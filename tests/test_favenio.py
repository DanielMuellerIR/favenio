# Tests für Favenio — laufen mit purem Python:
#   python3 -m unittest discover -s tests
#
# Die Tests bauen sich in setUp() eine kleine Test-Welt in einem
# Temp-Ordner: normale Dateien, ein Zip, ein tar.gz und ein Zip,
# das ein weiteres Zip enthält (für die Verschachtelungs-Tests).

import io
import json
import os
import sys
import tarfile
import tempfile
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout

# favenio.py liegt eine Ebene über tests/ — Pfad dafür ergänzen.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import favenio  # noqa: E402


def run(argv):
    """Ruft favenio.main() auf und fängt stdout/stderr + Exit-Code ein.
    Liefert (exit_code, stdout_zeilen, stderr_text)."""
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            code = favenio.main(argv)
        except SystemExit as exit_info:
            # argparse (parser.error) beendet per SystemExit — Code einfangen.
            code = exit_info.code
    lines = [line for line in out.getvalue().splitlines() if line]
    return code, lines, err.getvalue()


class TempTreeTest(unittest.TestCase):
    """Gemeinsames Gerüst: ein Temp-Ordner je Test, der danach automatisch
    verschwindet, plus ein Helfer zum Schreiben von Testdateien."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.addCleanup(self.tmp.cleanup)

    def write(self, rel_path, text):
        path = os.path.join(self.root, rel_path)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path


class FavenioTest(TempTreeTest):
    def setUp(self):
        super().setUp()

        # --- normale Dateien und ein Unterordner ---
        os.makedirs(os.path.join(self.root, "Rechnungen"))
        self.write("notiz.txt", "Hallo Welt\nZeile zwei mit GEHEIMNIS\n")
        self.write("Rechnungen/rechnung-2026.pdf", "kein echtes pdf")

        # --- ein Zip-Archiv mit zwei Einträgen ---
        zip_path = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("docs/anleitung.md", "Schritt 1: GEHEIMNIS lesen\n")
            zf.writestr("bild.png", "binaerkram")

        # --- ein tar.gz-Archiv ---
        tar_path = os.path.join(self.root, "backup.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tf:
            data = b"Inhalt mit GEHEIMNIS im Tar\n"
            info = tarfile.TarInfo("sicherung/alt.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))

        # --- Zip im Zip (Verschachtelung) ---
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("tief/verstecktes.txt", "GEHEIMNIS ganz unten\n")
        outer_path = os.path.join(self.root, "aussen.zip")
        with zipfile.ZipFile(outer_path, "w") as zf:
            zf.writestr("innen.zip", inner.getvalue())

    # ---------- Namenssuche ----------

    def test_name_substring_case_insensitive(self):
        # „rechnung" (klein) findet Datei UND Ordner „Rechnungen".
        code, lines, _ = run(["rechnung", self.root])
        self.assertEqual(code, 0)
        joined = "\n".join(lines)
        self.assertIn("rechnung-2026.pdf", joined)
        self.assertIn("Rechnungen", joined)

    def test_only_files_and_dirs_default_both(self):
        # Ohne --only kommen Datei „rechnung-2026.pdf" UND Ordner „Rechnungen".
        code, lines, _ = run(["--json", "rechnung", self.root])
        self.assertEqual(code, 0)
        types = {json.loads(line)["type"] for line in lines}
        self.assertIn("file", types)
        self.assertIn("dir", types)

    def test_only_files(self):
        # --only files unterdrückt den Ordner-Treffer.
        code, lines, _ = run(["--json", "--only", "files", "rechnung",
                              self.root])
        self.assertEqual(code, 0)
        types = {json.loads(line)["type"] for line in lines}
        self.assertIn("file", types)
        self.assertNotIn("dir", types)

    def test_only_dirs(self):
        # --only dirs liefert nur den Ordner, keine Dateien.
        code, lines, _ = run(["--json", "--only", "dirs", "rechnung",
                              self.root])
        self.assertEqual(code, 0)
        types = {json.loads(line)["type"] for line in lines}
        self.assertEqual(types, {"dir"})

    def test_hidden_skipped_by_default(self):
        # Eine unsichtbare Datei wird ohne --hidden NICHT gefunden.
        self.write(".geheim-notiz.txt", "x")
        code, lines, _ = run(["geheim", self.root])
        self.assertEqual(code, 1)   # kein Treffer
        self.assertFalse(any(".geheim-notiz" in line for line in lines))

    def test_hidden_found_with_flag(self):
        self.write(".geheim-notiz.txt", "x")
        code, lines, _ = run(["--hidden", "geheim", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(any(".geheim-notiz" in line for line in lines))

    def test_hidden_dir_pruned(self):
        # In einem unsichtbaren Ordner liegende Treffer bleiben unsichtbar.
        os.makedirs(os.path.join(self.root, ".versteck"))
        self.write(".versteck/beute.txt", "x")
        code, _, _ = run(["beute", self.root])
        self.assertEqual(code, 1)
        code, _, _ = run(["--hidden", "beute", self.root])
        self.assertEqual(code, 0)

    def test_size_in_json(self):
        # Größe steht als Bytes im JSON; Ordner haben keine Größe.
        self.write("groesse-probe.txt", "12345")   # 5 Bytes
        code, lines, _ = run(["--json", "groesse-probe", self.root])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertEqual(record["size"], 5)

    def test_name_glob(self):
        # Glob muss den GANZEN Namen matchen.
        code, lines, _ = run(["*.txt", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(any(line.endswith("notiz.txt") for line in lines))
        # Der Zip-Eintrag tief/verstecktes.txt zählt auch (Archiv-Namenssuche).
        self.assertTrue(any("!/" in line for line in lines))

    def test_name_in_zip_member(self):
        code, lines, _ = run(["anleitung", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(
            any(line.endswith("paket.zip!/docs/anleitung.md")
                for line in lines))

    def test_name_in_tar_member(self):
        code, lines, _ = run(["alt.txt", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(
            any("backup.tar.gz!/sicherung/alt.txt" in line for line in lines))

    def test_no_archives_flag(self):
        code, lines, _ = run(["anleitung", self.root, "--no-archives"])
        self.assertEqual(code, 1)  # ohne Archivblick kein Treffer
        self.assertEqual(lines, [])

    def test_case_sensitive(self):
        code, _, _ = run(["RECHNUNG", self.root, "--case-sensitive"])
        self.assertEqual(code, 1)

    # ---------- Inhaltssuche ----------

    def test_content_in_plain_file(self):
        code, lines, _ = run(["-c", "geheimnis", self.root])
        self.assertEqual(code, 0)
        # Treffer in der normalen Datei mit Zeilennummer 2
        self.assertTrue(any(line.endswith("notiz.txt:2") for line in lines))

    def test_content_in_zip_and_tar(self):
        code, lines, _ = run(["-c", "GEHEIMNIS", self.root])
        self.assertEqual(code, 0)
        joined = "\n".join(lines)
        self.assertIn("paket.zip!/docs/anleitung.md:1", joined)
        self.assertIn("backup.tar.gz!/sicherung/alt.txt:1", joined)

    def test_content_nested_zip_needs_depth_2(self):
        # Mit Default-Tiefe 1 bleibt das Zip im Zip zu.
        code, lines, _ = run(["-c", "ganz unten", self.root])
        self.assertEqual(code, 1)
        # Mit Tiefe 2 wird es gefunden.
        code, lines, _ = run(["-c", "ganz unten", self.root,
                              "--archive-depth", "2"])
        self.assertEqual(code, 0)
        self.assertTrue(
            any("aussen.zip!/innen.zip!/tief/verstecktes.txt" in line
                for line in lines))

    # ---------- Regex, JSON, Fehlerfälle ----------

    def test_regex(self):
        code, lines, _ = run(["-r", r"rechnung-\d{4}", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(any("rechnung-2026.pdf" in line for line in lines))

    def test_invalid_regex_exits_2(self):
        code, _, err = run(["-r", "[kaputt", self.root])
        self.assertEqual(code, 2)
        self.assertIn("regul", err)

    def test_missing_path_exits_2(self):
        code, _, err = run(["x", os.path.join(self.root, "gibtsnicht")])
        self.assertEqual(code, 2)
        self.assertIn("existiert nicht", err)

    def test_json_output(self):
        code, lines, _ = run(["--json", "-c", "GEHEIMNIS", self.root])
        self.assertEqual(code, 0)
        records = [json.loads(line) for line in lines]
        # Jeder Datensatz hat path/type, Inhalts-Treffer auch line.
        for record in records:
            self.assertIn("path", record)
            self.assertIn("type", record)
            self.assertIn("line", record)
        types = {record["type"] for record in records}
        self.assertIn("file", types)    # notiz.txt
        self.assertIn("member", types)  # Archiv-Einträge

    # ---------- Fortschrittsmeldungen (--progress) ----------

    def test_progress_json(self):
        # Mit --json --progress erscheinen Fortschritts-Objekte im Strom;
        # die erste Meldung kommt immer (Drossel greift erst danach).
        code, lines, _ = run(["--json", "--progress", "notiz", self.root])
        self.assertEqual(code, 0)
        records = [json.loads(line) for line in lines]
        progress = [r for r in records if r["type"] == "progress"]
        hits = [r for r in records if r["type"] != "progress"]
        self.assertGreaterEqual(len(progress), 1)
        self.assertTrue(all("path" in r for r in progress))
        # Die Treffer bleiben davon unberührt.
        self.assertEqual([os.path.basename(r["path"]) for r in hits],
                         ["notiz.txt"])

    def test_progress_text_mode_goes_to_stderr(self):
        # Ohne --json bleibt stdout eine reine Trefferliste;
        # die Fortschrittszeilen landen auf stderr.
        code, lines, err = run(["--progress", "notiz", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertIn("durchsuche", err)

    def test_no_progress_without_flag(self):
        code, lines, _ = run(["--json", "notiz", self.root])
        self.assertEqual(code, 0)
        types = {json.loads(line)["type"] for line in lines}
        self.assertNotIn("progress", types)

    # ---------- Extraktion (--extract, Unterbau für die GUI) ----------

    def read(self, path):
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    def test_extract_plain_file(self):
        # Normale Datei: wird nicht kopiert, nur absolut ausgegeben.
        target = os.path.join(self.root, "notiz.txt")
        code, lines, _ = run(["--extract", target])
        self.assertEqual(code, 0)
        self.assertEqual(lines, [os.path.abspath(target)])

    def test_extract_zip_member(self):
        result = os.path.join(self.root, "paket.zip") + "!/docs/anleitung.md"
        code, lines, _ = run(["--extract", result])
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].endswith("anleitung.md"))
        self.assertIn("GEHEIMNIS", self.read(lines[0]))

    def test_extract_tar_member(self):
        result = (os.path.join(self.root, "backup.tar.gz")
                  + "!/sicherung/alt.txt")
        code, lines, _ = run(["--extract", result])
        self.assertEqual(code, 0)
        self.assertIn("GEHEIMNIS", self.read(lines[0]))

    def test_extract_nested_zip(self):
        result = (os.path.join(self.root, "aussen.zip")
                  + "!/innen.zip!/tief/verstecktes.txt")
        code, lines, _ = run(["--extract", result])
        self.assertEqual(code, 0)
        self.assertIn("ganz unten", self.read(lines[0]))

    def test_extract_missing_member_exits_2(self):
        result = os.path.join(self.root, "paket.zip") + "!/gibtsnicht.txt"
        code, _, err = run(["--extract", result])
        self.assertEqual(code, 2)
        self.assertIn("fehler", err)

    def test_extract_from_non_archive_exits_2(self):
        result = os.path.join(self.root, "notiz.txt") + "!/x.txt"
        code, _, err = run(["--extract", result])
        self.assertEqual(code, 2)
        self.assertIn("kein unterstütztes Archiv", err)

    def test_no_pattern_and_no_extract_exits_2(self):
        code, _, _ = run([])
        self.assertEqual(code, 2)

    def test_single_file_as_start_path(self):
        # Auch eine einzelne Datei (statt Ordner) ist ein gültiger Startpfad.
        code, lines, _ = run(["notiz", os.path.join(self.root, "notiz.txt")])
        self.assertEqual(code, 0)


class ChunkedContentTest(TempTreeTest):
    """Die Inhaltssuche liest häppchenweise. Diese Tests sichern ab, dass
    dabei GENAU dieselben Zeilen entstehen wie beim Dekodieren am Stück —
    inklusive Zeilennummern, Häppchengrenzen und kaputter Bytes."""

    def collect_lines(self, data, chunk_size):
        """Lässt match_content über die Daten laufen und schreibt jede
        geprüfte Zeile mit. Der Matcher liefert nie True, damit wirklich
        alle Zeilen durchlaufen werden."""
        seen = []

        def record(line):
            seen.append(line)
            return False

        search = favenio.Search(record, True, 0, False)
        chunks = [data[i:i + chunk_size]
                  for i in range(0, len(data), chunk_size)]
        self.assertIsNone(search.match_content(iter(chunks)))
        return seen

    def assert_same_as_whole(self, data):
        """Häppchenweise == am Stück, für viele Häppchengrößen."""
        expected = data.decode("utf-8", errors="replace").splitlines()
        for chunk_size in (1, 2, 3, 5, 8, 64, 4096):
            self.assertEqual(self.collect_lines(data, chunk_size), expected,
                             "Häppchengröße %d" % chunk_size)

    def test_line_endings_across_chunks(self):
        # CRLF, einzelnes CR und LF — auch wenn ein \r\n genau auf einer
        # Häppchengrenze auseinandergerissen wird.
        self.assert_same_as_whole(b"eins\r\nzwei\rdrei\nvier")
        self.assert_same_as_whole(b"a\r\n\r\nb")
        self.assert_same_as_whole(b"endet-mit-cr\r")

    def test_exotic_line_separators(self):
        # str.splitlines() bricht auch bei \v \f \x1c \x1d \x1e, U+0085,
        # U+2028 und U+2029 um — das muss die Häppchen-Variante mitmachen.
        self.assert_same_as_whole(
            "a\vb\fc\x1cd\x1de\x1ef\x85g h i".encode("utf-8"))

    def test_multibyte_split_across_chunks(self):
        # Mehrbyte-Zeichen dürfen an Häppchengrenzen nicht zerfallen.
        self.assert_same_as_whole("äöü ✓ 🔍\nzweite Zeile\n".encode("utf-8"))

    def test_broken_bytes_stay_replaced(self):
        # Halb-binäre Dateien bleiben durchsuchbar (errors="replace"),
        # auch bei einem abgeschnittenen Zeichen am Dateiende.
        self.assert_same_as_whole(b"gut\n\xff\xfe kaputt\ngut\n\xe2\x80")

    def test_file_without_any_line_break(self):
        # Eine einzige sehr lange Zeile über viele Häppchen hinweg.
        self.assert_same_as_whole(b"x" * 5000 + b"NADEL" + b"y" * 5000)

    def test_empty_file(self):
        self.assert_same_as_whole(b"")

    def test_line_number_beyond_chunk_boundary(self):
        # Treffer weit hinten: die Zeilennummer muss über Häppchengrenzen
        # hinweg korrekt weitergezählt werden.
        path = self.write("gross.txt",
                          "fuellzeile\n" * 20000 + "hier steht GEHEIMNIS\n")
        code, lines, _ = run(["--json", "--content", "GEHEIMNIS", path])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(lines[0])["line"], 20001)


if __name__ == "__main__":
    unittest.main()
