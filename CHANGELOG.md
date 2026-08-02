# Changelog

## 0.21.1 — 2026-08-03

Korrekturen aus einer Code-Review-Triage; jeder Punkt mit Repro und
Regressionstest.

- **Archivbudget:** Der zweite Lesedurchlauf über ein Treffer-Mitglied war
  komplett von `--max-archive-total-bytes` befreit. Bei `--exact` und einer
  sehr langen Zeile liest der genaue Lauf weiter als der Vortest — damit ließ
  sich das Gesamtbudget um Größenordnungen umgehen. Freigestellt bleibt jetzt
  nur, was der Vortest wirklich gelesen hat.
- **`--max-depth`:** Ordner genau auf der Grenztiefe fehlten. `--max-depth 1
  --only dirs` fand gar nichts, obwohl `find -maxdepth 1` die direkten
  Unterordner listet.
- **Inhalts-Vortest und griechisches Sigma:** „Σ" wird am Wortende zu „ς",
  sonst zu „σ". Weil der Vortest Häppchen sieht und der genaue Lauf ganze
  Zeilen, verschluckte er an der Häppchengrenze einen echten Treffer.
- **`.tar.zst` ohne bsdtar:** Die Datei fiel in den Zweig für einzelne
  `.zst`-Dateien, und der entpackte Tar-Strom erschien als ein Mitglied
  `a.tar`. Ohne das nötige Werkzeug bleibt sie jetzt eine normale Datei.
- **Eintragsnamen aus bsdtar-Archiven:** `bsdtar -tf` maskiert Steuerzeichen
  und Backslashes. Betroffene Einträge (7z, ISO, tar.zst) trugen deshalb einen
  falschen Pfad und ließen sich weder durchsuchen noch extrahieren.
- **Schnellsuche:** Wartet sie auf den Finder-Ordner, blieb die Trefferliste
  der vorigen Suche stehen; ⌘↩ übergab der Haupt-App dann alte Treffer unter
  neuem Suchtext. Außerdem überschrieb der Trefferzähler eine Warnung zum
  unbestätigten Suchbereich — nach dem Stopp bei 20 Treffern dauerhaft.
- **`install.sh`:** prüft jetzt auch die Produktidentität (Bundle-IDs und
  gleiche Version beider Apps), tauscht beide Bundles als eine Transaktion mit
  Rückholung des alten Stands und endet bei jedem Fehler wirklich mit Exit 2
  statt mit dem Status des ausgelösten Werkzeugs.

## 0.21.0 — 2026-07-29

- Neue Archivformate über externe Werkzeuge, sauber erkannt und rein optional:
  Mit dem System-`bsdtar` (in macOS enthalten) liest Favenio jetzt auch
  **7z**-Archive und **ISO**-Abbilder; ist zusätzlich ein `zstd`-Programm
  installiert (z. B. über Homebrew, wird automatisch gefunden — auch ohne
  Homebrew im PATH), kommen **tar.zst** und einzelne **.zst**-Dateien dazu.
  Fehlen die Werkzeuge, bleiben diese Dateien einfach normale Dateien.
- Namenssuche, Inhaltssuche mit Zeilennummer, `!/`-Notation, Verschachtelung
  und Extraktion funktionieren in den neuen Formaten wie bei Zip und Tar;
  die Byte-Budgets greifen beim Lesen.
- Glob-Zeichen in Eintragsnamen werden beim bsdtar-Zugriff entschärft: ein
  Eintrag `a*.txt` liefert exakt diesen Eintrag, nicht zusätzlich `abc.txt`.

## 0.20.0 — 2026-07-29

- Einzeln komprimierte Dateien (**gz**, **bz2**, **xz** — ohne die weiterhin
  als Tar behandelten `.tar.gz` & Co.) werden als Archive mit genau einem
  Eintrag durchsucht: `notiz.txt.gz` enthält `notiz.txt`. Damit greifen
  Namenssuche, Inhaltssuche mit Zeilennummer, `!/`-Notation, Verschachtelung
  (`inner.zip.gz` genauso wie `log.gz` in einem Zip) und `--extract` —
  ausschließlich mit der Python-Standardbibliothek.
- Kaputte oder abgeschnittene Kompressionsströme erzeugen eine Warnung auf
  stderr, die Suche läuft weiter. Die entpackte Größe ist bei diesen Formaten
  vorab unbekannt; die Byte-Budgets greifen deshalb beim Lesen.

## 0.19.0 — 2026-07-28

- Die Inhaltssuche ist deutlich schneller, ohne dass sich ein Ergebnis ändert.
  Bei festem Suchtext (ohne `--regex`, ohne Platzhalter) prüft ein billiger
  Vortest zuerst, ob der Text überhaupt vorkommt; die Zeilennummer wird erst
  bei einem echten Treffer in einem zweiten Durchlauf bestimmt. Gemessen mit dem
  System-Python auf 72,8 MB Text (2877 Dateien), Bestwert aus drei Läufen,
  Trefferlisten in allen Fällen identisch:

  | Fall | vorher | jetzt |
  | --- | --- | --- |
  | kein Treffer | 0,653 s | 0,339 s |
  | 219 Treffer | 0,601 s | 0,423 s |
  | Muster mit Umlaut | 0,684 s | 0,370 s |
  | `--case-sensitive`, 156 Treffer | 0,519 s | 0,274 s |
  | dieselben Daten in einem 22-MB-Zip | 0,649 s | 0,354 s |
  | `--regex` (kein Vortest möglich) | 0,806 s | 0,802 s |

- Der Vortest gilt auch für Archiv-Einträge. Dort wird ein Treffer-Eintrag
  zweimal entpackt; gegen das Gesamtbudget des Suchlaufs zählt er trotzdem nur
  einmal, damit ein Treffer nicht teurer ist als ein Nicht-Treffer. Die
  Einzelgrenze pro Eintrag bleibt in beiden Durchläufen aktiv.
- Entschieden: Die CRC-Prüfsumme eines ZIP-Eintrags wird nach einem frühen
  Inhaltstreffer nicht geprüft. Python prüft sie erst am Eintragsende, und
  vollständiges Durchlesen nur zur Prüfsumme würde den Abbruch beim ersten
  Treffer aufheben. Ein Treffer ist ein Fund, keine Integritätszusage.

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
