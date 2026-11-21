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
        openedRecording = recording
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

final class RecordingComparison {
    let earlier: SearchRecording
    private let formerIdentities: Set<HitIdentity>
    private var observed = Set<HitIdentity>()
    private(set) var newHits: [Hit] = []
    var earlierOnly: [Hit] { earlier.hits.filter { !observed.contains($0.identity) } }

    init(_ earlier: SearchRecording) {
        self.earlier = earlier
        formerIdentities = Set(earlier.hits.map(\.identity))
    }

    func accept(_ hit: Hit) {
        if observed.insert(hit.identity).inserted && !formerIdentities.contains(hit.identity) {
            newHits.append(hit)
        }
    }

    func incompatibility(_ current: ControlSearchInput, report: SearchReportSnapshot?) -> String? {
        let roots = SearchRoots(current.roots, rawBytes: current.rootBytes).bytes
        guard roots == SearchRoots(earlier.input.roots, rawBytes: earlier.input.rootBytes).bytes else {
            return "Die Suchbereiche unterscheiden sich."
        }
        if let config = report?.object["configuration"] as? [String: Any],
           let paths = config["paths"] as? [String], paths.map({ Data($0.utf8) }) != roots {
            return "Der Kern hat andere Suchbereiche verwendet."
        }
        func criteria(_ input: ControlSearchInput) -> [Data] {
            [Data(input.pattern.utf8)] + input.options.queryItems.filter { $0.name != "date-reference-time" }
                .flatMap { [Data($0.name.utf8), Data(($0.value ?? "").utf8)] }
        }
        guard criteria(earlier.input) == criteria(current) else {
            return "Die Suchkriterien unterscheiden sich."
        }
        guard current.options.requiresDateRanges else { return nil }
        func bounds(_ data: Data?, for input: ControlSearchInput) -> [String: [Double]]? {
            guard let data, DateRangeTransport.bound(data, to: input.options),
                  let object = preservedJSONObject(data) as? [String: Any],
                  let entries = object["entries"] as? [[String: Any]] else { return nil }
            return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                guard let id = entry["id"] as? String,
                      let lower = entry["lowerEpoch"] as? Double,
                      let upper = entry["upperEpoch"] as? Double else { return nil }
                return (id, [lower, upper])
            })
        }
        let recentProof = report?.object["dateResolution"].flatMap(DateRangeTransport.resolution)
        guard let old = bounds(earlier.dateResolution, for: earlier.input),
              let new = bounds(recentProof, for: current) else {
            return "Tatsächlich verwendete Kalendergrenzen fehlen für mindestens einen Lauf."
        }
        return old == new ? nil : "Die tatsächlich verwendeten Kalendergrenzen unterscheiden sich."
    }

    func coverageNotes(_ run: ControlledSearchRun, report: SearchReportSnapshot?) -> [String] {
        let earlierNote: String
        switch earlier.state {
        case "warnings": earlierNote = "Die frühere Suche hatte Warnungen. Ihre Abdeckung ist eingeschränkt."
        case "cancelled": earlierNote = "Die frühere Suche wurde abgebrochen."
        case "failed": earlierNote = "Die frühere Suche ist fehlgeschlagen."
        default: earlierNote = "Die frühere Aufzeichnung enthält keinen Suchbericht. Ihre Abdeckung ist unbekannt."
        }
        let currentNote: String
        switch run.state {
        case "cancelled": currentNote = "Die neue Suche wurde abgebrochen. Die Liste enthält nur bisher empfangene Treffer."
        case "failed": currentNote = run.error ?? "Die neue Suche ist fehlgeschlagen."
        default:
            currentNote = report?.coverage == "withinRequestedScope"
                ? "Die neue Suche wurde im angefragten Umfang beendet."
                : "Die Abdeckung der neuen Suche ist eingeschränkt oder unbekannt. Einzelheiten stehen im Suchbericht."
        }
        return [earlierNote, currentNote]
    }
}

