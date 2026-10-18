"""Lokale Lesepolitik: unbekannte Inhalte sind keine negativen Beweise."""
import contextlib
import ctypes
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import favenio as f


class LocalContentTests(unittest.TestCase):
    def run_core(self, args, reason=None):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors), \
             mock.patch.object(f, 'local_content_reason', return_value=reason), \
             mock.patch.object(f, 'local_content_policy', side_effect=lambda _: contextlib.nullcontext()):
            status = f.main(['--local-only', '--json', '--search-report'] + args)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        return status, [row for row in rows if row['type'] != 'searchReport'], rows[-1], errors.getvalue()

    def test_name_and_facts_survive_without_any_content_reader(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / 'wolke.txt'
            source.write_text('bekannter Inhalt')
            with mock.patch.object(f, 'open_regular_file', side_effect=AssertionError('Inhalt geöffnet')):
                status, hits, report, _ = self.run_core(['--min-size', '1', 'wolke', str(source)], 'localContentNotLocal')
            self.assertEqual(status, 0)
            self.assertEqual(hits[0]['size'], source.stat().st_size)
            self.assertEqual(report['coverage'], 'withinRequestedScope')

    def test_content_absence_stays_unknown_and_or_can_use_known_name(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / 'wolke.txt'; source.write_text('secret')
            negative = dict(id='c', field='content', operator='contains', value='secret', negate=True)
            name = dict(id='n', field='name', operator='contains', value='wolke')
            for tree, count in [(negative, 0), (dict(id='root', op='or', children=[negative, name]), 1)]:
                query = json.dumps(dict(schemaVersion=1, root=tree))
                with mock.patch.object(f, 'open_regular_file', side_effect=AssertionError('Inhalt geöffnet')):
                    status, hits, report, _ = self.run_core(['--criteria-json', query, str(source)], 'localContentNotLocal')
                self.assertEqual(len(hits), count)
                self.assertEqual(status, 0 if count else 1)
                if not count:
                    self.assertEqual(report['coverage'], 'incomplete')
                    self.assertIn('localContentNotLocal', [r['id'] for r in report['reasons']])

    def test_unknown_provider_cannot_prove_content_or_run_metadata_or_dimensions(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / 'wolke.png'; source.write_bytes(b'not an image')
            for options in [['--content', 'needle'], ['--min-width', '10'], ['--metadata', 'needle']]:
                with mock.patch.object(f, 'open_regular_file', side_effect=AssertionError('Inhalt geöffnet')), \
                     mock.patch.object(f, 'find_exiftool', return_value='/unused/exiftool'), \
                     mock.patch.object(f.Search, 'exiftool_stream', side_effect=AssertionError('Helfer gestartet')):
                    status, hits, report, _ = self.run_core(options + [str(source)], 'localContentUnknown')
                self.assertEqual(status, 1)
                self.assertEqual(hits, [])
                self.assertIn('localContentUnknown', [r['id'] for r in report['reasons']])

    def test_remote_archive_keeps_container_name_and_never_opens_catalog(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / 'wolke.zip'; source.write_bytes(b'PK\x03\x04')
            with mock.patch.object(f.zipfile, 'ZipFile', side_effect=AssertionError('Archiv geöffnet')):
                status, hits, report, _ = self.run_core(['wolke', str(source)], 'localContentNotLocal')
            self.assertEqual(status, 0)
            self.assertEqual([r['type'] for r in hits], ['file'])
            self.assertEqual(report['coverage'], 'incomplete')

    def test_flags_and_other_provider_states(self):
        source = str(Path.home() / 'Library/CloudStorage/Unknown/fixture')
        with mock.patch.object(f.os, 'stat', return_value=types.SimpleNamespace(st_flags=0x40000000)):
            self.assertEqual(f.local_content_reason(source), 'localContentNotLocal')
        with mock.patch.object(f.os, 'stat', return_value=types.SimpleNamespace(st_flags=0)), \
             mock.patch.object(f, 'unverified_provider_location', return_value=True), \
             mock.patch.object(f, 'local_file_system', return_value=True):
            self.assertEqual(f.local_content_reason(source), 'localContentUnknown')
            with mock.patch.object(f, 'unverified_provider_location', return_value=False):
                self.assertIsNone(f.local_content_reason(source))
                with mock.patch.object(f, 'local_file_system', return_value=False):
                    self.assertEqual(f.local_content_reason(source), 'localContentUnknown')

    def test_provider_boundary_survives_aliases_in_both_directions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); storage = root / 'CloudStorage'; storage.mkdir()
            outside = root / 'outside'; outside.mkdir(); (outside / 'local.txt').write_text('own fixture')
            (storage / 'local-link').symlink_to(outside, target_is_directory=True)
            (storage / 'provider.txt').write_text('own provider fixture')
            (outside / 'provider-link.txt').symlink_to(storage / 'provider.txt')
            for source in [storage, storage / 'local-link/local.txt', outside / 'provider-link.txt']:
                self.assertTrue(f.unverified_provider_location(str(source), str(storage)))
            self.assertFalse(f.unverified_provider_location(str(outside / 'local.txt'), str(storage)))

    def test_unsupported_platform_fails_before_file_access(self):
        with mock.patch.object(f.sys, 'platform', 'linux'), \
             mock.patch.object(f, 'run_parsed', side_effect=AssertionError('Suchzugriff')), \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as caught:
                f.main(['--local-only', 'needle', '/unused'])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn('macOS 13', errors.getvalue())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS erforderlich')
    def test_missing_policy_api_fails_closed_before_dispatch(self):
        with mock.patch.object(f.ctypes, 'CDLL', side_effect=OSError('missing API')), \
             mock.patch.object(f, 'run_parsed', side_effect=AssertionError('Suchzugriff')), \
             contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(SystemExit) as caught:
                f.main(['--local-only', 'needle', '/unused'])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn('Materialisierungssperre nicht verfügbar', errors.getvalue())

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS erforderlich')
    def test_policy_is_inherited_and_restored_on_exception(self):
        library = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        before = library.getiopolicy_np(3, 0)
        with self.assertRaisesRegex(RuntimeError, 'probe'):
            with f.local_content_policy(True):
                self.assertEqual(library.getiopolicy_np(3, 0), 1)
                child = subprocess.run([sys.executable, '-c', 'import ctypes; print(ctypes.CDLL("/usr/lib/libSystem.B.dylib").getiopolicy_np(3,0))'], capture_output=True, text=True, timeout=10)
                self.assertEqual(child.returncode, 0)
                self.assertEqual(child.stdout.strip(), '1')
                raise RuntimeError('probe')
        self.assertEqual(library.getiopolicy_np(3, 0), before)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS erforderlich')
    def test_statfs_abi_and_actual_local_volume(self):
        source = '#include <sys/mount.h>\n#include <stdio.h>\n#include <stddef.h>\nint main(void){printf("%zu %zu",sizeof(struct statfs),offsetof(struct statfs,f_flags));}\n'
        with tempfile.TemporaryDirectory() as root:
            binary = str(Path(root) / 'abi')
            built = subprocess.run(['/usr/bin/clang', '-x', 'c', '-', '-o', binary], input=source, text=True, capture_output=True, timeout=20)
            self.assertEqual(built.returncode, 0, built.stderr)
            actual = subprocess.check_output([binary], text=True, timeout=5)
        self.assertEqual(actual, '%d %d' % (ctypes.sizeof(f.DarwinFileSystem), f.DarwinFileSystem.flags.offset))
        self.assertTrue(f.local_file_system(__file__))
