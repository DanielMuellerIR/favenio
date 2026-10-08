import AppKit

struct SearchRecording {
    static let maximumBytes = 48_000
    static let maximumHits = 128
    let input: ControlSearchInput
    let runID: String
    let startedAt: Double
    let capturedAt: Double
    let state: String
    let warningCount: Int
    let error: String?
    let hits: [Hit]
    let selection: [HitIdentity]

    var object: [String: Any] {
        var value: [String: Any] = ["schemaVersion": 1, "configuration": input.object,
            "runID": runID, "startedAt": startedAt, "capturedAt": capturedAt,
            "state": state, "warningCount": warningCount,
            "hits": hits.compactMap { try? JSONSerialization.jsonObject(with: jsonlData(for: [$0])) },
            "selection": selection.map(LocalSearchController.identityObject)]
        if let error { value["error"] = error }
        return value
    }

    static func decode(_ value: Any?) throws -> SearchRecording {
        func invalid() -> SearchControlFailure {
            SearchControlFailure(code: "invalidRequest", message: "Ungültiger oder zu großer aufgezeichneter Suchstand.")
        }
        guard let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "configuration", "runID", "startedAt", "capturedAt", "state", "warningCount", "error", "hits", "selection"]),
              SearchControlWire.encode(object).count <= maximumBytes,
              SearchControlWire.integer(object["schemaVersion"]) == 1,
              let runID = object["runID"] as? String, UUID(uuidString: runID) != nil,
              let startedAt = object["startedAt"] as? NSNumber,
              CFGetTypeID(startedAt) != CFBooleanGetTypeID(), startedAt.doubleValue.isFinite,
              let capturedAt = object["capturedAt"] as? NSNumber,
              CFGetTypeID(capturedAt) != CFBooleanGetTypeID(), capturedAt.doubleValue.isFinite,
              startedAt.doubleValue >= 0, capturedAt.doubleValue >= startedAt.doubleValue,
              let state = object["state"] as? String,
              ["completed", "warnings", "cancelled", "failed"].contains(state),
              let warningCount = SearchControlWire.integer(object["warningCount"]),
              let rows = object["hits"] as? [[String: Any]], rows.count <= maximumHits,
              let selected = object["selection"] as? [[String: Any]], selected.count <= maximumHits,
              object["error"] == nil || object["error"] is String else { throw invalid() }
        let error = object["error"] as? String
        guard (state == "failed") == (error != nil),
              state != "completed" || warningCount == 0,
              state != "warnings" || warningCount > 0 else { throw invalid() }
        let input = try ControlSearchInput.decode(object["configuration"])
        let hits = try rows.map { row -> Hit in
            guard let hit = parseHit(SearchControlWire.encode(row)),
                  hit.filesystemPath.hasPrefix("/"), !hit.filesystemPath.utf8.contains(0) else { throw invalid() }
            _ = try LocalSearchController.identity(LocalSearchController.identityObject(hit.identity))
            return hit
        }
        let identities = Set(hits.map { $0.identity })
        guard identities.count == hits.count else { throw invalid() }
        let selection = try selected.map(LocalSearchController.identity)
        guard Set(selection).count == selection.count, selection.allSatisfy(identities.contains) else { throw invalid() }
        return SearchRecording(input: input, runID: runID, startedAt: startedAt.doubleValue,
            capturedAt: capturedAt.doubleValue, state: state, warningCount: warningCount,
            error: error, hits: hits, selection: selection)
    }
}

extension LocalSearchController {
    func captureRecording() throws -> [String: Any] {
        guard let host, let run, ["completed", "warnings", "cancelled", "failed"].contains(run.state),
              host.activeSearchRun == nil, run.origin != "recording" else {
            throw SearchControlFailure(code: "busy", message: "Nur einen beendeten Suchlauf aufzeichnen; laufende Suche zuerst abbrechen.")
        }
        host.flushPending()
        guard host.hits.count <= SearchRecording.maximumHits else {
            throw SearchControlFailure(code: "capacity", message: "Aufzeichnung ist auf 128 Treffer begrenzt; kein stilles Abschneiden.")
        }
        let recording = SearchRecording(input: run.input, runID: run.id, startedAt: run.startedAt,
            capturedAt: Date().timeIntervalSince1970, state: run.state, warningCount: run.warningCount,
            error: run.error, hits: host.hits, selection: Array(host.selectedHitIdentities()))
        guard SearchControlWire.encode(recording.object).count <= SearchRecording.maximumBytes else {
            throw SearchControlFailure(code: "capacity", message: "Aufzeichnung überschreitet 48.000 Byte; kein stilles Abschneiden.")
        }
        return recording.object
    }
    func openRecording(_ recording: SearchRecording) throws {
        guard let host, host.activeSearchRun == nil, !handoff.busy else {
            throw SearchControlFailure(code: "busy", message: "Suche oder Übergabe läuft; zuerst ausdrücklich abbrechen.")
        }
        host.setSearchRoot(URL(fileURLWithPath: recording.input.root))
        host.searchField.stringValue = recording.input.pattern
        host.applyConfiguration(recording.input.options)
        host.recolorRegexField()
        host.replaceSearchResults(recording.hits)
        // Historische Kennung nur als Herkunft: jede Wiederöffnung erhält eine
        // neue aktuelle Kennung, damit alte Aufträge keine neue Ansicht treffen.
        begin(recording.input)
        run?.state = recording.state
        run?.origin = "recording"
        run?.warningCount = recording.warningCount
        run?.error = recording.error
        recordedSource = ["runID": recording.runID, "startedAt": recording.startedAt,
                          "capturedAt": recording.capturedAt]
        host.applyHitsToTable(keepingSelection: Set(recording.selection))
        host.skippedCount = recording.warningCount
        host.searchPhase = .recorded(recording.state)
        host.exportStatus = nil
        host.refreshStatus()
    }
}
