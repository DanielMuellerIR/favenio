import AppKit
import Darwin

final class DuplicateCheckController: NSObject, NSWindowDelegate {
    weak var owner: HitListController?
    let button = NSButton(title: "Dubletten prüfen…", target: nil, action: nil)
    let scope = NSPopUpButton()
    let local = NSButton(checkboxWithTitle: "Nur lokal vorhandene Inhalte lesen", target: nil, action: nil)
    let start = NSButton(title: "Prüfen", target: nil, action: nil)
    let stop = NSButton(title: "Abbrechen", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let scopeNote = NSTextField(wrappingLabelWithString: "")
    let issueNote = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    private(set) var results = DuplicateResultsController()
    private(set) var job: DuplicateJob?
    private var snapshot: [[Hit]] = []
    private var selected: [Hit] { snapshot.indices.contains(scope.indexOfSelectedItem) ? snapshot[scope.indexOfSelectedItem] : [] }

    init(owner: HitListController) {
        self.owner = owner; super.init()
        button.target = self; button.action = #selector(show)
        button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11)
        button.setAccessibilityIdentifier("duplicateCheckButton")
    }
    @objc func show() {
        guard let owner else { return }
        if results.window == nil { buildWindow(owner: owner) }
        if job == nil {
            prepareSnapshot()
        }
        results.window.makeKeyAndOrderFront(nil)
    }
    func prepareSnapshot() {
        guard let owner, job == nil else { return }
        owner.flushResultFilterPending()
        snapshot = [owner.selectedHitIndices.map { owner.hits[$0] }, owner.hits]
        scope.selectItem(at: fileObjects(snapshot[0]).count >= 2 ? 0 : 1)
        local.state = owner.localOnlyContent ? .on : .off
        changedScope()
    }
    private func fileObjects(_ hits: [Hit]) -> [Hit] {
        var seen = Set<HitIdentity>()
        return hits.filter { !$0.isDirectory && seen.insert($0.identity).inserted }
    }
    func buildWindow(owner: HitListController) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 840, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Dublettenprüfung – Favenio"; panel.minSize = NSSize(width: 720, height: 650)
        panel.isReleasedWhenClosed = false; panel.level = owner.window?.level ?? .normal; panel.appearance = owner.window?.appearance
        panel.delegate = self; results.window = panel
        scope.addItems(withTitles: ["Ausgewählte Treffer", "Alle gefilterten Treffer"])
        scope.target = self; scope.action = #selector(changedScope)
        scope.setAccessibilityIdentifier("duplicateScope")
        start.target = self; start.action = #selector(begin); start.keyEquivalent = "\r"
        start.setAccessibilityIdentifier("duplicateStart")
        stop.target = self; stop.action = #selector(cancel); stop.isEnabled = false
        stop.setAccessibilityIdentifier("duplicateCancel")
        status.font = .systemFont(ofSize: 13, weight: .semibold); status.setAccessibilityIdentifier("duplicateStatus")
        scopeNote.font = .systemFont(ofSize: 11); scopeNote.textColor = .secondaryLabelColor
        scopeNote.setAccessibilityIdentifier("duplicateScopeNote")
        issueNote.font = .systemFont(ofSize: 11); issueNote.textColor = .secondaryLabelColor
        issueNote.maximumNumberOfLines = 3; issueNote.setAccessibilityIdentifier("duplicateIssues")
        progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        let title = NSTextField(labelWithString: "Bytegleiche Dateien prüfen")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [scope, spacer, stop, start]); controls.spacing = 12
        let note = NSTextField(wrappingLabelWithString: "Größe → vollständiger SHA-256 → Bytevergleich. Ergebnis gilt für den Prüfzeitpunkt. Hardlinks können dasselbe Dateisystemobjekt benennen. Quelldateien und Archive bleiben unverändert; keine Speicherersparnis wird berechnet.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let scroll = results.makeTable()
        let stack = NSStackView(views: [title, controls, scopeNote, local, progress, status, issueNote, scroll, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let content = NSView(); panel.contentView = content
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)])
        for view in [controls, scopeNote, progress, status, issueNote, scroll, note] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        issueNote.isHidden = true
        panel.center()
    }
    @objc func changedScope() {
        guard job == nil else { return }
        let files = fileObjects(selected)
        scopeNote.stringValue = "Festgehaltene Menge: \(files.count) Objekte, davon \(files.filter { $0.isMember }.count) Archivmitglieder; \(selected.count - files.count) Ordner/doppelte Treffer ausgenommen. Containerdateien bleiben eigene Objekte."
        start.isEnabled = files.count >= 2 && files.count <= 50000
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        results.clear(); status.stringValue = files.count > 50000 ? "Höchstens 50000 Dateien je Prüfung." : "Bereit. Höchstens 64 GiB Vergleichsbytes, 1 GiB befristete Archivdateien und 5 Minuten einschließlich Vorbereitung."
    }
    @objc func begin() {
        guard job == nil, start.isEnabled else { return }
        let files = fileObjects(selected), operation = DuplicateJob()
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        results.clear(); job = operation; running(true); progress.doubleValue = 0
        status.stringValue = "Bereite \(files.count) Dateien vor…"
        operation.run(hits: files, localOnly: local.state == .on, progress: { [weak self, weak operation] value in
            guard let self, let operation, self.job === operation else { return }
            let phase = ["facts": "Dateifakten", "hash": "Vollständig lesen", "confirm": "Bytevergleich", "validate": "Quellen prüfen", "materialize": "Archive vorbereiten"][value.phase] ?? value.phase
            self.progress.doubleValue = value.total > 0 ? Double(value.done) / Double(value.total) : 0
            let name = value.currentID.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].displayName : nil } ?? ""
            let measure = value.phase == "materialize" ? "befristet" : "gelesen"
            self.status.stringValue = "\(phase): \(value.done)/\(value.total) · \(ByteCountFormatter.string(fromByteCount: value.readBytes, countStyle: .binary)) \(measure) · \(name)"
        }, completion: { [weak self, weak operation] outcome in
            guard let self, let operation, self.job === operation else { return }
            self.job = nil; self.running(false); self.progress.doubleValue = 1
            switch outcome {
            case .success(let result):
                self.results.accept(result, originals: files)
                let prefix = result.complete ? "Abgeschlossen" : result.state == "partial" ? "Teilprüfung – \(result.issueCount) unbekannte/ausgelassene Dateien" : "Unvollständig – Grenze oder Abbruch"
                self.status.stringValue = "\(prefix): \(result.groups.count) bytegeprüfte Gruppen · \(result.checkedAt)"
                self.issueNote.stringValue = result.issues.prefix(3).map { issue in
                    let name = issue.id.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].displayName : nil } ?? "Prüfung"
                    return name + ": " + issue.message
                }.joined(separator: "\n")
                self.issueNote.isHidden = result.issues.isEmpty
                self.status.toolTip = result.issues.map { "\($0.id.flatMap(Int.init).flatMap { files.indices.contains($0) ? files[$0].path : nil } ?? "Prüfung"): \($0.message)" }.joined(separator: "\n")
            case .failure(let error):
                self.results.clear(); self.status.stringValue = "Prüfung fehlgeschlagen; kein bestätigtes Ergebnis."
                self.status.toolTip = String(describing: error)
                self.issueNote.stringValue = String(describing: error); self.issueNote.isHidden = false
            }
        })
    }
    private func running(_ value: Bool) { scope.isEnabled = !value; local.isEnabled = !value; start.isEnabled = !value; stop.isEnabled = value }
    @objc func cancel() {
        job?.cancel(); job = nil
        guard results.window != nil else { return }
        running(false); results.clear(); progress.doubleValue = 0
        issueNote.stringValue = ""; issueNote.isHidden = true; status.toolTip = nil
        status.stringValue = "Abgebrochen. Kein bestätigtes Ergebnis."
    }
    func stopForTermination() { job?.cancel(force: true); job = nil }
    func windowWillClose(_ notification: Notification) { cancel() }
}

