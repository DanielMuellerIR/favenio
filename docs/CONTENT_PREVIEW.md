# Begrenzte Fundstellenvorschau

`--json --content-preview` ergänzt Treffer um das optionale Objekt
`contentPreview` (Schema 1). Die GUI-Schaltfläche „Fundstellenvorschau“ wählt
diesen Lesepfad für den nächsten Suchlauf. Ein bereits abgeschlossener Lauf
ohne Vorschau wird dadurch nicht still neu gestartet: Die Ansicht bietet
„Mit Vorschau neu suchen“ ausdrücklich an. Quick Look bleibt auf der Leertaste.

## Quelle und Bereiche

Die Ausschnitte entstehen beim ersten bewiesenen Inhaltsfund je Begriff bzw.
positivem entscheidendem Inhaltskriterium im vorhandenen Python-Leser. Sie
bewahren Originalschreibweise. Der Kontext liegt innerhalb derselben Fundzeile;
Zeilentrenner werden vom bestehenden Zeilenleser getrennt, nicht umgeschrieben.
Es gibt kein Vor-/Nachlesen zusätzlicher Zeilen, keinen Pflicht-Vollscan und
keine zusätzliche Materialisierung. Standardläufe ohne Option erfassen nichts.

`contentPreview.sourceGeneration` bindet den Dateisystemcontainer über Gerät,
Inode, Größe, Änderungs- und Statuszeit in Nanosekunden. Die fünf Werte sind
Dezimalstrings ohne Gleitkommarundung. Der Stand wird vor dem Öffnen, bei normalen
Dateien zusätzlich am tatsächlich geöffneten Deskriptor und nach dem Lesen
geprüft. Ein Archivmitglied bleibt über die im selben Treffer enthaltenen
`filesystemPath`, `archiveMembers` und `archiveMemberBytes` identifiziert;
`path` wird niemals an `!/` zerlegt. Der Containerstand gilt auch für verschachtelte
Archive. Das ist eine Metadatenbindung, kein Vollinhaltshash oder Integritätsbeweis.

