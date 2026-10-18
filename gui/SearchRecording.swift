import AppKit

struct SearchRecording {
    static let maximumBytes = 196_608
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
    var dateResolution: Data? = nil

    var object: [String: Any] {
        let finder = input.options.requiresFinderMetadata || hits.contains { $0.finderMetadata != nil }
        var value: [String: Any] = ["schemaVersion": input.options.pdfOCR ? 8 : input.options.ocr ? 7 : input.options.localOnly ? 6 : finder ? 5 : input.options.requiresDateRanges ? 4 : (input.roots.count > 1 ? 3 : (input.options.requiresTransportVersion2 ? 2 : 1)), "configuration": input.object,
            "runID": runID, "startedAt": startedAt, "capturedAt": capturedAt,
            "state": state, "warningCount": warningCount,
            "hits": hits.compactMap { preservedJSONObject(jsonlData(for: [$0])) },
            "selection": selection.map(LocalSearchController.identityObject)]
        if let error { value["error"] = error }
        if finder { value["finderMetadataCapability"] = 1 }
        if input.options.localOnly { value["localContentCapability"] = 1 }
        if input.options.ocr { value["ocrCapability"] = 1 }
        if input.options.pdfOCR { value["pdfOCRCapability"] = 1 }
        if input.options.requiresDateRanges { value["dateResolution"] = dateResolution.flatMap { preservedJSONObject($0) } ?? NSNull() }
        return value
    }

    static func decode(_ value: Any?, rawData: Data? = nil) throws -> SearchRecording {
        func invalid() -> SearchControlFailure {
            SearchControlFailure(code: "invalidRequest", message: "Ungültiger oder zu großer aufgezeichneter Suchstand.")
        }
        guard let object = (rawData.flatMap { preservedJSONObject($0) } ?? value) as? [String: Any],
              rawData.map({ $0.count <= maximumBytes && !DateRangeTransport.hasDuplicateKeys($0) }) ?? true,
              Set(object.keys).isSubset(of: ["schemaVersion", "configuration", "runID", "startedAt", "capturedAt", "state", "warningCount", "error", "hits", "selection", "dateResolution", "finderMetadataCapability", "localContentCapability", "ocrCapability", "pdfOCRCapability"]),
              SearchControlWire.encode(object).count <= maximumBytes,
              let version = SearchControlWire.integer(object["schemaVersion"]), [1, 2, 3, 4, 5, 6, 7, 8].contains(version),
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
        guard version >= 2 || input.options.textEncoding == .utf8,
              version >= 3 || (object["configuration"] as? [String: Any])?["schemaVersion"] == nil,
              !input.options.requiresDateRanges || version >= 4,
              !input.options.requiresFinderMetadata || version >= 5,
              !input.options.localOnly || version >= 6,
              !input.options.ocr || version >= 7,
              !input.options.pdfOCR || version == 8,
              version == 8 ? input.options.pdfOCR && SearchControlWire.integer(object["pdfOCRCapability"]) == 1 : object["pdfOCRCapability"] == nil,
              (version == 7 || input.options.ocr) ? version >= 7 && input.options.ocr && SearchControlWire.integer(object["ocrCapability"]) == 1 : object["ocrCapability"] == nil,
              (version == 6 || input.options.localOnly) ? version >= 6 && input.options.localOnly && SearchControlWire.integer(object["localContentCapability"]) == 1 : object["localContentCapability"] == nil,
              input.options.requiresDateRanges || object["dateResolution"] == nil,
              (version == 5 || input.options.requiresFinderMetadata || rows.contains { $0["finderMetadata"] != nil }) ? version >= 5 && SearchControlWire.integer(object["finderMetadataCapability"]) == 1 : object["finderMetadataCapability"] == nil else { throw invalid() }
        let scope = SearchRoots(input.roots)
        let rawRows: [Data]
        if let rawData, let array = JSONByteSlices.member("hits", in: rawData), let slices = JSONByteSlices.items(array) {
            rawRows = slices
        } else {
            guard rows.allSatisfy({ $0["finderMetadata"] == nil }) else { throw invalid() }
            rawRows = rows.map(SearchControlWire.encode)
        }
        guard rawRows.count == rows.count else { throw invalid() }
        let hits = try rawRows.map { raw -> Hit in
            guard let hit = parseHit(raw), version >= 5 || hit.finderMetadata == nil,
                  hit.contentEncoding != "vision-ocr-text-v1" || (version >= 7 && input.options.ocr),
                  hit.contentEncoding != "pdfkit-vision-text-v1" || (version == 8 && input.options.pdfOCR),
                  hit.filesystemPath.hasPrefix("/"), !hit.filesystemPath.utf8.contains(0) else { throw invalid() }
            _ = try LocalSearchController.identity(LocalSearchController.identityObject(hit.identity))
            guard let bound = scope.carrying(hit) else { throw invalid() }
            return bound
        }
        let identities = Set(hits.map { $0.identity })
        guard identities.count == hits.count else { throw invalid() }
        let selection = try selected.map(LocalSearchController.identity)
        guard Set(selection).count == selection.count, selection.allSatisfy(identities.contains) else { throw invalid() }
        var dateResolution: Data?
        if input.options.requiresDateRanges {
            guard version >= 4, input.options.dateReferenceTime != nil,
                  object["dateResolution"] != nil else { throw invalid() }
            if !(object["dateResolution"] is NSNull) {
                guard let raw = object["dateResolution"], let data = DateRangeTransport.resolution(raw), DateRangeTransport.bound(data, to: input.options) else { throw invalid() }
                dateResolution = data
            } else if !hits.isEmpty || !["failed", "cancelled"].contains(state) { throw invalid() }
        } else if version == 4 { throw invalid() }
        return SearchRecording(input: input, runID: runID, startedAt: startedAt.doubleValue,
            capturedAt: capturedAt.doubleValue, state: state, warningCount: warningCount,
            error: error, hits: hits, selection: selection, dateResolution: dateResolution)
    }
}

