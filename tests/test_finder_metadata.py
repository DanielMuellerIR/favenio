import ctypes
import base64
import csv
import errno
import contextlib
import io
import json
import subprocess
import zipfile
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest import mock

import favenio as f


def binary(value):
    return plistlib.dumps(value, fmt=plistlib.FMT_BINARY)


class FinderMetadataTest(unittest.TestCase):
    def test_tag_names_colors_and_original_spelling(self):
        raw = ['Projekt A\u0308\n6', 'Blau\n4', 'Ohne Farbe', 'Null\n0', 'Grau\n7', 'Name\n8']
        result = f.parse_finder_attribute('finderTags', binary(raw))
        self.assertEqual(result['status'], 'available')
        self.assertEqual([item['raw'] for item in result['values']], raw)
        self.assertEqual([item['name'] for item in result['values']],
                         ['Projekt A\u0308', 'Blau', 'Ohne Farbe', 'Null', 'Grau', 'Name\n8'])
        self.assertEqual([item['color'] for item in result['values']], [6, 4, None, 0, 7, None])

    def test_comment_and_explicit_empty_values(self):
        text = 'Kommentar Ä\nzweite Zeile 🌿'
        self.assertEqual(f.parse_finder_attribute('finderComment', binary(text)), dict(status='available', value=text))
        self.assertEqual(f.parse_finder_attribute('finderComment', binary(''))['value'], '')
        self.assertEqual(f.parse_finder_attribute('finderTags', binary([]))['values'], [])
        self.assertEqual(f.parse_finder_attribute('finderComment', plistlib.dumps(text))['value'], text)

    def test_invalid_attribute_shapes(self):
        for field, value in [('finderTags', 'name'), ('finderTags', ['']), ('finderTags', ['\n2']),
                             ('finderTags', [5]), ('finderTags', ['nul\0name']),
                             ('finderComment', ['text']), ('finderComment', 'nul\0text')]:
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                f.parse_finder_attribute(field, binary(value))
        for data in [b'', b'bplist00', b'<plist><string>broken', b'arbitrary']:
            with self.subTest(data=data), self.assertRaises(ValueError):
                f.finder_plist(data)

    def test_value_budgets_do_not_truncate_into_known_empty(self):
        for field, value in [('finderTags', ['x'] * 257), ('finderTags', ['Ä' * 513]),
                             ('finderComment', 'Ä' * 16385)]:
            with self.subTest(field=field), self.assertRaises(f.FinderMetadataLimit):
                f.parse_finder_attribute(field, binary(value))
        with self.assertRaises(f.FinderMetadataLimit):
            f.finder_plist(b'x' * 65537)

    def test_forged_binary_object_count_rejected_before_parser_allocation(self):
        data = b'bplist00' + b'\x00' + struct.pack('>6xBBQQQ', 1, 1, 2 ** 60, 0, 8)
        with mock.patch.object(plistlib, 'loads', side_effect=AssertionError('unbounded parser allocation')):
            with self.assertRaises(f.FinderMetadataLimit):
                f.finder_plist(data)

    def test_invalid_binary_offsets_and_trailer(self):
        data = bytearray(binary(['tag']))
        table = struct.unpack('>6xBBQQQ', data[-32:])[-1]
        data[table] = 0
        with self.assertRaises(ValueError):
            f.finder_plist(bytes(data))
        with self.assertRaises(ValueError):
            f.finder_plist(b'bplist01' + b'\0' * 40)

    def test_empty_demand_and_unsupported_platform_do_not_touch_source(self):
        with mock.patch.object(f.os, 'lstat', side_effect=AssertionError('unnecessary stat')), mock.patch.object(f, 'finder_xattr', side_effect=AssertionError('unnecessary attribute read')):
            self.assertEqual(f.read_finder_metadata('/unused', [])['fields'], {})
            with mock.patch.object(f.sys, 'platform', 'linux'):
                self.assertEqual(f.read_finder_metadata('/unused', ['finderTags'])['fields'], dict(finderTags=dict(status='unsupported')))
        with self.assertRaises(ValueError):
            f.read_finder_metadata('/unused', ['Keywords'])

    def test_only_requested_attributes_once_and_directories_supported(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            with mock.patch.object(f, 'finder_xattr', return_value=binary(['Ordner\n2'])) as getter:
                result = f.read_finder_metadata(directory, ['finderTags', 'finderTags'])
                self.assertEqual(result['fields']['finderTags']['values'][0]['name'], 'Ordner')
                getter.assert_called_once_with(directory, f.FINDER_ATTRIBUTES['finderTags'])
                self.assertEqual(result['sourceGeneration'], f.source_generation(status=os.lstat(directory)))

    def test_absent_unreadable_invalid_and_limited_remain_distinct(self):
        cases = [(OSError(93, 'absent'), 'absent'), (OSError(errno.EACCES, 'denied'), 'unreadable'),
                 (ValueError('malformed'), 'invalid'), (f.FinderMetadataLimit('large'), 'limited')]
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            for error, expected in cases:
                with self.subTest(expected=expected), mock.patch.object(f, 'finder_xattr', side_effect=error):
                    result = f.read_finder_metadata(directory, ['finderComment'])['fields']['finderComment']
                    self.assertEqual(result, dict(status=expected))

    def test_failed_field_does_not_erase_other_known_field(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            with mock.patch.object(f, 'finder_xattr', side_effect=[OSError(93, 'absent'), binary('known')]) as getter:
                result = f.read_finder_metadata(directory, ['finderTags', 'finderComment'])
            self.assertEqual(result['fields']['finderTags'], dict(status='absent'))
            self.assertEqual(result['fields']['finderComment'], dict(status='available', value='known'))
            self.assertEqual(getter.call_count, 2)

    def test_symlink_fifo_and_missing_path_never_read_target(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            root = Path(directory); target = root / 'target'; target.write_text('own fixture')
            link = root / 'link'; link.symlink_to(target); fifo = root / 'fifo'; os.mkfifo(fifo)
            with mock.patch.object(f, 'finder_xattr', side_effect=AssertionError('special source opened')):
                for path in [link, fifo]:
                    self.assertEqual(f.read_finder_metadata(path, ['finderTags'])['fields']['finderTags']['status'], 'unsupported')
                self.assertEqual(f.read_finder_metadata(root / 'missing', ['finderTags'])['fields']['finderTags']['status'], 'unreadable')

    def test_source_change_invalidates_all_fields_without_partial_values(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'; path.write_text('a')
            def changed(*_):
                path.write_text(path.read_text() + 'b')
                return binary(['tag'])
            calls = []
            def read(_, name):
                calls.append(name)
                if name == f.FINDER_ATTRIBUTES['finderTags']:
                    return changed()
                return binary('old comment')
            with mock.patch.object(f, 'finder_xattr', side_effect=read):
                result = f.read_finder_metadata(path, ['finderComment', 'finderTags'])
            self.assertEqual(result['fields'], {key: dict(status='sourceChanged') for key in ['finderComment', 'finderTags']})
            self.assertEqual(len(calls), 2)

    def test_replacement_and_disappearing_source_discard_attribute_values(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'
            for replacement in [True, False]:
                path.write_text('own')
                def replace(*_):
                    path.unlink()
                    if replacement:
                        path.write_text('different owned fixture')
                    return binary(['tag'])
                with mock.patch.object(f, 'finder_xattr', side_effect=replace):
                    self.assertEqual(f.read_finder_metadata(path, ['finderTags'])['fields']['finderTags'], dict(status='sourceChanged'))

    def test_native_getter_rejects_size_before_allocation(self):
        getter = mock.Mock(return_value=65537)
        with mock.patch.object(f, '_finder_getxattr', getter), mock.patch.object(ctypes, 'create_string_buffer', side_effect=AssertionError('oversized allocation')):
            with self.assertRaises(f.FinderMetadataLimit):
                f.finder_xattr('/unused', f.FINDER_ATTRIBUTES['finderTags'])
        self.assertEqual(getter.call_count, 1)

    def test_native_getter_rejects_changed_or_failed_second_read(self):
        for values in [[10, 9], [10, -1]]:
            with mock.patch.object(f, '_finder_getxattr', mock.Mock(side_effect=values)):
                with self.assertRaises(OSError):
                    f.finder_xattr('/unused', f.FINDER_ATTRIBUTES['finderTags'])

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin extended attributes')
    def test_real_file_and_folder_attributes_without_content_or_subprocess(self):
        library = ctypes.CDLL(None, use_errno=True)
        setter = library.setxattr
        setter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        setter.restype = ctypes.c_int
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic'; path.write_text('own fixture')
            for item in [path, Path(directory)]:
                for field, value in [('finderTags', ['Projekt Ä\n6', 'Blau\n4']), ('finderComment', 'Kommentar 🌿\nzweite Zeile')]:
                    data = binary(value); buffer = ctypes.create_string_buffer(data)
                    self.assertEqual(setter(os.fsencode(item), f.FINDER_ATTRIBUTES[field].encode(), buffer, len(data), 0, 1), 0)
                with mock.patch.object(f.subprocess, 'run', side_effect=AssertionError('external metadata process')):
                    result = f.read_finder_metadata(item, f.FINDER_ATTRIBUTES)
                self.assertEqual(result['fields']['finderTags']['values'][0], dict(name='Projekt Ä', color=6, raw='Projekt Ä\n6'))
                self.assertEqual(result['fields']['finderComment']['value'], 'Kommentar 🌿\nzweite Zeile')
            absent = Path(directory) / 'absent'; absent.write_bytes(b'')
            self.assertEqual(f.read_finder_metadata(absent, f.FINDER_ATTRIBUTES)['fields'], {field: dict(status='absent') for field in f.FINDER_ATTRIBUTES})


class FinderCriteriaTest(unittest.TestCase):
    def test_change_between_facts_and_snapshot_keeps_only_independent_hits(self):
        for size, modified_ns in [(4, 1700000000000000000), (3, 1700000001000000000), (4, 1700000001000000000)]:
            status = mock.Mock(st_mode=f.stat.S_IFREG, st_dev=1, st_ino=2, st_size=size,
                               st_mtime_ns=modified_ns, st_ctime_ns=modified_ns)
            for query, optional in [(None, True), (self.query(dict(id='both', op='and', children=[
                    self.leaf(), dict(id='size', field='size', operator='atMost', value='3')])), False)]:
                output = io.StringIO()
                search = f.Search(lambda name: name == 'synthetic', content_mode=False, archive_depth=0,
                                  as_json=True, criteria_query=query, include_finder_metadata=optional)
                probe = f.FileProbe(search, '/missing/synthetic', 'synthetic', None, None, '/missing/synthetic')
                probe._set_facts(3, 1700000000.0, None)
                def attribute(_, name):
                    return binary(['Projekt Ä\n6'] if name == f.FINDER_ATTRIBUTES['finderTags'] else 'comment')
                with mock.patch.object(f.sys, 'platform', 'darwin'), mock.patch.object(f.os, 'lstat', return_value=status), mock.patch.object(f, 'finder_xattr', side_effect=attribute), contextlib.redirect_stdout(output):
                    try: search.evaluate(probe, '/missing/synthetic', 'file', filesystem_path='/missing/synthetic')
                    finally: search.close()
                rows = [json.loads(line) for line in output.getvalue().splitlines()]
                if query is not None:
                    self.assertEqual(rows, [])
                else:
                    self.assertEqual(len(rows), 1)
                    self.assertEqual((rows[0]['size'], rows[0]['modified']), (3, 1700000000.0))
                    snapshot = rows[0]['finderMetadata']
                    self.assertIsNone(snapshot['sourceGeneration'])
                    self.assertTrue(all(value['status'] == 'sourceChanged' for value in snapshot['fields'].values()))
                    f.validate_finder_snapshot(snapshot)
                    from swift_test_support import run_probe
                    reply = json.loads(run_probe('finder-metadata', 'hit', input=json.dumps([json.dumps(rows[0])])).stdout)[0]
                    self.assertTrue(reply['valid'] and reply['snapshotBytesPreserved'])

    @staticmethod
    def leaf(field='finderTags', value='Projekt Ä', **options):
        return dict(id='finder', field=field, operator='contains', value=value, **options)

    @staticmethod
    def query(root):
        return f.parse_criteria_query(dict(schemaVersion=3, root=root))

    def search(self, path, root, **options):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            search = f.Search(None, content_mode=False, archive_depth=0, as_json=True, criteria_query=self.query(root), **options)
            try:
                search.search_path(str(path))
            finally:
                search.close()
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def test_new_fields_need_schema_three_and_do_not_enable_exiftool(self):
        for version in [1, 2]:
            with self.assertRaises(ValueError):
                f.parse_criteria_query(dict(schemaVersion=version, root=self.leaf()))
        query = self.query(self.leaf())
        self.assertEqual(query.finder_fields, ['finderTags'])
        self.assertEqual(query.metadata_fields, [])
        with self.assertRaises(ValueError):
            self.query(self.leaf(metadataField='Keywords'))

    def test_two_conditions_share_one_requested_snapshot_and_preserve_evidence(self):
        tag = self.leaf(); comment = dict(self.leaf('finderComment', '🌿'), id='comment')
        root = dict(id='both', op='and', children=[tag, comment])
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'; path.write_text('own fixture')
            def getter(_, name):
                return binary(['Projekt Ä\n6']) if name == f.FINDER_ATTRIBUTES['finderTags'] else binary('Kommentar 🌿')
            with mock.patch.object(f, 'finder_xattr', side_effect=getter) as read:
                records = self.search(path, root)
            self.assertEqual(len(records), 1)
            self.assertEqual(read.call_count, 2)
            self.assertEqual([item['field'] for item in records[0]['criteriaEvidence']], ['finderTags', 'finderComment'])
            self.assertEqual(records[0]['finderMetadata']['fields']['finderTags']['values'][0]['color'], 6)
            self.assertEqual(records[0]['finderMetadata']['fields']['finderComment']['value'], 'Kommentar 🌿')

    def test_absent_unreadable_and_malformed_are_not_negated_into_hits(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'; path.write_text('own fixture')
            for error in [OSError(93, 'absent'), OSError(errno.EACCES, 'denied'), ValueError('invalid')]:
                with self.subTest(error=error), mock.patch.object(f, 'finder_xattr', side_effect=error):
                    self.assertEqual(self.search(path, self.leaf(negate=True)), [])
            with mock.patch.object(f, 'finder_xattr', return_value=binary([])):
                record = self.search(path, self.leaf(negate=True))[0]
                self.assertTrue(record['criteriaEvidence'][0]['negated'])
                self.assertEqual(record['finderMetadata']['fields']['finderTags']['values'], [])

    def test_cheap_false_name_and_successful_or_branch_do_not_read_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'own'; path.write_text('own fixture')
            for operator, name, count in [('and', 'missing', 0), ('or', 'own', 1)]:
                root = dict(id='group', op=operator, children=[self.leaf(), dict(id='name', field='name', operator='equals', value=name)])
                with mock.patch.object(f, 'read_finder_metadata', side_effect=AssertionError('unnecessary metadata read')):
                    records = self.search(path, root)
                self.assertEqual(len(records), count)
                if records:
                    self.assertNotIn('finderMetadata', records[0])

    def test_source_changed_after_matching_is_discarded_before_emit(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'; path.write_text('own fixture')
            original = f.FileProbe.facts
            def changed(probe):
                result = original(probe)
                path.write_text('changed own fixture')
                return result
            with mock.patch.object(f, 'finder_xattr', return_value=binary(['Projekt Ä'])), mock.patch.object(f.FileProbe, 'facts', changed):
                self.assertEqual(self.search(path, self.leaf()), [])

    def test_archive_members_have_no_finder_properties(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'own.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('keep.txt', 'own fixture')
            with mock.patch.object(f, 'read_finder_metadata', side_effect=AssertionError('archive metadata source read')):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    search = f.Search(lambda name: name == 'keep.txt', content_mode=False, archive_depth=1, as_json=True, include_finder_metadata=True)
                    try:
                        search.search_path(str(path))
                    finally:
                        search.close()
            record = json.loads(output.getvalue())
            self.assertEqual(record['finderMetadata']['fields'], {key: dict(status='notApplicable') for key in f.FINDER_ATTRIBUTES})
            self.assertIsNone(record['finderMetadata']['sourceGeneration'])

    def test_optional_snapshot_reads_matching_names_only(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            root = Path(directory); (root / 'keep').write_text('a'); (root / 'skip').write_text('b')
            output = io.StringIO()
            with mock.patch.object(f, 'finder_xattr', side_effect=OSError(93, 'absent')) as getter, contextlib.redirect_stdout(output):
                search = f.Search(lambda name: name == 'keep', content_mode=False, archive_depth=0, as_json=True, include_finder_metadata=True)
                try:
                    search.search_path(str(root))
                finally:
                    search.close()
            self.assertEqual(getter.call_count, 2)
            self.assertEqual(json.loads(output.getvalue())['finderMetadata']['fields']['finderTags']['status'], 'absent')

    def test_optional_snapshot_change_does_not_cancel_a_name_only_or_match(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'):
            path = Path(directory) / 'own'; path.write_text('own fixture')
            root = dict(id='either', op='or', children=[self.leaf(), dict(id='name', field='name', operator='equals', value='own')])
            def changed(*_):
                path.write_text(path.read_text() + 'x')
                return binary(['tag'])
            with mock.patch.object(f, 'finder_xattr', side_effect=changed):
                record = self.search(path, root, include_finder_metadata=True)[0]
            self.assertEqual([item['field'] for item in record['criteriaEvidence']], ['name'])
            self.assertTrue(all(value['status'] == 'sourceChanged' for value in record['finderMetadata']['fields'].values()))

    def test_schema_three_validation_does_not_read_metadata_or_source(self):
        with mock.patch.object(f, 'read_finder_metadata', side_effect=AssertionError('validation source read')), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(f.main(['--validate-criteria', '--criteria-json='+json.dumps(dict(schemaVersion=3, root=self.leaf()))]), 0)
        self.assertTrue(json.loads(output.getvalue())['valid'])

    def test_snapshot_option_cannot_reach_content_preview_source(self):
        with contextlib.redirect_stderr(io.StringIO()), mock.patch.object(f, 'load_content_preview', side_effect=AssertionError('preview source touched')):
            with self.assertRaises(SystemExit) as error:
                f.main(['--finder-metadata', '--preview-request={}'])
        self.assertEqual(error.exception.code, 2)

    @unittest.skipUnless(sys.platform == 'darwin', 'Darwin extended attributes')
    def test_cli_real_tags_and_comment_match_with_json_proof(self):
        library = ctypes.CDLL(None, use_errno=True); setter = library.setxattr
        setter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        setter.restype = ctypes.c_int
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'synthetic.any-extension'; path.write_text('own fixture')
            for field, value in [('finderTags', ['Projekt Ä\n6']), ('finderComment', 'Kommentar 🌿')]:
                data = binary(value); buffer = ctypes.create_string_buffer(data)
                self.assertEqual(setter(os.fsencode(path), f.FINDER_ATTRIBUTES[field].encode(), buffer, len(data), 0, 1), 0)
            for field, pattern in [('finderTags', 'Projekt Ä'), ('finderComment', '🌿')]:
                question = json.dumps(dict(schemaVersion=3, root=self.leaf(field, pattern)))
                result = subprocess.run([sys.executable, f.__file__, '--json', '--criteria-json='+question, str(path)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                record = json.loads(result.stdout)
                self.assertEqual(record['criteriaEvidence'][0]['field'], field)
                self.assertEqual(record['finderMetadata']['fields'][field]['status'], 'available')
                self.assertNotIn('exiftool', result.stderr)


class FinderSnapshotFilterTest(unittest.TestCase):
    @staticmethod
    def record():
        generation = dict(device='1', inode='2', size='3', modifiedNS='1700000000123456789', changedNS='1700000000123456789')
        return dict(path='/missing/synthetic', filesystemPath='/missing/synthetic', type='file', isDirectory=False,
                    archiveMembers=[], size=3, modified=int(generation['modifiedNS']) / 1e9,
                    finderMetadata=dict(schemaVersion=1, sourceGeneration=generation,
                        fields=dict(finderTags=dict(status='available', values=[f.finder_tag('Projekt Ä\n6')]),
                                    finderComment=dict(status='available', value='Kommentar 🌿'))))

    def filtered(self, record, field='finderTags', negate=False):
        query = FinderCriteriaTest.query(FinderCriteriaTest.leaf(field, 'Projekt Ä' if field == 'finderTags' else '🌿', negate=negate))
        raw = json.dumps(record, ensure_ascii=False) + '\n'
        with mock.patch.object(f, 'read_finder_metadata', side_effect=AssertionError('frozen source read')), mock.patch.object(f.os, 'stat', side_effect=AssertionError('frozen stat')), mock.patch.object(f.os, 'lstat', side_effect=AssertionError('frozen lstat')):
            return list(f.iter_filtered_results(io.BytesIO(raw.encode()), query)), raw.rstrip('\n')

    def test_frozen_values_filter_without_source_and_preserve_original_jsonl(self):
        record = self.record(); record['opaqueFutureField'] = ['unchanged', 'Ä']
        for field in ['finderTags', 'finderComment']:
            results, original = self.filtered(record, field)
            self.assertEqual(results, [original])

    def test_missing_and_unknown_snapshots_do_not_satisfy_negative_criteria(self):
        record = self.record(); record.pop('finderMetadata')
        self.assertEqual(self.filtered(record, negate=True)[0], [])
        record = self.record(); record['finderMetadata']['fields']['finderTags'] = dict(status='absent')
        self.assertEqual(self.filtered(record, negate=True)[0], [])
        record['finderMetadata']['fields']['finderTags'] = dict(status='available', values=[])
        self.assertEqual(len(self.filtered(record, negate=True)[0]), 1)

    def test_corrupt_snapshot_values_and_generation_are_rejected(self):
        mutations = [lambda x: x['finderMetadata'].update(schemaVersion=2),
                     lambda x: x['finderMetadata'].update(sourceGeneration=None),
                     lambda x: x['finderMetadata']['sourceGeneration'].update(inode='-1'),
                     lambda x: x['finderMetadata']['sourceGeneration'].update(modifiedNS='0'),
                     lambda x: x['finderMetadata']['fields']['finderTags']['values'][0].update(color=False),
                     lambda x: x['finderMetadata']['fields']['finderTags']['values'][0].update(name='other'),
                     lambda x: x['finderMetadata']['fields'].update(finderTags=dict(status='absent', values=[]))]
        for mutation in mutations:
            record = self.record(); mutation(record)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.filtered(record)

    def test_archive_member_rejects_local_generation_even_without_member_chain(self):
        for members in [[], ['keep.txt']]:
            record = self.record(); record['type'] = 'member'; record['archiveMembers'] = members
            with self.subTest(members=members), self.assertRaises(ValueError):
                self.filtered(record)

    def test_unrequested_future_snapshot_stays_opaque(self):
        record = self.record(); record['finderMetadata'] = dict(schemaVersion=999, payload='preserve')
        raw = json.dumps(record)
        query = f.parse_criteria_query(dict(schemaVersion=1, root=dict(id='name', field='name', operator='equals', value='synthetic')))
        self.assertEqual(list(f.iter_filtered_results(io.BytesIO(raw.encode()), query)), [raw])

    def test_json_expansion_budget_is_not_a_truncated_known_tag_list(self):
        data = binary(['\x01' * 512] * 120)
        self.assertLess(len(data), f.MAX_FINDER_ATTRIBUTE_BYTES)
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(f.sys, 'platform', 'darwin'), mock.patch.object(f, 'finder_xattr', return_value=data):
            self.assertEqual(f.read_finder_metadata(directory, ['finderTags'])['fields'], dict(finderTags=dict(status='limited')))


class FinderSwiftTransportTest(unittest.TestCase):
    def test_snapshot_identity_ignores_json_format_but_keeps_value_bytes(self):
        import copy
        original = FinderSnapshotFilterTest.record()['finderMetadata']
        original['fields']['finderTags']['values'] = [f.finder_tag('Tag A\u0308\n6')]
        original['fields']['finderComment']['value'] = 'Kommentar A\u0308'
        values = [original]
        changed = copy.deepcopy(original); changed['fields']['finderTags']['values'] = [f.finder_tag('Tag Ä\n6')]; values.append(changed)
        changed = copy.deepcopy(original); changed['fields']['finderTags']['values'] = [f.finder_tag('Tag A\u0308\n4')]; values.append(changed)
        changed = copy.deepcopy(original); changed['fields']['finderComment']['value'] = 'Kommentar Ä'; values.append(changed)
        changed = copy.deepcopy(original); changed['fields']['finderComment'] = dict(status='absent'); values.append(changed)
        changed = copy.deepcopy(original); changed['sourceGeneration']['inode'] = '3'; values.append(changed)
        replies = self.run_frames([json.dumps(value, ensure_ascii=False, indent=2) for value in values], 'semantic')
        self.assertEqual([reply['sameAsFirst'] for reply in replies], [True] + [False] * (len(values) - 1))
        for reply in replies:
            self.assertTrue(reply['valid'] and reply['jsonChanged'] and reply['equalAfterCodec'] and reply['hashAfterCodec'])

    def test_csv_preserves_tag_arrays_colors_comment_newlines_and_status(self):
        record = FinderSnapshotFilterTest.record()
        tags = ['\ufeffTag A\u0308\r\n6', 'Tag, mit Komma\n4', 'Farblos']
        record['finderMetadata']['fields']['finderTags']['values'] = [f.finder_tag(tag) for tag in tags]
        record['finderMetadata']['fields']['finderComment']['value'] = '\ufeffKommentar, "Zitat"\nzweite Zeile 🌿'
        reply = self.run_frames([json.dumps(record, ensure_ascii=False)], 'csv')[0]
        raw = base64.b64decode(reply['csvBase64'])
        self.assertTrue(raw.startswith(b'\xef\xbb\xbf'))
        rows = list(csv.DictReader(io.StringIO(raw.decode('utf-8-sig'))))
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0]['finderTags']), [f.finder_tag(tag)['name'] for tag in tags])
        self.assertEqual(json.loads(rows[0]['finderTagColors']), [6, 4, None])
        self.assertEqual(rows[0]['finderComment'], record['finderMetadata']['fields']['finderComment']['value'])
        self.assertEqual(rows[0]['finderTagsStatus'], 'available')
        record['finderMetadata']['fields'] = dict(finderTags=dict(status='available', values=[]), finderComment=dict(status='absent'))
        reply = self.run_frames([json.dumps(record)], 'csv')[0]
        row = next(csv.DictReader(io.StringIO(base64.b64decode(reply['csvBase64']).decode('utf-8-sig'))))
        self.assertEqual(row['finderTags'], '[]')
        self.assertEqual(row['finderTagsStatus'], 'available')
        self.assertEqual(row['finderCommentStatus'], 'absent')

    def test_quick5_preserves_optional_snapshots_selection_and_combined_dates(self):
        record = FinderSnapshotFilterTest.record()
        record['finderMetadata']['fields']['finderComment']['value'] = '\ufeffKommentar A\u0308\nsecond'
        record['finderMetadata']['fields']['finderTags']['values'] = [f.finder_tag('\ufeffTag A\u0308\r\n6')]
        resolver = f.DateRangeResolver('2023-11-14T12:00:00Z')
        resolver.resolve(dict(kind='relative', timeZone='UTC', preset='today'), 'modified')
        record['testDateResolution'] = resolver.snapshot()
        for mode in ['quick', 'quick-dates']:
            reply = self.run_frames([json.dumps(record, ensure_ascii=False)], mode)[0]
            self.assertEqual(reply['version'], 5)
            for key in ['valid', 'temporaryConsumed', 'snapshotBytesPreserved', 'configurationPreserved', 'datesPreserved', 'selectionPreserved', 'legacyRejected']:
                self.assertTrue(reply[key], (mode, key, reply))

    def test_quick5_capability_rejects_bool_unknown_and_missing_support(self):
        for value in ['true', 'false', '0', '2', 'null']:
            reply = self.run_frames([json.dumps(FinderSnapshotFilterTest.record())], 'quick-cap-' + value)[0]
            self.assertFalse(reply['valid'], value)
            self.assertTrue(reply['temporaryConsumed'])

    def test_hit_roundtrip_preserves_original_snapshot_and_unicode(self):
        record = FinderSnapshotFilterTest.record()
        record['finderMetadata']['fields']['finderComment']['value'] = '\ufeffKommentar A\u0308\nzweite Zeile'
        record['finderMetadata']['fields']['finderTags']['values'] = [f.finder_tag('\ufeffTag A\u0308\r\n6')]
        reply = self.run_frames([json.dumps(record, ensure_ascii=False)], 'hit')[0]
        self.assertTrue(reply['valid'])
        self.assertTrue(reply['snapshotBytesPreserved'])
        self.assertEqual(json.loads(reply['jsonl'])['finderMetadata'], record['finderMetadata'])

    def test_hit_rejects_original_number_lexemes_and_conflicting_facts(self):
        raw = json.dumps(FinderSnapshotFilterTest.record())
        frames = [raw.replace('"schemaVersion": 1', '"schemaVersion": ' + value)
                  for value in ['1.0', '1e0', 'true']]
        record = FinderSnapshotFilterTest.record()
        record['size'] = int(record['finderMetadata']['sourceGeneration']['size']) + 1
        frames.append(json.dumps(record))
        record = FinderSnapshotFilterTest.record(); record['type'] = 'member'; record['archiveMembers'] = []
        frames.append(json.dumps(record))
        for size in [True, 3.0, 3.1, '3']:
            record = FinderSnapshotFilterTest.record(); record['size'] = size
            record['finderMetadata']['sourceGeneration']['size'] = '1' if size is True else '3'
            frames.append(json.dumps(record))
        for modified in [True, 'timestamp', []]:
            record = FinderSnapshotFilterTest.record(); record['modified'] = modified
            record['finderMetadata']['sourceGeneration']['modifiedNS'] = '1000000000' if modified is True else '1700000000123456789'
            frames.append(json.dumps(record))
        for created in [True, 'timestamp', []]:
            record = FinderSnapshotFilterTest.record(); record['created'] = created
            frames.append(json.dumps(record))
        self.assertEqual([r['valid'] for r in self.run_frames(frames, 'hit')], [False] * len(frames))

    def test_hit_preserves_large_integer_size_before_dictionary_roundtrip(self):
        record = FinderSnapshotFilterTest.record(); record['size'] = 2 ** 63 - 1
        record['finderMetadata']['sourceGeneration']['size'] = str(record['size'])
        reply = self.run_frames([json.dumps(record)], 'hit')[0]
        self.assertTrue(reply['valid'])
        self.assertEqual(json.loads(reply['jsonl'])['size'], record['size'])

    @staticmethod
    def run_frames(frames, mode="shape"):
        from swift_test_support import run_probe
        return json.loads(run_probe('finder-metadata', mode, input=json.dumps(frames)).stdout)

    def test_preserves_raw_json_unicode_and_crlf_tag_names(self):
        record = FinderSnapshotFilterTest.record()['finderMetadata']
        raw = ['Projekt A\u0308\n6', 'CR\r\n0', 'Ohne Farbe']
        record['fields']['finderTags']['values'] = [f.finder_tag(tag) for tag in raw]
        record['fields']['finderComment']['value'] = '\ufeffKommentar 1.0, 1e0 und "Text" 🌿'
        f.validate_finder_snapshot(record)
        frame = json.dumps(record, ensure_ascii=False, indent=2)
        result = self.run_frames([frame])[0]
        self.assertTrue(result['valid']); self.assertTrue(result['bytesPreserved'])
        self.assertEqual(result['tagRaw'], raw)
        self.assertEqual(result['tagNames'], [f.finder_tag(tag)['name'] for tag in raw])
        self.assertEqual(result['comment'], record['fields']['finderComment']['value'])

    def test_core_and_swift_reject_the_same_corrupt_snapshots(self):
        mutations = [lambda x: x.update(schemaVersion=True), lambda x: x.update(schemaVersion=1.0),
                     lambda x: x.update(sourceGeneration=None),
                     lambda x: x['sourceGeneration'].update(inode='0002'),
                     lambda x: x['sourceGeneration'].update(modifiedNS='-0'),
                     lambda x: x['fields']['finderTags']['values'][0].update(color=True),
                     lambda x: x['fields']['finderTags']['values'][0].update(color=6.0),
                     lambda x: x['fields']['finderTags']['values'][0].update(name='other'),
                     lambda x: x['fields']['finderTags']['values'][0].update(raw='Projekt A\u0308\n6', name='Projekt Ä'),
                     lambda x: x['fields']['finderTags']['values'][0].update(raw=''),
                     lambda x: x['fields'].update(finderComment=dict(status='absent', value='stale')),
                     lambda x: x['fields'].update(finderComment=dict(status='available', value='Ä' * 16385))]
        frames = []
        for mutation in mutations:
            value = FinderSnapshotFilterTest.record()['finderMetadata']; mutation(value)
            with self.assertRaises(ValueError): f.validate_finder_snapshot(value)
            frames.append(json.dumps(value, ensure_ascii=False))
        replies = self.run_frames(frames)
        self.assertTrue(all(not result['valid'] for result in replies), replies)

    def test_source_fact_binding_and_archive_boundary(self):
        value = FinderSnapshotFilterTest.record()['finderMetadata']
        valid = json.dumps(value)
        value['sourceGeneration']['size'] = '4'; wrong_size = json.dumps(value)
        value['sourceGeneration']['size'] = '3'; value['sourceGeneration']['modifiedNS'] = '0'; wrong_time = json.dumps(value)
        results = self.run_frames([valid, wrong_size, wrong_time], 'bound')
        self.assertEqual([row['valid'] for row in results], [True, False, False])
        self.assertFalse(self.run_frames([valid], 'archive')[0]['valid'])
        unknown = dict(schemaVersion=1, sourceGeneration=None, fields=dict(finderTags=dict(status='notApplicable')))
        self.assertTrue(self.run_frames([json.dumps(unknown)], 'archive')[0]['valid'])

    def test_empty_and_unknown_remain_distinct_and_duplicate_keys_fail(self):
        known = FinderSnapshotFilterTest.record()['finderMetadata']
        known['fields'] = dict(finderTags=dict(status='available', values=[]), finderComment=dict(status='available', value=''))
        unknown = dict(schemaVersion=1, sourceGeneration=None, fields=dict(finderTags=dict(status='absent'), finderComment=dict(status='notApplicable')))
        frames = [json.dumps(known), json.dumps(unknown), '{"schemaVersion":1,"schemaVersion":1,"sourceGeneration":null,"fields":{}}', '{"schemaVersion":1e0,"sourceGeneration":null,"fields":{}}']
        results = self.run_frames(frames)
        self.assertTrue(results[0]['valid'] and results[0]['knownEmptyTags'] and results[0]['knownEmptyComment'])
        self.assertTrue(results[1]['valid']); self.assertIsNone(results[1]['tagNames']); self.assertIsNone(results[1]['comment'])
        self.assertFalse(results[2]['valid']); self.assertFalse(results[3]['valid'])


if __name__ == '__main__':
    unittest.main()
