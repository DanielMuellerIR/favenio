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
    /// Änderungs- und Erstellungszeit als Unix-Zeit (Sekunden seit 1970),
    /// wie der Kern sie aus `stat` bzw. dem Archivkatalog liest. Beide
    /// optional: Ein Zip- oder Tar-Eintrag kennt nur die Änderungszeit,
    /// ein bsdtar-Eintrag keine von beiden.
    var modified: Double? = nil
    var created: Double? = nil

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

    /// Der ORDNER, in dem der Treffer liegt — ohne den Dateinamen, den die
    /// Namensspalte schon zeigt. Bei einem Archiv-Eintrag in `!/`-Notation
    /// bis zum Ordner im Archiv (`a.zip!/docs`), bei einem Eintrag direkt in
    /// der Archivwurzel das Archiv selbst (`a.zip`).
    ///
    /// Aus den STRUKTURIERTEN Feldern gebaut, nicht aus `path` geschnitten:
    /// Ein Eintragsname darf selbst `!/` enthalten, und nur die Eintragsliste
    /// sagt, wo das Archiv aufhört und der Ordner darin anfängt.
    var folderPath: String {
        guard let last = archiveMembers.last else {
            return (filesystemPath as NSString).deletingLastPathComponent
        }
        var folder = ([filesystemPath] + archiveMembers.dropLast())
            .joined(separator: "!/")
        let inner = (last as NSString).deletingLastPathComponent
        if !inner.isEmpty { folder += "!/" + inner }
        return folder
    }

    /// Die Spalte „Pfad": `folderPath` relativ zum durchsuchten Ordner.
    /// Ein Treffer direkt im Suchordner hat einen leeren Pfad; ein Treffer
    /// außerhalb (anderer Startpfad, Übergabe aus der Schnellsuche mit
    /// anderem Ordner) behält seinen vollen Pfad, statt einen falschen
    /// relativen zu erfinden.
    func folderText(relativeTo root: String) -> String {
        let folder = folderPath
        var base = root
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        if base == "/" {
            return folder == "/" ? "" : String(folder.dropFirst())
        }
        if folder == base { return "" }
        if folder.hasPrefix(base + "/") {
            return String(folder.dropFirst(base.count + 1))
        }
        return folder
    }

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

