"""Ausschlüsse müssen Lesen und Abstieg verhindern, nicht nur Treffer verbergen."""

import io
import json
import os
import tarfile
import unittest
from unittest import mock
import zipfile

from test_favenio import TempTreeTest, favenio, run


class ExclusionTest(TempTreeTest):
    def write_nested(self, relative, content="NEEDLE\n"):
        path = os.path.join(self.root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        return self.write(relative, content)

    def test_excluded_directory_is_never_scanned(self):
        blocked = os.path.join(self.root, "cache")
        self.write_nested("cache/deep/hidden.txt")
        visible = self.write_nested("keep/visible.txt")
        original_scandir = os.scandir
        visited = []

        def scandir(path):
            visited.append(os.fspath(path))
            self.assertNotEqual(os.fspath(path), blocked,
                                "Ein ausgeschlossener Ordner wurde betreten")
            return original_scandir(path)

        with mock.patch.object(favenio.os, "scandir", side_effect=scandir):
            code, lines, errors = run(["--content", "--exclude", "cache",
                                       "NEEDLE", self.root])
        self.assertEqual((code, lines, errors), (0, [visible + ":1"], ""))
        self.assertIn(os.path.join(self.root, "keep"), visited)

    def test_directory_exclusion_also_removes_the_directory_hit(self):
        self.write_nested("cache/data.txt")
        self.write_nested("keep/data.txt")
        code, lines, errors = run(["--only", "dirs", "--exclude", "cache",
                                   "*", self.root])
        self.assertEqual((code, lines, errors),
                         (0, [os.path.join(self.root, "keep")], ""))

    def test_excluded_file_is_not_opened_as_archive_or_as_raw_bytes(self):
        archive = self.write_nested("skip.zip")
        for options in ([], ["--no-archives"], ["--archive-depth", "0"]):
            with self.subTest(options=options), \
                    mock.patch.object(favenio.Search, "search_archive") as open_archive, \
                    mock.patch.object(favenio, "open_regular_file") as open_file:
                code, lines, errors = run(
                    options + ["--content", "--exclude", "*.zip", "NEEDLE", archive])
                self.assertEqual((code, lines, errors), (1, [], ""))
                open_archive.assert_not_called()
                open_file.assert_not_called()

    def test_plain_file_exclusion_prevents_the_content_reader(self):
        path = self.write_nested("skip.txt")
        with mock.patch.object(favenio, "open_regular_file") as open_file:
            self.assertEqual(run(["--content", "--exclude", "skip.txt",
                                  "NEEDLE", path]), (1, [], ""))
            open_file.assert_not_called()

    def test_patterns_are_repeatable_and_match_whole_case_sensitive_names(self):
        for name in ("cache", "mycache", "Cache.bin", "first.tmp", "second.bak"):
            self.write_nested(name)
        code, lines, errors = run(["--exclude", "cache", "--exclude", "cache.bin",
                                   "--exclude", "*.tmp",
                                   "--exclude", "*.bak", "*", self.root])
        self.assertEqual(code, 0)
        self.assertEqual(set(lines), {os.path.join(self.root, "mycache"),
                                     os.path.join(self.root, "Cache.bin")})
        self.assertEqual(errors, "")

    def test_exclusions_do_not_inherit_regex_or_search_case_options(self):
        path = self.write_nested("a.txt")
        for options in ([], ["--regex"], ["--exact"], ["--case-sensitive"]):
            with self.subTest(options=options):
                self.assertEqual(run(options + ["--exclude", "a.*", "a.txt", path]),
                                 (1, [], ""))

    def test_glob_question_mark_and_character_classes(self):
        for name in ("file1.txt", "file2.txt", "file3.txt", "note-a.log"):
            self.write_nested(name)
        self.assertEqual(run(["--exclude", "file[12].txt", "--exclude", "note-?.log",
                              "*", self.root]),
                         (0, [os.path.join(self.root, "file3.txt")], ""))

    def test_relative_roots_and_options_between_positionals(self):
        self.write_nested("one/cache/skip.txt")
        self.write_nested("one/keep.txt")
        self.assertEqual(run(["*.txt", "--exclude", "cache", "./one"], cwd=self.root),
                         (0, ["./one/keep.txt"], ""))

    def test_path_patterns_are_relative_to_each_start_directory(self):
        for root in ("one", "two"):
            self.write_nested(root + "/build/generated/skip.txt")
            self.write_nested(root + "/other/build/generated/keep.txt")
        code, lines, errors = run([
            "--exclude", "build/generated", "*.txt",
            os.path.join(self.root, "one"), os.path.join(self.root, "two"),
        ])
        self.assertEqual(code, 0)
        self.assertEqual(set(lines), {
            os.path.join(self.root, root, "other/build/generated/keep.txt")
            for root in ("one", "two")
        })
        self.assertEqual(errors, "")

    def test_component_patterns_apply_at_any_depth(self):
        self.write_nested("a/cache/deep/skip.txt")
        keep = self.write_nested("a/keep.txt")
        self.assertEqual(run(["--exclude", "cache", "*.txt", self.root]),
                         (0, [keep], ""))

    def test_star_in_path_pattern_crosses_directory_separators(self):
        self.write_nested("build/a/b/cache/skip.txt")
        keep = self.write_nested("build/a/b/keep.txt")
        self.assertEqual(run(["--exclude", "build/*/cache", "*.txt", self.root]),
                         (0, [keep], ""))

    def test_explicit_start_directory_is_the_root_even_when_its_name_matches(self):
        path = self.write_nested("cache/keep.txt")
        root = os.path.join(self.root, "cache")
        self.assertEqual(run(["--exclude", "cache", "*.txt", root]),
                         (0, [path], ""))

    def test_explicit_start_file_is_matched_by_its_basename(self):
        path = self.write_nested("folder/keep.txt")
        self.assertEqual(run(["--exclude", "folder/keep.txt", "*.txt", path]),
                         (0, [path], ""))
        self.assertEqual(run(["--exclude", "keep.txt", "*.txt", path]),
                         (1, [], ""))

    def test_no_implicit_exclusions_are_added(self):
        path = self.write_nested("cache/build/node_modules/keep.txt")
        self.assertEqual(run(["*.txt", self.root]), (0, [path], ""))

    def test_zip_implicit_parent_is_excluded_before_opening_the_member(self):
        path = os.path.join(self.root, "data.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("cache/deep/skip.txt", "NEEDLE\n")
            archive.writestr("keep.txt", "NEEDLE\n")
        original_open = zipfile.ZipFile.open
        opened = []

        def open_member(archive, member, *args, **kwargs):
            name = member.filename if isinstance(member, zipfile.ZipInfo) else member
            opened.append(name)
            self.assertNotEqual(name, "cache/deep/skip.txt")
            return original_open(archive, member, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, "open", new=open_member):
            code, lines, errors = run(["--content", "--exclude", "cache/deep",
                                       "NEEDLE", path])
        self.assertEqual((code, lines, errors), (0, [path + "!/keep.txt:1"], ""))
        self.assertIn("keep.txt", opened)

    def test_tar_dot_prefix_and_implicit_parent_are_excluded_before_extraction(self):
        path = os.path.join(self.root, "data.tar")
        with tarfile.open(path, "w") as archive:
            for name in ("./cache/deep/skip.txt", "./keep.txt"):
                member = tarfile.TarInfo(name)
                member.size = 7
                archive.addfile(member, io.BytesIO(b"NEEDLE\n"))
        original_extract = tarfile.TarFile.extractfile

        def extract_member(archive, member):
            self.assertNotEqual(member.name, "./cache/deep/skip.txt")
            return original_extract(archive, member)

        with mock.patch.object(tarfile.TarFile, "extractfile", new=extract_member):
            code, lines, errors = run(["--content", "--exclude", "cache/deep",
                                       "NEEDLE", path])
        self.assertEqual((code, lines, errors), (0, [path + "!/./keep.txt:1"], ""))

    def test_nested_archive_is_excluded_before_unpacking(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as archive:
            archive.writestr("deep.txt", "NEEDLE\n")
        path = os.path.join(self.root, "outer.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("folder/skip.zip", inner.getvalue())
            archive.writestr("keep.txt", "NEEDLE\n")
        original_open = zipfile.ZipFile.open

        def open_member(archive, member, *args, **kwargs):
            self.assertNotEqual(member.filename, "folder/skip.zip")
            return original_open(archive, member, *args, **kwargs)

        with mock.patch.object(zipfile.ZipFile, "open", new=open_member):
            code, lines, errors = run([
                "--content", "--archive-depth", "2", "--exclude", "folder/skip.zip",
                "NEEDLE", path,
            ])
        self.assertEqual((code, lines, errors), (0, [path + "!/keep.txt:1"], ""))

    def test_path_patterns_restart_at_each_archive_root(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as archive:
            archive.writestr("cache/deep/skip.txt", "NEEDLE\n")
            archive.writestr("keep.txt", "NEEDLE\n")
        path = os.path.join(self.root, "outer.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("folder/inner.zip", inner.getvalue())
            archive.writestr("cache/deep/skip.txt", "NEEDLE\n")
            archive.writestr("keep.txt", "NEEDLE\n")
        code, lines, errors = run([
            "--content", "--archive-depth", "2", "--exclude", "cache/deep",
            "NEEDLE", path,
        ])
        self.assertEqual(code, 0)
        self.assertEqual(set(lines), {path + "!/keep.txt:1",
                                     path + "!/folder/inner.zip!/keep.txt:1"})
        self.assertEqual(errors, "")

    def test_literal_archive_separator_is_part_of_the_member_path(self):
        path = os.path.join(self.root, "outer!.zip")
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("odd!/skip.txt", "NEEDLE\n")
            archive.writestr("odd!/keep.txt", "NEEDLE\n")
        code, lines, errors = run(["--json", "--content", "--exclude", "odd!/skip.txt",
                                   "NEEDLE", path])
        self.assertEqual(code, 0)
        self.assertEqual([json.loads(line)["archiveMembers"] for line in lines],
                         [["odd!/keep.txt"]])
        self.assertEqual(errors, "")

    def test_excluded_archive_member_never_opens_even_for_raw_fallback(self):
        search = favenio.Search(lambda text: True, True, 2, False,
                                exclusions=["cache/deep"])
        self.addCleanup(search.close)
        for name in ("cache/deep/fake.key", "cache/deep/inner.zip", "cache/deep/file.txt"):
            opener = mock.Mock(side_effect=AssertionError("Eintrag wurde geöffnet"))
            with self.subTest(name=name):
                search.visit_member(name, False, opener, "outer.zip", 2,
                                    "outer.zip", (), size=7)
                opener.assert_not_called()


if __name__ == "__main__":
    unittest.main()
