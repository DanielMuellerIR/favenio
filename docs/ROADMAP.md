# Funktionsumfang

Stand: 2026-10-18. Aktueller Kernstand: Favenio 0.64.0.

Der Kriterienbaum für Name, Pfad, Inhalt, Metadaten, Größe, Datum und Bildmaße
ist im CLI-Kern und in beiden Editoren umgesetzt.
Der gewählte Funktionsumfang ist umgesetzt; Unterstützung und Grenzen stehen
im jeweiligen Abschnitt und den verlinkten Verträgen.
Die Reihenfolge bildet fachliche Abhängigkeiten ab; sie ist kein Release-Termin.
Favenio bleibt lokal und indexlos. Der Python-Kern enthält die einzige
Suchlogik und bleibt ohne Pflicht-Zusatzpakete nutzbar.

## 1. Kombinierbare Kriterien mit verschachtelten Gruppen

Der Kern unterstützt bereits verschachtelte Gruppen und negative Bedingungen
über `--criteria-json` / `--criteria-file`. Schema, Grenzen und Belege stehen in
[CRITERIA.md](CRITERIA.md). Beide Apps bieten denselben zuschaltbaren Zeileneditor
mit verschachtelten UND-/ODER-Gruppen und versionierten Transportwegen.

Name, Endung, relativer Pfad, Inhalt, Metadaten, Dateigröße, Zeitpunkte und
Bildmaße lassen sich in einer Suche kombinieren. Jede Gruppe verbindet
ihre Bedingungen mit UND oder ODER; Gruppen dürfen weitere Gruppen enthalten.
Negative Bedingungen unterscheiden sicher nicht erfüllte von unbekannten
oder nicht lesbaren Werten.

Die Oberfläche folgt dem Prinzip von Mail-Regeln und intelligenten Playlists:

- Eine Zeile enthält Feld, Operator und den dazu passenden Werteditor.
- `+` ergänzt eine Bedingung in der aktuellen Gruppe.
- `⌥+` ergänzt eine verschachtelte Gruppe. Ein sichtbarer Knopf
  „Gruppe hinzufügen“ bietet dieselbe Funktion.
- Der Gruppenkopf wählt „Alle Bedingungen (UND)“ oder
  „Mindestens eine Bedingung (ODER)“.
- Einrückung und Gruppengrenzen zeigen die Verknüpfung an.

Beispiel:

```text
Alle Bedingungen (UND)
  Name enthält „Rechnung“
  Mindestens eine Bedingung (ODER)
    Endung ist „pdf“
    Endung ist „docx“
  Inhalt enthält „Kundennummer“
```

PDF-Seitenbelege, DOCX-/ODT-Absatzbelege und EPUB-Kapitelbelege sowie XLSX-Zellbelege und PPTX-Folien-/Objektbelege sind umgesetzt.
Die bisherige Rohinhaltssuche bleibt erhalten.

Haupt-App und Schnellsuche verwenden denselben Kriterienbaum und Editor.
Vorlagen, Quick-Übergaben, lokale Steuerung und Aufzeichnungen transportieren
ihn verlustfrei mit ausdrücklichen Versions- und Größenprüfungen. Bisherige einfache
Suchfragen und CLI-Aufrufe bleiben nutzbar.

## 2. Unicode und Textkodierungen

Kanonisch gleichwertige Unicode-Schreibweisen sind für normale Namens-,
Inhalts- und Metadatensuche sowie Ausschlüsse umgesetzt. Originalnamen,
Archividentitäten und Fundbelege bleiben erhalten; Regex arbeitet auf dem
Originaltext. UTF-16 mit BOM-Automatik und eine begrenzte ausdrückliche
Kodierungswahl sind umgesetzt; die Editorübergabe bindet Originalbytes,
dekodierten Text und ursprüngliche UTF-16-Position. Die Fundstellenvorschau
erhält Kodierung und Originalposition. Akzententfernung, unscharfe Suche und
heuristische Kodierungsraterei sind nicht vorgesehen.

