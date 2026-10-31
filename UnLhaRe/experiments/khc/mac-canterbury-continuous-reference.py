#!/usr/bin/env python3
"""Prospective Canterbury11 continuous observation; training reference only.

One sandboxed helper owns observer thread and all CLI events. Timing epochs are
never subtracted across processes. Per-CLI limits are eligibility checks after
wait4, not hard watchdogs; the outer finite supervisor owns group closure.
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
import subprocess
import sys
import time
import zipfile

HERE = Path(__file__).absolute().parent
ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX = 'mac-canterbury-continuous-reference'
RUN = ROOT/'tmp'/f'{PREFIX}-20261027'
REFERENCE_SHA = 'a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4'
OBSERVER_SHA = '416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
SUPERVISOR_SHA = '51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
CONTINUOUS_E2E_SHA = 'e30e1bcee8ecab6358e3cf6d73483f97393575fe934b75df2ec96c8f4eaf9478'
CLOSED_SHA = 'ff13dcf396a3d0ebadb306d457d0e0a361aeb208cfa7a2775506dc5fc5a0715c'
MAX_BYTES, MAX_ENTRIES = 160*1024**2, 512
JOURNAL_RESERVED_BYTES, JOURNAL_RESERVED_ENTRIES = 196608, 4
RAW_LIMIT, REPORT_LIMIT, TERMINAL_LIMIT = 65536, 32768, 65536
PROTOCOL = 'khc-mac-canterbury-continuous-reference-v1'
TERMINAL = 'khc-mac-canterbury-continuous-reference-terminal-v1'
REASON = 'canterbury-continuous-training-reference-no-superiority-decision'


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False)+'\n').encode()


def digest(value):
    return hashlib.sha256(value).hexdigest()


def load(path, name, expected):
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1 and metadata.st_size <= 131072,
            'dependency type/bound')
    require(digest(path.read_bytes()) == expected, 'dependency SHA: '+str(path))
    spec = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Frozen functions are reused without invoking main or modifying its globals.
REF = load(HERE/'mac-canterbury-reference.py', 'continuous_frozen_reference', REFERENCE_SHA)
OBS = load(HERE/'mac-continuous-cpu-observer.py', 'continuous_reference_observer', OBSERVER_SHA)
FS = load(HERE/'mac-finite-supervisor.py', 'continuous_reference_supervisor', SUPERVISOR_SHA)
schedule = REF.schedule


def codec_commands(letter, source, archive, decoded):
    # Windows純粋再検証でもMac上と同じ絶対パス表現にする。
    return tuple([arg.replace('\\','/') for arg in command]
                 for command in REF.codec_commands(letter,source,archive,decoded))


def valid_sha(value):
    return type(value) is str and re.fullmatch('[0-9a-f]{64}', value) is not None


def expected_protocol(endpoint_sha):
    require(valid_sha(endpoint_sha), 'endpoint SHA')
    legacy = REF.expected_protocol(endpoint_sha, endpoint_sha)
    # Independent type: legacy campaign timing and before/after CPU do not apply.
    names = ('task','host','purpose','superiority_decision_allowed','encode_seconds','decode_seconds',
             'thermal_state_required','ac_power_required','rss_eligibility_bytes','cpu_per_wall_eligibility_max',
             'warmups','orders','method_profiles')
    return dict(schema=1, protocol=PROTOCOL, root=ROOT.as_posix(), run=RUN.name,
        endpoint_sha256=endpoint_sha, reference_sha256=REFERENCE_SHA, observer_sha256=OBSERVER_SHA,
        supervisor_sha256=SUPERVISOR_SHA, setup_sha256=REF.SETUP_SHA, build_sha256=REF.BUILD_SHA,
        continuous_e2e_receipt_sha256=CONTINUOUS_E2E_SHA, closed_receipt_sha256=CLOSED_SHA,
        remote_max_bytes=MAX_BYTES, remote_max_entries=MAX_ENTRIES,
        journal_reserved_bytes=JOURNAL_RESERVED_BYTES, journal_reserved_entries=JOURNAL_RESERVED_ENTRIES,
        observer_captures=64, cadence_ns=1250000000, entry_windows=3,
        cpu_baseline_limit_percent=15, cpu_interval_limit_percent=30,
        codec_pairs=21, codec_invocations=42, runtime_seconds=90,
        helper_timeout_seconds=100, final_elapsed_limit_seconds=120,
        raw_json_max_bytes=RAW_LIMIT, report_max_bytes=REPORT_LIMIT, terminal_max_bytes=TERMINAL_LIMIT,
        archive_max_bytes=RAW_LIMIT*48,
        windows_max_bytes=8388608, windows_max_entries=96, windows_timeout_seconds=180,
        failure_helper_exit=70, hard_watchdog_guaranteed=False, final_event_before_capture=63,
        reason=REASON, **{k:legacy[k] for k in names}, **REF.PINS)


def validate_protocol(value, endpoint_sha):
    require(type(value) is dict and canonical(value) == canonical(expected_protocol(endpoint_sha)),
            'fixed continuous protocol mismatch')


def quota_counts(total, count):
    require(type(total) is int and type(count) is int and total >= 0 and count >= 1, 'quota types')
    charged, entries = total+JOURNAL_RESERVED_BYTES, count+JOURNAL_RESERVED_ENTRIES
    require(charged <= MAX_BYTES and entries <= MAX_ENTRIES, 'aggregate run+journal quota')
    return dict(run_bytes=total, run_entries=count, journal_reserved_bytes=JOURNAL_RESERVED_BYTES,
                journal_reserved_entries=JOURNAL_RESERVED_ENTRIES, charged_bytes=charged, charged_entries=entries)


def local_counts():
    require(RUN.is_dir() and not RUN.is_symlink(), 'run directory')
    total, count = 0, 1
    def failed(error):
        raise Refusal('run walk failed') from error
    for directory, dirs, files in os.walk(RUN, followlinks=False, onerror=failed):
        for name in dirs+files:
            info = (Path(directory)/name).lstat()
            require(info.st_uid == os.getuid() and not stat.S_ISLNK(info.st_mode) and
                    (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) and
                    (not stat.S_ISREG(info.st_mode) or info.st_nlink == 1), 'run object type/owner/link')
            count += 1
            if stat.S_ISREG(info.st_mode): total += info.st_size
    return quota_counts(total, count)


def write(path, value, maximum=RAW_LIMIT):
    return REF.write_json(path, value, maximum)


def read_json(path, maximum=RAW_LIMIT, expected=None, *, canonical_required=False):
    data = REF.read_bounded(path, maximum, expected)
    value = REF.load_json(data)
    if canonical_required:
        require(canonical(value) == data, 'noncanonical JSON: '+str(path))
    return value


def validate_metric(row, seconds):
    fields = {'elapsed_ns','user_seconds','system_seconds','peak_rss_bytes','normal_exit',
              'exit_code','signal','cpu_per_wall'}
    require(type(row) is dict and set(row) == fields, 'metric fields')
    require(all(type(row[k]) is int and row[k] > 0 for k in ('elapsed_ns','peak_rss_bytes')), 'metric integers')
    require(all(type(row[k]) in (int,float) and math.isfinite(row[k]) and row[k] >= 0
                for k in ('user_seconds','system_seconds','cpu_per_wall')), 'metric numbers')
    ratio = (row['user_seconds']+row['system_seconds'])*1e9/row['elapsed_ns']
    require(math.isclose(ratio, row['cpu_per_wall'], rel_tol=1e-12, abs_tol=1e-12), 'CPU/wall recomputation')
    require(row['normal_exit'] is True and type(row['exit_code']) is int and row['exit_code'] == 0 and
            row['signal'] is None, 'CLI failed')
    require(row['elapsed_ns'] <= seconds*1e9 and row['peak_rss_bytes'] <= 128*1024**2 and ratio <= 1.2,
            'post-wait4 eligibility limit')


def validate_observation(raw):
    check = OBS.validate_report(raw)
    require(check['eligible'] and raw['max_captures'] == 64 and len(raw['captures']) == 64 and
            len(raw['events']) == 42, 'continuous CPU/capture/event eligibility: '+str(check['errors'])[:1000])
    require(all(type(e['end_ns']) is int for e in raw['events']) and
            raw['events'][-1]['end_ns'] < raw['captures'][63]['start_ns'], 'final event before final capture')
    require(all(a['end_ns'] <= b['start_ns'] for a,b in zip(raw['events'],raw['events'][1:])),
            'CLI events overlap or reorder')
    return check


def evidence_plan():
    return [('capture', i, f'capture-{i:02d}.json') for i in range(64)] + [
        ('cli', i, f'cli-{i:02d}.json') for i in range(42)] + [
        ('pair', i, f'pair-{i:02d}.json') for i in range(21)]


def summary_skeleton():
    return dict(schema=1, protocol=PROTOCOL, purpose='training-reference-only', superiority_decision_allowed=False,
        windows_run_id='f'*32, protocol_sha256='f'*64, status='completed-reference',
        observation=dict(schema=1,cadence_ns=1250000000,max_captures=64,completed=True,failure=None),
        evidence=[dict(kind=k,id=i,path=p,bytes=RAW_LIMIT,sha256='f'*64) for k,i,p in evidence_plan()],
        pairs=21,codec_invocations=42,captures=64,input_files=11,input_bytes=2810784,
        rss_unit='bytes',time_scope='CLI spawn-to-wait4 including launch and scheduling',
        cpu_observation='single-helper continuous 1.25s host CPU tick windows',
        cpu_summary=dict(entry_max_percent=15,runtime_max_percent=30),reason=REASON)


def validate_output_budget():
    report = canonical(summary_skeleton())
    terminal = dict(schema=1,protocol=TERMINAL,windows_run_id='f'*32,protocol_sha256='f'*64,
                    report_base64=base64.b64encode(report).decode(),report_sha256='f'*64,error='e'*2048,
                    status='completed-reference',closure_sha256='f'*64)
    require(len(report) <= REPORT_LIMIT and len(canonical(terminal))+4096 <= TERMINAL_LIMIT,
            'preflight receipt budget')
    require(127*RAW_LIMIT+REPORT_LIMIT+2*RAW_LIMIT+21*(RAW_LIMIT*48+2810784)+
            2810784+JOURNAL_RESERVED_BYTES <= MAX_BYTES, 'preflight output byte budget')
    require(1+1+11+21*(1+1+11)+127+4+JOURNAL_RESERVED_ENTRIES <= MAX_ENTRIES,
            'preflight output entry budget')


def validate_report(report, protocol, run_id, raw_reader):
    """Pure revalidation; raw_reader(relative_path) returns exact stored JSON bytes."""
    validate_protocol(protocol, protocol.get('endpoint_sha256'))
    expected = summary_skeleton()
    require(type(report) is dict and set(report) == set(expected), 'report fields')
    require(type(run_id) is str and re.fullmatch('[0-9a-f]{32}',run_id), 'report run id')
    for key in set(expected)-{'windows_run_id','protocol_sha256','evidence','cpu_summary'}:
        require(canonical(report[key]) == canonical(expected[key]), 'report '+key)
    require(report['windows_run_id'] == run_id and report['protocol_sha256'] == digest(canonical(protocol)),
            'report identity')
    require(len(canonical(report)) <= REPORT_LIMIT and type(report['evidence']) is list and
            len(report['evidence']) == 127, 'report evidence count/bound')
    values = {'capture':[], 'cli':[], 'pair':[]}
    for row, (kind,index,path) in zip(report['evidence'], evidence_plan()):
        require(type(row) is dict and set(row) == {'kind','id','path','bytes','sha256'} and
                row['kind'] == kind and type(row['id']) is int and row['id'] == index and row['path'] == path and
                type(row['bytes']) is int and 0 < row['bytes'] <= RAW_LIMIT and valid_sha(row['sha256']),
                'evidence plan/shape')
        data = raw_reader(path)
        require(type(data) is bytes and len(data) == row['bytes'] and digest(data) == row['sha256'], 'raw bytes/hash')
        value = REF.load_json(data)
        require(canonical(value) == data, 'raw canonical encoding')
        values[kind].append(value)
    events = []
    plan = schedule()
    for index,row in enumerate(values['cli']):
        pair, direction = divmod(index,2)
        require(set(row) == {'schema','id','pair','direction','command','event','metric'} and
                type(row['schema']) is int and row['schema'] == 1 and type(row['id']) is int and row['id'] == index and
                type(row['pair']) is int and row['pair'] == pair and row['direction'] == ('encode','decode')[direction],
                'CLI fixed order')
        archive, decoded = pair_paths(pair,plan[pair][3])
        command = codec_commands(plan[pair][3],RUN/'input',archive,decoded)[direction]
        require(row['command'] == command and row['event']['id'] == index, 'planned CLI/event')
        validate_metric(row['metric'], (60,20)[direction])
        require(row['event']['end_ns']-row['event']['start_ns'] >= row['metric']['elapsed_ns'], 'event/timing containment')
        events.append(row['event'])
    for index,row in enumerate(values['pair']):
        archive, decoded = pair_paths(index,plan[index][3])
        require(set(row) == {'schema','id','schedule','archive','archive_bytes','archive_sha256','decoded','restored'} and
                type(row['schema']) is int and row['schema'] == 1 and type(row['id']) is int and row['id'] == index and
                row['schedule'] == list(plan[index]) and row['archive'] == archive.name and
                row['decoded'] == decoded.name and type(row['archive_bytes']) is int and 0 < row['archive_bytes'] <= RAW_LIMIT*48 and
                valid_sha(row['archive_sha256']), 'pair plan/archive')
        require(tuple(r['name'] for r in row['restored']) == REF.INPUT_NAMES and
                REF.manifest_digest(row['restored']) == REF.MANIFEST_SHA and
                sum(r['bytes'] for r in row['restored']) == 2810784, 'complete restored file hashes')
    raw = dict(report['observation'],captures=values['capture'],events=events)
    check = validate_observation(raw)
    summary = dict(entry_max_percent=max(w['cpu_percent'] for w in check['windows'][:3]),
                   runtime_max_percent=max(w['cpu_percent'] for w in check['windows'][3:]))
    require(canonical(report['cpu_summary']) == canonical(summary), 'CPU summary recomputation')
    return raw


def pair_paths(index, letter):
    return RUN/f'{index:02d}-archive.{"khc" if letter == "A" else "7z"}', RUN/f'{index:02d}-decoded'


def extract_inputs(zip_bytes, manifest):
    """Same frozen ZIP checks, with an explicitly new destination."""
    entries = manifest['entries']
    require(tuple(row['name'] for row in entries) == REF.INPUT_NAMES and
            REF.manifest_digest(entries) == REF.MANIFEST_SHA and manifest['manifest_sha256'] == REF.MANIFEST_SHA and
            manifest['source_container_sha256'] == REF.SOURCE_CONTAINER_SHA and manifest['files'] == 11 and
            manifest['bytes'] == 2810784 and manifest['purpose'] == 'training-reference-only', 'fixed input manifest')
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as archive:
        members = archive.infolist()
        require(len(members) == 11 and {REF.zip_leaf(m.filename) for m in members} == set(REF.INPUT_NAMES), 'ZIP file set')
        (RUN/'input').mkdir(mode=0o700)
        for member in members:
            row = next(r for r in entries if r['name'] == REF.zip_leaf(member.filename))
            require(not member.is_dir() and not member.flag_bits & 1 and member.compress_type == zipfile.ZIP_STORED and
                    stat.S_IFMT(member.external_attr >> 16) in (0,stat.S_IFREG) and
                    member.file_size == row['bytes'] and member.date_time == (1980,1,1,0,0,0), 'ZIP member type/size/time')
            data = archive.read(member)
            require(len(data) == row['bytes'] and digest(data) == row['sha256'], 'ZIP content SHA')
            path = RUN/'input'/row['name']
            with path.open('xb') as stream: stream.write(data)
            os.utime(path,(315532800,315532800),follow_symlinks=False)
    REF.verify_files(RUN/'input', entries)


def child(parent_pid, run_id, protocol_sha):
    require(parent_pid == os.getppid() and parent_pid != 1, 'helper parent')
    identity = read_json(ROOT/'journal'/(PREFIX+'.started.json'))
    require(identity['endpoint_pid'] == parent_pid and identity['windows_run_id'] == run_id and
            identity['protocol_sha256'] == protocol_sha and identity['endpoint_sha256'] == digest(Path(__file__).read_bytes()),
            'helper identity')
    manifest = read_json(ROOT/'downloads/mac-canterbury-input-manifest.json',1988,REF.PINS['input_manifest_sha256'])
    evidence = {}
    def save(kind,index,value):
        path = {'capture':f'capture-{index:02d}.json','cli':f'cli-{index:02d}.json','pair':f'pair-{index:02d}.json'}[kind]
        data = write(RUN/path,value)
        evidence[path] = dict(kind=kind,id=index,path=path,bytes=len(data),sha256=digest(data))
    def capture():
        result = subprocess.run([str(REF.METRICS)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=.2,check=True)
        require(not result.stderr and len(result.stdout) <= 4096, 'native metric output')
        return REF.load_json(result.stdout)
    def fail(error, partial):
        try:
            write(RUN/'failure.json',dict(schema=1,error_type=type(error).__name__,error=str(error)[:2048],
                                         captured=len(partial),exit=70))
        finally:
            os._exit(70)
    observer = OBS.Observer(capture,on_failure=fail,on_capture=lambda r:save('capture',r['id'],r),max_captures=64)
    observer.start()
    try:
        require(observer.wait_entry_ready(6), 'entry timeout')
        os.chdir(RUN/'input')
        for index,item in enumerate(schedule()):
            REF.verify_files(RUN/'input',manifest['entries'])
            archive, decoded = pair_paths(index,item[3])
            decoded.mkdir(mode=0o700)
            commands = codec_commands(item[3],RUN/'input',archive,decoded)
            for direction,command in enumerate(commands):
                actions = [(os.POSIX_SPAWN_OPEN,n,'/dev/null',os.O_RDONLY if n == 0 else os.O_WRONLY,0) for n in range(3)]
                token = observer.begin_event()
                start = time.monotonic_ns()
                pid = os.posix_spawn(command[0],command,dict(os.environ),file_actions=actions)
                waited,status,usage = os.wait4(pid,0)
                ended = time.monotonic_ns()
                event = observer.finish_event(token)
                require(waited == pid, 'wait4 PID')
                normal = os.WIFEXITED(status)
                metric = dict(elapsed_ns=ended-start,user_seconds=usage.ru_utime,system_seconds=usage.ru_stime,
                    peak_rss_bytes=usage.ru_maxrss,normal_exit=normal,
                    exit_code=os.WEXITSTATUS(status) if normal else None,
                    signal=os.WTERMSIG(status) if os.WIFSIGNALED(status) else None,
                    cpu_per_wall=(usage.ru_utime+usage.ru_stime)*1e9/(ended-start))
                save('cli',token,dict(schema=1,id=token,pair=index,direction=('encode','decode')[direction],
                    command=command,event={k:event[k] for k in ('id','start_ns','end_ns')},metric=metric))
                validate_metric(metric,(60,20)[direction])
            REF.verify_files(decoded,manifest['entries'])
            data = REF.read_bounded(archive,RAW_LIMIT*48)
            save('pair',index,dict(schema=1,id=index,schedule=list(item),archive=archive.name,
                archive_bytes=len(data),archive_sha256=digest(data),decoded=decoded.name,restored=manifest['entries']))
            local_counts()
        require(observer.join(85), 'fixed capture completion timeout')
        raw = observer.report()
        check = validate_observation(raw)
        report = summary_skeleton()
        report.update(windows_run_id=run_id,protocol_sha256=protocol_sha,
            evidence=[evidence[p] for _,_,p in evidence_plan()],cpu_summary=dict(
                entry_max_percent=max(w['cpu_percent'] for w in check['windows'][:3]),
                runtime_max_percent=max(w['cpu_percent'] for w in check['windows'][3:])))
        write(RUN/'report.json',report,REPORT_LIMIT)
    except BaseException as error:
        fail(error,observer.report()['captures'])


def dependency_pins():
    return [(HERE/'mac-canterbury-reference.py',REFERENCE_SHA,131072),
        (HERE/'mac-continuous-cpu-observer.py',OBSERVER_SHA,131072),
        (HERE/'mac-finite-supervisor.py',SUPERVISOR_SHA,131072),
        (HERE/'mac-native-build.py',REF.BUILD_SHA,131072),
        (REF.CLI,REF.PINS['cli_sha256'],16*1024**2),(REF.SEVEN,REF.PINS['sevenzip_sha256'],16*1024**2),
        (REF.METRICS,REF.PINS['system_metrics_sha256'],1024**2),
        (ROOT/'downloads/source.zip',REF.PINS['source_sha256'],8*1024**2),
        (ROOT/'downloads/mac-canterbury-input.zip',REF.PINS['input_zip_sha256'],2811966),
        (ROOT/'downloads/mac-canterbury-input-manifest.json',REF.PINS['input_manifest_sha256'],1988),
        (ROOT/'journal/mac-native-e2e-ps-free.terminal.json',REF.PINS['e2e_passed_receipt_sha256'],65536),
        (ROOT/'journal/mac-canterbury-reference.terminal.json',CLOSED_SHA,65536),
        (ROOT/'journal/mac-continuous-observer-e2e-v2-20261027.terminal.json',CONTINUOUS_E2E_SHA,65536)]


def preflight(setup):
    setup.checked_path(ROOT,private=True)
    for path,expected,maximum in dependency_pins():
        setup.checked_path(path)
        require(path.stat().st_uid == os.getuid(), 'dependency UID')
        REF.read_bounded(path,maximum,expected)
    passed = read_json(ROOT/'journal/mac-native-e2e-ps-free.terminal.json')
    require(passed['status'] == 'passed' and passed['exit'] == 0 and passed['children_absent'] is True,
            'native correctness prerequisite')
    e2e = read_json(ROOT/'journal/mac-continuous-observer-e2e-v2-20261027.terminal.json')
    require(e2e['status'] == 'completed-no-codec-e2e' and len(e2e['phases']) == 2, 'continuous E2E prerequisite')
    source = load(HERE/'mac-native-build.py','continuous_source_verify',REF.BUILD_SHA)
    setup.checked_path(ROOT/'journal/source-inputs.json')
    inputs = read_json(ROOT/'journal/source-inputs.json')
    require(inputs['source_sha256'] == REF.PINS['source_sha256'], 'source snapshot identity')
    source.verify_source(ROOT,inputs['files'])
    return source,inputs


def identity_for(run_id, protocol_sha, endpoint_sha):
    return dict(schema=1,protocol=TERMINAL,windows_run_id=run_id,protocol_sha256=protocol_sha,
        purpose='training-reference-only',superiority_decision_allowed=False,reason=REASON,
        endpoint_sha256=endpoint_sha,observer_sha256=OBSERVER_SHA,supervisor_sha256=SUPERVISOR_SHA,
        reference_sha256=REFERENCE_SHA,continuous_e2e_receipt_sha256=CONTINUOUS_E2E_SHA,**REF.PINS)


def validate_terminal(terminal, protocol, run_id, raw_reader):
    """Recompute identity, report and closure for success and failure receipts."""
    validate_protocol(protocol,protocol.get('endpoint_sha256'))
    identity = identity_for(run_id,digest(canonical(protocol)),protocol['endpoint_sha256'])
    extra = {'status','error','exit','children_absent','closure_sha256','counts','elapsed_seconds',
             'report_sha256','report_base64'}
    require(type(terminal) is dict and set(terminal) == set(identity)|extra, 'terminal fields')
    require(all(canonical(terminal[k]) == canonical(v) for k,v in identity.items()), 'terminal identity')
    require(terminal['status'] in ('completed-reference','failed') and
            type(terminal['exit']) is int and type(terminal['children_absent']) is bool,
            'terminal status/exit/types')
    success = terminal['status'] == 'completed-reference'
    require(terminal['exit'] == (0 if success else 1) and
            ((success and terminal['error'] is None) or
             (not success and type(terminal['error']) is str and 0 < len(terminal['error']) <= 4096)), 'terminal outcome')
    require(type(terminal['elapsed_seconds']) in (int,float) and math.isfinite(terminal['elapsed_seconds']) and
            terminal['elapsed_seconds'] >= 0 and (not success or terminal['elapsed_seconds'] <= 120), 'terminal elapsed')
    counts = terminal['counts']
    if counts is not None:
        require(type(counts) is dict and set(counts) == set(quota_counts(0,1)) and
                canonical(counts) == canonical(quota_counts(counts['run_bytes'],counts['run_entries'])), 'terminal counts')
    require(not success or counts is not None, 'missing successful quota')
    closure_sha = terminal['closure_sha256']
    if closure_sha is not None:
        require(valid_sha(closure_sha), 'closure SHA')
        data = raw_reader('closure.json')
        require(type(data) is bytes and len(data) <= RAW_LIMIT and digest(data) == closure_sha, 'closure bytes/SHA')
        closure = REF.load_json(data)
        require(canonical(closure) == data, 'closure encoding')
        absent = FS.validate_closure(closure,closure.get('pid'),closure.get('sequence'))
        require(terminal['children_absent'] is bool(absent), 'closure/terminal absence disagreement')
        if success:
            require(absent and closure['primary']['kind'] == 'exit' and closure['primary']['returncode'] == 0 and
                    closure['actual_returncode'] == 0, 'successful closure outcome')
    else:
        require(not success and terminal['children_absent'] is False, 'missing closure proof')
    if success:
        require(valid_sha(terminal['report_sha256']) and type(terminal['report_base64']) is str, 'report reference')
        data = raw_reader('report.json')
        require(type(data) is bytes and len(data) <= REPORT_LIMIT and digest(data) == terminal['report_sha256'] and
                base64.b64encode(data).decode() == terminal['report_base64'], 'embedded report bytes/SHA')
        value = REF.load_json(data)
        require(canonical(value) == data, 'report encoding')
        validate_report(value,protocol,run_id,raw_reader)
    else:
        require(terminal['report_sha256'] is None and terminal['report_base64'] is None, 'failed report must not authorize seal')
    return success


def inspect_terminal(identity, protocol):
    terminal = read_json(ROOT/'journal'/(PREFIX+'.terminal.json'),canonical_required=True)
    require(all(canonical(terminal.get(k)) == canonical(v) for k,v in identity.items()), 'terminal identity')
    if validate_terminal(terminal,protocol,identity['windows_run_id'],lambda p:REF.read_bounded(RUN/p,RAW_LIMIT)):
        manifest = read_json(ROOT/'downloads/mac-canterbury-input-manifest.json',1988,REF.PINS['input_manifest_sha256'])
        REF.verify_files(RUN/'input',manifest['entries'])
        for index,item in enumerate(schedule()):
            row = read_json(RUN/f'pair-{index:02d}.json')
            archive,decoded = pair_paths(index,item[3])
            archive_data = REF.read_bounded(archive,RAW_LIMIT*48,row['archive_sha256'])
            require(len(archive_data) == row['archive_bytes'], 'retained archive bytes')
            REF.verify_files(decoded,manifest['entries'])
    return terminal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-run-id',required=True)
    parser.add_argument('--protocol-sha',required=True)
    parser.add_argument('--inspect',action='store_true')
    parser.add_argument('--helper-parent-pid',type=int)
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native Mac ARM64 only')
    require(Path(__file__).absolute() == ROOT/'tools'/(PREFIX+'.py'), 'endpoint location')
    require(re.fullmatch('[0-9a-f]{32}',args.windows_run_id) and valid_sha(args.protocol_sha), 'endpoint identity')
    require(not (args.inspect and args.helper_parent_pid is not None), 'incompatible endpoint mode')
    os.umask(0o077)
    validate_output_budget()
    endpoint_sha = digest(REF.read_bounded(Path(__file__),131072))
    protocol = read_json(ROOT/'downloads'/(PREFIX+'-protocol.json'),RAW_LIMIT,args.protocol_sha)
    validate_protocol(protocol,endpoint_sha)
    require(digest(canonical(protocol)) == args.protocol_sha, 'protocol canonical bytes')
    identity = identity_for(args.windows_run_id,args.protocol_sha,endpoint_sha)
    if args.helper_parent_pid is not None:
        child(args.helper_parent_pid,args.windows_run_id,args.protocol_sha)
        return 0
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup = load(setup_path,'continuous_reference_setup',REF.SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    source,inputs = preflight(setup)
    if args.inspect:
        terminal = inspect_terminal(identity,protocol)
        sys.stdout.write(canonical(terminal).decode())
        return terminal['exit']
    started,terminal_path = (ROOT/'journal'/(PREFIX+s) for s in ('.started.json','.terminal.json'))
    require(not RUN.exists() and not started.exists() and not terminal_path.exists(), 'continuous reference already attempted')
    setup.admit(ROOT,MAX_BYTES)
    setup.new_json(started,dict(identity,endpoint_pid=os.getpid(),parent_pid=os.getppid(),
        started_unix_ns=time.time_ns(),journal_reserved_bytes=JOURNAL_RESERVED_BYTES,
        journal_reserved_entries=JOURNAL_RESERVED_ENTRIES))
    begin = time.monotonic()
    status,error,closure_sha,report_data,absent = 'failed',None,None,None,False
    original_admit,original_environment = setup.admit,setup.child_environment
    supervisor = FS.Supervisor(ROOT,support=setup)
    def guard(root,extra=0):
        require(time.monotonic()-begin < 90, 'campaign runtime deadline')
        local_counts()
        return original_admit(root,extra)
    def environment(root):
        result = original_environment(root)
        for key in ('TEMP','TMP','TMPDIR'): result[key] = str(RUN/'temp')
        return result
    try:
        RUN.mkdir(mode=0o700)
        (RUN/'temp').mkdir(mode=0o700)
        extract_inputs(REF.read_bounded(ROOT/'downloads/mac-canterbury-input.zip',2811966,REF.PINS['input_zip_sha256']),
            read_json(ROOT/'downloads/mac-canterbury-input-manifest.json',1988,REF.PINS['input_manifest_sha256']))
        setup.LOG_LIMIT = 16384
        setup.admit,setup.child_environment = guard,environment
        caught = None
        try:
            output = supervisor.run(setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(Path(__file__)),
                '--windows-run-id',args.windows_run_id,'--protocol-sha',args.protocol_sha,
                '--helper-parent-pid',str(os.getpid())],timeout=100,cwd=RUN)
            require(output == '', 'helper stdout/stderr')
        except BaseException as failure:
            caught = failure
        proof = supervisor.last_closure
        closure_sha = digest(write(RUN/'closure.json',proof))
        absent = FS.validate_closure(proof,proof['pid'],proof['sequence'])
        require(absent and proof['primary']['kind'] == 'exit' and proof['primary']['returncode'] == 0 and
                proof['actual_returncode'] == 0 and caught is None, 'helper/closure failed: '+str(caught))
        report_data = REF.read_bounded(RUN/'report.json',REPORT_LIMIT)
        validate_report(REF.load_json(report_data),protocol,args.windows_run_id,lambda p:REF.read_bounded(RUN/p,RAW_LIMIT))
        status = 'completed-reference'
    except BaseException as failure:
        error,report_data = str(failure)[:2048],None
    finally:
        setup.admit,setup.child_environment = original_admit,original_environment
    try:
        source.verify_source(ROOT,inputs['files'])
        for path,expected,maximum in dependency_pins():
            setup.checked_path(path)
            REF.read_bounded(path,maximum,expected)
        counts = local_counts()
        original_admit(ROOT)
        require(time.monotonic()-begin <= 120, 'finalization elapsed deadline')
    except BaseException as failure:
        status,error,report_data = 'failed',((error+'; ') if error else '')+str(failure)[:2048],None
        counts = None
    terminal = dict(identity,status=status,error=error,exit=0 if status == 'completed-reference' else 1,
        children_absent=bool(absent),closure_sha256=closure_sha,counts=counts,elapsed_seconds=time.monotonic()-begin,
        report_sha256=digest(report_data) if report_data else None,
        report_base64=base64.b64encode(report_data).decode() if report_data else None)
    write(terminal_path,terminal,TERMINAL_LIMIT)
    sys.stdout.write(canonical(terminal).decode())
    return terminal['exit']


if __name__ == '__main__':
    sys.exit(main())
