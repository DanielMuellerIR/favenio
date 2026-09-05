# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Mehrwortmodus als eigene Produktentscheidung spezifizieren.
2. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
3. Sichtbarer Sparkle-Update-Test: aus einer älteren notarisierten Fassung
   heraus auf die aktuelle aktualisieren und den Ablauf am Fenster prüfen.
   Der Appcast-Weg selbst ist gebaut und läuft in CI; was fehlt, ist der
   Durchlauf am Bildschirm.

## Flackernder Test 2026-09-03

`test_sigterm_during_the_swap_restores_both_bundles`
(`tests/test_build_safety.py`) schlug am 2026-09-03 zweimal fehl und war
danach in sieben Läufen hintereinander grün. Beide Male lag die Systemlast
des Rechners bei rund 100 (fremde Prozesse anderer Projekte). Der Test
schickt SIGTERM an ein Shell-Skript und prüft danach den Zustand — unter
extremer Last ist das zeitkritisch. Zu klären: ob der Test auf eine feste
Wartezeit baut, die sich durch ein Warten auf einen Zustand ersetzen lässt.
Nicht reproduziert, deshalb keine Änderung.

## Offen aus der Code-Review-Triage 2026-08-02

- Leerer Ordner in einem ISO wird als Datei geführt. `bsdtar -tf` listet ihn
  ohne Schrägstrich, und ohne Kinder greift die Ordner-Erkennung nicht;
  `--only files --exact <name>` findet ihn deshalb, `--only dirs` nicht. Ein
  sauberer Fix braucht eine typtragende Auflistung (etwa `bsdtar -tvf`,
  dessen erste Spalte den Typ nennt) — die ist aber schwerer verlässlich zu
  zerlegen als die reine Namensliste. Vor der Umsetzung: leeren ISO-Ordner
  als Fixture ergänzen.

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
