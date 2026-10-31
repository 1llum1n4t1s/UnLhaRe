#!/usr/bin/env python3
"""One-shot KHC decode stack diagnostic. No benchmark or improvement claim.

The owned CLI PID is deliberately not reaped until its sampler has completed.
The outer finite supervisor owns closure of the helper, CLI and sampler group.
"""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import time
import zipfile

ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX='mac-khc-decode-sample-20261027'
RUN=ROOT/'tmp'/PREFIX
CLI=ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli'
ARCHIVE=ROOT/'tmp/mac-canterbury-continuous-reference-20261027/00-archive.khc'
METRICS=ROOT/'tools/mac-native-system-metrics'
SAMPLE=Path('/usr/bin/sample')
REFERENCE_SHA='a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4'
BUILD_SHA='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb'
SUPERVISOR_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
OBSERVER_SHA='416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
ARCHIVE_SHA='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee'
REFERENCE_TERMINAL_SHA='88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e'
TIMING_LABEL='includes profiler completion wait; not benchmark timing'
PROFILE_LIMIT=256*1024
LOG_LIMIT=16384
MAX_BYTES,MAX_ENTRIES=8*1024**2,64
JOURNAL_BYTES,JOURNAL_ENTRIES=131072,4


class Refusal(RuntimeError):
    pass


def require(ok,message):
    if not ok:raise Refusal(message)


def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path,maximum,expected=None):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=maximum,'file type/link/bound: '+str(path))
    with path.open('rb') as stream:data=stream.read(maximum+1)
    require(len(data)<=maximum and (expected is None or digest(data)==expected),'file bytes/SHA: '+str(path))
    return data


def load(path,name,expected):
    read(path,131072,expected)
    spec=importlib.util.spec_from_file_location(name,str(path))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


HERE=Path(__file__).absolute().parent
REF=load(HERE/'mac-canterbury-reference.py','decode_sample_reference',REFERENCE_SHA)
BUILD=load(HERE/'mac-native-build.py','decode_sample_build',BUILD_SHA)
FS=load(HERE/'mac-finite-supervisor.py','decode_sample_finite',SUPERVISOR_SHA)
OBS=load(HERE/'mac-continuous-cpu-observer.py','decode_sample_observer',OBSERVER_SHA)


def write_bytes(path,data,maximum):
    require(type(data) is bytes and len(data)<=maximum,'output byte bound')
    with path.open('xb') as stream:
        stream.write(data);stream.flush();os.fsync(stream.fileno())
    return digest(data)


def write_json(path,value):
    return write_bytes(path,canonical(value),65536)


def quota_counts(total,count):
    require(type(total) is int and type(count) is int and total>=0 and count>=1,'quota types')
    require(total+JOURNAL_BYTES<=MAX_BYTES and count+JOURNAL_ENTRIES<=MAX_ENTRIES,'run plus journal quota')
    return dict(run_bytes=total,run_entries=count,journal_reserved_bytes=JOURNAL_BYTES,
        journal_reserved_entries=JOURNAL_ENTRIES,charged_bytes=total+JOURNAL_BYTES,charged_entries=count+JOURNAL_ENTRIES)


def local_counts():
    require(RUN.is_dir() and not RUN.is_symlink() and RUN.stat().st_uid==os.getuid(),'run identity')
    total,count=0,1
    def failed(error):raise Refusal('run walk failed') from error
    for directory,dirs,files in os.walk(RUN,followlinks=False,onerror=failed):
        for name in dirs+files:
            path=Path(directory)/name;info=path.lstat()
            require(info.st_uid==os.getuid() and not stat.S_ISLNK(info.st_mode) and
                (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)) and
                (not stat.S_ISREG(info.st_mode) or info.st_nlink==1),'run owner/type/link')
            count+=1
            if stat.S_ISREG(info.st_mode):
                total+=info.st_size
                if path==RUN/'sample.txt':require(info.st_size<=PROFILE_LIMIT,'live sample report bound')
    return quota_counts(total,count)


