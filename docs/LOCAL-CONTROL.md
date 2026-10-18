# Lokale sichtbare Suchsteuerung

Ab Favenio 0.36.0, Protokollversion 1. Der Bundle-Helfer
`Contents/Helpers/favenio-control` konfiguriert und steuert das normale
Hauptfenster. Die Suche läuft weiterhin ausschließlich im Python-Kern.

```sh
/Applications/Favenio.app/Contents/Helpers/favenio-control --capabilities --json
/Applications/Favenio.app/Contents/Helpers/favenio-control --request request.json
/Applications/Favenio.app/Contents/Helpers/favenio-control --no-launch --request - < request.json
```

Die Offline-Fähigkeitsabfrage startet keine App. Sonst öffnet der Helfer bei
Bedarf sein eigenes App-Bundle. `--no-launch` verbindet sich nur mit einem
laufenden Prozess. Der Transport ist lokal und nach Benutzer und Bundle-ID
getrennt. Eine andere Instanz derselben App kann denselben Endpunkt nicht
übernehmen. Es werden keine Shellstrings ausgewertet.

Jeder JSON-Auftrag enthält `version: 1`, eine UUID in `id`, `operation` und
`deadline` als Unix-Sekunden: aktuelle Zeit plus höchstens zehn Sekunden.
Unbekannte Felder und `null` werden abgewiesen. Ändernde Aufträge verlangen
zusätzlich die aktuelle `runtimeID` und `windowID` aus `capabilities`.
Nach App-Neustart gelten die alten Kennungen nicht mehr. Ab 0.41.0 beträgt die
Auftragsgrenze 262.144 Byte; `maximumRequestBytes` nennt den aktuellen Wert.

| Operation | Weitere Felder | Verhalten |
| --- | --- | --- |
| `capabilities` | keine | Fähigkeiten, Produktversion, Laufzeit und Fenster |
| `configuration` | keine | aktuelle sichtbare Eingaben |
| `configure` | `configuration` | Eingaben setzen; keine Suche starten |
| `start` | keine | neue Suche; laufende Suche ergibt `busy` |
| `replace` | keine | laufende Suche ausdrücklich ersetzen |
| `cancel` | `runID` | abbrechen und bereits empfangene Treffer erhalten |
| `status` | keine | Laufzustand, Fortschritt, Warnungszahl und Trefferanzahl |
| `report` | `runID` | begrenzter JSON-Suchbericht des aktuellen Laufs, auch vorläufig; [Vertrag](SEARCH_REPORT.md) |
| `results` | `runID`, `offset`, `limit`, optional `generation` | begrenzte Ergebnisseite |
| `select` | `runID`, `identity` | genau diesen Treffer in der Tabelle zeigen |
| `handoff` | `runID`, `identity` | ab 0.37.0: begrenzte asynchrone Fastra-Übernahme starten |
| `handoffStatus` | `jobID` | Status und bestätigte Herkunft der eigenen Übergabe |
| `cancelHandoff` | `jobID` | noch nicht abgeschlossene eigene Übergabe abbrechen |
| `captureRecording` | `runID` | ab 0.38.0: beendeten eigenen Suchstand vollständig aufnehmen |
| `openRecording` | `recording` | ab 0.38.0: gespeicherten Stand ohne Suche sichtbar öffnen |

Die Konfiguration enthält `pattern`, einen absoluten `root` und `options`
als Liste von Objekten mit `name` und `value` (beides Strings). Optionen
verwenden denselben Katalog wie Quick-Übergabe und Suchvorlagen: `mode`
(`name`, `content`, `metadata`, `document`), `only` (`both`, `files`, `dirs`), die
Schalter `regex`, `case`, `archives`, `hidden`, `exact`, `literal-wildcards`
(`0` oder `1`), `field`, `minw`, `maxw`, `minh`, `maxh`, die sechs Größen-/
Datumsfilter sowie wiederholbare `term` und `exclude`. Ab 0.40.0 enthält
`criteria` optional einen JSON-Kriterienbaum als String; die Fähigkeitsabfrage
nennt `criteriaSchemaVersion: 1`. Werte bleiben roh;
Python validiert Größen, Daten und Suchmuster. GUI-Maßfehler verhindern wie
beim manuellen Start die Suche.

