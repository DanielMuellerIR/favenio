import AppKit
import Quartz

@main
struct FavenioQuickSelfTest {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let screenshot = arguments.first == "--selftest-scope-ui"
        if screenshot && arguments.count != 2 {
            print("Aufruf: FavenioQuick --selftest-scope-ui <Ausgabeordner>")
            exit(2)
        }
        let forcedDisclosureFailure = arguments.contains("--fail-preferences")
            ? "Erzwungener Fehler nach Änderung der Finder-Spalten" : nil
        let status = runWithIsolatedPreferences(
            bundleIdentifierPrefix: "local.favenio.selftest.quick",
            filterKey: QuickController.filtersExpandedKey,
            success: screenshot ? nil : "Quick-Suche, Zeitpause und Trefferlisten-Werkzeuge"
        ) {
            if screenshot {
                return runScopeScreenshot(output: URL(fileURLWithPath: arguments[1]))
            }
            if arguments.contains("--fail-scope-capture") {
                do {
                    try captureScopeImage(executable: "/usr/bin/false", arguments: [])
                    print("SELFTEST FEHLER: Erzwungener Aufnahmefehler wurde nicht erkannt")
                } catch {
                    print("SELFTEST FEHLER: \(error.localizedDescription)")
                }
                return 1
            }
            return runQuickSelfTest(forcedDisclosureFailure: forcedDisclosureFailure)
        }
        exit(status)
    }
}

private struct QuickSelfTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func captureScopeImage(executable: String, arguments: [String]) throws {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: executable)
    capture.arguments = arguments
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationReason == .exit, capture.terminationStatus == 0 else {
        throw QuickSelfTestError(message: "Bildaufnahme fehlgeschlagen (Status \(capture.terminationStatus))")
    }
}

private func runScopeScreenshot(output: URL) -> Int32 {
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = QuickController()
    controller.buildWindow()
    controller.field.stringValue = "fixture"
    controller.hasSearched = true
    controller.searchRoot = "/ersatz"
    controller.finish(query: "fixture", errorText: nil)
    controller.window.orderBack(nil)
    defer { controller.window.orderOut(nil) }
    func captureWindow(_ name: String) throws {
        controller.window.displayIfNeeded()
        try captureScopeImage(executable: "/usr/sbin/screencapture", arguments: [
            "-x", "-l", "\(controller.window.windowNumber)",
            output.appendingPathComponent(name + ".png").path,
        ])
        guard !app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost else {
            throw QuickSelfTestError(message: "Die Bildaufnahme hat den Fokus verändert")
        }
    }
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (index, folders) in [["/finder"], ["/ersatz"]].enumerated() {
            controller.applyScopeOutcome(.folders(folders))
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            guard !app.isActive, controller.window.isVisible else {
                throw QuickSelfTestError(message: "Quick-Fenster ist im Hintergrund nicht sichtbar")
            }
            if index == 0 {
                guard controller.infoLabel.stringValue.contains("Finder-Ordner ist /finder"),
                      controller.infoLabel.textColor == .systemOrange else {
                    throw QuickSelfTestError(message: "Warnung bei abweichendem Finder-Ordner fehlt")
                }
            } else {
                guard let outcome = controller.searchOutcomeText,
                      controller.runScopeMismatch == nil, controller.infoLabel.stringValue == outcome,
                      controller.infoLabel.textColor == .secondaryLabelColor,
                      controller.infoLabel.toolTip == outcome + "\n/ersatz" else {
                    throw QuickSelfTestError(message: "Nach übereinstimmendem Finder-Ordner bleibt die Warnung sichtbar")
                }
            }
            try captureWindow("scope-\(index)")
        }
        let fixture = output.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data().write(to: fixture.appendingPathComponent("fixture.txt"))
        controller.manualSearchRoots = [fixture.path]
        controller.userPickedScope = true
        controller.initialSearchSeconds = 0
        controller.startSearch()
        let until = Date(timeIntervalSinceNow: 8)
        while controller.resumeButton.isHidden && Date() < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard !controller.resumeButton.isHidden, controller.infoLabel.stringValue.contains("Pausiert") else {
            throw QuickSelfTestError(message: "Quick-Suche zeigt die erwartete Pause nicht an")
        }
        try captureWindow("quick-paused")
        controller.resumeButton.performClick(nil)
        while controller.runningSearch != nil && Date() < until {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard controller.hits.count == 1, controller.infoLabel.stringValue.contains("Suchbereich durchsucht") else {
            throw QuickSelfTestError(message: "Quick-Suche zeigt den erwarteten Endstand nicht an")
        }
        try captureWindow("quick-finished")
        print("SCOPE UI OK — Bereichswarnung und normaler Quick-Endstand im Hintergrund geprüft")
    } catch {
        print("SELFTEST FEHLER: \(error.localizedDescription)")
        return 1
    }
    return 0
}

