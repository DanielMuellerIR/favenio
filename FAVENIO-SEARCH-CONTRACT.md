# Favenio-Suchvertrag

## Kern und Suchvertrag

`favenio.py` nutzt nur die Python-Standardbibliothek. Neue Pflichtabhängigkeiten
brauchen eine ausdrückliche Architekturentscheidung; ein optionales externes
Werkzeug muss sauber erkannt werden und darf den bisherigen Kern nicht brechen.

`Search` kapselt Muster, Optionen und Trefferausgabe. `visit_member()` ist der
gemeinsame Pfad für Zip- und Tar-Einträge. Archive werden derzeit anhand der
Dateiendung erkannt. Neben klassischen Archiven gehören auch ZIP-basierte
Dokumentformate wie JAR, WHL, EPUB, DOCX, XLSX, PPTX, ODT, ODS, ODP
sowie die iWork-Formate PAGES, NUMBERS und KEY dazu.

Verbindliches CLI-Verhalten:

- `--criteria-json` / `--criteria-file` nehmen den versionierten Baum aus
  `docs/CRITERIA.md` an. Schema, Grenzen, Dreiwertlogik, Wurzelbezug und
  `criteriaEvidence` gelten gleichermaßen für Dateien und Archivmitglieder.
  Die Auswertung bleibt im Python-Kern; Frontends erzeugen/transportieren
  nur den Baum. Bestehende Suchbegriffe und Filter gelten zusätzlich per UND.
- `--json` schreibt JSONL, ein Objekt pro Treffer. Jeder Treffer trägt
  `path`, `type`, `isDirectory`, `filesystemPath` und `archiveMembers`;
  Archivtreffer zusätzlich `archiveMemberBytes` mit der Base64-Identität jeder
  Archivstufe; sie bleibt bei nicht als UTF-8 lesbaren Namensbytes eindeutig,
  während `path` und `archiveMembers` U+FFFD anzeigen;
  Inhaltstreffer zusätzlich `line`, Metadatentreffer `field` und `value`,
  Treffer eines Laufs mit Maßfilter `width` und `height`. `size` ist
  optional: Es steht nur dort,
  wo das Format die entpackte Größe vorab nennt (normale Dateien, Zip- und
  Tar-Einträge), nicht bei einzeln komprimierten Dateien (`.gz`, `.bz2`,
  `.xz`) und nicht bei `bsdtar`-Einträgen (7z, ISO, `.tar.zst`). Dort wäre
  die Größe erst nach vollständigem Entpacken bekannt; das hebt den
  Early-Exit auf und ist für ein bloßes Anzeigefeld abgelehnt. Das Feld fehlt
  auch, wenn sich die Größe einer normalen Datei nicht ermitteln lässt (zum
  Beispiel bei einem toten Symlink). `modified` und `created` (Unix-Zeit,
  Gleitkomma) sind ebenso optional: Dateien und Ordner tragen beide aus
  derselben `stat`-Abfrage (`file_facts()`), Zip- und Tar-Einträge nur
  `modified` aus dem Katalog (`zip_member_mtime()` deutet die zonenlose
  Zip-Ortszeit wie der Finder), bsdtar-Einträge und einzeln komprimierte
  Dateien keines. `isDirectory`
  ist nötig, weil `type` es nicht verrät: Ein Ordner IM Archiv kommt wie eine
  Datei als `member` an. Die Frontends dürfen den Typ nicht aus dem Pfad oder
  aus `type` erraten. `parseHit()` verwirft eine Zeile ohne das Feld
  deshalb, statt zu raten; beide Erzeuger — `emit()` im Kern und
  `jsonlData()` in Swift — schreiben es immer.
- `--progress` erzeugt gedrosselte Fortschrittsobjekte. Im JSON-Modus stehen sie
  im selben stdout-Strom und sind über `type: progress` erkennbar. Ohne JSON
  gehen Fortschritte nach stderr.
- `--json --content-preview` erfasst begrenzte erste Inhaltsbelege aus demselben
  Leser, ohne zusätzliches Nachlesen. Schema, Quellbindung, Ausschnittbereiche
  und Grenzen stehen in `docs/CONTENT_PREVIEW.md`; die Apps bauen keine eigene
  Such- oder Hervorhebungslogik. Ohne Option bleibt die Erfassung aus.
- Warnungen und Diagnose gehören nach stderr; stdout bleibt parsebar.
- `FavenioArgumentParser.error()` gibt auch Validierungsfehler mit
  `favenio: fehler: ` und Exit 2 aus. Das Präfix gehört zum Vertrag mit
  `SearchDiagnostics`; normales argparse-`error:` verliert den konkreten
  Grund in beiden Apps.
