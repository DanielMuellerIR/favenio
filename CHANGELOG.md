# Changelog

## 0.18.0 — 2026-07-25

- Die drei Skripte sind jetzt jedes für sich vollständig: `build-app.sh` baut,
  `install.sh` baut + notarisiert + installiert nach `/Applications`,
  `release.sh` baut + notarisiert + packt und notarisiert das DMG. Eine
  Installation braucht damit kein vorheriges Release mehr.
- Die Notarisierung der Bundles ist ein gemeinsamer Weg (`notarize-lib.sh`,
  wird eingebunden, nicht ausgeführt): beide Apps zusammen in einem Zip zu Apple
  — `notarytool` nimmt kein nacktes `.app` — und anschließend einzeln gestapelt.
  Dadurch tragen auch aus dem DMG herausgezogene Apps ihr Ticket und starten
  ohne Netz.

- Neu `--exact` (`-e`): Das Muster muss dem ganzen Namen entsprechen. Ohne die
  Option ist ein Muster ohne Platzhalter ein Teilstring — `release.sh` fand
  deshalb auch `test-github-release.sh`. Mit `--regex` wird aus `search` ein
  `fullmatch`; Glob-Muster matchen ohnehin den ganzen Namen. Beide Apps haben
  dafür den Schalter „Genauer Name", die Schnellsuche gibt ihn an die Haupt-App
  weiter.
- Neu `--max-depth N`: nur N Ordnerebenen tief suchen, deckungsgleich mit
  `find -maxdepth`. Für „welche Projekte haben ein Release-Skript" fiel die
  Laufzeit über `~/git` damit von 0,31 s auf 0,07 s.
- Die Finder-Abfrage nutzt `URL of` statt `as alias` und `front Finder window`
  statt `front window`. Gemessen mit 13 offenen Fenstern, Median aus sieben
  Läufen: 185 ms vorher, 147 ms jetzt, davon 34 ms reiner Prozessstart. Die
  Fensterliste kostet gegenüber der Einzelabfrage nur rund 2 ms; `front Finder
  window` überspringt Info- und Hilfsfenster.
- Vor der Abfrage klärt `AEDeterminePermissionToAutomateTarget` ohne Event und
  ohne Dialog, ob die Automation erlaubt ist. Verbotene Automation wird damit
  sofort erkannt statt aus einem hängenden Unterprozess erschlossen; der Not-Aus
  sinkt von 12 s auf 6 s. Steht der Freigabedialog offen, wird gewartet statt
  abgebrochen — und das auch so gemeldet.
- Der Suchbereich der Schnellsuche zeigt den Pfad statt nur des Ordnernamens,
  und der Button „Alle in Favenio" nennt sein Tastenkürzel.

## 0.17.0 — 2026-07-25

- Die Finder-Ordner werden in einer einzigen Apple-Event-Abfrage geholt statt
  Fenster für Fenster. Gemessen mit 13 offenen Finder-Fenstern: 11,6 s vorher,
  0,19 s jetzt. Die alte Schleife lief regelmäßig in den 12-s-Not-Aus — die
  Schnellsuche startete dann kommentarlos im Benutzerordner statt im Ordner des
  vordersten Finder-Fensters.
- Scheitert die Finder-Abfrage trotzdem, wird der Grund gemeldet statt still auf
  den Benutzerordner zurückzufallen: verweigerte Automation, kein offenes
  Fenster oder Zeitüberschreitung. Bei verweigerter Automation nennt ein
  einmaliger Hinweis den Weg zur Freigabe.
- Die Schnellsuche startet keine Suche mehr im Ersatzordner, solange der
  Finder-Ordner noch aussteht: Das Bereichsmenü zeigt „Finder-Ordner wird
  ermittelt…", die Suche wartet höchstens zwei Sekunden und nennt danach
  sichtbar den tatsächlich durchsuchten Ordner.
- Ein selbst gewählter Suchbereich bleibt wählbar, auch wenn sein Finder-Fenster
  inzwischen geschlossen wurde.
- Neu: `--finder-scope` in beiden Apps — eine headless JSON-Diagnose, die aus
  dem echten App-Bundle heraus zeigt, welche Finder-Ordner erkannt werden.
- Neu: `install.sh` als drittes Skript neben `build-app.sh` und `release.sh`.
  Es installiert ein Release-DMG nach `/Applications`, aber nur mit angeheftetem
  Notary-Ticket und Gatekeeper-Akzeptanz, prüft beide Bundles vor und nach dem
  Kopieren und tauscht erst nach vollständigem Kopiervorgang. `--verify-only`
  prüft ohne zu installieren.

## 0.16.0 — 2026-07-22

- Archivmitglieder werden für Inhaltssuchen gestreamt und durch konfigurierbare
  Einzel-, Gesamt- und Kompressionsgrenzen geschützt.
- Verschlüsselte oder nicht unterstützte ZIP-Mitglieder erzeugen kontrollierte
  Warnungen; Extraktion endet ohne Traceback mit Exit-Code 2.
- Hidden-Komponenten in ZIP-/Tar-Pfaden werden vollständig berücksichtigt.
- JSONL überträgt Dateisystempfad und Archivkette strukturiert; normale Pfade
  mit `!/` bleiben dadurch in den Apps eindeutig.
- GUI-Suchläufe besitzen getrennte Prozessgenerationen und Puffer. Späte Daten
  eines abgebrochenen Laufs können keine neue Suche mehr beenden oder mischen.
- Materialisierte Archivtreffer werden pro App-Lauf wiederverwendet und beim
  Beenden aus einem app-eigenen Temp-Root entfernt.
- Quick-Handoffs werden atomar mit Besitzer- und Größenprüfung geschrieben,
  begrenzt gestreamt gelesen und nach jedem Verbrauch gelöscht.
- Swift-Streaming liefert Treffer nur noch per Callback statt sie zusätzlich
  als zweite Treffer- und JSONL-Kopie im Speicher zu sammeln; der wirkungslose
  Python-Fehlerzustand wurde entfernt.
- Der Sortier-Comparator ist auch absteigend bei Gleichständen strikt.
- `build-app.sh` baut und testet ausschließlich im Repository. Nur das fertig
  signierte, gestapelte und von Gatekeeper akzeptierte Release-DMG ist für eine
  bewusste Installation vorgesehen.
