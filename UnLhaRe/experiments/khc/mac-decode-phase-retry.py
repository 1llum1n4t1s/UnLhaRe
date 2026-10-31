#!/usr/bin/env python3
"""One permitted retry: validate the immutable first-attempt evidence before use.

Fail closed on altered/noncanonical or oversized evidence, changed paths, limits,
controller or snapshot; an unsuccessful or unclosed first attempt; a mismatched
closure; a prior retry; unsafe or incomplete storage inspection; changed sources
or tools; missing normal Cargo exit, group closure, or successful postchecks.
No retry execution is enabled until the gateway and storage contracts are joined.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

HERE = Path(__file__).absolute().parent
OLD_CONTROLLER_SHA = 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'
OLD_PROTOCOL_SHA = '64f6aae8c18c83f5f966462c96e1d4ecc3bb34af0a2f114b9844c129539f0088'
OLD_RECEIPT_SHA = '84c7e314b0a79c2ac9d55e34772c8f20339e29079dbd17868605c0e08f27f4ca'
OLD_CLOSURE_SHA = 'd12c7079556b9f44e5e0e952847040f9a467a380a977badf9102669ecc7f91a6'
SOURCE_SHA = '1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55'
ROOT = '/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
SOURCE = ROOT + '/decode-phase-20261027/source'
TARGET = ROOT + '/cargo-target/decode-phase-20261027'
PROTOCOL = 'khc-mac-decode-phase-retry-v1'
MAX_JSON = 65536


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')


def parse(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate JSON key')
            result[key] = value
        return result
    require(type(data) is bytes and 0 < len(data) <= MAX_JSON, 'JSON bound')
    value = json.loads(data, object_pairs_hook=pairs,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
    require(canonical(value) == data, 'canonical JSON required')
    return value


def valid_sha(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def expected_amendment(controller_sha, snapshot_sha):
    require(valid_sha(controller_sha) and valid_sha(snapshot_sha), 'new dependency hashes')
    return dict(schema=1, protocol=PROTOCOL, old_protocol_sha256=OLD_PROTOCOL_SHA,
        old_receipt_sha256=OLD_RECEIPT_SHA, old_closure_sha256=OLD_CLOSURE_SHA,
        old_controller_sha256=OLD_CONTROLLER_SHA, source_sha256=SOURCE_SHA,
        root=ROOT, source_directory=SOURCE, target=TARGET, controller_sha256=controller_sha,
        snapshot_sha256=snapshot_sha, additional_attempts=1, cargo_timeout_seconds=300,
        native_final_seconds=350, ssh_timeout_seconds=380, additional_target_max_bytes=536870912,
        ordinary_max_bytes=1610612736, cargo_max_bytes=1073741824, total_max_bytes=2684354560)


def validate_amendment(data, expected_sha, controller_sha, snapshot_sha):
    require(valid_sha(expected_sha) and digest(data) == expected_sha, 'amendment raw SHA')
    value = parse(data)
    require(canonical(value) == canonical(expected_amendment(controller_sha, snapshot_sha)),
        'fixed amendment mismatch')
    return value


def load_old_controller():
    path = HERE / 'mac-decode-phase-build.py'
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink == 1 and
        path.stat().st_size <= 131072 and digest(path.read_bytes()) == OLD_CONTROLLER_SHA,
        'old controller SHA/type')
    spec = importlib.util.spec_from_file_location('frozen_phase_build_retry', str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_old_evidence(protocol_data, receipt_data, closure_data, old=None):
    for data, expected in ((protocol_data, OLD_PROTOCOL_SHA), (receipt_data, OLD_RECEIPT_SHA),
                           (closure_data, OLD_CLOSURE_SHA)):
        require(type(data) is bytes and 0 < len(data) <= MAX_JSON and digest(data) == expected,
            'old raw evidence SHA/bound')
    protocol, receipt, closure = map(parse, (protocol_data, receipt_data, closure_data))
    old = old or load_old_controller()
    old.verify_protocol_bytes(protocol_data, OLD_PROTOCOL_SHA)
    verified = old.verify_receipt_bytes(receipt_data, protocol_data)
    require(protocol['controller_sha256'] == OLD_CONTROLLER_SHA and protocol['source_sha256'] == SOURCE_SHA and
        protocol['root'] == ROOT and protocol['source_directory'] == SOURCE and protocol['target'] == TARGET,
        'old identity')
    require(receipt['status'] == 'failed' and receipt['exit'] == 1 and
        receipt['binary_sha256'] is None and verified['cleanup_allowed'] is True and
        receipt['wait_confirmed'] is True and receipt['group_absent'] is True and receipt['postchecks_ok'] is True and
        receipt['closure_sha256'] == OLD_CLOSURE_SHA and canonical(receipt['closure_proof']) == closure_data and
        closure == receipt['closure_proof'], 'first attempt must be closed failure without binary')
    return verified


def decode_wire(value):
    require(type(value) is str and 0 < len(value) <= ((MAX_JSON + 2) // 3) * 4, 'wire bound')
    data = base64.b64decode(value, validate=True)
    require(len(data) <= MAX_JSON, 'wire decoded bound')
    return data


def validate_bundle(amendment_data, amendment_sha, protocol_data, receipt_data):
    snapshot_path = HERE / 'mac-diagnostic-storage-snapshot.py'
    require(not snapshot_path.is_symlink() and snapshot_path.is_file() and
        snapshot_path.stat().st_nlink == 1 and snapshot_path.stat().st_size <= 131072,
        'snapshot dependency type')
    controller_sha = digest(Path(__file__).read_bytes())
    snapshot_sha = digest(snapshot_path.read_bytes())
    amendment = validate_amendment(amendment_data, amendment_sha, controller_sha, snapshot_sha)
    receipt = parse(receipt_data)
    closure_data = canonical(receipt.get('closure_proof'))
    old = load_old_controller()
    validate_old_evidence(protocol_data, receipt_data, closure_data, old)
    return amendment, old, parse(protocol_data)


def validate_retry_receipt(data, amendment, amendment_sha, old, old_protocol):
    value = parse(data)
    extras = {'amendment_sha256', 'snapshot_sha256', 'old_receipt_sha256'}
    require(type(value) is dict and extras <= set(value), 'retry receipt fields')
    require(value['protocol'] == PROTOCOL and value['controller_sha256'] == amendment['controller_sha256'] and
        value['amendment_sha256'] == amendment_sha and value['protocol_sha256'] == amendment_sha and
        value['snapshot_sha256'] == amendment['snapshot_sha256'] and
        value['old_receipt_sha256'] == OLD_RECEIPT_SHA, 'retry receipt binding')
    # Reuse the frozen receipt's complete schema, closure and success validation
    # without changing its module globals or weakening its original identities.
    translated = {key: val for key, val in value.items() if key not in extras}
    translated.update(protocol=old_protocol['protocol'], controller_sha256=OLD_CONTROLLER_SHA,
                      protocol_sha256=OLD_PROTOCOL_SHA)
    checked = old.validate_receipt(translated, old_protocol)
    return dict(schema=1, protocol=PROTOCOL, verified=True, amendment_sha256=amendment_sha,
        old_receipt_sha256=OLD_RECEIPT_SHA, snapshot_sha256=amendment['snapshot_sha256'],
        receipt_sha256=digest(data), status=checked['status'], exit=checked['exit'],
        binary_sha256=checked['binary_sha256'], closure_sha256=checked['closure_sha256'],
        cleanup_allowed=checked['cleanup_allowed'])


def native_context(amendment_sha):
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native Mac ARM64 only')
    root = Path(ROOT)
    require(Path(__file__).absolute() == root / 'tools/mac-decode-phase-retry.py', 'controller location')
    old = load_old_controller()
    setup_path = Path(ROOT + '-bootstrap') / 'mac-native-setup.py'
    setup = old.load(setup_path, 'retry_native_setup', old.SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    setup.checked_path(root, private=True)
    setup.checked_path(root / 'journal', private=True)
    paths = [root / 'journal/mac-decode-phase-retry-amendment.json', old.PROTOCOL_PATH,
             root / 'journal/mac-decode-phase-build.terminal.json',
             root / 'journal/mac-decode-phase-build.closure.json']
    for path in paths:
        setup.checked_path(path)
    amendment_data = old.read_native(paths[0], MAX_JSON, amendment_sha)
    protocol_data = old.read_native(paths[1], MAX_JSON, OLD_PROTOCOL_SHA)
    receipt_data = old.read_native(paths[2], MAX_JSON, OLD_RECEIPT_SHA)
    closure_data = old.read_native(paths[3], MAX_JSON, OLD_CLOSURE_SHA)
    amendment, old, protocol = validate_bundle(amendment_data, amendment_sha, protocol_data, receipt_data)
    validate_old_evidence(protocol_data, receipt_data, closure_data, old)
    setup.checked_path(Path(__file__))
    old.read_native(Path(__file__), 131072, amendment['controller_sha256'])
    snapshot_path = HERE / 'mac-diagnostic-storage-snapshot.py'
    setup.checked_path(snapshot_path)
    old.read_native(snapshot_path, 131072, amendment['snapshot_sha256'])
    snapshot = old.load(snapshot_path, 'retry_storage_snapshot', amendment['snapshot_sha256'])
    return root, old, setup, snapshot, amendment, protocol


def native_admission(snapshot, root, deadline_ns, extra):
    measured = snapshot.snapshot(root, deadline_ns=deadline_ns)
    free = os.statvfs(str(root))
    return snapshot.validate_admission(measured, extra_ordinary=extra,
                                       free_bytes=free.f_bavail * free.f_frsize)


def cargo_guard_deadline(cargo_begin_ns, limit, native_deadline_ns):
    require(type(cargo_begin_ns) is int and type(native_deadline_ns) is int and
            type(limit) in (int, float) and 13 < limit <= 300, 'Cargo closure reserve')
    return min(native_deadline_ns, cargo_begin_ns + int((limit - 13) * 1_000_000_000))


def guarded_admission(deadline_ns, check_source, admit, *, clock=time.monotonic_ns):
    require(clock() < deadline_ns, 'Cargo guard deadline before source check')
    check_source()
    require(clock() < deadline_ns, 'Cargo guard deadline after source check')
    result = admit(deadline_ns)
    require(clock() < deadline_ns, 'Cargo guard deadline after snapshot')
    return result


def enforce_preparation_deadline(result, began, *, clock=time.monotonic):
    result = dict(result, runtime_seconds=max(result['runtime_seconds'], clock() - began))
    if result['status'] == 'done' and result['runtime_seconds'] > 350:
        result.update(status='failed', exit=1, error='native terminal preparation deadline exceeded')
    return result


def helper_main(parent_pid, amendment_sha):
    require(type(parent_pid) is int and parent_pid > 1 and os.getppid() == parent_pid,
            'Cargo helper parent identity')
    root, old, setup, _, amendment, protocol = native_context(amendment_sha)
    started = old.parse(old.read_native(root / 'journal/mac-decode-phase-retry.started.json', MAX_JSON))
    require(started['endpoint_pid'] == parent_pid and started['controller_sha256'] == amendment['controller_sha256'] and
            started['amendment_sha256'] == amendment_sha, 'Cargo helper started binding')
    _, records, _, profile, tools = old.native_inputs(setup, protocol)
    require(tools == started['tool_sha256'] and Path.cwd() == old.SOURCE, 'Cargo helper context')
    require(not old.BINARY.exists() and not old.BINARY.is_symlink(), 'existing diagnostic binary before Cargo')
    old.check_source_layout(old.SOURCE_PARENT, records)
    old.build_verifier().verify_source(old.SOURCE_PARENT, records)
    setup.checked_path(old.TARGET, private=True)
    setup.checked_path(old.TARGET / 'tmp', private=True)
    env = old.build_environment(profile, setup.child_environment(root))
    def runner(command):
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, close_fds=True)
        stdout, stderr = process.communicate(timeout=3)
        return dict(returncode=process.returncode, stdout=stdout, stderr=stderr)
    def save_versions(versions):
        require(old.tool_hashes(setup) == tools, 'tools changed during version checks')
        old.write_native(root / 'journal/mac-decode-phase-retry.versions.json',
            dict(schema=1, versions=versions, tool_sha256=tools, amendment_sha256=amendment_sha,
                 controller_sha256=amendment['controller_sha256']))
    old.cargo_transition(protocol['cargo_command'], env, runner, os.execvpe, save_versions)
    raise RuntimeError('Cargo exec unexpectedly returned')


def native_main(amendment_sha):
    root, old, setup, snapshot, amendment, protocol = native_context(amendment_sha)
    os.umask(0o077)
    prefix = root / 'journal/mac-decode-phase-retry'
    started = Path(str(prefix) + '.started.json')
    terminal = Path(str(prefix) + '.terminal.json')
    for suffix in ('.started.json', '.terminal.json', '.terminal-deadline.json', '.closure.json', '.versions.json'):
        path = Path(str(prefix) + suffix)
        require(not path.exists() and not path.is_symlink(), 'retry already attempted or journal occupied')
    begin = time.monotonic()
    deadline_ns = time.monotonic_ns() + 350_000_000_000
    cargo_runtime, proof, error, binary_sha, postchecks, status = 0., None, None, None, False, 'failed'
    old_records = records = tools = None
    started_here = False
    original_admit, original_environment = setup.admit, setup.child_environment
    try:
        require(not old.BINARY.exists() and not old.BINARY.is_symlink(), 'existing diagnostic binary')
        setup.checked_path(old.SOURCE_PARENT, private=True)
        setup.checked_path(old.TARGET, private=True)
        setup.checked_path(old.TARGET / 'tmp', private=True)
        old_records, records, _, profile, tools = old.native_inputs(setup, protocol)
        old.check_source_layout(old.SOURCE_PARENT, records)
        old.build_verifier().verify_source(old.SOURCE_PARENT, records)
        native_admission(snapshot, root, deadline_ns, old.JOURNAL_MARGIN)
        setup.new_json(started, dict(schema=1, protocol=PROTOCOL, amendment_sha256=amendment_sha,
            controller_sha256=amendment['controller_sha256'], source_sha256=SOURCE_SHA,
            endpoint_pid=os.getpid(), parent_pid=os.getppid(), tool_sha256=tools, started_unix_ns=time.time_ns()))
        started_here = True
        cargo_deadline_ns = deadline_ns
        def guard(_root, extra=0):
            def check_source():
                old.check_source_layout(root, old_records)
                old.check_source_layout(old.SOURCE_PARENT, records)
            return guarded_admission(cargo_deadline_ns, check_source,
                lambda deadline: native_admission(snapshot, root, deadline, extra + old.JOURNAL_MARGIN))
        setup.admit = guard
        setup.child_environment = lambda selected: old.build_environment(profile, original_environment(selected))
        setup.LOG_LIMIT = 16384
        supervisor = old.FS.Supervisor(root, support=setup)
        cargo_begin_ns = time.monotonic_ns()
        cargo_begin = cargo_begin_ns / 1_000_000_000
        limit = min(300., 350. - 45. - (cargo_begin - begin))
        cargo_deadline_ns = cargo_guard_deadline(cargo_begin_ns, limit, deadline_ns)
        command = setup.sandbox_command(root) + ['/usr/bin/python3', '-I', '-B', str(Path(__file__)),
            '--cargo-helper-parent-pid', str(os.getpid()), '--amendment-sha', amendment_sha]
        cargo_runtime, proof, primary = old.supervise_cargo(supervisor, command, old.SOURCE, limit,
            lambda: guard(root),
            persist=lambda value: old.write_native(Path(str(prefix) + '.closure.json'), value))
        require(primary is None, primary)
        require(cargo_runtime <= 300 and old.FS.validate_closure(proof, proof.get('pid'), proof.get('sequence')) and
            proof['primary']['kind'] == 'exit' and proof['primary']['returncode'] == 0 and
            proof['actual_returncode'] == 0, 'Cargo normal exit/group closure')
        setup.checked_path(old.BINARY)
        require(os.access(old.BINARY, os.X_OK), 'diagnostic binary executable')
        binary_sha = digest(old.read_native(old.BINARY, 64 * 1024**2, artifact=True))
        status = 'done'
    except BaseException as failure:
        error = (type(failure).__name__ + ': ' + str(failure))[:2048]
    finally:
        setup.admit, setup.child_environment = original_admit, original_environment
    # A competing invocation or an incomplete CreateNew must never publish a
    # terminal belonging to the process that acquired the journal start.
    require(started_here, error or 'retry start was not recorded')
    try:
        _, _, _, _, amendment_after, protocol_after = native_context(amendment_sha)
        require(amendment_after == amendment and protocol_after == protocol, 'post-build evidence identity')
        old_after, new_after, _, _, tools_after = old.native_inputs(setup, protocol)
        require(old_records == old_after and records == new_after and tools == tools_after, 'post-build identity')
        old.check_source_layout(old.SOURCE_PARENT, records)
        old.build_verifier().verify_source(old.SOURCE_PARENT, records)
        native_admission(snapshot, root, deadline_ns, old.JOURNAL_MARGIN)
        if status == 'done':
            require(digest(old.read_native(old.BINARY, 64 * 1024**2, artifact=True)) == binary_sha,
                    'post-build binary changed')
            versions = old.parse(old.read_native(Path(str(prefix) + '.versions.json'), MAX_JSON))
            require(versions['tool_sha256'] == tools and versions['amendment_sha256'] == amendment_sha and
                    versions['controller_sha256'] == amendment['controller_sha256'], 'version binding')
        require(time.monotonic_ns() <= deadline_ns, 'native finalization deadline')
        postchecks = True
    except BaseException as failure:
        status = 'failed'
        error = old.bounded_errors(error, type(failure).__name__ + ': ' + str(failure))
    closed = bool(proof is not None and old.FS.validate_closure(proof, proof.get('pid'), proof.get('sequence')))
    result = dict(schema=1, protocol=PROTOCOL, purpose=protocol['purpose'], source_sha256=SOURCE_SHA,
        controller_sha256=amendment['controller_sha256'], protocol_sha256=amendment_sha, root=ROOT, target=TARGET,
        cargo_command=protocol['cargo_command'], status=status, exit=0 if status == 'done' else 1,
        runtime_seconds=time.monotonic() - begin, cargo_runtime_seconds=cargo_runtime, binary_sha256=binary_sha,
        wait_confirmed=closed, group_absent=closed, postchecks_ok=postchecks, closure_proof=proof,
        closure_sha256=digest(canonical(proof)) if proof is not None else None, error=error,
        binary_path=old.BINARY.as_posix(), amendment_sha256=amendment_sha,
        snapshot_sha256=amendment['snapshot_sha256'], old_receipt_sha256=OLD_RECEIPT_SHA)
    result = enforce_preparation_deadline(result, begin)
    validate_retry_receipt(canonical(result), amendment, amendment_sha, old, protocol)
    terminal_sha = old.write_native(terminal, result)
    if time.monotonic_ns() > deadline_ns:
        result.update(status='failed', exit=1, postchecks_ok=False, runtime_seconds=time.monotonic() - begin,
            error=old.bounded_errors(error, 'native terminal persistence exceeded 350 seconds'))
        validate_retry_receipt(canonical(result), amendment, amendment_sha, old, protocol)
        temporary = Path(str(prefix) + '.terminal-deadline.json')
        old.read_native(terminal, MAX_JSON, terminal_sha)
        old.write_native(temporary, result)
        old.read_native(terminal, MAX_JSON, terminal_sha)
        os.replace(temporary, terminal)
        old.read_native(terminal, MAX_JSON, digest(canonical(result)))
    sys.stdout.buffer.write(canonical(result))
    return result['exit']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-amendment-base64')
    parser.add_argument('--amendment-base64')
    parser.add_argument('--amendment-sha')
    parser.add_argument('--verify-receipt-base64')
    parser.add_argument('--old-protocol-base64')
    parser.add_argument('--old-receipt-base64')
    parser.add_argument('--cargo-helper-parent-pid', type=int)
    args = parser.parse_args()
    if args.amendment_sha and not any((args.verify_amendment_base64, args.amendment_base64,
            args.verify_receipt_base64, args.old_protocol_base64, args.old_receipt_base64)):
        return (helper_main(args.cargo_helper_parent_pid, args.amendment_sha)
                if args.cargo_helper_parent_pid is not None else native_main(args.amendment_sha))
    require(args.cargo_helper_parent_pid is None, 'verifier cannot be a Cargo helper')
    require(args.old_protocol_base64 and args.old_receipt_base64, 'old evidence wire required')
    protocol_data, receipt_data = map(decode_wire, (args.old_protocol_base64, args.old_receipt_base64))
    if args.verify_amendment_base64:
        require(args.amendment_sha and not args.amendment_base64 and not args.verify_receipt_base64,
                'amendment verifier arguments')
        data = decode_wire(args.verify_amendment_base64)
        amendment, _, _ = validate_bundle(data, args.amendment_sha, protocol_data, receipt_data)
        result = dict(schema=1, protocol=PROTOCOL, verified=True, amendment_sha256=args.amendment_sha,
            old_receipt_sha256=OLD_RECEIPT_SHA, snapshot_sha256=amendment['snapshot_sha256'])
    else:
        require(args.amendment_base64 and args.verify_receipt_base64 and not args.amendment_sha,
                'receipt verifier arguments')
        data = decode_wire(args.amendment_base64)
        amendment_sha = digest(data)
        amendment, old, protocol = validate_bundle(data, amendment_sha, protocol_data, receipt_data)
        result = validate_retry_receipt(decode_wire(args.verify_receipt_base64), amendment, amendment_sha, old, protocol)
    sys.stdout.buffer.write(canonical(result))
    return 0


if __name__ == '__main__':
    sys.exit(main())