Ab 0.55.0 wird alternativ die strikte Form
`{"schemaVersion":2,"pattern":"Beispiel","roots":["/tmp/docs","/tmp/project"],"options":[]}`
gelesen. Die geordnete Liste, Herkunft je Treffer, Versionsmigration und Grenzen
stehen im [Suchbereichsvertrag](SEARCH_ROOTS.md). Capabilities nennen
`configurationSchemaVersions: [1,2]` und `recordingSchemaVersion: 3` mit
`recordingSchemaVersions: [1,2,3]`. Historisches Öffnen prüft die Wurzelliste nicht
auf Vorhandensein; ein neuer Gesamtstart prüft alle Bereiche.

```json
{
  "pattern": "Beispiel", "root": "/tmp/suchfixture",
  "options": [{"name": "mode", "value": "content"},
              {"name": "archives", "value": "1"}]
}
```

Ein Start friert die tatsächlich verwendete Konfiguration unter einer neuen
`runID` ein. Späteres `configure` verändert sichtbare Eingaben, aber keine
laufende Suche. Manuelle Starts und Quick-Übergaben entwerten ebenfalls alte
Laufkennungen. Alte Prozessantworten werden vom bestehenden Runner abgewiesen.

`status.state` unterscheidet `idle`, `running`, `completed`, `warnings`,
`cancelled`, `failed` und `recorded` (Quick-Übergabe ohne eigenen Lauf).
`complete` ist nur bei `completed` wahr; Nulltreffer sind dabei erfolgreich.
Warnungen, Abbruch und Fehler werden nicht als vollständige Suche ausgegeben.
Bei Fehlern bleibt die konkrete Diagnose erhalten. Während einer Suche steht
die endgültige Warnungszahl erst nach Prozessende fest. `pendingCount` nennt
noch nicht angezeigte empfangene Treffer. Die Auswahl ist auf 128 Identitäten
begrenzt; `selectionCount` und `selectionTruncated` nennen die tatsächliche
Anzahl und eine gekürzte Antwort.

Ergebnisseiten enthalten unveränderte JSONL-Treffer, `count`, `generation`,
`nextOffset`, `hasMore` und Laufzustand. `limit` liegt zwischen 1 und 128.
Die erste Seite beginnt bei Offset null; Folgeseiten müssen die zurückgegebene
Generation nennen. Nach Nachschub, Sortierung oder Entfernen ergibt ein alter
Cursor `stale`: mit Offset null neu beginnen. Eine Seite kann wegen der
Antwortgröße kürzer sein. Große Listen werden für Statusabfragen nicht kopiert.

`identity` enthält genau `filesystemPath`, `archiveMembers` und
`archiveMemberBytes`. Die drei Felder unverändert aus einem Ergebnis übernehmen;
niemals Tabellenposition oder sichtbaren `path` als Identität verwenden.

Nach verlorener Bestätigung einen ändernden Auftrag mit derselben ID und
identischem Inhalt wiederholen. Die letzten 128 bestätigten Änderungen bleiben
bis zu 300 Sekunden wiederholbar, auch nach Ablauf ihrer ursprünglichen Frist.
Eine ID mit anderem Inhalt wird abgewiesen. Danach muss der Client den aktuellen
Zustand prüfen; ein neuer Start mit neuer ID erzeugt einen neuen Lauf.

Requests sind auf 256 KiB und Antworten auf 1 MiB begrenzt. Der Helfer beendet
auch eine nicht abgeschlossene Standardeingabe nach zehn Sekunden.
Aufruf-/Transport-/Controllerfehler ergeben Exit 1 und ein JSON-Fehlerobjekt,
erfolgreiche Antworten mit Exit 0. Ein erfolgreich abgefragter `failed`-Status
bleibt eine erfolgreiche Statusabfrage. Suchfehler stehen im Status selbst.
Während eines geöffneten Dialogs nehmen die ändernden Operationen keinen Auftrag
an. Begrenzte gespeicherte Abläufe sind unten beschrieben.

