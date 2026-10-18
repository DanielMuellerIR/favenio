import AppKit
import CryptoKit
import Darwin

// JSONSerialization entfernt ein führendes U+FEFF auch in Stringwerten.
// Optionale Beleg- und Berichtszweige brauchen den bytegetreuen JSONDecoder-Pfad;
// Standardtreffer behalten ihren bisherigen schlanken Parser.
private enum PreviewJSONValue: Decodable {
    case object([String: PreviewJSONValue]), array([PreviewJSONValue]), string(String), number(Double), boolean(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: PreviewJSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([PreviewJSONValue].self) { self = .array(array) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else { self = .number(try value.decode(Double.self)) }
    }
    var value: Any {
        switch self {
        case .object(let items): return items.mapValues { $0.value }
        case .array(let items): return items.map { $0.value }
        case .string(let text): return text
        case .number(let number): return NSNumber(value: number)
        case .boolean(let flag): return NSNumber(value: flag)
        case .null: return NSNull()
        }
    }
}

func preservedJSONObject(_ data: Data) -> Any? {
    (try? JSONDecoder().decode(PreviewJSONValue.self, from: data))?.value
}

func preservedContentPreview(_ data: Data) -> Any? {
    struct Envelope: Decodable { let contentPreview: PreviewJSONValue? }
    return (try? JSONDecoder().decode(Envelope.self, from: data))?.contentPreview?.value
}

enum LocalContentAccess {
    static func withoutMaterialization<Result>(allowLegacy: Bool = true, _ body: () -> Result) -> Result? {
        if #available(macOS 13, *) {
            let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            guard previous >= 0,
                  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                                IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0 else { return nil }
            defer {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous)
            }
            guard getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
                    == IOPOL_MATERIALIZE_DATALESS_FILES_OFF else { return nil }
            return body()
        }
        return allowLegacy ? body() : nil
    }
}

struct ContentSourceGeneration: Hashable {
    let device: String
    let inode: String
    let size: String
    let modifiedNS: String
    let changedNS: String

    var json: [String: String] {
        ["device": device, "inode": inode, "size": size,
         "modifiedNS": modifiedNS, "changedNS": changedNS]
    }

    static func parse(_ raw: Any?) -> Self? {
        func timestamp(_ text: String) -> Bool {
            let digits = text.hasPrefix("-") ? text.dropFirst() : text[...]
            return !digits.isEmpty && digits.count <= 30 && digits.utf8.allSatisfy { (48...57).contains($0) }
        }
        guard let object = raw as? [String: String], object.count == 5,
              let device = object["device"], UInt64(device) != nil,
              let inode = object["inode"], UInt64(inode) != nil,
              let size = object["size"], UInt64(size) != nil,
              let modified = object["modifiedNS"], timestamp(modified),
              let changed = object["changedNS"], timestamp(changed) else { return nil }
        return Self(device: device, inode: inode, size: size, modifiedNS: modified, changedNS: changed)
    }

    static func from(_ information: stat) -> Self {
        func nanoseconds(_ value: timespec) -> String {
            let result = Decimal(value.tv_sec) * Decimal(1_000_000_000) + Decimal(value.tv_nsec)
            return NSDecimalNumber(decimal: result).stringValue
        }
        return Self(device: String(information.st_dev), inode: String(information.st_ino), size: String(information.st_size),
                    modifiedNS: nanoseconds(information.st_mtimespec), changedNS: nanoseconds(information.st_ctimespec))
    }

    static func current(_ path: String, localOnly: Bool = false) -> Self? {
        LocalContentAccess.withoutMaterialization(allowLegacy: !localOnly) { () -> Self? in
            var information = stat()
            guard stat(path, &information) == 0 else { return nil }
            return Self.from(information)
        } ?? nil
    }
}

private func previewInteger(_ value: Any?, maximum: Int = 1_000_000_000) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 0,
          number.doubleValue < Double(Int.max), number.doubleValue <= Double(maximum), number.doubleValue.rounded() == number.doubleValue else { return nil }
    return number.intValue
}

