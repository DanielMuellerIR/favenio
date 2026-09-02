// Gemeinsamer Unterbau für Favenio.app (große GUI) und FavenioQuick.app
// (Schnellsuche für die Finder-Toolbar).
//
// Wichtigstes Prinzip: Der eigentliche Suchmotor ist und bleibt favenio.py.
// Die Swift-Apps sind nur Frontends — sie starten den Python-Kern als
// Unterprozess und lesen dessen JSONL-Ausgabe (--json). So gibt es genau
// EINE Suchlogik, die auch headless (CLI, AI-Agenten) identisch arbeitet.

import AppKit
import Darwin
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
struct Hit: Hashable {
    let path: String   // menschenlesbarer Pfad; kann !/-Notation enthalten
    let kind: String   // "file", "dir" oder "member" (= im Archiv)
    let line: Int?     // Zeilennummer bei Inhaltssuche, sonst nil
    let size: Int?     // Dateigröße in Bytes; bei Ordnern nil
    let filesystemPath: String
    let archiveMembers: [String]
    /// Ist der Treffer ein Verzeichnis? Der `kind` allein genügt dafür nicht:
    /// Ein Ordner INNERHALB eines Archivs kommt als `member` an und sah damit
    /// aus wie eine Datei (Review-Fund 2026-08-17). Der Kern schickt das
    /// Merkmal jetzt als `isDirectory` mit.
    let isDirectory: Bool
    /// Metadatensuche: das Feld und der Wert, in dem das Muster stand
    /// (`Keywords` / `Winter`). Nur bei `--metadata`-Treffern gesetzt.
    var field: String? = nil
    var value: String? = nil
    /// Pixelmaße, wenn ein Maßfilter sie ermittelt hat; sonst nil.
    var width: Int? = nil
    var height: Int? = nil

    /// Liegt der Treffer INNERHALB eines Archivs?
    var isMember: Bool { !archiveMembers.isEmpty }

    /// Gibt es hinter dem Treffer überhaupt eine Datei, die man öffnen,
    /// anzeigen oder vorschauen kann?
    ///
    /// Für einen ORDNER im Archiv nicht: Er hat keinen Inhalt zum
    /// Herausschreiben, `materializeHit()` liefert deshalb nil. Ein Ordner im
    /// Dateisystem hat dagegen sehr wohl einen Pfad, den der Finder öffnet.
    /// Die Oberflächen fragen hier, statt die Bedingung nachzubauen.
    var hasOpenableFile: Bool { !(isMember && isDirectory) }

    /// Die Spalte „Fundstelle": Zeilennummer bei Inhaltstreffern,
    /// „Feld: Wert" bei Metadatentreffern, sonst leer.
    var locationText: String {
        if let field, let value { return field + ": " + value }
        return line.map { String($0) } ?? ""
    }

    /// Die Spalte „Maße": „1200×800" oder leer.
    var dimensionsText: String {
        guard let width, let height else { return "" }
        return "\(width)×\(height)"
    }

    /// Fläche in Pixeln — die Größe, nach der die Maß-Spalte sortiert.
    /// Gedeckelt statt fangend: Ein beschädigter oder präparierter Bildkopf
    /// kann sehr große Kanten melden, und `width * height` beendet in Swift
    /// bei Überlauf den ganzen Prozess. Der Kern lehnt solche Köpfe seit
    /// 0.26.1 ab; die Sortierung darf sich darauf trotzdem nicht verlassen,
    /// weil die Zahlen aus einem fremden Prozess kommen.
    var pixelArea: Int? {
        guard let width, let height else { return nil }
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow ? Int.max : product
    }

    /// Nur der Dateiname (letzte Komponente), für die Namensspalte.
    var displayName: String {
        let lastSegment = archiveMembers.last ?? filesystemPath
        return (lastSegment as NSString).lastPathComponent
    }

