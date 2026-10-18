# Miniaturansicht

Beide Apps zeigen dieselbe Trefferliste wahlweise als Tabelle oder Raster. Die
Haupt-App verwendet 160 × 180 Punkte große Kacheln, Quick 144 × 180 Punkte. Jede
Kachel nennt Dateiname, bekannte Größe, Typ und gegebenenfalls einen Grund für
die fehlende Miniatur. Vollständige Pfade stehen im Tooltip. Die Ansichtswahl
wird pro App lokal gespeichert; sie verändert weder Suchauftrag noch Export.

Die Tabelle bleibt das gemeinsame Auswahl- und Aktionsmodell. Das Raster bildet
nur deren Trefferidentitäten und Gruppen ab. Umschalten und Sortieren erhalten
die Auswahl; eingeklappte Gruppen liefern keine ausgewählten Dateien.
QuickLook, Öffnen, Kontextmenü und Drag-and-drop verwenden die bestehenden
Dateiaktionen. Archivdateien werden über den gemeinsamen Materialisierungsmanager
angefordert; ein ausdrücklicher Dateiabruf behält dieselbe Datei bis zum App-Ende.
Eine ausschließlich für die Miniatur angelegte Kopie wird nach dem Decodieren
freigegeben. Mehrere gleichzeitige Abrufe teilen den bestehenden Auftrag.

## Lokale Quellen und Grenzen

Miniaturen lesen immer ausschließlich lokal vorhandene Inhalte, auch wenn die
Suche Downloads zulässt. Der Python-Kern prüft die lokale Inhaltsfreigabe der
äußeren Quelle; Swift übernimmt keine Providerklassifikation. Unter macOS 13+
schützt die Materialisierungssperre den lesenden Swift-Thread; im Python-Kern
gilt sie für den Prozess und dessen Helfer. Nicht lokale,
unbekannte, geänderte oder unlesbare Quellen erhalten Platzhalter. Ausdrücklich
gewünschtes Öffnen folgt weiterhin seinem eigenen Aktionsvertrag. Einzelheiten
zur unterstützten iCloud-Politik: [Lokale Inhalte](LOCAL_CONTENT.md).

- PNG, JPEG, TIFF, GIF, BMP, HEIC/HEIF und WebP; bei mehreren Frames nur der erste.
  Höchstens 1024 Frames, 32 Millionen Pixel, 16384 Pixel je Kante und 1–16 Bit.
- Höchstens 64 MiB Bildbytes; äußere Archive höchstens 256 MiB. Archivabrufe:
  die bestehenden Materialisierungsgrenzen (standardmäßig 256 MiB je Mitglied,
  1 GiB Gesamtbudget und Verhältnis 1000), zusätzlich zu strengeren hinterlegten
  Beleggrenzen. Ein gleichzeitiger ausdrücklicher Dateiabruf erhält dieselben
  Grenzen. Unbekannte Mitgliedsgrößen können deshalb beim Auspacken mehr als
  64 MiB erzeugen; der Miniaturleser lehnt sie danach ab, ohne Bildbytes zu lesen.
- Lokale Freigabeprüfung höchstens zwei Sekunden; Archivabruf höchstens fünf
  Sekunden; eigener Byte-Leseloop höchstens zwei Sekunden. ImageIO arbeitet auf
  begrenzten Daten statt auf einer Quell-URL. Framework-Decodierung hat keine
  zugesicherte harte Laufzeit- oder Prozessspeichergrenze.
- Zwei Hintergrundarbeiter, höchstens 16 ausstehende sichtbare Anforderungen;
  kein Prefetch unsichtbarer Kacheln. Neue Suche, Ansichtswechsel und Wegscrollen
  brechen nicht mehr benötigte eigene Aufträge ab.
- Miniaturen bis 256 Pixel; LRU-Cache höchstens 64 Einträge und 16 MiB tatsächliche
  Pixelbytes. Schlüssel: bytegetreue Trefferidentität und Quellengeneration.
  Neue Anforderungen prüfen die Generation; sichtbare Bilder werden nicht
  fortlaufend auf externe Änderungen überwacht.

Ordner und andere Formate bleiben als Dateikacheln ohne Bildminiatur nutzbar.
Eine fehlende Miniatur ist kein Suchfehler und kein Beweis für fehlenden Inhalt.