struct DocumentPosition: Hashable {
    let page: Int
    let line: Int
    var part: String? = nil
    var partKind: String? = nil
    var paragraph: Int? = nil
    var kind: String = "pdfPage"
    var chapter: Int? = nil
    var sheet: String? = nil
    var sheetIndex: Int? = nil
    var cell: String? = nil
    var valueKind: String? = nil
    var slide: Int? = nil
    var objectID: String? = nil
    var objectKind: String? = nil
    var row: Int? = nil
    var column: Int? = nil
    var ocrBlock: Int? = nil
    var ocrConfidence: Double? = nil
    var ocrRegion: [Double]? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ocrBlock == rhs.ocrBlock && lhs.ocrConfidence == rhs.ocrConfidence && lhs.ocrRegion == rhs.ocrRegion && lhs.slide == rhs.slide && lhs.objectID == rhs.objectID && lhs.objectKind == rhs.objectKind && lhs.row == rhs.row && lhs.column == rhs.column && lhs.sheetIndex == rhs.sheetIndex && lhs.cell == rhs.cell && lhs.valueKind == rhs.valueKind && sameBytes(lhs.sheet, rhs.sheet) && lhs.kind == rhs.kind && lhs.chapter == rhs.chapter && lhs.page == rhs.page && lhs.line == rhs.line && lhs.partKind == rhs.partKind && lhs.paragraph == rhs.paragraph &&
            ((lhs.part == nil && rhs.part == nil) || (lhs.part != nil && rhs.part != nil && lhs.part!.utf8.elementsEqual(rhs.part!.utf8)))
    }
    private static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
        if let lhs, let rhs { return lhs.utf8.elementsEqual(rhs.utf8) }
        return lhs == nil && rhs == nil
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(ocrBlock); hasher.combine(ocrConfidence); hasher.combine(ocrRegion)
        hasher.combine(slide); hasher.combine(objectID); hasher.combine(objectKind); hasher.combine(row); hasher.combine(column)
        hasher.combine(sheetIndex); hasher.combine(cell); hasher.combine(valueKind); hasher.combine(sheet != nil)
        if let sheet { for byte in sheet.utf8 { hasher.combine(byte) } }
        hasher.combine(kind); hasher.combine(chapter); hasher.combine(page); hasher.combine(line); hasher.combine(partKind); hasher.combine(paragraph)
        hasher.combine(part != nil)
        if let part { for byte in part.utf8 { hasher.combine(byte) } }
    }
    static let readers = ["pdfkit-text-v1": "pdfkit-v1", "docx-text-v1": "docx-v1", "odt-text-v1": "odt-v1", "epub-text-v1": "epub-v1", "xlsx-text-v1": "xlsx-v1", "pptx-text-v1": "pptx-v1", "vision-ocr-text-v1": "vision-image-v1", "pdfkit-vision-text-v1": "pdfkit-vision-v1"]
    var reader: String { ["pdfPage": "pdfkit-v1", "docxParagraph": "docx-v1", "odtParagraph": "odt-v1", "epubParagraph": "epub-v1", "xlsxCell": "xlsx-v1", "pptxParagraph": "pptx-v1", "imageOCR": "vision-image-v1", "pdfOCR": "pdfkit-vision-v1", "pdfTextPage": "pdfkit-vision-v1"][kind]! }
    static let cellValueKinds = ["text", "number", "boolean", "date", "cachedString", "cachedNumber", "cachedBoolean", "cachedDate"]
    var json: [String: Any] {
        if kind == "imageOCR" || kind == "pdfOCR" {
            var value: [String: Any] = ["kind": kind, "block": ocrBlock!, "confidence": ocrConfidence!, "region": ocrRegion!, "line": line]
            if kind == "pdfOCR" { value["page"] = page }
            return value
        }
        if kind == "pdfTextPage" { return ["kind": kind, "page": page, "line": line] }
        if kind == "pptxParagraph" {
            var result: [String: Any] = ["kind": kind, "part": part!, "slide": slide!, "objectID": objectID!, "objectKind": objectKind!, "paragraph": paragraph!, "line": line]
            if let row, let column { result["row"] = row; result["column"] = column }
            return result
        }
        if kind == "xlsxCell" {
            return ["kind": kind, "part": part!, "sheet": sheet!, "sheetIndex": sheetIndex!, "cell": cell!, "valueKind": valueKind!, "line": line]
        }
        if let part, let paragraph {
            var result: [String: Any] = ["kind": kind, "part": part, "paragraph": paragraph, "line": line]
            if let partKind { result["partKind"] = partKind }
            if let chapter { result["chapter"] = chapter }
            return result
        }
        return ["kind": "pdfPage", "page": page, "line": line]
    }
    var title: String {
        if kind == "pdfTextPage" { return "Seite \(page) · Textebene · Zeile \(line)" }
        if kind == "pdfOCR" { return "Seite \(page) · OCR · Bereich \(ocrBlock!) (ca.) · Zeile \(line)" }
        if kind == "imageOCR" { return "OCR · Bereich \(ocrBlock!) (ca.) · Zeile \(line)" }
        if kind == "pptxParagraph" {
            let object = objectKind == "table" ? "Tabelle \(objectID!) · Zelle \(row!),\(column!)" : "Objekt \(objectID!)"
            return "Folie \(slide!) · \(object) · Absatz \(paragraph!) · Zeile \(line)"
        }
        if kind == "xlsxCell" {
            let label = ["text": "Text", "number": "Zahl, unformatiert", "boolean": "Wahrheitswert", "date": "ISO-Datum", "cachedString": "gespeichertes Formelergebnis: Text", "cachedNumber": "gespeichertes Formelergebnis: Zahl, unformatiert", "cachedBoolean": "gespeichertes Formelergebnis: Wahrheitswert", "cachedDate": "gespeichertes Formelergebnis: ISO-Datum"][valueKind!]!
            return "Blatt \(sheetIndex!) „\(sheet!)“ · Zelle \(cell!) · \(label) · Zeile \(line)"
        }
        if let part, let paragraph {
            let source: String
            switch kind {
            case "odtParagraph": source = "ODT-Haupttext"
            case "epubParagraph": source = "Kapitel \(chapter!) (\(part))"
            default:
                let label = ["document": "Haupttext", "header": "Kopfzeile", "footer": "Fußzeile", "footnote": "Fußnote", "endnote": "Endnote"][partKind!]!
                source = partKind == "document" ? label : "\(label) (\(part))"
            }
            return "\(source) · Absatz \(paragraph) · Zeile \(line)"
        }
        return "Seite \(page) · Zeile \(line)"
    }
    static func parse(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any],
              let line = previewInteger(object["line"]), line > 0 else { return nil }
        if let kind = object["kind"] as? String, ["imageOCR", "pdfOCR"].contains(kind) {
            let page = kind == "pdfOCR" ? previewInteger(object["page"], maximum: 128) : 0
            guard let page, kind != "pdfOCR" || page > 0,
                  Set(object.keys) == (kind == "pdfOCR" ? ["kind", "block", "confidence", "region", "line", "page"] : ["kind", "block", "confidence", "region", "line"]),
                  let block = previewInteger(object["block"], maximum: 4096), block > 0,
                  let confidence = object["confidence"] as? NSNumber, CFGetTypeID(confidence) != CFBooleanGetTypeID(),
                  confidence.doubleValue.isFinite, (0.5...1).contains(confidence.doubleValue),
                  let values = object["region"] as? [NSNumber], values.count == 4,
                  values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (0...1).contains($0.doubleValue) }) else { return nil }
            let region = values.map(\.doubleValue)
            guard region[2] > 0, region[3] > 0, region[0] + region[2] <= 1.000001, region[1] + region[3] <= 1.000001 else { return nil }
            return Self(page: page, line: line, kind: kind, ocrBlock: block, ocrConfidence: confidence.doubleValue, ocrRegion: region)
        }
        if object["kind"] as? String == "pdfTextPage" {
            guard Set(object.keys) == ["kind", "page", "line"], let page = previewInteger(object["page"], maximum: 128), page > 0 else { return nil }
            return Self(page: page, line: line, kind: "pdfTextPage")
        }
        guard ["block", "confidence", "region"].allSatisfy({ object[$0] == nil }) else { return nil }
        let pptxKeys = ["slide", "objectID", "objectKind", "row", "column"]
        if object["kind"] as? String != "pptxParagraph", pptxKeys.contains(where: { object[$0] != nil }) { return nil }
        if object["kind"] as? String == "pdfPage" {
            guard let page = previewInteger(object["page"], maximum: 512), page > 0 else { return nil }
            return Self(page: page, line: line)
        }
        guard let locator = object["kind"] as? String, ["docxParagraph", "odtParagraph", "epubParagraph", "xlsxCell", "pptxParagraph"].contains(locator),
              let part = object["part"] as? String, !part.isEmpty, part.unicodeScalars.count <= 256,
              !part.hasPrefix("/"), !part.contains("\\"), !part.contains("\0"),
              !part.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        if locator == "pptxParagraph" {
            guard let slide = previewInteger(object["slide"], maximum: 64), slide > 0,
                  let objectID = object["objectID"] as? String, !objectID.isEmpty, objectID.utf8.count <= 10,
                  (objectID == "0" || objectID.utf8.first != 48), objectID.utf8.allSatisfy({ (48...57).contains($0) }),
                  let identifier = UInt64(objectID), identifier <= 4294967295,
                  let objectKind = object["objectKind"] as? String, ["shape", "table"].contains(objectKind),
                  let paragraph = previewInteger(object["paragraph"], maximum: 32768), paragraph > 0,
                  ["sheet", "sheetIndex", "cell", "valueKind", "partKind", "chapter", "page"].allSatisfy({ object[$0] == nil }) else { return nil }
            var row: Int?, column: Int?
            if objectKind == "table" {
                guard let r = previewInteger(object["row"], maximum: 131072), r > 0,
                      let c = previewInteger(object["column"], maximum: 131072), c > 0 else { return nil }
                row = r; column = c
            } else if object["row"] != nil || object["column"] != nil { return nil }
            return Self(page: 0, line: line, part: part, paragraph: paragraph, kind: locator, slide: slide, objectID: objectID, objectKind: objectKind, row: row, column: column)
        }
        if locator == "xlsxCell" {
            guard let sheet = object["sheet"] as? String, !sheet.isEmpty, sheet.unicodeScalars.count <= 256, !sheet.contains("\0"),
                  let sheetIndex = previewInteger(object["sheetIndex"], maximum: 64), sheetIndex > 0,
                  let cell = object["cell"] as? String, validCellAddress(cell),
                  let valueKind = object["valueKind"] as? String, cellValueKinds.contains(valueKind),
                  object["paragraph"] == nil, object["chapter"] == nil, object["partKind"] == nil else { return nil }
            return Self(page: 0, line: line, part: part, kind: locator, sheet: sheet, sheetIndex: sheetIndex, cell: cell, valueKind: valueKind)
        }
        guard object["sheet"] == nil, object["sheetIndex"] == nil, object["cell"] == nil, object["valueKind"] == nil,
              let paragraph = previewInteger(object["paragraph"], maximum: 32768), paragraph > 0 else { return nil }
        if locator == "docxParagraph" {
            guard let partKind = object["partKind"] as? String, ["document", "header", "footer", "footnote", "endnote"].contains(partKind), object["chapter"] == nil else { return nil }
            return Self(page: 0, line: line, part: part, partKind: partKind, paragraph: paragraph, kind: locator)
        }
        guard object["partKind"] == nil else { return nil }
        if locator == "odtParagraph" {
            guard part == "content.xml", object["chapter"] == nil else { return nil }
            return Self(page: 0, line: line, part: part, paragraph: paragraph, kind: locator)
        }
        guard let chapter = previewInteger(object["chapter"], maximum: 4096), chapter > 0 else { return nil }
        return Self(page: 0, line: line, part: part, paragraph: paragraph, kind: locator, chapter: chapter)
    }
    private static func validCellAddress(_ address: String) -> Bool {
        let bytes = Array(address.utf8)
        guard bytes.count >= 2, bytes.count <= 10 else { return false }
        let letters = bytes.prefix { (65...90).contains($0) }
        guard !letters.isEmpty, letters.count <= 3 else { return false }
        let digits = bytes.dropFirst(letters.count)
        guard !digits.isEmpty, digits.first != 48, digits.allSatisfy({ (48...57).contains($0) }),
              let row = Int(String(decoding: digits, as: UTF8.self)), row <= 1048576 else { return false }
        return letters.reduce(0, { $0 * 26 + Int($1) - 64 }) <= 16384
    }

}

