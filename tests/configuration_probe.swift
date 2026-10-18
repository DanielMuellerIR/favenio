import AppKit

#if !FAVENIO_TEST_SUITE
@main
#endif
struct ConfigurationProbe {
    static func main() throws {
        try run(CommandLine.arguments)
    }

    static func run(_ arguments: [String]) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let nfc = "Büro"
        let nfd = "Bu\u{0308}ro"
        precondition(nfc == nfd && !nfc.utf8.elementsEqual(nfd.utf8))
        let firstPath = HitIdentity(filesystemPath: "/" + nfc, archiveMembers: [])
        let secondPath = HitIdentity(filesystemPath: "/" + nfd, archiveMembers: [])
        let firstMember = HitIdentity(filesystemPath: "/archive.zip", archiveMembers: [nfc])
        let secondMember = HitIdentity(filesystemPath: "/archive.zip", archiveMembers: [nfd])
        precondition(Set([firstPath, secondPath, firstMember, secondMember]).count == 4,
                     "Kanonisch gleiche Anzeigenamen dürfen keine Originalidentitäten zusammenführen")
        let ascii = HitIdentity(filesystemPath: "/ascii", archiveMembers: ["item"])
        let bridged = HitIdentity(filesystemPath: NSString(string: "/ascii") as String, archiveMembers: ["item"])
        precondition(ascii == bridged && Set([ascii, bridged]).count == 1)
        let bridgedNFD = HitIdentity(filesystemPath: NSString(string: "/" + nfd) as String, archiveMembers: [])
        precondition(secondPath == bridgedNFD && Set([secondPath, bridgedNFD]).count == 1)
        var original = SearchConfiguration()
        original.mode = .metadata
        original.regex = true
        original.caseSensitive = true
        original.archives = true
        original.includeHidden = true
        original.exact = true
        original.literalWildcards = true
        original.only = "files"
        original.metadataField = "Title"
        original.pixelTexts = ["1.000 px", "2000", "", ""]
        original.rawFacts = ["min-size": "1 B", "max-size": "1 KiB",
                             "modified-from": "2000-01-01T00:00:00Z",
                             "modified-to": "2099-01-01T00:00:00+02:00",
                             "created-from": "2000-01-01T00:00:00Z",
                             "created-to": "2099-01-01T00:00:00Z"]
        original.exclusions = ["node_modules", "Cache/*.zip", " whitespace ", "100%+#Ü.txt", "-cache", "--hidden"]
        original.terms = ["beta", " mit Leerraum ", "-dash", "100%+#Ü", nfd]
        var url = URLComponents()
        url.scheme = "favenio"
        url.host = "results"
        url.queryItems = original.queryItems
        let decoded = SearchConfiguration.fromQueryItems(
            URLComponents(url: url.url!, resolvingAgainstBaseURL: false)!.queryItems!)
        precondition(original == decoded, "Options-URL verliert Werte")
        precondition(decoded.terms.last!.utf8.elementsEqual(nfd.utf8), "Options-URL verändert Original-Codepoints")
        let args = decoded.arguments(pattern: "Winter", root: "/fixture")!
        precondition(args.filter { $0.hasPrefix("--exclude=") }
            .map { String($0.dropFirst("--exclude=".count)) } == original.exclusions)
        precondition(args.contains("--literal-wildcards"))
        precondition(args.contains("1000") && args.contains("--metadata"))
        precondition(args.contains("--metadata-field") && args.contains("Title"))
        // Das Feld gehoert NUR in den Metadaten-Modus. Der Kern liest
        // `metadata_mode = args.metadata or bool(args.metadata_field)`: Ein
        // Feld ohne `--metadata` liesse ihn im Namens-Modus stillschweigend
        // Metadaten durchsuchen, mit `--content` endete er mit Exit 2.
        for other in [SearchTextMode.name, .content] {
            var strayField = decoded
            strayField.mode = other
            let strayArgs = strayField.arguments(pattern: "Winter", root: "/fixture")!
            precondition(!strayArgs.contains("--metadata-field"),
                         "Metadatenfeld erreicht den Kern im Modus \(other)")
            precondition(!strayArgs.contains("--metadata"))
        }
        precondition(args.filter { $0.hasPrefix("--term=") }
            .map { String($0.dropFirst("--term=".count)) } == original.terms)
        // Mehrwortsuche gegen den echten Kern: beide Begriffe in EINER Datei
        // auf verschiedenen Zeilen, Belege je Begriff im Treffer.
        let termFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: termFixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: termFixture) }
        try "alpha\nx\nbeta\n".write(to: termFixture.appendingPathComponent("beide.txt"), atomically: true, encoding: .utf8)
        try "alpha\n".write(to: termFixture.appendingPathComponent("eins.txt"), atomically: true, encoding: .utf8)
        var termSearch = SearchConfiguration()
        termSearch.mode = .content
        termSearch.terms = ["beta"]
        var termHits: [Hit] = []
        let termExit = runSearchStreaming(arguments: termSearch.arguments(pattern: "alpha", root: termFixture.path)!,
                                          onHit: { termHits.append($0) }, onProgress: { _ in })
        precondition(termExit.status == 0 && termHits.count == 1, "Mehrwortsuche liefert nicht genau beide.txt")
        precondition(termHits[0].terms.map { $0.line } == [1, 3] && termHits[0].locationText == "1, 3")
        // Ohne Muster im Suchfeld tragen die Begriffe die Suche allein.
        termSearch.terms = ["alpha", "beta"]
        termHits = []
        let termsOnly = runSearchStreaming(arguments: termSearch.arguments(pattern: "", root: termFixture.path)!,
                                           onHit: { termHits.append($0) }, onProgress: { _ in })
        precondition(termsOnly.status == 0 && termHits.count == 1)
        let view0 = SearchFilterView()
        view0.terms = ["a", "", "b"]
        precondition(view0.terms == ["a", "b"] && view0.activeFilterCount == 2)
        let legacy = SearchConfiguration.fromQueryItems([URLQueryItem(name: "content", value: "1")])
        precondition(legacy.mode == .content && !legacy.archives && !legacy.regex && !legacy.caseSensitive)
        for texts in [["10.5", "", "", ""], ["2000", "1000", "", ""],
                      ["-1", "", "", ""], [String(Int.max) + "0", "", "", ""]] {
            var invalid = original
            invalid.pixelTexts = texts
            let restored = SearchConfiguration.fromQueryItems(invalid.queryItems)
            precondition(restored.pixelTexts == texts)
            precondition(restored.arguments(pattern: "x", root: "/fixture") == nil)
            let fields = texts.map { NSTextField(string: $0) }
            precondition(validatePixelFields(fields).error != nil)
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("-cache"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try "x".write(to: fixture.appendingPathComponent("-cache/needle.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: fixture.appendingPathComponent("needle.txt"), atomically: true, encoding: .utf8)
        var dashPattern = SearchConfiguration()
        dashPattern.exclusions = ["-cache", "--hidden"]
        var found: [Hit] = []
        let outcome = runSearchStreaming(arguments: dashPattern.arguments(pattern: "needle", root: fixture.path)!,
                                         onHit: { found.append($0) }, onProgress: { _ in })
        precondition(outcome.status == 0 && found.count == 1 && found[0].filesystemPath == fixture.appendingPathComponent("needle.txt").path)
        var factsOnly = SearchConfiguration()
        factsOnly.mode = .metadata
        factsOnly.rawFacts = original.rawFacts
        factsOnly.exclusions = ["-cache"]
        precondition(factsOnly.hasPositiveFilter)
        precondition(FactFilterOption.all.allSatisfy { factsOnly.filterSummary.contains($0.title) })
        let factsArguments = factsOnly.arguments(pattern: "", root: fixture.path)!
        precondition(!factsArguments.contains("--metadata") && !factsArguments.contains("--content"))
        found = []
        let factsExit = runSearchStreaming(arguments: factsArguments,
                                           onHit: { found.append($0) }, onProgress: { _ in })
        precondition(factsExit.status == 0 && found.count == 1)
        var excludedOnly = SearchConfiguration()
        excludedOnly.exclusions = ["x"]
        precondition(!excludedOnly.hasPositiveFilter && excludedOnly.arguments(pattern: "", root: fixture.path) == nil)
        for invalid in [["min-size": "-1"], ["min-size": "10", "max-size": "1"],
                        ["modified-from": "2026-09-05"], ["created-to": "2026-09-05T12:00:00"]] {
            factsOnly.rawFacts = invalid
            let restored = SearchConfiguration.fromQueryItems(factsOnly.queryItems)
            precondition(restored.rawFacts == invalid && restored.hasPositiveFilter)
            let result = runSearchStreaming(arguments: restored.arguments(pattern: "", root: fixture.path)!, onProgress: { _ in })
            precondition(result.status == 2 && !(result.errorMessage ?? "").isEmpty)
        }
        // Vorlagenformat: Roundtrip über die Datei mit allen Optionen und
        // Rohtexten; eine neuere Formatversion wird mit Nummer abgelehnt.
        let templateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("favenio-probe-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: templateFile) }
        var invalidPixels = original
        invalidPixels.pixelTexts = ["10.5", "", "", ""]
        let templates = [
            SearchTemplate(name: "Alles", pattern: "Winter", root: "/fixture", configuration: original),
            SearchTemplate(name: "Roh", pattern: "", root: nil, configuration: invalidPixels)]
        let store = SearchTemplateStore(fileURL: templateFile)
        try store.save(templates)
        let loaded = try store.load()
        precondition(loaded == templates, "Vorlagendatei verliert Werte")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: templateFile)) as! [String: Any]
        precondition(json["version"] as? Int == 1)
        let criteria = """
        {"schemaVersion":1,"root":{"id":"all","op":"and","children":[
          {"id":"name","field":"name","operator":"contains","value":"needle"},
          {"id":"formats","op":"or","children":[
            {"id":"txt","field":"extension","operator":"equals","value":"txt"},
            {"id":"log","field":"extension","operator":"equals","value":"log"}]}]}}
        """
        var criteriaConfiguration = SearchConfiguration(archives: true)
        criteriaConfiguration.criteriaJSON = criteria
        let criteriaTemplate = SearchTemplate(name: "Baum", pattern: "", root: fixture.path,
                                              configuration: criteriaConfiguration)
        try store.save([criteriaTemplate])
        let criteriaData = try Data(contentsOf: templateFile)
        var criteriaObject = try JSONSerialization.jsonObject(with: criteriaData) as! [String: Any]
        precondition(criteriaObject["version"] as? Int == 2)
        let criteriaLoaded = try store.load()
        precondition(criteriaLoaded == [criteriaTemplate])
        let criteriaURL = SearchTemplateFormat.encodeOptions(criteriaLoaded[0].configuration)
        let criteriaRestored = try SearchTemplateFormat.decodeOptions(criteriaURL)
        precondition(criteriaRestored == criteriaConfiguration)
        var criteriaHits: [Hit] = []
        let criteriaExit = runSearchStreaming(arguments: criteriaRestored.arguments(pattern: "", root: fixture.path)!,
                                              onHit: { criteriaHits.append($0) }, onProgress: { _ in })
        precondition(criteriaExit.status == 0 && criteriaHits.count == 2)
        precondition(criteriaHits.allSatisfy { $0.criteriaEvidence.map { $0.id } == ["name", "txt"] })
        // Alte Leser müssen die neue Frage ablehnen, statt deren Kriterien zu verlieren.
        criteriaObject["version"] = 1
        let migrated = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: criteriaObject))
        precondition(migrated == [criteriaTemplate], "Kriterien aus 0.40.0 gehen beim Laden verloren")
        let migratedObject = try JSONSerialization.jsonObject(with: SearchTemplateFormat.encode(migrated)) as! [String: Any]
        precondition(migratedObject["version"] as? Int == 2)
        for invalidVersion: Any in [6, true, 1.5] {
            criteriaObject["version"] = invalidVersion
            do {
                _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: criteriaObject))
                preconditionFailure("Unpassende Vorlagenversion akzeptiert")
            } catch is SearchTemplateError {}
        }
        criteriaObject["version"] = 2
        let validEntry = (criteriaObject["templates"] as! [[String: Any]])[0]
        for field in ["pattern", "root", "options"] {
            var entry = validEntry
            entry[field] = 1
            criteriaObject["templates"] = [entry]
            do {
                _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: criteriaObject))
                preconditionFailure("Ungültiges Vorlagenfeld wird still durch einen Default ersetzt")
            } catch is SearchTemplateError {}
        }
        for raw in ["{future: true}", criteria.replacingOccurrences(of: "needle", with: "Bu\u{0308}ro #100% + a!/b"),
                    criteria + String(repeating: " ", count: CriteriaTransport.maximumBytes - criteria.utf8.count)] {
            criteriaConfiguration.criteriaJSON = raw
            let rawTemplate = SearchTemplate(name: "Rohbaum", pattern: "", root: nil, configuration: criteriaConfiguration)
            let restored = try SearchTemplateFormat.decode(SearchTemplateFormat.encode([rawTemplate]))
            precondition(restored == [rawTemplate], "Rohtext eines nicht darstellbaren Baums wird verändert")
        }
        let finderSchema = #"{"schemaVersion":3,"root":{"id":"tag","field":"finderTags","operator":"contains","value":"Projekt"}}"#
        precondition(SearchConfiguration.transportProblem([URLQueryItem(name: "criteria", value: finderSchema)]) == nil)
        var finderConfiguration = SearchConfiguration(); finderConfiguration.criteriaJSON = finderSchema
        let finderTemplate = SearchTemplate(name: "Finder", pattern: "", roots: ["/missing"], configuration: finderConfiguration)
        let finderData = try SearchTemplateFormat.encode([finderTemplate])
        var finderObject = try JSONSerialization.jsonObject(with: finderData) as! [String: Any]
        let restoredFinder = try SearchTemplateFormat.decode(finderData)
        precondition(finderObject["version"] as? Int == 5 && restoredFinder == [finderTemplate])
        let rawFinder = String(decoding: finderData, as: UTF8.self)
        let duplicateFinder = rawFinder.replacingOccurrences(of: "\"version\" : 5", with: "\"version\" : 4, \"version\" : 5")
        precondition(duplicateFinder != rawFinder)
        do { _ = try SearchTemplateFormat.decode(Data(duplicateFinder.utf8)); preconditionFailure("Doppelte Finder-Vorlagenfelder akzeptiert") }
        catch is SearchTemplateError {}
        finderObject["version"] = 4
        do { _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: finderObject)); preconditionFailure("Finder-Frage unter Altformat akzeptiert") }
        catch is SearchTemplateError {}
        finderConfiguration.criteriaJSON = nil; finderConfiguration.finderMetadata = true
        precondition(finderConfiguration.arguments(pattern: "synthetic", root: "/missing")!.contains("--finder-metadata"))
        criteriaConfiguration.criteriaJSON = String(repeating: " ", count: CriteriaTransport.maximumBytes + 1)
        let beforeOversized = try Data(contentsOf: templateFile)
        do {
            try store.save([SearchTemplate(name: "Zu groß", pattern: "", root: nil, configuration: criteriaConfiguration)])
            preconditionFailure("Zu große Kriterien wurden gesichert")
        } catch is SearchTemplateError {}
        let afterOversized = try Data(contentsOf: templateFile)
        precondition(afterOversized == beforeOversized)
        for options in ["criteria=x&criteria=y", "criteria", "criteria=%00"] {
            do { _ = try SearchTemplateFormat.decodeOptions(options); preconditionFailure("Ungültiger Kriterientransport") }
            catch is SearchTemplateError {}
        }
        let chosen = Set(criteriaHits.map { $0.identity }.prefix(1))
        let handoff = try writeQuickHandoff(criteriaHits, selection: chosen, version: 2)
        let payload = consumeQuickHandoffPayload(handoff)!
        precondition(payload.version == 2 && payload.hits == criteriaHits && payload.selection == chosen)
        precondition(!FileManager.default.fileExists(atPath: handoff.path))
        let malformed = try writeQuickHandoff(criteriaHits, version: 2)
        let malformedData = try String(contentsOf: malformed, encoding: .utf8)
        try malformedData.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":3")
            .write(to: malformed, atomically: true, encoding: .utf8)
        precondition(consumeQuickHandoffPayload(malformed) == nil)
        try Data("{\"version\": 99, \"templates\": []}".utf8).write(to: templateFile)
        do { _ = try store.load(); preconditionFailure("Version 99 wurde gelesen") }
        catch let error as SearchTemplateError { precondition(error.description.contains("99")) }
        let missing = try SearchTemplateStore(fileURL: templateFile.appendingPathExtension("fehlt")).load()
        precondition(missing.isEmpty)
        for encoding in SearchTextEncoding.allCases {
            var configuration = SearchConfiguration()
            configuration.mode = .content
            configuration.textEncoding = encoding
            let items = configuration.queryItems
            precondition(SearchConfiguration.transportProblem(items) == nil)
            precondition(SearchConfiguration.fromQueryItems(items) == configuration)
            precondition(configuration.arguments(pattern: "Büro", root: "/tmp")!.contains("--encoding=" + encoding.rawValue) == (encoding != .utf8))
            precondition(configuration.requiresTransportVersion2 == (encoding != .utf8))
            precondition(!SearchConfiguration(textEncoding: encoding).hasPositiveFilter)
            let template = SearchTemplate(name: "Kodierung", pattern: "Büro", root: nil, configuration: configuration)
            let data = try SearchTemplateFormat.encode([template])
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            precondition(object["version"] as? Int == (encoding == .utf8 ? 1 : 2))
            let decodedTemplates = try SearchTemplateFormat.decode(data)
            precondition(decodedTemplates == [template])
            let filters = SearchFilterView()
            filters.textEncoding = encoding
            precondition(filters.textEncoding == encoding && filters.activeFilterCount == (encoding == .utf8 ? 0 : 1))
            var notified = 0
            filters.onChange = { notified += 1 }
            _ = filters.encodingPopup.sendAction(filters.encodingPopup.action, to: filters.encodingPopup.target)
            precondition(notified == 1)
        }
        for query in ["encoding=utf-7", "encoding=", "encoding=utf-8&encoding=auto", "encoding=mac-roman&surprise=1"] {
            let items = URLComponents(string: "?" + query)!.queryItems!
            precondition(SearchConfiguration.transportProblem(items) != nil)
            do { _ = try SearchTemplateFormat.decodeOptions(query); preconditionFailure("Ungültiger Decoder wurde übernommen") }
            catch is SearchTemplateError {}
        }
        var encodedHit = criteriaHits[0]
        encodedHit.contentEncoding = "utf-16-be"
        encodedHit.criteriaEvidence = [CriterionEvidence(id: "content", field: "content", value: "Büro", line: 2, contentEncoding: "utf-16-be")]
        precondition(parseHit(jsonlData(for: [encodedHit]).dropLast()) == encodedHit)
        let csvLines = String(decoding: exportData(for: [encodedHit], format: .csv), as: UTF8.self).split(separator: "\n")
        let csvHeaders = csvLines[0].split(separator: ",", omittingEmptySubsequences: false)
        let csvValues = csvLines[1].split(separator: ",", omittingEmptySubsequences: false)
        precondition(csvHeaders.count == csvValues.count && csvValues[csvHeaders.firstIndex(of: "contentEncoding")!] == "utf-16-be")
        var localConfiguration = SearchConfiguration()
        localConfiguration.localOnly = true
        precondition(localConfiguration.arguments(pattern: "needle", root: "/fixture")!.contains("--local-only"))
        precondition(SearchConfiguration.fromQueryItems(localConfiguration.queryItems) == localConfiguration)
        let localTemplate = SearchTemplate(name: "Lokal", pattern: "needle", root: "/fixture", configuration: localConfiguration)
        let localData = try SearchTemplateFormat.encode([localTemplate])
        var localObject = try JSONSerialization.jsonObject(with: localData) as! [String: Any]
        precondition(localObject["version"] as? Int == 6)
        let localRestored = try SearchTemplateFormat.decode(localData)
        precondition(localRestored[0].configuration.localOnly)
        localObject["version"] = 5
        do { _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: localObject)); preconditionFailure("Lokale Politik unter Altformat") }
        catch is SearchTemplateError {}
        for query in ["local-only=2", "local-only=1&local-only=0", "local-only"] {
            do { _ = try SearchTemplateFormat.decodeOptions(query); preconditionFailure("Ungültige lokale Politik") }
            catch is SearchTemplateError {}
        }
        let localHandoff = try writeQuickHandoff([], version: 6, roots: ["/fixture"], configuration: localConfiguration)
        let localPayload = consumeQuickHandoffPayload(localHandoff)!.bound(to: ["/fixture"])!
        precondition(localPayload.version == 6 && localPayload.configuration!.localOnly)
        do { _ = try writeQuickHandoff([], version: 5, roots: ["/fixture"], configuration: localConfiguration); preconditionFailure("Lokale Politik in alter Quick-Übergabe") }
        catch {}
        let localView = SearchFilterView()
        var localChanges = 0
        localView.onChange = { localChanges += 1 }
        precondition(!localView.localOnly && localView.activeFilterCount == 0)
        localView.localOnlyCheckbox.performClick(nil)
        precondition(localView.localOnly && localView.activeFilterCount == 1 && localChanges == 1)
        var pdfConfiguration = SearchConfiguration()
        pdfConfiguration.mode = .document; pdfConfiguration.pdfOCR = true; pdfConfiguration.ocr = true; pdfConfiguration.localOnly = true
        precondition(pdfConfiguration.arguments(pattern: "München", root: "/fixture")!.contains("--pdf-ocr"))
        precondition(SearchConfiguration.fromQueryItems(pdfConfiguration.queryItems) == pdfConfiguration)
        let pdfTemplate = SearchTemplate(name: "PDF-OCR", pattern: "München", root: "/fixture", configuration: pdfConfiguration)
        let pdfData = try SearchTemplateFormat.encode([pdfTemplate])
        var pdfObject = try JSONSerialization.jsonObject(with: pdfData) as! [String: Any]
        precondition(pdfObject["version"] as? Int == 8)
        let restoredPDF = try SearchTemplateFormat.decode(pdfData); precondition(restoredPDF[0].configuration.pdfOCR)
        pdfObject["version"] = 7
        do { _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: pdfObject)); preconditionFailure("PDF-OCR unter Altformat") } catch {}
        let pdfHandoff = try writeQuickHandoff([], version: 8, roots: ["/fixture"], configuration: pdfConfiguration)
        let pdfPayload = consumeQuickHandoffPayload(pdfHandoff)!.bound(to: ["/fixture"])!
        precondition(pdfPayload.version == 8 && pdfPayload.configuration!.pdfOCR && pdfPayload.configuration!.ocr)
        do { _ = try writeQuickHandoff([], version: 7, roots: ["/fixture"], configuration: pdfConfiguration); preconditionFailure("PDF-OCR in alter Übergabe") } catch {}
        let pdfView = SearchFilterView(); precondition(!pdfView.pdfOCR); pdfView.pdfOCRCheckbox.performClick(nil)
        precondition(pdfView.pdfOCR && pdfView.activeFilterCount == 1)
        let pdfPosition: [String: Any] = ["kind": "pdfOCR", "page": 2, "block": 1, "line": 1, "confidence": 0.9, "region": [0.1, 0.2, 0.5, 0.1]]
        precondition(DocumentPosition.parse(pdfPosition)!.json["page"] as? Int == 2)
        var badPDFPosition = pdfPosition; badPDFPosition["page"] = true
        precondition(DocumentPosition.parse(badPDFPosition) == nil)
        precondition(DocumentPosition.parse(["kind": "pdfTextPage", "page": 1, "line": 1])!.reader == "pdfkit-vision-v1")
        if case .progress(let detail)? = parseSearchLine(Data(#"{"type":"progress","path":"/fixture","stage":"pdfOCR","page":2,"pages":4}"#.utf8)) { precondition(detail.contains("PDF-OCR · Seite 2 von 4")) } else { preconditionFailure("PDF-Fortschritt fehlt") }
        var ocrConfiguration = SearchConfiguration()
        ocrConfiguration.mode = .document; ocrConfiguration.ocr = true; ocrConfiguration.localOnly = true
        precondition(ocrConfiguration.arguments(pattern: "München", root: "/fixture")!.contains("--ocr"))
        precondition(SearchConfiguration.fromQueryItems(ocrConfiguration.queryItems) == ocrConfiguration)
        let ocrTemplate = SearchTemplate(name: "OCR", pattern: "München", root: "/fixture", configuration: ocrConfiguration)
        let ocrData = try SearchTemplateFormat.encode([ocrTemplate])
        var ocrObject = try JSONSerialization.jsonObject(with: ocrData) as! [String: Any]
        precondition(ocrObject["version"] as? Int == 7)
        let restoredOCR = try SearchTemplateFormat.decode(ocrData)
        precondition(restoredOCR[0].configuration.ocr)
        ocrObject["version"] = 6
        do { _ = try SearchTemplateFormat.decode(JSONSerialization.data(withJSONObject: ocrObject)); preconditionFailure("OCR unter Altformat") }
        catch is SearchTemplateError {}
        let ocrHandoff = try writeQuickHandoff([], version: 7, roots: ["/fixture"], configuration: ocrConfiguration)
        let ocrPayload = consumeQuickHandoffPayload(ocrHandoff)!.bound(to: ["/fixture"])!
        precondition(ocrPayload.version == 7 && ocrPayload.configuration!.ocr && ocrPayload.configuration!.localOnly)
        do { _ = try writeQuickHandoff([], version: 6, roots: ["/fixture"], configuration: ocrConfiguration); preconditionFailure("OCR in alter Quick-Übergabe") }
        catch {}
        let ocrView = SearchFilterView()
        precondition(!ocrView.ocr)
        ocrView.ocrCheckbox.performClick(nil)
        precondition(ocrView.ocr && ocrView.activeFilterCount == 1)
        let ocrPosition: [String: Any] = ["kind": "imageOCR", "block": 1, "line": 1, "confidence": 0.9, "region": [0.1, 0.2, 0.5, 0.1]]
        let ocrGeneration: [String: Any] = ["device": "1", "inode": "2", "size": "3", "modifiedNS": "4", "changedNS": "5"]
        let ocrRow: [String: Any] = ["path": "/fixture/screen.png", "type": "file", "isDirectory": false, "filesystemPath": "/fixture/screen.png", "archiveMembers": [], "line": 1,
            "contentEncoding": "vision-ocr-text-v1", "documentPosition": ocrPosition, "documentSourceGeneration": ocrGeneration]
        let ocrHit = parseHit(try JSONSerialization.data(withJSONObject: ocrRow))!
        precondition(ocrHit.documentPosition!.title.contains("OCR") && ocrHit.documentPosition!.title.contains("ca."))
        precondition(parseHit(jsonlData(for: [ocrHit]).dropLast()) == ocrHit)
        let boundOCRHit = SearchRoots(["/fixture"]).carrying(ocrHit)!
        var pdfOnly = pdfConfiguration; pdfOnly.ocr = false
        do { _ = try writeQuickHandoff([boundOCRHit], version: 8, roots: ["/fixture"], configuration: pdfOnly); preconditionFailure("Bild-OCR ohne aktive Bildoption in PDF-Übergabe") } catch {}
        let mixedHandoff = try writeQuickHandoff([boundOCRHit], version: 8, roots: ["/fixture"], configuration: pdfConfiguration)
        let lines = try Data(contentsOf: mixedHandoff).split(separator: 10)
        var header = try JSONSerialization.jsonObject(with: Data(lines[0])) as! [String: Any]
        header["options"] = pdfOnly.queryItems.map { ["name": $0.name, "value": $0.value ?? ""] }
        var altered = try JSONSerialization.data(withJSONObject: header); altered.append(10); altered.append(jsonlData(for: [boundOCRHit]))
        try altered.write(to: mixedHandoff)
        precondition(consumeQuickHandoffPayload(mixedHandoff) == nil)
        var badOCR = ocrPosition; badOCR["confidence"] = true
        precondition(DocumentPosition.parse(badOCR) == nil)
        badOCR = ocrPosition; badOCR["region"] = [0.9, 0.2, 0.5, 0.1]
        precondition(DocumentPosition.parse(badOCR) == nil)
        let ocrCSV = String(decoding: exportData(for: [ocrHit], format: .csv), as: UTF8.self)
        precondition(ocrCSV.contains("ocrBlock,ocrConfidence,ocrRegion") && ocrCSV.contains("0.1;0.2;0.5;0.1"))
        let view = SearchFilterView()
        view.literalWildcards = true
        precondition(view.literalWildcardsCheckbox.title == "* wörtlich")
        precondition(view.literalWildcards && view.activeFilterCount == 1)
        view.rawFacts = original.rawFacts
        precondition(view.rawFacts == original.rawFacts)
        view.exclusions = original.exclusions
        precondition(view.exclusions == original.exclusions)
        view.exclusionsEditor.string = "a\n\n space \nb"
        precondition(view.exclusions == ["a", " space ", "b"])
        var changes = 0
        view.onChange = { changes += 1 }
        view.textDidChange(Notification(name: NSText.didChangeNotification))
        precondition(changes == 1)
        view.literalWildcardsCheckbox.performClick(nil)
        precondition(!view.literalWildcards && changes == 2)
        if arguments.count > 1 {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView!.wantsLayer = true
            window.contentView!.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            window.contentView!.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 12),
                view.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -12),
                view.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12)])
            view.exclusions = ["node_modules", "Cache/*.zip"]
            view.rawFacts = ["min-size": "1 MiB", "max-size": "10 MiB",
                             "modified-from": "2026-09-05T00:00:00Z",
                             "modified-to": "2026-09-05T23:59:59+02:00"]
            window.contentView!.layoutSubtreeIfNeeded()
            precondition(!window.isVisible && !window.isKeyWindow)
            guard let bitmap = window.contentView!.bitmapImageRepForCachingDisplay(in: window.contentView!.bounds)
            else { fatalError("Offscreen-Bitmap fehlt") }
            window.contentView!.cacheDisplay(in: window.contentView!.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: arguments[1]))
        }
        print("CONFIGURATION OK")
    }
}
