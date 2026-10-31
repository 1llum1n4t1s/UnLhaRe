#!/usr/bin/env python3
"""Finite Canterbury11 training/reference pilot; no superiority decision.

All inputs use ZIP's fixed 1980-01-01 epoch. Metadata representations differ
between formats; comparisons concern complete archive sizes, not payload alone.
"""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import platform
import re
import stat
import sys
import time
import zipfile

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
RUN = ROOT/'tmp/mac-canterbury-reference-20261026'
PREFIX = 'mac-canterbury-reference'
SETUP_SHA = '9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
BUILD_SHA = '9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb'
MANIFEST_SHA = 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
SOURCE_CONTAINER_SHA = 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
REASON = 'canterbury-training-reference-pilot-no-superiority-decision'
PINS = dict(source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f',
            cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629',
            sevenzip_sha256='8e495531e1b2b8cb169ca583493922d4ab386007756418c15b95f07f642c35fb',
            e2e_passed_receipt_sha256='0f9b1a1cb744775b64c7cdcbb485efebb2e5f4ba2cf0d58c99ee903255676299',
            input_manifest_sha256='458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af',
            input_zip_sha256='29d1f681371d50819a904a9fc4639c276268fa631b709f9b4afe9398857d7b71',
            system_metrics_sha256='31955203a22b4128b956e86daa4bffb653e513bb31682d63a9b8b5941df8d5ba')
CLI = ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli'
SEVEN = ROOT/'tools/7zip/7zz'
METRICS = ROOT/'tools/mac-native-system-metrics'
HELPER = ROOT/'tools/mac-canterbury-measure.py'
INPUT_NAMES = ('alice29.txt', 'asyoulik.txt', 'cp.html', 'fields.c', 'grammar.lsp',
               'kennedy.xls', 'lcet10.txt', 'plrabn12.txt', 'ptt5', 'sum', 'xargs.1')
MAX_BYTES, MAX_ENTRIES = 160*1024**2, 512
FINALIZATION_RESERVE_SECONDS = 10


class Refusal(RuntimeError):
    pass


class Stop(Refusal):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)+'\n').encode('utf-8')


def expected_protocol(endpoint_sha, measurement_sha):
    profiles = [dict(id='khc', strategy='portfolio-trial', encode_workers=1, decode_workers=1)]
    common = dict(level=9, solid=True, sort_by_type=True, store_mtime=True,
                  store_ctime=False, store_atime=False, encode_workers=1, decode_workers=1)
    profiles += [dict(common, id='lzma2', dictionary_bytes=8388608, fast_bytes=273),
                 dict(common, id='ppmd', memory_bytes=67108864, order=16)]
    return dict(schema=1, protocol='khc-mac-canterbury-reference-v1', task='goal-restore-20261019',
                host='m3mb14', root=ROOT.as_posix(), run='mac-canterbury-reference-20261026',
                purpose='training-reference-only', superiority_decision_allowed=False,
                windows_max_bytes=8388608, windows_max_entries=96, windows_timeout_seconds=1800,
                remote_max_bytes=MAX_BYTES, remote_max_entries=MAX_ENTRIES,
                campaign_seconds=1700, encode_seconds=60, decode_seconds=20,
                cpu_baseline_limit_percent=15, cpu_interval_limit_percent=30,
                thermal_state_required=0, ac_power_required=True,
                rss_eligibility_bytes=134217728, cpu_per_wall_eligibility_max=1.2,
                warmups=1, orders=['ABC','BCA','CAB','ACB','CBA','BAC'], method_profiles=profiles,
                endpoint_sha256=endpoint_sha, measurement_sha256=measurement_sha, reason=REASON, **PINS)


def validate_protocol(value, endpoint_sha):
    require(type(value) is dict and len(value) == 35, 'protocol shape')
    for key in ('endpoint_sha256', 'measurement_sha256'):
        require(type(value.get(key)) is str and re.fullmatch('[0-9a-f]{64}', value[key]) is not None,
                'protocol executable hash')
    require(canonical(value) == canonical(expected_protocol(endpoint_sha, value['measurement_sha256'])),
            'fixed protocol mismatch')


