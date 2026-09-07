"""Gemeinsamer Swift-Build pro Testprozess, getrennte Prozesse je Prüffall."""
import atexit
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_suite_directory = None
_suite_binary = None


def _terminate_session(session_id):
    """Foundation startet Kinder in eigenen Gruppen derselben Sitzung.

    Erst die gefundenen Gruppen anhalten, dann erneut nachsehen: Ein noch
    laufender Compiler oder Kern könnte während der ersten Abfrage ein
    weiteres Kind starten. Nach dem Anhalten darf niemand neu schreiben.
    """
    assert session_id > 1 and session_id != os.getsid(0)
    stopped = set()
    try:
        while True:
            listing = subprocess.check_output(
                ['/bin/ps', '-axo', 'pid=,pgid='], text=True, timeout=2)
            groups = set()
            for line in listing.splitlines():
                pid, group = map(int, line.split())
                try:
                    if os.getsid(pid) == session_id:
                        groups.add(group)
                except ProcessLookupError:
                    pass
            new = groups - stopped
            if not new:
                break
            for group in new:
                try:
                    os.killpg(group, signal.SIGSTOP)
                except ProcessLookupError:
                    pass
                stopped.add(group)
    finally:
        # Die direkte Gruppe kennen wir auch bei einer fehlgeschlagenen
        # Prozessabfrage; Popen.__exit__ darf dann nicht auf sie warten.
        for group in stopped | {session_id}:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass


def run_process(command, *, input=None, timeout=20, environment=None):
    """Begrenzt Build und Proben samt Kindern; liefert auch Fehlerausgaben."""
    with subprocess.Popen(command, cwd=REPO, env=environment, text=True,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, start_new_session=True) as child:
        try:
            stdout, stderr = child.communicate(input, timeout=timeout)
        except subprocess.TimeoutExpired:
            _terminate_session(child.pid)
            stdout, stderr = child.communicate()
            raise subprocess.TimeoutExpired(command, timeout, stdout, stderr)
        finally:
            # Gilt auch für Compilerfehler und KeyboardInterrupt. Bei einem
            # normalen Ende bleiben höchstens verwaiste Kinder übrig.
            _terminate_session(child.pid)
    return subprocess.CompletedProcess(command, child.returncode, stdout, stderr)


def swift_function(source, signature):
    """Schneidet eine Swift-Funktion samt Rumpf aus dem Quelltext: von der
    Signatur bis zur passenden schließenden Klammer. Gezählt werden schlicht
    die geschweiften Klammern — das trägt, solange im Rumpf keine in einem
    Text steht."""
    start = source.index(signature)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("Funktion %r ist nicht abgeschlossen" % signature)


def suite_binary():
    """Keine Wiederverwendung zwischen Python-Prozessen: stets aktueller Code."""
    global _suite_directory, _suite_binary
    if _suite_binary is not None:
        return _suite_binary
    if shutil.which('swiftc') is None:
        raise unittest.SkipTest('swiftc fehlt')
    directory = tempfile.TemporaryDirectory(prefix='favenio-swift-tests-')
    root = Path(directory.name)
    try:
        source = (REPO / 'common/FavenioCore.swift').read_text(encoding='utf-8')
        # Nur der Bundle-Einstieg vor Hit braucht Sparkle. Der gesamte
        # gemeinsame Laufzeitcode geht unverändert in denselben Build.
        core = root / 'Core.swift'
        core.write_text('import AppKit\nimport Darwin\nimport Quartz\n'
                        'import UniformTypeIdentifiers\n'
                        'let pythonPath = "/usr/bin/python3"\n'
                        + source[source.index('struct Hit:'):], encoding='utf-8')
        quick = (REPO / 'quick/FavenioQuick.swift').read_text(encoding='utf-8')
        harness = (REPO / 'tests/quick_scope_probe.swift.in').read_text(encoding='utf-8')
        for marker, signature in (
            ('REFRESH', 'func refreshFinderFoldersAsync() {'),
            ('APPLY', 'func applyScopeOutcome(_ outcome: FinderScopeOutcome) {'),
            ('NOTE', 'func runScopeNoteText() -> String? {'),
        ):
            harness = harness.replace('/* ' + marker + ' */', swift_function(quick, signature))
        scope = root / 'QuickScope.swift'
        scope.write_text(harness, encoding='utf-8')
        binary = root / 'TestProbe'
        probes = ['runner_probe.swift', 'materialization_probe.swift',
                  'configuration_probe.swift', 'export_probe.swift', 'test_probe.swift']
        command = ['swiftc', '-O', '-D', 'FAVENIO_TEST_SUITE', str(core), str(scope)]
        command += [str(REPO / 'tests' / name) for name in probes]
        result = run_process(command + ['-o', str(binary)], timeout=120)
        if result.returncode:
            raise RuntimeError('Swift-Testprogramm kompiliert nicht:\n'
                               + result.stdout + result.stderr)
    except BaseException:
        directory.cleanup()
        raise
    _suite_directory, _suite_binary = directory, binary
    atexit.register(directory.cleanup)
    return binary


def run_probe(family, *arguments, input=None, timeout=20):
    """Fester Kernpfad und eigene Temp-Wurzel, auch bei Aufruf aus /tmp.

    Die Sitzung umfasst auch den Python-Kern. Eine fehlgeschlagene
    Probe darf weder ihn noch seine temporären Dateien liegenlassen.
    """
    binary = suite_binary()
    with tempfile.TemporaryDirectory(prefix='favenio-probe-') as directory:
        environment = dict(os.environ, TMPDIR=directory + os.sep)
        command = [str(binary), family] + [str(value) for value in arguments]
        result = run_process(command, input=input, timeout=timeout, environment=environment)
        if result.returncode:
            raise RuntimeError('Swift-Probe %s endet mit %d:\n%s%s'
                               % (family, result.returncode, result.stdout, result.stderr))
        return result