- Exit-Codes folgen grep: 0 = Treffer, 1 = keine Treffer, 2 = Fehler.
  Zu den Fehlern gehört ausdrücklich JEDER unerwartete Abbruch: `main()`
  fängt ihn ab, nennt ihn auf stderr und endet mit 2. Ohne das beendete
  sich Python mit Status 1 — genau dem Status für „keine Treffer" —, und
  beide Apps zeigten eine halbe Trefferliste als vollständiges Ergebnis.
  Erwartete Lesefehler EINZELNER Objekte bleiben davon unberührt; sie sind
  weiter eine Warnung, und die Suche läuft weiter.
  Ein geschlossener Leser (`| head -1`, auch `2>&1 | head -1`) ist kein
  Fehler: `write_output()` macht aus `BrokenPipeError` ein `OutputClosed` —
  bewusst kein OSError, sonst schluckt es `search_archive()` als
  Archiv-Warnung —, und `main()` endet still mit 0 bzw. 1 wie grep statt mit
  Traceback und Status 120. Das gilt auch für stderr (`warn()`,
  Text-Fortschritt gehen durch `write_output()`); `discard_closed_output()`
  biegt danach BEIDE Ströme auf /dev/null, sonst scheitert ein Restpuffer
  beim Interpreter-Ende. `--extract` und `--list-metadata-fields` schreiben
  über `write_result()` und enden dabei mit 0.
- `main()` stellt stdout auf UTF-8 mit `surrogateescape` und stderr auf
  UTF-8 mit `backslashreplace` (`use_locale_independent_streams()`), also
  wie ohne Locale unter launchd. JSONL ersetzt nicht als UTF-8 lesbare
  Tar-Namensbytes im sichtbaren Namen durch U+FFFD und trägt ihre exakte
  Base64-Identität parallel in `archiveMemberBytes`; so können zwei
  verschiedene kaputte Namen weder kollidieren noch beim Auspacken vertauscht
  werden. Bis 0.34.22 brach derselbe Name unter `LANG=de_DE.UTF-8` den ganzen
  Lauf mit Exit 2 ab.
- Namens-Glob-Muster matchen den vollständigen Namen. Inhalt und Metadaten
  verwenden `*` für mindestens ein Zeichen innerhalb derselben Zeile, mit
  beliebigem Text davor/danach; andere Zeichen sind dort wörtlich.
  `--literal-wildcards` unterdrückt Platzhalter in beiden Modi, nicht Regex
  oder Ausschlüsse. `--exact` verlangt weiterhin das ganze Ziel.
- `--exclude` ist wiederholbar und arbeitet unabhängig vom Suchmatcher über
  `Exclusions` mit `fnmatchcase`: ohne `/` je ganze Pfadkomponente, mit `/`
  gegen den ganzen relativen Pfad und dessen Eltern. `*` darf `/` überqueren.
  Jede Start- und Archivwurzel wird unabhängig geprüft; ein expliziter
  Startordner bleibt die Wurzel, eine Startdatei zählt mit ihrem Dateinamen.
  Archiv-Eltern werden auch ohne eigene Katalogeinträge geprüft. Dabei den
  echten `member_path` verwenden, niemals `display` an `!/` zerlegen.
  Muster werden wie die Pfade normalisiert (`Exclusions.normalize_pattern()`,
  seit 0.34.1): `build/` und `./cache` gelten; ob Pfad- oder
  Komponentenmuster, entscheidet das rohe Muster. Absolute Muster lehnt
  `main()` mit Exit 2 ab — sie träfen nie.
  `search_path()` entfernt ausgeschlossene Ordner vor dem Abstieg aus
  `dirnames`; `visit_file()` und `visit_member()` prüfen vor jedem Öffnen,
  auch vor dem Rückfall auf rohe Archivbytes. Kein Standardausschluss.
- `--local-only` setzt vor Auftrags-/Pfadzugriffen die macOS-Prozesssperre gegen
  dataless-Materialisierung; Helfer erben sie. Statusprüfungen allein ersetzen
  die Sperre nicht. Namen/bekannte Fakten bleiben suchbar, nicht lokale oder
  unbekannte Inhalte erfüllen auch Negation nicht. Explizite Dateiaktionen
  bleiben getrennt. Vorschau-Nachladen übernimmt die Politik; automatische
  Swift-Generationsprüfungen dürfen keine Materialisierung auslösen. Grenzen,
  Providerunterstützung und Transportgates stehen in `docs/LOCAL_CONTENT.md`.
