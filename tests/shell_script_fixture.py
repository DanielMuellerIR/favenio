"""Führt macOS-Skripte mit lokalen Dateien und Werkzeugattrappen aus."""

import os
import plistlib
import re
import shutil
from shlex import quote
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
APPS = ("Favenio.app", "FavenioQuick.app")
COMMIT = "a" * 40
TEAM = "ABC123XYZ9"
SIGN_ID = "Developer ID Application: Fixture"


class ScriptFixture:
    def __init__(self, root, script):
        self.root = Path(root).resolve()
        self.source = self.root / "source checkout"
        self.source.mkdir()
        self.temp = self.root / "tmp"
        self.temp.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.dest = self.root / "installed apps"
        self.mount = self.root / "volumes" / "Favenio"
        self.mount.parent.mkdir()
        self.mount_lock = self.root / "mount.lock"
        self.dmg = self.root / "fixture.dmg"
        self.dmg.touch()
        self.log = self.root / "calls.tsv"
        self.log.touch()
        (self.root / "plists").mkdir()
        for app, identifier in zip(APPS, ("local.favenio", "local.favenio.quick")):
            self.write_plist(app, CFBundleIdentifier=identifier)
        for name in (script, "notarize-lib.sh", "favenio.py", "THIRD-PARTY.md"):
            shutil.copy2(REPO / name, self.source / name)
        (self.source / "tools").mkdir()
        shutil.copy2(REPO / "tools/generate-document-limits.py",
                     self.source / "tools/generate-document-limits.py")
        (self.source / "common").mkdir()
        for name in ("update-feed-url.txt", "update-public-key.txt"):
            shutil.copy2(REPO / "common" / name, self.source / "common" / name)
        if script == "build-app.sh":
            (self.source / "icons").mkdir()
            for app in APPS:
                (self.source / "icons" / (Path(app).stem + ".icns")).touch()
        if script == "release.sh":
            self.redirect_assignment(script, "MOUNT_DIR", self.mount)
            self.redirect_assignment(script, "MOUNT_LOCK_PATH", self.mount_lock)
            self.write_executable(self.source / "build.sh", '#!/bin/sh\nexec fixture-build\n')
        if script == "install.sh":
            self.redirect_assignment(script, "DEST", self.dest)
            self.dest.mkdir()
            for app in APPS:
                (self.dest / app).mkdir()
                (self.dest / app / "marker").write_text("alt", encoding="utf-8")
        stub = self.bin / "fixture-tool"
        self.write_executable(stub, r"""#!/bin/sh
name=${0##*/}
{
    printf '%s' "$name"
    printf '\t%s' "$@"
    printf '\n'
} >> "$FAVENIO_FIXTURE/calls.tsv"
case "$name:${FIXTURE_SCENARIO:-}" in
    codesign:bad-signature|codesign:foreign-team|codesign:slow-install-output|codesign:install-second-bundle-rejected) ;;
    spctl:bad-bundle-gatekeeper|spctl:bad-dmg-gatekeeper) ;;
    xcrun:bad-bundle-ticket|xcrun:bad-dmg-ticket) ;;
    codesign:*|spctl:*|xcrun:*|sleep:*) exit 0 ;;
    pgrep:*|security:*) exit 1 ;;
    killall:*|pkill:*) exit 99 ;;
esac
""" + f'exec {shell_quote(sys.executable)} {shell_quote(__file__)} "$name" "$@"\n')
        for tool in ("codesign", "ditto", "fixture-build", "fixture-selftest", "git",
                     "hdiutil", "killall", "ln", "mktemp", "osascript", "pgrep", "pkill",
                     "security", "sips", "sleep", "spctl", "swift", "swiftc", "tiffutil", "xcrun"):
            (self.bin / tool).symlink_to(stub)
        self.command = ["/bin/zsh", "-f", str(self.source / script)]

    @staticmethod
    def write_executable(path, body):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def redirect_assignment(self, script, variable, destination):
        path = self.source / script
        original = path.read_text(encoding="utf-8")
        redirected, count = re.subn(rf"^{variable}=.*$", f"{variable}={shell_quote(destination)}",
                                    original, flags=re.MULTILINE)
        if count != 1:
            raise AssertionError(f"{script}: isoliertes Ziel für {variable} nicht eindeutig")
        path.write_text(redirected, encoding="utf-8")

    def environment(self, **overrides):
        return dict({"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                     "ZDOTDIR": str(self.root), "TMPDIR": str(self.temp),
                     "PYTHONDONTWRITEBYTECODE": "1", "FAVENIO_FIXTURE": str(self.root),
                     "FAVENIO_TEAM_ID": TEAM, "NOTARY_PROFILE": "fixture-profile",
                     "FAVENIO_SIGN_ID": SIGN_ID}, **overrides)

    def run(self, *args, **overrides):
        return subprocess.run([*self.command, *args], cwd=self.source, env=self.environment(**overrides),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=30)

    def write_plist(self, app, **fields):
        path = self.root / "plists" / (app + ".plist")
        info = plistlib.loads(path.read_bytes()) if path.exists() else {
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0",
            "SUFeedURL": (REPO / "common" / "update-feed-url.txt").read_text().strip(),
            "SUPublicEDKey": (REPO / "common" / "update-public-key.txt").read_text().strip(),
            "SURequireSignedFeed": True,
        }
        path.write_bytes(plistlib.dumps(dict(info, **fields)))

    def calls(self, tool):
        entries = (line.split("\t") for line in self.log.read_text(encoding="utf-8").splitlines())
        return [[arg for arg in entry[1:] if arg] for entry in entries if entry[0] == tool]


