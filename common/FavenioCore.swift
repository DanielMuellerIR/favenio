// Gemeinsamer Unterbau für Favenio.app (große GUI) und FavenioQuick.app
// (Schnellsuche für die Finder-Toolbar).
//
// Wichtigstes Prinzip: Der eigentliche Suchmotor ist und bleibt favenio.py.
// Die Swift-Apps sind nur Frontends — sie starten den Python-Kern als
// Unterprozess und lesen dessen JSONL-Ausgabe (--json). So gibt es genau
// EINE Suchlogik, die auch headless (CLI, AI-Agenten) identisch arbeitet.

import AppKit
import Darwin
import Quartz   // QLPreviewPanel (QuickLook-Vorschau)
import Sparkle
import UniformTypeIdentifiers

/// Pfad zum System-Python (auf jedem Mac mit Xcode-CLT vorhanden).
let pythonPath = "/usr/bin/python3"

/// Erzeugt pro App-Prozess genau einen langlebigen Sparkle-Controller.
/// Die aufrufenden Controller halten ihn als Feld über die gesamte Laufzeit.
func makeUpdaterController() -> SPUStandardUpdaterController {
    SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Verdrahtet „Nach Updates suchen …" direkt auf Sparkle. Dadurch validiert
/// Sparkle den Eintrag auch während einer laufenden Suche oder Installation.
func installUpdateMenuItem(
    updaterController: SPUStandardUpdaterController
) {
    guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
    let identifier = NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")

    if let existing = appMenu.items.first(where: {
        $0.identifier == identifier
    }) {
        existing.action =
            #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        existing.target = updaterController
        return
    }

    let item = NSMenuItem(
        title: "Nach Updates suchen …",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    item.identifier = identifier
    item.target = updaterController

    let quitIndex = appMenu.items.firstIndex(where: {
        $0.action == #selector(NSApplication.terminate(_:))
    }) ?? appMenu.items.count
    appMenu.insertItem(item, at: quitIndex)
    appMenu.insertItem(.separator(), at: quitIndex + 1)
}

/// Prüft ohne Fenster oder Netzwerkzugriff die sicherheitsrelevante
/// Sparkle-Konfiguration des tatsächlich gebauten App-Bundles.
func validateSparkleConfiguration(
    expectedBundleIdentifier: String
) -> String? {
    let info = Bundle.main.infoDictionary ?? [:]
    guard Bundle.main.bundleIdentifier == expectedBundleIdentifier else {
        return "unerwartete Bundle-ID"
    }
    guard let feed = info["SUFeedURL"] as? String,
          let feedURL = URL(string: feed),
          feedURL.scheme == "https",
          feedURL.host != nil else {
        return "Sparkle-Feed ist keine gültige HTTPS-URL"
    }
    guard info["SUPublicEDKey"] as? String == favenioSparklePublicKey,
          info["SUEnableAutomaticChecks"] as? Bool == true,
          info["SUAutomaticallyUpdate"] as? Bool == false,
          info["SUAllowsAutomaticUpdates"] as? Bool == false,
          info["SUEnableSystemProfiling"] as? Bool == false,
          info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
          info["SURequireSignedFeed"] as? Bool == true else {
        return "Sparkle-Signatur-, Update- oder Datenschutzwerte fehlen"
    }
    guard let frameworks = Bundle.main.privateFrameworksURL,
          FileManager.default.fileExists(
              atPath: frameworks.appendingPathComponent(
                  "Sparkle.framework"
              ).path
          ) else {
        return "Sparkle.framework fehlt im App-Bundle"
    }

    // Der normale App-Start erzeugt NSApplication vor dem Controller. Der
    // Headless-Pfad muss dieselbe Grundlage ohne Runloop ausdrücklich anlegen.
    _ = NSApplication.shared
    // Separater, nicht gestarteter Controller: kein Feed-Abruf, aber der Test
    // beweist, dass Framework, Selector und Menüverdrahtung wirklich laden.
    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    installMainMenu(appName: "Favenio Selbsttest")
    installUpdateMenuItem(updaterController: controller)
    guard let item = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first(
        where: {
            $0.identifier
                == NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")
        }
    ),
    item.action == #selector(
        SPUStandardUpdaterController.checkForUpdates(_:)
    ),
    item.target === controller else {
        return "Update-Menüpunkt zielt nicht direkt auf Sparkle"
    }
    return nil
}

/// Ein einzelner Suchtreffer, wie ihn `favenio.py --json` liefert.
/// Zwischenspeicher der Typbeschreibungen, EINER je Endung.
///
/// `UTType(filenameExtension:)` samt `localizedDescription` ist eine
/// Datenbankabfrage: gemessen am 2026-09-03 mit 11,65 µs je Aufruf. Die
/// Sortierung nach der Typ-Spalte ruft sie ZWEIMAL je Vergleich, und die
/// Trefferliste wird während des Streamens mehrmals pro Sekunde neu
/// sortiert — bei 100 000 Treffern kostete ein einzelner Sortierlauf
/// dadurch 47,3 s auf dem Main-Thread, das Fenster stand.
///
/// Die Antwort hängt ausschließlich an der Endung, ein Eintrag je Endung
/// genügt also. Die Sperre ist nötig, weil auch der Zellenaufbau und ein
/// künftiger Hintergrundpfad hier hereinkommen können.
final class TypeDescriptionCache {
    private let lock = NSLock()
    private var byExtension: [String: String] = [:]

    func description(for ext: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = byExtension[ext] { return cached }
        var result = ext.uppercased()
        if let type = UTType(filenameExtension: ext),
           let localized = type.localizedDescription {
            result = localized
        }
        byExtension[ext] = result
        return result
    }
}

extension Hit {
    /// Menschlicher Dateityp für die Typ-Spalte: „Ordner" bei Verzeichnissen,
    /// sonst die lokalisierte Typbeschreibung der Endung (z. B. „PDF-Dokument"),
    /// ersatzweise die Endung groß bzw. „Datei" ohne Endung.
    var typeDescription: String {
        if isDirectory { return "Ordner" }
        let ext = (displayName as NSString).pathExtension
        if ext.isEmpty { return "Datei" }
        return typeDescriptions.description(for: ext.lowercased())
    }
}

let typeDescriptions = TypeDescriptionCache()

/// Selektoren der fünf Dateiaktionen im gemeinsamen Kontextmenü. Die beiden
/// Apps verwenden andere Methoden für „Öffnen", der Menüaufbau selbst bleibt
/// dadurch trotzdem an genau einer Stelle.
struct HitContextMenuSelectors {
    let preview: Selector
    let open: Selector
    let openWith: Selector
    let reveal: Selector
    let copyPath: Selector
}

/// Zeilen einer Tabellenaktion nach der AppKit-Konvention: Ein Rechtsklick
/// außerhalb der Auswahl meint nur seine Zeile; ein Klick innerhalb der
/// Auswahl meint die ganze Auswahl. Ohne Kontextzeile gilt die Auswahl.
func hitActionRows(selectedRows: IndexSet, contextRow: Int) -> [Int] {
    if contextRow >= 0, !selectedRows.contains(contextRow) {
        return [contextRow]
    }
    if !selectedRows.isEmpty { return Array(selectedRows) }
    return contextRow >= 0 ? [contextRow] : []
}

/// Ergebnis des gemeinsamen Materialisierungspfads für Öffnen, Öffnen mit,
/// Finder-Anzeige und Vorschau. `unavailable` enthält sowohl Ordner im Archiv
/// als auch Treffer, deren Extraktion wirklich fehlgeschlagen ist.
struct MaterializedHitSelection {
    let rows: [Int]
    let urls: [URL]
    let unavailable: [Hit]
    /// Der konkrete Grund je Auspackfehler (nur für Treffer mit
    /// `hasOpenableFile`), in der Reihenfolge von `unavailable`.
    var reasons: [String] = []
    /// Wurde der Auftrag vor Zustellung des Gesamtergebnisses abgebrochen?
    /// Dann sind `urls` und `unavailable` unvollständig und keine Grundlage
    /// für eine Aktion.
    var cancelled = false
}

/// Griff auf die Materialisierung einer ganzen Zeilenmenge: bricht alle
/// noch laufenden Einzelaufträge ab. Die Completion kommt danach genau
/// einmal mit `cancelled == true`.
final class MaterializationSelectionRequest {
    private var children: [MaterializationRequest] = []
    private(set) var isCancelled = false

    fileprivate func add(_ request: MaterializationRequest) {
        if isCancelled { request.cancel() } else { children.append(request) }
    }

    func cancel() {
        isCancelled = true
        children.forEach { $0.cancel() }
        children.removeAll()
    }
}

/// Materialisiert eine FESTE Zeilenmenge asynchron und liefert das Ergebnis
/// in einem Stück — auf der Main-Queue, oder sofort und synchron, wenn kein
/// Treffer ausgepackt werden muss (normale Dateien, schon ausgepackte
/// Einträge). Nur von der Main-Queue rufen: Die Teilergebnisse werden dort
/// eingesammelt.
///
/// `rows` ist eine Momentaufnahme: Was danach mit der Tabelle passiert,
/// ändert den Auftrag nicht mehr — Öffnen arbeitet mit genau der Auswahl,
/// die beim Klick galt.
@discardableResult
func materializeHitSelection(
    _ hits: [Hit], rows: [Int],
    completion: @escaping (MaterializedHitSelection) -> Void)
    -> MaterializationSelectionRequest {
    let group = MaterializationSelectionRequest()
    let selected = rows.filter { hits.indices.contains($0) }.map { hits[$0] }
    var outcomes = [MaterializationOutcome?](repeating: nil,
                                             count: selected.count)
    var remaining = selected.count
    func finish() {
        var urls: [URL] = []
        var unavailable: [Hit] = []
        var reasons: [String] = []
        var cancelled = group.isCancelled
        for (hit, outcome) in zip(selected, outcomes) {
            switch outcome {
            case .ready(let url):
                urls.append(url)
            case .failed(let reason):
                unavailable.append(hit)
                if hit.hasOpenableFile { reasons.append(reason) }
            case .cancelled:
                cancelled = true
            case nil:
                cancelled = true
            }
        }
        completion(MaterializedHitSelection(
            rows: rows, urls: urls, unavailable: unavailable,
            reasons: reasons, cancelled: cancelled))
    }
    guard !selected.isEmpty else {
        finish()
        return group
    }
    for (index, hit) in selected.enumerated() {
        let request = MaterializationManager.shared.request(hit) { outcome in
            outcomes[index] = outcome
            remaining -= 1
            if remaining == 0 { finish() }
        }
        if let request { group.add(request) }
    }
    return group
}

/// Synchrone Fassung für den Headless-Selbsttest und Werkzeuge. Die Apps
/// rufen sie NIE aus einer Aktion — dort gilt die Completion-Fassung; ein
/// Wächter-Test hält das fest.
func materializeHitSelection(_ hits: [Hit], rows: [Int])
    -> MaterializedHitSelection {
    var urls: [URL] = []
    var unavailable: [Hit] = []
    for row in rows where hits.indices.contains(row) {
        let hit = hits[row]
        if let url = materializeHit(hit) {
            urls.append(url)
        } else {
            unavailable.append(hit)
        }
    }

    return MaterializedHitSelection(rows: rows, urls: urls,
                                    unavailable: unavailable)
}

/// Eine verständliche Meldung für ausgelassene Treffer. Die Controller
/// entscheiden nur noch, ob sie sie in Status- oder Infozeile anzeigen.
func hitActionIssue(_ selection: MaterializedHitSelection)
    -> (summary: String, detail: String?)? {
    if selection.rows.isEmpty {
        return ("Kein Treffer ausgewählt.", nil)
    }
    // Beide Gruppen getrennt zählen und BEIDE melden. Vorher gewann der
    // Archivordner sofort: Eine Auswahl aus einem Archivordner und einem
    // beschädigten Archivmitglied nannte nur den ausgelassenen Ordner, der
    // echte Auspackfehler blieb unsichtbar (Review-Fund 2026-08-21).
    let archiveFolders = selection.unavailable.filter { !$0.hasOpenableFile }
    let extractionFailures = selection.unavailable.filter { $0.hasOpenableFile }

    var parts: [String] = []
    if !archiveFolders.isEmpty {
        parts.append(archiveFolders.count == 1
            ? "Ordner im Archiv — keine Datei zum Öffnen."
            : "\(archiveFolders.count) Ordner im Archiv wurden ausgelassen.")
    }
    if !extractionFailures.isEmpty {
        parts.append(extractionFailures.count == 1
            ? "Konnte nicht auspacken."
            : "\(extractionFailures.count) Treffer ließen sich nicht auspacken.")
    }
    guard !parts.isEmpty else { return nil }
    // Der Detailpfad nennt den ersten betroffenen Treffer in derselben
    // Reihenfolge, in der die Meldung die Gruppen aufzählt; bei einem
    // Auspackfehler steht der konkrete Grund des Kerns dahinter.
    if let folder = archiveFolders.first {
        return (parts.joined(separator: " "), folder.path)
    }
    let failure = extractionFailures.first
    let reason = selection.reasons.first.map { " — " + $0 } ?? ""
    return (parts.joined(separator: " "), failure.map { $0.path + reason })
}

/// Schnittmenge der Anwendungen über ALLE öffenbaren Treffer der Auswahl.
///
/// Das Untermenü „Öffnen mit" richtete sich früher allein nach dem ERSTEN
/// öffenbaren Treffer, während `ctxOpenWith` danach sämtliche materialisierten
/// URLs derselben Mehrfachauswahl an die eine gewählte Anwendung übergab. Bei
/// gemischten Dateitypen bot das Menü deshalb eine Anwendung an, die die
/// übrigen Dateien gar nicht öffnen kann (Review-Fund 2026-08-21).
///
/// Die Reihenfolge des ersten Treffers bleibt erhalten — dessen Standard-App
/// steht dort vorn und soll auch im Menü vorn stehen.
///
/// LaunchServices wird je Dateiendung nur EINMAL gefragt: Der Aufruf läuft
/// beim Öffnen des Rechtsklick-Menüs auf dem Main-Thread, und bei einer
/// großen, gleichartigen Auswahl (tausend `.txt`) kostete die Abfrage je
/// Treffer sichtbar Zeit, obwohl sich der Anwendungssatz für dieselbe Endung
/// wiederholt (Review-Fund 2026-09-02). Ohne Endung wird je Treffer gefragt.
///
/// Ebenso wird je Endung nur EINMAL geschnitten. Eine Endung, gegen die
/// `common` schon gefiltert wurde, kann nichts mehr wegnehmen: `common` war
/// damals eine Teilmenge ihrer Anwendungsmenge und ist seither nur kleiner
/// geworden. Bis 0.34.11 lief der Schnitt trotzdem je Treffer und kostete
/// bei 100 000 gleichartigen Treffern 11,9 s statt 0,08 s — auf dem
/// Main-Thread, das Fenster stand bis zum Aufgehen des Menüs (gemessen am
/// 2026-09-10, Ergebnis beide Male dieselben Anwendungen). Es ist dieselbe
/// Fehlerklasse, die `TypeDescriptionCache` schon behoben hat: nicht die
/// Abfrage war teuer, sondern die Arbeit je Treffer drumherum.
func commonApplicationsFor(_ hits: [Hit]) -> [URL] {
    guard let first = hits.first else { return [] }
    var common = applicationsFor(first)
    // Endungen, gegen die `common` bereits geschnitten wurde. Der erste
    // Treffer zählt dazu: `common` IST seine Anwendungsmenge.
    var narrowed: Set<String> = []
    func extensionKey(_ hit: Hit) -> String? {
        // Ein Ordner namens „Fotos.txt“ hat andere öffnende Apps als eine
        // Textdatei. Auch Pakete sind Ordner und brauchen ihre eigene Abfrage.
        guard !hit.isDirectory else { return nil }
        let ext = (hit.displayName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
    if let key = extensionKey(first) { narrowed.insert(key) }
    for hit in hits.dropFirst() {
        if common.isEmpty { break }
        let key = extensionKey(hit)
        if let key, narrowed.contains(key) { continue }
        let allowed = Set(applicationsFor(hit).map { $0.standardizedFileURL })
        common = common.filter { allowed.contains($0.standardizedFileURL) }
        if let key { narrowed.insert(key) }
    }
    return common
}

/// Baut das Datei-Kontextmenü für beide Apps. `applicationHits` sind ALLE
/// öffnenbaren Treffer der wirksamen Zeilenmenge; eine leere Liste heißt, dass
/// ALLE Dateiaktionen grau bleiben. So entscheiden Menü und spätere Aktion über
/// dieselben Zeilen, auch bei einer gemischten Mehrfachauswahl — und „Öffnen
/// mit" bietet nur Anwendungen an, die JEDEN dieser Treffer öffnen können.
///
/// Das Leeren des Menüs bleibt bei den Controllern: Deren Pfad für eine
/// ungültige Zeile endet vor diesem Aufbau, sie müssen also ohnehin selbst
/// aufräumen. Ein zweites `removeAllItems()` hier war reine Doppelarbeit
/// (Review-Fund 2026-08-21).
func populateHitContextMenu(
    _ menu: NSMenu,
    applicationHits: [Hit],
    target: AnyObject,
    selectors: HitContextMenuSelectors
) {
    let openable = !applicationHits.isEmpty
    if !openable {
        let note = NSMenuItem(title: "Ordner im Archiv — keine Datei "
                                   + "zum Öffnen", action: nil,
                              keyEquivalent: "")
        note.isEnabled = false
        menu.addItem(note)
        menu.addItem(.separator())
    }

    let preview = menu.addItem(
        withTitle: "Vorschau (Leertaste)",
        action: openable ? selectors.preview : nil,
        keyEquivalent: "")
    let open = menu.addItem(
        withTitle: "Öffnen", action: openable ? selectors.open : nil,
        keyEquivalent: "")
    preview.isEnabled = openable
    open.isEnabled = openable
    if openable {
        preview.target = target
        open.target = target
    }

    let openWithItem = NSMenuItem(title: "Öffnen mit", action: nil,
                                  keyEquivalent: "")
    openWithItem.isEnabled = openable
    if openable {
        let submenu = NSMenu()
        let appURLs = commonApplicationsFor(applicationHits)
        if appURLs.isEmpty {
            // Leere Schnittmenge bei mehreren Treffern ist etwas anderes als
            // „für diesen Dateityp gibt es nichts" — das muss die Meldung sagen.
            let title = applicationHits.count > 1
                ? "Keine App öffnet alle ausgewählten Dateien"
                : "Keine passende App gefunden"
            let none = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            openWithItem.isEnabled = false
        }
        for appURL in appURLs {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let item = NSMenuItem(title: name, action: selectors.openWith,
                                  keyEquivalent: "")
            item.target = target
            item.representedObject = appURL
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            submenu.addItem(item)
        }
        openWithItem.submenu = submenu
    }
    menu.addItem(openWithItem)

    menu.addItem(.separator())
    let reveal = menu.addItem(
        withTitle: "Im Finder zeigen",
        action: openable ? selectors.reveal : nil,
        keyEquivalent: "")
    reveal.isEnabled = openable
    if openable { reveal.target = target }
    menu.addItem(withTitle: "Pfad kopieren", action: selectors.copyPath,
                 keyEquivalent: "").target = target
}

/// Vergleicht zwei Zahlen, die fehlen dürfen. Ein fehlender Wert gilt als
/// kleiner als jede echte Zahl: Ordner haben keine Größe, Namenstreffer keine
/// Zeilennummer, und beide sollen in aufsteigender Sortierung vorn stehen.
/// Findet den Python-Kern: zuerst im App-Bundle (Resources), sonst im
/// Arbeitsverzeichnis (Entwicklungs-Fallback beim Direktstart des Binarys).
func findCLI() -> String? {
    if let bundled = Bundle.main.path(forResource: "favenio", ofType: "py") {
        return bundled
    }
    // Der Rückfall auf das Arbeitsverzeichnis gilt nur für einen NACKTEN
    // Testbinär. In einem App-Bundle wäre er ein Einfallstor: Fehlt das
    // gebündelte favenio.py, führte eine notarisierte App mit Automations-
    // und Festplatten-Freigaben fremdes Python mit ihren Rechten aus —
    // `cd ~/Downloads/entpackt && open -a Favenio .` genügte. Im regulären
    // Build kann der Zweig ohnehin nicht greifen: build-app.sh kopiert
    // favenio.py in beide Resources-Ordner.
    guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
    let local = FileManager.default.currentDirectoryPath + "/favenio.py"
    if FileManager.default.fileExists(atPath: local) { return local }
    return nil
}

/// Baut die Argumentliste für einen Suchlauf des Python-Kerns.
/// nil, wenn favenio.py nicht auffindbar ist.
/// `only` begrenzt Treffer auf einen Typ: "both" (Dateien & Ordner),
/// "files" oder "dirs" — für den Drei-Wege-Umschalter der großen GUI.
/// Pixel-Grenzen eines Suchlaufs (Breite/Höhe je von/bis). nil = keine
/// Grenze. Die Oberflächen füllen sie aus vier Textfeldern; leer heißt
/// „egal".
func validatePixelFields(_ fields: [NSTextField]) -> (limits: PixelLimits, error: String?) {
    let validation = validatePixelTexts(fields.map { $0.stringValue })
    for (index, field) in fields.enumerated() {
        let error = validation.errors[index]
        field.textColor = error == nil ? .controlTextColor : .systemRed
        field.toolTip = error
        field.setAccessibilityHelp(error)
    }
    return (validation.limits, validation.errors.compactMap { $0 }.first)
}

/// Läuft in beiden Bundle-Selbsttests an den echten Controller-Feldern,
/// ohne Fenster zu öffnen oder einen Suchprozess zu starten.
func pixelFieldSelfTest(_ fields: [NSTextField], validate: () -> Bool) -> String? {
    for (inputs, valid) in [(["", "", "", ""], true),
                            (["1.000 px", "1000", "", ""], true),
                            (["-1", "", "", ""], false),
                            (["10.5", "", "", ""], false),
                            ([String(Int.max) + "0", "", "", ""], false),
                            (["1001", "1000", "", ""], false),
                            (["", "", "2", "1"], false),
                            (["", "", "1", "2"], true)] {
        for (field, input) in zip(fields, inputs) { field.stringValue = input }
        guard validate() == valid else { return "Maßvalidierung falsch: \(inputs)" }
        guard valid ? fields.allSatisfy({ $0.toolTip == nil })
                    : fields.contains(where: { $0.toolTip != nil && $0.textColor == .systemRed })
        else { return "Maßfelder markieren Fehler nicht korrekt: \(inputs)" }
    }
    for field in fields { field.stringValue = "" }
    _ = validate()
    return nil
}

/// Wie das Suchmuster gelesen wird: gegen Namen, Inhalt oder Metadaten.
final class SearchRootsEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var paths: [String]
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let table = NSTableView()
    let status = NSTextField(wrappingLabelWithString: "")
    let removeButton = NSButton(title: "Entfernen", target: nil, action: nil)
    let upButton = NSButton(title: "Nach oben", target: nil, action: nil)
    let downButton = NSButton(title: "Nach unten", target: nil, action: nil)
    let applyButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    private var completion: (([String]?) -> Void)?

    init(paths: [String]) {
        self.paths = paths
        super.init()
        window.title = "Suchbereiche"
        window.isReleasedWhenClosed = false
        let title = NSTextField(wrappingLabelWithString: "Dateien und Ordner werden in dieser Reihenfolge durchsucht. Überlappende Treffer erscheinen einmal.")
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Datei oder Ordner"; column.width = 585
        table.addTableColumn(column)
        table.headerView = nil; table.allowsMultipleSelection = true
        table.delegate = self; table.dataSource = self
        table.rowHeight = 27
        table.setAccessibilityIdentifier("searchRootsTable")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let add = NSButton(title: "Hinzufügen…", target: self, action: #selector(add))
        add.setAccessibilityIdentifier("searchRootsAdd")
        removeButton.target = self; removeButton.action = #selector(remove)
        upButton.target = self; upButton.action = #selector(up)
        downButton.target = self; downButton.action = #selector(down)
        applyButton.target = self; applyButton.action = #selector(apply)
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityIdentifier("searchRootsApply")
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [add, removeButton, upButton, downButton])
        actions.spacing = 8
        let footer = NSStackView(views: [cancel, applyButton]); footer.spacing = 8
        let content = NSStackView(views: [title, scroll, actions, status, footer])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            title.widthAnchor.constraint(equalTo: content.widthAnchor),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)])
        refresh()
    }

    func present(on parent: NSWindow, completion: @escaping ([String]?) -> Void) {
        self.completion = completion
        parent.beginSheet(window)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { paths.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard paths.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: paths[row].replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = paths[row]
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refresh() }
    @discardableResult
    func addPaths(_ incoming: [String]) -> String? {
        var updated = paths, seen = Set(paths.map { Data($0.utf8) })
        for path in incoming where seen.insert(Data(path.utf8)).inserted { updated.append(path) }
        if let problem = SearchRoots.problem(updated) { status.stringValue = problem; return problem }
        paths = updated; table.reloadData(); refresh(); return nil
    }
    func moveSelection(by offset: Int) {
        let row = table.selectedRow, next = row + offset
        guard table.selectedRowIndexes.count == 1, paths.indices.contains(row), paths.indices.contains(next) else { return }
        paths.swapAt(row, next); table.reloadData()
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        refresh()
    }
    private func refresh() {
        let selected = table.selectedRowIndexes
        removeButton.isEnabled = !selected.isEmpty
        upButton.isEnabled = selected.count == 1 && table.selectedRow > 0
        downButton.isEnabled = selected.count == 1 && table.selectedRow < paths.count - 1
        let problem = SearchRoots.problem(paths)
        applyButton.isEnabled = problem == nil
        status.stringValue = problem ?? paths.compactMap(searchRootProblem).first
            .map { $0 + " Die Liste bleibt erhalten; vor einer neuen Suche den Bereich wieder verbinden oder entfernen." }
            ?? "\(paths.count) von 16 Suchbereichen"
    }
    @objc func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true; panel.prompt = "Hinzufügen"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.addPaths(panel.urls.map { $0.path }) }
        }
    }
    @objc func remove() {
        for index in table.selectedRowIndexes.reversed() where paths.indices.contains(index) { paths.remove(at: index) }
        table.deselectAll(nil); table.reloadData(); refresh()
    }
    @objc func up() { moveSelection(by: -1) }
    @objc func down() { moveSelection(by: 1) }
    private func finish(_ value: [String]?) {
        let callback = completion; completion = nil
        window.sheetParent?.endSheet(window); window.orderOut(nil)
        callback?(value)
    }
    @objc func apply() { guard SearchRoots.problem(paths) == nil else { return }; finish(paths) }
    @objc func cancel() { finish(nil) }
}

