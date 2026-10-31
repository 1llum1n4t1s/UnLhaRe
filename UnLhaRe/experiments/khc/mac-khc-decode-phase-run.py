#!/usr/bin/env python3
"""成功済み派生buildだけを単回実行する非比較診断。優越・改善率を判定しない。"""
import argparse
import hashlib
import importlib.util
import math
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import time

ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX='mac-khc-decode-phase-run-20261027'
RUN=ROOT/'tmp'/PREFIX
BINARY=ROOT/'cargo-target/decode-phase-20261027/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic'
ARCHIVE=ROOT/'tmp/mac-canterbury-continuous-reference-20261027/00-archive.khc'
METRICS=ROOT/'tools/mac-native-system-metrics'
SOURCE_SHA='1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55'
ARCHIVE_SHA='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee'
BINARY_SHA='4e68a6a54d5b9fec55c4507c4b5c3588b8cf8e10c3425615541cd91a3103e742'
AMENDMENT_SHA='f2a4979ed0f796b98876a324734998329eb40255b8593350ee439165873ae46e'
BUILD_RECEIPT_SHA='b5e6efbefc39bafa9f2d21f7ce33074c6b26f3cff0af44b2a5159fc64fca3b0d'
BUILD_CLOSURE_SHA='163ea2b3c4b9998d7f0519245c0447ba4df935b249326e4417f97264d0e53a36'
REFERENCE_SHA='a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4'
RETRY_SHA='771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe'
FS_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
OBS_SHA='416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
LOG_LIMIT=16384
MAX_BYTES,MAX_ENTRIES=8*1024**2,64
JOURNAL_BYTES,JOURNAL_ENTRIES=131072,4
PURPOSE='non-comparative-decode-phase-diagnostic'
AGGREGATION='do not sum inclusive phases; outer total includes unmeasured intervals'
UNMEASURED='routing, allocation, metadata and pipeline internals may be unmeasured; instrumentation adds overhead'
PHASE_NAMES=('archive.whole','archive.open','archive.manifest','archive.parallel_eligibility',
    'archive.parallel_dispatch','archive.read_frame','archive.decompress','archive.file_crc',
    'archive.write','archive.sync_all','archive.publish','archive.close','archive.finish',
    'block.whole','block.header_wire','block.stored_copy','block.lz','block.model_setup',
    'block.entropy_loop','block.inverse','block.raw_crc','spatial.whole','spatial.header_wire',
    'spatial.stored_copy','spatial.model_setup','spatial.token_loop','spatial.raw_crc')


def require(ok,message):
    if not ok:raise ValueError(message)


def digest(data):return hashlib.sha256(data).hexdigest()


def read(path,maximum,expected=None,*,artifact=False):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink>=1 and (artifact or info.st_nlink==1) and
        info.st_size<=maximum,'input file type/link/bound: '+str(path))
    with path.open('rb') as stream:data=stream.read(maximum+1)
    require(len(data)<=maximum and (expected is None or digest(data)==expected),'input bytes/SHA: '+str(path))
    return data


def load(path,name,expected):
    read(path,131072,expected)
    spec=importlib.util.spec_from_file_location(name,str(path));module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module);return module


HERE=Path(__file__).absolute().parent
REF=load(HERE/'mac-canterbury-reference.py','phase_run_reference',REFERENCE_SHA)
RETRY=load(HERE/'mac-decode-phase-retry.py','phase_run_retry',RETRY_SHA)
FS=load(HERE/'mac-finite-supervisor.py','phase_run_finite',FS_SHA)
OBS=load(HERE/'mac-continuous-cpu-observer.py','phase_run_observer',OBS_SHA)
canonical=REF.canonical


def write_bytes(path,data,maximum):
    require(type(data) is bytes and len(data)<=maximum,'output byte bound')
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    return digest(data)


def write(path,value):return write_bytes(path,canonical(value),65536)


