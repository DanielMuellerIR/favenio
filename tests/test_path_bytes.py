"""Versionierter POSIX-Pfadtransport trennt Anzeige und ausführbare Identität."""
import base64
import json
import os
from pathlib import Path
import sys
import unittest

from test_favenio import TempTreeTest, run, favenio
import io


class PathBytesTests(TempTreeTest):
    def test_new_transport_is_explicit_and_old_stream_unchanged(self):
        path = self.write('Büro.txt', 'needle')
        code, rows, errors = run(['--json', 'Büro', self.root])
        legacy = json.loads(rows[0])
        self.assertEqual((code, errors), (0, ''))
        self.assertNotIn('filesystemPathBytes', legacy)
        code, rows, errors = run(['--json', '--json-path-bytes', 'Büro', self.root])
        envelope = json.loads(rows[0])
        self.assertEqual((code, errors), (0, ''))
        self.assertEqual(envelope['type'], 'hitV2')
        self.assertNotIn('path', envelope)
        self.assertNotIn('isDirectory', envelope)
        hit = envelope['hit']
        self.assertEqual(base64.b64decode(hit.pop('filesystemPathBytes')), os.fsencode(path))
        self.assertEqual(base64.b64decode(hit.pop('searchRootPathBytes')), os.fsencode(self.root))
        self.assertEqual(hit, legacy)

    def test_result_filter_preserves_versioned_identity_and_root(self):
        self.write('source.txt', 'needle')
        code, rows, errors = run(['--json', '--json-path-bytes', 'source', self.root])
        self.assertEqual((code, errors), (0, ''))
        query = favenio.parse_criteria_query(dict(schemaVersion=1, root=dict(id='name', field='name', operator='contains', value='source')))
        filtered = list(favenio.iter_filtered_results(io.StringIO(rows[0] + '\n'), query))
        self.assertEqual(filtered, rows)

    def test_path_bytes_requires_json(self):
        code, rows, errors = run(['--json-path-bytes', 'needle', self.root])
        self.assertEqual((code, rows), (2, []))
        self.assertIn('--json', errors)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux-Dateisystem erforderlich')
    def test_distinct_invalid_names_remain_distinct_and_extractable(self):
        for name, content in ((b'bad-\xff.txt', b'first'), (b'bad-\xfe.txt', b'second')):
            with open(os.fsencode(self.root) + b'/' + name, 'wb') as handle:
                handle.write(content)
        code, rows, errors = run(['--json', '--json-path-bytes', 'bad-', self.root])
        self.assertEqual((code, errors), (0, ''))
        hits = [json.loads(row) for row in rows]
        self.assertEqual(len(hits), 2)
        self.assertEqual(len({h['hit']['filesystemPath'] for h in hits}), 1)
        self.assertEqual(len({h['hit']['filesystemPathBytes'] for h in hits}), 2)
        contents = set()
        for hit in hits:
            code, paths, errors = run(['--extract-json', json.dumps(hit)])
            self.assertEqual((code, errors), (0, ''))
            with open(os.fsencode(paths[0]), 'rb') as handle:
                contents.add(handle.read())
        self.assertEqual(contents, {b'first', b'second'})

    def test_mismatched_display_cannot_redirect_extraction(self):
        path = self.write('source.txt', 'needle')
        hit = dict(type='file', path=path, filesystemPath=path, archiveMembers=[], isDirectory=False,
                   filesystemPathBytes=base64.b64encode(os.fsencode(path + '.other')).decode())
        code, paths, errors = run(['--extract-json', json.dumps(hit)])
        self.assertEqual((code, paths), (2, []))
        self.assertIn('widerspricht', errors)

    def test_nul_and_invalid_base64_are_rejected(self):
        path = self.write('source.txt', 'needle')
        for raw in ['???', base64.b64encode(b'a\0b').decode(), '']:
            hit = dict(filesystemPath=path, filesystemPathBytes=raw, archiveMembers=[])
            code, paths, _ = run(['--extract-json', json.dumps(hit)])
            self.assertEqual((code, paths), (2, []))
