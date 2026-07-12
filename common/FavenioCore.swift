// Gemeinsamer Unterbau für Favenio.app (große GUI) und FavenioQuick.app
// (Schnellsuche für die Finder-Toolbar).
//
// Wichtigstes Prinzip: Der eigentliche Suchmotor ist und bleibt favenio.py.
// Die Swift-Apps sind nur Frontends — sie starten den Python-Kern als
// Unterprozess und lesen dessen JSONL-Ausgabe (--json). So gibt es genau
// EINE Suchlogik, die auch headless (CLI, AI-Agenten) identisch arbeitet.

import AppKit

/// Pfad zum System-Python (auf jedem Mac mit Xcode-CLT vorhanden).
let pythonPath = "/usr/bin/python3"

/// Ein einzelner Suchtreffer, wie ihn `favenio.py --json` liefert.
struct Hit {
    let path: String   // voller Pfad; Archiv-Einträge mit "!/"-Notation
    let kind: String   // "file", "dir" oder "member" (= im Archiv)
    let line: Int?     // Zeilennummer bei Inhaltssuche, sonst nil

    /// Liegt der Treffer INNERHALB eines Archivs?
    var isMember: Bool { path.contains("!/") }

    /// Nur der Dateiname (letzte Komponente), für die Namensspalte.
    var displayName: String {
        let lastSegment = path.components(separatedBy: "!/").last ?? path
        return (lastSegment as NSString).lastPathComponent
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
    return Hit(path: path, kind: kind, line: dict["line"] as? Int)
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
func searchArguments(pattern: String, root: String, content: Bool,
                     regex: Bool, caseSensitive: Bool,
                     archives: Bool, progress: Bool = false) -> [String]? {
    guard let cli = findCLI() else { return nil }
    var args = ["-u", cli, "--json"]   // -u = ungepuffert → Treffer streamen
    if content { args.append("--content") }
    if regex { args.append("--regex") }
    if caseSensitive { args.append("--case-sensitive") }
    if !archives { args.append("--no-archives") }
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
func runSearchStreaming(arguments: [String],
                        onProgress: @escaping (String) -> Void)
    -> (hits: [Hit], raw: Data, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ([], Data(), 2) }

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

/// Baut das minimale Menü (Beenden + Bearbeiten), damit Cmd+Q/C/V/X/A
/// in beiden Apps funktionieren — programmatische Apps haben sonst
/// KEINE Tastaturkürzel.
func installMainMenu(appName: String) {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "\(appName) beenden",
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")
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