    /// Menschlicher Dateityp für die Typ-Spalte: „Ordner" bei Verzeichnissen,
    /// sonst die lokalisierte Typbeschreibung der Endung (z. B. „PDF-Dokument"),
    /// ersatzweise die Endung groß bzw. „Datei" ohne Endung.
    var typeDescription: String {
        if isDirectory { return "Ordner" }
        let ext = (displayName as NSString).pathExtension
        if ext.isEmpty { return "Datei" }
        if let type = UTType(filenameExtension: ext.lowercased()),
           let description = type.localizedDescription {
            return description
        }
        return ext.uppercased()
    }
}

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
}

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
    // Reihenfolge, in der die Meldung die Gruppen aufzählt.
    let firstPath = (archiveFolders.first ?? extractionFailures.first)?.path
    return (parts.joined(separator: " "), firstPath)
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
func commonApplicationsFor(_ hits: [Hit]) -> [URL] {
    guard let first = hits.first else { return [] }
    var common = applicationsFor(first)
    var byExtension: [String: Set<URL>] = [:]
    func extensionKey(_ hit: Hit) -> String? {
        let ext = (hit.displayName as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
    if let key = extensionKey(first) {
        byExtension[key] = Set(common.map { $0.standardizedFileURL })
    }
    for hit in hits.dropFirst() {
        if common.isEmpty { break }
        let allowed: Set<URL>
        if let key = extensionKey(hit), let cached = byExtension[key] {
            allowed = cached
        } else {
            allowed = Set(applicationsFor(hit).map { $0.standardizedFileURL })
            if let key = extensionKey(hit) { byExtension[key] = allowed }
        }
        common = common.filter { allowed.contains($0.standardizedFileURL) }
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
private func compareOptionalNumbers(_ lhs: Int?, _ rhs: Int?)
    -> ComparisonResult {
    let left = lhs ?? -1
    let right = rhs ?? -1
    if left < right { return .orderedAscending }
    if left > right { return .orderedDescending }
    return .orderedSame
}

/// Gemeinsame, strikte Sortierordnung für beide Trefferlisten. Der feste
/// Pfad-Tie-Breaker verhindert, dass zwei verschiedene Treffer einander in
/// beiden Richtungen als „kleiner“ ansehen.
func compareHits(_ lhs: Hit, _ rhs: Hit, key: String,
                 ascending: Bool) -> Bool {
    let primary: ComparisonResult
    switch key {
    case "size":
        primary = compareOptionalNumbers(lhs.size, rhs.size)
    case "type":
        primary = lhs.typeDescription.localizedCaseInsensitiveCompare(
            rhs.typeDescription)
    case "line":
        primary = compareOptionalNumbers(lhs.line, rhs.line)
    case "dims":
        // Nach Fläche: Das ist die Frage, die man an Bildmaße stellt.
        primary = compareOptionalNumbers(lhs.pixelArea, rhs.pixelArea)
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
    let pathOrder = lhs.path.localizedCaseInsensitiveCompare(rhs.path)
    if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
    return compareOptionalNumbers(lhs.line, rhs.line) == .orderedAscending
}

/// Findet den Python-Kern: zuerst im App-Bundle (Resources), sonst im
/// Arbeitsverzeichnis (Entwicklungs-Fallback beim Direktstart des Binarys).
func findCLI() -> String? {
    if let bundled = Bundle.main.path(forResource: "favenio", ofType: "py") {
        return bundled
    }
    let local = FileManager.default.currentDirectoryPath + "/favenio.py"
    if FileManager.default.fileExists(atPath: local) { return local }
    return nil
}

/// Übersetzt EINE JSONL-Zeile der Suche in einen Hit (oder nil bei Müll).
/// Fortschritts-Zeilen (type=progress, von --progress) sind KEINE Treffer
/// und werden hier bewusst verworfen — dafür gibt es parseProgress().
func parseHit(_ lineData: Data) -> Hit? {
    guard
        let object = try? JSONSerialization.jsonObject(with: lineData),
        let dict = object as? [String: Any],
        let path = dict["path"] as? String,
        let kind = dict["type"] as? String,
        kind != "progress"
    else { return nil }
    let filesystemPath = dict["filesystemPath"] as? String
        ?? (kind == "member"
            ? path.components(separatedBy: "!/").first ?? path
            : path)
    let archiveMembers = dict["archiveMembers"] as? [String]
        ?? (kind == "member"
            ? Array(path.components(separatedBy: "!/").dropFirst())
            : [])
    // Ältere Kern-Ausgaben kennen `isDirectory` nicht; dort bleibt der
    // Rückfall auf den Typ, der wenigstens Dateisystem-Ordner richtig erkennt.
    let isDirectory = dict["isDirectory"] as? Bool ?? (kind == "dir")
    return Hit(path: path, kind: kind, line: dict["line"] as? Int,
               size: dict["size"] as? Int,
               filesystemPath: filesystemPath,
               archiveMembers: archiveMembers,
               isDirectory: isDirectory,
               field: dict["field"] as? String,
               value: dict["value"] as? String,
               width: dict["width"] as? Int,
               height: dict["height"] as? Int)
}

/// Übersetzt eine JSONL-Zeile in einen Fortschritts-Pfad (der Ordner bzw.
/// das Archiv, das der Kern gerade durchsucht) — nil für alles andere.
func parseProgress(_ lineData: Data) -> String? {
    guard
        let object = try? JSONSerialization.jsonObject(with: lineData),
        let dict = object as? [String: Any],
        dict["type"] as? String == "progress",
        let path = dict["path"] as? String
    else { return nil }
    return path
}

/// Baut die Argumentliste für einen Suchlauf des Python-Kerns.
/// nil, wenn favenio.py nicht auffindbar ist.
/// `only` begrenzt Treffer auf einen Typ: "both" (Dateien & Ordner),
/// "files" oder "dirs" — für den Drei-Wege-Umschalter der großen GUI.
/// Pixel-Grenzen eines Suchlaufs (Breite/Höhe je von/bis). nil = keine
/// Grenze. Die Oberflächen füllen sie aus vier Textfeldern; leer heißt
/// „egal".
struct PixelLimits: Equatable {
    var minWidth: Int? = nil
    var maxWidth: Int? = nil
    var minHeight: Int? = nil
    var maxHeight: Int? = nil

    var isEmpty: Bool {
        minWidth == nil && maxWidth == nil && minHeight == nil
            && maxHeight == nil
    }

    /// Die CLI-Optionen in fester Reihenfolge.
    var arguments: [String] {
        var args: [String] = []
        if let minWidth { args += ["--min-width", String(minWidth)] }
        if let maxWidth { args += ["--max-width", String(maxWidth)] }
        if let minHeight { args += ["--min-height", String(minHeight)] }
        if let maxHeight { args += ["--max-height", String(maxHeight)] }
        return args
    }

    /// Beschreibung für Statuszeilen: „B ≥ 1000, H 500–800".
    var summary: String {
        func span(_ label: String, _ low: Int?, _ high: Int?) -> String? {
            switch (low, high) {
            case (nil, nil): return nil
            case (let low?, nil): return "\(label) ≥ \(low)"
            case (nil, let high?): return "\(label) ≤ \(high)"
            case (let low?, let high?): return "\(label) \(low)–\(high)"
            }
        }
        return [span("B", minWidth, maxWidth),
                span("H", minHeight, maxHeight)]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Ein Pixel-Textfeld lesen: leer oder unbrauchbar → nil, sonst die Zahl.
/// „1.000" und „1000 px" gelten als 1000 — man tippt so etwas.
///
/// Erlaubt ist genau eine positive Ganzzahl, wahlweise in Dreierblöcken
/// gruppiert (Punkt, Komma, Apostroph oder Leerzeichen als Trenner) und mit
/// angehängtem „px". Alles andere verwirft die Grenze, statt sie
/// stillschweigend umzudeuten: Der frühere Weg strich einfach alle
/// Nicht-Ziffern und machte damit aus „-1" eine 1 und aus „10.5" eine 105 —
/// eine Suchgrenze, die der Nutzer nirgends hingeschrieben hat. Die
/// Dreierblöcke sind das, was Tausendertrenner von Dezimalstellen
/// unterscheidbar macht.
func parsePixelLimit(_ text: String) -> Int? {
    var rest = text.trimmingCharacters(in: .whitespaces).lowercased()
    if rest.hasSuffix("px") {
        rest = String(rest.dropLast(2))
            .trimmingCharacters(in: .whitespaces)
    }
    guard !rest.isEmpty else { return nil }
    // Schmale und geschützte Leerzeichen kommen aus Kopiervorgängen.
    let separators: Set<Character> = [".", ",", "'", "\u{2019}", " ",
                                      "\u{00a0}", "\u{202f}", "\u{2009}"]
    var groups = [""]
    for character in rest {
        if separators.contains(character) {
            groups.append("")
        } else if character.isASCII, character.isNumber {
            groups[groups.count - 1].append(character)
        } else {
            return nil
        }
    }
    if groups.count > 1 {
        // "1.000" ist 1000, "10.5" ist keine Ganzzahl.
        guard (1...3).contains(groups[0].count) else { return nil }
        for group in groups.dropFirst() where group.count != 3 { return nil }
    }
    guard let value = Int(groups.joined()), value > 0 else { return nil }
    return value
}

/// Wie das Suchmuster gelesen wird: gegen Namen, Inhalt oder Metadaten.
enum SearchTextMode: String, CaseIterable {
    case name, content, metadata

    var title: String {
        switch self {
        case .name: return "Name"
        case .content: return "Inhalt"
        case .metadata: return "Metadaten"
        }
    }
}

/// Die kuratierte Feldliste der Metadatensuche — vom Kern erfragt
/// (`--list-metadata-fields`), nicht in Swift nachgebaut. Einmal je
/// Prozess; leer, wenn der Kern nicht erreichbar ist.
private var cachedMetadataFields: [String]?
func metadataFieldList() -> [String] {
    if let cachedMetadataFields { return cachedMetadataFields }
    var fields: [String] = []
    if let cli = findCLI() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [cli, "--list-metadata-fields"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let raw = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            fields = String(decoding: raw, as: UTF8.self)
                .split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty }
        }
    }
    cachedMetadataFields = fields
    return fields
}

func searchArguments(pattern: String, root: String, content: Bool,
                     regex: Bool, caseSensitive: Bool,
                     archives: Bool, progress: Bool = false,
                     only: String = "both",
                     includeHidden: Bool = false,
                     exact: Bool = false,
                     metadata: Bool = false,
                     metadataField: String? = nil,
                     pixelLimits: PixelLimits = PixelLimits()) -> [String]? {
    guard let cli = findCLI() else { return nil }
    // Eine Suche braucht mindestens ein Muster oder einen Maßfilter.
    let hasPattern = !pattern.isEmpty
    guard hasPattern || !pixelLimits.isEmpty else { return nil }
    var args = ["-u", cli, "--json"]   // -u = ungepuffert → Treffer streamen
    // Nur nach Maßen suchen: Ohne Muster läuft die Suche ganz ohne
    // Textkriterium. --content und --metadata sagen, WOGEGEN das Muster
    // läuft, und lehnt der Kern ohne Muster deshalb ab.
    if content && hasPattern { args.append("--content") }
    if metadata && hasPattern { args.append("--metadata") }
    if let metadataField, !metadataField.isEmpty, hasPattern {
        args += ["--metadata-field", metadataField]
    }
    args += pixelLimits.arguments
    if regex { args.append("--regex") }
    if caseSensitive { args.append("--case-sensitive") }
    if exact { args.append("--exact") }
    if !archives { args.append("--no-archives") }
    if only != "both" { args.append(contentsOf: ["--only", only]) }
    if includeHidden { args.append("--hidden") }
    if progress { args.append("--progress") }
    args.append("--")   // ab hier nur noch Positionsargumente (Muster darf
    if hasPattern { args.append(pattern) }  // sonst mit "-" beginnen und
    args.append(root)                       // argparse verwirren)
    return args
}

/// Vollständiges Ende eines Suchprozesses. `status` allein reicht nicht:
/// Foundation meldet bei einem Signal dessen Nummer, sodass etwa SIGHUP und
/// der reguläre grep-Status „keine Treffer" beide den Zahlenwert 1 tragen.
struct SearchExit {
    let status: Int32
    let reason: Process.TerminationReason
}

/// grep-Semantik des Python-Kerns: Nur ein REGULÄRER Exit 0 (Treffer) oder 1
/// (keine Treffer) ist normal. Ein Signal ist unabhängig von seiner Nummer ein
/// Fehler und muss in beiden Frontends sichtbar werden.
func searchExitIsError(_ status: Int32,
                       reason: Process.TerminationReason) -> Bool {
    reason != .exit || (status != 0 && status != 1)
}

/// Führt eine Suche BLOCKIEREND aus und liefert Treffer.
///
/// Nur für den Headless-Selbsttest. Beide Oberflächen streamen stattdessen
/// über `runSearchStreaming` — die Schnellsuche seit ihrer Live-Trefferliste
/// ebenfalls. Diese Fassung verwirft nämlich das Prozessende: Ein Fehler
/// (Exit 2) und ein Signalabbruch kommen hier genauso an wie „keine Treffer".
/// Genau das musste in beiden Frontends behoben werden; ein sichtbarer
/// Suchlauf gehört deshalb nicht auf diesen Weg zurück.
func runSearchSync(arguments: [String]) -> [Hit] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var hits: [Hit] = []
    for lineData in raw.split(separator: 0x0A) {   // 0x0A = "\n"
        if let hit = parseHit(Data(lineData)) { hits.append(hit) }
    }
    return hits
}

/// Wie runSearchSync, liest die Ausgabe aber ZEILENWEISE, während die
/// Suche läuft: Fortschritts-Zeilen (--progress) werden sofort über den
/// Callback gemeldet (auf dem Main-Thread). Treffer werden ausschließlich
/// über `onHit` weitergereicht; der Kern legt keine redundante zweite Kopie an.
/// Blockiert bis zum Ende der Suche; im Hintergrund-Thread aufrufen.
///
/// `register` bekommt (falls gesetzt) den gestarteten Prozess durchgereicht,
/// damit der Aufrufer ihn abbrechen kann (`process.terminate()`) — z. B. die
/// Schnellsuche, wenn der Nutzer weitertippt. Nach dem Abbruch bricht die
/// Lese-Schleife ab (die Pipe schließt) und die Funktion kehrt zurück; der
/// Ergebnis trägt dann Status UND Signalgrund — der Aufrufer verwirft das
/// veraltete Ergebnis ohnehin über seinen Generations-Zähler.
///
/// `onHit` (falls gesetzt) meldet JEDEN Treffer sofort auf dem Main-Thread —
/// so kann die Schnellsuche ihre Trefferliste live wachsen lassen, statt bis
/// zum Ende zu warten.
func runSearchStreaming(arguments: [String],
                        register: ((Process) -> Void)? = nil,
                        onHit: ((Hit) -> Void)? = nil,
                        onProgress: @escaping (String) -> Void)
    -> SearchExit {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        return SearchExit(status: 2, reason: .exit)
    }
    register?(process)   // Aufrufer kann den Lauf ab jetzt abbrechen

    var buffer = Data()    // noch unvollständige Zeile vom Pipe-Ende

    func handleLine(_ lineData: Data) {
        if lineData.isEmpty { return }
        if let path = parseProgress(lineData) {
            DispatchQueue.main.async { onProgress(path) }
        } else if let hit = parseHit(lineData) {
            if let onHit { DispatchQueue.main.async { onHit(hit) } }
        }
    }

    let handle = pipe.fileHandleForReading
    while true {
        let chunk = handle.availableData   // blockiert; leer = Pipe zu
        if chunk.isEmpty { break }
        buffer.append(chunk)
        // Alle vollständigen Zeilen aus dem Puffer abarbeiten.
        while let newline = buffer.firstIndex(of: 0x0A) {
            handleLine(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }
    handleLine(buffer)   // letzte Zeile, falls ohne Zeilenumbruch
    process.waitUntilExit()
    return SearchExit(status: process.terminationStatus,
                      reason: process.terminationReason)
}

/// Appweiter Cache: jede Aktion auf denselben Archivtreffer verwendet dieselbe
/// materialisierte Datei. Alle Kopien liegen unter einem eindeutigen Root und
/// werden beim App-Ende gemeinsam entfernt.
final class MaterializationManager {
    static let shared = MaterializationManager()
    private var cache: [Hit: URL] = [:]
    private var root: URL?

    private func materializationRoot() -> URL? {
        if let root { return root }
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("Favenio-\(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: candidate, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            root = candidate
            return candidate
        } catch {
            return nil
        }
    }

    /// Bewusst synchron: Öffnen, Quick Look und besonders Drag-and-drop
    /// brauchen in ihren AppKit-Callbacks sofort die fertige URL. Der
    /// Python-Kern begrenzt die dabei entpackten Daten durch Mitglieds- und
    /// Gesamtbudget. Ein Wechsel auf Task.detached müsste deshalb zuerst die
    /// Aktionsschnittstellen beider Frontends asynchron machen.
    func materialize(_ hit: Hit) -> URL? {
        if !hit.isMember {
            return URL(fileURLWithPath: hit.filesystemPath)
        }
        // Ein ORDNER im Archiv hat keinen Inhalt zum Herausschreiben: Bei ZIP
        // entstand dabei eine leere Datei, bei TAR scheiterte die Extraktion
        // (Review-Fund 2026-08-17). Dateiaktionen gibt es dafür deshalb nicht;
        // sichtbar bleibt der Treffer trotzdem.
        if hit.isDirectory {
            return nil
        }
        if let cached = cache[hit],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let cli = findCLI(), let root = materializationRoot() else {
            return nil
        }
        let object: [String: Any] = [
            "filesystemPath": hit.filesystemPath,
            "archiveMembers": hit.archiveMembers,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              let jsonText = String(data: json, encoding: .utf8) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [cli, "--extract-json", jsonText,
                             "--extract-root", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        let url = URL(fileURLWithPath: output)
        cache[hit] = url
        return url
    }

    func cleanup() {
        cache.removeAll()
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
        self.root = nil
    }
}

func materializeHit(_ hit: Hit) -> URL? {
    MaterializationManager.shared.materialize(hit)
}

func cleanupMaterializedHits() {
    MaterializationManager.shared.cleanup()
}

/// Serialisiert Treffer zu JSONL (eine Zeile pro Treffer), im selben Format,
/// das `parseHit` wieder liest. Damit reicht die Schnellsuche ihre schon
/// gefundenen Treffer als Datei an die große GUI weiter, ohne den
/// (abgebrochenen) Suchlauf-Rohstrom zu brauchen.
func jsonlData(for hits: [Hit]) -> Data {
    var data = Data()
    for hit in hits {
        var object: [String: Any] = ["path": hit.path, "type": hit.kind,
                                     "isDirectory": hit.isDirectory]
        object["filesystemPath"] = hit.filesystemPath
        object["archiveMembers"] = hit.archiveMembers
        if let line = hit.line { object["line"] = line }
        if let size = hit.size { object["size"] = size }
        if let field = hit.field, let value = hit.value {
            object["field"] = field
            object["value"] = value
        }
        if let width = hit.width, let height = hit.height {
            object["width"] = width
            object["height"] = height
        }
        if let encoded = try? JSONSerialization.data(withJSONObject: object) {
            data.append(encoded)
            data.append(0x0A)
        }
    }
    return data
}

let quickHandoffPrefix = "favenio-quick-"
let quickHandoffSuffix = ".jsonl"
let maximumHandoffBytes = 8 * 1024 * 1024
let maximumHandoffLineBytes = 1024 * 1024

/// Schreibt die Quick→Haupt-App-Übergabe atomar und nur für den Besitzer.
func writeQuickHandoff(_ hits: [Hit]) throws -> URL {
    let data = jsonlData(for: hits)
    guard data.count <= maximumHandoffBytes else {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        quickHandoffPrefix + UUID().uuidString + quickHandoffSuffix)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

/// Akzeptiert nur eigene reguläre Dateien direkt im System-Temp-Ordner.
func validatedQuickHandoff(_ candidate: URL) -> URL? {
    let url = candidate.standardizedFileURL
    let temporary = FileManager.default.temporaryDirectory
        .standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent().resolvingSymlinksInPath()
            == temporary,
          url.lastPathComponent.hasPrefix(quickHandoffPrefix),
          url.lastPathComponent.hasSuffix(quickHandoffSuffix),
          let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let size = values.fileSize,
          size <= maximumHandoffBytes,
          let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path),
          let owner = attributes[.ownerAccountID] as? NSNumber,
          owner.uint32Value == getuid() else {
        return nil
    }
    return url
}

/// Liest begrenzt und zeilenweise; eine validierte Übergabedatei wird bei
/// Erfolg wie Fehler exakt einmal verbraucht und anschließend gelöscht.
func consumeQuickHandoff(_ candidate: URL) -> [Hit]? {
    guard let url = validatedQuickHandoff(candidate) else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var total = 0
    var buffer = Data()
    var hits: [Hit] = []
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumHandoffBytes else { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.count <= maximumHandoffLineBytes,
                      let hit = parseHit(line) else { return nil }
                hits.append(hit)
            }
            guard buffer.count <= maximumHandoffLineBytes else { return nil }
        }
    } catch {
        return nil
    }
    if !buffer.isEmpty {
        guard let hit = parseHit(buffer) else { return nil }
        hits.append(hit)
    }
    return hits
}

/// Apps, die einen Treffer öffnen können — für das „Öffnen mit"-Menü.
/// Bei normalen Dateien direkt über die URL, bei Archiv-Einträgen über den
/// Dateityp (Endung), damit fürs bloße Menü noch nichts ausgepackt wird.
/// Nach Namen sortiert, Doppelte entfernt.
func applicationsFor(_ hit: Hit) -> [URL] {
    var urls: [URL] = []
    if hit.isMember {
        let ext = (hit.displayName as NSString).pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext.lowercased()) {
            urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
    } else {
        urls = NSWorkspace.shared.urlsForApplications(
            toOpen: URL(fileURLWithPath: hit.path))
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
func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

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
enum HitExportFormat: String, CaseIterable {
    case paths
    case pathsNUL
    case jsonl
    case csv

    /// Beschriftung im Format-Aufklappmenü des Sichern-Dialogs.
    var title: String {
        switch self {
        case .paths:
            return "Pfade — eine Zeile pro Treffer (.txt)"
        case .pathsNUL:
            return "Pfade — NUL-getrennt für xargs -0 (.txt)"
        case .jsonl:
            return "JSON Lines — ein Objekt pro Treffer (.jsonl)"
        case .csv:
            return "CSV — für Tabellenkalkulation (.csv)"
        }
    }

    var fileExtension: String {
        switch self {
        case .paths, .pathsNUL: return "txt"
        case .jsonl: return "jsonl"
        case .csv: return "csv"
        }
    }
}

/// Ein CSV-Feld nach RFC 4180: Anführungszeichen nur, wo sie nötig sind, und
/// ein enthaltenes Anführungszeichen wird verdoppelt.
func csvField(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n"
                                    || $0 == "\r" }) else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

/// Serialisiert die Trefferliste in das gewählte Exportformat.
///
/// Für die beiden Pfadformate steht dort derselbe Pfad, den auch „Pfad
/// kopieren" liefert: bei einer normalen Datei ihr POSIX-Pfad, bei einem
/// Archiv-Eintrag der Pfad in `!/`-Notation, den `favenio.py --extract`
/// wieder versteht. Ein Archiv-Eintrag hat keinen eigenen POSIX-Pfad; ihn
/// stillschweigend wegzulassen wäre schlimmer, als ihn kenntlich zu machen.
func exportData(for hits: [Hit], format: HitExportFormat) -> Data {
    switch format {
    case .paths:
        return Data(hits.map { $0.path + "\n" }.joined().utf8)
    case .pathsNUL:
        return Data(hits.map { $0.path + "\0" }.joined().utf8)
    case .jsonl:
        return jsonlData(for: hits)
    case .csv:
        var text = "path,type,isDirectory,size,line,filesystemPath,"
            + "field,value,width,height\n"
        for hit in hits {
            // In Teilschritten: Ein Array-Literal mit zehn gemischten
            // Ausdrücken bringt den Typprüfer an seine Zeitgrenze.
            var cells: [String] = [csvField(hit.path), csvField(hit.kind)]
            cells.append(hit.isDirectory ? "true" : "false")
            cells.append(hit.size.map { String($0) } ?? "")
            cells.append(hit.line.map { String($0) } ?? "")
            cells.append(csvField(hit.filesystemPath))
            cells.append(csvField(hit.field ?? ""))
            cells.append(csvField(hit.value ?? ""))
            cells.append(hit.width.map { String($0) } ?? "")
            cells.append(hit.height.map { String($0) } ?? "")
            text += cells.joined(separator: ",")
            text += "\n"
        }
        // BOM voran: Ohne sie liest Excel eine UTF-8-Tabelle unter macOS als
        // Latin-1 und zerlegt jeden Umlaut im Dateinamen.
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
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