extension MainController {
    @objc func saveSearchRecording() {
        guard let window, window.attachedSheet == nil, !exportIsBusy else { return }
        let recording: [String: Any]
        do { recording = try searchControl.captureRecording() }
        catch {
            presentActionIssue(summary: (error as? SearchControlFailure)?.message ?? error.localizedDescription, detail: nil)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Favenio-Suchstand.json"
        exportSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.exportSavePanel = nil
            guard response == .OK, let url = panel.url else { return }
            let started = self.exportWriter.writeJSON(recording, to: url, prettyPrinted: false) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.exportStatus = "Suchstand aufgezeichnet."
                case .failure(let error): self.exportStatus = "Aufzeichnung fehlgeschlagen. " + error.localizedDescription
                }
                self.refreshStatus()
            }
            if !started { self.presentActionIssue(summary: "Ein anderer Export läuft bereits.", detail: nil) }
        }
    }

    @objc func openSearchRecording() {
        guard let window, window.attachedSheet == nil, activeSearchRun == nil, !searchControl.handoff.busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let runID = self.searchControl.run?.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let loaded = Result { try HandoffSourceState.read(url, limit: SearchControlWire.maximumRequestBytes, check: {}).1 }
                DispatchQueue.main.async {
                    guard let self, self.searchControl.run?.id == runID else { return }
                    do { try self.searchControl.openRecording(Self.decodeSearchRecording(loaded.get())) }
                    catch {
                        self.presentActionIssue(summary: (error as? SearchControlFailure)?.message ?? error.localizedDescription, detail: nil)
                    }
                }
            }
        }
    }

    static func decodeSearchRecording(_ data: Data?) throws -> SearchRecording {
        let invalid = SearchControlFailure(code: "invalidRequest", message: "Ungültige Suchaufzeichnung.")
        guard let data, data.count <= SearchControlWire.maximumRequestBytes,
              !DateRangeTransport.hasDuplicateKeys(data), let object = preservedJSONObject(data) as? [String: Any] else {
            throw invalid
        }
        guard object["recording"] != nil else { return try SearchRecording.decode(nil, rawData: data) }
        guard Set(object.keys) == ["schemaVersion", "recording", "actions"],
              SearchControlWire.integer(object["schemaVersion"]) == 1,
              let actions = object["actions"] as? [[String: Any]], actions.count <= 32,
              let recording = JSONByteSlices.member("recording", in: data) else { throw invalid }
        return try SearchRecording.decode(nil, rawData: recording)
    }

    @objc func rerunSearchRecording() {
        guard let recording = searchControl.openedRecording, window?.attachedSheet == nil else { return }
        recordingComparisonWindow?.window.close()
        recordingComparisonWindow = nil
        setSearchRoots(recording.input.roots)
        searchField.stringValue = recording.input.pattern
        applyConfiguration(recording.input.options)
        let reference = recording.dateResolution == nil ? nil : recording.input.options.dateReferenceTime
        startSearchWithReference(reference, comparing: recording)
    }

    func finishRecordingComparison() {
        guard let comparison = recordingComparison, let run = searchControl.run, run.state != "running" else { return }
        recordingComparison = nil
        let report = searchReportController.snapshot
        let problem = run.state == "failed" ? "Für den Vergleich fehlt ein neuer Suchlauf mit auswertbaren Treffern."
            : comparison.incompatibility(run.input, report: report)
        let window = RecordingComparisonWindow(comparison, run: run, report: report, problem: problem)
        window.onClose = { [weak self] in self?.recordingComparisonWindow = nil }
        recordingComparisonWindow = window
        #if !FAVENIO_SELFTEST
        window.window.makeKeyAndOrderFront(nil)
        #endif
    }
}

final class RecordingComparisonWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 420),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    let summary: NSTextField
    let tabs: NSSegmentedControl
    let table = NSTableView()
    let newHits: [Hit]
    let earlierOnly: [Hit]
    var onClose: (() -> Void)?
    private var rows: [Hit] { tabs.selectedSegment == 1 ? earlierOnly : newHits }

    init(_ comparison: RecordingComparison, run: ControlledSearchRun, report: SearchReportSnapshot?, problem: String?) {
        let notes = comparison.coverageNotes(run, report: report)
        let dates = ISO8601DateFormatter()
        let times = "Früher \(dates.string(from: Date(timeIntervalSince1970: comparison.earlier.startedAt)))"
            + " · Neu \(dates.string(from: Date(timeIntervalSince1970: run.startedAt)))"
        summary = NSTextField(wrappingLabelWithString: ([times] + notes + [problem
            ?? "Dateien, die nur früher gefunden wurden, können weiterhin existieren."]).joined(separator: "\n"))
        newHits = problem == nil ? comparison.newHits : []
        earlierOnly = problem == nil ? comparison.earlierOnly : []
        tabs = NSSegmentedControl(labels: ["Neu gefunden (\(groupedNumber(newHits.count)))",
                                          "Nur früher gefunden (\(groupedNumber(earlierOnly.count)))"],
                                  trackingMode: .selectOne, target: nil, action: nil)
        super.init()
        window.title = "Suchläufe vergleichen"
        window.delegate = self
        window.minSize = NSSize(width: 580, height: 340)
        window.isReleasedWhenClosed = false
        summary.setAccessibilityIdentifier("recordingComparisonSummary")
        summary.lineBreakMode = .byWordWrapping
        let stack = NSStackView(views: [summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        window.contentView = stack
        summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        if problem == nil {
            tabs.selectedSegment = newHits.isEmpty && !earlierOnly.isEmpty ? 1 : 0
            tabs.target = self
            tabs.action = #selector(tabChanged)
            table.addTableColumn(NSTableColumn(identifier: .init("path")))
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.headerView = nil
            table.usesAlternatingRowBackgroundColors = true
            table.dataSource = self
            table.delegate = self
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            stack.addArrangedSubview(tabs)
            stack.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: summary.widthAnchor).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
            table.reloadData()
        }
        window.center()
    }

    @objc private func tabChanged() { table.reloadData() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let path = rows[row].path
        let label = NSTextField(labelWithString: path)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = path
        return label
    }
}
