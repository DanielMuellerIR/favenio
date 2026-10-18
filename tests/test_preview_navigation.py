"""Gezielte Nachladeaufträge: unabhängige Originalbereiche und harte Grenzen."""
import json
import io
from pathlib import Path
from unittest import mock
import unittest
from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from test_content_preview import selected
from swift_test_support import run_probe, suite_binary


class NavigationTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        suite_binary()

    def hit(self, path, pattern='needle', options=()):
        code, rows, errors = run(['--json', '--content-preview', '--content', *options, pattern, str(path)])
        self.assertEqual(code, 0, errors)
        return json.loads(rows[0])

    def load(self, hit, occurrence=1, index=0, context=False, path=None):
        path = path or hit['filesystemPath']
        request = dict(schemaVersion=1, hit=hit, filePath=str(path), fileGeneration=favenio.source_generation(path),
                       queryIndex=index, occurrence=occurrence, context=context)
        return favenio.load_content_preview(request)['contentPreview']

    def test_repeated_matches_in_one_line_original_unicode_and_previous(self):
        path = self.write('source.txt', 'vorher\n😀 für Köln und für Köln\nzwischen\nFÜR Köln\ndanach\n')
        hit = self.hit(path, 'für Köln')
        for occurrence, line, raw in [(0,2,'für Köln'),(1,2,'für Köln'),(2,4,'FÜR Köln'),(1,2,'für Köln'),(0,2,'für Köln')]:
            value = self.load(hit, occurrence)
            self.assertEqual(value['snippets'][0]['line'], line)
            self.assertEqual(selected(value['snippets'][0]), raw)
        end = self.load(hit, 3)
        self.assertEqual(end['navigation']['reason'], 'end')
        self.assertEqual(end['snippets'], [])

    def test_terms_are_navigated_independently(self):
        hit = self.hit(self.write('multi.txt', 'needle\nother\nneedle\nother\n'), options=['--term','other'])
        for index, line in [(0,3),(1,4)]:
            value = self.load(hit, index=index)
            self.assertEqual(value['snippets'][0]['line'], line)
            self.assertEqual(value['snippets'][0]['termIndex'], index+1)

    def test_only_decisive_positive_criteria_are_available(self):
        path = self.write('criterion.txt', 'needle\nneedle\n')
        query = group('root','and', leaf('positive','content','contains','needle'), leaf('negative','content','contains','absent',negate=True))
        code, rows, errors = run(['--json','--content-preview',*arguments(query),str(path)])
        self.assertEqual(code,0,errors)
        hit=json.loads(rows[0]);self.assertEqual(len(hit['contentPreview']['snippets']),1)
        value=self.load(hit)
        self.assertEqual(value['snippets'][0]['criterionID'],'positive')
        self.assertEqual(value['snippets'][0]['line'],2)

    def test_context_is_only_on_request_and_bounded(self):
        path = self.write('context.txt', '\n'.join(['before'*100]*5+['needle']+['after'*100]*10000))
        hit=self.hit(path)
        short=self.load(hit,0);expanded=self.load(hit,0,context=True)
        self.assertEqual(short['navigation']['contextLines'],[])
        self.assertEqual([v['line'] for v in expanded['navigation']['contextLines']],[3,4,5,7,8,9])
        self.assertTrue(all(len(v['text'])<=256 for v in expanded['navigation']['contextLines']))
        self.assertLessEqual(expanded['navigation']['readBytes'],8192)

    def test_source_change_and_materialized_leaf_change_discard_positions(self):
        path=self.write('source.txt','needle\nneedle')
        hit=self.hit(path)
        Path(path).write_text('needle changed')
        value=self.load(hit)
        self.assertEqual(value['status'],'sourceChanged');self.assertEqual(value['snippets'],[])

    def test_descriptor_is_checked_before_and_after_read(self):
        path=self.write('change.txt','needle\nneedle')
        hit=self.hit(path)
        original=favenio.open_regular_file
        class Changed:
            def __enter__(self):
                self.handle=original(path);return self
            def fileno(self):return self.handle.fileno()
            def read(self,size):
                value=self.handle.read(size);Path(path).write_bytes(b'other');return value
            def __exit__(self,*args):self.handle.close()
        with mock.patch.object(favenio,'open_regular_file',lambda _:Changed()):
            value=self.load(hit)
        self.assertEqual(value['status'],'sourceChanged');self.assertEqual(value['snippets'],[])

    def test_read_limit_does_not_claim_end_or_absence(self):
        path=self.write('large.txt','needle\n'+'x'*100000+'\nneedle')
        hit=self.hit(path)
        with mock.patch.object(favenio,'PREVIEW_LOAD_BYTES',8192):value=self.load(hit)
        self.assertEqual(value['navigation']['reason'],'readLimit')
        self.assertEqual(value['navigation']['readBytes'],8192)
        with mock.patch.object(favenio,'PREVIEW_LOAD_SECONDS',0):value=self.load(hit)
        self.assertEqual(value['navigation']['reason'],'readLimit');self.assertEqual(value['navigation']['readBytes'],0)

    def test_minified_file_boundary_has_no_overlap_duplicates(self):
        text='x'*32765+'needle'+'x'*20000+'needle'+'x'*40000
        path=self.write('minified.txt',text);hit=self.hit(path)
        value=self.load(hit,1)
        self.assertEqual(selected(value['snippets'][0]),'needle')
        self.assertEqual(self.load(hit,2)['navigation']['reason'],'end')

    def test_utf16_and_zero_width_regex(self):
        path=Path(self.root,'utf16.txt');path.write_bytes(('😀 needle\r\nneedle').encode('utf-16'))
        hit=self.hit(path,options=['--encoding','auto'])
        value=self.load(hit)
        self.assertEqual(value['contentEncoding'],'utf-16-le');self.assertEqual(value['snippets'][0]['line'],2)
        path=self.write('regex.txt','abc\nabc')
        hit=self.hit(path,'(?=b)',options=['--regex'])
        value=self.load(hit)
        self.assertEqual(value['snippets'][0]['length'],0);self.assertEqual(value['snippets'][0]['line'],2)

    def test_cli_entry_returns_one_hit_without_searching(self):
        path=self.write('single.txt','needle\nneedle');hit=self.hit(path)
        request=dict(schemaVersion=1,hit=hit,filePath=str(path),fileGeneration=favenio.source_generation(path),queryIndex=0,occurrence=1)
        with mock.patch.object(favenio.Search,'search_path',side_effect=AssertionError('globale Suche')):
            code,rows,errors=run(['--preview-request',json.dumps(request)])
        self.assertEqual(code,0,errors);self.assertEqual(json.loads(rows[0])['contentPreview']['snippets'][0]['line'],2)
        code,_,errors=run(['--preview-request','{}'])
        self.assertEqual(code,2);self.assertIn('favenio: fehler: Nachladen',errors)

    def test_native_shared_controller_process_and_cancellation(self):
        hits=[self.hit(self.write(name,'needle\nmiddle\nneedle\nend')) for name in ['first.txt','second.txt']]
        rows=''.join(json.dumps(hit)+'\n' for hit in hits)
        core=Path(__file__).resolve().parent.parent/'favenio.py'
        report=json.loads(run_probe('content-preview','navigate',str(core),input=rows).stdout)
        self.assertTrue(all(report.values()),report)

    def test_catastrophic_regex_has_hard_time_limit(self):
        path=self.write('regex.txt','needle\n'+'a'*30000+'!')
        hit=self.hit(path,'needle|(a+)+$',options=['--regex'])
        with mock.patch.object(favenio,'PREVIEW_LOAD_SECONDS',0.05):
            value=self.load(hit)
        self.assertEqual(value['navigation']['reason'],'readLimit')

    def test_running_processes_are_killed_on_escape_off_selection_and_change(self):
        hits=[self.hit(self.write(name,'needle\nmiddle\nneedle')) for name in ['first.txt','second.txt']]
        wrapper=Path(self.root,'slow.py')
        wrapper.write_text('import os,signal,time\nfrom pathlib import Path\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nPath(__file__+".pid").write_text(str(os.getpid()))\ntime.sleep(30)\n')
        report=json.loads(run_probe('content-preview','cancel-load',str(wrapper),input=''.join(json.dumps(h)+'\n' for h in hits),timeout=20).stdout)
        self.assertTrue(all(report.values()),report)

    def test_original_bom_pattern_survives_native_reload_request(self):
        hit = self.hit(self.write('bom.txt', '\ufeffneedle\nmiddle\n\ufeffneedle\nend'), '\ufeffneedle')
        core = Path(__file__).resolve().parent.parent/'favenio.py'
        report = json.loads(run_probe('content-preview', 'navigate', str(core), input=json.dumps(hit)+'\n').stdout)
        self.assertTrue(all(report.values()), report)

    def test_nested_archive_materialization_retains_identity_and_budget(self):
        import zipfile
        inner=io.BytesIO()
        with zipfile.ZipFile(inner,'w') as archive:archive.writestr('odd!/für.txt','needle\nmiddle\nneedle')
        path=Path(self.root,'outer.zip')
        with zipfile.ZipFile(path,'w') as archive:archive.writestr('inner.zip',inner.getvalue())
        hit=self.hit(path,options=['--archive-depth','2','--max-archive-member-bytes','1048576'])
        self.assertEqual(hit['contentPreview']['archiveLimits']['memberBytes'],1048576)
        code,rows,errors=run(['--extract-json',json.dumps(hit),'--extract-root',self.root])
        self.assertEqual(code,0,errors)
        value=self.load(hit,path=rows[0])
        self.assertEqual(value['snippets'][0]['line'],3)
        self.assertEqual(selected(value['snippets'][0]),'needle')
        report=json.loads(run_probe('content-preview','navigate',str(Path(__file__).resolve().parent.parent/'favenio.py'),input=json.dumps(hit)+'\n').stdout)
        self.assertTrue(all(report.values()),report)

    def test_normalization_tail_is_not_a_false_fragment_match(self):
        # 40960 Zeichen ist die erste Stückgrenze bei 8192-Byte-Häppchen.
        path=self.write('tail.txt','a\n'+'x'*40959+'ä'+'x'*2000+'\na')
        hit=self.hit(path,'a')
        value=self.load(hit,1)
        self.assertEqual(value['snippets'][0]['line'],3)
        self.assertEqual(self.load(hit,2)['navigation']['reason'],'end')

    def test_utf8_bom_choice_is_preserved_when_reloading_first_line(self):
        import codecs
        path=Path(self.root,'bom.txt');path.write_bytes(codecs.BOM_UTF8+b'needle needle\nend')
        for options, prefix in [(['--encoding','auto'],False),([],True)]:
            hit=self.hit(path,options=options)
            report=json.loads(run_probe('content-preview','parse',input=json.dumps(hit)+'\n').stdout)
            self.assertEqual(report['requestedEncoding'],'auto' if options else 'utf-8')
            self.assertTrue(report['roundtrip'])
            for occurrence in [0,1]:
                value=self.load(hit,occurrence)
                snippet=value['snippets'][0]
                self.assertEqual(snippet['text'].startswith('\ufeff'),prefix)
                self.assertEqual(selected(snippet),'needle')
