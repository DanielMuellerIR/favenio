# Favenio – offene Arbeit

- Schutz vor dem Nachladen noch nicht lokaler Inhalte auf weitere
  Cloud-Anbieter ausweiten, sobald sich deren Zustände zuverlässig prüfen lassen.
  [Lokale Inhalte](docs/LOCAL_CONTENT.md)
- OCR für eingebettete Bilder in weiteren Office-Formaten prüfen. In PPTX ist
  sie bereits als eigene Option verfügbar.
  [Dokumenttext und PPTX-Bild-OCR](docs/DOCUMENT_TEXT.md#pptx-bild-ocr)
- Den sporadischen SIGTERM-Fehler im Installations-Rollbacktest erst bei einem
  neuen Fehlschlag untersuchen. Dann Bereitschaftsdatei, Prozessstatus,
  Ausgabe und Systemlast sichern. Die historische Ursache ist ungeklärt.
  [Messung und Reproduktion](docs/PERFORMANCE.md#sigterm-beim-installationsaustausch)

Verfügbare Funktionen stehen in der [Funktionsübersicht](docs/FEATURES.md).
Erledigte Änderungen sind im [Changelog](CHANGELOG.md) dokumentiert.
