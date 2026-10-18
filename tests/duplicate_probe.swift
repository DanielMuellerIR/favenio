import AppKit
import Darwin
import Quartz

private func duplicateRequire(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw NSError(domain: "DuplicateProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func duplicateWait(_ condition: () -> Bool) throws {
    let until = Date().addingTimeInterval(12)
    while !condition(), Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try duplicateRequire(condition(), "Timeout")
}
struct DuplicateProbe {
    static func archiveScenario(_ root: URL) throws {
        let fixtures = root.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
        let python = Process(), pipe = Pipe(), errors = Pipe()
        python.executableURL = URL(fileURLWithPath: pythonPath)
        python.arguments = ["-c", """
import gzip,io,pathlib,sys,tarfile,zipfile
r=pathlib.Path(sys.argv[1]);(r/'normal').write_bytes(b'alpha')
inner=io.BytesIO()
with zipfile.ZipFile(inner,'w',zipfile.ZIP_STORED) as z:z.writestr('deep',b'alpha')
with zipfile.ZipFile(r/'own.zip','w',zipfile.ZIP_STORED) as z:
 z.writestr('name!/member',b'alpha');z.writestr('inner.zip',inner.getvalue())
with tarfile.open(r/'own.tar','w',format=tarfile.GNU_FORMAT,encoding='utf-8',errors='surrogateescape') as t:
 for name,data in [('normal-tar',b'alpha'),(b'bad\\x80'.decode('utf-8','surrogateescape'),b'alpha'),(b'bad\\x81'.decode('utf-8','surrogateescape'),b'bravo')]:
  i=tarfile.TarInfo(name);i.size=len(data);t.addfile(i,io.BytesIO(data))
with gzip.open(r/'single.gz','wb') as g:g.write(b'alpha')
for name in ['broken.zip','limited.zip']:
 with zipfile.ZipFile(r/name,'w',zipfile.ZIP_STORED) as z:z.writestr('crc',b'alpha')
p=r/'broken.zip';b=bytearray(p.read_bytes());b[33]^=1;p.write_bytes(b)
""", fixtures.path]
        python.standardOutput = pipe; python.standardError = errors
        try python.run(); python.waitUntilExit()
        try duplicateRequire(python.terminationStatus == 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let search = Process(), output = Pipe()
        search.executableURL = URL(fileURLWithPath: pythonPath)
        search.arguments = [findCLI()!, "--json", "--archive-depth", "3", "*", fixtures.path]
        search.standardOutput = output; search.standardError = FileHandle.nullDevice
        try search.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); search.waitUntilExit()
        var objects = data.split(separator: 10).compactMap { parseHit(Data($0)) }.filter { !$0.isDirectory && ($0.isMember || ["normal", "own.zip"].contains($0.displayName)) }
        try duplicateRequire(objects.contains { $0.isMember && $0.filesystemPath.hasSuffix("single.gz") && $0.size == nil }, "Unbekannte Kataloggröße fehlt")
        let bad = objects.filter { $0.archiveMembers.last == "bad�" }
        try duplicateRequire(bad.count == 2 && Set(bad.map { $0.identity }).count == 2, "Rohnamen zusammengeführt")
        for index in objects.indices where objects[index].filesystemPath.hasSuffix("limited.zip") {
            objects[index].contentPreview = ContentPreview(status: "none", sourceGeneration: nil, encoding: nil, snippets: [], omitted: nil,
                archiveLimits: ContentPreviewArchiveLimits(memberBytes: 4, totalBytes: 16, ratio: 1000))
        }
        let manager = MaterializationManager(); manager.temporaryDirectory = root.appendingPathComponent("materializations")
        try FileManager.default.createDirectory(at: manager.temporaryDirectory, withIntermediateDirectories: false)
        let sharedIndex = objects.firstIndex { $0.archiveMembers == ["name!/member"] }!
        var openedURL: URL?
        _ = manager.request(objects[sharedIndex]) { if case .ready(let url) = $0 { openedURL = url } }
        let operation = DuplicateJob(materializer: manager)
        var outcome: Result<DuplicateResult, Error>?
        operation.run(hits: objects, localOnly: false, progress: { _ in }, completion: { outcome = $0 })
        try duplicateWait { outcome != nil && openedURL != nil }
        let result = try outcome!.get()
        try duplicateRequire(result.state == "partial" && result.issueCount == 2 && result.groups.count == 1, "Archivfehler/Budget/Teilgruppe: \(result.state) \(result.issueCount) \(result.groups.count)")
        try duplicateRequire(result.groups[0].memberIDs.count == 6, "Datei/ZIP/Tar/Gzip/verschachtelte Gruppe unvollständig")
        try duplicateRequire(result.files[String(sharedIndex)]?.sourceGeneration == ContentSourceGeneration.current(openedURL!.path)?.json, "Paralleles Öffnen und Prüfung verwenden verschiedene Dateien")
        let expected = Set(result.groups[0].memberIDs.compactMap(Int.init).map { objects[$0].identity })
        let controller = DuplicateResultsController(); _ = controller.makeTable(); controller.accept(result, originals: objects)
        try duplicateRequire(Set(controller.hits.map { $0.identity }) == expected, "Originalidentität in Dublettengruppen verändert")
        let exported = jsonlData(for: controller.hits).split(separator: 10).compactMap { parseHit(Data($0)) }
        try duplicateRequire(Set(exported.map { $0.identity }) == expected, "Export verändert Archividentitäten")
        let sharedHit = controller.hits.first { $0.identity == objects[sharedIndex].identity }!
        try duplicateRequire(manager.knownURL(for: sharedHit) == openedURL, "Öffnen der Ergebnisgruppe verliert die gemeinsame Datei")
        let normal = objects.first { !$0.isMember && $0.displayName == "normal" }!
        let cachedOperation = DuplicateJob(materializer: manager)
        var firstPreparedBytes: Int64?, cachedResult: Result<DuplicateResult, Error>?
        cachedOperation.run(hits: [normal, sharedHit], localOnly: false, progress: { value in
            if value.phase == "materialize" && firstPreparedBytes == nil { firstPreparedBytes = value.readBytes }
        }, completion: { cachedResult = $0 })
        Thread.sleep(forTimeInterval: 0.1)
        try duplicateWait { cachedResult != nil && firstPreparedBytes != nil }
        try duplicateRequire(firstPreparedBytes == 0, "Fortschrittsframe liest spätere Vorbereitungsmutationen")
        let cachedGroups = try cachedResult!.get().groups.count
        try duplicateRequire(cachedGroups == 1, "Cachevergleich fehlt")
        try duplicateRequire(controller.hits.contains { $0.archiveMemberBytes.last == Data([98,97,100,128]).base64EncodedString() }, "Falscher Rohname bestätigt")
        try duplicateRequire(!controller.hits.contains { !$0.isMember && $0.filesystemPath.hasSuffix("own.zip") }, "Container mit seinem Inhalt verwechselt")
        var localResult: Result<DuplicateResult, Error>?
        let localOperation = DuplicateJob(materializer: manager)
        localOperation.run(hits: [normal, sharedHit], localOnly: true, progress: { _ in }, completion: { localResult = $0 })
        try duplicateWait { localResult != nil }
        let localGroups = try localResult!.get().groups.count
        try duplicateRequire(localGroups == 1, "Lokaler Archivvortest verliert vorhandenen Inhalt")
        manager.cleanup()
        try duplicateWait { !FileManager.default.fileExists(atPath: openedURL!.path) }

        let slowFolder = root.appendingPathComponent("slow-materialization")
        try FileManager.default.createDirectory(at: slowFolder, withIntermediateDirectories: false)
        let slowScript = slowFolder.appendingPathComponent("slow.py")
        try Data("import os,pathlib,sys,time\nr=pathlib.Path(sys.argv[sys.argv.index('--extract-root')+1]);(r.parent/'materializing.pid').write_text(str(os.getpid()))\ntime.sleep(30)\n".utf8).write(to: slowScript)
        let slow = MaterializationManager(); slow.cliPath = slowScript.path; slow.temporaryDirectory = slowFolder
        let cancelled = DuplicateJob(materializer: slow); var late = false
        cancelled.run(hits: [objects[sharedIndex]], localOnly: false, progress: { _ in }, completion: { _ in late = true })
        let pidFile = slowFolder.appendingPathComponent("materializing.pid")
        var pid: Int32?
        try duplicateWait { pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init); return pid != nil }
        cancelled.cancel()
        try duplicateWait { kill(pid!, 0) != 0 && errno == ESRCH }
        try duplicateRequire(!late, "Ergebnis nach Materialisierungsabbruch")
        slow.cleanup()
        let blockedFolder = root.appendingPathComponent("blocked-materialization")
        try FileManager.default.createDirectory(at: blockedFolder, withIntermediateDirectories: false)
        let blocked = MaterializationManager(); blocked.cliPath = slowScript.path; blocked.temporaryDirectory = blockedFolder
        let missing = root.appendingPathComponent("missing-archive.zip")
        let missingHit = Hit(path: missing.path + "!/item", kind: "member", line: nil, size: nil, filesystemPath: missing.path, archiveMembers: ["item"], isDirectory: false)
        let copyURL = root.appendingPathComponent("guard-copy"); try Data("alpha".utf8).write(to: copyURL)
        let copy = Hit(path: copyURL.path, kind: "file", line: nil, size: nil, filesystemPath: copyURL.path, archiveMembers: [], isDirectory: false)
        let gated = DuplicateJob(materializer: blocked); var gatedResult: Result<DuplicateResult, Error>?
        gated.run(hits: [normal, copy, missingHit], localOnly: true, progress: { _ in }, completion: { gatedResult = $0 })
        try duplicateWait { gatedResult != nil }
        let gatedProof = try gatedResult!.get()
        try duplicateRequire(gatedProof.state == "partial" && gatedProof.groups.count == 1, "Lokaler Vortest verliert bekannte Teilgruppe")
        try duplicateRequire(!FileManager.default.fileExists(atPath: blockedFolder.appendingPathComponent("materializing.pid").path), "Nicht lokale/unbekannte Wurzel startete gemeinsamen Materialisierer")
        blocked.cleanup()
    }

    static func run(_ arguments: [String]) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: arguments[1])
        func hit(_ name: String, _ data: Data) throws -> Hit {
            let url = root.appendingPathComponent(name); try data.write(to: url)
            return Hit(path: url.path, kind: "file", line: nil, size: nil, filesystemPath: url.path, archiveMembers: [], isDirectory: false)
        }
        let a = try hit("alpha", Data("alpha".utf8)), b = try hit("copy", Data("alpha".utf8)), c = try hit("different", Data("bravo".utf8))
        let owner = HitListController()
        owner.window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.window.isReleasedWhenClosed = false; owner.hits = [a, b, c]
        let controller = owner.duplicateCheckController
        controller.buildWindow(owner: owner); controller.results.window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        controller.results.window.orderFront(nil)
        defer { controller.cancel(); controller.results.window.close(); owner.window.close() }
        try duplicateRequire(!controller.results.window.isKeyWindow, "Test hat Fokus übernommen")
        controller.prepareSnapshot(); owner.hits = []
        try duplicateRequire(controller.scopeNote.stringValue.contains("3 Objekte"), "Menge nicht festgehalten")
        controller.begin()
        try duplicateWait { controller.job == nil }
        try duplicateRequire(controller.status.stringValue.hasPrefix("Abgeschlossen: 1"), controller.status.stringValue + (controller.status.toolTip ?? ""))
        try duplicateRequire(controller.results.hits.count == 2 && controller.results.resultTableRowCount == 3, "Gruppenprojektion")
        let header = controller.results.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        try duplicateRequire(header?.textField?.stringValue.hasPrefix("Gruppe 1") == true, "Native Gruppenüberschrift fehlt bei nil-Spalte")
        try duplicateRequire(controller.results.hitIndex(forTableRow: 0) == nil && controller.results.hitIndex(forTableRow: 1) == 0, "Kopf ist keine Datei")
        controller.results.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try duplicateRequire(controller.results.selectedHitIndices == [0], "Auswahl mapping")
        let previewPanel = QLPreviewPanel.shared()!
        previewPanel.dataSource = controller.results
        try duplicateRequire(!owner.acceptsPreviewPanelControl(previewPanel), "App-Delegate übernimmt fremde Dublettenvorschau")
        owner.beginPreviewPanelControl(previewPanel)
        try duplicateRequire(previewPanel.dataSource === controller.results, "Fremde beginPreviewPanelControl überschreibt Datenquelle")
        try duplicateRequire(controller.results.acceptsPreviewPanelControl(previewPanel), "Eigener Vorschaucontroller wird abgewiesen")
        previewPanel.dataSource = nil

        let first = controller.results.tableView.rect(ofRow: 1)
        try duplicateRequire(first.height >= 40, "Dateizeile zu niedrig")
        let decoded = try JSONDecoder().decode(DuplicateResult.self, from: JSONSerialization.data(withJSONObject: [
            "type":"duplicateResult", "schemaVersion":1, "state":"completed", "complete":true,
            "checkedAt":"2026-10-18T15:00:00Z", "scopeCount":2, "hashedFiles":2, "readBytes":20,
            "groups":[["id":"1","memberIDs":["0","0"],"sha256":String(repeating:"a",count:64),"size":5,"physicalFiles":1,"byteVerified":true]],
            "files":["0":["sourceGeneration":ContentSourceGeneration.current(a.filesystemPath)!.json,"size":5,"linkKind":"regular","linkCount":1]],
            "issueCount":0,"issues":[]]))
        try duplicateRequire(!decoded.validate(ids: ["0","1"]), "Doppelte Belegidentität akzeptiert")
        try archiveScenario(root)
        var large: [Hit] = []
        for name in ["large-a", "large-b"] {
            let item = try hit(name, Data()); let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: item.filesystemPath))
            try handle.truncate(atOffset: 4 * 1024 * 1024 * 1024); try handle.close(); large.append(item)
        }
        let job = DuplicateJob(); var cancellationStarted = false, called = false, wasRunningBeforeCancel = false
        job.run(hits: large, localOnly: false, progress: { value in
            if value.phase == "hash" { wasRunningBeforeCancel = job.activePID != nil; cancellationStarted = true; job.cancel() }
        }, completion: { _ in called = true })
        try duplicateWait { cancellationStarted && job.activePID == nil }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try duplicateRequire(wasRunningBeforeCancel, "Fortschritt kam erst nach Prozessende")
        try duplicateRequire(!called, "Spätes Ergebnis nach Abbruch")
        controller.cancel(); try duplicateRequire(controller.results.hits.isEmpty, "Altes Ergebnis nach Abbruch")
        print("{\"passed\":true,\"frozenScope\":true,\"verifiedGroups\":1,\"cancelledChildReaped\":true,\"lateResultIgnored\":true}")
    }
}
