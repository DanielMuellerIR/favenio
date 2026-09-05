import Foundation

@main struct ExportProbe {
    static func wait(_ predicate: () -> Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        while !predicate() && ProcessInfo.processInfo.systemUptime - start < 10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        precondition(predicate(), "Export-Completion fehlt")
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = [
            Hit(path: "=1+1", kind: "file", line: 7, size: 1000,
                filesystemPath: "/fixture/Ü\n\".txt", archiveMembers: [], isDirectory: false,
                modified: 1725500000, created: 1725400000),
            Hit(path: "/fixture/archive.zip!/a.txt", kind: "member", line: nil, size: nil,
                filesystemPath: "/fixture/archive.zip", archiveMembers: ["a.txt"], isDirectory: false)
        ]
        let writer = ExportWriter()
        for format in HitExportFormat.allCases {
            let expected = exportData(for: fixture, format: format)
            let destination = root.appendingPathComponent(format.rawValue)
            try Data("old".utf8).write(to: destination)
            var complete = false
            var snapshot = fixture
            precondition(writer.write(snapshot, format: format, to: destination) { result in
                precondition(Thread.isMainThread && !writer.isWriting)
                if case .failure(let error) = result { fatalError(error.localizedDescription) }
                complete = true
            })
            snapshot.removeAll() // Kein Zugriff des Workers auf späteres UI-Modell.
            precondition(!writer.write([], format: format, to: destination) { _ in
                fatalError("Zweiter Export durfte nicht starten")
            })
            wait { complete }
            let actual = try Data(contentsOf: destination)
            if format == .jsonl {
                let parse: (Data) -> [Hit] = { data in data.split(separator: 10).compactMap { parseHit(Data($0)) } }
                precondition(parse(actual) == parse(expected) && parse(actual) == fixture)
            } else { precondition(actual == expected) }
            if format == .csv {
                precondition(actual.starts(with: [0xEF, 0xBB, 0xBF]))
                precondition(String(decoding: actual, as: UTF8.self).contains("'=1+1"))
            }
        }
        let blocked = root.appendingPathComponent("existing-directory")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let sentinel = blocked.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var failed = false
        writer.write(fixture, format: .csv, to: blocked) { result in
            precondition(Thread.isMainThread && !writer.isWriting)
            if case .failure = result { failed = true }
        }
        wait { failed }
        let remaining = try Data(contentsOf: sentinel)
        precondition(remaining == Data("keep".utf8))
        let protected = root.appendingPathComponent("unwritable-parent")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let existing = protected.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: existing)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protected.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path) }
        var fileFailed = false
        writer.write(fixture, format: .paths, to: existing) { result in
            if case .failure = result { fileFailed = true }
        }
        wait { fileFailed }
        let original = try Data(contentsOf: existing)
        precondition(original == Data("original".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
        var retried = false
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in ticks += 1 }
        // Genug Zeitstempel für echte Arbeit: Main muss WÄHREND des Exports
        // reagieren, nicht erst nachdem der Worker fertig geworden ist.
        let many = Array(repeating: fixture[0], count: 3000)
        let submitStart = ProcessInfo.processInfo.systemUptime
        precondition(writer.write(many, format: .csv, to: root.appendingPathComponent("retry.csv")) { result in
            if case .failure(let error) = result { fatalError(error.localizedDescription) }
            precondition(ticks > 0)
            retried = true
        })
        precondition(ProcessInfo.processInfo.systemUptime - submitStart < 0.2,
                     "Exportstart blockiert Main bereits beim Serialisieren")
        wait { retried }
        timer.invalidate()
        print("EXPORT OK: four formats, snapshot, single job, atomic failure, retry, main heartbeat")
    }
}
