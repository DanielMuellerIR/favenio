import Darwin
import Foundation

struct DocumentHelperReply: Encodable {
    let schemaVersion = 1
    let ok: Bool
    var reason: String? = nil
    var reader: String? = nil
    var blocks: [OCRTextBlock]? = nil
    var pageCount: Int? = nil
    var pdfOCRCapability: Int? = nil
    var page: Int? = nil
    var text: String? = nil

    static func failure(_ reason: String) -> Self {
        Self(ok: false, reason: reason)
    }
}

enum DocumentHelperFileError: Error {
    case unreadable
    case limit
}

func readDocumentHelperFile(_ path: String) throws -> Data {
    let maximumBytes = DocumentHelperLimits.documentBytes
    let descriptor = open(path, O_RDONLY | O_NONBLOCK)
    guard descriptor >= 0 else { throw DocumentHelperFileError.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }

    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
        throw DocumentHelperFileError.unreadable
    }
    guard status.st_size <= maximumBytes else { throw DocumentHelperFileError.limit }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw DocumentHelperFileError.limit }
    return data
}

func serveDocumentHelper(_ handleRequest: (Data) -> DocumentHelperReply) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let maximumRequestBytes = 65_536
    let maximumReplyBytes = 2 * 1024 * 1024
    var buffer = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { return }
        buffer.append(chunk)
        while let end = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: end) <= maximumRequestBytes else { exit(2) }
            let request = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            autoreleasepool {
                do {
                    var reply = try encoder.encode(handleRequest(request))
                    if reply.count > maximumReplyBytes {
                        reply = try encoder.encode(DocumentHelperReply.failure("ocrLimit"))
                    }
                    reply.append(10)
                    try FileHandle.standardOutput.write(contentsOf: reply)
                } catch {
                    exit(2)
                }
            }
        }
        if buffer.count > maximumRequestBytes { exit(2) }
    }
}
