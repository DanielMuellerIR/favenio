// Favenio.app — die große GUI im EasyFind-Stil.
//
// Aufbau: Suchfeld + Ordnerwahl + Optionen oben, darunter die Trefferliste.
// Die Suche läuft als Unterprozess (favenio.py --json) und streamt ihre
// Treffer live in die Tabelle. Aus der Liste heraus geht:
//   - Doppelklick        → Datei öffnen (Archiv-Einträge werden erst
//                          per --extract in einen Temp-Ordner ausgepackt)
//   - Rechtsklick        → Öffnen / Öffnen mit… / Im Finder zeigen /
//                          Pfad kopieren
//   - Drag & Drop        → Datei in den Finder oder andere Apps ziehen
//
// Außerdem versteht die App das URL-Schema favenio://results?file=…&q=…
// sowie das Startargument --handoff-url —
// darüber liefert die Schnellsuche (FavenioQuick.app) ihre Treffer an.
//
// Mit --selftest läuft statt der GUI ein Headless-Integrationstest.

import AppKit
import Quartz   // QLPreviewPanel (QuickLook-Vorschau)

@main
struct FavenioApp {
    static func main() {
        // Headless-Selbsttest (für Build-Skript und AI-Agenten):
        // prüft Suche + Extraktion über exakt denselben Code, den die
        // GUI benutzt — ganz ohne Fenster.
        if CommandLine.arguments.contains("--selftest") {
            exit(runSelfTest())
        }
        // Headless-Diagnose: was sieht DIESES Bundle beim Finder wirklich?
        if CommandLine.arguments.contains("--finder-scope") {
            runFinderScopeDiagnostic()
        }
        let app = NSApplication.shared
        let controller = MainController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        app.run()
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
    guard skippedNote(1).contains("1 Objekt"), skippedNote(0).isEmpty,
          skippedNote(3).contains("3 Objekte") else {
        return "Fußzeilen-Zusatz für übersprungene Objekte stimmt nicht"
    }
    return nil
}

func runSelfTest() -> Int32 {
    defer { cleanupMaterializedHits() }
    _ = NSApplication.shared
    let pixelController = MainController()
    if let error = pixelFieldSelfTest(pixelController.pixelFields,
                                     validate: pixelController.validatePixelInputs) {
        print("SELFTEST FEHLER: \(error)")
        return 1
    }

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
    guard findCLI() != nil else {
        print("SELFTEST FEHLER: favenio.py nicht gefunden")
        return 1
    }
    if let error = validateSparkleConfiguration(
        expectedBundleIdentifier: "local.favenio"
    ) {
        print("SELFTEST FEHLER: \(error)")
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
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("favenio-selftest-\(ProcessInfo.processInfo.processIdentifier)")
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

    guard let args = searchArguments(pattern: "FAVENIO_PROBE",
                                     root: tmp.path, content: true,
                                     regex: false, caseSensitive: true,
                                     archives: true) else { return 1 }
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
    guard limits.arguments == ["--min-width", "1000", "--max-height", "900"],
          limits.summary == "B ≥ 1000, H ≤ 900",
          let sizeArgs = searchArguments(pattern: "", root: tmp.path,
                                         content: false, regex: false,
                                         caseSensitive: false, archives: true,
                                         pixelLimits: limits),
          sizeArgs.contains("--min-width"),
          // Ohne Muster kein synthetisches „*": Der Kern läuft dann ganz
          // ohne Textkriterium (Review-Fund 2026-09-02).
          !sizeArgs.contains("*") else {
        print("SELFTEST FEHLER: Maßfilter werden nicht an den Kern gereicht")
        return 1
    }
    // --content/--metadata brauchen ein Muster; ohne eines lehnt der Kern
    // sie ab und die reine Maßsuche wäre nicht mehr startbar.
    guard let sizeOnlyArgs = searchArguments(
            pattern: "", root: tmp.path, content: true, regex: false,
            caseSensitive: false, archives: true, metadata: false,
            metadataField: "Title", pixelLimits: limits),
          !sizeOnlyArgs.contains("--content"),
          !sizeOnlyArgs.contains("--metadata-field"),
          searchArguments(pattern: "", root: tmp.path, content: false,
                          regex: false, caseSensitive: false,
                          archives: true) == nil else {
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
    // Die Feldliste der Metadatensuche kommt vom Kern.
    let fields = metadataFieldList()
    guard fields.contains("Keywords"), fields.contains("Title") else {
        print("SELFTEST FEHLER: Metadaten-Feldliste nicht vom Kern erhalten")
        return 1
    }
    guard let metaArgs = searchArguments(pattern: "Winter", root: tmp.path,
                                         content: false, regex: false,
                                         caseSensitive: false, archives: true,
                                         metadata: true,
                                         metadataField: "Title"),
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
    guard let member = hits.first(where: { $0.isMember }),
          let extracted = materializeHit(member),
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
    if let failure = checkResultListFeatures(realHits: hits, sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    if let failure = checkDiagnosticsReachTheSurface(sandbox: tmp) {
        print("SELFTEST FEHLER: " + failure)
        return 1
    }
    print("SELFTEST OK — Suche, Archiv-Extraktion, Trefferlisten-Werkzeuge "
          + "und Sparkle-Anbindung funktionieren")
    return 0
}

/// Prüft die Werkzeuge, die auf der fertigen Trefferliste arbeiten:
/// Kennzahlen, Export, Auswahl fürs Löschen und den Papierkorb selbst.
/// Rückgabe: nil bei Erfolg, sonst der Grund.
func checkResultListFeatures(realHits: [Hit], sandbox: URL) -> String? {
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
                        + "field,value,width,height,modified,created\n"),
          csv.contains("\"/tmp/mit,Komma und \"\"Zitat\"\".txt\"") else {
        return "CSV-Export maskiert Komma und Anführungszeichen nicht"
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

    // ---- Die Menüpunkte selbst ----
    // Am echten NSMenu geprüft: Ein Kürzel, das im Menü fehlt oder die
    // falsche Zusatztaste trägt, ist für den Nutzer nicht auffindbar.
    let resultMenu = NSMenu()
    populateResultListMenu(
        resultMenu, target: NSObject(),
        selectors: ResultListMenuSelectors(
            exportSelection: NSSelectorFromString("export:"),
            removeFromList: NSSelectorFromString("remove:"),
            moveToTrash: NSSelectorFromString("trash:")))
    let expected: [(String, String, NSEvent.ModifierFlags)] = [
        ("Auswahl exportieren…", "e", [.command, .shift]),
        ("Aus Trefferliste entfernen", backspaceKeyEquivalent, []),
        ("In den Papierkorb legen", backspaceKeyEquivalent, [.command]),
    ]
    guard resultMenu.items.count == expected.count else {
        return "Trefferlisten-Menü hat \(resultMenu.items.count) Punkte "
            + "statt \(expected.count)"
    }
    for (item, want) in zip(resultMenu.items, expected) {
        guard item.title == want.0, item.keyEquivalent == want.1,
              item.keyEquivalentModifierMask == want.2 else {
            return "Menüpunkt „\(item.title)“ trägt das falsche Kürzel"
        }
    }

    // ---- Kennzahlen über echte Treffer ----
    guard HitStatistics.over(realHits).count == realHits.count else {
        return "Kennzahlen zählen die echten Treffer falsch"
    }
    return nil
}

// MARK: - Haupt-Controller

/// Erbt von HitListController (common/FavenioCore.swift): Trefferliste,
/// Vorschau und die gemeinsamen Kontextmenü-Aktionen stehen dort EINMAL
/// für beide Apps.
final class MainController: HitListController, NSApplicationDelegate,
                            NSTableViewDataSource, NSTableViewDelegate,
                            NSMenuDelegate, NSMenuItemValidation,
                            NSSearchFieldDelegate {

    /// Ein Controller pro App-Prozess; Sparkle hält darüber Update-Zustand,
    /// Download und Installation über die gesamte App-Laufzeit zusammen.
    private let updaterController = makeUpdaterController()
    let searchField = NSSearchField()
    let stopButton = NSButton(title: "", target: nil, action: nil)
    let folderButton = NSButton(title: "Ordner…", target: nil, action: nil)
    // Wogegen das Muster läuft: Name | Inhalt | Metadaten.
    let modeControl = NSSegmentedControl(
        labels: SearchTextMode.allCases.map { $0.title },
        trackingMode: .selectOne, target: nil, action: nil)
    // Nur bei „Metadaten": ein Feld oder alle Textfelder. Die Liste kommt
    // vom Kern (--list-metadata-fields) und wird hier nicht nachgebaut.
    let fieldPopup = NSPopUpButton()
    // Bildmaße: Breite und Höhe je von/bis, leer = egal. Gelten immer
    // zusätzlich (UND) zum Muster; das Muster darf dann auch fehlen.
    let filterView = SearchFilterView()
    let minWidthField = NSTextField(string: "")
    let maxWidthField = NSTextField(string: "")
    let minHeightField = NSTextField(string: "")
    let maxHeightField = NSTextField(string: "")
    let archivesCheckbox = NSButton(checkboxWithTitle: "In Archiven suchen",
                                    target: nil, action: nil)
    let regexCheckbox = NSButton(checkboxWithTitle: "Regex",
                                 target: nil, action: nil)
    let caseCheckbox = NSButton(checkboxWithTitle: "Groß/klein beachten",
                                target: nil, action: nil)
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Unsichtbare",
                                  target: nil, action: nil)
    // „Genauer Name": ohne diesen Schalter ist ein Muster ohne Platzhalter ein
    // Teilstring — „release.sh" fände dann auch „test-github-release.sh".
    let exactCheckbox = NSButton(checkboxWithTitle: "Genauer Name",
                                 target: nil, action: nil)
    // Drei-Wege-Umschalter: Dateien & Ordner / nur Dateien / nur Ordner.
    let typeControl = NSSegmentedControl(
        labels: ["Dateien & Ordner", "Dateien", "Ordner"],
        trackingMode: .selectOne, target: nil, action: nil)
    // Aufklappbare Liste fertiger RegEx-Vorlagen (nur im Regex-Modus sinnvoll).
    let templatesButton = NSButton(title: "Regex-Vorlagen ▾",
                                   target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "Bereit.")

    var seenPaths = Set<String>()   // schon gezeigte Pfade → keine Doppelten
    // Was dieser Lauf in den Papierkorb gelegt hat. Ein noch laufender
    // Suchprozess kennt den Papierkorb nicht und streamt Treffer unter einem
    // verschobenen Ordner oder in einem verschobenen Archiv weiter.
    var trashedPaths = TrashedPaths()
    // Wahr, solange applyHitsToTable die Auswahl leert und wieder setzt.
    var isRestoringSelection = false
    var cachedFinderFolders: [String] = []   // Finder-Fenster (async geladen)
    var refreshingFinder = false
    /// Zählt die Aktivierungen des Fensters. Nur die Antwort der AKTUELLEN
    /// Aktivierung darf das Ordner-Menü setzen; eine währenddessen
    /// eingetroffene neue Aktivierung wird vorgemerkt und danach mit einer
    /// frischen Finder-Abfrage bedient. Vorher verwarf ein laufender Lauf jede
    /// neue Aktivierung ersatzlos, und das Menü zeigte die Fenster oder den
    /// TCC-Zustand der vorigen Aktivierung (Review-Fund 2026-08-17). Dieselbe
    /// Mechanik steckt in QuickController.refreshFinderFoldersAsync().
    var finderRefreshGeneration = 0
    var queuedFinderRefreshGeneration: Int?
    // Warum die Finder-Fenster fehlen (verweigerte Automation, kein Fenster,
    // Zeitüberschreitung). Steht im Ordner-Menü, statt kommentarlos zu fehlen.
    var finderScopeProblem: String?
    var finderScopeDenied = false
    var searchRoot = FileManager.default.homeDirectoryForCurrentUser
    var activeSearchRun: SearchRunner?
    var flushTimer: Timer?
    var pendingURL: URL?            // favenio://-URL, die vor dem Fenster kam
    /// Zustand der Suche für die Fußzeile. Gespeichert wird der ZUSTAND, nie
    /// ein fertig formulierter Satz — sonst steht dort später „Suche läuft…",
    /// obwohl sie längst fertig ist. Dieselbe Falle umgeht FavenioQuick mit
    /// runScopeNoteText().
    enum SearchPhase {
        case idle                // es wurde noch nicht gesucht
        case running
        case stopped             // vom Nutzer abgebrochen
        case finished
        case handedOver          // Treffer der Schnellsuche, ohne eigenen Lauf
        case failed(String)      // Grund, den die Fußzeile wörtlich zeigt
    }
    var searchPhase: SearchPhase = .idle
    /// Wie viele Objekte der letzte Lauf überspringen musste (kaputtes
    /// Archiv, fehlende Leserechte). Ohne diese Zahl sieht ein Lauf, der
    /// etwas auslassen musste, genauso vollständig aus wie einer, der
    /// alles gelesen hat.
    var skippedCount = 0
    /// Ordner oder Archiv, das der Kern gerade durchsucht (nur bei .running).
    var progressPath: String?
    /// Kennzahlen der Trefferliste (Treffer, Datenmenge, Ordner) für die
    /// Fußzeile. Beim Streamen fortgeschrieben statt neu aufsummiert.
    var statistics = HitStatistics()
    /// Der offene Sichern-Dialog des Exports; das Format-Aufklappmenü darin
    /// muss seinen Dateinamen ändern können.
    var exportSavePanel: NSSavePanel?

    // ---------- App-Lebenszyklus ----------

    func applicationWillFinishLaunching(_ notification: Notification) {
        // GetURL-Events (favenio://…) müssen VOR didFinishLaunching
        // registriert sein, sonst geht ein Launch-per-URL verloren.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu(appName: "Favenio")
        installUpdateMenuItem(updaterController: updaterController)
        buildWindow()
        installAboutItem()
        installViewMenu()
        installFileMenu()
        // Finder-Fenster für das Ordner-Popup vorab im Hintergrund laden
        // (der AppleScript-Aufruf darf den Start nicht blockieren).
        refreshFinderFoldersAsync()

        // Fallback-Weg ohne funktionierende URL-Zuordnung: Quick startet eine
        // neue App-Instanz und gibt denselben strukturierten URL-Datensatz als
        // Argument mit. Dadurch verarbeitet genau EIN Parser Wurzel, Optionen,
        // Ergebnisdatei und die gewünschte Fortsetzung der Suche.
        //
        // Die ältere Übergabe --query/--results-file gibt es nicht mehr: Sie
        // kannte keine Suchwurzel, und die Pfadspalte zeigte die Treffer
        // dann relativ zum Benutzerordner statt zum durchsuchten Ordner
        // (Review-Fund 2026-09-05). Nötig war sie nie — install.sh und das
        // DMG liefern beide Bundles nur mit derselben Version aus.
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--handoff-url"),
           flagIndex + 1 < arguments.count,
           let handoffURL = URL(string: arguments[flagIndex + 1]) {
            handleFavenioURL(handoffURL)
        }
        // Eine URL, die schon vor dem Fensterbau eintraf, jetzt verarbeiten.
        if let url = pendingURL {
            pendingURL = nil
            handleFavenioURL(url)
        }

        // Beim Start einmal auf Festplattenvollzugriff hinweisen (bringt bei
        // Suchen über den ganzen Benutzerordner deutlich weniger Nachfragen).
        maybePromptFullDiskAccess(appName: "Favenio")

        // Tasten, die nur IN der Trefferliste gelten. Hat die Tabelle nicht
        // den Fokus, geht das Ereignis unverändert weiter — dann tippt die
        // Leertaste normal ins Suchfeld und ⌫ löscht dort ein Zeichen.
        //
        // Der Monitor läuft vor NSApplication.sendEvent und damit vor dem
        // Tastenkürzel des Menüs: Wer hier zugreift, löst die Aktion genau
        // einmal aus. Der Menüpunkt trägt dasselbe Kürzel trotzdem — dort
        // steht es sichtbar, statt Geheimwissen zu bleiben.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            // Das Ereignis muss aus dem HAUPTFENSTER kommen, und das muss
            // das Tastaturfenster sein. Der gemerkte firstResponder allein
            // reicht nicht: Während ein Sichern-Blatt oder ein NSAlert offen
            // ist, steht im Hauptfenster weiter die Tabelle — ⌫ im
            // Dateinamenfeld des Exportdialogs entfernte sonst Treffer
            // (Review-Fund 2026-09-02).
            guard let self,
                  event.window === self.window,
                  self.window.isKeyWindow,
                  self.window.firstResponder === self.tableView
            else { return event }
            // Nur die echten Zusatztasten vergleichen. Caps Lock, Zehnerblock
            // und das Funktionsbit hängen je nach Tastatur mit dran und
            // dürfen ein Kürzel nicht entwerten.
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            switch event.keyCode {
            case 49 where modifiers.isEmpty:               // Leertaste
                self.contextRow = -1
                self.togglePreview()
                return nil
            case 53 where modifiers.isEmpty:               // ⎋
                // Die Vorschau ist nicht mehr das Tastaturfenster und kann
                // sich deshalb nicht mehr selbst schließen. Nur abfangen,
                // wenn sie wirklich offen ist — sonst gehört ⎋ weiter dem
                // Fenster (Suchfeld leeren, Blatt abbrechen).
                guard QLPreviewPanel.sharedPreviewPanelExists(),
                      QLPreviewPanel.shared().isVisible else { return event }
                QLPreviewPanel.shared().orderOut(nil)
                return nil
            case 51 where modifiers.isEmpty:               // ⌫
                self.contextRow = -1
                self.removeFromResults(nil)
                return nil
            case 51 where modifiers == .command:           // ⌘⌫
                self.contextRow = -1
                self.trashSelected(nil)
                return nil
            default:
                return event
            }
        }
    }

    /// „Über Favenio" ganz oben ins App-Menü setzen.
    func installAboutItem() {
        guard let appMenu = NSApp.mainMenu?.item(at: 0)?.submenu else { return }
        let about = NSMenuItem(title: "Über Favenio",
                               action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.insertItem(about, at: 0)
        appMenu.insertItem(.separator(), at: 1)
    }

    /// Über-Dialog: HIER (und nur hier) steht der lateinische Spruch, dazu
    /// Versionsnummer und Versionsdatum.
    @objc func showAbout() {
        let credits = NSAttributedString(
            string: "facile invenio — „ich finde mit Leichtigkeit“\n\n"
                + "Indexlose Datei- und Archivsuche.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Favenio",
            .applicationVersion: favenioVersion,         // Versionsnummer
            .version: favenioDate,                       // Versionsdatum
            .credits: credits,
        ])
    }

    /// Auswahl geändert, während die Vorschau offen ist → mitziehen.
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Während applyHitsToTable die Auswahl leert und wieder setzt, ist
        // der Zwischenzustand keine Auswahländerung.
        guard !isRestoringSelection else { return }
        contextRow = -1
        refreshStatus()     // „N ausgewählt" in der Fußzeile mitziehen
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible {
            rebuildPreviewURLs()
            QLPreviewPanel.shared().reloadData()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication) -> Bool { true }

    /// App vorderste → Finder-Fenster (neu) laden. Nur wenn die App aktiv
    /// ist, zeigt TCC den Automations-Consent-Dialog. Läuft im Hintergrund.
    func applicationDidBecomeActive(_ notification: Notification) {
        finderRefreshGeneration += 1
        // Finder-Fenster der vorigen Aktivierung sind keine gültige Antwort
        // für die neue: Bis die frische Abfrage da ist, bleibt die Liste leer.
        cachedFinderFolders = []
        refreshFinderFoldersAsync()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopSearch()
        cleanupMaterializedHits()
    }

    // ---------- URL-Schema (favenio://results?file=…&q=…&root=…) ----------

    @objc func handleGetURL(_ event: NSAppleEventDescriptor,
                            withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event
                .paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?
                .stringValue,
              let url = URL(string: urlString) else { return }
        if window == nil {
            pendingURL = url    // Fenster existiert noch nicht → merken
        } else {
            handleFavenioURL(url)
        }
    }

    func handleFavenioURL(_ url: URL) {
        guard let components = URLComponents(url: url,
                                             resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "favenio",
              components.host?.lowercased() == "results"
        else { return }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        guard let filePath = value("file"),
              validatedQuickHandoff(URL(fileURLWithPath: filePath)) != nil,
              (value("q")?.utf8.count ?? 0) <= 4096,
              (value("root")?.utf8.count ?? 0) <= 4096 else { return }
        if let query = value("q") { searchField.stringValue = query }
        if let root = value("root") {
            setSearchRoot(URL(fileURLWithPath: root))
        }
        // Suchoptionen der Schnellsuche übernehmen (Default: aus), damit die
        // Weitersuche hier mit denselben Einstellungen läuft. „Aus" ist bei
        // regex, case und field kein Verlust: Die Schnellsuche hat diese
        // Schalter nicht und sucht immer ohne sie; ein hier gesetzter Wert
        // muss deshalb zurückgesetzt werden, sonst passen die übergebenen
        // Treffer nicht zur fortgesetzten Suche. Neue Quick-Versionen
        // schicken regex=0 und case=0 ausdrücklich mit.
        // Alte Quick-Versionen schicken nur content=0/1, neue den Modus.
        let configuration = SearchConfiguration.fromQueryItems(items)
        selectMode(configuration.mode)
        selectMetadataField(configuration.metadataField)
        for (field, text) in zip(pixelFields, configuration.pixelTexts) { field.stringValue = text }
        filterView.exclusions = configuration.exclusions
        filterView.rawFacts = configuration.rawFacts
        archivesCheckbox.state = configuration.archives ? .on : .off
        hiddenCheckbox.state = configuration.includeHidden ? .on : .off
        regexCheckbox.state = configuration.regex ? .on : .off
        caseCheckbox.state = configuration.caseSensitive ? .on : .off
        exactCheckbox.state = configuration.exact ? .on : .off
        typeControl.selectedSegment = ["both": 0, "files": 1, "dirs": 2][configuration.only] ?? 0

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if value("continue") == "1" {
            // Schnellsuche hat bei 20 Treffern übergeben: die 20 sofort
            // zeigen und die Suche hier live fortsetzen (weitere Treffer
            // kommen hinzu, die 20 werden dabei nicht doppelt gelistet).
            continueSearch(from: URL(fileURLWithPath: filePath))
        } else {
            loadResults(from: URL(fileURLWithPath: filePath))
        }
        // Auch eine reine Ergebnisanzeige markiert ungültige URL-Eingaben;
        // der nächste Start bleibt durch denselben Validator gesperrt.
        _ = validatePixelInputs()
    }

    /// Fertige Treffer (JSONL-Datei der Schnellsuche) direkt anzeigen —
    /// die Suche lief dort schon, hier wird nichts doppelt gesucht.
    func loadResults(from file: URL) {
        guard let loaded = consumeQuickHandoff(file) else {
            searchPhase = .failed("Ungültige oder zu große Ergebnisübergabe.")
            refreshStatus()
            return
        }
        stopSearch()
        hits = loaded
        pending = []
        seenPaths = Set(loaded.map { $0.path })
        trashedPaths = TrashedPaths()
        statistics = .over(hits)
        skippedCount = 0
        searchPhase = .handedOver
        progressPath = nil
        applyHitsToTable(keepingSelection: [])
        refreshStatus()
    }

    // ---------- Fenster + Layout ----------

    func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Favenio"   // der lateinische Spruch nur im „Über"-Dialog
        window.isReleasedWhenClosed = false
        guard let content = window.contentView else { return }

        searchField.placeholderString =
            "Suchmuster — Return startet die Suche"
        searchField.target = self
        searchField.action = #selector(startSearch)
        searchField.delegate = self   // controlTextDidChange → Regex-Färbung
        // Ohne das zeigt NSSearchField NUR eine Textfarbe — die Token-Färbung
        // im Regex-Modus wäre unsichtbar.
        searchField.allowsEditingTextAttributes = true

        // Stopp-Button links vom Suchfeld: bricht die laufende Suche ab.
        stopButton.image = NSImage(systemSymbolName: "stop.fill",
                                   accessibilityDescription: "Suche stoppen")
        stopButton.bezelStyle = .rounded
        stopButton.imagePosition = .imageOnly
        stopButton.toolTip = "Suche stoppen"
        stopButton.target = self
        stopButton.action = #selector(stopSearchClicked)
        stopButton.isEnabled = false
        searchField.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                              for: .horizontal)

        folderButton.title = "📁 " + searchRoot.lastPathComponent + " ▾"
        folderButton.toolTip = searchRoot.path
        folderButton.target = self
        // Klick öffnet NICHT mehr direkt den Dateidialog, sondern ein
        // Popup-Menü (wie EasyFind): offene Finder-Fenster + wichtige Ordner
        // + „Anderer Ordner…". Ein ▾ signalisiert das Aufklappen.
        folderButton.action = #selector(showFolderMenu)

        archivesCheckbox.state = .on   // Archiv-Blick ist das Markenzeichen

        // Umschalter: „Dateien & Ordner" vorausgewählt; Wechsel sucht neu.
        typeControl.selectedSegment = 0
        typeControl.target = self
        typeControl.action = #selector(startSearch)

        // Regex-Umschalten färbt das Feld um (an) bzw. zurück (aus).
        regexCheckbox.target = self
        regexCheckbox.action = #selector(regexToggled)
        // „Genauer Name" wirkt sofort — sonst müsste man Return nachschieben.
        exactCheckbox.target = self
        exactCheckbox.action = #selector(startSearch)
        templatesButton.bezelStyle = .rounded
        templatesButton.target = self
        templatesButton.action = #selector(showTemplatesMenu(_:))

        // Statuszeile darf die Fensterbreite NICHT aufblähen: lange
        // Fortschritts-Pfade werden gekürzt, die Breite an den Stack gebunden.
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        buildTable()
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        // Die Spalten dürfen zusammen breiter sein als das Fenster: Wer den
        // Pfad breit zieht, soll dafür nicht erst alle anderen Spalten
        // zusammenquetschen müssen. Der Rest läuft über den waagerechten
        // Balken. Bis 0.28.3 deckelte `lastColumnOnlyAutoresizingStyle` ohne
        // Scroller die Summe auf die Fensterbreite.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),
                                         for: .vertical)

        let topRow = NSStackView(views: [stopButton, searchField, folderButton])
        topRow.orientation = .horizontal
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        fieldPopup.addItem(withTitle: "Alle Textfelder")
        fieldPopup.menu?.addItem(.separator())
        for field in metadataFieldList() { fieldPopup.addItem(withTitle: field) }
        fieldPopup.isHidden = true      // erst im Modus „Metadaten"
        let optionsRow = NSStackView(views: [typeControl, modeControl,
                                             fieldPopup,
                                             archivesCheckbox, hiddenCheckbox,
                                             exactCheckbox, regexCheckbox,
                                             caseCheckbox, templatesButton])
        optionsRow.orientation = .horizontal
        optionsRow.spacing = 12

        // Maßzeile: „Bildmaße  Breite [min]–[max]  Höhe [min]–[max] px".
        for (field, placeholder) in [(minWidthField, "min"),
                                     (maxWidthField, "max"),
                                     (minHeightField, "min"),
                                     (maxHeightField, "max")] {
            field.placeholderString = placeholder
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.target = self
            field.action = #selector(startSearch)
            field.delegate = self
        }
        let sizeRow = NSStackView(views: [
            NSTextField(labelWithString: "Bildmaße:"),
            NSTextField(labelWithString: "Breite"), minWidthField,
            NSTextField(labelWithString: "–"), maxWidthField,
            NSTextField(labelWithString: "Höhe"), minHeightField,
            NSTextField(labelWithString: "–"), maxHeightField,
            NSTextField(labelWithString: "px"),
        ])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 6
        sizeRow.setCustomSpacing(14, after: sizeRow.views[4])

        filterView.onChange = { [weak self] in
            self?.stopSearch()
            self?.searchPhase = .idle
            self?.progressPath = nil
            self?.refreshStatus()
        }
        let stack = NSStackView(views: [topRow, optionsRow, sizeRow, filterView, scroll,
                                        statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor,
                                       constant: 12),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor,
                                           constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor,
                                            constant: -12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor,
                                          constant: -12),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            optionsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            filterView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            // Statuszeile an die Stack-Breite binden → kann das Fenster nicht
            // in die Breite ziehen (langer „durchsuche …"-Pfad).
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
    }

