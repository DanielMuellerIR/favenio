import Foundation
import ImageIO
import Darwin

let maximumBytes = 64 * 1024 * 1024
func response(_ object: [String: Any]) {
    var value = object; value["schemaVersion"] = 1
    guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { exit(2) }
    if data.count > 2 * 1024 * 1024 {
        data = try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "ok": false, "reason": "ocrLimit"])
    }
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}
func readImage(_ path: String) throws -> (CGImage, CGImagePropertyOrientation) {
    let descriptor = open(path, O_RDONLY | O_NONBLOCK)
    guard descriptor >= 0 else { throw OCRFailure(reason: "ocrReadError") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var information = stat()
    guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG else { throw OCRFailure(reason: "ocrReadError") }
    guard information.st_size <= maximumBytes else { throw OCRFailure(reason: "ocrLimit") }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw OCRFailure(reason: "ocrLimit") }
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let type = CGImageSourceGetType(source) as String?,
          ["public.png", "public.jpeg", "public.tiff", "com.microsoft.bmp", "com.compuserve.gif", "public.heic", "public.heif"].contains(type),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
          let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
          width > 0, height > 0 else { throw OCRFailure(reason: "ocrDamaged") }
    guard CGImageSourceGetCount(source) == 1 else { throw OCRFailure(reason: "ocrMultipleFrames") }
    guard let depth = properties[kCGImagePropertyDepth as String] as? Int, (1...16).contains(depth),
          let colorModel = properties[kCGImagePropertyColorModel as String] as? String,
          ["RGB", "Gray"].contains(colorModel) else { throw OCRFailure(reason: "ocrDamaged") }
    guard width <= 8192, height <= 8192, width * height <= 12_000_000 else { throw OCRFailure(reason: "ocrLimit") }
    let rawOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
    guard let orientation = CGImagePropertyOrientation(rawValue: rawOrientation),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
        throw OCRFailure(reason: "ocrDamaged")
    }
    return (image, orientation)
}
func request(_ data: Data) {
    do {
        guard #available(macOS 13, *) else { throw OCRFailure(reason: "ocrHelperUnavailable") }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["operation"] as? String == "image", let path = value["path"] as? String,
              Set(value.keys) == ["operation", "path"] else { throw OCRFailure(reason: "ocrReadError") }
        let (image, orientation) = try readImage(path)
        let blocks = try recognizeImageText(image, orientation: orientation)
        response(["ok": true, "reader": "vision-image-v1", "blocks": blocks])
    } catch let error as OCRFailure { response(["ok": false, "reason": error.reason]) }
    catch { response(["ok": false, "reason": "ocrReadError"]) }
}
var buffer = Data()
while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty { break }
    buffer.append(chunk)
    while let end = buffer.firstIndex(of: 10) {
        guard end <= 65536 else { exit(2) }
        let data = Data(buffer[..<end]); buffer.removeSubrange(...end)
        autoreleasepool { request(data) }
    }
    if buffer.count > 65536 { exit(2) }
}
