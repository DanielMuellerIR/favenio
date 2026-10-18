import AppKit
import Quartz

enum ResultFilterProbe {
    final class QuickSelectionOwner: HitListController, NSTableViewDataSource, NSTableViewDelegate {
        func numberOfRows(in tableView: NSTableView) -> Int { resultTableRowCount }
        // Die Methoden stammen beim Testbuild unverändert aus Quick.
        /* QUICK_FILTER_RELOAD */
        /* QUICK_FILTER_SELECTION */
    }
    final class Rows: NSObject, NSTableViewDataSource {
        let owner: HitListController
        init(_ owner: HitListController) { self.owner = owner }
        func numberOfRows(in tableView: NSTableView) -> Int { owner.hits.count }
    }
    static func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
    static func run(_ arguments: [String]) throws {
        _ = NSApplication.shared
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let hits = input.split(separator: 10).compactMap { parseHit(Data($0)) }
        if arguments.dropFirst().first?.hasPrefix("quick-selection") == true {
            precondition(hits.count == 1)
            let owner = QuickSelectionOwner()
            owner.contentPreviewController.cliPath = arguments.last
            owner.tableView.dataSource = owner
            owner.tableView.delegate = owner
            owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
            owner.contentPreviewView.toggle.state = .on
            owner.contentPreviewView.syncVisibility()
            owner.hits = hits
            owner.tableView.reloadData()
            if arguments.dropFirst().first == "quick-selection-grouped" { owner.resultGrouping.setMode(.folder) }
            owner.tableView.selectRowIndexes(owner.tableRows(for: [hits[0].identity]), byExtendingSelection: false)
            owner.refreshContentPreview()
            let initial = wait { !owner.contentPreviewController.isLoading
                && owner.contentPreviewView.textView.string.contains("Zeile 1")
                && owner.contentPreviewView.nextButton.isEnabled }
            owner.contentPreviewView.nextButton.performClick(nil)
            let next = wait { !owner.contentPreviewController.isLoading && owner.contentPreviewView.textView.string.contains("Zeile 3") }
            owner.hits.append(Hit(path: "/missing/other.txt", kind: "file", line: nil, size: 0,
                filesystemPath: "/missing/other.txt", archiveMembers: [], isDirectory: false))
            owner.reloadKeepingSelection([hits[0].identity])
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let report = ["initial": initial, "next": next,
                "sameSelection": owner.selectedHitIdentities() == [hits[0].identity],
                "navigationRetained": owner.contentPreviewView.textView.string.contains("Zeile 3")]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self))
            if report.values.contains(false) { exit(1) }
            return
        }
        precondition(hits.count == 4)
        let owner = HitListController()
        let rows = Rows(owner)
        owner.tableView.dataSource = rows
        owner.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
        owner.replaceFilteredHits(hits, keepingSelection: [hits[0].identity])
        let filter = owner.resultFilter
        func apply(_ value: String, field: String = "name") {
            filter.criteria.applyJSON(CriteriaNode(field: field, value: value).json)
            filter.apply()
        }
        var result: [String: Bool] = [:]
        apply("keep-")
        result["initialCleared"] = owner.hits.isEmpty && filter.sourceCount == 4
        result["initial"] = wait { !filter.isFiltering } && owner.hits == [hits[0], hits[2]]
        result["originalEvidence"] = owner.hits.first?.line == 7
        result["selectionRetained"] = owner.selectedHitIdentities() == [hits[0].identity]
        let incoming = Hit(path: "/missing/keep-stream.txt", kind: "file", line: 11, size: 9,
            filesystemPath: "/missing/keep-stream.txt", archiveMembers: [], isDirectory: false)
        filter.append([incoming])
        result["stream"] = wait { !filter.isFiltering } && filter.sourceCount == 5 && owner.hits.count == 3
        result["sourceExport"] = filter.unfilteredHits == hits + [incoming]
        apply("other-")
        result["hiddenSelectionCleared"] = wait { !filter.isFiltering } && owner.hits == [hits[1], hits[3]] && owner.selectedHitIdentities().isEmpty
        owner.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        filter.reset()
        result["reset"] = owner.hits == hits + [incoming] && !filter.isActive
            && owner.selectedHitIdentities() == [hits[1].identity]
        apply("keep-")
        filter.remove { $0.identity == hits[0].identity }
        result["lateRemoved"] = wait { !filter.isFiltering } && !owner.hits.contains(hits[0])
        filter.reset()
        result["resetDoesNotResurrect"] = !owner.hits.contains(hits[0]) && owner.hits.count == 4
        apply("keep-")
        apply("other-")
        result["generation"] = wait { !filter.isFiltering } && owner.hits == [hits[1], hits[3]]
        apply("text", field: "content")
        result["failure"] = wait { !filter.isFiltering } && filter.errorMessage != nil
            && filter.sourceCount == 4 && owner.hits.isEmpty
        filter.reset()
        result["failureReset"] = owner.hits.count == 4 && filter.errorMessage == nil
        apply("keep-")
        filter.clearForSearch()
        owner.replaceFilteredHits([hits[3]], keepingSelection: [])
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        result["newSearch"] = owner.hits == [hits[3]] && !filter.isActive
        let terminating = ResultFilterRun()
        let longName = String(repeating: "a", count: 100) + "X.txt"
        let slow = Hit(path: "/missing/" + longName, kind: "file", line: nil, size: 0,
            filesystemPath: "/missing/" + longName, archiveMembers: [], isDirectory: false)
        terminating.start([slow], query: CriteriaNode(field: "name", matchOperator: "regex", value: "(a+)+$").json,
                          root: "/missing", completion: { _, _ in })
        let started = wait { terminating.runner.process.isRunning }
        let pid = terminating.runner.process.processIdentifier
        terminating.stopForTermination(deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        result["termination"] = started && wait { kill(pid, 0) != 0 }
        let workspacePrefix = "favenio-result-filter-\(ProcessInfo.processInfo.processIdentifier)-"
        result["cleanup"] = wait {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
            return !files.contains { $0.hasPrefix(workspacePrefix) }
        }
        if result["cleanup"] == false {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
            fputs("FILTER CLEANUP DIAG: " + NSTemporaryDirectory() + " "
                + files.filter { $0.hasPrefix(workspacePrefix) }.joined(separator: ",") + "\n", stderr)
        }
        withExtendedLifetime(rows) {}
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if result.values.contains(false) { exit(1) }
    }
}
