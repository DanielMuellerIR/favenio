import AppKit
import Quartz

@main
struct FavenioMainSelfTest {
    static func main() {
        let forcedDateFailure = CommandLine.arguments.contains("--fail-date")
            ? "Erzwungener Fehler im Datumstest" : nil
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-selftest-\(ProcessInfo.processInfo.processIdentifier)")
        let status = runWithIsolatedPreferences(
            bundleIdentifierPrefix: "local.favenio.selftest.main",
            filterKey: MainController.filtersExpandedKey,
            success: "Suche, Archiv-Extraktion und Trefferlisten-Werkzeuge"
        ) {
            let status = runMainSelfTest(sandbox: sandbox, forcedDateFailure: forcedDateFailure)
            guard !FileManager.default.fileExists(atPath: sandbox.path) else {
                print("SELFTEST FEHLER: Testordner nach Rückkehr noch vorhanden")
                return 2
            }
            return status
        }
        exit(status)
    }
}

// MARK: - Headless-Selbsttest

/// Kommt an, WAS der Kern gemeldet hat — oder nur, DASS etwas schiefging?
///
/// Bis 0.27.1 hing stderr des Kerns in beiden Apps auf `nullDevice`. Ein
/// fehlendes exiftool, ein ungültiger regulärer Ausdruck und ein gelöschter
/// Startordner kamen deshalb alle als „Suche fehlgeschlagen." an, und die
/// Schnellsuche riet zu einer Neuinstallation, die nichts half. Ebenso
/// unsichtbar war, dass ein Lauf Objekte überspringen musste: Er sah
/// genauso vollständig aus wie einer, der alles gelesen hat.
func checkDiagnosticsReachTheSurface(sandbox: URL) -> String? {
    guard let cli = findCLI() else { return "favenio.py nicht gefunden" }

    // 1. Ein Lauf, der mit Exit 2 endet, muss seinen GRUND mitbringen.
    let broken = runSearchStreaming(
        arguments: [cli, "--json", "--content", "--regex", "[unfertig",
                    "--", sandbox.path],
        onProgress: { _ in })
    guard searchExitIsError(broken.status, reason: broken.reason) else {
        return "ungültiger regulärer Ausdruck galt als erfolgreicher Lauf"
    }
    guard let reason = broken.errorMessage, !reason.isEmpty else {
        return "Exit 2 ohne Grund — stderr des Kerns kommt nicht an"
    }
    let text = searchFailureText(broken)
    guard text.contains(reason), text != "Suche fehlgeschlagen." else {
        return "Fehlertext nennt den Grund nicht: \(text)"
    }

    // 2. Ein Lauf, der etwas überspringen musste, muss das sagen können.
    //    Eine benannte Pipe ist dafür der verlässlichste Anlass: Der Kern
    //    liest sie nicht und meldet genau eine Warnung.
    let noisy = sandbox.appendingPathComponent("diagnose")
    try? FileManager.default.createDirectory(at: noisy,
                                             withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: noisy) }
    try? "FAVENIO_PROBE\n".write(to: noisy.appendingPathComponent("a.txt"),
                                 atomically: true, encoding: .utf8)
    guard mkfifo(noisy.appendingPathComponent("pipe.txt").path, 0o600) == 0
    else { return "Testpipe ließ sich nicht anlegen" }

    let skipping = runSearchStreaming(
        arguments: [cli, "--json", "--content", "FAVENIO_PROBE",
                    "--", noisy.path],
        onProgress: { _ in })
    guard !searchExitIsError(skipping.status, reason: skipping.reason) else {
        return "Lauf mit übersprungener Pipe galt als Fehlschlag"
    }
    guard skipping.warningCount == 1 else {
        return "übersprungenes Objekt nicht gezählt "
            + "(\(skipping.warningCount) statt 1)"
    }

    // 3. Mehr Warnungen, als in eine Pipe passen. Genau dafür wird stderr
    //    NEBENLÄUFIG geleert: Eine volle Pipe (rund 64 KiB) hält den Kern
    //    an, während die App auf seine Treffer wartet — beide Seiten
    //    stünden. Und gezählt werden muss beim Durchlaufen, sonst wäre
    //    die Zahl auf das gedeckelte Textstück beschränkt.
    let many = 900
    for index in 0..<many {
        let name = String(format: "pipe%04d.txt", index)
        _ = mkfifo(noisy.appendingPathComponent(name).path, 0o600)
    }
    let flooded = runSearchStreaming(
        arguments: [cli, "--json", "--content", "FAVENIO_PROBE",
                    "--", noisy.path],
        onProgress: { _ in })
    guard !searchExitIsError(flooded.status, reason: flooded.reason) else {
        return "Lauf mit vielen Warnungen galt als Fehlschlag"
    }
    guard flooded.warningCount == many + 1 else {
        return "Warnungen jenseits der Pipe-Größe nicht vollständig gezählt "
            + "(\(flooded.warningCount) statt \(many + 1))"
    }
    guard skippedNote(1).contains("1 Warnung"), skippedNote(0).isEmpty,
          skippedNote(3).contains("3 Warnungen") else {
        return "Fußzeilen-Zusatz für übersprungene Objekte stimmt nicht"
    }
    return nil
}

