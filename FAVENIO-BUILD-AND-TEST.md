# Favenio bauen und testen

## Bauen und testen

Vom Repo-Root:

```bash
python3 -m unittest discover -s tests
/usr/bin/python3 -m unittest discover -s tests
./build-app.sh
```

Der zweite Lauf ist wichtig: Die gebauten Apps verwenden den macOS-System-
Interpreter, dessen Verhalten vom Python der Login-Shell abweichen kann.
`build-app.sh` baut beide Bundles im Projektverzeichnis, kopiert Python-Kern und
Icons, signiert je nach verfügbarer Identität und führt die Headless-Selbsttests
aus. Eine Installation ersetzt weder einen Test noch einen Commit.

Erfolgskriterium der beiden Selbsttests ist ihre Schlusszeile `SELFTEST OK`,
nicht ihr Exit-Status (`run_selftest` in `build-app.sh`). `NSApp.terminate(nil)`
beendet den Prozess nämlich mit Status 0: Ein Selbsttest, der unterwegs
darüber stirbt, ist am Status nicht von einem bestandenen zu unterscheiden.
Am 2026-09-10 belegt — mit zurückgenommenem `windowWillClose`-Fix der
Schnellsuche meldete `build-app.sh` Erfolg, während deren Selbsttest mitten
im Lauf endete. Deshalb darf jede App ihre OK-Zeile genau einmal und als
letzte Handlung ausgeben; `tests/test_build_safety.py::SelfTestGateTest`
hält beides fest.

Die drei Skripte sind bewusst getrennt und dürfen nicht zusammenwachsen:

| Skript | Aufgabe | Fasst `/Applications` an |
| --- | --- | --- |
| `build-app.sh` | bauen und Selbsttests | nein |
| `install.sh` | bauen, notarisieren, nach `/Applications` kopieren | ja, nur nach Prüfung |
| `release.sh` | bauen, notarisieren, DMG bauen und notarisieren | nein |

Die Notarisierung der Bundles ist EIN Weg für beide: `notarize-lib.sh` wird von
`install.sh` und `release.sh` eingebunden (nur `source`, nie ausführen). Auch
die drei Pflichtprüfungen eines Bundles — Signatur, Gatekeeper-Urteil und
angeheftetes Ticket — kommen aus EINER Funktion dort
(`notarize_verify_installed`), von beiden Skripten UND vom Austausch selbst
gerufen. Die frühere Kopie in `release.sh` ließ `spctl` weg; ein Release ging
damit über eine schwächere Hürde als eine lokale Installation. Das DMG selbst
prüft `install.sh` weiterhin direkt — anderes Objekt, andere Anforderung. Beide
Bundles gehen zusammen in einem Zip zu Apple — `notarytool` nimmt kein nacktes
`.app` — und werden anschließend einzeln gestapelt. Deshalb tragen auch aus dem
DMG herausgezogene Apps ihr Ticket und starten offline.

