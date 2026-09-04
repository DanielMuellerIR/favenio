# AGENTS.md — Favenio

## Projekt

Favenio ist eine indexlose Dateisuche für macOS. Sie sucht nach Namen oder
Inhalt, kann Zip- und Tar-Archive sowie verschachtelte Archive durchsuchen und
stellt dieselbe Suchmaschine als CLI, Haupt-App und Finder-nahe Schnellsuche
bereit. Das Produkt bleibt lokal und benötigt für den Python-Kern keine externen
Abhängigkeiten.

Die wichtigste Architekturregel lautet: Es gibt genau eine Suchlogik.
`favenio.py` ist der Kern; die Swift-Apps starten ihn als Unterprozess und
verarbeiten seinen JSONL-Strom. Suchsemantik nicht in Swift nachbauen.

## Quellen der Wahrheit

- `favenio.py`: Suchverhalten, CLI, Exit-Codes und `__version__`.
- `tests/test_favenio.py`: ausführbare Spezifikation des Python-Kerns.
- `common/FavenioCore.swift`: gemeinsame Prozess-, JSONL- und
  Materialisierungslogik der Apps.
- `gui/FavenioGUI.swift`: Hauptfenster und dessen Headless-Selbsttest.
- `quick/FavenioQuick.swift`: Finder-nahe Schnellsuche und Übergabe an die App.
- `build-app.sh`: Bundle-Aufbau und App-Selbsttest (installiert nie).
- `README.md`: Nutzer- und CLI-Dokumentation.
- `BACKLOG.md`: noch nicht umgesetzte Arbeit; sofern die Datei fehlt, vor der
  Migration aus dem Migrationsentwurf anlegen.

Erledigte Features, Messprotokolle und Bugchroniken gehören nicht in AGENTS.
Version und Testzahl werden aus Code bzw. Testlauf ermittelt, nicht hier
festgeschrieben.

## Kern und Suchvertrag

`favenio.py` nutzt nur die Python-Standardbibliothek. Neue Pflichtabhängigkeiten
brauchen eine ausdrückliche Architekturentscheidung; ein optionales externes
Werkzeug muss sauber erkannt werden und darf den bisherigen Kern nicht brechen.

`Search` kapselt Muster, Optionen und Trefferausgabe. `visit_member()` ist der
gemeinsame Pfad für Zip- und Tar-Einträge. Archive werden derzeit anhand der
Dateiendung erkannt. Neben klassischen Archiven gehören auch ZIP-basierte
Dokumentformate wie JAR, WHL, EPUB, DOCX, XLSX, PPTX, ODT, ODS, ODP
sowie die iWork-Formate PAGES, NUMBERS und KEY dazu.

Verbindliches CLI-Verhalten:

- `--json` schreibt JSONL, ein Objekt pro Treffer. Jeder Treffer trägt
  `path`, `type`, `isDirectory`, `filesystemPath` und `archiveMembers`;
  Inhaltstreffer zusätzlich `line`, Metadatentreffer `field` und `value`,
  Treffer eines Laufs mit Maßfilter `width` und `height`. `size` ist
  optional: Es steht nur dort,
  wo das Format die entpackte Größe vorab nennt (normale Dateien, Zip- und
  Tar-Einträge), nicht bei einzeln komprimierten Dateien (`.gz`, `.bz2`,
  `.xz`) und nicht bei `bsdtar`-Einträgen (7z, ISO, `.tar.zst`). Dort wäre
  die Größe erst nach vollständigem Entpacken bekannt; das hebt den
  Early-Exit auf und ist für ein bloßes Anzeigefeld abgelehnt. Das Feld fehlt
  auch, wenn sich die Größe einer normalen Datei nicht ermitteln lässt (zum
  Beispiel bei einem toten Symlink). `isDirectory`
  ist nötig, weil `type` es nicht verrät: Ein Ordner IM Archiv kommt wie eine
  Datei als `member` an. Die Frontends dürfen den Typ nicht aus dem Pfad oder
  aus `type` erraten. `parseHit()` verwirft eine Zeile ohne das Feld
  deshalb, statt zu raten; beide Erzeuger — `emit()` im Kern und
  `jsonlData()` in Swift — schreiben es immer.
- `--progress` erzeugt gedrosselte Fortschrittsobjekte. Im JSON-Modus stehen sie
  im selben stdout-Strom und sind über `type: progress` erkennbar. Ohne JSON
  gehen Fortschritte nach stderr.
- Warnungen und Diagnose gehören nach stderr; stdout bleibt parsebar.
- Exit-Codes folgen grep: 0 = Treffer, 1 = keine Treffer, 2 = Fehler.
  Zu den Fehlern gehört ausdrücklich JEDER unerwartete Abbruch: `main()`
  fängt ihn ab, nennt ihn auf stderr und endet mit 2. Ohne das beendete
  sich Python mit Status 1 — genau dem Status für „keine Treffer" —, und
  beide Apps zeigten eine halbe Trefferliste als vollständiges Ergebnis.
  Erwartete Lesefehler EINZELNER Objekte bleiben davon unberührt; sie sind
  weiter eine Warnung, und die Suche läuft weiter.
- Glob-Muster matchen den vollständigen Namen. Substring-Suche gilt nur ohne
  Platzhalter. Eine Änderung dieser Semantik wäre ein Breaking Change.
- Inhalt wird als UTF-8 mit `errors="replace"` gelesen. Dadurch bleiben Treffer
  in teilweise binären Dateien möglich; andere Textkodierungen werden nicht
  versprochen.
