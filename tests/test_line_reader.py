"""Der herausgelöste Zeilenleser (`iter_line_pieces`) gegen die alte
`match_content()`-Fassung: gleiche Treffer, Zeilennummern, Warnungen und
gleiches frühes Leseende — Eingabe für Eingabe."""
import codecs
import io
import os
import random
import sys
import unittest
from contextlib import redirect_stderr

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import favenio  # noqa: E402


class LegacyReader:
    """Wörtliche Kopie von Search.match_content() aus 7fc8691 (0.32.0),
    der Fassung VOR dem Herausziehen des Lesers — nur `self.matcher` und
    `self.warn` sind Attribute dieser Hülle. Der Vergleich gegen diese
    Kopie ist die Abnahme des Refactors."""

    def __init__(self, matcher, warn):
        self.matcher = matcher
        self.warn = warn

    def legacy_match_content(self, chunks, label=None):
        """Sucht das Muster im Datei-Inhalt. Liefert die Zeilennummer des
        ersten Treffers oder None.

        chunks ist eine Folge von Byte-Häppchen zu je CHUNK_SIZE — bei
        Dateien von der Platte, bei Archiv-Einträgen aus dem budgetierten
        Chunker. Beim ersten Treffer steigen wir sofort aus; der Rest der
        Datei wird dann gar nicht mehr gelesen.

        Dekodiert wird als UTF-8 mit errors="replace", damit die Suche auch
        in „halb-binären" Dateien funktioniert, ohne dass das Programm
        abbricht. Der inkrementelle Decoder setzt Mehrbyte-Zeichen über
        Häppchengrenzen hinweg korrekt zusammen; das Ergebnis ist deshalb
        identisch zum Dekodieren der ganzen Datei am Stück."""
        pending = []          # Bruchstücke der noch nicht beendeten Zeile
        pending_chars = 0     # deren Gesamtlänge, ohne sie zusammenzusetzen
        number = 0
        # Darf der Matcher ein Bruchstück sehen? Nur der reine
        # „enthält"-Test; alles andere ist verankert (siehe build_matcher).
        piecewise = getattr(self.matcher, "substring_only", False)
        skipping = False      # Zeile zu lang und mit diesem Muster ungeprüft
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
                    and text[-1] not in favenio.LINE_BREAKS:
                if pending_chars > favenio.MAX_LINE_CHARS:
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
                            if skipping:
                                skipping = False
                            elif self.matcher(line):
                                return number
                        segment = finished[-1]
                    if len(segment) > favenio.MAX_LINE_CHARS:
                        # Die Zeile ist noch nicht zu Ende, aber schon zu
                        # lang. Die Zeilennummer bleibt dieselbe, denn es
                        # ist weiterhin EINE Zeile.
                        if piecewise and not skipping:
                            if self.matcher(segment):
                                return number + 1
                            # Nicht segment[-favenio.LINE_OVERLAP_CHARS:] ohne
                            # Prüfung: Bei einer Überlappung von 0 wäre das
                            # segment[0:], also der GANZE Abschnitt — die
                            # Grenze verschwände lautlos, und genau der
                            # Speicherfehler wäre zurück.
                            segment = (segment[-favenio.LINE_OVERLAP_CHARS:]
                                       if favenio.LINE_OVERLAP_CHARS > 0 else "")
                        else:
                            # Verankerte Muster (--regex mit ^ oder $,
                            # Glob, --exact) gelten für die GANZE Zeile.
                            # Auf einem Bruchstück geprüft träfen sie
                            # falsch: `--regex 'A$'` traf am Abschnitts-
                            # statt am Zeilenende und meldete einen
                            # Treffer, den grep nicht sieht. Diese Zeile
                            # bleibt deshalb ungeprüft — gemeldet, statt
                            # still falsch beantwortet.
                            if not skipping:
                                self.warn(
                                    "%s: Zeile %d ist länger als %d "
                                    "Zeichen und wird mit diesem Muster "
                                    "nicht geprüft"
                                    % (label or "<Eingabe>", number + 1,
                                       favenio.MAX_LINE_CHARS))
                                skipping = True
                            segment = ""
                    pending = [segment]
                    pending_chars = len(segment)
                continue
            buffer = "".join(pending)
            pending.clear()
            pending_chars = 0
            lines = buffer.splitlines()
            if buffer[-1] not in favenio.LINE_BREAKS:
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
            for line in lines:
                number += 1
                if skipping:
                    # Nur der REST der zu langen Zeile wird übersprungen;
                    # ab der nächsten Zeile wird wieder normal geprüft.
                    skipping = False
                    continue
                if self.matcher(line):
                    return number
        # Rest: die letzte noch offene Zeile prüfen. Den Decoder leert
        # iterdecode() selbst — ein angebrochenes Mehrbyte-Zeichen am
        # Dateiende steht dann schon als Ersatzzeichen im Puffer.
        for line in "".join(pending).splitlines():
            number += 1
            if skipping:
                skipping = False
                continue
            if self.matcher(line):
                return number
        return None


