"""Source admission checks, written before the native build controller."""
import ast
import json
from pathlib import Path
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
M = types.ModuleType('mac_build')
M.__file__ = str(HERE/'mac-native-build.py')
exec(compile(ast.parse(Path(M.__file__).read_text(encoding='utf-8')), M.__file__, 'exec'), M.__dict__)


class Contracts(unittest.TestCase):
    def test_clean_build_log_checks_warnings_before_truncation(self):
        M.validate_clean_build_output('Compiling unlhare v1.0.4\nFinished', True)
        for output, fresh in [('warning: linker\n'+'x'*9000, False),
                              ('xcrun: error: outside cache denied\nFinished', False),
                              ('warning: stripping failed\nCompiling unlhare v1', True),
                              ('Finished', True)]:
            with self.assertRaises(M.Refusal):
                M.validate_clean_build_output(output, fresh)

    def test_amendment_is_only_for_the_unstarted_corrective_build(self):
        environment = json.loads((HERE/'mac-native-environment.json').read_text(encoding='utf-8'))
        spec = {'schema': 1, 'protocol': 'khc-mac-native-build-amendment-v1',
                'task': 'goal-restore-20261019', 'host': 'm3mb14', 'root': M.ROOT.as_posix(), 'stage': 'build',
                'source_sha256': environment['source_sha256'],
                'old_controller_sha256': environment['old_controller_sha256'],
                'new_controller_sha256': 'b'*64,
                'old_check_terminal_sha256': environment['previous_terminal_sha256']['check'],
                'environment_sha256': '4febd21b0ab814a62efb12c006c91ab5c9d4776cdd5c3d8a03e7f8c3213769e3',
                'cc_shim_sha256': environment['cc_shim_sha256'],
                'reason': 'sandboxed-xcrun-cache-and-rust-objcopy-rpath'}
        M.validate_amendment(spec, 'b'*64, environment)
        for change in ({'schema': True}, {'stage': 'check'}, {'source_sha256': 'c'*64},
                       {'new_controller_sha256': 'c'*64}, {'old_check_terminal_sha256': 'c'*64},
                       {'cc_shim_sha256': 'c'*64}, {'environment_sha256': 'c'*64},
                       {'reason': 'retry'}, {'extra': True}):
            with self.assertRaises(M.Refusal):
                M.validate_amendment(dict(spec, **change), 'b'*64, environment)

    def test_cargo_home_configuration_is_rejected(self):
        home = Path('/owned/task/cargo-home')
        with mock.patch.object(Path, 'exists', autospec=True,
                               side_effect=lambda p: p == home/'config.toml'), \
                mock.patch.object(Path, 'is_symlink', return_value=False):
            with self.assertRaises(M.Refusal):
                M.reject_cargo_config(Path('/owned/task/source'), home)

    def test_source_manifest_requires_complete_build_inputs(self):
        names = ['Cargo.toml', 'Cargo.lock', 'build.rs', 'src/lib.rs', 'src/main.rs',
                 'examples/khc_spatial_mdl_e2e.rs', 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_LICENSES.txt']
        records = [{'path': name, 'bytes': 1, 'sha256': 'a'*64} for name in names]
        self.assertEqual(set(M.validate_source_manifest(records)), set(names))
        for bad in (records[:-1], records+[records[0]],
                    records+[dict(records[0], path='../escape')],
                    records+[dict(records[0], path='.cargo/config.toml')],
                    records+[dict(records[0], path='src/LIB.rs')],
                    records+[dict(records[0], path='src/../escape.rs')],
                    records+[dict(records[0], path='src/link.rs', bytes=-1)],
                    records+[dict(records[0], path='src/link.rs', sha256='bad')]):
            with self.assertRaises(M.Refusal):
                M.validate_source_manifest(bad)


if __name__ == '__main__':
    unittest.main()
