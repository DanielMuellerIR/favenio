# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Größen-/Datumsfilter und Mehrwortmodus als getrennte Produktentscheidungen.
2. Zusätzliche Archivformate nur als sauber erkannte optionale Integration.
3. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
4. CLI-Wart: Optionen MIT Wert (`--archive-depth`, `--jobs`) dürfen nicht
   zwischen Muster und Startpfad stehen — argparse ordnet den Startpfad dann
   keinem Positionsargument mehr zu und bricht mit Exit 2 ab. Betrifft den
   bisherigen Stand genauso; Optionen vor dem Muster funktionieren. Entweder
   Parsing umbauen oder die Reihenfolge im README festschreiben.
5. `--jobs` bewusst nicht in den Swift-Apps verdrahtet: die parallele Suche
   lohnt nur bei langsamem Speicher und wäre in der GUI eine eigene
   Produktentscheidung (Einstellung plus Erklärung, wann sie hilft).

Nicht offen: der frühere Finder-Ordner-Fehler; `osascript` als Unterprozess ist
die verifizierte Lösung und eine Dauerregel.
