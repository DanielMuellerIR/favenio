import AppKit

struct ControlSearchInput {
    let pattern: String
    let root: String
    let options: SearchConfiguration
    var object: [String: Any] {
        ["pattern": pattern, "root": root,
         "options": options.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }]
    }
    static func decode(_ value: Any?) throws -> ControlSearchInput {
        guard let object = value as? [String: Any], Set(object.keys) == ["pattern", "root", "options"],
              let pattern = object["pattern"] as? String, !pattern.utf8.contains(0), let root = object["root"] as? String,
              root.hasPrefix("/"), !root.utf8.contains(0),
              let pairs = object["options"] as? [[String: String]] else {
            throw SearchControlFailure(code: "invalidRequest", message: "Konfiguration braucht Muster, absoluten Suchordner und Optionen.")
        }
        let known = Set(["mode", "content", "only", "regex", "case", "archives", "hidden", "exact", "literal-wildcards", "field", "exclude", "term"] + SearchConfiguration.pixelKeys + FactFilterOption.all.map { $0.key })
        let booleans = Set(["content", "regex", "case", "archives", "hidden", "exact", "literal-wildcards"])
        var seen = Set<String>()
        var items: [URLQueryItem] = []
        for pair in pairs {
            guard Set(pair.keys) == ["name", "value"], let name = pair["name"], let text = pair["value"], !text.utf8.contains(0), known.contains(name),
                  name == "exclude" || name == "term" || seen.insert(name).inserted,
                  !booleans.contains(name) || ["0", "1"].contains(text),
                  name != "mode" || SearchTextMode(rawValue: text) != nil,
                  name != "only" || ["both", "files", "dirs"].contains(text),
                  name != "field" || metadataFieldList().contains(text),
                  !["term", "exclude"].contains(name) || (!text.isEmpty && !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) })) else {
                throw SearchControlFailure(code: "invalidRequest", message: "Unbekannte, doppelte oder ungültige Suchoption.")
            }
            items.append(URLQueryItem(name: name, value: text))
        }
        let options = SearchConfiguration.fromQueryItems(items)
        guard options.metadataField == nil || options.mode == .metadata else {
            throw SearchControlFailure(code: "invalidRequest", message: "Ein Metadatenfeld braucht den Metadatenmodus.")
        }
        return ControlSearchInput(pattern: pattern, root: root, options: options)
    }
}

struct ControlledSearchRun {
    let id = UUID().uuidString
    let startedAt = Date().timeIntervalSince1970
    let input: ControlSearchInput
    var state = "running"
    var warningCount = 0
    var error: String?
    var origin = "live"
}

final class LocalSearchController {
    weak var host: MainController?
    let runtimeID = UUID().uuidString
    let windowID = UUID().uuidString
    var run: ControlledSearchRun?
    var recordedSource: [String: Any]?
    private(set) var generation = 0
    private struct Replay { let request: Data; let reply: Data; let at: TimeInterval }
    private var replays: [String: Replay] = [:]
    private var replayOrder: [String] = []
    private var server: SearchControlServer?
    lazy var handoff = FastraHandoffController(owner: self)
    init(host: MainController) { self.host = host }

