// Gemeinsamer Unterbau für Favenio.app (große GUI) und FavenioQuick.app
// (Schnellsuche für die Finder-Toolbar).
//
// Wichtigstes Prinzip: Der eigentliche Suchmotor ist und bleibt favenio.py.
// Die Swift-Apps sind nur Frontends — sie starten den Python-Kern als
// Unterprozess und lesen dessen JSONL-Ausgabe (--json). So gibt es genau
// EINE Suchlogik, die auch headless (CLI, AI-Agenten) identisch arbeitet.

import AppKit
import Darwin
import Sparkle
import UniformTypeIdentifiers

/// Pfad zum System-Python (auf jedem Mac mit Xcode-CLT vorhanden).
let pythonPath = "/usr/bin/python3"

/// Erzeugt pro App-Prozess genau einen langlebigen Sparkle-Controller.
/// Die aufrufenden Controller halten ihn als Feld über die gesamte Laufzeit.
func makeUpdaterController() -> SPUStandardUpdaterController {
    SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

/// Verdrahtet „Nach Updates suchen …" direkt auf Sparkle. Dadurch validiert
/// Sparkle den Eintrag auch während einer laufenden Suche oder Installation.
func installUpdateMenuItem(
    updaterController: SPUStandardUpdaterController
) {
    guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
    let identifier = NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")

    if let existing = appMenu.items.first(where: {
        $0.identifier == identifier
    }) {
        existing.action =
            #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        existing.target = updaterController
        return
    }

    let item = NSMenuItem(
        title: "Nach Updates suchen …",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
        keyEquivalent: ""
    )
    item.identifier = identifier
    item.target = updaterController

    let quitIndex = appMenu.items.firstIndex(where: {
        $0.action == #selector(NSApplication.terminate(_:))
    }) ?? appMenu.items.count
    appMenu.insertItem(item, at: quitIndex)
    appMenu.insertItem(.separator(), at: quitIndex + 1)
}

/// Prüft ohne Fenster oder Netzwerkzugriff die sicherheitsrelevante
/// Sparkle-Konfiguration des tatsächlich gebauten App-Bundles.
func validateSparkleConfiguration(
    expectedBundleIdentifier: String
) -> String? {
    let info = Bundle.main.infoDictionary ?? [:]
    guard Bundle.main.bundleIdentifier == expectedBundleIdentifier else {
        return "unerwartete Bundle-ID"
    }
    guard let feed = info["SUFeedURL"] as? String,
          let feedURL = URL(string: feed),
          feedURL.scheme == "https",
          feedURL.host != nil else {
        return "Sparkle-Feed ist keine gültige HTTPS-URL"
    }
    guard info["SUPublicEDKey"] as? String == favenioSparklePublicKey,
          info["SUEnableAutomaticChecks"] as? Bool == true,
          info["SUAutomaticallyUpdate"] as? Bool == false,
          info["SUAllowsAutomaticUpdates"] as? Bool == false,
          info["SUEnableSystemProfiling"] as? Bool == false,
          info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
          info["SURequireSignedFeed"] as? Bool == true else {
        return "Sparkle-Signatur-, Update- oder Datenschutzwerte fehlen"
    }
    guard let frameworks = Bundle.main.privateFrameworksURL,
          FileManager.default.fileExists(
              atPath: frameworks.appendingPathComponent(
                  "Sparkle.framework"
              ).path
          ) else {
        return "Sparkle.framework fehlt im App-Bundle"
    }

    // Der normale App-Start erzeugt NSApplication vor dem Controller. Der
    // Headless-Pfad muss dieselbe Grundlage ohne Runloop ausdrücklich anlegen.
    _ = NSApplication.shared
    // Separater, nicht gestarteter Controller: kein Feed-Abruf, aber der Test
    // beweist, dass Framework, Selector und Menüverdrahtung wirklich laden.
    let controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    installMainMenu(appName: "Favenio Selbsttest")
    installUpdateMenuItem(updaterController: controller)
    guard let item = NSApp.mainMenu?.item(at: 0)?.submenu?.items.first(
        where: {
            $0.identifier
                == NSUserInterfaceItemIdentifier("Favenio.CheckForUpdates")
        }
    ),
    item.action == #selector(
        SPUStandardUpdaterController.checkForUpdates(_:)
    ),
    item.target === controller else {
        return "Update-Menüpunkt zielt nicht direkt auf Sparkle"
    }
    return nil
}

