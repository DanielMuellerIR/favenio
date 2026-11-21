# Messungen und Reproduktionen

Diese Ergebnisse beschreiben die jeweils genannten Quellstände und
Testdaten. Die Skripte erzeugen ihre Testdaten selbst. Messungen auf
anderen Rechnern und mit anderen Dateien können abweichen.

- [Zeilenleser](../tests/LINE_READER_MEASUREMENTS.md)
- [Suchtransport zwischen Kern und App](../tests/RUNNER_MEASUREMENTS.md)
- [Auspacken von Archivtreffern](../tests/MATERIALIZATION_MEASUREMENTS.md)
- [Hintergrundexport](../tests/EXPORT_MEASUREMENTS.md)

## Archivsuche mit TAR und 7z

Am 2026-09-05 verglich `tools/archive-search-benchmark.py` den Kern
`e04db963779ca4d048d9b00e73880f4ee8977a8c` mit zwei Varianten.
Die TAR-Variante ersetzte den vollständigen Katalog durch Iteration über das
mit `r:*` geöffnete Archiv. Die 7z-Variante übersprang bei bsdtar-Lesewegen
den Inhaltsvortest. Beide Änderungen liefen nur in temporären Kernkopien.

Gemessen wurde auf macOS mit System-Python 3.9.6 und System-bsdtar bei warmem
Cache. Die 43 Fälle umfassten Namens- und Inhaltssuche mit frühen, späten
und fehlenden Treffern, Archivbudgets und ein abgeschnittenes TAR. Pro Fall
lief jede Variante in drei frischen Prozessen in wechselnder Reihenfolge.
Zeit ab `main()` bis zum ersten Treffer und bis zum Ende enthält keinen
Interpreterstart. `ru_maxrss` misst Python und beendete Kinder getrennt.
Der Vergleich prüft Treffer, Zeilennummern, stderr und Exitcodes.

| Fall | Messgröße | Bisher, Median ms | Experiment, Median ms |
| --- | --- | ---: | ---: |
| TAR, 3000 × 4 KiB, früher Inhalt | Erster Treffer | 42,85 | 1,67 |
| TAR, 3000 × 4 KiB, früher Inhalt | Gesamte Suche | 80,25 | 81,66 |
| TAR.GZ, 3000 × 4 KiB, früher Inhalt | Erster Treffer | 55,79 | 1,72 |
| TAR.GZ, 200 × 256 KiB, kein Inhaltstreffer | Gesamte Suche | 61,51 | 47,34 |
| 7z, 4 KiB, früher Inhalt | Gesamte Suche | 12,71 | 9,12 |
| 7z, 1 MiB, später Inhalt | Gesamte Suche | 16,04 | 12,07 |
| 7z, 16 MiB, kein Inhaltstreffer | Gesamte Suche | 20,38 | 54,65 |

42 Fälle lieferten gleiche Ergebnisse. Beim abgeschnittenen TAR meldete die
bisherige Suche keinen Treffer und endete mit Status 1. Der Iterator gab
`first.txt:1` und eine zusätzliche Warnung aus und endete mit Status 0.
Im frühen TAR-Fall betrug das Python-Speichermaximum in beiden Varianten
18.595.840 Byte. `tarfile` behält Eintragsobjekte weiterhin im Speicher.
Das Entfernen des 7z-Vortests verlangsamte den negativen 16-MiB-Lauf um den
Faktor 2,68. Beide Änderungen wurden verworfen.

Auf macOS im Repository-Root ausführen. Das Skript schreibt Einzelwerte und
Medianwerte in ein temporäres Verzeichnis und nennt den Pfad auf stderr.

```sh
benchmark_source=$(mktemp /tmp/favenio-benchmark.XXXXXX)
git show e04db963779ca4d048d9b00e73880f4ee8977a8c:favenio.py > "$benchmark_source"
/usr/bin/python3 tools/archive-search-benchmark.py --source "$benchmark_source"
```

## SIGTERM beim Installationsaustausch

