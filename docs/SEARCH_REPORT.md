# Begrenzter Suchbericht

`--json --search-report` ergänzt den JSONL-Suchstrom um Objekte mit
`type: "searchReport"` und `schemaVersion: 1`. Ohne diese Option ändern sich
Trefferausgabe, stderr und Exit-Codes nicht. Berichtsstände sind kumulativ:
Anfang, höchstens vier Zwischenstände pro Sekunde bei laufender Aktivität und
Ende. Es gibt keine zusätzliche Suche und keinen Vollscan zur Berichterstellung.

Beide Apps fordern diese Records an. „Suchbericht…“ öffnet dieselbe gemeinsame
Ansicht mit Abschlusszustand, Gründen, gezählten Ereignissen, gekürzten Beispielen,
Kriterien und Grenzen. „Bericht exportieren…“ schreibt ausdrücklich auf Anforderung
UTF-8-JSON über die vorhandene Hintergrund-Exportqueue mit atomarem Dateiaustausch.
Der Stand wird vor dem Sichern-Dialog festgehalten. Während der Suche exportiert
man einen vorläufigen Stand; ein späterer Abschluss verändert die Datei nicht.

## Zählung und Grenzen

Gezählt werden **Ereignisse, keine eindeutigen Objekte**. Mehrere Probleme am selben
Objekt können mehrfach zählen. Ein abgeschnittener Ordner ist ein Ereignis;
wie viele Dateien darunter liegen, bleibt unbekannt. Nachweislich nicht erfüllte Suchkriterien
sind keine Auslassung. Eine nicht belegbare Bedingung bleibt dagegen als
`criterionUnknown` sichtbar; angefragte unbekannte Größen-/Datumsfakten als
`factUnavailable`. Die Suche hält keine wachsende Menge aller betroffenen Pfade.

- Festes Grundregister; unbekannte Gründe sind ein Programmierfehler. Neue Leser
  ergänzen definierte Kennungen mit Kategorie und Anzeigetext im Python-Kern.
- Höchstens drei unterschiedliche Beispiele je Grund, jeweils 256 ursprüngliche
  Codepoints. `truncated` nennt Kürzung; kaputte Namensbytes erscheinen als U+FFFD.
  Die Anzeige maskiert Steuerzeichen. Beispiele sind keine wiederherstellbare
  Quell-/Archividentität und dürfen nicht zum Öffnen oder Extrahieren dienen.
- `count` sättigt bei 2^53−1; `countCapped: true` bedeutet „mindestens“ diesen Wert.
- Die vollständige Konfiguration umfasst höchstens 65.536 Byte ASCII-JSON. Darüber
  steht ausdrücklich `{truncated: true, jsonPrefix: ...}` (höchstens 32.700 ASCII-Zeichen im Prefix, damit auch dessen JSON-Maskierung in 64 KiB passt); vollständige Kriterien
  lassen sich dann nicht aus dem Bericht rekonstruieren.
- Ein Record bleibt unter 262.144 UTF-8-Byte. Nicht-ASCII-Beispiele werden direkt als UTF-8 geschrieben, damit auch astrale Zeichen bei vollem Grundregister in diese Grenze passen. Die Apps validieren diese Grenze, höchstens
  64 Gründe und die Beispiel-/Zählgrenzen. Der vorhandene Runner behält nur den
  letzten Stand und transportiert ihn in seinen begrenzten Main-Queue-Paketen.
  stderr wird weiterhin unabhängig und nebenläufig geleert.

## Record und Abschluss

`runID` ist die UUID des Kernlaufs; `startedAt` und `capturedAt` sind Unix-Zeiten.
`configuration` enthält angefragte Optionen, tatsächlich verwendete Startpfade,
den validierten Kriterienbaum (auch aus Datei/stdin), effektive Archivtiefe und
feste Leser-/Kataloggrenzen. Die angeforderte Kodierung bleibt erhalten; der
Bericht ersetzt keine Decoder- oder Positionsbelege eines Treffers. Ganze Zahlen
der Konfiguration außerhalb des exakt darstellbaren JSON-Double-Bereichs
(±(2^53−1)) werden als Dezimalstrings transportiert; große Größenfilter bleiben
dadurch auch beim Export exakt.