/// Dasselbe für Zeitstempel: Ein Treffer ohne Datum (bsdtar-Eintrag) steht
/// aufsteigend vorn.
private func compareOptionalSeconds(_ lhs: Double?, _ rhs: Double?)
    -> ComparisonResult {
    let left = lhs ?? -Double.infinity
    let right = rhs ?? -Double.infinity
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
    case "modified":
        primary = compareOptionalSeconds(lhs.modified, rhs.modified)
    case "created":
        primary = compareOptionalSeconds(lhs.created, rhs.created)
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

/// EINE Zeile des JSONL-Stroms der Suche: ein Fortschrittsobjekt
/// (`type: progress`, der Ordner bzw. das Archiv, das der Kern gerade
/// durchsucht) oder ein Treffer. Alles andere — Müll, fremde Zeilen, ein
/// Treffer ohne `isDirectory` — ist nil.
enum SearchLine {
    case progress(String)
    case hit(Hit)
}

/// Parst eine JSONL-Zeile GENAU EINMAL und verzweigt am `type`-Feld.
///
/// Bis 0.28.2 liefen zwei getrennte Parser hintereinander: parseProgress
/// parste die ganze Zeile, verwarf sie am type-Feld, danach parste parseHit
/// dieselben Bytes noch einmal. Gemessen am 2026-09-03 mit `swiftc -O`
/// über 100 000 Zeilen: 0,493 s für beide Parser, 0,289 s für diesen einen
/// — und in der Haupt-App lief das auf dem Main-Thread.
func parseSearchLine(_ lineData: Data) -> SearchLine? {
    guard
        let object = try? JSONSerialization.jsonObject(with: lineData),
        let dict = object as? [String: Any],
        let path = dict["path"] as? String,
        let kind = dict["type"] as? String
    else { return nil }
    if kind == "progress" { return .progress(path) }
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
    // KEIN Rückfall auf `kind == "dir"`: Der Vertrag verlangt ausdrücklich,
    // dass die Frontends den Typ nicht erraten. Ein ORDNER im Archiv kommt
    // als `member` an und sähe damit aus wie eine Datei — genau der
    // Review-Fund vom 2026-08-17, bei dem ein Doppelklick eine leere Datei
    // erzeugte. Beide Erzeuger (emit() im Kern, jsonlData() hier) schreiben
    // das Feld immer; eine Zeile ohne es stammt nicht von uns und wird
    // verworfen, statt einen falschen Typ zu behaupten.
    guard let isDirectory = dict["isDirectory"] as? Bool else { return nil }
    return .hit(Hit(path: path, kind: kind, line: dict["line"] as? Int,
                    size: dict["size"] as? Int,
                    filesystemPath: filesystemPath,
                    archiveMembers: archiveMembers,
                    isDirectory: isDirectory,
                    field: dict["field"] as? String,
                    value: dict["value"] as? String,
                    width: dict["width"] as? Int,
                    height: dict["height"] as? Int,
                    modified: dict["modified"] as? Double,
                    created: dict["created"] as? Double))
}

/// Übersetzt EINE JSONL-Zeile in einen Hit (oder nil bei Müll und bei
/// Fortschrittszeilen). Für Übergabedateien, Export-Rückprobe und Tests —
/// wer den laufenden Strom liest, nimmt parseSearchLine() und parst nur
/// einmal.
func parseHit(_ lineData: Data) -> Hit? {
    if case .hit(let hit)? = parseSearchLine(lineData) { return hit }
    return nil
}

/// Übersetzt eine JSONL-Zeile in einen Fortschritts-Pfad — nil für alles
/// andere. Gleiche Regel wie bei parseHit(): nicht im laufenden Strom.
func parseProgress(_ lineData: Data) -> String? {
    if case .progress(let path)? = parseSearchLine(lineData) { return path }
    return nil
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

/// Ein leeres Feld setzt keine Grenze; eine falsche Eingabe darf niemals
/// dieselbe Bedeutung bekommen. Der Zahlenleser bleibt für gültige Syntax
/// die einzige Quelle.
enum PixelLimitInput: Equatable {
    case empty
    case value(Int)
    case invalid

    init(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .empty
        } else if let value = parsePixelLimit(text) {
            self = .value(value)
        } else {
            self = .invalid
        }
    }
}

/// Validiert und markiert dieselben vier Felder in beiden Apps. Der erste
/// konkrete Fehler erscheint zusätzlich in der Statuszeile des Aufrufers.
func validatePixelTexts(_ texts: [String]) -> (limits: PixelLimits, errors: [String?]) {
    precondition(texts.count == 4)
    let labels = ["Breite von", "Breite bis", "Höhe von", "Höhe bis"]
    var values = [Int?](repeating: nil, count: 4)
    var errors = [String?](repeating: nil, count: 4)
    for (index, text) in texts.enumerated() {
        switch PixelLimitInput(text) {
        case .empty: break
        case .value(let value): values[index] = value
        case .invalid:
            errors[index] = labels[index] + ": Positive ganze Pixelzahl eingeben (z. B. 1.000 px); keine Dezimalzahl oder Zahl über " + String(Int.max) + "."
        }
    }
    for (low, high, label) in [(0, 1, "Breite"), (2, 3, "Höhe")] {
        if let minimum = values[low], let maximum = values[high], minimum > maximum {
            let error = label + ": Von darf nicht größer als bis sein."
            errors[low] = error
            errors[high] = error
        }
    }
    return (PixelLimits(minWidth: values[0], maxWidth: values[1],
                        minHeight: values[2], maxHeight: values[3]), errors)
}

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

/// Ein Katalog für Eingabefelder, CLI, Übergabe und Zusammenfassung.
/// Werte bleiben Text; Einheiten und Zeitpunkte validiert ausschließlich Python.
struct FactFilterOption {
    let key: String
    let group: String
    let title: String
    let placeholder: String

    static let all: [FactFilterOption] = [
        .init(key: "min-size", group: "Größe", title: "Größe ab", placeholder: "z. B. 1 MiB"),
        .init(key: "max-size", group: "Größe", title: "Größe bis", placeholder: "z. B. 10 MiB"),
        .init(key: "modified-from", group: "Geändert", title: "Geändert ab", placeholder: "2026-09-05T00:00:00Z"),
        .init(key: "modified-to", group: "Geändert", title: "Geändert bis", placeholder: "2026-09-05T23:59:59Z"),
        .init(key: "created-from", group: "Erstellt", title: "Erstellt ab", placeholder: "2026-09-05T00:00:00Z"),
        .init(key: "created-to", group: "Erstellt", title: "Erstellt bis", placeholder: "2026-09-05T23:59:59Z")
    ]
}

/// Eine Quelle für CLI-Optionen und Quick-Übergaben. Maßtexte bleiben roh:
/// Eine ungültige URL-Eingabe darf nicht zu einer leeren Grenze werden.
struct SearchConfiguration: Equatable {
    var mode: SearchTextMode = .name
    var regex = false
    var caseSensitive = false
    var archives = false
    var includeHidden = false
    var exact = false
    var only = "both"
    var metadataField: String? = nil
    var pixelTexts = ["", "", "", ""]
    var exclusions: [String] = []
    var rawFacts: [String: String] = [:]

    /// Auch fehlerhafter nichtleerer Faktentext muss Python erreichen, damit
    /// der Nutzer dessen konkrete Diagnose sieht. Ausschlüsse zählen nicht.
    var hasPositiveFilter: Bool {
        !validatePixelTexts(pixelTexts).limits.isEmpty || FactFilterOption.all.contains {
            !(rawFacts[$0.key] ?? "").isEmpty
        }
    }

    var filterSummary: String {
        let pixels = validatePixelTexts(pixelTexts).limits.summary
        let facts = FactFilterOption.all.compactMap { option -> String? in
            guard let text = rawFacts[option.key], !text.isEmpty else { return nil }
            return option.title + " " + text
        }
        return ([pixels].filter { !$0.isEmpty } + facts).joined(separator: ", ")
    }

    static let pixelKeys = ["minw", "maxw", "minh", "maxh"]

    static func fromQueryItems(_ items: [URLQueryItem]) -> SearchConfiguration {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        var result = SearchConfiguration()
        result.mode = SearchTextMode(rawValue: value("mode") ?? "")
            ?? (value("content") == "1" ? .content : .name)
        result.regex = value("regex") == "1"
        result.caseSensitive = value("case") == "1"
        result.archives = value("archives") == "1"
        result.includeHidden = value("hidden") == "1"
        result.exact = value("exact") == "1"
        result.only = ["both", "files", "dirs"].contains(value("only") ?? "")
            ? value("only")! : "both"
        result.metadataField = value("field")
        result.pixelTexts = pixelKeys.map { value($0) ?? "" }
        for option in FactFilterOption.all {
            if let text = value(option.key), !text.isEmpty { result.rawFacts[option.key] = text }
        }
        result.exclusions = items.filter { $0.name == "exclude" }.compactMap { $0.value }
        return result
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "content", value: mode == .content ? "1" : "0"),
            URLQueryItem(name: "only", value: only)]
        for (key, enabled) in [("regex", regex), ("case", caseSensitive),
                               ("archives", archives), ("hidden", includeHidden),
                               ("exact", exact)] {
            items.append(URLQueryItem(name: key, value: enabled ? "1" : "0"))
        }
        if let metadataField { items.append(URLQueryItem(name: "field", value: metadataField)) }
        for (key, text) in zip(Self.pixelKeys, pixelTexts) {
            items.append(URLQueryItem(name: key, value: text))
        }
        for option in FactFilterOption.all {
            if let text = rawFacts[option.key], !text.isEmpty {
                items.append(URLQueryItem(name: option.key, value: text))
            }
        }
        items += exclusions.map { URLQueryItem(name: "exclude", value: $0) }
        return items
    }

    func arguments(pattern: String, root: String, progress: Bool = false) -> [String]? {
        let validation = validatePixelTexts(pixelTexts)
        guard validation.errors.allSatisfy({ $0 == nil }), let cli = findCLI() else { return nil }
        let hasPattern = !pattern.isEmpty
        guard hasPattern || hasPositiveFilter else { return nil }
        var args = ["-u", cli, "--json"]
        if hasPattern {
            if mode == .content { args.append("--content") }
            if mode == .metadata { args.append("--metadata") }
            if let metadataField, !metadataField.isEmpty { args += ["--metadata-field", metadataField] }
        }
        args += validation.limits.arguments
        if regex { args.append("--regex") }
        if caseSensitive { args.append("--case-sensitive") }
        if exact { args.append("--exact") }
        if !archives { args.append("--no-archives") }
        if only != "both" { args += ["--only", only] }
        if includeHidden { args.append("--hidden") }
        if progress { args.append("--progress") }
        // Ein Muster darf mit '-' beginnen; '=' bindet es eindeutig an
        // die Option, statt es argparse als neue Option lesen zu lassen.
        for exclusion in exclusions { args.append("--exclude=" + exclusion) }
        for option in FactFilterOption.all {
            if let text = rawFacts[option.key], !text.isEmpty {
                args.append("--" + option.key + "=" + text)
            }
        }
        args.append("--")
        if hasPattern { args.append(pattern) }
        args.append(root)
        return args
    }
}

