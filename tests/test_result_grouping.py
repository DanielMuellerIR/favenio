"""Gruppenköpfe besitzen keine Dateiidentität; Projektion bewahrt Originaltreffer."""
import json
import unittest

from swift_test_support import run_probe


class ResultGroupingTests(unittest.TestCase):
    def probe(self, mode):
        result = run_probe('result-grouping', mode, timeout=20)
        report = json.loads(result.stdout)
        self.assertTrue(all(value for value in report.values() if isinstance(value, bool)), report)
        return report

    def test_all_group_modes_collapse_and_inverse_mapping(self):
        self.probe('roundtrip')

    def test_controller_selection_filter_stream_and_menu_validation(self):
        self.probe('controller')

    def test_group_count_stays_in_visible_width_after_scroll_and_resize(self):
        self.probe('header-layout')

    def test_long_archive_chain_has_bounded_scrollable_selectable_view(self):
        self.probe('chain-view')

    def test_archive_stages_raw_bytes_and_unicode_remain_distinct(self):
        self.probe('identity')

    def test_large_projection_keeps_every_hit_and_inverse(self):
        report = self.probe('large')
        print('RESULT GROUP PROJECTION: 100000 hits / 100 groups / seconds', report['seconds'])


if __name__ == '__main__':
    unittest.main()
