"""Strukturierte Kriterien: beobachtbare Suchmenge, Belege und sichere Grenzen."""

import base64
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run


def leaf(identifier, field="name", operator="contains", value="report", **options):
    return dict(id=identifier, field=field, operator=operator, value=value, **options)


def group(identifier, operator, *children):
    return {"id": identifier, "op": operator, "children": list(children)}


def document(root):
    return {"schemaVersion": 1, "root": root}


def arguments(root):
    return ["--criteria-json", json.dumps(document(root), ensure_ascii=True)]


class CriteriaTruthTest(unittest.TestCase):
    def test_unknown_is_not_negated_into_a_hit(self):
        probe = SimpleNamespace(name="report", is_dir=True, relative_path=None)
        for field in ("extension", "relativePath"):
            with self.subTest(field=field):
                query = favenio.parse_criteria_query(document(
                    leaf("missing", field, "equals", "txt", negate=True)))
                self.assertIsNone(query.root.evaluate(probe))
                self.assertFalse(query.test(probe))
                self.assertIsNone(probe.criteria_evidence)

    def test_three_valued_truth_tables_in_both_orders(self):
        probe = SimpleNamespace(name="yes", is_dir=True, relative_path=None)
        values = {True: leaf("true", value="yes"),
                  False: leaf("false", value="no"),
                  None: leaf("unknown", field="relativePath", value="x")}
        for operator in ("and", "or"):
            for left in (True, False, None):
                for right in (True, False, None):
                    with self.subTest(operator=operator, left=left, right=right):
                        first, second = dict(values[left]), dict(values[right])
                        second["id"] += "2"
                        query = favenio.parse_criteria_query(document(
                            group("root", operator, first, second)))
                        if operator == "and":
                            expected = False if False in (left, right) else (
                                None if None in (left, right) else True)
                        else:
                            expected = True if True in (left, right) else (
                                None if None in (left, right) else False)
                        self.assertIs(query.root.evaluate(probe), expected)

    def test_failed_branches_do_not_leak_evidence(self):
        query = favenio.parse_criteria_query(document(group("root", "or",
            group("failed", "and", leaf("partial", value="yes"),
                  leaf("no", value="absent")),
            leaf("chosen", value="yes"), leaf("unread", value="yes"))))
        probe = SimpleNamespace(name="yes", is_dir=False, relative_path="yes")
        self.assertTrue(query.test(probe))
        self.assertEqual([item["id"] for item in probe.criteria_evidence], ["chosen"])

    def test_matching_uses_full_value_but_evidence_is_bounded(self):
        value = "a" * 300 + "NEEDLE"
        query = favenio.parse_criteria_query(document(leaf("long", value="NEEDLE")))
        probe = SimpleNamespace(name=value, is_dir=False, relative_path=value)
        self.assertTrue(query.test(probe))
        self.assertEqual(probe.criteria_evidence[0]["value"], "a" * 256)
        self.assertTrue(probe.criteria_evidence[0]["valueTruncated"])


