import os
import plistlib
import signal
import shutil
import subprocess
import tempfile
import time
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

    def test_release_requires_and_checks_the_developer_team(self):
        source = Path("release.sh").read_text(encoding="utf-8")
        self.assertIn("favenio_require_team_id", source)
        self.assertIn(
            'favenio_verify_identity "$VERIFY_MOUNT/$app" "$app"', source)

    def test_install_distinguishes_an_incomplete_rollback(self):
        install = Path("install.sh").read_text(encoding="utf-8")
        library = Path("notarize-lib.sh").read_text(encoding="utf-8")
        self.assertIn("3 = Rollback unvollständig", install)
        self.assertIn("return 3", library)

    def test_install_help_shows_the_complete_header(self):
        """`--help` gibt den Kopfkommentar aus. Als der Kopf um die
        Exit-Code-Erklärung wuchs, schnitt die dort fest eingetragene Endzeile
        den Hinweis auf die maschinenlesbare Erfolgszeile ab. Der Test hält
        Anfang UND Ende des Blocks fest, damit das nicht wieder still
        passiert."""
        result = subprocess.run(["./install.sh", "--help"], cwd=REPO,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0,
                         result.stderr.decode("utf-8", "replace"))
        help_text = result.stdout.decode("utf-8")
        self.assertIn("Favenio — Installation nach /Applications.", help_text)
        self.assertIn("--verify-only", help_text)
        self.assertIn("3 = Rollback unvollständig", help_text)
        self.assertIn("INSTALL OK: <version>", help_text)
        self.assertIn("VERIFY OK: <quelle>", help_text)
        # Der Block endet vor dem Code: keine Shell-Zeile in der Hilfe.
        self.assertNotIn("set -euo pipefail", help_text)

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

    def test_feed_url_is_not_interpolated_into_plist_xml(self):
        """Eine URL darf XML-Zeichen wie `&` enthalten. Der Wert muss daher
        vom Plist-Werkzeug serialisiert werden statt roh im Here-Dokument zu
        landen."""
        source = Path("build-app.sh").read_text(encoding="utf-8")
        self.assertNotIn("<string>${SPARKLE_FEED_URL}</string>", source)
        self.assertIn(
            '/usr/bin/plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL"',
            source)
        self.assertIn("set_sparkle_feed_url Favenio.app", source)
        self.assertIn("set_sparkle_feed_url FavenioQuick.app", source)

    def test_ad_hoc_build_omits_hardened_runtime(self):
        """Ohne Developer-ID haben App und Framework keine gemeinsame
        Team-ID. Hardened Runtime würde Sparkle dann beim Laden ablehnen."""
        source = Path("build-app.sh").read_text(encoding="utf-8")
        self.assertIn(
            'if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then', source)
        self.assertIn('NESTED_SIGN=(--force --sign -)', source)
        self.assertIn(
            'APP_SIGN=(--force --entitlements assets/favenio.entitlements '
            '--sign -)', source)

    def test_ci_explicitly_exercises_ad_hoc_build(self):
        workflow = Path(".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn('FAVENIO_SIGN_ID: "-"', workflow)


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

    def install_script(self, verify_body, prelude=""):
        """Baut ein Testskript mit einer gestellten Bundle-Prüfung."""
        return """
        set -euo pipefail
        source "%s/notarize-lib.sh"
        %s
        notarize_verify_installed() {
        %s
        }
        if favenio_install_bundles "%s" "%s"; then
            echo "RC=0"
        else
            echo "RC=$?"
        fi
        """ % (REPO, prelude, verify_body, self.source, self.dest)

    def run_install(self, verify_body, prelude=""):
        """Führt das Testskript aus und liefert seine gemeinsame Ausgabe."""
        script = self.install_script(verify_body, prelude)
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

    # Die zweite App fällt am ZIELORT durch die Prüfung — der Auslöser für
    # jeden Rollback-Test hier.
    FAIL_ON_SECOND = """
        case "$1" in
            */.favenio-install.*) return 0 ;;
            */FavenioQuick.app) return 2 ;;
        esac
        return 0"""

    def previous_folder(self):
        """Der Sicherungsordner dieses Laufs, falls er liegen geblieben ist."""
        folders = [name for name in self.leftovers()
                   if name.startswith(".favenio-previous.")]
        self.assertEqual(len(folders), 1, folders)
        return os.path.join(self.dest, folders[0])

    def test_a_failed_rollback_is_reported_and_overwrites_nothing(self):
        # `set -e` schützt die Befehle in favenio_install_bundles NICHT:
        # install.sh ruft die Funktion in einer ||-Liste auf, dort ist errexit
        # abgeschaltet. Ein gescheitertes Wegräumen des schon eingesetzten
        # Bundles muss deshalb selbst geprüft werden — früher lief der Rollback
        # nach einem ungeprüften `rm -rf` stillschweigend weiter und der Lauf
        # meldete nur den allgemeinen Exit 2.
        prelude = """
        mv() {
            case "$2" in
                */rollback-Favenio.app) return 1 ;;
            esac
            command mv "$@"
        }"""
        output = self.run_install(self.FAIL_ON_SECOND, prelude=prelude)
        self.assertIn("RC=3", output)
        self.assertIn("ließ sich nicht wieder aus", output)
        # Das neue Bundle liegt noch am Zielort — genau das muss der Lauf
        # sagen, statt es zu verschweigen.
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "neu")
        # Und der alte Stand wird dann nicht blind darübergeschrieben, sondern
        # bleibt im Sicherungsordner erhalten.
        self.assertIn("belegt", output)
        self.assertEqual(self.marker(self.previous_folder(), "Favenio.app"),
                         "alt")
        # Die zweite App war wegräumbar und ist sauber zurückgerollt.
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")

    def test_rollback_leaves_a_bundle_of_another_run_alone(self):
        # Ein zweiter Lauf hat den Zielpfad inzwischen durch sein eigenes
        # Bundle ersetzt. Ein Rollback nach dem bloßen NAMEN nähme ihm dieses
        # Bundle weg; erkannt wird der Unterschied an der Kennung des
        # Verzeichniseintrags (Gerät und Inode).
        body = """
        case "$1" in
            */.favenio-install.*) return 0 ;;
            */FavenioQuick.app)
                rm -rf "{dest}/Favenio.app"
                mkdir -p "{dest}/Favenio.app/Contents/MacOS"
                printf fremd > "{dest}/Favenio.app/Contents/MacOS/marker"
                return 2 ;;
        esac
        return 0""".format(dest=self.dest)
        output = self.run_install(body)
        self.assertIn("RC=3", output)
        self.assertIn("nicht mehr das Bundle dieses Laufs", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "fremd")
        self.assertEqual(self.marker(self.previous_folder(), "Favenio.app"),
                         "alt")

    def test_a_second_run_in_the_same_target_is_refused(self):
        # Austausch und Rollback teilen sich den Zielordner und müssen deshalb
        # pro Ziel serialisiert laufen.
        lock = os.path.join(self.dest, ".favenio-install.lock")
        os.makedirs(lock)
        output = self.run_install("    return 0")
        self.assertIn("RC=2", output)
        self.assertIn("läuft bereits eine Favenio-Installation", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        # Die fremde Sperre bleibt stehen — der abgewiesene Lauf räumt sie nicht
        # weg, sonst könnte er den anderen Lauf gleich mit freigeben.
        self.assertTrue(os.path.isdir(lock))

    def test_bad_copy_never_touches_the_installed_bundles(self):
        # Schon die danebengelegte Kopie fällt durch: Der Zielordner darf
        # dann gar nicht erst angefasst werden.
        output = self.run_install("    return 2")
        self.assertIn("RC=2", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")
        self.assertEqual(self.leftovers(), [])

    def assert_signal_during_swap_restores_both_bundles(self, signum):
        # Beim Einsetzen der zweiten App ist die erste bereits neu und die
        # zweite alte App liegt im Sicherungsordner. INT oder TERM darf diesen
        # Zwischenstand weder liegen lassen noch nur die Sperre entfernen.
        prelude = r'''
        mv() {
            if [[ "$1" == */.favenio-install.*/FavenioQuick.app &&
                  "$2" == "$FAVENIO_TEST_DEST/FavenioQuick.app" ]]; then
                print -r -- bereit > "$FAVENIO_TEST_READY"
                while true; do :; done
            fi
            command mv "$@"
        }'''
        ready = Path(self.tmp.name) / ("ready-%s" % signum)
        environment = dict(os.environ)
        environment["FAVENIO_TEST_DEST"] = self.dest
        environment["FAVENIO_TEST_READY"] = str(ready)
        process = subprocess.Popen(
            ["zsh", "-c", self.install_script("    return 0", prelude)],
            cwd=REPO, env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                break
            time.sleep(0.01)
        if not ready.exists():
            process.kill()
            output = process.communicate()[0].decode("utf-8", "replace")
            self.fail("Tauschphase nicht erreicht:\n%s" % output)
        process.send_signal(signum)
        output = process.communicate(timeout=5)[0].decode("utf-8", "replace")
        self.assertEqual(process.returncode, 2, output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")
        self.assertEqual(self.leftovers(), [])

    def test_sigint_during_the_swap_restores_both_bundles(self):
        self.assert_signal_during_swap_restores_both_bundles(signal.SIGINT)

    def test_sigterm_during_the_swap_restores_both_bundles(self):
        self.assert_signal_during_swap_restores_both_bundles(signal.SIGTERM)


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

    def test_team_requirement_reaches_codesign(self):
        # `path` ist in zsh an PATH gekoppelt. Eine lokale Variable dieses
        # Namens ließ die Team-Prüfung deshalb ihr `codesign` nicht finden;
        # ohne konfigurierte Team-ID blieb der Fehler unsichtbar.
        bundle = os.path.join(self.tmp.name, "Favenio.app")
        InstallTransactionTest.make_bundle(
            bundle, "x", bundle_id="local.favenio")
        stubs = os.path.join(self.tmp.name, "stubs")
        os.makedirs(stubs)
        log = os.path.join(self.tmp.name, "codesign-args")
        codesign = os.path.join(stubs, "codesign")
        with open(codesign, "w", encoding="utf-8") as handle:
            handle.write('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$CODESIGN_LOG"\n')
        os.chmod(codesign, 0o755)
        script = """
        set -uo pipefail
        source "%s/notarize-lib.sh"
        if favenio_verify_identity "%s" "Favenio.app"; then
            echo "RC=0"
        else
            echo "RC=$?"
        fi
        """ % (REPO, bundle)
        environment = dict(os.environ)
        environment["PATH"] = stubs + os.pathsep + environment["PATH"]
        environment["FAVENIO_TEAM_ID"] = "TESTTEAM00"
        environment["CODESIGN_LOG"] = log
        result = subprocess.run(["zsh", "-c", script], cwd=self.tmp.name,
                                env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        output = result.stdout.decode("utf-8", "replace")
        self.assertIn("RC=0", output)
        requirement = Path(log).read_text(encoding="utf-8")
        self.assertIn('certificate leaf[subject.OU] = "TESTTEAM00"',
                      requirement)


class RequiredTeamIdentityTest(unittest.TestCase):
    """Ein Release braucht die Team-ID zwingend; Installation darf sie nach
    dem bestehenden Vertrag weiterhin optional aus Umgebung oder Clone lesen."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def check(self, environment_team=None, configured_team=None):
        if configured_team is not None:
            subprocess.run(["git", "init", "-q"], cwd=self.tmp.name,
                           check=True)
            subprocess.run(
                ["git", "config", "--local", "favenio.teamId",
                 configured_team], cwd=self.tmp.name, check=True)
        script = """
        set -uo pipefail
        source "%s/notarize-lib.sh"
        if favenio_require_team_id; then
            echo "RC=0"
            echo "TEAM=$FAVENIO_TEAM_ID"
        else
            echo "RC=$?"
        fi
        """ % REPO
        environment = dict(os.environ)
        environment.pop("FAVENIO_TEAM_ID", None)
        if environment_team is not None:
            environment["FAVENIO_TEAM_ID"] = environment_team
        result = subprocess.run(["zsh", "-c", script], cwd=self.tmp.name,
                                env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_missing_team_is_rejected(self):
        output = self.check()
        self.assertIn("RC=2", output)
        self.assertIn("Entwickler-Team-ID", output)

    def test_environment_team_is_exported(self):
        output = self.check(environment_team="TESTTEAM00")
        self.assertIn("RC=0", output)
        self.assertIn("TEAM=TESTTEAM00", output)

    def test_malformed_environment_team_is_rejected(self):
        output = self.check(environment_team='BAD" or true')
        self.assertIn("RC=2", output)
        self.assertIn("zehn", output)

    def test_clone_local_team_is_exported(self):
        output = self.check(configured_team="LOCALTEAM0")
        self.assertIn("RC=0", output)
        self.assertIn("TEAM=LOCALTEAM0", output)


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
    # Der Update-Kanal besteht aus drei Werten; alle drei prueft install.sh.
    SPARKLE_KEY = "H504COadHZVAKo+/XD0jzXT5PJzghkS2t/DDYmuHPDg="

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
                    build=None, sparkle_key=None, signed_feed=True):
        """`build=None` übernimmt die Kurzversion, `build=""` lässt
        CFBundleVersion ganz weg. `sparkle_key`/`signed_feed` bauen die
        Negativfälle des Update-Kanals (Review-Fund 2026-08-17)."""
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "SUFeedURL": self.FEED_URL if feed_url is None else feed_url,
        }
        key = self.SPARKLE_KEY if sparkle_key is None else sparkle_key
        if key != "":
            info["SUPublicEDKey"] = key
        if signed_feed is not None:
            info["SURequireSignedFeed"] = signed_feed
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

    # --- Update-Kanal: Feed-URL allein genuegt nicht (Review-Fund 2026-08-17) ---

    def test_wrong_sparkle_key_is_rejected(self):
        """Ein gueltig signiertes DMG mit fremdem Schluessel wuerde jedes
        Update ablehnen — das darf nicht nach /Applications."""
        self.write_plist("Favenio.app", "local.favenio",
                         sparkle_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("prüft den Appcast", output)

    def test_missing_sparkle_key_is_rejected(self):
        self.write_plist("Favenio.app", "local.favenio", sparkle_key="")
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("keinem Schlüssel", output)

    def test_unsigned_feed_is_rejected(self):
        """Ohne SURequireSignedFeed akzeptierte die App einen unsignierten
        Appcast."""
        self.write_plist("Favenio.app", "local.favenio", signed_feed=False)
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("keine signierte Appcast-Datei", output)

    def test_missing_signed_feed_flag_is_rejected(self):
        self.write_plist("Favenio.app", "local.favenio", signed_feed=None)
        code, output = self.run_install()
        self.assertEqual(code, 2, output)
        self.assertIn("keine signierte Appcast-Datei", output)


class FeedUrlTest(unittest.TestCase):
    """favenio_verify_feed_url einzeln: Der Produktions-Feed ist Pflicht,
    jede Abweichung führt zum Abbruch (fail-closed)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def check(self, feed_url):
        path = os.path.join(self.tmp.name, "Favenio.app")
        os.makedirs(os.path.join(path, "Contents"), exist_ok=True)
        info = {
            "CFBundleIdentifier": "local.favenio",
            "SUPublicEDKey": InstallFromDmgTest.SPARKLE_KEY,
            "SURequireSignedFeed": True,
        }
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
