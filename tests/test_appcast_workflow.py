"""Prüft die Sicherheitsblöcke des Appcast-Workflows.

Der Workflow selbst kann hier nicht laufen (er braucht GitHub Actions, ein
echtes Release und eine Notarisierung). Getestet wird deshalb das, was
tatsächlich schützt: Die beiden markierten Shell-Blöcke werden WÖRTLICH aus
`.github/workflows/publish-appcast.yml` gelesen und lokal gegen gute und
schlechte Eingaben ausgeführt — mit vorgeschobenen Werkzeugen für codesign,
spctl und xcrun. Weicht der Workflow ab, fällt der Test, nicht erst das
nächste Release.
"""

import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WORKFLOW = REPO / ".github/workflows/publish-appcast.yml"
BUILD_SCRIPT = REPO / "build-app.sh"

# Der Update-Schlüssel des Produkts (öffentlich, steht so in build-app.sh und
# in beiden Info.plists).
PRODUCTION_KEY = "H504COadHZVAKo+/XD0jzXT5PJzghkS2t/DDYmuHPDg="

# Der Produktions-Update-Feed — ebenfalls aus build-app.sh, und die URL, gegen
# die der Workflow das Release-Artefakt prüft.
PRODUCTION_FEED = "https://danielmuellerir.github.io/favenio/appcast.xml"

# Keine echte Projekt-ID, sondern die feste Herausgeber-ID der Test-Stubs.
TEST_TEAM_ID = "TESTTEAM00"

# Ein öffentlicher Testschlüssel und ein damit von Sparkles echtem
# `sign_update` signierter Mini-Feed. Das Werkzeug hängt den Signaturblock
# direkt an `</rss>` an. Ed25519 ist deterministisch, deshalb ist die Signatur
# eine feste Konstante und der Test braucht kein Schlüsselmaterial und keinen
# Sparkle-Download.
FIXTURE_KEY = "Fv6jwB9CT7NsfnVzII4LNyTly5IPudZeMk6ERLMYiFA="
FIXTURE_BODY = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<rss version="2.0"><channel><title>Favenio Updates</title>'
    "</channel></rss>"
)
FIXTURE_SIGNATURE = (
    "A4rC66eyLoTNa1ykiKoKhiesvLqTquyUr+w4BMvmH2OJjtB/1CSM+PFXY8dd4bEVE"
    "Fg/rBR+/vIXZU/C8XeIDg=="
)


def workflow_lines():
    return WORKFLOW.read_text(encoding="utf-8").splitlines()


def _dedent(lines, width):
    """Nimmt die Einrückung des YAML-Blocks zurück — genau das, was der
    YAML-Parser mit einem `run: |`-Block macht, bevor die Shell ihn sieht."""
    return "\n".join(line[width:] if line.strip() else "" for line in lines)


def extract_marked_block(name):
    """Holt den Shell-Block zwischen den BEGIN/END-Marken aus dem Workflow."""
    lines = workflow_lines()
    begin = end = None
    for index, line in enumerate(lines):
        if line.strip() == "# ===== BEGIN %s =====" % name:
            begin = index
        elif line.strip() == "# ===== END %s =====" % name:
            end = index
    if begin is None or end is None or end <= begin:
        raise AssertionError("Block '%s' fehlt im Workflow." % name)
    width = len(lines[begin]) - len(lines[begin].lstrip())
    return _dedent(lines[begin + 1:end], width)


def extract_run_block(step_name):
    """Holt das komplette `run: |`-Skript eines Workflow-Schritts."""
    lines = workflow_lines()
    start = None
    for index, line in enumerate(lines):
        if line.strip() == "- name: %s" % step_name:
            start = index
            break
    if start is None:
        raise AssertionError("Schritt '%s' fehlt im Workflow." % step_name)
    for index in range(start, len(lines)):
        if lines[index].strip() == "run: |":
            break
    else:
        raise AssertionError("Schritt '%s' hat kein run-Skript." % step_name)
    body = lines[index + 1:]
    width = len(body[0]) - len(body[0].lstrip())
    collected = []
    for line in body:
        if line.strip() and len(line) - len(line.lstrip()) < width:
            break
        collected.append(line)
    return _dedent(collected, width)


