"""Export mit echten Dateien und Main-RunLoop, ohne Sichern-Dialog."""
import shutil
import unittest
from swift_test_support import run_probe


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class ExportWriterTests(unittest.TestCase):
    def test_formats_snapshot_failure_retry_and_responsiveness(self):
        result = run_probe('export')
        self.assertIn('EXPORT OK', result.stdout)