final class DuplicateResultsController: HitListController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private var rows: [Int?] = []
    private var headers: [Int: String] = [:]
    private var relations: [Int: String] = [:]
    override var resultTableRowCount: Int { rows.count }
    override func hitIndex(forTableRow row: Int) -> Int? { rows.indices.contains(row) ? rows[row] : nil }
    override func tableRow(forHitIndex index: Int) -> Int? { rows.firstIndex { $0 == index } }
    func makeTable() -> NSScrollView {
        let names = NSTableColumn(identifier: .init("file")); names.title = "Datei und vollständiger Pfad"; names.width = 570; names.minWidth = 300
        let relation = NSTableColumn(identifier: .init("relation")); relation.title = "Dateisystembezug"; relation.width = 190; relation.minWidth = 150
        tableView.addTableColumn(names); tableView.addTableColumn(relation)
        tableView.dataSource = self; tableView.delegate = self; tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.setAccessibilityIdentifier("duplicateGroups")
        let menu = NSMenu(); menu.delegate = self; tableView.menu = menu
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = tableView
        return scroll
    }
    func clear() { hits = []; rows = []; headers = [:]; relations = [:]; tableView.reloadData() }
    func accept(_ result: DuplicateResult, originals: [Hit]) {
        clear()
        for group in result.groups {
            headers[rows.count] = "Gruppe \(group.id) · \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .binary)) je Datei · \(group.memberIDs.count) Pfade · \(group.physicalFiles) Dateisystemobjekte"
            let archiveCount = group.memberIDs.compactMap(Int.init).filter { originals.indices.contains($0) && originals[$0].isMember }.count
            if archiveCount > 0 { headers[rows.count] = "Gruppe \(group.id) · \(ByteCountFormatter.string(fromByteCount: group.size, countStyle: .binary)) je Objekt · \(group.memberIDs.count) Objekte · \(archiveCount) Archivmitglieder" }
            rows.append(nil)
            for id in group.memberIDs {
                guard let index = Int(id), originals.indices.contains(index), let file = result.files[id] else { continue }
                let original = originals[index]
                var hit = Hit(path: original.path, kind: original.kind, line: nil, size: Int(file.size), filesystemPath: original.filesystemPath, archiveMembers: original.archiveMembers, isDirectory: false)
                hit.archiveMemberBytes = original.archiveMemberBytes; hit.searchRootBytes = original.searchRootBytes
                if original.isMember { hit.contentPreview = original.contentPreview; hit.contentEncoding = original.contentEncoding; hit.terms = original.terms }
                relations[hits.count] = original.isMember ? "Archivmitglied" : file.linkKind == "symbolic" ? "Symbolische Verknüpfung" : file.linkKind == "hardlink" ? "Hardlink · \(file.linkCount) Namen" : "Eigene Datei"
                rows.append(hits.count); hits.append(hit)
            }
        }
        tableView.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { hitIndex(forTableRow: row) != nil }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { headers[row] != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { headers[row] == nil ? 44 : 30 }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let container = NSTableCellView(), label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false; label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label); container.textField = label
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8), label.centerYAnchor.constraint(equalTo: container.centerYAnchor)])
        if let header = headers[row] {
            // AppKit fordert die gesamte Gruppenzeile ohne Spaltenobjekt an.
            label.stringValue = column == nil || column?.identifier.rawValue == "file" ? header : ""
            label.font = .systemFont(ofSize: 12, weight: .semibold); label.toolTip = header
        } else if let index = hitIndex(forTableRow: row) {
            if column?.identifier.rawValue == "relation" { label.stringValue = relations[index] ?? ""; label.font = .systemFont(ofSize: 11) }
            else {
                let hit = hits[index]
                let text = NSMutableAttributedString(string: hit.displayName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])
                text.append(NSAttributedString(string: hit.path, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
                label.maximumNumberOfLines = 2; label.attributedStringValue = text; label.toolTip = hit.path
            }
        }
        return container
    }
    func menuWillOpen(_ menu: NSMenu) { _ = populateHitMenu(menu) }
}
