import Foundation
import CoreFoundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DateRangeSpec: Equatable {
    let kind: String
    let timeZone: String
    var preset: String? = nil
    var lower: String? = nil
    var upper: String? = nil
    static let presets = ["today", "last7CalendarDays", "thisMonth"]
    static let titles = ["today": "Heute", "last7CalendarDays": "Letzte sieben Kalendertage", "thisMonth": "Dieser Monat"]
    var object: [String: Any] {
        var value: [String: Any] = ["kind": kind, "timeZone": timeZone]
        if let preset { value["preset"] = preset }
        if let lower { value["lower"] = lower }
        if let upper { value["upper"] = upper }
        return value
    }
    var title: String { preset.flatMap { Self.titles[$0] } ?? "Fester Zeitraum" }
    static func parse(_ value: Any) -> Self? {
        guard let object = value as? [String: Any], let kind = object["kind"] as? String,
              let zone = object["timeZone"] as? String, !zone.isEmpty,
              zone.utf8.count <= 128, !zone.utf8.contains(0) else { return nil }
        if kind == "relative", Set(object.keys) == ["kind", "timeZone", "preset"],
           let preset = object["preset"] as? String, presets.contains(preset) {
            return Self(kind: kind, timeZone: zone, preset: preset)
        }
        if kind == "fixed", Set(object.keys) == ["kind", "timeZone", "lower", "upper"],
           let lower = object["lower"] as? String, let upper = object["upper"] as? String,
           [lower, upper].allSatisfy({ DateRangeTransport.isISO($0) }) {
            return Self(kind: kind, timeZone: zone, lower: lower, upper: upper)
        }
        return nil
    }
}