- Inhalt wird standardmäßig als UTF-8 mit `errors="replace"` gelesen. `--encoding`
  wählt aus einer begrenzten Positivliste; BOM-Automatik ist ausdrücklich zu wählen.
  Der gemeinsame inkrementelle Decoder versorgt Vortest, Inhaltskriterien und
  Positionsprüfung. Suchaufträge bewahren die Wahl; `contentEncoding` nennt den
  tatsächlich gelesenen Decoder ohne zusätzliche Dateiöffnung. Ungültige
  Zeichenfolgen können positive Treffer liefern, aber keine Abwesenheit beweisen.
  Originalbytes und Zeilentrenner bleiben erhalten; exakte Positionsbelege
  erfordern fehlerfreie Dekodierung und getrennte Byte-/Texthashes.
- Normale Matcher und Ausschlüsse vergleichen in NFC; Regex arbeitet auf den
  ursprünglichen Codepoints. Quellen und Belege werden nicht normalisiert.
  `ContentProbe` und `iter_matching_pieces()` halten über Häppchengrenzen den
  letzten noch komponierbaren Starter samt Kombinationszeichen zurück. Ein
  übergroßer Rest bleibt unbekannt; der Vortest antwortet dann konservativ Ja.
  Regex und kanonische Matcher können denselben Rohzeilenleser verwenden.
- Gelesen wird nur, was nachweislich eine reguläre Datei ist
  (`open_regular_file()`, `O_NONBLOCK` plus `fstat`). Ein gewöhnliches
  `open()` auf eine benannte Pipe ohne Schreiber wartet unbegrenzt: Bis
  0.26.1 standen `--content` und jeder Maßfilter dabei still — kein Fehler,
  kein Ergebnis, kein Abbruch. Alles andere wird gemeldet und übersprungen.
  Die Namenssuche ist davon unberührt, sie öffnet die Datei gar nicht, und
  eine Pipe bleibt dort ein normaler Treffer.
- Das Lesen der Inhaltssuche — UTF-8-Dekodierung, Zeilentrennung,
  Überlappung, Längengrenze — steht seit 0.32.1 EINMAL im Generator
  `iter_line_pieces()`; `match_content()` entscheidet nur noch je
  `LinePiece`, was mit ihm passiert. Jedes Stück trägt Zeilennummer,
  `complete` (ganze Zeile oder Bruchstück — auch das LETZTE Stück einer zu
  langen Zeile ist keine ganze Zeile) und `ends_line`. Die Abnahme des
  Refactors ist `tests/test_line_reader.py`: eine wörtliche Kopie der alten
  `match_content()` läuft dort gegen die neue, Eingabe für Eingabe (LF,
  CRLF über Häppchengrenzen, einzelnes CR, alle Trenner, UTF-8-Grenzen,
  Ersatzzeichen, letzte Zeile ohne Umbruch, überlange Zeilen, Treffer in
  der Überlappung, 300 Zufallseingaben) — gleiche Treffer, Zeilennummern,
  Warnungen und gleiches frühes Leseende. Messung in
  `tests/LINE_READER_MEASUREMENTS.md`.
- Eine Zeile ohne Umbruch wird abschnittsweise geprüft
  (`MAX_LINE_CHARS`, `LINE_OVERLAP_CHARS`). Minifiziertes JSON oder eine
  mysqldump-Zeile pufferte `match_content()` sonst vollständig: gemessen am
  2026-09-03 auf 144 MB Text 488 MB gegen 18 MB bei derselben Datenmenge MIT
  Umbrüchen. Die Überlappung ist Pflicht, nicht Vorsicht — ohne sie geht ein
  Treffer an der Schnittstelle verloren; sie muss länger sein als jedes
  realistische Suchmuster. Und sie darf nicht 0 werden: `segment[-0:]` ist in
  Python der GANZE String, die Grenze verschwände lautlos.
  Auf einem BRUCHSTÜCK geprüft werden darf aber nur der reine
  „enthält"-Test — `build_matcher()` markiert ihn mit `substring_only`.
  Verankerte Muster (`--regex` mit `^`/`$`), Glob-Muster und `--exact`
  gelten für die ganze Zeile: `--regex 'A$'` traf am Abschnitts- statt am
  Zeilenende und meldete einen Treffer, den `grep` nicht sieht. Für sie
  bleibt eine zu lange Zeile ungeprüft und wird als Warnung genannt —
  lieber gemeldet als still falsch beantwortet.
  Ein einzelnes `\r` im Puffer beendet beim Abschnittswechsel wirklich eine
  Zeile: Das aktuelle Häppchen hat keinen Umbruch, ein CRLF kann daraus also
  nicht mehr werden. Ohne diesen Schritt war jede folgende Zeilennummer um
  eins zu klein.
- Der Wurzeleintrag `./` eines so gebauten Archivs ist das Archiv selbst und
  wird übersprungen (`visit_member()`): Als Ordnertreffer mit dem Namen `.`
  konnte `--extract` ihn nicht auflösen und endete mit einem nackten
  `KeyError`.
