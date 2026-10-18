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
    /// Verlustfreie Base64-Namen je Archivstufe. Die sichtbaren Namen können
    /// bei ungültigem UTF-8 dasselbe Ersatzzeichen tragen; diese Liste hält
    /// Identität und Materialisierung trotzdem auseinander.
    var archiveMemberBytes: [String] = []
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
    /// Mehrwortsuche (`--term`): je Begriff der Beleg — Zeile bei Inhalt,
    /// Feld und Wert bei Metadaten. Leer bei einem Begriff.
    var terms: [TermEvidence] = []
    var criteriaEvidence: [CriterionEvidence] = []
    var contentEncoding: String? = nil
    var contentPreview: ContentPreview? = nil
    var documentEvidence: DocumentEvidence? = nil
    var searchRootBytes: Data? = nil
    var finderMetadata: FinderMetadataSnapshot? = nil
    var searchRoot: String? { searchRootBytes.map { String(decoding: $0, as: UTF8.self) } }
    var documentPosition: DocumentPosition? { documentEvidence?.position }
    var documentSourceGeneration: ContentSourceGeneration? { documentEvidence?.generation }

    /// Anzeige und Suchbelege können sich ändern; das gefundene Objekt wird
    /// allein durch Dateisystempfad und die einzelnen Archivstufen bestimmt.
    var identity: HitIdentity {
        HitIdentity(filesystemPath: filesystemPath,
                    archiveMembers: archiveMembers,
                    archiveMemberBytes: archiveMemberBytes)
    }

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
    /// „Feld: Wert“ bei Metadaten oder begrenzte Kriterienbelege.
    var locationText: String {
        if terms.count > 1 {
            // Alle Begriffe: „1, 3" bzw. „Keywords: Winter | Title: Alpen".
            if terms.allSatisfy({ $0.line != nil }) {
                return terms.map { $0.documentPosition?.title ?? String($0.line!) }.joined(separator: ", ")
            }
            if terms.allSatisfy({ $0.field != nil }) {
                return terms.map { $0.field! + ": " + ($0.value ?? "") }
                    .joined(separator: " | ")
            }
        }
        if let field, let value { return field + ": " + value }
        if let documentPosition { return documentPosition.title }
        if let line { return String(line) }
        let fields = ["name": "Name", "extension": "Endung", "relativePath": "Pfad",
                      "content": "Inhalt", "metadata": "Metadaten", "size": "Größe",
                      "modified": "Geändert", "created": "Erstellt", "width": "Breite", "height": "Höhe",
                      "finderTags": "Finder-Tags", "finderComment": "Finder-Kommentar"]
        let locations = criteriaEvidence.filter { ["content", "metadata"].contains($0.field) }
        let facts = criteriaEvidence.filter { !["content", "metadata"].contains($0.field) }
        var evidence = (locations + facts).prefix(3).map {
            let place = ($0.documentPosition.map { " " + $0.title } ?? $0.line.map { " Zeile \($0)" } ?? "") + ($0.metadataField.map { " \($0)" } ?? "")
            let absent = $0.field == "content" && $0.negated ? "ohne „" + $0.value + "“" : $0.value
            return (fields[$0.field] ?? $0.field) + place + ": " + absent + ($0.valueTruncated ? "…" : "")
        }
        if criteriaEvidence.count > 3 { evidence.append("+\(criteriaEvidence.count - 3) weitere") }
        return evidence.joined(separator: " | ")
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
    func folderText(relativeTo root: String, showSearchRoot: Bool = false) -> String {
        if showSearchRoot, let source = searchRoot {
            let relative = folderText(relativeTo: source)
            return abbreviateHome(source) + (relative.isEmpty ? "" : " → " + relative)
        }
        let folder = folderPath
        var base = searchRoot ?? root
        if Data(base.utf8) == Data(filesystemPath.utf8), !isDirectory {
            base = (base as NSString).deletingLastPathComponent
        }
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        if base == "/" {
            return folder == "/" ? "" : String(folder.dropFirst())
        }
        let bytes = Data(folder.utf8), prefix = Data((base + "/").utf8)
        if bytes == Data(base.utf8) { return "" }
        if bytes.starts(with: prefix) {
            return String(decoding: bytes.dropFirst(prefix.count), as: UTF8.self)
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

/// Stabile Trefferidentität. Ein einzelner Name darf selbst `!/` enthalten;
/// deshalb niemals die Archivstufen zu einem Identitätstext zusammenfügen.
struct HitIdentity: Hashable {
    let filesystemPath: String
    let archiveMembers: [String]
    let archiveMemberBytes: [String]

    init(filesystemPath: String, archiveMembers: [String],
         archiveMemberBytes: [String] = []) {
        self.filesystemPath = filesystemPath
        self.archiveMembers = archiveMembers
        self.archiveMemberBytes = archiveMemberBytes
    }

    // Swift-Strings setzen NFC/NFD gleich; eine Dateiidentität behält ihre Originalbytes.
    static func == (lhs: HitIdentity, rhs: HitIdentity) -> Bool {
        lhs.filesystemPath.utf8.elementsEqual(rhs.filesystemPath.utf8)
            && sameOriginalTexts(lhs.archiveMembers, rhs.archiveMembers)
            && sameOriginalTexts(lhs.archiveMemberBytes, rhs.archiveMemberBytes)
    }

    private static func sameOriginalTexts(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
    }

    private static func hashOriginalText(_ text: String, into hasher: inout Hasher) {
        hasher.combine(text.utf8.count)
        if text.utf8.withContiguousStorageIfAvailable({ bytes in
            hasher.combine(bytes: UnsafeRawBufferPointer(bytes))
            return true
        }) == nil {
            Array(text.utf8).withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        }
    }

    func hash(into hasher: inout Hasher) {
        Self.hashOriginalText(filesystemPath, into: &hasher)
        for values in [archiveMembers, archiveMemberBytes] {
            hasher.combine(values.count)
            for value in values { Self.hashOriginalText(value, into: &hasher) }
        }
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
    case "finderTags":
        primary = (lhs.finderMetadata?.tagsText ?? "").localizedCaseInsensitiveCompare(rhs.finderMetadata?.tagsText ?? "")
    case "finderComment":
        primary = (lhs.finderMetadata?.commentText ?? "").localizedCaseInsensitiveCompare(rhs.finderMetadata?.commentText ?? "")
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
/// durchsucht), ein optionaler Bericht oder ein Treffer. Alles andere — Müll, fremde Zeilen, ein
/// Treffer ohne `isDirectory` — ist nil.
enum SearchLine {
    case progress(String)
    case report(SearchReportSnapshot)
    case invalidReport
    case dateResolution(Data)
    case invalidDateResolution
    case hit(Hit)
}

/// Ein Beleg der Mehrwortsuche: der Begriff und wo er stand.
struct TermEvidence: Hashable {
    let term: String
    var line: Int? = nil
    var field: String? = nil
    var value: String? = nil
    var documentPosition: DocumentPosition? = nil

    var json: [String: Any] {
        var object: [String: Any] = ["term": term]
        if let line { object["line"] = line }
        if let field { object["field"] = field }
        if let value { object["value"] = value }
        if let documentPosition { object["documentPosition"] = documentPosition.json }
        return object
    }

    static func parse(_ object: Any) -> TermEvidence? {
        guard let dict = object as? [String: Any],
              let term = dict["term"] as? String else { return nil }
        let position = DocumentPosition.parse(dict["documentPosition"])
        if dict["documentPosition"] != nil && position == nil { return nil }
        return TermEvidence(term: term, line: dict["line"] as? Int,
                            field: dict["field"] as? String,
                            value: dict["value"] as? String, documentPosition: position)
    }
}

struct CriterionEvidence: Hashable {
    let id: String
    let field: String
    let value: String
    var valueTruncated = false
    var negated = false
    var line: Int? = nil
    var metadataField: String? = nil
    var contentEncoding: String? = nil
    var documentPosition: DocumentPosition? = nil

    var json: [String: Any] {
        var result: [String: Any] = ["id": id, "field": field, "value": value]
        if valueTruncated { result["valueTruncated"] = true }
        if negated { result["negated"] = true }
        if let line { result["line"] = line }
        if let metadataField { result["metadataField"] = metadataField }
        if let contentEncoding { result["contentEncoding"] = contentEncoding }
        if let documentPosition { result["documentPosition"] = documentPosition.json }
        return result
    }

    static func parse(_ object: Any) -> CriterionEvidence? {
        guard let object = object as? [String: Any],
              let id = object["id"] as? String,
              let field = object["field"] as? String,
              let value = object["value"] as? String else { return nil }
        for key in ["valueTruncated", "negated"] where object[key] != nil {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        }
        var line: Int?
        if let raw = object["line"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue > 0, number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            line = number.intValue
        }
        guard object["metadataField"] == nil || object["metadataField"] is String else { return nil }
        let position = DocumentPosition.parse(object["documentPosition"])
        if object["documentPosition"] != nil && position == nil { return nil }
        return CriterionEvidence(id: id, field: field, value: value,
                                 valueTruncated: object["valueTruncated"] as? Bool ?? false,
                                 negated: object["negated"] as? Bool ?? false, line: line,
                                 metadataField: object["metadataField"] as? String,
                                 contentEncoding: object["contentEncoding"] as? String, documentPosition: position)
    }
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
        var dict = object as? [String: Any],
        let kind = dict["type"] as? String
    else { return nil }
    if kind == "searchReport" { return SearchReportSnapshot.parse(lineData).map { .report($0) } ?? .invalidReport }
    if kind == "dateResolution" || (kind == "validation" && dict["dateResolution"] != nil) {
        let value = kind == "dateResolution" ? dict["value"] : dict["dateResolution"]
        return value.flatMap { DateRangeTransport.resolution($0) }.map { .dateResolution($0) } ?? .invalidDateResolution
    }
    if dict["finderMetadata"] != nil || DocumentPosition.readers[dict["contentEncoding"] as? String ?? ""] != nil,
       let original = preservedJSONObject(lineData) as? [String: Any] { dict = original }
    guard let path = dict["path"] as? String else { return nil }
    if kind == "progress" {
        if let stage = dict["stage"] as? String, ["pdfText", "pdfOCR"].contains(stage),
           let page = DateRangeTransport.integer(dict["page"]), (1...128).contains(page),
           let pages = DateRangeTransport.integer(dict["pages"]), pages >= page, pages <= 10_000_000 {
            return .progress((stage == "pdfOCR" ? "PDF-OCR" : "PDF-Textebene") + " · Seite \(page) von \(pages) · " + path)
        }
        return .progress(path)
    }
    let filesystemPath = dict["filesystemPath"] as? String
        ?? (kind == "member"
            ? path.components(separatedBy: "!/").first ?? path
            : path)
    let archiveMembers = dict["archiveMembers"] as? [String]
        ?? (kind == "member"
            ? Array(path.components(separatedBy: "!/").dropFirst())
            : [])
    // KEIN Rückfall auf `kind == "dir"`: Der Vertrag verlangt ausdrücklich,
    // dass die Frontends den Typ nicht erraten. Ein ORDNER im Archiv kommt
    // als `member` an und sähe damit aus wie eine Datei — genau der
    // Review-Fund vom 2026-08-17, bei dem ein Doppelklick eine leere Datei
    // erzeugte. Beide Erzeuger (emit() im Kern, jsonlData() hier) schreiben
    // das Feld immer; eine Zeile ohne es stammt nicht von uns und wird
    // verworfen, statt einen falschen Typ zu behaupten.
    guard let isDirectory = dict["isDirectory"] as? Bool else { return nil }
    var rootBytes: Data?
    if let value = dict["searchRoot"] {
        guard let text = value as? String, text.hasPrefix("/"), !text.utf8.contains(0) else { return nil }
        rootBytes = Data(text.utf8)
    }
    let archiveMemberBytes = dict["archiveMemberBytes"] as? [String] ?? []
    let documentPosition = DocumentPosition.parse(dict["documentPosition"])
    let documentGeneration = ContentSourceGeneration.parse(dict["documentSourceGeneration"])
    if dict["documentPosition"] != nil {
        let reader = DocumentPosition.readers[dict["contentEncoding"] as? String ?? ""]
        if documentPosition == nil || documentGeneration == nil || documentPosition?.reader != reader { return nil }
    }
    guard archiveMemberBytes.isEmpty
            || archiveMemberBytes.count == archiveMembers.count else {
        return nil
    }
    var finderMetadata: FinderMetadataSnapshot?
    var hitSize = dict["size"] as? Int
    var hitModified = dict["modified"] as? Double
    var hitCreated = dict["created"] as? Double
    if dict["finderMetadata"] != nil {
        if let value = dict["size"], !(value is NSNull) {
            guard let raw = JSONByteSlices.member("size", in: lineData),
                  let size = Int(String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
                  size >= 0 else { return nil }
            hitSize = size
        }
        for key in ["modified", "created"] {
            guard let value = dict[key], !(value is NSNull) else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite else { return nil }
            if key == "modified" { hitModified = number.doubleValue }
            else { hitCreated = number.doubleValue }
        }
        guard !DateRangeTransport.hasDuplicateKeys(lineData),
              let raw = JSONByteSlices.member("finderMetadata", in: lineData),
              let snapshot = FinderMetadataSnapshot.parse(raw, size: hitSize,
                  modified: hitModified, inArchive: kind == "member" || !archiveMembers.isEmpty) else { return nil }
        finderMetadata = snapshot
    }
    return .hit(Hit(path: path, kind: kind, line: dict["line"] as? Int,
                    size: hitSize,
                    filesystemPath: filesystemPath,
                    archiveMembers: archiveMembers,
                    archiveMemberBytes: archiveMemberBytes,
                    isDirectory: isDirectory,
                    field: dict["field"] as? String,
                    value: dict["value"] as? String,
                    width: dict["width"] as? Int,
                    height: dict["height"] as? Int,
                    modified: hitModified,
                    created: hitCreated,
                    terms: (dict["terms"] as? [Any])?
                        .compactMap(TermEvidence.parse) ?? [],
                    criteriaEvidence: (dict["criteriaEvidence"] as? [Any])?
                        .compactMap(CriterionEvidence.parse) ?? [],
                    contentEncoding: dict["contentEncoding"] as? String,
                    contentPreview: ContentPreview.parse(dict["contentPreview"] == nil ? nil : (preservedContentPreview(lineData) ?? NSNull()), contentEncoding: dict["contentEncoding"] as? String),
                    documentEvidence: documentGeneration.map { DocumentEvidence(position: documentPosition, generation: $0) },
                    searchRootBytes: rootBytes, finderMetadata: finderMetadata))
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
    case name, content, metadata, document

    var title: String {
        switch self {
        case .name: return "Name"
        case .content: return "Inhalt"
        case .metadata: return "Metadaten"
        case .document: return "Dokumenttext"
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
enum CriteriaTransport {
    static let maximumBytes = 65_536

    static func problem(_ items: [URLQueryItem]) -> String? {
        let values = items.filter { $0.name == "criteria" }
        guard values.count <= 1 else { return "Kriterien dürfen nur einmal übergeben werden." }
        if let item = values.first {
            guard let text = item.value, !text.utf8.contains(0), text.utf8.count <= maximumBytes else {
                return "Kriterien überschreiten 65.536 UTF-8-Bytes oder enthalten einen ungültigen Wert."
            }
            if let document = preservedJSONObject(Data(text.utf8)) as? [String: Any],
               let version = document["schemaVersion"] as? NSNumber, version.doubleValue > 3 {
                return "Diese Kriterienschemaversion wird von den Apps noch nicht unterstützt."
            }
        }
        return DateRangeTransport.problem(items)
    }
}

enum SearchTextEncoding: String, CaseIterable {
    case utf8 = "utf-8", automatic = "auto", utf16LE = "utf-16-le", utf16BE = "utf-16-be"
    case windows1252 = "windows-1252", latin1 = "iso-8859-1", macRoman = "mac-roman"

    var title: String {
        switch self {
        case .utf8: return "UTF-8 (Standard)"
        case .automatic: return "Automatisch: UTF-BOM, sonst UTF-8"
        case .utf16LE: return "UTF-16 Little Endian"
        case .utf16BE: return "UTF-16 Big Endian"
        case .windows1252: return "Windows-1252"
        case .latin1: return "ISO-8859-1 (Latin-1)"
        case .macRoman: return "Mac Roman"
        }
    }
}

struct SearchConfiguration: Equatable {
    var textEncoding: SearchTextEncoding = .utf8
    static func supportsLocalContentCapability(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }
    var localOnly = false
    static func supportsPDFOCRCapability(_ raw: Any?) -> Bool { supportsOCRCapability(raw) }

    static func supportsOCRCapability(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == 1
    }
    var pdfOCR = false
    var ocr = false
    var finderMetadata = false
    var requiresFinderMetadata: Bool {
        if finderMetadata { return true }
        guard let criteriaJSON, let document = preservedJSONObject(Data(criteriaJSON.utf8)) as? [String: Any],
              let version = document["schemaVersion"] as? NSNumber else { return false }
        return version.doubleValue == 3
    }
    var requiresTransportVersion2: Bool { criteriaJSON != nil || textEncoding != .utf8 || mode == .document }
    var mode: SearchTextMode = .name
    var regex = false
    var caseSensitive = false
    var archives = false
    var includeHidden = false
    var exact = false
    var literalWildcards = false
    var only = "both"
    var metadataField: String? = nil
    var pixelTexts = ["", "", "", ""]
    var exclusions: [String] = []
    var rawFacts: [String: String] = [:]
    /// Weitere Suchbegriffe (`--term`), die ZUSÄTZLICH zum Muster zutreffen
    /// müssen — im selben Ziel (Name, Inhalt, Metadaten), nicht zwingend in
    /// derselben Zeile. Rohtexte, einer je Zeile des Eingabefelds.
    var terms: [String] = []
    var criteriaJSON: String? = nil
    var dateRanges: [String: DateRangeSpec] = [:]
    var dateReferenceTime: String? = nil
    var requiresDateRanges: Bool { !dateRanges.isEmpty || DateRangeTransport.criteriaHasRanges(criteriaJSON) }
    func forNewRun(reference: String? = nil) -> SearchConfiguration {
        var result = self
        result.dateReferenceTime = requiresDateRanges ? (reference ?? DateRangeTransport.referenceNow()) : nil
        return result
    }

    /// Auch fehlerhafter nichtleerer Faktentext muss Python erreichen, damit
    /// der Nutzer dessen konkrete Diagnose sieht. Ausschlüsse zählen nicht;
    /// weitere Suchbegriffe zählen — sie sind selbst eine Frage, die auch
    /// ohne Muster im Suchfeld eine Suche trägt.
    var hasPositiveFilter: Bool {
        criteriaJSON != nil || !terms.isEmpty || !dateRanges.isEmpty
            || !validatePixelTexts(pixelTexts).limits.isEmpty
            || FactFilterOption.all.contains { !(rawFacts[$0.key] ?? "").isEmpty }
    }

    /// Kurzfassung der positiven Filter für Endmeldung und Vorlagen-
    /// Tooltip: Maße, Fakten und weitere Begriffe — alles, was
    /// `hasPositiveFilter` zählt. Eine reine Begriffssuche ohne Muster
    /// nannte bis 0.34.0 „Keine Treffer in ~" ohne die Begriffe.
    var filterSummary: String {
        let pixels = validatePixelTexts(pixelTexts).limits.summary
        let facts = FactFilterOption.all.compactMap { option -> String? in
            guard let text = rawFacts[option.key], !text.isEmpty else { return nil }
            return option.title + " " + text
        }
        let termList = terms.isEmpty ? ""
            : "Begriffe " + terms.map { "„\($0)“" }.joined(separator: ", ")
        let criteria = criteriaJSON == nil ? "" : "Zusätzliche Kriterien"
        let encoding = textEncoding == .utf8 ? "" : "Textkodierung: " + textEncoding.title
        let dates = dateRanges.keys.sorted().map { ($0 == "modified" ? "Geändert: " : "Erstellt: ") + dateRanges[$0]!.title + " (" + dateRanges[$0]!.timeZone + ")" }
        return ([pixels, termList, criteria, encoding, localOnly ? "Nur lokale Inhalte" : "", ocr ? "Bild-OCR im Dokumenttext (DE/EN)" : "", pdfOCR ? "Scan-PDF-OCR im Dokumenttext" : ""].filter { !$0.isEmpty } + facts + dates).joined(separator: ", ")
    }

    static let pixelKeys = ["minw", "maxw", "minh", "maxh"]

    static func transportProblem(_ items: [URLQueryItem]) -> String? {
        let known = Set(SearchConfiguration().queryItems.map { $0.name }
            + ["criteria", "field", "term", "exclude", "encoding", "date-ranges", "date-reference-time", "finder-metadata", "local-only", "ocr", "pdf-ocr"] + FactFilterOption.all.map { $0.key })
        let booleans = Set(["content", "regex", "case", "archives", "hidden", "exact", "literal-wildcards", "finder-metadata", "local-only", "ocr", "pdf-ocr"])
        var seen = Set<String>()
        for item in items {
            guard known.contains(item.name), let text = item.value, !text.utf8.contains(0),
                  ["term", "exclude"].contains(item.name) || seen.insert(item.name).inserted,
                  !booleans.contains(item.name) || ["0", "1"].contains(text),
                  item.name != "mode" || SearchTextMode(rawValue: text) != nil,
                  item.name != "only" || ["both", "files", "dirs"].contains(text),
                  item.name != "encoding" || SearchTextEncoding(rawValue: text) != nil else {
                return "Unbekannte, doppelte oder ungültige Suchoption."
            }
        }
        return DateRangeTransport.problem(items) ?? CriteriaTransport.problem(items)
    }

    static func fromQueryItems(_ items: [URLQueryItem]) -> SearchConfiguration {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        var result = SearchConfiguration()
        result.localOnly = value("local-only") == "1"
        result.ocr = value("ocr") == "1"
        result.pdfOCR = value("pdf-ocr") == "1"
        result.finderMetadata = value("finder-metadata") == "1"
        result.textEncoding = SearchTextEncoding(rawValue: value("encoding") ?? "utf-8") ?? .utf8
        result.mode = SearchTextMode(rawValue: value("mode") ?? "")
            ?? (value("content") == "1" ? .content : .name)
        result.regex = value("regex") == "1"
        result.caseSensitive = value("case") == "1"
        result.archives = value("archives") == "1"
        result.includeHidden = value("hidden") == "1"
        result.exact = value("exact") == "1"
        result.literalWildcards = value("literal-wildcards") == "1"
        result.only = ["both", "files", "dirs"].contains(value("only") ?? "")
            ? value("only")! : "both"
        result.metadataField = value("field")
        result.pixelTexts = pixelKeys.map { value($0) ?? "" }
        for option in FactFilterOption.all {
            if let text = value(option.key), !text.isEmpty { result.rawFacts[option.key] = text }
        }
        result.exclusions = items.filter { $0.name == "exclude" }.compactMap { $0.value }
        result.terms = items.filter { $0.name == "term" }.compactMap { $0.value }
        result.criteriaJSON = value("criteria")
        if let text = value("date-ranges"), let ranges = DateRangeTransport.ranges(text) { result.dateRanges = ranges }
        result.dateReferenceTime = value("date-reference-time")
        return result
    }

    var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "mode", value: mode.rawValue),
            URLQueryItem(name: "content", value: mode == .content ? "1" : "0"),
            URLQueryItem(name: "only", value: only)]
        for (key, enabled) in [("regex", regex), ("case", caseSensitive),
                               ("archives", archives), ("hidden", includeHidden),
                               ("exact", exact), ("literal-wildcards", literalWildcards)] {
            items.append(URLQueryItem(name: key, value: enabled ? "1" : "0"))
        }
        if textEncoding != .utf8 { items.append(URLQueryItem(name: "encoding", value: textEncoding.rawValue)) }
        if localOnly { items.append(URLQueryItem(name: "local-only", value: "1")) }
        if ocr { items.append(URLQueryItem(name: "ocr", value: "1")) }
        if pdfOCR { items.append(URLQueryItem(name: "pdf-ocr", value: "1")) }
        if finderMetadata { items.append(URLQueryItem(name: "finder-metadata", value: "1")) }
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
        items += terms.map { URLQueryItem(name: "term", value: $0) }
        if let criteriaJSON { items.append(URLQueryItem(name: "criteria", value: criteriaJSON)) }
        if !dateRanges.isEmpty, let text = DateRangeTransport.text(["schemaVersion": 1, "ranges": dateRanges.mapValues { $0.object }]) {
            items.append(URLQueryItem(name: "date-ranges", value: text))
        }
        if let dateReferenceTime { items.append(URLQueryItem(name: "date-reference-time", value: dateReferenceTime)) }
        return items
    }

    func arguments(pattern: String, root: String, progress: Bool = false) -> [String]? {
        arguments(pattern: pattern, roots: [root], progress: progress)
    }

    func arguments(pattern: String, roots: [String], progress: Bool = false, frozenDateResolution: Data? = nil) -> [String]? {
        guard !roots.isEmpty else { return nil }
        let validation = validatePixelTexts(pixelTexts)
        guard validation.errors.allSatisfy({ $0 == nil }), let cli = findCLI() else { return nil }
        // Ohne Muster im Suchfeld tragen weitere Begriffe die Suche: Der
        // Kern nimmt dann den ersten --term als Muster.
        let hasPattern = !pattern.isEmpty || !terms.isEmpty
        guard hasPattern || hasPositiveFilter else { return nil }
        var args = ["-u", cli, "--json"]
        if localOnly { args.append("--local-only") }
        if ocr { args.append("--ocr") }
        if pdfOCR { args.append("--pdf-ocr") }
        if finderMetadata { args.append("--finder-metadata") }
        if textEncoding != .utf8 { args.append("--encoding=" + textEncoding.rawValue) }
        if let criteriaJSON { args.append("--criteria-json=" + criteriaJSON) }
        if let text = queryItems.first(where: { $0.name == "date-ranges" })?.value { args.append("--date-ranges-json=" + text) }
        args += DateRangeTransport.referenceArguments(dateReferenceTime)
        args += DateRangeTransport.frozenArguments(frozenDateResolution)
        if mode == .document && (hasPattern || criteriaJSON != nil) { args.append("--document-text") }
        if hasPattern {
            if mode == .content { args.append("--content") }
            if mode == .metadata {
                args.append("--metadata")
                // NUR im Metadaten-Modus. Der Kern liest
                // `metadata_mode = args.metadata or bool(args.metadata_field)`:
                // Ein gesetztes Feld ohne `--metadata` liess ihn im
                // Namens-Modus stillschweigend Metadaten durchsuchen, mit
                // `--content` endete er mit Exit 2. Bis 0.34.17 hing die
                // Bedingung nur an `hasPattern` — verdeckt allein davon,
                // dass die Haupt-App ausserhalb des Modus `nil` liefert.
                // Die Invariante gehoert hierher, nicht in eine der Apps.
                if let metadataField, !metadataField.isEmpty {
                    args += ["--metadata-field", metadataField]
                }
            }
        }
        args += validation.limits.arguments
        if regex { args.append("--regex") }
        if caseSensitive { args.append("--case-sensitive") }
        if exact { args.append("--exact") }
        if literalWildcards { args.append("--literal-wildcards") }
        if !archives { args.append("--no-archives") }
        if only != "both" { args += ["--only", only] }
        if includeHidden { args.append("--hidden") }
        if progress { args.append("--progress") }
        // Ein Muster darf mit '-' beginnen; '=' bindet es eindeutig an
        // die Option, statt es argparse als neue Option lesen zu lassen.
        for exclusion in exclusions { args.append("--exclude=" + exclusion) }
        for term in terms { args.append("--term=" + term) }
        for option in FactFilterOption.all {
            if let text = rawFacts[option.key], !text.isEmpty {
                args.append("--" + option.key + "=" + text)
            }
        }
        args.append("--")
        args.append(pattern)
        args += roots
        return args
    }
}

/// Neue Suchen prüfen alle deklarierten Bereiche; historische Transporte
/// bleiben ohne Quellenprüfung lesbar. Der Kern entscheidet über Lesbarkeit.
func searchRootProblem(_ root: String) -> String? {
    // Auf macOS 12 prüft der Kern den Pfad; die lokale Politik wird dort vor Zugriff abgewiesen.
    guard #available(macOS 13, *) else { return nil }
    guard let present = LocalContentAccess.withoutMaterialization(allowLegacy: false, {
        var information = stat()
        return stat(root, &information) == 0 || errno == EDEADLK || errno == EAGAIN
    }) else { return "Suchbereich ohne Materialisierung nicht prüfbar: " + abbreviateHome(root) }
    return present ? nil : "Suchbereich fehlt: " + abbreviateHome(root)
}

struct SearchRoots {
    static let maximumCount = 16
    static let maximumPathBytes = 4096
    static let maximumBytes = 65_536
    let paths: [String]
    let bytes: [Data]
    init(_ paths: [String]) { self.paths = paths; bytes = paths.map { Data($0.utf8) } }
    static func problem(_ paths: [String], limited: Bool = true) -> String? {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            return "Mindestens ein absoluter Suchbereich ist erforderlich."
        }
        if limited && (paths.count > maximumCount || paths.contains(where: { $0.utf8.count > maximumPathBytes })
            || paths.reduce(0, { $0 + $1.utf8.count }) > maximumBytes) {
            return "Suchbereiche sind auf 16 Einträge mit je 4096 und insgesamt 65.536 UTF-8-Bytes begrenzt."
        }
        guard Set(paths.map { Data($0.utf8) }).count == paths.count else {
            return "Ein Suchbereich ist mehrfach angegeben."
        }
        return nil
    }
    var liveProblem: String? { Self.problem(paths, limited: paths.count != 1) ?? paths.compactMap(searchRootProblem).first }
    var single: String? { paths.count == 1 ? paths[0] : nil }
    var title: String { single.map { abbreviateHome($0) } ?? "\(paths.count) Bereiche" }
    var detail: String { paths.joined(separator: "\n") }
    func carrying(_ hit: Hit, legacy: Bool = false) -> Hit? {
        var result = hit
        if let value = hit.searchRootBytes {
            guard let index = bytes.firstIndex(of: value) else { return nil }
            result.searchRootBytes = bytes[index]
        } else if let first = bytes.first, bytes.count == 1 {
            result.searchRootBytes = first
        } else if !legacy { return nil }
        return result
    }
}

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
struct SearchTemplate: Equatable {
    var name: String
    var pattern: String
    /// nil bedeutet: Die Vorlage speichert keinen Suchbereich.
    var roots: [String]?
    var root: String? { roots.flatMap { $0.count == 1 ? $0[0] : nil } }
    var configuration: SearchConfiguration

    init(name: String, pattern: String, root: String?, configuration: SearchConfiguration) {
        self.init(name: name, pattern: pattern, roots: root.map { [$0] }, configuration: configuration)
    }
    init(name: String, pattern: String, roots: [String]?, configuration: SearchConfiguration) {
        self.name = name; self.pattern = pattern; self.roots = roots; self.configuration = configuration
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.pattern == rhs.pattern && lhs.configuration == rhs.configuration
            && lhs.roots?.map { Data($0.utf8) } == rhs.roots?.map { Data($0.utf8) }
    }

    /// nil, wenn kein Ordner gespeichert ist oder er existiert.
    var missingRootMessage: String? {
        guard let roots, let missing = roots.first(where: { searchRootProblem($0) != nil }) else { return nil }
        return "Suchbereich der Vorlage „\(name)“ fehlt: " + missing
    }
}

struct SearchTemplateError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// Das Dateiformat der Vorlagen, versioniert:
///
///     {"version": 1,
///      "templates": [{"name": "…", "pattern": "…", "root": "/…" | null,
///                     "options": "mode=name&regex=1&exclude=…"}]}
///
/// `options` ist die Query der Quick-URL. Format 1 überliest unbekannte
/// Schlüssel; Format 2 mit Kriterien, Format 3 mit Wurzellisten und Format 4
/// mit Kalenderfragen, Format 5 mit Finder-Eigenschaften und Format 6 mit
/// lokaler Lesepolitik Format 7 mit Bild-OCR und Format 8 mit PDF-OCR weisen unbekannte Optionen ab. Eine höhere
/// `version` wird abgelehnt und genannt, statt still
/// falsch gelesen zu werden — ein fehlender oder falscher Wert ebenso.
enum SearchTemplateFormat {
    static let version = 8
    static let maximumBytes = 8 * 1024 * 1024

    static func encodeOptions(_ configuration: SearchConfiguration) -> String {
        var components = URLComponents()
        var question = configuration; question.dateReferenceTime = nil
        components.queryItems = question.queryItems
        return components.percentEncodedQuery ?? ""
    }

    /// Liest die Optionen einer Vorlage. NICHT über `percentEncodedQuery`:
    /// Dessen Setter bricht bei einem Zeichen, das in einer kodierten Query
    /// nichts zu suchen hat (Leerzeichen, Umlaut, nacktes `%`), mit einem
    /// `Fatal error` ab — und die Datei ist lesbares JSON, das zum
    /// Handedit einlädt; die App startete dann gar nicht mehr (belegt
    /// 2026-09-06). `URLComponents(string:)` nimmt solche Zeichen an und
    /// kodiert sie nach. Nur ein `#` schnitte alles dahinter still als
    /// Fragment ab — das ist ein Fehler mit Grund, kein halbes Ergebnis.
    static func decodeOptions(_ options: String) throws -> SearchConfiguration {
        guard !options.contains("#"),
              let components = URLComponents(string: "?" + options) else {
            throw SearchTemplateError(
                description: "Optionen „\(options)“ sind keine gültige Query")
        }
        let items = components.queryItems ?? []
        if let problem = CriteriaTransport.problem(items) {
            throw SearchTemplateError(description: problem)
        }
        if items.contains(where: { ["encoding", "local-only", "ocr", "pdf-ocr"].contains($0.name) }),
           let problem = SearchConfiguration.transportProblem(items) {
            throw SearchTemplateError(description: problem)
        }
        return SearchConfiguration.fromQueryItems(items)
    }

    static func encode(_ templates: [SearchTemplate]) throws -> Data {
        let dates = templates.contains { $0.configuration.requiresDateRanges }
        let finder = templates.contains { $0.configuration.requiresFinderMetadata }
        let local = templates.contains { $0.configuration.localOnly }
        let ocr = templates.contains { $0.configuration.ocr }
        let pdfOCR = templates.contains { $0.configuration.pdfOCR }
        let multiple = pdfOCR || ocr || local || finder || dates || templates.contains { ($0.roots?.count ?? 0) > 1 }
        for template in templates {
            if let roots = template.roots, let problem = SearchRoots.problem(roots, limited: multiple) {
                throw SearchTemplateError(description: problem)
            }
            if let problem = CriteriaTransport.problem(template.configuration.queryItems) {
                throw SearchTemplateError(description: problem)
            }
        }
        let entries: [[String: Any]] = templates.map { template in
            ["name": template.name, "pattern": template.pattern,
             multiple ? "roots" : "root": multiple ? (template.roots as Any? ?? NSNull()) : (template.root as Any? ?? NSNull()),
             "options": encodeOptions(template.configuration)]
        }
        let fileVersion = pdfOCR ? 8 : ocr ? 7 : local ? 6 : finder ? 5 : dates ? 4 : (multiple ? 3 : (templates.contains { $0.configuration.requiresTransportVersion2 } ? 2 : 1))
        let data = try JSONSerialization.data(
            withJSONObject: ["version": fileVersion, "templates": entries],
            options: [.prettyPrinted, .sortedKeys])
        guard data.count <= maximumBytes else {
            throw SearchTemplateError(description: "Vorlagendatei überschreitet 8 MiB.")
        }
        return data
    }

    static func decode(_ data: Data) throws -> [SearchTemplate] {
        guard data.count <= maximumBytes else {
            throw SearchTemplateError(description: "Vorlagendatei überschreitet 8 MiB.")
        }
        let object: Any
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            object = preservedJSONObject(data) ?? parsed
        } catch {
            // Den Grund des Parsers mitgeben (Zeile, fehlendes Komma …),
            // statt jede Syntaxpanne als „kein JSON-Objekt" zu melden.
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                ?? error.localizedDescription
            throw SearchTemplateError(
                description: "Vorlagendatei ist kein gültiges JSON: " + detail)
        }
        guard let dictionary = object as? [String: Any] else {
            throw SearchTemplateError(
                description: "Vorlagendatei ist kein JSON-Objekt")
        }
        guard let number = dictionary["version"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int.max) else {
            throw SearchTemplateError(
                description: "Vorlagendatei nennt keine Formatversion")
        }
        let fileVersion = number.intValue
        guard (1...version).contains(fileVersion) else {
            throw SearchTemplateError(
                description: "Vorlagendatei hat Formatversion \(fileVersion), "
                    + "diese App liest Version \(version)")
        }
        if fileVersion >= 2 && DateRangeTransport.hasDuplicateKeys(data) {
            throw SearchTemplateError(description: "Vorlagendatei enthält doppelte JSON-Felder.")
        }
        guard let entries = dictionary["templates"] as? [[String: Any]] else {
            throw SearchTemplateError(
                description: "Vorlagendatei enthält keine Vorlagenliste")
        }
        if fileVersion >= 2 && !Set(dictionary.keys).isSubset(of: ["version", "templates"]) {
            throw SearchTemplateError(description: "Vorlagendatei enthält unbekannte Felder.")
        }
        return try entries.enumerated().map { index, entry in
            if fileVersion >= 2 {
                let rootKey = fileVersion >= 3 ? "roots" : "root"
                guard Set(entry.keys) == ["name", "pattern", rootKey, "options"],
                      let pattern = entry["pattern"] as? String, !pattern.utf8.contains(0),
                      entry["options"] is String,
                      entry[rootKey] is NSNull || (fileVersion >= 3
                          ? (entry[rootKey] as? [String]).map { SearchRoots.problem($0) == nil }
                          : (entry[rootKey] as? String).map { $0.hasPrefix("/") && !$0.utf8.contains(0) }) == true else {
                    throw SearchTemplateError(description: "Vorlage \(index + 1) enthält unbekannte oder ungültige Felder.")
                }
            }
            guard let name = entry["name"] as? String, !name.isEmpty else {
                throw SearchTemplateError(
                    description: "Vorlage \(index + 1) hat keinen Namen")
            }
            let configuration: SearchConfiguration
            do {
                configuration = try decodeOptions(entry["options"] as? String ?? "")
                if configuration.pdfOCR && fileVersion < 8 { throw SearchTemplateError(description: "PDF-OCR benötigt Vorlagenformat 8.") }
                if configuration.ocr && fileVersion < 7 {
                    throw SearchTemplateError(description: "OCR benötigt Vorlagenformat 7.")
                }
                if configuration.localOnly && fileVersion < 6 {
                    throw SearchTemplateError(description: "Lokale Inhalte benötigen Vorlagenformat 6.")
                }
                if configuration.requiresDateRanges && fileVersion < 4 {
                    throw SearchTemplateError(description: "Kalenderbereiche benötigen Vorlagenformat 4.")
                }
                if configuration.requiresFinderMetadata && fileVersion < 5 {
                    throw SearchTemplateError(description: "Finder-Eigenschaften benötigen Vorlagenformat 5.")
                }
                if configuration.dateReferenceTime != nil {
                    throw SearchTemplateError(description: "Vorlagen speichern die Datumsfrage ohne Laufzeitpunkt.")
                }
                if fileVersion == 1 && configuration.textEncoding != .utf8 {
                    throw SearchTemplateError(description: "Textkodierung benötigt Vorlagenformat 2.")
                }
                if fileVersion >= 2 {
                    let items = URLComponents(string: "?" + (entry["options"] as? String ?? ""))?.queryItems ?? []
                    if let problem = SearchConfiguration.transportProblem(items) {
                        throw SearchTemplateError(description: problem)
                    }
                }
            } catch let error as SearchTemplateError {
                throw SearchTemplateError(
                    description: "Vorlage \(index + 1): " + error.description)
            }
            return SearchTemplate(
                name: name,
                pattern: entry["pattern"] as? String ?? "",
                roots: fileVersion >= 3 ? entry["roots"] as? [String] : (entry["root"] as? String).map { [$0] },
                configuration: configuration)
        }
    }
}

/// Liest und schreibt die Vorlagendatei — lokal, außerhalb jedes
/// Repositorys: `~/Library/Application Support/Favenio/search-templates.json`.
/// Geschrieben wird atomar; der Ordner entsteht beim ersten Sichern.
final class SearchTemplateStore {
    static var defaultURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Favenio", isDirectory: true)
            .appendingPathComponent("search-templates.json")
    }

    let fileURL: URL

    init(fileURL: URL = SearchTemplateStore.defaultURL) {
        self.fileURL = fileURL
    }

    /// Keine Datei heißt: keine Vorlagen. Alles andere, was nicht lesbar
    /// ist, kommt als Fehler mit Grund zurück.
    func load() throws -> [SearchTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            let descriptor = open(fileURL.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw SearchTemplateError(description: "Vorlagendatei muss eine reguläre Datei sein.")
            }
            data = try handle.read(upToCount: SearchTemplateFormat.maximumBytes + 1) ?? Data()
        } catch {
            throw SearchTemplateError(
                description: "Vorlagendatei nicht lesbar: "
                    + error.localizedDescription)
        }
        return try SearchTemplateFormat.decode(data)
    }

    func save(_ templates: [SearchTemplate]) throws {
        let data = try SearchTemplateFormat.encode(templates)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw SearchTemplateError(
                description: "Vorlagendatei nicht schreibbar: "
                    + error.localizedDescription)
        }
    }
}

/// Mehrzeiliges Eingabefeld mit Platzhalter, in beiden Apps für die
/// Ausschlüsse und (seit 0.34.0) die weiteren Begriffe. `NSTextView` kennt keinen
/// `placeholderString`; der graue Beispieltext wird gezeichnet, solange das
/// Feld leer ist, und verschwindet mit dem ersten Zeichen.
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
    /// Die erste stderr-Zeile OHNE Favenio-Präfix. Sie stammt nicht vom
    /// Kern, sondern von dem, was vor ihm steht — und das kann der Grund
    /// eines Fehlschlags sein: `/usr/bin/python3` ist ein Apple-Stummel,
    /// der ohne akzeptierte Xcode-Lizenz „You have not agreed to the Xcode
    /// license agreements" schreibt und mit Status 69 endet, ohne den Kern
    /// je zu starten. Bis 0.34.21 verwarfen beide Apps diese Zeile und
    /// zeigten nur „Suche fehlgeschlagen (Status 69)" (belegt 2026-09-15).
    private var firstForeignLine: String?

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
        } else if firstForeignLine == nil {
            // Auch Zeilenenden: Bei CRLF bleibt nach dem Zerlegen am \n ein
            // „\r" stehen, und eine Leerzeile davor würde sonst selbst zum Grund.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { firstForeignLine = trimmed }
        }
    }

    /// Die erste Fehlerzeile des Kerns, ohne Präfix. Hat der Kern keine
    /// genannt, ersatzweise die erste fremde stderr-Zeile (siehe
    /// `firstForeignLine`) — oder nil. Die Oberflächen zeigen den Text nur
    /// bei einem gescheiterten Lauf; eine harmlose fremde Zeile eines
    /// gelungenen Laufs bleibt damit unsichtbar.
    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstError ?? firstForeignLine
    }

    /// Zahl der stderr-Warnmeldungen, keine eindeutige Objektzahl.
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
    var report: SearchReportSnapshot? = nil
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
    case 1: return " · 1 Warnung"
    default: return " · \(count) Warnungen"
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

    /// Nur beim App-Ende: Danach laufen Dispatch-Completions nicht mehr
    /// verlässlich. Kein normaler Such-/Filterwechsel wartet hier.
    func stopForTermination(deadline: TimeInterval) {
        cancel()
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func start(arguments: [String], executable: String = pythonPath,
               onBatch: @escaping ([Hit], String?) -> Void,
               onReport: @escaping (SearchReportSnapshot) -> Void = { _ in },
               onDateResolution: @escaping (Data) -> Void = { _ in },
               completion: @escaping (SearchExit) -> Void) {
        lock.lock()
        precondition(!started)
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = read(arguments: arguments, executable: executable,
                              onBatch: onBatch, onReport: onReport, onDateResolution: onDateResolution)
            // Alle Pakete wurden vorher in dieselbe serielle Main-Queue
            // gestellt. completion sieht daher auch die letzte übernommene Zeile.
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func read(arguments: [String], executable: String,
                      onBatch: @escaping ([Hit], String?) -> Void,
                      onReport: @escaping (SearchReportSnapshot) -> Void,
                      onDateResolution: @escaping (Data) -> Void) -> SearchExit {
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
        var report: SearchReportSnapshot?
        var latestReport: SearchReportSnapshot?
        var dateResolution: Data?
        var protocolError: String?
        var lastDelivery = ProcessInfo.processInfo.systemUptime
        func deliver() {
            guard !hits.isEmpty || progress != nil || report != nil || dateResolution != nil else { return }
            // Ein voller Verbraucher bremst den Erzeuger über dessen Pipe.
            // Das kurze Warten prüft Abbruch auch bei blockierter Main-Queue.
            while slots.wait(timeout: .now() + 0.05) != .success {
                if isCancelled { return }
            }
            if isCancelled { slots.signal(); return }
            let packet = hits
            let latestProgress = progress
            let packetReport = report
            let packetDateResolution = dateResolution
            lock.lock()
            outstanding += 1
            maximumOutstanding = max(maximumOutstanding, outstanding)
            maximumBatchBytes = max(maximumBatchBytes, bytes)
            lock.unlock()
            hits = []; bytes = 0; progress = nil; report = nil; dateResolution = nil
            lastDelivery = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async { [self] in
                defer {
                    lock.lock(); outstanding -= 1; lock.unlock()
                    slots.signal()
                }
                if !isCancelled {
                    if let packetReport { onReport(packetReport) }
                    if let packetDateResolution { onDateResolution(packetDateResolution) }
                    onBatch(packet, latestProgress)
                }
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
            case .report(let value)?: report = value; latestReport = value; bytes += line.count
            case .dateResolution(let value)?: dateResolution = value; bytes += line.count
            case .invalidDateResolution?:
                protocolError = "Datumsbeleg: ungültiges Schema oder überschrittene Beleggrenze."
                cancel()
            case .invalidReport?:
                protocolError = "Suchbericht: ungültiges Schema oder überschrittene Berichtsgrenze."
                cancel()
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
                          warningCount: diagnostics.warningCount, report: latestReport)
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

/// Ergebnis eines Materialisierungsauftrags.
enum MaterializationOutcome: Equatable {
    case ready(URL)
    /// Der konkrete Grund — die Fehlerzeile des Kerns oder, wenn er keine
    /// schrieb, was auf unserer Seite scheiterte.
    case failed(String)
    case cancelled
}

/// Griff auf einen laufenden Auftrag. `cancel()` nimmt nur DIESEN Anforderer
/// vom Auftrag; der Unterprozess endet erst, wenn niemand mehr wartet. Die
/// Completion kommt genau einmal. Bis zum Beginn ihrer Zustellung gilt ein
/// Abbruch auch dann noch, wenn der Worker seine Datei bereits geliefert hat.
final class MaterializationRequest {
    fileprivate let hit: Hit
    fileprivate let epoch: Int
    // Ausschließlich unter MaterializationManager.lock lesen und ändern.
    fileprivate var cancelled = false
    fileprivate var delivered = false
    fileprivate var leaseCleanup: (() -> Void)?
    fileprivate var ephemeral = false
    private weak var manager: MaterializationManager?

    fileprivate init(hit: Hit, epoch: Int, manager: MaterializationManager) {
        self.hit = hit
        self.epoch = epoch
        self.manager = manager
    }

    func cancel() { manager?.cancel(self) }
    func release() { manager?.release(self) }
}

/// Appweiter Cache: jede Aktion auf denselben Archivtreffer verwendet dieselbe
/// materialisierte Datei. Alle Kopien liegen unter einem eindeutigen Root und
/// werden beim App-Ende gemeinsam entfernt.
///
/// Seit 0.32.0 asynchron: `request()` startet den Python-Kern im Hintergrund
/// und liefert das Ergebnis auf der Main-Queue. Bis 0.31.4 las
/// `materialize()` stdout synchron und wartete mit `waitUntilExit()` — auf
/// dem Main-Thread, aus Öffnen, Quick Look und Drag-and-drop heraus.
/// Gemessen am 2026-09-05 (`tests/MATERIALIZATION_MEASUREMENTS.md`) fror
/// das Fenster dabei so lange ein, wie der Kern brauchte.
///
/// Drei Zusagen, jede durch die Probe `tests/materialization_probe.swift`
/// geprüft:
/// - Gleichzeitige Anforderungen desselben Treffers teilen EINEN
///   Unterprozess und dieselbe Datei (`jobs`).
/// - stderr wird nebenläufig geleert (`SearchDiagnostics.collect`), sonst
///   hält eine volle Pipe den Kern an, während wir auf stdout warten.
/// - Nach `cleanup()` legt kein noch laufender Auftrag eine Datei neu an:
///   `epoch` markiert jeden Auftrag, ein zu spätes Ergebnis wird gelöscht
///   und als `.cancelled` gemeldet.
final class MaterializationManager {
    static let shared = MaterializationManager()

    /// Haken für Tests: anderer Interpreter, Kern, Zusatzargumente und eigene
    /// Temp-Wurzel. Foundation beachtet TMPDIR nicht auf jedem macOS-System.
    /// Die Apps lassen diese Werte auf ihren Vorgaben.
    var interpreter = pythonPath
    var cliPath: String?
    var extraArguments: [String] = []
    var temporaryDirectory = FileManager.default.temporaryDirectory

    private let lock = NSLock()
    // Schlüssel ist die IDENTITÄT, nicht der ganze Treffer: Anzeige und
    // Suchbelege (`line`, `terms`, `width`, `modified`) ändern sich mit der
    // Suche, das Objekt dahinter nicht. Bis 0.34.14 waren derselbe
    // Archiv-Eintrag aus einer Namenssuche und aus einer Inhaltssuche zwei
    // Cache-Einträge und zwei Unterprozesse in zwei Temp-Ordner — gegen die
    // Zusage, dass gleichzeitige Anforderungen desselben Treffers EINEN
    // Unterprozess und dieselbe Datei teilen.
    private final class CachedFile {
        let url: URL
        let source: ContentSourceGeneration?
        let leaf: ContentSourceGeneration?
        var retained: Bool
        var pins = 0
        init(url: URL, source: ContentSourceGeneration?, leaf: ContentSourceGeneration?, retained: Bool) {
            self.url = url
            self.source = source
            self.leaf = leaf
            self.retained = retained
        }
    }
    private var cache: [HitIdentity: CachedFile] = [:]
    private var jobs: [HitIdentity: Job] = [:]
    private var root: URL?
    private var epoch = 0
    /// Auspackaufträge laufen nebenläufig, aber GEDECKELT. Eine einzige
    /// Nutzeraktion — Leertaste, Doppelklick oder „Im Finder zeigen" auf
    /// einer großen Auswahl — erzeugt einen Auftrag je Archivtreffer, und
    /// jeder blockiert in `readDataToEndOfFile()` plus `waitUntilExit()`.
    /// Ohne Deckel wuchs der GCD-Threadpool bis an seine Decke: 200
    /// Einträge mit einer 3-s-Attrappe waren nach 9,3 s fertig, also rund
    /// 64 gleichzeitige Aufträge; mit dem echten Kern lief die Spitze auf
    /// 25 gleichzeitige Python-Prozesse. Der Folgeschaden traf die Suche,
    /// die denselben globalen Pool nimmt: Ihr erster Treffer kam nach
    /// 5,19 s statt 0,02 s (alles gemessen am 2026-09-10).
    ///
    /// `OperationQueue` statt eines Semaphors: Wartende Aufträge belegen
    /// dort keinen Thread. Ein Semaphor auf einer nebenläufigen
    /// `DispatchQueue` würde genau die Threads blockieren, die es sparen
    /// soll. Ein zu spät startender Auftrag ist unschädlich — `execute()`
    /// prüft `job.cancelled` und `epoch`, bevor es einen Prozess startet.
    static let maximumConcurrentExtractions = 4
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "favenio.materialize"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount =
            MaterializationManager.maximumConcurrentExtractions
        return queue
    }()

    /// Ein laufender Auspackvorgang samt allen, die auf ihn warten.
    private final class Job {
        let hit: Hit
        let epoch: Int
        let source: ContentSourceGeneration?
        let localOnly: Bool
        var waiters: [(MaterializationRequest, (MaterializationOutcome) -> Void)] = []
        var process: Process?
        var cancelled = false
        var retained = true
        init(hit: Hit, epoch: Int, source: ContentSourceGeneration?, localOnly: Bool) {
            self.localOnly = localOnly
            self.hit = hit
            self.epoch = epoch
            self.source = source
        }
    }

    /// Nur mit gehaltenem `lock` aufrufen.
    private func materializationRootLocked() -> URL? {
        if let root { return root }
        let candidate = temporaryDirectory
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

    /// Die URL, die OHNE Auspacken feststeht: eine normale Datei oder ein
    /// Ordner im Dateisystem, oder ein schon ausgepackter Eintrag. nil heißt
    /// „muss erst ausgepackt werden" — oder „gibt es nicht" (Ordner im
    /// Archiv, siehe `Hit.hasOpenableFile`). Drag-and-drop fragt hier, weil
    /// AppKit im Pasteboard-Callback sofort eine Antwort will.
    func knownURL(for hit: Hit) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let source = cache[hit.identity] != nil || hit.contentPreview?.sourceGeneration != nil
            ? ContentSourceGeneration.current(hit.filesystemPath) : nil
        let url = knownURLLocked(for: hit, source: source)
        if url != nil { cache[hit.identity]?.retained = true }
        return url
    }

    /// Nur mit gehaltenem Lock: request() verbindet dieselbe Cacheprüfung
    /// mit der Auftragswahl. Dazwischen darf finish() keinen Job entfernen.
    private func knownURLLocked(for hit: Hit, source: ContentSourceGeneration?) -> URL? {
        if let expected = hit.contentPreview?.sourceGeneration,
           source != expected { return nil }
        if !hit.isMember {
            return URL(fileURLWithPath: hit.filesystemPath)
        }
        if hit.isDirectory { return nil }
        if let cached = cache[hit.identity] {
            guard source == cached.source, let leaf = cached.leaf,
                  ContentSourceGeneration.current(cached.url.path) == leaf else {
                cache.removeValue(forKey: hit.identity)
                return nil
            }
            return cached.url
        }
        return nil
    }

    func generationSnapshot(for hit: Hit, url: URL) -> (source: ContentSourceGeneration, leaf: ContentSourceGeneration)? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = cache[hit.identity], cached.url.path.utf8.elementsEqual(url.path.utf8),
              let source = cached.source, let leaf = cached.leaf else { return nil }
        return (source, leaf)
    }

    /// Fordert die Datei hinter einem Treffer an.
    ///
    /// Steht sie schon fest (`knownURL`), kommt die Completion SOFORT und
    /// synchron auf dem rufenden Thread. Normale Abrufe liefern dabei nil;
    /// befristete Abrufe liefern eine Lease, die nach jedem Ausgang mit
    /// release() freigegeben werden muss.
    /// Sonst läuft der Kern im Hintergrund, die Completion kommt auf der
    /// Main-Queue, und der Griff erlaubt den Abbruch. Läuft für denselben
    /// Treffer schon ein Auftrag, hängt sich die Anforderung an ihn.
    @discardableResult
    func request(_ hit: Hit, localOnly: Bool = false,
                 ephemeral: Bool = false,
                 completion: @escaping (MaterializationOutcome) -> Void)
        -> MaterializationRequest? {
        lock.lock()
        let source = hit.isMember || hit.contentPreview?.sourceGeneration != nil
            ? ContentSourceGeneration.current(hit.filesystemPath, localOnly: localOnly) : nil
        if let expected = hit.contentPreview?.sourceGeneration,
           source != expected {
            lock.unlock()
            completion(.failed("Quelle stimmt nicht mehr mit der Fundstellenvorschau überein. Bitte neu suchen."))
            return nil
        }
        if let url = knownURLLocked(for: hit, source: source) {
            if ephemeral, let cached = cache[hit.identity] {
                let request = MaterializationRequest(hit: hit, epoch: epoch, manager: self)
                request.ephemeral = true
                request.delivered = true
                pin(request, cached: cached)
                lock.unlock()
                completion(.ready(url))
                return request
            }
            cache[hit.identity]?.retained = true
            lock.unlock()
            completion(.ready(url))
            return nil
        }
        // Ein ORDNER im Archiv hat keinen Inhalt zum Herausschreiben: Bei ZIP
        // entstand dabei eine leere Datei, bei TAR scheiterte die Extraktion
        // (Review-Fund 2026-08-17). Dateiaktionen gibt es dafür deshalb nicht;
        // sichtbar bleibt der Treffer trotzdem.
        if hit.isDirectory {
            lock.unlock()
            completion(.failed("Ordner im Archiv — keine Datei zum Öffnen"))
            return nil
        }
        let request = MaterializationRequest(hit: hit, epoch: epoch, manager: self)
        request.ephemeral = ephemeral
        // Ein Auftrag, den alle verlassen haben, stirbt gerade; ihm darf
        // sich niemand mehr anschließen — er endete mit `.cancelled`.
        if let job = jobs[hit.identity], !job.cancelled {
            if !ephemeral { job.retained = true }
            job.waiters.append((request, completion))
            lock.unlock()
            return request
        }
        let job = Job(hit: hit, epoch: epoch, source: source, localOnly: localOnly)
        job.retained = !ephemeral
        job.waiters.append((request, completion))
        jobs[hit.identity] = job
        lock.unlock()
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.finish(job, with: self.execute(job))
        }
        return request
    }

    // Miniaturen halten dieselbe Datei nur während des Decodierens fest.
    // Ein ausdrücklicher Dateiabruf behält sie weiterhin bis zum App-Ende.
    private func pin(_ request: MaterializationRequest, cached: CachedFile) {
        cached.pins += 1
        let identity = request.hit.identity
        request.leaseCleanup = { [weak self] in self?.releaseCached(cached, identity: identity) }
    }
    fileprivate func release(_ request: MaterializationRequest) {
        lock.lock()
        let cleanup = request.leaseCleanup
        request.leaseCleanup = nil
        lock.unlock()
        cleanup?()
    }
    private func releaseCached(_ cached: CachedFile, identity: HitIdentity) {
        lock.lock()
        cached.pins -= 1
        let discardFile = cached.pins == 0 && !cached.retained
        if discardFile && cache[identity] === cached { cache[identity] = nil }
        lock.unlock()
        if discardFile { DispatchQueue.global(qos: .utility).async { self.discard(cached.url) } }
    }

    /// Nimmt einen Anforderer vom Auftrag. Der letzte beendet den Prozess.
    fileprivate func cancel(_ request: MaterializationRequest) {
        lock.lock()
        guard !request.cancelled && !request.delivered else {
            lock.unlock()
            release(request)
            return
        }
        // finish() kann den Job bereits entfernt haben. Die eingereihte
        // Completion hält den Request und sieht diese Markierung trotzdem.
        request.cancelled = true
        guard let job = jobs[request.hit.identity],
              let index = job.waiters.firstIndex(where: { $0.0 === request })
        else {
            lock.unlock()
            release(request)
            return
        }
        let (_, completion) = job.waiters.remove(at: index)
        if job.waiters.isEmpty { terminateLocked(job) }
        lock.unlock()
        release(request)
        DispatchQueue.main.async { self.deliver(request, .cancelled, completion) }
    }

    /// Auf Main, unmittelbar vor JEDER Completion prüfen: Die vorige darf
    /// einen weiteren Request abbrechen oder cleanup() auslösen. Den Lock
    /// vor dem Aufruf freigeben, damit solche Rückrufe nicht blockieren.
    private func deliver(_ request: MaterializationRequest,
                         _ outcome: MaterializationOutcome,
                         _ completion: (MaterializationOutcome) -> Void) {
        lock.lock()
        guard !request.delivered else { lock.unlock(); return }
        let result = request.cancelled || request.epoch != epoch
            ? .cancelled : outcome
        request.delivered = true
        lock.unlock()
        completion(result)
    }

    /// Nur mit gehaltenem `lock` aufrufen. SIGTERM übersetzt der Kern in ein
    /// normales Ende (`install_termination_handlers`); bleibt er trotzdem
    /// stehen, folgt nach einer Sekunde SIGKILL — wie im SearchRunner.
    private func terminateLocked(_ job: Job) {
        job.cancelled = true
        guard let process = job.process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Läuft auf `queue`: startet den Kern und wartet auf ihn — hier darf
    /// gewartet werden, das ist nicht der Main-Thread.
    private func execute(_ job: Job) -> MaterializationOutcome {
        lock.lock()
        let stale = job.cancelled || job.epoch != epoch
        let root = stale ? nil : materializationRootLocked()
        lock.unlock()
        if stale { return .cancelled }
        guard let root else {
            return .failed("Temp-Ordner für ausgepackte Dateien nicht anlegbar")
        }
        guard let cli = cliPath ?? findCLI() else {
            return .failed("favenio.py nicht gefunden")
        }
        var object: [String: Any] = [
            "filesystemPath": job.hit.filesystemPath,
            "archiveMembers": job.hit.archiveMembers,
        ]
        if !job.hit.archiveMemberBytes.isEmpty {
            object["archiveMemberBytes"] = job.hit.archiveMemberBytes
        }
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              let jsonText = String(data: json, encoding: .utf8) else {
            return .failed("Treffer nicht als JSON darstellbar")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        var limits: [String] = []
        if let budget = job.hit.contentPreview?.archiveLimits {
            limits = ["--max-archive-member-bytes", String(budget.memberBytes),
                      "--max-archive-total-bytes", String(budget.totalBytes),
                      "--max-archive-ratio", String(budget.ratio)]
        }
        process.arguments = [cli, "--extract-json", jsonText,
                             "--extract-root", root.path] + (job.localOnly ? ["--local-only"] : []) + limits + extraArguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // stderr NEBENLÄUFIG leeren — dieselbe Wache wie beim Suchlauf: Eine
        // volle Pipe hält den Kern an, während wir auf sein stdout warten.
        let diagnostics = SearchDiagnostics()
        diagnostics.collect(from: errors)
        lock.lock()
        if job.cancelled {
            lock.unlock()
            diagnostics.finish(errors)
            return .cancelled
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            diagnostics.finish(errors)
            return .failed("Python-Kern nicht startbar: "
                           + error.localizedDescription)
        }
        job.process = process
        lock.unlock()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        diagnostics.finish(errors)
        lock.lock()
        let cancelled = job.cancelled
        lock.unlock()
        // print(out_path) hängt genau ein LF-Byte an. Leerraum davor gehört
        // zum Dateinamen; auch ein CR vor dem LF darf nicht verschwinden.
        let pathData = data.last == 0x0A ? data.dropLast() : data
        let path = String(data: pathData, encoding: .utf8) ?? ""
        if cancelled {
            // Der Kern war womöglich schneller als das Signal: Was er
            // schon geschrieben hat, will niemand mehr.
            if !path.isEmpty { discard(URL(fileURLWithPath: path)) }
            return .cancelled
        }
        guard process.terminationStatus == 0, !path.isEmpty else {
            return .failed(diagnostics.errorMessage
                ?? "Auspacken fehlgeschlagen (Status "
                   + "\(process.terminationStatus))")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed("Ausgepackte Datei fehlt: " + path)
        }
        return .ready(URL(fileURLWithPath: path))
    }

    /// Entfernt eine ausgepackte Datei samt ihrem `hit-…`-Ordner.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Trägt das Ergebnis ein und benachrichtigt alle Wartenden auf Main.
    private func finish(_ job: Job, with result: MaterializationOutcome) {
        var outcome = result
        let changed: Bool
        if case .ready = result { changed = ContentSourceGeneration.current(job.hit.filesystemPath, localOnly: job.localOnly) != job.source }
        else { changed = false }
        lock.lock()
        if job.cancelled || job.epoch != epoch {
            // Abbruch kann zwischen execute() und diesem Lock eintreffen.
            if case .ready(let url) = outcome { discard(url) }
            outcome = .cancelled
        } else if case .ready(let url) = outcome {
            if changed {
                discard(url)
                outcome = .failed("Quelle wurde während des Auspackens verändert. Bitte erneut anfordern.")
            } else {
                let cached = CachedFile(url: url, source: job.source, leaf: ContentSourceGeneration.current(url.path), retained: job.retained)
                cache[job.hit.identity] = cached
                for (request, _) in job.waiters where request.ephemeral && !request.cancelled { pin(request, cached: cached) }
            }
        }
        if jobs[job.hit.identity] === job { jobs[job.hit.identity] = nil }
        let waiters = job.waiters
        job.waiters = []
        lock.unlock()
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async {
            waiters.forEach { self.deliver($0.0, outcome, $0.1) }
        }
    }

    /// Bricht alle laufenden Aufträge ab und entfernt alle ausgepackten
    /// Dateien. Ein Auftrag, der danach noch zu Ende kommt, löscht sein
    /// Ergebnis selbst (`epoch`).
    func cleanup() {
        lock.lock()
        epoch += 1
        jobs.values.forEach { terminateLocked($0) }
        jobs.removeAll()
        cache.removeAll()
        let old = root
        root = nil
        lock.unlock()
        if let old { try? FileManager.default.removeItem(at: old) }
    }
}

/// Synchron — NUR für den Headless-Selbsttest und Werkzeuge. Auf dem
/// Main-Thread dreht die RunLoop weiter, bis die Completion da ist; die
/// Apps rufen das aus keiner Aktion, dort gilt `request()`.
func materializeHit(_ hit: Hit) -> URL? {
    var result: MaterializationOutcome?
    let done = DispatchSemaphore(value: 0)
    MaterializationManager.shared.request(hit) {
        result = $0
        done.signal()
    }
    if Thread.isMainThread {
        while done.wait(timeout: .now()) != .success {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    } else {
        done.wait()
    }
    if case .ready(let url)? = result { return url }
    return nil
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
        // Foundation-Zwischenobjekte nach jeder Zeile freigeben. Die
        // fertigen UTF-8-Bytes bleiben im gemeinsamen Ausgabepuffer.
        autoreleasepool {
            var object: [String: Any] = ["path": hit.path, "type": hit.kind,
                                         "isDirectory": hit.isDirectory]
            object["filesystemPath"] = hit.filesystemPath
            object["archiveMembers"] = hit.archiveMembers
            if let searchRoot = hit.searchRoot { object["searchRoot"] = searchRoot }
            if !hit.archiveMemberBytes.isEmpty {
                object["archiveMemberBytes"] = hit.archiveMemberBytes
            }
            if let contentEncoding = hit.contentEncoding { object["contentEncoding"] = contentEncoding }
            if let contentPreview = hit.contentPreview { object["contentPreview"] = contentPreview.json }
            if let documentPosition = hit.documentPosition { object["documentPosition"] = documentPosition.json }
            if let documentSourceGeneration = hit.documentSourceGeneration { object["documentSourceGeneration"] = documentSourceGeneration.json }
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
            if !hit.terms.isEmpty { object["terms"] = hit.terms.map { $0.json } }
            if !hit.criteriaEvidence.isEmpty {
                object["criteriaEvidence"] = hit.criteriaEvidence.map { $0.json }
            }
            if var encoded = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) {
                if let snapshot = hit.finderMetadata {
                    encoded.removeLast()
                    encoded.append(Data(",\"finderMetadata\":".utf8))
                    encoded.append(snapshot.json)
                    encoded.append(125)
                }
                data.append(encoded)
                data.append(0x0A)
            }
        }
    }
    return data
}

let quickHandoffPrefix = "favenio-quick-"
let quickHandoffSuffix = ".jsonl"
let maximumHandoffBytes = 8 * 1024 * 1024
let maximumHandoffLineBytes = 1024 * 1024
let maximumQuickURLBytes = 262_144

func quickHandoffInputProblem(query: String, root: String) -> String? {
    if query.utf8.count > 4096 {
        return "Suchtext ist zu lang für die Übergabe an Favenio (maximal 4096 UTF-8-Bytes)."
    }
    if root.utf8.count > 4096 {
        return "Suchpfad ist zu lang für die Übergabe an Favenio (maximal 4096 UTF-8-Bytes)."
    }
    return nil
}

/// Schreibt die Quick→Haupt-App-Übergabe atomar und nur für den Besitzer.
func writeQuickHandoff(_ hits: [Hit], selection: Set<HitIdentity> = [], version: Int = 1, roots: [String]? = nil,
                       configuration: SearchConfiguration? = nil, dateResolution: Data? = nil) throws -> URL {
    guard [1, 2, 3, 4, 5, 6, 7, 8].contains(version), selection.count <= 20,
          selection.isSubset(of: Set(hits.map { $0.identity })),
          version >= 2 || selection.isEmpty else { throw CocoaError(.fileWriteUnknown) }
    guard version >= 7 || configuration?.ocr != true else { throw CocoaError(.fileWriteUnknown) }
    guard !hits.contains(where: { $0.contentEncoding == "vision-ocr-text-v1" }) || configuration?.ocr == true else { throw CocoaError(.fileWriteUnknown) }
    guard version == 8 || configuration?.pdfOCR != true else { throw CocoaError(.fileWriteUnknown) }
    guard version >= 8 || !hits.contains(where: { $0.contentEncoding == "pdfkit-vision-text-v1" }) else { throw CocoaError(.fileWriteUnknown) }
    guard version >= 7 || !hits.contains(where: { $0.contentEncoding == "vision-ocr-text-v1" }) else { throw CocoaError(.fileWriteUnknown) }
    guard version >= 6 || configuration?.localOnly != true else { throw CocoaError(.fileWriteUnknown) }
    guard version >= 5 || (!hits.contains { $0.finderMetadata != nil } && configuration?.requiresFinderMetadata != true) else { throw CocoaError(.fileWriteUnknown) }
    if version >= 3 {
        guard let roots, SearchRoots.problem(roots) == nil,
              Set(hits.map { $0.identity }).count == hits.count,
              hits.allSatisfy({ $0.searchRootBytes != nil && SearchRoots(roots).carrying($0) != nil }) else {
            throw CocoaError(.fileWriteUnknown)
        }
    } else if roots != nil { throw CocoaError(.fileWriteUnknown) }
    if version >= 4 {
        guard let configuration, SearchConfiguration.transportProblem(configuration.queryItems) == nil,
              version == 8 ? configuration.pdfOCR : version == 7 ? configuration.ocr : version == 6 ? configuration.localOnly : version == 5 ? (configuration.requiresFinderMetadata || hits.contains { $0.finderMetadata != nil }) : configuration.requiresDateRanges else { throw CocoaError(.fileWriteUnknown) }
        if configuration.requiresDateRanges {
            guard configuration.dateReferenceTime != nil,
                  dateResolution.map({ DateRangeTransport.bound($0, to: configuration) }) ?? hits.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        } else if dateResolution != nil { throw CocoaError(.fileWriteUnknown) }
    } else if configuration != nil || dateResolution != nil { throw CocoaError(.fileWriteUnknown) }
    var data = Data()
    if version >= 2 {
        let identities = hits.filter { selection.contains($0.identity) }.map { hit in
            ["filesystemPath": hit.filesystemPath, "archiveMembers": hit.archiveMembers,
             "archiveMemberBytes": hit.archiveMemberBytes] as [String: Any]
        }
        var header: [String: Any] = ["type": "quickHandoff", "schemaVersion": version, "selection": identities]
        if version >= 3 { header["roots"] = roots! }
        if version >= 4 {
            header["options"] = configuration!.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }
            header["dateResolution"] = dateResolution.flatMap { preservedJSONObject($0) } ?? NSNull()
        }
        if version >= 5 { header["finderMetadataCapability"] = 1 }
        if version >= 6 { header["localContentCapability"] = 1 }
        if version >= 7 { header["ocrCapability"] = 1 }
        if version == 8 { header["pdfOCRCapability"] = 1 }
        data = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        data.append(10)
    }
    data.append(jsonlData(for: hits))
    guard data.count <= maximumHandoffBytes,
          data.split(separator: 0x0A).allSatisfy({ $0.count <= maximumHandoffLineBytes }) else {
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
struct QuickHandoffPayload {
    var hits: [Hit] = []
    var selection: Set<HitIdentity> = []
    var version = 1
    var roots: [String]?
    var configuration: SearchConfiguration?
    var dateResolution: Data?

    func bound(to paths: [String]) -> QuickHandoffPayload? {
        let scope = SearchRoots(paths)
        guard SearchRoots.problem(paths, limited: paths.count != 1) == nil,
              roots == nil || roots!.map({ Data($0.utf8) }) == scope.bytes else { return nil }
        guard !hits.contains(where: { $0.contentEncoding == "vision-ocr-text-v1" }) || configuration?.ocr == true else { return nil }
        if version >= 4 {
            guard let configuration,
                  version == 8 ? configuration.pdfOCR : version == 7 ? configuration.ocr : version == 6 ? configuration.localOnly : version == 5 ? (configuration.requiresFinderMetadata || hits.contains { $0.finderMetadata != nil }) : configuration.requiresDateRanges else { return nil }
            if configuration.requiresDateRanges {
                guard configuration.dateReferenceTime != nil,
                      dateResolution.map({ DateRangeTransport.bound($0, to: configuration) }) ?? hits.isEmpty else { return nil }
            } else if dateResolution != nil { return nil }
        } else if configuration != nil || dateResolution != nil { return nil }
        var result = self
        result.roots = paths; result.hits = []
        var seen: Set<HitIdentity> = []
        for hit in hits {
            guard let bound = scope.carrying(hit) else { return nil }
            if seen.insert(bound.identity).inserted { result.hits.append(bound) }
        }
        return result
    }
}

func consumeQuickHandoff(_ candidate: URL) -> [Hit]? {
    consumeQuickHandoffPayload(candidate)?.hits
}

private func quickHandoffHeaderKeys(_ version: Int) -> Set<String> {
    var keys: Set<String> = ["type", "schemaVersion", "selection"]
    if version >= 3 { keys.insert("roots") }
    if version >= 4 { keys.formUnion(["options", "dateResolution"]) }
    if version >= 5 { keys.insert("finderMetadataCapability") }
    if version >= 6 { keys.insert("localContentCapability") }
    if version >= 7 { keys.insert("ocrCapability") }
    if version >= 8 { keys.insert("pdfOCRCapability") }
    return keys
}

func consumeQuickHandoffPayload(_ candidate: URL) -> QuickHandoffPayload? {
    guard let url = validatedQuickHandoff(candidate) else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var total = 0
    var buffer = Data()
    var payload = QuickHandoffPayload()
    var firstLine = true
    func accept(_ line: Data) -> Bool {
        defer { firstLine = false }
        if firstLine, let object = preservedJSONObject(line) as? [String: Any],
           object["type"] as? String == "quickHandoff" {
            guard let version = object["schemaVersion"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), [2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0].contains(version.doubleValue),
                  !DateRangeTransport.hasDuplicateKeys(line),
                  Set(object.keys) == quickHandoffHeaderKeys(version.intValue),
                  version.intValue < 5 || FinderMetadataSnapshot.supportsCapability(object["finderMetadataCapability"]),
                  version.intValue < 6 || SearchConfiguration.supportsLocalContentCapability(object["localContentCapability"]),
                  version.intValue < 7 || SearchConfiguration.supportsOCRCapability(object["ocrCapability"]),
                  version.intValue != 8 || SearchConfiguration.supportsPDFOCRCapability(object["pdfOCRCapability"]),
                  let rows = object["selection"] as? [[String: Any]], rows.count <= 20 else { return false }
            if version.intValue >= 3 {
                guard let roots = object["roots"] as? [String], SearchRoots.problem(roots) == nil else { return false }
                payload.roots = roots
            }
            if version.intValue >= 4 {
                guard let pairs = object["options"] as? [[String: String]], pairs.allSatisfy({ Set($0.keys) == ["name", "value"] }) else { return false }
                let items = pairs.map { URLQueryItem(name: $0["name"]!, value: $0["value"]!) }
                guard SearchConfiguration.transportProblem(items) == nil else { return false }
                let configuration = SearchConfiguration.fromQueryItems(items)
                guard version.intValue == 8 ? configuration.pdfOCR : version.intValue == 7 ? configuration.ocr : version.intValue == 6 ? configuration.localOnly : version.intValue == 5 || configuration.requiresDateRanges,
                      !configuration.ocr || version.intValue >= 7,
                      !configuration.pdfOCR || version.intValue == 8,
                      !configuration.localOnly || version.intValue >= 6,
                      !configuration.requiresFinderMetadata || version.intValue >= 5,
                      !configuration.requiresDateRanges || configuration.dateReferenceTime != nil else { return false }
                payload.configuration = configuration
                if !(object["dateResolution"] is NSNull) {
                    guard let raw = object["dateResolution"], let proof = DateRangeTransport.resolution(raw), DateRangeTransport.bound(proof, to: configuration) else { return false }
                    payload.dateResolution = proof
                }
            }
            for row in rows {
                guard Set(row.keys) == ["filesystemPath", "archiveMembers", "archiveMemberBytes"],
                      let path = row["filesystemPath"] as? String,
                      let members = row["archiveMembers"] as? [String],
                      let bytes = row["archiveMemberBytes"] as? [String],
                      bytes.isEmpty || bytes.count == members.count,
                      bytes.allSatisfy({ Data(base64Encoded: $0) != nil }),
                      payload.selection.insert(HitIdentity(filesystemPath: path,
                          archiveMembers: members, archiveMemberBytes: bytes)).inserted else { return false }
            }
            payload.version = version.intValue
            return true
        }
        guard let hit = parseHit(line), payload.version >= 5 || hit.finderMetadata == nil,
              payload.version >= 7 || hit.contentEncoding != "vision-ocr-text-v1",
              hit.contentEncoding != "vision-ocr-text-v1" || payload.configuration?.ocr == true,
              payload.version >= 8 || hit.contentEncoding != "pdfkit-vision-text-v1" else { return false }
        payload.hits.append(hit)
        return true
    }
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumHandoffBytes else { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.count <= maximumHandoffLineBytes, accept(line) else { return nil }
            }
            guard buffer.count <= maximumHandoffLineBytes else { return nil }
        }
    } catch {
        return nil
    }
    if !buffer.isEmpty {
        guard accept(buffer) else { return nil }
    }
    guard payload.selection.isSubset(of: Set(payload.hits.map { $0.identity })) else { return nil }
    guard payload.version != 4 || payload.dateResolution != nil || payload.hits.isEmpty else { return nil }
    if let roots = payload.roots {
        guard Set(payload.hits.map { $0.identity }).count == payload.hits.count,
              payload.hits.allSatisfy({ $0.searchRootBytes != nil && SearchRoots(roots).carrying($0) != nil }) else { return nil }
    }
    if payload.version >= 4 {
        guard let roots = payload.roots, payload.bound(to: roots) != nil else { return nil }
    }
    return payload
}

/// Nur die echten Zusatztasten eines Tastendrucks.
///
/// Caps Lock, Zehnerblock und das Funktionsbit hängen je nach Tastatur mit
/// dran und dürfen ein Kürzel nicht entwerten. Steht EINMAL hier: Die
/// Haupt-App normalisierte, die Schnellsuche prüfte gar nicht — dort lösten
/// deshalb auch ⇧⎋ und ⌥⎋ Abbruch beziehungsweise Beenden aus.
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
        // Ein Formatter pro Export: Die gleiche lokale Zeitzone für alle
        // Zeilen, ohne geteilten veränderlichen Zustand zwischen Exporten.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        func isoTimestamp(_ seconds: Double) -> String {
            formatter.string(from: Date(timeIntervalSince1970: seconds))
        }
        var text = "path,type,isDirectory,size,line,filesystemPath,"
            + "field,value,width,height,modified,created,contentEncoding,documentPage,documentLine,documentPart,documentPartKind,documentParagraph,documentChapter,documentSheet,documentSheetIndex,documentCell,documentValueKind,documentSlide,documentObjectID,documentObjectKind,documentRow,documentColumn,finderTags,finderTagColors,finderComment,finderTagsStatus,finderCommentStatus,ocrBlock,ocrConfidence,ocrRegion\n"
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
            cells.append(csvField(hit.contentEncoding ?? ""))
            cells.append(hit.documentPosition.flatMap { ["pdfPage", "pdfTextPage", "pdfOCR"].contains($0.kind) ? String($0.page) : nil } ?? "")
            cells.append(hit.documentPosition.map { String($0.line) } ?? "")
            cells.append(csvField(hit.documentPosition?.part ?? ""))
            cells.append(csvField(hit.documentPosition?.partKind ?? ""))
            cells.append(hit.documentPosition?.paragraph.map(String.init) ?? "")
            cells.append(hit.documentPosition?.chapter.map(String.init) ?? "")
            cells.append(csvField(hit.documentPosition?.sheet ?? ""))
            cells.append(hit.documentPosition?.sheetIndex.map(String.init) ?? "")
            cells.append(csvField(hit.documentPosition?.cell ?? ""))
            cells.append(csvField(hit.documentPosition?.valueKind ?? ""))
            cells.append(hit.documentPosition?.slide.map(String.init) ?? "")
            cells.append(csvField(hit.documentPosition?.objectID ?? ""))
            cells.append(csvField(hit.documentPosition?.objectKind ?? ""))
            cells.append(hit.documentPosition?.row.map(String.init) ?? "")
            cells.append(hit.documentPosition?.column.map(String.init) ?? "")
            func jsonText(_ value: Any?) -> String {
                guard let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return "" }
                return String(decoding: data, as: UTF8.self)
            }
            cells.append(csvField(jsonText(hit.finderMetadata?.tags?.map { $0.name })))
            cells.append(csvField(jsonText(hit.finderMetadata?.tags?.map { $0.color.map { $0 as Any } ?? NSNull() })))
            cells.append(csvField(hit.finderMetadata?.comment ?? ""))
            cells.append(csvField(hit.finderMetadata?.tagStatus ?? "notCaptured"))
            cells.append(csvField(hit.finderMetadata?.commentStatus ?? "notCaptured"))
            cells.append(hit.documentPosition?.ocrBlock.map(String.init) ?? "")
            cells.append(hit.documentPosition?.ocrConfidence.map { String($0) } ?? "")
            cells.append(csvField(hit.documentPosition?.ocrRegion.map { $0.map { String($0) }.joined(separator: ";") } ?? ""))
            text += cells.joined(separator: ",")
            text += "\n"
        }
        // BOM voran: Ohne sie liest Excel eine UTF-8-Tabelle unter macOS als
        // Latin-1 und zerlegt jeden Umlaut im Dateinamen.
        return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }
}