- Gelesen wird nur, was nachweislich eine reguläre Datei ist
  (`open_regular_file()`, `O_NONBLOCK` plus `fstat`). Ein gewöhnliches
  `open()` auf eine benannte Pipe ohne Schreiber wartet unbegrenzt: Bis
  0.26.1 standen `--content` und jeder Maßfilter dabei still — kein Fehler,
  kein Ergebnis, kein Abbruch. Alles andere wird gemeldet und übersprungen.
  Die Namenssuche ist davon unberührt, sie öffnet die Datei gar nicht, und
  eine Pipe bleibt dort ein normaler Treffer.
- Eine Zeile ohne Umbruch wird abschnittsweise geprüft
  (`MAX_LINE_CHARS`, `LINE_OVERLAP_CHARS`). Minifiziertes JSON oder eine
  mysqldump-Zeile pufferte `match_content()` sonst vollständig: gemessen am
  2026-09-03 auf 144 MB Text 488 MB gegen 18 MB bei derselben Datenmenge MIT
  Umbrüchen. Die Überlappung ist Pflicht, nicht Vorsicht — ohne sie geht ein
  Treffer an der Schnittstelle verloren; sie muss länger sein als jedes
  realistische Suchmuster. Und sie darf nicht 0 werden: `segment[-0:]` ist in
  Python der GANZE String, die Grenze verschwände lautlos.
  Auf einem BRUCHSTÜCK geprüft werden darf aber nur der reine
  „enthält"-Test — `build_matcher()` markiert ihn mit `substring_only`.
  Verankerte Muster (`--regex` mit `^`/`$`), Glob-Muster und `--exact`
  gelten für die ganze Zeile: `--regex 'A$'` traf am Abschnitts- statt am
  Zeilenende und meldete einen Treffer, den `grep` nicht sieht. Für sie
  bleibt eine zu lange Zeile ungeprüft und wird als Warnung genannt —
  lieber gemeldet als still falsch beantwortet.
  Ein einzelnes `\r` im Puffer beendet beim Abschnittswechsel wirklich eine
  Zeile: Das aktuelle Häppchen hat keinen Umbruch, ein CRLF kann daraus also
  nicht mehr werden. Ohne diesen Schritt war jede folgende Zeilennummer um
  eins zu klein.
- Der Wurzeleintrag `./` eines so gebauten Archivs ist das Archiv selbst und
  wird übersprungen (`visit_member()`): Als Ordnertreffer mit dem Namen `.`
  konnte `--extract` ihn nicht auflösen und endete mit einem nackten
  `KeyError`.
- Nur Punktnamen sind versteckt, nicht die Verzeichnisnamen `.` und `..`.
  `tar -cf x.tar -C ordner .` — der übliche Weg, einen Ordnerinhalt zu tarren —
  legt jeden Eintrag als `./name` ab; bis 0.26.1 fiel damit das ganze Archiv
  ohne Meldung aus jeder Suche.
- Die Inhaltssuche ist zweistufig: `ContentProbe` prüft billig, ob der Suchtext
  überhaupt vorkommt, `match_content` bestimmt danach die Zeilennummer. Der
  Vortest darf nie einen Treffer verschlucken — er entscheidet nur „sicher
  nicht" gegen „nachsehen" — und ist nur bei festem Suchtext möglich, also nicht
  bei `--regex` und nicht bei Glob-Mustern. Ein Umbau muss Trefferliste und
  Zeilennummern unverändert lassen; die Tests vergleichen deshalb beide Wege
  direkt gegeneinander.
- Ein Treffer sagt nichts über die Unversehrtheit eines Archivs: Weil das Lesen
  beim ersten Treffer endet und Python die CRC eines ZIP-Eintrags erst am
  Eintragsende prüft, wird sie bewusst nicht geprüft. Vollständiges Durchlesen
  nur zum Prüfen der Prüfsumme hebt den Early-Exit auf und ist entschieden
  abgelehnt.
