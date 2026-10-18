import AppKit

enum CriteriaEditorSelfTest {
    static func drain() {
        let until = Date().addingTimeInterval(0.03)
        while Date() < until { RunLoop.current.run(mode: .default, before: until) }
    }

    static func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let text = """
        {"schemaVersion":1,"root":{"id":"all","op":"and","children":[
          {"id":"name","field":"name","operator":"contains","value":"Rechnung"},
          {"id":"formats","op":"or","children":[
            {"id":"pdf","field":"extension","operator":"equals","value":"pdf"},
            {"id":"word","field":"extension","operator":"equals","value":"docx"}]}]}}
        """
        let original = CriteriaNode.fromJSON(text)!
        let view = CriteriaEditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        view.loadJSON(text)
        precondition(view.root == original && view.queryJSON == text)
        precondition(view.editor.predicate == nil, "Der Editor darf keine zweite Suchauswertung aufbauen")
        precondition(view.inputIssue == nil && view.editor.numberOfRows == 5)
        view.editor.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.groupButton.performClick(nil)
        drain()
        precondition(view.editor.numberOfRows == 7)
        precondition(Set(original.identifiers).isSubset(of: Set(view.root!.identifiers)))
        precondition(Set(view.root!.identifiers).count == view.root!.identifiers.count)
        precondition(view.inputIssue != nil, "Eine neue leere Bedingung muss erklärt werden")
        view.editor.removeRows(at: IndexSet(integer: 5), includeSubrows: true)
        drain()
        precondition(view.root == original && view.inputIssue == nil)
        let input = view.editor.displayValues(forRow: 1).compactMap { $0 as? CriteriaValueView }.first!
        input.valueField.stringValue = "NEU"
        input.caseButton.state = .on
        input.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        precondition(view.root!.children[0].id == "name")
        precondition(view.root!.children[0].value == "NEU" && view.root!.children[0].caseSensitive)
        let changed = view.root!
        func descendants(_ parent: NSView) -> [NSView] {
            parent.subviews.flatMap { [$0] + descendants($0) }
        }
        func choose(_ oldTitle: String, _ title: String) {
            guard let popup = descendants(view.editor).compactMap({ $0 as? NSPopUpButton })
                .first(where: { $0.titleOfSelectedItem == oldTitle && $0.itemTitles.contains(title) })
            else { preconditionFailure("Natives Kriterienmenü \(oldTitle) fehlt") }
            popup.selectItem(withTitle: title)
            _ = popup.sendAction(popup.action, to: popup.target)
            drain()
        }
        choose("Name", "Relativer Pfad")
        guard let editedRoot = view.root else {
            let rows = (0..<view.editor.numberOfRows).map { row in
                "\(row): \(view.editor.criteria(forRow: row)); \(view.editor.displayValues(forRow: row).map { String(describing: type(of: $0)) })"
            }
            fatalError("Natives Feldmenü liefert unvollständige Zeilen: " + rows.joined(separator: " | "))
        }
        precondition(editedRoot.children[0].field == "relativePath"
                     && editedRoot.children[0].id == "name"
                     && editedRoot.children[0].value == "NEU"
                     && editedRoot.children[0].caseSensitive,
                     "Feldwechsel verliert Kennung, Wert oder Groß-/Kleinschreibung")
        choose("Relativer Pfad", "Name")
        choose("enthält", "enthält nicht")
        precondition(view.root!.children[0].negate && view.root!.children[0].value == "NEU")
        choose("enthält nicht", "enthält")
        choose("Alle Bedingungen (UND)", "Mindestens eine Bedingung (ODER)")
        precondition(view.root!.groupOperator == "or" && view.root!.id == "all")
        choose("Mindestens eine Bedingung (ODER)", "Alle Bedingungen (UND)")
        precondition(view.root == changed)
        view.editor.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        view.addButton.performClick(nil)
        drain()
        precondition(view.editor.numberOfRows == 6)
        precondition(Set(changed.identifiers).isSubset(of: Set(view.root!.identifiers)))
        view.editor.removeRows(at: IndexSet(integer: 5), includeSubrows: true)
        drain()
        precondition(view.root == changed)
        view.editor.insertRow(at: 2, with: .compound, asSubrowOfRow: 0, animate: false)
        view.editor.insertRow(at: 3, with: .simple, asSubrowOfRow: 2, animate: false)
        drain()
        precondition(Set(changed.identifiers).isSubset(of: Set(view.root!.identifiers)))
        view.editor.removeRows(at: IndexSet(integer: 2), includeSubrows: true)
        drain()
        precondition(view.root == changed)

