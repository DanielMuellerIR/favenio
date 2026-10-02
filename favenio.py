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
import datetime
import fnmatch
import gzip
import io
import json
import lzma
import math
import os
import re
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
import zipfile
import zlib

__version__ = "0.35.1"
# Datum dieser Version (ISO 8601). Zweite Single-Source neben __version__;
# das Build-Skript gießt beides in eine Swift-Konstante für die Fenstertitel.
__date__ = "2026-10-02"

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


class ArchiveLimitError(ArchiveReadError):
    """Ein Archivmitglied überschreitet eine konfigurierte Sicherheitsgrenze."""


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
                % (label, declared_size, self.maximum_member))
        if declared_size and compressed_size is not None:
            ratio = declared_size / max(1, compressed_size)
            if ratio > self.maximum_ratio:
                raise ArchiveLimitError(
                    "%s: Kompressionsverhältnis %.1f überschreitet Grenze %.1f"
                    % (label, ratio, self.maximum_ratio))

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
                % MAX_TAR_MEMBERS)
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
        raise ArchiveReadError(
            "Eintragsliste größer als %d Bytes — Archiv übersprungen"
            % limit)
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


def iter_line_pieces(chunks, max_line_chars=None, overlap_chars=None):
    """Liest Byte-Häppchen als UTF-8-Text und liefert Zeilen als LinePiece.

    Das ist der Leser der Inhaltssuche, herausgelöst aus match_content()
    (0.32.1, verhaltensneutral — die Tests vergleichen beide Fassungen
    Eingabe für Eingabe). Was er zusagt:

    - Dekodiert wird als UTF-8 mit errors="replace", damit die Suche auch
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
    for text in codecs.iterdecode(chunks, "utf-8", errors="replace"):
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

    def __init__(self, needle, case_sensitive):
        # `needle` ist EIN Suchtext oder eine Liste (Mehrwortsuche, --term):
        # Dann müssen ALLE vorkommen, geprüft in demselben Durchlauf — der
        # Inhalt wird nicht je Begriff neu gelesen.
        needles = [needle] if isinstance(needle, str) else list(needle)
        # Bei egaler Groß-/Kleinschreibung vergleichen wir kleingeschrieben —
        # genau wie der Matcher aus build_matcher() es pro Zeile tut.
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

        Dekodiert wird wie in `match_content` als UTF-8 mit
        errors="replace" — beide sehen also denselben Text."""
        # Der Suchtext kann genau auf einer Häppchengrenze liegen. Deshalb
        # wandert das Ende des bisher Gesehenen (Suchtextlänge minus ein
        # Zeichen) vorne an das nächste Häppchen. Wichtig: Das Fenster wird
        # aus carry UND Häppchen gebildet, nicht nur aus dem Häppchen —
        # sonst reicht es bei sehr kleinen Häppchen nicht über den Suchtext.
        overlap = max(0, max(len(text) for text in self.needles) - 1)
        remaining = list(self.needles)
        carry = ""
        for text in codecs.iterdecode(chunks, "utf-8", errors="replace"):
            if not text:
                continue
            if not self.case_sensitive:
                text = text.lower()
                if self.fold_sigma:
                    text = text.replace(GREEK_FINAL_SIGMA, GREEK_SMALL_SIGMA)
            window = carry + text
            # Gefundene Begriffe fallen aus der Liste; die Liste wird
            # kopiert, denn sie schrumpft während des Durchlaufs.
            for needle in remaining[:]:
                if needle in window:
                    remaining.remove(needle)
            if not remaining:
                return True
            carry = window[-overlap:] if overlap else ""
        return False


def build_content_probe(pattern, use_regex, case_sensitive, literal_wildcards=False,
                        text_wildcards=False):
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
    return ContentProbe(fixed, case_sensitive)