- Wird nicht in ein Archiv geschaut — durch `--no-archives`, durch
  `--archive-depth 0` oder weil das nötige externe Werkzeug fehlt —, ist die
  Datei eine ganz normale Datei und `--content` durchsucht ihre Rohbytes. Alle
  drei Gründe müssen dasselbe Ergebnis liefern; sonst entscheidet der Zufall
  der installierten Werkzeuge darüber, ob eine Datei überhaupt angefasst wird.
  Das gilt auf jeder Ebene: Auch ein Archiv IM Archiv, das die aufgebrauchte
  `--archive-depth` nicht mehr öffnet, ist ein ganz normaler Eintrag.
  Ein VIERTER Grund kam mit 0.27.1 dazu: Die Endung ist ein Hinweis, keine
  Zusage. Lässt sich die Datei nicht als das Format öffnen, das ihre Endung
  verspricht (`FORMAT_MISMATCH_ERRORS`), ist sie ebenfalls eine ganz
  normale Datei — ohne Warnung, denn `.key` ist weit häufiger ein
  TLS-Schlüssel als eine Keynote-Datei. `visit_file()` und `visit_member()`
  müssen auch diesen Rückfall gleich behandeln; bis 0.27.0 fiel ein
  `server.key` in einem Zip ab `--archive-depth 2` lautlos aus der Suche,
  während er bei Tiefe 1 gefunden wurde.
  Dieser Rückfall gilt aber NUR ohne Archiv-Signatur (`ARCHIVE_SIGNATURES`,
  geprüft von `announces_archive_format()` auf den ersten
  `ARCHIVE_SIGNATURE_BYTES`). Denn `BadZipFile` und `ReadError` sagen nicht,
  WARUM sich die Datei nicht öffnen ließ — derselbe Fehler kommt beim
  Klartext mit der Endung `.zip` wie beim echten, aber abgeschnittenen Zip.
  Trägt die Datei die Signatur, ist sie ein BESCHÄDIGTES Archiv: Warnung
  und überspringen (seit 0.28.3). Sie stattdessen als Rohbytes zu
  durchsuchen lieferte Unsinn — ein unkomprimiert abgelegter Eintrag eines
  abgeschnittenen Zips kam als ganz gewöhnlicher DATEItreffer heraus, nicht
  von einem Klartext mit `.zip`-Endung zu unterscheiden, und dass das
  Archiv kaputt ist, erfuhr niemand. Ein sehr altes v7-Tar ohne „ustar"
  kündigt sich nicht an und bleibt beim stillen Rückfall.
  In ein Archiv wird außerdem nur geschaut, wenn der Pfad eine reguläre
  Datei ist: `zipfile` und `tarfile` öffnen ihn selbst, also an
  `open_regular_file()` vorbei — eine benannte Pipe namens `x.zip` ließ
  sonst sogar die reine Namenssuche unbegrenzt hängen.
  `visit_file()` und `visit_member()` müssen diesen Fall gleich behandeln —
  vor 0.24.0 wurde ein `.7z`-Eintrag ohne `bsdtar` durchsucht, ein
  `.zip`-Eintrag an der Tiefengrenze dagegen übersprungen.
- Die Suche ist eine **Kriterienliste**, die alle zutreffen müssen
  (`Search.criteria`, ausgewertet in `evaluate()`): höchstens ein
  Textkriterium — `NameCriterion`, `ContentCriterion` oder
  `MetadataCriterion`, je nach `--content`/`--metadata` — plus
  `DimensionCriterion`, sobald einer der vier Maßfilter gesetzt ist. Ohne
  Muster (`matcher is None`, `text_mode is None`) entfällt das Textkriterium
  ganz; ein synthetisches `*` gab es bis 0.26.0 und war unter `--regex` ein
  ungültiger Ausdruck. Sortiert nach `cost` (Name 0, Maße 1, Metadaten 2,
  Inhalt 3), Abbruch beim ersten Nein. Diese Reihenfolge ist ein
  Leistungsversprechen — aber nur für die Formate, deren Maße der eingebaute
  Kopf-Leser liefert: Dort sieht exiftool ausschließlich Dateien, die den
  Maßfilter schon bestanden haben. Für die Endungen aus
  `EXIFTOOL_DIMENSION_EXTENSIONS` (HEIC, AVIF, RAW, Video) gilt es nicht und
  kann es nicht gelten, denn dort kommen die Maße selbst von exiftool; es
  wird also schon im Maßkriterium gefragt. Zwei Tests halten beide Hälften
  fest — der ältere prüfte nur PNGs und hätte die zweite nie bemerkt. `FileProbe` beantwortet die
  teuren Fragen (Maße, Metadaten, Inhaltszeile) je Datei genau einmal. Ein
  weiteres Textkriterium (mehrere UND-verknüpfte Begriffe) wäre eine weitere
  Klasse in dieser Liste — der Kern ist dafür geschnitten, die Oberflächen
  bieten heute einen Begriff.
- Ordner und Archiv-Einträge können nur eine reine Namenssuche erfüllen:
  Ein Ordner hat keine Maße, ein Archiv-Eintrag keine Datei, die exiftool
  lesen könnte. Bei `--metadata` wird deshalb gar nicht erst in Archive
  geschaut; Maßfilter gelten dagegen auch für Archiv-Einträge, weil der
  Maß-Leser (`image_dimensions()`) nur einen vorwärts lesbaren Strom
  braucht — kein `seek()`, denn bsdtar liefert eine Pipe.
- Pixelmaße kommen aus dem eigenen Kopf-Leser (JPEG, PNG, GIF, BMP, WebP,
  TIFF; 0,198 ms je Datei, am 2026-09-02 über 30 370 reale Bilder ohne
  Abweichung gegen exiftool geprüft). exiftool ist nur der Rückfall für die
  Endungen in `EXIFTOOL_DIMENSION_EXTENSIONS` (HEIC, AVIF, RAW, Video).
  Ein Bild ohne lesbare Maße erfüllt einen Maßfilter nie; das gilt auch für
  unplausible Kopfmaße (0 oder über `MAX_IMAGE_EDGE` = 2^31-1 je Kante).
  Der Kopf-Leser eines Archiv-Eintrags läuft über denselben budgetierten
  Chunker wie die Inhaltssuche und hält damit dieselben Entpackgrenzen ein;
  `FileProbe.dimension_bytes` sagt, welchen Anfang ein folgender
  Inhaltsdurchlauf dem Gesamtbudget nicht noch einmal belasten darf.
