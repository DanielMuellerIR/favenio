import AppKit
import Darwin

func checkSearchRootsControl(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host; host.tableView.delegate = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    let folder = sandbox.appendingPathComponent("ap17-project")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("AP17\n".utf8).write(to: folder.appendingPathComponent("needle.txt"))
    } catch { return "Mehrwurzel-Fixture fehlt" }
    defer { try? FileManager.default.removeItem(at: folder) }
    let control = host.searchControl
    func response(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString,
            "deadline": Date().timeIntervalSince1970 + 8, "operation": operation,
            "runtimeID": control.runtimeID, "windowID": control.windowID]
        value.merge(extra) { _, rhs in rhs }
        return (try? JSONSerialization.jsonObject(with: control.handle(SearchControlWire.encode(value))) as? [String: Any]) ?? [:]
    }
    var options = SearchConfiguration()
    options.criteriaJSON = #"{"schemaVersion":1,"root":{"id":"relative","field":"relativePath","operator":"equals","value":"needle.txt"}}"#
    options.textEncoding = .windows1252
    let roots = [sandbox.path, folder.path]
    let input = ControlSearchInput(pattern: "", roots: roots, options: options)
    guard response("configure", ["configuration": input.object])["error"] == nil,
          host.searchRoots.map({ Data($0.utf8) }) == SearchRoots(roots).bytes else { return "Controller verliert Wurzelliste" }
    _ = response("start")
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    host.flushPending()
    guard control.run?.state == "completed", host.hits.count == 1,
          host.hits[0].searchRootBytes == Data(folder.path.utf8),
          host.resultFilterRoot == nil else { return "Überlappung/Kriterien verlieren erfolgreiche Herkunft" }
    let raw = try? control.captureRecording()
    guard let raw, raw["schemaVersion"] as? Int == 3,
          let decoded = try? SearchRecording.decode(raw), decoded.input.options == options,
          decoded.hits.first?.searchRootBytes == Data(folder.path.utf8) else { return "Aufnahme3 verliert Liste, Herkunft oder Textkodierung" }
    let preservedInput = host.controlInput.object as NSDictionary
    let preservedHits = host.hits
    let preservedRun = control.run?.id
    var invalidInputs: [[String: Any]] = []
    let futureConfigurationVersion = (SearchControlWire.capabilities["configurationSchemaVersions"] as! [Int]).max()! + 1
    for bad: Any in [true, futureConfigurationVersion] { var object = input.object; object["schemaVersion"] = bad; invalidInputs.append(object) }
    for paths in [[], [folder.path, folder.path], [folder.path, "relative"], Array(repeating: "/x", count: 17)] {
        var object = input.object; object["roots"] = paths; invalidInputs.append(object)
    }
    var mixed = input.object; mixed["root"] = folder.path; invalidInputs.append(mixed)
    for object in invalidInputs {
        guard response("configure", ["configuration": object])["error"] != nil,
              host.controlInput.object as NSDictionary == preservedInput, host.hits == preservedHits,
              control.run?.id == preservedRun else { return "Ungültige Wurzelliste verändert Teilzustand" }
    }
    for badRoot: Any in [NSNull(), "/foreign"] {
        var broken = raw
        var hits = broken["hits"] as! [[String: Any]]
        hits[0]["searchRoot"] = badRoot; broken["hits"] = hits
        guard response("openRecording", ["recording": broken])["error"] != nil,
              host.controlInput.object as NSDictionary == preservedInput, host.hits == preservedHits,
              control.run?.id == preservedRun else { return "Ungültige Herkunft verändert aufgezeichneten Stand" }
    }
    var oldVersion = raw; oldVersion["schemaVersion"] = 2
    guard (try? SearchRecording.decode(oldVersion)) == nil else { return "Mehrwurzelaufnahme wird als Altformat gelesen" }
    do {
        var foreign = host.hits[0]; foreign.searchRootBytes = Data("/foreign".utf8)
        let file = try writeQuickHandoff([foreign], version: 2)
        var url = URLComponents(); url.scheme = "favenio"; url.host = "results-v2"
        url.queryItems = [URLQueryItem(name: "q", value: "nicht übernehmen"),
            URLQueryItem(name: "root", value: folder.path), URLQueryItem(name: "file", value: file.path)]
        host.handleFavenioURL(url.url!)
        guard host.controlInput.object as NSDictionary == preservedInput, host.hits == preservedHits,
              control.run?.id == preservedRun else { return "Fremde Legacy-Übergabe verändert Teilzustand" }
        host.loadResults(payload: QuickHandoffPayload(hits: [foreign], version: 2, roots: [folder.path]))
        guard host.controlInput.object as NSDictionary == preservedInput, host.hits == preservedHits,
              control.run?.id == preservedRun else { return "Direkte Übergabe verwirft fremde Treffer still" }
    } catch { return "Legacy-Herkunftsgegenprobe fehlt: \(error)" }
    try? FileManager.default.removeItem(at: folder)
    guard response("openRecording", ["recording": raw])["error"] == nil,
          host.searchRoots == roots, host.hits.count == 1 else { return "Historischer Mehrwurzelstand benötigt vorhandene Quellen" }
    _ = response("start")
    guard control.run?.state == "failed", host.activeSearchRun == nil, host.hits.isEmpty,
          host.searchRoots == roots, host.statusText().contains(folder.path) else { return "Fehlende zweite Wurzel startet Teilumfang oder verändert Liste" }
    return nil
}

