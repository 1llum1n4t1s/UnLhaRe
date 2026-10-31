#!/usr/bin/env python3
"""固定sleep2だけでsandbox signal境界を診断する。benchmark再開の許可には使わない。"""
import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import select
import signal
import subprocess
import sys
import threading
import time

ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX='mac-signal-boundary-probe-20261027'
RUN=ROOT/'tmp'/PREFIX
CAL_SHA='cb5ef0c6f4b4eb10f7f8c0ca17bc49620f815d29723e28ed386410bb9ae617b0'
SETUP_SHA='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
PHASES=('sandbox','control')


def require(ok,message):
    if not ok: raise ValueError(message)


def parse_ps(text,requested):
    """-wwで完全commandを保持。列欠落・重複・対象外PIDは不明扱い。"""
    result={}
    for line in text.splitlines():
        if not line.strip(): continue
        parts=line.split(None,10)
        require(len(parts)==11,'ps missing columns')
        try: pid,ppid,pgid,uid=map(int,parts[:4])
        except ValueError: raise ValueError('ps invalid integer') from None
        require(pid in requested and pid not in result and pid>0 and min(ppid,pgid,uid)>=0,'ps identity')
        result[pid]=dict(pid=pid,ppid=ppid,pgid=pgid,uid=uid,stat=parts[4],
                         started=' '.join(parts[5:10]),command=parts[10])
    return result


def _complete(value):
    return (type(value) is dict and set(value)=={'pid','ppid','pgid','uid','stat','started','command'}
            and all(type(value[k]) is int and value[k]>=0 for k in ('pid','ppid','pgid','uid'))
            and all(type(value[k]) is str and value[k] for k in ('stat','started','command'))
            and not value['stat'].startswith('Z'))


def group_allowed(helper,fixture,helper_pid,fixture_pid,uid):
    return (_complete(helper) and _complete(fixture) and helper_pid!=fixture_pid
            and helper_pid>1 and fixture_pid>1
            and helper['pid']==helper_pid and helper['pgid']==helper_pid and helper['uid']==uid
            and fixture['pid']==fixture_pid and fixture['pgid']==helper_pid
            and fixture['ppid']==helper_pid and fixture['uid']==uid
            and fixture['command']=='/bin/sleep 2')


def pid_allowed(before,current,fixture_pid,pgid,uid):
    keys=('pid','ppid','pgid','uid','started','command')
    return (_complete(before) and _complete(current) and fixture_pid>1 and pgid>1
            and all(before[k]==current[k] for k in keys)
            and current['pid']==fixture_pid and current['pgid']==pgid and current['uid']==uid
            and current['command']=='/bin/sleep 2')


def classify_outcome(sent,absent):
    if absent: return 'signal-sent-then-absent' if sent else 'natural-exit-candidate'
    return 'unresolved'


def phase_allows_next(result):
    """自然終了候補も不在確認は必須。成功したsignal送信との区別はstatusへ残す。"""
    return (result.get('fixture_absent') is True and 'error' not in result
            and result.get('status') in ('signal-sent-then-absent','natural-exit-candidate'))


def final_hash_snapshot(paths,digest):
    hashes,errors={},[]
    for path in paths:
        try: hashes[str(path)]=digest(path)
        except Exception as exc:
            hashes[str(path)]=None
            errors.append(('final SHA '+str(path)+': '+type(exc).__name__+': '+str(exc))[:2048])
    return hashes,errors


def final_count_snapshot(counter):
    try: return dict(counts=counter(),counts_error=None)
    except Exception as exc:
        return dict(counts=None,counts_error=(type(exc).__name__+': '+str(exc))[:2048])


def phase_order(values): return list(values)==list(PHASES)


def valid_step_order(steps):
    names=[x.get('step') for x in steps]
    expected=['live-ps','live-getpgid','live-pid-signal0','live-getpgid','live-pid-signal0',
              'live-group-signal0','release','helper-wait','reaped-ps','reaped-getpgid',
              'reaped-pid-signal0','reaped-getpgid','reaped-pid-signal0','reaped-group-signal0','prekill-ps']
    if names[:len(expected)]!=expected: return False
    if not all(type(s.get('start_ns')) is int and type(s.get('end_ns')) is int
               and 0<=s['start_ns']<=s['end_ns'] for s in steps): return False
    if any(a['end_ns']>b['start_ns'] for a,b in zip(steps,steps[1:])): return False
    wait=steps[7]
    if wait.get('ok') is not True or wait.get('value')!=70: return False
    if 'fixture-SIGKILL' in names:
        if names.count('group-SIGKILL')!=1 or names.count('fallback-ps')!=1: return False
        group=names.index('group-SIGKILL')
        if steps[group].get('ok') is not False: return False
        if not group<names.index('fallback-ps')<names.index('fixture-SIGKILL'): return False
    return names.count('group-SIGKILL')<=1 and names.count('fixture-SIGKILL')<=1


