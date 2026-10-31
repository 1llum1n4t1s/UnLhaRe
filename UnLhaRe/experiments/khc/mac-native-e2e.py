#!/usr/bin/env python3
"""固定登録・有限34ケースのnative correctness検証。性能試験は行わない。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import selectors
import signal
import stat
import struct
import subprocess
import sys
import time

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
RUN = ROOT/'tmp/native-e2e-ps-free'
FIXTURE_SHA = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
CONFIG_SHA = '4ab81ef5c3fceda36edd379ae89430c1f3e19825d3e0f3f42074e51c9a729e6a'
ORACLE_SHA = '343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75'
OLD_FAILED_BUILD_SHA = '1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7'
PREVIOUS_E2E_SHA = '60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c'
CLI_SHA = '5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629'
E2E_SHA = 'b4e8d7c5fe5fa87b74c466cacabe4c94baddf80a1717b66629e0012c59e12ff4'
REASON = 'sandbox-ps-exec-denied-use-outer-group-proof'
CONFIG = dict(schema=1, task='goal-restore-20261019', run='mac-native-e2e-ps-free-20261026',
              root=RUN.as_posix(), max_bytes=8388608, max_entries=96, outer_timeout_seconds=300,
              child_timeout_seconds=240, outer_log_reserved_bytes=1048576,
              report_reserved_bytes=65536, fixture_bytes=513216,
              fixture_sha256=FIXTURE_SHA, oracle_sha256=ORACLE_SHA)


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def load_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError) as error:
        raise Refusal('invalid JSON') from error


def sha(data):
    return hashlib.sha256(data).hexdigest()


def validate_config(value):
    require(type(value) is dict and set(value) == set(CONFIG), 'config fields')
    require(all(type(value[k]) is type(v) and value[k] == v for k, v in CONFIG.items()), 'config value/type')


def validate_registration(value):
    fields = {'schema', 'task', 'run', 'root', 'config_sha256', 'cli_sha256',
              'e2e_sha256', 'oracle_sha256', 'fixture_sha256', 'windows_run_id',
              'old_failed_build_sha256', 'previous_e2e_sha256', 'e2e_script_sha256',
              'reason', 'protocol_sha256'}
    require(type(value) is dict and set(value) == fields, 'registration fields')
    require(type(value['schema']) is int and value['schema'] == 1, 'registration schema')
    require(all(value[k] == CONFIG[k] for k in ('task', 'run', 'root')), 'registration identity')
    require(isinstance(value['windows_run_id'], str) and re.fullmatch('[0-9a-f]{32}', value['windows_run_id']) is not None,
            'Windows run ID format')
    require(value['reason'] == REASON, 'corrective-run reason')
    for key in fields - {'schema', 'task', 'run', 'root', 'windows_run_id', 'reason'}:
        require(isinstance(value[key], str) and re.fullmatch('[0-9a-f]{64}', value[key]) is not None,
                'registration SHA format')
    require(value['config_sha256'] == CONFIG_SHA and value['oracle_sha256'] == ORACLE_SHA and
            value['fixture_sha256'] == FIXTURE_SHA and value['cli_sha256'] == CLI_SHA and
            value['e2e_sha256'] == E2E_SHA and value['old_failed_build_sha256'] == OLD_FAILED_BUILD_SHA and
            value['previous_e2e_sha256'] == PREVIOUS_E2E_SHA, 'registration fixed pins')


def relative_path(value):
    require(isinstance(value, str), 'oracle path type')
    path = PurePosixPath(value)
    require(value and str(path) == value and not path.is_absolute() and
            '..' not in path.parts and '\\' not in value and value != '.', 'unsafe oracle path')
    return path


def admit_counts(size, entries, report_pending=True):
    require(type(size) is int and type(entries) is int and size >= 0 and entries >= 1, 'invalid tree counters')
    require(size+CONFIG['outer_log_reserved_bytes']+CONFIG['report_reserved_bytes'] <= CONFIG['max_bytes'],
            'run bytes plus outer log/report reserves exceed 8MiB')
    require(entries+1+int(report_pending) <= CONFIG['max_entries'], 'run entries plus log/report exceed 96')


def validate_check(name, code, index, oracle):
    require(type(code) is int and code in (0, 1), 'signal/abnormal child exit is not an expected refusal')
    require(index < len(oracle) and oracle[index] == {'name': name, 'exit_code': code},
            'check order/name/normal exit differs from Windows oracle')


def archive_suffix(data):
    require(len(data) >= 32, 'archive header shorter than 32 bytes')
    offset = 32+struct.unpack_from('<I', data, 20)[0]
    require(offset <= len(data), 'archive metadata exceeds file')
    return data[offset:]


def checked_path(path, private=False):
    path = Path(path)
    require(path.is_absolute() and str(path.resolve()) == str(path), 'noncanonical absolute path')
    for part in list(reversed(path.parents))+[path]:
        metadata = part.lstat()
        require(not stat.S_ISLNK(metadata.st_mode) and metadata.st_uid in (0, os.getuid()) and
                not metadata.st_mode & 0o022, 'untrusted owner/writable/link ancestor: '+str(part))
    if private:
        metadata = path.lstat()
        require(metadata.st_uid == os.getuid() and not metadata.st_mode & 0o077, 'private owned path required')
    return path


def read_file(path, maximum=8*1024**2, expected=None, single_link=False):
    checked_path(path)
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and
                before.st_size <= maximum and (not single_link or before.st_nlink == 1), 'input file bound/ownership/link')
        chunks, length = [], 0
        while True:
            block = os.read(fd, min(65536, maximum+1-length))
            if not block:
                break
            length += len(block)
            require(length <= maximum, 'file read bound')
            chunks.append(block)
        after = os.fstat(fd)
        require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) and length == before.st_size,
                'file changed while reading')
    finally:
        os.close(fd)
    data = b''.join(chunks)
    require(expected is None or sha(data) == expected, 'pinned file SHA mismatch: '+str(path))
    return data


def budget():
    checked_path(RUN, private=True)
    size, entries, pending = 0, 1, True
    stack = [RUN]
    while stack:
        for child in stack.pop().iterdir():
            metadata = child.lstat()
            require(not stat.S_ISLNK(metadata.st_mode) and metadata.st_uid == os.getuid() and
                    not metadata.st_mode & 0o077, 'untrusted run entry')
            entries += 1
            if stat.S_ISDIR(metadata.st_mode):
                stack.append(child)
            else:
                require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1, 'run special file/hardlink')
                size += metadata.st_size
            if child == RUN/'report.json':
                pending = False
            admit_counts(size, entries, pending)
    admit_counts(size, entries, pending)
    return {'actual_bytes': size, 'actual_entries': entries,
            'outer_log_reserved_bytes': 1048576, 'report_reserved_bytes': 65536}


class Runner:
    def __init__(self):
        self.deadline = time.monotonic()+300
        self.interrupted = False
        self.accounting = False
        self.active = set()

    def stop(self, *_):
        self.interrupted = True

    def pulse(self):
        require(not self.interrupted and time.monotonic() < self.deadline, 'interrupted/global 300s deadline')
        if self.accounting:
            budget()

    def capture(self, argv, env=None, timeout=240):
        self.pulse()
        limit = min(self.deadline, time.monotonic()+timeout)
        process = None
        selector = selectors.DefaultSelector()
        output = [bytearray(), bytearray()]
        try:
            # session/process groupは作らず、outer Supervisorのgroupを全子へ継承する。
            process = subprocess.Popen(argv, cwd=str(RUN if self.accounting else ROOT), env=env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, close_fds=True)
            self.active.add(process)
            for index, pipe in enumerate((process.stdout, process.stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, index)
            while selector.get_map() or process.poll() is None:
                self.pulse()
                require(time.monotonic() < limit, 'child observation deadline')
                for key, _ in selector.select(0.1):
                    block = os.read(key.fileobj.fileno(), 4096)
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        output[key.data].extend(block)
                        require(sum(len(x) for x in output) <= 32768, 'combined child stdout/stderr exceeds 32KiB')
            self.pulse()
            code = process.wait(timeout=1)
            return code, bytes(output[0]).decode('utf-8', 'strict'), bytes(output[1]).decode('utf-8', 'strict'), process.pid
        finally:
            selector.close()
            if process is not None:
                # sandbox内からsignalを送らない。途中異常の元例外を保ち、
                # 生存中の子はactiveのままouter Supervisorのgroup停止へ引き渡す。
                for pipe in (process.stdout, process.stderr):
                    if pipe is not None:
                        try:
                            pipe.close()
                        except OSError:
                            pass
                if process.poll() is not None:
                    self.active.discard(process)

    def validate_acls(self, paths):
        seen = set()
        for path in paths:
            for part in list(reversed(path.parents))+[path]:
                if part in seen:
                    continue
                seen.add(part)
                code, out, _, _ = self.capture(['/bin/ls', '-lde', str(part)], timeout=10)
                acl = [line.strip() for line in out.splitlines()[1:]]
                require(code == 0 and out.splitlines() and acl in ([], ['0: group:everyone deny delete']),
                        'unknown/granting path ACL')

    def tracked_children_absent(self):
        # 全groupの不在はsandbox外のSupervisor/endpointが確認する。
        require(not self.active, 'tracked children remain active')


def new_file(path, data):
    current = budget()
    admit_counts(current['actual_bytes']+len(data), current['actual_entries']+1,
                 path != RUN/'report.json' and not (RUN/'report.json').exists())
    require(path.parent.is_dir() and not path.parent.is_symlink(), 'output parent missing/link')
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    budget()


def new_directory(path):
    current = budget()
    admit_counts(current['actual_bytes'], current['actual_entries']+1, not (RUN/'report.json').exists())
    path.mkdir(mode=0o700)
    budget()


def run(registration_sha):
    require(sys.platform == 'darwin' and platform.machine() == 'arm64', 'native macOS ARM64 required')
    require(re.fullmatch('[0-9a-f]{64}', registration_sha) is not None, 'registration SHA format')
    runner = Runner()
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, runner.stop)
    os.umask(0o077)
    registration_path = RUN/'registration.json'
    config_path = ROOT/'downloads/mac-native-e2e-config.json'
    oracle_path = ROOT/'downloads/mac-native-e2e-oracle.json'
    fixture = ROOT/'downloads/ptt5.bin'
    cli = ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli'
    e2e = ROOT/'cargo-target/aarch64-apple-darwin/release/examples/khc_spatial_mdl_e2e'
    checked_path(ROOT, private=True)
    checked_path(RUN, private=True)
    require(sorted(p.name for p in RUN.iterdir()) == ['registration.json'], 'registered run is not untouched/one-shot')
    for path in (registration_path, config_path, oracle_path, fixture, cli, e2e):
        checked_path(path)
    runner.validate_acls((registration_path, config_path, oracle_path, fixture, cli, e2e))
    registration = load_json(read_file(registration_path, 65536, registration_sha, True))
    validate_registration(registration)
    self_path = ROOT/'tools/mac-native-e2e.py'
    require(Path(__file__).resolve() == self_path, 'E2E script canonical path')
    read_file(self_path, 65536, registration['e2e_script_sha256'], True)
    validate_config(load_json(read_file(config_path, 65536, CONFIG_SHA, True)))
    oracle = load_json(read_file(oracle_path, 65536, ORACLE_SHA, True))
    require(type(oracle) is dict and set(oracle) == {'schema', 'reference_zip_sha256', 'api', 'archive_suffixes', 'checks', 'restored'} and oracle['schema'] == 1, 'oracle schema')
    fixture_data = read_file(fixture, 513216, FIXTURE_SHA, True)
    require(len(fixture_data) == 513216, 'fixture size')
    read_file(cli, 256*1024**2, registration['cli_sha256'])
    read_file(e2e, 256*1024**2, registration['e2e_sha256'])
    env = dict(os.environ)
    env['KHC_STORAGE_RUN_RECORD'] = str(registration_path)
    for key in ('TMPDIR', 'TEMP', 'TMP'):
        env[key] = str(ROOT/'tmp')
    runner.accounting = True
    runner.pulse()
    new_directory(RUN/'input')
    new_file(RUN/'input/ptt5', fixture_data)
    checks = []

    def child(binary, args, name):
        code, out, err, _ = runner.capture([str(binary)]+[str(x) for x in args], env)
        validate_check(name, code, len(checks), oracle['checks'])
        checks.append({'name': name, 'exit_code': code})
        return out

    api = RUN/'api'
    api_json = load_json(child(e2e, [api, RUN/'input/ptt5'], 'api-revision-10-e2e'))
    require(api_json == oracle['api'], 'API JSON including three full goldens differs from Windows')
    goldens = api_json['folded_zero_count_frames']
    require(len(goldens) == 3, 'expected exactly three full golden frames')
    golden_report = [{'index': i, 'bytes': len(bytes.fromhex(x)), 'sha256': sha(bytes.fromhex(x)), 'hex': x}
                     for i, x in enumerate(goldens)]
    g32_sha = sha(read_file(api/'source/g32.bin'))
    source = RUN/'cli-source'
    new_directory(source)
    new_file(source/'ptt5.bin', fixture_data)
    new_file(source/'short.bin', read_file(api/'source/short.bin'))
    archive, output = RUN/'cli-revision-10.khc', RUN/'cli-output'
    child(cli, ['khc-create', archive, '--source', source, '--strategy', 'portfolio-trial'], 'cli-create')
    archive_data = read_file(archive)
    require(len(archive_data) >= 40 and archive_data[:8] == b'KHC1ARC\0' and archive_data[8] == 10, 'CLI archive revision')
    listed = load_json(child(cli, ['khc-list', archive, '--json'], 'cli-list'))
    require(type(listed) is list and len(listed) == 2, 'CLI manifest entry count')
    child(cli, ['khc-test', archive], 'cli-test')
    child(cli, ['khc-extract', archive, '--output', output], 'cli-extract')
    restored = {}
    for name in ('ptt5.bin', 'short.bin'):
        before, after = read_file(source/name), read_file(output/name)
        require(before == after and sha(after) == oracle['restored'][name], 'CLI restored bytes/SHA')
        restored[name] = sha(after)
    archive_hash = sha(archive_data)
    child(cli, ['khc-create', archive, '--source', source, '--strategy', 'portfolio-trial'], 'cli-no-replace-create')
    require(sha(read_file(archive)) == archive_hash, 'CLI replaced existing archive')
    child(cli, ['khc-extract', archive, '--output', output], 'cli-no-replace-extract')
    require(all(sha(read_file(output/name)) == value for name, value in restored.items()), 'CLI modified existing output')
    invalid = sorted(api.glob('bad-*.khc'), key=lambda p: p.name)
    require([p.name for p in invalid] == ['bad-%d.khc' % i for i in range(9)], 'nine fixed invalid archives')
    for invalid_archive in invalid:
        label = invalid_archive.stem
        group = {'bad-2': 'truncated', 'bad-3': 'trailing'}.get(label, 'frames')
        rejected = api/('cli-rejected-'+group)
        if not rejected.exists():
            new_directory(rejected)
        sentinel, payload = rejected/'sentinel', rejected/'payload.bin'
        if not sentinel.exists():
            new_file(sentinel, b'keep')
        require(read_file(sentinel) == b'keep' and (group != 'frames' or not payload.exists()), 'contaminated refusal output')
        child(cli, ['khc-test', invalid_archive], 'cli-rejects-'+label+'-test')
        child(cli, ['khc-extract', invalid_archive, '--output', rejected], 'cli-rejects-'+label+'-extract')
        require(read_file(sentinel) == b'keep', 'CLI changed refusal sentinel')
        require(group != 'frames' or not payload.exists(), 'invalid frame wrote payload')
        if payload.exists():
            require(sha(read_file(payload)) == g32_sha, 'unexpected bad-2/3 partial payload')
    for revision in range(1, 10):
        child(cli, ['khc-test', api/('legacy-%d.khc' % revision)], 'cli-read-revision-%d' % revision)
    require(checks == oracle['checks'] and len(checks) == 34 and
            sum(x['exit_code'] == 0 for x in checks) == 14, '34 checks / 14 normal / 20 refusal contract')
    rows = oracle['archive_suffixes']
    require(type(rows) is list and len(rows) == 24, '24 suffix records required')
    names = [str(relative_path(row['path'])) for row in rows]
    require(len(set(names)) == 24 and set(names) == {p.relative_to(RUN).as_posix() for p in RUN.rglob('*.khc')}, 'exact 24 archive suffix path set')
    suffix_report = []
    for row in rows:
        suffix = archive_suffix(read_file(RUN/relative_path(row['path'])))
        observed = {'path': row['path'], 'bytes': len(suffix), 'sha256': sha(suffix)}
        require(observed == row, 'individual archive suffix bytes/SHA differs: '+row['path'])
        suffix_report.append(observed)
    runner.tracked_children_absent()
    report = dict(schema=1, state='passed', scope='finite native revision-10 correctness; not a benchmark',
                  registration_sha256=registration_sha, config_sha256=CONFIG_SHA, oracle_sha256=ORACLE_SHA,
                  fixture_sha256=FIXTURE_SHA, cli_sha256=registration['cli_sha256'], e2e_sha256=registration['e2e_sha256'],
                  checks=checks, api=api_json, full_goldens=golden_report, archive_suffixes=suffix_report,
                  restored=restored, cli_archive_sha256=archive_hash, tracked_direct_children_absent=True,
                  windows_run_id=registration['windows_run_id'], protocol_sha256=registration['protocol_sha256'],
                  old_failed_build_sha256=OLD_FAILED_BUILD_SHA, previous_e2e_sha256=PREVIOUS_E2E_SHA,
                  e2e_script_sha256=registration['e2e_script_sha256'], reason=REASON, usage=budget())
    encoded = json.dumps(report, ensure_ascii=True, sort_keys=True, separators=(',', ':')).encode('utf-8')
    require(len(encoded) <= 32768, 'report exceeds 32KiB endpoint transfer bound')
    new_file(RUN/'report.json', encoded)
    runner.pulse()
    print(encoded.decode('utf-8'), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--registration-sha', required=True)
    args = parser.parse_args()
    try:
        run(args.registration_sha)
    except Exception as error:
        print(json.dumps({'state': 'failed', 'error': str(error)[:2048]}, ensure_ascii=True), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