def recipe():
    return dict(schema=1,purpose=PURPOSE,superiority_decision_allowed=False,root=ROOT.as_posix(),run=RUN.as_posix(),
        binary_sha256=BINARY_SHA,source_sha256=SOURCE_SHA,archive_sha256=ARCHIVE_SHA,
        build_receipt_sha256=BUILD_RECEIPT_SHA,build_closure_sha256=BUILD_CLOSURE_SHA,amendment_sha256=AMENDMENT_SHA,
        command=[BINARY.as_posix(),ARCHIVE.as_posix(),(RUN/'decoded').as_posix()],
        decode_seconds=20,helper_seconds=35,runtime_seconds=40,final_seconds=60,captures=24,cadence_ns=1250000000,
        entry_windows=3,entry_cpu_limit_percent=15,runtime_cpu_limit_percent=30,thermal_state=0,ac_power=True,
        max_bytes=MAX_BYTES,max_entries=MAX_ENTRIES,journal_reserved_bytes=JOURNAL_BYTES,
        journal_reserved_entries=JOURNAL_ENTRIES,stdout_max_bytes=LOG_LIMIT,stderr_max_bytes=LOG_LIMIT)


def uint(value,bits):return type(value) is int and 0<=value<2**bits


def validate_phase_stdout(data,wall_ns):
    require(type(data) is bytes and 0<len(data)<=LOG_LIMIT and data.endswith(b'\n') and b'\r' not in data and
        b'\n' not in data[:-1] and type(wall_ns) is int and wall_ns>0,'phase stdout/wall bound')
    value=REF.load_json(data)
    require(type(value) is dict and set(value)=={'schema','purpose','superiority_decision_allowed','status','summary','error','phase_report'} and
        type(value['schema']) is int and value['schema']==1 and value['purpose']==PURPOSE and
        value['superiority_decision_allowed'] is False and value['status']=='completed' and value['error'] is None,'phase result shape/status')
    summary=value['summary']
    require(type(summary) is dict and set(summary)=={'entries','files','bytes'} and
        all(type(summary[k]) is int for k in summary) and summary==dict(entries=11,files=11,bytes=2810784),'phase corpus summary')
    report=value['phase_report']
    require(type(report) is dict and set(report)=={'schema','purpose','superiority_decision_allowed','inclusive','aggregation','unmeasured_scope','outer_total_ns','lost_measurements','phases'} and
        type(report['schema']) is int and report['schema']==1 and report['purpose']==PURPOSE and
        report['superiority_decision_allowed'] is False and report['inclusive'] is True and
        report['aggregation']==AGGREGATION and report['unmeasured_scope']==UNMEASURED and
        report['lost_measurements'] is False and uint(report['outer_total_ns'],128) and
        0<report['outer_total_ns']<=wall_ns,'phase report contract/outer duration')
    rows=report['phases'];require(type(rows) is list and len(rows)==27,'phase count')
    for row,name in zip(rows,PHASE_NAMES):
        require(type(row) is dict and set(row)=={'name','calls','ns'} and row['name']==name and
            uint(row['calls'],64) and uint(row['ns'],128) and (row['calls']!=0 or row['ns']==0),'phase exact name/order/counter')
    for row in rows:
        if row['name'] in ('archive.whole','archive.open','archive.manifest'):
            require(row['calls']==1,'single-invocation top-level phase calls')
    require(0<rows[0]['ns']<=report['outer_total_ns'],'archive whole versus outer duration')
    return value


def gate_build(value,checked):
    require(type(value) is dict and type(checked) is dict and value.get('status')=='done' and
        type(value.get('exit')) is int and value['exit']==0 and
        all(value.get(k) is True for k in ('wait_confirmed','group_absent','postchecks_ok')) and
        value.get('source_sha256')==SOURCE_SHA and value.get('binary_sha256')==BINARY_SHA and
        value.get('closure_sha256')==BUILD_CLOSURE_SHA,'successful retry build prerequisite')
    require(checked.get('verified') is True and checked.get('cleanup_allowed') is True and
        checked.get('status')=='done' and type(checked.get('exit')) is int and checked['exit']==0 and
        checked.get('receipt_sha256')==BUILD_RECEIPT_SHA and checked.get('binary_sha256')==BINARY_SHA and
        checked.get('closure_sha256')==BUILD_CLOSURE_SHA,'verified raw build/closure/binary prerequisite')


