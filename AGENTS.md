# AGENTS.md — Favenio

Stand: 2026-07-11

## Typ & Zweck
- **Typ:** GUI-App (+ CLI)
- **Zweck:** Durchsucht Dateien und Archive indexlos nach Namen oder Inhalt; die macOS-Apps machen dieselbe Python-Suchmaschine als Finder-nahe Oberfläche nutzbar.
- **Plattform:** macOS-GUI, CLI

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
  sucht selbst (streamend im Hintergrund-Thread, `runSearchStreaming`)
  und übergibt die fertigen Treffer als JSONL-Temp-Datei an die GUI.
  Während der Suche zeigt die Info-Zeile dezent (tertiäre Textfarbe,
  Mitten-Kürzung) den gerade durchsuchten Ordner/das Archiv (`--progress`).
- **Übergabe Schnellsuche → GUI:** primär URL-Schema
  `favenio://results?q=…&root=…&file=…` (in Info.plist registriert,
  `lsregister -f` im Build-Skript); Fallback Startargumente
  `--query`/`--results-file` via `NSWorkspace.openApplication`.
- `build-app.sh` baut beide Bundles (swiftc, ad-hoc-signiert), kopiert
  `favenio.py` + App-Icon in die Resources, lässt den Selbsttest laufen und
  installiert beide fertigen Apps nach `/Applications`.
