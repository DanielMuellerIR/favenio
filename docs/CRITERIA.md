# Strukturierte Suchkriterien

Der Python-Kern nimmt zusätzlich zur bisherigen Suche einen Kriterienbaum an.
Er unterstützt Name, Endung, relativen Pfad, Inhalt, Metadaten, Dateigröße,
Zeitpunkte und Pixelmaße. Beide Apps verwenden denselben grafischen Editor.

## Eingabe

`--criteria-json JSON` liest einen direkt übergebenen Baum,
`--criteria-file DATEI` eine UTF-8-JSON-Datei; `--criteria-file -` liest stdin.
Die Optionen schließen sich aus. Ein Baum genügt auch ohne Suchmuster.
Mehrere existierende Positionsargumente werden dann wie bei reinen Filtersuchen
als Startpfade behandelt; ohne Startpfad gilt der aktuelle Ordner.

Vorhandenes PATTERN, `--term` und Größen-/Datums-/Maßfilter gelten zusätzlich
per UND. Die Bedingungen besitzen eigene Operatoren und Optionen. `--regex`,
`--exact`, `--case-sensitive` und `--literal-wildcards` verändern nur die
herkömmlichen Suchbegriffe. Inhalts- und Metadatenbedingungen dürfen im Baum unterschiedliche Ziele
innerhalb desselben Objekts kombinieren; bisherige CLI-Optionen bleiben nutzbar.

`--validate-criteria` prüft ausschließlich den angegebenen Baum, ohne einen
Suchpfad zu besuchen. Erfolg schreibt ein JSONL-Objekt
`{"type":"validation","schemaVersion":1,"valid":true}` und endet mit 0;
ungültige Kriterien behalten den beschriebenen Fehler-/Exit-2-Vertrag.
Der grafische Editor nutzt diese Prüfung auch für Python-RegEx-Muster und
interpretiert Suchbedingungen nicht in Swift.

Vor Suchbeginn wird vollständig validiert. Fehler ergeben Exit 2 mit
`favenio: fehler:` auf stderr und ohne Teilergebnisse. Extraktion,
Positionsprüfung und Auflistung der Metadatenfelder sind getrennte Aktionen
und können nicht mit einem Kriterienbaum kombiniert werden.

## Schema 1

```json
{
  "schemaVersion": 1,
  "root": {
    "id": "required",
    "op": "and",
    "children": [
      {"id": "name", "field": "name", "operator": "contains", "value": "Rechnung"},
      {
        "id": "formats",
        "op": "or",
        "children": [
          {"id": "pdf", "field": "extension", "operator": "equals", "value": "pdf"},
          {"id": "word", "field": "extension", "operator": "equals", "value": "docx"}
        ]
      }
    ]
  }
}
```

`root` ist eine Gruppe oder einzelne Bedingung. Jeder Knoten braucht eine im
Baum eindeutige `id`: 1–64 ASCII-Buchstaben, Ziffern, Unterstriche oder
Bindestriche. Beim Bearbeiten bleibt die ID erhalten; die Baumposition ist
keine Identität.

Gruppen besitzen genau `id`, `op` (`and`/`or`) und eine nicht leere
`children`-Liste. Bedingungen besitzen `id`, `field`, `operator`, `value`
und optional die Bool-Felder `caseSensitive` und `negate` (Default false).
Bei `metadata` darf zusätzlich `metadataField` eines der durch
`--list-metadata-fields` aufgelisteten Felder wählen; ohne diese Option werden
alle kuratierten Textfelder durchsucht. Andere exiftool-Optionen sind unzulässig.
Unbekannte Felder, doppelte JSON-Schlüssel/IDs und andere Versionen sind Fehler.

| Feld | Verglichener Wert |
| --- | --- |
| `name` | letzter Name des Objekts, auch bei Ordnern und Archivmitgliedern |
| `extension` | letzte Endung ohne Punkt in Originalschreibweise; `archive.tar.gz` hat `gz`; Dateien ohne Endung haben den leeren Wert; Ordner haben keinen Endungswert |
| `relativePath` | Pfad einschließlich Name ab der jeweiligen Such- oder Archivwurzel |
| `content` | Inhalt mit globaler `--encoding`-Wahl (Standard UTF-8), zeilenweise; mehrere Bedingungen gelten für das ganze Objekt |
| `metadata` | kuratierte Textwerte über optionales exiftool; nur unterstützte lokale Mediendateien |
| `size` | bekannte entpackte Dateigröße in Bytes, nie Ordnergröße |
| `modified`, `created` | bekannte Änderungs-/Erstellungszeit |
| `width`, `height` | lesbare Pixelmaße; auch bei Archivmitgliedern |

