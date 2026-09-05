# Hintergrundexport: Messung 2026-09-05

Reproduktion: `python3 tests/benchmark_export.py --baseline 5c2243d --repetitions 3`.
Rohwerte: `export-measurements-2026-09-05.jsonl`.

macOS/Apple M5, Swift `-O`; 100.000 künstliche Treffer mit Pfad, Größe sowie
Änderungs- und Erstellungszeit, drei frische Prozesse je Format und Variante.
Gemessen wird Serialisieren plus atomarer Dateiaustausch in eine temporäre
Datei. Vorher läuft der unveränderte `exportData`-Serializer auf Main, nachher
über `ExportWriter` auf einer Worker-Queue. Der gemeinsame Dateizeit-Formatter,
CSV-Präfixschutz/BOM, JSONL und beide Pfadformate bleiben unverändert.

`ru_maxrss` bezeichnet unter macOS den Prozess-Spitzenspeicher in Bytes.
Ein Main-RunLoop-Timer mit 5 ms Intervall misst seine größte Verspätung über
sein Sollintervall hinaus. Auch nach dem synchronen Vorher-Export wird der
verspätete Timer einmal bedient, damit die blockierte Zeit nicht fälschlich
als Null erscheint. Die Exportdauer endet beim Schreiben bzw. bei der
Main-Completion des Workers; das anschließende Timer-Nachholen verlängert die
Vorher-Dauer nicht.

Median von jeweils drei Läufen; Main-Verzögerung ist der Median der drei
jeweiligen Maxima:

| Format | Dauer vorher/nachher s | RSS vorher/nachher MiB | Main-Verzögerung vorher/nachher ms |
|---|---|---|---|
| Pfade | 0,00926 / 0,00943 | 60,25 / 60,53 | 4,42 / 0,19 |
| Pfade NUL | 0,00937 / 0,00947 | 60,28 / 60,53 | 4,52 / 0,18 |
| JSONL | 0,276 / 0,302 | 513,16 / 513,67 | 271,30 / 0,98 |
| CSV | 16,576 / 16,779 | 111,20 / 111,95 | 16571,61 / 2,88 |

Der Export wird insgesamt nicht schneller: CSV dauert rund 1 % länger,
JSONL rund 10 %. Die Main-Queue bleibt während dieser Arbeit bedienbar.
JSONL benötigt nach wie vor rund 514 MiB Spitzenspeicher, da Objekte und die
vollständige `Data`-Ausgabe im Speicher entstehen. Der Einzeljob verhindert
mehrere gleichzeitige große Snapshots, begrenzt aber nicht einen einzelnen
Export. Gemessen wurden Worker, Serialisierung und Dateien; keine Sichern-
Dialog-Interaktion oder Finder-Anzeige.

`test_export_writer.py` kompiliert den Produktionskern und prüft alle vier
Formate mit echten Dateien. Die Pfad- und CSV-Bytes stimmen exakt mit dem
unveränderten Serializer überein; JSONL wird wegen variabler Schlüsselreihenfolge
als geordnete Trefferliste verglichen. CSV-BOM/Formelpräfixe, Unicode,
Zeilenumbrüche, unbekannte Größen und Zeitpunkte sind in der Fixture enthalten.
Eine nach Start geänderte Eingabe verändert den Export nicht. Ein zweiter Job
wird abgelehnt; Completion läuft auf Main und gibt den Writer für einen Retry
frei. Fehler beim atomaren Austausch lassen sowohl ein bestehendes Verzeichnis
mit Sentinel als auch eine Datei in einem nicht beschreibbaren Elternordner
unverändert. Ein 3.000-Treffer-CSV-Export muss in unter 0,2 s gestartet werden;
Main-Timer-Ereignisse müssen vor Completion eintreffen. So reicht es nicht,
die Serialisierung synchron auszuführen und bloß Completion später einzureihen.
Der Bundle-Selbsttest prüft zusätzlich, dass eine neue Suche und ihr Fehlerstatus
neben einem späteren Exportstatus sichtbar bleiben.
