import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
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

    def test_release_checks_the_update_feed_of_both_bundles(self):
        source = Path("release.sh").read_text(encoding="utf-8")
        self.assertIn('favenio_verify_feed_url "$VERIFY_MOUNT/$app"', source)

    def test_expected_feed_url_matches_the_build_script(self):
        """notarize-lib.sh prüft gegen eine Kopie des Defaults aus
        build-app.sh. Läuft die auseinander, prüft die Installation gegen
        eine URL, die gar nicht mehr gebaut wird."""
        build = Path("build-app.sh").read_text(encoding="utf-8")
        library = Path("notarize-lib.sh").read_text(encoding="utf-8")
        self.assertIn(
            'SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-%s}"'
            % InstallFromDmgTest.FEED_URL, build)
        self.assertIn('FAVENIO_FEED_URL="%s"' % InstallFromDmgTest.FEED_URL,
                      library)


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
        if favenio_install_bundles "%s" "%s"; then
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

    def test_first_installation_leaves_nothing_behind_on_failure(self):
        # Erstinstallation: Der Zielordner ist LEER, es gibt also gar keinen
        # alten Stand zum Zurückholen. Scheitert die zweite App, muss trotzdem
        # auch die erste wieder verschwinden — sonst hinterlässt ein Lauf mit
        # Exit 2 eine halbe Installation, obwohl install.sh "nichts
        # installiert" zusagt.
        for app in ("Favenio.app", "FavenioQuick.app"):
            shutil.rmtree(os.path.join(self.dest, app))
        body = """
        case "$1" in
            */.favenio-install.*) return 0 ;;
            */FavenioQuick.app) return 2 ;;
        esac
        return 0"""
        output = self.run_install(body)
        self.assertIn("RC=2", output)
        self.assertEqual(sorted(os.listdir(self.dest)), [])

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
        # Geprüft wird hier NUR die Bundle-ID. Die zusätzliche Team-Prüfung in
        # favenio_verify_identity greift, sobald ein Team bekannt ist — und die
        # Attrappe hier trägt gar keine Signatur. Deshalb FAVENIO_TEAM_ID aus
        # der Umgebung nehmen und außerhalb des Repos laufen, damit auch
        # `git config --local favenio.teamId` nicht greift. notarize-lib.sh
        # kommt ohnehin über den absoluten Repo-Pfad herein.
        environment = dict(os.environ)
        environment.pop("FAVENIO_TEAM_ID", None)
        result = subprocess.run(["zsh", "-c", script], cwd=self.tmp.name,
                                env=environment,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_expected_bundle_id_passes(self):
        self.assertIn("RC=0", self.check("local.favenio"))

    def test_expected_bundle_id_passes_with_a_team_id_in_the_environment(self):
        # Ohne die Umgebungs-Isolation oben scheiterte dieser Test auf jedem
        # Mac, auf dem FAVENIO_TEAM_ID gesetzt ist — die Attrappe ist nicht
        # signiert und fiele durch die Team-Prüfung.
        with unittest.mock.patch.dict(os.environ,
                                      {"FAVENIO_TEAM_ID": "TESTTEAM00"}):
            self.assertIn("RC=0", self.check("local.favenio"))

    def test_foreign_bundle_id_is_rejected(self):
        output = self.check("com.example.trojaner")
        self.assertIn("RC=2", output)
        self.assertIn("nicht Favenio", output)


class InstallFromDmgTest(unittest.TestCase):
    """Der --dmg-Weg mit vorgeschobenen Werkzeugen: `hdiutil attach` legt zwei
    Bundle-Gerüste in den Mountpoint, codesign/spctl/xcrun antworten nach
    Vorgabe. Damit lässt sich `--verify-only` vollständig durchspielen, ohne
    Notarisierung und ohne /Applications.

    Geprüft wird die Entscheidung vom 2026-08-03: Auch aus einem DMG braucht
    jedes Bundle sein EIGENES angeheftetes Notary-Ticket."""

    APPS = {"Favenio.app": "local.favenio",
            "FavenioQuick.app": "local.favenio.quick"}
    FEED_URL = "https://danielmuellerir.github.io/favenio/appcast.xml"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plists = self.root / "plists"
        self.plists.mkdir()
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        self.dmg = self.root / "Favenio-0.21.1.dmg"
        self.dmg.write_bytes(b"kein echtes Abbild")
        for app, bundle_id in self.APPS.items():
            self.write_plist(app, bundle_id)
        self.write_stubs()

    def write_plist(self, app, bundle_id, feed_url=None, version="0.21.1",
                    build=None):
        """`build=None` übernimmt die Kurzversion, `build=""` lässt
        CFBundleVersion ganz weg."""
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "SUFeedURL": self.FEED_URL if feed_url is None else feed_url,
        }
        if build is None:
            build = version
        if build != "":
            info["CFBundleVersion"] = build
        with open(self.plists / ("%s.plist" % app), "wb") as handle:
            plistlib.dump(info, handle)

    def write_stubs(self):
        # hdiutil attach füllt den Mountpoint mit den vorbereiteten Bundles.
        (self.stubs / "hdiutil").write_text(
            "#!/bin/sh\n"
            'mount=""; prev=""\n'
            'for arg in "$@"; do\n'
            '  [ "$prev" = "-mountpoint" ] && mount="$arg"\n'
            '  prev="$arg"\n'
            "done\n"
            '[ "$1" = "attach" ] || exit 0\n'
            '[ -n "$mount" ] || exit 1\n'
            "for app in Favenio.app FavenioQuick.app; do\n"
            '  mkdir -p "$mount/$app/Contents"\n'
            '  cp "$STUB_PLISTS/$app.plist" "$mount/$app/Contents/Info.plist"\n'
            "done\n"
            "exit 0\n",
            encoding="utf-8")
        for name in ("xcrun", "spctl", "codesign"):
            (self.stubs / name).write_text(
                "#!/bin/sh\n"
                "for last; do :; done\n"
                'entry=$(basename "$last")\n'
                'case " ${STUB_FAIL_%s:-} " in *" $entry "*) exit 1 ;; esac\n'
                "exit 0\n" % name.upper(),
                encoding="utf-8")
        for stub in self.stubs.iterdir():
            stub.chmod(0o755)

    def run_install(self, *arguments, **fails):
        environment = dict(os.environ)
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        environment["STUB_PLISTS"] = str(self.plists)
        for tool, entries in fails.items():
            environment["STUB_FAIL_%s" % tool.upper()] = entries
        result = subprocess.run(
            [str(REPO / "install.sh"), "--dmg", str(self.dmg), "--verify-only",
             *arguments],
            cwd=REPO, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.returncode, result.stdout.decode("utf-8", "replace")

    def test_stapled_bundles_from_a_dmg_pass(self):
        code, output = self.run_install()
        self.assertEqual(code, 0, output)
        self.assertIn("VERIFY OK", output)
        self.assertIn("Ticket angeheftet", output)

    def test_bundle_without_own_ticket_is_rejected(self):
        # Genau der alte Sonderfall: Das DMG selbst ist gestapelt, das Bundle
        # darin nicht. Früher gab es dafür nur einen Hinweis.
        code, output = self.run_install(xcrun="FavenioQuick.app")
        self.assertEqual(code, 2, output)
        self.assertIn("kein angeheftetes Notary-Ticket", output)

    def test_dmg_without_ticket_is_still_rejected(self):
        code, output = self.run_install(xcrun="Favenio-0.21.1.dmg")
        self.assertEqual(code, 2, output)
        self.assertIn("kein angeheftetes Notary-Ticket", output)

    def test_foreign_bundle_id_from_a_dmg_is_rejected(self):
        self.write_plist("Favenio.app", "com.example.trojaner")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("nicht Favenio", output)

    def test_foreign_update_feed_is_rejected(self):
        # Ein geerbtes SPARKLE_FEED_URL landet über build-app.sh im Bundle
        # und richtete die installierte App dauerhaft auf einen fremden Feed.
        self.write_plist("FavenioQuick.app", "local.favenio.quick",
                         feed_url="https://example.invalid/appcast.xml")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("sucht Updates unter", output)

    def test_differing_build_numbers_are_rejected(self):
        # Gleiche Kurzversion, verschiedene CFBundleVersion: Sparkle
        # entscheidet nach der Build-Nummer, die Prüfung sah sie früher gar
        # nicht an.
        self.write_plist("FavenioQuick.app", "local.favenio.quick",
                         build="0.13.9")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("Build 0.13.9", output)

    def test_missing_build_number_is_rejected(self):
        self.write_plist("Favenio.app", "local.favenio", build="")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("nennt keine Version", output)


class FeedUrlTest(unittest.TestCase):
    """favenio_verify_feed_url einzeln: Der Produktions-Feed ist Pflicht,
    jede Abweichung führt zum Abbruch (fail-closed)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def check(self, feed_url):
        path = os.path.join(self.tmp.name, "Favenio.app")
        os.makedirs(os.path.join(path, "Contents"), exist_ok=True)
        info = {"CFBundleIdentifier": "local.favenio"}
        if feed_url is not None:
            info["SUFeedURL"] = feed_url
        with open(os.path.join(path, "Contents", "Info.plist"), "wb") as handle:
            plistlib.dump(info, handle)
        script = """
        set -uo pipefail
        source "%s/notarize-lib.sh"
        if favenio_verify_feed_url "%s" "Favenio.app"; then
            echo "RC=0"
        else
            echo "RC=$?"
        fi
        """ % (REPO, path)
        result = subprocess.run(["zsh", "-c", script], cwd=REPO,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_production_feed_passes(self):
        self.assertIn("RC=0", self.check(InstallFromDmgTest.FEED_URL))

    def test_foreign_feed_is_rejected(self):
        output = self.check("http://127.0.0.1:8000/appcast.xml")
        self.assertIn("RC=2", output)
        self.assertIn("sucht Updates unter", output)

    def test_missing_feed_is_rejected(self):
        output = self.check(None)
        self.assertIn("RC=2", output)
        self.assertIn("keiner URL", output)


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