def validate_profile(data,pid):
    """Unknown native layouts are inconclusive, never grounds for another run."""
    require(type(data) is bytes and len(data)<=PROFILE_LIMIT,'profile byte bound')
    require(type(pid) is int and pid>1,'owned CLI PID')
    errors=[];roots=[];app=[];evidence=[]
    try:text=data.decode('utf-8')
    except UnicodeDecodeError:text='';errors.append('profile is not UTF-8')
    process=re.findall(r'^Process:\s+([^\n]+)$',text,re.M)
    paths=re.findall(r'^Path:\s+([^\n]+)$',text,re.M)
    if len(process)!=1 or re.fullmatch(r'unlhare-cli\s+\['+str(pid)+r'\]\s*',process[0]) is None:
        errors.append('profile process/executable/PID mismatch')
    if len(paths)!=1 or paths[0].strip()!=CLI.as_posix():errors.append('profile executable Path mismatch')
    markers=list(re.finditer(r'^Call graph:\s*$',text,re.M))
    if len(markers)!=1:errors.append('missing/duplicate Call graph')
    else:
        graph=text[markers[0].end():]
        graph=re.split(r'^Binary Images:',graph,maxsplit=1,flags=re.M)[0]
        for line in graph.splitlines():
            root=re.match(r'^\s+(\d+)\s+Thread_\d+\b',line)
            if root:roots.append(int(root[1]))
            if re.match(r'^\s*[+!|:* ]*\d+\s+.*\(in unlhare-cli\)',line):app.append(line[:384])
            if re.search(r'\b(fsync|fcntl|write|unlhare::\w+)\b',line) and len(evidence)<16:evidence.append(line[:384])
    if not roots or max(roots)<5:errors.append('no Thread_N root with at least 5 samples')
    if not app:errors.append('no application frame in Call graph')
    return dict(state='inconclusive' if errors else 'observed',errors=errors,root_samples=max(roots,default=0),
        app_frames=app[:16],evidence_lines=evidence,scope='sampled instants only; no complete-cause or performance claim')


def validate_sampler(value):
    require(type(value) is dict and set(value)=={'returncode','stdout','stderr'} and
        type(value['returncode']) is int and value['returncode']==0 and
        all(type(value[k]) is bytes and len(value[k])<=LOG_LIMIT for k in ('stdout','stderr')),
        'sampler return code/output bound')


def run_process(command,timeout):
    # timeout/overflow時はhelperが70で閉じ、外側が共通groupを回収する。
    # CLIはこのAPIへ渡さない。CLIのreapはmeasure_once末尾のwait4一回だけ。
    process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True)
    stdout,stderr=process.communicate(timeout=timeout)
    return dict(returncode=process.returncode,stdout=stdout,stderr=stderr)


def spawn_cli(command):
    actions=[(os.POSIX_SPAWN_OPEN,n,'/dev/null',os.O_RDONLY if n==0 else os.O_WRONLY,0) for n in range(3)]
    return os.posix_spawn(command[0],command,dict(os.environ),file_actions=actions)


def measure_once(command,observer,*,spawn=None,sampler=None,wait=None,clock=time.monotonic_ns):
    spawn=spawn or spawn_cli;sampler=sampler or (lambda cmd:run_process(cmd,5));wait=wait or os.wait4
    token=observer.begin_event();start=clock()
    pid=spawn(command)
    require(type(pid) is int and pid>1,'spawned owned CLI PID')
    sample_command=[SAMPLE.as_posix(),str(pid),'1','1','-mayDie','-file',(RUN/'sample.txt').as_posix()]
    sample_result=sampler(sample_command)
    validate_sampler(sample_result)
    # sampleが完了するまではwait4/poll/PopenでCLIをreapしない。PID再利用を防ぐ。
    waited,status,usage=wait(pid,0)
    end=clock();event=observer.finish_event(token)
    require(waited==pid and type(status) is int and status>=0 and end>start,'wait4 identity/timing')
    signal=status & 0x7f;normal=signal==0
    require(normal or signal!=0x7f,'wait4 terminal child status')
    return dict(schema=1,pid=pid,command=command,sample_command=sample_command,timing_label=TIMING_LABEL,
        event={k:event[k] for k in ('id','start_ns','end_ns')},
        metric=dict(elapsed_ns=end-start,user_seconds=usage.ru_utime,system_seconds=usage.ru_stime,
            peak_rss_bytes=usage.ru_maxrss,normal_exit=normal,exit_code=(status>>8)&255 if normal else None,
            signal=None if normal else signal,cpu_per_wall=(usage.ru_utime+usage.ru_stime)*1e9/(end-start)))