    func listen() {
        guard server == nil, let identifier = Bundle.main.bundleIdentifier else { return }
        let candidate = SearchControlServer(name: SearchControlWire.endpoint(identifier)) { [weak self] data in
            DispatchQueue.main.sync {
                self?.handle(data) ?? SearchControlWire.encode(["error": ["code": "delivery", "message": "Fenster geschlossen."]])
            }
        }
        if candidate.isListening { server = candidate }
        else { host?.presentActionIssue(summary: "Lokale Suchsteuerung ist bereits belegt.", detail: nil) }
    }
    func begin(_ input: ControlSearchInput) { recordedSource = nil; handoff.cancelPending(); run = ControlledSearchRun(input: input); changed() }
    func changed() { generation += 1 }
    func cancelled() { if run?.state == "running" { run?.state = "cancelled" } }
    func finished(_ exit: SearchExit) {
        guard run?.state == "running" else { return }
        run?.warningCount = exit.warningCount
        if searchExitIsError(exit.status, reason: exit.reason) {
            run?.state = "failed"; run?.error = searchFailureText(exit)
        } else { run?.state = exit.warningCount > 0 ? "warnings" : "completed" }
    }
    func failed(_ message: String) { run?.state = "failed"; run?.error = message }
    func imported(_ input: ControlSearchInput) {
        begin(input); run?.state = "recorded"; run?.origin = "quick"
    }
    var status: [String: Any] {
        guard let host else { return ["state": "closed"] }
        var selection: [[String: Any]] = []
        var selectionBytes = 0
        for index in host.tableView.selectedRowIndexes.prefix(SearchControlWire.maximumPage)
            where host.hits.indices.contains(index) {
            let identity = Self.identityObject(host.hits[index].identity)
            let bytes = SearchControlWire.encode(identity).count
            guard selectionBytes + bytes <= SearchControlWire.maximumReplyBytes / 4 else { break }
            selection.append(identity)
            selectionBytes += bytes
        }
        var object: [String: Any] = ["state": run?.state ?? "idle", "generation": generation,
            "count": host.hits.count, "pendingCount": host.pending.count,
            "warningCount": run?.warningCount ?? 0, "complete": run?.state == "completed",
            "selectionCount": host.tableView.selectedRowIndexes.count,
            "selectionTruncated": host.tableView.selectedRowIndexes.count > selection.count,
            "selection": selection]
        if let run {
            object["runID"] = run.id; object["startedAt"] = run.startedAt
            object["configuration"] = run.input.object; object["origin"] = run.origin
            if let error = run.error { object["error"] = error }
        }
        if let recordedSource { object["recordedSource"] = recordedSource }
        if let path = host.progressPath { object["progressPath"] = path }
        return object
    }
    static func identityObject(_ identity: HitIdentity) -> [String: Any] {
        ["filesystemPath": identity.filesystemPath, "archiveMembers": identity.archiveMembers,
         "archiveMemberBytes": identity.archiveMemberBytes]
    }
    static func identity(_ value: Any?) throws -> HitIdentity {
        guard let object = value as? [String: Any], Set(object.keys) == ["filesystemPath", "archiveMembers", "archiveMemberBytes"],
              let path = object["filesystemPath"] as? String,
              let members = object["archiveMembers"] as? [String], let bytes = object["archiveMemberBytes"] as? [String],
              bytes.isEmpty || bytes.count == members.count,
              bytes.allSatisfy({ Data(base64Encoded: $0) != nil }) else {
            throw SearchControlFailure(code: "invalidRequest", message: "Ungültige Trefferidentität.")
        }
        return HitIdentity(filesystemPath: path, archiveMembers: members, archiveMemberBytes: bytes)
    }
    func requireRun(_ request: [String: Any]) throws {
        guard let id = request["runID"] as? String, id == run?.id else {
            throw SearchControlFailure(code: "stale", message: "Suchlauf ist nicht mehr aktuell.")
        }
    }
    func handle(_ data: Data) -> Data {
        precondition(Thread.isMainThread)
        do {
            let request = try SearchControlWire.decode(data)
            let canonical = SearchControlWire.encode(request)
            let id = request["id"] as! String
            let operation = request["operation"] as! String
            let now = Date().timeIntervalSince1970
            if let replay = replays[id], now - replay.at <= 300 {
                guard replay.request == canonical else { throw SearchControlFailure(code: "invalidRequest", message: "Auftrags-ID wurde für einen anderen Inhalt benutzt.") }
                return replay.reply
            }
            guard let deadline = request["deadline"] as? Double, deadline > now, deadline <= now + 10 else {
                throw SearchControlFailure(code: "expired", message: "Auftrag ist abgelaufen oder seine Frist liegt mehr als zehn Sekunden voraus.")
            }
            if let runtime = request["runtimeID"] as? String, runtime != runtimeID {
                throw SearchControlFailure(code: "stale", message: "Favenio wurde inzwischen neu gestartet.")
            }
            if let window = request["windowID"] as? String, window != windowID {
                throw SearchControlFailure(code: "stale", message: "Zielfenster ist nicht mehr vorhanden.")
            }
            let mutations = Set(["configure", "start", "replace", "cancel", "select", "handoff", "cancelHandoff", "openRecording"])
            if mutations.contains(operation) {
                guard !handoff.isShuttingDown else { throw SearchControlFailure(code: "busy", message: "Favenio wird beendet.") }
                guard request["runtimeID"] as? String == runtimeID, request["windowID"] as? String == windowID else {
                    throw SearchControlFailure(code: "invalidRequest", message: "Ändernde Aufträge brauchen die aktuelle Laufzeit- und Fensterkennung.")
                }
                guard host?.window?.attachedSheet == nil, NSApp.modalWindow == nil else {
                    throw SearchControlFailure(code: "busy", message: "Ein Dialog ist geöffnet.")
                }
            }
            guard let host else { throw SearchControlFailure(code: "stale", message: "Fenster geschlossen.") }
            var reply: [String: Any] = ["protocolVersion": 1, "runtimeID": runtimeID, "windowID": windowID, "requestID": id]
            switch operation {
            case "capabilities": reply["capabilities"] = SearchControlWire.capabilities; reply["productVersion"] = favenioVersion
            case "configuration": reply["configuration"] = host.controlInput.object
            case "configure":
                guard host.window?.attachedSheet == nil else { throw SearchControlFailure(code: "busy", message: "Ein Dialog ist geöffnet.") }
                let input = try ControlSearchInput.decode(request["configuration"])
                host.setSearchRoot(URL(fileURLWithPath: input.root))
                host.searchField.stringValue = input.pattern
                host.applyConfiguration(input.options)
                host.recolorRegexField()
                reply["configuration"] = host.controlInput.object
            case "start", "replace":
                guard host.window?.attachedSheet == nil else { throw SearchControlFailure(code: "busy", message: "Ein Dialog ist geöffnet.") }
                guard operation == "replace" || host.activeSearchRun == nil else { throw SearchControlFailure(code: "busy", message: "Suche läuft; zum Ersetzen die Operation replace verwenden.") }
                let pattern = host.searchField.stringValue.trimmingCharacters(in: .whitespaces)
                guard !pattern.isEmpty || host.searchConfiguration.hasPositiveFilter else { throw SearchControlFailure(code: "invalidRequest", message: "Suchmuster oder positiver Filter fehlt.") }
                host.startSearch()
                reply["status"] = status
            case "cancel": try requireRun(request); host.stopSearchClicked(); reply["status"] = status
            case "status": host.flushPending(); reply["status"] = status
            case "results":
                try requireRun(request); host.flushPending()
                guard let offset = SearchControlWire.integer(request["offset"]), let limit = SearchControlWire.integer(request["limit"]),
                      limit > 0, limit <= SearchControlWire.maximumPage, offset <= host.hits.count else {
                    throw SearchControlFailure(code: "invalidRequest", message: "Ungültige Ergebnisseite.")
                }
                if let requested = request["generation"] {
                    guard SearchControlWire.integer(requested) == generation else { throw SearchControlFailure(code: "stale", message: "Ergebnisliste hat sich verändert; bei Offset null neu beginnen.") }
                } else if offset != 0 { throw SearchControlFailure(code: "invalidRequest", message: "Folgeseiten brauchen eine Ergebnisgeneration.") }
                var page: [[String: Any]] = []
                var byteCount = 4096
                for hit in host.hits.dropFirst(offset).prefix(limit) {
                    let bytes = jsonlData(for: [hit])
                    guard byteCount + bytes.count <= SearchControlWire.maximumReplyBytes / 2 else {
                        if page.isEmpty { throw SearchControlFailure(code: "capacity", message: "Ein einzelner Treffer ist zu groß für die Steuerungsantwort.") }
                        break
                    }
                    byteCount += bytes.count
                    page.append(try JSONSerialization.jsonObject(with: bytes) as! [String: Any])
                }
                reply["hits"] = page; reply["runID"] = run!.id; reply["generation"] = generation
                reply["count"] = host.hits.count; reply["nextOffset"] = offset + page.count
                reply["hasMore"] = offset + page.count < host.hits.count
                reply["state"] = run!.state
            case "select":
                try requireRun(request); host.flushPending()
                let identity = try Self.identity(request["identity"])
                guard let row = host.hits.firstIndex(where: { $0.identity == identity }) else { throw SearchControlFailure(code: "missingHit", message: "Treffer gehört nicht mehr zur aktuellen Liste.") }
                host.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                host.tableView.scrollRowToVisible(row)
                reply["identity"] = Self.identityObject(identity); reply["runID"] = run!.id
            case "captureRecording":
                try requireRun(request); reply["recording"] = try captureRecording()
            case "openRecording":
                let recording = try SearchRecording.decode(request["recording"])
                try openRecording(recording); reply["status"] = status
            case "handoff":
                try requireRun(request); host.flushPending()
                let identity = try Self.identity(request["identity"])
                guard let hit = host.hits.first(where: { $0.identity == identity }) else {
                    throw SearchControlFailure(code: "missingHit", message: "Treffer gehört nicht mehr zur aktuellen Liste.")
                }
                reply["handoff"] = try handoff.start(hit: hit, run: run!).object
            case "handoffStatus", "cancelHandoff":
                guard let id = request["jobID"] as? String, let job = handoff.jobs[id] else {
                    throw SearchControlFailure(code: "stale", message: "Übergabeauftrag ist nicht mehr vorhanden.")
                }
                if operation == "cancelHandoff" { handoff.cancel(id) }
                reply["handoff"] = job.object
            default: break
            }
            let bytes = SearchControlWire.encode(reply)
            guard bytes.count <= SearchControlWire.maximumReplyBytes else { throw SearchControlFailure(code: "capacity", message: "Steuerungsantwort überschreitet die Größe.") }
            if mutations.contains(operation) {
                replays[id] = Replay(request: canonical, reply: bytes, at: now)
                replayOrder.append(id)
                while replayOrder.count > 128 { replays.removeValue(forKey: replayOrder.removeFirst()) }
            }
            return bytes
        } catch {
            let failure = error as? SearchControlFailure ?? SearchControlFailure(code: "invalidRequest", message: "Auftrag konnte nicht verarbeitet werden.")
            return SearchControlWire.encode(["protocolVersion": 1, "runtimeID": runtimeID, "windowID": windowID, "error": failure.object])
        }
    }
}

extension MainController {
    var controlInput: ControlSearchInput {
        ControlSearchInput(pattern: searchField.stringValue, root: searchRoot.path, options: searchConfiguration)
    }
    @objc func showSelectedInFastra(_ sender: Any?) {
        let rows = rows(for: sender)
        guard rows.count == 1, let row = rows.first, hits.indices.contains(row), let run = searchControl.run else {
            presentActionIssue(summary: "Für die Fastra-Übergabe genau einen aktuellen Treffer auswählen.", detail: nil); return
        }
        do { _ = try searchControl.handoff.start(hit: hits[row], run: run) }
        catch { presentActionIssue(summary: (error as? SearchControlFailure)?.message ?? error.localizedDescription, detail: nil) }
    }
    @objc func cancelFastraHandoff(_ sender: Any?) { searchControl.handoff.cancelPending() }
    func addFastraMenuItems(to menu: NSMenu) {
        let show = menu.addItem(withTitle: "In Fastra zeigen", action: #selector(showSelectedInFastra(_:)), keyEquivalent: "")
        show.target = self
        let cancel = menu.addItem(withTitle: "Fastra-Übergabe abbrechen", action: #selector(cancelFastraHandoff(_:)), keyEquivalent: "")
        cancel.target = self
    }
}
