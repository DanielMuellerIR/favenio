import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DuplicateProgress: Codable {
    let type: String
    let schemaVersion: Int
    let phase: String
    let done: Int
    let total: Int
    let readBytes: Int64
    let currentID: String?
}

struct DuplicateResult: Codable {
    struct Group: Codable {
        let id: String
        let memberIDs: [String]
        let sha256: String
        let size: Int64
        let physicalFiles: Int
        let byteVerified: Bool
    }
    struct File: Codable {
        let sourceGeneration: [String: String]
        let size: Int64
        let linkKind: String
        let linkCount: Int
        let guardGeneration: [String: String]?
    }
    struct Issue: Codable { let id: String?; let reason: String; let message: String }
    let type: String
    let schemaVersion: Int
    let state: String
    let complete: Bool
    let checkedAt: String
    let scopeCount: Int
    let hashedFiles: Int
    let readBytes: Int64
    let groups: [Group]
    let files: [String: File]
    let issueCount: Int
    let issues: [Issue]

    func validate(ids: Set<String>, guarded: [String: ContentSourceGeneration] = [:]) -> Bool {
        guard type == "duplicateResult", [1, 2, 3].contains(schemaVersion),
              ["completed", "partial", "limited", "cancelled"].contains(state),
              complete == (state == "completed"), scopeCount == ids.count,
              (0...scopeCount).contains(hashedFiles), (0...(64 * 1024 * 1024 * 1024 + 1)).contains(readBytes),
              (0...scopeCount + 1).contains(issueCount), issues.count == min(32, issueCount),
              (state != "completed" || issueCount == 0), (state != "partial" || issueCount > 0),
              (!["limited", "cancelled"].contains(state) || groups.isEmpty),
              ISO8601DateFormatter().date(from: checkedAt) != nil else { return false }
        var members = Set<String>(), groupIDs = Set<String>()
        for group in groups {
            guard groupIDs.insert(group.id).inserted, group.memberIDs.count >= 2,
                  group.byteVerified, group.size >= 0,
                  (1...group.memberIDs.count).contains(group.physicalFiles),
                  group.sha256.utf8.count == 64,
                  group.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
            var physical = Set<String>()
            for id in group.memberIDs {
                guard ids.contains(id), members.insert(id).inserted, let file = files[id],
                      file.size == group.size, file.linkCount > 0,
                      ["regular", "hardlink", "symbolic"].contains(file.linkKind),
                      let generation = ContentSourceGeneration.parse(file.sourceGeneration),
                      generation.size == String(file.size) else { return false }
                if let expected = guarded[id] {
                    guard ContentSourceGeneration.parse(file.guardGeneration) == expected else { return false }
                } else if file.guardGeneration != nil { return false }
                physical.insert(generation.device + ":" + generation.inode)
            }
            guard physical.count == group.physicalFiles else { return false }
        }
        return Set(files.keys) == members && issues.allSatisfy { ($0.id == nil || ids.contains($0.id!)) && !$0.message.isEmpty }
    }
}

