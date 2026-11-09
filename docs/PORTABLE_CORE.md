# Gemeinsamer Anwendungsunterbau

Die Suche bleibt ausschließlich in `favenio.py`. Die AppKit-Apps und die
Rust/GTK-Oberflächen unter Linux verwenden dieselben Swift-Quellen für
Treffer, Kriterien, Konfigurationen, Prozessereignisse und Materialisierung.
Eine zweite Such- oder Hervorhebungslogik gehört nicht in die Oberflächen.

| Datei | Zuständigkeit |
|---|---|
| `common/SearchModel.swift` | Treffer und bytegenaue Identitäten, JSONL, Export, Gruppierung und Sortierung |
| `common/SearchConfiguration.swift` | Optionen, Suchbereiche und Vorlagen |
| `common/SearchProcess.swift` | begrenzter Prozessleser, Diagnose, Abbruch, Materialisierung und Quick-Transport |
| `common/ContentModel.swift` | Quellenbindung, Dokumentpositionen und validierte Fundstellen |
| `common/CriteriaModel.swift` | Struktur und Transport des Kriterieneditors |
| `common/DateRangeModel.swift` | Datumstransport; Kalenderauflösung bleibt im Python-Kern |
| `common/SearchReportModel.swift` | begrenzte Berichte und lesbare Zusammenfassung |
| `common/ResultFilterModel.swift` | asynchrone Ansichtsfilter mit Kernvalidierung |
| `common/DuplicateModel.swift` | Dublettenauftrag, Quellbindung und Leases |
| `common/ControlModel.swift`, `common/RecordingModel.swift` | Steuerkonfiguration und Aufzeichnungen |
| `common/FastraHandoffModel.swift` | begrenzte, quittierte Quellenübergabe |
| `common/ContentPreviewLoad.swift` | abbrechbares Nachladen mit Quellenprüfung |
| `common/RegexTemplates.swift` | gemeinsame Regex-Einfügehilfen |
| `common/FinderMetadata.swift` | bytegetreue Finder-Snapshots ohne Quellenabfrage |

Die bisherigen AppKit-Dateien behalten Darstellung und Plattformaktionen.
Unter Linux lädt Rust die zur konkreten Programmversion gehörende Bibliothek
`libfavenio-shared.so`. Die private C-Schnittstelle übernimmt längenbegrenzte
UTF-8-Aufträge und gibt einen eigenen, mit `favenio_model_free` freizugebenden
Puffer zurück. Treffer bleiben einmal im gemeinsamen Laufmodell gespeichert. Der Abruf liefert
höchstens 512 neue Treffer; Fortschrittsereignisse werden zusammengefasst.
Abbruch und ein neuer Lauf trennen ihre Generationen. Die Bibliothek bleibt
wegen ihrer Hintergrundaufträge für die gesamte Prozesslaufzeit geladen.

Die direkte Wiederverwendung vermeidet eine zweite Implementierung dieser
Anwendungsregeln. Die Linux-Auslieferung muss die dazugehörige Swift-Laufzeit
mitführen. Python und externe, optionale Datenhelfer bleiben getrennte Prozesse.
Der normale CLI-Kern benötigt weiterhin nur die Python-Standardbibliothek.

## Verlustfreie POSIX-Pfadidentitäten

Der normale `--json`-Strom bleibt kompatibel. `--json --json-path-bytes` fordert
für Treffer einen ausdrücklichen Umschlag an:

```json
{"type":"hitV2","schemaVersion":2,"hit":{"type":"file","path":"/tmp/a.txt","filesystemPath":"/tmp/a.txt","filesystemPathBytes":"L3RtcC9hLnR4dA==","archiveMembers":[],"isDirectory":false}}
```

`filesystemPathBytes` ist kanonisches Base64 der unveränderten POSIX-Bytes,
einschließlich nicht als UTF-8 darstellbarer Namen. Der Anzeigepfad enthält
gegebenenfalls Ersatzzeichen; er darf nicht für Dateiaktionen benutzt werden.
Beide Darstellungen müssen zueinander passen. NUL, leere Identitäten,
fehlerhaftes Base64 und widersprüchliche Pfade werden abgewiesen.
`searchRootPathBytes` erhält dieselbe Information für die Suchherkunft.

Der Umschlag hat absichtlich selbst keinen Pfad und kein `isDirectory`.
Alte App-Leser können ihn damit nicht als ausführbaren Treffer missverstehen.
`--extract-json` und Ansichtsfilter nehmen den Umschlag an; JSONL-Export erhält
vorhandene Byteidentitäten. Dateinamen und Archivstufen werden niemals an der
menschenlesbaren `!/`-Darstellung zerlegt oder kanonisch zusammengeführt.

Linux-Quellen können mit `tests/linux_shared_probe.py` direkt über die C-Grenze
geprüft werden. Der Test benötigt `FAVENIO_SHARED_LIBRARY`, den absoluten
`FAVENIO_ENGINE`-Pfad und die zur Bibliothek gehörende Swift-Laufzeit im Loaderpfad.
Die Prüfung umfasst tatsächliche Suchprozesse und byteverschiedene Dateinamen.
Ein erfolgreicher Unterbautest ersetzt keine GUI- oder Installationsabnahme.

## Versionierte portable Daten

Konfigurationen verwenden für äußere POSIX-Bytes Schema 8, Aufzeichnungen
Schema 9 und Vorlagen Format 9. Ältere Formate bleiben lesbar. Dublettenaufträge
verwenden Schema 3, Nachladeaufträge Schema 2, sobald Bytepfade vorkommen.
`--search-roots-bytes` transportiert höchstens 16 absolute Suchwurzeln als
kanonisches Base64; der Kern führt die Suche mit diesen Bytes aus. Linux-Datei-
aktionen benutzen native `OsString`-Pfade. Die AppKit-Oberfläche lehnt äußere
Pfade mit ungültigem UTF-8 ausdrücklich ab.

Linux-PDF-/OCR-Belege nennen Poppler/Tesseract als Leser und erhalten zusätzlich
einen Komponentenfingerabdruck. Ein Leserwechsel erfordert eine neue Suche,
bevor weitere Fundstellen nachgeladen werden. Die Mac-Leser bleiben unverändert.
Weitere Grenzen und Build-/Installationswege stehen in [LINUX.md](LINUX.md).
