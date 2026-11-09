import Foundation
import Glibc

private func failure(_ text: String) -> [String: Any] { ["ok": false, "error": text] }
private func encoded(_ value: Any) -> Data? {
    try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
}
private func identityText(_ hit: Hit) -> String {
    encoded([hit.filesystemPathData.base64EncodedString(), hit.archiveMembers, hit.archiveMemberBytes])!.base64EncodedString()
}
private func projected(_ hit: Hit, root: String? = nil, multiple: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["id": identityText(hit), "name": hit.displayName,
        "folder": root.map { hit.folderText(relativeTo: $0, showSearchRoot: multiple) } ?? hit.folderPath, "path": hit.path, "location": hit.locationText,
        "dimensions": hit.dimensionsText, "type": hit.typeDescription,
        "pathBytes": hit.filesystemPathData.base64EncodedString(), "openable": hit.hasOpenableFile, "isDirectory": hit.isDirectory,
        "identity": ControlIdentity.object(hit.identity), "raw": String(decoding: jsonlData(for: [hit]), as: UTF8.self)]
    if let size = hit.size { result["size"] = size }
    if let modified = hit.modified { result["modified"] = modified }
    if let created = hit.created { result["created"] = created }
    if let finder = hit.finderMetadata { result["finderTags"] = finder.tagsText; result["finderComment"] = finder.commentText }
    if let position = hit.documentPosition { result["documentPosition"] = position.json }
    if let preview = hit.contentPreview { result["preview"] = preview.json }
    return result
}

private final class Session: FastraHandoffOwner {
    let id = UUID().uuidString
    let runner = SearchRunner()
    let condition = NSCondition()
    var events: [[String: Any]] = []
    var hits: [Hit] = []
    var identities = Set<HitIdentity>()
    var closed = false, limited = false
    var report: SearchReportSnapshot?
    var filter: ResultFilterRun?
    var accepted: Set<HitIdentity>?
    var removed = Set<HitIdentity>()
    var duplicate: DuplicateJob?
    var previewLoad: ContentPreviewLoad?
    var resolution: Data?
    var sortedIndices: [Int] = []
    var sortedCount = 0
    var sortedKey = "", sortedAscending = true
    var deliveredHits = 0
    var latestProgress: String?
    lazy var handoff = FastraHandoffController(owner: self)
    var handoffRunID: String? { id }
    var handoffHits: [Hit] { condition.lock(); defer { condition.unlock() }; return hits }
    func handoffIssue(_ text: String) { enqueue(["kind": "handoffIssue", "text": text]) }
    var input: ControlSearchInput?
    var startedAt = Date().timeIntervalSince1970
    var recorded = false
    var ending = "running"
    var warnings = 0
    var error: String?
    let quick: Bool
    init(quick: Bool) { self.quick = quick }
    func enqueue(_ event: [String: Any]) {
        condition.lock(); defer { condition.unlock() }
        if !closed {
            if let kind = event["kind"] as? String, ["duplicateProgress", "handoffIssue"].contains(kind) { events.removeAll { $0["kind"] as? String == kind } }
            events.append(event)
        }
    }
    func stop() {
        condition.lock(); closed = true; events.removeAll(); condition.broadcast(); condition.unlock()
        filter?.cancel(); duplicate?.cancel(); runner.cancel()
        searchDeliveryQueue.sync { previewLoad?.cancel(); previewLoad = nil; handoff.cancelPending() }
    }
}
private var session: Session?
private let requestLock = NSLock()
private var actionEvents: [[String: Any]] = []
private let actionLock = NSLock()
private var materializations: [String: MaterializationRequest] = [:]

private func cancelFileActions() {
    materializations.values.forEach { $0.cancel(); $0.release() }
    materializations.removeAll()
    actionLock.lock(); actionEvents.removeAll(); actionLock.unlock()
}

private func ordered(_ current: Session, request: [String: Any]) -> ([Hit], [Int]) {
    current.condition.lock()
    let source = current.hits, accepted = current.accepted, removed = current.removed
    current.condition.unlock()
    let sort = request["sort"] as? String ?? "name", ascending = request["ascending"] as? Bool ?? true
    let comparator: (Int, Int) -> Bool = { compareHits(source[$0], source[$1], key: sort, ascending: ascending) }
    if current.sortedKey != sort || current.sortedAscending != ascending {
        current.sortedIndices = source.indices.sorted(by: comparator)
    } else if current.sortedCount < source.count {
        current.sortedIndices = mergingSortedValues(current.sortedIndices, Array(current.sortedCount..<source.count), using: comparator)
    }
    current.sortedKey = sort; current.sortedAscending = ascending; current.sortedCount = source.count
    let indices = current.sortedIndices.filter { !removed.contains(source[$0].identity) && (accepted?.contains(source[$0].identity) ?? true) }
    return (source, indices)
}

