"""実装前の純粋契約テスト。子プロセスや生成ファイルは作らない。"""
import importlib.util
import json
from pathlib import Path
import struct
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('native_e2e', Path(__file__).with_name('mac-native-e2e.py'))
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)


class Contracts(unittest.TestCase):
    def test_exact_config(self):
        e.validate_config(dict(e.CONFIG))
        for field, value in [('max_bytes', 9*1024**2), ('schema', True), ('max_entries', 97), ('other', 1)]:
            bad = dict(e.CONFIG, **{field: value})
            with self.subTest(field=field), self.assertRaises(e.Refusal):
                e.validate_config(bad)

    def registration(self):
        return dict(schema=1, task=e.CONFIG['task'], run=e.CONFIG['run'], root=e.CONFIG['root'],
                    config_sha256=e.CONFIG_SHA, oracle_sha256=e.ORACLE_SHA,
                    fixture_sha256=e.FIXTURE_SHA, cli_sha256=e.CLI_SHA, e2e_sha256=e.E2E_SHA,
                    windows_run_id='a'*32,
                    old_failed_build_sha256='1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7',
                    previous_e2e_sha256='60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c',
                    e2e_script_sha256='c'*64, protocol_sha256='d'*64,
                    reason='sandbox-ps-exec-denied-use-outer-group-proof')

    def test_registration(self):
        e.validate_registration(self.registration())
        for key, value in [('schema', True), ('root', '/tmp/other'), ('cli_sha256', 'A'*64),
                           ('config_sha256', '0'*64), ('oracle_sha256', '0'*64),
                           ('fixture_sha256', '0'*64), ('windows_run_id', 'invalid'),
                           ('old_failed_build_sha256', '0'*64), ('previous_e2e_sha256', '0'*64),
                           ('e2e_script_sha256', 'bad'), ('protocol_sha256', 'bad'),
                           ('reason', 'other'), ('extra', 1)]:
            with self.subTest(field=key), self.assertRaises(e.Refusal):
                e.validate_registration(dict(self.registration(), **{key: value}))

    def test_budget_boundaries(self):
        maximum = 8*1024**2-1024**2-65536
        e.admit_counts(maximum, 94, True)
        e.admit_counts(maximum, 95, False)
        for size, count, pending in [(maximum+1, 94, True), (maximum, 95, True),
                                     (maximum, 96, False), (-1, 0, True)]:
            with self.subTest(size=size, entries=count), self.assertRaises(e.Refusal):
                e.admit_counts(size, count, pending)

    def test_refusal_is_only_normal_one(self):
        oracle = [{'name': 'refusal', 'exit_code': 1}]
        e.validate_check('refusal', 1, 0, oracle)
        for code in [-9, -15, 0, 2, 127]:
            with self.subTest(code=code), self.assertRaises(e.Refusal):
                e.validate_check('refusal', code, 0, oracle)
        with self.assertRaises(e.Refusal):
            e.validate_check('other', 1, 0, oracle)

    def test_suffix_exact_metadata_offset(self):
        data = bytearray(42)
        struct.pack_into('<I', data, 20, 4)
        data[36:] = b'ABCDEF'
        self.assertEqual(e.archive_suffix(bytes(data)), b'ABCDEF')
        for bad in [b'', b'a'*31, b'a'*32]:
            with self.assertRaises(e.Refusal):
                e.archive_suffix(bad)

    def test_json_duplicate_rejected(self):
        self.assertEqual(e.load_json(b'{"schema":1}'), {'schema': 1})
        with self.assertRaises(e.Refusal):
            e.load_json(b'{"schema":1,"schema":1}')

    def test_oracle_paths(self):
        self.assertEqual(str(e.relative_path('api/legacy-1.khc')), 'api/legacy-1.khc')
        for value in ['../a', '/tmp/a', 'api/../a', 'api//a', 'api\\a', '.']:
            with self.subTest(path=value), self.assertRaises(e.Refusal):
                e.relative_path(value)

    def test_capture_preserves_failure_without_sandbox_signals(self):
        runner = e.Runner()
        runner.pulse = mock.Mock(side_effect=[None, e.Refusal('original accounting failure')])
        process = mock.Mock(pid=1234)
        process.poll.return_value = None
        process.stdout.fileno.return_value = 11
        process.stderr.fileno.return_value = 12
        process.kill.side_effect = PermissionError('sandbox denies signal')
        selector = mock.Mock()
        selector.get_map.return_value = {11: 1}
        with mock.patch.object(e.subprocess, 'Popen', return_value=process), \
                mock.patch.object(e.selectors, 'DefaultSelector', return_value=selector), \
                mock.patch.object(e.os, 'set_blocking'):
            with self.assertRaisesRegex(e.Refusal, 'original accounting failure'):
                runner.capture(['/not-executed'])
        process.kill.assert_not_called()
        process.terminate.assert_not_called()
        process.wait.assert_not_called()
        self.assertIn(process, runner.active)
        process.stdout.close.assert_called_once()
        process.stderr.close.assert_called_once()

    def test_direct_children_check_does_not_spawn_ps(self):
        runner = e.Runner()
        runner.capture = mock.Mock(side_effect=AssertionError('ps must not execute'))
        runner.tracked_children_absent()
        runner.capture.assert_not_called()

    def test_direct_children_still_active_reject_success(self):
        runner = e.Runner()
        runner.active.add(object())
        with self.assertRaises(e.Refusal):
            runner.tracked_children_absent()


if __name__ == '__main__':
    unittest.main()
