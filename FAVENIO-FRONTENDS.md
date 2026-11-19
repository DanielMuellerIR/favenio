# Regeln für Favenio-Frontends

## Linux-Frontends

`linux/src` enthält die Rust/GTK-Oberflächen beider Apps. Suchsemantik bleibt in
`favenio.py`, gemeinsame Anwendungsregeln in `common`; keine parallele Rust-
Implementierung von Kriterien, Dubletten, Aufzeichnungen oder Fundstellen.
`linux/shared/Bridge.swift` ist die private, begrenzte C-Schnittstelle. Bibliothek,
Swift-Laufzeit und Helfer werden pro Version gemeinsam ausgeliefert. Native
Dateiaktionen verwenden die transportierten POSIX-Bytes, niemals Ersatzzeichenpfade.
PDF/OCR-Daten liefern unter Linux Poppler/Tesseract, unter macOS weiterhin
PDFKit/Vision. Linux-Leserfingerabdrücke binden nachgeladene Belege an Komponenten.
Bau, Installation, signierte Updates und Plattformgrenzen: `docs/LINUX.md`.

## Swift-Frontends

Beide Apps sind programmatische AppKit-Frontends ohne Xcode-Projekt.
`common/Thumbnails.swift` bildet dieselben Treffer und die kanonische Tabellenauswahl als Raster ab; Dateiaktionen und Archivmaterialisierung bleiben gemeinsam. Bei `NSCollectionView` muss das Layout vor den Item-/Headerklassen registriert werden. Reine Miniaturabrufe geben ihre Materialisierungs-Lease nach jedem Ausgang frei; ausdrückliche Dateiaktionen behalten den gemeinsamen Cacheeintrag.
`NSStackView(views:)` kann eine Ansicht beim Einhängen wieder sichtbar machen,
obwohl ihr `isHidden` vorher gesetzt wurde. Den anfänglichen Sichtbarkeitszustand
deshalb erst nach dem Einfügen in den Stack setzen und im App-Selbsttest prüfen.
Ein umbrechendes Label in einem Popover braucht außerdem eine feste Breite oder
eine gleichwertige Layout-Constraint; ohne sie kann AppKit den Inhalt als schmalen
Balken anordnen.
`HitIdentity` besteht aus `filesystemPath`, `archiveMembers` und
`archiveMemberBytes`. Vergleich und Hash verwenden die ursprünglichen
UTF-8-Bytes: Swifts kanonischer Stringvergleich würde unterschiedliche
Archivnamen mit NFC-/NFD-Schreibweise zusammenführen. Deduplikation,
Auswahlerhalt, Entfernen aus der Trefferliste und die Schlüssel von
Auspack-Zwischenspeicher und -Aufträgen (`MaterializationManager`) verwenden
diese Identität,
niemals den menschenlesbaren `Hit.path`: Ein Mitgliedsname darf selbst `!/`
enthalten. Und niemals den ganzen `Hit`-Wert: Anzeige und Suchbelege
(`line`, `terms`, `width`, `modified`) ändern sich mit der Suche, das
Objekt dahinter nicht. Bis 0.34.14 waren derselbe Archiv-Eintrag aus einer
Namenssuche und aus einer Inhaltssuche zwei Cache-Einträge, zwei
Unterprozesse und zwei Temp-Ordner — gegen die Zusage, dass gleichzeitige
Anforderungen desselben Treffers EINEN Unterprozess und dieselbe Datei
teilen. Anzeige und Export behalten ihren bisherigen Pfadtext.
`common/SearchModel.swift` enthält Hit-Modell und JSONL-Parsing;
`common/SearchProcess.swift` enthält Unterprozessaufrufe und den
`MaterializationManager`. `common/FavenioCore.swift` behält die AppKit-Darstellung
und Dateiaktionen. Änderungen am
JSONL-Schema zuerst im Kern und in gemeinsamen Tests spezifizieren, dann beide
Frontends anpassen.
Finder-Snapshots werden ausschließlich im Python-Kern erfasst. Swift prüft den
ursprünglichen JSON-Zweig vor Dictionary-Roundtrips über `JSONByteSlices` und
`FinderMetadataSnapshot`; führendes U+FEFF und Zahlenlexeme dürfen nicht vor der
Prüfung verändert werden. Snapshot-Gleichheit verwendet ursprüngliche Wertbytes,
Status und Generation, keine JSON-Einrückung. Die Formatwahl berücksichtigt auch
optional erfasste Werte in Treffern, nicht nur Kriterien. Vorschau, Spalten und
historischer Ansichtsfilter lesen keine Finder-Attribute nach; Datenvertrag und
Versionsgates stehen in [docs/FINDER_METADATA.md](docs/FINDER_METADATA.md).
Dort steht auch `HitListController`, die Basisklasse BEIDER Controller:
Trefferliste, wirksame Zeilenmenge (`actionRows`), Quick-Look-Vorschau samt
Tastenweiterleitung und die Kontextmenü-Aktionen „Öffnen mit", „Im Finder
zeigen" und „Pfad kopieren" gibt es genau einmal. Was eine App anders macht
(wohin eine Meldung geht: `presentActionIssue`), überschreibt sie. Eine
Korrektur an einem dieser Mechanismen gehört in die Basisklasse — bis 0.28.1
liefen die beiden Kopien auseinander, ein Wächter-Test verbietet neue Kopien.
Seit 0.34.17 gehören dazu auch der Aufbau des Rechtsklick-Menüs
(`populateHitMenu`, die Haupt-App hängt ihre Listen-Aktionen dahinter an),
der Zellbau samt Bereichsprüfung (`hitCell`), das Schließen einer offenen
Vorschau (`closeOpenPreview`, genutzt von beiden Tastaturmonitoren, von
`previewPanel(_:handle:)` und von `clearHits`) und die Normalisierung der
Zusatztasten (`plainModifiers(of:)`). Die letzte Kopie war schon
auseinandergelaufen: Die Haupt-App verlangte für ⎋ und die Leertaste
ausdrücklich keine Zusatztaste, die Schnellsuche prüfte gar nicht — dort
lösten deshalb auch ⇧⎋ und ⌥⎋ aus.
„Öffnen mit" bietet nur Anwendungen an, die JEDEN Treffer der wirksamen
Zeilenmenge öffnen (`commonApplicationsFor`). Diese Schnittmenge läuft je
ENDUNG, nicht je Treffer — beides: die LaunchServices-Abfrage und das
Schneiden selbst. Eine Endung, gegen die schon geschnitten wurde, kann
nichts mehr wegnehmen, denn die Menge ist seither nur kleiner geworden.
Bis 0.34.11 schnitt jeder Treffer erneut: bei 100 000 gleichartigen
Treffern 11,9 s statt 0,08 s, auf dem Main-Thread beim Öffnen des
Rechtsklick-Menüs (gemessen 2026-09-10, Ergebnis beide Male dieselben 31
Anwendungen). Dieselbe Fehlerklasse wie beim `TypeDescriptionCache`: nicht
die Abfrage war teuer, sondern die Arbeit je Treffer drumherum.
`tests/test_swift_guards.py::CommonApplicationsTest` führt die alte Fassung
mit und vergleicht die Anwendungslisten.

