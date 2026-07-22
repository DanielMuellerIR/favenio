# Changelog

## 0.16.0 — 2026-07-22

- Archivmitglieder werden für Inhaltssuchen gestreamt und durch konfigurierbare
  Einzel-, Gesamt- und Kompressionsgrenzen geschützt.
- Verschlüsselte oder nicht unterstützte ZIP-Mitglieder erzeugen kontrollierte
  Warnungen; Extraktion endet ohne Traceback mit Exit-Code 2.
- Hidden-Komponenten in ZIP-/Tar-Pfaden werden vollständig berücksichtigt.
- JSONL überträgt Dateisystempfad und Archivkette strukturiert; normale Pfade
  mit `!/` bleiben dadurch in den Apps eindeutig.
- GUI-Suchläufe besitzen getrennte Prozessgenerationen und Puffer. Späte Daten
  eines abgebrochenen Laufs können keine neue Suche mehr beenden oder mischen.
- Materialisierte Archivtreffer werden pro App-Lauf wiederverwendet und beim
  Beenden aus einem app-eigenen Temp-Root entfernt.
- Quick-Handoffs werden atomar mit Besitzer- und Größenprüfung geschrieben,
  begrenzt gestreamt gelesen und nach jedem Verbrauch gelöscht.
- Swift-Streaming liefert Treffer nur noch per Callback statt sie zusätzlich
  als zweite Treffer- und JSONL-Kopie im Speicher zu sammeln; der wirkungslose
  Python-Fehlerzustand wurde entfernt.
- Der Sortier-Comparator ist auch absteigend bei Gleichständen strikt.
- `build-app.sh` baut und testet ausschließlich im Repository. Nur das fertig
  signierte, gestapelte und von Gatekeeper akzeptierte Release-DMG ist für eine
  bewusste Installation vorgesehen.
