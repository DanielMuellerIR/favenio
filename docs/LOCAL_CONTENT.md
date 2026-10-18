# Lokal vorhandene Inhalte

`--local-only` und **Weitere Filter → Nur lokal vorhandene Inhalte lesen**
sind ausdrücklich wählbar und standardmäßig aus. Namen und bekannte Größen/
Zeitpunkte bleiben suchbar. Inhalt, Dokumenttext, Bildmaße, eingebettete
Medienmetadaten und Archivkataloge werden nur bei belegbar lokalem Inhalt gelesen.
Finder-Tags/-Kommentare bleiben eine getrennte Metadatenabfrage.

```sh
./favenio.py --local-only --content --json --search-report Rechnung ~/Documents
./favenio.py --local-only --document-text --json --search-report Rechnung ~/Documents
```

## Unterstützung und Grenzen

Die Option benötigt macOS 13 oder neuer und eine erfolgreich gesetzte und
bestätigte macOS-Materialisierungssperre. Ohne diese Fähigkeit endet der Auftrag
mit Exit 2 vor dem Zugriff auf Suchquellen. Auf macOS 12 überlässt die native
Bereichsprüfung dem Kern die Entscheidung; ein Vorschau-Nachladen mit aktiver
lokaler Politik führt dort auch keine native Quellenabfrage ohne Sperre aus. iCloud Drive auf APFS ist der
unterstützte Cloudanschluss; die eigene Systemgegenprobe erfolgte mit macOS
26.7.1. Auf früheren unterstützten Systemversionen wird dieselbe öffentliche
Betriebssystemfunktion verlangt; ein eigener iCloud-Systembeleg für jede
Zwischenversion liegt nicht vor.

Andere Provider unter `~/Library/CloudStorage` werden mangels eigenem
Providerbeleg als unbekannt ausgelassen. Die Grenze verwendet die Identität der
Providerwurzel und gilt auch über Links, Firmlinks und Schreibvarianten.
Netzwerkdateisysteme sowie Quellen ohne
belegbaren Dateisystem-/Flagzustand werden ebenfalls ausgelassen. Diese Option
ist keine allgemeine Offlinegarantie für beliebige Provider, Erweiterungen oder
parallel arbeitende Programme.

Apple beschreibt in [TN3150](https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files)
`SF_DATALESS` und `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`. Favenio setzt die
Sperre für den Python-Prozess, bevor er Aufträge oder Suchpfade liest. Neue
Helferprozesse erben sie. Damit bleibt auch der Zwischenraum zwischen einer
Statusprüfung und dem Öffnen geschützt; schon ein ausgelagerter Zwischenordner
kann einen Zugriff scheitern lassen. Das vorherige Prozessprofil wird nach dem
Auftrag wiederhergestellt. Die globale iCloud-/Providerkonfiguration wird nicht
verändert.

## Zustände und Abdeckung

- **Lokal:** regulärer Inhalt ohne `SF_DATALESS` auf einem lokalen Dateisystem,
  außerhalb eines nicht unterstützten Providerordners. Der Leser bleibt während
  des tatsächlichen Zugriffs unter der Betriebssystemsperre.
- **Noch nicht lokal lesbar:** `SF_DATALESS` beziehungsweise ein wegen
  Materialisierung abgewiesener Zugriff. Favenio wartet nicht und startet keinen
  Download. Ein späterer neuer Suchlauf prüft den Zustand erneut.
- **Unbekannt:** Statusabfrage fehlgeschlagen, nicht unterstützter Provider oder
  nicht belegbar lokales Dateisystem. Unbekannt erfüllt auch eine verneinte
  Inhalts-/Metadatenbedingung nicht. Ein unabhängiger bekannter ODER-Zweig kann
  weiterhin einen Treffer beweisen.

Der Suchbericht enthält die angefragte Option `configuration.local_only` und
begrenzt gezählte Gründe `localContentNotLocal` beziehungsweise
`localContentUnknown`. Die Apps zeigen diese Gründe im vorhandenen Suchbericht.
Ein Provider kann einen Download noch als aktiv melden, obwohl die vollständige
aktuelle Datei bereits lokal vorliegt. Favenio entscheidet anhand der
Dateiverfügbarkeit unter der Betriebssystemsperre; ein solches lokales Exemplar
darf gelesen werden. Der Aktivitätsstatus eines unabhängigen Downloads wird
nicht als Downloadauftrag behandelt.

Eine reine Namenssuche muss keinen nicht angefragten Inhaltszugriff als
Auslassung zählen. Ein nicht gelesener angefragter Archivkatalog schränkt dagegen
auch eine Namenssuche in Archiven ein. Zähler beschreiben Ereignisse, keine
vollständige Anzahl aller Dateien in einem ausgelassenen Teilbaum.

## Vorschau und Dateiaktionen

Erfasste Ausschnitte stammen weiterhin aus demselben Suchleser. **Weitere
Fundstelle** und **Kontext** übernehmen die lokale Politik, einschließlich einer
nötigen begrenzten Archivmaterialisierung. Automatische Prüfungen der
Quellengeneration sperren Materialisierung auch im Swift-Thread.

**Öffnen**, **Öffnen mit** und ausdrücklich ausgelöstes **Quick Look** bleiben
Nutzeraktionen und dürfen einen Cloudinhalt herunterladen. Die Suchoption ist
keine Sperre gegen das bewusst gewünschte Öffnen. Ein gleichzeitig ausdrücklich
angeforderter Download oder ein anderer Prozess kann den Zustand unabhängig von
Favenio ändern.

## Transport

Die gemeinsame Suchkonfiguration kodiert `local-only=1`; ohne aktivierte Option
bleiben bisherige Formate erhalten. Aktive lokale Politik benötigt
Vorlagenformat 6, Quick-Übergabeformat 6 mit `localContentCapability: 1`,
Controller-Konfiguration 5 und Aufzeichnung 6 mit derselben Capability.
Ältere Formate mit aktiver neuer Politik werden vor Übernahme abgewiesen;
bisherige Vorlagen und Aufzeichnungen bleiben lesbar. JSONL-Trefferidentitäten
und die üblichen Exit-Codes ändern sich nicht. Ein Trefferexport allein enthält
keine Suchkonfiguration; dafür den Suchbericht beziehungsweise eine Aufzeichnung
verwenden.