Beide Apps LESEN stderr des Kerns mit, statt ihn zu verwerfen
(`SearchDiagnostics`). Dort steht, WAS schiefging — „--metadata braucht
exiftool", „ungültiger regulärer Ausdruck" —, und jede Warnung über ein
übersprungenes Objekt. Nennt der Kern keinen Grund, gilt bei einem
gescheiterten Lauf ersatzweise die erste stderr-Zeile OHNE Favenio-Präfix
(seit 0.34.22): `/usr/bin/python3` ist ein Apple-Stummel, der ohne
akzeptierte Xcode-Lizenz „You have not agreed to the Xcode license
agreements" schreibt und mit Status 69 endet, ohne den Kern zu starten —
beide Apps zeigten dafür nur „Suche fehlgeschlagen (Status 69)"
(belegt 2026-09-15; Abhilfe `sudo xcodebuild -license accept`). Bis 0.27.1 hing die Pipe auf `nullDevice`: Die
Haupt-App zeigte nur „Suche fehlgeschlagen.", die Schnellsuche riet zu einer
Neuinstallation, die nichts half. Drei Eigenschaften sind dabei Pflicht und
je durch eine Wache festgehalten:

- Die Pipe wird NEBENLÄUFIG geleert (`collect(from:)`, vor `process.run()`).
  Eine volle stderr-Pipe hält den Kern an, während die App auf seine Treffer
  in stdout wartet — beide Seiten stehen dann. Belegt: mit 900 übersprungenen
  Objekten läuft der Selbsttest ohne dieses Leeren nicht zu Ende.
