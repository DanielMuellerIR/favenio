# Mehrere Suchbereiche

Beide Apps können Dateien und Ordner gemeinsam durchsuchen. **Ablage → Suchbereiche
bearbeiten…** (⇧⌘O) öffnet dieselbe native Liste ohne Finder-Abfrage.
Der Befehl ist auch in der Bereichsauswahl verfügbar. **Hinzufügen…** wählt mehrere
Dateien/Ordner, **Entfernen**, **Nach oben** und **Nach unten** ändern die Liste.
**Übernehmen** übernimmt die ganze Liste; **Abbrechen** erhält den alten Stand.
Eine leere Liste kann nicht übernommen werden. Fehlende Bereiche bleiben sichtbar.

Neue Listen haben höchstens 16 Einträge, je 4096 und insgesamt 65.536 UTF-8-Bytes.
Identische Rohpfade werden beim Hinzufügen einmal geführt; unterschiedliche
Unicode-Schreibweisen, Symlinks und überlappende Bereiche bleiben getrennt.
Alte Einzelwurzelkonfigurationen werden ohne neue Mengenbegrenzung gelesen.
Die Reihenfolge ist Teil des Auftrags und wird weder sortiert noch normalisiert.

Vor einem neuen Suchlauf werden alle Bereiche auf Vorhandensein geprüft.
Fehlt einer, scheitert der Gesamtstart mit seinem Pfad. Es gibt keine stille
Ersatzwurzel und keinen Teilstart. Historische Aufzeichnungen lassen sich auch
nach Trennen eines Volumes öffnen; erst eine neue Suche braucht die Quellen.
Bestehende Quellbindungsprüfungen einer ausgewählten Inhaltsvorschau bleiben
erhalten und behaupten für verschwundene Dateien keinen aktuellen Quellstand.

Der Python-Kern durchsucht Wurzeln der Reihe nach. Ausschlüsse, Ordnertiefe und
relative Dateipfadbedingungen gelten jeweils zur aktuellen Wurzel. Eine explizite
Startdatei wird mit ihrem Dateinamen geprüft, Archivmitglieder bleiben relativ
zum Archiv. Archive teilen sich die bisherigen Laufbudgets. Ein überlappender
Pfad wird erneut ausgewertet: Erst die zweite Wurzel kann seine relative
Pfadbedingung erfüllen. Beide Apps entfernen erfolgreiche doppelte HitIdentity
vor Filter, Statistik und Quicks 20er-Grenze. Der erste erfolgreiche Treffer
behält seine Belege und Herkunft. Das bisherige CLI-Duplikatverhalten bleibt.

JSONL ergänzt `searchRoot` als absolute Herkunft des Treffers. Bereits absolute
Startpfade behalten ihre deklarierte Schreibweise einschließlich `/.` oder
abschließendem `/`; relative CLI-Startpfade erhalten nur für dieses Zusatzfeld
eine absolute Herkunft. HitIdentity bleibt unverändert. Ansichtsfilter verwenden
die übergebene Herkunft rein lexikalisch und öffnen keine Quelle. Für alte Hits
ohne Herkunft ist nur eine bekannte einzelne Wurzel ein gültiger Rückfall.

Die Pfadspalte verwendet die jeweilige Trefferwurzel. Ordnergruppen mit neuen
Herkunftsbelegen zeigen den physischen Elternpfad eindeutig; rohe Archivstufen
bleiben getrennt. Vollständige Originalpfade stehen weiterhin im Tooltip.

## Versionierte Transporte

- Controller: Die alte Form `{pattern, root, options}` bleibt lesbar. Die neue
  Form ist `{schemaVersion:2, pattern, roots:[...], options}`. Unbekannte Versionen,
  gleichzeitiges `root`/`roots` und ungültige Listen werden vor Teilmutation
  abgewiesen. `configure` ändert keine laufende Suche; `status.configuration`
  beschreibt weiterhin deren eingefrorene Liste. Capabilities nennen beide
  Konfigurationsversionen und Listenlimits.
- Vorlagen: Format 3 speichert `roots` als geordnete Liste oder `null` für einen
  nicht gespeicherten Bereich. Formate 1/2 lesen einzelne `root` verlustfrei.
  Fehlende gespeicherte Bereiche ersetzen die sichtbare Liste und bleiben
  erklärt; ein Start wird blockiert. `null` behält die aktuelle Auswahl.
- Aufzeichnungen: Format 3 trägt mehrere Wurzeln und passende Herkunft je Hit.
  Formate 1/2 bleiben Einzelwurzelformate. Ein Mehrwurzelhit ohne bekannte Herkunft
  macht die gesamte Aufnahme ungültig. Der äußere Dateiwrapper von
  `tools/search-recording.py` bleibt Format 1; sein Konfigurationsvergleich
  migriert alte `root` nur nach `[root]`, ohne Reihenfolge/Schreibweise zu ändern.
- Quick: Übergabeformat 3 enthält die Liste im JSONL-Kopf, URL-Host `results-v3`.
  Es gibt keine erste Ersatzwurzel in der URL. Alte Übergaben 1/2 bleiben lesbar;
  eine ältere Haupt-App wird für mehrere Bereiche mit Updatehinweis abgewiesen.
  Bisherige Datei-, Zeilen-, Auswahl- und URL-Limits gelten zusätzlich.

Quick schützt bewusst gewählte Bereiche vor späteren Finderantworten. Während
des Tippens beschreibt die Übergabe die sichtbare Auswahl; vorhandene Treffer
gehören zur eingefrorenen Liste des laufenden beziehungsweise letzten Suchlaufs.

Kalenderfragen verwenden die kompatiblen Folgeformate Vorlage4, Controller3,
Aufzeichnung4 und Quick4. Die geordnete Wurzelliste und rohe Herkunft bleiben
dabei erhalten; alle Wurzeln teilen denselben Datumsbezug und dieselben konkreten
Grenzen. Siehe [Kalenderbereiche](DATE_RANGES.md).
