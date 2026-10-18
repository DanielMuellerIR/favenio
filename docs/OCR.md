# Lokale Texterkennung für Bilder

**Dokumenttext → Weitere Filter → Bild-OCR im Dokumenttext** beziehungsweise
`--document-text --ocr` liest zusätzlich Text aus einzelnen Bildframes. OCR ist
standardmäßig aus. In den Suchzielen Name, Inhalt und Metadaten bleibt `--ocr`
ohne Wirkung. PDF-Textebenen und bisherige Dokumentleser bleiben unverändert;
Scan-PDFs und Bilder innerhalb von Office-Dokumenten werden hier nicht per OCR gelesen.

```sh
./favenio.py --document-text --ocr --json --content-preview München ~/Pictures
./favenio.py --document-text --ocr --local-only --search-report --json Rechnung ~/Documents
```

## Erkennung und unterstützter Umfang

Der optionale native Helfer `favenio-ocr` verwendet Apple Vision, Request-Revision
3 auf macOS 13 oder neuer, den genauen Erkennungspfad und die festgelegten Sprachen
`de-DE`, `en-US` in dieser Reihenfolge. Die Verfügbarkeit beider Sprachen wird
geprüft; fehlende Fähigkeiten bleiben unbekannt. Sprachkorrektur ist abgeschaltet.
Muster, Unicode-/Regex-Regeln, mehrere Begriffe und Kriterien entscheidet allein
Python. Es gibt keinen Index und keinen Cloud-OCR-Auftrag.

