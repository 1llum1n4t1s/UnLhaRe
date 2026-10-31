#!/usr/bin/env python3
"""連続observerを正常系とwait4中の故障系で検証する。コーデックは実行しない。"""
import argparse
import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import subprocess
import sys
import time


def load(path, name, expected):
    data = path.read_bytes()
    if len(data) > 65536 or hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('dependency SHA/bound: '+str(path))
    spec = importlib.util.spec_from_file_location(name,str(path))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HERE = Path(__file__).absolute().parent
CAL_SHA = 'cb5ef0c6f4b4eb10f7f8c0ca17bc49620f815d29723e28ed386410bb9ae617b0'
OBS_SHA = '416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
CAL = load(HERE/'mac-cpu-observation-calibration.py','observer_e2e_calibration',CAL_SHA)
OBS = load(HERE/'mac-continuous-cpu-observer.py','observer_e2e_primitive',OBS_SHA)
FS_SHA = '51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
FS = load(HERE/'mac-finite-supervisor.py','observer_e2e_finite_supervisor',FS_SHA)
ROOT, CLI, METRICS = CAL.ROOT,CAL.CLI,CAL.METRICS
CLI_ARG = CLI.as_posix()
PREFIX = 'mac-continuous-observer-e2e-v2-20261027'
RUN = ROOT/'tmp'/PREFIX
PURPOSE = 'no-codec-continuous-observer-e2e-v2'
EVENT_NS = tuple(i*1000000000 for i in range(4,10))
require,read,write,sha = CAL.require,CAL.read,CAL.write,CAL.sha


def integer(value):
    return type(value) is int and value >= 0


def validate_normal(value):
    require(value['schema'] == 1 and value['purpose'] == PURPOSE and value['phase'] == 'normal', 'normal identity')
    raw, metrics = value['observer'],value['metrics']
    derived = OBS.validate_report(raw)
    require(derived == raw['validation'] and derived['eligible'] is True and raw['max_captures'] == 10 and
            len(raw['captures']) == 10 and len(raw['events']) == 6 and len(metrics) == 6, 'normal observer coverage')
    for index,(event,metric,planned) in enumerate(zip(raw['events'],metrics,EVENT_NS)):
        require(metric['event_id'] == index and metric['planned_start_ns'] == planned and
                metric['command'] == [CLI_ARG,'--version'], 'normal event/command identity')
        require(all(integer(metric[k]) for k in ('spawn_start_ns','wait_end_ns','elapsed_ns','peak_rss_bytes')) and
                event['start_ns'] <= metric['spawn_start_ns'] < metric['wait_end_ns'] <= event['end_ns'] and
                metric['elapsed_ns'] == metric['wait_end_ns']-metric['spawn_start_ns'] and
                metric['peak_rss_bytes'] > 0 and 0 <= event['start_ns']-planned <= 100000000, 'normal time/resource fields')
        require(metric['normal_exit'] is True and type(metric['exit_code']) is int and metric['exit_code'] == 0 and
                metric['signal'] is None and all(type(metric[k]) in (int,float) and math.isfinite(metric[k]) and metric[k] >= 0
                for k in ('user_seconds','system_seconds')), 'normal child exit/usage')
        if index:
            require(metrics[index-1]['wait_end_ns'] <= metric['spawn_start_ns'], 'overlapping CLI processes')
    require(len({i for event in derived['events'] for i in event['window_ids']}) >= 3, 'events not distributed across windows')
    return derived