func installSearchRootsMenu(target: AnyObject, action: Selector) {
    guard let main = NSApp.mainMenu else { return }
    let menu: NSMenu
    if let existing = main.items.first(where: { $0.submenu?.title == "Ablage" })?.submenu {
        menu = existing
    } else {
        menu = NSMenu(title: "Ablage")
        let item = NSMenuItem(title: "Ablage", action: nil, keyEquivalent: "")
        item.submenu = menu
        main.insertItem(item, at: min(1, main.numberOfItems))
    }
    let identifier = NSUserInterfaceItemIdentifier("Favenio.SearchRoots")
    let item = menu.items.first(where: { $0.identifier == identifier })
        ?? NSMenuItem(title: "Suchbereiche bearbeiten…", action: action, keyEquivalent: "o")
    item.identifier = identifier; item.target = target; item.action = action
    item.keyEquivalentModifierMask = [.command, .shift]
    if item.menu == nil {
        if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
        menu.insertItem(item, at: 0)
    }
}

// ---------- Benannte Suchvorlagen ----------

/// Eine gespeicherte Suche: Name, Suchmuster, der beim Sichern gewählte
/// Suchordner und sämtliche Optionen. Die Optionen stehen in derselben Form
/// wie in der Quick-URL (`SearchConfiguration.queryItems`): So beschreiben
/// geladene Vorlage, CLI-Argumente und Übergabe dieselbe Suche, und die
/// Rohtexte der Pixel-, Größen- und Zeitfelder bleiben unverändert — ein
/// ungültiger Wert wie „10.5" ist nach dem Laden weiter sichtbar und wird
/// wie bei der Eingabe von Hand erst beim Suchstart bemängelt.
/// Keine Trefferliste: Eine Vorlage ist eine Frage, keine Antwort.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// Erklärung der Ausschlussmuster, gezeigt vom ?-Knopf neben dem Feld.
/// Die Regeln entsprechen `--exclude` im Kern; hier stehen sie nur als Text.
let exclusionHelpText = """
Ein Muster je Zeile. Groß-/Kleinschreibung gilt immer, unabhängig vom Suchtext.

node_modules
    Ohne Schrägstrich gilt das Muster für jede einzelne Pfadkomponente: \
jeder Ordner oder jede Datei mit diesem Namen wird übersprungen.
*.log
    Platzhalter: * beliebig viele Zeichen, ? genau eines, [ab] eines aus der Menge.
Cache/*.zip
    Mit Schrägstrich gilt das Muster für den relativen Pfad ab Such- oder \
Archivwurzel; * darf dabei auch über Schrägstriche hinweg passen.

Leere Zeilen werden ignoriert, Leerzeichen gehören zum Muster. Return beginnt \
eine neue Zeile.
"""

/// Die sechs Größen-/Datumsfelder und das Ausschlussfeld beider Apps.
/// Zwei Spalten nebeneinander: links die drei Von/Bis-Zeilen, rechts das
/// mehrzeilige Ausschlussfeld. Untereinander waren beide zu breit für ihren
/// Inhalt — die Von/Bis-Felder dehnten sich über die ganze Fensterbreite,
/// das Ausschlussfeld auch, obwohl ein Muster selten länger als 30 Zeichen ist.
final class SearchFilterView: NSStackView, NSTextViewDelegate, NSTextFieldDelegate {
    let literalWildcardsCheckbox = NSButton(checkboxWithTitle: "* wörtlich", target: nil, action: nil)
    var literalWildcards: Bool {
        get { literalWildcardsCheckbox.state == .on }
        set { literalWildcardsCheckbox.state = newValue ? .on : .off }
    }
    let encodingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    var textEncoding: SearchTextEncoding {
        get { SearchTextEncoding(rawValue: encodingPopup.selectedItem?.representedObject as? String ?? "") ?? .utf8 }
        set { encodingPopup.selectItem(at: SearchTextEncoding.allCases.firstIndex(of: newValue)!) }
    }
    let exclusionsEditor = PlaceholderTextView()
    /// Weitere Suchbegriffe, einer je Zeile — alle müssen zusätzlich zum
    /// Suchfeld zutreffen (Mehrwortsuche, `--term`).
    let termsEditor = PlaceholderTextView()
    let localOnlyCheckbox = NSButton(checkboxWithTitle: "Nur lokal vorhandene Inhalte lesen", target: nil, action: nil)
    let pdfOCRCheckbox = NSButton(checkboxWithTitle: "Textlose PDF-Seiten per OCR lesen (Deutsch/Englisch)", target: nil, action: nil)
    var pdfOCR: Bool {
        get { pdfOCRCheckbox.state == .on }
        set { pdfOCRCheckbox.state = newValue ? .on : .off }
    }
    let ocrCheckbox = NSButton(checkboxWithTitle: "Bild-OCR im Dokumenttext (Deutsch/Englisch)", target: nil, action: nil)
    var ocr: Bool {
        get { ocrCheckbox.state == .on }
        set { ocrCheckbox.state = newValue ? .on : .off }
    }
    var localOnly: Bool {
        get { localOnlyCheckbox.state == .on }
        set { localOnlyCheckbox.state = newValue ? .on : .off }
    }
    let finderMetadataCheckbox = NSButton(checkboxWithTitle: "Finder-Eigenschaften erfassen", target: nil, action: nil)
    var finderMetadata: Bool {
        get { finderMetadataCheckbox.state == .on }
        set { finderMetadataCheckbox.state = newValue ? .on : .off }
    }
    let helpButton = NSButton()
    private(set) var factFields: [String: NSTextField] = [:]
    private var helpPopover: NSPopover?
    private var dateEditor: DateRangeEditor?
    var dateRanges: [String: DateRangeSpec] = [:] {
        didSet {
            for key in oldValue.keys where dateRanges[key] == nil {
                factFields[key + "-from"]?.stringValue = ""; factFields[key + "-to"]?.stringValue = ""
            }
            refreshDateRanges()
        }
    }
    var rawFacts: [String: String] {
        get { factFields.mapValues { $0.stringValue }.filter { !$0.value.isEmpty && dateRanges[String($0.key.split(separator: "-").first ?? "")] == nil } }
        set {
            for (key, field) in factFields { field.stringValue = newValue[key] ?? "" }
            refreshDateRanges()
        }
    }
    var onChange: (() -> Void)?

    /// Return trennt Muster, Leerraum gehört zum Muster. Nur wirklich
    /// leere Zeilen setzen keinen Ausschluss.
    var exclusions: [String] {
        get { exclusionsEditor.string.components(separatedBy: .newlines).filter { !$0.isEmpty } }
        set {
            exclusionsEditor.string = newValue.joined(separator: "\n")
            exclusionsEditor.needsDisplay = true
        }
    }

    /// Leere Zeilen entfallen; Leerraum bleibt Bestandteil des Begriffs,
    /// genau wie beim Muster im Suchfeld nichts getrennt wird.
    var terms: [String] {
        get { termsEditor.string.components(separatedBy: .newlines).filter { !$0.isEmpty } }
        set {
            termsEditor.string = newValue.joined(separator: "\n")
            termsEditor.needsDisplay = true
        }
    }

    /// Wie viele Filter dieser Ansicht gerade gesetzt sind: jedes nichtleere
    /// Von/Bis-Feld, jedes Ausschlussmuster und jeder weitere Begriff zählt
    /// eins; wörtliche Platzhalter zählen ebenfalls. Beide Apps zeigen die
    /// Zahl am zugeklappten Aufklapp-Schalter.
    var activeFilterCount: Int { rawFacts.count + dateRanges.count + exclusions.count + terms.count + (literalWildcards ? 1 : 0) + (textEncoding == .utf8 ? 0 : 1) + (finderMetadata ? 1 : 0) + (localOnly ? 1 : 0) + (ocr ? 1 : 0) + (pdfOCR ? 1 : 0) }

    @objc private func encodingChanged() { onChange?() }

    @objc private func literalWildcardsChanged() { onChange?() }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .top
        spacing = 16

