# Changelog

## 0.27.4 — 2026-09-03

Aus der CodeQA-Kampagne, Bereich Release und Appcast.

- **`release.sh` räumt bei SIGTERM auf.** Gemessen mit zsh 5.9: Ein
  `trap … EXIT` läuft bei Ctrl-C und bei geschlossenem Terminal mit, bei
  SIGTERM nicht. Hier wiegt das schwerer als bei der Installation, weil der
  Mountpoint ein FESTER Pfad ist: Ein liegengebliebenes `/Volumes/Favenio`
  lässt jeden weiteren Release-Lauf absichtlich abbrechen, bis jemand von
  Hand auswirft.
- **Ein Release prüft die Bundles jetzt so streng wie eine Installation.** Die
  Prüfung im fertigen DMG kannte nur Signatur und angeheftetes Ticket und ließ
  `spctl` weg. Beide Wege rufen jetzt dieselbe Funktion aus `notarize-lib.sh`.
- **Das Appcast-Tor lässt kein Temp-Verzeichnis liegen.** Die Feed-Prüfung
  kehrt an mehreren Stellen mit einem Fehler zurück und legte je Aufruf ein
  `mktemp`-Verzeichnis an. Im CI-Läufer harmlos, in den lokalen Tests dieses
  Blocks nicht: Dort hatten sich Hunderte angesammelt.
- **Die Testmodule laufen aus jedem Arbeitsverzeichnis.** Siebzehn
  Lesezugriffe gingen gegen das aktuelle Verzeichnis statt gegen das Repo; aus
  einem anderen Ordner gestartet brachen die Tests ab, statt zu prüfen.
- **Eine Wache prüft Verhalten statt einen Namen.** Die Absicherung der
  Flächensortierung bestätigte mit `assertIn("MAX_IMAGE_EDGE", …)` nur sich
  selbst und suchte zusätzlich eine Zeichenkette, die nie im Code stand. Jetzt
  wird der Wert der Konstante geprüft.

## 0.27.3 — 2026-09-03

Aus der CodeQA-Kampagne, Bereich Installation und Notarisierung.

- **`install.sh` lehnt geerbte Sparkle-Testvariablen ab.** `SPARKLE_FEED_URL`
  hätte die installierte App dauerhaft auf einen fremden Update-Feed
  gerichtet, `FAVENIO_SPARKLE_TEST_VERSION` ihr eine gefälschte Build-Nummer
  gegeben, mit der sie sich sofort selbst ein „Update" anbietet — die
  Gleichheitsprüfung vergleicht nur die beiden Bundles gegeneinander und wäre
  durchgegangen. Geprüft wird jetzt VOR dem Bauen; die nachgelagerte
  Feed-Prüfung griff erst nach der Notarisierung und hätte einen
  Notary-Vorgang verbraucht.
- **SIGTERM räumt jetzt auf.** Gemessen mit zsh 5.9: Ein `trap … EXIT` läuft
  bei Ctrl-C und bei geschlossenem Terminal mit, bei SIGTERM aber nicht —
  dann blieben das eingehängte DMG und die Installationssperre liegen. Der
  Austausch selbst war nie betroffen, er hat eigene, feinere Handler.
- **Exit 2 hält seine Zusage.** Exit 2 verspricht „installierter Stand
  unverändert". Nach dem Austausch stimmte das nicht mehr: `install.sh | head`
  beendet die letzten Ausgabezeilen mit SIGPIPE, und der Lauf meldete
  fälschlich, nichts geändert zu haben.
- **`notarize_apps` lässt keine Bundle-Kopien mehr liegen.** Die Funktion legt
  rund 40 MB Kopien plus ein Zip in einem `mktemp`-Verzeichnis an; ein
  scheiterndes `ditto` beendete das Skript unter errexit sofort, und das
  Verzeichnis blieb — bei jedem Versuch aufs Neue.
- **Die drei Bundle-Prüfungen haben nur noch einen Ort.** Signatur,
  Gatekeeper-Urteil und angeheftetes Ticket standen in `install.sh` ein
  zweites Mal ausgeschrieben; jetzt ruft es dieselbe Funktion aus
  `notarize-lib.sh`, die auch nach dem Austausch prüft. Sie nennt beim
  Scheitern, welche der drei Prüfungen es war.
- **Die Testsuite hinterlässt keine Temp-Ordner mehr.** Die `hdiutil`-Attrappe
  leerte den Mountpoint bei `detach` nicht, und das bewusst konservative
  `rmdir` in `cleanup()` scheiterte daran. Auf einem Entwicklungsrechner
  hatten sich so 684 Ordner mit Attrappen-Bundles angesammelt.

## 0.27.2 — 2026-09-03

Aus der CodeQA-Kampagne: ein abgebrochener oder unvollständiger Suchlauf war
für beide Apps von einem leeren Ergebnis nicht zu unterscheiden. Zwei
Ursachen, beide behoben.

