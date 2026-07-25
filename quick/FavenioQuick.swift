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
import Quartz   // QLPreviewPanel (QuickLook-Vorschau)

@main
struct FavenioQuickApp {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            if let error = validateSparkleConfiguration(
                expectedBundleIdentifier: "local.favenio.quick"
            ) {
                print("SELFTEST FEHLER: \(error)")
                exit(1)
            }
            print("SELFTEST OK — Sparkle-Anbindung der Schnellsuche "
                  + "funktioniert")
            exit(0)
        }
        // Headless-Diagnose: was sieht DIESES Bundle beim Finder wirklich?
        if CommandLine.arguments.contains("--finder-scope") {
            runFinderScopeDiagnostic()
        }
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
                             NSMenuDelegate,
                             QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    /// Die Schnellsuche ist ein eigenes App-Bundle und aktualisiert deshalb
    /// sich selbst aus demselben signierten Favenio-DMG wie die Haupt-App.
    private let updaterController = makeUpdaterController()
    static let hint = "Return oder 0,6 s Pause startet die Suche · Esc beendet"
    static let debounceInterval: TimeInterval = 0.6
    static let maxQuickHits = 20        // ab hier übernimmt die große GUI
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 420   // Default; Fenster ist resizable

    var panel: NSPanel!
    let field = NSSearchField()
    let scopePopup = NSPopUpButton()    // Suchbereich (Finder-Fenster / Ordner)
    let archivesCheckbox = NSButton(checkboxWithTitle: "In Archiven",
                                    target: nil, action: nil)
    let contentCheckbox = NSButton(checkboxWithTitle: "Inhalt",
                                   target: nil, action: nil)
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Unsichtbare",
                                  target: nil, action: nil)
    // Ohne diesen Schalter ist ein Muster ohne Platzhalter ein Teilstring:
    // „release.sh" fände dann auch „test-github-release.sh".
    let exactCheckbox = NSButton(checkboxWithTitle: "Genauer Name",
                                 target: nil, action: nil)
    // Öffnet die große Favenio.app mit den Treffern (zum Sortieren / für mehr
    // als die Top 20). Früher sprang Quick automatisch dorthin — jetzt nur
    // noch auf Klick bzw. Cmd+Return.
    // Das Kürzel steht IM Titel: AppKit zeigt keinen Hinweis auf den
    // Tastaturmonitor, der Cmd+Return abfängt.
    let openButton = NSButton(title: "Alle in Favenio ↗ ⌘↩",
                              target: nil, action: nil)
    let infoLabel = NSTextField(labelWithString: QuickController.hint)
    let spinner = NSProgressIndicator()
    let tableView = NSTableView()
    let scrollView = NSScrollView()

    var searchRoot = NSHomeDirectory()  // Wurzel des laufenden Suchlaufs
    var searching = false

    var scopeFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    var refreshingScope = false
    var userPickedScope = false             // hat der Nutzer selbst gewählt?
    // Steht die Antwort des Finders für DIESE Aktivierung schon fest? Solange
    // nicht, ist der Suchbereich unbekannt — und eine Suche darf nicht
    // ersatzweise im Benutzerordner loslaufen (genau das suchte im falschen
    // Ordner, ohne es zu sagen).
    var scopeResolved = false
    var scopeProblem: String?               // warum kein Finder-Ordner da ist
    var scopeDenied = false                 // Automation ausdrücklich verboten
    var deniedAlertShown = false            // Hinweis höchstens einmal pro Start
    var queuedQuery = false                 // Suche wartet auf den Suchbereich
    var scopeWaitTimer: Timer?
    /// So lange wartet eine Suche höchstens auf den Finder-Ordner; danach
    /// läuft sie im Ersatzordner — mit sichtbarem Hinweis.
    static let scopeWaitLimit: TimeInterval = 2.0

    // Debounce + Abbruch: nach der letzten Taste 0,6 s warten, dann suchen;
    // Weitertippen bricht den laufenden favenio.py-Prozess ab. Nur das
    // Ergebnis der AKTUELLEN Generation zählt.
    var debounceTimer: Timer?
    var flushTimer: Timer?
    var runningProcess: Process?
    var searchGeneration = 0

    var hits: [Hit] = []                // was die Liste zeigt (max. 20)
    var pending: [Hit] = []             // frisch gestreamt, noch nicht gezeigt
    var contextRow = -1                 // Zeile, auf die der Rechtsklick ging
    var previewURLs: [URL] = []         // gerade in der QuickLook-Vorschau

    // ---------- App-Lebenszyklus ----------

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(appName: "Favenio Schnellsuche", includeClose: true)
        installUpdateMenuItem(updaterController: updaterController)
        buildPanel()
        showPanel()
        // Beim allerersten Start ist die App noch im Launch-Handshake —
        // NSApp.activate verpufft dann. Ein zweites Aktivieren im nächsten
        // Runloop-Durchlauf holt das Fenster zuverlässig nach vorn.
        DispatchQueue.main.async { [weak self] in self?.showPanel() }

        // Tastatur: Esc (leeres Feld) beendet; Cmd+Return öffnet die Haupt-App;
        // Leertaste in der Trefferliste zeigt die QuickLook-Vorschau.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.field.stringValue.isEmpty {  // Escape
                NSApp.terminate(nil)
                return nil
            }
            if event.keyCode == 36,                        // 36 = Return
               event.modifierFlags.contains(.command), !self.hits.isEmpty {
                self.openInMainApp()
                return nil
            }
            if event.keyCode == 49,                        // 49 = Leertaste
               self.panel.firstResponder === self.tableView {
                self.togglePreview()
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

    /// App ist vorderste geworden → JETZT den Finder abfragen: nur so zeigt
    /// TCC den Automations-Consent-Dialog. Läuft im Hintergrund (kein Hang).
    /// Jede Aktivierung fragt neu, denn inzwischen kann ein anderes
    /// Finder-Fenster vorn sein; bis die Antwort da ist, gilt der Suchbereich
    /// als unbekannt.
    func applicationDidBecomeActive(_ notification: Notification) {
        scopeResolved = false
        refreshFinderFoldersAsync()
        rebuildScopePopup()
    }

    /// Fenster geschlossen (roter Knopf / Cmd+W) → App beenden.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelSearch()
        cleanupMaterializedHits()
    }

    // ---------- Aufbau ----------

    func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.windowWidth,
                                height: Self.windowHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 420, height: 200)
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
        // Der Titel endet auf dem Pfad — deshalb VORNE kürzen, damit bei
        // knappem Platz der Ordner sichtbar bleibt und nicht die Beschriftung.
        (scopePopup.cell as? NSPopUpButtonCell)?.lineBreakMode =
            .byTruncatingHead

        for checkbox in [archivesCheckbox, contentCheckbox, hiddenCheckbox,
                         exactCheckbox] {
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

        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = NSFont.systemFont(ofSize: 11)
        openButton.target = self
        openButton.action = #selector(openInMainApp)
        openButton.isEnabled = false        // erst wenn es Treffer gibt

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
                                             hiddenCheckbox, exactCheckbox,
                                             openButton])
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

        // Die Trefferliste füllt den restlichen Platz (Fenster ist resizable);
        // deshalb niedrige vertikale Hugging-Priorität und Boden-Anker.
        scrollView.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                             for: .vertical)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 12),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -12),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                          constant: -12),
            searchRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            infoRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: outer.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 32),
            // Breiter als früher: Der Suchbereich zeigt jetzt den Pfad.
            scopePopup.widthAnchor.constraint(equalToConstant: 250),
        ])

        // Immer in Default-Größe oben-mittig öffnen (Spotlight-Gefühl).
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
        tableView.headerView = nil          // schlichte Liste, keine Spaltenköpfe
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

    // ---------- Suchbereich (Finder-Fenster / Ordner) ----------

    /// Den Platzhalter „wird ermittelt…" auszuwählen ist keine eigene Wahl —
    /// sonst folgte die App danach nicht mehr dem vordersten Finder-Fenster.
    @objc func scopeChanged() {
        userPickedScope = scopePopup.selectedItem?.representedObject != nil
    }

    /// Füllt das Bereichs-Menü aus dem Cache (schnell, kein AppleScript). Die
    /// Finder-Fenster lädt applicationDidBecomeActive nach — der Apple-Event
    /// darf nur laufen, wenn die App vorderste ist (sonst erscheint kein
    /// TCC-Consent-Dialog) und nie auf dem Main-Thread (sonst Hang).
    func updateScope() {
        rebuildScopePopup()
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
        // Solange die Finder-Antwort aussteht, steht oben ein Platzhalter OHNE
        // Pfad. Damit ist der unbekannte Suchbereich sichtbar, und startSearch()
        // erkennt am fehlenden Pfad, dass es kurz warten muss.
        if !scopeResolved {
            scopePopup.addItem(withTitle: "Finder-Ordner wird ermittelt…")
            scopePopup.lastItem?.toolTip =
                "Favenio fragt gerade den Finder nach dem vordersten Fenster."
        }
        // Jeder Finder-Eintrag trägt den PFAD, nicht nur den Ordnernamen: Erst
        // damit sieht man, ob wirklich der gemeinte Ordner durchsucht wird —
        // „git" gibt es unter mehreren Elternordnern.
        for (index, path) in scopeFinderFolders.enumerated() {
            let shown = abbreviateHome(path)
            add(index == 0 ? "Finder-Fenster: \(shown)" : shown, path)
        }
        for (title, path) in commonFolders() { add(title, path) }
        // Ein selbst gewählter Ordner bleibt wählbar, auch wenn sein
        // Finder-Fenster inzwischen zu ist — sonst spränge die Auswahl
        // kommentarlos auf den ersten Eintrag.
        if userPickedScope, let previous, !added.contains(previous) {
            add(abbreviateHome(previous), previous)
        }
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
        // Läuft im Hintergrund (osascript-Unterprozess) — der Main-Thread
        // blockiert NIE.
        finderWindowFoldersAsync { [weak self] outcome in
            self?.applyScopeOutcome(outcome)
        }
    }

    /// Antwort des Finders verarbeiten. Wichtig: Ein Fehlschlag wird GEMELDET
    /// statt stillschweigend auf den Benutzerordner zurückzufallen.
    func applyScopeOutcome(_ outcome: FinderScopeOutcome) {
        refreshingScope = false
        scopeResolved = true
        scopeProblem = outcome.problemText
        if case .denied = outcome { scopeDenied = true } else { scopeDenied = false }
        if case .folders(let folders) = outcome { scopeFinderFolders = folders }
        rebuildScopePopup()

        if let problem = scopeProblem, !searching {
            showScopeProblem(problem)
        }
        // Kam die Finder-Antwort erst, nachdem eine Suche im Ersatzordner
        // angelaufen ist: sagen, wo der Finder steht. Die laufende Suche wird
        // NICHT hinter dem Rücken des Nutzers umgehängt.
        if scopeProblem == nil, searching, !userPickedScope,
           let front = scopeFinderFolders.first, front != searchRoot {
            showScopeProblem("Suche läuft in " + abbreviateHome(searchRoot)
                             + " — Finder-Ordner ist "
                             + abbreviateHome(front) + " (Return sucht dort).")
        }
        if scopeDenied { maybeReportDeniedAutomation() }

        // Auf den Suchbereich wartende Suche jetzt starten.
        if queuedQuery {
            queuedQuery = false
            scopeWaitTimer?.invalidate(); scopeWaitTimer = nil
            startSearch()
        }
    }

    /// Der Finder hat innerhalb der Wartezeit nicht geantwortet: Suche trotzdem
    /// starten, aber sagen, dass der Bereich nur der Ersatzordner ist.
    func scopeWaitExpired() {
        guard queuedQuery else { return }
        queuedQuery = false
        scopeResolved = true      // Platzhalter weg, sonst wartet es ewig
        // Wartet macOS gerade auf die Freigabe, ist „antwortet nicht" falsch —
        // dann steht der Dialog noch offen und die Antwort kommt danach.
        scopeProblem = finderAutomationConsentPending()
            ? "macOS fragt gerade nach der Finder-Freigabe."
            : "Finder-Ordner steht noch aus — Suchbereich nicht bestätigt."
        rebuildScopePopup()
        startSearch()
    }

    /// Problemtext sichtbar (nicht grau) in die Info-Zeile schreiben.
    func showScopeProblem(_ problem: String) {
        infoLabel.textColor = .systemOrange
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = problem
        infoLabel.toolTip = problem
    }

    /// Verbotene Finder-Automation ist nichts, was man nur klein in die
    /// Info-Zeile schreibt: einmal pro Start ausdrücklich melden — mit dem Weg
    /// zur Freigabe und der Möglichkeit, das künftig zu lassen.
    func maybeReportDeniedAutomation() {
        let suppressKey = "FavenioSuppressAutomationAlert"
        if deniedAlertShown { return }
        if UserDefaults.standard.bool(forKey: suppressKey) { return }
        deniedAlertShown = true

        let alert = NSAlert()
        alert.messageText = "Finder-Ordner nicht abfragbar"
        alert.informativeText = """
            macOS erlaubt der Schnellsuche nicht, den Finder nach dem \
            vordersten Fenster zu fragen. Deshalb kann Favenio den Ordner \
            nicht übernehmen, in dem du gerade bist — der Suchbereich muss \
            von Hand gewählt werden.

            Freigeben: Systemeinstellungen → Datenschutz & Sicherheit → \
            Automation → „Favenio Schnellsuche" → Finder aktivieren.
            """
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Später")
        alert.addButton(withTitle: "Nicht mehr melden")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAutomationSettings()
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: suppressKey)
        default:
            break
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
            tableView.reloadData()
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
        scopeWaitTimer?.invalidate(); scopeWaitTimer = nil
        queuedQuery = false
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

        // Der ausgewählte Eintrag trägt keinen Pfad → der Finder-Ordner steht
        // noch aus. Dann NICHT ersatzweise im Benutzerordner suchen, sondern
        // kurz warten; das ist sichtbar und endet spätestens nach
        // `scopeWaitLimit` (scopeWaitExpired sucht dann mit Hinweis weiter).
        guard let root = scopePopup.selectedItem?.representedObject as? String
        else {
            queuedQuery = true
            spinner.startAnimation(nil)
            infoLabel.textColor = .secondaryLabelColor
            infoLabel.stringValue = "Finder-Ordner wird ermittelt…"
            scopeWaitTimer = Timer.scheduledTimer(
                withTimeInterval: Self.scopeWaitLimit, repeats: false) {
                [weak self] _ in self?.scopeWaitExpired()
            }
            return
        }

        let generation = searchGeneration
        hits = []
        openButton.isEnabled = false
        tableView.reloadData()
        searching = true
        spinner.startAnimation(nil)
        // Immer sagen, WO gesucht wird — und warum es nicht der Finder-Ordner
        // ist, falls dessen Abfrage schiefging.
        searchRoot = root
        if let problem = scopeProblem {
            showScopeProblem("Suche in " + abbreviateHome(root) + " — "
                             + problem)
        } else {
            infoLabel.textColor = .secondaryLabelColor
            infoLabel.stringValue = "Suche in " + abbreviateHome(root) + " …"
            infoLabel.toolTip = root
        }
        let searchContent = contentCheckbox.state == .on
        let searchArchives = archivesCheckbox.state == .on
        let searchHidden = hiddenCheckbox.state == .on
        let searchExact = exactCheckbox.state == .on

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
                includeHidden: searchHidden, exact: searchExact)
            else {
                DispatchQueue.main.async {
                    guard let self, generation == self.searchGeneration
                    else { return }
                    self.finish(query: query,
                                errorText: "favenio.py nicht gefunden.")
                }
                return
            }
            let exitCode = runSearchStreaming(arguments: arguments,
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
                let errorText = exitCode == 2
                    ? "Suche fehlgeschlagen. Bitte Favenio erneut installieren."
                    : nil
                self.finish(query: query, errorText: errorText)
            }
        }
    }

    /// Zeigt den gerade durchsuchten Ort dezent in der Info-Zeile. Steht dort
    /// eine Warnung zum Suchbereich, bleibt die stehen — sie ist wichtiger als
    /// der laufende Ort.
    func showProgress(path: String) {
        guard searching, hits.isEmpty, pending.isEmpty, scopeProblem == nil
        else { return }
        infoLabel.textColor = .tertiaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.stringValue = "Durchsuche " + abbreviateHome(path)
    }

    /// Gebündelt anzeigen. Bei 20 Treffern STOPPT die Suche (Top 20 reichen
    /// meist) — der Rest bzw. das Sortieren läuft auf Wunsch in der Haupt-App
    /// (Button „Alle in Favenio ↗" oder Cmd+Return), nicht mehr automatisch.
    func flushPending() {
        guard !pending.isEmpty else { return }
        // Auswahl über den reloadData hinweg festhalten (fürs QuickLook).
        let selectedPaths = Set(tableView.selectedRowIndexes.compactMap {
            $0 < hits.count ? hits[$0].path : nil
        })
        let room = Self.maxQuickHits - hits.count
        if room > 0 { hits.append(contentsOf: pending.prefix(room)) }
        pending = []
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        tableView.reloadData()
        if !selectedPaths.isEmpty {
            let rows = IndexSet(hits.indices.filter {
                selectedPaths.contains(hits[$0].path)
            })
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
        openButton.isEnabled = !hits.isEmpty
        if hits.count >= Self.maxQuickHits {
            cancelSearch()   // Top 20 erreicht → Suche stoppen
            infoLabel.stringValue =
                "Top \(Self.maxQuickHits) — ⌘↩ öffnet alle in Favenio"
        } else {
            infoLabel.stringValue = "\(hits.count) Treffer — Suche läuft…"
        }
    }

    /// Suche natürlich fertig (weniger als 20 Treffer): Endstand zeigen.
    func finish(query: String, errorText: String?) {
        flushPending()
        cancelSearch()
        openButton.isEnabled = !hits.isEmpty
        if let errorText {
            infoLabel.stringValue = errorText
            return
        }
        let summary = hits.isEmpty
            ? "Keine Treffer für „\(query)“ in \(abbreviateHome(searchRoot))."
            : "\(hits.count) Treffer für „\(query)“."
        // Gerade wenn NICHTS gefunden wurde, muss ein unklarer Suchbereich
        // dabeistehen — sonst sucht man den Fehler beim Suchbegriff.
        if let problem = scopeProblem {
            showScopeProblem(summary + " " + problem)
        } else {
            infoLabel.stringValue = summary
        }
    }

    // ---------- Übergabe an die große GUI (auf Wunsch) ----------

    /// Button „Alle in Favenio ↗" bzw. Cmd+Return: die schon gefundenen
    /// Treffer an die Haupt-App übergeben, die sie sofort zeigt und die Suche
    /// vollständig fortsetzt (dort kann man sortieren und alle sehen).
    @objc func openInMainApp() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let root = searchRoot
        let resultsFile: URL
        do { resultsFile = try writeQuickHandoff(hits) } catch {
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
            URLQueryItem(name: "exact",
                         value: exactCheckbox.state == .on ? "1" : "0"),
            URLQueryItem(name: "continue", value: "1"),
        ]
        if let url = components.url, NSWorkspace.shared.open(url) {
            NSApp.terminate(nil)
            return
        }
        // Weg 2 (Fallback): Favenio.app direkt starten (ohne Weitersuchen).
        guard let appURL = locateMainApp() else {
            try? FileManager.default.removeItem(at: resultsFile)
            infoLabel.stringValue =
                "Favenio.app nicht gefunden — bitte einmal manuell starten."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--query", query,
                                   "--results-file", resultsFile.path]
        NSWorkspace.shared.openApplication(at: appURL,
                                           configuration: configuration) {
            _, error in
            DispatchQueue.main.async {
                if error == nil {
                    NSApp.terminate(nil)
                } else {
                    try? FileManager.default.removeItem(at: resultsFile)
                    self.infoLabel.stringValue =
                        "Favenio.app konnte nicht gestartet werden."
                }
            }
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
            if let url = materializeHit(hits[row]) {
                NSWorkspace.shared.open(url)
            } else {
                infoLabel.stringValue = "Konnte nicht öffnen: \(hits[row].path)"
            }
        }
    }

    // ---------- QuickLook-Vorschau ----------

    @objc func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func rebuildPreviewURLs() {
        // Vorschau folgt der AUSWAHL, nicht dem alten Rechtsklick (das war der
        // „immer dieselbe Datei"-Fehler).
        var rows = Array(tableView.selectedRowIndexes)
        if rows.isEmpty, tableView.clickedRow >= 0 {
            rows = [tableView.clickedRow]
        }
        previewURLs = rows.compactMap { row in
            row < hits.count ? materializeHit(hits[row]) : nil
        }
    }

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

    func tableViewSelectionDidChange(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            rebuildPreviewURLs()
            QLPreviewPanel.shared().reloadData()
        }
    }

    // ---------- Rechtsklick-Menü (Öffnen / Öffnen mit / …) ----------

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        guard contextRow >= 0, contextRow < hits.count else { return }
        let hit = hits[contextRow]

        menu.addItem(withTitle: "Vorschau (Leertaste)",
                     action: #selector(togglePreview),
                     keyEquivalent: "").target = self
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
            row < hits.count ? materializeHit(hits[row]) : nil
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc func ctxReveal() {
        let urls = actionRows().compactMap { row in
            row < hits.count ? materializeHit(hits[row]) : nil
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