- **App-Icons** (`icons/`): programmatisch gezeichnet („F-Monogramm mit
  Lupe"; Quick-Variante invertiert + Blitz in der Linse). Quelle ist
  `icons/make-icons.swift` (CoreGraphics, kein SVG-Rasterizer nötig);
  die fertigen `.icns` sind eingecheckt, die `.iconset`-Zwischenordner
  nicht. Neu erzeugen: `swift icons/make-icons.swift` + `iconutil -c
  icns icons/<Name>.iconset -o icons/<Name>.icns`.

## Headless-/Agent-Schnittstelle (Design-Entscheidung)

- `--json` → JSONL, ein Objekt pro Treffer: `path`, `type`
  (`file`/`dir`/`member`), bei Inhaltssuche `line`.
- `--progress` → laufende Meldung, wo gerade gesucht wird (gedrosselt
  auf ~10/s, erste Meldung immer). Mit `--json` als eigene JSONL-Objekte
  `{"type": "progress", "path": …}` im stdout-Strom (Konsumenten
  unterscheiden am `type`-Feld); ohne `--json` auf stderr.
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

## Performance-Einordnung (Messung 2026-07-11, M5, warmer FS-Cache)

- **Namenssuche: praktisch am Single-Thread-Maximum.** ~527.000 Einträge
  (`~/git`): Favenio 1,39 s vs. `find` 1,41 s, identische Trefferzahl.
  Syscall-gebunden; `os.walk` nutzt intern C-`scandir`. Absolutes Maximum
  wäre parallele Traversierung à la `fd` (~3–6× bei warmem Cache); bei
  kaltem Cache (typischer Erstlauf ohne Index) ist die Platte der
  Flaschenhals und der Vorsprung schrumpft deutlich.
- **Inhaltssuche: ~14× langsamer als ripgrep** (~10.700 Dateien: 1,22 s
  vs. 0,09 s). Drei Gründe: Single-Thread (rg nutzte ~11 Kerne),
  Python-Zeilenschleife mit Komplett-UTF-8-Dekodierung statt
  SIMD-Bytesuche, kein Early-Exit — jede Datei wird komplett in den RAM
  gelesen (`visit_file()`), auch große Binärdateien. Der Faktor wächst
  auf großen Bäumen eher noch.
- **Archiv-Suche: konzeptbedingt nahe am Maximum.** Zip-Namenssuche liest
  nur das zentrale Verzeichnis, Dekompression läuft in C (zlib).
  Inhärente Kosten: tar.gz muss zum Auflisten komplett dekomprimiert
  werden (Formateigenschaft); verschachtelte Archive landen ganz im RAM
  (Design-Entscheidung).

Größter Hebel ist die Inhaltssuche → geplantes Feature unten.

## Geplant: parallele Inhaltssuche (opt-in, Default AUS)

Entscheidung Daniel 2026-07-11: Beschleunigung über mehrere Kerne kann
nerven (Rechner sofort voll ausgelastet, Lüfter) — deshalb bewusst
abschaltbar und **standardmäßig aus**; meist braucht man sie nicht.

Plan (nur geplant, nicht begonnen):

1. **Kern (`favenio.py`):** Worker-Pool (stdlib, z. B.
   `concurrent.futures.ProcessPoolExecutor`) NUR für die Inhaltssuche
   in normalen Dateisystem-Dateien. Traversierung bleibt Single-Thread
   und verteilt Datei-Pfade als Jobs; Archive bleiben seriell
   (Archiv-Objekte sind nicht prozess-übergreifend teilbar).
2. **Lese-Verbesserung unabhängig davon:** Chunk-Lesen mit Early-Exit
   beim ersten Treffer statt Komplett-Read — hilft auch seriell.
   Verhalten beibehalten: kein Binär-Skip (dokumentierte Eigenschaft,
   Treffer in „halb-binären" Dateien).
3. **CLI:** Flag `--parallel [N]` (ohne N = Kernzahl); ohne Flag exakt
   bisheriges Verhalten.
4. **GUI (`Favenio.app`):** Ankreuzfeld (z. B. „Alle Prozessorkerne
   nutzen"), Default aus, reicht nur das Flag an den Unterprozess durch.
5. **Tests:** Ergebnisgleichheit seriell vs. parallel auf den
   bestehenden Fixtures; JSONL-Reihenfolge darf abweichen.

## Arbeitsweise (Commit-Disziplin)

**Nach jedem abgeschlossenen Feature committen — vor dem nächsten.** Lektion aus
v0.8→v0.13: mehrere Features wurden über Sessions hinweg gebaut *und* nach
`/Applications` installiert, ohne dazwischen zu committen. Ergebnis: ~720
uncommittete, dateiübergreifend verzahnte Zeilen, die sich nur noch thematisch
(nicht feature-atomar) trennen ließen — kein Zwischen-Commit compilierte für
sich. `build-app.sh` installiert die Bundles am Ende automatisch; das ersetzt
KEINEN Commit. Regel: Feature fertig + verifiziert → committen, dann erst das
nächste. So bleiben Commits atomar und rückrollbar.

## Status / offene Ideen

### Stand (2026-07-14, v0.13.1 committet + gebaut + installiert)

Seit v0.8.0 gebaut, in v0.13.1 committet (4 thematische Commits: Kern/Finder-Fix,
Haupt-App-Features, Schnellsuche-Umbau, Doku):

- Regex-Vorlagen + Syntaxfärbung (Haupt-App, Farbschema/Vorlagen aus Fastra;
  eigener leichter Tokenizer statt tree-sitter). Färbung braucht
  `searchField.allowsEditingTextAttributes = true`.
- QuickLook (Leertaste/Rechtsklick) in beiden Apps; folgt der Auswahl.
- Haupt-App: „Über Favenio"-Dialog (lat. Spruch nur dort + Version/Datum),
  Stopp-Button links vom Feld, Auswahl bleibt beim Streamen erhalten,
  Fortschritt (durchsuchter Ordner) in der Statuszeile.
- Quick: resizable + feste Default-Größe; **kein Auto-Sprung** mehr in die
  Haupt-App (Button „Alle in Favenio ↗" / Cmd+Return); Optik.
- Fenster-Breiten-Fix Haupt-App (Statuszeile war unbegrenzt breit). ✅ bestätigt.

**BUG „Quick zeigt Benutzerordner" — GEFIXT (2026-07-13, v0.13.1).**
Ursache war NICHT Accessory/Thread/Signatur/TCC (alles empirisch ausgeschlossen:
`local.favenio.quick → com.apple.finder = 2`, kein Hardened Runtime). Der echte
Fehler: **In-Prozess-`NSAppleScript` hängt in einer laufenden `NSApplication`.**
Der Apple-Event-Manager stellt die Antwort dem MAIN-Thread zu — auf einem
Hintergrund-Thread kommt sie nie an, auf dem Main-Thread wartet er auf eine
Antwort, die nur er selbst zustellen könnte (Deadlock). Beide In-Prozess-Wege im
echten App-Kontext als Hänger verifiziert (per Logfile, `completion` feuerte nie).
**Beide Handoff-Verdächtigungen waren falsch:** „Hintergrund-Thread funktioniert"
(hängt) und „osascript-Unterprozess scheidet aus wegen TCC" (funktioniert
tadellos). **Fix:** `finderWindowFoldersAsync` in `common/FavenioCore.swift` ruft
jetzt `/usr/bin/osascript` als Unterprozess (eigener Event-Loop, kehrt sauber
zurück — genau wie das nc_pin-AppleScript-Applet), timeboxed. End-to-end
verifiziert: Popup wählt jetzt den vordersten Finder-Ordner statt `~`.

### Versionshistorie (committet)

- v0.1.0: CLI — Namens-/Inhaltssuche, Zip+Tar, Verschachtelung, JSONL.
- v0.2.0: `--extract`, Favenio.app (Trefferliste mit Doppelklick/
  Kontextmenü/Öffnen mit/Drag&Drop), FavenioQuick.app (Toolbar-
  Schnellsuche mit Übergabe an die GUI). Alles verifiziert bis auf
  echtes Tippen/Maus-Drag (Handtest).
- v0.2.1: App-Icons (F-Monogramm mit Lupe; Quick invertiert + Blitz).
- v0.3.0: `--progress` + Live-Anzeige des durchsuchten Ordners/Archivs
  im Schnellsuche-Panel (`runSearchStreaming` in FavenioCore).
- v0.4.0: Suchbereich der Schnellsuche wählbar — vorderster
  Finder-Ordner (Vorauswahl) oder Benutzerordner. Handtest des
  Finder-Zugriffs (Automation-Dialog) steht noch aus.
- v0.4.1: Quick-Layout stabilisiert, Suchprozessfehler sichtbar gemacht und
  beide Apps als fester Build-Abschluss nach `/Applications` installiert.
- Ideen (nicht begonnen): 7z/rar via externe Tools, Größen-/Datums-
  filter, Mehrwort-Suche („alle Wörter" wie EasyFind),
  Suchabbruch-Button in der GUI, Optionen im Schnellsuche-Panel,
  Fortschrittsanzeige auch in der großen GUI-Statuszeile.
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
- **`time.monotonic()` startet beim System-Python (3.9, das die Apps
  nutzen) nahe 0 beim Prozessstart** — ein Drossel-Startwert von `0.0`
  verschluckt dann die erste Meldung. Deshalb `None` als „noch nie"-
  Marker (gefunden 2026-07-11 bei `--progress`; Homebrew-Python 3.14
  zählt boot-relativ und verdeckte den Fehler in den Tests → Tests im
  Zweifel auch mit `/usr/bin/python3 -m unittest discover -s tests`).
- **Finder-Ordner NUR per `osascript`-Unterprozess abfragen, NIE
  In-Prozess-`NSAppleScript`.** In einer laufenden `NSApplication` stellt der
  Apple-Event-Manager die Antwort dem Main-Thread zu → ein synchroner
  `executeAndReturnError` hängt ewig (Hintergrund-Thread: Antwort kommt nie an;
  Main-Thread: Deadlock). Verifiziert 2026-07-13. `finderWindowFoldersAsync`
  nutzt deshalb `/usr/bin/osascript` (eigener Event-Loop). TCC ordnet den Event
  korrekt der App zu — nicht auf In-Prozess „optimieren".
- Suchbereich der Schnellsuche: vorderster Finder-Ordner (per
  AppleScript erfragt) oder Benutzerordner, wählbar im Panel-Menü.
  Der ERSTE Finder-Zugriff löst den macOS-Automation-Dialog aus
  („… möchte Finder steuern"); wird er verweigert oder ist kein
  Finder-Fenster offen, fällt die App still auf `~` zurück. Die
  Erlaubnis steht unter Systemeinstellungen → Datenschutz →
  Automation.

## Verzeichnisstruktur

<!-- directory-structure: generated -->
- [AGENTS.md](AGENTS.md) — Projektprofil, Arbeitsregeln und dieses Datei-Verzeichnis.
- [README.md](README.md) — Projekt-Einstieg und Nutzerdokumentation.
- `Favenio.app/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `FavenioQuick.app/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `common/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `gui/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `icons/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `quick/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
- `tests/` — Projektbestandteil; Details stehen im Code bzw. in der verlinkten Dokumentation.
<!-- /directory-structure -->
