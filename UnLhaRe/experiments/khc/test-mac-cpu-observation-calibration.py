"""CPU観測診断の失敗条件を先に固定する。実コーデックは実行しない。"""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('calibration', Path(__file__).with_name('mac-cpu-observation-calibration.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class CalibrationTests(unittest.TestCase):
    def env(self, ticks):
        return dict(schema=1, cpu_ticks=ticks, logical_cpus=14, thermal_state=0, ac_power=True)

    def test_schedule_balances_all_modes_and_positions(self):
        rows = m.schedule()
        self.assertEqual(len(rows), 36)
        self.assertEqual(len(set(rows)), 36)
        for mode in m.MODES:
            self.assertEqual(sorted(p for _, p, v in rows if v == mode), list(range(6)))

    def test_zero_ticks_are_unobservable_not_zero_percent(self):
        value = m.cpu_sample(self.env([1,2,3,4]), self.env([1,2,3,4]))
        self.assertEqual(value['observation_status'], 'unobservable-zero-ticks')
        self.assertIsNone(value['cpu_interval_percent'])
        self.assertIsNone(value['tick_percentage_point_quantum'])

    def test_wrap_and_quantum(self):
        value = m.cpu_sample(self.env([2**32-2,0,0,0]), self.env([0,0,8,0]))
        self.assertEqual(value['cpu_tick_deltas'], [2,0,8,0])
        self.assertEqual(value['cpu_interval_percent'], 20)
        self.assertEqual(value['tick_percentage_point_quantum'], 10)

    def test_environment_types_and_ranges(self):
        for key, value in [('schema', True), ('logical_cpus', 13), ('ac_power', 1),
                           ('cpu_ticks', [-1,0,0,0]), ('thermal_state', 4)]:
            bad = self.env([0]*4)
            bad[key] = value
            with self.assertRaises(ValueError):
                m.cpu_sample(bad, self.env([1]*4))

    def test_observation_brackets(self):
        self.assertEqual(m.brackets(10,20,100,120),
                         dict(before_call_ns=10, after_call_ns=20, interval_lower_ns=80, interval_upper_ns=110))
        with self.assertRaises(ValueError):
            m.brackets(10,20,19,30)

    def test_only_version_or_true_commands(self):
        self.assertEqual(m.command_for('true'), ['/usr/bin/true'])
        for mode in ('version','version-window-1s'):
            self.assertEqual(m.command_for(mode), [str(m.CLI), '--version'])
        self.assertIsNone(m.command_for('idle-1s'))
        with self.assertRaises(ValueError):
            m.command_for('encode')

    def test_final_counts_failure_is_retained_without_retry(self):
        with patch.object(m, 'local_counts', side_effect=ValueError('x'*3000)) as counter:
            value = m.count_snapshot()
        counter.assert_called_once_with()
        self.assertIsNone(value['counts'])
        self.assertEqual(len(value['counts_error']), 2048)

    def test_journal_reservation_is_in_total_quota(self):
        value = m.quota_counts(512*1024, 8)
        self.assertEqual(value['journal_reserved_bytes'], 2*65536+16384)
        self.assertLessEqual(value['charged_bytes'], 1048576)
        self.assertLessEqual(value['charged_entries'], 16)
        with self.assertRaises(ValueError):
            m.quota_counts(512*1024+1, 8)

    def test_runtime_leaves_cleanup_margin(self):
        self.assertEqual(m.remaining_runtime(1000, 1099), 1)
        with self.assertRaises(ValueError):
            m.remaining_runtime(1000, 1100)


if __name__ == '__main__':
    unittest.main()
