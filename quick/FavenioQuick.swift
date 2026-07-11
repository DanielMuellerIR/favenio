// FavenioQuick.app — die Mini-Schnellsuche für die Finder-Toolbar.
//
// Gedacht als Spotlight-Ersatz zum In-die-Toolbar-Ziehen (Cmd-Drag der
// App in die Finder-Kopfleiste, wie bei den nc_pin-Droplets):
//
//   Klick aufs Toolbar-Icon  → kleines schwebendes Eingabefeld
//   Return                   → Suche läuft (Namenssuche im Benutzerordner,
//                              Archive eingeschlossen)
//   Treffer vorhanden        → die große Favenio.app öffnet sich mit der
//                              fertigen Trefferliste (kein Doppel-Suchlauf:
//                              die Treffer werden als JSONL-Datei übergeben)
//   keine Treffer            → kurze Meldung im Feld, Panel bleibt offen
//   Esc (bei leerem Feld)    → App beendet sich
//
// Die App ist ein "Accessory" (LSUIElement): kein Dock-Icon, kein
// Menübalken-Wechsel — sie erscheint nur als schwebendes Feld.

import AppKit

@main
struct FavenioQuickApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = QuickController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class QuickController: NSObject, NSApplicationDelegate,
                             NSWindowDelegate {

    var panel: NSPanel!
    let field = NSSearchField()
    let infoLabel = NSTextField(labelWithString:
        "Return sucht in deinem Benutzerordner · Esc beendet")
    let spinner = NSProgressIndicator()
    var searching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(appName: "Favenio Schnellsuche")
        buildPanel()
        showPanel()

        // Esc bei LEEREM Feld beendet die App; mit Text drin macht Esc
        // das Übliche (Feld leeren) — wie bei Spotlight.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53,                       // 53 = Escape
               let self, self.field.stringValue.isEmpty {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }

    /// Erneuter Klick aufs Toolbar-Icon, während die App schon läuft.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        showPanel()
        return true
    }

    /// Panel geschlossen (rotes Knöpfchen) → App ganz beenden,
    /// der nächste Toolbar-Klick startet sie frisch.
    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    // ---------- Aufbau ----------

    func buildPanel() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 92),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating              // schwebt über allen Fenstern
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        guard let content = panel.contentView else { return }

        field.placeholderString = "Favenio-Schnellsuche…"
        field.font = NSFont.systemFont(ofSize: 18)
        field.target = self
        field.action = #selector(fire)

        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let infoRow = NSStackView(views: [spinner, infoLabel])
        infoRow.orientation = .horizontal
        infoRow.spacing = 6

        let stack = NSStackView(views: [field, infoRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: 14),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -14),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 34),
        ])

        // Oben-mittig auf dem Bildschirm platzieren (Spotlight-Gefühl).
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - 250,
                y: visible.maxY - 180))
        }
    }

    func showPanel() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    // ---------- Suche + Übergabe an die große GUI ----------

    @objc func fire() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !searching else { return }
        searching = true
        spinner.startAnimation(nil)
        infoLabel.stringValue = "Suche läuft… (Esc nach Abbruch: Feld leeren)"

        let home = NSHomeDirectory()
        // Die Suche blockierend im Hintergrund-Thread laufen lassen,
        // damit das Panel bedienbar bleibt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let arguments = searchArguments(
                pattern: query, root: home, content: false, regex: false,
                caseSensitive: false, archives: true)
            else {
                DispatchQueue.main.async {
                    self?.finish(query: query, count: 0, raw: nil,
                                 errorText: "favenio.py nicht gefunden.")
                }
                return
            }
            let result = runSearchSync(arguments: arguments)
            DispatchQueue.main.async {
                self?.finish(query: query, count: result.hits.count,
                             raw: result.raw, errorText: nil)
            }
        }
    }

    func finish(query: String, count: Int, raw: Data?, errorText: String?) {
        searching = false
        spinner.stopAnimation(nil)
        if let errorText {
            infoLabel.stringValue = errorText
            return
        }
        guard count > 0, let raw else {
            // Kernidee der Schnellsuche: OHNE Treffer bleibt alles klein.
            infoLabel.stringValue = "Keine Treffer für „\(query)“."
            return
        }
        // Treffer als JSONL-Datei ablegen und der großen GUI übergeben.
        let resultsFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("favenio-quick-\(UUID().uuidString).jsonl")
        do { try raw.write(to: resultsFile) } catch {
            infoLabel.stringValue = "Konnte Treffer nicht zwischenspeichern."
            return
        }
        openMainApp(query: query, root: NSHomeDirectory(),
                    resultsFile: resultsFile)
    }

    func openMainApp(query: String, root: String, resultsFile: URL) {
        // Weg 1: URL-Schema — funktioniert, sobald Favenio.app einmal
        // bei LaunchServices registriert ist (auch wenn sie schon läuft).
        var components = URLComponents()
        components.scheme = "favenio"
        components.host = "results"
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "root", value: root),
            URLQueryItem(name: "file", value: resultsFile.path),
        ]
        if let url = components.url, NSWorkspace.shared.open(url) {
            NSApp.terminate(nil)
            return
        }
        // Weg 2 (Fallback): Favenio.app direkt starten und die Treffer
        // als Startargumente mitgeben.
        guard let appURL = locateMainApp() else {
            infoLabel.stringValue =
                "Favenio.app nicht gefunden — bitte einmal manuell starten."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--query", query,
                                   "--results-file", resultsFile.path]
        NSWorkspace.shared.openApplication(at: appURL,
                                           configuration: configuration) {
            _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Die große Favenio.app finden: über die Bundle-ID (LaunchServices)
    /// oder als Nachbarin im selben Ordner wie diese App.
    func locateMainApp() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "local.favenio") {
            return url
        }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Favenio.app")
        if FileManager.default.fileExists(atPath: sibling.path) {
            return sibling
        }
        return nil
    }
}