def validate_environment(value):
    require(type(value) is dict and set(value) == {'schema','cpu_ticks','logical_cpus','thermal_state','ac_power'},
            'environment fields')
    require(type(value['schema']) is int and value['schema'] == 1 and
            type(value['logical_cpus']) is int and value['logical_cpus'] == 14 and
            type(value['thermal_state']) is int and 0 <= value['thermal_state'] <= 3 and
            type(value['ac_power']) is bool and type(value['cpu_ticks']) is list and
            len(value['cpu_ticks']) == 4 and
            all(type(n) is int and 0 <= n < 2**32 for n in value['cpu_ticks']), 'environment types/ranges')
    return value


def environment_ok(value):
    validate_environment(value)
    return value['thermal_state'] == 0 and value['ac_power']


def cpu_percent(before, after):
    validate_environment(before)
    validate_environment(after)
    deltas = [(b-a) % 2**32 for a,b in zip(before['cpu_ticks'], after['cpu_ticks'])]
    require(sum(deltas) > 0, 'CPU observation unavailable: zero tick interval')
    return 100*(sum(deltas)-deltas[2])/sum(deltas)


def validate_metric(value, seconds):
    fields = {'elapsed_ns','user_seconds','system_seconds','peak_rss_bytes','cpu_per_wall',
              'normal_exit','exit_code','signal','cpu_interval_percent','environment_before','environment_after'}
    require(type(value) is dict and set(value) == fields, 'metric fields')
    require(all(type(value[k]) is int and value[k] > 0 for k in ('elapsed_ns','peak_rss_bytes')), 'metric ns/bytes')
    require(all(type(value[k]) in (int,float) and math.isfinite(value[k]) and value[k] >= 0
                for k in ('user_seconds','system_seconds','cpu_per_wall','cpu_interval_percent')), 'metric finite values')
    require(value['normal_exit'] is True and type(value['exit_code']) is int and value['exit_code'] == 0 and
            value['signal'] is None, 'measured CLI did not exit normally with zero status')
    ratio = (value['user_seconds']+value['system_seconds'])/(value['elapsed_ns']/1e9)
    require(abs(value['cpu_per_wall']-ratio) <= max(1e-9,abs(ratio)*1e-6), 'CPU/wall representation')
    observed = cpu_percent(value['environment_before'], value['environment_after'])
    require(value['cpu_interval_percent'] <= 100 and abs(value['cpu_interval_percent']-observed) <= 1e-6,
            'CPU interval representation')
    host_ok = (environment_ok(value['environment_before']) and environment_ok(value['environment_after'])
               and value['cpu_interval_percent'] <= 30)
    # RSS and CPU/wall are post-hoc eligibility, not OS isolation or quotas.
    resources_ok = (value['peak_rss_bytes'] <= 134217728 and value['cpu_per_wall'] <= 1.2 and
                    value['elapsed_ns'] <= seconds*1000000000)
    return host_ok, resources_ok


def schedule():
    return [(round_index-1, position, round_index == 0, letter)
            for round_index, order in enumerate(['ABC','ABC','BCA','CAB','ACB','CBA','BAC'])
            for position, letter in enumerate(order)]


def runtime_seconds_left(elapsed):
    left = 1700-FINALIZATION_RESERVE_SECONDS-elapsed
    require(left > 0, 'campaign runtime deadline; finalization reserve')
    return left


def finalized_outcome(status, error, elapsed):
    if elapsed > 1700:
        return 'failed', (((error+'; ') if error else '')+'campaign deadline exceeded during finalization')[:4096]
    return status, error