def validate_fault(returncode, failure, pending, entered, finished, helper_pid, absent):
    require(type(returncode) is int and returncode == 70 and absent is True and finished is False, 'fault exit/group state')
    require(failure['schema'] == 1 and failure['phase'] == 'fault' and failure['error_type'] == 'RuntimeError' and
            failure['error'] == 'injected-capture-fault', 'fault identity')
    raw = failure['observer']
    derived = OBS.validate_report(raw)
    require(raw['completed'] is False and raw['max_captures'] == 10 and len(raw['captures']) == 4 and
            len(raw['events']) == 1 and raw['events'][0]['end_ns'] is None and
            raw['failure'] == 'RuntimeError: injected-capture-fault' and
            derived['errors'] == ['observer failed: RuntimeError: injected-capture-fault'], 'unexpected observer fault')
    require(pending['schema'] == 1 and pending['phase'] == 'fault' and pending['token'] == 0 and
            pending['parent_pid'] == helper_pid and integer(pending['pid']) and pending['pid'] > 0 and
            pending['command'] == ['/bin/sleep','45'], 'fault fixture identity')
    require(entered['schema'] == 1 and entered['token'] == 0 and entered['pid'] == pending['pid'] and
            all(integer(x) for x in (pending['spawn_start_ns'],entered['entered_ns'],failure['failure_ns'])) and
            raw['events'][0]['start_ns'] <= pending['spawn_start_ns'] <= entered['entered_ns'] < failure['failure_ns'] and
            4000000000 <= raw['events'][0]['start_ns'] <= 4100000000 and
            5000000000 <= failure['failure_ns'] <= 5250000000, 'wait4/fault ordering')
    return dict(state='expected-failure-verified',returncode=70,fixture_pid=pending['pid'],children_absent=True)


def quota_counts(total,count):
    require(0 <= total <= 1048576 and 1 <= count <= 32, 'E2E run quota')
    charged,entries = total+163840,count+4
    require(charged <= 2097152 and entries <= 64, 'E2E aggregate quota')
    return dict(run_bytes=total,run_entries=count,journal_reserved_bytes=163840,
                journal_reserved_entries=4,charged_bytes=charged,charged_entries=entries)


def local_counts():
    total,count = 0,1
    for path in RUN.rglob('*'):
        require(not path.is_symlink() and (path.is_file() or path.is_dir()) and path.stat().st_uid == os.getuid(), 'run object changed')
        count += 1
        if path.is_file():
            require(path.stat().st_nlink == 1, 'run hardlink')
            total += path.stat().st_size
    return quota_counts(total,count)


def count_snapshot():
    try:
        return dict(counts=local_counts(),counts_error=None)
    except Exception as failure:
        return dict(counts=None,counts_error=str(failure)[:2048])


def await_target(epoch,target):
    remaining = epoch+target-time.monotonic_ns()
    while remaining > 0:
        time.sleep(remaining/1e9)
        remaining = epoch+target-time.monotonic_ns()
    require(time.monotonic_ns()-epoch-target <= 100000000, 'fixed event start late')


def spawn(command):
    actions = [(os.POSIX_SPAWN_OPEN,n,'/dev/null',os.O_RDONLY if n == 0 else os.O_WRONLY,0) for n in range(3)]
    return os.posix_spawn(command[0],command,dict(os.environ),file_actions=actions)