`contentEncoding` nennt den tatsächlichen Decoder dieses Lesers. Die angeforderte
Wahl `encoding` und die UTF-8-/BOM-Regeln aus [Textkodierung](../README.de.md#textkodierung)
bleiben erhalten. Ein billig entscheidender Namenszweig liest keinen Inhalt für
die Vorschau. Negative Inhaltsbedingungen erzeugen keinen positiven Ausschnitt.

Jeder Ausschnitt enthält:

- `termIndex` (1-basiert) oder `criterionID`, dazu eine gekürzte `label`;
- `line` (1-basiert), ursprünglichen `text` und dessen `excerptSHA256` als UTF-8;
- `positionBinding: excerptUTF16` sowie `location`/`length` innerhalb dieses
  Ausschnitts, in UTF-16-Codeeinheiten;
- `prefixTruncated`, `suffixTruncated` und gegebenenfalls `matchTruncated`.

Die Bereiche sind ausdrücklich keine Offsets der ganzen Quelldatei.
`excerptSHA256` ist weder der Rohbyte-SHA noch der Text-SHA des vollständigen
Fastra-Snapshots. NFC-Treffer werden auf die ursprünglichen Codepoints zurückgeführt;
Regex arbeitet direkt darauf. Ein leerer Regex-Treffer bleibt ein Bereich der
Länge null und wird beschriftet, ohne ein fremdes Zeichen zu markieren.

Bei Ersatzzeichen lautet die Bindung `invalidDecoding`; bei nicht begrenzt
belegbarem Originalbereich `unavailable`. Beide besitzen keinen markierbaren
Bereich. Der Treffer bleibt erhalten, die Vorschau erklärt die Einschränkung.

## Grenzen und Zustände

- Höchstens 32 Ausschnitte pro Treffer, je 256 Unicode-Codepoints, insgesamt
  2048 Codepoints (höchstens 4096 UTF-16-Codeeinheiten) pro Treffer.
- Höchstens 48 Codepoints Kontext vor/nach dem Fund innerhalb derselben Zeile;
  ein langer Fundtext wird mit expliziter Kennzeichnung gekürzt.
- Die Originalbereichsabbildung untersucht höchstens 65536 Codepoints eines
  vorhandenen Zeilenstücks. Größere Stücke erhalten keine erfundene Position.
- Die Erfassung stoppt nach 100 ms aufgewendeter Vorschauarbeit je Objekt,
  geprüft zwischen Belegen. Ein einzelner Matcher wird nicht präemptiv beendet;
  die vorhandenen Such-/Regexgrenzen gelten weiter.
- Pro Suchlauf höchstens 8 MiB serialisierte Vorschauobjekte. Danach folgen
  nur noch kleine `budgetExceeded`-Statusobjekte ohne Text und Quellengeneration.
  Die bestehenden Lese-/Entpackbudgets zählen unverändert Rohbytes.

`status` ist `ready`, `noContentEvidence`, `sourceChanged` oder `budgetExceeded`.
`omitted` zählt angeforderte, nicht gespeicherte positive Belege eines erfassten
Objekts. Bei `budgetExceeded` fehlt der Zähler, weil keine objektbezogene
Erfassung vorliegt; das ist keine behauptete Null. Frühere Vorschauobjekte mit
Null an dieser Stelle werden als derselbe unbekannte Zustand gelesen. Kürzungen
und Grenzen verändern die Treffermenge oder Abwesenheitsentscheidung nicht.

Beide Apps prüfen bei Auswahlwechsel und im Sekundenabstand ausschließlich die
Metadaten der ausgewählten Quelle im Hintergrund. Auswahlepochen verwerfen alte
Antworten; pro Controller läuft höchstens eine Prüfung. Geänderte/fehlende Quellen
entfernen den angezeigten Text und bieten eine neue Suche an. Unveränderte Prüfungen
setzen Scrollposition oder Textauswahl nicht zurück. JSONL-Export, Aufnahmen und
Quick-Übergabe bewahren die begrenzten Belege; ungültige Vorschauobjekte werden
ohne Verwendung ihrer Textbereiche kenntlich gemacht.

Öffnen, Quick Look und Fastra verwenden weiterhin die vorhandenen Materialisierer
mit deren Abbruch und Lebensdauern. Fastra weist eine gegenüber dem gespeicherten
Vorschaustand geänderte Quelle oder einen anderen Decoder ab und belegt seine
vollständige aktuelle Kopie weiterhin getrennt. Weitere Fundstellen und Kontext werden ausschließlich auf Anforderung geladen,
wie im folgenden Abschnitt beschrieben.

Der gemeinsame Auspackcache bindet seine Kopien zusätzlich an die
Dateigeneration des Containers. Eine neue Generation verwendet eine frische
Kopie; eine an eine alte Vorschau gebundene Anforderung wird abgewiesen.
Änderungen während des Auspackens werden vor Veröffentlichung erkannt.
Bereits zugestellte alte Kopien bleiben bis zum normalen Cleanup erhalten,
damit offene externe Ansichten ihre Datei nicht verlieren. Die Identität des
Treffers und das Teilen gleichzeitiger Anforderungen derselben Generation
bleiben unverändert.

## Weitere Fundstellen auf Anforderung

Schema 1 wird um optionale `query`-Deskriptoren je positivem Ausschnitt erweitert:
`pattern`, `regex`, `caseSensitive`, `exact`, `literalWildcards` und die angeforderte
`encoding`. Letztere bewahrt auch die Wahl, ob eine UTF-8-BOM verbraucht wurde;
`contentEncoding` bleibt der tatsächliche Decoder. Sie transportieren
die tatsächlichen Python-Matcheroptionen. Die Apps werten sie nicht aus. Alte
Schema-1-Belege bleiben lesbar; ohne Deskriptor ist keine Navigation verfügbar.
Nicht verlustfrei als Unicode transportierbare Muster bekommen keinen Deskriptor.
Negative oder nicht entscheidende Bedingungen werden weiterhin nicht nachgeladen.

Die gemeinsame Ansicht wählt einen Begriff oder ein positives entscheidendes
Inhaltskriterium. Seine Fundstellen werden unabhängig, in Quellreihenfolge und
nicht überlappend gezählt, einschließlich mehrerer Bereiche derselben Zeile.
Ein leerer Regex-Fund wird einmal gezählt, danach geht es mindestens einen
Originalcodepoint weiter. Die UND-/ODER-Entscheidung des Suchlaufs wird nicht neu
berechnet; Nachladen ist keine neue Trefferentscheidung. Vorherige/Nächste
beziehen sich auf dieses eine Muster, nicht auf andere Begriffe.

`--preview-request JSON` ist ein gezielter Belegeingang ohne globale Traversierung.
Der Auftrag enthält `schemaVersion: 1`, den ursprünglichen `hit`, `filePath` des
Blatts, dessen `fileGeneration`, `queryIndex` (0-basiert im ursprünglichen
Ausschnittarray), `occurrence` (0-basiert pro Muster) und optional `context: true`.
Für normale Dateien muss `filePath` der Trefferquelle entsprechen. Archivblätter
werden von den Apps mit dem vorhandenen Materialisierer und dessen Cachebindung
bereitgestellt; die ursprüngliche Archividentität bleibt im Hit erhalten.
`archiveLimits` in der Vorschau bewahrt `memberBytes`, `totalBytes` und `ratio` aus
dem Suchlauf, höchstens die bisherigen Standardgrenzen der Materialisierung. Der Eingang packt selbst keine
Archive aus. Die CLI kann ihm ein separat materialisiertes Blatt übergeben.

Die Fortsetzungsmarke ist die logische Fundnummer innerhalb des gebundenen Musters,
Decoders, Blatts und Quellstands. Sie behauptet keine Dateioffsets und keinen
vollständigen Inhaltshash. Der Leser läuft je ausdrücklichem Auftrag erneut vom
Anfang; alle übersprungenen Bytes zählen mit. Das ist auch bei UTF-16, komprimierten
Quellen und späteren Dokumentlesern eindeutig. Künftige Leser können pro
Fundstelle zusätzliche Seiten-/Absatz-Lokatoren liefern und dieselbe Navigation
über Fundnummer, Quellbindung und Ausschnittbereiche anschließen; PDF-Dokumenttext verwendet inzwischen ausdrücklich Seitenlokatoren; siehe
[Dokumenttext](DOCUMENT_TEXT.md).

Pro Auftrag gelten:

- Höchstens 128 KiB Auftrag, 64 MiB Blattbytes und drei Sekunden Leserarbeit.
  Ein eigener Alarm unterbricht auch einen einzelnen teuren Regexaufruf.
- In den Apps höchstens fünf Sekunden einschließlich Warten und Auspacken;
  SIGTERM/SIGKILL und das Abmelden eigener Materialisierungsanforderer verwenden
  die bestehenden Prozesswege. Andere Anforderer desselben Auftrags bleiben erhalten.
- Eine Fundstelle mit höchstens 256 Codepoints. Mehr Kontext erweitert innerhalb
  der Fundzeile von 48 auf bis zu 120 Codepoints je Seite und liefert zusätzlich
  höchstens drei Zeilen davor/danach, je 256 Codepoints. Insgesamt höchstens 1792
  Codepoints. Kontextzeilen bleiben getrennt, ohne umgeschriebene Quellzeilentrenner.
- Reine Enthält-Muster nutzen begrenzte überlappende Rohstücke auch in minifizierten
  Dateien. Verankerte/Glob-Muster werden nur auf ganzen Zeilen geprüft;
  nicht begrenzt abbildbare Zeilen ergeben eine ausdrückliche Positionsgrenze.

Die Antwort ist genau ein Hit im bisherigen JSONL-Format. `contentPreview.navigation`
enthält `queryIndex`, die angeforderte `occurrence`, `readBytes`, `contextLines`
und `reason`: `ready`, `end`, `readLimit`, `positionLimit` oder `sourceChanged`.
Nur `end` beweist das Ende dieses Belegstroms. Ein textloses `noContentEvidence`
mit Nachladegrenze ist keine Abwesenheitsaussage. Das bisher angezeigte Ergebnis
bleibt bei Ende/Abbruch/Grenze stehen. Kontextzeilen tragen `line`, ursprünglichen
`text`, `truncated` und `excerptSHA256`; sie behaupten keine exakten Quellbereiche.
Swift validiert ihre Länge und ihren Ausschnitt-SHA ebenso wie die Fundstelle.
Der optionale Belegzweig wird mit JSONDecoder gelesen: Foundation-
JSONSerialization entfernt sonst ein führendes U+FEFF auch in Stringwerten.

Container und Blatt werden vor und nach dem Auftrag sowie das geöffnete Blatt am
Deskriptor geprüft. Quellenänderung verwirft alle alten Positionen und Kontexttexte
und fordert eine neue Suche. Auswahlwechsel, Ausschalten und Abbrechen entwerten
auch bereits eingereihte Antworten. Unveränderte Timerprüfungen setzen die aktuelle
Fundstelle, Textauswahl und Scrollposition nicht zurück. Nachgeladene Fundstellen
sind ein lokaler Ansichtszustand; Export und Übergabe erhalten weiterhin die im
Suchlauf erfassten ersten Belege.

## Dokumenttext und Seitenlokatoren

PDF-Belege ergänzen Schema 1 um `documentPosition` an Ausschnitten/Kontextzeilen
und `query.documentReader: pdfkit-v1`. `contentEncoding: pdfkit-text-v1` ist eine
Textprojektion, kein Rohbyte-Decoder. Die gemeinsame Vorschau validiert Seiten-
und Zeilennummern zusätzlich; Ausschnittbereiche bleiben ausschließlich UTF-16
im gespeicherten Ausschnitt. Vollständiger Vertrag: [DOCUMENT_TEXT.md](DOCUMENT_TEXT.md).

DOCX ergänzt denselben Vertrag um `documentReader: docx-v1`,
`contentEncoding: docx-text-v1` und ausdrücklich getrennte Teil-/Absatz-Lokatoren
`kind: docxParagraph`. Die gemeinsame Ansicht, Quellprüfung und begrenzte
Navigation bleiben gleich. Siehe [Dokumenttext](DOCUMENT_TEXT.md).


ODT und EPUB ergänzen `odt-v1` / `epub-v1` und `odt-text-v1` / `epub-text-v1`.
`odtParagraph` nennt `part`, `paragraph`, `line`; `epubParagraph` zusätzlich die
ursprüngliche Spine-Position `chapter`. Teilnamen werden bytegetreu verglichen.
Die gemeinsame Vorschau, Navigation und Quellprüfung verwenden dieselben Grenzen.
[DOCUMENT_TEXT.md](DOCUMENT_TEXT.md) definiert Projektion, Ausschlüsse und Lokatoren.


XLSX ergänzt `xlsx-v1` / `xlsx-text-v1` und `kind: xlsxCell` mit part, sheet,
sheetIndex, cell, valueKind und zelllokaler line. Die gemeinsame Ansicht beschriftet
gespeicherte Formel-Caches und unformatierte Zahlen. Sheet- und Part-Identität
bleiben bytegetreu; Quellprüfung und begrenzte Navigation gelten unverändert.
Der vollständige Vertrag steht in [DOCUMENT_TEXT.md](DOCUMENT_TEXT.md).

PPTX ergänzt `pptx-v1` / `pptx-text-v1` und `kind: pptxParagraph` mit part, slide,
objectID, objectKind, paragraph und absatzlokaler line; Tabellen zusätzlich row und
column. Folien-/Objekt-/Absatzbelege bleiben im bestehenden Quellbindungs-, Kontext-
und Navigationsweg. [DOCUMENT_TEXT.md](DOCUMENT_TEXT.md) definiert Umfang und Grenzen.

## Erkannter Bildtext

OCR-Ausschnitte verwenden denselben begrenzten Vorschau-/Nachladepfad mit dem
Leser `vision-image-v1`. Hervorhebung bindet den erkannten Text, keine Original-
Dateibytes oder exakten Bildpixel. Herkunft, Modellwert und ungefähre normalisierte
Bildregion werden sichtbar genannt; Quellengeneration und lokale Lesepolitik
bleiben erforderlich. [OCR-Vertrag](OCR.md).

PDF-OCR verwendet `pdfkit-vision-text-v1` / `pdfkit-vision-v1` mit `pdfTextPage` (page, line) oder `pdfOCR` (page, block, line, confidence, region). Vorschau/Nachladen erhalten Ursprung und Quelle; ungefähre Seitenregionen und OCR-Unsicherheit werden sichtbar gekennzeichnet. Details: [PDF-OCR](PDF_OCR.md).