## Übergabe an Fastra

Ab 0.37.0 nennt `capabilities` zusätzlich `fastraSourceSnapshotSchemaVersion: 1`,
`maximumHandoffBytes: 262144` und `handoffTimeoutSeconds: 30`.
`handoff` und `cancelHandoff` sind ändernde Aufträge mit Laufzeit-/Fensterbindung.
Ein wiederholter identischer `handoff` erzeugt keinen zweiten Übergabeauftrag.
Die Antwort enthält `handoff.id`; diese Kennung als `jobID` abfragen.
Die letzten 32 Aufträge bleiben bis zum App-Ende abfragbar. Genau eine Übergabe
kann gleichzeitig laufen. Zustände: `preparing`, `opening`, `ready`, `failed`,
`cancelled`. Ein abgefragter Fehlerzustand bleibt eine erfolgreiche Statusabfrage.

Fastra wird über seine installierte Bundle-ID ohne Aktivierung gestartet.
Der Empfänger muss `sourceSnapshotSchemaVersion: 1` mit Schreibschutz und
passenden Größenlimits bestätigen (Fastra ab 1.137.0). Eine normale Datei
oder ein Archivmitglied wird als begrenzter Textsnapshot übergeben; Ordner
und Archivtreffer ohne bytegenaue Mitgliedskette sind ausdrücklich ausgeschlossen.
Die Materialisierung verwendet einen eigenen frischen `MaterializationManager`;
die vorhandene Vorschaukopie ist keine Quelle der neuen Übergabe.

Die Quellengeneration enthält Gerät, Inode, Größe sowie Änderungs- und
Statusänderungszeit mit Nanosekunden. Sie wird vor und nach Materialisierung
und Positionsprüfung verglichen. Äußere Archive bis 64 MiB werden zusätzlich
vor und nach der Materialisierung gehasht. Größere Archive erhalten ausdrücklich
`archiveBinding: generation`; Fastra erklärt die schwächere Herkunftsbindung.
Der Blattinhalt ist immer mit SHA-256 gebunden. Auch ein äußerer Hash ist
keine allgemeine Integritätsprüfung oder ein unabhängiger Entpackbeweis.

Der frühere Suchinhalt wurde nicht gespeichert. Das steht im sichtbaren
`searchEvidence`; die Übergabe verspricht keine historische Inhaltsidentität.
Für Inhaltstreffer prüft derselbe Python-Kern die Begriffe erneut am aktuellen
Blatt. Die aktuelle erste Fundzeile wird vollständig ausgewählt. Geänderte Positionen erhalten neue UTF-16-Offsets; verschwundene Begriffe
werden abgewiesen. Gültiges UTF-8, UTF-16 und ausdrücklich gewählte Legacy-Kodierungen ohne Nullbytes
können exakt navigiert werden, einschließlich Datei-BOM und Python-Zeilentrennern. Der Bereich muss auch auf
vollständigen Swift-Characters liegen. Andere Modi oder nicht belegbare
Zeichengrenzen verwenden `positionBinding: unboundHit`, Position/Länge null und
eine sichtbare Erklärung; es wird kein mehrdeutiger Textanker geraten.

Erst Fastras `ready` mit `adopted: true`, passendem Blatt-/Texthash, Herkunft und
beobachteter Auswahl ergibt Favenios `ready`. Die Antwort enthält Fastras
Übernahmebeleg unter `handoff.fastra`. Anschließend entfernt Favenio seine
eigene Materialisierung; Fastras Kopie bleibt bis zum Schließen der Sitzung.
Ein Suchwechsel, App-Ende, Abbruch oder die 30-Sekunden-Frist beendet offene
Arbeit. Bereits identifizierte unbestätigte Fastra-Sitzungen werden gezielt
abgebrochen und geschlossen; andere Editorfenster bleiben unberührt.
Beim normalen App-Ende wartet Favenio asynchron höchstens fünf Sekunden auf
die eigene Empfängerbereinigung. Bei unerreichbarem Fastra oder erzwungenem
Prozessende ist eine Empfängerbestätigung nicht garantiert; eine dort bereits
bestätigte eigene Kopie bleibt unabhängig vom Sender erhalten.

