# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Größen-/Datumsfilter und Mehrwortmodus als getrennte Produktentscheidungen.
2. Zusätzliche Archivformate nur als sauber erkannte optionale Integration.
3. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
4. CLI-Wart, nachgestellt und bestätigt: eine Option MIT Wert darf nicht
   zwischen Muster und Startpfad stehen. `--content X --archive-depth 2 PFAD`
   bricht mit „unrecognized arguments" und Exit 2 ab — argparse trennt die
   Positionsargumente an der Option auf. Vor dem Muster oder hinter allen
   Positionsargumenten funktioniert es. Der Wart ist alt, schon v0.14.0 zeigt
   ihn. Entweder Parsing umbauen oder die Reihenfolge in beiden READMEs
   festschreiben.
5. ZIP-CRC nach frühem Inhaltstreffer als Produktentscheidung klären. Das neue
   Archiv-Streaming beendet das Lesen absichtlich beim ersten Treffer; Python
   prüft die CRC eines `ZipExtFile` jedoch erst am Dateiende. Vollständiges
   Drainen würde den Early-Exit-Vorteil aufheben und muss weiterhin innerhalb
   der Archivbudgets bleiben.
## Niedrigprior (Code-Review-Triage 2026-07-24)

Aus der Review-Triage vom 2026-07-24 (Quelle: MiniMax-Review, von Opus
verifiziert). Kosmetik und bewusste Tradeoffs, keine Bugs.

- `common/FavenioCore.swift` (~344–360): Materialisierung liest die
  Unterprozess-Ausgabe synchron auf dem Main-Thread (`readDataToEndOfFile`).
  Bewusster Tradeoff — entweder als solchen kommentieren oder später auf
  `Task.detached` umstellen.
- `quick/FavenioQuick.swift` (~362–372): Fällt ein zuvor gewählter
  Finder-Ordner aus der neu gebauten Liste, springt die Auswahl kommentarlos
  auf Index 0. Stillen Reset entweder bewusst dokumentieren oder abfangen.
- `favenio.py` (~516–528, `walk_tar`): Die Kompressions-Ratio-Heuristik greift
  nur bei ZIP; für TAR schützen allein die Byte-Budgets (per-Member-Ratio bei
  tar nicht ermittelbar). Klarstellenden Kommentar ergänzen.
- `favenio.py:583`: Ungenutzte Schleifenvariable `index` durch `_` ersetzen
  (reine Kosmetik, beim nächsten Anfassen miterledigen).

Nicht offen: der frühere Finder-Ordner-Fehler; `osascript` als Unterprozess ist
die verifizierte Lösung und eine Dauerregel.

Nicht offen — parallele Inhaltssuche (`--jobs`): gebaut, gemessen und bewusst
wieder entfernt. Messung auf 174-MB-Korpus mit System-Python 3.9.6 zeigte einen
Gewinn nur bei ungecachtem Lesen (~1,9x), dagegen Verluste bei warmem Cache
(0,68x bei 3000 kleinen Dateien) — Dekodieren, `splitlines()` und Matcher laufen
alle unter der GIL, nur `read()` gibt sie frei. Der Nutzen rechtfertigte Pool,
Sperre und Auftragsbuchhaltung im Kern nicht. Details in der Historie um
v0.15.0. Vor einem neuen Anlauf bräuchte es einen Datenpfad, der die GIL
wirklich freigibt — sonst wird das Ergebnis dasselbe.