private func checkFinderRefresh() -> String? {
    var replies: [FinderScopeRefresh.Reply] = []
    let refresh = FinderScopeRefresh(query: { replies.append($0) })
    let controller = QuickController(finderScopeRefresh: refresh)
    let activation = Notification(name: NSApplication.didBecomeActiveNotification)
    defer { controller.cancelSearch() }

    controller.applyScopeOutcome(.folders(["/alter-finder"]))
    controller.applicationDidBecomeActive(activation)
    controller.applicationDidBecomeActive(activation)
    controller.applicationDidBecomeActive(activation)
    guard controller.scopeFinderFolders.isEmpty, !controller.scopeResolved,
          controller.selectedSearchRoots == nil, replies.count == 1 else {
        return "Quick verwendet während einer neuen Aktivierung alte Finder-Ordner"
    }
    let stale = replies.removeFirst()
    stale(.folders(["/ueberholt"]))
    guard controller.scopeFinderFolders.isEmpty, !controller.scopeResolved, replies.count == 1 else {
        return "Quick verwirft die alte Antwort oder startet die neue Finder-Abfrage nicht korrekt"
    }
    controller.deniedAlertShown = true
    let current = replies.removeFirst()
    current(.denied)
    guard replies.isEmpty, controller.scopeResolved, controller.scopeDenied,
          controller.scopeFinderFolders.isEmpty,
          controller.selectedSearchRoots?.first == commonFolders().first?.path,
          controller.infoLabel.stringValue.contains("Finder-Zugriff nicht erlaubt"),
          controller.infoLabel.textColor == .systemOrange else {
        return "Eine verweigerte Finder-Abfrage zeigt keinen verständlichen Ersatzbereich"
    }
    controller.applyScopeOutcome(.folders(["/finder"]))
    guard controller.infoLabel.stringValue == QuickController.hint,
          controller.runScopeMismatch == nil,
          controller.selectedSearchRoots == ["/finder"] else {
        return "Eine erfolgreiche Finder-Antwort löst die Bereichswarnung im Leerlauf nicht ab"
    }

    controller.hasSearched = true
    controller.searching = true
    controller.searchRoot = "/ersatz"
    controller.resumeButton.isHidden = true
    controller.applyScopeOutcome(.folders(["/finder"]))
    let runningNote = "Suche läuft in /ersatz — Finder-Ordner ist /finder (Return sucht dort)."
    controller.showProgress(path: "/ersatz/unterordner")
    guard controller.infoLabel.stringValue.contains(runningNote) else {
        return "Suchfortschritt verdrängt den Hinweis auf den tatsächlichen Suchbereich"
    }
    let hit = Hit(path: "/ersatz/treffer", kind: "file", line: nil, size: 1,
                  filesystemPath: "/ersatz/treffer", archiveMembers: [], isDirectory: false)
    controller.enqueueSearchHits([hit], scope: SearchRoots(["/ersatz"]))
    controller.flushPending()
    guard controller.hits.count == 1, controller.infoLabel.stringValue.contains(runningNote) else {
        return "Treffer verdrängen den Hinweis auf den tatsächlichen Suchbereich"
    }
    controller.finish(query: "treffer", errorText: nil)
    let completedNote = "Gesucht wurde in /ersatz — Finder-Ordner ist /finder (Return sucht dort)."
    guard controller.infoLabel.stringValue.contains(completedNote),
          !controller.infoLabel.stringValue.contains(runningNote) else {
        return "Die Infozeile zeigt nach der Suche einen laufenden Suchvorgang"
    }
    controller.userPickedScope = true
    guard controller.runScopeNoteText() == nil else {
        return "Der Finder-Hinweis bleibt nach eigener Bereichswahl aktiv"
    }
    controller.userPickedScope = false

    for summary in ["Keine Treffer. — 1 Objekt übersprungen.", "Suche fehlgeschlagen."] {
        controller.searchOutcomeText = summary
        controller.applyScopeOutcome(.folders(["/finder"]))
        guard controller.infoLabel.stringValue == summary + " " + completedNote else {
            return "Die verspätete Finder-Antwort überdeckt Warnungen oder Suchfehler"
        }
        controller.applyScopeOutcome(.folders(["/ersatz"]))
        guard controller.infoLabel.stringValue == summary,
              controller.infoLabel.toolTip == summary + "\n/ersatz" else {
            return "Nach bestätigtem Finder-Ordner bleibt die falsche Warnung stehen"
        }
    }

    controller.searchOutcomeText = "1 Treffer."
    controller.showHandoffIssue("Übergabe abgelehnt")
    controller.applyScopeOutcome(.folders(["/finder"]))
    guard controller.infoLabel.stringValue == "1 Treffer. " + completedNote + " · Übergabe abgelehnt" else {
        return "Die Übergabemeldung verdrängt den Hinweis auf den tatsächlichen Suchbereich"
    }
    controller.applyScopeOutcome(.folders(["/ersatz"]))
    guard controller.infoLabel.stringValue == "Übergabe abgelehnt" else {
        return "Die bestätigte Suche verdrängt die abgelehnte Übergabe"
    }

    controller.applicationDidBecomeActive(activation)
    controller.field.stringValue = "neue Suche"
    controller.startSearch()
    guard controller.queuedQuery, controller.hits.isEmpty, !controller.openButton.isEnabled else {
        return "Vor der Finder-Antwort bleiben alte Treffer für die Übergabe verfügbar"
    }
    return nil
}