/// Derselbe Editor in beiden Apps. Return trennt Muster, Leerraum gehört
/// zum Muster. Nur wirklich leere Zeilen setzen keinen Ausschluss.
final class SearchFilterView: NSStackView, NSTextViewDelegate, NSTextFieldDelegate {
    let exclusionsEditor = NSTextView()
    private(set) var factFields: [String: NSTextField] = [:]
    var rawFacts: [String: String] {
        get { factFields.mapValues { $0.stringValue }.filter { !$0.value.isEmpty } }
        set {
            for (key, field) in factFields { field.stringValue = newValue[key] ?? "" }
        }
    }
    var onChange: (() -> Void)?

    var exclusions: [String] {
        get { exclusionsEditor.string.components(separatedBy: .newlines).filter { !$0.isEmpty } }
        set { exclusionsEditor.string = newValue.joined(separator: "\n") }
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        let label = NSTextField(labelWithString: "Ausschließen · ein Muster je Zeile")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        addArrangedSubview(label)
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
        exclusionsEditor.toolTip = "Zum Beispiel node_modules oder Cache/*.zip. Groß-/Kleinschreibung gilt immer. Ohne / gilt das Muster für jede Pfadkomponente; mit / für den relativen Pfad ab Such- oder Archivwurzel."
        exclusionsEditor.setAccessibilityLabel("Ausschlussmuster, ein Muster je Zeile")
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = exclusionsEditor
        addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        scroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        for index in stride(from: 0, to: FactFilterOption.all.count, by: 2) {
            let options = Array(FactFilterOption.all[index...index + 1])
            let label = NSTextField(labelWithString: options[0].group)
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
                factFields[option.key] = field
                fields.append(field)
            }
            let from = NSTextField(labelWithString: "von")
            let to = NSTextField(labelWithString: "bis")
            from.font = .systemFont(ofSize: 11)
            to.font = .systemFont(ofSize: 11)
            let row = NSStackView(views: [label, from, fields[0], to, fields[1]])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            fields[0].widthAnchor.constraint(equalTo: fields[1].widthAnchor).isActive = true
        }
        let hint = NSTextField(labelWithString: "Grenzen inklusive · Zeitpunkte mit Z oder Offset · leer = keine Grenze")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .secondaryLabelColor
        addArrangedSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht verwendet") }
    func textDidChange(_ notification: Notification) { onChange?() }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
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
    // Kompatibler Adapter für bestehende Headless-Aufrufer; die eigentliche
    // Optionsweitergabe steht ausschließlich in SearchConfiguration.
    var configuration = SearchConfiguration()
    configuration.mode = metadata ? .metadata : (content ? .content : .name)
    configuration.regex = regex
    configuration.caseSensitive = caseSensitive
    configuration.archives = archives
    configuration.includeHidden = includeHidden
    configuration.exact = exact
    configuration.only = only
    configuration.metadataField = metadataField
    configuration.pixelTexts = [pixelLimits.minWidth, pixelLimits.maxWidth,
                                pixelLimits.minHeight, pixelLimits.maxHeight].map { $0.map(String.init) ?? "" }
    return configuration.arguments(pattern: pattern, root: root, progress: progress)
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
final class SearchDiagnostics {
    /// Höchstlänge einer einzelnen stderr-Zeile, die noch zusammengesetzt
    /// wird. Ein Kern, der eine endlos lange Zeile schriebe, soll den
    /// Puffer nicht wachsen lassen.
    static let lineLimit = 64 * 1024
    /// Die Präfixe, die `favenio.py` seinen stderr-Zeilen voranstellt.
    static let errorPrefix = "favenio: fehler: "
    static let warningPrefix = "favenio: warnung: "

