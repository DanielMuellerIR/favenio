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

private func previewBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

struct DocumentPosition: Hashable {
    private enum Kind: String {
        case pdfPage, pdfTextPage, pdfOCR, imageOCR
        case docxParagraph, odtParagraph, epubParagraph, xlsxCell, pptxParagraph, pptxOCR

        var defaultReader: String {
            switch self {
            case .pdfPage: return "pdfkit-v1"
            case .pdfTextPage, .pdfOCR: return "pdfkit-vision-v1"
            case .imageOCR: return "vision-image-v1"
            case .docxParagraph: return "docx-v1"
            case .odtParagraph: return "odt-v1"
            case .epubParagraph: return "epub-v1"
            case .xlsxCell: return "xlsx-v1"
            case .pptxParagraph: return "pptx-v1"
            case .pptxOCR: return "pptx-vision-v1"
            }
        }
    }

    // Verschieden kodierte Paketpfade und Blattnamen können verschiedene Quellen bezeichnen.
    private struct SourceName: Hashable {
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.utf8.elementsEqual(rhs.text.utf8)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(text.utf8.count)
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }

    private enum DOCXPart: String {
        case document, header, footer, footnote, endnote

        var label: String {
            switch self {
            case .document: return "Haupttext"
            case .header: return "Kopfzeile"
            case .footer: return "Fußzeile"
            case .footnote: return "Fußnote"
            case .endnote: return "Endnote"
            }
        }
    }

    private enum CellValue: String {
        case text, number, boolean, date, cachedString, cachedNumber, cachedBoolean, cachedDate

        var label: String {
            switch self {
            case .text: return "Text"
            case .number: return "Zahl, unformatiert"
            case .boolean: return "Wahrheitswert"
            case .date: return "ISO-Datum"
            case .cachedString: return "gespeichertes Formelergebnis: Text"
            case .cachedNumber: return "gespeichertes Formelergebnis: Zahl, unformatiert"
            case .cachedBoolean: return "gespeichertes Formelergebnis: Wahrheitswert"
            case .cachedDate: return "gespeichertes Formelergebnis: ISO-Datum"
            }
        }
    }

    private struct WorksheetCell: Hashable {
        let part: SourceName
        let sheet: SourceName
        let sheetIndex: Int
        let address: String
        let value: CellValue
    }

    private struct SlideObject: Hashable {
        let part: SourceName
        let slide: Int
        let id: String
    }

    private enum SlideText: Hashable {
        case shape
        case table(row: Int, column: Int)

        var kind: String {
            switch self {
            case .shape: return "shape"
            case .table: return "table"
            }
        }
    }

    private struct OCRBlock: Hashable {
        let number: Int
        let confidence: Double
        let region: [Double]
    }

    private enum Location: Hashable {
        case pdfPage(Int)
        case pdfTextPage(Int)
        case pdfOCR(page: Int, OCRBlock)
        case imageOCR(OCRBlock)
        case docxParagraph(part: SourceName, role: DOCXPart, paragraph: Int)
        case odtParagraph(Int)
        case epubParagraph(part: SourceName, chapter: Int, paragraph: Int)
        case xlsxCell(WorksheetCell)
        case pptxParagraph(SlideObject, SlideText, paragraph: Int)
        case pptxOCR(SlideObject, OCRBlock)

        var kind: Kind {
            switch self {
            case .pdfPage: return .pdfPage
            case .pdfTextPage: return .pdfTextPage
            case .pdfOCR: return .pdfOCR
            case .imageOCR: return .imageOCR
            case .docxParagraph: return .docxParagraph
            case .odtParagraph: return .odtParagraph
            case .epubParagraph: return .epubParagraph
            case .xlsxCell: return .xlsxCell
            case .pptxParagraph: return .pptxParagraph
            case .pptxOCR: return .pptxOCR
            }
        }
    }

    private struct ReaderBinding: Hashable {
        let name: String
        let fingerprint: String?
    }

    private let location: Location
    private let readerBinding: ReaderBinding?
    let line: Int

