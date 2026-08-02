import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


class BuildSafetyTest(unittest.TestCase):
    def test_normal_build_never_mutates_applications(self):
        source = Path("build-app.sh").read_text(encoding="utf-8")
        forbidden = (
            "rm -rf /Applications",
            "ditto Favenio.app /Applications",
            "ditto FavenioQuick.app /Applications",
            "pkill -x Favenio",
        )
        for command in forbidden:
            self.assertNotIn(command, source)

    def test_release_checks_staple_and_gatekeeper_without_installing(self):
        source = Path("release.sh").read_text(encoding="utf-8")
        self.assertIn('xcrun stapler validate "$DMG_PATH"', source)
        self.assertIn('spctl --assess --type open', source)
        self.assertNotIn(" /Applications/Favenio.app", source)
        self.assertNotIn(" /Applications/FavenioQuick.app", source)


class InstallTransactionTest(unittest.TestCase):
    """Der Austausch beider Bundles ist EINE Transaktion: Entweder liegen
    danach beide neu am Zielort, oder beide alten Stände sind zurück. Getestet
    wird die Funktion aus notarize-lib.sh in einem Temp-Ordner — ohne
    /Applications, ohne Notarisierung."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = os.path.join(self.tmp.name, "quelle")
        self.dest = os.path.join(self.tmp.name, "ziel")
        for folder in (self.source, self.dest):
            os.makedirs(folder)
        for app in ("Favenio.app", "FavenioQuick.app"):
            self.make_bundle(os.path.join(self.source, app), "neu")
            self.make_bundle(os.path.join(self.dest, app), "alt")

    @staticmethod
    def make_bundle(path, marker, bundle_id=None):
        """Ein Bundle-Gerüst: reicht für ditto, mv und PlistBuddy."""
        os.makedirs(os.path.join(path, "Contents", "MacOS"), exist_ok=True)
        with open(os.path.join(path, "Contents", "MacOS", "marker"),
                  "w", encoding="utf-8") as handle:
            handle.write(marker)
        if bundle_id is not None:
            with open(os.path.join(path, "Contents", "Info.plist"),
                      "wb") as handle:
                plistlib.dump({"CFBundleIdentifier": bundle_id}, handle)

    def marker(self, folder, app):
        with open(os.path.join(folder, app, "Contents", "MacOS", "marker"),
                  encoding="utf-8") as handle:
            return handle.read()

    def run_install(self, verify_body):
        """Ruft favenio_install_bundles mit einer gestellten Prüffunktion auf
        (die echte fragt codesign/spctl/stapler). Liefert (rc, ausgabe)."""
        script = """
        set -euo pipefail
        source "%s/notarize-lib.sh"
        notarize_verify_installed() {
        %s
        }
        if favenio_install_bundles "%s" "%s" ""; then
            echo "RC=0"
        else
            echo "RC=$?"
        fi
        """ % (REPO, verify_body, self.source, self.dest)
        result = subprocess.run(["zsh", "-c", script], cwd=REPO,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def leftovers(self):
        return sorted(name for name in os.listdir(self.dest)
                      if name.startswith(".favenio-"))

    def test_both_bundles_are_replaced_on_success(self):
        output = self.run_install("    return 0")
        self.assertIn("RC=0", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "neu")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "neu")
        self.assertEqual(self.leftovers(), [])

    def test_failure_on_the_second_bundle_restores_both(self):
        # Die zweite App besteht die Prüfung AM ZIELORT nicht — genau der
        # Fall, der früher eine halb aktualisierte Installation hinterließ.
        body = """
        case "$1" in
            */.favenio-install.*) return 0 ;;
            */FavenioQuick.app) return 2 ;;
        esac
        return 0"""
        output = self.run_install(body)
        self.assertIn("RC=2", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")
        self.assertEqual(self.leftovers(), [])

    def test_bad_copy_never_touches_the_installed_bundles(self):
        # Schon die danebengelegte Kopie fällt durch: Der Zielordner darf
        # dann gar nicht erst angefasst werden.
        output = self.run_install("    return 2")
        self.assertIn("RC=2", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")
        self.assertEqual(self.leftovers(), [])


class InstallIdentityTest(unittest.TestCase):
    """Ein gültig signiertes, notarisiertes Bundle ist noch lange nicht
    Favenio. favenio_verify_identity prüft deshalb die Bundle-ID."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def check(self, bundle_id):
        path = os.path.join(self.tmp.name, "Favenio.app")
        InstallTransactionTest.make_bundle(path, "x", bundle_id=bundle_id)
        script = """
        set -uo pipefail
        source "%s/notarize-lib.sh"
        if favenio_verify_identity "%s" "Favenio.app"; then
            echo "RC=0"
        else
            echo "RC=$?"
        fi
        """ % (REPO, path)
        result = subprocess.run(["zsh", "-c", script], cwd=REPO,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_expected_bundle_id_passes(self):
        self.assertIn("RC=0", self.check("local.favenio"))

    def test_foreign_bundle_id_is_rejected(self):
        output = self.check("com.example.trojaner")
        self.assertIn("RC=2", output)
        self.assertIn("nicht Favenio", output)


class InstallExitCodeTest(unittest.TestCase):
    """install.sh sagt im Kopf zu: 0 oder 2, nie ein fremder Werkzeugstatus.
    Geprüft mit vorgeschobenen Werkzeugen, die den Lauf früh scheitern
    lassen — /Applications wird dabei nie erreicht."""

    def test_failing_tool_still_ends_with_exit_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            stubs = os.path.join(tmp, "stubs")
            os.makedirs(stubs)
            # xcrun/spctl bestätigen das DMG, hdiutil scheitert mit 1.
            for name, body in (("xcrun", "exit 0"),
                               ("spctl", "exit 0"),
                               ("hdiutil", 'echo "hdiutil kaputt" >&2\nexit 1')):
                path = os.path.join(stubs, name)
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write("#!/bin/sh\n%s\n" % body)
                os.chmod(path, 0o755)
            fake_dmg = os.path.join(tmp, "favenio.dmg")
            Path(fake_dmg).write_bytes(b"kein echtes Abbild")
            environment = dict(os.environ)
            environment["PATH"] = stubs + os.pathsep + environment["PATH"]
            result = subprocess.run(
                [str(REPO / "install.sh"), "--dmg", fake_dmg],
                cwd=REPO, env=environment,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 2,
                             result.stdout.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
