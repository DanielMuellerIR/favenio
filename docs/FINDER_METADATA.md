# Finder-Eigenschaften

Die CLI liest Finder-Tags und Finder-Kommentare getrennt von eingebetteten
Medienmetadaten. Dateien und Ordner brauchen keine bestimmte Endung, keinen
Spotlight-Index und keinen exiftool-Prozess. Beide Apps bieten dieselben Felder
im gemeinsamen Kriterieneditor und reversiblen Ansichtsfilter.

## Bedienung und erfasster Suchstand

Die Kriterienfelder **Finder-Tag** und **Finder-Kommentar** verwenden dieselben
Textoperatoren wie die übrigen Textfelder. **Weitere Filter → Finder-Eigenschaften
erfassen** erfasst beide Eigenschaften auch ohne Finder-Kriterium. Ohne diese
Wahl liest eine gewöhnliche Namenssuche keine Finder-Attribute.

**Finder-Eigenschaften** unter der Trefferliste öffnet eine begrenzte, scrollbar
lesbare Darstellung der erfassten Tags mit Farben und des vollständigen Kommentars.
Das Kontextmenü des Tabellenkopfs blendet optional **Finder-Tags** und
**Finder-Kommentar** ein. Einblenden aktiviert die zusätzliche Erfassung für die
nächste Suche; sichtbare Spalten werden beim Neustart wiederhergestellt.
Die Spalten zeigen eine Zeile; „↵“ kennzeichnet Zeilenumbrüche in Tags und
Kommentaren. Der Tooltip und die Vorschau erhalten den vollständigen Originaltext.
Auswahl, Spalten, Ansichtsfilter und historisches Öffnen verwenden den erfassten
Suchstand ohne erneute Attributabfrage. Eine neue Suche erfasst einen neuen Stand.
Bekannt leer erscheint als **Leer**; nicht erfasste und unbekannte Werte behalten
ihren jeweiligen Grund. Historische Werte behaupten keine aktuelle Quellengültigkeit.

## Suche und Ausgabe

Ein CLI-Kriterienbaum mit `schemaVersion: 3` kann `finderTags` oder
`finderComment` mit `contains`, `equals`, `glob` oder `regex` verwenden.
`caseSensitive` und `negate` haben die bisherigen Bedeutungen. Beispiel:

```sh
./favenio.py --json --criteria-json '{"schemaVersion":3,"root":{"id":"tag","field":"finderTags","operator":"equals","value":"Projekt"}}' "$HOME/Documents"
```

Ein Tagkriterium vergleicht jeden Tag-Namen einzeln; es genügt ein passender
Name. Ein negiertes Kriterium verlangt, dass keiner passt. Farbanteile gehören
nicht zum Namen. Kommentare werden als ein vollständiger Text verglichen,
einschließlich ihrer Zeilenumbrüche. Die vorhandene Unicode-/Mustersemantik
gilt unverändert. Schema 3 kann auch bisherige Kriterien und Kalenderwerte
enthalten. Schema 1/2 akzeptieren die neuen Finder-Felder nicht.

`--finder-metadata --json` erfasst beide Finder-Eigenschaften für Objekte, die
zur übrigen Suche passen, auch ohne Finder-Kriterium. Normale Suchen lesen
keine Finder-Attribute. Namen und bekannte Fakten werden zuerst geprüft;
innerhalb einer Objektprüfung teilen alle Finder-Kriterien einen Snapshot.
Ein erfolgreicher ODER-Zweig kann die Attributabfrage vollständig vermeiden.

JSONL-Treffer mit gelesenen Finder-Eigenschaften enthalten `finderMetadata`:
`schemaVersion: 1`, die erfasste `sourceGeneration` und `fields` mit den
angefragten Eigenschaften. Tags tragen `name`, `color` und den unveränderten
`raw`-Text. Ein abschließendes LF plus Ziffer 0–7 ist der gespeicherte
Farbanteil; ohne diesen Anteil ist `color` null. Der Kommentar steht als
unveränderter `value`-Text im Feld. `criteriaEvidence` nennt das eigenständige
Finder-Feld und einen begrenzten passenden Wert.

## Verfügbarkeit und Grenzen

Nur `status: available` ist ein bekannter Wert. Ein ausdrücklich gespeicherter
leerer Tagbestand oder Kommentar ist bekannt leer. `absent`, `unreadable`,
`invalid`, `limited`, `unsupported`, `notApplicable` und `sourceChanged` sind
unbekannt und werden durch Negation nicht zu Treffern. Ein nicht vorhandenes
Attribut ist damit keine stillschweigend bewiesene Abwesenheit.

