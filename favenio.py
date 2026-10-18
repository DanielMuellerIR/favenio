#!/usr/bin/env python3
"""Favenio — „facile invenio", ich finde mit Leichtigkeit.

Dateisuche im Stil von EasyFind (Suche ohne Index, direkt im Dateisystem),
mit einer zusätzlichen Fähigkeit: Favenio schaut auch IN Archive hinein
(Zip- und Tar-Familien, einzeln komprimierte .gz/.bz2/.xz-Dateien, auf
Wunsch auch Archive in Archiven). Mit den externen Werkzeugen bsdtar
(macOS-Bordmittel) und zstd kommen 7z, ISO und Zstandard dazu.

Grundprinzipien:
- Standardmäßig wird nach DATEINAMEN gesucht (Ordner zählen mit).
- Mit --content wird stattdessen im DATEIINHALT gesucht, mit --metadata in
  den Metadaten-Textfeldern (Stichwörter, Titel, Beschreibung …; braucht
  das optionale exiftool).
- --min-width/--max-width/--min-height/--max-height filtern Bilder nach
  Pixelmaßen; sie gelten immer zusätzlich (UND) zum Suchmuster.
- --min-size/--max-size filtern Dateigrößen, --modified-from/--modified-to
  und --created-from/--created-to Zeitpunkte; alle Grenzen sind inklusive.
- Ohne Platzhalter (* ? [) gilt „Name enthält den Suchtext";
  mit Platzhaltern gilt Glob-Matching auf den ganzen Namen. --exact verlangt
  in jedem Fall den ganzen Namen.
- Groß-/Kleinschreibung ist standardmäßig egal (--case-sensitive schaltet um).
- Treffer in Archiven werden als  archiv.zip!/pfad/im/archiv  ausgegeben.

Für AI-Agenten/Skripte: --json liefert einen Treffer pro Zeile als
JSON-Objekt (JSONL); Exit-Code 0 = Treffer, 1 = kein Treffer, 2 = Fehler.
Nur Python-Standardbibliothek, keine Abhängigkeiten.
"""

import argparse
import base64
import bz2
import codecs
import collections
import contextlib
import ctypes
import datetime
import errno
import fnmatch
import gzip
import hashlib
import html.entities
import html.parser
import io
import json
import lzma
import math
import os
import posixpath
import re
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import traceback
import unicodedata
import uuid
import urllib.parse
import xml.parsers.expat
import zipfile
import zlib
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

__version__ = "0.64.0"
# Datum dieser Version (ISO 8601). Zweite Single-Source neben __version__;
# das Build-Skript gießt beides in eine Swift-Konstante für die Fenstertitel.
__date__ = "2026-10-18"

# Dateiendungen, die wir als Zip-Container behandeln.
# (Viele Formate sind „Zip in Verkleidung": Java-Archive, Python-Wheels,
#  E-Books und die Office-Formate von Microsoft/LibreOffice.)
ZIP_EXTENSIONS = (
    ".zip", ".jar", ".whl", ".epub",
    ".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp",
    # Die iWork-Formate sind auf einem Mac die häufigsten Zip-Dokumente
    # überhaupt. Ohne sie fand `--content Rechnungsnummer` den Text in
    # einer .docx, in einer .pages daneben aber nicht — und meldete das
    # als erfolgreiche Suche.
    ".pages", ".numbers", ".key",
)

# Dateiendungen der Tar-Familie (unkomprimiert und komprimiert).
TAR_EXTENSIONS = (
    ".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz",
)

# Einzeln komprimierte Dateien: EINE Datei im Kompressionsmantel, kein
# Container wie Zip oder Tar. Die Endung bestimmt das Entpackwerkzeug aus
# der Standardbibliothek. Wichtig: classify_archive() prüft die Tar-Familie
# ZUERST, sonst würde ".tar.gz" hier als einzelnes ".gz" hängenbleiben.
SINGLE_COMPRESSION_OPENERS = {
    ".gz": gzip.open,
    ".bz2": bz2.open,
    ".xz": lzma.open,
}

# --- Optionale Formate über externe Werkzeuge -------------------------------
# Diese Formate kann die Standardbibliothek nicht lesen. Sie funktionieren
# nur, wenn die Werkzeuge auf dem System vorhanden sind — sonst verhalten
# sich die Dateien wie vor dieser Integration (normale Dateien, bei
# --content wird der rohe Inhalt durchsucht). macOS bringt bsdtar mit;
# Zstandard braucht zusätzlich ein zstd-Programm (z. B. aus Homebrew).

# Liest bsdtar von Haus aus (auf diesem Weg real geprüft: 7-Zip und ISO-9660).
BSDTAR_NATIVE_EXTENSIONS = (".7z", ".iso")
# Tar mit Zstandard-Kompression: bsdtar ruft dafür intern "zstd" auf.
BSDTAR_ZSTD_TAR_EXTENSIONS = (".tar.zst", ".tzst")
# Einzeln Zstandard-komprimierte Datei: direkt über das zstd-Programm,
# denn bsdtar erkennt einen rohen zst-Strom nicht als Archiv.
ZSTD_SINGLE_EXTENSION = ".zst"

# Alle Endungen, die für EINE Datei im Kompressionsmantel stehen. Ihr
# Eintragsname entsteht allein aus dem Dateinamen, ohne die Datei zu
# öffnen; deshalb entscheidet bei ihnen die Signatur schon VOR dem
# Abstieg, ob überhaupt ein Archiv vorliegt (search_archive).
SINGLE_COMPRESSION_KINDS = tuple(SINGLE_COMPRESSION_OPENERS) \
    + (ZSTD_SINGLE_EXTENSION,)

# Orte, an denen zstd liegen kann, wenn es nicht im PATH steht (die Apps
# starten mit dem knappen launchd-PATH ohne Homebrew).
ZSTD_FALLBACK_CANDIDATES = (
    "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/opt/local/bin/zstd",
)

# Cache der einmaligen Werkzeugsuche: (bsdtar_pfad, zstd_pfad, env).
# None = noch nicht ermittelt. Tests dürfen den Cache gezielt setzen,
# um „Werkzeug fehlt" zu simulieren.
_EXTERNAL_TOOLS = None


def external_archive_tools():
    """Ermittelt einmalig, welche externen Entpackwerkzeuge nutzbar sind.

    Liefert (bsdtar_pfad, zstd_pfad, env): env ist die Umgebung für
    bsdtar-Unterprozesse, mit dem zstd-Fundort vorn im PATH — bsdtar
    findet sein zstd-Filterprogramm ausschließlich über den PATH."""
    global _EXTERNAL_TOOLS
    if _EXTERNAL_TOOLS is None:
        bsdtar = shutil.which("bsdtar")
        zstd = shutil.which("zstd")
        if zstd is None:
            for candidate in ZSTD_FALLBACK_CANDIDATES:
                if os.access(candidate, os.X_OK):
                    zstd = candidate
                    break
        env = None
        if zstd is not None:
            env = dict(os.environ)
            env["PATH"] = (os.path.dirname(zstd) + os.pathsep
                           + env.get("PATH", ""))
        _EXTERNAL_TOOLS = (bsdtar, zstd, env)
    return _EXTERNAL_TOOLS


def bsdtar_escape(member):
    """Entschärft Glob-Zeichen in einem Eintragsnamen.

    bsdtar interpretiert das Eintrags-Argument als Muster; ein
    unescaptes „a*.txt" würde auch „abc.txt" treffen und beide
    Inhalte aneinanderhängen. Ein Backslash macht das Zeichen wörtlich
    (verifiziert am 2026-07-29 mit bsdtar 3.5.3)."""
    escaped = re.sub(r"([\\*?\[\]])", r"\\\1", member)
    # libarchive deutet ein Caret nur am Musteranfang als Negation. Ohne
    # Maskierung findet `^bericht.txt` deshalb gerade NICHT diesen Eintrag.
    if escaped.startswith("^"):
        escaped = "\\" + escaped
    return escaped


# Kurzformen, die bsdtar beim AUFLISTEN für Steuerzeichen ausgibt (libarchive
# „safe_fprintf"): Aus einem Tabulator im Eintragsnamen wird die Zeichenfolge
# \t, aus einem Backslash \\. Alles andere nicht Druckbare kommt als \NNN —
# dreistellig oktal, eine Folge je Byte.
BSDTAR_LISTING_ESCAPES = {
    ord("a"): 0x07, ord("b"): 0x08, ord("f"): 0x0C, ord("n"): 0x0A,
    ord("r"): 0x0D, ord("t"): 0x09, ord("v"): 0x0B, ord("\\"): 0x5C,
}


def bsdtar_unescape(raw_line):
    """Macht die Maskierung einer `bsdtar -tf`-Zeile rückgängig
    (Bytes rein, Bytes raus).

    bsdtar gibt Eintragsnamen NICHT wörtlich aus, sondern maskiert
    Steuerzeichen und den Backslash selbst — auch wenn die Ausgabe in eine
    Pipe geht. Ohne diese Rückabbildung liefe ein Eintrag mit Tabulator im
    Namen unter dem maskierten Namen: Der Treffer zeigte einen falschen Pfad,
    und Inhaltssuche wie Extraktion fänden ihn nicht mehr (verifiziert am
    2026-08-03 mit bsdtar 3.5.3).

    Die Rückabbildung ist eindeutig, weil ein echter Backslash im Namen selbst
    schon maskiert ankommt. Oktale Folgen stehen für einzelne Bytes; deshalb
    arbeitet die Funktion auf Bytes und die UTF-8-Dekodierung passiert erst
    danach."""
    out = bytearray()
    index = 0
    length = len(raw_line)
    while index < length:
        byte = raw_line[index]
        if byte != 0x5C or index + 1 >= length:   # 0x5C = Backslash
            out.append(byte)
            index += 1
            continue
        marker = raw_line[index + 1]
        if marker in BSDTAR_LISTING_ESCAPES:
            out.append(BSDTAR_LISTING_ESCAPES[marker])
            index += 2
            continue
        digits = raw_line[index + 1:index + 4]
        if len(digits) == 3 and all(0x30 <= digit <= 0x37 for digit in digits):
            out.append(int(digits, 8) & 0xFF)
            index += 4
            continue
        # Unbekannte Folge: den Backslash wörtlich nehmen und weitergehen.
        out.append(byte)
        index += 1
    return bytes(out)


class ToolStream:
    """Liest die stdout eines Entpack-Unterprozesses wie eine Datei.

    close() räumt den Prozess in jedem Fall auf. Ein Fehlerstatus des
    Werkzeugs wird nur gemeldet, wenn der Strom bis zum Ende gelesen
    wurde — wer nach einem frühen Treffer abbricht, schließt die Pipe,
    das Werkzeug endet mit SIGPIPE, und das ist KEIN Fehler."""

    def __init__(self, proc, label, cleanup_path=None):
        self.proc = proc
        self.label = label
        self.cleanup_path = cleanup_path
        self.saw_eof = False

    def read(self, size=-1):
        chunk = self.proc.stdout.read(size)
        if not chunk:
            self.saw_eof = True
        return chunk

    def close(self):
        try:
            self.proc.stdout.close()
        except OSError:
            pass
        returncode = self.proc.wait()
        if self.cleanup_path is not None:
            try:
                os.unlink(self.cleanup_path)
            except OSError:
                pass
            self.cleanup_path = None
        if self.saw_eof and returncode != 0:
            raise ArchiveReadError(
                "%s: Entpackwerkzeug endete mit Status %d"
                % (self.label, returncode))

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is not None:
            # Es fliegt bereits eine Ausnahme — keine zweite aus close().
            try:
                self.close()
            except ArchiveReadError:
                pass
        else:
            self.close()
        return False


def zstd_open(source, mode="rb"):
    """Öffnet eine .zst-Datei als entpackten Datenstrom über das externe
    zstd-Programm (die Standardbibliothek kann Zstandard nicht lesen).

    source ist ein Pfad oder ein BytesIO mit den komprimierten Bytes
    (Archiv im Archiv). Speicherdaten gehen über eine Temp-Datei statt
    über stdin: gleichzeitiges Schreiben und Lesen zweier Pipes kann
    sich gegenseitig blockieren. mode wird nur für die Signatur-
    Gleichheit mit gzip.open/bz2.open/lzma.open akzeptiert."""
    _, zstd, _ = external_archive_tools()
    if zstd is None:
        raise ArchiveReadError("zstd-Programm nicht gefunden")
    cleanup_path = None
    if hasattr(source, "getvalue"):
        handle = tempfile.NamedTemporaryFile(suffix=".zst", delete=False)
        with handle:
            handle.write(source.getvalue())
        cleanup_path = handle.name
        label = "zst-Daten im Speicher"
        path = handle.name
    else:
        label = os.fspath(source)
        path = label
    try:
        proc = subprocess.Popen([zstd, "-dcq", "--", path],
                                stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
    except OSError:
        # Scheitert schon der Start (z. B. weil das gemerkte zstd-Programm
        # inzwischen weg oder nicht mehr ausführbar ist), gibt es kein
        # ToolStream — und damit niemanden, der die Temp-Datei später
        # aufräumt. Deshalb hier selbst löschen und den Fehler weiterreichen.
        if cleanup_path is not None:
            try:
                os.unlink(cleanup_path)
            except OSError:
                pass
        raise
    return ToolStream(proc, label, cleanup_path=cleanup_path)


def single_opener(extension):
    """Liefert die Öffnen-Funktion für eine Einzelkompressions-Endung."""
    if extension == ZSTD_SINGLE_EXTENSION:
        return zstd_open
    return SINGLE_COMPRESSION_OPENERS[extension]


def zip_member_mtime(info):
    """Änderungszeit eines Zip-Eintrags als Unix-Zeit — oder None.

    Zip speichert die Zeit als sechs Felder in ORTSZEIT ohne Zeitzone
    (`ZipInfo.date_time`); `time.mktime()` deutet sie wie der Finder in der
    Zeitzone dieses Rechners. Ein Eintrag mit unsinnigem Datum (Jahr 1980
    ist der Nullwert, alles darunter ungültig) oder einem Wert außerhalb
    des Bereichs von mktime liefert None statt eines Abbruchs."""
    date_time = getattr(info, "date_time", None)
    if not date_time or len(date_time) != 6 or date_time[0] < 1980:
        return None
    try:
        # mktime normalisiert etwa den 31. Februar still zum März. Zuerst
        # Kalenderfelder prüfen, danach weiterhin die lokale Zone verwenden.
        datetime.datetime(*date_time)
        return time.mktime(tuple(date_time) + (0, 0, -1))
    except (OverflowError, ValueError):
        return None


def single_member_name(container_name, extension):
    """Der Eintragsname einer einzeln komprimierten Datei: der Dateiname ohne
    die Kompressionsendung („notiz.txt.gz" enthält „notiz.txt").

    Suche und Extraktion müssen dieselbe Regel anwenden: `walk_single()` gibt
    diesen Namen als Archiv-Eintrag aus, `extract_result()` akzeptiert genau
    ihn wieder und lehnt jeden anderen mit KeyError ab. Zwei getrennte Kopien
    der Regel könnten auseinanderdriften — dann wäre ein .gz-Treffer nicht
    mehr auszupacken. Sonderfall: Heißt die Datei nur „.gz", bleibt der Name
    er selbst, statt leer zu werden."""
    return container_name[:-len(extension)] or container_name

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

# Ab wann eine Zeile ohne Umbruch abschnittsweise geprüft wird, und wie viel
# Text dabei aus dem vorigen Abschnitt stehen bleibt.
#
# Minifiziertes JSON, ein Base64-Block oder eine mysqldump-Zeile haben über
# hunderte Megabyte keinen einzigen Umbruch. Ohne Grenze puffert
# match_content() eine solche Datei vollständig: gemessen am 2026-09-03 mit
# dem System-Python auf 144 MB Text 488 MB Spitzenspeicher, gegenüber 18 MB
# bei derselben Datenmenge MIT Umbrüchen. Eine 4-GB-Datei dieser Bauart
# hätte den Prozess vom System abschießen lassen. Mit Grenze sind es 58 MB,
# bei unveränderten Ergebnissen und leicht besserer Laufzeit.
#
# Die Überlappung ist der Preis dafür, dass ein Treffer an der Schnittstelle
# nicht verlorengeht: Der Schwanz des vorigen Abschnitts bleibt stehen.
# Gefunden wird damit jeder Treffer, der nicht länger als die Überlappung
# ist — 64 Ki Zeichen, also weit jenseits jedes realistischen Suchbegriffs.
MAX_LINE_CHARS = 8 * 1024 * 1024
LINE_OVERLAP_CHARS = 64 * 1024


# Die beiden Kleinformen des griechischen Sigma. Welche davon str.lower() aus
# einem großen „Σ" macht, hängt davon ab, ob das Zeichen am Wortende steht —
# der einzige Fall, in dem Kleinschreibung vom Zusammenhang abhängt. Warum das
# für den Vortest wichtig ist, steht in ContentProbe.
GREEK_SMALL_SIGMA = "σ"   # σ
GREEK_FINAL_SIGMA = "ς"   # ς
GREEK_SIGMAS = GREEK_SMALL_SIGMA + GREEK_FINAL_SIGMA


class ArchiveReadError(Exception):
    """Kontrollierter Lesefehler EINES Eintrags oder EINER Datei.

    Der Name kommt aus der Archivsuche, gilt aber allgemein: Alles, was
    hiermit endet, wird als Warnung gemeldet und übersprungen — der
    restliche Suchlauf läuft weiter."""

    def __init__(self, message, reason="readError"):
        super().__init__(message)
        self.reason = reason


class ArchiveLimitError(ArchiveReadError):
    """Ein Archivmitglied überschreitet eine konfigurierte Sicherheitsgrenze."""

    def __init__(self, message, reason="archiveBudget"):
        super().__init__(message, reason)


class DirectoryMemberError(ArchiveReadError):
    """`--extract` zielt auf einen Ordner-Eintrag eines Archivs.

    Die Suche gibt Ordner im Archiv als Treffer aus (`isDirectory: true`);
    materialisiert wird aber nur eine Datei. Die Apps prüfen das vorher
    selbst, die CLI nennt den Grund statt eines nackten `KeyError`."""

    def __init__(self, member):
        super().__init__("Ordner-Eintrag, wird nicht materialisiert: %s"
                         % member)


class OutputClosed(Exception):
    """Der Leser von stdout oder stderr ist weg (`favenio … | head -1`,
    `favenio … 2>&1 | head -1`).

    Absichtlich KEIN OSError: `BrokenPipeError` ist einer, und
    `search_archive()` fängt OSError als Lesefehler eines Archivs ab. Ein
    geschlossener Leser innerhalb eines Archivs wurde deshalb als Warnung
    je Archiv gemeldet, und die Suche lief bis zum Ende weiter, ohne dass
    jemand zuhörte (belegt 2026-09-17). Diese Ausnahme läuft an allen
    Lesefehler-Fängen vorbei bis zu `main()`."""


def write_output(text, flush=False, file=None):
    """Schreibt eine Zeile nach stdout (mit `file=sys.stderr` nach stderr);
    ein geschlossener Leser wird zu OutputClosed (siehe dort).

    Auch stderr braucht das: Bei `2>&1 | head -1` trifft die nächste
    Warnung den geschlossenen Leser, und ein nackter BrokenPipeError aus
    `warn()` innerhalb eines Archivs wäre wieder ein OSError, den ein
    Lesefehler-Fang als Warnung behandeln will."""
    try:
        print(text, file=file, flush=flush)
    except BrokenPipeError:
        raise OutputClosed() from None


def discard_closed_output():
    """Biegt stdout UND stderr auf /dev/null um, nachdem ein Leser weg ist.

    Python leert beim Interpreter-Ende beide Puffer. Steckt in einem noch
    Text für die geschlossene Pipe, scheitert das erneut — mit „Exception
    ignored" und Status 120 statt 0/1. Bis 2026-09-17 wurde nur stdout
    umgebogen; `favenio … 2>&1 | head -1` mit Warnungen endete deshalb
    weiter mit 120. Ein Strom ohne Dateideskriptor (StringIO in den Tests)
    bleibt, wie er ist."""
    try:
        devnull = os.open(os.devnull, os.O_WRONLY)
    except OSError:
        return
    try:
        for stream in (sys.stdout, sys.stderr):
            try:
                os.dup2(devnull, stream.fileno())
            except (OSError, ValueError):
                pass
    finally:
        os.close(devnull)


def write_result(lines):
    """Gibt das Ergebnis eines Aufrufs ohne Suchlauf aus (`--extract`,
    `--list-metadata-fields`). Ein geschlossener Leser ist dort kein
    Fehler — die Arbeit ist schon getan —, darf aber auch nicht erst beim
    Interpreter-Ende mit Status 120 auffallen: Deshalb wird hier geleert."""
    try:
        for line in lines:
            write_output(line)
        sys.stdout.flush()
    except (OutputClosed, BrokenPipeError):
        discard_closed_output()


def json_safe_text(text):
    """Ersetzt alleinstehende Surrogatzeichen für gültiges UTF-8-JSON.

    Dateinamenbytes bleiben getrennt als Base64-Identität erhalten; diese
    Darstellung ist nur für Anzeige und die bisherigen Textfelder."""
    return re.sub(r"[\ud800-\udfff]", "\ufffd", text)


def archive_member_bytes(member):
    """Kodiert einen internen Archivnamen verlustfrei für JSON und Swift."""
    raw = member.encode("utf-8", "surrogateescape")
    return base64.b64encode(raw).decode("ascii")


def decode_archive_member(encoded):
    """Stellt einen Archivnamen aus seiner Base64-Identität wieder her."""
    raw = base64.b64decode(encoded.encode("ascii"), validate=True)
    return raw.decode("utf-8", "surrogateescape")


def use_locale_independent_streams():
    """stdout und stderr so einstellen, wie Python sie ohne jede Locale
    hätte (UTF-8-Modus, so starten die Apps über launchd).

    Ein Dateisystemname mit nicht als UTF-8 lesbaren Bytes kann als
    Surrogatzeichen ankommen. Unter einer strikten UTF-8-Locale warf
    `print()` daran `UnicodeEncodeError`, und der GESAMTE Lauf endete mit
    Exit 2. `surrogateescape` auf stdout hält die Textausgabe robust.
    Tar-Eintragsnamen bleiben intern per `surrogateescape` verlustfrei;
    `emit()` trennt für JSONL die UTF-8-sichere Anzeige von der Base64-
    Identität. So bleibt der Strom gültig und die Extraktion eindeutig.
    stderr behält Pythons eigene Voreinstellung `backslashreplace` — dort
    genügt eine lesbare Diagnose —, bekommt aber wie stdout
    UTF-8 statt der Kodierung einer Nicht-UTF-8-Locale.

    Ein Strom ohne `reconfigure()` (StringIO in den Tests) oder ein schon
    geschlossener bleibt, wie er ist."""
    for stream, errors in ((sys.stdout, "surrogateescape"),
                           (sys.stderr, "backslashreplace")):
        try:
            stream.reconfigure(encoding="utf-8", errors=errors)
        except (AttributeError, ValueError):
            pass


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
                % (label, declared_size, self.maximum_member), "archiveMemberBytes")
        if declared_size and compressed_size is not None:
            ratio = declared_size / max(1, compressed_size)
            if ratio > self.maximum_ratio:
                raise ArchiveLimitError(
                    "%s: Kompressionsverhältnis %.1f überschreitet Grenze %.1f"
                    % (label, ratio, self.maximum_ratio), "archiveRatio")

    def iter_chunks(self, handle, label, declared_size=None,
                    compressed_size=None, free_bytes=0):
        """Liefert die entpackten Bytes eines Archiv-Eintrags in Häppchen und
        bricht ab, sobald eine Grenze überschritten wäre.

        free_bytes sind die ersten n Bytes DIESES Eintrags, die schon einmal
        gegen das Gesamtbudget des Suchlaufs gezählt wurden. Das brauchen wir
        für den zweiten Durchlauf über ein Mitglied, dessen Anfang der Vortest
        (ContentProbe) bereits gelesen hat: derselbe Eintrag soll das Budget
        nicht doppelt belasten. Alles, was DARÜBER hinaus gelesen wird, zählt
        wieder voll — sonst käme ein Mitglied, dessen Vortest früh fertig war,
        am Gesamtbudget vorbei (der genaue Lauf liest bei --exact und einer
        sehr langen Zeile weiter als der Vortest). Die Einzelgrenze pro
        Eintrag gilt in beiden Durchläufen."""
        self.validate(label, declared_size, compressed_size)
        member_bytes = 0
        while True:
            chunk = handle.read(CHUNK_SIZE)
            if not chunk:
                return
            start = member_bytes
            member_bytes += len(chunk)
            # Nur der Teil des Häppchens hinter dem schon gezählten Anfang
            # belastet das Gesamtbudget; ohne free_bytes ist das das ganze
            # Häppchen.
            self.consumed += max(0, member_bytes - max(free_bytes, start))
            if member_bytes > self.maximum_member:
                raise ArchiveLimitError(
                    "%s: Einzelgrenze %d überschritten"
                    % (label, self.maximum_member), "archiveMemberBytes")
            if self.consumed > self.maximum_total:
                raise ArchiveLimitError(
                    "%s: Gesamtbudget %d überschritten"
                    % (label, self.maximum_total), "archiveTotalBytes")
            yield chunk

    def read_all(self, handle, label, declared_size=None,
                 compressed_size=None):
        return b"".join(self.iter_chunks(
            handle, label, declared_size, compressed_size))


EXPECTED_ARCHIVE_ERRORS = (
    ArchiveReadError,
    OSError,               # deckt auch gzip.BadGzipFile ab
    RuntimeError,          # z. B. verschlüsseltes ZIP-Mitglied
    NotImplementedError,   # nicht unterstützte ZIP-Kompression
    KeyError,
    EOFError,              # abgeschnittener gzip-/bz2-/xz-Strom
    zipfile.BadZipFile,
    zipfile.LargeZipFile,
    tarfile.TarError,
    lzma.LZMAError,        # kaputter xz-Strom
    zlib.error,            # kaputte Deflate-Daten in gzip
    UnicodeDecodeError,    # Zip mit gesetztem UTF-8-Flag, dessen
                           # Eintragsnamen aber CP932-/Latin-1-Bytes
                           # tragen (verbreitet bei Windows-Packern).
                           # zipfile wirft schon beim Öffnen; ohne diesen
                           # Eintrag beendete EIN solches Archiv den
                           # ganzen Suchlauf statt nur sich selbst.
)


# Die Fehler, die zipfile und tarfile werfen, wenn sich eine Datei nicht als
# das versprochene Format öffnen lässt. Sie sagen NICHT, warum: Dieselbe
# BadZipFile kommt bei einem Klartext mit der Endung `.zip` wie bei einem
# echten, aber abgeschnittenen Zip. Erst die Signatur unten trennt beides.
FORMAT_MISMATCH_ERRORS = (zipfile.BadZipFile, tarfile.ReadError)


# Die Bytes, mit denen ein Archiv sich selbst ankündigt, je Format als
# (Position, Bytefolge). Die Endung ist nur ein Hinweis — `.key` ist weit
# häufiger ein TLS-Schlüssel als eine Keynote-Datei —, die Signatur dagegen
# ist eine Zusage.
# Zstandard erlaubt vor dem eigentlichen Daten-Frame beliebige überspringbare
# Frames. Deren Magic-Wert reicht in Little-Endian von 50 2a 4d 18 bis
# 5f 2a 4d 18; nur den normalen Daten-Magic zu prüfen verliert gültige Dateien.
ZSTANDARD_SIGNATURES = ((0, b"\x28\xb5\x2f\xfd"),) + tuple(
    (0, bytes((value, 0x2a, 0x4d, 0x18))) for value in range(0x50, 0x60)
)


ARCHIVE_SIGNATURES = {
    # Lokaler Eintrag, leeres Archiv, gespanntes Archiv.
    "zip": ((0, b"PK\x03\x04"), (0, b"PK\x05\x06"), (0, b"PK\x07\x08")),
    # tarfile öffnet mit "r:*" und erkennt die Kompression selbst; deshalb
    # zählen auch die Hüllen gzip, bzip2 und xz. Ein blankes Tar trägt sein
    # "ustar" erst ab Position 257. Ein sehr altes v7-Tar hat gar keine
    # Signatur und bleibt deshalb beim stillen Rückfall auf „normale Datei".
    "tar": ((0, b"\x1f\x8b"), (0, b"BZh"), (0, b"\xfd7zXZ\x00"),
            (257, b"ustar")),
    # Einzelkompression: die Hülle selbst, immer am Anfang.
    ".gz": ((0, b"\x1f\x8b"),),
    ".bz2": ((0, b"BZh"),),
    ".xz": ((0, b"\xfd7zXZ\x00"),),
    ".zst": ZSTANDARD_SIGNATURES,
    # Die Formate, die nur bsdtar liest. tar.zst trägt die Zstandard-Hülle.
    ".7z": ((0, b"7z\xbc\xaf\x27\x1c"),),
    ".tar.zst": ZSTANDARD_SIGNATURES,
    # ISO 9660 schreibt seine Kennung erst ab Sektor 16 (0x8001); weitere
    # Volume Descriptors folgen sektorweise. Das kostet 36 KB Kopf — die
    # liest nur, wessen Endung ein ISO verspricht UND dessen Öffnen
    # scheiterte, also kein normaler Suchlauf.
    ".iso": ((0x8001, b"CD001"), (0x8801, b"CD001"), (0x9001, b"CD001")),
}


def signature_head_bytes(key):
    """So viel Anfang braucht die Signaturprüfung dieses Formats.

    Für Zip sind es vier Bytes, für ein Tar 262 (257 + „ustar"), für ein
    ISO 36 870. Je Format nur so viel zu lesen ist der Unterschied
    zwischen einem billigen Blick und 36 KB für jede Datei."""
    return max((start + len(magic)
                for start, magic in ARCHIVE_SIGNATURES.get(key, ())),
               default=0)


def archive_signature_key(kind, name):
    """Welche Signaturliste gilt für diese Datei?

    `kind` aus classify_archive() sagt, WER das Archiv öffnet, nicht
    welches Format es ist: Hinter "bsdtar" stecken 7z, ISO und tar.zst mit
    drei verschiedenen Signaturen. Für alle anderen Arten ist `kind`
    selbst schon der Schlüssel ("zip", "tar", ".gz", ".bz2", ".xz",
    ".zst")."""
    if kind != "bsdtar":
        return kind
    lowered = name.lower()
    if lowered.endswith(BSDTAR_ZSTD_TAR_EXTENSIONS):
        return ".tar.zst"
    for extension in BSDTAR_NATIVE_EXTENSIONS:
        if lowered.endswith(extension):
            return extension
    return kind


def tar_envelope_kind(name, head):
    """Die Endung sagt „Tar in einer Hülle" — aber steckt wirklich ein Tar
    darin?

    `ARCHIVE_SIGNATURES["tar"]` zählt gzip, bzip2 und xz mit, weil
    `tarfile` mit "r:*" die Kompression selbst erkennt. Diese Bytes
    kündigen aber nur die HÜLLE an, kein Tar. Ein
    `gzip -c notiz.txt > notiz.tar.gz` — ein verbreiteter
    Benennungsfehler — ist ein gültiges gzip ohne Tar darin: `tarfile`
    scheitert, die Signatur sagt trotzdem „ist ein Tar", und die Datei
    fiel bis 0.34.13 mit der Warnung „beschädigtes Archiv" aus der Suche.
    Als `rein.gz` benannt fand favenio denselben Inhalt.

    Liefert die Endung der Einzelkompression, wenn der Dateiname auf
    genau sie endet UND der Anfang ihre Hülle ankündigt; sonst None.
    Der Name muss passen, weil `single_member_name()` die Endung
    abschneidet: `notiz.tgz` ergäbe mit ".gz" den Eintrag `notiz.t`.
    Für `.tgz`, `.tbz2`, `.txz` und `.tzst` bleibt es deshalb bei der
    Warnung. Nur „ustar" ab Position 257 beweist ein Tar unmittelbar.

    Dieselbe Regel gilt für `.tar.zst` (seit 2026-09-17), das bsdtar statt
    `tarfile` öffnet: `zstd -c notiz.txt > notiz.tar.zst` scheiterte an
    „bsdtar: Unrecognized archive format", während dieselben Bytes als
    `notiz.tar.gz` gefunden wurden. Deshalb über alle Einzelkompressionen,
    `.zst` eingeschlossen."""
    lowered = name.lower()
    for extension in SINGLE_COMPRESSION_KINDS:
        if lowered.endswith(extension) \
                and announces_archive_format(extension, head):
            return extension
    return None


def announces_archive_format(key, head):
    """Sagen die ersten Bytes selbst, dass das ein Archiv dieses Formats ist?

    `key` ist der Formatschlüssel aus archive_signature_key(), nicht die
    Öffner-Art aus classify_archive(): "bsdtar" hat selbst keine Signatur,
    seine drei Formate haben je eine eigene.

    Nur mit Signatur ist ein Öffnungsfehler ein BESCHÄDIGTES Archiv und
    damit eine Warnung wert. Ohne Signatur war die Endung schlicht
    mehrdeutig, und die Datei ist eine ganz normale Datei."""
    return any(head[start:start + len(magic)] == magic
               for start, magic in ARCHIVE_SIGNATURES.get(key, ()))


# Obergrenze für die Namensliste EINES Archivs, das nur bsdtar lesen kann.
#
# ArchiveBudget zählt nur Eintrags-INHALTE; der Namenskatalog läuft daran
# vorbei. Bei 7z, ISO und tar.zst liegt er komprimiert im Archiv und wirkt
# deshalb mit Verstärkungsfaktor: gemessen am 2026-09-03 trieb ein .tar.zst
# von 307 KB mit 200 000 Einträgen den Speicher auf 182 MB — Faktor 600.
# Dieselbe Bauart im zweistelligen MB-Bereich reichte für den GB-Bereich.
# Mit Grenze sind es 58 MB, und das Archiv wird mit Meldung übersprungen.
MAX_ARCHIVE_LISTING_BYTES = 32 * 1024 * 1024

# Python hält beim Durchlaufen eines Tar-Archivs jedes TarInfo-Objekt im
# Katalog. Ein stark komprimiertes tar.gz mit hunderttausenden leeren
# Einträgen kann deshalb viel mehr Arbeitsspeicher belegen als seine Datei
# vermuten lässt. Die Inhaltsbudgets greifen hier nicht: Sie zählen nur
# gelesene Eintragsdaten. 65 536 Einträge lassen große reale Archive zu,
# deckeln aber den Katalog, bevor er in den dreistelligen MB-Bereich wächst.
MAX_TAR_MEMBERS = 65_536

# `search_archive()` ruft sich für Archive in Archiven rekursiv auf. Bei etwa
# 330 verschachtelten Zips kann der C-Stack schon vor einer auffangbaren
# RecursionError-Grenze abbrechen. Die CLI lehnt solche Werte deshalb ab.
MAX_ARCHIVE_DEPTH = 100


def bounded_tar_members(archive):
    """Liest den Tar-Katalog vollständig, aber nie über die feste Grenze.

    Suche UND Extraktion müssen denselben Wächter verwenden. Erst der
    vollständige Katalog darf Ergebnisse freigeben: Ein abgeschnittenes Tar
    liefert sonst Treffer aus seinem lesbaren Anfang und erst danach eine
    Warnung."""
    members = []
    for index, member in enumerate(archive):
        if index >= MAX_TAR_MEMBERS:
            raise ArchiveLimitError(
                "mehr als %d Tar-Einträge — Archiv übersprungen"
                % MAX_TAR_MEMBERS, "archiveMemberCount")
        members.append(member)
    return members


def bsdtar_list(bsdtar, path, env, limit=None, verbose=False):
    """Die Ausgabe von `bsdtar -tf` (mit `verbose` von `bsdtar -tvf`),
    aber höchstens `limit` Bytes lang.

    `subprocess.run(stdout=PIPE)` liest, was kommt — hier ist genau das
    die Lücke (siehe MAX_ARCHIVE_LISTING_BYTES). Deshalb wird der Strom
    häppchenweise gelesen und der Prozess beendet, sobald die Grenze
    überschritten ist.

    stderr geht in eine temporäre Datei statt in eine Pipe: Eine zweite
    Pipe, die niemand leert, während wir stdout lesen, könnte volllaufen
    und beide Seiten blockieren.

    Liefert (stdout, stderr, returncode). Reißt die Grenze, ist das ein
    ArchiveReadError — das Archiv wird übersprungen und gemeldet, statt
    den Speicher des ganzen Laufs aufzubrauchen."""
    if limit is None:
        limit = MAX_ARCHIVE_LISTING_BYTES
    parts = []
    total = 0
    too_large = False
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen([bsdtar, "-tvf" if verbose else "-tf",
                                    path],
                                   stdout=subprocess.PIPE,
                                   stderr=errors, env=env)
        try:
            while True:
                chunk = process.stdout.read(CHUNK_SIZE)
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    too_large = True
                    process.kill()
                    break
                parts.append(chunk)
        finally:
            process.stdout.close()
            process.wait()
        errors.seek(0)
        stderr = errors.read(CHUNK_SIZE)
    if too_large:
        raise ArchiveLimitError(
            "Eintragsliste größer als %d Bytes — Archiv übersprungen"
            % limit, "archiveListingBytes")
    return b"".join(parts), stderr, process.returncode


def bsdtar_listing_names(raw_stdout):
    """Die Eintragsnamen aus der Ausgabe von `bsdtar -tf`.

    Suche und `--extract` müssen hier dasselbe sehen: Findet die Suche einen
    Eintrag, dessen Name die Maskierung oder ein "./"-Präfix trägt, muss
    `pick_member()` beim Materialisieren genau diesen Namen wiedererkennen.
    Vorher las nur der Suchpfad die Maskierung zurück, und ein 7z-Eintrag mit
    Tabulator und "!/" im Namen ließ sich nicht mehr auspacken.

    Erst die Maskierung zurücknehmen (bsdtar schreibt z. B. für einen
    Tabulator die zwei Zeichen \\t), dann dekodieren — echte Zeilenumbrüche im
    Namen kommen ebenfalls maskiert an, die Zeilenaufteilung bleibt dadurch
    heil. ISO listet ein "."-Wurzelelement; "./"-Präfixe würden als
    versteckte Komponente gelten. Beides wird normalisiert."""
    names = []
    for raw_line in raw_stdout.split(b"\n"):
        raw = bsdtar_unescape(raw_line).decode("utf-8", "replace")
        if raw.startswith("./"):
            raw = raw[2:]
        if raw in ("", ".", "./"):
            continue
        names.append(raw)
    return names


def bsdtar_member_is_directory(bsdtar, path, env, member):
    """Ob `member` in einem bsdtar-Archiv (7z, ISO, tar.zst) ein Ordner ist.

    Für `extract_result()`, und nur dann, wenn das Auspacken null Bytes
    lieferte: Die zwei Auflistungen kosten je einen bsdtar-Prozess samt
    Entpacken des Katalogs. Typ wie in walk_bsdtar() über
    bsdtar_listing_entries(); passen die Auflistungen nicht zusammen,
    gilt dieselbe Heuristik (Schrägstrich am Ende oder Einträge darunter).
    Ist nicht einmal `-tf` lesbar, bleibt es beim bisherigen Ergebnis —
    einer leeren Datei —, denn das Auspacken selbst war ja erfolgreich."""
    try:
        raw, _, status = bsdtar_list(bsdtar, path, env)
    except ArchiveReadError:
        return False
    if status != 0:
        return False
    try:
        verbose, _, verbose_status = bsdtar_list(bsdtar, path, env,
                                                 verbose=True)
    except ArchiveReadError:
        verbose, verbose_status = None, 1
    below = member + "/"
    for name, is_dir in bsdtar_listing_entries(
            raw, verbose if verbose_status == 0 else None):
        clean = name.rstrip("/")
        if is_dir is not None:
            if clean == member:
                return is_dir
        elif name == below or clean.startswith(below):
            return True
    return False


def bsdtar_listing_entries(raw_stdout, raw_verbose):
    """Die Eintragsnamen samt Typ aus `bsdtar -tf` UND `bsdtar -tvf`.

    Liefert eine Liste von (name, is_dir); `is_dir` ist None, wenn der Typ
    nicht bestimmbar war. Die Namen kommen ausschließlich aus `-tf`
    (siehe bsdtar_listing_names), der Typ aus Spalte 0 der Zeile mit
    derselben Nummer in `-tvf` — ein `d` ist ein Ordner.

    Warum zwei Auflistungen statt nur der ausführlichen: Aus einer
    `-tvf`-Zeile lässt sich der Name nicht sicher herauslösen. Die Zeile
    ist im Stil von `ls -l` gebaut, Nutzer- und Gruppennamen dürfen
    Leerzeichen enthalten, und ein Symlink endet mit „ -> ziel" — genau
    das darf aber auch ein normaler Dateiname enthalten
    (verifiziert am 2026-09-05 mit bsdtar 3.5.3: „a -> b.txt" und ein
    Symlink darauf sind in der Ausgabe nicht zu unterscheiden). Der
    Zeilenzähler dagegen ist verlässlich: Beide Ausgaben maskieren
    Zeilenumbrüche im Namen, jede Zeile ist genau ein Eintrag.

    Warum das nötig ist: ISO listet Ordner OHNE Schrägstrich, 7z und Tar
    mit. Ein LEERER Ordner in einem ISO war deshalb bis 0.31.3 eine Datei —
    `--only files` zeigte ihn, `--only dirs` nicht. Stimmen die
    Zeilenzahlen nicht überein (raw_verbose None oder anders lang), bleibt
    `is_dir` None; der Aufrufer fällt dann auf die alte Heuristik zurück
    (Schrägstrich am Ende oder Einträge darunter)."""
    raw_lines = raw_stdout.split(b"\n")
    verbose_lines = (None if raw_verbose is None
                     else raw_verbose.split(b"\n"))
    aligned = (verbose_lines is not None
               and len(verbose_lines) == len(raw_lines))
    entries = []
    for index, raw_line in enumerate(raw_lines):
        raw = bsdtar_unescape(raw_line).decode("utf-8", "replace")
        if raw.startswith("./"):
            raw = raw[2:]
        if raw in ("", ".", "./"):
            continue
        is_dir = None
        if aligned:
            mode = verbose_lines[index][:1]
            # Jede Zeile beginnt mit der 10-stelligen Rechtemaske;
            # deren erstes Zeichen ist der Typ (d = Ordner, - = Datei,
            # l = Symlink, ? = unbekannt). Nur ein Ordner ist ein Ordner.
            is_dir = mode == b"d" if mode else None
        entries.append((raw, is_dir))
    return entries


def classify_archive(name):
    """Liefert "zip", "tar", "bsdtar", eine Kompressionsendung (".gz",
    ".bz2", ".xz", ".zst") oder None — je nachdem, ob der Dateiname wie
    ein unterstütztes Archiv aussieht (nur anhand der Endung, damit wir
    nicht jede Datei öffnen müssen). Die Tar-Familie gewinnt gegen die
    Einzelkompression, damit ".tar.gz" als Tar behandelt wird und nicht
    als einzelnes ".gz".

    Die bsdtar- und zstd-Formate zählen nur als Archiv, wenn das jeweilige
    Werkzeug auf dem System gefunden wurde — sonst bleiben diese Dateien
    normale Dateien wie vor der Integration."""
    lowered = name.lower()
    if lowered.endswith(ZIP_EXTENSIONS):
        return "zip"
    if lowered.endswith(TAR_EXTENSIONS):
        return "tar"
    for extension in SINGLE_COMPRESSION_OPENERS:
        if lowered.endswith(extension):
            return extension
    bsdtar, zstd, _ = external_archive_tools()
    # Tar-mit-Zstandard zuerst, und zwar mit eigenem Rückgabepunkt: „.tar.zst"
    # endet auch auf „.zst" und fiele sonst ohne bsdtar in den Roh-.zst-Zweig
    # darunter. Der entpackte Tar-Strom erschiene dann als EIN Mitglied
    # „a.tar" — versprochen ist aber, dass die Datei ohne Werkzeug eine
    # normale Datei bleibt.
    if lowered.endswith(BSDTAR_ZSTD_TAR_EXTENSIONS):
        if bsdtar is not None and zstd is not None:
            return "bsdtar"
        return None
    if bsdtar is not None and lowered.endswith(BSDTAR_NATIVE_EXTENSIONS):
        return "bsdtar"
    if zstd is not None and lowered.endswith(ZSTD_SINGLE_EXTENSION):
        return ZSTD_SINGLE_EXTENSION
    return None


TEXT_ENCODINGS = {
    "utf-8": "utf-8", "utf-16-le": "utf-16-le", "utf-16-be": "utf-16-be",
    "windows-1252": "cp1252", "iso-8859-1": "latin-1", "mac-roman": "mac_roman",
}

class DecoderChoiceError(ArchiveReadError):
    """Die ausdrücklich gewählte Kodierung lässt sich nicht anwenden."""


def decoded_text_chunks(chunks, requested="utf-8", errors="replace", info=None):
    """Ein Decoder für Vortest, Zeilen und Positionsbindung; Budgets zählen Rohbytes."""
    if requested not in TEXT_ENCODINGS and requested != "auto":
        raise DecoderChoiceError("Unbekannte Textkodierung: " + requested)
    chunks = iter(chunks)
    header = b""
    remainder = b""
    encoding = requested
    skipped = 0
    if requested in ("auto", "utf-16-le", "utf-16-be"):
        while len(header) < 4:
            try:
                chunk = next(chunks)
            except StopIteration:
                break
            needed = 4 - len(header)
            header += chunk[:needed]
            remainder = chunk[needed:]
        if requested == "auto":
            if header.startswith((codecs.BOM_UTF32_LE, codecs.BOM_UTF32_BE)):
                raise DecoderChoiceError("UTF-32-BOM wird von dieser Positivliste nicht unterstützt")
            encoding = "utf-8"
            for bom, candidate in ((codecs.BOM_UTF8, "utf-8"),
                                   (codecs.BOM_UTF16_LE, "utf-16-le"),
                                   (codecs.BOM_UTF16_BE, "utf-16-be")):
                if header.startswith(bom):
                    encoding = candidate
                    skipped = len(bom)
                    break
        else:
            own = codecs.BOM_UTF16_LE if requested == "utf-16-le" else codecs.BOM_UTF16_BE
            opposite = codecs.BOM_UTF16_BE if requested == "utf-16-le" else codecs.BOM_UTF16_LE
            if header.startswith(opposite):
                raise DecoderChoiceError("BOM widerspricht ausdrücklich gewählter Byteordnung")
            if header.startswith(own):
                skipped = len(own)
    if info is not None:
        info.update(requested=requested, decoder=encoding, consumedBOMBytes=skipped)
    decoder = codecs.getincrementaldecoder(TEXT_ENCODINGS[encoding])(errors=errors)

    def decode(chunk, final=False):
        if info is None or errors != "replace":
            return decoder.decode(chunk, final=final)
        state = decoder.getstate()
        decoder.errors = "strict"
        try:
            return decoder.decode(chunk, final=final)
        except UnicodeDecodeError:
            info["hadReplacement"] = True
            decoder.setstate(state)
            decoder.errors = "replace"
            return decoder.decode(chunk, final=final)
        finally:
            decoder.errors = errors
    if header:
        text = decode(header[skipped:])
        if text:
            yield text
    if remainder:
        text = decode(remainder)
        if text:
            yield text
    for chunk in chunks:
        text = decode(chunk)
        if text:
            yield text
    text = decode(b"", final=True)
    if text:
        yield text


LinePiece = collections.namedtuple("LinePiece",
                                   "number text complete ends_line")
LinePiece.__doc__ = """Ein Stück Text aus iter_line_pieces() — die Namen
seiner vier Felder.

`number` ist die Zeilennummer (1-basiert). `complete` sagt, ob `text` die
GANZE Zeile ist; ein Bruchstück einer zu langen Zeile hat complete=False —
auch ihr letztes Stück, denn der Anfang der Zeile ist längst weg.
`ends_line` sagt, ob mit diesem Stück die Zeile zu Ende ist (bei einer
vollständigen Zeile immer, bei Bruchstücken nur beim letzten).

Der Generator liefert aus Kostengründen NACKTE Tupel dieser Form, keine
LinePiece-Objekte: 64 MiB in 80-Zeichen-Zeilen sind 840 000 Zeilen, und
ein namedtuple je Zeile kostete gemessen am 2026-09-05 0,14 s auf 0,17 s
Gesamtlauf (`tests/LINE_READER_MEASUREMENTS.md`). Ein Tupel vergleicht
sich gleich mit dem LinePiece derselben Werte; wer Feldnamen will, nimmt
`LinePiece._make(piece)`."""


def iter_line_pieces(chunks, max_line_chars=None, overlap_chars=None,
                     text_encoding="utf-8", decoder_info=None):
    """Liest Byte-Häppchen in der gewählten Kodierung als LinePiece.

    Das ist der Leser der Inhaltssuche, herausgelöst aus match_content()
    (0.32.1, verhaltensneutral — die Tests vergleichen beide Fassungen
    Eingabe für Eingabe). Was er zusagt:

    - Dekodiert wird in der gewählten Textkodierung mit errors="replace", damit die Suche auch
      in „halb-binären" Dateien funktioniert. Der inkrementelle Decoder
      setzt Mehrbyte-Zeichen über Häppchengrenzen hinweg zusammen; das
      Ergebnis ist identisch zum Dekodieren der ganzen Datei am Stück.
    - Zeilen enden an allem, woran str.splitlines() sie beendet
      (LINE_BREAKS). Ein CRLF über eine Häppchengrenze ist EIN Umbruch:
      Ein \r am Häppchenende wartet, ob ein \n folgt.
    - Eine Zeile ohne Umbruch wird nicht vollständig gepuffert
      (MAX_LINE_CHARS): Läuft sie darüber hinaus, kommt der bisherige Text
      als Bruchstück (complete=False), und nur der Schwanz
      (LINE_OVERLAP_CHARS) bleibt für das nächste Stück stehen — damit
      ein Treffer an der Schnittstelle nicht verlorengeht. Die
      Überlappung darf nicht 0 werden: `segment[-0:]` ist in Python der
      GANZE String, die Grenze verschwände lautlos.
    - Die letzte Zeile ohne Umbruch kommt trotzdem, mit ends_line=True —
      auch dann, wenn von ihr schon Bruchstücke gingen und (Überlappung
      0) nichts mehr im Puffer steht: Dann schließt ein leeres Stück die
      Zeile ab, damit ends_line einmal je Zeile wahr ist.

    Die Grenzen werden beim Aufruf aus den Modulkonstanten gelesen (Tests
    setzen sie klein), lassen sich aber auch direkt übergeben."""
    if max_line_chars is None:
        max_line_chars = MAX_LINE_CHARS
    if overlap_chars is None:
        overlap_chars = LINE_OVERLAP_CHARS
    pending = []          # Bruchstücke der noch nicht beendeten Zeile
    pending_chars = 0     # deren Gesamtlänge, ohne sie zusammenzusetzen
    number = 0
    fragmented = False    # von der aktuellen Zeile gingen schon Stücke raus
    # Eine beendete Zeile ist vollständig, wenn nichts von ihr schon als
    # Bruchstück ging — das steht an drei Stellen unten wörtlich gleich,
    # statt in einer Hilfsfunktion: Ein Aufruf je Zeile wäre für den
    # Normalfall (kurze Zeilen) der teuerste Schritt des Lesers.
    for text in decoded_text_chunks(chunks, text_encoding, info=decoder_info):
        if not text:
            continue
        pending.append(text)
        pending_chars += len(text)
        # Steckt in diesem Häppchen überhaupt ein Umbruch? Wenn nicht,
        # gibt es keine fertige Zeile und wir puffern nur weiter — würden
        # wir den wachsenden Puffer bei jedem Häppchen neu zusammensetzen,
        # bekämen Dateien ohne Zeilenumbrüche quadratischen Aufwand.
        # Der \n-Test ist der billige Normalfall; erst wenn er scheitert,
        # kosten die selteneren Umbruchzeichen einen splitlines()-Lauf.
        if "\n" not in text and len(text.splitlines()) == 1 \
                and text[-1] not in LINE_BREAKS:
            if pending_chars > max_line_chars:
                segment = "".join(pending)
                # Im Puffer kann trotzdem ein Zeilenende stecken: ein
                # einzelnes "\r" aus einem früheren Häppchen, das dort
                # wartete, weil ein "\n" daraus ein CRLF machen könnte.
                # DIESES Häppchen hat keinen Umbruch, also wird daraus
                # keines mehr — die Zeilen sind fertig und werden ganz
                # normal gezählt. Ohne diesen Schritt verschwanden sie
                # mit dem Abschnitt, und jede folgende Zeilennummer war
                # um eins zu klein.
                finished = segment.splitlines()
                if len(finished) > 1:
                    for line in finished[:-1]:
                        number += 1
                        yield (number, line, not fragmented, True)
                        fragmented = False
                    segment = finished[-1]
                if len(segment) > max_line_chars:
                    # Die Zeile ist noch nicht zu Ende, aber schon zu
                    # lang. Die Zeilennummer bleibt dieselbe, denn es
                    # ist weiterhin EINE Zeile.
                    yield (number + 1, segment, False, False)
                    fragmented = True
                    # Nicht segment[-overlap_chars:] ohne Prüfung: Bei
                    # einer Überlappung von 0 wäre das segment[0:], also
                    # der GANZE Abschnitt — die Grenze verschwände
                    # lautlos, und genau der Speicherfehler wäre zurück.
                    segment = (segment[-overlap_chars:]
                               if overlap_chars > 0 else "")
                pending = [segment]
                pending_chars = len(segment)
            continue
        buffer = "".join(pending)
        pending.clear()
        pending_chars = 0
        lines = buffer.splitlines()
        if buffer[-1] not in LINE_BREAKS:
            # Die letzte Zeile ist noch offen; sie wird im nächsten
            # Häppchen fortgesetzt.
            rest = lines.pop()
            pending.append(rest)
            pending_chars = len(rest)
        elif buffer.endswith("\r"):
            # Umbruch noch offen: folgt im nächsten Häppchen ein \n,
            # sind beide zusammen EIN Umbruch (CRLF) — sonst zählten
            # wir hier eine Zeile zu viel.
            rest = lines.pop() + "\r"
            pending.append(rest)
            pending_chars = len(rest)
        if fragmented and lines:
            # Nur die ERSTE Zeile dieses Häppchens kann der Rest einer
            # zu langen Zeile sein.
            number += 1
            yield (number, lines[0], False, True)
            fragmented = False
            lines = lines[1:]
        for line in lines:
            number += 1
            yield (number, line, True, True)
    # Rest: die letzte noch offene Zeile. Den Decoder leert iterdecode()
    # selbst — ein angebrochenes Mehrbyte-Zeichen am Dateiende steht dann
    # schon als Ersatzzeichen im Puffer.
    rest = "".join(pending).splitlines()
    if not rest and fragmented:
        # Von der letzten Zeile gingen Stücke, aber kein Rest steht mehr
        # im Puffer (nur bei Überlappung 0). Ohne Abschluss hätte diese
        # Zeile nie ein ends_line=True — der Vertrag oben verspricht es.
        rest = [""]
    for line in rest:
        number += 1
        yield (number, line, not fragmented, True)
        fragmented = False


MAX_NORMALIZATION_CHARS = 64 * 1024


class NormalizationLimit(Exception):
    pass


def normalized_parts(text, final=False):
    text = unicodedata.normalize("NFC", text)
    if final:
        return text, ""
    boundary = max(0, len(text) - 1)
    while boundary > 0 and unicodedata.combining(text[boundary]):
        boundary -= 1
    return text[:boundary], text[boundary:]


def normalized_text_chunks(chunks):
    tail = ""
    for text in chunks:
        prefix, tail = normalized_parts(tail + text)
        if prefix:
            yield prefix
        if len(tail) > MAX_NORMALIZATION_CHARS:
            raise NormalizationLimit()
    if tail:
        yield tail


def iter_matching_pieces(chunks, normalize, text_encoding="utf-8", decoder_info=None):
    """Rohzeilen für Regex/Belege, stabile NFC-Stücke für normale Matcher.

    Die Rohüberlappung darf nicht ein zweites Mal in den NFC-Rest gelangen.
    Eine eigene normalisierte Überlappung erhält Treffer über Stückgrenzen.
    """
    previous = None
    raw_overlap = 0
    tail = overlap = ""
    overflow = False
    for number, raw, complete, ends_line in iter_line_pieces(
            chunks, text_encoding=text_encoding, decoder_info=decoder_info):
        if not normalize or complete:
            yield number, raw, complete, unicodedata.normalize("NFC", raw) if normalize else raw, False
            continue
        if previous != number:
            previous = number
            raw_overlap = 0
            tail = overlap = ""
            overflow = False
        unique = raw[raw_overlap:]
        raw_overlap = min(len(raw), LINE_OVERLAP_CHARS)
        if overflow:
            yield number, raw, False, None, True
            continue
        prefix, tail = normalized_parts(tail + unique, final=ends_line)
        window = overlap + prefix
        overlap = window[-LINE_OVERLAP_CHARS:] if LINE_OVERLAP_CHARS else ""
        overflow = len(tail) > MAX_NORMALIZATION_CHARS
        yield number, raw, False, window, overflow


def match_content_piece(matcher, raw, complete, normalized, uncertain):
    if not complete and not getattr(matcher, "substring_only", False):
        return None
    canonical = getattr(matcher, "canonical_matcher", None)
    if canonical is None:
        return bool(matcher(raw))
    if normalized is None:
        return None
    matched = bool(canonical(normalized))
    return None if not matched and uncertain else matched


class ContentProbe:
    """Schneller Vortest für die Inhaltssuche: Kommt der Suchtext überhaupt vor?

    Der genaue Weg (`match_content`) zerlegt jeden Inhalt in Zeilen und prüft
    jede einzeln — nur so lässt sich die Zeilennummer eines Treffers ausgeben.
    Das Zerlegen und die Schleife über die Zeilen kosten den Großteil der
    Suchzeit, obwohl die allermeisten Dateien den Suchtext gar nicht enthalten
    (gemessen am 2026-07-28 auf 72,8 MB Text: 0,56 s gesamt, davon 0,07 s
    Lesen und 0,13 s Dekodieren — der Rest ist die Arbeit pro Zeile).

    Dieser Vortest sucht deshalb im ganzen Häppchen auf einmal, also mit einem
    einzigen Aufruf in C statt einer Schleife in Python, und liefert nur ein
    Ja/Nein. Erst bei Ja liest der Aufrufer denselben Inhalt ein zweites Mal
    und bestimmt die Zeilennummer genau.

    Warum das keinen Treffer verschluckt: Jede Zeile ist ein Teilstück des
    gesamten Inhalts. Enthält eine Zeile den Suchtext, enthält ihn der Inhalt
    zwangsläufig auch. Umgekehrt darf der Vortest ruhig einmal zu viel „ja"
    sagen — etwa wenn der Suchtext über einen Zeilenumbruch hinweg steht.
    Diesen Fall verwirft dann der genaue Lauf.
    """

    def __init__(self, needle, case_sensitive, text_encoding="utf-8"):
        self.text_encoding = text_encoding
        # `needle` ist EIN Suchtext oder eine Liste (Mehrwortsuche, --term):
        # Dann müssen ALLE vorkommen, geprüft in demselben Durchlauf — der
        # Inhalt wird nicht je Begriff neu gelesen.
        needles = [needle] if isinstance(needle, str) else list(needle)
        # Bei egaler Groß-/Kleinschreibung vergleichen wir kleingeschrieben —
        # genau wie der Matcher aus build_matcher() es pro Zeile tut.
        needles = [unicodedata.normalize("NFC", text) for text in needles]
        needles = [text if case_sensitive else text.lower()
                   for text in needles]
        # str.lower() hängt an genau EINER Stelle vom Zusammenhang ab: Ein
        # großes Sigma wird am Wortende zu „ς", sonst zu „σ". Der Vortest sieht
        # Häppchen, der genaue Lauf ganze Zeilen — dieselbe Stelle kann deshalb
        # unterschiedlich herauskommen, und der Vortest würde einen echten
        # Treffer verschlucken (verifiziert am 2026-08-03 mit „ΟΣ" an der
        # Häppchengrenze). Enthält der Suchtext ein Sigma, gleicht der Vortest
        # deshalb beide Formen an. Er sagt dadurch höchstens einmal zu oft
        # „ja"; das ist erlaubt, „nein" zu Unrecht dagegen nicht. Ohne Sigma im
        # Suchtext kann es den Unterschied nicht geben — dann bleibt der heiße
        # Pfad unverändert.
        self.fold_sigma = not case_sensitive and any(
            char in text for text in needles for char in GREEK_SIGMAS)
        if self.fold_sigma:
            needles = [text.replace(GREEK_FINAL_SIGMA, GREEK_SMALL_SIGMA)
                       for text in needles]
        self.needles = needles
        self.case_sensitive = case_sensitive

    def hits(self, chunks):
        """True, wenn der Suchtext in den Häppchen vorkommt.

        Dekodiert wird wie in `match_content` in der gewählten Textkodierung mit
        errors="replace" — beide sehen also denselben Text."""
        # Der Suchtext kann genau auf einer Häppchengrenze liegen. Deshalb
        # wandert das Ende des bisher Gesehenen (Suchtextlänge minus ein
        # Zeichen) vorne an das nächste Häppchen. Wichtig: Das Fenster wird
        # aus carry UND Häppchen gebildet, nicht nur aus dem Häppchen —
        # sonst reicht es bei sehr kleinen Häppchen nicht über den Suchtext.
        overlap = max(0, max(len(text) for text in self.needles) - 1)
        remaining = list(self.needles)
        carry = ""
        try:
            decoded = decoded_text_chunks(chunks, self.text_encoding)
            for text in normalized_text_chunks(decoded):
                if not self.case_sensitive:
                    text = text.lower()
                    if self.fold_sigma:
                        text = text.replace(GREEK_FINAL_SIGMA, GREEK_SMALL_SIGMA)
                window = carry + text
                for needle in remaining[:]:
                    if needle in window:
                        remaining.remove(needle)
                if not remaining:
                    return True
                carry = window[-overlap:] if overlap else ""
        except NormalizationLimit:
            return True  # Der Vortest darf bei einem begrenzten Rest nur offenlassen.
        return False


def build_content_probe(pattern, use_regex, case_sensitive, literal_wildcards=False,
                        text_wildcards=False, text_encoding="utf-8"):
    """Baut den Vortest für die Inhaltssuche — oder None, wenn keiner möglich
    ist.

    Möglich ist er nur, wenn wir einen festen Suchtext kennen. --regex und
    Namens-Globs bleiben beim genauen Lauf. Bei Text-Sternmustern können
    dagegen alle festen Teile geprobt werden; Reihenfolge und Zeilengrenzen
    prüft weiterhin der genaue Lauf.
    `--exact` ist dagegen unkritisch: Dort muss die ganze Zeile dem Muster
    entsprechen, der Suchtext kommt also erst recht vor.

    `pattern` darf eine Liste sein (Mehrwortsuche): Geprobt werden dann alle
    Begriffe OHNE Platzhalter; schon einer, der fehlt, ist ein sicheres
    Nein. Begriffe mit Platzhaltern bleiben dem genauen Lauf überlassen."""
    patterns = [pattern] if isinstance(pattern, str) else list(pattern)
    if text_wildcards and not literal_wildcards:
        # Jeder feste Teil muss vorkommen; Reihenfolge und Zeilengrenzen
        # prüft erst der genaue Lauf. Leere Teile stellen keine Bedingung.
        fixed = list(dict.fromkeys(part for text in patterns
                                   for part in re.split(r"\*+", text) if part))
    else:
        fixed = [text for text in patterns
                 if literal_wildcards or not any(char in text for char in "*?[")]
    if use_regex or not fixed:
        return None
    return ContentProbe(fixed, case_sensitive, text_encoding)


def build_matcher(pattern, use_regex, case_sensitive, exact=False,
                  literal_wildcards=False, text_wildcards=False):
    if use_regex:
        matcher = _build_matcher(pattern, True, case_sensitive, exact, literal_wildcards, text_wildcards)
        matcher.preview_spec = (pattern, True, case_sensitive, exact, literal_wildcards, text_wildcards)
        return matcher
    pattern = unicodedata.normalize("NFC", pattern)
    canonical = _build_matcher(pattern, False, case_sensitive, exact, literal_wildcards, text_wildcards)
    def matcher(text):
        return canonical(unicodedata.normalize("NFC", text))
    matcher.canonical_matcher = canonical
    matcher.preview_spec = (pattern, False, case_sensitive, exact, literal_wildcards, text_wildcards)
    if getattr(canonical, "substring_only", False):
        matcher.substring_only = True
    return matcher


MAX_PREVIEW_SNIPPETS = 32
MAX_PREVIEW_SNIPPET_CHARS = 256
MAX_PREVIEW_HIT_CHARS = 2048
MAX_PREVIEW_MAPPING_CHARS = 65536
MAX_PREVIEW_TOTAL_BYTES = 8 * 1024 * 1024
PREVIEW_CONTEXT_CHARS = 48
PREVIEW_CAPTURE_SECONDS = 0.1


def source_generation(path=None, status=None):
    try:
        status = os.stat(path) if status is None else status
    except OSError:
        return None
    return dict(device=str(status.st_dev), inode=str(status.st_ino),
                size=str(status.st_size), modifiedNS=str(status.st_mtime_ns),
                changedNS=str(status.st_ctime_ns))


def original_normalized_span(raw, canonical, start, end):
    # NFD trägt die Herkunft auch über kanonische Umordnung und Hangul hinweg.
    # Präfix-NFC je Zeichen wäre quadratisch; dieser Weg bleibt begrenzt linear/loglinear.
    mapped, tail = [], []
    for index, char in enumerate(raw):
        for part in unicodedata.normalize("NFD", char):
            if unicodedata.combining(part):
                tail.append((part, index))
            else:
                mapped.extend(sorted(tail, key=lambda item: unicodedata.combining(item[0])))
                tail.clear()
                mapped.append((part, index))
    mapped.extend(sorted(tail, key=lambda item: unicodedata.combining(item[0])))
    left = len(unicodedata.normalize("NFD", canonical[:start]))
    right = len(unicodedata.normalize("NFD", canonical[:end]))
    if left == right:
        point = mapped[left][1] if left < len(mapped) else len(raw)
        return point, point
    origins = [item[1] for item in mapped[left:right]]
    return (min(origins), max(origins) + 1) if origins else None


def preview_match_span(matcher, raw, after=0):
    spec = getattr(matcher, "preview_spec", None)
    if spec is None or len(raw) > MAX_PREVIEW_MAPPING_CHARS:
        return None
    pattern, regex, sensitive, exact, literal, wildcards = spec
    if regex:
        compiled = re.compile(pattern, 0 if sensitive else re.IGNORECASE)
        match = (compiled.fullmatch(raw) if after == 0 else None) if exact else compiled.search(raw, after)
        return None if match is None else match.span()
    canonical = unicodedata.normalize("NFC", raw)
    target = canonical if sensitive else canonical.lower()
    needle = pattern if sensitive else pattern.lower()
    prefix = unicodedata.normalize("NFC", raw[:after])
    offset = len(prefix if sensitive else prefix.lower())
    if exact and after:
        return None
    if wildcards and not literal and "*" in needle:
        parts = re.split(r"\*+", needle)
        start = 0 if exact and target.startswith(parts[0]) else target.find(parts[0], offset)
        if start < 0 or (exact and start != 0):
            return None
        end = start + len(parts[0])
        for index, part in enumerate(parts[1:], 1):
            position = (len(target) - len(part) if exact and index == len(parts) - 1
                        else target.find(part, end + 1))
            if position < end + 1 or not target.startswith(part, position):
                return None
            end = position + len(part)
    elif exact:
        if target != needle:
            return None
        start, end = 0, len(target)
    elif not literal and not wildcards and any(char in needle for char in "*?["):
        match = re.compile(fnmatch.translate(pattern), 0 if sensitive else re.IGNORECASE).match(canonical)
        if match is None:
            return None
        start, end = match.span()
        sensitive = True
    else:
        start = target.find(needle, offset)
        if start < 0:
            return None
        end = start + len(needle)
    if not sensitive:
        origins = [index for index, char in enumerate(canonical) for _ in char.lower()]
        if len(origins) != len(target):
            return None
        if start == end:
            start = end = origins[start] if start < len(origins) else len(canonical)
        else:
            start, end = origins[start], origins[end - 1] + 1
    if canonical == raw:
        return start, end
    return original_normalized_span(raw, canonical, start, end)


def content_snippet(number, raw, complete, span, limit=MAX_PREVIEW_SNIPPET_CHARS, context=PREVIEW_CONTEXT_CHARS):
    start, end = span if span is not None else (0, 0)
    left = max(0, start - context)
    right = min(len(raw), left + limit, max(start + 1, end) + context)
    text = raw[left:right]
    binding = "excerptUTF16" if span is not None else "unavailable"
    snippet = dict(line=number, text=text, positionBinding=binding,
                   prefixTruncated=left > 0 or not complete,
                   suffixTruncated=right < len(raw) or not complete,
                   excerptSHA256=hashlib.sha256(text.encode("utf-8")).hexdigest())
    if span is not None:
        snippet.update(location=len(raw[left:start].encode("utf-16-le")) // 2,
                       length=len(raw[start:min(end, right)].encode("utf-16-le")) // 2,
                       matchTruncated=end > right)
    return snippet


class ContentPreviewCapture:
    def __init__(self, probe):
        self.probe = probe
        self.snippets = {}
        self.chars = 0
        self.spent = 0.0
        self.changed = False

    def record(self, matcher, number, raw, complete):
        if matcher in self.snippets:
            return
        if len(self.snippets) >= MAX_PREVIEW_SNIPPETS or self.chars >= MAX_PREVIEW_HIT_CHARS \
                or self.spent >= PREVIEW_CAPTURE_SECONDS:
            return
        started = time.monotonic()
        span = preview_match_span(matcher, raw)
        limit = min(MAX_PREVIEW_SNIPPET_CHARS, MAX_PREVIEW_HIT_CHARS - self.chars)
        snippet = content_snippet(number, raw, complete, span, limit)
        position = getattr(self.probe, "document_position", None)
        if position is not None:
            snippet["documentPosition"] = position
        self.snippets[matcher] = snippet
        self.chars += len(snippet["text"])
        self.spent += time.monotonic() - started

    def finish(self):
        probe = self.probe
        search = probe.search
        expected = probe.preview_generation
        wanted = []
        if search.text_mode == "content":
            wanted.extend((matcher, {"termIndex": index + 1, "label": json_safe_text(term[:128])})
                          for index, (matcher, term) in enumerate(zip(search.matchers, search.terms)))
        evidence = {item["id"] for item in probe.criteria_evidence or []
                    if item.get("field") == "content" and not item.get("negated")}
        if search.criteria_query is not None:
            wanted.extend((condition.matcher, {"criterionID": condition.identifier,
                                               "label": json_safe_text(condition.value[:128])})
                          for condition in search.criteria_query.conditions
                          if isinstance(condition, ContentCondition) and condition.identifier in evidence)
        if not wanted:
            return dict(schemaVersion=1, status="noContentEvidence", snippets=[], omitted=0)
        if self.changed or expected is None or source_generation(probe.filesystem_path) != expected:
            return dict(schemaVersion=1, status="sourceChanged", snippets=[], omitted=len(wanted))
        snippets = []
        for matcher, identity in wanted[:MAX_PREVIEW_SNIPPETS]:
            if matcher in self.snippets:
                snippet = dict(self.snippets[matcher], **identity)
                spec = matcher.preview_spec
                if not any(0xD800 <= ord(char) <= 0xDFFF for char in spec[0]):
                    snippet["query"] = dict(pattern=spec[0], regex=spec[1], caseSensitive=spec[2],
                                           exact=spec[3], literalWildcards=spec[4], encoding=search.text_encoding)
                    if search.document_mode:
                        snippet["query"]["documentReader"] = next(reader for reader, encoding in DOCUMENT_READERS.items() if encoding == probe.decoder_info.get("decoder"))
                if probe.decoder_info.get("hadReplacement"):
                    snippet["positionBinding"] = "invalidDecoding"
                    snippet.pop("location", None)
                    snippet.pop("length", None)
                snippets.append(snippet)
        return dict(schemaVersion=1, status="ready" if snippets else "noContentEvidence",
                    sourceGeneration=expected, contentEncoding=probe.decoder_info.get("decoder"),
                    snippets=snippets, omitted=max(0, len(wanted) - len(snippets)),
                    archiveLimits=dict(memberBytes=min(search.archive_budget.maximum_member, DEFAULT_MAX_ARCHIVE_MEMBER_BYTES),
                                       totalBytes=min(search.archive_budget.maximum_total, DEFAULT_MAX_ARCHIVE_TOTAL_BYTES),
                                       ratio=min(search.archive_budget.maximum_ratio, DEFAULT_MAX_ARCHIVE_RATIO)))



PREVIEW_LOAD_BYTES = 64 * 1024 * 1024
PREVIEW_LOAD_SECONDS = 3.0
PREVIEW_REQUEST_BYTES = 128 * 1024


class PreviewLoadLimit(Exception):
    pass


def load_content_preview(request, local_only=False):
    """Gezieltes Wiederlesen eines bereits gewählten Blatts, keine Suche im Baum.

    Die Fortsetzungsmarke ist eine Fundnummer pro Muster/Quellengeneration.
    Sie ist kein Byteoffset: Auch Decoder und künftige Dokumentleser können
    denselben Vertrag bedienen. Wiederlesen bleibt pro Auftrag gedeckelt.
    """
    if not isinstance(request, dict) or type(request.get("schemaVersion")) is not int or request["schemaVersion"] != 1:
        raise ValueError("Nachladeauftrag braucht Schema 1")
    hit = request.get("hit")
    if not isinstance(hit, dict) or not isinstance(hit.get("filesystemPath"), str) \
            or not isinstance(hit.get("archiveMembers"), list) or hit.get("isDirectory") is not False:
        raise ValueError("ungültige Trefferidentität")
    preview = hit.get("contentPreview")
    if not isinstance(preview, dict) or preview.get("status") != "ready":
        raise ValueError("kein positiver Vorschaubeleg")
    snippets = preview.get("snippets")
    if not isinstance(snippets, list) or len(snippets) > 32:
        raise ValueError("ungültige Belegliste")
    index = request.get("queryIndex")
    occurrence = request.get("occurrence")
    if type(index) is not int or not 0 <= index < len(snippets) \
            or type(occurrence) is not int or not 0 <= occurrence <= 1000000:
        raise ValueError("ungültige Fundnummer oder Inhaltsbedingung")
    original = snippets[index]
    if not isinstance(original, dict):
        raise ValueError("ungültiger Inhaltsbeleg")
    query = original.get("query")
    if not isinstance(query, dict):
        raise ValueError("Mustervertrag fehlt")
    pattern = query.get("pattern")
    if not isinstance(pattern, str) or not pattern or len(pattern) > 65536:
        raise ValueError("kein fortsetzbarer positiver Inhaltsbeleg")
    for key in ("regex", "caseSensitive", "exact", "literalWildcards"):
        if type(query.get(key)) is not bool:
            raise ValueError("ungültige Musteroption")
    encoding = preview.get("contentEncoding")
    document_reader = query.get("documentReader")
    document = document_reader in DOCUMENT_READERS
    if query.get("documentReader") is not None and not document:
        raise ValueError("unbekannter Dokumentleser")
    if not isinstance(encoding, str) or (encoding != DOCUMENT_READERS[document_reader] if document else encoding not in TEXT_ENCODINGS):
        raise ValueError("ungültiger tatsächlicher Decoder")
    requested_encoding = query.get("encoding", encoding)
    if not isinstance(requested_encoding, str) or (requested_encoding not in TEXT_ENCODINGS and requested_encoding != "auto"):
        raise ValueError("ungültige angeforderte Kodierung")
    path = request.get("filePath")
    if not isinstance(path, str) or not path:
        raise ValueError("Blattdatei fehlt")
    expected = preview.get("sourceGeneration")
    leaf_expected = request.get("fileGeneration")
    if not isinstance(expected, dict) or not isinstance(leaf_expected, dict):
        raise ValueError("Quellengeneration fehlt")
    if not hit["archiveMembers"] and os.path.abspath(path) != os.path.abspath(hit["filesystemPath"]):
        raise ValueError("Blattdatei passt nicht zum Treffer")
    matcher = build_matcher(pattern, query["regex"], query["caseSensitive"],
                            query["exact"], query["literalWildcards"], True)
    result = dict(hit)
    state = dict(queryIndex=index, occurrence=occurrence, reason="end", contextLines=[])
    updated = dict(schemaVersion=1, status="ready", sourceGeneration=expected,
                   contentEncoding=encoding, snippets=[], omitted=0, navigation=state)
    result["contentPreview"] = updated
    def unchanged():
        return source_generation(hit["filesystemPath"]) == expected and source_generation(path) == leaf_expected
    def changed():
        updated.update(status="sourceChanged", snippets=[])
        state.update(reason="sourceChanged", contextLines=[])
    if local_only:
        reason = local_content_reason(hit["filesystemPath"]) or local_content_reason(path)
        if reason is not None:
            updated.update(status="noContentEvidence", snippets=[])
            state.update(reason="documentUnavailable", documentMessage=REPORT_REASONS[reason][1])
            return result
    if not unchanged():
        changed()
        return result
    deadline = time.monotonic() + PREVIEW_LOAD_SECONDS
    read_bytes = 0
    info = {}
    context = request.get("context") is True
    before = []
    found = None
    count = 0
    last_line, base, previous_length, last_end = None, 0, 0, -1
    overlap = min(32768, max(1024, len(pattern) * 3))
    def context_line(number, raw, complete, position=None):
        text = raw[:256]
        item = dict(line=number, text=text, truncated=len(raw) > 256 or not complete,
                    excerptSHA256=hashlib.sha256(text.encode("utf-8")).hexdigest())
        if position is not None:
            item["documentPosition"] = position
        return item
    def chunks(handle):
        nonlocal read_bytes
        while True:
            if time.monotonic() >= deadline or read_bytes >= PREVIEW_LOAD_BYTES:
                raise PreviewLoadLimit()
            chunk = handle.read(min(8192, PREVIEW_LOAD_BYTES - read_bytes))
            if not chunk:
                return
            read_bytes += len(chunk)
            yield chunk
    alarm_handler = signal.getsignal(signal.SIGALRM)
    alarm_timer = signal.getitimer(signal.ITIMER_REAL)
    def expired(signum, frame):
        raise PreviewLoadLimit()
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, max(0.001, PREVIEW_LOAD_SECONDS))
    reader = None
    pieces = None
    try:
        with open_regular_file(path) as handle:
            if source_generation(status=os.fstat(handle.fileno())) != leaf_expected:
                changed()
                return result
            # Reine Enthält-Muster können auch minifizierte Zeilen stückweise
            # belegen. Verankerte Muster behalten die Grenzen der normalen Suche.
            substring = getattr(matcher, "substring_only", False)
            options = dict(max_line_chars=32768 if substring else None,
                           overlap_chars=overlap if substring else None)
            if document:
                read_bytes = os.fstat(handle.fileno()).st_size
                if read_bytes > DOCUMENT_BYTES:
                    raise PreviewLoadLimit()
                if document_reader in PACKAGE_QUERY_READERS:
                    limits = preview.get("archiveLimits", {})
                    if not isinstance(limits, dict) or any(type(limits.get(key, default)) not in (int, float) or
                            not math.isfinite(limits.get(key, default)) or limits.get(key, default) <= 0
                            for key, default in (("memberBytes", DEFAULT_MAX_ARCHIVE_MEMBER_BYTES),
                                                 ("totalBytes", DEFAULT_MAX_ARCHIVE_TOTAL_BYTES),
                                                 ("ratio", DEFAULT_MAX_ARCHIVE_RATIO))):
                        raise ValueError("ungültige Archivgrenzen")
                    reader = PACKAGE_QUERY_READERS[document_reader](ArchiveBudget(
                        min(DEFAULT_MAX_ARCHIVE_MEMBER_BYTES, limits.get("memberBytes", DEFAULT_MAX_ARCHIVE_MEMBER_BYTES)),
                        min(DEFAULT_MAX_ARCHIVE_TOTAL_BYTES, limits.get("totalBytes", DEFAULT_MAX_ARCHIVE_TOTAL_BYTES)),
                        min(DEFAULT_MAX_ARCHIVE_RATIO, limits.get("ratio", DEFAULT_MAX_ARCHIVE_RATIO))))
                elif document_reader == "pdfkit-vision-v1":
                    reader = PDFOCRTextReader(find_pdf_helper())
                elif document_reader == "vision-image-v1":
                    reader = OCRTextReader(find_ocr_helper())
                else:
                    reader = PDFTextReader(find_pdf_helper())
                pieces = document_line_pieces(reader, path, deadline, **options)
                info["decoder"] = encoding
            else:
                pieces = ((number, raw, complete, ends_line, None) for number, raw, complete, ends_line in
                    iter_line_pieces(chunks(handle), text_encoding=requested_encoding, decoder_info=info, **options))
            for number, raw, complete, ends_line, position in pieces:
                if time.monotonic() >= deadline:
                    raise PreviewLoadLimit()
                if found is not None:
                    if number != found["line"] and len(state["contextLines"]) < 6:
                        state["contextLines"].append(context_line(number, raw, complete, position))
                    if len(state["contextLines"]) >= len(before) + 3:
                        break
                    continue
                if last_line != number:
                    base, last_end = 0, -1
                else:
                    base += previous_length - min(previous_length, overlap if substring else LINE_OVERLAP_CHARS)
                last_line, previous_length = number, len(raw)
                if (not complete and not substring) or len(raw) > MAX_PREVIEW_MAPPING_CHARS:
                    state["reason"] = "positionLimit"
                    break
                stable_end = len(raw)
                if substring and not ends_line:
                    canonical = unicodedata.normalize("NFC", raw)
                    prefix, tail = normalized_parts(raw)
                    stable_end = (len(prefix) if canonical == raw else
                                  original_normalized_span(raw, canonical, len(prefix), len(canonical))[0])
                after = 0
                while after <= len(raw):
                    if time.monotonic() >= deadline:
                        raise PreviewLoadLimit()
                    span = preview_match_span(matcher, raw, after)
                    if span is None:
                        break
                    start, end = span
                    if end > stable_end:
                        break
                    after = max(end, start + 1)
                    if base + start < last_end:
                        continue
                    last_end = base + max(end, start + 1)
                    if count < occurrence:
                        count += 1
                        continue
                    found = dict(original, **content_snippet(number, raw, complete, span,
                                                               context=120 if context else PREVIEW_CONTEXT_CHARS))
                    if position is not None:
                        found["documentPosition"] = position
                    updated["snippets"] = [found]
                    state["reason"] = "ready"
                    if context:
                        state["contextLines"] = list(before)
                    break
                if found is not None and not context:
                    break
                if found is None and len(raw) - stable_end > overlap:
                    state["reason"] = "positionLimit"
                    break
                if found is None and ends_line:
                    before.append(context_line(number, raw, complete, position))
                    before = before[-3:]
            if source_generation(status=os.fstat(handle.fileno())) != leaf_expected:
                changed()
    except PreviewLoadLimit:
        state["reason"] = "readLimit"
    except ArchiveLimitError:
        state.update(reason="documentUnavailable", documentReason="documentLimit", documentMessage=REPORT_REASONS["documentLimit"][1])
    except DocumentReadError as err:
        if err.reason == "documentSourceChanged":
            changed()
        else:
            state.update(reason="documentUnavailable", documentReason=err.reason, documentMessage=str(err))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        if pieces is not None:
            pieces.close()
        if isinstance(reader, PDFTextReader):
            reader.close()
        signal.signal(signal.SIGALRM, alarm_handler)
        signal.setitimer(signal.ITIMER_REAL, *alarm_timer)
    state["readBytes"] = read_bytes
    if info.get("decoder", encoding) != encoding:
        raise ValueError("Decoder stimmt nicht mehr mit dem Beleg überein")
    if info.get("hadReplacement") and found is not None:
        found["positionBinding"] = "invalidDecoding"
        found.pop("location", None); found.pop("length", None)
    if not unchanged():
        changed()
    # Ein leeres Ergebnis ist keine neue Trefferentscheidung. Es meldet nur
    # das Ende/die Grenze des angeforderten Belegstroms.
    if not updated["snippets"] and updated["status"] == "ready":
        updated["status"] = "noContentEvidence"
    return result

def _build_matcher(pattern, use_regex, case_sensitive, exact=False,
                   literal_wildcards=False, text_wildcards=False):
    """Baut den Matcher: Regex, Namens-Glob oder Text mit Sternplatzhaltern.

    Inhalt und Metadaten suchen * wie fastra innerhalb einer Zeile
    (mindestens ein Zeichen); andere Sonderzeichen sind wörtlich.
    Namen behalten Ganznamen-Globs. --literal-wildcards unterdrückt beide
    Platzhalterarten. --exact verlangt immer das gesamte Ziel.
    """
    flags = 0 if case_sensitive else re.IGNORECASE

    if use_regex:
        # Ungültige Regexes fängt main() ab und meldet sie als Fehler.
        compiled = re.compile(pattern, flags)
        if exact:
            return lambda text: compiled.fullmatch(text) is not None
        return lambda text: compiled.search(text) is not None

    if text_wildcards and not literal_wildcards and "*" in pattern:
        parts = re.split(r"\*+", pattern if case_sensitive else pattern.lower())

        def matches_line(text):
            # Früheste feste Teile lassen für alle folgenden Teile den
            # größten Rest frei. str.find läuft in C; kein Regex-Backtracking
            # bei langen Abständen oder einem fehlenden letzten Teil.
            if exact:
                if not text.startswith(parts[0]):
                    return False
                position = len(parts[0])
            else:
                start = text.find(parts[0])
                if start < 0:
                    return False
                position = start + len(parts[0])
            for index, part in enumerate(parts[1:], 1):
                if exact and index == len(parts) - 1:
                    start = len(text) - len(part)
                    return start >= position + 1 and text.endswith(part)
                start = text.find(part, position + 1)
                if start < 0:
                    return False
                position = start + len(part)
            return True

        def wildcard_matcher(text):
            if not case_sensitive:
                text = text.lower()
            if exact:
                return (not text or (len(text.splitlines()) == 1
                                     and text[-1] not in LINE_BREAKS)) and matches_line(text)
            return any(matches_line(line) for line in text.splitlines())

        return wildcard_matcher

    if not literal_wildcards and not text_wildcards and any(char in pattern for char in "*?["):
        # fnmatch.translate macht aus dem Glob-Muster einen Regex,
        # der den kompletten String matchen muss.
        compiled = re.compile(fnmatch.translate(pattern), flags)
        return lambda text: compiled.match(text) is not None

    if exact:
        if case_sensitive:
            return lambda text: text == pattern
        lowered_exact = pattern.lower()
        return lambda text: text.lower() == lowered_exact

    # Nur der reine „enthält"-Test darf auf einem BRUCHSTÜCK einer Zeile
    # laufen (siehe match_content und MAX_LINE_CHARS): Ein Teilstring bleibt
    # ein Teilstring, egal wo die Zeile zerschnitten wird. Bei --regex, bei
    # Glob-Mustern und bei --exact gilt das nicht — sie sind am Zeilenanfang
    # oder -ende verankert und träfen auf einem Bruchstück falsch.
    if case_sensitive:
        matcher = lambda text: pattern in text        # noqa: E731
    else:
        lowered_pattern = pattern.lower()
        matcher = lambda text: lowered_pattern in text.lower()  # noqa: E731
    matcher.substring_only = True
    return matcher


class FavenioArgumentParser(argparse.ArgumentParser):
    """Auch argparse-Fehler tragen das gemeinsame stderr-Präfix der Apps.

    Die normale Usage bleibt für die CLI erhalten. Den konkreten Grund
    lesen beide Frontends über SearchDiagnostics aus der folgenden Zeile."""

    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(2, "favenio: fehler: %s\n" % message)


def byte_size(value):
    """Ganze nichtnegative Bytezahl; Binäreinheiten sind ausdrücklich benannt."""
    match = re.fullmatch(r"([0-9]+)\s*(B|KiB|MiB|GiB|TiB)?", value.strip())
    if match is None:
        raise argparse.ArgumentTypeError(
            "erwartet eine ganze Zahl ab 0 in Bytes, optional B/KiB/MiB/GiB/TiB "
            "(z. B. 2048 oder '2 KiB')")
    multipliers = {None: 1, "B": 1, "KiB": 1024, "MiB": 1024 ** 2,
                   "GiB": 1024 ** 3, "TiB": 1024 ** 4}
    try:
        return int(match.group(1)) * multipliers[match.group(2)]
    except ValueError:
        # Neuere Python-Versionen begrenzen die Länge gelesener Ganzzahlen.
        raise argparse.ArgumentTypeError("Bytezahl ist zu lang") from None


def file_timestamp(value):
    """ISO-Zeitpunkt mit ausdrücklicher Zone; keine implizite lokale Uhrzeit."""
    text = value.strip()
    syntax = (r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}"
              r"(?::[0-9]{2}(?:\.[0-9]{1,6})?)?"
              r"(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])")
    try:
        if re.fullmatch(syntax, text) is None:
            raise ValueError("Zeitformat")
        # Python 3.9 liest nur drei oder sechs Bruchstellen und versteht
        # +00:00, aber noch kein abschließendes Z. Nach der Syntaxprüfung
        # sind fehlende Bruchstellen eindeutig Nullen, keine Rundung.
        text = re.sub(r"\.([0-9]+)",
                      lambda match: "." + match.group(1).ljust(6, "0"), text)
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return parsed.timestamp()
    except (ValueError, OverflowError):
        raise argparse.ArgumentTypeError(
            "erwartet einen gültigen ISO-Zeitpunkt mit Z oder Offset "
            "(z. B. 2024-01-01T00:00:00Z oder 2024-01-01T01:00+01:00); "
            "ein Datum ohne Uhrzeit/Zone reicht nicht") from None


def file_timestamp_end(value):
    """Obergrenze eines Zeitfilters (--modified-to, --created-to).

    Die Grenze ist inklusive, und zwar so genau, wie sie genannt wurde:
    Ohne Sekundenbruchteile gehört die ganze genannte Sekunde dazu, ohne
    Sekunden die ganze Minute. Eine Datei mit Änderungszeit 23:59:59,7
    fiel bis 0.34.0 aus `--modified-to …T23:59:59Z` heraus, obwohl die
    Hilfe „inklusive" verspricht — Dateisysteme führen Bruchteile, der
    Nutzer nennt sie nicht. Mit genannten Bruchteilen gilt der Zeitpunkt
    genau."""
    stamp = file_timestamp(value)
    text = value.strip()
    clock = text[11:]                  # hinter dem T: Uhrzeit samt Zone
    if "." in clock:
        return stamp                   # Bruchteile genannt: genau so
    # Die Zone trägt selbst einen Doppelpunkt (+01:00); die Uhrzeit hat
    # dann mit Sekunden drei, ohne zwei. Mit „Z" ist es einer weniger.
    zone_colons = 0 if clock.endswith("Z") else 1
    has_seconds = clock.count(":") - zone_colons >= 2
    # Dateisysteme können feiner als Mikrosekunden auflösen. Eine feste
    # .999999-Grenze verlöre deren letzte Werte: genau vor der Folgegrenze
    # endet stattdessen das inklusive Intervall.
    return math.nextafter(stamp + (1 if has_seconds else 60), -math.inf)


DATE_RANGE_BYTES = 65536
DATE_PRESETS = ("today", "last7CalendarDays", "thisMonth")


def date_json(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("doppeltes JSON-Feld: " + key)
            result[key] = value
        return result
    if not isinstance(text, str) or len(text.encode("utf-8")) > DATE_RANGE_BYTES:
        raise ValueError("Datumsauftrag überschreitet 64 KiB")
    return json.loads(text, object_pairs_hook=unique)


class DateRangeResolver:
    """Ein expliziter Laufzeitpunkt für alle Kalenderbereiche eines Auftrags."""

    def __init__(self, reference_time=None, frozen=None):
        if reference_time is not None and not isinstance(reference_time, str):
            raise ValueError("Laufzeitpunkt muss ein ISO-Text sein")
        if reference_time is not None and reference_time != reference_time.strip():
            raise ValueError("Laufzeitpunkt braucht ISO-Text ohne Rand-Leerraum")
        self.reference = None if reference_time is None else file_timestamp(reference_time)
        self.reference_input = reference_time
        self.entries = []
        self.frozen = None if frozen is None else self.read_frozen(date_json(frozen))

    @staticmethod
    def same_instant(value, expected):
        return (type(value) in (int, float) and math.isfinite(value)
                and abs(value - expected) <= max(math.ulp(value), math.ulp(expected)))

    def read_frozen(self, value):
        if (not isinstance(value, dict) or set(value) != {"schemaVersion", "referenceInput", "referenceTime", "referenceISO", "entries"}
                or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
                or value["referenceInput"] != self.reference_input
                or not isinstance(value["entries"], list) or not 1 <= len(value["entries"]) <= 130):
            raise ValueError("eingefrorener Datumsbeleg passt nicht zum Laufzeitpunkt oder Schema")
        if len(json.dumps(value).encode("utf-8")) > DATE_RANGE_BYTES:
            raise ValueError("eingefrorener Datumsbeleg überschreitet 64 KiB")
        if self.reference is None:
            if value["referenceTime"] is not None or value["referenceISO"] is not None:
                raise ValueError("widersprüchlicher Referenzzeitpunkt im Datumsbeleg")
        elif (not self.same_instant(value["referenceTime"], self.reference)
              or not isinstance(value["referenceISO"], str)
              or value["referenceISO"] != value["referenceISO"].strip()
              or not self.same_instant(file_timestamp(value["referenceISO"]), self.reference)):
            raise ValueError("widersprüchlicher Referenzzeitpunkt im Datumsbeleg")
        result = {}
        for entry in value["entries"]:
            if (not isinstance(entry, dict) or set(entry) != {"id", "question", "lowerISO", "upperISO", "lowerEpoch", "upperEpoch", "upperExclusiveISO"}
                    or not isinstance(entry["id"], str) or not 1 <= len(entry["id"].encode("utf-8")) <= 80
                    or entry["id"] in result or not isinstance(entry["question"], dict)):
                raise ValueError("ungültiger oder doppelter eingefrorener Datumsbereich")
            question = entry["question"]
            zone = question.get("timeZone")
            if not isinstance(zone, str) or not zone or len(zone.encode("utf-8")) > 128 or "\0" in zone:
                raise ValueError("eingefrorener Bereich braucht eine benannte Zeitzone")
            if question.get("kind") == "relative":
                if set(question) != {"kind", "preset", "timeZone"} or question["preset"] not in DATE_PRESETS or self.reference is None:
                    raise ValueError("ungültige eingefrorene relative Frage")
            elif question.get("kind") == "fixed":
                if (set(question) != {"kind", "lower", "upper", "timeZone"}
                        or question["lower"] != entry["lowerISO"] or question["upper"] != entry["upperISO"]):
                    raise ValueError("eingefrorene feste Grenzen passen nicht zur Frage")
            else:
                raise ValueError("unbekannte eingefrorene Datumsfrage")
            for key in ("lowerISO", "upperISO"):
                if not isinstance(entry[key], str) or entry[key] != entry[key].strip():
                    raise ValueError("ungültiger eingefrorener ISO-Beleg")
            lower, upper = file_timestamp(entry["lowerISO"]), file_timestamp_end(entry["upperISO"])
            if (not self.same_instant(entry["lowerEpoch"], lower) or not self.same_instant(entry["upperEpoch"], upper)
                    or entry["lowerEpoch"] > entry["upperEpoch"]):
                raise ValueError("ISO- und Epochgrenzen widersprechen sich")
            if "." in entry["upperISO"][11:]:
                if entry["upperExclusiveISO"] is not None:
                    raise ValueError("exakter Sekundenbruch hat keine folgende exklusive Grenze")
            else:
                end = entry["upperExclusiveISO"]
                if (not isinstance(end, str) or end != end.strip()
                        or file_timestamp(end) != math.nextafter(upper, math.inf)
                        or entry["upperEpoch"] != math.nextafter(file_timestamp(end), -math.inf)):
                    raise ValueError("inklusive und exklusive Obergrenze widersprechen sich")
            result[entry["id"]] = entry
        return result

    def finish(self):
        if self.frozen is not None and set(self.frozen) != {entry["id"] for entry in self.entries}:
            raise ValueError("eingefrorener Datumsbeleg beschreibt nicht genau alle Datumsbedingungen")

    @staticmethod
    def iso(stamp):
        return datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).isoformat().replace("+00:00", "Z")

    @staticmethod
    def zone(name):
        if (not isinstance(name, str) or not name or len(name.encode("utf-8")) > 128
                or "\0" in name):
            raise ValueError("eine ausdrückliche IANA-Zeitzone ist erforderlich")
        try:
            return ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            raise ValueError("unbekannte oder nicht verfügbare IANA-Zeitzone: " + name) from None

    @staticmethod
    def local_time(text, zone, fold=None):
        if (not isinstance(text, str)
                or re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}", text) is None
                or (fold is not None and (type(fold) is not int or fold not in (0, 1)))):
            raise ValueError("lokale Kalenderzeit braucht Datum, Uhrzeit mit Sekunden und gegebenenfalls fold 0/1")
        wall = datetime.datetime.fromisoformat(text)
        candidates = {}
        for choice in (0, 1):
            stamp = wall.replace(tzinfo=zone, fold=choice).timestamp()
            back = datetime.datetime.fromtimestamp(stamp, zone)
            if back.replace(tzinfo=None) == wall:
                candidates[choice] = stamp
        if not candidates:
            raise ValueError("lokale Uhrzeit existiert in dieser Zeitzone nicht: " + text)
        if len(set(candidates.values())) > 1 and fold is None:
            raise ValueError("lokale Uhrzeit ist zweideutig; frühere/spätere Uhrzeit (fold 0/1) ausdrücklich wählen: " + text)
        return candidates.get(0 if fold is None else fold, next(iter(candidates.values())))

    def resolve(self, spec, identifier):
        if not isinstance(spec, dict) or not isinstance(spec.get("kind"), str):
            raise ValueError("Datumsbereich muss ein typisiertes Objekt sein")
        kind = spec["kind"]
        if self.frozen is not None:
            entry = self.frozen.get(identifier)
            if entry is None or entry["question"] != spec:
                raise ValueError("eingefrorener Datumsbereich passt nicht zur Frage: " + identifier)
            self.entries.append(entry)
            return entry
        zone = self.zone(spec.get("timeZone"))
        exclusive = None
        if kind == "relative":
            if set(spec) != {"kind", "preset", "timeZone"} or spec["preset"] not in DATE_PRESETS:
                raise ValueError("unbekannter relativer Datumsbereich")
            if self.reference is None:
                raise ValueError("relative Datumsbereiche brauchen --date-reference-time mit Z oder Offset")
            day = datetime.datetime.fromtimestamp(math.floor(self.reference), zone).date()
            if spec["preset"] == "today":
                first, after = day, day + datetime.timedelta(days=1)
            elif spec["preset"] == "last7CalendarDays":
                first, after = day - datetime.timedelta(days=6), day + datetime.timedelta(days=1)
            else:
                first = day.replace(day=1)
                after = (first.replace(year=first.year + 1, month=1)
                         if first.month == 12 else first.replace(month=first.month + 1))
            lower = self.local_time(first.isoformat() + "T00:00:00", zone)
            exclusive = self.local_time(after.isoformat() + "T00:00:00", zone)
            upper = math.nextafter(exclusive, -math.inf)
            lower_iso, upper_iso = self.iso(lower), self.iso(exclusive - 1)
        elif kind == "fixed":
            if set(spec) != {"kind", "lower", "upper", "timeZone"}:
                raise ValueError("fester Datumsbereich braucht lower, upper und timeZone")
            if not isinstance(spec["lower"], str) or not isinstance(spec["upper"], str):
                raise ValueError("feste Grenzen müssen ISO-Zeitpunkte sein")
            if any(spec[key] != spec[key].strip() for key in ("lower", "upper")):
                raise ValueError("feste Kalendergrenzen brauchen ISO-Text ohne Rand-Leerraum")
            lower, upper = file_timestamp(spec["lower"]), file_timestamp_end(spec["upper"])
            lower_iso, upper_iso = spec["lower"], spec["upper"]
            if "." not in upper_iso[11:]:
                exclusive = math.nextafter(upper, math.inf)
        elif kind == "calendar":
            required = {"kind", "fromLocal", "toLocal", "timeZone"}
            if (not required.issubset(spec) or not set(spec).issubset(required | {"fold", "fromFold", "toFold"})
                    or ("fold" in spec and ("fromFold" in spec or "toFold" in spec))):
                raise ValueError("Kalenderauftrag braucht fromLocal, toLocal und timeZone")
            lower = self.local_time(spec["fromLocal"], zone, spec.get("fromFold", spec.get("fold")))
            last_second = self.local_time(spec["toLocal"], zone, spec.get("toFold", spec.get("fold")))
            upper = math.nextafter(last_second + 1, -math.inf)
            exclusive = last_second + 1
            lower_iso, upper_iso = self.iso(lower), self.iso(last_second)
        else:
            raise ValueError("unbekannte Datumsbereichsart")
        if not math.isfinite(lower) or not math.isfinite(upper) or lower > upper:
            raise ValueError("Datumsbereich ist ungültig oder die Untergrenze liegt nach der Obergrenze")
        entry = {"id": identifier, "question": spec, "lowerISO": lower_iso, "upperISO": upper_iso,
                 "lowerEpoch": lower, "upperEpoch": upper,
                 "upperExclusiveISO": None if exclusive is None else self.iso(exclusive)}
        self.entries.append(entry)
        if len(self.entries) > 130 or len(json.dumps(self.snapshot()).encode("utf-8")) > DATE_RANGE_BYTES:
            raise ValueError("aufgelöste Datumsbereiche überschreiten die Beleggrenze von 64 KiB/130 Einträgen")
        return entry

    def snapshot(self):
        return {"schemaVersion": 1, "referenceTime": self.reference,
                "referenceInput": self.reference_input,
                "referenceISO": None if self.reference is None else self.iso(self.reference),
                "entries": self.entries}


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("muss größer als 0 sein")
    return parsed


def metadata_tag(value):
    """Ein Feldname aus --metadata-field — nur aus METADATA_TEXT_FIELDS.

    Eine POSITIVLISTE, keine Zeichenregel. Der Name wird mit "-" verkettet
    und geht als Argument an exiftool; die Argumentdatei von `-stay_open`
    ist dabei zeilenweise. Eine Zeichenregel reicht dagegen nicht: Sie
    ließe `execute`, `charset`, `p`, `b`, `w`, `if` und `ver` durch —
    allesamt echte exiftool-Optionen. Schon `--metadata-field execute`
    zerlegte jede Anfrage in zwei Kommandos, und die Suche lieferte für
    JEDE Datei „keine Treffer". Ein Zeilenumbruch im Wert schöbe darüber
    hinaus beliebige weitere Optionen ein, über `-p` mit einem
    Perl-Ausdruck bis hin zum Shell-Aufruf.

    Die Liste ist ohnehin der Vertrag: `--list-metadata-fields` gibt genau
    sie aus, und die Oberflächen bauen ihr Feldmenü daraus. Die
    Schreibweise ist frei — exiftool unterscheidet dort keine Groß- und
    Kleinschreibung —, zurück kommt die kanonische Form."""
    erlaubt = {field.lower(): field for field in METADATA_TEXT_FIELDS}
    kanonisch = erlaubt.get(value.strip().lower())
    if kanonisch is None:
        raise argparse.ArgumentTypeError(
            "unbekanntes Metadatenfeld %r — erlaubt sind: %s "
            "(siehe --list-metadata-fields)"
            % (value, ", ".join(METADATA_TEXT_FIELDS)))
    return kanonisch


def install_termination_handlers():
    """Übersetzt SIGTERM und SIGHUP in ein normales Programmende.

    Ohne das läuft der `finally`-Block in main() NICHT, und der
    exiftool-Prozess mit `-stay_open` bleibt als Waise stehen. Das ist
    kein Randfall: Beide Apps brechen jede Suche mit `terminate()` ab —
    also SIGTERM —, und die Schnellsuche startet die Suche bei jedem
    Tastendruck neu. SIGINT braucht nichts, das ist bereits ein
    KeyboardInterrupt. Gegen SIGKILL hilft nichts; das lässt sich nicht
    abfangen.

    Liefert die vorherigen Handler zurück, damit ein Aufrufer im selben
    Prozess (die Tests rufen main() direkt) sie wiederherstellen kann."""
    previous = {}

    def stop(signal_number, _frame):
        raise SystemExit(128 + signal_number)

    for name in ("SIGTERM", "SIGHUP"):
        number = getattr(signal, name, None)
        if number is None:
            continue
        try:
            previous[number] = signal.signal(number, stop)
        except (ValueError, OSError):
            pass          # etwa beim Aufruf aus einem Nebenthread
    return previous


def restore_termination_handlers(previous):
    """Setzt zurück, was install_termination_handlers() gesetzt hat."""
    for number, handler in previous.items():
        try:
            signal.signal(number, handler)
        except (ValueError, OSError):
            pass


def positive_float(value):
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("muss endlich und größer als 0 sein")
    return parsed


def nonnegative_int(value):
    """Wie positive_int, lässt aber die 0 zu — nur für --archive-depth.

    Dort heißt 0 ausdrücklich „gar nicht in Archive schauen". Eine negative
    Zahl hat dagegen keine Bedeutung: Sie lief bisher stillschweigend wie 0,
    ein Tippfehler wie „--archive-depth -1" hat also kommentarlos alle
    Archivtreffer unterschlagen."""
    parsed = int(value)
    if parsed < 0:
        raise argparse.ArgumentTypeError("darf nicht negativ sein")
    return parsed


def parse_archive_depth(value):
    """Begrenzt die rekursive Archivtiefe auf einen C-Stack-sicheren Wert."""
    parsed = nonnegative_int(value)
    if parsed > MAX_ARCHIVE_DEPTH:
        raise argparse.ArgumentTypeError(
            "darf höchstens %d sein" % MAX_ARCHIVE_DEPTH)
    return parsed



# --- Metadaten und Bildmaße -------------------------------------------------

# Die Metadatenfelder, in denen --metadata liest: bewusst EINE kuratierte
# Liste, die sich leicht ändern lässt. „Alle Felder" wäre als Suchraum
# unbrauchbar — in 357 realen Dateien (Bilder, PDFs, Audio; Messung
# 2026-09-01) waren die häufigsten Felder ICC-Profil-Rauschen wie
# ProfileCMMType, nutzerrelevanter Text steckte in etwa 15 Feldern.
# Die Namen sind die von exiftool mit `-use MWG` (das legt EXIF, IPTC und
# XMP übereinander); --list-metadata-fields gibt sie aus.
METADATA_TEXT_FIELDS = (
    "Keywords", "Subject", "Title", "Description", "ImageDescription",
    "Caption-Abstract", "Headline", "UserComment", "Comment", "XPComment",
    "XPKeywords", "Artist", "Creator", "Author", "Copyright", "PersonInImage",
    "Album", "AlbumArtist", "Genre", "Composer", "Category",
)

# Nur Dateien mit diesen Endungen gehen überhaupt an exiftool. Ein Lauf über
# ein Quellcodeverzeichnis darf exiftool nicht auf jede .o werfen — der
# Aufruf kostet je Datei 0,7 ms (Bilder) bis 61 ms (PDF).
METADATA_EXTENSIONS = frozenset((
    ".jpg", ".jpeg", ".jpe", ".png", ".gif", ".tif", ".tiff", ".bmp", ".webp",
    ".heic", ".heif", ".avif", ".psd", ".dng", ".cr2", ".cr3", ".nef", ".arw",
    ".raf", ".orf", ".rw2", ".pdf", ".mp3", ".m4a", ".flac", ".wav", ".aif",
    ".aiff", ".ogg", ".opus", ".aac", ".mp4", ".mov", ".m4v", ".mkv", ".avi",
))

# Formate, deren Maße der eingebaute Leser nicht kennt. Nur hier fragt der
# Rückfall exiftool nach ImageWidth/ImageHeight — und nur, wenn es da ist.
EXIFTOOL_DIMENSION_EXTENSIONS = frozenset((
    ".heic", ".heif", ".avif", ".psd", ".dng", ".cr2", ".cr3", ".nef", ".arw",
    ".raf", ".orf", ".rw2", ".mp4", ".mov", ".m4v", ".mkv", ".avi",
))

# Orte, an denen exiftool liegen kann, wenn es nicht im PATH steht (die Apps
# starten mit dem knappen launchd-PATH ohne Homebrew).
EXIFTOOL_FALLBACK_CANDIDATES = (
    "/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool",
    "/opt/local/bin/exiftool",
)

# Cache der einmaligen Suche: None = noch nicht gesucht, "" = nicht da.
# Tests setzen "" um „exiftool fehlt" zu simulieren.
_EXIFTOOL_PATH = None


def find_exiftool():
    """Pfad zu exiftool oder None, wenn es nicht installiert ist."""
    global _EXIFTOOL_PATH
    if _EXIFTOOL_PATH is None:
        found = shutil.which("exiftool")
        if found is None:
            for candidate in EXIFTOOL_FALLBACK_CANDIDATES:
                if os.access(candidate, os.X_OK):
                    found = candidate
                    break
        _EXIFTOOL_PATH = found or ""
    return _EXIFTOOL_PATH or None


# So viele Bytes darf der Maß-Leser höchstens durchgehen. Ein JPEG trägt
# seine Maße hinter den APP-Segmenten (EXIF, ICC, XMP) — normalerweise nach
# wenigen KB, bei eingebetteten Vorschaubildern nach ein paar hundert KB.
DIMENSION_SCAN_LIMIT = 4 * 1024 * 1024

# Längste Kante, die noch als Bildmaß durchgeht. PNG erlaubt laut
# Spezifikation höchstens 2^31-1 Pixel je Kante, und kein reales Format geht
# darüber hinaus; größere Werte stammen aus einem beschädigten oder absichtlich
# präparierten Kopf. Ohne diese Schranke liefert ein 30-Byte-PNG-Kopf mit
# 0xffffffff je Kante einen Treffer, dessen Fläche in der App beim Sortieren
# über Int.max läuft und den Prozess beendet.
MAX_IMAGE_EDGE = 2 ** 31 - 1


def plausible_dimensions(width, height):
    """(Breite, Höhe) — oder None, wenn die Werte kein Bild beschreiben
    können. Gilt für den eigenen Kopf-Leser wie für den exiftool-Rückfall."""
    if not isinstance(width, int) or not isinstance(height, int):
        return None
    if width <= 0 or height <= 0:
        return None
    if width > MAX_IMAGE_EDGE or height > MAX_IMAGE_EDGE:
        return None
    return width, height


class _BudgetedStream:
    """Macht aus den Byte-Häppchen eines Chunkers ein lesbares Objekt.

    Der Maß-Leser will `read(n)`; der Chunker liefert Häppchen und zählt sie
    dabei gegen die Entpackgrenzen des Suchlaufs. Nur über diesen Umweg gilt
    für den Bildkopf eines Archiv-Eintrags dieselbe Einzel- und Gesamtgrenze
    wie für die Inhaltssuche — sonst käme eine Maßsuche an den Grenzen
    vorbei. `fetched` sagt hinterher, wie viele Bytes dem Budget belastet
    wurden; der Inhaltsdurchlauf zählt genau diesen Anfang nicht noch einmal.
    """

    def __init__(self, chunks):
        self.chunks = iter(chunks)
        self.pending = b""      # vom letzten Häppchen übrig geblieben
        self.fetched = 0        # so viele Bytes kamen aus dem Chunker

    def read(self, count):
        parts = []
        have = 0
        if self.pending:
            take = self.pending[:count]
            self.pending = self.pending[len(take):]
            parts.append(take)
            have = len(take)
        while have < count:
            try:
                chunk = next(self.chunks)
            except StopIteration:
                break
            self.fetched += len(chunk)
            take = min(count - have, len(chunk))
            parts.append(chunk[:take])
            self.pending = chunk[take:]
            have += take
        return b"".join(parts)


class _ForwardReader:
    """Liest einen Datenstrom nur vorwärts, mit Zurücklegen des Kopfes.

    Der Maß-Leser bekommt keinen Pfad, sondern einen Strom — so gilt er
    unverändert für Archiv-Einträge, die sich nicht zurückspulen lassen
    (bsdtar liefert einen Pipe-Strom). Deshalb kein seek(): Überspringen
    heißt Weglesen, und die anfangs gelesenen Kopfbytes werden zurückgelegt,
    damit jedes Format bei Byte 0 beginnt."""

    def __init__(self, handle):
        self.handle = handle
        self.pending = b""
        self.position = 0

    def push_back(self, data):
        self.pending = data + self.pending
        self.position -= len(data)

    def read(self, count):
        """Bis zu `count` Bytes; am Ende weniger oder b""."""
        parts = []
        if self.pending:
            parts.append(self.pending[:count])
            self.pending = self.pending[count:]
            count -= len(parts[0])
        if count > 0:
            chunk = self.handle.read(count)
            if chunk:
                parts.append(chunk)
        data = b"".join(parts)
        self.position += len(data)
        if self.position > DIMENSION_SCAN_LIMIT:
            raise ValueError("Bildkopf zu lang")
        return data

    def read_exact(self, count):
        data = self.read(count)
        if len(data) < count:
            raise EOFError("Bildkopf abgeschnitten")
        return data

    def skip(self, count):
        while count > 0:
            chunk = self.read(min(count, CHUNK_SIZE))
            if not chunk:
                raise EOFError("Bildkopf abgeschnitten")
            count -= len(chunk)


def image_dimensions(handle):
    """(Breite, Höhe) in Pixeln aus dem Dateikopf — oder None.

    Nur Standardbibliothek, liest nur vorwärts und nur so weit wie nötig:
    PNG (IHDR), GIF, BMP, WebP (VP8/VP8L/VP8X), TIFF (erstes IFD) und JPEG
    (erster SOF-Marker). Alles andere — HEIC, RAW, Video — beantwortet der
    Rückfall über exiftool. Gemessen am 2026-09-01: 0,198 ms je Datei über
    239 reale Bilder, 239 davon korrekt."""
    try:
        dims = _image_dimensions(_ForwardReader(handle))
    except (EOFError, ValueError, struct.error, IndexError):
        # IndexError als Netz: Ein kaputter Kopf darf nie den ganzen
        # Suchlauf beenden. Ein Bild ohne lesbare Maße erfüllt einen
        # Maßfilter einfach nie — so steht es auch im Vertrag.
        return None
    if dims is None:
        return None
    return plausible_dimensions(*dims)


def _image_dimensions(reader):
    head = reader.read(30)
    reader.push_back(head)
    if head[:8] == b"\x89PNG\r\n\x1a\n" and head[12:16] == b"IHDR":
        return struct.unpack(">II", head[16:24])
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return struct.unpack("<HH", head[6:10])
    if head[:2] == b"BM" and len(head) >= 26:
        header_size = struct.unpack("<I", head[14:18])[0]
        if header_size == 12:                      # altes OS/2-Format
            return struct.unpack("<HH", head[18:22])
        width, height = struct.unpack("<ii", head[18:26])
        return abs(width), abs(height)             # negativ = von oben
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        chunk = head[12:16]
        # Die Längenprüfungen sind Pflicht, nicht Vorsicht: Bei einer
        # abgeschnittenen Datei (halber Download) liefert read(30) weniger
        # Bytes. VP8L griff dann mit bits[1] ins Leere — ein IndexError,
        # den image_dimensions() nicht fing und der den GANZEN Suchlauf
        # beendete; VP8X las aus leeren Slices still 1×1 Pixel und erzeugte
        # damit einen Falschtreffer. Die Zahlen sind das jeweils zuletzt
        # gebrauchte Byte: VP8L braucht 25, VP8 und VP8X je 30.
        if chunk == b"VP8 " and len(head) >= 30:
            width, height = struct.unpack("<HH", head[26:30])
            return width & 0x3FFF, height & 0x3FFF
        if chunk == b"VP8L" and len(head) >= 25:
            bits = head[21:25]
            width = 1 + (((bits[1] & 0x3F) << 8) | bits[0])
            height = 1 + (((bits[3] & 0x0F) << 10) | (bits[2] << 2)
                          | ((bits[1] & 0xC0) >> 6))
            return width, height
        if chunk == b"VP8X" and len(head) >= 30:
            return (int.from_bytes(head[24:27], "little") + 1,
                    int.from_bytes(head[27:30], "little") + 1)
        return None
    if head[:2] == b"\xff\xd8":
        return _jpeg_dimensions(reader)
    if head[:4] in (b"II*\x00", b"MM\x00*"):
        return _tiff_dimensions(reader, "<" if head[:2] == b"II" else ">")
    return None


def _jpeg_dimensions(reader):
    """Sucht den ersten SOF-Marker; davor liegen nur Segmente mit Länge."""
    reader.skip(2)
    while True:
        byte = reader.read(1)
        if not byte:
            return None
        if byte != b"\xff":
            continue
        while byte == b"\xff":
            byte = reader.read_exact(1)
        marker = byte[0]
        if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
            continue                               # Marker ohne Länge
        if marker in (0xD9, 0xDA):
            return None                            # Bilddaten ohne SOF
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            reader.skip(3)                         # Länge + Farbtiefe
            height, width = struct.unpack(">HH", reader.read_exact(4))
            return width, height
        length = struct.unpack(">H", reader.read_exact(2))[0]
        reader.skip(length - 2)


def _tiff_dimensions(reader, endian):
    """Breite (Tag 0x100) und Höhe (0x101) aus dem ersten IFD."""
    header = reader.read_exact(8)
    offset = struct.unpack(endian + "I", header[4:8])[0]
    reader.skip(offset - 8)
    count = struct.unpack(endian + "H", reader.read_exact(2))[0]
    width = height = None
    for _ in range(count):
        entry = reader.read_exact(12)
        tag, kind = struct.unpack(endian + "HH", entry[:4])
        if tag not in (0x0100, 0x0101):
            continue
        if kind == 3:                              # SHORT
            value = struct.unpack(endian + "H", entry[8:10])[0]
        elif kind == 4:                            # LONG
            value = struct.unpack(endian + "I", entry[8:12])[0]
        else:
            continue
        if tag == 0x0100:
            width = value
        else:
            height = value
        if width is not None and height is not None:
            return width, height
    return None


class ExifToolStream:
    """EIN exiftool-Prozess für den ganzen Suchlauf.

    Ein Prozess je Datei kostet 44 ms; mit `-stay_open True` werden die
    Pfade laufend über die Argumentdatei (hier: stdin) nachgereicht und
    kosten 0,75 ms je Bild (Messung 2026-09-01). Die Suche streamt damit
    weiter, statt erst alle Pfade zu sammeln. Je Datei kommt ein JSON-Array
    zurück, abgeschlossen durch die Zeile `{ready}`."""

    def __init__(self, executable, fields, warn=None):
        self.executable = executable
        self.fields = list(fields)
        self.broken = False
        # Ohne Warnkanal blieb der Tod des Prozesses unsichtbar: read()
        # lieferte danach für JEDE weitere Datei None, der Lauf endete mit
        # „keine Treffer" und war von einer wirklich leeren Suche nicht zu
        # unterscheiden.
        self.warn = warn if warn is not None else (lambda message: None)
        self.process = subprocess.Popen(
            [executable, "-stay_open", "True", "-@", "-"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL)

    def arguments(self, path):
        """Die exiftool-Argumente für EINE Datei.

        `-use MWG` legt EXIF, IPTC und XMP übereinander (Keywords ist dann
        ein Feld statt drei); `-m` übergeht kleine Formatfehler, wie es auch
        ein Bildbetrachter täte."""
        arguments = ["-json", "-use", "MWG", "-m", "-charset",
                     "filename=utf8"]
        arguments.extend("-" + field for field in self.fields)
        # Die Argumentdatei von -stay_open ist zeilenweise, und exiftool
        # deutet den Zeilenanfang: "-" beginnt eine Option, "#" einen
        # Kommentar, führender Leerraum wird abgeschnitten. Ein "./" davor
        # macht aus JEDEM relativen Pfad einen eindeutigen Dateinamen, der
        # auf dieselbe Datei zeigt. Vorher galt die Regel nur für "-", und
        # "#tag.jpg" wie " bilder/foto.jpg" fielen ohne jede Meldung aus
        # der Suche. Ein absoluter Pfad beginnt mit "/" und braucht nichts.
        arguments.append(path if path.startswith("/") else "./" + path)
        return arguments

    @staticmethod
    def parse(raw):
        """Das JSON-Array eines exiftool-Laufs als dict — oder None."""
        text = raw.decode("utf-8", "replace").strip()
        if not text:
            return None
        try:
            records = json.loads(text)
        except ValueError:
            return None
        return records[0] if records else None

    def read(self, path):
        """Die angeforderten Felder EINER Datei als dict — oder None."""
        if self.broken:
            return None
        # Leerraum am Zeilenende schneidet exiftool ab; ein Zeilenumbruch
        # im Pfad zerlegte die Zeile ganz. Beides beantwortet ein eigener
        # Prozess. Führenden Leerraum und ein "#" am Anfang entschärft
        # dagegen schon das "./" aus arguments().
        if "\n" in path or "\r" in path or path != path.rstrip():
            return self.read_once(path)
        arguments = self.arguments(path) + ["-execute"]
        try:
            self.process.stdin.write(
                ("\n".join(arguments) + "\n").encode("utf-8"))
            self.process.stdin.flush()
            buffer = []
            while True:
                line = self.process.stdout.readline()
                if not line:
                    raise BrokenPipeError("exiftool hat sich beendet")
                if line.strip() == b"{ready}":
                    break
                buffer.append(line)
        except (OSError, ValueError) as err:
            self.broken = True
            self.warn("exiftool weggebrochen, ab hier gibt es keine "
                      "Metadaten und keine Maße daraus mehr: %s" % err)
            return None
        return self.parse(b"".join(buffer))

    def read_once(self, path):
        """Rückfall für Pfade, die der laufende Prozess nicht annehmen kann.

        Die Argumentdatei von `-stay_open` ist zeilenweise; ein Zeilenumbruch
        im Dateinamen ließe sich darüber nicht übertragen. macOS erlaubt in
        einem Dateinamen aber jedes Zeichen außer "/" und NUL. Für diese
        seltenen Pfade deshalb EIN eigener Prozess (44 ms statt 0,75 ms) —
        besser als der frühere stille Ausfall, bei dem eine getaggte Datei
        ohne jede Meldung aus der Trefferliste fiel."""
        try:
            completed = subprocess.run(
                [self.executable] + self.arguments(path),
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                check=False)
        except OSError:
            return None
        return self.parse(completed.stdout)

    def close(self):
        """Beendet den Prozess sauber — auch nach einem Abbruch der Suche."""
        try:
            self.process.stdin.write(b"-stay_open\nFalse\n")
            self.process.stdin.flush()
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait()
        finally:
            # Beide Pipes gehören uns. Ohne dieses Schließen bleibt je
            # Suchlauf ein Dateideskriptor offen, bis der Sammler ihn
            # irgendwann einzieht (sichtbar als ResourceWarning) — und auf
            # dem Fehlerpfad, wo der Prozess schon tot ist und der Aufruf
            # oben gar nicht bis zum stdin.close() kommt, sogar zwei.
            # Mehrfaches close() ist gefahrlos.
            for pipe in (self.process.stdin, self.process.stdout):
                if pipe is not None:
                    try:
                        pipe.close()
                    except OSError:
                        pass


def metadata_values(value):
    """Ein Metadatenfeld als Liste von Texten: Listen (Keywords) Element
    für Element, alles andere als ein Text."""
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


MISSING = object()   # „noch nicht ermittelt" — auch None ist ein Ergebnis
DEFERRED = object()  # ein anderer Zweig hat die Frage bereits entschieden


class LocalContentPolicyError(ValueError):
    pass


@contextlib.contextmanager
def local_content_policy(enabled):
    """Die macOS-Sperre gilt auch für Zwischenordner und erbt sich an Helfer.

    Ein stat-Vortest allein hat eine Lücke zwischen Prüfung und Öffnen.
    TN3150 verlangt deshalb zusätzlich die Materialisierungssperre.
    """
    if not enabled:
        yield
        return
    if sys.platform != "darwin" or int(os.uname().release.split(".")[0]) < 22:
        raise LocalContentPolicyError("--local-only benötigt macOS 13 oder neuer")
    try:
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        get_policy, set_policy = library.getiopolicy_np, library.setiopolicy_np
    except (OSError, AttributeError) as error:
        raise LocalContentPolicyError("Materialisierungssperre nicht verfügbar; lokale Suche nicht gestartet") from error
    get_policy.argtypes = (ctypes.c_int, ctypes.c_int)
    set_policy.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_int)
    get_policy.restype = set_policy.restype = ctypes.c_int
    # Öffentliche Konstanten aus sys/resource.h: VFS_DATALESS, PROCESS, OFF.
    previous = get_policy(3, 0)
    if previous < 0 or set_policy(3, 0, 1) != 0:
        raise LocalContentPolicyError("Materialisierungssperre nicht verfügbar; lokale Suche nicht gestartet")
    try:
        if get_policy(3, 0) != 1:
            raise LocalContentPolicyError("Materialisierungssperre nicht bestätigt; lokale Suche nicht gestartet")
        yield
    finally:
        if set_policy(3, 0, previous) != 0:
            raise RuntimeError("Materialisierungssperre konnte nicht zurückgesetzt werden")


class DarwinFileSystem(ctypes.Structure):
    """Öffentliches statfs64-Layout aus sys/mount.h, einschließlich Reserve."""
    _fields_ = [("blockSize", ctypes.c_uint32), ("ioSize", ctypes.c_int32),
                ("blocks", ctypes.c_uint64), ("freeBlocks", ctypes.c_uint64),
                ("availableBlocks", ctypes.c_uint64), ("files", ctypes.c_uint64),
                ("freeFiles", ctypes.c_uint64), ("identifier", ctypes.c_int32 * 2),
                ("owner", ctypes.c_uint32), ("kind", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("subtype", ctypes.c_uint32),
                ("name", ctypes.c_char * 16), ("mountPoint", ctypes.c_char * 1024),
                ("source", ctypes.c_char * 1024), ("extendedFlags", ctypes.c_uint32),
                ("reserved", ctypes.c_uint32 * 7)]


def local_file_system(path):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    query = library.statfs64
    query.argtypes = (ctypes.c_char_p, ctypes.POINTER(DarwinFileSystem))
    query.restype = ctypes.c_int
    information = DarwinFileSystem()
    if query(os.fsencode(path), ctypes.byref(information)) != 0:
        return False
    return bool(information.flags & 0x1000)  # MNT_LOCAL


def unverified_provider_location(path, provider_root=None):
    """Die Providergrenze gilt auch über Links, Großschreibung und Firmlinks."""
    if provider_root is None:
        provider_root = os.path.join(os.path.expanduser("~"), "Library", "CloudStorage")
    try:
        root = os.stat(provider_root)
    except FileNotFoundError:
        return False
    if not stat.S_ISDIR(root.st_mode):
        return False
    identity = root.st_dev, root.st_ino
    visited = set()
    for candidate in (os.path.abspath(path), os.path.realpath(path)):
        while candidate not in visited:
            visited.add(candidate)
            information = os.stat(candidate)
            if (information.st_dev, information.st_ino) == identity:
                return True
            parent = os.path.dirname(candidate)
            if parent == candidate:
                break
            candidate = parent
    return False


def local_content_reason(path):
    """None bedeutet lokal lesbar; andere Provider bleiben ausdrücklich unbekannt."""
    try:
        information = os.stat(path)
        flags = getattr(information, "st_flags", None)
        if flags is None:
            return "localContentUnknown"
        if flags & 0x40000000:  # SF_DATALESS, auch während Materialisierung.
            return "localContentNotLocal"
        if not local_file_system(path) or unverified_provider_location(path):
            return "localContentUnknown"
    except OSError as error:
        return ("localContentNotLocal" if error.errno in (errno.EDEADLK, errno.EAGAIN)
                else "localContentUnknown")
    except AttributeError:
        return "localContentUnknown"
    return None


def search_path_exists(path, local_only):
    if not local_only:
        return os.path.exists(path)
    try:
        os.stat(path)
        return True
    except OSError as error:
        # Ein gesperrter Zwischenordner ist kein Beweis für einen fehlenden
        # Startpfad. Der Lauf meldet diesen Bereich als unbekannt/ausgelassen.
        return error.errno in (errno.EDEADLK, errno.EAGAIN)


class LocalContentError(ArchiveReadError):
    def __init__(self, reason):
        super().__init__(REPORT_REASONS[reason][1], reason)


def open_regular_file(path):
    """Öffnet NUR eine reguläre Datei zum Lesen.

    Eine benannte Pipe (FIFO) ohne Schreiber lässt ein gewöhnliches
    `open()` unbegrenzt warten: Die Suche steht dann still — kein
    Ergebnis, kein Fehler, kein Abbruch. `O_NONBLOCK` kehrt beim Öffnen
    sofort zurück, danach sagt `fstat`, was wirklich dahintersteckt.
    Für das anschließende Lesen wird das Blockieren wieder eingeschaltet,
    sonst bräche `read()` auf einer langsamen Quelle vorzeitig ab.

    Die Namenssuche ist nicht betroffen — sie öffnet die Datei gar nicht.
    Betroffen waren `--content` und jeder Maßfilter."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ArchiveReadError(
                "keine reguläre Datei (Pipe, Socket oder Gerät)", "notRegularFile")
        os.set_blocking(descriptor, True)
    except BaseException:
        os.close(descriptor)
        raise
    return open(descriptor, "rb")


DOCUMENT_BYTES = 64 * 1024 * 1024
DOCUMENT_TEXT_BYTES = 8 * 1024 * 1024
DOCUMENT_PAGE_BYTES = 256 * 1024
DOCUMENT_PAGES = 512
DOCUMENT_SECONDS = 5.0
DOCUMENT_ENCODING = "pdfkit-text-v1"
ODT_ENCODING = "odt-text-v1"
EPUB_ENCODING = "epub-text-v1"
DOCX_ENCODING = "docx-text-v1"
PPTX_ENCODING = "pptx-text-v1"
PPTX_SLIDES = 64
PPTX_OBJECTS = 32768
PPTX_TABLE_CELLS = 131072
PPTX_TABLE_ROWS = 131072
XLSX_ENCODING = "xlsx-text-v1"
XLSX_CELLS = 131072
XLSX_SHARED_STRINGS = 65536
XLSX_SHARED_TEXT_BYTES = 8 * 1024 * 1024
DOCUMENT_PARTS = 64
DOCUMENT_PARAGRAPHS = 32768
DOCUMENT_PARAGRAPH_BYTES = 256 * 1024
DOCUMENT_XML_BYTES = 8 * 1024 * 1024
DOCUMENT_TOTAL_XML_BYTES = 32 * 1024 * 1024
DOCUMENT_METADATA_BYTES = 256 * 1024
DOCUMENT_ZIP_ENTRIES = 4096
DOCUMENT_CATALOG_BYTES = 1024 * 1024
DOCUMENT_XML_DEPTH = 128
PDF_OCR_ENCODING = "pdfkit-vision-text-v1"
PDF_OCR_SECONDS = 10
PDF_OCR_PAGES = 128
OCR_ENCODING = "vision-ocr-text-v1"
OCR_EXTENSIONS = frozenset((".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".gif", ".heic", ".heif"))
OCR_PIXELS = 12_000_000
OCR_EDGE = 8192
OCR_BLOCKS = 4096
OCR_TEXT_BYTES = 1024 * 1024
OCR_REASONS = frozenset(("ocrHelperUnavailable", "ocrDamaged", "ocrLimit", "ocrReadError", "ocrMultipleFrames", "ocrNoText", "ocrTimeout"))
DOCUMENT_READERS = {"pdfkit-v1": DOCUMENT_ENCODING, "docx-v1": DOCX_ENCODING, "odt-v1": ODT_ENCODING, "epub-v1": EPUB_ENCODING, "xlsx-v1": XLSX_ENCODING, "pptx-v1": PPTX_ENCODING, "vision-image-v1": OCR_ENCODING, "pdfkit-vision-v1": PDF_OCR_ENCODING}


def find_pdf_helper():
    override = os.environ.get("FAVENIO_PDF_HELPER")
    if override is not None:
        return override if override and os.path.isfile(override) and os.access(override, os.X_OK) else None
    root = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.join(root, "..", "Helpers", "favenio-pdf"),
                      os.path.join(root, ".build", "favenio-pdf")):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return shutil.which("favenio-pdf")


def find_ocr_helper():
    override = os.environ.get("FAVENIO_OCR_HELPER")
    if override is not None:
        return override if override and os.path.isfile(override) and os.access(override, os.X_OK) else None
    root = os.path.dirname(os.path.abspath(__file__))
    for candidate in (os.path.join(root, "..", "Helpers", "favenio-ocr"),
                      os.path.join(root, ".build", "favenio-ocr")):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.abspath(candidate)
    return shutil.which("favenio-ocr")


class DocumentReadError(ArchiveReadError):
    def __init__(self, reason):
        super().__init__(REPORT_REASONS[reason][1], reason)


class ZIPDocumentReader:
    """Begrenzter ZIP-/XML-Zugang für logische Dokumentprojektionen."""
    REL_NAMESPACE = "http://schemas.openxmlformats.org/package/2006/relationships"
    REL_PREFIXES = ("http://schemas.openxmlformats.org/officeDocument/2006/relationships/",
                    "http://purl.oclc.org/ooxml/officeDocument/relationships/")
    def __init__(self, budget):
        self.budget = budget
        self.xml_bytes = self.text_bytes = self.paragraphs = 0
        self.on_issue = None

    @staticmethod
    def parser():
        parser = xml.parsers.expat.ParserCreate(namespace_separator="}")
        def forbidden(*args):
            raise DocumentReadError("documentDamaged")
        parser.StartDoctypeDeclHandler = forbidden
        parser.EntityDeclHandler = forbidden
        parser.ExternalEntityRefHandler = forbidden
        return parser

    @staticmethod
    def catalog(handle):
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        if size > DOCUMENT_BYTES:
            raise DocumentReadError("documentLimit")
        handle.seek(max(0, size - 65557))
        tail = handle.read(65557)
        offset = tail.rfind(b"PK\x05\x06")
        if offset < 0 or len(tail) - offset < 22:
            raise DocumentReadError("documentDamaged")
        disk, central_disk, disk_count, count, central_bytes, central_offset, comment = struct.unpack_from("<4H2IH", tail, offset + 4)
        if disk or central_disk or disk_count != count or len(tail) - offset != 22 + comment:
            raise DocumentReadError("documentDamaged")
        if count > DOCUMENT_ZIP_ENTRIES or central_bytes > DOCUMENT_CATALOG_BYTES or central_offset == 0xffffffff:
            raise DocumentReadError("documentLimit")
        handle.seek(0)

    def relations(self, archive, part, base):
        nodes = self.metadata(archive, part, paths=True)
        ns = self.REL_NAMESPACE + "}"
        if not nodes or nodes[0][0] != ns + "Relationships":
            raise DocumentReadError("documentDamaged")
        result, identifiers = {}, set()
        for tag, attrs, path in nodes[1:]:
            if tag != ns + "Relationship" or path != (ns + "Relationships", tag):
                raise DocumentReadError("documentDamaged")
            identifier, kind = attrs.get("Id"), attrs.get("Type", "")
            if not identifier or identifier in identifiers or attrs.get("TargetMode") not in (None, "Internal", "External"):
                raise DocumentReadError("documentDamaged")
            identifiers.add(identifier)
            if not any(kind.startswith(prefix) for prefix in self.REL_PREFIXES):
                continue
            result[identifier] = (kind.rsplit("/", 1)[-1], None if attrs.get("TargetMode") == "External" else self.target(base, attrs.get("Target")))
        return result

    def chunks(self, archive, name, metadata=False):
        try:
            info = archive.getinfo(name)
        except KeyError:
            raise DocumentReadError("documentDamaged")
        if info.flag_bits & 1:
            raise DocumentReadError("documentEncrypted")
        limit = DOCUMENT_METADATA_BYTES if metadata else DOCUMENT_XML_BYTES
        if info.is_dir() or info.file_size > limit:
            raise DocumentReadError("documentLimit")
        with archive.open(info) as stream:
            for chunk in self.budget.iter_chunks(stream, name, info.file_size, info.compress_size):
                self.xml_bytes += len(chunk)
                if self.xml_bytes > DOCUMENT_TOTAL_XML_BYTES:
                    raise DocumentReadError("documentLimit")
                # ArchiveBudget liefert größere Häppchen; der XML-Parser soll
                # vor einem frühen Treffer höchstens 8 KiB auf einmal sehen.
                for start in range(0, len(chunk), 8192):
                    yield chunk[start:start + 8192]

    def metadata(self, archive, name, paths=False):
        parser = self.parser()
        nodes = []
        depth = 0
        stack = []
        def start(tag, attributes):
            nonlocal depth
            depth += 1
            if depth > DOCUMENT_XML_DEPTH or len(nodes) >= DOCUMENT_ZIP_ENTRIES:
                raise DocumentReadError("documentLimit")
            stack.append(tag)
            nodes.append((tag, attributes, tuple(stack)) if paths else (tag, attributes))
        def end(tag):
            nonlocal depth
            depth -= 1
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler = start, end
        for chunk in self.chunks(archive, name, metadata=True):
            parser.Parse(chunk, False)
        parser.Parse(b"", True)
        return nodes

    @staticmethod
    def target(base, value):
        if not isinstance(value, str) or not value or len(value) > 1024:
            raise DocumentReadError("documentDamaged")
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment:
            raise DocumentReadError("documentDamaged")
        value = urllib.parse.unquote(parsed.path, errors="strict")
        path = posixpath.normpath(posixpath.join(base, value)) if not value.startswith("/") else posixpath.normpath(value[1:])
        if path in ("", ".", "..") or path.startswith("../") or "\\" in path or "\x00" in path or len(path) > 256:
            raise DocumentReadError("documentDamaged")
        return path

    @contextlib.contextmanager
    def package(self, path):
        try:
            with open_regular_file(path) as handle:
                self.catalog(handle)
                with zipfile.ZipFile(handle) as archive:
                    names = [item.filename for item in archive.infolist()]
                    if len(names) > DOCUMENT_ZIP_ENTRIES:
                        raise DocumentReadError("documentLimit")
                    if len(names) != len(set(names)):
                        raise DocumentReadError("documentDamaged")
                    yield archive
        except (zipfile.BadZipFile, xml.parsers.expat.ExpatError, KeyError, UnicodeError,
                ValueError, NotImplementedError, RuntimeError):
            raise DocumentReadError("documentDamaged")


class DOCXTextReader(ZIPDocumentReader):
    """WordprocessingML-Textläufe und Absätze, ohne Suchsemantik."""
    WORD_NAMESPACES = ("http://schemas.openxmlformats.org/wordprocessingml/2006/main",
                       "http://purl.oclc.org/ooxml/wordprocessingml/main")
    PART_KINDS = {"header": "header", "footer": "footer", "footnotes": "footnote", "endnotes": "endnote"}

    def __init__(self, budget):
        super().__init__(budget)
        self.relationship_ids = {}

    def relationships(self, archive, name, base):
        result = []
        ids = set()
        for tag, attrs in self.metadata(archive, name):
            if tag != self.REL_NAMESPACE + "}Relationship":
                continue
            identifier, kind = attrs.get("Id"), attrs.get("Type", "")
            if not identifier or identifier in ids:
                raise DocumentReadError("documentDamaged")
            ids.add(identifier)
            if not any(kind.startswith(prefix) for prefix in self.REL_PREFIXES):
                continue
            kind = kind.rsplit("/", 1)[-1]
            if kind not in ("officeDocument", *self.PART_KINDS):
                continue
            target = None if attrs.get("TargetMode") == "External" else self.target(base, attrs.get("Target"))
            self.relationship_ids[identifier] = (kind, target)
            result.append((kind, target))
        return result

    def paragraphs_in(self, archive, part, kind):
        parser = self.parser()
        queue = collections.deque()
        stack = []
        skip = None
        number = 0
        paragraph = None
        text_size = 0
        root = None
        unresolved = False
        def word(tag):
            namespace, _, local = tag.rpartition("}")
            return local if namespace in self.WORD_NAMESPACES else None
        def start(tag, attrs):
            nonlocal skip, paragraph, text_size, number, root, unresolved
            local = word(tag)
            stack.append(local)
            if root is None:
                root = local
                expected = {"document": "document", "header": "hdr", "footer": "ftr", "footnote": "footnotes", "endnote": "endnotes"}[kind]
                if root != expected:
                    raise DocumentReadError("documentDamaged")
            if len(stack) > DOCUMENT_XML_DEPTH:
                raise DocumentReadError("documentLimit")
            if skip is not None:
                return
            note_type = next((attrs.get(ns + "}type") for ns in self.WORD_NAMESPACES if ns + "}type" in attrs), None)
            if local in ("del", "moveFrom", "txbxContent") or (local in ("footnote", "endnote") and note_type in ("separator", "continuationSeparator", "continuationNotice")):
                skip = len(stack)
                return
            if local == "altChunk":
                raise DocumentReadError("documentReadError")
            if kind == "document" and local in ("headerReference", "footerReference", "footnoteReference", "endnoteReference"):
                reference_kind = local.removesuffix("Reference")
                if reference_kind in ("header", "footer"):
                    identifier = next((attrs.get(prefix.rstrip("/") + "}id") for prefix in self.REL_PREFIXES
                                       if prefix.rstrip("/") + "}id" in attrs), None)
                    relation = self.relationship_ids.get(identifier)
                    unresolved |= relation is None or relation[0] != reference_kind or relation[1] is None
                else:
                    unresolved |= not any(item[0] == reference_kind + "s" and item[1] is not None for item in self.relationship_ids.values())
            if local == "p":
                if paragraph is not None or (kind == "document" and "body" not in stack):
                    raise DocumentReadError("documentDamaged")
                number += 1
                self.paragraphs += 1
                if self.paragraphs > DOCUMENT_PARAGRAPHS:
                    raise DocumentReadError("documentLimit")
                paragraph, text_size = [], 0
            if local in ("tab", "br", "cr") and paragraph is not None:
                append("\t" if local == "tab" else "\n")
        def append(value):
            nonlocal text_size
            size = len(value.encode("utf-8"))
            text_size += size
            self.text_bytes += size
            if text_size > DOCUMENT_PARAGRAPH_BYTES or self.text_bytes > DOCUMENT_TEXT_BYTES:
                raise DocumentReadError("documentLimit")
            paragraph.append(value)
        def data(value):
            if skip is None and paragraph is not None and stack[-1] == "t":
                append(value)
        def end(tag):
            nonlocal skip, paragraph
            if skip == len(stack):
                skip = None
            elif skip is None and word(tag) == "p":
                queue.append((dict(kind="docxParagraph", part=part, partKind=kind, paragraph=number), "".join(paragraph)))
                paragraph = None
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, data
        for chunk in self.chunks(archive, part):
            try:
                parser.Parse(chunk, False)
            except (DocumentReadError, xml.parsers.expat.ExpatError):
                # Bereits abgeschlossene Absätze vor einem späteren Defekt
                # bleiben positive Belege. Erst weiteres Lesen sieht den Fehler.
                while queue:
                    yield queue.popleft()
                raise
            while queue:
                yield queue.popleft()
        parser.Parse(b"", True)
        while queue:
            yield queue.popleft()
        if unresolved:
            raise DocumentReadError("documentDamaged")

    def sections(self, path, deadline):
        try:
            with open_regular_file(path) as handle:
                self.catalog(handle)
                with zipfile.ZipFile(handle) as archive:
                    names = [item.filename for item in archive.infolist()]
                    if len(names) > DOCUMENT_ZIP_ENTRIES or len(names) != len(set(names)):
                        raise DocumentReadError("documentDamaged")
                    roots = [target for kind, target in self.relationships(archive, "_rels/.rels", "") if kind == "officeDocument"]
                    if len(roots) != 1 or roots[0] is None:
                        raise DocumentReadError("documentDamaged")
                    main = roots[0]
                    self.relationship_ids = {}
                    types = self.metadata(archive, "[Content_Types].xml")
                    if not any(tag == "http://schemas.openxmlformats.org/package/2006/content-types}Override" and
                               attrs.get("PartName") == "/" + main and attrs.get("ContentType") ==
                               "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
                               for tag, attrs in types):
                        raise DocumentReadError("documentDamaged")
                    directory, name = posixpath.split(main)
                    rels = posixpath.join(directory, "_rels", name + ".rels")
                    parts = [("document", main)]
                    pending_error = None
                    try:
                        if rels in names:
                            parts += [(self.PART_KINDS[kind], target) for kind, target in self.relationships(archive, rels, directory) if kind in self.PART_KINDS]
                    except DocumentReadError as err:
                        pending_error = err
                    seen = set()
                    for kind, part in parts:
                        if time.monotonic() >= deadline:
                            raise DocumentReadError("documentTimeout")
                        if part is None:
                            raise DocumentReadError("documentReadError")
                        if part in seen:
                            continue
                        seen.add(part)
                        if len(seen) > DOCUMENT_PARTS:
                            raise DocumentReadError("documentLimit")
                        yield from self.paragraphs_in(archive, part, kind)
                    if pending_error:
                        raise pending_error
        except (zipfile.BadZipFile, xml.parsers.expat.ExpatError, KeyError, UnicodeError, ValueError, NotImplementedError, RuntimeError):
            raise DocumentReadError("documentDamaged")


class ODTTextReader(ZIPDocumentReader):
    OFFICE = "urn:oasis:names:tc:opendocument:xmlns:office:1.0}"
    TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0}"

    def paragraphs_in(self, archive):
        parser = self.parser()
        stack, queue = [], collections.deque()
        paragraph, skip, number, size = None, None, 0, 0
        body_seen = False
        def append(value):
            nonlocal size
            amount = len(value.encode("utf-8"))
            size += amount
            self.text_bytes += amount
            if size > DOCUMENT_PARAGRAPH_BYTES or self.text_bytes > DOCUMENT_TEXT_BYTES:
                raise DocumentReadError("documentLimit")
            paragraph.append(value)
        def start(tag, attrs):
            nonlocal paragraph, skip, number, size, body_seen
            stack.append(tag)
            if len(stack) > DOCUMENT_XML_DEPTH:
                raise DocumentReadError("documentLimit")
            if len(stack) == 1 and tag != self.OFFICE + "document-content":
                raise DocumentReadError("documentDamaged")
            if skip is not None:
                return
            if tag in (self.OFFICE + "annotation", *(self.TEXT + name for name in ("tracked-changes", "note", "table-of-content", "alphabetical-index", "bibliography", "user-index", "illustration-index", "table-index", "object-index"))) or tag.startswith("urn:oasis:names:tc:opendocument:xmlns:draw:1.0}"):
                skip = len(stack)
                return
            if tag == self.OFFICE + "text" and stack[-2:] == [self.OFFICE + "body", tag]:
                body_seen = True
            if not body_seen or self.OFFICE + "text" not in stack:
                return
            if tag in (self.TEXT + "p", self.TEXT + "h"):
                if paragraph is not None:
                    raise DocumentReadError("documentDamaged")
                number += 1
                if number > DOCUMENT_PARAGRAPHS:
                    raise DocumentReadError("documentLimit")
                paragraph, size = [], 0
            if paragraph is not None:
                if tag == self.TEXT + "s":
                    count = attrs.get(self.TEXT + "c", "1")
                    if not count.isascii() or not count.isdecimal() or len(count) > 6 or not 1 <= int(count) <= DOCUMENT_PARAGRAPH_BYTES:
                        raise DocumentReadError("documentLimit")
                    append(" " * int(count))
                elif tag in (self.TEXT + "tab", self.TEXT + "line-break"):
                    append("\t" if tag == self.TEXT + "tab" else "\n")
        def data(value):
            if skip is None and paragraph is not None:
                append(value)
        def end(tag):
            nonlocal paragraph, skip
            if skip == len(stack):
                skip = None
            elif skip is None and tag in (self.TEXT + "p", self.TEXT + "h") and paragraph is not None:
                queue.append((dict(kind="odtParagraph", part="content.xml", paragraph=number), "".join(paragraph)))
                paragraph = None
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, data
        for chunk in self.chunks(archive, "content.xml"):
            try:
                parser.Parse(chunk, False)
            except (DocumentReadError, xml.parsers.expat.ExpatError):
                while queue:
                    yield queue.popleft()
                raise
            while queue:
                yield queue.popleft()
        parser.Parse(b"", True)
        if not body_seen:
            raise DocumentReadError("documentDamaged")

    def sections(self, path, deadline):
        with self.package(path) as archive:
            # Der Manifesteintrag ist erforderlich; verschlüsselte Textteile
            # sind auch bei unverschlüsseltem ZIP keine lesbare Projektion.
            manifest = self.metadata(archive, "META-INF/manifest.xml")
            ns = "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}"
            if not manifest or manifest[0][0] != ns + "manifest":
                raise DocumentReadError("documentDamaged")
            if any(tag == ns + "encryption-data" for tag, attrs in manifest):
                raise DocumentReadError("documentEncrypted")
            if not any(tag == ns + "file-entry" and attrs.get(ns + "full-path") == "/" and
                       attrs.get(ns + "media-type") == "application/vnd.oasis.opendocument.text" for tag, attrs in manifest):
                raise DocumentReadError("documentDamaged")
            yield from self.paragraphs_in(archive)


class EPUBHTMLProjection(html.parser.HTMLParser):
    """Begrenzte statische HTML-Projektion; kein CSS-/Script-Interpreter."""
    VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
    BLOCK = frozenset("address article aside blockquote div dl dt dd fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr li main ol p pre section table tbody td th thead tfoot tr ul".split())
    EXCLUDED = frozenset("head script style nav template noscript svg math iframe object".split())

    def __init__(self, reader, part, chapter):
        super().__init__(convert_charrefs=False)
        self.reader, self.part, self.chapter = reader, part, chapter
        self.stack, self.queue, self.text = [], collections.deque(), []
        self.skip = None
        self.body_seen = False
        self.number = self.size = 0
        self.pending_space = False

    def append(self, value, literal=False):
        if self.skip is not None or "body" not in self.stack:
            return
        if not literal and "pre" not in self.stack:
            # ASCII-HTML-Leerraum kollabiert auch über Inline-Grenzen hinweg.
            pieces = re.split(r"([ \t\r\n\f]+)", value)
            for piece in pieces:
                if not piece:
                    continue
                if re.fullmatch(r"[ \t\r\n\f]+", piece):
                    self.pending_space = bool(self.text)
                else:
                    if self.pending_space:
                        self.append(" ", literal=True)
                    self.pending_space = False
                    self.append(piece, literal=True)
            return
        amount = len(value.encode("utf-8"))
        self.size += amount
        self.reader.text_bytes += amount
        if self.size > DOCUMENT_PARAGRAPH_BYTES or self.reader.text_bytes > DOCUMENT_TEXT_BYTES:
            raise DocumentReadError("documentLimit")
        self.text.append(value)

    def flush(self):
        if self.text:
            self.number += 1
            self.reader.paragraphs += 1
            if self.reader.paragraphs > DOCUMENT_PARAGRAPHS:
                raise DocumentReadError("documentLimit")
            self.queue.append((dict(kind="epubParagraph", part=self.part, chapter=self.chapter, paragraph=self.number), "".join(self.text)))
        self.text, self.size, self.pending_space = [], 0, False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if len(self.stack) >= DOCUMENT_XML_DEPTH:
            raise DocumentReadError("documentLimit")
        if (tag == "html" and self.stack) or (tag == "body" and (self.body_seen or self.stack != ["html"])) or (tag in self.BLOCK and "p" in self.stack):
            raise DocumentReadError("documentDamaged")
        if tag == "body":
            self.body_seen = True
        excluded = tag in self.EXCLUDED or "hidden" in attrs or attrs.get("aria-hidden", "").lower() == "true"
        if self.skip is None and tag in self.BLOCK:
            self.flush()
        if tag in self.VOID:
            if tag == "br":
                self.append("\n", literal=True)
            return
        self.stack.append(tag)
        if self.skip is None and excluded:
            # Unterdrückter Inline-Text darf zwei sichtbare Wörter nicht kleben.
            self.flush()
            self.skip = len(self.stack)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in self.VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag in self.VOID or not self.stack or self.stack[-1] != tag:
            raise DocumentReadError("documentDamaged")
        if self.skip == len(self.stack):
            self.skip = None
        elif self.skip is None and (tag in self.BLOCK or tag == "body"):
            self.flush()
        self.stack.pop()

    def handle_data(self, value):
        self.append(value)

    def handle_entityref(self, name):
        value = html.entities.html5.get(name + ";")
        if value is None:
            raise DocumentReadError("documentDamaged")
        self.append(value)

    def handle_charref(self, name):
        try:
            value = chr(int(name[1:], 16) if name.lower().startswith("x") else int(name))
            if value == "\0" or 0xD800 <= ord(value) <= 0xDFFF:
                raise ValueError()
        except (ValueError, OverflowError):
            raise DocumentReadError("documentDamaged")
        self.append(value)

    def handle_decl(self, decl):
        if decl.lower().strip() != "doctype html":
            raise DocumentReadError("documentDamaged")

    def unknown_decl(self, data):
        raise DocumentReadError("documentDamaged")

    def finish(self):
        self.close()
        if self.stack or self.rawdata or not self.body_seen:
            raise DocumentReadError("documentDamaged")
        self.flush()


class EPUBTextReader(ZIPDocumentReader):
    CONTAINER = "urn:oasis:names:tc:opendocument:xmlns:container}"
    OPF = "http://www.idpf.org/2007/opf}"

    def chapters(self, archive):
        nodes = self.metadata(archive, "META-INF/container.xml", paths=True)
        if not nodes or nodes[0][0] != self.CONTAINER + "container":
            raise DocumentReadError("documentDamaged")
        roots = [attrs.get("full-path") for tag, attrs, parents in nodes if parents == (self.CONTAINER + "container", self.CONTAINER + "rootfiles", self.CONTAINER + "rootfile") and
                 attrs.get("media-type") == "application/oebps-package+xml"]
        if not roots:
            raise DocumentReadError("documentDamaged")
        # Bei mehreren Renditions ist die erste Paketbeschreibung maßgeblich.
        root = self.target("", roots[0])
        nodes = self.metadata(archive, root, paths=True)
        if not nodes or nodes[0][0] != self.OPF + "package":
            raise DocumentReadError("documentDamaged")
        manifest, spine = {}, []
        for tag, attrs, parents in nodes:
            if tag == self.OPF + "item":
                if parents != (self.OPF + "package", self.OPF + "manifest", tag):
                    raise DocumentReadError("documentDamaged")
                identifier = attrs.get("id")
                if not identifier or identifier in manifest:
                    raise DocumentReadError("documentDamaged")
                manifest[identifier] = attrs
            elif tag == self.OPF + "itemref":
                if parents != (self.OPF + "package", self.OPF + "spine", tag) or attrs.get("linear", "yes") not in ("yes", "no"):
                    raise DocumentReadError("documentDamaged")
                spine.append(attrs)
        if not spine:
            raise DocumentReadError("documentDamaged")
        for chapter, item in enumerate(spine, 1):
            attrs = manifest.get(item.get("idref"))
            if attrs is None:
                yield chapter, None
                continue
            if item.get("linear", "yes") == "no" or "nav" in attrs.get("properties", "").split():
                continue
            if attrs.get("media-type") not in ("application/xhtml+xml", "text/html"):
                yield chapter, None
                continue
            yield chapter, self.target(posixpath.dirname(root), attrs.get("href"))

    def paragraphs_in(self, archive, part, chapter):
        parser = EPUBHTMLProjection(self, part, chapter)
        decoder = None
        for chunk in self.chunks(archive, part):
            if decoder is None:
                encoding = "utf-8-sig"
                if chunk.startswith((codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE)):
                    encoding = "utf-16"
                else:
                    declaration = re.match(br'<\?xml\s+[^>]*encoding=[\'"]([^\'"]+)', chunk)
                    if declaration:
                        encoding = declaration[1].decode("ascii").lower()
                        if encoding not in ("utf-8", "utf-16", "iso-8859-1", "windows-1252"):
                            raise DocumentReadError("documentReadError")
                decoder = codecs.getincrementaldecoder(encoding)(errors="strict")
            try:
                parser.feed(decoder.decode(chunk))
                if len(parser.rawdata) > DOCUMENT_PARAGRAPH_BYTES:
                    raise DocumentReadError("documentLimit")
            except DocumentReadError:
                while parser.queue:
                    yield parser.queue.popleft()
                raise
            while parser.queue:
                yield parser.queue.popleft()
        if decoder is not None:
            parser.feed(decoder.decode(b"", final=True))
        parser.finish()
        while parser.queue:
            yield parser.queue.popleft()

    def sections(self, path, deadline):
        with self.package(path) as archive:
            if "META-INF/encryption.xml" in archive.namelist():
                # Font-Obfuscation ist für Kapiteltext irrelevant. Verschlüsselte
                # Kapitel werden erst beim angefragten Textteil abgewiesen.
                encryption = self.metadata(archive, "META-INF/encryption.xml")
                encrypted = {self.target("", attrs.get("URI")) for tag, attrs in encryption
                             if tag == "http://www.w3.org/2001/04/xmlenc#}CipherReference"}
            else:
                encrypted = set()
            pending_error = None
            count = 0
            for chapter, part in self.chapters(archive):
                count += 1
                if count > DOCUMENT_PARTS or chapter > DOCUMENT_ZIP_ENTRIES:
                    raise DocumentReadError("documentLimit")
                if time.monotonic() >= deadline:
                    raise DocumentReadError("documentTimeout")
                try:
                    if part is None:
                        raise DocumentReadError("documentReadError")
                    if part in encrypted:
                        raise DocumentReadError("documentEncrypted")
                    yield from self.paragraphs_in(archive, part, chapter)
                except (DocumentReadError, xml.parsers.expat.ExpatError, UnicodeError, KeyError, zipfile.BadZipFile) as err:
                    pending_error = err if isinstance(err, DocumentReadError) else DocumentReadError("documentDamaged")
                    if pending_error.reason in ("documentLimit", "documentTimeout"):
                        raise pending_error
                    if self.on_issue:
                        self.on_issue(pending_error.reason)
            if pending_error:
                raise pending_error


class XLSXTextReader(ZIPDocumentReader):
    """Zellprojektion mit fortsetzbarer Shared-String-Tabelle, ohne Berechnung."""
    NAMESPACES = ("http://schemas.openxmlformats.org/spreadsheetml/2006/main",
                  "http://purl.oclc.org/ooxml/spreadsheetml/main")
    VALUE_KINDS = ("text", "number", "boolean", "date", "cachedString", "cachedNumber", "cachedBoolean", "cachedDate")

    def __init__(self, budget):
        super().__init__(budget)
        self.cells = self.shared_bytes = 0
        self.pending_error = None

    @staticmethod
    def decoded(value):
        # OOXML maskiert Steuerzeichen und auch den maskierenden Unterstrich.
        # Ein Ersetzen in einem Durchlauf bewahrt _x005F_x0041_ als Literal.
        value = re.sub(r"_x([0-9a-fA-F]{4})_", lambda match: chr(int(match[1], 16)), value)
        return value.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "strict")

    @staticmethod
    def address(value):
        match = re.fullmatch(r"([A-Z]{1,3})([1-9][0-9]{0,6})", value or "")
        if match is None:
            raise DocumentReadError("documentDamaged")
        column = 0
        for char in match[1]:
            column = column * 26 + ord(char) - 64
        if column > 16384 or int(match[2]) > 1048576:
            raise DocumentReadError("documentDamaged")
        return int(match[2]), column

    def issue(self, reason):
        if reason in ("documentLimit", "documentTimeout"):
            raise DocumentReadError(reason)
        self.pending_error = DocumentReadError(reason)
        if self.on_issue:
            self.on_issue(reason)

    def workbook(self, archive):
        roots = [target for kind, target in self.relations(archive, "_rels/.rels", "").values() if kind == "officeDocument"]
        if len(roots) != 1 or roots[0] is None:
            raise DocumentReadError("documentDamaged")
        main = roots[0]
        types = self.metadata(archive, "[Content_Types].xml")
        if not any(tag == "http://schemas.openxmlformats.org/package/2006/content-types}Override" and
                   attrs.get("PartName") == "/" + main and attrs.get("ContentType") ==
                   "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml" for tag, attrs in types):
            raise DocumentReadError("documentDamaged")
        directory, name = posixpath.split(main)
        relations = self.relations(archive, posixpath.join(directory, "_rels", name + ".rels"), directory)
        shared = [target for kind, target in relations.values() if kind == "sharedStrings"]
        if len(shared) > 1:
            raise DocumentReadError("documentDamaged")
        nodes = self.metadata(archive, main, paths=True)
        ns = nodes[0][0].rpartition("}")[0] if nodes else ""
        if ns not in self.NAMESPACES or nodes[0][0] != ns + "}workbook":
            raise DocumentReadError("documentDamaged")
        sheets, identifiers, names = [], set(), set()
        for tag, attrs, path in nodes:
            if tag != ns + "}sheet":
                continue
            if path != (ns + "}workbook", ns + "}sheets", tag):
                raise DocumentReadError("documentDamaged")
            sheet = self.decoded(attrs.get("name", ""))
            identifier = next((attrs[prefix.rstrip("/") + "}id"] for prefix in self.REL_PREFIXES if prefix.rstrip("/") + "}id" in attrs), None)
            if not sheet or len(sheet) > 256 or "\0" in sheet or sheet in names or not identifier or identifier in identifiers:
                raise DocumentReadError("documentDamaged")
            identifiers.add(identifier); names.add(sheet)
            sheets.append((sheet, relations.get(identifier)))
        if not sheets:
            raise DocumentReadError("documentDamaged")
        return sheets, shared[0] if shared else None

    def strings_in(self, archive, part):
        parser = self.parser()
        stack, queue = [], collections.deque()
        text, size, count = None, 0, 0
        def local(tag):
            ns, _, name = tag.rpartition("}")
            return name if ns in self.NAMESPACES else None
        def start(tag, attrs):
            nonlocal text, size, count
            name = local(tag); stack.append(name)
            if len(stack) > DOCUMENT_XML_DEPTH:
                raise DocumentReadError("documentLimit")
            if len(stack) == 1 and name != "sst":
                raise DocumentReadError("documentDamaged")
            if name == "si":
                if stack != ["sst", "si"]:
                    raise DocumentReadError("documentDamaged")
                count += 1
                if count > XLSX_SHARED_STRINGS:
                    raise DocumentReadError("documentLimit")
                text, size = [], 0
        def data(value):
            nonlocal size
            if text is not None and (stack == ["sst", "si", "t"] or stack == ["sst", "si", "r", "t"]):
                size += len(value.encode("utf-8"))
                if size > DOCUMENT_PARAGRAPH_BYTES:
                    raise DocumentReadError("documentLimit")
                text.append(value)
        def end(tag):
            nonlocal text
            if stack == ["sst", "si"]:
                value = self.decoded("".join(text))
                self.shared_bytes += len(value.encode("utf-8"))
                if self.shared_bytes > XLSX_SHARED_TEXT_BYTES:
                    raise DocumentReadError("documentLimit")
                queue.append(value); text = None
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, data
        for chunk in self.chunks(archive, part):
            try:
                parser.Parse(chunk, False)
            except (DocumentReadError, xml.parsers.expat.ExpatError, UnicodeError):
                while queue:
                    yield queue.popleft()
                raise
            while queue:
                yield queue.popleft()
        parser.Parse(b"", True)

    def cells_in(self, archive, part):
        parser = self.parser()
        stack, queue, seen = [], collections.deque(), set()
        cell = None
        size = 0
        sheet_data = False
        row_number = None
        def local(tag):
            ns, _, name = tag.rpartition("}")
            return name if ns in self.NAMESPACES else None
        def start(tag, attrs):
            nonlocal cell, size, sheet_data, row_number
            name = local(tag); stack.append(name)
            if len(stack) > DOCUMENT_XML_DEPTH:
                raise DocumentReadError("documentLimit")
            if len(stack) == 1 and name != "worksheet":
                raise DocumentReadError("documentDamaged")
            if name == "sheetData" and stack == ["worksheet", "sheetData"]:
                if sheet_data:
                    raise DocumentReadError("documentDamaged")
                sheet_data = True
            if name == "row" and stack == ["worksheet", "sheetData", "row"]:
                raw = attrs.get("r")
                if raw is not None and (not re.fullmatch(r"[1-9][0-9]{0,6}", raw) or int(raw) > 1048576):
                    raise DocumentReadError("documentDamaged")
                row_number = int(raw) if raw is not None else None
            if name == "c":
                if stack != ["worksheet", "sheetData", "row", "c"]:
                    raise DocumentReadError("documentDamaged")
                self.cells += 1
                if self.cells > XLSX_CELLS:
                    raise DocumentReadError("documentLimit")
                address = attrs.get("r")
                row, column = self.address(address)
                if row_number is not None and row != row_number:
                    raise DocumentReadError("documentDamaged")
                if address in seen:
                    raise DocumentReadError("documentDamaged")
                seen.add(address)
                cell, size = dict(address=address, type=attrs.get("t", "n"), formula=False, value=None, text=None), 0
            if cell is not None and len(stack) == 5:
                if name == "f":
                    if cell["formula"]:
                        raise DocumentReadError("documentDamaged")
                    cell["formula"] = True
                if name in ("v", "is"):
                    key = "value" if name == "v" else "text"
                    if cell[key] is not None:
                        raise DocumentReadError("documentDamaged")
                    cell[key] = []
        def data(value):
            nonlocal size
            if cell is None:
                return
            key = None
            if stack == ["worksheet", "sheetData", "row", "c", "v"]:
                key = "value"
            elif stack in (["worksheet", "sheetData", "row", "c", "is", "t"], ["worksheet", "sheetData", "row", "c", "is", "r", "t"]):
                key = "text"
            if key is not None:
                size += len(value.encode("utf-8"))
                if size > DOCUMENT_PARAGRAPH_BYTES:
                    raise DocumentReadError("documentLimit")
                cell[key].append(value)
        def end(tag):
            nonlocal cell
            if stack == ["worksheet", "sheetData", "row", "c"]:
                queue.append(cell); cell = None
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, data
        for chunk in self.chunks(archive, part):
            try:
                parser.Parse(chunk, False)
            except (DocumentReadError, xml.parsers.expat.ExpatError):
                while queue:
                    yield queue.popleft()
                raise
            while queue:
                yield queue.popleft()
        parser.Parse(b"", True)
        if not sheet_data:
            raise DocumentReadError("documentDamaged")

    def sections(self, path, deadline):
        shared_stream = None
        cache = []
        shared_error = None
        try:
            with self.package(path) as archive:
                sheets, shared = self.workbook(archive)
                def shared_value(raw):
                    nonlocal shared_stream, shared_error
                    if not re.fullmatch(r"[0-9]{1,6}", raw):
                        raise DocumentReadError("documentDamaged")
                    index = int(raw)
                    if index >= XLSX_SHARED_STRINGS:
                        raise DocumentReadError("documentLimit")
                    if index < len(cache):
                        return cache[index]
                    if shared_error:
                        raise shared_error
                    if shared is None:
                        raise DocumentReadError("documentDamaged")
                    if shared_stream is None:
                        shared_stream = self.strings_in(archive, shared)
                    try:
                        while index >= len(cache):
                            cache.append(next(shared_stream))
                    except StopIteration:
                        shared_error = DocumentReadError("documentDamaged")
                        raise shared_error
                    except (DocumentReadError, xml.parsers.expat.ExpatError, UnicodeError) as err:
                        shared_error = err if isinstance(err, DocumentReadError) else DocumentReadError("documentDamaged")
                        raise shared_error
                    return cache[index]
                for sheet_index, (sheet, relation) in enumerate(sheets, 1):
                    if sheet_index > DOCUMENT_PARTS:
                        raise DocumentReadError("documentLimit")
                    if time.monotonic() >= deadline:
                        raise DocumentReadError("documentTimeout")
                    try:
                        if relation is None or relation[0] != "worksheet" or relation[1] is None:
                            raise DocumentReadError("documentReadError")
                        part = relation[1]
                        for cell in self.cells_in(archive, part):
                            try:
                                kind, formula = cell["type"], cell["formula"]
                                if kind not in ("s", "str", "inlineStr", "n", "b", "d"):
                                    raise DocumentReadError("documentReadError")
                                if kind != "inlineStr" and cell["text"] is not None:
                                    raise DocumentReadError("documentDamaged")
                                raw = "".join(cell["value"]) if cell["value"] is not None else None
                                if kind == "inlineStr":
                                    if formula or cell["text"] is None or raw is not None:
                                        raise DocumentReadError("documentDamaged")
                                    text, value_kind = self.decoded("".join(cell["text"])), "text"
                                elif raw is None:
                                    if formula:
                                        raise DocumentReadError("documentReadError")
                                    continue
                                elif kind in ("s", "str"):
                                    text = shared_value(raw) if kind == "s" else self.decoded(raw)
                                    value_kind = "cachedString" if formula else "text"
                                elif kind == "n":
                                    if not re.fullmatch(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?", raw):
                                        raise DocumentReadError("documentReadError")
                                    text, value_kind = raw, "cachedNumber" if formula else "number"
                                elif kind == "b" and raw in ("0", "1"):
                                    text, value_kind = ("TRUE" if raw == "1" else "FALSE"), "cachedBoolean" if formula else "boolean"
                                elif kind == "d":
                                    try:
                                        datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
                                    except ValueError:
                                        raise DocumentReadError("documentReadError")
                                    text, value_kind = raw, "cachedDate" if formula else "date"
                                else:
                                    raise DocumentReadError("documentReadError")
                                self.text_bytes += len(text.encode("utf-8"))
                                if self.text_bytes > DOCUMENT_TEXT_BYTES:
                                    raise DocumentReadError("documentLimit")
                                yield dict(kind="xlsxCell", part=part, sheet=sheet, sheetIndex=sheet_index, cell=cell["address"], valueKind=value_kind), text
                            except (DocumentReadError, UnicodeError) as err:
                                self.issue(err.reason if isinstance(err, DocumentReadError) else "documentDamaged")
                    except (DocumentReadError, xml.parsers.expat.ExpatError, UnicodeError, zipfile.BadZipFile) as err:
                        self.issue(err.reason if isinstance(err, DocumentReadError) else "documentDamaged")
                if self.pending_error:
                    raise self.pending_error
        finally:
            if shared_stream is not None:
                shared_stream.close()


class PPTXTextReader(ZIPDocumentReader):
    """Gespeicherter Folientext in Präsentations-/Objektreihenfolge, ohne Layout."""
    PRESENTATION = ("http://schemas.openxmlformats.org/presentationml/2006/main",
                    "http://purl.oclc.org/ooxml/presentationml/main")
    DRAWING = ("http://schemas.openxmlformats.org/drawingml/2006/main",
               "http://purl.oclc.org/ooxml/drawingml/main")

    def __init__(self, budget):
        super().__init__(budget)
        self.objects = self.cells = 0
        self.pending_error = None

    def issue(self, reason):
        if reason in ("documentLimit", "documentTimeout"):
            raise DocumentReadError(reason)
        self.pending_error = DocumentReadError(reason)
        if self.on_issue:
            self.on_issue(reason)

    @classmethod
    def local(cls, tag):
        ns, _, name = tag.rpartition("}")
        if ns in cls.PRESENTATION:
            return "p:" + name
        if ns in cls.DRAWING:
            return "a:" + name
        return None

    def presentation(self, archive):
        roots = [target for kind, target in self.relations(archive, "_rels/.rels", "").values() if kind == "officeDocument"]
        if len(roots) != 1 or roots[0] is None:
            raise DocumentReadError("documentDamaged")
        main = roots[0]
        types = self.metadata(archive, "[Content_Types].xml")
        if not any(tag == "http://schemas.openxmlformats.org/package/2006/content-types}Override" and
                   attrs.get("PartName") == "/" + main and attrs.get("ContentType") ==
                   "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml" for tag, attrs in types):
            raise DocumentReadError("documentDamaged")
        directory, name = posixpath.split(main)
        relations = self.relations(archive, posixpath.join(directory, "_rels", name + ".rels"), directory)
        nodes = self.metadata(archive, main, paths=True)
        if not nodes or self.local(nodes[0][0]) != "p:presentation":
            raise DocumentReadError("documentDamaged")
        slides, seen = [], set()
        for tag, attrs, path in nodes:
            if self.local(tag) == "p:sldId":
                if [self.local(value) for value in path] != ["p:presentation", "p:sldIdLst", "p:sldId"]:
                    raise DocumentReadError("documentDamaged")
                identifier = next((attrs.get(prefix.rstrip("/") + "}id") for prefix in self.REL_PREFIXES
                                   if prefix.rstrip("/") + "}id" in attrs), None)
                if not identifier or identifier in seen:
                    raise DocumentReadError("documentDamaged")
                seen.add(identifier)
                slides.append(relations.get(identifier))
        return slides

    def paragraphs_in(self, archive, part, slide):
        parser = self.parser()
        stack, objects, seen, queue = [], [], set(), collections.deque()
        paragraph = None
        paragraph_path = None
        text_size = 0
        tree_seen = False
        def identifier(value):
            if not re.fullmatch(r"[+]?[0-9]{1,10}", value.strip()):
                raise DocumentReadError("documentDamaged")
            number = int(value)
            if number > 4294967295 or number in seen:
                raise DocumentReadError("documentDamaged")
            seen.add(number)
            return str(number)
        def start(tag, attrs):
            nonlocal paragraph, paragraph_path, text_size, tree_seen
            name = self.local(tag)
            stack.append(name)
            if len(stack) > DOCUMENT_XML_DEPTH:
                raise DocumentReadError("documentLimit")
            if len(stack) == 1 and name != "p:sld":
                raise DocumentReadError("documentDamaged")
            if stack == ["p:sld", "p:cSld", "p:spTree"]:
                if tree_seen:
                    raise DocumentReadError("documentDamaged")
                tree_seen = True
            if name in ("p:sp", "p:graphicFrame", "p:grpSp", "p:pic", "p:cxnSp") and (stack[:-1] == ["p:sld", "p:cSld", "p:spTree"] or (objects and objects[-1]["type"] == "p:grpSp" and len(stack) == objects[-1]["depth"] + 1)):
                if stack[:3] != ["p:sld", "p:cSld", "p:spTree"]:
                    return
                self.objects += 1
                if self.objects > PPTX_OBJECTS:
                    raise DocumentReadError("documentLimit")
                objects.append(dict(depth=len(stack), type=name, id=None, paragraph=0, row=0, column=0, bodies=0, table=False))
            if stack == ["p:sld", "p:cSld", "p:spTree", "p:nvGrpSpPr", "p:cNvPr"]:
                identifier(attrs.get("id", ""))
            if not objects:
                return
            obj = objects[-1]
            relative = stack[obj["depth"]:]
            nonvisual = {"p:sp": "p:nvSpPr", "p:graphicFrame": "p:nvGraphicFramePr", "p:grpSp": "p:nvGrpSpPr", "p:pic": "p:nvPicPr", "p:cxnSp": "p:nvCxnSpPr"}[obj["type"]]
            if relative == [nonvisual, "p:cNvPr"]:
                if obj["id"] is not None:
                    raise DocumentReadError("documentDamaged")
                obj["id"] = identifier(attrs.get("id", ""))
            table_path = ["a:graphic", "a:graphicData", "a:tbl"]
            if obj["type"] == "p:graphicFrame" and relative == ["a:graphic", "a:graphicData"]:
                obj["table"] = attrs.get("uri") in tuple(ns + "/table" for ns in self.DRAWING)
            if obj["type"] == "p:graphicFrame" and relative == table_path and not obj["table"]:
                raise DocumentReadError("documentDamaged")
            if obj["type"] == "p:graphicFrame" and relative == table_path + ["a:tr"]:
                obj["row"] += 1
                if obj["row"] > PPTX_TABLE_ROWS:
                    raise DocumentReadError("documentLimit")
                obj["column"] = 0
            if obj["type"] == "p:graphicFrame" and relative == table_path + ["a:tr", "a:tc"]:
                self.cells += 1
                if self.cells > PPTX_TABLE_CELLS:
                    raise DocumentReadError("documentLimit")
                obj["column"] += 1
                obj["paragraph"] = obj["bodies"] = 0
            if (obj["type"] == "p:sp" and relative == ["p:txBody"]) or (obj["type"] == "p:graphicFrame" and relative == table_path + ["a:tr", "a:tc", "a:txBody"]):
                obj["bodies"] += 1
                if obj["bodies"] > 1:
                    raise DocumentReadError("documentDamaged")
            shape_text = obj["type"] == "p:sp" and relative == ["p:txBody", "a:p"]
            table_text = obj["type"] == "p:graphicFrame" and relative == table_path + ["a:tr", "a:tc", "a:txBody", "a:p"]
            if shape_text or table_text:
                if obj["id"] is None or paragraph is not None:
                    raise DocumentReadError("documentDamaged")
                self.paragraphs += 1
                obj["paragraph"] += 1
                if self.paragraphs > DOCUMENT_PARAGRAPHS:
                    raise DocumentReadError("documentLimit")
                position = dict(kind="pptxParagraph", part=part, slide=slide, objectID=obj["id"], objectKind="shape" if shape_text else "table", paragraph=obj["paragraph"])
                if table_text:
                    position.update(row=obj["row"], column=obj["column"])
                paragraph, paragraph_path, text_size = (position, []), tuple(stack), 0
            if paragraph is not None and tuple(stack) == paragraph_path + ("a:br",):
                append("\n")
        def append(value):
            nonlocal text_size
            size = len(value.encode("utf-8"))
            text_size += size
            self.text_bytes += size
            if text_size > DOCUMENT_PARAGRAPH_BYTES or self.text_bytes > DOCUMENT_TEXT_BYTES:
                raise DocumentReadError("documentLimit")
            paragraph[1].append(value)
        def data(value):
            if paragraph is not None and tuple(stack) == paragraph_path + ("a:r", "a:t"):
                append(value)
        def end(tag):
            nonlocal paragraph, paragraph_path
            if paragraph is not None and tuple(stack) == paragraph_path:
                position, runs = paragraph
                queue.append((position, "".join(runs)))
                paragraph = paragraph_path = None
            if objects and objects[-1]["type"] == "p:graphicFrame" and stack[objects[-1]["depth"]:] == ["a:graphic", "a:graphicData", "a:tbl", "a:tr", "a:tc"] and objects[-1]["bodies"] != 1:
                raise DocumentReadError("documentDamaged")
            if objects and objects[-1]["depth"] == len(stack):
                obj = objects.pop()
                if obj["id"] is None:
                    raise DocumentReadError("documentDamaged")
            stack.pop()
        parser.StartElementHandler, parser.EndElementHandler, parser.CharacterDataHandler = start, end, data
        for chunk in self.chunks(archive, part):
            try:
                parser.Parse(chunk, False)
            except (DocumentReadError, xml.parsers.expat.ExpatError):
                while queue:
                    yield queue.popleft()
                raise
            while queue:
                yield queue.popleft()
        parser.Parse(b"", True)
        if not tree_seen:
            raise DocumentReadError("documentDamaged")

    def sections(self, path, deadline):
        with self.package(path) as archive:
            for number, relation in enumerate(self.presentation(archive), 1):
                if number > PPTX_SLIDES:
                    raise DocumentReadError("documentLimit")
                if time.monotonic() >= deadline:
                    raise DocumentReadError("documentTimeout")
                try:
                    if relation is None or relation[0] != "slide" or relation[1] is None:
                        raise DocumentReadError("documentReadError")
                    yield from self.paragraphs_in(archive, relation[1], number)
                except (DocumentReadError, xml.parsers.expat.ExpatError, UnicodeError, zipfile.BadZipFile) as err:
                    self.issue(err.reason if isinstance(err, DocumentReadError) else "documentDamaged")
            if self.pending_error:
                raise self.pending_error


PACKAGE_DOCUMENT_READERS = {".docx": DOCXTextReader, ".odt": ODTTextReader, ".epub": EPUBTextReader, ".xlsx": XLSXTextReader, ".pptx": PPTXTextReader}
PACKAGE_DOCUMENT_ENCODINGS = {".docx": DOCX_ENCODING, ".odt": ODT_ENCODING, ".epub": EPUB_ENCODING, ".xlsx": XLSX_ENCODING, ".pptx": PPTX_ENCODING}
PACKAGE_QUERY_READERS = {"docx-v1": DOCXTextReader, "odt-v1": ODTTextReader, "epub-v1": EPUBTextReader, "xlsx-v1": XLSXTextReader, "pptx-v1": PPTXTextReader}


class PDFTextReader:
    """Ein wiederverwendeter Datenhelfer; jede Seite wird einzeln angefordert.

    stdout ist größen-/zeitbegrenzt. PDFKit-Diagnosen gehen nicht in eine
    ungelesene stderr-Pipe; definierte Fehler kommen über das Protokoll.
    """
    unavailable_reason = "documentHelperUnavailable"
    read_error_reason = "documentReadError"
    limit_reason = "documentLimit"
    timeout_reason = "documentTimeout"
    accepted_reasons = frozenset(("documentEncrypted", "documentDamaged", "documentLimit", "documentReadError"))

    def __init__(self, path):
        self.path = path
        self.process = None
        self.documents = 0

    def exchange(self, request, deadline):
        if self.process is None:
            if not self.path:
                raise DocumentReadError(self.unavailable_reason)
            try:
                self.process = subprocess.Popen([self.path], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
            except OSError:
                raise DocumentReadError(self.unavailable_reason)
        try:
            payload = json.dumps(request, ensure_ascii=True).encode("ascii") + b"\n"
            if len(payload) > 65536:
                raise DocumentReadError(self.read_error_reason)
            # Auch ein weggebrochener/ersetzter Helfer darf beim Schreiben
            # nicht blockieren. Die Pipe bleibt für beide Richtungen nonblocking.
            os.set_blocking(self.process.stdin.fileno(), False)
            offset = 0
            while offset < len(payload):
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([], [self.process.stdin], [], remaining)[1]:
                    raise DocumentReadError(self.timeout_reason)
                offset += os.write(self.process.stdin.fileno(), payload[offset:])
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                    raise DocumentReadError(self.timeout_reason)
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise DocumentReadError(self.read_error_reason)
                data.extend(chunk)
                if len(data) > 2 * 1024 * 1024:
                    raise DocumentReadError(self.limit_reason)
                if b"\n" in chunk:
                    if not data.endswith(b"\n") or data.count(b"\n") != 1:
                        raise DocumentReadError(self.read_error_reason)
                    break
            response = json.loads(data)
            if not isinstance(response, dict) or type(response.get("schemaVersion")) is not int or response["schemaVersion"] != 1 \
                    or type(response.get("ok")) is not bool:
                raise DocumentReadError(self.read_error_reason)
            if not response["ok"]:
                reason = response.get("reason")
                if reason not in self.accepted_reasons:
                    reason = self.read_error_reason
                raise DocumentReadError(reason)
            return response
        except (OSError, ValueError):
            self.close()
            raise DocumentReadError(self.read_error_reason)

    def pages(self, path, deadline):
        if self.documents >= 32:
            self.close()
        self.documents += 1
        try:
            response = self.exchange(dict(operation="open", path=os.path.abspath(path)), deadline)
            count = response.get("pageCount")
            if type(count) is not int or not 0 < count <= 10000000:
                raise DocumentReadError("documentDamaged")
            total = 0
            any_text = False
            for index in range(min(count, DOCUMENT_PAGES)):
                response = self.exchange(dict(operation="page", index=index), deadline)
                text = response.get("text")
                if type(response.get("page")) is not int or response["page"] != index + 1 or not isinstance(text, str):
                    raise DocumentReadError("documentReadError")
                try:
                    size = len(text.encode("utf-8"))
                except UnicodeError:
                    raise DocumentReadError("documentReadError")
                total += size
                if size > DOCUMENT_PAGE_BYTES or total > DOCUMENT_TEXT_BYTES:
                    raise DocumentReadError("documentLimit")
                any_text |= bool(text.strip())
                yield index + 1, text
            if count > DOCUMENT_PAGES:
                raise DocumentReadError("documentLimit")
            if not any_text:
                raise DocumentReadError("documentNoText")
        finally:
            if self.process is not None:
                try:
                    self.exchange(dict(operation="close"), min(deadline, time.monotonic() + 0.1))
                except DocumentReadError:
                    self.close()

    def close(self):
        process, self.process = self.process, None
        self.documents = 0
        if process is None:
            return
        try:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=0.2)
        finally:
            process.stdin.close()
            process.stdout.close()


def validated_ocr_blocks(blocks, position):
    total = 0
    sections = []
    for index, block in enumerate(blocks, 1):
        if not isinstance(block, dict) or set(block) != {"block", "text", "confidence", "region"} \
                or type(block["block"]) is not int or block["block"] != index \
                or not isinstance(block["text"], str) or not block["text"]:
            raise DocumentReadError("ocrReadError")
        confidence, region = block["confidence"], block["region"]
        if type(confidence) not in (int, float) or not math.isfinite(confidence) or not 0.5 <= confidence <= 1 \
                or not isinstance(region, list) or len(region) != 4 \
                or any(type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1 for value in region) \
                or region[2] <= 0 or region[3] <= 0 or region[0] + region[2] > 1.000001 or region[1] + region[3] > 1.000001:
            raise DocumentReadError("ocrReadError")
        try:
            size = len(block["text"].encode("utf-8"))
        except UnicodeError:
            raise DocumentReadError("ocrReadError")
        total += size
        if size > 65536 or total > OCR_TEXT_BYTES:
            raise DocumentReadError("ocrLimit")
        sections.append((dict(position, block=index, confidence=confidence, region=region), block["text"]))
    return sections


class OCRTextReader(PDFTextReader):
    unavailable_reason = "ocrHelperUnavailable"
    read_error_reason = "ocrReadError"
    limit_reason = "ocrLimit"
    timeout_reason = "ocrTimeout"
    accepted_reasons = OCR_REASONS

    def sections(self, path, deadline):
        if self.documents >= 32:
            self.close()
        self.documents += 1
        try:
            response = self.exchange(dict(operation="image", path=os.path.abspath(path)), deadline)
            blocks = response.get("blocks")
            if set(response) != {"schemaVersion", "ok", "reader", "blocks"} or response["reader"] != "vision-image-v1" \
                    or not isinstance(blocks, list) or len(blocks) > OCR_BLOCKS:
                raise DocumentReadError("ocrReadError")
            sections = validated_ocr_blocks(blocks, dict(kind="imageOCR"))
            if not blocks:
                raise DocumentReadError("ocrNoText")
            yield from sections
        except BaseException:
            self.close()
            raise


class PDFOCRTextReader(PDFTextReader):
    accepted_reasons = PDFTextReader.accepted_reasons | OCR_REASONS | {"pdfOCRLimit"}

    def sections(self, path, deadline):
        if self.documents >= 32:
            self.close()
        self.documents += 1
        pending = None
        def issue(reason):
            nonlocal pending
            pending = DocumentReadError(reason)
            callback = getattr(self, "on_issue", None)
            if callback is not None:
                callback(reason)
        def progress(stage, page, count):
            callback = getattr(self, "on_progress", None)
            if callback is not None:
                callback(stage, page, count)
        try:
            opened = self.exchange(dict(operation="open", path=os.path.abspath(path)), deadline)
            count = opened.get("pageCount")
            if type(count) is not int or not 0 < count <= 10000000:
                raise DocumentReadError("documentDamaged")
            if type(opened.get("pdfOCRCapability")) is not int or opened["pdfOCRCapability"] != 1:
                raise DocumentReadError("ocrHelperUnavailable")
            total = 0
            for index in range(min(count, PDF_OCR_PAGES)):
                progress("pdfText", index + 1, count)
                response = self.exchange(dict(operation="page", index=index), deadline)
                text = response.get("text")
                if type(response.get("page")) is not int or response["page"] != index + 1 or not isinstance(text, str):
                    raise DocumentReadError("documentReadError")
                if text.strip():
                    try:
                        size = len(text.encode("utf-8"))
                    except UnicodeError:
                        raise DocumentReadError("documentReadError")
                    if size > DOCUMENT_PAGE_BYTES:
                        raise DocumentReadError("documentLimit")
                    sections = [(dict(kind="pdfTextPage", page=index + 1), text)]
                else:
                    progress("pdfOCR", index + 1, count)
                    try:
                        response = self.exchange(dict(operation="ocrPage", index=index), deadline)
                        if set(response) != {"schemaVersion", "ok", "reader", "page", "blocks"} or response["reader"] != "pdfkit-vision-v1" \
                                or type(response["page"]) is not int or response["page"] != index + 1 \
                                or not isinstance(response["blocks"], list) or len(response["blocks"]) > OCR_BLOCKS:
                            raise DocumentReadError("ocrReadError")
                        sections = validated_ocr_blocks(response["blocks"], dict(kind="pdfOCR", page=index + 1))
                        if not sections:
                            issue("ocrNoText")
                    except DocumentReadError as error:
                        if error.reason in {"pdfOCRLimit", "ocrNoText", "ocrDamaged"}:
                            issue(error.reason)
                            continue
                        raise
                total += sum(len(text.encode("utf-8")) for _, text in sections)
                if total > DOCUMENT_TEXT_BYTES:
                    raise DocumentReadError("documentLimit")
                yield from sections
            if count > PDF_OCR_PAGES:
                issue("pdfOCRLimit")
            if pending is not None:
                raise pending
        finally:
            if self.process is not None:
                try:
                    self.exchange(dict(operation="close"), min(deadline, time.monotonic() + 0.1))
                except DocumentReadError:
                    self.close()


def document_sections(reader, path, deadline):
    if isinstance(reader, (ZIPDocumentReader, OCRTextReader, PDFOCRTextReader)):
        yield from reader.sections(path, deadline)
    else:
        for page, text in reader.pages(path, deadline):
            yield dict(kind="pdfPage", page=page), text


def document_line_pieces(reader, path, deadline, **options):
    base = 0
    for position, text in document_sections(reader, path, deadline):
        last = 0
        for number, raw, complete, ends_line in iter_line_pieces(
                [text.encode("utf-8")], text_encoding="utf-8", **options):
            last = number
            yield base + number, raw, complete, ends_line, dict(position, line=number)
        base += last


FINDER_ATTRIBUTES = {
    "finderTags": "com.apple.metadata:_kMDItemUserTags",
    "finderComment": "com.apple.metadata:kMDItemFinderComment",
}
MAX_FINDER_ATTRIBUTE_BYTES = 65536
MAX_FINDER_TAGS = 256
MAX_FINDER_TAG_BYTES = 1024
MAX_FINDER_COMMENT_BYTES = 32768
MAX_FINDER_SNAPSHOT_BYTES = 256 * 1024
_finder_getxattr = None


class FinderMetadataLimit(ValueError):
    pass


def finder_xattr(path, name):
    # System-Python auf macOS hat kein os.getxattr. Der native Aufruf liest
    # Attribute ohne Dateiinhalt und folgt keinem symbolischen Link.
    import ctypes
    global _finder_getxattr
    if _finder_getxattr is None:
        library = ctypes.CDLL(None, use_errno=True)
        getter = library.getxattr
        getter.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                           ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        getter.restype = ctypes.c_ssize_t
        _finder_getxattr = getter
    arguments = os.fsencode(path), name.encode("ascii")
    size = _finder_getxattr(*arguments, None, 0, 0, 1)
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size > MAX_FINDER_ATTRIBUTE_BYTES:
        raise FinderMetadataLimit("Finder-Attribut überschreitet 64 KiB")
    if size == 0:
        return b""
    buffer = ctypes.create_string_buffer(size)
    count = _finder_getxattr(*arguments, buffer, size, 0, 1)
    if count < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if count != size:
        raise OSError("Finder-Attribut änderte sich beim Lesen")
    return buffer.raw[:count]


def finder_plist(data):
    import plistlib
    if len(data) > MAX_FINDER_ATTRIBUTE_BYTES:
        raise FinderMetadataLimit("Finder-Attribut überschreitet 64 KiB")
    if data.startswith(b"bplist"):
        if not data.startswith(b"bplist00") or len(data) < 40:
            raise ValueError("ungültiger binärer Finder-Plist")
        offsets, references, objects, top, table = struct.unpack(">6xBBQQQ", data[-32:])
        # Ein kleiner Eingabepuffer darf keine riesige Objekttabelle allozieren.
        if objects > 1024:
            raise FinderMetadataLimit("Finder-Plist enthält zu viele Objekte")
        if (offsets not in (1, 2, 4, 8) or references not in (1, 2, 4, 8)
                or not 0 <= top < objects or table < 8
                or table + objects * offsets > len(data) - 32):
            raise ValueError("ungültige Finder-Plist-Tabelle")
        for index in range(objects):
            start = table + index * offsets
            if not 8 <= int.from_bytes(data[start:start + offsets], "big") < table:
                raise ValueError("ungültiger Finder-Plist-Offset")
    try:
        return plistlib.loads(data)
    except xml.parsers.expat.ExpatError as error:
        raise ValueError("ungültiger XML-Finder-Plist") from error


def finder_tag(raw):
    if not isinstance(raw, str) or not raw or "\0" in raw:
        raise ValueError("Finder-Tag ist kein Name")
    if len(raw.encode("utf-8")) > MAX_FINDER_TAG_BYTES:
        raise FinderMetadataLimit("Finder-Tag überschreitet 1024 UTF-8-Bytes")
    name, color = raw, None
    if len(raw) >= 2 and raw[-2] == "\n" and raw[-1] in "01234567":
        name, color = raw[:-2], int(raw[-1])
    if not name:
        raise ValueError("Finder-Tag hat keinen Namen")
    return dict(name=name, color=color, raw=raw)


def parse_finder_attribute(field, data):
    if field not in FINDER_ATTRIBUTES:
        raise ValueError("unbekanntes Finder-Feld")
    value = finder_plist(data)
    if field == "finderComment":
        if not isinstance(value, str) or "\0" in value:
            raise ValueError("Finder-Kommentar ist kein Text")
        if len(value.encode("utf-8")) > MAX_FINDER_COMMENT_BYTES:
            raise FinderMetadataLimit("Finder-Kommentar überschreitet 32 KiB")
        return dict(status="available", value=value)
    if not isinstance(value, list):
        raise ValueError("Finder-Tags sind keine Liste")
    if len(value) > MAX_FINDER_TAGS:
        raise FinderMetadataLimit("Finder-Tags überschreiten 256 Werte")
    return dict(status="available", values=[finder_tag(raw) for raw in value])


def validate_finder_snapshot(value):
    if (not isinstance(value, dict) or set(value) != {"schemaVersion", "sourceGeneration", "fields"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or not isinstance(value["fields"], dict) or not set(value["fields"]).issubset(FINDER_ATTRIBUTES)):
        raise ValueError("ungültiger Finder-Snapshot")
    if len(json.dumps(value, ensure_ascii=False).encode("utf-8")) > MAX_FINDER_SNAPSHOT_BYTES:
        raise ValueError("Finder-Snapshot überschreitet 256 KiB")
    generation = value["sourceGeneration"]
    if generation is not None:
        keys = {"device", "inode", "size", "modifiedNS", "changedNS"}
        if (not isinstance(generation, dict) or set(generation) != keys
                or any(not isinstance(raw, str) or len(raw) > 32 or re.fullmatch(r"-?[0-9]+", raw) is None
                       or str(int(raw)) != raw for raw in generation.values())
                or any(int(generation[key]) < 0 for key in ("device", "inode", "size"))):
            raise ValueError("ungültige Finder-Quellengeneration")
    unknown = {"absent", "unreadable", "invalid", "limited", "unsupported", "notApplicable", "sourceChanged"}
    for field, record in value["fields"].items():
        if not isinstance(record, dict) or not isinstance(record.get("status"), str):
            raise ValueError("ungültiges Finder-Feld")
        if record["status"] in unknown:
            if set(record) != {"status"}:
                raise ValueError("unbekanntes Finder-Feld enthält einen Wert")
        elif record["status"] == "available" and generation is not None:
            if field == "finderTags":
                if set(record) != {"status", "values"} or not isinstance(record["values"], list) or len(record["values"]) > MAX_FINDER_TAGS:
                    raise ValueError("ungültiger Finder-Tagbestand")
                for tag in record["values"]:
                    if (not isinstance(tag, dict) or set(tag) != {"name", "color", "raw"}
                            or (tag["color"] is not None and type(tag["color"]) is not int)
                            or finder_tag(tag["raw"]) != tag):
                        raise ValueError("Finder-Tagname/Farbe widersprechen dem Original")
            elif (set(record) != {"status", "value"} or not isinstance(record["value"], str)
                  or "\0" in record["value"] or len(record["value"].encode("utf-8")) > MAX_FINDER_COMMENT_BYTES):
                raise ValueError("ungültiger Finder-Kommentar")
        else:
            raise ValueError("Finder-Wert ohne gültigen Status oder Quellengeneration")
    return value


def finder_generation_matches_facts(generation, size, modified):
    return ((size is None or int(generation["size"]) == size)
            and (modified is None or abs(int(generation["modifiedNS"]) / 1e9 - modified) <= math.ulp(modified)))


def read_finder_metadata(path, fields):
    fields = tuple(dict.fromkeys(fields))
    if any(field not in FINDER_ATTRIBUTES for field in fields):
        raise ValueError("unbekanntes Finder-Feld")
    result = dict(schemaVersion=1, sourceGeneration=None, fields={})
    if not fields:
        return result
    def unavailable(status):
        result["fields"] = {field: dict(status=status) for field in fields}
        return result
    if sys.platform != "darwin":
        return unavailable("unsupported")
    try:
        before = os.lstat(path)
    except OSError:
        return unavailable("unreadable")
    if not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode)):
        return unavailable("unsupported")
    generation = source_generation(status=before)
    result["sourceGeneration"] = generation
    for field in fields:
        try:
            result["fields"][field] = parse_finder_attribute(field, finder_xattr(path, FINDER_ATTRIBUTES[field]))
        except FinderMetadataLimit:
            result["fields"][field] = dict(status="limited")
        except OSError as error:
            result["fields"][field] = dict(status="absent" if error.errno == 93 else "unreadable")
        except (ValueError, TypeError, OverflowError, RecursionError, UnicodeError):
            result["fields"][field] = dict(status="invalid")
    try:
        after = os.lstat(path)
    except OSError:
        return unavailable("sourceChanged")
    if source_generation(status=after) != generation:
        return unavailable("sourceChanged")
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > MAX_FINDER_SNAPSHOT_BYTES:
        return unavailable("limited")
    return result


class FileProbe:
    """Eine Datei oder ein Archiv-Eintrag, der teure Fragen EINMAL beantwortet.

    Ein Lauf mit drei Kriterien (Name, Maße, Metadaten) fragt exiftool
    trotzdem nur einmal je Datei und liest den Bildkopf nur einmal. Die
    Antworten bleiben gemerkt, bis der Treffer ausgegeben ist."""

    def __init__(self, search, label, name, open_stream, chunker,
                 filesystem_path, size=None, in_archive=False,
                 modified=None, is_dir=False, relative_path=None):
        self.search = search
        self.label = label                    # Anzeigepfad für Warnungen
        self.name = name                      # Dateiname (nur die letzte
                                              # Komponente)
        self.open_stream = open_stream        # liefert einen frischen
                                              # lesbaren Datenstrom
        self.chunker = chunker                # chunker(handle, free_bytes)
                                              # → Byte-Häppchen (Budget!)
        self.filesystem_path = filesystem_path
        self.in_archive = in_archive
        self.is_dir = is_dir
        self.relative_path = relative_path
        self.criteria_evidence = None
        self.decoder_info = {}
        self.document_position = None
        self.document_positions = {}
        self.criteria_phase = math.inf
        self.criteria_results = {}
        self._criteria_content = None
        self.content_available = not is_dir
        self.local_content_checked = False
        self.peek_content = False
        # Archivfakten stehen schon im Katalog, lokale Fakten werden erst
        # bei Bedarf gelesen. Ein Ordner hat keine Dateigröße in diesem
        # Suchvertrag; st_size des Verzeichnisses ist nicht seine Datenmenge.
        self._facts = MISSING
        if in_archive:
            self._set_facts(size, modified, None)
        self.metadata_hit = None              # (Feld, Wert) bei Treffer
        self.metadata_hits = []               # je Begriff (Feld, Wert)
        self.dimension_bytes = 0              # so viele Bytes hat der
                                              # Maß-Leser schon gegen das
                                              # Archivbudget gezählt
        self._dimensions = MISSING
        self._metadata = MISSING
        self._finder_metadata = MISSING
        self._content_lines = MISSING
        self.preview_generation = getattr(search, "preview_source_generation", None)
        if search.document_mode and self.preview_generation is None:
            self.preview_generation = source_generation(filesystem_path)
        self.content_preview = (ContentPreviewCapture(self)
                                if getattr(search, "content_preview", False)
                                and search.preview_remaining > 0 else None)

    def local_content_allowed(self, record=True):
        if self.search.local_only and not self.in_archive:
            reason = local_content_reason(self.filesystem_path)
            if reason is not None:
                if record and not self.local_content_checked:
                    self.search.report_warning("%s: %s" % (self.label, REPORT_REASONS[reason][1]),
                                               reason=reason, path=self.label)
                    self.local_content_checked = True
                return False
        return True

    @contextlib.contextmanager
    def content_stream(self):
        if not self.local_content_allowed(record=False):
            raise LocalContentError(local_content_reason(self.filesystem_path) or "localContentUnknown")
        with self.open_stream() as stream:
            if self.content_preview is not None and not self.in_archive:
                current = source_generation(status=os.fstat(stream.fileno()))
                self.content_preview.changed |= current != self.preview_generation
            try:
                yield stream
            finally:
                if self.content_preview is not None and not self.in_archive:
                    current = source_generation(status=os.fstat(stream.fileno()))
                    self.content_preview.changed |= current != self.preview_generation

    @property
    def extension(self):
        return os.path.splitext(self.name)[1].lower()

    def facts(self):
        """(Größe, Änderungszeit, Erstellungszeit), einmal für Filter UND Ausgabe."""
        if self._facts is MISSING:
            if self.search.report is None:
                facts = self.search.file_facts(self.filesystem_path)
            else:
                facts = self.search.file_facts(self.filesystem_path, onerror=lambda err:
                    self.search.omission(report_error_reason(err), self.label))
            self._set_facts(*facts)
        return self._facts

    def _set_facts(self, size, modified, created):
        """Ungültige Fakten sind unbekannt — gleichermaßen für Filter und JSON."""
        if self.is_dir or (size is not None and size < 0):
            size = None
        # PAX-Zeitfelder erlauben NaN/inf. Sie sind weder Zeitpunkte noch
        # gültige JSON-Zahlen; nur im Filter zu prüfen verlöre die Treffer
        # ohne Datumfilter später beim JSON-Parser der Apps.
        self._facts = tuple(None if isinstance(value, float) and not math.isfinite(value)
                            else value for value in (size, modified, created))

    def dimensions(self):
        """(Breite, Höhe) oder None. Erst der eingebaute Leser, dann — nur
        für Formate, die er nicht kennt — exiftool."""
        if self._dimensions is MISSING:
            if not self.local_content_allowed():
                return None
            self._dimensions = None
            with self.open_stream() as handle:
                # Über den Chunker statt direkt über den Strom: Der Bildkopf
                # eines Archiv-Eintrags muss dieselben Entpackgrenzen
                # einhalten wie sein Inhalt. Sonst liest eine Maßsuche
                # beliebig viele Köpfe an --max-archive-total-bytes vorbei.
                stream = _BudgetedStream(self.chunker(handle))
                try:
                    dims = image_dimensions(stream)
                finally:
                    self.dimension_bytes = stream.fetched
            if dims is None and not self.in_archive \
                    and self.extension in EXIFTOOL_DIMENSION_EXTENSIONS:
                record = self.metadata() or {}
                dims = plausible_dimensions(record.get("ImageWidth"),
                                            record.get("ImageHeight"))
            self._dimensions = dims
        return self._dimensions

    def finder_metadata(self):
        if self._finder_metadata is MISSING:
            query = self.search.criteria_query
            fields = list(query.finder_fields) if query is not None else []
            if self.search.include_finder_metadata:
                fields = list(FINDER_ATTRIBUTES)
            if self.in_archive:
                self._finder_metadata = dict(schemaVersion=1, sourceGeneration=None,
                    fields={field: dict(status="notApplicable") for field in fields})
            else:
                self._finder_metadata = read_finder_metadata(self.filesystem_path, fields)
        return self._finder_metadata

    def final_finder_metadata(self):
        if self.search.include_finder_metadata:
            self.finder_metadata()
        if self._finder_metadata is MISSING:
            return None
        result = self._finder_metadata
        generation = result["sourceGeneration"]
        if generation is not None:
            size, modified, _ = self.facts()
            try:
                current = source_generation(status=os.lstat(self.filesystem_path))
            except OSError:
                current = None
            # Fakten können bereits einen Filter entschieden haben. Ein neuerer
            # Finder-Stand darf sie weder ersetzen noch widersprüchlich ergänzen.
            if current != generation or not finder_generation_matches_facts(generation, size, modified):
                result["fields"] = {field: dict(status="sourceChanged") for field in result["fields"]}
                result["sourceGeneration"] = None
        return result

    def metadata(self):
        """Die angeforderten exiftool-Felder als dict — oder None. Archiv-
        Einträge und Dateien ohne Medienendung fragen exiftool gar nicht."""
        if self._metadata is MISSING:
            if not self.local_content_allowed():
                return None
            self._metadata = None
            if not self.in_archive \
                    and self.extension in METADATA_EXTENSIONS:
                stream = self.search.exiftool_stream()
                if stream is not None:
                    self._metadata = stream.read(self.filesystem_path)
                    if self._metadata is None:
                        self.search.omission("metadataUnavailable", self.label)
                else:
                    self.search.omission("metadataUnavailable", self.label)
            else:
                self.search.omission("archiveMetadata" if self.in_archive else "metadataUnsupported", self.label)
        return self._metadata

    def content_lines(self):
        """Je Suchbegriff die Zeilennummer seines ersten Vorkommens — oder
        None, wenn auch nur ein Begriff fehlt. Bei EINEM Begriff eine Liste
        mit einem Eintrag."""
        if self._content_lines is MISSING:
            if self.search.criteria_content_matchers or self.search.document_mode:
                results = [self.criteria_content().resolve(matcher)
                           for matcher in self.search.matchers]
                self._content_lines = ([result[1] for result in results]
                                       if all(result[0] is True for result in results)
                                       else None)
            else:
                self._content_lines = self.search.find_content_lines(self)
        return self._content_lines

    def matching_pieces(self, normalize):
        if not self.search.document_mode:
            with self.content_stream() as stream:
                yield from iter_matching_pieces(self.chunker(stream, free_bytes=self.dimension_bytes),
                    normalize, self.search.text_encoding, self.decoder_info)
            return
        image_ocr = self.search.ocr and self.extension in OCR_EXTENSIONS
        if self.extension != ".pdf" and self.extension not in PACKAGE_DOCUMENT_READERS and not image_ocr:
            raise DocumentReadError("documentUnsupported")
        pdf_ocr = self.search.pdf_ocr and self.extension == ".pdf"
        seconds = PDF_OCR_SECONDS if pdf_ocr else DOCUMENT_SECONDS
        deadline = time.monotonic() + seconds
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)
        def expired(signum, frame):
            raise DocumentReadError("ocrTimeout" if image_ocr or pdf_ocr else "documentTimeout")
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, seconds)
        temporary = None
        pieces = None
        try:
            expected = self.preview_generation
            if expected is None or source_generation(self.filesystem_path) != expected:
                raise DocumentReadError("documentSourceChanged")
            with self.content_stream() as stream:
                if not self.in_archive:
                    if source_generation(status=os.fstat(stream.fileno())) != expected:
                        raise DocumentReadError("documentSourceChanged")
                    if os.fstat(stream.fileno()).st_size > DOCUMENT_BYTES:
                        raise DocumentReadError("documentLimit")
                if not self.in_archive and not any(0xD800 <= ord(char) <= 0xDFFF for char in self.filesystem_path):
                    path = self.filesystem_path
                else:
                    # tempfile macht den Pfad sichtbar, bevor sein eigener
                    # Cleanup registriert ist. Erst den Besitz zuweisen, dann
                    # Abbruch und Dokumentfrist wieder zustellen lassen.
                    previous_mask = (signal.pthread_sigmask(signal.SIG_BLOCK,
                        {signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGALRM})
                        if hasattr(signal, "pthread_sigmask") else None)
                    try:
                        temporary = tempfile.NamedTemporaryFile(suffix=self.extension)
                    finally:
                        if previous_mask is not None:
                            signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    total = 0
                    for chunk in self.chunker(stream, free_bytes=self.dimension_bytes):
                        total += len(chunk)
                        if total > DOCUMENT_BYTES:
                            raise DocumentReadError("documentLimit")
                        temporary.write(chunk)
                    temporary.flush()
                    path = temporary.name
                package_reader = PACKAGE_DOCUMENT_READERS.get(self.extension)
                reader = (self.search.ocr_reader if image_ocr else
                          package_reader(self.search.archive_budget) if package_reader else self.search.pdf_reader)
                self.decoder_info["decoder"] = OCR_ENCODING if image_ocr else PDF_OCR_ENCODING if pdf_ocr else PACKAGE_DOCUMENT_ENCODINGS.get(self.extension, DOCUMENT_ENCODING)
                if image_ocr:
                    # Auch ein hoher Modellwert beweist nicht, dass alle Bildtexte erkannt wurden.
                    self.decoder_info["documentMissingText"] = True
                    self.search.omission("ocrProjection", self.label)
                if pdf_ocr:
                    self.decoder_info["documentMissingText"] = True
                    self.search.omission("pdfOCRProjection", self.label)
                    reader.on_progress = lambda stage, page, count: self.search.report_progress(self.label, stage=stage, page=page, pages=count)
                if package_reader or pdf_ocr:
                    def issue(reason):
                        self.decoder_info["documentMissingText"] = True
                        self.search.omission(reason, self.label)
                    reader.on_issue = issue
                pieces = document_sections(reader, path, deadline)
                base = 0
                for position, text in pieces:
                    if package_reader is None and not text.strip():
                        self.decoder_info["documentMissingText"] = True
                        self.search.omission("documentNoText", self.label)
                    last = 0
                    for number, raw, complete, canonical, uncertain in iter_matching_pieces(
                            [text.encode("utf-8")], normalize, "utf-8"):
                        if source_generation(self.filesystem_path) != expected:
                            raise DocumentReadError("documentSourceChanged")
                        last = number
                        self.document_position = dict(position, line=number)
                        yield base + number, raw, complete, canonical, uncertain
                    base += last
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            try:
                if pieces is not None:
                    pieces.close()
            finally:
                if temporary is not None:
                    temporary.close()
                signal.signal(signal.SIGALRM, previous_handler)
                signal.setitimer(signal.ITIMER_REAL, *previous_timer)

    def criteria_content(self):
        if self._criteria_content is None:
            self._criteria_content = CriteriaContentScan(self)
        return self._criteria_content

    def close(self):
        if self._criteria_content is not None:
            self._criteria_content.close()
        if self.decoder_info.get("decoder") in DOCUMENT_READERS.values() and source_generation(self.filesystem_path) != self.preview_generation:
            raise DocumentReadError("documentSourceChanged")

# Die Kriterien einer Suche. Alle müssen zutreffen; `Search` sortiert sie
# nach `cost` und bricht beim ersten Nein ab. Reihenfolge: Name (gratis) →
# Dateifakten (stat/Katalog) → Maße (0,2 ms) → Metadaten (0,75 ms) → Inhalt.
# Genau das macht
# „Winter UND ≥ 1000 px" schnell: exiftool sieht nur die Dateien, die die
# Maßprüfung überlebt haben. Der strukturierte Baum verwendet dieselben
# Kostenphasen und FileProbe-Antworten wie die bisherigen UND-Kriterien.

MAX_CRITERIA_BYTES = 64 * 1024
MAX_CRITERIA_DEPTH = 16
MAX_CRITERIA_NODES = 256
MAX_CRITERIA_LEAVES = 128
MAX_CRITERIA_VALUE_BYTES = 4096
MAX_CRITERIA_EVIDENCE_CHARS = 256


class Condition:
    """Kostenphasen und Negation gelten gleichermaßen für alle Blattfelder."""

    cost = 0

    def __init__(self, field, identifier=None, negate=False):
        self.field = field
        self.identifier = identifier
        self.negate = negate

    def evaluate(self, probe, evidence=None):
        if self.cost > getattr(probe, "criteria_phase", math.inf):
            return None
        cache = getattr(probe, "criteria_results", None)
        if cache is not None and self in cache:
            matched, item = cache[self]
        else:
            try:
                matched, value, extras = self.match(probe)
            except EXPECTED_ARCHIVE_ERRORS as err:
                probe.search.report_warning("%s: %s" % (probe.label, err), path=probe.label, error=err)
                matched, value, extras = None, "", {}
            if matched is DEFERRED:
                return None
            if matched is not None and self.negate:
                matched = not matched
            item = None
            if matched is True and self.identifier is not None:
                item = {"id": self.identifier, "field": self.field,
                        "value": json_safe_text(value[:MAX_CRITERIA_EVIDENCE_CHARS])}
                item.update(extras)
                if len(value) > MAX_CRITERIA_EVIDENCE_CHARS:
                    item["valueTruncated"] = True
                if self.negate:
                    item["negated"] = True
            if cache is not None:
                cache[self] = matched, item
        if matched is True and evidence is not None and item is not None:
            evidence.append(item)
        return matched


class TextCondition(Condition):
    def __init__(self, field, matcher, identifier=None, negate=False):
        super().__init__(field, identifier, negate)
        self.matcher = matcher

    def match(self, probe):
        if self.field == "name":
            value = probe.name
        elif self.field == "relativePath":
            value = probe.relative_path
        else:
            value = (None if probe.is_dir or probe.name is None
                     else os.path.splitext(probe.name)[1][1:])
        if value is None:
            return None, "", {}
        return bool(self.matcher(value)), value, {}


class ContentCondition(Condition):
    cost = 3

    def __init__(self, matcher, value, identifier, negate=False):
        super().__init__("content", identifier, negate)
        self.matcher = matcher
        self.value = value

    def match(self, probe):
        scan = probe.criteria_content()
        matched, line, text, truncated = (scan.peek(self.matcher) if probe.peek_content else
                                         scan.resolve(self.matcher, allow_query_decision=True))
        extras = {"line": line} if matched is True else {}
        if matched is True and self.matcher in probe.document_positions:
            extras["documentPosition"] = probe.document_positions[self.matcher]
        if probe.decoder_info.get("decoder"):
            extras["contentEncoding"] = probe.decoder_info["decoder"]
        if truncated and not self.negate:
            extras["valueTruncated"] = True
        return matched, self.value if self.negate else (text or ""), extras

    def evaluate(self, probe, evidence=None):
        if probe.peek_content and self.matcher not in probe.criteria_content().results:
            return None
        return super().evaluate(probe, evidence)


class MetadataCondition(Condition):
    cost = 2

    def __init__(self, matcher, fields, identifier, negate=False):
        super().__init__("metadata", identifier, negate)
        self.matcher = matcher
        self.fields = fields

    def match(self, probe):
        if probe.is_dir:
            return None, "", {}
        record = probe.metadata()
        first = None
        for field in self.fields:
            raw = (record or {}).get(field)
            if raw is None:
                continue
            for value in metadata_values(raw):
                if first is None:
                    first = field, value
                if self.matcher(value):
                    return True, value, {"metadataField": field}
        if first is None:
            return None, "", {}
        return False, first[1], {"metadataField": first[0]}


class FinderCondition(Condition):
    cost = 1

    def __init__(self, field, matcher, identifier, negate=False):
        super().__init__(field, identifier, negate)
        self.matcher = matcher

    def match(self, probe):
        value = probe.finder_metadata()["fields"].get(self.field, dict(status="notRecorded"))
        if value["status"] != "available":
            reason = {"limited": "finderMetadataLimit", "notApplicable": "archiveFinderMetadata"}.get(
                value["status"], "finderMetadataUnavailable")
            if getattr(probe, "search", None) is not None:
                probe.search.omission(reason, probe.label)
            return None, "", {}
        texts = ([tag["name"] for tag in value["values"]] if self.field == "finderTags"
                 else [value["value"]])
        for text in texts:
            if self.matcher(text):
                return True, text, {}
        return False, texts[0] if texts else "", {}


class FactCondition(Condition):
    def __init__(self, field, operator, lower, upper, identifier, negate=False):
        super().__init__(field, identifier, negate)
        self.operator = operator
        self.lower = lower
        self.upper = upper
        self.cost = 1 if field in ("width", "height") else 0.5

    def match(self, probe):
        if self.field in ("width", "height"):
            dims = None if probe.is_dir else probe.dimensions()
            value = None if dims is None else dims[self.field == "height"]
        else:
            value = probe.facts()[("size", "modified", "created").index(self.field)]
        if value is None:
            return None, "", {}
        if self.operator == "atLeast":
            matched = value >= self.lower
        elif self.operator == "atMost":
            matched = value <= self.upper
        else:
            matched = self.lower <= value <= self.upper
        text = str(value)
        if self.field in ("modified", "created"):
            try:
                displayed = datetime.datetime.fromtimestamp(value, datetime.timezone.utc)
                # Mikrosekundenrundung darf einen positiven Beleg nicht
                # über die gerade noch erfüllte Sekundengrenze schieben.
                if displayed.microsecond == 0 and displayed.timestamp() > value:
                    displayed -= datetime.timedelta(microseconds=1)
                text = displayed.isoformat().replace("+00:00", "Z")
            except (ValueError, OverflowError, OSError):
                pass
        return bool(matched), text, {}


class CriteriaContentScan:
    """Ein fortsetzbarer Inhaltsdurchlauf für Baum und bisherige Begriffe.

    Ein ODER darf beim ersten bewiesenen Fund enden. Später benötigte Blätter
    setzen denselben Leser fort; es werden keine Zeilen für später gepuffert.
    """

    def __init__(self, probe):
        self.probe = probe
        matchers = list(probe.search.criteria_content_matchers)
        if probe.search.text_mode == "content":
            matchers.extend(probe.search.matchers)
        self.pending = list(dict.fromkeys(matchers))
        self.results = {}
        self.skipped = {}
        self.requested = set()
        self.warned = False
        self.finished = False
        self.reader = self.read()

    def warn_skipped(self, matcher):
        if matcher in self.skipped and not self.warned:
            self.probe.search.report_warning(
                "%s: Zeile %d ist länger als %d Zeichen; dieses Inhaltskriterium "
                "konnte nicht vollständig geprüft werden"
                % (self.probe.label, self.skipped[matcher], MAX_LINE_CHARS),
                reason="lineTooLong", path=self.probe.label)
            self.warned = True

    def read(self):
        probe = self.probe
        try:
            normalize = any(hasattr(matcher, "canonical_matcher") for matcher in self.pending)
            pieces = probe.matching_pieces(normalize)
            try:
                for number, text, complete, canonical, uncertain in pieces:
                    for matcher in self.pending[:]:
                        matched = match_content_piece(matcher, text, complete, canonical, uncertain)
                        if matched is True:
                            if probe.document_position is not None:
                                probe.document_positions[matcher] = probe.document_position
                            if probe.content_preview is not None:
                                probe.content_preview.record(matcher, number, text, complete)
                            self.results[matcher] = (True, number,
                                text[:MAX_CRITERIA_EVIDENCE_CHARS],
                                len(text) > MAX_CRITERIA_EVIDENCE_CHARS)
                            self.pending.remove(matcher)
                        elif matched is None:
                            self.skipped.setdefault(matcher, number)
                            if matcher in self.requested:
                                self.warn_skipped(matcher)
                    yield
                    if not self.pending:
                        return
            finally:
                pieces.close()
            negative = {condition.matcher for condition in (probe.search.criteria_query.conditions if probe.search.criteria_query else [])
                        if isinstance(condition, ContentCondition) and condition.negate}
            if negative.intersection(self.pending) and probe.decoder_info.get("hadReplacement"):
                probe.search.report_warning("%s: ungültige Zeichenfolgen ersetzt; Abwesenheit von Inhalt bleibt unbekannt" % probe.label, reason="invalidDecoding", path=probe.label)
            for matcher in self.pending:
                self.results[matcher] = (None if matcher in self.skipped or probe.decoder_info.get("hadReplacement") or probe.decoder_info.get("documentMissingText")
                                         else False), None, None, False
        except EXPECTED_ARCHIVE_ERRORS as err:
            if isinstance(err, DocumentReadError) and err.reason == "documentUnsupported":
                probe.search.omission(err.reason, probe.label)
            elif isinstance(err, DocumentReadError) and err.reason == "documentNoText" and probe.decoder_info.get("documentMissingText"):
                probe.search.warn("%s: %s" % (probe.label, err))
            else:
                probe.search.report_warning("%s: %s" % (probe.label, err), path=probe.label, error=err)
            for matcher in self.pending:
                self.results[matcher] = None, None, None, False
        finally:
            self.finished = True

    def peek(self, matcher):
        return self.results.get(matcher, (None, None, None, False))

    def resolve(self, matcher, allow_query_decision=False):
        if not self.probe.content_available:
            return None, None, None, False
        self.requested.add(matcher)
        while matcher not in self.results and not self.finished:
            before = len(self.results)
            try:
                next(self.reader)
            except StopIteration:
                break
            if allow_query_decision and matcher not in self.results and len(self.results) > before:
                self.probe.peek_content = True
                try:
                    decided = self.probe.search.criteria_query.root.evaluate(self.probe)
                finally:
                    self.probe.peek_content = False
                if decided is not None:
                    return DEFERRED, None, None, False
        self.warn_skipped(matcher)
        return self.results.get(matcher, (None, None, None, False))

    def close(self):
        self.reader.close()


class CriteriaGroup:
    """Dreiwertige UND-/ODER-Verknüpfung mit Belegen nur für bewiesene Treffer."""

    def __init__(self, operator, children):
        self.operator = operator
        self.children = tuple(children)
        self.cost = min(child.cost for child in children)
        self.ordered_children = sorted(children, key=lambda child: child.cost)

    def evaluate(self, probe, evidence=None):
        cache = getattr(probe, "criteria_results", None)
        if cache is not None and self in cache:
            matched, proof = cache[self]
            if matched is True and evidence is not None:
                evidence.extend(proof)
            return matched
        unknown = False
        keep_proof = evidence is not None or cache is not None
        collected = [] if keep_proof else None
        for child in self.ordered_children:
            branch = [] if keep_proof else None
            matched = child.evaluate(probe, branch)
            if self.operator == "and" and matched is False:
                if cache is not None:
                    cache[self] = False, []
                return False
            if self.operator == "or" and matched is True:
                if cache is not None:
                    cache[self] = True, branch
                if evidence is not None:
                    evidence.extend(branch)
                return True
            unknown = unknown or matched is None
            if collected is not None and matched is True:
                collected.extend(branch)
        if unknown:
            return None
        matched = self.operator == "and"
        if cache is not None:
            cache[self] = matched, collected
        if matched and evidence is not None:
            evidence.extend(collected)
        return matched


class CriteriaQuery:
    cost = 0

    def __init__(self, root, needs_relative_path=False, conditions=()):
        self.root = root
        self.needs_relative_path = needs_relative_path
        self.conditions = list(conditions)
        self.maximum_cost = max((condition.cost for condition in conditions), default=0)
        self.content_matchers = [condition.matcher for condition in conditions
                                 if isinstance(condition, ContentCondition)]
        self.metadata_fields = list(dict.fromkeys(
            field for condition in conditions if isinstance(condition, MetadataCondition)
            for field in condition.fields))
        self.needs_dimensions = any(condition.field in ("width", "height")
                                    for condition in conditions)
        self.finder_fields = list(dict.fromkeys(condition.field for condition in conditions
                                               if isinstance(condition, FinderCondition)))

    def test(self, probe):
        evidence = []
        matched = self.root.evaluate(probe, evidence) is True
        probe.criteria_evidence = evidence if matched else None
        return matched


def parse_criteria_query(document, date_resolver=None):
    """Validiert den ganzen Baum, bevor ein Suchobjekt angefasst wird."""
    if (not isinstance(document, dict)
            or set(document) != {"schemaVersion", "root"}
            or type(document["schemaVersion"]) is not int
            or document["schemaVersion"] not in (1, 2, 3)):
        raise ValueError("Kriterien brauchen schemaVersion 1/2/3 und root")
    date_resolver = date_resolver or DateRangeResolver()
    identifiers = set()
    leaves = 0
    fields = set()
    conditions = []

    def node(value, depth):
        nonlocal leaves
        if depth > MAX_CRITERIA_DEPTH:
            raise ValueError("Kriterien überschreiten die Gruppentiefe %d"
                             % MAX_CRITERIA_DEPTH)
        if not isinstance(value, dict):
            raise ValueError("jede Bedingung/Gruppe muss ein Objekt sein")
        identifier = value.get("id")
        if (not isinstance(identifier, str)
                or re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identifier) is None):
            raise ValueError("jede Bedingung/Gruppe braucht eine id aus "
                             "1–64 Buchstaben, Ziffern, _ oder -")
        if identifier in identifiers:
            raise ValueError("doppelte Kriterien-id: %s" % identifier)
        identifiers.add(identifier)
        if len(identifiers) > MAX_CRITERIA_NODES:
            raise ValueError("zu viele Kriterienknoten (maximal %d)"
                             % MAX_CRITERIA_NODES)
        if "children" in value or "op" in value:
            if (set(value) != {"id", "op", "children"}
                    or value["op"] not in ("and", "or")
                    or not isinstance(value["children"], list)
                    or not value["children"]):
                raise ValueError("Gruppe %s braucht op and/or und eine "
                                 "nicht leere children-Liste" % identifier)
            return CriteriaGroup(value["op"],
                                 [node(child, depth + 1)
                                  for child in value["children"]])
        required = {"id", "field", "operator", "value"}
        text_fields = ("name", "extension", "relativePath", "content", "metadata")
        if document["schemaVersion"] == 3:
            text_fields += tuple(FINDER_ATTRIBUTES)
        fact_fields = ("size", "modified", "created", "width", "height")
        if (not required.issubset(value)
                or not set(value).issubset(required | {"caseSensitive", "negate", "metadataField"})
                or value["field"] not in text_fields + fact_fields
                or not (isinstance(value["value"], str)
                        or (document["schemaVersion"] >= 2 and value["field"] in ("modified", "created")
                            and isinstance(value["value"], dict)))
                or any(type(value[key]) is not bool for key in
                       ("caseSensitive", "negate") if key in value)
                or ("metadataField" in value and (value["field"] != "metadata"
                                                  or not isinstance(value["metadataField"], str)))):
            raise ValueError("ungültige Bedingung %s (Feld, Wert oder Optionen)" % identifier)
        pattern = value["value"]
        if isinstance(pattern, str) and ("\0" in pattern or len(pattern.encode("utf-8")) > MAX_CRITERIA_VALUE_BYTES
                or (not pattern and not (value["field"] == "extension"
                                         and value["operator"] == "equals"))):
            raise ValueError("Bedingung %s: Wert ist leer, enthält NUL oder "
                             "überschreitet %d UTF-8-Bytes"
                             % (identifier, MAX_CRITERIA_VALUE_BYTES))
        leaves += 1
        if leaves > MAX_CRITERIA_LEAVES:
            raise ValueError("zu viele Bedingungen (maximal %d)" % MAX_CRITERIA_LEAVES)
        field, operator = value["field"], value["operator"]
        fields.add(field)
        negate = value.get("negate", False)
        if field in fact_fields:
            if operator not in ("equals", "atLeast", "atMost") or value.get("caseSensitive", False):
                raise ValueError("Bedingung %s: ungültiger Zahlen-/Datumsoperator" % identifier)
            try:
                if field in ("modified", "created"):
                    if isinstance(pattern, dict):
                        if pattern.get("kind") not in ("relative", "fixed"):
                            raise ValueError("Kriterien speichern nur relative oder feste Datumsbereiche")
                        resolution = date_resolver.resolve(pattern, "criteria:" + identifier)
                        lower, upper = resolution["lowerEpoch"], resolution["upperEpoch"]
                    else:
                        lower, upper = file_timestamp(pattern), file_timestamp_end(pattern)
                else:
                    lower = upper = byte_size(pattern) if field == "size" else nonnegative_int(pattern)
            except (argparse.ArgumentTypeError, ValueError) as err:
                raise ValueError("Bedingung %s: %s" % (identifier, err)) from err
            condition = FactCondition(field, operator, lower, upper, identifier, negate)
        else:
            if operator not in ("contains", "equals", "glob", "regex"):
                raise ValueError("Bedingung %s: ungültiger Textoperator" % identifier)
            try:
                matcher = build_matcher(
                    pattern, operator == "regex", value.get("caseSensitive", False),
                    exact=operator in ("equals", "glob"),
                    literal_wildcards=operator in ("contains", "equals"))
            except (re.error, OverflowError) as err:
                raise ValueError("Bedingung %s: ungültiger regulärer Ausdruck: %s"
                                 % (identifier, err)) from err
            if field == "content":
                condition = ContentCondition(matcher, pattern, identifier, negate)
            elif field in FINDER_ATTRIBUTES:
                condition = FinderCondition(field, matcher, identifier, negate)
            elif field == "metadata":
                try:
                    tags = ([metadata_tag(value["metadataField"])] if "metadataField" in value
                            else list(METADATA_TEXT_FIELDS))
                except argparse.ArgumentTypeError as err:
                    raise ValueError("Bedingung %s: %s" % (identifier, err)) from err
                condition = MetadataCondition(matcher, tags, identifier, negate)
            else:
                condition = TextCondition(field, matcher, identifier, negate)
        conditions.append(condition)
        return condition

    root = node(document["root"], 1)
    query = CriteriaQuery(root, "relativePath" in fields, conditions)
    query.document = document
    return query


def read_criteria_query(text=None, filename=None, date_resolver=None):
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("doppeltes JSON-Feld: %s" % key)
            result[key] = value
        return result

    if filename is not None:
        if filename == "-":
            stream = getattr(sys.stdin, "buffer", sys.stdin)
            raw = stream.read(MAX_CRITERIA_BYTES + 1)
        else:
            with open_regular_file(filename) as stream:
                raw = stream.read(MAX_CRITERIA_BYTES + 1)
        text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
    if len(text.encode("utf-8")) > MAX_CRITERIA_BYTES:
        raise ValueError("Kriterien überschreiten %d UTF-8-Bytes"
                         % MAX_CRITERIA_BYTES)
    document = json.loads(text, object_pairs_hook=unique_fields)
    return parse_criteria_query(document, date_resolver)


RESULT_FILTER_RECORD_BYTES = 1024 * 1024
RESULT_FILTER_SECONDS = 20.0
RESULT_FILTER_FIELDS = frozenset(("name", "extension", "relativePath", "size",
                                  "modified", "created", "width", "height", "finderTags", "finderComment"))


def validate_result_filter(query):
    if any(condition.field not in RESULT_FILTER_FIELDS for condition in query.conditions):
        raise ValueError("Ansichtsfilter erlauben nur Name, Endung, relativen Pfad, bekannte Fakten und Finder-Snapshots; Inhalt braucht einen neuen Suchlauf")


class KnownResultProbe:
    """Nur übergebene Trefferwerte; dieser Probe besitzt keinen Quellenleser."""

    def __init__(self, record, root=None):
        if not isinstance(record, dict):
            raise ValueError("Treffer muss ein JSON-Objekt sein")
        if "searchRoot" in record:
            provenance = record["searchRoot"]
            if not isinstance(provenance, str) or not provenance.startswith("/") or "\0" in provenance:
                raise ValueError("ungültige Suchwurzel des Treffers")
            root = provenance
        path = record.get("filesystemPath")
        members = record.get("archiveMembers")
        raw_members = record.get("archiveMemberBytes", [])
        self.is_dir = record.get("isDirectory")
        if (record.get("type") not in ("file", "dir", "member")
                or not isinstance(record.get("path"), str)
                or not isinstance(path, str) or not path.startswith("/") or "\0" in path
                or type(self.is_dir) is not bool
                or not isinstance(members, list)
                or any(not isinstance(value, str) or "\0" in value for value in members)
                or not isinstance(raw_members, list)
                or (raw_members and len(raw_members) != len(members))
                or any(not isinstance(value, str) for value in raw_members)):
            raise ValueError("ungültige strukturierte Trefferidentität")
        if raw_members:
            try:
                decoded = [base64.b64decode(value, validate=True).decode("utf-8", "surrogateescape")
                           for value in raw_members]
            except (ValueError, UnicodeError):
                raise ValueError("ungültige rohe Archividentität") from None
            if any("\0" in value for value in decoded):
                raise ValueError("NUL in roher Archividentität")
            members = decoded
        leaf = members[-1] if members else path
        self.name = os.path.basename(leaf.rstrip("/"))
        file_root = root is not None and not self.is_dir and os.path.normpath(path) == os.path.normpath(root)
        self.relative_path = (Exclusions.normalize_pattern(leaf)[0] if members else
                              self.name if root is None or file_root else os.path.relpath(path, root))
        self._facts = tuple(self.known(record, key) for key in ("size", "modified", "created"))
        self._dimensions = tuple(self.known(record, key) for key in ("width", "height"))
        self.in_archive = record["type"] == "member" or bool(members)
        self._raw_finder_metadata = record.get("finderMetadata", MISSING)
        self._finder_metadata = MISSING
        if self.is_dir:
            self._facts = (None, self._facts[1], self._facts[2])
            self._dimensions = (None, None)

    @staticmethod
    def known(record, key):
        value = record.get(key)
        if value is None:
            return None
        if key in ("size", "width", "height"):
            if type(value) is not int or not 0 <= value <= 2**63 - 1:
                raise ValueError("ungültiger bekannter Zahlenwert: " + key)
        elif type(value) not in (int, float) or not -1e308 <= value <= 1e308:
            raise ValueError("ungültiger bekannter Zeitpunkt: " + key)
        return value

    def facts(self):
        return self._facts

    def dimensions(self):
        return self._dimensions

    def finder_metadata(self):
        if self._finder_metadata is MISSING:
            raw = self._raw_finder_metadata
            result = (dict(schemaVersion=1, sourceGeneration=None, fields={}) if raw is MISSING
                      else validate_finder_snapshot(raw))
            generation = result["sourceGeneration"]
            if generation is not None:
                if self.in_archive:
                    raise ValueError("Archivmitglied trägt lokale Finder-Quellengeneration")
                size, modified, _ = self._facts
                if not finder_generation_matches_facts(generation, size, modified):
                    raise ValueError("Finder-Quellengeneration passt nicht zu den Trefferfakten")
            self._finder_metadata = result
        return self._finder_metadata


def iter_filtered_results(stream, query, root=None):
    validate_result_filter(query)
    def invalid_constant(value):
        raise ValueError("ungültige JSON-Konstante: " + value)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("doppeltes JSON-Feld: " + key)
            result[key] = value
        return result
    while True:
        raw = stream.readline(RESULT_FILTER_RECORD_BYTES + 1)
        if not raw:
            return
        if len(raw) > RESULT_FILTER_RECORD_BYTES:
            raise ValueError("Trefferrecord überschreitet 1 MiB")
        text = raw.decode("utf-8") if isinstance(raw, bytes) else raw
        record = json.loads(text, object_pairs_hook=unique, parse_constant=invalid_constant)
        if query.test(KnownResultProbe(record, root)):
            # Originalbelege und Identitäten reisen unverändert weiter.
            yield text.rstrip("\r\n")


def filter_result_file(filename, query, root=None):
    if root is not None and (not root.startswith("/") or "\0" in root):
        raise ValueError("Filterwurzel braucht einen absoluten Pfad ohne NUL")
    validate_result_filter(query)
    handlers = install_termination_handlers()
    previous_handler = signal.getsignal(signal.SIGALRM)
    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    def expired(*_):
        # OSError wird von der allgemeinen Kriterienauswertung als Quellen-
        # Warnung behandelt; dieser gesamte Filterauftrag muss abbrechen.
        raise ValueError("Ansichtsfilter überschreitet sein Zeitbudget")
    matched = False
    try:
        signal.signal(signal.SIGALRM, expired)
        signal.setitimer(signal.ITIMER_REAL, RESULT_FILTER_SECONDS)
        source = (contextlib.nullcontext(getattr(sys.stdin, "buffer", sys.stdin))
                  if filename == "-" else open_regular_file(filename))
        with source as stream:
            for text in iter_filtered_results(stream, query, root):
                write_output(text)
                matched = True
        sys.stdout.flush()
        return 0 if matched else 1
    except (OutputClosed, BrokenPipeError):
        discard_closed_output()
        return 0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous_handler)
        signal.setitimer(signal.ITIMER_REAL, *previous_timer)
        restore_termination_handlers(handlers)


class NameCriterion:
    cost = 0

    def __init__(self, matchers):
        # Alle Begriffe müssen im Namen stehen (Mehrwortsuche: UND).
        self.matchers = list(matchers)
        self.root = CriteriaGroup("and", [TextCondition("name", matcher)
                                          for matcher in self.matchers])

    def test(self, probe):
        return self.root.evaluate(probe) is True


class FileFactsCriterion:
    """Drei inklusive Bereiche aus derselben Faktenabfrage, vor allen Lesern."""

    cost = 0.5

    def __init__(self, min_size=None, max_size=None, modified_from=None,
                 modified_to=None, created_from=None, created_to=None):
        self.bounds = ((min_size, max_size), (modified_from, modified_to),
                       (created_from, created_to))

    def test(self, probe):
        for value, (lower, upper) in zip(probe.facts(), self.bounds):
            if lower is None and upper is None:
                continue
            if value is None:
                probe.search.omission("factUnavailable", probe.label)
                return False
            if lower is not None and value < lower:
                return False
            if upper is not None and value > upper:
                return False
        return True


class DimensionCriterion:
    cost = 1

    def __init__(self, min_width=None, max_width=None, min_height=None,
                 max_height=None):
        self.min_width = min_width
        self.max_width = max_width
        self.min_height = min_height
        self.max_height = max_height

    def test(self, probe):
        dims = probe.dimensions()
        if dims is None:
            return False               # keine Maße = kein Bild = kein Treffer
        width, height = dims
        if self.min_width is not None and width < self.min_width:
            return False
        if self.max_width is not None and width > self.max_width:
            return False
        if self.min_height is not None and height < self.min_height:
            return False
        if self.max_height is not None and height > self.max_height:
            return False
        return True


class MetadataCriterion:
    cost = 2

    def __init__(self, matchers, fields):
        self.matchers = list(matchers)
        self.fields = list(fields)

    def test(self, probe):
        """Jeder Begriff muss in irgendeinem Wert der Felder stehen — nicht
        alle im selben Wert (Mehrwortsuche: UND über die ganze Datei). Je
        Begriff wird das erste passende (Feld, Wert) als Beleg gemerkt."""
        record = probe.metadata()
        if not record:
            return False
        hits = []
        for matcher in self.matchers:
            found = None
            for field in self.fields:
                value = record.get(field)
                if value is None:
                    continue
                for text in metadata_values(value):
                    if matcher(text):
                        found = (field, text)
                        break
                if found is not None:
                    break
            if found is None:
                return False
            hits.append(found)
        probe.metadata_hits = hits
        probe.metadata_hit = hits[0]
        return True


class ContentCriterion:
    cost = 3

    def test(self, probe):
        return probe.content_lines() is not None


class Exclusions:
    """Glob-Ausschlüsse relativ zu einer Such- oder Archivwurzel.

    Ohne Schrägstrich gilt ein Muster für jede ganze Pfadkomponente. Mit
    Schrägstrich gilt es für den ganzen relativen Pfad. Auch dessen Eltern
    werden geprüft: Ein Archiv muss seine Ordner nicht eigens auflisten,
    damit beispielsweise `cache/deep` alle Einträge darunter ausschließt.
    `fnmatchcase` hält Groß-/Kleinschreibung immer auseinander; sein `*`
    darf auch Schrägstriche überqueren. Suchoptionen wie --regex ändern
    diese eigenständige Mustersemantik nicht.

    Muster werden wie die Pfade normalisiert (`normalize_pattern()`):
    ein `./` am Anfang und ein `/` am Ende fallen weg — die Shell hängt
    bei der Tab-Vervollständigung eines Ordners den Schrägstrich an, und
    `--exclude build/` schloss bis 0.34.0 still gar nichts aus. Ob ein
    Muster den Pfad oder nur eine Komponente meint, entscheidet weiter
    das ROHE Muster: `build/` bleibt ein Pfadmuster (nur der Ordner
    `build` an der Wurzel), `build` gilt für jede Komponente. Ein
    absolutes Muster kann nie treffen, weil immer relativ zur Wurzel
    verglichen wird; `main()` lehnt es deshalb ab, ebenso ein Muster,
    von dem nach der Normalisierung nichts übrig bleibt."""

    @staticmethod
    def normalize_pattern(pattern):
        """Muster in dieselbe Form bringen wie `matches()` die Pfade:
        leere Komponenten und `.` entfallen. Liefert das normalisierte
        Muster und ob es (roh) einen Schrägstrich trug, also ein Pfad-
        statt Komponentenmuster ist."""
        parts = [part for part in pattern.split("/") if part not in ("", ".")]
        return "/".join(parts), "/" in pattern

    def __init__(self, patterns):
        self.component_patterns = []
        self.path_patterns = []
        for pattern in patterns:
            normalized, is_path = self.normalize_pattern(pattern)
            if not normalized:
                continue               # `/`, `./` oder "": nichts auszuschließen
            target = (self.path_patterns if is_path
                      else self.component_patterns)
            target.append(unicodedata.normalize("NFC", normalized))

    def __bool__(self):
        return bool(self.component_patterns or self.path_patterns)

    def matches(self, relative_path):
        if not self.component_patterns and not self.path_patterns:
            return False
        # `./` ist in TAR-Katalogen üblich. Es bezeichnet keinen Namen.
        # Nicht normpath(): Ein `..` im Archivnamen bleibt Teil des Namens,
        # und die Anzeige-/Übergabepfade selbst werden hier nie umgeschrieben.
        parts = [unicodedata.normalize("NFC", part) for part in relative_path.split("/")
                 if part not in ("", ".")]
        for part in parts:
            if any(fnmatch.fnmatchcase(part, pattern)
                   for pattern in self.component_patterns):
                return True
        if not self.path_patterns:
            return False
        prefix = []
        for part in parts:
            prefix.append(part)
            path = "/".join(prefix)
            if any(fnmatch.fnmatchcase(path, pattern)
                   for pattern in self.path_patterns):
                return True
        return False


# Neue Leser ergänzen hier definierte Gründe; Nachrichten werden nie geparst.
REPORT_REASONS = {
    "pdfOCRProjection": ("intentional", "Textebenen bevorzugt, OCR nur für textlose PDF-Seiten; Originalabdeckung nicht garantiert"),
    "pdfOCRLimit": ("budget", "Seiten- oder Renderpixelgrenze für PDF-OCR erreicht"),
    "ocrProjection": ("intentional", "OCR-Text ist erkannt und kann vom Original abweichen; keine Abwesenheit bewiesen"),
    "ocrHelperUnavailable": ("readError", "Lokaler OCR-Helfer oder Deutsch/Englisch-Erkennung fehlt (macOS 13+)"),
    "ocrDamaged": ("readError", "Bild für OCR nicht lesbar oder nicht unterstützt"),
    "ocrReadError": ("readError", "OCR-Leser oder sein begrenzter Datenvertrag fehlgeschlagen"),
    "ocrLimit": ("budget", "OCR-Bild-, Pixel- oder Textgrenze erreicht"),
    "ocrTimeout": ("budget", "Zeitgrenze für OCR erreicht"),
    "ocrMultipleFrames": ("intentional", "Mehrbilddatei nicht per OCR gelesen"),
    "ocrNoText": ("intentional", "Kein ausreichend sicherer OCR-Text erkannt"),
    "localContentNotLocal": ("intentional", "Inhalt noch nicht lokal lesbar"),
    "localContentUnknown": ("readError", "Lokaler Inhalt / Providerzustand nicht sicher belegbar"),
    "documentUnsupported": ("intentional", "Dateityp ohne Dokumenttextleser"),
    "documentHelperUnavailable": ("readError", "PDF-Texthelfer fehlt oder ist nicht startbar"),
    "documentEncrypted": ("readError", "Verschlüsseltes Dokument nicht gelesen"),
    "documentDamaged": ("readError", "Dokument / Textteil nicht lesbar oder beschädigt"),
    "documentNoText": ("readError", "PDF ohne extrahierbare Textebene; keine OCR"),
    "documentLimit": ("budget", "Dokument-Seiten-/Teil-/Text-/Materialisierungsgrenze"),
    "documentTimeout": ("budget", "Dokument-Zeitgrenze"),
    "documentReadError": ("readError", "Dokumentleser / Textteil unvollständig"),
    "documentSourceChanged": ("readError", "Dokumentquelle während des Lesens geändert"),
    "excludedPattern": ("intentional", "Ausschlussmuster"),
    "hidden": ("intentional", "Versteckte Bereiche"),
    "folderDepth": ("intentional", "Ordner-Tiefengrenze"),
    "symlinkDirectory": ("intentional", "Verzeichnislink wird nicht verfolgt"),
    "archiveDepth": ("intentional", "Archivabstieg ausgeschaltet / Tiefengrenze"),
    "archiveMetadata": ("intentional", "Metadatenmodus ohne Archivabstieg"),
    "toolUnavailable": ("readError", "Archivwerkzeug fehlt; nur Rohdatei geprüft"),
    "permissionDenied": ("readError", "Keine Leseberechtigung"),
    "readError": ("readError", "Nicht vollständig lesbar"),
    "criterionUnknown": ("readError", "Angefragte Bedingung nicht belegbar"),
    "factUnavailable": ("readError", "Angefragte Dateieigenschaft unbekannt"),
    "metadataUnsupported": ("intentional", "Dateityp ohne Metadatenleser"),
    "damagedArchive": ("readError", "Beschädigtes Archiv"),
    "notRegularFile": ("readError", "Keine reguläre Datei"),
    "metadataUnavailable": ("readError", "Metadatenwerkzeug nicht verfügbar"),
    "finderMetadataUnavailable": ("readError", "Finder-Eigenschaften nicht verfügbar"),
    "finderMetadataChanged": ("readError", "Finder-Quellengeneration geändert"),
    "finderMetadataLimit": ("budget", "Finder-Attribute überschreiten ihre Grenzen"),
    "archiveFinderMetadata": ("intentional", "Archivmitglieder haben keine Finder-Eigenschaften"),
    "invalidDecoding": ("readError", "Ungültige Zeichenfolgen / Decoder"),
    "archiveBudget": ("budget", "Archivbudget"),
    "archiveMemberBytes": ("budget", "Entpackte Einzelgröße"),
    "archiveTotalBytes": ("budget", "Entpacktes Gesamtbudget"),
    "archiveRatio": ("budget", "Kompressionsverhältnis"),
    "archiveListingBytes": ("budget", "Archivkatalog-Bytegrenze"),
    "archiveMemberCount": ("budget", "Archivkatalog-Eintragsgrenze"),
    "lineTooLong": ("budget", "Überlange Zeile für dieses Muster"),
}
MAX_REPORT_COUNT = 2 ** 53 - 1
MAX_REPORT_BYTES = 262144


class SearchReport:
    """Begrenzte Ereigniszähler, ohne Pfadmenge oder zusätzlichen Scan."""

    def __init__(self, configuration, date_resolution=None):
        def safe(value):
            if type(value) is int and abs(value) > MAX_REPORT_COUNT:
                return str(value)
            if isinstance(value, str):
                return json_safe_text(value)
            if isinstance(value, dict):
                return {key: safe(item) for key, item in value.items()}
            if isinstance(value, (list, tuple)):
                return [safe(item) for item in value]
            return value
        configuration = safe(configuration)
        raw = json.dumps(configuration, ensure_ascii=True, sort_keys=True)
        self.configuration = (configuration if len(raw) <= 65536 else
                              {"truncated": True, "jsonPrefix": raw[:32700]})
        self.run_id = str(uuid.uuid4())
        self.started = time.time()
        self.reasons = {}
        self.last_output = None
        self.date_resolution = date_resolution

    def record(self, reason, path=None):
        if reason not in REPORT_REASONS:
            raise ValueError("undefinierter Berichtsgrund: " + reason)
        category, label = REPORT_REASONS[reason]
        item = self.reasons.setdefault(reason, {
            "id": reason, "category": category, "label": label,
            "count": 0, "countCapped": False, "examples": []})
        if item["count"] < MAX_REPORT_COUNT:
            item["count"] += 1
        else:
            item["countCapped"] = True
        if path is not None and len(item["examples"]) < 3:
            path = str(path)
            # Beispiele sind Anzeigetexte, keine wiederherstellbare Identität.
            example = {"path": json_safe_text(path[:256]), "truncated": len(path) > 256}
            if example not in item["examples"]:
                item["examples"].append(example)

    def snapshot(self, state):
        result = {"type": "searchReport", "schemaVersion": 1,
                "runID": self.run_id, "startedAt": self.started,
                "capturedAt": time.time(), "state": state,
                "coverage": ("withinRequestedScope" if state == "finished" and
                             not self.reasons else "incomplete"),
                "counting": "events", "configuration": self.configuration,
                "reportLimits": {"reasons": len(REPORT_REASONS), "examplesPerReason": 3,
                                 "exampleCharacters": 256, "maximumCount": MAX_REPORT_COUNT,
                                 "configurationBytes": 65536, "recordBytes": MAX_REPORT_BYTES},
                "reasons": [dict(self.reasons[key], examples=[dict(example) for example in self.reasons[key]["examples"]])
                            for key in sorted(self.reasons)]}
        if self.date_resolution is not None:
            result["dateResolution"] = self.date_resolution
        # ASCII-JSON ist auch bei Steuerzeichen/astralen Zeichen die obere
        # Bytegrenze. Zusätzliche Gründe dürfen Zähler nicht aus dem Bericht drängen.
        while len(json.dumps(result, ensure_ascii=True)) > MAX_REPORT_BYTES:
            changed = False
            for item in result["reasons"]:
                for example in item["examples"]:
                    if example["path"]:
                        example["path"] = example["path"][:len(example["path"]) // 2]
                        example["truncated"] = True
                        changed = True
            if not changed:
                raise ValueError("Suchbericht-Metadaten überschreiten ihre Bytegrenze")
        return result

    def emit(self, state="running", force=False):
        now = time.monotonic()
        if not force and self.last_output is not None and now - self.last_output < 0.25:
            return
        self.last_output = now
        raw = json.dumps(self.snapshot(state), ensure_ascii=False, sort_keys=True)
        assert len(raw.encode("utf-8")) <= MAX_REPORT_BYTES
        write_output(raw, flush=True)


def report_error_reason(error):
    if isinstance(error, OSError) and error.errno in (errno.EDEADLK, errno.EAGAIN):
        return "localContentNotLocal"
    if isinstance(error, PermissionError):
        return "permissionDenied"
    if isinstance(error, (zipfile.BadZipFile, tarfile.TarError, gzip.BadGzipFile, lzma.LZMAError, zlib.error, EOFError)):
        return "damagedArchive"
    if isinstance(error, DecoderChoiceError):
        return "invalidDecoding"
    return getattr(error, "reason", "readError")


class Search:
    """Kapselt eine Suche: Muster, Optionen und das Einsammeln der Treffer.

    Die Klasse hält bewusst wenig Zustand: matcher (die Testfunktion),
    die Optionen und den Trefferzustand für den Exit-Code.
    """

    def __init__(self, matcher, content_mode, archive_depth, as_json,
                 progress=False, only="both", include_hidden=False,
                 max_depth=None,
                 max_archive_member_bytes=DEFAULT_MAX_ARCHIVE_MEMBER_BYTES,
                 max_archive_total_bytes=DEFAULT_MAX_ARCHIVE_TOTAL_BYTES,
                 max_archive_ratio=DEFAULT_MAX_ARCHIVE_RATIO,
                 content_probe=None, metadata_mode=False,
                 metadata_fields=None, min_width=None, max_width=None,
                 min_height=None, max_height=None, exiftool_path=None,
                 exclusions=(), min_size=None, max_size=None,
                 modified_from=None, modified_to=None,
                 created_from=None, created_to=None, extra_matchers=(),
                 criteria_query=None, text_encoding="utf-8", content_preview=False, search_report=None,
                 document_mode=False, include_finder_metadata=False, local_only=False, ocr=False, pdf_ocr=False):
        self.report = search_report
        self.local_only = local_only
        self.search_root = None
        self.document_mode = document_mode
        self.ocr = ocr
        self.pdf_ocr = pdf_ocr
        self.include_finder_metadata = include_finder_metadata
        self.pdf_reader = (PDFOCRTextReader if pdf_ocr else PDFTextReader)(find_pdf_helper()) if document_mode else None
        self.ocr_reader = OCRTextReader(find_ocr_helper()) if document_mode and ocr else None
        self.text_encoding = text_encoding
        self.content_preview = content_preview
        self.preview_remaining = MAX_PREVIEW_TOTAL_BYTES
        self.preview_source_generation = None
        self.matcher = matcher                # Funktion text -> bool
        # Mehrwortsuche (--term): weitere Testfunktionen, die ZUSÄTZLICH
        # zutreffen müssen — im selben Ziel (Name, Inhalt oder Metadaten),
        # aber nicht in derselben Zeile bzw. demselben Wert.
        if matcher is None and extra_matchers:
            # main() macht den ersten Begriff zum Muster; ein direkter
            # Aufrufer, der nur weitere Begriffe gibt, bekäme sonst still
            # eine Suche OHNE Textkriterium.
            raise ValueError("extra_matchers ohne matcher: der erste "
                             "Begriff gehört in matcher")
        self.matchers = ([] if matcher is None
                         else [matcher] + list(extra_matchers))
        # Die Begriffe im Klartext, für die Belege in der Ausgabe; main()
        # setzt sie, Tests dürfen sie weglassen.
        self.terms = [getattr(m, "term", "") for m in self.matchers]
        self.exclusions = Exclusions(exclusions)
        self.needs_relative_path = (criteria_query is not None
                                    and criteria_query.needs_relative_path)
        self.criteria_query = criteria_query
        self.criteria_content_matchers = [] if criteria_query is None else criteria_query.content_matchers
        self.content_probe = content_probe    # ContentProbe oder None:
                                              # billiger Vortest vor der
                                              # zeilenweisen Inhaltssuche
        # Wogegen das Muster läuft: "name", "content" oder "metadata" —
        # oder None, wenn es gar kein Muster gibt. Dann filtern allein die
        # Maß-/Faktengrenzen, und die Suche hat kein Textkriterium.
        if matcher is None:
            self.text_mode = None
        elif content_mode or document_mode:
            self.text_mode = "content"
        elif metadata_mode:
            self.text_mode = "metadata"
        else:
            self.text_mode = "name"
        self.metadata_fields = list(metadata_fields or METADATA_TEXT_FIELDS)
        # Die Kriterienliste — siehe Kommentar über NameCriterion.
        criteria = []
        if criteria_query is not None:
            criteria.append(criteria_query)
        if self.text_mode == "name":
            criteria.append(NameCriterion(self.matchers))
        elif self.text_mode == "content":
            criteria.append(ContentCriterion())
        elif self.text_mode == "metadata":
            criteria.append(MetadataCriterion(self.matchers,
                                              self.metadata_fields))
        self.wants_size = min_size is not None or max_size is not None
        if any(limit is not None for limit in (
                min_size, max_size, modified_from, modified_to, created_from, created_to)):
            criteria.append(FileFactsCriterion(min_size, max_size, modified_from,
                                               modified_to, created_from, created_to))
        self.wants_dimensions = any(
            limit is not None
            for limit in (min_width, max_width, min_height, max_height))
        if self.wants_dimensions:
            criteria.append(DimensionCriterion(min_width, max_width,
                                               min_height, max_height))
        self.criteria = sorted(criteria, key=lambda item: item.cost)
        # Ordner können Namen und Zeitpunkte erfüllen, aber weder Datei-
        # größe noch Inhalt, Pixelmaße oder exiftool-Metadaten.
        self.directories_can_match = (self.text_mode in ("name", None)
                                      and not self.wants_dimensions
                                      and not self.wants_size)
        # exiftool: Pfad (oder None) und der erst bei Bedarf gestartete
        # Prozess. Angefordert werden nur die Felder, die dieser Lauf braucht.
        self.exiftool_path = exiftool_path
        self._exiftool = MISSING
        self.exiftool_fields = []
        if self.text_mode == "metadata":
            self.exiftool_fields.extend(self.metadata_fields)
        if criteria_query is not None:
            self.exiftool_fields.extend(criteria_query.metadata_fields)
        if self.wants_dimensions or (criteria_query is not None and criteria_query.needs_dimensions):
            self.exiftool_fields.extend(["ImageWidth", "ImageHeight"])
        self.exiftool_fields = list(dict.fromkeys(self.exiftool_fields))
        self.archive_depth = archive_depth    # 0 = Archive ignorieren,
                                              # 1 = in Archive schauen,
                                              # 2 = auch Archive IN Archiven …
        self.only = only                      # "both"/"files"/"dirs" —
                                              # Treffer auf einen Typ begrenzen
        self.include_hidden = include_hidden  # unsichtbare (Punkt-)Dateien
                                              # und -Ordner mitdurchsuchen?
        self.max_depth = max_depth            # None = unbegrenzt tief;
                                              # 1 = nur direkt im Startpfad
                                              # (zählt wie `find -maxdepth`)
        self.as_json = as_json                # Ausgabeformat JSONL statt Text
        self.progress = progress              # laufend melden, wo wir suchen
        self.found_any = False                # für den Exit-Code (0 vs. 1)
        # Zahl der bisher gemeldeten Treffer. search_archive() liest sie,
        # um den Rückfall auf „ganz normale Datei" auszuschließen, sobald
        # aus dem Archiv schon etwas gemeldet wurde — sonst käme dieselbe
        # Datei ein zweites Mal, jetzt als Dateitreffer.
        self.emitted = 0
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
             archive_members=None, is_dir=None, field=None, value=None,
             width=None, height=None, modified=None, created=None,
             terms=None, criteria_evidence=None, content_encoding=None,
             content_preview=None, document_position=None, document_generation=None,
             finder_metadata=None):
        """Gibt EINEN Treffer aus. kind ist "file", "dir" oder "member"
        (member = Eintrag innerhalb eines Archivs). line ist bei
        Inhaltssuche die Zeilennummer des ersten Treffers, size die
        Dateigröße in Bytes (bei Ordnern None).

        `is_dir` sagt ausdrücklich, ob der Treffer ein Verzeichnis ist. Der
        Typ `member` allein verrät das nicht: Ein Ordner IM Archiv kam vorher
        genauso an wie eine Datei im Archiv, und die Oberfläche zeigte ihn als
        Datei an, filterte ihn beim Ordner-Umschalter falsch und erzeugte beim
        Öffnen eine leere Datei (Review-Fund 2026-08-17). Ohne Angabe folgt es
        dem Typ.

        `field`/`value` nennen bei einer Metadatensuche das Feld und den
        gefundenen Wert, `width`/`height` die Pixelmaße, wenn ein Maßfilter
        sie ermittelt hat. Alle vier sind optional und ändern den bisherigen
        Pflichtsatz nicht.

        `modified`/`created` sind Änderungs- und Erstellungszeit als
        Sekunden seit 1970 (Unix-Zeit, Gleitkomma). Beide sind optional:
        Ein Zip- oder Tar-Eintrag kennt nur seine Änderungszeit, ein
        bsdtar-Eintrag und eine einzeln komprimierte Datei (`.gz`) keine
        von beiden. Die Oberflächen zeigen daraus die Spalten
        „Änderungsdatum" und „Erstellungsdatum".

        `terms` gibt es nur bei der Mehrwortsuche (ab zwei Begriffen): je
        Begriff ein dict mit `term` und — bei Inhalt — `line` bzw. — bei
        Metadaten — `field` und `value`. `line`/`field`/`value` nennen
        weiter den ERSTEN Begriff, damit ältere Leser nichts verlieren."""
        self.found_any = True
        self.emitted += 1
        directory = kind == "dir" if is_dir is None else bool(is_dir)
        if self.as_json:
            members = list(archive_members or ())
            record = {"path": json_safe_text(path), "type": kind,
                      "isDirectory": directory}
            raw_filesystem_path = (filesystem_path
                                   if filesystem_path is not None else path)
            record["filesystemPath"] = json_safe_text(raw_filesystem_path)
            record["archiveMembers"] = [json_safe_text(item)
                                        for item in members]
            if self.search_root is not None:
                record["searchRoot"] = json_safe_text(self.search_root)
            if members:
                # Die sichtbaren Namen dürfen bei ungültigem UTF-8 dasselbe
                # Ersatzzeichen tragen. Diese parallele Liste hält die echte
                # Identität auseinander und macht --extract-json verlustfrei.
                record["archiveMemberBytes"] = [archive_member_bytes(item)
                                                for item in members]
            if line is not None:
                record["line"] = line
            if size is not None:
                record["size"] = size
            if field is not None:
                record["field"] = field
                record["value"] = value
            if width is not None and height is not None:
                record["width"] = width
                record["height"] = height
            if modified is not None:
                record["modified"] = modified
            if created is not None:
                record["created"] = created
            if terms:
                record["terms"] = terms
            if content_encoding is not None:
                record["contentEncoding"] = content_encoding
            if criteria_evidence is not None:
                record["criteriaEvidence"] = criteria_evidence
            if finder_metadata is not None:
                record["finderMetadata"] = finder_metadata
            if content_preview is not None:
                record["contentPreview"] = content_preview
            if document_generation is not None:
                record["documentSourceGeneration"] = document_generation
            if document_position is not None:
                record["documentPosition"] = document_position
            text = json.dumps(record, ensure_ascii=False)
        elif document_position is not None:
            positions = [item["documentPosition"] for item in terms or [] if "documentPosition" in item] or [document_position]
            text = path + ":" + ", ".join(("PDF-Seite %d OCR-Bereich %d Zeile %d (erkannt, ungefähre Seitenposition)" % (item["page"], item["block"], item["line"]) if item["kind"] == "pdfOCR" else "PDF-Seite %d Zeile %d (Textebene)" % (item["page"], item["line"]) if item["kind"] == "pdfTextPage" else "OCR-Bereich %d Zeile %d (erkannt, ungefähre Bildposition)" % (item["block"], item["line"]) if item["kind"] == "imageOCR" else
                                          "Seite %d Zeile %d" % (item["page"], item["line"]) if item["kind"] == "pdfPage" else
                                          "%s Absatz %d Zeile %d" % (item["part"], item["paragraph"], item["line"])) for item in positions)
        elif terms and terms[0].get("line") is not None:
            # Mehrere Begriffe: die Zeilen aller Begriffe in ihrer
            # Reihenfolge, mit Komma — „pfad:3,17".
            text = path + ":" + ",".join(str(item["line"]) for item in terms)
        elif terms and terms[0].get("field") is not None:
            text = path + ":" + " | ".join(
                "%s: %s" % (item["field"], item["value"]) for item in terms)
        else:
            text = path + (":%d" % line if line is not None else "")
            if field is not None:
                text += ":%s: %s" % (field, value)
        write_output(text)

    def omission(self, reason, path=None):
        if self.report is not None:
            self.report.record(reason, path)
            self.report.emit()

    def report_warning(self, message, reason="readError", path=None, error=None):
        self.omission(report_error_reason(error) if error is not None else reason, path)
        self.warn(message)

    def warn(self, message):
        """Nicht-fatale Probleme (z. B. kaputtes Archiv, keine Leserechte)
        landen auf stderr, die Suche läuft weiter."""
        write_output("favenio: warnung: %s" % message, file=sys.stderr)

    def report_progress(self, path, stage=None, page=None, pages=None):
        """Meldet (mit --progress) laufend, welcher Ordner bzw. welches
        Archiv gerade durchsucht wird — damit GUIs zeigen können, dass
        die Suche noch lebt.

        Gedrosselt auf höchstens ~10 Meldungen pro Sekunde, damit die
        Ausgabe die Suche nicht ausbremst; die erste Meldung kommt immer.
        Mit --json als eigenes JSONL-Objekt ({"type": "progress"}) auf
        stdout — Konsumenten unterscheiden Treffer und Fortschritt am
        type-Feld. Ohne --json auf stderr, damit stdout eine reine
        Trefferliste bleibt."""
        if self.report is not None:
            self.report.emit()
        if not self.progress:
            return
        now = time.monotonic()
        ocr_transition = stage == "pdfOCR" and (getattr(self, "_last_progress_stage", None) != "pdfOCR"
            or getattr(self, "_last_progress_path", None) != path)
        if not ocr_transition and self._last_progress is not None and now - self._last_progress < 0.1:
            return
        self._last_progress_stage = stage
        self._last_progress_path = path
        self._last_progress = now
        if self.as_json:
            value = {"type": "progress", "path": json_safe_text(path)}
            if stage is not None:
                value.update(stage=stage, page=page, pages=pages)
            write_output(json.dumps(value, ensure_ascii=False), flush=True)
        else:
            detail = " · PDF-OCR Seite %d von %d" % (page, pages) if stage == "pdfOCR" else ""
            write_output("… durchsuche: %s%s" % (path, detail), file=sys.stderr)

    # ---------- exiftool ----------

    def exiftool_stream(self):
        """Der eine exiftool-Prozess dieses Laufs — gestartet beim ersten
        Bedarf, None ohne exiftool oder ohne angeforderte Felder."""
        if self._exiftool is MISSING:
            self._exiftool = None
            if self.exiftool_path and self.exiftool_fields:
                try:
                    self._exiftool = ExifToolStream(self.exiftool_path,
                                                    self.exiftool_fields,
                                                    warn=(self.warn if self.report is None else
                                                        lambda message: self.report_warning(message, reason="metadataUnavailable")))
                except OSError as err:
                    self.report_warning("exiftool nicht startbar: %s" % err, reason="metadataUnavailable")
        return self._exiftool

    def close(self):
        """Räumt auf, was der Lauf gestartet hat (den exiftool-Prozess)."""
        if self._exiftool not in (MISSING, None):
            self._exiftool.close()
        self._exiftool = MISSING
        if self.pdf_reader is not None:
            self.pdf_reader.close()
        if self.ocr_reader is not None:
            self.ocr_reader.close()

    # ---------- Kriterien ----------

    def evaluate(self, probe, display, kind, filesystem_path=None,
                 archive_members=None):
        """Prüft alle Kriterien gegen EINE Datei bzw. EINEN Archiv-Eintrag
        und gibt bei Erfolg den Treffer aus. Das erste Nein beendet die
        Prüfung — die teuren Fragen kommen dank der Kostenreihenfolge
        zuletzt."""
        close_error = None
        try:
            query = self.criteria_query
            if query is None or query.maximum_cost == 0:
                for criterion in self.criteria:
                    if not criterion.test(probe):
                        return
            else:
                legacy = [criterion for criterion in self.criteria if criterion is not query]
                phases = sorted({criterion.cost for criterion in legacy}
                                | {condition.cost for condition in query.conditions})
                for phase in phases:
                    probe.criteria_phase = phase
                    partial = query.root.evaluate(probe)
                    if partial is False or (phase >= query.maximum_cost and partial is not True):
                        if partial is None:
                            self.omission("criterionUnknown", probe.label)
                        return
                    for criterion in legacy:
                        if criterion.cost == phase and not criterion.test(probe):
                            return
                probe.criteria_phase = math.inf
                if not query.test(probe):
                    return
            lines = (probe.content_lines() if self.text_mode == "content" else None)
            dims = (probe.dimensions() if self.wants_dimensions else
                    None if probe._dimensions is MISSING else probe._dimensions)
        except EXPECTED_ARCHIVE_ERRORS as err:
            self.report_warning("%s: %s" % (probe.label, err), path=probe.label, error=err)
            return
        finally:
            probe.criteria_phase = math.inf
            try:
                probe.close()
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.report_warning("%s: %s" % (probe.label, err), path=probe.label, error=err)
                close_error = err
        if close_error is not None:
            return
        line = lines[0] if lines else None
        field = value = None
        if probe.metadata_hit is not None:
            field, value = probe.metadata_hit
        # Belege je Begriff — nur bei der Mehrwortsuche, sonst genügen
        # line bzw. field/value.
        terms = None
        if len(self.terms) > 1:
            if lines is not None:
                terms = [{"term": json_safe_text(term), "line": number}
                         for term, number in zip(self.terms, lines)]
                for item, matcher in zip(terms, self.matchers):
                    if matcher in probe.document_positions:
                        item["documentPosition"] = probe.document_positions[matcher]
            elif probe.metadata_hits:
                terms = [{"term": json_safe_text(term), "field": hit[0], "value": hit[1]}
                         for term, hit in zip(self.terms, probe.metadata_hits)]
            else:
                terms = [{"term": json_safe_text(term)} for term in self.terms]
        size, modified, created = probe.facts()
        finder = probe.final_finder_metadata()
        if (finder is not None
                and any(item["field"] in FINDER_ATTRIBUTES for item in probe.criteria_evidence or [])
                and any(value["status"] == "sourceChanged" for value in finder["fields"].values())):
            self.omission("finderMetadataChanged", probe.label)
            return
        preview = None
        if self.content_preview:
            if probe.content_preview is None:
                preview = dict(schemaVersion=1, status="budgetExceeded", snippets=[])
            else:
                preview = probe.content_preview.finish()
                count = len(json.dumps(preview, ensure_ascii=False).encode("utf-8"))
                if count > self.preview_remaining:
                    preview = dict(schemaVersion=1, status="budgetExceeded", snippets=[])
                    self.preview_remaining = 0
                else:
                    self.preview_remaining -= count
        self.emit(display, kind, line=line, size=size,
                  filesystem_path=filesystem_path,
                  archive_members=archive_members, is_dir=probe.is_dir,
                  field=field, value=value,
                  width=dims[0] if dims else None,
                  height=dims[1] if dims else None,
                  modified=modified, created=created, terms=terms,
                  criteria_evidence=probe.criteria_evidence,
                  finder_metadata=finder,
                  content_encoding=probe.decoder_info.get("decoder"),
                  content_preview=preview,
                  document_position=(probe.document_positions.get(self.matcher) or
                      next((item["documentPosition"] for item in probe.criteria_evidence or []
                            if "documentPosition" in item), None)),
                  document_generation=(probe.preview_generation if probe.decoder_info.get("decoder") in DOCUMENT_READERS.values() else None))

    @staticmethod
    def file_chunks(handle, free_bytes=0):
        """Häppchen einer normalen Datei; `free_bytes` gibt es nur bei
        Archiv-Einträgen (Budget) und wird hier ignoriert."""
        # iter(callable, sentinel) ruft read() so lange auf,
        # bis es b"" liefert — das Dateiende.
        return iter(lambda: handle.read(CHUNK_SIZE), b"")

    def find_content_lines(self, probe):
        """Je Suchbegriff die Zeile seines ersten Vorkommens, oder None —
        für Dateien wie für Archiv-Einträge derselbe Weg.

        Ohne Vortest ist das ein Durchlauf. Mit Vortest sind es zwei: erst
        das billige Ja/Nein, und nur bei Ja das genaue Zählen. Auch im
        Archiv lohnt sich das, denn das Entpacken ist nicht der Hauptaufwand
        (gemessen am 2026-07-28 an einem 22-MB-Zip mit 72,8 MB Inhalt:
        0,12 s Entpacken gegenüber 0,68 s Gesamtsuche). Für den zweiten
        Durchlauf wird neu geöffnet — ein entpackender Datenstrom lässt sich
        nicht zurückspulen, und eine Datei liegt jetzt im Cache."""
        # Der Maß-Leser läuft wegen der Kostenreihenfolge vor der
        # Inhaltssuche und hat den Anfang des Eintrags bereits gegen das
        # Gesamtbudget gezählt. Genau diese Bytes sind hier frei.
        head_bytes = probe.dimension_bytes
        if self.content_probe is None:
            with probe.content_stream() as handle:
                return self.match_content_all(
                    probe.chunker(handle, free_bytes=head_bytes),
                    self.matchers, label=probe.label, decoder_info=probe.decoder_info,
                    preview=probe.content_preview)
        probed_bytes = 0

        def tally(chunks):
            """Zählt mit, wie weit der Vortest wirklich gelesen hat. Genau
            diese Bytes stehen danach schon im Gesamtbudget; er hört beim
            ersten Fund mitten im Eintrag auf."""
            nonlocal probed_bytes
            for chunk in chunks:
                probed_bytes += len(chunk)
                yield chunk

        with probe.content_stream() as handle:
            if not self.content_probe.hits(
                    tally(probe.chunker(handle, free_bytes=head_bytes))):
                return None
        with probe.content_stream() as handle:
            # free_bytes: genau den Anfang, den der Vortest schon gelesen und
            # dem Gesamtbudget belastet hat, nicht zweimal zählen. Liest der
            # genaue Lauf weiter, zählt der Rest wieder mit.
            return self.match_content_all(
                probe.chunker(handle,
                              free_bytes=max(probed_bytes, head_bytes)),
                self.matchers, label=probe.label, decoder_info=probe.decoder_info,
                preview=probe.content_preview)

    # ---------- Inhalts-Matching ----------

    def match_content_all(self, chunks, matchers, label=None, decoder_info=None, preview=None):
        """Sucht ALLE Begriffe im Inhalt — in EINEM Durchlauf. Liefert je
        Begriff die Zeilennummer seines ersten Vorkommens, oder None, sobald
        das Ende erreicht ist und ein Begriff fehlt. Der Durchlauf endet,
        sobald der letzte Begriff gefunden ist.

        Bei genau einem Begriff läuft `match_content()`, der schlanke Weg
        ohne Schleife über die Begriffe je Zeile (Messung in
        `tests/LINE_READER_MEASUREMENTS.md`, warum jeder Schritt je Zeile
        zählt). Dieselben Regeln für Bruchstücke wie dort: Nur der reine
        „enthält"-Test darf ein Bruchstück einer zu langen Zeile prüfen;
        für verankerte Begriffe bleibt die Zeile ungeprüft und wird EINMAL
        gemeldet."""
        if len(matchers) == 1:
            line = self.match_content(chunks, label=label, decoder_info=decoder_info, preview=preview)
            return None if line is None else [line]
        remaining = list(enumerate(matchers))
        lines = [None] * len(matchers)
        warned = None
        normalize = any(hasattr(matcher, "canonical_matcher") for matcher in matchers)
        for number, text, complete, canonical, uncertain in iter_matching_pieces(
                chunks, normalize, self.text_encoding, decoder_info):
            for index, matcher in remaining[:]:
                matched = match_content_piece(matcher, text, complete, canonical, uncertain)
                if matched is True:
                    if preview is not None:
                        preview.record(matcher, number, text, complete)
                    lines[index] = number
                    remaining.remove((index, matcher))
                elif matched is None and warned != number:
                    self.report_warning("%s: Zeile %d ist länger als %d Zeichen und "
                              "wird mit diesem Muster nicht geprüft"
                              % (label or "<Eingabe>", number,
                                 MAX_LINE_CHARS), reason="lineTooLong", path=label)
                    warned = number
            if not remaining:
                return lines
        return None

    def match_content(self, chunks, label=None, decoder_info=None, preview=None):
        """Sucht das Muster im Datei-Inhalt. Liefert die Zeilennummer des
        ersten Treffers oder None.

        chunks ist eine Folge von Byte-Häppchen zu je CHUNK_SIZE — bei
        Dateien von der Platte, bei Archiv-Einträgen aus dem budgetierten
        Chunker. Beim ersten Treffer steigen wir sofort aus; der Rest der
        Datei wird dann gar nicht mehr gelesen.

        Das Lesen — Dekodieren, Zeilentrennung, Überlappung, Längengrenze —
        macht `iter_line_pieces()`; hier steht nur noch, was mit jedem
        Stück passiert. Nur der reine „enthält"-Test darf ein BRUCHSTÜCK
        einer zu langen Zeile prüfen (`substring_only`, siehe
        build_matcher). Verankerte Muster (--regex mit ^/$, Glob, --exact)
        gelten für die ganze Zeile: `--regex 'A$'` traf am Abschnitts-
        statt am Zeilenende und meldete einen Treffer, den grep nicht
        sieht. Für sie bleibt die zu lange Zeile ungeprüft und wird EINMAL
        als Warnung genannt — gemeldet, statt still falsch beantwortet."""
        # Darf der Matcher ein Bruchstück sehen? Nur der reine
        # „enthält"-Test; alles andere ist verankert (siehe build_matcher).
        matcher = self.matcher
        normalize = hasattr(matcher, "canonical_matcher")
        warned = None
        for number, text, complete, canonical, uncertain in iter_matching_pieces(
                chunks, normalize, self.text_encoding, decoder_info):
            matched = match_content_piece(matcher, text, complete, canonical, uncertain)
            if matched is True:
                if preview is not None:
                    preview.record(matcher, number, text, complete)
                return number
            if matched is None and warned != number:
                self.report_warning("%s: Zeile %d ist länger als %d Zeichen und wird "
                          "mit diesem Muster nicht geprüft"
                          % (label or "<Eingabe>", number, MAX_LINE_CHARS), reason="lineTooLong", path=label)
                warned = number
        return None

    # ---------- Dateisystem ----------

    def search_path(self, root):
        """Durchsucht einen Startpfad rekursiv (Datei ODER Ordner)."""
        previous = self.search_root
        self.search_root = root if os.path.isabs(root) else os.path.abspath(root)
        try:
            with local_content_policy(self.local_only):
                self._search_path(root)
        finally:
            self.search_root = previous

    def _search_path(self, root):
        if not os.path.isdir(root):
            # Auch Pipes und Geräte haben einen Namen. Nur ihr Inhalt ist
            # gesperrt; visit_file prüft das vor jedem Öffnen gesondert.
            self.visit_file(root)
            return
        # followlinks=False: Symlink-Schleifen vermeiden.
        for dirpath, dirnames, filenames in os.walk(
            root, onerror=lambda err: self.report_warning(str(err), path=err.filename, error=err), followlinks=False
        ):
            self.report_progress(dirpath)
            if not self.include_hidden:
                # Unsichtbare Ordner gar nicht erst betreten (spart auch das
                # Durchsuchen von .git & Co.) und unsichtbare Dateien
                # überspringen. dirnames IN PLACE ändern, damit os.walk folgt.
                if self.report is not None:
                    for name in dirnames + filenames:
                        if self.is_hidden(name):
                            self.omission("hidden", os.path.join(dirpath, name))
                dirnames[:] = [d for d in dirnames if not self.is_hidden(d)]
                filenames = [f for f in filenames if not self.is_hidden(f)]
            # Der explizite Startordner ist die Wurzel und wird nicht gegen
            # seinen eigenen Namen geprüft. Seine Kinder müssen dagegen
            # schon vor Trefferausgabe und Abstieg ausgeschlossen werden.
            if self.exclusions:
                dirnames[:] = [d for d in dirnames
                               if not self.path_is_excluded(
                                   os.path.join(dirpath, d), root)]
            if self.directories_can_match:
                # Bei Namens-/Datumssuche zählen auch Ordner als Treffer. Das
                # passiert VOR dem Abschneiden unten: Ein Ordner GENAU auf der
                # Grenztiefe ist selbst noch ein erlaubter Treffer, nur sein
                # Inhalt nicht mehr (`find -maxdepth 1` listet die direkten
                # Unterordner ebenfalls).
                for dirname in dirnames:
                    if self.type_allowed(True):
                        folder = os.path.join(dirpath, dirname)
                        # Die zulässigen Ordnerkriterien öffnen keinen Strom.
                        probe = FileProbe(self, folder, dirname, None, None,
                                          folder, is_dir=True,
                                          relative_path=self.relative_file_path(folder, root))
                        self.evaluate(probe, folder, "dir")
            # Was in `dirpath` liegt, hat die Tiefe `depth_of + 1`. Nur wenn
            # dessen Unterordner noch erlaubt wären, weiter absteigen — sonst
            # käme eine Ebene zu viel mit (`--max-depth 1` = nur direkt im
            # Startpfad, wie `find -maxdepth 1`).
            if self.max_depth is not None \
                    and self.depth_of(root, dirpath) + 1 >= self.max_depth:
                for name in dirnames:
                    self.omission("folderDepth", os.path.join(dirpath, name))
                dirnames[:] = []
            if self.report is not None:
                for name in dirnames:
                    folder = os.path.join(dirpath, name)
                    if os.path.islink(folder):
                        self.omission("symlinkDirectory", folder)
            for filename in filenames:
                self.visit_file(os.path.join(dirpath, filename), root=root)

    def path_is_excluded(self, path, root=None):
        """Einzel-Startdateien gelten nur mit ihrem Namen; sonst relativ zur
        jeweiligen Suchwurzel. Diese bleibt ein Argument, kein Zustand, der
        auf den nächsten Startpfad oder auf Archive übergreifen könnte."""
        if not self.exclusions:
            return False
        relative = (os.path.relpath(path, root) if root is not None
                    else os.path.basename(path))
        matched = self.exclusions.matches(relative)
        if matched:
            self.omission("excludedPattern", path)
        return matched

    def relative_file_path(self, path, root=None):
        if not self.needs_relative_path:
            return None
        return os.path.relpath(path, root) if root is not None else os.path.basename(path)

    def relative_member_path(self, member_path):
        if not self.needs_relative_path:
            return None
        return Exclusions.normalize_pattern(member_path)[0]

    @staticmethod
    def depth_of(root, dirpath):
        """Wie viele Ordnerebenen liegt `dirpath` unter `root`?

        Der Startpfad selbst ist 0, ein Unterordner 1. Damit bedeutet
        `--max-depth 1` genau „nur was direkt im Startpfad liegt"."""
        relative = os.path.relpath(dirpath, root)
        if relative == os.curdir:
            return 0
        return relative.count(os.sep) + 1

    @staticmethod
    def file_facts(path, onerror=None):
        """(Größe, Änderungszeit, Erstellungszeit) einer Datei oder eines
        Ordners aus EINER stat-Abfrage; jeder Wert ist None, wenn er sich
        nicht ermitteln lässt (toter Symlink: alle drei).

        Die Erstellungszeit (`st_birthtime`) kennt macOS; ein Dateisystem
        oder System ohne sie liefert None statt eines Fehlers."""
        try:
            status = os.stat(path)
        except OSError as err:
            if onerror is not None:
                onerror(err)
            return None, None, None
        birth = getattr(status, "st_birthtime", None)
        return status.st_size, status.st_mtime, birth

    def visit_file(self, path, root=None):
        if not self.content_preview:
            return self._visit_file(path, root)
        previous = self.preview_source_generation
        self.preview_source_generation = source_generation(path)
        try:
            return self._visit_file(path, root)
        finally:
            self.preview_source_generation = previous

    def _visit_file(self, path, root=None):
        """Behandelt EINE Datei im Dateisystem: alle Kriterien gegen die
        Datei selbst, und — falls es ein Archiv ist — der Blick hinein."""
        # Vor jedem Öffnen, auch vor dem Rückfall auf rohe Archivbytes.
        if self.path_is_excluded(path, root):
            return
        name = os.path.basename(path)
        archive_kind = None if self.document_mode and os.path.splitext(name.lower())[1] in PACKAGE_DOCUMENT_READERS else classify_archive(name)
        if self.report is not None and archive_kind is None and name.lower().endswith(
                BSDTAR_NATIVE_EXTENSIONS + BSDTAR_ZSTD_TAR_EXTENSIONS + (ZSTD_SINGLE_EXTENSION,)):
            self.omission("archiveDepth" if self.archive_depth < 1 else
                          "archiveMetadata" if self.text_mode == "metadata" else
                          "toolUnavailable", path)
        # Bei einer Metadatensuche lohnt der Blick ins Archiv nicht: Ein
        # Eintrag hat keine Datei, die exiftool lesen könnte.
        # `os.path.isfile` erst als letzte Bedingung: Der Aufruf kostet
        # ein stat und läuft deshalb nur für Dateien, deren Endung
        # überhaupt ein Archiv verspricht. Er ist nötig, weil zipfile und
        # tarfile den Pfad selbst öffnen — an `open_regular_file()` vorbei.
        # Eine benannte Pipe namens `x.zip` ließ sonst den ganzen Lauf
        # hängen, sogar die reine Namenssuche.
        descend = (archive_kind is not None and self.archive_depth >= 1
                   and self.text_mode != "metadata"
                   and os.path.isfile(path))
        if archive_kind is not None and not descend:
            self.omission("archiveDepth" if self.archive_depth < 1 else
                          "archiveMetadata" if self.text_mode == "metadata" else
                          "notRegularFile", path)
        # Wird NICHT in das Archiv geschaut — weil --no-archives bzw.
        # --archive-depth 0 das verbietet oder weil die Endung gar kein
        # Archiv ist —, dann ist die Datei eine ganz normale Datei und
        # ihr roher Inhalt wird durchsucht. Genau das passiert auch mit
        # einer .7z ohne bsdtar; beide Fälle dürfen sich nicht
        # unterscheiden, sonst hinge es vom Zufall der installierten
        # Werkzeuge ab, ob eine Datei überhaupt angefasst wird. Bei der
        # Namenssuche zählt das Archiv selbst immer auch als Datei.
        def as_plain_file(content_available=True):
            probe = FileProbe(self, path, name,
                              open_stream=lambda: open_regular_file(path),
                              chunker=self.file_chunks,
                              filesystem_path=path,
                              relative_path=self.relative_file_path(path, root))
            probe.content_available = content_available
            self.evaluate(probe, path, "file")

        if descend and self.local_only:
            reason = local_content_reason(path)
            if reason is not None:
                self.report_warning("%s: %s; Archivinhalt ausgelassen" % (path, REPORT_REASONS[reason][1]),
                                    reason=reason, path=path)
                descend = False

        if descend and self.criteria_content_matchers:
            before = self.emitted
            if self.type_allowed(False) and self.text_mode != "content":
                as_plain_file(content_available=False)
            container_matched = self.emitted > before
            opened = self.search_archive(path, None, archive_kind, path, self.archive_depth)
            if not opened and not container_matched and self.type_allowed(False):
                as_plain_file()
            return

        if self.type_allowed(False) \
                and (self.text_mode != "content" or not descend):
            as_plain_file()
        elif descend and self.type_allowed(False):
            # Nur hier ist die Datei bisher ÜBERSPRUNGEN worden, weil ihr
            # Inhalt aus dem Archiv kommen sollte. Ist sie keines, muss
            # sie nachträglich als normale Datei geprüft werden.
            if not self.search_archive(path, None, archive_kind, path,
                                       self.archive_depth):
                as_plain_file()
            return
        if descend:
            self.search_archive(path, None, archive_kind, path,
                                self.archive_depth)

    # ---------- Archive ----------

    def search_archive(self, fs_path, fileobj, kind, display, depth,
                       archive_path=None, archive_members=()):
        """Durchsucht ein Archiv. Entweder liegt es als Datei auf der
        Platte (fs_path) oder als Bytes im Speicher (fileobj — das ist
        der Fall bei Archiven INNERHALB von Archiven).

        display ist der Anzeige-Pfad, z. B. "ordner/paket.zip" oder
        verschachtelt "aussen.zip!/innen.zip". depth zählt runter:
        bei 0 steigen wir nicht weiter in Unter-Archive ein.

        Liefert False, wenn die Datei trotz passender Endung gar kein
        Archiv dieses Formats ist — dann muss der Aufrufer sie wie eine
        ganz normale Datei behandeln. Sonst True."""
        self.report_progress(display)
        if archive_path is None:
            archive_path = fs_path
        key = archive_signature_key(
            kind, os.path.basename(display.rstrip("/")))
        # Einzelkompression VORAB prüfen, nicht erst am Fehler: walk_single
        # baut den einen Eintrag allein aus dem Dateinamen und öffnet die
        # Datei bei einer reinen Namenssuche gar nicht. Eine Textdatei
        # namens `notiz.gz` lieferte deshalb den Phantom-Treffer
        # `notiz.gz!/notiz`, den `--extract` nie auflösen kann. Bei diesen
        # Formaten steht die Hülle immer am Anfang, die Prüfung ist also
        # eindeutig — anders als bei einem ISO, das sich nicht immer
        # ankündigt und dessen Rückfall deshalb erst nach dem Fehlversuch
        # entschieden wird.
        if kind in SINGLE_COMPRESSION_KINDS \
                and not announces_archive_format(
                    key, self.archive_head(key, fs_path, fileobj)):
            return False
        emitted_before = self.emitted
        try:
            if kind == "zip":
                source = fileobj if fileobj is not None else fs_path
                with zipfile.ZipFile(source) as archive:
                    self.walk_zip(archive, display, depth, archive_path,
                                  archive_members)
            elif kind == "tar":
                # tarfile erkennt die Kompression selbst ("r:*").
                try:
                    if fileobj is not None:
                        archive = tarfile.open(fileobj=fileobj, mode="r:*")
                    else:
                        archive = tarfile.open(fs_path, mode="r:*")
                except tarfile.ReadError:
                    # Kein Tar in der Hülle? Dann ist es eine einzeln
                    # komprimierte Datei — siehe tar_envelope_kind().
                    # Scheitert auch das Entpacken, greift unten die
                    # normale Behandlung: Die Hüllen-Signatur macht die
                    # Datei zum beschädigten Archiv mit Warnung.
                    envelope = tar_envelope_kind(
                        os.path.basename(display.rstrip("/")),
                        self.archive_head("tar", fs_path, fileobj))
                    if envelope is None:
                        raise
                    if fileobj is not None:
                        fileobj.seek(0)
                    self.walk_single(envelope, fs_path, fileobj, display,
                                     depth, archive_path, archive_members)
                else:
                    with archive:
                        self.walk_tar(archive, display, depth, archive_path,
                                      archive_members)
            elif kind == "bsdtar":
                self.walk_bsdtar(fs_path, fileobj, display, depth,
                                 archive_path, archive_members)
            else:  # Einzelkompression: kind ist die Endung, z. B. ".gz"
                self.walk_single(kind, fs_path, fileobj, display, depth,
                                 archive_path, archive_members)
        except EXPECTED_ARCHIVE_ERRORS as err:
            # Die Endung versprach ein Archiv. Ob der Inhalt dasselbe
            # verspricht, entscheidet erst die Signatur — hinter demselben
            # Fehler stecken zwei sehr verschiedene Fälle:
            #
            #  - Keine Signatur: Die Endung war schlicht mehrdeutig
            #    (`.key` ist meist ein TLS-Schlüssel). Die Datei ist eine
            #    ganz normale Datei, und der Aufrufer behandelt sie wie bei
            #    `--no-archives`. Keine Warnung — das ist der Normalfall,
            #    und genau das verlangt der Vertrag: Alle Gründe, NICHT ins
            #    Archiv zu schauen, müssen dasselbe Ergebnis liefern.
            #  - Signatur vorhanden: Die Datei IST ein Archiv dieses
            #    Formats und trotzdem nicht zu öffnen, also beschädigt.
            #    Sie stattdessen als Rohbytes zu durchsuchen liefert
            #    Unsinn — ein ungepackter Eintrag eines abgeschnittenen
            #    Zips kam als ganz gewöhnlicher Dateitreffer heraus, und
            #    dass das Archiv kaputt ist, erfuhr niemand.
            #
            # Das gilt für JEDES Format, nicht nur für Zip und Tar. Bis
            # 0.34.10 kannte nur deren Öffnungsfehler diesen Rückfall;
            # eine Textdatei namens `notes.7z` oder `image.iso` fiel
            # deshalb mit Warnung aus der Suche, während dieselbe Datei
            # ohne installiertes bsdtar ganz normal durchsucht wurde. Genau
            # das darf nicht sein: Der Zufall der installierten Werkzeuge
            # darf nicht entscheiden, ob eine Datei angefasst wird.
            #
            # Hat der Lauf aus diesem Archiv schon Treffer gemeldet, ist
            # der Rückfall ausgeschlossen — sonst käme dieselbe Datei ein
            # zweites Mal, jetzt als Dateitreffer.
            if self.emitted == emitted_before \
                    and not announces_archive_format(
                        key, self.archive_head(key, fs_path, fileobj)):
                return False
            if isinstance(err, FORMAT_MISMATCH_ERRORS):
                self.report_warning("%s: beschädigtes Archiv: %s" % (display, err), reason="damagedArchive", path=display)
            else:
                self.report_warning("%s: %s" % (display, err), path=display, error=err)
        return True

    @staticmethod
    def archive_head(key, fs_path, fileobj):
        """Der Anfang des Archivs für die Signaturprüfung.

        Gelesen wird nur, was das Format `key` wirklich braucht — vier
        Bytes für ein Zip, 36 KB für ein ISO.

        Lässt der Anfang sich nicht lesen, gilt die Datei als nicht
        angekündigt und wird als ganz normale Datei behandelt — der stille
        Rückfall ist der schonendere der beiden Wege."""
        length = signature_head_bytes(key)
        if not length:
            return b""
        try:
            if fileobj is not None:
                fileobj.seek(0)
                return fileobj.read(length)
            with open_regular_file(fs_path) as handle:
                return handle.read(length)
        except EXPECTED_ARCHIVE_ERRORS:
            return b""

    @staticmethod
    def member_is_hidden(member_path):
        """Prüft jede Pfadkomponente, nicht nur den sichtbaren Blattnamen."""
        components = re.split(r"[/\\]+", member_path)
        # "." und ".." benennen ein Verzeichnis, sie sind kein versteckter
        # NAME. Ohne diese Ausnahme galt jeder Eintrag eines mit
        # `tar -cf x.tar -C ordner .` gebauten Archivs als versteckt —
        # also der übliche Weg, einen Ordnerinhalt zu tarren —, und das
        # ganze Archiv fiel ohne Meldung aus jeder Suche.
        return any(component.startswith(".") for component in components
                   if component and component not in (".", ".."))

    def visit_member(self, member_path, is_dir, open_member, display, depth,
                     archive_path, archive_members, size=None,
                     compressed_size=None, modified=None):
        """Gemeinsame Logik für EINEN Archiv-Eintrag (Zip wie Tar).

        member_path: Pfad innerhalb des Archivs.
        read_bytes:  Funktion, die den Inhalt liefert (lazy — wird nur
                     aufgerufen, wenn wir den Inhalt wirklich brauchen).
        size:        entpackte Größe des Eintrags in Bytes (bei Ordnern None).
        modified:    Änderungszeit des Eintrags als Unix-Zeit, None wenn das
                     Format sie nicht nennt (bsdtar, einzeln komprimiert).
        """
        # Der Wurzeleintrag eines mit `tar -cf x.tar -C ordner .` gebauten
        # Archivs heißt "./" — das ist das Archiv selbst, kein Eintrag
        # darin. Seit "." nicht mehr als versteckter Name gilt, käme er
        # sonst als Ordnertreffer mit dem Namen "." heraus, den
        # `--extract` nicht auflösen kann (nackter KeyError, Exit 2).
        if member_path.strip("/") in ("", ".", ".."):
            return

        # Anzeige ohne Ordnersuffix; die Identität behält den echten Namen.
        displayed_member = member_path.rstrip("/") if is_dir else member_path
        full_display = display + "!/" + displayed_member
        member_chain = tuple(archive_members) + (member_path,)
        name = os.path.basename(member_path.rstrip("/"))

        # Unsichtbare Archiv-Einträge wie im Dateisystem überspringen.
        if not self.include_hidden and self.member_is_hidden(member_path):
            self.omission("hidden", full_display)
            return

        # Jede Archivebene hat ihre eigene Wurzel. Direkt member_path prüfen,
        # niemals display an `!/` zerlegen: Ein echter Name darf `!` enthalten.
        if self.exclusions.matches(member_path):
            self.omission("excludedPattern", full_display)
            return

        if is_dir:
            # Archivordner nennen teils ihre Änderungszeit, nie ihre Größe.
            if self.directories_can_match and self.type_allowed(True):
                probe = FileProbe(self, full_display, name, None, None,
                                  archive_path, in_archive=True,
                                  modified=modified, is_dir=True,
                                  relative_path=self.relative_member_path(member_path))
                self.evaluate(probe, full_display, "member",
                              filesystem_path=archive_path,
                              archive_members=member_chain)
            return

        nested_kind = None if self.document_mode and os.path.splitext(name.lower())[1] in PACKAGE_DOCUMENT_READERS else classify_archive(name)
        if self.report is not None and nested_kind is None and name.lower().endswith(
                BSDTAR_NATIVE_EXTENSIONS + BSDTAR_ZSTD_TAR_EXTENSIONS + (ZSTD_SINGLE_EXTENSION,)):
            self.omission("archiveDepth" if depth - 1 < 1 else "toolUnavailable", full_display)
        nested = nested_kind is not None and depth - 1 >= 1
        if nested_kind is not None and not nested:
            self.omission("archiveDepth", full_display)
        # Ein und derselbe Eintrag wird im ungünstigen Fall zweimal gelesen:
        # einmal für den Blick ins Unterarchiv und einmal als ganz normaler
        # Eintrag. Es sind beide Male dieselben Bytes, und sie dürfen das
        # Gesamtbudget des Laufs nur EINMAL belasten. `counted` merkt
        # deshalb, wie weit dieser Eintrag schon gezählt wurde; alles
        # darüber hinaus zählt wie immer voll. Ohne diese Marke verschwand
        # ein 20-Byte-Eintrag `fake.zip` bei --max-archive-total-bytes 20
        # aus der Trefferliste, sobald --archive-depth 2 den Blick ins
        # vermeintliche Unterarchiv überhaupt erlaubte — bei Tiefe 1 wurde
        # er gefunden. Genauso bei einer Maßsuche, die den Bildkopf schon
        # vor dem Rekursionsversuch gelesen hat.
        counted = [0]

        def chunker(handle, free_bytes=0):
            read = 0
            for chunk in self.archive_budget.iter_chunks(
                    handle, full_display, size, compressed_size,
                    free_bytes=max(counted[0], free_bytes)):
                read += len(chunk)
                counted[0] = max(counted[0], read)
                yield chunk

        def as_plain_member(open_stream=None, content_available=True):
            """Der Eintrag als ganz normaler Eintrag: sein roher Inhalt wird
            durchsucht.

            Wird in diesen Eintrag NICHT hineingeschaut — weil die
            --archive-depth aufgebraucht ist oder weil er gar kein Archiv
            ist —, dann gilt dieselbe Regel wie eine Ebene höher in
            visit_file(). Ohne das entschiede auch hier der Grund über das
            Ergebnis: ein .7z ohne bsdtar wurde durchsucht, ein .zip an der
            Tiefengrenze dagegen nicht.

            open_stream reicht einen schon entpackten Puffer durch, damit
            ein gescheiterter Blick ins Unterarchiv den Eintrag nicht ein
            zweites Mal entpacken muss."""
            probe = FileProbe(self, full_display, name,
                              open_stream=open_stream or open_member,
                              chunker=chunker,
                              filesystem_path=archive_path, size=size,
                              in_archive=True, modified=modified,
                              relative_path=self.relative_member_path(member_path))
            probe.content_available = content_available
            self.evaluate(probe, full_display, "member",
                          filesystem_path=archive_path,
                          archive_members=member_chain)

        before = self.emitted
        if self.type_allowed(False) \
                and (self.text_mode != "content" or not nested):
            as_plain_member(content_available=not (nested and self.criteria_content_matchers))
        container_matched = self.emitted > before

        if nested:
            # Archiv im Archiv: Inhalt in den Speicher holen und rekursiv
            # weitersuchen (depth sinkt um 1).
            try:
                with open_member() as handle:
                    data = b"".join(chunker(handle))
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.report_warning("%s: %s" % (full_display, err), path=full_display, error=err)
                return
            opened = self.search_archive(None, io.BytesIO(data), nested_kind,
                                         full_display, depth - 1,
                                         archive_path=archive_path,
                                         archive_members=member_chain)
            # Dieselbe Regel wie eine Ebene höher in visit_file(): Verspricht
            # die Endung ein Archiv und ist der Eintrag keines, dann ist er
            # ein ganz normaler Eintrag. Ohne das fiel ein `server.key` in
            # einem Zip ab `--archive-depth 2` ohne jede Meldung aus der
            # Inhaltssuche — bei `--archive-depth 1` wurde er gefunden.
            # Der Puffer von oben wird dabei weitergereicht: Der Eintrag ist
            # schon entpackt, ein zweites Entpacken brächte nichts.
            if not opened and self.type_allowed(False) \
                    and (self.text_mode == "content" or
                         (self.criteria_content_matchers and not container_matched)):
                as_plain_member(lambda: io.BytesIO(data))

    def walk_zip(self, archive, display, depth, archive_path,
                 archive_members):
        """Geht alle Einträge eines Zip-Archivs durch."""
        for info in archive.infolist():
            # getinfo() wählt beim Auspacken den letzten gleichnamigen
            # Eintrag. Nur dieser darf auch Suchtreffer liefern.
            if archive.getinfo(info.filename) is not info:
                continue
            self.visit_member(
                info.filename,
                info.is_dir(),
                lambda info=info: archive.open(info, "r"),
                display,
                depth,
                archive_path,
                archive_members,
                size=info.file_size,
                compressed_size=info.compress_size,
                modified=zip_member_mtime(info),
            )

    def walk_tar(self, archive, display, depth, archive_path,
                 archive_members):
        """Geht alle Einträge eines Tar-Archivs durch.

        Anders als bei Zip wird hier KEIN compressed_size übergeben, und damit
        greift die Kompressionsverhältnis-Prüfung aus ArchiveBudget nicht: Ein
        Tar komprimiert als Ganzes, nicht pro Eintrag — eine Einzelgröße gibt
        es schlicht nicht. Gegen eine Entpack-Bombe schützen bei Tar deshalb
        allein die Byte-Budgets (Einzel- und Gesamtgrenze), die beim Lesen
        greifen. Das ist kein Versehen, sondern die Grenze des Formats."""
        # Direkt iterieren statt getmembers(): So können wir abbrechen,
        # bevor tarfile den vollständigen, unbegrenzten Katalog aufgebaut
        # hat. Erst NACH dem vollständigen, begrenzten Katalog Einträge
        # besuchen: Ein abgeschnittenes Tar darf keinen Treffer aus seinem
        # lesbaren Anfang ausgeben und danach nur eine Warnung melden.
        # Wie bei der Extraktion gewinnt der letzte gleichnamige Eintrag.
        # Der vollständige Katalog bleibt in archive erhalten: Hardlinks
        # dürfen weiterhin auf frühere Einträge zeigen.
        members = bounded_tar_members(archive)
        members_by_name = {member.name: member for member in members}
        # Die Gewinner in physischer Reihenfolge lesen: Rückwärtssprünge
        # würden bei gzip den komprimierten Strom jedes Mal neu entpacken.
        for member in members:
            if members_by_name[member.name] is not member:
                continue
            def open_member(member=member):
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise tarfile.TarError("Eintrag nicht lesbar")
                return extracted
            self.visit_member(member.name, member.isdir(), open_member,
                              display, depth, archive_path, archive_members,
                              size=member.size, modified=member.mtime)

    def walk_single(self, extension, fs_path, fileobj, display, depth,
                    archive_path, archive_members):
        """Behandelt eine einzeln komprimierte Datei (.gz/.bz2/.xz) wie ein
        Archiv mit genau EINEM Eintrag: dem entpackten Inhalt.

        Der Eintragsname ist der Dateiname ohne die Kompressionsendung
        („notiz.txt.gz" enthält „notiz.txt"). Dadurch greifen Namenssuche,
        Inhaltssuche, !/-Notation und Extraktion genauso wie bei Zip und
        Tar — und ein „inner.zip.gz" wird über die normale Verschachtelung
        weiter durchsucht (kostet wie jedes Archiv im Archiv eine Stufe
        --archive-depth).

        Die entpackte Größe ist bei diesen Formaten vorab nicht verlässlich
        bekannt (size=None); die Byte-Budgets greifen deshalb erst beim
        Lesen, eine Kompressionsverhältnis-Prüfung ist nicht möglich."""
        opener = single_opener(extension)
        name = os.path.basename(display.rstrip("/"))
        member_name = single_member_name(name, extension)
        if fileobj is not None:
            # Archiv im Archiv: Die komprimierten Bytes liegen im Speicher.
            # Für den zweiten Lesedurchlauf (Vortest + Zeilennummer) braucht
            # open_member() jedes Mal einen frischen Datenstrom.
            data = fileobj.getvalue()

            def open_member():
                return opener(io.BytesIO(data), "rb")
        else:
            def open_member():
                return opener(fs_path, "rb")
        self.visit_member(member_name, False, open_member, display, depth,
                          archive_path, archive_members, size=None)

    def walk_bsdtar(self, fs_path, fileobj, display, depth, archive_path,
                    archive_members):
        """Durchsucht ein Format, das nur das externe bsdtar lesen kann
        (7z, ISO, tar.zst): Auflistung über `bsdtar -tf`, Inhalt je
        Eintrag als Datenstrom über `bsdtar -xOf`.

        Liegt das Archiv nur im Speicher (Archiv im Archiv), wird es in
        eine Temp-Datei geschrieben — 7z und ISO brauchen wahlfreien
        Zugriff und lassen sich nicht verlässlich von stdin lesen.

        Ordner-Erkennung: Der Typ kommt aus einer zweiten, ausführlichen
        Auflistung (`bsdtar -tvf`, siehe bsdtar_listing_entries) — 7z
        listet Ordner mit Schrägstrich am Ende, ISO ohne, und ein LEERER
        Ordner in einem ISO war deshalb bis 0.31.3 eine Datei. Nur wenn
        sich die beiden Auflistungen nicht zeilenweise decken, gilt die
        alte Heuristik: Schrägstrich am Ende oder Einträge darunter.
        Kosten: je bsdtar-Archiv zwei Prozesse (`-tf` und `-tvf`), und
        beide Auflistungen werden bis MAX_ARCHIVE_LISTING_BYTES gepuffert.
        Größen liefert die Auflistung nicht (size=None), die Byte-Budgets
        greifen beim Lesen."""
        bsdtar, _, env = external_archive_tools()
        temp_path = None
        path = fs_path
        try:
            if fileobj is not None:
                handle = tempfile.NamedTemporaryFile(delete=False)
                with handle:
                    handle.write(fileobj.getvalue())
                temp_path = handle.name
                path = temp_path
            raw, errors, status = bsdtar_list(bsdtar, path, env)
            if status != 0:
                # Kein Tar in der Zstandard-Hülle eines `.tar.zst`? Dann ist
                # es eine einzeln komprimierte Datei — siehe
                # tar_envelope_kind(). Nur bei gescheiterter Auflistung,
                # nicht bei einer zu langen: Die beweist ein echtes Archiv.
                name = os.path.basename(display.rstrip("/"))
                if name.lower().endswith(ZSTD_SINGLE_EXTENSION):
                    envelope = tar_envelope_kind(name, self.archive_head(
                        ZSTD_SINGLE_EXTENSION, fs_path, fileobj))
                    if envelope is not None:
                        self.walk_single(envelope, fs_path, fileobj, display,
                                         depth, archive_path, archive_members)
                        return
                raise ArchiveReadError(
                    errors.decode("utf-8", "replace").strip()
                    or "bsdtar konnte das Archiv nicht lesen")
            # Zweite Auflistung nur für den Typ; ihr Status zählt nicht,
            # denn die Namen kommen aus der ersten. Fehlt sie oder passt
            # sie nicht zeilenweise, bleibt is_dir None (Heuristik unten).
            # Reißt allein die längere -tvf-Liste die Grenze, fällt nicht
            # das Archiv aus, sondern nur die Typbestimmung.
            listing_reason = "readError"
            try:
                verbose, _, verbose_status = bsdtar_list(bsdtar, path, env,
                                                         verbose=True)
            except ArchiveReadError as err:
                listing_reason = report_error_reason(err)
                verbose, verbose_status = None, 1
            entries = bsdtar_listing_entries(
                raw, verbose if verbose_status == 0 else None)
            dir_names = set()
            if any(is_dir is None for _, is_dir in entries):
                self.report_warning("%s: Eintragstypen nicht bestimmbar, Ordner "
                          "werden geschätzt" % display, reason=listing_reason, path=display)
                # Nur der Rückfall braucht Elternnamen. Bei bekannten
                # Typen entfällt der sonst unbenutzte vollständige Satz.
                for name, _ in entries:
                    clean = name.rstrip("/")
                    if name.endswith("/"):
                        dir_names.add(clean)
                    parts = clean.split("/")
                    for count in range(1, len(parts)):
                        dir_names.add("/".join(parts[:count]))
            seen = set()
            for name, is_dir in entries:
                clean = name.rstrip("/")
                if clean in seen:
                    continue
                seen.add(clean)
                if is_dir is None:
                    is_dir = clean in dir_names

                def open_member(member=clean):
                    proc = subprocess.Popen(
                        # `-q` beendet die Extraktion nach dem ersten
                        # passenden Eintrag. Ohne das wurden doppelte Namen
                        # aneinandergehängt und als eine Datei durchsucht.
                        [bsdtar, "-xqOf", path, "--",
                         bsdtar_escape(member)],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        env=env)
                    return ToolStream(proc, display + "!/" + member)
                self.visit_member(clean, is_dir, open_member,
                                  display, depth, archive_path,
                                  archive_members, size=None)
        finally:
            if temp_path is not None:
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass


def pick_member(remaining, names):
    """Welcher Eintrag dieser Archivebene gemeint ist, und wie viele Teile
    der !/-Kette er verbraucht.

    `remaining` sind die restlichen Teile der Kette, `names` die Eintrags-
    namen des Archivs (None = nicht auflösen, der erste Teil ist der Name).
    Enthält ein Eintragsname selbst "!/", zerlegt ihn die Notation in
    mehrere Teile; gewählt wird deshalb der LÄNGSTE Anfang der Kette, der
    als Eintrag existiert. Ohne Treffer bleibt es beim ersten Teil — die
    folgende Fehlermeldung nennt dann den fehlenden Eintrag."""
    if names is None or len(remaining) == 1:
        return remaining[0], 1
    known = set(names)
    for count in range(len(remaining), 0, -1):
        candidate = "!/".join(remaining[:count])
        if candidate in known:
            return candidate, count
    return remaining[0], 1


def snapshot_position(record, local_only=False):
    """Belegt eine aktuelle Fundzeile am begrenzten Blattinhalt. Das ist
    keine Zusage über den früheren Inhalt des Suchlaufs. Matcher und
    Zeilenzählung kommen unverändert aus dem Suchkern."""
    required = {"path", "mode", "pattern", "terms", "regex", "caseSensitive",
                "exact", "literalWildcards"}
    if not isinstance(record, dict) or not required <= set(record) \
            or set(record) - required - {"encoding"} \
            or record.get("encoding", "utf-8") not in ("auto",) + tuple(TEXT_ENCODINGS) \
            or not isinstance(record["path"], str) \
            or not os.path.isabs(record["path"]) \
            or record["mode"] not in ("name", "content", "metadata") \
            or not isinstance(record["pattern"], str) \
            or not isinstance(record["terms"], list) \
            or not all(isinstance(term, str) and term for term in record["terms"]) \
            or not all(type(record[key]) is bool for key in
                       ("regex", "caseSensitive", "exact", "literalWildcards")):
        raise ValueError("ungültiger Positionsauftrag")
    if local_only:
        reason = local_content_reason(record["path"])
        if reason is not None:
            raise LocalContentError(reason)
    with open_regular_file(record["path"]) as stream:
        before = os.fstat(stream.fileno())
        data = stream.read(262_145)
        after = os.fstat(stream.fileno())
    generation = lambda value: (value.st_dev, value.st_ino, value.st_size,
                                value.st_mtime_ns, value.st_ctime_ns)
    if len(data) > 262_144:
        raise ValueError("Blattinhalt überschreitet 262144 Bytes")
    if generation(before) != generation(after):
        raise ValueError("Blattinhalt wurde während der Prüfung verändert")
    result = {"sha256": hashlib.sha256(data).hexdigest(), "location": 0,
              "length": 0, "positionBinding": "unboundHit"}
    requested = record.get("encoding", "utf-8")
    info = {}
    try:
        text = "".join(decoded_text_chunks([data], requested, errors="strict", info=info))
    except UnicodeDecodeError:
        return result
    result["contentEncoding"] = info["decoder"]
    # Der Standardleser behält seine historische UTF-8-BOM im Suchtext.
    # Der Empfänger entfernt genau die Datei-BOM, kein weiteres U+FEFF.
    target_text = text[1:] if requested == "utf-8" and data.startswith(codecs.BOM_UTF8) else text
    result.update(textSHA256=hashlib.sha256(target_text.encode("utf-8")).hexdigest(),
                  textUTF16Length=len(target_text.encode("utf-16-le")) // 2,
                  consumedBOMBytes=len(data) - len(text.encode(TEXT_ENCODINGS[info["decoder"]])))
    terms = list(dict.fromkeys(([record["pattern"]] if record["pattern"] else []) + record["terms"]))
    if record["mode"] != "content" or not terms:
        return result
    if "\0" in text:
        return result
    matchers = [build_matcher(term, record["regex"], record["caseSensitive"],
                             exact=record["exact"],
                             literal_wildcards=record["literalWildcards"],
                             text_wildcards=True) for term in terms]
    search = Search(matchers[0], True, 0, False, extra_matchers=matchers[1:],
                    text_encoding=requested)
    lines = search.match_content_all(iter([data]), matchers)
    if lines is None:
        raise ValueError("Treffer passt nicht mehr zum aktuellen Blattinhalt")
    # Python zählt auch VT/FF/Unicode-Trenner. Fastra entfernt eine UTF-8-BOM,
    # behält aber die Zeilentrenner; deshalb direkt UTF-16-Offsets übertragen.
    pieces = text.splitlines(keepends=True)
    number = lines[0]
    prefix = "".join(pieces[:number - 1])
    line = pieces[number - 1].splitlines()[0] if pieces[number - 1].splitlines() else ""
    if requested == "utf-8" and data.startswith(codecs.BOM_UTF8):
        if prefix:
            prefix = prefix[1:]
        elif line.startswith("\ufeff"):
            line = line[1:]
    result.update(location=len(prefix.encode("utf-16-le")) // 2,
                  length=len(line.encode("utf-16-le")) // 2,
                  positionBinding="exactUTF16", line=number,
                  decoder=info["decoder"] + "; Python splitlines")
    return result


def extract_result(result_path=None, filesystem_path=None, archive_members=None,
                   archive_member_bytes=None,
                   max_archive_member_bytes=DEFAULT_MAX_ARCHIVE_MEMBER_BYTES,
                   max_archive_total_bytes=DEFAULT_MAX_ARCHIVE_TOTAL_BYTES,
                   max_archive_ratio=DEFAULT_MAX_ARCHIVE_RATIO,
                   materialization_root=None, local_only=False):
    """Packt einen Suchtreffer für die Weiterverwendung aus.

    Eingabe ist ein Treffer-Pfad, wie ihn die Suche ausgibt — entweder
    ein normaler Dateipfad oder die !/-Notation für Archiv-Einträge
    (auch verschachtelt: "aussen.zip!/innen.zip!/datei.txt").

    Normale Pfade werden nur geprüft und absolut ausgegeben; Archiv-
    Einträge werden in einen frischen Temp-Ordner extrahiert. In beiden
    Fällen landet der nutzbare Datei-Pfad auf stdout (genau eine Zeile).
    Das ist der Unterbau für Öffnen/„Öffnen mit"/Drag&Drop in der GUI."""
    # Kam der Pfad in !/-Notation, ist die Zerlegung mehrdeutig: Ein
    # Eintragsname darf selbst "!/" enthalten (Test-Fixture "odd!/name.txt").
    # Dann wird unten je Archivebene gegen die Eintragsliste aufgelöst.
    ambiguous = False
    if filesystem_path is None:
        # Ein existierender Pfad gewinnt immer gegen die historische !/-Notation.
        # Damit bleibt z. B. /tmp/folder!/plain.txt eine normale Datei.
        if result_path is not None and search_path_exists(result_path, local_only):
            filesystem_path = result_path
            archive_members = []
        else:
            parts = (result_path or "").split("!/")
            filesystem_path = parts[0]
            archive_members = parts[1:]
            ambiguous = len(archive_members) > 1
    fs_path = filesystem_path
    if local_only:
        reason = local_content_reason(fs_path)
        if reason is not None:
            print("favenio: fehler: %s: %s" % (fs_path, REPORT_REASONS[reason][1]), file=sys.stderr)
            return 2
    members = list(archive_members or [])
    if archive_member_bytes is not None:
        if len(archive_member_bytes) != len(members):
            print("favenio: fehler: archiveMemberBytes passt nicht zu "
                  "archiveMembers", file=sys.stderr)
            return 2
        try:
            members = [decode_archive_member(item)
                       for item in archive_member_bytes]
        except (UnicodeEncodeError, UnicodeDecodeError, ValueError) as err:
            print("favenio: fehler: ungültige archiveMemberBytes: %s" % err,
                  file=sys.stderr)
            return 2
    display_path = result_path or fs_path + "".join(
        "!/" + member for member in members)
    if not os.path.exists(fs_path):
        print("favenio: fehler: Pfad existiert nicht: %s" % fs_path,
              file=sys.stderr)
        return 2
    if not members:
        # Kein Archiv-Eintrag, nur eine normale Datei: nichts auszupacken.
        write_result([os.path.abspath(fs_path)])
        return 0

    kind = classify_archive(fs_path)
    data = None    # Bytes des aktuellen Archivs (None = liegt als Datei vor)
    # Name des Archivs der aktuellen Ebene — bei Einzelkompression bestimmt
    # er den einzig gültigen Eintragsnamen (Dateiname ohne Endung).
    container_name = os.path.basename(fs_path.rstrip("/"))
    budget = ArchiveBudget(max_archive_member_bytes,
                           max_archive_total_bytes,
                           max_archive_ratio)
    try:
        # Ebene für Ebene absteigen: erst das Archiv auf der Platte
        # öffnen, dann ggf. innere Archive aus dem Speicher heraus.
        # `index` zeigt auf den nächsten Teil der !/-Kette; eine Ebene kann
        # mehrere Teile verbrauchen, wenn der Eintragsname "!/" enthält.
        index = 0
        while index < len(members):
            remaining = members[index:]
            if kind is None:
                print("favenio: fehler: kein unterstütztes Archiv: %s"
                      % display_path, file=sys.stderr)
                return 2
            if kind == "zip":
                source = io.BytesIO(data) if data is not None else fs_path
                with zipfile.ZipFile(source) as archive:
                    names = archive.namelist() if ambiguous else None
                    member, used = pick_member(remaining, names)
                    try:
                        info = archive.getinfo(member)
                    except KeyError:
                        # Ein Ordner steht im Zip-Katalog MIT Schrägstrich,
                        # im Treffer ohne. Ohne diese Prüfung meldete
                        # `--extract 'paket.zip!/ordner'` „There is no item
                        # named 'ordner'", obwohl der Eintrag existiert.
                        if (member + "/") in archive.namelist():
                            raise DirectoryMemberError(member) from None
                        raise
                    if info.is_dir():
                        # Mit Schrägstrich (`paket.zip!/ordner/`) findet
                        # getinfo() den Ordner direkt; ohne diese Prüfung
                        # entstand eine leere Datei mit Exit 0
                        # (Code-Review 2026-09-18).
                        raise DirectoryMemberError(member)
                    with archive.open(info, "r") as handle:
                        data = budget.read_all(
                            handle, display_path, info.file_size,
                            info.compress_size)
            elif kind == "tar":
                try:
                    if data is not None:
                        archive = tarfile.open(fileobj=io.BytesIO(data),
                                               mode="r:*")
                    else:
                        archive = tarfile.open(fs_path, mode="r:*")
                except tarfile.ReadError:
                    # Dieselbe Regel wie in search_archive(): Steckt in der
                    # Hülle kein Tar, ist es eine einzeln komprimierte
                    # Datei. Suche und --extract MÜSSEN denselben
                    # Eintragsnamen sehen, sonst findet pick_member() einen
                    # gefundenen Eintrag nicht wieder.
                    head = data[:signature_head_bytes("tar")] \
                        if data is not None \
                        else Search.archive_head("tar", fs_path, None)
                    envelope = tar_envelope_kind(container_name, head)
                    if envelope is None:
                        raise
                    kind = envelope
                    continue
                with archive:
                    tar_members = bounded_tar_members(archive)
                    names = ([name for item in tar_members
                              for name in ((item.name, item.name.rstrip("/") + "/")
                                           if item.isdir() else (item.name,))]
                             if ambiguous else None)
                    member, used = pick_member(remaining, names)
                    # tarfile speichert Ordnernamen ohne Schrägstrich; ein
                    # Aufruf mit `paket.tar!/ordner/` endete deshalb mit
                    # einem nackten KeyError (Code-Review 2026-09-18).
                    wanted = (member, member.rstrip("/"))
                    tar_member = next((item for item in reversed(tar_members)
                                       if item.name in wanted), None)
                    if tar_member is None:
                        raise KeyError(member)
                    if tar_member.isdir():
                        # Sonst lieferte extractfile() None, und die
                        # Meldung bestand nur aus dem nackten Namen.
                        raise DirectoryMemberError(member)
                    handle = archive.extractfile(member)
                    if handle is None:
                        raise KeyError(member)
                    with handle:
                        data = budget.read_all(
                            handle, display_path, tar_member.size)
            elif kind == "bsdtar":
                bsdtar, _, env = external_archive_tools()
                temp_path = None
                path = fs_path
                try:
                    if data is not None:
                        # Inneres Archiv liegt im Speicher: bsdtar braucht
                        # eine echte Datei (wahlfreier Zugriff).
                        temp_handle = tempfile.NamedTemporaryFile(
                            delete=False)
                        with temp_handle:
                            temp_handle.write(data)
                        temp_path = temp_handle.name
                        path = temp_path
                    names = None
                    # Bei `.tar.zst` entscheidet wie in walk_bsdtar() eine
                    # GESCHEITERTE Auflistung, ob in der Zstandard-Hülle
                    # überhaupt ein Tar steckt — dieselbe Regel, sonst wäre
                    # ein gefundener Treffer `notiz.tar.zst!/notiz.tar`
                    # nicht auszupacken. Gefragt wird erst, wenn bsdtar
                    # gescheitert ist: Ein echtes tar.zst soll nicht für
                    # eine vorsorgliche Auflistung ein zweites Mal
                    # entpackt werden.
                    def zst_envelope():
                        if not container_name.lower().endswith(
                                ZSTD_SINGLE_EXTENSION):
                            return None
                        head = data[:signature_head_bytes(
                            ZSTD_SINGLE_EXTENSION)] if data is not None \
                            else Search.archive_head(
                                ZSTD_SINGLE_EXTENSION, fs_path, None)
                        return tar_envelope_kind(container_name, head)

                    if ambiguous:
                        # Eintragsliste nur im mehrdeutigen Fall erfragen —
                        # sie kostet einen eigenen bsdtar-Prozess.
                        # Derselbe Weg wie in walk_bsdtar — Suche und
                        # --extract müssen denselben Eintragsnamen sehen.
                        # Der Status wird ausgewertet: Blieb er früher
                        # unbeachtet, war `names` bei einem kaputten
                        # Archiv einfach leer, pick_member() fiel auf
                        # remaining[0] zurück und der Nutzer bekam eine
                        # Meldung über einen fehlenden Eintrag statt über
                        # das unlesbare Archiv.
                        raw, errors, status = bsdtar_list(bsdtar, path, env)
                        if status != 0:
                            envelope = zst_envelope()
                            if envelope is not None:
                                kind = envelope
                                continue
                            raise ArchiveReadError(
                                errors.decode("utf-8", "replace").strip()
                                or "bsdtar konnte das Archiv nicht lesen")
                        # rstrip("/") wie in walk_bsdtar: Ein Ordnereintrag
                        # steht im Treffer ohne Schrägstrich, und genau
                        # diesen Namen sucht pick_member() hier wieder.
                        names = [name.rstrip("/") for name
                                 in bsdtar_listing_names(raw)]
                    member, used = pick_member(remaining, names)
                    try:
                        # `-n`: Das Muster trifft nur den Eintrag selbst.
                        # Ohne es liefert ein Ordner-Eintrag alle Dateien
                        # darunter aneinandergehängt (belegt 2026-09-17
                        # mit 7z, ISO und tar.zst), und die Prüfung auf
                        # null Bytes unten sähe ihn nie.
                        proc = subprocess.Popen(
                            [bsdtar, "-xqOnf", path, "--",
                             bsdtar_escape(member)],
                            stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=env)
                        # Erst nach dem Schließen übernehmen: ToolStream
                        # meldet den Fehlerstatus erst in close(), und
                        # zst_envelope() braucht dann noch die alten Bytes.
                        with ToolStream(proc, display_path) as handle:
                            extracted = budget.read_all(handle, display_path)
                        data = extracted
                    except ArchiveReadError:
                        # Nur bei `.tar.zst` und nur, wenn auch die
                        # Auflistung scheitert (sonst ist es ein echtes
                        # Archiv mit einem anderen Fehler).
                        envelope = None if ambiguous else zst_envelope()
                        if envelope is None:
                            raise
                        _, _, status = bsdtar_list(bsdtar, path, env)
                        if status == 0:
                            raise
                        kind = envelope
                        continue
                    # Ein Ordner-Eintrag schreibt nichts und endet mit
                    # Status 0 — genau wie eine leere Datei. Nur in diesem
                    # Sonderfall wird der Typ über die Auflistung erfragt;
                    # sonst entstand still eine leere Datei mit Exit 0,
                    # während Zip und Tar den Ordner schon benannten.
                    # Außerhalb des `try`: DirectoryMemberError ist ein
                    # ArchiveReadError und gehört nicht in den Hüllenzweig.
                    if not data and bsdtar_member_is_directory(
                            bsdtar, path, env, member):
                        raise DirectoryMemberError(member)
                finally:
                    if temp_path is not None:
                        try:
                            os.unlink(temp_path)
                        except OSError:
                            pass
            else:  # Einzelkompression: kind ist die Endung, z. B. ".gz"
                expected = single_member_name(container_name, kind)
                member, used = pick_member(
                    remaining, [expected] if ambiguous else None)
                if member != expected:
                    raise KeyError(member)
                opener = single_opener(kind)
                source = io.BytesIO(data) if data is not None else fs_path
                with opener(source, "rb") as handle:
                    data = budget.read_all(handle, display_path)
            # Endung des gerade gelesenen Eintrags bestimmt, ob die
            # nächste Ebene wieder ein Archiv ist.
            container_name = os.path.basename(member.rstrip("/"))
            kind = classify_archive(member)
            index += used
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
        # APFS/Python lehnt einen neuen Pfad mit Surrogatzeichen ab. Der
        # eindeutige Temp-Ordner trennt kollidierende Anzeigenamen bereits;
        # der materialisierte Blattname darf deshalb U+FFFD verwenden.
        out_path = os.path.join(
            out_dir, json_safe_text(os.path.basename(member.rstrip("/"))))
        with open(out_path, "wb") as handle:
            handle.write(data)
    except OSError as err:
        if out_dir is not None:
            shutil.rmtree(out_dir, ignore_errors=True)
        print("favenio: fehler: Materialisierung fehlgeschlagen: %s" % err,
              file=sys.stderr)
        return 2
    write_result([out_path])
    return 0


DUPLICATE_MAX_ITEMS = 50000
DUPLICATE_MAX_JSON_BYTES = 32 * 1024 * 1024
DUPLICATE_MAX_READ_BYTES = 64 * 1024 ** 3
DUPLICATE_MAX_SECONDS = 300


def duplicate_request(document):
    if (not isinstance(document, dict) or not {"schemaVersion", "items"} <= set(document)
            or set(document) - {"schemaVersion", "items", "limits"}
            or type(document["schemaVersion"]) is not int or document["schemaVersion"] not in (1, 2)
            or not isinstance(document["items"], list) or len(document["items"]) > DUPLICATE_MAX_ITEMS):
        raise ValueError("Dublettenauftrag braucht Schema 1/2 und höchstens 50000 Dateitreffer")
    limits = document.get("limits", {})
    if not isinstance(limits, dict) or set(limits) - {"maxReadBytes", "maxSeconds"}:
        raise ValueError("Unbekannte Dublettengrenzen")
    byte_limit = limits.get("maxReadBytes", DUPLICATE_MAX_READ_BYTES)
    seconds = limits.get("maxSeconds", DUPLICATE_MAX_SECONDS)
    if type(byte_limit) is not int or not 1 <= byte_limit <= DUPLICATE_MAX_READ_BYTES:
        raise ValueError("Lesebudget muss 1 Byte bis 64 GiB betragen")
    if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 0 < seconds <= DUPLICATE_MAX_SECONDS:
        raise ValueError("Zeitgrenze muss positiv und höchstens 300 Sekunden sein")
    def path_value(value):
        if not isinstance(value, str) or "\0" in value or not os.path.isabs(value):
            raise ValueError("Dubletten brauchen absolute Dateipfade ohne NUL")
        value = os.path.abspath(value)
        if len(os.fsencode(value)) > 16384:
            raise ValueError("Dateipfad ist zu lang")
        return value

    def generation(value):
        fields = {"device", "inode", "size", "modifiedNS", "changedNS"}
        if not isinstance(value, dict) or set(value) != fields:
            raise ValueError("Ungültige Dateigeneration")
        for key, text in value.items():
            if not isinstance(text, str) or not re.fullmatch(r"-?[0-9]{1,30}" if key.endswith("NS") else r"[0-9]{1,20}", text):
                raise ValueError("Ungültiger Generationswert")
        return value

    items, identifiers, paths = [], set(), set()
    for item in document["items"]:
        allowed = {"id", "filesystemPath"}
        if document["schemaVersion"] == 2:
            allowed |= {"expectedGeneration", "sourceGuard", "unavailable"}
        if not isinstance(item, dict) or not {"id", "filesystemPath"} <= set(item) or set(item) - allowed:
            raise ValueError("Ungültige Dublettenobjekte; Archividentitäten werden ausschließlich vom gemeinsamen Materialisierer aufgelöst")
        identifier = item["id"]
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identifier) or identifier in identifiers:
            raise ValueError("Ungültige/doppelte Objekt-ID")
        path = path_value(item["filesystemPath"])
        record = dict(id=identifier, filesystemPath=path)
        if "unavailable" in item:
            value = item["unavailable"]
            if (set(item) != {"id", "filesystemPath", "unavailable"} or not isinstance(value, dict)
                    or set(value) != {"reason", "message"} or value["reason"] not in ("archiveError", "archiveLimit")
                    or not isinstance(value["message"], str) or not value["message"] or len(value["message"]) > 1024):
                raise ValueError("Ungültiger Materialisierungsfehler")
            record["unavailable"] = value
        else:
            raw = os.fsencode(path)
            if raw in paths:
                raise ValueError("Dateipfad ist doppelt enthalten")
            paths.add(raw)
            if "expectedGeneration" in item:
                record["expectedGeneration"] = generation(item["expectedGeneration"])
            if "sourceGuard" in item:
                value = item["sourceGuard"]
                if not isinstance(value, dict) or set(value) != {"filesystemPath", "generation"} or "expectedGeneration" not in item:
                    raise ValueError("Quellwache braucht Pfad, Generation und erwartete Inhaltsgeneration")
                record["sourceGuard"] = dict(filesystemPath=path_value(value["filesystemPath"]), generation=generation(value["generation"]))
        identifiers.add(identifier)
        items.append(record)
    return items, byte_limit, float(seconds)


class DuplicateFileIssue(Exception):
    def __init__(self, identifier, reason, detail=None):
        self.identifier, self.reason, self.detail = identifier, reason, detail


class DuplicateLimit(Exception):
    def __init__(self, reason):
        self.reason = reason


class DuplicateCheck:
    MESSAGES = {"changed": "Quelle während der Prüfung verändert", "unreadable": "Datei nicht lesbar",
                "notRegular": "Keine reguläre Datei", "localContentNotLocal": "Inhalt nicht lokal verfügbar",
                "localContentUnknown": "Lokaler Zustand oder Provider nicht belegt",
                "byteLimit": "Lesebudget erreicht", "timeLimit": "Zeitgrenze erreicht",
                "archiveError": "Archivmitglied nicht prüfbar", "archiveLimit": "Archivbudget erreicht"}

    def __init__(self, document, local_only=False, event=None):
        self.items, self.byte_limit, self.seconds = duplicate_request(document)
        self.schema_version = document["schemaVersion"]
        self.local_only, self.event = local_only, event
        self.started = time.monotonic()
        self.last_event = -math.inf
        self.read_bytes = self.hashed_files = 0
        self.records, self.issues = {}, {}
        self.phase, self.done, self.total, self.current = "facts", 0, len(self.items), None

    def emit(self, force=False):
        now = time.monotonic()
        if self.event and (force or now - self.last_event >= .1):
            value = dict(type="duplicateProgress", schemaVersion=self.schema_version, phase=self.phase,
                         done=self.done, total=self.total, readBytes=self.read_bytes)
            if self.current is not None:
                value["currentID"] = self.current
            self.event(value)
            self.last_event = now

    def stage(self, phase, total):
        self.phase, self.done, self.total, self.current = phase, 0, total, None
        self.emit(True)

    def tick(self):
        if time.monotonic() - self.started > self.seconds:
            raise DuplicateLimit("timeLimit")

    def issue(self, identifier, reason, detail=None):
        value = dict(reason=reason, message=self.MESSAGES[reason])
        if identifier is not None:
            value["id"] = identifier
        if detail:
            detail = str(detail)
            value["message"] += ": " + (detail if len(detail) <= 160 else "…" + detail[-159:])
        self.issues.setdefault(identifier or "", value)

    def available(self, identifier, path):
        self.tick()
        if self.local_only:
            reason = local_content_reason(path)
            if reason:
                raise DuplicateFileIssue(identifier, reason)

    def guard_source(self, record):
        guard = record.get("sourceGuard")
        if guard is not None:
            self.available(record["id"], guard["filesystemPath"])
            if source_generation(guard["filesystemPath"]) != guard["generation"]:
                raise DuplicateFileIssue(record["id"], "changed")

    def ensure(self, record, handle=None):
        self.guard_source(record)
        identifier, path = record["id"], record["filesystemPath"]
        self.available(identifier, path)
        if (source_generation(path) != record["generation"]
                or (handle is not None and source_generation(status=os.fstat(handle.fileno())) != record["generation"])):
            raise DuplicateFileIssue(identifier, "changed")

    def read(self, handle, record):
        self.tick()
        try:
            chunk = handle.read(min(65536, max(1, self.byte_limit - self.read_bytes + 1)))
        except OSError as error:
            reason = "localContentNotLocal" if self.local_only and error.errno in (errno.EDEADLK, errno.EAGAIN) else "unreadable"
            raise DuplicateFileIssue(record["id"], reason, error.strerror) from error
        self.read_bytes += len(chunk)
        if self.read_bytes > self.byte_limit:
            raise DuplicateLimit("byteLimit")
        self.emit()
        return chunk

    @contextlib.contextmanager
    def opened(self, record):
        self.ensure(record)
        try:
            with open_regular_file(record["filesystemPath"]) as handle:
                self.ensure(record, handle)
                yield handle
                self.ensure(record, handle)
        except DuplicateFileIssue:
            raise
        except ArchiveReadError as error:
            raise DuplicateFileIssue(record["id"], "notRegular") from error
        except OSError as error:
            reason = "localContentNotLocal" if self.local_only and error.errno in (errno.EDEADLK, errno.EAGAIN) else "unreadable"
            raise DuplicateFileIssue(record["id"], reason, error.strerror) from error

    def digest(self, record):
        digest = hashlib.sha256()
        count = 0
        with self.opened(record) as handle:
            while True:
                chunk = self.read(handle, record)
                if not chunk:
                    break
                digest.update(chunk)
                count += len(chunk)
        if count != record["size"]:
            raise DuplicateFileIssue(record["id"], "changed")
        self.hashed_files += 1
        return digest.hexdigest()

    def equal(self, first, second):
        with self.opened(first) as left, self.opened(second) as right:
            while True:
                a, b = self.read(left, first), self.read(right, second)
                if a != b:
                    return False
                if not a:
                    return True

    def run(self):
        groups, state = [], "completed"
        try:
            self.stage("facts", len(self.items))
            by_size = collections.defaultdict(list)
            for item in self.items:
                self.current = item["id"]
                try:
                    if "unavailable" in item:
                        value = item["unavailable"]
                        raise DuplicateFileIssue(item["id"], value["reason"], value["message"])
                    self.guard_source(item)
                    self.available(item["id"], item["filesystemPath"])
                    status = os.stat(item["filesystemPath"])
                    if not stat.S_ISREG(status.st_mode) or status.st_size < 0:
                        raise DuplicateFileIssue(item["id"], "notRegular")
                    actual_generation = source_generation(status=status)
                    if item.get("expectedGeneration", actual_generation) != actual_generation:
                        raise DuplicateFileIssue(item["id"], "changed")
                    symbolic = stat.S_ISLNK(os.lstat(item["filesystemPath"]).st_mode)
                    record = dict(item, size=status.st_size, generation=source_generation(status=status),
                                  linkKind="symbolic" if symbolic else "hardlink" if status.st_nlink > 1 else "regular",
                                  linkCount=status.st_nlink)
                    self.records[item["id"]] = record
                    by_size[record["size"]].append(record)
                except DuplicateFileIssue as error:
                    self.issue(error.identifier, error.reason, error.detail)
                except OSError as error:
                    self.issue(item["id"], "unreadable", error.strerror)
                self.done += 1
                self.emit()
            candidates = [record for values in by_size.values() if len(values) > 1 for record in values]
            self.stage("hash", len(candidates))
            by_hash = collections.defaultdict(list)
            for record in candidates:
                self.current = record["id"]
                try:
                    record["digest"] = self.digest(record)
                    by_hash[(record["size"], record["digest"])].append(record)
                except DuplicateFileIssue as error:
                    self.issue(error.identifier, error.reason, error.detail)
                self.done += 1
                self.emit()
            buckets = [values for values in by_hash.values() if len(values) > 1]
            self.stage("confirm", sum(map(len, buckets)))
            for bucket in buckets:
                partitions = []
                for record in bucket:
                    self.current = record["id"]
                    matched = False
                    if record["id"] not in self.issues:
                        for partition in partitions:
                            while True:
                                representative = next((value for value in partition if value["id"] not in self.issues), None)
                                if representative is None:
                                    break
                                try:
                                    matched = self.equal(representative, record)
                                    break
                                except DuplicateFileIssue as error:
                                    self.issue(error.identifier, error.reason, error.detail)
                                    if error.identifier == record["id"]:
                                        break
                            if matched:
                                partition.append(record)
                                break
                            if record["id"] in self.issues:
                                break
                        if not matched and record["id"] not in self.issues:
                            partitions.append([record])
                    self.done += 1
                    self.emit()
                groups.extend(partition for partition in partitions if len(partition) > 1)
            self.stage("validate", len(self.records))
            for record in self.records.values():
                self.current = record["id"]
                if record["id"] not in self.issues:
                    try:
                        self.ensure(record)
                    except DuplicateFileIssue as error:
                        self.issue(error.identifier, error.reason, error.detail)
                self.done += 1
                self.emit()
        except DuplicateLimit as error:
            self.issue(None, error.reason)
            groups, state = [], "limited"
        except (SystemExit, KeyboardInterrupt):
            groups, state = [], "cancelled"
        accepted, files = [], {}
        for partition in groups:
            members = [record for record in partition if record["id"] not in self.issues]
            if len(members) < 2:
                continue
            physical = {(record["generation"]["device"], record["generation"]["inode"]) for record in members}
            accepted.append(dict(id=str(len(accepted) + 1), memberIDs=[record["id"] for record in members],
                                 sha256=members[0]["digest"], size=members[0]["size"],
                                 physicalFiles=len(physical), byteVerified=True))
            for record in members:
                files[record["id"]] = dict(sourceGeneration=record["generation"], size=record["size"],
                                           linkKind=record["linkKind"], linkCount=record["linkCount"])
                if "sourceGuard" in record:
                    files[record["id"]]["guardGeneration"] = record["sourceGuard"]["generation"]
        if self.issues and state == "completed":
            state = "partial"
        return dict(type="duplicateResult", schemaVersion=self.schema_version, state=state,
                    complete=state == "completed", checkedAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    scopeCount=len(self.items), hashedFiles=self.hashed_files, readBytes=self.read_bytes,
                    groups=accepted, files=files, issueCount=len(self.issues), issues=list(self.issues.values())[:32])


def check_duplicate_file(path, local_only=False):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Doppeltes JSON-Feld: " + key)
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError("Ungültige JSON-Zahl: " + value)

    if path == "-":
        data = sys.stdin.buffer.read(DUPLICATE_MAX_JSON_BYTES + 1)
    else:
        with open_regular_file(path) as handle:
            data = handle.read(DUPLICATE_MAX_JSON_BYTES + 1)
    if len(data) > DUPLICATE_MAX_JSON_BYTES:
        raise ValueError("Dublettenauftrag überschreitet 32 MiB")
    document = json.loads(data.decode("utf-8"), object_pairs_hook=unique, parse_constant=invalid_constant)
    check = DuplicateCheck(document, local_only, lambda value: write_output(json.dumps(value), flush=True))
    handlers = install_termination_handlers()
    try:
        result = check.run()
        write_output(json.dumps(result), flush=True)
        return (0 if result["groups"] else 1) if result["complete"] else 2
    except (OutputClosed, BrokenPipeError):
        discard_closed_output()
        return 0
    finally:
        restore_termination_handlers(handlers)


def main(argv=None):
    use_locale_independent_streams()
    parser = FavenioArgumentParser(
        prog="favenio",
        description="Favenio — facile invenio. Dateisuche ohne Index, "
                    "auch in Archiven (zip/jar/docx/…, tar/tar.gz/…, "
                    "einzelne gz/bz2/xz; mit bsdtar/zstd auch 7z, iso "
                    "und zst).",
        epilog="Exit-Codes: 0 = Treffer gefunden, 1 = keine Treffer, "
               "2 = Fehler. Ausgabeformat für Skripte/Agenten: --json.",
    )
    parser.add_argument("pattern", nargs="?",
                        help="Suchmuster: „enthält“-Text, Glob (* ? [) "
                             "oder mit --regex ein regulärer Ausdruck")
    parser.add_argument("paths", nargs="*", default=[],
                        help="Startpfade (Default: aktueller Ordner)")
    criteria_input = parser.add_mutually_exclusive_group()
    criteria_input.add_argument("--criteria-json", metavar="JSON",
                                help="zusätzlicher Kriterienbaum (Schema 1/2/3) "
                                     "für Textbedingungen und bekannte Fakten")
    criteria_input.add_argument("--criteria-file", metavar="DATEI",
                                help="Kriterienbaum aus UTF-8-JSON lesen; "
                                     "- liest stdin, maximal 64 KiB")
    parser.add_argument("--validate-criteria", action="store_true",
                        help="nur den angegebenen Kriterienbaum prüfen; "
                             "kein Suchlauf")
    parser.add_argument("--date-reference-time", metavar="ISO",
                        help="einmaliger ausdrücklicher Laufzeitpunkt mit Z/Offset für relative Kalenderbereiche")
    parser.add_argument("--date-ranges-json", metavar="JSON",
                        help="versionierte modified/created-Kalenderbereiche (Schema 1)")
    parser.add_argument("--date-resolution-json", metavar="JSON",
                        help="bereits aufgelöste, vollständig gebundene Kalendergrenzen für Fortsetzung/Filterbatches")
    parser.add_argument("--resolve-date-range", metavar="JSON",
                        help="nur einen Kalenderbereich auflösen und konkrete inklusive ISO-/Epochgrenzen ausgeben")
    parser.add_argument("--duplicates-file", metavar="JSON",
                        help="ausdrückliche Dublettenprüfung normaler Dateien aus versioniertem JSON; - liest stdin")
    parser.add_argument("--filter-results", metavar="JSONL",
                        help="nur bekannte Trefferwerte einer JSONL-Liste filtern; - liest stdin, keine Quellenöffnung")
    parser.add_argument("--results-root", metavar="ORDNER",
                        help="lexikalische Wurzel für relative Dateipfade beim Ansichtsfilter")
    parser.add_argument("--validate-result-filter", action="store_true",
                        help="Kriterien ausschließlich für bekannte Trefferwerte prüfen")
    parser.add_argument("--term", action="append", metavar="TEXT",
                        default=[],
                        help="weiterer Suchbegriff, der ZUSÄTZLICH zutreffen "
                             "muss (wiederholbar; gleiche Regeln wie PATTERN, "
                             "gleiches Ziel: Name, --content oder --metadata; "
                             "UND über das ganze Objekt, nicht dieselbe Zeile)")
    parser.add_argument("-c", "--content", action="store_true",
                        help="im Dateiinhalt suchen statt in Dateinamen")
    parser.add_argument("--search-report", action="store_true",
                        help="mit --json begrenzte strukturierte Suchberichte ausgeben")
    parser.add_argument("--document-text", action="store_true",
                        help="logischen PDF-/DOCX-/ODT-/EPUB-/XLSX-/PPTX-Text mit Dokumentbelegen lesen (optionaler PDFKit-Helfer)")
    parser.add_argument("--pdf-ocr", action="store_true",
                        help="textlose PDF-Seiten im Dokumenttext begrenzt per Vision erkennen (macOS 13+)")
    parser.add_argument("--ocr", action="store_true",
                        help="im Dokumenttextmodus zusätzlich lokale Bild-OCR verwenden (Deutsch/Englisch, macOS 13+)")
    parser.add_argument("--content-preview", action="store_true",
                        help="begrenzte Originalausschnitte und Hervorhebungen im JSONL-Treffer erfassen; braucht --json")
    parser.add_argument("-m", "--metadata", action="store_true",
                        help="in den Metadaten-Textfeldern suchen (Stich"
                             "wörter, Titel, Beschreibung …) statt in "
                             "Dateinamen; braucht exiftool")
    parser.add_argument("--finder-metadata", action="store_true",
                        help="Finder-Tags und -Kommentar für passende lokale Objekte erfassen; braucht --json")
    parser.add_argument("--metadata-field", action="append", metavar="TAG",
                        default=[], type=metadata_tag,
                        help="nur dieses Metadatenfeld durchsuchen (wieder"
                             "holbar; schaltet --metadata ein)")
    parser.add_argument("--list-metadata-fields", action="store_true",
                        help="die durchsuchten Metadatenfelder ausgeben, "
                             "eines je Zeile, und beenden")
    parser.add_argument("--min-size", type=byte_size, metavar="BYTES",
                        help="Dateigröße ab dieser Bytezahl (inklusive; "
                             "optional B/KiB/MiB/GiB/TiB)")
    parser.add_argument("--max-size", type=byte_size, metavar="BYTES",
                        help="Dateigröße bis zu dieser Bytezahl (inklusive); "
                             "unbekannte Größe und Ordner erfüllen den Filter nicht")
    parser.add_argument("--modified-from", type=file_timestamp, metavar="ISO",
                        help="Änderungszeit ab diesem ISO-Zeitpunkt mit Zone (inklusive)")
    parser.add_argument("--modified-to", type=file_timestamp_end, metavar="ISO",
                        help="Änderungszeit bis zu diesem ISO-Zeitpunkt mit Zone "
                             "(inklusive der ganzen genannten Sekunde bzw. Minute)")
    parser.add_argument("--created-from", type=file_timestamp, metavar="ISO",
                        help="Erstellungszeit ab diesem ISO-Zeitpunkt mit Zone (inklusive)")
    parser.add_argument("--created-to", type=file_timestamp_end, metavar="ISO",
                        help="Erstellungszeit bis zu diesem ISO-Zeitpunkt mit Zone "
                             "(inklusive der ganzen genannten Sekunde bzw. Minute); "
                             "ohne bekannten Zeitpunkt kein Treffer")
    parser.add_argument("--min-width", type=positive_int, metavar="PX",
                        help="nur Bilder ab dieser Breite (Pixel)")
    parser.add_argument("--max-width", type=positive_int, metavar="PX",
                        help="nur Bilder bis zu dieser Breite (Pixel)")
    parser.add_argument("--min-height", type=positive_int, metavar="PX",
                        help="nur Bilder ab dieser Höhe (Pixel)")
    parser.add_argument("--max-height", type=positive_int, metavar="PX",
                        help="nur Bilder bis zu dieser Höhe (Pixel); alle "
                             "vier Maßfilter gelten zusätzlich (UND) zum "
                             "Muster, das dann auch fehlen darf")
    parser.add_argument("-r", "--regex", action="store_true",
                        help="Muster als regulären Ausdruck interpretieren")
    parser.add_argument("-s", "--case-sensitive", action="store_true",
                        help="Groß-/Kleinschreibung beachten")
    parser.add_argument("-e", "--exact", action="store_true",
                        help="Muster muss dem GANZEN Namen entsprechen statt "
                             "nur enthalten zu sein (mit --regex: fullmatch; "
                             "mit --content gilt es je Zeile)")
    parser.add_argument("--literal-wildcards", action="store_true",
                        help="Platzhalter im Suchmuster wörtlich suchen; "
                             "ohne Wirkung mit --regex oder auf --exclude")
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
    parser.add_argument("--exclude", action="append", default=[],
                        metavar="GLOB",
                        help="Dateien/Teilbäume vor dem Öffnen ausschließen "
                             "(wiederholbar; Groß-/Kleinschreibung gilt); "
                             "ohne / je Name, mit / relativ zur Such- oder "
                             "Archivwurzel; * darf / überqueren; ein "
                             "./ am Anfang und ein / am Ende zählen nicht, "
                             "ein absolutes Muster ist ein Fehler")
    parser.add_argument("--max-depth", type=positive_int, default=None,
                        metavar="N",
                        help="nur N Ordnerebenen tief suchen (1 = nur direkt "
                             "im Startpfad, wie find -maxdepth); Default: "
                             "unbegrenzt")
    parser.add_argument("--archive-depth", type=parse_archive_depth, default=1,
                        metavar="N",
                        help="wie tief in verschachtelte Archive schauen "
                             "(0 = gar nicht, wie --no-archives; 1 = Archive, "
                             "2 = Archive in Archiven, …; höchstens 100; "
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
    parser.add_argument("--preview-request", metavar="JSON",
                        help="begrenzte weitere Fundstelle eines einzelnen belegten Treffers laden")
    parser.add_argument("--snapshot-position-json", metavar="JSON",
                        help="begrenzten aktuellen Blattinhalt hashen und "
                             "Inhaltsfundstelle als UTF-16-Bereich belegen")
    parser.add_argument("--local-only", action="store_true",
                        help="nur lokal vorhandene Inhalte lesen (macOS 13+); keine APFS-Materialisierung, Namen/Fakten bleiben suchbar")
    parser.add_argument("--encoding", choices=("auto",) + tuple(TEXT_ENCODINGS),
                        default="utf-8", help="Inhaltskodierung (Standard: utf-8); auto erkennt nur UTF-8-/UTF-16-BOM")
    parser.add_argument("--version", action="version",
                        version="favenio " + __version__)
    # Optionen mit Wert dürfen zwischen Muster und Startpfaden stehen. Das
    # klassische parse_args() trennt bei nargs="*" auf älteren Python-
    # Versionen die Positionsargumente an einer solchen Option auf.
    #
    # Python 3.9 behandelt `--` in parse_intermixed_args() jedoch nicht
    # zuverlässig als Ende der Optionen: Ein folgendes Muster wie `-entwurf`
    # wird erneut als Option gelesen. Deshalb den Trenner selbst abnehmen und
    # alles dahinter ausdrücklich an die Positionsargumente hängen.
    parse_argv = list(sys.argv[1:] if argv is None else argv)
    if "--" in parse_argv:
        separator = parse_argv.index("--")
        positional_tail = parse_argv[separator + 1:]
        args = parser.parse_intermixed_args(parse_argv[:separator])
        positionals = []
        if args.pattern is not None:
            positionals = [args.pattern] + args.paths
        positionals.extend(positional_tail)
        args.pattern = positionals[0] if positionals else None
        args.paths = positionals[1:]
    else:
        args = parser.parse_intermixed_args(parse_argv)

    try:
        with local_content_policy(args.local_only):
            return run_parsed(args, parser)
    except LocalContentPolicyError as error:
        parser.error(str(error))
    except Exception as error:
        print("favenio: fehler: unerwarteter Fehler, Suche unvollständig: %s: %s"
              % (type(error).__name__, error), file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2


def run_parsed(args, parser):
    if args.duplicates_file is not None:
        allowed = {"duplicates_file", "local_only", "json"}
        defaults = vars(parser.parse_args([]))
        if any(value != defaults[key] for key, value in vars(args).items() if key not in allowed):
            parser.error("Dublettenprüfung kann nicht mit Suche oder anderen Aktionen kombiniert werden")
        try:
            return check_duplicate_file(args.duplicates_file, args.local_only)
        except (ValueError, UnicodeError, OSError, ArchiveReadError, RecursionError) as error:
            parser.error("Dublettenauftrag: %s" % error)

    try:
        date_resolver = DateRangeResolver(args.date_reference_time, args.date_resolution_json)
        if args.resolve_date_range is not None:
            allowed = {"resolve_date_range", "date_reference_time"}
            defaults = vars(parser.parse_args([]))
            if any(value != defaults[key] for key, value in vars(args).items() if key not in allowed):
                parser.error("Kalenderauflösung kann nicht mit Suche oder anderen Aktionen kombiniert werden")
            date_resolver.resolve(date_json(args.resolve_date_range), "preview")
            write_result([json.dumps({"type": "dateResolution", "value": date_resolver.snapshot()}, ensure_ascii=True)])
            return 0
        if args.date_ranges_json is not None:
            document = date_json(args.date_ranges_json)
            if (not isinstance(document, dict) or set(document) != {"schemaVersion", "ranges"}
                    or type(document["schemaVersion"]) is not int or document["schemaVersion"] != 1
                    or not isinstance(document["ranges"], dict) or not document["ranges"]
                    or not set(document["ranges"]).issubset({"modified", "created"})):
                raise ValueError("Datumsfilter brauchen schemaVersion 1 und modified/created unter ranges")
            for field, spec in document["ranges"].items():
                if not isinstance(spec, dict) or spec.get("kind") not in ("relative", "fixed"):
                    raise ValueError("Datumsfilter speichern nur relative oder feste Bereiche")
                if getattr(args, field + "_from") is not None or getattr(args, field + "_to") is not None:
                    raise ValueError("Kalenderbereich und rohe ISO-Grenzen desselben Felds schließen sich aus")
                entry = date_resolver.resolve(spec, field)
                setattr(args, field + "_from", entry["lowerEpoch"])
                setattr(args, field + "_to", entry["upperEpoch"])
    except (ValueError, argparse.ArgumentTypeError, OverflowError, OSError, RecursionError) as err:
        parser.error("Datumsbereich: %s" % err)

    if args.filter_results is not None or args.validate_result_filter:
        allowed = {"filter_results", "results_root", "validate_result_filter", "criteria_json", "criteria_file", "json", "date_reference_time", "date_resolution_json"}
        defaults = vars(parser.parse_args([]))
        if any(value != defaults[key] for key, value in vars(args).items() if key not in allowed):
            parser.error("Ansichtsfilter kann nicht mit Suche oder anderen Ausgabeaktionen kombiniert werden")
        if args.validate_result_filter and args.filter_results is not None:
            parser.error("Filterprüfung kann nicht zugleich eine Trefferliste lesen")
        if args.validate_result_filter and args.results_root is not None:
            parser.error("--results-root braucht --filter-results")
        if args.criteria_json is None and args.criteria_file is None:
            parser.error("Ansichtsfilter braucht --criteria-json oder --criteria-file")
        if args.filter_results == "-" and args.criteria_file == "-":
            parser.error("Kriterien und Trefferliste können nicht zugleich stdin lesen")
        try:
            query = read_criteria_query(args.criteria_json, args.criteria_file, date_resolver)
            validate_result_filter(query)
            date_resolver.finish()
            if args.validate_result_filter:
                result = {"type": "validation", "schemaVersion": 1, "valid": True}
                if date_resolver.entries:
                    result["dateResolution"] = date_resolver.snapshot()
                write_result([json.dumps(result)])
                return 0
            if date_resolver.entries:
                write_output(json.dumps({"type": "dateResolution", "value": date_resolver.snapshot()}), flush=True)
            return filter_result_file(args.filter_results, query, args.results_root)
        except (ValueError, OSError, UnicodeError, RecursionError, ArchiveReadError) as err:
            parser.error("Ansichtsfilter: %s" % err)
    if args.results_root is not None:
        parser.error("--results-root braucht --filter-results")

    if args.preview_request is not None:
        if args.pattern or args.paths or args.criteria_json or args.criteria_file or args.extract or args.extract_json or args.snapshot_position_json or args.list_metadata_fields or args.finder_metadata or args.date_ranges_json is not None or args.date_reference_time is not None or args.date_resolution_json is not None:
            parser.error("Nachladen kann nicht mit Suche oder anderen Ausgabeaktionen kombiniert werden")
        try:
            if len(args.preview_request.encode("utf-8")) > PREVIEW_REQUEST_BYTES:
                raise ValueError("Nachladeauftrag ist größer als 128 KiB")
            result = load_content_preview(json.loads(args.preview_request), local_only=args.local_only)
        except (ValueError, OSError, UnicodeError, re.error, RecursionError) as error:
            parser.error("Nachladen: %s" % error)
        write_result([json.dumps(result, ensure_ascii=True)])
        return 0

    if args.content_preview and not args.json:
        parser.error("--content-preview braucht --json")
    if args.finder_metadata and not args.json:
        parser.error("--finder-metadata braucht --json")
    if args.finder_metadata and (args.extract or args.extract_json or args.snapshot_position_json
                                 or args.list_metadata_fields or args.validate_criteria):
        parser.error("Finder-Erfassung kann nicht mit Ausgabeaktionen kombiniert werden")

    if args.search_report and not args.json:
        parser.error("--search-report braucht --json")
    criteria_query = None
    has_criteria = args.criteria_json is not None or args.criteria_file is not None
    if args.validate_criteria and not has_criteria:
        parser.error("--validate-criteria braucht --criteria-json oder --criteria-file")
    if has_criteria:
        if (args.snapshot_position_json or args.extract or args.extract_json
                or args.list_metadata_fields):
            parser.error("Kriterien können nicht mit Ausgabeaktionen kombiniert werden")
        try:
            criteria_query = read_criteria_query(args.criteria_json, args.criteria_file, date_resolver)
        except (ValueError, OSError, UnicodeError, RecursionError, ArchiveReadError) as err:
            parser.error("ungültige Kriterien: %s" % err)
    if args.validate_criteria:
        try:
            date_resolver.finish()
        except ValueError as err:
            parser.error("Datumsbereich: %s" % err)
        result = {"type": "validation", "schemaVersion": 1, "valid": True}
        if date_resolver.entries:
            result["dateResolution"] = date_resolver.snapshot()
        write_result([json.dumps(result)])
        return 0
    try:
        date_resolver.finish()
    except ValueError as err:
        parser.error("Datumsbereich: %s" % err)

    if args.snapshot_position_json:
        if args.extract or args.extract_json or args.list_metadata_fields:
            parser.error("Positionsprüfung kann nicht mit anderen Ausgabeaktionen kombiniert werden")
        try:
            record = json.loads(args.snapshot_position_json)
            if args.encoding != "utf-8" and isinstance(record, dict):
                if "encoding" in record and record["encoding"] != args.encoding:
                    raise ValueError("widersprüchliche Textkodierung im Positionsauftrag")
                record["encoding"] = args.encoding
            position = snapshot_position(record, local_only=args.local_only)
        except (ValueError, OSError, ArchiveReadError, re.error, OverflowError) as err:
            parser.error("Positionsprüfung fehlgeschlagen: %s" % err)
        write_result([json.dumps(position, ensure_ascii=True, sort_keys=True)])
        return 0

    # Extraktions-Modus: kein Suchlauf, nur einen Treffer auspacken.
    extract_options = {
        "max_archive_member_bytes": args.max_archive_member_bytes,
        "max_archive_total_bytes": args.max_archive_total_bytes,
        "max_archive_ratio": args.max_archive_ratio,
        "materialization_root": args.extract_root,
        "local_only": args.local_only,
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
            archive_member_bytes = record.get("archiveMemberBytes")
            if not isinstance(filesystem_path, str) \
                    or not isinstance(archive_members, list) \
                    or not all(isinstance(item, str)
                               for item in archive_members) \
                    or (archive_member_bytes is not None
                        and (not isinstance(archive_member_bytes, list)
                             or not all(isinstance(item, str)
                                        for item in archive_member_bytes))):
                raise ValueError("ungültige Feldtypen")
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as err:
            print("favenio: fehler: ungültiger strukturierter Treffer: %s"
                  % err, file=sys.stderr)
            return 2
        return extract_result(filesystem_path=filesystem_path,
                              archive_members=archive_members,
                              archive_member_bytes=archive_member_bytes,
                              **extract_options)

    if args.list_metadata_fields:
        write_result(METADATA_TEXT_FIELDS)
        return 0

    dimension_limits = {
        "min_width": args.min_width, "max_width": args.max_width,
        "min_height": args.min_height, "max_height": args.max_height,
    }
    wants_dimensions = any(value is not None
                           for value in dimension_limits.values())
    fact_limits = {
        "min_size": args.min_size, "max_size": args.max_size,
        "modified_from": args.modified_from, "modified_to": args.modified_to,
        "created_from": args.created_from, "created_to": args.created_to,
    }
    wants_filters = wants_dimensions or any(value is not None
                                            for value in fact_limits.values())
    for lower, upper in (("min_size", "max_size"),
                         ("modified_from", "modified_to"),
                         ("created_from", "created_to")):
        if fact_limits[lower] is not None and fact_limits[upper] is not None \
                and fact_limits[lower] > fact_limits[upper]:
            parser.error("--%s ist größer als --%s"
                         % (lower.replace("_", "-"), upper.replace("_", "-")))
    if args.min_width is not None and args.max_width is not None \
            and args.min_width > args.max_width:
        parser.error("--min-width ist größer als --max-width")
    if args.min_height is not None and args.max_height is not None \
            and args.min_height > args.max_height:
        parser.error("--min-height ist größer als --max-height")
    # Dieselbe Beförderung gilt mit --term: `--content --term x ~/Docs`
    # nennt seinen Begriff über die Option, das Positionsargument ist der
    # Startpfad.
    if (wants_filters or args.term or has_criteria) and args.pattern \
            and search_path_exists(args.pattern, args.local_only) \
            and all(search_path_exists(path, args.local_only) for path in args.paths):
        # `favenio.py --min-width 1000 ~/Bilder`: Das erste Positions-
        # argument ist ein Pfad, kein Muster. Das gilt auch für MEHRERE
        # Ordner — vorher griff die Regel nur bei genau einem Argument,
        # und `--min-width 100 dirA dirB` las dirA still als Namensmuster:
        # Beide Ordner einzeln lieferten Treffer, zusammen kam Exit 1 und
        # keine Zeile. Befördert wird nur, wenn ALLE Positionsargumente
        # als Pfad existieren; wer nach einem Namen sucht, der zufällig
        # auch ein Pfad ist, hat dann weiterhin ein Argument, das keiner
        # ist.
        args.paths = [args.pattern] + list(args.paths)
        args.pattern = None
    if not args.pattern and not wants_filters and not args.term and not has_criteria:
        # parser.error() gibt die Usage aus und beendet mit Exit-Code 2.
        parser.error("PATTERN fehlt (oder --extract verwenden)")

    metadata_mode = args.metadata or bool(args.metadata_field)
    if sum((args.content, metadata_mode, args.document_text)) > 1:
        parser.error("--content, --document-text und --metadata schließen sich aus")
    # Ausschlüsse werden immer RELATIV zur Such- oder Archivwurzel
    # verglichen. Ein absolutes Muster träfe deshalb nie — lieber sofort
    # sagen als still nichts ausschließen. Ein Muster ohne Rest (`/`,
    # `./`, "") ebenso.
    for pattern in args.exclude:
        if pattern.startswith("/"):
            parser.error("--exclude %r: Muster gelten relativ zur Such- "
                         "oder Archivwurzel, nicht absolut" % pattern)
        if not Exclusions.normalize_pattern(pattern)[0]:
            parser.error("--exclude %r: leeres Muster" % pattern)
    # Mehrwortsuche: PATTERN und jedes --term sind Begriffe, die ALLE
    # zutreffen müssen. Ohne PATTERN wird der erste --term zum Muster; ein
    # leerer Begriff ist ein Fehler (er träfe alles und sagte nichts), ein
    # doppelter zählt einmal — die Reihenfolge bleibt.
    if any(term == "" for term in args.term):
        parser.error("--term darf nicht leer sein")
    terms = []
    for term in ([args.pattern] if args.pattern else []) + args.term:
        if term not in terms:
            terms.append(term)
    if terms and not args.pattern:
        args.pattern = terms[0]
    if (args.exact and len(terms) > 1 and not args.content and not args.document_text
            and not metadata_mode and not args.regex):
        # Nur widersprüchliche WÖRTLICHE Namen schließen sich sicher aus.
        # Globs/Regexe können denselben ganzen Namen treffen, und ohne
        # Groß-/Kleinschreibung sind auch beide.txt und BEIDE.TXT identisch.
        literal_names = {unicodedata.normalize("NFC", term) if args.case_sensitive else unicodedata.normalize("NFC", term).lower()
                         for term in terms if args.literal_wildcards
                         or not any(char in term for char in "*?[")}
        if len(literal_names) > 1:
            parser.error("--exact mit mehreren Begriffen enthält "
                         "widersprüchliche wörtliche Namen; --exact "
                         "weglassen oder --content nutzen")
    if not args.pattern and (args.content or metadata_mode or (args.document_text and not has_criteria)):
        # Ohne Muster läuft die Suche ganz ohne Textkriterium (nur die
        # Maß-/Faktengrenzen zählen). --content und --metadata sagen, WOGEGEN das
        # Muster läuft, und sind dann eine widersprüchliche Angabe. Früher
        # sprang hier ein künstliches "*" ein: Mit --regex war das ein
        # ungültiger Ausdruck (Exit 2), mit --metadata ein stiller Filter
        # auf Dateien, die überhaupt Metadaten tragen.
        parser.error("--content, --document-text und --metadata brauchen ein PATTERN (Dokumenttext auch mit Kriterien)")
    exiftool_path = find_exiftool()
    if (metadata_mode or (criteria_query is not None and criteria_query.metadata_fields)) and exiftool_path is None:
        request = "--metadata braucht" if metadata_mode else "Metadatenkriterien brauchen"
        print("favenio: fehler: %s exiftool, das nicht "
              "gefunden wurde (z. B. `brew install exiftool`). Die "
              "Maßfilter kommen ohne aus." % request, file=sys.stderr)
        return 2

    # argparse setzt den Default für nargs="*" nur, wenn GAR NICHTS kommt —
    # deshalb hier noch einmal absichern.
    paths = args.paths if args.paths else ["."]

    try:
        # Ohne Muster gibt es kein Textkriterium; Search kommt mit None aus.
        matcher = None
        extra_matchers = []
        if args.pattern:
            matchers = []
            for term in terms:
                built = build_matcher(term, args.regex, args.case_sensitive,
                                      exact=args.exact,
                                      literal_wildcards=args.literal_wildcards,
                                      text_wildcards=args.content or args.document_text or metadata_mode)
                built.term = term      # Klartext für die Belege
                matchers.append(built)
            matcher, extra_matchers = matchers[0], matchers[1:]
    except (re.error, OverflowError) as err:
        print("favenio: fehler: ungültiger regulärer Ausdruck: %s" % err,
              file=sys.stderr)
        return 2

    # Der Vortest greift nur bei der Inhaltssuche; bei der Namenssuche gibt es
    # keine Zeilen zu zählen und damit nichts zu sparen.
    content_probe = None
    if args.content:
        content_probe = build_content_probe(terms, args.regex,
                                            args.case_sensitive,
                                            args.literal_wildcards,
                                            text_wildcards=True, text_encoding=args.encoding)

    archive_depth = 0 if args.no_archives else args.archive_depth
    report = None
    if args.search_report:
        configuration = dict(vars(args))
        configuration["paths"] = paths
        configuration["criteria"] = getattr(criteria_query, "document", None)
        configuration["effectiveArchiveDepth"] = archive_depth
        configuration["fixedLimits"] = {"lineCharacters": MAX_LINE_CHARS,
                                      "archiveListingBytes": MAX_ARCHIVE_LISTING_BYTES,
                                      "tarMembers": MAX_TAR_MEMBERS,
                                      "documentBytes": DOCUMENT_BYTES, "documentPages": DOCUMENT_PAGES,
                                      "documentTextBytes": DOCUMENT_TEXT_BYTES,
                                      "documentPageBytes": DOCUMENT_PAGE_BYTES,
                                      "documentSeconds": DOCUMENT_SECONDS,
                                      "pdfOCRPages": PDF_OCR_PAGES, "pdfOCRRenderedPages": 16, "pdfOCRDPI": 150,
                                      "pdfOCRRenderPixels": 6_000_000, "pdfOCRTotalRenderPixels": 32_000_000, "pdfOCRRenderEdge": 4096, "pdfOCRSeconds": PDF_OCR_SECONDS,
                                      "ocrLanguages": ["de-DE", "en-US"], "ocrPixels": OCR_PIXELS,
                                      "ocrEdge": OCR_EDGE, "ocrBlocks": OCR_BLOCKS, "ocrTextBytes": OCR_TEXT_BYTES,
                                      "ocrMinimumConfidence": 0.5, "ocrMinimumTextHeight": 0.003,
                                      "ocrMaximumBitDepth": 16, "ocrColorModels": ["RGB", "Gray"],
                                      "docxParts": DOCUMENT_PARTS, "docxParagraphs": DOCUMENT_PARAGRAPHS,
                                      "docxParagraphBytes": DOCUMENT_PARAGRAPH_BYTES,
                                      "docxXMLBytes": DOCUMENT_XML_BYTES, "docxTotalXMLBytes": DOCUMENT_TOTAL_XML_BYTES,
                                      "docxMetadataBytes": DOCUMENT_METADATA_BYTES, "docxZIPEntries": DOCUMENT_ZIP_ENTRIES,
                                      "docxCatalogBytes": DOCUMENT_CATALOG_BYTES, "docxXMLDepth": DOCUMENT_XML_DEPTH,
                                      "docxExcluded": ["comments", "deletedChanges", "fieldInstructions", "noteSeparators", "textBoxes"],
                                      "packageParts": DOCUMENT_PARTS, "packageParagraphs": DOCUMENT_PARAGRAPHS,
                                      "packageParagraphBytes": DOCUMENT_PARAGRAPH_BYTES,
                                      "packageXMLBytes": DOCUMENT_XML_BYTES, "packageTotalXMLBytes": DOCUMENT_TOTAL_XML_BYTES,
                                      "packageMetadataBytes": DOCUMENT_METADATA_BYTES, "packageZIPEntries": DOCUMENT_ZIP_ENTRIES,
                                      "packageCatalogBytes": DOCUMENT_CATALOG_BYTES, "packageXMLDepth": DOCUMENT_XML_DEPTH,
                                      "odtExcluded": ["annotations", "trackedChanges", "notes", "indexes", "drawingObjects", "headersFooters"],
                                      "epubExcluded": ["navigation", "nonLinearSpine", "head", "scripts", "styles", "hidden", "embeddedObjects"],
                                      "epubRendition": "firstPackage", "epubWhitespace": "collapseASCIIExceptPre",
                                      "xlsxSheets": DOCUMENT_PARTS, "xlsxCells": XLSX_CELLS,
                                      "xlsxSharedStrings": XLSX_SHARED_STRINGS, "xlsxSharedTextBytes": XLSX_SHARED_TEXT_BYTES,
                                      "xlsxFormulaPolicy": "storedResultsOnly", "xlsxNumberPolicy": "unformattedStoredValues",
                                      "xlsxHidden": "included", "xlsxExcluded": ["formulaText", "comments", "drawings", "charts", "phoneticGuides"],
                                      "xlsxValueKinds": list(XLSXTextReader.VALUE_KINDS),
                                      "pptxSlides": PPTX_SLIDES, "pptxNotes": 0, "pptxObjects": PPTX_OBJECTS,
                                      "pptxTableCells": PPTX_TABLE_CELLS, "pptxTableRows": PPTX_TABLE_ROWS, "pptxHidden": "included",
                                      "pptxOrder": "presentationThenShapeTreeXML",
                                      "pptxExcluded": ["notes", "masters", "layouts", "comments", "fields", "charts", "embeddedObjects", "imageOCR", "alternateContent"]}
        report = SearchReport(configuration, date_resolver.snapshot() if date_resolver.entries else None)
    search = Search(matcher, args.content, archive_depth, args.json,
                    progress=args.progress, only=args.only,
                    include_hidden=args.hidden, max_depth=args.max_depth,
                    exclusions=args.exclude,
                    max_archive_member_bytes=args.max_archive_member_bytes,
                    max_archive_total_bytes=args.max_archive_total_bytes,
                    max_archive_ratio=args.max_archive_ratio,
                    content_probe=content_probe,
                    metadata_mode=metadata_mode,
                    metadata_fields=args.metadata_field or None,
                    exiftool_path=exiftool_path, extra_matchers=extra_matchers,
                    criteria_query=criteria_query, text_encoding=args.encoding,
                    content_preview=args.content_preview, search_report=report, document_mode=args.document_text,
                    include_finder_metadata=args.finder_metadata, local_only=args.local_only, ocr=args.ocr, pdf_ocr=args.pdf_ocr,
                    **dimension_limits, **fact_limits)

    # Erst alle Startpfade prüfen, dann suchen: sonst stünden bei mehreren
    # Pfaden schon Treffer auf stdout, bevor ein späterer Pfad den Fehler
    # auslöst.
    unavailable_paths = {}
    for path in paths:
        if args.local_only:
            try:
                os.stat(path)
            except OSError as error:
                if error.errno != errno.ENOENT:
                    unavailable_paths[path] = report_error_reason(error)
                    continue
        if not search_path_exists(path, args.local_only):
            print("favenio: fehler: Pfad existiert nicht: %s" % path,
                  file=sys.stderr)
            return 2
    previous_handlers = install_termination_handlers()
    report_state = "failed"
    try:
        if report is not None:
            report.emit(force=True)
        for path in paths:
            if path in unavailable_paths:
                reason = unavailable_paths[path]
                search.report_warning("%s: Suchbereich unter lokaler Lesepolitik nicht zugänglich" % path,
                                      reason=reason, path=path)
            else:
                search.search_path(path)
        # Innerhalb des try leeren: Steckt der letzte Treffer noch im
        # Puffer, scheiterte sonst erst das Leeren beim Interpreter-Ende —
        # mit „Exception ignored" auf stderr und Status 120.
        sys.stdout.flush()
        report_state = "finished"
    except (SystemExit, KeyboardInterrupt):
        report_state = "cancelled"
        raise
    except (OutputClosed, BrokenPipeError):
        # Der Leser hat genug (`| head -1`, auch `2>&1 | head -1`). Wie
        # grep: kein Fehler, der Status sagt weiter, ob es Treffer gab.
        # stdout und stderr zeigen ab jetzt ins Leere, damit das Leeren der
        # Restpuffer beim Interpreter-Ende nicht noch einmal scheitert.
        discard_closed_output()
        return 0 if search.found_any else 1
    except Exception as err:            # noqa: BLE001 — siehe Kommentar
        # Ein unerwarteter Fehler MUSS als Fehler enden. Python beendet
        # sich sonst mit Status 1 — genau dem Status, den der Vertrag für
        # „keine Treffer" vergibt. Ein abgebrochener Lauf war damit von
        # einem leeren Ergebnis nicht unterscheidbar: Beide Apps zeigten
        # eine halbe Trefferliste als vollständiges Ergebnis an, ohne
        # jeden Hinweis. Erwartete Lesefehler einzelner Objekte fängt
        # dagegen weiter unten `evaluate()` ab und meldet sie als Warnung.
        #
        # Der Traceback bleibt erhalten und geht nach stderr: Er ist
        # Diagnose, und stdout muss parsebar bleiben.
        print("favenio: fehler: unerwarteter Fehler, Suche unvollständig: "
              "%s: %s" % (type(err).__name__, err), file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        return 2
    finally:
        search.close()
        restore_termination_handlers(previous_handlers)
        if report is not None:
            try:
                report.emit(report_state, force=True)
            except (OutputClosed, BrokenPipeError):
                discard_closed_output()

    return 0 if search.found_any else 1


if __name__ == "__main__":
    sys.exit(main())