func checkResultGroupingControl(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host
    host.tableView.delegate = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    let source = sandbox.appendingPathComponent("group-control.txt")
    do { try Data("needle\n".utf8).write(to: source) } catch { return "Gruppen-Controller-Fixture fehlt" }
    let first = Hit(path: source.path, kind: "file", line: 1, size: 7,
        filesystemPath: source.path, archiveMembers: [], isDirectory: false)
    let other = Hit(path: "/missing/other.md", kind: "file", line: nil, size: 1,
        filesystemPath: "/missing/other.md", archiveMembers: [], isDirectory: false)
    host.replaceSearchResults([first, other])
    let control = host.searchControl
    control.begin(ControlSearchInput(pattern: "needle", root: sandbox.path, options: SearchConfiguration()))
    control.cancelled()
    control.handoff.ensureApplication = { $0(false) }
    defer { control.handoff.cancelPending() }
    func response(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["version": 1, "id": UUID().uuidString,
            "deadline": Date().timeIntervalSince1970 + 8, "operation": operation,
            "runtimeID": control.runtimeID, "windowID": control.windowID, "runID": control.run!.id]
        object.merge(extra) { _, value in value }
        return (try? JSONSerialization.jsonObject(with: control.handle(SearchControlWire.encode(object))) as? [String: Any]) ?? [:]
    }
    host.resultGrouping.setMode(.folder)
    let oldGeneration = control.generation
    host.resultGrouping.collapseAll()
    let page = response("results", ["offset": 0, "limit": 10])
    guard (page["hits"] as? [Any])?.count == 2,
          (page["resultGrouping"] as? [String: Any])?["displayedHitCount"] as? Int == 0,
          (page["resultGrouping"] as? [String: Any])?["resultsIncludeCollapsed"] as? Bool == true,
          control.generation > oldGeneration,
          (response("results", ["offset": 1, "limit": 1, "generation": oldGeneration])["error"] as? [String: Any])?["code"] as? String == "stale" else {
        return "Gruppen-Controller verliert Vollumfang, Klappzustand oder Cursorentwertung"
    }
    let selected = response("select", ["identity": LocalSearchController.identityObject(first.identity)])
    guard selected["error"] == nil, host.selectedHitIdentities() == [first.identity],
          host.resultGrouping.projection.displayedHitCount == 1,
          control.status["selectionCount"] as? Int == 1,
          let recording = try? control.captureRecording(), (recording["hits"] as? [Any])?.count == 2 else {
        return "Controller-select/Aufzeichnung verwechselt Gruppenzeilen mit Treffern"
    }
    let header = (0..<host.resultTableRowCount).first { host.resultGrouping.projection.group(at: $0) != nil }!
    guard host.tableView(host.tableView, pasteboardWriterForRow: header) == nil else { return "Gruppenheader wird gezogen" }
    host.resultGrouping.collapseAll()
    let handoff = response("handoff", ["identity": LocalSearchController.identityObject(first.identity)])
    guard handoff["error"] == nil, let id = (handoff["handoff"] as? [String: Any])?["id"] as? String,
          host.resultGrouping.projection.displayedHitCount == 1 else { return "Controller-handoff bleibt unsichtbar oder trifft falsche Zeile" }
    host.resultGrouping.collapseAll()
    guard control.handoff.jobs[id]?.state == "cancelled", host.selectedHitIdentities().isEmpty,
          host.hits.count == 2 else { return "Einklappen lässt alte Fastra-Aktion oder Auswahl bestehen" }
    let item = NSMenuItem(title: "", action: #selector(MainController.exportAllHits(_:)), keyEquivalent: "")
    _ = host.validateMenuItem(item)
    guard item.title == "Alle gefilterten Treffer exportieren…" else { return "Gruppenexport nennt einen falschen Umfang" }
    return nil
}

func checkResultFilterControl(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    host.tableView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
    let input = ControlSearchInput(pattern: "fixture", root: sandbox.path, options: SearchConfiguration())
    func hit(_ name: String, size: Int = 1) -> Hit {
        let path = sandbox.appendingPathComponent(name).path
        return Hit(path: path, kind: "file", line: 7, size: size,
            filesystemPath: path, archiveMembers: [], isDirectory: false)
    }
    func wait() -> Bool {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while host.resultFilter.isFiltering && ProcessInfo.processInfo.systemUptime < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return !host.resultFilter.isFiltering && host.resultFilter.errorMessage == nil
    }
    func filter(_ value: String, op: String = "contains") {
        host.resultFilter.criteria.applyJSON(CriteriaNode(field: "name", matchOperator: op, value: value).json)
        host.resultFilter.apply()
    }
    let first = hit("keep-a.txt"), other = hit("other.txt"), last = hit("keep-c.txt")
    host.replaceSearchResults([first, other, last])
    host.searchControl.begin(input)
    host.searchControl.cancelled()
    host.tableView.selectRowIndexes([0], byExtendingSelection: false)
    let generation = host.searchControl.generation
    filter("keep-")
    guard wait(), host.hits == [first, last], host.statistics.count == 2,
          host.searchControl.generation > generation,
          (host.searchControl.status["resultFilter"] as? [String: Any])?["sourceCount"] as? Int == 3,
          let recording = try? host.searchControl.captureRecording(),
          (recording["hits"] as? [Any])?.count == 3 else {
        return "Controller/Statistik/Aufzeichnung verliert ungefilterte Quellmenge"
    }
    host.removeFromResults(nil)
    host.resultFilter.reset()
    host.enqueueSearchHits([first]); host.flushPending()
    guard Set(host.hits.map { $0.identity }) == [other.identity, last.identity],
          host.statistics.count == 2 else { return "Filterreset bringt ausdrücklich entfernten Treffer zurück" }
    host.replaceSearchResults((0..<129).map { hit(String(format: "item-%04d.txt", $0)) })
    host.searchControl.begin(input); host.searchControl.cancelled()
    filter("item-0000.txt", op: "equals")
    guard wait(), host.hits.count == 1, host.resultFilter.sourceCount == 129,
          (try? host.searchControl.captureRecording()) == nil else {
        return "Ansichtsfilter umgeht vollständige Aufzeichnungsgrenze"
    }
    host.replaceSearchResults([])
    filter("keep-")
    let started = ProcessInfo.processInfo.systemUptime
    for batch in 0..<10 {
        let incoming = (batch * 5000..<(batch + 1) * 5000).map { n in
            hit(String(format: (n % 2 == 0 ? "keep-" : "other-") + "%05d.txt", n), size: n)
        }
        host.enqueueSearchHits(incoming); host.flushPending()
        guard wait() else { return "Großer sortierter Filter-Nachschub endet nicht: \(host.resultFilter.errorMessage ?? "ausstehend")" }
    }
    guard host.resultFilter.sourceCount == 50000, host.hits.count == 25000,
          host.statistics.count == 25000,
          host.hits.first?.displayName == "keep-00000.txt",
          host.hits.last?.displayName == "keep-49998.txt" else {
        return "Großer sortierter Filter-Nachschub verliert Treffer oder Statistik"
    }
    print("RESULT FILTER STREAM OK: source=50000 visible=25000 batches=10 seconds=\(ProcessInfo.processInfo.systemUptime - started)")
    host.resultFilter.reset()
    guard host.hits.count == 50000, host.statistics.count == 50000 else { return "Großer Filterreset verliert Quelltreffer" }
    host.resultFilter.clearForSearch()
    return nil
}

func checkSearchControl(sandbox: URL, hits: [Hit]) -> String? {
    let host = MainController()
    host.tableView.dataSource = host
    host.tableView.delegate = host
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
    do {
        let previous = host.controlInput.object as NSDictionary
        for options in [[URLQueryItem(name: "encoding", value: nil)],
                        [URLQueryItem(name: "encoding", value: nil), URLQueryItem(name: "encoding", value: "mac-roman")]] {
            let file = try writeQuickHandoff(hits)
            defer { try? FileManager.default.removeItem(at: file) }
            var url = URLComponents()
            url.scheme = "favenio"; url.host = "results"
            url.queryItems = [URLQueryItem(name: "q", value: "changed"),
                              URLQueryItem(name: "root", value: sandbox.path),
                              URLQueryItem(name: "file", value: file.path)] + options
            host.handleFavenioURL(url.url!)
            guard host.controlInput.object as NSDictionary == previous,
                  FileManager.default.fileExists(atPath: file.path) else {
                return "Leere oder doppelte Kodierung in alter Quick-Übergabe verändert den Stand"
            }
        }
    } catch { return "Quick-Decoder-Gegenprobe: \(error)" }
    for encoding in SearchTextEncoding.allCases {
        var options = SearchConfiguration()
        options.textEncoding = encoding
        let input = ControlSearchInput(pattern: "Büro", root: sandbox.path, options: options)
        guard response(request("configure", ["configuration": input.object]))["error"] == nil,
              host.filterView.textEncoding == encoding, host.controlInput.options == options else {
            return "Lokale Konfiguration verliert die Textkodierung"
        }
        let hit = Hit(path: sandbox.path + "/leaf", kind: "file", line: 2, size: 8,
                      filesystemPath: sandbox.path + "/leaf", archiveMembers: [], isDirectory: false,
                      contentEncoding: "utf-16-le")
        let recording = SearchRecording(input: input, runID: UUID().uuidString, startedAt: 1, capturedAt: 2,
            state: "completed", warningCount: 0, error: nil, hits: [hit], selection: [])
        guard let decoded = try? SearchRecording.decode(recording.object), decoded.input.options == options,
              decoded.hits == [SearchRoots(input.roots).carrying(hit)!], recording.object["schemaVersion"] as? Int == (encoding == .utf8 ? 1 : 2) else {
            return "Aufzeichnung verliert die Textkodierung oder Decoderbelege"
        }
        if encoding != .utf8 {
            var invalid = recording.object; invalid["schemaVersion"] = 1
            guard (try? SearchRecording.decode(invalid)) == nil else { return "Nichtstandardkodierung in Aufnahmeformat 1 akzeptiert" }
        }
        for values in [["utf-7"], ["utf-8", "auto"]] {
            var invalid = input.object
            invalid["options"] = values.map { ["name": "encoding", "value": $0] }
            guard code(request("configure", ["configuration": invalid])) == "invalidRequest",
                  host.controlInput.options == options else { return "Abgelehnte Decoderwahl verändert die Konfiguration" }
        }
    }
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
    let report = response(request("report", ["runID": originalRun]))
    guard report["runID"] as? String == originalRun,
          (report["report"] as? [String: Any])?["coverage"] as? String == "incomplete",
          code(request("report", ["runID": UUID().uuidString])) == "stale" else {
        return "Suchbericht ist nicht an den angefragten Lauf gebunden"
    }
    let cancelled = response(request("cancel", ["runID": originalRun]))
    guard (cancelled["status"] as? [String: Any])?["state"] as? String == "cancelled",
          host.activeSearchRun == nil, !host.hits.isEmpty, control.status["complete"] as? Bool == false else { return "Abbruch verliert Teilergebnisse oder wird als vollständig gemeldet" }
    let oldRunner = SearchRunner()
    host.startSearch()
    let replacementID = control.run?.id
    host.finishSearchRun(oldRunner, exit: SearchExit(status: 0, reason: .exit))
    guard replacementID != originalRun, control.run?.state == "running",
          code(request("select", ["runID": originalRun, "identity": LocalSearchController.identityObject(first.identity)])) == "stale",
          code(request("report", ["runID": originalRun])) == "stale" else { return "Alte Antworten gelangen in einen neuen Lauf" }
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
    let complete = SearchReportSnapshot(object: ["type": "searchReport", "schemaVersion": 1,
        "runID": UUID().uuidString, "state": "finished", "coverage": "withinRequestedScope",
        "counting": "events", "configuration": [:], "reasons": [[String: Any]]()])
    host.searchReportController.accept(complete)
    control.finished(SearchExit(status: 1, reason: .exit))
    guard control.status["complete"] as? Bool == true, control.status["count"] as? Int == 0 else { return "Nulltrefferstatus falsch" }
    guard code(request("cancel", ["runID": control.run!.id, "runtimeID": UUID().uuidString])) == "stale",
          code(request("status", ["deadline": 0])) == "expired",
          code(request("status", ["surprise": 1])) == "invalidRequest" else { return "Frist-/Laufzeit-/Schema-Prüfung fehlt" }
    let beforeInvalidKeys = control.run!.id
    for key in ["id", "operation"] {
        var badKey = preservedJSONObject(request("status")) as! [String: Any]
        badKey["\u{FEFF}" + key] = badKey.removeValue(forKey: key)
        guard code(SearchControlWire.encode(badKey)) == "invalidRequest", control.run?.id == beforeInvalidKeys else {
            return "BOM vor Auftragsschlüssel beendet oder verändert den Controller"
        }
        var badValue = preservedJSONObject(request("status")) as! [String: Any]
        badValue[key] = "\u{FEFF}" + (badValue[key] as! String)
        guard code(SearchControlWire.encode(badValue)) == "invalidRequest", control.run?.id == beforeInvalidKeys else {
            return "BOM vor UUID/Operation verändert den Controller"
        }
    }
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
    let missingTemplateRoot = sandbox.appendingPathComponent("missing-template-root").path
    host.applyTemplate(SearchTemplate(name: "Fehlender Ordner", pattern: "neu",
        root: missingTemplateRoot,
        configuration: input.options))
    guard host.activeSearchRun == nil, host.searchRoots == [missingTemplateRoot],
          host.statusLabel.stringValue.contains("Aufgezeichneter Stand"),
          host.statusLabel.stringValue.contains("Vorlage „Fehlender Ordner“ geladen"),
          host.statusLabel.stringValue.contains("fehlt:") else {
        return "Vorlage nach Aufzeichnung verdeckt den fehlenden Suchordner oder die Herkunft"
    }
    var invalid = recording
    let recordedRun = control.run!.id
    host.filterView.rawFacts = ["min-size": "1"]
    host.stopSearchForChangedCriteria()
    guard host.activeSearchRun == nil, control.run?.id == recordedRun,
          host.hits.count == hits.count, host.statusLabel.stringValue.contains("Aufgezeichneter Stand (abgeschlossen)") else {
        return "Filteränderung entfernt die Kennzeichnung des unveränderten aufgezeichneten Stands"
    }
    host.minWidthField.stringValue = "ungültig"
    host.stopSearchForChangedCriteria()
    guard host.statusLabel.stringValue.contains("Aufgezeichneter Stand"),
          host.statusLabel.stringValue.contains("Breite") else {
        return "Ungültiger Maßfilter verdeckt Aufnahmeherkunft oder Eingabefehler"
    }
    host.minWidthField.stringValue = ""
    host.stopSearchForChangedCriteria()
    guard host.statusLabel.stringValue.contains("Aufgezeichneter Stand (abgeschlossen)") else {
        return "Korrigierter Maßfilter verliert Aufnahmeherkunft"
    }
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
    // Ein maximal großer Baum muss Konfiguration, echte Suche und Aufnahme
    // verlustfrei durchlaufen; abgelehnte Formate dürfen nichts umstellen.
    let criteria = """
    {"schemaVersion":1,"root":{"id":"mixed","op":"and","children":[{"id":"visible","field":"name","operator":"regex","value":"."},{"id":"content","field":"content","operator":"contains","value":"FAVENIO_PROBE"}]}}
    """
    var criteriaOptions = input.options
    criteriaOptions.criteriaJSON = criteria + String(repeating: " ", count: CriteriaTransport.maximumBytes - criteria.utf8.count)
    let criteriaInput = ControlSearchInput(pattern: input.pattern, root: sandbox.path, options: criteriaOptions)
    guard response(request("configure", ["configuration": criteriaInput.object]))["error"] == nil,
          host.controlInput.options == criteriaOptions else { return "Steuerung verliert maximal großen Kriterienbaum" }
    _ = response(request("start"))
    let criteriaStopAt = ProcessInfo.processInfo.systemUptime + 10
    while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < criteriaStopAt {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard control.run?.state == "completed", !host.hits.isEmpty,
          host.hits.allSatisfy({ $0.criteriaEvidence.map { $0.id } == ["visible", "content"] }) else {
        return "Kriterien aus der Steuerung erreichen nicht dieselbe Suchmaschine: \(control.status)"
    }
    let criteriaSaved = response(request("captureRecording", ["runID": control.run!.id]))
    guard let criteriaRecording = criteriaSaved["recording"] as? [String: Any],
          criteriaRecording["schemaVersion"] as? Int == 2,
          SearchControlWire.encode(criteriaRecording).count > 48_000,
          response(request("openRecording", ["recording": criteriaRecording]))["error"] == nil,
          host.controlInput.options == criteriaOptions, control.run?.origin == "recording",
          host.statusText().contains("Aufgezeichneter Stand") else {
        return "Kriterienaufnahme verliert Konfiguration, Herkunft oder neue Größenbegrenzung"
    }
    let preservedRun = control.run!.id
    var oldCriteriaRecording = criteriaRecording
    oldCriteriaRecording["schemaVersion"] = 1
    guard let migratedRecording = try? SearchRecording.decode(oldCriteriaRecording),
          migratedRecording.input.options == host.controlInput.options,
          migratedRecording.object["schemaVersion"] as? Int == 2 else {
        return "Kriterienaufnahme aus 0.40.0 wird nicht verlustfrei migriert"
    }
    for version: Any in [6, true] {
        var bad = criteriaRecording
        bad["schemaVersion"] = version
        guard code(request("openRecording", ["recording": bad])) == "invalidRequest",
              control.run?.id == preservedRun, host.controlInput.options == criteriaOptions else {
            return "Abgelehnte Aufnahmeversion verändert den aktuellen Stand"
        }
    }
    criteriaOptions.criteriaJSON! += " "
    let oversizedInput = ControlSearchInput(pattern: "nicht übernehmen", root: sandbox.path, options: criteriaOptions)
    guard code(request("configure", ["configuration": oversizedInput.object])) == "invalidRequest",
          control.run?.id == preservedRun, host.controlInput.pattern == input.pattern else {
        return "Zu große Kriterien verändern die aktuelle Konfiguration"
    }
    return nil
}

func checkDateRangesControl(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host; host.tableView.delegate = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    let root = sandbox.appendingPathComponent("ap18-date")
    defer { host.stopSearch(); host.resultFilter.stopForTermination(); try? FileManager.default.removeItem(at: root) }
    func fixture() -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, iso) in [("spring.txt", "2026-03-29T12:00:00Z"), ("next.txt", "2026-03-30T12:00:00Z")] {
                let file = root.appendingPathComponent(name)
                try Data("AP18\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.modificationDate: ISO8601DateFormatter().date(from: iso)!], ofItemAtPath: file.path)
            }
            return true
        } catch { return false }
    }
    guard fixture() else { return "Kalender-Fixture fehlt" }
    let control = host.searchControl
    func response(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "deadline": Date().timeIntervalSince1970 + 8,
            "operation": operation, "runtimeID": control.runtimeID, "windowID": control.windowID]
        value.merge(extra) { _, rhs in rhs }
        return (try? JSONSerialization.jsonObject(with: control.handle(SearchControlWire.encode(value))) as? [String: Any]) ?? [:]
    }
    func wait() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        host.flushPending(); return host.activeSearchRun == nil
    }
    let question = DateRangeSpec(kind: "relative", timeZone: "Europe/Berlin", preset: "today")
    var options = SearchConfiguration(); options.dateRanges["modified"] = question
    var node = CriteriaNode(id: "same_day", field: "modified", matchOperator: "equals"); node.dateRange = question; options.criteriaJSON = node.json
    let input = ControlSearchInput(pattern: "", roots: [root.path], options: options)
    guard response("configure", ["configuration": input.object])["error"] == nil else { return "Kalender-Konfiguration3 abgelehnt" }
    var oldInput = input.object; oldInput["schemaVersion"] = 2
    guard response("configure", ["configuration": oldInput])["error"] != nil,
          host.searchConfiguration.dateRanges == options.dateRanges else { return "Kalenderfrage als Altformat akzeptiert oder teilmutiert" }
    guard response("start", ["dateReferenceTime": "2026-03-29T12:00:00Z"])["error"] == nil, wait(),
          control.run?.state == "completed", host.hits.count == 1, host.hits[0].filesystemPath == root.appendingPathComponent("spring.txt").path,
          control.run?.input.options.dateReferenceTime == "2026-03-29T12:00:00Z" else { return "Datumsfilter und Regelzeile teilen keinen expliziten Kontext: \(control.status)" }
    let answer = response("captureRecording", ["runID": control.run!.id])
    guard let object = answer["recording"] as? [String: Any], object["schemaVersion"] as? Int == 4,
          let recording = try? SearchRecording.decode(object), let dates = recording.dateResolution,
          DateRangeTransport.bound(dates, to: recording.input.options),
          (preservedJSONObject(dates) as? [String: Any])?["entries"] is [[String: Any]] else { return "Aufnahme4 verliert tatsächliche Kalendergrenzen" }
    var wrong = object; var wrongProof = wrong["dateResolution"] as! [String: Any]; wrongProof["referenceInput"] = "2026-03-30T12:00:00Z"; wrong["dateResolution"] = wrongProof
    guard (try? SearchRecording.decode(wrong)) == nil else { return "Aufnahme bindet Datumsbeleg nicht an Referenz" }
    do { try FileManager.default.removeItem(at: root) } catch { return "Historische Fixture lässt sich nicht entfernen" }
    guard response("openRecording", ["recording": object])["error"] == nil,
          host.hits.count == 1, control.run?.origin == "recording",
          host.searchReportController.snapshot?.object["dateResolution"].flatMap({ DateRangeTransport.resolution($0) }) == dates else { return "Historisches Öffnen verändert Datumsbelege oder benötigt Quelle" }
    guard fixture() else { return "Rerun-Fixture fehlt" }
    guard response("configure", ["configuration": recording.input.object])["error"] == nil,
          response("start", ["dateReferenceTime": "2026-03-30T12:00:00Z"])["error"] == nil, wait(),
          control.run?.state == "completed", host.hits.count == 1, host.hits[0].filesystemPath == root.appendingPathComponent("next.txt").path,
          control.run?.input.options.dateReferenceTime == "2026-03-30T12:00:00Z",
          recording.input.options.dateReferenceTime == "2026-03-29T12:00:00Z" else { return "Neuer Start übernimmt historischen Referenzzeitpunkt" }
    return nil
}

