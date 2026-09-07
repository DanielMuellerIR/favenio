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
        default: exit(2)
        }
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
