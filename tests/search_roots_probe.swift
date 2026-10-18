import AppKit

enum SearchRootsProbe {
    static func run(_ arguments: [String]) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let mode = arguments.dropFirst().first ?? "model"
        let roots = ["/missing/Büro/.", "/missing/Bu\u{0308}ro/", "/missing/file.txt"]
        var report: [String: Bool] = [:]
        switch mode {
        case "model":
            report["rawDistinct"] = SearchRoots.problem(roots) == nil && Set(SearchRoots(roots).bytes).count == 3
            report["duplicateRejected"] = SearchRoots.problem([roots[0], roots[0]]) != nil
            report["invalidRejected"] = [[], ["relative"], ["/a\0b"], Array(repeating: "/x", count: 17), ["/" + String(repeating: "x", count: 4096)]].allSatisfy { SearchRoots.problem($0) != nil }
            report["legacyLong"] = SearchRoots.problem(["/" + String(repeating: "x", count: 5000)], limited: false) == nil
            report["missingExplained"] = SearchRoots(roots).liveProblem?.contains(roots[0]) == true
        case "arguments":
            var options = SearchConfiguration(); options.rawFacts = ["min-size": "0"]
            let args = options.arguments(pattern: "", roots: roots)!
            let start = args.firstIndex(of: "--")!
            report["emptyPatternAndOrder"] = Array(args[(start + 1)...]) == [""] + roots
            report["emptyScopeRejected"] = options.arguments(pattern: "x", roots: []) == nil
            report["legacyOverload"] = options.arguments(pattern: "-dash", root: roots[0]) == options.arguments(pattern: "-dash", roots: [roots[0]])
        case "templates":
            var options = SearchConfiguration(); options.textEncoding = .windows1252
            let source = [SearchTemplate(name: "Mehrere", pattern: "", roots: roots, configuration: options),
                          SearchTemplate(name: "Ohne Bereich", pattern: "x", root: nil, configuration: SearchConfiguration())]
            let data = try SearchTemplateFormat.encode(source)
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            report["roundtrip"] = try SearchTemplateFormat.decode(data) == source
            report["version3"] = object["version"] as? Int == 3
            var entries = object["templates"] as! [[String: Any]]
            entries[0]["roots"] = [roots[0], roots[0]]; object["templates"] = entries
            report["invalidWholeList"] = (try? SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: object))) == nil
            let old = Data(#"{"version":1,"templates":[{"name":"Alt","pattern":"x","root":"/missing/a/.","options":""}]}"#.utf8)
            report["legacyRaw"] = try SearchTemplateFormat.decode(old)[0].roots == ["/missing/a/."]
        case "provenance", "handoff":
            let path = roots[0] + "/folder/a.txt"
            var hit = Hit(path: path, kind: "file", line: 1, size: 3, filesystemPath: path, archiveMembers: [], isDirectory: false)
            let identity = hit.identity
            hit.searchRootBytes = Data(roots[0].utf8)
            report["identityUnchanged"] = identity == hit.identity
            report["roundtripRaw"] = parseHit(jsonlData(for: [hit]))?.searchRootBytes == Data(roots[0].utf8)
            report["ownRelativePath"] = hit.folderText(relativeTo: "/wrong") == "folder"
            report["foreignRejected"] = SearchRoots([roots[1]]).carrying(hit) == nil
            var unknown = hit; unknown.searchRootBytes = nil
            report["missingMultiRejected"] = SearchRoots(roots).carrying(unknown) == nil
            report["knownSingleMigrated"] = SearchRoots([roots[0]]).carrying(unknown)?.searchRootBytes == hit.searchRootBytes
            if mode == "handoff" {
                let file = try writeQuickHandoff([hit], selection: [identity], version: 3, roots: roots)
                let payload = consumeQuickHandoffPayload(file)
                report["v3Payload"] = payload?.version == 3 && payload?.roots?.map { Data($0.utf8) } == SearchRoots(roots).bytes
                report["selectionAndOrigin"] = payload?.selection == [identity] && payload?.hits.first?.searchRootBytes == hit.searchRootBytes
                report["consumed"] = !FileManager.default.fileExists(atPath: file.path)
                report["missingOriginRejected"] = (try? writeQuickHandoff([unknown], version: 3, roots: roots)) == nil
                report["duplicateV3Rejected"] = (try? writeQuickHandoff([hit, hit], version: 3, roots: roots)) == nil
                let legacy = QuickHandoffPayload(hits: [hit], version: 2)
                report["legacyForeignWholeRejected"] = legacy.bound(to: [roots[1]]) == nil
                report["legacyOwnBound"] = legacy.bound(to: [roots[0]])?.hits.first?.searchRootBytes == hit.searchRootBytes
            }
        case "editor":
            let editor = SearchRootsEditor(paths: roots)
            report["missingPreserved"] = editor.paths == roots && editor.applyButton.isEnabled && editor.status.stringValue.contains("fehlt")
            editor.table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            editor.moveSelection(by: -1)
            report["reorder"] = editor.paths.map { Data($0.utf8) } == [roots[0], roots[2], roots[1]].map { Data($0.utf8) }
            report["addDuplicateIgnored"] = editor.addPaths([roots[0]]) == nil && editor.paths.count == 3
            let before = editor.paths
            report["invalidAddAtomic"] = editor.addPaths(["relative"]) != nil && editor.paths == before
            editor.table.selectAll(nil); editor.remove()
            report["emptyDisablesApply"] = editor.paths.isEmpty && !editor.applyButton.isEnabled
            report["backgroundOnly"] = !editor.window.isVisible
            editor.window.close()
            let long = SearchRootsEditor(paths: ["/" + String(repeating: "x", count: 4095)])
            long.window.contentView!.layoutSubtreeIfNeeded()
            report["boundedMissingStatus"] = long.window.contentView!.fittingSize.height < 500
                && long.status.maximumNumberOfLines == 3
            long.window.close()
        default: exit(2)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
