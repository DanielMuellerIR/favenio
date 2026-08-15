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
// sowie das Startargument --handoff-url (älter: --results-file/--query) —
// darüber liefert die Schnellsuche (FavenioQuick.app) ihre Treffer an.
//
// Mit --selftest läuft statt der GUI ein Headless-Integrationstest.

import AppKit
import Quartz   // QLPreviewPanel (QuickLook-Vorschau)

@main
struct FavenioApp {
    static func main() {
        // Headless-Selbsttest (für Build-Skript und AI-Agenten):
        // prüft Suche + Extraktion über exakt denselben Code, den die
        // GUI benutzt — ganz ohne Fenster.
        if CommandLine.arguments.contains("--selftest") {
            exit(runSelfTest())
        }
        // Headless-Diagnose: was sieht DIESES Bundle beim Finder wirklich?
        if CommandLine.arguments.contains("--finder-scope") {
            runFinderScopeDiagnostic()
        }
        let app = NSApplication.shared
        let controller = MainController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
    }
}

// MARK: - Headless-Selbsttest

func runSelfTest() -> Int32 {
    defer { cleanupMaterializedHits() }
    guard findCLI() != nil else {
        print("SELFTEST FEHLER: favenio.py nicht gefunden")
        return 1
    }
    if let error = validateSparkleConfiguration(
        expectedBundleIdentifier: "local.favenio"
    ) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    guard !searchExitIsError(0), !searchExitIsError(1),
          searchExitIsError(2), searchExitIsError(15) else {
        print("SELFTEST FEHLER: Such-Exit-Codes falsch eingeordnet")
        return 1
    }
    // Eigene kleine Test-Welt in einem Temp-Ordner bauen.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("favenio-selftest-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmp,
                                             withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let plain = tmp.appendingPathComponent("probe.txt")
    try? "FAVENIO_PROBE flach\n".write(to: plain, atomically: true,
                                       encoding: .utf8)
    // Zip-Fixture über Python bauen (kein zip-CLI nötig).
    let zipBuilder = Process()
    zipBuilder.executableURL = URL(fileURLWithPath: pythonPath)
    zipBuilder.arguments = ["-c",
        "import zipfile,sys\n" +
        "z = zipfile.ZipFile(sys.argv[1], 'w')\n" +
        "z.writestr('inner/geheim.txt', 'FAVENIO_PROBE im Zip')\n" +
        "z.close()",
        tmp.appendingPathComponent("probe.zip").path]
    try? zipBuilder.run()
    zipBuilder.waitUntilExit()

    guard let args = searchArguments(pattern: "FAVENIO_PROBE",
                                     root: tmp.path, content: true,
                                     regex: false, caseSensitive: true,
                                     archives: true) else { return 1 }
    let hits = runSearchSync(arguments: args)
    guard hits.count == 2 else {
        print("SELFTEST FEHLER: \(hits.count) Treffer statt 2")
        return 1
    }
    guard let member = hits.first(where: { $0.isMember }),
          let extracted = materializeHit(member),
          materializeHit(member) == extracted,
          let content = try? String(contentsOf: extracted, encoding: .utf8),
          content.contains("FAVENIO_PROBE")
    else {
        print("SELFTEST FEHLER: Archiv-Extraktion fehlgeschlagen")
        return 1
    }
    let tied = Hit(path: "/tmp/b/same.txt", kind: "file", line: 7,
                   size: 42, filesystemPath: "/tmp/b/same.txt",
                   archiveMembers: [])
    let tiedEarlier = Hit(path: "/tmp/a/same.txt", kind: "file", line: 7,
                          size: 42, filesystemPath: "/tmp/a/same.txt",
                          archiveMembers: [])
    for key in ["name", "type", "size", "line", "path"] {
        for ascending in [true, false] {
            guard !compareHits(tied, tied, key: key, ascending: ascending),
                  !(compareHits(tied, tiedEarlier, key: key,
                                ascending: ascending)
                    && compareHits(tiedEarlier, tied, key: key,
                                   ascending: ascending)) else {
                print("SELFTEST FEHLER: Sortierordnung für \(key)")
                return 1
            }
        }
    }
    do {
        let handoff = try writeQuickHandoff(hits)
        guard consumeQuickHandoff(handoff)?.count == hits.count,
              !FileManager.default.fileExists(atPath: handoff.path) else {
            print("SELFTEST FEHLER: Ergebnisübergabe nicht verbraucht")
            return 1
        }
    } catch {
        print("SELFTEST FEHLER: Ergebnisübergabe: \(error)")
        return 1
    }
    print("SELFTEST OK — Suche, Archiv-Extraktion und Sparkle-Anbindung "
          + "funktionieren")
    return 0
}