/// Ein Export pro Instanz. Steuerung und Completion gehören auf Main;
/// Serialisierung und atomarer Dateiaustausch laufen auf einer Worker-Queue.
/// Der unveränderliche Wert hält genau den beim Start gewählten Treffer-/Berichtsstand.
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

enum ResultGroupingMode: String, CaseIterable {
    case none, folder, fileExtension, archive
    var title: String {
        switch self {
        case .none: return "Keine"
        case .folder: return "Ordner"
        case .fileExtension: return "Endung"
        case .archive: return "Quellarchiv"
        }
    }
}

struct ResultGroupKey: Hashable {
    let components: [Data]
    func precedes(_ other: ResultGroupKey) -> Bool {
        for (left, right) in zip(components, other.components) where left != right {
            return left.lexicographicallyPrecedes(right)
        }
        return components.count < other.components.count
    }
}

struct ResultGroup {
    let key: ResultGroupKey
    let title: String
    var hitIndices: [Int]
}

enum ResultTableRow {
    case group(Int), hit(Int)
}

/// Darstellung ohne Suchauswertung: Trefferindices bleiben auf die unveränderte
/// gefilterte Liste bezogen. Rohbytes trennen auch gleich aussehende Archivordner.
struct ResultProjection {
    let mode: ResultGroupingMode
    let hitCount: Int
    private(set) var groups: [ResultGroup] = []
    private(set) var rows: [ResultTableRow] = []
    private var inverse: [Int?] = []
    private(set) var displayedHitCount: Int
    var rowCount: Int { mode == .none ? hitCount : rows.count }