func checkFinderMetadataControl(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host; host.tableView.delegate = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    let root = sandbox.appendingPathComponent("ap19-finder")
    defer { host.stopSearch(); host.resultFilter.stopForTermination(); try? FileManager.default.removeItem(at: root) }
    let comment = "\u{FEFF}Kommentar A\u{0308}\nzweite Zeile 🌿"
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("synthetic.txt"), folder = root.appendingPathComponent("synthetic-folder")
        try Data("own fixture".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for path in [file.path, folder.path] {
            for (key, value) in [("com.apple.metadata:_kMDItemUserTags", ["\u{FEFF}Projekt A\u{0308}\r\n6", "Blau\n4"] as Any),
                                 ("com.apple.metadata:kMDItemFinderComment", comment as Any)] {
                let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
                guard data.withUnsafeBytes({ setxattr(path, key, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }) == 0 else { return "Finder-Fixtureattribute nicht schreibbar" }
            }
        }
    } catch { return "Finder-Fixture fehlt: \(error)" }
    let control = host.searchControl
    func response(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString, "deadline": Date().timeIntervalSince1970 + 8,
            "operation": operation, "runtimeID": control.runtimeID, "windowID": control.windowID]
        value.merge(extra) { _, rhs in rhs }
        return preservedJSONObject(control.handle(SearchControlWire.encode(value))) as? [String: Any] ?? [:]
    }
    func wait() -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while (host.activeSearchRun != nil || host.resultFilter.isFiltering) && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        host.flushPending()
        return host.activeSearchRun == nil && !host.resultFilter.isFiltering && host.resultFilter.errorMessage == nil
    }
    var date = CriteriaNode(id: "date", field: "modified", matchOperator: "equals")
    date.dateRange = DateRangeSpec(kind: "relative", timeZone: "UTC", preset: "today")
    let tag = CriteriaNode(id: "tag", field: "finderTags", matchOperator: "equals", value: "\u{FEFF}Projekt Ä\r")
    var options = SearchConfiguration(); options.finderMetadata = true
    options.criteriaJSON = CriteriaNode(id: "both", groupOperator: "and", children: [tag, date]).json
    let input = ControlSearchInput(pattern: "", roots: [root.path], options: options)
    guard input.object["schemaVersion"] as? Int == 4,
          response("configure", ["configuration": input.object])["error"] == nil,
          response("start")["error"] == nil, wait(), host.hits.count == 2,
          host.hits.contains(where: { $0.isDirectory }),
          host.hits.allSatisfy({ $0.finderMetadata?.commentBytes == Data(comment.utf8) }) else { return "Finder/Kalender-Suche verliert Datei, Ordner oder Originaltext: \(control.status)" }
    let hit = host.hits[0]
    let tagsColumn = NSTableColumn(identifier: .init("finderTags"))
    let commentColumn = NSTableColumn(identifier: .init("finderComment"))
    guard let tagsCell = host.hitCell(host.tableView, column: tagsColumn, row: 0) as? FinderTagsCellView,
          let commentCell = host.hitCell(host.tableView, column: commentColumn, row: 0),
          host.renderFinderColumn(tagsColumn, cell: tagsCell, hit: hit),
          host.renderFinderColumn(commentColumn, cell: commentCell, hit: hit),
          tagsCell.textField?.maximumNumberOfLines == 1,
          commentCell.textField?.maximumNumberOfLines == 1,
          tagsCell.textField?.stringValue.contains("Projekt A\u{0308} ↵ ") == true,
          tagsCell.textField?.stringValue.rangeOfCharacter(from: .newlines) == nil,
          commentCell.textField?.stringValue == "\u{FEFF}Kommentar A\u{0308} ↵ zweite Zeile 🌿",
          commentCell.textField?.toolTip == comment,
          FinderMetadataView.singleLineSummary("a\r\nb\rc\nd\u{0085}e\u{2028}f\u{2029}g") == "a ↵ b ↵ c ↵ d ↵ e ↵ f ↵ g",
          FinderMetadataView.tags(hit.finderMetadata).string.contains("Projekt A\u{0308}\r") else { return "Finder-Spalten verlieren Einzeilenbegrenzung oder Originaltext" }
    for (style, color) in [(NSView.BackgroundStyle.emphasized, NSColor.alternateSelectedControlTextColor), (.normal, .labelColor)] {
        tagsCell.backgroundStyle = style
        let text = tagsCell.textField!.attributedStringValue
        guard (text.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor)?.isEqual(color) == true,
              (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.isEqual(NSColor.systemRed) == true,
              tagsCell.snapshot?.json == hit.finderMetadata?.json else { return "Finder-Tag-Auswahl verliert Textkontrast, Tagfarbe oder Snapshot" }
    }
    print("FINDER CELLS OK: single line, original tooltips/preview, selected text color, tag colors")
    let answer = response("captureRecording", ["runID": control.run!.id])
    guard let object = answer["recording"] as? [String: Any], object["schemaVersion"] as? Int == 5,
          SearchControlWire.integer(object["finderMetadataCapability"]) == 1,
          let recording = try? SearchRecording.decode(object, rawData: SearchControlWire.encode(object)),
          let dates = recording.dateResolution, DateRangeTransport.bound(dates, to: recording.input.options),
          recording.hits.allSatisfy({ $0.finderMetadata?.commentBytes == Data(comment.utf8) }) else { return "Aufnahme5 verliert Finder- oder Kalenderbelege" }
    do { try FileManager.default.removeItem(at: root) } catch { return "Finder-Quellen nicht entfernbar" }
    guard response("openRecording", ["recording": object])["error"] == nil, host.hits.count == 2,
          host.hits.allSatisfy({ $0.finderMetadata?.commentBytes == Data(comment.utf8) }) else { return "Historisches Finder-Öffnen braucht Quellen oder verändert Werte" }
    host.tableView.selectRowIndexes([0], byExtendingSelection: false)
    host.refreshContentPreview()
    guard host.finderMetadataView.textView.string.contains(comment) else { return "Finder-Vorschau verliert Kommentar" }
    host.resultFilter.criteria.applyJSON(CriteriaNode(field: "finderComment", value: "Kommentar Ä").json)
    host.resultFilter.apply()
    guard wait(), host.hits.count == 2, host.resultFilter.unfilteredHits.count == 2 else { return "Finder-Ansichtsfilter verliert eingefrorene Werte" }
    let before = control.run!.id, identities = host.hits.map { $0.identity }
    var old = object; old["schemaVersion"] = 4; old.removeValue(forKey: "finderMetadataCapability")
    guard response("openRecording", ["recording": old])["error"] != nil,
          control.run?.id == before, host.hits.map({ $0.identity }) == identities else { return "Finder-Aufnahme als Altformat teilmutiert" }
    let request: [String: Any] = ["version": 1, "id": UUID().uuidString, "deadline": Date().timeIntervalSince1970 + 8,
        "operation": "openRecording", "runtimeID": control.runtimeID, "windowID": control.windowID, "recording": object]
    let raw = String(decoding: SearchControlWire.encode(request), as: UTF8.self)
    let corrupt = raw.replacingOccurrences(of: "\"color\":6", with: "\"color\":6.0")
    guard corrupt != raw, let rejected = preservedJSONObject(control.handle(Data(corrupt.utf8))) as? [String: Any],
          rejected["error"] != nil, control.run?.id == before, host.hits.map({ $0.identity }) == identities else { return "Aufnahme-Roundtrip repariert ungültiges Integerlexem vor Mutation" }
    let columns = MainController()
    columns.buildWindow()
    if let error = finderColumnsSelfTest(columns) { return error }
    print("FINDER CONTROL OK: file/folder, BOM/NFD/CRLF, dates, recording5, frozen filter, mutation guards")
    return nil
}