Die interne CLI-Positionsprüfung `--snapshot-position-json JSON` verwendet
exakt `path` (absoluter Blattpfad), `mode` (`name`, `content`, `metadata`),
`pattern`, `terms` (Stringliste) und die Bool-Felder `regex`, `caseSensitive`,
`exact`, `literalWildcards` sowie optional `encoding` aus der dokumentierten
Positivliste (fehlend: `utf-8`). Sie liest höchstens 262144 Bytes einer regulären
Datei. Erfolg liefert ein JSON-Objekt mit `sha256`, `location`, `length` und
`positionBinding`; bei fehlerfreier Dekodierung zusätzlich `contentEncoding`,
`textSHA256` (UTF-8 des ursprünglichen Texts, ohne die Datei-BOM), `textUTF16Length`
und `consumedBOMBytes` des Suchdecoders. Eine belegte Inhaltsposition trägt
zusätzlich `line` und `decoder`. Es gibt keine NFC- oder Zeilenendumschreibung.
Nichtstandardkodierungen erfordern Fastras Capability `sourceSnapshotTextEncodings`
und übergeben den aufgelösten Decoder als optionales `textEncoding`. Das
Herkunftsschema bleibt 1; alte Empfänger werden vor der Übernahme abgewiesen.
Ein in der Nichtstandardkodierung nicht fehlerfrei dekodierbarer Blattinhalt
wird vor der Übergabe mit `sourceUnavailable` erklärt.
Fehler ergeben Exit 2 mit Favenio-Diagnose. Es entsteht keine zweite Suchlogik.

## Suchaufzeichnungen (ab 0.38.0)

`captureRecording` braucht die aktuelle `runID` und einen beendeten eigenen
Suchlauf. Die Antwort enthält `recording`: Schema 1 (ohne Kriterien und mit UTF-8) oder 2 (mit Kriterien oder Nichtstandardkodierung), Konfiguration, ursprüngliche
Laufkennung und Startzeit, Aufnahmezeit, Abschlusszustand, Warnungszahl, gegebenenfalls
Fehler, vollständige Treffer und Auswahl. Maximal 128 Treffer und 196.608 Byte;
Überschreitung ist `capacity`, niemals eine still gekürzte vollständige Liste.
Schema-1-Aufnahmen aus 0.40.0 mit Kriterien bleiben verlustfrei lesbar und
werden bei erneuter Aufnahme als Schema 2 ausgegeben.
Eine laufende Suche muss zuerst ausdrücklich mit `cancel` beendet werden.
Fähigkeiten nennen `recordingSchemaVersion: 2`, `recordingSchemaVersions: [1, 2]`,
`maximumRecordingBytes: 196608`
und `maximumRecordingHits: 128`. Warnungen bewahren wie die bisherige GUI
die Anzahl übersprungener Objekte, keine einzelnen Diagnosetexte.

`openRecording` braucht die aktuellen Laufzeit-/Fensterkennungen und `recording`.
Es validiert den ganzen Stand vor jeder Änderung. Laufende Suche oder Übergabe
führt zu `busy`. Die Wiederöffnung setzt sichtbare Konfiguration, Treffer und
Auswahl, startet keinen Python-Prozess und kennzeichnet die Fußzeile als
aufgezeichneten Stand. Die aktuelle Ansicht bekommt eine neue `runID`;
`status.recordedSource` bewahrt ursprüngliche Laufkennung/Startzeit/Aufnahmezeit.
Alte Aufträge werden dadurch `stale`. Warnungen, Abbruch und Fehler bleiben
unvollständig. Der Stand enthält keine damaligen Dateiinhalte; Öffnen und
Fastra-Übergabe beziehen sich weiter auf die aktuell verfügbaren Quellen.

Der lokale Helfer `tools/search-recording.py` verwendet ausschließlich diesen
Controller. Beispiel mit dem Bundle-Helfer als `HELPER`:

