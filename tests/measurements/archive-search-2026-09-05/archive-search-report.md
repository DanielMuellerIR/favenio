# Archivsuche: zwei verworfene Optimierungen

Stand: 2026-09-05, Basis `e04db963779ca4d048d9b00e73880f4ee8977a8c`.
Python-Kern-SHA-256: `ddcb05f287eaa62869508e5c95afa5a6a4988affacfd02d0901517b62bd56c89`.

Beide Experimente bleiben außerhalb des Produktcodes. Die TAR-Iteration liefert
frühe Treffer schneller, verändert aber bei einem später beschädigten Archiv
Treffer, Warnungen und Exit-Code. Das Abschalten des Inhaltsvortests für bsdtar
beschleunigt positive Suchläufe und verlangsamt einen negativen 16-MiB-Lauf
auf das 2,68-Fache.

## Aufbau

Das Skript kopiert den Kern in ein temporäres Verzeichnis und verändert nur
je eine Kopie: `archive.getmembers()` wird durch Iteration über das weiterhin
mit `r:*` geöffnete Archiv ersetzt; in der anderen Kopie wird nur für die
bsdtar-Testfälle die genaue Inhaltssuche ohne Vortest ausgeführt. Kein
Repository-Code wird verändert. Die Varianten laufen jeweils in einem eigenen
Prozess, dreimal in wechselnder Reihenfolge. Cache wird nicht geleert; die
Zahlen beschreiben den warmen synthetischen Korpus, keinen Kaltstart.

Gemessen wird mit macOS-System-Python 3.9.6 und System-bsdtar:

- Zeit vom Aufruf `main()` bis zum ersten `emit()` und bis zum Ende;
  Interpreterstart und Modulimport zählen nicht dazu.
- `resource.ru_maxrss` getrennt für Python und seine beendeten Kindprozesse;
  Werte auf macOS in Bytes. Das sind getrennte Maxima, kein gemessener
  gleichzeitiger Gesamtspeicher aller Prozesse.
- Exakte Gleichheit von JSONL, Zeilennummern, stderr und Exit-Code zwischen
  Varianten und Wiederholungen, bevor die Daten als Prüfsummen gespeichert werden.

TAR und TAR.GZ enthalten jeweils 3000 Dateien à 4 KiB oder 200 Dateien à
256 KiB. Gemessen werden frühe, späte und fehlende Namens- und Inhaltstreffer.
7z enthält jeweils eine Datei mit 4 KiB, 1 MiB oder 16 MiB und frühem, spätem
oder fehlendem Inhaltstreffer. Der Text besteht aus kurzen wiederholten
ASCII-Zeilen; andere Kompressionsgrade und Verteilungen sind nicht vermessen.
Hinzu kommen Gesamtbudgetläufe mit 64 KiB für TAR, TAR.GZ und 7z sowie ein
spät abgeschnittenes TAR. Insgesamt 43 Fälle mit je sechs Prozessen.

Aufruf vom Repository-Root, die Skriptdatei entsprechend ihrem Ablageort:

```sh
benchmark_source=$(mktemp /tmp/favenio-baseline.XXXXXX)
git show e04db963779ca4d048d9b00e73880f4ee8977a8c:favenio.py > "$benchmark_source"
/usr/bin/python3 tools/archive-search-benchmark.py --source "$benchmark_source"
```

Das Skript schreibt seine Messdateien in ein neues temporäres Verzeichnis.
Mit `--output-dir` kann ein neues oder leeres Verzeichnis außerhalb des
Repositorys angegeben werden; bestehende Fixture-Verzeichnisse und Pfade im
Repository werden abgelehnt. stdout enthält pro Fall die Medianwerte als JSONL.
Das Zielverzeichnis wird auf stderr genannt. Die Dateien heißen
`archive-search-environment.json`, `archive-search-summary.jsonl` und
`archive-search-results.json`.

`--source favenio.py` kann einen späteren Kernstand untersuchen. Fehlt einer
der beiden erwarteten Änderungsanker oder kommt er mehrfach vor, bricht das
Skript mit einer konkreten Fehlermeldung ab. Die hier dokumentierten Zahlen
stammen ausschließlich aus der oben genannten Basis.

## Ergebnisse

Alle Zeiten sind Mediane in Millisekunden. Vollständige Fallwerte und getrennte
RSS-Werte stehen in `archive-search-summary.jsonl`; Einzelmessungen,
Ausgabeprüfsummen und Diagnosebeispiele in `archive-search-results.json`.

| Fall | Messgröße | Bisher | Experiment |
| --- | --- | ---: | ---: |
| TAR, 3000 × 4 KiB, früher Inhalt | erster Treffer | 42,85 | 1,67 |
| TAR, 3000 × 4 KiB, früher Inhalt | gesamte Suche | 80,25 | 81,66 |
| TAR.GZ, 3000 × 4 KiB, früher Inhalt | erster Treffer | 55,79 | 1,72 |
| TAR.GZ, 200 × 256 KiB, kein Inhaltstreffer | gesamte Suche | 61,51 | 47,34 |
| 7z, 4 KiB, früher Inhalt | gesamte Suche | 12,71 | 9,12 |
| 7z, 1 MiB, später Inhalt | gesamte Suche | 16,04 | 12,07 |
| 7z, 16 MiB, kein Inhaltstreffer | gesamte Suche | 20,38 | 54,65 |

Die TAR-Iteration begrenzt den Speicher nicht: `tarfile` behält weiterhin
`TarInfo`-Objekte in `archive.members`. Beim frühen TAR-Fall beträgt das
Python-Maximum in beiden Varianten 18.595.840 Bytes. Der frühe TAR.GZ-Fall
liegt bei 18.743.296 gegenüber 18.481.152 Bytes. Daraus folgt kein belastbarer
Speichergewinn. Das späte Auflösen von TAR-Verknüpfungen kann intern außerdem
weiterhin den vollständigen Katalog laden.

42 Fälle liefern identische Treffer, Zeilennummern, Warnungen und Exit-Codes.
Beim 64-KiB-Gesamtbudget stimmen auch die jeweils 2984 TAR-Budgetwarnungen
exakt überein. Der abweichende 43. Fall ist das beschädigte TAR:

1. `first.txt` enthält `NEEDLE` in Zeile 1.
2. `late.txt` verspricht 6000 Bytes, das TAR wird nach 1600 Bytes abgeschnitten.
3. Bisher: kein Treffer, eine Warnung „beschädigtes Archiv“, Exit 1.
4. Iterator: Treffer `first.txt:1`, eine zusätzliche Eintragswarnung und die
   Archivwarnung, Exit 0.

Eine Ausgabe erst nach vollständiger TAR-Prüfung könnte den bisherigen
Vertrag erhalten, würde jedoch den belegten Gewinn beim ersten Treffer
wieder aufheben. Eine Änderung des Verhaltens beschädigter Archive wäre eine
separate Produktentscheidung. Sie ist keine verhaltensneutrale Optimierung.

Beim bsdtar-Experiment bleibt der Speicher im gleichen Bereich. Die
zusätzliche Zeilenauswertung ohne Vortest erklärt den Rückschritt beim
fehlenden großen Treffer. Die Größen der bsdtar-Einträge sind vor dem
Entpacken unbekannt; eine größenabhängige Umschaltung ist mit dem heutigen
Katalog nicht verfügbar. Beide bisherigen Verfahren bleiben daher erhalten.