func checkLocalContentControl(sandbox: URL) -> String? {
    let folder = sandbox.appendingPathComponent("ap20-local-content")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("eigene lokale Fixture".utf8).write(to: folder.appendingPathComponent("cloud-policy.txt"))
    } catch { return "Lokale Fixture nicht anlegbar" }
    defer { try? FileManager.default.removeItem(at: folder) }
    let host = MainController()
    host.tableView.dataSource = host; host.tableView.delegate = host
    host.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    let control = host.searchControl
    func response(_ operation: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["version": 1, "id": UUID().uuidString,
            "deadline": Date().timeIntervalSince1970 + 8, "operation": operation,
            "runtimeID": control.runtimeID, "windowID": control.windowID]
        value.merge(extra) { _, rhs in rhs }
        return (try? JSONSerialization.jsonObject(with: control.handle(SearchControlWire.encode(value))) as? [String: Any]) ?? [:]
    }
    var options = SearchConfiguration(); options.localOnly = true; options.finderMetadata = true
    let input = ControlSearchInput(pattern: "cloud-policy", root: folder.path, options: options)
    guard input.object["schemaVersion"] as? Int == 5,
          response("configure", ["configuration": input.object])["error"] == nil,
          host.searchConfiguration.localOnly, host.localOnlyContent,
          response("start")["error"] == nil else { return "Lokale Suchpolitik beim Konfigurieren verloren" }
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard host.activeSearchRun == nil, host.hits.count == 1, let run = control.run,
          let object = response("captureRecording", ["runID": run.id])["recording"] as? [String: Any],
          object["schemaVersion"] as? Int == 6,
          SearchControlWire.integer(object["localContentCapability"]) == 1,
          let recording = try? SearchRecording.decode(object, rawData: SearchControlWire.encode(object)),
          recording.input.options.localOnly, recording.input.options.finderMetadata else { return "Aufnahme6 verliert lokale Politik oder Finder-Belege" }
    let before = host.searchConfiguration, runID = control.run!.id
    var oldInput = input.object; oldInput["schemaVersion"] = 4
    var oldRecording = object; oldRecording["schemaVersion"] = 5; oldRecording.removeValue(forKey: "localContentCapability")
    guard response("configure", ["configuration": oldInput])["error"] != nil,
          response("openRecording", ["recording": oldRecording])["error"] != nil,
          host.searchConfiguration == before, control.run?.id == runID else { return "Alte Formate verlieren lokale Politik oder mutieren teilweise" }
    guard response("openRecording", ["recording": object])["error"] == nil,
          host.searchConfiguration.localOnly, host.hits.count == 1 else { return "Lokale Aufnahme nicht wiederherstellbar" }
    print("LOCAL CONTENT CONTROL OK: configuration5, recording6, Finder combination, mutation guards")
    return nil
}

