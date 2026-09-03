**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

# Favenio

**„facile invenio", Latein für „ich finde mit Leichtigkeit".**

Favenio ist eine indexlose Dateisuche für macOS im Stil von EasyFind: Sie
durchsucht das Dateisystem direkt (ohne Index, ohne Spotlight) nach Dateinamen
oder Dateiinhalten. Die Besonderheit: **Favenio schaut auch in Archive
hinein.** Unterstützt werden die Zip-Familie (zip, jar, whl, epub, docx, xlsx,
pptx, odt, ods, odp, pages, numbers, key), die Tar-Familie (tar, tar.gz/tgz, tar.bz2/tbz2,
tar.xz/txz) und einzeln komprimierte Dateien (gz, bz2, xz — `notiz.txt.gz`
enthält also `notiz.txt`), auf Wunsch auch Archive in Archiven.

Zwei optionale Integrationen erweitern die Liste: Mit dem System-`bsdtar`
(in macOS enthalten) liest Favenio auch **7z** und **ISO**-Abbilder, und wenn
ein `zstd`-Programm installiert ist (z. B. über Homebrew, wird automatisch
gefunden) zusätzlich **zst** und **tar.zst**. Ohne diese Werkzeuge bleiben
die Dateien einfach normale Dateien — wie bisher.

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

Alternativ selbst bauen — drei Skripte, jedes für sich vollständig:

```bash
./build-app.sh      # beide Apps im Repository bauen und selbst testen
./install.sh        # bauen, notarisieren, nach /Applications installieren
./release.sh        # bauen, notarisieren, DMG bauen und notarisieren
```

Quell-Builds können nur ad hoc signiert sein und werden nie automatisch
installiert. Was in `/Applications` landet, trägt ein angeheftetes
Notary-Ticket: `install.sh` notarisiert die Bundles selbst, prüft sie vor und
nach dem Kopieren (`codesign`, `spctl`, `stapler validate`) und endet bei jedem
Fehler mit Exit-Code 2, ohne `/Applications` anzufassen. Eine gültige Signatur
allein genügt nicht: Geprüft werden auch die Bundle-IDs und die übereinstimmende
Version, damit keine fremde notarisierte App unter demselben Dateinamen an die
Stelle von Favenio treten kann. Beide Apps werden als eine Transaktion
getauscht — scheitert ein Schritt, kommen beide alten Stände zurück.
`./install.sh --dmg <pfad>` installiert stattdessen aus einem fertigen DMG,
`./install.sh --verify-only` führt nur die Prüfung aus. Auch die Bundles in
einem DMG brauchen ihr eigenes angeheftetes Ticket, damit sie offline starten;
sehr alte DMGs, die es nur am Image tragen, werden abgelehnt. Beide Skripte
prüfen außerdem, dass die Bundles auf den Produktions-Update-Feed zeigen:
`build-app.sh` nimmt für lokale End-to-End-Tests ein abweichendes
`SPARKLE_FEED_URL` an, eine damit installierte oder ausgelieferte App wird
abgelehnt.

## Schnellstart (CLI)