private func checkQuickSearchInputs() -> String? {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("quick-inputs-" + UUID().uuidString)
    let folder = root.appendingPathComponent("ASSET.TARGET-folder", isDirectory: true)
    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    } catch { return "Suchfixture nicht angelegt: \(error)" }
    defer { try? fileManager.removeItem(at: root) }
    do {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["ASSET.TARGET-file.txt", "ASSETxTARGET-decoy.txt", "replacement.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        for (name, width) in [("wide.png", 20), ("narrow.png", 4)] {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let pixels = bitmap.bitmapData else { return "Bildfixture nicht angelegt" }
            pixels.initialize(repeating: 180, count: bitmap.bytesPerPlane)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return "Bildfixture nicht kodiert" }
            try png.write(to: root.appendingPathComponent(name))
        }
    } catch { return "Suchfixture nicht geschrieben: \(error)" }

    let controller = QuickController()
    controller.buildWindow()
    controller.manualSearchRoots = [root.path]
    controller.userPickedScope = true
    defer { controller.cancelSearch() }
    func finishWith(_ expected: Set<String>) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while (controller.debounceTimer != nil || controller.runningSearch != nil),
              ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return controller.hasSearched && controller.runningSearch == nil
            && controller.debounceTimer == nil && Set(controller.hits.map(\.displayName)) == expected
            && controller.tableView.numberOfRows == expected.count
            && controller.infoLabel.stringValue.contains("\(expected.count) Treffer")
    }
    func checkHandoff(query: String, only: String, width: String, names: Set<String>,
                      useFallback: Bool = false, action: () -> Void) -> Bool {
        enum Launch {
            case url(URL)
            case bundle(URL, NSWorkspace.OpenConfiguration)
        }
        var launches: [Launch] = []
        let app = root.appendingPathComponent("Favenio.app")
        controller.handoffWorkspaceForSelfTest = (
            app,
            { launches.append(.url($0)); return !useFallback },
            { launches.append(.bundle($0, $1)) }
        )
        defer { controller.handoffWorkspaceForSelfTest = nil }
        action()
        guard case let .url(handoff)? = launches.first,
              let components = URLComponents(url: handoff, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let file = items.first(where: { $0.name == "file" })?.value,
              let hits = consumeQuickHandoff(URL(fileURLWithPath: file)) else { return false }
        if useFallback {
            guard launches.count == 2, case let .bundle(target, configuration) = launches[1],
                  target == app, configuration.createsNewApplicationInstance,
                  configuration.arguments == ["--handoff-url", handoff.absoluteString] else { return false }
        } else {
            guard launches.count == 1 else { return false }
        }
        let expected = ["q": query, "root": root.path, "continue": "1", "only": only,
                        "regex": "0", "case": "0", "minw": width]
        return components.scheme == "favenio" && components.host == "results"
            && Set(hits.map(\.displayName)) == names
            && expected.allSatisfy { key, value in items.filter { $0.name == key }.map(\.value) == [value] }
    }
    func editSearchField(_ text: String) {
        controller.field.stringValue = text
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: controller.field)
    }

    let query = "asset.target"
    let matchingFile = "ASSET.TARGET-file.txt"
    let matchingFolder = "ASSET.TARGET-folder"
    controller.field.stringValue = query
    for (segment, names): (Int, Set<String>) in [(0, [matchingFile, matchingFolder]),
                                                  (1, [matchingFile]), (2, [matchingFolder])] {
        controller.typeControl.selectedSegment = segment
        guard controller.typeControl.sendAction(controller.typeControl.action, to: controller.typeControl.target),
              finishWith(names) else { return "Quick-Typfilter liefert falsche Treffer für Segment \(segment)" }
    }
    // Die Übergabe muss den Typ aus dem Suchlauf übernehmen.
    controller.typeControl.selectedSegment = 1
    guard controller.openButton.isEnabled,
          checkHandoff(query: query, only: "dirs", width: "", names: [matchingFolder],
                       action: { controller.openButton.performClick(nil) }) else {
        return "Quick-Übergabe verliert Typ, explizite Optionen oder Starttreffer"
    }

    controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
    controller.previewURLs = [folder]
    controller.runScopeMismatch = (searched: root.path, finder: folder.path)
    editSearchField("replacement")
    guard controller.hits.isEmpty, controller.tableView.numberOfRows == 0,
          controller.tableView.selectedRowIndexes.isEmpty, controller.previewURLs.isEmpty,
          controller.runScopeMismatch == nil,
          !controller.openButton.isEnabled, controller.infoLabel.stringValue == QuickController.hint,
          controller.runningSearch == nil, !controller.hasSearched, controller.debounceTimer?.isValid == true else {
        return "Quick zeigt beim Tippen vor der neuen Suche noch alte Treffer"
    }
    guard checkHandoff(query: "replacement", only: "files", width: "", names: [],
                       action: controller.openInMainApp) else {
        return "Quick übergibt vor dem ersten Suchlauf nicht den neuen Text mit leerer Startmenge"
    }
    editSearchField("replacement")
    guard finishWith(["replacement.txt"]) else { return "Quick wartet beim Tippen nicht auf den neuen Suchlauf" }

    editSearchField("")
    controller.fire()
    guard controller.hits.isEmpty, controller.tableView.numberOfRows == 0,
          controller.runningSearch == nil, !controller.queuedQuery, !controller.hasSearched,
          controller.debounceTimer == nil, !controller.openButton.isEnabled,
          controller.infoLabel.stringValue == QuickController.hint else {
        return "Leeres Suchfeld ohne Filter startet eine Quick-Suche"
    }
    controller.minWidthField.stringValue = "10"
    guard controller.minWidthField.sendAction(controller.minWidthField.action, to: controller.minWidthField.target),
          finishWith(["wide.png"]), controller.hits.first?.width == 20,
          controller.infoLabel.stringValue.contains("1 Treffer (B ≥ 10)."),
          controller.openButton.isEnabled else {
        return "Quick-Maßsuche ohne Muster verliert Treffer oder Statistik"
    }
    guard checkHandoff(query: "", only: "files", width: "10", names: ["wide.png"], useFallback: true,
                       action: { controller.openButton.performClick(nil) }) else {
        return "Quick übergibt die Maßsuche beim Ersatzstart nicht mit derselben URL"
    }
    print("QUICK SEARCH INPUTS OK: type, pixel filter, debounce, result count, handoff and launch fallback")
    return nil
}

