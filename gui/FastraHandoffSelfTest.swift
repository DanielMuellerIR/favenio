import AppKit

func checkFastraHandoff(sandbox: URL) -> String? {
    let host = MainController()
    host.tableView.dataSource = host
    host.tableView.delegate = host
    let controller = host.searchControl
    let handoff = controller.handoff
    defer { handoff.cancelPending() }
    let source = sandbox.appendingPathComponent("handoff.txt")
    let first = Data("😀 vor\r\nneedle é\r\n".utf8)
    do { try first.write(to: source) } catch { return "Übergabe-Fixture nicht schreibbar" }
    let normal = Hit(path: source.path, kind: "file", line: 2, size: first.count,
                     filesystemPath: source.path, archiveMembers: [], isDirectory: false)
    let archive = sandbox.appendingPathComponent("handoff.zip")
    let member = "eins!/gleich.txt"
    let archived = Hit(path: archive.path + "!/" + member, kind: "member", line: 2, size: first.count,
                       filesystemPath: archive.path, archiveMembers: [member],
                       archiveMemberBytes: [Data(member.utf8).base64EncodedString()], isDirectory: false)
    func writeArchive(_ data: Data, prefix: Bool = false) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import base64,io,sys,zipfile; b=io.BytesIO(); z=zipfile.ZipFile(b,'w'); z.writestr(sys.argv[2],base64.b64decode(sys.argv[3])); z.close(); f=open(sys.argv[1],'wb'); f.seek(int(sys.argv[4])); f.write(b.getvalue()); f.close()", archive.path, member, data.base64EncodedString(), prefix ? "67108865" : "0"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 } catch { return false }
    }
    guard writeArchive(first) else { return "Archiv-Fixture nicht anlegbar" }
    let input = ControlSearchInput(pattern: "needle", root: sandbox.path, options: SearchConfiguration(mode: .content, archives: true))
    host.replaceSearchResults([normal, archived]); controller.begin(input)
    handoff.ensureApplication = { $0(true) }
    let runtime = UUID().uuidString
    let remoteID = UUID().uuidString
    let sessionID = UUID().uuidString
    let windowID = UUID().uuidString
    let documentID = UUID().uuidString
    var accepted: [String: Any] = [:]
    var leafPath = ""
    var adoptedBytes = Data()
    var supportedEncodings: [String] = []
    var acceptedRequests = 0
    var wrongTextHash = false
    var adopted = true
    var loading = false
    var mismatchedSession = false
    let foreignSessionID = UUID().uuidString
    var closedSessionIDs: [String] = []
    let observedClose = DispatchSemaphore(value: 0)
    let observedAcceptance = DispatchSemaphore(value: 0)
    handoff.send = { bytes, _, _ in
        let request = (try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]) ?? [:]
        var reply: [String: Any] = ["protocolVersion": 1, "runtimeID": runtime]
        switch request["operation"] as? String {
        case "capabilities":
            reply["capabilities"] = ["sourceSnapshotSchemaVersion": 1, "readOnly": true,
                "operations": ["sourceSnapshot"], "maximumSnapshotBytes": 262_144, "maximumOuterArchiveBytes": 67_108_864]
            if !supportedEncodings.isEmpty {
                (reply["capabilities"] as? [String: Any]).map { capabilities in
                    var value = capabilities; value["sourceSnapshotTextEncodings"] = supportedEncodings
                    reply["capabilities"] = value
                }
            }
        case "sourceSnapshot":
            acceptedRequests += 1
            leafPath = request["path"] as? String ?? ""
            adoptedBytes = (try? Data(contentsOf: URL(fileURLWithPath: leafPath))) ?? Data()
            let payload = adoptedBytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(adoptedBytes.dropFirst(3)) : adoptedBytes
            var textHash = FastraHandoffController.hash(payload)
            if let encoding = request["textEncoding"] as? String {
                let encodings: [String: String.Encoding] = ["utf-8": .utf8, "utf-16-le": .utf16LittleEndian,
                    "utf-16-be": .utf16BigEndian, "windows-1252": .windowsCP1252,
                    "iso-8859-1": .isoLatin1, "mac-roman": .macOSRoman]
                var body = adoptedBytes
                if body.starts(with: [0xff, 0xfe]) || body.starts(with: [0xfe, 0xff]) { body = Data(body.dropFirst(2)) }
                let text = String(data: body, encoding: encodings[encoding]!)!
                textHash = FastraHandoffController.hash(Data(text.utf8))
            }
            accepted = ["id": remoteID, "requestID": request["id"]!, "sessionID": sessionID,
                "windowID": windowID, "documentID": documentID, "byteCount": adoptedBytes.count,
                "sha256": request["sha256"]!, "textSHA256": wrongTextHash ? String(repeating: "0", count: 64) : textHash,
                "selection": ["location": request["location"]!, "length": request["length"]!],
                "provenance": request["provenance"]!, "state": "accepted"]
            reply["job"] = accepted
            observedAcceptance.signal()
        case "status":
            var value = accepted; value["state"] = loading ? "loading" : "ready"; value["adopted"] = adopted
            if mismatchedSession { value["sessionID"] = foreignSessionID }
            reply["job"] = value
        case "close":
            if let id = request["sessionID"] as? String { closedSessionIDs.append(id) }
            if request["sessionID"] as? String == sessionID { observedClose.signal() }
        default: break
        }
        return SearchControlWire.encode(reply)
    }
    func wait(_ job: FastraHandoffController.Job) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !job.terminal && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        return job.terminal
    }
    do {
        host.typeControl.segmentCount = 3
        host.fieldPopup.addItem(withTitle: "Alle")
        host.setSearchRoot(sandbox)
        host.searchField.stringValue = ""
        host.applyConfiguration(SearchConfiguration(mode: .content, archives: false, rawFacts: ["min-size": "1"]))
        host.startSearch()
        let filterDeadline = ProcessInfo.processInfo.systemUptime + 10
        while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < filterDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard controller.run?.state == "completed", host.hits.contains(where: { $0.identity == normal.identity }) else {
            return "Reine Filtersuche im Inhaltsmodus liefert keinen echten Treffer"
        }
        let filteredRecording = try SearchRecording.decode(controller.captureRecording())
        for reopen in [false, true] {
            if reopen { try controller.openRecording(filteredRecording) }
            let filtered = try handoff.start(hit: normal, run: controller.run!)
            guard wait(filtered), filtered.state == "ready", adoptedBytes == first,
                  (filtered.receipt?["selection"] as? [String: Int]) == ["location": 0, "length": 0],
                  (filtered.receipt?["provenance"] as? [String: Any])?["positionBinding"] as? String == "unboundHit" else {
                return "Reine Filtersuche kann live oder aufgezeichnet nicht ohne Fundposition übergeben werden (\(filtered.error?.message ?? filtered.state))"
            }
        }
        host.replaceSearchResults([normal, archived]); controller.begin(input)
        let original = try handoff.start(hit: normal, run: controller.run!)
        guard wait(original), original.state == "ready", adoptedBytes == first,
              FileManager.default.fileExists(atPath: source.path),
              (original.receipt?["selection"] as? [String: Int]) == ["location": 8, "length": 9] else {
            return "Originalsnapshot: Hash, UTF-16 oder Übernahmebestätigung falsch (\(original.error?.message ?? original.state))"
        }
        let firstArchive = try handoff.start(hit: archived, run: controller.run!)
        guard wait(firstArchive), firstArchive.state == "ready", adoptedBytes == first,
              !FileManager.default.fileExists(atPath: leafPath),
              (firstArchive.receipt?["provenance"] as? [String: Any])?["archiveBinding"] as? String == "sha256" else {
            return "Archivsnapshot: Herkunft oder Cleanup nach bestätigter eigener Kopie fehlt (\(firstArchive.error?.message ?? firstArchive.state))"
        }
        let later = Data("neu\nneedle jetzt\n".utf8)
        guard writeArchive(later) else { return "Archivänderung nicht schreibbar" }
        let fresh = try handoff.start(hit: archived, run: controller.run!)
        guard wait(fresh), fresh.state == "ready", adoptedBytes == later,
              (fresh.receipt?["selection"] as? [String: Int]) == ["location": 4, "length": 12] else {
            return "Aktuelles Archiv erhält alte Cache-Kopie oder alte Fundposition"
        }
        guard writeArchive(later, prefix: true) else { return "Große Archiv-Fixture nicht schreibbar" }
        let weak = try handoff.start(hit: archived, run: controller.run!)
        guard wait(weak), weak.state == "ready", adoptedBytes == later,
              let provenance = weak.receipt?["provenance"] as? [String: Any],
              provenance["archiveBinding"] as? String == "generation", provenance["outerSHA256"] == nil else {
            return "Große Archive erhalten keine ausdrücklich schwächere Bindung"
        }
        let nestedPath = sandbox.appendingPathComponent("handoff-nested.zip")
        let nestedMember = "innen!/teil.zip"
        let nestedProcess = Process()
        nestedProcess.executableURL = URL(fileURLWithPath: pythonPath)
        nestedProcess.arguments = ["-c", "import base64,io,sys,zipfile; b=io.BytesIO(); z=zipfile.ZipFile(b,'w'); z.writestr(sys.argv[2],base64.b64decode(sys.argv[3])); z.close(); o=zipfile.ZipFile(sys.argv[1],'w'); o.writestr(sys.argv[4],b.getvalue()); o.close()", nestedPath.path, member, later.base64EncodedString(), nestedMember]
        try nestedProcess.run(); nestedProcess.waitUntilExit()
        guard nestedProcess.terminationStatus == 0 else { return "Geschachtelte Fixture nicht schreibbar" }
        let nestedHit = Hit(path: nestedPath.path + "!/" + nestedMember + "!/" + member, kind: "member", line: 2, size: later.count,
                            filesystemPath: nestedPath.path, archiveMembers: [nestedMember, member],
                            archiveMemberBytes: [nestedMember, member].map { Data($0.utf8).base64EncodedString() }, isDirectory: false)
        host.replaceSearchResults([normal, archived, nestedHit])
        let nested = try handoff.start(hit: nestedHit, run: controller.run!)
        guard wait(nested), nested.state == "ready", adoptedBytes == later,
              ((nested.receipt?["provenance"] as? [String: Any])?["hitIdentity"] as? [String: Any])?["archiveMembers"] as? [String] == nestedHit.archiveMembers else {
            return "Geschachtelte Archivkette wird am Anzeigenamen getrennt oder falsch materialisiert"
        }
        let text = "vor\r\nJahresbericht für Köln\r\n"
        for (choice, codec) in [(SearchTextEncoding.automatic, String.Encoding.utf16LittleEndian),
                                (.utf16BE, .utf16BigEndian), (.windows1252, .windowsCP1252),
                                (.latin1, .isoLatin1), (.macRoman, .macOSRoman)] {
            var bytes = text.data(using: codec)!
            if choice == .automatic { bytes = Data([0xff, 0xfe]) + bytes }
            try bytes.write(to: source)
            var options = SearchConfiguration(); options.mode = .content; options.textEncoding = choice
            let encodedInput = ControlSearchInput(pattern: "Jahresbericht", root: sandbox.path, options: options)
            host.replaceSearchResults([normal]); controller.begin(encodedInput)
            let before = acceptedRequests
            let unsupported = try handoff.start(hit: normal, run: controller.run!)
            guard wait(unsupported), unsupported.error?.code == "unsupported", acceptedRequests == before else {
                return "Alter Fastra-Empfänger ignoriert Textkodierung oder mutiert vor Fähigkeitsprüfung"
            }
            supportedEncodings = SearchTextEncoding.allCases.filter { $0 != .automatic }.map { $0.rawValue }
            let encoded = try handoff.start(hit: normal, run: controller.run!)
            guard wait(encoded), encoded.state == "ready", adoptedBytes == bytes,
                  encoded.receipt?["textSHA256"] as? String == FastraHandoffController.hash(Data(text.utf8)),
                  (encoded.receipt?["selection"] as? [String: Int]) == ["location": 5, "length": 22],
                  ((encoded.receipt?["provenance"] as? [String: Any])?["searchEvidence"] as? String)?.contains("verwendet:") == true else {
                return "Gewählte Textkodierung verliert Originalbytes, Texthash oder Auswahl (\(encoded.error?.message ?? encoded.state))"
            }
            wrongTextHash = true
            let wrong = try handoff.start(hit: normal, run: controller.run!)
            guard wait(wrong), wrong.error?.code == "delivery" else { return "Abweichend dekodierter Empfängertext wird bestätigt" }
            wrongTextHash = false; supportedEncodings = []
        }
        try first.write(to: source)
        guard let previewCLI = findCLI() else { return "Vorschaubeleg: Python-Kern fehlt" }
        let previewResult = runSearchSync(arguments: [previewCLI, "--json", "--content-preview", "--content", "needle", source.path])
        guard let previewHit = previewResult.first, previewHit.contentPreview?.status == "ready" else { return "Vorschaubeleg aus Kern fehlt" }
        host.replaceSearchResults([previewHit]); controller.begin(input)
        let previewBound = try handoff.start(hit: previewHit, run: controller.run!)
        guard wait(previewBound), previewBound.state == "ready" else { return "Gebundene Vorschau kann nicht übergeben werden" }
        let acceptedBeforeChange = acceptedRequests
        try later.write(to: source)
        let previewChanged = try handoff.start(hit: previewHit, run: controller.run!)
        guard wait(previewChanged), previewChanged.error?.code == "stale", acceptedRequests == acceptedBeforeChange else {
            return "Geänderte Vorschauquelle erreicht Fastra oder erhält alten Bereich"
        }
        try first.write(to: source)
        guard let freshPreview = runSearchSync(arguments: [previewCLI, "--json", "--content-preview", "--content", "needle", source.path]).first else {
            return "Frischer Vorschaubeleg aus Kern fehlt"
        }
        var wrongDecoder = input.options; wrongDecoder.textEncoding = .macRoman
        host.replaceSearchResults([freshPreview]); controller.begin(ControlSearchInput(pattern: "needle", root: sandbox.path, options: wrongDecoder))
        let mismatchedDecoder = try handoff.start(hit: freshPreview, run: controller.run!)
        guard wait(mismatchedDecoder), mismatchedDecoder.error?.code == "stale", acceptedRequests == acceptedBeforeChange else {
            return "Abweichender Vorschaudecoder erreicht Fastra"
        }
        host.replaceSearchResults([normal, archived, nestedHit]); controller.begin(input)
        adopted = false
        let unconfirmed = try handoff.start(hit: normal, run: controller.run!)
        guard wait(unconfirmed), unconfirmed.state == "failed", unconfirmed.error?.code == "delivery" else {
            return "Unbestätigte eigene Inhaltsübernahme wird als fertig gemeldet"
        }
        guard observedClose.wait(timeout: .now() + 2) == .success else { return "Unbestätigte eigene Fastra-Sitzung wird nicht geschlossen" }
        while observedAcceptance.wait(timeout: .now()) == .success {}
        adopted = true; mismatchedSession = true
        let mismatched = try handoff.start(hit: normal, run: controller.run!)
        guard wait(mismatched), mismatched.state == "failed", mismatched.error?.code == "delivery",
              closedSessionIDs.last == sessionID, !closedSessionIDs.contains(foreignSessionID) else {
            return "Abweichende Statuskennung schließt eine fremde statt der eigenen Fastra-Sitzung"
        }
        mismatchedSession = false
        while observedClose.wait(timeout: .now()) == .success {}
        while observedAcceptance.wait(timeout: .now()) == .success {}
        adopted = true; loading = true
        let cancelled = try handoff.start(hit: normal, run: controller.run!)
        let until = ProcessInfo.processInfo.systemUptime + 5
        var acceptedPending = false
        while !acceptedPending && ProcessInfo.processInfo.systemUptime < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
            acceptedPending = observedAcceptance.wait(timeout: .now()) == .success
        }
        guard acceptedPending else { return "Abbruchprobe erreicht den Empfänger nicht" }
        controller.begin(input)
        guard cancelled.state == "cancelled" else { return "Neuer Suchlauf lässt alte Übergabe weiterlaufen" }
        var shutDown = false
        handoff.shutdown { shutDown = true }
        let shutdownDeadline = ProcessInfo.processInfo.systemUptime + 5.5
        while !shutDown && ProcessInfo.processInfo.systemUptime < shutdownDeadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard shutDown, observedClose.wait(timeout: .now()) == .success else {
            return "App-Ende bestätigt vor der Bereinigung der eigenen unbestätigten Empfängersitzung"
        }
    } catch { return "Übergabe-Selbsttest: \(error)" }
    return nil
}
