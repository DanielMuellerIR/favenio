import AppKit

struct SearchReportProbe {
    static func run(_ arguments: [String]) throws {
        let mode = arguments[1]
        let owner = HitListController()
        let controller = owner.searchReportController
        let runner = SearchRunner()
        var completed: SearchExit?
        var exported: [String: Any]?
        var writing = false
        var written = false
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("favenio-report-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("report.json")
        let script = """
        import favenio,time
        report=favenio.SearchReport({'pattern':'\\ufeffneedle'})
        search=favenio.Search(None,False,1,True,search_report=report)
        report.emit(force=True)
        if '\(mode)' == 'flood':
            for i in range(12000): search.report_warning('problem '+str(i),path='/fixture/'+str(i)+'x'*500)
            report.emit('finished',force=True)
        elif '\(mode)' == 'invalid': print('{"type":"searchReport","schemaVersion":2}',flush=True)
        else: time.sleep(30)
        """
        controller.begin(configuration: [:])
        runner.start(arguments: ["-u", "-c", script], onBatch: { _, _ in }, onReport: { report in
            precondition(Thread.isMainThread)
            controller.accept(report)
            if mode == "live-export", !writing {
                writing = true
                let snapshot = report.exportObject
                precondition(owner.exportWriter.writeJSON(snapshot, to: destination) { result in
                    precondition(Thread.isMainThread)
                    if case .failure(let error) = result { fatalError(error.localizedDescription) }
                    let data = try! Data(contentsOf: destination)
                    exported = preservedJSONObject(data) as? [String: Any]
                    written = true
                    controller.end("cancelled")
                    runner.cancel()
                })
                precondition(!owner.exportWriter.writeJSON([:], to: destination) { _ in fatalError("zweiter Export") })
            }
        }, completion: { exit in
            completed = exit
            if mode == "flood" { controller.end("finished", exit: exit) }
            if mode == "invalid" { controller.end("failed", exit: exit) }
        })
        let deadline = Date().addingTimeInterval(20)
        while completed == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
        precondition(completed != nil)
        let snapshot = controller.snapshot!
        let item = snapshot.reasons.first
        let exportedConfig = exported?["configuration"] as? [String: Any]
        let invalid = Data(#"{"type":"searchReport","schemaVersion":1,"runID":"bad","state":"finished","configuration":{},"reasons":[],"counting":"events"}"#.utf8)
        controller.begin(configuration: [:], state: "recorded")
        let restoredState = controller.snapshot!.state
        controller.end("limitReached")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["rss": usage.ru_maxrss, "status": completed!.status, "error": completed!.errorMessage ?? "", "warnings": completed!.warningCount,
            "events": item?["count"] ?? 0, "examples": (item?["examples"] as? [Any])?.count ?? 0,
            "peakPackets": runner.transportPeaks.packets, "state": snapshot.state, "coverage": snapshot.coverage,
            "exportedState": exported?["state"] ?? "", "bomPreserved": exportedConfig?["pattern"] as? String == "\u{feff}needle",
            "writerFinished": written && !owner.exportWriter.isWriting,
            "invalidRejected": SearchReportSnapshot.parse(invalid) == nil,
            "cancelWarningKnown": snapshot.object["warningCount"] != nil, "restoredState": restoredState, "limitState": controller.snapshot!.state]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