Ein expliziter Datei-Startpfad wird mit seinem Dateinamen verglichen. Jede
Suchwurzel und jede verschachtelte Archivebene hat einen eigenen relativen Pfad.
Bei Archivnamen entfallen leere Komponenten und `.`; `..` bleibt Teil des
tatsächlichen Namens. Ein echtes `!/` im Namen ist keine zusätzliche Archivstufe.
Originalpfade und strukturierte Archividentitäten bleiben unverändert.

| Operator | Bedeutung |
| --- | --- |
| `contains` | wörtlicher Teilstring; auch `*`, `?` und `[` sind wörtlich |
| `equals` | wörtliche Gleichheit des ganzen Werts |
| `glob` | Glob über den ganzen Wert; `*` darf `/` überqueren |
| `regex` | Python-RegEx-Suche wie beim bisherigen `--regex` |

Die Textoperatoren gelten für die ersten fünf Felder. Bei Inhalt beziehen sich
`equals`, `glob` und Regex-Verankerungen auf eine ganze Zeile, bei Metadaten
auf einen einzelnen Wert.

Groß-/Kleinschreibung wird standardmäßig ignoriert; `caseSensitive: true`
berücksichtigt sie. `negate: true` verneint nur bekannte Ergebnisse.
Normale Textoperatoren vergleichen kanonisch gleiche Unicode-Schreibweisen
in NFC. Regex prüft ursprüngliche Codepoints; Akzente und Kompatibilitätszeichen
werden nicht entfernt oder gleichgesetzt. Namen und Inhalts-/Metadatenbelege
bleiben original. Ein Normalisierungsrest über 65.536 Zeichen in einer
fragmentierten Zeile bleibt nach Warnung ungeprüft und unter Negation unbekannt.
Bereits belegte Treffer bleiben gültig; Zeilennummern und Positionsbereiche
beziehen sich auf den ursprünglichen Inhalt.
Leere Suchwerte sind ausschließlich für `extension` mit `equals` zulässig,
um Dateien ohne Endung zu finden. NUL ist in Suchwerten unzulässig.

Zahlen- und Datumsfelder verwenden `equals`, `atLeast` und `atMost` mit
`value` als Text; `caseSensitive: true` ist dort unzulässig. Größen erlauben
ganze nichtnegative Bytes und B/KiB/MiB/GiB/TiB, Pixelmaße nichtnegative ganze
Zahlen. Zeitpunkte brauchen ISO-8601 mit ausdrücklichem Z oder Offset.
`equals` umfasst die angegebene Sekunde beziehungsweise Minute; ohne
Sekundenbruchteile schließt `atMost` die ganze Sekunde/Minute ein. Ein Zeitpunkt
mit Bruchteilen wird exakt verglichen. Der Kern validiert diese Angaben; der
Editor erhält auch einen noch unvollständigen Entwurf bis zum Übernehmen.

## Unbekannte Werte und Auswertung

Eine Bedingung ist erfüllt, nicht erfüllt oder unbekannt. Beispielsweise
besitzt ein Ordner keinen Endungswert; eine Endungsbedingung bleibt bei ihm
auch mit Negation unbekannt und ergibt keinen bewiesenen Treffer.

- UND: ein sicher falsches Kind entscheidet gegen die Gruppe; andernfalls
  verhindert ein unbekanntes Kind einen bewiesenen Treffer.
- ODER: ein sicher wahres Kind entscheidet für die Gruppe; andernfalls bleibt
  eine Gruppe mit unbekannten Kindern unbekannt.
- Nur ein sicher wahrer Baum erfüllt das Kriterium.

Die Prüfung läuft in Kostenphasen: Name/Endung/Pfad, Dateifakten, Maße,
Metadaten, Inhalt. Innerhalb derselben Kostenstufe bleibt die Eingabereihenfolge
erhalten. Bisherige UND-Filter werden in derselben Reihenfolge angewendet.
Ein entscheidender Zweig bleibt bewiesen; ein billiger ODER-Treffer öffnet
keinen Inhaltsleser und startet kein exiftool. Ein abgelehnter Container-Treffer
verhindert nicht den Abstieg zu dessen eigenen Archivmitgliedern.

Inhaltsbedingungen teilen einen fortsetzbaren Leser, auch mit den bisherigen
Inhaltsbegriffen. ODER darf beim ersten bewiesenen Zweig enden, selbst wenn
ein später eingegebener Begriff zuerst vorkommt. Negative Inhaltsbedingungen
brauchen zum Beweis der Abwesenheit das vollständige Objekt. Ein leeres
lesbares Objekt enthält keinen nichtleeren Begriff; ein Ordner, ein Lesefehler
ersetzte ungültige Zeichenfolgen oder eine wegen ihrer Länge ungeprüfte
verankerte Zeile bleiben unbekannt.
Nur reine Teilstrings dürfen auf Bruchstücken überlanger Zeilen geprüft werden.