    init(hits: [Hit], mode: ResultGroupingMode, collapsed: Set<ResultGroupKey> = [], root: String = "/") {
        self.mode = mode
        hitCount = hits.count
        displayedHitCount = mode == .none ? hits.count : 0
        guard mode != .none else { return }
        var byKey: [ResultGroupKey: Int] = [:]
        for (index, hit) in hits.enumerated() {
            let (key, title) = Self.group(for: hit, mode: mode, root: root)
            if let group = byKey[key] { groups[group].hitIndices.append(index) }
            else {
                byKey[key] = groups.count
                groups.append(ResultGroup(key: key, title: title, hitIndices: [index]))
            }
        }
        groups.sort {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.key.precedes($1.key) : order == .orderedAscending
        }
        inverse = Array(repeating: nil, count: hits.count)
        for (index, group) in groups.enumerated() {
            rows.append(.group(index))
            guard !collapsed.contains(group.key) else { continue }
            for hitIndex in group.hitIndices {
                inverse[hitIndex] = rows.count
                rows.append(.hit(hitIndex))
                displayedHitCount += 1
            }
        }
    }

    func hitIndex(at row: Int) -> Int? {
        guard row >= 0, row < rowCount else { return nil }
        if mode == .none { return row }
        if case .hit(let index) = rows[row] { return index }
        return nil
    }