def build_matcher(pattern, use_regex, case_sensitive, exact=False,
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
                "keine reguläre Datei (Pipe, Socket oder Gerät)")
        os.set_blocking(descriptor, True)
    except BaseException:
        os.close(descriptor)
        raise
    return open(descriptor, "rb")


class FileProbe:
    """Eine Datei oder ein Archiv-Eintrag, der teure Fragen EINMAL beantwortet.

    Ein Lauf mit drei Kriterien (Name, Maße, Metadaten) fragt exiftool
    trotzdem nur einmal je Datei und liest den Bildkopf nur einmal. Die
    Antworten bleiben gemerkt, bis der Treffer ausgegeben ist."""

    def __init__(self, search, label, name, open_stream, chunker,
                 filesystem_path, size=None, in_archive=False,
                 modified=None, is_dir=False):
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
        self._content_lines = MISSING

    @property
    def extension(self):
        return os.path.splitext(self.name)[1].lower()

    def facts(self):
        """(Größe, Änderungszeit, Erstellungszeit), einmal für Filter UND Ausgabe."""
        if self._facts is MISSING:
            self._set_facts(*self.search.file_facts(self.filesystem_path))
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

    def metadata(self):
        """Die angeforderten exiftool-Felder als dict — oder None. Archiv-
        Einträge und Dateien ohne Medienendung fragen exiftool gar nicht."""
        if self._metadata is MISSING:
            self._metadata = None
            if not self.in_archive \
                    and self.extension in METADATA_EXTENSIONS:
                stream = self.search.exiftool_stream()
                if stream is not None:
                    self._metadata = stream.read(self.filesystem_path)
        return self._metadata

    def content_lines(self):
        """Je Suchbegriff die Zeilennummer seines ersten Vorkommens — oder
        None, wenn auch nur ein Begriff fehlt. Bei EINEM Begriff eine Liste
        mit einem Eintrag."""
        if self._content_lines is MISSING:
            self._content_lines = self.search.find_content_lines(self)
        return self._content_lines

# Die Kriterien einer Suche. Alle müssen zutreffen; `Search` sortiert sie
# nach `cost` und bricht beim ersten Nein ab. Reihenfolge: Name (gratis) →
# Dateifakten (stat/Katalog) → Maße (0,2 ms) → Metadaten (0,75 ms) → Inhalt.
# Genau das macht
# „Winter UND ≥ 1000 px" schnell: exiftool sieht nur die Dateien, die die
# Maßprüfung überlebt haben. Ein weiteres Textkriterium wäre eine weitere
# Klasse in dieser Liste — der Kern ist dafür geschnitten.

