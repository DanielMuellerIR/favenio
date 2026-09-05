# Suchtransport: Messung 2026-09-05

Reproduktion: `python3 tests/benchmark_runner.py --baseline e04db96`.
macOS/Apple M5, Swift `-O`, System-Python. Je drei frische Prozesse; derselbe
Python-Erzeuger schreibt 100.000 eindeutige JSONL-Treffer, alle Empfänger halten
alle Treffer in einem Array. Der alte GUI-Weg zerlegt/parst auf Main; der alte
Quick-Weg stellt jeden Treffer einzeln auf die Main-Queue. Der neue Weg nutzt
den gemeinsamen Runner über seinen synchronen Diagnoseadapter. Die zusätzliche
wartende Adapter-Queue gehört zur Nachher-Messung.

RSS ist `getrusage(RUSAGE_SELF).ru_maxrss` (unter macOS Bytes); ein Main-RunLoop-
Timer mit 5 ms Intervall misst die größte Verzögerung über sein Sollintervall
hinaus. Dies ist ein Transporttest: Tabellenaufbau, Sortieren, Suchdateisystem,
AppKit-Darstellung und die produktive Top-20-Grenze der Schnellsuche sind nicht
Teil dieser Zeitmessung. Der neue Runner begrenzt Transportpuffer, nicht die
bewusst dauerhaft gehaltene vollständige Trefferliste.

| Weg | Dauer s (3 Läufe) | RSS MiB (3 Läufe) | Größte Main-Verzögerung ms (3 Läufe) |
|---|---|---|---|
| GUI vorher | 0,399 / 0,396 / 0,401 | 347,5 / 326,2 / 339,2 | 77,0 / 77,6 / 90,8 |
| Quick vorher | 0,545 / 0,537 / 0,540 | 107,7 / 107,6 / 107,5 | 2,27 / 2,21 / 2,04 |
| Gemeinsamer Runner | 0,438 / 0,431 / 0,438 | 69,5 / 69,4 / 69,4 | 2,05 / 2,20 / 1,77 |

Gegenüber dem GUI-Weg kostet die Entkopplung im Median rund 10 % Gesamtdauer,
reduziert den Spitzenspeicher aber um rund 80 % und die größte Main-Verzögerung
um rund 97 %. Gegenüber Quick sinken Zeit um rund 19 % und Speicher um 35 %.
Keine Aussage über beschleunigte Suchsemantik oder das Zeichnen von 100.000
Tabellenzeilen.

`test_search_runner.py` kompiliert denselben Produktionskern separat und prüft
mit echten Unterprozessen: 100.000 vollständige Treffer vor Completion, letzte
Zeile ohne Umbruch, EOF vor Exit sowie Exit vor EOF, 10.000 stderr-Warnungen,
Startfehler, Abbruch vor Start, während des Lesens und bei voller Main-Queue,
20 schnelle Laufwechsel einschließlich schon eingereihter alter Pakete,
SIGKILL nach bestätigtem Ignorieren von SIGTERM, Top-20-Abbruch, Fortschritt ohne Treffer und überlange JSONL-Zeilen. Die
Transport-Messwerte belegen höchstens zwei ausstehende Pakete, 256 Treffer und
1 MiB pro Paket; lange gültige Datensätze prüfen zusätzlich die Bytegrenze.
EOF/Exit-Reihenfolge wird durch getrenntes Schließen von stdout und einen kurz
weiterlebenden Prozess mit geerbtem Deskriptor hergestellt.
