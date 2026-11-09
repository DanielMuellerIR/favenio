import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    #if !os(macOS)
    return FileManager.default.fileExists(atPath: root) ? nil : "Suchbereich fehlt: " + abbreviateHome(root)
    #else
    // Auf macOS 12 prüft der Kern den Pfad; die lokale Politik wird dort vor Zugriff abgewiesen.
    guard #available(macOS 13, *) else { return nil }
    guard let present = LocalContentAccess.withoutMaterialization(allowLegacy: false, {
        var information = stat()
        return stat(root, &information) == 0 || errno == EDEADLK || errno == EAGAIN
    }) else { return "Suchbereich ohne Materialisierung nicht prüfbar: " + abbreviateHome(root) }
    return present ? nil : "Suchbereich fehlt: " + abbreviateHome(root)
    #endif
}

struct SearchRoots {
    static let maximumCount = 16
    static let maximumPathBytes = 4096
    static let maximumBytes = 65_536
    let paths: [String]
    let bytes: [Data]
    init(_ paths: [String], rawBytes: [Data]? = nil) { self.paths = paths; bytes = rawBytes ?? paths.map { Data($0.utf8) } }
    static func problem(_ paths: [String], limited: Bool = true, rawBytes: [Data]? = nil) -> String? {
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) else {
            return "Mindestens ein absoluter Suchbereich ist erforderlich."
        }
        let pathBytes = rawBytes ?? paths.map { Data($0.utf8) }
        if limited && (paths.count > maximumCount || pathBytes.contains(where: { $0.count > maximumPathBytes })
            || pathBytes.reduce(0, { $0 + $1.count }) > maximumBytes) {
            return "Suchbereiche sind auf 16 Einträge mit je 4096 und insgesamt 65.536 UTF-8-Bytes begrenzt."
        }
        guard Set(rawBytes ?? paths.map { Data($0.utf8) }).count == paths.count else {
            return "Ein Suchbereich ist mehrfach angegeben."
        }
        return nil
    }
    static func decodeRawPaths(_ value: Any, paths: [String]) -> [Data]? {
        guard let values = value as? [String], values.count == paths.count else { return nil }
        let data = values.compactMap { Data(base64Encoded: $0) }
        guard data.count == paths.count, Set(data).count == data.count,
              zip(zip(data, values), paths).allSatisfy({ pair in
                  let ((bytes, text), path) = pair
                  return bytes.first == 47 && !bytes.contains(0) && bytes.count <= 4096 && bytes.base64EncodedString() == text && String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(path.utf8)
              }) else { return nil }
        return data
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

struct SearchTemplate: Equatable {
    var name: String
    var pattern: String
    /// nil bedeutet: Die Vorlage speichert keinen Suchbereich.
    var roots: [String]?
    var rootBytes: [Data]? = nil
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
            && (lhs.rootBytes ?? lhs.roots?.map { Data($0.utf8) }) == (rhs.rootBytes ?? rhs.roots?.map { Data($0.utf8) })
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
    static let version = 9
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
        let portable = templates.contains { $0.rootBytes != nil }
        let multiple = portable || pdfOCR || ocr || local || finder || dates || templates.contains { ($0.roots?.count ?? 0) > 1 }
        for template in templates {
            if let roots = template.roots, let problem = SearchRoots.problem(roots, limited: multiple, rawBytes: template.rootBytes) {
                throw SearchTemplateError(description: problem)
            }
            if let problem = CriteriaTransport.problem(template.configuration.queryItems) {
                throw SearchTemplateError(description: problem)
            }
        }
        let entries: [[String: Any]] = templates.map { template in
            var entry: [String: Any] = ["name": template.name, "pattern": template.pattern,
             multiple ? "roots" : "root": multiple ? (template.roots as Any? ?? NSNull()) : (template.root as Any? ?? NSNull()),
             "options": encodeOptions(template.configuration)]
            if let raw = template.rootBytes { entry["rootBytes"] = raw.map { $0.base64EncodedString() } }
            return entry
        }
        let fileVersion = portable ? 9 : pdfOCR ? 8 : ocr ? 7 : local ? 6 : finder ? 5 : dates ? 4 : (multiple ? 3 : (templates.contains { $0.configuration.requiresTransportVersion2 } ? 2 : 1))
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
                guard Set(entry.keys).subtracting(fileVersion >= 9 ? ["rootBytes"] : []) == ["name", "pattern", rootKey, "options"],
                      let pattern = entry["pattern"] as? String, !pattern.utf8.contains(0),
                      entry["options"] is String,
                      entry[rootKey] is NSNull || (fileVersion >= 3
                          ? (entry[rootKey] as? [String]).map { paths in
                              let raw = entry["rootBytes"].flatMap { SearchRoots.decodeRawPaths($0, paths: paths) }
                              return SearchRoots.problem(paths, rawBytes: raw) == nil
                          }
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
            var template = SearchTemplate(
                name: name,
                pattern: entry["pattern"] as? String ?? "",
                roots: fileVersion >= 3 ? entry["roots"] as? [String] : (entry["root"] as? String).map { [$0] },
                configuration: configuration)
            if let raw = entry["rootBytes"] {
                guard let roots = template.roots, let bytes = SearchRoots.decodeRawPaths(raw, paths: roots) else { throw SearchTemplateError(description: "Ungültige POSIX-Suchwurzeln der Vorlage.") }
                #if os(macOS)
                guard bytes.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) else { throw SearchTemplateError(description: "Vorlage enthält nicht als UTF-8 lesbare Linux-Suchwurzeln. Unter Linux öffnen.") }
                #endif
                template.rootBytes = bytes
            }
            return template
        }
    }
}

/// Liest und schreibt die Vorlagendatei — lokal, außerhalb jedes
/// Repositorys: `~/Library/Application Support/Favenio/search-templates.json`.
/// Geschrieben wird atomar; der Ordner entsteht beim ersten Sichern.
final class SearchTemplateStore {
    static var defaultURL: URL {
        #if os(Linux)
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? NSHomeDirectory() + "/.local/share"
        let support = URL(fileURLWithPath: base, isDirectory: true)
        #else
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        #endif
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