    static let pptxOCREncodings = ["pptx-vision-text-v1": "pptx-vision-v1", "pptx-tesseract-text-v1": "pptx-tesseract-v1"]
    static let readers = ["pdfkit-text-v1": "pdfkit-v1", "docx-text-v1": "docx-v1", "odt-text-v1": "odt-v1", "epub-text-v1": "epub-v1", "xlsx-text-v1": "xlsx-v1", "pptx-text-v1": "pptx-v1", "vision-ocr-text-v1": "vision-image-v1", "pdfkit-vision-text-v1": "pdfkit-vision-v1", "poppler-text-v1": "poppler-v1", "tesseract-ocr-text-v1": "tesseract-image-v1", "poppler-tesseract-text-v1": "poppler-tesseract-v1"].merging(pptxOCREncodings) { existing, _ in existing }

    var reader: String { readerOverride ?? location.kind.defaultReader }
    var readerOverride: String? { readerBinding?.name }
    var kind: String { location.kind.rawValue }
    var page: Int {
        switch location {
        case .pdfPage(let page), .pdfTextPage(let page), .pdfOCR(let page, _): return page
        default: return 0
        }
    }
    var part: String? {
        switch location {
        case .docxParagraph(let part, _, _), .epubParagraph(let part, _, _): return part.text
        case .odtParagraph: return "content.xml"
        case .xlsxCell(let cell): return cell.part.text
        case .pptxParagraph(let object, _, _), .pptxOCR(let object, _): return object.part.text
        default: return nil
        }
    }
    var partKind: String? {
        if case .docxParagraph(_, let role, _) = location { return role.rawValue }
        return nil
    }
    var paragraph: Int? {
        switch location {
        case .docxParagraph(_, _, let number), .odtParagraph(let number),
             .epubParagraph(_, _, let number), .pptxParagraph(_, _, let number): return number
        default: return nil
        }
    }
    var chapter: Int? {
        if case .epubParagraph(_, let chapter, _) = location { return chapter }
        return nil
    }

    private var worksheetCell: WorksheetCell? {
        if case .xlsxCell(let cell) = location { return cell }
        return nil
    }
    var sheet: String? { worksheetCell?.sheet.text }
    var sheetIndex: Int? { worksheetCell?.sheetIndex }
    var cell: String? { worksheetCell?.address }
    var valueKind: String? { worksheetCell?.value.rawValue }

    private var slideObject: SlideObject? {
        switch location {
        case .pptxParagraph(let object, _, _), .pptxOCR(let object, _): return object
        default: return nil
        }
    }
    var slide: Int? { slideObject?.slide }
    var objectID: String? { slideObject?.id }
    var objectKind: String? {
        switch location {
        case .pptxParagraph(_, let placement, _): return placement.kind
        case .pptxOCR: return "picture"
        default: return nil
        }
    }
    var row: Int? {
        if case .pptxParagraph(_, .table(let row, _), _) = location { return row }
        return nil
    }
    var column: Int? {
        if case .pptxParagraph(_, .table(_, let column), _) = location { return column }
        return nil
    }

    private var ocr: OCRBlock? {
        switch location {
        case .pdfOCR(_, let block), .imageOCR(let block), .pptxOCR(_, let block): return block
        default: return nil
        }
    }
    var ocrBlock: Int? { ocr?.number }
    var ocrConfidence: Double? { ocr?.confidence }
    var ocrRegion: [Double]? { ocr?.region }

    var json: [String: Any] {
        var result: [String: Any] = ["kind": kind, "line": line]
        switch location {
        case .pdfPage(let page), .pdfTextPage(let page), .pdfOCR(let page, _):
            result["page"] = page
        case .imageOCR:
            break
        case .docxParagraph(let part, let role, let paragraph):
            result["part"] = part.text
            result["partKind"] = role.rawValue
            result["paragraph"] = paragraph
        case .odtParagraph(let paragraph):
            result["part"] = "content.xml"
            result["paragraph"] = paragraph
        case .epubParagraph(let part, let chapter, let paragraph):
            result["part"] = part.text
            result["chapter"] = chapter
            result["paragraph"] = paragraph
        case .xlsxCell(let cell):
            result["part"] = cell.part.text
            result["sheet"] = cell.sheet.text
            result["sheetIndex"] = cell.sheetIndex
            result["cell"] = cell.address
            result["valueKind"] = cell.value.rawValue
        case .pptxParagraph(let object, let placement, let paragraph):
            result["part"] = object.part.text
            result["slide"] = object.slide
            result["objectID"] = object.id
            result["objectKind"] = placement.kind
            result["paragraph"] = paragraph
            if case .table(let row, let column) = placement {
                result["row"] = row
                result["column"] = column
            }
        case .pptxOCR(let object, _):
            result["part"] = object.part.text
            result["slide"] = object.slide
            result["objectID"] = object.id
            result["objectKind"] = "picture"
        }
        if let ocr {
            result["block"] = ocr.number
            result["confidence"] = ocr.confidence
            result["region"] = ocr.region
        }
        result["reader"] = readerBinding?.name
        result["readerFingerprint"] = readerBinding?.fingerprint
        return result
    }

