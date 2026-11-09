import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(CryptoKit)
import CryptoKit
#else
import CContentHash
#endif

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

#if !canImport(CryptoKit)
enum SHA256 {
    static func hash(data: Data) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = CContentHash.SHA256(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, &output)
        }
        return output
    }
}
#endif

enum LocalContentAccess {
    static func withoutMaterialization<Result>(allowLegacy: Bool = true, _ body: () -> Result) -> Result? {
        #if os(macOS)
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
        #endif
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
        #if os(macOS)
        let modified = information.st_mtimespec, changed = information.st_ctimespec
        #else
        let modified = information.st_mtim, changed = information.st_ctim
        #endif
        return Self(device: String(information.st_dev), inode: String(information.st_ino), size: String(information.st_size),
                    modifiedNS: nanoseconds(modified), changedNS: nanoseconds(changed))
    }

    static func current(_ path: String, localOnly: Bool = false) -> Self? {
        current(Data(path.utf8), localOnly: localOnly)
    }

    static func current(_ path: Data, localOnly: Bool = false) -> Self? {
        guard !path.isEmpty, !path.contains(0) else { return nil }
        return LocalContentAccess.withoutMaterialization(allowLegacy: !localOnly) { () -> Self? in
            var information = stat()
            let bytes = Array(path) + [0]
            let result = bytes.withUnsafeBytes { raw in
                stat(raw.bindMemory(to: CChar.self).baseAddress!, &information)
            }
            guard result == 0 else { return nil }
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
    var readerOverride: String? = nil
    var readerFingerprint: String? = nil
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.readerFingerprint == rhs.readerFingerprint && lhs.readerOverride == rhs.readerOverride && lhs.ocrBlock == rhs.ocrBlock && lhs.ocrConfidence == rhs.ocrConfidence && lhs.ocrRegion == rhs.ocrRegion && lhs.slide == rhs.slide && lhs.objectID == rhs.objectID && lhs.objectKind == rhs.objectKind && lhs.row == rhs.row && lhs.column == rhs.column && lhs.sheetIndex == rhs.sheetIndex && lhs.cell == rhs.cell && lhs.valueKind == rhs.valueKind && sameBytes(lhs.sheet, rhs.sheet) && lhs.kind == rhs.kind && lhs.chapter == rhs.chapter && lhs.page == rhs.page && lhs.line == rhs.line && lhs.partKind == rhs.partKind && lhs.paragraph == rhs.paragraph &&
            ((lhs.part == nil && rhs.part == nil) || (lhs.part != nil && rhs.part != nil && lhs.part!.utf8.elementsEqual(rhs.part!.utf8)))
    }
    private static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
        if let lhs, let rhs { return lhs.utf8.elementsEqual(rhs.utf8) }
        return lhs == nil && rhs == nil
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(readerFingerprint); hasher.combine(readerOverride); hasher.combine(ocrBlock); hasher.combine(ocrConfidence); hasher.combine(ocrRegion)
        hasher.combine(slide); hasher.combine(objectID); hasher.combine(objectKind); hasher.combine(row); hasher.combine(column)
        hasher.combine(sheetIndex); hasher.combine(cell); hasher.combine(valueKind); hasher.combine(sheet != nil)
        if let sheet { for byte in sheet.utf8 { hasher.combine(byte) } }
        hasher.combine(kind); hasher.combine(chapter); hasher.combine(page); hasher.combine(line); hasher.combine(partKind); hasher.combine(paragraph)
        hasher.combine(part != nil)
        if let part { for byte in part.utf8 { hasher.combine(byte) } }
    }
    static let readers = ["pdfkit-text-v1": "pdfkit-v1", "docx-text-v1": "docx-v1", "odt-text-v1": "odt-v1", "epub-text-v1": "epub-v1", "xlsx-text-v1": "xlsx-v1", "pptx-text-v1": "pptx-v1", "vision-ocr-text-v1": "vision-image-v1", "pdfkit-vision-text-v1": "pdfkit-vision-v1", "poppler-text-v1": "poppler-v1", "tesseract-ocr-text-v1": "tesseract-image-v1", "poppler-tesseract-text-v1": "poppler-tesseract-v1"]
    var reader: String { readerOverride ?? ["pdfPage": "pdfkit-v1", "docxParagraph": "docx-v1", "odtParagraph": "odt-v1", "epubParagraph": "epub-v1", "xlsxCell": "xlsx-v1", "pptxParagraph": "pptx-v1", "imageOCR": "vision-image-v1", "pdfOCR": "pdfkit-vision-v1", "pdfTextPage": "pdfkit-vision-v1"][kind]! }
    static let cellValueKinds = ["text", "number", "boolean", "date", "cachedString", "cachedNumber", "cachedBoolean", "cachedDate"]
    var json: [String: Any] {
        var result = baseJSON
        if let readerOverride { result["reader"] = readerOverride }
        if let readerFingerprint { result["readerFingerprint"] = readerFingerprint }
        return result
    }
    private var baseJSON: [String: Any] {
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
        if var object = raw as? [String: Any], let reader = object.removeValue(forKey: "reader") {
            guard let fingerprint = object.removeValue(forKey: "readerFingerprint") as? String,
                  fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let name = reader as? String,
                  let kinds = ["poppler-v1": ["pdfPage"], "tesseract-image-v1": ["imageOCR"], "poppler-tesseract-v1": ["pdfTextPage", "pdfOCR"]][name],
                  let kind = object["kind"] as? String, kinds.contains(kind), var result = parse(object) else { return nil }
            result.readerOverride = name; result.readerFingerprint = fingerprint
            return result
        }

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
