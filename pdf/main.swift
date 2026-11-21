import Foundation
import PDFKit

// Nur Datenextraktion. Muster, Kriterien und Fundstellen entscheidet Python.
private struct PDFHelperFailure: Error {
    let reason: String
}

private func readPDF(_ path: String) throws -> PDFDocument {
    let data = try readDocumentHelperFile(path)
    guard let document = PDFDocument(data: data), document.pageCount > 0 else {
        throw PDFHelperFailure(reason: "documentDamaged")
    }
    guard !document.isEncrypted, !document.isLocked else {
        throw PDFHelperFailure(reason: "documentEncrypted")
    }
    return document
}

private final class PDFHelper {
    private var document: PDFDocument?
    private var renderedPages = 0
    private var renderedPixels = 0

    private func reset() {
        document = nil
        renderedPages = 0
        renderedPixels = 0
    }

    @available(macOS 13, *)
    private func recognizePDFPage(_ page: PDFPage) throws -> [OCRTextBlock] {
        let renderDPI = CGFloat(DocumentHelperLimits.pdfOCRDPI)
        let renderEdge = CGFloat(DocumentHelperLimits.pdfOCRRenderEdge)
        guard (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let reference = page.pageRef
        else { throw PDFHelperFailure(reason: "documentReadError") }
        let box = reference.getBoxRect(.cropBox)
        let rotated = reference.rotationAngle % 180 != 0
        let rawWidth = ceil((rotated ? box.height : box.width) * renderDPI / 72)
        let rawHeight = ceil((rotated ? box.width : box.height) * renderDPI / 72)
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0,
            rawWidth <= renderEdge, rawHeight <= renderEdge
        else { throw PDFHelperFailure(reason: "pdfOCRLimit") }
        let width = Int(rawWidth)
        let height = Int(rawHeight)
        let pixels = width * height
        guard pixels <= DocumentHelperLimits.pdfOCRRenderPixels,
            renderedPages < DocumentHelperLimits.pdfOCRRenderedPages,
            renderedPixels + pixels <= DocumentHelperLimits.pdfOCRTotalRenderPixels
        else {
            throw PDFHelperFailure(reason: "pdfOCRLimit")
        }
        renderedPages += 1
        renderedPixels += pixels
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PDFHelperFailure(reason: "pdfOCRLimit") }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.concatenate(
            reference.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw PDFHelperFailure(reason: "documentReadError") }
        return try recognizeImageText(image, orientation: .up)
    }

    func request(_ data: Data) -> DocumentHelperReply {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let operation = value["operation"] as? String
        else { return .failure("documentReadError") }
        switch operation {
        case "open":
            reset()
            guard let path = value["path"] as? String else { return .failure("documentReadError") }
            do {
                let opened = try readPDF(path)
                document = opened
                return DocumentHelperReply(ok: true, pageCount: opened.pageCount, pdfOCRCapability: 1)
            } catch DocumentHelperFileError.limit {
                return .failure("documentLimit")
            } catch let error as PDFHelperFailure {
                return .failure(error.reason)
            } catch {
                return .failure("documentReadError")
            }
        case "page":
            guard let (index, page) = page(value, limit: DocumentHelperLimits.documentPages) else {
                return .failure("documentDamaged")
            }
            let text = page.string ?? ""
            guard text.utf8.count <= DocumentHelperLimits.documentPageBytes else {
                return .failure("documentLimit")
            }
            return DocumentHelperReply(ok: true, page: index + 1, text: text)
        case "ocrPage":
            guard #available(macOS 13, *) else { return .failure("ocrHelperUnavailable") }
            guard let (index, page) = page(value, limit: DocumentHelperLimits.pdfOCRPages) else {
                return .failure("documentDamaged")
            }
            do {
                let blocks = try recognizePDFPage(page)
                return DocumentHelperReply(
                    ok: true, reader: "pdfkit-vision-v1", blocks: blocks, page: index + 1)
            } catch let error as PDFHelperFailure {
                return .failure(error.reason)
            } catch let error as OCRFailure {
                return .failure(error.reason)
            } catch {
                return .failure("ocrReadError")
            }
        case "close":
            reset()
            return DocumentHelperReply(ok: true)
        default:
            return .failure("documentReadError")
        }
    }

    private func page(_ request: [String: Any], limit: Int) -> (Int, PDFPage)? {
        guard let document, let index = request["index"] as? Int,
            index >= 0, index < min(document.pageCount, limit),
            let page = document.page(at: index)
        else { return nil }
        return (index, page)
    }
}

serveDocumentHelper(PDFHelper().request)