private func runQuickSelfTest(forcedDisclosureFailure: String?) -> Int32 {
    defer { cleanupMaterializedHits() }
    _ = NSApplication.shared
    if let failure = checkFinderRefresh() ?? checkQuickSearchInputs() {
        print("SELFTEST FEHLER: \(failure)")
        return 1
    }
    let controller = QuickController()
    if let error = pixelFieldSelfTest(controller.pixelFields,
                                     validate: controller.validatePixelInputs) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    controller.filterView.literalWildcards = true
    guard controller.searchConfiguration.literalWildcards else {
        print("SELFTEST FEHLER: Wörtliche Platzhalteroption fehlt")
        return 1
    }
    controller.filterView.exclusions = ["node_modules", " keep spaces "]
    controller.filterView.rawFacts = ["min-size": "0"]
    guard controller.searchConfiguration.hasPositiveFilter,
          controller.searchConfiguration.arguments(pattern: "", root: "/fixture") != nil else {
        print("SELFTEST FEHLER: Reine Faktenfilter starten keine Suche")
        return 1
    }
    guard controller.searchConfiguration.exclusions == ["node_modules", " keep spaces "],
          SearchConfiguration.fromQueryItems(controller.searchConfiguration.queryItems)
            == controller.searchConfiguration else {
        print("SELFTEST FEHLER: Ausschlussoptionen gehen zwischen Controls und Übergabe verloren")
        return 1
    }
    // Weitere Suchbegriffe: erreichen Argumente und die Übergabe-URL.
    controller.filterView.terms = ["beta"]
    guard controller.searchConfiguration.terms == ["beta"],
          controller.searchConfiguration.arguments(pattern: "alpha", root: "/fixture")?
              .contains("--term=beta") == true,
          controller.searchConfiguration.queryItems.contains(
              URLQueryItem(name: "term", value: "beta")) else {
        print("SELFTEST FEHLER: Weitere Suchbegriffe erreichen Argumente oder Übergabe nicht")
        return 1
    }
    controller.filterView.terms = []
    let criteria = """
    {"schemaVersion":1,"root":{"id":"quick","field":"name","operator":"contains","value":"Treffer"}}
    """
    controller.criteriaControl.applyJSON(criteria)
    guard controller.searchConfiguration.criteriaJSON == criteria,
          controller.searchConfiguration.arguments(pattern: "", root: "/fixture")?
            .contains("--criteria-json=" + criteria) == true,
          SearchConfiguration.fromQueryItems(controller.searchConfiguration.queryItems)
            == controller.searchConfiguration else {
        print("SELFTEST FEHLER: Quick verliert den Kriterienbaum")
        return 1
    }
    controller.criteriaControl.applyJSON(nil)
    controller.startSearch()
    guard controller.queuedQuery else {
        print("SELFTEST FEHLER: Reine Faktenfilter erreichen Quick-Start nicht")
        return 1
    }
    controller.cancelSearch()
    controller.field.stringValue = "Treffer"
    controller.minWidthField.stringValue = "10.5"
    controller.startSearch()
    controller.openInMainApp()
    guard controller.runningSearch == nil, !controller.searching,
          !controller.queuedQuery,
          controller.infoLabel.stringValue == controller.minWidthField.toolTip else {
        print("SELFTEST FEHLER: Ungültige Maße starten oder übergeben die Schnellsuche")
        return 1
    }
    controller.field.stringValue = ""
    controller.optionsChanged()
    guard controller.minWidthField.toolTip != nil else {
        print("SELFTEST FEHLER: Maßfehler ohne Suchtext bleibt unsichtbar")
        return 1
    }
    let oversized = QuickController()
    oversized.field.stringValue = String(repeating: "🙂", count: 1025)
    oversized.scopePopup.addItem(withTitle: "Fixture")
    oversized.scopePopup.selectedItem?.representedObject = "/fixture"
    oversized.openInMainApp()
    guard oversized.infoLabel.stringValue == quickHandoffInputProblem(
        query: oversized.field.stringValue, root: "/fixture"),
          quickHandoffInputProblem(query: String(repeating: "🙂", count: 1024),
                                   root: "/fixture") == nil,
          quickHandoffInputProblem(query: "x", root: String(repeating: "x", count: 4097)) != nil else {
        print("SELFTEST FEHLER: Zu lange Übergabe wird nicht vor dem Öffnen erkannt")
        return 1
    }
    for flags: NSEvent.ModifierFlags in [[], .shift, .option, .command] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        guard controller.previewPanel(nil, handle: event) == flags.isEmpty else {
            print("SELFTEST FEHLER: Quick Look verarbeitet Escape mit Zusatztaste")
            return 1
        }
    }
    let literal = Hit(path: "/fixture/a.zip!/inner.zip!/x.txt", kind: "member",
        line: nil, size: nil, filesystemPath: "/fixture/a.zip",
        archiveMembers: ["inner.zip!/x.txt"], isDirectory: false)
    let nested = Hit(path: literal.path, kind: "member", line: nil, size: nil,
        filesystemPath: literal.filesystemPath,
        archiveMembers: ["inner.zip", "x.txt"], isDirectory: false)
    controller.buildWindow()
    controller.hits = [literal, nested]
    controller.reloadKeepingSelection([])
    guard MaterializationManager.shared.knownURL(for: literal) == nil,
          let promise = controller.tableView.dataSource?.tableView?(
            controller.tableView, pasteboardWriterForRow: 0) as? NSFilePromiseProvider,
          (promise.userInfo as? Hit)?.identity == literal.identity,
          MaterializationManager.shared.knownURL(for: literal) == nil else {
        print("SELFTEST FEHLER: Quick verspricht das uncached Archivmitglied beim Ziehen nicht")
        return 1
    }
    controller.tableView.selectRowIndexes([0], byExtendingSelection: false)
    let selected = controller.selectedHitIdentities()
    controller.hits.reverse()
    controller.reloadKeepingSelection(selected)
    guard controller.tableView.selectedRowIndexes == IndexSet(integer: 1) else {
        print("SELFTEST FEHLER: Quick verwechselt gleiche Anzeigepfade")
        return 1
    }
    // Kein externer Öffnen-Aufruf: Die leere Tabelle liefert keine URL.
    controller.hits = []
    controller.reloadKeepingSelection([])
    controller.contextRow = 7
    controller.openSelected()
    guard controller.contextRow == -1 else {
        print("SELFTEST FEHLER: Doppelklick behält die alte Kontextzeile")
        return 1
    }
    controller.contextRow = 7
    controller.ctxOpen()
    guard controller.contextRow == 7 else {
        print("SELFTEST FEHLER: Kontextaktion verliert ihre Zeile")
        return 1
    }
    let deduped = QuickController()
    let roots = SearchRoots(["/scope-a", "/scope-b"])
    var repeated: [Hit] = []
    for index in 0..<25 {
        var hit = Hit(path: "/scope-a/item-\(index)", kind: "file", line: nil, size: 1,
            filesystemPath: "/scope-a/item-\(index)", archiveMembers: [], isDirectory: false,
            searchRootBytes: roots.bytes[0])
        repeated.append(hit); hit.searchRootBytes = roots.bytes[1]; repeated.append(hit)
    }
    deduped.enqueueSearchHits(repeated, scope: roots)
    guard deduped.pending.count == 25, Set(deduped.pending.map { $0.identity }).count == 25,
          deduped.pending.allSatisfy({ $0.searchRootBytes == roots.bytes[0] }) else {
        print("SELFTEST FEHLER: Quick dedupliziert überlappende Suchbereiche falsch")
        return 1
    }
    deduped.manualSearchRoots = roots.paths; deduped.userPickedScope = true
    deduped.rebuildScopePopup(); deduped.scopeChanged()
    deduped.scopeProblem = nil; deduped.applyScopeOutcome(.denied)
    guard deduped.selectedSearchRoots == roots.paths, deduped.scopeProblem == nil else {
        print("SELFTEST FEHLER: Späte Finderantwort ersetzt manuelle Bereiche")
        return 1
    }
    let automatic = QuickController()
    automatic.scopeResolved = true; automatic.scopeFinderFolders = ["/finder"]
    automatic.rebuildScopePopup()
    automatic.scopePopup.select(automatic.scopePopup.itemArray.first { $0.identifier?.rawValue == "editSearchRoots" })
    guard automatic.selectedSearchRoots == ["/finder"] else {
        print("SELFTEST FEHLER: Editor-Menü verliert sichtbaren Finderbereich")
        return 1
    }
    do {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // os.walk liest die FIFO vor dem Abstieg in den Trefferordner.
        // Ihre Warnung muss auch nach dem Fortsetzen sichtbar bleiben.
        guard mkfifo(root.appendingPathComponent("warn.pipe").path, 0o600) == 0 else {
            throw QuickSelfTestError(message: "Test-FIFO konnte nicht angelegt werden")
        }
        let matches = root.appendingPathComponent("matches")
        try FileManager.default.createDirectory(at: matches, withIntermediateDirectories: true)
        for index in 0..<32 {
            try Data("NEEDLE\n".utf8).write(to: matches.appendingPathComponent("match-\(index).txt"))
        }
        let limited = QuickController()
        limited.tableView.dataSource = limited
        limited.field.stringValue = "NEEDLE"
        limited.modeControl.selectItem(at: 1)
        limited.scopePopup.addItem(withTitle: "Fixture")
        limited.scopePopup.selectedItem?.representedObject = root.path
        limited.initialSearchSeconds = 0
        limited.startSearch()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while limited.resumeButton.isHidden && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        guard let run = limited.runningSearch, !limited.searching, !limited.resumeButton.isHidden,
              limited.infoLabel.stringValue.contains("Weitere Treffer möglich") else {
            print("SELFTEST FEHLER: Zeitpause ohne Treffer nicht sichtbar")
            return 1
        }
        limited.resumeSearch()
        guard limited.runningSearch === run else { print("SELFTEST FEHLER: Fortsetzen startet neue Suche"); return 1 }
        while limited.runningSearch != nil && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        }
        guard limited.hits.count == 32, limited.runningSearch == nil, limited.resumeButton.isHidden,
              limited.infoLabel.stringValue.contains("Abdeckung eingeschränkt") else {
            print("SELFTEST FEHLER: Quick setzt die Suche nicht bis zum Ende fort")
            return 1
        }
        guard limited.skippedCount == 1,
              limited.infoLabel.stringValue.contains(skippedNote(1)),
              !limited.infoLabel.stringValue.contains("fehlgeschlagen") else {
            print("SELFTEST FEHLER: Fortsetzen verliert Warnungen")
            return 1
        }
    } catch {
        print("SELFTEST FEHLER: Quick-Zeitpause: \(error)")
        return 1
    }
    if let error = quickFilterDisclosureSelfTest(forcedFailure: forcedDisclosureFailure) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    let finderColumns = QuickController()
    finderColumns.buildWindow()
    if let failure = checkQuickWindowContracts(finderColumns) {
        print("SELFTEST FEHLER: \(failure)")
        return 1
    }
    if let error = finderColumnsSelfTest(finderColumns) ?? quickHandoffIssueSelfTest()
        ?? checkStreamedPreviewSelection() {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    let grouped = QuickController()
    grouped.buildWindow()
    if let error = resultGroupingListSelfTest(grouped) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    let filtered = QuickController()
    filtered.buildWindow()
    if let error = resultFilterListSelfTest(filtered, terminate: {
        filtered.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    let filteredLimit = QuickController()
    filteredLimit.buildWindow()
    filteredLimit.resultFilter.criteria.applyJSON(CriteriaNode(field: "name", value: "keep-").json)
    filteredLimit.resultFilter.apply()
    filteredLimit.pending = (0..<24).map { n in
        let path = "/missing/" + (n % 2 == 0 ? "keep-" : "other-") + String(n) + ".txt"
        return Hit(path: path, kind: "file", line: nil, size: 1,
            filesystemPath: path, archiveMembers: [], isDirectory: false)
    }
    filteredLimit.flushPending()
    let filteredUntil = ProcessInfo.processInfo.systemUptime + 8
    while filteredLimit.resultFilter.isFiltering && ProcessInfo.processInfo.systemUptime < filteredUntil {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard filteredLimit.resultFilter.sourceCount == 24,
          filteredLimit.hits.count == 12, filteredLimit.pending.isEmpty,
          filteredLimit.resultFilter.errorMessage == nil else {
        print("SELFTEST FEHLER: Ansichtsfilter verliert Quick-Quelltreffer")
        filteredLimit.resultFilter.stopForTermination()
        return 1
    }
    filteredLimit.resultFilter.reset()
    guard filteredLimit.hits.count == 24 else { print("SELFTEST FEHLER: Quick-Filterreset verliert Quelltreffer"); return 1 }
    // Die Vorschau zu schließen darf die App NICHT beenden. Der
    // Controller ist auch Delegat des Quick-Look-Panels, und dessen
    // `orderOut` kommt als `windowWillClose` an. Feuerte hier
    // `NSApp.terminate`, endete der Selbsttest ohne die Zeile
    // „SELFTEST OK" — der Lauf muss also weiterkommen.
    do {
        let quitter = QuickController()
        quitter.buildWindow()
        quitter.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: QLPreviewPanel.shared() as Any))
        quitter.windowWillClose(Notification(
            name: NSWindow.willCloseNotification,
            object: NSWindow()))
    }
    return 0
}

private func checkQuickWindowContracts(_ controller: QuickController) -> String? {
    guard !(controller.window is NSPanel), controller.window.styleMask.contains(.miniaturizable),
          controller.window.level == .normal else {
        return "Schnellsuche verwendet kein reguläres minimierbares Fenster"
    }
    guard controller.field.sendsWholeSearchString,
          !controller.field.sendsSearchStringImmediately else {
        return "Das Suchfeld der Schnellsuche startet die Suche beim Tippen"
    }
    let table = controller.tableView
    guard table.tableColumns.first(where: { $0.identifier.rawValue == "name" })?.sortDescriptorPrototype?.key == "name",
          table.tableColumns.first(where: { $0.identifier.rawValue == "path" })?.sortDescriptorPrototype?.key == "path",
          table.allowsColumnResizing, table.columnAutoresizingStyle == .noColumnAutoresizing,
          table.headerView != nil, controller.scrollView.hasHorizontalScroller else {
        return "Treffertabelle lässt sich nicht per Spaltenkopf sortieren, vergrößern und horizontal scrollen"
    }
    let boundary = QuickController()
    boundary.tableView.dataSource = boundary
    return staleHitRowSelfTest(boundary, cellAt: { column, row in
        boundary.tableView(boundary.tableView, viewFor: column, row: row)
    })
}

private func checkStreamedPreviewSelection() -> String? {
    guard let cli = findCLI() else { return "Gebündelter Suchkern für Vorschauprobe fehlt" }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("favenio-quick-preview-\(UUID())")
    let source = root.appendingPathComponent("content.txt")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "needle\nKontext\nneedle\n".write(to: source, atomically: true, encoding: .utf8)
    } catch {
        return "Vorschau-Testdatei nicht anlegbar: \(error.localizedDescription)"
    }
    var hits: [Hit] = []
    let search = runSearchStreaming(
        arguments: [cli, "--json", "--content", "--content-preview", "needle", "--", source.path],
        onHit: { hits.append($0) }, onProgress: { _ in })
    guard search.status == 0, search.reason == .exit, hits.count == 1, let hit = hits.first else {
        return "Suchkern liefert keine zwei Fundstellen in der Vorschau-Testdatei"
    }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }
    for mode in [ResultGroupingMode.none, .folder] {
        let owner = QuickController()
        owner.buildWindow()
        let preview = owner.contentPreviewView
        preview.toggle.state = .on
        preview.syncVisibility()
        owner.replaceFilteredHits([hit], keepingSelection: [])
        owner.resultGrouping.setMode(mode)
        owner.tableView.selectRowIndexes(owner.tableRows(for: [hit.identity]), byExtendingSelection: false)
        guard wait({ !owner.contentPreviewController.isLoading
            && preview.textView.string.contains("Zeile 1") && preview.nextButton.isEnabled }) else {
            return "Quick-Vorschau (\(mode.rawValue)) zeigt die erste Fundstelle nicht"
        }
        preview.nextButton.performClick(nil)
        guard wait({ !owner.contentPreviewController.isLoading && preview.textView.string.contains("Zeile 3") }) else {
            return "Quick-Vorschau (\(mode.rawValue)) blättert nicht zur zweiten Fundstelle"
        }
        let unrelated = root.appendingPathComponent("other.txt").path
        owner.pending = [Hit(path: unrelated, kind: "file", line: nil, size: 0,
            filesystemPath: unrelated, archiveMembers: [], isDirectory: false)]
        owner.flushPending()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        guard owner.hits.count == 2, owner.selectedHitIdentities() == [hit.identity],
              preview.textView.string.contains("Zeile 3") else {
            return "Quick-Nachschub (\(mode.rawValue)) verliert Auswahl oder geladene Fundstelle"
        }
    }
    print("QUICK PREVIEW SELECTION OK: flat and grouped streaming")
    return nil
}