def codec_commands(letter, source, archive, decoded):
    if letter == 'A':
        return ([str(CLI),'khc-create',str(archive),'--source',str(source),'--strategy','portfolio-trial'],
                [str(CLI),'khc-extract',str(archive),'--output',str(decoded)])
    require(letter in 'BC', 'unknown method')
    method = '-m0=LZMA2:d=8m:fb=273' if letter == 'B' else '-m0=PPMd:mem=64m:o=16'
    return ([str(SEVEN),'a',str(archive),'-t7z','-mx=9',method,'-mmt=1','-ms=on','-mqs=on',
             '-mtm=on','-mta=off','-mtc=off','--']+list(INPUT_NAMES),
            [str(SEVEN),'x',str(archive),'-o'+str(decoded),'-y','-mmt=1'])


def manifest_digest(entries):
    require(type(entries) is list and 0 < len(entries) <= 11, 'manifest entry count')
    seen, lines = set(), []
    for row in entries:
        require(type(row) is dict and set(row) == {'name','bytes','sha256'}, 'manifest entry fields')
        name, length, sha = row['name'], row['bytes'], row['sha256']
        require(type(name) is str and re.fullmatch('[A-Za-z0-9_.-]+', name) is not None and
                name not in ('.','..') and name.casefold() not in seen, 'manifest name/duplicate')
        require(type(length) is int and 0 <= length <= 2810784 and type(sha) is str and
                re.fullmatch('[0-9a-f]{64}', sha) is not None, 'manifest size/hash')
        seen.add(name.casefold())
        lines.append('%s\t%d\t%s\n' % (name,length,sha))
    return digest(''.join(lines).encode('utf-8'))


def read_bounded(path, maximum, expected=None):
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size <= maximum,
            'input type/bound: '+str(path))
    with path.open('rb') as stream:
        data = stream.read(maximum+1)
    require(len(data) <= maximum and (expected is None or digest(data) == expected), 'input bytes/hash: '+str(path))
    return data


def load_json(data):
    def pairs(rows):
        result = {}
        for key,value in rows:
            require(key not in result, 'duplicate JSON field')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_constant=lambda _: (_ for _ in ()).throw(Refusal('nonfinite JSON')))


def write_json(path, value, maximum):
    data = canonical(value)
    require(len(data) <= maximum, 'JSON output bound')
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    return data


def load_module(path, name, expected):
    read_bounded(path, 128*1024, expected)
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def local_counts():
    require(RUN.is_dir() and not RUN.is_symlink() and RUN.stat().st_uid == os.getuid(), 'run directory changed')
    count, total = 1, 0
    def failed(error):
        raise Refusal('run walk failed: '+str(error)) from error
    for directory, dirs, files in os.walk(str(RUN), followlinks=False, onerror=failed):
        for name in dirs+files:
            metadata = (Path(directory)/name).lstat()
            require(metadata.st_uid == os.getuid() and not stat.S_ISLNK(metadata.st_mode) and
                    (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)) and
                    (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink == 1), 'run object changed')
            count += 1
            if stat.S_ISREG(metadata.st_mode):
                total += metadata.st_size
    require(count <= MAX_ENTRIES and total <= MAX_BYTES, 'run storage bound')
    return total, count


def verify_files(directory, entries):
    require(directory.is_dir() and not directory.is_symlink(), 'missing restored directory')
    require(sorted(p.name for p in directory.iterdir()) == sorted(INPUT_NAMES), 'restored/input file set')
    observed = []
    for record in entries:
        data = read_bounded(directory/record['name'], record['bytes'], record['sha256'])
        require(len(data) == record['bytes'], 'restored byte length')
        observed.append(dict(name=record['name'], bytes=len(data), sha256=digest(data)))
    require(manifest_digest(observed) == MANIFEST_SHA, 'restored full manifest')


def zip_leaf(name):
    require(type(name) is str and name.startswith('input/') and name[6:] in INPUT_NAMES,
            'input ZIP exact transport prefix/name')
    return name[6:]


