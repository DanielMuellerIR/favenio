# Tests für Favenio — laufen mit purem Python:
#   python3 -m unittest discover -s tests
#
# Die Tests bauen sich in setUp() eine kleine Test-Welt in einem
# Temp-Ordner: normale Dateien, ein Zip, ein tar.gz und ein Zip,
# das ein weiteres Zip enthält (für die Verschachtelungs-Tests).

import argparse
import bz2
import gzip
import io
import json
import lzma
import os
import struct
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
import zlib
from contextlib import redirect_stderr, redirect_stdout

# favenio.py liegt eine Ebene über tests/ — Pfad dafür ergänzen.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import favenio  # noqa: E402


def run(argv, cwd=None):
    """Ruft favenio.main() auf und fängt stdout/stderr + Exit-Code ein.
    Liefert (exit_code, stdout_zeilen, stderr_text).

    `cwd` führt den Lauf in einem anderen Arbeitsverzeichnis aus — nötig für
    relative Startpfade, deren Schreibweise Teil des Testfalls ist."""
    out, err = io.StringIO(), io.StringIO()
    previous = os.getcwd() if cwd is not None else None
    if cwd is not None:
        os.chdir(cwd)
    try:
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = favenio.main(argv)
            except SystemExit as exit_info:
                # argparse (parser.error) beendet per SystemExit — Code
                # einfangen.
                code = exit_info.code
    finally:
        if previous is not None:
            os.chdir(previous)
    lines = [line for line in out.getvalue().splitlines() if line]
    return code, lines, err.getvalue()


