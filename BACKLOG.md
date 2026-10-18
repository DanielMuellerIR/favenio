# Favenio — offene Arbeit

Vor jedem Punkt gegen Code und Git verifizieren. Erledigte Punkte in Changelog
oder Release Notes verschieben, nicht im AGENTS-Dauerprompt belassen.

## Umgesetzter Funktionsausbau

Der umgesetzte Ausbau steht in [docs/ROADMAP.md](docs/ROADMAP.md): ein grafischer
Kriterieneditor mit verschachtelten UND-/ODER-Gruppen, Unicode/Encoding,
Fundstellenkontext, Suchberichte, logischer Dokumenttext, Trefferfilter und
Gruppierung, Archivnavigation, mehrere Suchwurzeln, Datumshilfen,
Finder-Tags/-Kommentare, Cloud-Platzhalter, lokale OCR, Miniaturen und eine
explizite Dublettenprüfung. Als erste Stufe ist der CLI-Kriterienbaum für
Name, Endung und relativen Pfad umgesetzt, einschließlich Zeileneditor in der
Haupt-App und Quick sowie versionierten Vorlagen, Übergaben und Aufzeichnungen.
Inhalt, Metadaten, Größen, Zeitpunkte und Bildmaße sind ebenfalls als
Baumkriterien umgesetzt. Normale Suchen und Ausschlüsse vergleichen kanonisch
gleiche Unicode-Schreibweisen, ohne Originalidentitäten zu verändern.
UTF-16 mit BOM-Automatik und ausdrücklich gewählte Legacy-Kodierungen sind
umgesetzt. Eine zuschaltbare begrenzte Fundstellenvorschau im Suchfenster erfasst
erste Inhaltsbelege mit Originalhervorhebung und Quellbindung. Weitere Fundstellen
und zusätzlicher Kontext lassen sich begrenzt und abbrechbar auf Anforderung laden.
Strukturierte Auslassungsgründe und ein begrenzter Suchbericht mit JSON-Export
sind in beiden Apps umgesetzt. PDF-Dokumenttext mit Seitenbelegen, begrenztem
Nachladen und optionalem PDFKit-Helfer sowie DOCX mit zusammengeführten
Textläufen, Tabellen und Teil-/Absatzbelegen sowie ODT-/EPUB-Text mit
Absatz-/Kapitelbelegen sowie XLSX-Zelltext mit Blatt-/Zellbelegen und PPTX mit Folien-/Objekt-/Absatzbelegen sind ebenfalls
umgesetzt. Reversible Trefferfilter auf bekannten Namen, Pfaden, Endungen und
Fakten sind ebenfalls verfügbar; [Vertrag](docs/RESULT_FILTER.md). Gruppierung
nach Ordner/Endung/Quellarchiv und getrennte Navigation zur äußeren Archivdatei
samt Archivkette sind umgesetzt; [Vertrag](docs/RESULT_GROUPS.md). Mehrere geordnete Datei-/Ordnerbereiche mit Herkunft, Deduplikation und versionierten Transporten sind umgesetzt; [Vertrag](docs/SEARCH_ROOTS.md). Die gewählten Erweiterungen sind umgesetzt; Formatgrenzen und optionale
Erweiterungen stehen in den jeweiligen Verträgen und verbleibenden Punkten.
Der Vergleich gespeicherter Suchstände bleibt lediglich eine mögliche Idee.


Gemeinsame Kalender-/Uhrzeiteingaben und relative Datumsbereiche sind umgesetzt,
mit festen oder pro Start neu aufgelösten Vorlagen und erhaltenen Laufbelegen.
[Vertrag](docs/DATE_RANGES.md).

## SIGTERM-Diagnose: Messauftrag abgeschlossen, historische Ursache offen

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

Der begrenzte Messauftrag vom 2026-10-06 ist abgeschlossen: 20 Wiederholungen
unter vorhandener Last und 20 mit vier zusätzlichen, zeitlich begrenzten
CPU-Prozessen bestanden. Vor jedem Signal war die Bereitschaft bestätigt und
die Shell lief noch; jeder Test endete mit Status 2, stellte beide alten
Bundles wieder her und hinterließ keine Transaktionsreste. Der ursprüngliche
Fehler wurde nicht reproduziert; Installer und Timeouts bleiben unverändert.
Zusammenfassung: [SIGTERM-Messung](tests/measurements/sigterm-2026-10-06.json).
Wiederholbarer Aufruf: `python3 tools/measure-sigterm.py --output /tmp/sigterm.json`.
Weitere Diagnose erst bei einem neuen tatsächlichen Fehlschlag.

Nicht offen — Mehrwortsuche: mit 0.34.0 als `--term` gebaut; Vertrag (UND
über das ganze Objekt, Belege je Begriff) in AGENTS und beiden READMEs.
Der strukturierte Kriterienbaum kombiniert außerdem unterschiedliche Ziele und
verschachteltes UND/ODER; beide Apps bieten dafür denselben Zeileneditor.
Die Folgeaufträge vom 2026-09-05 (FOLLOWUPS.md) sind
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

Finder-Tags und Finder-Kommentare sind mit separaten Kriterien, begrenzten
Snapshots, grafischem Ansichtsfilter, Vorschau, optionalen Spalten und
versionierten App-Transporten verfügbar; [Vertrag](docs/FINDER_METADATA.md).

Die ausdrücklich wählbare lokale Inhaltspolitik für iCloud-Platzhalter ist
umgesetzt. Namen und bekannte Fakten bleiben nutzbar; nicht lokale und unbekannte
Inhalte werden mit Abdeckungsgründen ausgelassen. Unterstützung und Grenzen:
[Lokale Inhalte](docs/LOCAL_CONTENT.md). Weitere Provider bleiben offen, bis ihre
Zustände zuverlässig belegt sind.

Die umschaltbare Miniaturansicht ist in beiden Apps mit gemeinsamen Aktionen und begrenztem lokalen Hintergrundcache verfügbar; [Vertrag](docs/THUMBNAILS.md).

OCR von Bildern innerhalb anderer Office-Dokumente bleibt offen; Bild- und textlose PDF-Seiten verwenden bereits getrennte Opt-ins mit dokumentierten Grenzen.

Die explizite Dublettenprüfung normaler Dateien ist in beiden Apps mit vollständigem SHA-256, Bytebestätigung und nachvollziehbaren Teilprüfungen verfügbar; [Vertrag](docs/DUPLICATES.md). Archivmitglieder werden über denselben Materialisierer einbezogen; Rohidentitäten, Quellwachen und befristete Leases bleiben erhalten.
