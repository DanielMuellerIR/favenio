import AppKit

final class DateRangeEditor: NSObject, NSTextFieldDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
    let choice = NSPopUpButton()
    let from = NSDatePicker()
    let to = NSDatePicker()
    let zone = NSTextField(string: TimeZone.current.identifier)
    let fromFold = NSPopUpButton()
    let toFold = NSPopUpButton()
    let proofLabel = NSTextField(wrappingLabelWithString: "")
    let applyButton = NSButton(title: "Übernehmen", target: nil, action: nil)
    let fixedButton = NSButton(title: "Aufgelöste Grenzen als festen Zeitraum übernehmen", target: nil, action: nil)
    private var request: SearchRunner?
    private var deadlineTask: DispatchWorkItem?
    private var calendarRow: NSStackView?
    private var foldRow: NSStackView?
    private var generation = UUID()
    private var resolved: (DateRangeSpec, Data)?
    private var completion: (((DateRangeSpec?, Data?)?) -> Void)?

    init(spec: DateRangeSpec?, title: String) {
        super.init()
        window.title = title; window.isReleasedWhenClosed = false
        choice.addItem(withTitle: "Fester Zeitraum · Kalender und Uhrzeit")
        for key in DateRangeSpec.presets { choice.addItem(withTitle: DateRangeSpec.titles[key]!); choice.lastItem?.representedObject = key }
        choice.target = self; choice.action = #selector(changed)
        choice.setAccessibilityIdentifier("date-range-choice")
        if let spec { zone.stringValue = spec.timeZone; if let preset = spec.preset { choice.selectItem(withTitle: DateRangeSpec.titles[preset]!) } }
        zone.delegate = self; zone.setAccessibilityLabel("IANA-Zeitzone"); zone.setAccessibilityIdentifier("date-range-zone")
        var initialWall = Date()
        if let displayZone = TimeZone(identifier: zone.stringValue) {
            let display = Self.wallFormatter(); display.timeZone = displayZone
            initialWall = Self.wallFormatter().date(from: display.string(from: initialWall)) ?? initialWall
        }
        for (picker, id) in [(from, "date-range-from"), (to, "date-range-to")] {
            picker.datePickerStyle = .clockAndCalendar
            picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            picker.timeZone = TimeZone(secondsFromGMT: 0)
            picker.calendar = Calendar(identifier: .gregorian)
            picker.dateValue = initialWall
            picker.target = self; picker.action = #selector(changed)
            picker.setAccessibilityIdentifier(id)
        }
        if let spec, spec.kind == "fixed", let timeZone = TimeZone(identifier: spec.timeZone) {
            for (picker, raw) in [(from, spec.lower), (to, spec.upper)] {
                if let raw, let instant = Self.isoDate(raw) {
                    let display = Self.wallFormatter(); display.timeZone = timeZone
                    if let wall = Self.wallFormatter().date(from: display.string(from: instant)) { picker.dateValue = wall }
                }
            }
        }
        for (popup, key) in [(fromFold, "from"), (toFold, "to")] {
            popup.addItems(withTitles: ["Eindeutige Ortszeit", "Frühere Ortszeit (fold 0)", "Spätere Ortszeit (fold 1)"])
            popup.target = self; popup.action = #selector(changed); popup.setAccessibilityIdentifier("date-range-fold-" + key)
        }
        let calendars = NSStackView(views: [Self.column("Von (inklusive)", from), Self.column("Bis (ganze Sekunde inklusive)", to)])
        calendarRow = calendars
        calendars.spacing = 24; calendars.alignment = .top
        let zoneRow = NSStackView(views: [NSTextField(labelWithString: "Zeitzone"), zone]); zoneRow.spacing = 8
        let folds = NSStackView(views: [NSTextField(labelWithString: "Von"), fromFold, NSTextField(labelWithString: "Bis"), toFold]); folds.spacing = 8; foldRow = folds
        let hint = NSTextField(wrappingLabelWithString: "Relative Vorlagen werden bei jedem neuen Start aufgelöst. Kalenderwerte gelten in der angegebenen Zeitzone. Fehlende oder zweideutige Ortszeiten werden vom Suchkern geprüft.")
        hint.font = .systemFont(ofSize: 11)
        proofLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        proofLabel.setAccessibilityIdentifier("date-range-proof")
        let check = NSButton(title: "Grenzen prüfen", target: self, action: #selector(validate))
        check.setAccessibilityIdentifier("date-range-check")
        let raw = NSButton(title: "Rohe ISO-Eingabe", target: self, action: #selector(useRaw))
        let cancel = NSButton(title: "Abbrechen", target: self, action: #selector(cancel)); cancel.keyEquivalent = "\u{1b}"
        applyButton.target = self; applyButton.action = #selector(apply); applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityIdentifier("date-range-apply")
        fixedButton.target = self; fixedButton.action = #selector(applyFixed)
        fixedButton.setAccessibilityIdentifier("date-range-fixed")
        let footer = NSStackView(views: [raw, check, cancel, applyButton]); footer.spacing = 8
        let stack = NSStackView(views: [choice, calendars, zoneRow, folds, hint, proofLabel, fixedButton, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -20),
            zone.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            proofLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        refresh()
    }
    private static func column(_ title: String, _ view: NSView) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), view]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6; return stack
    }
    private static func wallFormatter() -> DateFormatter {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }
    private static func isoDate(_ value: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    func present(on parent: NSWindow, completion: @escaping (((DateRangeSpec?, Data?)?) -> Void)) {
        self.completion = completion; parent.beginSheet(window); validate()
    }
    private func refresh() {
        let fixed = choice.selectedItem?.representedObject == nil
        from.isEnabled = fixed; to.isEnabled = fixed; fromFold.isEnabled = fixed; toFold.isEnabled = fixed
        calendarRow?.isHidden = !fixed; foldRow?.isHidden = !fixed
        applyButton.isEnabled = resolved != nil
        fixedButton.isEnabled = resolved?.0.kind == "relative"
        window.setContentSize(NSSize(width: 650, height: fixed ? 510 : 330))
    }
    func controlTextDidChange(_ notification: Notification) { invalidate() }
    private func invalidate() { generation = UUID(); deadlineTask?.cancel(); deadlineTask = nil; request?.cancel(); request = nil; resolved = nil; proofLabel.stringValue = "Grenzen erneut prüfen."; refresh() }
    @objc private func changed() { invalidate(); validate() }
    @objc func validate() {
        invalidate()
        guard let cli = findCLI() else { proofLabel.stringValue = "Suchkern nicht gefunden."; return }
        let timeZone = zone.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = choice.selectedItem?.representedObject as? String
        var question: [String: Any]
        if let preset { question = DateRangeSpec(kind: "relative", timeZone: timeZone, preset: preset).object }
        else {
            question = ["kind": "calendar", "timeZone": timeZone, "fromLocal": Self.wallFormatter().string(from: from.dateValue), "toLocal": Self.wallFormatter().string(from: to.dateValue)]
            if fromFold.indexOfSelectedItem > 0 { question["fromFold"] = fromFold.indexOfSelectedItem - 1 }
            if toFold.indexOfSelectedItem > 0 { question["toFold"] = toFold.indexOfSelectedItem - 1 }
        }
        guard let text = DateRangeTransport.text(question) else { proofLabel.stringValue = "Datumsauftrag ist zu groß."; return }
        let token = generation, runner = SearchRunner(); request = runner
        var answer: Data?
        var timedOut = false
        let deadlineTask = DispatchWorkItem { [weak self, weak runner] in
            guard let self, let runner, self.generation == token, self.request === runner else { return }
            timedOut = true; runner.cancel()
        }
        self.deadlineTask = deadlineTask; DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: deadlineTask)
        proofLabel.stringValue = "Kalendergrenzen werden im Suchkern geprüft…"
        runner.start(arguments: ["-u", cli, "--resolve-date-range=" + text] + DateRangeTransport.referenceArguments(DateRangeTransport.referenceNow()),
                     onBatch: { _, _ in }, onDateResolution: { answer = $0 }, completion: { [weak self, weak runner] exit in
            guard let self, let runner, self.request === runner, self.generation == token else { return }
            self.request = nil
            self.deadlineTask?.cancel(); self.deadlineTask = nil
            guard exit.reason == .exit, exit.status == 0, let answer,
                  let object = preservedJSONObject(answer) as? [String: Any],
                  let entry = (object["entries"] as? [[String: Any]])?.first,
                  let lower = entry["lowerISO"] as? String, let upper = entry["upperISO"] as? String else {
                self.proofLabel.stringValue = timedOut ? "Kalenderprüfung überschreitet acht Sekunden." : (exit.errorMessage ?? "Der Suchkern lieferte keinen gültigen Datumsbeleg."); self.refresh(); return
            }
            let spec = preset.map { DateRangeSpec(kind: "relative", timeZone: timeZone, preset: $0) }
                ?? DateRangeSpec(kind: "fixed", timeZone: timeZone, lower: lower, upper: upper)
            self.resolved = (spec, answer)
            self.proofLabel.stringValue = "Ab: \(lower)\nBis: \(upper) (inklusive)\nZone: \(timeZone) · Bezug: \(object["referenceISO"] as? String ?? "fest")"
            self.refresh()
        })
    }
    private func finish(_ value: (DateRangeSpec?, Data?)?) {
        deadlineTask?.cancel(); deadlineTask = nil
        request?.cancel(); request = nil; generation = UUID()
        let callback = completion; completion = nil
        window.sheetParent?.endSheet(window); window.orderOut(nil); callback?(value)
    }
    @objc private func useRaw() { finish((nil, nil)) }
    @objc private func cancel() { finish(nil) }
    @objc private func apply() { guard let resolved else { return }; finish((resolved.0, resolved.1)) }
    func stopForTermination() { deadlineTask?.cancel(); request?.stopForTermination(deadline: ProcessInfo.processInfo.systemUptime + 0.5); request = nil }
    deinit { deadlineTask?.cancel(); request?.cancel() }
    @objc private func applyFixed() {
        guard let resolved, resolved.0.kind == "relative", let object = preservedJSONObject(resolved.1) as? [String: Any],
              let entry = (object["entries"] as? [[String: Any]])?.first,
              let lower = entry["lowerISO"] as? String, let upper = entry["upperISO"] as? String else { return }
        finish((DateRangeSpec(kind: "fixed", timeZone: resolved.0.timeZone, lower: lower, upper: upper), resolved.1))
    }
}
