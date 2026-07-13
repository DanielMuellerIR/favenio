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
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Unsichtbare",
                                  target: nil, action: nil)
    // Drei-Wege-Umschalter: Dateien & Ordner / nur Dateien / nur Ordner.
    let typeControl = NSSegmentedControl(
        labels: ["Dateien & Ordner", "Dateien", "Ordner"],
        trackingMode: .selectOne, target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "Bereit.")
    let tableView = NSTableView()

    var hits: [Hit] = []            // was die Tabelle zeigt
    var pending: [Hit] = []         // frisch gestreamte, noch nicht gezeigte
    var seenPaths = Set<String>()   // schon gezeigte Pfade → keine Doppelten
    var cachedFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    var refreshingFinder = false
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
        installViewMenu()
        // Finder-Fenster für das Ordner-Popup vorab im Hintergrund laden
        // (der AppleScript-Aufruf darf den Start nicht blockieren).
        refreshFinderFoldersAsync()

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

        // Beim Start einmal auf Festplattenvollzugriff hinweisen (bringt bei
        // Suchen über den ganzen Benutzerordner deutlich weniger Nachfragen).
        maybePromptFullDiskAccess(appName: "Favenio")
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
        // Suchoptionen der Schnellsuche übernehmen (Default: aus), damit die
        // Weitersuche hier mit denselben Einstellungen läuft.
        contentCheckbox.state = value("content") == "1" ? .on : .off
        archivesCheckbox.state = value("archives") == "1" ? .on : .off
        hiddenCheckbox.state = value("hidden") == "1" ? .on : .off
        regexCheckbox.state = value("regex") == "1" ? .on : .off
        caseCheckbox.state = value("case") == "1" ? .on : .off

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if let file = value("file") {
            if value("continue") == "1" {
                // Schnellsuche hat bei 20 Treffern übergeben: die 20 sofort
                // zeigen und die Suche hier live fortsetzen (weitere Treffer
                // kommen hinzu, die 20 werden dabei nicht doppelt gelistet).
                continueSearch(from: URL(fileURLWithPath: file))
            } else {
                loadResults(from: URL(fileURLWithPath: file))
            }
        }
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

        buildTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                         for: .vertical)

        let topRow = NSStackView(views: [searchField, folderButton])
        topRow.orientation = .horizontal
        let optionsRow = NSStackView(views: [typeControl, contentCheckbox,
                                             archivesCheckbox, hiddenCheckbox,
                                             regexCheckbox, caseCheckbox])
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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    /// Lädt die offenen Finder-Fenster im Hintergrund (AppleScript kann
    /// blockieren) und aktualisiert den Cache — nie auf dem Main-Thread.
    func refreshFinderFoldersAsync() {
        guard !refreshingFinder else { return }
        refreshingFinder = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders = finderWindowFolders()
            DispatchQueue.main.async {
                self?.refreshingFinder = false
                self?.cachedFinderFolders = folders
            }
        }
    }

    @objc func showFolderMenu() {
        // Für den nächsten Aufruf frisch laden, jetzt aber den Cache nehmen —
        // so hängt der Klick nie am (evtl. blockierenden) Finder-AppleScript.
        refreshFinderFoldersAsync()
        let menu = NSMenu()

        // 1) Offene Finder-Fenster. Der erste Eintrag ist das VORDERSTE
        //    Finder-Fenster (Daniel: „aktives Finderfenster" gemeint als das
        //    vorderste — aktiv kann es nicht sein, solange Favenio vorn ist).
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
        stopSearch()
        let seed = (try? Data(contentsOf: file)).map {
            $0.split(separator: 0x0A).compactMap { parseHit(Data($0)) }
        } ?? []
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
            only: only, includeHidden: hiddenCheckbox.state == .on)
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
            // Schon gezeigte Pfade (z. B. die aus der Schnellsuche
            // übernommenen 20) nicht erneut auflisten.
            if let hit = parseHit(lineData),
               seenPaths.insert(hit.path).inserted {
                pending.append(hit)
            }
        }
    }

    func flushPending() {
        guard !pending.isEmpty else { return }
        hits.append(contentsOf: pending)
        pending = []
        sortHits()   // aktive Sortierung auch auf frische Treffer anwenden
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
        hits.sort { lhs, rhs in
            let result: Bool
            switch key {
            case "size":
                result = (lhs.size ?? -1) < (rhs.size ?? -1)
            case "type":
                result = lhs.typeDescription.localizedCaseInsensitiveCompare(
                    rhs.typeDescription) == .orderedAscending
            case "line":
                result = (lhs.line ?? -1) < (rhs.line ?? -1)
            case "path":
                result = lhs.path.localizedCaseInsensitiveCompare(rhs.path)
                    == .orderedAscending
            default:   // "name"
                result = lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName) == .orderedAscending
            }
            return ascending ? result : !result
        }
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
