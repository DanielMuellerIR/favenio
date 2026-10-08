import AppKit
import CryptoKit
import Darwin

struct HandoffSourceState: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    init(_ value: stat) {
        device = UInt64(value.st_dev); inode = UInt64(value.st_ino); size = UInt64(max(0, value.st_size))
        modificationSeconds = Int64(value.st_mtimespec.tv_sec); modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changeSeconds = Int64(value.st_ctimespec.tv_sec); changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }
    var object: [String: Any] {
        ["device": device, "inode": inode, "size": size,
         "modificationSeconds": modificationSeconds, "modificationNanoseconds": modificationNanoseconds,
         "changeSeconds": changeSeconds, "changeNanoseconds": changeNanoseconds]
    }
    static func read(_ url: URL, limit: Int?, check: () throws -> Void) throws -> (HandoffSourceState, Data?) {
        try check()
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw SearchControlFailure(code: "sourceUnavailable", message: "Quelle ist nicht lesbar.") }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            throw SearchControlFailure(code: "sourceUnavailable", message: "Quelle ist keine reguläre Datei.")
        }
        let state = HandoffSourceState(before)
        var data: Data?
        if let limit {
            guard state.size <= UInt64(limit) else { throw SearchControlFailure(code: "capacity", message: "Quelle überschreitet die zulässige Größe.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var bytes = Data()
            while true {
                try check()
                let chunk = try handle.read(upToCount: min(262_144, limit - bytes.count + 1)) ?? Data()
                if chunk.isEmpty { break }
                bytes.append(chunk)
                guard bytes.count <= limit else { throw SearchControlFailure(code: "capacity", message: "Quelle überschreitet die zulässige Größe.") }
            }
            data = bytes
        }
        var after = stat()
        var current = stat()
        guard fstat(descriptor, &after) == 0, stat(url.path, &current) == 0,
              state == HandoffSourceState(after), state == HandoffSourceState(current) else {
            throw SearchControlFailure(code: "stale", message: "Quelle wurde während der Übergabe verändert.")
        }
        return (state, data)
    }
}

final class FastraHandoffController {
    static let applicationID = "de.dm0.fastra"
    static let maximumLeafBytes = 262_144
    static let maximumOuterBytes = 67_108_864
    static let lifetime: TimeInterval = 30
    weak var owner: LocalSearchController?
    // Transport und App-Start lassen sich getrennt vom Dateivertrag prüfen.
    var send: (Data, String, TimeInterval) -> Data? = { SearchControlClient.send($0, name: $1, timeout: $2) }
    var ensureApplication: ((@escaping (Bool) -> Void) -> Void)?
    private(set) var jobs: [String: Job] = [:]
    private var order: [String] = []
    private let work = DispatchQueue(label: "Favenio.fastraHandoff", qos: .userInitiated)
    private(set) var isShuttingDown = false

