import AppKit
import CryptoKit
import Darwin

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

final class ContentPreviewView: NSStackView {
    let toggle = NSButton(checkboxWithTitle: "Fundstellenvorschau", target: nil, action: nil)
    let sourceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "Treffer auswählen.")
    let textView = NSTextView()
    let restartButton = NSButton(title: "Mit Vorschau neu suchen", target: nil, action: nil)
    let body = NSStackView()
    let queryMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    let previousButton = NSButton(title: "Vorherige", target: nil, action: nil)
    let nextButton = NSButton(title: "Nächste", target: nil, action: nil)
    let contextButton = NSButton(title: "Mehr Kontext", target: nil, action: nil)
    let cancelButton = NSButton(title: "Abbrechen", target: nil, action: nil)
    let navigationBar = NSStackView()
    var onNavigate: ((Int, Bool) -> Void)?
    var onQueryChange: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggle: (() -> Void)?
    var onRestart: (() -> Void)?
    var enabled: Bool { toggle.state == .on }
    private var bodyHeight: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        toggle.target = self; toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("contentPreviewToggle")
        toggle.toolTip = "Erfasst begrenzte Fundzeilenausschnitte ab dem nächsten Suchlauf. Die Leertaste öffnet weiterhin Quick Look."
        restartButton.target = self; restartButton.action = #selector(restart)
        for (button, action, identifier) in [
            (previousButton, #selector(previous), "contentPreviewPrevious"),
            (nextButton, #selector(next), "contentPreviewNext"),
            (contextButton, #selector(context), "contentPreviewContext"),
            (cancelButton, #selector(cancel), "contentPreviewCancel")] {
            button.target = self; button.action = action
            button.controlSize = .small; button.font = .systemFont(ofSize: 11)
            button.setAccessibilityIdentifier(identifier)
        }
        queryMenu.target = self; queryMenu.action = #selector(queryChanged)
        queryMenu.controlSize = .small; queryMenu.font = .systemFont(ofSize: 11)
        queryMenu.setAccessibilityIdentifier("contentPreviewQuery")
        queryMenu.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        queryMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        navigationBar.orientation = .horizontal; navigationBar.spacing = 6
        for control in [queryMenu, previousButton, nextButton, contextButton, cancelButton] { navigationBar.addArrangedSubview(control) }
        previousButton.toolTip = "Vorherige Fundstelle des ausgewählten Begriffs oder Inhaltskriteriums."
        nextButton.toolTip = "Nächste Fundstelle in dieser Quelle; höchstens 64 MiB erneut lesen und fünf Sekunden einschließlich Auspacken."
        contextButton.toolTip = "Bis zu drei Zeilen davor und danach sowie mehr Text der Fundzeile laden."
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceLabel.font = .systemFont(ofSize: 11); sourceLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11); statusLabel.textColor = .secondaryLabelColor
        sourceLabel.setAccessibilityIdentifier("contentPreviewSource")
        statusLabel.setAccessibilityIdentifier("contentPreviewStatus")
        textView.isEditable = false; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor; textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("contentPreviewText")
        let scroll = NSScrollView()
        scroll.documentView = textView; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 4
        for view in [sourceLabel, statusLabel, navigationBar, scroll, restartButton] { body.addArrangedSubview(view) }
        addArrangedSubview(toggle); addArrangedSubview(body)
        for view in [body, sourceLabel, statusLabel, scroll] {
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        bodyHeight = body.heightAnchor.constraint(equalToConstant: 168); bodyHeight.isActive = true
        navigationBar.isHidden = true; cancelButton.isHidden = true
        syncVisibility()
        show("Treffer auswählen.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    func compact() { bodyHeight.constant = 140 }
    func syncVisibility() { body.isHidden = !enabled }
    @objc private func toggled() { syncVisibility(); onToggle?() }
    @objc private func restart() { onRestart?() }
    @objc private func previous() { onNavigate?(-1, false) }
    @objc private func next() { onNavigate?(1, false) }
    @objc private func context() { onNavigate?(0, true) }
    @objc private func cancel() { onCancel?() }
    @objc private func queryChanged() { onQueryChange?() }

    func navigation(queries: [ContentSnippet], occurrence: Int, loading: Bool = false, next: Bool = true) {
        navigationBar.isHidden = queries.allSatisfy { $0.query == nil }
        if queryMenu.numberOfItems != queries.count {
            queryMenu.removeAllItems()
            for snippet in queries {
                queryMenu.addItem(withTitle: (snippet.termIndex.map { "Begriff \($0)" } ?? "Bedingung") + ": " + snippet.label)
            }
        }
        let canLoad = queries.indices.contains(queryMenu.indexOfSelectedItem) && queries[queryMenu.indexOfSelectedItem].query != nil
        previousButton.isEnabled = !loading && canLoad && occurrence > 0
        nextButton.isEnabled = !loading && canLoad && next
        contextButton.isEnabled = !loading && canLoad
        queryMenu.isEnabled = !loading
        cancelButton.isHidden = !loading
    }

    func show(_ message: String, source: String = "", restart: Bool = false) {
        sourceLabel.stringValue = source; sourceLabel.toolTip = source
        statusLabel.stringValue = message; statusLabel.toolTip = message
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        restartButton.isHidden = !restart
        navigationBar.isHidden = true
    }

    func render(_ preview: ContentPreview, hit: Hit) {
        show("Quellstand geprüft · " + (preview.encoding ?? "?"), source: hit.path)
        let result = NSMutableAttributedString(string: "")
        var notes: [String] = []
        if preview.encoding == "vision-ocr-text-v1" { notes.append("OCR: erkannter Text, kein garantierter Originaltext; Bildbereiche sind ungefähr.") }
        if preview.encoding == "pdfkit-vision-text-v1" { notes.append("PDF: Textebenen bevorzugt; OCR textloser Seiten ist erkannt und nicht garantiert vollständig. Seitenbereiche sind ungefähr.") }
        var firstMatch: NSRange?
        func appendContext(_ line: ContentPreviewNavigation.ContextLine) {
            result.append(NSAttributedString(string: "Kontext · " + (line.documentPosition?.title ?? "Zeile \(line.line)") + (line.truncated ? " · gekürzt" : "") + "\n" + line.text + "\n\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        for line in preview.navigation?.contextLines ?? [] where line.line < (preview.snippets.first?.line ?? 0) { appendContext(line) }
        for snippet in preview.snippets {
            let label = snippet.termIndex.map { "Begriff \($0)" } ?? "Inhaltsbedingung"
            var title = label + " · " + snippet.label + " · " + (snippet.documentPosition?.title ?? "Zeile \(snippet.line)")
            if snippet.prefixTruncated || snippet.suffixTruncated { title += " · gekürzt" }
            if snippet.range?.length == 0 { title += " · leerer Treffer" }
            result.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            if let position = snippet.documentPosition, let confidence = position.ocrConfidence, let region = position.ocrRegion {
                let bounds = region.map { String(format: "%.3f", $0) }.joined(separator: ", ")
                result.append(NSAttributedString(string: String(format: "OCR-Modellwert %.2f · ", confidence) + (position.kind == "pdfOCR" ? "Seitenregion [" : "Bildregion [") + bounds + "] (x, y, Breite, Höhe; Ursprung unten links)\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            let offset = result.length
            result.append(NSAttributedString(string: snippet.text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.labelColor]))
            if firstMatch == nil {
                firstMatch = NSRange(location: offset + (snippet.range?.location ?? 0), length: snippet.range?.length ?? 0)
            }
            if let range = snippet.range, range.length > 0 {
                result.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.35),
                                      .underlineStyle: NSUnderlineStyle.single.rawValue],
                                     range: NSRange(location: offset + range.location, length: range.length))
            }
            if snippet.binding == "invalidDecoding" { notes.append("Ersatzzeichen: keine exakte Hervorhebung.") }
            if snippet.binding == "unavailable" { notes.append("Fundposition nicht begrenzt belegbar.") }
            if snippet.matchTruncated { notes.append("Langer Fundtext gekürzt.") }
            result.append(NSAttributedString(string: "\n\n"))
        }
        if let omitted = preview.omitted, omitted > 0 { notes.append("\(omitted) Belege wegen Vorschaugrenzen nicht gespeichert.") }
        if !notes.isEmpty {
            statusLabel.stringValue += " · " + Array(Set(notes)).sorted().joined(separator: " ")
            statusLabel.toolTip = statusLabel.stringValue
        }
        for line in preview.navigation?.contextLines ?? [] where line.line > (preview.snippets.last?.line ?? 0) { appendContext(line) }
        textView.textStorage?.setAttributedString(result)
        textView.scrollRangeToVisible(firstMatch ?? NSRange(location: 0, length: 0))
    }
}

final class SearchWindowViewport {
    private weak var window: NSWindow?
    private let heightLimit: NSLayoutConstraint
    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false

    init?(window: NSWindow) {
        guard let content = window.contentView else { return nil }
        self.window = window
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        heightLimit = content.heightAnchor.constraint(lessThanOrEqualToConstant: max(1, window.contentRect(forFrameRect: visible).height))
        heightLimit.isActive = true
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in self?.scheduleUpdate() })
        observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                                             object: window, queue: .main) { [weak self] _ in self?.heightLimit.isActive = false })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                             object: window, queue: .main) { [weak self] _ in
            self?.heightLimit.isActive = true
            self?.scheduleUpdate()
        })
        update()
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    private func update() {
        guard heightLimit.isActive, let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Weiche Vorschauhöhen allein verkleinern AppKits Fenster-Minimum nicht.
        let maximumHeight = max(1, window.contentRect(forFrameRect: visible).height)
        if heightLimit.constant != maximumHeight { heightLimit.constant = maximumHeight }
        var frame = window.frame
        frame.size.height = min(frame.height, visible.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != window.frame { window.setFrame(frame, display: window.isVisible) }
    }
}

final class FinderMetadataView: NSStackView {
    let toggle = NSButton(checkboxWithTitle: "Finder-Eigenschaften", target: nil, action: nil)
    let textView = NSTextView()
    let scroll = NSScrollView()
    private var hit: Hit?
    var enabled: Bool { toggle.state == .on }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        toggle.target = self; toggle.action = #selector(toggled)
        toggle.setAccessibilityIdentifier("finderMetadataToggle")
        toggle.toolTip = "Zeigt die erfassten Tags und den Kommentar dieses Suchstands. Die Quelle wird dabei nicht erneut gelesen."
        textView.isEditable = false; textView.isSelectable = true; textView.isRichText = true
        textView.isHorizontallyResizable = false; textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityIdentifier("finderMetadataText")
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        addArrangedSubview(toggle); addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 130)
        preferredHeight.priority = NSLayoutConstraint.Priority(749)
        preferredHeight.isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        syncVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }
    @objc private func toggled() { syncVisibility(); render(hit) }
    func syncVisibility() { scroll.isHidden = !enabled }
    static let colorNames = ["Ohne Farbe", "Grau", "Grün", "Violett", "Blau", "Gelb", "Rot", "Orange"]
    static let colors: [NSColor] = [.secondaryLabelColor, .systemGray, .systemGreen, .systemPurple, .systemBlue, .systemYellow, .systemRed, .systemOrange]
    static func singleLineSummary(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines).joined(separator: " ↵ ")
    }
    static func tags(_ snapshot: FinderMetadataSnapshot?, textColor: NSColor = .labelColor,
                     compact: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        guard let values = snapshot?.tags, !values.isEmpty else {
            return NSAttributedString(string: snapshot?.tagsText ?? "Nicht erfasst", attributes: [.foregroundColor: textColor])
        }
        for (index, tag) in values.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: ", ", attributes: [.foregroundColor: textColor])) }
            result.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: colors[tag.color ?? 0]]))
            result.append(NSAttributedString(string: compact ? singleLineSummary(tag.name) : tag.name,
                                             attributes: [.foregroundColor: textColor]))
        }
        return result
    }
    func render(_ hit: Hit?) {
        self.hit = hit
        let result = NSMutableAttributedString(string: "")
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        if let hit {
            result.append(NSAttributedString(string: "Erfasster Suchstand · keine erneute Quellenabfrage\n\nFinder-Tags\n", attributes: heading))
            let tags = NSMutableAttributedString(attributedString: Self.tags(hit.finderMetadata))
            tags.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: tags.length))
            result.append(tags)
            result.append(NSAttributedString(string: "\n\nFinder-Kommentar\n", attributes: heading))
            result.append(NSAttributedString(string: hit.finderMetadata?.commentText ?? "Nicht erfasst. Vor der nächsten Suche unter Weitere Filter die Finder-Eigenschaften einschalten.", attributes: body))
        } else { result.append(NSAttributedString(string: "Treffer auswählen.", attributes: body)) }
        textView.textStorage?.setAttributedString(result)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}

