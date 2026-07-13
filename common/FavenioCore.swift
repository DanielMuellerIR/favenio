// Gemeinsamer Unterbau für Favenio.app (große GUI) und FavenioQuick.app
// (Schnellsuche für die Finder-Toolbar).
//
// Wichtigstes Prinzip: Der eigentliche Suchmotor ist und bleibt favenio.py.
// Die Swift-Apps sind nur Frontends — sie starten den Python-Kern als
// Unterprozess und lesen dessen JSONL-Ausgabe (--json). So gibt es genau
// EINE Suchlogik, die auch headless (CLI, AI-Agenten) identisch arbeitet.

import AppKit
import UniformTypeIdentifiers

/// Pfad zum System-Python (auf jedem Mac mit Xcode-CLT vorhanden).
let pythonPath = "/usr/bin/python3"

/// Ein einzelner Suchtreffer, wie ihn `favenio.py --json` liefert.
struct Hit {
    let path: String   // voller Pfad; Archiv-Einträge mit "!/"-Notation
    let kind: String   // "file", "dir" oder "member" (= im Archiv)
    let line: Int?     // Zeilennummer bei Inhaltssuche, sonst nil
    let size: Int?     // Dateigröße in Bytes; bei Ordnern nil

    /// Liegt der Treffer INNERHALB eines Archivs?
    var isMember: Bool { path.contains("!/") }

    /// Nur der Dateiname (letzte Komponente), für die Namensspalte.
    var displayName: String {
        let lastSegment = path.components(separatedBy: "!/").last ?? path
        return (lastSegment as NSString).lastPathComponent
    }

    /// Menschlicher Dateityp für die Typ-Spalte: „Ordner" bei Verzeichnissen,
    /// sonst die lokalisierte Typbeschreibung der Endung (z. B. „PDF-Dokument"),
    /// ersatzweise die Endung groß bzw. „Datei" ohne Endung.
    var typeDescription: String {
        if kind == "dir" { return "Ordner" }
        let ext = (displayName as NSString).pathExtension
        if ext.isEmpty { return "Datei" }
        if let type = UTType(filenameExtension: ext.lowercased()),
           let description = type.localizedDescription {
            return description
        }
        return ext.uppercased()
    }
}

/// Findet den Python-Kern: zuerst im App-Bundle (Resources), sonst im
/// Arbeitsverzeichnis (Entwicklungs-Fallback beim Direktstart des Binarys).
func findCLI() -> String? {
    if let bundled = Bundle.main.path(forResource: "favenio", ofType: "py") {
        return bundled
    }
    let local = FileManager.default.currentDirectoryPath + "/favenio.py"
    if FileManager.default.fileExists(atPath: local) { return local }
    return nil
}

/// Übersetzt EINE JSONL-Zeile der Suche in einen Hit (oder nil bei Müll).
/// Fortschritts-Zeilen (type=progress, von --progress) sind KEINE Treffer
/// und werden hier bewusst verworfen — dafür gibt es parseProgress().
func parseHit(_ lineData: Data) -> Hit? {
    guard
        let object = try? JSONSerialization.jsonObject(with: lineData),
        let dict = object as? [String: Any],
        let path = dict["path"] as? String,
        let kind = dict["type"] as? String,
        kind != "progress"
    else { return nil }
    return Hit(path: path, kind: kind, line: dict["line"] as? Int,
               size: dict["size"] as? Int)
}

/// Übersetzt eine JSONL-Zeile in einen Fortschritts-Pfad (der Ordner bzw.
/// das Archiv, das der Kern gerade durchsucht) — nil für alles andere.
func parseProgress(_ lineData: Data) -> String? {
    guard
        let object = try? JSONSerialization.jsonObject(with: lineData),
        let dict = object as? [String: Any],
        dict["type"] as? String == "progress",
        let path = dict["path"] as? String
    else { return nil }
    return path
}

