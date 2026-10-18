import AppKit

struct CriteriaNode: Equatable {
    var id = UUID().uuidString
    var groupOperator: String? = nil
    var field = "name"
    var matchOperator = "contains"
    var value = ""
    var caseSensitive = false
    var negate = false
    var metadataField: String? = nil
    var children: [CriteriaNode] = []
    var dateRange: DateRangeSpec? = nil
    var hasDateRanges: Bool { dateRange != nil || children.contains { $0.hasDateRanges } }
    var hasFinderFields: Bool { ["finderTags", "finderComment"].contains(field) || children.contains { $0.hasFinderFields } }

    var object: [String: Any] {
        if let groupOperator {
            return ["id": id, "op": groupOperator, "children": children.map { $0.object }]
        }
        var result: [String: Any] = ["id": id, "field": field,
                                   "operator": matchOperator, "value": dateRange.map { $0.object as Any } ?? value]
        if caseSensitive { result["caseSensitive"] = true }
        if negate { result["negate"] = true }
        if let metadataField { result["metadataField"] = metadataField }
        return result
    }

    var conditionCount: Int {
        groupOperator == nil ? 1 : children.reduce(0) { $0 + $1.conditionCount }
    }
    var identifiers: [String] { [id] + children.flatMap { $0.identifiers } }

