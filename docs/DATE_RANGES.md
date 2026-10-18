# Kalenderbereiche

Geändert- und Erstellt-Filter bieten in beiden Apps einen Kalenderknopf. Der
Kriterieneditor verwendet denselben Dialog. Kalender und Uhrzeit lassen sich
ohne ISO-Eingabe wählen; rohe ISO-Felder bleiben über **Rohe ISO-Eingabe**
verfügbar. Die IANA-Zeitzone ist ausdrücklich angegeben. Fehlende Ortszeiten
werden abgewiesen; für doppelt vorkommende Uhrzeiten lässt sich je Grenze die
frühere oder spätere Zeit wählen.

**Heute** umfasst den ganzen lokalen Kalendertag, **Letzte sieben Kalendertage**
heute und die sechs vorherigen Tage, **Dieser Monat** den ganzen lokalen Monat.
Spätere Uhrzeiten desselben Tages oder Monats gehören dazu. Es handelt sich
nicht um die letzten 24 beziehungsweise 168 Stunden. Ein Tag kann bei einem
Sommerzeitwechsel 23 oder 25 Stunden lang sein. Nicht auflösbare lokale
Mitternachtsgrenzen werden erklärt abgelehnt.

Der Python-Kern löst relative Fragen mit einem einmaligen, ausdrücklichen
Laufzeitpunkt auf. Alle Suchwurzeln und Kriterien teilen diesen Bezug. Ein
Ansichtsfilter verwendet die einmal aufgelösten Grenzen für alle Trefferbatches. Quick übergibt
seinen Bezug und seine konkreten Grenzen an die Fortsetzung im Hauptfenster; ein neuer manueller Start
beziehungsweise `rerun` erhält einen neuen Bezug. Historisches Öffnen übernimmt
die gespeicherten Grenzen ohne neue Zeitauflösung und ohne Suche.

Der Dialog zeigt eine Vorschau der konkreten ISO-Grenzen. Der Suchbericht und die
lokale Steuerung nennen die tatsächlich verwendete Frage, Zone, Referenz und
ISO-/Epochgrenzen des Laufs. Diese Belege bleiben auch erhalten, wenn die große
allgemeine Berichtskonfiguration gekürzt werden muss.

Vorlagen speichern entweder eine relative Frage oder feste ISO-Grenzen. Sie
speichern keinen Laufzeitpunkt. **Aufgelöste Grenzen als festen Zeitraum
übernehmen** macht aus der Vorschau eine feste Frage. Alte Vorlagen mit rohen
ISO-Feldern bleiben fest. Die Obergrenze schließt wie bisher die ganze genannte
Minute beziehungsweise Sekunde ein; mit angegebenem Sekundenbruch gilt genau
der genannte Zeitpunkt. Intern endet ein Kalenderintervall unmittelbar vor der
nächsten exklusiven Grenze (`nextafter`), ohne deren Mitternacht einzuschließen.

## Datenvertrag

Neue Kalenderfragen verwenden Kriterienschema 2, Vorlagenformat 4,
Controller-Konfiguration 3, Aufzeichnung 4 und Quick-Übergabe 4. Die bisherigen
Formate bleiben für unveränderte Fragen verfügbar. In Kombination mit Finder-
Eigenschaften werden Kriterienschema 3, Konfiguration 4 und Vorlagen/Quick/
Aufzeichnungen 5 verwendet; Kalenderfrage, Bezug und Grenzen bleiben erhalten.
Ältere Formate dürfen neue
Kalenderfragen nicht still interpretieren. Schema- und Größenfehler werden vor
der Übernahme zurückgewiesen.

Ein relativer Wert ist
`{"kind":"relative","preset":"today","timeZone":"Europe/Berlin"}`.
Weitere Presets heißen `last7CalendarDays` und `thisMonth`. Ein fester Wert nennt
`kind: fixed`, `lower`, `upper` und `timeZone`. Neue strukturierte ISO-Werte und
Laufzeitpunkte sind ohne Rand-Leerraum; die bisherigen rohen CLI-ISO-Filter
behalten ihre bisherige Eingabegrammatik.

`--date-ranges-json` nimmt `{"schemaVersion":1,"ranges":{"modified":…}}`
entgegen; `created` ist ebenfalls möglich. Ein Bereich und rohe Von-/Bis-Grenzen
desselben Felds schließen sich aus. `--date-reference-time` nennt den expliziten
Bezug mit Z oder Offset. `--resolve-date-range` prüft einen Bereich ohne Suche
und liefert dessen Grenzen. Die lokale Operation `start`/`replace` kann einen
expliziten `dateReferenceTime` annehmen; ohne ihn erfassen die Apps den Bezug
selbst. Auflösungsbelege sind auf 130 Einträge und 64 KiB begrenzt. Unbekannte
Zeitzonen haben keinen stillen lokalen Ersatz.

`--date-resolution-json` übernimmt bereits aufgelöste Grenzen für Fortsetzungen
und weitere Filterbatches. Der Kern prüft den gesamten Beleg, die ursprüngliche
Frage, den Referenztext sowie ISO-/Epochkonsistenz vor der Suche. Dabei werden
keine relativen Kalendergrenzen oder IANA-Regeln erneut ausgewertet.

Eine zusätzlich aktive [lokale Lesepolitik](LOCAL_CONTENT.md) benötigt
Konfigurationsformat 5 und Vorlagen-/Quick-/Aufzeichnungsformat 6; die bisherigen
Finder-/Kalenderbelege und Fähigkeiten bleiben dabei erhalten.
