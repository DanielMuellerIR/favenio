# Folgeaufträge aus der Codeanalyse vom 2026-09-05

Die Größen-, Datums- und Ausschlussfilter sind umgesetzt, ebenso die
asynchrone Materialisierung (0.32.0) und der ISO-Ordnertyp (0.31.4). Die
folgenden Aufträge sind getrennte Änderungen mit eigenen Abnahmen.

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
