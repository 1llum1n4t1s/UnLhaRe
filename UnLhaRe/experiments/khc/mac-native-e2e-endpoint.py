#!/usr/bin/env python3
"""登録済みWindows runからのみ呼ぶps-free検証の有限endpoint。"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import sys
import time

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
RUN = ROOT/'tmp/native-e2e-ps-free'
PREFIX = 'mac-native-e2e-ps-free'
SETUP_SHA = '9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
BUILD_CONTROLLER_SHA = '9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb'
REASON = 'sandbox-ps-exec-denied-use-outer-group-proof'
PINS = {
    'source_sha256': '030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f',
    'old_failed_build_sha256': '1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7',
    'previous_e2e_sha256': '60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c',
    'e2e_script_sha256': 'a64e6252a045e0be98c12d06d9b216d62ab45133609173168c2502f6cc369b8d',
    'config_sha256': '4ab81ef5c3fceda36edd379ae89430c1f3e19825d3e0f3f42074e51c9a729e6a',
    'oracle_sha256': '343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75',
    'fixture_sha256': '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650',
    'cli_sha256': '5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629',
    'e2e_sha256': 'b4e8d7c5fe5fa87b74c466cacabe4c94baddf80a1717b66629e0012c59e12ff4',
}


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def expected_protocol(endpoint_sha):
    return dict(schema=1, protocol='khc-mac-native-e2e-ps-free-v1', task='goal-restore-20261019',
                host='m3mb14', root=ROOT.as_posix(), run='mac-native-e2e-ps-free-20261026',
                windows_max_bytes=8388608, windows_max_entries=96, windows_timeout_seconds=360,
                remote_global_seconds=300, remote_supervisor_seconds=305,
                endpoint_sha256=endpoint_sha, reason=REASON, **PINS)


def validate_protocol(value, endpoint_sha):
    require(type(value) is dict and type(value.get('schema')) is int and
            value == expected_protocol(endpoint_sha) and
            re.fullmatch('[0-9a-f]{64}', endpoint_sha) is not None, 'invalid fixed correctness protocol')


def validate_report_identity(report, windows_run_id, protocol_sha, registration_sha):
    expected = {key: value for key, value in PINS.items() if key != 'source_sha256'}
    expected.update(windows_run_id=windows_run_id, protocol_sha256=protocol_sha,
                    registration_sha256=registration_sha, reason=REASON)
    require(all(report.get(key) == value for key, value in expected.items()),
            'report and endpoint identity differ')


def read_bounded(path, maximum, expected=None):
    require(path.is_file() and not path.is_symlink(), 'missing/link input: '+str(path))
    with path.open('rb') as stream:
        data = stream.read(maximum+1)
    require(len(data) <= maximum, 'input bound: '+str(path))
    require(expected is None or digest(data) == expected, 'input SHA changed: '+str(path))
    return data


def load_module(path, name, expected):
    read_bounded(path, 128*1024, expected)
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-run-id', required=True)
    parser.add_argument('--protocol-sha', required=True)
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native Mac ARM64 only')
    require(re.fullmatch('[0-9a-f]{32}', args.windows_run_id) is not None and
            re.fullmatch('[0-9a-f]{64}', args.protocol_sha) is not None, 'invalid endpoint identity')
    os.umask(0o077)
    endpoint_sha = digest(read_bounded(Path(__file__), 65536))
    require(Path(__file__).absolute() == ROOT/'tools/mac-native-e2e-endpoint.py', 'endpoint location')
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup = load_module(setup_path, 'mac_setup', SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT, private=True)
    protocol_bytes = read_bounded(ROOT/'downloads/mac-native-e2e-ps-free-protocol.json', 65536, args.protocol_sha)
    protocol = json.loads(protocol_bytes)
    validate_protocol(protocol, endpoint_sha)
    journal = ROOT/'journal'
    terminal_path = journal/(PREFIX+'.terminal.json')
    if args.inspect:
        data = read_bounded(terminal_path, 65536)
        previous = json.loads(data)
        require(previous['windows_run_id'] == args.windows_run_id and
                previous['protocol_sha256'] == args.protocol_sha and
                previous['endpoint_sha256'] == endpoint_sha, 'terminal identity mismatch')
        print(data.decode('utf-8').strip(), flush=True)
        return previous['exit']
    # 終端の読取だけなら、新しいrunの容量・空き領域を予約しない。
    setup.admit(ROOT, 8*1024**2)
    require(not (journal/(PREFIX+'.started.json')).exists() and not terminal_path.exists(),
            'correctness endpoint already attempted')
    identity = dict(schema=1, protocol='khc-mac-native-e2e-ps-free-terminal-v1',
                    windows_run_id=args.windows_run_id, protocol_sha256=args.protocol_sha,
                    endpoint_sha256=endpoint_sha, reason=REASON, **PINS)
    setup.new_json(journal/(PREFIX+'.started.json'), dict(identity, endpoint_pid=os.getpid(),
                   parent_pid=os.getppid(), started_unix_ns=time.time_ns()))
    supervisor = setup.Supervisor(ROOT)
    code, error, report_bytes, report = 0, None, None, None
    source = None
    try:
        old = json.loads(read_bounded(journal/'mac-build-build-failed.json', 65536,
                                     PINS['old_failed_build_sha256']))
        require(old['exit'] == 1 and old['children_absent'] is True and
                old['source_sha256'] == PINS['source_sha256'] and
                old['script_sha256'] == BUILD_CONTROLLER_SHA, 'previous failed stage changed')
        for key, relative, maximum in (
                ('e2e_script_sha256', 'tools/mac-native-e2e.py', 65536),
                ('config_sha256', 'downloads/mac-native-e2e-config.json', 65536),
                ('oracle_sha256', 'downloads/mac-native-e2e-oracle.json', 65536),
                ('fixture_sha256', 'downloads/ptt5.bin', 513216),
                ('cli_sha256', 'cargo-target/aarch64-apple-darwin/release/unlhare-cli', 16*1024**2),
                ('e2e_sha256', 'cargo-target/aarch64-apple-darwin/release/examples/khc_spatial_mdl_e2e', 16*1024**2)):
            setup.checked_path(ROOT/relative)
            read_bounded(ROOT/relative, maximum, PINS[key])
        source = load_module(ROOT/'tools/mac-native-build.py', 'mac_build', BUILD_CONTROLLER_SHA)
        inputs = json.loads(read_bounded(journal/'source-inputs.json', 65536))
        require(inputs['source_sha256'] == PINS['source_sha256'], 'source snapshot changed')
        source.verify_source(ROOT, inputs['files'])
        require(not RUN.exists(), 'ps-free correctness run already exists')
        RUN.mkdir(mode=0o700)
        registration = dict(schema=1, task='goal-restore-20261019', run=protocol['run'], root=str(RUN),
                            config_sha256=PINS['config_sha256'], oracle_sha256=PINS['oracle_sha256'],
                            fixture_sha256=PINS['fixture_sha256'], cli_sha256=PINS['cli_sha256'],
                            e2e_sha256=PINS['e2e_sha256'], windows_run_id=args.windows_run_id,
                            old_failed_build_sha256=PINS['old_failed_build_sha256'],
                            previous_e2e_sha256=PINS['previous_e2e_sha256'],
                            e2e_script_sha256=PINS['e2e_script_sha256'], reason=REASON,
                            protocol_sha256=args.protocol_sha)
        setup.new_json(RUN/'registration.json', registration)
        registration_sha = digest(read_bounded(RUN/'registration.json', 65536))
        stdout = supervisor.run(setup.sandbox_command(ROOT) + ['/usr/bin/python3', '-I', '-B',
            str(ROOT/'tools/mac-native-e2e.py'), '--registration-sha', registration_sha], timeout=305)
        report_bytes = read_bounded(RUN/'report.json', 32768)
        require(stdout.strip() == report_bytes.decode('utf-8'), 'stdout/report differs')
        report = json.loads(report_bytes)
        validate_report_identity(report, args.windows_run_id, args.protocol_sha, registration_sha)
        oracle = json.loads(read_bounded(ROOT/'downloads/mac-native-e2e-oracle.json', 65536, PINS['oracle_sha256']))
        require(report['schema'] == 1 and report['state'] == 'passed' and
                report['tracked_direct_children_absent'] is True and
                report['registration_sha256'] == registration_sha and
                report['checks'] == oracle['checks'] and len(report['checks']) == 34 and
                report['api'] == oracle['api'] and
                [row['hex'] for row in report['full_goldens']] == oracle['api']['folded_zero_count_frames'] and
                report['archive_suffixes'] == oracle['archive_suffixes'] and
                report['restored'] == oracle['restored'], 'endpoint correctness report mismatch')
        source.verify_source(ROOT, inputs['files'])
    except BaseException as failure:
        code, error = 1, str(failure)[:4096]
        if source is not None:
            try:
                source.verify_source(ROOT, inputs['files'])
            except BaseException as changed:
                error = (error+'; source postcheck: '+str(changed))[:4096]
    # groupの終了責任はsandbox外のSupervisorだけが持つ。
    absent = True
    if supervisor.process is not None:
        try:
            os.killpg(supervisor.process.pid, 0)
            absent = False
        except ProcessLookupError:
            pass
    if not absent:
        code, error = 1, 'owned process group still exists; no cleanup authorization'
    setup.admit(ROOT)
    terminal = dict(identity, children_absent=absent,
                    tracked_direct_children_absent=bool(report and report.get('tracked_direct_children_absent')),
                    exit=code, status='passed' if code == 0 else 'failed',
                    report_sha256=digest(report_bytes) if code == 0 else None,
                    report_base64=base64.b64encode(report_bytes).decode('ascii') if code == 0 else None,
                    error=error)
    encoded = (json.dumps(terminal, sort_keys=True)+'\n').encode('utf-8')
    require(len(encoded) <= 65536, 'endpoint receipt exceeds 64KiB')
    setup.new_json(terminal_path, terminal)
    print(encoded.decode('utf-8').strip(), flush=True)
    return code


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BaseException as failure:
        if isinstance(failure, SystemExit):
            raise
        print(json.dumps({'error': str(failure)[:4096]}), file=sys.stderr, flush=True)
        sys.exit(1)
