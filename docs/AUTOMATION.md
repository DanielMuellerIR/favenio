# Favenio Suchsteuerung und Übergabe an Fastra

Stand: 2026-10-08. Ausgangsbasis des historischen Ausbauplans: Favenio 0.35.2.
Der [lokale Controller](LOCAL-CONTROL.md) ist mit 0.36.0 umgesetzt und
automatisch sowie im echten notarisierten Fenster geprüft. Die Editor-Übergabe ist mit 0.37.0 abgenommen. Begrenzte Suchaufzeichnungen
werden ab 0.38.0 über denselben Controller geöffnet oder ausdrücklich neu gesucht. Fastra ab 1.137.0 stellt
den geprüften Herkunftsvertrag `sourceSnapshot` bereit. Favenio 0.37.0 nutzt
ihn für begrenzte, abbrechbare Übergaben; Details im lokalen Controllervertrag.

## Ziel und Voraussetzung

Favenio soll externe Suchaufträge nachvollziehbar in seiner tatsächlichen
Oberfläche ausführen und ausgewählte Ergebnisse an Fastra übergeben können.
Der Nutzer sieht Ordner, Begriffe, Optionen, Fortschritt, Warnungen und Treffer.
Eine ausschließlich unsichtbare CLI-Suche erfüllt diesen GUI-Auftrag nicht.

Voraussetzung waren die praktisch geprüfte Fastra-Steuerung, Quellenbindung
und Bereitschaftsantwort. Diese Empfangsgrenze ist abgenommen. Favenios
Python-Kern bleibt die einzige Suchlogik.
Swift stellt Konfiguration, Prozesssteuerung und Ergebnisse dar. Such- und
Wildcard-Semantik beider Produkte bleiben getrennt; die Übergabe übersetzt
keine Muster oder Treffer still in eine andere Suchsemantik.

## Vorhandene Anschlüsse

| Code | Nutzung |
| --- | --- |
| `favenio.py` | Suche, JSONL, Progress, Diagnosen und Extraktion |
| `common/FavenioCore.swift: SearchConfiguration` | Konfiguration und Argumentbildung |
| `common/FavenioCore.swift: SearchRunner` | Prozess, begrenzter JSONL-Transport, Abbruch |
| `common/FavenioCore.swift: HitIdentity` | Identität unabhängig vom Anzeigenamen |
| `common/FavenioCore.swift: MaterializationManager` | Begrenzte asynchrone Archivmaterialisierung |
| `gui/FavenioGUI.swift: applyConfiguration` | Sichtbare Optionen setzen |
| `gui/FavenioGUI.swift: startSearch` / `launchSearch` | Regulären GUI-Suchlauf starten |
| `gui/FavenioGUI.swift: handleFavenioURL` | Bestehende private Quick-Übergabe |
| `HitListController` | Auswahl und Ergebnisaktionen |

Die Quick-Übergabe verwendet eine geprüfte Einmaldatei. Sie wird nicht durch
Weglassen ihrer Sicherheits- oder Verbrauchsregeln zu einer öffentlichen API.

## Steuerungsvertrag

Ein kleiner Controller bündelt die vorhandenen GUI-Operationen:

- Suchkonfiguration setzen und auslesen;
- Suche starten oder abbrechen;
- Status, Fortschritt und Warnungen abfragen;
- Ergebnisse begrenzt und seitenweise lesen;
- konkrete Treffer auswählen;
- ausgewählte Treffer für Fastra vorbereiten und übergeben.

Ein Auftrag trägt Request-ID, Zielfenster oder Suchsitzung und Protokollversion.
Jeder Lauf erhält eine neue Run-ID. Treffer werden zusammen mit dieser ID
adressiert; eine Tabellenposition ist keine stabile Identität. Fähigkeiten und
Status sind maschinenlesbar abfragbar.

Konfigurieren verändert zunächst die sichtbaren Eingaben. Start erzeugt einen
unveränderlichen Konfigurationsstand für den Lauf. Spätere Eingaben verändern
diesen nicht rückwirkend. Eine neue Suche verdrängt eine andere nur über eine
definierte Operation; alte Antworten gelangen nicht in den neuen Lauf.

Die erste Schnittstelle kann als kleiner Bundle-Helfer mit strukturiertem
lokalen Vertrag entstehen. Sie wertet keine Shellstrings aus und setzt
Sucheingaben nicht in frei zusammengesetzte URLs ein. Ein späterer
AppleScript-Adapter kann denselben Controller nutzen, wenn dieser Zugang
benötigt wird. Es entstehen keine neue Suchengine oder KI-Runtime.

## Ergebnisse und Vollständigkeit