/// Ein einzelner Suchtreffer, wie ihn `favenio.py --json` liefert.
struct Hit: Hashable {
    let path: String   // menschenlesbarer Pfad; kann !/-Notation enthalten
    let kind: String   // "file", "dir" oder "member" (= im Archiv)
    let line: Int?     // Zeilennummer bei Inhaltssuche, sonst nil
    let size: Int?     // Dateigröße in Bytes; bei Ordnern nil
    let filesystemPath: String
    let archiveMembers: [String]

    /// Liegt der Treffer INNERHALB eines Archivs?
    var isMember: Bool { !archiveMembers.isEmpty }

    /// Nur der Dateiname (letzte Komponente), für die Namensspalte.
    var displayName: String {
        let lastSegment = archiveMembers.last ?? filesystemPath
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
    let filesystemPath = dict["filesystemPath"] as? String
        ?? (kind == "member"
            ? path.components(separatedBy: "!/").first ?? path
            : path)
    let archiveMembers = dict["archiveMembers"] as? [String]
        ?? (kind == "member"
            ? Array(path.components(separatedBy: "!/").dropFirst())
            : [])
    return Hit(path: path, kind: kind, line: dict["line"] as? Int,
               size: dict["size"] as? Int,
               filesystemPath: filesystemPath,
               archiveMembers: archiveMembers)
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

/// Führt eine Suche BLOCKIEREND aus und liefert Treffer.
/// Für die Schnellsuche und den Selbsttest; die große GUI streamt
/// stattdessen asynchron (siehe MainController in FavenioGUI.swift).
func runSearchSync(arguments: [String]) -> [Hit] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let raw = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var hits: [Hit] = []
    for lineData in raw.split(separator: 0x0A) {   // 0x0A = "\n"
        if let hit = parseHit(Data(lineData)) { hits.append(hit) }
    }
    return hits
}

/// Wie runSearchSync, liest die Ausgabe aber ZEILENWEISE, während die
/// Suche läuft: Fortschritts-Zeilen (--progress) werden sofort über den
/// Callback gemeldet (auf dem Main-Thread). Treffer werden ausschließlich
/// über `onHit` weitergereicht; der Kern legt keine redundante zweite Kopie an.
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
    -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: pythonPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return 2 }
    register?(process)   // Aufrufer kann den Lauf ab jetzt abbrechen

    var buffer = Data()    // noch unvollständige Zeile vom Pipe-Ende

    func handleLine(_ lineData: Data) {
        if lineData.isEmpty { return }
        if let path = parseProgress(lineData) {
            DispatchQueue.main.async { onProgress(path) }
        } else if let hit = parseHit(lineData) {
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
    return process.terminationStatus
}

/// Appweiter Cache: jede Aktion auf denselben Archivtreffer verwendet dieselbe
/// materialisierte Datei. Alle Kopien liegen unter einem eindeutigen Root und
/// werden beim App-Ende gemeinsam entfernt.
final class MaterializationManager {
    static let shared = MaterializationManager()
    private var cache: [Hit: URL] = [:]
    private var root: URL?

    private func materializationRoot() -> URL? {
        if let root { return root }
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("Favenio-(UUID().uuidString)",
                                    isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: candidate, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            root = candidate
            return candidate
        } catch {
            return nil
        }
    }

    func materialize(_ hit: Hit) -> URL? {
        if !hit.isMember {
            return URL(fileURLWithPath: hit.filesystemPath)
        }
        if let cached = cache[hit],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let cli = findCLI(), let root = materializationRoot() else {
            return nil
        }
        let object: [String: Any] = [
            "filesystemPath": hit.filesystemPath,
            "archiveMembers": hit.archiveMembers,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              let jsonText = String(data: json, encoding: .utf8) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [cli, "--extract-json", jsonText,
                             "--extract-root", root.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        let url = URL(fileURLWithPath: output)
        cache[hit] = url
        return url
    }

    func cleanup() {
        cache.removeAll()
        guard let root else { return }
        try? FileManager.default.removeItem(at: root)
        self.root = nil
    }
}

func materializeHit(_ hit: Hit) -> URL? {
    MaterializationManager.shared.materialize(hit)
}

func cleanupMaterializedHits() {
    MaterializationManager.shared.cleanup()
}

/// Serialisiert Treffer zu JSONL (eine Zeile pro Treffer), im selben Format,
/// das `parseHit` wieder liest. Damit reicht die Schnellsuche ihre schon
/// gefundenen Treffer als Datei an die große GUI weiter, ohne den
/// (abgebrochenen) Suchlauf-Rohstrom zu brauchen.
func jsonlData(for hits: [Hit]) -> Data {
    var data = Data()
    for hit in hits {
        var object: [String: Any] = ["path": hit.path, "type": hit.kind]
        object["filesystemPath"] = hit.filesystemPath
        object["archiveMembers"] = hit.archiveMembers
        if let line = hit.line { object["line"] = line }
        if let size = hit.size { object["size"] = size }
        if let encoded = try? JSONSerialization.data(withJSONObject: object) {
            data.append(encoded)
            data.append(0x0A)
        }
    }
    return data
}

let quickHandoffPrefix = "favenio-quick-"
let quickHandoffSuffix = ".jsonl"
let maximumHandoffBytes = 8 * 1024 * 1024
let maximumHandoffLineBytes = 1024 * 1024

/// Schreibt die Quick→Haupt-App-Übergabe atomar und nur für den Besitzer.
func writeQuickHandoff(_ hits: [Hit]) throws -> URL {
    let data = jsonlData(for: hits)
    guard data.count <= maximumHandoffBytes else {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        quickHandoffPrefix + UUID().uuidString + quickHandoffSuffix)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

/// Akzeptiert nur eigene reguläre Dateien direkt im System-Temp-Ordner.
func validatedQuickHandoff(_ candidate: URL) -> URL? {
    let url = candidate.standardizedFileURL
    let temporary = FileManager.default.temporaryDirectory
        .standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent().resolvingSymlinksInPath()
            == temporary,
          url.lastPathComponent.hasPrefix(quickHandoffPrefix),
          url.lastPathComponent.hasSuffix(quickHandoffSuffix),
          let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ]),
          values.isRegularFile == true,
          values.isSymbolicLink != true,
          let size = values.fileSize,
          size <= maximumHandoffBytes,
          let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path),
          let owner = attributes[.ownerAccountID] as? NSNumber,
          owner.uint32Value == getuid() else {
        return nil
    }
    return url
}

/// Liest begrenzt und zeilenweise; eine validierte Übergabedatei wird bei
/// Erfolg wie Fehler exakt einmal verbraucht und anschließend gelöscht.
func consumeQuickHandoff(_ candidate: URL) -> [Hit]? {
    guard let url = validatedQuickHandoff(candidate) else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var total = 0
    var buffer = Data()
    var hits: [Hit] = []
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumHandoffBytes else { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.count <= maximumHandoffLineBytes,
                      let hit = parseHit(line) else { return nil }
                hits.append(hit)
            }
            guard buffer.count <= maximumHandoffLineBytes else { return nil }
        }
    } catch {
        return nil
    }
    if !buffer.isEmpty {
        guard let hit = parseHit(buffer) else { return nil }
        hits.append(hit)
    }
    return hits
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