- Nur Punktnamen sind versteckt, nicht die Verzeichnisnamen `.` und `..`.
  `tar -cf x.tar -C ordner .` — der übliche Weg, einen Ordnerinhalt zu tarren —
  legt jeden Eintrag als `./name` ab; bis 0.26.1 fiel damit das ganze Archiv
  ohne Meldung aus jeder Suche.
- Die Inhaltssuche ist zweistufig: `ContentProbe` prüft billig, ob der Suchtext
  überhaupt vorkommt, `match_content` bestimmt danach die Zeilennummer. Der
  Vortest darf nie einen Treffer verschlucken — er entscheidet nur „sicher
  nicht" gegen „nachsehen" — und ist nur bei festem Suchtext möglich, also nicht
  bei `--regex` und nicht bei Glob-Mustern. Ein Umbau muss Trefferliste und
  Zeilennummern unverändert lassen; die Tests vergleichen deshalb beide Wege
  direkt gegeneinander.
- Ein Treffer sagt nichts über die Unversehrtheit eines Archivs: Weil das Lesen
  beim ersten Treffer endet und Python die CRC eines ZIP-Eintrags erst am
  Eintragsende prüft, wird sie bewusst nicht geprüft. Vollständiges Durchlesen
  nur zum Prüfen der Prüfsumme hebt den Early-Exit auf und ist entschieden
  abgelehnt.
- Wird nicht in ein Archiv geschaut — durch `--no-archives`, durch
  `--archive-depth 0` oder weil das nötige externe Werkzeug fehlt —, ist die
  Datei eine ganz normale Datei und `--content` durchsucht ihre Rohbytes. Alle
  drei Gründe müssen dasselbe Ergebnis liefern; sonst entscheidet der Zufall
  der installierten Werkzeuge darüber, ob eine Datei überhaupt angefasst wird.
  Das gilt auf jeder Ebene: Auch ein Archiv IM Archiv, das die aufgebrauchte
  `--archive-depth` nicht mehr öffnet, ist ein ganz normaler Eintrag.
  Ein VIERTER Grund kam mit 0.27.1 dazu: Die Endung ist ein Hinweis, keine
  Zusage. Lässt sich die Datei nicht als das Format öffnen, das ihre Endung
  verspricht, ist sie ebenfalls eine ganz
  normale Datei — ohne Warnung, denn `.key` ist weit häufiger ein
  TLS-Schlüssel als eine Keynote-Datei. `visit_file()` und `visit_member()`
  müssen auch diesen Rückfall gleich behandeln; bis 0.27.0 fiel ein
  `server.key` in einem Zip ab `--archive-depth 2` lautlos aus der Suche,
  während er bei Tiefe 1 gefunden wurde.
  Dieser Rückfall gilt aber NUR ohne Archiv-Signatur (`ARCHIVE_SIGNATURES`,
  geprüft von `announces_archive_format()`; `archive_head()` liest je Format
  nur so viel Anfang, wie dessen Signatur braucht — vier Bytes für ein Zip,
  36 KB für ein ISO). Denn der Öffnungsfehler sagt nicht,
  WARUM sich die Datei nicht öffnen ließ — derselbe Fehler kommt beim
  Klartext mit der Endung `.zip` wie beim echten, aber abgeschnittenen Zip.
  Trägt die Datei die Signatur, ist sie ein BESCHÄDIGTES Archiv: Warnung
  und überspringen (seit 0.28.3). Sie stattdessen als Rohbytes zu
  durchsuchen lieferte Unsinn — ein unkomprimiert abgelegter Eintrag eines
  abgeschnittenen Zips kam als ganz gewöhnlicher DATEItreffer heraus, nicht
  von einem Klartext mit `.zip`-Endung zu unterscheiden, und dass das
  Archiv kaputt ist, erfuhr niemand. Ein sehr altes v7-Tar ohne „ustar"
  kündigt sich nicht an und bleibt beim stillen Rückfall.
  Für die Tar-Familie gilt eine Zusatzregel (`tar_envelope_kind()`, seit
  0.34.14): `ARCHIVE_SIGNATURES["tar"]` zählt gzip, bzip2 und xz mit, weil
  `tarfile` mit „r:*" die Kompression selbst erkennt — diese Bytes kündigen
  aber nur die HÜLLE an, kein Tar. Scheitert das Öffnen und heißt die Datei
  auf genau die Hüllen-Endung (`.tar.gz`, `.tar.bz2`, `.tar.xz`, seit
  2026-09-17 auch `.tar.zst`), wird sie als EINZELKOMPRESSION gelesen:
  `gzip -c notiz.txt > notiz.tar.gz` ist ein gültiges gzip ohne Tar darin
  und fiel bis 0.34.13 mit „beschädigtes
  Archiv" aus der Suche, während dieselben Bytes als `rein.gz` gefunden
  wurden. Bei `.tar.zst` entscheidet statt `tarfile.open` die
  gescheiterte `bsdtar -tf`-Auflistung (nicht die zu lange) — in
  `walk_bsdtar()` und, mit eigener Auflistung, in `extract_result()`.
  `.tgz`, `.tbz2`, `.txz` und `.tzst` bleiben bei der Warnung, weil
  `single_member_name()` die Endung abschneidet und `notiz.tgz` mit „.gz"
  den Eintrag `notiz.t` ergäbe. Scheitert auch das Entpacken, greift wieder
  die Warnung. `search_archive()` UND `extract_result()` wenden dieselbe
  Regel an — sonst wäre ein gefundener Treffer nicht auszupacken.
  Der Rückfall gilt seit 0.34.11 für JEDES Format, nicht mehr nur für Zip
  und Tar: Bis dahin kannten ihn allein `FORMAT_MISMATCH_ERRORS`
  (`BadZipFile`, `ReadError`). Eine Textdatei namens `notes.7z`,
  `image.iso` oder `blob.zst` fiel deshalb mit Warnung aus der Suche,
  während dieselbe Datei ohne installiertes `bsdtar`/`zstd` ganz normal
  durchsucht wurde — genau der Zufall, den dieser Absatz ausschließt.
  Der Schlüssel der Signaturliste ist deshalb das FORMAT, nicht die
  Öffner-Art: Hinter `kind == "bsdtar"` stecken 7z, ISO und tar.zst mit
  drei verschiedenen Signaturen, `archive_signature_key()` löst das an der
  Endung auf. Bei der Einzelkompression (`SINGLE_COMPRESSION_KINDS`)
  entscheidet die Signatur schon VOR dem Abstieg, denn `walk_single()`
  baut seinen einen Eintrag allein aus dem Dateinamen und öffnet die Datei
  bei einer reinen Namenssuche gar nicht: Eine Textdatei `notiz.gz` lieferte
  sonst den Phantom-Treffer `notiz.gz!/notiz`, den `--extract` nie auflösen
  kann. Und der Rückfall ist ausgeschlossen, sobald aus dem Archiv schon
  ein Treffer gemeldet wurde (`Search.emitted`) — sonst käme dieselbe Datei
  ein zweites Mal, jetzt als Dateitreffer.
  In ein Archiv wird außerdem nur geschaut, wenn der Pfad eine reguläre
  Datei ist: `zipfile` und `tarfile` öffnen ihn selbst, also an
  `open_regular_file()` vorbei — eine benannte Pipe namens `x.zip` ließ
  sonst sogar die reine Namenssuche unbegrenzt hängen.
  `visit_file()` und `visit_member()` müssen diesen Fall gleich behandeln —
  vor 0.24.0 wurde ein `.7z`-Eintrag ohne `bsdtar` durchsucht, ein
  `.zip`-Eintrag an der Tiefengrenze dagegen übersprungen.
