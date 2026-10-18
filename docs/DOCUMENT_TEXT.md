# Dokumenttext: PDF, DOCX, ODT, EPUB, XLSX und PPTX

`--document-text` beziehungsweise das Suchziel **Dokumenttext** in beiden Apps
liest die logische PDF-Textebene oder zusammenhängenden DOCX-, ODT-, EPUB-, XLSX- und PPTX-Text. `--content` / **Inhalt** bleibt Rohbytesuche
mit der gewählten Textkodierung. Komprimierte PDF-Textströme sind damit erstmals
als sichtbarer Text durchsuchbar. Es gibt keinen Dokumentindex. [Bild-OCR](OCR.md) ist ausdrücklich zuschaltbar;
Textlose PDF-Seiten nutzen die getrennte Option [PDF-OCR](PDF_OCR.md); in Office-Dokumente eingebettete Bilder werden nicht per OCR gelesen.

## Suchvertrag und optionaler Helfer

Der native Helfer `favenio-pdf` extrahiert mit PDFKit ausschließlich Seiten und
Text. Alle Muster, NFC-/Regex-Regeln, Mehrbegriffe und Kriterien entscheidet
weiter `favenio.py`. Begriffe gelten per UND über das ganze Dokument; die
Zeilenmatcher arbeiten innerhalb einer extrahierten Zeile. Ein Muster reicht
nicht über Seiten hinweg. Name, relativer Pfad, Endung und Fakten lassen sich
im bestehenden Kriterienbaum kombinieren. Im Dokumenttextmodus beziehen sich
dessen Inhaltsbedingungen ebenfalls auf Dokumenttext. Ein billig entscheidender
ODER-Zweig öffnet das PDF nicht. Negative Inhaltsbedingungen brauchen alle
angefragten Seiten ohne unbekannte Bereiche.

`build-app.sh` baut und signiert den Helfer für beide Bundles. Der Kern findet
ihn neben den Bundle-Ressourcen unter `../Helpers`, im Quellcheckout unter
`.build/favenio-pdf` oder im PATH. `FAVENIO_PDF_HELPER` wählt ausdrücklich einen
ausführbaren Pfad; ein leerer Wert schaltet den Helfer ab. Die CLI selbst
kompiliert nichts. Ohne Helfer bleiben alle bisherigen Suchmodi verfügbar;
angefragte PDFs erhalten Warnung und den Grund `documentHelperUnavailable`.
Keine zusätzliche Python-Pflichtabhängigkeit. DOCX, ODT, EPUB, XLSX und PPTX verwenden die unten beschriebenen Standardbibliothek-Leser, auch ohne PDF-Helfer. Andere Dokumentformate sind in
dieser Version ausdrücklich nicht unterstützt (`documentUnsupported`).

Ein Prozess pro Suchlauf wird erst bei Bedarf gestartet und nach 32 Dokumenten
erneuert. Das private JSONL-Protokoll Schema 1 kennt `open`, `page` und `close`;
pro Anfrage genau eine begrenzte Antwort. Python fordert Seiten einzeln an und
stoppt beim ersten ausreichenden Suchbeleg. Es gibt keinen vorausgehenden
Dokument-Vollscan. Schließen/Abbruch beendet und erntet eigene Helfer mit
SIGTERM und nötigenfalls SIGKILL. PDFKit-Diagnosen sind kein parsebares
Suchprotokoll; definierte Fehler werden getrennt transportiert.

## Grenzen und unbekannte Ergebnisse

- Höchstens 64 MiB PDF-Datei beziehungsweise materialisiertes Archivblatt.
  Archivblätter verwenden FileProbe und denselben budgetierten Chunker wie
  andere Inhalte. Einzel-/Gesamt-/Quotienten-/Tiefengrenzen gelten zusätzlich;
  ein vorher gelesener Bildkopf belastet das Archivbudget nicht doppelt.
- Fünf Sekunden je Dokument einschließlich Materialisierung, PDFKit und
  Sucharbeit. Ein eigener Alarm begrenzt auch blockierende Reads/Matcher;
  Helferwartezeiten sind zusätzlich zeitbegrenzt.
- Höchstens 512 angefragte Seiten, 256 KiB UTF-8 je Seite und 8 MiB je Dokument.
  Eine große Seitenzahl verhindert einen frühen Treffer innerhalb der Grenze
  nicht. Eine erreichte Grenze erlaubt keine negative Aussage über den Rest.
- Helferantwort höchstens 2 MiB, Anfrage höchstens 64 KiB. PDFKit muss eine
  einzelne Seite intern extrahieren, bevor deren Textgröße feststeht; diese
  Grenze ist eine Transport-/Erfassungsgrenze, keine garantierte RSS-Obergrenze
  der nativen PDF-Bibliothek. Datei- und Zeitgrenzen gelten bereits davor.