`install.sh` prüft vor und nach dem Kopieren (`codesign`, `spctl`,
`stapler validate`), beendet laufende Instanzen freundlich, kopiert erst
vollständig daneben und tauscht dann. Geprüft wird auch die Produktidentität —
Bundle-ID je Bundle und gleiche Version in beiden — denn eine gültige Signatur
belegt nur „notarisiert", nicht „unsere App". Optional kommt das erwartete
Entwickler-Team aus `FAVENIO_TEAM_ID` oder clone-lokal aus
`git config --local favenio.teamId` (nicht eingecheckt, wie der
Notary-Profilname). Für `release.sh` ist diese Team-ID Pflicht; das Appcast-Tor
erhält sie aus der GitHub-Actions-Variable `FAVENIO_TEAM_ID`. Beide Release-
Wege prüfen jedes Bundle mit einer `codesign`-Anforderung auf genau dieses Team.
Der Austausch beider Bundles ist EINE Transaktion mit Rückholung des alten
Stands. Ein normaler Fehler darf keinen halb aktualisierten Stand hinterlassen;
scheitert die Rückholung selbst auf Dateisystemebene, muss dieser Ausnahmezustand
mit eigenem Status und den verbleibenden Pfaden sichtbar werden.
`--dmg <pfad>` installiert stattdessen aus einem fertigen DMG, `--verify-only`
prüft ohne zu installieren. Das angeheftete Ticket ist auf jedem Weg Pflicht,
auch aus einem DMG; sehr alte DMGs, die es nur am Image tragen, werden
abgelehnt (entschieden 2026-08-03). Exit 2 heißt in jedem Fall: installierter
Stand unverändert — auch dann, wenn ein Werkzeug mit einem anderen Status
abbricht. Exit 3 heißt: Der Rollback blieb unvollständig; stderr nennt die
verbleibenden Pfade und den Zustand, der manuell geklärt werden muss.
Zu „in jedem Fall" gehört auch SIGPIPE: In zsh läuft der EXIT-Trap dabei
so wenig mit wie bei SIGTERM (gemessen 2026-09-10), deshalb steht `PIPE` in
der Signalliste beider Skripte. Und der Fortschritt der Transaktion geht
nach stderr, nicht nach stdout — `install.sh | head` löste sonst mitten im
Austausch SIGPIPE aus und ließ Sperre, Ablage- und Sicherungsordner im
Zielordner liegen, bis jemand sie von Hand entfernte. Beides allein reichte
nicht für `2>&1 | head`: Trifft SIGPIPE ein EINGEBAUTES `echo`, führt zsh 5.9
den Trap mitten in stdio aus — in einer Funktion lief er endlos, im EXIT-Trap
hing ein externes Kommando mit Umleitung (`hdiutil detach … 2>/dev/null`;
gemessen 2026-09-17). Deshalb ist `echo` in `notarize-lib.sh` auf `/bin/echo`
umgelenkt: Jede Ausgabe schreibt ein Kindprozess, die Shell bekommt kein
SIGPIPE. `print`/`printf` nur innerhalb von `$(...)`; `trap '' PIPE` ist kein
Ersatz (danach lieferten spätere `$(...)` Status 141). Ein gescheitertes
`mv` bedeutet, dass das Bundle NICHT am Zielpfad liegt: Der vorsorglich
notierte Eintrag wird dann wieder herausgenommen, sonst hielte der Rollback
einen gleichnamigen Fremdkörper für ein fremdes Bundle und meldete 3 statt
2. `notarize_require_credentials` lehnt außerdem die Ad-hoc-Kennung `-`
ab — sie ist genau der Wert, den `build-app.sh` als „keine Developer-ID"
liest, und geerbt aus der CI-Umgebung kam sie bis 0.34.19 durch das Tor und
verbrauchte einen Notary-Vorgang für einen Fehler, den das Tor früh melden
soll.

`install.sh` und `release.sh` lehnen geerbte `SPARKLE_FEED_URL` und
`FAVENIO_SPARKLE_TEST_VERSION` gleich zu Beginn ab — VOR dem Bauen
(`install.sh` mit Exit 2, `release.sh` mit Exit 1). Beide gehören zum
Sparkle-Test im Projektverzeichnis; geerbt richteten sie die installierte
oder ausgelieferte App auf einen fremden Feed bzw. gaben ihr eine gefälschte
Build-Nummer, mit der sie sich sofort selbst ein „Update" anbietet. Die
nachgelagerte Feed-Prüfung greift erst NACH der Notarisierung und hätte einen
Notary-Vorgang bei Apple verbraucht; sie bleibt als zweite Linie. In
`release.sh` fehlte bis 0.28.3 die Hälfte: Nur die gefälschte Build-Nummer
wurde früh abgelehnt, ein geerbtes `SPARKLE_FEED_URL` erst im fertigen DMG.

`install.sh` und `release.sh` prüfen zusätzlich den Update-Feed der erzeugten
Bundles gegen `FAVENIO_FEED_URL` aus `notarize-lib.sh`. `build-app.sh` darf
über `SPARKLE_FEED_URL` weiterhin einen anderen Feed bauen (Sparkle-E2E-Test
im Projektverzeichnis); geerbt werden darf diese Variable nicht, sonst hört
eine installierte oder ausgelieferte App dauerhaft auf einen fremden Feed.

