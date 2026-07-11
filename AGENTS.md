# AGENTS.md — Favenio

Stand: 2026-07-11

## Was ist das?

Favenio („facile invenio" — ich finde mit Leichtigkeit) ist ein
EasyFind-Nachbau: indexlose Dateisuche nach Namen oder Inhalt, mit der
Zusatzfähigkeit, **in Archive hineinzusuchen** (Zip- und Tar-Familie,
verschachtelt via `--archive-depth`). Drei Teile: CLI (`favenio.py`),
GUI (`Favenio.app`) und Finder-Toolbar-Schnellsuche (`FavenioQuick.app`).

## Tech-Stack / Architektur

- **Kern = `favenio.py`**: Python 3, **nur Standardbibliothek** (argparse,
  fnmatch, zipfile, tarfile, io, json, re, os, tempfile) — keine
  Dependencies. Version als `__version__`-Konstante dort (einzige Quelle,
  Build-Skript liest sie aus).
- Kernklasse `Search` kapselt Muster + Optionen + Trefferausgabe;
  `visit_member()` ist die gemeinsame Logik für Zip- und Tar-Einträge.
- Archiv-Erkennung rein über Dateiendung (schnell, kein Öffnen nötig);
  Zip-in-Verkleidung-Formate (jar, whl, epub, docx, xlsx, pptx, odt,
  ods, odp) werden mitbehandelt.
- Verschachtelte Archive werden in den Speicher (`io.BytesIO`) geladen
  und rekursiv durchsucht; `--archive-depth` begrenzt die Tiefe
  (Default 1 = in Archive schauen, aber nicht in Archive in Archiven).
- `--extract TREFFER` packt einen Treffer-Pfad (`!/`-Notation, auch
  verschachtelt) in einen Temp-Ordner aus — Unterbau für Öffnen/Drag&Drop
  der GUI.

### Swift-Frontends (AppKit, programmatisch, kein Xcode-Projekt)

- **Design-Entscheidung: genau EINE Suchlogik.** Die Apps starten
  `favenio.py --json` als Unterprozess (Streaming über Pipe) statt die
  Suche in Swift zu duplizieren.
- `common/FavenioCore.swift` — geteilt: Hit-Modell, JSONL-Parsing,
  Prozess-Aufrufe, `materializeHit()` (= `--extract`-Wrapper).
- `gui/FavenioGUI.swift` — Hauptfenster mit Trefferliste: Doppelklick
  öffnet, Rechtsklick (Öffnen / Öffnen mit… / Im Finder zeigen / Pfad
  kopieren), Drag&Drop nach draußen. `--selftest` = Headless-Test.
- `quick/FavenioQuick.swift` — LSUIElement-Panel (schwebendes Suchfeld);
  sucht selbst (blockierend im Hintergrund-Thread) und übergibt die
  fertigen Treffer als JSONL-Temp-Datei an die GUI.
- **Übergabe Schnellsuche → GUI:** primär URL-Schema
  `favenio://results?q=…&root=…&file=…` (in Info.plist registriert,
  `lsregister -f` im Build-Skript); Fallback Startargumente
  `--query`/`--results-file` via `NSWorkspace.openApplication`.
- `build-app.sh` baut beide Bundles (swiftc, ad-hoc-signiert), kopiert
  `favenio.py` in die Resources und lässt den Selbsttest laufen.

## Headless-/Agent-Schnittstelle (Design-Entscheidung)

- `--json` → JSONL, ein Objekt pro Treffer: `path`, `type`
  (`file`/`dir`/`member`), bei Inhaltssuche `line`.
- Exit-Codes wie grep: 0 Treffer / 1 keine / 2 Fehler.
- Warnungen nach stderr, stdout bleibt parsebar.

## Tests / Verifikation

```bash
python3 -m unittest discover -s tests            # 21 Unit-Tests (Kern)
./build-app.sh                                   # Build + Headless-Selbsttest
```

Die Unit-Tests bauen sich ihre Fixtures (Dateien, zip, tar.gz,
Zip-im-Zip) selbst in einem Temp-Ordner. Der App-Selbsttest
(`Favenio --selftest`) prüft Suche + Extraktion über die echte
GUI-Anbindung, ohne Fenster. GUI-Optik: fenstergezielte Screenshots
(CGWindowList → `screencapture -l <WID>`), siehe Fallen unten.

## Status / offene Ideen

- v0.1.0: CLI — Namens-/Inhaltssuche, Zip+Tar, Verschachtelung, JSONL.
- v0.2.0: `--extract`, Favenio.app (Trefferliste mit Doppelklick/
  Kontextmenü/Öffnen mit/Drag&Drop), FavenioQuick.app (Toolbar-
  Schnellsuche mit Übergabe an die GUI). Alles verifiziert bis auf
  echtes Tippen/Maus-Drag (Handtest).
- Ideen (nicht begonnen): 7z/rar via externe Tools, Größen-/Datums-
  filter, Mehrwort-Suche („alle Wörter" wie EasyFind), App-Icon,
  Suchabbruch-Button in der GUI, Optionen im Schnellsuche-Panel.
- Idee (2026-07-11): README-H1 mit Einordnung versehen („Favenio:
  Dateisuche für macOS ohne Index, mit Blick in Archive", analog
  Fastra); bei einem späteren GitHub-Gang englische `README.md` +
  deutsche `README.de.md` anlegen.

## Fallen / Agent-Hinweise

- Inhaltssuche dekodiert als UTF-8 mit `errors="replace"` — findet
  Text auch in „halb-binären" Dateien, aber keine anderen Encodings
  (Latin-1-Umlaute matchen nicht).
- Glob-Muster matchen den GANZEN Namen (fnmatch), Substring-Suche nur
  ohne Platzhalter — Verhalten ist in `build_matcher()` dokumentiert.
- **`open -g` unterdrückt das Panel** von FavenioQuick (Hintergrund-
  Launch ⇒ macOS lässt das Fenster nicht nach vorn) — beim normalen
  Klick-Start (Finder-Toolbar, Doppelklick) erscheint es. Für
  Screenshots das Bundle-Binary direkt starten.
- FavenioQuick hat neben dem Panel (500×92, onscreen) ein unsichtbares
  500×500-Fenster-Artefakt im CGWindowList — beim fenstergezielten
  Screenshot `optionOnScreenOnly` verwenden, sonst erwischt man das
  falsche (weiße) Fenster.
- „Im Finder zeigen" zeigt bei Archiv-Einträgen die ausgepackte
  Temp-Kopie (genau die Datei, die Öffnen/Drag liefert), nicht das
  Archiv.