Verschlüsselte PDFs werden auch bei leerem Benutzerpasswort nicht gelesen;
es gibt keinen Passwortdialog. Nicht lesbare/beschädigte PDFs, textlose PDFs,
Helfer-/Protokollfehler und Zeit-/Mengengrenzen haben definierte Suchberichtgründe.
Eine angefragte Seite ohne Text erzeugt `documentNoText`; sie kann leer oder ein
Scan sein. Die Suche unterscheidet das nicht und beweist dort keine Abwesenheit.
Später gelesener positiver Text kann dennoch einen Treffer liefern. Nicht
angefragte Seiten werden nicht nur für einen Bericht untersucht.

## Seiten, Zeilen und Belege

`contentEncoding: "pdfkit-text-v1"` bezeichnet die extrahierte Textprojektion,
keinen Decoder der PDF-Rohbytes. Die angeforderte Rohtextkodierung bleibt in
Konfiguration und Query erhalten, verändert die PDFKit-Projektion jedoch nicht.
PDFKit liefert seinen ursprünglichen Seitentext ohne nachträgliche Normalisierung.
Die Vergleichsnormalisierung des Kerns verändert die gespeicherten Belege nicht.
Textreihenfolge und Zeilentrennung folgen PDFKit. Bei mehreren Spalten kann
PDFKit Texte auf gleicher Höhe zu einer Zeile verbinden; eine semantische
Leserichtung oder ein geometrischer Seitenbereich wird nicht versprochen.

Optionale Schema-1-Erweiterungen am bisherigen Hit:

- `documentPosition: {kind: "pdfPage", page: N, line: N}`: physische 1-basierte
  Seite und extrahierte seitenlokale Zeile. PDF-Seitenlabels wie „iv“ werden
  nicht als Seitennummer ausgegeben. Das bisherige `line` zählt extrahierte
  Zeilen über die angefragten Seiten hinweg; es ist keine PDF-Rohbytezeile.
- `documentSourceGeneration`: dieselbe Metadatenbindung des ursprünglichen
  Dateisystemcontainers wie in der Vorschau, auch ohne Vorschauerfassung.
- Begriffe und positive Inhaltskriterien tragen ihren eigenen `documentPosition`.
  JSONL, Aufnahmen und Quick-Übergabe bewahren diese Felder; CSV ergänzt
  `documentPage` und `documentLine` für den ersten Beleg. Pfadexport enthält
  weiterhin nur Pfade.

`contentPreview` bleibt Schema 1 und ergänzt dieselben Seitenlokatoren an
Ausschnitten/Kontextzeilen. `query.documentReader: "pdfkit-v1"` bindet Nachladen
an diesen Leser. Originaltext, Ausschnitt-SHA und UTF-16-Bereiche bleiben wie
in [CONTENT_PREVIEW.md](CONTENT_PREVIEW.md): keine PDF-Dateioffsets, kein
Vollinhaltshash und kein Integritätsbeweis. Die rohe Archividentität bleibt am
Hit; ein sichtbares `!/` im Mitgliedsnamen wird nicht als Archivstufe gedeutet.

Vor und nach Lesen/Nachladen werden Container und geöffnetes Blatt erneut an
ihre Generation gebunden. Geänderte Quellen verwerfen alte Positionen. Nachladen
verwendet die bestehende Materialisierungs-/Cachelogik, Fundnummer und Abbruch;
drei Sekunden Leserarbeit und fünf Sekunden App einschließlich Materialisierung
bleiben bestehen. Je Klick beginnt die seitenweise Wiedergabe am Anfang, ohne
globale Suche. `navigation.readBytes` nennt bei PDF die zugelassene Blattgröße,
keine behauptete Zahl physischer PDFKit-Lesezugriffe. `documentUnavailable`
mit `documentReason` erklärt einen nicht verfügbaren Nachladebeleg; die bisherige
Ansicht bleibt stehen. Kontext kann eine benachbarte Seite einschließen.

Öffnen und Quick Look verwenden weiterhin das PDF. Die bisherige Fastra-
Positionsübergabe erwartet Rohtext; eine PDFKit-Seitenposition ist dafür kein
Rohtextoffset und wird nicht als solcher übertragen oder bestätigt.


## DOCX-Textteile und Absätze

DOCX wird im Modus **Dokumenttext** als ein Dokument behandelt, auch bei
`--no-archives` / `--archive-depth 0`. Das ZIP-Paket ist hier die interne
Dokumentstruktur; die Archivtiefe begrenzt weiterhin äußere Sucharchive.
`--content` behält den technischen Archivmodus: mit Archivabstieg erscheinen
XML-Mitglieder als eigene Treffer, ohne Abstieg werden Paket-Rohbytes gesucht.
Ein DOCX innerhalb äußerer Archive behält deren strukturierte Identität samt
`archiveMemberBytes`, Materialisierungsweg und Quellengeneration.