class CountingChunks:
    """Zählt, wie viele Häppchen der Leser wirklich abgeholt hat — das
    frühe Leseende beim ersten Treffer muss gleich bleiben."""

    def __init__(self, chunks):
        self.chunks = iter(chunks)
        self.consumed = 0

    def __iter__(self):
        return self

    def __next__(self):
        chunk = next(self.chunks)
        self.consumed += 1
        return chunk


SEPARATORS = ["\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e",
              "\x85", "\u2028", "\u2029"]


def matchers():
    """Ein reiner Substring-Matcher (darf Bruchstücke sehen) und drei
    verankerte (dürfen es nicht): Regex mit $, Glob, --exact."""
    return {
        "substring": favenio.build_matcher("ZIEL", False, False),
        "regex-anchored": favenio.build_matcher("ZIEL$", True, False),
        "glob": favenio.build_matcher("*ZIEL*", False, False),
        "exact": favenio.build_matcher("ZIEL", False, False, exact=True),
    }


def run_both(text_or_bytes, chunk, max_chars, overlap):
    """Liefert je Matcher (alt, neu) mit (Trefferzeile, Warnungen,
    verbrauchte Häppchen)."""
    blob = (text_or_bytes.encode("utf-8") if isinstance(text_or_bytes, str)
            else text_or_bytes)
    chunks = [blob[i:i + chunk] for i in range(0, len(blob), chunk)]
    results = {}
    vorher = (favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS)
    favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = max_chars, overlap
    try:
        for name, matcher in matchers().items():
            pair = []
            for variant in ("legacy", "new"):
                warnings = []
                counter = CountingChunks(chunks)
                if variant == "legacy":
                    hit = LegacyReader(matcher, warnings.append) \
                        .legacy_match_content(counter, label="probe")
                else:
                    search = favenio.Search(matcher, True, 1, False)
                    search.warn = warnings.append
                    hit = search.match_content(counter, label="probe")
                pair.append((hit, warnings, counter.consumed))
            results[name] = tuple(pair)
    finally:
        favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = vorher
    return results


class LineReaderEquivalenceTest(unittest.TestCase):
    def assertSame(self, data, chunk=7, max_chars=1000, overlap=50):
        for name, (legacy, new) in run_both(data, chunk, max_chars,
                                            overlap).items():
            with self.subTest(matcher=name, chunk=chunk):
                self.assertEqual(legacy, new)

    def test_plain_lf_lines(self):
        self.assertSame("erste\nzweite ZIEL\ndritte\n")
        self.assertSame("erste\nzweite\ndritte")
        self.assertSame("")
        self.assertSame("\n\n\nZIEL\n\n")

    def test_crlf_and_lone_cr_across_every_chunk_boundary(self):
        text = "a\r\nb\r\nZIEL\r\nc\rd\re ZIEL\r\n\r\n\rZIEL"
        for chunk in range(1, 12):
            self.assertSame(text, chunk=chunk)

    def test_every_separator_python_knows(self):
        for separator in SEPARATORS:
            text = separator.join(["eins", "zwei", "ZIEL", "vier", ""])
            for chunk in (1, 3, 5, 64):
                self.assertSame(text, chunk=chunk)

    def test_utf8_boundaries_and_replacement_characters(self):
        text = "grün\näöü ZIEL\n€€€\n😀 ZIEL"
        for chunk in range(1, 9):
            self.assertSame(text, chunk=chunk)
        # Ungültige Bytes: Ersatzzeichen, kein Abbruch — und ein
        # angebrochenes Mehrbyte-Zeichen am Dateiende.
        for chunk in (1, 2, 5):
            self.assertSame(b"\xff\xfe ZIEL\n\xc3", chunk=chunk)
            self.assertSame(b"abc\n\xe2\x82", chunk=chunk)

    def test_last_line_without_newline_and_empty_lines(self):
        self.assertSame("eins\n\nZIEL")
        self.assertSame("\n\n\n")
        self.assertSame("ZIEL")

    def test_overlong_lines_with_and_without_hits(self):
        # 5000 Zeichen ohne Umbruch bei Grenze 1000 / Überlappung 50, mit
        # Treffer an jeder Stelle — auch im Überlappungsbereich — und ohne.
        for stelle in (0, 500, 999, 1000, 1001, 1150, 1200, 2500, 4990):
            text = "a" * stelle + "ZIEL" + "a" * (5000 - stelle - 4)
            for chunk in (200, 333):
                self.assertSame(text, chunk=chunk)
        self.assertSame("a" * 5000)
        # Zu lange Zeile, dann normale Zeilen: Die Nummern danach stimmen.
        self.assertSame("a" * 3000 + "\nZIEL\n")
        self.assertSame("a" * 3000 + "\r\nb\nZIEL")
        # Einzelnes \r im Puffer vor dem Abschnittswechsel.
        self.assertSame("x\r" + "a" * 3000 + "\nZIEL\n", chunk=200)
        # Zwei zu lange Zeilen hintereinander: zwei Warnungen.
        self.assertSame("a" * 2500 + "\n" + "b" * 2500 + "\nZIEL")
        # Überlappung 0 und Grenze knapp am Häppchen.
        self.assertSame("a" * 3000 + "ZIEL", chunk=200, max_chars=1000,
                        overlap=0)

    def test_random_inputs_agree(self):
        alphabet = ["a", "b", "ZIEL", "Z", "IEL", "ä", "😀", " "] + SEPARATORS
        rng = random.Random(20260905)
        for _ in range(300):
            text = "".join(rng.choice(alphabet)
                           for _ in range(rng.randint(0, 400)))
            chunk = rng.randint(1, 40)
            max_chars = rng.choice([30, 100, 1000])
            overlap = rng.choice([0, 5, 20])
            self.assertSame(text, chunk=chunk, max_chars=max_chars,
                            overlap=overlap)