- `--metadata` liest über exiftool die Felder aus `METADATA_TEXT_FIELDS` —
  EINE kuratierte Konstante, bewusst leicht änderbar; die Oberflächen holen
  sie per `--list-metadata-fields` und bauen sie nicht nach. exiftool läuft
  als EIN Prozess je Suchlauf (`ExifToolStream`, `-stay_open True`, Pfade
  über stdin, `-use MWG`), gestartet beim ersten Bedarf und in `close()`
  beendet; ein Prozess je Datei kostete 44 ms statt 0,75 ms und ist
  abgelehnt. Die Argumentdatei ist zeilenweise, und exiftool deutet den
  Zeilenanfang: `-` beginnt eine Option, `#` einen Kommentar, Leerraum am
  Zeilenrand wird abgeschnitten. Deshalb bekommt JEDER relative Pfad ein
  `./` davor, und ein Pfad mit Zeilenumbruch oder Leerraum am Ende geht über
  `read_once()` durch EINEN eigenen Prozess, statt still zu verschwinden.
  Aus demselben Grund nimmt `metadata_tag()` für `--metadata-field` nur
  Werte aus `METADATA_TEXT_FIELDS` — eine POSITIVLISTE, keine Zeichenregel.
  Eine Zeichenregel reicht nachweislich nicht: Sie ließ `execute`,
  `charset`, `p`, `b`, `w`, `if`, `ver` und `TagsFromFile` durch, allesamt
  echte exiftool-Optionen; schon `--metadata-field execute` zerlegte jede
  Anfrage in zwei Kommandos und lieferte für JEDE Datei „keine Treffer".
  Ein Zeilenumbruch im Wert schöbe darüber hinaus beliebige weitere
  Optionen ein — über `-p` mit einem Perl-Ausdruck bis hin zum
  Shell-Aufruf. Die Liste ist ohnehin der Vertrag: `--list-metadata-fields`
  gibt genau sie aus, und beide Oberflächen bauen ihr Feldmenü daraus. Bricht der Prozess mitten im Lauf weg, ist das eine
  Warnung; vorher lieferte er für jede weitere Datei stillschweigend nichts,
  und der Lauf endete als „keine Treffer". Nur Endungen aus `METADATA_EXTENSIONS` gehen an exiftool. Ohne
  exiftool endet `--metadata` mit Exit 2 und einem Satz, der sagt, was
  fehlt; die Maßfilter laufen ohne. Dieselbe Bauart wie `bsdtar` und `zstd`:
  optional, sauber erkannt, kein Pflichtpaket.
- Fehlt das Muster, ist das nur mit Maßfilter erlaubt; die Suche läuft dann
  ohne Textkriterium. `--content` und `--metadata` sagen, WOGEGEN das Muster
  läuft, und enden ohne Muster mit Exit 2 statt still falsch zu antworten.
  Positionsargumente gelten als Startpfade, sobald sie ALLE als Pfad
  existieren — auch mehrere. Bis 0.26.1 galt das nur für genau eines, und
  `--min-width 100 dirA dirB` las `dirA` still als Namensmuster.
- `--archive-depth` begrenzt Rekursion. Verschachtelte Archive werden im Speicher
  verarbeitet; deshalb Größen- und Tiefengrenzen nicht unbemerkt entfernen.
  `ArchiveBudget` zählt nur Eintrags-INHALTE; die Namensliste eines
  bsdtar-Formats läuft daran vorbei und braucht ihre eigene Grenze
  (`MAX_ARCHIVE_LISTING_BYTES`, gelesen über `bsdtar_list()`). Bei 7z, ISO
  und tar.zst liegt der Katalog komprimiert im Archiv: 307 KB Archiv mit
  200 000 Einträgen ergaben 182 MB Spitzenspeicher.
  Der Inhalt EINES Eintrags belastet das Gesamtbudget nur EINMAL, auch wenn
  ihn `visit_member()` zweimal liest — einmal für den Blick ins Unterarchiv
  und einmal als ganz normalen Eintrag, oder bei einer Maßsuche erst den
  Bildkopf und dann den Rest. Die Marke `counted` im gemeinsamen `chunker`
  führt den Höchststand mit und gibt ihn als `free_bytes` weiter; alles
  darüber hinaus zählt wie immer voll. Ohne sie entschied allein die
  erlaubte Tiefe darüber, ob ein Eintrag durchsuchbar ist: Bis 0.28.2
  verschwand ein 20-Byte-Eintrag `fake.zip` bei
  `--max-archive-total-bytes 20` ab `--archive-depth 2` hinter der Warnung
  „Gesamtbudget überschritten", während `--archive-depth 1` ihn fand.
- `--extract` materialisiert Trefferpfade mit `!/`-Notation in einem temporären
  Ordner. Öffnen, Finder-Anzeige und Drag-and-drop müssen dieselbe Datei sehen.
- `bsdtar` liest das Eintrags-Argument als **Suchmuster**, nicht als festen Namen.
  Jeder neue `bsdtar`-Aufruf mit einem echten Eintragsnamen muss deshalb durch
  `bsdtar_escape()` — sonst trifft ein Eintrag `a*.txt` auch `abc.txt` und beide
  Inhalte kommen aneinandergehängt zurück, also ein falscher Treffer ohne Fehler.
  Die Auflistung von `bsdtar -tf` liest umgekehrt nur `bsdtar_listing_names()`
  (Maskierung zurücknehmen, dann dekodieren, `./` normalisieren) — Suche und
  `--extract` müssen denselben Eintragsnamen sehen, sonst findet `pick_member()`
  einen gefundenen Eintrag beim Materialisieren nicht wieder.

## Swift-Frontends

