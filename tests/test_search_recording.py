"""Dateigrenzen und Wiedergabe nutzen den tatsächlichen Controllervertrag."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import os

spec = importlib.util.spec_from_file_location('search_recording', Path(__file__).resolve().parents[1] / 'tools/search-recording.py')
recording = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recording)


class RecordingFilesTest(unittest.TestCase):
    def test_open_recording_sends_bounded_original_unicode_as_utf8(self):
        controller = object.__new__(recording.Controller)
        controller.helper = Path('/unused'); controller.binding = {}
        controller.capabilities = dict(recordingSchemaVersions=[1, 2, 3, 4, 5],
            configurationSchemaVersions=[1, 2, 3, 4], finderMetadataSchemaVersion=1)
        configuration = dict(schemaVersion=4, pattern='synthetic', roots=['/fixture'],
            options=[dict(name='finder-metadata', value='1')])
        generation = dict(device='1', inode='2', size='3', modifiedNS='1000000000', changedNS='1000000000')
        hits = [dict(path='/fixture/' + str(index), type='file', filesystemPath='/fixture/' + str(index),
            isDirectory=False, archiveMembers=[], size=3, modified=1.0,
            finderMetadata=dict(schemaVersion=1, sourceGeneration=generation,
                fields=dict(finderComment=dict(status='available', value='Ä' * 16000)))) for index in range(4)]
        value = dict(schemaVersion=5, finderMetadataCapability=1, configuration=configuration,
            runID='00000000-0000-0000-0000-000000000001', startedAt=1.0, capturedAt=2.0,
            state='completed', warningCount=0, hits=hits, selection=[])
        self.assertLess(len(json.dumps(value, ensure_ascii=False).encode()), 196608)
        def helper(*args, **kwargs):
            data = kwargs['input']
            self.assertLess(len(data), recording.MAX_BYTES)
            self.assertEqual(json.loads(data)['recording'], value)
            return recording.subprocess.CompletedProcess(args[0], 0, b'{}', b'')
        with patch.object(recording.subprocess, 'run', helper):
            controller.send('openRecording', recording=value)

    def test_duplicate_finder_snapshot_fields_rejected_before_decoding(self):
        raw = '{"schemaVersion":1,"recording":{"hits":[{"finderMetadata":{"fields":{"finderTags":{"values":[{"color":true,"color":6}]}}}}]},"actions":[]}'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'own-recording.json'
            path.write_text(raw)
            with self.assertRaisesRegex(ValueError, 'Doppelte'):
                recording.read_recording(path)

    def test_finder_and_inline_calendar_capabilities_checked_before_mutation(self):
        controller = object.__new__(recording.Controller)
        controller.binding = {}; controller.helper = Path('/unused')
        controller.capabilities = dict(configurationSchemaVersions=[1, 2, 3, 4], criteriaSchemaVersions=[1, 2, 3], finderMetadataSchemaVersion=1)
        query = dict(schemaVersion=3, root=dict(id='both', op='and', children=[
            dict(id='tag', field='finderTags', operator='contains', value='Project'),
            dict(id='date', field='modified', operator='equals', value=dict(kind='relative', preset='today', timeZone='UTC'))]))
        configuration = dict(schemaVersion=4, pattern='', roots=['/fixture'], options=[dict(name='criteria', value=json.dumps(query))])
        with patch.object(recording.subprocess, 'run', side_effect=AssertionError('mutation delivered')):
            with self.assertRaisesRegex(ValueError, 'Kalenderbereiche'):
                controller.send('configure', configuration=configuration)
        controller.capabilities['dateRangeSchemaVersion'] = 1
        controller.require_configuration(configuration)
        for key in ['dateRangeSchemaVersion', 'finderMetadataSchemaVersion']:
            controller.capabilities[key] = True
            with self.assertRaises(ValueError):
                controller.require_configuration(configuration)
            controller.capabilities[key] = 1
        del controller.capabilities['finderMetadataSchemaVersion']
        with self.assertRaisesRegex(ValueError, 'Finder'):
            controller.require_configuration(configuration)

    def test_local_content_capability_checked_before_delivery(self):
        controller = object.__new__(recording.Controller)
        controller.binding = {}; controller.helper = Path('/unused')
        controller.capabilities = dict(configurationSchemaVersions=[1, 2, 3, 4, 5], recordingSchemaVersions=[1, 2, 3, 4, 5, 6])
        configuration = dict(schemaVersion=5, pattern='needle', roots=['/fixture'], options=[dict(name='local-only', value='1')])
        with patch.object(recording.subprocess, 'run', side_effect=AssertionError('mutation delivered')):
            for capability in [None, True, 0, 2]:
                controller.capabilities['localContentSchemaVersion'] = capability
                with self.assertRaisesRegex(ValueError, 'lokale Inhalte'):
                    controller.send('configure', configuration=configuration)
        controller.capabilities['localContentSchemaVersion'] = 1
        controller.require_configuration(configuration)
        controller.require_recording(dict(schemaVersion=6, configuration=configuration, hits=[]))

    def test_pdf_ocr_and_image_ocr_capabilities_are_independent(self):
        controller = object.__new__(recording.Controller)
        controller.binding = {}; controller.helper = Path('/unused')
        controller.capabilities = dict(configurationSchemaVersions=[1,2,3,4,5,6,7], recordingSchemaVersions=[1,2,3,4,5,6,7,8])
        configuration = dict(schemaVersion=7,pattern='München',roots=['/fixture'],options=[dict(name='pdf-ocr',value='1')])
        with patch.object(recording.subprocess,'run',side_effect=AssertionError('mutation delivered')):
            with self.assertRaisesRegex(ValueError,'PDF-OCR'):controller.send('configure',configuration=configuration)
        controller.capabilities['pdfOCRSchemaVersion']=1
        controller.require_configuration(configuration)
        controller.require_recording(dict(schemaVersion=8,configuration=configuration,hits=[]))
        configuration['options'].append(dict(name='ocr',value='1'))
        with self.assertRaisesRegex(ValueError,'OCR'):controller.require_configuration(configuration)
        controller.capabilities['ocrSchemaVersion']=1
        controller.require_configuration(configuration)
        for key in ['pdfOCRSchemaVersion','ocrSchemaVersion']:
            controller.capabilities[key]=True
            with self.assertRaises(ValueError):controller.require_configuration(configuration)
            controller.capabilities[key]=1

    def test_configuration_comparison_migrates_only_legacy_shape(self):
        old = dict(pattern='', root='/missing/a/.', options=[dict(name='encoding', value='windows-1252')])
        new = dict(schemaVersion=2, pattern=old['pattern'], roots=[old['root']], options=old['options'])
        self.assertEqual(recording.configuration_key(old), recording.configuration_key(new))
        first = dict(new, roots=['/a', '/b'])
        self.assertNotEqual(recording.configuration_key(first), recording.configuration_key(dict(first, roots=['/b', '/a'])))
        self.assertNotEqual(recording.configuration_key(old), recording.configuration_key(dict(new, options=[])))
        self.assertNotEqual(recording.configuration_key(old), recording.configuration_key(dict(new, roots=['/missing/a'])))

    def test_configuration_comparison_rejects_unknown_or_partial_lists(self):
        source = dict(schemaVersion=2, pattern='x', roots=['/a', '/b'], options=[])
        for value in (dict(source, schemaVersion=True), dict(source, schemaVersion=8), dict(source, root='/a'),
                      dict(source, roots=[]), dict(source, roots=['/a', '/a']), dict(source, roots=['/a', 'relative'])):
            with self.subTest(value=value), self.assertRaises(ValueError):
                recording.configuration_key(value)

    def test_capability_three_accepts_old_and_new_recording_clients(self):
        def send(controller, operation, **fields):
            self.assertEqual(operation, 'capabilities')
            return dict(runtimeID='runtime', windowID='window', capabilities=dict(recordingSchemaVersion=3, recordingSchemaVersions=[1, 2, 3]))
        with patch.object(recording.Controller, 'send', send):
            self.assertEqual(recording.Controller(Path('/unused')).binding, dict(runtimeID='runtime', windowID='window'))

    def test_atomic_roundtrip_and_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'recording.json'
            value = dict(schemaVersion=1, recording={}, actions=[])
            recording.save_recording(path, value)
            self.assertEqual(recording.read_recording(path), value)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                recording.save_recording(path, dict(blob='x' * (recording.MAX_BYTES + 1)))
            self.assertEqual(recording.read_recording(path), value)

    def test_fifo_oversize_and_unapproved_action(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input'
            os.mkfifo(path)
            with self.assertRaises(ValueError):
                recording.read_recording(path)
            path.unlink()
            path.write_bytes(b'x' * (recording.MAX_BYTES + 1))
            with self.assertRaises(ValueError):
                recording.read_recording(path)
            path.write_text(json.dumps(dict(schemaVersion=1, recording={}, actions=[dict(operation='delete', identity={})])))
            with self.assertRaises(ValueError):
                recording.read_recording(path)


class PlaybackTest(unittest.TestCase):
    def controller(self):
        value = object.__new__(recording.Controller)
        value.helper = Path('/unused')
        value.binding = {}
        return value

    def test_replaced_run_never_cancels_new_search(self):
        controller = self.controller()
        controller.current = lambda: dict(runID='new', state='running')
        sent = []
        controller.send = lambda *a, **k: sent.append((a, k))
        with self.assertRaisesRegex(ValueError, 'ersetzt'):
            controller.wait_search('old', 1)
        self.assertEqual(sent, [])

    def test_timeout_cancels_only_bound_run(self):
        controller = self.controller()
        controller.current = lambda: dict(runID='own', state='running')
        sent = []
        controller.send = lambda *a, **k: sent.append((a, k))
        with patch.object(recording.time, 'monotonic', side_effect=[0, 2]):
            with self.assertRaisesRegex(ValueError, 'abgebrochen'):
                controller.wait_search('own', 1)
        self.assertEqual(sent, [(('cancel',), dict(runID='own'))])

    def test_handoff_waits_for_confirmation_before_next_action(self):
        controller = self.controller()
        sent = []
        def send(operation, **fields):
            sent.append(operation)
            return dict(handoff=dict(id='job', state='preparing' if operation == 'handoff' else 'failed'))
        controller.send = send
        with patch.object(recording.time, 'sleep'):
            with self.assertRaisesRegex(ValueError, 'nicht bestätigt'):
                controller.play_actions([dict(operation='handoff', identity={}), dict(operation='select', identity={})], 'own')
        self.assertEqual(sent, ['handoff', 'handoffStatus'])

    def test_cli_reports_current_selection_after_actions_and_rejects_replaced_run(self):
        identity = dict(filesystemPath='/fixture.txt', archiveMembers=[], archiveMemberBytes=[])
        for command in ('open', 'rerun'):
            for replaced in (False, True):
                with self.subTest(command=command, replaced=replaced), tempfile.TemporaryDirectory() as folder:
                    path = Path(folder) / 'recording.json'
                    recording.save_recording(path, dict(schemaVersion=1,
                        recording=dict(configuration={}), actions=[dict(operation='select', identity=identity)]))
                    status = dict(runID='own', state='completed', selection=[])
                    selected = False
                    def send(controller, operation, **fields):
                        nonlocal selected
                        if operation == 'capabilities':
                            return dict(runtimeID='runtime', windowID='window',
                                        capabilities=dict(recordingSchemaVersion=1))
                        if operation == 'select':
                            self.assertEqual(fields, dict(runID='own', identity=identity))
                            selected = True
                            status['selection'] = [identity]
                            if replaced:
                                status['runID'] = 'other'
                        return dict(status=dict(status))
                    output = io.StringIO()
                    with patch.object(recording.Controller, 'send', send), \
                         patch('sys.argv', ['search-recording.py', '--helper', '/unused', command, str(path), '--actions']), \
                         contextlib.redirect_stdout(output):
                        if replaced:
                            with self.assertRaisesRegex(ValueError, 'ersetzt'):
                                recording.main()
                            self.assertEqual(output.getvalue(), '')
                        else:
                            recording.main()
                            self.assertEqual(json.loads(output.getvalue()), status)
                    self.assertTrue(selected)


if __name__ == '__main__':
    unittest.main()
