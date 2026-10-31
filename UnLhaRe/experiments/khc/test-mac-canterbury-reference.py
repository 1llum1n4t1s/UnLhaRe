"""Reference endpoint failures, fixed before implementation; no OS/codec work."""
import ast
import copy
import hashlib
import json
from pathlib import Path
import types
import unittest

HERE = Path(__file__).resolve().parent
m = types.ModuleType('reference')
m.__file__ = str(HERE/'mac-canterbury-reference.py')


class ReferenceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        exec(compile(ast.parse(Path(m.__file__).read_text(encoding='utf-8')), m.__file__, 'exec'), m.__dict__)

    def environment(self, ticks):
        return dict(schema=1, cpu_ticks=ticks, logical_cpus=14, thermal_state=0, ac_power=True)

    def metric(self):
        return dict(elapsed_ns=1000000000, user_seconds=.3, system_seconds=.2,
                    peak_rss_bytes=64*1024**2, cpu_per_wall=.5, normal_exit=True,
                    exit_code=0, signal=None, cpu_interval_percent=20.,
                    environment_before=self.environment([100,100,700,100]),
                    environment_after=self.environment([110,110,780,100]))

    def test_protocol_exact_types_and_pins(self):
        p = m.expected_protocol('a'*64, 'b'*64)
        m.validate_protocol(p, 'a'*64)
        for key, value in [('schema', True), ('remote_max_bytes', 1), ('warmups', 2),
                           ('endpoint_sha256', 'c'*64), ('sevenzip_sha256', 'd'*64),
                           ('orders', ['ABC']*6), ('extra', 1)]:
            changed = copy.deepcopy(p)
            changed[key] = value
            with self.assertRaises(m.Refusal):
                m.validate_protocol(changed, 'a'*64)

    def test_environment_zero_interval_wrap_and_types(self):
        a, b = self.environment([2**32-2,0,0,0]), self.environment([0,0,8,0])
        self.assertEqual(m.cpu_percent(a, b), 20)
        with self.assertRaises(m.Refusal):
            m.cpu_percent(a, a)
        for key, value in [('logical_cpus', 13), ('thermal_state', 4), ('ac_power', 1),
                           ('cpu_ticks', [0,0,0,-1]), ('schema', True)]:
            changed = self.environment([0]*4)
            changed[key] = value
            with self.assertRaises(m.Refusal):
                m.validate_environment(changed)

    def test_metric_pair_normality_environment_and_eligibility_are_distinct(self):
        value = self.metric()
        self.assertEqual(m.validate_metric(value, 60), (True, True))
        for key, bad in [('normal_exit', False), ('exit_code', 1), ('signal', 9),
                         ('elapsed_ns', 0), ('cpu_per_wall', float('nan')),
                         ('cpu_interval_percent', 15.), ('extra', 1)]:
            changed = copy.deepcopy(value)
            changed[key] = bad
            with self.assertRaises(m.Refusal):
                m.validate_metric(changed, 60)
        changed = copy.deepcopy(value)
        changed['peak_rss_bytes'] = 129*1024**2
        self.assertEqual(m.validate_metric(changed, 60), (True, False))
        changed = copy.deepcopy(value)
        changed['environment_after']['thermal_state'] = 1
        self.assertEqual(m.validate_metric(changed, 60), (False, True))

    def test_fixed_order_and_7zip_flags(self):
        schedule = m.schedule()
        self.assertEqual(len(schedule), 21)
        self.assertEqual([''.join(row[3] for row in schedule[i:i+3]) for i in range(0,21,3)],
                         ['ABC','ABC','BCA','CAB','ACB','CBA','BAC'])
        for letter in 'BC':
            args = m.codec_commands(letter, Path('/input'), Path('/archive'), Path('/decoded'))[0]
            for arg in ('-mmt=1','-ms=on','-mqs=on','-mtm=on','-mta=off','-mtc=off','-mx=9'):
                self.assertIn(arg, args)
        self.assertIn('-m0=LZMA2:d=8m:fb=273', m.codec_commands('B',Path('/i'),Path('/a'),Path('/d'))[0])
        self.assertIn('-m0=PPMd:mem=64m:o=16', m.codec_commands('C',Path('/i'),Path('/a'),Path('/d'))[0])

    def test_manifest_canonical_digest_and_reject_duplicate(self):
        entries = [dict(name='one.txt', bytes=3, sha256='a'*64)]
        self.assertEqual(m.manifest_digest(entries), hashlib.sha256(('one.txt\t3\t'+'a'*64+'\n').encode()).hexdigest())
        for value in [[dict(name='../bad', bytes=3, sha256='a'*64)], entries*2,
                      [dict(name='one.txt', bytes=True, sha256='a'*64)]]:
            with self.assertRaises(m.Refusal):
                m.manifest_digest(value)

    def test_zip_transport_prefix_is_exact_and_removed_once(self):
        self.assertEqual(m.zip_leaf('input/alice29.txt'), 'alice29.txt')
        for name in ('alice29.txt','other/alice29.txt','input/../alice29.txt',
                     'input/nested/alice29.txt','/input/alice29.txt','input/input/alice29.txt'):
            with self.assertRaises(m.Refusal):
                m.zip_leaf(name)

    def test_finalization_reserve_closes_new_work_before_campaign_deadline(self):
        self.assertEqual(m.FINALIZATION_RESERVE_SECONDS, 10)
        self.assertEqual(m.runtime_seconds_left(1689.5), .5)
        for elapsed in (1690, 1699, 1700):
            with self.assertRaises(m.Refusal):
                m.runtime_seconds_left(elapsed)
        self.assertEqual(m.finalized_outcome('completed-reference', None, 1699), ('completed-reference', None))
        status, error = m.finalized_outcome('completed-reference', None, 1700.001)
        self.assertEqual(status, 'failed')
        self.assertIn('deadline', error)
        status, error = m.finalized_outcome('stopped', 'eligibility', 1701)
        self.assertEqual(status, 'failed')
        self.assertIn('eligibility', error)


if __name__ == '__main__':
    unittest.main()
