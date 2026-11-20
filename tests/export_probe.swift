import Foundation

#if !FAVENIO_TEST_SUITE
@main
#endif
struct ExportProbe {
    static func wait(_ predicate: () -> Bool) {
        let start = ProcessInfo.processInfo.systemUptime
        while !predicate() && ProcessInfo.processInfo.systemUptime - start < 10 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        precondition(predicate(), "Export-Completion fehlt")
    }

    static func main() throws {
        var metadata = Hit(path: "/fixture/a.txt", kind: "file", line: nil, size: nil,
                           filesystemPath: "/fixture/a.txt", archiveMembers: [], isDirectory: false,
                           field: "Description", value: "")
        let overhead = jsonlData(for: [metadata]).count - 1
        for count in [600_000, maximumHandoffLineBytes - overhead] {
            metadata.value = String(repeating: "/", count: count)
            let handoff = try writeQuickHandoff([metadata])
            precondition(consumeQuickHandoff(handoff) == [metadata])
            precondition(!FileManager.default.fileExists(atPath: handoff.path))
        }
        for value in [String(repeating: "/", count: maximumHandoffLineBytes - overhead + 1),
                      String(repeating: "\n", count: 600_000)] {
            metadata.value = value
            do {
                let unexpected = try writeQuickHandoff([metadata])
                try? FileManager.default.removeItem(at: unexpected)
                preconditionFailure("Übergabe akzeptiert eine zu lange JSONL-Zeile")
            } catch { precondition((error as? CocoaError)?.code == .fileWriteOutOfSpace) }
        }
        let many = (0..<30).map { index -> Hit in
            let path = "/fixture/Datei-\(index)"
            return Hit(path: path, kind: "file", line: nil, size: 1, filesystemPath: path,
                       archiveMembers: [], isDirectory: false)
        }
        let all = try writeQuickHandoff(many, continuingSearch: true)
        precondition(consumeQuickHandoff(all) == many)
        metadata.value = String(repeating: "x", count: 950_000)
        let large = many + Array(repeating: metadata, count: 10)
        let bounded = try writeQuickHandoff(large, continuingSearch: true)
        let prefix = consumeQuickHandoff(bounded)!
        precondition(prefix.count > many.count && prefix.count < large.count && prefix == Array(large.prefix(prefix.count)))
        let archiveHits = (1...3).map { index -> Hit in
            let archive = "/fixture/entries.tar"
            let member = String(repeating: "x", count: 200_000) + String(index)
            return Hit(path: archive + "!/" + member, kind: "member", line: nil, size: nil,
                       filesystemPath: archive, archiveMembers: [member],
                       archiveMemberBytes: [Data(member.utf8).base64EncodedString()], isDirectory: false)
        }
        let selection = Set(archiveHits.map { $0.identity })
        let selected = try writeQuickHandoff(archiveHits, selection: selection, version: 2, continuingSearch: true)
        let selectedPayload = consumeQuickHandoffPayload(selected)!
        precondition(selectedPayload.hits == archiveHits)
        precondition(selectedPayload.selection == Set(archiveHits.prefix(2).map { $0.identity }))
        let nearLimit = Array(repeating: metadata, count: 8)
        let limited = try writeQuickHandoff(nearLimit + archiveHits, selection: selection,
                                            version: 2, continuingSearch: true)
        let limitedPayload = consumeQuickHandoffPayload(limited)!
        precondition(limitedPayload.hits == nearLimit + [archiveHits[0]])
        precondition(limitedPayload.selection.isEmpty)
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
        let raw = Data([47, 116, 109, 112, 47, 98, 97, 100, 45, 255])
        let byteHit = Hit(path: String(decoding: raw, as: UTF8.self), kind: "file", line: nil, size: nil,
            filesystemPath: String(decoding: raw, as: UTF8.self), archiveMembers: [], isDirectory: false, filesystemPathBytes: raw)
        precondition(exportData(for: [byteHit], format: .pathsNUL) == raw + Data([0]), "NUL-Export verliert POSIX-Namensbytes")
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
            precondition(Thread.isMainThread && !writer.isWriting)
            if case .failure = result { fileFailed = true }
        }
        wait { fileFailed }
        let original = try Data(contentsOf: existing)
        precondition(original == Data("original".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protected.path)
        var retried = false
        precondition(writer.write(fixture, format: .csv, to: root.appendingPathComponent("retry.csv")) { result in
            precondition(Thread.isMainThread && !writer.isWriting)
            if case .failure(let error) = result { fatalError(error.localizedDescription) }
            retried = true
        })
        wait { retried }

        // Main gibt den Auftrag erst NACH Rückkehr von write frei. Damit
        // hängt der Nachweis weder von Rechnergeschwindigkeit noch CSV-Größe ab.
        let release = DispatchSemaphore(value: 0)
        let destination = root.appendingPathComponent("controlled.csv")
        let controlled = ExportWriter { hits, format, url in
            precondition(!Thread.isMainThread, "Exportarbeit blockiert Main")
            precondition(release.wait(timeout: .now() + 5) == .success)
            precondition(hits == fixture && format == .csv && url == destination)
        }
        var completed = false
        precondition(controlled.write(fixture, format: .csv, to: destination) { result in
            precondition(Thread.isMainThread && !controlled.isWriting)
            if case .failure(let error) = result { fatalError(error.localizedDescription) }
            completed = true
        })
        precondition(controlled.isWriting && !completed)
        release.signal()
        wait { completed }
        print("EXPORT OK: four formats, snapshot, single job, atomic failure, retry, worker scheduling")
    }
}