private func checkSizeOnlyHandoff(sandbox: URL) -> String? {
    // Den URL-Einstieg auslassen: Er aktiviert die Haupt-App auch im Test.
    let link = "favenio://results-v2?regex=0&case=0&mode=content&minw=1000&maxh=900"
    guard let items = URLComponents(string: link)?.queryItems else {
        return "URL-Optionen für die Maßsuche fehlen"
    }
    let host = MainController()
    host.buildWindow()
    defer { host.stopSearch(); host.window.orderOut(nil) }
    host.regexCheckbox.state = .on
    host.caseCheckbox.state = .on
    host.applyConfiguration(SearchConfiguration.fromQueryItems(items))
    guard host.regexCheckbox.state == .off, host.caseCheckbox.state == .off,
          host.pixelFields.map(\.stringValue) == ["1000", "", "", "900"] else {
        return "Quick-Optionen setzen Regex, Groß/Klein oder Bildmaße falsch"
    }

    host.continueSearch(payload: QuickHandoffPayload(version: 2, roots: [sandbox.path]))
    guard host.activeSearchRun != nil, host.searchField.stringValue.isEmpty else {
        return "Eine übergebene reine Maßsuche startet nicht"
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 8
    while host.activeSearchRun != nil && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    guard host.activeSearchRun == nil, host.hits.count == 1,
          host.hits.first?.displayName == "probe.png",
          host.hits.first?.dimensionsText == "1200×800" else {
        return "Fortsetzung der Maßsuche liefert falsche Treffer: \(host.statusLabel.stringValue)"
    }
    print("MAIN SIZE HANDOFF OK: explicit false switches and continued size-only search")
    return nil
}

private func runMainSelfTest(sandbox tmp: URL, forcedDateFailure: String?) -> Int32 {
    defer { cleanupMaterializedHits() }
    _ = NSApplication.shared
    do {
        try CriteriaEditorSelfTest.run()
    } catch {
        print("SELFTEST FEHLER: Kriterieneditor: \(error)")
        return 1
    }
    let pixelController = MainController()
    if let error = pixelFieldSelfTest(pixelController.pixelFields,
                                     validate: pixelController.validatePixelInputs) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }

    let collapsedController = MainController()
    collapsedController.buildWindow()   // sonst erst in applicationDidFinishLaunching
    collapsedController.window.orderOut(nil)
    let modeHelp = collapsedController.modeControl.toolTip?.components(separatedBy: "\n") ?? []
    guard modeHelp.count == 3, modeHelp[1].contains("DOCX"), modeHelp[1].contains("XLSX"),
          modeHelp[2].contains("OCR"), modeHelp[2].contains("PPTX") else {
        print("SELFTEST FEHLER: Der Suchziel-Tooltip nennt Dokumentformate und OCR-Optionen nicht getrennt")
        return 1
    }
    let coreFields = metadataFieldList()
    let metadataPopup = collapsedController.fieldPopup
    let popupTitles = metadataPopup.itemArray.filter { !$0.isSeparatorItem }.map(\.title)
    guard coreFields.contains("Keywords"), coreFields.contains("Title"),
          popupTitles.first == "Alle Textfelder",
          Array(popupTitles.dropFirst()) == coreFields else {
        print("SELFTEST FEHLER: Die Metadaten-Feldauswahl zeigt nicht die Liste des Suchkerns")
        return 1
    }
    let modePopup = collapsedController.modeControl
    modePopup.selectItem(withTitle: "Metadaten")
    guard let modeAction = modePopup.action,
          NSApp.sendAction(modeAction, to: modePopup.target, from: modePopup),
          !metadataPopup.isHidden, collapsedController.selectedMetadataField == nil else {
        print("SELFTEST FEHLER: Der Metadatenmodus zeigt die Feldauswahl nicht")
        return 1
    }
    metadataPopup.selectItem(withTitle: "Title")
    guard collapsedController.searchConfiguration.metadataField == "Title" else {
        print("SELFTEST FEHLER: Die Suche übernimmt das gewählte Metadatenfeld nicht")
        return 1
    }
    print("MAIN METADATA FIELDS OK: native menu, mode and selected field")
    if let error = contentPreviewDisclosureSelfTest(collapsedController) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    // Zugeklappt beim Start, Umschalten, Zählung im Titel und Maßfelder ohne
    // Suche beim Fokusverlust — gemeinsam mit der Schnellsuche geprüft.
    if let error = filterDisclosureSelfTest(collapsedController.filters) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }
    // Return startet die Suche — nicht das Tippen. Ohne diese beiden Werte
    // schickt NSSearchField die Action nach jeder Tipppause von selbst.
    guard collapsedController.searchField.sendsWholeSearchString,
          !collapsedController.searchField.sendsSearchStringImmediately else {
        print("SELFTEST FEHLER: Das Suchfeld startet die Suche beim Tippen")
        return 1
    }
    guard collapsedController.filterView.exclusionsEditor.placeholder.contains("node_modules") else {
        print("SELFTEST FEHLER: Ausschlussfeld hat keinen Beispiel-Platzhalter")
        return 1
    }
    collapsedController.window.close()
    favenioPreferences.set(true, forKey: "finderColumn.finderTags")
    let restoredFinderColumns = MainController()
    restoredFinderColumns.buildWindow()
    restoredFinderColumns.window.orderOut(nil)
    guard restoredFinderColumns.finderColumnsVisible,
          restoredFinderColumns.searchConfiguration.finderMetadata else {
        print("SELFTEST FEHLER: Wiederhergestellte Finder-Spalten: visible=\(restoredFinderColumns.finderColumnsVisible), capture=\(restoredFinderColumns.searchConfiguration.finderMetadata), saved=\(favenioPreferences.bool(forKey: "finderColumn.finderTags"))")
        return 1
    }
    favenioPreferences.removeObject(forKey: "finderColumn.finderTags")

    pixelController.filterView.exclusions = ["node_modules", " keep spaces "]
    pixelController.filterView.rawFacts = ["min-size": "0"]
    guard pixelController.searchConfiguration.hasPositiveFilter,
          pixelController.searchConfiguration.arguments(pattern: "", root: "/fixture") != nil else {
        print("SELFTEST FEHLER: Reine Faktenfilter starten keine Suche")
        return 1
    }
    guard pixelController.searchConfiguration.exclusions == ["node_modules", " keep spaces "],
          SearchConfiguration.fromQueryItems(pixelController.searchConfiguration.queryItems)
            == pixelController.searchConfiguration else {
        print("SELFTEST FEHLER: Ausschlussoptionen gehen zwischen Controls und Übergabe verloren")
        return 1
    }
    // Benannte Suchvorlagen: Datei-Roundtrip, Laden ohne Suchstart,
    // Rohtexte, fehlender Ordner, Umbenennen, Löschen, Formatmigration.
    let templateFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("favenio-selftest-templates-\(ProcessInfo.processInfo.processIdentifier).json")
    defer { try? FileManager.default.removeItem(at: templateFile) }
    let saver = MainController()
    saver.templateStore = SearchTemplateStore(fileURL: templateFile)
    saver.searchField.stringValue = "Rechnung*"
    saver.regexCheckbox.state = .on
    saver.filterView.literalWildcards = true
    saver.minWidthField.stringValue = "1.000 px"
    saver.filterView.exclusions = ["node_modules", " keep spaces "]
    saver.filterView.rawFacts = ["min-size": "1 KiB"]
    let existingRoot = FileManager.default.temporaryDirectory.path
    let validTemplate = SearchTemplate(
        name: "Rechnungen", pattern: "Rechnung*", root: existingRoot,
        configuration: saver.searchConfiguration)
    var rawConfiguration = saver.searchConfiguration
    rawConfiguration.pixelTexts = ["10.5", "", "", ""]      // ungültig, bleibt roh
    rawConfiguration.mode = .metadata
    rawConfiguration.metadataField = "Title"
    let rawTemplate = SearchTemplate(
        name: "Roh", pattern: "", root: "/nicht/vorhanden/favenio-selftest",
        configuration: rawConfiguration)
    guard saver.storeTemplate(validTemplate) == nil,
          saver.storeTemplate(rawTemplate) == nil,
          saver.templates.count == 2,
          (try? SearchTemplateStore(fileURL: templateFile).load()) == saver.templates,
          saver.templatesMenu.items.contains(where: { $0.title == "Rechnungen" }) else {
        print("SELFTEST FEHLER: Suchvorlagen überleben die Datei nicht")
        return 1
    }
    let loader = MainController()
    loader.templateStore = SearchTemplateStore(fileURL: templateFile)
    loader.reloadTemplates()
    guard loader.templates == saver.templates else {
        print("SELFTEST FEHLER: Vorlagendatei liest sich anders als geschrieben")
        return 1
    }
    loader.applyTemplate(validTemplate)
    guard loader.activeSearchRun == nil,
          loader.searchField.stringValue == "Rechnung*",
          loader.searchRoot.path == existingRoot,
          loader.searchConfiguration == validTemplate.configuration,
          loader.filters.isExpanded,
          loader.statusLabel.stringValue.contains("„Rechnungen“ geladen") else {
        print("SELFTEST FEHLER: Vorlage befüllt die Oberfläche nicht oder startet eine Suche")
        return 1
    }
    // Ein geladenes Regex-Muster steht GEFÄRBT im Feld: applyConfiguration
    // färbt zuletzt, aber noch den alten Text. Ein erneutes Färben darf
    // deshalb nichts mehr ändern.
    var regexConfiguration = SearchConfiguration()
    regexConfiguration.regex = true
    let bufferedHit = Hit(path: "/fixture/still-visible.txt", kind: "file", line: nil, size: nil,
                          filesystemPath: "/fixture/still-visible.txt", archiveMembers: [], isDirectory: false)
    let pausedSearch = SearchRunner()
    loader.activeSearchRun = pausedSearch
    loader.pending = [bufferedHit]
    loader.applyTemplate(SearchTemplate(name: "RegexVorlage",
                                        pattern: "^(a|b)+$", root: nil,
                                        configuration: regexConfiguration))
    let colored = loader.searchField.attributedStringValue
    var patternColors: Set<NSColor> = []
    colored.enumerateAttribute(
        .foregroundColor,
        in: NSRange(location: 0, length: colored.length)
    ) { value, _, _ in
        if let color = value as? NSColor { patternColors.insert(color) }
    }
    // Anker, Gruppe und Alternative bekommen verschiedene Farben; ein
    // ungefärbtes Feld trägt höchstens eine.
    guard loader.searchField.stringValue == "^(a|b)+$", patternColors.count > 1,
          loader.activeSearchRun == nil, pausedSearch.isCancelled,
          loader.pending.isEmpty, loader.hits.contains(bufferedHit) else {
        print("SELFTEST FEHLER: Vorlage färbt das Muster nicht oder verliert bereits empfangene Treffer")
        return 1
    }
    loader.applyTemplate(validTemplate)
    // Geladene Vorlage, CLI-Argumente und Quick-Übergabe: dieselbe Suche.
    guard loader.searchConfiguration.arguments(
              pattern: loader.searchField.stringValue, root: loader.searchRoot.path)
              == validTemplate.configuration.arguments(
                  pattern: validTemplate.pattern, root: existingRoot),
          SearchConfiguration.fromQueryItems(loader.searchConfiguration.queryItems)
              == validTemplate.configuration,
          (try? SearchTemplateFormat.decodeOptions(
              SearchTemplateFormat.encodeOptions(validTemplate.configuration)))
              == validTemplate.configuration else {
        print("SELFTEST FEHLER: Vorlage, CLI-Argumente und URL beschreiben verschiedene Suchen")
        return 1
    }
    loader.applyTemplate(rawTemplate)
    guard loader.minWidthField.stringValue == "10.5",
          loader.selectedMode == .metadata,
          loader.selectedMetadataField == nil || loader.selectedMetadataField == "Title",
          loader.searchRoot.path == rawTemplate.root,
          loader.statusLabel.stringValue.contains("fehlt: /nicht/vorhanden/favenio-selftest") else {
        print("SELFTEST FEHLER: Rohtext oder fehlender Vorlagenordner werden nicht sichtbar")
        return 1
    }
    guard loader.renameTemplate("Rechnungen", to: "Roh") != nil,
          loader.renameTemplate("Rechnungen", to: "  ") != nil,
          loader.renameTemplate("Rechnungen", to: "Rechnungen 2026") == nil,
          loader.deleteTemplate("Roh") == nil,
          loader.templates.map({ $0.name }) == ["Rechnungen 2026"],
          (try? SearchTemplateStore(fileURL: templateFile).load())?.map({ $0.name })
              == ["Rechnungen 2026"] else {
        print("SELFTEST FEHLER: Umbenennen oder Löschen einer Vorlage")
        return 1
    }
    let futureTemplateVersion = SearchTemplateFormat.version + 1
    try? Data("{\"version\": \(futureTemplateVersion), \"templates\": []}".utf8).write(to: templateFile)
    var migrationError = ""
    do { _ = try SearchTemplateStore(fileURL: templateFile).load() } catch { migrationError = "\(error)" }
    guard migrationError.contains("Formatversion \(futureTemplateVersion)") else {
        print("SELFTEST FEHLER: Neuere Vorlagendatei wird nicht abgelehnt: \(migrationError)")
        return 1
    }
    // Solange die Datei nicht lesbar ist, wird NICHT gesichert: Sonst
    // ersetzte die eine sichtbare Vorlage alle Vorlagen der neueren Fassung.
    loader.reloadTemplates()
    let versionTwo = FileManager.default.contents(atPath: templateFile.path)
    guard loader.templateLoadError != nil, loader.templates.isEmpty,
          loader.storeTemplate(validTemplate) != nil,
          loader.renameTemplate("x", to: "y") != nil,
          FileManager.default.contents(atPath: templateFile.path) == versionTwo,
          loader.statusLabel.stringValue.contains("nicht gesichert") else {
        print("SELFTEST FEHLER: Sichern bei unlesbarer Vorlagendatei überschreibt sie")
        return 1
    }
    // Ein Handedit mit Leerzeichen oder Umlaut in den Optionen darf die
    // App nicht beenden (percentEncodedQuery brach mit Fatal error ab);
    // nur ein „#" schnitte still ab und ist deshalb ein genannter Fehler.
    try? Data("{\"version\": 1, \"templates\": [{\"name\": \"Hand\", \"options\": \"mode=content&exclude=a b&term=ä\"}]}".utf8)
        .write(to: templateFile)
    guard let handEdited = try? SearchTemplateStore(fileURL: templateFile).load(),
          handEdited.first?.configuration.mode == .content,
          handEdited.first?.configuration.exclusions == ["a b"],
          handEdited.first?.configuration.terms == ["ä"] else {
        print("SELFTEST FEHLER: Handbearbeitete Vorlagenoptionen werden nicht gelesen")
        return 1
    }
    try? Data("{\"version\": 1, \"templates\": [{\"name\": \"Raute\", \"options\": \"mode=name#exclude=x\"}]}".utf8)
        .write(to: templateFile)
    var fragmentError = ""
    do { _ = try SearchTemplateStore(fileURL: templateFile).load() } catch { fragmentError = "\(error)" }
    // Fehlendes Komma — ein Komma zu viel nähme Apples Parser stillschweigend an.
    try? Data("{\"version\": 1 \"templates\": []}".utf8).write(to: templateFile)
    var syntaxError = ""
    do { _ = try SearchTemplateStore(fileURL: templateFile).load() } catch { syntaxError = "\(error)" }
    guard fragmentError.contains("Vorlage 1"), fragmentError.contains("#"),
          syntaxError.contains("kein gültiges JSON: "),
          syntaxError.count > "Vorlagendatei ist kein gültiges JSON: ".count else {
        print("SELFTEST FEHLER: Vorlagenfehler ohne Grund: \(fragmentError) / \(syntaxError)")
        return 1
    }
    try? Data("{\"version\": 1, \"später\": true, \"templates\": [{\"name\": \"Alt\", \"extra\": 1}]}".utf8)
        .write(to: templateFile)
    guard (try? SearchTemplateStore(fileURL: templateFile).load())
              == [SearchTemplate(name: "Alt", pattern: "", root: nil,
                                 configuration: SearchConfiguration())] else {
        print("SELFTEST FEHLER: Unbekannte Felder derselben Formatversion werden nicht überlesen")
        return 1
    }
    loader.reloadTemplates()
    guard loader.templates.count == 1, loader.templateLoadError == nil,
          case .idle = loader.searchPhase,
          !regexTemplates.isEmpty else {
        print("SELFTEST FEHLER: Vorlagen neu laden oder Regex-Einfügehilfe")
        return 1
    }
    // Das Fenster „Vorlagen verwalten": Die Tabelle füllt ihre Zeilen über
    // die echten NSTableViewDelegate-Methoden. Bis 0.34.0 hießen sie
    // `templateTable(_:viewFor:row:)` — AppKit rief sie nie, jede Zeile
    // blieb leer, und die Knöpfe wurden bei einer Auswahl nicht aktiv.
    let manager = SearchTemplateManager(owner: loader)
    guard manager.templateTable.numberOfRows == 1,
          (manager.templateTable.view(atColumn: 0, row: 0, makeIfNecessary: true)
              as? NSTextField)?.stringValue == "Alt",
          !manager.loadButton.isEnabled, !manager.deleteButton.isEnabled else {
        print("SELFTEST FEHLER: Vorlagenfenster zeigt die Vorlagen nicht")
        return 1
    }
    manager.templateTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    guard manager.selectedTemplate?.name == "Alt",
          manager.loadButton.isEnabled, manager.renameButton.isEnabled,
          manager.deleteButton.isEnabled,
          manager.summaryLabel.stringValue == loader.templateSummary(loader.templates[0]) else {
        print("SELFTEST FEHLER: Auswahl im Vorlagenfenster schaltet die Knöpfe nicht frei")
        return 1
    }
    // Ein leerer Name darf weder schreiben noch nach erfolgreichem Retry
    // als Fehler stehen bleiben. Derselbe Pfad läuft nach dem Namensdialog.
    let beforeEmptyName = try? Data(contentsOf: templateFile)
    var emptyNameTemplate = validTemplate
    emptyNameTemplate.name = "  "
    guard loader.storeTemplate(emptyNameTemplate) != nil,
          loader.statusLabel.stringValue.contains("kein Name"),
          (try? Data(contentsOf: templateFile)) == beforeEmptyName,
          loader.storeTemplate(validTemplate) == nil,
          !loader.statusLabel.stringValue.contains("kein Name"),
          loader.statusLabel.stringValue.contains("gesichert"),
          loader.templateFailure == nil else {
        print("SELFTEST FEHLER: Leerer Vorlagenname bleibt nach erfolgreichem Sichern als Fehler stehen")
        return 1
    }
    // Ein Sichern nimmt nur den EIGENEN Fehler zurück, nicht den der Suche.
    loader.searchPhase = .failed("Kernfehler der letzten Suche")
    guard loader.storeTemplate(validTemplate) == nil,
          loader.statusLabel.stringValue.contains("Kernfehler der letzten Suche") else {
        print("SELFTEST FEHLER: Vorlage sichern löscht den Fehler der letzten Suche")
        return 1
    }
    // Derselbe Ablauf MIT einem abgelehnten Namen dazwischen: Suchfehler →
    // leerer Name → gültiger Name. Bis 0.34.8 überschrieb der Vorlagenfehler
    // den Suchfehler, und das erfolgreiche Sichern setzte den Zustand auf
    // `.idle` — der Suchfehler war danach endgültig weg.
    guard loader.storeTemplate(emptyNameTemplate) != nil,
          loader.statusLabel.stringValue.contains("kein Name"),
          loader.statusLabel.stringValue.contains("Kernfehler der letzten Suche"),
          loader.storeTemplate(validTemplate) == nil,
          !loader.statusLabel.stringValue.contains("kein Name"),
          loader.statusLabel.stringValue.contains("Kernfehler der letzten Suche"),
          loader.templateFailure == nil,
          case .failed(let keptReason) = loader.searchPhase,
          keptReason == "Kernfehler der letzten Suche" else {
        print("SELFTEST FEHLER: Abgelehnter Vorlagenname löscht den Fehler der letzten Suche")
        return 1
    }
    // Und derselbe Ablauf während einer laufenden Suche: Die Laufanzeige
    // gehört dem Runner, nicht der Vorlagenaktion.
    loader.searchPhase = .running
    loader.progressPath = "/laufende-suche-favenio-selftest"
    loader.refreshStatus()
    guard loader.storeTemplate(emptyNameTemplate) != nil,
          loader.statusLabel.stringValue.contains("kein Name"),
          loader.statusLabel.stringValue.contains("/laufende-suche-favenio-selftest"),
          loader.storeTemplate(validTemplate) == nil,
          loader.templateFailure == nil,
          case .running = loader.searchPhase,
          !loader.statusLabel.stringValue.contains("kein Name"),
          loader.statusLabel.stringValue.contains("/laufende-suche-favenio-selftest") else {
        print("SELFTEST FEHLER: Abgelehnter Vorlagenname verdrängt die laufende Suche")
        return 1
    }
    loader.searchPhase = .idle
    loader.progressPath = nil

    let recordedController = MainController()
    recordedController.searchPhase = .recorded("completed")
    recordedController.previewRequest = MaterializationSelectionRequest()
    recordedController.refreshStatus()
    guard recordedController.statusLabel.stringValue.contains("Aufgezeichneter Stand"),
          recordedController.statusLabel.stringValue.contains(MainController.materializingNote) else {
        print("SELFTEST FEHLER: Aufgezeichneter Stand verbirgt laufendes Auspacken und Abbruchhinweis")
        return 1
    }
    recordedController.cancelMaterializations(reportCancellation: false)
    guard !recordedController.statusLabel.stringValue.contains(MainController.materializingNote) else {
        print("SELFTEST FEHLER: Aufgezeichneter Stand behält beendeten Auspackhinweis")
        return 1
    }

    for continuing in [false, true] {
        let rejected = MainController()
        let stale = SearchRunner()
        rejected.activeSearchRun = stale
        let oldHit = Hit(path: "/fixture/old.txt", kind: "file", line: nil, size: nil,
                         filesystemPath: "/fixture/old.txt", archiveMembers: [], isDirectory: false)
        rejected.hits = [oldHit]
        rejected.pending = [oldHit]
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(
            quickHandoffPrefix + UUID().uuidString + quickHandoffSuffix)
        try? Data("kein JSON\n".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        if continuing { rejected.continueSearch(from: invalid) }
        else { rejected.loadResults(from: invalid) }
        rejected.finishSearchRun(stale, exit: SearchExit(status: 0, reason: .exit))
        guard rejected.activeSearchRun == nil, stale.isCancelled,
              rejected.hits.isEmpty, rejected.pending.isEmpty,
              rejected.statusLabel.stringValue.contains("Ungültige oder zu große Ergebnisübergabe"),
              rejected.searchControl.run?.state == "failed" else {
            print("SELFTEST FEHLER: Abgewiesene Quick-Übergabe lässt den alten Suchlauf weiterlaufen")
            return 1
        }
    }

    // Mehrwortsuche: Begriffe aus der Filteransicht erreichen Argumente,
    // URL und Vorlage; ohne Muster tragen sie die Suche; Belege im Treffer.
    let termsController = MainController()
    termsController.filterView.terms = ["beta", " mit Leerraum "]
    guard termsController.searchConfiguration.terms == ["beta", " mit Leerraum "],
          termsController.searchConfiguration.hasPositiveFilter,
          let termArguments = termsController.searchConfiguration.arguments(
              pattern: "alpha", root: "/fixture"),
          termArguments.contains("--term=beta"),
          termArguments.contains("--term= mit Leerraum "),
          termsController.searchConfiguration.arguments(pattern: "", root: "/fixture")?
              .contains("--term=beta") == true,
          SearchConfiguration.fromQueryItems(termsController.searchConfiguration.queryItems)
              == termsController.searchConfiguration else {
        print("SELFTEST FEHLER: Weitere Suchbegriffe erreichen Argumente oder URL nicht")
        return 1
    }
    termsController.applyConfiguration(SearchConfiguration.fromQueryItems(
        [URLQueryItem(name: "term", value: "gamma")]))
    guard termsController.filterView.terms == ["gamma"],
          termsController.filters.isExpanded else {
        print("SELFTEST FEHLER: Übergebene Suchbegriffe füllen die Filteransicht nicht")
        return 1
    }
    let termHitLine = Data(#"{"path":"/x/a.txt","type":"file","isDirectory":false,"filesystemPath":"/x/a.txt","archiveMembers":[],"line":1,"terms":[{"term":"alpha","line":1},{"term":"beta","line":3}]}"#.utf8)
    guard let termHit = parseHit(termHitLine),
          termHit.terms.map({ $0.line }) == [1, 3],
          termHit.locationText == "1, 3",
          parseHit(jsonlData(for: [termHit]).prefix(while: { $0 != 0x0A })) == termHit else {
        print("SELFTEST FEHLER: Belege der Mehrwortsuche gehen beim Lesen oder Schreiben verloren")
        return 1
    }

    pixelController.searchField.stringValue = "Treffer"
    pixelController.minWidthField.stringValue = "10.5"
    pixelController.startSearch()
    guard pixelController.activeSearchRun == nil,
          pixelController.minWidthField.toolTip != nil else {
        print("SELFTEST FEHLER: Ungültige Maße starten die Hauptsuche")
        return 1
    }
    pixelController.minWidthField.stringValue = "1000"
    pixelController.controlTextDidChange(Notification(
        name: NSControl.textDidChangeNotification,
        object: pixelController.minWidthField))
    guard case .idle = pixelController.searchPhase,
          pixelController.minWidthField.toolTip == nil else {
        print("SELFTEST FEHLER: Korrigierter Maßfehler bleibt sichtbar")
        return 1
    }
    pixelController.exportStatus = "Export läuft"
    pixelController.searchPhase = .running
    pixelController.progressPath = "/new-search"
    pixelController.refreshStatus()
    guard pixelController.statusLabel.stringValue.contains("/new-search"),
          pixelController.statusLabel.stringValue.contains("Export läuft") else {
        print("SELFTEST FEHLER: Exportstatus verdrängt eine neue Suche")
        return 1
    }
    pixelController.searchPhase = .failed("Neuer Suchfehler")
    pixelController.exportStatus = "Export fertig"
    pixelController.refreshStatus()
    guard pixelController.statusLabel.stringValue.contains("Neuer Suchfehler"),
          pixelController.statusLabel.stringValue.contains("Export fertig") else {
        print("SELFTEST FEHLER: Exportabschluss verdrängt neuen Suchfehler")
        return 1
    }
    // Der nächste Suchstart nimmt den Exporttext aus der Fußzeile — er
    // hing sonst die ganze Sitzung hinter jedem Suchstatus. Und ein
    // verschwundener Suchordner ist ein genannter Fehler, keine stille
    // Suche über `/` (der Kern las den Pfad sonst als Namensmuster).
    let rootController = MainController()
    rootController.exportStatus = "Export fertig"
    rootController.setSearchRoot(URL(fileURLWithPath: "/nicht/vorhanden/favenio-selftest"))
    rootController.launchSearch(pattern: "x")
    guard rootController.activeSearchRun == nil, rootController.exportStatus == nil,
          rootController.statusLabel.stringValue.contains("Suchbereich fehlt"),
          rootController.statusLabel.stringValue.contains("/nicht/vorhanden/favenio-selftest") else {
        print("SELFTEST FEHLER: Fehlender Suchordner oder alter Exportstatus: "
              + rootController.statusLabel.stringValue)
        return 1
    }
    guard findCLI() != nil else {
        print("SELFTEST FEHLER: favenio.py nicht gefunden")
        return 1
    }
    guard !searchExitIsError(0, reason: .exit),
          !searchExitIsError(1, reason: .exit),
          searchExitIsError(2, reason: .exit),
          searchExitIsError(1, reason: .uncaughtSignal) else {
        print("SELFTEST FEHLER: Such-Exit-Codes falsch eingeordnet")
        return 1
    }
    // Nicht nur eine nachgebaute Enum-Konstellation prüfen: Foundation muss
    // einen wirklich per SIGHUP beendeten Prozess als Signalabbruch melden.
    let signalProbe = Process()
    signalProbe.executableURL = URL(fileURLWithPath: "/bin/sh")
    signalProbe.arguments = ["-c", "kill -HUP $$"]
    do { try signalProbe.run() } catch {
        print("SELFTEST FEHLER: Signalprobe nicht startbar")
        return 1
    }
    signalProbe.waitUntilExit()
    guard signalProbe.terminationReason == .uncaughtSignal,
          searchExitIsError(signalProbe.terminationStatus,
                            reason: signalProbe.terminationReason) else {
        print("SELFTEST FEHLER: echter Signalabbruch nicht erkannt")
        return 1
    }
    // Eigene kleine Test-Welt in einem Temp-Ordner bauen.
    try? FileManager.default.createDirectory(at: tmp,
                                             withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let plain = tmp.appendingPathComponent("probe.txt")
    try? "FAVENIO_PROBE flach\n".write(to: plain, atomically: true,
                                       encoding: .utf8)
    // Zip-Fixture über Python bauen (kein zip-CLI nötig).
    let zipBuilder = Process()
    zipBuilder.executableURL = URL(fileURLWithPath: pythonPath)
    zipBuilder.arguments = ["-c",
        "import zipfile,sys\n" +
        "z = zipfile.ZipFile(sys.argv[1], 'w')\n" +
        "z.writestr('inner/geheim.txt', 'FAVENIO_PROBE im Zip')\n" +
        "z.close()\n" +
        // Ein echtes 1200×800-PNG für die Maßsuche (nur zlib, kein Pillow).
        "import struct, zlib\n" +
        "def chunk(kind, payload):\n" +
        "    return (struct.pack('>I', len(payload)) + kind + payload\n" +
        "            + struct.pack('>I', zlib.crc32(kind + payload)))\n" +
        "raw = b''.join(b'\\x00' + b'\\x10\\x20\\x30' * 1200 " +
        "for _ in range(800))\n" +
        "png = (b'\\x89PNG\\r\\n\\x1a\\n'\n" +
        "       + chunk(b'IHDR', struct.pack('>IIBBBBB', 1200, 800, " +
        "8, 2, 0, 0, 0))\n" +
        "       + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))\n" +
        "open(sys.argv[2], 'wb').write(png)",
        tmp.appendingPathComponent("probe.zip").path,
        tmp.appendingPathComponent("probe.png").path]
    try? zipBuilder.run()
    zipBuilder.waitUntilExit()

    var probeConfiguration = SearchConfiguration()
    probeConfiguration.mode = .content
    probeConfiguration.caseSensitive = true
    probeConfiguration.archives = true
    guard let args = probeConfiguration.arguments(pattern: "FAVENIO_PROBE",
                                                  root: tmp.path) else { return 1 }
    let hits = runSearchSync(arguments: args)
    guard hits.count == 2 else {
        print("SELFTEST FEHLER: \(hits.count) Treffer statt 2")
        return 1
    }
    // ---- Maßsuche: ohne Muster, nur „mindestens 1000 px breit" ----
    guard parsePixelLimit("1.000 px") == 1000, parsePixelLimit("") == nil,
          parsePixelLimit("abc") == nil, parsePixelLimit("0") == nil,
          // Eine unbrauchbare Eingabe darf keine Grenze setzen: „-1" ergab
          // früher 1 und „10.5" ergab 105, weil nur die Ziffern übrig
          // blieben (Review-Fund 2026-09-02).
          parsePixelLimit("-1") == nil, parsePixelLimit("10.5") == nil,
          parsePixelLimit("1 000") == 1000, parsePixelLimit("12") == 12 else {
        print("SELFTEST FEHLER: Pixelfeld wird falsch gelesen")
        return 1
    }
    // Ein präparierter Bildkopf darf die Flächensortierung nicht über
    // Int.max laufen lassen — das beendete den Prozess.
    let riesig = Hit(path: "/tmp/a/kaputt.png", kind: "file", line: nil,
                     size: nil, filesystemPath: "/tmp/a/kaputt.png",
                     archiveMembers: [], isDirectory: false, field: nil,
                     value: nil, width: Int.max, height: Int.max)
    guard riesig.pixelArea == Int.max,
          compareHits(riesig, riesig, key: "dims", ascending: true) == false
    else {
        print("SELFTEST FEHLER: Flächenvergleich läuft über")
        return 1
    }
    let limits = PixelLimits(minWidth: 1000, maxHeight: 900)
    var sizeConfiguration = SearchConfiguration()
    sizeConfiguration.archives = true
    sizeConfiguration.pixelTexts = ["1000", "", "", "900"]
    guard limits.arguments == ["--min-width", "1000", "--max-height", "900"],
          limits.summary == "B ≥ 1000, H ≤ 900",
          let sizeArgs = sizeConfiguration.arguments(pattern: "", root: tmp.path),
          sizeArgs.contains("--min-width"),
          // Ohne Muster kein synthetisches „*": Der Kern läuft dann ganz
          // ohne Textkriterium (Review-Fund 2026-09-02).
          !sizeArgs.contains("*") else {
        print("SELFTEST FEHLER: Maßfilter werden nicht an den Kern gereicht")
        return 1
    }
    // --content/--metadata brauchen ein Muster; ohne eines lehnt der Kern
    // sie ab und die reine Maßsuche wäre nicht mehr startbar.
    var sizeOnlyConfiguration = sizeConfiguration
    sizeOnlyConfiguration.mode = .content
    sizeOnlyConfiguration.metadataField = "Title"
    var emptyConfiguration = SearchConfiguration()
    emptyConfiguration.archives = true
    guard let sizeOnlyArgs = sizeOnlyConfiguration.arguments(pattern: "", root: tmp.path),
          !sizeOnlyArgs.contains("--content"),
          !sizeOnlyArgs.contains("--metadata-field"),
          emptyConfiguration.arguments(pattern: "", root: tmp.path) == nil else {
        print("SELFTEST FEHLER: Textmodus ohne Muster wird mitgeschickt")
        return 1
    }
    let sized = runSearchSync(arguments: sizeArgs)
    guard sized.count == 1, sized[0].width == 1200, sized[0].height == 800,
          sized[0].dimensionsText == "1200×800",
          sized[0].displayName == "probe.png" else {
        print("SELFTEST FEHLER: Maßsuche findet das 1200×800-PNG nicht "
              + "(\(sized.count) Treffer)")
        return 1
    }
    if let failure = checkSizeOnlyHandoff(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    var metaConfiguration = SearchConfiguration()
    metaConfiguration.mode = .metadata
    metaConfiguration.metadataField = "Title"
    metaConfiguration.archives = true
    guard let metaArgs = metaConfiguration.arguments(pattern: "Winter", root: tmp.path),
          metaArgs.contains("--metadata"),
          metaArgs.contains("--metadata-field") else {
        print("SELFTEST FEHLER: Metadatensuche wird nicht an den Kern gereicht")
        return 1
    }
    // Metadatentreffer überleben die JSONL-Runde in beide Richtungen.
    let metaHit = Hit(path: "/tmp/a/winter.jpg", kind: "file", line: nil,
                      size: 3, filesystemPath: "/tmp/a/winter.jpg",
                      archiveMembers: [], isDirectory: false,
                      field: "Keywords", value: "Winter", width: 4000,
                      height: 3000)
    guard let metaLine = jsonlData(for: [metaHit])
            .split(separator: 0x0A).first,
          parseHit(Data(metaLine)) == metaHit,
          metaHit.locationText == "Keywords: Winter" else {
        print("SELFTEST FEHLER: Metadatenfelder gehen in JSONL verloren")
        return 1
    }
    // Zeitstempel überleben die JSONL-Runde, und die Pfadspalte zeigt den
    // Ordner relativ zum Suchordner — ohne Dateinamen, mit dem Archiv in
    // `!/`-Notation, und bei einem Eintragsnamen mit `!/` aus der
    // Eintragsliste statt aus dem geschnittenen Anzeigepfad.
    let datedHit = Hit(path: "/tmp/a/b/c.txt", kind: "file", line: nil,
                       size: 1, filesystemPath: "/tmp/a/b/c.txt",
                       archiveMembers: [], isDirectory: false,
                       modified: 1_700_000_000.5, created: 1_600_000_000)
    guard let datedLine = jsonlData(for: [datedHit])
            .split(separator: 0x0A).first,
          parseHit(Data(datedLine)) == datedHit else {
        print("SELFTEST FEHLER: Zeitstempel gehen in JSONL verloren")
        return 1
    }
    let oddMember = Hit(path: "/tmp/a/p.zip!/odd!/name.txt", kind: "member",
                        line: nil, size: 1, filesystemPath: "/tmp/a/p.zip",
                        archiveMembers: ["odd!/name.txt"], isDirectory: false)
    let nested = Hit(path: "/tmp/a/o.zip!/i.zip!/x.txt", kind: "member",
                     line: nil, size: 1, filesystemPath: "/tmp/a/o.zip",
                     archiveMembers: ["i.zip", "x.txt"], isDirectory: false)
    let rootMember = Hit(path: "/tmp/a/p.zip!/top.txt", kind: "member",
                         line: nil, size: 1, filesystemPath: "/tmp/a/p.zip",
                         archiveMembers: ["top.txt"], isDirectory: false)
    guard datedHit.folderText(relativeTo: "/tmp/a") == "b",
          datedHit.folderText(relativeTo: "/tmp/a/") == "b",
          datedHit.folderText(relativeTo: "/tmp/a/b") == "",
          datedHit.folderText(relativeTo: "/") == "tmp/a/b",
          datedHit.folderText(relativeTo: "/tmp/ab") == "/tmp/a/b",
          datedHit.folderText(relativeTo: "/other") == "/tmp/a/b",
          oddMember.folderText(relativeTo: "/tmp/a") == "p.zip!/odd!",
          nested.folderText(relativeTo: "/tmp/a") == "o.zip!/i.zip",
          rootMember.folderText(relativeTo: "/tmp/a") == "p.zip" else {
        print("SELFTEST FEHLER: Pfadspalte zeigt den falschen Ordner")
        return 1
    }
    // Vier Datumsstufen in fester Zeitzone, und die Stufenwahl folgt der
    // Breite: breiter nie kürzer, und kein Muster passt in 0 pt.
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let stamp = 1_757_000_000.0     // 2025-09-04T15:33:20Z
    guard formatDateColumn(stamp, stage: 1, calendar: utc) == "04.09.25",
          formatDateColumn(stamp, stage: 2, calendar: utc)
              == "04.09.25, 15:33",
          formatDateColumn(stamp, stage: 3, calendar: utc)
              == "04.09.2025, 15:33",
          formatDateColumn(stamp, stage: 4, calendar: utc)
              == "4. September 2025 um 15:33",
          formatDateColumn(stamp, stage: 9, calendar: utc)
              == "4. September 2025 um 15:33",
          formatDateColumn(nil, stage: 3) == "",
          formatDateColumn(Double.nan, stage: 3) == "" else {
        print("SELFTEST FEHLER: Datumsstufen formatieren falsch")
        return 1
    }
    let dateFont = NSFont.monospacedDigitSystemFont(ofSize: 13,
                                                    weight: .regular)
    let sampleWidths = dateColumnSampleWidths(font: dateFont)
    guard sampleWidths.count == dateColumnStages,
          sampleWidths == sampleWidths.sorted(),
          dateColumnStage(forWidth: 0, font: dateFont) == 1,
          dateColumnStage(forWidth: sampleWidths[1], font: dateFont) == 2,
          dateColumnStage(forWidth: sampleWidths[3] + 100, font: dateFont)
              == dateColumnStages else {
        print("SELFTEST FEHLER: Datumsstufe folgt nicht der Spaltenbreite")
        return 1
    }
    guard let member = hits.first(where: { $0.isMember }) else {
        print("SELFTEST FEHLER: Archivtreffer für den Drag-Test fehlt")
        return 1
    }
    let archiveDrag = MainController()
    archiveDrag.buildWindow()
    defer { archiveDrag.window.orderOut(nil) }
    archiveDrag.replaceSearchResults([member])
    let table = archiveDrag.tableView
    let materializer = MaterializationManager.shared
    guard materializer.knownURL(for: member) == nil,
          let row = archiveDrag.tableRow(forHitIndex: 0),
          let promise = table.dataSource?.tableView?(table, pasteboardWriterForRow: row) as? NSFilePromiseProvider,
          promise.delegate === archiveDrag,
          (promise.userInfo as? Hit)?.identity == member.identity,
          archiveDrag.filePromiseProvider(promise, fileNameForType: promise.fileType) == "geheim.txt",
          materializer.knownURL(for: member) == nil else {
        print("SELFTEST FEHLER: Archivzeile liefert vor dem Auspacken kein passendes Dateiversprechen")
        return 1
    }
    print("MAIN ARCHIVE DRAG OK: table data source promises the unmaterialized member")

    guard let extracted = materializeHit(member),
          materializeHit(member) == extracted,
          let content = try? String(contentsOf: extracted, encoding: .utf8),
          content.contains("FAVENIO_PROBE")
    else {
        print("SELFTEST FEHLER: Archiv-Extraktion fehlgeschlagen")
        return 1
    }
    guard member.hasOpenableFile else {
        print("SELFTEST FEHLER: auspackbarer Archiv-Eintrag gilt als nicht "
              + "öffenbar")
        return 1
    }
    // Ein ORDNER im Archiv hat nichts zum Öffnen. hasOpenableFile ist die
    // Auskunft, an der die Kontextmenüs ihre Dateiaktionen ausgrauen — sie
    // muss deshalb genau dann nein sagen, wenn materializeHit() nil liefert.
    let archiveFolder = Hit(path: "/tmp/probe.zip!/inner", kind: "member",
                            line: nil, size: nil,
                            filesystemPath: "/tmp/probe.zip",
                            archiveMembers: ["inner"], isDirectory: true)
    guard !archiveFolder.hasOpenableFile,
          materializeHit(archiveFolder) == nil else {
        print("SELFTEST FEHLER: Ordner im Archiv gilt als öffenbare Datei")
        return 1
    }
    // Menü und Aktion müssen bei Mehrfachauswahl dieselbe Zeilenmenge sehen:
    // Rechtsklick in die Auswahl = alles; Rechtsklick daneben = nur diese Zeile.
    let selectedRows = IndexSet([0, 2])
    guard hitActionRows(selectedRows: selectedRows, contextRow: 0) == [0, 2],
          hitActionRows(selectedRows: selectedRows, contextRow: 1) == [1]
    else {
        print("SELFTEST FEHLER: Aktionszeilen widersprechen der Auswahl")
        return 1
    }
    let mixed = materializeHitSelection([member, archiveFolder], rows: [0, 1])
    guard mixed.urls.count == 1, mixed.unavailable == [archiveFolder],
          hitActionIssue(mixed)?.detail == archiveFolder.path else {
        print("SELFTEST FEHLER: gemischte Auswahl verschluckt Auslassungen")
        return 1
    }
    // Archivordner UND Auspackfehler zusammen: Beide Gruppen müssen in der
    // Meldung stehen. Vorher gewann der Ordner, und der echte Auspackfehler
    // eines weiteren Treffers blieb unsichtbar (Review-Fund 2026-08-21).
    let brokenMember = Hit(path: "/tmp/probe.zip!/kaputt.txt", kind: "member",
                           line: nil, size: nil,
                           filesystemPath: "/tmp/fehlt-nicht-vorhanden.zip",
                           archiveMembers: ["kaputt.txt"], isDirectory: false)
    guard brokenMember.hasOpenableFile, materializeHit(brokenMember) == nil else {
        print("SELFTEST FEHLER: beschädigtes Archivmitglied verhält sich falsch")
        return 1
    }
    let bothKinds = materializeHitSelection([archiveFolder, brokenMember],
                                            rows: [0, 1])
    guard let bothIssue = hitActionIssue(bothKinds),
          bothIssue.summary.contains("Ordner im Archiv"),
          bothIssue.summary.contains("auspacken") else {
        print("SELFTEST FEHLER: Meldung nennt nicht beide Gruppen")
        return 1
    }
    // Die Kopfzeile und vier grauen Dateiaktionen werden am echten NSMenu
    // geprüft. Damit kann ein Kommentar im Quelltext die Wache nicht erfüllen.
    let blockedMenu = NSMenu()
    blockedMenu.removeAllItems()
    populateHitContextMenu(
        blockedMenu, applicationHits: [], target: NSObject(),
        selectors: HitContextMenuSelectors(
            preview: NSSelectorFromString("preview"),
            open: NSSelectorFromString("open"),
            openWith: NSSelectorFromString("openWith:"),
            reveal: NSSelectorFromString("reveal"),
            copyPath: NSSelectorFromString("copyPath")))
    let blockedItems = Dictionary(uniqueKeysWithValues: blockedMenu.items
        .filter { !$0.title.isEmpty }.map { ($0.title, $0) })
    guard blockedMenu.items.first?.title.hasPrefix("Ordner im Archiv") == true,
          blockedItems["Vorschau (Leertaste)"]?.isEnabled == false,
          blockedItems["Öffnen"]?.isEnabled == false,
          blockedItems["Öffnen mit"]?.isEnabled == false,
          blockedItems["Öffnen mit"]?.submenu == nil,
          blockedItems["Im Finder zeigen"]?.isEnabled == false,
          blockedItems["Pfad kopieren"]?.isEnabled == true else {
        print("SELFTEST FEHLER: Kontextmenü für Archivordner ist inkonsistent")
        return 1
    }
    // Ein Ordner im DATEISYSTEM bleibt öffenbar — sein Pfad existiert.
    let plainFolder = Hit(path: tmp.path, kind: "dir", line: nil, size: nil,
                          filesystemPath: tmp.path, archiveMembers: [],
                          isDirectory: true)
    guard plainFolder.hasOpenableFile,
          materializeHit(plainFolder) != nil else {
        print("SELFTEST FEHLER: Ordner im Dateisystem gilt als nicht öffenbar")
        return 1
    }
    let tied = Hit(path: "/tmp/b/same.txt", kind: "file", line: 7,
                   size: 42, filesystemPath: "/tmp/b/same.txt",
                   archiveMembers: [], isDirectory: false)
    let tiedEarlier = Hit(path: "/tmp/a/same.txt", kind: "file", line: 7,
                          size: 42, filesystemPath: "/tmp/a/same.txt",
                          archiveMembers: [], isDirectory: false)
    for key in ["name", "type", "size", "line", "dims", "path"] {
        for ascending in [true, false] {
            guard !compareHits(tied, tied, key: key, ascending: ascending),
                  !(compareHits(tied, tiedEarlier, key: key,
                                ascending: ascending)
                    && compareHits(tiedEarlier, tied, key: key,
                                   ascending: ascending)) else {
                print("SELFTEST FEHLER: Sortierordnung für \(key)")
                return 1
            }
        }
    }
    do {
        let handoff = try writeQuickHandoff(hits)
        guard consumeQuickHandoff(handoff)?.count == hits.count,
              !FileManager.default.fileExists(atPath: handoff.path) else {
            print("SELFTEST FEHLER: Ergebnisübergabe nicht verbraucht")
            return 1
        }
    } catch {
        print("SELFTEST FEHLER: Ergebnisübergabe: \(error)")
        return 1
    }
    if let failure = checkResultListFeatures(realHits: hits, sandbox: tmp) ?? checkResultListMenus() {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkNativeMainSearch(sandbox: tmp) ?? checkDiagnosticsReachTheSurface(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkSearchControl(sandbox: tmp, hits: hits) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkRecordingComparison(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkEmptySearchStatus(sandbox: tmp) ?? checkResultFilterControl(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkDateRangesControl(sandbox: tmp) ?? forcedDateFailure {
        print("SELFTEST FEHLER: \(failure)")
        return 1
    }
    if let failure = checkPDFOCRControl(sandbox: tmp) { print("SELFTEST FEHLER: \(failure)"); return 1 }
    if let failure = checkPPTXOCRControl(sandbox: tmp) { print("SELFTEST FEHLER: \(failure)"); return 1 }
    if let failure = checkOCRControl(sandbox: tmp) {
        print("SELFTEST FEHLER: \(failure)"); return 1
    }
    if let failure = checkLocalContentControl(sandbox: tmp) {
        print("SELFTEST FEHLER: \(failure)"); return 1
    }
    if let failure = checkFinderMetadataControl(sandbox: tmp) {
        print("SELFTEST FEHLER: \(failure)"); return 1
    }
    if let failure = checkSearchRootsControl(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkResultGroupingControl(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkFastraHandoff(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    let grouped = MainController()
    grouped.tableView.dataSource = grouped
    grouped.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    if let failure = resultGroupingListSelfTest(grouped) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    let filtered = MainController()
    filtered.tableView.dataSource = filtered
    filtered.tableView.addTableColumn(NSTableColumn(identifier: .init("name")))
    if let failure = resultFilterListSelfTest(filtered, terminate: {
        filtered.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    return 0
}

/// Prüft die Werkzeuge, die auf der fertigen Trefferliste arbeiten:
/// Kennzahlen, Export, Auswahl fürs Löschen und den Papierkorb selbst.
/// Rückgabe: nil bei Erfolg, sonst der Grund.
func checkResultListFeatures(realHits: [Hit], sandbox: URL) -> String? {
    // Gleiche Anzeige, unterschiedliche Archivstruktur: Beide Treffer
    // müssen ankommen, einzeln auswählbar und einzeln entfernbar bleiben.
    let literal = Hit(path: "/fixture/a.zip!/inner.zip!/x.txt", kind: "member",
        line: nil, size: nil, filesystemPath: "/fixture/a.zip",
        archiveMembers: ["inner.zip!/x.txt"], isDirectory: false)
    let nested = Hit(path: literal.path, kind: "member", line: nil, size: nil,
        filesystemPath: literal.filesystemPath,
        archiveMembers: ["inner.zip", "x.txt"], isDirectory: false)
    let replacement = MainController()
    replacement.tableView.dataSource = replacement
    guard let original = realHits.first(where: { !$0.isMember }) else { return "Originaldatei fehlt im Test" }
    replacement.hits = [original, literal]
    guard replacement.externalDragOperations(for: [0]) == [.move, .copy],
          replacement.externalDragOperations(for: [1]) == .copy,
          replacement.externalDragOperations(for: [0, 1]) == .copy else {
        return "Ziehoperationen für Original, Archivmitglied oder gemischte Auswahl falsch"
    }
    for incoming in [[literal, nested], []] {
        replacement.pending = [literal]
        replacement.contextRow = 7
        if !replacement.hits.isEmpty {
            replacement.tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
        replacement.skippedCount = 42
        replacement.progressPath = "/old"
        replacement.replaceSearchResults(incoming)
        guard replacement.hits == incoming, replacement.pending.isEmpty,
              replacement.seenHitIdentities == Set(incoming.map { $0.identity }),
              replacement.statistics.count == incoming.count,
              replacement.skippedCount == 0, replacement.progressPath == nil,
              replacement.contextRow == -1,
              replacement.tableView.selectedRowIndexes.isEmpty else {
            return "Trefferersatz lässt alten Listenstand zurück"
        }
    }
    let list = MainController()
    list.tableView.dataSource = list
    list.tableView.allowsMultipleSelection = true
    list.enqueueSearchHits([literal, nested, literal])
    var identityFailures: [String] = []
    if list.pending.map({ $0.identity }) != [literal.identity, nested.identity]
        || list.pending.contains(where: { $0.searchRootBytes != Data(list.searchRoots[0].utf8) }) {
        identityFailures.append("Deduplikation/Herkunft")
    }
    list.pending = []
    list.hits = [literal, nested]
    list.applyHitsToTable(keepingSelection: [], resort: false)
    list.tableView.selectRowIndexes([0], byExtendingSelection: false)
    let selected = list.selectedHitIdentities()
    list.hits.reverse()
    list.applyHitsToTable(keepingSelection: selected, resort: false)
    if list.tableView.selectedRowIndexes != IndexSet(integer: 1) {
        identityFailures.append("Auswahlerhalt")
    }
    list.tableView.selectRowIndexes([0], byExtendingSelection: false)
    list.removeFromResults(nil)
    if list.hits != [literal] { identityFailures.append("Entfernen") }
    if !identityFailures.isEmpty {
        return "gleiche Anzeigepfade verwechselt: " + identityFailures.joined(separator: ", ")
    }

    let file = Hit(path: "/tmp/ordner-a/gross.bin", kind: "file", line: nil,
                   size: 1000, filesystemPath: "/tmp/ordner-a/gross.bin",
                   archiveMembers: [], isDirectory: false)
    let sameFolder = Hit(path: "/tmp/ordner-a/klein.bin", kind: "file",
                         line: 12, size: 24,
                         filesystemPath: "/tmp/ordner-a/klein.bin",
                         archiveMembers: [], isDirectory: false)
    let folder = Hit(path: "/tmp/ordner-b/unterordner", kind: "dir",
                     line: nil, size: nil,
                     filesystemPath: "/tmp/ordner-b/unterordner",
                     archiveMembers: [], isDirectory: true)
    // Eine DATEI ohne bekannte Größe (bsdtar-Eintrag) macht die Summe
    // unvollständig; ein Ordner ohne Größe nicht.
    let unsized = Hit(path: "/tmp/ordner-b/paket.7z!/darin.txt",
                      kind: "member", line: nil, size: nil,
                      filesystemPath: "/tmp/ordner-b/paket.7z",
                      archiveMembers: ["darin.txt"], isDirectory: false)

    // ---- Kennzahlen ----
    var stepwise = HitStatistics()
    for hit in [file, sameFolder, folder, unsized] { stepwise.add(hit) }
    let atOnce = HitStatistics.over([file, sameFolder, folder, unsized])
    guard stepwise.count == atOnce.count,
          stepwise.totalSize == atOnce.totalSize,
          stepwise.folders == atOnce.folders,
          stepwise.sizeIsPartial == atOnce.sizeIsPartial else {
        return "fortgeschriebene und neu berechnete Kennzahlen weichen ab"
    }
    guard stepwise.count == 4, stepwise.totalSize == 1024,
          stepwise.folders == ["/tmp/ordner-a", "/tmp/ordner-b"],
          stepwise.sizeIsPartial else {
        return "Kennzahlen falsch: \(stepwise.count) Treffer, "
            + "\(stepwise.totalSize) Bytes, "
            + "\(stepwise.folders.count) Ordner"
    }
    guard HitStatistics.over([folder]).sizeIsPartial == false else {
        return "ein Ordner ohne Größe macht die Summe unvollständig"
    }
    // Zwei einzeln darstellbare, zusammen aber zu große Archivgrößen dürfen
    // die App nicht beenden: Die Summe sättigt und gilt als Untergrenze.
    let huge = Hit(path: "/tmp/ordner-a/riesig.zip!/a.bin", kind: "member",
                   line: nil, size: Int.max - 1,
                   filesystemPath: "/tmp/ordner-a/riesig.zip",
                   archiveMembers: ["a.bin"], isDirectory: false)
    let overflowed = HitStatistics.over([huge, huge, file])
    guard overflowed.totalSize == Int.max, overflowed.sizeIsPartial,
          overflowed.count == 3 else {
        return "Größensumme sättigt beim Überlauf nicht"
    }

    // ---- Papierkorb-Merkliste ----
    // Ein verschobener Ordner nimmt alles darunter mit, aber nicht den
    // Nachbarn mit gleichem Namensanfang; ein Archiv nimmt seine Einträge mit.
    var trashedList = TrashedPaths()
    guard trashedList.isEmpty, !trashedList.contains("/tmp/x") else {
        return "leere Papierkorb-Merkliste meldet Treffer"
    }
    trashedList.insert("/tmp/weg/", isDirectory: true)
    trashedList.insert("/tmp/ordner-b/paket.7z", isDirectory: false)
    guard trashedList.contains("/tmp/weg"),
          trashedList.contains("/tmp/weg/tief/datei.txt"),
          !trashedList.contains("/tmp/wegweiser.txt"),
          trashedList.contains(unsized.filesystemPath),
          !trashedList.contains("/tmp/ordner-b/paket.7z.bak") else {
        return "Papierkorb-Merkliste ordnet Pfade falsch zu"
    }
    // Die Auswahl steht erst ab zwei markierten Zeilen in der Fußzeile.
    let oneSelected = hitStatisticsText(stepwise, selected: 1)
    let twoSelected = hitStatisticsText(stepwise, selected: 2)
    guard !oneSelected.contains("ausgewählt"),
          twoSelected.contains("2 ausgewählt"),
          oneSelected.contains("≥"), oneSelected.contains("2 Ordner") else {
        return "Fußzeile falsch: \(oneSelected) / \(twoSelected)"
    }

    // ---- Export ----
    let exported = [file, unsized]
    guard let paths = String(data: exportData(for: exported, format: .paths),
                             encoding: .utf8),
          paths == "/tmp/ordner-a/gross.bin\n"
              + "/tmp/ordner-b/paket.7z!/darin.txt\n" else {
        return "Pfad-Export stimmt nicht"
    }
    let nulData = exportData(for: exported, format: .pathsNUL)
    guard nulData.filter({ $0 == 0 }).count == 2,
          !nulData.contains(0x0A) else {
        return "NUL-Export enthält keine zwei Trenner oder einen Zeilenumbruch"
    }
    // JSONL muss der Kern-Parser wieder lesen können — sonst ist es kein
    // Austauschformat, sondern nur Text.
    let jsonlLines = exportData(for: exported, format: .jsonl)
        .split(separator: 0x0A).map { Data($0) }
    guard jsonlLines.count == 2,
          jsonlLines.compactMap({ parseHit($0) }) == exported else {
        return "JSONL-Export liest sich nicht wieder als dieselben Treffer"
    }
    let tricky = Hit(path: "/tmp/mit,Komma und \"Zitat\".txt", kind: "file",
                     line: nil, size: 7,
                     filesystemPath: "/tmp/mit,Komma und \"Zitat\".txt",
                     archiveMembers: [], isDirectory: false)
    let csvData = exportData(for: [tricky], format: .csv)
    // Die BOM wird als BYTES geprüft: Beim Dekodieren nach String
    // verschluckt Foundation sie, und ohne sie liest Excel unter macOS eine
    // UTF-8-Tabelle als Latin-1 und zerlegt jeden Umlaut im Dateinamen.
    guard csvData.starts(with: [0xEF, 0xBB, 0xBF]) else {
        return "CSV-Export beginnt nicht mit der UTF-8-BOM"
    }
    guard let csv = String(data: csvData.dropFirst(3), encoding: .utf8),
          csv.hasPrefix("path,type,isDirectory,size,line,filesystemPath,"
            + "field,value,width,height,modified,created,contentEncoding,documentPage,documentLine,documentPart,documentPartKind,documentParagraph,documentChapter,documentSheet,documentSheetIndex,documentCell,documentValueKind,documentSlide,documentObjectID,documentObjectKind,documentRow,documentColumn,finderTags,finderTagColors,finderComment,finderTagsStatus,finderCommentStatus,ocrBlock,ocrConfidence,ocrRegion\n"),
          csv.contains("\"/tmp/mit,Komma und \"\"Zitat\"\".txt\"") else {
        return "CSV-Export hat eine falsche Kopfzeile oder Maskierung"
    }

    // ---- Auswahl fürs Löschen ----
    // Derselbe Pfad zweimal darf nur EINMAL gelöscht werden, und ein Eintrag
    // im Archiv gar nicht: Dort gäbe es nur die ausgepackte Temp-Kopie.
    let split = trashableHits([file, file, unsized, sameFolder])
    guard split.trashable == [file, sameFolder], split.skipped == [unsized]
    else { return "Auswahl fürs Löschen falsch aufgeteilt" }
    let onlyMembers = trashableHits([unsized])
    guard onlyMembers.trashable.isEmpty else {
        return "ein Archiv-Eintrag gilt als löschbar"
    }
    let confirmation = trashConfirmationText(trashable: split.trashable,
                                             skipped: split.skipped)
    guard confirmation.message.contains("2 Objekte"),
          confirmation.info.contains("Archiv") else {
        return "Bestätigungstext nennt Anzahl oder Auslassung nicht"
    }
    guard trashConfirmationText(trashable: [file], skipped: [])
            .message.contains("gross.bin") else {
        return "Bestätigungstext einer einzelnen Datei nennt sie nicht"
    }

    // ---- Papierkorb, wirklich ----
    // Nicht nur die Aufteilung prüfen, sondern den Weg, den auch ⌘⌫ nimmt.
    let victim = sandbox.appendingPathComponent("papierkorb-probe.txt")
    guard (try? "weg damit\n".write(to: victim, atomically: true,
                                    encoding: .utf8)) != nil else {
        return "Testdatei für den Papierkorb nicht anlegbar"
    }
    let victimHit = Hit(path: victim.path, kind: "file", line: nil, size: 9,
                        filesystemPath: victim.path, archiveMembers: [],
                        isDirectory: false)
    var trashedPaths: [String: URL]?
    var trashError: Error?
    trashHits([victimHit]) { trashed, error in
        trashedPaths = trashed
        trashError = error
    }
    // Die Antwort kommt über die Main-Queue; ohne laufende NSApplication muss
    // der Selbsttest den Runloop selbst drehen.
    let deadline = Date().addingTimeInterval(20)
    while trashedPaths == nil, Date() < deadline {
        RunLoop.current.run(mode: .default,
                            before: Date().addingTimeInterval(0.05))
    }
    guard let trashedPaths else {
        return "Papierkorb hat innerhalb von 20 s nicht geantwortet"
    }
    guard let inTrash = trashedPaths[victim.path], trashedPaths.count == 1,
          !FileManager.default.fileExists(atPath: victim.path),
          FileManager.default.fileExists(atPath: inTrash.path) else {
        return "Datei liegt nicht im Papierkorb: "
            + (trashError?.localizedDescription ?? "ohne Fehlermeldung")
    }
    // Der Selbsttest räumt seine eigene Probe wieder weg — sonst sammelt sich
    // bei jedem Bauen eine weitere Datei im Papierkorb des Nutzers an.
    try? FileManager.default.removeItem(at: inTrash)

    let boundary = MainController()
    boundary.tableView.dataSource = boundary
    if let failure = staleHitRowSelfTest(boundary, cellAt: { column, row in
        boundary.tableView(boundary.tableView, viewFor: column, row: row)
    }) { return failure }

    // ---- Kennzahlen über echte Treffer ----
    guard HitStatistics.over(realHits).count == realHits.count else {
        return "Kennzahlen zählen die echten Treffer falsch"
    }
    return nil
}

private func checkResultListMenus() -> String? {
    let owner = MainController()
    let previousMainMenu = NSApp.mainMenu
    let menuBar = NSMenu()
    NSApp.mainMenu = menuBar
    defer { NSApp.mainMenu = previousMainMenu }
    owner.installFileMenu()
    guard let fileMenu = menuBar.items.compactMap(\.submenu).first(where: { $0.title == "Ablage" }) else {
        return "Hauptmenü enthält keine Ablage"
    }
    let context = NSMenu()
    owner.tableView.menu = context
    owner.tableView.dataSource = owner
    let scroll = NSScrollView()
    scroll.documentView = owner.tableView
    owner.installThumbnails(in: scroll, compact: false)
    guard let thumbs = owner.thumbnailController else { return "Vorschauraster fehlt" }
    thumbs.setGrid(true, persist: false)
    // Ein Kontextmenü für einen Archivordner benötigt keine LaunchServices-Abfrage.
    owner.hits = [
        Hit(path: "/fixture/a", kind: "file", line: nil, size: nil,
            filesystemPath: "/fixture/a", archiveMembers: [], isDirectory: false),
        Hit(path: "/fixture/a.zip!/Ordner", kind: "member", line: nil, size: nil,
            filesystemPath: "/fixture/a.zip", archiveMembers: ["Ordner"], isDirectory: true),
    ]
    owner.tableView.reloadData()
    owner.tableView.selectRowIndexes([0], byExtendingSelection: false)
    thumbs.contextTableRow = 1
    owner.menuNeedsUpdate(context)
    let expected: [(Selector, String, String, NSEvent.ModifierFlags)] = [
        (#selector(MainController.exportSelectedHits(_:)), "Auswahl exportieren…", "e", [.command, .shift]),
        (#selector(MainController.removeFromResults(_:)), "Aus Trefferliste entfernen", "\u{8}", []),
        (#selector(MainController.trashSelected(_:)), "In den Papierkorb legen", "\u{8}", [.command]),
    ]
    for (action, title, key, modifiers) in expected {
        guard let fileItem = fileMenu.items.first(where: { $0.action == action }),
              let contextItem = context.items.first(where: { $0.action == action }) else {
            return "Listenaktion „\(title)“ fehlt im Ablage- oder Kontextmenü"
        }
        for item in [fileItem, contextItem] {
            guard item.title == title, item.keyEquivalent == key,
                  item.keyEquivalentModifierMask == modifiers, item.target === owner else {
                return "Menüpunkt „\(title)“ trägt falsches Kürzel oder Ziel"
            }
        }
        guard owner.rows(for: fileItem) == [0], owner.rows(for: contextItem) == [1],
              !owner.validateMenuItem(fileItem), owner.validateMenuItem(contextItem) else {
            return "Listenaktion „\(title)“ reagiert auf die falsche Auswahl oder den falschen Fokus"
        }
    }
    owner.tableView.deselectAll(nil)
    thumbs.contextTableRow = -1
    owner.menuNeedsUpdate(context)
    guard context.items.isEmpty, owner.actionRows().isEmpty else {
        return "Kontextmenü behält Aktionen ohne vorhandene Zeile"
    }
    return nil
}
