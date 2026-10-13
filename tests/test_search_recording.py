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
    def test_atomic_roundtrip_and_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'recording.json'
            value = dict(schemaVersion=1, recording={}, actions=[])
            recording.save_recording(path, value)
            self.assertEqual(recording.read_recording(path), value)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                recording.save_recording(path, dict(blob='x' * 60001))
            self.assertEqual(recording.read_recording(path), value)

    def test_fifo_oversize_and_unapproved_action(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input'
            os.mkfifo(path)
            with self.assertRaises(ValueError):
                recording.read_recording(path)
            path.unlink()
            path.write_bytes(b'x' * 60001)
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
