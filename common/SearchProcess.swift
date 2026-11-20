import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if os(macOS)
let searchDeliveryQueue = DispatchQueue.main
#else
let searchDeliveryQueue = DispatchQueue(label: "favenio.delivery")
#endif

final class SearchDiagnostics {
    /// Höchstlänge einer einzelnen stderr-Zeile, die noch zusammengesetzt
    /// wird. Ein Kern, der eine endlos lange Zeile schriebe, soll den
    /// Puffer nicht wachsen lassen.
    static let lineLimit = 64 * 1024
    /// Die Präfixe, die `favenio.py` seinen stderr-Zeilen voranstellt.
    static let errorPrefix = "favenio: fehler: "
    static let warningPrefix = "favenio: warnung: "

    private let lock = NSLock()
    private var carry = Data()        // angefangene Zeile zwischen Häppchen
    private var warnings = 0
    private var firstError: String?
    /// Die erste stderr-Zeile OHNE Favenio-Präfix. Sie stammt nicht vom
    /// Kern, sondern von dem, was vor ihm steht — und das kann der Grund
    /// eines Fehlschlags sein: `/usr/bin/python3` ist ein Apple-Stummel,
    /// der ohne akzeptierte Xcode-Lizenz „You have not agreed to the Xcode
    /// license agreements" schreibt und mit Status 69 endet, ohne den Kern
    /// je zu starten. Bis 0.34.21 verwarfen beide Apps diese Zeile und
    /// zeigten nur „Suche fehlgeschlagen (Status 69)" (belegt 2026-09-15).
    private var firstForeignLine: String?

    /// Hängt sich an die stderr-Pipe und leert sie fortlaufend.
    func collect(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    /// Nach dem Prozessende: Handler lösen und den Rest nachlesen.
    ///
    /// Die Schreibseite wird VOR dem Lesen geschlossen. `availableData`
    /// blockiert nämlich, solange irgendein Deskriptor die Pipe noch zum
    /// Schreiben offen hält — und genau das ist der Fall, wenn
    /// `process.run()` gescheitert ist: Dann hat das Kind die Pipe nie
    /// bekommen, und niemand sonst schließt sie. Ohne dieses Schließen
    /// hing der Aufruf unbegrenzt. Ein zweites Schließen ist harmlos,
    /// deshalb `try?`.
    func finish(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        append(handle.availableData)
        lock.lock()
        defer { lock.unlock() }
        if !carry.isEmpty {          // letzte Zeile ohne Umbruch
            consume(String(decoding: carry, as: UTF8.self))
            carry.removeAll()
        }
    }

    /// Gezählt wird beim DURCHLAUFEN, nicht am Ende aus einem gedeckelten
    /// Text: Ein Lauf über einen unlesbaren Baum erzeugt beliebig viele
    /// Warnungen, und „470 Objekte übersprungen" wäre schlicht falsch,
    /// wenn es 5000 waren. Gespeichert wird deshalb nichts außer der
    /// ersten Fehlerzeile und dem Zähler.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        carry.append(chunk)
        while let newline = carry.firstIndex(of: 0x0A) {
            let lineData = carry.subdata(in: carry.startIndex..<newline)
            carry.removeSubrange(carry.startIndex...newline)
            consume(String(decoding: lineData, as: UTF8.self))
        }
        if carry.count > SearchDiagnostics.lineLimit {
            carry.removeAll(keepingCapacity: true)
        }
    }

    /// Nur mit gehaltenem `lock` aufrufen.
    private func consume(_ line: String) {
        if line.hasPrefix(SearchDiagnostics.warningPrefix) {
            warnings += 1
        } else if firstError == nil,
                  line.hasPrefix(SearchDiagnostics.errorPrefix) {
            firstError = String(
                line.dropFirst(SearchDiagnostics.errorPrefix.count))
        } else if firstForeignLine == nil {
            // Auch Zeilenenden: Bei CRLF bleibt nach dem Zerlegen am \n ein
            // „\r" stehen, und eine Leerzeile davor würde sonst selbst zum Grund.
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { firstForeignLine = trimmed }
        }
    }

    /// Die erste Fehlerzeile des Kerns, ohne Präfix. Hat der Kern keine
    /// genannt, ersatzweise die erste fremde stderr-Zeile (siehe
    /// `firstForeignLine`) — oder nil. Die Oberflächen zeigen den Text nur
    /// bei einem gescheiterten Lauf; eine harmlose fremde Zeile eines
    /// gelungenen Laufs bleibt damit unsichtbar.
    var errorMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return firstError ?? firstForeignLine
    }

    /// Zahl der stderr-Warnmeldungen, keine eindeutige Objektzahl.
    var warningCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return warnings
    }
}

struct SearchExit {
    let status: Int32
    let reason: Process.TerminationReason
    /// Der Grund eines Fehlschlags, wie der Kern ihn auf stderr genannt hat.
    var errorMessage: String? = nil
    /// Wie viele Objekte der Lauf überspringen musste.
    var warningCount: Int = 0
    var report: SearchReportSnapshot? = nil
}

/// Der Satz, den die Oberfläche bei einem gescheiterten Lauf zeigt.
///
/// Der Kern sagt auf stderr, WAS schiefging — „--metadata braucht exiftool,
/// das nicht gefunden wurde" etwa, oder „ungültiger regulärer Ausdruck".
/// Bis 0.27.1 hing stderr auf `nullDevice`, und beide Apps rieten
/// stattdessen: Die Haupt-App zeigte nur „Suche fehlgeschlagen.", die
/// Schnellsuche riet zu einer Neuinstallation, die nichts half.
func searchFailureText(_ exit: SearchExit) -> String {
    if let message = exit.errorMessage, !message.isEmpty {
        return "Suche fehlgeschlagen: " + message
    }
    if exit.reason != .exit {
        return "Suche abgebrochen (Signal \(exit.status))."
    }
    return "Suche fehlgeschlagen (Status \(exit.status))."
}

/// Zusatz für die Fußzeile, wenn der Lauf Objekte überspringen musste.
///
/// Ohne ihn sieht ein Lauf, der ein kaputtes Archiv oder einen gesperrten
/// Ordner auslassen musste, genauso vollständig aus wie einer, der alles
/// gelesen hat.
func skippedNote(_ count: Int) -> String {
    switch count {
    case 0: return ""
    case 1: return " · 1 Warnung"
    default: return " · \(count) Warnungen"
    }
}

/// grep-Semantik des Python-Kerns: Nur ein REGULÄRER Exit 0 (Treffer) oder 1
/// (keine Treffer) ist normal. Ein Signal ist unabhängig von seiner Nummer ein
/// Fehler und muss in beiden Frontends sichtbar werden.
func searchExitIsError(_ status: Int32,
                       reason: Process.TerminationReason) -> Bool {
    reason != .exit || (status != 0 && status != 1)
}