Der Leser verwendet die nativen Darwin-Attribute
`com.apple.metadata:_kMDItemUserTags` und
`com.apple.metadata:kMDItemFinderComment` mit `getxattr`/`XATTR_NOFOLLOW`.
Er öffnet keinen Dateiinhalt. Symbolische Links und Spezialdateien werden
nicht gelesen; Archivmitglieder besitzen keine Finder-Eigenschaften der
entpackten Datei. Die äußere Archivdatei kann eigene Finder-Attribute besitzen.
Auf anderen Plattformen bleiben Finder-Werte unbekannt.

Jedes Attribut ist auf 64 KiB begrenzt. Hinzu kommen höchstens 256 Tags mit
je 1024 UTF-8-Bytes, 32 KiB Kommentartext, 1024 binäre Plist-Objekte und
256 KiB für den gesamten JSON-Snapshot.
Übergrößen werden verworfen und nicht zu einem scheinbar vollständig
geprüften Rest gekürzt. Binäre Plist-Tabellen werden vor der Parserallokation
geprüft. Dateigerät, Inode, Größe sowie Änderungs-/Metadatenzeit binden den
Snapshot vor und nach dem Lesen. Ändert sich die Quelle danach vor der
Ausgabe, entfällt ein auf diesem Finder-Beleg beruhender Treffer. Eine bloß
optionale Metadatenanzeige entfernt keinen unabhängig bewiesenen Namenstreffer.

`--filter-results` kann dieselben Finder-Kriterien auf erhaltene Snapshotwerte
anwenden. Es validiert deren Schema, Grenzen, Namen/Farben und Übereinstimmung
mit bekannten Trefferfakten, ohne Quellen erneut zu lesen. Nicht erfasste Werte
bleiben unbekannt. Nicht angefragte zukünftige Snapshotformate bleiben beim
CLI-Filtern anderer Fakten unverändert erhalten. Der grafische Ansichtsfilter
verwendet denselben eingefrorenen Kernfilter.

Das gemeinsame Swift-Modell prüft begrenzte Snapshotdaten vor der Hit-Übernahme,
erhält die JSON-Bytes und unterscheidet unbekannt von bekannt leer. Ursprüngliche
Zahlenlexeme werden vor Dictionary-Roundtrips geprüft; führendes U+FEFF, NFD,
Kommentarumbrüche und CRLF am Farbsuffix bleiben erhalten. Widersprüchliche
Snapshots, Dateifakten oder Archivkontexte werden abgewiesen.

## Versionen und Exporte

Finder-Fragen verwenden Kriterienschema 3 und Konfigurationsformat 4.
Vorlagen, Quick-Übergaben und Aufzeichnungen mit Finder-Fragen oder erfassten
Finder-Werten verwenden Format 5. Die Fähigkeit heißt
`finderMetadataSchemaVersion: 1`; Quick prüft zusätzlich die entsprechende
Bundle-Fähigkeit. Alte Fragen bleiben im kleinsten passenden bisherigen Format.
Kalenderfragen in Schema 3 behalten denselben Laufzeitpunkt und dieselben
eingefrorenen Grenzen; Format 5 ersetzt diese Belege nicht.

Neue Fragen und Snapshotdaten werden vor Zustandsänderung validiert. Der
Aufzeichnungshelfer prüft die benötigten Empfängerfähigkeiten vor configure/open
und weist doppelte JSON-Felder bereits beim Dateilesen ab. Historische Aufnahmen
behalten die ungefilterte Quellmenge; ein Ansichtsfilter verändert die Aufnahme
nicht stillschweigend.

JSONL erhält den vollständigen Snapshot mit Quellengeneration. CSV ergänzt
`finderTags`, `finderTagColors`, `finderComment`, `finderTagsStatus` und
`finderCommentStatus`. Tag-Namen und Farben sind JSON-Listen innerhalb ihrer
CSV-Zelle; Kommentarumbrüche werden normal nach CSV maskiert. Fehlende erfasste
Felder erhalten den Status `notCaptured`, bekannte leere Listen bleiben `[]`.

Eine zusätzlich aktive [lokale Lesepolitik](LOCAL_CONTENT.md) benötigt
Konfigurationsformat 5 und Vorlagen-/Quick-/Aufzeichnungsformat 6; die bisherigen
Finder-/Kalenderbelege und Fähigkeiten bleiben dabei erhalten.