def make_stub(folder, name):
    """Ein Ersatzwerkzeug, das anhand seines LETZTEN Arguments entscheidet.
    Steht der Dateiname in der passenden Umgebungsvariablen, scheitert es —
    so lassen sich fehlendes Ticket, Gatekeeper-Ablehnung und kaputte
    Signatur einzeln nachstellen."""
    path = folder / name
    team_check = ""
    if name == "codesign":
        team_check = (
            'if [ -n "${STUB_EXPECT_TEAM:-}" ]; then\n'
            '  printf \'%s\\n\' "$@" | /usr/bin/grep -F '
            '\'certificate leaf[subject.OU] = "\'"$STUB_EXPECT_TEAM"\'"\' '
            ">/dev/null || exit 3\n"
            "fi\n"
        )
    path.write_text(
        "#!/bin/sh\n"
        + team_check
        + "for last; do :; done\n"
        'entry=$(basename "$last")\n'
        'case " ${STUB_FAIL_%s:-} " in *" $entry "*) exit 1 ;; esac\n'
        "exit 0\n" % name.upper(),
        encoding="utf-8",
    )
    path.chmod(0o755)


class WorkflowShellSyntaxTest(unittest.TestCase):
    """Die beiden run-Skripte müssen für die Shell gültig bleiben; ein
    Tippfehler im Workflow fiele sonst erst beim nächsten Release auf."""

    def test_run_blocks_are_valid_bash(self):
        for step in ("Download release DMG and notes",
                     "Generate signed appcast"):
            script = extract_run_block(step)
            result = subprocess.run(["bash", "-n"], input=script.encode(),
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT)
            self.assertEqual(result.returncode, 0,
                             "%s: %s" % (step,
                                         result.stdout.decode("utf-8",
                                                              "replace")))

    def test_selftest_no_longer_verifies_with_the_private_key(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("--ed-key-file - --verify", text)
        self.assertIn("favenio_check_feed site/appcast.xml", text)

    def test_expected_update_key_matches_build_script(self):
        build = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn('SPARKLE_PUBLIC_KEY="%s"' % PRODUCTION_KEY, build)
        self.assertIn('SPARKLE_PUBLIC_KEY: "%s"' % PRODUCTION_KEY,
                      WORKFLOW.read_text(encoding="utf-8"))

    def test_expected_feed_url_matches_build_script(self):
        """Der Workflow prüft gegen eine Kopie des Feed-Defaults aus
        build-app.sh. Laufen die auseinander, prüft das Release-Tor gegen eine
        URL, die gar nicht mehr gebaut wird."""
        build = BUILD_SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            'SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-%s}"' % PRODUCTION_FEED,
            build)
        self.assertIn('local expected_feed="%s"' % PRODUCTION_FEED,
                      WORKFLOW.read_text(encoding="utf-8"))

    def test_team_id_comes_from_an_actions_variable(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("FAVENIO_TEAM_ID: ${{ vars.FAVENIO_TEAM_ID }}", workflow)
        self.assertIn('"$SPARKLE_PUBLIC_KEY" "$FAVENIO_TEAM_ID"', workflow)

    def test_dmg_is_verified_before_it_is_mounted(self):
        script = extract_run_block("Generate signed appcast")
        verify = script.index('favenio_check_dmg "$dmg"')
        mount = script.index('hdiutil attach "$dmg"')
        self.assertLess(verify, mount)


class CheckDmgTest(unittest.TestCase):
    """Das heruntergeladene Release-DMG wird vor dem Mounten geprüft."""

    BLOCK = None

    @classmethod
    def setUpClass(cls):
        cls.BLOCK = extract_marked_block("favenio-check-dmg")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        for tool in ("xcrun", "spctl"):
            make_stub(self.stubs, tool)
        self.dmg = self.tmp / "Favenio-0.21.1.dmg"
        self.dmg.write_bytes(b"kein echtes Abbild")

    def run_check(self, **fails):
        script = (
            "set -euo pipefail\n"
            + self.BLOCK
            + "\n"
            'if favenio_check_dmg "$1"; then\n'
            '  echo "RC=0"\n'
            "else\n"
            '  echo "RC=$?"\n'
            "fi\n"
        )
        path = self.tmp / "harness.sh"
        path.write_text(script, encoding="utf-8")
        environment = dict(os.environ)
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        for tool, entries in fails.items():
            environment["STUB_FAIL_%s" % tool.upper()] = entries
        result = subprocess.run(
            ["bash", str(path), str(self.dmg)], cwd=REPO, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_valid_dmg_passes(self):
        self.assertIn("RC=0", self.run_check())

    def test_dmg_without_stapled_ticket_is_rejected(self):
        output = self.run_check(xcrun="Favenio-0.21.1.dmg")
        self.assertIn("RC=1", output)
        self.assertIn("no stapled notarization ticket", output)

    def test_dmg_rejected_by_gatekeeper_is_rejected(self):
        output = self.run_check(spctl="Favenio-0.21.1.dmg")
        self.assertIn("RC=1", output)
        self.assertIn("Gatekeeper rejects", output)


class CheckArtifactTest(unittest.TestCase):
    """favenio_check_artifact ist das Tor vor der Signatur: Nur ein
    notarisiertes, gestapeltes, zum Tag passendes Favenio-DMG darf durch."""

    BLOCK = None

    @classmethod
    def setUpClass(cls):
        cls.BLOCK = extract_marked_block("favenio-check-artifact")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        for tool in ("xcrun", "spctl", "codesign"):
            make_stub(self.stubs, tool)
        self.mount = self.tmp / "mount"
        self.mount.mkdir()
        self.add_app("Favenio.app", "local.favenio")
        self.add_app("FavenioQuick.app", "local.favenio.quick")

    def add_app(self, name, bundle_id, version="0.21.1", build="0.21.1",
                key=PRODUCTION_KEY, feed=PRODUCTION_FEED, signed_feed=True):
        """Legt ein Bundle-Gerüst mit Info.plist an. `key`, `feed` und
        `signed_feed` auf None lassen den jeweiligen Schlüssel ganz weg."""
        app = self.mount / name
        (app / "Contents").mkdir(parents=True)
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        }
        if key is not None:
            info["SUPublicEDKey"] = key
        if feed is not None:
            info["SUFeedURL"] = feed
        if signed_feed is not None:
            info["SURequireSignedFeed"] = signed_feed
        with open(app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump(info, handle)
        return app

    def run_check(self, tag="v0.21.1", expected_key=PRODUCTION_KEY,
                  expected_team=TEST_TEAM_ID, **fails):
        script = (
            "set -euo pipefail\n"
            + self.BLOCK
            + "\n"
            "if favenio_check_artifact \"$1\" \"$2\" \"$3\" \"$4\"; then\n"
            '  echo "RC=0"\n'
            "else\n"
            '  echo "RC=$?"\n'
            "fi\n"
            'echo "VERSION=${ARTIFACT_VERSION:-}"\n'
            'echo "BUILD=${ARTIFACT_BUILD:-}"\n'
            'echo "PUBLIC_KEY=${ARTIFACT_PUBLIC_KEY:-}"\n'
        )
        path = self.tmp / "harness.sh"
        path.write_text(script, encoding="utf-8")
        environment = dict(os.environ)
        environment["PATH"] = "%s%s%s" % (self.stubs, os.pathsep,
                                          environment["PATH"])
        environment["STUB_EXPECT_TEAM"] = expected_team
        for tool, entries in fails.items():
            environment["STUB_FAIL_%s" % tool.upper()] = entries
        result = subprocess.run(
            ["bash", str(path), str(self.mount), tag, expected_key,
             expected_team],
            cwd=REPO, env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    # ---------- guter Fall ----------

    def test_valid_release_artifact_passes(self):
        output = self.run_check()
        self.assertIn("RC=0", output)
        self.assertIn("VERSION=0.21.1", output)
        self.assertIn("BUILD=0.21.1", output)
        self.assertIn("PUBLIC_KEY=%s" % PRODUCTION_KEY, output)

    def test_tag_without_v_prefix_is_accepted(self):
        self.assertIn("RC=0", self.run_check(tag="0.21.1"))

    def test_missing_expected_team_is_rejected(self):
        output = self.run_check(expected_team="")
        self.assertIn("RC=1", output)
        self.assertIn("developer team ID is missing", output)

    def test_malformed_expected_team_is_rejected(self):
        output = self.run_check(expected_team='BAD" or true')
        self.assertIn("RC=1", output)
        self.assertIn("developer team ID is invalid", output)

    # ---------- schlechte Fälle ----------

    def test_bundle_with_broken_signature_is_rejected(self):
        output = self.run_check(codesign="FavenioQuick.app")
        self.assertIn("RC=1", output)
        self.assertIn("invalid code signature", output)

    def test_bundle_rejected_by_gatekeeper_is_rejected(self):
        output = self.run_check(spctl="Favenio.app")
        self.assertIn("RC=1", output)
        self.assertIn("Gatekeeper rejects Favenio.app", output)

    def test_bundle_without_stapled_ticket_is_rejected(self):
        output = self.run_check(xcrun="FavenioQuick.app")
        self.assertIn("RC=1", output)
        self.assertIn("carries no stapled ticket", output)

    def test_foreign_bundle_identifier_is_rejected(self):
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "com.example.trojaner")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("unexpected bundle identifier", output)

    def test_bundle_identifier_of_the_other_app_is_rejected(self):
        # Früher wurden die IDs nur gezählt: „einmal local.favenio, einmal
        # local.favenio.quick" stimmte auch dann, wenn beide am falschen
        # Bundle hingen. Erwartet wird die ID jetzt je Dateiname.
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "local.favenio")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("unexpected bundle identifier", output)
        self.assertIn("expected 'local.favenio.quick'", output)

    def test_swapped_bundle_identifiers_are_rejected(self):
        # Der Vertauschungsfall: beide IDs sind da, aber über Kreuz. Die
        # Zählung von früher hätte ihn durchgelassen; danach hätte jede App
        # das jeweils andere Programm aktualisiert.
        for name in ("Favenio.app", "FavenioQuick.app"):
            shutil.rmtree(self.mount / name)
        self.add_app("Favenio.app", "local.favenio.quick")
        self.add_app("FavenioQuick.app", "local.favenio")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("unexpected bundle identifier", output)

    def test_unknown_app_name_is_rejected(self):
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("Trojaner.app", "local.favenio.quick")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("unexpected app 'Trojaner.app'", output)

    def test_foreign_update_feed_is_rejected(self):
        # Ein aus der Umgebung geerbtes SPARKLE_FEED_URL landet über
        # build-app.sh im Bundle und richtete jede ausgelieferte App dauerhaft
        # auf einen fremden Update-Kanal.
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "local.favenio.quick",
                     feed="https://example.invalid/appcast.xml")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("looks for updates at", output)

    def test_missing_update_feed_is_rejected(self):
        shutil.rmtree(self.mount / "Favenio.app")
        self.add_app("Favenio.app", "local.favenio", feed=None)
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("looks for updates at 'none'", output)

    def test_unsigned_feed_setting_is_rejected(self):
        # Ohne SURequireSignedFeed nähme die App auch einen unsignierten Feed
        # an — die Feed-Signatur im Workflow wäre dann folgenlos.
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "local.favenio.quick",
                     signed_feed=False)
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("does not require a signed update feed", output)

    def test_missing_signed_feed_setting_is_rejected(self):
        shutil.rmtree(self.mount / "Favenio.app")
        self.add_app("Favenio.app", "local.favenio", signed_feed=None)
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("SURequireSignedFeed is 'none'", output)

    def test_build_number_below_the_version_is_rejected(self):
        # Genau ein Build mit FAVENIO_SPARKLE_TEST_VERSION: Der Tag passt zur
        # Kurzversion, Sparkle vergleicht aber CFBundleVersion.
        for name, bundle_id in (("Favenio.app", "local.favenio"),
                                ("FavenioQuick.app", "local.favenio.quick")):
            shutil.rmtree(self.mount / name)
            self.add_app(name, bundle_id, build="0.13.9")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("does not match app version", output)
        self.assertIn("test build", output)

    def test_differing_versions_are_rejected(self):
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "local.favenio.quick",
                     version="0.21.0", build="0.21.0")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("app versions in the release DMG differ", output)

    def test_foreign_update_key_is_rejected(self):
        shutil.rmtree(self.mount / "FavenioQuick.app")
        self.add_app("FavenioQuick.app", "local.favenio.quick",
                     key=FIXTURE_KEY)
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("trusts update key", output)

    def test_missing_update_key_is_rejected(self):
        shutil.rmtree(self.mount / "Favenio.app")
        self.add_app("Favenio.app", "local.favenio", key=None)
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("trusts update key 'none'", output)

    def test_tag_that_does_not_match_the_version_is_rejected(self):
        output = self.run_check(tag="v0.22.0")
        self.assertIn("RC=1", output)
        self.assertIn("does not match app version", output)

    def test_wrong_number_of_apps_is_rejected(self):
        self.add_app("Third.app", "local.favenio.third")
        output = self.run_check()
        self.assertIn("RC=1", output)
        self.assertIn("exactly two apps", output)