    var title: String {
        switch location {
        case .pdfPage(let page):
            return "Seite \(page) · Zeile \(line)"
        case .pdfTextPage(let page):
            return "Seite \(page) · Textebene · Zeile \(line)"
        case .pdfOCR(let page, let block):
            return "Seite \(page) · OCR · Bereich \(block.number) (ca.) · Zeile \(line)"
        case .imageOCR(let block):
            return "OCR · Bereich \(block.number) (ca.) · Zeile \(line)"
        case .docxParagraph(let part, let role, let paragraph):
            let source = role == .document ? role.label : "\(role.label) (\(part.text))"
            return "\(source) · Absatz \(paragraph) · Zeile \(line)"
        case .odtParagraph(let paragraph):
            return "ODT-Haupttext · Absatz \(paragraph) · Zeile \(line)"
        case .epubParagraph(let part, let chapter, let paragraph):
            return "Kapitel \(chapter) (\(part.text)) · Absatz \(paragraph) · Zeile \(line)"
        case .xlsxCell(let cell):
            return "Blatt \(cell.sheetIndex) „\(cell.sheet.text)“ · Zelle \(cell.address) · \(cell.value.label) · Zeile \(line)"
        case .pptxParagraph(let object, let placement, let paragraph):
            let label: String
            switch placement {
            case .shape: label = "Objekt \(object.id)"
            case .table(let row, let column): label = "Tabelle \(object.id) · Zelle \(row),\(column)"
            }
            return "Folie \(object.slide) · \(label) · Absatz \(paragraph) · Zeile \(line)"
        case .pptxOCR(let object, let block):
            return "Folie \(object.slide) · Bild \(object.id) · OCR · Bereich \(block.number) (ca.) · Zeile \(line)"
        }
    }

    static func parse(_ raw: Any?) -> Self? {
        guard var object = raw as? [String: Any],
              let name = object["kind"] as? String, let kind = Kind(rawValue: name),
              let line = previewInteger(object["line"]), line > 0 else { return nil }
        let binding: ReaderBinding?
        if let reader = object.removeValue(forKey: "reader") {
            guard let name = reader as? String,
                  let parsed = parseReader(name, kind: kind, fingerprint: object.removeValue(forKey: "readerFingerprint")) else { return nil }
            binding = parsed
        } else {
            binding = nil
        }
        guard let location = parseLocation(kind, object: object) else { return nil }
        return Self(location: location, readerBinding: binding, line: line)
    }

    private static func parseReader(_ name: String, kind: Kind, fingerprint: Any?) -> ReaderBinding? {
        let needsFingerprint: Bool
        switch (name, kind) {
        case ("poppler-v1", .pdfPage), ("tesseract-image-v1", .imageOCR),
             ("poppler-tesseract-v1", .pdfTextPage), ("poppler-tesseract-v1", .pdfOCR),
             ("pptx-tesseract-v1", .pptxOCR):
            needsFingerprint = true
        case ("pptx-vision-v1", .pptxParagraph), ("pptx-vision-v1", .pptxOCR),
             ("pptx-tesseract-v1", .pptxParagraph):
            needsFingerprint = false
        default:
            return nil
        }
        if needsFingerprint {
            guard let text = fingerprint as? String, text.utf8.count == 64,
                  text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return ReaderBinding(name: name, fingerprint: text)
        }
        guard fingerprint == nil else { return nil }
        return ReaderBinding(name: name, fingerprint: nil)
    }

