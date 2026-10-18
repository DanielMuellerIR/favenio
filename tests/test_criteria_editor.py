"""Native Kriterienansicht und ihr tatsächlicher Anschluss an den Python-Kern."""
import shutil
import unittest

from swift_test_support import run_probe


@unittest.skipUnless(shutil.which('swiftc'), 'swiftc fehlt')
class CriteriaEditorTests(unittest.TestCase):
    def test_editor_preserves_groups_ids_drafts_and_search_evidence(self):
        result = run_probe('criteria-editor', timeout=60)
        self.assertIn('CRITERIA EDITOR OK:', result.stdout)