class NameCriterion:
    cost = 0

    def __init__(self, matchers):
        # Alle Begriffe müssen im Namen stehen (Mehrwortsuche: UND).
        self.matchers = list(matchers)

    def test(self, probe):
        return all(matcher(probe.name) for matcher in self.matchers)


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
            target.append(normalized)

    def __bool__(self):
        return bool(self.component_patterns or self.path_patterns)

    def matches(self, relative_path):
        if not self.component_patterns and not self.path_patterns:
            return False
        # `./` ist in TAR-Katalogen üblich. Es bezeichnet keinen Namen.
        # Nicht normpath(): Ein `..` im Archivnamen bleibt Teil des Namens,
        # und die Anzeige-/Übergabepfade selbst werden hier nie umgeschrieben.
        parts = [part for part in relative_path.split("/")
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
                 created_from=None, created_to=None, extra_matchers=()):
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
        self.content_probe = content_probe    # ContentProbe oder None:
                                              # billiger Vortest vor der
                                              # zeilenweisen Inhaltssuche
        # Wogegen das Muster läuft: "name", "content" oder "metadata" —
        # oder None, wenn es gar kein Muster gibt. Dann filtern allein die
        # Maß-/Faktengrenzen, und die Suche hat kein Textkriterium.
        if matcher is None:
            self.text_mode = None
        elif content_mode:
            self.text_mode = "content"
        elif metadata_mode:
            self.text_mode = "metadata"
        else:
            self.text_mode = "name"
        self.metadata_fields = list(metadata_fields or METADATA_TEXT_FIELDS)
        # Die Kriterienliste — siehe Kommentar über NameCriterion.
        criteria = []
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
        if self.wants_dimensions:
            self.exiftool_fields.extend(["ImageWidth", "ImageHeight"])
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
             terms=None):
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
            text = json.dumps(record, ensure_ascii=False)
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

    def warn(self, message):
        """Nicht-fatale Probleme (z. B. kaputtes Archiv, keine Leserechte)
        landen auf stderr, die Suche läuft weiter."""
        write_output("favenio: warnung: %s" % message, file=sys.stderr)

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
            write_output(json.dumps({"type": "progress",
                                     "path": json_safe_text(path)},
                                    ensure_ascii=False), flush=True)
        else:
            write_output("… durchsuche: %s" % path, file=sys.stderr)

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
                                                    warn=self.warn)
                except OSError as err:
                    self.warn("exiftool nicht startbar: %s" % err)
        return self._exiftool

    def close(self):
        """Räumt auf, was der Lauf gestartet hat (den exiftool-Prozess)."""
        if self._exiftool not in (MISSING, None):
            self._exiftool.close()
        self._exiftool = MISSING

    # ---------- Kriterien ----------

    def evaluate(self, probe, display, kind, filesystem_path=None,
                 archive_members=None):
        """Prüft alle Kriterien gegen EINE Datei bzw. EINEN Archiv-Eintrag
        und gibt bei Erfolg den Treffer aus. Das erste Nein beendet die
        Prüfung — die teuren Fragen kommen dank der Kostenreihenfolge
        zuletzt."""
        try:
            for criterion in self.criteria:
                if not criterion.test(probe):
                    return
            lines = (probe.content_lines() if self.text_mode == "content"
                     else None)
            dims = probe.dimensions() if self.wants_dimensions else None
        except EXPECTED_ARCHIVE_ERRORS as err:
            self.warn("%s: %s" % (probe.label, err))
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
                terms = [{"term": term, "line": number}
                         for term, number in zip(self.terms, lines)]
            elif probe.metadata_hits:
                terms = [{"term": term, "field": hit[0], "value": hit[1]}
                         for term, hit in zip(self.terms, probe.metadata_hits)]
            else:
                terms = [{"term": term} for term in self.terms]
        size, modified, created = probe.facts()
        self.emit(display, kind, line=line, size=size,
                  filesystem_path=filesystem_path,
                  archive_members=archive_members, is_dir=probe.is_dir,
                  field=field, value=value,
                  width=dims[0] if dims else None,
                  height=dims[1] if dims else None,
                  modified=modified, created=created, terms=terms)

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
            with probe.open_stream() as handle:
                return self.match_content_all(
                    probe.chunker(handle, free_bytes=head_bytes),
                    self.matchers, label=probe.label)
        probed_bytes = 0

        def tally(chunks):
            """Zählt mit, wie weit der Vortest wirklich gelesen hat. Genau
            diese Bytes stehen danach schon im Gesamtbudget; er hört beim
            ersten Fund mitten im Eintrag auf."""
            nonlocal probed_bytes
            for chunk in chunks:
                probed_bytes += len(chunk)
                yield chunk

        with probe.open_stream() as handle:
            if not self.content_probe.hits(
                    tally(probe.chunker(handle, free_bytes=head_bytes))):
                return None
        with probe.open_stream() as handle:
            # free_bytes: genau den Anfang, den der Vortest schon gelesen und
            # dem Gesamtbudget belastet hat, nicht zweimal zählen. Liest der
            # genaue Lauf weiter, zählt der Rest wieder mit.
            return self.match_content_all(
                probe.chunker(handle,
                              free_bytes=max(probed_bytes, head_bytes)),
                self.matchers, label=probe.label)

    # ---------- Inhalts-Matching ----------

    def match_content_all(self, chunks, matchers, label=None):
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
            line = self.match_content(chunks, label=label)
            return None if line is None else [line]
        remaining = list(enumerate(matchers))
        lines = [None] * len(matchers)
        warned = None
        for number, text, complete, _ in iter_line_pieces(chunks):
            for index, matcher in remaining[:]:
                if complete or getattr(matcher, "substring_only", False):
                    if matcher(text):
                        lines[index] = number
                        remaining.remove((index, matcher))
                elif warned != number:
                    self.warn("%s: Zeile %d ist länger als %d Zeichen und "
                              "wird mit diesem Muster nicht geprüft"
                              % (label or "<Eingabe>", number,
                                 MAX_LINE_CHARS))
                    warned = number
            if not remaining:
                return lines
        return None

    def match_content(self, chunks, label=None):
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
        piecewise = getattr(self.matcher, "substring_only", False)
        matcher = self.matcher
        warned = None         # Nummer der zu langen Zeile, die gemeldet ist
        for number, text, complete, _ in iter_line_pieces(chunks):
            if complete:
                if matcher(text):
                    return number
                continue
            # Ein Bruchstück einer zu langen Zeile — auch ihr letztes Stück
            # ist keine vollständige Zeile.
            if piecewise:
                if matcher(text):
                    return number
            elif warned != number:
                self.warn("%s: Zeile %d ist länger als %d Zeichen und wird "
                          "mit diesem Muster nicht geprüft"
                          % (label or "<Eingabe>", number, MAX_LINE_CHARS))
                warned = number
        return None

    # ---------- Dateisystem ----------

    def search_path(self, root):
        """Durchsucht einen Startpfad rekursiv (Datei ODER Ordner)."""
        if not os.path.isdir(root):
            # Auch Pipes und Geräte haben einen Namen. Nur ihr Inhalt ist
            # gesperrt; visit_file prüft das vor jedem Öffnen gesondert.
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
                                          folder, is_dir=True)
                        self.evaluate(probe, folder, "dir")
            # Was in `dirpath` liegt, hat die Tiefe `depth_of + 1`. Nur wenn
            # dessen Unterordner noch erlaubt wären, weiter absteigen — sonst
            # käme eine Ebene zu viel mit (`--max-depth 1` = nur direkt im
            # Startpfad, wie `find -maxdepth 1`).
            if self.max_depth is not None \
                    and self.depth_of(root, dirpath) + 1 >= self.max_depth:
                dirnames[:] = []
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
        return self.exclusions.matches(relative)

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
    def file_facts(path):
        """(Größe, Änderungszeit, Erstellungszeit) einer Datei oder eines
        Ordners aus EINER stat-Abfrage; jeder Wert ist None, wenn er sich
        nicht ermitteln lässt (toter Symlink: alle drei).

        Die Erstellungszeit (`st_birthtime`) kennt macOS; ein Dateisystem
        oder System ohne sie liefert None statt eines Fehlers."""
        try:
            status = os.stat(path)
        except OSError:
            return None, None, None
        birth = getattr(status, "st_birthtime", None)
        return status.st_size, status.st_mtime, birth

    def visit_file(self, path, root=None):
        """Behandelt EINE Datei im Dateisystem: alle Kriterien gegen die
        Datei selbst, und — falls es ein Archiv ist — der Blick hinein."""
        # Vor jedem Öffnen, auch vor dem Rückfall auf rohe Archivbytes.
        if self.path_is_excluded(path, root):
            return
        name = os.path.basename(path)
        archive_kind = classify_archive(name)
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
        # Wird NICHT in das Archiv geschaut — weil --no-archives bzw.
        # --archive-depth 0 das verbietet oder weil die Endung gar kein
        # Archiv ist —, dann ist die Datei eine ganz normale Datei und
        # ihr roher Inhalt wird durchsucht. Genau das passiert auch mit
        # einer .7z ohne bsdtar; beide Fälle dürfen sich nicht
        # unterscheiden, sonst hinge es vom Zufall der installierten
        # Werkzeuge ab, ob eine Datei überhaupt angefasst wird. Bei der
        # Namenssuche zählt das Archiv selbst immer auch als Datei.
        def as_plain_file():
            probe = FileProbe(self, path, name,
                              open_stream=lambda: open_regular_file(path),
                              chunker=self.file_chunks,
                              filesystem_path=path)
            self.evaluate(probe, path, "file")

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
                self.warn("%s: beschädigtes Archiv: %s" % (display, err))
            else:
                self.warn("%s: %s" % (display, err))
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

        full_display = display + "!/" + member_path
        member_chain = tuple(archive_members) + (member_path,)
        name = os.path.basename(member_path.rstrip("/"))

        # Unsichtbare Archiv-Einträge wie im Dateisystem überspringen.
        if not self.include_hidden and self.member_is_hidden(member_path):
            return

        # Jede Archivebene hat ihre eigene Wurzel. Direkt member_path prüfen,
        # niemals display an `!/` zerlegen: Ein echter Name darf `!` enthalten.
        if self.exclusions.matches(member_path):
            return

        if is_dir:
            # Archivordner nennen teils ihre Änderungszeit, nie ihre Größe.
            if self.directories_can_match and self.type_allowed(True):
                probe = FileProbe(self, full_display, name, None, None,
                                  archive_path, in_archive=True,
                                  modified=modified, is_dir=True)
                self.evaluate(probe, full_display, "member",
                              filesystem_path=archive_path,
                              archive_members=member_chain)
            return

        nested_kind = classify_archive(name)
        nested = nested_kind is not None and depth - 1 >= 1
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

        def as_plain_member(open_stream=None):
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
                              in_archive=True, modified=modified)
            self.evaluate(probe, full_display, "member",
                          filesystem_path=archive_path,
                          archive_members=member_chain)

        if self.type_allowed(False) \
                and (self.text_mode != "content" or not nested):
            as_plain_member()

        if nested:
            # Archiv im Archiv: Inhalt in den Speicher holen und rekursiv
            # weitersuchen (depth sinkt um 1).
            try:
                with open_member() as handle:
                    data = b"".join(chunker(handle))
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.warn("%s: %s" % (full_display, err))
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
                    and self.text_mode == "content":
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
                info.filename.rstrip("/"),
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
        members_by_name = {member.name: member
                           for member in bounded_tar_members(archive)}
        for member in members_by_name.values():
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
            try:
                verbose, _, verbose_status = bsdtar_list(bsdtar, path, env,
                                                         verbose=True)
            except ArchiveReadError:
                verbose, verbose_status = None, 1
            entries = bsdtar_listing_entries(
                raw, verbose if verbose_status == 0 else None)
            dir_names = set()
            if any(is_dir is None for _, is_dir in entries):
                self.warn("%s: Eintragstypen nicht bestimmbar, Ordner "
                          "werden geschätzt" % display)
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