    /// Die beiden Datumsspalten. Sie laufen in Tabellenziffern, damit die
    /// Musterbreiten aus `dateColumnSamples` für jedes echte Datum gelten.
    static let dateColumns: Set<String> = ["modified", "created"]
    let dateFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)
    /// Je Datumsspalte die Breite, für die die Stufe zuletzt bestimmt wurde,
    /// und diese Stufe — die Messung läuft nur bei geänderter Breite.
    var dateStages: [String: (width: CGFloat, stage: Int)] = [:]

    func buildTable() {
        // (Identifier, Titel, Breite) — Reihenfolge = Spaltenreihenfolge:
        // die wichtigsten zuerst, damit der Pfad ohne Ziehen im Fenster
        // steht. Jede Spalte ist über einen sortDescriptorPrototype
        // sortierbar; der key zeigt auf compareHits() im Kern.
        let columns = [
            ("name", "Name", CGFloat(240)),
            ("size", "Größe", CGFloat(80)),
            ("path", "Pfad", CGFloat(300)),
            ("type", "Typ", CGFloat(130)),
            ("modified", "Änderungsdatum", CGFloat(130)),
            ("created", "Erstellungsdatum", CGFloat(130)),
            ("line", "Fundstelle", CGFloat(110)),
            ("dims", "Maße", CGFloat(84)),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 40
            column.sortDescriptorPrototype =
                NSSortDescriptor(key: identifier, ascending: true)
            // Größe rechtsbündig (Zahlenspalte).
            if identifier == "size" {
                column.headerCell.alignment = .right
            }
            tableView.addTableColumn(column)
        }
        // Keine automatische Anpassung: Die Summe der Spalten darf das
        // Fenster überragen (waagerechter Balken), und keine Spalte wird
        // beim Fensterziehen heimlich schmaler.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        // Breite und Reihenfolge der Spalten überleben den Neustart — wer
        // den Pfad einmal breit gezogen hat, soll das nicht wiederholen.
        tableView.autosaveName = "Favenio.hits.columns"
        tableView.autosaveTableColumns = true
        // Beim Ziehen einer Datumsspalte deren Stufe neu bestimmen und die
        // sichtbaren Zellen neu formatieren.
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: tableView)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)

        // Rechtsklick-Menü: Inhalt wird je Klick in menuNeedsUpdate gebaut.
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        // Drag & Drop nach draußen (Finder, andere Apps) erlauben.
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    }

    // ---------- Fußzeile ----------

    /// Schreibt die Fußzeile aus dem aktuellen Zustand neu.
    func refreshStatus() { statusLabel.stringValue = statusText() }

    /// Formuliert die Fußzeile: Kennzahlen der Trefferliste, dahinter — falls
    /// gerade etwas läuft oder abgebrochen wurde — der Zustand der Suche.
    func statusText() -> String {
        if case .failed(let reason) = searchPhase { return reason }
        if hits.isEmpty {
            switch searchPhase {
            case .idle:
                return "Bereit."
            case .running:
                return progressPath.map { "Durchsuche " + abbreviateHome($0) }
                    ?? "Suche läuft…"
            case .stopped:
                return "Suche gestoppt — keine Treffer."
            default:
                return "Keine Treffer." + skippedNote(skippedCount)
            }
        }
        var text = hitStatisticsText(
            statistics, selected: tableView.selectedRowIndexes.count)
        switch searchPhase {
        case .running:
            text += progressPath.map { " — durchsuche " + abbreviateHome($0) }
                ?? " — Suche läuft…"
        case .stopped:
            text += " — Suche gestoppt"
        case .handedOver:
            text += " — aus der Schnellsuche"
        default:
            break
        }
        return text + skippedNote(skippedCount)
    }

    func setSearchRoot(_ url: URL) {
        searchRoot = url
        // Wurzel-Ordner heißt "" bei "/" → dann den Pfad zeigen.
        let name = url.lastPathComponent.isEmpty ? url.path
                                                 : url.lastPathComponent
        folderButton.title = "📁 " + name + " ▾"
        folderButton.toolTip = url.path
    }

    // ---------- Suche (asynchron, streamend) ----------

    /// Klick auf den Ordner-Button: EasyFind-artiges Popup statt sofortigem
    /// Dateidialog. Ganz oben die offenen Finder-Fenster (vorderstes zuerst),
    /// darunter die wichtigsten Ordner, ganz unten „Anderer Ordner…".
    /// „Ansicht"-Menü: bündelt den Unsichtbare-Umschalter mit dem Finder-
    /// Kürzel Cmd+Shift+. (dieselbe Kombi wie im Finder).
    func installViewMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Ansicht")
        let hidden = NSMenuItem(title: "Unsichtbare Dateien",
                                action: #selector(toggleHidden),
                                keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = self
        viewMenu.addItem(hidden)
        viewItem.submenu = viewMenu
        // Vor „Bearbeiten" einsortieren (nach dem App-Menü).
        mainMenu.insertItem(viewItem, at: min(1, mainMenu.numberOfItems))
    }

    /// Cmd+Shift+. bzw. Menü: Unsichtbare-Checkbox umschalten und neu suchen.
    @objc func toggleHidden() {
        hiddenCheckbox.state = hiddenCheckbox.state == .on ? .off : .on
        startSearch()
    }

    /// Lädt die offenen Finder-Fenster in den Cache — asynchron über einen
    /// osascript-Unterprozess, der den Main-Thread NIE blockiert (siehe
    /// finderWindowFoldersAsync). Das Ordner-Popup nimmt danach den Cache.
    func refreshFinderFoldersAsync() {
        let generation = finderRefreshGeneration
        guard !refreshingFinder else {
            queuedFinderRefreshGeneration = generation
            return
        }
        refreshingFinder = true
        finderWindowFoldersAsync { [weak self] outcome in
            guard let self else { return }
            self.refreshingFinder = false
            // Eine Antwort aus einer überholten Aktivierung wird verworfen.
            if generation == self.finderRefreshGeneration {
                self.finderScopeProblem = outcome.problemText
                if case .denied = outcome {
                    self.finderScopeDenied = true
                } else {
                    self.finderScopeDenied = false
                }
                if case .folders(let folders) = outcome {
                    self.cachedFinderFolders = folders
                }
            }
            guard let queued = self.queuedFinderRefreshGeneration else { return }
            self.queuedFinderRefreshGeneration = nil
            if queued == self.finderRefreshGeneration {
                self.refreshFinderFoldersAsync()
            }
        }
    }

    /// Menüpunkt bei verweigerter Automation: direkt in die passende
    /// Systemeinstellung springen.
    @objc func openAutomationPrefs() { openAutomationSettings() }

    @objc func showFolderMenu() {
        // Für den nächsten Aufruf frisch laden, jetzt aber den Cache nehmen —
        // so hängt der Klick nie am (evtl. blockierenden) Finder-AppleScript.
        refreshFinderFoldersAsync()
        let menu = NSMenu()

        // 0) Scheiterte die letzte Finder-Abfrage, steht der Grund GANZ OBEN —
        //    auch wenn unten noch ältere Fenster aus dem Cache stehen. Ohne den
        //    Hinweis wirkte eine veraltete oder leere Liste wie die Wahrheit.
        if let problem = finderScopeProblem {
            let info = NSMenuItem(title: problem, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
            if finderScopeDenied {
                let fix = NSMenuItem(title: "Automatisierung erlauben…",
                                     action: #selector(openAutomationPrefs),
                                     keyEquivalent: "")
                fix.target = self
                menu.addItem(fix)
            }
            menu.addItem(.separator())
        }

        // 1) Offene Finder-Fenster. Der erste Eintrag ist das VORDERSTE
        //    Finder-Fenster. Bewusst „vorderstes" und nicht „aktives": Solange
        //    Favenio vorn ist, hat kein Finder-Fenster den Tastaturfokus.
        let windows = cachedFinderFolders
        for (index, path) in windows.enumerated() {
            let name = (path as NSString).lastPathComponent
            let title = index == 0 ? "Vorderstes Finder-Fenster — \(name)"
                                   : name
            addFolderItem(to: menu, title: title, path: path)
        }
        if !windows.isEmpty { menu.addItem(.separator()) }

        // 2) Wichtige Ordner (feste, verständliche deutsche Namen).
        for (title, path) in commonFolders() {
            addFolderItem(to: menu, title: title, path: path)
        }

        // 3) Beliebiger Ordner über den Dateidialog (der frühere Direktweg).
        menu.addItem(.separator())
        let other = NSMenuItem(title: "Anderer Ordner…",
                               action: #selector(chooseFolder),
                               keyEquivalent: "")
        other.target = self
        menu.addItem(other)

        // Direkt unter dem Button aufklappen. In der (nicht gespiegelten)
        // Superview ist frame.minY die Unterkante des Buttons — von dort
        // wächst das Menü nach unten.
        if let host = folderButton.superview {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: folderButton.frame.minX,
                                   y: folderButton.frame.minY),
                       in: host)
        }
    }

    /// Ein Ordner-Eintrag mit Icon, Tooltip (Pfad, ~-gekürzt) und Häkchen,
    /// falls es der gerade aktive Suchordner ist.
    func addFolderItem(to menu: NSMenu, title: String, path: String) {
        let item = NSMenuItem(title: title, action: #selector(pickFolder(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = path
        item.toolTip = abbreviateHome(path)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        item.image = icon
        if path == searchRoot.path { item.state = .on }
        menu.addItem(item)
    }

    @objc func pickFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        setSearchRoot(URL(fileURLWithPath: path))
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = searchRoot
        panel.prompt = "Hier suchen"
        if panel.runModal() == .OK, let url = panel.url {
            setSearchRoot(url)
        }
    }

    // ---------- RegEx: Vorlagen + Syntaxfärbung ----------

    /// Klick auf „Regex-Vorlagen": aufklappende Liste nach Kategorien.
    @objc func showTemplatesMenu(_ sender: NSButton) {
        let menu = NSMenu()
        var lastCategory: String?
        for template in regexTemplates {
            if template.category != lastCategory {
                if lastCategory != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: template.category, action: nil,
                                        keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastCategory = template.category
            }
            let item = NSMenuItem(title: template.name,
                                  action: #selector(insertTemplate(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = template.regex
            item.toolTip = "\(template.regex)   —   z. B. \(template.example)"
            menu.addItem(item)
        }
        if let host = sender.superview {
            menu.popUp(positioning: nil,
                       at: NSPoint(x: sender.frame.minX, y: sender.frame.minY),
                       in: host)
        }
    }

    /// Vorlage übernehmen: ins Suchfeld setzen, Regex-Modus an, einfärben.
    @objc func insertTemplate(_ sender: NSMenuItem) {
        guard let regex = sender.representedObject as? String else { return }
        regexCheckbox.state = .on
        searchField.stringValue = regex
        window.makeFirstResponder(searchField)
        recolorRegexField()
    }

    /// Regex-Checkbox umgeschaltet → Feld ein-/ausfärben.
    @objc func regexToggled() { recolorRegexField() }

    /// Live-Färbung des Suchfelds beim Tippen (nur im Regex-Modus).
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, pixelFields.contains(where: { $0 === field }) {
            // Die sichtbare Konfiguration gehört ab jetzt zu einem neuen
            // Lauf. Alte Treffer dürfen keinen neuen Fehlerstatus überholen.
            stopSearch()
            progressPath = nil
            if validatePixelInputs() {
                searchPhase = .idle
                refreshStatus()
            }
            return
        }
        guard notification.object as? NSSearchField === searchField else { return }
        recolorRegexField()
    }

    /// Färbt den Suchtext nach RegEx-Token-Art ein (Schema von Fastra) —
    /// oder setzt ihn auf die Standardfarbe zurück, wenn Regex aus ist.
    /// Verändert nur Farb-Attribute, nie den Text → Cursor bleibt stehen.
    func recolorRegexField() {
        let editor = searchField.currentEditor() as? NSTextView
        let text = editor?.string ?? searchField.stringValue
        let full = NSRange(location: 0, length: (text as NSString).length)
        let regexOn = regexCheckbox.state == .on
        let base: NSColor = regexOn ? RegexHighlighter.literalColor
                                    : .textColor

        if let storage = editor?.textStorage {
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: full)
            storage.addAttribute(.foregroundColor, value: base, range: full)
            if regexOn {
                for (range, kind) in RegexHighlighter.tokenize(text) {
                    storage.addAttribute(.foregroundColor,
                                         value: RegexHighlighter.color(for: kind),
                                         range: range)
                }
            }
            storage.endEditing()
            editor?.typingAttributes[.foregroundColor] = base
        } else {
            // Feld nicht im Fokus → über den attributierten Wert färben.
            let attributed = NSMutableAttributedString(string: text)
            attributed.addAttribute(.foregroundColor, value: base, range: full)
            if regexOn {
                for (range, kind) in RegexHighlighter.tokenize(text) {
                    attributed.addAttribute(.foregroundColor,
                                            value: RegexHighlighter.color(for: kind),
                                            range: range)
                }
            }
            searchField.attributedStringValue = attributed
        }
    }

    @objc func startSearch() {
        stopSearch()
        // Frische Suche: Tabelle leeren und von vorn sammeln. Auch das leere
        // Modell geht über applyHitsToTable — sonst gäbe es doch wieder einen
        // Weg an der Sortierung vorbei, und genau daran krankten vorher
        // continueSearch() und loadResults().
        hits = []
        pending = []
        seenPaths = []
        trashedPaths = TrashedPaths()
        applyHitsToTable(keepingSelection: [])
        guard validatePixelInputs() else { return }
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        statistics = HitStatistics()
        skippedCount = 0
        searchPhase = .idle
        progressPath = nil
        // Ohne Muster nur dann suchen, wenn ein Maß- oder Faktenfilter gesetzt ist —
        // „alle Bilder über 1000 px" ist eine vollständige Frage.
        guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter else {
            refreshStatus()
            return
        }
        launchSearch(pattern: pattern)
    }

    var searchConfiguration: SearchConfiguration {
        var configuration = SearchConfiguration()
        configuration.mode = selectedMode
        configuration.archives = archivesCheckbox.state == .on
        configuration.includeHidden = hiddenCheckbox.state == .on
        configuration.exact = exactCheckbox.state == .on
        configuration.pixelTexts = pixelFields.map { $0.stringValue }
        configuration.exclusions = filterView.exclusions
        configuration.rawFacts = filterView.rawFacts
        configuration.regex = regexCheckbox.state == .on
        configuration.caseSensitive = caseCheckbox.state == .on
        configuration.metadataField = selectedMetadataField
        configuration.only = ["both", "files", "dirs"][max(0, min(2, typeControl.selectedSegment))]
        return configuration
    }

    var pixelFields: [NSTextField] {
        [minWidthField, maxWidthField, minHeightField, maxHeightField]
    }

    var pixelLimits: PixelLimits { validatePixelFields(pixelFields).limits }

    /// Kein Start und keine Übergabe darf ungültige sichtbare Grenzen ignorieren.
    @discardableResult
    func validatePixelInputs() -> Bool {
        let result = validatePixelFields(pixelFields)
        if let error = result.error {
            searchPhase = .failed(error)
            refreshStatus()
            return false
        }
        return true
    }

    var selectedMode: SearchTextMode {
        SearchTextMode.allCases[
            max(0, min(SearchTextMode.allCases.count - 1,
                       modeControl.selectedSegment))]
    }

    func selectMode(_ mode: SearchTextMode) {
        modeControl.selectedSegment =
            SearchTextMode.allCases.firstIndex(of: mode) ?? 0
        fieldPopup.isHidden = mode != .metadata
    }

    /// Das gewählte Metadatenfeld — nil heißt „alle Textfelder".
    var selectedMetadataField: String? {
        guard selectedMode == .metadata, fieldPopup.indexOfSelectedItem > 0
        else { return nil }
        return fieldPopup.titleOfSelectedItem
    }

    func selectMetadataField(_ field: String?) {
        if let field, fieldPopup.itemTitles.contains(field) {
            fieldPopup.selectItem(withTitle: field)
        } else {
            fieldPopup.selectItem(at: 0)
        }
    }

    @objc func modeChanged() {
        fieldPopup.isHidden = selectedMode != .metadata
    }

    /// Fertige Treffer der Schnellsuche (≤20) sofort zeigen und die Suche
    /// hier LIVE fortsetzen. Die schon gezeigten Treffer werden über
    /// `seenPaths` nicht doppelt gelistet.
    func continueSearch(from file: URL) {
        guard let seed = consumeQuickHandoff(file) else {
            searchPhase = .failed("Ungültige oder zu große Ergebnisübergabe.")
            refreshStatus()
            return
        }
        stopSearch()
        hits = seed
        pending = []
        seenPaths = Set(seed.map { $0.path })
        trashedPaths = TrashedPaths()
        statistics = .over(hits)
        skippedCount = 0
        searchPhase = .handedOver
        progressPath = nil
        applyHitsToTable(keepingSelection: [])
        guard validatePixelInputs() else { return }
        let pattern = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        // Wie startSearch(): ohne Muster nur weitersuchen, wenn ein
        // Maß- oder Faktenfilter gesetzt ist. Die Schnellsuche übergibt genau so eine
        // reine Maßsuche, und die Fortsetzung darf sie nicht abbrechen.
        guard !pattern.isEmpty || searchConfiguration.hasPositiveFilter else {
            refreshStatus()
            return
        }
        launchSearch(pattern: pattern)
    }

    /// Startet den Suchprozess und streamt Treffer in die (evtl. schon per
    /// `continueSearch` vorbelegte) Tabelle. Setzt hits/seenPaths NICHT
    /// zurück — das machen die Aufrufer je nach Fall.
    func launchSearch(pattern: String) {
        guard validatePixelInputs() else { return }
        guard let arguments = searchConfiguration.arguments(
            pattern: pattern, root: searchRoot.path, progress: true)
        else {
            searchPhase = .failed("favenio.py nicht gefunden.")
            refreshStatus()
            return
        }

        let run = SearchRunner()
        activeSearchRun = run
        run.start(arguments: arguments, onBatch: { [weak self, weak run] hits, progress in
            guard let self, let run, self.activeSearchRun === run else { return }
            if let progress {
                self.progressPath = progress
                self.refreshStatus()
            }
            for hit in hits where !self.trashedPaths.contains(hit.filesystemPath) {
                if self.seenPaths.insert(hit.path).inserted { self.pending.append(hit) }
            }
        }, completion: { [weak self, weak run] exit in
            guard let self, let run, self.activeSearchRun === run else { return }
            self.finishSearchRun(run, exit: exit)
        })
        stopButton.isEnabled = true
        skippedCount = 0
        searchPhase = .running
        progressPath = nil
        refreshStatus()
        // Die Tabelle nicht bei jedem einzelnen Treffer neu laden,
        // sondern gebündelt ein paar Mal pro Sekunde.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.15,
                                          repeats: true) { [weak self] _ in
            self?.flushPending()
        }
    }

    func stopSearch() {
        let run = activeSearchRun
        activeSearchRun = nil
        run?.cancel()
        flushTimer?.invalidate()
        flushTimer = nil
        stopButton.isEnabled = false
    }

    /// Klick auf den Stopp-Button: laufende Suche abbrechen.
    @objc func stopSearchClicked() {
        guard activeSearchRun != nil else { return }
        stopSearch()
        searchPhase = .stopped
        progressPath = nil
        flushPending()
        refreshStatus()
    }

    /// Sortieren, neu laden und dieselben Treffer wieder auswählen.
    ///
    /// Jede Trefferübernahme muss hier durch: `continueSearch()` und
    /// `loadResults()` luden vorher einfach neu und wandten eine bereits
    /// aktive Sortierung nicht an. Enthielt der fortgesetzte Lauf nur die
    /// übergebenen Treffer, blieb `pending` leer, `flushPending()` lief nie —
    /// und die Kopfzeile zeigte eine Sortierung, der die Liste nicht folgte
    /// (Review-Fund 2026-08-17).
    ///
    /// `reloadData()` behält die Auswahl nach ZEILENNUMMER. Nach Sortieren,
    /// Entfernen oder einer Übergabe aus der Schnellsuche zeigt dieselbe
    /// Nummer auf einen anderen Treffer; deshalb wird die Auswahl vorher
    /// geleert und danach ausschließlich pfadbasiert gesetzt — auch bei
    /// leerer Pfadmenge (Review-Fund 2026-09-02). Die Zwischenschritte lösen
    /// keine Auswahl-Benachrichtigung aus, sonst flackerte die Vorschau bei
    /// jedem Nachschub; am Ende wird sie nur nachgeladen, wenn sie jetzt
    /// andere Dateien meint.
    func applyHitsToTable(keepingSelection selectedPaths: Set<String>,
                          resort: Bool = true) {
        if resort { sortHits() }
        isRestoringSelection = true
        tableView.deselectAll(nil)
        tableView.reloadData()
        let rows = IndexSet(hits.indices.filter {
            selectedPaths.contains(hits[$0].path)
        })
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isRestoringSelection = false
        contextRow = -1
        reloadPreviewIfSelectionChanged()
    }

    /// Offene Vorschau nachziehen, wenn die Auswahl jetzt andere Dateien
    /// meint als die, die sie zeigt.
    func reloadPreviewIfSelectionChanged() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared().isVisible else { return }
        let shown = previewURLs
        rebuildPreviewURLs()
        if previewURLs != shown { QLPreviewPanel.shared().reloadData() }
    }

    func flushPending() {
        guard !pending.isEmpty else { return }
        // Auswahl über den reloadData hinweg festhalten (sonst verliert man
        // beim Streamen sofort wieder die markierte Zeile — etwa fürs
        // QuickLook). Wir merken die Pfade und stellen sie danach wieder her.
        let selectedPaths = selectedHitPaths()
        // Kennzahlen FORTSCHREIBEN statt neu aufsummieren: Bei einem langen
        // Lauf wird diese Methode viele Male aufgerufen, und jedes Mal die
        // ganze Liste durchzurechnen kostete quadratisch.
        for hit in pending { statistics.add(hit) }
        if let comparator = hitComparator() {
            mergeSortedHits(pending, using: comparator)
        } else {
            hits.append(contentsOf: pending)
        }
        pending = []
        // `resort: false`: Die Liste ist gerade schon in der richtigen
        // Ordnung — entweder eingemischt oder unsortiert angehängt.
        applyHitsToTable(keepingSelection: selectedPaths, resort: false)
        refreshStatus()
    }

    func finishSearchRun(_ run: SearchRunner, exit: SearchExit) {
        guard activeSearchRun === run else { return }
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        activeSearchRun = nil
        stopButton.isEnabled = false
        progressPath = nil
        skippedCount = exit.warningCount
        searchPhase = searchExitIsError(exit.status, reason: exit.reason)
            ? .failed(searchFailureText(exit)) : .finished
        refreshStatus()
    }

    // ---------- Tabelle ----------

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    /// Welche Datumsstufe eine Datumsspalte bei ihrer aktuellen Breite
    /// zeigt. Die Zelle hat je 2 pt Rand, und ein Muster, das haargenau
    /// passt, kürzte AppKit trotzdem mit „…" — deshalb 8 pt Luft.
    func dateStage(for column: NSTableColumn) -> Int {
        let key = column.identifier.rawValue
        if let known = dateStages[key], known.width == column.width {
            return known.stage
        }
        let stage = dateColumnStage(forWidth: column.width - 8,
                                    font: dateFont)
        dateStages[key] = (column.width, stage)
        return stage
    }

    @objc func columnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"]
                as? NSTableColumn,
              Self.dateColumns.contains(column.identifier.rawValue),
              let previous = dateStages[column.identifier.rawValue]?.stage
        else { return }
        guard dateStage(for: column) != previous else { return }
        let columnIndex = tableView.column(withIdentifier: column.identifier)
        guard columnIndex >= 0 else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn:
                visible.location ..< visible.location + visible.length),
            columnIndexes: IndexSet(integer: columnIndex))
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        // `row < hits.count` ist Pflicht, nicht Vorsicht: applyHitsToTable
        // verkleinert `hits` VOR dem reloadData(), und dazwischen laufen
        // noch sortHits() und deselectAll(nil) — NSTableView hält solange
        // die alte Zeilenzahl. Fragt AppKit in diesem Fenster dann eine
        // Zelle für eine Zeile jenseits des Endes an, beendete sich die App
        // mit „Index out of range". Die Schnellsuche hatte die Prüfung an
        // dieser Stelle immer, die Haupt-App nicht.
        guard let column = tableColumn, row < hits.count else { return nil }
        var cell = tableView.makeView(withIdentifier: column.identifier,
                                      owner: nil) as? NSTableCellView
        if cell == nil {
            // Zellen einmal bauen, danach werden sie recycelt.
            let newCell = NSTableCellView()
            newCell.identifier = column.identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            newCell.addSubview(label)
            newCell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(
                    equalTo: newCell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(
                    equalTo: newCell.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(
                    equalTo: newCell.centerYAnchor),
            ])
            cell = newCell
        }
        let hit = hits[row]
        // Zellen werden recycelt → Ausrichtung je Spalte neu setzen.
        let identifier = column.identifier.rawValue
        cell?.textField?.alignment =
            ["size", "dims"].contains(identifier) ? .right : .left
        // Der Pfad wird AM ANFANG gekürzt: Das Ende — der Ordner, in dem
        // die Datei liegt — ist der Teil, der unterscheidet; der Anfang
        // ist bei allen Treffern derselbe Suchordner.
        cell?.textField?.lineBreakMode =
            identifier == "path" ? .byTruncatingHead : .byTruncatingMiddle
        cell?.textField?.font = Self.dateColumns.contains(identifier)
            ? dateFont : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        cell?.textField?.toolTip = nil
        switch identifier {
        case "name":
            cell?.textField?.stringValue = hit.displayName
        case "type":
            cell?.textField?.stringValue = hit.typeDescription
        case "size":
            cell?.textField?.stringValue = humanSize(hit.size)
        case "line":
            // Zeilennummer bei Inhaltstreffern, „Feld: Wert" bei Metadaten.
            cell?.textField?.stringValue = hit.locationText
        case "dims":
            cell?.textField?.stringValue = hit.dimensionsText
        case "modified":
            cell?.textField?.stringValue =
                formatDateColumn(hit.modified, stage: dateStage(for: column))
        case "created":
            cell?.textField?.stringValue =
                formatDateColumn(hit.created, stage: dateStage(for: column))
        default:
            // Nur der Ordner, relativ zum Suchordner — der Dateiname steht
            // schon in der ersten Spalte, der Suchordner im Ordnerknopf.
            cell?.textField?.stringValue =
                hit.folderText(relativeTo: searchRoot.path)
            cell?.textField?.toolTip = hit.folderPath
        }
        return cell
    }

    /// Header-Klick: Trefferliste nach der gewählten Spalte sortieren.
    func tableView(_ tableView: NSTableView,
                   sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyHitsToTable(keepingSelection: selectedHitPaths())
    }

    /// Sortiert `hits` nach dem aktiven Sortierkriterium (oder lässt die
    /// Einfüge-Reihenfolge, wenn keins gesetzt ist).
    /// Der aktive Vergleicher der Trefferliste — oder nil, wenn der Nutzer
    /// keine Spalte zum Sortieren gewählt hat.
    func hitComparator() -> ((Hit, Hit) -> Bool)? {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else { return nil }
        let ascending = descriptor.ascending
        return { compareHits($0, $1, key: key, ascending: ascending) }
    }

    func sortHits() {
        guard let comparator = hitComparator() else { return }
        hits.sort(by: comparator)
    }

    /// Fügt frische Treffer in die BEREITS sortierte Liste ein.
    ///
    /// Vorher sortierte jeder Nachschub die ganze Liste neu — der Flush
    /// läuft alle 0,15 s, also bis zu siebenmal pro Sekunde. Der Aufwand
    /// wuchs damit über den Lauf hinweg quadratisch: Bei 100 000 Treffern
    /// kostete ein einzelner Sortierlauf 1,2 s auf dem Main-Thread (vor
    /// dem Typ-Zwischenspeicher sogar 46,6 s), und das siebenmal je
    /// Sekunde. Einsortieren ist dagegen linear: Der Nachschub wird
    /// einmal sortiert und dann zusammengeführt.
    func mergeSortedHits(_ fresh: [Hit],
                         using comparator: (Hit, Hit) -> Bool) {
        var frisch = fresh
        frisch.sort(by: comparator)
        var zusammen: [Hit] = []
        zusammen.reserveCapacity(hits.count + frisch.count)
        var links = hits.startIndex
        var rechts = frisch.startIndex
        while links < hits.endIndex && rechts < frisch.endIndex {
            if comparator(frisch[rechts], hits[links]) {
                zusammen.append(frisch[rechts])
                rechts += 1
            } else {
                zusammen.append(hits[links])
                links += 1
            }
        }
        zusammen.append(contentsOf: hits[links...])
        zusammen.append(contentsOf: frisch[rechts...])
        hits = zusammen
    }

    /// Drag & Drop: die gezogene Zeile liefert eine Datei-URL —
    /// Archiv-Einträge werden dafür beim Anfassen ausgepackt.
    func tableView(_ tableView: NSTableView,
                   pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < hits.count,
              let url = materializeHit(hits[row]) else { return nil }
        return url as NSURL
    }

    // ---------- Aktionen (Doppelklick, Kontextmenü) ----------

    /// Zeilen, auf die sich eine Aktion bezieht: die Auswahl, oder —
    /// falls außerhalb der Auswahl geklickt wurde — die geklickte Zeile.
    /// Was sich nicht öffnen ließ, steht in der Fußzeile.
    override func presentActionIssue(summary: String, detail: String?) {
        statusLabel.stringValue = detail.map { summary + " " + $0 } ?? summary
    }

    /// Der Doppelklick-Weg. Hier gilt, worauf geklickt wurde — und wenn
    /// das NICHTS war, die Auswahl.
    ///
    /// `clickedRow` ist -1 bei einem Doppelklick unter der letzten Zeile.
    /// Vorher blieb dann der `contextRow` eines früheren Rechtsklicks
    /// stehen und bestimmte die Aktion: Wer Zeile 2 markiert, auf Zeile 7
    /// rechtsklickt, das Menü mit ⎋ schließt und dann in den leeren Bereich
    /// doppelklickt, öffnete Datei 7. Dieselbe Regel wie im Hauptmenü
    /// (`rows(for:)`): Ohne Klickort gilt die Auswahl.
    @objc func openSelected() {
        contextRow = tableView.clickedRow
        openActionRows()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        contextRow = tableView.clickedRow
        guard contextRow >= 0, contextRow < hits.count else { return }
        // ALLE öffnenbaren Treffer, nicht nur der erste: `ctxOpenWith`
        // übergibt später sämtliche materialisierten URLs an die gewählte App,
        // also muss das Menü über dieselbe Menge entscheiden.
        let applicationHits = actionRows().compactMap {
            hits.indices.contains($0) ? hits[$0] : nil
        }.filter { $0.hasOpenableFile }
        populateHitContextMenu(
            menu, applicationHits: applicationHits, target: self,
            selectors: HitContextMenuSelectors(
                preview: #selector(togglePreview), open: #selector(ctxOpen),
                openWith: #selector(ctxOpenWith(_:)),
                reveal: #selector(ctxReveal),
                copyPath: #selector(ctxCopyPath)))
        // Dieselben Listen-Aktionen wie im Ablage-Menü, mit denselben
        // Kürzeln daneben. Sie hängen nicht an einer öffenbaren Datei: Auch
        // ein Ordner im Archiv lässt sich aus der Liste werfen.
        menu.addItem(.separator())
        addResultListItems(to: menu)
    }

    /// Die drei Punkte, die auf die Trefferliste wirken — einmal gebaut, in
    /// beiden Menüs verwendet. Gebaut werden sie im Kern; hier stehen nur die
    /// Methoden, die sie aufrufen sollen.
    func addResultListItems(to menu: NSMenu) {
        populateResultListMenu(
            menu, target: self,
            selectors: ResultListMenuSelectors(
                exportSelection: #selector(exportSelectedHits(_:)),
                removeFromList: #selector(removeFromResults(_:)),
                moveToTrash: #selector(trashSelected(_:))))
    }

    /// Aus dem Rechtsklick-Menü: Dort hat `menuNeedsUpdate` den `contextRow`
    /// gesetzt, und der gilt — deshalb NICHT über `openSelected`, das ihn
    /// für den Doppelklick-Weg neu bestimmt.
    @objc func ctxOpen() { openActionRows() }

    private func openActionRows() {
        let selection = actionSelection()
        selection.urls.forEach { NSWorkspace.shared.open($0) }
        showActionIssue(selection)
    }

    // ---------- Trefferliste verfeinern, exportieren, löschen ----------

    /// „Ablage"-Menü: Export, Entfernen aus der Trefferliste und Papierkorb.
    /// Die Tastenkürzel stehen hier sichtbar daneben, damit sie niemand
    /// erraten muss.
    func installFileMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Ablage")
        let exportAll = fileMenu.addItem(
            withTitle: "Alle Treffer exportieren…",
            action: #selector(exportAllHits(_:)), keyEquivalent: "e")
        exportAll.target = self
        fileMenu.addItem(.separator())
        addResultListItems(to: fileMenu)
        fileItem.submenu = fileMenu
        // Direkt hinter das App-Menü, also vor „Ansicht".
        mainMenu.insertItem(fileItem, at: min(1, mainMenu.numberOfItems))
    }

    /// Zeilen, die eine Menüaktion meint.
    ///
    /// Aus dem Rechtsklick-Menü der Tabelle gilt die AppKit-Konvention: Ein
    /// Klick außerhalb der Auswahl meint nur die geklickte Zeile. Aus dem
    /// Hauptmenü und vom Tastenkürzel gilt dagegen immer die Auswahl — dort
    /// gibt es keinen Klickort, und ein liegengebliebener `contextRow` eines
    /// früheren Rechtsklicks träfe sonst die falschen Dateien.
    func rows(for sender: Any?) -> [Int] {
        if let item = sender as? NSMenuItem, item.menu === tableView.menu {
            return actionRows()
        }
        return Array(tableView.selectedRowIndexes)
    }

    /// Die Treffer zu einer Zeilenmenge, in Listenreihenfolge.
    func hitsAtRows(_ rows: [Int]) -> [Hit] {
        rows.sorted().compactMap { hits.indices.contains($0) ? hits[$0] : nil }
    }

    /// Ein ungültiger Menüpunkt gibt sein Tastenkürzel wieder frei. Genau
    /// deshalb löscht ⌫ im Suchfeld weiter ein Zeichen und ⌘⌫ dort weiter bis
    /// zum Zeilenanfang, statt an Dateien zu gehen: Beide Punkte gelten nur,
    /// solange die Trefferliste den Fokus hat. Im Rechtsklick-Menü der
    /// Tabelle entfällt diese Bedingung — dort ist der Bezug der Klick.
    ///
    /// Dieselbe Bedingung wie beim Tastaturmonitor: Das Hauptfenster muss das
    /// Tastaturfenster sein. Solange ein Blatt oder ein Alert offen ist,
    /// bleiben alle vier Punkte grau — sonst startete ⌘⌫ aus dem Exportdialog
    /// heraus einen zweiten Papierkorb-Dialog. „Alle Treffer exportieren"
    /// braucht keine Auswahl und deshalb auch keinen Tabellenfokus.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let fromTableMenu = item.menu === tableView.menu
        let mainWindowIsKey = window?.isKeyWindow == true
        switch item.action {
        case #selector(removeFromResults(_:)), #selector(trashSelected(_:)),
             #selector(exportSelectedHits(_:)):
            guard fromTableMenu
                    || (mainWindowIsKey
                        && window?.firstResponder === tableView)
            else { return false }
            return !rows(for: item).isEmpty
        case #selector(exportAllHits(_:)):
            return mainWindowIsKey && !hits.isEmpty
        default:
            return true
        }
    }

    /// ⌫ bzw. Menü: Treffer nur aus der ANZEIGE werfen. Die Dateien bleiben
    /// unangetastet — das dient dem schrittweisen Verfeinern der Liste, bis
    /// nur noch übrig ist, was wirklich gemeint war.
    @objc func removeFromResults(_ sender: Any?) {
        let doomed = Set(hitsAtRows(rows(for: sender)).map { $0.path })
        guard !doomed.isEmpty else {
            statusLabel.stringValue = "Kein Treffer ausgewählt."
            return
        }
        let removed = removeHits { doomed.contains($0.path) }
        statusLabel.stringValue = removed == 1
            ? "1 Treffer aus der Liste entfernt — die Datei bleibt."
            : "\(groupedNumber(removed)) Treffer aus der Liste entfernt — "
                + "die Dateien bleiben."
    }

    /// Entfernt Treffer aus der Liste und stellt Kennzahlen, Sortierung und
    /// Auswahl wieder her. Danach steht die Auswahl auf der Zeile, die an die
    /// Stelle der ersten entfernten gerückt ist.
    @discardableResult
    func removeHits(where shouldRemove: (Hit) -> Bool) -> Int {
        guard let firstRemoved = hits.firstIndex(where: shouldRemove) else {
            return 0
        }
        let before = hits.count
        hits.removeAll(where: shouldRemove)
        // `seenPaths` bleibt unangetastet: Ein noch laufender Suchlauf soll
        // einen bewusst entfernten Treffer nicht gleich wieder einfügen.
        statistics = .over(hits)
        applyHitsToTable(keepingSelection: [])
        if !hits.isEmpty {
            tableView.selectRowIndexes(
                [min(firstRemoved, hits.count - 1)], byExtendingSelection: false)
        }
        refreshStatus()
        return before - hits.count
    }

    /// ⌘⌫ bzw. Menü: Die ausgewählten Dateien in den Papierkorb legen — nach
    /// Rückfrage, in EINEM `recycle`-Aufruf (damit auch eine sehr große
    /// Auswahl nicht Datei für Datei abgearbeitet wird) und mit dem
    /// Papierkorb-Geräusch des Finders.
    @objc func trashSelected(_ sender: Any?) {
        let targets = hitsAtRows(rows(for: sender))
        let split = trashableHits(targets)
        guard !split.trashable.isEmpty else {
            statusLabel.stringValue = targets.isEmpty
                ? "Kein Treffer ausgewählt."
                : "Einträge in einem Archiv lassen sich nicht löschen."
            return
        }
        let text = trashConfirmationText(trashable: split.trashable,
                                         skipped: split.skipped)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        trashHits(split.trashable) { [weak self] trashed, error in
            guard let self else { return }
            guard !trashed.isEmpty else {
                self.statusLabel.stringValue = "Nichts in den Papierkorb "
                    + "gelegt: " + (error?.localizedDescription
                                    ?? "unbekannter Fehler")
                return
            }
            playFinderTrashSound()
            // Mit einem Archiv verschwinden auch seine Einträge aus der
            // Liste, mit einem Ordner alles darunter: Hinter ihnen liegt
            // jetzt keine Datei mehr. Dasselbe gilt für schon vorgemerkte
            // und für noch eintreffende Treffer des laufenden Suchprozesses.
            for hit in split.trashable where trashed[hit.filesystemPath] != nil {
                self.trashedPaths.insert(hit.filesystemPath,
                                         isDirectory: hit.isDirectory)
            }
            self.pending.removeAll {
                self.trashedPaths.contains($0.filesystemPath)
            }
            self.removeHits { self.trashedPaths.contains($0.filesystemPath) }
            let failed = split.trashable.count - trashed.count
            let moved = "\(groupedNumber(trashed.count)) in den Papierkorb "
                + "gelegt"
            self.statusLabel.stringValue = failed == 0
                ? moved + "."
                : moved + ", \(groupedNumber(failed)) nicht: "
                    + (error?.localizedDescription ?? "unbekannter Fehler")
        }
    }

    @objc func exportAllHits(_ sender: Any?) {
        runExport(hits, scope: "alle Treffer")
    }

    @objc func exportSelectedHits(_ sender: Any?) {
        runExport(hitsAtRows(rows(for: sender)), scope: "Auswahl")
    }

    /// Vorschlag für den Dateinamen: der Suchbegriff, von allem befreit, was
    /// in einem Dateinamen nichts zu suchen hat.
    func exportBaseName() -> String {
        let query = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "Favenio-Treffer" }
        let cleaned = query.components(
            separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(
                separator: "-")
        return "Favenio-" + String(cleaned.prefix(60))
    }

    /// Sichern-Dialog mit Format-Aufklappmenü und anschließendes Schreiben.
    func runExport(_ selected: [Hit], scope: String) {
        guard !selected.isEmpty else {
            statusLabel.stringValue = "Kein Treffer zum Exportieren."
            return
        }
        let formats = HitExportFormat.allCases
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0,
                                                width: 340, height: 26))
        formats.forEach { popUp.addItem(withTitle: $0.title) }
        popUp.target = self
        popUp.action = #selector(exportFormatChanged(_:))
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popUp])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        let panel = NSSavePanel()
        panel.message = "Trefferliste exportieren (\(scope))"
        panel.nameFieldStringValue = exportBaseName() + "."
            + formats[0].fileExtension
        panel.accessoryView = row
        exportSavePanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.exportSavePanel = nil
            guard response == .OK, let url = panel.url,
                  let self else { return }
            let format = formats[max(0, popUp.indexOfSelectedItem)]
            do {
                try exportData(for: selected, format: format)
                    .write(to: url, options: .atomic)
                self.statusLabel.stringValue =
                    "\(groupedNumber(selected.count)) Treffer exportiert: "
                    + abbreviateHome(url.path)
            } catch {
                self.statusLabel.stringValue = "Export fehlgeschlagen: "
                    + error.localizedDescription
            }
        }
    }

    /// Anderes Format gewählt → Endung im Dateinamen mitziehen.
    @objc func exportFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = exportSavePanel else { return }
        let format = HitExportFormat.allCases[
            max(0, sender.indexOfSelectedItem)]
        let base = (panel.nameFieldStringValue as NSString)
            .deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.fileExtension
    }
}

