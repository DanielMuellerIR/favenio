# Vorhandene Treffer reversibel filtern

Ab 0.53.0 begrenzt **Trefferliste filtern → Bearbeiten…** in beiden Apps den
bereits empfangenen Trefferstand. Der gemeinsame Kriterieneditor bietet Name,
Endung, relativen Pfad, Größe, Änderungs-/Erstellungszeit, bekannte Pixelmaße
sowie erfasste Finder-Tags und Finder-Kommentare.
UND/ODER, Negation, NFC-Vergleich, Glob und Regex folgen unverändert dem
[Python-Kriterienkern](CRITERIA.md). Inhalt und eingebettete Medienmetadaten brauchen einen neuen
Suchlauf; der Ansichtsfilter liest weder Quelldateien noch Archive erneut.

**x von y Treffern** nennt durch den Filter zugelassene Treffer und erhaltene
Quelltreffer. Bei [Gruppierung](RESULT_GROUPS.md) ist die aufgeklappte Menge
zusätzlich ausgewiesen; eingeklappte Treffer bleiben zugelassen.
**Zurücksetzen** stellt ausgeblendete Treffer wieder her. Eine neue/ersetzte
Suche sowie eine Quick-Übergabe oder geladene Aufzeichnung setzen den
Ansichtsfilter zurück. Suchkriterien und Ansichtsfilter bleiben getrennt.
Fehlende Werte erfüllen auch negative Bedingungen nicht. Bekannte Fakten sind
der gespeicherte Suchstand: Filtern aktualisiert keine Größe oder Zeit und
beweist nicht, dass die Quelldatei noch vorhanden oder unverändert ist.

## Nachschub, Auswahl und Aktionen

Während eines laufenden Suchlaufs werden neue Treffer mit denselben Kriterien
gefiltert. Bereits geprüfte Treffer müssen dafür nicht erneut durch den Kern.
Die 20er-Grenze der Schnellsuche zählt Quelltreffer, auch wenn der Ansichtsfilter
weniger davon zeigt. Sortierung und Auswahl bleiben an den ursprünglichen
strukturierten Identitäten gebunden; der sichtbare Pfad wird nie an `!/` zerlegt.

Auswahl, Öffnen, Vorschau, Pfadkopie, Entfernen und Papierkorb arbeiten auf den
sichtbaren beziehungsweise ausgewählten Zeilen. Eine ausgeblendete Auswahl
wird aufgehoben. Ein Filterwechsel bricht bisherige Vorschau-/Dateianforderungen
ab und verwirft alte Filterantworten. Entfernen aus der Trefferliste bleibt bis
zur nächsten Suche wirksam; Zurücksetzen darf diese Zeilen nicht zurückbringen.
Nach dem Papierkorb verschwinden auch betroffene Quelltreffer und Archivkinder.

**Sichtbare Treffer exportieren…** exportiert bei aktivem Filter die zugelassene
Teilmenge. Bei Gruppierung heißt der Punkt **Alle gefilterten Treffer exportieren…**
und enthält ausdrücklich auch eingeklappte Gruppen; Auswahl-Export bleibt auf
die Auswahl begrenzt. JSONL, CSV und
Inhaltsbelege bleiben unverändert. Aufzeichnungen bewahren dagegen den gesamten
beendeten Suchstand. **Alle in Favenio** übergibt ebenfalls den gesamten
Quellstand; die Haupt-App setzt die ursprüngliche Suche ohne Ansichtsfilter fort.

## Fehler, Abbruch und Grenzen

Ein neuer Filterauftrag leert zunächst die sichtbare Liste; die Quelle bleibt
erhalten. Die Zeile zeigt **Filter läuft…**. Ein fehlgeschlagener Auftrag
veröffentlicht keine teilweise geprüften Zeilen dieses Auftrags und zeigt
**Filterfehler** mit konkretem Grund im Tooltip. Zurücksetzen bleibt möglich.
Bereits erfolgreich gefilterte frühere Nachschubblöcke bleiben bei einem späteren
Fehler sichtbar; die Quelle enthält auch den ungeprüften Nachschub.

Kriterien behalten ihre Grenzen: 64 KiB JSON, 16 Ebenen, 256 Knoten,
128 Bedingungen und 4096 UTF-8-Bytes je Wert. Jeder übertragene Trefferrecord
ist auf 1 MiB begrenzt. Der Kern begrenzt einen Filterauftrag auf 20 Sekunden,
die App einschließlich Vorbereitung und Transport auf 25 Sekunden. Die Liste
wird außerhalb des Main-Threads serialisiert und zeilenweise im Kern gelesen.
Eine garantierte RSS-Obergrenze wird nicht versprochen. Neue Kriterien/Reset
beenden eigene Unterprozesse und räumen deren temporäre Listen auf; beim
App-Ende werden aktive und auslaufende Filterjobs ausdrücklich beendet.

## CLI und lokale Steuerung

```sh
favenio --filter-results results.jsonl --results-root /search/root \
  --criteria-json '{"schemaVersion":1,"root":{"id":"name","field":"name","operator":"contains","value":"Rechnung"}}'
```

`--filter-results -` liest stdin. Die optionale Wurzel ist rein lexikalisch:
Ab 0.55.0 hat die übergebene `searchRoot`-Herkunft jedes Treffers Vorrang;
`--results-root` bleibt ein Rückfall für alte Einzelwurzelstände. Mehrere
Suchbereiche verwenden keinen geratenen globalen Ersatzpfad.
Dateien verwenden ihren relativen Pfad, ein einzelner Datei-Startpfad seinen
Namen, Archivmitglieder den Pfad innerhalb ihrer Archivwurzel. Es gibt keinen
`stat`, keine Materialisierung und keinen Suchabstieg für diese Auswertung.
Kriterien und Trefferliste dürfen nicht gleichzeitig stdin verwenden.
`--validate-result-filter` prüft nur den Kriterienbaum und erlaubt keine
Filterwurzel. Such- und andere Ausgabeaktionen sind in diesem Modus unzulässig.

Passende ursprüngliche JSONL-Records werden unverändert ausgegeben. Ungültige
Records, doppelte JSON-Schlüssel und nicht endliche JSON-Konstanten werden
abgewiesen. Exit 0 bedeutet Treffer, 1 keine Treffer, 2 Fehler; eine Ausgabe
vor einem späteren Fehler ist kein vollständiges Filterergebnis.

Die lokale Steuerung liefert sichtbare Treffer. `status.resultFilter` und das
gleichnamige Feld an Ergebnisseiten nennen `active`, `loading`, `sourceCount`,
`visibleCount` sowie gegebenenfalls `criteriaJSON`/`error`. `complete` bleibt
während ausstehender oder fehlgeschlagener Filterauswertung falsch. Neue
Filterstände entwerten Ergebnisseiten-Generationen. Aufzeichnungen bleiben
vollständige Quellstände im bisherigen Format; Filter sind kein Bestandteil
der Suchkonfiguration oder des Suchberichts.

Datumsbedingungen aus Kriterienschema 2 werden einmal je Übernahme anhand eines
expliziten Bezugs aufgelöst. Weitere Batches verwenden den ersten konkreten
Beleg, ohne die relativen Bereiche erneut auszuwerten. Der Steuerungszustand
nennt `dateReferenceTime` und `dateResolution`. Nur bei solchen neuen Fragen
enthält `--filter-results` vor den Trefferzeilen ein `dateResolution`-Objekt;
bisherige Aufrufe behalten ihre bisherige Ausgabe. Auch unbekannte Datumswerte
bleiben unter Negation unbekannt. [Kalenderbereiche](DATE_RANGES.md).