        // Linke Spalte: Größe, Geändert, Erstellt — je „von … bis …".
        let factColumn = NSStackView()
        factColumn.orientation = .vertical
        factColumn.alignment = .leading
        factColumn.spacing = 4
        literalWildcardsCheckbox.font = .systemFont(ofSize: 11)
        literalWildcardsCheckbox.target = self
        literalWildcardsCheckbox.action = #selector(literalWildcardsChanged)
        literalWildcardsCheckbox.toolTip = "Aus: Im Inhalt und in Metadaten steht * für mindestens ein Zeichen in derselben Zeile (bla*blubb); Text davor und danach ist erlaubt; mehrere Sterne wirken wie einer, nie über Zeilenumbrüche. Namen verwenden * ? [abc] für den ganzen Namen. An: Alle Platzhalter werden wörtlich gesucht. Regex und Ausschlüsse bleiben unverändert."
        factColumn.addArrangedSubview(literalWildcardsCheckbox)
        // Nach der Gruppe zusammenfassen, nicht paarweise nach Index:
        // `all[index...index + 1]` setzte eine gerade Anzahl voraus, und ein
        // siebter Eintrag in `FactFilterOption.all` liesse beide Apps beim
        // Aufbau der Filteransicht abstuerzen. Die Gruppe steht ohnehin
        // schon in jedem Eintrag.
        var factGroups: [(name: String, options: [FactFilterOption])] = []
        for option in FactFilterOption.all {
            if factGroups.last?.name == option.group {
                factGroups[factGroups.count - 1].options.append(option)
            } else {
                factGroups.append((option.group, [option]))
            }
        }
        for group in factGroups {
            let options = group.options
            let label = NSTextField(labelWithString: group.name)
            label.font = .systemFont(ofSize: 11)
            label.widthAnchor.constraint(equalToConstant: 58).isActive = true
            var fields: [NSTextField] = []
            for option in options {
                let field = NSTextField(string: "")
                field.font = .systemFont(ofSize: 11)
                field.placeholderString = option.placeholder
                field.delegate = self
                field.toolTip = option.key.contains("size")
                    ? "Inklusive Grenze. Ganze Bytes ab 0, optional B, KiB, MiB, GiB oder TiB. Leer = keine Grenze."
                    : "Inklusive Grenze. ISO-8601-Zeitpunkt mit Z (UTC) oder Offset, z. B. 2026-09-05T12:00:00+02:00. Leer = keine Grenze."
                field.setAccessibilityLabel(option.title)
                // Breit genug für den längsten Platzhalter (ISO-Zeitpunkt mit
                // Zone), aber fest: Die Felder sollen nicht mehr die ganze
                // Fensterbreite einnehmen.
                field.widthAnchor.constraint(equalToConstant: 150).isActive = true
                factFields[option.key] = field
                fields.append(field)
            }
            let from = NSTextField(labelWithString: "von")
            let to = NSTextField(labelWithString: "bis")
            from.font = .systemFont(ofSize: 11)
            to.font = .systemFont(ofSize: 11)
            // „von … bis …" braucht genau zwei Felder je Gruppe; eine
            // ungerade Gruppe waere ein Fehler in FactFilterOption.all.
            precondition(fields.count == 2,
                         "Gruppe \(group.name) hat \(fields.count) Felder statt zwei")
            let row = NSStackView(views: [label, from, fields[0], to, fields[1]])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            if let key = options.first?.key.split(separator: "-").first.map(String.init), ["modified", "created"].contains(key) {
                let button = NSButton(title: "", target: self, action: #selector(editDateRange(_:)))
                button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Kalender")
                button.imagePosition = .imageOnly
                button.toolTip = "Kalender, Uhrzeit oder relativen Zeitraum für \(group.name) wählen. Die tatsächlich verwendeten Grenzen stehen im Suchbericht."
                button.setAccessibilityLabel("Datumsbereich für " + group.name)
                button.identifier = NSUserInterfaceItemIdentifier("date-range-edit-" + key)
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                row.addArrangedSubview(button)
            }
            factColumn.addArrangedSubview(row)
        }
        let hint = NSTextField(labelWithString: "Grenzen inklusive · Zeitpunkte mit Z oder Offset · leer = keine Grenze")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        factColumn.addArrangedSubview(hint)
        let encodingLabel = NSTextField(labelWithString: "Textkodierung")
        encodingLabel.font = .systemFont(ofSize: 11)
        encodingPopup.font = .systemFont(ofSize: 11)
        encodingPopup.controlSize = .small
        encodingPopup.setAccessibilityLabel("Textkodierung für Inhaltsbedingungen")
        encodingPopup.toolTip = "Gilt für Inhalt und Inhaltsbedingungen. Automatik erkennt nur UTF-8-/UTF-16-BOM, sonst UTF-8; ohne BOM die Byteordnung ausdrücklich wählen. Keine Erkennung älterer Kodierungen."
        for encoding in SearchTextEncoding.allCases {
            encodingPopup.addItem(withTitle: encoding.title)
            encodingPopup.lastItem?.representedObject = encoding.rawValue
        }
        encodingPopup.target = self
        encodingPopup.action = #selector(encodingChanged)
        let encodingRow = NSStackView(views: [encodingLabel, encodingPopup])
        encodingRow.orientation = .horizontal
        encodingRow.alignment = .centerY
        encodingRow.spacing = 6
        factColumn.addArrangedSubview(encodingRow)
        finderMetadataCheckbox.font = .systemFont(ofSize: 11)
        finderMetadataCheckbox.target = self
        finderMetadataCheckbox.action = #selector(encodingChanged)
        finderMetadataCheckbox.setAccessibilityIdentifier("finder-metadata-capture")
        finderMetadataCheckbox.toolTip = "Tags und Kommentar für passende Dateien und Ordner beim nächsten Suchlauf erfassen. Vorschau, Spalten und Ansichtsfilter verwenden danach diesen Suchstand ohne erneutes Lesen."
        factColumn.addArrangedSubview(finderMetadataCheckbox)
        localOnlyCheckbox.font = .systemFont(ofSize: 11)
        localOnlyCheckbox.target = self
        localOnlyCheckbox.action = #selector(encodingChanged)
        localOnlyCheckbox.setAccessibilityIdentifier("local-only-content")
        localOnlyCheckbox.toolTip = "Namen und bekannte Eigenschaften bleiben suchbar. Noch nicht lokal lesbare Inhalte und nicht belegbare Providerzustände werden ausgelassen. Ausdrückliches Öffnen darf herunterladen. Einzelheiten und Grenzen stehen im Suchbericht und in der Hilfe."
        factColumn.addArrangedSubview(localOnlyCheckbox)
        ocrCheckbox.font = .systemFont(ofSize: 11)
        ocrCheckbox.target = self
        ocrCheckbox.action = #selector(encodingChanged)
        ocrCheckbox.setAccessibilityIdentifier("image-ocr")
        ocrCheckbox.toolTip = "Im Suchziel Dokumenttext zusätzlich Bildtext lokal erkennen. Deutsch/Englisch, einzelne Bildframes, begrenzte Pixel/Zeit/Textmenge. Erkannter Text kann vom Original abweichen; eine fehlende Erkennung beweist keine Abwesenheit. In Name, Inhalt und Metadaten ohne Wirkung."
        factColumn.addArrangedSubview(ocrCheckbox)
        pdfOCRCheckbox.font = .systemFont(ofSize: 11)
        pdfOCRCheckbox.target = self
        pdfOCRCheckbox.action = #selector(encodingChanged)
        pdfOCRCheckbox.setAccessibilityIdentifier("pdf-ocr")
        pdfOCRCheckbox.toolTip = "Nur im Dokumenttext: vorhandene Textebenen bevorzugen, textlose Seiten begrenzt rendern und lokal erkennen. Erkannter Text und Seitenbereiche sind ungefähr. Fortschritt und Grenzen stehen im Suchbericht."
        factColumn.addArrangedSubview(pdfOCRCheckbox)
        // Darunter die weiteren Suchbegriffe: UND zum Suchfeld, einer je
        // Zeile. Unter der linken Spalte statt als dritte Spalte, damit die
        // Ansicht nicht breiter wird — die Schnellsuche hat eine feste Breite.
        let termsLabel = NSTextField(labelWithString: "Weitere Begriffe · alle müssen vorkommen · einer je Zeile")
        termsLabel.font = .systemFont(ofSize: 11)
        termsLabel.textColor = .secondaryLabelColor
        factColumn.addArrangedSubview(termsLabel)
        termsEditor.isRichText = false
        termsEditor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        termsEditor.isAutomaticQuoteSubstitutionEnabled = false
        termsEditor.isAutomaticDashSubstitutionEnabled = false
        termsEditor.isAutomaticTextReplacementEnabled = false
        termsEditor.isVerticallyResizable = true
        termsEditor.isHorizontallyResizable = false
        termsEditor.autoresizingMask = [.width]
        termsEditor.textContainer?.widthTracksTextView = true
        termsEditor.delegate = self
        termsEditor.placeholder = "z. B. Rechnung\n2026"
        termsEditor.toolTip = "Jeder Begriff muss zusätzlich zum Suchfeld zutreffen — im Namen, im Inhalt (auch auf verschiedenen Zeilen) oder in den Metadaten. Gleiche Regeln wie das Suchfeld: Platzhalter, Regex, Groß/klein, Genau."
        termsEditor.setAccessibilityLabel("Weitere Suchbegriffe, einer je Zeile")
        let termsScroll = NSScrollView()
        termsScroll.borderType = .bezelBorder
        termsScroll.hasVerticalScroller = true
        termsScroll.documentView = termsEditor
        factColumn.addArrangedSubview(termsScroll)
        termsScroll.heightAnchor.constraint(equalToConstant: 40).isActive = true
        termsScroll.widthAnchor.constraint(equalTo: factColumn.widthAnchor).isActive = true
        factColumn.setContentHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(factColumn)

        // Rechte Spalte: Überschrift mit ?-Knopf, darunter das Ausschlussfeld.
        let exclusionColumn = NSStackView()
        exclusionColumn.orientation = .vertical
        exclusionColumn.alignment = .leading
        exclusionColumn.spacing = 4
        let label = NSTextField(labelWithString: "Ausschließen · ein Muster je Zeile")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        helpButton.bezelStyle = .helpButton
        helpButton.title = ""
        helpButton.controlSize = .small
        helpButton.target = self
        helpButton.action = #selector(showHelp(_:))
        helpButton.toolTip = "Erklärt die Ausschlussmuster"
        helpButton.setAccessibilityLabel("Hilfe zu Ausschlussmustern")
        let header = NSStackView(views: [label, helpButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        exclusionColumn.addArrangedSubview(header)
        exclusionsEditor.isRichText = false
        exclusionsEditor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        exclusionsEditor.isAutomaticQuoteSubstitutionEnabled = false
        exclusionsEditor.isAutomaticDashSubstitutionEnabled = false
        exclusionsEditor.isAutomaticTextReplacementEnabled = false
        exclusionsEditor.isVerticallyResizable = true
        exclusionsEditor.isHorizontallyResizable = false
        exclusionsEditor.autoresizingMask = [.width]
        exclusionsEditor.textContainer?.widthTracksTextView = true
        exclusionsEditor.delegate = self
        exclusionsEditor.placeholder = "z. B. node_modules\n*.log\nCache/*.zip"
        exclusionsEditor.toolTip = "Zum Beispiel node_modules oder Cache/*.zip. Groß-/Kleinschreibung gilt immer. Ohne / gilt das Muster für jede Pfadkomponente; mit / für den relativen Pfad ab Such- oder Archivwurzel."
        exclusionsEditor.setAccessibilityLabel("Ausschlussmuster, ein Muster je Zeile")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = exclusionsEditor
        exclusionColumn.addArrangedSubview(scroll)
        // Vier Zeilen hoch — so hoch wie die drei Von/Bis-Zeilen samt
        // Hinweis links — und so breit wie der Platz rechts davon.
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
        scroll.widthAnchor.constraint(equalTo: exclusionColumn.widthAnchor).isActive = true
        // Mindestens 160 pt (Schnellsuche), höchstens 460 pt: Ein Muster ist
        // selten länger als 30 Zeichen, mehr Breite wäre nur leerer Rahmen.
        exclusionColumn.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        exclusionColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true
        addArrangedSubview(exclusionColumn)
        // Die rechte Spalte wächst bis zur Deckelung, der Stack (Distribution
        // `gravityAreas`) lässt den Rest rechts frei — die Spalte bleibt so
        // direkt neben den Von/Bis-Feldern statt am rechten Fensterrand.
        let fill = exclusionColumn.widthAnchor.constraint(equalToConstant: 460)
        fill.priority = .defaultLow
        fill.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }
    func textDidChange(_ notification: Notification) { onChange?() }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    private func refreshDateRanges() {
        for key in ["modified", "created"] {
            for suffix in ["from", "to"] {
                guard let field = factFields[key + "-" + suffix] else { continue }
                field.isEnabled = dateRanges[key] == nil
                if let spec = dateRanges[key] {
                    field.stringValue = suffix == "from" ? spec.title : spec.timeZone
                    field.toolTip = "\(spec.title) · \(spec.timeZone). Verwendete ISO-Grenzen: Suchbericht. Kalenderknopf → Rohe ISO-Eingabe stellt die Textfelder wieder her."
                }
            }
        }
    }
    @objc private func editDateRange(_ sender: NSButton) {
        guard let window, window.attachedSheet == nil, dateEditor == nil,
              let identifier = sender.identifier?.rawValue else { return }
        let key = String(identifier.dropFirst("date-range-edit-".count))
        guard ["modified", "created"].contains(key) else { return }
        var spec = dateRanges[key]
        if spec == nil, let lower = rawFacts[key + "-from"], let upper = rawFacts[key + "-to"] {
            spec = DateRangeSpec(kind: "fixed", timeZone: TimeZone.current.identifier, lower: lower, upper: upper)
        }
        let editor = DateRangeEditor(spec: spec, title: key == "modified" ? "Geändert im Zeitraum" : "Erstellt im Zeitraum")
        dateEditor = editor
        editor.present(on: window) { [weak self] result in
            guard let self else { return }; self.dateEditor = nil
            guard let result else { return }
            self.factFields[key + "-from"]?.stringValue = ""; self.factFields[key + "-to"]?.stringValue = ""
            self.dateRanges[key] = result.0
            self.onChange?()
        }
    }
    func stopDateEditorForTermination() { dateEditor?.stopForTermination() }

    /// Zeigt die Erklärung als Popover am ?-Knopf; ein zweiter Klick schließt.
    @objc func showHelp(_ sender: Any?) {
        if let open = helpPopover, open.isShown {
            open.close()
            return
        }
        // Feste Breite, Höhe aus dem Umbruch: Ein umbrechendes Label hat
        // keine eigene Breite, ohne die Vorgabe wurde das Popover ein
        // schmaler Balken ohne lesbaren Text.
        let width: CGFloat = 360
        let text = NSTextField(wrappingLabelWithString: exclusionHelpText)
        text.font = .systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = width
        let height = text.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
        text.frame = NSRect(x: 14, y: 12, width: width, height: height)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width + 28, height: height + 24))
        controller.view.addSubview(text)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: helpButton.bounds, of: helpButton, preferredEdge: .maxY)
        helpPopover = popover
    }
}

/// Der Aufklapp-Schalter „Weitere Filter" BEIDER Apps: Dreieck plus
/// klickbarer Titel, beide schalten um. Bis 0.34.22 stand derselbe Aufbau
/// samt Umschalten, Zählen und Titel wörtlich in beiden Controllern; nur
/// Grundtitel, `UserDefaults`-Schlüssel und die mitversteckte Maßzeile
/// unterscheiden sich, und die kommen als Parameter. Wo der Schalter in der
/// Zeile steht und welche Abstände er hat, bleibt Sache der App.
final class FilterDisclosure: NSObject {
    let disclosureButton = NSButton()
    let titleButton = NSButton()
    /// Je App ein eigener Schlüssel; der Zustand überlebt den Neustart.
    let defaultsKey: String
    let baseTitle: String
    let filterView: SearchFilterView
    let pixelFields: [NSTextField]
    /// Weitere Ansichten hinter dem Schalter (die Maßzeile). Sie entstehen
    /// erst beim Fensterbau und werden deshalb nachträglich gesetzt.
    var extraViews: [NSView] = []

    init(defaultsKey: String, baseTitle: String,
         filterView: SearchFilterView, pixelFields: [NSTextField]) {
        self.defaultsKey = defaultsKey
        self.baseTitle = baseTitle
        self.filterView = filterView
        self.pixelFields = pixelFields
        super.init()
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.bezelStyle = .disclosure
        disclosureButton.title = ""
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle(_:))
        disclosureButton.setAccessibilityLabel("Weitere Filter ein- oder ausblenden")
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 11)
        titleButton.alignment = .left
        titleButton.target = self
        titleButton.action = #selector(toggle(_:))
    }

    var isExpanded: Bool { !filterView.isHidden }

    @objc func toggle(_ sender: Any?) {
        setExpanded(!isExpanded)
        UserDefaults.standard.set(isExpanded, forKey: defaultsKey)
    }

    /// Den gespeicherten Zustand anwenden. Erst NACH dem Einhängen in den
    /// Stack aufrufen: `NSStackView(views:)` hängt eine schon versteckte
    /// Ansicht sichtbar ein.
    func restoreSavedState() {
        setExpanded(UserDefaults.standard.bool(forKey: defaultsKey))
    }

    /// Blendet Filteransicht und Maßzeile ein oder aus. Der Stack entfernt
    /// eine versteckte Ansicht aus dem Layout, die Trefferliste rückt nach.
    func setExpanded(_ expanded: Bool) {
        filterView.isHidden = !expanded
        for view in extraViews { view.isHidden = !expanded }
        disclosureButton.state = expanded ? .on : .off
        refreshTitle()
    }

    /// Gesetzte Filter hinter dem Schalter: jedes Maßfeld mit Inhalt plus die
    /// Zählung der Filteransicht (Von/Bis-Felder, Ausschlussmuster, weitere
    /// Begriffe). Ein Maßfeld zählt nur, wenn `PixelLimitInput` es nicht als
    /// leer wertet — ein bloßes Leerzeichen setzt keinen Filter und meldete
    /// sonst zugeklappt „(1 aktiv)".
    var activeCount: Int {
        pixelFields.filter { PixelLimitInput($0.stringValue) != .empty }.count
            + filterView.activeFilterCount
    }

    /// Zugeklappt nennt der Titel, wie viele Filter dort gesetzt sind —
    /// sonst wirkt ein unsichtbarer Filter wie ein Suchfehler.
    func refreshTitle() {
        let count = activeCount
        var title = baseTitle
        if count > 0 && !isExpanded {
            title += count == 1 ? " (1 aktiv)" : " (\(count) aktiv)"
        }
        titleButton.title = title
    }
}

/// Gemeinsamer Selbsttest des Aufklapp-Schalters an einem frisch gebauten
/// Controller OHNE gespeicherten Zustand. Das Beiseitelegen und
/// Zurückschreiben des Entwickler-Zustands bleibt beim Aufrufer: Es muss den
/// Fensterbau umschließen, der den Zustand liest.
func filterDisclosureSelfTest(_ filters: FilterDisclosure) -> String? {
    guard !filters.isExpanded, !filters.extraViews.isEmpty,
          filters.extraViews.allSatisfy({ $0.isHidden }) else {
        return "Weitere Filter sind beim Start nicht zugeklappt"
    }
    filters.toggle(nil)
    guard filters.isExpanded, filters.extraViews.allSatisfy({ !$0.isHidden }),
          filters.disclosureButton.state == .on,
          UserDefaults.standard.bool(forKey: filters.defaultsKey) else {
        return "Aufklapp-Schalter zeigt die Filter nicht"
    }
    filters.toggle(nil)
    // Nur Return startet eine Suche aus einem Maßfeld. Mit der Voreinstellung
    // schickt ein NSTextField seine Action auch beim bloßen Fokusverlust —
    // und beim Zuklappen, weil das versteckte Feld den Fokus abgibt.
    guard filters.pixelFields.allSatisfy({
        ($0.cell as? NSTextFieldCell)?.sendsActionOnEndEditing == false }) else {
        return "Maßfelder suchen schon beim Fokusverlust"
    }
    filters.filterView.exclusions = ["node_modules"]
    filters.filterView.rawFacts = ["min-size": "1 MiB"]
    filters.pixelFields[0].stringValue = "100"
    filters.pixelFields[1].stringValue = " "   // leer laut PixelLimitInput
    filters.refreshTitle()
    guard filters.titleButton.title.contains("3 aktiv") else {
        return "Zugeklappter Schalter nennt aktive Filter nicht"
    }
    return nil
}

