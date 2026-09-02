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
Dokumentformate wie JAR, WHL, EPUB, DOCX, XLSX, PPTX, ODT, ODS und ODP dazu.

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
  aus `type` erraten.
- `--progress` erzeugt gedrosselte Fortschrittsobjekte. Im JSON-Modus stehen sie
  im selben stdout-Strom und sind über `type: progress` erkennbar. Ohne JSON
  gehen Fortschritte nach stderr.
- Warnungen und Diagnose gehören nach stderr; stdout bleibt parsebar.
- Exit-Codes folgen grep: 0 = Treffer, 1 = keine Treffer, 2 = Fehler.
- Glob-Muster matchen den vollständigen Namen. Substring-Suche gilt nur ohne
  Platzhalter. Eine Änderung dieser Semantik wäre ein Breaking Change.
- Inhalt wird als UTF-8 mit `errors="replace"` gelesen. Dadurch bleiben Treffer
  in teilweise binären Dateien möglich; andere Textkodierungen werden nicht
  versprochen.
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
  `visit_file()` und `visit_member()` müssen diesen Fall gleich behandeln —
  vor 0.24.0 wurde ein `.7z`-Eintrag ohne `bsdtar` durchsucht, ein
  `.zip`-Eintrag an der Tiefengrenze dagegen übersprungen.
- Die Suche ist eine **Kriterienliste**, die alle zutreffen müssen
  (`Search.criteria`, ausgewertet in `evaluate()`): genau ein Textkriterium
  — `NameCriterion`, `ContentCriterion` oder `MetadataCriterion`, je nach
  `--content`/`--metadata` — plus `DimensionCriterion`, sobald einer der vier
  Maßfilter gesetzt ist. Sortiert nach `cost` (Name 0, Maße 1, Metadaten 2,
  Inhalt 3), Abbruch beim ersten Nein. Diese Reihenfolge ist ein
  Leistungsversprechen: exiftool sieht nur Dateien, die den Maßfilter schon
  bestanden haben, und ein Test hält sie fest. `FileProbe` beantwortet die
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
  Ein Bild ohne lesbare Maße erfüllt einen Maßfilter nie.
- `--metadata` liest über exiftool die Felder aus `METADATA_TEXT_FIELDS` —
  EINE kuratierte Konstante, bewusst leicht änderbar; die Oberflächen holen
  sie per `--list-metadata-fields` und bauen sie nicht nach. exiftool läuft
  als EIN Prozess je Suchlauf (`ExifToolStream`, `-stay_open True`, Pfade
  über stdin, `-use MWG`), gestartet beim ersten Bedarf und in `close()`
  beendet; ein Prozess je Datei kostete 44 ms statt 0,75 ms und ist
  abgelehnt. Nur Endungen aus `METADATA_EXTENSIONS` gehen an exiftool. Ohne
  exiftool endet `--metadata` mit Exit 2 und einem Satz, der sagt, was
  fehlt; die Maßfilter laufen ohne. Dieselbe Bauart wie `bsdtar` und `zstd`:
  optional, sauber erkannt, kein Pflichtpaket.
- Fehlt das Muster, ist das nur mit Maßfilter erlaubt (`*`). Ein einziges
  Positionsargument, das als Pfad existiert, gilt dann als Startpfad.
- `--archive-depth` begrenzt Rekursion. Verschachtelte Archive werden im Speicher
  verarbeitet; deshalb Größen- und Tiefengrenzen nicht unbemerkt entfernen.
- `--extract` materialisiert Trefferpfade mit `!/`-Notation in einem temporären
  Ordner. Öffnen, Finder-Anzeige und Drag-and-drop müssen dieselbe Datei sehen.
- `bsdtar` liest das Eintrags-Argument als **Suchmuster**, nicht als festen Namen.
  Jeder neue `bsdtar`-Aufruf mit einem echten Eintragsnamen muss deshalb durch
  `bsdtar_escape()` — sonst trifft ein Eintrag `a*.txt` auch `abc.txt` und beide
  Inhalte kommen aneinandergehängt zurück, also ein falscher Treffer ohne Fehler.

## Swift-Frontends

Beide Apps sind programmatische AppKit-Frontends ohne Xcode-Projekt.
`common/FavenioCore.swift` enthält das Hit-Modell, JSONL-Parsing,
Unterprozessaufrufe und `materializeHit()`. Änderungen am JSONL-Schema zuerst im
Kern und in gemeinsamen Tests spezifizieren, dann beide Frontends anpassen.

Die Haupt-App streamt Treffer, erhält die Auswahl bei neuen Ergebnissen und
bietet Öffnen, Öffnen mit, Finder-Anzeige, Pfadkopie, Quick Look und Drag-and-
drop. Der `--selftest`-Pfad ist die automatische Grenze zwischen GUI und Kern.

Beide Apps tragen den Umschalter **Name | Inhalt | Metadaten**
(`SearchTextMode`, `modeControl`) und vier Maßfelder (Breite/Höhe je
von/bis, `PixelLimits`, gelesen über `parsePixelLimit`, das „1.000 px" als
1000 versteht). Die Haupt-App zeigt im Metadaten-Modus zusätzlich ein
Feldmenü, dessen Einträge `metadataFieldList()` vom Kern holt. Ohne Muster
startet eine Suche nur mit gesetztem Maßfilter; `searchArguments` schickt dann
`*`. Die Spalte „Fundstelle" (`locationText`) zeigt Zeilennummer oder
„Feld: Wert", die Spalte „Maße" (`dimensionsText`) die Pixel; nach Maßen wird
nach Fläche sortiert. Die URL-Übergabe der Schnellsuche trägt `mode`, `minw`,
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

Die Fußzeile zeigt Treffer, Datenmenge und Anzahl der Ordner, ab zwei
markierten Zeilen auch die Auswahlgröße. Sie wird über `statusText()` aus dem
Zustand formuliert; die Kennzahlen schreibt `flushPending()` fort, statt beim
Streamen jedes Mal die ganze Liste neu aufzusummieren.

Die Leertaste öffnet Quick Look und gibt den Tastaturfokus sofort ans
Hauptfenster zurück. Ohne das gehen die Pfeiltasten an das Vorschaufenster, und
die Vorschau lässt sich nicht durch die Trefferliste blättern.

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
`install.sh` und `release.sh` eingebunden (nur `source`, nie ausführen). Beide
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

## Offene Abnahme (2026-08-29, aus der Handoff-Frontier)

- **Echter sichtbarer Sparkle-Update-Test** aus einer älteren notarisierten
  Test-App auf v0.24.2 steht noch aus (Session c-1115a198).