        let unsupported = text.replacingOccurrences(of: "\"field\":\"name\"", with: "\"field\":\"futureField\"")
        view.loadJSON(unsupported)
        precondition(view.queryJSON == unsupported && !view.editor.isEditable && view.inputIssue != nil)
        view.replaceButton.performClick(nil)
        precondition(view.queryJSON != unsupported && view.editor.isEditable && view.inputIssue != nil)
        let invalidID = text.replacingOccurrences(of: "\"id\":\"all\"", with: "\"id\":\"invalid id\"")
        view.loadJSON(invalidID)
        precondition(view.queryJSON == invalidID && !view.editor.isEditable && !view.replaceButton.isHidden,
                     "Nicht bearbeitbare Kennungen brauchen einen verlustfreien Ersatzweg")
        view.loadJSON(text)

        let many = CriteriaNode(groupOperator: "and", children: (0..<100).map {
            CriteriaNode(id: "condition-\($0)", value: "Wert \($0)")
        })
        view.loadJSON(many.json)
        precondition(view.root == many && view.editor.numberOfRows == 101 && view.inputIssue == nil)
        view.editor.removeRows(at: IndexSet(integer: 50), includeSubrows: true)
        drain()
        precondition(view.root!.conditionCount == 99)
        precondition(view.root!.children[49].id == "condition-50")
        var deep = CriteriaNode(id: "deep-leaf", value: "Wert")
        for level in 1..<16 { deep = CriteriaNode(id: "level-\(level)", groupOperator: "and", children: [deep]) }
        view.loadJSON(deep.json)
        precondition(view.root == deep && view.inputIssue == nil)
        view.loadJSON(text)
        choose("Name", "Metadaten")
        let metadataInput = view.editor.displayValues(forRow: 1).compactMap { $0 as? CriteriaValueView }.first!
        precondition(!metadataInput.metadataPopup.isHidden && !metadataInput.caseButton.isHidden)
        metadataInput.metadataPopup.selectItem(withTitle: "Title")
        _ = metadataInput.metadataPopup.sendAction(metadataInput.metadataPopup.action, to: metadataInput.metadataPopup.target)
        precondition(view.root!.children[0].metadataField == "Title" && view.root!.children[0].id == "name")
        choose("Metadaten", "Dateigröße")
        precondition(metadataInput.metadataPopup.isHidden && metadataInput.caseButton.isHidden)
        precondition(view.root!.children[0].matchOperator == "atLeast"
                     && view.root!.children[0].value == "Rechnung"
                     && view.root!.children[0].metadataField == nil)
        choose("Dateigröße", "Geändert")
        precondition(metadataInput.operatorPopup.titleOfSelectedItem == "am oder nach")
        choose("Geändert", "Name")
        precondition(view.root!.children[0].matchOperator == "contains"
                     && view.root!.children[0].id == "name" && !metadataInput.caseButton.isHidden)
        let mixed = CriteriaNode(id: "mixed", groupOperator: "and", children: [
            CriteriaNode(id: "n", value: "Migration"),
            CriteriaNode(id: "e", field: "extension", matchOperator: "equals", value: "md"),
            CriteriaNode(id: "c", field: "content", value: "TODO"),
            CriteriaNode(id: "s", field: "size", matchOperator: "atLeast", value: "5 B"),
            CriteriaNode(id: "t", field: "modified", matchOperator: "atMost", value: "2099-01-01T00:00:00Z"),
            CriteriaNode(id: "m", field: "metadata", value: "alpha", metadataField: "Title"),
            CriteriaNode(id: "w", field: "width", matchOperator: "atLeast", value: "640"),
            CriteriaNode(id: "h", field: "height", matchOperator: "atMost", value: "480")])
        view.loadJSON(mixed.json)
        precondition(view.root == mixed && view.inputIssue == nil && view.editor.numberOfRows == 9)
        view.loadJSON(text)

