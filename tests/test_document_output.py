"""Textausgabe der CLI und unveränderte maschinenlesbare Fundstellen."""

import io
import json
from contextlib import redirect_stdout
from pathlib import Path

from test_favenio import TempTreeTest, favenio, run
from xlsx_fixture import xlsx_bytes


class DocumentOutputTests(TempTreeTest):
    def test_workbook_hit_in_text_and_json(self):
        workbook = Path(self.root, "report.xlsx")
        workbook.write_bytes(xlsx_bytes())
        args = ["--document-text", "Jahresbericht", str(workbook)]

        self.assertEqual(run(args), (0, [f"{workbook}:Blatt Übersicht, Zelle A1, Zeile 1"], ""))
        code, lines, errors = run(["--json", *args])
        self.assertEqual((code, errors, len(lines)), (0, "", 1))
        self.assertEqual(json.loads(lines[0])["documentPosition"], {
            "kind": "xlsxCell",
            "part": "xl/worksheets/z.xml",
            "sheet": "Übersicht",
            "sheetIndex": 1,
            "cell": "A1",
            "valueKind": "text",
            "line": 1,
        })

    def test_plain_output_preserves_every_other_document_position(self):
        cases = [
            (dict(kind="pdfPage", page=2), "Seite 2 Zeile 3"),
            (dict(kind="pdfTextPage", page=2), "PDF-Seite 2 Zeile 3 (Textebene)"),
            (dict(kind="pdfOCR", page=2, block=4),
             "PDF-Seite 2 OCR-Bereich 4 Zeile 3 (erkannt, ungefähre Seitenposition)"),
            (dict(kind="imageOCR", block=4),
             "OCR-Bereich 4 Zeile 3 (erkannt, ungefähre Bildposition)"),
            (dict(kind="pptxOCR", slide=2, objectID="5", block=4),
             "Folie 2 Bild 5 OCR-Bereich 4 Zeile 3 (erkannt, ungefähre Bildposition)"),
            (dict(kind="docxParagraph", part="word/document.xml", paragraph=1),
             "word/document.xml Absatz 1 Zeile 3"),
            (dict(kind="odtParagraph", part="content.xml", paragraph=1),
             "content.xml Absatz 1 Zeile 3"),
            (dict(kind="epubParagraph", part="chapter.xhtml", paragraph=1),
             "chapter.xhtml Absatz 1 Zeile 3"),
            (dict(kind="pptxParagraph", part="ppt/slides/slide2.xml", paragraph=1),
             "ppt/slides/slide2.xml Absatz 1 Zeile 3"),
        ]
        search = favenio.Search(None, True, 0, False)
        for position, label in cases:
            with self.subTest(kind=position["kind"]):
                output = io.StringIO()
                with redirect_stdout(output):
                    hit = favenio.HitRecord("document", "file", False,
                                            document_position=dict(position, line=3))
                    search.emit(hit)
                self.assertEqual(output.getvalue(), f"document:{label}\n")