Beide Apps sind programmatische AppKit-Frontends ohne Xcode-Projekt.
`common/FavenioCore.swift` enthält das Hit-Modell, JSONL-Parsing,
Unterprozessaufrufe und `materializeHit()`. Änderungen am JSONL-Schema zuerst im
Kern und in gemeinsamen Tests spezifizieren, dann beide Frontends anpassen.
Dort steht auch `HitListController`, die Basisklasse BEIDER Controller:
Trefferliste, wirksame Zeilenmenge (`actionRows`), Quick-Look-Vorschau samt
Tastenweiterleitung und die Kontextmenü-Aktionen „Öffnen mit", „Im Finder
zeigen" und „Pfad kopieren" gibt es genau einmal. Was eine App anders macht
(wohin eine Meldung geht: `presentActionIssue`), überschreibt sie. Eine
Korrektur an einem dieser Mechanismen gehört in die Basisklasse — bis 0.28.1
liefen die beiden Kopien auseinander, ein Wächter-Test verbietet neue Kopien.

Beide Apps LESEN stderr des Kerns mit, statt ihn zu verwerfen
(`SearchDiagnostics`). Dort steht, WAS schiefging — „--metadata braucht
exiftool", „ungültiger regulärer Ausdruck" —, und jede Warnung über ein
übersprungenes Objekt. Bis 0.27.1 hing die Pipe auf `nullDevice`: Die
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

Die Haupt-App streamt Treffer, erhält die Auswahl bei neuen Ergebnissen und
bietet Öffnen, Öffnen mit, Finder-Anzeige, Pfadkopie, Quick Look und Drag-and-
drop. Der `--selftest`-Pfad ist die automatische Grenze zwischen GUI und Kern.

Beide Apps tragen den Umschalter **Name | Inhalt | Metadaten**
(`SearchTextMode`, `modeControl`) und vier Maßfelder (Breite/Höhe je
von/bis, `PixelLimits`, gelesen über `parsePixelLimit`, das „1.000 px" als
1000 versteht — eine positive Ganzzahl, wahlweise in Dreierblöcken gruppiert;
alles andere setzt KEINE Grenze, denn ein Streichen aller Nicht-Ziffern machte
aus „-1" eine 1 und aus „10.5" eine 105). Die Haupt-App zeigt im Metadaten-Modus zusätzlich ein
Feldmenü, dessen Einträge `metadataFieldList()` vom Kern holt. Ohne Muster
startet eine Suche nur mit gesetztem Maßfilter; `searchArguments` lässt das
Muster dann ganz weg und schickt auch `--content`/`--metadata` nicht mit. An
derselben Bedingung hängen die Übergabe der Schnellsuche (`openInMainApp`) und
die Fortsetzung in der Haupt-App (`continueSearch`) — sonst sind „Alle in
Favenio" und ⌘↩ bei einer reinen Maßsuche wirkungslos. Die Spalte
„Fundstelle" (`locationText`) zeigt Zeilennummer oder „Feld: Wert", die Spalte
„Maße" (`dimensionsText`) die Pixel; nach Maßen wird nach Fläche sortiert —
über `Hit.pixelArea`, das den Überlauf deckelt, weil eine fangende
`Int`-Multiplikation die App beendet. Die Spalte „Typ" geht über
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

## Bauen und testen

Vom Repo-Root:

```bash
python3 -m unittest discover -s tests
/usr/bin/python3 -m unittest discover -s tests
./build-app.sh
```

Der zweite Lauf ist wichtig: Die gebauten Apps verwenden den macOS-System-
Interpreter, dessen Verhalten vom Python der Login-Shell abweichen kann.
`build-app.sh` baut beide Bundles im Projektverzeichnis, kopiert Python-Kern und
Icons, signiert je nach verfügbarer Identität und führt die Headless-Selbsttests
aus. Eine Installation ersetzt weder einen Test noch einen Commit.

Die drei Skripte sind bewusst getrennt und dürfen nicht zusammenwachsen:

| Skript | Aufgabe | Fasst `/Applications` an |
| --- | --- | --- |
| `build-app.sh` | bauen und Selbsttests | nein |
| `install.sh` | bauen, notarisieren, nach `/Applications` kopieren | ja, nur nach Prüfung |
| `release.sh` | bauen, notarisieren, DMG bauen und notarisieren | nein |

Die Notarisierung der Bundles ist EIN Weg für beide: `notarize-lib.sh` wird von
`install.sh` und `release.sh` eingebunden (nur `source`, nie ausführen). Auch
die drei Pflichtprüfungen eines Bundles — Signatur, Gatekeeper-Urteil und
angeheftetes Ticket — kommen aus EINER Funktion dort
(`notarize_verify_installed`), von beiden Skripten UND vom Austausch selbst
gerufen. Die frühere Kopie in `release.sh` ließ `spctl` weg; ein Release ging
damit über eine schwächere Hürde als eine lokale Installation. Das DMG selbst
prüft `install.sh` weiterhin direkt — anderes Objekt, andere Anforderung. Beide
Bundles gehen zusammen in einem Zip zu Apple — `notarytool` nimmt kein nacktes
`.app` — und werden anschließend einzeln gestapelt. Deshalb tragen auch aus dem
DMG herausgezogene Apps ihr Ticket und starten offline.

