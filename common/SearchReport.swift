import AppKit
import CoreFoundation

struct SearchReportSnapshot {
    var object: [String: Any]
    static let byteLimit = 262_144

    static func parse(_ data: Data) -> Self? {
        func boolean(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        guard data.count <= byteLimit, !DateRangeTransport.hasDuplicateKeys(data),
              let object = preservedJSONObject(data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber, !boolean(version), version.doubleValue == 1,
              let id = object["runID"] as? String, UUID(uuidString: id) != nil,
              let state = object["state"] as? String, ["running", "finished", "cancelled", "failed"].contains(state),
              object["counting"] as? String == "events",
              object["configuration"] is [String: Any],
              let reasons = object["reasons"] as? [[String: Any]], reasons.count <= 64,
              object["dateResolution"] == nil || DateRangeTransport.resolution(object["dateResolution"]!) != nil else { return nil }
        var ids = Set<String>()
        for reason in reasons {
            guard let id = reason["id"] as? String, !id.isEmpty, id.utf8.count <= 80, ids.insert(id).inserted,
                  let category = reason["category"] as? String, ["intentional", "readError", "budget"].contains(category),
                  let label = reason["label"] as? String, label.utf8.count <= 512,
                  let count = reason["count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
                  count.doubleValue >= 0, count.doubleValue <= 9_007_199_254_740_991,
                  count.doubleValue.rounded() == count.doubleValue,
                  boolean(reason["countCapped"]),
                  let examples = reason["examples"] as? [[String: Any]], examples.count <= 3,
                  examples.allSatisfy({ example in
                      guard let path = example["path"] as? String else { return false }
                      return path.unicodeScalars.count <= 256 && boolean(example["truncated"])
                  }) else { return nil }
        }
        return Self(object: object)
    }

    var state: String { object["state"] as? String ?? "unavailable" }
    var reasons: [[String: Any]] { object["reasons"] as? [[String: Any]] ?? [] }
    var coverage: String {
        state == "finished" && reasons.isEmpty && object["coverage"] as? String == "withinRequestedScope"
            ? "withinRequestedScope" : "incomplete"
    }
    var summary: String {
        switch state {
        case "running": return "Suche läuft – vorläufiger Bericht"
        case "finished": return coverage == "incomplete" ? "Suche beendet – Abdeckung eingeschränkt" : "Suchlauf im angefragten Umfang beendet"
        case "cancelled": return "Suche abgebrochen – Abdeckung unvollständig"
        case "limitReached": return "20-Treffer-Grenze erreicht – Abdeckung unvollständig"
        case "failed": return "Suche fehlgeschlagen – Abdeckung unvollständig"
        case "recorded": return "Übernommene Treffer – kein Bericht des ursprünglichen Suchlaufs"
        default: return "Bericht noch nicht verfügbar – Abdeckung unbekannt"
        }
    }
    func ending(_ state: String, warningCount: Int? = nil, error: String? = nil) -> Self {
        var result = self
        result.object["state"] = state
        result.object["observedAt"] = Date().timeIntervalSince1970
        if let warningCount { result.object["warningCount"] = warningCount }
        if let error { result.object["error"] = error }
        if state != "finished" || (warningCount ?? 0) > 0 { result.object["coverage"] = "incomplete" }
        return result
    }
    var exportObject: [String: Any] {
        var result = object
        result["coverage"] = coverage
        result["exportedAt"] = Date().timeIntervalSince1970
        return result
    }
    static func pending(configuration: [String: Any], state: String = "unavailable") -> Self {
        Self(object: ["type": "searchReport", "schemaVersion": 1, "runID": UUID().uuidString,
                      "startedAt": Date().timeIntervalSince1970, "state": state,
                      "coverage": "incomplete", "counting": "events", "source": "frontend",
                      "configuration": configuration, "reasons": [[String: Any]]()])
    }
    private var configurationText: String {
        guard let config = object["configuration"] as? [String: Any] else { return "Unbekannt." }
        func quoted(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else { return "–" }
            return String(decoding: data, as: UTF8.self)
        }
        if config["truncated"] as? Bool == true {
            return "Konfiguration überschreitet die Berichtsgrenze und ist gekürzt. Der Export enthält nur den ausdrücklich gekennzeichneten Anfang; vollständige Kriterien sind daraus nicht rekonstruierbar."
        }
        // Nur Darstellung der vom Kern gelieferten Optionen, keine Auswertung.
        guard config["paths"] != nil else { return "Kernbericht steht aus. Auftrag:\n" + quoted(config) }
        let mode = config["metadata"] as? Bool == true || !(config["metadata_field"] as? [String] ?? []).isEmpty
            ? "Metadaten" : (config["document_text"] as? Bool == true ? "Dokumenttext" : (config["content"] as? Bool == true ? "Inhalt" : "Name"))
        var lines = ["Suchziel: " + mode, "Suchordner/-dateien: " + quoted(config["paths"] ?? []),
                     "Muster: " + quoted(config["pattern"] ?? NSNull()), "Weitere Begriffe (UND): " + quoted(config["term"] ?? []),
                     "Kodierung: " + quoted(config["encoding"] ?? "utf-8"), "Ausschlüsse: " + quoted(config["exclude"] ?? [])]
        for (key, label) in [("regex", "Regulärer Ausdruck"), ("case_sensitive", "Groß-/Kleinschreibung"),
                             ("exact", "Ganzes Ziel"), ("literal_wildcards", "Platzhalter wörtlich"), ("hidden", "Versteckte Bereiche einbeziehen"), ("local_only", "Nur lokal vorhandene Inhalte lesen"), ("ocr", "Bild-OCR im Dokumenttext (Deutsch/Englisch)")] {
            lines.append(label + ": " + (config[key] as? Bool == true ? "Ja" : "Nein"))
        }
        for (key, label) in [("only", "Datei-/Ordnertyp"), ("max_depth", "Ordner-Tiefengrenze"), ("effectiveArchiveDepth", "Archiv-Tiefengrenze"),
                             ("max_archive_member_bytes", "Entpackte Einzelgrenze (Bytes)"), ("max_archive_total_bytes", "Entpacktes Gesamtbudget (Bytes)"),
                             ("max_archive_ratio", "Maximales Kompressionsverhältnis"), ("min_size", "Mindestgröße"), ("max_size", "Höchstgröße"),
                             ("min_width", "Mindestbreite"), ("max_width", "Höchstbreite"), ("min_height", "Mindesthöhe"), ("max_height", "Höchsthöhe"),
                             ("modified_from", "Geändert ab"), ("modified_to", "Geändert bis"), ("created_from", "Erstellt ab"), ("created_to", "Erstellt bis"),
                             ("metadata_field", "Metadatenfelder")] {
            if let value = config[key], !(value is NSNull) { lines.append(label + ": " + quoted(value)) }
        }
        if let criteria = config["criteria"], !(criteria is NSNull) { lines.append("Zusätzlicher Kriterienbaum:\n" + quoted(criteria)) }
        if let limits = config["fixedLimits"] { lines.append("Feste Leser-/Kataloggrenzen:\n" + quoted(limits)) }
        return lines.joined(separator: "\n")
    }
    var displayText: String {
        func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var lines = ["Laufkennung: \(object["runID"] as? String ?? "–")"]
        if let started = object["startedAt"] as? Double { lines.append("Beginn: " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started))) }
        if let at = object["capturedAt"] as? Double { lines.append("Kernstand: " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at))) }
        if let error = object["error"] as? String { lines.append("Fehler: " + error) }
        if let dates = object["dateResolution"] { lines.append("\nTatsächlich verwendete Kalendergrenzen (inklusive)\n" + json(dates)) }
        lines.append("\nGezählt werden Ereignisse, keine eindeutigen Objekte. Ausgelassene Teilbäume haben eine unbekannte Größe. Gekürzte Beispiele sind Anzeigetexte, keine vollständigen Pfade oder Archividentitäten.")
        for (category, title) in [("intentional", "Absichtlich ausgelassen"), ("readError", "Technische Einschränkungen"), ("budget", "Ausgeschöpfte Budgets")] {
            let items = reasons.filter { $0["category"] as? String == category }
            lines.append("\n" + title)
            if items.isEmpty { lines.append("Keine Ereignisse gemeldet.") }
            for item in items {
                let count = (item["count"] as? NSNumber)?.stringValue ?? "0"
                lines.append("\(item["label"] as? String ?? "") [\(item["id"] as? String ?? "")]: \(item["countCapped"] as? Bool == true ? "mindestens " : "")\(count) \(count == "1" ? "Ereignis" : "Ereignisse")")
                for example in item["examples"] as? [[String: Any]] ?? [] {
                    // JSON-Quoting hält Zeilenumbrüche und Steuerzeichen sichtbar.
                    lines.append("  " + json(example["path"] ?? "") + (example["truncated"] as? Bool == true ? " … [gekürzt]" : ""))
                }
                lines.append("  Höchstens drei Beispiele; weitere Ereignisse werden nur gezählt.")
            }
        }
        lines.append("\nKriterien und Grenzen des Laufs\n" + configurationText)
        lines.append("\nBerichtsgrenzen\n" + json(object["reportLimits"] ?? [:]))
        lines.append("\nDer Lauf prüft die angefragten Kriterien und darf nach einem ausreichenden Treffer früh aufhören. Dieser Bericht ist kein Nachweis vollständig gelesener oder unbeschädigter Inhalte. Ein laufender, abgebrochener oder eingeschränkter Lauf belegt keine vollständige Abdeckung.")
        return lines.joined(separator: "\n")
    }
}

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