```sh
python3 tools/search-recording.py --helper "$HELPER" record suchstand.json
python3 tools/search-recording.py --helper "$HELPER" open suchstand.json
python3 tools/search-recording.py --helper "$HELPER" rerun suchstand.json
```

`record` schreibt eine private JSON-Datei atomar. `open` zeigt gespeicherte
Treffer, `rerun` konfiguriert und startet eine neue echte Suche, ohne die
Aufzeichnung zu überschreiben. Bis zu 32 ausdrücklich ausgeführte Auswahl-/
Übergabeaktionen können mit `append-action DATEI select|handoff IDENTITÄTSDATEI`
angehängt werden. Die Identitätsdatei enthält `filesystemPath`, `archiveMembers`
und `archiveMemberBytes`; der Treffer muss zum gespeicherten Stand gehören.
Wiedergabe dieser Aktionen braucht ausdrücklich `open ... --actions` oder
`rerun ... --actions`. Fehlende Treffer sind Fehler; eine gescheiterte Übergabe
stoppt die Folge. Jeder Aufruf bindet sich an die aktuelle Laufzeit und das
aktuelle Fenster. Die standardmäßige Neusuche-Zeitgrenze beträgt 60 Sekunden,
mit `--timeout` maximal 300; bei Überschreitung wird nur der eigene noch aktuelle
Suchlauf abgebrochen. Die Eingabedatei ist auf 262.144 Byte begrenzt und muss
regulär sein; Aktionsidentitäten auf 48.000 Byte.

Textkodierung ist die optionale Suchoption `encoding`; die Capability `textEncodings`
nennt die zulässigen Werte. Fehlende Option bleibt `utf-8`. Unbekannte oder doppelte
Werte werden vor jeder Konfigurationsänderung abgewiesen.

Im Suchziel `document` beziehen sich Muster und Inhaltskriterien auf logischen
PDF-Text. Seitenlokatoren und Quellbindung bleiben in Ergebnissen, Aufnahmen und
Schema-2-Übergaben erhalten; siehe [Dokumenttext](DOCUMENT_TEXT.md). Die
Rohtext-Positionsübergabe an Fastra erhält dadurch keinen PDF-Seitenoffset.

## Ansichtsfilter ab 0.53.0

Ergebnisseiten beziehen sich auf die durch den Ansichtsfilter zugelassene Liste.
Auswahl und Übergabeaktionen verwenden echte Trefferidentitäten.
`status.resultFilter` und `results.resultFilter` nennen aktive Kriterien, Lade-/
Fehlerzustand sowie Quellzahl und durch den Filter zugelassene Trefferzahl
(`visibleCount`; unabhängig von eingeklappten Gruppen). Ausstehende oder gescheiterte
Filterauswertung verhindert `complete`. Filterwechsel entwerten Cursor-Generationen.
`captureRecording` erhält den gesamten Quellstand; beim Öffnen wird der Ansichtsfilter
zurückgesetzt. [Vertrag und CLI](RESULT_FILTER.md).

## Gruppierung ab 0.54.0

`status.resultGrouping` und `results.resultGrouping` unterscheiden gefilterte
Treffer und aufgeklappte Trefferzeilen; Gruppenüberschriften sind keine Dateien.
Ergebnisseiten enthalten auch eingeklappte gefilterte Treffer und nennen
`resultsIncludeCollapsed: true`. Explizites `select` und `handoff` klappen die
Gruppe des angefragten Treffers auf und scrollen ihn sichtbar. Gruppierungs-/
Klappwechsel entwerten Cursor sowie alte Vorschau-/Fastra-Aufträge. Aufzeichnungen
und Quick-Übergaben bewahren den Quellstand ohne Gruppierungsdarstellung.
[Vertrag und Archivnavigation](RESULT_GROUPS.md).

## Kalenderfragen und Laufbezug