Der Standardbibliothek-Leser verwendet ZIP und Expat, keinen Office-Prozess.
Er verbindet `w:t`-Textläufe ohne erfundene Leerzeichen. Tabellenzellen enthalten
gewöhnliche Absätze; Absatznummern zählen alle enthaltenen `w:p` eines Teils,
auch leere Absätze. Absätze, Zellen und Teile werden nicht zu einer Suchzeile
verbunden. `w:tab` wird Tabulator, `w:br` / `w:cr` werden Zeilenumbruch.
XML-Entities werden dekodiert; XML-eigene Zeilenendennormalisierung gilt bereits
im Parser. Unicode-Schreibweise und Leerraum des projizierten Texts bleiben
anschließend unverändert. Attribute, XML-Tags, Kommentare und Formatbefehle
sind kein Text. Formatierungen einschließlich „ausgeblendet“ werden nicht
visuell interpretiert; vorhandener `w:t`-Text bleibt in der Projektion.

Enthaltene Teile, in dieser Reihenfolge:

- Haupttext einschließlich Tabellen aus der `officeDocument`-Beziehung.
- Alle intern verknüpften Kopf-/Fußzeilen und Fuß-/Endnoten in der Reihenfolge
  der Hauptteil-Beziehungsdatei; gemeinsame Teile werden einmal gelesen.
  Kopf-/Fußzeilen gelten auf Teilebene, nicht als wiederholter Text jeder Seite.
- Eingefügte und hinverschobene Änderungen sowie angezeigte Feldergebnisse.

Ausgeschlossen sind Kommentarteile, gelöschte und wegverschobene Änderungen,
Feldanweisungen, Notentrenner und Textkästen (`w:txbxContent`). Zeichnungen/Bilder
werden nicht per OCR gelesen. Die festen Ausschlüsse stehen auch unter
`configuration.fixedLimits.docxExcluded`; die Suche behauptet nur Abdeckung
dieser Textprojektion. Alternative Importteile (`w:altChunk`) sowie externe
Beziehungen zu angefragten Textteilen bleiben unbekannt. Es gibt keinen Netzabruf.

Fehlende/beschädigte verknüpfte Teile werden erst bei Bedarf gemeldet. Ein
bereits ausreichender Haupttexttreffer fordert sie nicht allein für den Bericht
an. Negative Inhaltskriterien benötigen hingegen alle enthaltenen Teile ohne
Fehler oder Grenze. Ein strukturell gültiges leeres DOCX ist eine bekannte
leere Textprojektion; der PDF-Zustand „Seite ohne Textebene“ wird darauf nicht
übertragen. DTDs und deklarierte/externe Entities sind unzulässig; normale
XML-Zeichenreferenzen bleiben erlaubt. Transitional und Strict WordprocessingML
werden gelesen. Verschlüsselte ZIP-Teile, doppelte ZIP-Namen, ungültige
Paketbeziehungen oder fehlender Hauptteil werden erklärt und übersprungen.

### DOCX-Grenzen

- 64 MiB Paket/Materialisierung und fünf Sekunden einschließlich Sucharbeit.
- Vor Öffnen des ZIP-Katalogs: höchstens 4096 Einträge, 1 MiB Zentralverzeichnis;
  ZIP64-Zentralkataloge und mehrteilige ZIP-Pakete werden abgewiesen.
- Höchstens 64 angefragte Textteile und 32768 Absätze insgesamt.
- 256 KiB UTF-8 je Absatz, 8 MiB projizierter Text insgesamt.
- XML höchstens 8 MiB je Textteil und 32 MiB insgesamt; Metadatenteile jeweils
  256 KiB, XML-Verschachtelung höchstens 128 Ebenen.
- Die bestehenden Einzel-/Gesamt-/Quotientenbudgets gelten zusätzlich für
  entpackte interne XML-Teile. Äußere Archivbytes zählen wie bisher ebenfalls.

XML wird in 8-KiB-Häppchen geparst, der vorhandene budgetierte ZIP-Leser darf
ein größeres Häppchen vorauslesen. Höchstens ein Absatz und die abgeschlossenen
Absätze eines Parserhäppchens bleiben gepuffert. Es gibt keinen Pflicht-Vollscan,
keine Entpackung des Pakets in ein Verzeichnis und keine vorausgehende CRC-
Integritätsprüfung. Erreichte Grenzen beweisen keine Abwesenheit im Rest.

### DOCX-Belegvertrag