    private let lock = NSLock()
    private var carry = Data()        // angefangene Zeile zwischen Häppchen
    private var warnings = 0
    private var firstError: String?

    /// Hängt sich an die stderr-Pipe und leert sie fortlaufend.
    func collect(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    /// Nach dem Prozessende: Handler lösen und den Rest nachlesen.
    ///
    /// Die Schreibseite wird VOR dem Lesen geschlossen. `availableData`
    /// blockiert nämlich, solange irgendein Deskriptor die Pipe noch zum
    /// Schreiben offen hält — und genau das ist der Fall, wenn
    /// `process.run()` gescheitert ist: Dann hat das Kind die Pipe nie
    /// bekommen, und niemand sonst schließt sie. Ohne dieses Schließen
    /// hing der Aufruf unbegrenzt. Ein zweites Schließen ist harmlos,
    /// deshalb `try?`.
    func finish(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        append(handle.availableData)
        lock.lock()
        defer { lock.unlock() }
        if !carry.isEmpty {          // letzte Zeile ohne Umbruch
            consume(String(decoding: carry, as: UTF8.self))
            carry.removeAll()
        }
    }

    /// Gezählt wird beim DURCHLAUFEN, nicht am Ende aus einem gedeckelten
    /// Text: Ein Lauf über einen unlesbaren Baum erzeugt beliebig viele
    /// Warnungen, und „470 Objekte übersprungen" wäre schlicht falsch,
    /// wenn es 5000 waren. Gespeichert wird deshalb nichts außer der
    /// ersten Fehlerzeile und dem Zähler.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        carry.append(chunk)
        while let newline = carry.firstIndex(of: 0x0A) {
            let lineData = carry.subdata(in: carry.startIndex..<newline)
            carry.removeSubrange(carry.startIndex...newline)
            consume(String(decoding: lineData, as: UTF8.self))
        }
        if carry.count > SearchDiagnostics.lineLimit {
            carry.removeAll(keepingCapacity: true)
        }
    }

