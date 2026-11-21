import Foundation
import ImageIO
import Vision

struct OCRFailure: Error { let reason: String }

struct OCRTextBlock: Encodable {
    let block: Int
    let text: String
    let confidence: Double
    let region: [Double]
}

@available(macOS 13, *)
func recognizeImageText(_ image: CGImage, orientation: CGImagePropertyOrientation) throws -> [OCRTextBlock] {
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["de-DE", "en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = Float(DocumentHelperLimits.visionMinimumTextHeight)
    let languages = try request.supportedRecognitionLanguages()
    guard request.recognitionLanguages.allSatisfy(languages.contains) else {
        throw OCRFailure(reason: "ocrHelperUnavailable")
    }
    try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
    let observations = request.results ?? []
    guard observations.count <= DocumentHelperLimits.ocrBlocks else { throw OCRFailure(reason: "ocrLimit") }
    let ordered = observations.enumerated().sorted {
        let left = $0.element.boundingBox
        let right = $1.element.boundingBox
        if left.maxY != right.maxY { return left.maxY > right.maxY }
        if left.minX != right.minX { return left.minX < right.minX }
        return $0.offset < $1.offset
    }
    var result: [OCRTextBlock] = []
    var total = 0
    for observation in ordered {
        guard let candidate = observation.element.topCandidates(1).first, !candidate.string.isEmpty,
            candidate.confidence.isFinite,
            candidate.confidence >= Float(DocumentHelperLimits.ocrMinimumConfidence)
        else { continue }
        let box = observation.element.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let region = [box.minX, box.minY, box.width, box.height].map(Double.init)
        guard !box.isNull, box.width > 0, box.height > 0,
            region.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else {
            throw OCRFailure(reason: "ocrReadError")
        }
        let bytes = candidate.string.utf8.count
        total += bytes
        guard total <= DocumentHelperLimits.ocrTextBytes, bytes <= DocumentHelperLimits.ocrBlockBytes else {
            throw OCRFailure(reason: "ocrLimit")
        }
        result.append(
            OCRTextBlock(
                block: result.count + 1, text: candidate.string,
                confidence: Double(candidate.confidence), region: region))
    }
    return result
}