def shell_quote(value):
    return quote(str(value))


def isolated_path(value):
    path = Path(value).resolve()
    if root not in path.parents:
        raise ValueError(f"Werkzeugattrappe: {path} liegt außerhalb der Testdaten")
    return path


def fill_bundles(path):
    for app in APPS:
        bundle = path / app
        (bundle / "Contents").mkdir(parents=True)
        shutil.copyfile(root / "plists" / (app + ".plist"), bundle / "Contents" / "Info.plist")
        (bundle / "marker").write_text("neu", encoding="utf-8")


def hdiutil(args):
    action = args[0]
    info = root / "mount.plist"
    if action == "info":
        sys.stdout.buffer.write(info.read_bytes())
    elif action == "create":
        isolated_path(args[-1]).touch()
        if scenario == "foreign":
            foreign_mount = root / "volumes" / "Favenio"
            foreign_mount.mkdir()
            info.write_bytes(plistlib.dumps({"images": [{
                "image-path": str(root / "foreign.dmg"), "system-entities": [{
                    "mount-point": str(foreign_mount), "dev-entry": "/dev/foreignFixture"}]}]}))
    elif action == "attach":
        mount = isolated_path(args[args.index("-mountpoint") + 1])
        building = "-readwrite" in args
        if building and scenario == "foreign":
            return 1
        if building:
            image = isolated_path(args[-1])
            entity = {"dev-entry": "/dev/ownFixture"}
            if scenario != "partial":
                mount.mkdir()
                entity["mount-point"] = str(mount)
            info.write_bytes(plistlib.dumps({"images": [{"image-path": str(image), "system-entities": [entity]}]}))
            if scenario in ("term-during-attach", "partial"):
                os.kill(os.getppid(), signal.SIGTERM)
        else:
            fill_bundles(mount)
            if scenario == "term-during-verification":
                os.kill(os.getppid(), signal.SIGTERM)
            if scenario == "pipe-during-verification":
                os.kill(os.getppid(), signal.SIGPIPE)
    elif action == "detach":
        target = args[-1] if args[1] == "-force" else args[1]
        if target == "/dev/ownFixture":
            info.unlink()
            mount = root / "volumes" / "Favenio"
            if mount.exists():
                shutil.rmtree(mount)
        else:
            mount = isolated_path(target)
            for app in APPS:
                shutil.rmtree(mount / app)
    elif action == "convert":
        isolated_path(args[args.index("-o") + 1]).write_bytes(b"fixture DMG")
    else:
        raise ValueError(args)
    return 0


def git(args):
    if args[0] == "status":
        if scenario == "dirty" or (scenario == "dirty-after-build" and Path("dirty").exists()):
            print("?? dirty")
    elif args == ["config", "--local", "--get", "favenio.teamId"]:
        return 1
    elif args[:2] == ["rev-parse", "--verify"]:
        changed = scenario == "head-changed" and Path("dirty").exists()
        print("b" * 40 if changed else COMMIT)
    elif args[:3] == ["worktree", "add", "--detach"]:
        shutil.copytree(Path.cwd(), isolated_path(args[3]), ignore=shutil.ignore_patterns(".build", "dist"))
    elif args[:3] == ["worktree", "remove", "--force"]:
        target = isolated_path(args[3])
        if target.exists():
            shutil.rmtree(target)
    else:
        raise ValueError(args)
    return 0


