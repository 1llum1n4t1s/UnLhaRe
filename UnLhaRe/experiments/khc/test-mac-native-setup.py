"""Pure, disk/network/process-free contract checks; written before implementation."""
import ast
import io
import json
from pathlib import Path, PurePosixPath
import tarfile
import types
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
M = types.ModuleType('mac_setup')
M.__file__ = str(HERE / 'mac-native-setup.py')
exec(compile(ast.parse(Path(M.__file__).read_text(encoding='utf-8')), M.__file__, 'exec'), M.__dict__)


class Contracts(unittest.TestCase):
    def test_cargo_hardlinks_require_all_aliases_in_one_cargo_tree(self):
        pair = [('a', (1, 2), 2, 10, 'cargo-target'),
                ('b', (1, 2), 2, 10, 'cargo-target')]
        M.validate_link_groups(pair)
        for rows in (pair[:1], pair + [('c', (1, 2), 2, 10, 'cargo-target')],
                     [pair[0], ('b', (1, 2), 2, 10, 'ordinary')],
                     [pair[0], ('b', (1, 2), 3, 10, 'cargo-target')],
                     [pair[0], ('b', (1, 2), 2, 11, 'cargo-target')],
                     [pair[0], ('b', (1, 2), 2, 10, 'cargo-home')]):
            with self.assertRaises(M.Refusal):
                M.validate_link_groups(rows)

    def test_installer_payload_comes_from_manifest_not_control_file(self):
        self.assertEqual(M.installed_file_names('file:bin/rustc\nfile:lib/libLLVM.dylib\n'),
                         {'bin/rustc', 'lib/libLLVM.dylib'})
        for text in ('file:../escape\n', 'file:/absolute\n', 'file:bin/a\nfile:bin/a\n',
                     'dir:bin\n', 'file:manifest.in\n', ''):
            with self.assertRaises(M.Refusal):
                M.installed_file_names(text)

    def test_std_finish_accepts_only_observed_component_boundary(self):
        identity = {'profile_sha256': 'a'*64, 'root': M.ROOT, 'uid': 501}
        prior = dict(identity, error='tar scan bound',
                     original_failure_sha256='fdb817119cf4d15488cba2c6c04b7207ff4ae3925b2b998288ff262c6f162e4f',
                     setup_sha256='47fe5ad1c88d0ae655e83fd29a431bb0f8055986351b03a0f986c8dff3d64c20')
        names = {'channel.toml', 'channel.sha256', 'channel-repair-1.toml',
                 'channel-repair-1.sha256', 'rustc.tar.xz', 'cargo.tar.xz', 'rust-std.tar.xz'}
        M.validate_std_finish(prior, identity, ['rustc', 'cargo'], names, [], False)
        for failure, components, files, stages, std in [
            (dict(prior, error='process failed'), ['rustc', 'cargo'], names, [], False),
            (dict(prior, uid=0), ['rustc', 'cargo'], names, [], False),
            (prior, ['rustc'], names, [], False),
            (prior, ['rustc', 'cargo'], names | {'extra'}, [], False),
            (prior, ['rustc', 'cargo'], names, ['rust-std'], False),
            (prior, ['rustc', 'cargo'], names, [], True),
        ]:
            with self.assertRaises(M.Refusal):
                M.validate_std_finish(failure, identity, components, files, stages, std)

    def test_generated_installer_option_declarations_are_supported(self):
        text = '#!/usr/bin/env bash\nvalopt prefix "/usr/local" "prefix"\nopt ldconfig 1 "Linux only"\n'
        M.validate_installer_text(text)
        for invalid in (text.replace('valopt prefix', 'valopt other'),
                        text.replace('opt ldconfig', 'opt other'),
                        text+'\nsudo touch /etc/unsafe\n'):
            with self.assertRaises(M.Refusal):
                M.validate_installer_text(invalid)

    def test_only_pre_execution_options_failure_can_be_repaired(self):
        identity = {'profile_sha256': 'a'*64, 'root': M.ROOT, 'uid': 501}
        failure = dict(identity, error='installer options unavailable')
        names = {'channel.toml', 'channel.sha256', 'rustc.tar.xz'}
        M.validate_options_repair(failure, identity, False, names)
        for bad, prefix, files in ((dict(failure, error='process failed'), False, names),
                                   (dict(failure, uid=502), False, names),
                                   (failure, True, names),
                                   (failure, False, names | {'cargo.tar.xz'})):
            with self.assertRaises(M.Refusal):
                M.validate_options_repair(bad, identity, prefix, files)

    def test_bootstrap_transfer_is_charged_inside_ordinary_cap(self):
        fs = types.SimpleNamespace(f_bavail=10*M.GIB, f_frsize=1)
        with mock.patch.object(M, 'counts', return_value=(12, 3)), \
                mock.patch.object(M.os, 'statvfs', return_value=fs, create=True):
            usage = M.admit(Path('/owned/root'))
        self.assertEqual(usage['bootstrap_reserved_bytes'], 1024*1024)
        self.assertEqual(usage['root_actual_ordinary_bytes'], 12)
        self.assertEqual(usage['ordinary'], 12+1024*1024)
        self.assertEqual(usage['total'], 15+1024*1024)

    def test_root_cannot_consume_the_bootstrap_reservation(self):
        fs = types.SimpleNamespace(f_bavail=10*M.GIB, f_frsize=1)
        with mock.patch.object(M, 'counts', return_value=(M.ORDINARY, 0)), \
                mock.patch.object(M.os, 'statvfs', return_value=fs, create=True):
            with self.assertRaises(M.Refusal):
                M.admit(Path('/owned/root'))

    def test_counts_fails_closed_on_root_and_walk_errors(self):
        good = types.SimpleNamespace(st_mode=M.stat.S_IFDIR | 0o700, st_uid=501)
        def unreadable(*args, **kwargs):
            kwargs['onerror'](PermissionError('unreadable subtree'))
            return iter(())
        with mock.patch.object(M.os, 'getuid', return_value=501, create=True), mock.patch.object(M.os, 'lstat', return_value=good), mock.patch.object(M.os, 'walk', unreadable):
            with self.assertRaises(M.Refusal):
                M.counts(Path('/owned/root'))
        for metadata in [types.SimpleNamespace(st_mode=M.stat.S_IFLNK | 0o700, st_uid=501),
                         types.SimpleNamespace(st_mode=M.stat.S_IFDIR | 0o700, st_uid=502)]:
            with mock.patch.object(M.os, 'getuid', return_value=501, create=True), mock.patch.object(M.os, 'lstat', return_value=metadata):
                with self.assertRaises(M.Refusal):
                    M.counts(Path('/owned/root'))
        with mock.patch.object(M.os, 'lstat', side_effect=FileNotFoundError('missing')):
            with self.assertRaises(M.Refusal):
                M.counts(Path('/owned/root'))

    def test_redirects_stay_with_original_provider(self):
        self.assertTrue(M.redirect_allowed('rust', 'https://static.rust-lang.org/dist/file'))
        self.assertTrue(M.redirect_allowed('sevenzip', 'https://release-assets.githubusercontent.com/file?sig=x'))
        self.assertTrue(M.redirect_allowed('sevenzip', 'https://github.com/ip7z/7zip/file'))
        for provider, url in [('rust', 'https://github.com/file'),
                              ('rust', 'https://release-assets.githubusercontent.com/file'),
                              ('sevenzip', 'https://static.rust-lang.org/file'),
                              ('sevenzip', 'http://github.com/file'),
                              ('sevenzip', 'https://github.com.evil/file'),
                              ('rust', 'https://static.rust-lang.org:444/file')]:
            self.assertFalse(M.redirect_allowed(provider, url))

    def test_only_known_deny_delete_acl_is_accepted(self):
        first = b'drwx------ 1 szk staff 0 Oct 26 00:00 /Users/szk\n'
        M.validate_acl_output(first)
        M.validate_acl_output(first + b' 0: group:everyone deny delete\n')
        for entry in [b' 0: group:everyone allow write\n',
                      b' 0: group:staff deny delete\n',
                      b' 0: group:everyone deny delete,write\n',
                      b' 0: group:everyone deny delete\n 1: group:everyone allow write\n']:
            with self.assertRaises(M.Refusal):
                M.validate_acl_output(first + entry)

    def test_budget_includes_next_peak_and_reserve(self):
        M.admit_values(100, 20, 30, 40, 6 * M.GIB)
        for ordinary, cargo, extra_o, extra_c, free in [
            (M.ORDINARY, 0, 1, 0, 10*M.GIB),
            (0, M.CARGO, 0, 1, 10*M.GIB),
            (0, 0, 0, 0, 5*M.GIB-1),
        ]:
            with self.assertRaises(M.Refusal):
                M.admit_values(ordinary, cargo, extra_o, extra_c, free)

    def test_environment_isolated(self):
        env = M.child_environment(PurePosixPath('/private/task'), {
            'RUSTC_WRAPPER': 'bad', 'RUSTC_WORKSPACE_WRAPPER': 'bad',
            'CARGO_BUILD_TARGET_DIR': 'bad', 'CARGO_ENCODED_RUSTFLAGS': 'bad',
            'HOME': '/Users/szk', 'PATH': '/evil',
        })
        self.assertEqual(env['CARGO_HOME'], '/private/task/cargo-home')
        self.assertNotIn('RUSTC_WRAPPER', env)
        self.assertNotIn('CARGO_BUILD_TARGET_DIR', env)
        self.assertEqual(env['PATH'], '/private/task/tools/rust/bin:/usr/bin:/bin:/usr/sbin:/sbin')

    def test_tar_rejects_escape_links_devices_duplicates_and_limits(self):
        for name, kind, link in [('../escape', tarfile.REGTYPE, ''),
                                 ('/escape', tarfile.REGTYPE, ''),
                                 ('ok', tarfile.SYMTYPE, '../../escape'),
                                 ('ok', tarfile.CHRTYPE, '')]:
            member = tarfile.TarInfo(name)
            member.type, member.linkname = kind, link
            with self.assertRaises(M.Refusal):
                M.validate_members([member], 100)
        one = tarfile.TarInfo('package/file')
        one.size = 101
        with self.assertRaises(M.Refusal):
            M.validate_members([one], 100)
        one.size = 1
        with self.assertRaises(M.Refusal):
            M.validate_members([one, one], 100)
        self.assertEqual(M.validate_members([one], 100), 1)

    def test_manifest_requires_exact_pins_and_no_duplicate_blocks(self):
        profile = json.loads((HERE / 'mac-native-tools.json').read_text(encoding='utf-8'))
        manifest = '\n'.join('[pkg.%s.target.aarch64-apple-darwin]\navailable = true\nxz_url = "%s"\nxz_hash = "%s"' %
                             (p['package'], p['url'], p['sha256']) for p in profile['rust'])
        M.validate_manifest(manifest, profile)
        with self.assertRaises(M.Refusal):
            M.validate_manifest(manifest.replace('23948a', '000000'), profile)
        with self.assertRaises(M.Refusal):
            M.validate_manifest(manifest + '\n' + manifest, profile)

    def test_profile_is_fixed(self):
        profile = json.loads((HERE / 'mac-native-tools.json').read_text(encoding='utf-8'))
        M.validate_profile(profile)
        profile['root'] += '-other'
        with self.assertRaises(M.Refusal):
            M.validate_profile(profile)


if __name__ == '__main__':
    unittest.main()