- Gezählt wird beim DURCHLAUFEN, nicht am Ende aus einem gedeckelten Text.
  Sonst wäre „470 Objekte übersprungen" falsch, wenn es 5000 waren.
- `finish()` schließt die Schreibseite VOR dem Lesen: `availableData`
  blockiert, solange irgendein Deskriptor die Pipe noch zum Schreiben offen
  hält — genau der Fall, wenn `process.run()` gescheitert ist.

`SearchConfiguration` ist die gemeinsame Quelle für Suchargumente, Quick-URL-
Encoder und -Decoder. Darauf bauen die benannten **Suchvorlagen** auf
(`SearchTemplate`, `SearchTemplateFormat`, `SearchTemplateStore` im Kern,
seit 0.33.0): Name, Muster, gespeicherter Suchordner und die Optionen als
Query der Quick-URL — dieselbe Kodierung, damit Vorlage, CLI-Argumente und
Übergabe dieselbe Suche beschreiben und Rohtexte unverändert bleiben. Die
Datei `~/Library/Application Support/Favenio/search-templates.json` trägt
eine `version`; eine höhere wird mit Nummer abgelehnt, unbekannte Felder
derselben Version werden überlesen. In der Haupt-App gibt es genau EINE
Stelle, die eine Konfiguration in die Oberfläche schreibt
(`applyConfiguration`); Quick-Übergabe und `applyTemplate` gehen beide
hindurch. `applyTemplate` färbt danach ausdrücklich nach
(`recolorRegexField`), denn `applyConfiguration` färbt zuletzt — aber noch
den ALTEN Feldinhalt; ein geladenes Regex-Muster stand sonst bis zum
nächsten Tastendruck ungefärbt da. Und es stoppt über
`stopSearchForChangedCriteria()`, nicht über `stopSearch()`: Das ließe bis
zu 150 ms Nachschub unsichtbar in `pending` liegen, obwohl die Trefferliste
stehen bleibt. Laden startet keine Suche und behält bei fehlendem Ordner den
aktuellen (`missingRootMessage` in der Fußzeile). Ein Vorlagenfehler
(`templateFailure`) steht NEBEN dem Zustand der Suche, nicht in ihm:
`refreshStatus` stellt ihn dem Suchtext voran, statt `searchPhase` auf
`.failed` zu setzen. Bis 0.34.8 tat er genau das — ein abgelehnter
Vorlagenname überschrieb damit den Fehler der letzten Suche, und das
anschließend gelungene Sichern setzte den Zustand auf `.idle`: Der
Suchfehler war endgültig weg, und eine laufende Suche verschwand aus der
Fußzeile. Zurückgenommen wird die Meldung nur von einer gelungenen
Vorlagenaktion oder vom nächsten Suchstart. Die Namensprüfung sitzt
deshalb in `storeTemplate()` und nicht im Dialog: Dialog und
Headless-Selbsttest prüfen denselben Speicherpfad. `RegexTemplate` bleibt
davon getrennt eine Einfügehilfe fürs Suchfeld. Pixeltexte bleiben bis zur Validierung unverändert:
Ein URL-Wert `10.5` darf niemals still zu einer leeren Grenze werden.
`FactFilterOption.all` beschreibt die sechs Größen-/Datumseingaben EINMAL
für UI, CLI-Argumente, URL und Zusammenfassung. Werte bleiben rohe Texte;
ausschließlich Python validiert Bytes und Zeitpunkte. `SearchFilterView`
fasst die Einträge nach ihrer `group` zusammen, nicht paarweise nach Index:
`all[index...index + 1]` setzte eine gerade Anzahl voraus, und ein siebter
Eintrag ließe beide Apps beim Aufbau der Filteransicht abstürzen.
`--metadata-field` geht nur im Metadaten-Modus mit; der Kern liest
`metadata_mode = args.metadata or bool(args.metadata_field)`, ein Feld ohne
`--metadata` ließe ihn im Namens-Modus stillschweigend Metadaten
durchsuchen und mit `--content` mit Exit 2 enden. Bis 0.34.17 hing das nur
an `hasPattern` und war allein davon verdeckt, dass die Haupt-App außerhalb
des Modus `nil` liefert — die Invariante gehört in die gemeinsame Quelle,
nicht in eine der Apps. `hasPositiveFilter`
zählt Maße, nichtleere Faktenfilter oder weitere Suchbegriffe, niemals
Ausschlüsse allein.
`SearchFilterView` enthält die sechs Felder, das mehrzeilige Feld „Weitere
Begriffe" (`termsEditor`, einer je Zeile → `SearchConfiguration.terms`,
CLI `--term=`, URL `term`) und das mehrzeilige Ausschlussfeld
beider Apps — zweispaltig: links die drei Von/Bis-Zeilen mit fester
Feldbreite, rechts das Ausschlussfeld (Platzhalter aus `PlaceholderTextView`,
?-Knopf mit Popover aus `exclusionHelpText`). BEIDE Apps zeigen die ganze
Ansicht und die Bildmaße-Zeile erst nach dem Aufklapp-Schalter „Weitere Filter"
(`FilterDisclosure` im Kern, Zustand in `UserDefaults`, je App ein eigener
Schlüssel; die Schnellsuche seit 0.34.22); zugeklappt nennt der
Titel die Zahl gesetzter Filter (ein Maßfeld nur, wenn `PixelLimitInput` es
nicht als leer wertet), eine Übergabe mit Filtern klappt in der
Haupt-App auf. Die Maßfelder starten eine Suche nur mit Return, nicht beim
Fokusverlust (`sendsActionOnEndEditing = false`): Sonst suchte schon ein
Klick in die Trefferliste oder das Zuklappen neu und leerte die Liste.
In der Schnellsuche stehen Spinner, Status und „Fortsetzen“ zusammen über der
Tabelle. Die Statuszeile bleibt auch bei eingeklappten Filtern sichtbar. Leere
Zeilen entfallen, Leerraum bleibt Musterbestandteil; die URL trägt wiederholte
`exclude`-Parameter. Der direkte Start-Fallback übergibt dieselbe URL.

