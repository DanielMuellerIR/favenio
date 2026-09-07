# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

1. Sichtbarer Drag-and-drop-Test am Fenster der Haupt-App: einen noch nicht
   ausgepackten Archiv-Eintrag als Dateiversprechen in den Finder ziehen
   (mehrere Dateien, langsame Extraktion, Abbruch, Fehler). Headless ist der
   Weg seit 0.32.0 geprüft (`tests/test_materialization.py`); der Test am
   Fenster braucht Daniels Freigabe.
2. Sichtbarer Test des Fensters „Suchvorlagen" (Verwalten: Laden,
   Umbenennen in der Zeile, Löschen). Headless ist alles geprüft
   (Selbsttest); das Fenster selbst wurde noch nicht am Bildschirm
   angesehen — braucht Daniels Freigabe für GUI-Fokus.
3. Sichtbarer Blick auf das neue Feld „Weitere Begriffe" (0.34.0) in beiden
   Fenstern: Es liegt unter der linken Filterspalte und macht die
   Filteransicht rund 60 pt höher; offscreen gerendert sieht es richtig aus
   (`tests/configuration_probe.swift` mit Ausgabepfad), am Fenster der
   Schnellsuche (Standardhöhe 520 pt, Tabelle darunter) noch nicht geprüft.
4. Screenshots (GUI + Schnellsuche) für die öffentlichen READMEs ergänzen.
5. Sichtbarer Sparkle-Update-Test: aus einer älteren notarisierten Fassung
   heraus auf die aktuelle aktualisieren und den Ablauf am Fenster prüfen.
   Der Appcast-Weg selbst ist gebaut und läuft in CI; was fehlt, ist der
   Durchlauf am Bildschirm.

6. Refactoring aus dem Nacht-Review vom 2026-09-06: Der Getter
   `searchConfiguration` samt `pixelFields`/`validatePixelInputs` steht in
   beiden Apps fast wortgleich (`gui/FavenioGUI.swift`,
   `quick/FavenioQuick.swift`); jede neue Option (zuletzt `--term`) muss
   zweimal nachgezogen werden. Gemeinsamer Bauer in `FavenioCore`
   (Checkboxen + `SearchFilterView` + Pixelfelder → `SearchConfiguration`)
   mit Anzeige-Callback für den Fehlerfall. Ebenso ein
   `HitListController.resetHits()`, das Trefferliste und laufende
   Auspackvorgänge an genau einer Stelle zurücksetzt — seit 0.34.1 rufen
   `startSearch`/`continueSearch`/`loadResults`/`applyTemplate` und Quicks
   `clearHits()` das getrennt.

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

Nicht offen — Mehrwortsuche: mit 0.34.0 als `--term` gebaut; Vertrag (UND
über das ganze Objekt, Belege je Begriff) in AGENTS und beiden READMEs.
Gemischte Ziele je Begriff und ODER-Verknüpfung sind nicht gebaut und wären
ein eigener Auftrag. Die Folgeaufträge vom 2026-09-05 (FOLLOWUPS.md) sind
damit alle umgesetzt; die Datei ist entfernt.

Nicht offen — benannte Suchvorlagen: mit 0.33.0 gebaut (Menü „Vorlagen",
Datei unter Application Support, versioniertes Format, Selbsttest deckt
Sichern, Laden, Umbenennen, Löschen und Migration ab).

Nicht offen — Zeilenleser: mit 0.32.1 als `iter_line_pieces()` aus
`match_content()` herausgelöst, verhaltensneutral gegen eine Kopie der alten
Fassung geprüft (`tests/test_line_reader.py`), Messung in
`tests/LINE_READER_MEASUREMENTS.md`.

Nicht offen — leerer ISO-Ordner als Datei: mit 0.31.4 behoben, der Typ
kommt aus `bsdtar -tvf`. `tools/reproduce-empty-iso.py` bleibt als Prüfung
(Exit 0 = korrekt); der Befund von vorher liegt unter
`tests/measurements/empty-iso-2026-09-05.json`.

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
