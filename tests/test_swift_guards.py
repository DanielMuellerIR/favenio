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
        # Nur die Vergleichsfunktion selbst prüfen, nicht die ganze Datei:
        # Ein dateiweites Muster wie "return false" trifft irgendwann eine
        # fremde Zeile und die Wache wird stillschweigend gegenstandslos.
        compare = swift_function(COMMON, "func compareHits")
        # Die naive Umkehrung macht aus einem Gleichstand ein „kleiner" in
        # BEIDE Richtungen.
        self.assertNotIn("return ascending ? result : !result", compare)
        # Gleichstand endet ausdrücklich mit „nicht kleiner".
        self.assertIn("== .orderedAscending", compare)
        # Und der Headless-Selbsttest prüft die Ordnung zur Laufzeit.
        self.assertIn("!compareHits(tied, tied", GUI)
        self.assertIn("compareHits($0, $1", GUI)
        self.assertIn("compareHits($0, $1", QUICK)

    def test_gui_table_updates_always_go_through_one_place(self):
        """Sortierung und Auswahlerhalt haengen an applyHitsToTable(). Wer
        daneben direkt reloadData() ruft, umgeht beides — genau daran krankten
        continueSearch() und loadResults()."""
        controller = GUI[GUI.index("final class MainController"):]
        self.assertIn("func applyHitsToTable(keepingSelection", controller)
        apply_function = swift_function(
            GUI, "func applyHitsToTable(keepingSelection")
        outside = controller.replace(apply_function, "")
        self.assertNotIn("tableView.reloadData()", outside)

    def test_both_menus_grey_out_actions_for_a_folder_in_an_archive(self):
        """Ein Ordner im Archiv hat keine Datei hinter sich; materializeHit()
        liefert dafuer nil. Vorher boten beide Kontextmenues Vorschau, Oeffnen
        und Im Finder zeigen trotzdem an und taten auf Klick kommentarlos
        nichts. Die Bedingung steht EINMAL im Kern und wird nicht in den Apps
        nachgebaut."""
        self.assertIn("var hasOpenableFile: Bool", COMMON)
        builder = swift_function(COMMON, "func populateHitContextMenu(")
        # Kommentare dürfen keinen dieser Belege liefern. Genau das machte die
        # vorige Suche nach „Ordner im Archiv" wirkungslos.
        code = "\n".join(line.split("//", 1)[0] for line in builder.splitlines())
        compact = " ".join(code.split())
        self.assertIn(
            'NSMenuItem(title: "Ordner im Archiv — keine Datei " '
            '+ "zum Öffnen"', compact)
        self.assertIn("openWithItem.isEnabled = openable", code)
        self.assertIn("if openable {", code)
        self.assertIn("openWithItem.submenu = submenu", code)
        # „Öffnen mit" darf nur Apps anbieten, die JEDEN öffnenbaren Treffer
        # der Auswahl öffnen — ctxOpenWith übergibt später alle URLs an die
        # eine gewählte App (Review-Fund 2026-08-21).
        self.assertIn("commonApplicationsFor(applicationHits)", code)
        self.assertNotIn("applicationsFor(applicationHit)", code)
        self.assertIn("action: openable ? selectors.preview : nil", code)
        self.assertIn("action: openable ? selectors.open : nil", code)
        self.assertIn("action: openable ? selectors.reveal : nil", code)
        self.assertIn("action: selectors.copyPath", code)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            menu = swift_function(source, "func menuNeedsUpdate(")
            with self.subTest(app=name):
                self.assertIn("populateHitContextMenu(", menu)
                # Die wirksame Zeilenmenge entscheidet; bei gemischter Auswahl
                # genügt ein öffnenbarer Treffer, egal worauf rechtsgeklickt
                # wurde. Menü und spätere Aktion benutzen actionRows().
                self.assertIn("actionRows().compactMap", menu)
                # ALLE öffnenbaren Treffer, nicht nur der erste.
                self.assertIn("filter { $0.hasOpenableFile }", menu)
                self.assertIn("applicationHits: applicationHits", menu)
                self.assertIn("copyPath: #selector(ctxCopyPath)", menu)
        # Und der Headless-Selbsttest prueft die Auskunft gegen die Wirklichkeit.
        self.assertIn("materializeHit(archiveFolder) == nil", GUI)

    def test_space_key_preview_only_opens_with_a_real_file(self):
        """Die Leertaste ruft togglePreview() direkt, am Kontextmenue vorbei.
        Fuer einen Ordner im Archiv gibt es keine Datei; das Panel ginge leer
        auf. Deshalb baut togglePreview() die Vorschau-URLs SELBST auf und
        bricht bei leerer Liste mit einem Hinweis ab."""
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            toggle = swift_function(source, "@objc func togglePreview() {")
            with self.subTest(app=name):
                self.assertIn("guard !previewURLs.isEmpty else {", toggle)
                self.assertIn("showActionIssue(selection)", toggle)
                self.assertLess(toggle.index("rebuildPreviewURLs()"),
                                toggle.index("panel.makeKeyAndOrderFront"))
        issue = swift_function(COMMON, "func hitActionIssue(")
        self.assertIn("Ordner im Archiv", issue)
        self.assertIn("Kein Treffer ausgewählt", issue)

    def test_trashing_is_one_bulk_call_and_never_touches_an_archive_entry(self):
        """Der Papierkorb muss so schnell sein wie im Finder: EIN
        recycle()-Aufruf fuer die ganze Auswahl, nicht ein Aufruf je Datei.
        Und ein Eintrag IM Archiv hat keine eigene Datei — dort laege nur die
        ausgepackte Temp-Kopie, deren Loeschung niemandem hilft."""
        trash = swift_function(COMMON, "func trashHits(")
        self.assertIn("NSWorkspace.shared.recycle(urls)", trash)
        # Kein Weg, der Datei fuer Datei arbeitet.
        for slow in ("trashItem", "for hit in hits", "for url in urls"):
            self.assertNotIn(slow, trash)
        split = swift_function(COMMON, "func trashableHits(")
        self.assertIn("if hit.isMember {", split)
        self.assertIn("seen.insert(hit.filesystemPath).inserted", split)
        # Und die GUI fragt genau diese Aufteilung, statt sie nachzubauen.
        action = swift_function(GUI, "@objc func trashSelected(")
        self.assertIn("trashableHits(targets)", action)
        self.assertIn("alert.runModal() == .alertFirstButtonReturn", action)
        self.assertIn("playFinderTrashSound()", action)

    def test_removing_from_the_list_never_touches_the_filesystem(self):
        """„Aus Trefferliste entfernen" verfeinert nur die Anzeige. Wer hier
        versehentlich einen Loesch- oder Papierkorbweg einbaut, vernichtet
        Daten, obwohl der Menuepunkt das Gegenteil verspricht."""
        for name in ("@objc func removeFromResults(",
                     "func removeHits(where"):
            body = swift_function(GUI, name)
            for destructive in ("trashHits", "recycle", "removeItem",
                                "trashItem", "unlink"):
                self.assertNotIn(destructive, body, name)

    def test_list_shortcuts_release_their_keys_outside_the_result_list(self):
        """⌫ und ⌘⌫ duerfen im Suchfeld weiter ganz normal Text loeschen.
        Dafuer sorgen zwei Dinge: Der Tastaturmonitor greift nur, wenn die
        Tabelle den Fokus hat, und der Menuepunkt meldet sich sonst als
        ungueltig — ein ungueltiger Menuepunkt gibt sein Kuerzel frei."""
        launch = swift_function(GUI, "func applicationDidFinishLaunching(")
        self.assertIn("self.window.firstResponder === self.tableView",
                      launch)
        self.assertIn("case 51 where modifiers.isEmpty:", launch)
        self.assertIn("case 51 where modifiers == .command:", launch)
        validate = swift_function(GUI, "func validateMenuItem(")
        self.assertIn("window?.firstResponder === tableView", validate)
        self.assertIn("#selector(removeFromResults(_:))", validate)
        self.assertIn("#selector(trashSelected(_:))", validate)

    def test_both_list_actions_are_visible_in_the_menu_with_their_keys(self):
        """Ein Kuerzel, das nirgends steht, ist Geheimwissen. Beide Aktionen
        stehen im Ablage-Menue UND im Rechtsklick-Menue, aus demselben
        Bauplan, mit ihrem Kuerzel daneben."""
        builder = swift_function(COMMON, "func populateResultListMenu(")
        self.assertIn('"Aus Trefferliste entfernen"', builder)
        self.assertIn('"In den Papierkorb legen"', builder)
        self.assertIn("keyEquivalent: backspaceKeyEquivalent", builder)
        self.assertIn("trash.keyEquivalentModifierMask = [.command]", builder)
        self.assertIn("remove.keyEquivalentModifierMask = []", builder)
        # Und der Headless-Selbsttest prueft die gebauten Punkte am echten
        # NSMenu — ein Kommentar im Quelltext kann diese Wache nicht erfuellen.
        self.assertIn('resultMenu.items', GUI)
        for caller in ("func installFileMenu(", "func menuNeedsUpdate("):
            self.assertIn("addResultListItems(to:",
                          swift_function(GUI, caller), caller)

    def test_footer_numbers_are_written_from_state_not_stored_as_a_sentence(self):
        """Die Fusszeile wird aus dem Zustand formuliert. Wer die fertige
        Zahl irgendwo anders hineinschreibt, hat spaeter eine Zeile, die der
        Liste nicht mehr folgt — dieselbe Falle wie in FavenioQuick."""
        controller = GUI[GUI.index("final class MainController"):]
        status = swift_function(GUI, "func statusText(")
        outside = controller.replace(status, "")
        self.assertNotIn("hits.count) Treffer", outside)
        self.assertIn("hitStatisticsText(", status)
        # Die Auswahl erst ab zwei markierten Zeilen — sonst stuende dort
        # fast immer „1 ausgewaehlt", was niemandem hilft.
        text = swift_function(COMMON, "func hitStatisticsText(")
        self.assertIn("if selected >= 2", text)

    def test_streaming_updates_the_statistics_incrementally(self):
        """flushPending() laeuft waehrend eines langen Laufs sehr oft. Wer
        dort die ganze Liste neu aufsummiert, macht aus dem Streamen einen
        quadratischen Aufwand."""
        flush = swift_function(GUI, "func flushPending(")
        self.assertIn("for hit in pending { statistics.add(hit) }", flush)
        self.assertNotIn("HitStatistics.over", flush)
        self.assertNotIn(".over(hits)", flush)
        # Beide Wege muessen dasselbe ergeben; der Selbsttest vergleicht sie.
        self.assertIn("stepwise.folders == atOnce.folders", GUI)

    def test_quicklook_hands_the_focus_back_to_the_main_window(self):
        """Sonst gehen Pfeil hoch/runter an das Vorschaufenster und man kann
        die Vorschau nicht durch die Trefferliste wandern lassen."""
        toggle = swift_function(GUI, "@objc func togglePreview(")
        self.assertIn("self.window.makeKeyAndOrderFront(nil)", toggle)
        self.assertIn("self.window.makeFirstResponder(self.tableView)",
                      toggle)

    def test_path_export_is_offered_in_the_form_pipes_really_need(self):
        """Ein Dateiname darf unter macOS jedes Zeichen ausser / und NUL
        enthalten — auch einen Zeilenumbruch. Deshalb gibt es die Pfadliste
        zusaetzlich NUL-getrennt; nur die uebertraegt jeden Namen unversehrt
        an `xargs -0`."""
        self.assertIn("case pathsNUL", COMMON)
        export = swift_function(COMMON, "func exportData(")
        self.assertIn('$0.path + "\\0"', export)
        self.assertIn("return jsonlData(for: hits)", export)
        # Die BOM ist kein Schmuck: ohne sie liest Excel UTF-8 als Latin-1.
        self.assertIn("Data([0xEF, 0xBB, 0xBF])", export)
        self.assertIn("csvField(", export)

    def test_menu_actions_from_the_main_menu_ignore_a_stale_click_row(self):
        """`contextRow` merkt sich den Rechtsklick. Aus dem Hauptmenue und
        vom Tastenkuerzel gibt es keinen Klickort — dort muss die Auswahl
        gelten, sonst trifft ⌘⌫ die Datei eines frueheren Rechtsklicks."""
        rows = swift_function(GUI, "func rows(for sender: Any?)")
        self.assertIn("item.menu === tableView.menu", rows)
        self.assertIn("return actionRows()", rows)
        self.assertIn("return Array(tableView.selectedRowIndexes)", rows)

    def test_quick_drops_old_hits_on_every_keystroke(self):
        """Zwischen Tastendruck und dem 0,6-s-Debounce standen die Treffer des
        ALTEN Suchtexts weiter in der Liste, der Uebergabeknopf blieb aktiv.
        ⌘↩ schickte der Haupt-App in diesem Fenster alte Treffer unter neuem
        Suchtext."""
        change = swift_function(QUICK, "func controlTextDidChange(")
        self.assertIn("clearHits()", change)
        self.assertIn("guard !query.isEmpty", change)
        self.assertLess(change.index("clearHits()"),
                        change.index("guard !query.isEmpty"))
        clear = swift_function(QUICK, "func clearHits()")
        for line in ("hits = []", "openButton.isEnabled = false",
                     "runScopeMismatch = nil", "previewURLs = []",
                     "tableView.reloadData()", "showInfo(Self.hint)",
                     "orderOut(nil)"):
            self.assertIn(line, clear)

    def test_quick_command_return_hands_off_even_before_the_first_hit(self):
        """Die Haupt-App setzt die Suche selbst fort; deshalb ist ⌘↩ auch im
        Debounce-Fenster sinnvoll und darf nicht vom alten Trefferzustand
        abhängen."""
        launch = swift_function(QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("self.openInMainApp()", launch)
        self.assertNotIn("!self.hits.isEmpty", launch)
        self.assertIn("!self.field.stringValue.trimmingCharacters", launch)
        handoff = swift_function(QUICK, "@objc func openInMainApp()")
        self.assertIn("if !hits.isEmpty || searching", handoff)
        self.assertIn("scopePopup.selectedItem?.representedObject", handoff)
        self.assertIn("Finder-Ordner wird noch ermittelt", handoff)

    def test_quick_info_line_has_a_single_writer(self):
        """Farbe, Umbruch und Tooltip der Infozeile gehören zusammen. Solange
        einzelne Meldungen nur `stringValue` schrieben, blieb der Tooltip einer
        längst erledigten Bereichswarnung an einer harmlosen Statuszeile
        hängen."""
        writer = swift_function(QUICK, "func showInfo(")
        for property_name in ("textColor", "lineBreakMode", "stringValue",
                              "toolTip"):
            self.assertIn("infoLabel.%s" % property_name, writer)
        # Ausserhalb von showInfo() und dem einmaligen Aufbau des Fensters
        # fasst niemand die Infozeile an.
        build = swift_function(QUICK, "func buildWindow()")
        outside = QUICK.replace(writer, "").replace(build, "")
        self.assertNotIn("infoLabel.stringValue", outside)
        self.assertNotIn("infoLabel.toolTip", outside)
        self.assertNotIn("infoLabel.textColor", outside)

    def test_quick_uses_a_regular_window_and_balances_the_search_row(self):
        build = QUICK[
            QUICK.index("func buildWindow()"):
            QUICK.index("func buildTable()")
        ]
        self.assertIn("window = NSWindow(", build)
        self.assertIn(".miniaturizable", build)
        self.assertNotIn("NSPanel(", build)
        self.assertNotIn("level = .floating", build)
        self.assertIn(
            "field.widthAnchor.constraint(equalTo: scopePopup.widthAnchor)",
            build)

    def test_quick_table_is_resizable_sortable_and_scrolls_horizontally(self):
        table = swift_function(QUICK, "func buildTable()")
        self.assertIn("visibleWidth * 0.65", table)
        self.assertIn('NSSortDescriptor(key: "name"', table)
        self.assertIn('NSSortDescriptor(key: "path"', table)
        self.assertIn("allowsColumnResizing = true", table)
        self.assertIn("hasHorizontalScroller = true", table)
        self.assertIn(".noColumnAutoresizing", table)
        self.assertNotIn("headerView = nil", table)

    def test_quick_type_filter_reaches_search_and_main_handoff(self):
        start = QUICK[
            QUICK.index("func startSearch()"):
            QUICK.index("func showProgress")
        ]
        self.assertIn("let only = selectedOnly", start)
        self.assertIn("only: only", start)
        handoff = QUICK[
            QUICK.index("func openMainApp("):
            QUICK.index("func locateMainApp()")
        ]
        self.assertIn('URLQueryItem(name: "only", value: selectedOnly)',
                      handoff)
        handler = GUI[
            GUI.index("func handleFavenioURL"):
            GUI.index("func loadResults")
        ]
        self.assertIn('value("only") ?? "both"', handler)
        continuation = QUICK[
            QUICK.index("func flushPending()"):
            QUICK.index("func finish(")
        ]
        self.assertNotIn('"Top \\(Self.maxQuickHits)', continuation)
        self.assertIn("openButton.toolTip", QUICK)

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
        self.assertIn("clearHits()", start)
        self.assertLess(start.index("clearHits()"),
                        start.index("guard !query.isEmpty"))
        self.assertLess(start.index("clearHits()"),
                        start.index("scopePopup.selectedItem?.representedObject"))

    def test_quick_keeps_the_scope_warning_while_hits_arrive(self):
        # Eine Warnung zum Suchbereich darf nicht vom Trefferzähler
        # überschrieben werden — beim Top-20-Stopp käme sie sonst nie wieder.
        flush = QUICK[
            QUICK.index("func flushPending()"):
            QUICK.index("func finish(")
        ]
        self.assertIn("showScopeProblem(summary + problem)", flush)

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
                ("func clearHits()", "func startSearch()",
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