## 3. Fundstellen mit Kontext

Eine zuschaltbare Vorschau zeigt den ersten Fund mit begrenztem Umfeld und
Hervorhebung. Weitere Fundstellen und mehr Kontext werden auf
Anforderung begrenzt und abbrechbar nachgeladen. Quellenänderungen bleiben
erkennbar. Das frühe Leseende der normalen Suche bleibt erhalten.

## 4. Nachvollziehbare Suchabdeckung

Auslassungen werden nach stabilen Gründen zusammengefasst und mit begrenzten
Pfadbeispielen erklärt: etwa fehlende Rechte, beschädigte Archive oder erreichte
Budgets. Beide Apps bieten einen Suchbericht mit JSON-Export auf Anforderung;
er hält Konfiguration, Grenzen und den tatsächlichen Abschlusszustand fest.
Weitere definierte Gründe künftiger Dokumentleser können daran anschließen.
Der [Berichtsvertrag](SEARCH_REPORT.md) beschreibt Ereigniszählung und Grenzen.
Absichtliche Ausschlüsse und technische Fehler werden unterschieden.

## 5. Logischer Dokumenttext

Ein eigener Dokumenttextmodus liest PDF-Textebenen, DOCX-/ODT-Absätze und
EPUB-Kapitel in Lesereihenfolge sowie XLSX-Zellwerte und PPTX-Folien-/Tabellentext; siehe
[Dokumenttext](DOCUMENT_TEXT.md). Die unterstützten Formate liefern lesbaren Inhalt statt technischer
Containerdateien:

| Format | Textbezug |
| --- | --- |
| PDF mit Textebene | Seite (umgesetzt) |
| DOCX | Teil und Absatz, zusammengeführte Textläufe und Tabellen (umgesetzt) |
| ODT | Absätze und Tabellen (umgesetzt) |
| EPUB | Kapitel in Spine-Lesereihenfolge und Absätze (umgesetzt) |
| XLSX | Blatt und Zelle, aufgelöste gemeinsame Stringtabellen (umgesetzt) |
| PPTX | Folie, Objekt, Absatz und Tabellenzelle (umgesetzt) |

Dokumente innerhalb von Archiven sind nach denselben begrenzten Verträgen
lesbar. Optionale lokale Helfer extrahieren Daten; das Matching bleibt
im Python-Kern. Passwortschutz, fehlende Textebenen, nicht unterstützte Teile
und Extraktionsfehler werden erklärt. Die bisherigen technischen Archiv-
und Rohinhaltssuchen bleiben eigenständig nutzbar.

## 6. Trefferlisten und Archivnavigation

Reversible Ansichtsfilter auf bekannten Trefferwerten sind in beiden Apps umgesetzt;
Quellmenge, sichtbare Menge und Auswahl bleiben getrennt. [Vertrag](RESULT_FILTER.md).

- Umgesetzt: bekannte Trefferwerte reversibel filtern, mit sichtbarer Anzahl
  „angezeigt von insgesamt“ und vollständigem Zurücksetzen.
- Umgesetzt: nach Ordner, Endung oder äußerem Quellarchiv gruppieren, mit
  getrennten Überschriften, Klappzuständen und Trefferzahlen.
- Umgesetzt: „Quellarchiv im Finder zeigen“ als eigene Aktion neben der bisherigen
  Finder-Anzeige einer materialisierten Datei, mit nachvollziehbarer Archivkette.
  [Vertrag](RESULT_GROUPS.md).
- Auswahl, Dateiaktionen, Export und lokale Steuerung eindeutig auf die
  jeweils erkennbare Treffer-/Auswahlmenge beziehen.

## 7. Suchbereiche, Datumshilfen und Finder-Eigenschaften

- Mehrere geordnete Suchwurzeln in beiden Apps sind umgesetzt, einschließlich
  Überlappungen, Herkunft und Migration alter Einzelwurzelkonfigurationen;
  [Vertrag](SEARCH_ROOTS.md).
