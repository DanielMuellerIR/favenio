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
5. Public-Repo-Hygiene: Der Kommentar in `gui/FavenioGUI.swift` bei der
   Finder-Fenster-Ermittlung zitiert eine persönliche Rückfrage statt die
   Sache zu beschreiben. Auf eine sachliche Formulierung umstellen. Steht
   seit v0.14.0 öffentlich, ist also kein akuter Fund, sondern Nachpflege.
6. Echtes Streaming aus Archiven prüfen: `visit_member()` bekommt heute die
   fertigen Bytes, obwohl `tarfile.extractfile()` und `ZipFile.open()` einen
   Strom liefern. Nutzen nur bei sehr großen Einträgen; Haken ist, dass
   `ZipFile.open()` die CRC erst am Stromende prüft — mit Early-Exit liefe
   ein kaputter Eintrag dann still durch statt zu warnen.

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
