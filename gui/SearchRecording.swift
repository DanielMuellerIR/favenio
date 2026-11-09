import AppKit

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
