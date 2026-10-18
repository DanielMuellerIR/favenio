import Foundation
import CoreFoundation

// Schneidet Werte aus bereits syntaxgeprüftem JSON aus. Ein Dictionary-Roundtrip
// würde ursprüngliche Zahlenlexeme und führendes U+FEFF vor der Prüfung verlieren.
enum JSONByteSlices {
    private static func values(_ data: Data, object: Bool) -> [(String?, Data)]? {
        let bytes = Array(data)
        var index = 0
        func whitespace() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        func stringEnd() -> Bool {
            guard index < bytes.count, bytes[index] == 34 else { return false }
            index += 1
            while index < bytes.count {
                if bytes[index] == 34 { index += 1; return true }
                if bytes[index] == 92 { index += 1 }
                index += 1
            }
            return false
        }
        whitespace()
        guard index < bytes.count, bytes[index] == (object ? 123 : 91) else { return nil }
        index += 1
        var result: [(String?, Data)] = []
        var names = Set<Data>()
        while index < bytes.count {
            whitespace()
            if index < bytes.count, bytes[index] == (object ? 125 : 93) { return result }
            var name: String?
            if object {
                let start = index
                guard stringEnd(), let key = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])),
                      names.insert(Data(key.utf8)).inserted else { return nil }
                name = key
                whitespace()
                guard index < bytes.count, bytes[index] == 58 else { return nil }
                index += 1; whitespace()
            }
            let start = index
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 { guard stringEnd() else { return nil }; continue }
                if depth == 0 && (byte == 44 || byte == 125 || byte == 93) { break }
                if byte == 123 || byte == 91 { depth += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                guard depth >= 0, depth <= 64 else { return nil }
                index += 1
            }
            guard index > start, depth == 0 else { return nil }
            result.append((name, Data(bytes[start..<index])))
            guard index < bytes.count else { return nil }
            if bytes[index] == 44 { index += 1 }
            else if bytes[index] == (object ? 125 : 93) { return result }
            else { return nil }
        }
        return nil
    }
    static func member(_ name: String, in data: Data) -> Data? {
        values(data, object: true)?.first { $0.0 == name }?.1
    }
    static func items(_ data: Data) -> [Data]? { values(data, object: false)?.map { $0.1 } }
}

struct FinderTagValue: Hashable {
    let nameBytes: Data
    let rawBytes: Data
    let color: Int?
    var name: String { String(decoding: nameBytes, as: UTF8.self) }
    var raw: String { String(decoding: rawBytes, as: UTF8.self) }
}

