"""Einmalaktionen weisen widersprüchliche Aufträge vor der Ausführung ab."""

from itertools import combinations
import json
import unittest

from test_favenio import run
from test_criteria import arguments, leaf


class CLIModeTests(unittest.TestCase):
    def test_criteria_validation_keeps_resolved_search_calendar_ranges(self):
        dates = {
            "schemaVersion": 1,
            "ranges": {"modified": {"kind": "relative", "preset": "today", "timeZone": "UTC"}},
        }
        code, lines, errors = run([
            "--validate-criteria", *arguments(leaf("valid")),
            "--date-ranges-json", json.dumps(dates), "--date-reference-time", "2026-11-21T12:00:00Z",
        ])
        self.assertEqual((code, errors, len(lines)), (0, "", 1))
        result = json.loads(lines[0])
        self.assertEqual((result["type"], result["valid"]), ("validation", True))
        entry, = result["dateResolution"]["entries"]
        self.assertEqual(entry["id"], "modified")
        self.assertEqual(entry["lowerISO"], "2026-11-21T00:00:00Z")

    def test_action_pairs_are_rejected_before_processing_the_payload(self):
        actions = [
            ["--duplicates-file", "unreadable.json"],
            ["--resolve-date-range", "{invalid"],
            ["--filter-results", "unreadable.jsonl"],
            ["--validate-result-filter"],
            ["--preview-request", "{invalid"],
            ["--validate-criteria"],
            ["--snapshot-position-json", "{invalid"],
            ["--extract", "missing.txt"],
            ["--extract-json", "{invalid"],
            ["--list-metadata-fields"],
        ]
        for first, second in combinations(actions, 2):
            with self.subTest(first=first[0], second=second[0]):
                code, lines, errors = run(first + second)
                self.assertEqual((code, lines), (2, []))
                diagnostic = errors.splitlines()[-1]
                self.assertIn("favenio: fehler: Betriebsarten schließen sich aus", diagnostic)
                self.assertIn(first[0], diagnostic)
                self.assertIn(second[0], diagnostic)

    def test_single_actions_do_not_silently_accept_search_options(self):
        for args, conflicting, option in [
            (["--preview-request", "{}"], ["--max-width", "100"], "--max-width"),
            (["--preview-request", "{}"], ["--json", "--search-report"], "--search-report"),
            (["--validate-criteria", "--criteria-json", "{}"], ["--hidden"], "--hidden"),
            (["--snapshot-position-json", "{}"], ["--document-text"], "--document-text"),
            (["--extract", "missing.txt"], ["--content"], "--content"),
            (["--list-metadata-fields"], ["--progress"], "--progress"),
        ]:
            with self.subTest(action=args[0], conflicting=conflicting):
                code, lines, errors = run(args + conflicting)
                self.assertEqual((code, lines), (2, []))
                self.assertIn(f"{args[0]} kann nicht mit {option}", errors.splitlines()[-1])

    def test_explicit_default_values_are_neutral(self):
        expected = run(["--list-metadata-fields"])
        self.assertEqual(expected[0], 0)
        self.assertTrue(expected[1])
        self.assertEqual(run(["--list-metadata-fields", "--encoding", "utf-8", "--only", "both"]),
                         expected)

    def test_action_only_options_require_their_action(self):
        for option, required in [
            ("--results-root", "--filter-results"),
            ("--extract-root", "--extract"),
        ]:
            with self.subTest(option=option):
                code, lines, errors = run([option, ".", "query"])
                self.assertEqual((code, lines), (2, []))
                self.assertIn(f"{option} braucht {required}", errors.splitlines()[-1])