Beide Apps starten Suchläufe ausschließlich über `SearchRunner`. Der Runner
zerlegt und parst JSONL im Hintergrund, übergibt höchstens 256 Treffer und
1 MiB pro Paket und hält höchstens zwei Main-Queue-Pakete gleichzeitig bereit.
Die Identität des Runners und in Quick zusätzlich die Generation verhindern
alte Treffer nach einem Suchwechsel. `cancel()` gilt auch vor dem Prozessstart
und während eines vollen Transports; nach SIGTERM folgt nötigenfalls SIGKILL.
Eine Zeile über 1 MiB ist ein sichtbarer Protokollfehler (Exit 2), kein still
verworfener Treffer. EOF und Prozessende müssen beide abgeschlossen sein;
die Completion steht hinter allen Paketen auf der Main-Queue. Foundation-
Temporaries werden je JSONL-Zeile freigegeben. Nur der synchrone Headless-
Adapter `runSearchStreaming` wartet; die Frontends tun das nie.

Dasselbe gilt fürs Auspacken von Archivtreffern (`MaterializationManager`,
seit 0.32.0). Auch die MENGE gleichzeitiger Aufträge ist begrenzt
(`maximumConcurrentExtractions`, eine `OperationQueue` mit
`maxConcurrentOperationCount`): Eine einzige Nutzeraktion auf einer großen
Auswahl erzeugt einen Auftrag je Archivtreffer, und jeder blockiert in
`readDataToEndOfFile()` plus `waitUntilExit()`. Ohne Deckel wuchs der
GCD-Threadpool bis an seine Decke — 200 Einträge mit einer 3-s-Attrappe
waren nach 9,3 s fertig, also rund 64 gleichzeitig, und mit dem echten
Kern lief die Spitze auf 25 Python-Prozesse. Getroffen hat es die Suche,
die denselben globalen Pool nimmt: erster Treffer nach 5,19 s statt
0,02 s (gemessen 2026-09-10). Ein Semaphor auf einer nebenläufigen
`DispatchQueue` wäre der falsche Weg — er blockierte genau die Threads,
die er sparen soll. `request(hit)` startet den Kern im Hintergrund und liefert
`ready(URL)`, `failed(Grund)` oder `cancelled` auf der Main-Queue — sofort
und synchron nur, wenn die Datei ohne Auspacken feststeht (`knownURL`:
normale Datei, schon ausgepackter Eintrag). Bis 0.31.4 las `materialize()`
stdout synchron und wartete mit `waitUntilExit()` aus Öffnen, Quick Look
und Drag-and-drop heraus auf dem Main-Thread; Messung in
`tests/MATERIALIZATION_MEASUREMENTS.md`. Die synchrone Fassung
`materializeHit()` gibt es nur noch für den Headless-Selbsttest; ein
Wächter-Test verbietet sie in beiden Controllern. Drei Zusagen, jede von
`tests/materialization_probe.swift` geprüft: gleichzeitige Anforderungen
desselben Treffers teilen EINEN Unterprozess und dieselbe Datei; stderr wird
nebenläufig geleert (`SearchDiagnostics`), sonst hält eine volle Pipe den
Kern an, während wir auf stdout warten; nach `cleanup()` legt kein noch
laufender Auftrag eine Datei neu an (`epoch`, ein zu spätes Ergebnis wird
gelöscht). `cancel()` nimmt nur den eigenen Anforderer vom Auftrag, der
letzte beendet den Prozess (SIGTERM, nach 1 s SIGKILL). Abbruch und
`cleanup()` gelten bis zum Beginn der Ergebniszustellung: `deliver()` prüft
für jeden Anforderer dessen Abbruchmarkierung und `epoch` unter demselben
Lock wie der Manager. Eine vorherige Completion darf den nächsten
Anforderer abbrechen; keine Completion läuft unter dem Lock. Bereits
zugestellte Anforderungen melden sich nach erneutem Abbruch nicht wieder.
Cacheprüfung und Auftragswahl in `request()` stehen unter einem gemeinsamen
Lock; `knownURLLocked()` liefert dieselbe Entscheidung wie `knownURL()`.
Ein dazwischen fertig werdender Worker darf keine zweite Extraktion auslösen.
In
`HitListController` arbeitet `withActionSelection` mit der FESTEN Auswahl
vom Klick, `requestPreview` nimmt für Quick Look nur die ZULETZT
angeforderte Auswahl (die vorige wird abgebrochen, ein spätes Ergebnis
verworfen); beide zeigen den Ladezustand über `presentMaterializationState`
(Haupt-App: Fußzeile, Schnellsuche: Infozeile), auch wenn eine neue Vorschau
sofort aus dem Cache oder Dateisystem bereitsteht. Listen- und Vorlagenwechsel
brechen mit `reportCancellation: false` ab; `actionGeneration` entwertet
auch bereits eingereihte Abbruchmeldungen, damit sie keinen neuen Status
überschreiben. ⎋ ruft in beiden
Tastaturmonitoren zuerst `cancelMaterializations()`. Drag-and-drop in beiden
Apps verlangt im Pasteboard-Callback sofort eine Antwort: Was
`knownURL` kennt, geht als URL, ein noch nicht ausgepackter Eintrag als
`NSFilePromiseProvider`, das der Finder beim Ablegen über denselben Manager
einlöst. Tabelle und Miniaturen setzen die erlaubte Operation anhand der beim
Dragstart beteiligten Treffer. Ausschließlich Originale erlauben Verschieben.
Finder wählt die Operation und verwaltet deren Rücknahme.