final class DocumentEvidence: Hashable {
    let position: DocumentPosition?
    let generation: ContentSourceGeneration
    init(position: DocumentPosition?, generation: ContentSourceGeneration) {
        self.position = position; self.generation = generation
    }
    static func == (lhs: DocumentEvidence, rhs: DocumentEvidence) -> Bool {
        lhs === rhs || (lhs.position == rhs.position && lhs.generation == rhs.generation)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(position); hasher.combine(generation) }
}

struct ContentPreviewQuery: Hashable {
    let pattern: String
    let regex: Bool
    let caseSensitive: Bool
    let exact: Bool
    let literalWildcards: Bool
    let encoding: String?
    var documentReader: String? = nil
    var json: [String: Any] {
        var result: [String: Any] = ["pattern": pattern, "regex": regex, "caseSensitive": caseSensitive,
                                   "exact": exact, "literalWildcards": literalWildcards]
        if let encoding { result["encoding"] = encoding }
        if let documentReader { result["documentReader"] = documentReader }
        return result
    }
    static func parse(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any], let pattern = object["pattern"] as? String,
              !pattern.isEmpty, pattern.unicodeScalars.count <= 65536 else { return nil }
        for key in ["regex", "caseSensitive", "exact", "literalWildcards"] {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        }
        let encoding = object["encoding"] as? String
        let reader = object["documentReader"] as? String
        if object["documentReader"] != nil && !DocumentPosition.readers.values.contains(reader ?? "") { return nil }
        if object["encoding"] != nil && (encoding == nil || SearchTextEncoding(rawValue: encoding!) == nil) { return nil }
        return Self(pattern: pattern, regex: object["regex"] as! Bool, caseSensitive: object["caseSensitive"] as! Bool,
                    exact: object["exact"] as! Bool, literalWildcards: object["literalWildcards"] as! Bool, encoding: encoding, documentReader: reader)
    }
}

struct ContentPreviewArchiveLimits: Hashable {
    let memberBytes: Int
    let totalBytes: Int
    let ratio: Double
    var json: [String: Any] { ["memberBytes": memberBytes, "totalBytes": totalBytes, "ratio": ratio] }
    static func parse(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any],
              let member = previewInteger(object["memberBytes"], maximum: Int.max), member > 0,
              let total = previewInteger(object["totalBytes"], maximum: Int.max), total > 0,
              let ratio = object["ratio"] as? NSNumber, CFGetTypeID(ratio) != CFBooleanGetTypeID(),
              ratio.doubleValue.isFinite, ratio.doubleValue > 0 else { return nil }
        return Self(memberBytes: member, totalBytes: total, ratio: ratio.doubleValue)
    }
}

