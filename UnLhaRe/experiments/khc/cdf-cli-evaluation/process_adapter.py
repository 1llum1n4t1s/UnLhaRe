#!/usr/bin/env python3
"""Bounded process measurement primitives; the production entry is not connected.

The measurement helper must run inside the existing finite supervisor's owned
session. Its raw wait4 result alone is not a group-closure or host proof. The
adapter accepts a result only after independent frozen validators confirm both.
"""
import copy
import base64
import json
import math
import os
import selectors
import signal
import subprocess
import sys
import time
import threading
from pathlib import Path

class InvalidObservation(ValueError):pass
class Unavailable(RuntimeError):pass
class PartialFailure(InvalidObservation):
    def __init__(self,message,stdout=b'',stderr=b''):
        super().__init__(message);self.stdout=bytes(stdout);self.stderr=bytes(stderr);self.cleanup_error=None
class BackendFailure(InvalidObservation):
    def __init__(self,message,closure=None,event=None,output=b'',failures=None):
        super().__init__(message);self.closure=copy.deepcopy(closure);self.event=copy.deepcopy(event)
        self.output=bytes(output[:131072])
        self.failures=copy.deepcopy(failures or [])

def failure_item(phase,error):
    return dict(phase=phase,type=type(error).__name__,message=str(error)[:2048])

def bounded_child_timeout(native_begin_ns,now_ns,requested):
    require(type(native_begin_ns) is int and native_begin_ns>=0 and type(now_ns) is int and
        now_ns>=native_begin_ns and type(requested) is int and requested in (20,60),'native clock/child timeout')
    # 317s observer end minus 13s group closure, 4s coverage, 1s pre-spawn allowance.
    remaining_ns=native_begin_ns+299_000_000_000-now_ns
    require(remaining_ns>0,'insufficient time before child start')
    return min(requested*1_000_000_000,remaining_ns)/1e9

class DeadlineSpawnGuard:
    """Wrap only FS's popen; refusal precedes creation of any child."""
    def __init__(self,ops,lifecycle,native_begin_ns,timeout):
        self.ops=ops;self.lifecycle=lifecycle;self.native_begin_ns=native_begin_ns;self.timeout=timeout
        self.spawn_check_ns=None
    def __getattr__(self,name):return getattr(self.ops,name)
    def popen(self,*args,**kwargs):
        require(self.spawn_check_ns is None,'duplicate child spawn')
        require(self.lifecycle.verify_native_clock(self.native_begin_ns) is True,'native clock not authenticated')
        now=time.monotonic_ns();limit=self.native_begin_ns+300_000_000_000
        require(now>=self.native_begin_ns and now+math.ceil(self.timeout*1e9)<=limit,'pre-spawn deadline')
        self.spawn_check_ns=now
        return self.ops.popen(*args,**kwargs)

def require(ok,message):
    if not ok:raise InvalidObservation(message)

def verify_observation(value,timeout,backend):
    """Validate a supervisor/observer result before it reaches the scorer."""
    require(type(value) is dict and set(value)=={'metric','closure_proof','host_observation','stdout','stderr'},
        'observation schema')
    result=copy.deepcopy(value);metric=result['metric']
    require(type(timeout) in (int,float) and math.isfinite(timeout) and 0<timeout<=60,'timeout bound')
    require(type(metric) is dict and set(metric)=={'elapsed_ns','user_seconds','system_seconds','peak_rss_bytes',
        'normal_exit','exit_code','signal','cpu_per_wall'},'metric schema')
    require(type(metric['elapsed_ns']) is int and 0<metric['elapsed_ns']<=timeout*10**9 and
        type(metric['peak_rss_bytes']) is int and metric['peak_rss_bytes']>0 and
        metric['normal_exit'] is True and type(metric['exit_code']) is int and metric['exit_code']==0 and
        metric['signal'] is None,'exit/time/RSS')
    for key in ('user_seconds','system_seconds','cpu_per_wall'):
        require(type(metric[key]) in (int,float) and math.isfinite(metric[key]) and metric[key]>=0,'CPU metric')
    cpu=(metric['user_seconds']+metric['system_seconds'])*10**9/metric['elapsed_ns']
    require(math.isclose(cpu,metric['cpu_per_wall'],rel_tol=1e-12,abs_tol=1e-12) and cpu<=1.2,'CPU/wall')
    require(type(result['stdout']) is bytes and type(result['stderr']) is bytes and
        len(result['stdout'])<=32768 and len(result['stderr'])<=32768 and
        len(result['stdout'])+len(result['stderr'])<=65536,'child output bounds')
    try:
        closed=backend.verify_closure(copy.deepcopy(result['closure_proof']))
        eligible=backend.verify_host(copy.deepcopy(result['host_observation']))
    except Exception as error:
        raise InvalidObservation('closure/host validator unavailable') from error
    require(closed is True,'group closure unknown')
    require(eligible is True,'host observation invalid')
    return result

