#!/usr/bin/env python3
"""Favenio — „facile invenio", ich finde mit Leichtigkeit.

Dateisuche im Stil von EasyFind (Suche ohne Index, direkt im Dateisystem),
mit einer zusätzlichen Fähigkeit: Favenio schaut auch IN Archive hinein
(Zip- und Tar-Familien, auf Wunsch auch Archive in Archiven).

Grundprinzipien:
- Standardmäßig wird nach DATEINAMEN gesucht (Ordner zählen mit).
- Mit --content wird stattdessen im DATEIINHALT gesucht.
- Ohne Platzhalter (* ? [) gilt „Name enthält den Suchtext";
  mit Platzhaltern gilt Glob-Matching auf den ganzen Namen.
- Groß-/Kleinschreibung ist standardmäßig egal (--case-sensitive schaltet um).
- Treffer in Archiven werden als  archiv.zip!/pfad/im/archiv  ausgegeben.

Für AI-Agenten/Skripte: --json liefert einen Treffer pro Zeile als
JSON-Objekt (JSONL); Exit-Code 0 = Treffer, 1 = kein Treffer, 2 = Fehler.
Nur Python-Standardbibliothek, keine Abhängigkeiten.
"""

import argparse
import fnmatch
import io
import json
import os
import re
import sys
import tarfile
import zipfile

__version__ = "0.1.0"

# Dateiendungen, die wir als Zip-Container behandeln.
# (Viele Formate sind „Zip in Verkleidung": Java-Archive, Python-Wheels,
#  E-Books und die Office-Formate von Microsoft/LibreOffice.)
ZIP_EXTENSIONS = (
    ".zip", ".jar", ".whl", ".epub",
    ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp",
)

# Dateiendungen der Tar-Familie (unkomprimiert und komprimiert).
TAR_EXTENSIONS = (
    ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
)


def classify_archive(name):
    """Liefert "zip", "tar" oder None — je nachdem, ob der Dateiname
    wie ein unterstütztes Archiv aussieht (nur anhand der Endung,
    damit wir nicht jede Datei öffnen müssen)."""
    lowered = name.lower()
    if lowered.endswith(ZIP_EXTENSIONS):
        return "zip"
    if lowered.endswith(TAR_EXTENSIONS):
        return "tar"
    return None


def build_matcher(pattern, use_regex, case_sensitive):
    """Baut aus dem Suchmuster eine Funktion  text -> True/False .

    Drei Fälle:
    1. --regex:            Muster ist ein regulärer Ausdruck (re.search).
    2. Muster mit * ? [ :  Glob-Matching auf den GANZEN Namen (wie die Shell).
    3. sonst:              einfacher „enthält"-Test (wie EasyFind-Default).
    """
    flags = 0 if case_sensitive else re.IGNORECASE

    if use_regex:
        # Ungültige Regexes fängt main() ab und meldet sie als Fehler.
        compiled = re.compile(pattern, flags)
        return lambda text: compiled.search(text) is not None

    if any(char in pattern for char in "*?["):
        # fnmatch.translate macht aus dem Glob-Muster einen Regex,
        # der den kompletten String matchen muss.
        compiled = re.compile(fnmatch.translate(pattern), flags)
        return lambda text: compiled.match(text) is not None

    if case_sensitive:
        return lambda text: pattern in text
    lowered_pattern = pattern.lower()
    return lambda text: lowered_pattern in text.lower()