// MARK: - Haupt-Controller

final class ActiveSearchRun {
    let process: Process
    let pipe: Pipe
    var lineBuffer = Data()
    var reachedEOF = false
    var terminationStatus: Int32?

    init(process: Process, pipe: Pipe) {
        self.process = process
        self.pipe = pipe
    }
}

func compareHits(_ lhs: Hit, _ rhs: Hit, key: String,
                 ascending: Bool) -> Bool {
    let primary: ComparisonResult
    switch key {
    case "size":
        primary = (lhs.size ?? -1) < (rhs.size ?? -1) ? .orderedAscending
            : (lhs.size ?? -1) > (rhs.size ?? -1) ? .orderedDescending
            : .orderedSame
    case "type":
        primary = lhs.typeDescription.localizedCaseInsensitiveCompare(
            rhs.typeDescription)
    case "line":
        primary = (lhs.line ?? -1) < (rhs.line ?? -1) ? .orderedAscending
            : (lhs.line ?? -1) > (rhs.line ?? -1) ? .orderedDescending
            : .orderedSame
    case "path":
        primary = lhs.path.localizedCaseInsensitiveCompare(rhs.path)
    default:
        primary = lhs.displayName.localizedCaseInsensitiveCompare(
            rhs.displayName)
    }
    if primary != .orderedSame {
        return ascending ? primary == .orderedAscending
                         : primary == .orderedDescending
    }
    // Deterministischer Tie-Breaker, unabhängig von der Sortierrichtung.
    // Vollständig gleiche Treffer vergleichen in beiden Richtungen false.
    let pathOrder = lhs.path.localizedCaseInsensitiveCompare(rhs.path)
    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
    if lhs.line != rhs.line { return (lhs.line ?? -1) < (rhs.line ?? -1) }
    return false
}

