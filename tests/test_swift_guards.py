import json
import re
import shutil
import unittest
from pathlib import Path
from swift_test_support import run_probe, swift_function


# Gegen das Repo, nicht gegen das Arbeitsverzeichnis: Ein Lauf aus einem
# anderen Ordner brach sonst schon beim Import ab, statt zu prüfen.
REPO = Path(__file__).resolve().parent.parent
COMMON = (REPO / "common/FavenioCore.swift").read_text(encoding="utf-8")
GUI = (REPO / "gui/FavenioGUI.swift").read_text(encoding="utf-8")
QUICK = (REPO / "quick/FavenioQuick.swift").read_text(encoding="utf-8")


def favenio_constant(name):
    """Der Wert einer Konstante aus favenio.py — repo-relativ gelesen."""
    quelle = (REPO / "favenio.py").read_text(encoding="utf-8")
    treffer = re.search(r"^%s = (.+)$" % re.escape(name), quelle, re.M)
    assert treffer is not None, "Konstante %s fehlt in favenio.py" % name
    return str(eval(treffer.group(1), {"__builtins__": {}}, {}))


class SwiftGuardTests(unittest.TestCase):
    def test_gui_search_callbacks_are_bound_to_active_run(self):
        self.assertIn("final class SearchRunner", COMMON)
        self.assertGreaterEqual(GUI.count("self.activeSearchRun === run"), 2)
        self.assertNotIn("var lineBuffer = Data()", GUI)
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
        # Seit 0.28.2 steht togglePreview() EINMAL in der Basisklasse
        # HitListController (common), beide Apps erben es.
        toggle = swift_function(COMMON, "@objc func togglePreview() {")
        self.assertIn("guard !previewURLs.isEmpty else {", toggle)
        self.assertIn("showActionIssue(selection)", toggle)
        # Ob es überhaupt eine Datei gibt, steht OHNE Auspacken fest
        # (hasOpenableFile) — sonst liefe für einen Archivordner erst ein
        # Kern-Prozess, der nichts zu tun hat.
        self.assertIn("selected.contains(where: { $0.hasOpenableFile })",
                      toggle)
        # Das Panel wird erst NACH dem Auspacken gezeigt (nur nach vorn
        # geholt, siehe test_quicklook_keeps_the_focus…): Der Aufbau der
        # Liste läuft asynchron, orderFront steht in der Completion.
        self.assertLess(toggle.index("requestPreview(rows: rows)"),
                        toggle.index("panel.orderFront(nil)"))

    def test_archive_hits_are_never_extracted_on_the_main_thread(self):
        """Bis 0.31.4 las materialize() stdout synchron und wartete mit
        waitUntilExit() — aus Oeffnen, Quick Look und Drag-and-drop heraus,
        also auf dem Main-Thread; das Fenster fror so lange ein, wie der Kern
        brauchte (tests/MATERIALIZATION_MEASUREMENTS.md). Die Apps rufen nur
        noch die Completion-Fassung; die synchrone bleibt dem
        Headless-Selbsttest vorbehalten."""
        selftest = swift_function(GUI, "func runSelfTest() -> Int32 {")
        for source, name in ((GUI.replace(selftest, ""), "FavenioGUI"),
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
                          "func cancelMaterializations()", "func openActionRows()"):
            self.assertIn(signature, COMMON)
            self.assertNotIn(signature, GUI)
            self.assertNotIn(signature, QUICK)
        # Quick Look nimmt nur die ZULETZT angeforderte Auswahl.
        preview = swift_function(COMMON, "func requestPreview(")
        self.assertIn("previewRequest?.cancel()", preview)
        self.assertIn("guard self.previewRequest === request else { return }",
                      preview)

    def test_both_apps_pass_additional_terms_from_the_filter_view(self):
        """Mehrwortsuche: Die Begriffe stehen in der gemeinsamen Filteransicht
        und erreichen ueber SearchConfiguration Argumente, URL und Vorlage —
        die Semantik (UND ueber das ganze Objekt) lebt allein im Kern."""
        self.assertIn("let termsEditor = PlaceholderTextView()", COMMON)
        self.assertIn('args.append("--term=" + term)', COMMON)
        self.assertIn('URLQueryItem(name: "term", value: $0)', COMMON)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                getter = swift_function(source, "var searchConfiguration: SearchConfiguration {")
                self.assertIn("configuration.terms = filterView.terms", getter)
        apply = swift_function(GUI, "func applyConfiguration(")
        self.assertIn("filterView.terms = configuration.terms", apply)

    def test_search_templates_fill_the_window_through_one_place_without_searching(self):
        """Quick-Uebergabe und Vorlage schreiben die Optionen ueber
        applyConfiguration() in die Oberflaeche; Laden startet KEINE Suche
        und behaelt bei fehlendem Ordner den aktuellen."""
        self.assertIn("struct SearchTemplate: Equatable", COMMON)
        self.assertIn("static let version = 1", COMMON)
        self.assertIn('"search-templates.json"', COMMON)
        handoff = swift_function(GUI, "func handleFavenioURL(")
        self.assertIn("applyConfiguration(SearchConfiguration.fromQueryItems(items))", handoff)
        self.assertNotIn("archivesCheckbox.state =", handoff)
        apply_template = swift_function(GUI, "func applyTemplate(")
        self.assertIn("applyConfiguration(template.configuration)", apply_template)
        self.assertIn("template.missingRootMessage", apply_template)
        for forbidden in ("startSearch()", "launchSearch("):
            self.assertNotIn(forbidden, apply_template)
        # Die Regex-Vorlagen bleiben eine getrennte Einfuegehilfe.
        self.assertIn("let regexTemplates: [RegexTemplate]", GUI)
        self.assertIn("@objc func insertTemplate(_ sender: NSMenuItem)", GUI)

    def test_a_new_hit_list_cancels_extractions_and_checks_the_root(self):
        """Jeder Weg zu einer NEUEN Trefferliste bricht Vorschau/Öffnen der
        alten ab (sonst „Packe aus…" über leerer Tabelle, Panel mit altem
        Treffer) und prüft den Suchordner, bevor der Kern ihn ohne Muster
        als Namensmuster liest. Der Exporttext läuft mit dem Start ab."""
        self.assertIn("func searchRootProblem(_ root: String) -> String?", COMMON)
        for name in ("@objc func startSearch() {", "func continueSearch(from file: URL) {",
                     "func loadResults(from file: URL) {", "func applyTemplate("):
            with self.subTest(function=name):
                self.assertIn("cancelMaterializations()", swift_function(GUI, name))
        launch = swift_function(GUI, "func launchSearch(pattern: String) {")
        self.assertIn("searchRootProblem(searchRoot.path)", launch)
        self.assertIn("exportStatus = nil", launch)
        self.assertIn("searchRootProblem(root)",
                      swift_function(QUICK, "func startSearch() {"))
        self.assertIn("cancelMaterializations()", swift_function(QUICK, "func clearHits()"))
        # Die Vorlagentabelle hängt an den ECHTEN Delegate-Namen.
        self.assertIn("func tableView(_ templateTable: NSTableView, viewFor", GUI)
        self.assertNotIn("func templateTable(_ templateTable", GUI)

    def test_drag_and_drop_promises_files_instead_of_extracting_on_grab(self):
        """pasteboardWriterForRow verlangt sofort eine Antwort. Was schon als
        Datei vorliegt, geht als URL; ein noch nicht ausgepackter Eintrag als
        NSFilePromiseProvider, den der Finder beim Ablegen einloest — ueber
        denselben Manager, im Hintergrund."""
        writer = swift_function(GUI, "                   pasteboardWriterForRow row: Int)")
        self.assertIn("MaterializationManager.shared.knownURL(for: hit)", writer)
        self.assertIn("NSFilePromiseProvider(fileType:", writer)
        self.assertNotIn("materializeHit(", writer)
        promise = swift_function(GUI, "                             writePromiseTo url: URL,")
        self.assertIn("MaterializationManager.shared.request(hit)", promise)
        self.assertIn("copyItem(at: source, to: url)", promise)
        self.assertIn("NSFilePromiseProviderDelegate", GUI)
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
        self.assertIn("window.makeFirstResponder(tableView)", toggle)
        # Und wird das Panel doch Tastaturfenster (am 2026-09-02 am Fenster
        # gemessen: nach der Leertaste war es das), leitet der Delegate wie
        # der Finder Pfeil hoch/runter an die Tabelle weiter und ⎋ schliesst.
        handler = swift_function(
            COMMON, "func previewPanel(_ panel: QLPreviewPanel!, handle event:")
        self.assertIn("tableView.keyDown(with: event)", handler)
        self.assertIn("panel.orderOut(nil)", handler)
        for source, name in ((GUI, "FavenioGUI"), (QUICK, "FavenioQuick")):
            with self.subTest(app=name):
                self.assertIn(": HitListController,", source)
                self.assertNotIn("func togglePreview(", source)
                self.assertNotIn("previewItemAt index", source)
                self.assertNotIn("func ctxCopyPath()", source)
        # ⎋ schliesst die Vorschau vom Hauptfenster aus, weil das Panel sich
        # als Nicht-Tastaturfenster nicht mehr selbst schliessen kann.
        self.assertIn("case 53 where modifiers.isEmpty", GUI)
        launch = swift_function(QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("QLPreviewPanel.shared().orderOut(nil)", launch)

    def test_progress_only_batches_refresh_gui_status(self):
        launch = swift_function(GUI, "func launchSearch(pattern: String)")
        self.assertIn("self.progressPath = progress", launch)
        self.assertIn("self.refreshStatus()", launch)

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

    def test_quick_handoff_states_regex_and_case_explicitly(self):
        """Die Schnellsuche sucht immer ohne Regex und ohne Gross/klein; die
        Haupt-App liest beide Werte und schaltet sie beim Fortsetzen aus.
        Der Vertrag steht in der URL selbst, statt als fehlender Wert vom
        Leser erraten zu werden."""
        handoff = swift_function(QUICK, "func openMainApp(")
        self.assertIn("searchConfiguration.queryItems", handoff)
        configuration = swift_function(QUICK, "var searchConfiguration:")
        self.assertNotIn("configuration.regex =", configuration)
        self.assertNotIn("configuration.caseSensitive =", configuration)
        self.assertIn("var regex = false", COMMON)
        self.assertIn("var caseSensitive = false", COMMON)
        self.assertIn('regexCheckbox.state = configuration.regex', GUI)
        self.assertIn('caseCheckbox.state = configuration.caseSensitive', GUI)

    def test_export_job_preserves_current_search_and_prevents_second_job(self):
        writer = swift_function(COMMON, "func write(_ hits: [Hit], format:")
        self.assertIn("guard !isWriting else { return false }", writer)
        self.assertIn("DispatchQueue.global", writer)
        self.assertIn("DispatchQueue.main.async", writer)
        self.assertIn("options: .atomic", writer)
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
        outside = QUICK[QUICK.index("final class QuickController:"):].replace(writer, "").replace(build, "")
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
        self.assertIn("configuration.only = selectedOnly", QUICK)
        self.assertIn("searchConfiguration.arguments(", start)
        handoff = QUICK[
            QUICK.index("func openMainApp("):
            QUICK.index("func locateMainApp()")
        ]
        self.assertIn("searchConfiguration.queryItems", handoff)
        # Seit 0.33.0 schreibt applyConfiguration() die Optionen in die
        # Oberflaeche; die Uebergabe ruft sie.
        handler = swift_function(GUI, "func handleFavenioURL(")
        self.assertIn("applyConfiguration(", handler)
        apply = swift_function(GUI, "func applyConfiguration(")
        self.assertIn("configuration.only", apply)
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
        # Die alte Übergabe --query/--results-file kannte keine Suchwurzel;
        # die Pfadspalte zeigte ihre Treffer relativ zum Benutzerordner
        # (Review-Fund 2026-09-05). Beide Bundles kommen immer mit derselben
        # Version, ein alter Quick trifft also nie auf diese App.
        self.assertNotIn('"--results-file"', startup)
        self.assertNotIn('"--query"', startup)

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
        self.assertIn("searchExitIsError(exit.status, reason: exit.reason)", GUI)
        self.assertIn("searchExitIsError(exit.status, reason: exit.reason)", QUICK)
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

    def test_the_search_never_throws_away_the_reason_it_failed(self):
        """stderr des Kerns trägt den Grund — er darf nicht ins Leere gehen.

        Bis 0.27.1 hing er auf nullDevice: Ein fehlendes exiftool, ein
        ungültiger regulärer Ausdruck und ein gelöschter Startordner kamen
        alle als „Suche fehlgeschlagen." an, und die Schnellsuche riet zu
        einer Neuinstallation, die nichts half.
        """
        streaming = swift_function(
            COMMON, "private func read(arguments: [String],")
        self.assertNotIn("standardError = FileHandle.nullDevice", streaming)
        self.assertIn("process.standardError = errPipe", streaming)
        # Nebenläufig leeren, sonst hält eine volle Pipe den Kern an.
        self.assertIn("diagnostics.collect(from: errPipe)", streaming)
        launch = streaming.index("try process.run()")
        self.assertLess(streaming.index("diagnostics.collect(from: errPipe)"),
                        launch,
                        "stderr muss VOR dem Start geleert werden")

        for source, signature in ((GUI, "func launchSearch(pattern: String)"),
                                  (QUICK, "func startSearch()")):
            start = swift_function(source, signature)
            self.assertIn("SearchRunner()", start)
            self.assertNotIn("Process()", start)

    def test_both_apps_name_the_reason_instead_of_guessing(self):
        body = swift_function(
            GUI, "func finishSearchRun(_ run: SearchRunner, exit: SearchExit)")
        self.assertIn("searchFailureText(", body, "GUI")
        # Die Schnellsuche wertet das Ende in startSearch() aus.
        self.assertIn("searchFailureText(",
                      swift_function(QUICK, "func startSearch()"), "Quick")
        # Der falsche Rat der Schnellsuche darf nicht zurückkehren.
        self.assertNotIn("erneut installieren", QUICK)
        # Und kein Frontend darf den Grund durch einen festen Satz ersetzen.
        self.assertNotIn('.failed("Suche fehlgeschlagen.")', GUI)

    def test_skipped_objects_are_counted_while_streaming(self):
        """Gezählt wird beim Durchlaufen, nicht aus einem gedeckelten Text.

        Ein Lauf über einen unlesbaren Baum erzeugt beliebig viele
        Warnungen; „470 Objekte übersprungen" wäre falsch, wenn es 5000
        waren.
        """
        append = swift_function(COMMON, "func append(_ chunk: Data)")
        self.assertIn("warnings += 1", swift_function(
            COMMON, "private func consume(_ line: String)"))
        self.assertIn("while let newline = carry.firstIndex(of: 0x0A)",
                      append)
        # Beide Oberflächen zeigen die Zahl auch an.
        for label, source in (("GUI", GUI), ("Quick", QUICK)):
            self.assertIn("skippedNote(skippedCount)", source, label)

    def test_the_diagnostics_reader_can_never_block(self):
        """`availableData` blockiert, solange die Schreibseite offen ist.

        Genau das passiert, wenn `process.run()` gescheitert ist: Das Kind
        hat die Pipe nie bekommen, und niemand sonst schließt sie.
        """
        finish = swift_function(COMMON, "func finish(_ pipe: Pipe)")
        schliessen = finish.index("fileHandleForWriting.close()")
        lesen = finish.index("availableData")
        self.assertLess(schliessen, lesen,
                        "Schreibseite muss VOR dem Lesen geschlossen werden")

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
    def test_metadata_field_list_comes_from_the_core(self):
        """Die kuratierte Feldliste ist EINE Konstante in favenio.py. Swift
        fragt sie per --list-metadata-fields ab statt sie abzuschreiben —
        sonst driften Kern und Menue auseinander."""
        self.assertIn("--list-metadata-fields", COMMON)
        self.assertIn("metadataFieldList()", GUI)
        # „Keywords" darf der Selbsttest nennen (er prüft die Liste); eine
        # abgeschriebene Liste verriete sich an den selteneren Feldern.
        for field in ("Caption-Abstract", "PersonInImage", "XPKeywords"):
            self.assertNotIn('"%s"' % field, GUI)
            self.assertNotIn('"%s"' % field, QUICK)
            self.assertNotIn('"%s"' % field, COMMON)
    def test_size_filters_reach_the_core_and_allow_an_empty_pattern(self):
        """Ohne Muster nur mit Maßfilter: SearchConfiguration.arguments laesst das Muster
        ganz weg (der Kern laeuft dann ohne Textkriterium; ein kuenstliches
        `*` war unter --regex ein ungueltiger Ausdruck), und beide Apps
        starten die Suche nur, wenn Muster ODER Maßfilter da sind."""
        arguments = swift_function(COMMON, "func arguments(pattern:")
        self.assertIn("args += validation.limits.arguments", arguments)
        self.assertNotIn('"*"', arguments)
        self.assertIn("if !pattern.isEmpty { args.append(pattern) }", arguments)
        # --content/--metadata sagen, WOGEGEN das Muster laeuft, und lehnt
        # der Kern ohne Muster ab.
        self.assertIn("if hasPattern", arguments)
        self.assertIn("if mode == .content", arguments)
        self.assertIn("if mode == .metadata", arguments)
        self.assertIn("guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter", GUI)
        self.assertIn("guard !query.isEmpty || searchConfiguration.hasPositiveFilter", QUICK)
    def test_a_size_only_search_can_be_handed_over_and_continued(self):
        """Der Knopf „Alle in Favenio" und ⌘↩ brachen bei leerem Suchfeld ab,
        obwohl die Schnellsuche mit gesetztem Maßfilter laeuft; die
        Fortsetzung in der Haupt-App ebenso. Beide Uebergabewege haengen
        jetzt an derselben Bedingung wie der Suchstart."""
        handover = swift_function(QUICK, "@objc func openInMainApp() {")
        self.assertIn("guard !query.isEmpty || searchConfiguration.hasPositiveFilter",
                      handover)
        # ⌘↩ geht nicht ueber den Knopf, sondern ueber den Tastaturmonitor —
        # der muss dieselbe Bedingung tragen, sonst faellt die Taste bei
        # leerem Suchfeld kommentarlos ins Feld durch.
        launched = swift_function(
            QUICK, "func applicationDidFinishLaunching(")
        self.assertIn("|| self.searchConfiguration.hasPositiveFilter", launched)
        continue_search = swift_function(
            GUI, "func continueSearch(from file: URL) {")
        self.assertIn("guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter",
                      continue_search)
    def test_a_size_only_result_line_names_the_size_filter(self):
        """Ohne Suchbegriff schrieb die Endmeldung „für „"" mit leeren
        Anfuehrungszeichen. Bei einer reinen Maßsuche nennt sie stattdessen
        den Filter, nach dem wirklich gesucht wurde."""
        finish = swift_function(
            QUICK, "func finish(query: String, errorText: String?) {")
        self.assertIn("searchConfiguration.filterSummary", finish)
        self.assertIn("query.isEmpty", finish)
    def test_area_sort_cannot_overflow(self):
        """Die Maß-Spalte sortiert nach Flaeche. Ein praeparierter Bildkopf
        mit 0xffffffff je Kante liess `width * height` ueber Int.max laufen
        und beendete die App; der Kern lehnt solche Kopfmaße zusaetzlich ab."""
        compare = swift_function(COMMON, "func compareHits")
        # Sortiert wird über die gedeckelte Fläche, nicht über eine
        # fangende Multiplikation im Vergleicher selbst.
        self.assertIn("lhs.pixelArea, rhs.pixelArea", compare)
        area = swift_function(COMMON, "var pixelArea")
        self.assertIn("multipliedReportingOverflow", area)
        # Die zweite Hälfte gehört dem Kern: Er lehnt unplausible
        # Kopfmaße ab. Geprüft wird das VERHALTEN, nicht der Name der
        # Konstante — ein `assertIn("MAX_IMAGE_EDGE", …)` auf den
        # Quelltext bestätigte nur sich selbst.
        grenze = favenio_constant("MAX_IMAGE_EDGE")
        self.assertEqual(grenze, str(2 ** 31 - 1))


@unittest.skipUnless(shutil.which("swiftc"), "swiftc nicht verfügbar")
class QuickScopeRefreshBehaviourTest(unittest.TestCase):
    """Führt die echten Refresh- und Apply-Funktionen in einer kleinen
    Attrappe aus. So lassen sich überlappende Finder-Antworten und verweigerte
    Automation deterministisch prüfen, ohne die TCC-Einstellungen des Macs zu
    verändern."""


    @classmethod
    def setUpClass(cls):
        result = run_probe('scope-refresh')
        cls.lines = dict(line.split('|', 1) for line in result.stdout.splitlines() if line)

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


    @classmethod
    def setUpClass(cls):
        result = run_probe('scope-note')
        cls.lines = dict(line.split('|', 1) for line in result.stdout.splitlines() if line)

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


class PixelFieldValidationGuards(unittest.TestCase):
    def test_both_frontends_gate_search_and_run_field_selftests(self):
        for source in (GUI, QUICK):
            self.assertIn("pixelFieldSelfTest(", source)
            self.assertIn("func validatePixelInputs()", source)
            self.assertIn("validatePixelFields(pixelFields)", source)
            start = swift_function(source, "func startSearch()")
            self.assertIn("guard validatePixelInputs() else { return }", start)
        for source, signature in ((GUI, "func launchSearch(pattern:"),
                                  (GUI, "func continueSearch(from"),
                                  (QUICK, "func openInMainApp()")):
            self.assertIn("guard validatePixelInputs() else { return }",
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


class MainAppResultListTest(unittest.TestCase):
    """Drei Stellen der Trefferliste, an denen die Haupt-App entweder
    abstuerzte, einfror oder die falsche Datei traf."""

    def test_the_cell_builder_never_reads_past_the_end(self):
        # applyHitsToTable verkleinert `hits` VOR dem reloadData(), und
        # dazwischen laufen noch sortHits() und deselectAll(nil) —
        # NSTableView haelt solange die alte Zeilenzahl. Fragt AppKit dann
        # eine Zelle jenseits des Endes an, endet die App mit
        # "Index out of range". Die Schnellsuche hatte die Pruefung immer.
        for label, source in (("GUI", GUI), ("Quick", QUICK)):
            body = swift_function(
                source, "                   viewFor tableColumn:")
            self.assertIn("row < hits.count else { return nil }", body,
                          label)

    def test_the_preview_panel_never_reads_past_the_end(self):
        # Das Panel fragt seinen ALTEN Index auch dann noch ab, wenn die
        # Liste inzwischen kuerzer ist: ⌫ oder ⌘⌫ kuerzt previewURLs und
        # ruft danach reloadData().
        body = swift_function(COMMON, "    func previewPanel(_ panel: "
                                      "QLPreviewPanel!,\n"
                                      "                      previewItemAt")
        self.assertIn("index < previewURLs.count", body)

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
        self.assertIn("while links < hits.endIndex", merge)

    def test_a_double_click_on_nothing_uses_the_selection(self):
        """`clickedRow` ist -1 bei einem Doppelklick unter der letzten
        Zeile. Vorher blieb der contextRow eines frueheren Rechtsklicks
        stehen: Zeile 2 markiert, auf Zeile 7 rechtsgeklickt, Menue mit ⎋
        geschlossen, dann in den leeren Bereich doppelgeklickt — geoeffnet
        wurde Datei 7."""
        body = swift_function(GUI, "@objc func openSelected()")
        self.assertIn("contextRow = tableView.clickedRow", body)
        self.assertNotIn("if tableView.clickedRow >= 0", body)
        # Das Rechtsklick-Menue behaelt seinen contextRow und geht
        # deshalb NICHT durch openSelected.
        ctx = swift_function(GUI, "@objc func ctxOpen()")
        self.assertNotIn("openSelected()", ctx)
        self.assertIn("openActionRows()", ctx)


class ParsedHitTypeTest(unittest.TestCase):
    """`isDirectory` kommt vom Kern und darf nicht erraten werden.

    Ein ORDNER im Archiv kommt als `member` an und saehe ohne das Feld aus
    wie eine Datei — genau der Review-Fund vom 2026-08-17, bei dem ein
    Doppelklick eine leere Datei erzeugte. Der Vertrag in AGENTS.md sagt
    dazu woertlich: „Die Frontends duerfen den Typ nicht aus dem Pfad oder
    aus `type` erraten."
    """

    def test_a_line_without_the_field_is_rejected_not_guessed(self):
        # Seit 0.28.2 liest parseSearchLine() die Felder; parseHit() ist nur
        # noch eine Huelle darum.
        body = swift_function(COMMON, "func parseSearchLine(")
        self.assertIn('guard let isDirectory = dict["isDirectory"] as? Bool',
                      body)
        self.assertNotIn('?? (kind == "dir")', body)

    def test_our_own_serialiser_always_writes_it(self):
        # Sonst wäre die strenge Prüfung oben ein Datenverlust: Die
        # Übergabe der Schnellsuche geht durch genau diesen Weg.
        body = swift_function(COMMON, "func jsonlData(")
        self.assertIn('"isDirectory": hit.isDirectory', body)

    def test_the_bundled_core_is_never_taken_from_the_working_directory(self):
        # Fehlt das gebündelte favenio.py, führte eine notarisierte App mit
        # Automations- und Festplatten-Freigaben sonst fremdes Python mit
        # ihren Rechten aus.
        body = swift_function(COMMON, "func findCLI()")
        self.assertIn('Bundle.main.bundleURL.pathExtension != "app"', body)
        self.assertLess(body.index("pathExtension != \"app\""),
                        body.index("currentDirectoryPath"))


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


if __name__ == "__main__":
    unittest.main()
