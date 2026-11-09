import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    var filesystemPathBytes: Data? = nil
    var filesystemPathData: Data { filesystemPathBytes ?? Data(filesystemPath.utf8) }
    var exportedPathBytes: Data {
        guard filesystemPathBytes != nil else { return Data(path.utf8) }
        var result = filesystemPathData
        for (index, member) in archiveMembers.enumerated() {
            result.append(Data("!/".utf8))
            result.append(index < archiveMemberBytes.count ? (Data(base64Encoded: archiveMemberBytes[index]) ?? Data(member.utf8)) : Data(member.utf8))
        }
        return result
    }

    var searchRoot: String? { searchRootBytes.map { String(decoding: $0, as: UTF8.self) } }
    var documentPosition: DocumentPosition? { documentEvidence?.position }
    var documentSourceGeneration: ContentSourceGeneration? { documentEvidence?.generation }

    /// Anzeige und Suchbelege können sich ändern; das gefundene Objekt wird
    /// allein durch Dateisystempfad und die einzelnen Archivstufen bestimmt.
    var identity: HitIdentity {
        HitIdentity(filesystemPath: filesystemPath,
                    archiveMembers: archiveMembers,
                    archiveMemberBytes: archiveMemberBytes, filesystemPathBytes: filesystemPathBytes)
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

}

/// Stabile Trefferidentität. Ein einzelner Name darf selbst `!/` enthalten;
/// deshalb niemals die Archivstufen zu einem Identitätstext zusammenfügen.
struct HitIdentity: Hashable {
    let filesystemPath: String
    let archiveMembers: [String]
    let archiveMemberBytes: [String]
    let filesystemPathBytes: Data?

    init(filesystemPath: String, archiveMembers: [String],
         archiveMemberBytes: [String] = [], filesystemPathBytes: Data? = nil) {
        self.filesystemPath = filesystemPath
        self.archiveMembers = archiveMembers
        self.archiveMemberBytes = archiveMemberBytes
        self.filesystemPathBytes = filesystemPathBytes
    }

    // Swift-Strings setzen NFC/NFD gleich; eine Dateiidentität behält ihre Originalbytes.
    static func == (lhs: HitIdentity, rhs: HitIdentity) -> Bool {
        (lhs.filesystemPathBytes ?? Data(lhs.filesystemPath.utf8)) == (rhs.filesystemPathBytes ?? Data(rhs.filesystemPath.utf8))
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
        hasher.combine(filesystemPathBytes ?? Data(filesystemPath.utf8))
        for values in [archiveMembers, archiveMemberBytes] {
            hasher.combine(values.count)
            for value in values { Self.hashOriginalText(value, into: &hasher) }
        }
    }
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
    if kind == "hitV2" {
        guard Set(dict.keys) == ["type", "schemaVersion", "hit"],
              DateRangeTransport.integer(dict["schemaVersion"]) == 2,
              let raw = JSONByteSlices.member("hit", in: lineData),
              let body = preservedJSONObject(raw) as? [String: Any], body["type"] as? String != "hitV2",
              body["filesystemPathBytes"] is String else { return nil }
        return parseSearchLine(raw)
    }
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
        if let raw = dict["searchRootPathBytes"] {
            guard let value = raw as? String, let data = Data(base64Encoded: value), !data.isEmpty, !data.contains(0),
                  data.first == 47, data.base64EncodedString() == value,
                  String(decoding: data, as: UTF8.self).utf8.elementsEqual(text.utf8) else { return nil }
            rootBytes = data
        }
    }
    var rawFilesystemPath: Data?
    if let raw = dict["filesystemPathBytes"] {
        guard let text = raw as? String, let bytes = Data(base64Encoded: text), !bytes.isEmpty,
              !bytes.contains(0), bytes.base64EncodedString() == text,
              String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(filesystemPath.utf8) else { return nil }
        #if os(macOS)
        guard String(data: bytes, encoding: .utf8) != nil else { return nil }
        #endif
        rawFilesystemPath = bytes
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
                    searchRootBytes: rootBytes, finderMetadata: finderMetadata, filesystemPathBytes: rawFilesystemPath))
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
        let outer = hit.filesystemPathData
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
        return hits.reduce(into: Data()) { $0.append($1.exportedPathBytes); $0.append(10) }
    case .pathsNUL:
        return hits.reduce(into: Data()) { $0.append($1.exportedPathBytes); $0.append(0) }
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
        let portable = hits.contains { $0.filesystemPathBytes != nil || $0.documentPosition?.readerOverride != nil }
        if portable { text = String(text.dropLast()) + ",filesystemPathBytes,searchRootPathBytes,documentReader\n" }
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
            if portable {
                cells.append(hit.filesystemPathBytes?.base64EncodedString() ?? "")
                cells.append(hit.searchRootBytes?.base64EncodedString() ?? "")
                cells.append(csvField(hit.documentPosition?.reader ?? ""))
            }
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

func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

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

func mergingSortedValues<Value>(_ existing: [Value], _ fresh: [Value],
                                using comparator: (Value, Value) -> Bool) -> [Value] {
    let incoming = fresh.sorted(by: comparator)
    var result: [Value] = []
    result.reserveCapacity(existing.count + incoming.count)
    var left = existing.startIndex, right = incoming.startIndex
    while left < existing.endIndex && right < incoming.endIndex {
        if comparator(incoming[right], existing[left]) {
            result.append(incoming[right]); right += 1
        } else {
            result.append(existing[left]); left += 1
        }
    }
    result.append(contentsOf: existing[left...])
    result.append(contentsOf: incoming[right...])
    return result
}