- Die Suche ist eine **Kriterienliste**, die alle zutreffen müssen
  (`Search.criteria`, ausgewertet in `evaluate()`): höchstens ein
  Textkriterium — `NameCriterion`, `ContentCriterion` oder
  `MetadataCriterion`, je nach `--content`/`--metadata` — plus
  `DimensionCriterion`, sobald einer der vier Maßfilter gesetzt ist, sowie
  `FileFactsCriterion` für Größen-/Datumsgrenzen. Ohne
  Muster (`matcher is None`, `text_mode is None`) entfällt das Textkriterium
  ganz; ein synthetisches `*` gab es bis 0.26.0 und war unter `--regex` ein
  ungültiger Ausdruck. Sortiert nach `cost` (Name 0, Dateifakten 0.5,
  Maße 1, Metadaten 2, Inhalt 3), Abbruch beim ersten Nein. Diese Reihenfolge ist ein
  Leistungsversprechen — aber nur für die Formate, deren Maße der eingebaute
  Kopf-Leser liefert: Dort sieht exiftool ausschließlich Dateien, die den
  Maßfilter schon bestanden haben. Für die Endungen aus
  `EXIFTOOL_DIMENSION_EXTENSIONS` (HEIC, AVIF, RAW, Video) gilt es nicht und
  kann es nicht gelten, denn dort kommen die Maße selbst von exiftool; es
  wird also schon im Maßkriterium gefragt. Zwei Tests halten beide Hälften
  fest — der ältere prüfte nur PNGs und hätte die zweite nie bemerkt. `FileProbe` beantwortet die
  teuren Fragen (Maße, Metadaten, Inhaltszeile) je Datei genau einmal. Ein
  zusätzlicher `CriteriaQuery` enthält den strukturierten UND-/ODER-Baum.
  `Search.evaluate()` prüft ihn gemeinsam mit den bisherigen Filtern in
  Kostenphasen. `Condition` hält bekannte Ergebnisse und begrenzte Belege je
  `FileProbe` fest; `CriteriaGroup` behält entscheidende Zweige. Unbekannte
  Werte werden auch durch Negation nicht wahr. `CriteriaContentScan` teilt
  einen fortsetzbaren Leser zwischen allen Inhaltsblättern und bisherigen
  Inhaltsbegriffen, einschließlich früher ODER-Entscheidung. Negative
  Inhaltsbedingungen beweisen Abwesenheit nur nach vollständigem Lesen;
  ungeprüfte überlange verankerte Zeilen und Lesefehler bleiben unbekannt.
  Metadatenfelder verwenden dieselbe Positivliste wie `--metadata-field`.
  Schema und Grenzen stehen in `docs/CRITERIA.md`; keine Suchsemantik in Swift.
