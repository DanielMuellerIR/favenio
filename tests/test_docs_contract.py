# Hält die Dokumentation am CLI-Vertrag fest.
#
# Diese Tests prüfen keinen Code, sondern ob README, README.de und AGENTS noch
# beschreiben, was favenio.py wirklich tut. Beide Lücken, die sie schließen,
# gab es wirklich: `-e/--exact` und `--max-depth` standen in den Beispielen,
# aber in keiner Optionstabelle, und das Feld `isDirectory` kam am 2026-08-17
# in JEDEN Treffer, ohne dass eine der drei Dateien es erwähnte.

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLI = (REPO / "favenio.py").read_text(encoding="utf-8")
READMES = {
    "README.md": (REPO / "README.md").read_text(encoding="utf-8"),
    "README.de.md": (REPO / "README.de.md").read_text(encoding="utf-8"),
}
AGENTS = (REPO / "AGENTS.md").read_text(encoding="utf-8")
CHANGELOG = (REPO / "CHANGELOG.md").read_text(encoding="utf-8")


def cli_constant(name):
    """Wert einer Konstante aus favenio.py, z. B. __version__."""
    return re.search(r'^%s = "([^"]+)"' % name, CLI, re.M).group(1)


def cli_long_options():
    """Alle langen Optionen, die argparse in favenio.py kennt.

    Die lange Form steht mal an erster Stelle (`"--hidden"`), mal hinter einer
    Kurzform (`"-e", "--exact"`) — beide Schreibweisen müssen erfasst werden,
    sonst prüft der Test stillschweigend zu wenig."""
    return sorted(set(re.findall(
        r'add_argument\(\s*(?:"-[a-z]",\s*)?"(--[a-z-]+)"', CLI)))


def option_table(text):
    """Der Abschnitt „Optionen"/„Options" bis zur nächsten Überschrift."""
    start = text.index("| Option |")
    rest = text[start:]
    return rest[:rest.index("\n##")]


def table_long_options(text):
    """Die langen Optionen, die eine Optionstabelle wirklich aufführt.

    Zwei Fallstricke, beide echt (Review-Fund 2026-08-20):

    1. Ein Test auf Teilstrings fände `--json` auch in `--extract-json` und
       `--extract` in `--extract-root`. Deshalb werden ganze Backtick-Wörter
       geschnitten: `[a-z-]+` endet von selbst am Leerzeichen oder am
       schließenden Backtick.
    2. Optionen stehen auch in fremden Beschreibungstexten — die Zeile zu
       `--progress` nennt zum Beispiel `--json`. Gezählt wird deshalb nur die
       erste Tabellenspalte, also die eigene Zeile einer Option."""
    options = set()
    for row in option_table(text).splitlines():
        if not row.startswith("|"):
            continue
        first_cell = row.split("|")[1]
        options.update(re.findall(r"`(--[a-z-]+)", first_cell))
    return options


class OptionTableTest(unittest.TestCase):
    def test_every_cli_option_is_documented_in_both_readmes(self):
        options = set(cli_long_options())
        self.assertIn("--exact", options)       # Sanity: Regex greift noch.
        for name, text in READMES.items():
            with self.subTest(readme=name):
                listed = table_long_options(text)
                self.assertEqual(sorted(options - listed), [],
                                 "fehlt in %s" % name)
                # Auch andersherum: Eine Tabelle darf keine Option führen,
                # die es in favenio.py gar nicht (mehr) gibt.
                self.assertEqual(sorted(listed - options), [],
                                 "steht in %s, kennt argparse aber nicht"
                                 % name)

    def test_both_option_tables_list_the_same_options(self):
        """Die deutsche Fassung ist eine Übersetzung, keine eigene Auswahl."""
        listed = {name: sorted(table_long_options(text))
                  for name, text in READMES.items()}
        self.assertEqual(listed["README.md"], listed["README.de.md"])


class JsonContractTest(unittest.TestCase):
    """Welche Felder JEDER Treffer trägt, steht im Kern in Search.emit()."""

    ALWAYS = ("path", "type", "isDirectory", "filesystemPath",
              "archiveMembers")

    def test_emit_writes_the_documented_always_fields(self):
        start = CLI.index("    def emit(self, path, kind")
        body = CLI[start:CLI.index("\n    def warn(", start)]
        for field in self.ALWAYS:
            with self.subTest(field=field):
                self.assertIn('"%s"' % field, body)

    def test_readmes_and_agents_name_the_always_fields(self):
        for name, text in list(READMES.items()) + [("AGENTS.md", AGENTS)]:
            for field in self.ALWAYS:
                with self.subTest(document=name, field=field):
                    self.assertIn("`%s`" % field, text)

    def test_documentation_warns_that_type_does_not_reveal_a_folder(self):
        """Der eigentliche Fallstrick: Ein Ordner IM Archiv kommt als
        `member` an wie eine Datei. Wer nur `type` liest, liegt falsch."""
        for name, text in list(READMES.items()) + [("AGENTS.md", AGENTS)]:
            # Zeilenumbrüche und Fettdruck wegnormalisieren: Die Aussage soll
            # zählen, nicht wo der Zeilenumbruch gerade fällt.
            plain = " ".join(text.replace("*", "").split()).lower()
            with self.subTest(document=name):
                self.assertRegex(
                    plain,
                    r"(ordner (im|innerhalb eines) archivs?|"
                    r"folder inside an archive).{0,120}member",
                    "%s erklärt nicht, dass ein Ordner im Archiv als "
                    "`member` ankommt" % name)

    def test_documentation_says_size_can_be_unavailable_for_plain_files(self):
        required = {
            "README.md": "cannot be determined",
            "README.de.md": "nicht ermitteln lässt",
            "AGENTS.md": "nicht ermitteln lässt",
        }
        texts = dict(READMES, **{"AGENTS.md": AGENTS})
        for name, phrase in required.items():
            with self.subTest(document=name):
                self.assertIn(phrase, " ".join(texts[name].split()))


class ChangelogTest(unittest.TestCase):
    """`favenio.py::__version__` ist die einzige Versionsquelle, und der
    CHANGELOG ist die einzige Stelle, an der Nutzer nachlesen, was diese
    Version ändert — beide Readmes verlinken ihn. Ohne Kopplung entsteht
    stillschweigend eine Version ohne Eintrag: Der Versionssprung fällt beim
    Bauen auf, der fehlende Eintrag niemandem."""

    def test_newest_entry_matches_version_and_date(self):
        entry = re.search(r"^## (\S+) — (\S+)$", CHANGELOG, re.M)
        self.assertIsNotNone(
            entry, "CHANGELOG.md hat keinen Eintrag der Form "
                   "'## X.Y.Z — JJJJ-MM-TT'")
        version, date = entry.group(1), entry.group(2)
        self.assertEqual(version, cli_constant("__version__"),
                         "oberster CHANGELOG-Eintrag passt nicht zu "
                         "__version__")
        self.assertEqual(date, cli_constant("__date__"),
                         "oberster CHANGELOG-Eintrag passt nicht zu __date__")
        self.assertRegex(date, r"^\d{4}-\d{2}-\d{2}$")


if __name__ == "__main__":
    unittest.main()
