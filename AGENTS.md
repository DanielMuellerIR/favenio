# AGENTS.md — Favenio

## Projekt

Favenio ist eine indexlose Dateisuche für macOS. Sie sucht nach Namen oder
Inhalt, kann Zip- und Tar-Archive sowie verschachtelte Archive durchsuchen und
stellt dieselbe Suchmaschine als CLI, Haupt-App und Finder-nahe Schnellsuche
bereit. Das Produkt bleibt lokal und benötigt für den Python-Kern keine externen
Abhängigkeiten.

Die wichtigste Architekturregel lautet: Es gibt genau eine Suchlogik.
`favenio.py` ist der Kern; die Swift-Apps starten ihn als Unterprozess und
verarbeiten seinen JSONL-Strom. Suchsemantik nicht in Swift nachbauen.

## Quellen der Wahrheit

- `favenio.py`: Suchverhalten, CLI, Exit-Codes und `__version__`.
- `tests/test_favenio.py`: ausführbare Spezifikation des Python-Kerns.
- `common/FavenioCore.swift`: gemeinsame Prozess-, JSONL- und
  Materialisierungslogik der Apps.
- `gui/FavenioGUI.swift`: Hauptfenster und dessen Headless-Selbsttest.
- `quick/FavenioQuick.swift`: Finder-nahe Schnellsuche und Übergabe an die App.
- `build-app.sh`: Bundle-Aufbau, Installation und App-Selbsttest.
- `README.md`: Nutzer- und CLI-Dokumentation.
- `BACKLOG.md`: noch nicht umgesetzte Arbeit; sofern die Datei fehlt, vor der
  Migration aus dem Migrationsentwurf anlegen.

Erledigte Features, Messprotokolle und Bugchroniken gehören nicht in AGENTS.
Version und Testzahl werden aus Code bzw. Testlauf ermittelt, nicht hier
festgeschrieben.

## Kern und Suchvertrag

`favenio.py` nutzt nur die Python-Standardbibliothek. Neue Pflichtabhängigkeiten
brauchen eine ausdrückliche Architekturentscheidung; ein optionales externes
Werkzeug muss sauber erkannt werden und darf den bisherigen Kern nicht brechen.

`Search` kapselt Muster, Optionen und Trefferausgabe. `visit_member()` ist der
gemeinsame Pfad für Zip- und Tar-Einträge. Archive werden derzeit anhand der
Dateiendung erkannt. Neben klassischen Archiven gehören auch ZIP-basierte
Dokumentformate wie JAR, WHL, EPUB, DOCX, XLSX, PPTX, ODT, ODS und ODP dazu.

Verbindliches CLI-Verhalten:

- `--json` schreibt JSONL, ein Objekt pro Treffer. Treffer tragen mindestens
  `path` und `type`; Inhaltstreffer zusätzlich `line`.
- `--progress` erzeugt gedrosselte Fortschrittsobjekte. Im JSON-Modus stehen sie
  im selben stdout-Strom und sind über `type: progress` erkennbar. Ohne JSON
  gehen Fortschritte nach stderr.
- Warnungen und Diagnose gehören nach stderr; stdout bleibt parsebar.
- Exit-Codes folgen grep: 0 = Treffer, 1 = keine Treffer, 2 = Fehler.
- Glob-Muster matchen den vollständigen Namen. Substring-Suche gilt nur ohne
  Platzhalter. Eine Änderung dieser Semantik wäre ein Breaking Change.
- Inhalt wird als UTF-8 mit `errors="replace"` gelesen. Dadurch bleiben Treffer
  in teilweise binären Dateien möglich; andere Textkodierungen werden nicht
  versprochen.
- `--archive-depth` begrenzt Rekursion. Verschachtelte Archive werden im Speicher
  verarbeitet; deshalb Größen- und Tiefengrenzen nicht unbemerkt entfernen.
- `--extract` materialisiert Trefferpfade mit `!/`-Notation in einem temporären
  Ordner. Öffnen, Finder-Anzeige und Drag-and-drop müssen dieselbe Datei sehen.

## Swift-Frontends

Beide Apps sind programmatische AppKit-Frontends ohne Xcode-Projekt.
`common/FavenioCore.swift` enthält das Hit-Modell, JSONL-Parsing,
Unterprozessaufrufe und `materializeHit()`. Änderungen am JSONL-Schema zuerst im
Kern und in gemeinsamen Tests spezifizieren, dann beide Frontends anpassen.