struct ContentPreviewNavigation: Hashable {
    struct ContextLine: Hashable {
        let line: Int
        let text: String
        let truncated: Bool
        var documentPosition: DocumentPosition? = nil
        var json: [String: Any] {
            var result: [String: Any] = ["line": line, "text": text, "truncated": truncated,
                "excerptSHA256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()]
            if let documentPosition { result["documentPosition"] = documentPosition.json }
            return result
        }
    }
    let queryIndex: Int
    let occurrence: Int
    let reason: String
    let contextLines: [ContextLine]
    let readBytes: Int
    var documentReason: String? = nil
    var documentMessage: String? = nil
    var json: [String: Any] {
        var result: [String: Any] = ["queryIndex": queryIndex, "occurrence": occurrence, "reason": reason,
         "contextLines": contextLines.map { $0.json }, "readBytes": readBytes]
        if let documentReason { result["documentReason"] = documentReason }
        if let documentMessage { result["documentMessage"] = documentMessage }
        return result
    }
    static func parse(_ raw: Any?) -> Self? {
        guard let object = raw as? [String: Any], let index = previewInteger(object["queryIndex"], maximum: 31),
              let occurrence = previewInteger(object["occurrence"], maximum: 1000000),
              let reason = object["reason"] as? String,
              ["ready", "end", "positionLimit", "readLimit", "sourceChanged", "documentUnavailable"].contains(reason),
              let bytes = previewInteger(object["readBytes"] ?? 0, maximum: 64 * 1024 * 1024),
              let lines = object["contextLines"] as? [[String: Any]], lines.count <= 6 else { return nil }
        var contexts: [ContextLine] = []
        for line in lines {
            guard let number = previewInteger(line["line"]), number > 0,
                  let text = line["text"] as? String, text.unicodeScalars.count <= 256,
                  let truncated = line["truncated"] as? NSNumber,
                  CFGetTypeID(truncated) == CFBooleanGetTypeID(),
                  let hash = line["excerptSHA256"] as? String,
                  hash == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() else { return nil }
            let position = DocumentPosition.parse(line["documentPosition"])
            if line["documentPosition"] != nil && position == nil { return nil }
            contexts.append(ContextLine(line: number, text: text, truncated: truncated.boolValue, documentPosition: position))
        }
        let documentReason = object["documentReason"] as? String
        let documentMessage = object["documentMessage"] as? String
        if object["documentMessage"] != nil && (documentMessage == nil || documentMessage!.unicodeScalars.count > 256) { return nil }
        if object["documentReason"] != nil && !(documentReason?.hasPrefix("document") == true && documentReason!.utf8.count <= 64) { return nil }
        return Self(queryIndex: index, occurrence: occurrence, reason: reason, contextLines: contexts, readBytes: bytes, documentReason: documentReason, documentMessage: documentMessage)
    }
}

struct ContentSnippet: Hashable {
    let line: Int
    let text: String
    let label: String
    let termIndex: Int?
    let criterionID: String?
    let binding: String
    let range: NSRange?
    let prefixTruncated: Bool
    let suffixTruncated: Bool
    let matchTruncated: Bool
    let excerptSHA256: String
    let query: ContentPreviewQuery?
    var documentPosition: DocumentPosition? = nil

    var json: [String: Any] {
        var result: [String: Any] = ["line": line, "text": text, "label": label, "positionBinding": binding,
            "prefixTruncated": prefixTruncated, "suffixTruncated": suffixTruncated, "excerptSHA256": excerptSHA256]
        if let termIndex { result["termIndex"] = termIndex }
        if let criterionID { result["criterionID"] = criterionID }
        if let range { result["location"] = range.location; result["length"] = range.length }
        if matchTruncated { result["matchTruncated"] = true }
        if let query { result["query"] = query.json }
        if let documentPosition { result["documentPosition"] = documentPosition.json }
        return result
    }

    static func parse(_ raw: Any) -> Self? {
        guard let object = raw as? [String: Any], let line = previewInteger(object["line"]), line > 0,
              let text = object["text"] as? String, text.unicodeScalars.count <= 256,
              let label = object["label"] as? String, label.unicodeScalars.count <= 128,
              let binding = object["positionBinding"] as? String,
              ["excerptUTF16", "unavailable", "invalidDecoding"].contains(binding),
              let hash = object["excerptSHA256"] as? String,
              hash == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined() else { return nil }
        for key in ["prefixTruncated", "suffixTruncated", "matchTruncated"] where object[key] != nil {
            guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        }
        let termIndex = previewInteger(object["termIndex"])
        let criterionID = object["criterionID"] as? String
        guard (termIndex != nil) != (criterionID != nil), termIndex == nil || termIndex! > 0,
              criterionID == nil || (!criterionID!.isEmpty && criterionID!.utf8.count <= 256) else { return nil }
        var range: NSRange?
        if binding == "excerptUTF16" {
            let units = Array(text.utf16)
            guard let location = previewInteger(object["location"], maximum: units.count),
                  let length = previewInteger(object["length"], maximum: units.count - location) else { return nil }
            for point in [location, location + length] where point > 0 && point < units.count {
                guard !(0xDC00...0xDFFF).contains(units[point]) else { return nil }
            }
            range = NSRange(location: location, length: length)
        } else if object["location"] != nil || object["length"] != nil { return nil }
        let query = ContentPreviewQuery.parse(object["query"])
        let position = DocumentPosition.parse(object["documentPosition"])
        if object["documentPosition"] != nil && position == nil { return nil }
        if object["query"] != nil && query == nil { return nil }
        return Self(line: line, text: text, label: label, termIndex: termIndex, criterionID: criterionID,
                    binding: binding, range: range, prefixTruncated: object["prefixTruncated"] as? Bool ?? false,
                    suffixTruncated: object["suffixTruncated"] as? Bool ?? false,
                    matchTruncated: object["matchTruncated"] as? Bool ?? false, excerptSHA256: hash, query: query, documentPosition: position)
    }
}

// Eine optionale Referenz hält den Standardtreffer klein. Leere Statusobjekte
// werden geteilt; ihre Anzahl darf nicht mit großen Trefferlisten wachsen.
final class ContentPreview: Hashable {
    let status: String
    let sourceGeneration: ContentSourceGeneration?
    let encoding: String?
    let snippets: [ContentSnippet]
    let omitted: Int?
    let navigation: ContentPreviewNavigation?
    let archiveLimits: ContentPreviewArchiveLimits?

    init(status: String, sourceGeneration: ContentSourceGeneration?, encoding: String?, snippets: [ContentSnippet], omitted: Int?, navigation: ContentPreviewNavigation? = nil, archiveLimits: ContentPreviewArchiveLimits? = nil) {
        self.status = status; self.sourceGeneration = sourceGeneration; self.encoding = encoding
        self.snippets = snippets; self.omitted = omitted; self.navigation = navigation; self.archiveLimits = archiveLimits
    }