`counting` ist `events`. `reasons` enthält je Grund `id`, `category`, `label`,
`count`, `countCapped` und `examples`. `reportLimits` beschreibt die Deckel.
Die Kategorien sind `intentional`, `readError` und `budget`.

`state` des Kerns ist `running`, `finished`, `cancelled` oder `failed`.
SIGTERM/SIGHUP/KeyboardInterrupt versuchen einen abschließenden Stand; bei
SIGKILL oder geschlossenem Verbraucher ist keine Schlusszeile zugesagt.
Die Apps kennzeichnen ihren beobachteten Abbruch/Fehler selbst, einschließlich
Abbruch vor Prozessstart. Quick verwendet `limitReached` für seine 20-Treffer-Grenze.
Übernommene Treffer besitzen keinen ursprünglichen Bericht: `recorded`, Quelle
`frontend`. Ein Bericht vor dem ersten Kernrecord enthält den sichtbaren Auftrag
und ist als vorläufiger Frontendstand kenntlich. Laufwechsel übernehmen keine alten
Gründe. Exporte ergänzen `exportedAt`, Frontendabschlüsse `observedAt`,
`warningCount` nur bei bekanntem abschließendem Prozessstand und gegebenenfalls
`error`. Nach einem Abbruch ohne Abschlussrecord sind Zähler lediglich der
zuletzt empfangene Stand; eine unbekannte Warnungszahl wird nicht als null erfunden.

`coverage: "withinRequestedScope"` gibt es ausschließlich bei regulärem Abschluss
ohne gemeldete Auslassung/Warnung. Sonst gilt `incomplete`. Auch der erstere Wert
beweist weder vollständiges Lesen jeder Datei noch unbeschädigte Archive: Das
bewusste frühe Leseende bei ausreichendem Treffer bleibt erhalten. Ein Bericht ist
keine Integritätsprüfung und keine Zahl vollständig untersuchter Dateien.

## Stabile Gründe

| Kategorie | Kennungen |
| --- | --- |
| Absichtlich | `excludedPattern`, `hidden`, `folderDepth`, `symlinkDirectory`, `archiveDepth`, `archiveMetadata`, `metadataUnsupported` |
| Technisch | `permissionDenied`, `readError`, `damagedArchive`, `notRegularFile`, `metadataUnavailable`, `invalidDecoding`, `toolUnavailable`, `criterionUnknown`, `factUnavailable` |
| Budget | `archiveMemberBytes`, `archiveTotalBytes`, `archiveRatio`, `archiveListingBytes`, `archiveMemberCount`, `lineTooLong`, allgemeines `archiveBudget` |

Archivkennungen beruhen wie der bestehende Abstieg zunächst auf Endungen.
`archiveDepth` erklärt den ausgelassenen Abstieg, nicht einen Nachweis, dass
Rohbytes tatsächlich ein Archiv sind. Ohne Werkzeug bleiben Rohdateisuche und
vorhandener Rückfall erhalten; `toolUnavailable` erklärt die fehlende
Archivabdeckung. Keine neue Archivtiefen-Oberfläche ist dafür erforderlich.

Die lokale Steuerung liefert mit `report` und aktueller Steuerungs-`runID` den
festgehaltenen Stand, auch während der Suche. Diese äußere Laufkennung und die
Kern-`runID` im Bericht gehören zu verschiedenen bestehenden Prozessschichten.
`status` nennt `reportRunID`, `reportState` und `coverage`; `complete` verlangt
regulären Abschluss ohne gemeldete Auslassungen. Veraltete Laufkennungen werden
abgewiesen. Der Leseweg schreibt selbst keine Datei.

## Dokumenttext

Das Register ergänzt `documentUnsupported` (absichtlich), `documentHelperUnavailable`,
`documentEncrypted`, `documentDamaged`, `documentNoText`, `documentReadError`,
`documentSourceChanged` (technisch), sowie `documentLimit` und `documentTimeout`
(Budget). Textlose angefragte Seiten können leere Seiten oder Scans sein; eine
Abwesenheit wird dort nicht bewiesen. Dateitypen außerhalb der PDF-/DOCX-/ODT-/EPUB-/XLSX-/PPTX-Leser werden
ausdrücklich ausgelassen. Feste Dokumentgrenzen und die ausdrücklichen DOCX-Textausschlüsse stehen in `fixedLimits`.
DOCX verwendet vorhandene `document*`-Gründe für fehlende/beschädigte Teile,
Leserfehler und Grenzen sowie die bestehenden `archive*`-Budgetgründe. Das
Register bleibt bei 64 Gründen.
Zählung, Recordgrößen und Drosselung bleiben unverändert. Siehe
[Dokumenttext](DOCUMENT_TEXT.md).