def quota_counts(total,count):
    require(type(total) is int and type(count) is int and total>=0 and count>=1 and
        total+JOURNAL_BYTES<=MAX_BYTES and count+JOURNAL_ENTRIES<=MAX_ENTRIES,'run plus journal quota')
    return dict(run_bytes=total,run_entries=count,journal_reserved_bytes=JOURNAL_BYTES,
        journal_reserved_entries=JOURNAL_ENTRIES,charged_bytes=total+JOURNAL_BYTES,charged_entries=count+JOURNAL_ENTRIES)


def persist_terminal(value,began,persist,replace_late,*,clock=time.monotonic):
    first_sha=digest(canonical(value));persist(value)
    elapsed=clock()-began
    if elapsed>60:
        value=dict(value,status='failed',exit=1,postchecks_ok=False,runtime_seconds=elapsed,
            error=(((value['error']+'; ') if value['error'] else '')+'terminal persistence exceeded 60 seconds')[:4096])
        replace_late(value,first_sha)
    return value


def artifact_refs():
    result=[]
    names=['phase.stdout','phase.stderr','cli-started.json','measurement.json','observation.json',
        'restored.json','report.json','failure.json','failure-observation.json','closure.json']
    for name in names:
        path=RUN/name
        if not path.exists() and not path.is_symlink():continue
        info=path.lstat();require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_uid==os.getuid(),'artifact identity')
        maximum=LOG_LIMIT if name in ('phase.stdout','phase.stderr') else 65536
        # 上限超過を成功証拠にせず、原ファイルは失敗診断用に保持する。
        data=read(path,maximum) if info.st_size<=maximum else None
        result.append(dict(path=name,bytes=info.st_size,sha256=digest(data) if data is not None else None,
            within_bound=data is not None))
    return result


def local_counts():
    require(RUN.is_dir() and not RUN.is_symlink() and RUN.stat().st_uid==os.getuid(),'run identity')
    total,count=0,1
    def failed(error):raise ValueError('run walk failed') from error
    for directory,dirs,files in os.walk(RUN,followlinks=False,onerror=failed):
        for name in dirs+files:
            path=Path(directory)/name;info=path.lstat()
            require(info.st_uid==os.getuid() and not stat.S_ISLNK(info.st_mode) and
                (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) and
                (not stat.S_ISREG(info.st_mode) or info.st_nlink==1),'run owner/type/link')
            count+=1
            if stat.S_ISREG(info.st_mode):
                total+=info.st_size
                if path.name in ('phase.stdout','phase.stderr'):require(info.st_size<=LOG_LIMIT,'live stdout/stderr bound')
    return quota_counts(total,count)


def validate_observation(raw):
    checked=OBS.validate_report(raw)
    require(checked['eligible'] and raw['max_captures']==24 and len(raw['captures'])==24 and len(raw['events'])==1 and
        raw['events'][0]['end_ns']<raw['captures'][23]['start_ns'],'fixed 24 capture/one event observation: '+str(checked['errors'])[:1024])
    return checked


def spawn_binary(command):
    actions=[(os.POSIX_SPAWN_OPEN,0,'/dev/null',os.O_RDONLY,0)]
    for descriptor,side in ((1,'stdout'),(2,'stderr')):
        actions.append((os.POSIX_SPAWN_OPEN,descriptor,(RUN/('phase.'+side)).as_posix(),os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600))
    return os.posix_spawn(command[0],command,dict(os.environ),file_actions=actions)