func checkOCRControl(sandbox: URL) -> String? {
    do {
        var options = SearchConfiguration(); options.mode = .document; options.ocr = true
        let input = ControlSearchInput(pattern: "München", root: sandbox.path, options: options)
        guard input.object["schemaVersion"] as? Int == 6,
              try ControlSearchInput.decode(input.object).options.ocr else { return "OCR-Konfiguration verliert Option" }
        let recording = SearchRecording(input: input, runID: UUID().uuidString, startedAt: 1, capturedAt: 2,
            state: "completed", warningCount: 0, error: nil, hits: [], selection: [])
        let data = try JSONSerialization.data(withJSONObject: recording.object)
        guard recording.object["schemaVersion"] as? Int == 7,
              try SearchRecording.decode(recording.object, rawData: data).input.options.ocr else { return "OCR-Aufnahme verliert Option" }
        for version in 1...6 {
            var old = recording.object; old["schemaVersion"] = version
            do { _ = try SearchRecording.decode(old); return "OCR in alter Aufnahme angenommen" }
            catch {}
        }
        var old = input.object; old["schemaVersion"] = 5
        do { _ = try ControlSearchInput.decode(old); return "OCR in alter Konfiguration angenommen" }
        catch {}
        var combined = options; combined.localOnly = true; combined.finderMetadata = true
        let shared = ControlSearchInput(pattern: "München", root: sandbox.path, options: combined)
        let mixed = SearchRecording(input: shared, runID: UUID().uuidString, startedAt: 1, capturedAt: 2,
            state: "completed", warningCount: 0, error: nil, hits: [], selection: [])
        let mixedData = try JSONSerialization.data(withJSONObject: mixed.object)
        let parsed = try SearchRecording.decode(mixed.object, rawData: mixedData)
        guard parsed.input.options.ocr && parsed.input.options.localOnly && parsed.input.options.finderMetadata else { return "Gemischte OCR-/Cloud-/Finder-Aufnahme verliert Option" }
        print("OCR CONTROL OK: configuration 6, recording 7, legacy rejection and combined capabilities")
        return nil
    } catch { return "OCR-Steuerung: \(error)" }
}

