# Folgeaufträge aus der Codeanalyse vom 2026-09-05

Die Größen-, Datums- und Ausschlussfilter sind umgesetzt, ebenso die
asynchrone Materialisierung (0.32.0), der ISO-Ordnertyp (0.31.4) und der
herausgelöste Zeilenleser (0.32.1) und die benannten Suchvorlagen (0.33.0).
Die
folgenden Aufträge sind getrennte Änderungen mit eigenen Abnahmen.

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
