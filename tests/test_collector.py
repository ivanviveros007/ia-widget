import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('quota', Path(__file__).parents[1] / 'collector/quota_service.py')
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


class CollectorTests(unittest.TestCase):
    def test_missing_and_invalid_percent_never_becomes_zero(self):
        for value in [None, True, '0', -1, 101, float('nan'), float('inf')]:
            self.assertIsNone(q.window('x', value))
        self.assertEqual(q.window('x', 0)['usedPercent'], 0)

    def test_iso_reset_preserves_timezone(self):
        a = q.window('x', 100, '2026-11-05T01:19:59+00:00')
        b = q.window('x', 100, '2026-11-04T22:19:59-03:00')
        self.assertEqual(a['resetsAt'], b['resetsAt'])

    def test_export_strips_account_secrets(self):
        value = q.initial_snapshot()
        value['accessToken'] = 'never-export'
        value['providers'][0]['cookie'] = 'never-export'
        value['providers'][0]['windows'] = [{'label': 'x', 'usedPercent': 5, 'resetsAt': None, 'secret': 'never-export'}]
        self.assertNotIn('never-export', str(q.validate_snapshot(value)))

    def test_gemini_fraction_and_zero_are_valid(self):
        data = {'data': {'viewer': {'rpcs': {'getUsageInfo': {'pools': [
            {'poolType': 'GXU_FIVE_HOURLY', 'percentageUsed': 0, 'gxu': {'windowRefreshesAt': '2026-11-05T00:00:00Z'}},
            {'poolType': 'GXU_WEEKLY', 'percentageUsed': .38}
        ]}}}}}
        windows = q.gemini_from_web(data)['windows']
        self.assertEqual([w['usedPercent'] for w in windows], [0, 38])

    def test_gemini_missing_usage_is_not_fabricated(self):
        with self.assertRaises(ValueError): q.gemini_from_web({})

    def test_gemini_graphql_array_response(self):
        response = [{'data': {'unrelated': True}}, {'data': {'viewer': {'rpcs': {'getUsageInfo': {
            'pools': [{'poolType': 'GXU_WEEKLY', 'percentageUsed': .5, 'gxu': {'windowRefreshesAt': '2026-11-05T00:00:00Z'}}]
        }}}}}]
        result = q.gemini_from_web(response)
        self.assertEqual(result['windows'][0]['usedPercent'], 50)
        self.assertIsNotNone(result['windows'][0]['resetsAt'])

    def test_chat_counters_preserve_units_and_real_zero(self):
        raw = [{'label': 'GPT chat', 'remaining': 0, 'resetsAt': '2026-11-05T03:00:00Z'},
               {'label': 'Missing', 'remaining': None}, {'label': 'Invalid', 'remaining': True}]
        result = q.normalize_chat_allowances(raw)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['remaining'], 0)
        self.assertNotIn('usedPercent', result[0])
        self.assertIsNotNone(result[0]['resetsAt'])

    def test_chat_export_keeps_counts_and_strips_extra_fields(self):
        snapshot = q.initial_snapshot()
        entry = snapshot['providers'][1]
        entry['allowances'] = [{'label': 'GPT chat', 'remaining': 80, 'cookie': 'never-export'}]
        exported = q.validate_snapshot(snapshot)['providers'][1]
        self.assertEqual(exported['allowances'][0]['remaining'], 80)
        self.assertNotIn('never-export', str(exported))

    def test_failed_collection_preserves_last_measurement_age(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(q, 'STATE', Path(temp)):
            snapshot = q.initial_snapshot()
            snapshot['providers'][0] = q.provider('codex', [q.window('5 horas', 95)], updated='ignored')
            snapshot['providers'][0]['updatedAt'] = 100
            q.atomic_json(q.STATE / 'snapshot.json', snapshot)
            with patch.object(q, 'codex_usage', return_value=q.unavailable('codex', 'offline')), \
                 patch.object(q, 'claude_usage', return_value=q.unavailable('claude', 'offline')):
                q.collect()
            entry = q.read_snapshot()['providers'][0]
            self.assertEqual(entry['status'], 'stale')
            self.assertEqual(entry['updatedAt'], 100)
            self.assertEqual(entry['windows'][0]['usedPercent'], 95)


if __name__ == '__main__': unittest.main()