Die Haupt-App streamt Treffer, erhält die Auswahl bei neuen Ergebnissen und
bietet Öffnen, Öffnen mit, Finder-Anzeige, Pfadkopie, Quick Look und Drag-and-
drop. Der `--selftest`-Pfad ist die automatische Grenze zwischen GUI und Kern.

In BEIDEN Apps startet erst Return die Suche, nicht das Tippen: Das
Suchfeld setzt `sendsWholeSearchString = true` und
`sendsSearchStringImmediately = false`. Ohne diese beiden Werte schickt
`NSSearchField` seine Action von selbst, rund 0,45 s nach jeder
Tipppause — „Rechnung*" mit normalen Denkpausen getippt feuerte dreimal
(gemessen 2026-09-10). In der Haupt-App leert jeder dieser Aufrufe über
`startSearch` die sichtbare Trefferliste und schießt den laufenden
Kernprozess ab, um für zwei Zeichen einen neuen zu starten; ihr
Platzhalter verspricht das Gegenteil, und die Entprellung der
Schnellsuche (0,6 s) gibt es dort nicht. Bis 0.34.12 fehlten die Zeilen
in der Haupt-App.

Beide Apps tragen den Umschalter **Name | Inhalt | Metadaten**
(`SearchTextMode`, `modeControl`) und vier Maßfelder (Breite/Höhe je
von/bis, `PixelLimits`, gelesen über `parsePixelLimit`, das „1.000 px" als
1000 versteht — eine positive Ganzzahl, wahlweise in Dreierblöcken gruppiert;
`PixelLimitInput` unterscheidet leer, gültig und ungültig;
`validatePixelFields` markiert Fehler und widersprüchliche Von/Bis-Grenzen.
Beide Apps verhindern damit Suchstart und Übergabe, bis die Eingabe stimmt.
Ein Streichen aller Nicht-Ziffern machte
aus „-1" eine 1 und aus „10.5" eine 105). Die Haupt-App zeigt im Metadaten-Modus zusätzlich ein
Feldmenü, dessen Einträge `metadataFieldList()` vom Kern holt. Ohne Muster
startet eine Suche mit Maß-, Größen- oder Datumsfilter; `SearchConfiguration` lässt das
Muster dann ganz weg und schickt auch `--content`/`--metadata` nicht mit. An
derselben Bedingung hängen die Übergabe der Schnellsuche (`openInMainApp`) und
die Fortsetzung in der Haupt-App (`continueSearch`) — sonst sind „Alle in
Favenio" und ⌘↩ bei einer reinen Maßsuche wirkungslos. Die Spalte
„Fundstelle" (`locationText`) zeigt Zeilennummer oder „Feld: Wert", die Spalte
„Maße" (`dimensionsText`) die Pixel; nach Maßen wird nach Fläche sortiert —
über `Hit.pixelArea`, das den Überlauf deckelt, weil eine fangende
`Int`-Multiplikation die App beendet. Die Spalte „Pfad" zeigt den ORDNER
des Treffers relativ zum Suchordner (`Hit.folderText(relativeTo:)`, gebaut
aus `filesystemPath` und `archiveMembers`, nicht aus dem geschnittenen
`path` — ein Eintragsname darf selbst `!/` enthalten) und kürzt am ANFANG:
Der Dateiname steht links, der Suchordner im Ordnerknopf, und was die
Treffer unterscheidet, ist das Ende. Die Datumsspalten „Änderungsdatum" und
„Erstellungsdatum" wählen ihre Schreibweise nach der eigenen Breite
(`dateColumnStage`, vier Muster in `dateColumnSamples`, Tabellenziffern),
wie Doppeldecker; `columnDidResize` formatiert die sichtbaren Zellen um.
Die Haupt-App hält die Spalten ohne Gesamtlimit (`noColumnAutoresizing`,
waagerechter Balken, `autosaveName` für Breiten und Reihenfolge) — mit
`lastColumnOnlyAutoresizingStyle` ließ sich der Pfad nur breiter ziehen,
wenn man vorher andere Spalten zusammenquetschte. Die Spalte „Typ" geht über
`TypeDescriptionCache`, EINEN Eintrag je Endung:
`UTType(filenameExtension:)` samt `localizedDescription` ist eine
Datenbankabfrage (11,65 µs), und der Vergleicher ruft sie zweimal je
Vergleich. Gemessen am 2026-09-03 mit `swiftc -O` über 100 000 Treffer:
46,6 s ohne, 1,2 s mit Zwischenspeicher. Die URL-Übergabe der Schnellsuche trägt `mode`, `minw`,
`maxw`, `minh` und `maxh`; `content=1` bleibt für alte Quick-Versionen
lesbar.

