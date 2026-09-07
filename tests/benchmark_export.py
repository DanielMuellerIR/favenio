#!/usr/bin/env python3
"""100k Exporte mit vollständigem Ausgabeabgleich zwischen zwei Codeversionen.

python3 tests/benchmark_export.py --baseline 5c2243d --repetitions 3
Ausgabe JSONL: Sekunden, macOS-Spitzenspeicher in Bytes, Main-Verzögerung.
"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path
from swift_test_support import run_process

REPO = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True)
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
                ['git', 'show', args.baseline + ':common/FavenioCore.swift'], cwd=REPO, text=True, timeout=30)
        else:
            source = (REPO / 'common/FavenioCore.swift').read_text()
        core = Path(temp) / (variant + '.swift')
        core.write_text(header + source[source.index('struct Hit:'):])
        binary = Path(temp) / variant
        command = ['swiftc', '-O', str(core), str(REPO / 'tests/export_benchmark.swift'), '-o', str(binary)]
        if 'final class ExportWriter' in source:
            command += ['-D', 'AFTER']
        run_process(command, timeout=120).check_returncode()
        builds[variant] = binary
    for repeat in range(args.repetitions):
        for format_name in ('paths', 'pathsNUL', 'jsonl', 'csv'):
            reports, outputs = {}, {}
            order = ('before', 'after') if repeat % 2 == 0 else ('after', 'before')
            for variant in order:
                destination = Path(temp) / (variant + '.export')
                result = run_process(
                    [str(builds[variant]), format_name, str(destination)], timeout=130)
                result.check_returncode()
                output = result.stdout
                report = json.loads(output)
                data = destination.read_bytes()
                if report['hits'] != 100000 or report['bytes'] != len(data) or not data:
                    raise RuntimeError('Unvollständiger Export: ' + variant)
                if format_name == 'jsonl':
                    records = [json.loads(line) for line in data.splitlines()]
                    expected = [dict(path=f'/fixture/folder/file-{i}.txt', type='file',
                                     isDirectory=False, size=1000,
                                     filesystemPath=f'/fixture/folder/file-{i}.txt',
                                     archiveMembers=[], modified=1725500000,
                                     created=1725400000) for i in range(100000)]
                    if records != expected:
                        raise RuntimeError('JSONL-Treffer weichen von Eingabe ab: ' + variant)
                    outputs[variant] = records
                else:
                    outputs[variant] = data
                reports[variant] = dict(report, variant=variant, repeat=repeat + 1)
                destination.unlink()
            if outputs['before'] != outputs['after']:
                raise RuntimeError('Exportvarianten unterscheiden sich: ' + format_name)
            # Erst geprüfte Messpaare veröffentlichen; Prüfung liegt außerhalb
            # der Swift-Zeitmessung und des gemeldeten Prozess-Spitzenspeichers.
            for variant in order:
                print(json.dumps(dict(reports[variant], equivalent=True)), flush=True)