Fehlende Metadatenfelder und für Metadaten nicht anwendbare Objekte bleiben
unbekannt, auch bei Negation. Metadatenbedingungen benötigen exiftool; ohne
das Werkzeug schlägt der Suchstart mit Exit 2 fehl. Archivmitglieder besitzen
keine exiftool-Datei. Andere Zweige dürfen sie dennoch finden. Geöffnete Archive
werden für Inhaltsbedingungen nicht zusätzlich als komprimierte Rohbytes
durchsucht; bei ausgeschaltetem Archivabstieg oder einer falschen Formatendung
gilt der bisherige Rückfall auf die reguläre Datei. Archivbudgets und
Tiefengrenzen bleiben unverändert.

## Belege und Grenzen

Nur Suchen mit einem Kriterienbaum ergänzen JSONL-Treffer um `criteriaEvidence`:

```json
{
  "criteriaEvidence": [
    {"id": "name", "field": "name", "value": "Rechnung-2026.pdf"},
    {"id": "pdf", "field": "extension", "value": "pdf"}
  ]
}
```

Die Liste nennt bei UND die bewiesenen Blätter, bei ODER den ersten während der
Kostenphasen bewiesenen Zweig, nicht alle möglicherweise ebenfalls passenden
Zweige. Ein positiver Inhaltsbeleg trägt zusätzlich `line` und einen begrenzten
Zeilenausschnitt und `contentEncoding`; ein Metadatenbeleg `metadataField`. Negative Inhaltsbelege
nennen den gesuchten Begriff und den verwendeten Decoder ohne eine erfundene Fundzeile. Negative Belege
tragen `negated: true`. Belegwerte sind auf 256 Zeichen begrenzt und tragen bei
Kürzung `valueTruncated: true`; geprüft wird immer der vollständige Wert.
Bestehende Felder wie `terms`, `line` und Fakten bleiben erhalten. Textausgabe
und alte JSONL-Aufrufe ändern sich nicht.

Grenzen: 64 KiB UTF-8-JSON, 16 Knotenebenen (Wurzel = 1), 256 Knoten insgesamt,
128 Bedingungen und 4096 UTF-8-Bytes je Suchwert. Leere Gruppen sind Fehler.
Eine Konfigurationsdatei muss regulär sein; benannte Pipes werden ohne Warten
abgewiesen. Für beabsichtigte Pipelines dient der ausdrückliche stdin-Eingang.

## Gemischte Ziele

Dieser Baum verlangt einen Namen mit „Bericht“ und zwei Begriffe im selben
Dateiinhalt, auch auf unterschiedlichen Zeilen:

```json
{"schemaVersion":1,"root":{"id":"all","op":"and","children":[
  {"id":"title","field":"name","operator":"contains","value":"Bericht"},
  {"id":"first","field":"content","operator":"contains","value":"alpha"},
  {"id":"second","field":"content","operator":"contains","value":"beta"}
]}}
```

Das Schema bleibt Version 1. Alte Kerne lehnen ihnen unbekannte Felder
ab; es wird kein Zweig still entfernt. Alte Vorlagen behalten die bisherige
Bedeutung ihrer Felder. Der Editor erhält ihm unbekannte Bäume als Rohtext.

## Kombination mit Inhaltssuche

Eine Datei `criteria.json` nach obigem Beispiel kann kombiniert werden:

```sh
./favenio.py --json --criteria-file criteria.json --content Kundennummer Dokumente/
cat criteria.json | ./favenio.py --json --criteria-file - Dokumente/
```

Mit `--content` gilt die Roharchivsemantik samt gewählter Inhaltskodierung.
Mit `--document-text` prüfen Inhaltsbedingungen die PDF-/DOCX-/ODT-/EPUB-/XLSX-/PPTX-Projektion mit
Seiten- beziehungsweise Teil-/Absatzbelegen; siehe [Dokumenttext](DOCUMENT_TEXT.md).

## Vorlagen, Übergabe und Aufzeichnungen

Beide Apps verwenden dieselbe Kriterienkomponente. In Quick steht sie unter der
normalen Suchzeile; komplexe Gruppen öffnen sich in einem vergrößerbaren Blatt.
Die Suchoption `criteria` transportiert den unveränderten JSON-Rohtext.

