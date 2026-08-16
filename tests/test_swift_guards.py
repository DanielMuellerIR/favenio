import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


COMMON = Path("common/FavenioCore.swift").read_text(encoding="utf-8")
GUI = Path("gui/FavenioGUI.swift").read_text(encoding="utf-8")
QUICK = Path("quick/FavenioQuick.swift").read_text(encoding="utf-8")


def swift_function(source, signature):
    """Schneidet eine Swift-Funktion samt Rumpf aus dem Quelltext: von der
    Signatur bis zur passenden schließenden Klammer. Gezählt werden schlicht
    die geschweiften Klammern — das trägt, solange im Rumpf keine in einem
    Text steht."""
    start = source.index(signature)
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError("Funktion %r ist nicht abgeschlossen" % signature)


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

    def test_quick_fallback_reuses_the_structured_handoff_url(self):
        # Schlägt die LaunchServices-Zuordnung des URL-Schemas fehl, darf der
        # direkte App-Start nicht nur Suchtext und Trefferdatei übergeben. Der
        # identische URL-Datensatz enthält auch Wurzel und Suchoptionen.
        fallback = QUICK[
            QUICK.index("func openMainApp("):
            QUICK.index("func locateMainApp()")
        ]
        self.assertIn("guard let handoffURL = components.url", fallback)
        self.assertIn(
            'configuration.arguments = ["--handoff-url", '
            "handoffURL.absoluteString]", fallback)
        self.assertIn("configuration.createsNewApplicationInstance = true",
                      fallback)
        self.assertNotIn('configuration.arguments = ["--query"', fallback)

        startup = GUI[
            GUI.index("func applicationDidFinishLaunching"):
            GUI.index("func applicationDidBecomeActive")
        ]
        self.assertIn('arguments.firstIndex(of: "--handoff-url")', startup)
        self.assertIn("handleFavenioURL(handoffURL)", startup)

    def test_quick_drops_stale_finder_folders_before_refresh(self):
        # Ein Timeout oder eine verweigerte Abfrage darf nicht den Finder-
        # Ordner der VORIGEN Aktivierung als aktuellen Bereich stehen lassen.
        became_active = QUICK[
            QUICK.index("func applicationDidBecomeActive"):
            QUICK.index("func windowWillClose")
        ]
        self.assertLess(
            became_active.index("scopeFinderFolders = []"),
            became_active.index("refreshFinderFoldersAsync()"),
        )
        apply = QUICK[
            QUICK.index("func applyScopeOutcome("):
            QUICK.index("func scopeWaitExpired()")
        ]
        self.assertIn("scopeFinderFolders = outcome.folders", apply)

    def test_quick_restarts_finder_refresh_for_the_latest_activation(self):
        # Läuft beim erneuten Aktivieren noch die Finder-Abfrage der vorigen
        # Aktivierung, muss deren Antwort verworfen und danach eine aktuelle
        # Abfrage gestartet werden.
        became_active = QUICK[
            QUICK.index("func applicationDidBecomeActive"):
            QUICK.index("func windowWillClose")
        ]
        self.assertIn("scopeRefreshGeneration += 1", became_active)
        refresh = swift_function(QUICK, "func refreshFinderFoldersAsync()")
        self.assertIn("queuedScopeRefreshGeneration", refresh)
        self.assertIn("generation == self.scopeRefreshGeneration", refresh)
        self.assertGreaterEqual(refresh.count("refreshFinderFoldersAsync()"), 2)

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
        # Trefferpaket in der Info-Zeile. Er wird jetzt gemerkt und an allen
        # drei Stellen mitgelesen.
        apply = QUICK[
            QUICK.index("func applyScopeOutcome("):
            QUICK.index("func scopeWaitExpired()")
        ]
        self.assertIn(
            "runScopeMismatch = (searched: searchRoot, finder: front)", apply)
        for name, following, expected in (
                ("func startSearch()", "func showProgress",
                 "runScopeMismatch = nil"),
                ("func flushPending()", "func finish(", "runScopeNoteText()"),
                ("func finish(", "func openInMainApp", "runScopeNoteText()")):
            body = QUICK[QUICK.index(name):QUICK.index(following)]
            self.assertIn(expected, body, name)
        progress = QUICK[
            QUICK.index("func showProgress"):
            QUICK.index("func flushPending()")
        ]
        self.assertIn("(scopeProblem ?? runScopeNoteText()) == nil", progress)

    def test_quick_builds_the_scope_note_from_the_current_state(self):
        # Der Hinweis war ein fertig formulierter Präsens-Satz im Zustand.
        # finish() und der Top-20-Stopp rufen aber zuerst cancelSearch() und
        # zeigen die Zeile DANACH — die fertige Suche behauptete dort weiter
        # „Suche läuft in …". Und „Return sucht dort" stimmte nicht mehr,
        # sobald der Nutzer den Bereich selbst gewählt hatte. Gespeichert
        # werden deshalb nur die Pfade, formuliert wird aus dem Zustand.
        self.assertNotIn("var runScopeNote: String?", QUICK)
        self.assertIn(
            "var runScopeMismatch: (searched: String, finder: String)?", QUICK)
        note = QUICK[
            QUICK.index("func runScopeNoteText()"):
            QUICK.index("func showScopeProblem")
        ]
        self.assertIn(
            'searching ? "Suche läuft in " : "Gesucht wurde in "', note)
        self.assertIn("!userPickedScope", note)

    def test_streaming_core_does_not_collect_duplicate_results(self):
        self.assertNotIn("var hitsRaw", COMMON)
        self.assertNotIn("var hits: [Hit] = []\n    var hitsRaw", COMMON)
        self.assertIn("-> SearchExit", COMMON)

    def test_frontends_reject_every_unexpected_search_exit(self):
        # grep-Semantik: Nur reguläre Exits 0 (Treffer) und 1 (keine Treffer)
        # sind normal. Ein Signal kann ebenfalls Status 1 tragen; deshalb muss
        # der Foundation-Abbruchgrund bis in beide Frontends gelangen.
        self.assertIn("let reason: Process.TerminationReason", COMMON)
        self.assertIn("process.terminationReason", COMMON)
        self.assertIn("var terminationReason: Process.TerminationReason?", GUI)
        self.assertIn("run.terminationReason = process.terminationReason", GUI)
        self.assertIn("searchExitIsError(status, reason: reason)", GUI)
        self.assertIn("searchExitIsError(searchExit.status", QUICK)
        self.assertIn("reason: searchExit.reason", QUICK)
        self.assertIn(".uncaughtSignal", GUI)

    def test_open_finder_consent_is_never_timed_out(self):
        # Ein noch offener TCC-Dialog gehört dem Nutzer. Ein künstlicher
        # Timeout würde den osascript-Prozess und damit die wartende Freigabe
        # verwerfen; der Notaus gilt nur bei bereits entschiedenem Zugriff.
        finder = COMMON[
            COMMON.index("func finderWindowFoldersAsync("):
            COMMON.index("func runFinderScopeDiagnostic()")
        ]
        self.assertNotIn("consentPending ? 180", finder)
        self.assertIn("if !consentPending {", finder)
        self.assertIn("deadline: .now() + 6", finder)
        self.assertIn("killer = nil", finder)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc nicht verfügbar")