    func tableRow(for hitIndex: Int) -> Int? {
        guard hitIndex >= 0, hitIndex < hitCount else { return nil }
        return mode == .none ? hitIndex : inverse[hitIndex]
    }

    func group(at row: Int) -> ResultGroup? {
        guard mode != .none, rows.indices.contains(row), case .group(let index) = rows[row] else { return nil }
        return groups[index]
    }

    static func group(for hit: Hit, mode: ResultGroupingMode, root: String) -> (ResultGroupKey, String) {
        let outer = Data(hit.filesystemPath.utf8)
        let members = hit.archiveMembers.enumerated().map { index, text in
            hit.archiveMemberBytes.indices.contains(index)
                ? Data(base64Encoded: hit.archiveMemberBytes[index]) ?? Data(text.utf8) : Data(text.utf8)
        }
        switch mode {
        case .none: return (ResultGroupKey(components: []), "")
        case .archive:
            return members.isEmpty
                ? (ResultGroupKey(components: []), "Außerhalb von Archiven")
                : (ResultGroupKey(components: [outer]), abbreviateHome(hit.filesystemPath))
        case .folder:
            if var last = members.last {
                while last.last == 47 { last.removeLast() }
                let parent = last.lastIndex(of: 47).map { Data(last[..<$0]) } ?? Data()
                let key = ResultGroupKey(components: [outer] + members.dropLast() + [parent])
                let parts = [abbreviateHome(hit.filesystemPath)] + hit.archiveMembers.dropLast()
                    + (parent.isEmpty ? [] : [String(decoding: parent, as: UTF8.self)])
                return (key, parts.joined(separator: " → "))
            }
            let parent = (hit.filesystemPath as NSString).deletingLastPathComponent
            let title = hit.searchRoot == nil ? hit.folderText(relativeTo: root) : parent
            return (ResultGroupKey(components: [Data(parent.utf8)]), title.isEmpty ? "Suchordner" : abbreviateHome(title))
        case .fileExtension:
            if hit.isDirectory { return (ResultGroupKey(components: []), "Ordner") }
            let pathComponents: [Data] = (members.last ?? outer).split(separator: 47)
            let name = pathComponents.last ?? Data()
            guard let dot = name.lastIndex(of: 46), dot > name.startIndex, dot + 1 < name.endIndex else {
                return (ResultGroupKey(components: [Data()]), "Ohne Endung")
            }
            let raw = Data(name[(dot + 1)...])
            let folded = String(data: raw, encoding: .utf8).map { Data($0.lowercased().utf8) }
                ?? Data(raw.map { (65...90).contains($0) ? $0 + 32 : $0 })
            return (ResultGroupKey(components: [folded]), "." + String(decoding: folded, as: UTF8.self))
        }
    }
}

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

