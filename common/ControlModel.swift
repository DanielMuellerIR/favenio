import Foundation
import CoreFoundation

struct ControlSearchInput {
    let pattern: String
    let roots: [String]
    var rootBytes: [Data]? = nil
    var root: String { roots.count == 1 ? roots[0] : "" }
    let options: SearchConfiguration
    init(pattern: String, root: String, options: SearchConfiguration) {
        self.init(pattern: pattern, roots: [root], options: options)
    }
    init(pattern: String, roots: [String], options: SearchConfiguration) {
        self.pattern = pattern; self.roots = roots; self.options = options
    }
    var object: [String: Any] {
        var value: [String: Any] = ["pattern": pattern,
            "options": options.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }]
        if let rootBytes { value["schemaVersion"] = 8; value["roots"] = roots; value["rootBytes"] = rootBytes.map { $0.base64EncodedString() } }
        else if options.pdfOCR { value["schemaVersion"] = 7; value["roots"] = roots }
        else if options.ocr { value["schemaVersion"] = 6; value["roots"] = roots }
        else if options.localOnly { value["schemaVersion"] = 5; value["roots"] = roots }
        else if options.requiresFinderMetadata { value["schemaVersion"] = 4; value["roots"] = roots }
        else if options.requiresDateRanges { value["schemaVersion"] = 3; value["roots"] = roots }
        else if roots.count == 1 { value["root"] = roots[0] }
        else { value["schemaVersion"] = 2; value["roots"] = roots }
        return value
    }
    static func decode(_ value: Any?) throws -> ControlSearchInput {
        guard let object = value as? [String: Any],
              let pattern = object["pattern"] as? String, !pattern.utf8.contains(0),
              let pairs = object["options"] as? [[String: String]] else {
            throw SearchControlFailure(code: "invalidRequest", message: "Konfiguration braucht Muster, Suchbereiche und Optionen.")
        }
        let roots: [String]
        if Set(object.keys) == ["pattern", "root", "options"], let root = object["root"] as? String {
            roots = [root]
            if let problem = SearchRoots.problem(roots, limited: false) {
                throw SearchControlFailure(code: "invalidRequest", message: problem)
            }
        } else if (Set(object.keys) == ["schemaVersion", "pattern", "roots", "options"] || Set(object.keys) == ["schemaVersion", "pattern", "roots", "rootBytes", "options"]),
                  [2, 3, 4, 5, 6, 7, 8].contains(SearchControlWire.integer(object["schemaVersion"]) ?? 0), let paths = object["roots"] as? [String],
                  SearchRoots.problem(paths, rawBytes: object["rootBytes"].flatMap { SearchRoots.decodeRawPaths($0, paths: paths) }) == nil { roots = paths }
        else { throw SearchControlFailure(code: "invalidRequest", message: "Ungültige oder zu große Suchbereichsliste (Konfigurationsformat 2).") }
        let known = Set(["mode", "content", "only", "regex", "case", "archives", "hidden", "exact", "literal-wildcards", "field", "exclude", "term", "criteria", "encoding", "date-ranges", "date-reference-time", "finder-metadata", "local-only", "ocr", "pdf-ocr"] + SearchConfiguration.pixelKeys + FactFilterOption.all.map { $0.key })
        let booleans = Set(["content", "regex", "case", "archives", "hidden", "exact", "literal-wildcards", "finder-metadata", "local-only", "ocr", "pdf-ocr"])
        var seen = Set<String>()
        var items: [URLQueryItem] = []
        for pair in pairs {
            guard Set(pair.keys) == ["name", "value"], let name = pair["name"], let text = pair["value"], !text.utf8.contains(0), known.contains(name),
                  name == "exclude" || name == "term" || seen.insert(name).inserted,
                  !booleans.contains(name) || ["0", "1"].contains(text),
                  name != "mode" || SearchTextMode(rawValue: text) != nil,
                  name != "only" || ["both", "files", "dirs"].contains(text),
                  name != "field" || metadataFieldList().contains(text),
                  name != "encoding" || SearchTextEncoding(rawValue: text) != nil,
                  !["term", "exclude"].contains(name) || (!text.isEmpty && !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })) else {
                throw SearchControlFailure(code: "invalidRequest", message: "Unbekannte, doppelte oder ungültige Suchoption.")
            }
            items.append(URLQueryItem(name: name, value: text))
        }
        let options = SearchConfiguration.fromQueryItems(items)
        guard !options.requiresDateRanges || [3, 4, 5, 6, 7, 8].contains(SearchControlWire.integer(object["schemaVersion"]) ?? 0),
              options.dateReferenceTime == nil || options.requiresDateRanges else {
            throw SearchControlFailure(code: "invalidRequest", message: "Kalenderbereiche benötigen Konfigurationsformat 3.")
        }
        guard !options.requiresFinderMetadata || [4, 5, 6, 7, 8].contains(SearchControlWire.integer(object["schemaVersion"]) ?? 0) else {
            throw SearchControlFailure(code: "invalidRequest", message: "Finder-Eigenschaften benötigen Konfigurationsformat 4.")
        }
        guard !options.localOnly || [5, 6, 7, 8].contains(SearchControlWire.integer(object["schemaVersion"]) ?? 0) else {
            throw SearchControlFailure(code: "invalidRequest", message: "Lokale Inhalte benötigen Konfigurationsformat 5.")
        }
        guard !options.pdfOCR || (SearchControlWire.integer(object["schemaVersion"]) ?? 0) >= 7 else { throw SearchControlFailure(code: "invalidRequest", message: "PDF-OCR benötigt Konfigurationsformat 7.") }
        guard !options.ocr || (SearchControlWire.integer(object["schemaVersion"]) ?? 0) >= 6 else {
            throw SearchControlFailure(code: "invalidRequest", message: "OCR benötigt Konfigurationsformat 6.")
        }
        if let problem = CriteriaTransport.problem(items) {
            throw SearchControlFailure(code: "invalidRequest", message: problem)
        }
        guard options.metadataField == nil || options.mode == .metadata else {
            throw SearchControlFailure(code: "invalidRequest", message: "Ein Metadatenfeld braucht den Metadatenmodus.")
        }
        var result = ControlSearchInput(pattern: pattern, roots: roots, options: options)
        if let raw = object["rootBytes"] {
            guard SearchControlWire.integer(object["schemaVersion"]) == 8, let values = raw as? [String], values.count == roots.count else {
                throw SearchControlFailure(code: "invalidRequest", message: "POSIX-Wurzeln brauchen Konfigurationsformat 8.")
            }
            let data = values.compactMap { Data(base64Encoded: $0) }
            guard data.count == roots.count, Set(data).count == data.count,
                  zip(zip(data, values), roots).allSatisfy({ pair in
                      let ((bytes, text), path) = pair
                      return bytes.first == 47 && !bytes.contains(0) && bytes.count <= 4096 && bytes.base64EncodedString() == text && String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(path.utf8)
                  }) else { throw SearchControlFailure(code: "invalidRequest", message: "Ungültige POSIX-Wurzeln.") }
            #if os(macOS)
            guard data.allSatisfy({ String(data: $0, encoding: .utf8) != nil }) else {
                throw SearchControlFailure(code: "unsupported", message: "Nicht als UTF-8 lesbare Linux-Suchwurzeln können in AppKit nicht übernommen werden. Den Stand unter Linux öffnen.")
            }
            #endif
            result.rootBytes = data
        } else if SearchControlWire.integer(object["schemaVersion"]) == 8 {
            throw SearchControlFailure(code: "invalidRequest", message: "POSIX-Wurzeln fehlen.")
        }
        return result
    }
}