class QuickScopeRefreshBehaviourTest(unittest.TestCase):
    """Führt die echten Refresh- und Apply-Funktionen in einer kleinen
    Attrappe aus. So lassen sich überlappende Finder-Antworten und verweigerte
    Automation deterministisch prüfen, ohne die TCC-Einstellungen des Macs zu
    verändern."""

    HARNESS = r'''
// Von tests/test_swift_guards.py erzeugt — kein Bestandteil der Apps.
enum FinderScopeOutcome {
    case folders([String])
    case denied

    var folders: [String] {
        if case .folders(let value) = self { return value }
        return []
    }
    var problemText: String? {
        if case .denied = self { return "Finder-Zugriff nicht erlaubt" }
        return nil
    }
}

var finderCallbacks: [(FinderScopeOutcome) -> Void] = []
func finderWindowFoldersAsync(
    completion: @escaping (FinderScopeOutcome) -> Void
) {
    finderCallbacks.append(completion)
}

final class TimerStub { func invalidate() {} }

final class Attrappe {
    var scopeFinderFolders: [String] = []
    var refreshingScope = false
    var scopeRefreshGeneration = 0
    var queuedScopeRefreshGeneration: Int?
    var scopeResolved = false
    var scopeProblem: String?
    var runScopeMismatch: (searched: String, finder: String)?
    var scopeDenied = false
    var searching = false
    var userPickedScope = false
    var searchRoot = "/ersatz"
    var queuedQuery = false
    var scopeWaitTimer: TimerStub?
    var rebuilds = 0
    var shownProblems: [String] = []
    var deniedReports = 0

    func rebuildScopePopup() { rebuilds += 1 }
    func showScopeProblem(_ text: String) { shownProblems.append(text) }
    func runScopeNoteText() -> String? { nil }
    func maybeReportDeniedAutomation() { deniedReports += 1 }
    func startSearch() {}

%s

%s
}

let state = Attrappe()
state.scopeRefreshGeneration = 1
state.refreshFinderFoldersAsync()
state.scopeRefreshGeneration = 2
state.refreshFinderFoldersAsync()
let old = finderCallbacks.removeFirst()
old(.folders(["/alt"]))
print("NACH_ALT|\(state.scopeFinderFolders)|\(state.scopeResolved)|"
      + "\(finderCallbacks.count)|\(state.refreshingScope)")
let current = finderCallbacks.removeFirst()
current(.denied)
print("NACH_DENIED|\(state.scopeFinderFolders)|\(state.scopeResolved)|"
      + "\(state.scopeDenied)|\(state.rebuilds)|\(state.deniedReports)|"
      + "\(state.shownProblems.count)|\(state.refreshingScope)")
'''

    @classmethod
    def setUpClass(cls):
        refresh = swift_function(
            QUICK, "func refreshFinderFoldersAsync() {")
        apply = swift_function(
            QUICK, "func applyScopeOutcome(_ outcome: FinderScopeOutcome) {")
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "main.swift"
            source.write_text(cls.HARNESS % (refresh, apply), encoding="utf-8")
            binary = Path(tmp) / "refreshtest"
            subprocess.run(["swiftc", "-o", str(binary), str(source)],
                           check=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
            result = subprocess.run([str(binary)], check=True,
                                    stdout=subprocess.PIPE)
        cls.lines = dict(
            line.split("|", 1)
            for line in result.stdout.decode("utf-8").splitlines() if line)

    def test_old_answer_is_dropped_and_latest_refresh_is_started(self):
        self.assertEqual(self.lines["NACH_ALT"], "[]|false|1|true")

    def test_denied_answer_uses_the_visible_fallback_state(self):
        self.assertEqual(
            self.lines["NACH_DENIED"], "[]|true|true|1|1|1|false")


@unittest.skipUnless(shutil.which("swiftc"), "swiftc nicht verfügbar")
class QuickScopeNoteBehaviourTest(unittest.TestCase):
    """runScopeNoteText() hängt nur vom Zustand ab und lässt sich deshalb
    wirklich AUSFÜHREN: Die Funktion wird unverändert aus
    quick/FavenioQuick.swift geschnitten, in eine Attrappe mit denselben
    Zustandsfeldern gesetzt und übersetzt. So ist der sichtbare Satz geprüft
    und nicht nur die Schreibweise im Quelltext."""

    HARNESS = """
// Von tests/test_swift_guards.py erzeugt — kein Bestandteil der Apps.
func abbreviateHome(_ path: String) -> String { path }

final class Attrappe {
    var searching = false
    var userPickedScope = false
    var runScopeMismatch: (searched: String, finder: String)?
%s
}

let zustand = Attrappe()
zustand.runScopeMismatch = (searched: "/eins", finder: "/zwei")
zustand.searching = true
print("LAEUFT|" + (zustand.runScopeNoteText() ?? "nil"))
zustand.searching = false
print("FERTIG|" + (zustand.runScopeNoteText() ?? "nil"))
zustand.userPickedScope = true
print("GEWAEHLT|" + (zustand.runScopeNoteText() ?? "nil"))
zustand.userPickedScope = false
zustand.runScopeMismatch = nil
print("OHNE|" + (zustand.runScopeNoteText() ?? "nil"))
"""

    @classmethod
    def setUpClass(cls):
        body = swift_function(QUICK, "func runScopeNoteText() -> String? {")
        with tempfile.TemporaryDirectory() as tmp:
            # Top-Level-Code erlaubt Swift nur in einer Datei namens main.swift.
            source = Path(tmp) / "main.swift"
            source.write_text(cls.HARNESS % body, encoding="utf-8")
            binary = Path(tmp) / "notetest"
            subprocess.run(["swiftc", "-o", str(binary), str(source)],
                           check=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
            result = subprocess.run([str(binary)], check=True,
                                    stdout=subprocess.PIPE)
        cls.lines = dict(
            line.split("|", 1)
            for line in result.stdout.decode("utf-8").splitlines() if line)

    def test_the_note_speaks_in_the_present_only_while_searching(self):
        self.assertEqual(
            self.lines["LAEUFT"],
            "Suche läuft in /eins — Finder-Ordner ist /zwei "
            "(Return sucht dort).")

    def test_a_finished_search_is_not_called_running(self):
        # finish() und der Top-20-Stopp zeigen die Zeile NACH cancelSearch().
        self.assertEqual(
            self.lines["FERTIG"],
            "Gesucht wurde in /eins — Finder-Ordner ist /zwei "
            "(Return sucht dort).")

    def test_an_own_choice_drops_the_note_about_the_finder_folder(self):
        # „Return sucht dort" stimmte nach einer eigenen Bereichswahl nicht
        # mehr: Return sucht dann im selbst gewählten Ordner.
        self.assertEqual(self.lines["GEWAEHLT"], "nil")

    def test_without_a_mismatch_there_is_no_note(self):
        self.assertEqual(self.lines["OHNE"], "nil")


if __name__ == "__main__":
    unittest.main()