- **Mehrwortsuche** (`--term`, wiederholbar, seit 0.34.0): PATTERN und jeder
  `--term` sind Begriffe, die ALLE im selben Objekt zutreffen müssen —
  gleiche Regeln (`build_matcher` je Begriff) und dasselbe Ziel. Vertrag,
  entschieden 2026-09-06: UND über das GANZE Objekt, nicht dieselbe Zeile
  bzw. derselbe Metadatenwert. Favenio prüft Regex-Muster zeilenweise;
  ein Lookahead kann deshalb nur UND innerhalb einer Zeile ausdrücken. `Search.matchers` hält alle Begriffe;
  `NameCriterion`, `MetadataCriterion` und `FileProbe.content_lines()` prüfen
  alle, `match_content_all()` in EINEM Durchlauf (bei einem Begriff der
  schlanke Weg `match_content()`), `ContentProbe` nimmt eine Liste fester
  Begriffe und liest den Inhalt nicht je Begriff neu. Belege in `emit()`:
  `terms` je Begriff (`line` bzw. `field`/`value`), während
  `line`/`field`/`value` weiter den ERSTEN Begriff nennen; Text `pfad:1,3`
  bzw. `pfad:Feld: Wert | Feld: Wert`. Doppelte Begriffe zählen einmal, ein
  leerer ist Exit 2, ohne PATTERN wird der erste `--term` zum Muster, und
  die Pfadbeförderung der Positionsargumente gilt auch mit `--term`.
  Gemischte Ziele je Begriff und ODER sind ein eigener Auftrag.
- `--min-size`/`--max-size` sind inklusive Grenzen in ganzen nichtnegativen
  Bytes, optional B/KiB/MiB/GiB/TiB. `--modified-from`/`--modified-to` und
  `--created-from`/`--created-to` sind inklusive ISO-Zeitpunkte mit
  ausdrücklichem Z/Offset, nie implizite lokale Kalendertage. Eine
  Obergrenze ohne Sekundenbruchteile schließt die ganze genannte Sekunde
  ein (ohne Sekunden die Minute; `file_timestamp_end()`) — Dateisysteme
  führen Bruchteile, der Nutzer nennt sie nicht. Unbekannte
  oder ungültige angefragte Fakten erfüllen den Filter nicht; dazu gehören
  NaN/inf aus PAX-Zeitfeldern. `FileProbe.facts()` hält Größe und beide
  Zeitpunkte für Kriterien UND Ausgabe aus derselben Abfrage fest. Ordner
  haben keine Dateigröße, Archiv-Einträge keine Erstellungszeit. Archive
  werden nicht allein zur Größenbestimmung entpackt. Ein abgelehnter
  Container-Treffer darf seinen Archivabstieg nicht unterbinden: Einträge
  haben eigene Fakten.
- Ordner können Namen und bekannte Zeitpunkte erfüllen, aber weder Größen-
  noch Maß-/Inhalts-/Metadatenfilter. Dateieinträge in Archiven können Namen, Inhalte,
  Maße und bekannte Fakten erfüllen. Sie haben keine Datei, die exiftool
  lesen könnte. Bei `--metadata` wird deshalb gar nicht erst in Archive
  geschaut; Maßfilter gelten dagegen auch für Archiv-Einträge, weil der
  Maß-Leser (`image_dimensions()`) nur einen vorwärts lesbaren Strom
  braucht — kein `seek()`, denn bsdtar liefert eine Pipe.