    private static func parseLocation(_ kind: Kind, object: [String: Any]) -> Location? {
        let ocrKeys: Set<String> = ["block", "confidence", "region"]
        let slideKeys: Set<String> = ["slide", "objectID", "objectKind"]
        let baseKeys: Set<String> = ["kind", "line"]
        let keys = Set(object.keys)
        // Die älteren Positionsvarianten erlauben unbekannte Zusatzfelder.
        let otherLocationKeys = ocrKeys.union(slideKeys).union(["row", "column"])
        let cellKeys: Set<String> = ["sheet", "sheetIndex", "cell", "valueKind"]

        switch kind {
        case .imageOCR:
            guard keys == baseKeys.union(ocrKeys), let block = parseOCRBlock(object) else { return nil }
            return .imageOCR(block)
        case .pdfOCR:
            guard keys == baseKeys.union(ocrKeys).union(["page"]),
                  let page = previewInteger(object["page"], maximum: 128), page > 0,
                  let block = parseOCRBlock(object) else { return nil }
            return .pdfOCR(page: page, block)
        case .pptxOCR:
            guard keys == baseKeys.union(ocrKeys).union(slideKeys).union(["part"]),
                  object["objectKind"] as? String == "picture",
                  let source = parseSlideObject(object),
                  let block = parseOCRBlock(object) else { return nil }
            return .pptxOCR(source, block)
        case .pdfTextPage:
            guard keys == baseKeys.union(["page"]),
                  let page = previewInteger(object["page"], maximum: 128), page > 0 else { return nil }
            return .pdfTextPage(page)
        case .pdfPage:
            guard keys.isDisjoint(with: otherLocationKeys),
                  let page = previewInteger(object["page"], maximum: 512), page > 0 else { return nil }
            return .pdfPage(page)
        case .pptxParagraph:
            guard keys.isDisjoint(with: cellKeys.union(ocrKeys).union(["partKind", "chapter", "page"])),
                  let source = parseSlideObject(object),
                  let text = parseSlideText(object),
                  let paragraph = parseParagraphNumber(object["paragraph"]) else { return nil }
            return .pptxParagraph(source, text, paragraph: paragraph)
        case .xlsxCell:
            guard keys.isDisjoint(with: otherLocationKeys.union(["paragraph", "chapter", "partKind"])),
                  let part = partName(object["part"]),
                  let sheet = object["sheet"] as? String, !sheet.isEmpty, sheet.unicodeScalars.count <= 256, !sheet.contains("\0"),
                  let sheetIndex = previewInteger(object["sheetIndex"], maximum: 64), sheetIndex > 0,
                  let cell = object["cell"] as? String, validCellAddress(cell),
                  let name = object["valueKind"] as? String, let value = CellValue(rawValue: name) else { return nil }
            return .xlsxCell(WorksheetCell(part: part, sheet: SourceName(text: sheet), sheetIndex: sheetIndex, address: cell, value: value))
        case .docxParagraph, .odtParagraph, .epubParagraph:
            guard keys.isDisjoint(with: otherLocationKeys.union(cellKeys)),
                  let part = partName(object["part"]),
                  let paragraph = parseParagraphNumber(object["paragraph"]) else { return nil }
            return parsePackageParagraph(kind, part: part, paragraph: paragraph, object: object)
        }
    }

    private static func parsePackageParagraph(_ kind: Kind, part: SourceName, paragraph: Int, object: [String: Any]) -> Location? {
        switch kind {
        case .docxParagraph:
            guard let name = object["partKind"] as? String, let role = DOCXPart(rawValue: name),
                  object["chapter"] == nil else { return nil }
            return .docxParagraph(part: part, role: role, paragraph: paragraph)
        case .odtParagraph:
            guard part.text == "content.xml", object["partKind"] == nil, object["chapter"] == nil else { return nil }
            return .odtParagraph(paragraph)
        case .epubParagraph:
            guard object["partKind"] == nil,
                  let chapter = previewInteger(object["chapter"], maximum: 4096), chapter > 0 else { return nil }
            return .epubParagraph(part: part, chapter: chapter, paragraph: paragraph)
        default:
            return nil
        }
    }

