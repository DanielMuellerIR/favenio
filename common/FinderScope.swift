import AppKit

/// Die Ordnerabfrage unterscheidet fehlende Fenster, verweigerte Automation
/// und andere Fehler, damit die Oberfläche den Fallback erklären kann.
enum FinderScopeOutcome {
    case folders([String])   // mindestens ein Finder-Ordner, vorderster zuerst
    case noWindow            // Finder erreichbar, aber kein Ordnerfenster offen
    case denied              // Automations-Zugriff auf den Finder verweigert
    case failed(String)      // Zeitüberschreitung oder anderer Fehler
}

extension FinderScopeOutcome {
    /// Die ermittelten Ordner (bei jedem Fehlschlag leer).
    var folders: [String] {
        if case .folders(let folders) = self { return folders }
        return []
    }

    /// Kurztext mit einem Ausweg für die Benutzeroberfläche.
    var problemText: String? {
        switch self {
        case .folders:
            return nil
        case .noWindow:
            return "Kein Finder-Fenster offen — Suchbereich manuell wählen."
        case .denied:
            return "Finder-Zugriff nicht erlaubt — Suchbereich manuell wählen "
                 + "(Systemeinstellungen → Datenschutz & Sicherheit → "
                 + "Automation)."
        case .failed(let reason):
            return "Finder-Ordner nicht ermittelbar (\(reason)) — Suchbereich "
                 + "manuell wählen."
        }
    }

    /// Maschinenlesbares Kürzel für die Diagnose auf der Kommandozeile.
    var statusName: String {
        switch self {
        case .folders:  return "folders"
        case .noWindow: return "no-window"
        case .denied:   return "denied"
        case .failed:   return "failed"
        }
    }
}

/// Bündelt Anfragen auf dem Hauptthread. Eine Antwort aus einer früheren
/// Aktivierung wird verworfen; bei Bedarf folgt genau eine frische Abfrage.
final class FinderScopeRefresh {
    typealias Reply = (FinderScopeOutcome) -> Void

    private let query: (@escaping Reply) -> Void
    private var generation = 0
    private var refreshing = false
    private var pending: (generation: Int, reply: Reply)?

    init(query: @escaping (@escaping Reply) -> Void = finderWindowFoldersAsync) {
        self.query = query
    }

    func refresh(forActivation: Bool = false, reply: @escaping Reply) {
        if forActivation { generation += 1 }
        if refreshing {
            pending = (generation, reply)
            return
        }
        let requestedGeneration = generation
        refreshing = true
        query { [weak self] outcome in
            guard let self else { return }
            self.refreshing = false
            let pending = self.pending
            self.pending = nil
            if requestedGeneration == self.generation {
                reply(outcome)
            }
            if let pending, pending.generation == self.generation, !self.refreshing {
                self.refresh(reply: pending.reply)
            }
        }
    }
}

/// Öffnet die Automations-Freigabe in den Systemeinstellungen.
func openAutomationSettings() {
    if let url = URL(string: "x-apple.systempreferences:"
        + "com.apple.preference.security?Privacy_Automation") {
        NSWorkspace.shared.open(url)
    }
}

// Rückgabewerte von `AEDeterminePermissionToAutomateTarget`. Die Konstanten
// stehen in Apples Carbon-Headern; hier ausgeschrieben, damit der Code ohne
// zusätzliche Importe lesbar bleibt.
private let kAEEventNotPermitted: OSStatus = -1743          // ausdrücklich verboten
private let kAEEventWouldRequireUserConsent: OSStatus = -1744  // noch nicht gefragt

/// Fragt TCC OHNE Apple-Event und OHNE Dialog, ob wir den Finder steuern dürfen.
///
/// Das ist der einzige Weg, „verboten" sofort zu erkennen, statt es aus einem
/// hängenden Unterprozess zu erschließen: Apple-Events an einen verbotenen
/// Empfänger können beliebig lange stehen bleiben, und ein Timeout ist dann nur
/// geraten. `askUserIfNeeded: false` verhindert, dass dieser Aufruf selbst einen
/// Dialog auslöst — der Consent-Dialog gehört an die echte Abfrage.
/// Ergebnis: `noErr` = erlaubt, -1743 = verboten, -1744 = noch nicht gefragt.
func finderAutomationPermission() -> OSStatus {
    guard let target = NSAppleEventDescriptor(
        bundleIdentifier: "com.apple.finder").aeDesc else { return noErr }
    return AEDeterminePermissionToAutomateTarget(
        target, typeWildCard, typeWildCard, false)
}

