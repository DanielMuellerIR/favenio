# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Größen-/Datumsfilter und Mehrwortmodus als getrennte Produktentscheidungen.
2. Zusätzliche Archivformate nur als sauber erkannte optionale Integration.
3. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
4. CLI-Wart, nachgestellt und bestätigt: eine Option MIT Wert darf nicht
   zwischen Muster und Startpfad stehen. `--content X --archive-depth 2 PFAD`
   und `--content X --jobs 4 PFAD` brechen beide mit „unrecognized arguments"
   und Exit 2 ab — argparse trennt die Positionsargumente an der Option auf.
   Vor dem Muster oder hinter allen Positionsargumenten funktioniert es.
   Der Wart ist alt (auch v0.14.0 zeigt ihn), nur `--jobs` macht ihn sichtbarer.
   Dazu neu: `--jobs` ohne Zahl frisst ein direkt folgendes Positionsargument
   (`--jobs PFAD` → „invalid int value"), weil es das einzige `nargs="?"` ist.
   Entweder Parsing umbauen (z. B. `nargs="?"` streichen und Auto nur über
   `--jobs 0`) oder die Reihenfolge in beiden READMEs festschreiben.
5. Entscheiden, ob `--jobs` eine GUI-Einstellung bekommt. Bisher bewusst nicht
   verdrahtet: die parallele Suche lohnt nur bei langsamem Speicher und kostet
   bei warmem Cache — in der GUI bräuchte sie also Erklärung, nicht nur einen
   Schalter.
6. Echtes Streaming aus Archiven prüfen: `visit_member()` bekommt heute die
   fertigen Bytes, obwohl `tarfile.extractfile()` und `ZipFile.open()` einen
   Strom liefern. Nutzen nur bei sehr großen Einträgen; Haken ist, dass
   `ZipFile.open()` die CRC erst am Stromende prüft — mit Early-Exit liefe
   ein kaputter Eintrag dann still durch statt zu warnen.

Nicht offen: der frühere Finder-Ordner-Fehler; `osascript` als Unterprozess ist
die verifizierte Lösung und eine Dauerregel.
