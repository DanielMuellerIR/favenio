import Foundation
import PDFKit
import Darwin

// Nur Datenextraktion. Muster, Kriterien und Fundstellen entscheidet Python.
let pageBytes = 256 * 1024
var document: PDFDocument?
var renderedPages = 0, renderedPixels = 0
let renderDPI = 150.0, renderPixels = 6_000_000, totalRenderPixels = 32_000_000

func readPDF(_ path: String) throws -> PDFDocument {
    let descriptor = open(path, O_RDONLY | O_NONBLOCK)
    guard descriptor >= 0 else { throw OCRFailure(reason: "documentReadError") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { throw OCRFailure(reason: "documentReadError") }
    guard status.st_size <= 64 * 1024 * 1024 else { throw OCRFailure(reason: "documentLimit") }
    let data = try handle.read(upToCount: 64 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 64 * 1024 * 1024 else { throw OCRFailure(reason: "documentLimit") }
    guard let opened = PDFDocument(data: data), opened.pageCount > 0 else { throw OCRFailure(reason: "documentDamaged") }
    guard !opened.isEncrypted, !opened.isLocked else { throw OCRFailure(reason: "documentEncrypted") }
    return opened
}

@available(macOS 13, *)
func recognizePDFPage(_ page: PDFPage) throws -> [[String: Any]] {
    guard (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let reference = page.pageRef else { throw OCRFailure(reason: "documentReadError") }
    let box = reference.getBoxRect(.cropBox), rotated = reference.rotationAngle % 180 != 0
    let rawWidth = ceil((rotated ? box.height : box.width) * renderDPI / 72)
    let rawHeight = ceil((rotated ? box.width : box.height) * renderDPI / 72)
    guard rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0,
          rawWidth <= 4096, rawHeight <= 4096 else { throw OCRFailure(reason: "pdfOCRLimit") }
    let width = Int(rawWidth), height = Int(rawHeight), pixels = width * height
    guard pixels <= renderPixels, renderedPages < 16, renderedPixels + pixels <= totalRenderPixels else { throw OCRFailure(reason: "pdfOCRLimit") }
    renderedPages += 1; renderedPixels += pixels
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw OCRFailure(reason: "pdfOCRLimit") }
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    context.concatenate(reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(reference)
    guard let image = context.makeImage() else { throw OCRFailure(reason: "documentReadError") }
    return try recognizeImageText(image, orientation: .up)
}
func respond(_ object: [String: Any]) {
    var result = object
    result["schemaVersion"] = 1
    guard var data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) else { exit(2) }
    if data.count > 2 * 1024 * 1024 { data = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "ok": false, "reason": "ocrLimit"]) }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}
func request(_ data: Data) {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let operation = value["operation"] as? String else { respond(["ok": false, "reason": "documentReadError"]); return }
    switch operation {
    case "open":
        document = nil
        guard let path = value["path"] as? String else { respond(["ok": false, "reason": "documentReadError"]); return }
        do {
            let opened = try readPDF(path)
            document = opened; renderedPages = 0; renderedPixels = 0
            respond(["ok": true, "pageCount": opened.pageCount, "pdfOCRCapability": 1])
        } catch let error as OCRFailure { respond(["ok": false, "reason": error.reason]) }
        catch { respond(["ok": false, "reason": "documentReadError"]) }
    case "page":
        guard let document, let index = value["index"] as? Int, index >= 0, index < min(document.pageCount, 512),
              let page = document.page(at: index) else { respond(["ok": false, "reason": "documentDamaged"]); return }
        let text = page.string ?? ""
        guard text.utf8.count <= pageBytes else { respond(["ok": false, "reason": "documentLimit"]); return }
        respond(["ok": true, "page": index + 1, "text": text])
    case "ocrPage":
        guard #available(macOS 13, *) else { respond(["ok": false, "reason": "ocrHelperUnavailable"]); return }
        guard let document, let index = value["index"] as? Int, index >= 0, index < min(document.pageCount, 128),
              let page = document.page(at: index) else { respond(["ok": false, "reason": "documentDamaged"]); return }
        do { respond(["ok": true, "reader": "pdfkit-vision-v1", "page": index + 1, "blocks": try recognizePDFPage(page)]) }
        catch let error as OCRFailure { respond(["ok": false, "reason": error.reason]) }
        catch { respond(["ok": false, "reason": "ocrReadError"]) }
    case "close": document = nil; renderedPages = 0; renderedPixels = 0; respond(["ok": true])
    default: respond(["ok": false, "reason": "documentReadError"])
    }
}
var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let end = buffer.firstIndex(of: 10) {
        guard end <= 65536 else { exit(2) }
        let data = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        autoreleasepool { request(data) }
    }
    if buffer.count > 65536 { exit(2) }
}
