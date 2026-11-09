import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct SearchReportSnapshot {
    var object: [String: Any]
    static let byteLimit = 262_144

    static func parse(_ data: Data) -> Self? {
        func boolean(_ value: Any?) -> Bool {
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }
        guard data.count <= byteLimit, !DateRangeTransport.hasDuplicateKeys(data),
              let object = preservedJSONObject(data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber, !boolean(version), version.doubleValue == 1,
              let id = object["runID"] as? String, UUID(uuidString: id) != nil,
              let state = object["state"] as? String, ["running", "finished", "cancelled", "failed"].contains(state),
              object["counting"] as? String == "events",
              object["configuration"] is [String: Any],
              let reasons = object["reasons"] as? [[String: Any]], reasons.count <= 64,
              object["dateResolution"] == nil || DateRangeTransport.resolution(object["dateResolution"]!) != nil else { return nil }
        var ids = Set<String>()
        for reason in reasons {
            guard let id = reason["id"] as? String, !id.isEmpty, id.utf8.count <= 80, ids.insert(id).inserted,
                  let category = reason["category"] as? String, ["intentional", "readError", "budget"].contains(category),
                  let label = reason["label"] as? String, label.utf8.count <= 512,
                  let count = reason["count"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
                  count.doubleValue >= 0, count.doubleValue <= 9_007_199_254_740_991,
                  count.doubleValue.rounded() == count.doubleValue,
                  boolean(reason["countCapped"]),
                  let examples = reason["examples"] as? [[String: Any]], examples.count <= 3,
                  examples.allSatisfy({ example in
                      guard let path = example["path"] as? String else { return false }
                      return path.unicodeScalars.count <= 256 && boolean(example["truncated"])
                  }) else { return nil }
        }
        return Self(object: object)
    }

    var state: String { object["state"] as? String ?? "unavailable" }
    var reasons: [[String: Any]] { object["reasons"] as? [[String: Any]] ?? [] }
    var coverage: String {
        state == "finished" && reasons.isEmpty && object["coverage"] as? String == "withinRequestedScope"
            ? "withinRequestedScope" : "incomplete"
    }
    var summary: String {
        switch state {
        case "running": return "Suche läuft – vorläufiger Bericht"
        case "finished": return coverage == "incomplete" ? "Suche beendet – Abdeckung eingeschränkt" : "Suchlauf im angefragten Umfang beendet"
        case "cancelled": return "Suche abgebrochen – Abdeckung unvollständig"
        case "limitReached": return "20-Treffer-Grenze erreicht – Abdeckung unvollständig"
        case "failed": return "Suche fehlgeschlagen – Abdeckung unvollständig"
        case "recorded": return "Übernommene Treffer – kein Bericht des ursprünglichen Suchlaufs"
        default: return "Bericht noch nicht verfügbar – Abdeckung unbekannt"
        }
    }
    func ending(_ state: String, warningCount: Int? = nil, error: String? = nil) -> Self {
        var result = self
        result.object["state"] = state
        result.object["observedAt"] = Date().timeIntervalSince1970
        if let warningCount { result.object["warningCount"] = warningCount }
        if let error { result.object["error"] = error }
        if state != "finished" || (warningCount ?? 0) > 0 { result.object["coverage"] = "incomplete" }
        return result
    }
    var exportObject: [String: Any] {
        var result = object
        result["coverage"] = coverage
        result["exportedAt"] = Date().timeIntervalSince1970
        return result
    }
    static func pending(configuration: [String: Any], state: String = "unavailable") -> Self {
        Self(object: ["type": "searchReport", "schemaVersion": 1, "runID": UUID().uuidString,
                      "startedAt": Date().timeIntervalSince1970, "state": state,
                      "coverage": "incomplete", "counting": "events", "source": "frontend",
                      "configuration": configuration, "reasons": [[String: Any]]()])
    }
    private var configurationText: String {
        guard let config = object["configuration"] as? [String: Any] else { return "Unbekannt." }
        func quoted(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .prettyPrinted, .withoutEscapingSlashes]) else { return "–" }
            return String(decoding: data, as: UTF8.self)
        }
        if config["truncated"] as? Bool == true {
            return "Konfiguration überschreitet die Berichtsgrenze und ist gekürzt. Der Export enthält nur den ausdrücklich gekennzeichneten Anfang; vollständige Kriterien sind daraus nicht rekonstruierbar."
        }
        // Nur Darstellung der vom Kern gelieferten Optionen, keine Auswertung.
        guard config["paths"] != nil else { return "Kernbericht steht aus. Auftrag:\n" + quoted(config) }
        let mode = config["metadata"] as? Bool == true || !(config["metadata_field"] as? [String] ?? []).isEmpty
            ? "Metadaten" : (config["document_text"] as? Bool == true ? "Dokumenttext" : (config["content"] as? Bool == true ? "Inhalt" : "Name"))
        var lines = ["Suchziel: " + mode, "Suchordner/-dateien: " + quoted(config["paths"] ?? []),
                     "Muster: " + quoted(config["pattern"] ?? NSNull()), "Weitere Begriffe (UND): " + quoted(config["term"] ?? []),
                     "Kodierung: " + quoted(config["encoding"] ?? "utf-8"), "Ausschlüsse: " + quoted(config["exclude"] ?? [])]
        for (key, label) in [("regex", "Regulärer Ausdruck"), ("case_sensitive", "Groß-/Kleinschreibung"),
                             ("exact", "Ganzes Ziel"), ("literal_wildcards", "Platzhalter wörtlich"), ("hidden", "Versteckte Bereiche einbeziehen"), ("local_only", "Nur lokal vorhandene Inhalte lesen"), ("ocr", "Bild-OCR im Dokumenttext (Deutsch/Englisch)"), ("pdf_ocr", "PDF-OCR für textlose Seiten (Deutsch/Englisch)")] {
            lines.append(label + ": " + (config[key] as? Bool == true ? "Ja" : "Nein"))
        }
        for (key, label) in [("only", "Datei-/Ordnertyp"), ("max_depth", "Ordner-Tiefengrenze"), ("effectiveArchiveDepth", "Archiv-Tiefengrenze"),
                             ("max_archive_member_bytes", "Entpackte Einzelgrenze (Bytes)"), ("max_archive_total_bytes", "Entpacktes Gesamtbudget (Bytes)"),
                             ("max_archive_ratio", "Maximales Kompressionsverhältnis"), ("min_size", "Mindestgröße"), ("max_size", "Höchstgröße"),
                             ("min_width", "Mindestbreite"), ("max_width", "Höchstbreite"), ("min_height", "Mindesthöhe"), ("max_height", "Höchsthöhe"),
                             ("modified_from", "Geändert ab"), ("modified_to", "Geändert bis"), ("created_from", "Erstellt ab"), ("created_to", "Erstellt bis"),
                             ("metadata_field", "Metadatenfelder")] {
            if let value = config[key], !(value is NSNull) { lines.append(label + ": " + quoted(value)) }
        }
        if let criteria = config["criteria"], !(criteria is NSNull) { lines.append("Zusätzlicher Kriterienbaum:\n" + quoted(criteria)) }
        if let limits = config["fixedLimits"] { lines.append("Feste Leser-/Kataloggrenzen:\n" + quoted(limits)) }
        return lines.joined(separator: "\n")
    }
    var displayText: String {
        func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        var lines = ["Laufkennung: \(object["runID"] as? String ?? "–")"]
        if let started = object["startedAt"] as? Double { lines.append("Beginn: " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started))) }
        if let at = object["capturedAt"] as? Double { lines.append("Kernstand: " + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: at))) }
        if let error = object["error"] as? String { lines.append("Fehler: " + error) }
        if let dates = object["dateResolution"] { lines.append("\nTatsächlich verwendete Kalendergrenzen (inklusive)\n" + json(dates)) }
        lines.append("\nGezählt werden Ereignisse, keine eindeutigen Objekte. Ausgelassene Teilbäume haben eine unbekannte Größe. Gekürzte Beispiele sind Anzeigetexte, keine vollständigen Pfade oder Archividentitäten.")
        for (category, title) in [("intentional", "Absichtlich ausgelassen"), ("readError", "Technische Einschränkungen"), ("budget", "Ausgeschöpfte Budgets")] {
            let items = reasons.filter { $0["category"] as? String == category }
            lines.append("\n" + title)
            if items.isEmpty { lines.append("Keine Ereignisse gemeldet.") }
            for item in items {
                let count = (item["count"] as? NSNumber)?.stringValue ?? "0"
                lines.append("\(item["label"] as? String ?? "") [\(item["id"] as? String ?? "")]: \(item["countCapped"] as? Bool == true ? "mindestens " : "")\(count) \(count == "1" ? "Ereignis" : "Ereignisse")")
                for example in item["examples"] as? [[String: Any]] ?? [] {
                    // JSON-Quoting hält Zeilenumbrüche und Steuerzeichen sichtbar.
                    lines.append("  " + json(example["path"] ?? "") + (example["truncated"] as? Bool == true ? " … [gekürzt]" : ""))
                }
                lines.append("  Höchstens drei Beispiele; weitere Ereignisse werden nur gezählt.")
            }
        }
        lines.append("\nKriterien und Grenzen des Laufs\n" + configurationText)
        lines.append("\nBerichtsgrenzen\n" + json(object["reportLimits"] ?? [:]))
        lines.append("\nDer Lauf prüft die angefragten Kriterien und darf nach einem ausreichenden Treffer früh aufhören. Dieser Bericht ist kein Nachweis vollständig gelesener oder unbeschädigter Inhalte. Ein laufender, abgebrochener oder eingeschränkter Lauf belegt keine vollständige Abdeckung.")
        return lines.joined(separator: "\n")
    }
}