// MARK: - RegEx-Syntaxfärbung (Farbschema von Fastra übernommen)
//
// Fastra tokenisiert mit tree-sitter; das ist für Favenios Ein-Datei-Prinzip
// zu schwer. Hier ein schlanker linearer Scanner, der dieselben Token-Arten
// und exakt dieselben Farben (Fastra Theme/RegexFieldView) liefert.

enum RegexTokenKind {
    case anchor          // ^ $ \b \B
    case characterClass  // [...] \d \w \s .
    case quantifier      // * + ? {n,m}
    case groupDelimiter  // ( ) (?: (?<name> (?= …
    case alternation     // |
    case escape          // \. \n \t …
    case backreference   // \1 \k<name>
    case error           // unvollständig (offene Klasse, Backslash am Ende)
}

enum RegexHighlighter {
    /// Basisfarbe für gewöhnliche Zeichen (Lesbarkeit, kein Akzent).
    static let literalColor = NSColor.textColor

    /// Dynamische Farbe je Token-Art — Werte 1:1 aus Fastra.
    static func color(for kind: RegexTokenKind) -> NSColor {
        func pair(_ l: (Int, Int, Int), _ d: (Int, Int, Int)) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua])
                    == .darkAqua
                let (r, g, b) = dark ? d : l
                return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                               blue: CGFloat(b) / 255, alpha: 1)
            }
        }
        switch kind {
        case .anchor:         return pair((0xA3, 0x39, 0x2A), (0xE8, 0x8D, 0x7C))
        case .characterClass: return pair((0x2A, 0x66, 0xB5), (0x7F, 0xB0, 0xEE))
        case .quantifier:     return pair((0xB5, 0x6C, 0x1A), (0xDF, 0xA2, 0x5A))
        case .groupDelimiter: return pair((0x70, 0x20, 0xA0), (0xC0, 0x8A, 0xE8))
        case .alternation:    return pair((0x1A, 0x40, 0x80), (0x86, 0xA9, 0xE0))
        case .escape:         return pair((0x2F, 0x5D, 0x3A), (0x94, 0xCE, 0x9F))
        case .backreference:  return pair((0xA4, 0x66, 0xD9), (0xC0, 0x9A, 0xE8))
        case .error:          return pair((0xCC, 0x00, 0x00), (0xFF, 0x6B, 0x5E))
        }
    }

    /// Zerlegt das Muster in gefärbte Token. Gewöhnliche Zeichen werden NICHT
    /// als Token ausgegeben — sie behalten die Basisfarbe. Ranges sind
    /// UTF-16-NSRange (dieselbe Einheit wie NSTextStorage).
    static func tokenize(_ pattern: String) -> [(NSRange, RegexTokenKind)] {
        let s = pattern as NSString
        let n = s.length
        var i = 0
        var out: [(NSRange, RegexTokenKind)] = []
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
        func push(_ location: Int, _ length: Int, _ kind: RegexTokenKind) {
            out.append((NSRange(location: location, length: length), kind))
        }
        while i < n {
            let c = s.character(at: i)
            switch c {
            case 0x5C:   // \  Backslash-Sequenz
                if i + 1 >= n { push(i, 1, .error); i += 1; break }
                let d = s.character(at: i + 1)
                switch d {
                case 0x62, 0x42:                               // b B → Anker
                    push(i, 2, .anchor); i += 2
                case 0x64, 0x44, 0x77, 0x57, 0x73, 0x53:       // d D w W s S
                    push(i, 2, .characterClass); i += 2
                case 0x31...0x39:                              // \1..\9
                    var j = i + 1
                    while j < n && isDigit(s.character(at: j)) { j += 1 }
                    push(i, j - i, .backreference); i = j
                case 0x6B:                                     // \k<name>
                    var j = i + 2
                    if j < n && s.character(at: j) == 0x3C {
                        while j < n && s.character(at: j) != 0x3E { j += 1 }
                        if j < n { j += 1 }
                    }
                    push(i, j - i, .backreference); i = j
                default:
                    push(i, 2, .escape); i += 2                // \. \n \( …
                }
            case 0x5E, 0x24:                                   // ^ $
                push(i, 1, .anchor); i += 1
            case 0x2E:                                         // .
                push(i, 1, .characterClass); i += 1
            case 0x5B:                                         // [  Zeichenklasse
                var j = i + 1
                if j < n && s.character(at: j) == 0x5E { j += 1 }   // ^
                if j < n && s.character(at: j) == 0x5D { j += 1 }   // ] direkt am Anfang
                while j < n && s.character(at: j) != 0x5D {
                    if s.character(at: j) == 0x5C { j += 1 }         // Escape überspringen
                    j += 1
                }
                if j < n { push(i, j - i + 1, .characterClass); i = j + 1 }
                else { push(i, n - i, .error); i = n }              // offen → Fehler
            case 0x28:                                         // (  Gruppe
                var len = 1
                if i + 1 < n && s.character(at: i + 1) == 0x3F {    // (?
                    if i + 2 < n {
                        let e = s.character(at: i + 2)
                        if e == 0x3A || e == 0x3D || e == 0x21 {     // (?: (?= (?!
                            len = 3
                        } else if e == 0x3C {                        // (?<
                            if i + 3 < n && (s.character(at: i + 3) == 0x3D
                                             || s.character(at: i + 3) == 0x21) {
                                len = 4                              // (?<= (?<!
                            } else {                                 // (?<name>
                                var j = i + 3
                                while j < n && s.character(at: j) != 0x3E { j += 1 }
                                if j < n { j += 1 }
                                len = j - i
                            }
                        } else { len = 2 }                           // (?flags
                    } else { len = 2 }
                }
                push(i, len, .groupDelimiter); i += len
            case 0x29:                                         // )
                push(i, 1, .groupDelimiter); i += 1
            case 0x7C:                                         // |
                push(i, 1, .alternation); i += 1
            case 0x2A, 0x2B, 0x3F:                             // * + ?
                push(i, 1, .quantifier); i += 1
            case 0x7B:                                         // {  evtl. {n,m}
                var j = i + 1
                var digits = 0
                while j < n && isDigit(s.character(at: j)) { j += 1; digits += 1 }
                if j < n && s.character(at: j) == 0x2C {        // ,
                    j += 1
                    while j < n && isDigit(s.character(at: j)) { j += 1 }
                }
                if digits > 0 && j < n && s.character(at: j) == 0x7D {
                    push(i, j - i + 1, .quantifier); i = j + 1
                } else {
                    i += 1                                     // literales {
                }
            default:
                i += 1                                         // Literal → Basisfarbe
            }
        }
        return out
    }
}