private func configuration(_ request: [String: Any]) -> SearchConfiguration? {
    guard let pairs = request["options"] as? [[String: String]] else { return nil }
    let items = pairs.compactMap { pair -> URLQueryItem? in
        guard Set(pair.keys) == ["name", "value"], let name = pair["name"], let value = pair["value"] else { return nil }
        return URLQueryItem(name: name, value: value)
    }
    guard items.count == pairs.count, SearchConfiguration.transportProblem(items) == nil else { return nil }
    return SearchConfiguration.fromQueryItems(items)
}

private func perform(_ request: [String: Any]) -> [String: Any] {
    guard let operation = request["operation"] as? String else { return failure("Auftrag braucht eine Operation.") }
    switch operation {
    case "catalog":
        return ["ok": true, "modes": SearchTextMode.allCases.map { ["id": $0.rawValue, "title": $0.title] },
                "fields": CriteriaCatalog.fields, "labels": CriteriaCatalog.labels,
                "operators": Dictionary(uniqueKeysWithValues: CriteriaCatalog.fields.map { ($0, CriteriaCatalog.operators(for: $0)) }),
                "operatorTitles": Dictionary(uniqueKeysWithValues: CriteriaCatalog.fields.map { field in (field, Dictionary(uniqueKeysWithValues: CriteriaCatalog.operators(for: field).map { ($0, CriteriaCatalog.operatorTitle($0, field: field)) })) }),
                "regexTemplates": regexTemplates.map { ["name": $0.name, "category": $0.category, "regex": $0.regex, "example": $0.example] },
                "metadataFields": metadataFieldList(), "encodings": SearchTextEncoding.allCases.map { ["id": $0.rawValue, "title": $0.title] }]
    case "criteria":
        guard let raw = request["root"], let node = CriteriaNode.parse(raw),
              CriteriaNode.fromJSON(node.json) != nil,
              let object = preservedJSONObject(Data(node.json.utf8)) else { return failure("Kriterienbaum ist ungültig oder überschreitet seine Grenzen.") }
        return ["ok": true, "criteria": object]
    case "identity":
        do {
            let identity = try ControlIdentity.parse(request["identity"])
            let key = encoded([(identity.filesystemPathBytes ?? Data(identity.filesystemPath.utf8)).base64EncodedString(), identity.archiveMembers, identity.archiveMemberBytes])!.base64EncodedString()
            return ["ok": true, "id": key, "identity": ControlIdentity.object(identity)]
        } catch { return failure("Ungültige Trefferidentität.") }
    case "parse":
        guard let text = request["line"] as? String, let hit = parseHit(Data(text.utf8)) else { return failure("Ungültiger Treffer.") }
        return ["ok": true, "hit": projected(hit)]
    case "arguments", "start":
        guard let pattern = request["pattern"] as? String, let roots = request["roots"] as? [String],
              let config = configuration(request), SearchRoots.problem(roots, rawBytes: request["rootBytes"].flatMap { SearchRoots.decodeRawPaths($0, paths: roots) }) == nil else {
            return failure("Ungültige Suchkonfiguration.")
        }
        var frozen: Data?
        if let proof = request["continuation"] {
            guard let data = DateRangeTransport.resolution(proof), DateRangeTransport.bound(data, to: config) else { return failure("Übergebene Kalendergrenzen passen nicht zur Frage.") }
            frozen = data
        }
        if request["dateReferenceTime"] != nil && !config.requiresDateRanges { return failure("Ein Laufzeitpunkt braucht Kalenderbereiche.") }
        if let reference = request["dateReferenceTime"], !DateRangeTransport.isISO(reference) { return failure("Ungültiger Laufzeitpunkt.") }
        let runConfig = frozen == nil ? config.forNewRun(reference: request["dateReferenceTime"] as? String) : config
        guard let arguments = runConfig.arguments(pattern: pattern, roots: roots, progress: true, frozenDateResolution: frozen) else {
            return failure("Ungültige Suchkonfiguration oder leere Frage.")
        }
        if operation == "arguments" { return ["ok": true, "arguments": arguments] }
        if config.requiresFinderMetadata { return failure("Finder-Tags und -Kommentare können unter Linux nicht abgefragt werden. Gespeicherte Belege bleiben erhalten.") }
        if config.localOnly { return failure("Für diese Linux-Installation ist die Sperre gegen Cloud-Nachladen nicht verfügbar.") }
        let rootData: [Data]
        if let raw = request["rootBytes"] {
            guard let data = SearchRoots.decodeRawPaths(raw, paths: roots) else { return failure("Ungültige POSIX-Suchwurzeln.") }
            rootData = data
        } else { rootData = roots.map { Data($0.utf8) } }
        for (path, data) in zip(roots, rootData) where ContentSourceGeneration.current(data) == nil {
            return failure("Suchbereich fehlt oder ist nicht zugänglich: " + path)
        }
        session?.stop(); cancelFileActions()
        let current = Session(quick: request["quick"] as? Bool == true)
        current.input = ControlSearchInput(pattern: pattern, roots: roots, options: runConfig)
        session = current
        var args = arguments
        if let raw = request["rootBytes"] as? [String] {
            guard raw.count == roots.count, zip(raw, roots).allSatisfy({ pair in
                guard let data = Data(base64Encoded: pair.0) else { return false }
                return data.first == 47 && !data.contains(0) && data.count <= 4096 && data.base64EncodedString() == pair.0 && String(decoding: data, as: UTF8.self).utf8.elementsEqual(pair.1.utf8)
            }), let json = encoded(raw), let end = args.firstIndex(of: "--") else { return failure("Ungültige POSIX-Suchwurzeln.") }
            current.input?.rootBytes = raw.compactMap { Data(base64Encoded: $0) }
            args.insert("--search-roots-bytes=" + String(decoding: json, as: UTF8.self), at: end)
        }
        if let end = args.firstIndex(of: "--") { args.insert(contentsOf: (request["contentPreview"] as? Bool == true ? ["--content-preview"] : []) + ["--search-report", "--json-path-bytes"], at: end) }
        current.runner.start(arguments: args, onBatch: { hits, progress in
            current.condition.lock()
            if !current.closed {
                for hit in hits where current.identities.insert(hit.identity).inserted {
                    if current.quick && current.hits.count >= 20 { current.limited = true; break }
                    current.hits.append(hit)
                }
            }
            let limited = current.limited
            if let progress { current.latestProgress = progress }
            current.condition.unlock()
            if limited { current.runner.cancel() }
        }, onReport: { report in
            current.condition.lock(); current.report = report; current.condition.unlock()
        }, onDateResolution: { data in
            current.condition.lock(); current.resolution = data; current.condition.unlock()
        }, completion: { exit in
            current.condition.lock()
            let limited = current.limited
            let count = current.hits.count
            let report = current.report
            current.condition.unlock()
            let state = limited ? "limitReached" : current.runner.isCancelled ? "cancelled" : searchExitIsError(exit.status, reason: exit.reason) ? "failed" : "finished"
            var event: [String: Any] = ["kind": "finish", "state": state, "count": count, "warnings": exit.warningCount]
            current.condition.lock()
            current.ending = state == "finished" ? (exit.warningCount == 0 ? "completed" : "warnings") : state == "limitReached" ? "cancelled" : state
            current.warnings = exit.warningCount
            current.error = state == "failed" ? searchFailureText(exit) : nil
            current.condition.unlock()
            if state == "failed" { event["error"] = searchFailureText(exit) }
            if let report { event["report"] = report.ending(state, warningCount: exit.warningCount).exportObject; event["reportText"] = report.displayText }
            current.enqueue(event)
        })
        return ["ok": true, "runID": current.id]
    case "poll":
        var events: [[String: Any]] = []
        if let current = session, request["runID"] as? String == current.id {
            current.condition.lock()
            let end = min(current.hits.count, current.deliveredHits + 512)
            if end > current.deliveredHits {
                let rows = (current.deliveredHits..<end).map { index -> [String: Any] in var value = projected(current.hits[index], root: current.input?.root, multiple: (current.input?.roots.count ?? 0) > 1); value["index"] = index; return value }
                var batch: [String: Any] = ["kind": "batch", "hits": rows]
                if let progress = current.latestProgress { batch["progress"] = progress }
                events.append(batch); current.deliveredHits = end
            }
            if end == current.hits.count { events += current.events; current.events.removeAll() }
            current.condition.unlock()
        }
        actionLock.lock(); events += actionEvents; actionEvents.removeAll(); actionLock.unlock()
        return ["ok": true, "events": events]
    case "cancel":
        session?.runner.cancel(); return ["ok": true]
    case "cancelPreview":
        if let current = session { searchDeliveryQueue.sync { current.previewLoad?.cancel(); current.previewLoad = nil } }
        return ["ok": true]
    case "loadPreview":
        guard let current = session, let raw = request["raw"] as? String, let hit = parseHit(Data(raw.utf8)),
              let index = request["queryIndex"] as? Int, let occurrence = request["occurrence"] as? Int,
              (0...1_000_000).contains(occurrence), let cli = findCLI() else { return failure("Ungültiger Nachladeauftrag.") }
        let id = UUID().uuidString
        searchDeliveryQueue.sync {
            current.previewLoad?.cancel()
            let load = ContentPreviewLoad(); current.previewLoad = load
            load.start(hit: hit, queryIndex: index, occurrence: occurrence, context: request["context"] as? Bool == true, localOnly: false, cli: cli) { [weak current, weak load] outcome in
                guard let current, let load, current.previewLoad === load else { return }
                current.previewLoad = nil
                var event: [String: Any] = ["kind": "preview", "loadID": id, "identity": identityText(hit)]
                switch outcome {
                case .ready(let preview): event["preview"] = preview.json
                case .sourceChanged: event["error"] = "Quelle verändert. Bitte neu suchen."
                case .failed(let message): event["error"] = message
                }
                current.enqueue(event)
            }
        }
        return ["ok": true, "loadID": id]
    case "previewStatus":
        guard let raw = request["raw"] as? String, let hit = parseHit(Data(raw.utf8)), let preview = hit.contentPreview else { return failure("Für diesen Suchlauf wurde keine Vorschau erfasst. Mit aktivierter Fundstellenvorschau neu suchen.") }
        if preview.status != "ready" { return ["ok": true, "preview": preview.json] }
        guard let source = preview.sourceGeneration, ContentSourceGeneration.current(hit.filesystemPathData) == source else { return failure("Quelle verändert oder nicht mehr verfügbar. Bitte neu suchen.") }
        return ["ok": true, "preview": preview.json]
    case "materialize":
        guard let raw = request["raw"] as? String, let hit = parseHit(Data(raw.utf8)) else { return failure("Ungültiger Treffer.") }
        let id = UUID().uuidString
        if !hit.isMember {
            actionLock.lock(); actionEvents.append(["kind": "materialized", "actionID": id, "pathBytes": hit.filesystemPathData.base64EncodedString()]); actionLock.unlock()
            return ["ok": true, "actionID": id]
        }
        if let token = MaterializationManager.shared.request(hit, ephemeral: request["ephemeral"] as? Bool == true, completion: { outcome in
            var event: [String: Any] = ["kind": "materialized", "actionID": id]
            switch outcome {
            case .ready(let url): event["path"] = url.path
            case .failed(let error): event["error"] = error
            case .cancelled: event["cancelled"] = true
            }
            actionLock.lock(); actionEvents.append(event); actionLock.unlock()
        }) { materializations[id] = token }
        return ["ok": true, "actionID": id]
    case "release":
        if let id = request["actionID"] as? String { if let token = materializations.removeValue(forKey: id) { token.cancel(); token.release() } }
        return ["ok": true]
    case "cleanup":
        session?.stop(); session = nil
        cancelFileActions()
        MaterializationManager.shared.cleanup(); return ["ok": true]
    case "page", "exportCurrent":
        guard let current = session, request["runID"] as? String == current.id else { return failure("Suchlauf ist nicht mehr aktuell.") }
        let (source, indices) = ordered(current, request: request)
        if operation == "exportCurrent" {
            guard let raw = request["format"] as? String, let format = HitExportFormat(rawValue: raw) else { return failure("Exportformat fehlt.") }
            let selected = request["indices"] as? [Int]
            guard selected?.allSatisfy({ source.indices.contains($0) }) ?? true else { return failure("Trefferauswahl überholt.") }
            return ["ok": true, "data": exportData(for: (selected ?? indices).map { source[$0] }, format: format).base64EncodedString()]
        }
        guard let offset = request["offset"] as? Int, let limit = request["limit"] as? Int,
              (0...indices.count).contains(offset), (1...128).contains(limit) else { return failure("Ungültige Ergebnisseite.") }
        var page: [Any] = [], bytes = 0
        for index in indices.dropFirst(offset).prefix(limit) {
            let data = jsonlData(for: [source[index]])
            if bytes + data.count > 500_000 { break }
            guard let row = preservedJSONObject(data) else { return failure("Ungültiger Treffer.") }
            bytes += data.count; page.append(row)
        }
        guard !page.isEmpty || offset == indices.count else { return failure("Ein Treffer überschreitet die Antwortgrenze.") }
        return ["ok": true, "hits": page, "count": indices.count, "nextOffset": offset + page.count, "hasMore": offset + page.count < indices.count]
    case "projection":
        guard let current = session, request["runID"] as? String == current.id,
              let mode = ResultGroupingMode(rawValue: request["mode"] as? String ?? "none") else { return failure("Suchlauf oder Gruppierung fehlt.") }
        let (source, indices) = ordered(current, request: request)
        let hits = indices.map { source[$0] }
        let initially = ResultProjection(hits: hits, mode: mode)
        let collapsedIDs = Set(request["collapsed"] as? [String] ?? [])
        func key(_ group: ResultGroup) -> String { encoded(group.key.components.map { $0.base64EncodedString() })!.base64EncodedString() }
        let collapsed = Set(initially.groups.filter { request["collapseAll"] as? Bool == true || collapsedIDs.contains(key($0)) }.map { $0.key })
        let projection = ResultProjection(hits: hits, mode: mode, collapsed: collapsed)
        var rows: [[String: Any]] = []
        for row in 0..<projection.rowCount {
            if let index = projection.hitIndex(at: row) { rows.append(["kind": "hit", "index": indices[index]]) }
            else if let group = projection.group(at: row) { rows.append(["kind": "group", "key": key(group), "title": group.title, "count": group.hitIndices.count]) }
        }
        return ["ok": true, "rows": rows, "total": source.count, "visible": hits.count, "expanded": projection.displayedHitCount]
    case "filter":
        guard let current = session, let query = request["criteria"] as? String else { return failure("Suchlauf oder Filter fehlt.") }
        let operation = ResultFilterRun()
        current.condition.lock(); let previous = current.filter; current.filter = operation; let hits = current.hits; current.condition.unlock()
        previous?.cancel()
        operation.start(hits, query: query, root: request["root"] as? String, completion: { [weak current, weak operation] identities, error in
            guard let current, let operation else { return }
            current.condition.lock()
            guard current.filter === operation else { current.condition.unlock(); return }
            if let identities { current.accepted = identities }
            current.condition.unlock()
            var event: [String: Any] = ["kind": "filtered"]
            if let error { event["error"] = error }
            current.enqueue(event)
        })
        return ["ok": true]
    case "resetFilter":
        if let current = session {
            current.condition.lock(); let previous = current.filter; current.filter = nil; current.accepted = nil; current.condition.unlock()
            previous?.cancel()
        }
        return ["ok": true]
    case "remove":
        guard let current = session, let indices = request["indices"] as? [Int] else { return failure("Trefferauswahl fehlt.") }
        current.condition.lock(); defer { current.condition.unlock() }
        guard indices.allSatisfy({ current.hits.indices.contains($0) }) else { return failure("Überholte Trefferauswahl.") }
        current.removed.formUnion(indices.map { current.hits[$0].identity })
        return ["ok": true]
    case "duplicates":
        guard let current = session, let indices = request["indices"] as? [Int] else { return failure("Trefferauswahl fehlt.") }
        current.condition.lock(); let source = current.hits; current.condition.unlock()
        guard indices.allSatisfy({ source.indices.contains($0) }) else { return failure("Überholte Trefferauswahl.") }
        let operation = DuplicateJob()
        current.condition.lock(); let previous = current.duplicate; current.duplicate = operation; current.condition.unlock()
        previous?.cancel()
        operation.run(hits: indices.map { source[$0] }, localOnly: false, progress: { progress in
            current.condition.lock(); let active = current.duplicate === operation; current.condition.unlock()
            guard active else { return }
            current.enqueue(["kind": "duplicateProgress", "done": progress.done, "total": progress.total, "readBytes": progress.readBytes])
        }, completion: { result in
            current.condition.lock(); let active = current.duplicate === operation; current.condition.unlock()
            guard active else { return }
            switch result {
            case .success(let result):
                if let data = try? JSONEncoder().encode(result), let object = preservedJSONObject(data) {
                    current.enqueue(["kind": "duplicateResult", "result": object, "indices": indices])
                }
            case .failure(let error): current.enqueue(["kind": "duplicateError", "error": error.localizedDescription])
            }
        })
        return ["ok": true]
    case "templates":
        let store = SearchTemplateStore()
        do {
            var templates = try store.load()
            if let oldName = request["rename"] as? String, let rawName = request["newName"] as? String {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let index = templates.firstIndex(where: { $0.name == oldName }),
                      name == oldName || !templates.contains(where: { $0.name == name }) else { return failure("Vorlage fehlt, Name ist leer oder bereits vergeben.") }
                templates[index].name = name; try store.save(templates)
            }
            if let name = request["delete"] as? String { templates.removeAll { $0.name == name }; try store.save(templates) }
            if let name = request["name"] as? String, let pattern = request["pattern"] as? String,
               let config = configuration(request), let roots = request["roots"] as? [String] {
                templates.removeAll { $0.name == name }
                var template = SearchTemplate(name: name, pattern: pattern, roots: roots, configuration: config)
                if let raw = request["rootBytes"] {
                    guard let bytes = SearchRoots.decodeRawPaths(raw, paths: roots) else { return failure("Ungültige POSIX-Suchwurzeln der Vorlage.") }
                    template.rootBytes = bytes
                }
                templates.append(template)
                try store.save(templates)
            }
            return ["ok": true, "templates": templates.map { template -> [String: Any] in
                var value: [String: Any] = ["name": template.name, "pattern": template.pattern, "roots": template.roots ?? [], "options": template.configuration.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }]
                if let raw = template.rootBytes { value["rootBytes"] = raw.map { $0.base64EncodedString() } }
                return value
            }]
        } catch { return failure(String(describing: error)) }
    case "fastra", "fastraStatus", "cancelFastra":
        guard let current = session else { return failure("Kein Suchlauf vorhanden.") }
        return searchDeliveryQueue.sync {
            do {
                if operation == "fastra" {
                    guard let index = request["index"] as? Int else { return failure("Genau einen Treffer auswählen.") }
                    current.condition.lock(); let hit = current.hits.indices.contains(index) ? current.hits[index] : nil; let input = current.input; current.condition.unlock()
                    guard let hit, let input else { return failure("Treffer ist nicht mehr aktuell.") }
                    let run = ControlledSearchRun(id: current.id, input: input)
                    return ["ok": true, "handoff": try current.handoff.start(hit: hit, run: run).object]
                }
                guard let id = request["jobID"] as? String, let job = current.handoff.jobs[id] else { return failure("Übergabeauftrag fehlt.") }
                if operation == "cancelFastra" { current.handoff.cancel(id) }
                return ["ok": true, "handoff": job.object]
            } catch let error as SearchControlFailure { return failure(error.message) }
              catch { return failure(error.localizedDescription) }
        }
    case "capabilities":
        var capabilities = SearchControlWire.capabilities
        capabilities["finderMetadataSnapshotSchemaVersion"] = 1; capabilities["portableRecordingSchemaVersion"] = 1
        capabilities["finderMetadataSchemaVersion"] = 0; capabilities["localContentSchemaVersion"] = 0
        return ["ok": true, "capabilities": capabilities]
    case "controlValidate":
        guard let raw = request["requestRaw"] as? String, raw.utf8.count <= SearchControlWire.maximumRequestBytes,
              !DateRangeTransport.hasDuplicateKeys(Data(raw.utf8)), let value = preservedJSONObject(Data(raw.utf8)) as? [String: Any] else { return failure("Steuerungsauftrag fehlt oder enthält doppelte Felder.") }
        do { return ["ok": true, "request": try SearchControlWire.validate(value)] }
        catch let error as SearchControlFailure { return failure(error.message) }
        catch { return failure("Ungültiger Steuerungsauftrag.") }
    case "configurationValidate":
        do {
            let value = try ControlSearchInput.decode(request["configuration"])
            return ["ok": true, "configuration": value.object]
        } catch let error as SearchControlFailure { return failure(error.message) }
          catch { return failure("Ungültige Suchkonfiguration.") }
    case "handoff":
        guard let current = session else { return failure("Kein Suchlauf für die Übergabe.") }
        current.condition.lock(); defer { current.condition.unlock() }
        guard let input = current.input else { return failure("Suchfrage fehlt.") }
        var value: [String: Any] = ["pattern": input.pattern, "roots": input.roots, "options": input.options.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }]
        if let raw = input.rootBytes { value["rootBytes"] = raw.map { $0.base64EncodedString() } }
        if input.options.requiresDateRanges {
            guard let proof = current.resolution, let object = preservedJSONObject(proof) else { return failure("Kalendergrenzen stehen noch nicht fest.") }
            value["continuation"] = object
        }
        return ["ok": true, "configuration": value]
    case "captureRecording":
        guard let current = session else { return failure("Kein Suchlauf vorhanden.") }
        current.condition.lock(); defer { current.condition.unlock() }
        guard current.ending != "running", !current.recorded, let input = current.input,
              current.hits.count <= SearchRecording.maximumHits else { return failure("Nur beendete Suchen mit höchstens 128 Treffern aufzeichnen.") }
        let selected = Set(request["indices"] as? [Int] ?? [])
        let record = SearchRecording(input: input, runID: current.id, startedAt: current.startedAt,
            capturedAt: Date().timeIntervalSince1970, state: current.ending, warningCount: current.warnings,
            error: current.error, hits: current.hits, selection: current.hits.enumerated().filter { selected.contains($0.offset) }.map { $0.element.identity }, dateResolution: current.resolution)
        guard let data = encoded(record.object), data.count <= SearchRecording.maximumBytes else { return failure("Aufzeichnung überschreitet 192 KiB.") }
        return ["ok": true, "data": data.base64EncodedString()]
    case "openRecording":
        guard let raw = request["data"] as? String, let data = Data(base64Encoded: raw) else { return failure("Aufzeichnung fehlt.") }
        do {
            let recording = try SearchRecording.decode(nil, rawData: data)
            session?.stop(); cancelFileActions()
            let current = Session(quick: false); current.hits = recording.hits; current.identities = Set(recording.hits.map { $0.identity })
            current.recorded = true; current.deliveredHits = recording.hits.count
            current.input = recording.input; current.ending = recording.state; current.warnings = recording.warningCount
            current.error = recording.error; current.resolution = recording.dateResolution
            session = current
            let rows = recording.hits.enumerated().map { pair -> [String: Any] in var value = projected(pair.element, root: recording.input.root, multiple: recording.input.roots.count > 1); value["index"] = pair.offset; return value }
            var configuration: [String: Any] = ["pattern": recording.input.pattern, "roots": recording.input.roots, "options": recording.input.options.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }]
            if let raw = recording.input.rootBytes { configuration["rootBytes"] = raw.map { $0.base64EncodedString() } }
            return ["ok": true, "runID": current.id, "hits": rows, "configuration": configuration, "selection": recording.selection.map { identity in recording.hits.firstIndex { $0.identity == identity } ?? -1 }, "state": recording.state, "warningCount": recording.warningCount, "error": recording.error ?? ""]
        } catch let error as SearchControlFailure { return failure(error.message) }
          catch { return failure("Ungültige Aufzeichnung.") }
    case "export":
        guard let rows = request["hits"] as? [String], let format = request["format"] as? String,
              let selected = HitExportFormat(rawValue: format) else { return failure("Ungültiger Export.") }
        let hits = rows.compactMap { parseHit(Data($0.utf8)) }
        guard hits.count == rows.count else { return failure("Export enthält einen ungültigen Treffer.") }
        return ["ok": true, "data": exportData(for: hits, format: selected).base64EncodedString()]
    default: return failure("Unbekannte Operation.")
    }
}

@_cdecl("favenio_model_free")
public func releaseModel(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }

@_cdecl("favenio_model")
public func modelRequest(_ pointer: UnsafePointer<UInt8>?, _ count: Int) -> UnsafeMutablePointer<CChar>? {
    guard let pointer, count >= 0, count <= 1_048_576 else { return nil }
    requestLock.lock(); defer { requestLock.unlock() }
    let data = Data(bytes: pointer, count: count)
    let response = (preservedJSONObject(data) as? [String: Any]).map(perform) ?? failure("Ungültiger Auftrag.")
    guard let encoded = encoded(response), let text = String(data: encoded, encoding: .utf8) else { return nil }
    return strdup(text)
}
