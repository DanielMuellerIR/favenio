// Favenio.app — die große GUI im EasyFind-Stil.
//
// Aufbau: Suchfeld + Ordnerwahl + Optionen oben, darunter die Trefferliste.
// Die Suche läuft als Unterprozess (favenio.py --json) und streamt ihre
// Treffer live in die Tabelle. Aus der Liste heraus geht:
//   - Doppelklick        → Datei öffnen (Archiv-Einträge werden erst
//                          per --extract in einen Temp-Ordner ausgepackt)
//   - Rechtsklick        → Öffnen / Öffnen mit… / Im Finder zeigen /
//                          Pfad kopieren
//   - Drag & Drop        → Datei in den Finder oder andere Apps ziehen
//
// Außerdem versteht die App das URL-Schema favenio://results?file=…&q=…
// sowie das Startargument --handoff-url —
// darüber liefert die Schnellsuche (FavenioQuick.app) ihre Treffer an.

import AppKit
import Quartz   // QLPreviewPanel (QuickLook-Vorschau)

#if !FAVENIO_SELFTEST
@main
struct FavenioApp {
    static func main() {
        if CommandLine.arguments.contains("--check-bundle") {
            exit(checkProductBundle(identifier: "local.favenio", appName: "Favenio",
                                    helpers: ["favenio-control", "favenio-ocr", "favenio-pdf"]))
        }
        // Headless-Diagnose: was sieht DIESES Bundle beim Finder wirklich?
        if CommandLine.arguments.contains("--finder-scope") {
            runFinderScopeDiagnostic()
        }
        let app = NSApplication.shared
        applyUITestAppearance(app)
        let controller = MainController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
    }
}
#endif

// MARK: - Haupt-Controller

