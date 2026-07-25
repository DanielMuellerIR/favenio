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
import codecs
import fnmatch
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
import zipfile

__version__ = "0.17.0"
# Datum dieser Version (ISO 8601). Zweite Single-Source neben __version__;
# das Build-Skript gießt beides in eine Swift-Konstante für die Fenstertitel.
__date__ = "2026-07-25"

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

# Häppchengrösse für die Inhaltssuche. Dateien werden nicht am Stück
# eingelesen, sondern in Portionen dieser Grösse — das hält den Speicher
# klein und erlaubt den Abbruch beim ersten Treffer.
CHUNK_SIZE = 64 * 1024
DEFAULT_MAX_ARCHIVE_MEMBER_BYTES = 256 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_TOTAL_BYTES = 1024 * 1024 * 1024
DEFAULT_MAX_ARCHIVE_RATIO = 1000.0

# Alle Zeichen, an denen str.splitlines() eine Zeile umbricht (nicht nur \n:
# auch \r, Seitenvorschub und die Unicode-Trenner). Wir brauchen die Liste,
# um zu erkennen, ob ein Häppchen mit einer vollständigen Zeile endet.
LINE_BREAKS = "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029"


class ArchiveReadError(Exception):
    """Kontrollierter Lesefehler eines einzelnen Archiveintrags."""


class ArchiveLimitError(ArchiveReadError):
    """Ein Archivmitglied überschreitet eine konfigurierte Sicherheitsgrenze."""


class ArchiveBudget:
    """Begrenzt entpackte Einzel- und Gesamtbytes eines Suchlaufs."""

    def __init__(self, maximum_member, maximum_total, maximum_ratio):
        self.maximum_member = maximum_member
        self.maximum_total = maximum_total
        self.maximum_ratio = maximum_ratio
        self.consumed = 0

    def validate(self, label, declared_size=None, compressed_size=None):
        if declared_size is not None and declared_size > self.maximum_member:
            raise ArchiveLimitError(
                "%s: entpackte Größe %d überschreitet Einzelgrenze %d"
                % (label, declared_size, self.maximum_member))
        if declared_size and compressed_size is not None:
            ratio = declared_size / max(1, compressed_size)
            if ratio > self.maximum_ratio:
                raise ArchiveLimitError(
                    "%s: Kompressionsverhältnis %.1f überschreitet Grenze %.1f"
                    % (label, ratio, self.maximum_ratio))

    def iter_chunks(self, handle, label, declared_size=None,
                    compressed_size=None):
        self.validate(label, declared_size, compressed_size)
        member_bytes = 0
        while True:
            chunk = handle.read(CHUNK_SIZE)
            if not chunk:
                return
            member_bytes += len(chunk)
            self.consumed += len(chunk)
            if member_bytes > self.maximum_member:
                raise ArchiveLimitError(
                    "%s: Einzelgrenze %d überschritten"
                    % (label, self.maximum_member))
            if self.consumed > self.maximum_total:
                raise ArchiveLimitError(
                    "%s: Gesamtbudget %d überschritten"
                    % (label, self.maximum_total))
            yield chunk

    def read_all(self, handle, label, declared_size=None,
                 compressed_size=None):
        return b"".join(self.iter_chunks(
            handle, label, declared_size, compressed_size))


