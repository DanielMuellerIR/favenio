import AppKit

#if FAVENIO_SELFTEST
private var testPreferences: UserDefaults?

var favenioPreferences: UserDefaults {
    guard let testPreferences else { preconditionFailure("Selbsttest ohne Einstellungsdomäne") }
    return testPreferences
}

func runWithIsolatedPreferences(
    bundleIdentifierPrefix: String, filterKey: String, success: String?, run: () -> Int32
) -> Int32 {
    let prefix = bundleIdentifierPrefix + "."
    guard let bundleIdentifier = Bundle.main.bundleIdentifier, bundleIdentifier.hasPrefix(prefix),
          UUID(uuidString: String(bundleIdentifier.dropFirst(prefix.count))) != nil else {
        print("SELFTEST FEHLER: unerwartete Bundle-ID")
        return 2
    }
    let suite = bundleIdentifier + "." + UUID().uuidString
    guard let settings = UserDefaults(suiteName: suite) else {
        print("SELFTEST FEHLER: Einstellungsdomäne fehlt")
        return 2
    }

    // Die App-Standarddomäne simuliert persönliche Einstellungen. Auch
    // AppKit selbst sieht hier nur die separate Identität des Test-Bundles.
    let standard = UserDefaults.standard
    let original = standard.persistentDomain(forName: bundleIdentifier)
    let seeded: [String: Any] = [
        filterKey: true,
        "finderColumn.finderTags": false,
        "finderColumn.finderComment": true,
        "NSTableView Columns Favenio.hits.columns": ["path", "name"],
        "NSTableView Columns v3 Favenio.hits.columns": ["name": 321],
        "resultView.thumbnails": true,
    ]
    standard.setPersistentDomain(seeded, forName: bundleIdentifier)
    testPreferences = settings
    let status = run()
    testPreferences = nil
    settings.removePersistentDomain(forName: suite)
    _ = settings.synchronize()
    let after = standard.persistentDomain(forName: bundleIdentifier) ?? [:]
    if let original { standard.setPersistentDomain(original, forName: bundleIdentifier) }
    else { standard.removePersistentDomain(forName: bundleIdentifier) }
    _ = standard.synchronize()
    guard status == 0 || status == 1,
          NSDictionary(dictionary: after.filter { seeded.keys.contains($0.key) }).isEqual(to: seeded),
          settings.persistentDomain(forName: suite) == nil else {
        print("SELFTEST FEHLER: Einstellungsisolation oder Aufräumen fehlgeschlagen")
        return 2
    }
    print("SELFTEST ISOLATION OK")
    if status == 0, let success { print("SELFTEST OK — \(success)") }
    return status
}

#endif

/// Läuft in beiden Bundle-Selbsttests an den echten Controller-Feldern,
/// ohne Fenster zu öffnen oder einen Suchprozess zu starten.
func pixelFieldSelfTest(_ fields: [NSTextField], validate: () -> Bool) -> String? {
    for (inputs, valid) in [(["", "", "", ""], true),
                            (["1.000 px", "1000", "", ""], true),
                            (["-1", "", "", ""], false),
                            (["10.5", "", "", ""], false),
                            ([String(Int.max) + "0", "", "", ""], false),
                            (["1001", "1000", "", ""], false),
                            (["", "", "2", "1"], false),
                            (["", "", "1", "2"], true)] {
        for (field, input) in zip(fields, inputs) { field.stringValue = input }
        guard validate() == valid else { return "Maßvalidierung falsch: \(inputs)" }
        guard valid ? fields.allSatisfy({ $0.toolTip == nil })
                    : fields.contains(where: { $0.toolTip != nil && $0.textColor == .systemRed })
        else { return "Maßfelder markieren Fehler nicht korrekt: \(inputs)" }
    }
    for field in fields { field.stringValue = "" }
    _ = validate()
    return nil
}

