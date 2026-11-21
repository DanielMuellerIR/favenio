"""Echte Linux-Sprachgrenze: Swift-Modelle und Suchprozess aus einem fremden Aufrufer."""
import base64
import ctypes
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
import zipfile


class SharedModelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = ctypes.CDLL(os.environ['FAVENIO_SHARED_LIBRARY'])
        cls.library.favenio_model.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        cls.library.favenio_model.restype = ctypes.c_void_p
        cls.library.favenio_model_free.argtypes = [ctypes.c_void_p]

    def call(self, **value):
        data = json.dumps(value, ensure_ascii=False).encode()
        pointer = self.library.favenio_model(data, len(data))
        self.assertTrue(pointer)
        try:
            return json.loads(ctypes.string_at(pointer))
        finally:
            self.library.favenio_model_free(pointer)

    def parse(self, **changes):
        hit = dict(path='/tmp/Bu\u0308ro.txt', filesystemPath='/tmp/Bu\u0308ro.txt',
                   type='file', archiveMembers=[], isDirectory=False)
        hit.update(changes)
        return self.call(operation='parse', line=json.dumps(hit, ensure_ascii=False))

    def tearDown(self):
        self.call(operation='cleanup')

    def test_original_unicode_identity_is_not_canonicalized(self):
        first = self.parse()['hit']
        second = self.parse(path='/tmp/Büro.txt', filesystemPath='/tmp/Büro.txt')['hit']
        self.assertNotEqual(first['id'], second['id'])
        self.assertEqual(first['name'], 'Bu\u0308ro.txt')

    def test_archive_bytes_disambiguate_identical_display_names(self):
        first = self.parse(type='member', archiveMembers=['bad-�.txt'], archiveMemberBytes=[base64.b64encode(b'bad-\xff.txt').decode()])
        second = self.parse(type='member', archiveMembers=['bad-�.txt'], archiveMemberBytes=[base64.b64encode(b'bad-\xfe.txt').decode()])
        self.assertNotEqual(first['hit']['id'], second['hit']['id'])

    def test_missing_directory_flag_is_rejected(self):
        value = dict(path='/tmp/test', filesystemPath='/tmp/test', type='file', archiveMembers=[])
        self.assertFalse(self.call(operation='parse', line=json.dumps(value))['ok'])

    def test_directory_inside_archive_is_not_openable(self):
        self.assertFalse(self.parse(type='member', archiveMembers=['folder/'], isDirectory=True)['hit']['openable'])

    def test_python_arguments_preserve_patterns_and_roots(self):
        result = self.call(operation='arguments', pattern='-needle', roots=['/tmp/a b'], options=[dict(name='mode', value='content'), dict(name='term', value='second')])
        self.assertTrue(result['ok'], result)
        self.assertIn('--term=second', result['arguments'])
        self.assertEqual(result['arguments'][-3:], ['--', '-needle', '/tmp/a b'])

    def test_real_stream_and_early_quick_limit(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-') as directory:
            for index in range(40):
                Path(directory, f'needle-{index}.txt').write_text('content needle\n')
            started = self.call(operation='start', pattern='needle', roots=[directory], options=[], quick=True)
            self.assertTrue(started['ok'], started)
            hits, ending = [], None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and ending is None:
                response = self.call(operation='poll', runID=started['runID'])
                for event in response['events']:
                    hits += event.get('hits', [])
                    if event['kind'] == 'finish':
                        ending = event
                time.sleep(.01)
            self.assertIsNotNone(ending)
            self.assertEqual(len(hits), 20)
            self.assertEqual(ending['state'], 'limitReached')

    def test_distinct_outer_posix_bytes_cross_the_swift_boundary(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-bytes-') as directory:
            for name in (b'bad-\xff.txt', b'bad-\xfe.txt'):
                with open(os.fsencode(directory) + b'/' + name, 'wb') as handle:
                    handle.write(b'needle')
            started = self.call(operation='start', pattern='bad-', roots=[directory], options=[])
            hits, ending = [], None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and ending is None:
                for event in self.call(operation='poll', runID=started['runID'])['events']:
                    hits += event.get('hits', [])
                    if event['kind'] == 'finish': ending = event
                time.sleep(.01)
            self.assertEqual(len(hits), 2)
            self.assertEqual(len({hit['id'] for hit in hits}), 2)
            self.assertEqual(len({hit['pathBytes'] for hit in hits}), 2)

    def test_invalid_pixel_input_cannot_start_a_search(self):
        result = self.call(operation='start', pattern='needle', roots=['/tmp'], options=[dict(name='minw', value='-12')])
        self.assertFalse(result['ok'])

    def test_new_run_discards_previous_events(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-') as directory:
            Path(directory, 'first').touch()
            old = self.call(operation='start', pattern='first', roots=[directory], options=[])
            new = self.call(operation='start', pattern='absent', roots=[directory], options=[])
            self.assertNotEqual(old['runID'], new['runID'])
            self.assertEqual(self.call(operation='poll', runID=old['runID'])['events'], [])

    def test_arrival_order_stays_consistent_across_projections_and_pages(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-arrival-') as directory:
            roots = []
            for filename in ('needle-z.txt', 'needle-a.txt', 'needle-m.txt'):
                path = Path(directory, filename)
                path.touch()
                roots.append(str(path))
            started = self.call(operation='start', pattern='needle', roots=roots, options=[])
            hits, ending = self.finish(started)
            self.assertEqual(ending['state'], 'finished')
            self.assertEqual([hit['path'] for hit in hits], roots)
            run = dict(runID=started['runID'], sort='arrival', ascending=False)
            current = self.call(operation='projection', mode='none', **run)
            self.assertTrue(current['arrivalPrefix'])
            self.assertEqual([row['index'] for row in current['rows']], [0, 1, 2])
            page = self.call(operation='page', offset=0, limit=3, **run)
            self.assertEqual([row.get('hit', row)['path'] for row in page['hits']], roots)
            by_name = self.call(operation='projection', runID=started['runID'], mode='none', sort='name')
            self.assertFalse(by_name['arrivalPrefix'])
            self.assertEqual([row['index'] for row in by_name['rows']], [1, 2, 0])
            grouped = self.call(operation='projection', mode='fileExtension', **run)
            self.assertFalse(grouped['arrivalPrefix'])
            self.assertEqual([row['index'] for row in grouped['rows'] if row['kind'] == 'hit'], [0, 1, 2])
            self.call(operation='remove', indices=[1])
            current = self.call(operation='projection', mode='none', **run)
            self.assertFalse(current['arrivalPrefix'])
            self.assertEqual([row['index'] for row in current['rows']], [0, 2])

    def test_sorted_selection_and_export_share_result_indices(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-order-') as directory:
            roots = [str(Path(directory, name)) for name in ('needle-b', 'needle-c', 'needle-a')]
            for name in roots:
                Path(name).touch()
            started = self.call(operation='start', pattern='needle', roots=roots, options=[])
            self.finish(started)
            run = dict(runID=started['runID'], sort='name', ascending=False)
            initial = self.call(operation='projection', **run)
            self.assertEqual([row['index'] for row in initial['rows']], [1, 0, 2])
            self.assertTrue(self.call(operation='remove', indices=[0])['ok'])
            page = self.call(operation='page', offset=0, limit=1, **run)
            self.assertEqual(page['count'], 2)
            self.assertTrue(page['hasMore'])
            self.assertEqual(page['nextOffset'], 1)
            result = self.call(operation='exportCurrent', format='pathsNUL', **run)
            self.assertEqual(base64.b64decode(result['data']), os.fsencode(roots[1]) + b'\0' + os.fsencode(roots[2]) + b'\0')
            invalid = self.call(operation='exportCurrent', format='pathsNUL', indices=['0'], **run)
            self.assertFalse(invalid['ok'], invalid)

    def test_parallel_pages_keep_their_own_sort_order(self):
        with tempfile.TemporaryDirectory(prefix="favenio-ffi-concurrent-") as directory:
            roots = [str(Path(directory, f"needle-{number:02d}.txt")) for number in reversed(range(16))]
            sizes = {path: index for index, path in enumerate(roots, start=1)}
            for path, size in sizes.items():
                Path(path).write_bytes(b"x" * size)
            started = self.call(operation="start", pattern="needle", roots=roots, options=[])
            hits, _ = self.finish(started)
            self.assertEqual([hit["path"] for hit in hits], roots)
            expected_paths = roots.copy()

            def check_page(number):
                ascending = number % 2 == 0
                offset = number % 8
                field = "name" if number % 4 < 2 else "size"
                page = self.call(operation="page", runID=started["runID"], sort=field,
                                 ascending=ascending, offset=offset, limit=5)
                key = sizes.__getitem__ if field == "size" else None
                expected = sorted(expected_paths, key=key, reverse=not ascending)[offset:offset + 5]
                self.assertTrue(page["ok"], page)
                self.assertEqual(page["count"], len(expected_paths))
                self.assertEqual([row.get("hit", row)["path"] for row in page["hits"]], expected)

            with ThreadPoolExecutor(max_workers=4) as workers:
                list(workers.map(check_page, range(24)))
                self.assertTrue(self.call(operation="remove", indices=[0, 7, 15])["ok"])
                expected_paths = [path for index, path in enumerate(roots) if index not in {0, 7, 15}]
                list(workers.map(check_page, range(24)))

    def test_sorted_page_includes_a_later_search_batch(self):
        with tempfile.TemporaryDirectory(prefix="favenio-ffi-later-batch-") as directory:
            root = Path(directory)
            first, later = [str(root / name) for name in ("needle-b", "needle-a")]
            ready = root / "resume"
            engine = root / "fixture.py"
            engine.write_text(
                "import json, time\nfrom pathlib import Path\n"
                "def hit(path):\n"
                "    print(json.dumps(dict(path=path, type='file', isDirectory=False, "
                "filesystemPath=path, archiveMembers=[])), flush=True)\n"
                f"hit({first!r})\n"
                "deadline = time.monotonic() + 10\n"
                f"while not Path({str(ready)!r}).exists():\n"
                "    if time.monotonic() >= deadline: raise SystemExit(2)\n"
                "    time.sleep(.01)\n"
                f"hit({later!r})\n",
                encoding="utf-8",
            )
            previous_engine = os.environ["FAVENIO_ENGINE"]
            try:
                os.environ["FAVENIO_ENGINE"] = str(engine)
                started = self.call(operation="start", pattern="needle", roots=[directory], options=[])
                self.assertTrue(started["ok"], started)
                parameters = dict(runID=started["runID"], sort="name", ascending=True, offset=0, limit=4)
                deadline = time.monotonic() + 8
                while True:
                    page = self.call(operation="page", **parameters)
                    self.assertTrue(page["ok"], page)
                    if page["count"] or time.monotonic() >= deadline:
                        break
                    time.sleep(.01)
                self.assertEqual([row.get("hit", row)["path"] for row in page["hits"]], [first])
                ready.touch()
                _, ending = self.finish(started)
                self.assertEqual(ending["state"], "finished")
                page = self.call(operation="page", **parameters)
                self.assertEqual(page["count"], 2, page)
                self.assertEqual([row.get("hit", row)["path"] for row in page["hits"]], [later, first])
            finally:
                self.call(operation="cleanup")
                os.environ["FAVENIO_ENGINE"] = previous_engine

    def finish(self, started):
        self.assertTrue(started['ok'], started)
        hits, ending = [], None
        stop = time.monotonic()+15
        while time.monotonic()<stop and ending is None:
            for event in self.call(operation='poll',runID=started['runID'])['events']:
                hits.extend(event.get('hits',[]))
                if event['kind']=='finish':ending=event
            time.sleep(.005)
        self.assertIsNotNone(ending)
        return hits, ending

    def test_raw_root_recording_group_filter_and_duplicate_roundtrip(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-full-') as directory:
            raw=os.fsencode(directory)+b'/root-\xff'
            os.mkdir(raw)
            for name in (b'needle-a.txt',b'needle-b.txt'):
                with open(raw+b'/'+name,'wb') as handle:handle.write(b'equal content')
            display=raw.decode('utf-8','replace')
            started=self.call(operation='start',pattern='needle',roots=[display],rootBytes=[base64.b64encode(raw).decode()],options=[])
            hits,ending=self.finish(started)
            self.assertEqual(len(hits),2)
            projection=self.call(operation='projection',runID=started['runID'],mode='fileExtension',sort='name')
            self.assertEqual(projection['rows'][0]['count'],2)
            capture=self.call(operation='captureRecording',indices=[1])
            self.assertTrue(capture['ok'],capture)
            opened=self.call(operation='openRecording',data=capture['data'])
            self.assertTrue(opened['ok'],opened)
            self.assertEqual(opened['configuration']['rootBytes'],[base64.b64encode(raw).decode()])
            self.assertEqual(opened['hits'][1]['id'],hits[1]['id'])
            check=self.call(operation='duplicates',indices=[0,1]);self.assertTrue(check['ok'],check)
            result=None;stop=time.monotonic()+15
            while time.monotonic()<stop and result is None:
                for event in self.call(operation='poll',runID=opened['runID'])['events']:
                    if event['kind'] in ('duplicateResult','duplicateError'):result=event
                time.sleep(.01)
            self.assertEqual(result['kind'],'duplicateResult',result)
            self.assertEqual(len(result['result']['groups']),1)
            query=json.dumps(dict(schemaVersion=1,root=dict(id='selected',field='name',operator='contains',value='-a')))
            filtered=self.call(operation='filter',criteria=query)
            self.assertTrue(filtered['ok'],filtered)
            result=None;stop=time.monotonic()+10
            while time.monotonic()<stop and result is None:
                for event in self.call(operation='poll',runID=opened['runID'])['events']:
                    if event['kind']=='filtered':result=event
                time.sleep(.01)
            self.assertIsNotNone(result)
            self.assertNotIn('error',result,result)
            projection=self.call(operation='projection',runID=opened['runID'],mode='none',sort='path')
            self.assertEqual(projection['visible'],1,projection)
            arrival=self.call(operation='projection',runID=opened['runID'],mode='none',sort='arrival')
            self.assertEqual(arrival['visible'],1,arrival)
            self.assertFalse(arrival['arrivalPrefix'])
            self.call(operation='resetFilter')
            self.assertEqual(self.call(operation='projection',runID=opened['runID'],mode='none',sort='path')['visible'],2)


    def test_duplicate_comparison_shares_archive_materialization_and_raw_source_guard(self):
        with tempfile.TemporaryDirectory(prefix='favenio-ffi-archive-') as directory:
            raw=os.fsencode(directory)+b'/root-\xff';os.mkdir(raw)
            for name in (b'needle-a.txt',b'needle-b.txt'):
                with open(raw+b'/'+name,'wb') as source:source.write(b'identical archive and native content')
            with zipfile.ZipFile(os.fsdecode(raw+b'/bundle.zip'),'w') as archive:
                archive.writestr('needle-in.txt',b'identical archive and native content')
            started=self.call(operation='start',pattern='needle',roots=[raw.decode('utf-8','replace')],rootBytes=[base64.b64encode(raw).decode()],options=[dict(name="archives",value="1")])
            hits,_=self.finish(started);self.assertEqual(len(hits),3)
            self.assertTrue(any(json.loads(hit['raw'])['hit']['archiveMembers'] for hit in hits))
            self.assertTrue(self.call(operation='duplicates',indices=[0,1,2])['ok'])
            response=None;stop=time.monotonic()+15
            while time.monotonic()<stop and response is None:
                for event in self.call(operation='poll',runID=started['runID'])['events']:
                    if event['kind'] in ('duplicateResult','duplicateError'):response=event
                time.sleep(.01)
            self.assertIsNotNone(response);self.assertEqual(response['kind'],'duplicateResult',response)
            result=response['result'];self.assertTrue(result['complete'],result)
            self.assertEqual(len(result['groups']),1,result)
            self.assertEqual(len(result['groups'][0]['memberIDs']),3,result)
            self.assertTrue(result['groups'][0]['byteVerified'],result)

    def test_platform_requirements_are_not_silently_ignored(self):
        for option in ['finder-metadata','local-only']:
            result=self.call(operation='start',pattern='needle',roots=['/tmp'],options=[dict(name=option,value='1')])
            self.assertFalse(result['ok'])


    def test_shared_preview_load_uses_raw_native_path_and_rejects_changed_source(self):
        with tempfile.TemporaryDirectory(prefix='favenio-preview-bytes-') as directory:
            path=os.fsencode(directory)+b'/bad-\xff.txt'
            with open(path,'wb') as handle:handle.write(b'needle first\nneedle second\n')
            started=self.call(operation='start',pattern='needle',roots=[directory],options=[dict(name='mode',value='content')],contentPreview=True)
            hits,ending=self.finish(started)
            self.assertEqual(len(hits),1)
            loaded=self.call(operation='loadPreview',raw=hits[0]['raw'],queryIndex=0,occurrence=1,context=True)
            self.assertTrue(loaded['ok'],loaded)
            response=None;stop=time.monotonic()+10
            while time.monotonic()<stop and response is None:
                for event in self.call(operation='poll',runID=started['runID'])['events']:
                    if event['kind']=='preview':response=event
                time.sleep(.01)
            self.assertIsNotNone(response)
            self.assertNotIn('error',response,response)
            self.assertIn('second',response['preview']['snippets'][0]['text'])
            with open(path,'wb') as handle:handle.write(b'changed')
            self.assertFalse(self.call(operation='previewStatus',raw=hits[0]['raw'])['ok'])


if __name__ == '__main__':
    unittest.main()
