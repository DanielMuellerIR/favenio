#!/usr/bin/env python3
"""100k Exporte vor/nach Worker-Umbau; unveränderter Serializer, echte Dateien.

python3 tests/benchmark_export.py --baseline 5c2243d --repetitions 3
Ausgabe JSONL: Sekunden, macOS-Spitzenspeicher in Bytes, Main-Verzögerung.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True)
parser.add_argument('--repetitions', type=int, default=3)
args = parser.parse_args()
header = ('import AppKit\nimport Darwin\nimport Quartz\n'
          'import UniformTypeIdentifiers\nlet pythonPath = "/usr/bin/python3"\n')
with tempfile.TemporaryDirectory() as temp:
    builds = {}
    for variant in ('before', 'after'):
        if variant == 'before':
            source = subprocess.check_output(
                ['git', 'show', args.baseline + ':common/FavenioCore.swift'], cwd=REPO, text=True)
        else:
            source = (REPO / 'common/FavenioCore.swift').read_text()
        core = Path(temp) / (variant + '.swift')
        core.write_text(header + source[source.index('struct Hit:'):])
        binary = Path(temp) / variant
        command = ['swiftc', '-O', str(core), str(REPO / 'tests/export_benchmark.swift'), '-o', str(binary)]
        if variant == 'after':
            command += ['-D', 'AFTER']
        subprocess.run(command, check=True, capture_output=True)
        builds[variant] = binary
    for repeat in range(args.repetitions):
        for format_name in ('paths', 'pathsNUL', 'jsonl', 'csv'):
            for variant in ('before', 'after'):
                output = subprocess.check_output([str(builds[variant]), format_name], text=True, timeout=130)
                report = json.loads(output)
                report.update(variant=variant, repeat=repeat + 1)
                print(json.dumps(report), flush=True)
