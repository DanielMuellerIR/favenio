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

Alternativ selbst bauen — drei getrennte Skripte, von denen keines die Aufgabe
der anderen übernimmt:

```bash
./build-app.sh      # beide Apps im Repository bauen und selbst testen
./release.sh        # DMG bauen, notarisieren und stapeln (installiert nicht)
./install.sh        # geprüftes DMG nach /Applications installieren
```

Quell-Builds können nur ad hoc signiert sein und werden nie automatisch
installiert. `install.sh` akzeptiert ausschließlich ein DMG mit angeheftetem
Notary-Ticket, das Gatekeeper akzeptiert, prüft beide Bundles vor und nach dem
Kopieren und endet bei jedem Fehler mit Exit-Code 2, ohne `/Applications`
anzufassen. `./install.sh --verify-only` führt nur die Prüfung aus.

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
  `{"path": "...", "type": "member", "filesystemPath": "/tmp/a.zip", "archiveMembers": ["innen.txt"], "line": 2}`.
  `path` bleibt die menschenlesbare Darstellung; Automation sollte die
  eindeutigen strukturierten Felder verwenden.
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
| `--max-archive-member-bytes BYTES` | maximal gelesene entpackte Bytes pro Archivmitglied |
| `--max-archive-total-bytes BYTES` | maximal gelesene entpackte Archivbytes pro Suchlauf |
| `--max-archive-ratio FAKTOR` | maximales ZIP-Kompressionsverhältnis |
| `--only both\|files\|dirs` | Treffer auf Dateien, Ordner oder beides (Default) begrenzen |
| `--hidden` | unsichtbare (Punkt-)Dateien und -Ordner mitdurchsuchen |
| `--json` | JSONL-Ausgabe für Skripte/Agenten (mit `size` = Bytes) |
| `--progress` | laufend melden, wo gerade gesucht wird (mit `--json` als JSONL-Objekte, sonst auf stderr) |
| `--extract TREFFER` | Treffer-Pfad (`!/`-Notation) in einen Temp-Ordner auspacken und den nutzbaren Pfad ausgeben |
| `--extract-json JSON` | einen eindeutigen strukturierten JSON-Treffer auspacken |
| `--version` | Version anzeigen |

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

- **Doppelklick**: Öffnet die Datei. Archiv-Einträge werden einmal in einen
  app-eigenen Temp-Ordner ausgepackt und für Vorschau, Öffnen, Finder und Ziehen
  wiederverwendet
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
- **Return** startet die Namenssuche (inkl. Archive) in dem Suchbereich, der
  neben dem Feld steht — voreingestellt ist der Ordner des vordersten
  Finder-Fensters
- Bei Treffern öffnet sich die große GUI mit der fertigen Liste
  (die Treffer werden übergeben, es wird nicht doppelt gesucht);
  ohne Treffer bleibt nur das kleine Feld mit einer Meldung
- **Esc** (bei leerem Feld) beendet die Schnellsuche

Der Suchbereich wird nie stillschweigend geraten. Solange der Finder befragt
wird, sagt das Menü das, und eine Suche wartet kurz, statt anderswo zu starten.
Lässt sich der Ordner nicht ermitteln — Automation verweigert, kein
Finder-Fenster offen, Finder antwortet nicht —, wird der Grund gezeigt und der
tatsächlich durchsuchte Ordner benannt.

Hinweis: Beim ersten Suchlauf über den Benutzerordner fragt macOS
unter Umständen nach Zugriff auf Schreibtisch und Dokumente (TCC).
Einmal erlauben genügt. Den Finder nach dem aktuellen Ordner zu fragen braucht
eine eigene Freigabe (Systemeinstellungen → Datenschutz & Sicherheit →
Automation).

Was die Apps erkennen, zeigt ohne jedes Fenster:

```bash
FavenioQuick.app/Contents/MacOS/FavenioQuick --finder-scope
```

Eine JSON-Zeile mit den erkannten Ordnern (vorderstes Fenster zuerst).
Exit-Code 0 = Ordner ermittelt, 1 = kein Finder-Fenster, 2 = Fehler
(auch verweigerter Zugriff).

## Tests

```bash
python3 -m unittest discover -s tests            # Unit-Tests (Kern)
/usr/bin/python3 -m unittest discover -s tests   # Interpreter der Apps
Favenio.app/Contents/MacOS/Favenio --selftest    # Headless-GUI-Anbindung
```

`build-app.sh` führt nach jedem Build beide App-Selbsttests aus und lässt die
Bundles im Repository. Release-Änderungen stehen in [CHANGELOG.md](CHANGELOG.md).

## Lizenz

[MIT](LICENSE). Die macOS-Apps enthalten Sparkle unter dessen kompatibler
Lizenz; siehe [Drittanbieter-Software](THIRD-PARTY.md).