Vorlagen mit Kriterien werden als Format 2 gesichert. Vorlagen ohne Kriterien
behalten Format 1; beide Versionen werden gelesen. Kriterien aus Dateien der
Version 0.40.0 mit Formatnummer 1 bleiben erhalten und werden beim Sichern auf
Format 2 umgestellt. Unbekannte Formatversionen,
doppelte Kriterienoptionen und Kriterien über 65.536 UTF-8-Bytes werden
abgewiesen. Format 2 weist auch unbekannte Optionen ab. Eine nicht darstellbare
Bedingung bleibt als Rohtext erhalten; der Editor bietet einen ausdrücklichen
Ersatz an, und ein Suchstart meldet den konkreten Fehler des Kerns.
Vorlagendateien sind auf 8 MiB begrenzt; ein fehlgeschlagenes Sichern erhält die
vorherige Datei.

Quick prüft vor einer Übergabe mit Kriterien oder Auswahl, ob die Haupt-App
Übergabeformat 2 unterstützt. Der URL-Host `results-v2` und ein versionierter
Kopf der privaten JSONL-Datei verhindern, dass alte Apps die Frage still
vereinfachen. Trefferidentitäten und Auswahl werden unverändert übernommen.
Alte Übergaben ohne Kriterien und Auswahl bleiben lesbar. URLs sind auf
262.144 UTF-8-Bytes begrenzt, der Suchtext und Pfad jeweils auf 4096.

Die lokale Steuerung behält Protokollversion 1 und nennt ihre Kapazitäten in
`capabilities`: 262.144 Byte je Auftrag, 65.536 Byte je Kriterienbaum und
196.608 Byte je Aufnahme. Kriterienaufnahmen verwenden Schema 2;
Schema 1 bleibt lesbar, einschließlich Kriterienaufnahmen aus 0.40.0. Wiederöffnung zeigt weiterhin einen
historischen Stand ohne Neusuche. Unbekannte Versionen und zu große Aufträge
verändern die sichtbare Konfiguration nicht.

## Inhaltskriterien im Dokumenttextmodus

`--document-text` wählt für Inhaltsblätter dieselbe logische Dokumentprojektion
wie für das Suchmuster. Name/Pfad/Fakten bleiben kombinierbar; reine Namenszweige
lesen kein Dokument. Positive Belege ergänzen `documentPosition` mit Seite oder Teil/Absatz, bei EPUB zusätzlich Kapitel, und
lokaler extrahierter Zeile. Textlose oder nicht begrenzt lesbare Bereiche
bleiben unbekannt, auch unter Negation. Siehe [DOCUMENT_TEXT.md](DOCUMENT_TEXT.md).

Bei XLSX gelten Inhaltskriterien für tatsächliche projizierte Zellwerte, nicht
für unreferenzierte Shared Strings oder Formeltext. Belege nennen Blatt/Zelle
und die Art des gespeicherten Werts; fehlende Formel-Caches bleiben unbekannt.

Bei PPTX gelten Inhaltsbedingungen für die dokumentierte Folien-/Objektprojektion
mit Tabellen. Belege nennen tatsächliche Folie/Objekt/Absatz; Notizen und andere
feste Ausschlüsse bleiben außerhalb dieser Projektion. Defekte angefragte Teile
oder erreichte Grenzen bleiben unter Negation unbekannt.

## Kalenderwerte in Schema 2

Für `modified` und `created` darf `value` zusätzlich einen typisierten festen
oder relativen Kalenderbereich enthalten. Der ganze Baum nennt dann
`schemaVersion: 2`; Text- und bisherige rohe ISO-Werte bleiben erhalten.
`equals` prüft den gesamten Bereich, `atLeast` dessen Untergrenze und `atMost`
dessen inklusive Obergrenze. Negation verändert unbekannte Zeitwerte nicht in
einen sicheren Treffer. Auflösung, Präzision und Migration: [Kalenderbereiche](DATE_RANGES.md).

## Finder-Werte in Schema 3

Die CLI ergänzt `finderTags` und `finderComment` als eigene Textfelder.
Schema 3 erhält die bisherigen Felder einschließlich der Kalenderwerte.
Fehlende Attribute, Lesefehler und Archivmitglieder-Eigenschaften bleiben
unbekannt; bekannte leere Bestände sind davon unterschieden. Beide Apps erzeugen
und übernehmen Schema 3 im gemeinsamen Editor und Ansichtsfilter. Finder-Bäume
verwenden Konfigurationsformat 4; Vorlagen, Quick und Aufzeichnungen mit
Finder-Fragen oder erfassten Finder-Werten verwenden Format 5. Alte Fragen
bleiben in ihren bisherigen Formaten lesbar.
Daten, Grenzen und Beispiele: [Finder-Eigenschaften](FINDER_METADATA.md).

Eine zusätzlich aktive [lokale Lesepolitik](LOCAL_CONTENT.md) benötigt
Konfigurationsformat 5 und Vorlagen-/Quick-/Aufzeichnungsformat 6; die bisherigen
Finder-/Kalenderbelege und Fähigkeiten bleiben dabei erhalten.