    static func == (lhs: ContentPreview, rhs: ContentPreview) -> Bool {
        lhs === rhs || (lhs.status == rhs.status && lhs.sourceGeneration == rhs.sourceGeneration
            && lhs.encoding == rhs.encoding && lhs.snippets == rhs.snippets && lhs.omitted == rhs.omitted && lhs.navigation == rhs.navigation && lhs.archiveLimits == rhs.archiveLimits)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(status); hasher.combine(sourceGeneration); hasher.combine(encoding)
        hasher.combine(snippets); hasher.combine(omitted); hasher.combine(navigation); hasher.combine(archiveLimits)
    }

    private static let emptyStates: [String: ContentPreview] = Dictionary(uniqueKeysWithValues:
        ["invalid", "noContentEvidence", "sourceChanged", "budgetExceeded"].map {
            ($0, ContentPreview(status: $0, sourceGeneration: nil, encoding: nil, snippets: [], omitted: $0 == "budgetExceeded" ? nil : 0))
        })

    var json: [String: Any] {
        var result: [String: Any] = ["schemaVersion": 1, "status": status, "snippets": snippets.map { $0.json }]
        if let omitted { result["omitted"] = omitted }
        if let navigation { result["navigation"] = navigation.json }
        if let archiveLimits { result["archiveLimits"] = archiveLimits.json }
        if let sourceGeneration { result["sourceGeneration"] = sourceGeneration.json }
        if let encoding { result["contentEncoding"] = encoding }
        return result
    }