def child(phase,parent_pid):
    require(parent_pid == os.getppid() and parent_pid != 1, 'helper parent identity')
    identity = json.loads(read(ROOT/'journal'/(PREFIX+'.started.json')))
    require(identity['parent_pid'] == parent_pid and identity['script_sha256'] == sha(Path(__file__)), 'started identity')
    directory = RUN/phase
    holder, counter = {},[0]
    progress = (directory/'captures.jsonl').open('xb')
    def capture():
        index = counter[0]
        counter[0] += 1
        if phase == 'fault' and index == 4:
            raise RuntimeError('injected-capture-fault')
        result = subprocess.run([str(METRICS)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=.2,check=True)
        require(not result.stderr and len(result.stdout) <= 4096, 'native metrics output')
        return json.loads(result.stdout)
    def persist(record):
        line = CAL.canonical(record)
        require(progress.tell()+len(line) <= 65536, 'capture log bound')
        progress.write(line); progress.flush(); os.fsync(progress.fileno())
    def fail(error,partial):
        try:
            write(directory/'failure.json',dict(schema=1,phase=phase,error_type=type(error).__name__,error=str(error)[:2048],
                  failure_ns=time.monotonic_ns()-holder['observer'].epoch_ns,observer=holder['observer'].report()))
        finally:
            # sandbox内からsignalせずhelperを閉じ、outer Supervisorが残存groupを回収する。
            os._exit(70)
    observer = OBS.Observer(capture,on_failure=fail,on_capture=persist,max_captures=10)
    holder['observer'] = observer
    observer.start()
    require(observer.wait_entry_ready(6), 'entry readiness timeout')
    epoch = observer.epoch_ns
    if phase == 'fault':
        await_target(epoch,EVENT_NS[0])
        token = observer.begin_event()
        started = time.monotonic_ns()-epoch
        pid = spawn(['/bin/sleep','45'])
        write(directory/'pending-child.json',dict(schema=1,phase=phase,token=token,pid=pid,
              parent_pid=os.getpid(),command=['/bin/sleep','45'],spawn_start_ns=started))
        write(directory/'wait4-entered.json',dict(schema=1,token=token,pid=pid,entered_ns=time.monotonic_ns()-epoch))
        waited,status,_ = os.wait4(pid,0)
        write(directory/'finished-child.json',dict(waited=waited,status=status))
        raise ValueError('fixture unexpectedly finished before injected failure')
    metrics = []
    for planned in EVENT_NS:
        await_target(epoch,planned)
        token = observer.begin_event()
        started = time.monotonic_ns()-epoch
        pid = spawn([CLI_ARG,'--version'])
        waited,status,usage = os.wait4(pid,0)
        ended = time.monotonic_ns()-epoch
        require(waited == pid, 'wait4 PID mismatch')
        normal,code,sig = CAL.MEASURE.exit_state(status)
        observer.finish_event(token)
        metrics.append(dict(event_id=token,planned_start_ns=planned,spawn_start_ns=started,wait_end_ns=ended,
              elapsed_ns=ended-started,user_seconds=usage.ru_utime,system_seconds=usage.ru_stime,
              peak_rss_bytes=usage.ru_maxrss,normal_exit=normal,exit_code=code,signal=sig,command=[CLI_ARG,'--version']))
    require(observer.join(15), 'observer join timeout')
    progress.close()
    report = dict(schema=1,purpose=PURPOSE,phase=phase,observer=observer.report(),metrics=metrics)
    validate_normal(report)
    write(directory/'report.json',report)


def group_absent(supervisor):
    require(supervisor.process is not None, 'helper never started')
    proof = supervisor.last_closure
    require(FS.validate_closure(proof,supervisor.process.pid,supervisor.sequence), 'phase closure not proven')
    require(proof['actual_returncode'] == supervisor.process.returncode, 'closure return code mismatch')
    return True


def require_primary_exit(supervisor, code):
    primary = supervisor.last_closure['primary']
    require(primary['kind'] == 'exit' and primary['returncode'] == code and
            supervisor.process.returncode == code, 'phase primary outcome was not expected exit')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=('normal','fault'))
    parser.add_argument('--parent-pid',type=int)
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native Mac ARM64 only')
    require(Path(__file__).absolute() == ROOT/'tools/mac-continuous-observer-e2e-v2.py', 'driver location')
    os.umask(0o077)
    if args.phase:
        child(args.phase,args.parent_pid)
        return 0
    require(args.parent_pid is None, 'outer argument')
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup = CAL.module(setup_path,'continuous_e2e_setup',CAL.SETUP_SHA)
    setup.validate_bootstrap(setup_path); setup.checked_path(ROOT,private=True)
    pins = [(CLI,CAL.CLI_SHA),(METRICS,CAL.METRICS_SHA),
            (ROOT/'tools/mac-canterbury-measure.py',CAL.MEASURE_SHA),
            (ROOT/'tools/mac-cpu-observation-calibration.py',CAL_SHA),
            (ROOT/'tools/mac-continuous-cpu-observer.py',OBS_SHA),
            (ROOT/'tools/mac-finite-supervisor.py',FS_SHA),
            (ROOT/'journal/mac-canterbury-reference.terminal.json',CAL.CLOSED_SHA)]
    for path,expected in pins:
        setup.checked_path(path); require(sha(path) == expected, 'dependency before E2E')
    started = ROOT/'journal'/(PREFIX+'.started.json')
    terminal = ROOT/'journal'/(PREFIX+'.terminal.json')
    require(not RUN.exists() and not started.exists() and not terminal.exists(), 'E2E already attempted')
    setup.admit(ROOT,2097152)
    setup.LOG_LIMIT = 16384
    identity = dict(schema=1,purpose=PURPOSE,superiority_decision_allowed=False,parent_pid=os.getpid(),
             script_sha256=sha(Path(__file__)),observer_sha256=OBS_SHA,supervisor_sha256=FS_SHA,sleep_sha256=sha(Path('/bin/sleep')),
             closed_receipt_sha256=CAL.CLOSED_SHA,phase_timeouts_seconds=[20,10],runtime_seconds=60,
             final_elapsed_limit_seconds=80,quota_bytes=2097152,quota_entries=64,journal_reserved_bytes=163840)
    setup.new_json(started,identity)
    RUN.mkdir(mode=0o700)
    for phase in ('normal','fault'):
        (RUN/phase).mkdir(mode=0o700); (RUN/phase/'temp').mkdir(mode=0o700)
    begin = time.monotonic()
    original_admit,original_environment = setup.admit,setup.child_environment
    active = ['normal']
    def guard(root,extra=0):
        require(time.monotonic()-begin < 60, 'E2E runtime deadline'); local_counts()
        return original_admit(root,extra)
    def environment(root):
        values = original_environment(root)
        for key in ('TEMP','TMP','TMPDIR'):
            values[key] = str(RUN/active[0]/'temp')
        return values
    setup.admit,setup.child_environment = guard,environment
    supervisor = FS.Supervisor(ROOT,support=setup)
    phases,status,error = [],'completed-no-codec-e2e',None
    closure_sha = None
    try:
        for phase,timeout in (('normal',20),('fault',10)):
            active[0] = phase
            directory = RUN/phase
            caught = None
            try:
                output = supervisor.run(setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(Path(__file__)),
                         '--phase',phase,'--parent-pid',str(os.getpid())],timeout=min(timeout,60-(time.monotonic()-begin)),cwd=directory)
                require(output == '', 'helper output')
            except BaseException as failure:
                caught = failure
            closure_sha = write(directory/'closure.json',supervisor.last_closure)
            absent = group_absent(supervisor)
            require(absent, 'phase process group remains')
            if phase == 'normal':
                require(caught is None, 'normal helper failed: '+str(caught))
                require_primary_exit(supervisor,0)
                report = json.loads(read(directory/'report.json'))
                check = validate_normal(report)
                require([json.loads(line) for line in read(directory/'captures.jsonl').splitlines()] == report['observer']['captures'], 'normal raw capture log mismatch')
                phases.append(dict(phase=phase,status='passed',children_absent=True,closure_sha256=closure_sha,report_sha256=sha(directory/'report.json'),
                       event_window_ids=[x['window_ids'] for x in check['events']]))
            else:
                require(caught is not None and str(caught) == 'process failed: 70', 'expected injected exit was not observed')
                require_primary_exit(supervisor,70)
                failure = json.loads(read(directory/'failure.json'))
                pending = json.loads(read(directory/'pending-child.json'))
                entered = json.loads(read(directory/'wait4-entered.json'))
                result = validate_fault(supervisor.process.returncode,failure,pending,entered,
                         (directory/'finished-child.json').exists(),supervisor.process.pid,absent)
                require([json.loads(line) for line in read(directory/'captures.jsonl').splitlines()] == failure['observer']['captures'], 'fault capture log mismatch')
                phases.append(dict(phase=phase,**result,closure_sha256=closure_sha,failure_sha256=sha(directory/'failure.json'),
                       pending_sha256=sha(directory/'pending-child.json'),wait4_entered_sha256=sha(directory/'wait4-entered.json')))
    except BaseException as failure:
        status,error = 'failed-no-codec-e2e',str(failure)[:2048]
    finally:
        setup.admit,setup.child_environment = original_admit,original_environment
    counts = count_snapshot()
    try:
        require(counts['counts'] is not None, 'final quota failed: '+str(counts['counts_error']))
        for path,expected in pins+[(Path('/bin/sleep'),identity['sleep_sha256']),(Path(__file__),identity['script_sha256'])]:
            require(sha(path) == expected, 'dependency after E2E')
        original_admit(ROOT)
        require(time.monotonic()-begin <= 80, 'E2E finalization elapsed limit')
    except BaseException as failure:
        status,error = 'failed-no-codec-e2e',str(failure)[:2048]
    result = dict(identity,status=status,error=error,phases=phases,last_closure_sha256=closure_sha,**counts,elapsed_seconds=time.monotonic()-begin)
    write(terminal,result)
    print(json.dumps(result,sort_keys=True,separators=(',',':')),flush=True)
    return 0 if status == 'completed-no-codec-e2e' else 1


if __name__ == '__main__':
    sys.exit(main())