ODT/EPUB verwenden dieselben Dokumentgründe und Paketdeckel. Ihre festen
Textausschlüsse und EPUB-Rendition-/Whitespace-Politik stehen in `fixedLimits`.
Ein bereits angefragter defekter EPUB-Teil bleibt auch bei späterem Treffer sichtbar.


XLSX verwendet dieselben document-/archive-Gründe. fixedLimits nennt Blatt-/Zell-/
Stringcachedeckel, gespeicherte Formelergebnisse, unformatierte Zahlen und die
festen Textausschlüsse. Fehlende Caches und ungültige Zellwerte bleiben unbekannt;
bei späterem positivem Zellbeleg verschwinden angefragte Fehler nicht aus dem
Bericht. Das Register bleibt bei 64 Gründen.

PPTX verwendet dieselben 64 Gründe. fixedLimits nennt Folien-/Objekt-/Tabellenzell-/Zeilen-
grenzen, Notizen null, ausgeblendete Folien enthalten, XML-Objektreihenfolge und
feste Ausschlüsse einschließlich Notizen, Master/Layout und Feldern. Angefragte
fehlende/beschädigte Teile verhindern negative Beweise; kein Berichtsvollscan.

Kalenderfragen tragen ihre tatsächliche Auflösung separat unter `dateResolution`:
ursprüngliche Frage, ausdrücklicher Referenztext, IANA-Zone sowie inklusive
ISO-/Epochgrenzen und gegebenenfalls exklusive Folgegrenze. Diese auf64KiB und
130Einträge begrenzten Belege gehen bei Kürzung der allgemeinen Konfiguration
nicht verloren. Historische Anzeigen übernehmen sie unverändert; Fortsetzungen
und Filterbatches verwenden ihre konkreten Grenzen.
Siehe [Kalenderbereiche](DATE_RANGES.md).

Der lokale Lesemodus ergänzt `configuration.local_only` und die Gründe
`localContentNotLocal` (absichtlich ausgelassen) sowie `localContentUnknown`
(technisch unbekannt). Vertrag und Grenzen: [Lokale Inhalte](LOCAL_CONTENT.md).

## Bild-OCR

`configuration.ocr` erfasst die angefragte Option; sie wirkt im Dokumenttextmodus.
`ocrProjection` erklärt, dass erkannter Bildtext keine vollständige Abdeckung
des Originals beweist. `ocrHelperUnavailable`, `ocrDamaged` und `ocrReadError`
sind technische Einschränkungen; `ocrLimit` und `ocrTimeout` sind Budgets.
`ocrMultipleFrames` und `ocrNoText` erklären ausgelassene Mehrbilddateien oder
fehlenden ausreichend sicheren erkannten Text. Die festen Grenzen nennen Sprachen,
Pixel/Kanten, Textbereiche, Textbytes, Mindestmodellwert und Mindesttexthöhe.
Alle Gründe bleiben begrenzt gezählte Ereignisse, keine Vollzählung von Bildern.

Bei vielen Gründen und langen Unicode-/Steuerzeichenbeispielen werden die
sichtbaren Beispieltexte zusätzlich gekürzt, bis der gesamte Bericht seine
Bytegrenze einhält. `truncated` kennzeichnet dies; Gründe und Ereigniszähler
werden nicht entfernt. Die gespeicherten begrenzten Beispiele bleiben für
spätere kleinere Momentaufnahmen unverändert.

PDF-OCR ergänzt `pdfOCRProjection` (bewusst begrenzter Originalbezug) und `pdfOCRLimit` (Seiten-/Renderbudget). Der Bericht nennt 128 Seiten, 16 gerenderte Seiten, 150 DPI, sechs Millionen Pixel je Seite, 32 Millionen insgesamt, Kante 4096 und zehn Sekunden. OCR-/PDF-Fehlergründe bleiben getrennt. [Verhalten und Grenzen](PDF_OCR.md).
