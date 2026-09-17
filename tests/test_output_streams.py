# Tests für die echten Ausgabeströme des Kerns — laufen mit purem Python:
#   python3 -m unittest discover -s tests
#
# Die Hilfe `run()` in test_favenio.py fängt stdout in einem StringIO ab.
# Ein StringIO kennt aber weder eine Kodierung noch eine Pipe: Kodierungs-
# fehler des echten stdout und ein vorzeitig geschlossener Leser sind dort
# grundsätzlich unsichtbar. Deshalb läuft hier jeder Fall als eigener
# Prozess.

import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import favenio  # noqa: E402


def core_environment(**extra):
    """Umgebung für den Kern-Prozess: ohne erzwungenen UTF-8-Modus, damit die
    Locale tatsächlich wirkt, und ohne Bytecode-Reste im Arbeitsbaum."""
    env = dict(os.environ)
    for name in ("PYTHONUTF8", "PYTHONIOENCODING", "LC_ALL", "LC_CTYPE",
                 "LANG"):
        env.pop(name, None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update(extra)
    return env


class OutputStreamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name

    def latin1_tar(self, name="latin.tar", extra_members=()):
        """Ein Tar im GNU-Format, dessen Eintragsname in Latin-1 statt UTF-8
        abgelegt ist — typisch für alte Linux-Archive. `tarfile` liefert den
        Namen mit `surrogateescape` als `caf\\udce9.txt`."""
        path = os.path.join(self.root, name)
        with tarfile.open(path, "w", format=tarfile.GNU_FORMAT,
                          encoding="latin-1") as archive:
            for member, data in (("caf\xe9.txt", b"NADEL\n"),) \
                    + tuple(extra_members):
                info = tarfile.TarInfo(member)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return path

    def test_a_non_utf8_member_name_does_not_abort_the_run(self):
        """Fund 2026-09-17: Unter einer strikten UTF-8-Locale (Terminal.app
        setzt `LANG=de_DE.UTF-8`) warf `print()` beim ersten solchen Treffer
        `UnicodeEncodeError`; der GESAMTE Lauf endete mit Exit 2 und ohne
        eine einzige Zeile. Ein rohes Latin-1-Byte im JSONL wäre aber auch
        kein gültiges UTF-8 und würde von beiden Apps verworfen. tarfile
        ersetzt es deshalb verlustbehaftet, aber stabil durch U+FFFD."""
        archive = self.latin1_tar()
        env = core_environment(LC_ALL="en_US.UTF-8", LANG="en_US.UTF-8")
        for arguments in (["--json", "txt"], ["txt"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    [sys.executable, favenio.__file__] + arguments
                    + [archive], capture_output=True, env=env, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(b"Traceback", result.stderr)
                # Genau eine Zeile, und auch JSONL ist striktes UTF-8.
                lines = result.stdout.splitlines()
                self.assertEqual(len(lines), 1, result.stdout)
                if "--json" in arguments:
                    decoded = lines[0].decode("utf-8")
                    self.assertIn("caf\ufffd.txt", decoded)
                    record = json.loads(decoded)
                    self.assertEqual(record["path"],
                                     archive + "!/caf\ufffd.txt")
                    extracted = subprocess.run(
                        [sys.executable, favenio.__file__, "--extract-root",
                         self.root, "--extract-json", json.dumps(record)],
                        capture_output=True, env=env, timeout=30)
                    self.assertEqual(extracted.returncode, 0,
                                     extracted.stderr)
                    output_path = extracted.stdout.decode("utf-8").strip()
                    with open(output_path, "rb") as handle:
                        self.assertEqual(handle.read(), b"NADEL\n")
                else:
                    # Die klassische Textausgabe bleibt wie grep/find bei
                    # den originalen Namensbytes.
                    self.assertIn(b"caf\xe9.txt", lines[0])

    def test_a_warning_about_a_non_utf8_name_reaches_stderr(self):
        """Auch eine Warnung darf an einem solchen Namen nicht scheitern:
        ein abgeschnittenes Zip mit Latin-1-Namen im Tar (Tiefe 2, damit
        der Kern das innere Zip überhaupt öffnet). Python schreibt stderr
        von sich aus mit `backslashreplace`; der Test hält fest, dass die
        Umstellung der Ströme in `main()` das beibehält."""
        archive = self.latin1_tar(
            "warnung.tar", extra_members=(("kaputt\xe9.zip",
                                           b"PK\x03\x04abgeschnitten"),))
        env = core_environment(LC_ALL="en_US.UTF-8", LANG="en_US.UTF-8")
        result = subprocess.run(
            [sys.executable, favenio.__file__, "--json", "--archive-depth",
             "2", "caf", archive],
            capture_output=True, env=env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        self.assertIn(b"favenio: warnung: ", result.stderr)
        self.assertIn(b"kaputt\\udce9.zip", result.stderr)

    def test_non_utf8_member_identities_do_not_collapse(self):
        """Zwei verschiedene Latin-1-Bytes werden sichtbar beide U+FFFD.
        archiveMemberBytes muss sie trotzdem unterscheiden und jeweils den
        richtigen Eintrag materialisieren."""
        archive = self.latin1_tar(
            extra_members=(("caf\xea.txt", b"ZWEITER\n"),))
        env = core_environment()
        records = []
        for needle in ("NADEL", "ZWEITER"):
            result = subprocess.run(
                [sys.executable, favenio.__file__, "--json", "--content",
                 needle, archive], capture_output=True, env=env, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            records.append(json.loads(result.stdout.decode("utf-8")))
        self.assertEqual(records[0]["archiveMembers"], ["caf\ufffd.txt"])
        self.assertEqual(records[1]["archiveMembers"], ["caf\ufffd.txt"])
        self.assertNotEqual(records[0]["archiveMemberBytes"],
                            records[1]["archiveMemberBytes"])

        for record, expected in zip(records, (b"NADEL\n", b"ZWEITER\n")):
            extracted = subprocess.run(
                [sys.executable, favenio.__file__, "--extract-root",
                 self.root, "--extract-json", json.dumps(record)],
                capture_output=True, env=env, timeout=30)
            self.assertEqual(extracted.returncode, 0, extracted.stderr)
            with open(extracted.stdout.decode("utf-8").strip(), "rb") as handle:
                self.assertEqual(handle.read(), expected)

    def run_into_closed_pipe(self, arguments):
        """Startet den Kern mit einem stdout, dessen Leser schon weg ist —
        wie `favenio … | head -1`, nur ohne Zeitabhängigkeit: Jeder
        Schreibversuch scheitert sofort mit EPIPE."""
        read_end, write_end = os.pipe()
        os.close(read_end)
        try:
            result = subprocess.run(
                [sys.executable, favenio.__file__] + arguments,
                stdout=write_end, stderr=subprocess.PIPE,
                env=core_environment(), timeout=60)
        finally:
            os.close(write_end)
        return result

    def test_a_closed_reader_ends_like_grep(self):
        """Fund 2026-09-17: `favenio --json txt . | head -1` endete mit
        Traceback, „unerwartetem Fehler" und beim Interpreter-Ende mit
        Status 120 — außerhalb des 0/1/2-Vertrags. Innerhalb eines Archivs
        schluckte `search_archive()` den BrokenPipeError sogar als Warnung
        je Archiv und suchte weiter. Wie grep: Status 0, wenn schon Treffer
        ausgegeben wurden, keine Diagnose."""
        open(os.path.join(self.root, "ein.txt"), "w").close()
        for index in range(3000):
            open(os.path.join(self.root, "datei_%d.txt" % index), "w").close()
        with zipfile.ZipFile(os.path.join(self.root, "viele.zip"), "w") as zf:
            for index in range(3000):
                zf.writestr("drin_%d.txt" % index, b"")
        cases = (
            # Ein Treffer: Er steckt noch im Puffer, erst das Leeren scheitert.
            ("ein Treffer", ["--json", "ein.txt", self.root], 0),
            ("viele Dateien", ["--json", "datei_", self.root], 0),
            ("viele Archiv-Einträge",
             ["--json", "drin_", os.path.join(self.root, "viele.zip")], 0),
            # Die erste Fortschrittszeile scheitert vor jedem Treffer: Es
            # wurde nichts gefunden, also 1 — wie grep ohne Ausgabe.
            ("Fortschritt", ["--json", "--progress", "datei_", self.root], 1),
        )
        for label, arguments, expected in cases:
            with self.subTest(label):
                result = self.run_into_closed_pipe(arguments)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stderr, b"")

    def run_with_closed_streams(self, arguments, stdout_closed=True):
        """Wie `favenio … 2>&1 | head -1`: stderr (und normalerweise auch
        stdout) zeigt auf eine Pipe ohne Leser. Mit `stdout_closed=False`
        wie `2>&1 >/dev/null | head -1`."""
        read_end, write_end = os.pipe()
        os.close(read_end)
        try:
            result = subprocess.run(
                [sys.executable, favenio.__file__] + arguments,
                stdout=write_end if stdout_closed else subprocess.DEVNULL,
                stderr=write_end, env=core_environment(), timeout=60)
        finally:
            os.close(write_end)
        return result

    @unittest.skipIf(os.geteuid() == 0, "root liest auch chmod-000-Ordner")
    def test_a_closed_stderr_reader_ends_like_grep(self):
        """Review-Fund 2026-09-17: Bei `2>&1 | head -1` trifft die nächste
        Warnung oder Text-Fortschrittszeile den geschlossenen Leser.
        `main()` bog nur stdout auf /dev/null um; der Rest im Puffer von
        stderr scheiterte beim Interpreter-Ende erneut, Status 120."""
        locked = []
        for index in range(60):
            path = os.path.join(self.root, "gesperrt_%d" % index)
            os.mkdir(path)
            os.chmod(path, 0)
            locked.append(path)

        def unlock():
            for path in locked:
                os.chmod(path, 0o755)
        self.addCleanup(unlock)
        for index in range(3000):
            open(os.path.join(self.root, "datei_%d.txt" % index), "w").close()
        cases = (
            ("Warnungen", ["zzz", self.root], True),
            ("Warnungen, JSON", ["--json", "zzz", self.root], True),
            ("Warnungen, stdout offen", ["--json", "zzz", self.root], False),
            ("Text-Fortschritt", ["--progress", "zzz", self.root], True),
        )
        for label, arguments, stdout_closed in cases:
            with self.subTest(label):
                result = self.run_with_closed_streams(arguments,
                                                      stdout_closed)
                self.assertEqual(result.returncode, 1)

    def test_a_closed_reader_after_extract_or_field_list_is_no_error(self):
        """Review-Fund 2026-09-17: `--extract` und `--list-metadata-fields`
        schrieben mit `print()` außerhalb des geschützten Suchblocks. Mit
        `| head -0` scheiterte das Leeren beim Interpreter-Ende: „Exception
        ignored" und Status 120. Ihre Arbeit ist getan, also Status 0."""
        plain = os.path.join(self.root, "ein.txt")
        open(plain, "w").close()
        archive = os.path.join(self.root, "paket.zip")
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("drin.txt", b"x")
        cases = (
            ("Feldliste", ["--list-metadata-fields"]),
            ("normale Datei", ["--extract", plain]),
            ("Archiv-Eintrag", ["--extract-root", self.root, "--extract",
                                archive + "!/drin.txt"]),
        )
        for label, arguments in cases:
            with self.subTest(label):
                result = self.run_into_closed_pipe(arguments)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, b"")


if __name__ == "__main__":
    unittest.main()
