import AppKit

enum ContentPreviewProbe {
    final class Rows: NSObject, NSTableViewDataSource {
        let owner: HitListController
        init(_ owner: HitListController) { self.owner = owner }
        func numberOfRows(in tableView: NSTableView) -> Int { owner.hits.count }
    }

    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func run(_ arguments: [String]) throws {
        _ = NSApplication.shared
        defer { MaterializationManager.shared.cleanup() }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let lines: [Data] = data.split(separator: 10)
        let hits = lines.compactMap(parseHit)
        guard !hits.isEmpty else { exit(2) }
        let mode = arguments.dropFirst().first ?? "parse"
        var report: [String: Any] = [:]
        if mode == "parse" {
            report["hitStride"] = MemoryLayout<Hit>.stride
            report["previewStorageBytes"] = MemoryLayout<ContentPreview?>.size
            let first = hits[0]
            let preview = first.contentPreview
            report["status"] = preview?.status ?? "missing"
            report["requestedEncoding"] = preview?.snippets.first?.query?.encoding ?? "missing"
            report["roundtrip"] = parseHit(jsonlData(for: [first]).prefix(while: { $0 != 10 })) == first
            report["same_generation"] = preview?.sourceGeneration == ContentSourceGeneration.current(first.filesystemPath)
            if let preview, preview.status == "ready" {
                let view = ContentPreviewView()
                view.render(preview, hit: first)
                report["rendered"] = view.textView.string
                var marks: [String] = []
                view.textView.textStorage?.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: view.textView.string.utf16.count)) { value, range, _ in
                    if value != nil { marks.append((view.textView.string as NSString).substring(with: range)) }
                }
                report["marks"] = marks
            }
        } else if mode == "layout" {
            let view = ContentPreviewView()
            view.toggle.state = .on; view.syncVisibility(); view.compact()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor)])
            view.show("Quellstand geprüft", source: "/archive.zip!/" + String(repeating: "x", count: 5000))
            content.layoutSubtreeIfNeeded()
            report["compactWidth"] = window.frame.width <= 520 && view.frame.width <= 520
            report["sourceRetained"] = view.sourceLabel.stringValue.utf8.count > 5000 && view.sourceLabel.toolTip == view.sourceLabel.stringValue
            report["fittingWidth"] = view.fittingSize.width
            window.close()
        } else if ["pdf", "docx", "odt", "epub", "xlsx", "xlsx-unavailable", "pptx"].contains(mode) {
            let docx = mode != "pdf"
            let initial = mode == "pptx" ? "Folie 1 · Objekt 2 · Absatz 1 · Zeile 1" : mode.hasPrefix("xlsx") ? "Blatt 1 „Übersicht“ · Zelle A1 · Text · Zeile 1" : mode == "epub" ? "Kapitel 1 (OPS/z.xhtml) · Absatz 1 · Zeile 1" : mode == "odt" ? "ODT-Haupttext · Absatz 1 · Zeile 1" : docx ? "Haupttext · Absatz 1 · Zeile 1" : "Seite 1 · Zeile 1"
            let next = mode == "pptx" ? "Folie 1 · Tabelle 3 · Zelle 1,1 · Absatz 1 · Zeile 1" : mode.hasPrefix("xlsx") ? "Blatt 1 „Übersicht“ · Zelle A3 · Text · Zeile 1" : mode == "epub" ? "Kapitel 2 (OPS/a.xhtml) · Absatz 1 · Zeile 1" : mode == "odt" ? "ODT-Haupttext · Absatz 3 · Zeile 1" : docx ? "Haupttext · Absatz 3 · Zeile 1" : "Seite 3 · Zeile 1"
            let context = mode == "pptx" ? "Kontext · Folie 1 · Objekt 2 · Absatz 2" : mode.hasPrefix("xlsx") ? "Kontext · Blatt 1 „Übersicht“ · Zelle A2" : mode == "epub" ? "Kontext · Kapitel 1 (OPS/z.xhtml) · Absatz 2" : mode == "odt" ? "Kontext · ODT-Haupttext · Absatz 2" : docx ? "Kontext · Haupttext · Absatz 2" : "Kontext · Seite 2"
            let first = hits[0]
            if docx, var nfc = first.documentPosition, var nfd = first.documentPosition {
                nfc.part = "word/Büro.xml"; nfd.part = "word/Bu\u{0308}ro.xml"
                report["partByteIdentity"] = nfc != nfd && Set([nfc, nfd]).count == 2
            }
            if mode.hasPrefix("xlsx"), var nfc = first.documentPosition, var nfd = first.documentPosition {
                nfc.sheet = "Büro"; nfd.sheet = "Bu\u{0308}ro"
                report["sheetByteIdentity"] = nfc != nfd && Set([nfc, nfd]).count == 2
            }
            report["roundtrip"] = parseHit(jsonlData(for: [first]).prefix(while: { $0 != 10 })) == first
            report["positionExport"] = (mode.hasPrefix("xlsx") ? first.documentPosition?.cell == "A1" : docx ? first.documentPosition?.paragraph == 1 : first.documentPosition?.page == 1) && first.documentSourceGeneration != nil
            report["location"] = first.locationText.contains(initial)
            let csv = String(decoding: exportData(for: [first], format: .csv), as: UTF8.self)
            report["csv"] = csv.contains("documentPage,documentLine,documentPart,documentPartKind,documentParagraph") && csv.contains(mode == "pptx" ? "pptx-text-v1,,1,ppt/slides/z.xml,,1,,,,,,1,2,shape,," : mode.hasPrefix("xlsx") ? "xlsx-text-v1,,1,xl/worksheets/z.xml,,,,Übersicht,1,A1,text" : mode == "epub" ? "epub-text-v1,,1,OPS/z.xhtml,,1,1" : mode == "odt" ? "odt-text-v1,,1,content.xml,,1," : docx ? "docx-text-v1,,1,word/document.xml,document,1" : "pdfkit-text-v1,1,1")
            var config = SearchConfiguration(); config.mode = .document
            report["configuration"] = config.arguments(pattern: "needle", root: first.filesystemPath)?.contains("--document-text") == true && SearchConfiguration.fromQueryItems(config.queryItems).mode == .document && config.requiresTransportVersion2
            let owner = HitListController(); owner.hits = hits
            let rows = Rows(owner); owner.tableView.dataSource = rows
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            owner.tableView.reloadData(); owner.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let controller = owner.contentPreviewController; controller.cliPath = arguments.last
            controller.view.toggle.state = .on; controller.view.syncVisibility(); controller.selectionChanged(force: true)
            report["initial"] = wait { controller.view.textView.string.contains(initial) && controller.view.nextButton.isEnabled }
            if mode == "xlsx-unavailable" {
                controller.view.nextButton.performClick(nil)
                report["unavailable"] = wait { !controller.isLoading && controller.view.statusLabel.stringValue.hasPrefix("Dokument nicht nachladbar:") && controller.view.textView.string.contains(initial) }
            } else {
            controller.view.nextButton.performClick(nil)
            report["next"] = wait { !controller.isLoading && controller.view.textView.string.contains(next) }
            controller.view.previousButton.performClick(nil)
            report["previous"] = wait { !controller.isLoading && controller.view.textView.string.contains(initial) }
            controller.view.contextButton.performClick(nil)
            report["context"] = wait { !controller.isLoading && controller.view.textView.string.contains(context) }
            controller.view.nextButton.performClick(nil); controller.view.toggle.performClick(nil)
            report["offCancels"] = !controller.isLoading && controller.view.textView.string.isEmpty
            }
            withExtendedLifetime(rows) {}
        } else if mode == "cancel-load" {
            let owner = HitListController(); owner.hits = hits
            let rows = Rows(owner); owner.tableView.dataSource = rows
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            owner.tableView.reloadData(); owner.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let controller = owner.contentPreviewController
            let wrapper = arguments.last!; controller.cliPath = wrapper
            let marker = wrapper + ".pid"
            controller.view.toggle.state = .on; controller.view.syncVisibility(); controller.selectionChanged(force: true)
            func start() -> pid_t? {
                try? FileManager.default.removeItem(atPath: marker)
                guard wait({ !controller.view.navigationBar.isHidden }) else { return nil }
                controller.view.nextButton.performClick(nil)
                var startedPID: pid_t?
                guard wait({
                    guard let text = try? String(contentsOfFile: marker, encoding: .utf8), let pid = Int32(text), kill(pid, 0) == 0 else { return false }
                    startedPID = pid; return true
                }) else { return nil }
                return startedPID
            }
            func gone(_ pid: pid_t?) -> Bool { guard let pid else { return false }; return wait { kill(pid, 0) != 0 } }
            var pid = start(); report["escapeKilled"] = owner.cancelMaterializations() && gone(pid)
            pid = start(); controller.view.toggle.performClick(nil)
            report["offKilled"] = gone(pid) && !controller.isLoading && controller.view.textView.string.isEmpty
            controller.view.toggle.performClick(nil)
            pid = start(); controller.view.cancelButton.performClick(nil)
            report["buttonKilled"] = gone(pid) && !controller.isLoading
            pid = start()
            owner.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false); controller.selectionChanged()
            report["selectionKilled"] = gone(pid) && !controller.isLoading
            pid = start()
            let deadline = Date().addingTimeInterval(6)
            while controller.isLoading, Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            report["timeoutKilled"] = gone(pid) && !controller.isLoading && controller.view.statusLabel.stringValue.contains("fünf Sekunden")
            pid = start()
            try Data("changed source".utf8).write(to: URL(fileURLWithPath: hits[1].filesystemPath))
            report["sourceKilled"] = gone(pid) && controller.view.textView.string.isEmpty
            withExtendedLifetime(rows) {}
        } else if mode == "navigate" {
            let owner = HitListController(); owner.hits = hits
            let rows = Rows(owner); owner.tableView.dataSource = rows
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            owner.tableView.reloadData(); owner.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let controller = owner.contentPreviewController
            controller.cliPath = arguments.last
            controller.view.toggle.state = .on; controller.view.syncVisibility(); controller.selectionChanged(force: true)
            report["initial"] = wait { !controller.view.navigationBar.isHidden && controller.view.nextButton.isEnabled && controller.view.textView.string.contains("Zeile 1") }
            controller.view.nextButton.performClick(nil)
            report["next"] = wait { !controller.isLoading && controller.view.textView.string.contains("Zeile 3") }
            controller.view.previousButton.performClick(nil)
            report["previous"] = wait { !controller.isLoading && controller.view.textView.string.contains("Zeile 1") }
            controller.view.contextButton.performClick(nil)
            report["context"] = wait { !controller.isLoading && controller.view.textView.string.contains("Kontext · Zeile 2") }
            controller.view.nextButton.performClick(nil)
            controller.view.toggle.performClick(nil)
            report["offCancels"] = !controller.isLoading && controller.view.textView.string.isEmpty
            controller.view.toggle.performClick(nil)
            _ = wait { !controller.view.navigationBar.isHidden && controller.view.nextButton.isEnabled && controller.view.textView.string.contains("Zeile 1") }
            controller.view.nextButton.performClick(nil)
            controller.cancelLoad(message: "Nachladen abgebrochen.")
            report["cancel"] = !controller.isLoading && controller.view.statusLabel.stringValue.contains("abgebrochen")
            if hits.count > 1 {
                controller.view.nextButton.performClick(nil)
                owner.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
                controller.selectionChanged()
                report["selectionCancels"] = !controller.isLoading && wait { controller.view.sourceLabel.stringValue == hits[1].path }
            }
            try Data("changed source".utf8).write(to: URL(fileURLWithPath: hits.last!.filesystemPath))
            report["changeClears"] = wait { controller.view.statusLabel.stringValue.contains("verändert") && controller.view.textView.string.isEmpty }
            withExtendedLifetime(rows) {}
        } else {
            guard hits.count == 2 else { exit(2) }
            let owner = HitListController()
            owner.hits = hits
            let rows = Rows(owner)
            owner.tableView.dataSource = rows
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            owner.tableView.reloadData()
            let controller = owner.contentPreviewController
            controller.view.toggle.state = .on; controller.view.syncVisibility()
            for index in 0..<200 {
                owner.tableView.selectRowIndexes(IndexSet(integer: index % 2), byExtendingSelection: false)
                owner.refreshContentPreview()
            }
            report["latest_selection"] = wait { controller.view.textView.string.contains("second needle") }
            report["no_old_text"] = !controller.view.textView.string.contains("first needle")
            controller.view.textView.setSelectedRange(NSRange(location: 0, length: 1))
            let deadline = Date().addingTimeInterval(1.2)
            while Date() < deadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            report["selection_preserved"] = controller.view.textView.selectedRange() == NSRange(location: 0, length: 1)
            try Data("changed source".utf8).write(to: URL(fileURLWithPath: hits[1].filesystemPath))
            report["changed_source"] = wait { controller.view.statusLabel.stringValue.contains("verändert") }
            report["changed_text_cleared"] = controller.view.textView.string.isEmpty
            owner.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            owner.refreshContentPreview()
            controller.view.toggle.state = .off; controller.view.syncVisibility(); controller.selectionChanged(force: true)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            report["hidden_cancels"] = controller.view.body.isHidden && controller.view.textView.string.isEmpty
            report["off_arguments"] = owner.contentPreviewArguments(["cli", "--json"]) == ["cli", "--json"]
            controller.view.toggle.state = .on
            report["on_arguments"] = owner.contentPreviewArguments(["cli", "--json"]) == ["cli", "--json", "--content-preview"]
            if let arguments = SearchConfiguration(mode: .content).arguments(pattern: "needle", root: hits[0].filesystemPath) {
                report["real_arguments"] = runSearchSync(arguments: owner.contentPreviewArguments(arguments)).first?.contentPreview?.status == "ready"
            } else { report["real_arguments"] = false }
            withExtendedLifetime(rows) {}
        }
        let output = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        FileHandle.standardOutput.write(output)
    }
}