/// Baut die Argumentliste für einen Suchlauf des Python-Kerns.
/// nil, wenn favenio.py nicht auffindbar ist.
/// `only` begrenzt Treffer auf einen Typ: "both" (Dateien & Ordner),
/// "files" oder "dirs" — für den Drei-Wege-Umschalter der großen GUI.
func searchArguments(pattern: String, root: String, content: Bool,
                     regex: Bool, caseSensitive: Bool,
                     archives: Bool, progress: Bool = false,
                     only: String = "both",
                     includeHidden: Bool = false) -> [String]? {
    guard let cli = findCLI() else { return nil }
    var args = ["-u", cli, "--json"]   // -u = ungepuffert → Treffer streamen
    if content { args.append("--content") }
    if regex { args.append("--regex") }
    if caseSensitive { args.append("--case-sensitive") }
    if !archives { args.append("--no-archives") }
    if only != "both" { args.append(contentsOf: ["--only", only]) }
    if includeHidden { args.append("--hidden") }
    if progress { args.append("--progress") }
    args.append("--")   // ab hier nur noch Positionsargumente (Muster darf
    args.append(pattern) // sonst mit "-" beginnen und argparse verwirren)
    args.append(root)
    return args
}

/// Führt eine Suche BLOCKIEREND aus und liefert (Treffer, Roh-JSONL).
/// Für die Schnellsuche und den Selbsttest; die große GUI streamt
/// stattdessen asynchron (siehe MainController in FavenioGUI.swift).
func runSearchSync(arguments: [String]) -> (hits: [Hit], raw: Data) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ([], Data()) }
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var hits: [Hit] = []
    for lineData in raw.split(separator: 0x0A) {   // 0x0A = "\n"
        if let hit = parseHit(Data(lineData)) { hits.append(hit) }
    }
    return (hits, raw)
}

/// Wie runSearchSync, liest die Ausgabe aber ZEILENWEISE, während die
/// Suche läuft: Fortschritts-Zeilen (--progress) werden sofort über den
/// Callback gemeldet (auf dem Main-Thread), Treffer gesammelt. Das
/// zurückgegebene Roh-JSONL enthält NUR die Treffer — es kann also
/// unverändert als Ergebnisdatei an die große GUI übergeben werden.
/// Blockiert bis zum Ende der Suche; im Hintergrund-Thread aufrufen.
///
/// `register` bekommt (falls gesetzt) den gestarteten Prozess durchgereicht,
/// damit der Aufrufer ihn abbrechen kann (`process.terminate()`) — z. B. die
/// Schnellsuche, wenn der Nutzer weitertippt. Nach dem Abbruch bricht die
/// Lese-Schleife ab (die Pipe schließt) und die Funktion kehrt zurück; der
/// exitCode ist dann der Signal-Status, nicht 0 — der Aufrufer verwirft das
/// veraltete Ergebnis ohnehin über seinen Generations-Zähler.
///
/// `onHit` (falls gesetzt) meldet JEDEN Treffer sofort auf dem Main-Thread —
/// so kann die Schnellsuche ihre Trefferliste live wachsen lassen, statt bis
/// zum Ende zu warten.
func runSearchStreaming(arguments: [String],
                        register: ((Process) -> Void)? = nil,
                        onHit: ((Hit) -> Void)? = nil,
                        onProgress: @escaping (String) -> Void)
    -> (hits: [Hit], raw: Data, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ([], Data(), 2) }
    register?(process)   // Aufrufer kann den Lauf ab jetzt abbrechen

    var hits: [Hit] = []
    var hitsRaw = Data()   // gefiltertes JSONL (ohne progress-Zeilen)
    var buffer = Data()    // noch unvollständige Zeile vom Pipe-Ende

    func handleLine(_ lineData: Data) {
        if lineData.isEmpty { return }
        if let path = parseProgress(lineData) {
            DispatchQueue.main.async { onProgress(path) }
        } else if let hit = parseHit(lineData) {
            hits.append(hit)
            hitsRaw.append(lineData)
            hitsRaw.append(0x0A)
            if let onHit { DispatchQueue.main.async { onHit(hit) } }
        }
    }

    let handle = pipe.fileHandleForReading
    while true {
        let chunk = handle.availableData   // blockiert; leer = Pipe zu
        if chunk.isEmpty { break }
        buffer.append(chunk)
        // Alle vollständigen Zeilen aus dem Puffer abarbeiten.
        while let newline = buffer.firstIndex(of: 0x0A) {
            handleLine(buffer.subdata(in: buffer.startIndex..<newline))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }
    handleLine(buffer)   // letzte Zeile, falls ohne Zeilenumbruch
    process.waitUntilExit()
    return (hits, hitsRaw, process.terminationStatus)
}