enum DateRangeTransport {
    static let maximumBytes = 65_536
    static func hasDuplicateKeys(_ data: Data) -> Bool {
        struct Frame { var object: Bool; var key = true; var names = Set<String>() }
        let bytes = Array(data); var frames: [Frame] = []; var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 34 {
                let start = index; index += 1; var escaped = false
                while index < bytes.count {
                    let current = bytes[index]
                    if current == 34 && !escaped { break }
                    if current == 92 { escaped.toggle() } else { escaped = false }
                    index += 1
                }
                guard index < bytes.count else { return true }
                if !frames.isEmpty, frames[frames.count - 1].object, frames[frames.count - 1].key {
                    let raw = Data(bytes[start...index])
                    guard let name = (try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])) as? String else { return true }
                    if !frames[frames.count - 1].names.insert(name).inserted { return true }
                }
            } else if byte == 123 || byte == 91 { frames.append(Frame(object: byte == 123)) }
            else if byte == 125 || byte == 93 { if !frames.isEmpty { frames.removeLast() } }
            else if !frames.isEmpty, frames[frames.count - 1].object {
                if byte == 58 { frames[frames.count - 1].key = false }
                if byte == 44 { frames[frames.count - 1].key = true }
            }
            index += 1
        }
        return false
    }
    static func text(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), data.count <= maximumBytes else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func ranges(_ text: String) -> [String: DateRangeSpec]? {
        guard text.utf8.count <= maximumBytes, !hasDuplicateKeys(Data(text.utf8)),
              let object = preservedJSONObject(Data(text.utf8)) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "ranges"], integer(object["schemaVersion"]) == 1,
              let raw = object["ranges"] as? [String: Any], !raw.isEmpty,
              Set(raw.keys).isSubset(of: ["modified", "created"]) else { return nil }
        var result: [String: DateRangeSpec] = [:]
        for (key, value) in raw { guard let spec = DateRangeSpec.parse(value) else { return nil }; result[key] = spec }
        return result
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue.rounded() == n.doubleValue, abs(n.doubleValue) < Double(Int.max) else { return nil }
        return n.intValue
    }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func isISO(_ value: Any?) -> Bool {
        guard let text = value as? String, text.utf8.count <= 64 else { return false }
        return text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:\.[0-9]{1,6})?)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\z"#, options: .regularExpression) != nil
    }
    // Nur Konsistenz expliziter ISO-/Epochbelege prüfen; IANA-Zonen und
    // relative Kalendergrenzen werden ausschließlich im Python-Kern aufgelöst.
    private static func instant(_ value: Any?) -> (stamp: Double, precision: Double)? {
        guard isISO(value), let text = value as? String else { return nil }
        let bytes = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start >= 0, count > 0, start + count <= bytes.count else { return nil }
            return Int(String(decoding: bytes[start..<(start + count)], as: UTF8.self))
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2), let hour = digits(11, 2), let minute = digits(14, 2) else { return nil }
        let zoneStart = bytes.last == 90 ? bytes.count - 1 : bytes.count - 6
        let clock = String(decoding: bytes[11..<zoneStart], as: UTF8.self)
        let hasSeconds = clock.filter { $0 == ":" }.count == 2
        guard let second = hasSeconds ? digits(17, 2) : 0 else { return nil }
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        var broken = tm(); broken.tm_year = Int32(year - 1900); broken.tm_mon = Int32(month - 1); broken.tm_mday = Int32(day)
        broken.tm_hour = Int32(hour); broken.tm_min = Int32(minute); broken.tm_sec = Int32(second)
        var whole = timegm(&broken), roundtrip = tm()
        guard gmtime_r(&whole, &roundtrip) != nil, roundtrip.tm_year == year - 1900, roundtrip.tm_mon == month - 1,
              roundtrip.tm_mday == day, roundtrip.tm_hour == hour, roundtrip.tm_min == minute, roundtrip.tm_sec == second else { return nil }
        var offset = 0
        if bytes.last != 90 {
            guard let hours = digits(zoneStart + 1, 2), let minutes = digits(zoneStart + 4, 2) else { return nil }
            offset = (hours * 60 + minutes) * 60
            if bytes[zoneStart] == 45 { offset = -offset }
        }
        var fraction = 0.0
        if let text = clock.split(separator: ".").dropFirst().first { guard let value = Double("0." + text) else { return nil }; fraction = value }
        return (Double(whole) - Double(offset) + fraction, clock.contains(".") ? 0 : (hasSeconds ? 1 : 60))
    }
    private static func sameInstant(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) <= max(actual.ulp, expected.ulp)
    }
    static func resolution(_ value: Any) -> Data? {
        guard let object = value as? [String: Any], Set(object.keys) == ["schemaVersion", "referenceTime", "referenceInput", "referenceISO", "entries"],
              integer(object["schemaVersion"]) == 1,
              (object["referenceTime"] is NSNull && object["referenceISO"] is NSNull && object["referenceInput"] is NSNull)
                || (number(object["referenceTime"]) != nil && isISO(object["referenceISO"]) && isISO(object["referenceInput"])),
              let entries = object["entries"] as? [[String: Any]], !entries.isEmpty, entries.count <= 130 else { return nil }
        if let reference = number(object["referenceTime"]) {
            guard let original = instant(object["referenceInput"]), let canonical = instant(object["referenceISO"]),
                  sameInstant(reference, original.stamp), sameInstant(reference, canonical.stamp) else { return nil }
        }
        var ids = Set<String>()
        for entry in entries {
            guard Set(entry.keys) == ["id", "question", "lowerISO", "upperISO", "lowerEpoch", "upperEpoch", "upperExclusiveISO"],
                  let id = entry["id"] as? String, !id.isEmpty, id.utf8.count <= 80, ids.insert(id).inserted,
                  let question = entry["question"] as? [String: Any],
                  DateRangeSpec.parse(question) != nil || calendarQuestion(question),
                  let lower = number(entry["lowerEpoch"]), let upper = number(entry["upperEpoch"]), lower <= upper,
                  let lowerISO = entry["lowerISO"] as? String, let upperISO = entry["upperISO"] as? String,
                  isISO(lowerISO), isISO(upperISO),
                  entry["upperExclusiveISO"] is NSNull || isISO(entry["upperExclusiveISO"]) else { return nil }
            guard let low = instant(lowerISO), let high = instant(upperISO), sameInstant(lower, low.stamp) else { return nil }
            if high.precision == 0 {
                guard entry["upperExclusiveISO"] is NSNull, sameInstant(upper, high.stamp) else { return nil }
            } else {
                guard let end = instant(entry["upperExclusiveISO"]), end.stamp == high.stamp + high.precision,
                      upper == end.stamp.nextDown else { return nil }
            }
            if question["kind"] as? String == "relative" && number(object["referenceTime"]) == nil { return nil }
            if let spec = DateRangeSpec.parse(question), spec.kind == "fixed" {
                guard Data(spec.lower!.utf8) == Data(lowerISO.utf8), Data(spec.upper!.utf8) == Data(upperISO.utf8) else { return nil }
            }
        }
        guard let text = text(object) else { return nil }; return Data(text.utf8)
    }
    private static func calendarQuestion(_ object: [String: Any]) -> Bool {
        let required = Set(["kind", "timeZone", "fromLocal", "toLocal"])
        guard object["kind"] as? String == "calendar",
              required.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: required.union(["fold", "fromFold", "toFold"])),
              object["fold"] == nil || (object["fromFold"] == nil && object["toFold"] == nil),
              let zone = object["timeZone"] as? String, !zone.isEmpty, zone.utf8.count <= 128, !zone.utf8.contains(0),
              ["fromLocal", "toLocal"].allSatisfy({ key in
                  guard let text = object[key] as? String else { return false }
                  return text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\z"#, options: .regularExpression) != nil
              }), ["fold", "fromFold", "toFold"].allSatisfy({ object[$0] == nil || [0, 1].contains(integer(object[$0]) ?? -1) }) else { return false }
        return true
    }
    static func questions(_ configuration: SearchConfiguration) -> [String: DateRangeSpec] {
        var result = configuration.dateRanges
        func add(_ node: CriteriaNode) {
            if let spec = node.dateRange { result["criteria:" + node.id] = spec }
            node.children.forEach(add)
        }
        if let text = configuration.criteriaJSON, let node = CriteriaNode.fromJSON(text) { add(node) }
        return result
    }
    static func bound(_ data: Data, to configuration: SearchConfiguration) -> Bool {
        guard let object = preservedJSONObject(data) as? [String: Any], resolution(object) != nil,
              let reference = configuration.dateReferenceTime, let original = object["referenceInput"] as? String,
              Data(reference.utf8) == Data(original.utf8),
              let entries = object["entries"] as? [[String: Any]] else { return false }
        let expected = questions(configuration)
        guard entries.count == expected.count else { return false }
        return entries.allSatisfy { entry in
            guard let id = entry["id"] as? String, let raw = entry["question"],
                  let spec = DateRangeSpec.parse(raw) else { return false }
            return expected[id] == spec
        }
    }
    static func referenceNow() -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    static func referenceArguments(_ text: String?) -> [String] { text.map { ["--date-reference-time=" + $0] } ?? [] }
    static func frozenArguments(_ data: Data?) -> [String] { data.map { ["--date-resolution-json=" + String(decoding: $0, as: UTF8.self)] } ?? [] }
    static func problem(_ items: [URLQueryItem]) -> String? {
        for name in ["date-ranges", "date-reference-time"] where items.filter({ $0.name == name }).count > 1 {
            return "Datumsoptionen dürfen nur einmal vorkommen."
        }
        if let text = items.first(where: { $0.name == "date-ranges" })?.value {
            guard let ranges = ranges(text) else { return "Ungültige oder zu große Kalenderbereiche." }
            for key in ranges.keys {
                if items.contains(where: { $0.name == key + "-from" || $0.name == key + "-to" }) {
                    return "Kalenderbereich und rohe ISO-Grenzen desselben Felds schließen sich aus."
                }
            }
        }
        if let text = items.first(where: { $0.name == "date-reference-time" })?.value,
           !isISO(text) { return "Ungültiger Laufzeitpunkt mit Z oder Offset." }
        return nil
    }
    static func criteriaHasRanges(_ text: String?) -> Bool {
        guard let text, let node = CriteriaNode.fromJSON(text) else { return false }
        return node.hasDateRanges
    }
}