    static func parse(_ raw: Any?, contentEncoding: String?) -> ContentPreview? {
        guard let raw else { return nil }
        let invalid = emptyStates["invalid"]!
        guard let object = raw as? [String: Any], previewInteger(object["schemaVersion"]) == 1,
              let status = object["status"] as? String,
              ["ready", "noContentEvidence", "sourceChanged", "budgetExceeded"].contains(status),
              let values = object["snippets"] as? [Any], values.count <= 32 else { return invalid }
        let omitted: Int?
        if status == "budgetExceeded" {
            guard object["omitted"] == nil || previewInteger(object["omitted"]) == 0 else { return invalid }
            omitted = nil
        } else {
            guard let count = previewInteger(object["omitted"]) else { return invalid }
            omitted = count
        }
        let snippets = values.compactMap(ContentSnippet.parse)
        guard snippets.count == values.count, snippets.reduce(0, { $0 + $1.text.utf16.count }) <= 4096 else { return invalid }
        let generation = ContentSourceGeneration.parse(object["sourceGeneration"])
        let encoding = object["contentEncoding"] as? String
        if status == "ready" {
            guard generation != nil, let encoding, encoding != "auto",
                  (SearchTextEncoding(rawValue: encoding) != nil || DocumentPosition.readers[encoding] != nil),
                  encoding == contentEncoding, !snippets.isEmpty else { return invalid }
            if DocumentPosition.readers[encoding] != nil {
                let reader = DocumentPosition.readers[encoding]!
                guard snippets.allSatisfy({ $0.documentPosition?.reader == reader && ($0.query == nil || $0.query?.documentReader == reader) }) else { return invalid }
            } else if snippets.contains(where: { $0.documentPosition != nil || $0.query?.documentReader != nil }) { return invalid }
        } else if !snippets.isEmpty { return invalid }
        let archiveLimits = ContentPreviewArchiveLimits.parse(object["archiveLimits"])
        if object["archiveLimits"] != nil && archiveLimits == nil { return invalid }
        let navigation = ContentPreviewNavigation.parse(object["navigation"])
        if object["navigation"] != nil && navigation == nil { return invalid }
        if let encoding, DocumentPosition.readers[encoding] != nil {
            let reader = DocumentPosition.readers[encoding]!
            guard navigation?.contextLines.allSatisfy({ $0.documentPosition?.reader == reader }) ?? true else { return invalid }
        }
        if navigation == nil, generation == nil, encoding == nil, (omitted ?? 0) == 0, let empty = emptyStates[status] { return empty }
        return Self(status: status, sourceGeneration: generation, encoding: encoding, snippets: snippets, omitted: omitted, navigation: navigation, archiveLimits: archiveLimits)
    }
}

func contentPreviewDisclosureSelfTest(_ controller: HitListController) -> String? {
    let view = controller.contentPreviewView
    let arguments = ["-u", "core", "--json", "--", "needle", "/fixture"]
    guard !view.enabled, view.body.isHidden,
          controller.contentPreviewArguments(arguments) == arguments else {
        return "Fundstellenvorschau startet nicht schlank und zugeklappt"
    }
    defer { if view.enabled { view.toggle.performClick(nil) } }
    view.toggle.performClick(nil)
    guard view.enabled, !view.body.isHidden,
          controller.contentPreviewArguments(arguments) == ["-u", "core", "--json", "--content-preview", "--", "needle", "/fixture"] else {
        return "Fundstellenvorschau klappt nicht auf oder aktiviert ihren Kernpfad nicht"
    }
    return nil
}

final class ContentPreviewView: NSStackView {
    let toggle = NSButton(checkboxWithTitle: "Fundstellenvorschau", target: nil, action: nil)
    let sourceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Treffer auswählen.")
    let textView = NSTextView()
    let restartButton = NSButton(title: "Mit Vorschau neu suchen", target: nil, action: nil)
    let body = NSStackView()
    let queryMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let previousButton = NSButton(title: "Vorherige", target: nil, action: nil)
    let nextButton = NSButton(title: "Nächste", target: nil, action: nil)
    let contextButton = NSButton(title: "Mehr Kontext", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let navigationBar = NSStackView()
    var onNavigate: ((Int, Bool) -> Void)?
    var onQueryChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggle: (() -> Void)?
    var onRestart: (() -> Void)?
    var enabled: Bool { toggle.state == .on }
    private var bodyHeight: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        toggle.target = self; toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("contentPreviewToggle")
        toggle.toolTip = "Erfasst begrenzte Fundzeilenausschnitte ab dem nächsten Suchlauf. Die Leertaste öffnet weiterhin Quick Look."
        restartButton.target = self; restartButton.action = #selector(restart)
        for (button, action, identifier) in [
            (previousButton, #selector(previous), "contentPreviewPrevious"),
            (nextButton, #selector(next), "contentPreviewNext"),
            (contextButton, #selector(context), "contentPreviewContext"),
            (cancelButton, #selector(cancel), "contentPreviewCancel")] {
            button.target = self; button.action = action
            button.controlSize = .small; button.font = .systemFont(ofSize: 11)
            button.setAccessibilityIdentifier(identifier)
        }
        queryMenu.target = self; queryMenu.action = #selector(queryChanged)
        queryMenu.controlSize = .small; queryMenu.font = .systemFont(ofSize: 11)
        queryMenu.setAccessibilityIdentifier("contentPreviewQuery")
        queryMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        queryMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigationBar.orientation = .horizontal; navigationBar.spacing = 6
        for control in [queryMenu, previousButton, nextButton, contextButton, cancelButton] { navigationBar.addArrangedSubview(control) }
        previousButton.toolTip = "Vorherige Fundstelle des ausgewählten Begriffs oder Inhaltskriteriums."
        nextButton.toolTip = "Nächste Fundstelle in dieser Quelle; höchstens 64 MiB erneut lesen und fünf Sekunden einschließlich Auspacken."
        contextButton.toolTip = "Bis zu drei Zeilen davor und danach sowie mehr Text der Fundzeile laden."
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.font = .systemFont(ofSize: 11); sourceLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        sourceLabel.setAccessibilityIdentifier("contentPreviewSource")
        statusLabel.setAccessibilityIdentifier("contentPreviewStatus")
        textView.isEditable = false; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor; textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("contentPreviewText")
        let scroll = NSScrollView()
        scroll.documentView = textView; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 4
        for view in [sourceLabel, statusLabel, navigationBar, scroll, restartButton] { body.addArrangedSubview(view) }
        addArrangedSubview(toggle); addArrangedSubview(body)
        for view in [body, sourceLabel, statusLabel, scroll] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        bodyHeight = body.heightAnchor.constraint(equalToConstant: 168); bodyHeight.isActive = true
        navigationBar.isHidden = true; cancelButton.isHidden = true
        syncVisibility()
        show("Treffer auswählen.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    func compact() { bodyHeight.constant = 140 }
    func syncVisibility() { body.isHidden = !enabled }
    @objc private func toggled() { syncVisibility(); onToggle?() }
    @objc private func restart() { onRestart?() }
    @objc private func previous() { onNavigate?(-1, false) }
    @objc private func next() { onNavigate?(1, false) }
    @objc private func context() { onNavigate?(0, true) }
    @objc private func cancel() { onCancel?() }
    @objc private func queryChanged() { onQueryChange?() }

    func navigation(queries: [ContentSnippet], occurrence: Int, loading: Bool = false, next: Bool = true) {
        navigationBar.isHidden = queries.allSatisfy { $0.query == nil }
        if queryMenu.numberOfItems != queries.count {
            queryMenu.removeAllItems()
            for snippet in queries {
                queryMenu.addItem(withTitle: (snippet.termIndex.map { "Begriff \($0)" } ?? "Bedingung") + ": " + snippet.label)
            }
        }
        let canLoad = queries.indices.contains(queryMenu.indexOfSelectedItem) && queries[queryMenu.indexOfSelectedItem].query != nil
        previousButton.isEnabled = !loading && canLoad && occurrence > 0
        nextButton.isEnabled = !loading && canLoad && next
        contextButton.isEnabled = !loading && canLoad
        queryMenu.isEnabled = !loading
        cancelButton.isHidden = !loading
    }

    func show(_ message: String, source: String = "", restart: Bool = false) {
        sourceLabel.stringValue = source; sourceLabel.toolTip = source
        statusLabel.stringValue = message; statusLabel.toolTip = message
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        restartButton.isHidden = !restart
        navigationBar.isHidden = true
    }

    func render(_ preview: ContentPreview, hit: Hit) {
        show("Quellstand geprüft · " + (preview.encoding ?? "?"), source: hit.path)
        let result = NSMutableAttributedString(string: "")
        var notes: [String] = []
        if preview.encoding == "vision-ocr-text-v1" { notes.append("OCR: erkannter Text, kein garantierter Originaltext; Bildbereiche sind ungefähr.") }
        if preview.encoding == "pdfkit-vision-text-v1" { notes.append("PDF: Textebenen bevorzugt; OCR textloser Seiten ist erkannt und nicht garantiert vollständig. Seitenbereiche sind ungefähr.") }
        var firstMatch: NSRange?
        func appendContext(_ line: ContentPreviewNavigation.ContextLine) {
            result.append(NSAttributedString(string: "Kontext · " + (line.documentPosition?.title ?? "Zeile \(line.line)") + (line.truncated ? " · gekürzt" : "") + "\n" + line.text + "\n\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for line in preview.navigation?.contextLines ?? [] where line.line < (preview.snippets.first?.line ?? 0) { appendContext(line) }
        for snippet in preview.snippets {
            let label = snippet.termIndex.map { "Begriff \($0)" } ?? "Inhaltsbedingung"
            var title = label + " · " + snippet.label + " · " + (snippet.documentPosition?.title ?? "Zeile \(snippet.line)")
            if snippet.prefixTruncated || snippet.suffixTruncated { title += " · gekürzt" }
            if snippet.range?.length == 0 { title += " · leerer Treffer" }
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            if let position = snippet.documentPosition, let confidence = position.ocrConfidence, let region = position.ocrRegion {
                let bounds = region.map { String(format: "%.3f", $0) }.joined(separator: ", ")
                result.append(NSAttributedString(string: String(format: "OCR-Modellwert %.2f · ", confidence) + (position.kind == "pdfOCR" ? "Seitenregion [" : "Bildregion [") + bounds + "] (x, y, Breite, Höhe; Ursprung unten links)\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let offset = result.length
            result.append(NSAttributedString(string: snippet.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
            if firstMatch == nil {
                firstMatch = NSRange(location: offset + (snippet.range?.location ?? 0), length: snippet.range?.length ?? 0)
            }
            if let range = snippet.range, range.length > 0 {
                result.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35),
                                      .underlineStyle: NSUnderlineStyle.single.rawValue],
                                     range: NSRange(location: offset + range.location, length: range.length))
            }
            if snippet.binding == "invalidDecoding" { notes.append("Ersatzzeichen: keine exakte Hervorhebung.") }
            if snippet.binding == "unavailable" { notes.append("Fundposition nicht begrenzt belegbar.") }
            if snippet.matchTruncated { notes.append("Langer Fundtext gekürzt.") }
            result.append(NSAttributedString(string: "\n\n"))
        }
        if let omitted = preview.omitted, omitted > 0 { notes.append("\(omitted) Belege wegen Vorschaugrenzen nicht gespeichert.") }
        if !notes.isEmpty {
            statusLabel.stringValue += " · " + Array(Set(notes)).sorted().joined(separator: " ")
            statusLabel.toolTip = statusLabel.stringValue
        }
        for line in preview.navigation?.contextLines ?? [] where line.line > (preview.snippets.last?.line ?? 0) { appendContext(line) }
        textView.textStorage?.setAttributedString(result)
        textView.scrollRangeToVisible(firstMatch ?? NSRange(location: 0, length: 0))
    }
}

final class SearchWindowViewport {
    private weak var window: NSWindow?
    private let heightLimit: NSLayoutConstraint
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false

    init?(window: NSWindow) {
        guard let content = window.contentView else { return nil }
        self.window = window
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        heightLimit = content.heightAnchor.constraint(lessThanOrEqualToConstant: max(1, window.contentRect(forFrameRect: visible).height))
        heightLimit.isActive = true
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                                             object: window, queue: .main) { [weak self] _ in self?.heightLimit.isActive = false })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                             object: window, queue: .main) { [weak self] _ in
            self?.heightLimit.isActive = true
            self?.scheduleUpdate()
        })
        update()
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        guard heightLimit.isActive, let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Weiche Vorschauhöhen allein verkleinern AppKits Fenster-Minimum nicht.
        let maximumHeight = max(1, window.contentRect(forFrameRect: visible).height)
        if heightLimit.constant != maximumHeight { heightLimit.constant = maximumHeight }
        var frame = window.frame
        frame.size.height = min(frame.height, visible.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
    }
}

final class FinderMetadataView: NSStackView {
    let toggle = NSButton(checkboxWithTitle: "Finder-Eigenschaften", target: nil, action: nil)
    let textView = NSTextView()
    let scroll = NSScrollView()
    private var hit: Hit?
    var enabled: Bool { toggle.state == .on }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        toggle.target = self; toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("finderMetadataToggle")
        toggle.toolTip = "Zeigt die erfassten Tags und den Kommentar dieses Suchstands. Die Quelle wird dabei nicht erneut gelesen."
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityIdentifier("finderMetadataText")
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        addArrangedSubview(toggle); addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 130)
        preferredHeight.priority = NSLayoutConstraint.Priority(749)
        preferredHeight.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        syncVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    @objc private func toggled() { syncVisibility(); render(hit) }
    func syncVisibility() { scroll.isHidden = !enabled }
    static let colorNames = ["Ohne Farbe", "Grau", "Grün", "Violett", "Blau", "Gelb", "Rot", "Orange"]
    static let colors: [NSColor] = [.secondaryLabelColor, .systemGray, .systemGreen, .systemPurple, .systemBlue, .systemYellow, .systemRed, .systemOrange]
    static func singleLineSummary(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).joined(separator: " ↵ ")
    }
    static func tags(_ snapshot: FinderMetadataSnapshot?, textColor: NSColor = .labelColor,
                     compact: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        guard let values = snapshot?.tags, !values.isEmpty else {
            return NSAttributedString(string: snapshot?.tagsText ?? "Nicht erfasst", attributes: [.foregroundColor: textColor])
        }
        for (index, tag) in values.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: ", ", attributes: [.foregroundColor: textColor])) }
            result.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: colors[tag.color ?? 0]]))
            result.append(NSAttributedString(string: compact ? singleLineSummary(tag.name) : tag.name,
                                             attributes: [.foregroundColor: textColor]))
        }
        return result
    }
    func render(_ hit: Hit?) {
        self.hit = hit
        let result = NSMutableAttributedString(string: "")
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        if let hit {
            result.append(NSAttributedString(string: "Erfasster Suchstand · keine erneute Quellenabfrage\n\nFinder-Tags\n", attributes: heading))
            let tags = NSMutableAttributedString(attributedString: Self.tags(hit.finderMetadata))
            tags.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: tags.length))
            result.append(tags)
            result.append(NSAttributedString(string: "\n\nFinder-Kommentar\n", attributes: heading))
            result.append(NSAttributedString(string: hit.finderMetadata?.commentText ?? "Nicht erfasst. Vor der nächsten Suche unter Weitere Filter die Finder-Eigenschaften einschalten.", attributes: body))
        } else { result.append(NSAttributedString(string: "Treffer auswählen.", attributes: body)) }
        textView.textStorage?.setAttributedString(result)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

