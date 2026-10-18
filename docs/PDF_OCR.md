# Textlose PDF-Seiten per OCR lesen

`--document-text --pdf-ocr` beziehungsweise „Weitere Filter → Textlose PDF-Seiten per OCR lesen“ ergänzt den bestehenden PDF-Textebenenleser. Die Option ist standardmäßig aus und wirkt nur im Dokumenttextziel. Bild-OCR (`--ocr`) bleibt eine eigene Option; alte Bildsuchen beginnen dadurch keine Scan-PDF-Erkennung.

```sh
./favenio.py --document-text --pdf-ocr --json --content-preview München ~/Documents
./favenio.py --document-text --pdf-ocr --local-only --progress --search-report --json Rechnung ~/Documents
```

## Textebenen und OCR

Jede angeforderte Seite wird zuerst als vorhandene PDF-Textebene gelesen. Sobald diese mindestens ein Nicht-Leerraumzeichen liefert, wird für diese Seite keine Vision-Erkennung gestartet. Auch eine teilweise, fehlerhafte oder nur aus einer Kopfzeile bestehende Textebene wird bevorzugt. Bilder derselben Seite, Annotationen und nicht sichtbarer Text werden nicht zusätzlich per OCR ausgewertet. Der Leser behauptet deshalb keine vollständige Abdeckung des sichtbaren Originals; negative Inhaltsbedingungen bleiben mit aktiver PDF-OCR unbekannt. Positive Textbelege und unabhängige bekannte Kriterien können weiterhin entscheiden.

Nur textlose Seiten werden gerendert. Der native Helfer verwendet denselben Vision-Extraktionspfad, dieselben festgelegten Sprachen DE/EN, Revision 3 und Modellwert-/Textgrenzen wie [Bild-OCR](OCR.md). Der Helfer erhält keine Suchmuster. Er liefert ausschließlich Text und ungefähre Bereiche; Muster, Kriterien und mehrere Begriffe prüft Python. Ein Dokument wird höchstens einmal als Treffer ausgegeben, auch wenn Begriffe aus unterschiedlichen Seiten und Ursprüngen stammen. Positive Entscheidungen lesen keine weiteren Seiten allein für eine vollständigere Anzeige.

Die eigenen Versuche umfassen Scan-PDFs aus deutschen/englischen Bildschirmtexten, gedrehte Seiten und gemischte Textebenen-/Rasterseiten. Bei 150 DPI lagen die ersten Erkennungsaufrufe etwa zwischen 0,07 und 0,25 Sekunden. Dies ist keine Qualitäts- oder Laufzeitgarantie für beliebige Scans, Handschrift oder komplexe PDFs.

## Render- und Arbeitsgrenzen

- macOS 13 oder neuer für Vision-OCR; normale PDF-Textebenen behalten ihren bisherigen optionalen PDFKit-Pfad.
- Reguläre Datei, höchstens 64 MiB; der Helfer liest über einen nicht blockierenden, mit `fstat` geprüften Dateideskriptor in begrenzte Daten. PDFKit erhält Daten, keine Quell-URL.
- Höchstens 128 angeforderte Seiten pro Dokument; gegenüber dem normalen Textebenenleser mit 512 Seiten bewusst kleiner.
- Höchstens 16 gerenderte Seiten und 32 Millionen Renderpixel insgesamt pro Dokument. Bei erschöpftem Renderbudget können spätere Textebenen innerhalb der Seitengrenze weiterhin Treffer liefern.
- CropBox mit PDF-Rotation, 150 DPI, höchstens 4096 Pixel je Kante und sechs Millionen Pixel je Seite. Größere Seiten werden ausgelassen und nicht still unschärfer verkleinert. Core Graphics wendet die Seitentransformation beim Zeichnen an.
- RGB-Bitmap mit vier Bytes je Pixel: höchstens 24 MB für die eigene Renderfläche einer Seite. Die Eingabe-/Pixelgrenzen sind keine garantierte RSS-Obergrenze von PDFKit, Core Graphics oder Vision. Diese Systemframeworks können zusätzliche Decoder-/Schrift-/Erkennungscaches belegen.
- Zehn Sekunden einschließlich Materialisierung, PDF-Lesen, Rendering, OCR und Matching. Vorschau-Nachladen behält zusätzlich seine bisherigen kürzeren Grenzen.
- Die bisherigen Text-/Transportgrenzen gelten zusätzlich: 256 KiB je Textebenenseite, 4096 OCR-Bereiche/1 MiB OCR-Text je Seite, 8 MiB gesamter Dokumenttext, höchstens 2 MiB je Helferantwort. Archiv-Einzel-/Gesamt-/Quotienten-/Tiefenbudgets gelten vor und während der Materialisierung.

