# AGENTS.md — Favenio

Stand: 2026-07-11

## Was ist das?

Favenio („facile invenio" — ich finde mit Leichtigkeit) ist ein
EasyFind-Nachbau als CLI: indexlose Dateisuche nach Namen oder Inhalt,
mit der Zusatzfähigkeit, **in Archive hineinzusuchen** (Zip- und
Tar-Familie, verschachtelt via `--archive-depth`).

## Tech-Stack / Architektur

- Python 3, **nur Standardbibliothek** (argparse, fnmatch, zipfile,
  tarfile, io, json, re, os) — keine Dependencies, keine Installation.
- Eine Quelldatei: `favenio.py`. Version als `__version__`-Konstante dort.
- Kernklasse `Search` kapselt Muster + Optionen + Trefferausgabe;
  `visit_member()` ist die gemeinsame Logik für Zip- und Tar-Einträge.
- Archiv-Erkennung rein über Dateiendung (schnell, kein Öffnen nötig);
  Zip-in-Verkleidung-Formate (jar, whl, epub, docx, xlsx, pptx, odt,
  ods, odp) werden mitbehandelt.
- Verschachtelte Archive werden in den Speicher (`io.BytesIO`) geladen
  und rekursiv durchsucht; `--archive-depth` begrenzt die Tiefe
  (Default 1 = in Archive schauen, aber nicht in Archive in Archiven).

## Headless-/Agent-Schnittstelle (Design-Entscheidung)

- `--json` → JSONL, ein Objekt pro Treffer: `path`, `type`
  (`file`/`dir`/`member`), bei Inhaltssuche `line`.
- Exit-Codes wie grep: 0 Treffer / 1 keine / 2 Fehler.
- Warnungen nach stderr, stdout bleibt parsebar.

## Tests / Verifikation

```bash
python3 -m unittest discover -s tests
```

14 Tests in `tests/test_favenio.py`; sie bauen sich ihre Fixtures
(Dateien, zip, tar.gz, Zip-im-Zip) selbst in einem Temp-Ordner.

## Status / offene Ideen

- v0.1.0: Namens-/Inhaltssuche, Zip+Tar, Verschachtelung, JSONL — fertig, Tests grün.
- Ideen (nicht begonnen): 7z/rar via externe Tools, Größen-/Datumsfilter,
  Mehrwort-Suche („alle Wörter" wie EasyFind), GUI-Frontend.

## Fallen / Agent-Hinweise

- Inhaltssuche dekodiert als UTF-8 mit `errors="replace"` — findet
  Text auch in „halb-binären" Dateien, aber keine anderen Encodings
  (Latin-1-Umlaute matchen nicht).
- Glob-Muster matchen den GANZEN Namen (fnmatch), Substring-Suche nur
  ohne Platzhalter — Verhalten ist in `build_matcher()` dokumentiert.
