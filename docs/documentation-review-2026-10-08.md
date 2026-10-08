# Dokumentationsabgleich 2026-10-08

Basis: Favenio 0.38.0. Beide READMEs, aktuelle CLI-Hilfe, Controllervertrag,
Automationsbeschreibung, Backlog, aktueller Changelog und Build-/Installations-/
Release-Anleitungen gegen Implementierung und ausgeführte Prüfungen abgeglichen.
Historische Review- und Messberichte bleiben datierte Belege ihres damaligen Stands.

Korrigiert:

- Nicht-UTF-8-Archivnamen sind in JSON und Apps seit der bytegenauen Identität
  verfügbar; alte gegenteilige Aussagen entfernt und `archiveMemberBytes`
  in Vertrag und Beispiel ergänzt.
- Installer-Exit 2 bedeutet unverändert oder erfolgreich zurückgerollt;
  Exit 3 bezeichnet unvollständigen Rollback. `--verify-only` baut/notarisiert
  ohne DMG weiterhin, installiert aber nicht.
- Controlleroperationen für Aufzeichnungen, Fähigkeiten und Grenzen ergänzt;
  den überholten Verweis auf eine noch ausstehende Etappe entfernt.
- Aufnahmehinweise bei den Steuerungsbefehlen statt hinter der Lizenz eingeordnet.
- Frühes Leseende bei mehreren Inhaltsbegriffen und das Pfadexport-Beispiel
  präzisiert: Archivmitglieder brauchen vor externem `grep` Materialisierung.

Prüfung: Alle aktuellen langen CLI-Optionen sind in beiden READMEs vorhanden;
relative lokale Dokumentationslinks lösen auf. `git diff --check` bestanden.
Die aktuelle Produktprüfung umfasst 574 Tests je Interpreter, beide
App-Selbsttests, Notarisierung/Signaturen/Gatekeeper und native Fensterproben
für Übergabe sowie Aufzeichnung. Dokumentationskorrekturen ändern kein Produktverhalten.

Grenzen: Aufzeichnungen bewahren keine historischen Dateiinhalte und nur die
Warnungszahl der bestehenden GUI. Ein gespeicherter Trefferstand garantiert
keine heutige Verfügbarkeit seiner Quellen. Ein vollständiger neuer Code-Review
ist eine separate Prüfung; dieses Dokument behauptet ihn nicht.


## Intensiver Code-Review und Schlussprüfung, Version 0.38.3

Elf Bereiche der eigenen Quellen, Tests, Hilfswerkzeuge und Verträge sind
aktuell geprüft. Bestehende Vollprüfungen wurden durch vollständige Deltas und die
heutigen Ein-/Ausgänge ergänzt; neue Controller-, Übergabe- und
Aufzeichnungsmodule wurden vollständig geprüft. Suchsemantik bleibt allein
im Python-Kern. Es gibt keine offenen Querschnittsfunde oder nicht zugeordneten
Quellen im festgelegten Scope.

Vier belegte Produktfehler wurden während der Reviewkampagne korrigiert:
die Bindung der Empfängerbereinigung an die bestätigte eigene Sitzung,
unterschiedliche exakte Identitäten für ZIP-Datei `same` und Ordner `same/`,
der fehlende Auspackhinweis bei aufgezeichneten Ständen sowie ein alter
Suchprozess nach einer ungültigen Quick-Übergabe. Die beiden letzten
Selbsttestregressionen wurden jeweils zuerst gegen die fehlerhafte Fassung
bestätigt. Die veraltete Planung der inzwischen abgenommenen Suchautomatisierung
wurde aus dem Backlog entfernt; die Abnahmebelege stehen bei der Beschreibung.

Schlussprüfung:

- 575 Tests mit dem üblichen Python (56,627 s) und 575 mit System-Python
  (53,949 s), beide App-Selbsttests und der vollständige Build bestanden.
- Beide Bundles von 0.38.3 notarisiert und gestapelt; Signaturen, Gatekeeper,
  Bundle-Identitäten, Feed und Version geprüft. Der installierte Prüfstand
  enthält dieselben App-Binaries und bytegleichen Python-Ressourcen.
- Native Controller-, Aufzeichnungs- und Quick-Bereichsprüfungen bestanden.
  Beide ungültigen Quick-Übergabevarianten beenden den echten alten Python-Lauf,
  leeren seine Treffer und behalten den sichtbaren Fehlerzustand.
- Ein echter Archivtreffer mit 251.657.280 Byte wurde im aufgezeichneten Stand
  ausgepackt. Der eigene Entpackprozess wurde für die Fensteraufnahme kurz
  angehalten: Lade- und Escape-Hinweis sind sichtbar; Escape beendet die
  Extraktion, danach verschwindet der Ladehinweis. Zehn abschließende
  Fensterbilder wurden visuell geprüft. Test-Apps danach ausgeblendet und beendet.
- Die zusätzliche TAR→Python→Swift→Materialisierungsprobe bestätigt getrennte
  Inhalte bei sichtbar gleichen, byteverschiedenen Eintragsnamen. Der
  SIGTERM-Messweg bestand zwei begrenzte Wiederholungen einschließlich Rollback.
- Dokumentationsvertrag, lokale Dateiverweise und Diff-Nachprüfung bestanden.

Die dokumentierten Produktgrenzen gelten weiter: Aufzeichnungen speichern
keine historischen Inhalte; große äußere Archive können nur an ihre
Quellengeneration gebunden sein. Die historische Ursache des sporadischen
SIGTERM-Testfehlers bleibt ungeklärt und wurde auch jetzt nicht reproduziert.
Dieser Review behauptet weder einen neuen Release noch eine erneute Behebung
dieser historischen Ursache.