/// Vollständiges Ende eines Suchprozesses. `status` allein reicht nicht:
/// Foundation meldet bei einem Signal dessen Nummer, sodass etwa SIGHUP und
/// der reguläre grep-Status „keine Treffer" beide den Zahlenwert 1 tragen.
/// Sammelt, was der Kern nach stderr schreibt — nebenläufig und gedeckelt.
///
/// Nebenläufig ist Pflicht: Eine zweite Pipe, die niemand leert, läuft nach
/// rund 64 KiB voll und hält den Kern an. Er wartete dann auf Platz in
/// stderr, die App auf seine Treffer in stdout — beide Seiten stünden.
/// Deshalb hängt der Sammler an einem eigenen `readabilityHandler`.
///
/// Gedeckelt, weil eine Suche über einen unlesbaren Baum beliebig viele
/// Warnungen erzeugen kann. Gebraucht wird ohnehin nur der Anfang: die
/// erste Fehlerzeile und die Zahl der Warnungen.
func plainModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
    event.modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.capsLock, .numericPad, .function])
}

/// Apps, die einen Treffer öffnen können — für das „Öffnen mit"-Menü.
/// Bei normalen Dateien direkt über die URL, bei Archiv-Einträgen über den
/// Dateityp (Endung), damit fürs bloße Menü noch nichts ausgepackt wird.
/// Nach Namen sortiert, Doppelte entfernt.
#if FAVENIO_TEST_SUITE
// Beide Vergleichsalgorithmen müssen denselben LaunchServices-Stand sehen,
// auch wenn während der Tests andere Apps gebaut oder registriert werden.
var applicationsLookupForTesting: ((Hit) -> [URL])?
#endif