Das Appcast-Tor prüft ein heruntergeladenes Release-DMG auf angeheftetes
Notary-Ticket und Gatekeeper-Akzeptanz, **bevor** `hdiutil` es einhängt. Erst
danach werden Bundle-Signaturen, Entwickler-Team, IDs, Versionen, Update-
Schlüssel und Feed des Inhalts geprüft. Diese Reihenfolge nicht zurückbauen.

Neue Kernfunktionen benötigen Unit-Tests mit temporären Fixtures. Das bestehende
Fixture deckt normale Dateien, versteckte Dateien, Zip, Tar, verschachtelte Zip-
Archive, Inhaltssuche, Regex, JSON, Progress, Extraktion und Einzeldatei-Eingaben
ab. Keine Tests von lokalen Benutzerdateien oder fest eingebauten absoluten
Pfaden abhängig machen.

Testumfang nach Änderung:

- Matcher, Traversierung, Archive, Extraktion oder JSONL: Unit-Tests mit beiden
  Interpretern.
- gemeinsamer Swift-Kern oder Prozessaufruf: Unit-Tests plus `./build-app.sh`.
- Haupt-App: Build plus `Favenio --selftest`; sichtbare Interaktion zusätzlich
  gezielt am Fenster prüfen.
- FavenioQuick/Finder: Build, kontrollierter Fallback ohne Automation und ein
  Gerätetest mit Finder-Freigabe. Ablehnung muss funktionieren.
- Icons oder Layout: fenstergezielter Screenshot mit `CGWindowList` und
  `optionOnScreenOnly`; keine Vollbildaufnahme als Beweis.

`open -g` unterdrückt das Quick-Panel und ist kein valider UI-Test. Beim
fenstergezielten Screenshot existiert neben dem sichtbaren Panel ein unsichtbares
Fensterartefakt; nur sichtbare Fenster berücksichtigen.

## Verifizierte Fallen

- Ein `finally` läuft bei SIGTERM NICHT. Genau so brechen beide Apps jede
  Suche ab (`terminate()`), die Schnellsuche bei jedem Tastendruck — der
  `exiftool -stay_open`-Prozess blieb deshalb als Waise stehen, auf einem
  Entwicklungsrechner zwei Stück über 18 Stunden. `install_termination_handlers()`
  übersetzt SIGTERM und SIGHUP in ein normales Programmende; gegen SIGKILL
  hilft nichts.
- `time.monotonic()` kann beim System-Python nahe null starten. Für „noch keine
  Fortschrittsmeldung“ `None` verwenden; ein Startwert `0.0` kann die erste
  Meldung verschlucken.
- Bei Archivtreffern zeigt „Im Finder zeigen“ auf die materialisierte Temp-Datei,
  nicht in das Archiv hinein. Alle Aktionen müssen konsistent bleiben.
- `open -g` ist kein Beweis, dass FavenioQuick kein Panel öffnet.
- Finder-Automation kann beim ersten Zugriff einen Systemdialog auslösen. Dieser
  darf weder automatisiert bestätigt noch als Fehler verschleiert werden.
