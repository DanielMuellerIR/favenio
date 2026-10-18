# Explizite Dublettenprüfung

Die Prüfung startet ausschließlich auf Anforderung in beiden Apps oder über
`--duplicates-file JSON`. Sie vergleicht Originalbytes normaler Dateien.
Namen und Suchbelege beeinflussen die Gleichheit nicht. Archivdateien gelten als
gewöhnliche Datei; Mitglieder werden in beiden Apps über den gemeinsamen
Materialisierer einbezogen. Container und Mitglied bleiben getrennte Objekte.
Es werden keine Dateien gelöscht oder verändert und keine Speicherersparnis
berechnet. Insbesondere sind mehrere Hardlinkpfade kein mehrfach belegter Inhalt.

## Menge und Ablauf

Der Dialog hält beim Öffnen Auswahl und aktuell gefilterte Treffer fest,
einschließlich Treffern in eingeklappten Gruppen. Vor Start stehen die Anzahl
der Objekte, enthaltenen Archivmitglieder und ausgenommenen Ordner sichtbar fest.
Ein neuer Suchlauf ändert diesen Auftrag nicht. Die lokale Inhaltsoption wird
zunächst aus der Suche übernommen und lässt sich vor Start ausdrücklich ändern.
`--local-only` verwendet dieselbe macOS-/Provider-Politik wie die Inhaltssuche;
bei unbekanntem oder entferntem Zustand wird kein Inhaltsleser gestartet.

Der Python-Kern ermittelt Dateigröße und Generation neu. Nur mehrfach vorhandene
Größen brauchen einen vollständigen Streaming-SHA-256. Passende Hashes werden
immer zusätzlich byteweise bis zum Dateiende verglichen; selbst eine
Hashkollision erzeugt keine falsche Gruppe. Beide Leser brauchen nur begrenzte
Blöcke, keinen vollständigen Dateiinhalt im Speicher. Dateigenerationen aus
Gerät, Inode, Größe, mtime und ctime werden vor/nach jedem Leser und vor der
Ergebnisbildung gegen Pfad und geöffneten Deskriptor geprüft.

Das Ergebnis ist ein Beleg für den genannten Prüfzeitpunkt, keine dauerhafte
Überwachung oder transaktionale Dateisystemsperre. Fehler oder veränderte Quellen
bleiben unbekannt. Eine Teilprüfung kann Gruppen der stabil bestätigten Teilmenge
zeigen, nennt aber ausdrücklich ihre unvollständige Abdeckung. Abbruch sowie
Zeit-/Leselimit verwerfen sämtliche Gruppen. Die Apps zeigen während des Lesens
Fortschritt und bleiben bedienbar; ein späteres Ergebnis nach Abbruch wird verworfen.

Hardlinks und symbolische Verknüpfungen werden als solche benannt. Jede Gruppe
nennt neben Pfaden die Anzahl verschiedener (Gerät, Inode)-Paare. Ein Symlink
wird wie eine normale Suchdatei über sein reguläres Ziel gelesen; nicht reguläre
Objekte, einschließlich benannter Pipes, werden ohne blockierendes Öffnen abgelehnt.

## Auftrag und Grenzen (Schema 1)

```json
{"schemaVersion":1,"items":[
  {"id":"a","filesystemPath":"/absolute/first"},
  {"id":"b","filesystemPath":"/absolute/second"}
],"limits":{"maxReadBytes":68719476736,"maxSeconds":300}}
```

Schema 1 erlaubt ausschließlich diese Felder. Schema 2 erweitert sie wie unten beschrieben. IDs sind eindeutig, 1–64 ASCII-Zeichen aus
Buchstaben/Ziffern/Unterstrich/Minus. Pfade sind absolut, ohne NUL und höchstens
16384 Dateisystembytes lang; lexikalisch normalisierte Pfadbytes müssen eindeutig
sein. Namen werden nicht Unicode-normalisiert. `limits` und seine Felder sind
optional und dürfen die Standardgrenzen nur verkleinern.

