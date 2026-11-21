import Foundation
import ImageIO

func readImage(_ path: String) throws -> (CGImage, CGImagePropertyOrientation) {
    let data = try readDocumentHelperFile(path)
    guard
        let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let type = CGImageSourceGetType(source) as String?,
        [
            "public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif",
            "public.heic", "public.heif",
        ].contains(type),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
        let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
        let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
        width > 0, height > 0
    else { throw OCRFailure(reason: "ocrDamaged") }
    guard CGImageSourceGetCount(source) == 1 else { throw OCRFailure(reason: "ocrMultipleFrames") }
    guard let depth = properties[kCGImagePropertyDepth as String] as? Int,
        (1...DocumentHelperLimits.visionMaximumBitDepth).contains(depth),
        let colorModel = properties[kCGImagePropertyColorModel as String] as? String,
        ["RGB", "Gray"].contains(colorModel)
    else { throw OCRFailure(reason: "ocrDamaged") }
    guard width <= DocumentHelperLimits.ocrEdge, height <= DocumentHelperLimits.ocrEdge,
        width * height <= DocumentHelperLimits.ocrPixels
    else { throw OCRFailure(reason: "ocrLimit") }
    let rawOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
    guard let orientation = CGImagePropertyOrientation(rawValue: rawOrientation),
        let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
        throw OCRFailure(reason: "ocrDamaged")
    }
    return (image, orientation)
}
func request(_ data: Data) -> DocumentHelperReply {
    do {
        guard #available(macOS 13, *) else { return .failure("ocrHelperUnavailable") }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["operation"] as? String == "image", let path = value["path"] as? String,
            Set(value.keys) == ["operation", "path"]
        else { return .failure("ocrReadError") }
        let (image, orientation) = try readImage(path)
        let blocks = try recognizeImageText(image, orientation: orientation)
        return DocumentHelperReply(ok: true, reader: "vision-image-v1", blocks: blocks)
    } catch DocumentHelperFileError.limit {
        return .failure("ocrLimit")
    } catch let error as OCRFailure {
        return .failure(error.reason)
    } catch {
        return .failure("ocrReadError")
    }
}

serveDocumentHelper(request)