Die Rollback-Probe schlug am 2026-09-03 unter hoher Last zweimal fehl. Nach
sieben erfolgreichen Wiederholungen bestanden am 2026-09-05 zehn weitere.
Seit einer separaten Korrektur beendet und sammelt der Test den gestarteten
Prozess auch bei einem `communicate()`-Timeout. Die frühere Ursache blieb
ungeklärt.

Am 2026-10-06 prüfte `tools/measure-sigterm.py` mit Python 3.9.6 und
temporären Bundle-Attrappen. Test und Installationshelfer entsprechen
den Dateien in Release 0.38.3 (`2285350`). Bei vorhandener Last bestanden
20 von 20 Läufen (Median 0,295 s), mit vier zusätzlichen befristeten
CPU-Prozessen weitere 20 von 20 (Median 0,351 s).
Vor SIGTERM lag die Bereitschaftsdatei vor und die Shell lief. Jeder Lauf
endete mit Status 2, stellte beide alten Bundles wieder her und hinterließ
keine Transaktionsreste. Die Messung reproduzierte den Fehler nicht.
Installer und Zeitgrenzen wurden dafür nicht geändert.

Auf macOS im genannten Release-Checkout ausführen. Das Skript verwendet
temporäre Bundles.

```sh
/usr/bin/python3 tools/measure-sigterm.py --repetitions 20 --workers 4 --output /tmp/favenio-sigterm.json
```

## Leerer Ordner im ISO-Abbild

Auf dem alten Stand `e498064` lieferte die Suche für den leeren Ordner
`empty` in `empty.iso` einen Dateitreffer. Die Ordnersuche fand nichts.
Seit 0.31.4 verwendet der Kern die Typangabe von `bsdtar -tvf`.
Mit `/usr/bin/python3 tools/reproduce-empty-iso.py` lassen sich unter macOS
mit `hdiutil` und `bsdtar` beide Suchmodi prüfen. Exit 0 bedeutet
korrekte Ordnerklassifikation, Exit 1 den früheren Fehler und Exit 2 eine
gescheiterte Probe. `--source` nimmt alternativ den Kern des früheren Stands.

## Sternmuster in der Inhaltssuche

Am 2026-10-01 verglich ein einfacher Matcher-Lauf mit Python 3.9.6 am Stand
`5d7c30c` (Release 0.35.0) das Sternmuster `a*z` auf 64 KiB aus dem Zeichen `a` mit einem
äquivalenten ungebundenen regulären Ausdruck. Die Suche blieb in beiden Fällen
ohne Treffer. Der Median aus drei Läufen betrug rund 30 µs mit geordneten
Teilstrings und 13,28 s mit naivem Regex-Backtracking. Einzelne CLI-Proben
mit etwa 32,8 MB ergaben 0,026 s ohne Treffer und 0,271 s bei einem Treffer
in der letzten Zeile, jeweils rund 14,4 MiB Spitzenspeicher. Die Messung
gilt für diese Eingaben. Die Sternsuche bleibt auf eine Zeile begrenzt.

Der Matcher-Vergleich lässt sich mit `favenio.py` aus dem genannten Stand
reproduzieren. Den importierten `build_matcher` mit dem Textmuster `a*z`
und `text_wildcards=True` aufrufen, dann dasselbe Ziel mit dem regulären
Ausdruck `a.+z` und `use_regex=True` prüfen. Für die Zeitmessung den Matcher
vorab erstellen und je drei Aufrufe mit `time.perf_counter()` messen.

## Parallele Inhaltssuche

Ein früher Versuch mit `--jobs` verglich serielle und parallele Suche mit
System-Python 3.9.6 auf einem 174-MB-Korpus. Bei ungecachten Dateien lag das
Tempo bei etwa dem 1,9-Fachen, bei 3.000 kleinen Dateien im warmen Cache
bei 0,68 des seriellen Laufs. In diesem Datenpfad gab nur `read()` die
Python-Interpreter-Sperre frei. Dekodieren, Zeilentrennung und Matcher liefen
unter der Sperre. Die gemessenen Vorteile rechtfertigten Pool, Sperren und
Auftragsverwaltung nicht. Die Änderungen sind in der Git-Historie um
`v0.15.0` nachvollziehbar.
