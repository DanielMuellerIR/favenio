import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import favenio


class SnapshotPositionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "blatt.txt"

    def query(self, data, **options):
        self.path.write_bytes(data)
        record = dict(path=str(self.path), mode="content", pattern="needle", terms=[],
                      regex=False, caseSensitive=True, exact=False, literalWildcards=False)
        record.update(options)
        return record, favenio.snapshot_position(record)

    def test_utf16_offsets_include_non_bmp_and_crlf(self):
        data = "😀 davor\r\nprä needle é\r\nnachher".encode()
        _, value = self.query(data)
        self.assertEqual((value["line"], value["location"], value["length"]), (2, 10, 13))
        self.assertEqual(value["sha256"], hashlib.sha256(data).hexdigest())

    def test_each_python_line_separator_has_an_exact_position(self):
        for separator in ("\n", "\r\n", "\r", "\v", "\f", "\x1c", "\x1d", "\x1e", "\x85", "\u2028", "\u2029"):
            with self.subTest(separator=repr(separator)):
                _, value = self.query(("vor" + separator + "needle" + separator).encode())
                self.assertEqual(value["line"], 2)
                self.assertEqual(value["location"], 3 + len(separator))
                self.assertEqual(value["length"], 6)

    def test_utf8_bom_is_hashed_but_not_counted_in_editor(self):
        _, first = self.query(b"\xef\xbb\xbfneedle\n")
        self.assertEqual((first["location"], first["length"]), (0, 6))
        _, second = self.query(b"\xef\xbb\xbfvor\nneedle")
        self.assertEqual((second["location"], second["length"]), (4, 6))

    def test_core_regex_exact_and_terms_across_lines_remain_in_force(self):
        _, value = self.query(b"other\nneedle\n", terms=["other"], regex=True, exact=True)
        self.assertEqual(value["line"], 2)
        _, value = self.query(b"other\nneedle\n", pattern="", terms=["needle", "other"])
        self.assertEqual(value["line"], 2)
        with self.assertRaisesRegex(ValueError, "passt nicht mehr"):
            self.query(b"prefix needle\n", exact=True)
        with self.assertRaisesRegex(ValueError, "passt nicht mehr"):
            self.query(b"needle\n", terms=["missing"])

    def test_current_position_is_recomputed_after_source_change(self):
        _, first = self.query(b"needle\n")
        _, later = self.query(b"new\nneedle\n")
        self.assertNotEqual(first["sha256"], later["sha256"])
        self.assertEqual(later["location"], 4)
        with self.assertRaisesRegex(ValueError, "passt nicht mehr"):
            self.query(b"no longer present\n")

    def test_unverified_decoder_and_non_content_hits_never_guess(self):
        for data, options in [(b"invalid\xffneedle", {}), (b"needle\0", {}), (b"needle", {"mode": "name"}),
                              (b"needle", {"mode": "metadata"}), (b"\xff\xfeneedle", {})]:
            with self.subTest(data=data, options=options):
                _, value = self.query(data, **options)
                self.assertEqual(value["positionBinding"], "unboundHit")
                self.assertEqual((value["location"], value["length"]), (0, 0))

    def test_size_bound_and_fifo_do_not_read_unbounded_input(self):
        with self.assertRaisesRegex(ValueError, "262144"):
            self.query(b"x" * 262145)
        fifo = Path(self.directory.name) / "pipe"
        os.mkfifo(fifo)
        record, _ = self.query(b"needle")
        record["path"] = str(fifo)
        with self.assertRaises(favenio.ArchiveReadError):
            favenio.snapshot_position(record)

    def test_schema_rejects_unknown_keys_boolean_substitutes_and_missing_terms(self):
        record, _ = self.query(b"needle")
        for update in ({"surprise": 1}, {"regex": 1}, {"terms": "needle"}, {"terms": [None]}, {"mode": "other"}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                favenio.snapshot_position(dict(record, **update))

    def test_cli_stdout_is_json_and_failure_is_exit_two(self):
        record, expected = self.query(b"before\nneedle\n")
        command = [sys.executable, str(Path(favenio.__file__)), "--snapshot-position-json"]
        success = subprocess.run(command + [json.dumps(record)], capture_output=True, timeout=5)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(json.loads(success.stdout), expected)
        self.path.write_bytes(b"gone")
        failed = subprocess.run(command + [json.dumps(record)], capture_output=True, timeout=5)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(failed.stdout, b"")
        self.assertIn(b"favenio: fehler:", failed.stderr)
        invalid = subprocess.run(command + [json.dumps(dict(record, pattern="[", regex=True))],
                                 capture_output=True, timeout=5)
        self.assertEqual(invalid.returncode, 2)
        self.assertEqual(invalid.stdout, b"")
        self.assertIn(b"favenio: fehler:", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
