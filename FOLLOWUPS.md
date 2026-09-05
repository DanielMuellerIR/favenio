# Folgeaufträge aus der Codeanalyse vom 2026-09-05

Die Größen-, Datums- und Ausschlussfilter sind umgesetzt. Die folgenden
Aufträge sind getrennte Änderungen mit eigenen Abnahmen.

## Priorität 1: Archivtreffer asynchron vorbereiten

`MaterializationManager.materialize()` in `common/FavenioCore.swift` liest
stdout synchron, wartet mit `waitUntilExit()` und verwirft stderr. Öffnen,
Finder-Anzeige und Quick Look können damit den Main-Thread blockieren.
Zuerst Laufzeit und Main-Thread-Verzögerung mit großen und verschachtelten
Archivtreffern messen; für diesen Pfad liegt noch keine Laufzeitmessung vor.

Materialisierung als abbrechbaren Auftrag mit Ergebnis oder konkretem
Fehlergrund anbieten. stderr nebenläufig lesen. Gleichzeitige Anforderungen
desselben Treffers teilen eine Extraktion und denselben Cache. Öffnen arbeitet
mit einer festen Trefferauswahl; Quick Look übernimmt ausschließlich die
zuletzt angeforderte Auswahl. Ladezustand und Abbruch müssen sichtbar sein.
Cache und Temp-Wurzel gegen gleichzeitigen Zugriff schützen; laufende Aufträge
dürfen nach `cleanup()` keine Dateien erneut anlegen.

Abnahme: Startfehler, beschädigtes Archiv, Budgetüberschreitung, stderr-Flut,
Abbruch, schnelle Auswahlwechsel und gleichzeitige Anforderungen prüfen.
Öffnen und Vorschau verwenden weiterhin dieselbe materialisierte Datei.
Keine synchrone Extraktion im Main-Thread; Verzögerung vorher/nachher messen.

### Drag-and-drop gesondert lösen

`tableView(_:pasteboardWriterForRow:)` in `gui/FavenioGUI.swift` verlangt heute
sofort eine fertige URL. Ein bloßes `Task.detached` erfüllt diesen Vertrag nicht.

Einen AppKit-Prototyp mit Dateiversprechen (`NSFilePromiseProvider`) gegen
vorab vorbereitete URLs vergleichen. Quelldateien weiter über denselben
Manager beziehen. Mehrere Dateien, langsame Extraktion, Abbruch, Fehler und
Übernahme durch den Finder prüfen; Temp-Dateien erst nach ihrer Verwendung
bereinigen. Den sichtbaren Drag-and-drop-Test gesondert freigeben lassen.

## Priorität 1: Leere ISO-Ordner korrekt typisieren

`tools/reproduce-empty-iso.py` erzeugt ohne Mount ein ISO mit leerem Ordner
und prüft beide `--only`-Varianten. Am 2026-09-05 reproduziert: `bsdtar -tf`
nennt `empty` ohne Schrägstrich; die Suche meldet ihn als Datei. Der Bericht
liegt unter `tests/measurements/empty-iso-2026-09-05.json`. Exit 1 des
Repro-Skripts bestätigt diesen offenen Fehler; Exit 0 bedeutet korrekte Typen.

Eine typtragende Auflistung für das bsdtar-Backend implementieren. Vor einer
Parserwahl Namen mit Leerzeichen, Steuerzeichen und Maskierungen sowie 7z,
ISO und tar.zst prüfen. Ein blindes Zerlegen der menschenlesbaren Ausgabe von
`bsdtar -tvf` reicht nicht. Namenssuche, `--only`, JSONL-`isDirectory` und
Materialisierung müssen anschließend denselben Typ verwenden. Die bestehende
Fixture muss ohne Änderung ihrer Erwartung erfolgreich sein.

## Priorität 2: Zeilen- und Segmentleser herauslösen