    static func parse(_ object: Any, depth: Int = 1) -> CriteriaNode? {
        guard depth <= 16, let object = object as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty, id.utf8.count <= 64,
              id.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        if object["children"] != nil || object["op"] != nil {
            guard Set(object.keys) == ["id", "op", "children"],
                  let op = object["op"] as? String, ["and", "or"].contains(op),
                  let raw = object["children"] as? [Any], raw.count <= 256 else { return nil }
            let children = raw.compactMap { parse($0, depth: depth + 1) }
            guard children.count == raw.count else { return nil }
            return CriteriaNode(id: id, groupOperator: op, children: children)
        }
        let required = Set(["id", "field", "operator", "value"])
        guard required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(["caseSensitive", "negate", "metadataField"])),
              let field = object["field"] as? String,
              CriteriaEditorView.fields.contains(field),
              let op = object["operator"] as? String,
              CriteriaEditorView.operators(for: field).contains(op) else { return nil }
        let dateRange = object["value"].flatMap { DateRangeSpec.parse($0) }
        guard object["value"] is String || (["modified", "created"].contains(field) && dateRange != nil) else { return nil }
        let value = object["value"] as? String ?? ""
        for key in ["caseSensitive", "negate"] where object[key] != nil {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        }
        if let metadataField = object["metadataField"] {
            guard field == "metadata", let tag = metadataField as? String,
                  metadataFieldList().contains(tag) else { return nil }
        }
        if CriteriaEditorView.numericFields.contains(field), object["caseSensitive"] as? Bool == true { return nil }
        return CriteriaNode(id: id, field: field, matchOperator: op, value: value,
                            caseSensitive: object["caseSensitive"] as? Bool ?? false,
                            negate: object["negate"] as? Bool ?? false,
                            metadataField: object["metadataField"] as? String, dateRange: dateRange)
    }

    static func fromJSON(_ text: String) -> CriteriaNode? {
        guard text.utf8.count <= 64 * 1024, !DateRangeTransport.hasDuplicateKeys(Data(text.utf8)),
              let object = preservedJSONObject(Data(text.utf8)),
              let document = object as? [String: Any],
              Set(document.keys) == ["schemaVersion", "root"],
              let version = document["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), [1.0, 2.0, 3.0].contains(version.doubleValue) else { return nil }
        guard let node = document["root"].flatMap({ parse($0) }),
              node.identifiers.count <= 256, node.conditionCount <= 128,
              Set(node.identifiers).count == node.identifiers.count,
              !node.hasDateRanges || version.intValue >= 2,
              !node.hasFinderFields || version.intValue == 3 else { return nil }
        return node
    }

    var json: String {
        let object: [String: Any] = ["schemaVersion": hasFinderFields ? 3 : hasDateRanges ? 2 : 1, "root": self.object]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

final class CriteriaValueView: NSStackView, NSTextFieldDelegate {
    let nodeID: String
    let fieldPopup = NSPopUpButton()
    let operatorPopup = NSPopUpButton()
    let metadataPopup = NSPopUpButton()
    let valueField = NSTextField(string: "")
    let caseButton = NSButton(checkboxWithTitle: "Groß/klein", target: nil, action: nil)
    let dateButton = NSButton(title: "Datum…", target: nil, action: nil)
    private var dateRange: DateRangeSpec?
    private var dateEditor: DateRangeEditor?
    var onChange: (() -> Void)?
    var onFieldChange: (() -> Void)?

    init(id: String, field: String = "name", op: String = "contains",
         value: String = "", caseSensitive: Bool = false, negate: Bool = false,
         metadataField: String? = nil, allowedFields: [String] = CriteriaEditorView.fields,
         dateRange: DateRangeSpec? = nil) {
        nodeID = id
        self.dateRange = dateRange
        super.init(frame: NSRect(x: 0, y: 0, width: 650, height: 26))
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        for key in allowedFields {
            fieldPopup.addItem(withTitle: CriteriaEditorView.labels[key] ?? key)
            fieldPopup.lastItem?.representedObject = key
        }
        fieldPopup.selectItem(withTitle: CriteriaEditorView.labels[field]!)
        fieldPopup.target = self
        fieldPopup.action = #selector(fieldChanged)
        operatorPopup.target = self
        operatorPopup.action = #selector(changed)
        metadataPopup.addItem(withTitle: "Alle Textfelder")
        for tag in metadataFieldList() {
            metadataPopup.addItem(withTitle: tag)
            metadataPopup.lastItem?.representedObject = tag
        }
        if let metadataField { metadataPopup.selectItem(withTitle: metadataField) }
        metadataPopup.target = self
        metadataPopup.action = #selector(changed)
        metadataPopup.toolTip = "Metadatenfeld; die Liste stammt aus dem Suchkern"
        let fieldFont = fieldPopup.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let fieldLabelWidth = fieldPopup.itemTitles.map {
            ($0 as NSString).size(withAttributes: [.font: fieldFont]).width
        }.max() ?? 0
        fieldPopup.widthAnchor.constraint(equalToConstant: max(125, ceil(fieldLabelWidth) + 34)).isActive = true
        operatorPopup.widthAnchor.constraint(equalToConstant: 175).isActive = true
        metadataPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true
        valueField.stringValue = value
        valueField.identifier = NSUserInterfaceItemIdentifier("criteria-value-" + id)
        valueField.font = .systemFont(ofSize: NSFont.systemFontSize)
        valueField.widthAnchor.constraint(equalToConstant: 210).isActive = true
        valueField.delegate = self
        (valueField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false
        caseButton.state = caseSensitive ? .on : .off
        caseButton.toolTip = "Groß-/Kleinschreibung für diese Bedingung beachten"
        caseButton.target = self
        caseButton.action = #selector(changed)
        addArrangedSubview(fieldPopup)
        addArrangedSubview(metadataPopup)
        addArrangedSubview(operatorPopup)
        addArrangedSubview(valueField)
        dateButton.target = self; dateButton.action = #selector(editDate)
        dateButton.setAccessibilityIdentifier("criteria-date-" + id)
        addArrangedSubview(dateButton)
        addArrangedSubview(caseButton)
        refreshField(selectedOperator: (negate ? "not-" : "") + op)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    func controlTextDidChange(_ notification: Notification) { onChange?() }
    var node: CriteriaNode {
        let op = operatorPopup.selectedItem?.representedObject as? String ?? "contains"
        let field = fieldPopup.selectedItem?.representedObject as? String ?? "name"
        return CriteriaNode(id: nodeID, field: field,
                            matchOperator: op.hasPrefix("not-") ? String(op.dropFirst(4)) : op,
                            value: valueField.stringValue,
                            caseSensitive: !CriteriaEditorView.numericFields.contains(field) && caseButton.state == .on,
                            negate: op.hasPrefix("not-"),
                            metadataField: field == "metadata" ? metadataPopup.selectedItem?.representedObject as? String : nil,
                            dateRange: ["modified", "created"].contains(field) ? dateRange : nil)
    }
    private func refreshField(selectedOperator: String) {
        let field = fieldPopup.selectedItem?.representedObject as? String ?? "name"
        let operators = CriteriaEditorView.operators(for: field)
        let choices = operators + operators.map { "not-" + $0 }
        let fallback = (selectedOperator.hasPrefix("not-") ? "not-" : "") + operators[0]
        operatorPopup.removeAllItems()
        for key in choices {
            operatorPopup.addItem(withTitle: CriteriaEditorView.operatorTitle(key, field: field))
            operatorPopup.lastItem?.representedObject = key
        }
        let selected = choices.contains(selectedOperator) ? selectedOperator : fallback
        operatorPopup.selectItem(withTitle: CriteriaEditorView.operatorTitle(selected, field: field))
        metadataPopup.isHidden = field != "metadata"
        caseButton.isHidden = CriteriaEditorView.numericFields.contains(field)
        dateButton.isHidden = !["modified", "created"].contains(field)
        valueField.isEnabled = dateRange == nil
        if let dateRange { valueField.stringValue = dateRange.title; valueField.toolTip = dateRange.timeZone }
        setFrameSize(NSSize(width: field == "metadata" ? 810 : dateButton.isHidden ? 650 : 730, height: 26))
        let placeholders = ["extension": "z. B. pdf (ohne Punkt)", "relativePath": "z. B. Dokumente/*.txt",
                            "size": "z. B. 2 MiB", "modified": "2026-01-01T00:00:00Z",
                            "created": "2026-01-01T00:00:00Z", "width": "Pixel", "height": "Pixel"]
        valueField.placeholderString = placeholders[field] ?? "Suchtext"
        valueField.toolTip = dateRange.map { $0.title + " · " + $0.timeZone + ". Verwendete ISO-Grenzen: Suchbericht." } ?? (["modified", "created"].contains(field)
            ? "ISO-Zeitpunkt mit Z oder Offset. Gleichheit und Obergrenze schließen die genannte Sekunde bzw. Minute ein."
            : nil)
    }
    @objc private func fieldChanged() {
        let field = fieldPopup.selectedItem?.representedObject as? String ?? "name"
        if !["modified", "created"].contains(field), dateRange != nil { dateRange = nil; valueField.stringValue = "" }
        let selected = operatorPopup.selectedItem?.representedObject as? String ?? "contains"
        refreshField(selectedOperator: selected)
        onFieldChange?()
        onChange?()
    }
    @objc private func changed() { onChange?() }
    @objc private func editDate() {
        guard let window, window.attachedSheet == nil, dateEditor == nil else { return }
        let editor = DateRangeEditor(spec: dateRange, title: "Datum der Bedingung")
        dateEditor = editor
        editor.present(on: window) { [weak self] result in
            guard let self else { return }; self.dateEditor = nil
            guard let result else { return }
            self.dateRange = result.0; self.valueField.stringValue = ""
            self.refreshField(selectedOperator: self.operatorPopup.selectedItem?.representedObject as? String ?? "equals")
            self.onChange?()
        }
    }
    func stopDateEditorForTermination() { dateEditor?.stopForTermination() }
}

final class CriteriaGroupView: NSPopUpButton {
    let nodeID: String
    var onChange: (() -> Void)?
    init(id: String, op: String = "and") {
        nodeID = id
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 26), pullsDown: false)
        for key in ["and", "or"] {
            addItem(withTitle: CriteriaEditorView.labels[key]!)
            lastItem?.representedObject = key
        }
        selectItem(withTitle: CriteriaEditorView.labels[op]!)
        target = self
        action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    var groupOperator: String { selectedItem?.representedObject as? String ?? "and" }
    @objc private func changed() { onChange?() }
}

final class CriteriaEditorView: NSStackView, NSRuleEditorDelegate {
    var allowedFields = CriteriaEditorView.fields
    let editor = NSRuleEditor(frame: NSRect(x: 0, y: 0, width: 850, height: 64))
    let scroll = NSScrollView()
    let issueLabel = NSTextField(wrappingLabelWithString: "")
    let addButton = NSButton(title: "Bedingung hinzufügen", target: nil, action: nil)
    let groupButton = NSButton(title: "Gruppe hinzufügen", target: nil, action: nil)
    let replaceButton = NSButton(title: "Neue Kriterien anlegen", target: nil, action: nil)
    var onChange: (() -> Void)?
    private var updating = false
    private var changeScheduled = false
    private var freshIDs: [Int: String] = [:]
    private var wrapperID = UUID().uuidString
    private var originalJSON: String?
    private var unsupportedJSON: String?
    private var validationMessage: String?
    private var editingAllowed = true

    static let fields = ["name", "extension", "relativePath", "content", "metadata", "finderTags", "finderComment",
                         "size", "modified", "created", "width", "height"]
    static let numericFields: Set<String> = ["size", "modified", "created", "width", "height"]
    func stopDateEditorsForTermination() {
        for row in 0..<editor.numberOfRows {
            editor.displayValues(forRow: row).compactMap { $0 as? CriteriaValueView }.forEach { $0.stopDateEditorForTermination() }
        }
    }
    static func operators(for field: String) -> [String] {
        numericFields.contains(field) ? ["atLeast", "atMost", "equals"] : ["contains", "equals", "glob", "regex"]
    }
    static func operatorTitle(_ key: String, field: String) -> String {
        if ["modified", "created"].contains(field) {
            let titles = ["atLeast": "am oder nach", "atMost": "am oder vor",
                          "not-atLeast": "vor", "not-atMost": "nach"]
            if let title = titles[key] { return title }
        }
        return labels[key] ?? key
    }
    static let labels = ["name": "Name", "extension": "Endung", "relativePath": "Relativer Pfad",
                         "contains": "enthält", "equals": "ist genau", "glob": "passt zu Glob",
                         "regex": "passt zu Regex", "not-contains": "enthält nicht",
                         "not-equals": "ist nicht", "not-glob": "passt nicht zu Glob",
                         "not-regex": "passt nicht zu Regex",
                         "content": "Inhalt", "metadata": "Metadaten", "finderTags": "Finder-Tag", "finderComment": "Finder-Kommentar", "size": "Dateigröße",
                         "modified": "Geändert", "created": "Erstellt", "width": "Bildbreite", "height": "Bildhöhe",
                         "atLeast": "ist mindestens", "atMost": "ist höchstens",
                         "not-atLeast": "ist kleiner als", "not-atMost": "ist größer als",
                         "and": "Alle Bedingungen (UND)", "or": "Mindestens eine Bedingung (ODER)"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        editor.delegate = self
        editor.nestingMode = .compound
        editor.canRemoveAllRows = false
        editor.rowHeight = 34
        editor.autoresizingMask = [.width]
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addButton.target = self
        addButton.action = #selector(addCondition)
        groupButton.target = self
        groupButton.action = #selector(addGroup)
        groupButton.toolTip = "Eine UND-/ODER-Untergruppe hinzufügen; in einer Zeile geht auch ⌥+"
        replaceButton.target = self
        replaceButton.action = #selector(replaceUnsupported)
        let buttons = NSStackView(views: [addButton, groupButton, replaceButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        issueLabel.textColor = .systemRed
        addArrangedSubview(buttons)
        addArrangedSubview(scroll)
        addArrangedSubview(issueLabel)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            issueLabel.widthAnchor.constraint(equalTo: widthAnchor),
            issueLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        replaceButton.isHidden = true
        loadJSON(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }

    override func layout() {
        super.layout()
        var requiredWidth: CGFloat = 740
        for row in 0..<editor.numberOfRows {
            var parent = editor.parentRow(forRow: row)
            var rowDepth = 0
            while parent >= 0 { rowDepth += 1; parent = editor.parentRow(forRow: parent) }
            let metadata = editor.displayValues(forRow: row).compactMap { $0 as? CriteriaValueView }
                .contains { $0.node.field == "metadata" }
            requiredWidth = max(requiredWidth, 740 + (metadata ? 160 : 0) + CGFloat(rowDepth) * 30)
        }
        editor.setFrameSize(NSSize(width: max(requiredWidth, scroll.contentSize.width),
                                   height: max(64, CGFloat(editor.numberOfRows) * editor.rowHeight)))
    }

    func loadJSON(_ text: String?) {
        originalJSON = text
        unsupportedJSON = nil
        validationMessage = nil
        if let text, let node = CriteriaNode.fromJSON(text) {
            rebuild(node)
        } else if text != nil {
            unsupportedJSON = text
            rebuild(CriteriaNode(groupOperator: "and", children: [CriteriaNode()]))
        } else {
            rebuild(CriteriaNode(groupOperator: "and", children: [CriteriaNode()]))
        }
        allowEditing(unsupportedJSON == nil)
        replaceButton.isHidden = unsupportedJSON == nil
        refreshIssue()
    }

    private func rebuild(_ node: CriteriaNode) {
        updating = true
        defer { updating = false; needsLayout = true }
        if editor.numberOfRows > 0 {
            editor.removeRows(at: IndexSet(integersIn: 0..<editor.numberOfRows), includeSubrows: true)
        }
        freshIDs.removeAll()
        append(node, parent: -1)
    }

    private func valueView(_ node: CriteriaNode) -> CriteriaValueView {
        let view = CriteriaValueView(id: node.id, field: node.field, op: node.matchOperator,
                                     value: node.value, caseSensitive: node.caseSensitive, negate: node.negate,
                                     metadataField: node.metadataField, allowedFields: allowedFields, dateRange: node.dateRange)
        view.onFieldChange = { [weak self, weak view] in
            guard let self, let view,
                  let row = (0..<self.editor.numberOfRows).first(where: {
                      self.editor.displayValues(forRow: $0).contains { ($0 as? CriteriaValueView) === view }
                  }) else { return }
            self.updating = true
            self.editor.setCriteria(["condition"], andDisplayValues: [view], forRowAt: row)
            self.updating = false
        }
        view.onChange = { [weak self] in self?.changed() }
        return view
    }

    private func groupView(_ node: CriteriaNode) -> CriteriaGroupView {
        let view = CriteriaGroupView(id: node.id, op: node.groupOperator ?? "and")
        view.onChange = { [weak self] in self?.changed() }
        return view
    }

    private func append(_ node: CriteriaNode, parent: Int) {
        let row = editor.numberOfRows
        if node.groupOperator != nil {
            editor.insertRow(at: row, with: .compound, asSubrowOfRow: parent, animate: false)
            editor.setCriteria(["group"], andDisplayValues: [groupView(node)], forRowAt: row)
            for child in node.children { append(child, parent: row) }
        } else {
            editor.insertRow(at: row, with: .simple, asSubrowOfRow: parent, animate: false)
            editor.setCriteria(["condition"], andDisplayValues: [valueView(node)], forRowAt: row)
        }
    }

    // AppKit verschiebt Zeilenindizes. Die Kennung liegt deshalb an den
    // individuellen Zeilenansichten. Eigene Popups liegen innerhalb dieser
    // Ansichten; AppKit verwaltet nur Hierarchie, Einrückung und +/-.
    func identifier(forRow row: Int) -> String {
        if row >= 0 && row < editor.numberOfRows {
            for value in editor.displayValues(forRow: row) {
                if let view = value as? CriteriaGroupView { return view.nodeID }
                if let view = value as? CriteriaValueView { return view.nodeID }
            }
        }
        if let id = freshIDs[row] { return id }
        let id = UUID().uuidString
        freshIDs[row] = id
        return id
    }

    func node(at row: Int) -> CriteriaNode? {
        let id = identifier(forRow: row)
        if editor.rowType(forRow: row) == .compound {
            guard let view = editor.displayValues(forRow: row).compactMap({ $0 as? CriteriaGroupView }).first
            else { return nil }
            let indices = editor.subrowIndexes(forRow: row)
            let children = indices.compactMap { node(at: $0) }
            guard children.count == indices.count else { return nil }
            return CriteriaNode(id: id, groupOperator: view.groupOperator, children: children)
        }
        guard let view = editor.displayValues(forRow: row).compactMap({ $0 as? CriteriaValueView }).first
        else { return nil }
        return view.node
    }

    var root: CriteriaNode? {
        let indices = editor.subrowIndexes(forRow: -1)
        let children = indices.compactMap { node(at: $0) }
        guard !children.isEmpty, children.count == indices.count else { return nil }
        return children.count == 1 ? children[0]
            : CriteriaNode(id: wrapperID, groupOperator: "and", children: children)
    }

    var queryJSON: String { unsupportedJSON ?? originalJSON ?? root?.json ?? "{}" }

    var inputIssue: String? {
        if unsupportedJSON != nil {
            return "Diese Kriterien lassen sich hier nicht bearbeiten. Sie bleiben vollständig erhalten."
        }
        guard let root else { return "Die Kriterien konnten nicht vollständig gelesen werden." }
        if root.identifiers.count > 256 {
            return "Die Kriterien sind insgesamt zu umfangreich. Bitte weniger oder kürzere Bedingungen verwenden."
        }
        var number = 0
        func issue(_ node: CriteriaNode, depth: Int) -> String? {
            if depth > 16 { return "Die Kriterien dürfen höchstens 16 Ebenen enthalten." }
            if node.groupOperator != nil {
                if node.children.isEmpty { return "Eine Gruppe enthält noch keine Bedingung." }
                for child in node.children { if let result = issue(child, depth: depth + 1) { return result } }
                return nil
            }
            number += 1
            if number > 128 { return "Höchstens 128 Bedingungen sind möglich." }
            if node.value.isEmpty && !(node.field == "extension" && node.matchOperator == "equals") {
                return "Bedingung \(number): Wert fehlt."
            }
            if node.value.utf8.count > 4096 || node.value.utf8.contains(0) {
                return "Bedingung \(number): Der Wert ist zu lang oder enthält ein NUL-Zeichen."
            }
            return nil
        }
        if let issue = issue(root, depth: 1) { return issue }
        return root.json.utf8.count > 64 * 1024
            ? "Die Kriterien sind insgesamt zu umfangreich. Bitte weniger oder kürzere Bedingungen verwenden."
            : nil
    }

    private func refreshIssue() {
        issueLabel.stringValue = inputIssue ?? validationMessage ?? ""
        needsLayout = true
    }

    private func changed() {
        guard !updating else { return }
        originalJSON = nil
        validationMessage = nil
        refreshIssue()
        onChange?()
    }

    private func insertionParent() -> Int {
        let selected = editor.selectedRowIndexes.first ?? 0
        guard selected < editor.numberOfRows else { return -1 }
        return editor.rowType(forRow: selected) == .compound
            ? selected : editor.parentRow(forRow: selected)
    }

    private func insertionIndex(parent: Int) -> Int {
        guard parent >= 0 else { return editor.numberOfRows }
        var index = parent + 1
        while index < editor.numberOfRows {
            var ancestor = editor.parentRow(forRow: index)
            while ancestor >= 0 && ancestor != parent { ancestor = editor.parentRow(forRow: ancestor) }
            if ancestor != parent { break }
            index += 1
        }
        return index
    }

    @objc func addCondition(_ sender: Any?) {
        let parent = insertionParent()
        let index = insertionIndex(parent: parent)
        editor.insertRow(at: index, with: .simple, asSubrowOfRow: parent, animate: true)
        editor.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc func addGroup(_ sender: Any?) {
        let parent = insertionParent()
        let index = insertionIndex(parent: parent)
        updating = true
        editor.insertRow(at: index, with: .compound, asSubrowOfRow: parent, animate: false)
        editor.insertRow(at: index + 1, with: .simple, asSubrowOfRow: index, animate: false)
        updating = false
        editor.selectRowIndexes(IndexSet(integer: index + 1), byExtendingSelection: false)
        freshIDs.removeAll()
        changed()
    }

    @objc private func replaceUnsupported() { loadJSON(nil); changed() }

    func allowEditing(_ allowed: Bool) {
        let allowed = allowed && unsupportedJSON == nil
        editingAllowed = allowed
        if editor.isEditable != allowed { editor.isEditable = allowed }
        addButton.isEnabled = allowed
        groupButton.isEnabled = allowed
        for row in 0..<editor.numberOfRows {
            for value in editor.displayValues(forRow: row) {
                if let view = value as? CriteriaValueView {
                    view.fieldPopup.isEnabled = allowed
                    view.operatorPopup.isEnabled = allowed
                    view.valueField.isEnabled = allowed
                    view.caseButton.isEnabled = allowed
                } else if let view = value as? CriteriaGroupView { view.isEnabled = allowed }
            }
        }
    }

    func showValidationIssue(_ message: String?) {
        var friendly = message
        var condition = 0
        for row in 0..<editor.numberOfRows where editor.rowType(forRow: row) == .simple {
            condition += 1
            friendly = friendly?.replacingOccurrences(of: "Bedingung " + identifier(forRow: row) + ":",
                                                       with: "Bedingung \(condition):")
        }
        validationMessage = friendly
        refreshIssue()
    }

    func preserveUnsupported(_ text: String) {
        unsupportedJSON = text
        allowEditing(false)
        replaceButton.isHidden = false
        refreshIssue()
    }

    func ruleEditor(_ editor: NSRuleEditor, numberOfChildrenForCriterion criterion: Any?,
                    with rowType: NSRuleEditor.RowType) -> Int { criterion == nil ? 1 : 0 }
    func ruleEditor(_ editor: NSRuleEditor, child index: Int, forCriterion criterion: Any?,
                    with rowType: NSRuleEditor.RowType) -> Any { rowType == .compound ? "group" : "condition" }
    func ruleEditor(_ editor: NSRuleEditor, displayValueForCriterion criterion: Any, inRow row: Int) -> Any {
        let id = identifier(forRow: row)
        return editor.rowType(forRow: row) == .compound
            ? groupView(CriteriaNode(id: id, groupOperator: "and")) : valueView(CriteriaNode(id: id))
    }
    func ruleEditorRowsDidChange(_ notification: Notification) {
        guard !updating, !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changeScheduled = false
            self.freshIDs.removeAll()
            self.allowEditing(self.editingAllowed)
            self.changed()
        }
    }
}

final class CriteriaControl: NSStackView {
    var isResultFilter = false
    let enabledButton = NSButton(checkboxWithTitle: "Zusätzliche Kriterien", target: nil, action: nil)
    let editButton = NSButton(title: "Bearbeiten…", target: nil, action: nil)
    let summaryLabel = NSTextField(labelWithString: "")
    var onChange: (() -> Void)?
    private var storedJSON: String?
    private(set) var sheet: NSWindow?
    private(set) var editingView: CriteriaEditorView?
    private var applyButton: NSButton?
    private var validationRun: SearchRunner?
    private var validationTask: DispatchWorkItem?
    private var validationGeneration = UUID()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        enabledButton.target = self
        enabledButton.action = #selector(toggleEnabled)
        editButton.target = self
        editButton.action = #selector(edit)
        summaryLabel.textColor = .secondaryLabelColor
        addArrangedSubview(enabledButton)
        addArrangedSubview(editButton)
        addArrangedSubview(summaryLabel)
        refreshSummary()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    var queryJSON: String? { enabledButton.state == .on ? storedJSON : nil }
    var isEditing: Bool { sheet != nil }

    func applyJSON(_ text: String?) {
        cancelValidation()
        if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .cancel) }
        storedJSON = text
        enabledButton.state = text == nil ? .off : .on
        refreshSummary()
    }

    private func refreshSummary() {
        if let text = queryJSON {
            summaryLabel.stringValue = CriteriaNode.fromJSON(text).map {
                "\($0.conditionCount) Bedingung\($0.conditionCount == 1 ? "" : "en")"
            } ?? "Nicht darstellbar"
        } else { summaryLabel.stringValue = "" }
    }

    @objc private func toggleEnabled() {
        if enabledButton.state == .on && storedJSON == nil { edit(nil); return }
        refreshSummary()
        onChange?()
    }

    @objc func edit(_ sender: Any?) {
        guard let parent = window, sheet == nil else { return }
        let view = CriteriaEditorView()
        if isResultFilter { view.allowedFields = CriteriaEditorView.fields.filter { !["content", "metadata"].contains($0) } }
        view.loadJSON(storedJSON)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = isResultFilter ? "Trefferliste filtern" : "Zusätzliche Suchkriterien"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 300)
        let help = NSTextField(wrappingLabelWithString: isResultFilter
            ? "Filtert nur die vorhandenen Treffer, ohne Dateien erneut zu lesen. Fehlende Fakten erfüllen auch negative Bedingungen nicht. Ein neuer Suchlauf setzt den Ansichtsfilter zurück."
            : "Diese Bedingungen gelten zusätzlich zur Suche oben. + fügt eine Bedingung hinzu, ⌥+ eine Gruppe. Fehlende oder nicht lesbare Werte erfüllen auch negative Bedingungen nicht.")
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancelEditing))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Übernehmen", target: self, action: #selector(applyEditing))
        apply.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [help, view, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
            view.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        editingView = view
        applyButton = apply
        apply.isEnabled = false
        view.onChange = { [weak self] in self?.validateDraft() }
        sheet = window
        parent.beginSheet(window) { [weak self, weak view] response in
            guard let self else { return }
            self.cancelValidation()
            if response == .OK, let view {
                self.storedJSON = view.queryJSON
                self.enabledButton.state = .on
                self.onChange?()
            } else if self.storedJSON == nil { self.enabledButton.state = .off }
            self.sheet = nil
            self.editingView = nil
            self.applyButton = nil
            self.refreshSummary()
        }
        validateDraft(initial: storedJSON != nil)
    }

    private func cancelValidation() {
        validationGeneration = UUID()
        validationTask?.cancel()
        validationTask = nil
        validationRun?.cancel()
        validationRun = nil
    }

    func stopForTermination() {
        editingView?.stopDateEditorsForTermination()
        validationRun?.stopForTermination(deadline: ProcessInfo.processInfo.systemUptime + 0.5)
        cancelValidation()
    }

    private func validateDraft(initial: Bool = false) {
        cancelValidation()
        applyButton?.isEnabled = false
        guard let view = editingView else { return }
        view.showValidationIssue(nil)
        if !initial, view.inputIssue != nil { return }
        let text = view.queryJSON
        guard let cli = findCLI() else {
            view.showValidationIssue("Der Suchkern wurde nicht gefunden.")
            return
        }
        if initial { view.allowEditing(false) }
        view.showValidationIssue("Kriterien werden geprüft…")
        let generation = validationGeneration
        let task = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, generation == self.validationGeneration else { return }
            let run = SearchRunner()
            self.validationRun = run
            run.start(arguments: ["-u", cli, self.isResultFilter ? "--validate-result-filter" : "--validate-criteria", "--criteria-json=" + text]
                      + DateRangeTransport.referenceArguments(DateRangeTransport.criteriaHasRanges(text) ? DateRangeTransport.referenceNow() : nil),
                      onBatch: { _, _ in }, completion: { [weak self, weak view] exit in
                guard let self, let view, generation == self.validationGeneration else { return }
                self.validationRun = nil
                let valid = exit.reason == .exit && exit.status == 0
                // Foundation verwirft doppelte JSON-Schlüssel beim Lesen. Ein
                // solcher Altstand darf deshalb nicht unbemerkt editierbar werden.
                if initial && exit.errorMessage?.contains("doppeltes JSON-Feld:") == true {
                    view.preserveUnsupported(text)
                } else if initial { view.allowEditing(true) }
                view.showValidationIssue(valid ? nil : (exit.errorMessage ?? "Die Kriterien konnten nicht geprüft werden."))
                self.applyButton?.isEnabled = valid && view.inputIssue == nil
            })
        }
        validationTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: task)
    }

    @objc private func cancelEditing() {
        if let sheet { sheet.sheetParent?.endSheet(sheet, returnCode: .cancel) }
    }
    @objc private func applyEditing() {
        guard applyButton?.isEnabled == true, editingView?.inputIssue == nil else { return }
        if let sheet { sheet.sheetParent?.endSheet(sheet, returnCode: .OK) }
    }
}