// Prüft ausschließlich den Datenvertrag. Lesen und Suchauswertung bleiben im Python-Kern.
struct FinderMetadataSnapshot: Hashable {
    static let maximumBytes = 256 * 1024
    let json: Data
    let generation: ContentSourceGeneration?
    let tags: [FinderTagValue]?
    let commentBytes: Data?
    let tagStatus: String?
    let commentStatus: String?
    var comment: String? { commentBytes.map { String(decoding: $0, as: UTF8.self) } }
    // JSON-Escapierung und Einrückung ändern den erfassten Wert nicht.
    // Namen/Kommentare bleiben dennoch über ihre Originalbytes unterschieden.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.generation == rhs.generation && lhs.tags == rhs.tags && lhs.commentBytes == rhs.commentBytes
            && lhs.tagStatus == rhs.tagStatus && lhs.commentStatus == rhs.commentStatus
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(generation); hasher.combine(tags); hasher.combine(commentBytes)
        hasher.combine(tagStatus); hasher.combine(commentStatus)
    }
    var object: Any { preservedJSONObject(json)! }
    static func supportsCapability(_ value: Any?) -> Bool { integer(value) == 1 }

    static func statusTitle(_ status: String?) -> String {
        switch status {
        case "available": return "Leer"
        case "absent": return "Nicht gespeichert"
        case "unreadable": return "Nicht lesbar"
        case "invalid": return "Ungültiger Wert"
        case "limited": return "Grenze überschritten"
        case "unsupported": return "Nicht unterstützt"
        case "notApplicable": return "Nicht anwendbar"
        case "sourceChanged": return "Quelle verändert"
        default: return "Nicht erfasst"
        }
    }
    var tagsText: String { tags.map { $0.isEmpty ? "Leer" : $0.map(\.name).joined(separator: ", ") } ?? Self.statusTitle(tagStatus) }
    var commentText: String { comment.map { $0.isEmpty ? "Leer" : $0 } ?? Self.statusTitle(commentStatus) }

    private static func integersOnly(_ data: Data) -> Bool {
        let bytes = Array(data); var quoted = false; var escaped = false; var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                index += 1; continue
            }
            if byte == 34 { quoted = true; index += 1; continue }
            if byte == 45 || (48...57).contains(byte) {
                let start = index
                while index < bytes.count && ((48...57).contains(bytes[index]) || [45, 43, 46, 101, 69].contains(bytes[index])) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                if token.range(of: "\\A-?[0-9]+\\z", options: .regularExpression) == nil { return false }
            } else { index += 1 }
        }
        return true
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= 7,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    static func parse(_ data: Data, size: Int? = nil, modified: Double? = nil, inArchive: Bool = false) -> Self? {
        guard data.count <= maximumBytes, integersOnly(data), !DateRangeTransport.hasDuplicateKeys(data),
              let object = preservedJSONObject(data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "sourceGeneration", "fields"], integer(object["schemaVersion"]) == 1,
              let fields = object["fields"] as? [String: Any], Set(fields.keys).isSubset(of: ["finderTags", "finderComment"]) else { return nil }
        var generation: ContentSourceGeneration?
        if !(object["sourceGeneration"] is NSNull) {
            guard !inArchive, let raw = object["sourceGeneration"] as? [String: String],
                  Set(raw.keys) == ["device", "inode", "size", "modifiedNS", "changedNS"],
                  raw.values.allSatisfy({ $0.utf8.count <= 32 && $0.range(of: "\\A(?:0|-?[1-9][0-9]*)\\z", options: .regularExpression) != nil }),
                  ["device", "inode", "size"].allSatisfy({ !raw[$0]!.hasPrefix("-") }) else { return nil }
            if let size, raw["size"] != String(size) { return nil }
            if let modified {
                guard modified.isFinite, let nanoseconds = Double(raw["modifiedNS"]!),
                      abs(nanoseconds / 1e9 - modified) <= modified.ulp else { return nil }
            }
            generation = ContentSourceGeneration(device: raw["device"]!, inode: raw["inode"]!, size: raw["size"]!,
                                                  modifiedNS: raw["modifiedNS"]!, changedNS: raw["changedNS"]!)
        }
        let unknown: Set<String> = ["absent", "unreadable", "invalid", "limited", "unsupported", "notApplicable", "sourceChanged"]
        var tags: [FinderTagValue]?; var comment: Data?; var statuses: [String: String] = [:]
        for (field, raw) in fields {
            guard let record = raw as? [String: Any], let status = record["status"] as? String else { return nil }
            statuses[field] = status
            if unknown.contains(status) {
                guard Set(record.keys) == ["status"] else { return nil }
                continue
            }
            guard status == "available", generation != nil else { return nil }
            if field == "finderComment" {
                guard Set(record.keys) == ["status", "value"], let value = record["value"] as? String,
                      value.utf8.count <= 32768, !value.utf8.contains(0) else { return nil }
                comment = Data(value.utf8)
            } else {
                guard Set(record.keys) == ["status", "values"], let values = record["values"] as? [[String: Any]], values.count <= 256 else { return nil }
                var parsed: [FinderTagValue] = []
                for value in values {
                    guard Set(value.keys) == ["name", "raw", "color"], let raw = value["raw"] as? String,
                          let name = value["name"] as? String, !raw.isEmpty, raw.utf8.count <= 1024, !raw.utf8.contains(0) else { return nil }
                    let bytes = Data(raw.utf8); var expectedName = bytes; var expectedColor: Int?
                    if bytes.count >= 2 && bytes[bytes.count - 2] == 10 && (48...55).contains(bytes[bytes.count - 1]) {
                        expectedName = Data(bytes.dropLast(2)); expectedColor = Int(bytes[bytes.count - 1] - 48)
                    }
                    guard !expectedName.isEmpty, expectedName == Data(name.utf8) else { return nil }
                    let color: Int?
                    if value["color"] is NSNull { color = nil }
                    else { guard let number = integer(value["color"]) else { return nil }; color = number }
                    guard color == expectedColor else { return nil }
                    parsed.append(FinderTagValue(nameBytes: Data(name.utf8), rawBytes: bytes, color: color))
                }
                tags = parsed
            }
        }
        return Self(json: data, generation: generation, tags: tags, commentBytes: comment,
                    tagStatus: statuses["finderTags"], commentStatus: statuses["finderComment"])
    }
}
