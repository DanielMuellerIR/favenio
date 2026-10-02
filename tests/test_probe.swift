import Foundation
import UniformTypeIdentifiers

/// Ein Build, aber weiterhin ein frischer Prozess für jeden Testmodus.
@main struct TestProbeMain {
    static func main() throws {
        let command = CommandLine.arguments
        guard command.count >= 2 else { exit(2) }
        // Die Einzelproben behalten ihre bisherigen Argumentpositionen.
        let arguments = [command[0]] + Array(command.dropFirst(2))
        switch command[1] {
        case "runner": RunnerProbe.run(arguments)
        case "materialization": MaterializationProbe.run(arguments)
        case "configuration": try ConfigurationProbe.run(arguments)
        case "export": try ExportProbe.main()
        case "scope-refresh": QuickScopeRefreshHarness.run()
        case "scope-note": QuickScopeNoteHarness.run()
        case "pixel-limit", "csv-field", "type-description":
            try values(command[1])
        case "common-apps": try commonApps()
        default: exit(2)
        }
    }

    /// Die ALTE Fassung von `commonApplicationsFor`: schneidet je TREFFER.
    ///
    /// Sie bleibt hier als unabhängiger Vergleich stehen. Die neue Fassung
    /// überspringt Endungen, gegen die `common` schon geschnitten wurde —
    /// das ist nur dann erlaubt, wenn beide Fassungen für dieselbe Eingabe
    /// dieselbe Anwendungsliste liefern.
    static func commonApplicationsPerHit(_ hits: [Hit]) -> [URL] {
        guard let first = hits.first else { return [] }
        var common = applicationsFor(first)
        var byExtension: [String: Set<URL>] = [:]
        func extensionKey(_ hit: Hit) -> String? {
            let ext = (hit.displayName as NSString).pathExtension.lowercased()
            return ext.isEmpty ? nil : ext
        }
        if let key = extensionKey(first) {
            byExtension[key] = Set(common.map { $0.standardizedFileURL })
        }
        for hit in hits.dropFirst() {
            if common.isEmpty { break }
            let allowed: Set<URL>
            if let key = extensionKey(hit), let cached = byExtension[key] {
                allowed = cached
            } else {
                allowed = Set(applicationsFor(hit).map { $0.standardizedFileURL })
                if let key = extensionKey(hit) { byExtension[key] = allowed }
            }
            common = common.filter { allowed.contains($0.standardizedFileURL) }
        }
        return common
    }

    /// Liest eine Liste von Dateinamen (je Zeile ein Treffer) und
    /// vergleicht beide Fassungen: gleiche Anwendungsliste, und wie lange
    /// jede gebraucht hat.
    static func commonApps() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let names = try JSONDecoder().decode([String].self, from: input)
        // ECHTE Dateien: `urlsForApplications(toOpen: URL)` liefert für
        // einen erfundenen Pfad gar nichts, und die Schnittmenge wäre nach
        // dem ersten Treffer leer — der Vergleich prüfte dann nichts.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("favenio-common-apps-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var hits: [Hit] = []
        var written = Set<String>()
        for name in names {
            let url = root.appendingPathComponent(name)
            let isDirectory = name.hasSuffix("/")
            if written.insert(name).inserted {
                if isDirectory {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    FileManager.default.createFile(atPath: url.path, contents: Data())
                }
            }
            hits.append(Hit(path: url.path, kind: "file", line: nil, size: nil,
                            filesystemPath: url.path, archiveMembers: [],
                            isDirectory: isDirectory))
        }
        var start = Date()
        let neu = commonApplicationsFor(hits).map { $0.path }
        let neuDauer = Date().timeIntervalSince(start)
        start = Date()
        let alt = commonApplicationsPerHit(hits).map { $0.path }
        let altDauer = Date().timeIntervalSince(start)
        var direct = hits.first.map(applicationsFor) ?? []
        for hit in hits.dropFirst() {
            let allowed = Set(applicationsFor(hit).map { $0.standardizedFileURL })
            direct = direct.filter { allowed.contains($0.standardizedFileURL) }
        }
        let report: [String: [String]] = [
            "neu": neu, "alt": alt, "direct": direct.map { $0.path },
            "dauer": [String(format: "%.4f", neuDauer),
                      String(format: "%.4f", altDauer)],
        ]
        FileHandle.standardOutput.write(try JSONEncoder().encode(report))
    }

    static func values(_ mode: String) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let values = try JSONDecoder().decode([String].self, from: input)
        let output: Data
        switch mode {
        case "pixel-limit":
            output = try JSONEncoder().encode(values.map { parsePixelLimit($0).map(String.init) ?? "nil" })
        case "csv-field":
            output = try JSONEncoder().encode(values.map(csvField))
        default:
            let cache = TypeDescriptionCache()
            // Die direkte Datenbankabfrage bleibt der unabhängige Vergleich.
            let answers = (values + values).map { value -> [String] in
                let ext = value.lowercased()
                let direct = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
                return [cache.description(for: ext), direct]
            }
            output = try JSONEncoder().encode(answers)
        }
        FileHandle.standardOutput.write(output)
    }
}