class SupervisedAdapter:
    """Adapter for a separately approved backend; no implicit native backend exists."""
    def __init__(self,backend):self.backend=backend
    def admit(self):return self.backend.admit()
    def verify_binary(self,path,expected):return self.backend.verify_binary(path,expected)
    def require_unused(self,path):return self.backend.require_unused(path)
    def create_private_directory(self,path):return self.backend.create_private_directory(path)
    def check_path(self,path):return self.backend.check_path(path)
    def verify_preflight(self,evidence,source_sha,cli_sha):
        return self.backend.verify_preflight(evidence,source_sha,cli_sha) is True
    def invoke(self,command,*,timeout,cwd):
        try:return verify_observation(self.backend.run(command=command,timeout=timeout,cwd=cwd),timeout,self.backend)
        except InvalidObservation:raise
        except Exception as error:raise BackendFailure('backend run failed',failures=[failure_item('run',error)]) from error
    def validate_closure(self,proof):return self.backend.verify_closure(proof) is True
    def validate_host(self,observation):return self.backend.verify_host(observation) is True
    def finish_campaign(self):
        try:return self.backend.finish_campaign()
        except InvalidObservation:raise
        except Exception as error:raise BackendFailure('backend finalization failed',failures=[failure_item('finish_campaign',error)]) from error
    def validate_final_observation(self,observation):
        try:return self.backend.verify_final_observation(observation) is True
        except InvalidObservation:raise
        except Exception as error:raise BackendFailure('final observer verification failed',failures=[failure_item('final_validator',error)]) from error

class FixedHelperCommand:
    """Bind a frozen helper's wire to exactly one preregistered trial command."""
    def __init__(self,helper,pins,python_path):
        require(type(pins) is dict and set(pins)=={'wait4_helper.py','evaluation.py','process_adapter.py'} and
            all(type(v) is str and len(v)==64 and all(c in '0123456789abcdef' for c in v) for v in pins.values()) and
            python_path=='/usr/bin/python3','helper dependency pins/python')
        self.helper=helper;self.pins=dict(pins);self.python_path=python_path
    def verify_identity(self):
        try:return self.helper.dependency_hashes()==self.pins
        except Exception:return False
    def command(self,*,command,cwd,timeout):
        require(self.verify_identity(),'helper dependency identity')
        e=self.helper.evaluation(self.pins['evaluation.py']);matches=[]
        for index in range(-2,22):
            letter='A' if index==-2 else 'B' if index==-1 else e.schedule()[index]['letter']
            source,archive,decoded=e.trial_paths(index);create,extract=e.commands(letter,source,archive,decoded)
            for direction,expected,limit in (('encode',create,60),('decode',extract,20)):
                if command==expected and cwd==source and type(timeout) is int and timeout==limit:
                    matches.append((index,direction))
        require(len(matches)==1,'command/cwd/timeout outside fixed plan')
        request=self.helper.expected_request(matches[0][0],matches[0][1],os.getpid(),expected_pins=self.pins)
        require(type(request) is dict and request.get('dependency_sha256')==self.pins and self.verify_identity(),
            'request dependency pins changed')
        raw=self.helper.canonical(request)
        require(len(raw)<=self.helper.MAX_WIRE,'fixed helper request bound')
        script=str(Path(self.helper.HERE)/'wait4_helper.py')
        return [self.python_path,'-I','-B',script,'--run-request-base64',base64.b64encode(raw).decode()]