/// Macht aus einem Treffer eine echte Datei auf der Platte:
/// normale Pfade unverändert, Archiv-Einträge via `favenio.py --extract`
/// in einen Temp-Ordner. nil = Extraktion fehlgeschlagen.
/// Damit funktionieren Öffnen, „Öffnen mit" und Drag&Drop auch für
/// Dateien, die in einem Zip/Tar stecken.
func materializeHit(_ resultPath: String) -> URL? {
    if !resultPath.contains("!/") {
        return URL(fileURLWithPath: resultPath)
    }
    guard let cli = findCLI() else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = [cli, "--extract", resultPath]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let output = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
          !output.isEmpty
    else { return nil }
    return URL(fileURLWithPath: output)
}

/// Serialisiert Treffer zu JSONL (eine Zeile pro Treffer), im selben Format,
/// das `parseHit` wieder liest. Damit reicht die Schnellsuche ihre schon
/// gefundenen Treffer als Datei an die große GUI weiter, ohne den
/// (abgebrochenen) Suchlauf-Rohstrom zu brauchen.
func jsonlData(for hits: [Hit]) -> Data {
    var data = Data()
    for hit in hits {
        var object: [String: Any] = ["path": hit.path, "type": hit.kind]
        if let line = hit.line { object["line"] = line }
        if let size = hit.size { object["size"] = size }
        if let encoded = try? JSONSerialization.data(withJSONObject: object) {
            data.append(encoded)
            data.append(0x0A)
        }
    }
    return data
}

/// Apps, die einen Treffer öffnen können — für das „Öffnen mit"-Menü.
/// Bei normalen Dateien direkt über die URL, bei Archiv-Einträgen über den
/// Dateityp (Endung), damit fürs bloße Menü noch nichts ausgepackt wird.
/// Nach Namen sortiert, Doppelte entfernt.
func applicationsFor(_ hit: Hit) -> [URL] {
    var urls: [URL] = []
    if hit.isMember {
        let ext = (hit.displayName as NSString).pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext.lowercased()) {
            urls = NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
    } else {
        urls = NSWorkspace.shared.urlsForApplications(
            toOpen: URL(fileURLWithPath: hit.path))
    }
    var seen = Set<String>()
    return urls
        .filter { seen.insert($0.path).inserted }
        .sorted {
            FileManager.default.displayName(atPath: $0.path)
                .localizedCaseInsensitiveCompare(
                    FileManager.default.displayName(atPath: $1.path))
                == .orderedAscending
        }
}

// ---------- Festplattenvollzugriff (Full Disk Access) ----------

/// Grobe, prompt-freie Prüfung, ob die App Festplattenvollzugriff hat: die
/// TCC-Datenbank im Benutzerordner ist nur MIT Vollzugriff lesbar. Fehlt der
/// Zugriff, liefert das Öffnen nil (EPERM) — ganz ohne Systemdialog, denn
/// Vollzugriff lässt sich nicht per Prompt erfragen.
func hasFullDiskAccess() -> Bool {
    let probe = NSHomeDirectory()
        + "/Library/Application Support/com.apple.TCC/TCC.db"
    guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
    handle.closeFile()
    return true
}

