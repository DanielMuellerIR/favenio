#!/usr/bin/env python3
"""Zeilenleser: alte match_content()-Fassung gegen iter_line_pieces().

Aufruf vom Repo: python3 tests/benchmark_line_reader.py --baseline 7fc8691
Zwei Fixtures zu je 64 MiB, deren einziger Treffer ganz am Ende steht (der
Leser muss alles lesen; der billige Inhaltsvortest sagt „nachsehen"):
kurze Zeilen (80 Zeichen, LF) und EINE Zeile ohne Umbruch. Je Fixture zwei
Muster: `--content ENDEMARKE` (reiner Substring, darf Bruchstücke prüfen)
und `--regex ENDE.ARKE` (verankert im Sinn des Lesers: Bruchstücke bleiben
ungeprüft, die lange Zeile wird gemeldet). Gemessen wird ein kompletter Lauf
des jeweiligen favenio.py als Unterprozess: Wanduhrzeit und Spitzenspeicher
(ru_maxrss des Kindes, unter macOS Bytes). Ausgabe: JSONL je Lauf.
"""
import argparse
import json
import os
import resource
import subprocess
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


PATTERNS = {'substring': ['--content', 'ENDEMARKE'],
            'regex': ['--content', '--regex', 'ENDE.ARKE']}


def measure(script, fixture, interpreter, pattern):
    before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    start = time.perf_counter()
    result = subprocess.run([interpreter, str(script)] + PATTERNS[pattern]
                            + [str(fixture)], capture_output=True, text=True)
    seconds = time.perf_counter() - start
    # ru_maxrss der Kinder ist ein Höchststand über ALLE bisherigen Kinder;
    # deshalb läuft jede Messung in einem eigenen Python-Prozess (siehe main).
    after = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    return {'seconds': seconds, 'rss': max(after, before),
            'exit': result.returncode, 'stderr': result.stderr.strip()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True,
                        help='Git-Ref vor dem Herausziehen des Lesers')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--interpreter', default='/usr/bin/python3')
    parser.add_argument('--measure', nargs=4,
                        metavar=('SCRIPT', 'FIXTURE', 'PY', 'PATTERN'),
                        help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.measure:
        print(json.dumps(measure(*args.measure)))
        return
    with tempfile.TemporaryDirectory(prefix='favenio-lines-') as temp:
        temp_path = Path(temp)
        old = temp_path / 'favenio_old.py'
        old.write_text(subprocess.check_output(
            ['git', 'show', args.baseline + ':favenio.py'], cwd=REPO, text=True))
        scripts = {'before': old, 'after': REPO / 'favenio.py'}
        line = ('x' * 79 + '\n').encode()
        short = temp_path / 'short.txt'
        with open(short, 'wb') as handle:
            for _ in range(64 * 1024 * 1024 // len(line)):
                handle.write(line)
            handle.write(b'ENDEMARKE\n')
        long = temp_path / 'long.txt'
        with open(long, 'wb') as handle:
            for _ in range(64):
                handle.write(b'y' * (1024 * 1024))
            handle.write(b'ENDEMARKE')
        for repeat in range(args.repetitions):
            for fixture_name, fixture in (('short', short), ('long', long)):
                for pattern in PATTERNS:
                    for variant, script in scripts.items():
                        output = subprocess.check_output(
                            [args.interpreter, __file__, '--baseline',
                             args.baseline, '--measure', str(script),
                             str(fixture), args.interpreter, pattern],
                            text=True)
                        report = json.loads(output)
                        report.update({'variant': variant, 'pattern': pattern,
                                       'fixture': fixture_name,
                                       'repeat': repeat + 1})
                        print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