Antworten enthalten Run-ID, Ergebnisgeneration oder Cursor, aktuelle Anzahl
und Suchzustand. Zu unterscheiden sind laufend, erfolgreich ohne Treffer,
erfolgreich mit Treffern, mit Warnungen beziehungsweise ungeprüften Bereichen,
abgebrochen mit Teilergebnissen und fehlgeschlagen mit bereits empfangenen
Treffern.

Exit 0 beweist nicht, dass jeder Eintrag fehlerfrei geprüft wurde. Warnungen
bleiben sichtbar. Abbruch, Fehler und Ergebnisbegrenzung erscheinen nicht als
vollständige Suche. Die bestehenden JSONL-Treffer und `type: progress` werden
weiterverwendet. Diagnosen bleiben im vorhandenen Kanal; stdout bleibt
parsebar. Der Steuerungsstatus ergänzt diesen Vertrag.

Große Ergebnislisten werden nicht bei jeder Statusabfrage vollständig kopiert.
Die API bietet begrenzte Seiten oder inkrementelle Abfragen und meldet
Begrenzungen ausdrücklich. Eine Animation ersetzt keine tatsächliche Suche.

## Gespeicherter Stand und erneute Suche

Zwei Operationen bleiben getrennt:

1. Gespeicherten Ergebnisstand öffnen: damalige Konfiguration, Treffer,
   Warnungen und Vollständigkeit anzeigen, ohne neue Suche.
2. Suche erneut ausführen: neue Run-ID und neuer Zeitstempel, möglicherweise
   andere Treffer, ohne den aufgezeichneten Stand still zu überschreiben.

Eine gespeicherte Liste garantiert noch nicht, dass damalige Dateiinhalte
später identisch verfügbar sind. Benötigte Quellen müssen zusätzlich gebunden
oder als begrenzte Snapshots übernommen werden.

## Übergabe an Fastra

Eine Übergabe enthält Suchlauf und Treffer, regulären Dateipfad oder äußeres
Archiv, vollständige Mitgliedskette, `archiveMemberBytes`, Quellengeneration,
Hash des übergebenen Inhalts, Suchbeleg samt Positionskonvention und
Kennzeichnung als Original oder schreibgeschützte Materialisierung.

`Hit.path` ist nur ein Anzeigepfad. Namen können `!/` enthalten oder bei
ungültigen Bytes dieselbe Ersatzzeichendarstellung haben. Maßgeblich bleiben
`HitIdentity` und die bytegenaue Archivkette.

Der vorhandene Extraktionsweg wird genutzt. Materialisierung ist ein
asynchroner Job. Der tatsächlich übergebene Inhalt wird eingefroren und
gehasht. Archivpfad und Zeitstempel allein belegen keine historische
Byteidentität. Eine starke Herkunftszusage braucht einen Inhaltsbezug auf das
äußere Archiv oder einen aufbewahrten Archivsnapshot. Ist eine solche
Prüfung wegen Größe oder Verfügbarkeit nicht möglich, wird die schwächere
Herkunftsbindung benannt; der eingefrorene Blattinhalt kann trotzdem exakt
gebunden sein. Zusätzliche Prüfung bleibt begrenzt und abbrechbar.

Ein Suchtreffer bleibt keine Integritätszusage für das gesamte Archiv. Die
bestehende Entscheidung zum frühen Ende einer Inhaltssuche wird nicht geändert.

### Lebensdauer und Cache

Fastras Lesedauer darf nicht von Favenios Temp-Verzeichnis abhängen: Der
bestehende Materialisierungs-Cache wird beim App-Ende entfernt. Fastra kopiert
deshalb den gewählten Inhalt asynchron in einen eigenen sitzungsgebundenen
Snapshot-Speicher und bestätigt die Übernahme erst nach Hashprüfung. Favenio
darf danach seine Zwischenkopie aufräumen. Ein dauerhaftes Erklärungsartefakt
übernimmt benötigte Snapshots ausdrücklich in dessen Ablage.

Die Ansicht zeigt Archivherkunft und Schreibschutz. Es wird nicht ins Archiv
zurückgeschrieben; eine materialisierte Kopie wird nicht als Original
ausgegeben. Schließen, Abbruch, App-Ende und fehlgeschlagene Übergabe haben
definierte Cleanup-Pfade. Nur eigene eindeutig markierte Speicherwurzeln werden
auf verwaiste Dateien geprüft.

Der heutige Cache-Schlüssel beschreibt den Treffer, nicht automatisch den
Inhaltsstand des Archivs. Neue Übergaben prüfen deshalb Cachefrische und
Quellengeneration, damit dieselbe Pfadidentität keine alte Materialisierung
liefert. Ein zwischen Suche und Übernahme veränderter Inhalt wird erkannt oder
als nicht an den ursprünglichen Treffer gebunden gekennzeichnet.

## Zeilen und Encoding

