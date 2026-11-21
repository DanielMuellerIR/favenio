import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from swift_test_support import run_probe, suite_binary, swift_function
from test_favenio import favenio


# Gegen das Repo, nicht gegen das Arbeitsverzeichnis: Ein Lauf aus einem
# anderen Ordner brach sonst schon beim Import ab, statt zu prüfen.
REPO = Path(__file__).resolve().parent.parent
COMMON = "\n".join((REPO / "common" / (name + ".swift")).read_text(encoding="utf-8") for name in ("FavenioCore", "SearchModel", "SearchConfiguration", "SearchProcess", "ResultFilterModel", "DuplicateModel"))
GUI = (REPO / "gui/FavenioGUI.swift").read_text(encoding="utf-8")
QUICK = (REPO / "quick/FavenioQuick.swift").read_text(encoding="utf-8")
MAIN_SELFTEST = (REPO / "gui/FavenioMainSelfTest.swift").read_text(encoding="utf-8")


class SwiftGuardTests(unittest.TestCase):
    def test_both_frontends_use_the_shared_comparator(self):
        for frontend in (GUI, QUICK):
            self.assertIn("hitComparator()", swift_function(frontend, "func flushPending()"))

    def test_archive_context_menu_enables_only_available_actions(self):
        report = run_probe("archive-menu")
        self.assertEqual(report.stdout.strip(), "ARCHIVE MENU OK")

    def test_archive_hits_are_never_extracted_on_the_main_thread(self):
        """Bis 0.31.4 las materialize() stdout synchron und wartete mit
        waitUntilExit() — aus Oeffnen, Quick Look und Drag-and-drop heraus,
        also auf dem Main-Thread; das Fenster fror so lange ein, wie der Kern
        brauchte (tests/MATERIALIZATION_MEASUREMENTS.md). Die Apps rufen nur
        noch die Completion-Fassung; die synchrone bleibt dem
        Headless-Selbsttest vorbehalten."""
        for source, name in ((GUI, "FavenioGUI"),
                             (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                self.assertNotIn("materializeHit(", source)
                self.assertNotIn("materializeHitSelection(hits, rows: "
                                 "actionRows())", source)
                # ⎋ bricht ein laufendes Auspacken ab — vor allem anderen.
                self.assertIn("if self.cancelMaterializations() { return nil }",
                              source)
                self.assertIn("override func presentMaterializationState()",
                              source)
        # stderr-Flut, geteilte Aufträge und Cleanup werden mit wirklichen
        # Unterprozessen in test_materialization.py geprüft. Ihre konkrete
        # Schreibweise im Manager ist kein zusätzlicher Vertrag.
        # Die Basisklasse haelt die Aktionen; keine App baut sie nach.
        for signature in ("func withActionSelection(", "func requestPreview(",
                          "func cancelMaterializations(", "func openActionRows()"):
            self.assertIn(signature, COMMON)
            self.assertNotIn(signature, GUI)
            self.assertNotIn(signature, QUICK)
        # Quick Look nimmt nur die ZULETZT angeforderte Auswahl.
        preview = swift_function(COMMON, "func requestPreview(")
        self.assertIn("previewRequest?.cancel()", preview)
        self.assertIn("guard self.previewRequest === request else { return }",
                      preview)

    def test_a_new_hit_list_cancels_extractions_and_checks_the_root(self):
        """Jeder Weg zu einer NEUEN Trefferliste bricht Vorschau/Öffnen der
        alten ab (sonst „Packe aus…" über leerer Tabelle, Panel mit altem
        Treffer) und prüft den Suchordner, bevor der Kern ihn ohne Muster
        als Namensmuster liest. Der Exporttext läuft mit dem Start ab."""
        self.assertIn("func searchRootProblem(_ root: String) -> String?", COMMON)
        self.assertIn("startSearchWithReference(nil)", swift_function(GUI, "@objc func startSearch() {"))
        for name in ("func startSearchWithReference(", "func continueSearch(payload: QuickHandoffPayload) {",
                     "func loadResults(payload: QuickHandoffPayload) {"):
            with self.subTest(function=name):
                self.assertIn("replaceSearchResults(", swift_function(GUI, name))
        self.assertIn("cancelMaterializations(reportCancellation: false)", swift_function(GUI, "func replaceSearchResults("))
        self.assertIn("cancelMaterializations(reportCancellation: false)", swift_function(GUI, "func applyTemplate("))
        launch = swift_function(GUI, "func launchSearch(pattern: String,")
        self.assertIn("SearchRoots(searchRoots).liveProblem", launch)
        self.assertIn("exportStatus = nil", launch)
        self.assertIn("SearchRoots(roots).liveProblem",
                      swift_function(QUICK, "func startSearch() {"))
        self.assertIn("cancelMaterializations(reportCancellation: false)", swift_function(QUICK, "func clearHits()"))

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
        Trefferansicht den Fokus hat, und der Menuepunkt meldet sich sonst als
        ungueltig — ein ungueltiger Menuepunkt gibt sein Kuerzel frei."""
        launch = swift_function(GUI, "func applicationDidFinishLaunching(")
        self.assertIn("self.resultListHasFocus",
                      launch)
        self.assertIn("case 51 where modifiers.isEmpty:", launch)
        self.assertIn("case 51 where modifiers == .command:", launch)
        validate = swift_function(GUI, "func validateMenuItem(")
        self.assertIn("resultListHasFocus", validate)
        focus = COMMON[COMMON.index("var resultListHasFocus:"):COMMON.index("func installThumbnails(")]
        self.assertIn("window?.firstResponder === tableView", focus)
        self.assertIn("window?.firstResponder === thumbnailController?.collection", focus)
        self.assertIn("#selector(removeFromResults(_:))", validate)
        self.assertIn("#selector(trashSelected(_:))", validate)

    def test_streaming_updates_the_statistics_incrementally(self):
        """flushPending() laeuft waehrend eines langen Laufs sehr oft. Wer
        dort die ganze Liste neu aufsummiert, macht aus dem Streamen einen
        quadratischen Aufwand."""
        flush = swift_function(GUI, "func flushPending(")
        self.assertIn("for hit in pending { statistics.add(hit) }", flush)
        self.assertNotIn("HitStatistics.over", flush)
        self.assertNotIn(".over(hits)", flush)

    def test_quicklook_keeps_the_focus_in_the_main_window(self):
        """Sonst gehen Pfeil hoch/runter an das Vorschaufenster und man kann
        die Vorschau nicht durch die Trefferliste wandern lassen. Das Panel
        wird deshalb NUR nach vorn geholt, nie zum Tastaturfenster gemacht;
        den Fokus danach zurueckzuholen verlor das Rennen (2026-09-02 am
        Fenster geprueft). Ohne Wechsel des Tastaturfensters findet QuickLook
        seinen Controller nicht selbst — Datenquelle ausdruecklich setzen."""
        # Der Fix vom 2026-09-02 landete zuerst nur in der Haupt-App, die
        # Schnellsuche machte das Panel weiter zum Tastaturfenster
        # (Review-Fund 2026-09-03). Seit 0.28.2 steht der Vorschau-Block
        # EINMAL in der Basisklasse HitListController, und beide Apps erben
        # ihn — keine App darf eine eigene Fassung daneben halten.
        toggle = swift_function(COMMON, "@objc func togglePreview(")
        self.assertNotIn("makeKeyAndOrderFront", toggle)
        self.assertNotIn("DispatchQueue.main.async", toggle)
        self.assertIn("panel.dataSource = self", toggle)
        self.assertIn("panel.orderFront(nil)", toggle)
        self.assertIn("window.makeFirstResponder(activeResultView)", toggle)
        # Und wird das Panel doch Tastaturfenster (am 2026-09-02 am Fenster
        # gemessen: nach der Leertaste war es das), leitet der Delegate wie
        # der Finder Pfeil hoch/runter an die aktive Trefferansicht weiter und ⎋ schliesst.
        handler = swift_function(
            COMMON, "func previewPanel(_ panel: QLPreviewPanel!, handle event:")
        self.assertIn("activeResultView.keyDown(with: event)", handler)
        # Das Schließen steht seit 0.34.16 EINMAL in closeOpenPreview();
        # dieselbe Stelle nutzen beide Tastaturmonitore.
        self.assertIn("closeOpenPreview()", handler)
        closing = swift_function(COMMON, "func closeOpenPreview()")
        self.assertIn("QLPreviewPanel.shared().orderOut(nil)", closing)
        self.assertIn("QLPreviewPanel.shared().isVisible", closing)
        for label, source in (("GUI", GUI), ("Quick", QUICK)):
            with self.subTest(app=label):
                self.assertIn("closeOpenPreview()", source)
                self.assertNotIn("QLPreviewPanel.shared().orderOut(nil)",
                                 source)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                self.assertIn(": HitListController,", source)
                self.assertNotIn("func togglePreview(", source)
                self.assertNotIn("previewItemAt index", source)
                self.assertNotIn("func ctxCopyPath()", source)
        # ⎋ schliesst die Vorschau vom Hauptfenster aus, weil das Panel sich
        # als Nicht-Tastaturfenster nicht mehr selbst schliessen kann. In
        # BEIDEN Apps geht das ueber closeOpenPreview() und erst nach dem
        # Abbruch eines laufenden Auspackens.
        self.assertIn("case 53 where modifiers.isEmpty", GUI)
        launch = swift_function(QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("self.closeOpenPreview()", launch)
        self.assertLess(launch.index("cancelMaterializations()"),
                        launch.index("closeOpenPreview()"))
        # Und beide verlangen fuer ⎋ ausdruecklich KEINE Zusatztaste. In der
        # Schnellsuche loesten bis 0.34.16 auch ⇧⎋ und ⌥⎋ aus.
        self.assertIn("event.keyCode == 53, modifiers.isEmpty", launch)
        self.assertIn("plainModifiers(of: event)", launch)
        self.assertIn("plainModifiers(of: event)", GUI)
        # Die Normalisierung steht EINMAL im Kern.
        normalizer = swift_function(COMMON, "func plainModifiers(of event:")
        self.assertIn(".subtracting([.capsLock, .numericPad, .function])",
                      normalizer)
        for label, source in (("GUI", GUI), ("Quick", QUICK)):
            with self.subTest(app=label):
                self.assertNotIn(".subtracting([.capsLock", source)

    def test_the_live_stream_parses_every_line_only_once(self):
        """parseProgress und parseHit hintereinander parsten jede Trefferzeile
        zweimal. Gemessen am 2026-09-03 mit swiftc -O ueber 100 000 Zeilen:
        0,493 s gegen 0,289 s mit einem Parse. Die beiden Leser des
        laufenden Stroms nehmen deshalb parseSearchLine(); die alten
        Funktionen bleiben fuer Uebergabedatei, Export-Rueckprobe und Tests."""
        self.assertIn("enum SearchLine", COMMON)
        body = swift_function(COMMON, "func consume(_ line: Data)")
        self.assertIn("autoreleasepool { parseSearchLine(line) }", body)
        self.assertNotIn("parseProgress(", body)
        self.assertNotIn("parseHit(", body)
        for source in (GUI, QUICK):
            body = swift_function(source, "func startSearch()")
            self.assertNotIn("parseSearchLine(", body)
        # Und die Huellen bauen auf demselben Parser auf, statt eine dritte
        # Fassung der Feldregeln zu halten.
        for signature in ("func parseHit(_ lineData: Data)",
                          "func parseProgress(_ lineData: Data)"):
            self.assertIn("parseSearchLine(lineData)",
                          swift_function(COMMON, signature))

    def test_quick_key_monitor_only_acts_on_its_own_key_window(self):
        """Ein lokaler Monitor feuert auch waehrend runModal(): Beim
        allerersten Start beendete ⎋ im Hinweis zur Finder-Freigabe die
        ganze Schnellsuche, statt den Dialog zu schliessen. Dieselbe Wache
        wie in der Haupt-App: Ereignis aus dem eigenen Fenster, und das ist
        Tastaturfenster."""
        launch = swift_function(QUICK, "func applicationDidFinishLaunching(")
        monitor = launch[launch.index("addLocalMonitorForEvents"):]
        guard = monitor[:monitor.index("event.keyCode == 53")]
        self.assertIn("event.window === self.window", guard)
        self.assertIn("self.window.isKeyWindow", guard)
        self.assertIn("NSApp.terminate(nil)", monitor)

    def test_export_job_preserves_current_search_and_prevents_second_job(self):
        # Worker, Einzeljob-Sperre, Main-Completion und atomare Fehlerfälle
        # prüft die ausführbare Exportprobe. Hier bleibt die GUI-Anbindung.
        export = swift_function(GUI, "func runExport(_ selected:")
        self.assertIn("guard !exportIsBusy", export)
        self.assertIn("self.exportWriter.write", export)
        self.assertNotIn("exportData(for:", export)
        self.assertNotIn("statusLabel.stringValue", export)
        refresh = swift_function(GUI, "func refreshStatus()")
        self.assertIn("statusText()", refresh)
        self.assertIn("exportStatus.map", refresh)
        for signature in ("func exportAllHits(", "func exportSelectedHits("):
            self.assertIn("guard !exportIsBusy", swift_function(GUI, signature))

    def test_quick_command_return_hands_off_even_before_the_first_hit(self):
        """Die Haupt-App setzt die Suche selbst fort; deshalb ist ⌘↩ auch im
        Debounce-Fenster sinnvoll und darf nicht vom alten Trefferzustand
        abhängen."""
        launch = swift_function(QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("self.openInMainApp()", launch)
        self.assertNotIn("!self.hits.isEmpty", launch)
        self.assertIn("!self.field.stringValue.trimmingCharacters", launch)
        handoff = swift_function(QUICK, "@objc func openInMainApp()")
        self.assertIn("if hasSearched", handoff)
        self.assertIn("selectedSearchRoots", handoff)
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
        outside = QUICK[QUICK.index("final class QuickController:"):].replace(writer, "").replace(build, "")
        self.assertNotIn("infoLabel.stringValue", outside)
        self.assertNotIn("infoLabel.toolTip", outside)
        self.assertNotIn("infoLabel.textColor", outside)

    def test_filter_disclosure_exists_once(self):
        """Aufbau, Umschalten, Zählen und Titel des Schalters „Weitere Filter"
        standen bis 0.34.22 wörtlich in beiden Controllern; die Zählung von
        Leerraum in Maßfeldern war deshalb auch zweimal falsch. Neue Kopien
        in den Apps sind verboten."""
        self.assertIn("final class FilterDisclosure", COMMON)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                self.assertIn("FilterDisclosure(", source)
                for copy in ("func toggleFilters", "func setFiltersExpanded",
                             "func refreshFiltersTitle", "var activeFilterCount",
                             ".bezelStyle = .disclosure"):
                    self.assertNotIn(copy, source)

    def test_clearing_quick_hits_closes_the_preview_panel(self):
        self.assertIn("closeOpenPreview()", swift_function(QUICK, "func clearHits()"))

    def test_main_applies_the_handoff_type_filter(self):
        handler = swift_function(GUI, "func handleFavenioURL(")
        self.assertIn("applyConfiguration(", handler)
        apply = swift_function(GUI, "func applyConfiguration(")
        self.assertIn("configuration.only", apply)

    def test_quick_pause_does_not_truncate_the_result_list(self):
        continuation = QUICK[
            QUICK.index("func flushPending()"):
            QUICK.index("func finish(")
        ]
        self.assertNotIn('"Top \\(Self.maxQuickHits)', continuation)
        self.assertIn("openButton.toolTip", QUICK)

    def test_handoff_is_atomic_bounded_streamed_and_consumed(self):
        self.assertIn("options: .atomic", swift_function(COMMON, "func writeQuickHandoff("))
        self.assertIn("maximumHandoffBytes", COMMON)
        self.assertIn("read(upToCount: 64 * 1024)", COMMON)
        self.assertIn("removeItem(at: url)", COMMON)
        # Der Headless-Selbsttest darf seine kleine Vorlagendatei lesen.
        # Im Controller muss die Ergebnisübergabe weiterhin begrenzt bleiben.
        controller = GUI[GUI.index("final class MainController"):]
        self.assertNotIn("Data(contentsOf:", controller)
        self.assertIn('components.scheme?.lowercased() == "favenio"', GUI)
        self.assertIn("QuickHandoffFormat(host: host)", GUI)
        handler = GUI[
            GUI.index("func handleFavenioURL"):
            GUI.index("func loadResults")
        ]
        self.assertLess(
            handler.index("validatedQuickHandoff(URL(fileURLWithPath: filePath))"),
            handler.index("searchField.stringValue = query"),
        )
        self.assertIn("let resultsFile: URL", QUICK)
        self.assertIn("try writeQuickHandoff(seed, selection: seedSelection", QUICK)

    def test_main_startup_consumes_the_structured_handoff_url(self):
        startup = GUI[
            GUI.index("func applicationDidFinishLaunching"):
            GUI.index("func applicationDidBecomeActive")
        ]
        self.assertIn('arguments.firstIndex(of: "--handoff-url")', startup)
        self.assertIn("handleFavenioURL(handoffURL)", startup)
        # Die alte Übergabe --query/--results-file kannte keine Suchwurzel;
        # die Pfadspalte zeigte ihre Treffer relativ zum Benutzerordner
        # (Review-Fund 2026-09-05). Beide Bundles kommen immer mit derselben
        # Version, ein alter Quick trifft also nie auf diese App.
        self.assertNotIn('"--results-file"', startup)
        self.assertNotIn('"--query"', startup)

    def test_streaming_core_does_not_collect_duplicate_results(self):
        self.assertNotIn("var hitsRaw", COMMON)
        self.assertIn("-> SearchExit", COMMON)

    def test_frontends_reject_every_unexpected_search_exit(self):
        # grep-Semantik: Nur reguläre Exits 0 (Treffer) und 1 (keine Treffer)
        # sind normal. Ein Signal kann ebenfalls Status 1 tragen; deshalb muss
        # der Foundation-Abbruchgrund bis in beide Frontends gelangen.
        self.assertIn("let reason: Process.TerminationReason", COMMON)
        self.assertIn("process.terminationReason", COMMON)
        self.assertIn("searchExitIsError(exit.status, reason: exit.reason)", GUI)
        self.assertIn("searchExitIsError(exit.status, reason: exit.reason)", QUICK)
        self.assertIn(".uncaughtSignal", MAIN_SELFTEST)

    def test_open_finder_consent_is_never_timed_out(self):
        # Ein noch offener TCC-Dialog gehört dem Nutzer. Ein künstlicher
        # Timeout würde den osascript-Prozess und damit die wartende Freigabe
        # verwerfen; der Notaus gilt nur bei bereits entschiedenem Zugriff.
        source = (REPO / "common/FinderScope.swift").read_text(encoding="utf-8")
        finder = swift_function(source, "func finderWindowFoldersAsync(")
        self.assertNotIn("consentPending ? 180", finder)
        self.assertIn("if !consentPending {", finder)
        self.assertIn("deadline: .now() + 6", finder)
        self.assertIn("killer = nil", finder)

    def test_both_frontends_route_search_through_the_shared_runner(self):
        for source, signature in ((GUI, "func launchSearch(pattern: String,"),
                                  (QUICK, "func startSearch()")):
            start = swift_function(source, signature)
            self.assertIn("SearchRunner()", start)
            self.assertNotIn("Process()", start)

    def test_quick_names_the_reason_instead_of_guessing(self):
        self.assertIn("searchFailureText(",
                      swift_function(QUICK, "func startSearch()"))
        self.assertNotIn("erneut installieren", QUICK)

    def test_quick_shows_skipped_object_counts(self):
        self.assertIn("skippedNote(skippedCount)", QUICK)

    # --- Vertragswachen der Metadaten- und Maßsuche (0.26.0) ---
    # Sie standen bis 0.27.2 versehentlich in
    # QuickScopeNoteBehaviourTest, die @skipUnless(swiftc) trägt und
    # in setUpClass Swift übersetzt: Auf einem Rechner ohne
    # Xcode-Werkzeuge fiel damit die gesamte Absicherung lautlos aus,
    # und die Suite meldete trotzdem OK. Sie brauchen keinen
    # Übersetzer — sie lesen nur Quelltext.
    def test_both_apps_offer_the_mode_switch_and_size_fields(self):
        """Name | Inhalt | Metadaten ist EIN Umschalter in beiden Apps, kein
        Nachbau je App: Die Beschriftungen kommen aus SearchTextMode im
        gemeinsamen Kern. Die vier Maßfelder laufen ueber PixelLimits und
        parsePixelLimit, damit „1.000 px" ueberall dasselbe heisst."""
        self.assertIn("enum SearchTextMode", COMMON)
        self.assertIn("struct PixelLimits", COMMON)
        self.assertIn("func parsePixelLimit(", COMMON)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                self.assertIn("SearchTextMode.allCases.map { $0.title }",
                              source)
                self.assertIn("validatePixelFields(pixelFields)", source)
                # Der frühere Getter `pixelLimits` hatte keinen Aufrufer und
                # färbte als Nebenwirkung Felder um.
                self.assertNotIn("var pixelLimits: PixelLimits", source)
                self.assertNotIn("contentCheckbox", source)
                self.assertIn("configuration.mode = selectedMode", source)
                self.assertIn("configuration.pixelTexts =", source)
    def test_size_filters_reach_the_core_and_allow_an_empty_pattern(self):
        """Ohne Muster nur mit Maßfilter: SearchConfiguration.arguments laesst das Muster
        als echten leeren argv-Eintrag (der Kern läuft ohne Textkriterium; ein künstliches
        `*` war unter --regex ein ungueltiger Ausdruck), und beide Apps
        starten die Suche nur, wenn Muster ODER Maßfilter da sind."""
        arguments = swift_function(COMMON, "func arguments(pattern: String, roots:")
        self.assertIn("args += validation.limits.arguments", arguments)
        self.assertNotIn('"*"', arguments)
        self.assertIn("args.append(pattern)", arguments)
        self.assertIn("args += roots", arguments)
        # --content/--metadata sagen, WOGEGEN das Muster laeuft, und lehnt
        # der Kern ohne Muster ab.
        self.assertIn("if hasPattern", arguments)
        self.assertIn("if mode == .content", arguments)
        self.assertIn("if mode == .metadata", arguments)
        self.assertIn("guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter", GUI)

    def test_quick_size_handoff_shortcut_accepts_a_filter_without_text(self):
        # Die Button-Übergabe und die Fortsetzung werden nativ geprüft.
        # Ein echtes ⌘↩-Ereignis braucht ein aktives Tastaturfenster.
        launched = swift_function(QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("|| self.searchConfiguration.hasPositiveFilter", launched)

    def test_area_sort_uses_saturated_areas_and_a_strict_order(self):
        report = json.loads(run_probe("hit-sorting").stdout)
        self.assertEqual(report["ascending"], [
            "no dimensions", "narrow", "square", "a tie", "b tie", "oversized",
        ])
        self.assertEqual(report["descending"], [
            "oversized", "a tie", "b tie", "square", "narrow", "no dimensions",
        ])
        self.assertEqual(report["ascendingReflexive"], [])
        self.assertEqual(report["descendingReflexive"], [])
        self.assertEqual(favenio.MAX_IMAGE_EDGE, 2 ** 31 - 1)


class PixelFieldValidationGuards(unittest.TestCase):
    def test_both_frontends_validate_pixel_fields_at_search_entry_points(self):
        for source in (GUI, QUICK):
            self.assertIn("func validatePixelInputs()", source)
            self.assertIn("validatePixelFields(pixelFields)", source)
            start = swift_function(source, "func startSearchWithReference(" if source is GUI else "func startSearch()")
            self.assertIn("guard validatePixelInputs() else {", start)
        for source, signature in ((GUI, "func launchSearch(pattern:"),
                                  (GUI, "func continueSearch(payload:"),
                                  (QUICK, "func openInMainApp()")):
            self.assertIn("guard validatePixelInputs() else {",
                          swift_function(source, signature))


class ParsePixelLimitBehaviourTest(unittest.TestCase):
    """parsePixelLimit() haengt von nichts ab und laesst sich deshalb wirklich
    AUSFUEHREN: Das gemeinsame Testprogramm ruft die Produktionsfunktion
    aus common/FavenioCore.swift mit echten Eingaben auf. Frueher strich
    sie schlicht alle Nicht-Ziffern — aus „-1" wurde 1, aus „10.5" wurde 105,
    also eine Suchgrenze, die niemand hingeschrieben hat."""

    EINGABEN = ["1000", "1.000", "1 000", "1000 px", "1.000 px", "12",
                "-1", "10.5", "1.0", "1,5", "abc", "0", "", "  ",
                "1.000.000", "1.0000", "10.500", "12px", "3O0"]

    @classmethod
    def setUpClass(cls):
        result = run_probe('pixel-limit', input=json.dumps(cls.EINGABEN))
        answers = json.loads(result.stdout)
        if len(answers) != len(cls.EINGABEN):
            raise AssertionError('Swift-Probe hat Eingaben ausgelassen')
        cls.gelesen = dict(zip(cls.EINGABEN, answers))

    def test_plain_and_grouped_numbers_are_read(self):
        for text, expected in (("1000", "1000"), ("1.000", "1000"),
                               ("1 000", "1000"), ("1000 px", "1000"),
                               ("1.000 px", "1000"), ("12", "12"),
                               ("12px", "12"), ("1.000.000", "1000000")):
            with self.subTest(eingabe=text):
                self.assertEqual(self.gelesen[text], expected)

    def test_anything_that_is_not_a_whole_number_sets_no_limit(self):
        # "10.5" ist keine Tausendergruppe: Nach einem Trenner stehen genau
        # drei Ziffern, sonst ist es eine Dezimalzahl und keine Grenze.
        for text in ("-1", "10.5", "1.0", "1,5", "abc", "0", "", "  ",
                     "1.0000", "3O0"):
            with self.subTest(eingabe=text):
                self.assertEqual(self.gelesen[text], "nil")

    def test_a_real_thousands_group_still_counts(self):
        self.assertEqual(self.gelesen["10.500"], "10500")


class MainAppResultMergeGuard(unittest.TestCase):

    def test_fresh_hits_are_merged_instead_of_resorting_everything(self):
        """Jeder Nachschub sortierte die GANZE Liste neu — der Flush laeuft
        alle 0,15 s. Gemessen ueber einen ganzen Lauf mit 50 000 Treffern
        in Bloecken von 500 und dem echten Namensvergleicher: 1,02 s beim
        Neusortieren, 0,62 s beim Einmischen, Ergebnis identisch."""
        flush = swift_function(GUI, "func flushPending()")
        self.assertIn("mergeSortedHits(pending, using: comparator)", flush)
        self.assertIn("resort: false", flush)
        # Der volle Sortierlauf bleibt fuer Spaltenwechsel und Entfernen.
        self.assertIn("if resort { sortHits() }",
                      swift_function(GUI, "func applyHitsToTable("))
        merge = swift_function(GUI, "func mergeSortedHits(")
        # Linear zusammenfuehren, nicht wieder sortieren.
        self.assertNotIn("hits.sort", merge)
        self.assertIn("mergingSortedValues(hits, fresh, using: comparator)", merge)
        self.assertIn("while left < existing.endIndex", swift_function(COMMON, "func mergingSortedValues"))


class ParsedHitTypeTest(unittest.TestCase):
    def test_unknown_directory_type_is_rejected_and_valid_hits_round_trip(self):
        archive_dir = {"path": "/fixture/a.zip!/dir", "type": "member",
                       "filesystemPath": "/fixture/a.zip", "archiveMembers": ["dir"]}
        variants = [
            {**archive_dir, "isDirectory": True},
            {**archive_dir, "isDirectory": False},
            {**archive_dir, "isDirectory": "false"},
            archive_dir,
            {"path": "/fixture/file", "type": "file", "filesystemPath": "/fixture/file",
             "archiveMembers": [], "isDirectory": False},
            {"path": "/fixture/dir", "type": "dir", "filesystemPath": "/fixture/dir",
             "archiveMembers": [], "isDirectory": True},
        ]
        input_lines = json.dumps([json.dumps(value) for value in variants])
        report = json.loads(run_probe("hit-transport", input=input_lines).stdout)
        self.assertEqual(report["parsed"], [True, False, None, None, False, True])
        self.assertEqual(report["serialized"], [variants[index] for index in (0, 1, 4, 5)])

    def test_bundled_cli_cannot_fall_back_to_the_working_directory(self):
        binary = suite_binary()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            working = root / "project"
            working.mkdir()
            local_cli = working / "favenio.py"
            local_cli.touch()
            bundle = root / "Fixture.app" / "Contents"
            macos = bundle / "MacOS"
            bundle_cli = bundle / "Resources" / "favenio.py"
            macos.mkdir(parents=True)
            bundle_cli.parent.mkdir()
            (bundle / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.favenio.fixture", "CFBundleExecutable": "TestProbe",
                "CFBundlePackageType": "APPL",
            }))
            app_binary = Path(shutil.copy2(binary, macos / "TestProbe"))
            bundle_cli.touch()
            cases = [(binary, local_cli), (app_binary, bundle_cli), (app_binary, None)]
            for executable, expected in cases:
                with self.subTest(executable=executable, expected=expected):
                    if expected is None:
                        bundle_cli.unlink()
                    result = subprocess.run([str(executable), "find-cli"], cwd=working,
                                            capture_output=True, text=True, check=True, timeout=10)
                    self.assertEqual(result.stdout.strip(), str(expected) if expected else "")


class MetadataFieldListTest(unittest.TestCase):
    def test_metadata_fields_come_from_the_running_cli(self):
        binary = suite_binary()
        with tempfile.TemporaryDirectory() as scratch:
            cli = Path(scratch, "favenio.py")
            cli.write_text(
                "import sys\nassert sys.argv[1:] == ['--list-metadata-fields']\n"
                "print('Fixture-Keywords')\nprint('Fixture-Caption')\n",
                encoding="utf-8")
            for expected in (["Fixture-Keywords", "Fixture-Caption"], []):
                result = subprocess.run([str(binary), "metadata-fields"], cwd=scratch,
                                        capture_output=True, text=True, check=True, timeout=10)
                self.assertEqual(json.loads(result.stdout), expected)
                cli.unlink(missing_ok=True)


class CsvFieldBehaviourTest(unittest.TestCase):
    """csvField() haengt von nichts ab und laesst sich deshalb wirklich
    AUSFUEHREN: Das gemeinsame Testprogramm ruft die Produktionsfunktion
    aus FavenioCore.swift mit echten Dateinamen auf.

    macOS erlaubt in einem Dateinamen jedes Zeichen ausser "/" und NUL.
    Beginnt ein Zellwert mit "=", "+", "-", "@" oder einem Tabulator,
    wertet Excel ihn als FORMEL — auch in Anfuehrungszeichen. Eine Datei
    `=cmd|'/c calc'!A1.txt` landete beim Export in der ersten Spalte."""

    EINGABEN = ["harmlos.txt", "mit,Komma.txt", 'mit"Anfuehrung.txt',
                "=cmd|'/c calc'!A1.txt", "=1+1", "+42", "-minus.txt",
                "@SUM(A1)", "\tTab.txt", "=gefaehrlich,mit Komma.txt",
                "", "0=keine Formel.txt"]

    @classmethod
    def setUpClass(cls):
        result = run_probe('csv-field', input=json.dumps(cls.EINGABEN))
        answers = json.loads(result.stdout)
        if len(answers) != len(cls.EINGABEN):
            raise AssertionError('Swift-Probe hat Eingaben ausgelassen')
        cls.gelesen = dict(zip(cls.EINGABEN, answers))

    def test_a_formula_prefix_is_defused(self):
        for text in ("=cmd|'/c calc'!A1.txt", "=1+1", "+42", "-minus.txt",
                     "@SUM(A1)", "\tTab.txt"):
            with self.subTest(eingabe=text):
                wert = self.gelesen[text]
                # Das Apostroph steht VOR dem gefährlichen Zeichen — in
                # Anführungszeichen gesetzt eben dahinter.
                kern = wert[1:-1] if wert.startswith('"') else wert
                self.assertTrue(kern.startswith("'"), wert)

    def test_ordinary_names_are_untouched(self):
        self.assertEqual(self.gelesen["harmlos.txt"], "harmlos.txt")
        self.assertEqual(self.gelesen[""], "")
        # Eine Ziffer am Anfang ist keine Formel.
        self.assertEqual(self.gelesen["0=keine Formel.txt"],
                         "0=keine Formel.txt")

    def test_quoting_still_works(self):
        self.assertEqual(self.gelesen["mit,Komma.txt"], '"mit,Komma.txt"')
        self.assertEqual(self.gelesen['mit"Anfuehrung.txt'],
                         '"mit""Anfuehrung.txt"')
        # Beides zusammen: entschärft UND korrekt gequotet.
        self.assertEqual(self.gelesen["=gefaehrlich,mit Komma.txt"],
                         '"\'=gefaehrlich,mit Komma.txt"')


class TypeDescriptionCacheTest(unittest.TestCase):
    """Der Zwischenspeicher muss dieselben Antworten geben wie die direkte
    Abfrage. `UTType(filenameExtension:)` samt `localizedDescription` ist
    eine Datenbankabfrage (gemessen 11,65 µs); die Sortierung nach der
    Typ-Spalte ruft sie zweimal je Vergleich, und bei 100 000 Treffern
    kostete ein Sortierlauf dadurch 46,6 s — mit Zwischenspeicher 1,2 s
    (gemessen 2026-09-03, swiftc -O)."""

    ENDUNGEN = ["txt", "pdf", "png", "jpg", "zip", "swift", "heic", "mov",
                "gibtsnicht", "TXT"]

    def test_the_cache_answers_exactly_like_a_direct_lookup(self):
        result = run_probe('type-description', input=json.dumps(self.ENDUNGEN))
        answers = json.loads(result.stdout)
        # Zweimal durchlaufen: Der zweite Lauf trifft den Speicher.
        self.assertEqual(len(answers), 2 * len(self.ENDUNGEN))
        for index, (cached, direct) in enumerate(answers):
            with self.subTest(endung=self.ENDUNGEN[index % len(self.ENDUNGEN)]):
                self.assertEqual(cached, direct)

    def test_the_hit_type_goes_through_the_cache(self):
        # Ohne diese Wache fiele die Sortierung beim nächsten Umbau
        # unbemerkt auf 46,6 s zurück.
        body = swift_function(COMMON, "    var typeDescription: String {")
        self.assertIn("typeDescriptions.description(for:", body)
        self.assertNotIn("UTType(filenameExtension:", body)


class CommonApplicationsTest(unittest.TestCase):
    """„Öffnen mit" bietet nur Anwendungen an, die JEDEN Treffer öffnen.

    Die Schnittmenge lief bis 0.34.11 je Treffer, obwohl eine schon
    geschnittene Endung nichts mehr wegnehmen kann: `common` war damals
    eine Teilmenge ihrer Anwendungsmenge und ist seither nur kleiner
    geworden. Bei 100 000 gleichartigen Treffern kostete das 11,9 s statt
    0,08 s — auf dem Main-Thread beim Öffnen des Rechtsklick-Menüs
    (gemessen 2026-09-10, swiftc -O).

    Diese Abkürzung ist nur erlaubt, solange beide Fassungen dasselbe
    liefern. Die Probe führt deshalb die ALTE Fassung mit und vergleicht."""

    EINGABEN = (
        ["a.txt"],
        ["a.txt", "b.txt", "c.txt"],
        ["a.txt", "b.pdf", "c.txt", "d.pdf", "e.txt"],
        ["a.txt", "ohneendung", "b.txt", "ohneendung2"],
        ["a.TXT", "b.txt", "c.Txt"],
        ["bild.png", "text.txt", "film.mov", "bild2.png", "text2.txt"],
        ["a.gibtsnichtxyz", "b.gibtsnichtxyz"],
        ["a.txt"] * 200,
    )

    def test_both_ways_offer_the_same_applications(self):
        for namen in self.EINGABEN:
            with self.subTest(eingabe=namen[:4], anzahl=len(namen)):
                result = run_probe('common-apps', input=json.dumps(namen))
                report = json.loads(result.stdout)
                self.assertEqual(report["neu"], report["alt"])

    def test_each_extension_is_queried_once_for_the_common_apps_menu(self):
        names = ["a.txt", "b.TXT", "c.txt", "d.pdf", "e.PDF"]
        result = run_probe("common-apps", "--fixture-applications", input=json.dumps(names))
        report = json.loads(result.stdout)
        self.assertEqual(report["neu"], ["/fixture/Editor.app"])
        self.assertEqual(report["lookups"], ["extension:txt", "extension:pdf"])

    def test_directories_and_files_with_the_same_extension_are_intersected(self):
        for names in (["folder.txt/", "file.txt"], ["file.txt", "folder.txt/"],
                      ["one.app/", "two.app/", "file.app"]):
            with self.subTest(names=names):
                report = json.loads(run_probe('common-apps', '--direct', input=json.dumps(names)).stdout)
                self.assertEqual(report["neu"], report["direct"])


if __name__ == "__main__":
    unittest.main()
