import Foundation

enum BridgeSearchOperation: String, Decodable {
    case arguments, start, poll, projection, page, exportCurrent
}

struct BridgeSearchEnvelope: Decodable {
    let operation: BridgeSearchOperation
}

struct BridgeSearchOption: Decodable {
    let name: String
    let value: String

    private struct Key: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        guard Set(fields.allKeys.map(\.stringValue)) == ["name", "value"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Suchoption braucht Name und Wert."))
        }
        name = try fields.decode(String.self, forKey: Key(stringValue: "name"))
        value = try fields.decode(String.self, forKey: Key(stringValue: "value"))
    }

    var item: URLQueryItem { URLQueryItem(name: name, value: value) }
}

struct BridgeSearchRequest: Decodable {
    let pattern: String
    let roots: [String]
    let options: [BridgeSearchOption]
    let rootBytes: [String]?
    let quick: Bool?
    let contentPreview: Bool?
    // Der gemeinsame Kalendervertrag prüft das ursprüngliche JSON-Objekt.
    let hasContinuation: Bool
    let hasReference: Bool

    private enum Keys: String, CodingKey {
        case pattern, roots, options, rootBytes, quick, contentPreview, continuation, dateReferenceTime
    }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Keys.self)
        pattern = try fields.decode(String.self, forKey: .pattern)
        roots = try fields.decode([String].self, forKey: .roots)
        options = try fields.decode([BridgeSearchOption].self, forKey: .options)
        rootBytes = try fields.contains(.rootBytes) ? fields.decode([String].self, forKey: .rootBytes) : nil
        quick = try fields.decodeIfPresent(Bool.self, forKey: .quick)
        contentPreview = try fields.decodeIfPresent(Bool.self, forKey: .contentPreview)
        hasContinuation = fields.contains(.continuation)
        hasReference = fields.contains(.dateReferenceTime)
    }
}

struct BridgePollRequest: Decodable {
    let runID: String?
}

struct BridgeResultOrder: Equatable {
    let sort: String
    let ascending: Bool

    init(sort: String?, ascending: Bool?) {
        self.sort = sort ?? "name"
        self.ascending = ascending ?? true
    }
}

struct BridgeProjectionRequest: Decodable {
    let runID: String
    let sort: String?
    let ascending: Bool?
    let mode: String?
    let collapsed: [String]?
    let collapseAll: Bool?
}

struct BridgePageRequest: Decodable {
    let runID: String
    let sort: String?
    let ascending: Bool?
    let offset: Int
    let limit: Int
}

struct BridgeExportRequest: Decodable {
    let runID: String
    let sort: String?
    let ascending: Bool?
    let format: String
    let indices: [Int]?
}

struct BridgeRunResponse: Encodable {
    let ok = true
    let runID: String
}

struct BridgeArgumentsResponse: Encodable {
    let ok = true
    let arguments: [String]
}

struct BridgeExportResponse: Encodable {
    let ok = true
    let data: String
}

struct BridgeProjectionResponse: Encodable {
    enum Row: Encodable {
        case hit(Int)
        case group(key: String, title: String, count: Int)

        private enum Keys: String, CodingKey { case kind, index, key, title, count }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: Keys.self)
            switch self {
            case .hit(let index):
                try fields.encode("hit", forKey: .kind)
                try fields.encode(index, forKey: .index)
            case .group(let key, let title, let count):
                try fields.encode("group", forKey: .kind)
                try fields.encode(key, forKey: .key)
                try fields.encode(title, forKey: .title)
                try fields.encode(count, forKey: .count)
            }
        }
    }

    let ok = true
    let rows: [Row]
    let total: Int
    let visible: Int
    let expanded: Int
    let arrivalPrefix: Bool
}