/// Ermittelt die offenen Finder-Fenster (Ordner des vorderen Tabs),
/// VORDERSTES zuerst — ASYNCHRON und ohne den Main-Thread zu blockieren.
/// `completion` läuft auf dem Main-Thread; leere Liste = kein Fenster oder
/// (noch) kein Automations-Zugriff.
///
/// WARUM per `osascript`-UNTERPROZESS (statt NSAppleScript im eigenen Prozess):
/// Den Finder abzufragen ist ein Apple-Event, dessen Antwort der Apple-Event-
/// Manager an den MAIN-Thread des Prozesses zustellt. In einer laufenden
/// `NSApplication` (unsere Accessory-App) blockiert ein synchroner
/// `NSAppleScript.executeAndReturnError` dann ewig — egal ob auf einem
/// Hintergrund-Thread (die Antwort landet nie bei ihm) oder auf dem Main-Thread
/// (er wartet auf eine Antwort, die nur er selbst zustellen könnte → Deadlock).
/// Beide In-Prozess-Wege wurden im echten App-Kontext als Hänger verifiziert
/// (2026-07-13). Ein separater `osascript`-Prozess hat seinen eigenen
/// Event-Loop und kehrt sauber zurück — genau wie das nc_pin-AppleScript-Applet.
/// TCC ordnet den Apple-Event dabei korrekt UNSERER App als verantwortlichem
/// Prozess zu (Favenios `NSAppleEventsUsageDescription` → korrekter Prompt);
/// die entgegengesetzte Handoff-Notiz („osascript scheidet aus") war falsch.
/// (Finder-Tabs sind per AppleScript nicht einzeln adressierbar — pro Fenster
/// kommt der Ordner des vorderen Tabs.)
func finderWindowFoldersAsync(completion: @escaping ([String]) -> Void) {
    // Hintergrund-Thread nur, damit das Starten/Warten des Unterprozesses den
    // Main-Thread nicht anfasst; die eigentliche Apple-Event-Arbeit macht
    // osascript in seinem eigenen Prozess.
    DispatchQueue.global(qos: .userInitiated).async {
        // VORDERSTES Fenster explizit über `front window` (wie nc_pin) —
        // `Finder windows` ist nicht zuverlässig front-to-back sortiert. Die
        // Pfade kommen zeilengetrennt zurück (front zuerst, dann die übrigen).
        // `with timeout` verhindert ewiges Warten, falls der Finder klemmt.
        // `text item delimiters` ist eine AppleScript-Eigenschaft und muss
        // AUSSERHALB des `tell application "Finder"`-Blocks gesetzt werden —
        // sonst versucht AppleScript, sie am Finder zu setzen (Fehler -10006).
        let source = """
        set out to {}
        tell application "Finder"
            with timeout of 8 seconds
                set frontPath to ""
                try
                    set frontPath to POSIX path of (target of front window as alias)
                end try
                if frontPath is not "" then set end of out to frontPath
                try
                    repeat with w in Finder windows
                        try
                            set p to POSIX path of (target of w as alias)
                            if p is not frontPath then set end of out to p
                        end try
                    end repeat
                end try
            end timeout
        end tell
        set text item delimiters to linefeed
        return out as text
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var folders: [String] = []
        do {
            try process.run()
            // Not-Aus: klemmt osascript trotz AppleScript-Timeout, nach 12 s
            // abbrechen — dann bleibt die Vorauswahl eben `~`, kein Hänger.
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            if process.terminationStatus == 0,
               let text = String(data: data, encoding: .utf8) {
                for var line in text.split(separator: "\n", omittingEmptySubsequences: true)
                                    .map(String.init) {
                    // „als alias" liefert Ordner mit Schluss-Schrägstrich.
                    if line.count > 1 && line.hasSuffix("/") { line.removeLast() }
                    if !line.isEmpty { folders.append(line) }
                }
            }
        } catch {
            // osascript nicht startbar → leere Liste, App fällt auf `~` zurück.
        }
        DispatchQueue.main.async { completion(folders) }
    }
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
