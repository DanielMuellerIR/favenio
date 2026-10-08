import Foundation
import CoreFoundation
import Darwin

struct SearchControlFailure: Error {
    let code: String
    let message: String
    var object: [String: Any] { ["code": code, "message": message] }
}

enum SearchControlWire {
    static let maximumRequestBytes = 65_536
    static let maximumReplyBytes = 1_048_576
    static let maximumPage = 128
    static let operations = ["capabilities", "configuration", "configure", "start", "replace", "cancel", "status", "results", "select", "handoff", "handoffStatus", "cancelHandoff", "captureRecording", "openRecording"]
    static var capabilities: [String: Any] {
        ["protocolVersion": 1, "operations": operations,
         "maximumRequestBytes": maximumRequestBytes, "maximumReplyBytes": maximumReplyBytes,
         "maximumPage": maximumPage, "fastraSourceSnapshotSchemaVersion": 1,
         "maximumHandoffBytes": 262_144, "handoffTimeoutSeconds": 30, "recordingSchemaVersion": 1,
         "maximumRecordingBytes": 48_000, "maximumRecordingHits": 128]
    }
    static func endpoint(_ identifier: String) -> String {
        "\(identifier).search-control.\(getuid()).v1"
    }
    static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"protocolVersion":1,"error":{"code":"delivery","message":"Antwort konnte nicht kodiert werden."}}"#.utf8)
    }
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue < Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
    static func decode(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(object["version"]) == 1,
              let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let operation = object["operation"] as? String, operations.contains(operation),
              let deadline = object["deadline"] as? NSNumber,
              CFGetTypeID(deadline) != CFBooleanGetTypeID(), deadline.doubleValue.isFinite else {
            throw SearchControlFailure(code: "invalidRequest", message: "Ungültiger Steuerungsauftrag (Version, UUID, Operation oder Frist).")
        }
        let extras: [String: Set<String>] = [
            "configure": ["configuration"], "captureRecording": ["runID"], "openRecording": ["recording"], "results": ["runID", "generation", "offset", "limit"],
            "cancel": ["runID"], "select": ["runID", "identity"],
            "handoff": ["runID", "identity"], "handoffStatus": ["jobID"], "cancelHandoff": ["jobID"]]
        let allowed = Set(["version", "id", "operation", "deadline", "runtimeID", "windowID"])
            .union(extras[operation] ?? [])
        guard Set(object.keys).isSubset(of: allowed), !object.values.contains(where: { $0 is NSNull }) else {
            throw SearchControlFailure(code: "invalidRequest", message: "Unbekannte oder leere Auftragsfelder.")
        }
        for key in ["runtimeID", "windowID"] where object[key] != nil {
            guard let id = object[key] as? String, UUID(uuidString: id) != nil else {
                throw SearchControlFailure(code: "invalidRequest", message: "Ungültige Zielkennung.")
            }
        }
        return object
    }
}

final class SearchControlServer {
    private var port: CFMessagePort?
    private let handler: (Data) -> Data
    private let queue = DispatchQueue(label: "Favenio.searchControl.transport")
    init(name: String, handler: @escaping (Data) -> Data) {
        self.handler = handler
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        var shouldFree = DarwinBoolean(false)
        port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let data, let info, CFDataGetLength(data) <= SearchControlWire.maximumRequestBytes else { return nil }
            let server = Unmanaged<SearchControlServer>.fromOpaque(info).takeUnretainedValue()
            return Unmanaged.passRetained(server.handler(data as Data) as CFData)
        }, &context, &shouldFree)
        // Ein Port im eigenen Prozess kann zu einem anderen Controller gehören.
        if shouldFree.boolValue { port = nil }
        if let port { CFMessagePortSetDispatchQueue(port, queue) }
    }
    var isListening: Bool { port != nil }
    deinit { if let port { CFMessagePortInvalidate(port) } }
}

enum SearchControlClient {
    static func available(_ name: String) -> Bool { CFMessagePortCreateRemote(nil, name as CFString) != nil }
    static func send(_ data: Data, name: String, timeout: TimeInterval) -> Data? {
        guard timeout > 0, data.count <= SearchControlWire.maximumRequestBytes,
              let port = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }
        var response: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(port, 1, data as CFData, min(timeout, 0.25), timeout,
                                             CFRunLoopMode.defaultMode.rawValue, &response)
        guard result == kCFMessagePortSuccess, let response else { return nil }
        let bytes = response.takeRetainedValue() as Data
        return bytes.count <= SearchControlWire.maximumReplyBytes ? bytes : nil
    }
}