def extract_result(result_path=None, filesystem_path=None, archive_members=None,
                   archive_member_bytes=None,
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
    # Kam der Pfad in !/-Notation, ist die Zerlegung mehrdeutig: Ein
    # Eintragsname darf selbst "!/" enthalten (Test-Fixture "odd!/name.txt").
    # Dann wird unten je Archivebene gegen die Eintragsliste aufgelöst.
    ambiguous = False
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
            ambiguous = len(archive_members) > 1
    fs_path = filesystem_path
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
    parser.add_argument("--term", action="append", metavar="TEXT",
                        default=[],
                        help="weiterer Suchbegriff, der ZUSÄTZLICH zutreffen "
                             "muss (wiederholbar; gleiche Regeln wie PATTERN, "
                             "gleiches Ziel: Name, --content oder --metadata; "
                             "UND über das ganze Objekt, nicht dieselbe Zeile)")
    parser.add_argument("-c", "--content", action="store_true",
                        help="im Dateiinhalt suchen statt in Dateinamen")
    parser.add_argument("-m", "--metadata", action="store_true",
                        help="in den Metadaten-Textfeldern suchen (Stich"
                             "wörter, Titel, Beschreibung …) statt in "
                             "Dateinamen; braucht exiftool")
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
    if (wants_filters or args.term) and args.pattern \
            and os.path.exists(args.pattern) \
            and all(os.path.exists(path) for path in args.paths):
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
    if not args.pattern and not wants_filters and not args.term:
        # parser.error() gibt die Usage aus und beendet mit Exit-Code 2.
        parser.error("PATTERN fehlt (oder --extract verwenden)")

    metadata_mode = args.metadata or bool(args.metadata_field)
    if args.content and metadata_mode:
        parser.error("--content und --metadata schließen sich aus")
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
    if (args.exact and len(terms) > 1 and not args.content
            and not metadata_mode and not args.regex):
        # Nur widersprüchliche WÖRTLICHE Namen schließen sich sicher aus.
        # Globs/Regexe können denselben ganzen Namen treffen, und ohne
        # Groß-/Kleinschreibung sind auch beide.txt und BEIDE.TXT identisch.
        literal_names = {term if args.case_sensitive else term.lower()
                         for term in terms if args.literal_wildcards
                         or not any(char in term for char in "*?[")}
        if len(literal_names) > 1:
            parser.error("--exact mit mehreren Begriffen enthält "
                         "widersprüchliche wörtliche Namen; --exact "
                         "weglassen oder --content nutzen")
    if not args.pattern and (args.content or metadata_mode):
        # Ohne Muster läuft die Suche ganz ohne Textkriterium (nur die
        # Maß-/Faktengrenzen zählen). --content und --metadata sagen, WOGEGEN das
        # Muster läuft, und sind dann eine widersprüchliche Angabe. Früher
        # sprang hier ein künstliches "*" ein: Mit --regex war das ein
        # ungültiger Ausdruck (Exit 2), mit --metadata ein stiller Filter
        # auf Dateien, die überhaupt Metadaten tragen.
        parser.error("--content und --metadata brauchen ein PATTERN")
    exiftool_path = find_exiftool()
    if metadata_mode and exiftool_path is None:
        print("favenio: fehler: --metadata braucht exiftool, das nicht "
              "gefunden wurde (z. B. `brew install exiftool`). Die "
              "Maßfilter kommen ohne aus.", file=sys.stderr)
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
                                      text_wildcards=args.content or metadata_mode)
                built.term = term      # Klartext für die Belege
                matchers.append(built)
            matcher, extra_matchers = matchers[0], matchers[1:]
    except re.error as err:
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
                                            text_wildcards=True)

    archive_depth = 0 if args.no_archives else args.archive_depth
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
                    **dimension_limits, **fact_limits)

    # Erst alle Startpfade prüfen, dann suchen: sonst stünden bei mehreren
    # Pfaden schon Treffer auf stdout, bevor ein späterer Pfad den Fehler
    # auslöst.
    for path in paths:
        if not os.path.exists(path):
            print("favenio: fehler: Pfad existiert nicht: %s" % path,
                  file=sys.stderr)
            return 2
    previous_handlers = install_termination_handlers()
    try:
        for path in paths:
            search.search_path(path)
        # Innerhalb des try leeren: Steckt der letzte Treffer noch im
        # Puffer, scheiterte sonst erst das Leeren beim Interpreter-Ende —
        # mit „Exception ignored" auf stderr und Status 120.
        sys.stdout.flush()
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

    return 0 if search.found_any else 1


if __name__ == "__main__":
    sys.exit(main())