Höchstens 50000 Objekte und 32 MiB UTF-8-JSON je Auftrag. Doppelte JSON-Felder,
NaN/Infinity, Bool statt Zahlen und Archividentitäten werden zurückgewiesen.
`-` liest den Auftrag aus stdin. Die Aktion darf nur mit `--local-only` und
`--json` kombiniert werden; stdout ist immer JSONL. Die Apps schreiben den
Auftrag mit privaten Rechten in einen eigenen temporären Ordner und entfernen
ihn nach Abschluss, Abbruch oder Beenden.

Höchstens 64 GiB Vergleichsbytes und 300 Sekunden einschließlich Archivvorbereitung.
Hash und Bytevergleich belasten dasselbe Budget, auch bei Hardlinks. Zur sicheren
Unterscheidung von Dateiende und Budgetüberschreitung kann höchstens ein weiteres
Byte gelesen werden. Fortschritt ist auf etwa zehn Ereignisse je Sekunde begrenzt,
zuzüglich Phasenwechseln. Antwortzeilen sind in den Apps auf 32 MiB begrenzt.
Die Grenzen begrenzen den eigenen Ablauf; sie sind keine Zusage einer harten
Laufzeit für jeden Dateisystemaufruf. Die App kann ihren Prozess abbrechen und
nach einer Sekunde nötigenfalls beenden.

## JSONL-Antwort

`duplicateProgress` trägt `schemaVersion: 1`, `phase` (`facts`, `hash`, `confirm`,
`validate`), `done`, `total`, `readBytes` und optional `currentID`.

Genau ein abschließendes `duplicateResult` trägt `schemaVersion: 1`,
`state` (`completed`, `partial`, `limited`, `cancelled`), `complete`,
`checkedAt` (UTC ISO-8601), `scopeCount`, `hashedFiles`, `readBytes`, `groups`,
`files`, `issueCount` und höchstens 32 `issues`. Vollständig ist nur `completed`.
Ein Gruppenobjekt enthält `id`, mindestens zwei eindeutige `memberIDs`,
`sha256`, `size`, `physicalFiles` und `byteVerified: true`.
`files` enthält ausschließlich Gruppenmitglieder unter ihrer ID mit
`sourceGeneration` (fünf dezimale Strings wie im Vorschauvertrag), `size`,
`linkKind` (`regular`, `hardlink`, `symbolic`) und `linkCount`.

Auslassungen nennen optional die Objekt-ID sowie `reason` und `message`:
`changed`, `unreadable`, `notRegular`, `localContentNotLocal`,
`localContentUnknown`, `byteLimit`, `timeLimit`. `issueCount` zählt alle Gründe,
die begrenzte Liste enthält deren erste Beispiele. Exit 0 bedeutet vollständige
Prüfung mit Gruppen, 1 vollständige Prüfung ohne Gruppen, 2 Fehler oder
unvollständige Prüfung. Ein geschlossener stdout-Leser endet still.

## Archivvorbereitung und Schema 2

Die Apps lösen Archividentitäten ausschließlich durch befristete Leases des
bestehenden `MaterializationManager` auf. Laufende Auspackaufträge und bereits
bekannte Cachedateien werden mit Öffnen, Vorschau und Drag-and-drop geteilt.
Ein Mitglied wird je Identität einmal materialisiert; Hash und Bytevergleich
lesen anschließend dieselbe reguläre Cachedatei. Nach der Prüfung werden die
Leases freigegeben. Ausdrücklich geöffnete Dateien bleiben nach der bisherigen
Cachepolitik erhalten. Die ursprünglichen `filesystemPath`, `archiveMembers`
und `archiveMemberBytes` bleiben bei Gruppen, Öffnen/Vorschau und JSONL-Export
unverändert. Ein sichtbares U+FFFD führt verschiedene Namensbytes nicht zusammen.

Unbekannte Kataloggrößen werden nach dieser ausdrücklich angeforderten,
begrenzten Materialisierung per stat bekannt. Vollständiges Auspacken prüft
auch die vom Format gelieferten Integritätsbelege, etwa ZIP-CRC. Ein dabei
auftretender Fehler ist eine Auslassung der Dublettenprüfung; die bestehende
Early-Exit-Suche bleibt unverändert. Normale Dateien werden weiter unmittelbar
nach Größe vorgefiltert, ohne vorherige Volllektüre.