`iter_line_pieces()` decodiert Inhaltssuchen als UTF-8 mit Ersatzzeichen und
zählt Zeilen nach Python `str.splitlines()`. Zusätzlich zu Fastras üblichen
Zeilentrennern erkennt es etwa VT, FF und U+001C bis U+001E. Fastra kann ein
anderes Encoding erkennen. Eine Favenio-Zeilennummer wird daher nicht ungeprüft
als Fastra-Editorzeile verwendet.

Die Übergabe nennt Decoder- und Zeilenkonvention. Exakte Navigation ist
zunächst auf nachgewiesene Gleichheit begrenzt. Weitere Fälle benötigen einen
überprüfbaren Positionsbeleg im konkreten Inhalt und dessen Umrechnung in
Fastras Koordinaten. Dafür wird kein Suchmatcher in Swift nachgebaut.

Ist die genaue Position nicht belegbar, öffnet Fastra die richtige Quelle mit
sichtbarem Suchhinweis und erklärt die Grenze. Ein mehrdeutiger Textanker wird
nicht still seinem ersten Vorkommen zugeordnet.

## Etappen und Abnahme

### Etappe 1 Sichtbare Suche und normale Datei

Eine temporäre Fixture-Suche von außen konfigurieren und im realen Fenster
starten. Status, Abbruch, Ergebnisse und Auswahl verwenden den normalen
Controllerpfad. Einen UTF-8-Treffer mit geprüfter Positionskonvention und
Hashbindung in Fastra öffnen.

Abnahme: Optionen sind sichtbar, Ergebnisse stammen aus dem Python-Kern,
Abbruch entwertet alte Antworten, Auswahl bleibt bei nachkommenden Ergebnissen
erhalten und Fastra bestätigt Quelle und Navigation. Eine fehlende oder
inkompatible Fastra-Version ergibt eine verständliche Meldung.

### Etappe 2 Archive und stabiler Übergabestand

ZIP, TAR, verschachtelte Archive, bytegenaue Namen, veränderte Archive,
Extraktionsfehler und Materialisierungs-Lebensdauer ergänzen.

Abnahme: Nach bestätigter Übernahme kann Favenio beendet werden; Fastra zeigt
denselben schreibgeschützten Inhalt weiter. Fehlerhafte, veraltete und fehlende
Quellen werden erkannt. Archivordner und nicht materialisierbare Treffer
bleiben ausdrücklich begrenzt.

### Etappe 3 Gespeicherte Ergebnisse

Aufgezeichnete Stände und erneute Suche getrennt unterstützen. Externe
Erklärungswerkzeuge können Treffer und Snapshots in eine Fastra-Führung
übernehmen. Wiederöffnung startet nicht ungefragt eine neue Suche.

## Prüfung und Größe

Build-/Prüfregeln stehen in [AGENTS.md](../AGENTS.md) und
[README.md](../README.md). Vorgesehen sind:

- Python-Kerntests mit üblichem und mit `/usr/bin/python3`;
- `build-app.sh` und beide abschließenden `SELFTEST OK`-Nachweise;
- echte sichtbare GUI-Prüfung für Konfiguration, Progress, Auswahl und Übergabe;
- temporäre Fixtures für Nulltreffer, Teilergebnisse, Warnungen, Abbruch und
  Prozessfehler;
- ZIP/TAR und verschachtelte Archive, ungültige UTF-8-Namensbytes und `!/` im Namen;
- Archivänderung zwischen Suche, Materialisierung und Übernahme;
- Encoding- und Zeilentrennerunterschiede;
- App-Ende, verzögerte Extraktion und Cleanup;
- installierte stabile Identitäten für App-Übergabe und Berechtigungen.

Nutzerdateien dienen nicht als Fixture. Ein späterer AppleEvent-Zugang bekommt
reale AppleEvent-Tests. Verhaltensetappen aktualisieren die Version aus
`favenio.py::__version__`, beide READMEs und passende Dokumentation.

Bundle-Zuwachs wird unter gleicher Build-Konfiguration gegen eine aktuelle
Baseline gemessen. Vorhandene Prozess-/JSONL-Komponenten bleiben der Kern;
Präsentationsmedien und Quellensnapshots werden nicht gebündelt. Dieser Plan
allein verlangt keinen Versions-Bump oder Produktbuild.

## Abnahmebelege

Die umgesetzte Editor-Übergabe ist in der
[Übergabeprüfung](../tests/measurements/handoff-2026-10-08.json) belegt.
Die [Aufnahmeprüfung](../tests/measurements/recording-2026-10-08.json)
belegt Wiederöffnung ohne Suche, ausdrückliche Neusuche und gebundene Aktionen.
Diese früheren offenen Arbeiten stehen deshalb nicht mehr im Backlog.