class FrozenBackendBridge:
    """Bridge to frozen FS/Observer APIs; helper identity and lifecycle remain external.

    Helper must return one bounded JSON line with wait4 metric and two base64
    streams while inheriting FS's group. This bridge never grants authorization:
    create_native_adapter remains closed pending a reviewed helper and lifecycle.
    """
    def __init__(self,fs,supervisor,observer_validator,observer,helper,lifecycle,*,native_begin_ns=None):
        self.fs=fs;self._supervisor=fs.Supervisor(supervisor.root,supervisor.support,ops=supervisor._ops)
        require(self._supervisor is not supervisor,'supervisor must be independently owned')
        self._run_lock=threading.Lock();self.observer_validator=observer_validator
        self.observer=observer;self.helper=helper;self.lifecycle=lifecycle
        require(native_begin_ns is None or (type(native_begin_ns) is int and native_begin_ns>=0),'native begin time')
        self.native_begin_ns=native_begin_ns
        self.closure_history={}
    def admit(self):return self.lifecycle.admit()
    def verify_binary(self,path,expected):return self.lifecycle.verify_binary(path,expected)
    def require_unused(self,path):return self.lifecycle.require_unused(path)
    def create_private_directory(self,path):return self.lifecycle.create_private_directory(path)
    def check_path(self,path):return self.lifecycle.check_path(path)
    def verify_preflight(self,evidence,source_sha,cli_sha):
        return self.lifecycle.verify_preflight(evidence,source_sha,cli_sha)
    def verify_closure(self,binding):
        if type(binding) is not dict or set(binding)!={'raw','expected_pid','expected_sequence'}:return False
        sequence=binding['expected_sequence']
        if type(sequence) is not int:return False
        saved=self.closure_history.get(sequence)
        if (saved is None or binding['expected_pid']!=saved['pid'] or
            binding['raw']!=saved['proof']):return False
        return self._valid_closure(binding['raw'],saved['pid'],saved['sequence'])
    def _valid_closure(self,proof,pid,sequence):
        return (type(proof) is dict and type(pid) is int and pid>1 and type(sequence) is int and sequence>0 and
            proof.get('pid')==pid and proof.get('sequence')==sequence and
            type(proof.get('primary')) is dict and proof['primary'].get('kind')=='exit' and
            type(proof['primary'].get('returncode')) is int and proof['primary']['returncode']==0 and
            type(proof.get('actual_returncode')) is int and proof['actual_returncode']==0 and
            self.fs.validate_closure(proof,pid,sequence) is True)
    def remember_closure(self,proof,pid,sequence):
        require(sequence not in self.closure_history and self._valid_closure(proof,pid,sequence),
            'group closure identity/normal exit')
        self.closure_history[sequence]=dict(pid=pid,sequence=sequence,proof=copy.deepcopy(proof))
        return dict(raw=copy.deepcopy(proof),expected_pid=pid,expected_sequence=sequence)
    def verify_host(self,observation):
        if type(observation) is not dict or set(observation)!={'event_id','report'}:return False
        event_id=observation['event_id'];report=observation['report']
        if type(event_id) is not int or event_id<0:return False
        verdict=self.observer_validator.validate_report(report)
        return (type(verdict) is dict and verdict.get('entry_ready') is True and type(verdict.get('errors')) is list and
            not verdict['errors'] and
            type(verdict.get('events')) is list and event_id<len(verdict['events']) and
            verdict['events'][event_id].get('id')==event_id and verdict['events'][event_id].get('state')=='covered')
    def _covered(self,event_id,timeout=4.):
        end_ns=time.monotonic_ns()+int(timeout*1e9)
        if self.native_begin_ns is not None:end_ns=min(end_ns,self.native_begin_ns+317_000_000_000)
        while time.monotonic_ns()<end_ns:
            report=self.observer.report();observation={'event_id':event_id,'report':report}
            if self.verify_host(observation):
                require(time.monotonic_ns()<end_ns,'continuous observer event coverage deadline')
                return observation
            verdict=self.observer_validator.validate_report(report)
            if verdict.get('errors'):raise InvalidObservation('continuous observer failure')
            time.sleep(.05)
        raise InvalidObservation('continuous observer event coverage deadline')
    def _abort_observer(self):
        cleanup=dict(status='unknown',evidence=None)
        try:
            require(type(self.native_begin_ns) is int,'native deadline unavailable')
            closure_deadline_ns=self.native_begin_ns+330_000_000_000
            # 期限後でも停止は試みる。期限内完了できなければ証明をunknownにする。
            evidence=self.lifecycle.abort_observer(deadline_ns=closure_deadline_ns)
            require(time.monotonic_ns()<closure_deadline_ns,'observer abort deadline')
            verified=self.lifecycle.verify_observer_abort(evidence)
            require(time.monotonic_ns()<closure_deadline_ns and verified is True,'observer abort not confirmed')
            return dict(status='verified',evidence=copy.deepcopy(evidence)),None
        except Exception as error:return cleanup,failure_item('observer_abort',error)
    def _failure_with_abort(self,message,proof,event,captured,phase,error):
        failures=[failure_item(phase,error)]
        if self.native_begin_ns is not None:
            cleanup,abort_failure=self._abort_observer()
            if abort_failure is not None:failures.append(abort_failure)
            event=dict(observer_event=event,cleanup=cleanup)
        return BackendFailure(message,proof,event,captured,failures)
    def run(self,*,command,timeout,cwd):
        require(self._run_lock.acquire(blocking=False),'bridge already running')
        try:return self._run_owned(command=command,timeout=timeout,cwd=cwd)
        finally:self._run_lock.release()
    def _run_owned(self,*,command,timeout,cwd):
        try:
            require(type(self.native_begin_ns) is int and
                self.lifecycle.verify_native_clock(self.native_begin_ns) is True,'native clock not authenticated')
            bounded_child_timeout(self.native_begin_ns,time.monotonic_ns(),timeout)
            require(self.helper.verify_identity() is True,'measurement helper identity')
            argv=self.helper.command(command=command,cwd=cwd,timeout=timeout)
            require(type(argv) is list and argv and all(type(v) is str and v for v in argv) and
                os.path.isabs(argv[0]),'supervised helper command')
            limited_timeout=bounded_child_timeout(self.native_begin_ns,time.monotonic_ns(),timeout)
            previous_sequence=self._supervisor.sequence
            require(type(previous_sequence) is int and previous_sequence>=0,'supervisor sequence before invocation')
        except Exception as error:
            raise self._failure_with_abort('child pre-start invalid',None,None,b'','pre_start',error) from error
        original_ops=self._supervisor._ops
        guard=DeadlineSpawnGuard(original_ops,self.lifecycle,self.native_begin_ns,limited_timeout)
        try:token=self.observer.begin_event()
        except Exception as error:
            raise self._failure_with_abort('observer begin failed',None,None,b'','begin_event',error) from error
        self._supervisor._ops=guard
        event=None;failure=None;failures=[];output=''
        try:output=self._supervisor.run(argv,timeout=limited_timeout,cwd=cwd)
        except BaseException as error:failure=error;failures.append(failure_item('supervisor',error))
        finally:
            self._supervisor._ops=original_ops
            try:event=self.observer.finish_event(token)
            except BaseException as error:
                failures.append(failure_item('finish_event',error))
                if failure is None:failure=error
        proof=self._supervisor.last_closure
        if failure is not None:
            partial=getattr(self._supervisor,'last_output',b'')
            if type(partial) is not bytes:partial=b''
            if self.native_begin_ns is not None:
                cleanup,abort_failure=self._abort_observer()
                if abort_failure is not None:failures.append(abort_failure)
                event=dict(observer_event=event,cleanup=cleanup)
            raise BackendFailure('supervisor/observer failed: '+str(failure)[:2048],proof,event,
                partial,failures) from failure
        captured=output.encode('utf-8','replace')[:131072] if type(output) is str else b''
        try:
            pid=self._supervisor._owned_pid;sequence=self._supervisor.sequence
            require(type(guard.spawn_check_ns) is int and type(sequence) is int and
                sequence==previous_sequence+1 and self._supervisor.process is not None and
                self._supervisor._owned_process is self._supervisor.process and self._supervisor.process.pid==pid,
                'supervisor-owned process identity')
            binding=self.remember_closure(proof,pid,sequence)
        except Exception as error:
            raise self._failure_with_abort('group closure invalid',proof,event,captured,'closure',error) from error
        if type(output) is not str or len(output.encode())>131072:
            error=InvalidObservation('helper output bound')
            raise self._failure_with_abort('helper output bound',proof,event,captured,'helper_output',error) from error
        def pairs(items):
            result={}
            for key,value in items:
                require(key not in result,'duplicate helper JSON key');result[key]=value
            return result
        try:
            payload=json.loads(output,object_pairs_hook=pairs,
                parse_constant=lambda _:(_ for _ in ()).throw(InvalidObservation('nonfinite helper JSON')))
            require(type(payload) is dict and set(payload)=={'schema','metric','stdout_base64','stderr_base64'} and
                type(payload['schema']) is int and payload['schema']==1,'helper result schema')
            require(type(payload['metric']) is dict and type(payload['metric'].get('elapsed_ns')) is int and
                payload['metric']['elapsed_ns']<=math.floor(limited_timeout*1e9),'child exceeded limited timeout')
            for key in ('stdout_base64','stderr_base64'):
                require(type(payload[key]) is str and len(payload[key])<=43692,'helper output wire')
            stdout=base64.b64decode(payload['stdout_base64'],validate=True)
            stderr=base64.b64decode(payload['stderr_base64'],validate=True)
            host=self._covered(token)
        except Exception as error:
            raise self._failure_with_abort('helper/observer validation failed: '+str(error)[:2048],
                proof,event,captured,'helper_or_observer',error) from error
        return dict(metric=payload['metric'],closure_proof=binding,host_observation=host,stdout=stdout,stderr=stderr)
    def _finalize_observation(self,expected_events):
        require(type(expected_events) is int and expected_events==48 and type(self.native_begin_ns) is int,
            'fixed native start required')
        deadline_ns=self.native_begin_ns+317_000_000_000
        while True:
            now=time.monotonic_ns();require(self.native_begin_ns<=now<deadline_ns,'observer completion deadline')
            if self.observer.join(min(10.,(deadline_ns-now)/1e9)) is True:break
        require(time.monotonic_ns()<deadline_ns,'observer completion deadline')
        raw=self.observer.report()
        require(type(raw) is dict and type(raw.get('epoch_ns')) is int and
            0<=raw['epoch_ns']-self.native_begin_ns<=8_000_000_000,'observer start bound')
        require(self.verify_final_observation(raw),'final continuous coverage')
        require(time.monotonic_ns()<deadline_ns,'observer validation deadline')
        return copy.deepcopy(raw)
    def finalize_observation(self,expected_events):
        try:return self._finalize_observation(expected_events)
        except Exception as error:
            failures=[failure_item('observer_finalize',error)]
            cleanup,abort_failure=self._abort_observer()
            if abort_failure is not None:failures.append(abort_failure)
            raise BackendFailure('observer finalization invalid',event=cleanup,failures=failures) from error
    def verify_final_observation(self,raw):
        if type(raw) is not dict:return False
        verdict=self.observer_validator.validate_report(raw)
        events=raw.get('events');captures=raw.get('captures')
        return (type(verdict) is dict and verdict.get('eligible') is True and raw.get('completed') is True and
            type(raw.get('max_captures')) is int and raw['max_captures']==240 and
            type(raw.get('cadence_ns')) is int and raw['cadence_ns']==1250000000 and
            type(events) is list and len(events)==48 and type(captures) is list and len(captures)==240 and
            type(events[-1]) is dict and
            type(events[-1].get('end_ns')) is int and type(captures[-1]) is dict and
            type(captures[-1].get('start_ns')) is int and events[-1]['end_ns']<captures[-1]['start_ns'] and
            events[-1]['end_ns']<239*1250000000)
    def finish_campaign(self):
        return self.finalize_observation(48)