Kalenderfragen verwenden Konfigurationsformat 3 (`roots` als Liste),
Aufzeichnungsformat 4 und Kriterienschema 2. `dateRangeSchemaVersion: 1` meldet die
Fähigkeit. Die Optionen heißen `date-ranges` und gegebenenfalls
`date-reference-time`. `configure` übernimmt eine Frage; `start`/`replace`
erfassen einen neuen Bezug oder nehmen einen ausdrücklich angegebenen
`dateReferenceTime` mit Z/Offset an. `status.configuration` enthält den gefrorenen
Laufauftrag, `report.dateResolution` dessen konkrete Grenzen.

Aufzeichnungen tragen diese Grenzen separat als `dateResolution`. Beim Öffnen
werden Frage, Referenztext und explizite ISO-/Epochwerte vollständig geprüft;
es findet keine neue Kalenderauflösung statt. `rerun` startet die relative Frage
mit einem neuen Bezug. Aufnahmeaktionen vergleichen auch den eingefrorenen
Laufkontext. [Vollständiger Datumsvertrag](DATE_RANGES.md).

## Finder-Eigenschaften

Die Steuerung meldet `finderMetadataSchemaVersion: 1`,
`criteriaSchemaVersions: [1,2,3]`, `configurationSchemaVersions: [1,2,3,4,5,6,7]` und
`recordingSchemaVersions: [1,2,3,4,5,6,7,8]`. Finder-Fragen oder die Erfassungsoption
`finder-metadata=1` benötigen Konfigurationsformat 4 mit `roots` als Liste.
Aufnahmen mit Finder-Fragen oder erfassten Snapshots verwenden Format 5 und
`finderMetadataCapability: 1`, auch bei einer ursprünglichen reinen Namenssuche.

Ergebnisseiten, Aufnahmen und der CLI-Helfer erhalten führendes U+FEFF, NFD,
Tagfarben und Kommentarumbrüche. Eingehende Snapshots werden auf Originalbytes
geprüft, bevor Dictionary-Roundtrips Zahlenlexeme ändern könnten. Unbekannte
Formate und widersprüchliche Werte werden vor UI-/Laufänderung abgewiesen.
Der Aufnahmehelfer prüft die tatsächlich benötigten Fähigkeiten vor configure/open.
Kombinierte Kalenderfragen behalten Referenz und separat geprüfte Grenzen.
Historisches Öffnen und Ansichtsfilter lesen die Finder-Quelle nicht erneut.
[Datenvertrag und Bedienung](FINDER_METADATA.md).

## Lokal vorhandene Inhalte

`local-only=1` benötigt Konfigurationsformat 5, `localContentSchemaVersion: 1`
und Aufzeichnung 6 mit `localContentCapability: 1`. Die Option ist standardmäßig
aus. Kombinationen bewahren Finder-/Kalenderbelege und deren bisherige
Fähigkeiten. Ältere Konfigurationen oder Aufnahmen dürfen die aktive Politik
nicht verlieren und werden vor Mutation abgewiesen. [Lesepolitik und Grenzen](LOCAL_CONTENT.md).

## Bild-OCR

`ocr=1` benötigt Konfiguration 6, `ocrSchemaVersion: 1` und Aufnahme 7 mit
`ocrCapability: 1`. Die Option wirkt ausschließlich im Suchziel Dokumenttext;
Default ist aus. Quick und Vorlagen verwenden Format 7. OCR-Belege mit
`contentEncoding: "vision-ocr-text-v1"` und `documentPosition.kind: "imageOCR"`
bleiben über die bestehenden Treffer-/Exportpfade erhalten. Alter Transport mit
aktiver OCR wird vor Übernahme abgewiesen. Cloud-, Finder- und Kalenderfähigkeiten
werden bei gemeinsamer Verwendung unabhängig geprüft. [Vertrag und Grenzen](OCR.md).

PDF-OCR: aktives `pdf-ocr=1` benötigt Konfiguration 7, Aufnahme 8 mit `pdfOCRCapability: 1` sowie Quick-/Vorlagenformat 8. Controller/Bundles nennen `pdfOCRSchemaVersion` beziehungsweise `FavenioPDFOCRSchemaVersion` 1. Alte aktive Formate werden abgewiesen; Bild-OCR bleibt unabhängig. [Vollständiger Vertrag](PDF_OCR.md).
