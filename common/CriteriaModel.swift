import Foundation
import CoreFoundation

struct CriteriaNode: Equatable {
    var id = UUID().uuidString
    var groupOperator: String? = nil
    var field = "name"
    var matchOperator = "contains"
    var value = ""
    var caseSensitive = false
    var negate = false
    var metadataField: String? = nil
    var children: [CriteriaNode] = []
    var dateRange: DateRangeSpec? = nil
    var hasDateRanges: Bool { dateRange != nil || children.contains { $0.hasDateRanges } }
    var hasFinderFields: Bool { ["finderTags", "finderComment"].contains(field) || children.contains { $0.hasFinderFields } }

    var object: [String: Any] {
        if let groupOperator {
            return ["id": id, "op": groupOperator, "children": children.map { $0.object }]
        }
        var result: [String: Any] = ["id": id, "field": field,
                                   "operator": matchOperator, "value": dateRange.map { $0.object as Any } ?? value]
        if caseSensitive { result["caseSensitive"] = true }
        if negate { result["negate"] = true }
        if let metadataField { result["metadataField"] = metadataField }
        return result
    }

    var conditionCount: Int {
        groupOperator == nil ? 1 : children.reduce(0) { $0 + $1.conditionCount }
    }
    var identifiers: [String] { [id] + children.flatMap { $0.identifiers } }

    static func parse(_ object: Any, depth: Int = 1) -> CriteriaNode? {
        guard depth <= 16, let object = object as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 64,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        if object["children"] != nil || object["op"] != nil {
            guard Set(object.keys) == ["id", "op", "children"],
                  let op = object["op"] as? String, ["and", "or"].contains(op),
                  let raw = object["children"] as? [Any], raw.count <= 256 else { return nil }
            let children = raw.compactMap { parse($0, depth: depth + 1) }
            guard children.count == raw.count else { return nil }
            return CriteriaNode(id: id, groupOperator: op, children: children)
        }
        let required = Set(["id", "field", "operator", "value"])
        guard required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(["caseSensitive", "negate", "metadataField"])),
              let field = object["field"] as? String,
              CriteriaCatalog.fields.contains(field),
              let op = object["operator"] as? String,
              CriteriaCatalog.operators(for: field).contains(op) else { return nil }
        let dateRange = object["value"].flatMap { DateRangeSpec.parse($0) }
        guard object["value"] is String || (["modified", "created"].contains(field) && dateRange != nil) else { return nil }
        let value = object["value"] as? String ?? ""
        for key in ["caseSensitive", "negate"] where object[key] != nil {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        }
        if let metadataField = object["metadataField"] {
            guard field == "metadata", let tag = metadataField as? String,
                  metadataFieldList().contains(tag) else { return nil }
        }
        if CriteriaCatalog.numericFields.contains(field), object["caseSensitive"] as? Bool == true { return nil }
        return CriteriaNode(id: id, field: field, matchOperator: op, value: value,
                            caseSensitive: object["caseSensitive"] as? Bool ?? false,
                            negate: object["negate"] as? Bool ?? false,
                            metadataField: object["metadataField"] as? String, dateRange: dateRange)
    }

    static func fromJSON(_ text: String) -> CriteriaNode? {
        guard text.utf8.count <= 64 * 1024, !DateRangeTransport.hasDuplicateKeys(Data(text.utf8)),
              let object = preservedJSONObject(Data(text.utf8)),
              let document = object as? [String: Any],
              Set(document.keys) == ["schemaVersion", "root"],
              let version = document["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), [1.0, 2.0, 3.0].contains(version.doubleValue) else { return nil }
        guard let node = document["root"].flatMap({ parse($0) }),
              node.identifiers.count <= 256, node.conditionCount <= 128,
              Set(node.identifiers).count == node.identifiers.count,
              !node.hasDateRanges || version.intValue >= 2,
              !node.hasFinderFields || version.intValue == 3 else { return nil }
        return node
    }

    var json: String {
        let object: [String: Any] = ["schemaVersion": hasFinderFields ? 3 : hasDateRanges ? 2 : 1, "root": self.object]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum CriteriaCatalog {
    static let fields = ["name", "extension", "relativePath", "content", "metadata", "finderTags", "finderComment",
                         "size", "modified", "created", "width", "height"]
    static let numericFields: Set<String> = ["size", "modified", "created", "width", "height"]
    static func operators(for field: String) -> [String] {
        numericFields.contains(field) ? ["atLeast", "atMost", "equals"] : ["contains", "equals", "glob", "regex"]
    }
    static func operatorTitle(_ key: String, field: String) -> String {
        if ["modified", "created"].contains(field) {
            let titles = ["atLeast": "am oder nach", "atMost": "am oder vor",
                          "not-atLeast": "vor", "not-atMost": "nach"]
            if let title = titles[key] { return title }
        }
        return labels[key] ?? key
    }
    static let labels = ["name": "Name", "extension": "Endung", "relativePath": "Relativer Pfad",
                         "contains": "enthält", "equals": "ist genau", "glob": "passt zu Glob",
                         "regex": "passt zu Regex", "not-contains": "enthält nicht",
                         "not-equals": "ist nicht", "not-glob": "passt nicht zu Glob",
                         "not-regex": "passt nicht zu Regex",
                         "content": "Inhalt", "metadata": "Metadaten", "finderTags": "Finder-Tag", "finderComment": "Finder-Kommentar", "size": "Dateigröße",
                         "modified": "Geändert", "created": "Erstellt", "width": "Bildbreite", "height": "Bildhöhe",
                         "atLeast": "ist mindestens", "atMost": "ist höchstens",
                         "not-atLeast": "ist kleiner als", "not-atMost": "ist größer als",
                         "and": "Alle Bedingungen (UND)", "or": "Mindestens eine Bedingung (ODER)"]

}
