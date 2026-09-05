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

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, help='Git-Ref vor dem Runner-Umbau')
parser.add_argument('--repetitions', type=int, default=3)
args = parser.parse_args()
header = ('import AppKit\nimport Darwin\nimport Quartz\n'
          'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n')
with tempfile.TemporaryDirectory() as temp:
    builds = {}
    for variant in ('before', 'after'):
        if variant == 'before':
            source = subprocess.check_output(
                ['git', 'show', args.baseline + ':common/FavenioCore.swift'],
                cwd=REPO, text=True)
        else:
            source = (REPO / 'common/FavenioCore.swift').read_text()
        core = Path(temp) / (variant + '.swift')
        core.write_text(header + source[source.index('struct Hit:'):])
        binary = Path(temp) / variant
        subprocess.run(['swiftc', '-O', str(core),
                        str(REPO / 'tests/runner_benchmark.swift'), '-o', str(binary)],
                       check=True, capture_output=True)
        builds[variant] = binary
    for repeat in range(args.repetitions):
        for variant, mode in [('before', 'gui'), ('before', 'quick'), ('after', 'quick')]:
            output = subprocess.check_output([str(builds[variant]), mode], text=True)
            values = dict(field.split('=', 1) for field in output.strip().split())
            report = {'variant': variant, 'mode': mode if variant == 'before' else 'shared',
                      'repeat': repeat + 1}
            report.update({key: float(values[key]) for key in ('seconds', 'rss', 'max_delay')})
            report['hits'] = int(values['hits'])
            print(json.dumps(report), flush=True)
