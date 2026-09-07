#!/usr/bin/env python3
"""Leeren ISO-Ordner erzeugen und den bekannten Typfehler nachstellen.

Exit 0: Ordner korrekt erkannt. Exit 1: Typfehler reproduziert.
Exit 2: Aufbau oder Suchlauf gescheitert. Es wird nichts eingehängt.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def reproduce(root, source):
    fixture_source = root / "source"
    (fixture_source / "empty").mkdir(parents=True)
    image = root / "empty.iso"
    subprocess.run(
        ["/usr/bin/hdiutil", "makehybrid", "-iso", "-joliet", "-o",
         str(image), str(fixture_source), "-quiet"],
        check=True, capture_output=True, text=True, timeout=30)
    listing = subprocess.run(
        ["/usr/bin/tar", "-tf", str(image)], check=True,
        capture_output=True, text=True, timeout=30).stdout
    report = {"fixture": "empty.iso", "listing": listing}
    for kind in ("files", "dirs"):
        result = subprocess.run(
            [sys.executable, str(source), "--json", "--only", kind,
             "--exact", "empty", str(image)],
            capture_output=True, text=True, timeout=30)
        if result.returncode not in (0, 1):
            raise RuntimeError(result.stderr)
        report[kind] = {
            "exit": result.returncode,
            "hits": [json.loads(line) for line in
                     result.stdout.replace(str(root), "$FIXTURE").splitlines()],
            "stderr": result.stderr.replace(str(root), "$FIXTURE"),
        }
    files, dirs = report["files"], report["dirs"]
    for result in (files, dirs):
        if result['stderr'] or result['exit'] != (0 if result['hits'] else 1):
            raise RuntimeError('Unvollständiger oder widersprüchlicher Suchlauf')
        if any(not isinstance(hit, dict) or type(hit.get('isDirectory')) is not bool
               or hit.get('filesystemPath') != '$FIXTURE/empty.iso'
               or hit.get('archiveMembers') != ['empty']
               or hit.get('type') != 'member'
               for hit in result['hits']):
            raise ValueError('Ungültiger Treffertyp im JSONL-Strom')
    correct = (not files['hits'] and len(dirs['hits']) == 1
               and dirs['hits'][0]['isDirectory'] is True)
    reproduced = (not dirs['hits'] and len(files['hits']) == 1
                  and files['hits'][0]['isDirectory'] is False)
    if not correct and not reproduced:
        raise RuntimeError('Ausgabe entspricht weder korrektem Ordner noch bekanntem Typfehler')
    report["directory_type_correct"] = correct
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if correct else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=Path(__file__).resolve().parent.parent / "favenio.py")
    parser.add_argument("--output-dir", type=Path,
                        help="neues oder leeres Verzeichnis; sonst temporäre Fixture")
    options = parser.parse_args()
    if not shutil.which("hdiutil"):
        parser.error("Die Fixture benötigt macOS hdiutil.")
    if options.output_dir:
        root = options.output_dir.resolve()
        if root.exists() and (not root.is_dir() or any(root.iterdir())):
            parser.error("Das Ausgabeverzeichnis muss neu oder leer sein.")
        root.mkdir(parents=True, exist_ok=True)
        return reproduce(root, options.source.resolve())
    with tempfile.TemporaryDirectory(prefix="favenio-empty-iso-") as temporary:
        return reproduce(Path(temporary), options.source.resolve())


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("ISO-Repro fehlgeschlagen: " + str(error), file=sys.stderr)
        sys.exit(2)