EXPECTED_ARCHIVE_ERRORS = (
    ArchiveReadError,
    OSError,
    RuntimeError,          # z. B. verschlüsseltes ZIP-Mitglied
    NotImplementedError,   # nicht unterstützte ZIP-Kompression
    KeyError,
    zipfile.BadZipFile,
    zipfile.LargeZipFile,
    tarfile.TarError,
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


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("muss größer als 0 sein")
    return parsed


def positive_float(value):
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("muss größer als 0 sein")
    return parsed


class Search:
    """Kapselt eine Suche: Muster, Optionen und das Einsammeln der Treffer.

    Die Klasse hält bewusst wenig Zustand: matcher (die Testfunktion),
    die Optionen und den Trefferzustand für den Exit-Code.
    """

    def __init__(self, matcher, content_mode, archive_depth, as_json,
                 progress=False, only="both", include_hidden=False,
                 max_archive_member_bytes=DEFAULT_MAX_ARCHIVE_MEMBER_BYTES,
                 max_archive_total_bytes=DEFAULT_MAX_ARCHIVE_TOTAL_BYTES,
                 max_archive_ratio=DEFAULT_MAX_ARCHIVE_RATIO):
        self.matcher = matcher                # Funktion text -> bool
        self.content_mode = content_mode      # True = Inhalt, False = Namen
        self.archive_depth = archive_depth    # 0 = Archive ignorieren,
                                              # 1 = in Archive schauen,
                                              # 2 = auch Archive IN Archiven …
        self.only = only                      # "both"/"files"/"dirs" —
                                              # Treffer auf einen Typ begrenzen
        self.include_hidden = include_hidden  # unsichtbare (Punkt-)Dateien
                                              # und -Ordner mitdurchsuchen?
        self.as_json = as_json                # Ausgabeformat JSONL statt Text
        self.progress = progress              # laufend melden, wo wir suchen
        self.found_any = False                # für den Exit-Code (0 vs. 1)
        self.archive_budget = ArchiveBudget(
            max_archive_member_bytes,
            max_archive_total_bytes,
            max_archive_ratio,
        )
        self._last_progress = None            # Zeitstempel fürs Drosseln
                                              # (None = noch nie gemeldet;
                                              # nicht 0.0 — time.monotonic()
                                              # startet je nach Python nahe 0)

    # ---------- Ausgabe ----------

    def type_allowed(self, is_directory):
        """Filtert Treffer nach Typ (Drei-Wege-Umschalter der GUI):
        "files" nur Dateien, "dirs" nur Ordner, "both" (Default) beides."""
        if self.only == "files":
            return not is_directory
        if self.only == "dirs":
            return is_directory
        return True

    @staticmethod
    def is_hidden(name):
        """Unsichtbar = Name beginnt mit einem Punkt (.DS_Store, .git, …) —
        die auf macOS/Unix übliche Konvention, deckt den Finder-Fall ab."""
        return name.startswith(".")

    def emit(self, path, kind, line=None, size=None, filesystem_path=None,
             archive_members=None):
        """Gibt EINEN Treffer aus. kind ist "file", "dir" oder "member"
        (member = Eintrag innerhalb eines Archivs). line ist bei
        Inhaltssuche die Zeilennummer des ersten Treffers, size die
        Dateigröße in Bytes (bei Ordnern None)."""
        self.found_any = True
        if self.as_json:
            record = {"path": path, "type": kind}
            record["filesystemPath"] = (filesystem_path
                                        if filesystem_path is not None
                                        else path)
            record["archiveMembers"] = list(archive_members or ())
            if line is not None:
                record["line"] = line
            if size is not None:
                record["size"] = size
            text = json.dumps(record, ensure_ascii=False)
        else:
            text = path + (":%d" % line if line is not None else "")
        print(text)

    def warn(self, message):
        """Nicht-fatale Probleme (z. B. kaputtes Archiv, keine Leserechte)
        landen auf stderr, die Suche läuft weiter."""
        print("favenio: warnung: %s" % message, file=sys.stderr)

    def report_progress(self, path):
        """Meldet (mit --progress) laufend, welcher Ordner bzw. welches
        Archiv gerade durchsucht wird — damit GUIs zeigen können, dass
        die Suche noch lebt.

        Gedrosselt auf höchstens ~10 Meldungen pro Sekunde, damit die
        Ausgabe die Suche nicht ausbremst; die erste Meldung kommt immer.
        Mit --json als eigenes JSONL-Objekt ({"type": "progress"}) auf
        stdout — Konsumenten unterscheiden Treffer und Fortschritt am
        type-Feld. Ohne --json auf stderr, damit stdout eine reine
        Trefferliste bleibt."""
        if not self.progress:
            return
        now = time.monotonic()
        if self._last_progress is not None and now - self._last_progress < 0.1:
            return
        self._last_progress = now
        if self.as_json:
            print(json.dumps({"type": "progress", "path": path},
                             ensure_ascii=False), flush=True)
        else:
            print("… durchsuche: %s" % path, file=sys.stderr)

    # ---------- Inhalts-Matching ----------

    def match_content(self, chunks):
        """Sucht das Muster im Datei-Inhalt. Liefert die Zeilennummer des
        ersten Treffers oder None.

        chunks ist eine Folge von Byte-Häppchen: bei Dateien liest der
        Aufrufer sie portionsweise von der Platte, bei Archiv-Einträgen ist
        es genau ein Häppchen. Beim ersten Treffer steigen wir sofort aus —
        der Rest der Datei wird dann gar nicht mehr gelesen.

        Dekodiert wird als UTF-8 mit errors="replace", damit die Suche auch
        in „halb-binären" Dateien funktioniert, ohne dass das Programm
        abbricht. Der inkrementelle Decoder setzt Mehrbyte-Zeichen über
        Häppchengrenzen hinweg korrekt zusammen; das Ergebnis ist deshalb
        identisch zum Dekodieren der ganzen Datei am Stück."""
        pending = []          # Bruchstücke der noch nicht beendeten Zeile
        number = 0
        for text in codecs.iterdecode(chunks, "utf-8", errors="replace"):
            if not text:
                continue
            pending.append(text)
            # Steckt in diesem Häppchen überhaupt ein Umbruch? Wenn nicht,
            # gibt es keine fertige Zeile und wir puffern nur weiter — würden
            # wir den wachsenden Puffer bei jedem Häppchen neu zusammensetzen,
            # bekämen Dateien ohne Zeilenumbrüche quadratischen Aufwand.
            # Der \n-Test ist der billige Normalfall; erst wenn er scheitert,
            # kosten die selteneren Umbruchzeichen einen splitlines()-Lauf.
            if "\n" not in text and len(text.splitlines()) == 1 \
                    and text[-1] not in LINE_BREAKS:
                continue
            buffer = "".join(pending)
            pending.clear()
            lines = buffer.splitlines()
            if buffer[-1] not in LINE_BREAKS:
                # Die letzte Zeile ist noch offen; sie wird im nächsten
                # Häppchen fortgesetzt.
                pending.append(lines.pop())
            elif buffer.endswith("\r"):
                # Umbruch noch offen: folgt im nächsten Häppchen ein \n,
                # sind beide zusammen EIN Umbruch (CRLF) — sonst zählten
                # wir hier eine Zeile zu viel.
                pending.append(lines.pop() + "\r")
            for line in lines:
                number += 1
                if self.matcher(line):
                    return number
        # Rest: die letzte noch offene Zeile prüfen. Den Decoder leert
        # iterdecode() selbst — ein angebrochenes Mehrbyte-Zeichen am
        # Dateiende steht dann schon als Ersatzzeichen im Puffer.
        for line in "".join(pending).splitlines():
            number += 1
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
            self.report_progress(dirpath)
            if not self.include_hidden:
                # Unsichtbare Ordner gar nicht erst betreten (spart auch das
                # Durchsuchen von .git & Co.) und unsichtbare Dateien
                # überspringen. dirnames IN PLACE ändern, damit os.walk folgt.
                dirnames[:] = [d for d in dirnames if not self.is_hidden(d)]
                filenames = [f for f in filenames if not self.is_hidden(f)]
            if not self.content_mode:
                # Bei Namenssuche zählen auch Ordnernamen als Treffer.
                for dirname in dirnames:
                    if self.matcher(dirname) and self.type_allowed(True):
                        self.emit(os.path.join(dirpath, dirname), "dir")
            for filename in filenames:
                self.visit_file(os.path.join(dirpath, filename))

    @staticmethod
    def file_size(path):
        """Dateigröße in Bytes oder None, falls nicht ermittelbar."""
        try:
            return os.path.getsize(path)
        except OSError:
            return None

    def visit_file(self, path):
        """Behandelt EINE Datei im Dateisystem: Namens- oder Inhaltstest,
        und — falls es ein Archiv ist — der Blick hinein."""
        name = os.path.basename(path)

        if not self.content_mode and self.matcher(name) \
                and self.type_allowed(False):
            self.emit(path, "file", size=self.file_size(path))

        archive_kind = classify_archive(name)
        if archive_kind and self.archive_depth >= 1:
            self.search_archive(path, None, archive_kind, path,
                                self.archive_depth)
        elif self.content_mode and not archive_kind:
            self.scan_content(path)

    def scan_content(self, path):
        """Inhaltssuche in EINER normalen Datei des Dateisystems.

        Gelesen wird häppchenweise statt am Stück: so bleibt der Speicher
        unabhängig von der Dateigröße klein, und bei einem Treffer weit
        vorne sparen wir uns den ganzen Rest."""
        try:
            with open(path, "rb") as handle:
                # iter(callable, sentinel) ruft read() so lange auf,
                # bis es b"" liefert — das Dateiende.
                line = self.match_content(
                    iter(lambda: handle.read(CHUNK_SIZE), b""))
        except OSError as err:
            self.warn(str(err))
            return
        if line is not None and self.type_allowed(False):
            self.emit(path, "file", line, size=self.file_size(path))

    # ---------- Archive ----------

    def search_archive(self, fs_path, fileobj, kind, display, depth,
                       archive_path=None, archive_members=()):
        """Durchsucht ein Archiv. Entweder liegt es als Datei auf der
        Platte (fs_path) oder als Bytes im Speicher (fileobj — das ist
        der Fall bei Archiven INNERHALB von Archiven).

        display ist der Anzeige-Pfad, z. B. "ordner/paket.zip" oder
        verschachtelt "aussen.zip!/innen.zip". depth zählt runter:
        bei 0 steigen wir nicht weiter in Unter-Archive ein."""
        self.report_progress(display)
        if archive_path is None:
            archive_path = fs_path
        try:
            if kind == "zip":
                source = fileobj if fileobj is not None else fs_path
                with zipfile.ZipFile(source) as archive:
                    self.walk_zip(archive, display, depth, archive_path,
                                  archive_members)
            else:  # "tar" — tarfile erkennt die Kompression selbst ("r:*")
                if fileobj is not None:
                    archive = tarfile.open(fileobj=fileobj, mode="r:*")
                else:
                    archive = tarfile.open(fs_path, mode="r:*")
                with archive:
                    self.walk_tar(archive, display, depth, archive_path,
                                  archive_members)
        except EXPECTED_ARCHIVE_ERRORS as err:
            self.warn("%s: %s" % (display, err))

    @staticmethod
    def member_is_hidden(member_path):
        """Prüft jede Pfadkomponente, nicht nur den sichtbaren Blattnamen."""
        components = re.split(r"[/\\]+", member_path)
        return any(component.startswith(".") for component in components
                   if component)

    def visit_member(self, member_path, is_dir, open_member, display, depth,
                     archive_path, archive_members, size=None,
                     compressed_size=None):
        """Gemeinsame Logik für EINEN Archiv-Eintrag (Zip wie Tar).

        member_path: Pfad innerhalb des Archivs.
        read_bytes:  Funktion, die den Inhalt liefert (lazy — wird nur
                     aufgerufen, wenn wir den Inhalt wirklich brauchen).
        size:        entpackte Größe des Eintrags in Bytes (bei Ordnern None).
        """
        full_display = display + "!/" + member_path
        member_chain = tuple(archive_members) + (member_path,)
        name = os.path.basename(member_path.rstrip("/"))

        # Unsichtbare Archiv-Einträge wie im Dateisystem überspringen.
        if not self.include_hidden and self.member_is_hidden(member_path):
            return

        if not self.content_mode and self.matcher(name) \
                and self.type_allowed(is_dir):
            self.emit(full_display, "member", size=None if is_dir else size,
                      filesystem_path=archive_path,
                      archive_members=member_chain)

        if is_dir:
            return

        nested_kind = classify_archive(name)
        if nested_kind and depth - 1 >= 1:
            # Archiv im Archiv: Inhalt in den Speicher holen und rekursiv
            # weitersuchen (depth sinkt um 1).
            try:
                with open_member() as handle:
                    data = self.archive_budget.read_all(
                        handle, full_display, size, compressed_size)
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.warn("%s: %s" % (full_display, err))
                return
            self.search_archive(None, io.BytesIO(data), nested_kind,
                                full_display, depth - 1,
                                archive_path=archive_path,
                                archive_members=member_chain)
        elif self.content_mode and not nested_kind:
            try:
                with open_member() as handle:
                    line = self.match_content(
                        self.archive_budget.iter_chunks(
                            handle, full_display, size, compressed_size))
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.warn("%s: %s" % (full_display, err))
                return
            if line is not None and self.type_allowed(False):
                self.emit(full_display, "member", line, size=size,
                          filesystem_path=archive_path,
                          archive_members=member_chain)

    def walk_zip(self, archive, display, depth, archive_path,
                 archive_members):
        """Geht alle Einträge eines Zip-Archivs durch."""
        for info in archive.infolist():
            self.visit_member(
                info.filename.rstrip("/"),
                info.is_dir(),
                lambda info=info: archive.open(info, "r"),
                display,
                depth,
                archive_path,
                archive_members,
                size=info.file_size,
                compressed_size=info.compress_size,
            )

    def walk_tar(self, archive, display, depth, archive_path,
                 archive_members):
        """Geht alle Einträge eines Tar-Archivs durch."""
        for member in archive.getmembers():
            def open_member(member=member):
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise tarfile.TarError("Eintrag nicht lesbar")
                return extracted
            self.visit_member(member.name, member.isdir(), open_member,
                              display, depth, archive_path, archive_members,
                              size=member.size)


def extract_result(result_path=None, filesystem_path=None, archive_members=None,
                   max_archive_member_bytes=DEFAULT_MAX_ARCHIVE_MEMBER_BYTES,
                   max_archive_total_bytes=DEFAULT_MAX_ARCHIVE_TOTAL_BYTES,
                   max_archive_ratio=DEFAULT_MAX_ARCHIVE_RATIO,
                   materialization_root=None):
    """Packt einen Suchtreffer für die Weiterverwendung aus.

    Eingabe ist ein Treffer-Pfad, wie ihn die Suche ausgibt — entweder
    ein normaler Dateipfad oder die !/-Notation für Archiv-Einträge
    (auch verschachtelt: "aussen.zip!/innen.zip!/datei.txt").

    Normale Pfade werden nur geprüft und absolut ausgegeben; Archiv-
    Einträge werden in einen frischen Temp-Ordner extrahiert. In beiden
    Fällen landet der nutzbare Datei-Pfad auf stdout (genau eine Zeile).
    Das ist der Unterbau für Öffnen/„Öffnen mit"/Drag&Drop in der GUI."""
    if filesystem_path is None:
        # Ein existierender Pfad gewinnt immer gegen die historische !/-Notation.
        # Damit bleibt z. B. /tmp/folder!/plain.txt eine normale Datei.
        if result_path is not None and os.path.exists(result_path):
            filesystem_path = result_path
            archive_members = []
        else:
            parts = (result_path or "").split("!/")
            filesystem_path = parts[0]
            archive_members = parts[1:]
    fs_path = filesystem_path
    members = list(archive_members or [])
    display_path = result_path or fs_path + "".join(
        "!/" + member for member in members)
    if not os.path.exists(fs_path):
        print("favenio: fehler: Pfad existiert nicht: %s" % fs_path,
              file=sys.stderr)
        return 2
    if not members:
        # Kein Archiv-Eintrag, nur eine normale Datei: nichts auszupacken.
        print(os.path.abspath(fs_path))
        return 0

    kind = classify_archive(fs_path)
    data = None    # Bytes des aktuellen Archivs (None = liegt als Datei vor)
    member = members[-1]
    budget = ArchiveBudget(max_archive_member_bytes,
                           max_archive_total_bytes,
                           max_archive_ratio)
    try:
        # Ebene für Ebene absteigen: erst das Archiv auf der Platte
        # öffnen, dann ggf. innere Archive aus dem Speicher heraus.
        for index, member in enumerate(members):
            if kind is None:
                print("favenio: fehler: kein unterstütztes Archiv: %s"
                      % display_path, file=sys.stderr)
                return 2
            if kind == "zip":
                source = io.BytesIO(data) if data is not None else fs_path
                with zipfile.ZipFile(source) as archive:
                    info = archive.getinfo(member)
                    with archive.open(info, "r") as handle:
                        data = budget.read_all(
                            handle, display_path, info.file_size,
                            info.compress_size)
            else:  # "tar"
                if data is not None:
                    archive = tarfile.open(fileobj=io.BytesIO(data),
                                           mode="r:*")
                else:
                    archive = tarfile.open(fs_path, mode="r:*")
                with archive:
                    handle = archive.extractfile(member)
                    if handle is None:
                        raise KeyError(member)
                    with handle:
                        tar_member = archive.getmember(member)
                        data = budget.read_all(
                            handle, display_path, tar_member.size)
            # Endung des gerade gelesenen Eintrags bestimmt, ob die
            # nächste Ebene wieder ein Archiv ist.
            kind = classify_archive(member)
    except EXPECTED_ARCHIVE_ERRORS as err:
        print("favenio: fehler: %s: %s" % (display_path, err),
              file=sys.stderr)
        return 2

    if materialization_root is not None:
        materialization_root = os.path.abspath(materialization_root)
        if not os.path.isdir(materialization_root):
            print("favenio: fehler: Materialisierungsordner existiert nicht: %s"
                  % materialization_root, file=sys.stderr)
            return 2
    out_dir = None
    try:
        out_dir = tempfile.mkdtemp(prefix="hit-", dir=materialization_root)
        out_path = os.path.join(out_dir,
                                os.path.basename(member.rstrip("/")))
        with open(out_path, "wb") as handle:
            handle.write(data)
    except OSError as err:
        if out_dir is not None:
            shutil.rmtree(out_dir, ignore_errors=True)
        print("favenio: fehler: Materialisierung fehlgeschlagen: %s" % err,
              file=sys.stderr)
        return 2
    print(out_path)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="favenio",
        description="Favenio — facile invenio. Dateisuche ohne Index, "
                    "auch in Archiven (zip/jar/docx/…, tar/tar.gz/…).",
        epilog="Exit-Codes: 0 = Treffer gefunden, 1 = keine Treffer, "
               "2 = Fehler. Ausgabeformat für Skripte/Agenten: --json.",
    )
    parser.add_argument("pattern", nargs="?",
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
    parser.add_argument("--only", choices=["both", "files", "dirs"],
                        default="both",
                        help="Treffer auf einen Typ begrenzen: both (Default, "
                             "Dateien & Ordner), files (nur Dateien) oder "
                             "dirs (nur Ordner)")
    parser.add_argument("--hidden", action="store_true",
                        help="unsichtbare (Punkt-)Dateien und -Ordner "
                             "mitdurchsuchen (Default: überspringen)")
    parser.add_argument("--archive-depth", type=int, default=1,
                        metavar="N",
                        help="wie tief in verschachtelte Archive schauen "
                             "(1 = Archive, 2 = Archive in Archiven, …; "
                             "Default: 1)")
    parser.add_argument("--max-archive-member-bytes", type=positive_int,
                        default=DEFAULT_MAX_ARCHIVE_MEMBER_BYTES,
                        metavar="BYTES",
                        help="maximal gelesene entpackte Bytes pro "
                             "Archivmitglied")
    parser.add_argument("--max-archive-total-bytes", type=positive_int,
                        default=DEFAULT_MAX_ARCHIVE_TOTAL_BYTES,
                        metavar="BYTES",
                        help="maximal gelesene entpackte Archivbytes pro "
                             "Suchlauf")
    parser.add_argument("--max-archive-ratio", type=positive_float,
                        default=DEFAULT_MAX_ARCHIVE_RATIO,
                        metavar="FAKTOR",
                        help="maximales ZIP-Kompressionsverhältnis")
    parser.add_argument("--json", action="store_true",
                        help="Treffer als JSON-Zeilen ausgeben (JSONL)")
    parser.add_argument("--progress", action="store_true",
                        help="laufend melden, wo gerade gesucht wird "
                             "(mit --json als JSONL-Objekte type=progress "
                             "auf stdout, sonst auf stderr)")
    parser.add_argument("--extract", metavar="TREFFER",
                        help="statt zu suchen: einen Treffer-Pfad (ggf. mit "
                             "!/-Notation) in einen Temp-Ordner auspacken "
                             "und den nutzbaren Pfad ausgeben")
    parser.add_argument("--extract-json", metavar="JSON",
                        help="Treffer strukturiert mit filesystemPath und "
                             "archiveMembers materialisieren")
    parser.add_argument("--extract-root", metavar="ORDNER",
                        help="app-eigener Temp-Root für Materialisierung")
    parser.add_argument("--version", action="version",
                        version="favenio " + __version__)
    args = parser.parse_args(argv)

    # Extraktions-Modus: kein Suchlauf, nur einen Treffer auspacken.
    extract_options = {
        "max_archive_member_bytes": args.max_archive_member_bytes,
        "max_archive_total_bytes": args.max_archive_total_bytes,
        "max_archive_ratio": args.max_archive_ratio,
        "materialization_root": args.extract_root,
    }
    if args.extract and args.extract_json:
        parser.error("--extract und --extract-json schließen sich aus")
    if args.extract:
        return extract_result(args.extract, **extract_options)
    if args.extract_json:
        try:
            record = json.loads(args.extract_json)
            filesystem_path = record["filesystemPath"]
            archive_members = record.get("archiveMembers", [])
            if not isinstance(filesystem_path, str) \
                    or not isinstance(archive_members, list) \
                    or not all(isinstance(item, str)
                               for item in archive_members):
                raise ValueError("ungültige Feldtypen")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as err:
            print("favenio: fehler: ungültiger strukturierter Treffer: %s"
                  % err, file=sys.stderr)
            return 2
        return extract_result(filesystem_path=filesystem_path,
                              archive_members=archive_members,
                              **extract_options)

    if not args.pattern:
        # parser.error() gibt die Usage aus und beendet mit Exit-Code 2.
        parser.error("PATTERN fehlt (oder --extract verwenden)")

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
    search = Search(matcher, args.content, archive_depth, args.json,
                    progress=args.progress, only=args.only,
                    include_hidden=args.hidden,
                    max_archive_member_bytes=args.max_archive_member_bytes,
                    max_archive_total_bytes=args.max_archive_total_bytes,
                    max_archive_ratio=args.max_archive_ratio)

    # Erst alle Startpfade prüfen, dann suchen: sonst stünden bei mehreren
    # Pfaden schon Treffer auf stdout, bevor ein späterer Pfad den Fehler
    # auslöst.
    for path in paths:
        if not os.path.exists(path):
            print("favenio: fehler: Pfad existiert nicht: %s" % path,
                  file=sys.stderr)
            return 2
    for path in paths:
        search.search_path(path)

    return 0 if search.found_any else 1


if __name__ == "__main__":
    sys.exit(main())