struct ControlledSearchRun {
    let id: String
    let startedAt: Double
    let input: ControlSearchInput
    init(id: String = UUID().uuidString, startedAt: Double = Date().timeIntervalSince1970, input: ControlSearchInput) {
        self.id = id; self.startedAt = startedAt; self.input = input
    }
    var state = "running"
    var warningCount = 0
    var error: String?
    var origin = "live"
}


enum ControlIdentity {
    static func object(_ identity: HitIdentity) -> [String: Any] {
        var result: [String: Any] = ["filesystemPath": identity.filesystemPath, "archiveMembers": identity.archiveMembers,
         "archiveMemberBytes": identity.archiveMemberBytes]
        if let bytes = identity.filesystemPathBytes { result["filesystemPathBytes"] = bytes.base64EncodedString() }
        return result
    }
    static func parse(_ value: Any?) throws -> HitIdentity {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["filesystemPath", "archiveMembers", "archiveMemberBytes", "filesystemPathBytes"]),
              let path = object["filesystemPath"] as? String,
              let members = object["archiveMembers"] as? [String], let bytes = object["archiveMemberBytes"] as? [String],
              bytes.isEmpty || bytes.count == members.count,
              bytes.allSatisfy({ Data(base64Encoded: $0) != nil }) else {
            throw SearchControlFailure(code: "invalidRequest", message: "Ungültige Trefferidentität.")
        }
        var raw: Data?
        if let value = object["filesystemPathBytes"] {
            guard let text = value as? String, let data = Data(base64Encoded: text), data.first == 47, !data.contains(0),
                  data.base64EncodedString() == text, String(decoding: data, as: UTF8.self).utf8.elementsEqual(path.utf8) else {
                throw SearchControlFailure(code: "invalidRequest", message: "Ungültige POSIX-Trefferidentität.")
            }
            raw = data
        }
        return HitIdentity(filesystemPath: path, archiveMembers: members, archiveMemberBytes: bytes, filesystemPathBytes: raw)
    }
}