- **Ein Absturz sah aus wie „keine Treffer".** Python beendet sich bei jeder
  unbehandelten Ausnahme mit Status 1 — genau dem Status, den der Vertrag für
  „keine Treffer" vergibt, und beide Apps lassen 0 und 1 als normal durch. Ein
  Fehler mitten im Lauf kam dort deshalb als vollständige, nur eben kürzere
  Trefferliste an. `main()` fängt einen unerwarteten Fehler jetzt ab, nennt ihn
  auf stderr und endet mit 2. Erwartete Lesefehler einzelner Objekte bleiben
  eine Warnung, und die Suche läuft weiter.
- **Beide Apps warfen den Grund weg.** stderr des Kerns hing auf `nullDevice`.
  Ein fehlendes exiftool, ein ungültiger regulärer Ausdruck und ein gelöschter
  Startordner kamen alle als „Suche fehlgeschlagen." an; die Schnellsuche riet
  sogar zu einer Neuinstallation, die nichts half. Jetzt steht der Satz des
  Kerns in der Fußzeile („Suche fehlgeschlagen: --metadata braucht exiftool,
  das nicht gefunden wurde …").
- **Übersprungene Objekte sind sichtbar.** Musste ein Lauf ein kaputtes Archiv
  oder einen gesperrten Ordner auslassen, sah er genauso vollständig aus wie
  einer, der alles gelesen hat. Die Fußzeile nennt die Zahl jetzt („· 3
  Objekte übersprungen").
- **Drei Fallen dabei, alle mit einer Wache belegt.** stderr wird nebenläufig
  geleert — mit 900 übersprungenen Objekten läuft der Selbsttest ohne das
  nicht zu Ende, weil eine volle Pipe den Kern anhält. Gezählt wird beim
  Durchlaufen, sonst wäre die Zahl auf ein gedeckeltes Textstück beschränkt.
  Und die Schreibseite wird vor dem Lesen geschlossen, weil `availableData`
  sonst unbegrenzt wartet, wenn der Prozess gar nicht erst startete.
- **Sechs Vertragswachen liefen auf keinem Rechner ohne Xcode-Werkzeuge.** Die
  Absicherung der Metadaten- und Maßsuche aus 0.26.0 stand versehentlich in
  einer Klasse mit `@skipUnless(swiftc)`, obwohl sie nur Quelltext liest; die
  Suite meldete trotzdem `OK`. Ohne `swiftc` werden jetzt 7 statt 13 Tests
  übersprungen. Die Wachen lesen ihre Dateien außerdem gegen das Repo statt
  gegen das Arbeitsverzeichnis — aus einem anderen Ordner gestartet brachen
  sie vorher schon beim Import ab.

## 0.27.1 — 2026-09-03

Aus dem Nachlese-Durchgang des Reviews vom 2026-09-03. Vier der sechs Funde
sind Regressionen aus 0.27.0 vom selben Tag — der Durchgang liest die frisch
geänderten Zeilen noch einmal, gerade weil sie neu sind.

- **`.key`-Dateien fielen aus der Inhaltssuche.** Mit den iWork-Endungen kam
  `.key` in die Zip-Liste — auf einem Server ist das aber fast immer ein
  TLS-Schlüssel. Die Datei wurde als Archiv geöffnet, das Öffnen scheiterte,
  und sie war weg (Exit 1 plus „File is not a zip file"), während
  `--no-archives` sie fand. Die Endung ist jetzt ein Hinweis, keine Zusage:
  Lässt sich die Datei nicht als das versprochene Format öffnen, ist sie eine
  ganz normale Datei — genau wie bei `--no-archives` und `--archive-depth 0`.
  Betrifft ebenso `.pages`, `.numbers` und eine beschädigte `.docx`.
- **Dieselbe Datei war je nach Archivtiefe mal findbar, mal nicht.** Ein
  `server.key` in einem Zip wurde bei `--archive-depth 1` gefunden, ab Tiefe 2
  nicht mehr — dort galt er als Archiv. `visit_member()` kennt den Rückfall
  jetzt genauso wie `visit_file()`.
- **Eine benannte Pipe mit Archiv-Endung ließ den Lauf hängen.** Die
  FIFO-Sperre aus 0.27.0 sitzt in `visit_file()`; `zipfile` und `tarfile`
  öffnen den Pfad aber selbst. Eine Pipe namens `x.zip` blockierte deshalb
  weiterhin — sogar die reine Namenssuche, die vorher nie betroffen war. In
  ein Archiv wird jetzt nur geschaut, wenn der Pfad eine reguläre Datei ist.
- **Verankerte Muster trafen am Abschnitts- statt am Zeilenende.** Die
  Begrenzung langer Zeilen aus 0.27.0 prüft das Muster gegen ein Bruchstück.
  Für den reinen „enthält"-Test ist das exakt, für `--regex`, Glob-Muster und
  `--exact` nicht: `--regex 'A$'` meldete auf einer 9-MiB-Zeile einen
  Treffer, den `grep` nicht sieht. Bruchstücke sieht jetzt nur noch der
  „enthält"-Test; für die anderen bleibt eine zu lange Zeile ungeprüft und
  wird als Warnung genannt.
- **Zeilennummern nach einem einzelnen `\r`.** Ein `\r` wartet im Puffer,
  weil ein folgendes `\n` daraus ein CRLF machen könnte. Der
  Abschnittswechsel warf es samt seiner fertigen Zeile weg, und jede folgende
  Zeilennummer war um eins zu klein. Betraf Dateien, die mit einzelnen `\r`
  trennen (klassisches Mac-Format).
- **Der Wurzeleintrag `./` erschien als Ordnertreffer.** Seit `.` nicht mehr
  als versteckter Name gilt, lieferte ein mit `tar -C ordner .` gebautes
  Archiv einen Treffer namens `.` — das Archiv selbst, kein Eintrag darin.
  `--extract` endete darauf mit einem nackten `KeyError`.
- **`--metadata-field` nimmt nur noch Felder der kuratierten Liste.** Die
  Zeichenregel aus 0.27.0 ließ `execute`, `charset`, `p`, `b`, `w`, `if`,
  `ver` und `TagsFromFile` durch — allesamt echte exiftool-Optionen. Schon
  `--metadata-field execute` zerlegte jede Anfrage in zwei Kommandos und
  lieferte für JEDE Datei „keine Treffer". Statt einer Zeichenregel gilt
  jetzt eine Positivliste: die Felder aus `--list-metadata-fields`, in
  beliebiger Schreibweise. Das ist enger als zuvor; Gruppenschreibweisen wie
  `XMP-dc:Subject` gehen nicht mehr.

## 0.27.0 — 2026-09-03

Aus dem projektweiten Code-Review vom 2026-09-03, Bereich Suchkern. Vier der
Fehler beendeten den Suchlauf oder ließen ihn hängen; weil Python bei einer
unbehandelten Ausnahme mit Status 1 endet — genau dem Status für „keine
Treffer" —, sah das in beiden Apps wie ein vollständiges, leeres Ergebnis aus.
Neu suchbar sind die iWork-Formate; eine CLI-Form kommt dazu.

- **Archive mit `./`-Präfix waren komplett unsichtbar.** `tar -cf x.tar -C
  ordner .` — der übliche Weg, einen Ordnerinhalt zu tarren — legt jeden
  Eintrag als `./name` ab. Die Komponente `.` galt als versteckter Name,
  deshalb fiel das ganze Archiv ohne Meldung aus jeder Suche. `.` und `..`
  benennen ein Verzeichnis und sind kein versteckter Name; echte Punktnamen
  bleiben wie bisher hinter `--hidden`.
- **Abgeschnittene WebP-Datei beendete den ganzen Lauf.** Ein halber Download
  ließ den VP8L-Zweig des Maß-Lesers mit `bits[1]` ins Leere greifen; der
  `IndexError` wurde nicht gefangen. Ein abgeschnittener VP8X-Kopf las aus
  leeren Slices still 1×1 Pixel und erzeugte damit Falschtreffer. Beide Zweige
  prüfen jetzt die Kopflänge.
- **Zip mit falschem UTF-8-Flag beendete den ganzen Lauf.** Windows-Packer
  setzen gelegentlich das Flag, obwohl die Eintragsnamen CP932-/Latin-1-Bytes
  tragen; `zipfile` wirft dann schon beim Öffnen. `UnicodeDecodeError` gehört
  jetzt zu den erwarteten Archivfehlern: Warnung auf stderr, Suche läuft weiter.
- **Eine benannte Pipe ließ die Suche hängen.** `open()` auf eine FIFO ohne
  Schreiber wartet unbegrenzt — `--content` und jeder Maßfilter standen still,
  ohne Fehler und ohne Ergebnis. Gelesen wird jetzt nur, was nachweislich eine
  reguläre Datei ist; alles andere wird gemeldet und übersprungen. Die
  Namenssuche zeigt eine Pipe weiterhin an, sie öffnet die Datei ja nicht.
- **exiftool überlebte jeden Suchabbruch.** Beide Apps brechen mit
  `terminate()` ab, die Schnellsuche bei jedem Tastendruck; bei SIGTERM lief
  das `finally` nicht, und der `-stay_open`-Prozess blieb als Waise stehen (auf
  einem Entwicklungsrechner zwei Stück seit 18 Stunden). SIGTERM und SIGHUP
  enden jetzt geordnet. Zusätzlich schließt `close()` beide Pipes — auch auf
  dem Fehlerpfad.
- **Ein Feldname konnte exiftool-Optionen einschleusen.** Die Argumentdatei von
  `-stay_open` ist zeilenweise; ein Zeilenumbruch in `--metadata-field` schob
  beliebige weitere exiftool-Optionen ein, über `-p` mit einem Perl-Ausdruck
  bis hin zu einem Shell-Aufruf. Erlaubt sind jetzt nur Buchstaben, Ziffern,
  `-`, `_` und `:`; alles andere endet mit Exit 2. Die Haupt-App war nie
  betroffen, sie prüft gegen ihre Feldliste.
- **Wegbrechendes exiftool wird gemeldet.** Starb der Prozess mitten im Lauf,
  lieferte er für jede weitere Datei stillschweigend nichts — der Lauf endete
  mit „keine Treffer" und war von einer wirklich leeren Suche nicht zu
  unterscheiden.
- **Pfade mit `#` oder führendem Leerzeichen fielen aus `--metadata`.**
  exiftool liest eine solche Zeile als Kommentar bzw. schneidet den Leerraum
  ab. Jeder relative Pfad bekommt jetzt `./` davor; Leerraum am Zeilenende
  geht über einen eigenen Prozess.
- **Zeilen ohne Umbruch sprengten den Speicher.** Minifiziertes JSON, ein
  Base64-Block oder eine mysqldump-Zeile haben über hunderte Megabyte keinen
  Umbruch; `match_content()` pufferte die Datei vollständig. Gemessen auf
  144 MB Text: 488 MB Spitzenspeicher gegenüber 18 MB bei derselben Datenmenge
  MIT Umbrüchen. Geprüft wird jetzt abschnittsweise mit 64 Ki Zeichen
  Überlappung, damit ein Treffer an der Schnittstelle erhalten bleibt: 58 MB
  statt 488 MB, Ergebnisse unverändert, Laufzeit leicht besser.
- **Die bsdtar-Namensliste hatte keine Grenze.** `ArchiveBudget` zählt nur
  Eintrags-Inhalte. Bei 7z, ISO und tar.zst liegt der Namenskatalog
  komprimiert im Archiv: 307 KB Archiv mit 200 000 Einträgen ergaben 182 MB
  Spitzenspeicher. Über 32 MiB Auflistung wird das Archiv jetzt mit Meldung
  übersprungen (58 MB). `--extract` wertet dabei denselben Status aus wie die
  Suche, statt bei einem unlesbaren Archiv einen fehlenden Eintrag zu melden.
- **iWork-Dokumente werden durchsucht.** `.pages`, `.numbers` und `.key` sind
  Zip-Container wie `.docx` — auf einem Mac die häufigsten überhaupt. Der Text
  wurde in der `.docx` gefunden, in der `.pages` daneben nicht, und der Lauf
  meldete das als Erfolg.
- **Mehrere Startpfade bei reiner Maßsuche.** `--min-width 100 dirA dirB` las
  `dirA` still als Namensmuster: Beide Ordner einzeln lieferten Treffer,
  zusammen kam Exit 1 und keine Zeile. Befördert wird jetzt, wenn alle
  Positionsargumente als Pfad existieren.
- **Aufräumen in den Tests.** `--extract` legt seinen Ordner bewusst im
  Temp-Verzeichnis an und räumt ihn nicht auf; die Testsuite hinterließ deshalb
  je Lauf über zwanzig `hit-*`-Ordner im Benutzer-Temp-Verzeichnis. Jetzt
  landen sie in einem Ordner, der mit dem Test verschwindet.

## 0.26.1 — 2026-09-02

Korrekturen aus dem Code-Review vom 2026-09-02 (neun Funde) zur Metadaten- und
Bildmaßsuche aus 0.26.0. Der JSON-Vertrag bleibt unverändert; eine
CLI-Kombination verhält sich neu (siehe letzter Punkt).

- **Maß-Leser hält die Entpackgrenzen ein.** Der Bildkopf eines
  Archiv-Eintrags lief am Budget vorbei: Eine Maßsuche fand ihn auch bei
  `--max-archive-total-bytes 1`. Er läuft jetzt über denselben budgetierten
  Chunker wie die Inhaltssuche. Der schon gezählte Anfang belastet einen
  folgenden Inhaltsdurchlauf nicht ein zweites Mal.
- **Suche nur nach Maßen ohne künstliches Muster.** Fehlte das Muster, sprang
  ein `*` ein. Unter `--regex` war das ein ungültiger Ausdruck und beendete
  den Lauf mit Exit 2; unter `--metadata` filterte es still auf Dateien, die
  überhaupt Metadaten tragen, sodass ein ungetaggtes Bild trotz passender
  Maße fehlte. Ohne Muster läuft die Suche jetzt ganz ohne Textkriterium.
- **Übergabe einer reinen Maßsuche an die Haupt-App.** „Alle in Favenio" und
  ⌘↩ in der Schnellsuche brachen bei leerem Suchfeld ab, obwohl die Suche mit
  gesetztem Maßfilter läuft; die Haupt-App beendete die Fortsetzung ebenso.
  Alle drei Wege — Knopf, Tastaturmonitor und `continueSearch` — binden die
  Übergabe jetzt an dieselbe Bedingung wie den Suchstart. Gemessen an 33
  passenden Bildern: vorher blieb es bei den 20 übergebenen Treffern, jetzt
  sucht die Haupt-App bis 33 weiter.
- **Endmeldung einer reinen Maßsuche.** Ohne Suchbegriff schrieb die
  Schnellsuche „20 Treffer für „"." mit leeren Anführungszeichen; jetzt nennt
  der Satz den Maßfilter („1 Treffer (H ≥ 800).").
- **exiftool-Pfade vollständig übergeben.** Ein Dateiname mit Zeilenumbruch
  fiel ohne Meldung aus der Trefferliste (die Argumentdatei ist zeilenweise);
  er geht jetzt über einen eigenen exiftool-Aufruf. Ein relativer Startpfad
  wie `-bilder` galt exiftool als Option und lieferte falsche Ergebnisse.
- **`--extract` liest die bsdtar-Auflistung wie die Suche.** Beide gehen jetzt
  durch dieselbe Funktion. Ein 7z-Eintrag mit maskiertem Steuerzeichen und
  `!/` im Namen wurde gefunden, ließ sich aber nicht mehr materialisieren.
- **Flächensortierung ohne Überlauf.** Ein präparierter Bildkopf mit
  0xffffffff je Kante beendete die Haupt-App beim Sortieren der Maß-Spalte.
  Der Kern lehnt unplausible Kopfmaße jetzt ab, und die Sortierung deckelt die
  Multiplikation zusätzlich.
- **Pixelfelder mit klarer Syntax.** Die Oberflächen strichen aus der Eingabe
  alle Nicht-Ziffern: Aus „-1" wurde 1, aus „10.5" wurde 105. Erlaubt ist
  jetzt eine positive Ganzzahl, wahlweise in Dreierblöcken gruppiert und mit
  „px"; alles andere setzt keine Grenze.
- **`--content` und `--metadata` brauchen ein Muster.** Beide sagen, wogegen
  das Muster läuft. Ohne Muster sind sie eine widersprüchliche Angabe und
  enden mit Exit 2 statt still falsch zu antworten. Die reine Maßsuche
  (`favenio.py --min-width 3000 ~/Pictures`) bleibt unverändert.

## 0.26.0 — 2026-09-02

Metadaten- und Bildmaßsuche — im Kern, in der Haupt-App und in der
Schnellsuche. Der bisherige JSON-Pflichtsatz bleibt unverändert.

- **Suche nach Pixelmaßen.** `--min-width`, `--max-width`, `--min-height`
  und `--max-height` filtern Bilder nach Breite und Höhe. Die Maße kommen aus
  dem Dateikopf (JPEG, PNG, GIF, BMP, WebP, TIFF, auch in Archiven) ohne
  Abhängigkeit — 0,2 ms je Datei, über 30 370 reale Bilder ohne Abweichung
  gegen exiftool geprüft. HEIC, AVIF, RAW und Video fallen auf exiftool
  zurück. Die Filter gelten immer per UND zum Muster, das dann auch fehlen
  darf: `favenio.py --min-width 3000 ~/Pictures`.
- **Suche in Metadaten.** `--metadata` prüft das Muster gegen eine kuratierte
  Liste von Textfeldern (Stichwörter, Titel, Beschreibung, Kommentar, Künstler,
  Album …; `--list-metadata-fields` zeigt sie, `--metadata-field` grenzt auf
  eines ein). Gelesen wird über das optionale exiftool in EINEM Prozess je
  Suchlauf; ohne exiftool sagt der Kern, was fehlt. Treffer nennen Feld und
  Wert, in JSON als `field` und `value`.
- **Kriterien mit Kostenreihenfolge.** Name, dann Maße, dann Metadaten, dann
  Inhalt — exiftool sieht nur Dateien, die den Maßfilter bestanden haben.
  „Winter UND mindestens 1000 px breit" bleibt damit schnell. Der Kern ist so
  geschnitten, dass mehrere UND-verknüpfte Begriffe später dazukommen können.
- **Oberflächen.** Umschalter **Name | Inhalt | Metadaten** statt der
  Checkbox „Inhalt", in der Haupt-App dazu ein Feldmenü; eine Maßzeile mit
  Breite und Höhe je von/bis in beiden Apps. Neue Spalten **Fundstelle**
  (Zeilennummer oder „Keywords: Winter") und **Maße**; JSONL- und CSV-Export
  tragen die neuen Felder mit. Die Schnellsuche übergibt Modus und Maße an die
  Haupt-App.

## 0.25.1 — 2026-09-02

Korrekturen aus dem Code-Review vom 2026-09-02 (neun Funde) und der sichtbaren
Abnahme der Quick-Look-Vorschau. Suchsemantik und JSON-Vertrag sind unverändert.

- **Kürzel gelten nicht mehr in Dialogen.** Solange der Sichern-Dialog des
  Exports oder eine Rückfrage offen war, hielt die App die Trefferliste weiter
  für fokussiert: ⌫ im Dateinamenfeld entfernte Treffer, die Leertaste öffnete
  die Vorschau, ⌘⌫ konnte einen zweiten Papierkorb-Dialog starten. Tastatur-
  monitor und Menüprüfung verlangen jetzt, dass das Hauptfenster das
  Tastaturfenster ist und das Ereignis aus ihm kommt.
- **Papierkorb räumt vollständig auf.** Nach dem Verschieben eines Ordners
  blieben Treffer unter ihm stehen, und ein noch laufender Suchlauf konnte
  Einträge eines verschobenen Archivs erneut einfügen. Der Lauf merkt sich
  jetzt, was im Papierkorb liegt (Datei genau, Ordner mit allem darunter), und
  prüft Liste, vorgemerkte und neu eintreffende Treffer dagegen.
- **Auswahl überlebt Neuladen nur noch pfadbasiert.** Nach dem Entfernen einer
  Zeile oder einer Übergabe aus der Schnellsuche konnte die alte Zeilennummer
  auf einen anderen Treffer wandern und die Vorschau beim alten bleiben.
- **`--extract` versteht Eintragsnamen mit `!/`.** Der Pfad-Export schreibt
  nur die `!/`-Notation; ein Eintrag wie `odd!/name.txt` wurde darin als zwei
  Archivebenen gelesen. Jetzt wird je Ebene gegen die Eintragsliste aufgelöst,
  der längste passende Anfang gewinnt.
- **Kennzahlen stürzen bei absurden Archivgrößen nicht ab.** Mehrere einzeln
  darstellbare, zusammen aber zu große deklarierte Größen beendeten die App;
  die Summe sättigt jetzt und gilt als Untergrenze (`≥`).
- **Quick Look lässt sich blättern, egal wer die Tastatur hat.** Das
  Vorschaufenster wird nur nach vorn geholt; wird es trotzdem Tastaturfenster
  (am Fenster gemessen: nach der Leertaste ist es das), leitet die App wie der
  Finder Pfeil hoch/runter an die Trefferliste weiter, und ⎋ schließt. Der
  frühere Fokus-Rückholer verlor das Rennen (Auswahl grau, Pfeiltasten
  wirkungslos).
- **Installation:** Ein Ctrl-C, das den `mkdir`-Prozess des Sperr- oder
  Ablageordners selbst traf, ließ die eigene Sperre als fremd erscheinen und
  liegen. `mkdir` läuft dort jetzt gegen HUP/INT/TERM abgeschirmt, die Shell
  merkt sich das Signal weiterhin.
- **„Öffnen mit" bei großer Auswahl:** Anwendungen werden je Dateiendung nur
  einmal bei LaunchServices erfragt statt je Treffer.
- README: Das NUL-Export-Beispiel nutzte `xargs -a`, das BSD-`xargs` von macOS
  nicht kennt; jetzt per Umleitung von stdin.

## 0.25.0 — 2026-09-01

Vier neue Werkzeuge in der Haupt-App, alle auf der Trefferliste. Der Python-Kern
ist unverändert; die Suchsemantik und der JSON-Vertrag bleiben, wie sie waren.

- **In den Papierkorb legen (⌘⌫).** Die ausgewählten Dateien landen nach
  Rückfrage im Papierkorb — mit dem Papierkorb-Geräusch des Finders und aus dem
  Papierkorb zurückholbar. Die ganze Auswahl geht in EINEM
  `NSWorkspace.recycle`-Aufruf weg, nicht Datei für Datei; das ist derselbe Weg,
  den auch der Finder nimmt, und deshalb bei tausenden Dateien nicht langsamer.
  Einträge *in* einem Archiv werden ausgelassen und im Dialog genannt: Hinter
  ihnen liegt keine eigene Datei, sondern nur die ausgepackte Temp-Kopie.
  Zeigen mehrere Treffer auf dieselbe Datei, wird sie einmal gelöscht.
- **Aus Trefferliste entfernen (⌫).** Wirft Zeilen nur aus der Anzeige; die
  Dateien bleiben unangetastet. Damit lässt sich eine große Trefferliste
  schrittweise auf das eindampfen, was wirklich gemeint war. Entfernte Pfade
  bleiben in `seenPaths` — ein noch laufender Suchlauf fügt sie nicht wieder
  ein.
- **Treffer exportieren (⌘E für alle, ⇧⌘E für die Auswahl).** Vier Formate:
  Pfade zeilenweise, Pfade NUL-getrennt für `xargs -0` (ein Dateiname darf unter
  macOS jedes Zeichen außer `/` und NUL enthalten, auch einen Zeilenumbruch),
  JSON Lines im Format von `favenio.py --json` und CSV mit UTF-8-BOM für die
  Tabellenkalkulation.
- **Kennzahlen in der Fußzeile.** Neben der Trefferzahl jetzt auch die
  Datenmenge und die Anzahl der Ordner, auf die sich die Treffer verteilen; ab
  zwei markierten Zeilen zusätzlich die Größe der Auswahl. Ein `≥` vor der
  Datenmenge heißt, dass mindestens eine Datei keine vorab bekannte Größe hat.
  Die Zahlen werden beim Streamen fortgeschrieben statt bei jedem Nachschub neu
  aufsummiert.
- **QuickLook lässt sich jetzt durchblättern.** Die Leertaste öffnet die
  Vorschau und gibt den Tastaturfokus sofort ans Hauptfenster zurück. Vorher
  gingen Pfeil hoch/runter an das Vorschaufenster, und man musste erst das
  Favenio-Fenster anklicken, um mit den Pfeiltasten durch die Bilder zu gehen.

Alle drei Listen-Aktionen stehen sichtbar im neuen Menü **Ablage** und im
Rechtsklick-Menü der Trefferliste, jeweils mit ihrem Kürzel daneben. Die Kürzel
gelten nur, solange die Trefferliste den Fokus hat: Im Suchfeld löscht ⌫
weiterhin ein Zeichen und ⌘⌫ bis zum Zeilenanfang. Der Selbsttest der App legt
dafür eine echte Datei in den Papierkorb, prüft sie dort und räumt sie wieder
weg.

## 0.24.3 — 2026-08-21

Aus der Code-Review vom 2026-08-21:

- Ein Abbruchsignal während der Installation wird nicht mehr verworfen. Die
  kurzen kritischen Abschnitte (Sperrerwerb, Anlegen von Ablage- und
  Sicherungsordner) schoben `HUP`, `INT` und `TERM` bisher mit `trap ''`
  beiseite — die Installation lief danach trotz Abbruchwunsch weiter und
  konnte beide Apps ersetzen. Jetzt merkt sich ein Handler das Signal, und
  sobald der Besitz von Sperre und Ordnern feststeht, läuft der passende
  Abbruch mit Exit 2 und unverändertem Altstand. Die drei `trap`-Zeilen stehen
  bewusst ausgeschrieben statt in einer Hilfsfunktion: Unter `localtraps` gilt
  ein in einer Funktion gesetzter Trap nur bis zu deren Rückkehr, das Signal
  ging so komplett verloren (an zsh nachgemessen).
- „Öffnen mit" bietet nur noch Anwendungen an, die JEDEN öffnenbaren Treffer
  der Auswahl öffnen können. Das Untermenü richtete sich nach dem ersten
  Treffer, während der Klick anschließend sämtliche Dateien derselben
  Mehrfachauswahl an diese eine Anwendung übergab. Ist die Schnittmenge leer,
  erklärt der Eintrag das und bleibt grau.
- Die Meldung über ausgelassene Treffer nennt beide Gründe. Stand ein
  Archivordner in der Auswahl, blieb ein echter Auspackfehler eines weiteren
  Treffers unsichtbar; jetzt zählt die Meldung beide Gruppen und nennt den
  ersten betroffenen Pfad.
- Zwei doppelte Schreibpfade entfernt: `populateHitContextMenu` leert das Menü
  nicht mehr selbst (das tun die Controller ohnehin unmittelbar davor), und
  `controlTextDidChange` schreibt die Infozeile im Leerfall nicht ein zweites
  Mal — `clearHits()` hat sie bereits gesetzt.

## 0.24.2 — 2026-08-20

Aus der zweiten Code-Review vom 2026-08-20:

- Dateiaktionen in einer Mehrfachauswahl beziehen sich jetzt alle auf dieselben
  Treffer. Ein Rechtsklick auf einen Ordner im Archiv legt nicht mehr das ganze
  Menü lahm, wenn daneben öffenbare Dateien ausgewählt sind; umgekehrt melden
  „Öffnen mit" und „Im Finder zeigen" ausgelassene Ordner statt sie
  kommentarlos zu überspringen.
- Die Schnellsuche löscht beim ersten neuen Tastendruck auch die alte Infozeile,
  einen alten Suchbereichshinweis und eine offene Quick-Look-Vorschau. ⌘↩
  übergibt die neue Anfrage jetzt auch vor dem ersten Treffer sofort an die
  Haupt-App, die die Suche dort vollständig fortsetzt.
- Kontextmenü und Vorschau benutzen in beiden Apps dieselbe gemeinsame
  Zeilen- und Materialisierungslogik. Die Selbsttests prüfen die grauen
  Menüeinträge an einem echten `NSMenu`, statt sich auf Quelltext-Kommentare
  und Einrückung zu verlassen.
- Abbruchsignale während der Installation können weder eigene versteckte
  Zwischenordner noch eine fremde Installationssperre hinterlassen. Bleibt ein
  Ablageordner wider Erwarten stehen, nennt die Warnung jetzt seinen Pfad.
- Die JSONL-Dokumentation nennt auch normale Dateien, deren Größe sich nicht
  ermitteln lässt: Der Treffer bleibt erhalten, aber das optionale Feld `size`
  fehlt beispielsweise bei einem toten Symlink.

## 0.24.1 — 2026-08-20

Aus der Code-Review vom 2026-08-20:

- Die Schnellsuche wirft die alten Treffer jetzt sofort weg, sobald sich der
  Suchtext ändert. Zwischen Tastendruck und dem Start der neuen Suche liegen
  0,6 Sekunden; in diesem Fenster übergab ⌘↩ oder der Knopf „Alle in Favenio"
  der Haupt-App die Treffer der VORIGEN Anfrage unter dem bereits neuen
  Suchtext — und deren Pfade unterdrückten dort anschließend richtige Treffer.
- Für einen **Ordner innerhalb eines Archivs** ist jetzt auch „Öffnen mit"
  ausgegraut. Trägt der Ordnername eine Endung wie `daten.txt`, bot das
  Untermenü bisher passende Apps an, die auf Klick kommentarlos nichts taten.
  Beim Nachsehen in der laufenden App stand der Eintrag zunächst weiter schwarz
  zwischen drei grauen Dateiaktionen: AppKit hält ein Obermenü mit Untermenü
  aktiv, auch wenn darin nur ein deaktivierter Hinweis steht. Das Untermenü
  wird deshalb nur noch angehängt, wenn es wirklich etwas zu öffnen gibt.
- Die Leertaste öffnet die Vorschau nur noch, wenn es wirklich eine Datei zu
  zeigen gibt. Im Kontextmenü war die Vorschau für einen Ordner im Archiv
  schon ausgegraut, über die Tastatur ging trotzdem ein leeres
  Quick-Look-Fenster auf; stattdessen erscheint jetzt derselbe Hinweis.
- `install.sh` legt Ablage- und Sicherungsordner einzeln an. Trug einer der
  beiden Pfade denselben Namen wie ein liegen gebliebener Ordner eines anderen
  Laufs, entstand der jeweils andere trotzdem — und das Aufräumen löschte
  danach den FREMDEN Ordner samt nicht zurückgeholtem alten Stand, obwohl der
  Lauf mit Exit 2 „nichts geändert" zusagt.
- Ein Abbruch (Ctrl-C, HUP, TERM) unmittelbar nach dem Sperren des Zielordners
  nimmt die Sperre jetzt wieder ab. Vorher blieb sie liegen, und jede weitere
  Installation meldete „es läuft bereits eine Favenio-Installation".
- Dokumentation: `size` im JSONL ist ein optionales Feld. Es steht nur dort,
  wo das Format die entpackte Größe vorab nennt — nicht bei einzeln
  komprimierten Dateien (`.gz`, `.bz2`, `.xz`) und nicht bei Einträgen, die
  über `bsdtar` gelesen werden (7z, ISO, `.tar.zst`). Beide READMEs
  versprachen es bisher für jede Datei.

## 0.24.0 — 2026-08-19

- **Verhaltensänderung:** Die Regel aus 0.23.0 gilt jetzt auch INNERHALB von
  Archiven. Ein Archiv im Archiv, das die verbleibende `--archive-depth` nicht
  mehr öffnet, zählt als ganz normaler Eintrag, und `--content` durchsucht
  seine Rohbytes. Bisher entschied hier weiter der Grund über das Ergebnis:
  Ein `.7z`-Eintrag ohne `bsdtar` wurde durchsucht, ein `.zip`-Eintrag an der
  Tiefengrenze dagegen kommentarlos übersprungen. Gefunden in der
  CodeQA-Kampagne vom 2026-08-19.

## 0.23.0 — 2026-08-19

- **Verhaltensänderung:** `--no-archives` und `--archive-depth 0` heißen jetzt
  „nicht hineinschauen" statt „auslassen". Ein Archiv zählt dann als ganz
  normale Datei, `--content` durchsucht also seine Rohbytes — genau wie bei
  einer `.7z` ohne `bsdtar`. Vorher wurde eine Archivdatei bei `--content`
  kommentarlos übersprungen, wenn das Hineinschauen verboten war, aber
  durchsucht, wenn nur das Werkzeug fehlte. Der Grund darf das Ergebnis nicht
  ändern, sonst hängt es vom Zufall der installierten Werkzeuge ab, ob eine
  Datei überhaupt angefasst wird. Praktisch entsteht ein Treffer auf dem
  Behälter nur, wenn der Text wirklich roh darin steht (unkomprimiert
  abgelegte Einträge; `.xz` legt sehr kurze Eingaben ebenfalls fast
  unverändert ab).

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
- Die Infozeile der Schnellsuche behält keinen veralteten Tooltip mehr. Farbe
  und Umbruch wurden zurückgesetzt, der Tooltip nicht — die Erklärung einer
  längst erledigten Bereichswarnung hing dadurch weiter an einer harmlosen
  Zeile wie „12 Treffer — Suche läuft…". Alle vier Eigenschaften setzt jetzt
  eine einzige Stelle.
- Für einen **Ordner innerhalb eines Archivs** graut das Kontextmenü beider
  Apps jetzt Vorschau, Öffnen und „Im Finder zeigen" aus und nennt den Grund.
  Hinter einem solchen Treffer steht keine Datei; seit dem Fix vom 2026-08-17
  wird dafür bewusst nichts mehr ausgepackt — die Menüeinträge sahen aber
  weiterhin bedienbar aus und taten auf Klick kommentarlos nichts.
  „Pfad kopieren" bleibt nutzbar.

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