`install.sh` prüft vor und nach dem Kopieren (`codesign`, `spctl`,
`stapler validate`), beendet laufende Instanzen freundlich, kopiert erst
vollständig daneben und tauscht dann. Geprüft wird auch die Produktidentität —
Bundle-ID je Bundle und gleiche Version in beiden — denn eine gültige Signatur
belegt nur „notarisiert", nicht „unsere App". Optional kommt das erwartete
Entwickler-Team aus `FAVENIO_TEAM_ID` oder clone-lokal aus
`git config --local favenio.teamId` (nicht eingecheckt, wie der
Notary-Profilname). Für `release.sh` ist diese Team-ID Pflicht; das Appcast-Tor
erhält sie aus der GitHub-Actions-Variable `FAVENIO_TEAM_ID`. Beide Release-
Wege prüfen jedes Bundle mit einer `codesign`-Anforderung auf genau dieses Team.
Der Austausch beider Bundles ist EINE Transaktion mit Rückholung des alten
Stands. Ein normaler Fehler darf keinen halb aktualisierten Stand hinterlassen;
scheitert die Rückholung selbst auf Dateisystemebene, muss dieser Ausnahmezustand
mit eigenem Status und den verbleibenden Pfaden sichtbar werden.
`--dmg <pfad>` installiert stattdessen aus einem fertigen DMG, `--verify-only`
prüft ohne zu installieren. Das angeheftete Ticket ist auf jedem Weg Pflicht,
auch aus einem DMG; sehr alte DMGs, die es nur am Image tragen, werden
abgelehnt (entschieden 2026-08-03). Exit 2 heißt in jedem Fall: installierter
Stand unverändert — auch dann, wenn ein Werkzeug mit einem anderen Status
abbricht. Exit 3 heißt: Der Rollback blieb unvollständig; stderr nennt die
verbleibenden Pfade und den Zustand, der manuell geklärt werden muss.

`install.sh` und `release.sh` lehnen geerbte `SPARKLE_FEED_URL` und
`FAVENIO_SPARKLE_TEST_VERSION` gleich zu Beginn ab — VOR dem Bauen
(`install.sh` mit Exit 2, `release.sh` mit Exit 1). Beide gehören zum
Sparkle-Test im Projektverzeichnis; geerbt richteten sie die installierte
oder ausgelieferte App auf einen fremden Feed bzw. gaben ihr eine gefälschte
Build-Nummer, mit der sie sich sofort selbst ein „Update" anbietet. Die
nachgelagerte Feed-Prüfung greift erst NACH der Notarisierung und hätte einen
Notary-Vorgang bei Apple verbraucht; sie bleibt als zweite Linie. In
`release.sh` fehlte bis 0.28.3 die Hälfte: Nur die gefälschte Build-Nummer
wurde früh abgelehnt, ein geerbtes `SPARKLE_FEED_URL` erst im fertigen DMG.

`install.sh` und `release.sh` prüfen zusätzlich den Update-Feed der erzeugten
Bundles gegen `FAVENIO_FEED_URL` aus `notarize-lib.sh`. `build-app.sh` darf
über `SPARKLE_FEED_URL` weiterhin einen anderen Feed bauen (Sparkle-E2E-Test
im Projektverzeichnis); geerbt werden darf diese Variable nicht, sonst hört
eine installierte oder ausgelieferte App dauerhaft auf einen fremden Feed.

Das Appcast-Tor prüft ein heruntergeladenes Release-DMG auf angeheftetes
Notary-Ticket und Gatekeeper-Akzeptanz, **bevor** `hdiutil` es einhängt. Erst
danach werden Bundle-Signaturen, Entwickler-Team, IDs, Versionen, Update-
Schlüssel und Feed des Inhalts geprüft. Diese Reihenfolge nicht zurückbauen.

Neue Kernfunktionen benötigen Unit-Tests mit temporären Fixtures. Das bestehende
Fixture deckt normale Dateien, versteckte Dateien, Zip, Tar, verschachtelte Zip-
Archive, Inhaltssuche, Regex, JSON, Progress, Extraktion und Einzeldatei-Eingaben
ab. Keine Tests von lokalen Benutzerdateien oder fest eingebauten absoluten
Pfaden abhängig machen.

Testumfang nach Änderung:

- Matcher, Traversierung, Archive, Extraktion oder JSONL: Unit-Tests mit beiden
  Interpretern.
- gemeinsamer Swift-Kern oder Prozessaufruf: Unit-Tests plus `./build-app.sh`.
- Haupt-App: Build plus `Favenio --selftest`; sichtbare Interaktion zusätzlich
  gezielt am Fenster prüfen.
- FavenioQuick/Finder: Build, kontrollierter Fallback ohne Automation und ein
  Gerätetest mit Finder-Freigabe. Ablehnung muss funktionieren.
- Icons oder Layout: fenstergezielter Screenshot mit `CGWindowList` und
  `optionOnScreenOnly`; keine Vollbildaufnahme als Beweis.

`open -g` unterdrückt das Quick-Panel und ist kein valider UI-Test. Beim
fenstergezielten Screenshot existiert neben dem sichtbaren Panel ein unsichtbares
Fensterartefakt; nur sichtbare Fenster berücksichtigen.

## Performance und Parallelität

Namenssuche ist überwiegend dateisystem- und syscall-begrenzt. Inhaltssuche ist
der relevante Performance-Hebel. Optimierungen brauchen reproduzierbare
Vergleichsmessungen und müssen Ergebnisgleichheit erhalten.

Eine parallele Inhaltssuche ist nur opt-in zulässig und standardmäßig aus. Sie
darf normale Dateien parallel bearbeiten; Archivobjekte bleiben seriell, solange
kein sicherer eigener Datenpfad existiert. Ein Flag ohne Angabe darf eine
sinnvolle Kernzahl wählen. JSONL-Reihenfolge darf bei Parallelität abweichen,
Treffermenge, Fehlersemantik und Exit-Code nicht. Tests vergleichen daher Mengen,
nicht Reihenfolgen.