def run_once(command,observer,*,spawn=None,wait=None,read_outputs=None,check_outputs=None,clock=time.monotonic_ns,sleep=time.sleep):
    spawn=spawn or spawn_binary;wait=wait or os.wait4
    read_outputs=read_outputs or (lambda:(read(RUN/'phase.stdout',LOG_LIMIT),read(RUN/'phase.stderr',LOG_LIMIT)))
    check_outputs=check_outputs or local_counts
    token=observer.begin_event();start=clock();pid=spawn(command)
    require(type(pid) is int and pid>1,'owned binary PID')
    polls=0
    while True:
        require(clock()-start<=20_000_000_000,'decode/output supervision exceeded 20 seconds')
        check_outputs();waited,status,usage=wait(pid,getattr(os,'WNOHANG',1));polls+=1
        if waited==0:sleep(.025);continue
        require(waited==pid and type(status) is int,'wait4 PID/status')
        waited_at=clock();stdout,stderr=read_outputs();end=clock()
        require(type(stdout) is bytes and type(stderr) is bytes and len(stdout)<=LOG_LIMIT and len(stderr)<=LOG_LIMIT and
            0<end-start<=20_000_000_000,'decode/stdout/stderr completion bound')
        event=observer.finish_event(token);signal=status&0x7f;normal=signal==0
        require(normal or signal!=0x7f,'terminal wait4 state')
        return dict(schema=1,pid=pid,wait_status=status,command=command,recipe_sha256=digest(canonical(recipe())),
            event={k:event[k] for k in ('id','start_ns','end_ns')},wait_polls=polls,waited_elapsed_ns=waited_at-start,
            stdout_sha256=digest(stdout),stdout_bytes=len(stdout),stderr_sha256=digest(stderr),stderr_bytes=len(stderr),
            timing_label='instrumented diagnostic including output supervision; not benchmark timing',
            metric=dict(elapsed_ns=end-start,user_seconds=usage.ru_utime,system_seconds=usage.ru_stime,
                peak_rss_bytes=usage.ru_maxrss,normal_exit=normal,exit_code=(status>>8)&255 if normal else None,
                signal=None if normal else signal,cpu_per_wall=(usage.ru_utime+usage.ru_stime)*1e9/(end-start)))


def prerequisites(setup):
    paths=[(HERE/'mac-canterbury-reference.py',REFERENCE_SHA,131072),(HERE/'mac-decode-phase-retry.py',RETRY_SHA,131072),
        (HERE/'mac-finite-supervisor.py',FS_SHA,131072),(HERE/'mac-continuous-cpu-observer.py',OBS_SHA,131072),
        (METRICS,REF.PINS['system_metrics_sha256'],1024**2),(ARCHIVE,ARCHIVE_SHA,450309),
        (ROOT/'downloads/mac-canterbury-input-manifest.json',REF.PINS['input_manifest_sha256'],1988),
        (ROOT/'downloads/source.zip',REF.PINS['source_sha256'],8*1024**2),
        (ROOT/'downloads/mac-decode-phase-source.zip',SOURCE_SHA,304889),
        (ROOT/'journal/mac-decode-phase-retry-amendment.json',AMENDMENT_SHA,65536),
        (ROOT/'journal/mac-decode-phase-build-protocol.json',RETRY.OLD_PROTOCOL_SHA,65536),
        (ROOT/'journal/mac-decode-phase-build.terminal.json',RETRY.OLD_RECEIPT_SHA,65536),
        (ROOT/'journal/mac-decode-phase-build.closure.json',RETRY.OLD_CLOSURE_SHA,65536),
        (ROOT/'journal/mac-decode-phase-retry.terminal.json',BUILD_RECEIPT_SHA,65536),
        (ROOT/'journal/mac-decode-phase-retry.closure.json',BUILD_CLOSURE_SHA,65536)]
    data={}
    for path,expected,maximum in paths:
        setup.checked_path(path);require(path.stat().st_uid==os.getuid(),'prerequisite UID')
        data[path]=read(path,maximum,expected)
    amendment_data=data[ROOT/'journal/mac-decode-phase-retry-amendment.json']
    protocol_data=data[ROOT/'journal/mac-decode-phase-build-protocol.json']
    first_data=data[ROOT/'journal/mac-decode-phase-build.terminal.json']
    amendment,old,protocol=RETRY.validate_bundle(amendment_data,AMENDMENT_SHA,protocol_data,first_data)
    RETRY.validate_old_evidence(protocol_data,first_data,data[ROOT/'journal/mac-decode-phase-build.closure.json'],old)
    receipt_data=data[ROOT/'journal/mac-decode-phase-retry.terminal.json']
    checked=RETRY.validate_retry_receipt(receipt_data,amendment,AMENDMENT_SHA,old,protocol)
    receipt=RETRY.parse(receipt_data);gate_build(receipt,checked)
    require(canonical(receipt['closure_proof'])==data[ROOT/'journal/mac-decode-phase-retry.closure.json'],'build raw closure equality')
    setup.checked_path(BINARY);require(BINARY.stat().st_uid==os.getuid() and os.access(BINARY,os.X_OK),'owned executable binary')
    read(BINARY,64*1024**2,BINARY_SHA,artifact=True)
    base_records,new_records,_=old.validate_source_snapshot(data[ROOT/'downloads/source.zip'],data[ROOT/'downloads/mac-decode-phase-source.zip'],protocol)
    verifier=old.build_verifier()
    old.check_source_layout(ROOT,base_records);verifier.verify_source(ROOT,base_records)
    old.check_source_layout(old.SOURCE_PARENT,new_records);verifier.verify_source(old.SOURCE_PARENT,new_records)
    manifest=REF.load_json(data[ROOT/'downloads/mac-canterbury-input-manifest.json'])
    require(REF.manifest_digest(manifest['entries'])==REF.MANIFEST_SHA and
        tuple(r['name'] for r in manifest['entries'])==REF.INPUT_NAMES,'fixed eleven input hashes')
    return manifest


