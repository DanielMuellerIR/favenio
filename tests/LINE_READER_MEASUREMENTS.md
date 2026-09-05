# Zeilenleser: Messung 2026-09-05

Reproduktion: `python3 tests/benchmark_line_reader.py --baseline 7fc8691`.
macOS/Apple M5, System-Python 3.9, warmer Seitencache, je drei frische
Prozesse. Rohwerte: `tests/measurements/line-reader-2026-09-05.jsonl`.

Zwei Fixtures zu je 64 MiB, deren einziger Treffer ganz am Ende steht — so
sagt der billige Inhaltsvortest „nachsehen", und der Leser muss alles lesen:
kurze Zeilen (80 Zeichen, LF, 838 861 Zeilen) und EINE Zeile ohne Umbruch. Je
Fixture zwei Muster: `--content ENDEMARKE` (reiner Substring, darf
Bruchstücke prüfen) und `--regex ENDE.ARKE` (Bruchstücke bleiben ungeprüft,
die lange Zeile wird gemeldet, Exit 1). Gemessen ist ein kompletter Lauf des
jeweiligen `favenio.py` als Unterprozess; RSS ist `ru_maxrss` des Kindes.

„Vorher" ist 7fc8691 (0.32.0): Dekodieren, Zeilentrennung, Überlappung,
Längengrenze und Matching in EINER Schleife in `match_content()`. „Nachher"
ist der Generator `iter_line_pieces()`, der je Zeile ein Tupel
`(number, text, complete, ends_line)` liefert, und ein `match_content()`, das
nur noch je Stück entscheidet.

| Fixture | Muster | vorher s (3 Läufe) | nachher s (3 Läufe) | RSS MiB vorher / nachher |
|---|---|---|---|---|
| kurze Zeilen | Substring | 0,178 / 0,173 / 0,173 | 0,192 / 0,192 / 0,196 | 19,9 / 19,9 |
| kurze Zeilen | Regex | 0,363 / 0,348 / 0,344 | 0,368 / 0,365 / 0,367 | 19,8 / 20,0 |
| eine Zeile | Substring | 0,136 / 0,134 / 0,133 | 0,136 / 0,133 / 0,133 | 46,8 / 46,8 |
| eine Zeile | Regex | 0,096 / 0,094 / 0,095 | 0,093 / 0,093 / 0,095 | 47,0 / 46,8 |

Kurze Zeilen kosten mit dem Generator rund 10 % (Substring) bzw. 5 % (Regex)
mehr: ein `yield` je Zeile, 840 000 Mal. Das ist der Preis des Herauslösens
und bewusst nicht wegoptimiert — der Auftrag war ein verhaltensneutraler
Refactor, keine Optimierung. Eine erste Fassung mit einem `namedtuple` und
einer Hilfsfunktion je Zeile kostete 0,31 s statt 0,17 s (Substring) und
0,50 s statt 0,34 s (Regex); deshalb liefert der Generator nackte Tupel und
schreibt die drei Zeilenenden inline. Speicher und die lange Zeile bleiben
unverändert: Dort zählt nicht die Zahl der Stücke, sondern die Grenze
`MAX_LINE_CHARS`, und die ist dieselbe.

Ergebnisgleichheit belegt `tests/test_line_reader.py`: eine wörtliche Kopie
der alten `match_content()` läuft gegen die neue, Eingabe für Eingabe — LF,
CRLF über jede Häppchengrenze, einzelnes CR, alle elf Trenner von
`str.splitlines()`, UTF-8-Grenzen und Ersatzzeichen, letzte Zeile ohne
Umbruch, leere Zeilen, überlange Zeilen mit Treffer an jeder Stelle
einschließlich der Überlappung, Überlappung 0, zwei lange Zeilen
hintereinander, ein wartendes CR vor dem Abschnittswechsel und 300
Zufallseingaben — mit vier Matchern (Substring, verankerter Regex, Glob,
Exact). Verglichen werden Trefferzeile, Warnungen und die Zahl der
verbrauchten Häppchen (frühes Leseende).