`contentEncoding: "docx-text-v1"` benennt die WordprocessingML-Projektion.
Die angeforderte Rohtextkodierung bleibt erhalten, steuert aber nicht den
XML-Decoder; dessen XML-Deklaration gilt. Vorschau-Query:
`documentReader: "docx-v1"`. Schema 1 ergänzt den expliziten Lokator:

```json
{"kind":"docxParagraph","part":"word/document.xml","partKind":"document","paragraph":3,"line":1}
```

`part` ist der ursprüngliche interne ZIP-Teilname (höchstens 256 Codepoints),
`partKind` ist `document`, `header`, `footer`, `footnote` oder `endnote`.
`paragraph` zählt 1-basiert innerhalb dieses Teils; `line` ist absatzlokal.
Der bisherige Hit-`line` zählt projizierte Textzeilen über gelesene Absätze.
Teilname und Absatz sind weder Quellbyteoffset noch Word-Seitenlayout.
Begriffe, Inhaltskriterien, Ausschnitte und Kontext tragen eigene Lokatoren.
JSONL, Aufnahmen und Quick-Übergabe erhalten sie; CSV ergänzt `documentPart`,
`documentPartKind`, `documentParagraph`, während `documentPage` bei DOCX leer ist.

Beide Apps verwenden dieselbe Vorschau. Vorherige/Nächste laufen je positivem
Muster über dessen Fundnummer; Kontext ist ausdrücklich anzufordern und kann
benachbarte Absätze oder Teile umfassen. Quelle und materialisiertes Blatt werden
vor/nach dem Nachladen erneut geprüft. Bestehende Drei-/Fünf-Sekunden-Grenzen,
Abbruch und Auswahlwechsel gelten unverändert. `navigation.readBytes` nennt
wie bei PDF die zugelassene Paketgröße, keine Zahl physischer Parser-Lesezugriffe.
UTF-16-Bereiche bleiben Ausschnittbereiche und `excerptSHA256` bleibt der Hash
dieses Ausschnitts. Öffnen/Quick Look verwenden das DOCX; Fastra bekommt daraus
keinen erfundenen Rohtextoffset.