def child(parent_pid):
    require(parent_pid>1 and os.getppid()==parent_pid,'helper parent identity')
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'phase_run_child_setup',REF.SETUP_SHA);setup.validate_bootstrap(setup_path)
    started=REF.load_json(read(ROOT/'journal'/(PREFIX+'.started.json'),65536))
    require(started['endpoint_pid']==parent_pid and started['runner_sha256']==digest(read(Path(__file__),131072)) and
        started['recipe_sha256']==digest(canonical(recipe())),'helper runner/recipe identity')
    manifest=prerequisites(setup)
    observer_begin=time.monotonic()
    def fail(error,partial):
        try:
            write(RUN/'failure.json',dict(schema=1,error_type=type(error).__name__,error=str(error)[:2048],captures=len(partial),exit=70))
            write(RUN/'failure-observation.json',observer.report())
        finally:os._exit(70)
    def capture():
        process=subprocess.Popen([METRICS.as_posix()],stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True)
        stdout,stderr=process.communicate(timeout=.2)
        require(process.returncode==0 and not stderr and len(stdout)<=4096,'native observation output')
        return REF.load_json(stdout)
    observer=OBS.Observer(capture,on_failure=fail,on_capture=lambda r:write(RUN/('capture-%02d.json'%r['id']),r),max_captures=24)
    observer.start()
    try:
        require(observer.wait_entry_ready(6),'entry readiness timeout')
        command=setup.sandbox_command(ROOT)+recipe()['command']
        def spawn(command):
            pid=spawn_binary(command)
            write(RUN/'cli-started.json',dict(schema=1,pid=pid,command=command,recipe_sha256=started['recipe_sha256'],
                wait_flags=getattr(os,'WNOHANG',1),decode_seconds=20))
            return pid
        measured=run_once(command,observer,spawn=spawn);write(RUN/'measurement.json',measured)
        require(measured['metric']['normal_exit'] is True and measured['metric']['exit_code']==0 and
            measured['stderr_bytes']==0,'diagnostic exit/stderr')
        stdout=read(RUN/'phase.stdout',LOG_LIMIT);phase=validate_phase_stdout(stdout,measured['metric']['elapsed_ns'])
        REF.verify_files(RUN/'decoded',manifest['entries']);local_counts()
        write(RUN/'restored.json',dict(schema=1,files=manifest['entries'],manifest_sha256=REF.MANIFEST_SHA))
        remaining=35-(time.monotonic()-observer_begin)
        require(remaining>0 and observer.join(remaining),'bounded observer completion')
        raw=observer.report();validate_observation(raw);observation_sha=write(RUN/'observation.json',raw)
        write(RUN/'report.json',dict(schema=1,purpose=PURPOSE,superiority_decision_allowed=False,status='completed',
            runner_sha256=started['runner_sha256'],recipe_sha256=started['recipe_sha256'],binary_sha256=BINARY_SHA,
            source_sha256=SOURCE_SHA,build_receipt_sha256=BUILD_RECEIPT_SHA,build_closure_sha256=BUILD_CLOSURE_SHA,
            phase_stdout_sha256=digest(stdout),measurement_sha256=digest(read(RUN/'measurement.json',65536)),
            observation_sha256=observation_sha,restored_manifest_sha256=REF.MANIFEST_SHA,
            phase_count=len(phase['phase_report']['phases']),claims='single invocation; inclusive diagnostic only; no superiority decision'))
    except BaseException as error:fail(error,observer.report()['captures'])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--helper-parent-pid',type=int)
    args=parser.parse_args()
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(Path(__file__).absolute()==ROOT/'tools/mac-khc-decode-phase-run.py','runner location')
    os.umask(0o077)
    if args.helper_parent_pid is not None:child(args.helper_parent_pid);return 0
    begin=time.monotonic();setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'phase_run_setup',REF.SETUP_SHA);setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT,private=True);setup.checked_path(ROOT/'journal',private=True)
    manifest=prerequisites(setup)
    require(2810784+24*2048+8*65536+2*LOG_LIMIT+JOURNAL_BYTES<MAX_BYTES and 3+11+24+10+JOURNAL_ENTRIES<=MAX_ENTRIES,'prospective output budget')
    started=ROOT/'journal'/(PREFIX+'.started.json');terminal=ROOT/'journal'/(PREFIX+'.terminal.json')
    require(not started.exists() and not started.is_symlink() and not terminal.exists() and not terminal.is_symlink(),'journal already occupied')
    setup.admit(ROOT,MAX_BYTES)
    # mkdirの排他claimに負けた側はtryへ入らずterminalも作らない。
    RUN.mkdir(mode=0o700)
    runner_sha=digest(read(Path(__file__),131072));recipe_sha=digest(canonical(recipe()))
    identity=dict(schema=1,purpose=PURPOSE,superiority_decision_allowed=False,runner_sha256=runner_sha,
        recipe_sha256=recipe_sha,recipe=recipe(),binary_sha256=BINARY_SHA,source_sha256=SOURCE_SHA,
        build_receipt_sha256=BUILD_RECEIPT_SHA,build_closure_sha256=BUILD_CLOSURE_SHA,amendment_sha256=AMENDMENT_SHA)
    original_admit,original_env=setup.admit,setup.child_environment
    supervisor=FS.Supervisor(ROOT,support=setup);status,error,proof,report_sha='failed',None,None,None
    try:
        (RUN/'decoded').mkdir(mode=0o700);(RUN/'temp').mkdir(mode=0o700)
        setup.new_json(started,dict(identity,endpoint_pid=os.getpid(),parent_pid=os.getppid(),started_unix_ns=time.time_ns()))
        def guard(root,extra=0):
            require(time.monotonic()-begin<40,'diagnostic runtime deadline');local_counts()
            # 動的RUNの部分走査とは差し引かず、8MiB全額を常時追加予約する。
            return original_admit(root,MAX_BYTES+extra)
        def environment(root):
            result=original_env(root)
            for key in ('TEMP','TMP','TMPDIR'):result[key]=(RUN/'temp').as_posix()
            return result
        setup.admit,setup.child_environment=guard,environment;setup.LOG_LIMIT=LOG_LIMIT
        caught=None
        try:
            output=supervisor.run(['/usr/bin/python3','-I','-B',str(Path(__file__)),'--helper-parent-pid',str(os.getpid())],timeout=35,cwd=RUN)
            require(output=='','unexpected helper stdout')
        except BaseException as failure:caught=failure
        proof=supervisor.last_closure;write(RUN/'closure.json',proof)
        require(proof is not None and FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')) and
            caught is None and proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and
            proof['actual_returncode']==0,'helper primary/closure: '+str(caught))
        measured=REF.load_json(read(RUN/'measurement.json',65536));raw=REF.load_json(read(RUN/'observation.json',65536))
        validate_observation(raw);validate_phase_stdout(read(RUN/'phase.stdout',LOG_LIMIT),measured['metric']['elapsed_ns'])
        require(read(RUN/'phase.stderr',LOG_LIMIT)==b'' and measured['recipe_sha256']==recipe_sha,'saved output/recipe binding')
        require(measured['event']==raw['events'][0] and measured['metric']['normal_exit'] is True and
            measured['metric']['exit_code']==0 and 0<measured['metric']['elapsed_ns']<=20_000_000_000,'saved wait/event binding')
        report=REF.load_json(read(RUN/'report.json',65536))
        require(report['runner_sha256']==runner_sha and report['recipe_sha256']==recipe_sha and
            report['phase_stdout_sha256']==digest(read(RUN/'phase.stdout',LOG_LIMIT)) and
            report['measurement_sha256']==digest(read(RUN/'measurement.json',65536)) and
            report['observation_sha256']==digest(read(RUN/'observation.json',65536)),'report raw hashes')
        REF.verify_files(RUN/'decoded',manifest['entries']);report_sha=digest(read(RUN/'report.json',65536));status='done'
    except BaseException as failure:error=(type(failure).__name__+': '+str(failure))[:2048]
    finally:setup.admit,setup.child_environment=original_admit,original_env
    counts=None;postchecks=False;artifacts=[]
    try:
        prerequisites(setup)
        require(digest(read(Path(__file__),131072))==runner_sha,'runner changed after execution')
        counts=local_counts();original_admit(ROOT,MAX_BYTES)
        require(time.monotonic()-begin<=60,'native finalization deadline');postchecks=True
    except BaseException as failure:status='failed';error=(((error+'; ') if error else '')+type(failure).__name__+': '+str(failure))[:4096]
    try:
        artifacts=artifact_refs()
        if any(not row['within_bound'] for row in artifacts):
            status='failed';postchecks=False;error=(((error+'; ') if error else '')+'raw artifact output bound exceeded')[:4096]
    except BaseException as failure:
        status='failed';postchecks=False;error=(((error+'; ') if error else '')+'artifact binding: '+str(failure))[:4096]
    closed=bool(proof is not None and FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')))
    result=dict(identity,status=status,error=error,exit=0 if status=='done' else 1,children_absent=closed,
        postchecks_ok=postchecks,closure_sha256=digest(canonical(proof)) if proof is not None else None,
        report_sha256=report_sha,artifacts=artifacts,counts=counts,runtime_seconds=time.monotonic()-begin)
    if result['status']=='done':require(closed and postchecks,'done closure/postchecks')
    # runtime_secondsはJSON準備時点。初回fsync後にも成功資格の60sを確認する。
    def replace_late(value,first_sha):
        setup.checked_path(terminal);read(terminal,65536,first_sha)
        temporary=ROOT/'journal'/(PREFIX+'.terminal-deadline.json')
        require(not temporary.exists() and not temporary.is_symlink(),'deadline temporary occupied')
        final_sha=write(temporary,value);setup.checked_path(temporary);read(temporary,65536,final_sha)
        read(terminal,65536,first_sha);os.replace(temporary,terminal);read(terminal,65536,final_sha)
    result=persist_terminal(result,begin,lambda value:write(terminal,value),replace_late)
    sys.stdout.buffer.write(canonical(result));return result['exit']


if __name__=='__main__':sys.exit(main())