def extract_inputs(zip_bytes, manifest):
    entries = manifest['entries']
    require(set(manifest) == {'schema','corpus','purpose','files','bytes','manifest_sha256','source_container_sha256','entries'} and
            type(manifest['schema']) is int and manifest['schema'] == 1 and manifest['corpus'] == 'Canterbury11' and
            manifest['purpose'] == 'training-reference-only' and type(manifest['files']) is int and manifest['files'] == 11 and
            type(manifest['bytes']) is int and manifest['bytes'] == 2810784 and
            manifest['manifest_sha256'] == MANIFEST_SHA and manifest['source_container_sha256'] == SOURCE_CONTAINER_SHA and
            tuple(row['name'] for row in entries) == INPUT_NAMES and manifest_digest(entries) == MANIFEST_SHA and
            sum(row['bytes'] for row in entries) == 2810784, 'fixed input manifest')
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        members = archive.infolist()
        require(len(members) == 11 and {zip_leaf(p.filename) for p in members} == set(INPUT_NAMES), 'input ZIP names')
        for member in members:
            record = next(row for row in entries if row['name'] == zip_leaf(member.filename))
            require(not member.is_dir() and not member.flag_bits & 1 and member.compress_type == zipfile.ZIP_STORED and
                    stat.S_IFMT(member.external_attr >> 16) in (0,stat.S_IFREG) and
                    member.file_size == record['bytes'] and member.date_time == (1980,1,1,0,0,0), 'input ZIP member type/size/time')
        (RUN/'input').mkdir(mode=0o700)
        for member in members:
            record = next(row for row in entries if row['name'] == zip_leaf(member.filename))
            data = archive.read(member)
            require(len(data) == record['bytes'] and digest(data) == record['sha256'], 'input ZIP full SHA')
            path = RUN/'input'/zip_leaf(member.filename)
            with path.open('xb') as stream:
                stream.write(data)
            # Fixed ZIP metadata is retained explicitly by the manual extraction.
            os.utime(str(path), (315532800,315532800), follow_symlinks=False)
    verify_files(RUN/'input', entries)