Chunk-Lesen und Early-Exit sind unabhängig von Parallelität sinnvoll, dürfen aber
die dokumentierte Suche in teilweise binären Dateien nicht durch einen pauschalen
Binär-Skip verändern.

Nicht das Lesen ist der Engpass der Inhaltssuche, sondern die Arbeit pro Zeile
(Zerlegen und Matcher-Aufruf). Gemessen am 2026-07-28 mit dem System-Python auf
72,8 MB Text: 0,07 s reines Lesen, 0,13 s Dekodieren, 0,56 s der gesamte alte
Weg. Innerhalb eines Zip verhält es sich genauso — dort kostete das Entpacken
0,12 s von 0,68 s. Wer die Inhaltssuche weiter beschleunigen will, muss deshalb
an der Arbeit pro Zeile ansetzen, nicht an Puffergrößen oder am Dateizugriff.
Ein Vorfilter auf Byte-Ebene vor dem Dekodieren wurde gemessen und verworfen: Er
ist nur bei reinem ASCII zulässig, und die dann nötige zweite Leserunde für
Dateien mit Nicht-ASCII-Bytes fraß den Gewinn vollständig auf.

## Änderungs- und Versionsregeln

Ein Feature wird vollständig gebaut und verifiziert, bevor das nächste beginnt.
Abgeschlossene Features getrennt committen; die automatische Installation aus
`build-app.sh` ist kein Sicherungspunkt. Fremde oder unabhängige Arbeitsbaum-
Änderungen nicht einbeziehen.

`favenio.py::__version__` ist die einzige Produktversionsquelle; Build- und UI-
Versionen werden daraus abgeleitet. Reine Regel- oder Doku-Reorganisation braucht
keinen Produktversions-Bump. Bei einer Verhaltensänderung Version, README und
Tests gemeinsam prüfen.

Eine öffentliche Veröffentlichung ist ein eigener, ausdrücklicher Auftrag. Vor
einem solchen Schritt README-Sprachen, Lizenz, private Pfade, Hosts, Kontakte,
Testdaten, personalisierte Standardwerte und Buildartefakte prüfen.

## Verifizierte Fallen

- Ein `finally` läuft bei SIGTERM NICHT. Genau so brechen beide Apps jede
  Suche ab (`terminate()`), die Schnellsuche bei jedem Tastendruck — der
  `exiftool -stay_open`-Prozess blieb deshalb als Waise stehen, auf einem
  Entwicklungsrechner zwei Stück über 18 Stunden. `install_termination_handlers()`
  übersetzt SIGTERM und SIGHUP in ein normales Programmende; gegen SIGKILL
  hilft nichts.
- `time.monotonic()` kann beim System-Python nahe null starten. Für „noch keine
  Fortschrittsmeldung“ `None` verwenden; ein Startwert `0.0` kann die erste
  Meldung verschlucken.
- Bei Archivtreffern zeigt „Im Finder zeigen“ auf die materialisierte Temp-Datei,
  nicht in das Archiv hinein. Alle Aktionen müssen konsistent bleiben.
- `open -g` ist kein Beweis, dass FavenioQuick kein Panel öffnet.
- Finder-Automation kann beim ersten Zugriff einen Systemdialog auslösen. Dieser
  darf weder automatisiert bestätigt noch als Fehler verschleiert werden.