Formatgrundlagen: [WordprocessingML-Struktur und Textläufe](https://learn.microsoft.com/en-us/office/open-xml/word/how-to-open-and-add-text-to-a-word-processing-document),
[Kopfzeilenbeziehungen](https://learn.microsoft.com/en-us/office/open-xml/word/how-to-replace-the-header-in-a-word-processing-document).


## ODT: Haupttext und Tabellen

ODT verwendet denselben begrenzten ZIP-/XML-Zugang wie DOCX und benötigt nur die
Standardbibliothek. `content.xml` liefert `text:p` und `text:h` innerhalb von
`office:body/office:text`, einschließlich Tabellenzellen in XML-Reihenfolge.
Textspans werden ohne zusätzliche Trennzeichen verbunden. Absätze und Zellen
bleiben eigene Suchzeilen; leere Absätze zählen bei der Absatznummer mit.
XML-Entities werden aufgelöst. Einfacher Textleerraum bleibt erhalten;
`text:s` liefert ausdrücklich angegebene Leerzeichen, `text:tab` einen Tabulator,
`text:line-break` einen Zeilenumbruch. Wiederholungsattribute von Tabellen werden
nicht zu mehrfachen Absätzen expandiert; der Lokator benennt den gespeicherten Absatz.

Annotationen, Änderungsprotokolle, Noten, Inhalts-/andere Verzeichnisse und
Zeichenobjekte einschließlich Textkästen sind ausgeschlossen. Aktueller Haupttext
zwischen Änderungsmarken bleibt enthalten. Kopf-/Fußzeilen und Metadaten gehören
nicht zur Projektion. Tags, Stilnamen und Attribute erzeugen keinen Texttreffer.
Eine im Manifest angegebene Verschlüsselung wird als `documentEncrypted` gemeldet;
fehlendes Manifest, fehlender Haupttext oder defektes XML bleiben unbekannt.
Ein gültiger leerer Haupttext ist eine bekannte leere Projektion.

Schema 1 verwendet `contentEncoding: odt-text-v1`, Query `documentReader: odt-v1`
und diesen Lokator (ohne `partKind`):

```json
{"kind":"odtParagraph","part":"content.xml","paragraph":3,"line":1}
```

## EPUB: Kapitel nach Spine

Der Standardbibliothek-Leser folgt `META-INF/container.xml` zum ersten
Paketdokument, dessen OPF-Manifest und dessen Spine. ZIP-Katalogreihenfolge und
Dateinamen bestimmen die Lesereihenfolge nicht. Mehrere Renditions wählen bewusst
das erste Paket. `linear="no"` und Manifestteile mit `properties="nav"` sind
Hilfs-/Navigationsmaterial und ausgeschlossen. Die 1-basierte `chapter`-Nummer
entspricht der ursprünglichen Spine-Position einschließlich solcher ausgelassenen
Einträge; wiederholte Spine-Referenzen bleiben wiederholte Kapitel.

Angefragte XHTML-/HTML-Kapitel werden in 8-KiB-Häppchen mit dem HTML-Parser der
Standardbibliothek gelesen. Inline-Elemente verbinden Text ohne erfundene
Leerzeichen. HTML-Zeichenreferenzen einschließlich `&nbsp;` werden aufgelöst.
ASCII-HTML-Leerraum kollabiert über Inline-Grenzen hinweg zu einem Leerzeichen,
am Absatzrand entfällt er; `pre` bewahrt ihn, `br` liefert einen Zeilenumbruch.
Blockelemente und Tabellenzellen trennen projizierte Absätze. Nur nichtleere
projizierte Absätze zählen innerhalb eines Kapitels. Quelle, Unicode-Schreibweise
und dieser einmal projizierte Text werden danach nicht normalisiert.

`head`, `script`, `style`, `nav`, `template`, `noscript`, eingebettete SVG-/MathML-
und Fremdobjekte sowie `hidden` / `aria-hidden="true"` bleiben aus. Attribute und
Tags sind kein sichtbarer Text. CSS, Script und Layout werden nicht ausgeführt;
CSS-versteckter Text und per CSS erzeugter Text werden nicht visuell interpretiert.
Es gibt keine Netzabrufe. Kapitel-URLs müssen interne, normalisierte Paketpfade
sein. Andere Spine-Medientypen, fehlende Referenzen/Dateien, verschlüsselte Kapitel,
inkonsistente Tagverschachtelung, unvollständiges Markup und unbekannte Entities
bleiben unbekannt. Spätere lesbare Kapitel dürfen positive Belege liefern; bereits
angefragte Fehler bleiben im Suchbericht sichtbar. Ein ausreichender früher Beleg
liest spätere Kapitel nicht allein für den Bericht.

UTF-8 ist Standard; UTF-16 mit BOM sowie explizite XML-Deklarationen für UTF-8,
UTF-16, ISO-8859-1 und Windows-1252 werden strikt dekodiert. Fehler beweisen keine
Abwesenheit. Nur der einfache HTML-Doctype ist erlaubt; DTDs und externe Entities
werden nicht aufgelöst. Strukturell geschlossene HTML-Absätze sind erforderlich;
der Leser repariert beschädigte HTML-Strukturen nicht wie ein Browser.

Schema 1 verwendet `contentEncoding: epub-text-v1`, Query `documentReader: epub-v1`
und diesen Lokator (ohne `partKind`):

```json
{"kind":"epubParagraph","part":"OPS/chapter.xhtml","chapter":2,"paragraph":3,"line":1}
```

### Gemeinsame Paketgrenzen und Belegwege

ODT und EPUB übernehmen die DOCX-Deckel: 64 MiB Paket/Materialisierung, fünf
Sekunden, 64 angefragte Kapitel/Teile, 32768 Absätze, 256 KiB UTF-8 je Absatz,
8 MiB Text, ZIP-Katalog 4096 Einträge / 1 MiB, XML-/HTML-Teil 8 MiB / insgesamt
32 MiB, Metadaten je 256 KiB und 128 Strukturebenen. Ein noch unvollständiges
HTML-Token ist zusätzlich auf 256 KiB Zeichen begrenzt. ODT besitzt einen
Haupttextteil. Bestehende Archivbudgets begrenzen auch interne Paketdaten.

Die gemeinsamen Regeln für frühes Ende, Quellengeneration, rohe Archividentität,
Begriffe/Kriterien und UTF-16-Ausschnittbereiche gelten unverändert. Technische
ZIP-Mitglieder sind ausschließlich im Rohinhalt-/Archivmodus eigene Treffer.
JSONL, Vorschau, Kontext, Übergabe und Aufzeichnungen bewahren die Lokatoren.
CSV verwendet `documentPart`/`documentParagraph` sowie zusätzlich `documentChapter`
für EPUB; `documentPage` und `documentPartKind` bleiben bei ODT/EPUB leer.
Öffnen und Quick Look verwenden das Originaldokument. Nachladen bleibt bei drei
Sekunden Kern / fünf Sekunden App; der Ausschnitt-SHA ist kein Vollinhaltshash.
Die Berichtsgründe bleiben im bestehenden Register von 32 Kennungen.

Formatgrundlagen: [ODF 1.3, Teil 3](https://docs.oasis-open.org/office/OpenDocument/v1.3/os/part3-schema/OpenDocument-v1.3-os-part3-schema.html),
[EPUB-Paket und Spine](https://www.w3.org/TR/epub-33/#sec-spine).


## XLSX: Blatt und tatsächliche Zelle

XLSX verwendet denselben begrenzten Standardbibliothek-Zugang zu ZIP/XML. Der Leser
folgt der officeDocument-Beziehung zur Arbeitsmappe, deren sheets-Reihenfolge und
den worksheet-Beziehungen. Dateinamen, ZIP-Katalog und Shared-String-Reihenfolge
bestimmen keine Fundstellen. Jede Zelle mit einem gespeicherten Wert liefert einen
getrennten Textabschnitt. Begriffe können in verschiedenen Zellen/Blättern stehen;
ein einzelner Zeilenmatcher verbindet keine benachbarten Zellen.

Zellen vom Typ s lösen ihren Index in der gemeinsamen Stringtabelle auf. Diese
wird erst bei Bedarf fortgesetzt; bereits gelesene Einträge bleiben in einem
begrenzten Cache für rückwärts gerichtete oder wiederholte Referenzen. Unbenutzte
Strings werden weder als Treffer ausgegeben noch allein für den Bericht gelesen.
Ein beschädigter unangefragter Stringtabellenrest ist daher keine durchgeführte
Integritätsprüfung. Inline-Strings und Rich-Text-Läufe werden ohne zusätzliche
Trennzeichen verbunden. XML-Entities und OOXML-Maskierungen wie _x000D_ werden
aufgelöst; maskierte Unterstriche erhalten wörtliche Maskierungsfolgen. Phonetische
Hilfstexte und Formatattribute gehören nicht zum Zelltext. Ursprünglicher Leerraum
und Unicode bleiben nach der Projektion erhalten. Strict und Transitional
SpreadsheetML sowie die XML-eigene Kodierung sind unterstützt.

### Werte und Formeln

- Text und Inline-Text werden als Text projiziert.
- Zahlen bleiben ihre gespeicherten, unformatierten Dezimal-/Exponentenwerte.
  Stilvorlagen, Währung, Prozentformat und numerische Datumsserien werden nicht
  in Excel-Anzeigetext umgerechnet. Wahrheitswerte 0/1 erscheinen als FALSE/TRUE.
  Zellen vom ausdrücklichen Typ d behalten ihren gespeicherten ISO-Datumswert.
- Formeln werden nicht berechnet und ihr Formeltext ist ausgeschlossen. Nur ein
  vorhandener Cachewert wird gelesen und ausdrücklich als **gespeichertes
  Formelergebnis** beschriftet. Er kann veraltet sein. Das gilt auch für gemeinsame
  oder Arrayformeln; es wird keine Abhängigkeit oder Ausdehnung nachgebaut.
- Eine Zelle ohne Wert ist bekannt leer; ein ausdrücklich gespeicherter leerer
  String ebenfalls. Fehlender Formelcache, Fehlerzellen, ungültige Zahl-/Bool-/
  Datumswerte, unbekannte Zelltypen oder kaputte Shared-String-Referenzen bleiben
  unbekannt. Andere lesbare Zellen können weiterhin positive Belege liefern;
  angefragte Fehler bleiben im Suchbericht sichtbar.

Ausgeblendete/veryHidden Blätter, ausgeblendete Zeilen/Spalten und Zellen sind
enthalten. Formatierte Schriftfarbe, Sichtbarkeit und Excel-Layout werden nicht
interpretiert. Kommentare, Zeichnungen, Diagramm-/Pivottexte, Kopf-/Fußzeilen und
Fremdobjekte sind ausgeschlossen. Verbundene Zellen werden nicht vervielfacht;
nur der tatsächlich gespeicherte Zellwert zählt. Chartsheets/fremde Blattarten,
fehlende oder externe Blattbeziehungen bleiben unbekannt. Keine Netzabrufe.

### XLSX-Grenzen und Lokator

Die allgemeinen Paketdeckel bleiben unverändert: 64 MiB Paket/Materialisierung,
fünf Sekunden, ZIP-Katalog 4096 Einträge/1 MiB, XML je Teil 8 MiB/gesamt 32 MiB,
Metadaten je 256 KiB, 128 Strukturebenen. Hinzu kommen höchstens 64 angefragte
Blätter, 131072 gespeicherte Zellen insgesamt (auch leere), 65536 bei Bedarf
erschlossene Shared Strings und 8 MiB UTF-8-Stringcache. Ein Zellwert/einzelner
String bleibt bei 256 KiB UTF-8, projizierte Zellwerte zusammen bei 8 MiB. Wiederholte
Verwendung eines Strings zählt beim ausgegebenen Text erneut. Blattnamen haben
höchstens 256 Codepoints. Zelladressen sind ausdrücklich gespeicherte A1-Adressen
bis XFD1048576; doppelte oder zu vorhandenen Zeilennummern widersprüchliche
Adressen werden abgewiesen. Es wird keine fehlende Zelladresse geraten.

XML wird gestreamt, der Cache bleibt begrenzt; DTDs/externe Entities sind verboten.
Bestehende innere und äußere Archivbudgets gelten zusätzlich. Fehlende Teile und
Grenzen beweisen unter Negation keine Abwesenheit. Ein ausreichender früher Beleg
verlangt weder weitere Blätter noch die ganze Stringtabelle. Diese Deckel sind
keine behauptete konstante RSS-Grenze: Stringcache und Adressprüfung benötigen
Speicher innerhalb der benannten Mengenlimits.

Schema 1 verwendet `contentEncoding: xlsx-text-v1`, Query `documentReader: xlsx-v1`
und einen eigenen Lokator:

```json
{"kind":"xlsxCell","part":"xl/worksheets/sheet1.xml","sheet":"Übersicht","sheetIndex":1,"cell":"B3","valueKind":"cachedString","line":1}
```

sheetIndex ist die ursprüngliche 1-basierte Position in der Arbeitsmappe, sheet
der ursprüngliche Blattname, part der ursprüngliche interne Teilname und cell die
explizite Zelladresse. line zählt innerhalb des projizierten Zellwerts. valueKind
ist text, number, boolean, date, cachedString, cachedNumber, cachedBoolean oder
cachedDate. Blatt- und Teilnamen werden in Swift bytegetreu verglichen. Der Lokator
ist weder Excel-Layout noch Datei-/XML-Offset.

Gemeinsame Vorschau, Kontext, JSONL, Quick-Übergabe und Aufnahmen bewahren den
Lokator. CSV ergänzt documentSheet, documentSheetIndex, documentCell und
documentValueKind; Seiten-/Absatz-/Kapitelspalten bleiben für XLSX leer. Quelle und
materialisiertes Blatt werden vor/nach Nachladen erneut geprüft. Fundnummer,
Abbruch, Auswahlwechsel und Cache verwenden den bestehenden Weg; drei Sekunden
Kern / fünf Sekunden App gelten weiter. UTF-16-Ausschnittbereiche und
Ausschnitt-SHA bleiben ausschließlich an den gespeicherten Ausschnitt gebunden.
Öffnen/Quick Look verwenden das XLSX; daraus entsteht kein Rohtextoffset.

Formatgrundlagen: [Shared Strings und Textläufe](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/working-with-the-shared-string-table),
[Arbeitsmappen und Blattbeziehungen](https://learn.microsoft.com/en-us/office/open-xml/spreadsheet/structure-of-a-spreadsheetml-document).

## PPTX: Folien, Objekte und Tabellenabsätze

PPTX folgt der officeDocument-Beziehung zur Präsentation und deren sldIdLst-/
slide-Beziehungen. Foliennummern zählen 1-basiert in dieser Präsentationsliste,
auch ausgeblendete Folien. ZIP-Katalog und Teilnamen bestimmen keine Reihenfolge.
Innerhalb einer Folie gilt die gespeicherte XML-Reihenfolge des Shape-Trees,
rekursiv auch in Gruppen. Sie verspricht keine geometrische Leserichtung.

Enthalten sind DrawingML-Textläufe a:r/a:t in Form-/Textkastenabsätzen sowie
Tabellenzellen. Läufe innerhalb eines Absatzes werden ohne erfundene Leerzeichen
verbunden, a:br wird Zeilenumbruch. XML-Entities und XML-Zeilenendennormalisierung
gelten; Unicode und Leerraum bleiben danach erhalten. Jeder Absatz bleibt ein
getrennter Textabschnitt. Leere Absätze zählen mit; Tabellenabsätze zählen je
Zelle neu, Tabellenzeilen/-spalten nach gespeicherter Reihenfolge. Verbundene
Zellen werden nicht vervielfacht. Mehrere Begriffe dürfen verschiedene Absätze,
Objekte oder Folien erfüllen. Ein einzelner Zeilenmatcher verbindet sie nicht.

**Notizen sind ausgeschlossen** und werden weder gelesen noch in Folientext
vermischt. Ebenfalls ausgeschlossen: Master-/Layout-/Handouttexte, Kommentare,
a:fld-Felder einschließlich gespeicherter Datums-/Foliennummerntexte, Diagramme,
SmartArt, Bilder/OCR, eingebettete Fremdobjekte und AlternateContent-/Erweiterungs-
material. Form-/Textkastentext gehört dagegen zum unterstützten Umfang.
Attribute, Objektnamen, Tags, Formatbefehle und technische Paketdaten erzeugen
keinen Texttreffer. Ausgeblendete Folien und Textformen sind enthalten; Schrift,
Sichtbarkeit, Positionen, Animationen und PowerPoint-Berechnungen werden nicht
interpretiert. Diese feste Projektion steht im Suchbericht unter fixedLimits.

Transitional und Strict PresentationML/DrawingML sowie die XML-eigene Kodierung
werden unterstützt. Fehlende/externe/falsche Folienbeziehungen, defektes XML,
fehlende/duplizierte Objekt-IDs und erreichte Grenzen bleiben unbekannt, auch unter
Negation. Spätere lesbare Folien können positive Treffer liefern. Ein früher
Beleg liest spätere Teile nicht allein für den Bericht. Notizen und andere feste
Ausschlüsse gehören ausdrücklich nicht zur behaupteten Textabdeckung.

### PPTX-Grenzen

64 Folien, 32768 Shape-Tree-Objekte (einschließlich Gruppen/Bildern), 32768 Absätze
und 131072 gespeicherte Tabellenzellen insgesamt; je Tabelle höchstens 131072
Zeilen, auch leere. Damit bleiben auch Zeilenlokatoren innerhalb der gemeinsamen
Validierungsgrenze. Notizen: null. Absatz-/Textgrenzen
bleiben 256 KiB UTF-8 / 8 MiB. Die Objekt- und Zellgrenzen begrenzen auch leere
Strukturen, die sonst keinen Textdeckel erreichen. Es gelten zusätzlich unverändert
64 MiB Paket/Materialisierung, fünf Sekunden, ZIP-Katalog 4096 Einträge/1 MiB,
XML 8 MiB je Teil/32 MiB gesamt, Metadaten 256 KiB und 128 Ebenen. Innere/äußere
Archivbudgets gelten weiterhin. DTDs/externe Entities sind verboten. Es gibt keine
neue Pflichtabhängigkeit, Netzabfrage oder behauptete harte RSS-Grenze.

### PPTX-Belegvertrag

Schema 1: contentEncoding `pptx-text-v1`, Query documentReader `pptx-v1` und:

```json
{"kind":"pptxParagraph","part":"ppt/slides/slide1.xml","slide":1,"objectID":"2","objectKind":"shape","paragraph":3,"line":1}
```

part ist der ursprüngliche interne ZIP-Teilname (höchstens 256 Codepoints),
objectID die tatsächlich gespeicherte eindeutige cNvPr-ID als kanonischer Dezimalstring
(0–4294967295). objectKind ist shape oder table. Tabellen ergänzen 1-basierte
row und column für die gespeicherte Zelle. paragraph ist objekt- beziehungsweise
zelllokal, line absatzlokal. Es sind keine Datei-/XML-Offsets oder PowerPoint-
Layoutpositionen. Teilnamen werden in Swift bytegetreu verglichen.

Vorschau, Kontext, JSONL, Aufzeichnungen und Quick-Übergabe bewahren diese Lokatoren.
CSV ergänzt documentSlide, documentObjectID, documentObjectKind, documentRow und
documentColumn. Nachladen verwendet Fundnummer, begrenztes Wiederlesen und die
vorhandenen eigenen Abbruch-/Cachewege. Quelle und materialisiertes Blatt werden
vor/nach Nachladen erneut geprüft; Quellenwechsel verwirft alte Positionen.
Drei Sekunden Kern/fünf Sekunden App, UTF-16-Ausschnittbereiche und Ausschnitt-SHA
bleiben unverändert. Öffnen/Quick Look verwenden das PPTX; Fastra bekommt keinen
erfundenen Rohtextoffset. Technische ZIP-Mitglieder bleiben dem Roharchivmodus
vorbehalten; äußere Archive bewahren archiveMemberBytes und ihre Budgetgrenzen.

Formatgrundlagen: [Präsentation und Folienliste](https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-presentations),
[Textläufe und Absätze](https://learn.microsoft.com/en-us/office/open-xml/presentation/how-to-get-all-the-text-in-a-slide-in-a-presentation),
[getrennte Notizenteile](https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-notes-slides).

Objekt-ID-Typ: [ST_DrawingElementId, unsigned 32-bit](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/9746bb87-3dd0-4c7d-ae43-e3547589def1). Numerisch gleiche ID-Schreibweisen dürfen innerhalb einer Folie nicht kollidieren.

Textlose PDF-Seiten können ausdrücklich mit `--pdf-ocr` ergänzt werden. Vorhandene Textebenen werden bevorzugt; Regeln, Mischbelege und Grenzen stehen unter [PDF-OCR](PDF_OCR.md). Ohne die Option bleibt der bisherige PDF-Textebenenpfad erhalten.
