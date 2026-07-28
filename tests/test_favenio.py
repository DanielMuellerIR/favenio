# Tests für Favenio — laufen mit purem Python:
#   python3 -m unittest discover -s tests
#
# Die Tests bauen sich in setUp() eine kleine Test-Welt in einem
# Temp-Ordner: normale Dateien, ein Zip, ein tar.gz und ein Zip,
# das ein weiteres Zip enthält (für die Verschachtelungs-Tests).

import bz2
import gzip
import io
import json
import lzma
import os
import subprocess
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
            zf.writestr(".private/visible.txt", "HIDDEN CONTENT\n")
            zf.writestr("odd!/name.txt", "STRUKTURIERT\n")

        # --- ein tar.gz-Archiv ---
        tar_path = os.path.join(self.root, "backup.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tf:
            data = b"Inhalt mit GEHEIMNIS im Tar\n"
            info = tarfile.TarInfo("sicherung/alt.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
            hidden = b"HIDDEN TAR\n"
            hidden_info = tarfile.TarInfo(".private/visible-tar.txt")
            hidden_info.size = len(hidden)
            tf.addfile(hidden_info, io.BytesIO(hidden))

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

    def test_hidden_archive_parent_component_is_skipped(self):
        code, lines, _ = run(["visible", self.root])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        code, lines, _ = run(["--hidden", "visible", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 2)

    def test_hidden_archive_content_is_skipped(self):
        code, lines, _ = run(["--content", "HIDDEN", self.root])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])

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

    # ---------- Exakter Name ----------

    def test_exact_name_ignores_substring_hits(self):
        # Der reale Anlass: „release.sh" fand auch „test-github-release.sh".
        os.makedirs(os.path.join(self.root, "projekt"))
        self.write("projekt/release.sh", "#!/bin/sh\n")
        self.write("test-github-release.sh", "#!/bin/sh\n")

        code, lines, _ = run(["release.sh", self.root, "--only", "files"])
        self.assertEqual(code, 0)
        self.assertTrue(any(line.endswith("test-github-release.sh")
                            for line in lines))

        code, lines, _ = run(["--exact", "release.sh", self.root,
                              "--only", "files"])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].endswith(os.path.join("projekt",
                                                       "release.sh")))

    def test_exact_stays_case_insensitive_by_default(self):
        self.write("Release.SH", "#!/bin/sh\n")
        code, lines, _ = run(["--exact", "release.sh", self.root,
                              "--only", "files"])
        self.assertEqual(code, 0)
        self.assertTrue(any(line.endswith("Release.SH") for line in lines))
        # Mit -s zählt die Schreibweise wieder.
        code, _, _ = run(["--exact", "-s", "release.sh", self.root])
        self.assertEqual(code, 1)

    def test_exact_with_regex_is_fullmatch(self):
        self.write("release.sh", "#!/bin/sh\n")
        self.write("test-github-release.sh", "#!/bin/sh\n")
        code, lines, _ = run(["--exact", "-r", r"release\.sh", self.root,
                              "--only", "files"])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].endswith("release.sh"))
        self.assertFalse(lines[0].endswith("github-release.sh"))

    def test_exact_leaves_glob_semantics_alone(self):
        # Ein Glob matcht ohnehin den ganzen Namen; --exact ändert daran nichts.
        code, plain, _ = run(["*.txt", self.root, "--no-archives"])
        code_exact, exact_lines, _ = run(["--exact", "*.txt", self.root,
                                          "--no-archives"])
        self.assertEqual(code, code_exact)
        self.assertEqual(sorted(plain), sorted(exact_lines))

    # ---------- Suchtiefe ----------

    def test_max_depth_limits_like_find(self):
        os.makedirs(os.path.join(self.root, "eins", "zwei", "drei"))
        self.write("ziel.marker", "oben")
        self.write("eins/ziel.marker", "ebene 1")
        self.write("eins/zwei/ziel.marker", "ebene 2")
        self.write("eins/zwei/drei/ziel.marker", "ebene 3")

        def depths(value):
            args = ["ziel.marker", self.root, "--only", "files",
                    "--no-archives"]
            if value is not None:
                args += ["--max-depth", str(value)]
            _, lines, _ = run(args)
            return len(lines)

        self.assertEqual(depths(1), 1)   # nur direkt im Startpfad
        self.assertEqual(depths(2), 2)
        self.assertEqual(depths(3), 3)
        self.assertEqual(depths(None), 4)   # Default: unbegrenzt

    def test_max_depth_rejects_zero(self):
        code, _, err = run(["ziel", self.root, "--max-depth", "0"])
        self.assertEqual(code, 2)
        self.assertIn("größer als 0", err)

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
            self.assertIn("filesystemPath", record)
            self.assertIn("archiveMembers", record)
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

    def test_plain_path_containing_archive_separator_stays_plain(self):
        os.makedirs(os.path.join(self.root, "folder!"))
        target = self.write("folder!/plain.txt", "normal")
        code, lines, _ = run(["--extract", target])
        self.assertEqual(code, 0)
        self.assertEqual(lines, [os.path.abspath(target)])

    def test_structured_archive_path_handles_separator_inside_member(self):
        archive = os.path.join(self.root, "paket.zip")
        code, lines, _ = run(["--json", "name.txt", archive])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertEqual(record["filesystemPath"], archive)
        self.assertEqual(record["archiveMembers"], ["odd!/name.txt"])
        materialization_root = os.path.join(self.root, "materialized")
        os.makedirs(materialization_root)
        code, extracted, _ = run([
            "--extract-json", json.dumps(record),
            "--extract-root", materialization_root,
        ])
        self.assertEqual(code, 0)
        self.assertEqual(self.read(extracted[0]), "STRUKTURIERT\n")
        self.assertEqual(
            os.path.dirname(os.path.dirname(extracted[0])),
            materialization_root,
        )

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

    def make_encrypted_zip(self):
        source = self.write("encrypted-source.txt", "VERSCHLUESSELT\n")
        archive = os.path.join(self.root, "encrypted.zip")
        subprocess.run([
            "/usr/bin/zip", "-q", "-j", "-P", "test-only-password",
            archive, source,
        ], check=True)
        return archive

    def test_encrypted_zip_member_warns_and_search_continues(self):
        archive = self.make_encrypted_zip()
        code, lines, err = run(["--content", "VERSCHLUESSELT", archive])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("encrypted", err.lower())
        self.assertNotIn("Traceback", err)

    def test_encrypted_zip_extract_exits_2_without_traceback(self):
        archive = self.make_encrypted_zip()
        result = archive + "!/encrypted-source.txt"
        code, _, err = run(["--extract", result])
        self.assertEqual(code, 2)
        self.assertIn("fehler", err)
        self.assertNotIn("Traceback", err)

    def test_archive_member_and_total_budgets(self):
        archive = os.path.join(self.root, "budget.zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("one.txt", "A" * 48)
            zf.writestr("two.txt", "B" * 48)
        code, lines, err = run([
            "--content", "NADEL", archive,
            "--max-archive-member-bytes", "32",
        ])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Einzelgrenze", err)
        code, _, err = run([
            "--content", "NADEL", archive,
            "--max-archive-member-bytes", "64",
            "--max-archive-total-bytes", "64",
        ])
        self.assertEqual(code, 1)
        self.assertIn("Gesamtbudget", err)

    def test_extract_respects_archive_budget(self):
        result = os.path.join(self.root, "paket.zip") + "!/docs/anleitung.md"
        code, _, err = run([
            "--extract", result, "--max-archive-member-bytes", "8",
        ])
        self.assertEqual(code, 2)
        self.assertIn("Einzelgrenze", err)

    def test_zip_compression_ratio_limit(self):
        archive = os.path.join(self.root, "ratio.zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("repeated.txt", "A" * 4096)
        code, lines, err = run([
            "--content", "NADEL", archive, "--max-archive-ratio", "2",
        ])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Kompressionsverhältnis", err)

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


class ContentProbeTest(TempTreeTest):
    """Der Vortest (ContentProbe) darf die Inhaltssuche nur beschleunigen,
    nicht verändern. Diese Tests sichern beides ab: dass er das Ja/Nein
    korrekt liefert und dass die Suche mit und ohne ihn dasselbe findet."""

    def probe_hits(self, needle, data, case_sensitive=False, chunk_size=8):
        probe = favenio.ContentProbe(needle, case_sensitive)
        chunks = [data[i:i + chunk_size]
                  for i in range(0, len(data), chunk_size)]
        return probe.hits(iter(chunks))

    def test_probe_finds_needle_across_chunk_boundary(self):
        # „GEHEIMNIS" wird bei Häppchengröße 8 mitten auseinandergerissen.
        for chunk_size in (1, 2, 3, 4, 8, 64):
            self.assertTrue(
                self.probe_hits("GEHEIMNIS", b"xxxxxxxGEHEIMNISyyyy",
                                chunk_size=chunk_size),
                "Häppchengröße %d" % chunk_size)

    def test_probe_is_case_insensitive_by_default(self):
        self.assertTrue(self.probe_hits("geheimnis", b"das GEHEIMNIS hier"))
        self.assertFalse(self.probe_hits("geheimnis", b"das GEHEIMNIS hier",
                                         case_sensitive=True))

    def test_probe_sees_multibyte_and_broken_bytes(self):
        # Mehrbyte-Zeichen über Häppchengrenzen und errors="replace" müssen
        # sich genauso verhalten wie in match_content.
        self.assertTrue(self.probe_hits("Größe", "die Größe passt".encode()))
        self.assertTrue(self.probe_hits("gut", b"\xff\xfe kaputt aber gut"))

    def test_probe_says_no_when_needle_absent(self):
        self.assertFalse(self.probe_hits("NADEL", b"nur heu und stroh\n"))
        self.assertFalse(self.probe_hits("NADEL", b""))

    def test_probe_only_for_fixed_text(self):
        # Regex und Glob liefern keinen festen Suchtext — dort bleibt es beim
        # genauen Lauf.
        self.assertIsNone(favenio.build_content_probe("Zeile.*NADEL", True,
                                                      False))
        self.assertIsNone(favenio.build_content_probe("NAD*", False, False))
        self.assertIsInstance(favenio.build_content_probe("NADEL", False,
                                                          False),
                              favenio.ContentProbe)

    def build_world(self):
        """Ein Ordner mit Treffern in normaler Datei, Zip, Tar und Zip-im-Zip
        — plus reichlich Dateien ohne Treffer, damit auch der Nein-Pfad läuft.
        """
        self.write("klein.txt", "eins\nzwei mit NADEL\ndrei\n")
        self.write("ohne.txt", "hier steht nichts davon\n")
        self.write("umlaut.txt", "erste Zeile\nGrößere NADEL im Heu\n")
        # Treffer erst hinter der Häppchengrenze (CHUNK_SIZE = 64 KiB).
        self.write("gross.txt", "fuellzeile\n" * 20000 + "spaete NADEL\n")
        zip_path = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("docs/mit.md", "vorspann\nzeile mit NADEL\n")
            zf.writestr("docs/ohne.md", "nichts hier\n")
        tar_path = os.path.join(self.root, "backup.tar.gz")
        with tarfile.open(tar_path, "w:gz") as tf:
            data = b"kopf\nkoerper mit NADEL\n"
            info = tarfile.TarInfo("sicherung/alt.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("tief/unten.txt", "a\nb\nc mit NADEL\n")
        with zipfile.ZipFile(os.path.join(self.root, "aussen.zip"), "w") as zf:
            zf.writestr("innen.zip", inner.getvalue())

    def search_with_and_without_probe(self, argv):
        """Führt dieselbe Suche zweimal aus: einmal normal (mit Vortest) und
        einmal mit abgeschaltetem Vortest. Liefert beide Trefferlisten."""
        code_fast, fast, _ = run(argv)
        original = favenio.build_content_probe
        favenio.build_content_probe = lambda *args, **kwargs: None
        try:
            code_slow, slow, _ = run(argv)
        finally:
            favenio.build_content_probe = original
        self.assertEqual(code_fast, code_slow)
        return sorted(fast), sorted(slow)

    def test_same_hits_and_lines_with_and_without_probe(self):
        self.build_world()
        for argv in (
            ["--json", "--content", "NADEL", self.root, "--archive-depth", "2"],
            ["--json", "--content", "nadel", self.root, "--archive-depth", "2"],
            ["--json", "--content", "-s", "NADEL", self.root],
            ["--json", "--content", "Größere", self.root],
            ["--json", "--content", "--exact", "zeile mit NADEL", self.root,
             "--archive-depth", "2"],
            ["--json", "--content", "--regex", "NAD.L", self.root],
            ["--json", "--content", "NAD*L", self.root],
            ["--json", "--content", "gibtsnicht", self.root],
        ):
            with self.subTest(argv=argv):
                fast, slow = self.search_with_and_without_probe(argv)
                self.assertEqual(fast, slow)

    def test_line_numbers_stay_exact_in_all_containers(self):
        self.build_world()
        code, lines, _ = run(["--json", "--content", "NADEL", self.root,
                              "--archive-depth", "2"])
        self.assertEqual(code, 0)
        by_name = {}
        for line in lines:
            record = json.loads(line)
            by_name[os.path.basename(record["path"])] = record["line"]
        self.assertEqual(by_name["klein.txt"], 2)
        self.assertEqual(by_name["umlaut.txt"], 2)
        self.assertEqual(by_name["gross.txt"], 20001)
        self.assertEqual(by_name["mit.md"], 2)
        self.assertEqual(by_name["alt.txt"], 2)
        self.assertEqual(by_name["unten.txt"], 3)

    def test_probe_does_not_charge_total_budget_twice(self):
        # Ein Treffer-Mitglied wird zweimal gelesen (Vortest, dann genau).
        # Das Gesamtbudget des Suchlaufs darf davon nur einmal belastet
        # werden, sonst wäre ein Treffer teurer als ein Nicht-Treffer.
        archive = os.path.join(self.root, "budget.zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("mit.txt", "NADEL" + "x" * 59)
        code, lines, err = run([
            "--content", "NADEL", archive,
            "--max-archive-member-bytes", "128",
            "--max-archive-total-bytes", "80",
        ])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertNotIn("Gesamtbudget", err)

    def test_member_budget_still_applies_to_second_pass(self):
        # Die Einzelgrenze bleibt in beiden Durchläufen aktiv.
        archive = os.path.join(self.root, "eng.zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            zf.writestr("mit.txt", "NADEL" + "x" * 200)
        code, lines, err = run([
            "--content", "NADEL", archive,
            "--max-archive-member-bytes", "32",
        ])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Einzelgrenze", err)


class SingleCompressionTest(TempTreeTest):
    """Einzeln komprimierte Dateien (.gz/.bz2/.xz) — Archive mit genau
    einem Eintrag: dem entpackten Inhalt unter dem Namen ohne Endung."""

    CONTENT = "erste Zeile\nzweite Zeile mit NADEL\n"

    def write_bytes(self, rel_path, blob):
        path = os.path.join(self.root, rel_path)
        with open(path, "wb") as handle:
            handle.write(blob)
        return path

    def setUp(self):
        super().setUp()
        raw = self.CONTENT.encode("utf-8")
        self.write_bytes("log.txt.gz", gzip.compress(raw))
        self.write_bytes("log-b.txt.bz2", bz2.compress(raw))
        self.write_bytes("log-x.txt.xz", lzma.compress(raw))

    def test_classify_archive_extensions(self):
        # Die Tar-Familie gewinnt gegen die Einzelkompression.
        self.assertEqual(favenio.classify_archive("a.tar.gz"), "tar")
        self.assertEqual(favenio.classify_archive("a.tgz"), "tar")
        self.assertEqual(favenio.classify_archive("a.tar.bz2"), "tar")
        self.assertEqual(favenio.classify_archive("a.tbz2"), "tar")
        self.assertEqual(favenio.classify_archive("a.tar.xz"), "tar")
        self.assertEqual(favenio.classify_archive("a.txz"), "tar")
        self.assertEqual(favenio.classify_archive("a.zip"), "zip")
        self.assertEqual(favenio.classify_archive("a.GZ"), ".gz")
        self.assertEqual(favenio.classify_archive("a.bz2"), ".bz2")
        self.assertEqual(favenio.classify_archive("a.xz"), ".xz")
        self.assertIsNone(favenio.classify_archive("a.txt"))

    def test_content_hit_with_line_number_in_all_three_formats(self):
        for archive_name, member_name in [
            ("log.txt.gz", "log.txt"),
            ("log-b.txt.bz2", "log-b.txt"),
            ("log-x.txt.xz", "log-x.txt"),
        ]:
            with self.subTest(archive=archive_name):
                path = os.path.join(self.root, archive_name)
                code, lines, _ = run(["--json", "--content", "NADEL", path])
                self.assertEqual(code, 0)
                records = [json.loads(line) for line in lines]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["type"], "member")
                self.assertTrue(records[0]["path"].endswith(
                    archive_name + "!/" + member_name))
                self.assertEqual(records[0]["line"], 2)

    def test_name_search_sees_inner_member(self):
        # Der entpackte Name ist per Namenssuche und Glob auffindbar.
        code, lines, _ = run(["--json", "*.txt", self.root])
        self.assertEqual(code, 0)
        member_paths = [json.loads(line)["path"] for line in lines
                        if json.loads(line)["type"] == "member"]
        self.assertTrue(any(p.endswith("log.txt.gz!/log.txt")
                            for p in member_paths))

    def test_no_archives_skips_decompression(self):
        code, lines, _ = run(["--no-archives", "--content", "NADEL",
                              self.root])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])

    def test_gz_inside_zip_needs_depth_2(self):
        archive = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("brief.txt.gz",
                        gzip.compress("tief drin NADEL\n".encode("utf-8")))
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 1)
        # Option mit Wert VOR dem Muster: der argparse-Wart (BACKLOG 4)
        # verträgt sie beim System-Python nicht zwischen Muster und Pfad.
        code, lines, _ = run(["--json", "--content", "--archive-depth", "2",
                              "NADEL", archive])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith(
            "paket.zip!/brief.txt.gz!/brief.txt"))

    def test_zip_inside_gz_needs_depth_2(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("tief/verstecktes.txt", "GEHEIMNIS ganz unten\n")
        self.write_bytes("innen.zip.gz", gzip.compress(inner.getvalue()))
        code, _, _ = run(["--content", "GEHEIMNIS",
                          os.path.join(self.root, "innen.zip.gz")])
        self.assertEqual(code, 1)
        code, lines, _ = run(["--json", "--content", "--archive-depth", "2",
                              "GEHEIMNIS",
                              os.path.join(self.root, "innen.zip.gz")])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith(
            "innen.zip.gz!/innen.zip!/tief/verstecktes.txt"))

    def test_extract_single_member(self):
        result = os.path.join(self.root, "log.txt.gz") + "!/log.txt"
        code, lines, _ = run(["--extract", result])
        self.assertEqual(code, 0)
        self.assertTrue(lines[0].endswith("log.txt"))
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_extract_nested_chain_through_gz(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("tief/verstecktes.txt", "GEHEIMNIS ganz unten\n")
        self.write_bytes("innen.zip.gz", gzip.compress(inner.getvalue()))
        result = (os.path.join(self.root, "innen.zip.gz")
                  + "!/innen.zip!/tief/verstecktes.txt")
        code, lines, _ = run(["--extract", result])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertIn("ganz unten", handle.read())

    def test_extract_wrong_member_name_exits_2(self):
        # Der einzige gültige Eintrag ist der Name ohne Endung.
        result = os.path.join(self.root, "log.txt.gz") + "!/anders.txt"
        code, _, err = run(["--extract", result])
        self.assertEqual(code, 2)
        self.assertIn("fehler", err)

    def test_corrupt_gz_warns_and_search_continues(self):
        self.write_bytes("kaputt.gz", b"das ist kein gzip")
        self.write("klartext.txt", "hier NADEL im Klartext\n")
        code, lines, err = run(["--json", "--content", "NADEL", self.root])
        self.assertEqual(code, 0)   # der Klartext-Treffer bleibt
        self.assertIn("kaputt.gz", err)
        paths = [json.loads(line)["path"] for line in lines]
        self.assertFalse(any("kaputt" in p for p in paths))

    def test_truncated_gz_warns_without_traceback(self):
        blob = gzip.compress(("NADEL " + "x" * 4096).encode("utf-8"))
        self.write_bytes("halb.txt.gz", blob[:len(blob) // 2])
        code, lines, err = run(["--content", "NADEL",
                                os.path.join(self.root, "halb.txt.gz")])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("halb.txt.gz", err)

    def test_member_budget_applies_to_decompressed_bytes(self):
        code, lines, err = run([
            "--content", "NADEL", os.path.join(self.root, "log.txt.gz"),
            "--max-archive-member-bytes", "8",
        ])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Einzelgrenze", err)

    def test_hidden_compressed_file_skipped_by_default(self):
        self.write_bytes(".geheim.txt.gz",
                         gzip.compress(b"VERBORGEN\n"))
        code, _, _ = run(["--content", "VERBORGEN", self.root])
        self.assertEqual(code, 1)
        code, _, _ = run(["--hidden", "--content", "VERBORGEN", self.root])
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
