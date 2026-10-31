#!/usr/bin/env python3
"""完了済み旧3工程の証拠を保持し、未開始buildだけ修正環境で実行する。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import sys
import zipfile

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
SETUP_SHA256 = '9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
E2E_SCRIPT_SHA256 = '60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c'
E2E_CONFIG_SHA256 = '40c47b77f8400112a963d4efb26994bf97fb0ca3690943035071045d6d8ecbe3'
E2E_ORACLE_SHA256 = '343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75'
FIXTURE_SHA256 = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
ENVIRONMENT_SHA256 = '4febd21b0ab814a62efb12c006c91ab5c9d4776cdd5c3d8a03e7f8c3213769e3'
MAX_SOURCE = 8*1024**2


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_source_manifest(records):
    require(isinstance(records, list) and 0 < len(records) <= 200, 'source record bound')
    names, folded, total = {}, set(), 0
    root_files = {'Cargo.toml', 'Cargo.lock', 'build.rs', 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_LICENSES.txt'}
    for record in records:
        require(set(record) == {'path', 'bytes', 'sha256'}, 'source record shape')
        name, length, sha = record['path'], record['bytes'], record['sha256']
        require(isinstance(name, str) and 0 < len(name) <= 250, 'source path bound')
        path = PurePosixPath(name)
        require(str(path) == name and not path.is_absolute() and '..' not in path.parts and
                '\\' not in name and name.casefold() not in folded, 'source path/duplicate')
        require(name in root_files or (path.parts[0] in ('src', 'examples') and name.endswith('.rs')),
                'unexpected build input')
        require(type(length) is int and 0 <= length <= MAX_SOURCE and isinstance(sha, str) and
                re.fullmatch('[0-9a-f]{64}', sha) is not None, 'source length/hash')
        names[name] = record
        folded.add(name.casefold())
        total += length
    require(total <= MAX_SOURCE and root_files | {'src/lib.rs', 'src/main.rs',
            'examples/khc_spatial_mdl_e2e.rs'} <= set(names), 'source total/required files')
    return names


def verify_source(root, records):
    expected = validate_source_manifest(records)
    source = root/'source'
    actual = {str(p.relative_to(source)) for p in source.rglob('*') if p.is_file()}
    require(actual == set(expected), 'source file set changed')
    for name, record in expected.items():
        p = source/name
        require(not p.is_symlink() and p.stat().st_nlink == 1 and
                p.stat().st_size == record['bytes'] and digest(p) == record['sha256'], 'source bytes changed')


def reject_cargo_config(source, cargo_home):
    for parent in [source] + list(source.parents):
        for name in ('config', 'config.toml'):
            p = parent/'.cargo'/name
            require(not p.exists() and not p.is_symlink(), 'ancestor Cargo config requires review: '+str(p))
    for name in ('config', 'config.toml'):
        p = cargo_home/name
        require(not p.exists() and not p.is_symlink(), 'Cargo home config requires review: '+str(p))


def prepare_source(root, source_sha, setup):
    archive = root/'downloads/source.zip'
    require(not (root/'source').exists(), 'source already created')
    require(archive.stat().st_size <= MAX_SOURCE and digest(archive) == source_sha, 'source ZIP hash/size')
    with zipfile.ZipFile(str(archive)) as z:
        entries = z.infolist()
        require(0 < len(entries) <= 201 and sum(p.file_size for p in entries) <= MAX_SOURCE+65536,
                'source ZIP expansion bound')
        require(len({p.filename for p in entries}) == len(entries), 'duplicate ZIP member')
        require(all(not p.is_dir() and not p.flag_bits & 1 and
                    p.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) and
                    stat.S_IFMT(p.external_attr >> 16) in (0, stat.S_IFREG) for p in entries), 'source ZIP type')
        manifest = z.getinfo('snapshot-manifest.json')
        require(manifest.file_size < 65536, 'source manifest bound')
        records = json.loads(z.read(manifest))
        names = validate_source_manifest(records)
        require(set(z.namelist()) == set(names) | {'snapshot-manifest.json'}, 'ZIP/manifest file set')
        setup.admit(root, sum(p.file_size for p in entries)+1024**2)
        (root/'source').mkdir(mode=0o700)
        for name, record in names.items():
            entry = z.getinfo(name)
            require(entry.file_size == record['bytes'], 'source ZIP length')
            data = z.read(entry)
            require(hashlib.sha256(data).hexdigest() == record['sha256'], 'source member SHA256')
            path = root/'source'/name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            with path.open('xb') as out:
                out.write(data)
        setup.new_json(root/'journal/source-inputs.json', {'source_sha256': source_sha, 'files': records})
    verify_source(root, records)
    reject_cargo_config(root/'source', root/'cargo-home')


def validate_amendment(spec, script_sha, environment):
    expected = {'schema': 1, 'protocol': 'khc-mac-native-build-amendment-v1',
                'task': 'goal-restore-20261019', 'host': 'm3mb14', 'root': ROOT.as_posix(), 'stage': 'build',
                'source_sha256': environment['source_sha256'],
                'old_controller_sha256': environment['old_controller_sha256'],
                'new_controller_sha256': script_sha,
                'old_check_terminal_sha256': environment['previous_terminal_sha256']['check'],
                'environment_sha256': ENVIRONMENT_SHA256, 'cc_shim_sha256': environment['cc_shim_sha256'],
                'reason': 'sandboxed-xcrun-cache-and-rust-objcopy-rpath'}
    require(type(spec) is dict and type(spec.get('schema')) is int and spec == expected and
            re.fullmatch('[0-9a-f]{64}', script_sha) is not None and
            script_sha != environment['old_controller_sha256'], 'invalid limited build amendment')


def corrective_environment(root, stage, source_sha, script_sha, setup):
    require(stage == 'build', 'corrective controller is restricted to the unstarted build stage')
    path = root/'downloads/mac-native-environment.json'
    setup.checked_path(path)
    require(path.stat().st_size < 65536 and digest(path) == ENVIRONMENT_SHA256, 'environment profile changed')
    profile = json.loads(path.read_text())
    require(profile['schema'] == 1 and profile['host'] == 'm3mb14' and profile['root'] == str(root) and
            profile['source_sha256'] == source_sha and profile['old_controller_sha256'] ==
            '51baf46cb26f441e1148123409a271421bd17944893e9bbd3e2fd68401c56a97', 'environment identity mismatch')
    spec_path = root/'journal/mac-native-build-amendment-spec.json'
    setup.checked_path(spec_path)
    require(spec_path.stat().st_size < 65536, 'amendment size')
    spec = json.loads(spec_path.read_text())
    validate_amendment(spec, script_sha, profile)
    for previous, expected in profile['previous_terminal_sha256'].items():
        terminal = root/'journal'/('mac-build-'+previous+'-done.json')
        require(digest(terminal) == expected, 'original terminal proof changed')
        result = json.loads(terminal.read_text())
        require(result['source_sha256'] == source_sha and
                result['script_sha256'] == profile['old_controller_sha256'] and
                result['exit'] == 0 and result['children_absent'] is True, 'original stage incomplete')
    require(not list((root/'journal').glob('mac-build-build-*.json')), 'build already attempted')
    cc = root/'tools/native-bin/cc'
    setup.checked_path(cc)
    require(digest(cc) == profile['cc_shim_sha256'] and os.access(str(cc), os.X_OK), 'native cc shim changed')
    probe = root/'journal/native-environment-probe.json'
    require(digest(probe) == profile['native_probe_sha256'], 'native environment probe changed')
    observed = json.loads(probe.read_text())
    require(observed['environment'] == profile['environment'] and observed['children_absent'] is True and
            observed['c_compile_output'] == '' and observed['rust_compile_output'] == '' and
            observed['cc_shim_sha256'] == profile['cc_shim_sha256'], 'native probe incomplete')
    require(Path(profile['environment']['SDKROOT']).is_dir(), 'selected SDK missing')
    return profile, digest(spec_path)


def validate_clean_build_output(output, require_fresh=False):
    require(not any(marker in output.lower() for marker in ('warning:', 'error:')),
            'corrective compiler emitted a diagnostic warning/error')
    require(not require_fresh or 'Compiling unlhare v' in output,
            'corrective Clippy did not freshly rebuild the root build script')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('build',))
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Mac ARM64 only')
    require(re.fullmatch('[0-9a-f]{64}', args.source_sha) is not None, 'source SHA256 format')
    os.umask(0o077)
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    require(digest(setup_path) == SETUP_SHA256, 'setup source changed')
    spec = importlib.util.spec_from_file_location('mac_setup', str(setup_path))
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT, private=True)
    setup.checked_path(Path(__file__).absolute())
    require(Path(__file__).absolute() == ROOT/'tools/mac-native-build.py', 'controller location')
    profile_sha = digest(setup_path.with_name('mac-native-tools.json'))
    require(json.loads((ROOT/'ownership.json').read_text()) ==
            {'profile_sha256': profile_sha, 'uid': os.getuid(), 'root': str(ROOT)}, 'ownership mismatch')
    require((ROOT/'journal/finish-verified-tools-done.json').is_file(), 'tools not complete')
    environment, amendment_sha = corrective_environment(
        ROOT, args.stage, args.source_sha, digest(Path(__file__)), setup)
    # 最初のCargo工程より前に正常性確認の入力をすべて固定する。
    for relative, expected, maximum in (
            ('tools/mac-native-e2e.py', E2E_SCRIPT_SHA256, 65536),
            ('downloads/mac-native-e2e-config.json', E2E_CONFIG_SHA256, 65536),
            ('downloads/mac-native-e2e-oracle.json', E2E_ORACLE_SHA256, 65536),
            ('downloads/ptt5.bin', FIXTURE_SHA256, 513216)):
        path = ROOT/relative
        setup.checked_path(path)
        require(path.is_file() and path.stat().st_size <= maximum and digest(path) == expected,
                'correctness input changed: '+relative)
    setup.admit(ROOT)
    ordinary, cargo_bytes = setup.counts(ROOT)
    fs = os.statvfs(str(ROOT))
    setup.admit_values(ordinary+setup.BOOTSTRAP_RESERVE, cargo_bytes,
                       setup.LOG_LIMIT+65536, setup.CARGO-cargo_bytes,
                       fs.f_bavail*fs.f_frsize)
    journal = ROOT/'journal'
    stage = args.stage
    prefix = 'mac-build-'+stage
    require(not any(journal.glob(prefix+'-*.json')), 'build stage already attempted')
    if stage != 'prepare-source':
        predecessor = {'fetch': 'prepare-source', 'check': 'fetch', 'build': 'check'}[stage]
        prior = json.loads((journal/('mac-build-'+predecessor+'-done.json')).read_text())
        require(prior['source_sha256'] == args.source_sha and prior['children_absent'] is True and
                prior['exit'] == 0, 'previous build stage incomplete')
    identity = {'stage': stage, 'source_sha256': args.source_sha,
                'script_sha256': digest(Path(__file__)), 'setup_sha256': SETUP_SHA256,
                'e2e_script_sha256': E2E_SCRIPT_SHA256, 'e2e_config_sha256': E2E_CONFIG_SHA256,
                'e2e_oracle_sha256': E2E_ORACLE_SHA256, 'amendment_sha256': amendment_sha,
                'environment_sha256': ENVIRONMENT_SHA256}
    setup.new_json(journal/(prefix+'-started.json'), identity)
    supervisor = setup.Supervisor(ROOT)
    code, error, evidence = 0, None, {}
    records = None
    try:
        if stage == 'prepare-source':
            prepare_source(ROOT, args.source_sha, setup)
        else:
            inputs = json.loads((journal/'source-inputs.json').read_text())
            require(inputs['source_sha256'] == args.source_sha, 'source identity changed')
            records = inputs['files']
            verify_source(ROOT, records)
            reject_cargo_config(ROOT/'source', ROOT/'cargo-home')
            cargo = ROOT/'tools/rust/bin/cargo'
            env = ['/usr/bin/env', 'RUSTC='+str(ROOT/'tools/rust/bin/rustc'),
                   'RUSTDOC='+str(ROOT/'tools/rust/bin/rustdoc'), 'RUSTUP_AUTO_INSTALL=0',
                   'CARGO_INCREMENTAL=0', 'CARGO_BUILD_JOBS=1']
            env += [key+'='+value for key, value in environment['environment'].items()]
            target = ['--locked', '--target', 'aarch64-apple-darwin']
            if stage == 'fetch':
                # 取得時だけHTTPSを認め、書込み先とsignalの制約は維持する。
                policy = ('(version 1)(allow default)(deny file-write*)'
                          '(allow file-write* (subpath "%s") (literal "/dev/null"))'
                          '(deny signal)') % ROOT
                command = ['/usr/bin/sandbox-exec', '-p', policy] + env + [str(cargo), 'fetch'] + target + ['--config', 'net.retry=0',
                           '--config', 'http.timeout=30']
                evidence['fetch'] = supervisor.run(command, timeout=180, cwd=ROOT/'source')[-8192:]
            else:
                selection = ['--lib', '--bin', 'unlhare-cli', '--example', 'khc_spatial_mdl_e2e']
                verb = 'clippy' if stage == 'check' else 'build'
                if stage == 'build':
                    # byteを保ったbuild.rsのmtime更新で、警告を出したhost処理を再実行する。
                    build_script = ROOT/'source/build.rs'
                    before = build_script.stat()
                    script_input_sha = digest(build_script)
                    os.utime(str(build_script), None, follow_symlinks=False)
                    require(digest(build_script) == script_input_sha, 'rebuild trigger changed source bytes')
                    corrective = setup.sandbox_command(ROOT) + env + [str(cargo), 'clippy',
                        '--release', '--offline'] + target + selection + ['-j', '1', '--target-dir',
                        str(ROOT/'cargo-target'), '--', '-D', 'warnings']
                    checked = supervisor.run(corrective, timeout=180, cwd=ROOT/'source')
                    evidence['corrective_clippy'] = checked[-8192:]
                    evidence['rebuild_trigger'] = {'path': 'build.rs', 'bytes_sha256': script_input_sha,
                        'before_mtime_ns': before.st_mtime_ns, 'after_mtime_ns': build_script.stat().st_mtime_ns}
                    validate_clean_build_output(checked, True)
                command = setup.sandbox_command(ROOT) + env + [str(cargo), verb, '--release', '--offline'] + target + selection + [
                    '-j', '1', '--target-dir', str(ROOT/'cargo-target')]
                if stage == 'check':
                    command += ['--', '-D', 'warnings']
                built = supervisor.run(command, timeout=180, cwd=ROOT/'source')
                validate_clean_build_output(built)
                evidence[verb] = built[-8192:]
            verify_source(ROOT, records)
            if stage == 'build':
                for relative in ('unlhare-cli', 'examples/khc_spatial_mdl_e2e'):
                    binary = ROOT/'cargo-target/aarch64-apple-darwin/release'/relative
                    evidence[relative] = {'bytes': binary.stat().st_size, 'sha256': digest(binary),
                        'file': supervisor.run(['/usr/bin/file', '-b', str(binary)], timeout=10)}
                    require('arm64' in evidence[relative]['file'], 'non-native build')
                evidence['rustc'] = supervisor.run([str(ROOT/'tools/rust/bin/rustc'), '-vV'], timeout=10)
                # ビルドと正常性確認の両方を通過した場合だけ工程成功とする。
                setup.admit(ROOT, 8*1024**2)
                run_root = ROOT/'tmp/native-e2e'
                require(not run_root.exists(), 'native E2E run already exists')
                run_root.mkdir(mode=0o700)
                registration = {'schema': 1, 'task': 'goal-restore-20261019',
                    'run': 'mac-native-e2e-20261026', 'root': str(run_root),
                    'config_sha256': E2E_CONFIG_SHA256, 'oracle_sha256': E2E_ORACLE_SHA256,
                    'fixture_sha256': FIXTURE_SHA256,
                    'cli_sha256': evidence['unlhare-cli']['sha256'],
                    'e2e_sha256': evidence['examples/khc_spatial_mdl_e2e']['sha256']}
                registration_path = run_root/'registration.json'
                setup.new_json(registration_path, registration)
                report = supervisor.run(setup.sandbox_command(ROOT) + [
                    '/usr/bin/python3', '-I', '-B', str(ROOT/'tools/mac-native-e2e.py'),
                    '--registration-sha', digest(registration_path)], timeout=305)
                evidence['correctness'] = json.loads(report)
                require(evidence['correctness']['state'] == 'passed', 'native E2E did not pass')
                verify_source(ROOT, records)
    except BaseException as failure:
        code, error = 1, str(failure)[:4096]
        if records is not None:
            try:
                verify_source(ROOT, records)
            except BaseException as changed:
                error += '; source postcheck: '+str(changed)[:4096]
    # Supervisorの回収に失敗した場合は終了を確定せず、pendingを維持する。
    absent = not error or ('group still present' not in error and 'did not finish' not in error)
    if supervisor.process is not None:
        try:
            os.killpg(supervisor.process.pid, 0)
            absent = False
        except ProcessLookupError:
            pass
    terminal = dict(identity, exit=code, status='done' if code == 0 else 'failed',
                    children_absent=bool(absent), evidence=evidence, error=error,
                    usage=setup.admit(ROOT))
    setup.new_json(journal/(prefix+('-done.json' if code == 0 else '-failed.json')), terminal)
    print(json.dumps(terminal, sort_keys=True), flush=True)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BaseException as failure:
        if isinstance(failure, SystemExit):
            raise
        print(json.dumps({'error': str(failure)[:4096]}), file=sys.stderr)
        sys.exit(1)
