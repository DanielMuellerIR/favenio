"""Mehrwortsuche (--term): mehrere Begriffe, die ALLE im selben Objekt
zutreffen müssen — im Namen, im Inhalt (nicht zwingend in derselben Zeile)
oder in den Metadaten (nicht zwingend im selben Wert)."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import favenio  # noqa: E402
from test_favenio import TempTreeTest, run, png_bytes  # noqa: E402


class TermsTest(TempTreeTest):
    def setUp(self):
        super().setUp()
        self.write("beide.txt", "erste Zeile alpha\nzweite\nBETA hier\n")
        self.write("eins.txt", "nur alpha\n")
        self.write("phrase.txt", "alpha beta in einer Zeile\n")
        self.write("alpha-beta.md", "nichts\n")

    def paths(self, lines):
        return sorted(os.path.basename(json.loads(line)["path"]) for line in lines)

    def test_terms_on_different_lines_hit_with_evidence_per_term(self):
        code, lines, err = run(["--json", "--content", "alpha", "--term", "beta",
                                self.root])
        self.assertEqual(code, 0, err)
        records = {os.path.basename(json.loads(l)["path"]): json.loads(l)
                   for l in lines}
        self.assertEqual(sorted(records), ["beide.txt", "phrase.txt"])
        # Belege je Begriff; `line` nennt weiter den ersten Begriff.
        self.assertEqual(records["beide.txt"]["terms"],
                         [{"term": "alpha", "line": 1}, {"term": "beta", "line": 3}])
        self.assertEqual(records["beide.txt"]["line"], 1)
        self.assertEqual(records["phrase.txt"]["terms"],
                         [{"term": "alpha", "line": 1}, {"term": "beta", "line": 1}])
        # Textausgabe: die Zeilen aller Begriffe, mit Komma.
        code, lines, _ = run(["--content", "alpha", "--term", "beta", self.root])
        self.assertEqual(sorted(l.rsplit("/", 1)[1] for l in lines),
                         ["beide.txt:1,3", "phrase.txt:1,1"])

    def test_a_phrase_is_one_term_and_spaces_do_not_split(self):
        code, lines, _ = run(["--json", "--content", "alpha beta", self.root])
        self.assertEqual(self.paths(lines), ["phrase.txt"])
        record = json.loads(lines[0])
        self.assertNotIn("terms", record)      # ein Begriff: keine Belege

    def test_terms_in_names_and_with_globs(self):
        code, lines, _ = run(["--json", "alpha", "--term", "beta", self.root])
        self.assertEqual(self.paths(lines), ["alpha-beta.md"])
        code, lines, _ = run(["--json", "*.md", "--term", "alpha*", self.root])
        self.assertEqual(self.paths(lines), ["alpha-beta.md"])
        code, lines, _ = run(["--json", "*.txt", "--term", "alpha*", self.root])
        self.assertEqual((code, lines), (1, []))
        # Belege ohne Zeile bei Namenstreffern.
        code, lines, _ = run(["--json", "alpha", "--term", "beta", self.root])
        self.assertEqual(json.loads(lines[0])["terms"],
                         [{"term": "alpha"}, {"term": "beta"}])

    def test_duplicate_terms_count_once_and_empty_terms_are_an_error(self):
        code, lines, _ = run(["--json", "--content", "alpha", "--term", "alpha",
                              self.root])
        self.assertEqual(code, 0)
        self.assertEqual(self.paths(lines), ["beide.txt", "eins.txt", "phrase.txt"])
        self.assertNotIn("terms", json.loads(lines[0]))
        code, _, err = run(["--content", "alpha", "--term", "", self.root])
        self.assertEqual(code, 2)
        self.assertIn("--term darf nicht leer sein", err)

    def test_terms_without_pattern_take_the_first_term_as_pattern(self):
        # `--content --term alpha --term beta ORDNER`: das Positionsargument
        # ist der Startpfad, nicht das Muster.
        code, lines, err = run(["--json", "--content", "--term", "alpha",
                                "--term", "beta", self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.paths(lines), ["beide.txt", "phrase.txt"])
        code, lines, err = run(["--json", "--term", "alpha", "--term", "beta",
                                self.root])
        self.assertEqual(self.paths(lines), ["alpha-beta.md"])

    def test_case_sensitivity_applies_to_every_term(self):
        code, lines, _ = run(["--json", "--content", "-s", "alpha", "--term",
                              "beta", self.root])
        # BETA in beide.txt ist groß: mit -s bleibt nur die Phrase.
        self.assertEqual(self.paths(lines), ["phrase.txt"])

    def test_regex_and_exact_apply_to_every_term(self):
        code, lines, _ = run(["--json", "--content", "--regex", "^erste",
                              "--term", r"BETA\b", self.root])
        self.assertEqual(self.paths(lines), ["beide.txt"])
        code, lines, _ = run(["--json", "--content", "--exact", "zweite",
                              "--term", "nur alpha", self.root])
        self.assertEqual((code, lines), (1, []))      # nie beides in EINER Datei
        code, lines, _ = run(["--json", "--content", "--exact", "zweite",
                              "--term", "BETA hier", self.root])
        self.assertEqual(self.paths(lines), ["beide.txt"])

    def test_the_content_is_not_reread_per_term(self):
        # Ein Vortest über alle festen Begriffe, dann EIN genauer Durchlauf:
        # höchstens zwei Öffnungen je Datei, egal wie viele Begriffe.
        opened = []
        original = favenio.open_regular_file

        def counting_open(path, *args, **kwargs):
            opened.append(path)
            return original(path, *args, **kwargs)

        favenio.open_regular_file = counting_open
        try:
            code, lines, _ = run(["--json", "--content", "alpha", "--term",
                                  "beta", "--term", "Zeile", "--term", "zweite",
                                  os.path.join(self.root, "beide.txt")])
        finally:
            favenio.open_regular_file = original
        self.assertEqual(code, 0)
        self.assertLessEqual(len(opened), 2)
        # Ein fehlender Begriff endet schon im Vortest: eine Öffnung.
        opened.clear()
        favenio.open_regular_file = counting_open
        try:
            code, lines, _ = run(["--json", "--content", "alpha", "--term",
                                  "fehltganzsicher",
                                  os.path.join(self.root, "beide.txt")])
        finally:
            favenio.open_regular_file = original
        self.assertEqual((code, lines), (1, []))
        self.assertEqual(len(opened), 1)

    def test_match_content_all_stops_when_the_last_term_is_found(self):
        matchers = [favenio.build_matcher(t, False, False) for t in ("a", "b")]
        search = favenio.Search(matchers[0], True, 1, False,
                                extra_matchers=matchers[1:])
        consumed = []

        def chunks():
            for piece in (b"a\n", b"b\n", b"c\n"):
                consumed.append(piece)
                yield piece

        self.assertEqual(search.match_content_all(chunks(), matchers), [1, 2])
        self.assertEqual(consumed, [b"a\n", b"b\n"])
        self.assertIsNone(search.match_content_all(iter([b"a\nx\n"]), matchers))

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_metadata_terms_may_sit_in_different_fields(self):
        import subprocess
        path = os.path.join(self.root, "bild.png")
        with open(path, "wb") as handle:
            handle.write(png_bytes(60, 40))
        subprocess.run([favenio.find_exiftool(), "-overwrite_original", "-q",
                        "-XMP-dc:Subject=Winter", "-XMP-dc:Title=Alpen", path],
                       check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        code, lines, err = run(["--json", "--metadata", "Winter", "--term",
                                "Alpen", self.root])
        self.assertEqual(code, 0, err)
        record = json.loads(lines[0])
        self.assertEqual(record["field"], "Keywords")
        self.assertEqual([t["term"] for t in record["terms"]], ["Winter", "Alpen"])
        self.assertEqual(record["terms"][1]["field"], "Title")
        self.assertEqual(record["terms"][1]["value"], "Alpen")
        code, lines, _ = run(["--metadata", "Winter", "--term", "Alpen", self.root])
        self.assertTrue(lines[0].endswith("bild.png:Keywords: Winter | Title: Alpen"), lines)
        code, lines, _ = run(["--json", "--metadata", "Winter", "--term", "Sommer",
                              self.root])
        self.assertEqual((code, lines), (1, []))


if __name__ == "__main__":
    unittest.main()