def quota_ok(size,count):
    return type(size) is int and type(count) is int and 0<=size<=2097152 and 0<=count<=32


def sha(path):
    with Path(path).open('rb') as stream: data=stream.read(32*1024*1024+1)
    require(len(data)<=32*1024*1024,'SHA input bound')
    return hashlib.sha256(data).hexdigest()


def load(path,name,expected):
    require(sha(path)==expected,'dependency SHA: '+str(path))
    spec=importlib.util.spec_from_file_location(name,str(path))
    value=importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value


def child():
    """helperはsignal/group取得を行わず、fixture stdioは全て/dev/nullへ。"""
    fd=os.open('/dev/null',os.O_RDWR)
    actions=[(os.POSIX_SPAWN_DUP2,fd,target) for target in (0,1,2)]
    if fd>2: actions.append((os.POSIX_SPAWN_CLOSE,fd))
    start=time.monotonic_ns()
    pid=os.posix_spawn('/bin/sleep',['/bin/sleep','2'],os.environ,file_actions=actions)
    os.close(fd)
    entered=threading.Event()
    def release_waiter():
        try:
            entered.wait()
            ready,_,_=select.select([0],[],[],1.0)
            if ready and os.read(0,1)==b'\n': os._exit(70)
            os._exit(71)
        except BaseException: os._exit(73)
    threading.Thread(target=release_waiter,name='probe-release',daemon=True).start()
    record=dict(helper_pid=os.getpid(),helper_uid=os.getuid(),helper_euid=os.geteuid(),
                helper_ppid=os.getppid(),fixture_pid=pid,spawn_start_ns=start,spawn_end_ns=time.monotonic_ns())
    record['wait4_entered_ns']=time.monotonic_ns()
    print(json.dumps(record,separators=(',',':')),flush=True)
    entered.set()
    os.wait4(pid,0)
    os._exit(72)


def call_record(steps,label,target,callback):
    record=dict(step=label,target=target,start_ns=time.monotonic_ns())
    try:
        record.update(ok=True,value=callback(),errno=None)
    except OSError as exc:
        record.update(ok=False,value=None,errno=exc.errno,error=str(exc)[:512])
    except Exception as exc:
        record.update(ok=False,value=None,errno=None,error=str(exc)[:512])
    record['end_ns']=time.monotonic_ns(); steps.append(record)
    return record


def ps_snapshot(steps,label,pids,cwd,env):
    def capture():
        result=subprocess.run(['/bin/ps','-ww','-p',','.join(map(str,pids)),
                               '-o','pid=,ppid=,pgid=,uid=,stat=,lstart=,command='],
                              stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                              cwd=cwd,env=env,timeout=0.5)
        require(len(result.stdout)<=8192 and len(result.stderr)<=2048,'ps output bound')
        raw=result.stdout.decode('utf-8','strict')
        require(result.returncode in (0,1),'ps returncode')
        return dict(returncode=result.returncode,raw=raw,stderr=result.stderr.decode('utf-8','replace'),
                    identities=parse_ps(raw,pids))
    record=call_record(steps,label,pids,capture)
    return record['value']['identities'] if record['ok'] else {}


def checks(steps,label,helper,fixture):
    # 全項目を独立記録。最初のEPERMで中断しない。
    for pid in (helper,fixture):
        call_record(steps,label+'-getpgid',pid,lambda pid=pid:os.getpgid(pid))
        call_record(steps,label+'-pid-signal0',pid,lambda pid=pid:os.kill(pid,0))
    call_record(steps,label+'-group-signal0',helper,lambda:os.killpg(helper,0))


def read_handshake(process):
    deadline=time.monotonic()+0.75; data=b''
    while b'\n' not in data:
        remaining=deadline-time.monotonic()
        require(remaining>0,'helper handshake timeout')
        ready,_,_=select.select([process.stdout],[],[],remaining)
        require(bool(ready),'helper handshake timeout')
        block=os.read(process.stdout.fileno(),1)
        require(block and len(data)<2048,'helper handshake EOF/bound')
        data+=block
    value=json.loads(data)
    require(type(value) is dict and set(value)=={'helper_pid','helper_uid','helper_euid','helper_ppid',
            'fixture_pid','spawn_start_ns','spawn_end_ns','wait4_entered_ns'} and
            all(type(x) is int and x>=0 for x in value.values()),'helper handshake schema')
    return value


