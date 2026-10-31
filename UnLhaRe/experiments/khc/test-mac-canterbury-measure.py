"""計測境界の失敗条件をcodec実行前に固定する。"""
import importlib.util
from pathlib import Path
import unittest
import os

spec = importlib.util.spec_from_file_location('measure', Path(__file__).with_name('mac-canterbury-measure.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class MeasurementTests(unittest.TestCase):
    def env(self, ticks):
        return dict(schema=1, cpu_ticks=ticks, logical_cpus=14, thermal_state=0, ac_power=True)

    def test_idle_and_busy(self):
        self.assertEqual(m.cpu_percent(self.env([1, 2, 3, 0]), self.env([2, 3, 11, 0])), 20)

    def test_uint32_wrap(self):
        self.assertEqual(m.cpu_percent(self.env([2**32-2, 0, 0, 0]), self.env([0, 0, 8, 0])), 20)

    def test_unobserved_interval_is_not_idle(self):
        with self.assertRaises(ValueError):
            m.cpu_percent(self.env([0]*4), self.env([0]*4))

    def test_shape_types_and_ranges(self):
        for key, bad in [('schema', True), ('logical_cpus', 13), ('ac_power', 1),
                         ('thermal_state', 4), ('cpu_ticks', [0, 0, 0, -1])]:
            value = self.env([0]*4)
            value[key] = bad
            with self.assertRaises(ValueError):
                m.validate_environment(value)

    @unittest.skipUnless(hasattr(os, 'WIFEXITED'), 'POSIX wait status is checked natively on Mac')
    def test_exit_and_signal_are_distinct(self):
        self.assertEqual(m.exit_state(0), (True, 0, None))
        self.assertEqual(m.exit_state(256), (True, 1, None))
        self.assertEqual(m.exit_state(9), (False, None, 9))


if __name__ == '__main__':
    unittest.main()
