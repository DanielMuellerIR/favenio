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
        "Return startet die Suche · Esc beendet")
    let spinner = NSProgressIndicator()
    let scopePopup = NSPopUpButton()   // wo gesucht wird: Finder-Ordner / ~
    var searching = false
    var searchRoot = NSHomeDirectory() // Wurzel des laufenden Suchlaufs

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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 104),
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
        // Die Info-Zeile darf schrumpfen (…-Kürzung), damit das
        // Bereichs-Menü rechts immer sichtbar bleibt.
        infoLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        infoLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        // Auswahl des Suchbereichs (aktueller Finder-Ordner / Benutzer-
        // ordner); die Einträge füllt updateScope() bei jedem Anzeigen.
        scopePopup.controlSize = .small
        scopePopup.font = NSFont.systemFont(ofSize: 11)

        // Direkte Constraints halten Suchfeld, Status und Bereichsmenü auch
        // bei langen Ordnernamen sauber in einer Zeile. NSStackView hatte
        // hier je nach macOS-Version überlappende Elemente erzeugt.
        for view in [field, spinner, infoLabel, scopePopup] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -14),
            field.heightAnchor.constraint(equalToConstant: 34),
            spinner.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: infoLabel.centerYAnchor),
            infoLabel.topAnchor.constraint(equalTo: field.bottomAnchor,
                                           constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor,
                                               constant: 6),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo:
                scopePopup.leadingAnchor, constant: -10),
            scopePopup.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scopePopup.centerYAnchor.constraint(equalTo: infoLabel.centerYAnchor),
        ])

        // Oben-mittig auf dem Bildschirm platzieren (Spotlight-Gefühl).
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - 280,
                y: visible.maxY - 180))
        }
    }

    func showPanel() {
        updateScope()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    // ---------- Suchbereich (Finder-Ordner / Benutzerordner) ----------

    /// Kürzt den Benutzerordner-Anteil eines Pfads zu "~".
    func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Fragt den Finder nach dem Ordner seines vordersten Fensters.
    /// nil = kein Finder-Fenster offen, Zugriff verweigert (macOS fragt
    /// beim ersten Mal um Erlaubnis) oder sonstiger Fehler — dann bleibt
    /// der Benutzerordner der Suchbereich.
    func frontFinderFolder() -> String? {
        let source = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            end if
        end tell
        """
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?
                  .executeAndReturnError(&error),
              var path = descriptor.stringValue, !path.isEmpty
        else { return nil }
        // "als alias" liefert Ordner mit Schluss-Schrägstrich — angleichen,
        // damit der Vergleich mit NSHomeDirectory() funktioniert.
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Baut das Bereichs-Menü neu auf: vorderster Finder-Ordner (falls
    /// vorhanden und nicht sowieso der Benutzerordner) plus Benutzerordner.
    /// Vorauswahl ist der Finder-Ordner — „suchen, wo ich gerade bin".
    func updateScope() {
        let home = NSHomeDirectory()
        scopePopup.removeAllItems()
        if let folder = frontFinderFolder(), folder != home {
            let name = (folder as NSString).lastPathComponent
            scopePopup.addItem(withTitle: "In „\(name)“")
            scopePopup.lastItem?.representedObject = folder
            scopePopup.lastItem?.toolTip = abbreviate(folder)
        }
        scopePopup.addItem(withTitle: "Im Benutzerordner (~)")
        scopePopup.lastItem?.representedObject = home
        scopePopup.selectItem(at: 0)
    }

    // ---------- Suche + Übergabe an die große GUI ----------

    @objc func fire() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !searching else { return }
        searching = true
        field.isEnabled = false
        scopePopup.isEnabled = false
        spinner.startAnimation(nil)
        infoLabel.stringValue = "Suche läuft…"

        // Suchbereich aus dem Menü übernehmen (Finder-Ordner oder ~).
        searchRoot = scopePopup.selectedItem?.representedObject as? String
            ?? NSHomeDirectory()
        let root = searchRoot
        // Die Suche blockierend im Hintergrund-Thread laufen lassen,
        // damit das Panel bedienbar bleibt.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let arguments = searchArguments(
                pattern: query, root: root, content: false, regex: false,
                caseSensitive: false, archives: true, progress: true)
            else {
                DispatchQueue.main.async {
                    self?.finish(query: query, count: 0, raw: nil,
                                 errorText: "favenio.py nicht gefunden.")
                }
                return
            }
            // Fortschritt: der Kern meldet laufend (gedrosselt), welchen
            // Ordner bzw. welches Archiv er gerade durchsucht — das zeigen
            // wir dezent in der Info-Zeile, damit sichtbar ist, dass die
            // Suche noch arbeitet.
            let result = runSearchStreaming(arguments: arguments) {
                [weak self] path in
                self?.showProgress(path: path)
            }
            DispatchQueue.main.async {
                let errorText = result.exitCode == 2
                    ? "Suche fehlgeschlagen. Bitte Favenio erneut installieren."
                    : nil
                self?.finish(query: query, count: result.hits.count,
                             raw: result.raw, errorText: errorText)
            }
        }
    }

    /// Zeigt den gerade durchsuchten Ort in der Info-Zeile — bewusst
    /// zurückhaltend (tertiäre Textfarbe, in der Mitte gekürzt, damit
    /// der Datei-/Archivname am Ende lesbar bleibt).
    func showProgress(path: String) {
        guard searching else { return }   // Suche schon fertig → nicht mehr
        infoLabel.textColor = .tertiaryLabelColor // hinters Ergebnis malen
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.stringValue = "Durchsuche " + abbreviate(path)
    }

    func finish(query: String, count: Int, raw: Data?, errorText: String?) {
        searching = false
        field.isEnabled = true
        scopePopup.isEnabled = true
        spinner.stopAnimation(nil)
        // Info-Zeile aus dem Fortschritts-Look zurückholen.
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
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
        openMainApp(query: query, root: searchRoot,
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