class TempTreeTest(unittest.TestCase):
    """Gemeinsames Gerüst: ein Temp-Ordner je Test, der danach automatisch
    verschwindet, plus ein Helfer zum Schreiben von Testdateien."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.addCleanup(self.tmp.cleanup)
        # Was der Kern selbst im Temp-Verzeichnis anlegt — der Zielordner
        # von --extract und die Zwischendatei für ein Archiv im Archiv —,
        # soll mit dem Test verschwinden. `--extract` räumt bewusst nicht
        # auf (das tut die App über --extract-root), deshalb blieb je
        # Testlauf über zwanzig `hit-*`-Ordner im Benutzer-Temp-Verzeichnis
        # liegen; auf einem Entwicklungsrechner hatten sich 693 angesammelt,
        # in denen ein echtes Leck gar nicht mehr aufgefallen wäre.
        # Eigener Ordner NEBEN self.root, nicht darin: Sonst liefe eine
        # Suche über self.root mitten durch die Zwischendateien.
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        vorheriges_temp = tempfile.tempdir
        tempfile.tempdir = self.scratch.name
        self.addCleanup(setattr, tempfile, "tempdir", vorheriges_temp)

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

    def test_separator_allows_pattern_with_leading_hyphen(self):
        # Die Swift-Apps setzen vor Muster und Pfad immer `--`. Besonders das
        # macOS-System-Python 3.9 muss danach ein führendes Minus als Text und
        # nicht wieder als Option behandeln.
        self.write("-entwurf.txt", "probe")
        code, lines, err = run(["--json", "--", "-entwurf", self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual([json.loads(line)["path"] for line in lines],
                         [os.path.join(self.root, "-entwurf.txt")])

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

    def test_size_is_absent_when_a_plain_file_cannot_be_stated(self):
        # os.walk liefert einen toten Symlink als Dateinamen, getsize() kann
        # dessen Ziel aber nicht statten. Der Treffer bleibt brauchbar; `size`
        # fehlt nach dem dokumentierten optionalen Vertrag.
        broken = os.path.join(self.root, "kaputte-groesse.txt")
        os.symlink(os.path.join(self.root, "fehlt.txt"), broken)
        code, lines, err = run(["--json", "kaputte-groesse", self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertEqual(record["type"], "file")
        self.assertNotIn("size", record)

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

    def test_max_depth_keeps_dirs_on_the_limit(self):
        # `find -maxdepth N` listet Ordner GENAU auf Tiefe N noch mit; nur
        # ihr Inhalt fällt weg. Früher wurde die Ordnerliste abgeschnitten,
        # BEVOR sie geprüft wurde — dann fand `--max-depth 1 --only dirs`
        # gar nichts.
        os.makedirs(os.path.join(self.root, "ziel-eins", "ziel-zwei"))

        def dirs(value):
            args = ["ziel", self.root, "--only", "dirs", "--no-archives",
                    "--max-depth", str(value)]
            _, lines, _ = run(args)
            return sorted(os.path.relpath(line, self.root) for line in lines)

        self.assertEqual(dirs(1), ["ziel-eins"])
        self.assertEqual(dirs(2), ["ziel-eins",
                                   os.path.join("ziel-eins", "ziel-zwei")])

    def test_max_depth_rejects_zero(self):
        code, _, err = run(["ziel", self.root, "--max-depth", "0"])
        self.assertEqual(code, 2)
        self.assertIn("größer als 0", err)

    def test_archive_depth_rejects_negative(self):
        # Eine negative Tiefe lief vorher stillschweigend wie 0: Der
        # Tippfehler „-1" unterschlug kommentarlos alle Archivtreffer.
        code, _, err = run(["-c", "GEHEIMNIS", self.root,
                            "--archive-depth", "-1"])
        self.assertEqual(code, 2)
        self.assertIn("negativ", err)

    def test_archive_depth_zero_still_means_no_archives(self):
        # 0 bleibt ausdrücklich erlaubt und muss genau wirken wie
        # --no-archives: Treffer in normalen Dateien ja, in Archiven nein.
        zero_code, zero_lines, _ = run(["-c", "GEHEIMNIS", self.root,
                                        "--archive-depth", "0"])
        flag_code, flag_lines, _ = run(["-c", "GEHEIMNIS", self.root,
                                        "--no-archives"])
        self.assertEqual(zero_code, flag_code)
        self.assertEqual(sorted(zero_lines), sorted(flag_lines))
        self.assertFalse([line for line in zero_lines if "!/" in line],
                         zero_lines)
        # Ohne die Begrenzung kommen die Archivtreffer sehr wohl dazu.
        full_code, full_lines, _ = run(["-c", "GEHEIMNIS", self.root])
        self.assertEqual(full_code, 0)
        self.assertTrue([line for line in full_lines if "!/" in line],
                        full_lines)

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
        # Mit Default-Tiefe 1 bleibt das Zip im Zip zu: Kein Treffer zeigt
        # durch beide Ebenen. Das innere Zip selbst ist an der Tiefengrenze
        # aber ein ganz normaler Eintrag, und weil es unkomprimiert im
        # äußeren liegt, steht der Suchtext wirklich in seinen Rohbytes —
        # der Treffer endet deshalb bei „innen.zip".
        code, lines, _ = run(["-c", "ganz unten", self.root])
        self.assertEqual(code, 0)
        self.assertEqual([line.rsplit(":", 1)[0] for line in lines],
                         [os.path.join(self.root, "aussen.zip")
                          + "!/innen.zip"])
        # Mit Tiefe 2 wird es gefunden.
        code, lines, _ = run(["-c", "ganz unten", self.root,
                              "--archive-depth", "2"])
        self.assertEqual(code, 0)
        self.assertTrue(
            any("aussen.zip!/innen.zip!/tief/verstecktes.txt" in line
                for line in lines))

    def test_depth_limit_in_archive_matches_a_missing_tool(self):
        """An der Tiefengrenze IM Archiv gilt dieselbe Regel wie außerhalb.

        Wird in einen Eintrag nicht hineingeschaut, ist er ein ganz normaler
        Eintrag, und sein roher Inhalt wird durchsucht. Sonst entschiede auch
        hier der Grund über das Ergebnis: Ein „.7z" ohne bsdtar wurde
        durchsucht, ein „.zip" an der Tiefengrenze dagegen nicht — ob eine
        Datei überhaupt angefasst wird, hinge dann am Zufall der
        installierten Werkzeuge."""
        inner = io.BytesIO()
        # ZIP_STORED (die Voreinstellung): „NADEL" steht damit wirklich in
        # den Rohbytes des inneren Archivs.
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("drin.txt", "hier steht NADEL drin\n")
        outer = os.path.join(self.root, "behaelter.zip")
        with zipfile.ZipFile(outer, "w") as zf:
            zf.writestr("innen.zip", inner.getvalue())
            # Kein echtes 7z, nur roher Text: ohne bsdtar ist das für
            # classify_archive() eine ganz normale Datei.
            zf.writestr("innen.7z", "nur roher Text mit NADEL\n")
        original = favenio._EXTERNAL_TOOLS
        try:
            favenio._EXTERNAL_TOOLS = (None, None, None)  # Werkzeuge fehlen
            code, lines, _ = run(["--json", "--content", "NADEL", outer])
        finally:
            favenio._EXTERNAL_TOOLS = original
        self.assertEqual(code, 0)
        # Beide Einträge werden gleich behandelt, obwohl der eine wegen der
        # Tiefengrenze und der andere wegen des fehlenden Werkzeugs zu bleibt.
        self.assertEqual(sorted(json.loads(line)["path"] for line in lines),
                         [outer + "!/innen.7z", outer + "!/innen.zip"])

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

    def test_path_notation_resolves_separator_inside_zip_member(self):
        # Der Export der App schreibt in den Pfadformaten nur die !/-Notation,
        # und die zerlegt den Eintrag "odd!/name.txt" in zwei Teile. --extract
        # muss deshalb gegen die Eintragsliste auflösen, sonst hielte es "odd"
        # für ein inneres Archiv (Review-Fund 2026-09-02).
        result = os.path.join(self.root, "paket.zip") + "!/odd!/name.txt"
        code, lines, err = run(["--extract", result])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read(lines[0]), "STRUKTURIERT\n")

    def test_path_notation_resolves_separator_inside_tar_member(self):
        tar_path = os.path.join(self.root, "seltsam.tar")
        with tarfile.open(tar_path, "w") as tf:
            data = b"IM TAR\n"
            info = tarfile.TarInfo("odd!/im-tar.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        code, lines, err = run(["--extract", tar_path + "!/odd!/im-tar.txt"])
        self.assertEqual(code, 0, err)
        self.assertEqual(self.read(lines[0]), "IM TAR\n")

    def test_path_notation_still_descends_into_nested_archives(self):
        # Die Auflösung darf eine echte Verschachtelung nicht verschlucken:
        # Ohne Eintrag "innen.zip!/tief/verstecktes.txt" bleibt "innen.zip"
        # das innere Archiv.
        result = (os.path.join(self.root, "aussen.zip")
                  + "!/innen.zip!/tief/verstecktes.txt")
        code, lines, err = run(["--extract", result])
        self.assertEqual(code, 0, err)
        self.assertIn("ganz unten", self.read(lines[0]))

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

    def test_option_with_value_between_pattern_and_path(self):
        # Optionen dürfen wie bei üblichen CLI-Werkzeugen zwischen den
        # Positionsargumenten stehen. Das ist besonders praktisch, wenn ein
        # vorhandener Aufruf nachträglich um eine Suchoption ergänzt wird.
        code, lines, err = run([
            "--json", "--content", "GEHEIMNIS",
            "--archive-depth", "2", self.root,
        ])
        self.assertEqual(code, 0, err)
        paths = [json.loads(line)["path"] for line in lines]
        self.assertTrue(any(path.endswith(
            "aussen.zip!/innen.zip!/tief/verstecktes.txt")
            for path in paths))

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

    def test_probe_survives_greek_sigma_at_chunk_boundary(self):
        # str.lower() macht aus „Σ" am Wortende ein „ς", sonst ein „σ". Der
        # Vortest sieht Häppchen, der genaue Lauf ganze Zeilen — an der
        # Häppchengrenze kam deshalb früher ein anderes Zeichen heraus und der
        # Vortest verschluckte den Treffer.
        text = "ΟΣ und mehr"
        for chunk_size in (1, 2, 3, 4, 8):
            self.assertTrue(
                self.probe_hits("ΟΣ", text.encode(), chunk_size=chunk_size),
                "Häppchengröße %d" % chunk_size)
            self.assertTrue(
                self.probe_hits("οσ", text.encode(), chunk_size=chunk_size),
                "Häppchengröße %d, kleingeschrieben" % chunk_size)

    def test_sigma_hit_survives_the_real_chunk_boundary(self):
        # Dasselbe an der echten CHUNK_SIZE-Grenze, einmal quer durch die
        # ganze Suche: mit Vortest muss dasselbe herauskommen wie ohne.
        filler = "a" * (favenio.CHUNK_SIZE - len("Ο".encode()))
        self.write("sigma.txt", filler + "ΟΣ und mehr\n")
        fast, slow = self.search_with_and_without_probe(
            ["--json", "--content", "ΟΣ", self.root])
        self.assertEqual(len(fast), 1)
        self.assertEqual(fast, slow)

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

    def test_second_pass_pays_for_bytes_the_probe_never_read(self):
        # Der Vortest hört beim ersten Fund auf; bei --exact liest der genaue
        # Lauf danach die ganze lange Zeile weiter. Früher war der ZWEITE
        # Durchlauf komplett vom Gesamtbudget befreit — damit ließ sich
        # --max-archive-total-bytes um Größenordnungen umgehen. Freigestellt
        # ist nur, was der Vortest wirklich gelesen hat.
        archive = os.path.join(self.root, "lang.zip")
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zf:
            # Eine einzige sehr lange Zeile, die mit dem Suchtext BEGINNT:
            # Der Vortest ist nach dem ersten Häppchen fertig, der genaue
            # Lauf muss die Zeile bis zum Ende lesen.
            zf.writestr("lang.txt", "NADEL" + "x" * (3 * favenio.CHUNK_SIZE))
        argv = ["--content", "--exact", "NADEL", archive,
                "--max-archive-total-bytes", str(favenio.CHUNK_SIZE + 100)]
        code, lines, err = run(argv)
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Gesamtbudget", err)
        # Gegenprobe: ohne Vortest verhält sich der Lauf genauso.
        fast, slow = self.search_with_and_without_probe(argv)
        self.assertEqual(fast, slow)

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

    def test_size_is_absent_because_the_format_does_not_state_it(self):
        """`size` ist ein optionales Feld — hier fehlt es mit Absicht.

        Eine `.gz`/`.bz2`/`.xz` nennt die entpackte Größe nicht vorab; sie
        stünde erst nach vollständigem Entpacken fest, und die Suche hört beim
        ersten Treffer auf. Der Vertrag in beiden READMEs und in AGENTS sagt
        das ausdrücklich; dieser Test hält beide Seiten zusammen (Review-Fund
        2026-08-20). Der Zip-Eintrag daneben belegt, dass `size` überall dort
        weiterhin kommt, wo das Format die Größe im Verzeichnis führt."""
        for archive_name in ("log.txt.gz", "log-b.txt.bz2", "log-x.txt.xz"):
            with self.subTest(archive=archive_name):
                path = os.path.join(self.root, archive_name)
                code, lines, _ = run(["--json", "--content", "NADEL", path])
                self.assertEqual(code, 0)
                record = json.loads(lines[0])
                self.assertNotIn("size", record)

        zip_path = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(zip_path, "w") as zf:
            zf.writestr("innen.txt", self.CONTENT)
        code, lines, _ = run(["--json", "--content", "NADEL", zip_path])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(lines[0])["size"],
                         len(self.CONTENT.encode("utf-8")))

    def test_name_search_sees_inner_member(self):
        # Der entpackte Name ist per Namenssuche und Glob auffindbar.
        code, lines, _ = run(["--json", "*.txt", self.root])
        self.assertEqual(code, 0)
        member_paths = [json.loads(line)["path"] for line in lines
                        if json.loads(line)["type"] == "member"]
        self.assertTrue(any(p.endswith("log.txt.gz!/log.txt")
                            for p in member_paths))

    def test_no_archives_treats_them_as_plain_files(self):
        """`--no-archives` heißt „nicht hineinschauen", nicht „auslassen".

        Die Datei bleibt dann eine ganz normale Datei, und ihr ROHER Inhalt
        wird durchsucht — genau wie bei einer .7z ohne bsdtar. Entpackt wird
        nichts: Es darf keinen `!/`-Treffer geben. Dass dabei ausgerechnet
        das xz-Fixture anschlägt, ist kein Zufall und kein Fehler — LZMA legt
        eine so kurze Eingabe fast unverändert als Literale ab, „NADEL" steht
        dort also wirklich in den Rohbytes."""
        code, lines, _ = run(["--no-archives", "--content", "NADEL",
                              self.root])
        self.assertEqual(code, 0)
        self.assertFalse([line for line in lines if "!/" in line], lines)
        for line in lines:
            path = line.rsplit(":", 1)[0]
            with self.subTest(hit=path):
                with open(path, "rb") as handle:
                    self.assertIn(b"NADEL", handle.read())

    def test_no_archives_matches_a_missing_tool_exactly(self):
        """Der Grund, warum nicht hineingeschaut wird, darf das Ergebnis
        nicht ändern: Ob `--no-archives` es verbietet oder das Werkzeug fehlt,
        muss dieselbe Trefferliste ergeben. Sonst hinge es vom Zufall der
        installierten Werkzeuge ab, ob eine Datei überhaupt angefasst wird."""
        # Eine .zst-Datei, deren ROHE Bytes den Suchtext enthalten. Ob ein
        # echtes zstd vorhanden ist, spielt für diesen Test keine Rolle.
        self.write_bytes("daten.zst", b"unkomprimiert MERKMAL drin\n")
        original = favenio._EXTERNAL_TOOLS
        try:
            # Beide Seiten ausdrücklich festnageln, damit der Test überall
            # dasselbe prüft und nicht davon abhängt, ob auf der Maschine
            # zufällig ein zstd liegt (auf einem CI-Runner meist nicht).
            # Der Pfad wird nie ausgeführt: Mit --no-archives steigt die Suche
            # gar nicht erst in das Archiv ein.
            favenio._EXTERNAL_TOOLS = (None, "/usr/bin/true", None)
            self.assertEqual(favenio.classify_archive("daten.zst"), ".zst")
            with_flag = run(["--json", "--no-archives", "--content",
                             "MERKMAL", self.root])
            favenio._EXTERNAL_TOOLS = (None, None, None)  # Werkzeug fehlt
            self.assertIsNone(favenio.classify_archive("daten.zst"))
            without_tool = run(["--json", "--content", "MERKMAL", self.root])
        finally:
            favenio._EXTERNAL_TOOLS = original
        self.assertEqual(with_flag[0], without_tool[0])
        self.assertEqual(sorted(with_flag[1]), sorted(without_tool[1]))
        paths = [json.loads(line)["path"] for line in with_flag[1]]
        self.assertTrue(any(p.endswith("daten.zst") for p in paths), paths)

    def test_gz_inside_zip_needs_depth_2(self):
        archive = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("brief.txt.gz",
                        gzip.compress("tief drin NADEL\n".encode("utf-8")))
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 1)
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
        # Tiefe 1 entpackt das .gz, steigt aber nicht mehr in das Zip darin
        # ein. Das Zip ist damit ein ganz normaler Eintrag; sein roher Inhalt
        # trägt den Suchtext, weil es unkomprimiert gespeichert ist.
        code, lines, _ = run(["--content", "GEHEIMNIS",
                              os.path.join(self.root, "innen.zip.gz")])
        self.assertEqual(code, 0)
        self.assertEqual([line.rsplit(":", 1)[0] for line in lines],
                         [os.path.join(self.root, "innen.zip.gz")
                          + "!/innen.zip"])
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

    def test_search_output_is_extractable_in_all_three_formats(self):
        # Suche und Extraktion leiten den Eintragsnamen aus derselben Regel
        # ab (single_member_name). Der Test nagelt genau diese Kopplung fest:
        # Er nimmt den Pfad, den die SUCHE ausgibt, und reicht ihn unverändert
        # an --extract weiter. Driften beide Seiten auseinander, wäre ein
        # .gz/.bz2/.xz-Treffer nicht mehr auszupacken.
        code, lines, _ = run(["--json", "--content", "NADEL", self.root])
        self.assertEqual(code, 0)
        hits = [json.loads(line) for line in lines]
        self.assertEqual(len(hits), 3, hits)
        for hit in hits:
            with self.subTest(hit=hit["path"]):
                code, out, err = run(["--extract", hit["path"]])
                self.assertEqual(code, 0, err)
                with open(out[0], encoding="utf-8") as handle:
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

    def test_zstd_start_failure_leaves_no_temp_file(self):
        # .zst gehört zur Einzelkompression, wird aber vom externen
        # zstd-Programm gelesen. Für Daten aus dem Speicher legt zstd_open
        # vorher eine Temp-Datei an. Verschwindet das gemerkte Programm,
        # scheitert schon der Prozessstart — dann gibt es keinen ToolStream,
        # der die Temp-Datei später aufräumen würde.
        original_tools = favenio._EXTERNAL_TOOLS
        original_tempdir = tempfile.tempdir
        spool = os.path.join(self.root, "spool")
        os.makedirs(spool)
        favenio._EXTERNAL_TOOLS = (None,
                                   os.path.join(self.root, "gibt-es-nicht"),
                                   None)
        tempfile.tempdir = spool
        try:
            with self.assertRaises(OSError):
                favenio.zstd_open(io.BytesIO(b"komprimierte bytes"))
        finally:
            tempfile.tempdir = original_tempdir
            favenio._EXTERNAL_TOOLS = original_tools
        self.assertEqual(os.listdir(spool), [])

    def test_hidden_compressed_file_skipped_by_default(self):
        self.write_bytes(".geheim.txt.gz",
                         gzip.compress(b"VERBORGEN\n"))
        code, _, _ = run(["--content", "VERBORGEN", self.root])
        self.assertEqual(code, 1)
        code, _, _ = run(["--hidden", "--content", "VERBORGEN", self.root])
        self.assertEqual(code, 0)


def have_bsdtar():
    return favenio.external_archive_tools()[0] is not None


def have_zstd():
    return favenio.external_archive_tools()[1] is not None


@unittest.skipUnless(have_bsdtar(), "bsdtar nicht gefunden")
class BsdtarFormatsTest(TempTreeTest):
    """Formate, die nur über das externe bsdtar lesbar sind (7z, ISO,
    tar.zst) — plus einzelne .zst über das zstd-Programm."""

    CONTENT = "erste Zeile\nzweite Zeile mit NADEL\n"

    def make_archive(self, archive_rel, fmt, tree):
        """Baut über bsdtar ein Archiv (7zip/iso9660) aus `tree`
        (rel_pfad -> text) und legt es unter self.root ab."""
        bsdtar = favenio.external_archive_tools()[0]
        archive = os.path.join(self.root, archive_rel)
        with tempfile.TemporaryDirectory() as staging:
            for rel_path, text in tree.items():
                full = os.path.join(staging, rel_path)
                os.makedirs(os.path.dirname(full), exist_ok=True)
                with open(full, "w", encoding="utf-8") as handle:
                    handle.write(text)
            # "." packt den ganzen Baum ein — inklusive der expliziten
            # Ordnereinträge, die 7z mit und ISO ohne Schrägstrich listet.
            subprocess.run(
                [bsdtar, "-cf", archive, "--format", fmt, "-C", staging,
                 "."],
                check=True)
        return archive

    def test_an_oversized_entry_list_is_skipped_with_a_warning(self):
        # Der Namenskatalog läuft an ArchiveBudget vorbei — das zählt nur
        # Eintrags-INHALTE. Bei 7z, ISO und tar.zst liegt er komprimiert
        # im Archiv und wirkt deshalb mit Verstärkungsfaktor: 307 KB
        # Archiv trieben den Speicher auf 182 MB.
        # Geprüft wird mit einer winzigen Grenze, damit der Test schnell
        # bleibt; die echte Konstante steht daneben.
        bsdtar = favenio.external_archive_tools()[0]
        if bsdtar is None:
            self.skipTest("bsdtar nicht verfügbar")
        archive = self.make_archive(
            "viele.7z", "7zip",
            {"ordner/datei_%03d.txt" % i: self.CONTENT for i in range(40)})
        self.write("danach.txt", self.CONTENT)

        vorher = favenio.MAX_ARCHIVE_LISTING_BYTES
        favenio.MAX_ARCHIVE_LISTING_BYTES = 64
        try:
            code, lines, err = run(["--content", "NADEL", self.root])
        finally:
            favenio.MAX_ARCHIVE_LISTING_BYTES = vorher
        self.assertIn("Eintragsliste größer", err)
        # Das Archiv fällt aus, aber der Lauf geht weiter.
        self.assertEqual(code, 0)
        self.assertTrue(any(line.endswith("danach.txt:2") for line in lines),
                        lines)
        # Ohne die kleine Grenze wird dasselbe Archiv normal durchsucht.
        code, lines, err = run(["--content", "NADEL", self.root])
        self.assertEqual(code, 0)
        self.assertNotIn("Eintragsliste größer", err)
        self.assertTrue(any("viele.7z!/" in line for line in lines), lines)

    def test_7z_content_hit_with_line_number(self):
        archive = self.make_archive("arch.7z", "7zip",
                                    {"docs/brief.txt": self.CONTENT})
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0)
        records = [json.loads(line) for line in lines]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["type"], "member")
        self.assertTrue(records[0]["path"].endswith(
            "arch.7z!/docs/brief.txt"))
        self.assertEqual(records[0]["line"], 2)

    def test_7z_directory_entry_counts_as_dir(self):
        self.make_archive("arch.7z", "7zip",
                          {"docs/brief.txt": self.CONTENT})
        code, lines, _ = run(["--json", "--only", "dirs", "docs",
                              self.root])
        self.assertEqual(code, 0)
        self.assertTrue(any(json.loads(line)["path"].endswith(
            "arch.7z!/docs") for line in lines))

    def test_iso_content_hit_and_dir_detection(self):
        # ISO listet Ordner OHNE Schrägstrich; die Ordner-Erkennung läuft
        # über die darunterliegenden Einträge.
        archive = self.make_archive("scheibe.iso", "iso9660",
                                    {"unter/tief.txt": self.CONTENT})
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith(
            "scheibe.iso!/unter/tief.txt"))
        self.assertEqual(record["line"], 2)
        code, lines, _ = run(["--json", "--only", "dirs", "unter", archive])
        self.assertEqual(code, 0)
        self.assertTrue(any(json.loads(line)["path"].endswith(
            "scheibe.iso!/unter") for line in lines))

    def test_extract_7z_member(self):
        archive = self.make_archive("arch.7z", "7zip",
                                    {"docs/brief.txt": self.CONTENT})
        code, lines, _ = run(["--extract", archive + "!/docs/brief.txt"])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_extract_missing_7z_member_exits_2(self):
        archive = self.make_archive("arch.7z", "7zip",
                                    {"docs/brief.txt": self.CONTENT})
        code, _, err = run(["--extract", archive + "!/gibtsnicht.txt"])
        self.assertEqual(code, 2)
        self.assertIn("fehler", err)

    def test_glob_characters_in_member_name_stay_literal(self):
        # Ohne Escaping würde das Muster "a*.txt" auch "abc.txt" treffen
        # und bsdtar beide Inhalte aneinanderhängen.
        archive = self.make_archive("stern.7z", "7zip",
                                    {"a*.txt": "x\n", "abc.txt": "ABC\n"})
        code, lines, _ = run(["--extract", archive + "!/a*.txt"])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "x\n")

    def test_extract_finds_a_member_with_control_character_and_bang(self):
        # Suche und --extract müssen die Auflistung von `bsdtar -tf` gleich
        # lesen. Der Eintragsname trägt hier beides: ein maskiertes
        # Steuerzeichen UND ein "!/", das die Trefferschreibweise mehrdeutig
        # macht und pick_member() zur Eintragsliste zwingt.
        archive = self.make_archive(
            "sonder.7z", "7zip", {"odd!/tab\tname.txt": self.CONTENT})
        code, lines, err = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0, err)
        hit = json.loads(lines[0])["path"]
        self.assertTrue(hit.endswith("sonder.7z!/odd!/tab\tname.txt"), hit)
        code, lines, err = run(["--extract", hit])
        self.assertEqual(code, 0, err)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_control_characters_in_member_names_stay_real(self):
        # `bsdtar -tf` maskiert Steuerzeichen und Backslashes im Namen (aus
        # einem Tabulator werden die zwei Zeichen \t). Wird die Auflistung
        # ungeprüft übernommen, trägt der Treffer einen falschen Pfad und der
        # zweite bsdtar-Aufruf findet den Eintrag nicht mehr.
        names = {"tab\tname.txt": self.CONTENT,
                 "back\\slash.txt": self.CONTENT,
                 "schlicht.txt": self.CONTENT}
        archive = self.make_archive("sonder.7z", "7zip", names)
        code, lines, err = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0)
        found = {json.loads(line)["path"].split("!/", 1)[1]
                 for line in lines}
        self.assertEqual(found, set(names))
        self.assertNotIn("Entpackwerkzeug", err)
        # Und der Pfad taugt danach auch zum Materialisieren.
        code, lines, _ = run(["--extract", archive + "!/tab\tname.txt"])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_bsdtar_unescape_reverses_the_listing_format(self):
        self.assertEqual(favenio.bsdtar_unescape(rb"tab\tname.txt"),
                         b"tab\tname.txt")
        self.assertEqual(favenio.bsdtar_unescape(rb"back\\slash.txt"),
                         b"back\\slash.txt")
        # Ein echter Backslash kommt maskiert an; die Ziffern danach bleiben
        # dadurch Ziffern und werden nicht als Oktalfolge gelesen.
        self.assertEqual(favenio.bsdtar_unescape(rb"a\\123.txt"),
                         b"a\\123.txt")
        # Nicht druckbare Bytes kommen dreistellig oktal (hier UTF-8 für „ä").
        self.assertEqual(favenio.bsdtar_unescape(rb"gr\303\244n"),
                         "grän".encode("utf-8"))
        self.assertEqual(favenio.bsdtar_unescape(b"schlicht.txt"),
                         b"schlicht.txt")

    def test_zip_inside_7z_needs_depth_2(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as zf:
            zf.writestr("tief/verstecktes.txt", "GEHEIMNIS ganz unten\n")
        bsdtar = favenio.external_archive_tools()[0]
        archive = os.path.join(self.root, "aussen.7z")
        with tempfile.TemporaryDirectory() as staging:
            with open(os.path.join(staging, "innen.zip"), "wb") as handle:
                handle.write(inner.getvalue())
            subprocess.run([bsdtar, "-cf", archive, "--format", "7zip",
                            "-C", staging, "innen.zip"], check=True)
        # Tiefe 1 liest das 7z, steigt aber nicht in das Zip darin ein: Der
        # Eintrag zählt dann als ganz normale Datei, und der Suchtext steht
        # roh in seinen Bytes (das Zip ist unkomprimiert gespeichert).
        code, lines, _ = run(["--content", "GEHEIMNIS", archive])
        self.assertEqual(code, 0)
        self.assertEqual([line.rsplit(":", 1)[0] for line in lines],
                         [archive + "!/innen.zip"])
        code, lines, _ = run(["--json", "--content", "--archive-depth", "2",
                              "GEHEIMNIS", archive])
        self.assertEqual(code, 0)
        self.assertTrue(json.loads(lines[0])["path"].endswith(
            "aussen.7z!/innen.zip!/tief/verstecktes.txt"))

    def test_7z_inside_zip_needs_depth_2(self):
        # Das innere 7z liegt nur im Speicher — bsdtar bekommt es über
        # eine Temp-Datei gereicht.
        seven = self.make_archive("innen.7z", "7zip",
                                  {"docs/brief.txt": self.CONTENT})
        with open(seven, "rb") as handle:
            seven_bytes = handle.read()
        os.unlink(seven)
        outer = os.path.join(self.root, "aussen.zip")
        with zipfile.ZipFile(outer, "w") as zf:
            zf.writestr("innen.7z", seven_bytes)
        code, lines, _ = run(["--json", "--content", "--archive-depth", "2",
                              "NADEL", outer])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith(
            "aussen.zip!/innen.7z!/docs/brief.txt"))
        self.assertEqual(record["line"], 2)
        # Und die Extraktionskette durch beide Ebenen:
        code, lines, _ = run(["--extract",
                              outer + "!/innen.7z!/docs/brief.txt"])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_corrupt_7z_warns_and_search_continues(self):
        with open(os.path.join(self.root, "kaputt.7z"), "wb") as handle:
            handle.write(b"das ist kein 7z")
        self.write("klartext.txt", "hier NADEL im Klartext\n")
        code, lines, err = run(["--json", "--content", "NADEL", self.root])
        self.assertEqual(code, 0)
        self.assertIn("kaputt.7z", err)
        paths = [json.loads(line)["path"] for line in lines]
        self.assertFalse(any("kaputt" in p for p in paths))

    def test_member_budget_applies_to_7z(self):
        archive = self.make_archive("arch.7z", "7zip",
                                    {"docs/brief.txt": self.CONTENT})
        code, lines, err = run([
            "--content", "NADEL", archive,
            "--max-archive-member-bytes", "8",
        ])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("Einzelgrenze", err)

    def test_without_tools_files_stay_plain(self):
        # Simuliert „Werkzeuge fehlen": die Endungen zählen dann nicht als
        # Archiv, die Dateien bleiben normale Dateien (Verhalten vor der
        # Integration).
        original = favenio._EXTERNAL_TOOLS
        favenio._EXTERNAL_TOOLS = (None, None, None)
        try:
            self.assertIsNone(favenio.classify_archive("a.7z"))
            self.assertIsNone(favenio.classify_archive("a.iso"))
            self.assertIsNone(favenio.classify_archive("a.tar.zst"))
            self.assertIsNone(favenio.classify_archive("a.zst"))
        finally:
            favenio._EXTERNAL_TOOLS = original

    def test_tar_zst_needs_both_tools(self):
        original = favenio.external_archive_tools()
        favenio._EXTERNAL_TOOLS = (original[0], None, None)
        try:
            self.assertIsNone(favenio.classify_archive("a.tar.zst"))
            self.assertIsNone(favenio.classify_archive("a.zst"))
            self.assertEqual(favenio.classify_archive("a.7z"), "bsdtar")
        finally:
            favenio._EXTERNAL_TOOLS = original

    def test_tar_zst_without_bsdtar_is_no_archive(self):
        # Die andere Hälfte: zstd da, bsdtar nicht. „a.tar.zst" endet auch auf
        # „.zst" und wurde früher als einzeln komprimierte Datei behandelt —
        # der entpackte Tar-Strom erschien dann als Mitglied „a.tar".
        original = favenio.external_archive_tools()
        # Der Test ordnet nur Dateinamen zu und startet zstd nie. Die Klasse
        # hängt aber allein an bsdtar: Fehlt zstd auf dem Rechner, wäre
        # original[1] None und „a.zst" käme als „kein Archiv" zurück. Deshalb
        # hier ein garantiert nicht leerer Pfad statt des echten Fundorts.
        zstd = original[1] or "/usr/bin/zstd"
        favenio._EXTERNAL_TOOLS = (None, zstd, original[2])
        try:
            self.assertIsNone(favenio.classify_archive("a.tar.zst"))
            self.assertIsNone(favenio.classify_archive("a.tzst"))
            self.assertIsNone(favenio.classify_archive("a.7z"))
            self.assertEqual(favenio.classify_archive("a.zst"), ".zst")
        finally:
            favenio._EXTERNAL_TOOLS = original


@unittest.skipUnless(have_bsdtar() and have_zstd(),
                     "bsdtar oder zstd nicht gefunden")
class ZstdFormatsTest(TempTreeTest):
    """Zstandard-Formate: tar.zst über bsdtar, einzelne .zst über zstd."""

    CONTENT = "erste Zeile\nzweite Zeile mit NADEL\n"

    def setUp(self):
        super().setUp()
        self.zstd = favenio.external_archive_tools()[1]

    def compress(self, blob, archive_rel):
        source = os.path.join(self.root, archive_rel + ".roh")
        with open(source, "wb") as handle:
            handle.write(blob)
        target = os.path.join(self.root, archive_rel)
        subprocess.run([self.zstd, "-q", "-o", target, source], check=True)
        os.unlink(source)
        return target

    def test_tar_zst_content_hit(self):
        tar_bytes = io.BytesIO()
        with tarfile.open(fileobj=tar_bytes, mode="w") as tf:
            data = self.CONTENT.encode("utf-8")
            info = tarfile.TarInfo("sicherung/alt.txt")
            info.size = len(data)
            tf.addfile(info, io.BytesIO(data))
        archive = self.compress(tar_bytes.getvalue(), "backup.tar.zst")
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith(
            "backup.tar.zst!/sicherung/alt.txt"))
        self.assertEqual(record["line"], 2)

    def test_single_zst_content_hit_and_extract(self):
        archive = self.compress(self.CONTENT.encode("utf-8"), "log.txt.zst")
        code, lines, _ = run(["--json", "--content", "NADEL", archive])
        self.assertEqual(code, 0)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith("log.txt.zst!/log.txt"))
        self.assertEqual(record["line"], 2)
        code, lines, _ = run(["--extract", archive + "!/log.txt"])
        self.assertEqual(code, 0)
        with open(lines[0], encoding="utf-8") as handle:
            self.assertEqual(handle.read(), self.CONTENT)

    def test_corrupt_zst_warns_without_traceback(self):
        with open(os.path.join(self.root, "kaputt.txt.zst"), "wb") as handle:
            handle.write(b"kein zstd")
        code, lines, err = run(["--content", "NADEL",
                                os.path.join(self.root, "kaputt.txt.zst")])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        self.assertIn("kaputt.txt.zst", err)


class ArchiveDirectoryFlagTest(TempTreeTest):
    """Review-Fund 2026-08-17: Ein ORDNER im Archiv kam als `type: "member"`
    ohne jedes Verzeichnismerkmal an. Die Oberfläche zeigte ihn deshalb als
    Datei, und beim Öffnen entstand eine leere Datei (ZIP) bzw. die Extraktion
    scheiterte (TAR). Das JSONL trägt das Merkmal jetzt als `isDirectory`."""

    def setUp(self):
        super().setUp()
        self.archive = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(self.archive, "w") as zf:
            zf.writestr("nadel/", "")                 # Verzeichniseintrag
            zf.writestr("nadel/datei.txt", "inhalt")

    def records(self, argv):
        code, lines, _ = run(argv)
        return code, [json.loads(line) for line in lines]

    def test_archive_directory_is_marked_as_directory(self):
        code, records = self.records(["--json", "nadel", self.root])
        self.assertEqual(code, 0)
        directories = [r for r in records if r.get("isDirectory")]
        self.assertEqual(len(directories), 1, records)
        self.assertEqual(directories[0]["type"], "member")
        self.assertTrue(directories[0]["path"].endswith("!/nadel"))

    def test_archive_file_is_not_marked_as_directory(self):
        code, records = self.records(["--json", "datei", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(records)
        self.assertFalse(any(r.get("isDirectory") for r in records), records)

    def test_only_dirs_keeps_the_archive_directory(self):
        code, records = self.records(
            ["--json", "--only", "dirs", "nadel", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(records)
        self.assertTrue(all(r.get("isDirectory") for r in records), records)

    def test_filesystem_directory_is_marked_too(self):
        os.makedirs(os.path.join(self.root, "nadelordner"))
        code, records = self.records(
            ["--json", "--only", "dirs", "nadelordner", self.root])
        self.assertEqual(code, 0)
        self.assertEqual([r["type"] for r in records], ["dir"])
        self.assertTrue(records[0]["isDirectory"])


# ---------------------------------------------------------------------------
# Bildmaße und Metadaten (v0.26.0)
# ---------------------------------------------------------------------------

def png_bytes(width, height):
    """Ein gültiges, winziges PNG mit den gewünschten Maßen."""
    import struct
    import zlib

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))
    raw = b"".join(b"\x00" + b"\x10\x20\x30" * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                         8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def jpeg_head(width, height):
    """Nur der Kopf eines JPEG: SOI, ein APP1-Segment (wie EXIF), ein
    Kommentar und dann SOF0 mit den Maßen. Für den Maß-Leser reicht das —
    er hört beim SOF-Marker auf."""
    import struct
    app1 = b"Exif\x00\x00" + b"\x00" * 40
    comment = b"probe"
    sof = struct.pack(">BHH", 8, height, width) + b"\x03" + b"\x00" * 9
    return (b"\xff\xd8"
            + b"\xff\xe1" + struct.pack(">H", len(app1) + 2) + app1
            + b"\xff\xfe" + struct.pack(">H", len(comment) + 2) + comment
            + b"\xff\xc0" + struct.pack(">H", len(sof) + 2) + sof
            + b"\xff\xd9")


def gif_bytes(width, height):
    import struct
    return b"GIF89a" + struct.pack("<HH", width, height) + b"\x00" * 20


def bmp_bytes(width, height):
    import struct
    return (b"BM" + struct.pack("<IHHI", 54, 0, 0, 54)
            + struct.pack("<Iii", 40, width, -height) + b"\x00" * 28)


def webp_vp8x_bytes(width, height):
    return (b"RIFF" + b"\x00\x00\x00\x00" + b"WEBP" + b"VP8X"
            + b"\x0a\x00\x00\x00" + b"\x00" * 4
            + (width - 1).to_bytes(3, "little")
            + (height - 1).to_bytes(3, "little") + b"\x00" * 8)


def webp_vp8l_bytes(width, height):
    bits = ((width - 1) | ((height - 1) << 14))
    return (b"RIFF" + b"\x00\x00\x00\x00" + b"WEBP" + b"VP8L"
            + b"\x0a\x00\x00\x00" + b"\x2f"
            + bits.to_bytes(4, "little") + b"\x00" * 8)


def tiff_bytes(width, height, endian="<"):
    import struct
    magic = b"II*\x00" if endian == "<" else b"MM\x00*"
    entries = [(0x0100, 4, 1, width), (0x0101, 3, 1, height)]
    ifd = struct.pack(endian + "H", len(entries))
    for tag, kind, count, value in entries:
        if kind == 3:
            ifd += struct.pack(endian + "HHIH2x", tag, kind, count, value)
        else:
            ifd += struct.pack(endian + "HHII", tag, kind, count, value)
    ifd += struct.pack(endian + "I", 0)
    return magic + struct.pack(endian + "I", 8) + ifd


class ImageDimensionsTest(unittest.TestCase):
    """Der eingebaute Maß-Leser: nur Standardbibliothek, liest nur vorwärts
    und gibt für jedes Kopfformat Breite und Höhe zurück."""

    def dims(self, blob):
        return favenio.image_dimensions(io.BytesIO(blob))

    def test_reads_every_supported_header(self):
        cases = {
            "png": png_bytes(1200, 800),
            "jpeg": jpeg_head(1200, 800),
            "gif": gif_bytes(1200, 800),
            "bmp": bmp_bytes(1200, 800),
            "webp-vp8x": webp_vp8x_bytes(1200, 800),
            "webp-vp8l": webp_vp8l_bytes(1200, 800),
            "tiff-le": tiff_bytes(1200, 800, "<"),
            "tiff-be": tiff_bytes(1200, 800, ">"),
        }
        for name, blob in cases.items():
            with self.subTest(format=name):
                self.assertEqual(self.dims(blob), (1200, 800))

    def test_unknown_or_truncated_input_yields_none(self):
        self.assertIsNone(self.dims(b"kein Bild, nur Text\n"))
        self.assertIsNone(self.dims(b""))
        self.assertIsNone(self.dims(png_bytes(10, 10)[:20]))
        self.assertIsNone(self.dims(jpeg_head(10, 10)[:12]))
        # Ein JPEG ohne SOF vor den Bilddaten hat keine lesbaren Maße.
        self.assertIsNone(self.dims(b"\xff\xd8\xff\xda\x00\x02"))

    def test_truncated_webp_headers_yield_none_instead_of_crashing(self):
        # Ein halber Download endet mitten im Kopf. Bis 0.26.1 griff der
        # VP8L-Zweig dann mit bits[1] ins Leere: ein IndexError, den
        # image_dimensions() nicht fing und der den GANZEN Suchlauf
        # beendete. VP8X las aus leeren Slices still 1×1 Pixel — ein
        # Falschtreffer für jeden --max-width-Lauf.
        riff = b"RIFF" + b"\x00\x00\x00\x00" + b"WEBP"
        for label, blob in {
                "vp8l-abgeschnitten": riff + b"VP8L\x00\x00\x00\x00\x2f\x00",
                "vp8x-abgeschnitten": riff + b"VP8X\x00\x00\x00\x00",
                "vp8-abgeschnitten": riff + b"VP8 \x00\x00\x00\x00",
                "nur-signatur": riff,
        }.items():
            with self.subTest(fall=label):
                self.assertIsNone(self.dims(blob))
        # Die vollständigen Köpfe müssen weiterhin gelesen werden.
        self.assertEqual(self.dims(webp_vp8l_bytes(1200, 800)), (1200, 800))
        self.assertEqual(self.dims(webp_vp8x_bytes(1200, 800)), (1200, 800))

    def test_reader_never_seeks_backwards(self):
        # Archiv-Einträge aus bsdtar kommen als Pipe: Der Leser darf
        # ausschließlich read() benutzen.
        class ForwardOnly:
            def __init__(self, blob):
                self.blob = io.BytesIO(blob)

            def read(self, count):
                return self.blob.read(count)
        self.assertEqual(
            favenio.image_dimensions(ForwardOnly(jpeg_head(640, 480))),
            (640, 480))
        self.assertEqual(
            favenio.image_dimensions(ForwardOnly(tiff_bytes(640, 480))),
            (640, 480))

    def test_implausible_header_sizes_are_no_dimensions(self):
        # Ein beschädigter oder präparierter Kopf kann jede 32-Bit-Zahl
        # nennen. 0xffffffff je Kante ließ die Flächensortierung der App
        # über Int.max laufen und beendete den Prozess.
        import struct
        def png_head(width, height):
            return (b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR"
                    + struct.pack(">II", width, height)
                    + b"\x08\x02\x00\x00\x00")
        self.assertIsNone(self.dims(png_head(0xFFFFFFFF, 0xFFFFFFFF)))
        self.assertIsNone(self.dims(png_head(0, 100)))
        self.assertEqual(self.dims(png_head(2 ** 31 - 1, 1)),
                         (2 ** 31 - 1, 1))


class DimensionFilterTest(TempTreeTest):
    """--min-width/--max-width/--min-height/--max-height: Pixelfilter, die
    immer zusätzlich (UND) zum Muster gelten."""

    def setUp(self):
        super().setUp()
        self.write_bytes("breit.png", png_bytes(1200, 800))
        self.write_bytes("hoch.png", png_bytes(300, 1500))
        self.write_bytes("foto.jpg", jpeg_head(1000, 1000))
        self.write("notiz.txt", "kein Bild\n")
        os.makedirs(os.path.join(self.root, "breit-ordner"))
        with zipfile.ZipFile(os.path.join(self.root, "bilder.zip"),
                             "w") as zf:
            zf.writestr("drin/riesig.png", png_bytes(4000, 100))

    def write_bytes(self, rel_path, blob):
        path = os.path.join(self.root, rel_path)
        with open(path, "wb") as handle:
            handle.write(blob)
        return path

    def names(self, argv):
        code, lines, err = run(argv + ["--json", self.root])
        self.assertIn(code, (0, 1), err)
        return sorted(os.path.basename(json.loads(line)["path"])
                      for line in lines)

    def test_min_width_finds_only_wide_images(self):
        self.assertEqual(self.names(["--min-width", "1000"]),
                         ["breit.png", "foto.jpg", "riesig.png"])

    def test_max_height_and_exact_boundaries(self):
        self.assertEqual(self.names(["--max-height", "800"]),
                         ["breit.png", "riesig.png"])
        # Grenzen sind einschließlich: min = max = 1000 trifft das Quadrat.
        self.assertEqual(self.names(["--min-width", "1000", "--max-width",
                                     "1000"]), ["foto.jpg"])
        self.assertEqual(self.names(["--min-height", "1500"]), ["hoch.png"])

    def test_filters_combine_with_the_name_pattern_by_and(self):
        self.assertEqual(self.names(["hoch", "--min-width", "1000"]), [])
        self.assertEqual(self.names(["hoch", "--min-height", "1000"]),
                         ["hoch.png"])
        # Auch mit der Inhaltssuche: IHDR steht in jedem PNG.
        self.assertEqual(self.names(["--content", "IHDR", "--min-width",
                                     "1000"]), ["breit.png", "riesig.png"])

    def test_folders_and_non_images_never_match_a_size_filter(self):
        # "breit-ordner" trüge den Namen, hat aber keine Maße; notiz.txt
        # auch nicht.
        self.assertEqual(self.names(["breit", "--min-width", "1"]),
                         ["breit.png"])
        self.assertNotIn("notiz.txt", self.names(["--min-width", "1"]))

    def test_size_filter_alone_needs_no_pattern(self):
        code, lines, err = run(["--min-width", "4000", self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].endswith("bilder.zip!/drin/riesig.png"))

    def test_json_carries_width_and_height_only_with_a_size_filter(self):
        code, lines, _ = run(["--json", "--min-width", "1", self.root])
        self.assertEqual(code, 0)
        by_name = {os.path.basename(json.loads(line)["path"]):
                   json.loads(line) for line in lines}
        self.assertEqual((by_name["hoch.png"]["width"],
                          by_name["hoch.png"]["height"]), (300, 1500))
        code, lines, _ = run(["--json", "hoch", self.root])
        self.assertNotIn("width", json.loads(lines[0]))

    def test_min_above_max_is_rejected(self):
        code, _, err = run(["--min-width", "2000", "--max-width", "100",
                            self.root])
        self.assertEqual(code, 2)
        self.assertIn("größer", err)

    def test_size_filter_alone_has_no_text_criterion(self):
        # Ohne Muster gibt es kein Textkriterium — früher sprang ein
        # künstliches "*" ein, das unter --regex ein ungültiger Ausdruck war.
        search = favenio.Search(None, False, 1, True, min_width=1)
        self.assertEqual([type(item).__name__ for item in search.criteria],
                         ["DimensionCriterion"])
        self.assertIsNone(search.text_mode)

    def test_size_filter_alone_works_with_regex_flag(self):
        code, lines, err = run(["--regex", "--min-width", "4000", self.root])
        self.assertEqual(code, 0, err)
        self.assertTrue(lines[0].endswith("bilder.zip!/drin/riesig.png"))

    def test_content_and_metadata_need_a_pattern(self):
        # Beide sagen, WOGEGEN das Muster läuft. Ohne Muster ist das eine
        # widersprüchliche Angabe und muss auffallen — mit dem alten "*"
        # meldete --metadata still nur Dateien, die überhaupt Tags tragen.
        for flag in ("--content", "--metadata"):
            code, lines, err = run([flag, "--min-width", "1", self.root])
            self.assertEqual(code, 2, err)
            self.assertIn("PATTERN", err)
            self.assertEqual(lines, [])

    def test_dimension_reader_obeys_the_archive_budget(self):
        # Der Bildkopf eines Archiv-Eintrags läuft über denselben
        # budgetierten Chunker wie sein Inhalt. Sonst liest eine Maßsuche
        # beliebig viele Köpfe an den Entpackgrenzen vorbei.
        for limit in ("--max-archive-total-bytes",
                      "--max-archive-member-bytes"):
            code, lines, err = run(["--min-width", "4000", limit, "1",
                                    self.root])
            self.assertEqual(code, 1, err)
            self.assertEqual(lines, [])
            self.assertIn("bilder.zip!/drin/riesig.png", err)

    def test_dimension_head_is_not_charged_to_the_budget_twice(self):
        # Maß- und Inhaltssuche lesen denselben Eintrag nacheinander. Der
        # Anfang, den der Maß-Leser schon gezählt hat, darf das Gesamtbudget
        # nicht ein zweites Mal belasten.
        with zipfile.ZipFile(os.path.join(self.root, "bilder.zip")) as zf:
            member_size = zf.getinfo("drin/riesig.png").file_size
        # Genau EIN Durchlauf über den Eintrag passt ins Budget. Zählte der
        # Bildkopf ein zweites Mal, wäre die Grenze schon überschritten.
        code, lines, err = run(["--json", "--content", "IHDR",
                                "--min-width", "4000",
                                "--max-archive-total-bytes", str(member_size),
                                self.root])
        self.assertEqual(code, 0, err)
        self.assertEqual([json.loads(line)["path"].split("!/")[-1]
                          for line in lines], ["drin/riesig.png"])

    def test_cheap_criteria_run_first_and_short_circuit(self):
        # Die Reihenfolge ist Kosten: Name → Maße → Metadaten → Inhalt. Und
        # sie schließt kurz: Scheitert der Name, werden keine Maße gelesen.
        matcher = favenio.build_matcher("nirgends", False, False)
        search = favenio.Search(matcher, False, 1, True, min_width=1,
                                metadata_mode=False)
        self.assertEqual([type(item).__name__ for item in search.criteria],
                         ["NameCriterion", "DimensionCriterion"])
        opened = []

        def open_stream():
            opened.append(True)
            return open(os.path.join(self.root, "breit.png"), "rb")
        probe = favenio.FileProbe(search, "breit.png", "breit.png",
                                  open_stream, search.file_chunks,
                                  os.path.join(self.root, "breit.png"))
        with redirect_stdout(io.StringIO()):
            search.evaluate(probe, "breit.png", "file")
        self.assertEqual(opened, [])
        content = favenio.Search(matcher, True, 1, True, min_width=1)
        self.assertEqual([type(item).__name__ for item in content.criteria],
                         ["DimensionCriterion", "ContentCriterion"])
        meta = favenio.Search(matcher, False, 1, True, min_width=1,
                              metadata_mode=True)
        self.assertEqual([type(item).__name__ for item in meta.criteria],
                         ["DimensionCriterion", "MetadataCriterion"])


class MetadataSearchTest(TempTreeTest):
    """--metadata liest über exiftool die kuratierten Textfelder."""

    def setUp(self):
        super().setUp()
        self.original_path = favenio._EXIFTOOL_PATH
        favenio._EXIFTOOL_PATH = None
        self.addCleanup(self.restore_exiftool)

    def restore_exiftool(self):
        favenio._EXIFTOOL_PATH = self.original_path

    def write_bytes(self, rel_path, blob):
        path = os.path.join(self.root, rel_path)
        with open(path, "wb") as handle:
            handle.write(blob)
        return path

    def tag(self, path, **fields):
        arguments = [favenio.find_exiftool(), "-overwrite_original", "-q"]
        arguments.extend("-%s=%s" % item for item in fields.items())
        subprocess.run(arguments + [path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def test_list_metadata_fields_prints_the_curated_list(self):
        code, lines, _ = run(["--list-metadata-fields"])
        self.assertEqual(code, 0)
        self.assertEqual(lines, list(favenio.METADATA_TEXT_FIELDS))
        self.assertIn("Keywords", lines)

    def test_metadata_without_exiftool_exits_2_but_size_filters_work(self):
        favenio._EXIFTOOL_PATH = ""
        self.write_bytes("breit.png", png_bytes(1200, 800))
        code, lines, err = run(["--metadata", "Winter", self.root])
        self.assertEqual(code, 2)
        self.assertIn("exiftool", err)
        self.assertEqual(lines, [])
        code, lines, _ = run(["--min-width", "1000", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)

    def test_content_and_metadata_exclude_each_other(self):
        code, _, err = run(["--content", "--metadata", "x", self.root])
        self.assertEqual(code, 2)

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_metadata_reads_a_path_with_a_line_break(self):
        # macOS erlaubt in einem Dateinamen jedes Zeichen außer "/" und NUL.
        # Die Argumentdatei des laufenden exiftool-Prozesses ist zeilenweise;
        # solche Pfade gingen deshalb still verloren statt über einen eigenen
        # Prozess gelesen zu werden.
        umbruch = self.write_bytes("zeilen\numbruch.png", png_bytes(60, 40))
        schlicht = self.write_bytes("schlicht.png", png_bytes(60, 40))
        for path in (umbruch, schlicht):
            self.tag(path, **{"XMP-dc:Subject": "Winter"})
        code, lines, err = run(["--json", "--metadata", "Winter", self.root])
        self.assertEqual(code, 0, err)
        found = {json.loads(line)["path"] for line in lines}
        self.assertEqual(found, {umbruch, schlicht})

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_metadata_reads_a_relative_start_path_beginning_with_dash(self):
        # Ein Pfad, der mit "-" beginnt, wäre für exiftool eine Option.
        os.makedirs(os.path.join(self.root, "-bilder"))
        path = self.write_bytes(os.path.join("-bilder", "winter.png"),
                                png_bytes(60, 40))
        self.tag(path, **{"XMP-dc:Subject": "Winter"})
        code, lines, err = run(["--json", "--metadata", "Winter", "--",
                                "-bilder"], cwd=self.root)
        self.assertEqual(code, 0, err)
        self.assertEqual([json.loads(line)["path"] for line in lines],
                         ["-bilder/winter.png"])

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_metadata_hits_name_field_and_value(self):
        winter = self.write_bytes("winter.png", png_bytes(1200, 800))
        sommer = self.write_bytes("sommer.png", png_bytes(300, 1500))
        self.write_bytes("ohne.png", png_bytes(50, 50))
        self.write("winter.txt", "Winter steht hier nur im Inhalt\n")
        self.tag(winter, **{"XMP-dc:Subject": "Winter",
                            "XMP-dc:Title": "Winterlandschaft"})
        self.tag(sommer, **{"XMP-dc:Subject": "Sommer",
                            "XMP-dc:Description": "Winter war gestern"})
        code, lines, err = run(["--json", "--metadata", "winter", self.root])
        self.assertEqual(code, 0, err)
        records = {os.path.basename(json.loads(line)["path"]):
                   json.loads(line) for line in lines}
        # Die Textdatei hat keine Medienendung und geht nie an exiftool.
        self.assertEqual(sorted(records), ["sommer.png", "winter.png"])
        self.assertEqual(records["winter.png"]["field"], "Keywords")
        self.assertEqual(records["winter.png"]["value"], "Winter")
        self.assertEqual(records["sommer.png"]["field"], "Description")
        # Textausgabe nennt Feld und Wert hinter dem Pfad.
        code, lines, _ = run(["--metadata", "Winterland", self.root])
        self.assertEqual(lines, [winter + ":Title: Winterlandschaft"])

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_metadata_field_restricts_and_combines_with_sizes(self):
        winter = self.write_bytes("winter.png", png_bytes(1200, 800))
        klein = self.write_bytes("klein.png", png_bytes(200, 100))
        self.tag(winter, **{"XMP-dc:Subject": "Winter"})
        self.tag(klein, **{"XMP-dc:Subject": "Winter",
                           "XMP-dc:Title": "Winter klein"})
        code, lines, _ = run(["--json", "--metadata-field", "Title",
                              "winter", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertTrue(json.loads(lines[0])["path"].endswith("klein.png"))
        # Daniels Beispiel: Winter UND mindestens 1000 Pixel breit.
        code, lines, _ = run(["--json", "--metadata", "Winter",
                              "--min-width", "1000", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        record = json.loads(lines[0])
        self.assertTrue(record["path"].endswith("winter.png"))
        self.assertEqual((record["width"], record["height"]), (1200, 800))
        self.assertEqual(record["field"], "Keywords")

    @unittest.skipUnless(favenio.find_exiftool(), "exiftool nicht installiert")
    def test_exiftool_is_asked_only_once_per_file_and_only_after_sizes(self):
        winter = self.write_bytes("winter.png", png_bytes(1200, 800))
        klein = self.write_bytes("klein.png", png_bytes(200, 100))
        self.tag(winter, **{"XMP-dc:Subject": "Winter"})
        self.tag(klein, **{"XMP-dc:Subject": "Winter"})
        matcher = favenio.build_matcher("Winter", False, False)
        search = favenio.Search(matcher, False, 1, True, metadata_mode=True,
                                min_width=1000,
                                exiftool_path=favenio.find_exiftool())
        asked = []
        real = search.exiftool_stream()
        self.addCleanup(search.close)

        class Counting:
            def read(self, path):
                asked.append(os.path.basename(path))
                return real.read(path)

            def close(self):
                real.close()
        search._exiftool = Counting()
        with redirect_stdout(io.StringIO()):
            search.search_path(self.root)
        # klein.png ist an der Maßprüfung gescheitert, bevor exiftool dran war.
        self.assertEqual(asked, ["winter.png"])

    def test_formats_without_a_built_in_reader_ask_exiftool_for_the_size(self):
        # Die andere Hälfte der Kostenreihenfolge, die bis 0.26.1 weder
        # dokumentiert noch geprüft war: Für HEIC, AVIF, RAW und Video gibt
        # es keinen billigen Kopf-Leser — die Maße kommen von exiftool
        # selbst, also wird es schon IM Maßkriterium gefragt. Der ältere
        # Test daneben legt nur PNGs an und hätte das nie bemerkt.
        self.assertIn(".heic", favenio.EXIFTOOL_DIMENSION_EXTENSIONS)
        # Jede Endung mit exiftool-Rückfall muss auch an exiftool gehen
        # dürfen; sonst wäre der Rückfall tot, ohne dass etwas auffällt.
        self.assertTrue(
            set(favenio.EXIFTOOL_DIMENSION_EXTENSIONS)
            <= set(favenio.METADATA_EXTENSIONS),
            "Endung mit Maß-Rückfall, die METADATA_EXTENSIONS nicht kennt")

        self.write_bytes("ohne_leser.heic", b"nicht wirklich ein HEIC")
        # Ohne Muster, damit wirklich nur das Maßkriterium läuft: Ein
        # Namenskriterium hätte die Datei schon vorher aussortiert.
        search = favenio.Search(None, False, 1, True, min_width=1000,
                                exiftool_path=favenio.find_exiftool())
        gefragt = []
        real = search.exiftool_stream()
        self.addCleanup(search.close)

        class Counting:
            def read(self, path):
                gefragt.append(os.path.basename(path))
                return real.read(path)

            def close(self):
                real.close()
        search._exiftool = Counting()
        with redirect_stdout(io.StringIO()):
            search.search_path(self.root)
        self.assertEqual(gefragt, ["ohne_leser.heic"])


# Eine exiftool-Attrappe: schreibt jede empfangene Argumentzeile mit und
# antwortet auf "-execute" wie das Original. So lässt sich prüfen, WAS
# der Kern übergibt, ohne ein installiertes exiftool vorauszusetzen.
EXIFTOOL_STUB = """#!/usr/bin/env python3
import os, sys
log = open(os.environ["FAVENIO_STUB_LOG"], "a")
for line in sys.stdin:
    log.write(line)
    log.flush()
    if line.strip() == "-execute":
        sys.stdout.write('[{"SourceFile": "x"}]\\n{ready}\\n')
        sys.stdout.flush()
