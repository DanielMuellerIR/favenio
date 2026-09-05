"""Export mit echten Dateien und Main-RunLoop, ohne Sichern-Dialog."""
import shutil
import subprocess
import tempfile
import unittest
from test_search_runner import build_probe, REPO


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class ExportWriterTests(unittest.TestCase):
    def test_formats_snapshot_failure_retry_and_responsiveness(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = build_probe(directory, 'export_probe.swift')
            result = subprocess.run([str(binary)], cwd=REPO, check=True,
                                    text=True, capture_output=True, timeout=20)
            self.assertIn('EXPORT OK', result.stdout)
