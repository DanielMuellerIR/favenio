import AppKit

final class SearchReportController: NSObject {
    weak var owner: HitListController?
    let button = NSButton(title: "Suchbericht…", target: nil, action: nil)
    private(set) var snapshot: SearchReportSnapshot?
    private var panel: NSPanel?
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView()
    private let exportButton = NSButton(title: "Bericht exportieren…", target: nil, action: nil)
    private let exportNote = NSTextField(labelWithString: "")
    private(set) var isSaving = false
    private var renderedRunID: String?

    init(owner: HitListController) {
        self.owner = owner
        super.init()
        button.target = self; button.action = #selector(show)
        button.bezelStyle = .rounded; button.controlSize = .small
        button.font = .systemFont(ofSize: 11); button.isEnabled = false
        button.setAccessibilityIdentifier("searchReportButton")
    }
    func reset() { snapshot = nil; refresh() }
    func begin(configuration: [String: Any], state: String = "running") {
        snapshot = .pending(configuration: configuration, state: state); refresh()
    }
    func accept(_ report: SearchReportSnapshot) { snapshot = report; refresh() }
    func end(_ state: String, exit: SearchExit? = nil) {
        if let report = exit?.report { snapshot = report }
        if let snapshot {
            self.snapshot = snapshot.ending(state, warningCount: exit?.warningCount,
                                             error: exit?.errorMessage)
        }
        refresh()
    }
    private func refresh() {
        button.isEnabled = snapshot != nil
        button.toolTip = snapshot?.summary ?? "Noch kein Suchlauf."
        guard panel != nil else { return }
        titleLabel.stringValue = snapshot?.summary ?? "Kein Suchbericht für die aktuelle Trefferliste"
        let runID = snapshot?.object["runID"] as? String
        let sameRun = runID != nil && runID == renderedRunID
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        let selection = textView.selectedRange()
        let text = snapshot?.displayText ?? "Ein neuer Suchlauf erstellt einen Bericht. Übernommene Treffer enthalten keinen Bericht des ursprünglichen Laufs."
        if textView.string != text {
            textView.string = text
            if sameRun {
                let count = textView.string.utf16.count
                textView.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
                if let origin { textView.enclosingScrollView?.contentView.scroll(to: origin) }
            }
        }
        renderedRunID = runID
        exportButton.isEnabled = snapshot != nil && !isSaving && owner?.exportWriter.isWriting == false
    }
    @objc func show() {
        guard let owner, snapshot != nil else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Suchbericht – Favenio"; window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 380)
            window.level = owner.window?.level ?? .normal
            window.appearance = owner.window?.appearance
            titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            titleLabel.setAccessibilityIdentifier("searchReportSummary")
            textView.isEditable = false; textView.isRichText = false
            textView.font = .systemFont(ofSize: 12)
            textView.textColor = .labelColor; textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.autoresizingMask = [.width]; textView.isVerticallyResizable = true
            textView.textContainer?.widthTracksTextView = true
            textView.setAccessibilityIdentifier("searchReportText")
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder; scroll.documentView = textView
            exportButton.target = self; exportButton.action = #selector(export)
            exportButton.setAccessibilityIdentifier("searchReportExport")
            exportNote.font = .systemFont(ofSize: 11); exportNote.textColor = .secondaryLabelColor
            exportNote.lineBreakMode = .byTruncatingMiddle
            let actions = NSStackView(views: [exportNote, exportButton])
            actions.orientation = .horizontal; actions.spacing = 12
            exportNote.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [titleLabel, scroll, actions])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            let content = NSView(); window.contentView = content
            stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
                titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)])
            panel = window; window.center()
        }
        refresh(); panel?.makeKeyAndOrderFront(nil)
    }
    @objc func export() {
        guard let snapshot, let panel, let owner, !isSaving, !owner.exportWriter.isWriting,
              owner.window?.attachedSheet == nil, panel.attachedSheet == nil else { return }
        // Der Stand wird vor dem Dialog festgehalten, auch während einer Suche.
        let object = snapshot.exportObject
        let save = NSSavePanel(); save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "Favenio-Suchbericht.json"
        isSaving = true; refresh()
        save.beginSheetModal(for: panel) { [weak self, weak owner] response in
            guard let self, let owner else { return }
            guard response == .OK, let destination = save.url else { self.isSaving = false; self.refresh(); return }
            let started = owner.exportWriter.writeJSON(object, to: destination) { [weak self] result in
                guard let self else { return }
                self.isSaving = false
                switch result {
                case .success: self.exportNote.stringValue = "Bericht gespeichert."
                case .failure(let error): self.exportNote.stringValue = "Export fehlgeschlagen: " + error.localizedDescription
                }
                self.exportNote.toolTip = self.exportNote.stringValue; self.refresh()
            }
            if !started { self.isSaving = false; self.exportNote.stringValue = "Ein anderer Export läuft bereits."; self.refresh() }
        }
    }
}