func filterDisclosureSelfTest(_ filters: FilterDisclosure) -> String? {
    guard !filters.isExpanded, !filters.extraViews.isEmpty,
          filters.extraViews.allSatisfy({ $0.isHidden }) else {
        return "Weitere Filter sind beim Start nicht zugeklappt"
    }
    filters.toggle(nil)
    guard filters.isExpanded, filters.extraViews.allSatisfy({ !$0.isHidden }),
          filters.disclosureButton.state == .on,
          favenioPreferences.bool(forKey: filters.defaultsKey) else {
        return "Aufklapp-Schalter zeigt die Filter nicht"
    }
    filters.toggle(nil)
    // Nur Return startet eine Suche aus einem Maßfeld. Mit der Voreinstellung
    // schickt ein NSTextField seine Action auch beim bloßen Fokusverlust —
    // und beim Zuklappen, weil das versteckte Feld den Fokus abgibt.
    guard filters.pixelFields.allSatisfy({
        ($0.cell as? NSTextFieldCell)?.sendsActionOnEndEditing == false }) else {
        return "Maßfelder suchen schon beim Fokusverlust"
    }
    filters.filterView.exclusions = ["node_modules"]
    filters.filterView.rawFacts = ["min-size": "1 MiB"]
    filters.pixelFields[0].stringValue = "100"
    filters.pixelFields[1].stringValue = " "   // leer laut PixelLimitInput
    filters.refreshTitle()
    guard filters.titleButton.title.contains("3 aktiv") else {
        return "Zugeklappter Schalter nennt aktive Filter nicht"
    }
    return nil
}

