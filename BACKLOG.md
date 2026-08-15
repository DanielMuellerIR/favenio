# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Größen-/Datumsfilter und Mehrwortmodus als getrennte Produktentscheidungen.
2. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
3. CLI-Wart, nachgestellt und bestätigt: eine Option MIT Wert darf nicht
   zwischen Muster und Startpfad stehen. `--content X --archive-depth 2 PFAD`
   bricht mit „unrecognized arguments" und Exit 2 ab — argparse trennt die
   Positionsargumente an der Option auf. Vor dem Muster oder hinter allen
   Positionsargumenten funktioniert es. Der Wart ist alt, schon v0.14.0 zeigt
   ihn. Entweder Parsing umbauen oder die Reihenfolge in beiden READMEs
   festschreiben.
## Offen aus der Code-Review-Triage 2026-08-05

- Team-ID im Release-Tor erzwingen. `codesign --verify --strict` beantwortet
  nur „gültig signiert", nicht „von uns": Ohne `-R=`-Requirement käme ein
  fremdes, ebenfalls notarisiertes Bundle durch. Betroffen sind
  `.github/workflows/publish-appcast.yml` (~140, im Bundle-Loop) und
  `release.sh` (~152, Schritt 4). `release.sh` ruft außerdem
  `favenio_verify_identity` überhaupt nicht auf — die Funktion aus
  `notarize-lib.sh` (~153) nutzt bislang nur `install.sh` (~120). Offen ist
  auch, woher der Workflow die Team-ID nimmt: Sie steht bewusst nicht im
  öffentlichen Repo, bräuchte also ein GitHub-Secret oder eine Variable.
## Offen aus der Code-Review-Triage 2026-08-02

- Leerer Ordner in einem ISO wird als Datei geführt. `bsdtar -tf` listet ihn
  ohne Schrägstrich, und ohne Kinder greift die Ordner-Erkennung nicht;
  `--only files --exact <name>` findet ihn deshalb, `--only dirs` nicht. Ein
  sauberer Fix braucht eine typtragende Auflistung (etwa `bsdtar -tvf`,
  dessen erste Spalte den Typ nennt) — die ist aber schwerer verlässlich zu
  zerlegen als die reine Namensliste. Vor der Umsetzung: leeren ISO-Ordner
  als Fixture ergänzen.
- Fallback-Start der Schnellsuche verliert die Suchoptionen. Klappt das
  URL-Schema nicht, startet FavenioQuick die Haupt-App mit `--query` und
  `--results-file`; Wurzel, „Genauer Name", Inhalt, Archive und Unsichtbare
  gehen dabei verloren. Die übergebenen Treffer stammen dann aus einer
  anderen Suche als die, die die Haupt-App danach anzeigt. Entweder
  Startargumente und Parser um alle Optionen erweitern oder denselben
  strukturierten Übergabedatensatz wie im URL-Weg verwenden.

## Niedrigprior (Code-Review-Triage 2026-07-24)

Aus der Review-Triage vom 2026-07-24 (Quelle: MiniMax-Review, von Opus
verifiziert). Kosmetik und bewusste Tradeoffs, keine Bugs.

- `common/FavenioCore.swift` (~344–360): Materialisierung liest die
  Unterprozess-Ausgabe synchron auf dem Main-Thread (`readDataToEndOfFile`).
  Bewusster Tradeoff — entweder als solchen kommentieren oder später auf
  `Task.detached` umstellen.
- `favenio.py` (~516–528, `walk_tar`): Die Kompressions-Ratio-Heuristik greift
  nur bei ZIP; für TAR schützen allein die Byte-Budgets (per-Member-Ratio bei
  tar nicht ermittelbar). Klarstellenden Kommentar ergänzen.

Nicht offen: der frühere Finder-Ordner-Fehler; `osascript` als Unterprozess ist
die verifizierte Lösung und eine Dauerregel.

Nicht offen — zusätzliche Archivformate: mit 0.20.0/0.21.0 umgesetzt.
Einzelne .gz/.bz2/.xz liest die Standardbibliothek; 7z, ISO und tar.zst
kommen über das System-bsdtar, einzelne .zst über ein gefundenes
zstd-Programm (Homebrew-Pfade werden geprobt). Ohne Werkzeug bleiben die
Dateien normale Dateien. Einzelne rohe .zst kann bsdtar selbst NICHT lesen
(„Unrecognized archive format", verifiziert 2026-07-29), deshalb der direkte
zstd-Weg.

Nicht offen — ZIP-CRC nach frühem Inhaltstreffer: entschieden mit 0.19.0. Die
CRC bleibt ungeprüft, weil das Lesen beim ersten Treffer endet; ein Treffer ist
ein Fund, keine Integritätszusage. Steht so in AGENTS und in beiden READMEs.

Nicht offen — parallele Inhaltssuche (`--jobs`): gebaut, gemessen und bewusst
wieder entfernt. Messung auf 174-MB-Korpus mit System-Python 3.9.6 zeigte einen
Gewinn nur bei ungecachtem Lesen (~1,9x), dagegen Verluste bei warmem Cache
(0,68x bei 3000 kleinen Dateien) — Dekodieren, `splitlines()` und Matcher laufen
alle unter der GIL, nur `read()` gibt sie frei. Der Nutzen rechtfertigte Pool,
Sperre und Auftragsbuchhaltung im Kern nicht. Details in der Historie um
v0.15.0. Vor einem neuen Anlauf bräuchte es einen Datenpfad, der die GIL
wirklich freigibt — sonst wird das Ergebnis dasselbe.
