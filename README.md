# Favenio

**„facile invenio" — ich finde mit Leichtigkeit.**

Favenio ist eine Dateisuche im Stil von EasyFind: Sie durchsucht das
Dateisystem direkt (ohne Index, ohne Spotlight) nach Dateinamen oder
Dateiinhalten. Die Besonderheit gegenüber EasyFind: **Favenio schaut
auch in Archive hinein** — Zip-Familie (zip, jar, whl, epub, docx,
xlsx, pptx, odt, ods, odp) und Tar-Familie (tar, tar.gz/tgz,
tar.bz2/tbz2, tar.xz/txz), auf Wunsch auch Archive in Archiven.

Pures Python 3 (nur Standardbibliothek), eine Datei, keine Installation.

## Schnellstart

```bash
# Dateinamen suchen („enthält“, Groß-/Kleinschreibung egal)
./favenio.py rechnung ~/Documents

# Glob-Muster (matcht den ganzen Namen)
./favenio.py "*.sketch" ~/Projekte

# Im Dateiinhalt suchen — auch innerhalb von Archiven
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

## Nutzung durch AI-Agenten / Skripte (headless)

Favenio ist bewusst maschinenfreundlich gebaut:

- **`--json`**: ein Treffer pro Zeile als JSON-Objekt (JSONL) —
  `{"path": "...", "type": "file|dir|member", "line": 2}`
- **Exit-Codes** wie bei grep: `0` = Treffer, `1` = keine Treffer,
  `2` = Fehler (ungültiger Regex, Pfad fehlt)
- **Warnungen** (unlesbare Dateien, kaputte Archive) gehen nach stderr,
  die Suche läuft weiter — stdout bleibt sauber parsebar.

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
| `--json` | JSONL-Ausgabe für Skripte/Agenten |
| `--version` | Version anzeigen |

Ohne Platzhalter (`* ? [`) gilt „Name **enthält** den Suchtext";
mit Platzhaltern Glob-Matching auf den ganzen Namen. Bei der
Namenssuche zählen auch Ordnernamen als Treffer.

## GUI (Favenio.app)

EasyFind-artige Oberfläche: Suchfeld, Ordnerwahl, Optionen, Trefferliste.

```bash
./build-app.sh    # baut Favenio.app + FavenioQuick.app und testet sie
open Favenio.app
```

Aus der Trefferliste heraus:

- **Doppelklick** — öffnet die Datei; Archiv-Einträge werden vorher
  automatisch in einen Temp-Ordner ausgepackt (`--extract`)
- **Rechtsklick** — Öffnen / **Öffnen mit…** (alle passenden Apps) /
  Im Finder zeigen / Pfad kopieren
- **Drag & Drop** — Treffer in den Finder oder andere Apps ziehen
  (auch Dateien aus Archiven — gezogen wird die ausgepackte Kopie)

Die GUI ist nur ein Frontend: Gesucht wird immer über `favenio.py`.

## Schnellsuche (FavenioQuick.app)

Spotlight-Ersatz für die Finder-Toolbar: `FavenioQuick.app` bei
gedrückter **Cmd-Taste** in die Kopfleiste eines Finder-Fensters ziehen.

- Klick aufs Icon → kleines schwebendes Suchfeld (kein Dock-Icon)
- **Return** → Namenssuche im Benutzerordner (inkl. Archive)
- Bei Treffern öffnet sich die große GUI mit der fertigen Liste
  (die Treffer werden übergeben, es wird nicht doppelt gesucht);
  ohne Treffer bleibt nur das kleine Feld mit einer Meldung
- **Esc** (bei leerem Feld) beendet die Schnellsuche

Hinweis: Beim ersten Suchlauf über den Benutzerordner fragt macOS
ggf. nach Zugriff auf Schreibtisch/Dokumente (TCC) — einmal erlauben.

## Tests

```bash
python3 -m unittest discover -s tests            # 21 Unit-Tests (Kern)
Favenio.app/Contents/MacOS/Favenio --selftest    # Headless-GUI-Anbindung
```

`build-app.sh` führt den Selbsttest nach jedem Build automatisch aus.

## Stand

Version 0.2.0 · Stand: 2026-07-11