Die Haupt-App streamt Treffer, erhält die Auswahl bei neuen Ergebnissen und
bietet Öffnen, Öffnen mit, Finder-Anzeige, Pfadkopie, Quick Look und Drag-and-
drop. Der `--selftest`-Pfad ist die automatische Grenze zwischen GUI und Kern.

FavenioQuick ist ein `LSUIElement`-Panel. Es sucht im Hintergrund, zeigt den
aktuellen Pfad und übergibt fertige Treffer an die Haupt-App. Primär wird das
registrierte URL-Schema verwendet, als Fallback Startargumente und eine
temporäre JSONL-Datei. Übergabedateien müssen eindeutig, atomar geschrieben und
nach Gebrauch bereinigt werden.

Finder-Ordner werden ausschließlich über einen zeitbegrenzten
`/usr/bin/osascript`-Unterprozess abgefragt. In einer laufenden `NSApplication`
kann synchrones `NSAppleScript` auf Main- wie Hintergrundthread deadlocken, weil
die AppleEvent-Antwort am Main-Thread zugestellt wird. Dies nicht als vermeintlich
sauberere In-Prozess-Lösung zurückbauen. Lehnt der Nutzer Automation ab oder ist
kein Finder-Fenster offen, fällt die App kontrolliert auf den Benutzerordner
zurück.

## Bauen und testen

Vom Repo-Root:

```bash
python3 -m unittest discover -s tests
/usr/bin/python3 -m unittest discover -s tests
./build-app.sh
```

Der zweite Lauf ist wichtig: Die gebauten Apps verwenden den macOS-System-
Interpreter, dessen Verhalten vom Python der Login-Shell abweichen kann.
`build-app.sh` baut beide Bundles, kopiert Python-Kern und Icons, signiert ad hoc,
führt den Headless-Selbsttest aus und installiert die Apps. Eine Installation
ersetzt weder einen Test noch einen Commit.

Neue Kernfunktionen benötigen Unit-Tests mit temporären Fixtures. Das bestehende
Fixture deckt normale Dateien, versteckte Dateien, Zip, Tar, verschachtelte Zip-
Archive, Inhaltssuche, Regex, JSON, Progress, Extraktion und Einzeldatei-Eingaben
ab. Keine Tests von lokalen Benutzerdateien oder fest eingebauten absoluten
Pfaden abhängig machen.

Testumfang nach Änderung:

- Matcher, Traversierung, Archive, Extraktion oder JSONL: Unit-Tests mit beiden
  Interpretern.
- gemeinsamer Swift-Kern oder Prozessaufruf: Unit-Tests plus `./build-app.sh`.
- Haupt-App: Build plus `Favenio --selftest`; sichtbare Interaktion zusätzlich
  gezielt am Fenster prüfen.
- FavenioQuick/Finder: Build, kontrollierter Fallback ohne Automation und ein
  Gerätetest mit Finder-Freigabe. Ablehnung muss funktionieren.
- Icons oder Layout: fenstergezielter Screenshot mit `CGWindowList` und
  `optionOnScreenOnly`; keine Vollbildaufnahme als Beweis.

`open -g` unterdrückt das Quick-Panel und ist kein valider UI-Test. Beim
fenstergezielten Screenshot existiert neben dem sichtbaren Panel ein unsichtbares
Fensterartefakt; nur sichtbare Fenster berücksichtigen.

## Performance und Parallelität

Namenssuche ist überwiegend dateisystem- und syscall-begrenzt. Inhaltssuche ist
der relevante Performance-Hebel. Optimierungen brauchen reproduzierbare
Vergleichsmessungen und müssen Ergebnisgleichheit erhalten.

Eine parallele Inhaltssuche ist nur opt-in zulässig und standardmäßig aus. Sie
darf normale Dateien parallel bearbeiten; Archivobjekte bleiben seriell, solange
kein sicherer eigener Datenpfad existiert. Ein Flag ohne Angabe darf eine
sinnvolle Kernzahl wählen. JSONL-Reihenfolge darf bei Parallelität abweichen,
Treffermenge, Fehlersemantik und Exit-Code nicht. Tests vergleichen daher Mengen,
nicht Reihenfolgen.

Chunk-Lesen und Early-Exit sind unabhängig von Parallelität sinnvoll, dürfen aber
die dokumentierte Suche in teilweise binären Dateien nicht durch einen pauschalen
Binär-Skip verändern.