def probe_phase(phase,command,env,cwd,deadline):
    steps=[]; result=dict(phase=phase,steps=steps,status='inconclusive',outer_uid=os.getuid(),outer_euid=os.geteuid())
    require(time.monotonic()<deadline,'total runtime deadline')
    process=None
    try:
        result['spawn_start_ns']=time.monotonic_ns()
        process=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
                                 cwd=cwd,env=env,start_new_session=True,bufsize=0)
        result['spawn_end_ns']=time.monotonic_ns(); result['helper_pid']=process.pid
        hello=read_handshake(process); result['handshake']=hello
        hp,fp=process.pid,hello['fixture_pid']
        require(hello['helper_pid']==hp and hello['helper_ppid']==os.getpid() and fp!=hp and fp>1,'helper PID mismatch')
        live=ps_snapshot(steps,'live-ps',[hp,fp],cwd,env)
        checks(steps,'live',hp,fp)
        owned=group_allowed(live.get(hp),live.get(fp),hp,fp,os.getuid())
        owned=owned and hello['helper_uid']==os.getuid() and hello['helper_euid']==os.geteuid()
        result['owned_group_proven']=owned
        # 一秒handshakeの期限内に親がreleaseできなければinconclusive。
        require(process.poll() is None,'helper exited before release')
        call_record(steps,'release',hp,lambda:process.stdin.write(b'\n'))
        process.stdin.close()
        reaped=call_record(steps,'helper-wait',hp,lambda:process.wait(timeout=1.5))
        require(reaped['ok'] and reaped['value']==70,'helper was not reaped with exit70')
        post=ps_snapshot(steps,'reaped-ps',[hp,fp],cwd,env)
        checks(steps,'reaped',hp,fp)
        prekill=ps_snapshot(steps,'prekill-ps',[fp],cwd,env)
        anchor=live.get(fp); current=prekill.get(fp)
        # reparentは許容するがPID/UID/PGID/start/fullcommandはlive記録と一致必須。
        same_fixture=(_complete(anchor) and _complete(current) and
                      all(anchor[k]==current[k] for k in ('pid','uid','pgid','started','command')))
        group_sent=False; pid_sent=False
        if owned and same_fixture:
            attempt=call_record(steps,'group-SIGKILL',hp,lambda:os.killpg(hp,signal.SIGKILL))
            group_sent=attempt['ok']
            if not group_sent:
                final=ps_snapshot(steps,'fallback-ps',[fp],cwd,env).get(fp)
                # baselineはhelper reap後。PPIDを含め、直前snapshotとの完全一致を確認。
                if pid_allowed(current,final,fp,hp,os.getuid()):
                    pid_sent=call_record(steps,'fixture-SIGKILL',fp,lambda:os.kill(fp,signal.SIGKILL))['ok']
                else: result['fallback_skipped']='identity unknown/changed'
        else: result['kill_skipped']='identity unknown/changed/fixture already absent'
        until=min(deadline,time.monotonic()+3.0); absent=False
        while time.monotonic()<until:
            check=call_record(steps,'fixture-existence',fp,lambda:os.kill(fp,0))
            if not check['ok'] and check['errno']==errno.ESRCH:
                absent=True; break
            time.sleep(0.1)
        outcome=classify_outcome(group_sent or pid_sent,absent)
        result.update(status=outcome if owned and same_fixture and absent else 'inconclusive',outcome=outcome,
                      group_signal_sent=group_sent,pid_signal_sent=pid_sent,fixture_absent=absent,
                      post_reap_fixture=post.get(fp))
        require(valid_step_order(steps),'phase operation ordering')
    except Exception as exc:
        result['status']='inconclusive'
        result['error']=str(exc)[:2048]
    finally:
        if process is not None:
            if process.stdin and not process.stdin.closed: process.stdin.close()
            # unknownなPIDへsignalせず、helperの一秒期限とsleep2自然終了を待つ。
            call_record(steps,'final-helper-wait',process.pid,lambda:process.wait(timeout=3.0))
            if process.stdout: process.stdout.close()
            if 'fixture_absent' not in result:
                remaining=min(2.1,max(0,deadline-time.monotonic()))
                call_record(steps,'inconclusive-natural-wait',None,lambda:time.sleep(remaining))
        result['end_ns']=time.monotonic_ns()
    return result