"""


class ExifToolArgumentTest(TempTreeTest):
    """Die Argumentdatei von `-stay_open` ist zeilenweise, und exiftool
    deutet den Zeilenanfang. Jede Zeile, die der Kern dorthin schreibt,
    ist deshalb eine Schnittstelle mit eigenen Regeln."""

    def make_stub(self):
        path = os.path.join(self.root, "exiftool_stub.py")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(EXIFTOOL_STUB)
        os.chmod(path, 0o755)
        self.log = os.path.join(self.root, "stub.log")
        os.environ["FAVENIO_STUB_LOG"] = self.log
        self.addCleanup(os.environ.pop, "FAVENIO_STUB_LOG", None)
        return path

    def stub_lines(self):
        with open(self.log, encoding="utf-8") as handle:
            return [line.rstrip("\n") for line in handle]

    def test_a_field_name_can_never_smuggle_in_an_option(self):
        # Ein Zeilenumbruch im Feldnamen zerlegte die Zeile und schob
        # BELIEBIGE weitere exiftool-Optionen ein — über `-p` mit einem
        # Perl-Ausdruck bis hin zu einem Shell-Aufruf.
        for boese in ("Title\n-echo\nEINGESCHLEUST", "Title -p x",
                      "Title\r-ver", "-execute", "Title;id", ""):
            with self.subTest(wert=boese):
                with self.assertRaises(argparse.ArgumentTypeError):
                    favenio.metadata_tag(boese)

    def test_option_names_are_rejected_even_though_they_look_harmless(self):
        # Der Grund für die Positivliste: Eine bloße Zeichenregel ließe
        # diese Wörter durch, und alle sind echte exiftool-Optionen.
        # `--metadata-field execute` zerlegte jede Anfrage in zwei
        # Kommandos, und die Suche lieferte für JEDE Datei „keine Treffer".
        for option in ("execute", "charset", "p", "b", "w", "if", "ver",
                       "TagsFromFile", "stay_open"):
            with self.subTest(option=option):
                with self.assertRaises(argparse.ArgumentTypeError):
                    favenio.metadata_tag(option)

    def test_every_offered_field_is_accepted_in_any_spelling(self):
        # Die Liste IST der Vertrag: --list-metadata-fields gibt genau sie
        # aus, und beide Oberflächen bauen ihr Feldmenü daraus. Jeder
        # angebotene Wert muss deshalb auch durchgehen.
        for field in favenio.METADATA_TEXT_FIELDS:
            with self.subTest(feld=field):
                self.assertEqual(favenio.metadata_tag(field), field)
                # exiftool unterscheidet keine Groß-/Kleinschreibung;
                # zurück kommt die kanonische Form.
                self.assertEqual(favenio.metadata_tag(field.lower()), field)
                self.assertEqual(favenio.metadata_tag(field.upper()), field)

    def test_the_cli_rejects_a_smuggled_field_with_exit_two(self):
        for wert in ("Title\n-echo\nX", "execute", "XMP-dc:Subject"):
            with self.subTest(wert=wert):
                code, lines, err = run(["--metadata-field", wert,
                                        "muster", self.root])
                self.assertEqual(code, 2)
                self.assertEqual(lines, [])
                self.assertIn("Metadatenfeld", err)

    def test_every_relative_path_is_prefixed_so_exiftool_reads_it_as_a_file(self):
        # "-" wäre eine Option, "#" ein Kommentar, führender Leerraum
        # würde abgeschnitten. Alle drei fielen ohne Meldung aus der Suche.
        stream = favenio.ExifToolStream.__new__(favenio.ExifToolStream)
        stream.fields = ["Title"]
        for path, erwartet in (
                ("-bilder/a.jpg", "./-bilder/a.jpg"),
                ("#tag.jpg", "./#tag.jpg"),
                (" leer/b.jpg", "./ leer/b.jpg"),
                ("normal/c.jpg", "./normal/c.jpg"),
                ("/absolut/d.jpg", "/absolut/d.jpg"),
        ):
            with self.subTest(pfad=path):
                self.assertEqual(stream.arguments(path)[-1], erwartet)

    def test_a_path_the_argument_file_cannot_carry_gets_its_own_process(self):
        # exiftool schneidet Leerraum am Zeilenende ab und kann einen
        # Zeilenumbruch gar nicht übertragen. macOS erlaubt in einem
        # Dateinamen aber jedes Zeichen außer "/" und NUL.
        stream = favenio.ExifToolStream.__new__(favenio.ExifToolStream)
        stream.fields = ["Title"]
        stream.broken = False
        einzeln = []
        stream.read_once = lambda path: einzeln.append(path)
        for path in ("mit\numbruch.jpg", "mit\rwagen.jpg",
                     "endet mit leerzeichen.jpg ", "endet mit tab.jpg\t"):
            with self.subTest(pfad=path):
                einzeln.clear()
                stream.read(path)
                self.assertEqual(einzeln, [path])

    def test_a_broken_exiftool_is_reported_instead_of_swallowed(self):
        # Stirbt der eine Prozess mitten im Lauf, lieferte read() für
        # jede weitere Datei None — der Lauf endete mit „keine Treffer"
        # und war von einer wirklich leeren Suche nicht zu unterscheiden.
        gemeldet = []
        stream = favenio.ExifToolStream(self.make_stub(), ["Title"],
                                        warn=gemeldet.append)
        self.addCleanup(stream.close)
        self.assertIsNotNone(stream.read(os.path.join(self.root, "a.jpg")))
        stream.process.kill()
        stream.process.wait()
        self.assertIsNone(stream.read(os.path.join(self.root, "b.jpg")))
        self.assertTrue(stream.broken)
        self.assertEqual(len(gemeldet), 1, gemeldet)
        self.assertIn("exiftool", gemeldet[0])

    def test_a_search_hands_its_warning_channel_to_exiftool(self):
        # Ohne diese Verdrahtung landet die Meldung oben im Nichts.
        search = favenio.Search(favenio.build_matcher("x", False, False),
                                False, 1, False, metadata_mode=True,
                                exiftool_path=self.make_stub())
        self.addCleanup(search.close)
        stream = search.exiftool_stream()
        self.assertIsNotNone(stream)
        self.assertEqual(stream.warn, search.warn)


class TerminationHandlerTest(unittest.TestCase):
    """SIGTERM ist der Weg, auf dem beide Apps eine Suche abbrechen —
    die Schnellsuche bei JEDEM Tastendruck. Ohne Handler lief das
    finally in main() nicht, und der exiftool-Prozess blieb als Waise
    stehen."""

    def test_sigterm_becomes_a_normal_program_end(self):
        previous = favenio.install_termination_handlers()
        try:
            self.assertIn(signal.SIGTERM, previous)
            handler = signal.getsignal(signal.SIGTERM)
            self.assertTrue(callable(handler))
            with self.assertRaises(SystemExit) as caught:
                handler(signal.SIGTERM, None)
            self.assertEqual(caught.exception.code, 128 + signal.SIGTERM)
        finally:
            favenio.restore_termination_handlers(previous)
        self.assertEqual(signal.getsignal(signal.SIGTERM),
                         previous[signal.SIGTERM])


class IWorkContainerTest(TempTreeTest):
    """Pages, Numbers und Keynote sind Zip-Container wie docx — auf einem
    Mac die häufigsten überhaupt. Sie fehlten in ZIP_EXTENSIONS: Der Text
    wurde in der .docx gefunden, in der .pages daneben nicht, und der Lauf
    meldete das als Erfolg (Exit 0)."""

    def test_iwork_documents_are_searched_like_every_other_zip(self):
        # Gut komprimierbarer Inhalt: So kann der Treffer NICHT zufällig
        # als Rohbyte-Fund im unkomprimierten Container entstehen.
        text = "X" * 5000 + "RECHNUNGSNUMMER4711" + "Y" * 5000
        for ext in (".pages", ".numbers", ".key", ".docx", ".odt"):
            with zipfile.ZipFile(
                    os.path.join(self.root, "probe" + ext), "w",
                    zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("index.xml", text)

        code, lines, _ = run(["--content", "RECHNUNGSNUMMER4711", self.root])
        self.assertEqual(code, 0)
        gefunden = {os.path.splitext(line.split("!/")[0])[1]
                    for line in lines if "!/" in line}
        self.assertEqual(
            gefunden,
            {".pages", ".numbers", ".key", ".docx", ".odt"}, lines)


class DimensionStartPathTest(TempTreeTest):
    """Ohne Muster ist das erste Positionsargument einer Maßsuche ein
    Startpfad. Das galt nur bei genau EINEM Argument: `--min-width 100
    dirA dirB` las dirA still als Namensmuster — beide Ordner einzeln
    lieferten Treffer, zusammen kam Exit 1 und keine Zeile."""

    def setUp(self):
        super().setUp()
        for ordner in ("dirA", "dirB"):
            os.makedirs(os.path.join(self.root, ordner))
            with open(os.path.join(self.root, ordner, ordner + ".png"),
                      "wb") as handle:
                handle.write(png_bytes(120, 80))

    def test_several_start_paths_work_without_a_pattern(self):
        a = os.path.join(self.root, "dirA")
        b = os.path.join(self.root, "dirB")
        for argumente in ([a], [b]):
            code, lines, _ = run(["--min-width", "100"] + argumente)
            self.assertEqual(code, 0)
            self.assertEqual(len(lines), 1)
        code, lines, _ = run(["--min-width", "100", a, b])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 2, lines)

    def test_a_pattern_that_is_no_path_stays_a_pattern(self):
        # Gegenprobe: Befördert wird nur, wenn ALLE Positionsargumente als
        # Pfad existieren.
        code, lines, _ = run(["--min-width", "100", "dirA*",
                              os.path.join(self.root, "dirA"),
                              os.path.join(self.root, "dirB")])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1, lines)


class LongLineTest(TempTreeTest):
    """Eine Zeile ohne Umbruch darf den Speicher nicht sprengen.

    Minifiziertes JSON, ein Base64-Block oder eine mysqldump-Zeile haben
    über hunderte Megabyte keinen Umbruch; match_content() pufferte eine
    solche Datei vollständig (144 MB Text → 488 MB Spitzenspeicher). Der
    Puffer wird deshalb abschnittsweise geleert, mit einer Überlappung,
    damit ein Treffer an der Schnittstelle nicht verlorengeht."""

    def line_of(self, needle, haystack, max_chars=1000, overlap=50,
                chunk=200):
        search = favenio.Search(
            favenio.build_matcher(needle, False, False), True, 1, False)
        blob = haystack.encode("utf-8")
        chunks = [blob[i:i + chunk] for i in range(0, len(blob), chunk)]
        vorher = (favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS)
        favenio.MAX_LINE_CHARS = max_chars
        favenio.LINE_OVERLAP_CHARS = overlap
        try:
            return search.match_content(iter(chunks))
        finally:
            (favenio.MAX_LINE_CHARS,
             favenio.LINE_OVERLAP_CHARS) = vorher

    def test_a_hit_is_found_anywhere_in_an_endless_line(self):
        # 5000 Zeichen ohne Umbruch bei einer Abschnittsgrenze von 1000:
        # Der Treffer muss an jeder Stelle gefunden werden und immer als
        # Zeile 1 zählen — es ist ja EINE Zeile.
        for stelle in (0, 500, 999, 1000, 2500, 4990):
            with self.subTest(stelle=stelle):
                text = ("a" * stelle + "ZIEL"
                        + "a" * (5000 - stelle - 4))
                self.assertEqual(self.line_of("ZIEL", text), 1)

    def test_a_hit_across_a_section_boundary_survives(self):
        # Genau der Fall, für den die Überlappung da ist. Wo die
        # Abschnittsgrenze wirklich liegt, hängt von der Häppchengröße ab
        # (geleert wird beim ERSTEN Häppchen jenseits der Grenze, hier bei
        # 1200) — deshalb wird jede Stelle über einen ganzen Bereich
        # geprüft, statt eine Grenze auszurechnen, die sich verschieben
        # kann. Ohne Überlappung fallen genau die Stellen durch, an denen
        # das Muster über den Schnitt reicht.
        needle = "ZIELMARKE"
        verfehlt = []
        for stelle in range(900, 2500):
            text = ("a" * stelle + needle
                    + "a" * (4000 - stelle - len(needle)))
            if self.line_of(needle, text) != 1:
                verfehlt.append(stelle)
        self.assertEqual(verfehlt, [])

    def test_the_overlap_must_be_long_enough_for_the_pattern(self):
        # Die Zusicherung hinter der Konstante: Ein Muster, das länger ist
        # als die Überlappung, kann an der Schnittstelle verlorengehen.
        # Mit 64 Ki Zeichen liegt die Grenze weit jenseits jedes
        # realistischen Suchbegriffs — dieser Test hält fest, WARUM die
        # Zahl nicht klein sein darf.
        needle = "ZIELMARKE"
        zu_kurz = [stelle for stelle in range(1100, 1300)
                   if self.line_of(needle, "a" * stelle + needle
                                   + "a" * (4000 - stelle - len(needle)),
                                   overlap=4) != 1]
        self.assertTrue(zu_kurz, "zu kurze Überlappung muss auffallen")
        self.assertLess(len(needle), favenio.LINE_OVERLAP_CHARS)

    def test_nothing_is_invented_when_the_needle_is_absent(self):
        self.assertIsNone(self.line_of("ZIEL", "a" * 5000))

    def test_line_numbers_still_count_after_a_very_long_line(self):
        # Die lange Zeile bleibt EINE Zeile; was danach kommt, ist Zeile 2.
        text = "a" * 5000 + "\nZIEL\n"
        self.assertEqual(self.line_of("ZIEL", text), 2)
        text = "a" * 5000 + "\r\nZIEL\n"
        self.assertEqual(self.line_of("ZIEL", text), 2)

    def test_an_anchored_pattern_is_never_matched_on_a_fragment(self):
        # `--regex 'A$'` traf am Abschnitts- statt am Zeilenende und
        # meldete einen Treffer, den grep nicht sieht. Verankerte Muster,
        # Glob-Muster und --exact gelten für die GANZE Zeile; auf einem
        # Bruchstück geprüft antworten sie falsch. Solche Zeilen bleiben
        # deshalb ungeprüft — mit Meldung, statt still falsch.
        text = "A" * 5000 + "ZZZ\n"
        search = favenio.Search(
            favenio.build_matcher("A$", True, False), True, 1, False)
        gemeldet = []
        search.warn = gemeldet.append
        blob = text.encode()
        chunks = [blob[i:i + 200] for i in range(0, len(blob), 200)]
        vorher = (favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS)
        favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = 1000, 50
        try:
            treffer = search.match_content(iter(chunks), label="probe.txt")
        finally:
            (favenio.MAX_LINE_CHARS,
             favenio.LINE_OVERLAP_CHARS) = vorher
        self.assertIsNone(treffer)
        self.assertEqual(len(gemeldet), 1, gemeldet)
        self.assertIn("probe.txt", gemeldet[0])
        self.assertIn("Zeile 1", gemeldet[0])
        # Der reine „enthält"-Test bleibt exakt und findet weiter.
        self.assertEqual(self.line_of("ZZZ", text), 1)

    def test_a_line_after_a_skipped_one_is_checked_again(self):
        # Übersprungen wird nur der Rest der zu langen Zeile, nicht der
        # Rest der Datei.
        text = "A" * 5000 + "\nZIEL\n"
        search = favenio.Search(
            favenio.build_matcher("^ZIEL$", True, False), True, 1, False)
        search.warn = lambda message: None
        blob = text.encode()
        chunks = [blob[i:i + 200] for i in range(0, len(blob), 200)]
        vorher = (favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS)
        favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = 1000, 50
        try:
            self.assertEqual(search.match_content(iter(chunks)), 2)
        finally:
            (favenio.MAX_LINE_CHARS,
             favenio.LINE_OVERLAP_CHARS) = vorher

    def test_a_lone_carriage_return_still_ends_a_line(self):
        # Ein einzelnes "\r" wartet im Puffer, weil ein folgendes "\n"
        # daraus ein CRLF machen könnte. Der Abschnittswechsel warf es
        # samt seiner fertigen Zeile weg — jede folgende Zeilennummer war
        # danach um eins zu klein. Klassische Mac-Dateien trennen so.
        lang = "b" * 3000
        for label, text in (
                ("einzelnes CR", "a" * 199 + "\r" + lang + "ZIEL\n"),
                ("CRLF", "a" * 198 + "\r\n" + lang + "ZIEL\n"),
                ("LF", "a" * 199 + "\n" + lang + "ZIEL\n"),
        ):
            with self.subTest(trenner=label):
                self.assertEqual(self.line_of("ZIEL", text), 2)
        # Auch wenn der Treffer IN der langen zweiten Zeile steht.
        self.assertEqual(
            self.line_of("ZIEL", "a" * 199 + "\r" + "b" * 2000 + "ZIEL"
                         + "c" * 2000 + "\n"), 2)

    def test_the_bound_does_not_change_short_lines(self):
        # Gegenprobe: Unterhalb der Grenze arbeitet die Funktion wie zuvor.
        text = "erste\nzweite\nZIEL\nvierte\n"
        self.assertEqual(self.line_of("ZIEL", text), 3)


class ArchiveExtensionTest(TempTreeTest):
    """Die Archiv-Erkennung geht nach der Endung — die ist ein Hinweis,
    keine Zusage. `.key` ist weit häufiger ein TLS-Schlüssel als eine
    Keynote-Datei. Trifft die Erwartung nicht zu, ist die Datei eine ganz
    normale Datei; AGENTS verlangt, dass alle Gründe, NICHT ins Archiv zu
    schauen, dasselbe Ergebnis liefern."""

    PEM = ("-----BEGIN PRIVATE KEY-----\n"
           "MIIEvQIBADANBgkqhkiG9w0\n"
           "-----END PRIVATE KEY-----\n")

    def test_a_file_that_is_no_archive_is_searched_as_a_plain_file(self):
        for name in ("server.key", "notiz.pages", "tabelle.numbers",
                     "bericht.docx", "paket.zip"):
            with self.subTest(datei=name):
                self.write(name, self.PEM)
                code, lines, _ = run(["--content", "BEGIN PRIVATE",
                                      os.path.join(self.root, name)])
                self.assertEqual(code, 0, name)
                self.assertEqual(len(lines), 1, lines)

    def test_all_three_reasons_to_skip_an_archive_agree(self):
        pfad = self.write("server.key", self.PEM)
        ergebnisse = []
        for optionen in ([], ["--no-archives"], ["--archive-depth", "0"]):
            code, lines, _ = run(optionen + ["--content", "BEGIN PRIVATE",
                                             pfad])
            ergebnisse.append((code, lines))
        self.assertEqual(ergebnisse[0], ergebnisse[1])
        self.assertEqual(ergebnisse[0], ergebnisse[2])
        self.assertEqual(ergebnisse[0][0], 0)

    def test_a_real_iwork_container_is_still_searched_as_an_archive(self):
        # Gegenprobe: Der Rückfall darf echte Container nicht entwerten.
        with zipfile.ZipFile(os.path.join(self.root, "echte.key"), "w",
                             zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("index.xml", "X" * 3000 + "PRAESENTATION")
        code, lines, _ = run(["--content", "PRAESENTATION", self.root])
        self.assertEqual(code, 0)
        self.assertTrue(any("echte.key!/index.xml" in line
                            for line in lines), lines)

    def test_a_mislabelled_archive_inside_an_archive_is_read_as_a_member(self):
        # Dieselbe Regel eine Ebene tiefer. Der Fehler zeigt sich erst ab
        # --archive-depth 2: Bei Tiefe 1 ist die Rekursion schon
        # aufgebraucht, der Eintrag gilt dann ohnehin als normaler
        # Eintrag. Bei Tiefe 2 wurde er als Archiv geöffnet, das Öffnen
        # schlug fehl, und er fiel ohne jede Meldung heraus — dieselbe
        # Datei war je nach Tiefe mal findbar und mal nicht.
        with zipfile.ZipFile(os.path.join(self.root, "aussen.zip"), "w",
                             zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("server.key", self.PEM)
        ergebnisse = []
        for tiefe in ("1", "2", "3"):
            code, lines, _ = run(["--archive-depth", tiefe, "--content",
                                  "BEGIN PRIVATE", self.root])
            ergebnisse.append((code, lines))
            self.assertEqual(code, 0, tiefe)
            self.assertTrue(any("aussen.zip!/server.key" in line
                                for line in lines), (tiefe, lines))
        self.assertEqual(ergebnisse[0], ergebnisse[1])
        self.assertEqual(ergebnisse[1], ergebnisse[2])

    @unittest.skipUnless(hasattr(os, "mkfifo"), "Plattform kennt kein mkfifo")
    def test_a_fifo_with_an_archive_name_never_blocks(self):
        # zipfile und tarfile öffnen den Pfad selbst, also an
        # open_regular_file() vorbei. Eine Pipe namens `x.zip` ließ
        # deshalb sogar die reine NAMENSSUCHE unbegrenzt hängen.
        os.mkfifo(os.path.join(self.root, "x.zip"))
        self.write("normal.txt", "TREFFER\n")
        code, lines, _ = run(["normal*", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        code, lines, err = run(["--content", "TREFFER", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertIn("keine reguläre Datei", err)


class RobustTraversalTest(TempTreeTest):
    """Ein einzelner kaputter oder ungewöhnlicher Eintrag darf nie den
    ganzen Suchlauf beenden — er gehört als Warnung auf stderr, und die
    Suche läuft weiter. Alle drei Fälle beendeten den Prozess vor 0.26.2
    mit Status 1, den beide Apps als „keine Treffer" lesen."""

    def test_dot_prefixed_archive_entries_are_not_hidden(self):
        # `tar -cf x.tar -C ordner .` ist der übliche Weg, einen
        # Ordnerinhalt zu tarren; jeder Eintrag heißt dann "./name".
        # Die Komponente "." galt als versteckter Name, deshalb fiel das
        # ganze Archiv ohne Meldung aus jeder Suche.
        self.write("notiz.txt", "TREFFER\n")
        tar_path = os.path.join(self.root, "punkt.tar")
        with tarfile.open(tar_path, "w") as archive:
            archive.add(os.path.join(self.root, "notiz.txt"),
                        arcname="./notiz.txt")
        zip_path = os.path.join(self.root, "punkt.zip")
        with zipfile.ZipFile(zip_path, "w") as archive:
            archive.writestr("./notiz.txt", "TREFFER\n")

        for label, archive_path in (("tar", tar_path), ("zip", zip_path)):
            with self.subTest(format=label):
                code, lines, _ = run(["notiz", archive_path])
                self.assertEqual(code, 0)
                self.assertEqual(len(lines), 1)
                code, lines, _ = run(["--content", "TREFFER", archive_path])
                self.assertEqual(code, 0)
                self.assertEqual(len(lines), 1)

    def test_the_archive_root_entry_is_not_a_hit(self):
        # `tar -cf x.tar -C ordner .` legt den Eintrag "./" an — das ist
        # das Archiv selbst, kein Eintrag darin. Seit "." nicht mehr als
        # versteckter Name gilt, kam er als Ordnertreffer mit dem Namen
        # "." heraus, den --extract nicht auflösen kann.
        os.makedirs(os.path.join(self.root, "quelle", "unterordner"))
        self.write(os.path.join("quelle", "unterordner", "d.txt"), "x\n")
        tar_path = os.path.join(self.root, "archiv.tar")
        with tarfile.open(tar_path, "w") as archive:
            archive.add(os.path.join(self.root, "quelle"), arcname=".")

        code, lines, _ = run(["--only", "dirs", "*", tar_path])
        self.assertEqual(code, 0)
        self.assertNotIn(tar_path + "!/.", lines)
        # Echte Ordner im Archiv bleiben sichtbar.
        self.assertTrue(any(line.endswith("unterordner") for line in lines),
                        lines)
        # Und die Dateien darin ebenso.
        code, lines, _ = run(["d.txt", tar_path])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1, lines)

    def test_really_hidden_entries_stay_hidden(self):
        # Die Gegenprobe zum Test darüber: Nur "." und ".." sind
        # ausgenommen, ein echter Punktname bleibt versteckt.
        self.write("sichtbar.txt", "x\n")
        tar_path = os.path.join(self.root, "h.tar")
        with tarfile.open(tar_path, "w") as archive:
            archive.add(os.path.join(self.root, "sichtbar.txt"),
                        arcname="./.geheim.txt")
        code, lines, _ = run(["geheim", tar_path])
        self.assertEqual(code, 1)
        self.assertEqual(lines, [])
        code, lines, _ = run(["--hidden", "geheim", tar_path])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)

    def test_zip_with_undecodable_entry_name_only_warns(self):
        # Windows-Packer setzen gelegentlich das UTF-8-Flag, obwohl die
        # Eintragsnamen CP932-/Latin-1-Bytes tragen. zipfile wirft dann
        # schon beim Öffnen einen UnicodeDecodeError.
        name = b"\xff\xfe_boese.txt"
        data = b"TREFFER"
        crc = zlib.crc32(data) & 0xFFFFFFFF
        local = (b"PK\x03\x04"
                 + struct.pack("<5H3L2H", 20, 0x800, 0, 0, 0, crc,
                               len(data), len(data), len(name), 0)
                 + name + data)
        central = (b"PK\x01\x02"
                   + struct.pack("<6H3L5H2L", 20, 20, 0x800, 0, 0, 0, crc,
                                 len(data), len(data), len(name),
                                 0, 0, 0, 0, 0, 0)
                   + name)
        end = (b"PK\x05\x06"
               + struct.pack("<4H2LH", 0, 0, 1, 1, len(central),
                             len(local), 0))
        with open(os.path.join(self.root, "boese.zip"), "wb") as handle:
            handle.write(local + central + end)
        self.write("zzz_danach.txt", "TREFFER\n")

        code, lines, err = run(["--content", "TREFFER", self.root])
        self.assertEqual(code, 0)
        self.assertIn("warnung", err)
        # Die Datei HINTER dem kaputten Archiv muss erreicht werden.
        self.assertTrue(any(line.endswith("zzz_danach.txt:1")
                            for line in lines), lines)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "Plattform kennt kein mkfifo")
    def test_a_fifo_never_blocks_the_search(self):
        # Ein gewöhnliches open() auf eine benannte Pipe ohne Schreiber
        # wartet unbegrenzt: Die Suche stand still, ohne Fehler und ohne
        # Ergebnis. Die Namenssuche war nie betroffen, weil sie die Datei
        # gar nicht öffnet — geprüft werden deshalb Inhalt und Maßfilter.
        os.mkfifo(os.path.join(self.root, "pipe.txt"))
        self.write("normal.txt", "TREFFER\n")

        code, lines, err = run(["--content", "TREFFER", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertIn("keine reguläre Datei", err)

        code, _, _ = run(["--min-width", "10", self.root])
        self.assertEqual(code, 1)

    def test_a_name_search_still_sees_a_fifo(self):
        # Gegenprobe: Die Sperre gilt nur fürs Lesen. Eine Pipe ist eine
        # Datei mit Namen und muss in der Namenssuche auftauchen.
        if not hasattr(os, "mkfifo"):
            self.skipTest("Plattform kennt kein mkfifo")
        os.mkfifo(os.path.join(self.root, "pipe.txt"))
        code, lines, err = run(["pipe*", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1)
        self.assertEqual(err, "")


if __name__ == "__main__":
    unittest.main()
