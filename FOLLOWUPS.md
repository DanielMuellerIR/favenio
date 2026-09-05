# Folgeaufträge aus der Codeanalyse vom 2026-09-05

Die Größen-, Datums- und Ausschlussfilter sind umgesetzt, ebenso die
asynchrone Materialisierung (0.32.0), der ISO-Ordnertyp (0.31.4) und der
herausgelöste Zeilenleser (0.32.1). Die
folgenden Aufträge sind getrennte Änderungen mit eigenen Abnahmen.

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
