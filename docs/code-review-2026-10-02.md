# Code-Review vom 2026-10-02

Ausgangsstand: `e42c95e`, Version 0.35.0. Die acht unten beschriebenen
Produkt- und Skriptfehler sind in 0.35.1 korrigiert.

## Abdeckung

| Bereich | Prüfumfang |
| --- | --- |
| `favenio.py` | Matcher, Zeilenleser, Filter, Archivabstieg, Budgets, Extraktion, JSONL, Diagnose und CLI-Vertrag |
| `common/FavenioCore.swift` | Prozesslebenszyklus, Parsing, Abbruch, Materialisierung, Trefferidentität, Export, Dateiaktionen, Filter und Übergabe |
| `gui/FavenioGUI.swift` | Suchsteuerung, Vorlagen, URL-Eingang, Auswahl, Sortierung, Export und Papierkorb |
| `quick/FavenioQuick.swift` | Debounce, Treffergrenze, Finder-Bereich, verspätete Antworten, Übergabe und Statusanzeige |
| Build und Auslieferung | `build.sh`, `build-app.sh`, `install.sh`, `notarize-lib.sh`, `release.sh`, Paketkonfiguration und GitHub-Workflows |
| Tests und Dokumentation | Betroffene Regressionstests, Swift-Proben, Selbsttests und dokumentierte Verträge |

Das Schichtenmodell bleibt tragfähig: Python besitzt die Suchsemantik;
beide AppKit-Controller verwenden den gemeinsamen Prozess- und Trefferkern.
Die großen Controller verbinden weiterhin Darstellung und Ablaufsteuerung.
Für die gefundenen Fehler war kein Architekturwechsel erforderlich.

## Behobene Befunde

| Priorität | Stelle | Auslöser und vorherige Folge | Korrektur und Beleg |
| --- | --- | --- | --- |
| P2 | `Search.walk_zip`, `Search.walk_tar` | Zwei gleichnamige Einträge mit verschiedenen Inhalten: Die Suche fand die erste Variante, die Extraktion lieferte die letzte. | Suche verwendet ebenfalls den letzten Eintrag. Tests prüfen Inhalt, Größe, Einzelmeldung und Extraktion sowie doppelte innere Archive für ZIP und TAR. Der vollständige TAR-Katalog bleibt für Hardlinks erhalten. |
| P2 | `QuickController.flushPending`, Abschlusscallback | Nach 20 Treffern wurde die Laufidentität entwertet; bereits gelesene Warnungen erreichten die Oberfläche nicht. | Gezielter Stopp erhält den Abschlusscallback. Regulärer Exit 143 des SIGTERM-Handlers gilt dabei als erwarteter Abbruch. Der echte Controller-Selbsttest erzeugt eine FIFO-Warnung vor den Treffern und hält den Kern anschließend mit einer Sparse-Datei beschäftigt. |
| P2 | `QuickController.applyScopeOutcome` | Der Finder antwortete nach Ende einer Suche im Ersatzordner. Das Menü zeigte einen anderen Ordner als die Herkunft der Treffer, ohne Hinweis. | Ein eigener Zustand erhält den Bereich auch nach Nulltrefferläufen. Späte Antworten ergänzen den letzten Ergebnis- oder Fehlertext. Die Swift-Probe prüft Bereich, Warnungen und Fehler nach Suchende. |
| P2 | `commonApplicationsFor` | Ein Ordner `folder.txt` und eine Datei `file.txt` teilten den Endungsschlüssel. Dadurch wurden ungeeignete Apps angeboten. | Ordner werden einzeln abgefragt. Die Probe vergleicht beide Auswahlreihenfolgen gegen die direkte Schnittmenge der tatsächlich zuständigen Apps. |
| P3 | `HitListController.previewPanel` | Quick Look konsumierte auch Escape mit Shift, Option oder Command; die App-Fenster verarbeiteten nur Escape ohne Zusatztaste. | Einheitliche Modifier-Prüfung, im Selbsttest mit echten `NSEvent`-Objekten geprüft. |
| P3 | Quick→Haupt-App-Übergabe | Suchtexte über 4096 UTF-8-Bytes wurden vom Empfänger still verworfen, während Quick sich bereits beendete. | Gemeinsame Eingabeprüfung vor dem Schreiben und Öffnen der Übergabe; Quick zeigt den Grund und bleibt geöffnet. Selbsttest prüft Mehrbytezeichen an beiden Seiten der Grenze. |
| P2 | `notarize_apps` | Der lokale Signalhandler räumte auf, ließ danach aber Installation oder Release weiterlaufen. | Signale beenden den Ablauf mit Fehlerstatus; der EXIT-Handler räumt auf. Attrappen schicken HUP, INT und TERM während des Uploadschritts und prüfen, dass kein Stapeln mehr folgt. |
| P2 | Prüf-Mount in `release.sh` | Ein Signal nach erfolgreichem Attach, aber vor dem Setzen des Besitzmerkers, übersprang das Aushängen. | Merker vor Attach setzen. Ein deterministischer Signaltest des echten Skriptabschnitts prüft den Detach-Aufruf. |

Die Duplikat-, Menü-, Top-20- und Shell-Regressionen wurden vor der
jeweiligen Korrektur nachgewiesen. Eine zusätzliche Gegenprobe mit der alten
Abbruchbedingung lässt den erweiterten Top-20-Selbsttest weiterhin scheitern.
Die fertigen Diffs wurden erneut unabhängig geprüft.

Zusätzlich wurde ein Testfehler behoben: Die Materialisierungsprobe wartete
nur auf die Existenz einer PID-Datei. Traf der Abbruch das Kind vor dem
Schreiben der PID, verwendete die Probe anschließend `kill(-1, 0)` und
meldete trotz erfolgreichem Abbruch einen verbliebenen Prozess. Der Fehler
wurde durch eine kontrolliert verzögerte PID-Ausgabe reproduziert. Die Probe
wartet jetzt auf eine positive gelesene PID; der bestehende Test erzwingt
dieses Zeitfenster.

## Prüfung und Grenzen

Die Ausgangssuite bestand mit 546 Tests. Der Endstand hat 553 Tests;
zusätzlich prüfen beide gebauten Apps ihre Abläufe mit `--selftest`.
Die ausgeführten Befehle und Ergebnisse stehen im ergänzenden Eintrag
`timeboxed_reviews` in [coverage.json](../.codeqa/coverage.json).

Die Tests liefen ohne Übernahme des Fensterfokus. Die geänderten
Controllerzustände, Statusmeldungen und Tastaturereignisse wurden headless
am AppKit-Code geprüft. Es gab keinen neuen sichtbaren Finder-/Quick-Look-
Interaktionstest, keine Installation, Notarisierung oder Veröffentlichung.
Signale und Mount-Abbruch wurden mit isolierten Werkzeugattrappen geprüft.
Grafikgeneratoren und Benchmarkwerkzeuge wurden inventarisiert, aber nicht
vollständig ausgeführt; Fremdcode und generierte Artefakte wurden nicht
neu geprüft. Der Review ist keine Zusage der Fehlerfreiheit.

`FAVENIO_DEFER_SELFTEST=1` bleibt als ausdrücklich dokumentierte Option
für eine nachgelagerte Abnahme erhalten. Der schon bekannte sporadische
Installationstestfehler in [BACKLOG.md](../BACKLOG.md) ist durch grüne
Läufe weder erklärt noch als behoben markiert.