class Search:
    """Kapselt eine Suche: Muster, Optionen und das Einsammeln der Treffer.

    Die Klasse hält bewusst wenig Zustand: matcher (die Testfunktion),
    die Optionen und zwei Zähler (Treffer gefunden? Fehler passiert?).
    """

    def __init__(self, matcher, content_mode, archive_depth, as_json):
        self.matcher = matcher                # Funktion text -> bool
        self.content_mode = content_mode      # True = Inhalt, False = Namen
        self.archive_depth = archive_depth    # 0 = Archive ignorieren,
                                              # 1 = in Archive schauen,
                                              # 2 = auch Archive IN Archiven …
        self.as_json = as_json                # Ausgabeformat JSONL statt Text
        self.found_any = False                # für den Exit-Code (0 vs. 1)
        self.had_errors = False               # Warnungen gab es (stderr)

    # ---------- Ausgabe ----------

    def emit(self, path, kind, line=None):
        """Gibt EINEN Treffer aus. kind ist "file", "dir" oder "member"
        (member = Eintrag innerhalb eines Archivs). line ist bei
        Inhaltssuche die Zeilennummer des ersten Treffers."""
        self.found_any = True
        if self.as_json:
            record = {"path": path, "type": kind}
            if line is not None:
                record["line"] = line
            print(json.dumps(record, ensure_ascii=False))
        else:
            suffix = ":%d" % line if line is not None else ""
            print(path + suffix)

    def warn(self, message):
        """Nicht-fatale Probleme (z. B. kaputtes Archiv, keine Leserechte)
        landen auf stderr, die Suche läuft weiter."""
        self.had_errors = True
        print("favenio: warnung: %s" % message, file=sys.stderr)

    # ---------- Inhalts-Matching ----------

    def match_content(self, data):
        """Sucht das Muster im Datei-Inhalt (Bytes). Liefert die
        Zeilennummer des ersten Treffers oder None.

        Wir dekodieren als UTF-8 und ersetzen undekodierbare Bytes —
        so funktioniert die Suche auch in „halb-binären" Dateien,
        ohne dass das Programm abbricht."""
        text = data.decode("utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), start=1):
            if self.matcher(line):
                return number
        return None

    # ---------- Dateisystem ----------

    def search_path(self, root):
        """Durchsucht einen Startpfad rekursiv (Datei ODER Ordner)."""
        if os.path.isfile(root):
            self.visit_file(root)
            return
        # followlinks=False: Symlink-Schleifen vermeiden.
        for dirpath, dirnames, filenames in os.walk(
            root, onerror=lambda err: self.warn(str(err)), followlinks=False
        ):
            if not self.content_mode:
                # Bei Namenssuche zählen auch Ordnernamen als Treffer.
                for dirname in dirnames:
                    if self.matcher(dirname):
                        self.emit(os.path.join(dirpath, dirname), "dir")
            for filename in filenames:
                self.visit_file(os.path.join(dirpath, filename))

    def visit_file(self, path):
        """Behandelt EINE Datei im Dateisystem: Namens- oder Inhaltstest,
        und — falls es ein Archiv ist — der Blick hinein."""
        name = os.path.basename(path)

        if not self.content_mode and self.matcher(name):
            self.emit(path, "file")

        archive_kind = classify_archive(name)
        if archive_kind and self.archive_depth >= 1:
            self.search_archive(path, None, archive_kind, path,
                                self.archive_depth)
        elif self.content_mode and not archive_kind:
            # Normale Datei bei Inhaltssuche: einlesen und testen.
            try:
                with open(path, "rb") as handle:
                    data = handle.read()
            except OSError as err:
                self.warn(str(err))
                return
            line = self.match_content(data)
            if line is not None:
                self.emit(path, "file", line)

    # ---------- Archive ----------

    def search_archive(self, fs_path, fileobj, kind, display, depth):
        """Durchsucht ein Archiv. Entweder liegt es als Datei auf der
        Platte (fs_path) oder als Bytes im Speicher (fileobj — das ist
        der Fall bei Archiven INNERHALB von Archiven).

        display ist der Anzeige-Pfad, z. B. "ordner/paket.zip" oder
        verschachtelt "aussen.zip!/innen.zip". depth zählt runter:
        bei 0 steigen wir nicht weiter in Unter-Archive ein."""
        try:
            if kind == "zip":
                source = fileobj if fileobj is not None else fs_path
                with zipfile.ZipFile(source) as archive:
                    self.walk_zip(archive, display, depth)
            else:  # "tar" — tarfile erkennt die Kompression selbst ("r:*")
                if fileobj is not None:
                    archive = tarfile.open(fileobj=fileobj, mode="r:*")
                else:
                    archive = tarfile.open(fs_path, mode="r:*")
                with archive:
                    self.walk_tar(archive, display, depth)
        except (OSError, zipfile.BadZipFile, tarfile.TarError) as err:
            self.warn("%s: %s" % (display, err))

    def visit_member(self, member_path, is_dir, read_bytes, display, depth):
        """Gemeinsame Logik für EINEN Archiv-Eintrag (Zip wie Tar).

        member_path: Pfad innerhalb des Archivs.
        read_bytes:  Funktion, die den Inhalt liefert (lazy — wird nur
                     aufgerufen, wenn wir den Inhalt wirklich brauchen).
        """
        full_display = display + "!/" + member_path
        name = os.path.basename(member_path.rstrip("/"))

        if not self.content_mode and self.matcher(name):
            self.emit(full_display, "member")

        if is_dir:
            return

        nested_kind = classify_archive(name)
        if nested_kind and depth - 1 >= 1:
            # Archiv im Archiv: Inhalt in den Speicher holen und rekursiv
            # weitersuchen (depth sinkt um 1).
            try:
                data = read_bytes()
            except (OSError, zipfile.BadZipFile, tarfile.TarError) as err:
                self.warn("%s: %s" % (full_display, err))
                return
            self.search_archive(None, io.BytesIO(data), nested_kind,
                                full_display, depth - 1)
        elif self.content_mode and not nested_kind:
            try:
                data = read_bytes()
            except (OSError, zipfile.BadZipFile, tarfile.TarError) as err:
                self.warn("%s: %s" % (full_display, err))
                return
            line = self.match_content(data)
            if line is not None:
                self.emit(full_display, "member", line)

    def walk_zip(self, archive, display, depth):
        """Geht alle Einträge eines Zip-Archivs durch."""
        for info in archive.infolist():
            self.visit_member(
                info.filename.rstrip("/"),
                info.is_dir(),
                lambda info=info: archive.read(info),
                display,
                depth,
            )

    def walk_tar(self, archive, display, depth):
        """Geht alle Einträge eines Tar-Archivs durch."""
        for member in archive.getmembers():
            def read_bytes(member=member):
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise tarfile.TarError("Eintrag nicht lesbar")
                with extracted:
                    return extracted.read()
            self.visit_member(member.name, member.isdir(), read_bytes,
                              display, depth)


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="favenio",
        description="Favenio — facile invenio. Dateisuche ohne Index, "
                    "auch in Archiven (zip/jar/docx/…, tar/tar.gz/…).",
        epilog="Exit-Codes: 0 = Treffer gefunden, 1 = keine Treffer, "
               "2 = Fehler. Ausgabeformat für Skripte/Agenten: --json.",
    )
    parser.add_argument("pattern",
                        help="Suchmuster: „enthält“-Text, Glob (* ? [) "
                             "oder mit --regex ein regulärer Ausdruck")
    parser.add_argument("paths", nargs="*", default=["."],
                        help="Startpfade (Default: aktueller Ordner)")
    parser.add_argument("-c", "--content", action="store_true",
                        help="im Dateiinhalt suchen statt in Dateinamen")
    parser.add_argument("-r", "--regex", action="store_true",
                        help="Muster als regulären Ausdruck interpretieren")
    parser.add_argument("-s", "--case-sensitive", action="store_true",
                        help="Groß-/Kleinschreibung beachten")
    parser.add_argument("--no-archives", action="store_true",
                        help="nicht in Archive hineinschauen")
    parser.add_argument("--archive-depth", type=int, default=1,
                        metavar="N",
                        help="wie tief in verschachtelte Archive schauen "
                             "(1 = Archive, 2 = Archive in Archiven, …; "
                             "Default: 1)")
    parser.add_argument("--json", action="store_true",
                        help="Treffer als JSON-Zeilen ausgeben (JSONL)")
    parser.add_argument("--version", action="version",
                        version="favenio " + __version__)
    args = parser.parse_args(argv)

    # argparse setzt den Default für nargs="*" nur, wenn GAR NICHTS kommt —
    # deshalb hier noch einmal absichern.
    paths = args.paths if args.paths else ["."]

    try:
        matcher = build_matcher(args.pattern, args.regex, args.case_sensitive)
    except re.error as err:
        print("favenio: fehler: ungültiger regulärer Ausdruck: %s" % err,
              file=sys.stderr)
        return 2

    archive_depth = 0 if args.no_archives else args.archive_depth
    search = Search(matcher, args.content, archive_depth, args.json)

    for path in paths:
        if not os.path.exists(path):
            print("favenio: fehler: Pfad existiert nicht: %s" % path,
                  file=sys.stderr)
            return 2
        search.search_path(path)

    return 0 if search.found_any else 1


if __name__ == "__main__":
    sys.exit(main())
