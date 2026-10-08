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

MAX_BYTES = 60000


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
    value = json.loads(data)
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
        raise ValueError('Aufzeichnung überschreitet 60.000 Byte.')
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
        if caps['capabilities'].get('recordingSchemaVersion') != 1:
            raise ValueError('Favenio unterstützt das Aufnahmeformat nicht.')

    def send(self, operation, **fields):
        request = dict(version=1, id=str(uuid.uuid4()), deadline=time.time() + 9,
                       operation=operation, **self.binding, **fields)
        result = subprocess.run([str(self.helper), '--no-launch', '--request', '-'],
                                input=json.dumps(request).encode(), capture_output=True, timeout=12)
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
        if len(identity_data) > 48000:
            raise ValueError('Trefferidentität zu groß.')
        identity = json.loads(identity_data)
        if identity not in [dict(filesystemPath=h['filesystemPath'], archiveMembers=h['archiveMembers'],
                                 archiveMemberBytes=h.get('archiveMemberBytes', [])) for h in value['recording']['hits']]:
            raise ValueError('Treffer fehlt im aufgezeichneten Stand.')
        status = controller.current()
        if status.get('configuration') != value['recording']['configuration']:
            raise ValueError('Aktuelle Suche verwendet eine andere Konfiguration.')
        value['actions'].append(dict(operation=args.operation, identity=identity))
        if len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf8')) > MAX_BYTES:
            raise ValueError('Aufzeichnung überschreitet 60.000 Byte.')
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
            controller.play_actions(value['actions'], status['runID'])
        print(json.dumps(status, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