```bash
# Dateinamen suchen („enthält“, Groß-/Kleinschreibung egal)
./favenio.py rechnung ~/Documents

# Glob-Muster (matcht den ganzen Namen)
./favenio.py "*.sketch" ~/Projekte

# Genauer Dateiname — ohne -e ist „release.sh" ein Teilstring und findet
# auch „test-github-release.sh"
./favenio.py -e release.sh ~/git

# Nur zwei Ordnerebenen tief (wie find -maxdepth): welche Projekte haben
# ein Release-Skript?
./favenio.py -e --max-depth 2 release.sh ~/git

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
  `{"path": "...", "type": "member", "isDirectory": false, "filesystemPath": "/tmp/a.zip", "archiveMembers": ["innen.txt"], "line": 2}`.
  `path` bleibt die menschenlesbare Darstellung; Automation sollte die
  eindeutigen strukturierten Felder verwenden. Jeder Treffer trägt `path`,
  `type`, `isDirectory`, `filesystemPath` und `archiveMembers`; Inhaltstreffer
  zusätzlich `line`. Dateien tragen `size` (entpackte Bytes), **soweit das
  Format die Größe vorab nennt**: normale Dateien, Zip- und Tar-Einträge ja,
  einzeln komprimierte Dateien (`.gz`, `.bz2`, `.xz`) und über `bsdtar`
  gelesene Einträge (7z, ISO, `.tar.zst`) nein — dort steht die Größe erst
  nach vollständigem Entpacken fest, und die Suche endet beim ersten Treffer.
  Das Feld fehlt ebenfalls, wenn sich die Größe einer normalen Datei nicht
  ermitteln lässt (zum Beispiel bei einem toten Symlink). `size` ist also ein
  optionales Feld. Für „ist das ein Ordner?"
  `isDirectory` fragen, nicht `type`: Ein **Ordner innerhalb eines Archivs**
  kommt genau wie eine Datei als `"type": "member"` an. Metadatentreffer
  tragen zusätzlich `field` und `value`; mit Maßfilter tragen Treffer `width`
  und `height` (Pixel). Alle vier sind optional.
- **Exit-Codes** wie bei grep: `0` = Treffer, `1` = keine Treffer,
  `2` = Fehler (ungültiger Regex, Pfad fehlt)
- **Warnungen** (unlesbare Dateien, kaputte Archive) gehen nach stderr;
  die Suche läuft weiter, und stdout bleibt sauber parsebar.

```bash
./favenio.py --json -c "TODO" src/ | jq -r .path | sort -u
```

Beginnt das Suchmuster mit `-`, steht davor `--`, damit es nicht als Option
gelesen wird: `./favenio.py -- -entwurf ~/Dokumente`.

## Optionen

| Option | Wirkung |
|---|---|
| `-c`, `--content` | im Dateiinhalt suchen statt in Namen |
| `-m`, `--metadata` | in den kuratierten Metadaten-Textfeldern suchen (Stichwörter, Titel, Beschreibung …) statt in Namen; braucht `exiftool` |
| `--metadata-field TAG` | `--metadata` auf ein Feld der kuratierten Liste eingrenzen (wiederholbar; schaltet `--metadata` ein) |
| `--list-metadata-fields` | die kuratierte Feldliste ausgeben, eine je Zeile, und beenden |
| `--min-width PX`, `--max-width PX` | nur Bilder ab / bis zu dieser Breite (Pixel) |
| `--min-height PX`, `--max-height PX` | nur Bilder ab / bis zu dieser Höhe (Pixel); alle vier Maßfilter gelten per UND zusätzlich zum Muster, das dann auch fehlen darf |
| `-r`, `--regex` | Muster als regulären Ausdruck interpretieren |
| `-s`, `--case-sensitive` | Groß-/Kleinschreibung beachten |
| `-e`, `--exact` | Muster muss dem GANZEN Namen entsprechen (mit `-r`: fullmatch; mit `-c` je Zeile) |
| `--max-depth N` | nur N Ordnerebenen tief suchen (1 = nur direkt im Startpfad, wie `find -maxdepth`) |
| `--no-archives` | nicht in Archive hineinschauen; sie bleiben normale Dateien (siehe unten) |
| `--archive-depth N` | Verschachtelungstiefe (0 = wie `--no-archives`, Default 1) |
| `--max-archive-member-bytes BYTES` | maximal gelesene entpackte Bytes pro Archivmitglied |
| `--max-archive-total-bytes BYTES` | maximal gelesene entpackte Archivbytes pro Suchlauf |
| `--max-archive-ratio FAKTOR` | maximales ZIP-Kompressionsverhältnis |
| `--only both\|files\|dirs` | Treffer auf Dateien, Ordner oder beides (Default) begrenzen |
| `--hidden` | unsichtbare (Punkt-)Dateien und -Ordner mitdurchsuchen |
| `--json` | JSONL-Ausgabe für Skripte/Agenten (mit `size` in Bytes, soweit das Format sie nennt) |
| `--progress` | laufend melden, wo gerade gesucht wird (mit `--json` als JSONL-Objekte, sonst auf stderr) |
| `--extract TREFFER` | Treffer-Pfad (`!/`-Notation) in einen Temp-Ordner auspacken und den nutzbaren Pfad ausgeben |
| `--extract-json JSON` | einen eindeutigen strukturierten JSON-Treffer auspacken |
| `--extract-root ORDNER` | Temp-Wurzel für die Extraktion (nutzen die Apps, die sie selbst aufräumen) |
| `--version` | Version anzeigen |

`--no-archives` (und `--archive-depth 0`) heißt **nicht hineinschauen**,
nicht **auslassen**. Die Datei zählt dann als ganz normale Datei, mit `-c` wird
also ihr roher Inhalt durchsucht. Genau so verhält sich eine `.7z` ohne
`bsdtar` — der Grund, warum Favenio nicht hineinschaut, darf das Ergebnis nicht
ändern, sonst hinge es vom Zufall der installierten Werkzeuge ab, ob eine Datei
überhaupt angefasst wird. Praktisch entsteht ein Treffer auf dem Behälter
selbst nur, wenn der Text wirklich in seinen Rohbytes steht, also bei
unkomprimiert abgelegten Einträgen. Dasselbe gilt eine Ebene tiefer: Ein
Archiv IM Archiv, das die verbleibende `--archive-depth` nicht mehr öffnet,
zählt ebenfalls als ganz normaler Eintrag.

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

## Metadaten- und Bildmaßsuche

`--metadata` prüft das Muster gegen eine **kuratierte Liste von Textfeldern**
(Stichwörter, Titel, Beschreibung, Kommentar, Künstler, Album …;
`--list-metadata-fields` gibt sie aus). „Alle Metadaten" taugen nicht als
Suchraum: In einem realen Bestand aus Bildern, PDFs und Audio sind die
häufigsten Felder ICC-Profil-Rauschen, der nutzerrelevante Text steckt in etwa
fünfzehn Feldern. Die Liste ist eine Konstante in `favenio.py` und darf sich
ändern. Gelesen wird über das optionale [`exiftool`](https://exiftool.org)
(`brew install exiftool`) in **einem** Prozess je Suchlauf (`-stay_open`); das
kostet deutlich unter einer Millisekunde je Bild und etwa 60 ms je PDF. Nur
Dateien mit Medienendung gehen an exiftool. Ein Metadatentreffer nennt Feld und
Wert: in der Textausgabe als `pfad:Keywords: Winter`, in JSON als `field` und
`value`. Einträge in Archiven und Ordner können eine Metadatensuche nicht
erfüllen.

Die vier Maßfilter `--min-width`, `--max-width`, `--min-height` und
`--max-height` gelten immer **zusätzlich** (UND) zum Muster, egal in welchem
Modus es läuft — `--metadata Winter --min-width 1000` findet Bilder mit
Stichwort „Winter", die mindestens 1000 px breit sind. Breite und Höhe kommen
aus dem Dateikopf (JPEG, PNG, GIF, BMP, WebP, TIFF; auch in Archiven) ohne
jede Abhängigkeit; nur HEIC, AVIF, RAW und Video fallen auf `exiftool` zurück.
Dateien ohne lesbare Maße erfüllen einen Maßfilter nie. Mit Maßfilter darf das
Muster fehlen (`favenio.py --min-width 3000 ~/Pictures`, auch mit mehreren
Startpfaden); die Suche läuft dann ganz ohne Textkriterium, weshalb
`--content` und `--metadata` — die sagen, wogegen das Muster läuft — eines
brauchen. JSON-Treffer tragen `width` und `height`. Billige Prüfungen laufen
zuerst: Name, dann Maße, dann Metadaten, dann Inhalt. Für die Formate, die der
eingebaute Leser kennt, sieht exiftool deshalb nur Dateien, die den Maßfilter
schon bestanden haben. Bei HEIC, AVIF, RAW und Video wird es früher gefragt —
dort kommen die Maße selbst von exiftool, billiger sind sie nicht zu haben.

## Wie die Inhaltssuche liest

Mit `-c` liest Favenio häppchenweise und hört beim ersten Treffer auf. Bei
einem festen Suchtext (ohne `-r`, ohne Platzhalter) arbeitet die Suche in zwei
Schritten: erst ein billiger Test, ob der Text überhaupt vorkommt, und nur bei
einem echten Treffer ein zweiter Durchlauf für die Zeilennummer. Das ist rund
**1,4- bis 1,9-mal schneller** als jede Zeile jeder Datei zu prüfen — auch
innerhalb von Archiven — und liefert genau dieselben Treffer und
Zeilennummern.

Zwei Punkte, die man dazu wissen sollte:

- Inhalt wird als UTF-8 mit `errors="replace"` gelesen. Deshalb bleiben
  Treffer in teilweise binären Dateien möglich; andere Textkodierungen werden
  nicht versprochen.
- Weil das Lesen beim ersten Treffer endet, wird die CRC-Prüfsumme eines
  ZIP-Eintrags **nicht** geprüft — Python prüft sie erst am Ende des Eintrags.
  Ein Treffer ist ein Fund, keine Aussage über die Unversehrtheit des Archivs.
  Dafür ist ein Archivwerkzeug zuständig.

## GUI (Favenio.app)

EasyFind-artige Oberfläche: Suchfeld, Ordnerwahl, Optionen, Trefferliste.
Der Umschalter **Name | Inhalt | Metadaten** sagt, wogegen das Muster läuft;
im Metadaten-Modus grenzt ein Feldmenü auf ein Feld ein. Die Zeile
**Bildmaße** (Breite und Höhe je von/bis) filtert per UND und funktioniert auch
allein ohne Muster. Die Spalte **Fundstelle** zeigt die Zeilennummer eines
Inhaltstreffers oder `Keywords: Winter` bei einem Metadatentreffer, die Spalte
**Maße** die Pixelmaße.

Aus der Trefferliste heraus:

- **Doppelklick**: Öffnet die Datei. Archiv-Einträge werden einmal in einen
  app-eigenen Temp-Ordner ausgepackt und für Vorschau, Öffnen, Finder und Ziehen
  wiederverwendet
- **Rechtsklick**: Öffnen / **Öffnen mit…** (alle passenden Apps) /
  Im Finder zeigen / Pfad kopieren
- **Drag & Drop**: Treffer in den Finder oder andere Apps ziehen.
  Das geht auch mit Dateien aus Archiven; gezogen wird dann die
  ausgepackte Kopie
- **Leertaste**: QuickLook-Vorschau. Der Tastaturfokus bleibt in der
  Trefferliste, mit Pfeil hoch/runter wandert die Vorschau also durch die
  Treffer

Die Fußzeile zählt Treffer, Datenmenge und die Anzahl der Ordner, auf die sie
sich verteilen; ab zwei markierten Zeilen auch die Größe der Auswahl. Steht ein
`≥` vor der Datenmenge, hat mindestens eine Datei keine vorab bekannte Größe
(siehe `size` im JSON-Vertrag).

### Trefferliste verfeinern, exportieren, aufräumen

Diese drei Punkte stehen im Menü **Ablage** und im Rechtsklick-Menü der
Trefferliste. Die Kürzel, die auf der Auswahl arbeiten (⌫, ⌘⌫, ⇧⌘E), gelten
nur, solange die Trefferliste den Fokus hat — im Suchfeld löscht ⌫ weiterhin
ein Zeichen. ⌘E exportiert die ganze Liste und gilt, sobald das Hauptfenster
aktiv ist; in einem Dialog gilt es nie.

| Aktion | Kürzel | Wirkung |
| --- | --- | --- |
| Aus Trefferliste entfernen | ⌫ | Wirft Zeilen nur aus der **Anzeige**. Die Dateien bleiben unangetastet. Damit lässt sich eine große Trefferliste schrittweise auf das eindampfen, was wirklich gemeint war |
| In den Papierkorb legen | ⌘⌫ | Legt die Dateien nach Rückfrage in den Papierkorb — wie im Finder, mit demselben Geräusch, und aus dem Papierkorb zurückholbar. Einträge *in* einem Archiv werden ausgelassen und genannt: Hinter ihnen liegt keine eigene Datei |
| Alle Treffer exportieren… | ⌘E | Schreibt die ganze Liste in eine Datei |
| Auswahl exportieren… | ⇧⌘E | Dasselbe nur für die markierten Zeilen |

Der Sichern-Dialog bietet vier Formate an:

| Format | Wofür |
| --- | --- |
| Pfade, eine Zeile pro Treffer (`.txt`) | Das, was Kommandozeilenwerkzeuge erwarten: `xargs`, `while read`, `grep -f` |
| Pfade, NUL-getrennt (`.txt`) | Dieselbe Liste für `xargs -0`. Ein Dateiname darf unter macOS jedes Zeichen außer `/` und NUL enthalten — auch einen Zeilenumbruch. Nur diese Form überträgt deshalb **jeden** Namen unversehrt |
| JSON Lines (`.jsonl`) | Dieselben Objekte, die `favenio.py --json` schreibt (`path`, `type`, `isDirectory`, `filesystemPath`, `archiveMembers`, optional `size`/`line`) — für `jq` und eigene Skripte |
| CSV (`.csv`) | Für Tabellenkalkulation; mit UTF-8-BOM, sonst liest Excel unter macOS Umlaute falsch |

In den beiden Pfadformaten steht derselbe Pfad wie bei „Pfad kopieren": bei
einer normalen Datei ihr POSIX-Pfad, bei einem Archiv-Eintrag der Pfad in
`!/`-Notation, den `favenio.py --extract` wieder versteht (ein Eintragsname,
der selbst `!/` enthält, wird gegen die Eintragsliste des Archivs aufgelöst).
Ein Archiv-Eintrag hat keinen eigenen POSIX-Pfad; ihn stillschweigend
wegzulassen wäre schlimmer, als ihn kenntlich zu machen.

```bash
# Alle exportierten Treffer nach „TODO" durchsuchen (BSD-xargs kennt kein -a)
xargs -0 grep -l TODO < Favenio-Treffer.txt
```

Die GUI ist nur ein Frontend: Gesucht wird immer über `favenio.py`.

## Schnellsuche (FavenioQuick.app)

Spotlight-Ersatz für die Finder-Toolbar: `FavenioQuick.app` bei
gedrückter **Cmd-Taste** in die Kopfleiste eines Finder-Fensters ziehen.

- Ein Klick aufs Icon öffnet ein kleines normales App-Fenster (kein Dock-Icon)
- **Return** startet die Namenssuche in dem Suchbereich, der neben dem Feld
  steht — voreingestellt ist der Ordner des vordersten Finder-Fensters.
  Archive sind ein zuschaltbarer Schalter und **standardmäßig aus**; für
  Treffer im Archiv **Archive** ankreuzen
- Der Typ-Umschalter begrenzt Treffer auf Dateien und Ordner, nur Dateien oder
  nur Ordner
- **Name | Inhalt | Metadaten** wählt, wogegen der eine Suchbegriff läuft; die
  `px`-Zeile (Breite und Höhe je von/bis) ergänzt Maßfilter und funktioniert
  auch ohne Begriff
- Die Ergebnisspalten sind sortierbar und verschiebbar; horizontales Scrollen
  macht lange Quellpfade zugänglich
- Die Schnellsuche zeigt bis zu 20 Treffer. **Alle in Favenio** oder
  **Cmd-Return** übergibt sie an die Haupt-App, die dieselbe Suche ohne
  Duplikate fortsetzt
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
