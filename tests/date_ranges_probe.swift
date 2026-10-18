import AppKit

enum DateRangesProbe {
    static func run(_ arguments: [String]) throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let mode = arguments.dropFirst().first ?? "model"
        let question = DateRangeSpec(kind: "relative", timeZone: "Europe/Berlin", preset: "today")
        var source = SearchConfiguration(); source.dateRanges = ["modified": question]
        let frozen = source.forNewRun(reference: "2026-03-29T22:30:00Z")
        var checks: [String: Bool] = [:]
        func proof(_ configuration: SearchConfiguration) throws -> Data {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("favenio-date-probe-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = SearchRunner(); var answer: Data?; var exit: SearchExit?
            runner.start(arguments: ({ () -> [String] in var args = configuration.arguments(pattern: "", roots: [root.path])!; args.insert("--search-report", at: args.firstIndex(of: "--")!); return args })(), onBatch: { _, _ in }, onReport: { report in
                answer = report.object["dateResolution"].flatMap { DateRangeTransport.resolution($0) }
            }, completion: { exit = $0 })
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while exit == nil && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
            guard exit?.reason == .exit, [0, 1].contains(exit?.status ?? 2), let answer else {
                runner.stopForTermination(deadline: ProcessInfo.processInfo.systemUptime + 0.5)
                throw NSError(domain: "DateProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: exit?.errorMessage ?? "Core date proof missing"])
            }
            return answer
        }
        switch mode {
        case "model":
            var node = CriteriaNode(id: "date", field: "modified", matchOperator: "equals"); node.dateRange = question
            checks["criteria2"] = node.json.contains("\"schemaVersion\":2") && CriteriaNode.fromJSON(node.json) == node
            checks["legacyCriteria1"] = CriteriaNode(id: "old", field: "created", matchOperator: "atMost", value: "2026-01-01T00:00Z").json.contains("\"schemaVersion\":1")
            checks["queryRoundtrip"] = SearchConfiguration.fromQueryItems(frozen.queryItems) == frozen
            checks["newRunClock"] = frozen.dateReferenceTime != source.forNewRun(reference: "2026-03-30T22:30:00Z").dateReferenceTime && source.dateReferenceTime == nil
            let args = frozen.arguments(pattern: "", roots: ["/missing"] )!
            checks["oneClockInArguments"] = args.filter { $0.hasPrefix("--date-reference-time=") } == ["--date-reference-time=2026-03-29T22:30:00Z"]
            checks["positiveDateFilter"] = source.hasPositiveFilter && args.contains(where: { $0.hasPrefix("--date-ranges-json=") })
            checks["duplicateEscapedKeyRejected"] = DateRangeTransport.ranges(#"{"schemaVersion":1,"ranges":{"modified":{"kind":"relative","preset":"today","timeZone":"UTC","time\u005aone":"UTC"}}}"#) == nil
            var conflict = frozen.queryItems; conflict.append(URLQueryItem(name: "modified-from", value: "2026-01-01T00:00Z"))
            checks["rawConflictRejected"] = SearchConfiguration.transportProblem(conflict) != nil
        case "templates":
            let templates = [SearchTemplate(name: "Heute", pattern: "", roots: ["/missing"], configuration: frozen)]
            let data = try SearchTemplateFormat.encode(templates)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let decoded = try SearchTemplateFormat.decode(data)
            checks["format4"] = object["version"] as? Int == 4
            checks["questionOnly"] = decoded[0].configuration.dateRanges == source.dateRanges && decoded[0].configuration.dateReferenceTime == nil
            checks["relativeRerun"] = decoded[0].configuration.forNewRun(reference: "2026-03-30T22:30:00Z").dateReferenceTime == "2026-03-30T22:30:00Z"
            var rejected = true
            for version in [1, 2, 3] {
                let entry: [String: Any] = ["name": "bad", "pattern": "", version == 3 ? "roots" : "root": version == 3 ? ["/missing"] as Any : "/missing", "options": SearchTemplateFormat.encodeOptions(source)]
                let old = try JSONSerialization.data(withJSONObject: ["version": version, "templates": [entry]])
                if (try? SearchTemplateFormat.decode(old)) != nil { rejected = false }
            }
            checks["oldFormatsRejectRelative"] = rejected
            var fixed = source; fixed.dateRanges["modified"] = DateRangeSpec(kind: "fixed", timeZone: "Europe/Berlin", lower: "2026-03-28T23:00:00Z", upper: "2026-03-29T21:59:59Z")
            let fixedDecoded = try SearchTemplateFormat.decode(SearchTemplateFormat.encode([SearchTemplate(name: "Fest", pattern: "", roots: nil, configuration: fixed)]))[0]
            checks["fixedQuestionStable"] = fixedDecoded.configuration.forNewRun(reference: "2026-10-25T12:00:00Z").dateRanges == fixed.dateRanges
        case "proof":
            let data = try proof(frozen)
            checks["realCoreBound"] = DateRangeTransport.bound(data, to: frozen)
            checks["clockMismatchRejected"] = !DateRangeTransport.bound(data, to: source.forNewRun(reference: "2026-03-30T22:30:00Z"))
            var different = frozen; different.dateRanges["modified"] = DateRangeSpec(kind: "relative", timeZone: "Europe/Berlin", preset: "thisMonth")
            checks["questionMismatchRejected"] = !DateRangeTransport.bound(data, to: different)
            var object = preservedJSONObject(data) as! [String: Any]
            var entries = object["entries"] as! [[String: Any]]; entries[0]["lowerEpoch"] = true; object["entries"] = entries
            checks["booleanEpochRejected"] = DateRangeTransport.resolution(object) == nil
            object = preservedJSONObject(data) as! [String: Any]; object["referenceTime"] = 0; object["referenceISO"] = "1970-01-01T00:00:00Z"
            checks["referenceInconsistencyRejected"] = DateRangeTransport.resolution(object) == nil
            object = preservedJSONObject(data) as! [String: Any]; entries = object["entries"] as! [[String: Any]]; entries[0]["upperEpoch"] = (entries[0]["lowerEpoch"] as! Double) + 1; object["entries"] = entries
            checks["upperInconsistencyRejected"] = DateRangeTransport.resolution(object) == nil
            var rejectedLineEndings = true
            for suffix in ["\n", "\r\n", "\u{2028}"] {
                object = preservedJSONObject(data) as! [String: Any]; object["referenceISO"] = (object["referenceISO"] as! String) + suffix
                rejectedLineEndings = rejectedLineEndings && !DateRangeTransport.isISO("2026-03-29T00:00:00Z" + suffix) && DateRangeTransport.resolution(object) == nil
            }
            checks["lineEndingRejectedWithoutTrap"] = rejectedLineEndings


            var report = SearchReportSnapshot.pending(configuration: ["truncated": true], state: "recorded"); report.object["dateResolution"] = preservedJSONObject(data)
            checks["visibleHistoricalBounds"] = report.displayText.contains("2026-03-29T22:00:00Z") && report.displayText.contains("Tatsächlich verwendete Kalendergrenzen")
        case "handoff":
            let data = try proof(frozen)
            let root = "/missing/date-probe"
            let hit = Hit(path: root + "/x", kind: "file", line: nil, size: 1, filesystemPath: root + "/x", archiveMembers: [], isDirectory: false, searchRootBytes: Data(root.utf8))
            let file = try writeQuickHandoff([hit], version: 4, roots: [root], configuration: frozen, dateResolution: data)
            let payload = consumeQuickHandoffPayload(file)
            checks["version4Roundtrip"] = payload?.version == 4 && payload?.configuration == frozen && payload?.dateResolution == data && payload?.hits == [hit]
            checks["midnightContinuationClock"] = payload?.configuration?.forNewRun(reference: payload?.configuration?.dateReferenceTime).dateReferenceTime == frozen.dateReferenceTime
            checks["consumedOnce"] = !FileManager.default.fileExists(atPath: file.path) && consumeQuickHandoffPayload(file) == nil
            checks["missingProofRejected"] = (try? writeQuickHandoff([hit], version: 4, roots: [root], configuration: frozen)) == nil
            checks["oldVersionRejectsDate"] = (try? writeQuickHandoff([hit], version: 3, roots: [root], configuration: frozen, dateResolution: data)) == nil
        case "editor":
            let editor = DateRangeEditor(spec: DateRangeSpec(kind: "relative", timeZone: "not/a/zone", preset: "today"), title: "Probe")
            editor.validate()
            func wait(_ test: () -> Bool) -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + 8
                while !test() && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
                return test()
            }
            checks["invalidZoneExplained"] = wait { editor.proofLabel.stringValue.contains("IANA") } && !editor.applyButton.isEnabled
            editor.zone.stringValue = "UTC"; editor.validate()
            checks["corePreview"] = wait { editor.applyButton.isEnabled } && editor.proofLabel.stringValue.contains("Ab:") && editor.proofLabel.stringValue.contains("Bis:")
            checks["relativeIsCompact"] = !editor.from.isEnabled && editor.window.contentView!.bounds.height == 330 && editor.fixedButton.isEnabled
            editor.choice.selectItem(at: 0); editor.validate()
            checks["nativeCalendarClock"] = wait { editor.applyButton.isEnabled } && editor.from.datePickerStyle == .clockAndCalendar && editor.to.isEnabled && !editor.fixedButton.isEnabled
            editor.stopForTermination()
        default: throw NSError(domain: "DateProbe", code: 2)
        }
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
