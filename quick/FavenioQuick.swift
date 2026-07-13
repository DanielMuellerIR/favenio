// FavenioQuick.app — die Mini-Schnellsuche für die Finder-Toolbar.
//
// Gedacht als Spotlight-Ersatz zum In-die-Toolbar-Ziehen (Cmd-Drag der
// App in die Finder-Kopfleiste):
//
//   Klick aufs Toolbar-Icon  → schwebendes Suchfenster (über allem)
//   0,6 s Pause / Return     → Suche läuft (Namenssuche; Archive/Inhalt
//                              per Umschalter, Default AUS = schnell)
//   Treffer                  → erscheinen LIVE in der Liste (max. 20).
//                              Doppelklick öffnet, Rechtsklick „Öffnen mit".
//   ab dem 20. Treffer       → die große Favenio.app übernimmt: zeigt die
//                              20 sofort und sucht dort live weiter.
//   Esc (bei leerem Feld)    → App beendet sich
//
// Die App ist ein „Accessory" (LSUIElement): kein Dock-Icon. Anders als ein
// klassisches Panel bleibt sie sichtbar, wenn eine andere App nach vorn kommt
// (hidesOnDeactivate = false) — sonst verschwände sie bei jeder macOS-
// Berechtigungsfrage mitten in der Suche.

import AppKit