def create_native_adapter(*_args,**_kwargs):
    raise Unavailable('No approved lifecycle, finite supervisor, helper identity and continuous observer binding.')

def encode_helper_result(value):
    """Encode one wait4 measurement for the outer frozen supervisor's stream."""
    require(type(value) is dict and set(value)=={'metric','stdout','stderr'} and
        type(value['metric']) is dict and type(value['stdout']) is bytes and type(value['stderr']) is bytes and
        len(value['stdout'])<=32768 and len(value['stderr'])<=32768 and
        len(value['stdout'])+len(value['stderr'])<=65536,'helper encoding input')
    payload=dict(schema=1,metric=value['metric'],stdout_base64=base64.b64encode(value['stdout']).decode(),
        stderr_base64=base64.b64encode(value['stderr']).decode())
    encoded=(json.dumps(payload,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
    require(len(encoded)<=131072,'encoded helper result bound')
    return encoded

def stop_direct_child(process):
    """Bounded direct-child emergency cleanup; outer FS still owns the group."""
    require(type(process.pid) is int and process.pid>1,'owned child PID')
    try:os.kill(process.pid,signal.SIGKILL)
    except ProcessLookupError:pass
    deadline=time.monotonic_ns()+3_000_000_000
    for _ in range(300):
        if time.monotonic_ns()>=deadline:break
        pid,status,_=os.wait4(process.pid,os.WNOHANG)
        if pid:
            require(pid==process.pid,'emergency wait4 PID')
            process.returncode=os.waitstatus_to_exitcode(status)
            return
        time.sleep(.01)
    raise InvalidObservation('direct child termination/reap unconfirmed')

def measure_child_in_owned_group(command,cwd,environment,timeout,*,expected_supervisor_pid):
    """Darwin wait4 helper primitive, not a standalone process-supervision entry.

    Caller MUST be the group leader spawned by the frozen outer supervisor. Any
    child left on an error is killed/reaped by that outer supervisor, which also
    records group absence. The native integration is deliberately unavailable.
    """
    require(sys.platform=='darwin' and hasattr(os,'wait4') and hasattr(os,'getpgrp') and hasattr(os,'getsid') and
        type(expected_supervisor_pid) is int and expected_supervisor_pid>1 and os.getppid()==expected_supervisor_pid and
        os.getpid()==os.getpgrp()==os.getsid(0),'owned Darwin supervisor group required')
    require(type(command) is list and command and all(type(x) is str and x for x in command) and
        os.path.isabs(command[0]) and type(cwd) is str and os.path.isabs(cwd) and type(environment) is dict and
        type(timeout) in (int,float) and math.isfinite(timeout) and 0<timeout<=60,'helper request')
    start=time.monotonic_ns();deadline=start+int(timeout*1e9);out=[bytearray(),bytearray()]
    process=None;selector=selectors.DefaultSelector();waited=False;status=None;usage=None
    try:
        process=subprocess.Popen(command,cwd=cwd,env=environment,stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True,start_new_session=False)
        for index,pipe in enumerate((process.stdout,process.stderr)):
            os.set_blocking(pipe.fileno(),False);selector.register(pipe,selectors.EVENT_READ,index)
        while not waited or selector.get_map():
            now=time.monotonic_ns()
            if os.getppid()!=expected_supervisor_pid:
                # The only session/group is this FS-owned helper group. If its
                # supervisor disappeared, terminate that group rather than
                # orphaning descendants; no successful closure is inferred.
                os.killpg(os.getpgrp(),signal.SIGKILL)
                raise PartialFailure('supervisor parent lost',*out)
            if now>=deadline:raise PartialFailure('child deadline',*out)
            if not waited:
                pid,status,usage=os.wait4(process.pid,os.WNOHANG)
                if pid:
                    require(pid==process.pid,'wait4 PID');waited=True
                    process.returncode=os.waitstatus_to_exitcode(status)
                    ended=time.monotonic_ns()
            for key,_ in selector.select(min(.05,max(0.,(deadline-time.monotonic_ns())/1e9))):
                chunk=os.read(key.fileobj.fileno(),4096)
                if not chunk:selector.unregister(key.fileobj)
                else:
                    out[key.data].extend(chunk)
                    if len(out[key.data])>32768 or sum(map(len,out))>65536:
                        raise PartialFailure('child output bound',*(bytes(x[:32768]) for x in out))
        require(waited and status is not None and usage is not None and ended>start,'wait4 completion')
        elapsed=ended-start;normal=os.WIFEXITED(status)
        metric=dict(elapsed_ns=elapsed,user_seconds=usage.ru_utime,system_seconds=usage.ru_stime,
            peak_rss_bytes=usage.ru_maxrss,normal_exit=normal,exit_code=os.WEXITSTATUS(status) if normal else None,
            signal=os.WTERMSIG(status) if os.WIFSIGNALED(status) else None,
            cpu_per_wall=(usage.ru_utime+usage.ru_stime)*1e9/elapsed)
        return dict(metric=metric,stdout=bytes(out[0]),stderr=bytes(out[1]))
    except Exception as error:
        failure=(error if isinstance(error,PartialFailure) else
            PartialFailure((type(error).__name__+': '+str(error))[:2048],*out))
        if process is not None and not waited:
            try:stop_direct_child(process)
            except Exception as cleanup:
                failure.cleanup_error=failure_item('direct_child_cleanup',cleanup)
        if failure is error:raise
        raise failure from error
    finally:
        selector.close()
        if process is not None:
            for pipe in (process.stdout,process.stderr):
                if pipe is not None:pipe.close()
