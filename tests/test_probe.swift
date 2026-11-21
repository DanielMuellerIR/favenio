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
        case "search-report": try SearchReportProbe.run(arguments)
        case "runner": RunnerProbe.run(arguments)
        case "materialization": MaterializationProbe.run(arguments)
        case "configuration": try ConfigurationProbe.run(arguments)
        case "duplicates": try DuplicateProbe.run(arguments)
        case "thumbnails": try ThumbnailProbe.run(Array(CommandLine.arguments.dropFirst()))
        case "archive-menu": ThumbnailProbe.checkArchiveMenu()
        case "export": try ExportProbe.main()
        case "content-preview": try ContentPreviewProbe.run(arguments)
        case "result-filter": try ResultFilterProbe.run()
        case "result-grouping": try ResultGroupingProbe.run(arguments)
        case "search-roots": try SearchRootsProbe.run(arguments)
        case "finder-metadata": try FinderMetadataProbe.run(arguments)
        case "date-ranges": try DateRangesProbe.run(arguments)
        case "criteria-editor": try CriteriaEditorSelfTest.run()
        case "pixel-limit", "csv-field", "type-description":
            try values(command[1])
        case "hit-transport": try hitTransport()
        case "hit-sorting": try hitSorting()
        case "find-cli": print(findCLI() ?? "")
        case "common-apps":
            try commonApps(compareDirect: command.contains("--direct"),
                           fixture: command.contains("--fixture-applications"))
        case "metadata-fields":
            FileHandle.standardOutput.write(try JSONEncoder().encode(metadataFieldList()))
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
    static func commonApps(compareDirect: Bool, fixture: Bool) throws {
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
        func lookupKey(_ hit: Hit) -> String {
            let ext = (hit.displayName as NSString).pathExtension.lowercased()
            if hit.isDirectory || ext.isEmpty { return hit.filesystemPath }
            return "extension:" + ext
        }
        var snapshot: [String: [URL]] = [:]
        if !fixture {
            for hit in hits where snapshot[lookupKey(hit)] == nil {
                snapshot[lookupKey(hit)] = applicationsFor(hit)
            }
        }
        var lookups: [String] = []
        applicationsLookupForTesting = {
            let key = lookupKey($0)
            lookups.append(key)
            if fixture { return [URL(fileURLWithPath: "/fixture/Editor.app")] }
            return snapshot[key] ?? []
        }
        defer { applicationsLookupForTesting = nil }
        var start = Date()
        let neu = commonApplicationsFor(hits).map { $0.path }
        let actualLookups = lookups
        let neuDauer = Date().timeIntervalSince(start)
        start = Date()
        let alt = commonApplicationsPerHit(hits).map { $0.path }
        let altDauer = Date().timeIntervalSince(start)
        // Der ungecachte dritte Vergleich wird nur für die Typprüfung
        // ausgewertet. 200 unnötige LaunchServices-Abfragen überschritten
        // dessen Prozessfrist, obwohl beide verglichenen Fassungen fertig waren.
        var direct: [URL] = []
        if compareDirect {
            direct = hits.first.map(applicationsFor) ?? []
            for hit in hits.dropFirst() {
                let allowed = Set(applicationsFor(hit).map { $0.standardizedFileURL })
                direct = direct.filter { allowed.contains($0.standardizedFileURL) }
            }
        }
        let report: [String: [String]] = [
            "neu": neu, "alt": alt, "direct": direct.map { $0.path },
            "lookups": actualLookups,
            "dauer": [String(format: "%.4f", neuDauer),
                      String(format: "%.4f", altDauer)],
        ]
        FileHandle.standardOutput.write(try JSONEncoder().encode(report))
    }

    static func hitTransport() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let lines = try JSONDecoder().decode([String].self, from: input)
        let hits = lines.map { parseHit(Data($0.utf8)) }
        let parsed = hits.map { $0?.isDirectory }
        let serialized = try jsonlData(for: hits.compactMap { $0 }).split(separator: 0x0a).map {
            try JSONSerialization.jsonObject(with: Data($0))
        }
        let report: [String: Any] = [
            "parsed": parsed.map { $0 as Any? ?? NSNull() },
            "serialized": serialized,
        ]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report))
    }

    static func hitSorting() throws {
        func hit(_ name: String, width: Int? = nil, height: Int? = nil) -> Hit {
            Hit(path: "/fixture/\(name)", kind: "file", line: nil, size: nil,
                filesystemPath: "/fixture/\(name)", archiveMembers: [], isDirectory: false,
                width: width, height: height)
        }
        let missing = hit("no dimensions")
        let narrow = hit("narrow", width: 2, height: 9)
        let square = hit("square", width: 6, height: 6)
        let firstTie = hit("a tie", width: 10, height: 10)
        let secondTie = hit("b tie", width: 5, height: 20)
        let oversized = hit("oversized", width: Int.max, height: 2)
        let hits = [secondTie, oversized, missing, square, firstTie, narrow]
        var report: [String: [String]] = [:]
        for ascending in [true, false] {
            let compare: (Hit, Hit) -> Bool = { compareHits($0, $1, key: "dims", ascending: ascending) }
            let direction = ascending ? "ascending" : "descending"
            report[direction] = hits.sorted(by: compare).map(\.displayName)
            report[direction + "Reflexive"] = hits.filter { compare($0, $0) }.map(\.displayName)
        }
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
