import unittest
from pathlib import Path


COMMON = Path("common/FavenioCore.swift").read_text(encoding="utf-8")
GUI = Path("gui/FavenioGUI.swift").read_text(encoding="utf-8")
QUICK = Path("quick/FavenioQuick.swift").read_text(encoding="utf-8")


class SwiftGuardTests(unittest.TestCase):
    def test_gui_search_callbacks_are_bound_to_active_run(self):
        self.assertIn("final class ActiveSearchRun", GUI)
        self.assertGreaterEqual(GUI.count("self.activeSearchRun === run"), 3)
        self.assertIn("var lineBuffer = Data()", GUI)
        self.assertNotIn("var searchProcess: Process?", GUI)

    def test_descending_comparator_is_strict(self):
        self.assertIn("func compareHits", GUI)
        self.assertNotIn("return ascending ? result : !result", GUI)
        self.assertIn("return false", GUI)

    def test_structured_hits_and_materialization_cache_are_used(self):
        self.assertIn("let filesystemPath: String", COMMON)
        self.assertIn("let archiveMembers: [String]", COMMON)
        self.assertIn("private var cache: [Hit: URL]", COMMON)
        self.assertIn('"Favenio-\\(UUID().uuidString)"', COMMON)
        self.assertNotIn('"Favenio-(UUID().uuidString)"', COMMON)
        self.assertIn("func cleanupMaterializedHits()", COMMON)
        self.assertNotIn('path.contains("!/")', COMMON)

    def test_handoff_is_atomic_bounded_streamed_and_consumed(self):
        self.assertIn("options: .atomic", COMMON)
        self.assertIn("maximumHandoffBytes", COMMON)
        self.assertIn("read(upToCount: 64 * 1024)", COMMON)
        self.assertIn("removeItem(at: url)", COMMON)
        self.assertNotIn("Data(contentsOf:", GUI)
        self.assertIn('components.scheme?.lowercased() == "favenio"', GUI)
        self.assertIn('components.host?.lowercased() == "results"', GUI)
        handler = GUI[
            GUI.index("func handleFavenioURL"):
            GUI.index("func loadResults")
        ]
        self.assertLess(
            handler.index("validatedQuickHandoff(URL(fileURLWithPath: filePath))"),
            handler.index("searchField.stringValue = query"),
        )
        self.assertIn("let resultsFile: URL", QUICK)
        self.assertIn("try writeQuickHandoff(hits)", QUICK)

    def test_quick_drops_old_hits_before_waiting_for_the_finder(self):
        # Wartet die Schnellsuche auf den Finder-Ordner, kehrt startSearch()
        # früh zurück. Die Treffer der VORIGEN Suche müssen davor weg sein —
        # sonst übergibt ⌘↩ der Haupt-App alte Treffer unter neuem Suchtext.
        start = QUICK[
            QUICK.index("func startSearch()"):
            QUICK.index("func showProgress")
        ]
        self.assertLess(
            start.index("hits = []"),
            start.index("scopePopup.selectedItem?.representedObject"),
        )
        self.assertLess(
            start.index("openButton.isEnabled = false"),
            start.index("scopePopup.selectedItem?.representedObject"),
        )

    def test_quick_keeps_the_scope_warning_while_hits_arrive(self):
        # Eine Warnung zum Suchbereich darf nicht vom Trefferzähler
        # überschrieben werden — beim Top-20-Stopp käme sie sonst nie wieder.
        flush = QUICK[
            QUICK.index("func flushPending()"):
            QUICK.index("func finish(")
        ]
        self.assertIn('showScopeProblem(summary + " " + problem)', flush)

    def test_quick_keeps_the_late_finder_note_for_the_running_search(self):
        # Meldet sich der Finder erst, während die Suche schon im
        # Ersatzordner läuft, ist scopeProblem nil — der Hinweis „Suche läuft
        # in X, Finder-Ordner ist Y" hing deshalb nur bis zum ersten
        # Trefferpaket in der Info-Zeile. Er wird jetzt in runScopeNote
        # gemerkt und an allen drei Stellen mitgelesen.
        self.assertIn("var runScopeNote: String?", QUICK)
        apply = QUICK[
            QUICK.index("func applyScopeOutcome("):
            QUICK.index("func scopeWaitExpired()")
        ]
        self.assertIn("runScopeNote = note", apply)
        for name, following in (("func startSearch()", "func showProgress"),
                                ("func flushPending()", "func finish("),
                                ("func finish(", "func openInMainApp")):
            body = QUICK[QUICK.index(name):QUICK.index(following)]
            self.assertIn("runScopeNote", body, name)
        progress = QUICK[
            QUICK.index("func showProgress"):
            QUICK.index("func flushPending()")
        ]
        self.assertIn("(scopeProblem ?? runScopeNote) == nil", progress)

    def test_streaming_core_does_not_collect_duplicate_results(self):
        self.assertNotIn("var hitsRaw", COMMON)
        self.assertNotIn("var hits: [Hit] = []\n    var hitsRaw", COMMON)
        self.assertIn("-> Int32", COMMON)


if __name__ == "__main__":
    unittest.main()