/// Erbt von HitListController (common/FavenioCore.swift): Trefferliste,
/// Vorschau und die gemeinsamen Kontextmenü-Aktionen stehen dort EINMAL
/// für beide Apps.
final class MainController: HitListController, NSApplicationDelegate,
                            NSTableViewDataSource, NSTableViewDelegate,
                            NSMenuDelegate,
                            NSSearchFieldDelegate {
    override var localOnlyContent: Bool { filterView.localOnly }

    /// Ein Controller pro App-Prozess; Sparkle hält darüber Update-Zustand,
    /// Download und Installation über die gesamte App-Laufzeit zusammen.
    private let updaterController = makeUpdaterController()
    let searchField = NSSearchField()
    let stopButton = NSButton(title: "", target: nil, action: nil)
    let folderButton = NSButton(title: "Ordner…", target: nil, action: nil)
    // Suchziel; das Menü hält auch Dokumenttext in schmalen Fenstern erreichbar.
    let modeControl: NSPopUpButton = {
        let control = NSPopUpButton()
        control.addItems(withTitles: SearchTextMode.allCases.map { $0.title })
        control.setAccessibilityIdentifier("searchTextMode")
        control.toolTip = searchTextModeToolTip
        return control
    }()
    // Nur bei „Metadaten": ein Feld oder alle Textfelder. Die Liste kommt
    // vom Kern (--list-metadata-fields) und wird hier nicht nachgebaut.
    let fieldPopup = NSPopUpButton()
    // Bildmaße: Breite und Höhe je von/bis, leer = egal. Gelten immer
    // zusätzlich (UND) zum Muster; das Muster darf dann auch fehlen.
    let filterView = SearchFilterView()
    let criteriaControl = CriteriaControl()
    /// Aufklapp-Schalter über den Größen-/Datums- und Ausschlussfeldern.
    /// Diese Filter braucht man selten; zugeklappt kostet die Zeile nur
    /// eine Höhe. Der Zustand überlebt den Neustart (`filtersExpandedKey`).
    /// Der Titel nennt nicht alles: Auch weitere Suchbegriffe liegen hinter
    /// dem Schalter und zählen zugeklappt mit (`FilterDisclosure.activeCount`).
    lazy var filters = FilterDisclosure(
        defaultsKey: Self.filtersExpandedKey,
        baseTitle: "Weitere Filter: Bildmaße, Größe, Datum, Ausschlüsse",
        filterView: filterView, pixelFields: pixelFields)
    /// Die Bildmaße-Zeile; liegt seit 0.31.3 mit hinter dem Schalter.
    var sizeRow = NSStackView()
    static let filtersExpandedKey = "Favenio.filters.expanded"
    let minWidthField = NSTextField(string: "")
    let maxWidthField = NSTextField(string: "")
    let minHeightField = NSTextField(string: "")
    let maxHeightField = NSTextField(string: "")
    let archivesCheckbox = NSButton(checkboxWithTitle: "In Archiven suchen",
                                    target: nil, action: nil)
    let regexCheckbox = NSButton(checkboxWithTitle: "Regex",
                                 target: nil, action: nil)
    let caseCheckbox = NSButton(checkboxWithTitle: "Groß/klein beachten",
                                target: nil, action: nil)
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Unsichtbare",
                                  target: nil, action: nil)
    // „Genauer Name": ohne diesen Schalter ist ein Muster ohne Platzhalter ein
    // Teilstring — „release.sh" fände dann auch „test-github-release.sh".
    let exactCheckbox = NSButton(checkboxWithTitle: "Genauer Name",
                                 target: nil, action: nil)
    // Drei-Wege-Umschalter: Dateien & Ordner / nur Dateien / nur Ordner.
    let typeControl = NSSegmentedControl(
        labels: ["Dateien & Ordner", "Dateien", "Ordner"],
        trackingMode: .selectOne, target: nil, action: nil)
    // Aufklappbare Liste fertiger RegEx-Vorlagen (nur im Regex-Modus sinnvoll).
    let templatesButton = NSButton(title: "Regex-Vorlagen ▾",
                                   target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "Bereit.")

    var seenHitIdentities = Set<HitIdentity>()   // bereits gezeigte Objekte
    // Was dieser Lauf in den Papierkorb gelegt hat. Ein noch laufender
    // Suchprozess kennt den Papierkorb nicht und streamt Treffer unter einem
    // verschobenen Ordner oder in einem verschobenen Archiv weiter.
    var trashedPaths = TrashedPaths()
    var cachedFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    private let finderScopeRefresh = FinderScopeRefresh()
    // Warum die Finder-Fenster fehlen (verweigerte Automation, kein Fenster,
    // Zeitüberschreitung). Steht im Ordner-Menü, statt kommentarlos zu fehlen.
    var finderScopeProblem: String?
    var finderScopeDenied = false
    var searchRoots = [FileManager.default.homeDirectoryForCurrentUser.path]
    var searchRoot: URL {
        get { URL(fileURLWithPath: searchRoots.first ?? "/") }
        set { searchRoots = [newValue.path] }
    }
    var rootsEditor: SearchRootsEditor?
    var activeSearchRun: SearchRunner?
    lazy var searchControl = LocalSearchController(host: self)
    var flushTimer: Timer?
    var pendingURL: URL?            // favenio://-URL, die vor dem Fenster kam
    /// Zustand der Suche für die Fußzeile. Gespeichert wird der ZUSTAND, nie
    /// ein fertig formulierter Satz — sonst steht dort später „Suche läuft…",
    /// obwohl sie längst fertig ist. Dieselbe Falle umgeht FavenioQuick mit
    /// runScopeNoteText().
    enum SearchPhase {
        case idle                // es wurde noch nicht gesucht
        case running
        case stopped             // vom Nutzer abgebrochen
        case finished
        case recorded(String)
        case handedOver          // Treffer der Schnellsuche, ohne eigenen Lauf
        case failed(String)      // Grund, den die Fußzeile wörtlich zeigt
    }
    var searchPhase: SearchPhase = .idle
    /// Wie viele Objekte der letzte Lauf überspringen musste (kaputtes
    /// Archiv, fehlende Leserechte). Ohne diese Zahl sieht ein Lauf, der
    /// etwas auslassen musste, genauso vollständig aus wie einer, der
    /// alles gelesen hat.
    var skippedCount = 0
    /// Ordner oder Archiv, das der Kern gerade durchsucht (nur bei .running).
    var progressPath: String?
    /// Kennzahlen der Trefferliste (Treffer, Datenmenge, Ordner) für die
    /// Fußzeile. Beim Streamen fortgeschrieben statt neu aufsummiert.
    var statistics = HitStatistics()
    /// Der offene Sichern-Dialog des Exports; das Format-Aufklappmenü darin
    /// muss seinen Dateinamen ändern können.
    var exportSavePanel: NSSavePanel?
    /// Exporttext hinter dem Suchstatus in der Fußzeile. Er überlebt eine
    /// LAUFENDE Suche (ein später Exportabschluss darf sie nicht
    /// verdrängen), aber nicht den nächsten Start: `launchSearch()` und
    /// `loadResults()` nehmen ihn weg — bis 0.34.0 hing er die ganze
    /// Sitzung hinter jedem Status.
    var exportStatus: String?
    var recordingComparison: RecordingComparison?
    var recordingComparisonWindow: RecordingComparisonWindow?
    var exportIsBusy: Bool { exportSavePanel != nil || exportWriter.isWriting || searchReportController.isSaving }

    // ---------- App-Lebenszyklus ----------

    func applicationWillFinishLaunching(_ notification: Notification) {
        // GetURL-Events (favenio://…) müssen VOR didFinishLaunching
        // registriert sein, sonst geht ein Launch-per-URL verloren.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(appName: "Favenio")
        installUpdateMenuItem(updaterController: updaterController)
        buildWindow()
        searchControl.listen()
        installAboutItem()
        installViewMenu()
        installFileMenu()
        installSearchRootsMenu(target: self, action: #selector(editSearchRoots))
        installTemplatesMenu()
        // Finder-Fenster für das Ordner-Popup vorab im Hintergrund laden
        // (der AppleScript-Aufruf darf den Start nicht blockieren).
        if !CommandLine.arguments.contains("--control-test-host") { refreshFinderFoldersAsync() }

        // Fallback-Weg ohne funktionierende URL-Zuordnung: Quick startet eine
        // neue App-Instanz und gibt denselben strukturierten URL-Datensatz als
        // Argument mit. Dadurch verarbeitet genau EIN Parser Wurzel, Optionen,
        // Ergebnisdatei und die gewünschte Fortsetzung der Suche.
        //
        // Die ältere Übergabe --query/--results-file gibt es nicht mehr: Sie
        // kannte keine Suchwurzel, und die Pfadspalte zeigte die Treffer
        // dann relativ zum Benutzerordner statt zum durchsuchten Ordner
        // (Review-Fund 2026-09-05). Nötig war sie nie — install.sh und das
        // DMG liefern beide Bundles nur mit derselben Version aus.
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--handoff-url"),
           flagIndex + 1 < arguments.count,
           let handoffURL = URL(string: arguments[flagIndex + 1]) {
            handleFavenioURL(handoffURL)
        }
        // Eine URL, die schon vor dem Fensterbau eintraf, jetzt verarbeiten.
        if let url = pendingURL {
            pendingURL = nil
            handleFavenioURL(url)
        }

        // Beim Start einmal auf Festplattenvollzugriff hinweisen (bringt bei
        // Suchen über den ganzen Benutzerordner deutlich weniger Nachfragen).
        if !CommandLine.arguments.contains("--control-test-host") {
            maybePromptFullDiskAccess(appName: "Favenio")
        }

        // Tasten, die nur IN der Trefferliste gelten. Hat die Tabelle nicht
        // den Fokus, geht das Ereignis unverändert weiter — dann tippt die
        // Leertaste normal ins Suchfeld und ⌫ löscht dort ein Zeichen.
        //
        // Der Monitor läuft vor NSApplication.sendEvent und damit vor dem
        // Tastenkürzel des Menüs: Wer hier zugreift, löst die Aktion genau
        // einmal aus. Der Menüpunkt trägt dasselbe Kürzel trotzdem — dort
        // steht es sichtbar, statt Geheimwissen zu bleiben.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            // Das Ereignis muss aus dem HAUPTFENSTER kommen, und das muss
            // das Tastaturfenster sein. Der gemerkte firstResponder allein
            // reicht nicht: Während ein Sichern-Blatt oder ein NSAlert offen
            // ist, steht im Hauptfenster weiter die Tabelle — ⌫ im
            // Dateinamenfeld des Exportdialogs entfernte sonst Treffer
            // (Review-Fund 2026-09-02).
            guard let self,
                  event.window === self.window,
                  self.window.isKeyWindow
            else { return event }
            let modifiers = plainModifiers(of: event)
            // ⎋ bricht ein laufendes Auspacken ab, egal wo der Fokus steht:
            // Der Hinweis „(⎋ bricht ab)" verspricht das ohne Einschränkung,
            // und wer nach „Öffnen" ins Suchfeld klickte, leerte damit bis
            // 0.34.0 nur das Suchfeld, während die Extraktion weiterlief.
            if event.keyCode == 53, modifiers.isEmpty {
                if self.cancelMaterializations() { return nil }
            }
            // Alles Weitere gilt nur, solange die Trefferliste den Fokus hat.
            guard self.resultListHasFocus else { return event }
            switch event.keyCode {
            case 49 where modifiers.isEmpty:               // Leertaste
                self.contextRow = -1
                self.togglePreview()
                return nil
            case 53 where modifiers.isEmpty:               // ⎋
                // Die Vorschau ist nicht mehr das Tastaturfenster und kann
                // sich deshalb nicht mehr selbst schließen. Nur abfangen,
                // wenn sie wirklich offen ist — sonst gehört ⎋ weiter dem
                // Fenster (Suchfeld leeren, Blatt abbrechen).
                return self.closeOpenPreview() ? nil : event
            case 51 where modifiers.isEmpty:               // ⌫
                self.contextRow = -1
                self.removeFromResults(nil)
                return nil
            case 51 where modifiers == .command:           // ⌘⌫
                self.contextRow = -1
                self.trashSelected(nil)
                return nil
            default:
                return event
            }
        }
    }

    /// „Über Favenio" ganz oben ins App-Menü setzen.
    func installAboutItem() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        let about = NSMenuItem(title: "Über Favenio",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.insertItem(about, at: 0)
        appMenu.insertItem(.separator(), at: 1)
    }

    /// Über-Dialog: HIER (und nur hier) steht der lateinische Spruch, dazu
    /// Versionsnummer und Versionsdatum.
    @objc func showAbout() {
        let credits = NSAttributedString(
            string: "facile invenio — „ich finde mit Leichtigkeit“\n\n"
                + "Indexlose Datei- und Archivsuche.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Favenio",
            .applicationVersion: favenioVersion,         // Versionsnummer
            .version: favenioDate,                       // Versionsdatum
            .credits: credits,
        ])
    }

    /// Auswahl geändert, während die Vorschau offen ist → mitziehen.
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Während applyHitsToTable die Auswahl leert und wieder setzt, ist
        // der Zwischenzustand keine Auswahländerung.
        guard !isRestoringSelection else { return }
        contextRow = -1
        refreshStatus()     // „N ausgewählt" in der Fußzeile mitziehen
        refreshContentPreview()
        reloadPreviewIfSelectionChanged()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { true }

    /// App vorderste → Finder-Fenster (neu) laden. Nur wenn die App aktiv
    /// ist, zeigt TCC den Automations-Consent-Dialog. Läuft im Hintergrund.
    func applicationDidBecomeActive(_ notification: Notification) {
        if CommandLine.arguments.contains("--control-test-host") { return }
        // Finder-Fenster der vorigen Aktivierung sind keine gültige Antwort
        // für die neue: Bis die frische Abfrage da ist, bleibt die Liste leer.
        cachedFinderFolders = []
        refreshFinderFoldersAsync(forActivation: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !searchControl.handoff.jobs.isEmpty else { return .terminateNow }
        stopSearch()
        searchControl.handoff.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        duplicateCheckController.stopForTermination()
        filterView.stopDateEditorForTermination()
        criteriaControl.stopForTermination()
        resultFilter.stopForTermination()
        searchControl.handoff.cancelPending()
        stopSearch()
        thumbnailController?.loader.cancelAll(clearCache: true)
        cleanupMaterializedHits()
    }

    // ---------- URL-Schema (favenio://results?file=…&q=…&root=…) ----------

    @objc func handleGetURL(_ event: NSAppleEventDescriptor,
                            withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event
                .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue,
              let url = URL(string: urlString) else { return }
        if window == nil {
            pendingURL = url    // Fenster existiert noch nicht → merken
        } else {
            handleFavenioURL(url)
        }
    }

    func handleFavenioURL(_ url: URL) {
        guard url.absoluteString.utf8.count <= maximumQuickURLBytes,
              let components = URLComponents(url: url,
                                             resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "favenio"
        else { return }
        let host = components.host?.lowercased() ?? ""
        guard let format = QuickHandoffFormat(host: host) else {
            if host.hasPrefix("results-v") {
                presentActionIssue(summary: "Unbekannte Version der Quick-Übergabe.", detail: nil)
            }
            return
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if format.hasHeader {
            let transportKeys = Set(["q", "root", "file", "continue"])
            let envelope = items.filter { transportKeys.contains($0.name) }
            guard Set(envelope.map { $0.name }).count == envelope.count,
                  envelope.allSatisfy({ $0.value != nil && !$0.value!.utf8.contains(0) }),
                  !format.hasRoots || value("root") == nil else {
                presentActionIssue(summary: "Ungültige Quick-Übergabe.", detail: nil)
                return
            }
            if let problem = SearchConfiguration.transportProblem(items.filter { !transportKeys.contains($0.name) }) {
                presentActionIssue(summary: problem, detail: nil)
                return
            }
        }
        if let problem = CriteriaTransport.problem(items) {
            presentActionIssue(summary: problem, detail: nil)
            return
        }
        let configuration = SearchConfiguration.fromQueryItems(items)
        if let problem = format.optionProblem(configuration, explicitEncoding: items.contains(where: { $0.name == "encoding" })) {
            presentActionIssue(summary: problem, detail: nil)
            return
        }
        guard let filePath = value("file"),
              validatedQuickHandoff(URL(fileURLWithPath: filePath)) != nil,
              quickHandoffInputProblem(query: value("q") ?? "",
                                       root: value("root") ?? "") == nil else { return }
        guard let incoming = consumeQuickHandoffPayload(URL(fileURLWithPath: filePath)),
              incoming.version == format.rawValue,
              let payload = incoming.bound(to: incoming.roots ?? value("root").map { [$0] } ?? searchRoots) else {
            presentActionIssue(summary: "Ungültige oder zu große Ergebnisübergabe.", detail: nil)
            return
        }
        if format.hasFrozenOptions {
            guard let frozen = payload.configuration,
                  frozen.queryItems.flatMap({ [Data($0.name.utf8), Data(($0.value ?? "").utf8)] })
                    == configuration.queryItems.flatMap({ [Data($0.name.utf8), Data(($0.value ?? "").utf8)] }) else {
                presentActionIssue(summary: "Suchoptionen und Laufzeitpunkt der Übergabe stimmen nicht überein.", detail: nil); return
            }
        }
        if let root = value("root"), SearchRoots.problem([root], limited: false) != nil {
            presentActionIssue(summary: "Ungültiger Suchbereich der Quick-Übergabe.", detail: nil)
            return
        }
        if let query = value("q") { searchField.stringValue = query }
        if let roots = payload.roots { setSearchRoots(roots) }
        else if let root = value("root") { setSearchRoots([root]) }
        // Suchoptionen der Schnellsuche übernehmen (Default: aus), damit die
        // Weitersuche hier mit denselben Einstellungen läuft. „Aus" ist bei
        // regex, case und field kein Verlust: Die Schnellsuche hat diese
        // Schalter nicht und sucht immer ohne sie; ein hier gesetzter Wert
        // muss deshalb zurückgesetzt werden, sonst passen die übergebenen
        // Treffer nicht zur fortgesetzten Suche. Neue Quick-Versionen
        // schicken regex=0 und case=0 ausdrücklich mit.
        // Alte Quick-Versionen schicken nur content=0/1, neue den Modus.
        applyConfiguration(configuration)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if value("continue") == "1" {
            // Die Schnellsuche hat erste Treffer übergeben: diese sofort
            // zeigen und die Suche hier live fortsetzen (weitere Treffer
            // kommen hinzu, die 20 werden dabei nicht doppelt gelistet).
            continueSearch(payload: payload)
        } else {
            loadResults(payload: payload)
        }
        // Auch eine reine Ergebnisanzeige markiert ungültige URL-Eingaben;
        // der nächste Start bleibt durch denselben Validator gesperrt.
        _ = validatePixelInputs()
    }

    /// Fertige Treffer (JSONL-Datei der Schnellsuche) direkt anzeigen —
    /// die Suche lief dort schon, hier wird nichts doppelt gesucht.
    func loadResults(from file: URL) {
        guard let payload = consumeQuickHandoffPayload(file) else {
            rejectQuickHandoff()
            return
        }
        loadResults(payload: payload)
    }

    func loadResults(payload: QuickHandoffPayload) {
        guard let payload = payload.bound(to: payload.roots ?? searchRoots) else {
            presentActionIssue(summary: "Die Herkunft der übergebenen Treffer passt nicht zu den Suchbereichen.", detail: nil)
            return
        }
        if let configuration = payload.configuration { applyConfiguration(configuration) }
        if let roots = payload.roots { setSearchRoots(roots) }
        replaceSearchResults(payload.hits)
        if let configuration = payload.configuration {
            let input = ControlSearchInput(pattern: searchField.stringValue.trimmingCharacters(in: .whitespaces), roots: searchRoots, options: configuration)
            searchControl.imported(input)
            var report = SearchReportSnapshot.pending(configuration: input.object, state: "recorded")
            if let dates = payload.dateResolution { report.object["dateResolution"] = preservedJSONObject(dates) }
            searchReportController.accept(report)
        }
        applyHitsToTable(keepingSelection: payload.selection)
        exportStatus = nil
        searchPhase = .handedOver
        refreshStatus()
    }

    func rejectQuickHandoff() {
        replaceSearchResults([])
        let reason = "Ungültige oder zu große Ergebnisübergabe."
        searchPhase = .failed(reason)
        searchControl.failed(reason)
        refreshStatus()
    }

    // ---------- Fenster + Layout ----------

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Favenio"   // der lateinische Spruch nur im „Über"-Dialog
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }

        searchField.placeholderString =
            "Suchmuster — Return startet die Suche"
        searchField.target = self
        searchField.action = #selector(startSearch)
        // Nur Return/Enter (bzw. die Lupe) löst die Action aus — NICHT jeder
        // Tastendruck. Ohne diese beiden Zeilen schickt NSSearchField die
        // Action von selbst, rund 0,45 s nach jeder Tipppause: gemessen am
        // 2026-09-10 feuerte „Rechnung*" mit normalen Denkpausen dreimal.
        // Jeder dieser Aufrufe leert über `startSearch` die sichtbare
        // Trefferliste und schießt den laufenden Kernprozess ab, um für zwei
        // Zeichen einen neuen zu starten — bei eingeschalteter Archivsuche
        // ein voller Archivabstieg. Der Platzhalter verspricht das Gegenteil,
        // und eine Entprellung wie in der Schnellsuche gibt es hier nicht.
        searchField.sendsWholeSearchString = true
        searchField.sendsSearchStringImmediately = false
        searchField.delegate = self   // controlTextDidChange → Regex-Färbung
        // Ohne das zeigt NSSearchField NUR eine Textfarbe — die Token-Färbung
        // im Regex-Modus wäre unsichtbar.
        searchField.allowsEditingTextAttributes = true

        // Stopp-Button links vom Suchfeld: bricht die laufende Suche ab.
        stopButton.image = NSImage(systemSymbolName: "stop.fill",
                                   accessibilityDescription: "Suche stoppen")
        stopButton.bezelStyle = .rounded
        stopButton.imagePosition = .imageOnly
        stopButton.toolTip = "Suche stoppen"
        stopButton.target = self
        stopButton.action = #selector(stopSearchClicked)
        stopButton.isEnabled = false
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                              for: .horizontal)

        folderButton.title = "📁 " + searchRoot.lastPathComponent + " ▾"
        folderButton.toolTip = searchRoot.path
        folderButton.target = self
        // Klick öffnet NICHT mehr direkt den Dateidialog, sondern ein
        // Popup-Menü (wie EasyFind): offene Finder-Fenster + wichtige Ordner
        // + „Anderer Ordner…". Ein ▾ signalisiert das Aufklappen.
        folderButton.action = #selector(showFolderMenu)

        archivesCheckbox.state = .on   // Archiv-Blick ist das Markenzeichen

        // Umschalter: „Dateien & Ordner" vorausgewählt; Wechsel sucht neu.
        typeControl.selectedSegment = 0
        typeControl.target = self
        typeControl.action = #selector(startSearch)

        // Regex-Umschalten färbt das Feld um (an) bzw. zurück (aus).
        regexCheckbox.target = self
        regexCheckbox.action = #selector(regexToggled)
        // „Genauer Name" wirkt sofort — sonst müsste man Return nachschieben.
        exactCheckbox.target = self
        exactCheckbox.action = #selector(startSearch)
        templatesButton.bezelStyle = .rounded
        templatesButton.target = self
        templatesButton.action = #selector(showTemplatesMenu(_:))

        // Statuszeile darf die Fensterbreite NICHT aufblähen: lange
        // Fortschritts-Pfade werden gekürzt, die Breite an den Stack gebunden.
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        onFinderColumnsShown = { [weak self] in self?.filterView.finderMetadata = true; self?.filters.refreshTitle() }
        buildTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        // Die Spalten dürfen zusammen breiter sein als das Fenster: Wer den
        // Pfad breit zieht, soll dafür nicht erst alle anderen Spalten
        // zusammenquetschen müssen. Der Rest läuft über den waagerechten
        // Balken. Bis 0.28.3 deckelte `lastColumnOnlyAutoresizingStyle` ohne
        // Scroller die Summe auf die Fensterbreite.
        scroll.hasHorizontalScroller = true
        installThumbnails(in: scroll, compact: false)
        scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                         for: .vertical)

        let topRow = NSStackView(views: [stopButton, searchField, folderButton])
        topRow.orientation = .horizontal
        modeControl.selectItem(at: 0)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        fieldPopup.addItem(withTitle: "Alle Textfelder")
        fieldPopup.menu?.addItem(.separator())
        for field in metadataFieldList() { fieldPopup.addItem(withTitle: field) }
        fieldPopup.isHidden = true      // erst im Modus „Metadaten"
        let optionsRow = NSStackView(views: [typeControl, modeControl,
                                             fieldPopup,
                                             archivesCheckbox, hiddenCheckbox,
                                             exactCheckbox, regexCheckbox,
                                             caseCheckbox, templatesButton])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 12

        // Maßzeile: „Bildmaße  Breite [min]–[max]  Höhe [min]–[max] px".
        for (field, placeholder) in [(minWidthField, "min"),
                                     (maxWidthField, "max"),
                                     (minHeightField, "min"),
                                     (maxHeightField, "max")] {
            field.placeholderString = placeholder
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.target = self
            field.action = #selector(startSearch)
            // Nur Return startet die Suche, nicht schon der Fokusverlust:
            // Sonst suchte ein Klick in die Trefferliste oder das Zuklappen
            // der Filter neu und leerte die Trefferliste. Eine Änderung hält
            // `controlTextDidChange` ohnehin als geänderte Kriterien fest.
            (field.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
            field.delegate = self
        }
        sizeRow = NSStackView(views: [
            NSTextField(labelWithString: "Bildmaße:"),
            NSTextField(labelWithString: "Breite"), minWidthField,
            NSTextField(labelWithString: "–"), maxWidthField,
            NSTextField(labelWithString: "Höhe"), minHeightField,
            NSTextField(labelWithString: "–"), maxHeightField,
            NSTextField(labelWithString: "px"),
        ])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        sizeRow.setCustomSpacing(14, after: sizeRow.views[4])

        filterView.onChange = { [weak self] in
            self?.stopSearchForChangedCriteria()
            self?.filters.refreshTitle()
        }
        // Aufklapp-Zeile: Dreieck plus klickbarer Titel, beide schalten um.
        criteriaControl.onChange = { [weak self] in self?.stopSearchForChangedCriteria() }
        let filterSpacer = NSView()
        filterSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filtersRow = NSStackView(views: [filters.disclosureButton, filters.titleButton,
                                            filterSpacer, duplicateCheckController.button, criteriaControl])
        filtersRow.orientation = .horizontal
        filtersRow.alignment = .centerY
        filtersRow.spacing = 2
        contentPreviewView.onRestart = { [weak self] in self?.startSearch() }
        let statusRow = NSStackView(views: [statusLabel, searchReportController.button])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        let stack = NSStackView(views: [topRow, optionsRow, filtersRow, sizeRow, filterView,
                                        resultFilter.view, resultGrouping.view, scroll, finderMetadataView, contentPreviewView, statusRow])
        // Erst NACH dem Einhängen in den Stack verstecken: `NSStackView(views:)`
        // hängt eine schon versteckte Ansicht sichtbar ein.
        filters.extraViews = [sizeRow]
        filters.restoreSavedState()
        contentPreviewView.syncVisibility()
        finderMetadataView.syncVisibility()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        // Bei offenen Filtern und beiden Vorschauen bleibt der Fensterabschluss
        // auch auf niedrigen Bildschirmen erreichbar; die Trefferliste scrollt.
        let preferredResultHeight = scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        preferredResultHeight.priority = .defaultHigh
        preferredResultHeight.isActive = true
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                          constant: -12),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filtersRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultFilter.view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resultGrouping.view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentPreviewView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            finderMetadataView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Statuszeile an die Stack-Breite binden → kann das Fenster nicht
            // in die Breite ziehen (langer „durchsuche …"-Pfad).
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        windowViewport = SearchWindowViewport(window: window)
        window.center()
        #if !FAVENIO_SELFTEST
        window.makeKeyAndOrderFront(nil)
        #endif
        window.makeFirstResponder(searchField)
    }

    /// Die beiden Datumsspalten. Sie laufen in Tabellenziffern, damit die
    /// Musterbreiten aus `dateColumnSamples` für jedes echte Datum gelten.
    static let dateColumns: Set<String> = ["modified", "created"]
    let dateFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    /// Je Datumsspalte die Breite, für die die Stufe zuletzt bestimmt wurde,
    /// und diese Stufe — die Messung läuft nur bei geänderter Breite.
    var dateStages: [String: (width: CGFloat, stage: Int)] = [:]

    func buildTable() {
        // (Identifier, Titel, Breite) — Reihenfolge = Spaltenreihenfolge:
        // die wichtigsten zuerst, damit der Pfad ohne Ziehen im Fenster
        // steht. Jede Spalte ist über einen sortDescriptorPrototype
        // sortierbar; der key zeigt auf compareHits() im Kern.
        let columns = [
            ("name", "Name", CGFloat(240)),
            ("size", "Größe", CGFloat(80)),
            ("path", "Pfad", CGFloat(300)),
            ("type", "Typ", CGFloat(130)),
            ("modified", "Änderungsdatum", CGFloat(130)),
            ("created", "Erstellungsdatum", CGFloat(130)),
            ("line", "Fundstelle", CGFloat(110)),
            ("dims", "Maße", CGFloat(84)),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 40
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: identifier, ascending: true)
            // Größe rechtsbündig (Zahlenspalte).
            if identifier == "size" {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        configureFinderColumns()
        // Keine automatische Anpassung: Die Summe der Spalten darf das
        // Fenster überragen (waagerechter Balken), und keine Spalte wird
        // beim Fensterziehen heimlich schmaler.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Breite und Reihenfolge der Spalten überleben den Neustart — wer
        // den Pfad einmal breit gezogen hat, soll das nicht wiederholen.
        #if !FAVENIO_SELFTEST
        tableView.autosaveName = "Favenio.hits.columns"
        tableView.autosaveTableColumns = true
        #endif
        // Beim Ziehen einer Datumsspalte deren Stufe neu bestimmen und die
        // sichtbaren Zellen neu formatieren.
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: tableView)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        // Rechtsklick-Menü: Inhalt wird je Klick in menuNeedsUpdate gebaut.
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        restoreFinderColumnVisibility()
    }

    // ---------- Fußzeile ----------

    /// Schreibt die Fußzeile aus dem aktuellen Zustand neu.
    func refreshStatus() {
        // Der Export ist unabhängig von der Suche. Ein später Exportabschluss
        // darf weder eine neue Suche noch deren Fehlerstatus überschreiben.
        let search = statusText()
        var text = exportStatus.map { search + " — " + $0 } ?? search
        // Genauso wenig gehört ein Vorlagenfehler zur Suche: Er steht davor
        // und verdrängt weder einen Suchfehler noch die Laufanzeige.
        if let templateFailure { text = templateFailure + " — " + text }
        showStatus(text)
    }

    /// Der EINZIGE Schreiber der Fußzeile. Text und Tooltip gehören
    /// zusammen: Das Feld kürzt in der Mitte, der Tooltip zeigt das Ganze —
    /// bis 0.34.18 setzten `presentActionIssue`, `removeFromResults` und
    /// `trashSelected` nur den Text, und daneben stand weiter der Tooltip
    /// der alten Kennzahlenzeile. Die Schnellsuche hat dafür längst
    /// `showInfo` als einzigen Schreiber samt Wächter.
    func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
    }

    /// Formuliert die Fußzeile: Kennzahlen der Trefferliste, dahinter — falls
    /// gerade etwas läuft oder abgebrochen wurde — der Zustand der Suche.
    func statusText() -> String {
        // Kriterienänderungen können die Anzeigephase ändern, aber sie
        // prüfen den aufgezeichneten Trefferstand nicht erneut.
        let recordedState: String?
        if let run = searchControl.run, run.origin == "recording" { recordedState = run.state }
        else if case .recorded(let state) = searchPhase { recordedState = state }
        else { recordedState = nil }
        if let state = recordedState {
            let label = ["completed": "abgeschlossen", "warnings": "mit Warnungen",
                         "cancelled": "abgebrochen", "failed": "fehlgeschlagen"][state] ?? state
            var text = "Aufgezeichneter Stand (" + label + ") — "
                + hitStatisticsText(statistics, selected: selectedHitIndices.count)
                + skippedNote(skippedCount) + (searchControl.run?.error.map { " — " + $0 } ?? "")
                + (isMaterializing ? " — " + Self.materializingNote : "")
            if case .failed(let reason) = searchPhase { text += " — " + reason }
            if let templateNote { text += " — " + templateNote }
            return text
        }
        if case .failed(let reason) = searchPhase { return reason }
        if hits.isEmpty {
            switch searchPhase {
            case .idle:
                return templateNote ?? "Bereit."
            case .running:
                return progressPath.map { "Durchsuche " + abbreviateHome($0) }
                    ?? "Suche läuft…"
            case .stopped:
                return resultFilter.sourceCount > 0
                    ? "Suche gestoppt. Der Ansichtsfilter blendet alle bisherigen Treffer aus."
                    : "Suche gestoppt. Bis zum Abbruch keine Treffer."
            case .finished:
                if resultFilter.sourceCount > 0 {
                    if let error = resultFilter.errorMessage { return error }
                    return resultFilter.isFiltering
                        ? "Ansichtsfilter wird angewendet…"
                        : "Der Ansichtsfilter blendet alle Treffer aus."
                }
                return seenHitIdentities.isEmpty
                    ? SearchReportSnapshot.emptyResultText(for: searchReportController.snapshot)
                    : "Die Trefferliste ist leer."
            default:
                return "Keine Treffer." + skippedNote(skippedCount)
            }
        }
        var text = hitStatisticsText(
            statistics, selected: selectedHitIndices.count)
        switch searchPhase {
        case .running:
            text += progressPath.map { " — durchsuche " + abbreviateHome($0) }
                ?? " — Suche läuft…"
        case .stopped:
            text += " — Suche gestoppt"
        case .handedOver:
            text += " — aus der Schnellsuche"
        default:
            break
        }
        if isMaterializing { text += " — " + Self.materializingNote }
        if let templateNote { text += " — " + templateNote }
        return text + skippedNote(skippedCount)
    }

    func setSearchRoot(_ url: URL) {
        setSearchRoots([url.path])
    }

    func setSearchRoots(_ paths: [String]) {
        searchRoots = paths
        let scope = SearchRoots(paths)
        folderButton.title = (scope.single.map { ($0 as NSString).lastPathComponent.isEmpty ? $0 : ($0 as NSString).lastPathComponent } ?? scope.title) + " ▾"
        folderButton.toolTip = scope.detail
    }

    @objc func editSearchRoots() {
        guard let window, window.attachedSheet == nil, rootsEditor == nil else { return }
        let editor = SearchRootsEditor(paths: searchRoots)
        rootsEditor = editor
        editor.present(on: window) { [weak self] paths in
            guard let self else { return }
            self.rootsEditor = nil
            guard let paths else { return }
            self.stopSearchForChangedCriteria()
            self.setSearchRoots(paths)
        }
    }

    // ---------- Suche (asynchron, streamend) ----------

    /// Klick auf den Ordner-Button: EasyFind-artiges Popup statt sofortigem
    /// Dateidialog. Ganz oben die offenen Finder-Fenster (vorderstes zuerst),
    /// darunter die wichtigsten Ordner, ganz unten „Anderer Ordner…".
    /// „Ansicht"-Menü: bündelt den Unsichtbare-Umschalter mit dem Finder-
    /// Kürzel Cmd+Shift+. (dieselbe Kombi wie im Finder).
    func installViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Ansicht")
        let hidden = NSMenuItem(title: "Unsichtbare Dateien",
                                action: #selector(toggleHidden),
                                keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = self
        viewMenu.addItem(hidden)
        viewItem.submenu = viewMenu
        // Vor „Bearbeiten" einsortieren (nach dem App-Menü).
        mainMenu.insertItem(viewItem, at: min(1, mainMenu.numberOfItems))
    }

    /// Cmd+Shift+. bzw. Menü: Unsichtbare-Checkbox umschalten und neu suchen.
    @objc func toggleHidden() {
        hiddenCheckbox.state = hiddenCheckbox.state == .on ? .off : .on
        startSearch()
    }

    private func refreshFinderFoldersAsync(forActivation: Bool = false) {
        finderScopeRefresh.refresh(forActivation: forActivation) { [weak self] outcome in
            guard let self else { return }
            self.finderScopeProblem = outcome.problemText
            if case .denied = outcome {
                self.finderScopeDenied = true
            } else {
                self.finderScopeDenied = false
            }
            if case .folders(let folders) = outcome {
                self.cachedFinderFolders = folders
            }
        }
    }

    /// Menüpunkt bei verweigerter Automation: direkt in die passende
    /// Systemeinstellung springen.
    @objc func openAutomationPrefs() { openAutomationSettings() }

    @objc func showFolderMenu() {
        // Für den nächsten Aufruf frisch laden, jetzt aber den Cache nehmen —
        // so hängt der Klick nie am (evtl. blockierenden) Finder-AppleScript.
        refreshFinderFoldersAsync()
        let menu = NSMenu()

        // 0) Scheiterte die letzte Finder-Abfrage, steht der Grund GANZ OBEN —
        //    auch wenn unten noch ältere Fenster aus dem Cache stehen. Ohne den
        //    Hinweis wirkte eine veraltete oder leere Liste wie die Wahrheit.
        if let problem = finderScopeProblem {
            let info = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            if finderScopeDenied {
                let fix = NSMenuItem(title: "Automatisierung erlauben…",
                                     action: #selector(openAutomationPrefs),
                                     keyEquivalent: "")
                fix.target = self
                menu.addItem(fix)
            }
            menu.addItem(.separator())
        }

        // 1) Offene Finder-Fenster. Der erste Eintrag ist das VORDERSTE
        //    Finder-Fenster. Bewusst „vorderstes" und nicht „aktives": Solange
        //    Favenio vorn ist, hat kein Finder-Fenster den Tastaturfokus.
        let windows = cachedFinderFolders
        for (index, path) in windows.enumerated() {
            let name = (path as NSString).lastPathComponent
            let title = index == 0 ? "Vorderstes Finder-Fenster — \(name)"
                                   : name
            addFolderItem(to: menu, title: title, path: path)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }

        // 2) Wichtige Ordner (feste, verständliche deutsche Namen).
        for (title, path) in commonFolders() {
            addFolderItem(to: menu, title: title, path: path)
        }

        // 3) Beliebiger Ordner über den Dateidialog (der frühere Direktweg).
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Suchbereiche bearbeiten…",
                               action: #selector(chooseFolder),
                               keyEquivalent: "")
        other.target = self
        menu.addItem(other)

        // Direkt unter dem Button aufklappen. In der (nicht gespiegelten)
        // Superview ist frame.minY die Unterkante des Buttons — von dort
        // wächst das Menü nach unten.
        if let host = folderButton.superview {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: folderButton.frame.minX,
                                   y: folderButton.frame.minY),
                       in: host)
        }
    }

    /// Ein Ordner-Eintrag mit Icon, Tooltip (Pfad, ~-gekürzt) und Häkchen,
    /// falls es der gerade aktive Suchordner ist.
    func addFolderItem(to menu: NSMenu, title: String, path: String) {
        let item = NSMenuItem(title: title, action: #selector(pickFolder(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.toolTip = abbreviateHome(path)
        // Providerabhängige eigene Ordnersymbole können die Quelle abfragen.
        let icon = localOnlyContent ? NSImage(named: NSImage.folderName) : NSWorkspace.shared.icon(forFile: path)
        icon?.size = NSSize(width: 16, height: 16)
        item.image = icon
        if path == searchRoot.path { item.state = .on }
        menu.addItem(item)
    }

    @objc func pickFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        setSearchRoot(URL(fileURLWithPath: path))
    }

    @objc func chooseFolder() {
        editSearchRoots()
    }

    // ---------- Benannte Suchvorlagen ----------
    //
    // Eine Vorlage ist ein vollständiger Suchauftrag: Name, Muster, der beim
    // Sichern gewählte Ordner und alle Optionen (SearchTemplate im Kern).
    // Die Regex-Vorlagen darunter sind etwas anderes — eine Einfügehilfe
    // fürs Suchfeld — und bleiben getrennt.

    var templateStore = SearchTemplateStore()
    var templates: [SearchTemplate] = []
    let templatesMenu = NSMenu(title: "Vorlagen")
    var templateManager: SearchTemplateManager?

    func installTemplatesMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let item = NSMenuItem()
        item.submenu = templatesMenu
        // Hinter „Ablage" — vor „Bearbeiten", falls es das gibt.
        let fileIndex = mainMenu.items.firstIndex { $0.submenu?.title == "Ablage" }
        mainMenu.insertItem(item, at: min(mainMenu.numberOfItems,
                                          (fileIndex ?? 1) + 1))
        reloadTemplates()
    }

    /// Grund, warum die Vorlagendatei zuletzt nicht lesbar war. Solange er
    /// steht, wird NICHT gesichert: Die Liste ist dann leer, und ein
    /// Sichern schriebe die Datei mit der einen neuen Vorlage — alle
    /// Vorlagen einer neueren Fassung wären weg.
    var templateLoadError: String?
    /// Die zuletzt von den Vorlagen selbst gesetzte Fehlermeldung. Sie steht
    /// NEBEN dem Zustand der Suche, nicht in ihm: Der Fehler der letzten Suche
    /// („favenio.py nicht gefunden.", Kernfehler) und eine laufende Suche
    /// bleiben daneben sichtbar. Zurückgenommen wird sie nur von einer
    /// gelungenen Vorlagenaktion oder vom nächsten Suchstart.
    var templateFailure: String?

    /// Liest die Vorlagendatei neu; ein Lesefehler steht in der Fußzeile,
    /// die Liste bleibt dann leer — nicht still eine alte.
    func reloadTemplates() {
        do {
            templates = try templateStore.load()
            templateLoadError = nil
            clearTemplateFailure()
        } catch {
            templates = []
            templateLoadError = "\(error)"
            failTemplates("Vorlagen nicht geladen: \(error)")
        }
        rebuildTemplatesMenu()
    }

    /// Meldet einen Vorlagenfehler, ohne den Zustand der Suche anzufassen.
    /// Die vorherige Vorlagenmeldung ist damit überholt und fällt weg.
    private func failTemplates(_ message: String) {
        templateFailure = message
        templateNote = nil
        refreshStatus()
    }

    /// Nimmt NUR den eigenen Vorlagenfehler zurück. Ein Suchfehler und eine
    /// laufende Suche gehören dem Runner und bleiben unberührt.
    private func clearTemplateFailure() {
        templateFailure = nil
    }

    func rebuildTemplatesMenu() {
        templatesMenu.removeAllItems()
        let save = templatesMenu.addItem(
            withTitle: "Suche als Vorlage sichern…",
            action: #selector(saveCurrentAsTemplate(_:)), keyEquivalent: "s")
        save.target = self
        let manage = templatesMenu.addItem(
            withTitle: "Vorlagen verwalten…",
            action: #selector(manageTemplates(_:)), keyEquivalent: "")
        manage.target = self
        guard !templates.isEmpty else { return }
        templatesMenu.addItem(.separator())
        for template in templates {
            let item = templatesMenu.addItem(
                withTitle: template.name,
                action: #selector(loadTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = template.name
            item.toolTip = templateSummary(template)
        }
    }

    /// Kurzbeschreibung für Tooltip und Verwaltung: Muster, Modus, Ordner.
    func templateSummary(_ template: SearchTemplate) -> String {
        var parts: [String] = []
        parts.append(template.pattern.isEmpty
            ? "ohne Muster" : "„\(template.pattern)“")
        parts.append(template.configuration.mode.rawValue)
        if let roots = template.roots { parts += roots.map(abbreviateHome) }
        let filters = template.configuration.filterSummary
        if !filters.isEmpty { parts.append(filters) }
        if !template.configuration.exclusions.isEmpty {
            parts.append("ohne " + template.configuration.exclusions.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    /// Die sichtbare Suche als Vorlage — Name im Dialog, Ordner ist der
    /// aktuell gewählte Suchordner. Ein vorhandener Name wird ersetzt.
    @objc func saveCurrentAsTemplate(_ sender: Any?) {
        let pattern = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let alert = NSAlert()
        alert.messageText = "Suche als Vorlage sichern"
        alert.informativeText = "Gespeichert werden Muster, Suchbereiche „\(SearchRoots(searchRoots).title)“ "
            + "und alle Optionen. Ein vorhandener Name wird ersetzt."
        let nameField = NSTextField(string: pattern)
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.placeholderString = "Name der Vorlage"
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        storeTemplate(SearchTemplate(name: name, pattern: pattern,
                                     roots: searchRoots,
                                     configuration: searchConfiguration))
    }

    /// Legt eine Vorlage an oder ersetzt die mit demselben Namen, schreibt
    /// die Datei und baut das Menü neu. Liefert die Fehlermeldung, falls
    /// die Datei nicht schreibbar war (dann bleibt die Liste unverändert).
    @discardableResult
    func storeTemplate(_ template: SearchTemplate) -> String? {
        // Der Dialog und der Headless-Test prüfen denselben Speicherpfad.
        guard !template.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            let message = "Vorlage nicht gesichert: kein Name."
            failTemplates(message)
            return message
        }
        var updated = templates
        if let index = updated.firstIndex(where: { $0.name == template.name }) {
            updated[index] = template
        } else {
            updated.append(template)
        }
        return commitTemplates(updated, note: "Vorlage „\(template.name)“ gesichert.")
    }

    func renameTemplate(_ name: String, to newName: String) -> String? {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { return "Vorlage nicht umbenannt: kein Name." }
        guard let index = templates.firstIndex(where: { $0.name == name }) else {
            return "Vorlage „\(name)“ gibt es nicht mehr."
        }
        guard newName == name || !templates.contains(where: { $0.name == newName }) else {
            return "Es gibt schon eine Vorlage „\(newName)“."
        }
        var updated = templates
        updated[index].name = newName
        return commitTemplates(updated, note: "Vorlage „\(newName)“ umbenannt.")
    }

    func deleteTemplate(_ name: String) -> String? {
        commitTemplates(templates.filter { $0.name != name },
                        note: "Vorlage „\(name)“ gelöscht.")
    }

    private func commitTemplates(_ updated: [SearchTemplate], note: String) -> String? {
        if let templateLoadError {
            let message = "Vorlage nicht gesichert — die Vorlagendatei ist "
                + "nicht lesbar und bliebe sonst überschrieben: " + templateLoadError
            failTemplates(message)
            return message
        }
        do {
            try templateStore.save(updated)
        } catch {
            let message = "\(error)"
            failTemplates(message)
            return message
        }
        templates = updated
        rebuildTemplatesMenu()
        templateManager?.reload()
        clearTemplateFailure()
        templateNote = note
        refreshStatus()
        return nil
    }

    /// Letzte Vorlagen-Meldung für die Fußzeile; die nächste Suche löscht sie.
    var templateNote: String?

    @objc func loadTemplate(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let template = templates.first(where: { $0.name == name }) else { return }
        applyTemplate(template)
    }

    /// Befüllt die Oberfläche aus der Vorlage — und startet KEINE Suche.
    /// Fehlende gespeicherte Bereiche bleiben deklariert und werden konkret
    /// genannt; eine neue Suche prüft die vollständige Liste.
    func applyTemplate(_ template: SearchTemplate) {
        // Nicht bloss `stopSearch()`: Das liesse bis zu 150 ms Nachschub
        // unsichtbar in `pending` liegen, den der naechste Suchstart dann
        // wegwirft. Anders als bei `replaceSearchResults` ist das hier kein
        // gewollter Listenwechsel — die Trefferliste bleibt ja stehen.
        stopSearchForChangedCriteria()
        cancelMaterializations(reportCancellation: false)
        applyConfiguration(template.configuration)
        searchField.stringValue = template.pattern
        // `applyConfiguration` faerbt zuletzt — aber noch den ALTEN Text.
        // Ohne diese Zeile stand ein geladenes Regex-Muster ungefaerbt im
        // Feld, bis der naechste Tastendruck kam. `insertTemplate` und
        // `handleFavenioURL` setzen den Text schon vor dem Faerben.
        recolorRegexField()
        var note = "Vorlage „\(template.name)“ geladen — ↩ startet die Suche."
        if let roots = template.roots { setSearchRoots(roots) }
        if let missing = template.missingRootMessage {
            note += " " + missing
        }
        // Ein Feld, das das Menü nicht kennt (andere Feldliste des Kerns),
        // fällt auf „Alle Textfelder" zurück — das steht dann dabei, statt
        // dass die Vorlage still breiter sucht als gespeichert.
        if template.configuration.mode == .metadata,
           let field = template.configuration.metadataField,
           selectedMetadataField != field {
            note += " Metadatenfeld „\(field)“ ist unbekannt — es gilt „Alle Textfelder“."
        }
        searchPhase = .idle
        progressPath = nil
        // Eine geladene Vorlage ist eine gelungene Vorlagenaktion: Sie nimmt
        // den vorherigen Vorlagenfehler zurück.
        clearTemplateFailure()
        templateNote = note
        refreshStatus()
        window?.makeFirstResponder(searchField)
    }

    @objc func manageTemplates(_ sender: Any?) {
        if templateManager == nil {
            templateManager = SearchTemplateManager(owner: self)
        }
        templateManager?.show()
    }

    // ---------- RegEx: Vorlagen + Syntaxfärbung ----------

    /// Klick auf „Regex-Vorlagen": aufklappende Liste nach Kategorien.
    @objc func showTemplatesMenu(_ sender: NSButton) {
        let menu = NSMenu()
        var lastCategory: String?
        for template in regexTemplates {
            if template.category != lastCategory {
                if lastCategory != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: template.category, action: nil,
                                        keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastCategory = template.category
            }
            let item = NSMenuItem(title: template.name,
                                  action: #selector(insertTemplate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = template.regex
            item.toolTip = "\(template.regex)   —   z. B. \(template.example)"
            menu.addItem(item)
        }
        if let host = sender.superview {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: sender.frame.minX, y: sender.frame.minY),
                       in: host)
        }
    }

    /// Vorlage übernehmen: ins Suchfeld setzen, Regex-Modus an, einfärben.
    @objc func insertTemplate(_ sender: NSMenuItem) {
        guard let regex = sender.representedObject as? String else { return }
        regexCheckbox.state = .on
        searchField.stringValue = regex
        window.makeFirstResponder(searchField)
        recolorRegexField()
    }

    /// Regex-Checkbox umgeschaltet → Feld ein-/ausfärben.
    @objc func regexToggled() { recolorRegexField() }

    /// Live-Färbung des Suchfelds beim Tippen (nur im Regex-Modus).
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, pixelFields.contains(where: { $0 === field }) {
            // Die sichtbare Konfiguration gehört ab jetzt zu einem neuen
            // Lauf. Alte Treffer dürfen keinen neuen Fehlerstatus überholen.
            stopSearchForChangedCriteria()
            filters.refreshTitle()
            return
        }
        guard notification.object as? NSSearchField === searchField else { return }
        recolorRegexField()
    }

    /// Färbt den Suchtext nach RegEx-Token-Art ein (Schema von Fastra) —
    /// oder setzt ihn auf die Standardfarbe zurück, wenn Regex aus ist.
    /// Verändert nur Farb-Attribute, nie den Text → Cursor bleibt stehen.
    func recolorRegexField() {
        let editor = searchField.currentEditor() as? NSTextView
        let text = editor?.string ?? searchField.stringValue
        let full = NSRange(location: 0, length: (text as NSString).length)
        let regexOn = regexCheckbox.state == .on
        let base: NSColor = regexOn ? RegexHighlighter.literalColor
                                    : .textColor

        if let storage = editor?.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: base, range: full)
            if regexOn {
                for (range, kind) in RegexHighlighter.tokenize(text) {
                    storage.addAttribute(.foregroundColor,
                                         value: RegexHighlighter.color(for: kind),
                                         range: range)
                }
            }
            storage.endEditing()
            editor?.typingAttributes[.foregroundColor] = base
        } else {
            // Feld nicht im Fokus → über den attributierten Wert färben.
            let attributed = NSMutableAttributedString(string: text)
            attributed.addAttribute(.foregroundColor, value: base, range: full)
            if regexOn {
                for (range, kind) in RegexHighlighter.tokenize(text) {
                    attributed.addAttribute(.foregroundColor,
                                            value: RegexHighlighter.color(for: kind),
                                            range: range)
                }
            }
            searchField.attributedStringValue = attributed
        }
    }

    override var resultFilterRoot: String? { SearchRoots(searchControl.run?.input.roots ?? searchRoots).single }
    override func flushResultFilterPending() { flushPending() }
    override func resultViewWillChange() {
        super.resultViewWillChange()
        searchControl.handoff.cancelPending()
        searchControl.changed()
    }
    override func replaceFilteredHits(_ incoming: [Hit], keepingSelection selection: Set<HitIdentity>) {
        hits = incoming
        statistics = .over(incoming)
        applyHitsToTable(keepingSelection: selection)
        refreshStatus()
    }
    override func appendFilteredHits(_ incoming: [Hit], keepingSelection selection: Set<HitIdentity>) {
        incoming.forEach { statistics.add($0) }
        if let comparator = hitComparator() { mergeSortedHits(incoming, using: comparator) }
        else { hits.append(contentsOf: incoming) }
        applyHitsToTable(keepingSelection: selection, resort: false)
        refreshStatus()
    }

    /// Ersetzt den Trefferstand für Suchstart und beide Quick-Übergaben.
    /// Vorlagen benutzen diesen Weg nicht: Sie ändern nur die Suchoptionen.
    func replaceSearchResults(_ incoming: [Hit]) {
        recordingComparison = nil
        stopSearch()
        resultFilter.clearForSearch()
        // Vorschau und Öffnen gehören zur alten Liste. Der Abbruch verhindert,
        // dass ein fertiger Auftrag später einen verschwundenen Treffer öffnet.
        cancelMaterializations(reportCancellation: false)
        hits = incoming
        pending = []
        seenHitIdentities = Set(incoming.map { $0.identity })
        trashedPaths = TrashedPaths()
        statistics = .over(incoming)
        skippedCount = 0
        progressPath = nil
        // Auch die leere Liste geht durch dieselbe Sortier-/Auswahlpflege.
        applyHitsToTable(keepingSelection: [])
        searchControl.imported(controlInput)
        searchReportController.begin(configuration: controlInput.object, state: "recorded")
    }

    @objc func startSearch() { startSearchWithReference(nil) }

    func startSearchWithReference(_ referenceTime: String?, comparing recording: SearchRecording? = nil) {
        replaceSearchResults([])
        recordingComparison = recording.map(RecordingComparison.init)
        searchControl.begin(controlInput)
        searchReportController.reset()
        searchPhase = .idle
        guard validatePixelInputs() else {
            if case .failed(let reason) = searchPhase { searchControl.failed(reason) }
            finishRecordingComparison()
            return
        }
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        // Ohne Muster nur dann suchen, wenn ein Maß- oder Faktenfilter gesetzt ist —
        // „alle Bilder über 1000 px" ist eine vollständige Frage.
        guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter else {
            searchControl.failed("Suchmuster oder positiver Filter fehlt.")
            refreshStatus()
            finishRecordingComparison()
            return
        }
        launchSearch(pattern: pattern, dateReferenceTime: referenceTime, frozenDateResolution: recording?.dateResolution)
        if activeSearchRun == nil { finishRecordingComparison() }
    }

    /// Setzt alle Suchoptionen der Oberfläche aus einer Konfiguration — die
    /// Gegenrichtung zu `searchConfiguration`. Genau EINE Stelle dafür; die
    /// Quick-Übergabe und das Laden einer Vorlage gehen beide hier durch.
    func applyConfiguration(_ configuration: SearchConfiguration) {
        criteriaControl.applyJSON(configuration.criteriaJSON)
        selectMode(configuration.mode)
        selectMetadataField(configuration.metadataField)
        for (field, text) in zip(pixelFields, configuration.pixelTexts) { field.stringValue = text }
        filterView.exclusions = configuration.exclusions
        filterView.dateRanges = configuration.dateRanges
        filterView.rawFacts = configuration.rawFacts
        filterView.terms = configuration.terms
        filterView.literalWildcards = configuration.literalWildcards
        filterView.textEncoding = configuration.textEncoding
        filterView.localOnly = configuration.localOnly
        filterView.ocr = configuration.ocr
        filterView.pdfOCR = configuration.pdfOCR
        filterView.pptxOCR = configuration.pptxOCR
        filterView.finderMetadata = configuration.finderMetadata
        // Übergebene Filter sollen sichtbar sein, sonst wundert man sich
        // über eine kürzere Trefferliste ohne erkennbaren Grund.
        if filters.activeCount > 0 { filters.setExpanded(true) }
        filters.refreshTitle()
        archivesCheckbox.state = configuration.archives ? .on : .off
        hiddenCheckbox.state = configuration.includeHidden ? .on : .off
        regexCheckbox.state = configuration.regex ? .on : .off
        caseCheckbox.state = configuration.caseSensitive ? .on : .off
        exactCheckbox.state = configuration.exact ? .on : .off
        typeControl.selectedSegment = ["both", "files", "dirs"].firstIndex(of: configuration.only) ?? 0
        recolorRegexField()
    }

    var searchConfiguration: SearchConfiguration {
        var configuration = SearchConfiguration()
        configuration.mode = selectedMode
        configuration.archives = archivesCheckbox.state == .on
        configuration.includeHidden = hiddenCheckbox.state == .on
        configuration.exact = exactCheckbox.state == .on
        configuration.literalWildcards = filterView.literalWildcards
        configuration.textEncoding = filterView.textEncoding
        configuration.localOnly = filterView.localOnly
        configuration.ocr = filterView.ocr
        configuration.pdfOCR = filterView.pdfOCR
        configuration.pptxOCR = filterView.pptxOCR
        configuration.finderMetadata = filterView.finderMetadata
        configuration.pixelTexts = pixelFields.map { $0.stringValue }
        configuration.exclusions = filterView.exclusions
        configuration.rawFacts = filterView.rawFacts
        configuration.dateRanges = filterView.dateRanges
        configuration.terms = filterView.terms
        configuration.regex = regexCheckbox.state == .on
        configuration.caseSensitive = caseCheckbox.state == .on
        configuration.metadataField = selectedMetadataField
        configuration.only = ["both", "files", "dirs"][max(0, min(2, typeControl.selectedSegment))]
        configuration.criteriaJSON = criteriaControl.queryJSON
        return configuration
    }

    var pixelFields: [NSTextField] {
        [minWidthField, maxWidthField, minHeightField, maxHeightField]
    }

    /// Kein Start und keine Übergabe darf ungültige sichtbare Grenzen ignorieren.
    @discardableResult
    func validatePixelInputs() -> Bool {
        let result = validatePixelFields(pixelFields)
        if let error = result.error {
            searchPhase = .failed(error)
            refreshStatus()
            return false
        }
        return true
    }

    var selectedMode: SearchTextMode {
        SearchTextMode.allCases[
            max(0, min(SearchTextMode.allCases.count - 1,
                       modeControl.indexOfSelectedItem))]
    }

    func selectMode(_ mode: SearchTextMode) {
        modeControl.selectItem(at: SearchTextMode.allCases.firstIndex(of: mode) ?? 0)
        fieldPopup.isHidden = mode != .metadata
    }

    /// Das gewählte Metadatenfeld — nil heißt „alle Textfelder".
    var selectedMetadataField: String? {
        guard selectedMode == .metadata, fieldPopup.indexOfSelectedItem > 0
        else { return nil }
        return fieldPopup.titleOfSelectedItem
    }

    func selectMetadataField(_ field: String?) {
        if let field, fieldPopup.itemTitles.contains(field) {
            fieldPopup.selectItem(withTitle: field)
        } else {
            fieldPopup.selectItem(at: 0)
        }
    }

    @objc func modeChanged() {
        fieldPopup.isHidden = selectedMode != .metadata
    }

    /// Fertige Treffer der Schnellsuche (≤20) sofort zeigen und die Suche
    /// hier LIVE fortsetzen. Die schon gezeigten Treffer werden über
    /// `seenHitIdentities` nicht doppelt gelistet.
    func continueSearch(from file: URL) {
        guard let payload = consumeQuickHandoffPayload(file) else {
            rejectQuickHandoff()
            return
        }
        continueSearch(payload: payload)
    }

    func continueSearch(payload: QuickHandoffPayload) {
        guard let payload = payload.bound(to: payload.roots ?? searchRoots) else {
            presentActionIssue(summary: "Die Herkunft der übergebenen Treffer passt nicht zu den Suchbereichen.", detail: nil)
            return
        }
        if let configuration = payload.configuration { applyConfiguration(configuration) }
        if let roots = payload.roots { setSearchRoots(roots) }
        replaceSearchResults(payload.hits)
        applyHitsToTable(keepingSelection: payload.selection)
        searchPhase = .handedOver
        guard validatePixelInputs() else { return }
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        // Wie startSearch(): ohne Muster nur weitersuchen, wenn ein
        // Maß- oder Faktenfilter gesetzt ist. Die Schnellsuche übergibt genau so eine
        // reine Maßsuche, und die Fortsetzung darf sie nicht abbrechen.
        guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter else {
            refreshStatus()
            return
        }
        launchSearch(pattern: pattern, dateReferenceTime: payload.configuration?.dateReferenceTime, frozenDateResolution: payload.dateResolution)
    }

    /// Startet den Suchprozess und streamt Treffer in die (evtl. schon per
    /// `continueSearch` vorbelegte) Tabelle. Setzt hits/seenHitIdentities NICHT
    /// zurück — das machen die Aufrufer je nach Fall.
    func launchSearch(pattern: String, dateReferenceTime: String? = nil, frozenDateResolution: Data? = nil) {
        let configuration = searchConfiguration.forNewRun(reference: dateReferenceTime)
        searchControl.begin(ControlSearchInput(pattern: pattern, roots: searchRoots,
                                              options: configuration))
        searchReportController.begin(configuration: searchControl.run?.input.object ?? controlInput.object)
        guard validatePixelInputs() else {
            if case .failed(let reason) = searchPhase { searchControl.failed(reason) }
            return
        }
        templateNote = nil
        clearTemplateFailure()
        exportStatus = nil
        // Kein Teilstart, wenn auch nur ein deklarierter Bereich fehlt.
        if let problem = SearchRoots(searchRoots).liveProblem {
            searchControl.failed(problem)
            searchReportController.end("failed")
            searchPhase = .failed(problem)
            refreshStatus()
            return
        }
        guard let arguments = configuration.arguments(
            pattern: pattern, roots: searchRoots, progress: true, frozenDateResolution: frozenDateResolution)
        else {
            searchControl.failed("favenio.py nicht gefunden.")
            searchReportController.end("failed")
            searchPhase = .failed("favenio.py nicht gefunden.")
            refreshStatus()
            return
        }

        let run = SearchRunner()
        activeSearchRun = run
        run.start(arguments: searchOutputArguments(arguments), onBatch: { [weak self, weak run] hits, progress in
            guard let self, let run, self.activeSearchRun === run else { return }
            if let progress {
                self.progressPath = progress
                self.refreshStatus()
            }
            self.enqueueSearchHits(hits)
        }, onReport: { [weak self, weak run] report in
            guard let self, let run, self.activeSearchRun === run else { return }
            self.searchReportController.accept(report)
        }, completion: { [weak self, weak run] exit in
            guard let self, let run, self.activeSearchRun === run else { return }
            self.finishSearchRun(run, exit: exit)
        })
        stopButton.isEnabled = true
        skippedCount = 0
        searchPhase = .running
        progressPath = nil
        refreshStatus()
        // Die Tabelle nicht bei jedem einzelnen Treffer neu laden,
        // sondern gebündelt ein paar Mal pro Sekunde.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15,
                                          repeats: true) { [weak self] _ in
            self?.flushPending()
        }
    }

    func stopSearch() {
        let run = activeSearchRun
        activeSearchRun = nil
        if run != nil { searchControl.cancelled(); searchReportController.end("cancelled") }
        run?.cancel()
        flushTimer?.invalidate()
        flushTimer = nil
        stopButton.isEnabled = false
    }

    /// Ein Filter oder Maßfeld wurde geändert: Der laufende Lauf gehört zu
    /// den alten Kriterien. Anhalten, aber die schon empfangenen Treffer
    /// noch zeigen — `stopSearch()` allein ließ bis zu 150 ms Nachschub
    /// unsichtbar in `pending` liegen, während die Fußzeile ihn mitzählte.
    /// Ein Fehler der Maßfelder bleibt stehen, solange er besteht.
    func stopSearchForChangedCriteria() {
        stopSearch()
        flushPending()
        progressPath = nil
        if validatePixelInputs() {
            searchPhase = .idle
        }
        refreshStatus()
        finishRecordingComparison()
    }

    /// Klick auf den Stopp-Button: laufende Suche abbrechen.
    @objc func stopSearchClicked() {
        guard activeSearchRun != nil else { return }
        stopSearch()
        searchPhase = .stopped
        progressPath = nil
        flushPending()
        refreshStatus()
        finishRecordingComparison()
    }

    /// Sortieren, neu laden und dieselben Treffer wieder auswählen.
    ///
    /// Jede Trefferübernahme muss hier durch: `continueSearch()` und
    /// `loadResults()` luden vorher einfach neu und wandten eine bereits
    /// aktive Sortierung nicht an. Enthielt der fortgesetzte Lauf nur die
    /// übergebenen Treffer, blieb `pending` leer, `flushPending()` lief nie —
    /// und die Kopfzeile zeigte eine Sortierung, der die Liste nicht folgte
    /// (Review-Fund 2026-08-17).
    ///
    /// `reloadData()` behält die Auswahl nach ZEILENNUMMER. Nach Sortieren,
    /// Entfernen oder einer Übergabe aus der Schnellsuche zeigt dieselbe
    /// Nummer auf einen anderen Treffer; deshalb wird die Auswahl vorher
    /// geleert und danach ausschließlich über die Trefferidentität gesetzt — auch bei
    /// leerer Auswahlmenge (Review-Fund 2026-09-02). Die Zwischenschritte lösen
    /// keine Auswahl-Benachrichtigung aus, sonst flackerte die Vorschau bei
    /// jedem Nachschub; am Ende wird sie nur nachgeladen, wenn sie jetzt
    /// andere Dateien meint.
    func applyHitsToTable(keepingSelection selectedIdentities: Set<HitIdentity>,
                          resort: Bool = true) {
        searchControl.changed()
        if resort { sortHits() }
        isRestoringSelection = true
        resultGrouping.rebuild()
        tableView.deselectAll(nil)
        tableView.reloadData()
        let rows = tableRows(for: selectedIdentities)
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isRestoringSelection = false
        contextRow = -1
        refreshContentPreview()
        reloadPreviewIfSelectionChanged()
        resultFilter.refresh()
    }

    /// Nimmt neue Treffer des aktuellen Laufs an. Bewusst entfernte oder
    /// in den Papierkorb gelegte Dateien dürfen nicht erneut erscheinen.
    func enqueueSearchHits(_ incoming: [Hit]) {
        let scope = SearchRoots(searchControl.run?.input.roots ?? searchRoots)
        for original in incoming {
            guard let hit = scope.carrying(original) else { continue }
            recordingComparison?.accept(hit)
            guard !trashedPaths.contains(hit.filesystemPath) else { continue }
            if seenHitIdentities.insert(hit.identity).inserted { pending.append(hit) }
        }
    }

    /// Offene Vorschau nachziehen, wenn die Auswahl jetzt andere Dateien
    /// meint als die, die sie zeigt.
    func reloadPreviewIfSelectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return }
        refreshPreview()
    }

    /// Ladezustand des Auspackens in der Fußzeile (Teil von statusText).
    override func presentMaterializationState() { refreshStatus() }

    func flushPending() {
        guard !pending.isEmpty else { return }
        if resultFilter.isActive {
            let incoming = pending
            pending = []
            resultFilter.append(incoming)
            searchControl.changed()
            refreshStatus()
            return
        }
        // Auswahl über den reloadData hinweg festhalten (sonst verliert man
        // beim Streamen sofort wieder die markierte Zeile — etwa fürs
        // QuickLook). Wir merken die Identitäten und stellen sie danach wieder her.
        let selectedIdentities = selectedHitIdentities()
        // Kennzahlen FORTSCHREIBEN statt neu aufsummieren: Bei einem langen
        // Lauf wird diese Methode viele Male aufgerufen, und jedes Mal die
        // ganze Liste durchzurechnen kostete quadratisch.
        for hit in pending { statistics.add(hit) }
        if let comparator = hitComparator() {
            mergeSortedHits(pending, using: comparator)
        } else {
            hits.append(contentsOf: pending)
        }
        pending = []
        // `resort: false`: Die Liste ist gerade schon in der richtigen
        // Ordnung — entweder eingemischt oder unsortiert angehängt.
        applyHitsToTable(keepingSelection: selectedIdentities, resort: false)
        refreshStatus()
    }

    func finishSearchRun(_ run: SearchRunner, exit: SearchExit) {
        guard activeSearchRun === run else { return }
        searchControl.finished(exit)
        searchReportController.end(searchExitIsError(exit.status, reason: exit.reason) ? "failed" : "finished", exit: exit)
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        activeSearchRun = nil
        stopButton.isEnabled = false
        progressPath = nil
        skippedCount = exit.warningCount
        searchPhase = searchExitIsError(exit.status, reason: exit.reason)
            ? .failed(searchFailureText(exit)) : .finished
        refreshStatus()
        finishRecordingComparison()
    }

    // ---------- Tabelle ----------

    func numberOfRows(in tableView: NSTableView) -> Int { resultTableRowCount }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        resultGrouping.projection.group(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        hitIndex(forTableRow: row) != nil
    }

    /// Welche Datumsstufe eine Datumsspalte bei ihrer aktuellen Breite
    /// zeigt. Die Zelle hat je 2 pt Rand, und ein Muster, das haargenau
    /// passt, kürzte AppKit trotzdem mit „…" — deshalb 8 pt Luft.
    func dateStage(for column: NSTableColumn) -> Int {
        let key = column.identifier.rawValue
        if let known = dateStages[key], known.width == column.width {
            return known.stage
        }
        let stage = dateColumnStage(forWidth: column.width - 8,
                                    font: dateFont)
        dateStages[key] = (column.width, stage)
        return stage
    }

    @objc func columnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"]
                as? NSTableColumn,
              Self.dateColumns.contains(column.identifier.rawValue),
              let previous = dateStages[column.identifier.rawValue]?.stage
        else { return }
        guard dateStage(for: column) != previous else { return }
        let columnIndex = tableView.column(withIdentifier: column.identifier)
        guard columnIndex >= 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn:
                visible.location ..< visible.location + visible.length),
            columnIndexes: IndexSet(integer: columnIndex))
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        if let header = resultGrouping.header(at: row) { return header }
        // Zellbau samt Bereichsprüfung in der Basisklasse — dort steht
        // auch, warum `row < hits.count` Pflicht ist.
        guard let column = tableColumn,
              let cell = hitCell(tableView, column: column, row: row)
        else { return nil }
        guard let index = hitIndex(forTableRow: row) else { return nil }
        let hit = hits[index]
        // Zellen werden recycelt → Ausrichtung je Spalte neu setzen.
        let identifier = column.identifier.rawValue
        cell.textField?.alignment =
            ["size", "dims"].contains(identifier) ? .right : .left
        // Der Pfad wird AM ANFANG gekürzt: Das Ende — der Ordner, in dem
        // die Datei liegt — ist der Teil, der unterscheidet; der Anfang
        // ist bei allen Treffern derselbe Suchordner.
        cell.textField?.lineBreakMode =
            identifier == "path" ? .byTruncatingHead : .byTruncatingMiddle
        cell.textField?.font = Self.dateColumns.contains(identifier)
            ? dateFont : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cell.textField?.toolTip = nil
        if renderFinderColumn(column, cell: cell, hit: hit) { return cell }
        switch identifier {
        case "name":
            cell.textField?.stringValue = hit.displayName
        case "type":
            cell.textField?.stringValue = hit.typeDescription
        case "size":
            cell.textField?.stringValue = humanSize(hit.size)
        case "line":
            // Zeilennummer bei Inhaltstreffern, „Feld: Wert" bei Metadaten.
            cell.textField?.stringValue = hit.locationText
        case "dims":
            cell.textField?.stringValue = hit.dimensionsText
        case "modified":
            cell.textField?.stringValue =
                formatDateColumn(hit.modified, stage: dateStage(for: column))
        case "created":
            cell.textField?.stringValue =
                formatDateColumn(hit.created, stage: dateStage(for: column))
        default:
            // Nur der Ordner, relativ zum Suchordner — der Dateiname steht
            // schon in der ersten Spalte, der Suchordner im Ordnerknopf.
            cell.textField?.stringValue =
                hit.folderText(relativeTo: resultFilterRoot ?? "/", showSearchRoot: resultFilterRoot == nil)
            cell.textField?.toolTip = hit.isMember ? archiveChainText(for: hit) : hit.folderPath
        }
        return cell
    }

    /// Header-Klick: Trefferliste nach der gewählten Spalte sortieren.
    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyHitsToTable(keepingSelection: selectedHitIdentities())
    }

    /// Fügt frische Treffer in die BEREITS sortierte Liste ein.
    ///
    /// Vorher sortierte jeder Nachschub die ganze Liste neu — der Flush
    /// läuft alle 0,15 s, also bis zu siebenmal pro Sekunde. Der Aufwand
    /// wuchs damit über den Lauf hinweg quadratisch: Bei 100 000 Treffern
    /// kostete ein einzelner Sortierlauf 1,2 s auf dem Main-Thread (vor
    /// dem Typ-Zwischenspeicher sogar 46,6 s), und das siebenmal je
    /// Sekunde. Einsortieren ist dagegen linear: Der Nachschub wird
    /// einmal sortiert und dann zusammengeführt.
    func mergeSortedHits(_ fresh: [Hit],
                         using comparator: (Hit, Hit) -> Bool) {
        hits = mergingSortedValues(hits, fresh, using: comparator)
    }

    /// Drag & Drop: Was schon als Datei vorliegt — jede normale Datei, jeder
    /// schon ausgepackte Eintrag —, geht als URL ins Pasteboard. Ein noch
    /// nicht ausgepackter Archiv-Eintrag geht als DATEIVERSPRECHEN
    /// (`NSFilePromiseProvider`): AppKit will in diesem Callback sofort eine
    /// Antwort, und bis 0.31.4 wurde deshalb hier synchron ausgepackt — beim
    /// Anfassen der Zeile, auf dem Main-Thread. Das Versprechen löst der
    /// Empfänger (Finder) erst beim Ablegen ein; dann packt derselbe
    /// Manager im Hintergrund aus (`filePromiseProvider(_:writePromiseTo:)`).
    /// Abwägung in `tests/MATERIALIZATION_MEASUREMENTS.md`.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = hitIndex(forTableRow: row) else { return nil }
        return hitPasteboardWriter(index)
    }

    // ---------- Aktionen (Doppelklick, Kontextmenü) ----------

    /// Zeilen, auf die sich eine Aktion bezieht: die Auswahl, oder —
    /// falls außerhalb der Auswahl geklickt wurde — die geklickte Zeile.
    /// Was sich nicht öffnen ließ, steht in der Fußzeile.
    override func presentActionIssue(summary: String, detail: String?) {
        showStatus(detail.map { summary + " " + $0 } ?? summary)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard populateHitMenu(menu) else { return }
        addFastraMenuItems(to: menu)
        // Dieselben Listen-Aktionen wie im Ablage-Menü, mit denselben
        // Kürzeln daneben. Sie hängen nicht an einer öffenbaren Datei: Auch
        // ein Ordner im Archiv lässt sich aus der Liste werfen.
        menu.addItem(.separator())
        addResultListItems(to: menu)
    }

    /// Die drei Punkte, die auf die Trefferliste wirken — einmal gebaut, in
    /// beiden Menüs verwendet. Gebaut werden sie im Kern; hier stehen nur die
    /// Methoden, die sie aufrufen sollen.
    func addResultListItems(to menu: NSMenu) {
        populateResultListMenu(
            menu, target: self,
            selectors: ResultListMenuSelectors(
                exportSelection: #selector(exportSelectedHits(_:)),
                removeFromList: #selector(removeFromResults(_:)),
                moveToTrash: #selector(trashSelected(_:))))
    }

    // ---------- Trefferliste verfeinern, exportieren, löschen ----------

    /// „Ablage"-Menü: Export, Entfernen aus der Trefferliste und Papierkorb.
    /// Die Tastenkürzel stehen hier sichtbar daneben, damit sie niemand
    /// erraten muss.
    func installFileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Ablage")
        let exportAll = fileMenu.addItem(
            withTitle: "Alle Treffer exportieren…",
            action: #selector(exportAllHits(_:)), keyEquivalent: "e")
        exportAll.target = self
        fileMenu.addItem(.separator())
        for (title, action) in [("Suchstand aufzeichnen…", #selector(saveSearchRecording)),
                                ("Suchaufzeichnung öffnen…", #selector(openSearchRecording)),
                                ("Suche erneut ausführen und vergleichen", #selector(rerunSearchRecording))] {
            fileMenu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        fileMenu.addItem(.separator())
        addFastraMenuItems(to: fileMenu)
        fileMenu.addItem(.separator())
        addResultListItems(to: fileMenu)
        fileItem.submenu = fileMenu
        // Direkt hinter das App-Menü, also vor „Ansicht".
        mainMenu.insertItem(fileItem, at: min(1, mainMenu.numberOfItems))
    }

    /// Zeilen, die eine Menüaktion meint.
    ///
    /// Aus dem Rechtsklick-Menü der Tabelle gilt die AppKit-Konvention: Ein
    /// Klick außerhalb der Auswahl meint nur die geklickte Zeile. Aus dem
    /// Hauptmenü und vom Tastenkürzel gilt dagegen immer die Auswahl — dort
    /// gibt es keinen Klickort, und ein liegengebliebener `contextRow` eines
    /// früheren Rechtsklicks träfe sonst die falschen Dateien.
    func rows(for sender: Any?) -> [Int] {
        if let item = sender as? NSMenuItem, item.menu === tableView.menu {
            return actionRows()
        }
        return selectedHitIndices
    }

    /// Die Treffer zu einer Zeilenmenge, in Listenreihenfolge.
    func hitsAtRows(_ rows: [Int]) -> [Hit] {
        rows.sorted().compactMap { hits.indices.contains($0) ? hits[$0] : nil }
    }

    /// Ein ungültiger Menüpunkt gibt sein Tastenkürzel wieder frei. Genau
    /// deshalb löscht ⌫ im Suchfeld weiter ein Zeichen und ⌘⌫ dort weiter bis
    /// zum Zeilenanfang, statt an Dateien zu gehen: Beide Punkte gelten nur,
    /// solange die Trefferliste den Fokus hat. Im Rechtsklick-Menü der
    /// Trefferansicht entfällt diese Bedingung — dort ist der Bezug der Klick.
    ///
    /// Dieselbe Bedingung wie beim Tastaturmonitor: Das Hauptfenster muss das
    /// Tastaturfenster sein. Solange ein Blatt oder ein Alert offen ist,
    /// bleiben alle vier Punkte grau — sonst startete ⌘⌫ aus dem Exportdialog
    /// heraus einen zweiten Papierkorb-Dialog. „Alle Treffer exportieren"
    /// braucht keine Auswahl und deshalb auch keinen Fokus in der Trefferansicht.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let fromTableMenu = item.menu === tableView.menu
        let mainWindowIsKey = window?.isKeyWindow == true
        switch item.action {
        case #selector(saveSearchRecording):
            return mainWindowIsKey && !exportIsBusy && activeSearchRun == nil
                && searchControl.run.map { $0.origin == "live" && $0.state != "running" } == true
        case #selector(openSearchRecording):
            return mainWindowIsKey && activeSearchRun == nil && !searchControl.handoff.busy
        case #selector(rerunSearchRecording):
            return mainWindowIsKey && searchControl.openedRecording != nil
        case #selector(showSelectedInFastra(_:)):
            let indices = rows(for: item)
            return (fromTableMenu || (mainWindowIsKey && resultListHasFocus))
                && indices.count == 1 && hits.indices.contains(indices[0]) && !hits[indices[0]].isDirectory
                && searchControl.run != nil && !searchControl.handoff.busy
        case #selector(cancelFastraHandoff(_:)):
            return (fromTableMenu || mainWindowIsKey) && searchControl.handoff.busy
        case #selector(removeFromResults(_:)), #selector(trashSelected(_:)):
            guard fromTableMenu
                    || (mainWindowIsKey
                        && resultListHasFocus)
            else { return false }
            return !rows(for: item).isEmpty
        case #selector(exportSelectedHits(_:)):
            guard !exportIsBusy,
                  fromTableMenu || (mainWindowIsKey && resultListHasFocus)
            else { return false }
            return !rows(for: item).isEmpty
        case #selector(exportAllHits(_:)):
            item.title = resultGrouping.isActive ? "Alle gefilterten Treffer exportieren…"
                : resultFilter.isActive ? "Sichtbare Treffer exportieren…" : "Alle Treffer exportieren…"
            return !exportIsBusy && mainWindowIsKey && !hits.isEmpty
        default:
            return super.validateMenuItem(item)
        }
    }

    /// ⌫ bzw. Menü: Treffer nur aus der ANZEIGE werfen. Die Dateien bleiben
    /// unangetastet — das dient dem schrittweisen Verfeinern der Liste, bis
    /// nur noch übrig ist, was wirklich gemeint war.
    @objc func removeFromResults(_ sender: Any?) {
        let doomed = Set(hitsAtRows(rows(for: sender)).map { $0.identity })
        guard !doomed.isEmpty else {
            showStatus("Kein Treffer ausgewählt.")
            return
        }
        let removed = removeHits { doomed.contains($0.identity) }
        showStatus(removed == 1
            ? "1 Treffer aus der Liste entfernt — die Datei bleibt."
            : "\(groupedNumber(removed)) Treffer aus der Liste entfernt — "
                + "die Dateien bleiben.")
    }

    /// Entfernt Treffer aus der Liste und stellt Kennzahlen, Sortierung und
    /// Auswahl wieder her. Danach steht die Auswahl auf der Zeile, die an die
    /// Stelle der ersten entfernten gerückt ist.
    @discardableResult
    func removeHits(where shouldRemove: (Hit) -> Bool) -> Int {
        resultFilter.remove(where: shouldRemove)
        guard let firstRemoved = hits.firstIndex(where: shouldRemove) else {
            return 0
        }
        let before = hits.count
        hits.removeAll(where: shouldRemove)
        // `seenHitIdentities` bleibt unangetastet: Ein noch laufender Suchlauf soll
        // einen bewusst entfernten Treffer nicht gleich wieder einfügen.
        statistics = .over(hits)
        applyHitsToTable(keepingSelection: [])
        if !hits.isEmpty, let row = tableRow(forHitIndex: min(firstRemoved, hits.count - 1)) {
            tableView.selectRowIndexes(
                [row], byExtendingSelection: false)
        }
        refreshStatus()
        return before - hits.count
    }

    /// ⌘⌫ bzw. Menü: Die ausgewählten Dateien in den Papierkorb legen — nach
    /// Rückfrage, in EINEM `recycle`-Aufruf (damit auch eine sehr große
    /// Auswahl nicht Datei für Datei abgearbeitet wird) und mit dem
    /// Papierkorb-Geräusch des Finders.
    @objc func trashSelected(_ sender: Any?) {
        let targets = hitsAtRows(rows(for: sender))
        let split = trashableHits(targets)
        guard !split.trashable.isEmpty else {
            showStatus(targets.isEmpty
                ? "Kein Treffer ausgewählt."
                : "Einträge in einem Archiv lassen sich nicht löschen.")
            return
        }
        let text = trashConfirmationText(trashable: split.trashable,
                                         skipped: split.skipped)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        trashHits(split.trashable) { [weak self] trashed, error in
            guard let self else { return }
            guard !trashed.isEmpty else {
                self.showStatus("Nichts in den Papierkorb "
                    + "gelegt: " + (error?.localizedDescription
                                    ?? "unbekannter Fehler"))
                return
            }
            playFinderTrashSound()
            // Mit einem Archiv verschwinden auch seine Einträge aus der
            // Liste, mit einem Ordner alles darunter: Hinter ihnen liegt
            // jetzt keine Datei mehr. Dasselbe gilt für schon vorgemerkte
            // und für noch eintreffende Treffer des laufenden Suchprozesses.
            for hit in split.trashable where trashed[hit.filesystemPath] != nil {
                self.trashedPaths.insert(hit.filesystemPath,
                                         isDirectory: hit.isDirectory)
            }
            self.pending.removeAll {
                self.trashedPaths.contains($0.filesystemPath)
            }
            self.removeHits { self.trashedPaths.contains($0.filesystemPath) }
            let failed = split.trashable.count - trashed.count
            let moved = "\(groupedNumber(trashed.count)) in den Papierkorb "
                + "gelegt"
            self.showStatus(failed == 0
                ? moved + "."
                : moved + ", \(groupedNumber(failed)) nicht: "
                    + (error?.localizedDescription ?? "unbekannter Fehler"))
        }
    }

    @objc func exportAllHits(_ sender: Any?) {
        guard !exportIsBusy else { return }
        runExport(hits, scope: resultGrouping.isActive ? "alle gefilterten Treffer einschließlich eingeklappter Gruppen"
            : resultFilter.isActive ? "sichtbare Treffer" : "alle Treffer")
    }

    @objc func exportSelectedHits(_ sender: Any?) {
        guard !exportIsBusy else { return }
        runExport(hitsAtRows(rows(for: sender)), scope: "Auswahl")
    }

    /// Vorschlag für den Dateinamen: der Suchbegriff, von allem befreit, was
    /// in einem Dateinamen nichts zu suchen hat.
    func exportBaseName() -> String {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Favenio-Treffer" }
        let cleaned = query.components(
            separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(
                separator: "-")
        return "Favenio-" + String(cleaned.prefix(60))
    }

    /// Sichern-Dialog mit Format-Aufklappmenü und anschließendes Schreiben.
    func runExport(_ selected: [Hit], scope: String) {
        guard !exportIsBusy else { return }
        guard !selected.isEmpty else {
            exportStatus = "Kein Treffer zum Exportieren."
            refreshStatus()
            return
        }
        let formats = HitExportFormat.allCases
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0,
                                                width: 340, height: 26))
        formats.forEach { popUp.addItem(withTitle: $0.title) }
        popUp.target = self
        popUp.action = #selector(exportFormatChanged(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popUp])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        let panel = NSSavePanel()
        panel.message = "Trefferliste exportieren (\(scope))"
        panel.nameFieldStringValue = exportBaseName() + "."
            + formats[0].fileExtension
        panel.accessoryView = row
        exportSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.exportSavePanel = nil
            guard response == .OK, let url = panel.url,
                  let self else { return }
            let format = formats[max(0, popUp.indexOfSelectedItem)]
            self.exportStatus = "Export läuft: \(groupedNumber(selected.count)) Treffer…"
            self.refreshStatus()
            self.exportWriter.write(selected, format: format, to: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.exportStatus = "\(groupedNumber(selected.count)) Treffer exportiert: "
                        + abbreviateHome(url.path)
                case .failure(let error):
                    self.exportStatus = "Export fehlgeschlagen: " + error.localizedDescription
                }
                self.refreshStatus()
            }
        }
    }

    /// Anderes Format gewählt → Endung im Dateinamen mitziehen.
    @objc func exportFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = exportSavePanel else { return }
        let format = HitExportFormat.allCases[
            max(0, sender.indexOfSelectedItem)]
        let base = (panel.nameFieldStringValue as NSString)
            .deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.fileExtension
    }
}

