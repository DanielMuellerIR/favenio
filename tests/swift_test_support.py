"""Gemeinsamer Swift-Build pro Testprozess, getrennte Prozesse je Prüffall."""
import atexit
import os
import re
import shutil
import signal
import subprocess
import sys
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


def native_document_helper_sources(helper, scratch):
    limits = Path(scratch, "DocumentHelperLimits.swift")
    result = run_process([sys.executable, "-B", str(REPO / "tools/generate-document-limits.py"),
                          str(limits)])
    if result.returncode:
        raise RuntimeError(result.stderr)
    return (limits, REPO / "ocr/DocumentHelperIO.swift", REPO / "ocr/VisionText.swift",
            REPO / helper / "main.swift")


_SWIFT_DELIMITERS = re.compile(r'//[^\n]*|/\*|#*(?:"""|")|[{}()]')
_SWIFT_COMMENT_DELIMITERS = re.compile(r'/\*|\*/')


def _skip_block_comment(source, start):
    depth = 1
    for token in _SWIFT_COMMENT_DELIMITERS.finditer(source, start):
        depth += 1 if token[0] == '/*' else -1
        if depth == 0:
            return token.end()
    raise AssertionError('Offener Swift-Kommentar')


def _skip_string(source, token):
    opening = token[0]
    quotes = opening.lstrip('#')
    hashes = opening[:-len(quotes)]
    closing = quotes + hashes
    events = re.compile(re.escape(closing) + '|' + re.escape('\\' + hashes) + r'(.)', re.DOTALL)
    position = token.end()
    while event := events.search(source, position):
        if event[0] == closing:
            return event.end()
        position = event.end()
        if event[1] == '(':
            position = _swift_delimiter_end(source, position - 1, '(', ')')
    raise AssertionError('Offene Swift-Zeichenkette')


def _swift_delimiter_end(source, start, opening, closing):
    depth = 0
    position = start
    while token := _SWIFT_DELIMITERS.search(source, position):
        position = token.end()
        if token[0] == '/*':
            position = _skip_block_comment(source, position)
        elif token[0].startswith(('"', '#')):
            position = _skip_string(source, token)
        elif token[0] == opening:
            depth += 1
        elif token[0] == closing and depth:
            depth -= 1
            if depth == 0:
                return position
    raise AssertionError(f'Offener Swift-Block ab Offset {start}')


def swift_function(source, signature):
    """Grenze für statische Wächter, die eine konkrete Signatur kennen."""
    start = source.index(signature)
    return source[start:_swift_delimiter_end(source, start, '{', '}')]


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
        binary = root / 'TestProbe'
        probes = ['runner_probe.swift', 'materialization_probe.swift',
                  'configuration_probe.swift', 'thumbnail_probe.swift', 'duplicate_probe.swift', 'export_probe.swift', 'search_report_probe.swift', 'content_preview_probe.swift', 'test_probe.swift']
        command = ['swiftc', '-O', '-D', 'FAVENIO_TEST_SUITE', str(REPO / 'common/FavenioCore.swift'),
                   *[str(REPO / ('common/' + name + '.swift')) for name in ('DuplicateModel', 'ResultFilterModel', 'CriteriaModel', 'SearchModel', 'HitPresentation', 'SearchConfiguration', 'SearchProcess', 'ContentModel', 'ContentPreviewLoad', 'DateRangeModel', 'SearchReportModel')],
                   str(REPO / 'common/ContentPreview.swift'), str(REPO / 'common/Thumbnails.swift'),
                   str(REPO / 'common/SearchReport.swift'), str(REPO / 'common/DuplicateCheck.swift'),
                   str(REPO / 'common/CriteriaEditor.swift'),
                   str(REPO / 'common/DateRanges.swift'), str(REPO / 'common/FinderMetadata.swift'),
                   str(REPO / 'common/FinderScope.swift'),
                   str(REPO / 'gui/CriteriaEditorSelfTest.swift'),
                   str(REPO / 'tests/AppKitSelfTestSupport.swift'), str(REPO / 'tests/result_filter_probe.swift'),
                   str(REPO / 'tests/result_grouping_probe.swift'), str(REPO / 'tests/search_roots_probe.swift'), str(REPO / 'tests/date_ranges_probe.swift'), str(REPO / 'tests/finder_metadata_probe.swift')]
        command += [str(REPO / 'tests' / name) for name in probes]
        result = run_process(command + ['-o', str(binary)], timeout=300)
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
