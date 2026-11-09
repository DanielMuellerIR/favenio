import Foundation
import Glibc

let pythonPath = ProcessInfo.processInfo.environment["FAVENIO_PYTHON"] ?? "/usr/bin/python3"
func findCLI() -> String? {
    guard let value = ProcessInfo.processInfo.environment["FAVENIO_ENGINE"],
          value.hasPrefix("/"), FileManager.default.fileExists(atPath: value) else { return nil }
    return value
}
extension Hit {
    var typeDescription: String {
        if isDirectory { return "Ordner" }
        let suffix = (displayName as NSString).pathExtension
        return suffix.isEmpty ? "Datei" : suffix.uppercased()
    }
}

// Unter Linux gibt es keine Objective-C-Autorelease-Pools.
func autoreleasepool<Result>(_ body: () throws -> Result) rethrows -> Result { try body() }
