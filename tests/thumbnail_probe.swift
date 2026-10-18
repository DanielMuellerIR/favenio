import AppKit
import Darwin
import ImageIO

private func thumbnailCheck(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("Thumbnail regression: " + message + "\n", stderr)
        fflush(stderr)
        fatalError(message)
    }
}
private func thumbnailWait(_ body: () -> Bool) {
    let until = Date().addingTimeInterval(30)
    while !body() && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    thumbnailCheck(body(), "Timeout")
}
private func thumbnailPNGData(_ color: CGColor) -> Data {
    let context = CGContext(
        data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
    let data = NSMutableData()
    let out = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(out, context.makeImage()!, nil)
    thumbnailCheck(CGImageDestinationFinalize(out), "PNG")
    return data as Data
}
private final class ThumbnailProbeOwner: HitListController, NSTableViewDataSource, NSTableViewDelegate {
    var changes = 0
    func numberOfRows(in view: NSTableView) -> Int { resultTableRowCount }
    func tableViewSelectionDidChange(_ note: Notification) { if !isRestoringSelection { refreshContentPreview() } }
    func tableView(_ view: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        changes += 1
        let selected = selectedHitIdentities()
        hits.sort {
            $0.displayName.localizedStandardCompare($1.displayName)
                == (view.sortDescriptors.first?.ascending == false ? .orderedDescending : .orderedAscending)
        }
        replaceFilteredHits(hits, keepingSelection: selected)
    }
}

#if !FAVENIO_TEST_SUITE
    @main
#endif
struct ThumbnailProbe {
    static func main() throws { try run(CommandLine.arguments) }
    static func run(_ arguments: [String]) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: arguments[1])
        let repo = arguments[2]
        let own = ThumbnailProbeOwner()
        own.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        own.window.isReleasedWhenClosed = false
        own.tableView.dataSource = own
        own.tableView.delegate = own
        own.tableView.allowsMultipleSelection = true
        let column = NSTableColumn(identifier: .init("name"))
        column.title = "Name"
        column.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        own.tableView.addTableColumn(column)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
        scroll.documentView = own.tableView
        scroll.hasVerticalScroller = true
        own.window.contentView!.addSubview(scroll)
        own.hits = (0..<1000).map {
            Hit(
                path: "/synthetic/image-\($0).png", kind: "file", line: nil, size: 100,
                filesystemPath: "/synthetic/image-\($0).png", archiveMembers: [], isDirectory: false)
        }
        own.resultGrouping.rebuild()
        own.tableView.reloadData()
        own.installThumbnails(in: scroll, compact: false)
        let grid = own.thumbnailController!
        thumbnailCheck(own.tableView.sortDescriptors.isEmpty && grid.sortPopup.title == "Ohne Sortierung", "Unsorted projection")
        grid.setGrid(true, persist: false)
        grid.collection.layoutSubtreeIfNeeded()
        thumbnailCheck(grid.collection.numberOfItems(inSection: 0) == 1000, "Grid count")
        let selection: Set<IndexPath> = [IndexPath(item: 1, section: 0), IndexPath(item: 4, section: 0)]
        grid.collection.selectionIndexPaths = selection
        grid.collectionView(grid.collection, didSelectItemsAt: selection)
        grid.contextTableRow = 1
        let contextMenu = NSMenu()
        thumbnailCheck(own.populateHitMenu(contextMenu), "Grid context menu exists")
        thumbnailCheck(Set(own.actionRows()) == Set([1, 4]), "Grid context keeps multiple selection")
        grid.contextTableRow = 2
        thumbnailCheck(own.populateHitMenu(contextMenu) && own.actionRows() == [2], "Grid context targets clicked unselected tile")
        let identities = own.selectedHitIdentities()
        thumbnailCheck(identities.count == 2, "Grid selection")
        grid.setGrid(false, persist: false)
        thumbnailCheck(own.selectedHitIdentities() == identities, "Table selection")
        grid.setGrid(true, persist: false)
        thumbnailCheck(grid.collection.selectionIndexPaths == selection, "Restored selection")
        grid.sortPopup.selectItem(at: 1)
        NSApp.sendAction(grid.sortPopup.action!, to: grid.sortPopup.target, from: grid.sortPopup)
        thumbnailWait { own.changes > 0 }
        thumbnailCheck(own.selectedHitIdentities() == identities, "Sort selection")
        grid.sortPopup.select(grid.sortPopup.lastItem)
        NSApp.sendAction(grid.sortPopup.action!, to: grid.sortPopup.target, from: grid.sortPopup)
        thumbnailWait { own.changes > 1 }
        thumbnailCheck(own.tableView.sortDescriptors.isEmpty && own.selectedHitIdentities() == identities, "Clear sort selection")
        own.resultGrouping.setMode(.fileExtension)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        grid.reload()
        thumbnailCheck(grid.collection.numberOfSections == 1, "Group count")
        own.resultGrouping.collapseAll()
        grid.reload()
        thumbnailCheck(grid.collection.numberOfItems(inSection: 0) == 0, "Collapse")
        own.resultGrouping.expandAll()
        grid.reload()
        thumbnailCheck(grid.collection.numberOfItems(inSection: 0) == 1000, "Expand")
        thumbnailCheck(grid.loader.state["decoded"] == 0 && grid.loader.state["pending"] == 0, "Invisible work")
        _ = grid.collection.item(at: IndexPath(item: 0, section: 0))
        own.hits.reverse()
        own.resultGrouping.rebuild()
        own.tableView.reloadData()
        let currentTile = grid.collection.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailTile
        thumbnailCheck(currentTile?.identity == own.hits[0].identity, "Reload keeps displayed action identity atomic")
        let data = thumbnailPNGData(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let renderer = ThumbnailLoader()
        renderer.cliPath = repo + "/favenio.py"
        func load(_ hit: Hit) -> ThumbnailResult {
            var result: ThumbnailResult?
            renderer.request(hit) { result = $0 }
            thumbnailWait { result != nil }
            return result!
        }
        for index in 0..<70 {
            let path = root.appendingPathComponent("image-\(index).png")
            try data.write(to: path)
            let hit = Hit(
                path: path.path, kind: "file", line: nil, size: data.count, filesystemPath: path.path,
                archiveMembers: [], isDirectory: false)
            thumbnailCheck(load(hit).image != nil, "Local thumbnail \(index)")
        }
        let state = renderer.state
        thumbnailCheck(
            state["cacheCount"]! <= 64 && state["cacheBytes"]! <= 16 * 1024 * 1024 && state["peakRunning"]! <= 2,
            "Cache limits")
        own.hits = [Hit(path: root.appendingPathComponent("image-0.png").path, kind: "file", line: nil,
            size: data.count, filesystemPath: root.appendingPathComponent("image-0.png").path,
            archiveMembers: [], isDirectory: false)]
        own.window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 720, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        own.window.isReleasedWhenClosed = false
        own.window.contentView!.addSubview(scroll)
        // Die echte Kachelwiederverwendung braucht ein geordnetes Fenster;
        // es bleibt außerhalb aller Bildschirme und erhält keinen Fokus.
        own.window.orderFront(nil)
        thumbnailCheck(own.window.isVisible && !own.window.isKeyWindow, "Offscreen window without focus")
        own.resultGrouping.setMode(.none)
        own.resultGrouping.rebuild()
        own.tableView.reloadData()
        grid.loader.cliPath = repo + "/favenio.py"
        grid.reload()
        thumbnailWait {
            (grid.collection.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailTile)?.status.stringValue == ""
        }
        let decodedBeforeReuse = grid.loader.state["decoded"]!
        grid.collection.reloadData()
        grid.collection.layoutSubtreeIfNeeded()
        grid.scheduleVisible()
        thumbnailWait {
            (grid.collection.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailTile)?.status.stringValue == ""
        }
        thumbnailCheck(grid.loader.state["decoded"] == decodedBeforeReuse, "Reused tile uses bounded cache")
        grid.loader.cancelAll(clearCache: true)
        own.window.orderOut(nil)
        let archive = root.appendingPathComponent("own.zip")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],'w');z.write(sys.argv[2],'inner!/image.png');z.close()",
            archive.path, root.appendingPathComponent("image-0.png").path,
        ]
        try child.run()
        child.waitUntilExit()
        thumbnailCheck(child.terminationStatus == 0, "Own archive")
        let manager = MaterializationManager.shared
        manager.cleanup()
        manager.cliPath = repo + "/favenio.py"
        manager.temporaryDirectory = root
        renderer.manager = manager
        let member = Hit(
            path: archive.path + "!/inner!/image.png", kind: "member", line: nil, size: data.count,
            filesystemPath: archive.path, archiveMembers: ["inner!/image.png"], isDirectory: false)
        thumbnailCheck(load(member).image != nil, "Archive thumbnail")
        thumbnailWait {
            ((try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains("hit-") }
                .isEmpty
        }
        var first: URL?
        var second: URL?
        let lease = manager.request(member, localOnly: true, ephemeral: true) {
            if case .ready(let url) = $0 { first = url }
        }
        thumbnailWait { first != nil }
        manager.request(member) { if case .ready(let url) = $0 { second = url } }
        thumbnailWait { second != nil }
        thumbnailCheck(first == second, "Shared action file")
        lease?.release()
        Thread.sleep(forTimeInterval: 0.05)
        thumbnailCheck(FileManager.default.fileExists(atPath: first!.path), "Explicit action retained file")
        manager.cleanup()
        let shared = MaterializationManager.shared
        shared.cliPath = repo + "/favenio.py"
        shared.temporaryDirectory = root
        var retainedURL: URL?
        shared.request(member) { if case .ready(let url) = $0 { retainedURL = url } }
        thumbnailWait { retainedURL != nil }
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: own)
        provider.userInfo = member
        thumbnailCheck(own.filePromiseProvider(provider, fileNameForType: "public.png") == "image.png", "Promise name")
        let destination = root.appendingPathComponent("promised.png")
        var promised = false
        var promiseFailure: Error?
        own.filePromiseProvider(provider, writePromiseTo: destination) { error in
            DispatchQueue.main.async {
                promiseFailure = error
                promised = true
            }
        }
        thumbnailWait { promised }
        thumbnailCheck(promiseFailure == nil && (try? Data(contentsOf: destination)) == data, "Promise bytes")
        thumbnailCheck(shared.knownURL(for: member) == retainedURL, "Promise shared URL")
        shared.cleanup()
        let largeSource = root.appendingPathComponent("large-source.bin")
        FileManager.default.createFile(atPath: largeSource.path, contents: Data())
        let largeHandle = try FileHandle(forWritingTo: largeSource)
        try largeHandle.truncate(atOffset: 80 * 1024 * 1024)
        try largeHandle.close()
        let largeArchive = root.appendingPathComponent("large.zip")
        let pack = Process()
        pack.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        pack.arguments = ["-c", "import sys,zipfile;z=zipfile.ZipFile(sys.argv[1],'w',zipfile.ZIP_DEFLATED,compresslevel=1);z.write(sys.argv[2],'large.png');z.close()", largeArchive.path, largeSource.path]
        try pack.run()
        pack.waitUntilExit()
        thumbnailCheck(pack.terminationStatus == 0, "Large own archive")
        let extractionStarted = root.appendingPathComponent("large-started")
        let wrapper = root.appendingPathComponent("materialize.py")
        let wrapperCode = "import os,sys,time\nfrom pathlib import Path\nPath("
            + String(reflecting: extractionStarted.path) + ").touch()\ntime.sleep(.2)\nos.execv('/usr/bin/python3',['/usr/bin/python3',"
            + String(reflecting: repo + "/favenio.py") + ",*sys.argv[1:]])\n"
        try wrapperCode.write(to: wrapper, atomically: false, encoding: .utf8)
        shared.cliPath = wrapper.path
        let largeMember = Hit(path: largeArchive.path + "!/large.png", kind: "member", line: nil, size: nil,
            filesystemPath: largeArchive.path, archiveMembers: ["large.png"], isDirectory: false)
        var largeThumbnail: ThumbnailResult?
        var largeAction: MaterializationOutcome?
        renderer.request(largeMember) { largeThumbnail = $0 }
        thumbnailWait { FileManager.default.fileExists(atPath: extractionStarted.path) }
        shared.request(largeMember) { largeAction = $0 }
        thumbnailWait { largeThumbnail != nil && largeAction != nil }
        guard case .ready(let largeURL)? = largeAction else {
            thumbnailCheck(false, "Thumbnail must not tighten explicit action budgets")
            return
        }
        thumbnailCheck(largeThumbnail?.image == nil, "Own image byte limit remains")
        let compare = Process()
        compare.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        compare.arguments = ["-c", "import hashlib,sys\ndef digest(p):\n h=hashlib.sha256()\n with open(p,'rb') as f:\n  for b in iter(lambda:f.read(65536),b''):h.update(b)\n return h.digest()\nassert digest(sys.argv[1])==digest(sys.argv[2])", largeURL.path, largeSource.path]
        try compare.run()
        compare.waitUntilExit()
        thumbnailCheck(compare.terminationStatus == 0, "Shared large action bytes")
        shared.cleanup()
        shared.cliPath = repo + "/favenio.py"
        let changedPath = root.appendingPathComponent("image-69.png")
        let changedHit = Hit(
            path: changedPath.path, kind: "file", line: nil, size: data.count, filesystemPath: changedPath.path,
            archiveMembers: [], isDirectory: false)
        let before = renderer.state["decoded"]!
        try thumbnailPNGData(CGColor(red: 0, green: 0, blue: 1, alpha: 1)).write(to: changedPath)
        thumbnailCheck(
            load(changedHit).image != nil && renderer.state["decoded"]! > before, "Generation cache invalidation")
        let broken = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        thumbnailCheck(
            load(
                Hit(
                    path: broken.path, kind: "file", line: nil, size: 12, filesystemPath: broken.path,
                    archiveMembers: [], isDirectory: false)
            ).image == nil, "Broken image placeholder")
        let huge = root.appendingPathComponent("huge.png")
        FileManager.default.createFile(atPath: huge.path, contents: Data())
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: UInt64(ThumbnailLoader.maximumBytes + 1))
        try hugeHandle.close()
        thumbnailCheck(
            load(
                Hit(
                    path: huge.path, kind: "file", line: nil, size: ThumbnailLoader.maximumBytes + 1,
                    filesystemPath: huge.path, archiveMembers: [], isDirectory: false)
            ).image == nil, "Byte limit")
        let slow = root.appendingPathComponent("slow.py")
        let pidFile = root.appendingPathComponent("slow.pid")
        try
            ("import os,time\nfrom pathlib import Path\nPath(" + String(reflecting: pidFile.path)
            + ").write_text(str(os.getpid()))\ntime.sleep(30)\n").write(to: slow, atomically: false, encoding: .utf8)
        let cancelling = ThumbnailLoader()
        cancelling.cliPath = slow.path
        let cancelJob = cancelling.request(changedHit) { _ in fatalError("Cancelled thumbnail delivered") }
        // Dateianlage und PID-Inhalt entstehen im Kind nicht atomar.
        thumbnailWait { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        let childPID = Int32(try String(contentsOf: pidFile, encoding: .utf8))!
        cancelJob.cancel()
        thumbnailWait { cancelling.state["pending"] == 0 && cancelling.state["running"] == 0 }
        thumbnailCheck(kill(childPID, 0) != 0 && errno == ESRCH, "Own validation child reaped")
        renderer.cancelAll(clearCache: true)
        thumbnailCheck(renderer.state["cacheBytes"] == 0, "Cache cleanup")
        let report: [String: Any] = [
            "passed": true, "gridItems": 1000, "gridContextActions": true, "reusedTileCompleted": true, "atomicReloadIdentity": true, "sharedActionBudgetsPreserved": true, "unsortedProjection": true, "selectionTableGridSort": true, "groupCollapseExpand": true,
            "invisibleReads": 0, "cacheState": state, "archiveThumbnailReleased": true, "sharedActionURL": true,
            "cacheCleanup": true, "filePromiseBytes": true, "generationInvalidation": true, "brokenAndOversized": true,
            "cancelledChildReaped": true,
        ]
        print(
            String(data: try JSONSerialization.data(withJSONObject: report, options: .prettyPrinted), encoding: .utf8)!)

    }
}