final class ResultFilterRun {
    let runner = SearchRunner()
    private let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("favenio-result-filter-\(ProcessInfo.processInfo.processIdentifier)-" + UUID().uuidString)
    private let workspaceLock = NSLock()
    private var closing = false

    func cancel() { runner.cancel() }

    private func createWorkspace() throws {
        workspaceLock.lock(); defer { workspaceLock.unlock() }
        if closing || runner.isCancelled { throw CocoaError(.userCancelled) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
    }

    private func cleanupWorkspace() {
        workspaceLock.lock(); defer { workspaceLock.unlock() }
        closing = true
        try? FileManager.default.removeItem(at: workspace)
    }

    func stopForTermination(deadline: TimeInterval) {
        runner.stopForTermination(deadline: deadline)
        cleanupWorkspace()
    }

    func start(_ hits: [Hit], query: String, root: String?, dateReferenceTime: String? = nil, frozenDateResolution: Data? = nil,
               onDateResolution: @escaping (Data) -> Void = { _ in },
               completion: @escaping (Set<HitIdentity>?, String?) -> Void) {
        let runner = self.runner
        var timedOut = false
        let timeout = DispatchWorkItem { timedOut = true; runner.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            func finish(_ accepted: Set<HitIdentity>?, _ error: String?) {
                DispatchQueue.global().async {
                    self.cleanupWorkspace()
                    DispatchQueue.main.async {
                        timeout.cancel()
                        completion(accepted, timedOut ? "Ansichtsfilter überschreitet sein Zeitbudget." : error)
                    }
                }
            }
            do {
                guard let cli = findCLI() else { throw NSError(domain: "Favenio", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Der Suchkern wurde nicht gefunden."]) }
                try createWorkspace()
                let file = workspace.appendingPathComponent("results.jsonl")
                guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                       attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                let handle = try FileHandle(forWritingTo: file)
                do {
                    for hit in hits {
                        if runner.isCancelled { throw CocoaError(.userCancelled) }
                        let known = Hit(path: hit.path, kind: hit.kind, line: nil, size: hit.size,
                            filesystemPath: hit.filesystemPath, archiveMembers: hit.archiveMembers,
                            archiveMemberBytes: hit.archiveMemberBytes, isDirectory: hit.isDirectory,
                            width: hit.width, height: hit.height, modified: hit.modified, created: hit.created,
                            contentEncoding: hit.contentEncoding, searchRootBytes: hit.searchRootBytes,
                            finderMetadata: hit.finderMetadata)
                        let data = jsonlData(for: [known])
                        guard data.count <= SearchRunner.recordByteLimit else { throw NSError(domain: "Favenio", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Ein Treffer überschreitet die Filter-Recordgrenze."]) }
                        try handle.write(contentsOf: data)
                    }
                    try handle.close()
                } catch { try? handle.close(); throw error }
                if runner.isCancelled { throw CocoaError(.userCancelled) }
                var accepted: Set<HitIdentity> = []
                var proofError: String?
                let arguments = ["-u", cli, "--filter-results=" + file.path, "--criteria-json=" + query]
                    + (root.map { ["--results-root=" + $0] } ?? []) + DateRangeTransport.referenceArguments(dateReferenceTime) + DateRangeTransport.frozenArguments(frozenDateResolution)
                runner.start(arguments: arguments,
                    onBatch: { matches, _ in accepted.formUnion(matches.map { $0.identity }) },
                    onDateResolution: { data in
                        var configuration = SearchConfiguration(); configuration.criteriaJSON = query; configuration.dateReferenceTime = dateReferenceTime
                        if DateRangeTransport.bound(data, to: configuration) { onDateResolution(data) }
                        else { proofError = "Datumsbeleg passt nicht zum Ansichtsfilter."; runner.cancel() }
                    },
                    completion: { exit in
                        if proofError == nil && exit.reason == .exit && [0, 1].contains(exit.status) {
                            finish(accepted, nil)
                        } else {
                            finish(nil, proofError ?? exit.errorMessage ?? "Ansichtsfilter abgebrochen oder fehlgeschlagen.")
                        }
                    })
            } catch { finish(nil, error.localizedDescription) }
        }
    }
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