    final class Job {
        let id = UUID().uuidString
        let run: ControlledSearchRun
        let hit: Hit
        let deadline = ProcessInfo.processInfo.systemUptime + FastraHandoffController.lifetime
        let materializer = MaterializationManager()
        let lock = NSLock()
        var stopped = false
        var process: Process?
        var request: MaterializationRequest?
        var state = "preparing"
        var error: SearchControlFailure?
        var receipt: [String: Any]?
        var source: HandoffSourceState?
        var outerHash: String?
        init(hit: Hit, run: ControlledSearchRun) { self.hit = hit; self.run = run }
        var terminal: Bool { ["ready", "failed", "cancelled"].contains(state) }
        var object: [String: Any] {
            var value: [String: Any] = ["id": id, "runID": run.id, "identity": LocalSearchController.identityObject(hit.identity), "state": state]
            if let error { value["error"] = error.object }
            if let receipt { value["fastra"] = receipt }
            return value
        }
        func check() throws {
            lock.lock(); let cancelled = stopped; lock.unlock()
            if cancelled { throw SearchControlFailure(code: "cancelled", message: "Übergabe abgebrochen.") }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw SearchControlFailure(code: "expired", message: "Übergabe hat ihre 30-Sekunden-Frist überschritten.") }
        }
        func stop() {
            lock.lock(); stopped = true; let running = process; lock.unlock()
            if let running, running.isRunning {
                running.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if running.isRunning { kill(running.processIdentifier, SIGKILL) }
                }
            }
            request?.cancel(); materializer.cleanup()
        }
    }

    init(owner: LocalSearchController) { self.owner = owner }
    var busy: Bool { jobs.values.contains { !$0.terminal } }

    func start(hit: Hit, run: ControlledSearchRun) throws -> Job {
        precondition(Thread.isMainThread)
        guard !isShuttingDown else { throw SearchControlFailure(code: "busy", message: "Favenio wird beendet.") }
        guard !busy else { throw SearchControlFailure(code: "busy", message: "Eine Fastra-Übergabe läuft bereits.") }
        guard !hit.isDirectory else { throw SearchControlFailure(code: "sourceUnavailable", message: "Ordner können nicht als Textsnapshot an Fastra übergeben werden.") }
        guard !hit.isMember || (hit.archiveMembers.count == hit.archiveMemberBytes.count && !hit.archiveMemberBytes.isEmpty) else {
            throw SearchControlFailure(code: "sourceUnavailable", message: "Für diesen Archivtreffer fehlt die bytegenaue Herkunft. Bitte die Suche erneut ausführen.")
        }
        let job = Job(hit: hit, run: run)
        jobs[job.id] = job; order.append(job.id)
        while order.count > 32 { jobs.removeValue(forKey: order.removeFirst()) }
        owner?.host?.presentActionIssue(summary: "Fastra-Übergabe wird vorbereitet…", detail: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak self, weak job] in
            if let self, let job, !job.terminal { self.finish(job, error: SearchControlFailure(code: "expired", message: "Übergabe hat ihre 30-Sekunden-Frist überschritten.")) }
        }
        work.async { [self] in
            do {
                let url = URL(fileURLWithPath: hit.filesystemPath)
                let (source, _) = try HandoffSourceState.read(url, limit: nil, check: job.check)
                let (_, bytes) = try HandoffSourceState.read(url, limit: hit.isMember && source.size <= Self.maximumOuterBytes ? Self.maximumOuterBytes : nil, check: job.check)
                let hash = bytes.map(Self.hash)
                DispatchQueue.main.async {
                    guard self.current(job) else { return }
                    job.source = source; job.outerHash = hash
                    job.request = job.materializer.request(hit) { outcome in
                        guard self.current(job) else { return }
                        switch outcome {
                        case .ready(let leaf): self.prepare(job, leaf: leaf)
                        case .failed(let message): self.finish(job, error: SearchControlFailure(code: "sourceUnavailable", message: message))
                        case .cancelled: self.cancel(job.id)
                        }
                    }
                }
            } catch { DispatchQueue.main.async { self.finish(job, error: error) } }
        }
        return job
    }

    private func current(_ job: Job) -> Bool {
        guard !job.terminal else { return false }
        guard owner?.run?.id == job.run.id, owner?.host?.hits.contains(where: { $0.identity == job.hit.identity }) == true else {
            finish(job, error: SearchControlFailure(code: "stale", message: "Suchlauf oder Treffer ist nicht mehr aktuell.")); return false
        }
        return true
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func prepare(_ job: Job, leaf: URL) {
        work.async { [self] in
            do {
                let (_, raw) = try HandoffSourceState.read(leaf, limit: Self.maximumLeafBytes, check: job.check)
                let bytes = raw!
                let hash = Self.hash(bytes)
                let position = try position(job, leaf: leaf)
                guard position["sha256"] as? String == hash else { throw SearchControlFailure(code: "stale", message: "Blattinhalt wurde während der Positionsprüfung verändert.") }
                let (source, outer) = try HandoffSourceState.read(URL(fileURLWithPath: job.hit.filesystemPath), limit: job.outerHash == nil ? nil : Self.maximumOuterBytes, check: job.check)
                guard source == job.source, outer.map(Self.hash) == job.outerHash else { throw SearchControlFailure(code: "stale", message: "Quelle wurde während der Materialisierung verändert.") }
                var location = SearchControlWire.integer(position["location"]) ?? 0
                var length = SearchControlWire.integer(position["length"]) ?? 0
                var binding = position["positionBinding"] as? String ?? "unboundHit"
                let payload = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes
                let text = String(data: payload, encoding: .utf8)
                if binding == "exactUTF16" && !Self.characterRange(location: location, length: length, text: text) {
                    binding = "unboundHit"; location = 0; length = 0
                }
                var evidence = "Ursprünglicher Suchinhalt nicht gespeichert. Aktueller Blattinhalt: "
                if binding == "exactUTF16" { evidence += "Inhaltsbegriffe erneut geprüft; UTF-8/Python splitlines, Fundzeile \(position["line"] ?? "?")." }
                else { evidence += "keine belegte Fundposition; Ansicht beginnt am Anfang." }
                let terms = ([job.run.input.pattern] + job.run.input.options.terms).filter { !$0.isEmpty }.joined(separator: " · ")
                evidence += "\nSuchbegriffe: " + terms
                if evidence.utf8.count > 4096 { evidence = String(decoding: evidence.utf8.prefix(4000), as: UTF8.self) + "…" }
                var provenance: [String: Any] = ["schemaVersion": 1, "runID": job.run.id,
                    "kind": job.hit.isMember ? "archiveMaterialization" : "original",
                    "hitIdentity": LocalSearchController.identityObject(job.hit.identity), "sourceGeneration": source.object,
                    "archiveBinding": job.hit.isMember ? (job.outerHash == nil ? "generation" : "sha256") : "notApplicable",
                    "positionBinding": binding, "searchEvidence": evidence]
                if let outerHash = job.outerHash { provenance["outerSHA256"] = outerHash }
                let request: [String: Any] = ["path": leaf.path, "sha256": hash, "location": location, "length": length, "provenance": provenance]
                let textHash = text.map { Self.hash(Data($0.utf8)) }
                DispatchQueue.main.async {
                    guard self.current(job) else { return }
                    job.state = "opening"
                    self.launch { launched in
                        guard self.current(job) else { return }
                        if launched { self.transfer(job, fields: request, textHash: textHash, byteCount: bytes.count) }
                        else { self.finish(job, error: SearchControlFailure(code: "missingApplication", message: "Fastra ist nicht installiert oder konnte nicht gestartet werden.")) }
                    }
                }
            } catch { DispatchQueue.main.async { self.finish(job, error: error) } }
        }
    }

    static func characterRange(location: Int, length: Int, text: String?) -> Bool {
        guard let text, location >= 0, length >= 0, location <= text.utf16.count, length <= text.utf16.count - location else { return false }
        var boundary = 0; var start = location == 0; var end = location + length == 0
        for character in text {
            boundary += String(character).utf16.count
            if boundary == location { start = true }; if boundary == location + length { end = true }
        }
        return start && end
    }

    private func position(_ job: Job, leaf: URL) throws -> [String: Any] {
        guard let cli = findCLI() else { throw SearchControlFailure(code: "sourceUnavailable", message: "Python-Kern fehlt.") }
        let input = job.run.input; let options = input.options
        let query: [String: Any] = ["path": leaf.path, "mode": options.mode.rawValue,
            "pattern": input.pattern.trimmingCharacters(in: .whitespaces), "terms": options.terms,
            "regex": options.regex, "caseSensitive": options.caseSensitive, "exact": options.exact, "literalWildcards": options.literalWildcards]
        let data = SearchControlWire.encode(query)
        guard data.count <= SearchControlWire.maximumRequestBytes else { throw SearchControlFailure(code: "capacity", message: "Positionsauftrag ist zu groß.") }
        let process = Process(); let output = Pipe(); let errors = Pipe(); let diagnostics = SearchDiagnostics()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [cli, "--snapshot-position-json", String(data: data, encoding: .utf8)!]
        process.standardOutput = output; process.standardError = errors
        diagnostics.collect(from: errors)
        job.lock.lock()
        if job.stopped {
            job.lock.unlock(); diagnostics.finish(errors)
            throw SearchControlFailure(code: "cancelled", message: "Übergabe abgebrochen.")
        }
        do { try process.run(); job.process = process; job.lock.unlock() }
        catch { job.lock.unlock(); diagnostics.finish(errors); throw error }
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); diagnostics.finish(errors)
        job.lock.lock(); job.process = nil; job.lock.unlock()
        try job.check()
        guard process.terminationStatus == 0, reply.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw SearchControlFailure(code: "stale", message: diagnostics.errorMessage ?? "Positionsprüfung fehlgeschlagen.")
        }
        return object
    }

    private func launch(_ completion: @escaping (Bool) -> Void) {
        if let ensureApplication { ensureApplication(completion); return }
        let endpoint = "\(Self.applicationID).control.v1.\(getuid())"
        if SearchControlClient.available(endpoint) { completion(true); return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.applicationID),
              Bundle(url: url)?.bundleIdentifier == Self.applicationID else { completion(false); return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }

    private func transfer(_ job: Job, fields: [String: Any], textHash: String?, byteCount: Int) {
        work.async { [self] in
            let endpoint = "\(Self.applicationID).control.v1.\(getuid())"
            var remoteJob: [String: Any]?
            var runtime: String?
            do {
                let stopAt = min(job.deadline, ProcessInfo.processInfo.systemUptime + 3)
                if ensureApplication == nil {
                    while !SearchControlClient.available(endpoint), ProcessInfo.processInfo.systemUptime < stopAt {
                        try job.check(); Thread.sleep(forTimeInterval: 0.08)
                    }
                }
                let capabilities = try call(job, operation: "capabilities", endpoint: endpoint)
                guard let value = capabilities["capabilities"] as? [String: Any],
                      SearchControlWire.integer(value["sourceSnapshotSchemaVersion"]) == 1,
                      value["readOnly"] as? Bool == true,
                      (value["operations"] as? [String])?.contains("sourceSnapshot") == true,
                      SearchControlWire.integer(value["maximumSnapshotBytes"]) == Self.maximumLeafBytes,
                      SearchControlWire.integer(value["maximumOuterArchiveBytes"]) == Self.maximumOuterBytes,
                      let identifier = capabilities["runtimeID"] as? String, UUID(uuidString: identifier) != nil else {
                    throw SearchControlFailure(code: "unsupported", message: "Fastra braucht den geprüften Herkunftsvertrag sourceSnapshot Version 1.")
                }
                runtime = identifier
                let accepted = try call(job, operation: "sourceSnapshot", endpoint: endpoint, runtime: identifier, fields: fields)
                guard accepted["runtimeID"] as? String == identifier,
                      let first = accepted["job"] as? [String: Any], first["requestID"] as? String == job.id,
                      let remoteID = first["id"] as? String, UUID(uuidString: remoteID) != nil,
                      ["sessionID", "windowID", "documentID"].allSatisfy({ key in
                          (first[key] as? String).flatMap(UUID.init(uuidString:)) != nil
                      }) else {
                    throw SearchControlFailure(code: "delivery", message: "Fastra hat keinen Übernahmeauftrag bestätigt.")
                }
                remoteJob = first
                while true {
                    try job.check()
                    let reply = try call(job, operation: "status", endpoint: endpoint, runtime: identifier, fields: ["jobID": remoteID])
                    guard reply["runtimeID"] as? String == identifier, let value = reply["job"] as? [String: Any], value["id"] as? String == remoteID else {
                        throw SearchControlFailure(code: "stale", message: "Fastra wurde während der Übergabe neu gestartet.")
                    }
                    guard value["requestID"] as? String == job.id,
                          ["sessionID", "windowID", "documentID"].allSatisfy({ value[$0] as? String == first[$0] as? String }) else {
                        throw SearchControlFailure(code: "delivery", message: "Fastra hat abweichende Übernahmekennungen geliefert.")
                    }
                    if value["state"] as? String == "ready" {
                        guard value["adopted"] as? Bool == true, value["sha256"] as? String == fields["sha256"] as? String,
                              SearchControlWire.integer(value["byteCount"]) == byteCount,
                              (textHash == nil || value["textSHA256"] as? String == textHash),
                              (value["provenance"] as? NSDictionary) == (fields["provenance"] as? NSDictionary),
                              let selection = value["selection"] as? [String: Any],
                              SearchControlWire.integer(selection["location"]) == SearchControlWire.integer(fields["location"]),
                              SearchControlWire.integer(selection["length"]) == SearchControlWire.integer(fields["length"]) else {
                            throw SearchControlFailure(code: "delivery", message: "Fastra hat Inhalt, Herkunft oder Position nicht vollständig bestätigt.")
                        }
                        DispatchQueue.main.async {
                            guard self.current(job) else {
                                self.work.async { self.closeRemote(endpoint, runtime: identifier, value: first) }; return
                            }
                            job.receipt = value; job.state = "ready"; job.materializer.cleanup()
                            self.owner?.host?.presentActionIssue(summary: "In Fastra übernommen: eigene schreibgeschützte Inhaltskopie.", detail: nil)
                        }
                        return
                    }
                    if ["failed", "cancelled"].contains(value["state"] as? String ?? "") {
                        let error = value["error"] as? [String: Any]
                        throw SearchControlFailure(code: error?["code"] as? String ?? "delivery", message: error?["message"] as? String ?? "Fastra hat die Übergabe abgebrochen.")
                    }
                    Thread.sleep(forTimeInterval: 0.08)
                }
            } catch {
                if let runtime {
                    if let remoteJob { closeRemote(endpoint, runtime: runtime, value: remoteJob) }
                    else { closeUnconfirmedRequest(endpoint, runtime: runtime, requestID: job.id) }
                }
                DispatchQueue.main.async { self.finish(job, error: error) }
            }
        }
    }

    private func call(_ job: Job, operation: String, endpoint: String, runtime: String? = nil, fields: [String: Any] = [:]) throws -> [String: Any] {
        try job.check()
        var request: [String: Any] = ["version": 1, "id": operation == "sourceSnapshot" ? job.id : UUID().uuidString,
                                    "deadline": Date().timeIntervalSince1970 + 9, "operation": operation]
        if let runtime { request["runtimeID"] = runtime }
        request.merge(fields) { _, new in new }
        let bytes = SearchControlWire.encode(request)
        guard bytes.count <= 65_536 else { throw SearchControlFailure(code: "capacity", message: "Herkunftsauftrag ist zu groß.") }
        var response = send(bytes, endpoint, 1)
        if response == nil { try job.check(); response = send(bytes, endpoint, 1) }
        guard let response, let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              SearchControlWire.integer(object["protocolVersion"]) == 1 else {
            throw SearchControlFailure(code: "delivery", message: "Fastra ist noch nicht bereit oder hat die Übernahme nicht bestätigt.")
        }
        if let error = object["error"] as? [String: Any] {
            throw SearchControlFailure(code: error["code"] as? String ?? "delivery", message: error["message"] as? String ?? "Fastra hat den Auftrag abgelehnt.")
        }
        return object
    }
    private func closeRemote(_ endpoint: String, runtime: String, value: [String: Any]) {
        for operation in ["cancel", "close"] {
            let key = operation == "cancel" ? "jobID" : "sessionID"
            guard let id = value[key == "jobID" ? "id" : key] as? String, UUID(uuidString: id) != nil else { continue }
            let request: [String: Any] = ["version": 1, "id": UUID().uuidString, "deadline": Date().timeIntervalSince1970 + 9,
                "operation": operation, "runtimeID": runtime, key: id]
            _ = send(SearchControlWire.encode(request), endpoint, 1)
        }
    }
    private func closeUnconfirmedRequest(_ endpoint: String, runtime: String, requestID: String) {
        let request: [String: Any] = ["version": 1, "id": UUID().uuidString, "deadline": Date().timeIntervalSince1970 + 9,
                                     "operation": "objects", "runtimeID": runtime]
        guard let data = send(SearchControlWire.encode(request), endpoint, 1),
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["runtimeID"] as? String == runtime, let jobs = reply["jobs"] as? [[String: Any]],
              let own = jobs.first(where: { $0["requestID"] as? String == requestID }) else { return }
        closeRemote(endpoint, runtime: runtime, value: own)
    }
    private func finish(_ job: Job, error: Error) {
        guard !job.terminal else { return }
        let failure = error as? SearchControlFailure ?? SearchControlFailure(code: "sourceUnavailable", message: error.localizedDescription)
        job.state = failure.code == "cancelled" ? "cancelled" : "failed"; job.error = failure; job.stop()
        owner?.host?.presentActionIssue(summary: "Fastra-Übergabe: \(failure.message)", detail: nil)
    }
    func cancel(_ id: String) {
        if let job = jobs[id], !job.terminal { finish(job, error: SearchControlFailure(code: "cancelled", message: "Übergabe abgebrochen.")) }
    }
    func cancelPending() { jobs.values.filter { !$0.terminal }.forEach { cancel($0.id) } }
    func shutdown(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        isShuttingDown = true; cancelPending()
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true; completion()
        }
        // Der laufende Transport räumt nur seine eigene Empfängersitzung auf.
        // Die UI wartet asynchron und bei unerreichbarem Empfänger höchstens 5 s.
        work.async { DispatchQueue.main.async(execute: reply) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: reply)
    }
}