class CriteriaSearchTest(TempTreeTest):
    def setUp(self):
        super().setUp()
        Path(self.root, "docs").mkdir()
        self.write("docs/report.txt", "alpha\nbeta\n")
        self.write("docs/report.md", "alpha\n")
        self.write("report.TXT", "beta\n")
        self.write("other.txt", "alpha\nbeta\n")
        self.write("plain", "no extension\n")
        Path(self.root, "folder.txt").mkdir()

    def records(self, root, *options):
        code, lines, err = run(["--json"] + arguments(root) + list(options) + [self.root])
        self.assertEqual(code, 0, err)
        return [json.loads(line) for line in lines]

    def relative(self, records):
        return sorted(os.path.relpath(item["path"], self.root) for item in records)

    def test_name_and_extension_with_nested_or(self):
        query = group("root", "and", leaf("name"), group("types", "or",
            leaf("txt", "extension", "equals", "txt"),
            leaf("md", "extension", "equals", "md")))
        records = self.records(query)
        self.assertEqual(self.relative(records),
                         ["docs/report.md", "docs/report.txt", "report.TXT"])
        for record in records:
            self.assertEqual(record["criteriaEvidence"][0]["id"], "name")
            self.assertEqual(len(record["criteriaEvidence"]), 2)
            self.assertNotIn("terms", record)

    def test_relative_paths_have_their_own_roots(self):
        query = leaf("path", "relativePath", "glob", "docs/*.txt")
        records = self.records(query)
        self.assertEqual(self.relative(records), ["docs/report.txt"])
        self.assertEqual(records[0]["criteriaEvidence"][0]["value"], "docs/report.txt")
        code, lines, err = run(["--json"] + arguments(query) +
                               [os.path.join(self.root, "docs")])
        self.assertEqual((code, lines, err), (1, [], ""))

    def test_explicit_file_is_its_own_named_root(self):
        target = os.path.join(self.root, "docs/report.txt")
        query = leaf("path", "relativePath", "equals", "report.txt")
        code, lines, err = run(["--json"] + arguments(query) + [target])
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(lines[0])["path"], target)

    def test_multiple_start_roots_are_promoted_without_a_pattern(self):
        first, second = Path(self.root, "one"), Path(self.root, "two")
        first.mkdir()
        second.mkdir()
        (first / "report.txt").write_text("x")
        (second / "report.txt").write_text("x")
        code, lines, err = run(["--json"] + arguments(
            leaf("path", "relativePath", "equals", "report.txt")) +
            [str(first), str(second)])
        self.assertEqual(code, 0, err)
        self.assertEqual({json.loads(line)["path"] for line in lines},
                         {str(first / "report.txt"), str(second / "report.txt")})

    def test_extension_is_case_preserving_and_not_available_for_directories(self):
        records = self.records(leaf("txt", "extension", "equals", "txt",
                                    caseSensitive=True))
        self.assertEqual(self.relative(records), ["docs/report.txt", "other.txt"])
        records = self.records(leaf("not-txt", "extension", "equals", "txt", negate=True))
        self.assertEqual(self.relative(records), ["docs/report.md", "plain"])
        self.assertTrue(all(item["criteriaEvidence"][0]["negated"] for item in records))
        records = self.records(leaf("empty", "extension", "equals", ""))
        self.assertEqual(self.relative(records), ["plain"])

    def test_operators_are_explicit_and_do_not_inherit_cli_switches(self):
        self.write("a*.txt", "x")
        self.write("abc.txt", "x")
        records = self.records(leaf("literal", value="a*"), "--regex", "--case-sensitive")
        self.assertEqual(self.relative(records), ["a*.txt"])
        code, lines, err = run(arguments(leaf("glob", operator="glob", value="report")) + [self.root])
        self.assertEqual((code, lines, err), (1, [], ""))
        records = self.records(leaf("regex", operator="regex", value=r"^report\.[a-z]+$"))
        self.assertEqual(self.relative(records), ["docs/report.md", "docs/report.txt", "report.TXT"])

    def test_legacy_content_terms_and_facts_combine_with_query(self):
        records = self.records(leaf("extension", "extension", "equals", "txt"),
                               "--content", "alpha", "--term", "beta", "--min-size", "5")
        self.assertEqual(self.relative(records), ["docs/report.txt", "other.txt"])
        for record in records:
            self.assertEqual(record["line"], 1)
            self.assertEqual(record["terms"],
                             [{"term": "alpha", "line": 1}, {"term": "beta", "line": 2}])

    def test_false_cheap_query_prevents_content_open(self):
        with mock.patch.object(favenio, "open_regular_file") as opened:
            code, lines, err = run(arguments(leaf("never", value="absent")) +
                                   ["--content", "alpha", self.root])
        self.assertEqual((code, lines, err), (1, [], ""))
        opened.assert_not_called()

    def test_query_and_old_name_search_have_same_hits(self):
        cases = [("report", {}, []), ("*.txt", {"operator": "glob"}, []),
                 ("report.TXT", {"operator": "equals", "caseSensitive": True},
                  ["--exact", "--case-sensitive"]),
                 (r"report\.[a-z]+$", {"operator": "regex"}, ["--regex"])]
        for pattern, options, legacy_options in cases:
            with self.subTest(pattern=pattern):
                old = run(["--json"] + legacy_options + [pattern, self.root])
                new = run(["--json"] + arguments(leaf("same", value=pattern, **options)) + [self.root])
                self.assertEqual(old[0], new[0])
                clean = []
                for line in new[1]:
                    record = json.loads(line)
                    record.pop("criteriaEvidence")
                    clean.append(record)
                self.assertEqual(sorted(map(json.dumps, clean)),
                                 sorted(json.dumps(json.loads(line)) for line in old[1]))

    def test_rejected_containers_do_not_stop_archive_descent_or_change_identity(self):
        nested = io.BytesIO()
        with zipfile.ZipFile(nested, "w") as archive:
            archive.writestr("special!/report.txt", "alpha")
        with zipfile.ZipFile(Path(self.root, "outer.zip"), "w") as archive:
            archive.writestr("nested.zip", nested.getvalue())
        query = group("root", "and", leaf("name"),
                      leaf("path", "relativePath", "equals", "special!/report.txt"))
        records = self.records(query, "--archive-depth", "2")
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["archiveMembers"], ["nested.zip", "special!/report.txt"])
        self.assertEqual(records[0]["criteriaEvidence"][-1]["value"], "special!/report.txt")
        old = run(["--json", "--archive-depth", "2", "report", self.root])
        matching = [json.loads(line) for line in old[1]
                    if json.loads(line)["archiveMembers"]]
        original = dict(records[0])
        original.pop("criteriaEvidence")
        self.assertEqual(matching, [original])

    def test_tar_dot_prefix_and_parent_components_are_not_confused(self):
        with tarfile.open(Path(self.root, "data.tar"), "w") as archive:
            for name in ("./docs/report.txt", "../docs/report.txt"):
                data = b"alpha"
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        records = self.records(leaf("path", "relativePath", "equals", "docs/report.txt"))
        archived = [record for record in records if record["archiveMembers"]]
        self.assertEqual([item["archiveMembers"] for item in archived], [["./docs/report.txt"]])

    def test_non_utf8_archive_names_keep_their_exact_identity(self):
        with tarfile.open(Path(self.root, "raw.tar"), "w", format=tarfile.USTAR_FORMAT,
                          encoding="utf-8", errors="surrogateescape") as archive:
            for byte in (b"\xfe", b"\xff"):
                info = tarfile.TarInfo("bad-" + byte.decode("utf-8", "surrogateescape") + "-report.txt")
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
        records = [item for item in self.records(leaf("raw", value="report"))
                   if item["archiveMembers"]]
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["path"], records[1]["path"])
        self.assertEqual({item["archiveMemberBytes"][0] for item in records},
                         {base64.b64encode(b"bad-" + byte + b"-report.txt").decode()
                          for byte in (b"\xfe", b"\xff")})
        self.assertEqual(records[0]["criteriaEvidence"][0]["value"], "bad-\ufffd-report.txt")

    def test_criteria_file_stdin_and_inline_are_equivalent(self):
        content = json.dumps(document(leaf("name")))
        config = Path(self.scratch.name, "criteria.json")
        config.write_text(content, encoding="utf-8")
        inline = run(["--json", "--criteria-json", content, self.root])
        from_file = run(["--json", "--criteria-file", str(config), self.root])
        with mock.patch.object(favenio.sys, "stdin", io.StringIO(content)):
            from_stdin = run(["--json", "--criteria-file", "-", self.root])
        self.assertEqual(inline, from_file)
        self.assertEqual(inline, from_stdin)
        actual = subprocess.run([sys.executable, favenio.__file__, "--json",
                                 "--criteria-file", "-", self.root],
                                input=content.encode(), capture_output=True, timeout=10)
        self.assertEqual(actual.returncode, inline[0], actual.stderr)
        self.assertEqual(actual.stdout.decode().splitlines(), inline[1])


