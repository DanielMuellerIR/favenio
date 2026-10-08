#!/usr/bin/env python3
"""Begrenzte Diagnose des echten SIGTERM-Rollbacktests mit Lastbelegen."""
import argparse
from datetime import datetime, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parent.parent


def measure(module, phase, count):
    records = []
    for index in range(count):
        evidence = dict(phase=phase, iteration=index + 1, startedAt=datetime.now(timezone.utc).isoformat(),
                        loadBefore=list(os.getloadavg()))
        real_popen = subprocess.Popen
        def start_child(*args, **kwargs):
            child = real_popen(*args, **kwargs)
            environment = kwargs.get('env', {})
            if 'FAVENIO_TEST_READY' in environment:
                original_send = child.send_signal
                def send(signum):
                    ready = Path(environment['FAVENIO_TEST_READY'])
                    evidence.update(readyExists=ready.is_file(),
                                    readyText=ready.read_text() if ready.is_file() else None,
                                    processStatusBeforeSignal=child.poll(), signal=int(signum),
                                    loadAtSignal=list(os.getloadavg()))
                    return original_send(signum)
                child.send_signal = send
                original_communicate = child.communicate
                def communicate(*args, **kwargs):
                    try:
                        result = original_communicate(*args, **kwargs)
                    except subprocess.TimeoutExpired:
                        evidence['communicateTimeout'] = True
                        raise
                    evidence.update(exitCode=child.returncode, output=result[0].decode('utf8', 'replace') if result[0] else '')
                    return result
                child.communicate = communicate
            return child
        started = time.monotonic()
        log = io.StringIO()
        case = module.InstallTransactionTest('test_sigterm_during_the_swap_restores_both_bundles')
        with patch.object(module.subprocess, 'Popen', start_child):
            result = unittest.TextTestRunner(stream=log, verbosity=2).run(case)
        evidence.update(elapsedSeconds=time.monotonic() - started, passed=result.wasSuccessful(),
                        unittestOutput=log.getvalue(), loadAfter=list(os.getloadavg()))
        records.append(evidence)
        if not result.wasSuccessful():
            break
    return records


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=20)
    parser.add_argument('--workers', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 50 or not 0 <= args.workers <= 4:
        parser.error('1–50 Wiederholungen; höchstens vier begrenzte Lastprozesse')
    spec = importlib.util.spec_from_file_location('test_build_safety', REPO / 'tests/test_build_safety.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    records = measure(module, 'ambient', args.repetitions)
    workers = []
    try:
        for _ in range(args.workers):
            workers.append(subprocess.Popen([sys.executable, '-c',
                'import time\nend=time.monotonic()+30\nwhile time.monotonic()<end: sum(range(10000))'],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        if all(record['passed'] for record in records):
            records += measure(module, 'four-bounded-cpu-workers' if args.workers == 4 else 'bounded-cpu-workers', args.repetitions)
    finally:
        for worker in workers:
            if worker.poll() is None:
                worker.terminate()
            try:
                worker.wait(timeout=2)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()
    report = dict(schemaVersion=1, measuredAt=datetime.now(timezone.utc).isoformat(),
                  sourceCommit=subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip(),
                  python=sys.version, cpuCount=os.cpu_count(), workerCount=args.workers,
                  maximumWorkerSeconds=30, samples=records)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'{sum(record["passed"] for record in records)}/{len(records)} SIGTERM-Tests bestanden; {args.output}')
    return 0 if all(record['passed'] for record in records) else 1


if __name__ == '__main__':
    sys.exit(main())