- Pixelmaße kommen aus dem eigenen Kopf-Leser (JPEG, PNG, GIF, BMP, WebP,
  TIFF; 0,198 ms je Datei, am 2026-09-02 über 30 370 reale Bilder ohne
  Abweichung gegen exiftool geprüft). exiftool ist nur der Rückfall für die
  Endungen in `EXIFTOOL_DIMENSION_EXTENSIONS` (HEIC, AVIF, RAW, Video).
  Ein Bild ohne lesbare Maße erfüllt einen Maßfilter nie; das gilt auch für
  unplausible Kopfmaße (0 oder über `MAX_IMAGE_EDGE` = 2^31-1 je Kante).
  Der Kopf-Leser eines Archiv-Eintrags läuft über denselben budgetierten
  Chunker wie die Inhaltssuche und hält damit dieselben Entpackgrenzen ein;
  `FileProbe.dimension_bytes` sagt, welchen Anfang ein folgender
  Inhaltsdurchlauf dem Gesamtbudget nicht noch einmal belasten darf.
- `--metadata` liest über exiftool die Felder aus `METADATA_TEXT_FIELDS` —
  EINE kuratierte Konstante, bewusst leicht änderbar; die Oberflächen holen
  sie per `--list-metadata-fields` und bauen sie nicht nach. exiftool läuft
  als EIN Prozess je Suchlauf (`ExifToolStream`, `-stay_open True`, Pfade
  über stdin, `-use MWG`), gestartet beim ersten Bedarf und in `close()`
  beendet; ein Prozess je Datei kostete 44 ms statt 0,75 ms und ist
  abgelehnt. Die Argumentdatei ist zeilenweise, und exiftool deutet den
  Zeilenanfang: `-` beginnt eine Option, `#` einen Kommentar, Leerraum am
  Zeilenrand wird abgeschnitten. Deshalb bekommt JEDER relative Pfad ein
  `./` davor, und ein Pfad mit Zeilenumbruch oder Leerraum am Ende geht über
  `read_once()` durch EINEN eigenen Prozess, statt still zu verschwinden.
  Aus demselben Grund nimmt `metadata_tag()` für `--metadata-field` nur
  Werte aus `METADATA_TEXT_FIELDS` — eine POSITIVLISTE, keine Zeichenregel.
  Eine Zeichenregel reicht nachweislich nicht: Sie ließ `execute`,
  `charset`, `p`, `b`, `w`, `if`, `ver` und `TagsFromFile` durch, allesamt
  echte exiftool-Optionen; schon `--metadata-field execute` zerlegte jede
  Anfrage in zwei Kommandos und lieferte für JEDE Datei „keine Treffer".
  Ein Zeilenumbruch im Wert schöbe darüber hinaus beliebige weitere
  Optionen ein — über `-p` mit einem Perl-Ausdruck bis hin zum
  Shell-Aufruf. Die Liste ist ohnehin der Vertrag: `--list-metadata-fields`
  gibt genau sie aus, und beide Oberflächen bauen ihr Feldmenü daraus. Bricht der Prozess mitten im Lauf weg, ist das eine
  Warnung; vorher lieferte er für jede weitere Datei stillschweigend nichts,
  und der Lauf endete als „keine Treffer". Nur Endungen aus `METADATA_EXTENSIONS` gehen an exiftool. Ohne
  exiftool endet `--metadata` mit Exit 2 und einem Satz, der sagt, was
  fehlt; die Maßfilter laufen ohne. Dieselbe Bauart wie `bsdtar` und `zstd`:
  optional, sauber erkannt, kein Pflichtpaket.
- Fehlt das Muster, ist das nur mit Maß-, Größen- oder Datumsfilter erlaubt;
  die Suche läuft dann ohne Textkriterium. `--content` und `--metadata` sagen, WOGEGEN das Muster
  läuft, und enden ohne Muster mit Exit 2 statt still falsch zu antworten.
  Positionsargumente gelten als Startpfade, sobald sie ALLE als Pfad
  existieren — auch mehrere. Bis 0.26.1 galt das nur für genau eines, und
  `--min-width 100 dirA dirB` las `dirA` still als Namensmuster.