- Umgesetzt: Kalender-/Uhrzeiteingaben sowie „Heute“, „Letzte sieben Kalendertage“
  und „Dieser Monat“, mit explizitem Laufzeitpunkt, Zeitzone und überprüfbaren
  konkreten Grenzen. Vorlagen unterscheiden feste und bei jedem neuen Start
  aufgelöste Fragen; [Vertrag](DATE_RANGES.md).
- Umgesetzt: Finder-Tags und Finder-Kommentare als eigene lokale Kriterien neben
  eingebetteten Medienmetadaten, mit grafischen Kriterien und Ansichtsfilter,
  Vorschau, optionalen Spalten und versionierten App-Transporten;
  [Vertrag](FINDER_METADATA.md).

## 8. Lokal vorhandene Inhalte und Cloud-Platzhalter

Die ausdrückliche Option „Nur lokal vorhandene Inhalte lesen“ ist für iCloud
umgesetzt. Namen und bekannte Fakten von Platzhaltern bleiben nutzbar;
nicht gelesene oder unbekannte Inhalte werden erklärt. Die macOS-Sperre gilt
auch für Archiv-/Dokumentleser und Vorschau-Nachladen. Weitere Anbieter bleiben
bis zu einer zuverlässigen Prüfung offen. Eine allgemeine Offlinegarantie wird
nicht zugesagt; [Unterstützung und Grenzen](LOCAL_CONTENT.md).

## 9. OCR und Miniaturen

Lokale, ausdrücklich zuschaltbare OCR für einzelne Bilder und Screenshots ist
umgesetzt; [Vertrag](OCR.md). Textlose PDF-Seiten sind ebenfalls ausdrücklich zuschaltbar, mit begrenztem Rendering; [Vertrag](PDF_OCR.md). Vorhandene PDF-Textebenen werden
bevorzugt. OCR-Fundstellen bleiben als erkannter Text gekennzeichnet und
unterliegen eigenen Zeit-, Seiten-, Pixel- und Textlimits.

Eine umschaltbare Miniaturansicht erleichtert in beiden Apps die Auswahl von
Bildtreffern. Sie verwendet dieselben Trefferidentitäten und Aktionen wie die
Tabelle sowie begrenzte lokale Hintergrundaufträge und Caches; [Vertrag](THUMBNAILS.md).

## 10. Explizite Dublettenprüfung

Eine auf Anforderung gestartete Prüfung gruppiert bytegleiche normale Dateien
innerhalb einer festgehaltenen Trefferliste oder Auswahl; [Vertrag](DUPLICATES.md).
Archivmitglieder werden über gemeinsame befristete Materialisierungen einbezogen; Quellwachen erhalten die Bindung während des Vergleichs.
Größe allein belegt keine Gleichheit; vollständiges Lesen gehört ausdrücklich
zu dieser Prüfung. Fortschritt, Abbruch, geänderte Quellen, Hardlinks und
Lesefehler bleiben nachvollziehbar. Keine automatische Löschung oder
Archivänderung ist vorgesehen.

## Vielleicht sinnvoll: gespeicherte Suchstände vergleichen

Der Vergleich gespeicherter Suchstände ist nur als Idee vorgemerkt und gehört
nicht zum gewählten Funktionsausbau. Ein späterer Entwurf müsste zuerst den
konkreten Nutzen, vergleichbare vollständige Läufe, begrenzte Aufzeichnungen
und die Unterscheidung zwischen geänderten Fakten und geänderten Inhalten klären.

## Gemeinsame Abschlusskriterien

Neue Funktionen benötigen passende Kern-/Transporttests und echte Prüfungen
der betroffenen Ansichten. Vorhandene Suchverträge, strukturierte Archiv-
identitäten, Begrenzungen, Abbruchverhalten und optional fehlende Fähigkeiten
bleiben nachvollziehbar. Umsetzung und Dokumentation müssen übereinstimmen;
die Roadmap wird bei tatsächlich abgenommenen Funktionen aktualisiert.