/// Führt eine Suche BLOCKIEREND aus und liefert Treffer.
///
/// Nur für den Headless-Selbsttest. Beide Oberflächen streamen stattdessen
/// über `runSearchStreaming` — die Schnellsuche seit ihrer Live-Trefferliste
/// ebenfalls. Diese Fassung verwirft nämlich das Prozessende: Ein Fehler
/// (Exit 2) und ein Signalabbruch kommen hier genauso an wie „keine Treffer".
/// Genau das musste in beiden Frontends behoben werden; ein sichtbarer
/// Suchlauf gehört deshalb nicht auf diesen Weg zurück.
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

/// Ein Suchlauf mit eigener Identität und begrenztem Transport zur Main-Queue.
/// JSONL wird ausschließlich auf einem Hintergrundthread gelesen und geparst.
final class SearchRunner {
    static let batchHitLimit = 256
    static let batchByteLimit = 1024 * 1024
    static let recordByteLimit = 1024 * 1024
    static let outstandingLimit = 2

    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private let slots = DispatchSemaphore(value: outstandingLimit)
    private var outstanding = 0
    private var maximumOutstanding = 0
    private var maximumBatchBytes = 0

    /// Messwerte des Transports, ohne Zugriff auf Treffer oder UI-Zustand.
    var transportPeaks: (packets: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (maximumOutstanding, maximumBatchBytes)
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Abbruch gilt auch VOR process.run(). Bei ignoriertem SIGTERM folgt
    /// nach einer halben Sekunde SIGKILL; kein Main-Thread wartet darauf.
    func cancel() {
        lock.lock()
        cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
            lock.lock(); defer { lock.unlock() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Nur beim App-Ende: Danach laufen Dispatch-Completions nicht mehr
    /// verlässlich. Kein normaler Such-/Filterwechsel wartet hier.
    func stopForTermination(deadline: TimeInterval) {
        cancel()
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    func start(arguments: [String], executable: String = pythonPath,
               onBatch: @escaping ([Hit], String?) -> Void,
               onReport: @escaping (SearchReportSnapshot) -> Void = { _ in },
               onDateResolution: @escaping (Data) -> Void = { _ in },
               completion: @escaping (SearchExit) -> Void) {
        lock.lock()
        precondition(!started)
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = read(arguments: arguments, executable: executable,
                              onBatch: onBatch, onReport: onReport, onDateResolution: onDateResolution)
            // Alle Pakete wurden vorher in dieselbe serielle Main-Queue
            // gestellt. completion sieht daher auch die letzte übernommene Zeile.
            searchDeliveryQueue.async { completion(result) }
        }
    }

    private func read(arguments: [String], executable: String,
                      onBatch: @escaping ([Hit], String?) -> Void,
                      onReport: @escaping (SearchReportSnapshot) -> Void,
                      onDateResolution: @escaping (Data) -> Void) -> SearchExit {
        let pipe = Pipe()
        let errPipe = Pipe()
        let diagnostics = SearchDiagnostics()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = errPipe
        diagnostics.collect(from: errPipe)
        lock.lock()
        if cancelled {
            lock.unlock()
            diagnostics.finish(errPipe)
            return SearchExit(status: SIGTERM, reason: .uncaughtSignal)
        }
        do { try process.run() } catch {
            lock.unlock()
            diagnostics.finish(errPipe)
            return SearchExit(status: 2, reason: .exit,
                              errorMessage: error.localizedDescription)
        }
        lock.unlock()
        try? pipe.fileHandleForWriting.close()

        var buffer = Data()
        var hits: [Hit] = []
        var bytes = 0
        var progress: String?
        var report: SearchReportSnapshot?
        var latestReport: SearchReportSnapshot?
        var dateResolution: Data?
        var protocolError: String?
        var lastDelivery = ProcessInfo.processInfo.systemUptime
        func deliver() {
            guard !hits.isEmpty || progress != nil || report != nil || dateResolution != nil else { return }
            // Ein voller Verbraucher bremst den Erzeuger über dessen Pipe.
            // Das kurze Warten prüft Abbruch auch bei blockierter Main-Queue.
            while slots.wait(timeout: .now() + 0.05) != .success {
                if isCancelled { return }
            }
            if isCancelled { slots.signal(); return }
            let packet = hits
            let latestProgress = progress
            let packetReport = report
            let packetDateResolution = dateResolution
            lock.lock()
            outstanding += 1
            maximumOutstanding = max(maximumOutstanding, outstanding)
            maximumBatchBytes = max(maximumBatchBytes, bytes)
            lock.unlock()
            hits = []; bytes = 0; progress = nil; report = nil; dateResolution = nil
            lastDelivery = ProcessInfo.processInfo.systemUptime
            searchDeliveryQueue.async { [self] in
                defer {
                    lock.lock(); outstanding -= 1; lock.unlock()
                    slots.signal()
                }
                if !isCancelled {
                    if let packetReport { onReport(packetReport) }
                    if let packetDateResolution { onDateResolution(packetDateResolution) }
                    onBatch(packet, latestProgress)
                }
            }
        }
        func consume(_ line: Data) {
            guard !line.isEmpty else { return }
            if line.count > Self.recordByteLimit {
                protocolError = "Suchausgabe: JSONL-Zeile überschreitet 1 MiB."
                cancel()
                return
            }
            // Auch ein einzelner langer Dateiname belegt Transportbudget.
            if bytes + line.count > Self.batchByteLimit { deliver() }
            // Foundation-Temporaries gehören zur Zeile, nicht zum ganzen
            // lang laufenden Dispatch-Work-Item. Hits bleiben per ARC erhalten.
            let parsed = autoreleasepool { parseSearchLine(line) }
            switch parsed {
            case .hit(let hit)?: hits.append(hit); bytes += line.count
            case .progress(let path)?: progress = path; bytes += line.count
            case .report(let value)?: report = value; latestReport = value; bytes += line.count
            case .dateResolution(let value)?: dateResolution = value; bytes += line.count
            case .invalidDateResolution?:
                protocolError = "Datumsbeleg: ungültiges Schema oder überschrittene Beleggrenze."
                cancel()
            case .invalidReport?:
                protocolError = "Suchbericht: ungültiges Schema oder überschrittene Berichtsgrenze."
                cancel()
            case nil: break
            }
            if hits.count >= Self.batchHitLimit || bytes >= Self.batchByteLimit {
                deliver()
            }
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !isCancelled {
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&state, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                protocolError = "Suchausgabe konnte nicht gelesen werden."
                cancel(); break
            }
            if ready == 0 {
                if ProcessInfo.processInfo.systemUptime - lastDelivery >= 0.05 { deliver() }
                continue
            }
            #if canImport(Darwin)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            #else
            let count = Glibc.read(descriptor, &chunk, chunk.count)
            #endif
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                protocolError = "Suchausgabe konnte nicht gelesen werden."
                cancel(); break
            }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A), !isCancelled {
                consume(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if buffer.count > Self.recordByteLimit {
                protocolError = "Suchausgabe: JSONL-Zeile überschreitet 1 MiB."
                cancel()
            }
            if ProcessInfo.processInfo.systemUptime - lastDelivery >= 0.05 { deliver() }
        }
        if !isCancelled { consume(buffer); deliver() }
        try? pipe.fileHandleForReading.close()
        // EOF und Prozessende dürfen in jeder Reihenfolge kommen. Erst
        // nachdem BEIDES abgeschlossen ist, steht der Suchstatus fest.
        process.waitUntilExit()
        diagnostics.finish(errPipe)
        return SearchExit(status: protocolError == nil ? process.terminationStatus : 2,
                          reason: protocolError == nil ? process.terminationReason : .exit,
                          errorMessage: protocolError ?? diagnostics.errorMessage,
                          warningCount: diagnostics.warningCount, report: latestReport)
    }
}

/// Synchroner Adapter für Headless-Diagnosen; beide Oberflächen verwenden
/// SearchRunner direkt. Auf Main wird beim Warten die Queue weiter bedient.
func runSearchStreaming(arguments: [String],
                        onHit: ((Hit) -> Void)? = nil,
                        onProgress: @escaping (String) -> Void) -> SearchExit {
    let runner = SearchRunner()
    let done = DispatchSemaphore(value: 0)
    var result: SearchExit?
    runner.start(arguments: arguments, onBatch: { hits, progress in
        for hit in hits { onHit?(hit) }
        if let progress { onProgress(progress) }
    }, completion: { exit in result = exit; done.signal() })
    if Thread.isMainThread {
        while done.wait(timeout: .now()) != .success {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    } else { done.wait() }
    return result!
}

/// Ergebnis eines Materialisierungsauftrags.
enum MaterializationOutcome: Equatable {
    case ready(URL)
    /// Der konkrete Grund — die Fehlerzeile des Kerns oder, wenn er keine
    /// schrieb, was auf unserer Seite scheiterte.
    case failed(String)
    case cancelled
}

/// Griff auf einen laufenden Auftrag. `cancel()` nimmt nur DIESEN Anforderer
/// vom Auftrag; der Unterprozess endet erst, wenn niemand mehr wartet. Die
/// Completion kommt genau einmal. Bis zum Beginn ihrer Zustellung gilt ein
/// Abbruch auch dann noch, wenn der Worker seine Datei bereits geliefert hat.
final class MaterializationRequest {
    fileprivate let hit: Hit
    fileprivate let epoch: Int
    // Ausschließlich unter MaterializationManager.lock lesen und ändern.
    fileprivate var cancelled = false
    fileprivate var delivered = false
    fileprivate var leaseCleanup: (() -> Void)?
    fileprivate var ephemeral = false
    private weak var manager: MaterializationManager?

    fileprivate init(hit: Hit, epoch: Int, manager: MaterializationManager) {
        self.hit = hit
        self.epoch = epoch
        self.manager = manager
    }

    func cancel() { manager?.cancel(self) }
    func release() { manager?.release(self) }
}

/// Appweiter Cache: jede Aktion auf denselben Archivtreffer verwendet dieselbe
/// materialisierte Datei. Alle Kopien liegen unter einem eindeutigen Root und
/// werden beim App-Ende gemeinsam entfernt.
///
/// Seit 0.32.0 asynchron: `request()` startet den Python-Kern im Hintergrund
/// und liefert das Ergebnis auf der Main-Queue. Bis 0.31.4 las
/// `materialize()` stdout synchron und wartete mit `waitUntilExit()` — auf
/// dem Main-Thread, aus Öffnen, Quick Look und Drag-and-drop heraus.
/// Gemessen am 2026-09-05 (`tests/MATERIALIZATION_MEASUREMENTS.md`) fror
/// das Fenster dabei so lange ein, wie der Kern brauchte.
///
/// Drei Zusagen, jede durch die Probe `tests/materialization_probe.swift`
/// geprüft:
/// - Gleichzeitige Anforderungen desselben Treffers mit gleicher Zugriffsregel teilen EINEN
///   Unterprozess und dieselbe Datei (`jobs`).
/// - stderr wird nebenläufig geleert (`SearchDiagnostics.collect`), sonst
///   hält eine volle Pipe den Kern an, während wir auf stdout warten.
/// - Nach `cleanup()` legt kein noch laufender Auftrag eine Datei neu an:
///   `epoch` markiert jeden Auftrag, ein zu spätes Ergebnis wird gelöscht
///   und als `.cancelled` gemeldet.
final class MaterializationManager {
    static let shared = MaterializationManager()

    /// Haken für Tests: anderer Interpreter, Kern, Zusatzargumente und eigene
    /// Temp-Wurzel. Foundation beachtet TMPDIR nicht auf jedem macOS-System.
    /// Die Apps lassen diese Werte auf ihren Vorgaben.
    var interpreter = pythonPath
    var cliPath: String?
    var extraArguments: [String] = []
    var temporaryDirectory = FileManager.default.temporaryDirectory

    private let lock = NSLock()
    // Schlüssel ist die IDENTITÄT, nicht der ganze Treffer: Anzeige und
    // Suchbelege (`line`, `terms`, `width`, `modified`) ändern sich mit der
    // Suche, das Objekt dahinter nicht. Bis 0.34.14 waren derselbe
    // Archiv-Eintrag aus einer Namenssuche und aus einer Inhaltssuche zwei
    // Cache-Einträge und zwei Unterprozesse in zwei Temp-Ordner — gegen die
    // Zusage, dass gleichzeitige Anforderungen desselben Treffers EINEN
    // Unterprozess und dieselbe Datei teilen.
    private final class CachedFile {
        let url: URL
        let source: ContentSourceGeneration?
        let leaf: ContentSourceGeneration?
        var retained: Bool
        var pins = 0
        init(url: URL, source: ContentSourceGeneration?, leaf: ContentSourceGeneration?, retained: Bool) {
            self.url = url
            self.source = source
            self.leaf = leaf
            self.retained = retained
        }
    }
    private var cache: [HitIdentity: CachedFile] = [:]
    private var jobs: [HitIdentity: Job] = [:]
    private var root: URL?
    private var epoch = 0
    /// Auspackaufträge laufen nebenläufig, aber GEDECKELT. Eine einzige
    /// Nutzeraktion — Leertaste, Doppelklick oder „Im Finder zeigen" auf
    /// einer großen Auswahl — erzeugt einen Auftrag je Archivtreffer, und
    /// jeder blockiert in `readDataToEndOfFile()` plus `waitUntilExit()`.
    /// Ohne Deckel wuchs der GCD-Threadpool bis an seine Decke: 200
    /// Einträge mit einer 3-s-Attrappe waren nach 9,3 s fertig, also rund
    /// 64 gleichzeitige Aufträge; mit dem echten Kern lief die Spitze auf
    /// 25 gleichzeitige Python-Prozesse. Der Folgeschaden traf die Suche,
    /// die denselben globalen Pool nimmt: Ihr erster Treffer kam nach
    /// 5,19 s statt 0,02 s (alles gemessen am 2026-09-10).
    ///
    /// `OperationQueue` statt eines Semaphors: Wartende Aufträge belegen
    /// dort keinen Thread. Ein Semaphor auf einer nebenläufigen
    /// `DispatchQueue` würde genau die Threads blockieren, die es sparen
    /// soll. Ein zu spät startender Auftrag ist unschädlich — `execute()`
    /// prüft `job.cancelled` und `epoch`, bevor es einen Prozess startet.
    static let maximumConcurrentExtractions = 4
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "favenio.materialize"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount =
            MaterializationManager.maximumConcurrentExtractions
        return queue
    }()

    /// Ein laufender Auspackvorgang samt allen, die auf ihn warten.
    private final class Job {
        let hit: Hit
        let epoch: Int
        let source: ContentSourceGeneration?
        let localOnly: Bool
        var waiters: [(MaterializationRequest, (MaterializationOutcome) -> Void)] = []
        var process: Process?
        var cancelled = false
        var retained = true
        init(hit: Hit, epoch: Int, source: ContentSourceGeneration?, localOnly: Bool) {
            self.localOnly = localOnly
            self.hit = hit
            self.epoch = epoch
            self.source = source
        }
    }

    /// Nur mit gehaltenem `lock` aufrufen.
    private func materializationRootLocked() -> URL? {
        if let root { return root }
        let candidate = temporaryDirectory
            .appendingPathComponent("Favenio-\(UUID().uuidString)",
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

    /// Die URL, die OHNE Auspacken feststeht: eine normale Datei oder ein
    /// Ordner im Dateisystem, oder ein schon ausgepackter Eintrag. nil heißt
    /// „muss erst ausgepackt werden" — oder „gibt es nicht" (Ordner im
    /// Archiv, siehe `Hit.hasOpenableFile`). Drag-and-drop fragt hier, weil
    /// AppKit im Pasteboard-Callback sofort eine Antwort will.
    func knownURL(for hit: Hit) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let source = cache[hit.identity] != nil || hit.contentPreview?.sourceGeneration != nil
            ? ContentSourceGeneration.current(hit.filesystemPathData) : nil
        let url = knownURLLocked(for: hit, source: source)
        if url != nil { cache[hit.identity]?.retained = true }
        return url
    }

    /// Nur mit gehaltenem Lock: request() verbindet dieselbe Cacheprüfung
    /// mit der Auftragswahl. Dazwischen darf finish() keinen Job entfernen.
    private func knownURLLocked(for hit: Hit, source: ContentSourceGeneration?) -> URL? {
        if let expected = hit.contentPreview?.sourceGeneration,
           source != expected { return nil }
        if !hit.isMember {
            return URL(fileURLWithPath: hit.filesystemPath)
        }
        if hit.isDirectory { return nil }
        if let cached = cache[hit.identity] {
            guard source == cached.source, let leaf = cached.leaf,
                  ContentSourceGeneration.current(cached.url.path) == leaf else {
                cache.removeValue(forKey: hit.identity)
                return nil
            }
            return cached.url
        }
        return nil
    }

    func generationSnapshot(for hit: Hit, url: URL) -> (source: ContentSourceGeneration, leaf: ContentSourceGeneration)? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = cache[hit.identity], cached.url.path.utf8.elementsEqual(url.path.utf8),
              let source = cached.source, let leaf = cached.leaf else { return nil }
        return (source, leaf)
    }

    /// Fordert die Datei hinter einem Treffer an.
    ///
    /// Steht sie schon fest (`knownURL`), kommt die Completion SOFORT und
    /// synchron auf dem rufenden Thread. Normale Abrufe liefern dabei nil;
    /// befristete Abrufe liefern eine Lease, die nach jedem Ausgang mit
    /// release() freigegeben werden muss.
    /// Sonst läuft der Kern im Hintergrund, die Completion kommt auf der
    /// Main-Queue, und der Griff erlaubt den Abbruch. Läuft für denselben
    /// Treffer schon ein Auftrag mit gleicher Zugriffsregel, hängt sich die
    /// Anforderung an ihn. Abweichende Regeln werden bis zu dessen Ende abgelehnt.
    @discardableResult
    func request(_ hit: Hit, localOnly: Bool = false,
                 ephemeral: Bool = false,
                 completion: @escaping (MaterializationOutcome) -> Void)
        -> MaterializationRequest? {
        lock.lock()
        let source = hit.isMember || hit.contentPreview?.sourceGeneration != nil
            ? ContentSourceGeneration.current(hit.filesystemPathData, localOnly: localOnly) : nil
        if let expected = hit.contentPreview?.sourceGeneration,
           source != expected {
            lock.unlock()
            completion(.failed("Quelle stimmt nicht mehr mit der Fundstellenvorschau überein. Bitte neu suchen."))
            return nil
        }
        if let url = knownURLLocked(for: hit, source: source) {
            if ephemeral, let cached = cache[hit.identity] {
                let request = MaterializationRequest(hit: hit, epoch: epoch, manager: self)
                request.ephemeral = true
                request.delivered = true
                pin(request, cached: cached)
                lock.unlock()
                completion(.ready(url))
                return request
            }
            cache[hit.identity]?.retained = true
            lock.unlock()
            completion(.ready(url))
            return nil
        }
        // Ein ORDNER im Archiv hat keinen Inhalt zum Herausschreiben: Bei ZIP
        // entstand dabei eine leere Datei, bei TAR scheiterte die Extraktion
        // (Review-Fund 2026-08-17). Dateiaktionen gibt es dafür deshalb nicht;
        // sichtbar bleibt der Treffer trotzdem.
        if hit.isDirectory {
            lock.unlock()
            completion(.failed("Ordner im Archiv — keine Datei zum Öffnen"))
            return nil
        }
        let request = MaterializationRequest(hit: hit, epoch: epoch, manager: self)
        request.ephemeral = ephemeral
        // Ein Auftrag, den alle verlassen haben, stirbt gerade; ihm darf
        // sich niemand mehr anschließen — er endete mit `.cancelled`.
        if let job = jobs[hit.identity], !job.cancelled {
            guard job.localOnly == localOnly else {
                lock.unlock()
                completion(.failed("Für diese Datei läuft ein Abruf mit anderer Zugriffsregel. Bitte nach dessen Abschluss erneut versuchen."))
                return nil
            }
            if !ephemeral { job.retained = true }
            job.waiters.append((request, completion))
            lock.unlock()
            return request
        }
        let job = Job(hit: hit, epoch: epoch, source: source, localOnly: localOnly)
        job.retained = !ephemeral
        job.waiters.append((request, completion))
        jobs[hit.identity] = job
        lock.unlock()
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.finish(job, with: self.execute(job))
        }
        return request
    }

    // Miniaturen halten dieselbe Datei nur während des Decodierens fest.
    // Ein ausdrücklicher Dateiabruf behält sie weiterhin bis zum App-Ende.
    private func pin(_ request: MaterializationRequest, cached: CachedFile) {
        cached.pins += 1
        let identity = request.hit.identity
        request.leaseCleanup = { [weak self] in self?.releaseCached(cached, identity: identity) }
    }
    fileprivate func release(_ request: MaterializationRequest) {
        lock.lock()
        let cleanup = request.leaseCleanup
        request.leaseCleanup = nil
        lock.unlock()
        cleanup?()
    }
    private func releaseCached(_ cached: CachedFile, identity: HitIdentity) {
        lock.lock()
        cached.pins -= 1
        let discardFile = cached.pins == 0 && !cached.retained
        if discardFile && cache[identity] === cached { cache[identity] = nil }
        lock.unlock()
        if discardFile { DispatchQueue.global(qos: .utility).async { self.discard(cached.url) } }
    }

    /// Nimmt einen Anforderer vom Auftrag. Der letzte beendet den Prozess.
    fileprivate func cancel(_ request: MaterializationRequest) {
        lock.lock()
        guard !request.cancelled && !request.delivered else {
            lock.unlock()
            release(request)
            return
        }
        // finish() kann den Job bereits entfernt haben. Die eingereihte
        // Completion hält den Request und sieht diese Markierung trotzdem.
        request.cancelled = true
        guard let job = jobs[request.hit.identity],
              let index = job.waiters.firstIndex(where: { $0.0 === request })
        else {
            lock.unlock()
            release(request)
            return
        }
        let (_, completion) = job.waiters.remove(at: index)
        if job.waiters.isEmpty { terminateLocked(job) }
        lock.unlock()
        release(request)
        searchDeliveryQueue.async { self.deliver(request, .cancelled, completion) }
    }

    /// Auf Main, unmittelbar vor JEDER Completion prüfen: Die vorige darf
    /// einen weiteren Request abbrechen oder cleanup() auslösen. Den Lock
    /// vor dem Aufruf freigeben, damit solche Rückrufe nicht blockieren.
    private func deliver(_ request: MaterializationRequest,
                         _ outcome: MaterializationOutcome,
                         _ completion: (MaterializationOutcome) -> Void) {
        lock.lock()
        guard !request.delivered else { lock.unlock(); return }
        let result = request.cancelled || request.epoch != epoch
            ? .cancelled : outcome
        request.delivered = true
        lock.unlock()
        completion(result)
    }

    /// Nur mit gehaltenem `lock` aufrufen. SIGTERM übersetzt der Kern in ein
    /// normales Ende (`install_termination_handlers`); bleibt er trotzdem
    /// stehen, folgt nach einer Sekunde SIGKILL — wie im SearchRunner.
    private func terminateLocked(_ job: Job) {
        job.cancelled = true
        guard let process = job.process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Läuft auf `queue`: startet den Kern und wartet auf ihn — hier darf
    /// gewartet werden, das ist nicht der Main-Thread.
    private func execute(_ job: Job) -> MaterializationOutcome {
        lock.lock()
        let stale = job.cancelled || job.epoch != epoch
        let root = stale ? nil : materializationRootLocked()
        lock.unlock()
        if stale { return .cancelled }
        guard let root else {
            return .failed("Temp-Ordner für ausgepackte Dateien nicht anlegbar")
        }
        guard let cli = cliPath ?? findCLI() else {
            return .failed("favenio.py nicht gefunden")
        }
        var object: [String: Any] = [
            "filesystemPath": job.hit.filesystemPath,
            "archiveMembers": job.hit.archiveMembers,
        ]
        if let raw = job.hit.filesystemPathBytes {
            object["filesystemPathBytes"] = raw.base64EncodedString()
        }
        if !job.hit.archiveMemberBytes.isEmpty {
            object["archiveMemberBytes"] = job.hit.archiveMemberBytes
        }
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              let jsonText = String(data: json, encoding: .utf8) else {
            return .failed("Treffer nicht als JSON darstellbar")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        var limits: [String] = []
        if let budget = job.hit.contentPreview?.archiveLimits {
            limits = ["--max-archive-member-bytes", String(budget.memberBytes),
                      "--max-archive-total-bytes", String(budget.totalBytes),
                      "--max-archive-ratio", String(budget.ratio)]
        }
        process.arguments = [cli, "--extract-json", jsonText,
                             "--extract-root", root.path] + (job.localOnly ? ["--local-only"] : []) + limits + extraArguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        // stderr NEBENLÄUFIG leeren — dieselbe Wache wie beim Suchlauf: Eine
        // volle Pipe hält den Kern an, während wir auf sein stdout warten.
        let diagnostics = SearchDiagnostics()
        diagnostics.collect(from: errors)
        lock.lock()
        if job.cancelled {
            lock.unlock()
            diagnostics.finish(errors)
            return .cancelled
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            diagnostics.finish(errors)
            return .failed("Python-Kern nicht startbar: "
                           + error.localizedDescription)
        }
        job.process = process
        lock.unlock()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        diagnostics.finish(errors)
        lock.lock()
        let cancelled = job.cancelled
        lock.unlock()
        // print(out_path) hängt genau ein LF-Byte an. Leerraum davor gehört
        // zum Dateinamen; auch ein CR vor dem LF darf nicht verschwinden.
        let pathData = data.last == 0x0A ? data.dropLast() : data
        let path = String(data: pathData, encoding: .utf8) ?? ""
        if cancelled {
            // Der Kern war womöglich schneller als das Signal: Was er
            // schon geschrieben hat, will niemand mehr.
            if !path.isEmpty { discard(URL(fileURLWithPath: path)) }
            return .cancelled
        }
        guard process.terminationStatus == 0, !path.isEmpty else {
            return .failed(diagnostics.errorMessage
                ?? "Auspacken fehlgeschlagen (Status "
                   + "\(process.terminationStatus))")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed("Ausgepackte Datei fehlt: " + path)
        }
        return .ready(URL(fileURLWithPath: path))
    }

    /// Entfernt eine ausgepackte Datei samt ihrem `hit-…`-Ordner.
    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Trägt das Ergebnis ein und benachrichtigt alle Wartenden auf Main.
    private func finish(_ job: Job, with result: MaterializationOutcome) {
        var outcome = result
        let changed: Bool
        if case .ready = result { changed = ContentSourceGeneration.current(job.hit.filesystemPathData, localOnly: job.localOnly) != job.source }
        else { changed = false }
        lock.lock()
        if job.cancelled || job.epoch != epoch {
            // Abbruch kann zwischen execute() und diesem Lock eintreffen.
            if case .ready(let url) = outcome { discard(url) }
            outcome = .cancelled
        } else if case .ready(let url) = outcome {
            if changed {
                discard(url)
                outcome = .failed("Quelle wurde während des Auspackens verändert. Bitte erneut anfordern.")
            } else {
                let cached = CachedFile(url: url, source: job.source, leaf: ContentSourceGeneration.current(url.path), retained: job.retained)
                cache[job.hit.identity] = cached
                for (request, _) in job.waiters where request.ephemeral && !request.cancelled { pin(request, cached: cached) }
            }
        }
        if jobs[job.hit.identity] === job { jobs[job.hit.identity] = nil }
        let waiters = job.waiters
        job.waiters = []
        lock.unlock()
        guard !waiters.isEmpty else { return }
        let deliveredOutcome = outcome
        searchDeliveryQueue.async {
            waiters.forEach { self.deliver($0.0, deliveredOutcome, $0.1) }
        }
    }

    /// Bricht alle laufenden Aufträge ab und entfernt alle ausgepackten
    /// Dateien. Ein Auftrag, der danach noch zu Ende kommt, löscht sein
    /// Ergebnis selbst (`epoch`).
    func cleanup() {
        lock.lock()
        epoch += 1
        jobs.values.forEach { terminateLocked($0) }
        jobs.removeAll()
        cache.removeAll()
        let old = root
        root = nil
        lock.unlock()
        if let old { try? FileManager.default.removeItem(at: old) }
    }
}

/// Synchron — NUR für den Headless-Selbsttest und Werkzeuge. Auf dem
/// Main-Thread dreht die RunLoop weiter, bis die Completion da ist; die
/// Apps rufen das aus keiner Aktion, dort gilt `request()`.
func materializeHit(_ hit: Hit) -> URL? {
    var result: MaterializationOutcome?
    let done = DispatchSemaphore(value: 0)
    MaterializationManager.shared.request(hit) {
        result = $0
        done.signal()
    }
    if Thread.isMainThread {
        while done.wait(timeout: .now()) != .success {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    } else {
        done.wait()
    }
    if case .ready(let url)? = result { return url }
    return nil
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
        // Foundation-Zwischenobjekte nach jeder Zeile freigeben. Die
        // fertigen UTF-8-Bytes bleiben im gemeinsamen Ausgabepuffer.
        autoreleasepool {
            var object: [String: Any] = ["path": hit.path, "type": hit.kind,
                                         "isDirectory": hit.isDirectory]
            object["filesystemPath"] = hit.filesystemPath
            if let raw = hit.filesystemPathBytes { object["filesystemPathBytes"] = raw.base64EncodedString() }
            object["archiveMembers"] = hit.archiveMembers
            if let searchRoot = hit.searchRoot { object["searchRoot"] = searchRoot }
            if hit.filesystemPathBytes != nil, let raw = hit.searchRootBytes { object["searchRootPathBytes"] = raw.base64EncodedString() }
            if !hit.archiveMemberBytes.isEmpty {
                object["archiveMemberBytes"] = hit.archiveMemberBytes
            }
            if let contentEncoding = hit.contentEncoding { object["contentEncoding"] = contentEncoding }
            if let contentPreview = hit.contentPreview { object["contentPreview"] = contentPreview.json }
            if let documentPosition = hit.documentPosition { object["documentPosition"] = documentPosition.json }
            if let documentSourceGeneration = hit.documentSourceGeneration { object["documentSourceGeneration"] = documentSourceGeneration.json }
            if let line = hit.line { object["line"] = line }
            if let size = hit.size { object["size"] = size }
            if let field = hit.field, let value = hit.value {
                object["field"] = field
                object["value"] = value
            }
            if let width = hit.width, let height = hit.height {
                object["width"] = width
                object["height"] = height
            }
            if let modified = hit.modified { object["modified"] = modified }
            if let created = hit.created { object["created"] = created }
            if !hit.terms.isEmpty { object["terms"] = hit.terms.map { $0.json } }
            if !hit.criteriaEvidence.isEmpty {
                object["criteriaEvidence"] = hit.criteriaEvidence.map { $0.json }
            }
            if var encoded = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) {
                if let snapshot = hit.finderMetadata {
                    encoded.removeLast()
                    encoded.append(Data(",\"finderMetadata\":".utf8))
                    encoded.append(snapshot.json)
                    encoded.append(125)
                }
                if hit.filesystemPathBytes != nil {
                    encoded = Data([123]) + Data("\"type\":\"hitV2\",\"schemaVersion\":2,\"hit\":".utf8) + encoded + Data([125])
                }
                data.append(encoded)
                data.append(0x0A)
            }
        }
    }
    return data
}

let quickHandoffPrefix = "favenio-quick-"
let quickHandoffSuffix = ".jsonl"
let maximumHandoffBytes = 8 * 1024 * 1024
let maximumHandoffLineBytes = 1024 * 1024
let maximumQuickURLBytes = 262_144

enum QuickHandoffFormat: Int, CaseIterable {
    case legacy = 1, selection = 2, roots = 3, dates = 4, finder = 5
    case local = 6, ocr = 7, pdfOCR = 8, pptxOCR = 9

    private struct Feature {
        let format: QuickHandoffFormat
        let option: KeyPath<SearchConfiguration, Bool>
        let label: String
        let bundleKey: String
        let headerKey: String?
    }

    private static let features: [Feature] = [
        .init(format: .dates, option: \.requiresDateRanges, label: "Kalenderbereiche",
              bundleKey: "FavenioDateRangeSchemaVersion", headerKey: nil),
        .init(format: .finder, option: \.requiresFinderMetadata, label: "Finder-Eigenschaften",
              bundleKey: "FavenioFinderMetadataSchemaVersion", headerKey: "finderMetadataCapability"),
        .init(format: .local, option: \.localOnly, label: "Lokale Inhalte",
              bundleKey: "FavenioLocalContentSchemaVersion", headerKey: "localContentCapability"),
        .init(format: .ocr, option: \.ocr, label: "Bild-OCR",
              bundleKey: "FavenioOCRSchemaVersion", headerKey: "ocrCapability"),
        .init(format: .pdfOCR, option: \.pdfOCR, label: "PDF-OCR",
              bundleKey: "FavenioPDFOCRSchemaVersion", headerKey: "pdfOCRCapability"),
        .init(format: .pptxOCR, option: \.pptxOCR, label: "PPTX-Bild-OCR",
              bundleKey: "FavenioPPTXOCRSchemaVersion", headerKey: "pptxOCRCapability"),
    ]

    var host: String { self == .legacy ? "results" : "results-v\(rawValue)" }
    var hasHeader: Bool { self != .legacy }
    var hasRoots: Bool { rawValue >= Self.roots.rawValue }
    var hasFrozenOptions: Bool { rawValue >= Self.dates.rawValue }

    init?(host: String) {
        guard let format = Self.allCases.first(where: { $0.host == host }) else { return nil }
        self = format
    }

    private static func requiredFeatures(_ options: SearchConfiguration, finderSnapshots: Bool = false) -> [Feature] {
        features.filter { options[keyPath: $0.option] || ($0.format == .finder && finderSnapshots) }
    }

    static func forSending(_ options: SearchConfiguration, rootCount: Int, hasSelection: Bool,
                           finderSnapshots: Bool) -> Self {
        if let feature = requiredFeatures(options, finderSnapshots: finderSnapshots).last { return feature.format }
        if rootCount > 1 { return .roots }
        return options.requiresTransportVersion2 || hasSelection ? .selection : .legacy
    }

    func optionProblem(_ options: SearchConfiguration, explicitEncoding: Bool = false) -> String? {
        if !hasHeader && (options.criteriaJSON != nil || explicitEncoding || options.textEncoding != .utf8) {
            return "Kriterien und Textkodierung benötigen Übergabeformat 2."
        }
        guard let feature = Self.requiredFeatures(options).first(where: { $0.format.rawValue > rawValue }) else { return nil }
        return "Für \(feature.label) ist Übergabeformat \(feature.format.rawValue) erforderlich."
    }

    func missingSupport(_ info: [String: Any], options: SearchConfiguration, finderSnapshots: Bool) -> String? {
        if options.textEncoding != .utf8 && !SearchConfiguration.supportsOCRCapability(info["FavenioTextEncodingVersion"]) {
            return "Textkodierung"
        }
        if hasHeader {
            guard let maximum = Self.decode(info["FavenioQuickHandoffVersion"]), maximum.rawValue >= rawValue else {
                return "Übergabeformat \(rawValue)"
            }
        }
        return Self.requiredFeatures(options, finderSnapshots: finderSnapshots).first {
            !SearchConfiguration.supportsOCRCapability(info[$0.bundleKey])
        }?.label
    }

    static func decode(_ value: Any?) -> Self? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return allCases.first { Double($0.rawValue) == number.doubleValue }
    }

    var headerCapabilities: [String] {
        Self.features.filter { $0.format.rawValue <= rawValue }.compactMap(\.headerKey)
    }

    func acceptsHeader(_ object: [String: Any]) -> Bool {
        var keys: Set<String> = ["type", "schemaVersion", "selection"]
        if hasRoots { keys.insert("roots") }
        if hasFrozenOptions { keys.formUnion(["options", "dateResolution"]) }
        let capabilities = headerCapabilities
        return hasHeader && Set(object.keys) == keys.union(capabilities)
            && capabilities.allSatisfy { SearchConfiguration.supportsOCRCapability(object[$0]) }
    }

    func acceptsFile(_ options: SearchConfiguration?, dateResolution: Data?, hits: [Hit]) -> Bool {
        if let options {
            let finderSnapshots = hits.contains { $0.finderMetadata != nil }
            guard hasFrozenOptions, Self.requiredFeatures(options, finderSnapshots: finderSnapshots).last?.format == self else { return false }
            if options.requiresDateRanges {
                guard options.dateReferenceTime != nil,
                      dateResolution.map({ DateRangeTransport.bound($0, to: options) }) ?? hits.isEmpty else { return false }
            } else if dateResolution != nil { return false }
        } else if hasFrozenOptions || dateResolution != nil { return false }
        return hits.allSatisfy { hit in
            let encoding = hit.contentEncoding ?? ""
            return (rawValue >= Self.finder.rawValue || hit.finderMetadata == nil)
                && (encoding != "vision-ocr-text-v1" || options?.ocr == true)
                && (encoding != "pdfkit-vision-text-v1" || rawValue >= Self.pdfOCR.rawValue)
                && (DocumentPosition.pptxOCREncodings[encoding] == nil || options?.pptxOCR == true)
        }
    }
}

func quickHandoffInputProblem(query: String, root: String) -> String? {
    if query.utf8.count > 4096 {
        return "Suchtext ist zu lang für die Übergabe an Favenio (maximal 4096 UTF-8-Bytes)."
    }
    if root.utf8.count > 4096 {
        return "Suchpfad ist zu lang für die Übergabe an Favenio (maximal 4096 UTF-8-Bytes)."
    }
    return nil
}

/// Schreibt die Quick→Haupt-App-Übergabe atomar und nur für den Besitzer.
func writeQuickHandoff(_ hits: [Hit], selection: Set<HitIdentity> = [], version: Int = 1, roots: [String]? = nil,
                       configuration: SearchConfiguration? = nil, dateResolution: Data? = nil,
                       continuingSearch: Bool = false) throws -> URL {
    guard let format = QuickHandoffFormat(rawValue: version), selection.count <= 20,
          format.hasHeader || selection.isEmpty,
          configuration.map({ SearchConfiguration.transportProblem($0.queryItems) == nil }) ?? true
    else { throw CocoaError(.fileWriteUnknown) }
    var headerData = Data()
    var header: [String: Any] = [:]
    var identities: [[String: Any]] = []
    var transferredSelection: Set<HitIdentity> = []
    func encodeHeader(_ identities: [[String: Any]]) throws -> Data {
        var object = header
        object["selection"] = identities
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(10)
        return line
    }
    if format.hasHeader {
        header = ["type": "quickHandoff", "schemaVersion": version]
        if let roots { header["roots"] = roots }
        if let configuration {
            header["options"] = configuration.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }
            header["dateResolution"] = dateResolution.flatMap { preservedJSONObject($0) } ?? NSNull()
        }
        for key in format.headerCapabilities { header[key] = 1 }
        headerData = try encodeHeader(identities)
    }
    guard headerData.count <= maximumHandoffLineBytes + 1 else { throw CocoaError(.fileWriteOutOfSpace) }
    var rows = Data()
    var seed: [Hit] = []
    for hit in hits {
        let line = jsonlData(for: [hit])
        guard !line.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        guard line.count <= maximumHandoffLineBytes + 1 else {
            if continuingSearch { continue }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let rowBytes = rows.count + line.count
        guard headerData.count + rowBytes <= maximumHandoffBytes else {
            if continuingSearch { break }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let identity = hit.identity
        if selection.contains(identity), !transferredSelection.contains(identity) {
            let entry: [String: Any] = ["filesystemPath": hit.filesystemPath, "archiveMembers": hit.archiveMembers,
                                        "archiveMemberBytes": hit.archiveMemberBytes]
            let candidate = try encodeHeader(identities + [entry])
            if candidate.count <= maximumHandoffLineBytes + 1, candidate.count + rowBytes <= maximumHandoffBytes {
                headerData = candidate
                identities.append(entry)
                transferredSelection.insert(identity)
            } else if !continuingSearch {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        rows.append(line)
        seed.append(hit)
    }
    // Nur die übergebenen Treffer dürfen Wurzeln, Auswahl und Belege bestätigen.
    guard (continuingSearch || selection == transferredSelection),
          format.acceptsFile(configuration, dateResolution: dateResolution, hits: seed)
    else { throw CocoaError(.fileWriteUnknown) }
    if format.hasRoots {
        guard let roots, SearchRoots.problem(roots) == nil,
              Set(seed.map { $0.identity }).count == seed.count,
              seed.allSatisfy({ $0.searchRootBytes != nil && SearchRoots(roots).carrying($0) != nil })
        else { throw CocoaError(.fileWriteUnknown) }
    } else if roots != nil { throw CocoaError(.fileWriteUnknown) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        quickHandoffPrefix + UUID().uuidString + quickHandoffSuffix)
    headerData.append(rows)
    try headerData.write(to: url, options: .atomic)
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
struct QuickHandoffPayload {
    var hits: [Hit] = []
    var selection: Set<HitIdentity> = []
    var version = 1
    var roots: [String]?
    var configuration: SearchConfiguration?
    var dateResolution: Data?

    func bound(to paths: [String]) -> QuickHandoffPayload? {
        let scope = SearchRoots(paths)
        guard SearchRoots.problem(paths, limited: paths.count != 1) == nil,
              roots == nil || roots!.map({ Data($0.utf8) }) == scope.bytes,
              let format = QuickHandoffFormat(rawValue: version),
              format.acceptsFile(configuration, dateResolution: dateResolution, hits: hits) else { return nil }
        var result = self
        result.roots = paths; result.hits = []
        var seen: Set<HitIdentity> = []
        for hit in hits {
            guard let bound = scope.carrying(hit) else { return nil }
            if seen.insert(bound.identity).inserted { result.hits.append(bound) }
        }
        return result
    }
}

func consumeQuickHandoff(_ candidate: URL) -> [Hit]? {
    consumeQuickHandoffPayload(candidate)?.hits
}

func consumeQuickHandoffPayload(_ candidate: URL) -> QuickHandoffPayload? {
    guard let url = validatedQuickHandoff(candidate) else { return nil }
    defer { try? FileManager.default.removeItem(at: url) }
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var total = 0
    var buffer = Data()
    var payload = QuickHandoffPayload()
    var firstLine = true
    func accept(_ line: Data) -> Bool {
        defer { firstLine = false }
        if firstLine, let object = preservedJSONObject(line) as? [String: Any],
           object["type"] as? String == "quickHandoff" {
            guard let format = QuickHandoffFormat.decode(object["schemaVersion"]),
                  !DateRangeTransport.hasDuplicateKeys(line),
                  format.acceptsHeader(object),
                  let rows = object["selection"] as? [[String: Any]], rows.count <= 20 else { return false }
            if format.hasRoots {
                guard let roots = object["roots"] as? [String], SearchRoots.problem(roots) == nil else { return false }
                payload.roots = roots
            }
            if format.hasFrozenOptions {
                guard let pairs = object["options"] as? [[String: String]], pairs.allSatisfy({ Set($0.keys) == ["name", "value"] }) else { return false }
                let items = pairs.map { URLQueryItem(name: $0["name"]!, value: $0["value"]!) }
                guard SearchConfiguration.transportProblem(items) == nil else { return false }
                let configuration = SearchConfiguration.fromQueryItems(items)
                guard format.optionProblem(configuration) == nil else { return false }
                payload.configuration = configuration
                if !(object["dateResolution"] is NSNull) {
                    guard let raw = object["dateResolution"], let proof = DateRangeTransport.resolution(raw) else { return false }
                    payload.dateResolution = proof
                }
            }
            for row in rows {
                guard Set(row.keys) == ["filesystemPath", "archiveMembers", "archiveMemberBytes"],
                      let path = row["filesystemPath"] as? String,
                      let members = row["archiveMembers"] as? [String],
                      let bytes = row["archiveMemberBytes"] as? [String],
                      bytes.isEmpty || bytes.count == members.count,
                      bytes.allSatisfy({ Data(base64Encoded: $0) != nil }),
                      payload.selection.insert(HitIdentity(filesystemPath: path,
                          archiveMembers: members, archiveMemberBytes: bytes)).inserted else { return false }
            }
            payload.version = format.rawValue
            return true
        }
        guard let hit = parseHit(line) else { return false }
        payload.hits.append(hit)
        return true
    }
    do {
        while let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty {
            total += chunk.count
            guard total <= maximumHandoffBytes else { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard line.count <= maximumHandoffLineBytes, accept(line) else { return nil }
            }
            guard buffer.count <= maximumHandoffLineBytes else { return nil }
        }
    } catch {
        return nil
    }
    if !buffer.isEmpty {
        guard accept(buffer) else { return nil }
    }
    guard payload.selection.isSubset(of: Set(payload.hits.map { $0.identity })),
          let format = QuickHandoffFormat(rawValue: payload.version) else { return nil }
    if let roots = payload.roots {
        guard Set(payload.hits.map { $0.identity }).count == payload.hits.count,
              payload.hits.allSatisfy({ $0.searchRootBytes != nil && SearchRoots(roots).carrying($0) != nil }) else { return nil }
    }
    if format.hasFrozenOptions {
        guard let roots = payload.roots, payload.bound(to: roots) != nil else { return nil }
    } else if !format.acceptsFile(payload.configuration, dateResolution: payload.dateResolution, hits: payload.hits) {
        return nil
    }
    return payload
}

/// Nur die echten Zusatztasten eines Tastendrucks.
///
/// Caps Lock, Zehnerblock und das Funktionsbit hängen je nach Tastatur mit
/// dran und dürfen ein Kürzel nicht entwerten. Steht EINMAL hier: Die
/// Haupt-App normalisierte, die Schnellsuche prüfte gar nicht — dort lösten
/// deshalb auch ⇧⎋ und ⌥⎋ Abbruch beziehungsweise Beenden aus.