/// Wartet macOS gerade auf die Entscheidung des Nutzers? Dann darf die
/// Oberfläche nicht „Finder antwortet nicht" behaupten.
func finderAutomationConsentPending() -> Bool {
    finderAutomationPermission() == kAEEventWouldRequireUserConsent
}

/// Liefert die offenen Finder-Ordner auf dem Hauptthread, vorderster zuerst.
/// Pro Finder-Fenster ist der sichtbare Tab adressierbar. Der Unterprozess
/// besitzt einen eigenen Event-Loop. In einer laufenden NSApplication kann
/// synchrones NSAppleScript auf die Zustellung am Hauptthread blockieren.
func finderWindowFoldersAsync(
    completion: @escaping (FinderScopeOutcome) -> Void
) {
    // Hintergrund-Thread nur, damit das Starten/Warten des Unterprozesses den
    // Main-Thread nicht anfasst; die eigentliche Apple-Event-Arbeit macht
    // osascript in seinem eigenen Prozess.
    DispatchQueue.global(qos: .userInitiated).async {
        // Zuerst TCC fragen, ohne Event und ohne Dialog. Ist die Automation
        // verboten, ist das SOFORT klar — kein Unterprozess, kein Warten, kein
        // geratener Timeout.
        let permission = finderAutomationPermission()
        if permission == kAEEventNotPermitted {
            DispatchQueue.main.async { completion(.denied) }
            return
        }
        // Steht die Entscheidung noch aus, zeigt macOS gleich einen Dialog. Bis
        // der Nutzer geklickt hat, darf nichts abgebrochen werden; sonst würde
        // die App genau die Freigabe wegwerfen, auf die sie wartet.
        let consentPending = permission == kAEEventWouldRequireUserConsent

        // Die Fensterklasse schließt Infofenster aus. Das vorderste Fenster
        // kommt separat, weil die Liste nicht zuverlässig danach sortiert ist.
        // URL of liefert die übrigen Fenster gebündelt. Eine Schleife mit einem
        // Apple-Event je Fenster dauerte für 13 Fenster 11,6 s statt 147 ms.
        // text item delimiters gehört außerhalb des tell-Blocks, sonst
        // versucht AppleScript, die Eigenschaft am Finder zu setzen (-10006).
        let source = """
        set frontURL to ""
        set allURLs to {}
        tell application "Finder"
            with timeout of 4 seconds
                try
                    set frontURL to URL of (target of front Finder window)
                end try
                try
                    set allURLs to URL of (target of every Finder window)
                end try
            end timeout
        end tell
        if class of allURLs is not list then set allURLs to {allURLs}
        set out to {}
        if frontURL is not "" then set end of out to frontURL
        repeat with u in allURLs
            set p to u as text
            if p is not "" and out does not contain p then set end of out to p
        end repeat
        set text item delimiters to linefeed
        return out as text
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        // stderr wird gelesen, NICHT verworfen: Nur dort steht, ob TCC den
        // Apple-Event verboten hat (-1743/-1744) oder der Finder nicht
        // antwortet (-1712). Ohne diesen Text bliebe jeder Fehlschlag stumm.
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var outcome: FinderScopeOutcome
        do {
            try process.run()
            // Not-Aus, falls osascript trotz AppleScript-Timeout klemmt. 6 s
            // sind gegenüber gemessenen 147 ms reichlich; wartet dagegen ein
            // Consent-Dialog auf den Nutzer, wird nicht abgebrochen. Der
            // Abbruch wird gemeldet, nicht zu „keine Ordner" verschwiegen.
            let killed = Atomic(false)
            let killer: DispatchWorkItem?
            if !consentPending {
                let work = DispatchWorkItem {
                    if process.isRunning {
                        killed.set(true)
                        process.terminate()
                    }
                }
                killer = work
                DispatchQueue.global().asyncAfter(deadline: .now() + 6,
                                                  execute: work)
            } else {
                // Ein offener Systemdialog hat bewusst KEIN Zeitlimit. Nur
                // der Nutzer darf diese TCC-Entscheidung beenden; ein Notaus
                // würde die wartende Freigabe verwerfen.
                killer = nil
            }
            // Beide Pipes gleichzeitig leeren: Läuft stderr voll, während wir
            // nur stdout lesen, blockiert der Unterprozess.
            let group = DispatchGroup()
            let out = Atomic(Data())
            let err = Atomic(Data())
            DispatchQueue.global().async(group: group) {
                out.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global().async(group: group) {
                err.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            }
            group.wait()
            process.waitUntilExit()
            killer?.cancel()

            let text = String(data: out.get(), encoding: .utf8) ?? ""
            let errorText = (String(data: err.get(), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var folders: [String] = []
            for line in text.split(separator: "\n",
                                   omittingEmptySubsequences: true)
                            .map(String.init) {
                // Der Finder liefert `file://`-URLs; Sonderzeichen sind darin
                // prozentkodiert und werden erst von URL richtig aufgelöst.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                var path = URL(string: trimmed)?.path ?? trimmed
                // Ordner-URLs enden auf „/"; Pfade im Rest der App nicht.
                if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if !path.isEmpty && !folders.contains(path) {
                    folders.append(path)
                }
            }

            if killed.get() {
                outcome = .failed("Finder antwortet nicht")
            } else if process.terminationStatus == 0 {
                outcome = folders.isEmpty ? .noWindow : .folders(folders)
            } else if errorText.contains("-1743")
                        || errorText.contains("-1744")
                        || errorText.localizedCaseInsensitiveContains(
                            "not authorized") {
                outcome = .denied
            } else if errorText.contains("-1712") {
                outcome = .failed("Zeitüberschreitung beim Finder")
            } else {
                outcome = .failed(firstLine(of: errorText)
                                  ?? "osascript-Fehler "
                                     + "\(process.terminationStatus)")
            }
        } catch {
            outcome = .failed("osascript nicht startbar")
        }
        let result = outcome
        DispatchQueue.main.async { completion(result) }
    }
}

/// Headless-Diagnose (`--finder-scope`): fragt den Finder genau so wie die App
/// und schreibt eine JSON-Zeile nach stdout. Weil die Abfrage aus DEM Bundle
/// läuft, das auch TCC bewertet, zeigt sie den echten Zugriffsstatus — anders
/// als dasselbe AppleScript aus dem Terminal.
/// Exit-Codes wie im Kern: 0 = Ordner ermittelt, 1 = kein Fenster, 2 = Fehler
/// (auch verweigerter Zugriff).
func runFinderScopeDiagnostic() -> Never {
    // Der Freigabestatus steht getrennt im Ergebnis: Er beantwortet ohne
    // Rateverfahren, ob ein leeres Ergebnis an TCC oder am Finder liegt.
    let permission = finderAutomationPermission()
    let permissionName: String
    switch permission {
    case noErr:                          permissionName = "granted"
    case kAEEventNotPermitted:           permissionName = "denied"
    case kAEEventWouldRequireUserConsent: permissionName = "pending"
    default:                             permissionName = "error \(permission)"
    }
    finderWindowFoldersAsync { outcome in
        var payload: [String: Any] = [
            "status": outcome.statusName,
            "permission": permissionName,
            "folders": outcome.folders,
        ]
        if let problem = outcome.problemText { payload["problem"] = problem }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            print(line)
        }
        switch outcome {
        case .folders:  exit(0)
        case .noWindow: exit(1)
        default:        exit(2)
        }
    }
    // Die Antwort kommt über die Main-Queue; ohne laufenden Runloop käme sie nie.
    RunLoop.main.run()
    exit(2)   // wird nie erreicht
}

/// Erste nicht-leere Zeile eines Fehlertexts (osascript hängt gern mehrere an).
private func firstLine(of text: String) -> String? {
    text.split(separator: "\n").map(String.init).first {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Winziger Thread-sicherer Behälter — die beiden Pipe-Leser laufen auf eigenen
/// Queues und geben ihr Ergebnis hier ab.
private final class Atomic<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
