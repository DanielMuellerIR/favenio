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
// sowie die Startargumente --results-file/--query — darüber liefert die
// Schnellsuche (FavenioQuick.app) ihre fertigen Treffer an.
//
// Mit --selftest läuft statt der GUI ein Headless-Integrationstest.

import AppKit
import UniformTypeIdentifiers

@main
struct FavenioApp {
    static func main() {
        // Headless-Selbsttest (für Build-Skript und AI-Agenten):
        // prüft Suche + Extraktion über exakt denselben Code, den die
        // GUI benutzt — ganz ohne Fenster.
        if CommandLine.arguments.contains("--selftest") {
            exit(runSelfTest())
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
    guard findCLI() != nil else {
        print("SELFTEST FEHLER: favenio.py nicht gefunden")
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
    let hits = runSearchSync(arguments: args).hits
    guard hits.count == 2 else {
        print("SELFTEST FEHLER: \(hits.count) Treffer statt 2")
        return 1
    }
    guard let member = hits.first(where: { $0.isMember }),
          let extracted = materializeHit(member.path),
          let content = try? String(contentsOf: extracted, encoding: .utf8),
          content.contains("FAVENIO_PROBE")
    else {
        print("SELFTEST FEHLER: Archiv-Extraktion fehlgeschlagen")
        return 1
    }
    print("SELFTEST OK — Suche und Archiv-Extraktion über die "
          + "GUI-Anbindung funktionieren")
    return 0
}

// MARK: - Haupt-Controller

final class MainController: NSObject, NSApplicationDelegate,
                            NSTableViewDataSource, NSTableViewDelegate,
                            NSMenuDelegate {

    var window: NSWindow!
    let searchField = NSSearchField()
    let folderButton = NSButton(title: "Ordner…", target: nil, action: nil)
    let contentCheckbox = NSButton(checkboxWithTitle: "Inhalt durchsuchen",
                                   target: nil, action: nil)
    let archivesCheckbox = NSButton(checkboxWithTitle: "In Archiven suchen",
                                    target: nil, action: nil)
    let regexCheckbox = NSButton(checkboxWithTitle: "Regex",
                                 target: nil, action: nil)
    let caseCheckbox = NSButton(checkboxWithTitle: "Groß/klein beachten",
                                target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "Bereit.")
    let tableView = NSTableView()

    var hits: [Hit] = []            // was die Tabelle zeigt
    var pending: [Hit] = []         // frisch gestreamte, noch nicht gezeigte
    var searchRoot = FileManager.default.homeDirectoryForCurrentUser
    var searchProcess: Process?
    var lineBuffer = Data()         // Restbytes einer angefangenen Zeile
    var flushTimer: Timer?
    var contextRow = -1             // Zeile, auf die der Rechtsklick ging
    var pendingURL: URL?            // favenio://-URL, die vor dem Fenster kam

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
        buildWindow()

        // Startargumente der Schnellsuche (Fallback-Weg ohne URL-Schema).
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--query"),
           flagIndex + 1 < arguments.count {
            searchField.stringValue = arguments[flagIndex + 1]
        }
        if let flagIndex = arguments.firstIndex(of: "--results-file"),
           flagIndex + 1 < arguments.count {
            loadResults(from: URL(fileURLWithPath: arguments[flagIndex + 1]))
        }
        // Eine URL, die schon vor dem Fensterbau eintraf, jetzt verarbeiten.
        if let url = pendingURL {
            pendingURL = nil
            handleFavenioURL(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        stopSearch()
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
                                             resolvingAgainstBaseURL: false)
        else { return }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let query = value("q") { searchField.stringValue = query }
        if let root = value("root") {
            setSearchRoot(URL(fileURLWithPath: root))
        }
        if let file = value("file") {
            loadResults(from: URL(fileURLWithPath: file))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fertige Treffer (JSONL-Datei der Schnellsuche) direkt anzeigen —
    /// die Suche lief dort schon, hier wird nichts doppelt gesucht.
    func loadResults(from file: URL) {
        guard let raw = try? Data(contentsOf: file) else {
            statusLabel.stringValue = "Ergebnisdatei nicht lesbar: \(file.path)"
            return
        }
        stopSearch()
        hits = raw.split(separator: 0x0A).compactMap { parseHit(Data($0)) }
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
        window.title = "Favenio — facile invenio"
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }

        searchField.placeholderString =
            "Suchmuster — Return startet die Suche"
        searchField.target = self
        searchField.action = #selector(startSearch)
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                              for: .horizontal)

        folderButton.title = "📁 " + searchRoot.lastPathComponent
        folderButton.toolTip = searchRoot.path
        folderButton.target = self
        folderButton.action = #selector(chooseFolder)

        archivesCheckbox.state = .on   // Archiv-Blick ist das Markenzeichen

        buildTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                         for: .vertical)

        let topRow = NSStackView(views: [searchField, folderButton])
        topRow.orientation = .horizontal
        let optionsRow = NSStackView(views: [contentCheckbox,
                                             archivesCheckbox,
                                             regexCheckbox, caseCheckbox])
        optionsRow.orientation = .horizontal

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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    func buildTable() {
        let nameColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 240
        let lineColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("line"))
        lineColumn.title = "Zeile"
        lineColumn.width = 48
        let pathColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Ort"
        pathColumn.width = 520
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(lineColumn)
        tableView.addTableColumn(pathColumn)
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
        folderButton.title = "📁 " + url.lastPathComponent
        folderButton.toolTip = url.path
    }

    // ---------- Suche (asynchron, streamend) ----------

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

    @objc func startSearch() {
        stopSearch()
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        hits = []
        pending = []
        tableView.reloadData()
        guard !pattern.isEmpty else {
            statusLabel.stringValue = "Bereit."
            return
        }
        guard let arguments = searchArguments(
            pattern: pattern, root: searchRoot.path,
            content: contentCheckbox.state == .on,
            regex: regexCheckbox.state == .on,
            caseSensitive: caseCheckbox.state == .on,
            archives: archivesCheckbox.state == .on)
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
        lineBuffer = Data()

        // Treffer kommen zeilenweise über die Pipe herein (Hintergrund-
        // Thread) und werden auf dem Main-Thread eingesammelt.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {                    // EOF
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.searchFinished() }
        }
        do { try process.run() } catch {
            statusLabel.stringValue = "Suche ließ sich nicht starten: \(error.localizedDescription)"
            return
        }
        searchProcess = process
        statusLabel.stringValue = "Suche läuft…"
        // Die Tabelle nicht bei jedem einzelnen Treffer neu laden,
        // sondern gebündelt ein paar Mal pro Sekunde.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15,
                                          repeats: true) { [weak self] _ in
            self?.flushPending()
        }
    }

    func stopSearch() {
        searchProcess?.terminate()
        searchProcess = nil
        flushTimer?.invalidate()
        flushTimer = nil
    }

    /// Rohbytes aus der Pipe in Zeilen zerlegen und als Hits vormerken.
    func consume(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(
                in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if let hit = parseHit(lineData) { pending.append(hit) }
        }
    }

    func flushPending() {
        guard !pending.isEmpty else { return }
        hits.append(contentsOf: pending)
        pending = []
        tableView.reloadData()
        statusLabel.stringValue = "\(hits.count) Treffer — Suche läuft…"
    }

    func searchFinished() {
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        searchProcess = nil
        statusLabel.stringValue = hits.isEmpty
            ? "Keine Treffer."
            : "\(hits.count) Treffer."
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
        switch column.identifier.rawValue {
        case "name":
            cell?.textField?.stringValue = hit.displayName
        case "line":
            cell?.textField?.stringValue = hit.line.map { String($0) } ?? ""
        default:
            cell?.textField?.stringValue = hit.path
        }
        return cell
    }

    /// Drag & Drop: die gezogene Zeile liefert eine Datei-URL —
    /// Archiv-Einträge werden dafür beim Anfassen ausgepackt.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < hits.count,
              let url = materializeHit(hits[row].path) else { return nil }
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
            if let url = materializeHit(hits[row].path) {
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

    /// Apps für „Öffnen mit“: bei normalen Dateien direkt über die URL,
    /// bei Archiv-Einträgen über den Dateityp (Endung) — so muss fürs
    /// bloße Menü noch nichts ausgepackt werden.
    func applicationsFor(_ hit: Hit) -> [URL] {
        var urls: [URL] = []
        if hit.isMember {
            let ext = (hit.displayName as NSString).pathExtension
            if !ext.isEmpty, let type = UTType(filenameExtension:
                                                ext.lowercased()) {
                urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
            }
        } else {
            urls = NSWorkspace.shared.urlsForApplications(
                toOpen: URL(fileURLWithPath: hit.path))
        }
        // Nach Namen sortieren und Doppelte (gleicher Pfad) entfernen.
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.path).inserted }
            .sorted {
                FileManager.default.displayName(atPath: $0.path)
                    .localizedCaseInsensitiveCompare(
                        FileManager.default.displayName(atPath: $1.path))
                    == .orderedAscending
            }
    }

    @objc func ctxOpen() { openSelected() }

    @objc func ctxOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row].path) : nil
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func ctxReveal() {
        // Für Archiv-Einträge zeigt das die ausgepackte Temp-Kopie —
        // das ist genau die Datei, die man beim Öffnen/Ziehen bekommt.
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row].path) : nil
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