// Attributierte Tag-Namen übernehmen AppKits Auswahlfarbe nicht automatisch.
final class FinderTagsCellView: NSTableCellView {
    var snapshot: FinderMetadataSnapshot? { didSet { renderTags() } }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { renderTags() } }
    private func renderTags() {
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        textField?.attributedStringValue = FinderMetadataView.tags(snapshot, textColor: color, compact: true)
    }
}

final class ContentPreviewController {
    weak var owner: HitListController?
    let view = ContentPreviewView()
    private let queue = OperationQueue()
    private var check: BlockOperation?
    private var generation = 0
    private var selected: Hit?
    private var timer: Timer?
    private var displayed = false
    private var occurrence = 0
    private var requestEpoch = 0
    private var load: ContentPreviewLoad?
    var cliPath: String?
    var isLoading: Bool { load?.isLoading == true }

    func cancelLoad(message: String? = nil) {
        requestEpoch += 1
        load?.cancel(); load = nil
        if let message { view.statusLabel.stringValue = message; view.statusLabel.toolTip = message }
        if displayed, let preview = selected?.contentPreview {
            view.navigation(queries: preview.snippets, occurrence: occurrence)
        }
    }

    private func navigate(delta: Int, context: Bool) {
        guard view.enabled, displayed, let hit = selected, let original = hit.contentPreview,
              original.sourceGeneration != nil,
              original.snippets.indices.contains(view.queryMenu.indexOfSelectedItem),
              original.snippets[view.queryMenu.indexOfSelectedItem].query != nil,
              let cli = cliPath ?? findCLI() else { return }
        cancelLoad()
        let epoch = requestEpoch
        let index = view.queryMenu.indexOfSelectedItem
        let target = max(0, occurrence + delta)
        let localOnly = owner?.localOnlyContent == true
        view.statusLabel.stringValue = "Fundstelle wird geladen…"
        view.navigation(queries: original.snippets, occurrence: occurrence, loading: true)
        let load = ContentPreviewLoad(); self.load = load
        load.start(hit: hit, queryIndex: index, occurrence: target, context: context, localOnly: localOnly, cli: cli) { [weak self] outcome in
            guard let self, self.requestEpoch == epoch else { return }
            self.load = nil
            let response: ContentPreview
            switch outcome {
            case .sourceChanged: self.invalidateSource(hit); return
            case .failed(let message): self.cancelLoad(message: message); return
            case .ready(let preview): response = preview
            }
            guard let navigation = response.navigation else { self.cancelLoad(message: "Ungültige Nachladeantwort."); return }
            if response.status == "ready" {
                self.occurrence = target
                self.view.render(response, hit: hit)
                self.view.statusLabel.stringValue += " · Fundstelle \(target + 1)"
            }
            let reason = navigation.reason
            if reason == "end" { self.view.statusLabel.stringValue = "Keine weitere Fundstelle für diesen Begriff oder diese Bedingung." }
            if reason == "readLimit" { self.view.statusLabel.stringValue = "Nachladegrenze erreicht: höchstens 64 MiB / drei Sekunden im Leser." }
            if reason == "positionLimit" { self.view.statusLabel.stringValue = "Lange Zeile: weitere Positionen nicht begrenzt belegbar." }
            if reason == "documentUnavailable" { self.view.statusLabel.stringValue = "Dokument nicht nachladbar: " + (response.navigation?.documentMessage ?? "Dokumentleser nicht verfügbar") + "." }
            self.view.statusLabel.toolTip = self.view.statusLabel.stringValue
            self.view.navigation(queries: original.snippets, occurrence: self.occurrence, next: reason == "ready")
        }
    }