// MARK: - RegEx-Vorlagen (Auswahl aus Fastras Bibliothek, such-tauglich)

struct RegexTemplate {
    let name: String
    let category: String
    let regex: String
    let example: String
}

let regexTemplates: [RegexTemplate] = [
    // Identifikatoren
    .init(name: "E-Mail-Adresse", category: "Identifikatoren",
          regex: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
          example: "max.muster@example.com"),
    .init(name: "URL", category: "Identifikatoren",
          regex: #"https?://[\w.-]+(?:/[\w./?=&%#-]*)?"#,
          example: "https://example.com/path?q=1"),
    .init(name: "IPv4-Adresse", category: "Identifikatoren",
          regex: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, example: "192.168.1.1"),
    .init(name: "IBAN", category: "Identifikatoren",
          regex: #"[A-Z]{2}\d{2}[A-Z0-9]{1,30}"#,
          example: "DE89370400440532013000"),
    .init(name: "UUID", category: "Identifikatoren",
          regex: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
          example: "550e8400-e29b-41d4-a716-446655440000"),
    .init(name: "Hex-Farbe (#RRGGBB)", category: "Identifikatoren",
          regex: #"#(?:[0-9a-fA-F]{3}){1,2}\b"#, example: "#FF9900"),
    .init(name: "Versionsnummer (v1.2.3)", category: "Identifikatoren",
          regex: #"\bv?\d+\.\d+\.\d+\b"#, example: "v1.2.3"),
    .init(name: "Dateiname mit Endung", category: "Identifikatoren",
          regex: #"[\w.-]+\.[A-Za-z][A-Za-z0-9]{0,4}\b"#, example: "notiz.md"),
    // Datum & Zeit
    .init(name: "ISO-Datum (YYYY-MM-DD)", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})\b"#, example: "2026-07-13"),
    .init(name: "Deutsches Datum (DD.MM.YYYY)", category: "Datum & Zeit",
          regex: #"\b(\d{2})\.(\d{2})\.(\d{4})\b"#, example: "13.07.2026"),
    .init(name: "Uhrzeit", category: "Datum & Zeit",
          regex: #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b"#, example: "14:30:45"),
    .init(name: "ISO-Zeitstempel", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\b"#,
          example: "2026-07-13 15:30:00"),
    // Text & Struktur
    .init(name: "Markdown-Link", category: "Text & Struktur",
          regex: #"\[([^\]]+)\]\(([^)]+)\)"#,
          example: "[OpenAI](https://openai.com)"),
    .init(name: "Markdown-Überschrift", category: "Text & Struktur",
          regex: #"^(#{1,6})\s+(.+)$"#, example: "## Überschrift"),
    .init(name: "HTML-Tag", category: "Text & Struktur",
          regex: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#,
          example: #"<a href="…">"#),
    .init(name: "HTML-/XML-Kommentar", category: "Text & Struktur",
          regex: #"<!--[\s\S]*?-->"#, example: "<!-- Notiz -->"),
    // Zahlen
    .init(name: "Ganzzahl", category: "Zahlen",
          regex: #"-?\d+"#, example: "-42"),
    .init(name: "Dezimalzahl (deutsch)", category: "Zahlen",
          regex: #"-?\d+(?:\.\d{3})*,\d+"#, example: "1.234,56"),
    .init(name: "Telefonnummer (DE)", category: "Zahlen",
          regex: #"(?:\+49|0)[\s/-]?\d{2,5}[\s/-]?\d{4,8}"#,
          example: "+49 30 12345678"),
]