def local_counts():
    total,count=0,1
    for path in RUN.rglob('*'):
        require(not path.is_symlink() and path.stat().st_uid==os.getuid(),'run object identity')
        count+=1
        if path.is_file():
            require(path.stat().st_nlink==1,'run hardlink'); total+=path.stat().st_size
    # started/terminalとreportの最大保存予約を含む。
    require(quota_ok(total+3*65536,count+3),'aggregate 2MiB/32 quota')
    return dict(charged_bytes=total+3*65536,charged_entries=count+3)


def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--child',action='store_true')
    args=parser.parse_args()
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(Path(__file__).absolute()==ROOT/'tools/mac-signal-boundary-probe.py','script location')
    os.umask(0o077)
    if args.child: child(); return 70
    cal_path=ROOT/'tools/mac-cpu-observation-calibration.py'
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    cal=load(cal_path,'signal_probe_calibration',CAL_SHA)
    setup=load(setup_path,'signal_probe_setup',SETUP_SHA)
    setup.validate_bootstrap(setup_path); setup.checked_path(ROOT,private=True)
    measure_path=ROOT/'tools/mac-canterbury-measure.py'
    require(sha(measure_path)==cal.MEASURE_SHA,'frozen measure SHA')
    pins=[Path(__file__),cal_path,setup_path,measure_path,Path('/usr/bin/python3'),Path('/bin/sleep'),
          Path('/bin/ps'),Path('/usr/bin/sandbox-exec')]
    before={str(path):sha(path) for path in pins}
    for path in pins: setup.checked_path(path)
    started=ROOT/'journal'/(PREFIX+'.started.json'); terminal=ROOT/'journal'/(PREFIX+'.terminal.json')
    require(not RUN.exists() and not started.exists() and not terminal.exists(),'one-shot already attempted')
    setup.admit(ROOT,2097152)
    identity=dict(schema=1,purpose='no-codec-signal-boundary-diagnosis',prefix=PREFIX,
                  benchmark_restart_allowed=False,native_codec_payloads=0,
                  source_executable_sha256_before=before,conditions=list(PHASES),
                  runtime_seconds=20,final_elapsed_limit_seconds=40,quota_bytes=2097152,quota_entries=32,
                  outer_uid=os.getuid(),outer_euid=os.geteuid())
    setup.new_json(started,identity)
    RUN.mkdir(mode=0o700); begin=time.monotonic(); results=[]; error=None
    try:
        env=setup.child_environment(ROOT)
        for name in ('TEMP','TMP','TMPDIR'): env[name]=str(RUN)
        helper=['/usr/bin/python3','-I','-B',str(Path(__file__)),'--child']
        for phase in PHASES:
            require(time.monotonic()-begin<20,'total runtime deadline'); local_counts(); setup.admit(ROOT)
            command=(setup.sandbox_command(ROOT) if phase=='sandbox' else [])+helper
            results.append(probe_phase(phase,command,env,RUN,begin+20))
            require(phase_allows_next(results[-1]),'prior fixture unresolved/inconclusive; later phase prohibited')
        require(phase_order([x['phase'] for x in results]),'fixed condition order')
    except Exception as exc: error=str(exc)[:2048]
    after,final_errors=final_hash_snapshot(pins,sha)
    if after!=before: final_errors.append('source/executable SHA changed/unreadable')
    try: setup.admit(ROOT)
    except Exception as exc: final_errors.append(('final global admit: '+str(exc))[:2048])
    counts=final_count_snapshot(local_counts)
    if counts['counts_error'] is not None: final_errors.append('final counts unavailable')
    if time.monotonic()-begin>40: final_errors.append('final elapsed limit exceeded')
    complete=(error is None and not final_errors and len(results)==2 and all(phase_allows_next(r) for r in results))
    result=dict(identity,results=results,error=error,status='completed-diagnosis' if complete else 'inconclusive-diagnosis',
                source_executable_sha256_after=after,final_errors=final_errors,
                elapsed_seconds=time.monotonic()-begin,**counts)
    data=json.dumps(result,sort_keys=True,separators=(',',':')).encode()
    require(len(data)<=65536,'report bound')
    try: cal.write(RUN/'report.json',result)
    except Exception as exc:
        result['final_errors'].append(('report persistence: '+str(exc))[:2048])
        result['status']='inconclusive-diagnosis'; complete=False
    cal.write(terminal,result)
    print(json.dumps(dict(terminal=str(terminal),error=error,conditions=[x['status'] for x in results])))
    return 0 if complete else 1


if __name__=='__main__': sys.exit(main())