Die Vorbereitung läuft sequenziell nebenläufig zur Oberfläche. Höchstens 1 GiB
Archivdateien werden dafür gleichzeitig festgehalten; vor jedem Abruf wird die
maximale Mitgliedsgröße reserviert. Bei kleinerem Rest wird konservativ ausgelassen,
auch wenn ein unbekannt großes Mitglied später kleiner sein könnte. Je
Materialisierungsauftrag gelten weiterhin höchstens 256 MiB je Mitglied,
1 GiB über dessen verschachtelte Entpackstufen und Ratio 1000; strengere
mitgeführte Vorschaugrenzen bleiben erhalten. Weiter gefasste mitgeführte Grenzen
werden für diese Prüfung mit Grund ausgelassen. Konkurrierende ausdrückliche
Materialisierungsaufträge werden nicht enger begrenzt. Die 64-GiB-Grenze zählt
Hash-/Vergleichslektüre; Entpackgrenzen gelten getrennt je Materialisierungsauftrag.
Die gemeinsame 300-Sekunden-Frist umfasst Vorbereitung und Vergleich.

Schema 1 bleibt unverändert. Schema 2 akzeptiert zusätzlich je regulärem oder
bereits materialisiertem Dateipfad `expectedGeneration` und optional
`sourceGuard: {filesystemPath, generation}`. Beide Generationen verwenden die
fünf dezimalen Strings des Vorschauvertrags. Der Kern prüft die erwartete
Inhaltsgeneration sowie die zusätzliche äußere Quelle vor/nach Lesen und bei
der Abschlussprüfung. Ein geänderter Cacheinhalt oder ein verändertes äußeres
Archiv bleibt unbekannt. Die Apps beziehen diese Belege aus dem gemeinsamen
Materialisierungscache, ohne sie erneut aus aktuellen Metadaten zu erfinden.

Bereits fehlgeschlagene Vorbereitungen werden als `unavailable: {reason, message}`
übergeben (`archiveError` oder `archiveLimit`, höchstens 1024 Zeichen). Sie bleiben
in `scopeCount` enthalten, werden nicht geöffnet und erzeugen einen explizit
unvollständigen Abschluss. Mehrere solche Objekte dürfen dieselbe äußere Datei
nennen; vergleichbare Pfade bleiben eindeutig. Antworten verwenden die jeweilige
Schema-Version; Gruppenmitglieder mit Quellwache tragen zusätzlich
`files[id].guardGeneration`. `physicalFiles` zählt die tatsächlich verglichenen
regulären Dateisystemobjekte. Die Apps benennen bei Archivgruppen stattdessen
Objekt- und Archivmitgliedszahl, da befristete Dateien keine Speicherersparnis belegen.

Die CLI vergleicht die angegebenen regulären beziehungsweise bereitgestellten
Dateipfade. Archivketten und Rohname-Identitäten werden über das bestehende
`--extract-json` materialisiert; die Apps verbinden diesen Schritt über den
MaterializationManager mit der Prüfung. Eine Quellwache belegt eine unveränderte
zusätzliche Datei; die Zuordnung des bereitgestellten Inhalts zur Archividentität
stammt aus dem gemeinsamen Materialisierer.

Im lokalen Modus prüfen die Apps jede Archivwurzel vor Aufnahme in einen gemeinsamen Auspackauftrag über den bestehenden Kern-Metadatenvortest (höchstens zwei Sekunden). Nicht lokale oder unbekannte Wurzeln erzeugen dadurch keinen Hintergrundauftrag, der ein gleichzeitig ausdrücklich gewünschtes Öffnen übernehmen könnte. Der Vortest bleibt innerhalb der gemeinsamen 300-Sekunden-Frist. Vorbereitungszustand bleibt auf einer eigenen seriellen Queue, Fortschritte werden als unveränderliche Momentaufnahmen an Main übergeben.