func resultFilterListSelfTest(_ owner: HitListController, terminate: () -> Void) -> String? {
    func wait(_ condition: () -> Bool) -> Bool {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    defer { owner.resultFilter.stopForTermination() }
    let first = Hit(path: "/missing/keep-a.txt", kind: "file", line: 7, size: 8,
        filesystemPath: "/missing/keep-a.txt", archiveMembers: [], isDirectory: false)
    let other = Hit(path: "/missing/other.txt", kind: "file", line: nil, size: nil,
        filesystemPath: "/missing/other.txt", archiveMembers: [], isDirectory: false)
    owner.replaceFilteredHits([first, other], keepingSelection: [first.identity])
    let filter = owner.resultFilter
    filter.criteria.applyJSON(CriteriaNode(field: "name", value: "keep-").json)
    filter.apply()
    guard wait({ !filter.isFiltering }), owner.hits == [first],
          owner.selectedHitIdentities() == [first.identity], filter.sourceCount == 2 else {
        return "Ansichtsfilter verliert Quellmenge, Belege oder Auswahl"
    }
    let incoming = Hit(path: "/missing/keep-stream.txt", kind: "file", line: 9, size: 10,
        filesystemPath: "/missing/keep-stream.txt", archiveMembers: [], isDirectory: false)
    owner.pending = [incoming]
    owner.flushResultFilterPending()
    guard wait({ !filter.isFiltering }), owner.hits.count == 2, filter.sourceCount == 3,
          owner.selectedHitIdentities() == [first.identity] else { return "Filter-Nachschub verändert Auswahl oder Quelle" }
    filter.reset()
    guard owner.hits.count == 3, !filter.isActive, owner.selectedHitIdentities() == [first.identity] else {
        return "Filterreset verliert Originaltreffer oder Auswahl"
    }
    filter.clearForSearch()
    let name = String(repeating: "a", count: 100) + "X.txt"
    let slow = Hit(path: "/missing/" + name, kind: "file", line: nil, size: 0,
        filesystemPath: "/missing/" + name, archiveMembers: [], isDirectory: false)
    owner.replaceFilteredHits([slow], keepingSelection: [])
    filter.criteria.applyJSON(CriteriaNode(field: "name", matchOperator: "regex", value: "(a+)+$").json)
    filter.apply()
    guard wait({ filter.runningProcessIdentifier != nil }), let pid = filter.runningProcessIdentifier else {
        return "Filter-Lifecycle-Gegenprobe startet keinen eigenen Prozess"
    }
    terminate()
    guard wait({ kill(pid, 0) != 0 }), !filter.isFiltering else { return "App-Ende lässt Filterprozess zurück" }
    return nil
}

func resultGroupingListSelfTest(_ owner: HitListController) -> String? {
    let a = Hit(path: "/missing/a/keep-first.txt", kind: "file", line: 7, size: 8,
        filesystemPath: "/missing/a/keep-first.txt", archiveMembers: [], isDirectory: false)
    let b = Hit(path: "/missing/b/other.md", kind: "file", line: nil, size: 9,
        filesystemPath: "/missing/b/other.md", archiveMembers: [], isDirectory: false)
    let c = Hit(path: "/missing/a/keep-last.txt", kind: "file", line: 11, size: 10,
        filesystemPath: "/missing/a/keep-last.txt", archiveMembers: [], isDirectory: false)
    let source = [a, b, c]
    owner.replaceFilteredHits(source, keepingSelection: [a.identity, b.identity])
    let groups = owner.resultGrouping
    defer {
        owner.resultFilter.stopForTermination()
        groups.setMode(.none)
        owner.resultFilter.clearForSearch()
        owner.replaceFilteredHits([], keepingSelection: [])
    }
    groups.setMode(.folder)
    guard owner.resultTableRowCount == 5, owner.selectedHitIdentities() == [a.identity, b.identity],
          owner.actionRows().count == 2 else { return "Ordnergruppen verlieren Auswahl oder Trefferabbildung" }
    guard let header = (0..<owner.resultTableRowCount).first(where: { groups.projection.group(at: $0) != nil }) else {
        return "Gruppenüberschrift fehlt"
    }
    owner.contextRow = header
    guard owner.actionRows().isEmpty, owner.hitCell(owner.tableView,
        column: owner.tableView.tableColumns[0], row: header) == nil else { return "Gruppenüberschrift wird als Datei behandelt" }
    owner.contextRow = -1
    groups.collapseAll()
    guard owner.hits.count == 3, groups.projection.displayedHitCount == 0,
          owner.selectedHitIdentities().isEmpty, owner.resultTableRowCount == 2 else {
        return "Einklappen verliert Treffer oder behält unsichtbare Auswahl"
    }
    let incoming = Hit(path: "/missing/a/keep-stream.txt", kind: "file", line: 13, size: 12,
        filesystemPath: "/missing/a/keep-stream.txt", archiveMembers: [], isDirectory: false)
    owner.appendFilteredHits([incoming], keepingSelection: [])
    guard owner.hits.count == 4, groups.projection.displayedHitCount == 0,
          let row = owner.revealTableRow(for: a.identity), owner.hitIndex(forTableRow: row).map({ owner.hits[$0].identity }) == a.identity else {
        return "Nachschub oder ausdrückliches Aufklappen verliert Gruppenidentität"
    }
    owner.tableView.selectRowIndexes([row], byExtendingSelection: false)
    groups.setMode(.fileExtension)
    guard owner.selectedHitIdentities() == [a.identity] else { return "Gruppierungswechsel wählt eine andere Datei" }
    groups.collapseAll()
    owner.resultFilter.criteria.applyJSON(CriteriaNode(field: "name", value: "keep-").json)
    owner.resultFilter.apply()
    let until = ProcessInfo.processInfo.systemUptime + 8
    while owner.resultFilter.isFiltering && ProcessInfo.processInfo.systemUptime < until {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard !owner.resultFilter.isFiltering, owner.resultFilter.errorMessage == nil,
          owner.hits.count == 3, owner.resultFilter.sourceCount == 4,
          groups.projection.displayedHitCount == 0 else { return "Ansichtsfilter und Klappzustand verlieren Quellmenge oder Darstellung" }
    owner.resultFilter.reset()
    groups.expandAll()
    guard owner.hits.count == 4, groups.projection.displayedHitCount == 4 else {
        return "Filterreset/Aufklappen verliert Originaltreffer"
    }
    groups.collapseAll()
    owner.resultFilter.clearForSearch()
    owner.replaceFilteredHits(source, keepingSelection: [])
    guard groups.projection.displayedHitCount == 3 else { return "Neue Suche behält alte eingeklappte Gruppen" }
    let archived = Hit(path: "/missing/outer!/source.zip!/folder!/a.txt", kind: "member", line: nil, size: 1,
        filesystemPath: "/missing/outer!/source.zip", archiveMembers: ["folder!/a.txt"], isDirectory: false)
    owner.replaceFilteredHits([a, archived], keepingSelection: [a.identity, archived.identity])
    let menu = NSMenu()
    let chain = menu.addItem(withTitle: "Archivkette anzeigen…", action: #selector(HitListController.ctxArchiveChain), keyEquivalent: "")
    chain.target = owner
    menu.update()
    guard !chain.isEnabled else { return "Menüautomatik aktiviert Archivkette für mehrere Treffer" }
    owner.tableView.selectRowIndexes(owner.tableRows(for: [archived.identity]), byExtendingSelection: false)
    menu.update()
    guard chain.isEnabled,
          sourceArchiveURLs(for: [a, archived, archived]).map({ $0.path }) == [archived.filesystemPath],
          archiveChainText(for: archived).contains("Treffer: folder!/a.txt") else {
        return "Archivketten-Menü oder Quellarchiv verwendet falsche Identität"
    }
    if let scroll = owner.tableView.enclosingScrollView {
        let long = String(repeating: "long-", count: 100)
        let layoutHits = (0..<20).map { index in
            Hit(path: "/missing/group-\(index)-\(long)/a.txt", kind: "file", line: nil, size: 1,
                filesystemPath: "/missing/group-\(index)-\(long)/a.txt", archiveMembers: [], isDirectory: false)
        }
        owner.replaceFilteredHits(layoutHits, keepingSelection: [])
        groups.setMode(.folder)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let row = owner.tableView.rowView(atRow: 0, makeIfNecessary: true),
              let header = descendants(row).first(where: { $0 is ResultGroupHeaderView }),
              let count = descendants(header).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "1 Treffer" }),
              let scroller = scroll.verticalScroller else { return "Native Gruppen-Geometrie fehlt" }
        func headerFits() -> Bool {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            header.layoutSubtreeIfNeeded()
            let frame = count.convert(count.bounds, to: owner.tableView)
            let right = min(owner.tableView.visibleRect.maxX, scroller.convert(scroller.bounds, to: owner.tableView).minX)
            return frame.minX >= owner.tableView.visibleRect.minX && abs(frame.maxX - right) < 1
        }
        guard headerFits() else {
            return "Gruppentrefferzahl liegt außerhalb des freien nativen Tabellenbereichs"
        }
        scroll.contentView.scroll(to: NSPoint(x: 100, y: scroll.contentView.bounds.minY))
        guard scroll.contentView.bounds.minX == 100, headerFits() else {
            return "Native Gruppenzeile verliert ihre Ausrichtung nach Scrollen und Ereignisschleife"
        }
        print("RESULT GROUP HEADER OK: native window, scroller, scroll and count geometry")
    }
    return nil
}

func finderColumnsSelfTest(_ owner: HitListController) -> String? {
    let keys = ["finderTags", "finderComment"]
    let saved = keys.map { ($0, favenioPreferences.object(forKey: "finderColumn." + $0)) }
    let hidden = keys.map { owner.tableView.tableColumn(withIdentifier: .init($0))?.isHidden }
    let callback = owner.onFinderColumnsShown
    var shown = 0
    owner.onFinderColumnsShown = { shown += 1; callback?() }
    defer {
        owner.onFinderColumnsShown = callback
        for (index, key) in keys.enumerated() {
            if let value = saved[index].1 { favenioPreferences.set(value, forKey: "finderColumn." + key) }
            else { favenioPreferences.removeObject(forKey: "finderColumn." + key) }
            if let value = hidden[index] { owner.tableView.tableColumn(withIdentifier: .init(key))?.isHidden = value }
        }
    }
    guard let menu = owner.tableView.headerView?.menu else { return "Finder-Spaltenmenü fehlt" }
    for key in keys {
        guard let column = owner.tableView.tableColumn(withIdentifier: .init(key)),
              let index = menu.items.firstIndex(where: { $0.representedObject as? String == key }) else { return "Finder-Spalteneintrag fehlt: " + key }
        column.isHidden = true
        menu.update()
        guard menu.items[index].isEnabled, menu.items[index].state == .off else { return "Versteckte Finder-Spalte hat falschen Menüzustand" }
        menu.performActionForItem(at: index)
        menu.update()
        guard !column.isHidden, menu.items[index].state == .on,
              favenioPreferences.bool(forKey: "finderColumn." + key) else { return "Native Menüaktion blendet Finder-Spalte nicht ein: " + key }
        menu.performActionForItem(at: index)
        menu.update()
        guard column.isHidden, menu.items[index].state == .off,
              !favenioPreferences.bool(forKey: "finderColumn." + key) else { return "Native Menüaktion blendet Finder-Spalte nicht aus: " + key }
    }
    guard shown == 2 else { return "Finder-Spalten aktivieren die Erfassung nicht genau beim Einblenden" }
    print("FINDER COLUMNS OK: native NSMenu actions, checkmarks, visibility, capture callback")
    return nil
}

func contentPreviewDisclosureSelfTest(_ controller: HitListController) -> String? {
    let view = controller.contentPreviewView
    let arguments = ["-u", "core", "--json", "--", "needle", "/fixture"]
    guard !view.enabled, view.body.isHidden,
          controller.contentPreviewArguments(arguments) == arguments else {
        return "Fundstellenvorschau startet nicht schlank und zugeklappt"
    }
    defer { if view.enabled { view.toggle.performClick(nil) } }
    view.toggle.performClick(nil)
    guard view.enabled, !view.body.isHidden,
          controller.contentPreviewArguments(arguments) == ["-u", "core", "--json", "--content-preview", "--", "needle", "/fixture"] else {
        return "Fundstellenvorschau klappt nicht auf oder aktiviert ihren Kernpfad nicht"
    }
    return nil
}

func staleHitRowSelfTest(_ owner: HitListController,
                         cellAt: (NSTableColumn, Int) -> NSView?) -> String? {
    let urls = [URL(fileURLWithPath: "/fixture/first.txt"), URL(fileURLWithPath: "/fixture/second.txt")]
    owner.hits = urls.map {
        Hit(path: $0.path, kind: "file", line: nil, size: nil,
            filesystemPath: $0.path, archiveMembers: [], isDirectory: false)
    }
    owner.tableView.reloadData()
    let column = NSTableColumn(identifier: .init("name"))
    guard (cellAt(column, 1) as? NSTableCellView)?.textField?.stringValue == "second.txt" else {
        return "Tabellendelegat liefert keine Zelle für den vorhandenen Treffer"
    }
    owner.hits.removeLast()
    guard owner.tableView.numberOfRows == 2,
          cellAt(column, 1) == nil, cellAt(column, -1) == nil,
          (cellAt(column, 0) as? NSTableCellView)?.textField?.stringValue == "first.txt" else {
        return "Tabellendelegat verwechselt veraltete Zeilen mit vorhandenen Treffern"
    }
    owner.previewURLs = urls
    guard owner.numberOfPreviewItems(in: nil) == 2,
          owner.previewPanel(nil, previewItemAt: 1) as? URL == urls[1] else {
        return "Vorschau-Datenquelle liefert den vorhandenen Eintrag nicht"
    }
    owner.previewURLs.removeLast()
    guard owner.numberOfPreviewItems(in: nil) == 1,
          owner.previewPanel(nil, previewItemAt: 1) == nil,
          owner.previewPanel(nil, previewItemAt: -1) == nil,
          owner.previewPanel(nil, previewItemAt: 0) as? URL == urls[0] else {
        return "Vorschau-Datenquelle verwechselt veraltete Indizes mit vorhandenen Einträgen"
    }
    owner.previewURLs = []
    guard owner.previewPanel(nil, previewItemAt: 0) == nil else {
        return "Leere Vorschau liefert einen Eintrag"
    }
    return nil
}