def selftest(args):
    path, *options = args
    if "--check-bundle" in options:
        print("fixture bundle OK")
    elif failure_option := next((option for option in options if option.startswith("--fail-")), None):
        expected = {
            "--fail-date": "Erzwungener Fehler im Datumstest",
            "--fail-preferences": "Erzwungener Fehler nach Änderung der Finder-Spalten",
            "--fail-scope-capture": "Bildaufnahme fehlgeschlagen (Status 1)",
        }[failure_option]
        print(f"SELFTEST FEHLER: {expected}")
        if scenario != "irregular-failure":
            print("SELFTEST ISOLATION OK")
        return 1
    elif scenario == "missing-marker":
        print("Prüfung lief")
    elif scenario == "failing-selftest":
        print("SELFTEST FEHLER: Fixture")
        return 1
    else:
        print("SELFTEST OK — Fixture")
        if scenario == "early-marker":
            print("Ausgabe nach der Erfolgsmeldung")
        elif scenario == "duplicate-marker":
            print("SELFTEST OK — doppelt")
    return 0


def run_stub(tool, args):
    if tool == "hdiutil":
        return hdiutil(args)
    if tool == "git":
        return git(args)
    if tool == "fixture-selftest":
        return selftest(args)
    if tool == "fixture-build":
        fill_bundles(Path.cwd())
        if scenario in ("head-changed", "dirty-after-build"):
            Path("dirty").touch()
    elif tool == "swift":
        (Path(".build/artifacts/sparkle") / "Sparkle.framework").mkdir(parents=True, exist_ok=True)
        Path(".build/artifacts/sparkle/LICENSE").touch()
    elif tool == "swiftc":
        target = isolated_path(args[args.index("-o") + 1])
        ScriptFixture.write_executable(target, '#!/bin/sh\nexec fixture-selftest "$0" "$@"\n')
    elif tool == "ditto":
        source, dest = map(isolated_path, args[-2:])
        if args[0] == "-c":
            dest.touch()
        else:
            shutil.copytree(source, dest)
    elif tool == "mktemp":
        if args == ["-d"]:
            print(tempfile.mkdtemp(dir=root / "tmp"))
        else:
            isolated_path(args[-1])
            return subprocess.run(["/usr/bin/mktemp", *args]).returncode
    elif tool == "ln":
        target = isolated_path(args[-1])
        if args[:2] == ["-s", "/Applications"]:
            target.symlink_to(args[1])
        else:
            source = isolated_path(args[0])
            if scenario == "cross-device" and target == root / "mount.lock" and source.parent != target.parent:
                return 1
            if target.suffix == ".sha256" and scenario == "checksum-link-fails":
                return 1
            if target.suffix == ".sha256" and scenario == "signal-before-checksum-link":
                os.kill(os.getppid(), signal.SIGTERM)
                return 1
            if target.suffix == ".dmg" and scenario == "concurrent-artifact":
                target.write_bytes(b"foreign artifact")
            try:
                os.link(source, target)
            except FileExistsError:
                return 1
    elif tool in ("sips", "tiffutil"):
        isolated_path(args[args.index("--out" if tool == "sips" else "-out") + 1]).touch()
    elif tool == "osascript":
        with (root / "finder.applescript").open("w", encoding="utf-8") as output:
            shutil.copyfileobj(sys.stdin, output)
    elif tool in ("codesign", "spctl", "xcrun"):
        path = Path(args[-1])
        verifying_target = path.parent == root / "installed apps"
        verifying_release = str(path).startswith(str(root / "tmp")) and path.suffix == ".app"
        if verifying_target and scenario == "slow-install-output":
            time.sleep(0.05)
        if verifying_target and path.name == APPS[1] and scenario == "install-second-bundle-rejected":
            return 1
        if verifying_release and path.name == APPS[1]:
            if tool == "codesign" and scenario == ("foreign-team" if any(a.startswith("-R=") for a in args) else "bad-signature"):
                return 1
            if tool == "spctl" and scenario == "bad-bundle-gatekeeper":
                return 1
            if tool == "xcrun" and args[:2] == ["stapler", "validate"] and scenario == "bad-bundle-ticket":
                return 1
        if path.suffix == ".dmg":
            if tool == "spctl" and scenario == "bad-dmg-gatekeeper":
                return 1
            if tool == "xcrun" and args[:2] == ["stapler", "validate"] and scenario == "bad-dmg-ticket":
                return 1
    return 0


if __name__ == "__main__":
    root = Path(os.environ["FAVENIO_FIXTURE"])
    scenario = os.environ.get("FIXTURE_SCENARIO", "")
    tool, *args = sys.argv[1:]
    sys.exit(run_stub(tool, args))