class CriteriaValidationTest(TempTreeTest):
    def invalid(self, content, *options):
        with mock.patch.object(favenio.Search, "search_path") as walked:
            code, lines, err = run(["--criteria-json", content] + list(options) + [self.root])
        self.assertEqual((code, lines), (2, []), err)
        self.assertIn("favenio: fehler:", err)
        walked.assert_not_called()
        return err

    def test_invalid_schema_nodes_options_and_empty_groups(self):
        cases = [None, [], {}, {"schemaVersion": True, "root": leaf("a")},
                 {"schemaVersion": 4, "root": leaf("a")},
                 document(group("g", "and")), document(group("g", "xor", leaf("a"))),
                 document(group("g", "and", leaf("a"), leaf("a"))),
                 document(leaf("spaces not allowed")), document(leaf("a", field="futureField")),
                 document(leaf("a", operator="execute")), document(leaf("a", value="")),
                 document(leaf("a", value="\0")), document(leaf("a", value=17)),
                 document(leaf("a", caseSensitive=1)), document(leaf("a", negate="false")),
                 document(dict(leaf("a"), unexpected=True)),
                 document(leaf("a", operator="regex", value="["))]
        for case in cases:
            with self.subTest(case=case):
                self.invalid(json.dumps(case))

    def test_validation_does_not_search_and_uses_the_same_parser(self):
        with mock.patch.object(favenio.Search, "search_path") as walked:
            code, lines, err = run(arguments(leaf("valid")) + ["--validate-criteria"])
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(lines[0]),
                         {"type": "validation", "schemaVersion": 1, "valid": True})
        walked.assert_not_called()
        self.invalid(json.dumps(document(leaf("bad", operator="regex", value="["))),
                     "--validate-criteria")
        code, lines, err = run(["--validate-criteria"])
        self.assertEqual((code, lines), (2, []))
        self.assertIn("braucht --criteria-json", err)

    def test_duplicate_json_keys_and_malformed_json(self):
        self.assertIn("doppeltes JSON-Feld", self.invalid(
            '{"schemaVersion":1,"schemaVersion":1,"root":{}}'))
        for value in ("", "{", "[" * 1500 + "]" * 1500):
            with self.subTest(value=value[:10]):
                self.invalid(value)

    def test_depth_leaf_node_and_value_limits(self):
        nested = leaf("a")
        for n in range(favenio.MAX_CRITERIA_DEPTH):
            nested = group("g%d" % n, "and", nested)
        self.assertIn("Gruppentiefe", self.invalid(json.dumps(document(nested))))
        many = group("g", "or", *[leaf("a%d" % n)
                                    for n in range(favenio.MAX_CRITERIA_LEAVES + 1)])
        self.assertIn("Bedingungen", self.invalid(json.dumps(document(many))))
        nodes = group("g", "and", *[group("g%d" % n, "and", leaf("a%d" % n))
                                      for n in range(favenio.MAX_CRITERIA_LEAVES)])
        self.assertIn("Kriterienknoten", self.invalid(json.dumps(document(nodes))))
        self.invalid(json.dumps(document(leaf("long", value="ä" * 2049))))

    def test_input_byte_limit_is_enforced_for_file_and_inline(self):
        text = json.dumps(document(leaf("a"))) + " " * favenio.MAX_CRITERIA_BYTES
        self.assertIn("UTF-8-Bytes", self.invalid(text))
        config = Path(self.scratch.name, "huge.json")
        config.write_text(text)
        code, lines, err = run(["--criteria-file", str(config), self.root])
        self.assertEqual((code, lines), (2, []))
        self.assertIn("UTF-8-Bytes", err)

    def test_unreadable_nonregular_or_non_utf8_configuration_is_an_error(self):
        fifo = Path(self.scratch.name, "pipe.json")
        os.mkfifo(fifo)
        invalid = Path(self.scratch.name, "bytes.json")
        invalid.write_bytes(b"\xff")
        for target in (fifo, invalid, Path(self.scratch.name, "missing.json")):
            with self.subTest(target=target):
                code, lines, err = run(["--criteria-file", str(target), self.root])
                self.assertEqual((code, lines), (2, []))
                self.assertIn("favenio: fehler:", err)

    def test_structured_inputs_and_output_actions_are_exclusive(self):
        text = json.dumps(document(leaf("a")))
        self.invalid(text, "--criteria-file", "-")
        for action in (["--list-metadata-fields"], ["--extract", "x"],
                       ["--extract-json", "{}"], ["--snapshot-position-json", "{}"]):
            with self.subTest(action=action):
                self.invalid(text, *action)


if __name__ == "__main__":
    unittest.main()