`Search.match_content()` in `favenio.py` verbindet UTF-8-Dekodierung,
Zeilentrennung, Überlappung, Längengrenze und Matching. Den Leser in einem
eigenen verhaltensneutralen Refactor herauslösen; keine gleichzeitige Optimierung.

Jedes Element muss Zeilennummer, vollständige Zeile oder Fragment und das
Erreichen des Zeilenendes unterscheiden. Auch das letzte Fragment einer
langen Zeile darf nicht als vollständige Zeile gelten. Nur reine
Substring-Matcher dürfen Fragmente prüfen; Regex, Glob und Exact behalten
die bisherige Warnung und überspringen die zu lange Zeile.

Abnahme: bisherige und neue Implementierung mit denselben Eingaben vergleichen:
LF, CRLF über Chunkgrenzen, einzelnes CR, sämtliche bisherigen Zeilentrenner,
UTF-8-Grenzen und Ersatzzeichen, letzte Zeile ohne Umbruch, leere Zeilen,
überlange Zeilen und Treffer im Überlappungsbereich. Treffer, Zeilennummern,
Warnungen und frühes Leseende müssen identisch bleiben. Archivbudgets und
Inhaltsvortest bleiben unverändert. Speicher und Laufzeit für kurze und lange
Zeilen dokumentieren.

## Priorität 3: Vollständige benannte Suchvorlagen

`RegexTemplate` und `insertTemplate()` in `gui/FavenioGUI.swift` setzen heute
nur einen Regex in das Suchfeld. Sie sind keine gespeicherten Suchaufträge.

Ein versioniertes Vorlagenformat auf `SearchConfiguration` aufbauen und um
Name, Suchmuster und ausdrücklich gewählten Suchordner ergänzen. Alle
Optionen einschließlich Ausschlüssen, Maßfeldern, Größen-/Datumsgrenzen und
Metadatenfeld vollständig speichern. Rohtexte erhalten, damit ungültige Werte
beim Laden sichtbar bleiben. Lokal außerhalb des Repositorys speichern;
fehlende Suchordner konkret melden. Laden befüllt zunächst die Oberfläche,
ohne automatisch eine Suche zu starten. Keine Trefferlisten speichern.

Abnahme: Speichern, Laden, Umbenennen, Löschen und Formatmigration prüfen.
Geladene Vorlage, CLI-Argumente und Quick-Übergabe müssen dieselbe Suche
beschreiben. Regex-Vorlagen bleiben als getrennte Einfügehilfe erhalten.

## Priorität 3: Mehrwortsuche als eigene Funktionserweiterung

Die bestehende Eingabe `PATTERN` bleibt unverändert: Leerzeichen trennen
keine Suchbegriffe. Mehrere Begriffe benötigen eine ausdrückliche,
wiederholbare CLI-Option und eine entsprechende Eingabe in beiden Apps.
Suchsemantik weiterhin ausschließlich im Python-Kern implementieren.

Vor der Umsetzung den Vertrag festlegen: UND-Verknüpfung im ganzen Objekt
oder innerhalb derselben Inhaltszeile beziehungsweise desselben
Metadatenwerts. Für Treffer auf verschiedenen Zeilen/Feldern muss die
Ausgabe alle erforderlichen Belege ausdrücken können; das bisherige einzelne
`line` beziehungsweise `field` reicht dafür nicht. Gemischte Suchmodi und
ODER-Verknüpfungen sind ein weiterer Auftrag.

Abnahme: getrennte Begriffe, zusammenhängende Phrase, doppelte Begriffe,
leere Eingaben, Groß-/Kleinschreibung, Regex/Glob/Exact und Begriffe auf
verschiedenen Zeilen/Feldern prüfen. Trefferbelege sowie CLI, Haupt-App und
Quick-Übergabe müssen übereinstimmen. Kriterien früh abbrechen und Inhalte
nicht erneut für jeden Begriff vollständig lesen.