extension LocalSearchController {
    func captureRecording() throws -> [String: Any] {
        guard let host, let run, ["completed", "warnings", "cancelled", "failed"].contains(run.state),
              host.activeSearchRun == nil, run.origin != "recording" else {
            throw SearchControlFailure(code: "busy", message: "Nur einen beendeten Suchlauf aufzeichnen; laufende Suche zuerst abbrechen.")
        }
        host.flushPending()
        let sourceHits = host.resultFilter.unfilteredHits
        guard sourceHits.count <= SearchRecording.maximumHits else {
            throw SearchControlFailure(code: "capacity", message: "Aufzeichnung ist auf 128 Treffer begrenzt; kein stilles Abschneiden.")
        }
        let dateResolution = host.searchReportController.snapshot?.object["dateResolution"].flatMap { DateRangeTransport.resolution($0) }
        if run.input.options.requiresDateRanges && dateResolution == nil && (!sourceHits.isEmpty || !["failed", "cancelled"].contains(run.state)) {
            throw SearchControlFailure(code: "capacity", message: "Die tatsächlichen Kalendergrenzen des Laufs fehlen; keine unvollständige Aufnahme.")
        }
        let recording = SearchRecording(input: run.input, runID: run.id, startedAt: run.startedAt,
            capturedAt: Date().timeIntervalSince1970, state: run.state, warningCount: run.warningCount,
            error: run.error, hits: sourceHits, selection: Array(host.selectedHitIdentities()), dateResolution: dateResolution)
        guard SearchControlWire.encode(recording.object).count <= SearchRecording.maximumBytes else {
            throw SearchControlFailure(code: "capacity", message: "Aufzeichnung überschreitet 196.608 Byte; kein stilles Abschneiden.")
        }
        return recording.object
    }
    func openRecording(_ recording: SearchRecording) throws {
        guard let host, host.activeSearchRun == nil, !handoff.busy else {
            throw SearchControlFailure(code: "busy", message: "Suche oder Übergabe läuft; zuerst ausdrücklich abbrechen.")
        }
        host.setSearchRoots(recording.input.roots)
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
        var report = SearchReportSnapshot.pending(configuration: recording.input.object, state: "recorded")
        if let dateResolution = recording.dateResolution { report.object["dateResolution"] = preservedJSONObject(dateResolution) }
        host.searchReportController.accept(report)
        host.exportStatus = nil
        host.refreshStatus()
    }
}