    private static func parseOCRBlock(_ object: [String: Any]) -> OCRBlock? {
        guard let block = previewInteger(object["block"], maximum: 4096), block > 0,
              let confidence = object["confidence"] as? NSNumber, CFGetTypeID(confidence) != CFBooleanGetTypeID(),
              confidence.doubleValue.isFinite, (0.5...1).contains(confidence.doubleValue),
              let values = object["region"] as? [NSNumber], values.count == 4,
              values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite && (0...1).contains($0.doubleValue) }) else { return nil }
        let region = values.map(\.doubleValue)
        guard region[2] > 0, region[3] > 0, region[0] + region[2] <= 1.000001,
              region[1] + region[3] <= 1.000001 else { return nil }
        return OCRBlock(number: block, confidence: confidence.doubleValue, region: region)
    }

    private static func parseParagraphNumber(_ raw: Any?) -> Int? {
        guard let value = previewInteger(raw, maximum: 32768), value > 0 else { return nil }
        return value
    }

    private static func partName(_ raw: Any?) -> SourceName? {
        guard let part = raw as? String, !part.isEmpty, part.unicodeScalars.count <= 256,
              !part.hasPrefix("/"), !part.contains("\\"), !part.contains("\0"),
              !part.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return SourceName(text: part)
    }

    private static func parseSlideObject(_ object: [String: Any]) -> SlideObject? {
        guard let part = partName(object["part"]),
              let slide = previewInteger(object["slide"], maximum: 64), slide > 0,
              let id = object["objectID"] as? String, !id.isEmpty, id.utf8.count <= 10,
              (id == "0" || id.utf8.first != 48), id.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = UInt32(id), String(number) == id else { return nil }
        return SlideObject(part: part, slide: slide, id: id)
    }

    private static func parseSlideText(_ object: [String: Any]) -> SlideText? {
        switch object["objectKind"] as? String {
        case "shape":
            guard object["row"] == nil, object["column"] == nil else { return nil }
            return .shape
        case "table":
            guard let row = previewInteger(object["row"], maximum: 131072), row > 0,
                  let column = previewInteger(object["column"], maximum: 131072), column > 0 else { return nil }
            return .table(row: row, column: column)
        default:
            return nil
        }
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
              !pattern.isEmpty, pattern.unicodeScalars.count <= 65536,
              let regex = previewBoolean(object["regex"]),
              let caseSensitive = previewBoolean(object["caseSensitive"]),
              let exact = previewBoolean(object["exact"]),
              let literalWildcards = previewBoolean(object["literalWildcards"]) else { return nil }
        let encoding = object["encoding"] as? String
        let reader = object["documentReader"] as? String
        if object["encoding"] != nil, encoding.flatMap(SearchTextEncoding.init(rawValue:)) == nil { return nil }
        if object["documentReader"] != nil, reader.map(DocumentPosition.readers.values.contains) != true { return nil }
        return Self(pattern: pattern, regex: regex, caseSensitive: caseSensitive, exact: exact,
                    literalWildcards: literalWildcards, encoding: encoding, documentReader: reader)
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
        if object["documentReason"] != nil {
            guard let documentReason, documentReason.utf8.count <= 64,
                  ["document", "ocr", "archive"].contains(where: { documentReason.hasPrefix($0) }) else { return nil }
        }
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
            if let reader = DocumentPosition.readers[encoding] {
                guard snippets.allSatisfy({ $0.documentPosition?.reader == reader && ($0.query == nil || $0.query?.documentReader == reader) }) else { return invalid }
            } else if snippets.contains(where: { $0.documentPosition != nil || $0.query?.documentReader != nil }) { return invalid }
        } else if !snippets.isEmpty { return invalid }
        let archiveLimits = ContentPreviewArchiveLimits.parse(object["archiveLimits"])
        if object["archiveLimits"] != nil && archiveLimits == nil { return invalid }
        let navigation = ContentPreviewNavigation.parse(object["navigation"])
        if object["navigation"] != nil && navigation == nil { return invalid }
        if let encoding, let reader = DocumentPosition.readers[encoding] {
            guard navigation?.contextLines.allSatisfy({ $0.documentPosition?.reader == reader }) ?? true else { return invalid }
        }
        if navigation == nil, generation == nil, encoding == nil, (omitted ?? 0) == 0, let empty = emptyStates[status] { return empty }
        return Self(status: status, sourceGeneration: generation, encoding: encoding, snippets: snippets, omitted: omitted, navigation: navigation, archiveLimits: archiveLimits)
    }
}
