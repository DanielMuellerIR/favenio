import AppKit

func checkSearchControl(sandbox: URL, hits: [Hit]) -> String? {
    let host = MainController()
    host.tableView.dataSource = host
    host.tableView.delegate = host
    host.modeControl.segmentCount = SearchTextMode.allCases.count
    host.typeControl.segmentCount = 3
    host.fieldPopup.addItem(withTitle: "Alle")
    let control = host.searchControl
    defer { host.stopSearch() }
    func request(_ operation: String, _ fields: [String: Any] = [:], id: String = UUID().uuidString) -> Data {
        var object: [String: Any] = ["version": 1, "id": id, "deadline": Date().timeIntervalSince1970 + 9,
            "operation": operation, "runtimeID": control.runtimeID, "windowID": control.windowID]
        object.merge(fields) { _, new in new }
        return SearchControlWire.encode(object)
    }
    func response(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: control.handle(data)) as? [String: Any]) ?? [:]
    }
    func code(_ data: Data) -> String? { (response(data)["error"] as? [String: Any])?["code"] as? String }
    let input = ControlSearchInput(pattern: "FAVENIO_PROBE", root: sandbox.path,
                                   options: SearchConfiguration(mode: .content, archives: true))
    let configured = response(request("configure", ["configuration": input.object]))
    guard configured["error"] == nil, host.controlInput.pattern == input.pattern,
          host.searchConfiguration == input.options else { return "Controller-Konfiguration wird nicht in sichtbare Felder übernommen" }
    let start = request("start")
    let started = response(start)
    guard let originalRun = control.run?.id, (started["status"] as? [String: Any])?["runID"] as? String == originalRun,
          control.run?.input.pattern == input.pattern, host.activeSearchRun != nil,
          code(request("start")) == "busy" else { return "Controller startet nicht über den normalen Runner" }
    guard response(start)["status"] as? NSDictionary == started["status"] as? NSDictionary,
          control.run?.id == originalRun else { return "Wiederholter Start erzeugt einen neuen Lauf" }
    let changedInput = ControlSearchInput(pattern: "später", root: sandbox.path, options: SearchConfiguration())
    guard response(request("configure", ["configuration": changedInput.object]))["error"] == nil,
          control.run?.input.pattern == input.pattern, host.activeSearchRun != nil else { return "Konfigurieren verändert den laufenden Suchstand" }
    host.enqueueSearchHits(hits)
    host.flushPending()
    guard let first = host.hits.first else { return "Controller-Fixture fehlt" }
    let selection = request("select", ["runID": originalRun, "identity": LocalSearchController.identityObject(first.identity)])
    guard response(selection)["error"] == nil, host.selectedHitIdentities() == [first.identity] else { return "Treffer wird nicht über seine Identität ausgewählt" }
    let generation = control.generation
    let page = response(request("results", ["runID": originalRun, "offset": 0, "limit": 1]))
    guard (page["hits"] as? [Any])?.count == 1, page["generation"] as? Int == generation,
          page["count"] as? Int == host.hits.count else { return "Ergebnisseite ist nicht begrenzt" }
    host.applyHitsToTable(keepingSelection: host.selectedHitIdentities())
    guard host.selectedHitIdentities() == [first.identity],
          code(request("results", ["runID": originalRun, "generation": generation, "offset": 1, "limit": 1])) == "stale",
          code(request("results", ["runID": originalRun, "offset": 0, "limit": true])) == "invalidRequest" else { return "Veraltete Cursor oder Auswahlpflege fehlerhaft" }
    let cancelled = response(request("cancel", ["runID": originalRun]))
    guard (cancelled["status"] as? [String: Any])?["state"] as? String == "cancelled",
          host.activeSearchRun == nil, !host.hits.isEmpty, control.status["complete"] as? Bool == false else { return "Abbruch verliert Teilergebnisse oder wird als vollständig gemeldet" }
    let oldRunner = SearchRunner()
    host.startSearch()
    let replacementID = control.run?.id
    host.finishSearchRun(oldRunner, exit: SearchExit(status: 0, reason: .exit))
    guard replacementID != originalRun, control.run?.state == "running",
          code(request("select", ["runID": originalRun, "identity": LocalSearchController.identityObject(first.identity)])) == "stale" else { return "Alte Antworten gelangen in einen neuen Lauf" }
    host.stopSearch()
    control.begin(input)
    control.finished(SearchExit(status: 0, reason: .exit, warningCount: 7))
    guard control.status["state"] as? String == "warnings", control.status["warningCount"] as? Int == 7,
          control.status["complete"] as? Bool == false else { return "Warnungen erscheinen als vollständiger Lauf" }
    control.begin(input)
    control.finished(SearchExit(status: 2, reason: .exit, errorMessage: "Probe"))
    guard control.status["state"] as? String == "failed", control.status["error"] as? String == "Suche fehlgeschlagen: Probe" else { return "Fehlerdiagnose geht im Controller verloren" }
    host.replaceSearchResults([])
    control.begin(input)
    control.finished(SearchExit(status: 1, reason: .exit))
    guard control.status["complete"] as? Bool == true, control.status["count"] as? Int == 0 else { return "Nulltrefferstatus falsch" }
    guard code(request("cancel", ["runID": control.run!.id, "runtimeID": UUID().uuidString])) == "stale",
          code(request("status", ["deadline": 0])) == "expired",
          code(request("status", ["surprise": 1])) == "invalidRequest" else { return "Frist-/Laufzeit-/Schema-Prüfung fehlt" }
    // Echter Suchprozess: Die vorherigen Lifecycle-Proben halten die Reihenfolge
    // deterministisch; hier müssen die Ergebnisse vom Python-Kern ankommen.
    _ = response(request("configure", ["configuration": input.object]))
    _ = response(request("start"))
    let stopAt = ProcessInfo.processInfo.systemUptime + 10
    while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < stopAt {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard control.run?.state == "completed", host.hits.contains(where: { $0.line == 1 }),
          host.hits.contains(where: { $0.isMember }) else { return "Controller erhält keine echten JSONL-Ergebnisse aus dem Python-Kern" }
    host.replaceSearchResults(hits)
    control.begin(input)
    control.finished(SearchExit(status: 0, reason: .exit))
    let savedRun = control.run!.id
    let savedStart = control.run!.startedAt
    let saved = response(request("captureRecording", ["runID": savedRun]))
    guard let recording = saved["recording"] as? [String: Any],
          let decoded = try? SearchRecording.decode(recording), decoded.hits.count == hits.count else {
        return "Beendeter Suchstand wird nicht vollständig aufgezeichnet"
    }
    let opened = response(request("openRecording", ["recording": recording]))
    guard opened["error"] == nil, host.activeSearchRun == nil, host.hits.count == hits.count,
          control.run?.id != savedRun, control.run?.origin == "recording",
          control.recordedSource?["startedAt"] as? Double == savedStart,
          host.statusText().contains("Aufgezeichneter Stand"),
          code(request("select", ["runID": savedRun, "identity": LocalSearchController.identityObject(hits[0].identity)])) == "stale" else {
        return "Wiederöffnung startet eine Suche oder verliert Herkunft/Entwertung"
    }
    var invalid = recording
    invalid["state"] = "completed"; invalid["warningCount"] = 1
    guard code(request("openRecording", ["recording": invalid])) == "invalidRequest",
          control.run?.origin == "recording" else { return "Ungültige Aufzeichnung verändert den Stand" }
    invalid = recording; invalid["hits"] = Array(repeating: (recording["hits"] as! [Any])[0], count: 129)
    guard code(request("openRecording", ["recording": invalid])) == "invalidRequest" else {
        return "Treffergrenze für Aufzeichnungen fehlt"
    }
    invalid = recording; invalid["selection"] = [["filesystemPath": "/missing", "archiveMembers": [], "archiveMemberBytes": []]]
    guard code(request("openRecording", ["recording": invalid])) == "invalidRequest" else {
        return "Fehlende Auswahl wird still verworfen"
    }
    host.replaceSearchResults(hits); control.begin(input)
    control.cancelled()
    let partial = response(request("captureRecording", ["runID": control.run!.id]))
    guard let partialRecording = partial["recording"] as? [String: Any],
          partialRecording["state"] as? String == "cancelled",
          response(request("openRecording", ["recording": partialRecording]))["error"] == nil,
          control.status["complete"] as? Bool == false else {
        return "Abgebrochener Stand erscheint vollständig"
    }
    return nil
}