        var configuration = SearchConfiguration()
        configuration.criteriaJSON = text + "\n"
        precondition(configuration.hasPositiveFilter)
        precondition(SearchConfiguration.fromQueryItems(configuration.queryItems) == configuration)
        let templates = [SearchTemplate(name: "Kriterien", pattern: "", root: "/fixture", configuration: configuration)]
        let encodedTemplates = try SearchTemplateFormat.encode(templates)
        let decodedTemplates = try SearchTemplateFormat.decode(encodedTemplates)
        precondition(decodedTemplates == templates)
        let control = CriteriaControl()
        control.applyJSON(unsupported)
        precondition(control.queryJSON == unsupported)
        control.enabledButton.performClick(nil)
        precondition(control.queryJSON == nil)
        control.enabledButton.performClick(nil)
        precondition(control.queryJSON == unsupported, "Deaktivieren darf den Entwurf nicht löschen")

        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.contentView!.addSubview(control)
        func waitUntil(_ predicate: () -> Bool) {
            let end = Date().addingTimeInterval(8)
            while !predicate() && Date() < end { drain() }
            precondition(predicate(), "Kriterienblatt erreicht den erwarteten Zustand nicht")
        }
        func sheetButton(_ title: String) -> NSButton {
            descendants(control.sheet!.contentView!).compactMap { $0 as? NSButton }
                .first { $0.title == title }!
        }
        control.applyJSON(text)
        control.edit(nil)
        waitUntil { sheetButton("Übernehmen").isEnabled }
        let draft = control.editingView!
        let draftInput = draft.editor.displayValues(forRow: 1).compactMap { $0 as? CriteriaValueView }.first!
        draftInput.valueField.stringValue = "Entwurf"
        draftInput.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        sheetButton("Abbrechen").performClick(nil)
        waitUntil { !control.isEditing }
        precondition(control.queryJSON == text, "Abbrechen übernimmt den Entwurf")
        control.edit(nil)
        waitUntil { sheetButton("Übernehmen").isEnabled }
        sheetButton("Übernehmen").performClick(nil)
        waitUntil { !control.isEditing }
        precondition(CriteriaNode.fromJSON(control.queryJSON!) == original)
        control.applyJSON(mixed.json)
        control.edit(nil)
        waitUntil { sheetButton("Übernehmen").isEnabled }
        let metadataView = control.editingView!
        metadataView.layoutSubtreeIfNeeded()
        precondition(metadataView.editor.frame.width <= metadataView.scroll.contentSize.width + 1,
                     "Die normale Startansicht darf Metadatenzeilen und Zeilenknöpfe nicht abschneiden")
        sheetButton("Abbrechen").performClick(nil)
        waitUntil { !control.isEditing }
        control.applyJSON(text)
        let invalidRegex = text.replacingOccurrences(of: "\"contains\",\"value\":\"Rechnung\"",
                                                     with: "\"regex\",\"value\":\"[\"")
        control.applyJSON(invalidRegex)
        control.edit(nil)
        waitUntil { control.editingView!.issueLabel.stringValue.contains("Bedingung 1:") }
        precondition(!sheetButton("Übernehmen").isEnabled)
        control.applyJSON(text)
        waitUntil { !control.isEditing }
        precondition(control.queryJSON == text, "Ein alter Prüflauf überschreibt eine neue Konfiguration")
        let duplicate = text.replacingOccurrences(of: "\"schemaVersion\":1",
                                                  with: "\"schemaVersion\":2,\"schemaVersion\":1")
        control.applyJSON(duplicate)
        control.edit(nil)
        waitUntil { !control.editingView!.replaceButton.isHidden }
        precondition(!control.editingView!.editor.isEditable && !sheetButton("Übernehmen").isEnabled)
        precondition(control.editingView!.queryJSON == duplicate)
        sheetButton("Abbrechen").performClick(nil)
        waitUntil { !control.isEditing }
        let invalidDate = CriteriaNode(id: "date", field: "modified", matchOperator: "atLeast", value: "2026-01-01")
        control.applyJSON(invalidDate.json)
        control.edit(nil)
        waitUntil { control.editingView!.issueLabel.stringValue.contains("ISO-Zeitpunkt") }
        precondition(!sheetButton("Übernehmen").isEnabled && control.editingView!.editor.isEditable)
        sheetButton("Abbrechen").performClick(nil)
        waitUntil { !control.isEditing }
        precondition(control.queryJSON == invalidDate.json)
        parent.close()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Rechnung.pdf", "Rechnung.docx", "Rechnung.txt", "Anderes.pdf"] {
            try "alpha".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let args = configuration.arguments(pattern: "", root: root.path)!
        var hits: [Hit] = []
        let exit = runSearchStreaming(arguments: args, onHit: { hits.append($0) }, onProgress: { _ in })
        precondition(exit.status == 0 && hits.map { $0.displayName }.sorted() == ["Rechnung.docx", "Rechnung.pdf"])
        precondition(hits.allSatisfy { $0.criteriaEvidence.count == 2 })
        let encoded = jsonlData(for: hits)
        let roundtrip = encoded.split(separator: 0x0A).compactMap { parseHit(Data($0)) }
        precondition(roundtrip == hits, "Export verliert Kriterienbelege")
        try "alpha\nTODO\nbeta\n".write(to: root.appendingPathComponent("Migration.md"), atomically: true, encoding: .utf8)
        var contentConfiguration = SearchConfiguration()
        contentConfiguration.criteriaJSON = CriteriaNode(id: "content-query", groupOperator: "and", children: [
            CriteriaNode(id: "name", value: "Migration"),
            CriteriaNode(id: "extension", field: "extension", matchOperator: "equals", value: "md"),
            CriteriaNode(id: "todo", field: "content", value: "TODO"),
            CriteriaNode(id: "beta", field: "content", value: "beta"),
            CriteriaNode(id: "size", field: "size", matchOperator: "atLeast", value: "5 B")]).json
        var contentHits: [Hit] = []
        let contentExit = runSearchStreaming(arguments: contentConfiguration.arguments(pattern: "", root: root.path)!,
                                             onHit: { contentHits.append($0) }, onProgress: { _ in })
        precondition(contentExit.status == 0 && contentHits.count == 1 && contentHits[0].displayName == "Migration.md")
        precondition(contentHits[0].criteriaEvidence.filter { $0.field == "content" }.map { $0.line } == [2, 3])
        precondition(contentHits[0].locationText.contains("Zeile 2") && contentHits[0].locationText.contains("TODO"))
        let contentRoundtrip = jsonlData(for: contentHits).split(separator: 0x0A).compactMap { parseHit(Data($0)) }
        precondition(contentRoundtrip == contentHits, "Export verliert Inhaltsbelege")

        if let directory = ProcessInfo.processInfo.environment["FAVENIO_CRITERIA_RENDER_DIR"] {
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 340),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = window.contentView!
            content.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                view.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded()
                drain()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: destination.appendingPathComponent("criteria-" + name + ".png"))
            }
            window.close()
        }
        print("CRITERIA EDITOR OK: native tree, stable IDs, draft preservation, templates and real core")
    }
}