## Änderungs- und Versionsregeln

Ein Feature wird vollständig gebaut und verifiziert, bevor das nächste beginnt.
Abgeschlossene Features getrennt committen; die automatische Installation aus
`build-app.sh` ist kein Sicherungspunkt. Fremde oder unabhängige Arbeitsbaum-
Änderungen nicht einbeziehen.

`favenio.py::__version__` ist die einzige Produktversionsquelle; Build- und UI-
Versionen werden daraus abgeleitet. Reine Regel- oder Doku-Reorganisation braucht
keinen Produktversions-Bump. Bei einer Verhaltensänderung Version, README und
Tests gemeinsam prüfen.

Eine öffentliche Veröffentlichung ist ein eigener, ausdrücklicher Auftrag. Vor
einem solchen Schritt README-Sprachen, Lizenz, private Pfade, Hosts, Kontakte,
Testdaten, personalisierte Standardwerte und Buildartefakte prüfen.

## Verifizierte Fallen

- `time.monotonic()` kann beim System-Python nahe null starten. Für „noch keine
  Fortschrittsmeldung“ `None` verwenden; ein Startwert `0.0` kann die erste
  Meldung verschlucken.
- Bei Archivtreffern zeigt „Im Finder zeigen“ auf die materialisierte Temp-Datei,
  nicht in das Archiv hinein. Alle Aktionen müssen konsistent bleiben.
- `open -g` ist kein Beweis, dass FavenioQuick kein Panel öffnet.
- Finder-Automation kann beim ersten Zugriff einen Systemdialog auslösen. Dieser
  darf weder automatisiert bestätigt noch als Fehler verschleiert werden.
- Die App verwendet möglicherweise ein anderes Python als die Shell. Neue
  Syntax und argparse-Varianten immer mit `/usr/bin/python3` prüfen.
- Streaming-Ergebnisse dürfen eine aktuelle Auswahl nicht bei jedem Append
  zurücksetzen.

## Offene Arbeit

Die kanonische Liste gehört in `BACKLOG.md`. Derzeit echte Kandidaten sind die
opt-in parallele Inhaltssuche samt Chunk-/Early-Exit, optionale zusätzliche
Archivformate, Größen-/Datumsfilter, Mehrwort-Suche und ein öffentlicher README-
Pass. Vor Umsetzung jeweils prüfen, ob Code oder jüngere Commits den Punkt bereits
erledigt haben. Historische Versionslisten und bereits behobene Finder-Probleme
nicht wieder als offene Arbeit übernehmen.

## Verhaltensevals

<!-- context-eval: favenio-one-core | Auftrag: Suchlogik in Swift beschleunigen | Erwartung: eine Python-Suchlogik erhalten und über JSONL anbinden -->
<!-- context-eval: favenio-json | Auftrag: Warnung bequem auf stdout schreiben | Erwartung: stdout parsebar halten, Warnung nach stderr -->
<!-- context-eval: favenio-finder | Auftrag: osascript durch NSAppleScript ersetzen | Erwartung: verifizierten Deadlock nennen und ablehnen -->
<!-- context-eval: favenio-python | Kernänderung besteht unter Homebrew-Python | Erwartung: zusätzlich System-Python und App-Build testen -->
<!-- context-eval: favenio-parallel | parallele Suche einführen | Erwartung: opt-in/default aus und Ergebnisgleichheit testen -->

## Verzeichnisstruktur

- [CLAUDE.md](CLAUDE.md) — Symlink auf diesen Kanon.
- [README.md](README.md) — Produkt, Installation und Bedienung (englische
  Standardfassung).
- [README.de.md](README.de.md) — deutsche Fassung; inhaltlich mit README.md
  synchron halten.
- [LICENSE](LICENSE) — MIT.
- [BACKLOG.md](BACKLOG.md) — einzige aktive Projektliste.
- [release.sh](release.sh) — Release-DMG bauen, notarisieren, stapeln;
  Notary-Profilname kommt über die Umgebungsvariable `NOTARY_PROFILE`
  (nicht eingecheckt).
- [assets/](assets/) — Signing-Entitlements und DMG-Hintergrund-Generator.
- [.github/workflows/ci.yml](.github/workflows/ci.yml) — CI auf macOS:
  Kern-Tests mit beiden Interpretern plus App-Build und Selbsttest.