// MARK: - RegEx-Syntaxfärbung (Farbschema von Fastra übernommen)
//
// Fastra tokenisiert mit tree-sitter; das ist für Favenios Ein-Datei-Prinzip
// zu schwer. Hier ein schlanker linearer Scanner, der dieselben Token-Arten
// und exakt dieselben Farben (Fastra Theme/RegexFieldView) liefert.

enum RegexTokenKind {
    case anchor          // ^ $ \b \B
    case characterClass  // [...] \d \w \s .
    case quantifier      // * + ? {n,m}
    case groupDelimiter  // ( ) (?: (?<name> (?= …
    case alternation     // |
    case escape          // \. \n \t …
    case backreference   // \1 \k<name>
    case error           // unvollständig (offene Klasse, Backslash am Ende)
}

enum RegexHighlighter {
    /// Basisfarbe für gewöhnliche Zeichen (Lesbarkeit, kein Akzent).
    static let literalColor = NSColor.textColor

    /// Dynamische Farbe je Token-Art — Werte 1:1 aus Fastra.
    static func color(for kind: RegexTokenKind) -> NSColor {
        func pair(_ l: (Int, Int, Int), _ d: (Int, Int, Int)) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua
                let (r, g, b) = dark ? d : l
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                               blue: CGFloat(b) / 255, alpha: 1)
            }
        }
        switch kind {
        case .anchor:         return pair((0xA3, 0x39, 0x2A), (0xE8, 0x8D, 0x7C))
        case .characterClass: return pair((0x2A, 0x66, 0xB5), (0x7F, 0xB0, 0xEE))
        case .quantifier:     return pair((0xB5, 0x6C, 0x1A), (0xDF, 0xA2, 0x5A))
        case .groupDelimiter: return pair((0x70, 0x20, 0xA0), (0xC0, 0x8A, 0xE8))
        case .alternation:    return pair((0x1A, 0x40, 0x80), (0x86, 0xA9, 0xE0))
        case .escape:         return pair((0x2F, 0x5D, 0x3A), (0x94, 0xCE, 0x9F))
        case .backreference:  return pair((0xA4, 0x66, 0xD9), (0xC0, 0x9A, 0xE8))
        case .error:          return pair((0xCC, 0x00, 0x00), (0xFF, 0x6B, 0x5E))
        }
    }

    /// Zerlegt das Muster in gefärbte Token. Gewöhnliche Zeichen werden NICHT
    /// als Token ausgegeben — sie behalten die Basisfarbe. Ranges sind
    /// UTF-16-NSRange (dieselbe Einheit wie NSTextStorage).
    static func tokenize(_ pattern: String) -> [(NSRange, RegexTokenKind)] {
        let s = pattern as NSString
        let n = s.length
        var i = 0
        var out: [(NSRange, RegexTokenKind)] = []
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        func push(_ location: Int, _ length: Int, _ kind: RegexTokenKind) {
            out.append((NSRange(location: location, length: length), kind))
        }
        while i < n {
            let c = s.character(at: i)
            switch c {
            case 0x5C:   // \  Backslash-Sequenz
                if i + 1 >= n { push(i, 1, .error); i += 1; break }
                let d = s.character(at: i + 1)
                switch d {
                case 0x62, 0x42:                               // b B → Anker
                    push(i, 2, .anchor); i += 2
                case 0x64, 0x44, 0x77, 0x57, 0x73, 0x53:       // d D w W s S
                    push(i, 2, .characterClass); i += 2
                case 0x31...0x39:                              // \1..\9
                    var j = i + 1
                    while j < n && isDigit(s.character(at: j)) { j += 1 }
                    push(i, j - i, .backreference); i = j
                case 0x6B:                                     // \k<name>
                    var j = i + 2
                    if j < n && s.character(at: j) == 0x3C {
                        while j < n && s.character(at: j) != 0x3E { j += 1 }
                        if j < n { j += 1 }
                    }
                    push(i, j - i, .backreference); i = j
                default:
                    push(i, 2, .escape); i += 2                // \. \n \( …
                }
            case 0x5E, 0x24:                                   // ^ $
                push(i, 1, .anchor); i += 1
            case 0x2E:                                         // .
                push(i, 1, .characterClass); i += 1
            case 0x5B:                                         // [  Zeichenklasse
                var j = i + 1
                if j < n && s.character(at: j) == 0x5E { j += 1 }   // ^
                if j < n && s.character(at: j) == 0x5D { j += 1 }   // ] direkt am Anfang
                while j < n && s.character(at: j) != 0x5D {
                    if s.character(at: j) == 0x5C { j += 1 }         // Escape überspringen
                    j += 1
                }
                if j < n { push(i, j - i + 1, .characterClass); i = j + 1 }
                else { push(i, n - i, .error); i = n }              // offen → Fehler
            case 0x28:                                         // (  Gruppe
                var len = 1
                if i + 1 < n && s.character(at: i + 1) == 0x3F {    // (?
                    if i + 2 < n {
                        let e = s.character(at: i + 2)
                        if e == 0x3A || e == 0x3D || e == 0x21 {     // (?: (?= (?!
                            len = 3
                        } else if e == 0x3C {                        // (?<
                            if i + 3 < n && (s.character(at: i + 3) == 0x3D
                                             || s.character(at: i + 3) == 0x21) {
                                len = 4                              // (?<= (?<!
                            } else {                                 // (?<name>
                                var j = i + 3
                                while j < n && s.character(at: j) != 0x3E { j += 1 }
                                if j < n { j += 1 }
                                len = j - i
                            }
                        } else { len = 2 }                           // (?flags
                    } else { len = 2 }
                }
                push(i, len, .groupDelimiter); i += len
            case 0x29:                                         // )
                push(i, 1, .groupDelimiter); i += 1
            case 0x7C:                                         // |
                push(i, 1, .alternation); i += 1
            case 0x2A, 0x2B, 0x3F:                             // * + ?
                push(i, 1, .quantifier); i += 1
            case 0x7B:                                         // {  evtl. {n,m}
                var j = i + 1
                var digits = 0
                while j < n && isDigit(s.character(at: j)) { j += 1; digits += 1 }
                if j < n && s.character(at: j) == 0x2C {        // ,
                    j += 1
                    while j < n && isDigit(s.character(at: j)) { j += 1 }
                }
                if digits > 0 && j < n && s.character(at: j) == 0x7D {
                    push(i, j - i + 1, .quantifier); i = j + 1
                } else {
                    i += 1                                     // literales {
                }
            default:
                i += 1                                         // Literal → Basisfarbe
            }
        }
        return out
    }
}

