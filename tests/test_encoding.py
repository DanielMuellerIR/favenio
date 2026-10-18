"""Textkodierung: Bytegrenzen, Ersatzzeichen, Decoderbelege und alte Suchpfade."""
import codecs
import hashlib
import json
from pathlib import Path
import unittest
import zipfile
from test_favenio import TempTreeTest, run, favenio
from test_criteria import leaf, group, arguments

def decode(data, choice='utf-8', errors='replace', split=None, info=None):
    chunks = [data] if split is None else [data[:split], data[split:]]
    return ''.join(favenio.decoded_text_chunks(iter(chunks), choice, errors, info))

class TextDecoderTests(unittest.TestCase):

    def test_utf16_at_all_byte_boundaries_with_original_nfd(self):
        text = '😀\r\nBüro\r\nEnde'
        for (bom, encoding) in ((codecs.BOM_UTF16_LE, 'utf-16-le'), (codecs.BOM_UTF16_BE, 'utf-16-be')):
            data = bom + text.encode(encoding)
            for choice in ('auto', encoding):
                for boundary in range(len(data) + 1):
                    with self.subTest(encoding=encoding, choice=choice, boundary=boundary):
                        self.assertEqual(decode(data, choice, split=boundary), text)
                self.assertEqual(''.join(favenio.decoded_text_chunks((bytes([b]) for b in data), choice)), text)

    def test_utf8_default_preserves_bom_and_automatic_removes_exactly_one(self):
        data = codecs.BOM_UTF8 + codecs.BOM_UTF8 + b'hello'
        for boundary in range(len(data) + 1):
            self.assertEqual(decode(data, 'utf-8', split=boundary), '\ufeff\ufeffhello')
            self.assertEqual(decode(data, 'auto', split=boundary), '\ufeffhello')

    def test_utf16_second_feff_is_content(self):
        for (bom, encoding) in ((codecs.BOM_UTF16_LE, 'utf-16-le'), (codecs.BOM_UTF16_BE, 'utf-16-be')):
            self.assertEqual(decode(bom + '\ufeffhello'.encode(encoding), 'auto'), '\ufeffhello')

    def test_opposite_byte_order_is_explained(self):
        for (data, choice) in ((codecs.BOM_UTF16_LE + b'A\x00', 'utf-16-be'), (codecs.BOM_UTF16_BE + b'\x00A', 'utf-16-le')):
            with self.assertRaisesRegex(favenio.DecoderChoiceError, 'BOM widerspricht'):
                decode(data, choice)

    def test_explicit_legacy_encoding_preserves_bom_like_characters(self):
        self.assertEqual(decode(b'\xff\xfeA', 'iso-8859-1'), 'ÿþA')
        self.assertEqual(decode(codecs.BOM_UTF8 + b'A', 'windows-1252'), 'ï»¿A')

    def test_legacy_choices_have_distinct_fixed_byte_meanings(self):
        data = b'\x80 \x93K\xf6ln\x94'
        self.assertEqual(decode(data, 'windows-1252'), '€ “Köln”')
        self.assertEqual(decode(data, 'iso-8859-1'), '\x80 \x93Köln\x94')
        self.assertEqual(decode(b'f\x9fr K\x9aln', 'mac-roman'), 'für Köln')
        self.assertNotEqual(decode(b'f\x9fr K\x9aln', 'windows-1252'), 'für Köln')

    def test_encoding_is_a_positive_list(self):
        for encoding in ('utf-7', 'unicode_escape', 'utf-32', 'UTF-8', 'utf-8\n', 'cp1252'):
            with self.assertRaises(favenio.DecoderChoiceError):
                decode(b'hello', encoding)

    def test_unsupported_utf32_bom_is_explicit_under_automatic(self):
        for (bom, encoding) in ((codecs.BOM_UTF32_LE, 'utf-32-le'), (codecs.BOM_UTF32_BE, 'utf-32-be')):
            with self.assertRaisesRegex(favenio.DecoderChoiceError, 'UTF-32'):
                decode(bom + 'hello'.encode(encoding), 'auto')

    def test_explicit_utf16_disambiguates_bom_followed_by_nul(self):
        self.assertEqual(decode(codecs.BOM_UTF16_LE + '\x00A'.encode('utf-16-le'), 'utf-16-le'), '\x00A')

    def test_invalid_units_replace_for_search_but_fail_for_positions(self):
        data = codecs.BOM_UTF16_LE + b'A\x00\x00\xd8'
        self.assertEqual(decode(data, 'auto'), 'A�')
        with self.assertRaises(UnicodeDecodeError):
            decode(data, 'auto', 'strict')
        self.assertEqual(decode(b'\x81', 'windows-1252'), '�')
        with self.assertRaises(UnicodeDecodeError):
            decode(b'\x81', 'windows-1252', 'strict')

    def test_legacy_choices_and_decoded_text_hash_keep_original_spelling(self):
        text = 'Jahresbericht für Köln'
        for (choice, codec) in favenio.TEXT_ENCODINGS.items():
            if choice.startswith('utf-16'):
                continue
            data = text.encode(codec)
            actual = decode(data, choice, 'strict')
            self.assertEqual(actual, text)
            self.assertEqual(hashlib.sha256(actual.encode()).digest(), hashlib.sha256(text.encode()).digest())
        text = 'Büro'
        self.assertNotEqual(hashlib.sha256(text.encode()).digest(), hashlib.sha256('Büro'.encode()).digest())

    def test_explicit_legacy_must_not_fall_back_to_utf8(self):
        data = 'ä'.encode()
        self.assertEqual(decode(data, 'windows-1252'), 'Ã¤')
        self.assertEqual(decode(data, 'auto'), 'ä')

    def test_empty_bom_only_and_short_inputs(self):
        for choice in list(favenio.TEXT_ENCODINGS) + ['auto']:
            self.assertEqual(decode(b'', choice), '')
        for bom in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE, codecs.BOM_UTF8):
            self.assertEqual(decode(bom, 'auto'), '')
        for data in (b'A', b'\xef', b'\xef\xbb'):
            self.assertEqual(decode(data, 'auto'), data.decode('utf-8', errors='replace'))

    def test_actual_decoder_and_consumed_bom_are_reported(self):
        info = {}
        self.assertEqual(decode(codecs.BOM_UTF16_BE + b'\x00A', 'auto', info=info), 'A')
        self.assertEqual(info, dict(requested='auto', decoder='utf-16-be', consumedBOMBytes=2))

    def test_original_byte_counter_and_nfc_probe_can_stop_early(self):
        for (bom, encoding) in ((codecs.BOM_UTF16_LE, 'utf-16-le'), (codecs.BOM_UTF16_BE, 'utf-16-be')):
            data = bom + 'A\n'.encode(encoding) + b'x' * 10000
            events = {'bytes': 0}

            def chunks():
                for value in data:
                    events['bytes'] += 1
                    yield bytes([value])
            self.assertTrue(favenio.ContentProbe('A', True, text_encoding='auto').hits(chunks()))
            self.assertEqual(events['bytes'], 6)