// Attributierte Tag-Namen übernehmen AppKits Auswahlfarbe nicht automatisch.
final class FinderTagsCellView: NSTableCellView {
    var snapshot: FinderMetadataSnapshot? { didSet { renderTags() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { renderTags() } }
    private func renderTags() {
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        textField?.attributedStringValue = FinderMetadataView.tags(snapshot, textColor: color, compact: true)
    }
}

final class ContentPreviewController {
    weak var owner: HitListController?
    let view = ContentPreviewView()
    private let queue = OperationQueue()
    private var check: BlockOperation?
    private var generation = 0
    private var selected: Hit?
    private var timer: Timer?
    private var displayed = false
    private var occurrence = 0
    private var requestEpoch = 0
    private var runner: SearchRunner?
    private var materialization: MaterializationRequest?
    private var timeout: DispatchWorkItem?
    var cliPath: String?
    var isLoading: Bool { runner != nil || timeout != nil }

    func cancelLoad(message: String? = nil) {
        requestEpoch += 1
        timeout?.cancel(); timeout = nil
        runner?.cancel(); runner = nil
        materialization?.cancel(); materialization = nil
        if let message { view.statusLabel.stringValue = message; view.statusLabel.toolTip = message }
        if displayed, let preview = selected?.contentPreview {
            view.navigation(queries: preview.snippets, occurrence: occurrence)
        }
    }

