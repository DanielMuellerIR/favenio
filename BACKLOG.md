# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Archivtreffer asynchron für Öffnen und Quick Look vorbereiten; Drag-and-drop
   mit eigenem AppKit-Vertrag lösen. Priorität 1, Abnahme in [FOLLOWUPS.md](FOLLOWUPS.md).
2. Leere ISO-Ordner korrekt typisieren. Die Fixture in
   `tools/reproduce-empty-iso.py` reproduziert den Fehler ohne Mount;
   `tests/measurements/empty-iso-2026-09-05.json` hält den Befund fest.
   Typtragende Auflistung noch offen, Priorität 1.
3. Zeilen-/Segmentleser als eigenen verhaltensneutralen Refactor herauslösen.
   Priorität 2, Abnahme in [FOLLOWUPS.md](FOLLOWUPS.md).
4. Vollständige benannte Suchvorlagen und Mehrwortsuche als getrennte
   Funktionserweiterungen. Priorität 3, Verträge und offene Produktentscheidung
   zur Verknüpfung mehrerer Begriffe in [FOLLOWUPS.md](FOLLOWUPS.md).
5. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
6. Sichtbarer Sparkle-Update-Test: aus einer älteren notarisierten Fassung
   heraus auf die aktuelle aktualisieren und den Ablauf am Fenster prüfen.
   Der Appcast-Weg selbst ist gebaut und läuft in CI; was fehlt, ist der
   Durchlauf am Bildschirm.

## Flackernder Test: Ursache weiterhin offen

`test_sigterm_during_the_swap_restores_both_bundles`
(`tests/test_build_safety.py`) schlug am 2026-09-03 zweimal unter hoher
Systemlast fehl und war danach siebenmal grün. Der aktuelle Test wartet
bereits auf eine Bereitschaftsdatei, die genau beim Austausch der zweiten App
entsteht. Die frühere Vermutung einer bloßen festen Startwartezeit trifft
nicht zu. Am 2026-09-05 bestanden zehn weitere Wiederholungen (0,565 s gesamt).
Der ursprüngliche Fehlschlag wurde damit nicht reproduziert.

Separat bestätigt und korrigiert: Bei `communicate(timeout=5)` fehlte die
garantierte Prozessbereinigung. Ein `finally` beendet und sammelt die Shell
jetzt auch nach einem Timeout ein; ein mit echtem Prozess erzwungener Timeout
prüft das. Dies belegt keine Ursache für den ursprünglichen SIGTERM-Fehlschlag.
Bei erneutem Auftreten Bereitschaftsdatei, Prozessstatus, Ausgabe und Systemlast
sichern, bevor Timing-Grenzen geändert werden.

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