class EncodingSearchTests(TempTreeTest):

    def write_bytes(self, name, data):
        path = Path(self.root, name)
        path.write_bytes(data)
        return str(path)

    def test_utf16_auto_and_explicit_find_nfd_with_original_lines(self):
        for (codec, bom) in [('utf-16-le', codecs.BOM_UTF16_LE), ('utf-16-be', codecs.BOM_UTF16_BE)]:
            path = self.write_bytes(codec + '.txt', bom + '😀\r\nBüro\r\nEnde\r\n'.encode(codec))
            for choice in ('auto', codec):
                (code, lines, err) = run(['--json', '--content', '--encoding', choice, 'Büro', '--term', 'Ende', path])
                self.assertEqual(code, 0, err)
                hit = json.loads(lines[0])
                self.assertEqual(hit['line'], 2)
                self.assertEqual([t['line'] for t in hit['terms']], [2, 3])

    def test_content_tree_uses_encoding_in_name_mode(self):
        path = self.write_bytes('Büro.txt', codecs.BOM_UTF16_LE + 'Büro\n'.encode('utf-16-le'))
        query = group('all', 'and', leaf('name', value='Büro'), leaf('content', 'content', value='Büro'))
        (code, lines, err) = run(['--json', '--encoding', 'auto'] + arguments(query) + [path])
        self.assertEqual(code, 0, err)
        self.assertEqual(len(lines), 1)

    def test_conflicting_bom_is_unknown_under_negation(self):
        self.write_bytes('good.txt', codecs.BOM_UTF16_LE + 'alpha\n'.encode('utf-16-le'))
        self.write_bytes('bad.txt', codecs.BOM_UTF16_BE + 'alpha\n'.encode('utf-16-be'))
        (code, lines, err) = run(['--json', '--encoding', 'utf-16-le'] + arguments(leaf('negative', 'content', value='missing', negate=True)) + [self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual([Path(json.loads(x)['path']).name for x in lines], ['good.txt'])
        self.assertIn('BOM widerspricht', err)

    def test_archive_budget_counts_original_utf16_bytes_once(self):
        data = codecs.BOM_UTF16_LE + 'Büro\n'.encode('utf-16-le')
        path = Path(self.root, 'source.zip')
        with zipfile.ZipFile(path, 'w') as stream:
            stream.writestr('entry.txt', data)
        (code, lines, err) = run(['--json', '--content', '--encoding', 'auto', '--max-archive-total-bytes', str(len(data)), 'Büro', str(path)])
        self.assertEqual((code, len(lines), err), (0, 1, ''))
        self.assertEqual(json.loads(lines[0])['type'], 'member')

    def test_explicit_legacy_does_not_silently_use_utf8(self):
        path = self.write_bytes('legacy.txt', 'ä'.encode('utf-8'))
        (code, lines, err) = run(['--json', '--content', '--encoding', 'windows-1252', 'Ã¤', path])
        self.assertEqual((code, len(lines), err), (0, 1, ''))
        (code, lines, err) = run(['--json', '--content', '--encoding', 'auto', 'Ã¤', path])
        self.assertEqual((code, lines, err), (1, [], ''))

    def test_regex_stays_on_decoded_original_codepoints(self):
        path = self.write_bytes('regex.txt', codecs.BOM_UTF16_BE + 'Büro\n'.encode('utf-16-be'))
        for (pattern, expected) in [('Büro', 1), ('Büro', 0)]:
            (code, lines, err) = run(['--json', '--content', '--regex', '--encoding', 'auto', pattern, path])
            self.assertEqual(code, expected, err)

    def test_encoding_is_not_a_positive_filter_and_unknown_choice_fails(self):
        for args in (['--encoding', 'auto'], ['--encoding', 'utf-7', 'x', self.root]):
            (code, lines, err) = run(args)
            self.assertEqual((code, lines), (2, []))
            self.assertIn('favenio: fehler:', err)

    def test_real_core_probe_stops_after_six_original_bytes(self):
        data = codecs.BOM_UTF16_LE + 'A\n'.encode('utf-16-le') + b'x' * 10000
        events = {'bytes': 0}

        def chunks():
            for value in data:
                events['bytes'] += 1
                yield bytes([value])
        self.assertTrue(favenio.ContentProbe('A', True, text_encoding='auto').hits(chunks()))
        self.assertEqual(events['bytes'], 6)

    def test_every_preflight_boundary_runs_the_real_line_reader(self):
        text = '😀\r\nJahresbericht Büro\r\nEnde'
        fixtures = [(text.encode(), 'utf-8'), (codecs.BOM_UTF16_LE + text.encode('utf-16-le'), 'auto'), (codecs.BOM_UTF16_BE + text.encode('utf-16-be'), 'auto')]
        legacy = 'Jahresbericht für Köln\r\n'
        fixtures += [(legacy.encode(codec), choice) for (choice, codec) in [('windows-1252', 'cp1252'), ('iso-8859-1', 'latin-1'), ('mac-roman', 'mac_roman')]]
        count = 0
        for (data, choice) in fixtures:
            for boundary in range(len(data) + 1):
                matcher = favenio.build_matcher('Jahresbericht', False, True)
                search = favenio.Search(matcher, True, 0, False, text_encoding=choice)
                self.assertEqual(search.match_content([data[:boundary], data[boundary:]]), 2 if choice in ('utf-8', 'auto') else 1)
                count += 1
        self.assertEqual(count, 230)

    def test_content_evidence_comes_from_the_final_reader(self):
        path = self.write_bytes('leaf.txt', codecs.BOM_UTF16_BE + 'Büro\n'.encode('utf-16-be'))
        (code, lines, err) = run(['--json', '--content', '--encoding', 'auto', 'Büro', path])
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(lines[0])['contentEncoding'], 'utf-16-be')
        for condition in (leaf('positive', 'content', value='Büro'), leaf('negative', 'content', value='missing', negate=True)):
            (code, lines, err) = run(['--json', '--encoding', 'auto'] + arguments(condition) + [path])
            self.assertEqual(code, 0, err)
            hit = json.loads(lines[0])
            self.assertEqual(hit['contentEncoding'], 'utf-16-be')
            self.assertEqual(hit['criteriaEvidence'][0]['contentEncoding'], 'utf-16-be')
        (code, lines, err) = run(['--json', '--encoding', 'auto'] + arguments(leaf('name', value='leaf')) + [path])
        self.assertEqual(code, 0, err)
        self.assertNotIn('contentEncoding', json.loads(lines[0]))

    def test_decoder_evidence_comes_from_final_open_not_prefilter(self):
        import io
        matcher = favenio.build_matcher('needle', False, True)
        search = favenio.Search(matcher, True, 0, False, text_encoding='auto',
                                content_probe=favenio.ContentProbe('needle', True, text_encoding='auto'))
        streams = iter([io.BytesIO(b'needle\n'),
                        io.BytesIO(codecs.BOM_UTF16_LE + 'needle\n'.encode('utf-16-le'))])
        probe = favenio.FileProbe(search, 'fixture', 'leaf', lambda: next(streams),
                                  search.file_chunks, '/fixture')
        self.assertEqual(probe.content_lines(), [1])
        self.assertEqual(probe.decoder_info['decoder'], 'utf-16-le')

    def test_invalid_units_find_positives_but_cannot_prove_absence(self):
        for (data, choice) in [(codecs.BOM_UTF16_LE + b'A\x00\x00\xd8', 'auto'), (b'A\x81', 'windows-1252'), (b'A\xff', 'utf-8')]:
            path = self.write_bytes('invalid.txt', data)
            (code, lines, err) = run(['--json', '--content', '--encoding', choice, 'A', path])
            self.assertEqual(code, 0, err)
            (code, lines, err) = run(['--json', '--encoding', choice] + arguments(leaf('absent', 'content', value='missing', negate=True)) + [path])
            self.assertEqual((code, lines), (1, []), err)
        path = self.write_bytes('literal.txt', 'A�'.encode())
        (code, lines, err) = run(['--json'] + arguments(leaf('absent', 'content', value='missing', negate=True)) + [path])
        self.assertEqual(code, 0, err)

    def test_long_anchored_utf16_line_is_unknown_and_warned(self):
        from unittest import mock
        path = self.write_bytes('long.txt', codecs.BOM_UTF16_LE + ('A' * 100 + '\n').encode('utf-16-le'))
        with mock.patch.object(favenio, 'MAX_LINE_CHARS', 32), mock.patch.object(favenio, 'LINE_OVERLAP_CHARS', 8), mock.patch.object(favenio, 'CHUNK_SIZE', 32):
            (code, lines, err) = run(['--json', '--encoding', 'auto'] + arguments(leaf('anchor', 'content', operator='regex', value='A$', negate=True)) + [path])
        self.assertEqual((code, lines), (1, []))
        self.assertIn('Zeile', err)