final class MainController: NSObject, NSApplicationDelegate,
                            NSTableViewDataSource, NSTableViewDelegate,
                            NSMenuDelegate, NSSearchFieldDelegate,
                            QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    /// Ein Controller pro App-Prozess; Sparkle hält darüber Update-Zustand,
    /// Download und Installation über die gesamte App-Laufzeit zusammen.
    private let updaterController = makeUpdaterController()
    var window: NSWindow!
    let searchField = NSSearchField()
    let stopButton = NSButton(title: "", target: nil, action: nil)
    let folderButton = NSButton(title: "Ordner…", target: nil, action: nil)
    let contentCheckbox = NSButton(checkboxWithTitle: "Inhalt durchsuchen",
                                   target: nil, action: nil)
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
    let tableView = NSTableView()

    var hits: [Hit] = []            // was die Tabelle zeigt
    var pending: [Hit] = []         // frisch gestreamte, noch nicht gezeigte
    var seenPaths = Set<String>()   // schon gezeigte Pfade → keine Doppelten
    var cachedFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    var refreshingFinder = false
    // Warum die Finder-Fenster fehlen (verweigerte Automation, kein Fenster,
    // Zeitüberschreitung). Steht im Ordner-Menü, statt kommentarlos zu fehlen.
    var finderScopeProblem: String?
    var finderScopeDenied = false
    var searchRoot = FileManager.default.homeDirectoryForCurrentUser
    var activeSearchRun: ActiveSearchRun?
    var flushTimer: Timer?
    var contextRow = -1             // Zeile, auf die der Rechtsklick ging
    var pendingURL: URL?            // favenio://-URL, die vor dem Fenster kam
    var previewURLs: [URL] = []     // gerade in der QuickLook-Vorschau

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
        installAboutItem()
        installViewMenu()
        // Finder-Fenster für das Ordner-Popup vorab im Hintergrund laden
        // (der AppleScript-Aufruf darf den Start nicht blockieren).
        refreshFinderFoldersAsync()

        // Fallback-Weg ohne funktionierende URL-Zuordnung: Quick startet eine
        // neue App-Instanz und gibt denselben strukturierten URL-Datensatz als
        // Argument mit. Dadurch verarbeitet genau EIN Parser Wurzel, Optionen,
        // Ergebnisdatei und die gewünschte Fortsetzung der Suche.
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--handoff-url"),
           flagIndex + 1 < arguments.count,
           let handoffURL = URL(string: arguments[flagIndex + 1]) {
            handleFavenioURL(handoffURL)
        } else {
            // Alte Quick-Versionen bleiben kompatibel; dieser Weg konnte
            // Suchwurzel und Optionen noch nicht übertragen.
            if let flagIndex = arguments.firstIndex(of: "--query"),
               flagIndex + 1 < arguments.count {
                searchField.stringValue = arguments[flagIndex + 1]
            }
            if let flagIndex = arguments.firstIndex(of: "--results-file"),
               flagIndex + 1 < arguments.count {
                loadResults(from: URL(
                    fileURLWithPath: arguments[flagIndex + 1]))
            }
        }
        // Eine URL, die schon vor dem Fensterbau eintraf, jetzt verarbeiten.
        if let url = pendingURL {
            pendingURL = nil
            handleFavenioURL(url)
        }

        // Beim Start einmal auf Festplattenvollzugriff hinweisen (bringt bei
        // Suchen über den ganzen Benutzerordner deutlich weniger Nachfragen).
        maybePromptFullDiskAccess(appName: "Favenio")

        // Leertaste in der Trefferliste öffnet die QuickLook-Vorschau (wie im
        // Finder). Nur wenn die Tabelle den Fokus hat — sonst tippt die
        // Leertaste normal ins Suchfeld.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 49,                        // 49 = Leertaste
               let self, self.window.firstResponder === self.tableView {
                self.togglePreview()
                return nil
            }
            return event
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

    // ---------- QuickLook-Vorschau ----------

    /// Vorschau der ausgewählten Treffer ein-/ausblenden. Archiv-Einträge
    /// werden dafür (wie beim Öffnen) in einen Temp-Ordner ausgepackt.
    @objc func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func rebuildPreviewURLs() {
        // Vorschau folgt der AUSWAHL (Leertaste/Pfeiltasten). Nur wenn nichts
        // ausgewählt ist, die angeklickte Zeile — NICHT den alten Rechtsklick
        // (das war der „immer dieselbe Datei"-Fehler).
        var rows = Array(tableView.selectedRowIndexes)
        if rows.isEmpty, tableView.clickedRow >= 0 {
            rows = [tableView.clickedRow]
        }
        previewURLs = rows.compactMap { row in
            row < hits.count ? materializeHit(hits[row]) : nil
        }
    }

    // QuickLook fragt diese Methoden über die Responder-Kette + den
    // App-Delegate ab (informelles Protokoll auf NSResponder).
    @objc override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!)
        -> Bool { true }
    @objc override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        rebuildPreviewURLs()
        panel.dataSource = self
        panel.delegate = self
    }
    @objc override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }
    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }

    /// Auswahl geändert, während die Vorschau offen ist → mitziehen.
    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            rebuildPreviewURLs()
            QLPreviewPanel.shared().reloadData()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { true }

    /// App vorderste → Finder-Fenster (neu) laden. Nur wenn die App aktiv
    /// ist, zeigt TCC den Automations-Consent-Dialog. Läuft im Hintergrund.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshFinderFoldersAsync()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSearch()
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
        guard let components = URLComponents(url: url,
                                             resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "favenio",
              components.host?.lowercased() == "results"
        else { return }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let filePath = value("file"),
              validatedQuickHandoff(URL(fileURLWithPath: filePath)) != nil,
              (value("q")?.utf8.count ?? 0) <= 4096,
              (value("root")?.utf8.count ?? 0) <= 4096 else { return }
        if let query = value("q") { searchField.stringValue = query }
        if let root = value("root") {
            setSearchRoot(URL(fileURLWithPath: root))
        }
        // Suchoptionen der Schnellsuche übernehmen (Default: aus), damit die
        // Weitersuche hier mit denselben Einstellungen läuft.
        contentCheckbox.state = value("content") == "1" ? .on : .off
        archivesCheckbox.state = value("archives") == "1" ? .on : .off
        hiddenCheckbox.state = value("hidden") == "1" ? .on : .off
        regexCheckbox.state = value("regex") == "1" ? .on : .off
        caseCheckbox.state = value("case") == "1" ? .on : .off
        exactCheckbox.state = value("exact") == "1" ? .on : .off

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if value("continue") == "1" {
            // Schnellsuche hat bei 20 Treffern übergeben: die 20 sofort
            // zeigen und die Suche hier live fortsetzen (weitere Treffer
            // kommen hinzu, die 20 werden dabei nicht doppelt gelistet).
            continueSearch(from: URL(fileURLWithPath: filePath))
        } else {
            loadResults(from: URL(fileURLWithPath: filePath))
        }
    }

    /// Fertige Treffer (JSONL-Datei der Schnellsuche) direkt anzeigen —
    /// die Suche lief dort schon, hier wird nichts doppelt gesucht.
    func loadResults(from file: URL) {
        guard let loaded = consumeQuickHandoff(file) else {
            statusLabel.stringValue = "Ungültige oder zu große Ergebnisübergabe."
            return
        }
        stopSearch()
        hits = loaded
        pending = []
        tableView.reloadData()
        statusLabel.stringValue = "\(hits.count) Treffer (aus Schnellsuche)."
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

        buildTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                         for: .vertical)

        let topRow = NSStackView(views: [stopButton, searchField, folderButton])
        topRow.orientation = .horizontal
        let optionsRow = NSStackView(views: [typeControl, contentCheckbox,
                                             archivesCheckbox, hiddenCheckbox,
                                             exactCheckbox, regexCheckbox,
                                             caseCheckbox, templatesButton])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 12

        let stack = NSStackView(views: [topRow, optionsRow, scroll,
                                        statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Statuszeile an die Stack-Breite binden → kann das Fenster nicht
            // in die Breite ziehen (langer „durchsuche …"-Pfad).
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    func buildTable() {
        // (Identifier, Titel, Breite) — Reihenfolge = Spaltenreihenfolge.
        // Jede Spalte ist über einen sortDescriptorPrototype sortierbar; der
        // key zeigt auf die Sortier-Logik in sortDescriptorsDidChange.
        let columns = [
            ("name", "Name", CGFloat(220)),
            ("type", "Typ", CGFloat(140)),
            ("size", "Größe", CGFloat(90)),
            ("line", "Zeile", CGFloat(48)),
            ("path", "Ort", CGFloat(460)),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: identifier, ascending: true)
            // Größe rechtsbündig (Zahlenspalte).
            if identifier == "size" {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

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

        // Drag & Drop nach draußen (Finder, andere Apps) erlauben.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    func setSearchRoot(_ url: URL) {
        searchRoot = url
        // Wurzel-Ordner heißt "" bei "/" → dann den Pfad zeigen.
        let name = url.lastPathComponent.isEmpty ? url.path
                                                 : url.lastPathComponent
        folderButton.title = "📁 " + name + " ▾"
        folderButton.toolTip = url.path
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

    /// Lädt die offenen Finder-Fenster in den Cache — asynchron über einen
    /// osascript-Unterprozess, der den Main-Thread NIE blockiert (siehe
    /// finderWindowFoldersAsync). Das Ordner-Popup nimmt danach den Cache.
    func refreshFinderFoldersAsync() {
        guard !refreshingFinder else { return }
        refreshingFinder = true
        finderWindowFoldersAsync { [weak self] outcome in
            guard let self else { return }
            self.refreshingFinder = false
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
        let other = NSMenuItem(title: "Anderer Ordner…",
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
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        if path == searchRoot.path { item.state = .on }
        menu.addItem(item)
    }

    @objc func pickFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        setSearchRoot(URL(fileURLWithPath: path))
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = searchRoot
        panel.prompt = "Hier suchen"
        if panel.runModal() == .OK, let url = panel.url {
            setSearchRoot(url)
        }
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

    @objc func startSearch() {
        stopSearch()
        // Frische Suche: Tabelle leeren und von vorn sammeln.
        hits = []
        pending = []
        seenPaths = []
        tableView.reloadData()
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            statusLabel.stringValue = "Bereit."
            return
        }
        launchSearch(pattern: pattern)
    }

    /// Fertige Treffer der Schnellsuche (≤20) sofort zeigen und die Suche
    /// hier LIVE fortsetzen. Die schon gezeigten Treffer werden über
    /// `seenPaths` nicht doppelt gelistet.
    func continueSearch(from file: URL) {
        guard let seed = consumeQuickHandoff(file) else {
            statusLabel.stringValue = "Ungültige oder zu große Ergebnisübergabe."
            return
        }
        stopSearch()
        hits = seed
        pending = []
        seenPaths = Set(seed.map { $0.path })
        // Die Schnellsuche findet Dateien & Ordner → hier ebenso weitersuchen.
        typeControl.selectedSegment = 0
        tableView.reloadData()
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else {
            statusLabel.stringValue = "\(hits.count) Treffer (aus Schnellsuche)."
            return
        }
        launchSearch(pattern: pattern)
    }

    /// Startet den Suchprozess und streamt Treffer in die (evtl. schon per
    /// `continueSearch` vorbelegte) Tabelle. Setzt hits/seenPaths NICHT
    /// zurück — das machen die Aufrufer je nach Fall.
    func launchSearch(pattern: String) {
        let only = ["both", "files", "dirs"][
            max(0, typeControl.selectedSegment)]
        guard let arguments = searchArguments(
            pattern: pattern, root: searchRoot.path,
            content: contentCheckbox.state == .on,
            regex: regexCheckbox.state == .on,
            caseSensitive: caseCheckbox.state == .on,
            archives: archivesCheckbox.state == .on,
            progress: true,
            only: only, includeHidden: hiddenCheckbox.state == .on,
            exact: exactCheckbox.state == .on)
        else {
            statusLabel.stringValue = "favenio.py nicht gefunden."
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let run = ActiveSearchRun(process: process, pipe: pipe)
        activeSearchRun = run

        // Treffer kommen zeilenweise über die Pipe herein (Hintergrund-
        // Thread) und werden auf dem Main-Thread eingesammelt.
        pipe.fileHandleForReading.readabilityHandler = { [weak self, weak run]
                                                          handle in
            guard let run else { return }
            let data = handle.availableData
            if data.isEmpty {                    // EOF
                handle.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self, self.activeSearchRun === run else { return }
                    run.reachedEOF = true
                    self.finishSearchRunIfReady(run)
                }
                return
            }
            DispatchQueue.main.async {
                guard let self, self.activeSearchRun === run else { return }
                self.consume(data, for: run)
            }
        }
        process.terminationHandler = { [weak self, weak run] process in
            guard let run else { return }
            DispatchQueue.main.async {
                guard let self, self.activeSearchRun === run else { return }
                run.terminationStatus = process.terminationStatus
                self.finishSearchRunIfReady(run)
            }
        }
        do { try process.run() } catch {
            activeSearchRun = nil
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            statusLabel.stringValue = "Suche ließ sich nicht starten: \(error.localizedDescription)"
            return
        }
        stopButton.isEnabled = true
        statusLabel.stringValue = "Suche läuft…"
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
        run?.pipe.fileHandleForReading.readabilityHandler = nil
        run?.process.terminationHandler = nil
        if run?.process.isRunning == true { run?.process.terminate() }
        flushTimer?.invalidate()
        flushTimer = nil
        stopButton.isEnabled = false
    }

    /// Klick auf den Stopp-Button: laufende Suche abbrechen.
    @objc func stopSearchClicked() {
        guard activeSearchRun != nil else { return }
        stopSearch()
        flushPending()
        statusLabel.stringValue = "Suche gestoppt — \(hits.count) Treffer."
    }

    /// Rohbytes aus der Pipe in Zeilen zerlegen und als Hits vormerken.
    func consume(_ data: Data, for run: ActiveSearchRun) {
        run.lineBuffer.append(data)
        while let newline = run.lineBuffer.firstIndex(of: 0x0A) {
            let lineData = run.lineBuffer.subdata(
                in: run.lineBuffer.startIndex..<newline)
            run.lineBuffer.removeSubrange(run.lineBuffer.startIndex...newline)
            consumeSearchLine(lineData)
        }
    }

    func consumeSearchLine(_ lineData: Data) {
        // Fortschritt (welcher Ordner/welches Archiv gerade dran ist)
        // wie in der Schnellsuche laufend anzeigen.
        if let path = parseProgress(lineData) {
            statusLabel.stringValue = "\(hits.count) Treffer — durchsuche "
                + abbreviateHome(path)
        } else if let hit = parseHit(lineData),
                  seenPaths.insert(hit.path).inserted {
            // Schon gezeigte Pfade (z. B. die aus der Schnellsuche
            // übernommenen 20) nicht erneut auflisten.
            pending.append(hit)
        }
    }

    func flushPending() {
        guard !pending.isEmpty else { return }
        // Auswahl über den reloadData hinweg festhalten (sonst verliert man
        // beim Streamen sofort wieder die markierte Zeile — etwa fürs
        // QuickLook). Wir merken die Pfade und stellen sie danach wieder her.
        let selectedPaths = Set(tableView.selectedRowIndexes.compactMap {
            $0 < hits.count ? hits[$0].path : nil
        })
        hits.append(contentsOf: pending)
        pending = []
        sortHits()   // aktive Sortierung auch auf frische Treffer anwenden
        tableView.reloadData()
        if !selectedPaths.isEmpty {
            let rows = IndexSet(hits.indices.filter {
                selectedPaths.contains(hits[$0].path)
            })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        statusLabel.stringValue = "\(hits.count) Treffer — Suche läuft…"
    }

    func finishSearchRunIfReady(_ run: ActiveSearchRun) {
        guard activeSearchRun === run, run.reachedEOF,
              let status = run.terminationStatus else { return }
        if !run.lineBuffer.isEmpty {
            consumeSearchLine(run.lineBuffer)
            run.lineBuffer.removeAll()
        }
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        run.pipe.fileHandleForReading.readabilityHandler = nil
        run.process.terminationHandler = nil
        activeSearchRun = nil
        stopButton.isEnabled = false
        if searchExitIsError(status) {
            statusLabel.stringValue = "Suche fehlgeschlagen."
        } else {
            statusLabel.stringValue = hits.isEmpty
                ? "Keine Treffer."
                : "\(hits.count) Treffer."
        }
    }

    // ---------- Tabelle ----------

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        var cell = tableView.makeView(withIdentifier: column.identifier,
                                      owner: nil) as? NSTableCellView
        if cell == nil {
            // Zellen einmal bauen, danach werden sie recycelt.
            let newCell = NSTableCellView()
            newCell.identifier = column.identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(label)
            newCell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: newCell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(
                    equalTo: newCell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(
                    equalTo: newCell.centerYAnchor),
            ])
            cell = newCell
        }
        let hit = hits[row]
        // Zellen werden recycelt → Ausrichtung je Spalte neu setzen.
        cell?.textField?.alignment =
            column.identifier.rawValue == "size" ? .right : .left
        switch column.identifier.rawValue {
        case "name":
            cell?.textField?.stringValue = hit.displayName
        case "type":
            cell?.textField?.stringValue = hit.typeDescription
        case "size":
            cell?.textField?.stringValue = humanSize(hit.size)
        case "line":
            cell?.textField?.stringValue = hit.line.map { String($0) } ?? ""
        default:
            cell?.textField?.stringValue = hit.path
        }
        return cell
    }

    /// Dateigröße menschenlesbar (z. B. „1,2 MB"); Ordner (nil) → „—".
    func humanSize(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                         countStyle: .file)
    }

    /// Header-Klick: Trefferliste nach der gewählten Spalte sortieren.
    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortHits()
        tableView.reloadData()
    }

    /// Sortiert `hits` nach dem aktiven Sortierkriterium (oder lässt die
    /// Einfüge-Reihenfolge, wenn keins gesetzt ist).
    func sortHits() {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return }
        let ascending = descriptor.ascending
        hits.sort { compareHits($0, $1, key: key, ascending: ascending) }
    }

    /// Drag & Drop: die gezogene Zeile liefert eine Datei-URL —
    /// Archiv-Einträge werden dafür beim Anfassen ausgepackt.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < hits.count,
              let url = materializeHit(hits[row]) else { return nil }
        return url as NSURL
    }

    // ---------- Aktionen (Doppelklick, Kontextmenü) ----------

    /// Zeilen, auf die sich eine Aktion bezieht: die Auswahl, oder —
    /// falls außerhalb der Auswahl geklickt wurde — die geklickte Zeile.
    func actionRows() -> [Int] {
        if contextRow >= 0,
           !tableView.selectedRowIndexes.contains(contextRow) {
            return [contextRow]
        }
        if !tableView.selectedRowIndexes.isEmpty {
            return Array(tableView.selectedRowIndexes)
        }
        return contextRow >= 0 ? [contextRow] : []
    }

    @objc func openSelected() {
        let row = tableView.clickedRow
        let rows = row >= 0 ? [row] : actionRows()
        for row in rows where row < hits.count {
            if let url = materializeHit(hits[row]) {
                NSWorkspace.shared.open(url)
            } else {
                statusLabel.stringValue =
                    "Konnte nicht auspacken: \(hits[row].path)"
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        guard contextRow >= 0, contextRow < hits.count else { return }
        let hit = hits[contextRow]

        menu.addItem(withTitle: "Vorschau (Leertaste)",
                     action: #selector(togglePreview),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Öffnen", action: #selector(ctxOpen),
                     keyEquivalent: "").target = self

        // „Öffnen mit“ — Untermenü mit allen Apps, die den Dateityp können.
        let openWithItem = NSMenuItem(title: "Öffnen mit", action: nil,
                                      keyEquivalent: "")
        let submenu = NSMenu()
        let appURLs = applicationsFor(hit)
        if appURLs.isEmpty {
            let none = NSMenuItem(title: "Keine passende App gefunden",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for appURL in appURLs {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let item = NSMenuItem(title: name,
                                  action: #selector(ctxOpenWith(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = appURL
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        openWithItem.submenu = submenu
        menu.addItem(openWithItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Im Finder zeigen",
                     action: #selector(ctxReveal),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pfad kopieren",
                     action: #selector(ctxCopyPath),
                     keyEquivalent: "").target = self
    }

    @objc func ctxOpen() { openSelected() }

    @objc func ctxOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row]) : nil
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func ctxReveal() {
        // Für Archiv-Einträge zeigt das die ausgepackte Temp-Kopie —
        // das ist genau die Datei, die man beim Öffnen/Ziehen bekommt.
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row]) : nil
        }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func ctxCopyPath() {
        // Bewusst der ORIGINAL-Pfad inkl. !/-Notation — den versteht
        // auch favenio.py --extract wieder.
        let paths = actionRows().compactMap { row in
            row < hits.count ? hits[row].path : nil
        }
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
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

// MARK: - RegEx-Vorlagen (Auswahl aus Fastras Bibliothek, such-tauglich)

struct RegexTemplate {
    let name: String
    let category: String
    let regex: String
    let example: String
}

let regexTemplates: [RegexTemplate] = [
    // Identifikatoren
    .init(name: "E-Mail-Adresse", category: "Identifikatoren",
          regex: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
          example: "max.muster@example.com"),
    .init(name: "URL", category: "Identifikatoren",
          regex: #"https?://[\w.-]+(?:/[\w./?=&%#-]*)?"#,
          example: "https://example.com/path?q=1"),
    .init(name: "IPv4-Adresse", category: "Identifikatoren",
          regex: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, example: "192.168.1.1"),
    .init(name: "IBAN", category: "Identifikatoren",
          regex: #"[A-Z]{2}\d{2}[A-Z0-9]{1,30}"#,
          example: "DE89370400440532013000"),
    .init(name: "UUID", category: "Identifikatoren",
          regex: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
          example: "550e8400-e29b-41d4-a716-446655440000"),
    .init(name: "Hex-Farbe (#RRGGBB)", category: "Identifikatoren",
          regex: #"#(?:[0-9a-fA-F]{3}){1,2}\b"#, example: "#FF9900"),
    .init(name: "Versionsnummer (v1.2.3)", category: "Identifikatoren",
          regex: #"\bv?\d+\.\d+\.\d+\b"#, example: "v1.2.3"),
    .init(name: "Dateiname mit Endung", category: "Identifikatoren",
          regex: #"[\w.-]+\.[A-Za-z][A-Za-z0-9]{0,4}\b"#, example: "notiz.md"),
    // Datum & Zeit
    .init(name: "ISO-Datum (YYYY-MM-DD)", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})\b"#, example: "2026-07-13"),
    .init(name: "Deutsches Datum (DD.MM.YYYY)", category: "Datum & Zeit",
          regex: #"\b(\d{2})\.(\d{2})\.(\d{4})\b"#, example: "13.07.2026"),
    .init(name: "Uhrzeit", category: "Datum & Zeit",
          regex: #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b"#, example: "14:30:45"),
    .init(name: "ISO-Zeitstempel", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\b"#,
          example: "2026-07-13 15:30:00"),
    // Text & Struktur
    .init(name: "Markdown-Link", category: "Text & Struktur",
          regex: #"\[([^\]]+)\]\(([^)]+)\)"#,
          example: "[OpenAI](https://openai.com)"),
    .init(name: "Markdown-Überschrift", category: "Text & Struktur",
          regex: #"^(#{1,6})\s+(.+)$"#, example: "## Überschrift"),
    .init(name: "HTML-Tag", category: "Text & Struktur",
          regex: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#,
          example: #"<a href="…">"#),
    .init(name: "HTML-/XML-Kommentar", category: "Text & Struktur",
          regex: #"<!--[\s\S]*?-->"#, example: "<!-- Notiz -->"),
    // Zahlen
    .init(name: "Ganzzahl", category: "Zahlen",
          regex: #"-?\d+"#, example: "-42"),
    .init(name: "Dezimalzahl (deutsch)", category: "Zahlen",
          regex: #"-?\d+(?:\.\d{3})*,\d+"#, example: "1.234,56"),
    .init(name: "Telefonnummer (DE)", category: "Zahlen",
          regex: #"(?:\+49|0)[\s/-]?\d{2,5}[\s/-]?\d{4,8}"#,
          example: "+49 30 12345678"),
]
