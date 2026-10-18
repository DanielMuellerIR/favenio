"""ODT-/EPUB-Projektion: Reihenfolge, Grenzen, Quellen und gemeinsame Vorschau."""
import io
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
import tarfile
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from package_text_fixture import odt_bytes, odt_xml, epub_bytes, html, package, OPF, CONTAINER
from swift_test_support import run_probe, suite_binary

REPO = Path(__file__).resolve().parents[1]

class PackageTextTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        suite_binary()

    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, FAVENIO_PDF_HELPER='')
        patch.start(); self.addCleanup(patch.stop)
        self.odt = Path(self.root, 'report.odt')
        self.epub = Path(self.root, 'report.epub')
        self.odt.write_bytes(odt_bytes('<text:p>Jahres<text:span>bericht</text:span> 😀 fu&#x308;r &amp; Text</text:p><text:p>Kontextmitte</text:p><table:table><table:table-row><table:table-cell><text:p>Zweites Jahresbericht</text:p></table:table-cell></table:table-row></table:table>'))
        self.epub.write_bytes(epub_bytes())

    def search(self, path, *options, pattern='Jahresbericht'):
        code, lines, errors = run(['--json', '--search-report', '--content-preview', '--document-text', *options, pattern, str(path)])
        records = [json.loads(line) for line in lines]
        return code, [item for item in records if item['type'] != 'searchReport'], records[-1], errors

    def negative(self, path):
        return run(['--json','--document-text',*arguments(leaf('n','content',value='absent',negate=True)),str(path)])

    def request(self, path, hit, occurrence=1, context=False):
        return dict(schemaVersion=1,hit=hit,filePath=str(path),fileGeneration=favenio.source_generation(str(path)),queryIndex=0,occurrence=occurrence,context=context)

    def test_inline_projection_and_spine_order_differ_from_catalog(self):
        for path, kind, part in [(self.odt,'odtParagraph','content.xml'),(self.epub,'epubParagraph','OPS/z.xhtml')]:
            code,hits,report,errors=self.search(path)
            self.assertEqual((code,errors),(0,''));self.assertEqual(len(hits),1)
            hit=hits[0];position=hit['documentPosition']
            self.assertEqual((position['kind'],position['part'],position['paragraph'],position['line']),(kind,part,1,1))
            if path==self.epub:self.assertEqual(position['chapter'],1)
            self.assertEqual(hit['contentEncoding'],path.suffix[1:]+'-text-v1')
            self.assertEqual(hit['contentPreview']['snippets'][0]['query']['documentReader'],path.suffix[1:]+'-v1')
            self.assertIn('😀 fu\u0308r & Text',hit['contentPreview']['snippets'][0]['text'])
            self.assertEqual(report['coverage'],'withinRequestedScope')

    def test_odt_tables_annotations_changes_and_technical_text(self):
        self.odt.write_bytes(odt_bytes('<text:p text:style-name="ATTRIBUTE_ONLY">A<office:annotation><text:p>ANNOTATION_ONLY</text:p></office:annotation>B</text:p><text:tracked-changes><text:p>CHANGES_ONLY</text:p></text:tracked-changes><text:p>C</text:p>'))
        self.assertEqual(self.search(self.odt,pattern='AB')[0],0)
        for word in ['ATTRIBUTE_ONLY','ANNOTATION_ONLY','CHANGES_ONLY','text:p']:
            self.assertEqual(self.search(self.odt,pattern=word)[0],1,word)

    def test_odt_spaces_tabs_and_line_breaks(self):
        self.odt.write_bytes(odt_bytes('<text:p>A<text:s text:c="3"/>B<text:tab/>C<text:line-break/>D</text:p>'))
        hit=self.search(self.odt,pattern='A   B\tC')[1][0]
        self.assertEqual(hit['contentPreview']['snippets'][0]['text'],'A   B\tC')
        self.assertEqual(self.search(self.odt,pattern='D')[1][0]['documentPosition']['line'],2)

    def test_epub_entities_inline_whitespace_pre_and_cell_boundaries(self):
        self.epub.write_bytes(epub_bytes(first=html('<p>Jahres<em>bericht</em>  A\n <b>B</b>&nbsp;&copy;</p><pre>C  D\nE</pre><table><tr><td>linke</td><td>rechte</td></tr></table>')))
        for word in ['Jahresbericht A B\xa0©','C  D','linke','rechte']:
            self.assertEqual(self.search(self.epub,pattern=word)[0],0,word)
        self.assertEqual(self.search(self.epub,pattern='linkerechte')[0],1)
        self.assertEqual(self.search(self.epub,'--regex',pattern='^E$')[1][0]['documentPosition']['line'],2)

    def test_epub_navigation_auxiliary_scripts_styles_and_attributes_excluded(self):
        manifest='<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="z" href="z.xhtml" media-type="application/xhtml+xml"/><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
        self.epub.write_bytes(epub_bytes(first=html('<p title="ATTRIBUTE_ONLY">Visible</p><script>SCRIPT_ONLY</script><style>STYLE_ONLY</style><nav>NAV_ONLY</nav><p hidden="hidden">HIDDEN_ONLY</p>'),second=html('<p>AUX_ONLY</p>'),manifest=manifest,spine='<itemref idref="nav"/><itemref idref="z"/><itemref idref="a" linear="no"/>',extra=[('OPS/nav.xhtml',html('<p>WHOLE_NAV_ONLY</p>'))]))
        self.assertEqual(self.search(self.epub,pattern='Visible')[1][0]['documentPosition']['chapter'],2)
        for word in ['TITLE_ONLY','ATTRIBUTE_ONLY','SCRIPT_ONLY','STYLE_ONLY','NAV_ONLY','AUX_ONLY','HIDDEN_ONLY','WHOLE_NAV_ONLY']:
            self.assertEqual(self.search(self.epub,pattern=word)[0],1,word)
        self.assertEqual(self.negative(self.epub)[0],0)

    def test_paragraphs_do_not_form_one_search_line(self):
        for path,data in [(self.odt,odt_bytes('<text:p>Jahres</text:p><text:p>bericht</text:p>')),(self.epub,epub_bytes(first=html('<p>Jahres</p><p>bericht</p>'),second=html('')))]:
            path.write_bytes(data);self.assertEqual(self.search(path)[0],1)

    def test_multiple_terms_and_mixed_criteria(self):
        for path in [self.odt,self.epub]:
            code,hits,_,errors=self.search(path,'--term=Kontextmitte')
            self.assertEqual(code,0,errors);self.assertEqual(hits[0]['terms'][1]['documentPosition']['paragraph'],2)
            tree=group('r','and',leaf('name','name',value='report'),leaf('path','relativePath',value=path.name),leaf('body','content',value='Zweites'))
            code,rows,errors=run(['--json','--document-text',*arguments(tree),str(path)])
            self.assertEqual(code,0,errors);self.assertIn('documentPosition',json.loads(rows[0])['criteriaEvidence'][-1])

    def test_cheap_or_does_not_open_package(self):
        tree=group('r','or',leaf('name','name',value='report'),leaf('body','content',value='absent'))
        with mock.patch.object(favenio.ZIPDocumentReader,'catalog',side_effect=AssertionError('ungefragter Leser')):
            for path in [self.odt,self.epub]:self.assertEqual(run(['--document-text',*arguments(tree),str(path)])[0],0)

    def test_navigation_context_and_source_change(self):
        for path in [self.odt,self.epub]:
            hit=self.search(path)[1][0]
            value=favenio.load_content_preview(self.request(path,hit))['contentPreview']
            position=value['snippets'][0]['documentPosition']
            self.assertEqual(position['paragraph'],3 if path==self.odt else 1)
            if path==self.epub:self.assertEqual((position['chapter'],position['part']),(2,'OPS/a.xhtml'))
            value=favenio.load_content_preview(self.request(path,hit,0,True))['contentPreview']
            self.assertEqual(value['navigation']['contextLines'][0]['documentPosition']['paragraph'],2)
            request=self.request(path,hit);path.write_bytes(b'changed')
            self.assertEqual(favenio.load_content_preview(request)['contentPreview']['status'],'sourceChanged')

    def test_sources_changed_during_projection_are_rejected(self):
        for path,reader in [(self.odt,favenio.ODTTextReader),(self.epub,favenio.EPUBTextReader)]:
            original=reader.sections
            def changed(instance,*args):
                for section in original(instance,*args):
                    path.write_bytes(b'changed');yield section
            with mock.patch.object(reader,'sections',changed):
                code,hits,report,errors=self.search(path)
            self.assertEqual(code,1);self.assertFalse(hits);self.assertIn('documentSourceChanged',[item['id'] for item in report['reasons']])

    def test_missing_chapter_is_unknown_but_later_positive_can_match(self):
        self.epub.write_bytes(epub_bytes(spine='<itemref idref="missing"/><itemref idref="z"/>'))
        result=self.search(self.epub);self.assertEqual(result[1][0]['documentPosition']['chapter'],2)
        self.assertEqual(result[2]['coverage'],'incomplete');self.assertIn('documentReadError',[x['id'] for x in result[2]['reasons']])
        self.assertEqual(self.negative(self.epub)[0],1)
        # Nach frühem Beleg werden spätere Defekte nicht für den Bericht gelesen.
        self.epub.write_bytes(epub_bytes(second='<broken>'))
        self.assertEqual(self.search(self.epub)[2]['coverage'],'withinRequestedScope')
        self.assertEqual(self.negative(self.epub)[0],1)

    def test_corrupt_directories_xml_and_html_never_prove_absence(self):
        variants=[(self.odt,b'broken'),(self.odt,odt_bytes('<broken',raw=True)),(self.odt,odt_bytes('<!DOCTYPE x [<!ENTITY a "boom">]><x/>',raw=True)),(self.odt,odt_bytes(extra=[('content.xml','duplicate')])),(self.epub,epub_bytes(first=html('<p>wrong</div>'),second=html(''))),(self.epub,epub_bytes(first=html('<p>&unknown;</p>'),second=html(''))),(self.epub,package([('META-INF/container.xml','<broken>')])),(self.epub,epub_bytes(manifest='<item id="z" href="../../../escape" media-type="application/xhtml+xml"/>'))]
        for path,data in variants:
            with self.subTest(path=path,data=data[:20]):
                path.write_bytes(data);code,hits,report,errors=self.search(path,pattern='absent')
                self.assertEqual(code,1);self.assertFalse(hits);self.assertIn('documentDamaged',[item['id'] for item in report['reasons']]);self.assertEqual(self.negative(path)[0],1)

    def test_limits_and_internal_archive_budgets(self):
        for path in [self.odt,self.epub]:
            for constant,limit in [('DOCUMENT_BYTES',10),('DOCUMENT_ZIP_ENTRIES',1),('DOCUMENT_CATALOG_BYTES',10),('DOCUMENT_METADATA_BYTES',10),('DOCUMENT_XML_BYTES',10),('DOCUMENT_TOTAL_XML_BYTES',10),('DOCUMENT_PARAGRAPH_BYTES',3),('DOCUMENT_TEXT_BYTES',3),('DOCUMENT_PARAGRAPHS',0),('DOCUMENT_XML_DEPTH',2)]:
                with self.subTest(path=path,constant=constant),mock.patch.object(favenio,constant,limit):
                    code,hits,report,_=self.search(path);self.assertEqual(code,1);self.assertFalse(hits);self.assertIn('documentLimit',[x['id'] for x in report['reasons']]);self.assertEqual(self.negative(path)[0],1)
            self.assertEqual(self.search(path,'--max-archive-total-bytes=10')[0],1)
        with mock.patch.object(favenio,'DOCUMENT_PARTS',0):self.assertEqual(self.search(self.epub)[0],1)

    def test_first_hit_does_not_scan_whole_document(self):
        for path,reader,data in [(self.odt,favenio.ODTTextReader,odt_bytes('<text:p>Jahresbericht</text:p>'+('<text:p>'+'x'*1000+'</text:p>')*4000)),(self.epub,favenio.EPUBTextReader,epub_bytes(first=html('<p>Jahresbericht</p>'+('<p>'+'x'*1000+'</p>')*4000)))]:
            path.write_bytes(data);original=reader.chunks;read=[]
            def chunks(instance,archive,name,metadata=False):
                for chunk in original(instance,archive,name,metadata):
                    if not metadata:read.append(len(chunk))
                    yield chunk
            with mock.patch.object(reader,'chunks',chunks):self.assertEqual(self.search(path)[0],0)
            self.assertLess(sum(read),100000)

    def test_archived_documents_keep_raw_identity_and_respect_depth(self):
        for path in [self.odt,self.epub]:
            outer=Path(self.root,'archive.tar')
            with tarfile.open(outer,'w') as archive:
                info=tarfile.TarInfo('folder!/bad-\udcff'+path.suffix);data=path.read_bytes();info.size=len(data);archive.addfile(info,io.BytesIO(data))
            code,hits,_,errors=self.search(outer)
            self.assertEqual(code,0,errors);self.assertEqual(len(hits),1);self.assertIn('archiveMemberBytes',hits[0]);self.assertIn('folder!/',hits[0]['archiveMembers'][0])
            self.assertEqual(self.search(outer,'--archive-depth=0')[0],1)
            self.assertEqual(self.search(path,'--no-archives')[0],0)

    def test_raw_archive_mode_remains_technical(self):
        for path in [self.odt,self.epub]:
            code,rows,errors=run(['--json','--content','text:span' if path==self.odt else 'TITLE_ONLY',str(path)])
            self.assertEqual(code,0,errors);self.assertTrue(json.loads(rows[0])['archiveMembers'])

    def test_xml_encoding_and_original_unicode(self):
        self.odt.write_bytes(odt_bytes(('<?xml version="1.0" encoding="UTF-16"?>'+odt_xml('<text:p>Jahresbericht fu&#x308;r</text:p>')).encode('utf-16'),raw=True))
        self.epub.write_bytes(epub_bytes(first=('<?xml version="1.0" encoding="UTF-16"?>'+html('<p>Jahresbericht fu&#x308;r</p>')).encode('utf-16')))
        for path in [self.odt,self.epub]:self.assertIn('fu\u0308r',self.search(path,'--encoding=windows-1252')[1][0]['contentPreview']['snippets'][0]['text'])

    def test_empty_valid_projection_proves_negative(self):
        self.odt.write_bytes(odt_bytes(''));self.epub.write_bytes(epub_bytes(first=html(''),second=html('')))
        for path in [self.odt,self.epub]:self.assertEqual(self.negative(path)[0],0)

    def test_actual_paragraph_catalog_metadata_and_depth_caps(self):
        cases = [
            (self.odt, odt_bytes('<text:p>'+'x'*(256*1024+1)+'</text:p>')),
            (self.odt, odt_bytes('<text:p/>'*32769)),
            (self.epub, epub_bytes(first=html('<div>'*128+'x'+'</div>'*128))),
            (self.epub, package([('entry'+str(i),'') for i in range(4097)])),
            (self.epub, package([('META-INF/container.xml','x'*(256*1024+1))])),
            (self.epub, epub_bytes(first=html('<!--'+'x'*(8*1024*1024)+'-->'))),
        ]
        for path,data in cases:
            with self.subTest(path=path,bytes=len(data)):
                path.write_bytes(data)
                code,hits,report,_=self.search(path,'--max-archive-ratio=100000',pattern='absent')
                self.assertEqual(code,1);self.assertFalse(hits);self.assertIn('documentLimit',[x['id'] for x in report['reasons']])
        with self.odt.open('wb') as output:output.truncate(64*1024*1024+1)
        self.assertIn('documentLimit',[x['id'] for x in self.search(self.odt)[2]['reasons']])

    def test_actual_chapter_text_and_total_xml_caps(self):
        def many(count,body):
            entries=[('META-INF/container.xml',f'<container xmlns="{CONTAINER}"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')]
            manifest=''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(count))
            spine=''.join(f'<itemref idref="c{i}"/>' for i in range(count))
            entries.append(('book.opf',f'<package xmlns="{OPF}"><manifest>{manifest}</manifest><spine>{spine}</spine></package>'))
            entries.extend((f'c{i}.xhtml',html(body)) for i in range(count))
            return package(entries)
        for count,body in [(65,''),(40,'<p>'+'x'*230000+'</p>'),(5,'<!--'+'x'*(7*1024*1024)+'-->')]:
            with self.subTest(chapters=count):
                self.epub.write_bytes(many(count,body))
                result=self.search(self.epub,'--max-archive-ratio=100000',pattern='absent')
                self.assertEqual(result[0],1);self.assertIn('documentLimit',[x['id'] for x in result[2]['reasons']])

    def test_timeout_and_cancel_clean_owned_materialization(self):
        for path,create in [(self.odt,lambda:odt_bytes('<text:p>'+'a'*20000+'X</text:p>')),(self.epub,lambda:epub_bytes(first=html('<p>'+'a'*20000+'X</p>')))]:
            path.write_bytes(create())
            with mock.patch.object(favenio,'DOCUMENT_SECONDS',0.02):
                result=self.search(path,'--regex',pattern='(a+)+$')
                self.assertEqual(result[0],1);self.assertIn('documentTimeout',[x['id'] for x in result[2]['reasons']])
            outer=Path(self.root,'cancel.zip')
            with zipfile.ZipFile(outer,'w') as archive:archive.writestr(path.name,path.read_bytes())
            scratch=Path(self.root,'scratch');scratch.mkdir(exist_ok=True)
            process=subprocess.Popen([sys.executable,str(REPO/'favenio.py'),'--document-text','--regex','(a+)+$',str(outer)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,TMPDIR=str(scratch)))
            try:
                end=time.monotonic()+4
                while not list(scratch.glob('*'+path.suffix)) and process.poll() is None and time.monotonic()<end:time.sleep(.01)
                self.assertTrue(list(scratch.glob('*'+path.suffix)))
                process.send_signal(signal.SIGTERM);process.communicate(timeout=3)
                self.assertFalse(list(scratch.glob('*'+path.suffix)))
            finally:
                if process.poll() is None:process.kill();process.communicate()

    def test_swift_navigation_roundtrip_and_csv_for_both_formats(self):
        for path in [self.odt,self.epub]:
            hit=self.search(path)[1][0]
            result=run_probe('content-preview',path.suffix[1:],str(REPO/'favenio.py'),input=json.dumps(hit)+'\n')
            self.assertEqual(result.returncode,0,result.stderr)
            report=json.loads(result.stdout)
            for key in ['partByteIdentity','roundtrip','positionExport','location','csv','configuration','initial','next','previous','context','offCancels']:
                self.assertTrue(report[key],(key,report))

    def test_swift_rejects_untrusted_locators_and_readers(self):
        for path,changes in [(self.odt,[{'part':'other.xml'},{'paragraph':0},{'chapter':1}]),(self.epub,[{'part':'../escape'},{'chapter':0},{'chapter':4097},{'paragraph':True}])]:
            hit=self.search(path)[1][0]
            for change in changes:
                value=json.loads(json.dumps(hit));value['documentPosition'].update(change)
                with self.assertRaises(RuntimeError):
                    run_probe('content-preview','roundtrip',input=json.dumps(value)+'\n')
            value=json.loads(json.dumps(hit));value['contentPreview']['snippets'][0]['query']['documentReader']='pdfkit-v1'
            result=run_probe('content-preview','parse',input=json.dumps(value)+'\n')
            self.assertEqual(json.loads(result.stdout)['status'],'invalid')

if __name__ == '__main__':unittest.main()
