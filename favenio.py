#!/usr/bin/env python3
"""Favenio — „facile invenio", ich finde mit Leichtigkeit.

Dateisuche im Stil von EasyFind (Suche ohne Index, direkt im Dateisystem),
mit einer zusätzlichen Fähigkeit: Favenio schaut auch IN Archive hinein
(Zip- und Tar-Familien, einzeln komprimierte .gz/.bz2/.xz-Dateien, auf
Wunsch auch Archive in Archiven). Mit den externen Werkzeugen bsdtar
(macOS-Bordmittel) und zstd kommen 7z, ISO und Zstandard dazu.

Grundprinzipien:
- Standardmäßig wird nach DATEINAMEN gesucht (Ordner zählen mit).
- Mit --content wird stattdessen im DATEIINHALT gesucht.
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
import bz2
import codecs
import fnmatch
import gzip
import io
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import zipfile
import zlib

__version__ = "0.24.2"
# Datum dieser Version (ISO 8601). Zweite Single-Source neben __version__;
# das Build-Skript gießt beides in eine Swift-Konstante für die Fenstertitel.
__date__ = "2026-08-20"

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
    return re.sub(r"([\\*?\[\]])", r"\\\1", member)


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


# Die beiden Kleinformen des griechischen Sigma. Welche davon str.lower() aus
# einem großen „Σ" macht, hängt davon ab, ob das Zeichen am Wortende steht —
# der einzige Fall, in dem Kleinschreibung vom Zusammenhang abhängt. Warum das
# für den Vortest wichtig ist, steht in ContentProbe.
GREEK_SMALL_SIGMA = "σ"   # σ
GREEK_FINAL_SIGMA = "ς"   # ς
GREEK_SIGMAS = GREEK_SMALL_SIGMA + GREEK_FINAL_SIGMA


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
)


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
        # Bei egaler Groß-/Kleinschreibung vergleichen wir kleingeschrieben —
        # genau wie der Matcher aus build_matcher() es pro Zeile tut.
        needle = needle if case_sensitive else needle.lower()
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
            char in needle for char in GREEK_SIGMAS)
        if self.fold_sigma:
            needle = needle.replace(GREEK_FINAL_SIGMA, GREEK_SMALL_SIGMA)
        self.needle = needle
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
        overlap = max(0, len(self.needle) - 1)
        carry = ""
        for text in codecs.iterdecode(chunks, "utf-8", errors="replace"):
            if not text:
                continue
            if not self.case_sensitive:
                text = text.lower()
                if self.fold_sigma:
                    text = text.replace(GREEK_FINAL_SIGMA, GREEK_SMALL_SIGMA)
            window = carry + text
            if self.needle in window:
                return True
            carry = window[-overlap:] if overlap else ""
        return False


def build_content_probe(pattern, use_regex, case_sensitive):
    """Baut den Vortest für die Inhaltssuche — oder None, wenn keiner möglich
    ist.

    Möglich ist er nur, wenn wir einen festen Suchtext kennen. Bei --regex und
    bei Glob-Mustern (* ? [) steckt kein solcher Text im Muster, den ein
    Treffer garantiert enthalten müsste; dort bleibt es beim genauen Lauf.
    `--exact` ist dagegen unkritisch: Dort muss die ganze Zeile dem Muster
    entsprechen, der Suchtext kommt also erst recht vor."""
    if use_regex or any(char in pattern for char in "*?["):
        return None
    return ContentProbe(pattern, case_sensitive)


def build_matcher(pattern, use_regex, case_sensitive, exact=False):
    """Baut aus dem Suchmuster eine Funktion  text -> True/False .

    Drei Fälle:
    1. --regex:            Muster ist ein regulärer Ausdruck (re.search).
    2. Muster mit * ? [ :  Glob-Matching auf den GANZEN Namen (wie die Shell).
    3. sonst:              einfacher „enthält"-Test (wie EasyFind-Default).

    `exact` verlangt in allen Fällen den GANZEN Namen: aus dem „enthält"-Test
    wird Gleichheit, aus `re.search` wird `re.fullmatch`. Ein Glob-Muster
    matcht ohnehin schon den ganzen Namen und bleibt deshalb unverändert.
    Genau dafür gibt es die Option: `release.sh` ohne Platzhalter ist sonst ein
    Teilstring und findet auch `test-github-release.sh`.
    """
    flags = 0 if case_sensitive else re.IGNORECASE

    if use_regex:
        # Ungültige Regexes fängt main() ab und meldet sie als Fehler.
        compiled = re.compile(pattern, flags)
        if exact:
            return lambda text: compiled.fullmatch(text) is not None
        return lambda text: compiled.search(text) is not None

    if any(char in pattern for char in "*?["):
        # fnmatch.translate macht aus dem Glob-Muster einen Regex,
        # der den kompletten String matchen muss.
        compiled = re.compile(fnmatch.translate(pattern), flags)
        return lambda text: compiled.match(text) is not None

    if exact:
        if case_sensitive:
            return lambda text: text == pattern
        lowered_exact = pattern.lower()
        return lambda text: text.lower() == lowered_exact

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
                 content_probe=None):
        self.matcher = matcher                # Funktion text -> bool
        self.content_probe = content_probe    # ContentProbe oder None:
                                              # billiger Vortest vor der
                                              # zeilenweisen Inhaltssuche
        self.content_mode = content_mode      # True = Inhalt, False = Namen
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
             archive_members=None, is_dir=None):
        """Gibt EINEN Treffer aus. kind ist "file", "dir" oder "member"
        (member = Eintrag innerhalb eines Archivs). line ist bei
        Inhaltssuche die Zeilennummer des ersten Treffers, size die
        Dateigröße in Bytes (bei Ordnern None).

        `is_dir` sagt ausdrücklich, ob der Treffer ein Verzeichnis ist. Der
        Typ `member` allein verrät das nicht: Ein Ordner IM Archiv kam vorher
        genauso an wie eine Datei im Archiv, und die Oberfläche zeigte ihn als
        Datei an, filterte ihn beim Ordner-Umschalter falsch und erzeugte beim
        Öffnen eine leere Datei (Review-Fund 2026-08-17). Ohne Angabe folgt es
        dem Typ."""
        self.found_any = True
        directory = kind == "dir" if is_dir is None else bool(is_dir)
        if self.as_json:
            record = {"path": path, "type": kind, "isDirectory": directory}
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
                # Bei Namenssuche zählen auch Ordnernamen als Treffer. Das
                # passiert VOR dem Abschneiden unten: Ein Ordner GENAU auf der
                # Grenztiefe ist selbst noch ein erlaubter Treffer, nur sein
                # Inhalt nicht mehr (`find -maxdepth 1` listet die direkten
                # Unterordner ebenfalls).
                for dirname in dirnames:
                    if self.matcher(dirname) and self.type_allowed(True):
                        self.emit(os.path.join(dirpath, dirname), "dir")
            # Was in `dirpath` liegt, hat die Tiefe `depth_of + 1`. Nur wenn
            # dessen Unterordner noch erlaubt wären, weiter absteigen — sonst
            # käme eine Ebene zu viel mit (`--max-depth 1` = nur direkt im
            # Startpfad, wie `find -maxdepth 1`).
            if self.max_depth is not None \
                    and self.depth_of(root, dirpath) + 1 >= self.max_depth:
                dirnames[:] = []
            for filename in filenames:
                self.visit_file(os.path.join(dirpath, filename))

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
        elif self.content_mode:
            # Wird NICHT in das Archiv geschaut — weil --no-archives bzw.
            # --archive-depth 0 das verbietet oder weil die Endung gar kein
            # Archiv ist —, dann ist die Datei eine ganz normale Datei und
            # ihr roher Inhalt wird durchsucht. Genau das passiert auch mit
            # einer .7z ohne bsdtar; beide Fälle dürfen sich nicht
            # unterscheiden, sonst hinge es vom Zufall der installierten
            # Werkzeuge ab, ob eine Datei überhaupt angefasst wird.
            self.scan_content(path)

    def scan_content(self, path):
        """Inhaltssuche in EINER normalen Datei des Dateisystems.

        Gelesen wird häppchenweise statt am Stück: so bleibt der Speicher
        unabhängig von der Dateigröße klein, und bei einem Treffer weit
        vorne sparen wir uns den ganzen Rest.

        Gibt es einen Vortest (ContentProbe), läuft er zuerst. Die meisten
        Dateien enthalten den Suchtext nicht und sind damit ohne die teure
        Arbeit pro Zeile abgehakt."""
        try:
            with open(path, "rb") as handle:
                # iter(callable, sentinel) ruft read() so lange auf,
                # bis es b"" liefert — das Dateiende.
                if self.content_probe is not None:
                    if not self.content_probe.hits(
                            iter(lambda: handle.read(CHUNK_SIZE), b"")):
                        return
                    # Der Suchtext kommt vor: noch einmal von vorn, diesmal
                    # genau, für die Zeilennummer. Das zweite Lesen ist
                    # billig, weil die Datei jetzt im Cache des Systems liegt.
                    handle.seek(0)
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
            elif kind == "tar":
                # tarfile erkennt die Kompression selbst ("r:*").
                if fileobj is not None:
                    archive = tarfile.open(fileobj=fileobj, mode="r:*")
                else:
                    archive = tarfile.open(fs_path, mode="r:*")
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
                      archive_members=member_chain, is_dir=is_dir)

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
        elif self.content_mode:
            # Wird in diesen Eintrag NICHT hineingeschaut — weil die
            # --archive-depth aufgebraucht ist oder weil er gar kein Archiv
            # ist —, dann gilt dieselbe Regel wie eine Ebene höher in
            # visit_file(): Der Eintrag ist ein ganz normaler Eintrag, und
            # sein roher Inhalt wird durchsucht. Ohne das entschiede auch
            # hier der Grund über das Ergebnis — ein .7z ohne bsdtar wurde
            # durchsucht, ein .zip an der Tiefengrenze dagegen nicht.
            try:
                line = self.member_hit_line(open_member, full_display,
                                            size, compressed_size)
            except EXPECTED_ARCHIVE_ERRORS as err:
                self.warn("%s: %s" % (full_display, err))
                return
            if line is not None and self.type_allowed(False):
                self.emit(full_display, "member", line, size=size,
                          filesystem_path=archive_path,
                          archive_members=member_chain)

    def member_hit_line(self, open_member, label, size, compressed_size):
        """Zeilennummer des ersten Inhaltstreffers in EINEM Archiv-Eintrag,
        oder None.

        Ohne Vortest ist das ein Durchlauf wie bei einer normalen Datei. Mit
        Vortest sind es zwei: erst das billige Ja/Nein, und nur bei Ja das
        genaue Zählen. Auch im Archiv lohnt sich das, denn das Entpacken ist
        hier nicht der Hauptaufwand (gemessen am 2026-07-28 an einem 22-MB-Zip
        mit 72,8 MB Inhalt: 0,12 s Entpacken gegenüber 0,68 s Gesamtsuche).

        Der Eintrag wird für den zweiten Durchlauf neu geöffnet — ein
        entpackender Datenstrom lässt sich nicht zurückspulen."""
        if self.content_probe is None:
            with open_member() as handle:
                return self.match_content(self.archive_budget.iter_chunks(
                    handle, label, size, compressed_size))
        probed_bytes = 0

        def tally(chunks):
            """Zählt mit, wie weit der Vortest wirklich gelesen hat. Genau
            diese Bytes stehen danach schon im Gesamtbudget; er hört beim
            ersten Fund mitten im Eintrag auf."""
            nonlocal probed_bytes
            for chunk in chunks:
                probed_bytes += len(chunk)
                yield chunk

        with open_member() as handle:
            if not self.content_probe.hits(tally(
                    self.archive_budget.iter_chunks(
                        handle, label, size, compressed_size))):
                return None
        with open_member() as handle:
            # free_bytes: genau den Anfang, den der Vortest schon gelesen und
            # dem Gesamtbudget belastet hat, nicht zweimal zählen. Liest der
            # genaue Lauf weiter, zählt der Rest wieder mit.
            return self.match_content(self.archive_budget.iter_chunks(
                handle, label, size, compressed_size,
                free_bytes=probed_bytes))

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
        """Geht alle Einträge eines Tar-Archivs durch.

        Anders als bei Zip wird hier KEIN compressed_size übergeben, und damit
        greift die Kompressionsverhältnis-Prüfung aus ArchiveBudget nicht: Ein
        Tar komprimiert als Ganzes, nicht pro Eintrag — eine Einzelgröße gibt
        es schlicht nicht. Gegen eine Entpack-Bombe schützen bei Tar deshalb
        allein die Byte-Budgets (Einzel- und Gesamtgrenze), die beim Lesen
        greifen. Das ist kein Versehen, sondern die Grenze des Formats."""
        for member in archive.getmembers():
            def open_member(member=member):
                extracted = archive.extractfile(member)
                if extracted is None:
                    raise tarfile.TarError("Eintrag nicht lesbar")
                return extracted
            self.visit_member(member.name, member.isdir(), open_member,
                              display, depth, archive_path, archive_members,
                              size=member.size)

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
            compressed_size = len(data)

            def open_member():
                return opener(io.BytesIO(data), "rb")
        else:
            compressed_size = self.file_size(fs_path)

            def open_member():
                return opener(fs_path, "rb")
        self.visit_member(member_name, False, open_member, display, depth,
                          archive_path, archive_members,
                          size=None, compressed_size=compressed_size)

    def walk_bsdtar(self, fs_path, fileobj, display, depth, archive_path,
                    archive_members):
        """Durchsucht ein Format, das nur das externe bsdtar lesen kann
        (7z, ISO, tar.zst): Auflistung über `bsdtar -tf`, Inhalt je
        Eintrag als Datenstrom über `bsdtar -xOf`.

        Liegt das Archiv nur im Speicher (Archiv im Archiv), wird es in
        eine Temp-Datei geschrieben — 7z und ISO brauchen wahlfreien
        Zugriff und lassen sich nicht verlässlich von stdin lesen.

        Ordner-Erkennung: 7z listet Ordner mit Schrägstrich am Ende, ISO
        ohne. Deshalb gilt ein Eintrag auch dann als Ordner, wenn andere
        Einträge unter ihm liegen; ein LEERER Ordner in einem ISO wird
        dadurch als Datei geführt. Sein Inhalt ist leer, aber der Typ stimmt
        nicht: `--only files` zeigt ihn, `--only dirs` nicht. Bekannt und im
        BACKLOG notiert — sauber wäre eine typtragende bsdtar-Auflistung.
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
            listing = subprocess.run(
                [bsdtar, "-tf", path],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            if listing.returncode != 0:
                raise ArchiveReadError(
                    listing.stderr.decode("utf-8", "replace").strip()
                    or "bsdtar konnte das Archiv nicht lesen")
            names = []
            for raw_line in listing.stdout.split(b"\n"):
                # Erst die Maskierung zurücknehmen (bsdtar schreibt z. B. für
                # einen Tabulator die zwei Zeichen \t), dann dekodieren. Echte
                # Zeilenumbrüche im Namen kommen ebenfalls maskiert an, die
                # Zeilenaufteilung bleibt dadurch heil.
                raw = bsdtar_unescape(raw_line).decode("utf-8", "replace")
                # ISO listet ein "."-Wurzelelement; "./"-Präfixe würden
                # als versteckte Komponente gelten — beides normalisieren.
                if raw.startswith("./"):
                    raw = raw[2:]
                if raw in ("", ".", "./"):
                    continue
                names.append(raw)
            dir_names = set()
            for name in names:
                clean = name.rstrip("/")
                if name.endswith("/"):
                    dir_names.add(clean)
                parts = clean.split("/")
                for count in range(1, len(parts)):
                    dir_names.add("/".join(parts[:count]))
            seen = set()
            for name in names:
                clean = name.rstrip("/")
                if clean in seen:
                    continue
                seen.add(clean)

                def open_member(member=clean):
                    proc = subprocess.Popen(
                        [bsdtar, "-xOf", path, "--", bsdtar_escape(member)],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        env=env)
                    return ToolStream(proc, display + "!/" + member)
                self.visit_member(clean, clean in dir_names, open_member,
                                  display, depth, archive_path,
                                  archive_members, size=None)
        finally:
            if temp_path is not None:
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass


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
    # Name des Archivs der aktuellen Ebene — bei Einzelkompression bestimmt
    # er den einzig gültigen Eintragsnamen (Dateiname ohne Endung).
    container_name = os.path.basename(fs_path.rstrip("/"))
    budget = ArchiveBudget(max_archive_member_bytes,
                           max_archive_total_bytes,
                           max_archive_ratio)
    try:
        # Ebene für Ebene absteigen: erst das Archiv auf der Platte
        # öffnen, dann ggf. innere Archive aus dem Speicher heraus.
        for member in members:
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
            elif kind == "tar":
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
                    proc = subprocess.Popen(
                        [bsdtar, "-xOf", path, "--", bsdtar_escape(member)],
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        env=env)
                    with ToolStream(proc, display_path) as handle:
                        data = budget.read_all(handle, display_path)
                finally:
                    if temp_path is not None:
                        try:
                            os.unlink(temp_path)
                        except OSError:
                            pass
            else:  # Einzelkompression: kind ist die Endung, z. B. ".gz"
                expected = single_member_name(container_name, kind)
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
    parser.add_argument("-c", "--content", action="store_true",
                        help="im Dateiinhalt suchen statt in Dateinamen")
    parser.add_argument("-r", "--regex", action="store_true",
                        help="Muster als regulären Ausdruck interpretieren")
    parser.add_argument("-s", "--case-sensitive", action="store_true",
                        help="Groß-/Kleinschreibung beachten")
    parser.add_argument("-e", "--exact", action="store_true",
                        help="Muster muss dem GANZEN Namen entsprechen statt "
                             "nur enthalten zu sein (mit --regex: fullmatch; "
                             "mit --content gilt es je Zeile)")
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
    parser.add_argument("--max-depth", type=positive_int, default=None,
                        metavar="N",
                        help="nur N Ordnerebenen tief suchen (1 = nur direkt "
                             "im Startpfad, wie find -maxdepth); Default: "
                             "unbegrenzt")
    parser.add_argument("--archive-depth", type=nonnegative_int, default=1,
                        metavar="N",
                        help="wie tief in verschachtelte Archive schauen "
                             "(0 = gar nicht, wie --no-archives; 1 = Archive, "
                             "2 = Archive in Archiven, …; Default: 1)")
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
        matcher = build_matcher(args.pattern, args.regex, args.case_sensitive,
                                exact=args.exact)
    except re.error as err:
        print("favenio: fehler: ungültiger regulärer Ausdruck: %s" % err,
              file=sys.stderr)
        return 2

    # Der Vortest greift nur bei der Inhaltssuche; bei der Namenssuche gibt es
    # keine Zeilen zu zählen und damit nichts zu sparen.
    content_probe = None
    if args.content:
        content_probe = build_content_probe(args.pattern, args.regex,
                                            args.case_sensitive)

    archive_depth = 0 if args.no_archives else args.archive_depth
    search = Search(matcher, args.content, archive_depth, args.json,
                    progress=args.progress, only=args.only,
                    include_hidden=args.hidden, max_depth=args.max_depth,
                    max_archive_member_bytes=args.max_archive_member_bytes,
                    max_archive_total_bytes=args.max_archive_total_bytes,
                    max_archive_ratio=args.max_archive_ratio,
                    content_probe=content_probe)

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