Auf der Trefferliste arbeiten drei weitere Werkzeuge, alle im Menü **Ablage**
und im Rechtsklick-Menü der Tabelle, jeweils mit sichtbarem Kürzel:

- **Aus Trefferliste entfernen (⌫)** wirft Zeilen nur aus der Anzeige. Dieser
  Weg darf das Dateisystem nie anfassen — der Menüpunkt verspricht das
  Gegenteil eines Löschens, und ein Test hält ihn darauf fest. Entfernte Pfade
  bleiben in `seenPaths`, sonst fügt ein noch laufender Lauf sie wieder ein.
- **In den Papierkorb legen (⌘⌫)** geht über EINEN `NSWorkspace.recycle`-Aufruf
  für die ganze Auswahl. Datei für Datei zu löschen wäre bei tausenden Treffern
  deutlich langsamer als der Finder und ist damit abgelehnt. Ein Eintrag IM
  Archiv wird ausgelassen und im Dialog genannt: Hinter ihm liegt nur die
  ausgepackte Temp-Kopie. Dieselbe Datei aus mehreren Treffern wird einmal
  gelöscht. Das Geräusch ist die Klangdatei des Finders; fehlt sie, bleibt es
  still statt einen fremden Systemton zu spielen.
- **Treffer exportieren (⌘E / ⇧⌘E)** schreibt Pfade zeilenweise, Pfade
  NUL-getrennt, JSONL im Format von `--json` oder CSV mit UTF-8-BOM. Die
  BOM sagt, wohin die Tabelle geht — deshalb entschärft `csvField()` auch
  Formel-Präfixe: Beginnt ein Zellwert mit `=`, `+`, `-`, `@` oder einem
  Tabulator, wertet Excel ihn als FORMEL, auch in Anführungszeichen. Ein
  Dateiname darf unter macOS jedes Zeichen außer `/` und NUL enthalten,
  eine Datei `=cmd|'/c calc'!A1.txt` landete also in der ersten Spalte. Die
  NUL-Form ist kein Beiwerk: Ein Dateiname darf unter macOS jedes Zeichen außer
  `/` und NUL enthalten, auch einen Zeilenumbruch. In beiden Pfadformaten steht
  der Pfad in `!/`-Notation, den `--extract` wieder liest. Diese Notation ist
  mehrdeutig, wenn ein Eintragsname selbst `!/` enthält; `--extract` löst das
  je Archivebene gegen die Eintragsliste auf (`pick_member()`, längster
  passender Anfang gewinnt). Verlustfrei strukturiert ist nur JSONL.