private func duplicatePipeChunk(_ handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        // read(upToCount:) wartet bei Pipes mitunter auf die gesamte Länge oder EOF.
        #if canImport(Darwin)
        let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        #else
        let count = bytes.withUnsafeMutableBytes { Glibc.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        #endif
        if count >= 0 { return Data(bytes.prefix(count)) }
        if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

// Prozess/Abbruchzustand ist gesperrt; die Vorbereitung besitzt eine eigene Queue.
final class DuplicateJob: @unchecked Sendable {
    enum Failure: Error { case invalid(String), cancelled }
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var directory: URL?
    private var leases: [MaterializationRequest] = []
    private var finished = false
    private let began = ProcessInfo.processInfo.systemUptime
    private let materializer: MaterializationManager
    init(materializer: MaterializationManager = .shared) { self.materializer = materializer }

    private func releaseLeases() {
        lock.lock(); let held = leases; leases = []; lock.unlock()
        for request in held { request.cancel(); request.release() }
    }
    var activePID: Int32? { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true ? process?.processIdentifier : nil }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func cancel(force: Bool = false) {
        lock.lock(); stopped = true
        let child = process, root = directory
        lock.unlock()
        releaseLeases()
        if let child, child.isRunning {
            if force { kill(child.processIdentifier, SIGKILL) } else { child.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func run(hits: [Hit], localOnly: Bool, progress: @escaping (DuplicateProgress) -> Void,
             completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
        guard hits.count <= 50000, hits.allSatisfy({ $0.filesystemPath.hasPrefix("/") && !$0.filesystemPath.utf8.contains(0) && $0.filesystemPath.utf8.count <= 16384 }) else {
            searchDeliveryQueue.async { completion(.failure(Failure.invalid("Ungültige oder zu große Dublettenmenge."))) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let expired = !self.stopped && !self.finished; self.lock.unlock()
            if expired {
                self.cancel()
                searchDeliveryQueue.async { completion(.failure(Failure.invalid("Zeitgrenze einschließlich Archivvorbereitung erreicht."))) }
            }
        }
        Preparation(job: self, hits: hits, localOnly: localOnly, progress: progress, completion: completion).start()
    }

    // Alle veränderlichen Vorbereitungsdaten gehören ausschließlich queue.
    private final class Preparation: @unchecked Sendable {
        let job: DuplicateJob
        let hits: [Hit]
        let localOnly: Bool
        let progress: (DuplicateProgress) -> Void
        let completion: (Result<DuplicateResult, Error>) -> Void
        private let queue = DispatchQueue(label: "favenio.duplicate-preparation", qos: .userInitiated)
        private var records: [[String: Any]]
        private var guards: [String: ContentSourceGeneration] = [:]
        private let members: [Int]
        private var position = 0
        private var usedBytes: Int64 = 0

        init(job: DuplicateJob, hits: [Hit], localOnly: Bool, progress: @escaping (DuplicateProgress) -> Void,
             completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
            self.job = job; self.hits = hits; self.localOnly = localOnly
            self.progress = progress; self.completion = completion
            records = hits.enumerated().map { pair in
                var value: [String: Any] = ["id": String(pair.offset), "filesystemPath": pair.element.filesystemPath]
                if let raw = pair.element.filesystemPathBytes { value["filesystemPathBytes"] = raw.base64EncodedString() }
                return value
            }
            members = hits.indices.filter { hits[$0].isMember }
        }
        func start() { queue.async { self.advance() } }
        private func unavailable(_ index: Int, _ reason: String, _ message: String) {
            records[index] = ["id": String(index), "filesystemPath": hits[index].filesystemPath,
                              "unavailable": ["reason": reason, "message": String(String.UnicodeScalarView(message.unicodeScalars.suffix(1024)))]]
        }
        private func continuePreparation() {
            position += 1
            queue.async { self.advance() }
        }
        private func advance() {
            guard !job.isStopped else { return }
            guard position < members.count else {
                job.execute(hits: hits, records: records, guarded: guards, localOnly: localOnly, progress: progress, completion: completion)
                return
            }
            let index = members[position], hit = hits[index]
            let budget = hit.contentPreview?.archiveLimits
            let reserve = Int64(budget?.memberBytes ?? 256 * 1024 * 1024)
            guard reserve > 0, reserve <= 256 * 1024 * 1024,
                  (budget?.totalBytes ?? 1024 * 1024 * 1024) <= 1024 * 1024 * 1024,
                  (budget?.ratio ?? 1000) <= 1000 else {
                unavailable(index, "archiveLimit", "Gespeicherte Archivgrenzen überschreiten 256 MiB je Mitglied, 1 GiB je Auftrag oder Ratio 1000.")
                continuePreparation(); return
            }
            guard reserve <= 1024 * 1024 * 1024 - usedBytes else {
                unavailable(index, "archiveLimit", "Keine ausreichende Reserve für das nächste Archivmitglied (höchstens 1 GiB befristete Dateien).")
                continuePreparation(); return
            }
            let event = DuplicateProgress(type: "duplicateProgress", schemaVersion: 2, phase: "materialize", done: position, total: members.count, readBytes: usedBytes, currentID: String(index))
            searchDeliveryQueue.async { if !self.job.isStopped { self.progress(event) } }
            if localOnly, let message = job.validateLocalArchiveRoot(hit) {
                guard !job.isStopped else { return }
                unavailable(index, "archiveError", message)
                continuePreparation(); return
            }
            let request = job.materializer.request(hit, localOnly: localOnly, ephemeral: true) { outcome in
                self.queue.async(execute: DispatchWorkItem { self.receive(outcome, index: index, reserve: reserve) })
            }
            if let request {
                job.lock.lock(); let cancelled = job.stopped
                if !cancelled { job.leases.append(request) }
                job.lock.unlock()
                if cancelled { request.cancel(); request.release() }
            }
        }
        private func receive(_ outcome: MaterializationOutcome, index: Int, reserve: Int64) {
            guard !job.isStopped else { return }
            let hit = hits[index]
            switch outcome {
            case .ready(let url):
                if let proof = job.materializer.generationSnapshot(for: hit, url: url),
                   let size = Int64(proof.leaf.size), size >= 0, size <= reserve {
                    usedBytes += size; guards[String(index)] = proof.source
                    var sourceGuard: [String: Any] = ["filesystemPath": hit.filesystemPath, "generation": proof.source.json]
                    if let raw = hit.filesystemPathBytes { sourceGuard["filesystemPathBytes"] = raw.base64EncodedString() }
                    records[index] = ["id": String(index), "filesystemPath": url.path, "expectedGeneration": proof.leaf.json,
                                      "sourceGuard": sourceGuard]
                } else { unavailable(index, "archiveError", "Materialisierung ohne passenden Generationsbeleg oder zu groß.") }
            case .failed(let message): unavailable(index, "archiveError", message)
            case .cancelled: unavailable(index, "archiveError", "Materialisierung abgebrochen.")
            }
            continuePreparation()
        }
    }

    private func validateLocalArchiveRoot(_ hit: Hit) -> String? {
        guard !isStopped, let cli = findCLI(),
              let data = try? JSONSerialization.data(withJSONObject: ["filesystemPath": hit.filesystemPath, "archiveMembers": [String]()]),
              let text = String(data: data, encoding: .utf8) else { return "Archivwurzel nicht prüfbar." }
        let child = Process(), output = Pipe(), errors = Pipe(), diagnostics = SearchDiagnostics()
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = [cli, "--local-only", "--extract-json", text]
        child.standardInput = FileHandle.nullDevice; child.standardOutput = output; child.standardError = errors
        diagnostics.collect(from: errors)
        lock.lock()
        if stopped { lock.unlock(); diagnostics.finish(errors); return "Abgebrochen." }
        do { try child.run(); process = child; lock.unlock() }
        catch { lock.unlock(); diagnostics.finish(errors); return error.localizedDescription }
        let until = ProcessInfo.processInfo.systemUptime + 2
        while child.isRunning && !isStopped && ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.01) }
        if child.isRunning {
            child.terminate(); Thread.sleep(forTimeInterval: 0.05)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        child.waitUntilExit()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        diagnostics.finish(errors)
        lock.lock(); if process === child { process = nil }; lock.unlock()
        guard !isStopped, child.terminationStatus == 0, result.count > 1, result.count <= 16385 else {
            return diagnostics.errorMessage ?? "Archivwurzel nicht sicher lokal verfügbar oder Vortest abgebrochen."
        }
        return nil
    }

    private func execute(hits: [Hit], records: [[String: Any]], guarded: [String: ContentSourceGeneration], localOnly: Bool,
                         progress: @escaping (DuplicateProgress) -> Void,
                         completion: @escaping (Result<DuplicateResult, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { releaseLeases(); lock.lock(); finished = true; lock.unlock() }
            do {
                guard let cli = findCLI(), hits.count <= 50000 else { throw Failure.invalid("Kern fehlt oder mehr als 50000 Dateien.") }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("favenio-duplicates-" + UUID().uuidString)
                lock.lock()
                if stopped { lock.unlock(); throw Failure.cancelled }
                do {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    directory = root
                    lock.unlock()
                } catch { lock.unlock(); throw error }
                defer { try? FileManager.default.removeItem(at: root) }
                let request = root.appendingPathComponent("request.json")
                guard FileManager.default.createFile(atPath: request.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure.cancelled }
                let writer = try FileHandle(forWritingTo: request)
                defer { try? writer.close() }
                var bytes = 0
                func write(_ data: Data) throws {
                    if isStopped { throw Failure.cancelled }
                    bytes += data.count
                    guard bytes <= 32 * 1024 * 1024 else { throw Failure.invalid("Auftrag überschreitet 32 MiB.") }
                    try writer.write(contentsOf: data)
                }
                let remaining = 300 - (ProcessInfo.processInfo.systemUptime - began)
                guard remaining > 0 else { throw Failure.invalid("Zeitgrenze erreicht.") }
                let rawPaths = records.contains { $0["filesystemPathBytes"] != nil || ($0["sourceGuard"] as? [String: Any])?["filesystemPathBytes"] != nil }
                let schema = rawPaths ? "3" : "2"
                try write(Data(("{\"schemaVersion\":" + schema + ",\"limits\":{\"maxSeconds\":" + String(remaining) + "},\"items\":[").utf8))
                for (index, record) in records.enumerated() {
                    if index > 0 { try write(Data(",".utf8)) }
                    try write(JSONSerialization.data(withJSONObject: record))
                }
                try write(Data("]}".utf8)); try writer.close()
                let child = Process(), output = Pipe(), errors = Pipe()
                child.executableURL = URL(fileURLWithPath: pythonPath)
                child.arguments = [cli, "--duplicates-file", request.path] + (localOnly ? ["--local-only"] : [])
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = output; child.standardError = errors
                lock.lock()
                if stopped { lock.unlock(); throw Failure.cancelled }
                do { try child.run(); process = child; lock.unlock() }
                catch { lock.unlock(); throw error }
                defer {
                    if child.isRunning { child.terminate(); if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
                    child.waitUntilExit()
                    try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
                }
                let errorGroup = DispatchGroup(), diagnostic = DuplicateDiagnostic()
                errorGroup.enter()
                DispatchQueue.global().async {
                    defer { errorGroup.leave() }
                    while let data = try? duplicatePipeChunk(errors.fileHandleForReading), !data.isEmpty { diagnostic.append(data) }
                }
                var buffer = Data(), result: DuplicateResult?
                let ids = Set(hits.indices.map(String.init))
                func line(_ data: Data) throws {
                    guard !data.isEmpty, result == nil else { throw Failure.invalid("Ungültiger Antwortstrom.") }
                    if let value = try? JSONDecoder().decode(DuplicateProgress.self, from: data) {
                        guard value.type == "duplicateProgress", [1, 2, 3].contains(value.schemaVersion),
                              ["facts", "hash", "confirm", "validate"].contains(value.phase),
                              (0...hits.count).contains(value.total), (0...value.total).contains(value.done),
                              value.readBytes >= 0, value.currentID == nil || ids.contains(value.currentID!) else { throw Failure.invalid("Ungültiger Fortschritt.") }
                        searchDeliveryQueue.async { if !self.isStopped { progress(value) } }
                    } else {
                        let value = try JSONDecoder().decode(DuplicateResult.self, from: data)
                        guard value.validate(ids: ids, guarded: guarded) else { throw Failure.invalid("Ungültiger Dublettenbeleg.") }
                        result = value
                    }
                }
                while true {
                    let data = try duplicatePipeChunk(output.fileHandleForReading)
                    if data.isEmpty { break }
                    if isStopped { throw Failure.cancelled }
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 10) {
                        let frame = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        guard frame.count <= 32 * 1024 * 1024 else { throw Failure.invalid("Antwort überschreitet 32 MiB.") }
                        try line(frame)
                    }
                    guard buffer.count <= 32 * 1024 * 1024 else { throw Failure.invalid("Antwort überschreitet 32 MiB.") }
                }
                if !buffer.isEmpty { try line(buffer) }
                child.waitUntilExit(); errorGroup.wait()
                guard !isStopped else { throw Failure.cancelled }
                guard child.terminationReason == .exit, let result,
                      child.terminationStatus == (result.complete ? (result.groups.isEmpty ? 1 : 0) : 2) else {
                    throw Failure.invalid(diagnostic.text.isEmpty ? "Kern ohne vollständigen Dublettenbeleg beendet." : diagnostic.text)
                }
                searchDeliveryQueue.async { if !self.isStopped { completion(.success(result)) } }
            } catch {
                searchDeliveryQueue.async { if !self.isStopped { completion(.failure(error)) } }
            }
        }
    }
}

private final class DuplicateDiagnostic {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk.prefix(max(0, 65536 - data.count))) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