def make_report(identity, trials, status, error):
    pins = {key:identity[key] for key in ('source_sha256','cli_sha256','sevenzip_sha256',
            'e2e_passed_receipt_sha256','input_manifest_sha256','input_zip_sha256')}
    return dict(schema=1, purpose='training-reference-only', superiority_decision_allowed=False, reason=REASON,
                windows_run_id=identity['windows_run_id'], protocol_sha256=identity['protocol_sha256'],
                input_files=11, input_bytes=2810784, rss_unit='bytes',
                time_scope='CLI spawn-to-wait4 including launch and scheduling',
                cpu_observation='host-tick interval averages before/after each CLI',
                trials=trials, status=status, error=error, **pins)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-run-id', required=True)
    parser.add_argument('--protocol-sha', required=True)
    parser.add_argument('--inspect', action='store_true')
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'Mac ARM64 only')
    require(re.fullmatch('[0-9a-f]{32}', args.windows_run_id) is not None and
            re.fullmatch('[0-9a-f]{64}', args.protocol_sha) is not None, 'endpoint identity')
    os.umask(0o077)
    require(Path(__file__).absolute() == ROOT/'tools/mac-canterbury-reference.py', 'endpoint location')
    endpoint_sha = digest(read_bounded(Path(__file__), 65536))
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup = load_module(setup_path, 'mac_reference_setup', SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT, private=True)
    protocol = load_json(read_bounded(ROOT/'downloads/mac-canterbury-reference-protocol.json',65536,args.protocol_sha))
    validate_protocol(protocol, endpoint_sha)
    identity = dict(schema=1, protocol='khc-mac-canterbury-reference-terminal-v1',
                    windows_run_id=args.windows_run_id, protocol_sha256=args.protocol_sha,
                    purpose='training-reference-only', superiority_decision_allowed=False, reason=REASON,
                    **{key:protocol[key] for key in list(PINS)+['endpoint_sha256','measurement_sha256']})
    terminal_path = ROOT/'journal'/(PREFIX+'.terminal.json')
    if args.inspect:
        data = read_bounded(terminal_path,65536)
        previous = load_json(data)
        require(all(previous.get(key) == value for key,value in identity.items()) and canonical(previous) == data,
                'canonical terminal identity/encoding')
        sys.stdout.write(data.decode('utf-8'))
        return previous['exit']
    # All identities are checked before the one-shot marker or any measured CLI.
    for relative, maximum, expected in (
            ('tools/mac-canterbury-measure.py',65536,protocol['measurement_sha256']),
            ('tools/mac-native-system-metrics',1024**2,PINS['system_metrics_sha256']),
            ('cargo-target/aarch64-apple-darwin/release/unlhare-cli',16*1024**2,PINS['cli_sha256']),
            ('tools/7zip/7zz',16*1024**2,PINS['sevenzip_sha256']),
            ('downloads/source.zip',8*1024**2,PINS['source_sha256'])):
        setup.checked_path(ROOT/relative)
        read_bounded(ROOT/relative,maximum,expected)
    passed = load_json(read_bounded(ROOT/'journal/mac-native-e2e-ps-free.terminal.json',65536,
                                   PINS['e2e_passed_receipt_sha256']))
    require(passed['exit'] == 0 and passed['status'] == 'passed' and passed['children_absent'] is True and
            passed['source_sha256'] == PINS['source_sha256'] and passed['cli_sha256'] == PINS['cli_sha256'], 'native correctness prerequisite')
    zip_bytes = read_bounded(ROOT/'downloads/mac-canterbury-input.zip',2811966,PINS['input_zip_sha256'])
    manifest = load_json(read_bounded(ROOT/'downloads/mac-canterbury-input-manifest.json',1988,PINS['input_manifest_sha256']))
    source = load_module(ROOT/'tools/mac-native-build.py','mac_reference_build',BUILD_SHA)
    inputs = load_json(read_bounded(ROOT/'journal/source-inputs.json',65536))
    require(inputs['source_sha256'] == PINS['source_sha256'], 'source snapshot identity')
    source.verify_source(ROOT, inputs['files'])
    setup.admit(ROOT,MAX_BYTES+65536)
    started = ROOT/'journal'/(PREFIX+'.started.json')
    require(not started.exists() and not terminal_path.exists() and not RUN.exists(), 'reference already attempted')
    setup.new_json(started,dict(identity,endpoint_pid=os.getpid(),parent_pid=os.getppid(),started_unix_ns=time.time_ns()))
    started_at = time.monotonic()
    supervisor = setup.Supervisor(ROOT)
    original_admit = setup.admit
    trials, sizes = [], {}
    status, error = 'completed-reference', None
    report_bytes = None
    def guard(root, extra=0):
        runtime_seconds_left(time.monotonic()-started_at)
        if RUN.exists():
            local_counts()
        return original_admit(root,extra)
    setup.admit = guard
    def pulse(extra_bytes=0, extra_entries=0):
        total, count = local_counts()
        require(total+extra_bytes <= MAX_BYTES and count+extra_entries <= MAX_ENTRIES, 'next call run admission')
        setup.admit(ROOT,extra_bytes+65536)
    def observe():
        left = runtime_seconds_left(time.monotonic()-started_at)
        value = load_json(supervisor.run(setup.sandbox_command(ROOT)+[str(METRICS)],timeout=min(5,left)))
        return validate_environment(value)
    def measured(command, output, cwd, seconds):
        pulse(16*1024**2,16)
        left = runtime_seconds_left(time.monotonic()-started_at)
        result = supervisor.run(setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(HELPER),
                '--output',str(output),'--metrics',str(METRICS),'--cwd',str(cwd),'--']+command,
                timeout=min(seconds,left),cwd=cwd)
        require(result == '', 'measurement helper must not emit stdout')
        metric = load_json(read_bounded(output,16384))
        pulse()
        host_ok, resource_ok = validate_metric(metric,seconds)
        return metric, host_ok, resource_ok
    try:
        RUN.mkdir(mode=0o700)
        extract_inputs(zip_bytes,manifest)
        previous = observe()
        if not environment_ok(previous):
            raise Stop('baseline thermal/AC requirement')
        for _ in range(2):
            time.sleep(1)
            current = observe()
            baseline = cpu_percent(previous,current)
            if not environment_ok(current) or baseline > 15:
                raise Stop('baseline host CPU/thermal/AC requirement')
            previous = current
        for index,(round_index,position,warmup,letter) in enumerate(schedule()):
            pulse(16*1024**2,16)
            verify_files(RUN/'input',manifest['entries'])
            method = {'A':'khc','B':'lzma2','C':'ppmd'}[letter]
            archive = RUN/('%02d-%s.%s' % (index,method,'khc' if letter == 'A' else '7z'))
            decoded = RUN/('%02d-decoded' % index)
            decoded.mkdir(mode=0o700)
            encode_command,decode_command = codec_commands(letter,RUN/'input',archive,decoded)
            enc, enc_host, enc_resource = measured(encode_command,RUN/('%02d-encode.json'%index),RUN/'input',60)
            if not enc_host:
                raise Stop('encode host CPU/thermal/AC requirement')
            if letter == 'A':
                frame = read_bounded(archive,16*1024**2)
                # Revision 10 is excluded by pipeline::eligible (only 4/5).
                # This fixed CLI therefore takes the serial decode path.
                require(frame[:8] == b'KHC1ARC\0' and frame[8:9] == b'\x0a', 'portfolio revision/serial decode path')
            dec, dec_host, dec_resource = measured(decode_command,RUN/('%02d-decode.json'%index),decoded,20)
            verify_files(decoded,manifest['entries'])
            archived = read_bounded(archive,16*1024**2)
            require(len(archived)>0 and (method not in sizes or sizes[method] == len(archived)), 'archive size changed across trials')
            sizes[method] = len(archived)
            trials.append(dict(method=method,warmup=warmup,round=round_index,position=position,
                               archive_bytes=len(archived),archive_sha256=digest(archived),
                               restored_manifest_sha256=MANIFEST_SHA,encode=enc,decode=dec))
            if not dec_host or not enc_resource or not dec_resource:
                raise Stop('post-pair host/resource eligibility requirement')
        require(len(trials) == 21, 'incomplete reference campaign')
    except BaseException as failure:
        status = 'stopped' if isinstance(failure,Stop) else 'failed'
        error = str(failure)[:4096]
    finally:
        setup.admit = original_admit
        try:
            source.verify_source(ROOT,inputs['files'])
            original_admit(ROOT)
            local_counts()
        except BaseException as failure:
            status,error = 'failed',(((error+'; ') if error else '')+str(failure))[:4096]
    absent = True
    if supervisor.process is not None:
        try:
            os.killpg(supervisor.process.pid,0)
            absent = False
        except ProcessLookupError:
            pass
    if not absent:
        status,error = 'failed','owned process group still present; no cleanup authorization'
    status,error = finalized_outcome(status,error,time.monotonic()-started_at)
    if RUN.is_dir():
        report_bytes = write_json(RUN/'report.json',make_report(identity,trials,status,error),32768)
    # A slow report fsync must not turn an expired campaign into canonical success.
    final_status,final_error = finalized_outcome(status,error,time.monotonic()-started_at)
    if (final_status,final_error) != (status,error):
        status,error,report_bytes = final_status,final_error,None
    terminal = dict(identity,children_absent=absent,exit=0 if status == 'completed-reference' else 1,
                    status=status,report_sha256=digest(report_bytes) if report_bytes else None,
                    report_base64=base64.b64encode(report_bytes).decode('ascii') if report_bytes else None,error=error)
    encoded = write_json(terminal_path,terminal,65536)
    sys.stdout.write(encoded.decode('utf-8'))
    return terminal['exit']


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BaseException as failure:
        if isinstance(failure,SystemExit):
            raise
        print(json.dumps({'error':str(failure)[:4096]}),file=sys.stderr,flush=True)
        sys.exit(1)
