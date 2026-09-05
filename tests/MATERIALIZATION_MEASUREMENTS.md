# Auspacken von Archivtreffern: Messung 2026-09-05

Reproduktion: `python3 tests/benchmark_materialization.py --baseline 96e23fa`.
macOS/Apple M5, Swift `-O`, System-Python, warmer Seitencache. Je drei frische
Prozesse. Drei Fixtures: ein Zip mit einem 128-MiB-Eintrag (gespeichert), ein
Zip im Zip mit einem 64-MiB-Eintrag und ein 7z (LZMA) mit 128 MiB
Zufallsdaten. Rohwerte: `tests/measurements/materialization-2026-09-05.jsonl`.

`blocked` ist die Zeit, die der Aufruf auf dem Main-Thread nicht zurückkehrt;
`max_delay` die größte Verspätung eines 5-ms-Main-Timers über sein
Sollintervall hinaus — das ist die Zeit, in der ein Fenster einfriert.
„Vorher" ist `materializeHit()` aus 96e23fa (0.31.4): stdout synchron,
`waitUntilExit()`, stderr verworfen. „Nachher" ist `request()` mit Completion
auf der Main-Queue; `seconds` ist dort die Gesamtdauer bis zur Completion.

| Fixture | Weg | blocked ms (3 Läufe) | größte Main-Verzögerung ms (3 Läufe) | Gesamtdauer s |
|---|---|---|---|---|
| Zip, 128 MiB | vorher | 163 / 161 / 157 | 94 / 89 / 87 | — |
| Zip, 128 MiB | nachher | 0,2 / 0,2 / 0,1 | 2,4 / 2,5 / 2,2 | 0,15 / 0,15 / 0,14 |
| Zip im Zip, 64 MiB | vorher | 146 / 150 / 145 | 77 / 80 / 77 | — |
| Zip im Zip, 64 MiB | nachher | 0,3 / 0,2 / 0,1 | 1,8 / 2,1 / 2,5 | 0,13 / 0,13 / 0,13 |
| 7z, 128 MiB Zufall | vorher | 4745 / 4639 / 4620 | 4676 / 4569 / 4548 | — |
| 7z, 128 MiB Zufall | nachher | 0,2 / 0,1 / 0,2 | 2,6 / 2,5 / 2,3 | 4,64 / 4,62 / 4,61 |

Beim gespeicherten Zip fror das Fenster je Treffer rund 0,15 s ein, beim 7z
rund 4,6 s — bei einer Mehrfachauswahl je Treffer nacheinander. Nachher bleibt
die größte Main-Verzögerung in allen Fällen bei rund 2,5 ms, dem Timer-Rauschen
des leeren RunLoops. Die Gesamtdauer ändert sich nicht: Der Kern braucht so
lange wie vorher, er blockiert nur niemanden mehr. Die synchrone Fassung
`materializeHit()` gibt es weiter für den Headless-Selbsttest; sie dreht auf
Main die RunLoop und wird von keiner App aus einer Aktion gerufen
(Wächter-Test in `tests/test_swift_guards.py`).

Ein 7z mit sich wiederholenden Daten dekodiert LZMA fast so schnell wie ein
gespeichertes Zip (0,17 s bei gleicher Größe, erste Messreihe); deshalb misst
die Fixture Zufallsdaten.

## Drag-and-drop: Dateiversprechen gegen vorab ausgepackte URLs

`tableView(_:pasteboardWriterForRow:)` verlangt beim Anfassen der Zeile sofort
eine Antwort. Zwei Wege standen zur Wahl:

- **Vorab ausgepackte URLs**: Jeder sichtbare Archivtreffer wird schon beim
  Erscheinen ausgepackt, damit die URL beim Ziehen feststeht. Das kostet
  Entpackzeit und Temp-Speicher für Treffer, die niemand zieht, hebelt die
  Budgets des Kerns aus (1000 Treffer mal 128 MiB) und ist bei einem Lauf mit
  laufendem Nachschub nie fertig.
- **Dateiversprechen** (`NSFilePromiseProvider`): Die Zeile verspricht eine
  Datei mit Typ und Namen; erst beim Ablegen fragt der Empfänger
  (`filePromiseProvider(_:writePromiseTo:)`, auf einer eigenen Queue) nach
  dem Inhalt. Dann packt derselbe `MaterializationManager` im Hintergrund aus
  und kopiert die Datei an die Zielstelle; Fehler und Abbruch gehen als
  `Error` an den Empfänger. Gezogen wird nur, was wirklich abgelegt wird.

Gewählt ist ein Zwischenweg: Was `knownURL(for:)` schon kennt — jede normale
Datei, jeder schon ausgepackte Eintrag (etwa nach Vorschau oder Öffnen) —,
geht wie bisher als URL ins Pasteboard; nur ein noch nicht ausgepackter
Eintrag geht als Versprechen. Der Preis: Ein Empfänger, der ausschließlich
Datei-URLs annimmt und keine versprochenen Dateien, bekommt einen noch nicht
ausgepackten Eintrag nicht mehr. Der Finder und die üblichen Ablagen nehmen
Versprechen an. Die Temp-Kopie bleibt bis zum App-Ende im Cache; der Empfänger
bekommt eine KOPIE, nicht die Cache-Datei selbst.

Headless geprüft (`tests/test_materialization.py`): Startfehler, beschädigtes
Archiv, Budgetüberschreitung mit Grund des Kerns, 200 000 stderr-Zeilen ohne
Stillstand, Abbruch mit beendetem Kern, 20 schnelle Auswahlwechsel (nur die
letzte Auswahl kommt an), zwei gleichzeitige Anforderungen mit EINEM
Unterprozess, `cleanup()` während eines Auftrags ohne neu angelegten Root,
und dieselbe Datei für Öffnen und Vorschau. Der sichtbare Drag-and-drop-Test
am Fenster (mehrere Dateien, langsame Extraktion, Abbruch, Fehler, Übernahme
durch den Finder) steht noch aus und braucht eine eigene Freigabe.