@main
struct FavenioQuickApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = QuickController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class QuickController: NSObject, NSApplicationDelegate,
                             NSWindowDelegate, NSSearchFieldDelegate,
                             NSTableViewDataSource, NSTableViewDelegate,
                             NSMenuDelegate {

    static let hint = "Return oder 0,6 s Pause startet die Suche · Esc beendet"
    static let debounceInterval: TimeInterval = 0.6
    static let maxQuickHits = 20        // ab hier übernimmt die große GUI
    static let windowWidth: CGFloat = 560

    var panel: NSPanel!
    let field = NSSearchField()
    let scopePopup = NSPopUpButton()    // Suchbereich (Finder-Fenster / Ordner)
    let archivesCheckbox = NSButton(checkboxWithTitle: "In Archiven",
                                    target: nil, action: nil)
    let contentCheckbox = NSButton(checkboxWithTitle: "Inhalt",
                                   target: nil, action: nil)
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Unsichtbare",
                                  target: nil, action: nil)
    let infoLabel = NSTextField(labelWithString: QuickController.hint)
    let spinner = NSProgressIndicator()
    let tableView = NSTableView()
    let scrollView = NSScrollView()
    var scrollHeight: NSLayoutConstraint!
    var outerStack: NSStackView!        // für die Fensterhöhen-Berechnung

    var searchRoot = NSHomeDirectory()  // Wurzel des laufenden Suchlaufs
    var searching = false

    var scopeFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    var refreshingScope = false
    var userPickedScope = false             // hat der Nutzer selbst gewählt?

    // Debounce + Abbruch: nach der letzten Taste 0,6 s warten, dann suchen;
    // Weitertippen bricht den laufenden favenio.py-Prozess ab. Nur das
    // Ergebnis der AKTUELLEN Generation zählt.
    var debounceTimer: Timer?
    var flushTimer: Timer?
    var runningProcess: Process?
    var searchGeneration = 0

    var hits: [Hit] = []                // was die Liste zeigt (max. 20)
    var pending: [Hit] = []             // frisch gestreamt, noch nicht gezeigt
    var handedOff = false               // schon an die große GUI übergeben?
    var contextRow = -1                 // Zeile, auf die der Rechtsklick ging

    // ---------- App-Lebenszyklus ----------

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(appName: "Favenio Schnellsuche", includeClose: true)
        buildPanel()
        showPanel()
        // Beim allerersten Start ist die App noch im Launch-Handshake —
        // NSApp.activate verpufft dann. Ein zweites Aktivieren im nächsten
        // Runloop-Durchlauf holt das Fenster zuverlässig nach vorn.
        DispatchQueue.main.async { [weak self] in self?.showPanel() }

        // Esc bei LEEREM Feld beendet die App; mit Text drin leert Esc das
        // Feld (Standard) — wie bei Spotlight.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53,                       // 53 = Escape
               let self, self.field.stringValue.isEmpty {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }

        // Einmaliger Hinweis auf Festplattenvollzugriff (weniger Nachfragen
        // beim Durchsuchen geschützter Ordner).
        maybePromptFullDiskAccess(appName: "Favenio Schnellsuche")
    }

    /// Erneuter Klick aufs Toolbar-Icon, während die App schon läuft.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    /// Fenster geschlossen (roter Knopf / Cmd+W) → App beenden.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // ---------- Aufbau ----------

    func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.windowWidth, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        // Titel zeigt Version + Datum dieser Version.
        panel.title = "FavenioQuick \(favenioVersion) — \(favenioDate)"
        panel.titleVisibility = .visible
        panel.isMovableByWindowBackground = true
        panel.level = .floating              // schwebt über allen Fenstern
        panel.hidesOnDeactivate = false      // NICHT verschwinden bei App-Wechsel
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        guard let content = panel.contentView else { return }

        // Suchfeld: höher, eingefärbt, ohne Fokusrahmen.
        field.placeholderString = "Favenio-Schnellsuche…"
        field.font = NSFont.systemFont(ofSize: 18)
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = fieldFillColor()
        field.delegate = self       // controlTextDidChange → Debounce
        field.target = self
        field.action = #selector(fire)
        // Nur Return/Enter (bzw. die Lupe) löst die Action aus — NICHT jeder
        // Tastendruck (sonst suchte NSSearchField beim Tippen von selbst).
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                        for: .horizontal)

        // Suchbereich rechts neben dem Feld, in DERSELBEN Reihe.
        scopePopup.controlSize = .regular
        (scopePopup.cell as? NSPopUpButtonCell)?.lineBreakMode =
            .byTruncatingTail

        for checkbox in [archivesCheckbox, contentCheckbox, hiddenCheckbox] {
            checkbox.controlSize = .small
            checkbox.font = NSFont.systemFont(ofSize: 11)
            checkbox.state = .off        // Default: schnelle Namenssuche
            checkbox.target = self
            checkbox.action = #selector(optionsChanged)
        }

        // Merken, wenn der Nutzer den Suchbereich selbst umstellt (dann nicht
        // mehr automatisch aufs vorderste Finder-Fenster zurückspringen).
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged)

        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(.defaultLow,
                                                          for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        buildTable()

        // Reihen als horizontale Stacks, außen ein vertikaler Stack. Die
        // Breiten-Constraints halten alles sauber in Reihen (frühere
        // NSStackView-Überlappung kam vom fehlenden Breiten-Anker).
        let searchRow = NSStackView(views: [field, scopePopup])
        searchRow.orientation = .horizontal
        searchRow.spacing = 8
        searchRow.alignment = .centerY
        let optionsRow = NSStackView(views: [archivesCheckbox, contentCheckbox,
                                             hiddenCheckbox])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 14
        optionsRow.alignment = .centerY
        let infoRow = NSStackView(views: [spinner, infoLabel])
        infoRow.orientation = .horizontal
        infoRow.spacing = 6
        infoRow.alignment = .centerY

        let outer = NSStackView(views: [searchRow, optionsRow, infoRow,
                                        scrollView])
        outer.orientation = .vertical
        outer.spacing = 8
        outer.alignment = .leading
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        outerStack = outer

        scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 12),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -12),
            searchRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            infoRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: outer.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 32),
            scopePopup.widthAnchor.constraint(equalToConstant: 190),
            scrollHeight,
        ])

        layoutForHits()   // kompakte Startgröße (Liste noch leer)

        // Oben-mittig auf dem Bildschirm (Spotlight-Gefühl).
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: visible.midX - Self.windowWidth / 2,
                y: visible.maxY - 120))
        }
    }

    func buildTable() {
        let nameColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 200
        let pathColumn = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Ort"
        pathColumn.width = 320
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(pathColumn)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.rowHeight = 20
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    /// Feld-Füllfarbe je nach Erscheinungsbild: im Dark Mode etwas HELLERES
    /// Grau, im Light Mode etwas DUNKLERES Hellgrau — hebt das Feld dezent ab.
    func fieldFillColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua])
                == .darkAqua
            return dark ? NSColor(white: 0.28, alpha: 1)
                        : NSColor(white: 0.90, alpha: 1)
        }
    }

    func showPanel() {
        updateScope()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        panel.makeFirstResponder(field)
    }

    /// Fenster an die aktuelle Trefferzahl anpassen: Liste einblenden und die
    /// Höhe auf min(Treffer, 20) Zeilen setzen, dabei die OBERE Fensterkante
    /// festhalten (das Fenster wächst nach unten).
    func layoutForHits() {
        let count = min(hits.count, Self.maxQuickHits)
        scrollView.isHidden = count == 0
        let rowUnit = tableView.rowHeight + tableView.intercellSpacing.height
        scrollHeight.constant = count == 0 ? 0
                                           : CGFloat(count) * rowUnit + 6
        outerStack.layoutSubtreeIfNeeded()
        // Höhe = Inhalt des äußeren Stacks + 12 oben + 12 unten Rand.
        let fitting = outerStack.fittingSize.height + 24
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(NSSize(width: Self.windowWidth, height: fitting))
        panel.setFrameTopLeftPoint(topLeft)
    }

    // ---------- Suchbereich (Finder-Fenster / Ordner) ----------

    @objc func scopeChanged() { userPickedScope = true }

    /// Füllt das Bereichs-Menü sofort aus dem Cache (schnell, kein AppleScript)
    /// und lädt die Finder-Fenster im Hintergrund nach — der Finder-Zugriff
    /// darf den Start NICHT blockieren (sonst hängt die App sekundenlang).
    func updateScope() {
        rebuildScopePopup()
        refreshFinderFoldersAsync()
    }

    func rebuildScopePopup() {
        let previous = scopePopup.selectedItem?.representedObject as? String
        scopePopup.removeAllItems()
        var added = Set<String>()
        func add(_ title: String, _ path: String) {
            guard added.insert(path).inserted else { return }
            scopePopup.addItem(withTitle: title)
            scopePopup.lastItem?.representedObject = path
            scopePopup.lastItem?.toolTip = abbreviateHome(path)
        }
        for (index, path) in scopeFinderFolders.enumerated() {
            let name = (path as NSString).lastPathComponent
            add(index == 0 ? "Vorderstes Finder-Fenster — \(name)" : name, path)
        }
        for (title, path) in commonFolders() { add(title, path) }
        // Hat der Nutzer selbst gewählt, seine Auswahl halten; sonst den
        // ersten Eintrag (= vorderstes Finder-Fenster, sobald geladen).
        if userPickedScope, let previous,
           let item = scopePopup.itemArray.first(where: {
               ($0.representedObject as? String) == previous }) {
            scopePopup.select(item)
        } else {
            scopePopup.selectItem(at: 0)
        }
    }

    func refreshFinderFoldersAsync() {
        guard !refreshingScope else { return }
        refreshingScope = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders = finderWindowFolders()   // AppleScript → kann blockieren
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingScope = false
                if folders != self.scopeFinderFolders {
                    self.scopeFinderFolders = folders
                    self.rebuildScopePopup()
                }
            }
        }
    }

    // ---------- Tippen → Debounce / Abbruch ----------

    /// Bei JEDER Textänderung: laufende Suche abbrechen und den 0,6-s-Timer
    /// neu starten. Verstummt das Tippen, sucht startSearch().
    func controlTextDidChange(_ obj: Notification) {
        cancelSearch()
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            hits = []
            layoutForHits()
            infoLabel.stringValue = Self.hint
            return
        }
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.debounceInterval, repeats: false) {
            [weak self] _ in self?.startSearch()
        }
    }

    /// Return/Enter (oder Klick auf die Lupe): sofort suchen.
    @objc func fire() { startSearch() }

    /// Umschalten von Archive/Inhalt startet dieselbe Suche neu.
    @objc func optionsChanged() {
        if !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            startSearch()
        }
    }

    /// Bricht Debounce-Timer, laufenden Suchprozess und Flush-Timer ab und
    /// entwertet noch schwebende Ergebnisse (Generations-Zähler hoch).
    func cancelSearch() {
        debounceTimer?.invalidate(); debounceTimer = nil
        flushTimer?.invalidate(); flushTimer = nil
        searchGeneration += 1
        runningProcess?.terminate(); runningProcess = nil
        pending = []
        searching = false
        spinner.stopAnimation(nil)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
    }

    // ---------- Suche starten (live, im Hintergrund) ----------

    func startSearch() {
        cancelSearch()   // sauberer Ausgangszustand; zählt Generation hoch
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        hits = []
        handedOff = false
        layoutForHits()
        searching = true
        spinner.startAnimation(nil)
        infoLabel.stringValue = "Suche läuft…"

        searchRoot = scopePopup.selectedItem?.representedObject as? String
            ?? NSHomeDirectory()
        let root = searchRoot
        let searchContent = contentCheckbox.state == .on
        let searchArchives = archivesCheckbox.state == .on
        let searchHidden = hiddenCheckbox.state == .on

        // Trefferliste ein paar Mal pro Sekunde nachziehen (nicht bei jedem
        // einzelnen Treffer neu zeichnen).
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.12,
                                          repeats: true) { [weak self] _ in
            self?.flushPending()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let arguments = searchArguments(
                pattern: query, root: root, content: searchContent,
                regex: false, caseSensitive: false,
                archives: searchArchives, progress: true,
                includeHidden: searchHidden)
            else {
                DispatchQueue.main.async {
                    guard let self, generation == self.searchGeneration
                    else { return }
                    self.finish(query: query,
                                errorText: "favenio.py nicht gefunden.")
                }
                return
            }
            let result = runSearchStreaming(arguments: arguments,
                register: { [weak self] process in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if generation == self.searchGeneration {
                            self.runningProcess = process
                        } else {
                            process.terminate()   // schon überholt
                        }
                    }
                },
                onHit: { [weak self] hit in
                    guard let self, generation == self.searchGeneration
                    else { return }
                    self.pending.append(hit)
                },
                onProgress: { [weak self] path in
                    guard let self, generation == self.searchGeneration
                    else { return }
                    self.showProgress(path: path)
                })
            DispatchQueue.main.async {
                guard let self, generation == self.searchGeneration
                else { return }   // abgebrochen/übergeben → verwerfen
                self.runningProcess = nil
                let errorText = result.exitCode == 2
                    ? "Suche fehlgeschlagen. Bitte Favenio erneut installieren."
                    : nil
                self.finish(query: query, errorText: errorText)
            }
        }
    }

    /// Zeigt den gerade durchsuchten Ort dezent in der Info-Zeile.
    func showProgress(path: String) {
        guard searching, hits.isEmpty, pending.isEmpty else { return }
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.stringValue = "Durchsuche " + abbreviateHome(path)
    }

    /// Gebündelt anzeigen; bei ≥20 Treffern an die große GUI übergeben.
    func flushPending() {
        guard !pending.isEmpty else { return }
        let room = Self.maxQuickHits - hits.count
        if room > 0 { hits.append(contentsOf: pending.prefix(room)) }
        pending = []
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = "\(hits.count) Treffer — Suche läuft…"
        layoutForHits()
        tableView.reloadData()
        if hits.count >= Self.maxQuickHits, !handedOff { handOffToMainApp() }
    }

    /// Suche natürlich fertig (weniger als 20 Treffer): Endstand zeigen.
    func finish(query: String, errorText: String?) {
        flushPending()
        cancelSearch()
        if let errorText {
            infoLabel.stringValue = errorText
            return
        }
        infoLabel.stringValue = hits.isEmpty
            ? "Keine Treffer für „\(query)“."
            : "\(hits.count) Treffer für „\(query)“."
    }

    // ---------- Übergabe an die große GUI (ab 20 Treffern) ----------

    func handOffToMainApp() {
        handedOff = true
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        let root = searchRoot
        // Die schon gefundenen (max. 20) Treffer als JSONL-Datei ablegen.
        let resultsFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("favenio-quick-\(UUID().uuidString).jsonl")
        do { try jsonlData(for: hits).write(to: resultsFile) } catch {
            // Übergabe nicht möglich → wenigstens die 20 hier bedienbar lassen.
            handedOff = false
            infoLabel.stringValue = "Konnte Treffer nicht zwischenspeichern."
            return
        }
        cancelSearch()   // eigenen Suchlauf stoppen
        openMainApp(query: query, root: root, resultsFile: resultsFile)
    }

    func openMainApp(query: String, root: String, resultsFile: URL) {
        // Weg 1: URL-Schema — mit continue=1 setzt die große GUI die Suche
        // live fort (zeigt die 20 sofort). Optionen mitgeben, damit sie mit
        // denselben Einstellungen weitersucht.
        var components = URLComponents()
        components.scheme = "favenio"
        components.host = "results"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "root", value: root),
            URLQueryItem(name: "file", value: resultsFile.path),
            URLQueryItem(name: "content",
                         value: contentCheckbox.state == .on ? "1" : "0"),
            URLQueryItem(name: "archives",
                         value: archivesCheckbox.state == .on ? "1" : "0"),
            URLQueryItem(name: "hidden",
                         value: hiddenCheckbox.state == .on ? "1" : "0"),
            URLQueryItem(name: "continue", value: "1"),
        ]
        if let url = components.url, NSWorkspace.shared.open(url) {
            NSApp.terminate(nil)
            return
        }
        // Weg 2 (Fallback): Favenio.app direkt starten (ohne Weitersuchen).
        guard let appURL = locateMainApp() else {
            infoLabel.stringValue =
                "Favenio.app nicht gefunden — bitte einmal manuell starten."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--query", query,
                                   "--results-file", resultsFile.path]
        NSWorkspace.shared.openApplication(at: appURL,
                                           configuration: configuration) {
            _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Die große Favenio.app finden: über die Bundle-ID (LaunchServices)
    /// oder als Nachbarin im selben Ordner wie diese App.
    func locateMainApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "local.favenio") {
            return url
        }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Favenio.app")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    // ---------- Trefferliste (Anzeige + Öffnen) ----------

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let column = tableColumn, row < hits.count else { return nil }
        var cell = tableView.makeView(withIdentifier: column.identifier,
                                      owner: nil) as? NSTableCellView
        if cell == nil {
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
                label.centerYAnchor.constraint(equalTo: newCell.centerYAnchor),
            ])
            cell = newCell
        }
        let hit = hits[row]
        cell?.textField?.stringValue =
            column.identifier.rawValue == "name" ? hit.displayName : hit.path
        return cell
    }

    /// Zeilen, auf die sich eine Aktion bezieht: die geklickte Zeile, sonst
    /// die Auswahl.
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
                infoLabel.stringValue = "Konnte nicht öffnen: \(hits[row].path)"
            }
        }
    }

    // ---------- Rechtsklick-Menü (Öffnen / Öffnen mit / …) ----------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        guard contextRow >= 0, contextRow < hits.count else { return }
        let hit = hits[contextRow]

        menu.addItem(withTitle: "Öffnen", action: #selector(openSelected),
                     keyEquivalent: "").target = self

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
        menu.addItem(withTitle: "Im Finder zeigen", action: #selector(ctxReveal),
                     keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pfad kopieren", action: #selector(ctxCopyPath),
                     keyEquivalent: "").target = self
    }

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
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row].path) : nil
        }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    @objc func ctxCopyPath() {
        let paths = actionRows().compactMap { row in
            row < hits.count ? hits[row].path : nil
        }
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
