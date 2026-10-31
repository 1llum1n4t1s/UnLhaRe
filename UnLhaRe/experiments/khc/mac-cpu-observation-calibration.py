#!/usr/bin/env python3
"""コーデックを動かさず、CPU tick観測の時間幅と分解能を診断する。"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import sys
import time

ROOT = Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX = 'mac-cpu-observation-calibration-20261026'
RUN = ROOT/'tmp'/PREFIX
CLI = ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli'
METRICS = ROOT/'tools/mac-native-system-metrics'
SETUP_SHA = '9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
MEASURE_SHA = '0867ef2f84192c14f839a90fb731813f0f20edb0ec10e59fc01dec3a273dc855'
CLI_SHA = '5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629'
METRICS_SHA = '31955203a22b4128b956e86daa4bffb653e513bb31682d63a9b8b5941df8d5ba'
CLOSED_SHA = 'ff13dcf396a3d0ebadb306d457d0e0a361aeb208cfa7a2775506dc5fc5a0715c'
MODES = ('adjacent','true','version','idle-100ms','idle-1s','version-window-1s')
RUNTIME_SECONDS = 100
JOURNAL_RESERVE_BYTES = 2*65536+16384


def require(ok, message):
    if not ok:
        raise ValueError(message)


def read(path, maximum=65536):
    require(path.is_file() and not path.is_symlink(), 'input type: '+str(path))
    with path.open('rb') as stream:
        data = stream.read(maximum+1)
    require(len(data) <= maximum, 'input bound: '+str(path))
    return data


def sha(path, maximum=32*1024**2):
    return hashlib.sha256(read(path, maximum)).hexdigest()


def module(path, name, expected):
    require(sha(path) == expected, 'module SHA changed')
    spec = importlib.util.spec_from_file_location(name, str(path))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


MEASURE = module(Path(__file__).with_name('mac-canterbury-measure.py'), 'frozen_measure', MEASURE_SHA)


def schedule():
    return [(round_index, position, MODES[(position+round_index) % 6])
            for round_index in range(6) for position in range(6)]


def cpu_sample(before, after):
    MEASURE.validate_environment(before)
    MEASURE.validate_environment(after)
    delta = [(b-a) % 2**32 for a,b in zip(before['cpu_ticks'], after['cpu_ticks'])]
    total = sum(delta)
    return dict(cpu_tick_deltas=delta, cpu_ticks_total=total,
                observation_status='available' if total else 'unobservable-zero-ticks',
                cpu_interval_percent=MEASURE.cpu_percent(before,after) if total else None,
                tick_percentage_point_quantum=100/total if total else None)


def brackets(before_start, before_end, after_start, after_end):
    require(all(type(x) is int for x in (before_start,before_end,after_start,after_end)) and
            0 <= before_start <= before_end <= after_start <= after_end, 'invalid observation brackets')
    return dict(before_call_ns=before_end-before_start, after_call_ns=after_end-after_start,
                interval_lower_ns=after_start-before_end, interval_upper_ns=after_end-before_start)


def command_for(mode):
    require(mode in MODES, 'unknown diagnostic mode')
    if mode == 'true':
        return ['/usr/bin/true']
    if mode in ('version','version-window-1s'):
        return [str(CLI),'--version']
    return None


def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()


def write(path, value):
    data = canonical(value)
    require(len(data) <= 65536, 'JSON output bound')
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    return hashlib.sha256(data).hexdigest()


def sample(mode):
    a0 = time.perf_counter_ns()
    before = MEASURE.observe(METRICS)
    a1 = time.perf_counter_ns()
    command = command_for(mode)
    usage, elapsed = None, None
    if command:
        actions = [(os.POSIX_SPAWN_OPEN,n,'/dev/null',os.O_RDONLY if n == 0 else os.O_WRONLY,0)
                   for n in range(3)]
        start = time.perf_counter_ns()
        pid = os.posix_spawn(command[0],command,dict(os.environ),file_actions=actions)
        waited,status,ru = os.wait4(pid,0)
        elapsed = time.perf_counter_ns()-start
        normal,exit_code,sig = MEASURE.exit_state(status)
        require(waited == pid and normal and exit_code == 0 and sig is None, 'diagnostic command failed')
        usage = dict(user_seconds=ru.ru_utime,system_seconds=ru.ru_stime,peak_rss_bytes=ru.ru_maxrss)
    # 1秒拡張の起点はbefore観測呼出し完了a1。CLI時間を延長・差引きしない。
    minimum = {'idle-100ms':100000000,'idle-1s':1000000000,'version-window-1s':1000000000}.get(mode,0)
    remaining = minimum-(time.perf_counter_ns()-a1)
    if remaining > 0:
        time.sleep(remaining/1e9)
    b0 = time.perf_counter_ns()
    after = MEASURE.observe(METRICS)
    b1 = time.perf_counter_ns()
    return dict(mode=mode,environment_before=before,environment_after=after,
                command_elapsed_ns=elapsed,command_usage=usage,
                **brackets(a0,a1,b0,b1),**cpu_sample(before,after))


def environment_ok(value):
    return all(x['thermal_state'] == 0 and x['ac_power'] for x in
               (value['environment_before'],value['environment_after']))


def child(parent_pid):
    require(parent_pid == os.getppid() and parent_pid != 1, 'diagnostic parent identity')
    started = json.loads(read(ROOT/'journal'/(PREFIX+'.started.json')))
    require(started['parent_pid'] == parent_pid and started['script_sha256'] == sha(Path(__file__)), 'started identity')
    baseline, samples = [], []
    status,error = 'completed-diagnostic',None
    try:
        with (RUN/'progress.jsonl').open('xb') as progress:
            for index in range(3):
                value = dict(kind='baseline',index=index,**sample('idle-1s'))
                baseline.append(value)
                line = canonical(value)
                require(progress.tell()+len(line) <= 65536, 'progress bound')
                progress.write(line); progress.flush()
                require(environment_ok(value) and value['cpu_interval_percent'] is not None and
                        value['cpu_interval_percent'] <= 15, 'baseline CPU/thermal/AC requirement')
            for round_index,position,mode in schedule():
                value = dict(kind='diagnostic',round=round_index,position=position,**sample(mode))
                samples.append(value)
                line = canonical(value)
                require(progress.tell()+len(line) <= 65536, 'progress bound')
                progress.write(line); progress.flush()
                require(environment_ok(value), 'diagnostic thermal/AC requirement')
    except BaseException as failure:
        status,error = 'stopped-diagnostic',str(failure)[:2048]
    write(RUN/'report.json',dict(schema=1,purpose='no-codec-observation-calibration',
          superiority_decision_allowed=False,closed_receipt_sha256=CLOSED_SHA,
          script_sha256=started['script_sha256'],measure_sha256=MEASURE_SHA,metrics_sha256=METRICS_SHA,
          cli_sha256=CLI_SHA,true_sha256=started['true_sha256'],planned_schedule=schedule(),
          interval_scope='wrapper brackets around native observations; native snapshot times unknown',
          extension_origin='completion of before observe call; CLI spawn-to-wait4 remains separate',
          baseline=baseline,samples=samples,status=status,error=error))


def quota_counts(total, count):
    require(0 <= total <= 512*1024 and 1 <= count <= 8, 'diagnostic run quota')
    charged, entries = total+JOURNAL_RESERVE_BYTES, count+3
    require(charged <= 1048576 and entries <= 16, 'diagnostic aggregate quota')
    return dict(run_bytes=total,run_entries=count,journal_reserved_bytes=JOURNAL_RESERVE_BYTES,
                journal_reserved_entries=3,charged_bytes=charged,charged_entries=entries)


def remaining_runtime(begin, now):
    remaining = RUNTIME_SECONDS-(now-begin)
    require(remaining > 0, 'diagnostic runtime deadline')
    return remaining


def local_counts():
    total,count = 0,1
    for path in RUN.rglob('*'):
        require(not path.is_symlink() and (path.is_file() or path.is_dir()) and
                path.stat().st_uid == os.getuid(), 'diagnostic run object changed')
        count += 1
        if path.is_file():
            require(path.stat().st_nlink == 1, 'diagnostic hardlink')
            total += path.stat().st_size
    return quota_counts(total,count)


def count_snapshot():
    try:
        return dict(counts=local_counts(),counts_error=None)
    except Exception as failure:
        return dict(counts=None,counts_error=str(failure)[:2048])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--child',action='store_true')
    parser.add_argument('--parent-pid',type=int)
    args = parser.parse_args()
    require(platform.system() == 'Darwin' and platform.machine() == 'arm64', 'native Mac ARM64 only')
    require(Path(__file__).absolute() == ROOT/'tools/mac-cpu-observation-calibration.py', 'script location')
    os.umask(0o077)
    if args.child:
        child(args.parent_pid)
        return 0
    require(args.parent_pid is None, 'outer parent argument')
    setup_path = Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup = module(setup_path,'calibration_setup',SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT,private=True)
    closed = ROOT/'journal/mac-canterbury-reference.terminal.json'
    pins = [(CLI,CLI_SHA),(METRICS,METRICS_SHA),(closed,CLOSED_SHA),
            (ROOT/'tools/mac-canterbury-measure.py',MEASURE_SHA)]
    for path,expected in pins:
        setup.checked_path(path)
        require(sha(path) == expected, 'dependency SHA before diagnosis')
    terminal = ROOT/'journal'/(PREFIX+'.terminal.json')
    started = ROOT/'journal'/(PREFIX+'.started.json')
    require(not RUN.exists() and not started.exists() and not terminal.exists(), 'diagnosis already attempted')
    setup.admit(ROOT,2*1024**2)
    # この診断用module instanceだけでログを16KiBへ制限する。固定sourceは変更しない。
    setup.LOG_LIMIT = 16384
    identity = dict(schema=1,purpose='no-codec-observation-calibration',superiority_decision_allowed=False,
                    script_sha256=sha(Path(__file__)),true_sha256=sha(Path('/usr/bin/true')),
                    closed_receipt_sha256=CLOSED_SHA,parent_pid=os.getpid(),runtime_seconds=100,
                    final_elapsed_limit_seconds=120,quota_bytes=1048576,quota_entries=16,
                    journal_reserved_bytes=JOURNAL_RESERVE_BYTES,supervisor_log_limit_bytes=16384)
    setup.new_json(started,identity)
    RUN.mkdir(mode=0o700)
    (RUN/'temp').mkdir(mode=0o700)
    begin = time.monotonic()
    original_admit = setup.admit
    original_environment = setup.child_environment
    def scoped_environment(root):
        values = original_environment(root)
        for key in ('TMPDIR','TEMP','TMP'):
            values[key] = str(RUN/'temp')
        return values
    setup.child_environment = scoped_environment
    def guard(root,extra=0):
        remaining_runtime(begin,time.monotonic())
        local_counts()
        return original_admit(root,extra)
    setup.admit = guard
    supervisor = setup.Supervisor(ROOT)
    status,error,report_sha = 'failed-diagnostic',None,None
    try:
        output = supervisor.run(setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(Path(__file__)),
                    '--child','--parent-pid',str(os.getpid())],timeout=remaining_runtime(begin,time.monotonic()),cwd=RUN)
        require(output == '', 'unexpected child output')
        report = json.loads(read(RUN/'report.json'))
        require(report['script_sha256'] == identity['script_sha256'], 'report identity')
        status,error = report['status'],report['error']
        if status == 'completed-diagnostic':
            require(len(report['baseline']) == 3 and len(report['samples']) == 36, 'incomplete diagnostic')
        report_sha = sha(RUN/'report.json')
    except BaseException as failure:
        status,error = 'failed-diagnostic',str(failure)[:2048]
    finally:
        setup.admit = original_admit
        setup.child_environment = original_environment
    absent = True
    if supervisor.process is not None:
        try:
            os.killpg(supervisor.process.pid,0)
            absent = False
        except ProcessLookupError:
            pass
    snapshot = count_snapshot()
    try:
        require(absent, 'owned process group remains')
        for path,expected in pins+[(Path('/usr/bin/true'),identity['true_sha256']),
                                   (Path(__file__),identity['script_sha256'])]:
            require(sha(path) == expected, 'dependency SHA after diagnosis')
        require(snapshot['counts'] is not None, 'diagnostic counts unavailable: '+str(snapshot['counts_error']))
        original_admit(ROOT)
        require(time.monotonic()-begin <= 120, 'diagnostic finalization deadline')
    except BaseException as failure:
        status,error = 'failed-diagnostic',str(failure)[:2048]
    result = dict(identity,status=status,error=error,children_absent=absent,report_sha256=report_sha,
                  **snapshot,elapsed_seconds=time.monotonic()-begin)
    write(terminal,result)
    print(json.dumps(result,sort_keys=True,separators=(',',':')),flush=True)
    return 0 if status == 'completed-diagnostic' else 1


if __name__ == '__main__':
    sys.exit(main())
