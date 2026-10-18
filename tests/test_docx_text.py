"""DOCX-Projektion, begrenzter Frühabbruch und Teil-/Absatzbelege."""
import io
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tarfile
import time
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run
from test_criteria import arguments, group, leaf
from docx_fixture import docx_bytes, paragraph, part_xml, WORD, REL, OFFICE_REL
from swift_test_support import run_probe, suite_binary

REPO = Path(__file__).resolve().parents[1]


class DOCXTextTests(TempTreeTest):
    @classmethod
    def setUpClass(cls):
        suite_binary()

    def setUp(self):
        super().setUp()
        patch = mock.patch.dict(os.environ, FAVENIO_PDF_HELPER='')
        patch.start(); self.addCleanup(patch.stop)
        self.path = Path(self.root, 'report.docx')
        self.path.write_bytes(docx_bytes(paragraph('Jahres', 'bericht') + paragraph('zwischen 😀 fu\u0308r & < >') +
            '<w:tbl><w:tr><w:tc>' + paragraph('Tabelle Jahresbericht') + '</w:tc></w:tr></w:tbl>'))

    def search(self, path=None, *options, pattern='Jahresbericht'):
        code, lines, errors = run(['--json', '--search-report', '--content-preview', '--document-text', *options, pattern, str(path or self.path)])
        records = [json.loads(line) for line in lines]
        return code, [item for item in records if item['type'] != 'searchReport'], records[-1], errors

    def request(self, hit, occurrence=1, context=False, path=None):
        path = str(path or self.path)
        return dict(schemaVersion=1, hit=hit, filePath=path, fileGeneration=favenio.source_generation(path),
                    queryIndex=0, occurrence=occurrence, context=context)

    def negative(self, path=None):
        return run(['--json', '--document-text', *arguments(leaf('negative', 'content', value='absent', negate=True)), str(path or self.path)])

    def test_split_runs_produce_one_document_hit_and_original_projection(self):
        code, hits, report, errors = self.search()
        self.assertEqual((code, errors), (0, ''))
        self.assertEqual(len(hits), 1)
        hit = hits[0]
        self.assertEqual(hit['archiveMembers'], [])
        self.assertEqual(hit['contentEncoding'], 'docx-text-v1')
        self.assertEqual(hit['documentPosition'], dict(kind='docxParagraph', part='word/document.xml', partKind='document', paragraph=1, line=1))
        self.assertEqual(hit['documentSourceGeneration'], favenio.source_generation(str(self.path)))
        self.assertEqual(hit['contentPreview']['snippets'][0]['query']['documentReader'], 'docx-v1')
        self.assertEqual(report['coverage'], 'withinRequestedScope')
        self.assertEqual(len(report['reportLimits']) > 0, True)

    def test_xml_attributes_tags_comments_and_instruction_text_are_not_visible_text(self):
        body = '<!-- COMMENT_ONLY --><w:p w:rsidR="ATTRIBUTE_ONLY"><w:r><w:rPr><w:color w:val="FORMAT_ONLY"/></w:rPr><w:instrText>INSTRUCTION_ONLY</w:instrText><w:t>visible</w:t></w:r></w:p>'
        self.path.write_bytes(docx_bytes(body, extra=[('word/comments.xml', part_xml(paragraph('COMMENT_PART_ONLY')))]))
        for pattern in ['ATTRIBUTE_ONLY', 'FORMAT_ONLY', 'COMMENT_ONLY', 'COMMENT_PART_ONLY', 'INSTRUCTION_ONLY', 'w:rPr']:
            self.assertEqual(self.search(pattern=pattern)[0], 1, pattern)
        self.assertEqual(self.search(pattern='visible')[0], 0)
        raw = run(['--json', '--content', 'ATTRIBUTE_ONLY', str(self.path)])
        self.assertEqual(raw[0], 0, raw[2]); self.assertEqual(json.loads(raw[1][0])['archiveMembers'], ['word/document.xml'])

    def test_tables_multiple_terms_entities_and_unicode_keep_individual_locators(self):
        code, hits, report, errors = self.search(None, '--term', 'Tabelle', '--term', 'FÜR')
        self.assertEqual(code, 0, errors)
        self.assertEqual([item['documentPosition']['paragraph'] for item in hits[0]['terms']], [1, 3, 2])
        text = hits[0]['contentPreview']['snippets'][2]['text']
        self.assertIn('😀 fu\u0308r & < >', text)
        result = run_probe('content-preview', 'parse', input=json.dumps(hits[0])+'\n')
        values = json.loads(result.stdout)
        self.assertTrue(values['roundtrip']); self.assertIn('fu\u0308r', values['marks'])

    def test_headers_footers_notes_are_labelled_and_separators_excluded(self):
        parts = [('header', 'word/header1.xml', part_xml(paragraph('Kopfbeleg'), 'header')),
                 ('footer', 'word/footer1.xml', part_xml(paragraph('Fußbeleg'), 'footer')),
                 ('footnotes', 'word/footnotes.xml', part_xml('<w:footnote w:type="separator">'+paragraph('separatorOnly')+'</w:footnote><w:footnote w:id="1">'+paragraph('Notenbeleg')+'</w:footnote>', 'footnote')),
                 ('endnotes', 'word/endnotes.xml', part_xml('<w:endnote w:id="1">'+paragraph('Endbeleg')+'</w:endnote>', 'endnote'))]
        self.path.write_bytes(docx_bytes(paragraph('Hauptbeleg'), parts))
        for pattern, kind in [('Kopfbeleg','header'),('Fußbeleg','footer'),('Notenbeleg','footnote'),('Endbeleg','endnote')]:
            code, hits, report, errors = self.search(pattern=pattern)
            self.assertEqual(code, 0, errors); self.assertEqual(hits[0]['documentPosition']['partKind'], kind)
        self.assertEqual(self.search(pattern='separatorOnly')[0], 1)

    def test_insertions_moves_and_field_results_follow_current_text_scope(self):
        self.path.write_bytes(docx_bytes('<w:p><w:del><w:r><w:delText>deletedOnly</w:delText><w:t>deletedT</w:t></w:r></w:del><w:moveFrom><w:r><w:t>oldMove</w:t></w:r></w:moveFrom><w:ins><w:r><w:t>inserted</w:t></w:r></w:ins><w:moveTo><w:r><w:t> moved</w:t></w:r></w:moveTo><w:r><w:instrText>instruction</w:instrText><w:t> result</w:t></w:r></w:p>'))
        self.assertEqual(self.search(pattern='inserted moved result')[0], 0)
        for word in ['deletedOnly','deletedT','oldMove','instruction']: self.assertEqual(self.search(pattern=word)[0], 1)

    def test_paragraphs_cells_parts_and_breaks_do_not_create_cross_boundary_matches(self):
        self.path.write_bytes(docx_bytes(paragraph('Jahres')+paragraph('bericht')+'<w:p><w:r><w:t>tab</w:t><w:tab/><w:t>break</w:t><w:br/><w:t>next</w:t></w:r></w:p>'))
        self.assertEqual(self.search()[0], 1)
        self.assertEqual(self.search(pattern='tab\tbreak')[0], 0)
        self.assertEqual(self.search(pattern='breaknext')[0], 1)
        self.assertEqual(self.search(pattern='next')[1][0]['documentPosition']['line'], 2)

    def test_strict_namespace_and_nonstandard_main_part(self):
        self.path.write_bytes(docx_bytes(part_xml(paragraph('Jahres','bericht'), namespace='http://purl.oclc.org/ooxml/wordprocessingml/main'), main='custom/text.xml'))
        self.assertEqual(self.search()[1][0]['documentPosition']['part'], 'custom/text.xml')

    def test_name_path_facts_and_criteria_share_one_projection(self):
        criteria = group('root','and',leaf('name','name',value='report'),leaf('path','relativePath',value='report.docx'),leaf('body','content',value='Tabelle'))
        original = favenio.DOCXTextReader.sections
        with mock.patch.object(favenio.DOCXTextReader,'sections',autospec=True,side_effect=original) as reader:
            code, rows, errors = run(['--json','--content-preview','--document-text','--min-size','1',*arguments(criteria),str(self.path)])
        self.assertEqual(code,0,errors); self.assertEqual(reader.call_count,1)
        hit=json.loads(rows[0]); self.assertEqual(hit['criteriaEvidence'][-1]['documentPosition']['paragraph'],3)

    def test_cheap_or_does_not_open_docx(self):
        criteria=group('root','or',leaf('name',value='report'),leaf('body','content',value='absent'))
        with mock.patch.object(favenio.DOCXTextReader,'sections',side_effect=AssertionError('ungefragtes Lesen')):
            code,rows,errors=run(['--json','--document-text',*arguments(criteria),str(self.path)])
        self.assertEqual(code,0,errors);self.assertNotIn('contentEncoding',json.loads(rows[0]))

    def test_early_positive_and_report_do_not_open_later_missing_part(self):
        self.path.write_bytes(docx_bytes(paragraph('Jahresbericht'), [('header','word/missing.xml',None)]))
        self.assertEqual(self.search()[0],0)
        code,hits,report,errors=self.search(pattern='absent')
        self.assertEqual((code,hits,report['coverage']),(1,[],'incomplete'))
        self.assertIn('documentDamaged',[item['id'] for item in report['reasons']])
        self.assertEqual(self.negative()[0],1)

    def test_early_read_does_not_scan_rest_of_xml(self):
        self.path.write_bytes(docx_bytes(paragraph('Jahresbericht')+paragraph('x'*1000)*4000))
        original=favenio.DOCXTextReader.chunks;read=[]
        def chunks(reader,archive,name,metadata=False):
            for chunk in original(reader,archive,name,metadata):
                if name=='word/document.xml':read.append(len(chunk))
                yield chunk
        with mock.patch.object(favenio.DOCXTextReader,'chunks',chunks):self.assertEqual(self.search()[0],0)
        self.assertEqual(sum(read),8192)

    def test_missing_damaged_duplicate_and_dtd_packages_remain_unknown(self):
        dtd = part_xml(paragraph('Jahresbericht')).replace(b'?>', b'?><!DOCTYPE w:document [<!ENTITY a "boom">]>', 1)
        variants=[b'broken',docx_bytes(b'<w:document>'),docx_bytes(dtd),docx_bytes(paragraph('Jahresbericht'),extra=[('word/document.xml',part_xml(paragraph('second')))])]
        for data in variants:
            self.path.write_bytes(data)
            code,hits,report,errors=self.search()
            self.assertEqual((code,hits,report['coverage']),(1,[],'incomplete'))
            self.assertIn('documentDamaged',[item['id'] for item in report['reasons']]);self.assertEqual(self.negative()[0],1)

    def test_limits_are_explicit_and_do_not_prove_absence(self):
        for constant,limit in [('DOCUMENT_BYTES',10),('DOCUMENT_ZIP_ENTRIES',1),('DOCUMENT_CATALOG_BYTES',10),('DOCUMENT_METADATA_BYTES',10),('DOCUMENT_XML_BYTES',10),('DOCUMENT_TOTAL_XML_BYTES',10),('DOCUMENT_PARAGRAPH_BYTES',3),('DOCUMENT_TEXT_BYTES',3),('DOCUMENT_PARAGRAPHS',0),('DOCUMENT_XML_DEPTH',2),('DOCUMENT_PARTS',0)]:
            with self.subTest(constant=constant),mock.patch.object(favenio,constant,limit):
                code,hits,report,errors=self.search()
                self.assertEqual((code,hits,report['coverage']),(1,[],'incomplete'))
                self.assertIn('documentLimit',[item['id'] for item in report['reasons']]);self.assertEqual(self.negative()[0],1)

    def test_internal_zip_parts_keep_archive_byte_and_ratio_budgets(self):
        for options,reason in [(('--max-archive-member-bytes','100'),'archiveMemberBytes'),(('--max-archive-total-bytes','100'),'archiveTotalBytes'),(('--max-archive-ratio','1'),'archiveRatio')]:
            code,hits,report,errors=self.search(None,*options)
            self.assertEqual((code,hits),(1,[]));self.assertIn(reason,[item['id'] for item in report['reasons']])

    def test_nested_docx_identity_depth_and_raw_name_bytes(self):
        inner=io.BytesIO()
        with zipfile.ZipFile(inner,'w') as archive:archive.writestr('folder!/report.docx',self.path.read_bytes())
        outer=Path(self.root,'outer.zip')
        with zipfile.ZipFile(outer,'w') as archive:archive.writestr('inner.zip',inner.getvalue())
        code,hits,report,errors=self.search(outer,'--archive-depth','2')
        self.assertEqual(code,0,errors);self.assertEqual(hits[0]['archiveMembers'],['inner.zip','folder!/report.docx'])
        self.assertEqual(len(hits[0]['archiveMemberBytes']),2)
        self.assertEqual(self.search(outer,'--archive-depth','1')[0],1)
        path=Path(self.root,'raw.tar')
        with tarfile.open(path,'w',format=tarfile.GNU_FORMAT,encoding='utf-8',errors='surrogateescape') as archive:
            info=tarfile.TarInfo('bad-\udcff.docx');data=self.path.read_bytes();info.size=len(data);archive.addfile(info,io.BytesIO(data))
        code,hits,report,errors=self.search(path)
        self.assertEqual(code,0,errors);self.assertTrue(hits[0]['archiveMemberBytes'])

    def test_direct_docx_with_archives_off_still_uses_document_projection(self):
        self.assertEqual(self.search(None,'--no-archives')[0],0)
        self.assertEqual(self.search(None,'--archive-depth','0')[0],0)

    def test_requested_encoding_bom_and_unicode_remain_in_evidence(self):
        self.path.write_bytes(docx_bytes(paragraph('\ufefffu\u0308r 😀 Jahresbericht')))
        code,hits,report,errors=self.search(None,'--encoding','auto',pattern='FÜR')
        self.assertEqual(code,0,errors);snippet=hits[0]['contentPreview']['snippets'][0]
        self.assertTrue(snippet['text'].startswith('\ufefffu\u0308r'));self.assertEqual(snippet['query']['encoding'],'auto')
        result=run_probe('content-preview','parse',input=json.dumps(hits[0])+'\n');value=json.loads(result.stdout)
        self.assertTrue(value['roundtrip']);self.assertIn('\ufefffu\u0308r',value['rendered'])

    def test_navigation_previous_next_context_and_source_change(self):
        hit=self.search()[1][0]
        for occurrence,paragraph_number in [(1,3),(0,1)]:
            value=favenio.load_content_preview(self.request(hit,occurrence))['contentPreview']
            self.assertEqual(value['snippets'][0]['documentPosition']['paragraph'],paragraph_number)
        value=favenio.load_content_preview(self.request(hit,0,True))['contentPreview']
        self.assertEqual(value['navigation']['contextLines'][0]['documentPosition']['paragraph'],2)
        self.assertEqual(favenio.load_content_preview(self.request(hit,2))['contentPreview']['navigation']['reason'],'end')
        request=self.request(hit);self.path.write_bytes(docx_bytes(paragraph('changed')))
        value=favenio.load_content_preview(request)['contentPreview'];self.assertEqual(value['status'],'sourceChanged');self.assertFalse(value['snippets'])

    def test_source_changes_during_projection_invalidate_hit(self):
        original=favenio.DOCXTextReader.sections
        def changed(reader,path,deadline):
            for item in original(reader,path,deadline):
                self.path.write_bytes(docx_bytes(paragraph('changed')))
                yield item
        with mock.patch.object(favenio.DOCXTextReader,'sections',changed):
            code,hits,report,errors=self.search()
        self.assertEqual((code,hits),(1,[]));self.assertIn('documentSourceChanged',[item['id'] for item in report['reasons']])

    def test_alternative_import_is_unknown_without_external_fetch(self):
        self.path.write_bytes(docx_bytes(paragraph('Jahresbericht')+'<w:altChunk/>'))
        self.assertEqual(self.search()[0], 0)
        self.assertEqual(self.negative()[0],1)
        self.assertIn('documentReadError',[item['id'] for item in self.search(pattern='absent')[2]['reasons']])

    def test_xml_encoding_follows_declaration_and_empty_projection_is_known(self):
        xml = part_xml(paragraph('Jahres', 'bericht 😀')).decode('utf-8').replace('encoding="UTF-8"', 'encoding="UTF-16"')
        self.path.write_bytes(docx_bytes(xml.encode('utf-16')))
        self.assertEqual(self.search(None, '--encoding', 'mac-roman')[0], 0)
        self.path.write_bytes(docx_bytes(paragraph('')))
        self.assertEqual(self.search()[0], 1)
        self.assertEqual(self.negative()[0], 0)

    def test_regex_exact_and_matches_in_long_paragraph_keep_projection_contract(self):
        self.assertEqual(self.search(None, '--exact')[0], 0)
        self.assertEqual(self.search(None, '--regex', pattern='^Jahresbericht$')[0], 0)
        self.path.write_bytes(docx_bytes(paragraph('x' * 70000 + 'Jahresbericht' + 'x' * 70000)))
        self.assertEqual(self.search()[0], 0)
        self.assertEqual(self.search(None, '--regex', pattern='^Jahresbericht$')[0], 1)

    def test_untrusted_docx_locators_queries_and_context_are_rejected(self):
        hit = self.search()[1][0]
        result = run_probe('content-preview', 'parse', input=json.dumps(hit) + '\n')
        self.assertEqual(json.loads(result.stdout)['status'], 'ready')
        for change in [{'part': '../text.xml'}, {'part': '/text.xml'}, {'part': 'word//text.xml'},
                       {'paragraph': True}, {'paragraph': 32769}, {'partKind': 'comment'}]:
            value = json.loads(json.dumps(hit)); value['documentPosition'].update(change)
            with self.assertRaisesRegex(RuntimeError, 'endet mit 2'):
                run_probe('content-preview', 'parse', input=json.dumps(value) + '\n')
        value = json.loads(json.dumps(hit)); value['contentPreview']['snippets'][0]['query']['documentReader'] = 'pdfkit-v1'
        result = run_probe('content-preview', 'parse', input=json.dumps(value) + '\n')
        self.assertEqual(json.loads(result.stdout)['status'], 'invalid')
        value = favenio.load_content_preview(self.request(hit, 0, True))
        value['contentPreview']['navigation']['contextLines'][0]['documentPosition'] = dict(kind='pdfPage', page=1, line=1)
        result = run_probe('content-preview', 'parse', input=json.dumps(value) + '\n')
        self.assertEqual(json.loads(result.stdout)['status'], 'invalid')

    def test_external_relationship_and_missing_main_do_not_fetch_or_prove_absence(self):
        external = '<Relationships xmlns="' + REL + '"><Relationship Id="header" Type="' + OFFICE_REL + 'header" Target="https://example.invalid/header.xml" TargetMode="External"/></Relationships>'
        self.path.write_bytes(docx_bytes(paragraph('Jahresbericht'), extra=[('word/_rels/document.xml.rels', external)]))
        self.assertEqual(self.search()[0], 0)
        self.assertEqual(self.negative()[0], 1)
        self.assertIn('documentReadError', [item['id'] for item in self.search(pattern='absent')[2]['reasons']])
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive: archive.writestr('word/document.xml', part_xml(paragraph('Jahresbericht')))
        self.path.write_bytes(buffer.getvalue())
        self.assertEqual(self.search()[0], 1); self.assertEqual(self.negative()[0], 1)

    def test_dangling_header_and_note_references_are_unknown_after_early_body_hit(self):
        for reference in ['<w:footnoteReference w:id="1"/>', '<w:headerReference xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" r:id="missing"/>']:
            self.path.write_bytes(docx_bytes(paragraph('Jahresbericht') + '<w:p><w:r>' + reference + '</w:r></w:p>'))
            self.assertEqual(self.search()[0], 0)
            self.assertEqual(self.negative()[0], 1)
            self.assertIn('documentDamaged', [item['id'] for item in self.search(pattern='absent')[2]['reasons']])

    def test_encrypted_zip_flags_have_specific_reason(self):
        data = bytearray(self.path.read_bytes())
        offset = 0
        while True:
            offset = data.find(b'PK\x01\x02', offset)
            if offset < 0: break
            flags = struct.unpack_from('<H', data, offset + 8)[0]
            struct.pack_into('<H', data, offset + 8, flags | 1)
            offset += 4
        self.path.write_bytes(data)
        code, hits, report, errors = self.search()
        self.assertEqual((code, hits), (1, [])); self.assertIn('documentEncrypted', [item['id'] for item in report['reasons']])
        self.assertEqual(self.negative()[0], 1)

    def test_timeout_interrupts_single_regex(self):
        self.path.write_bytes(docx_bytes(paragraph('a'*20000+'X')))
        with mock.patch.object(favenio,'DOCUMENT_SECONDS',0.05):
            start=time.monotonic();code,hits,report,errors=self.search(None,'--regex',pattern='(a+)+$')
        self.assertLess(time.monotonic()-start,1);self.assertEqual(code,1)
        self.assertIn('documentTimeout',[item['id'] for item in report['reasons']])

    def test_cancel_cleans_owned_docx_materialization(self):
        self.path.write_bytes(docx_bytes(paragraph('a'*20000+'X')))
        archive=Path(self.root,'cancel.zip')
        with zipfile.ZipFile(archive,'w') as output:output.writestr('report.docx',self.path.read_bytes())
        env=dict(os.environ,TMPDIR=self.scratch.name)
        with subprocess.Popen([sys.executable,str(REPO/'favenio.py'),'--json','--search-report','--document-text','--regex','(a+)+$',str(archive)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env) as process:
            deadline=time.monotonic()+4
            while not list(Path(self.scratch.name).glob('*.docx')) and process.poll() is None and time.monotonic()<deadline:time.sleep(0.01)
            self.assertTrue(list(Path(self.scratch.name).glob('*.docx')))
            process.terminate();stdout,stderr=process.communicate(timeout=3)
        self.assertEqual(json.loads(stdout.splitlines()[-1])['state'],'cancelled')
        self.assertFalse(list(Path(self.scratch.name).glob('*.docx')))

    def test_swift_paragraph_navigation_roundtrip_and_exports(self):
        hit=self.search()[1][0]
        result=run_probe('content-preview','docx',str(REPO/'favenio.py'),input=json.dumps(hit)+'\n')
        self.assertEqual(result.returncode,0,result.stderr);self.assertTrue(all(json.loads(result.stdout).values()),result.stdout)


if __name__=='__main__':unittest.main()