private func quickFilterDisclosureSelfTest(forcedFailure: String?) -> String? {
    let collapsed = QuickController()
    collapsed.buildWindow()
    if let error = contentPreviewDisclosureSelfTest(collapsed) { return error }
    // Infozeile und Knopf stehen in der Aufklappzeile, nicht in der
    // zugeklappten Maßzeile. `isHidden` allein sähe das nicht: Eine Ansicht
    // in einer versteckten Zeile bleibt selbst `isHidden == false`.
    guard !collapsed.infoLabel.isHiddenOrHasHiddenAncestor,
          !collapsed.openButton.isHiddenOrHasHiddenAncestor else {
        return "Infozeile oder Übergabeknopf sind bei zugeklappten Filtern unsichtbar"
    }
    favenioPreferences.set(true, forKey: "finderColumn.finderTags")
    if let forcedFailure { return forcedFailure }
    let restored = QuickController()
    restored.buildWindow()
    restored.window.orderOut(nil)
    guard restored.finderColumnsVisible, restored.searchConfiguration.finderMetadata else {
        return "Wiederhergestellte Finder-Spalten erfassen keine Eigenschaften"
    }
    return filterDisclosureSelfTest(collapsed.filters)
}

func quickHandoffIssueSelfTest() -> String? {
    let controller = QuickController()
    controller.buildWindow()
    let warning = "Die Haupt-App unterstützt Finder-Eigenschaften noch nicht."
    controller.searching = true
    controller.showHandoffIssue(warning)
    controller.showProgress(path: "/fixture")
    controller.pending = [Hit(path: "/fixture/keep.txt", kind: "file", line: nil, size: 1,
        filesystemPath: "/fixture/keep.txt", archiveMembers: [], isDirectory: false)]
    controller.flushPending()
    controller.finish(query: "keep", errorText: nil)
    controller.hasSearched = true
    controller.searchRoot = "/ersatz"
    controller.applyScopeOutcome(.folders(["/finder"]))
    guard controller.lastInfo.text.contains("Finder-Ordner ist /finder"),
          controller.lastInfo.text.contains(warning) else { return "Übergabehinweis verdeckt tatsächlichen Suchbereich" }
    controller.applyScopeOutcome(.folders(["/ersatz"]))
    guard controller.hits.count == 1, controller.searchOutcomeText?.contains("1 Treffer") == true,
          controller.lastInfo.text == warning else { return "Übergabehinweis wird durch Suchabschluss oder Bereichsantwort ersetzt" }
    let errorText = "Eigener Suchfehler: " + String(repeating: "Vollständiger technischer Grund. ", count: 40)
    controller.finish(query: "keep", errorText: errorText)
    guard controller.lastInfo.text == errorText,
          controller.infoLabel.toolTip?.contains(errorText) == true,
          controller.lastInfo.detail?.contains(errorText) == true,
          controller.lastInfo.detail?.contains(warning) == true else { return "Alter Übergabehinweis verdeckt Suchfehler" }
    controller.showHandoffIssue(warning)
    controller.presentActionIssue(summary: "Eigener Aktionsfehler", detail: nil)
    guard controller.lastInfo.text == "Eigener Aktionsfehler",
          controller.lastInfo.detail?.contains("Eigener Aktionsfehler") == true,
          controller.lastInfo.detail?.contains(warning) == true else { return "Alter Übergabehinweis verdeckt Aktionsfehler" }
    controller.showHandoffIssue(warning)
    controller.clearHits()
    guard controller.handoffIssue == nil, controller.lastInfo.text == QuickController.hint,
          controller.infoLabel.toolTip?.contains(errorText) != true,
          controller.infoLabel.toolTip?.contains(warning) != true else {
        return "Neue Frage behält alten Übergabehinweis oder Fehler-Tooltip"
    }
    controller.showHandoffIssue(warning)
    controller.field.stringValue = ""
    controller.openInMainApp()
    guard controller.handoffIssue == nil else { return "Neuer Übergabeversuch behält alten Hinweis" }
    print("QUICK HANDOFF ISSUE OK: progress, batch, finish, scope, error precedence, reset")
    return nil
}