    private func invalidateSource(_ hit: Hit) {
        cancelLoad(); displayed = false
        view.show("Quelle wurde verändert oder ist nicht mehr verfügbar. Bitte neu suchen.", source: hit.path, restart: true)
    }

    init(owner: HitListController) {
        self.owner = owner
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
        view.onNavigate = { [weak self] delta, context in self?.navigate(delta: delta, context: context) }
        view.onCancel = { [weak self] in self?.cancelLoad(message: "Nachladen abgebrochen.") }
        view.onQueryChange = { [weak self] in
            guard let self, let hit = self.selected, let preview = hit.contentPreview else { return }
            self.cancelLoad(); self.occurrence = 0
            self.view.render(preview, hit: hit)
            self.view.navigation(queries: preview.snippets, occurrence: 0)
        }
        view.onToggle = { [weak self] in self?.selectionChanged(force: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.verifySource() }
    }

    deinit { timer?.invalidate(); queue.cancelAllOperations(); load?.cancel() }

    func selectionChanged(force: Bool = false) {
        let hit = owner.flatMap { owner in owner.selectedHitIndices.first.map { owner.hits[$0] } }
        if !force, hit == selected { return }
        cancelLoad(); occurrence = 0
        view.queryMenu.removeAllItems()
        generation += 1; check?.cancel(); check = nil; queue.cancelAllOperations()
        displayed = false
        selected = hit
        guard view.enabled else { view.show("Treffer auswählen."); return }
        guard let hit else { view.show("Treffer auswählen."); return }
        guard let preview = hit.contentPreview else {
            view.show("Für diesen Suchlauf wurde keine Vorschau erfasst.", source: hit.path, restart: true); return
        }
        switch preview.status {
        case "ready": view.show("Quellstand wird geprüft…", source: hit.path); verifySource()
        case "noContentEvidence": view.show("Kein positiver Inhaltsbeleg für diesen Treffer.", source: hit.path)
        case "sourceChanged": view.show("Quelle wurde verändert oder ist nicht mehr verfügbar. Bitte neu suchen.", source: hit.path, restart: true)
        case "budgetExceeded": view.show("Vorschaubudget dieses Suchlaufs ausgeschöpft (8 MiB).", source: hit.path)
        default: view.show("Vorschaubeleg ist ungültig oder wird nicht unterstützt.", source: hit.path)
        }
    }

    private func verifySource() {
        guard view.enabled, check == nil, let hit = selected, let preview = hit.contentPreview,
              preview.status == "ready", let expected = preview.sourceGeneration else { return }
        let epoch = generation
        let localOnly = owner?.localOnlyContent == true
        let operation = BlockOperation()
        check = operation
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let actual = ContentSourceGeneration.current(hit.filesystemPath, localOnly: localOnly)
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false, self.generation == epoch else { return }
                self.check = nil
                if actual == expected {
                    if !self.displayed { self.view.render(preview, hit: hit); self.view.navigation(queries: preview.snippets, occurrence: 0); self.displayed = true }
                } else {
                    self.invalidateSource(hit)
                }
            }
        }
        queue.addOperation(operation)
    }
}
