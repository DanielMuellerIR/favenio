**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Favenio

**„facile invenio", Latein für „ich finde mit Leichtigkeit".**

Favenio ist eine indexlose Dateisuche für macOS im Stil von EasyFind: Sie
durchsucht das Dateisystem direkt (ohne Index, ohne Spotlight) nach Dateinamen
oder Dateiinhalten. Die Besonderheit: **Favenio schaut auch in Archive
hinein.** Unterstützt werden die Zip-Familie (zip, jar, whl, epub, docx, xlsx,
pptx, odt, ods, odp) und die Tar-Familie (tar, tar.gz/tgz, tar.bz2/tbz2,
tar.xz/txz), auf Wunsch auch Archive in Archiven.

Der Suchkern ist pures Python 3 (nur Standardbibliothek), eine Datei, keine
Installation. Darauf aufbauend gibt es zwei native macOS-Apps: ein großes
Suchfenster und ein kleines Schnellsuche-Panel für die Finder-Toolbar.

## Voraussetzungen

- **CLI (`favenio.py`)**: Python 3.9 oder neuer, keine Zusatzpakete.
- **Apps (`Favenio.app`, `FavenioQuick.app`)**: macOS 12 (Monterey) oder
  neuer, Apple Silicon. Die Apps starten den Suchkern mit dem System-Python
  `/usr/bin/python3` aus Apples Command Line Tools; fehlen diese, bietet
  macOS die Installation automatisch an.

## Installation

`Favenio-<version>.dmg` von der
[Releases-Seite](../../releases/latest) laden, öffnen und beide Apps nach
`Programme` ziehen.

Das DMG ist mit einer Developer-ID signiert und von Apple notarisiert;
Gatekeeper öffnet die Apps ohne zusätzliche Schritte.

Ab Version 0.14.0 suchen beide Apps automatisch nach signierten Updates und
installieren sie nur nach Bestätigung. In der Haupt-App gibt es zusätzlich
**Favenio → Nach Updates suchen …**. Bei der Update-Prüfung werden keine
Hardware- oder Systemprofildaten übertragen. Ältere Versionen enthalten noch
keinen Updater; 0.14.0 muss deshalb einmalig über das DMG installiert werden.

Alternativ selbst bauen:

```bash
./build-app.sh    # baut, testet und installiert beide Apps nach /Applications
```

## Schnellstart (CLI)

```bash
# Dateinamen suchen („enthält“, Groß-/Kleinschreibung egal)
./favenio.py rechnung ~/Documents

# Glob-Muster (matcht den ganzen Namen)
./favenio.py "*.sketch" ~/Projekte

# Im Dateiinhalt suchen, auch innerhalb von Archiven
./favenio.py -c "Kündigungsfrist" ~/Documents

# Regulärer Ausdruck, Groß-/Kleinschreibung beachten
./favenio.py -r -s "rechnung-\d{4}" .

# Archive in Archiven durchsuchen (Tiefe 2)
./favenio.py -c geheim ~/Backups --archive-depth 2

# Archive ignorieren
./favenio.py notiz . --no-archives
```

Treffer in Archiven werden mit `!/` markiert:

```
backup.tar.gz!/sicherung/alt.txt:1
aussen.zip!/innen.zip!/tief/verstecktes.txt
```

Bei Inhaltssuche hängt `:N` die Zeilennummer des ersten Treffers an.

## Nutzung durch Skripte und AI-Agenten (headless)

Favenio ist bewusst maschinenfreundlich gebaut:

- **`--json`**: Ein Treffer pro Zeile als JSON-Objekt (JSONL), etwa
  `{"path": "...", "type": "file|dir|member", "line": 2}`
- **Exit-Codes** wie bei grep: `0` = Treffer, `1` = keine Treffer,
  `2` = Fehler (ungültiger Regex, Pfad fehlt)
- **Warnungen** (unlesbare Dateien, kaputte Archive) gehen nach stderr;
  die Suche läuft weiter, und stdout bleibt sauber parsebar.

```bash
./favenio.py --json -c "TODO" src/ | jq -r .path | sort -u
```

## Optionen

| Option | Wirkung |
|---|---|
| `-c`, `--content` | im Dateiinhalt suchen statt in Namen |
| `-r`, `--regex` | Muster als regulären Ausdruck interpretieren |
| `-s`, `--case-sensitive` | Groß-/Kleinschreibung beachten |
| `--no-archives` | nicht in Archive hineinschauen |
| `--archive-depth N` | Verschachtelungstiefe (Default 1) |
| `--only both\|files\|dirs` | Treffer auf Dateien, Ordner oder beides (Default) begrenzen |
| `--hidden` | unsichtbare (Punkt-)Dateien und -Ordner mitdurchsuchen |
| `-j`, `--jobs [N]` | Inhaltssuche in N Threads (Default 1 = seriell; `--jobs` ohne Zahl oder `--jobs 0` nimmt die Zahl der CPU-Kerne) |
| `--json` | JSONL-Ausgabe für Skripte/Agenten (mit `size` = Bytes) |
| `--progress` | laufend melden, wo gerade gesucht wird (mit `--json` als JSONL-Objekte, sonst auf stderr) |
| `--extract TREFFER` | Treffer-Pfad (`!/`-Notation) in einen Temp-Ordner auspacken und den nutzbaren Pfad ausgeben |
| `--version` | Version anzeigen |

