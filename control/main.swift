import AppKit
import Darwin

func runControlHelper() throws -> Data {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let noLaunch = arguments.first == "--no-launch"
    if noLaunch { arguments.removeFirst() }
    if arguments == ["--capabilities", "--json"] { return SearchControlWire.encode(SearchControlWire.capabilities) }
    guard arguments.count == 2, arguments[0] == "--request" else {
        throw SearchControlFailure(code: "invalidRequest", message: "Aufruf: favenio-control [--no-launch] --request <Datei|->")
    }
    let input: FileHandle
    if arguments[1] == "-" { input = .standardInput }
    else {
        let descriptor = open(arguments[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SearchControlFailure(code: "invalidRequest", message: "Auftragsdatei nicht lesbar.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw SearchControlFailure(code: "invalidRequest", message: "Auftrag muss eine reguläre Datei sein.")
        }
        input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    defer { if arguments[1] != "-" { try? input.close() } }
    var data = Data()
    let readStopAt = ProcessInfo.processInfo.systemUptime + 10
    while data.count <= SearchControlWire.maximumRequestBytes {
        let count = min(4096, SearchControlWire.maximumRequestBytes + 1 - data.count)
        let remaining = readStopAt - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            throw SearchControlFailure(code: "expired", message: "Auftragseingabe wurde nicht innerhalb von zehn Sekunden abgeschlossen.")
        }
        var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 1000)))
        if ready < 0 && errno == EINTR { continue }
        guard ready >= 0 else { throw SearchControlFailure(code: "invalidRequest", message: "Auftragseingabe nicht lesbar.") }
        if ready == 0 { continue }
        var buffer = [UInt8](repeating: 0, count: count)
        let received = Darwin.read(input.fileDescriptor, &buffer, count)
        if received < 0 && [EINTR, EAGAIN].contains(errno) { continue }
        guard received >= 0 else { throw SearchControlFailure(code: "invalidRequest", message: "Auftragseingabe nicht lesbar.") }
        if received == 0 { break }
        data.append(contentsOf: buffer.prefix(received))
    }
    _ = try SearchControlWire.decode(data)
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { throw SearchControlFailure(code: "delivery", message: "Bundle nicht gefunden.") }
    let app = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let identifier = Bundle(url: app)?.bundleIdentifier else { throw SearchControlFailure(code: "delivery", message: "Bundle nicht gefunden.") }
    let name = SearchControlWire.endpoint(identifier)
    let stopAt = ProcessInfo.processInfo.systemUptime + 10
    var launched = false
    var launchFailed = false
    while ProcessInfo.processInfo.systemUptime < stopAt {
        if SearchControlClient.available(name) {
            guard let reply = SearchControlClient.send(data, name: name, timeout: stopAt - ProcessInfo.processInfo.systemUptime),
                  let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                throw SearchControlFailure(code: "delivery", message: "Keine Antwort; denselben Auftrag unverändert wiederholen.")
            }
            // Die Antwort ist geprüft; erneutes Dekodieren/Kodieren würde
            // führendes U+FEFF in erfassten Finder-Strings entfernen.
            _ = object
            return reply
        }
        if noLaunch || launchFailed { break }
        if !launched {
            launched = true
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: options) { _, error in
                DispatchQueue.main.async { launchFailed = error != nil }
            }
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    throw SearchControlFailure(code: "delivery", message: "Favenio-Steuerung nicht erreichbar.")
}

do {
    let result = try runControlHelper()
    FileHandle.standardOutput.write(result + Data([10]))
    let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
    exit(object?["error"] == nil ? 0 : 1)
} catch {
    let failure = error as? SearchControlFailure ?? SearchControlFailure(code: "invalidRequest", message: "Auftrag konnte nicht gelesen werden.")
    FileHandle.standardOutput.write(SearchControlWire.encode(["protocolVersion": 1, "error": failure.object]) + Data([10]))
    exit(1)
}