    /// Nur mit gehaltenem `lock` aufrufen.
    private func consume(_ line: String) {
        if line.hasPrefix(SearchDiagnostics.warningPrefix) {
            warnings += 1
        } else if firstError == nil,
                  line.hasPrefix(SearchDiagnostics.errorPrefix) {
            firstError = String(
                line.dropFirst(SearchDiagnostics.errorPrefix.count))
        }
    }

    /// Die erste Fehlerzeile des Kerns, ohne Präfix — oder nil.
    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstError
    }

    /// Wie viele Objekte der Lauf überspringen musste.
    var warningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }
}

struct SearchExit {
    let status: Int32
    let reason: Process.TerminationReason
    /// Der Grund eines Fehlschlags, wie der Kern ihn auf stderr genannt hat.
    var errorMessage: String? = nil
    /// Wie viele Objekte der Lauf überspringen musste.
    var warningCount: Int = 0
}

/// Der Satz, den die Oberfläche bei einem gescheiterten Lauf zeigt.
///
/// Der Kern sagt auf stderr, WAS schiefging — „--metadata braucht exiftool,
/// das nicht gefunden wurde" etwa, oder „ungültiger regulärer Ausdruck".
/// Bis 0.27.1 hing stderr auf `nullDevice`, und beide Apps rieten
/// stattdessen: Die Haupt-App zeigte nur „Suche fehlgeschlagen.", die
/// Schnellsuche riet zu einer Neuinstallation, die nichts half.
func searchFailureText(_ exit: SearchExit) -> String {
    if let message = exit.errorMessage, !message.isEmpty {
        return "Suche fehlgeschlagen: " + message
    }
    if exit.reason != .exit {
        return "Suche abgebrochen (Signal \(exit.status))."
    }
    return "Suche fehlgeschlagen (Status \(exit.status))."
}

