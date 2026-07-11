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


class FavenioTest(unittest.TestCase):
    def setUp(self):
        # Temp-Ordner, der nach jedem Test automatisch verschwindet.
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.addCleanup(self.tmp.cleanup)

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

    def write(self, rel_path, text):
        path = os.path.join(self.root, rel_path)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)

    # ---------- Namenssuche ----------

    def test_name_substring_case_insensitive(self):
        # „rechnung" (klein) findet Datei UND Ordner „Rechnungen".
        code, lines, _ = run(["rechnung", self.root])
        self.assertEqual(code, 0)
        joined = "\n".join(lines)
        self.assertIn("rechnung-2026.pdf", joined)
        self.assertIn("Rechnungen", joined)

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


if __name__ == "__main__":
    unittest.main()