func applicationsFor(_ hit: Hit) -> [URL] {
#if FAVENIO_TEST_SUITE
    if let lookup = applicationsLookupForTesting { return lookup(hit) }
#endif
    var urls: [URL] = []
    if hit.isMember {
        let ext = (hit.displayName as NSString).pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext.lowercased()) {
            urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
    } else {
        // Der Dateipfad, nicht der Anzeigepfad: `path` trägt die
        // `!/`-Semantik und ist für einen Nicht-Eintrag heute zwar
        // derselbe Text, aber `filesystemPath` ist das Feld, das die Datei
        // benennt.
        urls = NSWorkspace.shared.urlsForApplications(
            toOpen: URL(fileURLWithPath: hit.filesystemPath))
    }
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

// ---------- Festplattenvollzugriff (Full Disk Access) ----------

/// Grobe, prompt-freie Prüfung, ob die App Festplattenvollzugriff hat: die
/// TCC-Datenbank im Benutzerordner ist nur MIT Vollzugriff lesbar. Fehlt der
/// Zugriff, liefert das Öffnen nil (EPERM) — ganz ohne Systemdialog, denn
/// Vollzugriff lässt sich nicht per Prompt erfragen.
func hasFullDiskAccess() -> Bool {
    let probe = NSHomeDirectory()
        + "/Library/Application Support/com.apple.TCC/TCC.db"
    guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
    handle.closeFile()
    return true
}

/// Zeigt beim Start einen einmaligen Anleitungs-Dialog, wenn (noch) kein
/// Vollzugriff besteht — außer der Nutzer hat „nicht mehr fragen" gewählt.
/// Der Suppress-Schalter liegt in den per-App-UserDefaults, gilt also je App
/// getrennt (beide Bundles brauchen den Zugriff separat).
func maybePromptFullDiskAccess(appName: String) {
    let suppressKey = "FavenioSuppressFullDiskAccessPrompt"
    if UserDefaults.standard.bool(forKey: suppressKey) { return }
    if hasFullDiskAccess() { return }

    let alert = NSAlert()
    alert.messageText = "Festplattenvollzugriff empfohlen"
    alert.informativeText = """
        \(appName) durchsucht Dateien mit dem Bordmittel-Suchmotor. OHNE \
        „Festplattenvollzugriff" fragt macOS beim Durchsuchen geschützter \
        Ordner (Musik, Fotos, Mail …) ständig einzeln um Erlaubnis — und die \
        Schnellsuche kann dabei sogar verschwinden.

        Mit einmal erteiltem Vollzugriff läuft die Suche ruhig und \
        vollständig durch. Die App funktioniert auch ohne, ist damit aber \
        deutlich besser.

        So geht's: Systemeinstellungen → Datenschutz & Sicherheit → \
        Festplattenvollzugriff → \(appName) aktivieren (nötigenfalls per „+" \
        hinzufügen), danach die App neu starten.
        """
    alert.addButton(withTitle: "Systemeinstellungen öffnen")
    alert.addButton(withTitle: "Später")
    alert.addButton(withTitle: "Nicht freigeben, nicht mehr fragen")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        if let url = URL(string: "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    case .alertThirdButtonReturn:
        UserDefaults.standard.set(true, forKey: suppressKey)
    default:
        break   // „Später" → beim nächsten Start erneut fragen
    }
}

/// Ergebnis der Finder-Abfrage. Eine leere Ordnerliste ist NICHT aussagekräftig
/// genug: „kein Fenster offen" und „Automation verboten" führen beide zu null
/// Ordnern, verlangen aber völlig verschiedene Reaktionen. Deshalb trägt jeder
/// Fehlschlag hier seinen Grund mit; die Frontends dürfen ihn nicht verschlucken
/// und stillschweigend im Benutzerordner suchen.
enum FinderScopeOutcome {
    case folders([String])   // mindestens ein Finder-Ordner, vorderster zuerst
    case noWindow            // Finder erreichbar, aber kein Ordnerfenster offen
    case denied              // Automations-Zugriff auf den Finder verweigert
    case failed(String)      // Zeitüberschreitung oder anderer Fehler
}

extension FinderScopeOutcome {
    /// Die ermittelten Ordner (bei jedem Fehlschlag leer).
    var folders: [String] {
        if case .folders(let folders) = self { return folders }
        return []
    }

    /// Kurztext für die Oberfläche; `nil`, wenn alles geklappt hat.
    /// Bewusst inklusive der Folge („Suchbereich bleibt …"), damit der Nutzer
    /// nicht selbst raten muss, wo gerade gesucht wird.
    var problemText: String? {
        switch self {
        case .folders:
            return nil
        case .noWindow:
            return "Kein Finder-Fenster offen — Suchbereich manuell wählen."
        case .denied:
            return "Finder-Zugriff nicht erlaubt — Suchbereich manuell wählen "
                 + "(Systemeinstellungen → Datenschutz & Sicherheit → "
                 + "Automation)."
        case .failed(let reason):
            return "Finder-Ordner nicht ermittelbar (\(reason)) — Suchbereich "
                 + "manuell wählen."
        }
    }

    /// Maschinenlesbares Kürzel für die Diagnose auf der Kommandozeile.
    var statusName: String {
        switch self {
        case .folders:  return "folders"
        case .noWindow: return "no-window"
        case .denied:   return "denied"
        case .failed:   return "failed"
        }
    }
}

/// Öffnet die Automations-Freigabe in den Systemeinstellungen.
func openAutomationSettings() {
    if let url = URL(string: "x-apple.systempreferences:"
        + "com.apple.preference.security?Privacy_Automation") {
        NSWorkspace.shared.open(url)
    }
}

// Rückgabewerte von `AEDeterminePermissionToAutomateTarget`. Die Konstanten
// stehen in Apples Carbon-Headern; hier ausgeschrieben, damit der Code ohne
// zusätzliche Importe lesbar bleibt.
private let kAEEventNotPermitted: OSStatus = -1743          // ausdrücklich verboten
private let kAEEventWouldRequireUserConsent: OSStatus = -1744  // noch nicht gefragt

/// Fragt TCC OHNE Apple-Event und OHNE Dialog, ob wir den Finder steuern dürfen.
///
/// Das ist der einzige Weg, „verboten" sofort zu erkennen, statt es aus einem
/// hängenden Unterprozess zu erschließen: Apple-Events an einen verbotenen
/// Empfänger können beliebig lange stehen bleiben, und ein Timeout ist dann nur
/// geraten. `askUserIfNeeded: false` verhindert, dass dieser Aufruf selbst einen
/// Dialog auslöst — der Consent-Dialog gehört an die echte Abfrage.
/// Ergebnis: `noErr` = erlaubt, -1743 = verboten, -1744 = noch nicht gefragt.
func finderAutomationPermission() -> OSStatus {
    guard let target = NSAppleEventDescriptor(
        bundleIdentifier: "com.apple.finder").aeDesc else { return noErr }
    return AEDeterminePermissionToAutomateTarget(
        target, typeWildCard, typeWildCard, false)
}

/// Wartet macOS gerade auf die Entscheidung des Nutzers? Dann darf die
/// Oberfläche nicht „Finder antwortet nicht" behaupten.
func finderAutomationConsentPending() -> Bool {
    finderAutomationPermission() == kAEEventWouldRequireUserConsent
}

/// Ermittelt die offenen Finder-Fenster (Ordner des vorderen Tabs),
/// VORDERSTES zuerst — ASYNCHRON und ohne den Main-Thread zu blockieren.
/// `completion` läuft auf dem Main-Thread und bekommt bei Fehlschlag den
/// Grund mitgeliefert (siehe `FinderScopeOutcome`).
///
/// WARUM per `osascript`-UNTERPROZESS (statt NSAppleScript im eigenen Prozess):
/// Den Finder abzufragen ist ein Apple-Event, dessen Antwort der Apple-Event-
/// Manager an den MAIN-Thread des Prozesses zustellt. In einer laufenden
/// `NSApplication` (unsere Accessory-App) blockiert ein synchroner
/// `NSAppleScript.executeAndReturnError` dann ewig — egal ob auf einem
/// Hintergrund-Thread (die Antwort landet nie bei ihm) oder auf dem Main-Thread
/// (er wartet auf eine Antwort, die nur er selbst zustellen könnte → Deadlock).
/// Beide In-Prozess-Wege wurden im echten App-Kontext als Hänger verifiziert
/// (2026-07-13). Ein separater `osascript`-Prozess hat seinen eigenen
/// Event-Loop und kehrt sauber zurück — genau wie das nc_pin-AppleScript-Applet.
/// TCC ordnet den Apple-Event dabei korrekt UNSERER App als verantwortlichem
/// Prozess zu (Favenios `NSAppleEventsUsageDescription` → korrekter Prompt);
/// die entgegengesetzte Handoff-Notiz („osascript scheidet aus") war falsch.
/// (Finder-Tabs sind per AppleScript nicht einzeln adressierbar — pro Fenster
/// kommt der Ordner des vorderen Tabs.)
func finderWindowFoldersAsync(
    completion: @escaping (FinderScopeOutcome) -> Void
) {
    // Hintergrund-Thread nur, damit das Starten/Warten des Unterprozesses den
    // Main-Thread nicht anfasst; die eigentliche Apple-Event-Arbeit macht
    // osascript in seinem eigenen Prozess.
    DispatchQueue.global(qos: .userInitiated).async {
        // Zuerst TCC fragen, ohne Event und ohne Dialog. Ist die Automation
        // verboten, ist das SOFORT klar — kein Unterprozess, kein Warten, kein
        // geratener Timeout.
        let permission = finderAutomationPermission()
        if permission == kAEEventNotPermitted {
            DispatchQueue.main.async { completion(.denied) }
            return
        }
        // Steht die Entscheidung noch aus, zeigt macOS gleich einen Dialog. Bis
        // der Nutzer geklickt hat, darf nichts abgebrochen werden; sonst würde
        // die App genau die Freigabe wegwerfen, auf die sie wartet.
        let consentPending = permission == kAEEventWouldRequireUserConsent

        // VORDERSTES Fenster über `front Finder window` — die Klasse
        // `Finder window` schließt Info- und andere Hilfsfenster aus, `front
        // window` würde an einem geöffneten Info-Fenster scheitern. Die übrigen
        // Fenster kommen in EINEM Zug; `Finder windows` ist nicht zuverlässig
        // front-to-back sortiert, deshalb steht das vorderste separat vorn.
        //
        // Gemessen am 2026-07-25 (13 offene Finder-Fenster, Median aus 7 Läufen):
        //   Schleife über die Fenster (je ein Apple-Event)   11 600 ms
        //   frühere Fassung, `as alias` + `POSIX path of`       185 ms
        //   diese Fassung, `URL of`                             147 ms
        //   davon reiner osascript-Prozessstart                  34 ms
        // Die Fensterliste kostet gegenüber der Einzelabfrage nur ~2 ms: Es
        // lohnt NICHT, sie wegzulassen — teuer ist der erste Apple-Event, nicht
        // die Menge. `as alias` kostet dagegen echte Zeit, weil es je Eintrag
        // zusätzliche Auflösungen auslöst. Diese Abfrage deshalb weder auf eine
        // Fenster-Schleife noch auf `as alias` zurückbauen.
        //
        // `text item delimiters` ist eine AppleScript-Eigenschaft und muss
        // AUSSERHALB des `tell application "Finder"`-Blocks gesetzt werden —
        // sonst versucht AppleScript, sie am Finder zu setzen (Fehler -10006).
        let source = """
        set frontURL to ""
        set allURLs to {}
        tell application "Finder"
            with timeout of 4 seconds
                try
                    set frontURL to URL of (target of front Finder window)
                end try
                try
                    set allURLs to URL of (target of every Finder window)
                end try
            end timeout
        end tell
        if class of allURLs is not list then set allURLs to {allURLs}
        set out to {}
        if frontURL is not "" then set end of out to frontURL
        repeat with u in allURLs
            set p to u as text
            if p is not "" and out does not contain p then set end of out to p
        end repeat
        set text item delimiters to linefeed
        return out as text
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        // stderr wird gelesen, NICHT verworfen: Nur dort steht, ob TCC den
        // Apple-Event verboten hat (-1743/-1744) oder der Finder nicht
        // antwortet (-1712). Ohne diesen Text bliebe jeder Fehlschlag stumm.
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outcome: FinderScopeOutcome
        do {
            try process.run()
            // Not-Aus, falls osascript trotz AppleScript-Timeout klemmt. 6 s
            // sind gegenüber gemessenen 147 ms reichlich; wartet dagegen ein
            // Consent-Dialog auf den Nutzer, wird nicht abgebrochen. Der
            // Abbruch wird gemeldet, nicht zu „keine Ordner" verschwiegen.
            let killed = Atomic(false)
            let killer: DispatchWorkItem?
            if !consentPending {
                let work = DispatchWorkItem {
                    if process.isRunning {
                        killed.set(true)
                        process.terminate()
                    }
                }
                killer = work
                DispatchQueue.global().asyncAfter(deadline: .now() + 6,
                                                  execute: work)
            } else {
                // Ein offener Systemdialog hat bewusst KEIN Zeitlimit. Nur
                // der Nutzer darf diese TCC-Entscheidung beenden; ein Notaus
                // würde die wartende Freigabe verwerfen.
                killer = nil
            }
            // Beide Pipes gleichzeitig leeren: Läuft stderr voll, während wir
            // nur stdout lesen, blockiert der Unterprozess.
            let group = DispatchGroup()
            let out = Atomic(Data())
            let err = Atomic(Data())
            DispatchQueue.global().async(group: group) {
                out.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global().async(group: group) {
                err.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            }
            group.wait()
            process.waitUntilExit()
            killer?.cancel()

            let text = String(data: out.get(), encoding: .utf8) ?? ""
            let errorText = (String(data: err.get(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var folders: [String] = []
            for line in text.split(separator: "\n",
                                   omittingEmptySubsequences: true)
                            .map(String.init) {
                // Der Finder liefert `file://`-URLs; Sonderzeichen sind darin
                // prozentkodiert und werden erst von URL richtig aufgelöst.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                var path = URL(string: trimmed)?.path ?? trimmed
                // Ordner-URLs enden auf „/"; Pfade im Rest der App nicht.
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if !path.isEmpty && !folders.contains(path) {
                    folders.append(path)
                }
            }

            if killed.get() {
                outcome = .failed("Finder antwortet nicht")
            } else if process.terminationStatus == 0 {
                outcome = folders.isEmpty ? .noWindow : .folders(folders)
            } else if errorText.contains("-1743")
                        || errorText.contains("-1744")
                        || errorText.localizedCaseInsensitiveContains(
                            "not authorized") {
                outcome = .denied
            } else if errorText.contains("-1712") {
                outcome = .failed("Zeitüberschreitung beim Finder")
            } else {
                outcome = .failed(firstLine(of: errorText)
                                  ?? "osascript-Fehler "
                                     + "\(process.terminationStatus)")
            }
        } catch {
            outcome = .failed("osascript nicht startbar")
        }
        let result = outcome
        DispatchQueue.main.async { completion(result) }
    }
}

/// Headless-Diagnose (`--finder-scope`): fragt den Finder genau so wie die App
/// und schreibt eine JSON-Zeile nach stdout. Weil die Abfrage aus DEM Bundle
/// läuft, das auch TCC bewertet, zeigt sie den echten Zugriffsstatus — anders
/// als dasselbe AppleScript aus dem Terminal.
/// Exit-Codes wie im Kern: 0 = Ordner ermittelt, 1 = kein Fenster, 2 = Fehler
/// (auch verweigerter Zugriff).
func runFinderScopeDiagnostic() -> Never {
    // Der Freigabestatus steht getrennt im Ergebnis: Er beantwortet ohne
    // Rateverfahren, ob ein leeres Ergebnis an TCC oder am Finder liegt.
    let permission = finderAutomationPermission()
    let permissionName: String
    switch permission {
    case noErr:                          permissionName = "granted"
    case kAEEventNotPermitted:           permissionName = "denied"
    case kAEEventWouldRequireUserConsent: permissionName = "pending"
    default:                             permissionName = "error \(permission)"
    }
    finderWindowFoldersAsync { outcome in
        var payload: [String: Any] = [
            "status": outcome.statusName,
            "permission": permissionName,
            "folders": outcome.folders,
        ]
        if let problem = outcome.problemText { payload["problem"] = problem }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        switch outcome {
        case .folders:  exit(0)
        case .noWindow: exit(1)
        default:        exit(2)
        }
    }
    // Die Antwort kommt über die Main-Queue; ohne laufenden Runloop käme sie nie.
    RunLoop.main.run()
    exit(2)   // wird nie erreicht
}

/// Erste nicht-leere Zeile eines Fehlertexts (osascript hängt gern mehrere an).
private func firstLine(of text: String) -> String? {
    text.split(separator: "\n").map(String.init).first {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Winziger Thread-sicherer Behälter — die beiden Pipe-Leser laufen auf eigenen
/// Queues und geben ihr Ergebnis hier ab.
private final class Atomic<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}

/// Die wichtigsten Ordner als (Anzeigename, Pfad) — für das Ordner-Popup der
/// großen GUI und das Bereichs-Menü der Schnellsuche.
func commonFolders() -> [(title: String, path: String)] {
    let home = NSHomeDirectory()
    return [
        ("Benutzerordner (~)", home),
        ("Schreibtisch", home + "/Desktop"),
        ("Dokumente", home + "/Documents"),
        ("Downloads", home + "/Downloads"),
        ("Programme", "/Applications"),
    ]
}

/// Kürzt den Benutzerordner-Anteil eines Pfads zu "~" (für Tooltips/Anzeige).


/// Baut das minimale Menü (Beenden + Bearbeiten), damit Cmd+Q/C/V/X/A
/// in beiden Apps funktionieren — programmatische Apps haben sonst
/// KEINE Tastaturkürzel.
/// `includeClose` = zusätzlich „Fenster schließen" (Cmd+W); nur die
/// Schnellsuche braucht das (dort beendet das Schließen die App), damit
/// nicht die große GUI ungewollt ihr Verhalten ändert.
// MARK: - Kennzahlen der Trefferliste

/// Was die Fußzeile über die Trefferliste sagt. Die Werte werden beim
/// Anhängen fortgeschrieben, damit ein Streaming-Lauf nicht bei jedem
/// Nachschub die ganze Liste erneut aufsummieren muss.
struct HitStatistics {
    /// Anzahl der Treffer.
    private(set) var count = 0
    /// Summe der bekannten Dateigrößen in Bytes.
    private(set) var totalSize = 0
    /// Die Ordner, in denen die Treffer liegen.
    private(set) var folders = Set<String>()
    /// Mindestens eine DATEI, deren Größe der Kern nicht mitliefert (etwa ein
    /// bsdtar-Eintrag, dessen entpackte Größe erst beim Auspacken feststeht),
    /// oder die Summe hat `Int.max` überschritten und ist gesättigt.
    /// `totalSize` ist dann eine Untergrenze und wird als „≥" gekennzeichnet.
    private(set) var sizeIsPartial = false

    mutating func add(_ hit: Hit) {
        count += 1
        folders.insert(HitStatistics.folder(of: hit))
        if let size = hit.size {
            // Die Größen kommen aus fremden Archivköpfen, ungeprüft: Eine
            // Namenssuche gibt die deklarierte Größe eines Zip-Eintrags aus,
            // ohne ihn zu öffnen. Mehrere einzeln darstellbare Werte können
            // zusammen Int.max überschreiten — mit fangender Addition
            // beendete Swift dann die App beim Fortschreiben der Fußzeile
            // (Review-Fund 2026-09-02). Die Summe sättigt stattdessen und
            // wird als Untergrenze gekennzeichnet.
            let (sum, overflow) = totalSize.addingReportingOverflow(size)
            if overflow {
                totalSize = Int.max
                sizeIsPartial = true
            } else {
                totalSize = sum
            }
        } else if !hit.isDirectory {
            // Ordner haben von Natur aus keine Größe — das macht die Summe
            // nicht unvollständig. Eine DATEI ohne Größe dagegen schon.
            sizeIsPartial = true
        }
    }

    /// Der Ordner, in dem ein Treffer liegt: immer der Elternordner seines
    /// Dateisystempfads. Ein Ordner-Treffer zählt damit für den Ordner, in dem
    /// er steckt, und ein Archiv-Eintrag für den Ordner seines Archivs — im
    /// Dateisystem liegt er nirgendwo anders.
    static func folder(of hit: Hit) -> String {
        (hit.filesystemPath as NSString).deletingLastPathComponent
    }

    static func over(_ hits: [Hit]) -> HitStatistics {
        var statistics = HitStatistics()
        for hit in hits { statistics.add(hit) }
        return statistics
    }
}

/// Zahl mit Tausendertrennung in der Sprache des Nutzers („12.345").
func groupedNumber(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

/// Dateigröße menschenlesbar (z. B. „1,2 MB"); ohne bekannte Größe „—".
func humanSize(_ bytes: Int?) -> String {
    guard let bytes else { return "—" }
    return ByteCountFormatter.string(fromByteCount: Int64(bytes),
                                     countStyle: .file)
}

// MARK: - Datumsspalten

/// Die vier Schreibweisen der Datumsspalten, von der kürzesten zur
/// ausführlichsten — dieselbe Staffel wie in Doppeldecker. Welche Stufe
/// eine Spalte zeigt, entscheidet ihre Breite (`dateColumnStage`), nicht
/// eine feste Wahl: Zieht man die Spalte auf, wird das Datum ausführlicher,
/// zieht man sie zu, bleibt es lesbar statt abgeschnitten.
///
/// Stufe 1 `04.09.26`, Stufe 2 `04.09.26, 14:03`,
/// Stufe 3 `04.09.2026, 14:03`, Stufe 4 `4. September 2026 um 14:03`.
let dateColumnStages = 4

/// Breitestes Muster je Stufe: Ziffern laufen in Tabellenziffern
/// (`monospacedDigitSystemFont`), jede „8" ist also so breit wie jede andere
/// Ziffer; „September" ist der längste deutsche Monatsname.
let dateColumnSamples = [
    "88.88.88",
    "88.88.88, 88:88",
    "88.88.8888, 88:88",
    "88. September 8888 um 88:88",
]

private let germanMonthNames = [
    "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
    "September", "Oktober", "November", "Dezember",
]

/// Ein Zeitstempel in der gewünschten Stufe (1…4, außerhalb gedeckelt);
/// ohne Wert leer. Lokale Zeitzone und gregorianischer Kalender — die
/// Spalte soll dasselbe zeigen wie der Finder daneben.
func formatDateColumn(_ seconds: Double?, stage: Int,
                      calendar: Calendar = dateColumnCalendar) -> String {
    guard let seconds, seconds.isFinite else { return "" }
    let date = Date(timeIntervalSince1970: seconds)
    let parts = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day,
          let hour = parts.hour, let minute = parts.minute,
          (1...12).contains(month) else { return "" }
    let time = String(format: "%02d:%02d", hour, minute)
    let shortYear = String(format: "%02d", ((year % 100) + 100) % 100)
    switch max(1, min(dateColumnStages, stage)) {
    case 1:
        return String(format: "%02d.%02d.", day, month) + shortYear
    case 2:
        return String(format: "%02d.%02d.", day, month) + shortYear
            + ", " + time
    case 3:
        return String(format: "%02d.%02d.%d, ", day, month, year) + time
    default:
        return "\(day). \(germanMonthNames[month - 1]) \(year) um \(time)"
    }
}

/// Gregorianisch in der Zeitzone des Rechners, unabhängig von einem
/// exotischen Nutzerkalender: Die Spalte zeigt Kalenderdaten, wie sie auf
/// der Datei stehen.
let dateColumnCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar
}()

/// Die ausführlichste Stufe, deren breitestes Muster in `width` Punkte
/// passt. Passt nicht einmal die kürzeste, bleibt es bei Stufe 1 — gekürzt
/// wird nur im Extremfall, erfunden nie. Die Musterbreiten werden je Schrift
/// einmal gemessen; die Frage kommt bei jedem Zeichnen einer Zelle.
func dateColumnStage(forWidth width: CGFloat, font: NSFont) -> Int {
    var stage = 1
    for (index, sampleWidth) in dateColumnSampleWidths(font: font).enumerated()
    where width >= sampleWidth {
        stage = index + 1
    }
    return stage
}

private var measuredDateSampleWidths: [String: [CGFloat]] = [:]

/// Gemessene Breite der vier Muster in dieser Schrift, einmal je Schrift.
func dateColumnSampleWidths(font: NSFont) -> [CGFloat] {
    let key = font.fontName + "@" + String(describing: font.pointSize)
    if let cached = measuredDateSampleWidths[key] { return cached }
    let widths = dateColumnSamples.map {
        ceil(($0 as NSString).size(withAttributes: [.font: font]).width)
    }
    measuredDateSampleWidths[key] = widths
    return widths
}

/// Die Kennzahlenzeile: Treffer, Datenmenge, Anzahl Ordner — und die Auswahl
/// erst ab ZWEI markierten Zeilen. Eine einzelne markierte Zeile hat man fast
/// immer; „1 ausgewählt" wäre nur Rauschen.
func hitStatisticsText(_ statistics: HitStatistics, selected: Int) -> String {
    var parts = [
        "\(groupedNumber(statistics.count)) Treffer",
        (statistics.sizeIsPartial ? "≥ " : "")
            + humanSize(statistics.totalSize),
        "\(groupedNumber(statistics.folders.count)) Ordner",
    ]
    if selected >= 2 { parts.append("\(groupedNumber(selected)) ausgewählt") }
    return parts.joined(separator: " · ")
}

// MARK: - Menüpunkte der Trefferliste

/// Selektoren der drei Aktionen, die auf der Trefferliste arbeiten.
struct ResultListMenuSelectors {
    let exportSelection: Selector
    let removeFromList: Selector
    let moveToTrash: Selector
}

/// Baut die drei Trefferlisten-Punkte — einmal für das Ablage-Menü, einmal
/// für das Rechtsklick-Menü der Tabelle. Beide zeigen dasselbe Kürzel, damit
/// es nicht Geheimwissen bleibt.
///
/// Der Bauplan steht hier und nicht im Controller, damit der Headless-
/// Selbsttest die fertigen Menüpunkte prüfen kann statt eines Kommentars.
func populateResultListMenu(_ menu: NSMenu, target: AnyObject,
                            selectors: ResultListMenuSelectors) {
    let export = menu.addItem(withTitle: "Auswahl exportieren…",
                              action: selectors.exportSelection,
                              keyEquivalent: "e")
    export.keyEquivalentModifierMask = [.command, .shift]
    export.target = target
    let remove = menu.addItem(withTitle: "Aus Trefferliste entfernen",
                              action: selectors.removeFromList,
                              keyEquivalent: backspaceKeyEquivalent)
    // Ohne Zusatztaste: ⌫ allein. NSMenuItem setzt sonst ⌘ voraus.
    remove.keyEquivalentModifierMask = []
    remove.target = target
    let trash = menu.addItem(withTitle: "In den Papierkorb legen",
                             action: selectors.moveToTrash,
                             keyEquivalent: backspaceKeyEquivalent)
    trash.keyEquivalentModifierMask = [.command]
    trash.target = target
}

// MARK: - Treffer exportieren

/// Ausgabeformate von „Treffer exportieren".
///
/// Die Textliste mit einem POSIX-Pfad pro Zeile ist das Format, das
/// Kommandozeilenwerkzeuge erwarten (`xargs`, `while read`, `grep -f`). Weil
/// ein Dateiname unter macOS jedes Zeichen außer `/` und NUL enthalten darf —
/// auch einen Zeilenumbruch —, gibt es dieselbe Liste zusätzlich
/// NUL-getrennt; das ist die Form, die `xargs -0` und `find -print0` sprechen
/// und die als einzige jeden Namen unversehrt überträgt.
final class ExportWriter {
    private(set) var isWriting = false
    private let operation: ([Hit], HitExportFormat, URL) throws -> Void

    /// Der Standardauftrag schreibt die echte Datei. Tests können die Arbeit
    /// gezielt anhalten, um ihre Ausführung außerhalb von Main zu beweisen.
    init(operation: @escaping ([Hit], HitExportFormat, URL) throws -> Void = {
        try exportData(for: $0, format: $1).write(to: $2, options: .atomic)
    }) {
        self.operation = operation
    }

    @discardableResult
    func write(_ hits: [Hit], format: HitExportFormat, to destination: URL,
               completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        enqueue({ [self] in try operation(hits, format, destination) }, completion: completion)
    }

    @discardableResult
    func writeJSON(_ object: [String: Any], to destination: URL,
                   completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        enqueue({
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
        }, completion: completion)
    }

    private func enqueue(_ operation: @escaping () throws -> Void,
                         completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        precondition(Thread.isMainThread)
        guard !isWriting else { return false }
        isWriting = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<Void, Error> = Result { try autoreleasepool { try operation() } }
            DispatchQueue.main.async { [self] in
                isWriting = false
                completion(result)
            }
        }
        return true
    }
}

// MARK: - In den Papierkorb legen

/// Das Kürzel-Zeichen der Rückschritttaste. NSMenuItem zeichnet dafür genau
/// das Symbol ⌫ neben den Menüpunkt. Das Tastenereignis selbst fängt der
/// Tastaturmonitor der GUI über den layoutunabhängigen Tastencode ab — das
/// Kürzel im Menü zeigt es, verlässt sich aber nicht darauf.
let backspaceKeyEquivalent = String(UnicodeScalar(UInt8(NSBackspaceCharacter)))


/// Was ein Suchlauf schon in den Papierkorb gelegt hat.
///
/// Der laufende Suchprozess weiß davon nichts und streamt weiter, was er
/// unter einem verschobenen Ordner oder in einem verschobenen Archiv findet.
/// Die Liste beantwortet deshalb für jeden Treffer: Liegt hinter seinem
/// Dateisystempfad noch etwas? Eine Datei zählt genau, ein Ordner mitsamt
/// allem darunter — mit Pfadkomponenten-Grenze, damit „/a/b" nicht auch
/// „/a/bc" trifft.
struct TrashedPaths {
    private var files = Set<String>()
    private var folders: [String] = []

    var isEmpty: Bool { files.isEmpty && folders.isEmpty }

    mutating func insert(_ filesystemPath: String, isDirectory: Bool) {
        let path = TrashedPaths.withoutTrailingSlash(filesystemPath)
        files.insert(path)
        if isDirectory { folders.append(path) }
    }

    func contains(_ filesystemPath: String) -> Bool {
        let path = TrashedPaths.withoutTrailingSlash(filesystemPath)
        if files.contains(path) { return true }
        return folders.contains { path.hasPrefix($0 + "/") }
    }

    private static func withoutTrailingSlash(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast()) : path
    }
}

/// Teilt eine Auswahl in das, was in den Papierkorb kann, und das, was nicht.
///
/// Ein Eintrag INNERHALB eines Archivs hat keine eigene Datei im Dateisystem;
/// zu löschen gäbe es dort nur die ausgepackte Kopie im Temp-Ordner, und das
/// hilft niemandem. Solche Treffer werden ausgelassen und gemeldet.
///
/// Mehrere Treffer können auf dieselbe Datei zeigen (ein Archiv und ein
/// Eintrag darin, mehrere Inhaltstreffer derselben Datei). Jede Datei steht
/// deshalb genau einmal in der Liste.
func trashableHits(_ hits: [Hit]) -> (trashable: [Hit], skipped: [Hit]) {
    var trashable: [Hit] = []
    var skipped: [Hit] = []
    var seen = Set<String>()
    for hit in hits {
        if hit.isMember {
            skipped.append(hit)
        } else if seen.insert(hit.filesystemPath).inserted {
            trashable.append(hit)
        }
    }
    return (trashable, skipped)
}

/// Text des Bestätigungsdialogs vor dem Papierkorb.
func trashConfirmationText(trashable: [Hit], skipped: [Hit])
    -> (message: String, info: String) {
    let message = trashable.count == 1
        ? "„\(trashable[0].displayName)“ in den Papierkorb legen?"
        : "\(groupedNumber(trashable.count)) Objekte in den Papierkorb legen?"
    var info = "Aus dem Papierkorb lassen sie sich im Finder zurückholen."
    if !skipped.isEmpty {
        info += skipped.count == 1
            ? "\n\nEin Treffer liegt in einem Archiv und wird ausgelassen: "
                + skipped[0].path
            : "\n\n\(groupedNumber(skipped.count)) Treffer liegen in Archiven "
                + "und werden ausgelassen."
    }
    return (message, info)
}

/// Legt die Dateien der Treffer in den Papierkorb — in EINEM Aufruf, damit
/// eine große Auswahl nicht Datei für Datei abgearbeitet wird.
/// `recycle` meldet im Wörterbuch nur die Dateien, die wirklich verschoben
/// wurden; die Antwort kommt auf dem Main-Thread.
/// `trashed` bildet den bisherigen Pfad auf den neuen Ort im Papierkorb ab.
func trashHits(_ hits: [Hit],
               completion: @escaping (_ trashed: [String: URL],
                                      _ error: Error?) -> Void) {
    let urls = hits.map { URL(fileURLWithPath: $0.filesystemPath) }
    NSWorkspace.shared.recycle(urls) { moved, error in
        var trashed: [String: URL] = [:]
        for (original, inTrash) in moved { trashed[original.path] = inTrash }
        DispatchQueue.main.async { completion(trashed, error) }
    }
}

/// Das Papierkorb-Geräusch des Finders — dieselbe Klangdatei, die auch der
/// Finder abspielt. Fehlt sie (andere macOS-Version), bleibt es still, statt
/// ersatzweise einen fremden Systemton zu spielen.
let finderTrashSoundPath =
    "/System/Library/Components/CoreAudio.component/Contents/SharedSupport"
    + "/SystemSounds/finder/move to trash.aif"

private let finderTrashSound = NSSound(contentsOfFile: finderTrashSoundPath,
                                       byReference: true)

func playFinderTrashSound() {
    guard let sound = finderTrashSound else { return }
    // Eine noch laufende Wiedergabe erst anhalten: NSSound spielt eine
    // Instanz sonst nicht erneut an, und bei zwei Löschungen kurz
    // hintereinander bliebe die zweite stumm.
    if sound.isPlaying { sound.stop() }
    sound.play()
}

func installMainMenu(appName: String, includeClose: Bool = false) {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "\(appName) beenden",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    if includeClose {
        // performClose läuft über die Responder-Kette ans Key-Fenster; beim
        // Panel löst das windowWillClose aus → die Schnellsuche beendet sich.
        appMenu.addItem(withTitle: "Fenster schließen",
                        action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")
    }
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Bearbeiten")
    editMenu.addItem(withTitle: "Ausschneiden",
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Kopieren",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Einsetzen",
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Alles auswählen",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
    editItem.submenu = editMenu

    NSApp.mainMenu = mainMenu
}

// ---------- Gemeinsamer Unterbau beider Trefferlisten ----------

final class ResultGroupButton: NSButton {
    var groupKey: ResultGroupKey?
}

final class ResultGroupHeaderView: NSView {
    private weak var table: NSTableView?
    private var leading: NSLayoutConstraint!
    private var width: NSLayoutConstraint!
    private var observers: [NSObjectProtocol] = []
    private var parentObservers: [NSObjectProtocol] = []

    init(table: NSTableView, content: NSStackView) {
        self.table = table
        content.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: .zero)
        addSubview(content)
        leading = content.leadingAnchor.constraint(equalTo: leadingAnchor)
        width = content.widthAnchor.constraint(equalToConstant: max(120, table.visibleRect.width))
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor), leading, width])
        // Der Tabelleninhalt darf breiter als der Ausschnitt sein. Kopf und
        // Trefferzahl folgen gemeinsam dem sichtbaren Ausschnitt.
        if let clip = table.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                    self?.needsLayout = true
                })
            }
        }
        if let scroller = table.enclosingScrollView?.verticalScroller {
            scroller.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroller, queue: .main) { [weak self] _ in
                self?.needsLayout = true
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    deinit { (observers + parentObservers).forEach(NotificationCenter.default.removeObserver) }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        parentObservers.forEach(NotificationCenter.default.removeObserver)
        parentObservers = []
        if let parent = superview {
            parent.postsFrameChangedNotifications = true
            parent.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                parentObservers.append(NotificationCenter.default.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                    self?.needsLayout = true
                })
            }
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }

    override func layout() {
        let visible = table.map { convert($0.visibleRect, from: $0) } ?? bounds
        let offset = max(bounds.minX, visible.minX)
        var right = min(bounds.maxX, visible.maxX)
        if let scroll = table?.enclosingScrollView, scroll.hasVerticalScroller,
           let scroller = scroll.verticalScroller, !scroller.isHidden {
            let edge = convert(scroller.bounds, from: scroller)
            if edge.width > 0 && edge.minX > offset { right = min(right, edge.minX) }
        }
        let available = max(0, right - offset)
        if leading.constant != offset + 2 { leading.constant = offset + 2 }
        if width.constant != max(0, available - 4) { width.constant = max(0, available - 4) }
        super.layout()
    }
}

final class ResultGroupingController: NSObject {
    weak var owner: HitListController?
    let view = NSStackView()
    let popup = NSPopUpButton()
    let expandButton = NSButton(title: "Alle aufklappen", target: nil, action: nil)
    let collapseButton = NSButton(title: "Alle einklappen", target: nil, action: nil)
    private(set) var mode: ResultGroupingMode = .none
    private(set) var collapsed = Set<ResultGroupKey>()
    private(set) var projection = ResultProjection(hits: [], mode: .none)
    var isActive: Bool { mode != .none }
    var state: [String: Any] {
        ["mode": mode.rawValue, "groupCount": projection.groups.count,
         "collapsedGroupCount": projection.groups.filter { collapsed.contains($0.key) }.count,
         "matchedCount": owner?.hits.count ?? 0, "displayedHitCount": projection.displayedHitCount,
         "resultsIncludeCollapsed": true]
    }

    init(owner: HitListController) {
        self.owner = owner
        super.init()
        popup.addItems(withTitles: ResultGroupingMode.allCases.map { $0.title })
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityIdentifier("resultGroupingMode")
        popup.setAccessibilityLabel("Treffer gruppieren nach")
        expandButton.target = self
        expandButton.action = #selector(expandAll)
        expandButton.setAccessibilityIdentifier("resultGroupingExpandAll")
        collapseButton.target = self
        collapseButton.action = #selector(collapseAll)
        collapseButton.setAccessibilityIdentifier("resultGroupingCollapseAll")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for child in [NSTextField(labelWithString: "Gruppieren:"), popup, expandButton, collapseButton, spacer] {
            view.addArrangedSubview(child)
        }
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 6
        rebuild()
    }

    func rebuild() {
        projection = ResultProjection(hits: owner?.hits ?? [], mode: mode, collapsed: collapsed,
                                      root: owner?.resultFilterRoot ?? "/")
        expandButton.isEnabled = isActive && projection.groups.contains { collapsed.contains($0.key) }
        collapseButton.isEnabled = isActive && projection.groups.contains { !collapsed.contains($0.key) }
    }

    func clearForSearch() { collapsed.removeAll() }

    func setMode(_ mode: ResultGroupingMode) {
        guard mode != self.mode else { return }
        owner?.flushResultFilterPending()
        self.mode = mode
        popup.selectItem(at: ResultGroupingMode.allCases.firstIndex(of: mode)!)
        collapsed.removeAll()
        reproject()
    }
    @objc private func changed() { setMode(ResultGroupingMode.allCases[popup.indexOfSelectedItem]) }
    @objc func expandAll() { collapsed.removeAll(); reproject() }
    @objc func collapseAll() {
        owner?.flushResultFilterPending()
        collapsed = Set(projection.groups.map { $0.key })
        reproject()
    }
    @objc private func toggle(_ sender: ResultGroupButton) {
        guard let key = sender.groupKey, projection.groups.contains(where: { $0.key == key }) else { return }
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        reproject()
    }
    func expand(hitIndex: Int) {
        guard let owner, owner.hits.indices.contains(hitIndex), isActive else { return }
        let key = ResultProjection.group(for: owner.hits[hitIndex], mode: mode, root: owner.resultFilterRoot ?? "/").0
        if collapsed.remove(key) != nil { reproject() }
    }
    private func reproject() {
        guard let owner else { return }
        let selected = owner.selectedHitIdentities()
        owner.resultViewWillChange()
        owner.replaceFilteredHits(owner.hits, keepingSelection: selected)
    }

    func headerContent(_ group: ResultGroup) -> NSStackView {
        let button = ResultGroupButton(title: (collapsed.contains(group.key) ? "▸ " : "▾ ") + group.title,
                                       target: self, action: #selector(toggle(_:)))
        button.groupKey = group.key
        button.isBordered = false
        button.alignment = .left
        button.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.toolTip = group.title
        button.setAccessibilityLabel("Gruppe " + group.title)
        button.setAccessibilityValue("\(group.hitIndices.count) Treffer, " + (collapsed.contains(group.key) ? "eingeklappt" : "aufgeklappt"))
        let count = NSTextField(labelWithString: "\(groupedNumber(group.hitIndices.count)) Treffer")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = NSStackView(views: [button, count])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return header
    }
    func header(at row: Int) -> NSView? {
        guard let owner, let group = projection.group(at: row) else { return nil }
        return ResultGroupHeaderView(table: owner.tableView, content: headerContent(group))
    }

}

func sourceArchiveURLs(for hits: [Hit]) -> [URL] {
    var seen = Set<Data>()
    return hits.filter { $0.isMember && seen.insert(Data($0.filesystemPath.utf8)).inserted }
        .map { URL(fileURLWithPath: $0.filesystemPath) }
}

func archiveChainText(for hit: Hit) -> String {
    func label(_ text: String) -> String {
        let bytes = text.utf8
        return String(decoding: bytes.prefix(4096), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r") + (bytes.count > 4096 ? "…" : "")
    }
    var lines = ["Quellarchiv: " + label(hit.filesystemPath)]
    for (index, member) in hit.archiveMembers.prefix(32).enumerated() {
        lines.append((index == hit.archiveMembers.count - 1 ? "Treffer: " : "Archivstufe \(index + 1): ") + label(member))
    }
    if hit.archiveMembers.count > 32 { lines.append("Weitere Archivstufen sind gekürzt.") }
    return lines.joined(separator: "\n\n")
}

func makeArchiveChainAlert(for hit: Hit) -> NSAlert {
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 800)
    let size = NSSize(width: min(640, max(280, visible.width - 120)),
                      height: min(300, max(120, visible.height - 260)))
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.setAccessibilityIdentifier("archiveChainScroll")
    let text = NSTextView(frame: NSRect(origin: .zero, size: size))
    text.isEditable = false
    text.isSelectable = true
    text.isHorizontallyResizable = false
    text.isVerticallyResizable = true
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
    text.textContainerInset = NSSize(width: 8, height: 8)
    text.font = .systemFont(ofSize: NSFont.systemFontSize)
    text.string = archiveChainText(for: hit)
    text.setAccessibilityIdentifier("archiveChainText")
    scroll.documentView = text
    let alert = NSAlert()
    alert.messageText = "Archivkette"
    alert.informativeText = "Quellarchiv und innere Stufen. Lange Namen sind ausdrücklich gekürzt."
    alert.accessoryView = scroll
    alert.addButton(withTitle: "Schließen")
    alert.window.initialFirstResponder = text
    return alert
}

final class ResultFilterController: NSObject {
    weak var owner: HitListController?
    let criteria = CriteriaControl()
    let resetButton = NSButton(title: "Zurücksetzen", target: nil, action: nil)
    let countLabel = NSTextField(labelWithString: "")
    let view = NSStackView()
    private(set) var sourceHits: [Hit]?
    private var sourceIdentities: Set<HitIdentity> = []
    private var pending: [Hit] = []
    private var activeRun: ResultFilterRun?
    private var retiringRuns: [ResultFilterRun] = []
    private var query: String?
    private var dateReferenceTime: String?
    private var dateResolution: Data?
    private var needsDateProof = false
    private var root: String?
    private var firstSelection: Set<HitIdentity>?
    private(set) var errorMessage: String?
    var isActive: Bool { sourceHits != nil }
    var isFiltering: Bool { activeRun != nil || !pending.isEmpty }
    var runningProcessIdentifier: pid_t? {
        guard let process = activeRun?.runner.process, process.isRunning else { return nil }
        return process.processIdentifier
    }
    var sourceCount: Int { sourceHits?.count ?? owner?.hits.count ?? 0 }
    var unfilteredHits: [Hit] { sourceHits ?? owner?.hits ?? [] }
    var state: [String: Any] {
        var result: [String: Any] = ["active": isActive, "loading": isFiltering,
            "sourceCount": sourceCount, "visibleCount": owner?.hits.count ?? 0]
        if let query { result["criteriaJSON"] = query }
        if let dateReferenceTime { result["dateReferenceTime"] = dateReferenceTime }
        if let dateResolution { result["dateResolution"] = preservedJSONObject(dateResolution) }
        if let errorMessage { result["error"] = errorMessage }
        return result
    }

    init(owner: HitListController) {
        self.owner = owner
        super.init()
        criteria.isResultFilter = true
        criteria.enabledButton.title = "Trefferliste filtern"
        criteria.enabledButton.identifier = NSUserInterfaceItemIdentifier("result-filter-enabled")
        criteria.editButton.identifier = NSUserInterfaceItemIdentifier("result-filter-edit")
        criteria.onChange = { [weak self] in self?.apply() }
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.identifier = NSUserInterfaceItemIdentifier("result-filter-reset")
        countLabel.identifier = NSUserInterfaceItemIdentifier("result-filter-count")
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [criteria, resetButton, spacer, countLabel].forEach { view.addArrangedSubview($0) }
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 8
        refresh()
    }
    deinit { activeRun?.cancel(); retiringRuns.forEach { $0.cancel() } }

    func compact() {
        for child in view.arrangedSubviews {
            view.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [resetButton, spacer, countLabel])
        status.orientation = .horizontal
        status.spacing = 8
        status.alignment = .centerY
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 4
        view.addArrangedSubview(criteria)
        view.addArrangedSubview(status)
        criteria.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
    }

    func stopForTermination() {
        criteria.stopForTermination()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        activeRun?.stopForTermination(deadline: deadline)
        retiringRuns.forEach { $0.stopForTermination(deadline: deadline) }
        activeRun = nil
        retiringRuns = []
        pending = []
    }

    private func cancelWork() {
        if let activeRun { retiringRuns.append(activeRun); activeRun.cancel() }
        activeRun = nil
        pending = []
        firstSelection = nil
    }

    func clearForSearch() {
        cancelWork()
        owner?.resultGrouping.clearForSearch()
        sourceHits = nil
        sourceIdentities = []
        query = nil
        dateReferenceTime = nil; dateResolution = nil; needsDateProof = false
        errorMessage = nil
        criteria.applyJSON(nil)
        refresh()
    }

    @objc func reset() {
        criteria.applyJSON(nil)
        apply()
    }

    func apply() {
        guard let owner else { return }
        owner.flushResultFilterPending()
        let selection = owner.selectedHitIdentities()
        owner.resultViewWillChange()
        let source = sourceHits ?? owner.hits
        cancelWork()
        errorMessage = nil
        query = criteria.queryJSON
        dateReferenceTime = DateRangeTransport.criteriaHasRanges(query) ? DateRangeTransport.referenceNow() : nil
        dateResolution = nil; needsDateProof = dateReferenceTime != nil && source.isEmpty
        guard query != nil else {
            sourceHits = nil
            sourceIdentities = []
            owner.replaceFilteredHits(source, keepingSelection: selection)
            refresh()
            return
        }
        root = owner.resultFilterRoot
        sourceHits = source
        sourceIdentities = Set(source.map { $0.identity })
        firstSelection = selection
        owner.replaceFilteredHits([], keepingSelection: [])
        pending = source
        startNext()
        refresh()
    }

    func append(_ incoming: [Hit]) {
        precondition(isActive)
        sourceHits?.append(contentsOf: incoming)
        sourceIdentities.formUnion(incoming.map { $0.identity })
        if errorMessage == nil { pending.append(contentsOf: incoming); startNext() }
        refresh()
    }

    func remove(where predicate: (Hit) -> Bool) {
        guard sourceHits != nil else { return }
        let removed = Set(sourceHits!.filter(predicate).map { $0.identity })
        sourceHits?.removeAll(where: predicate)
        sourceIdentities.subtract(removed)
        pending.removeAll { removed.contains($0.identity) }
        refresh()
    }

    private func startNext() {
        guard let query, activeRun == nil, errorMessage == nil, !pending.isEmpty || needsDateProof else { return }
        needsDateProof = false
        let batch = pending
        pending = []
        let job = ResultFilterRun()
        activeRun = job
        job.start(batch, query: query, root: root, dateReferenceTime: dateReferenceTime, frozenDateResolution: dateResolution,
                  onDateResolution: { [weak self, weak job] data in
            guard let self, let job, self.activeRun === job else { return }; self.dateResolution = data
        }) { [weak self, weak job] accepted, error in
            guard let self, let job else { return }
            self.retiringRuns.removeAll { $0 === job }
            guard self.activeRun === job, let owner = self.owner else { return }
            self.activeRun = nil
            if let accepted, error == nil {
                let matches = batch.filter { accepted.contains($0.identity) && self.sourceIdentities.contains($0.identity) }
                let selection = self.firstSelection ?? owner.selectedHitIdentities()
                self.firstSelection = nil
                owner.appendFilteredHits(matches, keepingSelection: selection)
                self.startNext()
            } else {
                self.errorMessage = error ?? "Ansichtsfilter fehlgeschlagen."
                self.pending = []
                self.firstSelection = nil
                owner.replaceFilteredHits(owner.hits, keepingSelection: owner.selectedHitIdentities())
            }
            self.refresh()
        }
    }

    func refresh() {
        let count = "\(groupedNumber(owner?.hits.count ?? 0)) von \(groupedNumber(sourceCount)) Treffern"
        let grouping = owner.map { $0.resultGrouping.isActive ? " · \(groupedNumber($0.resultGrouping.projection.displayedHitCount)) aufgeklappt" : "" } ?? ""
        countLabel.stringValue = count + grouping + (isFiltering ? " · Filter läuft…" : errorMessage == nil ? "" : " · Filterfehler")
        countLabel.toolTip = errorMessage ?? "Ansichtsfilter lesen ausschließlich bereits bekannte Trefferwerte."
        countLabel.textColor = errorMessage == nil ? .secondaryLabelColor : .systemRed
        resetButton.isEnabled = isActive
    }
}

/// Was Haupt-App und Schnellsuche an ihrer Trefferliste GLEICH tun: die
/// wirksame Zeilenmenge bestimmen, Treffer materialisieren, Quick Look
/// zeigen und blättern, „Öffnen mit", „Im Finder zeigen" und „Pfad kopieren".
/// Bis 0.28.2 standen diese 123 Zeilen wörtlich gleich in beiden Apps und
/// liefen bereits auseinander: Der Fokus-Fix der Vorschau landete zuerst nur
/// in der Haupt-App, die Indexprüfung zuerst nur in der Schnellsuche
/// (CodeQA-Fund frontend-adapter-duplication, 2026-09-03).
///
/// Eine Basisklasse statt einer Protokoll-Erweiterung, weil die Methoden
/// hier `@objc` sein müssen — als Selector-Ziele der Menüs und als die
/// informellen NSResponder-Methoden, über die Quick Look seinen Controller
/// sucht. Eine Protokoll-Erweiterung kann beides nicht liefern.
/// Beide Apps kompilieren diese Datei in ihr eigenes Modul; die Klasse ist
/// deshalb bewusst nicht `final`, und `presentActionIssue` ist der eine
/// Punkt, den jede App selbst füllt (Fußzeile bzw. Infozeile).
class HitListController: NSObject, QLPreviewPanelDataSource,
                         QLPreviewPanelDelegate, NSMenuItemValidation, NSFilePromiseProviderDelegate {
    let exportWriter = ExportWriter()
    lazy var searchReportController = SearchReportController(owner: self)
    lazy var duplicateCheckController = DuplicateCheckController(owner: self)
    lazy var contentPreviewController = ContentPreviewController(owner: self)
    var localOnlyContent: Bool { false }
    let finderMetadataView = FinderMetadataView()
    var windowViewport: SearchWindowViewport?
    var onFinderColumnsShown: (() -> Void)?
    var finderColumnsVisible: Bool {
        tableView.tableColumns.contains { ["finderTags", "finderComment"].contains($0.identifier.rawValue) && !$0.isHidden }
    }
    lazy var resultFilter = ResultFilterController(owner: self)
    lazy var resultGrouping = ResultGroupingController(owner: self)
    var resultFilterRoot: String? { "/" }
    // Zwischenzustände beim Wiederherstellen derselben Auswahl dürfen eine
    // bereits navigierte Fundstelle nicht als abgewählt behandeln.
    var isRestoringSelection = false
    func flushResultFilterPending() {}
    func resultViewWillChange() {
        thumbnailController?.loader.cancelAll()
        cancelMaterializations(reportCancellation: false)
        closeOpenPreview()
        contextRow = -1
    }
    func replaceFilteredHits(_ incoming: [Hit], keepingSelection selection: Set<HitIdentity>) {
        hits = incoming
        isRestoringSelection = true
        resultGrouping.rebuild()
        tableView.deselectAll(nil)
        tableView.reloadData()
        tableView.selectRowIndexes(tableRows(for: selection), byExtendingSelection: false)
        isRestoringSelection = false
        contextRow = -1
        refreshContentPreview()
    }
    func appendFilteredHits(_ incoming: [Hit], keepingSelection selection: Set<HitIdentity>) {
        replaceFilteredHits(hits + incoming, keepingSelection: selection)
    }
    var contentPreviewView: ContentPreviewView { contentPreviewController.view }
    func refreshContentPreview() {
        thumbnailController?.selectionFromTable()
        contentPreviewController.selectionChanged()
        finderMetadataView.render(selectedHitIndices.first.map { hits[$0] })
    }
    func configureFinderColumns() {
        let menu = tableView.headerView?.menu ?? NSMenu(title: "Spalten")
        for (key, title) in [("finderTags", "Finder-Tags"), ("finderComment", "Finder-Kommentar")] {
            let column = NSTableColumn(identifier: .init(key))
            column.title = title; column.width = 180; column.minWidth = 80
            column.isHidden = true
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            tableView.addTableColumn(column)
            let item = NSMenuItem(title: title, action: #selector(toggleFinderColumn(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = key; menu.addItem(item)
        }
        tableView.headerView?.menu = menu
    }
    func restoreFinderColumnVisibility() {
        for key in ["finderTags", "finderComment"] {
            tableView.tableColumn(withIdentifier: .init(key))?.isHidden = !UserDefaults.standard.bool(forKey: "finderColumn." + key)
        }
        if finderColumnsVisible { onFinderColumnsShown?() }
    }
    @objc private func toggleFinderColumn(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String, let column = tableView.tableColumn(withIdentifier: .init(key)) else { return }
        column.isHidden.toggle()
        UserDefaults.standard.set(!column.isHidden, forKey: "finderColumn." + key)
        if !column.isHidden { onFinderColumnsShown?() }
    }
    func renderFinderColumn(_ column: NSTableColumn, cell: NSTableCellView, hit: Hit) -> Bool {
        switch column.identifier.rawValue {
        case "finderTags":
            (cell as? FinderTagsCellView)?.snapshot = hit.finderMetadata
            cell.textField?.toolTip = hit.finderMetadata?.tags?.map { $0.name + " · " + FinderMetadataView.colorNames[$0.color ?? 0] }.joined(separator: "\n") ?? hit.finderMetadata?.tagsText ?? "Nicht erfasst"
        case "finderComment":
            let original = hit.finderMetadata?.commentText ?? "Nicht erfasst"
            cell.textField?.stringValue = FinderMetadataView.singleLineSummary(original)
            cell.textField?.toolTip = original
        default: return false
        }
        cell.textField?.alignment = .left
        cell.textField?.lineBreakMode = .byTruncatingTail
        return true
    }
    func contentPreviewArguments(_ arguments: [String]) -> [String] {
        guard contentPreviewView.enabled else { return arguments }
        var result = arguments
        result.insert("--content-preview", at: result.firstIndex(of: "--") ?? result.endIndex)
        return result
    }
    func searchOutputArguments(_ arguments: [String]) -> [String] {
        var result = contentPreviewArguments(arguments)
        result.insert("--search-report", at: result.firstIndex(of: "--") ?? result.endIndex)
        return result
    }
    var window: NSWindow!
    let tableView = HitResultTableView()
    var thumbnailController: ThumbnailGridController?
    var activeResultView: NSView {
        if let grid = thumbnailController, grid.isGrid { return grid.collection }
        return tableView
    }
    var resultListHasFocus: Bool {
        window?.firstResponder === tableView
            || (thumbnailController?.isGrid == true && window?.firstResponder === thumbnailController?.collection)
    }
    func installThumbnails(in scroll: NSScrollView, compact: Bool) {
        thumbnailController = ThumbnailGridController(owner: self, scroll: scroll, compact: compact)
    }

    var hits: [Hit] = []            // gefilterte Treffer, auch in eingeklappten Gruppen
    var pending: [Hit] = []         // frisch gestreamte, noch nicht gezeigte
    var contextRow = -1             // Zeile, auf die der Rechtsklick ging
    var previewURLs: [URL] = []     // gerade in der QuickLook-Vorschau

    /// Die zuletzt angeforderte Vorschau. Quick Look zeigt AUSSCHLIESSLICH
    /// die letzte Auswahl: Jede neue Anforderung bricht die vorige ab, und
    /// eine spät eintreffende alte wird verworfen (Identitätsvergleich).
    var previewRequest: MaterializationSelectionRequest?
    /// Laufende Aufträge von Öffnen, „Öffnen mit" und „Im Finder zeigen".
    /// Jeder arbeitet mit der FESTEN Auswahl vom Klick; ⎋ bricht sie ab.
    var actionRequests: [MaterializationSelectionRequest] = []
    /// Ein Listenwechsel entwertet auch bereits eingereihte Abbruchmeldungen.
    private var actionGeneration = 0

    /// Wird gerade ein Archivtreffer ausgepackt? Die Apps zeigen das an.
    var isMaterializing: Bool {
        previewRequest != nil || !actionRequests.isEmpty
    }

    /// Der Satz, den beide Apps während des Auspackens zeigen.
    static let materializingNote = "Packe Archivtreffer aus… (⎋ bricht ab)"

    // ---------- Wirksame Zeilenmenge ----------

    var resultTableRowCount: Int {
        resultGrouping.projection.mode == .none ? hits.count : resultGrouping.projection.rowCount
    }

    func hitIndex(forTableRow row: Int) -> Int? {
        let index = resultGrouping.projection.mode == .none ? row : resultGrouping.projection.hitIndex(at: row)
        return index.flatMap { hits.indices.contains($0) ? $0 : nil }
    }

    func tableRow(forHitIndex index: Int) -> Int? {
        guard hits.indices.contains(index) else { return nil }
        return resultGrouping.projection.mode == .none ? index : resultGrouping.projection.tableRow(for: index)
    }

    func revealTableRow(for identity: HitIdentity) -> Int? {
        guard let index = hits.firstIndex(where: { $0.identity == identity }) else { return nil }
        resultGrouping.expand(hitIndex: index)
        DispatchQueue.main.async { [weak self] in self?.thumbnailController?.reveal(identity) }
        return hits.firstIndex(where: { $0.identity == identity }).flatMap { tableRow(forHitIndex: $0) }
    }

    var selectedHitIndices: [Int] {
        tableView.selectedRowIndexes.compactMap { hitIndex(forTableRow: $0) }
    }

    func tableRows(for identities: Set<HitIdentity>) -> IndexSet {
        IndexSet(hits.indices.filter { identities.contains(hits[$0].identity) }.compactMap { tableRow(forHitIndex: $0) })
    }

    func actionRows() -> [Int] {
        // Ein Header-Rechtsklick darf nie auf eine alte Dateiauswahl zurückfallen.
        if contextRow >= 0, hitIndex(forTableRow: contextRow) == nil { return [] }
        return hitActionRows(selectedRows: tableView.selectedRowIndexes,
                             contextRow: contextRow).compactMap { hitIndex(forTableRow: $0) }
    }

    /// Materialisiert die wirksame Zeilenmenge und ruft `body` mit dem
    /// Ergebnis — sofort, wenn nichts ausgepackt werden muss, sonst auf der
    /// Main-Queue nach dem Auspacken. Solange dauert der Ladezustand
    /// (`presentMaterializationState`). Ein Abbruch über ⎋ ruft `body` nicht
    /// und meldet sich stattdessen als Hinweis.
    func withActionSelection(
        _ body: @escaping (MaterializedHitSelection) -> Void) {
        let rows = actionRows()
        let generation = actionGeneration
        var request: MaterializationSelectionRequest?
        var finished = false
        let started = materializeHitSelection(hits, rows: rows) {
            [weak self] selection in
            finished = true
            guard let self, generation == self.actionGeneration else { return }
            if let request {
                self.actionRequests.removeAll { $0 === request }
                self.presentMaterializationState()
            }
            if selection.cancelled {
                self.presentActionIssue(summary: "Auspacken abgebrochen.",
                                        detail: nil)
                return
            }
            body(selection)
        }
        if !finished {
            request = started
            actionRequests.append(started)
            presentMaterializationState()
        }
    }

    /// Bricht alle laufenden Auspackvorgänge ab (Vorschau und Aktionen).
    /// Liefert, ob es etwas abzubrechen gab — der Tastaturmonitor gibt ⎋
    /// nur dann nicht weiter. Listenwechsel unterdrücken Meldungen der alten
    /// Aktionen; der ausdrückliche Escape-Abbruch meldet sich weiterhin.
    @discardableResult
    func cancelMaterializations(reportCancellation: Bool = true) -> Bool {
        // Vor der Leerprüfung: Ein früherer Escape-Abbruch kann seine
        // Completion bereits eingereiht und die Auftragsliste geleert haben.
        if !reportCancellation { actionGeneration += 1 }
        let loadingContent = contentPreviewController.isLoading
        if loadingContent { contentPreviewController.cancelLoad(message: reportCancellation ? "Nachladen abgebrochen." : nil) }
        guard isMaterializing else { return loadingContent }
        previewRequest?.cancel()
        previewRequest = nil
        actionRequests.forEach { $0.cancel() }
        actionRequests.removeAll()
        presentMaterializationState()
        return true
    }

    /// Von jeder App überschrieben: zeigt `isMaterializing` an — die
    /// Haupt-App in der Fußzeile, die Schnellsuche in der Infozeile.
    func presentMaterializationState() {}

    /// Die ausgewählten Treffer als Identitäten — modellbezogen statt über
    /// Zeilennummern, die ein `reloadData()` nicht überlebt.
    func selectedHitIdentities() -> Set<HitIdentity> {
        Set(selectedHitIndices.map { hits[$0].identity })
    }

    /// Nennt, was sich an der Auswahl NICHT öffnen ließ (Ordner im Archiv).
    /// Wohin die Meldung geht, weiß nur die App — siehe presentActionIssue.
    func showActionIssue(_ selection: MaterializedHitSelection) {
        guard let issue = hitActionIssue(selection) else { return }
        presentActionIssue(summary: issue.summary, detail: issue.detail)
    }

    /// Von jeder App überschrieben: Die Haupt-App schreibt in die Fußzeile,
    /// die Schnellsuche in ihre Infozeile. Die Basis zeigt nichts an.
    func presentActionIssue(summary: String, detail: String?) {}

    func hitPasteboardWriter(_ index: Int) -> NSPasteboardWriting? {
        guard hits.indices.contains(index) else { return nil }
        let hit = hits[index]
        guard hit.hasOpenableFile else { return nil }
        if let url = MaterializationManager.shared.knownURL(for: hit) { return url as NSURL }
        let type = UTType(filenameExtension: (hit.path as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = hit
        return provider
    }

    // ---------- Dateiversprechen für Archiv-Einträge ----------

    /// Eigene Queue: Die Delegate-Aufrufe des Versprechens laufen dort,
    /// nicht auf Main.
    let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "favenio.file-promise"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        guard let hit = provider.userInfo as? Hit else { return "Datei" }
        return (hit.archiveMembers.last.map { ($0 as NSString).lastPathComponent }
                ?? (hit.path as NSString).lastPathComponent)
    }

    /// Der Empfänger löst das Versprechen ein: auspacken (oder aus dem
    /// Cache nehmen) und an die gewünschte Stelle KOPIEREN — die Temp-Datei
    /// bleibt für weitere Aktionen erhalten, aufgeräumt wird beim App-Ende.
    /// Fehler und Abbruch gehen als Error an den Empfänger, der sie nennt.
    /// Bewusst NICHT in `actionRequests`/⎋ eingebunden: Der Auftrag gehört
    /// dem Finder, der auf die versprochene Datei wartet; ein Abbruch aus
    /// unserem Fenster ließe seinen Ablegevorgang mit einem Fehler enden.
    /// Deshalb auch kein „Packe aus…" in der Fußzeile.
    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let hit = provider.userInfo as? Hit else {
            completionHandler(promiseError("Treffer nicht mehr bekannt"))
            return
        }
        DispatchQueue.main.async {
            MaterializationManager.shared.request(hit) { outcome in
                switch outcome {
                case .ready(let source):
                    DispatchQueue.global(qos: .userInitiated).async {
                        do {
                            try FileManager.default.copyItem(at: source, to: url)
                            completionHandler(nil)
                        } catch {
                            completionHandler(error)
                        }
                    }
                case .failed(let reason):
                    completionHandler(self.promiseError(reason))
                case .cancelled:
                    completionHandler(self.promiseError("Auspacken abgebrochen"))
                }
            }
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        promiseQueue
    }

    private func promiseError(_ reason: String) -> NSError {
        NSError(domain: "Favenio", code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason])
    }

    // ---------- QuickLook-Vorschau ----------

    /// Vorschau der ausgewählten Treffer ein-/ausblenden. Archiv-Einträge
    /// werden dafür (wie beim Öffnen) in einen Temp-Ordner ausgepackt —
    /// im Hintergrund; das Panel geht erst auf, wenn die Dateien da sind.
    @objc func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        // Erst nachsehen, ob es überhaupt etwas zu zeigen gibt. Ein ORDNER im
        // Archiv hat keine Datei: Das Panel bliebe leer. Im Kontextmenü ist
        // die Vorschau dafür schon grau — über die Leertaste war sie trotzdem
        // erreichbar (Review-Fund 2026-08-20). Das steht ohne Auspacken fest.
        let rows = actionRows()
        let selected = rows.compactMap {
            hits.indices.contains($0) ? hits[$0] : nil
        }
        guard selected.contains(where: { $0.hasOpenableFile }) else {
            showActionIssue(MaterializedHitSelection(
                rows: rows, urls: [], unavailable: selected))
            return
        }
        requestPreview(rows: rows) { [weak self] selection in
            guard let self, let panel = QLPreviewPanel.shared() else { return }
            self.previewURLs = selection.urls
            self.showActionIssue(selection)
            guard !previewURLs.isEmpty else { return }
            // Das Panel wird NUR nach vorn geholt, nicht zum Tastaturfenster
            // gemacht. Sonst gehen Pfeil hoch/runter dorthin und die Vorschau
            // lässt sich nicht durch die Trefferliste blättern — genau das,
            // was der Finder kann.
            //
            // Ein erster Versuch holte den Fokus danach per DispatchQueue
            // zurück. Das ist ein Rennen und verliert: Am 2026-09-02 am
            // laufenden Fenster gemessen blieb das Panel Tastaturfenster, die
            // Auswahl in der Tabelle wurde grau und die Pfeiltaste bewegte
            // nichts. Deshalb wird der Fokus gar nicht erst abgegeben.
            //
            // Damit entfällt auch der Weg, über den QuickLook seinen
            // Controller sonst sucht: `beginPreviewPanelControl` kommt über
            // die Responder-Kette beim Wechsel des Tastaturfensters. Ohne
            // diesen Wechsel muss die Datenquelle hier ausdrücklich gesetzt
            // werden, sonst bliebe das Panel leer.
            panel.dataSource = self
            panel.delegate = self
            panel.orderFront(nil)
            panel.reloadData()
            // Der Fokus gehört in die aktive Trefferansicht — von dort blättern die
            // Pfeiltasten.
            window.makeFirstResponder(activeResultView)
        }
    }

    /// Fordert die Vorschau-Dateien einer FESTEN Zeilenmenge an. Nur die
    /// zuletzt angeforderte Auswahl zählt: Die vorige wird abgebrochen, und
    /// `completion` läuft nur, wenn dieser Auftrag noch der aktuelle ist —
    /// ein schneller Auswahlwechsel kann sonst eine alte Vorschau über die
    /// neue legen.
    func requestPreview(
        rows: [Int],
        completion: @escaping (MaterializedHitSelection) -> Void) {
        previewRequest?.cancel()
        previewRequest = nil
        var request: MaterializationSelectionRequest?
        var finished = false
        let started = materializeHitSelection(hits, rows: rows) {
            [weak self] selection in
            finished = true
            guard let self else { return }
            if let request {
                guard self.previewRequest === request else { return }
                self.previewRequest = nil
            }
            // Auch eine sofort verfügbare neue Auswahl beendet den
            // Ladezustand der zuvor abgebrochenen Archivvorschau.
            self.presentMaterializationState()
            guard !selection.cancelled else { return }
            completion(selection)
        }
        if !finished {
            request = started
            previewRequest = started
            presentMaterializationState()
        }
    }

    /// Offene Vorschau auf die aktuelle Auswahl nachziehen. Das Panel lädt
    /// nur neu, wenn es jetzt andere Dateien meint.
    func refreshPreview() {
        requestPreview(rows: actionRows()) { [weak self] selection in
            guard let self else { return }
            let shown = self.previewURLs
            self.previewURLs = selection.urls
            if self.previewURLs != shown,
               QLPreviewPanel.sharedPreviewPanelExists() {
                QLPreviewPanel.shared().reloadData()
            }
        }
    }

    // QuickLook fragt diese Methoden über die Responder-Kette + den
    // App-Delegate ab (informelles Protokoll auf NSResponder).
    @objc override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        guard let panel else { return false }
        // Andere Trefferfenster dürfen die ausdrücklich gesetzte Datenquelle nicht übernehmen.
        if let owner = panel.dataSource as? HitListController { return owner === self }
        return window?.isKeyWindow == true
    }
    @objc override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard acceptsPreviewPanelControl(panel) else { return }
        panel.dataSource = self
        panel.delegate = self
        refreshPreview()
    }
    @objc override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }
    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> QLPreviewItem! {
        // Das Panel fragt seinen ALTEN Index auch dann noch ab, wenn die
        // Liste inzwischen kürzer ist: ⌫ oder ⌘⌫ auf der Auswahl kürzt
        // previewURLs und ruft danach reloadData(). Ohne diese Prüfung
        // griff der Zugriff ins Leere und beendete die App.
        guard index >= 0, index < previewURLs.count else { return nil }
        return previewURLs[index] as NSURL
    }

    /// Tasten, die beim Vorschaufenster landen.
    ///
    /// `orderFront` genügt nicht, um das Panel vom Tastaturfokus fernzuhalten:
    /// Am 2026-09-02 am laufenden Fenster gemessen wurde es nach der Leertaste
    /// trotzdem Tastaturfenster (Auswahl grau, Pfeiltasten wirkungslos), erst
    /// ein Klick ins Hauptfenster holte den Fokus zurück. Deshalb der Weg, den
    /// auch der Finder geht: Pfeil hoch/runter blättern die Trefferansicht, ⎋
    /// schließt — egal, welches Fenster gerade die Tastatur hat. Den anderen
    /// Fall (das App-Fenster ist Tastaturfenster) deckt der Tastaturmonitor
    /// der jeweiligen App ab.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!)
        -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126:                                   // ↓ ↑
            activeResultView.keyDown(with: event)
            return true
        case 53 where plainModifiers(of: event).isEmpty: // ⎋
            closeOpenPreview()
            return true
        default:
            return false
        }
    }

    // ---------- Kontextmenü-Aktionen auf der wirksamen Zeilenmenge ----------

    /// Ein Doppelklick übernimmt auch -1 (unterhalb der letzten Zeile),
    /// damit dort die Auswahl statt einer alten Kontextmenüzeile zählt.
    @objc func openSelected() {
        contextRow = tableView.clickedRow
        openActionRows()
    }

    /// Schließt eine offene Quick-Look-Vorschau. Liefert false, wenn gar
    /// keine offen war — dann gehört ⎋ weiter dem Fenster (Suchfeld leeren,
    /// Blatt abbrechen), und in der Schnellsuche beendet erst ein leeres
    /// Suchfeld die App.
    ///
    /// Steht EINMAL hier: Die drei Zeilen standen in beiden
    /// Tastaturmonitoren und in `previewPanel(_:handle:)`.
    @discardableResult
    func closeOpenPreview() -> Bool {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return false }
        QLPreviewPanel.shared().orderOut(nil)
        return true
    }

    /// Die recycelte oder frisch gebaute Zelle einer Spalte.
    ///
    /// Steht EINMAL hier statt zweimal in den Apps: Bis 0.34.16 waren die
    /// 19 Zeilen in beiden `tableView(_:viewFor:row:)` wörtlich gleich.
    /// Die Prüfung der projizierten Trefferzeile gehört dazu und ist Pflicht, nicht
    /// Vorsicht: `applyHitsToTable` verkleinert `hits` VOR dem
    /// `reloadData()`, und NSTableView hält solange die alte Zeilenzahl.
    /// Fragt AppKit dann eine Zelle jenseits des Endes an, beendete sich
    /// die App mit „Index out of range" — die Schnellsuche hatte die
    /// Prüfung an dieser Stelle immer, die Haupt-App nicht.
    ///
    /// nil heißt: nichts anzuzeigen. Das Befüllen übernimmt die App;
    /// Finder-Spalten benutzen dabei den gemeinsamen Renderer.
    func hitCell(_ tableView: NSTableView, column: NSTableColumn,
                 row: Int) -> NSTableCellView? {
        guard hitIndex(forTableRow: row) != nil else { return nil }
        if let cell = tableView.makeView(withIdentifier: column.identifier,
                                         owner: nil) as? NSTableCellView {
            return cell
        }
        // Zellen einmal bauen, danach werden sie recycelt.
        let cell = column.identifier.rawValue == "finderTags" ? FinderTagsCellView() : NSTableCellView()
        cell.identifier = column.identifier
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingMiddle
        if ["finderTags", "finderComment"].contains(column.identifier.rawValue) {
            label.maximumNumberOfLines = 1
            (label.cell as? NSTextFieldCell)?.usesSingleLineMode = true
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(
                equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Baut das gemeinsame Datei-Kontextmenü für die geklickte Zeile.
    ///
    /// Steht EINMAL hier statt zweimal in den Apps: Bis 0.34.16 waren die
    /// beiden `menuNeedsUpdate` bis auf die zwei Zeilen der Haupt-App
    /// wörtlich gleich — samt der Bereichsprüfung der Kontextzeile,
    /// die vorher nur in der Schnellsuche stand. Was eine App zusätzlich
    /// anbietet, hängt sie hinter dem `true` selbst an.
    ///
    /// Liefert false, wenn der Klick keine Zeile traf; dann bleibt das Menü
    /// leer, und es darf auch nichts angehängt werden.
    @discardableResult
    func populateHitMenu(_ menu: NSMenu) -> Bool {
        menu.removeAllItems()
        contextRow = thumbnailController?.isGrid == true
            ? (thumbnailController?.contextTableRow ?? -1) : tableView.clickedRow
        guard hitIndex(forTableRow: contextRow) != nil else { return false }
        // ALLE öffnenbaren Treffer, nicht nur der erste: `ctxOpenWith`
        // übergibt später sämtliche materialisierten URLs an die gewählte App,
        // also muss das Menü über dieselbe Menge entscheiden.
        let applicationHits = actionRows().compactMap {
            hits.indices.contains($0) ? hits[$0] : nil
        }.filter { $0.hasOpenableFile }
        populateHitContextMenu(
            menu, applicationHits: applicationHits, target: self,
            selectors: HitContextMenuSelectors(
                preview: #selector(togglePreview), open: #selector(ctxOpen),
                openWith: #selector(ctxOpenWith(_:)),
                reveal: #selector(ctxReveal),
                copyPath: #selector(ctxCopyPath)))
        let archived = actionRows().map { hits[$0] }.filter { $0.isMember }
        if !archived.isEmpty {
            menu.addItem(withTitle: "Quellarchiv im Finder zeigen", action: #selector(ctxRevealSourceArchive),
                         keyEquivalent: "").target = self
            let chain = menu.addItem(withTitle: "Archivkette anzeigen…", action: #selector(ctxArchiveChain), keyEquivalent: "")
            chain.target = self
            chain.isEnabled = archived.count == 1 && actionRows().count == 1
        }
        return true
    }

    /// Das Kontextmenü behält die Zeile, für die es aufgebaut wurde.
    @objc func ctxOpen() { openActionRows() }

    @objc func ctxOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        withActionSelection { [weak self] selection in
            guard let self else { return }
            if !selection.urls.isEmpty {
                NSWorkspace.shared.open(
                    selection.urls, withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration())
            }
            self.showActionIssue(selection)
        }
    }

    @objc func ctxReveal() {
        // Für Archiv-Einträge zeigt das die ausgepackte Temp-Kopie —
        // das ist genau die Datei, die man beim Öffnen/Ziehen bekommt.
        withActionSelection { [weak self] selection in
            guard let self else { return }
            if !selection.urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(selection.urls)
            }
            self.showActionIssue(selection)
        }
    }

    @objc func ctxRevealSourceArchive() {
        let urls = sourceArchiveURLs(for: actionRows().map { hits[$0] })
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func ctxArchiveChain() {
        let selected = actionRows().map { hits[$0] }
        guard selected.count == 1, let hit = selected.first, hit.isMember else { return }
        let alert = makeArchiveChainAlert(for: hit)
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleFinderColumn(_:)):
            if let key = item.representedObject as? String, let column = tableView.tableColumn(withIdentifier: .init(key)) {
                item.state = column.isHidden ? .off : .on
                return true
            }
            return false
        case #selector(ctxArchiveChain):
            let rows = actionRows()
            return rows.count == 1 && hits[rows[0]].isMember
        case #selector(ctxRevealSourceArchive):
            return actionRows().contains { hits[$0].isMember }
        default: return true
        }
    }

    /// „Öffnen" auf der wirksamen Zeilenmenge — mit der Standard-App.
    func openActionRows() {
        withActionSelection { [weak self] selection in
            guard let self else { return }
            selection.urls.forEach { NSWorkspace.shared.open($0) }
            self.showActionIssue(selection)
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

// Nur ein ausdrücklich gestarteter UI-Prüflauf setzt eine prozesslokale
// Appearance. Globale Benutzereinstellungen bleiben dabei unberührt.
func applyUITestAppearance(_ app: NSApplication) {
    guard let requested = ProcessInfo.processInfo.environment["FAVENIO_TEST_APPEARANCE"],
          ["light", "dark"].contains(requested) else { return }
    app.appearance = NSAppearance(named: requested == "dark" ? .darkAqua : .aqua)
    let actual = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown"
    fputs("FAVENIO TEST APPEARANCE: \(actual)\n", stderr)
}

func resultFilterListSelfTest(_ owner: HitListController, terminate: () -> Void) -> String? {
    func wait(_ condition: () -> Bool) -> Bool {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    defer { owner.resultFilter.stopForTermination() }
    let first = Hit(path: "/missing/keep-a.txt", kind: "file", line: 7, size: 8,
        filesystemPath: "/missing/keep-a.txt", archiveMembers: [], isDirectory: false)
    let other = Hit(path: "/missing/other.txt", kind: "file", line: nil, size: nil,
        filesystemPath: "/missing/other.txt", archiveMembers: [], isDirectory: false)
    owner.replaceFilteredHits([first, other], keepingSelection: [first.identity])
    let filter = owner.resultFilter
    filter.criteria.applyJSON(CriteriaNode(field: "name", value: "keep-").json)
    filter.apply()
    guard wait({ !filter.isFiltering }), owner.hits == [first],
          owner.selectedHitIdentities() == [first.identity], filter.sourceCount == 2 else {
        return "Ansichtsfilter verliert Quellmenge, Belege oder Auswahl"
    }
    let incoming = Hit(path: "/missing/keep-stream.txt", kind: "file", line: 9, size: 10,
        filesystemPath: "/missing/keep-stream.txt", archiveMembers: [], isDirectory: false)
    owner.pending = [incoming]
    owner.flushResultFilterPending()
    guard wait({ !filter.isFiltering }), owner.hits.count == 2, filter.sourceCount == 3,
          owner.selectedHitIdentities() == [first.identity] else { return "Filter-Nachschub verändert Auswahl oder Quelle" }
    filter.reset()
    guard owner.hits.count == 3, !filter.isActive, owner.selectedHitIdentities() == [first.identity] else {
        return "Filterreset verliert Originaltreffer oder Auswahl"
    }
    filter.clearForSearch()
    let name = String(repeating: "a", count: 100) + "X.txt"
    let slow = Hit(path: "/missing/" + name, kind: "file", line: nil, size: 0,
        filesystemPath: "/missing/" + name, archiveMembers: [], isDirectory: false)
    owner.replaceFilteredHits([slow], keepingSelection: [])
    filter.criteria.applyJSON(CriteriaNode(field: "name", matchOperator: "regex", value: "(a+)+$").json)
    filter.apply()
    guard wait({ filter.runningProcessIdentifier != nil }), let pid = filter.runningProcessIdentifier else {
        return "Filter-Lifecycle-Gegenprobe startet keinen eigenen Prozess"
    }
    terminate()
    guard wait({ kill(pid, 0) != 0 }), !filter.isFiltering else { return "App-Ende lässt Filterprozess zurück" }
    return nil
}

func resultGroupingListSelfTest(_ owner: HitListController) -> String? {
    let a = Hit(path: "/missing/a/keep-first.txt", kind: "file", line: 7, size: 8,
        filesystemPath: "/missing/a/keep-first.txt", archiveMembers: [], isDirectory: false)
    let b = Hit(path: "/missing/b/other.md", kind: "file", line: nil, size: 9,
        filesystemPath: "/missing/b/other.md", archiveMembers: [], isDirectory: false)
    let c = Hit(path: "/missing/a/keep-last.txt", kind: "file", line: 11, size: 10,
        filesystemPath: "/missing/a/keep-last.txt", archiveMembers: [], isDirectory: false)
    let source = [a, b, c]
    owner.replaceFilteredHits(source, keepingSelection: [a.identity, b.identity])
    let groups = owner.resultGrouping
    defer {
        owner.resultFilter.stopForTermination()
        groups.setMode(.none)
        owner.resultFilter.clearForSearch()
        owner.replaceFilteredHits([], keepingSelection: [])
    }
    groups.setMode(.folder)
    guard owner.resultTableRowCount == 5, owner.selectedHitIdentities() == [a.identity, b.identity],
          owner.actionRows().count == 2 else { return "Ordnergruppen verlieren Auswahl oder Trefferabbildung" }
    guard let header = (0..<owner.resultTableRowCount).first(where: { groups.projection.group(at: $0) != nil }) else {
        return "Gruppenüberschrift fehlt"
    }
    owner.contextRow = header
    guard owner.actionRows().isEmpty, owner.hitCell(owner.tableView,
        column: owner.tableView.tableColumns[0], row: header) == nil else { return "Gruppenüberschrift wird als Datei behandelt" }
    owner.contextRow = -1
    groups.collapseAll()
    guard owner.hits.count == 3, groups.projection.displayedHitCount == 0,
          owner.selectedHitIdentities().isEmpty, owner.resultTableRowCount == 2 else {
        return "Einklappen verliert Treffer oder behält unsichtbare Auswahl"
    }
    let incoming = Hit(path: "/missing/a/keep-stream.txt", kind: "file", line: 13, size: 12,
        filesystemPath: "/missing/a/keep-stream.txt", archiveMembers: [], isDirectory: false)
    owner.appendFilteredHits([incoming], keepingSelection: [])
    guard owner.hits.count == 4, groups.projection.displayedHitCount == 0,
          let row = owner.revealTableRow(for: a.identity), owner.hitIndex(forTableRow: row).map({ owner.hits[$0].identity }) == a.identity else {
        return "Nachschub oder ausdrückliches Aufklappen verliert Gruppenidentität"
    }
    owner.tableView.selectRowIndexes([row], byExtendingSelection: false)
    groups.setMode(.fileExtension)
    guard owner.selectedHitIdentities() == [a.identity] else { return "Gruppierungswechsel wählt eine andere Datei" }
    groups.collapseAll()
    owner.resultFilter.criteria.applyJSON(CriteriaNode(field: "name", value: "keep-").json)
    owner.resultFilter.apply()
    let until = ProcessInfo.processInfo.systemUptime + 8
    while owner.resultFilter.isFiltering && ProcessInfo.processInfo.systemUptime < until {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard !owner.resultFilter.isFiltering, owner.resultFilter.errorMessage == nil,
          owner.hits.count == 3, owner.resultFilter.sourceCount == 4,
          groups.projection.displayedHitCount == 0 else { return "Ansichtsfilter und Klappzustand verlieren Quellmenge oder Darstellung" }
    owner.resultFilter.reset()
    groups.expandAll()
    guard owner.hits.count == 4, groups.projection.displayedHitCount == 4 else {
        return "Filterreset/Aufklappen verliert Originaltreffer"
    }
    groups.collapseAll()
    owner.resultFilter.clearForSearch()
    owner.replaceFilteredHits(source, keepingSelection: [])
    guard groups.projection.displayedHitCount == 3 else { return "Neue Suche behält alte eingeklappte Gruppen" }
    let archived = Hit(path: "/missing/outer!/source.zip!/folder!/a.txt", kind: "member", line: nil, size: 1,
        filesystemPath: "/missing/outer!/source.zip", archiveMembers: ["folder!/a.txt"], isDirectory: false)
    owner.replaceFilteredHits([a, archived], keepingSelection: [a.identity, archived.identity])
    let menu = NSMenu()
    let chain = menu.addItem(withTitle: "Archivkette anzeigen…", action: #selector(HitListController.ctxArchiveChain), keyEquivalent: "")
    chain.target = owner
    menu.update()
    guard !chain.isEnabled else { return "Menüautomatik aktiviert Archivkette für mehrere Treffer" }
    owner.tableView.selectRowIndexes(owner.tableRows(for: [archived.identity]), byExtendingSelection: false)
    menu.update()
    guard chain.isEnabled,
          sourceArchiveURLs(for: [a, archived, archived]).map({ $0.path }) == [archived.filesystemPath],
          archiveChainText(for: archived).contains("Treffer: folder!/a.txt") else {
        return "Archivketten-Menü oder Quellarchiv verwendet falsche Identität"
    }
    if let scroll = owner.tableView.enclosingScrollView {
        let long = String(repeating: "long-", count: 100)
        let layoutHits = (0..<20).map { index in
            Hit(path: "/missing/group-\(index)-\(long)/a.txt", kind: "file", line: nil, size: 1,
                filesystemPath: "/missing/group-\(index)-\(long)/a.txt", archiveMembers: [], isDirectory: false)
        }
        owner.replaceFilteredHits(layoutHits, keepingSelection: [])
        groups.setMode(.folder)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let row = owner.tableView.rowView(atRow: 0, makeIfNecessary: true),
              let header = descendants(row).first(where: { $0 is ResultGroupHeaderView }),
              let count = descendants(header).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "1 Treffer" }),
              let scroller = scroll.verticalScroller else { return "Native Gruppen-Geometrie fehlt" }
        func headerFits() -> Bool {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            header.layoutSubtreeIfNeeded()
            let frame = count.convert(count.bounds, to: owner.tableView)
            let right = min(owner.tableView.visibleRect.maxX, scroller.convert(scroller.bounds, to: owner.tableView).minX)
            return frame.minX >= owner.tableView.visibleRect.minX && abs(frame.maxX - right) < 1
        }
        guard headerFits() else {
            return "Gruppentrefferzahl liegt außerhalb des freien nativen Tabellenbereichs"
        }
        scroll.contentView.scroll(to: NSPoint(x: 100, y: scroll.contentView.bounds.minY))
        guard scroll.contentView.bounds.minX == 100, headerFits() else {
            return "Native Gruppenzeile verliert ihre Ausrichtung nach Scrollen und Ereignisschleife"
        }
        print("RESULT GROUP HEADER OK: native window, scroller, scroll and count geometry")
    }
    return nil
}

func finderColumnsSelfTest(_ owner: HitListController) -> String? {
    let keys = ["finderTags", "finderComment"]
    let saved = keys.map { ($0, UserDefaults.standard.object(forKey: "finderColumn." + $0)) }
    let hidden = keys.map { owner.tableView.tableColumn(withIdentifier: .init($0))?.isHidden }
    let callback = owner.onFinderColumnsShown
    var shown = 0
    owner.onFinderColumnsShown = { shown += 1; callback?() }
    defer {
        owner.onFinderColumnsShown = callback
        for (index, key) in keys.enumerated() {
            if let value = saved[index].1 { UserDefaults.standard.set(value, forKey: "finderColumn." + key) }
            else { UserDefaults.standard.removeObject(forKey: "finderColumn." + key) }
            if let value = hidden[index] { owner.tableView.tableColumn(withIdentifier: .init(key))?.isHidden = value }
        }
    }
    guard let menu = owner.tableView.headerView?.menu else { return "Finder-Spaltenmenü fehlt" }
    for key in keys {
        guard let column = owner.tableView.tableColumn(withIdentifier: .init(key)),
              let index = menu.items.firstIndex(where: { $0.representedObject as? String == key }) else { return "Finder-Spalteneintrag fehlt: " + key }
        column.isHidden = true
        menu.update()
        guard menu.items[index].isEnabled, menu.items[index].state == .off else { return "Versteckte Finder-Spalte hat falschen Menüzustand" }
        menu.performActionForItem(at: index)
        menu.update()
        guard !column.isHidden, menu.items[index].state == .on,
              UserDefaults.standard.bool(forKey: "finderColumn." + key) else { return "Native Menüaktion blendet Finder-Spalte nicht ein: " + key }
        menu.performActionForItem(at: index)
        menu.update()
        guard column.isHidden, menu.items[index].state == .off,
              !UserDefaults.standard.bool(forKey: "finderColumn." + key) else { return "Native Menüaktion blendet Finder-Spalte nicht aus: " + key }
    }
    guard shown == 2 else { return "Finder-Spalten aktivieren die Erfassung nicht genau beim Einblenden" }
    print("FINDER COLUMNS OK: native NSMenu actions, checkmarks, visibility, capture callback")
    return nil
}
