"""Größen-/Zeitfilter prüfen Fakten vor teuren Lesern und erhalten Archivabstieg."""

import gzip
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run


class FactFilterTest(TempTreeTest):
    STAMP = 1704067200.0
    ISO = "2024-01-01T00:00:00Z"

    def timed_file(self, name="data.txt", content="NEEDLE\n"):
        path = self.write(name, content)
        os.utime(path, (self.STAMP, self.STAMP))
        return path

    def test_size_bounds_are_inclusive_and_zero_is_known(self):
        empty = self.write("empty.txt", "")
        small = self.write("small.txt", "abc")
        self.write("large.txt", "abcd")
        self.assertEqual(run(["--min-size", "3", "--max-size", "3 B", "*.txt", self.root]),
                         (0, [small], ""))
        self.assertEqual(run(["--max-size", "0", "*.txt", self.root]), (0, [empty], ""))

    def test_supported_byte_units_and_invalid_values(self):
        for text, expected in (("0", 0), ("2B", 2), ("2 KiB", 2048),
                               ("2MiB", 2 * 1024 ** 2), ("2GiB", 2 * 1024 ** 3),
                               ("2TiB", 2 * 1024 ** 4)):
            with self.subTest(text=text):
                self.assertEqual(favenio.byte_size(text), expected)
        for text in ("-1", "1.5MiB", "1KB", "1_000", "nan", "inf", "", "+2"):
            with self.subTest(text=text):
                code, lines, errors = run(["--min-size", text, "*", self.root])
                self.assertEqual((code, lines), (2, []))
                self.assertIn("favenio: fehler:", errors)
                self.assertIn("--min-size", errors)

    def test_datetime_zone_equivalence_and_fractional_seconds(self):
        for text in (self.ISO, "2024-01-01T01:00+01:00", "2023-12-31T19:00:00-05:00",
                     "2024-01-01T05:45+05:45"):
            self.assertEqual(favenio.file_timestamp(text), self.STAMP)
        self.assertEqual(favenio.file_timestamp("2024-01-01T00:00:00.125Z"),
                         self.STAMP + 0.125)

    def test_invalid_dates_and_missing_zones_are_rejected(self):
        for text in ("2024-01-01", "2024-01-01T00:00:00", "2024-02-30T00:00:00Z",
                     "2024-01-01T00:00:00+25:00", "2024-01-01T00:00+01:99",
                     "2024-01-01T00:00-00:99", "2024-01-01T00:00+00:60", "nan", "inf"):
            with self.subTest(text=text):
                code, lines, errors = run(["--modified-from", text, "*", self.root])
                self.assertEqual((code, lines), (2, []))
                self.assertIn("favenio: fehler:", errors)
                self.assertIn("--modified-from", errors)

    def test_modified_bounds_are_inclusive_and_use_the_given_zone(self):
        path = self.timed_file()
        self.assertEqual(run(["--modified-from", self.ISO, "--modified-to",
                              "2024-01-01T01:00:00+01:00", "*", path]), (0, [path], ""))
        for option, stamp in (("--modified-from", "2024-01-01T00:00:01Z"),
                              ("--modified-to", "2023-12-31T23:59:59Z")):
            self.assertEqual(run([option, stamp, "*", path]), (1, [], ""))

    def test_created_bounds_are_inclusive_and_unknown_is_not_zero(self):
        path = self.timed_file()
        with mock.patch.object(favenio.Search, "file_facts", return_value=(7, self.STAMP, self.STAMP)):
            self.assertEqual(run(["--created-from", self.ISO, "--created-to", self.ISO,
                                  "*", path]), (0, [path], ""))
            self.assertEqual(run(["--created-to", "2023-12-31T23:59:59Z", "*", path]),
                             (1, [], ""))
        with mock.patch.object(favenio.Search, "file_facts", return_value=(7, self.STAMP, None)):
            self.assertEqual(run(["--created-from", "1960-01-01T00:00:00Z", "*", path]),
                             (1, [], ""))

    def test_reversed_bounds_fail_before_searching(self):
        pairs = (("--min-size", "2", "--max-size", "1"),
                 ("--modified-from", "2025-01-01T00:00Z", "--modified-to", self.ISO),
                 ("--created-from", "2025-01-01T00:00Z", "--created-to", self.ISO))
        for arguments in pairs:
            with self.subTest(arguments=arguments), mock.patch.object(favenio.Search, "search_path") as search:
                code, lines, errors = run(list(arguments) + ["*", self.root])
                self.assertEqual((code, lines), (2, []))
                self.assertIn("favenio: fehler:", errors)
                self.assertIn(arguments[0], errors)
                self.assertIn(arguments[2], errors)
                search.assert_not_called()

    def test_facts_are_read_once_for_all_filters_and_json_output(self):
        path = self.timed_file()
        with mock.patch.object(favenio.Search, "file_facts", return_value=(7, self.STAMP, self.STAMP)) as facts:
            code, lines, errors = run([
                "--json", "--min-size", "7", "--max-size", "7", "--modified-from", self.ISO,
                "--modified-to", self.ISO, "--created-from", self.ISO, "--created-to", self.ISO,
                "*", path,
            ])
            facts.assert_called_once_with(path)
        self.assertEqual((code, errors), (0, ""))
        record = json.loads(lines[0])
        self.assertEqual((record["size"], record["modified"], record["created"]),
                         (7, self.STAMP, self.STAMP))

    def test_rejected_facts_never_open_content_or_metadata(self):
        path = self.timed_file("image.jpg")
        for mode in ("--content", "--metadata"):
            filters = (("--min-size", "8"), ("--modified-from", "2025-01-01T00:00Z"),
                       ("--created-to", "1960-01-01T00:00Z"))
            for option, value in filters:
                with self.subTest(mode=mode, option=option), \
                        mock.patch.object(favenio, "find_exiftool", return_value="/fake/exiftool"), \
                        mock.patch.object(favenio, "open_regular_file") as opened, \
                        mock.patch.object(favenio.Search, "exiftool_stream") as metadata:
                    self.assertEqual(run([mode, option, value, "NEEDLE", path]),
                                     (1, [], ""))
                    opened.assert_not_called()
                    metadata.assert_not_called()

    def test_unknown_or_invalid_size_does_not_match_even_a_zero_bound(self):
        path = self.timed_file()
        for size in (None, -1, float("nan"), float("inf")):
            with self.subTest(size=size), \
                    mock.patch.object(favenio.Search, "file_facts", return_value=(size, self.STAMP, None)):
                self.assertEqual(run(["--max-size", "0", "*", path]), (1, [], ""))

    def test_name_rejection_does_not_fetch_file_facts(self):
        path = self.timed_file()
        with mock.patch.object(favenio.Search, "file_facts") as facts:
            self.assertEqual(run(["--min-size", "0", "missing", path]), (1, [], ""))
            facts.assert_not_called()

    def test_rejected_facts_precede_dimension_reader(self):
        path = self.timed_file("image.png")
        with mock.patch.object(favenio.FileProbe, "dimensions") as dimensions:
            self.assertEqual(run(["--min-size", "8", "--min-width", "1", "*", path]),
                             (1, [], ""))
            dimensions.assert_not_called()

    def test_date_filters_allow_directories_and_use_no_directory_size(self):
        folder = os.path.join(self.root, "folder")
        os.mkdir(folder)
        os.utime(folder, (self.STAMP, self.STAMP))
        code, lines, errors = run(["--json", "--only", "dirs", "--modified-from", self.ISO,
                                   "--modified-to", self.ISO, self.root])
        self.assertEqual((code, errors), (0, ""))
        self.assertEqual(len(lines), 1)
        self.assertTrue(json.loads(lines[0])["isDirectory"])
        self.assertNotIn("size", json.loads(lines[0]))
        self.assertEqual(run(["--only", "dirs", "--min-size", "0", self.root]),
                         (1, [], ""))

    def test_filter_only_accepts_multiple_start_paths_and_regex_without_pattern(self):
        first = self.timed_file("first.txt")
        second = self.timed_file("second.txt")
        code, lines, errors = run(["--regex", "--min-size", "7", "--max-size", "7", first, second])
        self.assertEqual((code, set(lines), errors), (0, {first, second}, ""))

    def test_filter_only_uses_each_directory_root(self):
        roots = [os.path.join(self.root, name) for name in ("one", "two")]
        for root in roots:
            os.mkdir(root)
            with open(os.path.join(root, "file.txt"), "w") as handle:
                handle.write("abc")
        code, lines, errors = run(["--min-size", "3", "--max-size", "3"] + roots)
        self.assertEqual((code, set(lines), errors),
                         (0, {os.path.join(root, "file.txt") for root in roots}, ""))

    def test_content_and_metadata_still_require_a_pattern_with_fact_filters(self):
        for option in ("--content", "--metadata"):
            code, lines, errors = run([option, "--min-size", "0", self.root])
            self.assertEqual((code, lines), (2, []))
            self.assertIn("brauchen ein PATTERN", errors)

    def test_unknown_size_in_single_compression_does_not_inflate(self):
        path = os.path.join(self.root, "data.txt.gz")
        with gzip.open(path, "wb") as archive:
            archive.write(b"NEEDLE\n")
        with mock.patch.object(favenio.gzip, "open") as inflate:
            self.assertEqual(run(["--min-size", "0", "*.txt", path]), (1, [], ""))
            inflate.assert_not_called()

    def test_known_zip_sizes_filter_without_opening_members(self):
        path = os.path.join(self.root, "data.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("empty.txt", "")
            archive.writestr("large.txt", "NEEDLE\n")
        with mock.patch.object(zipfile.ZipFile, "open") as open_member:
            self.assertEqual(run(["--max-size", "0", "*.txt", path]),
                             (0, [path + "!/empty.txt"], ""))
            open_member.assert_not_called()

    def test_unknown_bsdtar_size_does_not_start_extraction(self):
        # Der Katalog dieses Backends nennt keine Größen; sein Extraktions-
        # prozess darf nicht bloß zum Ermitteln einer Größe gestartet werden.
        path = self.write("data.7z", "fixture")
        search = favenio.Search(favenio.build_matcher("*.txt", False, False),
                                False, 1, False, min_size=0)
        self.addCleanup(search.close)
        with mock.patch.object(favenio, "bsdtar_list", return_value=(b"file.txt\n", b"", 0)), \
                mock.patch.object(favenio.subprocess, "Popen") as extract:
            search.walk_bsdtar(path, None, path, 1, path, ())
            self.assertFalse(search.found_any)
            extract.assert_not_called()

    def test_archive_container_size_does_not_prune_its_members(self):
        path = os.path.join(self.root, "data.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("small.txt", "abc")
        self.assertGreater(os.path.getsize(path), 3)
        self.assertEqual(run(["--max-size", "3", path]),
                         (0, [path + "!/small.txt"], ""))

    def test_nested_archive_container_size_does_not_prune_its_members(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as archive:
            archive.writestr("small.txt", "abc")
        path = os.path.join(self.root, "outer.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("inner.zip", inner.getvalue())
        self.assertEqual(run(["--archive-depth", "2", "--max-size", "3", path]),
                         (0, [path + "!/inner.zip!/small.txt"], ""))

    def test_archive_container_date_does_not_prune_members(self):
        path = os.path.join(self.root, "data.tar")
        with tarfile.open(path, "w") as archive:
            member = tarfile.TarInfo("file.txt")
            member.size = 3
            member.mtime = self.STAMP
            archive.addfile(member, io.BytesIO(b"abc"))
        os.utime(path, (self.STAMP + 86400, self.STAMP + 86400))
        self.assertEqual(run(["--modified-from", self.ISO, "--modified-to", self.ISO, path]),
                         (0, [path + "!/file.txt"], ""))

    def test_tar_directories_keep_known_modified_but_have_unknown_created(self):
        path = os.path.join(self.root, "data.tar")
        with tarfile.open(path, "w") as archive:
            folder = tarfile.TarInfo("folder")
            folder.type = tarfile.DIRTYPE
            folder.mtime = self.STAMP
            archive.addfile(folder)
        self.assertEqual(run(["--only", "dirs", "--modified-from", self.ISO,
                              "--modified-to", self.ISO, path]),
                         (0, [path + "!/folder"], ""))
        self.assertEqual(run(["--only", "dirs", "--created-from", "1960-01-01T00:00Z", path]),
                         (1, [], ""))

    def test_nonfinite_pax_timestamps_never_pass_requested_date_filters(self):
        path = os.path.join(self.root, "nonfinite.tar")
        with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as archive:
            for index, value in enumerate(("nan", "inf", "-inf")):
                member = tarfile.TarInfo("file%d.txt" % index)
                member.size = 7
                member.pax_headers = {"mtime": value}
                archive.addfile(member, io.BytesIO(b"NEEDLE\n"))
        with mock.patch.object(tarfile.TarFile, "extractfile") as extracted:
            self.assertEqual(run(["--content", "--modified-from", self.ISO, "NEEDLE", path]),
                             (1, [], ""))
            extracted.assert_not_called()

    def test_real_cli_validation_errors_have_the_shared_diagnostics_prefix(self):
        cases = (("--min-size", "1.5MiB"),
                 ("--modified-from", "2025-01-01T00:00Z", "--modified-to", self.ISO))
        for arguments in cases:
            with self.subTest(arguments=arguments):
                process = subprocess.run([
                    sys.executable, str(Path(favenio.__file__).resolve()),
                ] + list(arguments) + ["*", self.root], capture_output=True, text=True)
                self.assertEqual((process.returncode, process.stdout), (2, ""))
                self.assertTrue(any(line.startswith("favenio: fehler: ") and arguments[0] in line
                                    for line in process.stderr.splitlines()))


if __name__ == "__main__":
    unittest.main()
