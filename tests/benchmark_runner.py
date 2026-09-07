#!/usr/bin/env python3
"""100k identische JSONL-Treffer: alte GUI/Quick-Wege gegen gemeinsamen Runner.

Aufruf vom Repo: python3 tests/benchmark_runner.py --baseline e04db96
Ausgabe: JSONL; Sekunden, ru_maxrss in Bytes (macOS), Main-Timer-Verspätung.
Gemessen werden Transport und Trefferhaltung, keine Tabellen-/Sortierkosten.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path
from swift_test_support import run_process

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, help='Git-Ref vor dem Runner-Umbau')
parser.add_argument('--repetitions', type=int, default=3)
args = parser.parse_args()
if args.repetitions < 1:
    parser.error("--repetitions muss positiv sein")
header = ('import AppKit\nimport Darwin\nimport Quartz\n'
          'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n')
with tempfile.TemporaryDirectory() as temp:
    builds = {}
    for variant in ('before', 'after'):
        if variant == 'before':
            source = subprocess.check_output(
                ['git', 'show', args.baseline + ':common/FavenioCore.swift'],
                cwd=REPO, text=True, timeout=30)
        else:
            source = (REPO / 'common/FavenioCore.swift').read_text()
        core = Path(temp) / (variant + '.swift')
        core.write_text(header + source[source.index('struct Hit:'):])
        binary = Path(temp) / variant
        run_process(['swiftc', '-O', str(core),
                        str(REPO / 'tests/runner_benchmark.swift'), '-o', str(binary)],
                       timeout=120).check_returncode()
        builds[variant] = binary
    for repeat in range(args.repetitions):
        runs = [('before', 'gui'), ('before', 'quick'), ('after', 'quick')]
        for variant, mode in (runs if repeat % 2 == 0 else reversed(runs)):
            result = run_process([str(builds[variant]), mode], timeout=65)
            result.check_returncode()
            output = result.stdout
            values = dict(field.split('=', 1) for field in output.strip().split())
            report = {'variant': variant, 'mode': mode if variant == 'before' else 'shared',
                      'repeat': repeat + 1}
            report.update({key: float(values[key]) for key in ('seconds', 'rss', 'max_delay')})
            report['hits'] = int(values['hits'])
            print(json.dumps(report), flush=True)