@unittest.skipUnless(shutil.which("swift"), "swift wird für CryptoKit gebraucht")
class CheckFeedTest(unittest.TestCase):
    """favenio_check_feed prüft die eingebettete Feed-Signatur gegen den
    öffentlichen Schlüssel aus den Bundles — nicht mehr gegen den privaten
    Schlüssel, mit dem gerade signiert wurde."""

    BLOCK = None

    @classmethod
    def setUpClass(cls):
        cls.BLOCK = extract_marked_block("favenio-check-feed")

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write_feed(self, body=FIXTURE_BODY, signature=FIXTURE_SIGNATURE,
                   length=None):
        if length is None:
            length = len(body.encode("utf-8"))
        feed = self.tmp / "appcast.xml"
        feed.write_bytes(
            body.encode("utf-8")
            + ("<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n"
               % (signature, length)).encode("utf-8"))
        return feed

    def run_check(self, feed, key=FIXTURE_KEY):
        script = (
            "set -euo pipefail\n"
            + self.BLOCK
            + "\n"
            'if favenio_check_feed "$1" "$2"; then\n'
            '  echo "RC=0"\n'
            "else\n"
            '  echo "RC=$?"\n'
            "fi\n"
        )
        path = self.tmp / "harness.sh"
        path.write_text(script, encoding="utf-8")
        result = subprocess.run(["bash", str(path), str(feed), key],
                                cwd=REPO, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        return result.stdout.decode("utf-8", "replace")

    def test_signature_matching_the_bundle_key_passes(self):
        feed = self.write_feed()
        self.assertIn("</rss><!-- sparkle-signatures:",
                      feed.read_text(encoding="utf-8"))
        output = self.run_check(feed)
        self.assertIn("RC=0", output)
        self.assertIn("verified against SUPublicEDKey", output)

    def test_signature_from_a_foreign_key_is_rejected(self):
        # Genau der Fall aus der Review: signiert wurde mit einem anderen
        # Schlüssel, als die Apps in SUPublicEDKey tragen.
        output = self.run_check(self.write_feed(), key=PRODUCTION_KEY)
        self.assertNotIn("RC=0", output)
        self.assertIn("does not match SUPublicEDKey", output)

    def test_tampered_feed_is_rejected(self):
        # Gleiche Länge, anderer Inhalt: Der Signaturblock passt weiterhin
        # zur Datei, die Signatur aber nicht mehr zum Text.
        tampered = FIXTURE_BODY.replace("Favenio Updates", "Favenio Updatez")
        self.assertEqual(len(tampered), len(FIXTURE_BODY))
        output = self.run_check(self.write_feed(body=tampered))
        self.assertNotIn("RC=0", output)
        self.assertIn("does not match SUPublicEDKey", output)

    def test_unsigned_feed_is_rejected(self):
        feed = self.tmp / "appcast.xml"
        feed.write_text(FIXTURE_BODY, encoding="utf-8")
        output = self.run_check(feed)
        self.assertIn("RC=1", output)
        self.assertIn("no embedded Sparkle signature", output)

    def test_length_beyond_the_file_is_rejected(self):
        output = self.run_check(self.write_feed(length=99999))
        self.assertIn("RC=1", output)
        self.assertIn("does not fit", output)

    def test_non_numeric_length_is_rejected(self):
        output = self.run_check(self.write_feed(length="viele"))
        self.assertIn("RC=1", output)
        self.assertIn("non-numeric signed length", output)


if __name__ == "__main__":
    unittest.main()