class LinePieceTest(unittest.TestCase):
    """Was der Leser je Stück verspricht: Zeilennummer, vollständige Zeile
    oder Bruchstück, Zeilenende."""

    def pieces(self, text, chunk=10, max_chars=30, overlap=5):
        blob = text.encode("utf-8")
        chunks = [blob[i:i + chunk] for i in range(0, len(blob), chunk)]
        # Der Generator liefert nackte Tupel (Kostengründe, siehe
        # LinePiece.__doc__); für die Feldnamen hier umgewandelt.
        return [favenio.LinePiece._make(piece) for piece in
                favenio.iter_line_pieces(iter(chunks), max_chars, overlap)]

    def test_complete_lines(self):
        self.assertEqual(self.pieces("eins\nzwei\r\n\ndrei"), [
            favenio.LinePiece(1, "eins", True, True),
            favenio.LinePiece(2, "zwei", True, True),
            favenio.LinePiece(3, "", True, True),
            favenio.LinePiece(4, "drei", True, True),
        ])

    def test_fragments_of_a_long_line_are_never_complete(self):
        pieces = self.pieces("a" * 100 + "\nkurz\n")
        fragments = [p for p in pieces if p.number == 1]
        self.assertGreater(len(fragments), 1)
        # Kein Stück der langen Zeile gilt als vollständig — auch das
        # letzte nicht, das mit dem Umbruch endet.
        self.assertTrue(all(not p.complete for p in fragments))
        self.assertEqual([p.ends_line for p in fragments],
                         [False] * (len(fragments) - 1) + [True])
        # Der Text ist mit Überlappung lückenlos: Jedes Stück beginnt mit
        # dem Schwanz des vorigen.
        for before, after in zip(fragments, fragments[1:]):
            self.assertTrue(after.text.startswith(before.text[-5:]))
        self.assertEqual(pieces[-1], favenio.LinePiece(2, "kurz", True, True))

    def test_last_fragment_without_newline_still_ends_the_line(self):
        pieces = self.pieces("a" * 100)
        self.assertTrue(all(p.number == 1 and not p.complete for p in pieces))
        self.assertTrue(pieces[-1].ends_line)
        self.assertTrue(all(not p.ends_line for p in pieces[:-1]))

    def test_the_search_only_matches_fragments_with_a_substring_matcher(self):
        text = "a" * 100 + "ZIEL" + "a" * 100 + "\nZIEL\n"
        vorher = (favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS)
        favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = 30, 5
        try:
            blob = text.encode("utf-8")
            chunks = lambda: iter([blob[i:i + 10]
                                   for i in range(0, len(blob), 10)])
            plain = favenio.Search(favenio.build_matcher("ZIEL", False, False),
                                   True, 1, False)
            self.assertEqual(plain.match_content(chunks()), 1)
            anchored = favenio.Search(
                favenio.build_matcher("ZIEL$", True, False), True, 1, False)
            err = io.StringIO()
            with redirect_stderr(err):
                self.assertEqual(anchored.match_content(chunks(), "p"), 2)
            self.assertEqual(err.getvalue().count("Zeile 1 ist länger"), 1)
        finally:
            favenio.MAX_LINE_CHARS, favenio.LINE_OVERLAP_CHARS = vorher


if __name__ == "__main__":
    unittest.main()