`ExportWriter` serialisiert und schreibt den unveränderlichen Trefferstand
im Hintergrund. Start, Einzeljob-Sperre und Completion gehören auf Main;
`exportData` erzeugt das Format, der Dateiaustausch ist atomar. CSV benutzt
einen lokalen Datumsformatter je Export; JSONL begrenzt die Lebensdauer von
Foundation-Zwischenobjekten auf eine Zeile. Die GUI erlaubt
höchstens einen Sichern-Dialog oder Exportjob gleichzeitig. Exportstatus wird
in `refreshStatus` an den AKTUELLEN Suchstatus angehängt, niemals direkt über
dessen Text geschrieben. Die Fußzeile selbst hat GENAU EINEN Schreiber
(`showStatus`, seit 0.34.19): Text und Tooltip gehören zusammen, weil das
Feld in der Mitte kürzt und der Tooltip das Ganze zeigt — vorher setzten
`presentActionIssue`, `removeFromResults` und `trashSelected` nur den Text,
und daneben stand weiter der Tooltip der alten Kennzahlenzeile. Die
Schnellsuche hat dafür längst `showInfo`. Eine neue Suche oder deren Fehler darf auch nach
einem späten Exportabschluss sichtbar bleiben. Die komplette Ausgabe wird
weiterhin als `Data` aufgebaut; dies ist kein speicherbegrenzter Streamingexport.

Die Kürzel auf der Auswahl (⌫, ⌘⌫, ⇧⌘E) gelten nur, solange die Trefferliste
den Fokus hat. Das ist keine Kosmetik: Ein ungültiger Menüpunkt gibt sein
Kürzel frei, und nur deshalb löscht ⌫ im Suchfeld weiter ein Zeichen.
Durchgesetzt wird das doppelt — vom Tastaturmonitor (layoutunabhängiger
Tastencode 51, läuft vor dem Menü) und von `validateMenuItem`. Beide verlangen
zusätzlich, dass das Hauptfenster das Tastaturfenster ist und das Ereignis aus
ihm kommt: Solange ein Sichern-Blatt oder ein Alert offen ist, steht im
Hauptfenster weiter die Tabelle als `firstResponder`, und ⌫ im Dateinamenfeld
des Exportdialogs entfernte sonst Treffer. ⌘E (alle Treffer) braucht keine
Auswahl und deshalb nur das aktive Hauptfenster. Aus dem Hauptmenü und vom
Kürzel gilt immer die Auswahl, nie der gemerkte `contextRow` eines früheren
Rechtsklicks.

Nach dem Papierkorb merkt sich der Lauf die verschobenen Pfade in
`TrashedPaths` (Datei genau, Ordner mit allem darunter). Der Suchprozess läuft
weiter und kennt den Papierkorb nicht; deshalb werden Trefferliste, `pending`
und jede neu gestreamte Zeile dagegen geprüft. Eine neue Suche oder Übergabe
setzt die Liste zurück.

