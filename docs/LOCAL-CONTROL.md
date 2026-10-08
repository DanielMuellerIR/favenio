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
Nach App-Neustart gelten die alten Kennungen nicht mehr.

| Operation | Weitere Felder | Verhalten |
| --- | --- | --- |
| `capabilities` | keine | Fähigkeiten, Produktversion, Laufzeit und Fenster |
| `configuration` | keine | aktuelle sichtbare Eingaben |
| `configure` | `configuration` | Eingaben setzen; keine Suche starten |
| `start` | keine | neue Suche; laufende Suche ergibt `busy` |
| `replace` | keine | laufende Suche ausdrücklich ersetzen |
| `cancel` | `runID` | abbrechen und bereits empfangene Treffer erhalten |
| `status` | keine | Laufzustand, Fortschritt, Warnungszahl und Trefferanzahl |
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
(`name`, `content`, `metadata`), `only` (`both`, `files`, `dirs`), die
Schalter `regex`, `case`, `archives`, `hidden`, `exact`, `literal-wildcards`
(`0` oder `1`), `field`, `minw`, `maxw`, `minh`, `maxh`, die sechs Größen-/
Datumsfilter sowie wiederholbare `term` und `exclude`. Werte bleiben roh;
Python validiert Größen, Daten und Suchmuster. GUI-Maßfehler verhindern wie
beim manuellen Start die Suche.

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

Requests sind auf 64 KiB und Antworten auf 1 MiB begrenzt. Der Helfer beendet
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
werden abgewiesen. Gültiges UTF-8 ohne Nullbytes kann exakt navigiert werden,
einschließlich UTF-8-BOM und Python-Zeilentrennern. Der Bereich muss auch auf
vollständigen Swift-Characters liegen. Andere Modi/Encodings oder nicht belegbare
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
`exact`, `literalWildcards`. Sie liest höchstens 262144 Bytes einer regulären
Datei. Erfolg liefert ein JSON-Objekt mit `sha256`, `location`, `length` und
`positionBinding`; eine belegte Inhaltsposition zusätzlich `line` und `decoder`.
Fehler ergeben Exit 2 mit Favenio-Diagnose. Es entsteht keine zweite Suchlogik.

## Suchaufzeichnungen (ab 0.38.0)

`captureRecording` braucht die aktuelle `runID` und einen beendeten eigenen
Suchlauf. Die Antwort enthält `recording`: Schema 1, Konfiguration, ursprüngliche
Laufkennung und Startzeit, Aufnahmezeit, Abschlusszustand, Warnungszahl, gegebenenfalls
Fehler, vollständige Treffer und Auswahl. Maximal 128 Treffer und 48.000 Byte;
Überschreitung ist `capacity`, niemals eine still gekürzte vollständige Liste.
Eine laufende Suche muss zuerst ausdrücklich mit `cancel` beendet werden.
Fähigkeiten nennen `recordingSchemaVersion: 1`, `maximumRecordingBytes: 48000`
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
Suchlauf abgebrochen. Die Eingabedatei ist auf 60.000 Byte begrenzt und muss
regulär sein; Aktionsidentitäten auf 48.000 Byte.
