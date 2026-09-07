#!/usr/bin/env python3
"""Materialisierung großer und verschachtelter Archivtreffer: Main-Thread-
Verzögerung des alten synchronen Wegs gegen den abbrechbaren Auftrag.

Aufruf vom Repo: python3 tests/benchmark_materialization.py --baseline 96e23fa
Ausgabe: JSONL je Lauf. `blocked_seconds` ist die Zeit, die der Aufruf auf
Main blockiert; `max_delay` die größte Verspätung eines 5-ms-Main-Timers.
Fixtures: ein Zip mit einem 128-MiB-Eintrag (gespeichert, nicht komprimiert),
ein Zip im Zip mit einem 64-MiB-Eintrag und — mit bsdtar — ein 7z (LZMA) mit
128 MiB Zufallsdaten. Alle bleiben unter den Standardbudgets des
Kerns (256 MiB je Eintrag, 1 GiB gesamt).
"""
import argparse
import io
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path
from swift_test_support import run_process

REPO = Path(__file__).resolve().parent.parent
HEADER = ('import AppKit\nimport Darwin\nimport Quartz\n'
          'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n')


def build(temp, name, source, asynchronous=False):
    core = Path(temp) / (name + '.swift')
    # Foundation ignoriert TMPDIR auf manchen macOS-Versionen. Nur die
    # Temp-Wurzel im Messbuild ersetzen, bei alter und neuer Quelle gleich.
    source = source.replace('FileManager.default.temporaryDirectory',
                            'URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!, isDirectory: true)')
    core.write_text(HEADER + source[source.index('struct Hit:'):])
    binary = Path(temp) / name
    command = ['swiftc', '-O', str(core), str(REPO / 'tests/materialization_benchmark.swift'),
               '-o', str(binary)]
    if asynchronous:
        command += ['-D', 'ASYNC']
    run_process(command, timeout=120).check_returncode()
    return binary


def make_fixtures(root):
    payload = os.urandom(1024 * 1024)
    big = root / 'big.zip'
    with zipfile.ZipFile(big, 'w', zipfile.ZIP_STORED) as archive:
        with archive.open('big.bin', 'w') as member:
            for _ in range(128):
                member.write(payload)
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, 'w', zipfile.ZIP_STORED) as archive:
        with archive.open('inner.bin', 'w') as member:
            for _ in range(64):
                member.write(payload)
    nested = root / 'outer.zip'
    with zipfile.ZipFile(nested, 'w', zipfile.ZIP_STORED) as archive:
        archive.writestr('inner.zip', inner.getvalue())
    def repeated_hash(count):
        digest = hashlib.sha256()
        for _ in range(count):
            digest.update(payload)
        return digest.hexdigest()
    fixtures = {'big': ([str(big), 'big.bin'], 128 * len(payload), repeated_hash(128)),
                'nested': ([str(nested), 'inner.zip', 'inner.bin'], 64 * len(payload), repeated_hash(64))}
    # Ein 7z (LZMA) mit 128 MiB Zufallsdaten: Hier arbeitet der Entpacker
    # wirklich, statt nur Bytes zu kopieren — sich wiederholende Daten
    # dekodiert LZMA fast so schnell wie ein gespeichertes Zip (gemessen
    # 2026-09-05: 0,17 s gegen 4,5 s bei Zufallsdaten).
    bsdtar = shutil.which('bsdtar')
    if bsdtar:
        staging = root / 'staging'
        staging.mkdir()
        digest = hashlib.sha256()
        with open(staging / 'big7z.bin', 'wb') as handle:
            for _ in range(128):
                chunk = os.urandom(1024 * 1024)
                handle.write(chunk)
                digest.update(chunk)
        run_process([bsdtar, '-cf', str(root / 'big.7z'), '--format', '7zip',
                        '-C', str(staging), 'big7z.bin'], timeout=180).check_returncode()
        fixtures['big7z'] = ([str(root / 'big.7z'), 'big7z.bin'], 128 * len(payload), digest.hexdigest())
    return fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True,
                        help='Git-Ref vor dem asynchronen Umbau')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--skip-async', action='store_true',
                        help='nur den synchronen Weg messen (alter Stand)')
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions muss positiv sein")
    with tempfile.TemporaryDirectory(prefix='favenio-mat-') as temp:
        temp_path = Path(temp)
        fixtures = make_fixtures(temp_path)
        before = subprocess.check_output(
            ['git', 'show', args.baseline + ':common/FavenioCore.swift'],
            cwd=REPO, text=True, timeout=30)
        after = (REPO / 'common/FavenioCore.swift').read_text()
        runs = [('before', build(temp, 'before', before)),
                ('after-sync', build(temp, 'after_sync', after))]
        if not args.skip_async:
            runs.append(('after-async', build(temp, 'after_async', after, asynchronous=True)))
        for repeat in range(args.repetitions):
            for fixture, (arguments, size, digest) in fixtures.items():
                order = runs if repeat % 2 == 0 else list(reversed(runs))
                for variant, binary in order:
                    with tempfile.TemporaryDirectory(prefix='extraction-', dir=temp) as extraction:
                        environment = dict(os.environ, TMPDIR=extraction + os.sep)
                        output = run_process([str(binary)] + arguments,
                                             environment=environment, timeout=120)
                        output.check_returncode()
                        report = json.loads(output.stdout)
                        if not report['ok'] or report['bytes'] != size or report['sha256'] != digest:
                            raise RuntimeError('Extrahierter Inhalt stimmt nicht: ' + repr(report))
                    report.update({'variant': variant, 'fixture': fixture,
                                   'repeat': repeat + 1, 'verified': True})
                    print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