def validate_observation(report):
    check=OBS.validate_report(report)
    require(check['eligible'] and report['max_captures']==8 and len(report['captures'])==8 and
        len(report['events'])==1,'fixed eight capture/one event observation: '+str(check['errors'])[:1024])
    require(report['events'][0]['end_ns']<report['captures'][7]['start_ns'],'diagnostic event ended after final capture')
    return check


def source_records(data):
    require(len(data)<=8*1024**2 and digest(data)==REF.PINS['source_sha256'],'source ZIP identity')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries=archive.infolist()
        require(0<len(entries)<=201 and len({e.filename for e in entries})==len(entries) and
            all(not e.is_dir() and not e.flag_bits & 1 and e.compress_type in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED)
                and stat.S_IFMT(e.external_attr>>16) in (0,stat.S_IFREG) for e in entries),'source ZIP member shape')
        manifest=archive.getinfo('snapshot-manifest.json')
        require(manifest.file_size<=65536,'source snapshot manifest bound')
        records=REF.load_json(archive.read(manifest))
        names=BUILD.validate_source_manifest(records)
        require(set(archive.namelist())==set(names)|{'snapshot-manifest.json'},'source ZIP complete set')
    return records


def pin_paths():
    return [(Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py',REF.SETUP_SHA,131072),
        (HERE/'mac-canterbury-reference.py',REFERENCE_SHA,131072),
        (HERE/'mac-native-build.py',BUILD_SHA,131072),(HERE/'mac-finite-supervisor.py',SUPERVISOR_SHA,131072),
        (HERE/'mac-continuous-cpu-observer.py',OBSERVER_SHA,131072),
        (CLI,REF.PINS['cli_sha256'],16*1024**2),(METRICS,REF.PINS['system_metrics_sha256'],1024**2),
        (ARCHIVE,ARCHIVE_SHA,450309),(ROOT/'downloads/source.zip',REF.PINS['source_sha256'],8*1024**2),
        (ROOT/'downloads/mac-canterbury-input-manifest.json',REF.PINS['input_manifest_sha256'],1988),
        (ROOT/'journal/mac-canterbury-continuous-reference.terminal.json',REFERENCE_TERMINAL_SHA,65536)]


def verify_inputs(setup):
    setup.checked_path(ROOT,private=True)
    for path,expected,maximum in pin_paths():
        setup.checked_path(path);require(path.stat().st_uid==os.getuid(),'input UID')
        read(path,maximum,expected)
    require(ARCHIVE.stat().st_size==450309,'archive exact length')
    setup.checked_path(SAMPLE)
    require(SAMPLE.stat().st_uid in (0,os.getuid()) and os.access(SAMPLE,os.X_OK),'system sample executable/owner')
    sample_sha=digest(read(SAMPLE,16*1024**2))
    records=source_records(read(ROOT/'downloads/source.zip',8*1024**2,REF.PINS['source_sha256']))
    for record in records:
        path=ROOT/'source'/record['path'];setup.checked_path(path)
        require(path.stat().st_uid==os.getuid(),'source UID')
    BUILD.verify_source(ROOT,records)
    manifest=REF.load_json(read(ROOT/'downloads/mac-canterbury-input-manifest.json',1988,REF.PINS['input_manifest_sha256']))
    require(REF.manifest_digest(manifest['entries'])==REF.MANIFEST_SHA and
        tuple(row['name'] for row in manifest['entries'])==REF.INPUT_NAMES,'input full manifest')
    sealed=REF.load_json(read(ROOT/'journal/mac-canterbury-continuous-reference.terminal.json',65536,REFERENCE_TERMINAL_SHA))
    require(sealed['children_absent'] is True and sealed['purpose']=='training-reference-only' and
        sealed['superiority_decision_allowed'] is False,'closed reference prerequisite')
    return records,manifest,sample_sha


def child(parent_pid):
    require(parent_pid==os.getppid() and parent_pid>1,'helper parent')
    identity=REF.load_json(read(ROOT/'journal'/(PREFIX+'.started.json'),65536))
    require(identity['endpoint_pid']==parent_pid and identity['script_sha256']==digest(read(Path(__file__),131072)),'helper binding')
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'decode_sample_child_setup',REF.SETUP_SHA)
    setup.validate_bootstrap(setup_path)
    _,manifest,sample_sha=verify_inputs(setup)
    require(sample_sha==identity['sample_tool_sha256'],'helper sample tool changed')
    def capture():
        result=run_process([METRICS.as_posix()],.2)
        require(result['returncode']==0 and not result['stderr'] and len(result['stdout'])<=4096,'native metrics output')
        return REF.load_json(result['stdout'])
    def failure(error,partial):
        try:write_json(RUN/'failure.json',dict(schema=1,error_type=type(error).__name__,error=str(error)[:2048],captures=len(partial),exit=70))
        finally:os._exit(70)
    def persist_capture(record):write_json(RUN/('capture-%02d.json'%record['id']),record)
    observer=OBS.Observer(capture,on_failure=failure,on_capture=persist_capture,max_captures=8)
    observer.start()
    try:
        require(observer.wait_entry_ready(6),'entry readiness timeout')
        command=setup.sandbox_command(ROOT)+[CLI.as_posix(),'khc-extract',ARCHIVE.as_posix(),'--output',(RUN/'decoded').as_posix()]
        def spawn(command):
            pid=spawn_cli(command)
            write_json(RUN/'cli-started.json',dict(schema=1,pid=pid,command=command,wait4_deferred_until_sample_complete=True))
            return pid
        def sampler(command):
            result=run_process(command,5)
            for side in ('stdout','stderr'):write_bytes(RUN/('sample.'+side),result[side][:LOG_LIMIT],LOG_LIMIT)
            write_json(RUN/'sampler-result.json',dict(returncode=result['returncode'],stdout_bytes=len(result['stdout']),stderr_bytes=len(result['stderr'])))
            return result
        measured=measure_once(command,observer,spawn=spawn,sampler=sampler)
        write_json(RUN/'measurement.json',measured)
        require(measured['metric']['normal_exit'] and measured['metric']['exit_code']==0,'decode CLI failed')
        REF.verify_files(RUN/'decoded',manifest['entries'])
        # 照合済み全11件を保存し、短いprofileでも復元の成功と区別する。
        write_json(RUN/'restored.json',dict(schema=1,files=manifest['entries'],manifest_sha256=REF.MANIFEST_SHA))
        profile=validate_profile(read(RUN/'sample.txt',PROFILE_LIMIT),measured['pid']) if (RUN/'sample.txt').exists() else validate_profile(b'',measured['pid'])
        require(observer.join(10),'fixed observer completion timeout')
        raw=observer.report();validate_observation(raw)
        observation_sha=write_json(RUN/'observation.json',raw)
        write_json(RUN/'report.json',dict(schema=1,purpose='non-comparative-decode-stack-diagnostic',
            superiority_decision_allowed=False,status=profile['state'],profile=profile,
            timing_label=TIMING_LABEL,measurement_sha256=digest(read(RUN/'measurement.json',65536)),
            observation_sha256=observation_sha,restored_manifest_sha256=REF.MANIFEST_SHA,
            profile_sha256=digest(read(RUN/'sample.txt',PROFILE_LIMIT)) if (RUN/'sample.txt').exists() else None,
            cli_pid=measured['pid'],script_sha256=identity['script_sha256'],claims='sampled instants only; no total cause or improvement rate'))
    except BaseException as error:failure(error,observer.report()['captures'])


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--helper-parent-pid',type=int)
    args=parser.parse_args()
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(Path(__file__).absolute()==ROOT/'tools/mac-khc-decode-sample.py','endpoint location')
    os.umask(0o077)
    require(2810784+PROFILE_LIMIT+12*65536+2*LOG_LIMIT+JOURNAL_BYTES<MAX_BYTES and 1+2+11+8+10+JOURNAL_ENTRIES<MAX_ENTRIES,'prospective output budget')
    if args.helper_parent_pid is not None:child(args.helper_parent_pid);return 0
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'decode_sample_setup',REF.SETUP_SHA);setup.validate_bootstrap(setup_path)
    records,manifest,sample_sha=verify_inputs(setup)
    started=ROOT/'journal'/(PREFIX+'.started.json');terminal=ROOT/'journal'/(PREFIX+'.terminal.json')
    require(not RUN.exists() and not started.exists() and not terminal.exists(),'diagnostic already attempted')
    setup.admit(ROOT,MAX_BYTES)
    identity=dict(schema=1,purpose='non-comparative-decode-stack-diagnostic',superiority_decision_allowed=False,
        script_sha256=digest(read(Path(__file__),131072)),archive_sha256=ARCHIVE_SHA,cli_sha256=REF.PINS['cli_sha256'],
        source_sha256=REF.PINS['source_sha256'],input_manifest_sha256=REF.PINS['input_manifest_sha256'],
        reference_terminal_sha256=REFERENCE_TERMINAL_SHA,sample_tool_sha256=sample_sha,
        observer_sha256=OBSERVER_SHA,supervisor_sha256=SUPERVISOR_SHA,setup_sha256=REF.SETUP_SHA,
        build_sha256=BUILD_SHA,reference_sha256=REFERENCE_SHA,metrics_sha256=REF.PINS['system_metrics_sha256'],timing_label=TIMING_LABEL,
        journal_reserved_bytes=JOURNAL_BYTES,journal_reserved_entries=JOURNAL_ENTRIES,
        runtime_seconds=20,helper_timeout_seconds=15,final_elapsed_limit_seconds=40)
    setup.new_json(started,dict(identity,endpoint_pid=os.getpid(),parent_pid=os.getppid(),started_unix_ns=time.time_ns()))
    begin=time.monotonic();original_admit,original_environment=setup.admit,setup.child_environment
    supervisor=FS.Supervisor(ROOT,support=setup)
    status,error,closure_sha,report_sha,absent='failed-diagnostic',None,None,None,False
    def guard(root,extra=0):
        require(time.monotonic()-begin<20,'diagnostic runtime deadline');local_counts()
        return original_admit(root,extra)
    def environment(root):
        values=original_environment(root)
        for name in ('TEMP','TMP','TMPDIR'):values[name]=str(RUN/'temp')
        return values
    try:
        RUN.mkdir(mode=0o700);(RUN/'decoded').mkdir(mode=0o700);(RUN/'temp').mkdir(mode=0o700)
        setup.LOG_LIMIT=LOG_LIMIT;setup.admit,setup.child_environment=guard,environment
        caught=None
        try:
            # helper/sampleはsandbox外。CLIだけがhelper内でfrozen sandboxへ入る。
            output=supervisor.run(['/usr/bin/python3','-I','-B',str(Path(__file__)),'--helper-parent-pid',str(os.getpid())],timeout=15,cwd=RUN)
            require(output=='','helper output')
        except BaseException as failure:caught=failure
        proof=supervisor.last_closure;closure_sha=write_json(RUN/'closure.json',proof)
        absent=FS.validate_closure(proof,proof['pid'],proof['sequence'])
        require(absent and caught is None and proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and
            proof['actual_returncode']==0,'helper outcome/closure: '+str(caught))
        report=REF.load_json(read(RUN/'report.json',65536));raw=REF.load_json(read(RUN/'observation.json',65536))
        validate_observation(raw)
        measured=REF.load_json(read(RUN/'measurement.json',65536))
        recomputed=validate_profile(read(RUN/'sample.txt',PROFILE_LIMIT),measured['pid']) if (RUN/'sample.txt').exists() else validate_profile(b'',measured['pid'])
        require(report['script_sha256']==identity['script_sha256'] and canonical(report['profile'])==canonical(recomputed) and
            report['status']==recomputed['state'] and report['timing_label']==TIMING_LABEL,'saved report binding')
        REF.verify_files(RUN/'decoded',manifest['entries'])
        report_sha=digest(read(RUN/'report.json',65536));status=recomputed['state']
    except BaseException as failure:status,error='failed-diagnostic',str(failure)[:2048]
    finally:setup.admit,setup.child_environment=original_admit,original_environment
    counts=None
    try:
        _,_,after_sample=verify_inputs(setup)
        require(after_sample==sample_sha and digest(read(Path(__file__),131072))==identity['script_sha256'],'after diagnostic executable changed')
        BUILD.verify_source(ROOT,records)
        counts=local_counts();original_admit(ROOT)
        require(time.monotonic()-begin<=40,'final diagnostic elapsed bound')
    except BaseException as failure:status,error='failed-diagnostic',((error+'; ') if error else '')+str(failure)[:2048]
    result=dict(identity,status=status,error=error,children_absent=bool(absent),closure_sha256=closure_sha,
        report_sha256=report_sha,counts=counts,elapsed_seconds=time.monotonic()-begin,
        exit=0 if status in ('observed','inconclusive') else 1)
    write_json(terminal,result);sys.stdout.write(canonical(result).decode());return result['exit']


if __name__=='__main__':sys.exit(main())
