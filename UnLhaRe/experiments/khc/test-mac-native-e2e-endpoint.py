"""endpoint入力契約を実装より先に固定する。"""
import ast
from pathlib import Path
import types
import unittest

HERE = Path(__file__).resolve().parent
M = types.ModuleType('endpoint')
M.__file__ = str(HERE/'mac-native-e2e-endpoint.py')
exec(compile(ast.parse(Path(M.__file__).read_text(encoding='utf-8')), M.__file__, 'exec'), M.__dict__)


class Contracts(unittest.TestCase):
    def test_report_identity_matches_its_registration_and_terminal(self):
        value = {k: v for k, v in M.PINS.items() if k != 'source_sha256'}
        value.update(windows_run_id='a'*32, protocol_sha256='b'*64,
                     registration_sha256='c'*64, reason=M.REASON)
        M.validate_report_identity(value, 'a'*32, 'b'*64, 'c'*64)
        for key in ('windows_run_id', 'protocol_sha256', 'registration_sha256',
                    'cli_sha256', 'config_sha256', 'old_failed_build_sha256', 'e2e_script_sha256'):
            with self.assertRaises(M.Refusal):
                M.validate_report_identity(dict(value, **{key: 'wrong'}), 'a'*32, 'b'*64, 'c'*64)

    def test_protocol_accepts_only_fixed_correctness_scope(self):
        value = M.expected_protocol('a'*64)
        M.validate_protocol(value, 'a'*64)
        for change in ({'schema': True}, {'host': 'other'}, {'root': '/tmp'},
                       {'endpoint_sha256': 'b'*64}, {'source_sha256': 'b'*64},
                       {'windows_max_bytes': 9*1024**2}, {'remote_global_seconds': 301},
                       {'reason': 'retry'}, {'old_failed_build_sha256': 'b'*64}, {'extra': 1}):
            with self.assertRaises(M.Refusal):
                M.validate_protocol(dict(value, **change), 'a'*64)


if __name__ == '__main__':
    unittest.main()