`pdfOCRLimit` meldet Seiten-/Rendergrenzen; `pdfOCRProjection` erklärt den bewusst begrenzten Originalbezug. Beschädigung, Verschlüsselung, fehlender/alter Helfer, fehlender ausreichend sicherer OCR-Text und Timeout bleiben getrennte Gründe. Eine leere oder wegen Renderbudget ausgelassene Seite verdeckt spätere bekannte Textbelege nicht. Abbruch beendet und erntet eigene Helfer; die Apps laufen asynchron weiter und zeigen den Abbruch als solchen.

Mit `--progress` kommen vor Seitenarbeit begrenzte JSONL-Fortschritte mit `stage: "pdfText"` beziehungsweise `"pdfOCR"`, `page` und `pages`. `path` bleibt der unveränderte sichtbare Quellpfad. Der Wechsel zur OCR wird vor der blockierenden Erkennung unmittelbar gemeldet; übrige Seiten-/Ordnerfortschritte bleiben gedrosselt. So bleibt eine zuvor gemeldete Textebenenphase nicht während der OCR stehen. Auch der erste OCR-Schritt nach einem Dokumentpfadwechsel wird unmittelbar gemeldet. Beide Apps zeigen Phase und Seitenstand am Anfang des Fortschrittstextes, damit lange Pfade die Phase nicht verdrängen.

## Belege und Transport

`contentEncoding: "pdfkit-vision-text-v1"` und der eingefrorene Leser `pdfkit-vision-v1` bezeichnen den gemischten Pfad. Eine vorhandene Textebene trägt:

```json
{"kind":"pdfTextPage","page":1,"line":1}
```

Eine OCR-Seite trägt:

```json
{"kind":"pdfOCR","page":2,"block":1,"line":1,"confidence":0.9,"region":[0.1,0.2,0.5,0.1]}
```

Die Region bezieht sich auf den gesamten erkannten Textblock in der gerenderten, gedrehten CropBox, normiert zwischen 0 und 1, Ursprung unten links. Sie ist keine genaue Wortposition oder Position im PDF-Dateibytestrom. Modellwerte sind keine Fehlerwahrscheinlichkeiten. Vorschau und CSV/JSONL erhalten Seite und Herkunft; Hervorhebungen beziehen sich auf die extrahierte beziehungsweise erkannte Textprojektion. Quellenwechsel machen Belege ungültig. Nachladen verwendet denselben eingefrorenen Leser mit denselben Grenzen und der ursprünglichen Quellbindung; es kann für einen früheren PDF-OCR-Beleg erneut OCR anfordern, auch wenn die Option für die nächste Suche ausgeschaltet ist.

Aktives `pdf-ocr=1` benötigt Vorlagen-/Quick-Format 8, Controller-Konfiguration 7 und Aufzeichnung 8 mit `pdfOCRCapability: 1`. Bundles/Controller nennen PDF-OCR-Schema 1. Vorherige Formate bleiben ohne PDF-OCR unverändert nutzbar; ältere Empfänger werden vor Übernahme abgewiesen. Kombinationen mit Bild-OCR, lokaler Inhaltspolitik, Finder-Snapshots und Kalenderbelegen behalten deren unabhängige Fähigkeiten.

Die [lokale Inhaltspolitik](LOCAL_CONTENT.md) gilt vor PDF-Öffnen, Archivmaterialisierung und Nachladen. Entfernte oder unbekannte Inhalte starten in diesem Modus keinen PDF-/Vision-Helfer. Explizites Öffnen bleibt ein eigener Vorgang. Es entstehen keine geänderten PDFs, Textebenen oder globalen OCR-Caches im Projekt.

Apple-Primärquellen: [PDFPage](https://developer.apple.com/documentation/pdfkit/pdfpage), [PDF drawing and transforms](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf/dq_pdf.html), [Vision text recognition](https://developer.apple.com/documentation/vision/recognizing-text-in-images).