### Wann `--jobs` etwas bringt

Die parallele Inhaltssuche ist standardmäßig aus, und das ist Absicht. Die
Threads lohnen sich nur, wenn das Lesen wirklich warten muss — kalter Cache,
externe oder Netzlaufwerke, drehende Platten. Dann überlappen sich mehrere
Lesevorgänge und die Suche wird deutlich schneller.

Liegen die Dateien schon im Cache, ist die Arbeit reine Rechenzeit im
Python-Interpreter, der immer nur einen Thread gleichzeitig rechnen lässt.
`--jobs` ist dann ein Verlustgeschäft, und je mehr kleine Dateien im Spiel
sind, desto größer wird der Verlust. Also: ein Schalter für langsamen
Speicher — vor dem dauerhaften Einschalten im eigenen Fall nachmessen.

Archive bleiben in jedem Fall seriell: ihre Einträge hängen an einem
gemeinsamen offenen Archiv-Objekt. Mit `--jobs` bleiben Treffermenge und
Exit-Code gleich — nur ihre **Reihenfolge** kann abweichen; wer eine stabile
Folge braucht, sortiert nach.

## Suchmodi — und wie man z. B. nur `.md`-Dateien findet

Favenio erkennt den Suchmodus **automatisch am Muster** — es gibt keinen
Umschalter:

| Eingabe | Modus | Findet |
|---|---|---|
| `notiz` | „enthält" (Default) | alles, was den Text **irgendwo** im Namen hat |
| `*.md` | Glob/Wildcards (`* ? [`) | **nur** Namen, die genau auf `.md` enden |
| `rechnung-\d{4}` mit `-r` | Regex | frei definierbares Muster (`re.search`) |

Deshalb findet die Eingabe `.md` auch `.mdi`, `.mdx` oder `readme.md` —
`.md` kommt dort ja *irgendwo* vor. **Für nur echte `.md`-Dateien: `*.md`
suchen.** Das `*` schaltet auf Glob-Matching um, das den **ganzen** Namen
prüft. (Endet ein *Ordner* auf `.md`, zusätzlich `--only files` bzw. in der
GUI „Nur Dateien" wählen.) Exakt gleichwertig wäre der Regex `\.md$`.

Bei der Namenssuche zählen auch Ordnernamen als Treffer.

## GUI (Favenio.app)

EasyFind-artige Oberfläche: Suchfeld, Ordnerwahl, Optionen, Trefferliste.

Aus der Trefferliste heraus:

- **Doppelklick**: Öffnet die Datei. Archiv-Einträge werden vorher
  automatisch in einen Temp-Ordner ausgepackt (`--extract`)
- **Rechtsklick**: Öffnen / **Öffnen mit…** (alle passenden Apps) /
  Im Finder zeigen / Pfad kopieren
- **Drag & Drop**: Treffer in den Finder oder andere Apps ziehen.
  Das geht auch mit Dateien aus Archiven; gezogen wird dann die
  ausgepackte Kopie

Die GUI ist nur ein Frontend: Gesucht wird immer über `favenio.py`.

## Schnellsuche (FavenioQuick.app)

Spotlight-Ersatz für die Finder-Toolbar: `FavenioQuick.app` bei
gedrückter **Cmd-Taste** in die Kopfleiste eines Finder-Fensters ziehen.

- Ein Klick aufs Icon öffnet ein kleines schwebendes Suchfeld
  (kein Dock-Icon)
- **Return** startet die Namenssuche im Benutzerordner (inkl. Archive)
- Bei Treffern öffnet sich die große GUI mit der fertigen Liste
  (die Treffer werden übergeben, es wird nicht doppelt gesucht);
  ohne Treffer bleibt nur das kleine Feld mit einer Meldung
- **Esc** (bei leerem Feld) beendet die Schnellsuche

Hinweis: Beim ersten Suchlauf über den Benutzerordner fragt macOS
unter Umständen nach Zugriff auf Schreibtisch und Dokumente (TCC).
Einmal erlauben genügt.

## Tests

```bash
python3 -m unittest discover -s tests            # Unit-Tests (Kern)
Favenio.app/Contents/MacOS/Favenio --selftest    # Headless-GUI-Anbindung
```

`build-app.sh` führt den Selbsttest nach jedem Build automatisch aus.

## Lizenz

[MIT](LICENSE). Die macOS-Apps enthalten Sparkle unter dessen kompatibler
Lizenz; siehe [Drittanbieter-Software](THIRD-PARTY.md).
