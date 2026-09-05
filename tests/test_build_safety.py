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


def applications_touching_lines(source):
    """Alle Befehlszeilen eines Shell-Skripts, die `/Applications` nennen
    oder eine laufende App abschießen. Kommentare zählen nicht — dort DARF
    stehen, dass der Build genau das nie tut. Eine Sperrliste aus vier
    Literalen ließ `cp -R Favenio.app /Applications/` glatt durch."""
    hits = []
    for line in source.splitlines():
        code = line.split("#", 1)[0]
        if "/Applications" in code or "pkill" in code or "killall" in code:
            hits.append(line.strip())
    return hits


class BuildSafetyTest(unittest.TestCase):
    def test_normal_build_never_mutates_applications(self):
        source = (REPO / "build-app.sh").read_text(encoding="utf-8")
        self.assertEqual(applications_touching_lines(source), [])

    def test_applications_guard_catches_any_copy_not_just_known_literals(self):
        # Der Wächter muss jede Form erkennen, nicht nur die vier Befehle,
        # die früher wörtlich verboten waren.
        for command in ("cp -R Favenio.app /Applications/",
                        "rsync -a Favenio.app /Applications",
                        'mv "$app" "/Applications/$app"',
                        "killall Favenio"):
            with self.subTest(command=command):
                self.assertEqual(
                    applications_touching_lines("# darf /Applications nennen\n"
                                                + command + "\n"),
                    [command])

    def test_release_checks_staple_and_gatekeeper_without_installing(self):
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn('xcrun stapler validate "$DMG_PATH"', source)
        self.assertIn('spctl --assess --type open', source)
        self.assertNotIn(" /Applications/Favenio.app", source)
        self.assertNotIn(" /Applications/FavenioQuick.app", source)

    def test_release_checks_the_bundles_as_strictly_as_an_install(self):
        # Die Kopie in release.sh prüfte nur Signatur und Ticket und ließ
        # `spctl` weg: Ein Release ging damit über eine schwächere Hürde
        # als eine lokale Installation. Beide rufen jetzt dieselbe
        # Funktion aus notarize-lib.sh.
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn('notarize_verify_installed "$VERIFY_MOUNT/$app"',
                      source)
        self.assertNotIn('codesign --verify --strict "$VERIFY_MOUNT/$app"',
                         source)
        self.assertNotIn('stapler validate "$VERIFY_MOUNT/$app"', source)

    def test_release_cleans_up_on_a_sigterm(self):
        # Gemessen am 2026-09-03 mit zsh 5.9, Signal an die ganze
        # Prozessgruppe: Ein EXIT-Trap läuft bei SIGINT und SIGHUP mit, bei
        # SIGTERM nicht. Hier wiegt das schwerer als in install.sh, weil
        # MOUNT_DIR ein FESTER Pfad ist: Ein liegengebliebenes
        # /Volumes/Favenio lässt jeden weiteren Lauf absichtlich abbrechen,
        # bis jemand von Hand auswirft.
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn("trap favenio_release_cleanup EXIT", source)
        self.assertIn("trap 'exit 1' HUP INT TERM", source)
        self.assertIn('MOUNT_DIR="/Volumes/$VOL_NAME"', source)

    def test_release_mounts_where_the_finder_can_address_the_disk(self):
        """Das Finder-Layout spricht die Platte als `disk "$VOL_NAME"` an.
        Der Finder führt ein Volume aber unter dem ORDNERNAMEN seines
        Mountpoints, nicht unter seinem Volume-Namen: Unter einem eigenen
        Mountpoint gibt es `disk "Favenio"` gar nicht (Fehler -1700), und der
        Standardlauf von release.sh bricht in Schritt 3 ab. Beide Zeilen
        gehören deshalb zusammen."""
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        if 'tell disk "$VOL_NAME"' in source:
            self.assertIn('MOUNT_DIR="/Volumes/$VOL_NAME"', source)
        # Der feste Pfad bleibt nur zulässig, solange ein fremdes Volume
        # gleichen Namens den Lauf abbricht und nur ein eigener Attach wieder
        # ausgehängt wird.
        self.assertIn('if [ -d "$MOUNT_DIR" ]; then', source)
        self.assertIn("BUILD_MOUNTED=1", source)
        self.assertIn('if [ "$BUILD_MOUNTED" = "1" ]; then', source)

    def test_release_checks_the_update_feed_of_both_bundles(self):
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn('favenio_verify_feed_url "$VERIFY_MOUNT/$app"', source)

    def test_release_requires_and_checks_the_developer_team(self):
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn("favenio_require_team_id", source)
        self.assertIn(
            'favenio_verify_identity "$VERIFY_MOUNT/$app" "$app"', source)

    def test_install_distinguishes_an_incomplete_rollback(self):
        install = (REPO / "install.sh").read_text(encoding="utf-8")
        library = (REPO / "notarize-lib.sh").read_text(encoding="utf-8")
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
        build = (REPO / "build-app.sh").read_text(encoding="utf-8")
        library = (REPO / "notarize-lib.sh").read_text(encoding="utf-8")
        self.assertIn(
            'SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-%s}"'
            % InstallFromDmgTest.FEED_URL, build)
        self.assertIn('FAVENIO_FEED_URL="%s"' % InstallFromDmgTest.FEED_URL,
                      library)

    def test_expected_update_key_matches_the_build_script(self):
        """Denselben Halt braucht der öffentliche Sparkle-Schlüssel. Er steht
        in build-app.sh (baut ihn in beide Info.plists), im Appcast-Workflow
        und seit dem Ausbau der Kanalprüfung auch in notarize-lib.sh — gegen
        DIESE Kopie prüfen install.sh und release.sh jedes Bundle. Die ersten
        beiden Kopien hält test_appcast_workflow zusammen, die dritte war
        ungeprüft."""
        build = (REPO / "build-app.sh").read_text(encoding="utf-8")
        library = (REPO / "notarize-lib.sh").read_text(encoding="utf-8")
        self.assertIn('SPARKLE_PUBLIC_KEY="%s"' % InstallFromDmgTest.SPARKLE_KEY,
                      build)
        self.assertIn(
            'FAVENIO_SPARKLE_PUBLIC_KEY="%s"' % InstallFromDmgTest.SPARKLE_KEY,
            library)

    def test_feed_url_is_not_interpolated_into_plist_xml(self):
        """Eine URL darf XML-Zeichen wie `&` enthalten. Der Wert muss daher
        vom Plist-Werkzeug serialisiert werden statt roh im Here-Dokument zu
        landen."""
        source = (REPO / "build-app.sh").read_text(encoding="utf-8")
        self.assertNotIn("<string>${SPARKLE_FEED_URL}</string>", source)
        self.assertIn(
            '/usr/bin/plutil -replace SUFeedURL -string "$SPARKLE_FEED_URL"',
            source)
        self.assertIn("set_sparkle_feed_url Favenio.app", source)
        self.assertIn("set_sparkle_feed_url FavenioQuick.app", source)

    def test_ad_hoc_build_omits_hardened_runtime(self):
        """Ohne Developer-ID haben App und Framework keine gemeinsame
        Team-ID. Hardened Runtime würde Sparkle dann beim Laden ablehnen."""
        source = (REPO / "build-app.sh").read_text(encoding="utf-8")
        self.assertIn(
            'if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then', source)
        self.assertIn('NESTED_SIGN=(--force --sign -)', source)
        self.assertIn(
            'APP_SIGN=(--force --entitlements assets/favenio.entitlements '
            '--sign -)', source)

    def test_ci_explicitly_exercises_ad_hoc_build(self):
        workflow = (REPO / ".github/workflows/ci.yml").read_text(
            encoding="utf-8")
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

    # Ablage- und Sicherungsordner tragen normalerweise eine Zufallskennung.
    # Für die Kollisionstests wird sie festgenagelt, sonst ließe sich der
    # seltene Fall gar nicht herstellen.
    FIXED_TOKEN = "testtoken"
    FIXED_TOKEN_PRELUDE = """
        _favenio_install_token() { printf 'testtoken' }"""

    def test_a_colliding_stage_folder_of_another_run_is_left_alone(self):
        # Früher legte EIN `mkdir` beide Ordner an. Existierte der Ablage-
        # ordner schon, entstand der Sicherungsordner trotzdem, und der
        # gemeinsame Rollback löschte anschließend den FREMDEN Ablageordner
        # samt Inhalt — obwohl der Lauf mit Exit 2 „nichts geändert" zusagt.
        foreign = os.path.join(self.dest,
                               ".favenio-install." + self.FIXED_TOKEN)
        os.makedirs(foreign)
        keep = os.path.join(foreign, "nicht-zurueckgeholt.txt")
        with open(keep, "w", encoding="utf-8") as handle:
            handle.write("alter Stand eines anderen Laufs")
        output = self.run_install("    return 0",
                                  prelude=self.FIXED_TOKEN_PRELUDE)
        self.assertIn("RC=2", output)
        self.assertTrue(os.path.exists(keep), output)
        # Nur der fremde Ordner bleibt: kein selbst erzeugter Rest, keine
        # liegen gebliebene Sperre.
        self.assertEqual(self.leftovers(),
                         [".favenio-install." + self.FIXED_TOKEN], output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")

    def test_a_colliding_backup_folder_of_another_run_is_left_alone(self):
        # Andersherum genauso: In einem fremden Sicherungsordner liegt ein
        # nicht zurückgeholter alter Stand. Der Rollback hätte dessen Bundles
        # nach dem bloßen Namen in den Zielordner geschoben.
        foreign = os.path.join(self.dest,
                               ".favenio-previous." + self.FIXED_TOKEN)
        self.make_bundle(os.path.join(foreign, "Favenio.app"), "fremd-alt")
        output = self.run_install("    return 0",
                                  prelude=self.FIXED_TOKEN_PRELUDE)
        self.assertIn("RC=2", output)
        self.assertEqual(self.marker(foreign, "Favenio.app"), "fremd-alt")
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        # Der eigene Ablageordner ist wieder weg, der fremde bleibt.
        self.assertEqual(self.leftovers(),
                         [".favenio-previous." + self.FIXED_TOKEN], output)

    def test_a_signal_before_the_folders_exist_removes_only_the_lock(self):
        # Zwischen erfolgreichem Sperren und dem Anlegen der Ordner laufen
        # externe Befehle (Zeitstempel, Zufallszahl). Ein HUP, INT oder TERM
        # in diesem Fenster beendete den Prozess, ohne die eigene Sperre
        # abzunehmen — jede weitere Installation lief danach in „es läuft
        # bereits eine Installation" und brauchte Handarbeit.
        # Der Kunstgriff: Die Token-Erzeugung schickt dem Skript selbst das
        # Signal und wartet danach kurz. Der Handler greift sofort — das
        # kurze Warten stellt nur sicher, dass die Zustellung nicht erst
        # NACH der Token-Erzeugung ankommt und dann einen anderen Weg testet.
        # Bleibt der Handler aus, kehrt die Funktion mit einem Token zurück
        # und der Test scheitert sichtbar, statt zu hängen. Das Warten bleibt
        # bewusst kurz: Der Unterprozess hält die Ausgabeleitung des Skripts
        # so lange offen, und genau so lange sammelt Python sie noch ein.
        prelude = r"""
        _favenio_install_token() {
            kill -TERM $$
            sleep 0.3
            printf 'nie'
        }"""
        result = subprocess.run(
            ["zsh", "-c", self.install_script("    return 0", prelude)],
            cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 2, output)
        self.assertIn("nichts installiert", output)
        self.assertEqual(self.leftovers(), [], output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")

    def test_signal_during_lock_creation_cannot_leave_the_lock_behind(self):
        # Der Signal-Handler steht vor dem Sperrversuch; den winzigen Abschnitt
        # aus atomarem mkdir und Besitzmarkierung schützt die Bibliothek selbst.
        # Vor dem ersten Fix starb zsh hier mit 143 und ließ die Sperre stehen.
        # Seit dem Review 2026-08-21 wird das Signal im kritischen Abschnitt
        # nur GEMERKT und danach ausgeführt: Der Abbruchwunsch darf nicht
        # verworfen werden, sonst liefe die Installation weiter und ersetzte
        # beide Apps. Erwartet ist deshalb Exit 2 mit unverändertem Altstand.
        prelude = r'''
        mkdir() {
            command mkdir "$@" || return $?
            if [[ "$1" == */.favenio-install.lock ]]; then
                kill -TERM $$
            fi
        }'''
        result = subprocess.run(
            ["zsh", "-c", self.install_script("    return 0", prelude)],
            cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 2, output)
        self.assertIn("nichts installiert", output)
        self.assertEqual(self.leftovers(), [], output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")

    def test_a_signal_that_hits_the_mkdir_process_itself_is_ignored_there(self):
        # Ctrl-C im Terminal trifft die ganze Prozessgruppe, also auch den
        # gerade laufenden mkdir-Prozess. Legt der den Ordner an und stirbt
        # dann mit Status 130/143, hielte die Bibliothek die eigene Sperre für
        # fremd und den eigenen Ablageordner für nicht erworben. Das Double
        # ist ein ECHTES Programm auf dem PATH, das sich nach dem Anlegen
        # selbst TERM schickt: Erbt es die Signal-Abschirmung der Bibliothek,
        # überlebt es und die Installation läuft normal durch.
        stubs = os.path.join(self.tmp.name, "stubs")
        os.makedirs(stubs)
        stub = os.path.join(stubs, "mkdir")
        with open(stub, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n"
                         '/bin/mkdir "$@" || exit $?\n'
                         'case "$1" in\n'
                         "    */.favenio-install.lock|*/.favenio-install.*|"
                         "*/.favenio-previous.*)\n"
                         "        kill -TERM $$\n"
                         "        sleep 0.2 ;;\n"
                         "esac\n"
                         "exit 0\n")
        os.chmod(stub, 0o755)
        prelude = 'export PATH="%s:$PATH"' % stubs
        output = self.run_install("    return 0", prelude=prelude)
        self.assertIn("RC=0", output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "neu")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "neu")
        self.assertEqual(self.leftovers(), [], output)

    def test_signal_during_backup_creation_leaves_no_private_folders(self):
        # Zwischen den beiden mkdir-Aufrufen kann nur der Ablageordner uns
        # gehören. Der Handler darf weder einen fremden Sicherungsordner
        # anfassen noch eigene Pfade liegen lassen. Auch hier wird das Signal
        # im kritischen mkdir/Handler-Wechsel gemerkt und unmittelbar danach
        # ausgeführt — Exit 2, alter Stand unverändert, keine eigenen Reste.
        # Hier gehören beide Ordner schon nachweislich diesem Lauf, deshalb
        # läuft der volle Rollback („alter Stand wird zurückgeholt") und nicht
        # der frühe Handler.
        prelude = r'''
        mkdir() {
            command mkdir "$@" || return $?
            if [[ "$1" == */.favenio-previous.* ]]; then
                kill -TERM $$
            fi
        }'''
        result = subprocess.run(
            ["zsh", "-c", self.install_script("    return 0", prelude)],
            cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 2, output)
        self.assertIn("Installation abgebrochen", output)
        self.assertEqual(self.leftovers(), [], output)
        self.assertEqual(self.marker(self.dest, "Favenio.app"), "alt")
        self.assertEqual(self.marker(self.dest, "FavenioQuick.app"), "alt")

    def test_early_signal_handler_never_removes_an_unowned_lock(self):
        # Nach dem Freigeben kann ein zweiter Lauf denselben Pfad sofort neu
        # anlegen. Ein verspäteter früher Handler darf dessen Sperre nicht nach
        # dem bloßen Namen löschen.
        lock = os.path.join(self.dest, ".favenio-install.lock")
        os.makedirs(lock)
        marker = os.path.join(lock, "fremder-lauf")
        Path(marker).write_text("behalten", encoding="utf-8")
        script = '''
        source "%s/notarize-lib.sh"
        FAVENIO_INSTALL_LOCK=""
        _favenio_install_interrupted_early "%s"
        ''' % (REPO, lock)
        result = subprocess.run(
            ["zsh", "-c", script], cwd=REPO, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT)
        output = result.stdout.decode("utf-8", "replace")
        self.assertEqual(result.returncode, 2, output)
        self.assertTrue(os.path.exists(marker), output)

    def test_failed_stage_cleanup_names_the_leftover(self):
        # Ein fremder Sicherungsordner erzwingt den frühen Fehlerweg. Scheitert
        # dort selbst das vorsichtige rmdir des eigenen Ablageordners, muss der
        # konkrete Restpfad auf stderr stehen statt still verschluckt zu werden.
        foreign = os.path.join(self.dest,
                               ".favenio-previous." + self.FIXED_TOKEN)
        os.makedirs(foreign)
        prelude = self.FIXED_TOKEN_PRELUDE + r'''
        rmdir() {
            if [[ "$1" == */.favenio-install.testtoken ]]; then
                return 1
            fi
            command rmdir "$@"
        }'''
        output = self.run_install("    return 0", prelude=prelude)
        self.assertIn("RC=2", output)
        self.assertIn("WARNUNG: Ablageordner", output)
        self.assertIn(".favenio-install.testtoken blieb stehen", output)

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
            # `detach` muss den Mountpoint LEEREN — genau das tut ein
            # echtes detach, und darauf verlässt sich das `rmdir` in
            # cleanup(). `rmdir` ist dort Absicht: Ein `rm -rf` auf einen
            # womöglich noch eingehängten Pfad wäre gefährlich. Ohne dieses
            # Leeren blieb je Testlauf ein mktemp-Ordner mit beiden
            # Attrappen-Bundles im Benutzer-Temp liegen; auf einem
            # Entwicklungsrechner hatten sich 922 angesammelt.
            'if [ "$1" = "detach" ]; then\n'
            '  for app in Favenio.app FavenioQuick.app; do\n'
            '    rm -rf "$2/$app"\n'
            "  done\n"
            "  exit 0\n"
            "fi\n"
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


class InheritedSparkleVariablesTest(InstallFromDmgTest):
    """Zwei Variablen, die build-app.sh für Sparkle-Tests im
    Projektverzeichnis kennt, dürfen nie in eine Installation
    durchschlagen. Geerbt würden sie einfach mitgegeben."""

    def run_with(self, **umgebung):
        environment = dict(os.environ)
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        environment["STUB_PLISTS"] = str(self.plists)
        environment.update(umgebung)
        result = subprocess.run(
            [str(REPO / "install.sh"), "--dmg", str(self.dmg),
             "--verify-only"],
            cwd=REPO, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.returncode, result.stdout.decode("utf-8", "replace")

    def test_a_foreign_feed_url_is_refused_before_anything_happens(self):
        # Geerbt richtete SPARKLE_FEED_URL die installierte App dauerhaft
        # auf einen fremden Update-Feed. Die vorhandene Feed-Prüfung greift
        # erst NACH der Notarisierung — sie hätte einen Notary-Vorgang
        # verbraucht und zwei fertig gestapelte Bundles hinterlassen.
        code, output = self.run_with(
            SPARKLE_FEED_URL="http://127.0.0.1:8000/appcast.xml")
        self.assertEqual(code, 2, output)
        self.assertIn("SPARKLE_FEED_URL", output)
        # Kein Schritt darf vorher gelaufen sein.
        self.assertNotIn("Schritt 1/3", output)
        self.assertNotIn("Schritt 2/3", output)

    def test_a_faked_build_number_is_refused(self):
        # FAVENIO_SPARKLE_TEST_VERSION setzt eine gefälschte Build-Nummer.
        # Die Gleichheitsprüfung in install.sh vergleicht nur die BEIDEN
        # Bundles gegeneinander und ginge durch; die installierte App böte
        # sich danach über Sparkle sofort selbst ein „Update" an.
        code, output = self.run_with(FAVENIO_SPARKLE_TEST_VERSION="0.13.9")
        self.assertEqual(code, 2, output)
        self.assertIn("FAVENIO_SPARKLE_TEST_VERSION", output)

    def test_without_them_the_run_passes_as_before(self):
        # Gegenprobe: Die Ablehnung darf den normalen Weg nicht behindern.
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("SPARKLE_FEED_URL",
                                      "FAVENIO_SPARKLE_TEST_VERSION")}
        code, output = self.run_with(**{})
        self.assertEqual(code, 0, output)
        self.assertIn("VERIFY OK", output)


class ReleaseRefusesInheritedSparkleVariablesTest(unittest.TestCase):
    """Dieselbe Wache wie in install.sh, nur für den Release-Weg.

    Bis 2026-09-04 lehnte release.sh nur FAVENIO_SPARKLE_TEST_VERSION früh
    ab. Ein geerbtes SPARKLE_FEED_URL fiel erst der Feed-Prüfung in
    Schritt 4 auf — also nach Bauen, Signieren, Notarisieren und Einhängen
    des DMG. Ein Notary-Vorgang bei Apple war damit schon verbraucht."""

    def setUp(self):
        # Bremse für den Fall, dass die Wache selbst kaputtgeht: Der Test
        # darf niemals einen echten Build oder gar eine Notarisierung
        # auslösen. Ein leeres NOTARY_PROFILE reicht dafür NICHT, aus zwei
        # Gründen (Review-Fund 2026-09-05): notarize_require_credentials
        # liest dann das clone-lokale Git-Attribut favenio.notaryProfile,
        # und auf einem Release-Mac steht dort ein echtes Profil. Und zsh
        # liest ~/.zshenv auch für Skripte — exportiert die Datei
        # NOTARY_PROFILE, ist der leere Wert schon vor der ersten Zeile von
        # release.sh überschrieben (auf einem Entwicklungsrechner belegt).
        # Deshalb bekommen git, security und xcrun Attrappen vor den PATH,
        # die nichts kennen: Ohne Profil aus git, ohne Signatur-Identität
        # aus security und ohne notarytool aus xcrun endet der Lauf sicher
        # an den Zugangsdaten, egal was die Shell mitbringt.
        self.stubs = Path(tempfile.mkdtemp(prefix="favenio-stubs-"))
        self.addCleanup(shutil.rmtree, self.stubs, ignore_errors=True)
        for tool in ("git", "security", "xcrun"):
            stub = self.stubs / tool
            stub.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            stub.chmod(0o755)

    def run_with(self, **umgebung):
        # Die beiden Sparkle-Testvariablen der aufrufenden Shell zuerst
        # entfernen: Geerbt löste die eine den Abbruch aus, den der Test
        # der anderen zuschrieb (Review-Fund 2026-09-05).
        environment = {key: value for key, value in os.environ.items()
                       if key not in ("SPARKLE_FEED_URL",
                                      "FAVENIO_SPARKLE_TEST_VERSION")}
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        environment["NOTARY_PROFILE"] = ""
        environment["FAVENIO_SIGN_ID"] = ""
        environment["FAVENIO_TEAM_ID"] = ""
        environment.update(umgebung)
        result = subprocess.run(
            [str(REPO / "release.sh")], cwd=REPO, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.returncode, result.stdout.decode("utf-8", "replace")

    def test_the_brake_holds_without_any_sparkle_variable(self):
        # Gegenprobe der Bremse selbst: Ohne Wache-Auslöser muss der Lauf
        # an den Zugangsdaten enden — VOR dem ersten Bauschritt.
        code, output = self.run_with()
        self.assertEqual(code, 2, output)
        # Welche der drei Linien greift, hängt von der Shell ab (siehe
        # setUp); mindestens eine muss es sein.
        self.assertTrue("Kein Notary-Profil bekannt" in output
                        or "keine Developer-ID gefunden" in output
                        or "nicht\nverwendbar" in output, output)
        self.assertNotIn("Schritt 1/5", output)

    def test_a_foreign_feed_url_is_refused_before_the_build(self):
        code, output = self.run_with(
            SPARKLE_FEED_URL="http://127.0.0.1:8000/appcast.xml")
        self.assertEqual(code, 1, output)
        self.assertIn("SPARKLE_FEED_URL", output)
        self.assertNotIn("Schritt 1/5", output)
        # Auch die Zugangsdatenprüfung darf nicht mehr drangekommen sein:
        # Die Ablehnung steht davor, nicht dahinter.
        self.assertNotIn("Kein Notary-Profil bekannt", output)

    def test_a_faked_build_number_is_still_refused(self):
        code, output = self.run_with(FAVENIO_SPARKLE_TEST_VERSION="0.13.9")
        self.assertEqual(code, 1, output)
        self.assertIn("FAVENIO_SPARKLE_TEST_VERSION", output)
        self.assertNotIn("Schritt 1/5", output)

    def test_the_late_feed_check_stays_as_a_second_line(self):
        # Die frühe Wache ersetzt die Prüfung im fertigen DMG nicht: Sie
        # deckt nur den Weg über die Umgebungsvariable ab.
        source = (REPO / "release.sh").read_text(encoding="utf-8")
        self.assertIn('favenio_verify_feed_url "$VERIFY_MOUNT/$app"', source)


class InstallSignalAndPromiseTest(unittest.TestCase):
    """Zwei Zusagen von install.sh, die sich nur am Skript selbst prüfen
    lassen — ein echter Lauf bräuchte /Applications und eine
    Notarisierung."""

    SCRIPT = (REPO / "install.sh").read_text(encoding="utf-8")

    def test_a_sigterm_still_runs_the_cleanup(self):
        # Gemessen am 2026-09-03 mit zsh 5.9, Signal an die ganze
        # Prozessgruppe: Ein EXIT-Trap läuft bei SIGINT (Ctrl-C) und bei
        # SIGHUP mit, bei SIGTERM aber NICHT — dann blieben das
        # eingehängte DMG und die Installationssperre liegen.
        self.assertIn("trap cleanup EXIT", self.SCRIPT)
        self.assertIn("trap 'exit 2' HUP INT TERM", self.SCRIPT)

    def test_exit_two_keeps_its_promise_after_the_swap(self):
        # Exit 2 verspricht: installierter Stand UNVERÄNDERT. Nach dem
        # Austausch stimmt das nicht mehr; erreichbar über
        # `install.sh | head`, wo die letzten echo-Zeilen mit SIGPIPE
        # enden.
        self.assertIn("INSTALLED=0", self.SCRIPT)
        self.assertIn('[ "$INSTALLED" = "1" ] && exit 0', self.SCRIPT)
        # Die Marke muss NACH dem Austausch gesetzt werden, sonst
        # verspricht sie das Falsche.
        self.assertLess(self.SCRIPT.index("favenio_install_bundles"),
                        self.SCRIPT.index("INSTALLED=1"))

    def test_the_three_checks_have_only_one_home(self):
        # Signatur, Gatekeeper und Ticket kommen aus notarize-lib.sh;
        # install.sh darf sie nicht ein zweites Mal ausschreiben.
        self.assertIn('notarize_verify_installed "$SOURCE_DIR/$app"',
                      self.SCRIPT)
        # Gemeint sind nur die BUNDLE-Prüfungen. Das DMG selbst prüft
        # install.sh weiterhin direkt (`stapler validate "$DMG"`,
        # `spctl --assess --type open`) — ein anderes Objekt mit einer
        # anderen Anforderung, das gehört nicht in dieselbe Funktion.
        for werkzeug in ("codesign", "spctl", "stapler"):
            self.assertNotIn('%s' % werkzeug + ' --verify --strict "$SOURCE_DIR',
                             self.SCRIPT, werkzeug)
        for aufruf in ('codesign --verify --strict "$SOURCE_DIR/$app"',
                       'spctl --assess --type execute "$SOURCE_DIR/$app"',
                       'stapler validate "$SOURCE_DIR/$app"'):
            self.assertNotIn(aufruf, self.SCRIPT, aufruf)
        # Und das DMG wird weiterhin selbst geprüft.
        self.assertIn('stapler validate "$DMG"', self.SCRIPT)
        self.assertIn("spctl --assess --type open", self.SCRIPT)


class NotarizeStageCleanupTest(unittest.TestCase):
    """`notarize_apps` legt ein mktemp-Verzeichnis mit Kopien beider Bundles
    an (rund 40 MB) plus das Zip. Beide Aufrufer rufen die Funktion NACKT
    auf, errexit ist also aktiv: Ein scheiterndes `stapler staple` oder ein
    Abbruch während `notarytool submit --wait` beendete das Skript sofort,
    und das Verzeichnis blieb liegen — bei jedem Versuch aufs Neue."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # macOS' `mktemp -d` ignoriert ein gesetztes TMPDIR und legt sein
        # Verzeichnis immer im Benutzer-Temp an. Ein Test, der dort nach
        # Resten sucht, träfe fremde Dateien und übersähe die eigenen.
        # Deshalb protokolliert eine mktemp-Attrappe den WIRKLICH
        # angelegten Pfad, und geprüft wird genau der.
        self.mktemp_log = self.root / "mktemp.log"
        self.stubs = self.root / "bin"
        self.stubs.mkdir()
        for app in ("Favenio.app", "FavenioQuick.app"):
            (self.root / app / "Contents").mkdir(parents=True)
        # `ditto` und `xcrun` als Attrappen; `xcrun` scheitert auf Wunsch.
        # `ditto` ist der Schritt, der wirklich undicht war: Der alte Code
        # entfernte das Verzeichnis erst NACH dem notarytool-Aufruf, die
        # beiden ditto-Aufrufe davor liefen unter errexit ungeschützt.
        (self.stubs / "ditto").write_text(
            '#!/bin/sh\n[ -n "${STUB_DITTO_FAILS:-}" ] && exit 1\n'
            'exit 0\n', encoding="utf-8")
        (self.stubs / "xcrun").write_text(
            '#!/bin/sh\n[ -n "${STUB_XCRUN_FAILS:-}" ] && exit 1\n'
            'exit 0\n', encoding="utf-8")
        (self.stubs / "spctl").write_text(
            "#!/bin/sh\nexit 0\n", encoding="utf-8")
        (self.stubs / "mktemp").write_text(
            '#!/bin/sh\nreal=$(/usr/bin/mktemp "$@") || exit 1\n'
            'printf \'%s\\n\' "$real" >> "$STUB_MKTEMP_LOG"\n'
            'printf \'%s\\n\' "$real"\n', encoding="utf-8")
        for stub in self.stubs.iterdir():
            stub.chmod(0o755)

    def run_notarize(self, fails=None):
        environment = dict(os.environ)
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        environment["STUB_MKTEMP_LOG"] = str(self.mktemp_log)
        environment["NOTARY_PROFILE"] = "attrappe"
        if fails is not None:
            environment["STUB_%s_FAILS" % fails.upper()] = "1"
        script = (
            'set -eu\n'
            'source "%s/notarize-lib.sh"\n'
            'cd "%s"\n'
            'notarize_apps\n'
            'echo "RC=$?"\n' % (REPO, self.root))
        result = subprocess.run(["zsh", "-c", script], env=environment,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.returncode, result.stdout.decode("utf-8", "replace")

    def leftovers(self):
        """Die von diesem Lauf angelegten Temp-Verzeichnisse, die noch da
        sind. Aufgeräumt wird hier auch selbst — ein fehlgeschlagener Test
        soll keine 40-MB-Reste hinterlassen."""
        if not self.mktemp_log.exists():
            return []
        offen = []
        for zeile in self.mktemp_log.read_text(encoding="utf-8").split("\n"):
            pfad = zeile.strip()
            if pfad and os.path.exists(pfad):
                offen.append(pfad)
                shutil.rmtree(pfad, ignore_errors=True)
        return offen

    def test_the_stage_is_gone_after_a_successful_run(self):
        code, output = self.run_notarize()
        self.assertEqual(code, 0, output)
        self.assertEqual(self.leftovers(), [], output)

    def test_the_stage_is_gone_when_copying_the_bundles_fails(self):
        # Genau der Pfad, der vorher liegenblieb: `ditto` steht VOR dem
        # `rm -rf` des alten Codes, und errexit beendet das Skript sofort.
        code, output = self.run_notarize(fails="ditto")
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.leftovers(), [], output)

    def test_the_stage_is_gone_when_notarisation_fails(self):
        # Diesen Pfad räumte schon der alte Code auf — die Gegenprobe hält
        # fest, dass er es weiterhin tut.
        code, output = self.run_notarize(fails="xcrun")
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.leftovers(), [], output)


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
