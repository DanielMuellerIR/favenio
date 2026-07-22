import unittest
from pathlib import Path


class BuildSafetyTest(unittest.TestCase):
    def test_normal_build_never_mutates_applications(self):
        source = Path("build-app.sh").read_text(encoding="utf-8")
        forbidden = (
            "rm -rf /Applications",
            "ditto Favenio.app /Applications",
            "ditto FavenioQuick.app /Applications",
            "pkill -x Favenio",
        )
        for command in forbidden:
            self.assertNotIn(command, source)

    def test_release_checks_staple_and_gatekeeper_without_installing(self):
        source = Path("release.sh").read_text(encoding="utf-8")
        self.assertIn('xcrun stapler validate "$DMG_PATH"', source)
        self.assertIn('spctl --assess --type open', source)
        self.assertNotIn(" /Applications/Favenio.app", source)
        self.assertNotIn(" /Applications/FavenioQuick.app", source)


if __name__ == "__main__":
    unittest.main()
