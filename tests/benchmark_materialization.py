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
import json
import os
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HEADER = ('import AppKit\nimport Darwin\nimport Quartz\n'
          'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n')


def build(temp, name, source, probe):
    core = Path(temp) / (name + '.swift')
    core.write_text(HEADER + source[source.index('struct Hit:'):])
    binary = Path(temp) / name
    subprocess.run(['swiftc', '-O', str(core), str(REPO / 'tests' / probe),
                    '-o', str(binary)], check=True, capture_output=True)
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
    fixtures = {'big': [str(big), 'big.bin'],
                'nested': [str(nested), 'inner.zip', 'inner.bin']}
    # Ein 7z (LZMA) mit 128 MiB Zufallsdaten: Hier arbeitet der Entpacker
    # wirklich, statt nur Bytes zu kopieren — sich wiederholende Daten
    # dekodiert LZMA fast so schnell wie ein gespeichertes Zip (gemessen
    # 2026-09-05: 0,17 s gegen 4,5 s bei Zufallsdaten).
    bsdtar = shutil.which('bsdtar')
    if bsdtar:
        staging = root / 'staging'
        staging.mkdir()
        with open(staging / 'big7z.bin', 'wb') as handle:
            for _ in range(128):
                handle.write(os.urandom(1024 * 1024))
        subprocess.run([bsdtar, '-cf', str(root / 'big.7z'), '--format', '7zip',
                        '-C', str(staging), 'big7z.bin'], check=True)
        fixtures['big7z'] = [str(root / 'big.7z'), 'big7z.bin']
    return fixtures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True,
                        help='Git-Ref vor dem asynchronen Umbau')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--skip-async', action='store_true',
                        help='nur den synchronen Weg messen (alter Stand)')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='favenio-mat-') as temp:
        temp_path = Path(temp)
        fixtures = make_fixtures(temp_path)
        before = subprocess.check_output(
            ['git', 'show', args.baseline + ':common/FavenioCore.swift'],
            cwd=REPO, text=True)
        after = (REPO / 'common/FavenioCore.swift').read_text()
        runs = [('before', build(temp, 'before', before,
                                 'materialization_benchmark.swift')),
                ('after-sync', build(temp, 'after_sync', after,
                                     'materialization_benchmark.swift'))]
        if not args.skip_async:
            runs.append(('after-async', build(temp, 'after_async', after,
                                              'materialization_probe.swift')))
        for repeat in range(args.repetitions):
            for fixture, arguments in fixtures.items():
                for variant, binary in runs:
                    command = [str(binary)]
                    if variant == 'after-async':
                        command.append('benchmark')
                    output = subprocess.check_output(command + arguments,
                                                     text=True, timeout=120)
                    report = json.loads(output)
                    report.update({'variant': variant, 'fixture': fixture,
                                   'repeat': repeat + 1})
                    print(json.dumps(report, sort_keys=True), flush=True)


if __name__ == '__main__':
    main()
