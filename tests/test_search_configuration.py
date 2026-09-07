"""CLI-/URL-Roundtrips und echte Filter-Controls ohne angezeigtes Fenster."""
import shutil
import unittest
from swift_test_support import run_probe


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class SearchConfigurationTests(unittest.TestCase):
    def test_roundtrip_preserves_filters_and_rejects_invalid_pixels(self):
        result = run_probe('configuration')
        self.assertIn('CONFIGURATION OK', result.stdout)