/// Zusatz für die Fußzeile, wenn der Lauf Objekte überspringen musste.
///
/// Ohne ihn sieht ein Lauf, der ein kaputtes Archiv oder einen gesperrten
/// Ordner auslassen musste, genauso vollständig aus wie einer, der alles
/// gelesen hat.
func skippedNote(_ count: Int) -> String {
    switch count {
    case 0: return ""
    case 1: return " · 1 Objekt übersprungen"
    default: return " · \(count) Objekte übersprungen"
    }
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

/// Ein Suchlauf mit eigener Identität und begrenztem Transport zur Main-Queue.
/// JSONL wird ausschließlich auf einem Hintergrundthread gelesen und geparst.
final class SearchRunner {
    static let batchHitLimit = 256
    static let batchByteLimit = 1024 * 1024
    static let recordByteLimit = 1024 * 1024
    static let outstandingLimit = 2

    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let slots = DispatchSemaphore(value: outstandingLimit)
    private var outstanding = 0
    private var maximumOutstanding = 0
    private var maximumBatchBytes = 0

    /// Messwerte des Transports, ohne Zugriff auf Treffer oder UI-Zustand.
    var transportPeaks: (packets: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (maximumOutstanding, maximumBatchBytes)
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Abbruch gilt auch VOR process.run(). Bei ignoriertem SIGTERM folgt
    /// nach einer halben Sekunde SIGKILL; kein Main-Thread wartet darauf.
    func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func start(arguments: [String], executable: String = pythonPath,
               onBatch: @escaping ([Hit], String?) -> Void,
               completion: @escaping (SearchExit) -> Void) {
        lock.lock()
        precondition(!started)
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = read(arguments: arguments, executable: executable,
                              onBatch: onBatch)
            // Alle Pakete wurden vorher in dieselbe serielle Main-Queue
            // gestellt. completion sieht daher auch die letzte übernommene Zeile.
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func read(arguments: [String], executable: String,
                      onBatch: @escaping ([Hit], String?) -> Void) -> SearchExit {
        let pipe = Pipe()
        let errPipe = Pipe()
        let diagnostics = SearchDiagnostics()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errPipe
        diagnostics.collect(from: errPipe)
        lock.lock()
        if cancelled {
            lock.unlock()
            diagnostics.finish(errPipe)
            return SearchExit(status: SIGTERM, reason: .uncaughtSignal)
        }
        do { try process.run() } catch {
            lock.unlock()
            diagnostics.finish(errPipe)
            return SearchExit(status: 2, reason: .exit,
                              errorMessage: error.localizedDescription)
        }
        lock.unlock()
        try? pipe.fileHandleForWriting.close()

        var buffer = Data()
        var hits: [Hit] = []
        var bytes = 0
        var progress: String?
        var protocolError: String?
        var lastDelivery = ProcessInfo.processInfo.systemUptime
        func deliver() {
            guard !hits.isEmpty || progress != nil else { return }
            // Ein voller Verbraucher bremst den Erzeuger über dessen Pipe.
            // Das kurze Warten prüft Abbruch auch bei blockierter Main-Queue.
            while slots.wait(timeout: .now() + 0.05) != .success {
                if isCancelled { return }
            }
            if isCancelled { slots.signal(); return }
            let packet = hits
            let latestProgress = progress
            lock.lock()
            outstanding += 1
            maximumOutstanding = max(maximumOutstanding, outstanding)
            maximumBatchBytes = max(maximumBatchBytes, bytes)
            lock.unlock()
            hits = []; bytes = 0; progress = nil
            lastDelivery = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [self] in
                defer {
                    lock.lock(); outstanding -= 1; lock.unlock()
                    slots.signal()
                }
                if !isCancelled { onBatch(packet, latestProgress) }
            }
        }
        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            if line.count > Self.recordByteLimit {
                protocolError = "Suchausgabe: JSONL-Zeile überschreitet 1 MiB."
                cancel()
                return
            }
            // Auch ein einzelner langer Dateiname belegt Transportbudget.
            if bytes + line.count > Self.batchByteLimit { deliver() }
            // Foundation-Temporaries gehören zur Zeile, nicht zum ganzen
            // lang laufenden Dispatch-Work-Item. Hits bleiben per ARC erhalten.
            let parsed = autoreleasepool { parseSearchLine(line) }
            switch parsed {
            case .hit(let hit)?: hits.append(hit); bytes += line.count
            case .progress(let path)?: progress = path; bytes += line.count
            case nil: break
            }
            if hits.count >= Self.batchHitLimit || bytes >= Self.batchByteLimit {
                deliver()
            }
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isCancelled {
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&state, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                protocolError = "Suchausgabe konnte nicht gelesen werden."
                cancel(); break
            }
            if ready == 0 {
                if ProcessInfo.processInfo.systemUptime - lastDelivery >= 0.05 { deliver() }
                continue
            }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                protocolError = "Suchausgabe konnte nicht gelesen werden."
                cancel(); break
            }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A), !isCancelled {
                consume(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.recordByteLimit {
                protocolError = "Suchausgabe: JSONL-Zeile überschreitet 1 MiB."
                cancel()
            }
            if ProcessInfo.processInfo.systemUptime - lastDelivery >= 0.05 { deliver() }
        }
        if !isCancelled { consume(buffer); deliver() }
        try? pipe.fileHandleForReading.close()
        // EOF und Prozessende dürfen in jeder Reihenfolge kommen. Erst
        // nachdem BEIDES abgeschlossen ist, steht der Suchstatus fest.
        process.waitUntilExit()
        diagnostics.finish(errPipe)
        return SearchExit(status: protocolError == nil ? process.terminationStatus : 2,
                          reason: protocolError == nil ? process.terminationReason : .exit,
                          errorMessage: protocolError ?? diagnostics.errorMessage,
                          warningCount: diagnostics.warningCount)
    }
}

/// Synchroner Adapter für Headless-Diagnosen; beide Oberflächen verwenden
/// SearchRunner direkt. Auf Main wird beim Warten die Queue weiter bedient.
func runSearchStreaming(arguments: [String],
                        onHit: ((Hit) -> Void)? = nil,
                        onProgress: @escaping (String) -> Void) -> SearchExit {
    let runner = SearchRunner()
    let done = DispatchSemaphore(value: 0)
    var result: SearchExit?
    runner.start(arguments: arguments, onBatch: { hits, progress in
        for hit in hits { onHit?(hit) }
        if let progress { onProgress(progress) }
    }, completion: { exit in result = exit; done.signal() })
    if Thread.isMainThread {
        while done.wait(timeout: .now()) != .success {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    } else { done.wait() }
    return result!
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
        if let modified = hit.modified { object["modified"] = modified }
        if let created = hit.created { object["created"] = created }
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

/// Unix-Zeit als ISO-8601-Zeitstempel in der Zeitzone dieses Rechners,
/// z. B. `2026-09-04T14:03:00+02:00`.
func isoTimestamp(_ seconds: Double) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
}

/// Ein CSV-Feld nach RFC 4180: Anführungszeichen nur, wo sie nötig sind, und
/// ein enthaltenes Anführungszeichen wird verdoppelt.
func csvField(_ value: String) -> String {
    // Formel-Präfixe entschärfen. Beginnt ein Zellwert mit "=", "+", "-",
    // "@" oder einem Tabulator, wertet Excel ihn als FORMEL — auch in
    // Anführungszeichen. Und macOS erlaubt in einem Dateinamen jedes
    // Zeichen außer "/" und NUL: Eine Datei `=cmd|'/c calc'!A1.txt` in
    // einem Downloads- oder Freigabeordner landete beim Export in der
    // ersten Spalte und bot Excel eine DDE-Ausführung an. Dass Excel das
    // Ziel ist, steht im Export selbst — er schreibt eine BOM genau dafür.
    // Das vorangestellte Apostroph ist die übliche Entschärfung: Excel
    // liest die Zelle dann als Text und zeigt es nicht an.
    var text = value
    if let first = text.first,
       first == "=" || first == "+" || first == "-" || first == "@"
        || first == "\t" || first == "\r" {
        text = "'" + text
    }
    guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n"
                                    || $0 == "\r" }) else { return text }
    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
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
            + "field,value,width,height,modified,created\n"
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
            // Zeitstempel als ISO 8601 mit Zeitzone — das liest jede
            // Tabellenkalkulation, eine nackte Sekundenzahl nicht.
            cells.append(hit.modified.map(isoTimestamp) ?? "")
            cells.append(hit.created.map(isoTimestamp) ?? "")
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

// ---------- Gemeinsamer Unterbau beider Trefferlisten ----------

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
                         QLPreviewPanelDelegate {
    var window: NSWindow!
    let tableView = NSTableView()

    var hits: [Hit] = []            // was die Tabelle zeigt
    var pending: [Hit] = []         // frisch gestreamte, noch nicht gezeigte
    var contextRow = -1             // Zeile, auf die der Rechtsklick ging
    var previewURLs: [URL] = []     // gerade in der QuickLook-Vorschau

    // ---------- Wirksame Zeilenmenge ----------

    func actionRows() -> [Int] {
        hitActionRows(selectedRows: tableView.selectedRowIndexes,
                      contextRow: contextRow)
    }

    func actionSelection() -> MaterializedHitSelection {
        materializeHitSelection(hits, rows: actionRows())
    }

    /// Die ausgewählten Treffer als Pfade — modellbezogen statt über
    /// Zeilennummern, die ein `reloadData()` nicht überlebt.
    func selectedHitPaths() -> Set<String> {
        Set(tableView.selectedRowIndexes.compactMap {
            $0 < hits.count ? hits[$0].path : nil
        })
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

    // ---------- QuickLook-Vorschau ----------

    /// Vorschau der ausgewählten Treffer ein-/ausblenden. Archiv-Einträge
    /// werden dafür (wie beim Öffnen) in einen Temp-Ordner ausgepackt.
    @objc func togglePreview() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        // Erst nachsehen, ob es überhaupt etwas zu zeigen gibt. Ein ORDNER im
        // Archiv hat keine Datei: materializeHit() liefert nil, das Panel
        // bliebe leer. Im Kontextmenü ist die Vorschau dafür schon grau — über
        // die Leertaste war sie trotzdem erreichbar (Review-Fund 2026-08-20).
        let selection = rebuildPreviewURLs()
        guard !previewURLs.isEmpty else {
            showActionIssue(selection)
            return
        }
        showActionIssue(selection)
        // Das Panel wird NUR nach vorn geholt, nicht zum Tastaturfenster
        // gemacht. Sonst gehen Pfeil hoch/runter dorthin und die Vorschau
        // lässt sich nicht durch die Trefferliste blättern — genau das, was
        // der Finder kann.
        //
        // Ein erster Versuch holte den Fokus danach per DispatchQueue zurück.
        // Das ist ein Rennen und verliert: Am 2026-09-02 am laufenden Fenster
        // gemessen blieb das Panel Tastaturfenster, die Auswahl in der Tabelle
        // wurde grau und die Pfeiltaste bewegte nichts. Deshalb wird der
        // Fokus gar nicht erst abgegeben.
        //
        // Damit entfällt auch der Weg, über den QuickLook seinen Controller
        // sonst sucht: `beginPreviewPanelControl` kommt über die
        // Responder-Kette beim Wechsel des Tastaturfensters. Ohne diesen
        // Wechsel muss die Datenquelle hier ausdrücklich gesetzt werden,
        // sonst bliebe das Panel leer.
        panel.dataSource = self
        panel.delegate = self
        panel.orderFront(nil)
        panel.reloadData()
        // Der Fokus gehört in die Tabelle — von dort blättern die Pfeiltasten.
        window.makeFirstResponder(tableView)
    }

    @discardableResult
    func rebuildPreviewURLs() -> MaterializedHitSelection {
        let selection = materializeHitSelection(hits, rows: actionRows())
        previewURLs = selection.urls
        return selection
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
    /// auch der Finder geht: Pfeil hoch/runter blättern die Trefferliste, ⎋
    /// schließt — egal, welches Fenster gerade die Tastatur hat. Den anderen
    /// Fall (das App-Fenster ist Tastaturfenster) deckt der Tastaturmonitor
    /// der jeweiligen App ab.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!)
        -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 125, 126:                                   // ↓ ↑
            tableView.keyDown(with: event)
            return true
        case 53:                                         // ⎋
            panel.orderOut(nil)
            return true
        default:
            return false
        }
    }

    // ---------- Kontextmenü-Aktionen auf der wirksamen Zeilenmenge ----------

    @objc func ctxOpenWith(_ sender: NSMenuItem) {
        guard let appURL = sender.representedObject as? URL else { return }
        let selection = actionSelection()
        guard !selection.urls.isEmpty else {
            showActionIssue(selection)
            return
        }
        NSWorkspace.shared.open(selection.urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration())
        showActionIssue(selection)
    }

    @objc func ctxReveal() {
        // Für Archiv-Einträge zeigt das die ausgepackte Temp-Kopie —
        // das ist genau die Datei, die man beim Öffnen/Ziehen bekommt.
        let selection = actionSelection()
        if !selection.urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(selection.urls)
        }
        showActionIssue(selection)
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
