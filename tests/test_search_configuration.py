"""CLI-/URL-Roundtrips und echte Filter-Controls ohne angezeigtes Fenster."""
import shutil
import subprocess
import tempfile
import unittest
from test_search_runner import build_probe, REPO


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class SearchConfigurationTests(unittest.TestCase):
    def test_roundtrip_preserves_filters_and_rejects_invalid_pixels(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = build_probe(directory, 'configuration_probe.swift')
            result = subprocess.run([str(binary)], cwd=REPO, check=True,
                                    text=True, capture_output=True, timeout=20)
            self.assertIn('CONFIGURATION OK', result.stdout)