- `--archive-depth` begrenzt Rekursion. Verschachtelte Archive werden im Speicher
  verarbeitet; deshalb Größen- und Tiefengrenzen nicht unbemerkt entfernen.
  Werte über `MAX_ARCHIVE_DEPTH` = 100 lehnt die CLI ab: Bei ungefähr 330
  verschachtelten Zips kann CPython auf macOS im C-Stack mit Exit 134 abbrechen,
  bevor `main()` eine Ausnahme fangen kann. Python-Tars werden direkt iteriert
  und nach `MAX_TAR_MEMBERS` = 65.536 Einträgen abgebrochen; `getmembers()`
  würde den unbegrenzten Katalog vollständig als TarInfo-Objekte halten.
  `ArchiveBudget` zählt nur Eintrags-INHALTE; die Namensliste eines
  bsdtar-Formats läuft daran vorbei und braucht ihre eigene Grenze
  (`MAX_ARCHIVE_LISTING_BYTES`, gelesen über `bsdtar_list()`). Bei 7z, ISO
  und tar.zst liegt der Katalog komprimiert im Archiv: 307 KB Archiv mit
  200 000 Einträgen ergaben 182 MB Spitzenspeicher.
  Der Inhalt EINES Eintrags belastet das Gesamtbudget nur EINMAL, auch wenn
  ihn `visit_member()` zweimal liest — einmal für den Blick ins Unterarchiv
  und einmal als ganz normalen Eintrag, oder bei einer Maßsuche erst den
  Bildkopf und dann den Rest. Die Marke `counted` im gemeinsamen `chunker`
  führt den Höchststand mit und gibt ihn als `free_bytes` weiter; alles
  darüber hinaus zählt wie immer voll. Ohne sie entschied allein die
  erlaubte Tiefe darüber, ob ein Eintrag durchsuchbar ist: Bis 0.28.2
  verschwand ein 20-Byte-Eintrag `fake.zip` bei
  `--max-archive-total-bytes 20` ab `--archive-depth 2` hinter der Warnung
  „Gesamtbudget überschritten", während `--archive-depth 1` ihn fand.
- `--extract` materialisiert Trefferpfade mit `!/`-Notation in einem temporären
  Ordner. Öffnen, Finder-Anzeige und Drag-and-drop müssen dieselbe Datei sehen.
  Ein Ordner-Eintrag wirft in JEDEM Format `DirectoryMemberError` und nennt
  den Grund, statt eines allgemeinen Lesefehlers. Bei 7z, ISO und tar.zst
  packt `bsdtar -xOnf` aus (`-n`, sonst liefert ein Ordner alle Dateien
  darunter); erst bei null Bytes fragt `bsdtar_member_is_directory()` die
  Auflistung, denn ein Ordner endet dort wie eine leere Datei mit Status 0.
- `bsdtar` liest das Eintrags-Argument als **Suchmuster**, nicht als festen Namen.
  Jeder neue `bsdtar`-Aufruf mit einem echten Eintragsnamen muss deshalb durch
  `bsdtar_escape()` — sonst trifft ein Eintrag `a*.txt` auch `abc.txt` und beide
  Inhalte kommen aneinandergehängt zurück, also ein falscher Treffer ohne Fehler;
  ein führendes `^` würde als Negation gerade den benannten Eintrag ausschließen.
  `-q` beendet das Auslesen nach dem ersten Treffer, damit doppelte Namen nicht
  als zusammengehängte Datei erscheinen.
  Die Auflistung von `bsdtar -tf` liest umgekehrt nur `bsdtar_listing_names()`
  (Maskierung zurücknehmen, dann dekodieren, `./` normalisieren) — Suche und
  `--extract` müssen denselben Eintragsnamen sehen, sonst findet `pick_member()`
  einen gefundenen Eintrag beim Materialisieren nicht wieder.
  Der Eintrags-TYP kommt aus einer zweiten Auflistung `bsdtar -tvf`
  (`bsdtar_listing_entries()`, Spalte 0 der zeilengleichen Zeile, nur `d`
  ist ein Ordner). Der Name wird NIE aus der `-tvf`-Zeile gelöst: Sie ist
  wie `ls -l` gebaut, und ein Symlink endet mit ` -> ziel` — genau das darf
  ein Dateiname selbst enthalten (belegt 2026-09-05). Die Zeilenzahl ist
  dagegen verlässlich, weil beide Ausgaben Zeilenumbrüche maskieren. ISO
  listet Ordner ohne Schrägstrich; ein LEERER Ordner war deshalb bis 0.31.3
  eine Datei. Decken sich die Auflistungen nicht oder reißt allein die
  längere `-tvf`-Liste `MAX_ARCHIVE_LISTING_BYTES`, gilt mit Warnung die
  alte Heuristik (Schrägstrich am Ende oder Einträge darunter).

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

Nicht das Lesen ist der Engpass der Inhaltssuche, sondern die Arbeit pro Zeile
(Zerlegen und Matcher-Aufruf). Gemessen am 2026-07-28 mit dem System-Python auf
72,8 MB Text: 0,07 s reines Lesen, 0,13 s Dekodieren, 0,56 s der gesamte alte
Weg. Innerhalb eines Zip verhält es sich genauso — dort kostete das Entpacken
0,12 s von 0,68 s. Wer die Inhaltssuche weiter beschleunigen will, muss deshalb
an der Arbeit pro Zeile ansetzen, nicht an Puffergrößen oder am Dateizugriff.
Ein Vorfilter auf Byte-Ebene vor dem Dekodieren wurde gemessen und verworfen: Er
ist nur bei reinem ASCII zulässig, und die dann nötige zweite Leserunde für
Dateien mit Nicht-ASCII-Bytes fraß den Gewinn vollständig auf.
