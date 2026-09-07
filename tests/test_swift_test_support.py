"""Auch Kinder mit eigener Prozessgruppe müssen nach einer Probe enden."""
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from swift_test_support import run_process


class ProbeProcessCleanupTests(unittest.TestCase):
    def test_normal_exit_and_timeout_remove_children_in_other_groups(self):
        for wait in (False, True):
            with self.subTest(timeout=wait), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                pid_file = root / 'child.json'
                child = root / 'child.py'
                # Foundation.Process eröffnet eine neue Gruppe, behält aber
                # die Sitzung. Diese Fixture bildet genau diese Grenze nach.
                child.write_text(
                    'import json, os, time\n'
                    'os.setpgid(0, 0)\n'
                    'destination = %r\n'
                    'with open(destination + ".tmp", "w") as stream:\n'
                    '    json.dump([os.getpid(), os.getpgid(0), os.getsid(0)], stream)\n'
                    'os.replace(destination + ".tmp", destination)\n'
                    'time.sleep(30)\n' % str(pid_file))
                parent = root / 'parent.py'
                parent.write_text(
                    'import os, subprocess, sys, time\n'
                    'subprocess.Popen([sys.executable, %r], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n'
                    'while not os.path.exists(%r): time.sleep(0.001)\n'
                    'time.sleep(%d)\n' % (str(child), str(pid_file), 30 if wait else 0))
                pid = None
                try:
                    if wait:
                        with self.assertRaises(subprocess.TimeoutExpired):
                            run_process([sys.executable, str(parent)], timeout=2)
                    else:
                        result = run_process([sys.executable, str(parent)], timeout=5)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    pid, group, session = json.loads(pid_file.read_text())
                    self.assertEqual(pid, group)
                    self.assertNotEqual(group, session)
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.01)
                    else:
                        self.fail('Kind einer beendeten Probe läuft weiter')
                finally:
                    # Auch eine absichtlich beschädigte Aufräumung darf die
                    # Gegenprobe nicht mit einem weiterlaufenden Kind verlassen.
                    if pid is None and pid_file.exists():
                        pid = json.loads(pid_file.read_text())[0]
                    if pid is not None:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
