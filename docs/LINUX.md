# Favenio und FavenioQuick unter Linux

Die Linux-Ausgabe verwendet Rust und GTK 4 für die Oberfläche. Die Suche bleibt
in `favenio.py`; Swift-Modelle, Prozesssteuerung, Archivmaterialisierung,
Aufzeichnungen, Dubletten und Fundstellen werden aus denselben Quellen wie für
die macOS-Apps gebaut. Details stehen im [gemeinsamen Unterbau](PORTABLE_CORE.md).
Die Desktop-Anbindung wurde unter Cinnamon/X11 und Plasma/Wayland mit Nemo und
Dolphin geprüft, einschließlich Quick-Übergabe, Vorschau, Zwischenablage und
Drag-and-drop. Die Datei- und Archivübergabe an einen korrigierten Fastra-Linux-Empfänger ist
unter Cinnamon/X11 und Plasma/Wayland geprüft. Das signierte Linux-Paket steht
im [Linux-Release](https://github.com/DanielMuellerIR/favenio/releases/tag/v0.66.2)
bereit.

## Voraussetzungen

Ziel ist Linux x86_64 mit glibc ab 2.39, GTK ab 4.14, OpenSSL 3 und Python ab 3.10.
Die Swift-Laufzeit wird privat mitgeliefert. Es muss kein Swift installiert sein.
Die Anwendung benötigt weder einen Suchindex noch einen Hintergrunddienst.

Unter Linux Mint 22 sind die Laufzeitpakete:

```sh
sudo apt install libgtk-4-1 libssl3t64 python3 zenity
```

Für die optionalen Dokument-, OCR-, Metadaten- und Archivfunktionen:

```sh
sudo apt install poppler-utils tesseract-ocr tesseract-ocr-deu tesseract-ocr-eng \
  libimage-exiftool-perl libarchive-tools zstd nemo-python
```

Unter CachyOS beziehungsweise Arch Linux:

```sh
sudo pacman -S --needed gtk4 openssl python kdialog poppler tesseract \
  tesseract-data-deu tesseract-data-eng perl-image-exiftool libarchive zstd
```

Bildformate hängen zusätzlich von den installierten GdkPixbuf-Ladern ab.
Fehlende optionale Helfer werden beim betreffenden Auftrag konkret gemeldet.
Der Suchkern allein benötigt weiterhin nur die Python-Standardbibliothek.
Für die optionale Übergabe an Fastra muss dessen Linux-Ausgabe mit ihren eigenen
Abhängigkeiten separat installiert sein, insbesondere GtkSourceView 5 und
WebKitGTK 6. Der geprüfte Fastra-Reparaturstand erhält automatische Zielauswahlen
auch bei PRIMARY-Wechseln unter Wayland; abweichende ältere Empfänger können die
Übernahme während des Ladens abbrechen.

## Bauen

Auf einem Linux-x86_64-Rechner mit Docker:

```sh
linux/build-container.sh debug
linux/build-container.sh package
```

Der Paketbau erzeugt `dist/linux/favenio-<Version>.tar.gz`. Der Container fixiert
Rust und Swift und enthält GTK-Entwicklungspakete. Cargo verwendet `Cargo.lock`.
Für einen direkten Bau mit vorhandenen Werkzeugketten dient `linux/build.sh`.
Ein Entwicklungsstand startet über `.build/linux/launch`, Quick zusätzlich mit
`--quick --directory /gewünschter/ordner`. Entwicklungsstände werden nicht in
Systemordner kopiert.

## Signiertes Paket installieren

Paket, `linux-update.json` und `linux-update.json.sig` müssen zusammengehören.
Der Installer wird aus einer vertrauenswürdigen Favenio-Ausgabe oder dem
geprüften Quellcheckout aufgerufen:

```sh
python3 -B linux/install.py favenio-<Version>.tar.gz linux-update.json linux-update.json.sig
```

Im entpackten Auslieferungspaket liegt derselbe Installer als `install.py`.
Er prüft Ed25519-Signatur, Version, Größe, SHA-256, Archivpfade und die enthaltene
Laufzeit, bevor er den aktiven Versionsverweis austauscht. Installation und Updates
brauchen kein sudo. Ziel ist `$XDG_DATA_HOME/favenio`, ersatzweise
`~/.local/share/favenio`. Desktop-Starter starten Haupt-App und Quick getrennt.
Vorlagen liegen außerhalb des Versionsordners unter `Favenio/search-templates.json`.

## Dateimanager

Nemo zeigt bei lokalen Ordnern einen Knopf „Mit FavenioQuick hier suchen“ über dem
Ordnerinhalt. Er erhält den Ordner direkt aus der betreffenden Ansicht. Eine
markierte Datei ändert den Suchbereich nicht. `nemo-python` muss installiert sein;
der Adapter wird beim nächsten regulären Start von Nemo geladen. Zusätzlich gibt
es eine Nemo-Aktion im Kontextmenü.

Dolphin erhält „Hier mit FavenioQuick suchen“ im Ordner-Kontextmenü. Ein eigener
Werkzeugleistenknopf ist nicht Bestandteil der allgemeinen Dolphin-Erweiterungs-
schnittstelle. Die Aktion übergibt den lokalen Ordner als eigenes Argument;
Leerzeichen und nicht als UTF-8 lesbare POSIX-Namen bleiben erhalten.
Netzwerk-URIs wie `smb://` werden nicht als lokale Ordner behandelt.

Ohne übergebenen Ordner öffnet Quick zuerst die Bereichsauswahl. Die Liste
offener Nemo-Ansichten wird vom mitgelieferten Adapter über eine begrenzte,
nur lesbare D-Bus-Eigenschaft geliefert. Geschlossene Ansichten werden entfernt.
Damit erscheinen die Ordner auch bei Nemo-Versionen, deren allgemeine
`OpenLocations`-Eigenschaft leer bleibt. Ohne Adapter wird diese allgemeine
Eigenschaft abgefragt; ein fehlender Anbieter wird erklärt, ohne einen
Dateimanager zu starten.
Unter Dolphin bleibt dafür die explizite Bereichsauswahl verfügbar.

Quick sucht nach kurzer Eingabepause und zeigt höchstens 20 Treffer. „Alle in
Favenio“ öffnet dieselbe Frage mit den bereits aufgelösten Kalendergrenzen und
übernimmt die Auswahl, sobald die Treffer eintreffen. Die vollständige Suche wird
neu ausgeführt. Eine Aufzeichnung öffnet dagegen den gespeicherten Stand ohne
neue Suche.

## Vorschau und Plattformgrenzen

Die Leertaste öffnet eine integrierte Vorschau für Text, Bilder und PDF-Seiten.
Pfeiltasten wechseln die Datei; PDF-Seiten lassen sich getrennt durchblättern.
Archivmitglieder werden durch den gemeinsamen Materialisierer bereitgestellt.
DOCX, ODT, EPUB, XLSX und PPTX zeigen begrenzten logischen Dokumenttext aus den
bereits vorhandenen gemeinsamen Lesern. Originalformatierung, Audio, Video und
weitere Formate öffnet die Standardanwendung. Dies ersetzt die gebündelten
System- und Drittanbieter-Plugins von macOS Quick Look nicht vollständig.

PDF-Text kommt unter Linux aus Poppler, OCR aus Tesseract mit Deutsch und Englisch.
Die Mac-Ausgabe behält PDFKit und Vision. Textreihenfolge und Erkennung können
abweichen. Linux-Belege enthalten deshalb eigene Leserkennungen und einen
SHA-256-Fingerabdruck von Helfern, Komponenten und Sprachdaten. Nach einer Änderung
muss für neue Fundstellen erneut gesucht werden; gespeicherte Belege bleiben
lesbar. OCR beweist weiterhin keine Abwesenheit von Text. Mehrbilddateien werden
nicht still auf ihr erstes Bild reduziert. BigTIFF wird vom Linux-OCR-Adapter
abgewiesen.

Finder-Tags/-Kommentare und die garantierte Cloud-Nachladesperre haben unter Linux
keinen gleichwertigen allgemeinen Systemvertrag. Gespeicherte Daten bleiben
vorhanden, entsprechende Suchaufträge werden mit Erklärung gesperrt. Unbekannte
Werte erfüllen auch negierte Bedingungen nicht. Ein Linux-Suchstand mit nicht als
UTF-8 lesbaren äußeren Dateinamen wird vom aktuellen AppKit-Dateiadapter abgewiesen,
damit keine Dateiaktion auf einen Ersatzzeichenpfad gerät.

GTK verwendet die Schrift, Fensterdekoration und Dateidialoge des Linux-Desktops.
Die Bedienkonzepte und Suchregeln bleiben gemeinsam; AppKit-Controls werden nicht
pixelgenau nachgezeichnet.

## Updates und Rücknahme

Die Anwendung prüft höchstens täglich den GitHub-Releasekanal und meldet verfügbare
Updates. „Updates …“ startet die manuelle Prüfung; die Installation braucht eine
Bestätigung. Verifiziert wird mit demselben öffentlichen Ed25519-Herausgeberschlüssel
wie bei der Mac-Ausgabe, mit getrenntem Signaturkontext für Linux.
Der getrennte GitHub-Release `linux-stable` enthält `linux-update.json` und
`linux-update.json.sig`; Mac-Releases verschieben diesen Kanal nicht. Die
Manifestadresse verweist auf das versionsgebundene Paket im jeweiligen Release.
Der [Linux-Updatekanal](https://github.com/DanielMuellerIR/favenio/releases/tag/linux-stable)
liefert das aktuelle Manifest und seine Signatur. Die Linux-Releases ändern
weder den Mac-Appcast noch den als „Latest“ markierten Mac-Release.

Beide Apps nutzen denselben atomar gewechselten Versionsverweis. Laufende Prozesse
bleiben auf ihrer vollständig geladenen alten Version; anschließend beide Apps
schließen und neu starten. Gleichzeitige Installationen werden gesperrt. Starter und Dateimanager-Adapter
werden auch bei Updates, Rücknahmen und Wiederherstellungen aus der betreffenden
verifizierten Version erneuert. Beide Programme und der
Updatekoordinator halten eine gemeinsame Dateisperre, solange sie diese
Installation benutzen. Die Deinstallation verlangt diese Sperre exklusiv;
unbeteiligte Prozesse anderer Anwendungen werden nicht untersucht.
Ein abgebrochener Wechsel lässt sich mit dem Helfer der installierten Version
und `--recover` abschließen. `helpers/favenio-update --rollback` schaltet auf die
vorherige lokal verifizierte Version zurück. Die höchste verifizierte Version
bleibt als Untergrenze für Netzwerk-Updates erhalten.

Zum Vorbereiten eines Releases signiert `linux/sign-release.py` das Paket mit einem
lokalen Schlüssel aus einer geschützten Datei. Das Skript veröffentlicht nichts.
Ein Schlüsselwechsel wird nicht still akzeptiert.

`~/.local/share/favenio/bin/favenio-uninstall` entfernt die Installation und ihre
Dateimanager-Adapter nach Bestätigung. Laufende Apps und Updates müssen zuerst
geschlossen werden. Vorlagen und Einstellungen bleiben erhalten.

## Prüfung

`tests/linux_shared_probe.py` prüft die echte Swift-Sprachgrenze einschließlich
Suchprozessen, Byteidentitäten, Aufzeichnungen und Nachladen.
`tests/linux_gui_probe.py` prüft das laufende GTK-Fenster über dessen lokalen
Steuerungsvertrag. `tests/linux_nemo_probe.py` prüft den tatsächlichen GTK3-Knopf
in einer privaten Anzeige. `tests/linux_interaction_probe.py` prüft Tastatureingabe und Quick-Übergabe.
`tests/linux_preview_probe.py` prüft echte Bild-/PDF-/Office-Vorschauen.
`tests/linux_fastra_probe.py` prüft die Übernahme durch einen tatsächlich laufenden
Fastra-Empfänger in einer freigegebenen Desktop-Sitzung. `tests/linux_package_probe.py` installiert zwei echte Pakete in einer privaten
XDG-Umgebung und prüft Update, Rücknahme und Deinstallation mit einem nur für
diesen Test erzeugten Schlüssel. `tests/linux_document_probe.py` verifiziert echte PDF-
und OCR-Ergebnisse mit Poppler/Tesseract. `tests/test_linux_update.py` prüft
signierte Installation, Manipulation, Rücknahme, konkurrierende Installation,
Wiederherstellung und Deinstallation. Ein Containerlauf ersetzt keine Prüfung
auf dem tatsächlichen X11- beziehungsweise Wayland-Desktop.

Die Dateimanager-Anbindung folgt den öffentlichen
[KDE-Service-Menüs](https://develop.kde.org/docs/apps/dolphin/service-menus/)
und Nemos [OpenLocations-Implementierung](https://github.com/linuxmint/nemo/blob/master/src/nemo-freedesktop-dbus.c).