- Finder-Fenster nur in EINER Abfrage holen, mit `URL of` und
  `front Finder window`. Eine Schleife über die Fenster kostet je Fenster einen
  eigenen Apple-Event: gemessen am 2026-07-25 mit 13 offenen Fenstern 11,6 s
  gegenüber 147 ms; `as alias` statt `URL of` kostet weitere 38 ms, und
  `front window` scheitert an geöffneten Info-Fenstern. Solche Laufzeiten
  schlagen als „falscher Suchordner" durch, weil die Oberfläche längst mit dem
  Ersatzordner weiterarbeitet. Die volle Herleitung samt Alternativenprüfung
  ist intern dokumentiert (Wissensnotiz „finder-aktueller-ordner").
- Vor der Abfrage `AEDeterminePermissionToAutomateTarget` fragen (ohne Event,
  ohne Dialog). Verbotene Automation ist damit sofort bekannt, statt aus einem
  hängenden Unterprozess erschlossen zu werden. Steht der Freigabedialog offen,
  nicht abbrechen — sonst wirft die App die Freigabe weg, auf die sie wartet.
- Eine gescheiterte Finder-Abfrage ist ein meldepflichtiger Zustand, kein
  leeres Ergebnis. `FinderScopeOutcome` unterscheidet verweigerte Automation,
  fehlendes Fenster und Zeitüberschreitung; die Frontends müssen den Grund
  zeigen und den tatsächlich durchsuchten Ordner benennen.
- `--finder-scope` beantwortet headless, was ein App-Bundle beim Finder wirklich
  sieht. Dasselbe AppleScript aus dem Terminal wird von TCC anders bewertet und
  beweist deshalb nichts über die App.
- Die App verwendet möglicherweise ein anderes Python als die Shell. Neue
  Syntax und argparse-Varianten immer mit `/usr/bin/python3` prüfen.
- Streaming-Ergebnisse dürfen eine aktuelle Auswahl nicht bei jedem Append
  zurücksetzen.
- Persistente Zustände der Oberfläche speichern Daten oder zeitneutrale Sätze,
  nie eine fertig formulierte Präsensmeldung. Quick setzt die Infozeile erst,
  wenn der Zustand der Pause oder des Abschlusses feststeht. `runScopeMismatch` hält deshalb nur die beiden Pfade,
  `runScopeNoteText()` formuliert daraus je nach Zustand — vorher stand dort
  „Suche läuft in …", obwohl die Suche fertig war.
- zsh liest `~/.zshenv` auch für Skripte. Exportiert die Datei
  `NOTARY_PROFILE`, ist ein leerer Wert aus der Umgebung eines Tests schon
  vor der ersten Zeile von `release.sh` überschrieben (belegt 2026-09-05).
  Ein Test, der `release.sh` startet, bremst deshalb nicht über Variablen,
  sondern über Attrappen für `git`, `security` und `xcrun` vor dem PATH.
- In zsh läuft ein `trap … EXIT` bei SIGINT (Ctrl-C) und SIGHUP mit, bei
  SIGTERM aber NICHT (gemessen 2026-09-03 mit Signal an die ganze
  Prozessgruppe). `install.sh` ergänzt deshalb `trap 'exit 2' HUP INT TERM`;
  das löst den EXIT-Trap aus, sodass `cleanup` genau einmal läuft.
- Ein funktionslokaler `trap … EXIT` läuft in zsh beim Verlassen der Funktion,
  auch auf dem errexit-Pfad — so räumt `notarize_apps` sein `mktemp`-Stage
  in jedem Fall auf. Der Pfad muss dabei beim SETZEN eingesetzt werden
  (`trap "rm -rf ${(q)stage}"`): Die Variable ist `local` und beim Auslösen
  längst weg, unter `set -u` scheiterte der Trap sonst an „parameter not set"
  und riss den Lauf mit.
- `rmdir` auf den DMG-Mountpoint ist Absicht, kein Versehen: Ein `rm -rf` auf
  einen womöglich noch eingehängten Pfad wäre gefährlich. Eine Test-Attrappe
  für `hdiutil` muss den Mountpoint bei `detach` deshalb selbst leeren — sonst
  bleibt je Testlauf ein Temp-Ordner liegen.
- `set -e` schützt die Befehle innerhalb einer Shell-Funktion NICHT, wenn die
  Funktion als Bedingung eines `if` aufgerufen wird — genau so übernimmt
  `install.sh` den unterscheidbaren Status von `favenio_install_bundles`.
  Kritische Rollback-Schritte müssen ihren Fehler deshalb selbst behandeln:
  `_favenio_install_restore` nimmt ein schon
  eingesetztes Bundle per geprüftem `mv` weg statt per ungeprüftem `rm -rf`, das
  obendrein halb gelingen und ein zerpflücktes Bundle hinterlassen kann.
- Austausch und Rollback eines gemeinsamen Installationsziels sind pro Zielordner
  serialisiert (Sperrverzeichnis `.favenio-install.lock`; `install.sh` nimmt sie
  auch bei Abbruch wieder ab). Der Rollback löscht nie allein anhand des
  Bundle-Namens: Hat ein paralleler Lauf den Zielpfad inzwischen ersetzt, erkennt
  die beim Einsetzen gemerkte Kennung des Verzeichniseintrags (Gerät und Inode)
  das fremde Bundle und lässt es stehen.