Apple beschreibt die Verarbeitung auf dem Gerät in
[Recognizing Text in Images](https://developer.apple.com/documentation/vision/recognizing-text-in-images).
Sprachen und Erkennungsgrenzen stehen unter
[VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest).

Unterstützt werden einzelne PNG-, JPEG-, TIFF-, BMP-, GIF- und HEIC/HEIF-Bildframes
mit von ImageIO lesbarem RGB-/Graustufenmodell und höchstens 16 Bit je Komponente.
Mehrbilddateien werden ausgelassen, statt still nur den ersten Frame zu durchsuchen.
Nicht lesbare Eigenschaften führen zu einer erklärten Auslassung. Die eigene
Qualitätsprobe umfasst deutsch-/englischsprachige Bildschirmtexte, einen echten
eigenen App-Screenshot sowie synthetische Papierfotos mit Drehung und Unschärfe.
Dies ist keine Qualitätsgarantie für beliebige Kamerafotos, Handschrift, Schriften
oder Aufnahmesituationen.

Vision berücksichtigt die EXIF-Orientierung. Textbereiche werden nach oberer
Kante von oben nach unten und danach von links nach rechts geordnet. Die Reihenfolge
ist eine geometrische Projektion, keine zugesagte semantische Leserichtung;
Spalten, Tabellen oder schräger Text können anders als beim menschlichen Lesen
geordnet sein. Jeder erkannte Bereich bleibt eine eigene Texteinheit; Suchmuster
reichen nicht über Bereichsgrenzen. Mehrere Begriffe dürfen in verschiedenen
Bereichen desselben Bildes stehen.

## Unsicherheit und Fundstellen

Verwendet wird der beste erkannte Kandidat ab Modellwert 0,5. Dieser Wert ist
keine gemessene Wahrscheinlichkeit und beweist auch bei 1,0 keine Fehlerfreiheit.
Auch nicht erkannte, kleine oder schwache Schrift kann im Bild vorhanden sein.
Deshalb erklärt `ocrProjection` die eingeschränkte Abdeckung; OCR kann keine
Abwesenheit im Original beweisen. Negative Inhaltsbedingungen bleiben unbekannt.
Ein unabhängiger bekannter Name-/Faktenzweig kann weiterhin entscheiden.

`contentEncoding: "vision-ocr-text-v1"` bezeichnet die erkannte Textprojektion.
`documentPosition` ergänzt:

```json
{"kind":"imageOCR","block":1,"line":1,"confidence":0.9,"region":[0.1,0.2,0.5,0.1]}
```

`block` ist der 1-basierte erkannte Bereich, `line` dessen Textzeile. `region`
enthält x, y, Breite und Höhe zwischen 0 und 1 im orientierten Bild, Ursprung
unten links; der Bereich gilt für den gesamten erkannten Textblock und ist
ungefähr. Das ist kein exakter Bildbereich eines einzelnen Suchworts und kein
Dateibyteoffset. Die Vorschau kennzeichnet OCR, Modellwert und Region sichtbar.
Hervorhebungen beziehen sich auf den erkannten Ausschnitt, nicht auf garantierten
Originaltext oder Bildpixel. JSONL und CSV erhalten die OCR-Belege; Pfadexporte
enthalten weiterhin nur Pfade.

Nachladen verwendet den eingefrorenen Leser `query.documentReader: "vision-image-v1"`, dieselbe Quellengeneration und begrenzte Fundnummern. Ein
explizites Nachladen eines früheren OCR-Belegs kann den Leser erneut anfordern,
auch wenn die Option für den nächsten Suchlauf ausgeschaltet wurde. Es lädt kein
anderes Bild und startet keine globale Suche. Die lokale Inhaltspolitik gilt auch
für Nachladen und eine nötige Archivmaterialisierung. Ohne verfügbaren lokalen
Inhalt wird kein OCR-Helfer gestartet.

## Budgets, Helfer und Abbruch

- Höchstens 64 MiB Bilddatei oder materialisiertes Archivblatt.
- Höchstens 8192 Pixel je Kante und 12 Millionen Pixel; Eigenschaften werden vor
  dem vollständigen Bilddecodieren geprüft.
- Fünf Sekunden einschließlich Materialisierung, OCR und Suche; Nachladen hält
  zusätzlich seine bisherigen kürzeren Grenzen ein.
- Höchstens 4096 Textbereiche, 64 KiB UTF-8 je Bereich und 1 MiB insgesamt;
  Helferantwort höchstens 2 MiB. Minimale Texthöhe: 0,003 der Bildhöhe.
- Archiv-Einzel-/Gesamt-/Quotienten-/Tiefengrenzen gelten zusätzlich; bekannte
  Datei-/Maßbedingungen entscheiden vor OCR. Ein Bildkopf zählt nicht doppelt.

Die Grenzen begrenzen Eingabe und Arbeit; sie sind keine garantierte RSS-Obergrenze
von ImageIO/Vision. Bilddecode und Erkennung eines einzelnen Bildes erfolgen vor
seinem ersten Suchbeleg. Andere Bilder werden nicht nur für eine Trefferanzeige
vorausgelesen. Timeout, Mengenlimit, Mehrbilddatei, fehlender Helfer, beschädigtes
Bild und fehlender ausreichend sicherer Text haben getrennte Berichtsgründe.
Abbruch beendet und erntet eigene Helfer. Normale Dateien und Archivbilder verwenden
denselben Kernpfad und behalten ihre strukturierten Identitäten.

Der Build signiert und enthält den Helfer in beiden Apps. Die CLI findet ihn im
Bundle, unter `.build/favenio-ocr` oder im PATH. `FAVENIO_OCR_HELPER` wählt einen
expliziten ausführbaren Helfer; ein leerer Wert deaktiviert ihn. Ohne Helfer
bleiben andere Suchmodi nutzbar. Keine Python-Pflichtabhängigkeit. Die
[Bedingungen der lokalen Inhaltspolitik](LOCAL_CONTENT.md) gelten unverändert.

## Versionierte Transporte

Aktives `ocr=1` braucht Vorlagenformat 7, Quick-Übergabe 7 mit `ocrCapability: 1`,
Controller-Konfiguration 6 und Aufzeichnung 7 mit derselben Capability. Bundles
und Controller nennen OCR-Schema 1. Ältere Empfänger/Formate werden vor Übernahme
abgewiesen. Vorherige Formate bleiben ohne OCR lesbar; lokale Politik, Finder-
Snapshots und Kalenderbelege lassen sich mit OCR gemeinsam transportieren.

Textlose PDF-Seiten sind eine getrennte ausdrückliche Option (`--pdf-ocr`); sie verwenden denselben Vision-Erkenner und eigene Render-/Seitenbudgets. Siehe [PDF-OCR](PDF_OCR.md).