// MARK: - Verwaltung der Suchvorlagen

/// Kleines Fenster mit der Vorlagenliste: Laden, Umbenennen (Name in der
/// Zeile bearbeiten), Löschen. Eigene Klasse, weil MainController schon
/// Datenquelle der Trefferliste ist — zwei Tabellen an einem Delegate
/// müssten sich bei jedem Aufruf gegenseitig auseinanderhalten.
final class SearchTemplateManager: NSObject, NSTableViewDataSource,
                                   NSTableViewDelegate, NSTextFieldDelegate {
    unowned let owner: MainController
    let window: NSWindow
    let templateTable = NSTableView()
    let summaryLabel = NSTextField(labelWithString: "")
    let loadButton = NSButton(title: "Laden", target: nil, action: nil)
    let renameButton = NSButton(title: "Umbenennen", target: nil, action: nil)
    let deleteButton = NSButton(title: "Löschen", target: nil, action: nil)

    init(owner: MainController) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Suchvorlagen"
        window.isReleasedWhenClosed = false
        window.center()
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Vorlage"
        templateTable.addTableColumn(column)
        templateTable.headerView = nil
        templateTable.dataSource = self
        templateTable.delegate = self
        templateTable.doubleAction = #selector(loadSelected)
        templateTable.target = self
        let scroll = NSScrollView()
        scroll.documentView = templateTable
        scroll.hasVerticalScroller = true
        loadButton.target = self
        loadButton.action = #selector(loadSelected)
        renameButton.target = self
        renameButton.action = #selector(renameSelected)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [loadButton, renameButton, deleteButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [scroll, summaryLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        summaryLabel.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true
        reload()
    }

    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        templateTable.reloadData()
        selectionChanged()
    }

    var selectedTemplate: SearchTemplate? {
        let row = templateTable.selectedRow
        return owner.templates.indices.contains(row) ? owner.templates[row] : nil
    }

    func selectionChanged() {
        let selected = selectedTemplate
        loadButton.isEnabled = selected != nil
        renameButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        summaryLabel.stringValue = selected.map(owner.templateSummary)
            ?? (owner.templates.isEmpty ? "Noch keine Vorlagen — „Suche als Vorlage sichern…“ im Menü Vorlagen." : "")
    }

    func numberOfRows(in templateTable: NSTableView) -> Int { owner.templates.count }

    // Die Namen sind Vertrag mit AppKit: `tableView(_:viewFor:row:)` und
    // `tableViewSelectionDidChange(_:)`. Bis 0.34.0 hießen sie
    // `templateTable(…)` — nie gerufen, alle Zeilen leer, Knöpfe grau.
    func tableView(_ templateTable: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard owner.templates.indices.contains(row) else { return nil }
        let field: NSTextField
        if let reused = templateTable.makeView(withIdentifier: .init("templateName"), owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(string: "")
            field.identifier = .init("templateName")
            field.isBordered = false
            field.drawsBackground = false
            field.delegate = self
        }
        field.stringValue = owner.templates[row].name
        field.isEditable = true
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanged() }

    /// Der Name wurde in der Zeile bearbeitet: umbenennen, Fehler nennen.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = templateTable.row(for: field)
        guard owner.templates.indices.contains(row) else { return }
        let previous = owner.templates[row].name
        if let error = owner.renameTemplate(previous, to: field.stringValue) {
            field.stringValue = previous
            summaryLabel.stringValue = error
        }
    }

    @objc func loadSelected() {
        guard let template = selectedTemplate else { return }
        owner.applyTemplate(template)
        owner.window?.makeKeyAndOrderFront(nil)
    }

    @objc func renameSelected() {
        let row = templateTable.selectedRow
        guard row >= 0 else { return }
        templateTable.editColumn(0, row: row, with: nil, select: true)
    }

    @objc func deleteSelected() {
        guard let template = selectedTemplate else { return }
        let alert = NSAlert()
        alert.messageText = "Vorlage „\(template.name)“ löschen?"
        alert.informativeText = "Gelöscht wird nur die Vorlage — keine Datei und kein Treffer."
        alert.addButton(withTitle: "Löschen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = owner.deleteTemplate(template.name) {
            summaryLabel.stringValue = error
        }
    }
}

// MARK: - RegEx-Vorlagen (Auswahl aus Fastras Bibliothek, such-tauglich)
