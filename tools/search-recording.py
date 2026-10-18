#!/usr/bin/env python3
"""Begrenzte Suchstände sichern, sichtbar öffnen oder ausdrücklich neu suchen."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid

MAX_BYTES = 262144


def unique_json_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('Doppelte JSON-Felder sind in Aufzeichnungen nicht zulässig.')
        value[key] = item
    return value


def configuration_key(value):
    if not isinstance(value, dict):
        raise ValueError('Ungültige Suchkonfiguration.')
    if set(value) == {'pattern', 'root', 'options'} and isinstance(value['root'], str):
        roots = [value['root']]
    elif (set(value) == {'schemaVersion', 'pattern', 'roots', 'options'}
          and type(value['schemaVersion']) is int and value['schemaVersion'] in (2, 3, 4, 5, 6, 7)
          and isinstance(value['roots'], list) and 1 <= len(value['roots']) <= 16
          and all(isinstance(root, str) and len(root.encode('utf-8')) <= 4096 for root in value['roots'])
          and sum(len(root.encode('utf-8')) for root in value['roots']) <= 65536):
        roots = value['roots']
    else:
        raise ValueError('Unbekannte Suchkonfiguration.')
    if (not all(root.startswith('/') and '\0' not in root for root in roots)
            or len(set(roots)) != len(roots)
            or not isinstance(value['pattern'], str) or not isinstance(value['options'], list)):
        raise ValueError('Ungültige Suchbereiche.')
    return value['pattern'], roots, value['options']


def read_regular(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('Eingabe muss eine reguläre Datei sein.')
        data = source.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Eingabe überschreitet die Größenbegrenzung.')
    return data


def read_recording(path):
    data = read_regular(path, MAX_BYTES)
    value = json.loads(data, object_pairs_hook=unique_json_object)
    if (not isinstance(value, dict) or set(value) != {'schemaVersion', 'recording', 'actions'}
            or type(value['schemaVersion']) is not int or value['schemaVersion'] != 1
            or not isinstance(value['recording'], dict) or not isinstance(value['actions'], list)
            or len(value['actions']) > 32):
        raise ValueError('Ungültiges Aufnahmeformat.')
    for action in value['actions']:
        if (not isinstance(action, dict) or set(action) != {'operation', 'identity'}
                or action['operation'] not in ('select', 'handoff')
                or not isinstance(action['identity'], dict)):
            raise ValueError('Unzulässige Aufnahmeaktion.')
    return value


def save_recording(path, value):
    data = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf8')
    if len(data) > MAX_BYTES:
        raise ValueError('Aufzeichnung überschreitet 262.144 Byte.')
    # Nur die ausdrücklich benannte Datei ersetzen; bei Fehler bleibt ihr alter Stand.
    descriptor, temporary = tempfile.mkstemp(prefix='.favenio-recording-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as target:
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Controller:
    def __init__(self, helper):
        self.helper = helper
        self.binding = {}
        caps = self.send('capabilities')
        self.binding = {key: caps[key] for key in ('runtimeID', 'windowID')}
        self.capabilities = caps['capabilities']
        if not set(self.recording_versions()).intersection((1, 2, 3, 4, 5, 6, 7, 8)):
            raise ValueError('Favenio unterstützt das Aufnahmeformat nicht.')

    def recording_versions(self):
        return [value for value in self.capabilities.get('recordingSchemaVersions', [self.capabilities.get('recordingSchemaVersion')]) if type(value) is int]

    def supports_capability(self, key):
        value = self.capabilities.get(key)
        return type(value) is int and value == 1

    def require_configuration(self, configuration):
        configuration_key(configuration)
        version = configuration.get('schemaVersion', 1)
        if not any(type(value) is int and value == version for value in self.capabilities.get('configurationSchemaVersions', [1])):
            raise ValueError(f'Favenio unterstützt Konfigurationsformat {version} nicht; gemeinsam aktualisieren.')
        for option in configuration['options']:
            if option['name'] == 'pdf-ocr' and option['value'] == '1' and not self.supports_capability('pdfOCRSchemaVersion'):
                raise ValueError('Favenio unterstützt PDF-OCR nicht; gemeinsam aktualisieren.')
            if option['name'] == 'ocr' and option['value'] == '1' and not self.supports_capability('ocrSchemaVersion'):
                raise ValueError('Favenio unterstützt OCR nicht; gemeinsam aktualisieren.')
            if option['name'] == 'local-only' and option['value'] == '1' and not self.supports_capability('localContentSchemaVersion'):
                raise ValueError('Favenio unterstützt lokale Inhalte nicht; gemeinsam aktualisieren.')
            if option['name'] == 'finder-metadata' and option['value'] == '1':
                if not self.supports_capability('finderMetadataSchemaVersion'):
                    raise ValueError('Favenio unterstützt Finder-Eigenschaften nicht; gemeinsam aktualisieren.')
            if option['name'] == 'criteria':
                criteria = json.loads(option['value'], object_pairs_hook=unique_json_object)
                schema = criteria['schemaVersion']
                if type(schema) is not int or not any(type(value) is int and value == schema for value in self.capabilities.get('criteriaSchemaVersions', [self.capabilities.get('criteriaSchemaVersion', 1)])):
                    raise ValueError(f'Favenio unterstützt Kriterienschema {schema} nicht; gemeinsam aktualisieren.')
                if schema == 3 and not self.supports_capability('finderMetadataSchemaVersion'):
                    raise ValueError('Favenio unterstützt Finder-Eigenschaften nicht; gemeinsam aktualisieren.')
                pending = [criteria['root']]
                count = 0
                while pending:
                    node = pending.pop()
                    count += 1
                    if count > 256 or not isinstance(node, dict):
                        raise ValueError('Ungültiger oder zu großer Kriterienbaum.')
                    if node.get('field') in ('modified', 'created') and isinstance(node.get('value'), dict):
                        if not self.supports_capability('dateRangeSchemaVersion'):
                            raise ValueError('Favenio unterstützt Kalenderbereiche nicht; gemeinsam aktualisieren.')
                    pending.extend(node.get('children', []))
            if option['name'] == 'date-ranges' and not self.supports_capability('dateRangeSchemaVersion'):
                raise ValueError('Favenio unterstützt Kalenderbereiche nicht; gemeinsam aktualisieren.')

    def require_recording(self, recording):
        if type(recording.get('schemaVersion')) is not int or recording['schemaVersion'] not in self.recording_versions():
            raise ValueError('Favenio unterstützt dieses Aufnahmeformat nicht; gemeinsam aktualisieren.')
        self.require_configuration(recording['configuration'])
        if recording['schemaVersion'] == 8 and not self.supports_capability('pdfOCRSchemaVersion'):
            raise ValueError('Favenio unterstützt PDF-OCR nicht; gemeinsam aktualisieren.')
        if any(option['name'] == 'ocr' and option['value'] == '1' for option in recording['configuration']['options']) and not self.supports_capability('ocrSchemaVersion'):
            raise ValueError('Favenio unterstützt OCR nicht; gemeinsam aktualisieren.')
        if any(option['name'] == 'local-only' and option['value'] == '1' for option in recording['configuration']['options']) and not self.supports_capability('localContentSchemaVersion'):
            raise ValueError('Favenio unterstützt lokale Inhalte nicht; gemeinsam aktualisieren.')
        if recording['schemaVersion'] == 5 or any('finderMetadata' in hit for hit in recording.get('hits', [])):
            if not self.supports_capability('finderMetadataSchemaVersion'):
                raise ValueError('Favenio unterstützt erfasste Finder-Eigenschaften nicht; gemeinsam aktualisieren.')

    def send(self, operation, **fields):
        if operation == 'configure':
            self.require_configuration(fields['configuration'])
        elif operation == 'openRecording':
            self.require_recording(fields['recording'])
        request = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 9,
                       operation=operation, **self.binding, **fields)
        result = subprocess.run([str(self.helper), '--no-launch', '--request', '-'],
                                input=json.dumps(request, ensure_ascii=False, separators=(',', ':')).encode('utf-8'), capture_output=True, timeout=12)
        value = json.loads(result.stdout)
        if result.returncode or 'error' in value:
            error = value.get('error', {})
            raise ValueError(f"{error.get('code', 'delivery')}: {error.get('message', 'Keine Antwort')}")
        return value

    def current(self):
        return self.send('status')['status']

    def wait_search(self, run_id, timeout):
        deadline = time.monotonic() + timeout
        while True:
            status = self.current()
            if status.get('runID') != run_id:
                raise ValueError('Suchlauf wurde während der Wiedergabe ersetzt.')
            if status['state'] != 'running':
                return status
            if time.monotonic() >= deadline:
                self.send('cancel', runID=run_id)
                raise ValueError('Wiedergabe nach Zeitgrenze abgebrochen; Teilergebnisse bleiben sichtbar.')
            time.sleep(.1)

    def play_actions(self, actions, run_id):
        for action in actions:
            response = self.send(action['operation'], runID=run_id, identity=action['identity'])
            if action['operation'] == 'handoff':
                job = response['handoff']
                deadline = time.monotonic() + 35
                while job['state'] not in ('ready', 'failed', 'cancelled'):
                    if time.monotonic() >= deadline:
                        self.send('cancelHandoff', jobID=job['id'])
                        raise ValueError('Übergabe hat die Zeitgrenze erreicht.')
                    time.sleep(.1)
                    job = self.send('handoffStatus', jobID=job['id'])['handoff']
                if job['state'] != 'ready':
                    raise ValueError('Übergabe nicht bestätigt: ' + json.dumps(job.get('error', {}), ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--helper', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=60)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('record', 'open', 'rerun'):
        command = sub.add_parser(name)
        command.add_argument('file', type=Path)
        if name in ('open', 'rerun'):
            command.add_argument('--actions', action='store_true', help='Aufgezeichnete Auswahl/Übergabe ausdrücklich ausführen')
    action = sub.add_parser('append-action')
    action.add_argument('file', type=Path)
    action.add_argument('operation', choices=['select', 'handoff'])
    action.add_argument('identity', type=Path, help='JSON-Datei mit exakter HitIdentity')
    args = parser.parse_args()
    if not 0 < args.timeout <= 300:
        raise ValueError('Zeitgrenze muss zwischen 0 und 300 Sekunden liegen.')
    value = None if args.command == 'record' else read_recording(args.file)
    controller = Controller(args.helper)
    if args.command == 'record':
        status = controller.current()
        recording = controller.send('captureRecording', runID=status.get('runID'))['recording']
        save_recording(args.file, dict(schemaVersion=1, recording=recording, actions=[]))
    elif args.command == 'append-action':
        if len(value['actions']) >= 32:
            raise ValueError('Aufnahme ist auf 32 Aktionen begrenzt.')
        identity_data = read_regular(args.identity, 48000)
        identity = json.loads(identity_data)
        if identity not in [dict(filesystemPath=h['filesystemPath'], archiveMembers=h['archiveMembers'],
                                 archiveMemberBytes=h.get('archiveMemberBytes', [])) for h in value['recording']['hits']]:
            raise ValueError('Treffer fehlt im aufgezeichneten Stand.')
        status = controller.current()
        if configuration_key(status.get('configuration')) != configuration_key(value['recording']['configuration']):
            raise ValueError('Aktuelle Suche verwendet eine andere Konfiguration.')
        value['actions'].append(dict(operation=args.operation, identity=identity))
        if len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf8')) > MAX_BYTES:
            raise ValueError('Aufzeichnung überschreitet 262.144 Byte.')
        controller.play_actions([value['actions'][-1]], status['runID'])
        save_recording(args.file, value)
    else:
        if args.command == 'open':
            status = controller.send('openRecording', recording=value['recording'])['status']
        else:
            status = controller.current()
            if status['state'] == 'running':
                raise ValueError('Laufende Suche zuerst ausdrücklich abbrechen.')
            controller.send('configure', configuration=value['recording']['configuration'])
            status = controller.send('start')['status']
            status = controller.wait_search(status['runID'], args.timeout)
            if status['state'] not in ('completed', 'warnings'):
                raise ValueError('Neue Suche endete ohne erfolgreichen Abschluss: ' + status['state'])
        if args.actions:
            run_id = status['runID']
            controller.play_actions(value['actions'], run_id)
            status = controller.current()
            if status.get('runID') != run_id:
                raise ValueError('Suchlauf wurde während der Wiedergabe ersetzt.')
        print(json.dumps(status, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