    private func navigate(delta: Int, context: Bool) {
        guard view.enabled, displayed, let hit = selected, let original = hit.contentPreview,
              let expected = original.sourceGeneration,
              original.snippets.indices.contains(view.queryMenu.indexOfSelectedItem),
              original.snippets[view.queryMenu.indexOfSelectedItem].query != nil,
              let cli = cliPath ?? findCLI() else { return }
        cancelLoad()
        let epoch = requestEpoch
        let index = view.queryMenu.indexOfSelectedItem
        let target = max(0, occurrence + delta)
        let localOnly = owner?.localOnlyContent == true
        view.statusLabel.stringValue = "Fundstelle wird geladen…"
        view.navigation(queries: original.snippets, occurrence: occurrence, loading: true)
        let limit = DispatchWorkItem { [weak self] in self?.cancelLoad(message: "Nachladen nach fünf Sekunden beendet. Bisheriger Beleg bleibt erhalten.") }
        timeout = limit
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: limit)
        materialization = MaterializationManager.shared.request(hit, localOnly: localOnly) { [weak self] outcome in
            guard let self, self.requestEpoch == epoch else { return }
            self.materialization = nil
            guard case .ready(let url) = outcome else {
                if case .failed(let reason) = outcome { self.cancelLoad(message: reason) }
                else { self.cancelLoad(message: "Nachladen abgebrochen.") }
                return
            }
            guard ContentSourceGeneration.current(hit.filesystemPath, localOnly: localOnly) == expected,
                  let leaf = ContentSourceGeneration.current(url.path, localOnly: localOnly),
                  let row = preservedJSONObject(jsonlData(for: [hit])),
                  let data = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "hit": row,
                    "filePath": url.path, "fileGeneration": leaf.json,
                    "queryIndex": index, "occurrence": target, "context": context]),
                  data.count <= 128 * 1024, let json = String(data: data, encoding: .utf8) else {
                self.cancelLoad(message: "Quelle verändert oder Nachladeauftrag zu groß. Bitte neu suchen.")
                self.invalidateSource(hit)
                return
            }
            let runner = SearchRunner(); self.runner = runner
            var response: ContentPreview?
            runner.start(arguments: ["-B", cli, "--preview-request", json] + (localOnly ? ["--local-only"] : []), onBatch: { rows, _ in
                guard self.requestEpoch == epoch, rows.count == 1, rows[0].identity == hit.identity else { return }
                response = rows[0].contentPreview
            }, completion: { [weak self] exit in
                guard let self, self.requestEpoch == epoch else { return }
                self.timeout?.cancel(); self.timeout = nil; self.runner = nil
                guard ContentSourceGeneration.current(hit.filesystemPath, localOnly: localOnly) == expected,
                      response?.status != "sourceChanged" else { self.invalidateSource(hit); return }
                guard exit.status == 0, exit.reason == .exit, let response,
                      let navigation = response.navigation else {
                    self.cancelLoad(message: exit.errorMessage ?? "Fundstelle konnte nicht geladen werden."); return
                }
                if response.status == "ready" {
                    self.occurrence = target
                    self.view.render(response, hit: hit)
                    self.view.statusLabel.stringValue += " · Fundstelle \(target + 1)"
                }
                let reason = navigation.reason
                if reason == "end" { self.view.statusLabel.stringValue = "Keine weitere Fundstelle für diesen Begriff oder diese Bedingung." }
                if reason == "readLimit" { self.view.statusLabel.stringValue = "Nachladegrenze erreicht: höchstens 64 MiB / drei Sekunden im Leser." }
                if reason == "positionLimit" { self.view.statusLabel.stringValue = "Lange Zeile: weitere Positionen nicht begrenzt belegbar." }
                if reason == "documentUnavailable" { self.view.statusLabel.stringValue = "Dokument nicht nachladbar: " + (response.navigation?.documentMessage ?? "Dokumentleser nicht verfügbar") + "." }
                self.view.statusLabel.toolTip = self.view.statusLabel.stringValue
                self.view.navigation(queries: original.snippets, occurrence: self.occurrence, next: reason == "ready")
            })
        }
    }

    private func invalidateSource(_ hit: Hit) {
        cancelLoad(); displayed = false
        view.show("Quelle wurde verändert oder ist nicht mehr verfügbar. Bitte neu suchen.", source: hit.path, restart: true)
    }

    init(owner: HitListController) {
        self.owner = owner
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        view.onNavigate = { [weak self] delta, context in self?.navigate(delta: delta, context: context) }
        view.onCancel = { [weak self] in self?.cancelLoad(message: "Nachladen abgebrochen.") }
        view.onQueryChange = { [weak self] in
            guard let self, let hit = self.selected, let preview = hit.contentPreview else { return }
            self.cancelLoad(); self.occurrence = 0
            self.view.render(preview, hit: hit)
            self.view.navigation(queries: preview.snippets, occurrence: 0)
        }
        view.onToggle = { [weak self] in self?.selectionChanged(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.verifySource() }
    }

    deinit { timer?.invalidate(); queue.cancelAllOperations(); runner?.cancel(); materialization?.cancel(); timeout?.cancel() }

    func selectionChanged(force: Bool = false) {
        let hit = owner.flatMap { owner in owner.selectedHitIndices.first.map { owner.hits[$0] } }
        if !force, hit == selected { return }
        cancelLoad(); occurrence = 0
        view.queryMenu.removeAllItems()
        generation += 1; check?.cancel(); check = nil; queue.cancelAllOperations()
        displayed = false
        selected = hit
        guard view.enabled else { view.show("Treffer auswählen."); return }
        guard let hit else { view.show("Treffer auswählen."); return }
        guard let preview = hit.contentPreview else {
            view.show("Für diesen Suchlauf wurde keine Vorschau erfasst.", source: hit.path, restart: true); return
        }
        switch preview.status {
        case "ready": view.show("Quellstand wird geprüft…", source: hit.path); verifySource()
        case "noContentEvidence": view.show("Kein positiver Inhaltsbeleg für diesen Treffer.", source: hit.path)
        case "sourceChanged": view.show("Quelle wurde verändert oder ist nicht mehr verfügbar. Bitte neu suchen.", source: hit.path, restart: true)
        case "budgetExceeded": view.show("Vorschaubudget dieses Suchlaufs ausgeschöpft (8 MiB).", source: hit.path)
        default: view.show("Vorschaubeleg ist ungültig oder wird nicht unterstützt.", source: hit.path)
        }
    }

    private func verifySource() {
        guard view.enabled, check == nil, let hit = selected, let preview = hit.contentPreview,
              preview.status == "ready", let expected = preview.sourceGeneration else { return }
        let epoch = generation
        let localOnly = owner?.localOnlyContent == true
        let operation = BlockOperation()
        check = operation
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let actual = ContentSourceGeneration.current(hit.filesystemPath, localOnly: localOnly)
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false, self.generation == epoch else { return }
                self.check = nil
                if actual == expected {
                    if !self.displayed { self.view.render(preview, hit: hit); self.view.navigation(queries: preview.snippets, occurrence: 0); self.displayed = true }
                } else {
                    self.invalidateSource(hit)
                }
            }
        }
        queue.addOperation(operation)
    }
}
