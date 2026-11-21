# Favenio

Favenio ist eine indexlose Dateisuche für macOS und Linux. CLI, Haupt-App und
Schnellsuche teilen genau eine Suchlogik in `favenio.py`. Der Python-Kern
verwendet die Standardbibliothek. Frontends starten ihn als Unterprozess und
verarbeiten JSONL. Die Suchsemantik bleibt im Kern.

## Zuständigkeiten

- `favenio.py` definiert Suche, CLI, Ausgabe, Exitcodes und `__version__`.
  `tests/test_favenio.py` und die Tests der jeweiligen Funktionen prüfen die Verträge.
- `common/` enthält gemeinsame Swift-Anwendungsmodelle, Prozessanbindung und
  AppKit-Ansichten. Der [portable Unterbau](docs/PORTABLE_CORE.md) wird von den
  macOS-Apps und der Linux-Bridge genutzt.
- `gui/` enthält das macOS-Hauptfenster, `quick/` die Finder-nahe Schnellsuche.
  `linux/` enthält GTK-Oberfläche, Swift-Bridge und plattformspezifische Helfer.
- [README.md](README.md) und [README.de.md](README.de.md) bleiben inhaltlich
  synchron. [BACKLOG.md](BACKLOG.md) ist die aktive Projektliste.
  Erledigte Änderungen gehören in [CHANGELOG.md](CHANGELOG.md).

## Verträge vor Änderungen lesen

- [Suchkern und CLI](docs/architecture/SEARCH-CONTRACT.md#kern-und-suchvertrag)
  für Kriterien, Ausgabe und Archive. Diagnosen gehen nach stderr. JSONL-Felder,
  Exitcodes und bytegetreue Quell- und Archividentitäten erhalten.
- [Performance und Parallelität](docs/architecture/SEARCH-CONTRACT.md#performance-und-parallelität)
  für I/O, Abbruch oder Durchsatz. Die dokumentierten Grenzen für Archive und
  Dokumente gelten auch bei Nachladen und Materialisierung.
- [Swift-Frontends](docs/architecture/FRONTENDS.md#swift-frontends) für AppKit,
  Dateiaktionen, geteilte Modelle und Prozessanbindung.
  [Linux-Frontends](docs/architecture/FRONTENDS.md#linux-frontends) für GTK und
  Swift-Bridge.
- [Build und Tests](docs/architecture/BUILD-AND-TEST.md#bauen-und-testen) sowie
  [verifizierte Fallen](docs/architecture/BUILD-AND-TEST.md#verifizierte-fallen)
  für Bundle-Bau, GUI-Prüfung, Installer und Release.
- [Dokumenttext](docs/DOCUMENT_TEXT.md), [Bild-OCR](docs/OCR.md),
  [PDF-OCR](docs/PDF_OCR.md) und [Dublettenprüfung](docs/DUPLICATES.md) für diese
  jeweils ausdrücklich gewählten Funktionen und ihre Quellbindung.
  Die Helfer extrahieren nur Daten. Matching und Vergleich liegen im Kern.

## Änderungen und Versionen

Ein Feature vollständig umsetzen, passend prüfen und getrennt committen. Vor
Arbeit an einem Backlog-Eintrag den aktuellen Code und jüngere Commits prüfen.
Fremde Änderungen bleiben außerhalb des Commits.

`favenio.py::__version__` ist die Produktversionsquelle. Build und UI leiten
ihre Version davon ab. Bei Verhaltensänderungen Version, README und Tests
gemeinsam prüfen. Reine Doku- und Regeländerungen brauchen keinen Produkt-Bump.

`./build.sh` baut beide macOS-Bundles über `build-app.sh`, ohne zu installieren.
Der Wrapper akzeptiert keine Argumente (Exit 2) und schreibt bei Erfolg
`BUILD OK: <ordner>/Favenio.app <ordner>/FavenioQuick.app`. Der Ordner darf
Leerzeichen enthalten. Beide Python-Interpreter und die Plattform-Builds
sind in [CI](.github/workflows/ci.yml) abgedeckt.

`install.sh` und `release.sh` binden die gemeinsame Notarisierungslogik aus
`notarize-lib.sh` ein. Eine öffentliche Veröffentlichung ist ein eigener
Auftrag. Vorher Lizenz, README-Sprachen, Einstellungen, Pfade und öffentliche
Artefakte prüfen.