/// Zeigt beim Start einen einmaligen Anleitungs-Dialog, wenn (noch) kein
/// Vollzugriff besteht — außer der Nutzer hat „nicht mehr fragen" gewählt.
/// Der Suppress-Schalter liegt in den per-App-UserDefaults, gilt also je App
/// getrennt (beide Bundles brauchen den Zugriff separat).
func maybePromptFullDiskAccess(appName: String) {
    let suppressKey = "FavenioSuppressFullDiskAccessPrompt"
    if UserDefaults.standard.bool(forKey: suppressKey) { return }
    if hasFullDiskAccess() { return }

    let alert = NSAlert()
    alert.messageText = "Festplattenvollzugriff empfohlen"
    alert.informativeText = """
        \(appName) durchsucht Dateien mit dem Bordmittel-Suchmotor. OHNE \
        „Festplattenvollzugriff" fragt macOS beim Durchsuchen geschützter \
        Ordner (Musik, Fotos, Mail …) ständig einzeln um Erlaubnis — und die \
        Schnellsuche kann dabei sogar verschwinden.

        Mit einmal erteiltem Vollzugriff läuft die Suche ruhig und \
        vollständig durch. Die App funktioniert auch ohne, ist damit aber \
        deutlich besser.

        So geht's: Systemeinstellungen → Datenschutz & Sicherheit → \
        Festplattenvollzugriff → \(appName) aktivieren (nötigenfalls per „+" \
        hinzufügen), danach die App neu starten.
        """
    alert.addButton(withTitle: "Systemeinstellungen öffnen")
    alert.addButton(withTitle: "Später")
    alert.addButton(withTitle: "Nicht freigeben, nicht mehr fragen")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
        if let url = URL(string: "x-apple.systempreferences:"
            + "com.apple.preference.security?Privacy_AllFilesAccess") {
            NSWorkspace.shared.open(url)
        }
    case .alertThirdButtonReturn:
        UserDefaults.standard.set(true, forKey: suppressKey)
    default:
        break   // „Später" → beim nächsten Start erneut fragen
    }
}

/// Alle offenen Finder-Fenster als POSIX-Pfade ihres Ziel-Ordners,
/// VORDERSTES zuerst (Fenster-Index 1 = ganz vorn). Leer, wenn kein
/// Finder-Fenster offen ist, der Automations-Zugriff (noch) nicht erlaubt
/// wurde oder ein Fehler auftrat — der Aufrufer fällt dann auf andere
/// Ordner zurück. (Finder-Tabs sind über AppleScript nicht einzeln
/// adressierbar; wir bekommen pro Fenster den Ordner des vorderen Tabs.)
func finderWindowFolders() -> [String] {
    let source = """
    tell application "Finder"
        set out to {}
        repeat with w in Finder windows
            try
                set end of out to POSIX path of (target of w as alias)
            end try
        end repeat
        return out
    end tell
    """
    var error: NSDictionary?
    guard let descriptor = NSAppleScript(source: source)?
              .executeAndReturnError(&error) else { return [] }
    let count = descriptor.numberOfItems
    guard count > 0 else { return [] }   // AEList ist 1-indexiert
    var paths: [String] = []
    for index in 1...count {
        guard var path = descriptor.atIndex(index)?.stringValue,
              !path.isEmpty else { continue }
        // „als alias" liefert Ordner mit Schluss-Schrägstrich — angleichen.
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        paths.append(path)
    }
    return paths
}

/// Die wichtigsten Ordner als (Anzeigename, Pfad) — für das Ordner-Popup der
/// großen GUI und das Bereichs-Menü der Schnellsuche.
func commonFolders() -> [(title: String, path: String)] {
    let home = NSHomeDirectory()
    return [
        ("Benutzerordner (~)", home),
        ("Schreibtisch", home + "/Desktop"),
        ("Dokumente", home + "/Documents"),
        ("Downloads", home + "/Downloads"),
        ("Programme", "/Applications"),
    ]
}

/// Kürzt den Benutzerordner-Anteil eines Pfads zu "~" (für Tooltips/Anzeige).
func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// Baut das minimale Menü (Beenden + Bearbeiten), damit Cmd+Q/C/V/X/A
/// in beiden Apps funktionieren — programmatische Apps haben sonst
/// KEINE Tastaturkürzel.
/// `includeClose` = zusätzlich „Fenster schließen" (Cmd+W); nur die
/// Schnellsuche braucht das (dort beendet das Schließen die App), damit
/// nicht die große GUI ungewollt ihr Verhalten ändert.
func installMainMenu(appName: String, includeClose: Bool = false) {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "\(appName) beenden",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
    if includeClose {
        // performClose läuft über die Responder-Kette ans Key-Fenster; beim
        // Panel löst das windowWillClose aus → die Schnellsuche beendet sich.
        appMenu.addItem(withTitle: "Fenster schließen",
                        action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")
    }
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Bearbeiten")
    editMenu.addItem(withTitle: "Ausschneiden",
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Kopieren",
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Einsetzen",
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Alles auswählen",
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
    editItem.submenu = editMenu

    NSApp.mainMenu = mainMenu
}