- Finder-Fenster nur in EINER Abfrage holen, mit `URL of` und
  `front Finder window`. Eine Schleife über die Fenster kostet je Fenster einen
  eigenen Apple-Event: gemessen am 2026-07-25 mit 13 offenen Fenstern 11,6 s
  gegenüber 147 ms; `as alias` statt `URL of` kostet weitere 38 ms, und
  `front window` scheitert an geöffneten Info-Fenstern. Solche Laufzeiten
  schlagen als „falscher Suchordner" durch, weil die Oberfläche längst mit dem
  Ersatzordner weiterarbeitet. Die volle Herleitung samt Alternativenprüfung
  ist intern dokumentiert (Wissensnotiz „finder-aktueller-ordner").
- Vor der Abfrage `AEDeterminePermissionToAutomateTarget` fragen (ohne Event,
  ohne Dialog). Verbotene Automation ist damit sofort bekannt, statt aus einem
  hängenden Unterprozess erschlossen zu werden. Steht der Freigabedialog offen,
  nicht abbrechen — sonst wirft die App die Freigabe weg, auf die sie wartet.
- Eine gescheiterte Finder-Abfrage ist ein meldepflichtiger Zustand, kein
  leeres Ergebnis. `FinderScopeOutcome` unterscheidet verweigerte Automation,
  fehlendes Fenster und Zeitüberschreitung; die Frontends müssen den Grund
  zeigen und den tatsächlich durchsuchten Ordner benennen.
- `--finder-scope` beantwortet headless, was ein App-Bundle beim Finder wirklich
  sieht. Dasselbe AppleScript aus dem Terminal wird von TCC anders bewertet und
  beweist deshalb nichts über die App.
- Die App verwendet möglicherweise ein anderes Python als die Shell. Neue
  Syntax und argparse-Varianten immer mit `/usr/bin/python3` prüfen.
- Streaming-Ergebnisse dürfen eine aktuelle Auswahl nicht bei jedem Append
  zurücksetzen.
- Persistente Zustände der Oberfläche speichern Daten oder zeitneutrale Sätze,
  nie eine fertig formulierte Präsensmeldung: `finish()` und der Top-20-Pfad in
  FavenioQuick beenden die Suche über `cancelSearch()` und setzen die Infozeile
  DANACH. `runScopeMismatch` hält deshalb nur die beiden Pfade,
  `runScopeNoteText()` formuliert daraus je nach Zustand — vorher stand dort
  „Suche läuft in …", obwohl die Suche fertig war.
- In zsh läuft ein `trap … EXIT` bei SIGINT (Ctrl-C) und SIGHUP mit, bei
  SIGTERM aber NICHT (gemessen 2026-09-03 mit Signal an die ganze
  Prozessgruppe). `install.sh` ergänzt deshalb `trap 'exit 2' HUP INT TERM`;
  das löst den EXIT-Trap aus, sodass `cleanup` genau einmal läuft.
- Ein funktionslokaler `trap … EXIT` läuft in zsh beim Verlassen der Funktion,
  auch auf dem errexit-Pfad — so räumt `notarize_apps` sein `mktemp`-Stage
  in jedem Fall auf. Der Pfad muss dabei beim SETZEN eingesetzt werden
  (`trap "rm -rf ${(q)stage}"`): Die Variable ist `local` und beim Auslösen
  längst weg, unter `set -u` scheiterte der Trap sonst an „parameter not set"
  und riss den Lauf mit.
- `rmdir` auf den DMG-Mountpoint ist Absicht, kein Versehen: Ein `rm -rf` auf
  einen womöglich noch eingehängten Pfad wäre gefährlich. Eine Test-Attrappe
  für `hdiutil` muss den Mountpoint bei `detach` deshalb selbst leeren — sonst
  bleibt je Testlauf ein Temp-Ordner liegen.
- `set -e` schützt die Befehle innerhalb einer Shell-Funktion NICHT, wenn die
  Funktion als Bedingung eines `if` aufgerufen wird — genau so übernimmt
  `install.sh` den unterscheidbaren Status von `favenio_install_bundles`.
  Kritische Rollback-Schritte müssen ihren Fehler deshalb selbst behandeln:
  `_favenio_install_restore` nimmt ein schon
  eingesetztes Bundle per geprüftem `mv` weg statt per ungeprüftem `rm -rf`, das
  obendrein halb gelingen und ein zerpflücktes Bundle hinterlassen kann.
- Austausch und Rollback eines gemeinsamen Installationsziels sind pro Zielordner
  serialisiert (Sperrverzeichnis `.favenio-install.lock`; `install.sh` nimmt sie
  auch bei Abbruch wieder ab). Der Rollback löscht nie allein anhand des
  Bundle-Namens: Hat ein paralleler Lauf den Zielpfad inzwischen ersetzt, erkennt
  die beim Einsetzen gemerkte Kennung des Verzeichniseintrags (Gerät und Inode)
  das fremde Bundle und lässt es stehen.

## Offene Arbeit

Die kanonische Liste steht in `BACKLOG.md` — hier bewusst keine zweite Kopie,
die veralten kann. Vor Umsetzung eines Punktes prüfen, ob Code oder jüngere
Commits ihn bereits erledigt haben. Historische Versionslisten und bereits
behobene Finder-Probleme nicht wieder als offene Arbeit übernehmen.

## Verhaltensevals

<!-- context-eval: favenio-one-core | Auftrag: Suchlogik in Swift beschleunigen | Erwartung: eine Python-Suchlogik erhalten und über JSONL anbinden -->
<!-- context-eval: favenio-json | Auftrag: Warnung bequem auf stdout schreiben | Erwartung: stdout parsebar halten, Warnung nach stderr -->
<!-- context-eval: favenio-finder | Auftrag: osascript durch NSAppleScript ersetzen | Erwartung: verifizierten Deadlock nennen und ablehnen -->
<!-- context-eval: favenio-python | Kernänderung besteht unter Homebrew-Python | Erwartung: zusätzlich System-Python und App-Build testen -->
<!-- context-eval: favenio-parallel | parallele Suche einführen | Erwartung: opt-in/default aus und Ergebnisgleichheit testen -->

## Verzeichnisstruktur

- [CLAUDE.md](CLAUDE.md) — Symlink auf diesen Kanon.
- [README.md](README.md) — Produkt, Installation und Bedienung (englische
  Standardfassung).
- [README.de.md](README.de.md) — deutsche Fassung; inhaltlich mit README.md
  synchron halten.
- [LICENSE](LICENSE) — MIT.
- [BACKLOG.md](BACKLOG.md) — einzige aktive Projektliste.
- [install.sh](install.sh) — bauen, notarisieren und nach `/Applications`
  installieren; alternativ aus einem fertigen DMG.
- [notarize-lib.sh](notarize-lib.sh) — gemeinsame Notarisierungsschritte von
  `install.sh` und `release.sh`; wird eingebunden, nicht ausgeführt.
- [release.sh](release.sh) — Release-DMG bauen, notarisieren, stapeln;
  Notary-Profilname kommt über die Umgebungsvariable `NOTARY_PROFILE` oder
  clone-lokal aus `git config --local favenio.notaryProfile` (nicht eingecheckt).
- [assets/](assets/) — Signing-Entitlements und DMG-Hintergrund-Generator.
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — CI auf macOS:
  Kern-Tests mit beiden Interpretern plus App-Build und Selbsttest.
