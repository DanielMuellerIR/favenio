import AppKit

enum ResultGroupingProbe {
    final class LiveOwner: HitListController, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { resultTableRowCount }
    }
    final class HeaderRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let owner: LiveOwner
        init(_ owner: LiveOwner) { self.owner = owner }
        func numberOfRows(in tableView: NSTableView) -> Int { owner.resultTableRowCount }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            owner.resultGrouping.projection.group(at: row) != nil
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            owner.resultGrouping.header(at: row) ?? NSTextField(labelWithString: "normal")
        }
    }
    static func hit(_ path: String, members: [String] = [], bytes: [Data] = [], directory: Bool = false) -> Hit {
        Hit(path: ([path] + members).joined(separator: "!/"), kind: members.isEmpty ? "file" : "member",
            line: nil, size: 5, filesystemPath: path, archiveMembers: members,
            archiveMemberBytes: bytes.map { $0.base64EncodedString() }, isDirectory: directory)
    }
    static func run(_ arguments: [String]) throws {
        let mode = arguments.dropFirst().first ?? "roundtrip"
        var report: [String: Any] = [:]
        switch mode {
        case "header-layout":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let owner = LiveOwner(), table = owner.tableView
            for index in 0..<3 {
                let column = NSTableColumn(identifier: .init("column-\(index)"))
                column.width = 300; table.addTableColumn(column)
            }
            table.columnAutoresizingStyle = .noColumnAutoresizing
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
            scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = false
            scroll.documentView = table
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = scroll
            owner.hits = (0..<20).map { hit("/root/folder-\($0)-" + String(repeating: "long-", count: 100) + "/a.txt") }
            owner.resultGrouping.setMode(.folder)
            let rows = HeaderRows(owner)
            table.dataSource = rows; table.delegate = rows; table.reloadData()
            window.contentView!.layoutSubtreeIfNeeded()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let row = table.rowView(atRow: 0, makeIfNecessary: true)!
            let header = descendants(row).first { $0 is ResultGroupHeaderView }!
            func countVisible(_ name: String) -> Bool {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
                header.layoutSubtreeIfNeeded()
                let count = descendants(header).compactMap { $0 as? NSTextField }.first { $0.stringValue == "1 Treffer" }!
                let frame = count.convert(count.bounds, to: table)
                report[name + "CountFrame"] = NSStringFromRect(frame)
                report[name + "Visible"] = NSStringFromRect(table.visibleRect)
                let right = min(table.visibleRect.maxX, scroll.verticalScroller!.convert(scroll.verticalScroller!.bounds, to: table).minX)
                report[name + "FillsWidth"] = abs(frame.maxX - right) < 1
                return frame.minX >= table.visibleRect.minX && frame.maxX <= right
            }
            report["overlayStyle"] = scroll.scrollerStyle == .overlay
            report["verticalOverflow"] = table.bounds.height > scroll.contentView.bounds.height && scroll.verticalScroller?.isEnabled == true
            report["countVisible"] = countVisible("initial")
            let initialX = scroll.contentView.bounds.minX
            scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            report["clipMoved"] = initialX == 0 && scroll.contentView.bounds.minX == 200
            report["horizontalScroll"] = countVisible("scrolled")
            scroll.setFrameSize(NSSize(width: 380, height: 180))
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
            report["resize"] = countVisible("resized")
            scroll.scrollerStyle = .legacy
            window.contentView!.layoutSubtreeIfNeeded()
            NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
            report["legacyScrollers"] = countVisible("legacy")
            report["compactToolbar"] = owner.resultGrouping.view.fittingSize.width <= 496
            weak var released: NSView?
            autoreleasepool {
                var transient = owner.resultGrouping.header(at: 0)
                let parent = NSView()
                parent.addSubview(transient!)
                transient!.removeFromSuperview()
                released = transient; transient = nil
            }
            report["headerReleased"] = released == nil
            weak var attached: NSView?
            autoreleasepool {
                let parent = NSView()
                var transient = owner.resultGrouping.header(at: 0)
                parent.addSubview(transient!)
                attached = transient; transient = nil
            }
            report["attachedHeaderReleased"] = attached == nil
            report["backgroundOnly"] = !window.isVisible
            window.close()
        case "chain-view":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let long = hit("/root/source!.zip", members: (0..<32).map { "stage-\($0)-" + String(repeating: "x", count: 5000) })
            let alert = makeArchiveChainAlert(for: long)
            alert.layout()
            let scroll = alert.accessoryView as! NSScrollView
            let text = scroll.documentView as! NSTextView
            report["boundedWindow"] = alert.window.frame.height <= NSScreen.main!.visibleFrame.height
                && alert.window.frame.width <= NSScreen.main!.visibleFrame.width
            report["scrollableSelection"] = scroll.hasVerticalScroller && text.isSelectable && !text.isEditable
            report["stages"] = text.string.contains("Archivstufe 31:") && text.string.contains("Treffer: stage-31-")
                && text.string.contains("…") && text.string.utf8.count < 140_000
        case "controller":
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            let owner = LiveOwner()
            owner.tableView.dataSource = owner
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            let error = resultGroupingListSelfTest(owner)
            report["controller"] = error == nil
            if let error { fputs(error + "\n", stderr) }
        case "roundtrip":
            let hits = [hit("/root/b/a.txt"), hit("/root/a/b.TXT"), hit("/root/noext"),
                        hit("/root/d.txt", directory: true), hit("/root/a.zip", members: ["docs/c.txt"])]
            for mode in ResultGroupingMode.allCases {
                let projection = ResultProjection(hits: hits, mode: mode, root: "/root")
                report[mode.rawValue] = projection.displayedHitCount == hits.count
                    && Set((0..<projection.rowCount).compactMap { projection.hitIndex(at: $0) }) == Set(hits.indices)
                    && hits.indices.allSatisfy { projection.tableRow(for: $0).flatMap { projection.hitIndex(at: $0) } == $0 }
                let collapsed = ResultProjection(hits: hits, mode: mode,
                    collapsed: Set(projection.groups.map { $0.key }), root: "/root")
                report[mode.rawValue + "Collapse"] = mode == .none || (collapsed.rowCount == projection.groups.count
                    && collapsed.displayedHitCount == 0 && hits.indices.allSatisfy { collapsed.tableRow(for: $0) == nil })
                report[mode.rawValue + "Headers"] = (0..<projection.rowCount).allSatisfy {
                    projection.group(at: $0) == nil || projection.hitIndex(at: $0) == nil
                }
            }
            let projection = ResultProjection(hits: hits, mode: .fileExtension)
            report["extensionCase"] = projection.groups.first { $0.title == ".txt" }?.hitIndices.count == 3
            report["invalidRows"] = projection.hitIndex(at: -1) == nil && projection.hitIndex(at: 999) == nil
                && projection.tableRow(for: -1) == nil && projection.tableRow(for: 999) == nil
        case "identity":
            let hits = [hit("/root/source.zip", members: ["a.zip!/folder/x.txt"]),
                        hit("/root/source.zip", members: ["a.zip", "folder/x.txt"]),
                        hit("/root/source.zip", members: ["bad-�/x.txt"], bytes: [Data([98,97,100,45,255,47,120,46,116,120,116])]),
                        hit("/root/source.zip", members: ["bad-�/x.txt"], bytes: [Data([98,97,100,45,254,47,120,46,116,120,116])]),
                        hit("/root/source.zip", members: ["é/x.txt"]),
                        hit("/root/source.zip", members: ["e\u{301}/x.txt"]),
                        hit("/root/source.zip", members: ["\u{feff}folder/x.txt"]),
                        hit("/root/source.zip", members: ["folder/x.txt"])]
            let folders = ResultProjection(hits: hits, mode: .folder)
            report["distinctFolders"] = folders.groups.count == hits.count
            report["originalIdentities"] = (0..<folders.rowCount).compactMap { folders.hitIndex(at: $0) }
                .map { hits[$0].identity }.count == Set(hits.map { $0.identity }).count
            let archives = ResultProjection(hits: hits + [hit("/root/outside.txt")], mode: .archive)
            report["structuredOuter"] = archives.groups.count == 2
                && archives.groups.first { $0.key.components == [Data("/root/source.zip".utf8)] }?.hitIndices.count == 8
        case "large":
            let hits = (0..<100_000).map { hit("/root/folder-\($0 % 100)/file-\($0).txt") }
            let start = ProcessInfo.processInfo.systemUptime
            let projection = ResultProjection(hits: hits, mode: .folder, root: "/root")
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            report["fullCount"] = projection.groups.count == 100 && projection.rowCount == 100_100
                && projection.displayedHitCount == 100_000
            report["inverse"] = hits.indices.allSatisfy { projection.tableRow(for: $0).flatMap { projection.hitIndex(at: $0) } == $0 }
            report["seconds"] = elapsed
        default: exit(2)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        if report.values.contains(where: { ($0 as? Bool) == false }) { exit(1) }
    }
}
