import Foundation

struct FinderMetadataProbe {
    static func run(_ arguments: [String]) throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let frames = try JSONDecoder().decode([String].self, from: input)
        var replies: [[String: Any]] = []
        var firstSnapshot: FinderMetadataSnapshot?
        for frame in frames {
            let data = Data(frame.utf8)
            let mode = arguments.dropFirst().first ?? "shape"
            if mode == "csv" {
                guard let hit = parseHit(data) else { throw CocoaError(.fileReadCorruptFile) }
                replies.append(["csvBase64": exportData(for: [hit], format: .csv).base64EncodedString()])
                continue
            }
            if mode.hasPrefix("quick") {
                guard let original = parseHit(data), let hit = SearchRoots(["/missing"]).carrying(original) else { throw CocoaError(.fileReadCorruptFile) }
                var configuration = SearchConfiguration(); configuration.finderMetadata = true
                var dates: Data?
                if mode == "quick-dates" {
                    configuration.dateRanges["modified"] = DateRangeSpec(kind: "relative", timeZone: "UTC", preset: "today")
                    configuration.dateReferenceTime = "2023-11-14T12:00:00Z"
                    let object = preservedJSONObject(data) as! [String: Any]
                    dates = DateRangeTransport.resolution(object["testDateResolution"]!)
                }
                let file = try writeQuickHandoff([hit], selection: [hit.identity], version: 5, roots: ["/missing"], configuration: configuration, dateResolution: dates)
                defer { try? FileManager.default.removeItem(at: file) }
                if mode.hasPrefix("quick-cap-") {
                    let raw = try String(contentsOf: file, encoding: .utf8)
                    let changed = raw.replacingOccurrences(of: "\"finderMetadataCapability\":1", with: "\"finderMetadataCapability\":" + mode.dropFirst("quick-cap-".count))
                    precondition(raw != changed)
                    try Data(changed.utf8).write(to: file)
                }
                let payload = consumeQuickHandoffPayload(file)
                var reply: [String: Any] = ["valid": payload != nil, "temporaryConsumed": !FileManager.default.fileExists(atPath: file.path)]
                if let payload {
                    reply["version"] = payload.version
                    reply["snapshotBytesPreserved"] = payload.hits.first?.finderMetadata?.json == original.finderMetadata?.json
                    reply["configurationPreserved"] = payload.configuration == configuration
                    reply["datesPreserved"] = payload.dateResolution == dates
                    reply["selectionPreserved"] = payload.selection == [hit.identity]
                }
                do {
                    _ = try writeQuickHandoff([hit], version: 3, roots: ["/missing"])
                    reply["legacyRejected"] = false
                } catch { reply["legacyRejected"] = true }
                replies.append(reply)
                continue
            }
            if mode == "hit" {
                var reply: [String: Any] = ["valid": false]
                if let hit = parseHit(data) {
                    let encoded = jsonlData(for: [hit])
                    reply = ["valid": true, "jsonl": String(decoding: encoded, as: UTF8.self),
                             "snapshotBytesPreserved": JSONByteSlices.member("finderMetadata", in: data) == JSONByteSlices.member("finderMetadata", in: encoded)]
                }
                replies.append(reply)
                continue
            }
            let snapshot = FinderMetadataSnapshot.parse(data,
                size: mode == "bound" ? 3 : nil,
                modified: mode == "bound" ? Double(1700000000123456789) / 1e9 : nil,
                inArchive: mode == "archive")
            var reply: [String: Any] = ["valid": snapshot != nil]
            if let snapshot {
                if mode == "semantic" {
                    let encoded = try JSONSerialization.data(withJSONObject: snapshot.object, options: [.sortedKeys])
                    let restored = FinderMetadataSnapshot.parse(encoded)!
                    reply["jsonChanged"] = encoded != data
                    reply["equalAfterCodec"] = restored == snapshot
                    reply["hashAfterCodec"] = Set([restored, snapshot]).count == 1
                    if firstSnapshot == nil { firstSnapshot = snapshot }
                    reply["sameAsFirst"] = snapshot == firstSnapshot!
                }
                reply["bytesPreserved"] = snapshot.json == data
                reply["tagNames"] = snapshot.tags?.map { $0.name } as Any? ?? NSNull()
                reply["tagRaw"] = snapshot.tags?.map { $0.raw } as Any? ?? NSNull()
                reply["comment"] = snapshot.comment as Any? ?? NSNull()
                reply["knownEmptyTags"] = snapshot.tags?.isEmpty == true
                reply["knownEmptyComment"] = snapshot.commentBytes?.isEmpty == true
            }
            replies.append(reply)
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: replies, options: [.sortedKeys]), as: UTF8.self))
    }
}
