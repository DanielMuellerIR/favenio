# Changelog

## 0.22.1 — 2026-08-19

Aus der CodeQA-Kampagne vom 2026-08-19:

- `--archive-depth` lehnt negative Werte jetzt mit einer Fehlermeldung ab.
  Bisher lief `--archive-depth -1` stillschweigend wie `0` und unterschlug
  damit alle Archivtreffer — ein Tippfehler blieb unbemerkt. `0` bleibt
  ausdrücklich erlaubt und wirkt wie `--no-archives`.
- `./install.sh --help` zeigt wieder den vollständigen Kopftext. Die Hilfe
  schnitt an einer fest eingetragenen Zeilennummer ab; als der Kopf um die
  Erklärung von Exit 3 wuchs, fiel der Hinweis auf die maschinenlesbare
  Erfolgszeile stillschweigend heraus. Die Hilfe endet jetzt an der ersten
  Nicht-Kommentarzeile.
- `release.sh` hängt das Arbeits-Image wieder unter `/Volumes/Favenio` ein.
  Ein Zwischenstand nutzte einen eigenen Mountpoint im Arbeitsverzeichnis —
  der Finder führt ein Volume aber unter dem Ordnernamen seines Mountpoints
  und nicht unter seinem Volume-Namen, sodass das Layout-Skript die Platte
  `Favenio` nicht mehr fand und der Standardlauf in Schritt 3 abbrach. Die
  Absicherungen des Zwischenstands bleiben: Ein fremdes Volume gleichen
  Namens bricht den Lauf ab, und ausgehängt wird nur ein eigener Attach.

## 0.22.0 — 2026-08-16

- **Schnellsuche:** Das normale, minimierbare App-Fenster ersetzt das stets
  schwebende Panel. Suchfeld und Ordnerbereich teilen die obere Zeile
  gleichmäßig.
- **Trefferliste:** Die Namensspalte beginnt bei 65 Prozent, beide Spalten sind
  per Kopfzeile sortierbar und der verschiebbare Trenner sowie horizontales
  Scrollen machen lange Quellpfade zugänglich.
- **Treffertyp:** Die Schnellsuche kann Dateien und Ordner, nur Dateien oder nur
  Ordner finden; die Auswahl bleibt bei der Übergabe an Favenio erhalten.
- Die Erklärung der Grenze von 20 Schnellsuche-Treffern steht im Tooltip von
  „Alle in Favenio“ statt in einer eigenen Statuszeile.

## 0.21.2 — 2026-08-16

Korrekturen aus dem Nacht-Review vom 2026-08-16:

- Suchmuster mit führendem `-` funktionieren hinter dem üblichen Trenner `--`
  jetzt auch mit dem macOS-System-Python 3.9 und damit in beiden Apps.
