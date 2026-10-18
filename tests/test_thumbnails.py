"""Grid und Tabelle teilen Identität/Aktionen; Miniaturen bleiben lokal und begrenzt."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from swift_test_support import run_probe


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'AppKit braucht macOS/Swift')
class ThumbnailTests(unittest.TestCase):
    def test_grid_cache_generation_materialization_and_cancellation(self):
        with tempfile.TemporaryDirectory(prefix='favenio-thumbnail-tests-') as directory:
            result = run_probe('thumbnails', directory, str(Path(__file__).resolve().parents[1]), timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            proof = json.loads(result.stdout)
            self.assertTrue(proof['passed'])
            self.assertEqual(proof['gridItems'], 1000)
            self.assertEqual(proof['invisibleReads'], 0)
            self.assertLessEqual(proof['cacheState']['cacheCount'], 64)
            self.assertLessEqual(proof['cacheState']['cacheBytes'], 16 * 1024 * 1024)
            self.assertTrue(proof['filePromiseBytes'])
            self.assertTrue(proof['cancelledChildReaped'])
