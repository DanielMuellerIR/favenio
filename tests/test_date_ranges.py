import contextlib
import datetime
import io
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import favenio as f


class DateRangesTest(unittest.TestCase):
    def resolve(self, preset, reference='2026-03-29T12:00:00Z', zone='Europe/Berlin'):
        resolver = f.DateRangeResolver(reference)
        entry = resolver.resolve(dict(kind='relative', preset=preset, timeZone=zone), 'modified')
        return entry, resolver.snapshot()

    def test_calendar_days_cross_dst(self):
        for reference, hours, week, month in [('2026-03-29T12:00:00Z', 23, 167, 743), ('2026-10-25T12:00:00Z', 25, 169, 745)]:
            for preset, expected in [('today', hours), ('last7CalendarDays', week), ('thisMonth', month)]:
                with self.subTest(reference=reference, preset=preset):
                    entry, proof = self.resolve(preset, reference)
                    end = f.file_timestamp(entry['upperExclusiveISO'])
                    self.assertEqual((end - entry['lowerEpoch']) / 3600, expected)
                    self.assertEqual(entry['upperEpoch'], math.nextafter(end, -math.inf))
                    self.assertEqual(f.file_timestamp_end(entry['upperISO']), entry['upperEpoch'])
                    self.assertEqual(proof['referenceTime'], f.file_timestamp(reference))

    def test_leap_month_year_and_local_day(self):
        entry, _ = self.resolve('thisMonth', '2024-02-29T12:00:00Z')
        self.assertEqual((f.file_timestamp(entry['upperExclusiveISO']) - entry['lowerEpoch']) / 3600, 696)
        entry, _ = self.resolve('thisMonth', '2026-12-31T12:00:00Z')
        self.assertEqual(entry['upperExclusiveISO'], '2026-12-31T23:00:00Z')
        entry, _ = self.resolve('today', '2026-03-29T22:30:00Z')
        self.assertEqual(entry['lowerISO'], '2026-03-29T22:00:00Z')

    def test_explicit_clock_zone_and_strict_shape(self):
        spec = dict(kind='relative', preset='today', timeZone='Europe/Berlin')
        for changed in [spec, dict(spec, timeZone='not/a/zone'), dict(spec, preset='last168Hours'), dict(spec, extra=1), dict(spec, timeZone=True)]:
            with self.subTest(spec=changed), self.assertRaises((ValueError, f.argparse.ArgumentTypeError)):
                f.DateRangeResolver().resolve(changed, 'test')
        for reference in ['', '2026-10-18', 'NaN', True]:
            with self.subTest(reference=reference), self.assertRaises((ValueError, TypeError, AttributeError, f.argparse.ArgumentTypeError)):
                f.DateRangeResolver(reference)
        with self.assertRaisesRegex(ValueError, 'doppeltes'):
            f.date_json('{"kind":"fixed","kind":"relative"}')

    def test_ambiguous_missing_local_clock_and_midnight(self):
        resolver = f.DateRangeResolver('2026-10-25T12:00:00Z')
        zone = resolver.zone('Europe/Berlin')
        for stamp in ['2026-03-29T02:30:00', '2026-10-25T02:30:00']:
            with self.subTest(stamp=stamp), self.assertRaises(ValueError):
                resolver.local_time(stamp, zone)
        first = resolver.local_time('2026-10-25T02:30:00', zone, 0)
        second = resolver.local_time('2026-10-25T02:30:00', zone, 1)
        self.assertEqual(second - first, 3600)
        for name, stamp in [('Pacific/Apia', '2011-12-30T00:00:00'), ('America/Sao_Paulo', '2018-11-04T00:00:00')]:
            with self.subTest(zone=name), self.assertRaises(ValueError):
                resolver.local_time(stamp, resolver.zone(name))

    def test_calendar_to_fixed_preserves_inclusive_second(self):
        resolver = f.DateRangeResolver()
        entry = resolver.resolve(dict(kind='calendar', fromLocal='2026-10-25T02:30:00', toLocal='2026-10-25T02:30:00', timeZone='Europe/Berlin', fold=1), 'preview')
        fixed = dict(kind='fixed', lower=entry['lowerISO'], upper=entry['upperISO'], timeZone='Europe/Berlin')
        again = resolver.resolve(fixed, 'fixed')
        self.assertEqual((entry['lowerEpoch'], entry['upperEpoch']), (again['lowerEpoch'], again['upperEpoch']))
        self.assertEqual(entry['lowerISO'], '2026-10-25T01:30:00Z')

    def test_new_date_contract_rejects_padding_but_raw_iso_retains_it(self):
        with self.assertRaisesRegex(ValueError, 'Rand-Leerraum'):
            f.DateRangeResolver(' 2026-03-29T12:00:00Z ')
        with self.assertRaisesRegex(ValueError, 'Rand-Leerraum'):
            f.DateRangeResolver().resolve(dict(kind='fixed', timeZone='UTC', lower=' 2026-01-01T00:00:00Z ', upper='2026-01-02T00:00:00Z'), 'fixed')
        self.assertEqual(f.file_timestamp(' 2026-01-01T00:00:00Z '), f.file_timestamp('2026-01-01T00:00:00Z'))

    def test_each_ambiguous_calendar_bound_can_choose_its_fold(self):
        entry = f.DateRangeResolver().resolve(dict(kind='calendar', timeZone='Europe/Berlin', fromLocal='2026-10-25T02:30:00', toLocal='2026-10-25T02:15:00', fromFold=0, toFold=1), 'preview')
        self.assertEqual(entry['lowerISO'], '2026-10-25T00:30:00Z')
        self.assertEqual(entry['upperISO'], '2026-10-25T01:15:00Z')
        self.assertEqual(entry['upperEpoch'], math.nextafter(f.file_timestamp('2026-10-25T01:15:01Z'), -math.inf))

    def test_raw_iso_precision_is_unchanged(self):
        for text, span in [('2026-01-01T00:00Z', 60), ('2026-01-01T00:00:00Z', 1)]:
            start = f.file_timestamp(text)
            self.assertEqual(f.file_timestamp_end(text), math.nextafter(start + span, -math.inf))
        self.assertEqual(f.file_timestamp_end('2026-01-01T00:00:00.1234Z'), f.file_timestamp('2026-01-01T00:00:00.1234Z'))

    def test_criteria_schema_and_negated_unknown_facts(self):
        node = dict(id='date', field='modified', operator='equals', value=dict(kind='relative', preset='today', timeZone='Europe/Berlin'), negate=True)
        with self.assertRaises(ValueError):
            f.parse_criteria_query(dict(schemaVersion=1, root=node), f.DateRangeResolver('2026-03-29T12:00:00Z'))
        query = f.parse_criteria_query(dict(schemaVersion=2, root=node), f.DateRangeResolver('2026-03-29T12:00:00Z'))
        record = dict(type='file', path='/absent/file', filesystemPath='/absent/file', archiveMembers=[], isDirectory=False)
        with mock.patch.object(f.os, 'stat', side_effect=AssertionError('source read')):
            self.assertFalse(query.test(f.KnownResultProbe(record)))

    def cli(self, *args):
        return subprocess.run([sys.executable, str(Path(f.__file__)), *args], capture_output=True, text=True, timeout=8)

    def test_relative_cli_real_files_exact_boundary_and_report(self):
        entry, _ = self.resolve('today')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, stamp in [('lower.txt', entry['lowerEpoch']), ('last.txt', entry['upperEpoch']), ('excluded.txt', f.file_timestamp(entry['upperExclusiveISO']))]:
                path = root/name; path.write_text(name); os.utime(path, (stamp, stamp))
            question = json.dumps(dict(schemaVersion=1, ranges=dict(modified=dict(kind='relative', preset='today', timeZone='Europe/Berlin'))))
            result = self.cli('--json', '--search-report', '--date-reference-time=2026-03-29T12:00:00Z', '--date-ranges-json='+question, '--', '', directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual({Path(r['filesystemPath']).name for r in records if r['type']=='file'}, {'lower.txt', 'last.txt'})
            proof = [r['dateResolution'] for r in records if r['type']=='searchReport'][-1]
            self.assertEqual(proof['entries'][0]['upperEpoch'], entry['upperEpoch'])
            conflict = self.cli('--date-reference-time=2026-03-29T12:00:00Z', '--date-ranges-json='+question, '--modified-from=2026-01-01T00:00Z', '--', '', directory)
            self.assertEqual(conflict.returncode, 2); self.assertEqual(conflict.stdout, '')

    def test_matching_fact_evidence_does_not_round_into_next_day(self):
        resolver = f.DateRangeResolver('2026-10-18T12:00:00Z')
        spec = dict(kind='relative', preset='today', timeZone='UTC')
        query = f.parse_criteria_query(dict(schemaVersion=2, root=dict(id='day', field='modified', operator='equals', value=spec)), resolver)
        upper = resolver.entries[0]['upperEpoch']
        probe = f.KnownResultProbe(dict(type='file', path='/missing/edge', filesystemPath='/missing/edge', archiveMembers=[], isDirectory=False, modified=upper))
        self.assertTrue(query.test(probe))
        self.assertEqual(probe.criteria_evidence[0]['value'], '2026-10-18T23:59:59.999999Z')
        self.assertEqual(probe.facts()[1], upper)
        value = '2026-10-18T23:00:00.1Z'
        point = f.parse_criteria_query(dict(schemaVersion=1, root=dict(id='point', field='modified', operator='equals', value=value)))
        probe = f.KnownResultProbe(dict(type='file', path='/missing/point', filesystemPath='/missing/point', archiveMembers=[], isDirectory=False, modified=f.file_timestamp(value)))
        self.assertTrue(point.test(probe)); self.assertEqual(probe.criteria_evidence[0]['value'], '2026-10-18T23:00:00.100000Z')

    def test_preview_rejects_search_dates_before_any_source_access(self):
        spec = dict(kind='relative', preset='today', timeZone='UTC')
        resolver = f.DateRangeResolver('2026-10-18T12:00:00Z'); resolver.resolve(spec, 'modified')
        with mock.patch.object(f, 'load_content_preview', side_effect=AssertionError('unexpected source access')) as load, contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as ended:
                f.main(['--date-reference-time=2026-10-18T12:00:00Z', '--date-resolution-json='+json.dumps(resolver.snapshot()), '--preview-request={}'])
        self.assertEqual(ended.exception.code, 2); self.assertEqual(output.getvalue(), ''); load.assert_not_called()

    def test_frozen_proof_reuses_bounds_without_timezone_resolution(self):
        spec = dict(kind='relative', preset='today', timeZone='Europe/Berlin')
        original = f.DateRangeResolver('2026-03-29T12:00:00Z')
        expected = original.resolve(spec, 'modified')
        saved = json.dumps(original.snapshot())
        with mock.patch.object(f, 'ZoneInfo', side_effect=AssertionError('historical zone lookup')):
            frozen = f.DateRangeResolver('2026-03-29T12:00:00Z', saved)
            self.assertEqual(frozen.resolve(spec, 'modified'), expected)
            frozen.finish()
        with self.assertRaisesRegex(ValueError, 'genau alle'):
            f.DateRangeResolver('2026-03-29T12:00:00Z', saved).finish()
        with self.assertRaises(ValueError):
            f.DateRangeResolver('2026-03-30T12:00:00Z', saved)
        changed = original.snapshot(); changed['entries'] = [dict(expected, upperEpoch=expected['lowerEpoch']+1)]
        with self.assertRaises(ValueError):
            f.DateRangeResolver('2026-03-29T12:00:00Z', json.dumps(changed))

    def test_helper_does_not_search_and_proof_survives_config_truncation(self):
        spec = dict(kind='relative', preset='today', timeZone='UTC')
        result = self.cli('--resolve-date-range='+json.dumps(spec), '--date-reference-time=2026-12-31T23:59:59Z')
        self.assertEqual(result.returncode, 0, result.stderr)
        proof = json.loads(result.stdout)['value']
        snapshot = f.SearchReport(dict(huge='x'*100000), proof).snapshot('finished')
        self.assertTrue(snapshot['configuration']['truncated'])
        self.assertEqual(snapshot['dateResolution'], proof)
        invalid = self.cli('--resolve-date-range='+json.dumps(spec), '--date-reference-time=2026-12-31T23:59:59Z', 'unexpected')
        self.assertEqual(invalid.returncode, 2); self.assertEqual(invalid.stdout, '')

    def test_view_filter_uses_the_explicit_clock_without_sources(self):
        entry, _ = self.resolve('today')
        node = dict(id='day', field='modified', operator='equals', value=dict(kind='relative', preset='today', timeZone='Europe/Berlin'))
        record = dict(type='file', path='/nonexistent/keep', filesystemPath='/nonexistent/keep', archiveMembers=[], isDirectory=False, modified=entry['lowerEpoch'])
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)/'known.jsonl'; source.write_text(json.dumps(record)+'\n')
            result = self.cli('--filter-results='+str(source), '--criteria-json='+json.dumps(dict(schemaVersion=2, root=node)), '--date-reference-time=2026-03-29T12:00:00Z')
            self.assertEqual(result.returncode, 0, result.stderr)
            records = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(records[0]['type'], 'dateResolution')
            self.assertEqual(records[1]['filesystemPath'], record['filesystemPath'])


class NativeDateRangesTest(unittest.TestCase):
    def check(self, mode):
        from swift_test_support import run_probe
        result = run_probe('date-ranges', mode)
        checks = json.loads(result.stdout)
        self.assertTrue(checks)
        self.assertTrue(all(checks.values()), checks)

    def test_model(self): self.check('model')
    def test_templates(self): self.check('templates')
    def test_proof(self): self.check('proof')
    def test_handoff(self): self.check('handoff')
    def test_editor(self): self.check('editor')