func checkPDFOCRControl(sandbox: URL) -> String? {
    do {
        var options = SearchConfiguration(); options.mode = .document; options.pdfOCR = true
        let input = ControlSearchInput(pattern: "München", root: sandbox.path, options: options)
        guard input.object["schemaVersion"] as? Int == 7,
              try ControlSearchInput.decode(input.object).options.pdfOCR else { return "OCR-Konfiguration verliert Option" }
        let recording = SearchRecording(input: input, runID: UUID().uuidString, startedAt: 1, capturedAt: 2,
            state: "completed", warningCount: 0, error: nil, hits: [], selection: [])
        let data = try JSONSerialization.data(withJSONObject: recording.object)
        guard recording.object["schemaVersion"] as? Int == 8,
              try SearchRecording.decode(recording.object, rawData: data).input.options.pdfOCR else { return "OCR-Aufnahme verliert Option" }
        for version in 1...7 {
            var old = recording.object; old["schemaVersion"] = version
            do { _ = try SearchRecording.decode(old); return "OCR in alter Aufnahme angenommen" }
            catch {}
        }
        var old = input.object; old["schemaVersion"] = 6
        do { _ = try ControlSearchInput.decode(old); return "OCR in alter Konfiguration angenommen" }
        catch {}
        var combined = options; combined.ocr = true; combined.localOnly = true; combined.finderMetadata = true
        let shared = ControlSearchInput(pattern: "München", root: sandbox.path, options: combined)
        let mixed = SearchRecording(input: shared, runID: UUID().uuidString, startedAt: 1, capturedAt: 2,
            state: "completed", warningCount: 0, error: nil, hits: [], selection: [])
        let mixedData = try JSONSerialization.data(withJSONObject: mixed.object)
        let parsed = try SearchRecording.decode(mixed.object, rawData: mixedData)
        guard parsed.input.options.pdfOCR && parsed.input.options.ocr && parsed.input.options.localOnly && parsed.input.options.finderMetadata else { return "Gemischte OCR-/Cloud-/Finder-Aufnahme verliert Option" }
        print("PDF OCR CONTROL OK: configuration 7, recording 8, legacy rejection and combined capabilities")
        return nil
    } catch { return "OCR-Steuerung: \(error)" }
}