`applyHitsToTable` leert die Auswahl vor `reloadData()` und setzt sie danach
nur pfadbasiert — `reloadData()` behält Zeilennummern, und nach Sortieren oder
Entfernen zeigt dieselbe Nummer auf einen anderen Treffer. Die Zwischenschritte
lösen keine Auswahl-Benachrichtigung aus; die Vorschau wird am Ende nur
nachgeladen, wenn sie jetzt andere Dateien meint.

Frischer Nachschub wird in die schon sortierte Liste EINGEMISCHT
(`mergeSortedHits`), nicht durch ein Neusortieren der ganzen Liste
eingeordnet: Der Flush läuft alle 0,15 s, der Aufwand wüchse also über den
Lauf hinweg quadratisch. Gemessen am 2026-09-03 über einen ganzen Lauf mit
50 000 Treffern in Blöcken von 500 und dem echten Namensvergleicher: 1,02 s
beim Neusortieren, 0,62 s beim Einmischen, Ergebnis identisch. Der volle
Sortierlauf bleibt für den Spaltenwechsel und fürs Entfernen — dafür trägt
`applyHitsToTable` den Schalter `resort`.

`tableView(_:viewFor:row:)` und `previewPanel(_:previewItemAt:)` prüfen ihren
Index. Das ist Pflicht: `applyHitsToTable` verkleinert `hits` VOR dem
`reloadData()`, und NSTableView hält solange die alte Zeilenzahl; das
Quick-Look-Panel fragt nach einem Entfernen ebenfalls noch seinen alten
Index ab. Beides beendete die App mit „Index out of range".

Die Fußzeile zeigt Treffer, Datenmenge und Anzahl der Ordner, ab zwei
markierten Zeilen auch die Auswahlgröße. Sie wird über `statusText()` aus dem
Zustand formuliert; die Kennzahlen schreibt `flushPending()` fort, statt beim
Streamen jedes Mal die ganze Liste neu aufzusummieren.

Die Leertaste öffnet Quick Look, ohne das Panel zum Tastaturfenster zu machen
(`orderFront`, dann `makeFirstResponder(tableView)`) — in BEIDEN Apps.
Sonst gehen die Pfeiltasten an das Vorschaufenster, und die Vorschau lässt
sich nicht durch die Trefferliste blättern. Den Fokus NACH
`makeKeyAndOrderFront` zurückzuholen ist der verworfene Weg: Das ist ein
Rennen und verlor am 2026-09-02 am laufenden Fenster. Wird das Panel doch
Tastaturfenster, leitet `previewPanel(_:handle:)` ↑/↓ an die Tabelle weiter
und schließt bei ⎋; ist das Hauptfenster Tastaturfenster, schließt der
Tastaturmonitor die Vorschau bei ⎋. Der Monitor der Schnellsuche verlangt wie
der der Haupt-App, dass das Ereignis aus dem eigenen Fenster kommt und dieses
Tastaturfenster ist — ein lokaler Monitor feuert auch während `runModal()`,
und ⎋ im Freigabedialog beendete sonst die ganze App.

FavenioQuick ist ein `LSUIElement`-Panel. Es sucht im Hintergrund, zeigt den
aktuellen Pfad und übergibt fertige Treffer an die Haupt-App. Primär wird das
registrierte URL-Schema verwendet, als Fallback Startargumente und eine
temporäre JSONL-Datei. Übergabedateien müssen eindeutig, atomar geschrieben und
nach Gebrauch bereinigt werden.

Finder-Ordner werden ausschließlich über einen `/usr/bin/osascript`-
Unterprozess abgefragt. Bei bereits entschiedenem Automationszugriff gilt ein
Notaus von sechs Sekunden; solange der TCC-Freigabedialog auf die Entscheidung
des Nutzers wartet, gibt es bewusst kein künstliches Zeitlimit. In einer
laufenden `NSApplication` kann synchrones `NSAppleScript` auf Main- wie
Hintergrundthread deadlocken, weil die AppleEvent-Antwort am Main-Thread
zugestellt wird. Dies nicht als vermeintlich sauberere In-Prozess-Lösung
zurückbauen. Lehnt der Nutzer Automation ab oder ist kein Finder-Fenster offen,
fällt die App kontrolliert auf den Benutzerordner zurück.