- Die Frontends unterscheiden regulären Exit 1 („keine Treffer") von einem
  Signalabbruch mit derselben Nummer; der Headless-Selbsttest beendet dafür
  einen echten Probeprozess per SIGHUP.
- FavenioQuick verwirft Finder-Antworten einer früheren Aktivierung und startet
  eine vorgemerkte aktuelle Abfrage, sobald die alte beendet ist.
- `install.sh` garantiert bei Exit 2 wieder den unveränderten installierten
  Stand. Scheitert der Rollback selbst, meldet Exit 3 den Ausnahmezustand und
  stderr nennt die verbleibenden Pfade.
- Die Architekturregel zur Finder-Abfrage nennt die zwingende Ausnahme vom
  Sechs-Sekunden-Notaus, solange der TCC-Freigabedialog offen ist.

## 0.21.1 — 2026-08-15

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
- **Angeheftetes Notary-Ticket ist Pflicht:** Bisher installierte
  `./install.sh --dmg <pfad>` auch Bundles ohne eigenes Ticket und meldete das
  nur als Hinweis — gedacht als Rücksicht auf sehr alte DMGs, bei denen das
  Ticket am Image hängt. Nach `/Applications` kommen jetzt ausnahmslos
  notarisierte und gestapelte Bundles; solche DMGs werden abgelehnt.
- **Update-Feed wird geprüft:** `install.sh` und `release.sh` reichten die
  Umgebung unverändert an `build-app.sh` weiter. Ein geerbtes
  `SPARKLE_FEED_URL` — gedacht für lokale Sparkle-Tests — richtete eine
  installierte oder ausgelieferte App dauerhaft auf einen fremden
  Update-Feed. Beide Skripte prüfen die erzeugten Info.plists jetzt gegen die
  Produktions-URL und brechen bei jeder Abweichung ab.
- **Appcast-Workflow:** Vor dem Signieren des Feeds wurde vom Release-DMG nur
  „genau zwei Apps mit gleicher Version" geprüft. Jetzt zählen Signatur,
  Gatekeeper-Urteil, angeheftetes Ticket, die Bundle-IDs, der
  Update-Schlüssel und die Übereinstimmung mit dem Release-Tag; der
  anschließende Selbsttest prüft die Feed-Signatur gegen den öffentlichen
  Schlüssel aus den Bundles statt gegen den privaten, mit dem gerade
  signiert wurde.
- **Appcast-Workflow, zweite Runde:** Die Bundle-IDs wurden nur gezählt — zwei
  vertauschte Bundles kamen damit durch, obwohl danach jede App das jeweils
  andere Programm aktualisiert hätte. Die erwartete ID kommt jetzt aus dem
  Dateinamen. Zusätzlich geprüft werden `SUFeedURL` gegen die Produktions-URL,
  `SURequireSignedFeed` und die Übereinstimmung von `CFBundleVersion` mit der
  Kurzversion — Letzteres fängt ein versehentlich mit
  `FAVENIO_SPARKLE_TEST_VERSION` gebautes Artefakt ab.
- **Erstinstallation nach einem Fehler:** Beim Zurückrollen wurden nur Bundles
  angefasst, für die es einen gesicherten alten Stand gab. Lag noch nichts in
  `/Applications`, blieben beide neuen Bundles trotz Exit 2 liegen. Der Lauf
  merkt sich jetzt, was er eingesetzt hat, und räumt es beim Zurückrollen weg.
- **`install.sh` prüft auch die Build-Nummer:** Verglichen wurde nur
  `CFBundleShortVersionString`, obwohl Sparkle nach `CFBundleVersion`
  entscheidet. Beide Werte müssen jetzt vorhanden sein und zwischen den
  Bundles übereinstimmen.
- **Schnellsuche, später Finder-Hinweis:** Meldet sich der Finder erst,
  während die Suche schon im Ersatzordner läuft, stand der Hinweis „Suche
  läuft in X — Finder-Ordner ist Y" nur bis zum ersten Trefferpaket in der
  Info-Zeile. Er wird jetzt gemerkt und bleibt bis zum Ende des Suchlaufs
  sichtbar.
- **Zurückrollen der Installation, geprüft statt geraten:** Ein schon
  eingesetztes Bundle wurde mit `rm -rf` ohne Statusprüfung weggeräumt. Weil
  `install.sh` die Installationsfunktion in einer `||`-Liste aufruft, greift
  `set -e` innerhalb der Funktion nicht — ein misslungenes oder halb
  gelungenes Löschen blieb unbemerkt, und Exit 2 konnte trotz der Zusage
  „nichts installiert" ein neues oder zerpflücktes Bundle hinterlassen.
  Weggeräumt wird jetzt per geprüftem `mv`; scheitert das, sagt der Lauf es
  und schreibt den alten Stand nicht blind darüber.
- **Zwei Installationen gleichzeitig:** Der Austausch läuft jetzt unter einer
  Sperre pro Zielordner, und das Zurückrollen löscht nicht mehr allein anhand
  des Bundle-Namens. Hatte ein paralleler Lauf den Zielpfad inzwischen
  ersetzt, nahm der erste Lauf beim Zurückrollen dessen frisches Bundle mit.
  Die beim Einsetzen gemerkte Kennung des Verzeichniseintrags (Gerät und
  Inode) erkennt das jetzt und lässt ein fremdes Bundle stehen.
- **Abbruch während der Installation:** `INT`, `TERM` und `HUP` konnten den
  Zweibundle-Tausch bisher zwischen den Apps beenden. Die Sperre verschwand,
  aber neue und alte Bundles sowie Ablage- und Sicherungsordner blieben als
  halber Stand zurück. Die Transaktion fängt diese Signale jetzt selbst ab,
  holt beide alten Bundles zurück und schützt den Rollback vor einem zweiten
  Abbruchsignal. Reale Signaltests decken `SIGINT` und `SIGTERM` ab.
- **Release-Herausgeber wird erzwungen:** Gültige Signatur und Notarisierung
  allein beweisen nicht, dass ein Bundle von Favenios Entwickler-Team stammt.
  Der lokale Release und das Appcast-Tor verlangen jetzt eine außerhalb des
  Repos konfigurierte Team-ID und prüfen beide Apps mit einer `codesign`-
  Anforderung gegen genau dieses Team, bevor ein DMG ausgeliefert oder für
  Sparkle signiert wird. Die bisher optionale Installationsprüfung erreicht
  `codesign` nun ebenfalls wirklich: Ihre lokale zsh-Variable `path` hatte
  unbemerkt den gleichnamigen Suchpfad der Shell überschrieben.
- **Release-DMG vor dem Mounten geprüft:** Das Appcast-Tor validierte Ticket
  und Gatekeeper-Urteil bisher erst, nachdem `hdiutil` das heruntergeladene
  Release-DMG bereits eingehängt hatte. Die Container-Prüfung ist jetzt ein
  eigener getesteter Schritt vor dem Mounten; erst danach werden die beiden
  enthaltenen Apps geprüft und für Sparkle signiert.
- **Freie Reihenfolge der CLI-Optionen:** Beim macOS-System-Python brach ein
  Aufruf wie `--content X --archive-depth 2 PFAD` mit Exit 2 ab, weil eine
  Option mit Wert zwischen Muster und Startpfad stand. Optionen und
  Positionsargumente lassen sich jetzt wie bei üblichen CLI-Werkzeugen
  mischen.
- **Lokale und CI-Builds:** Der Ad-hoc-Fallback aktivierte Hardened Runtime,
  obwohl App und Sparkle-Framework ohne Developer-ID keine gemeinsame Team-ID
  haben. macOS verweigerte deshalb beim Headless-Test das Laden von Sparkle.
  Ad-hoc-Builds bleiben jetzt bewusst ohne Hardened Runtime; Release-Builds
  mit Developer-ID behalten sie. Außerdem schreibt `plutil` eine abweichende
  `SPARKLE_FEED_URL` sicher in beide Plists, sodass gültige URLs mit `&` das
  XML nicht mehr beschädigen.
- **Schnellsuche, vollständiger Fallback:** Scheiterte das registrierte
  URL-Schema, startete Quick die Haupt-App nur mit Suchtext und Trefferdatei.
  Suchwurzel, Inhalt, Archive, Unsichtbare und „Genauer Name" gingen verloren,
  die fortgesetzte Suche passte nicht mehr zu den schon gezeigten Treffern.
  Der direkte App-Start übergibt jetzt denselben strukturierten Datensatz wie
  der URL-Weg. Außerdem werden alte Finder-Ordner vor jeder neuen Abfrage aus
  dem Cache entfernt, damit Timeout oder verweigerte Automation nicht im
  Ordner der vorigen Aktivierung suchen.
- **Offener Finder-Freigabedialog:** Trotz der Zusage, die wartende
  macOS-Automationsfreigabe nicht abzubrechen, beendete der gemeinsame
  Finder-Unterprozess sie nach 180 Sekunden. Der Sechs-Sekunden-Notaus gilt
  jetzt nur bei bereits entschiedenem Zugriff; ein offener Systemdialog hat
  kein künstliches Zeitlimit mehr.
- **Unerwarteter Suchprozess-Abbruch:** Haupt-App und Schnellsuche behandelten
  nur Exit 2 als Fehler. Ein Signalabbruch oder jeder andere unerwartete Status
  erschien deshalb als normaler Abschluss mit Treffern oder „keine Treffer".
  Beide Frontends verwenden jetzt gemeinsam den CLI-Vertrag: Nur 0 und 1 sind
  normale Enden.
- **Schnellsuche, Statuszeile nach dem Ende:** Der gemerkte Hinweis war ein
  fertig formulierter Satz im Präsens. `finish()` und der Stopp bei 20
  Treffern beenden die Suche aber, bevor sie die Zeile neu setzen — die
  fertige Suche meldete deshalb weiter „Suche läuft in …". Und „Return sucht
  dort" stimmte nicht mehr, sobald der Suchbereich selbst gewählt worden war.
  Gemerkt werden jetzt nur die beiden Pfade; der Satz entsteht aus dem
  aktuellen Zustand.

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
