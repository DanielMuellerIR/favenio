"""Dubletten brauchen vollständige, stabile Inhalte statt Name oder Größe."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import favenio


class DuplicateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='favenio-duplicates-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def files(self, values):
        items = []
        for index, value in enumerate(values):
            path = self.root / str(index)
            path.write_bytes(value)
            items.append(dict(id=str(index), filesystemPath=str(path)))
        return dict(schemaVersion=1, items=items)

    def check(self, document, **kwargs):
        return favenio.DuplicateCheck(document, **kwargs).run()

    def test_equal_size_and_name_do_not_prove_equality(self):
        request = self.files([b'alpha', b'bravo', b'alpha', b'longer'])
        second = self.root / 'other'; second.mkdir()
        destination = second / '0'
        Path(request['items'][1]['filesystemPath']).rename(destination)
        request['items'][1]['filesystemPath'] = str(destination)
        result = self.check(request)
        self.assertTrue(result['complete'])
        self.assertEqual([g['memberIDs'] for g in result['groups']], [['0', '2']])
        self.assertEqual(result['hashedFiles'], 3)
        self.assertEqual(result['readBytes'], 25)
        self.assertTrue(result['groups'][0]['byteVerified'])

    def test_empty_files_are_confirmed(self):
        result = self.check(self.files([b'', b'']))
        self.assertEqual(result['groups'][0]['memberIDs'], ['0', '1'])
        self.assertEqual(result['readBytes'], 0)

    def test_hardlinks_and_symbolic_links_name_the_same_physical_file(self):
        request = self.files([b'alpha'])
        source = Path(request['items'][0]['filesystemPath'])
        hard, link = self.root / 'hard', self.root / 'link'
        os.link(source, hard); link.symlink_to(source)
        request['items'] += [dict(id='hard', filesystemPath=str(hard)), dict(id='link', filesystemPath=str(link))]
        result = self.check(request)
        self.assertEqual(result['groups'][0]['physicalFiles'], 1)
        self.assertEqual(result['files']['hard']['linkKind'], 'hardlink')
        self.assertEqual(result['files']['link']['linkKind'], 'symbolic')

    def test_hash_collision_still_partitions_by_bytes(self):
        class Collision:
            def update(self, chunk): pass
            def hexdigest(self): return '0' * 64
        with mock.patch.object(favenio.hashlib, 'sha256', Collision):
            result = self.check(self.files([b'alpha', b'bravo', b'alpha', b'bravo']))
        self.assertEqual([g['memberIDs'] for g in result['groups']], [['0', '2'], ['1', '3']])

    def test_generation_changed_after_hash_cannot_be_confirmed(self):
        request = self.files([b'alpha', b'alpha'])
        def event(value):
            if value['phase'] == 'confirm':
                Path(request['items'][0]['filesystemPath']).write_bytes(b'bravo')
        result = self.check(request, event=event)
        self.assertEqual(result['groups'], [])
        self.assertFalse(result['complete'])
        self.assertEqual(result['issues'][0]['reason'], 'changed')

    def test_final_generation_validation_rejects_already_confirmed_group(self):
        request = self.files([b'alpha', b'alpha'])
        def event(value):
            if value['phase'] == 'validate':
                Path(request['items'][1]['filesystemPath']).unlink()
        result = self.check(request, event=event)
        self.assertEqual(result['groups'], [])
        self.assertEqual(result['state'], 'partial')

    def test_unreadable_and_nonregular_are_explicit_partial_results(self):
        request = self.files([b'alpha', b'alpha'])
        fifo = self.root / 'fifo'; os.mkfifo(fifo)
        request['items'] += [dict(id='missing', filesystemPath=str(self.root / 'missing')),
                             dict(id='fifo', filesystemPath=str(fifo))]
        result = self.check(request)
        self.assertEqual(len(result['groups']), 1)
        self.assertEqual(result['state'], 'partial')
        self.assertEqual(result['issueCount'], 2)

    def test_byte_and_time_limits_clear_groups(self):
        request = self.files([b'alpha', b'alpha'])
        for limits, reason in [(dict(maxReadBytes=10), 'byteLimit'), (dict(maxSeconds=.00000001), 'timeLimit')]:
            request['limits'] = limits
            result = self.check(request)
            self.assertEqual(result['groups'], [])
            self.assertEqual(result['state'], 'limited')
            self.assertEqual(result['issues'][0]['reason'], reason)

    def test_budget_cannot_turn_a_truncated_comparison_into_inequality(self):
        request = self.files([b'x' * 100000, b'x' * 100000])
        request['limits'] = dict(maxReadBytes=300000)
        result = self.check(request)
        self.assertEqual(result['state'], 'limited')
        self.assertEqual(result['groups'], [])
        self.assertEqual(result['readBytes'], 300001)

    def test_local_policy_does_not_open_unknown_content(self):
        request = self.files([b'alpha', b'alpha'])
        with mock.patch.object(favenio, 'local_content_reason', return_value='localContentUnknown'), \
             mock.patch.object(favenio, 'open_regular_file', side_effect=AssertionError('opened')):
            result = self.check(request, local_only=True)
        self.assertEqual(result['groups'], [])
        self.assertEqual(result['hashedFiles'], 0)
        self.assertEqual(result['issueCount'], 2)

    def test_strict_request(self):
        request = self.files([b'a', b'a'])
        invalid = [dict(request, schemaVersion=True), dict(request, limits=dict(maxReadBytes=True)),
                   dict(request, limits=dict(maxSeconds=float('nan'))), dict(request, unknown=1),
                   dict(request, items=request['items'] * 2),
                   dict(request, items=[dict(request['items'][0], archiveMembers=['x'])])]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                favenio.DuplicateCheck(value)

    def test_cli_result_and_invalid_combination(self):
        request = self.root / 'request.json'; request.write_text(json.dumps(self.files([b'a', b'a'])))
        command = [sys.executable, str(Path(favenio.__file__)), '--duplicates-file', str(request)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout.splitlines()[-1])['type'], 'duplicateResult')
        result = subprocess.run(command + ['--content', 'a'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertIn('favenio: fehler:', result.stderr)

    def test_sigterm_clears_results_without_traceback(self):
        request = self.files([b'', b''])
        for item in request['items']:
            with open(item['filesystemPath'], 'wb') as handle: handle.truncate(2 * 1024 ** 3)
        path = self.root / 'request.json'; path.write_text(json.dumps(request))
        with subprocess.Popen([sys.executable, str(Path(favenio.__file__)), '--duplicates-file', str(path)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as child:
            while True:
                value = json.loads(child.stdout.readline())
                if value['phase'] == 'hash': break
            child.send_signal(signal.SIGTERM)
            stdout, stderr = child.communicate(timeout=5)
        result = json.loads(stdout.splitlines()[-1])
        self.assertEqual(result['state'], 'cancelled')
        self.assertEqual(result['groups'], [])
        self.assertEqual(child.returncode, 2)
        self.assertNotIn('Traceback', stderr)

@unittest.skipUnless(sys.platform == 'darwin', 'AppKit braucht macOS')
class DuplicateFrontendTests(unittest.TestCase):
    def test_frozen_scope_shared_archives_verified_groups_and_cancellation(self):
        from swift_test_support import run_probe
        with tempfile.TemporaryDirectory(prefix='favenio-duplicate-ui-') as directory:
            result = run_probe('duplicates', directory, timeout=30)
            self.assertTrue(json.loads(result.stdout)['passed'])


class DuplicateGuardTests(unittest.TestCase):
    setUp = DuplicateTests.setUp
    files = DuplicateTests.files
    check = DuplicateTests.check
    def guarded(self):
        request = self.files([b'alpha', b'alpha'])
        source = self.root / 'archive'; source.write_bytes(b'outer')
        request['schemaVersion'] = 2
        request['items'][1]['expectedGeneration'] = favenio.source_generation(request['items'][1]['filesystemPath'])
        request['items'][1]['sourceGuard'] = dict(filesystemPath=str(source), generation=favenio.source_generation(str(source)))
        return request, source

    def test_prepared_leaf_and_outer_guard_are_bound(self):
        request, source = self.guarded(); result = self.check(request)
        self.assertTrue(result['complete'])
        self.assertEqual(result['schemaVersion'], 2)
        self.assertEqual(result['files']['1']['guardGeneration'], favenio.source_generation(str(source)))

    def test_outer_change_after_hash_rejects_archive_member(self):
        request, source = self.guarded()
        def event(value):
            if value['phase'] == 'confirm': source.write_bytes(b'new outer')
        result = self.check(request, event=event)
        self.assertEqual(result['groups'], [])
        self.assertEqual(result['state'], 'partial')
        self.assertEqual(result['issues'][0]['reason'], 'changed')

    def test_leaf_changed_since_materialization_is_unknown(self):
        request, source = self.guarded()
        Path(request['items'][1]['filesystemPath']).write_bytes(b'bravo')
        result = self.check(request)
        self.assertEqual(result['groups'], [])
        self.assertEqual(result['issues'][0]['reason'], 'changed')

    def test_unavailable_members_keep_scope_and_partial_group(self):
        request = self.files([b'alpha', b'alpha']); request['schemaVersion'] = 2
        for i in range(2):
            request['items'].append(dict(id='bad'+str(i),filesystemPath=str(self.root/'archive'),unavailable=dict(reason='archiveError',message='own CRC failure')))
        result = self.check(request)
        self.assertEqual(result['scopeCount'], 4)
        self.assertEqual(result['issueCount'], 2)
        self.assertEqual(result['state'], 'partial')
        self.assertEqual(result['groups'][0]['memberIDs'], ['0','1'])

    def test_generation_and_failure_transport_are_strict(self):
        request, source = self.guarded()
        request['items'][1]['expectedGeneration']['size'] = True
        with self.assertRaises(ValueError): favenio.DuplicateCheck(request)
        request, source = self.guarded(); request['schemaVersion'] = 1
        with self.assertRaises(ValueError): favenio.DuplicateCheck(request)

    def test_long_archive_diagnostic_keeps_integrity_reason(self):
        request = self.files([b'alpha', b'alpha']); request['schemaVersion'] = 2
        request['items'].append(dict(id='broken', filesystemPath=str(self.root/'archive'),
                                    unavailable=dict(reason='archiveError', message='path/' + 'x'*900 + ': Bad CRC-32')))
        result = self.check(request)
        self.assertEqual(result['state'], 'partial')
        self.assertIn('Bad CRC-32', result['issues'][0]['message'])
