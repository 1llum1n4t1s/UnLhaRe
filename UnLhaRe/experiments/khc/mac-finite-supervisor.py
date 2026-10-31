#!/usr/bin/env python3
"""owned process groupの有限な回収証拠。EPERM原因の解決やhard watchdogではない。"""
import copy
import errno
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time

MAX_RAW_CALLS=256
WAIT_NS=10_000_000_000
GROUP_NS=3_000_000_000
POLL_SECONDS=0.05
SIGKILL=int(getattr(signal,'SIGKILL',9))


class SupervisorError(RuntimeError):
    pass


class ClosureError(SupervisorError):
    def __init__(self,message,primary=None):
        super().__init__(message)
        self.primary=primary


def _integer(value): return type(value) is int


def validate_closure(proof,expected_pid,expected_sequence):
    """raw wait/group-probeを再検証。kill拒否後の不在はdelivery成功と別。

    この検証はclosure専用。呼出側はprimary.kind/returncodeも独立に検証する。
    """
    keys={'schema','sequence','generation','pid','pgid','owned_new_session','primary','signal_attempted',
          'signal_sent','child_reaped','actual_returncode','wait_start_ns','wait_end_ns','wait_deadline_ns',
          'group_deadline_ns','group_absent','group_absent_ns','raw_calls','raw_calls_dropped',
          'closure_error','complete','secondary_errors'}
    try:
        if type(proof) is not dict or set(proof)!=keys: return False
        if not _integer(expected_pid) or expected_pid<=1 or not _integer(expected_sequence) or expected_sequence<1: return False
        if any(type(proof[k]) is not int for k in ('schema','sequence','generation','pid','pgid')): return False
        if (proof['schema']!=1 or proof['sequence']!=expected_sequence or proof['generation']!=expected_sequence
                or proof['pid']!=expected_pid or proof['pgid']!=expected_pid): return False
        if not all(proof[k] is True for k in ('owned_new_session','signal_attempted','child_reaped','group_absent','complete')): return False
        if (type(proof['signal_sent']) is not bool or proof['closure_error'] is not None
                or type(proof['raw_calls_dropped']) is not int or proof['raw_calls_dropped']!=0): return False
        if not _integer(proof['actual_returncode']): return False
        if not all(_integer(proof[k]) and proof[k]>=0 for k in ('wait_start_ns','wait_end_ns','wait_deadline_ns',
                                                              'group_deadline_ns','group_absent_ns')): return False
        if not proof['wait_start_ns']<=proof['wait_end_ns']<=proof['wait_deadline_ns']: return False
        if proof['wait_deadline_ns']!=proof['wait_start_ns']+WAIT_NS: return False
        if proof['group_deadline_ns']!=proof['wait_end_ns']+GROUP_NS: return False
        calls=proof['raw_calls']
        if type(calls) is not list or not 3<=len(calls)<=MAX_RAW_CALLS: return False
        call_keys={'operation','target','generation','signal','start_ns','end_ns','ok','errno','value','error'}
        for c in calls:
            if type(c) is not dict or set(c)!=call_keys: return False
            if type(c['target']) is not int or type(c['generation']) is not int: return False
            if c['target']!=expected_pid or c['generation']!=expected_sequence: return False
            if not _integer(c['start_ns']) or not _integer(c['end_ns']) or not 0<=c['start_ns']<=c['end_ns']: return False
            if type(c['ok']) is not bool: return False
            if c['errno'] is not None and (type(c['errno']) is not int or c['errno']<=0): return False
            if c['ok'] and (c['errno'] is not None or c['error'] is not None): return False
            if not c['ok'] and (type(c['error']) is not str or not 0<len(c['error'])<=2048): return False
            if c['operation'] not in ('group_kill','child_wait','group_probe'): return False
        if any(a['end_ns']>b['start_ns'] for a,b in zip(calls,calls[1:])): return False
        kills=[c for c in calls if c['operation']=='group_kill']
        waits=[c for c in calls if c['operation']=='child_wait']
        probes=[c for c in calls if c['operation']=='group_probe']
        if len(kills)!=1 or kills[0]['signal']!=SIGKILL: return False
        if proof['signal_sent']!=kills[0]['ok']: return False
        if (len(waits)!=1 or not waits[0]['ok'] or type(waits[0]['value']) is not int
                or waits[0]['signal'] is not None or waits[0]['value']!=proof['actual_returncode']): return False
        if waits[0]['start_ns']!=proof['wait_start_ns'] or waits[0]['end_ns']!=proof['wait_end_ns']: return False
        if kills[0]['end_ns']>waits[0]['start_ns']: return False
        if not probes or any(c['signal']!=0 or c['start_ns']<proof['wait_end_ns'] for c in probes): return False
        evidence=[c for c in probes if c['ok'] is False and c['errno']==errno.ESRCH
                  and c['end_ns']<=proof['group_deadline_ns']]
        if not evidence or evidence[-1] is not calls[-1] or evidence[-1]['end_ns']!=proof['group_absent_ns']: return False
        if type(proof['primary']) is not dict or set(proof['primary'])!={'kind','returncode','error'}: return False
        primary=proof['primary']
        if primary['kind'] not in ('exit','timeout','hup','parent_loss','guard','log_bound','spawn','internal','log_write'): return False
        if primary['returncode'] is not None and type(primary['returncode']) is not int: return False
        if primary['error'] is not None and (type(primary['error']) is not str or len(primary['error'])>2048): return False
        if type(proof['secondary_errors']) is not list or len(proof['secondary_errors'])>16: return False
        if not all(type(x) is str and len(x)<=2048 for x in proof['secondary_errors']): return False
        if proof['secondary_errors']: return False
        if proof['primary']['kind']=='exit' and proof['primary']['returncode']!=proof['actual_returncode']: return False
        return True
    except (KeyError,TypeError,ValueError): return False


class SystemOps:
    getppid=staticmethod(os.getppid)
    monotonic_ns=staticmethod(time.monotonic_ns)
    time_ns=staticmethod(time.time_ns)
    sleep=staticmethod(time.sleep)
    popen=staticmethod(subprocess.Popen)
    selector=staticmethod(selectors.DefaultSelector)
    read=staticmethod(os.read)
    signal=staticmethod(signal.signal)

    @staticmethod
    def killpg(pid,sig): return os.killpg(pid,sig)

    @staticmethod
    def write_log(path,data):
        with path.open('xb') as log: log.write(data)


class Supervisor:
    """supportはfrozen setupのadmit/child_environment/checked_path/LOG_LIMIT。

    stopは非blockingなkill要求。run finallyがwaitとgroup不在確認を必ず担う。
    cleanupの10+3秒はsyscall後に経過も検証する予算でありhard watchdogではない。
    """
    def __init__(self,root,support,*,ops=None):
        self.root=Path(root); self.support=support; self._ops=ops or SystemOps()
        self.parent=self._ops.getppid(); self.process=None; self.sequence=0
        self.interrupted=False; self.last_output=b''; self._closure=None
        self._owned_process=None; self._owned_pid=None; self._active=False; self._blocked=False

    @property
    def last_closure(self): return copy.deepcopy(self._closure)

    @property
    def currentgeneration(self): return self.sequence

    def _reset(self):
        self.sequence+=1; self.process=None; self._owned_process=None; self._owned_pid=None
        self.interrupted=False; self.last_output=b''
        self._closure=dict(schema=1,sequence=self.sequence,generation=self.sequence,pid=None,pgid=None,
                           owned_new_session=False,primary=dict(kind='internal',returncode=None,error=None),
                           signal_attempted=False,signal_sent=False,child_reaped=False,actual_returncode=None,
                           wait_start_ns=None,wait_end_ns=None,wait_deadline_ns=None,group_deadline_ns=None,
                           group_absent=False,group_absent_ns=None,raw_calls=[],raw_calls_dropped=0,
                           closure_error=None,complete=False,secondary_errors=[])

    def _record(self,operation,sig,callback):
        c=dict(operation=operation,target=self._owned_pid,generation=self.sequence,signal=sig,
               start_ns=self._ops.monotonic_ns(),end_ns=None,ok=False,errno=None,value=None,error=None)
        try: c['value']=callback(); c['ok']=True
        except BaseException as exc:
            c['errno']=getattr(exc,'errno',None)
            c['error']=(type(exc).__name__+': '+str(exc))[:2048]
        c['end_ns']=self._ops.monotonic_ns()
        if len(self._closure['raw_calls'])<MAX_RAW_CALLS: self._closure['raw_calls'].append(c)
        else: self._closure['raw_calls_dropped']+=1
        return c

    def _owned(self):
        return (self._owned_process is not None and self.process is self._owned_process
                and type(self._owned_pid) is int and self._owned_pid>1
                and self._owned_process.pid==self._owned_pid and self._closure['owned_new_session'])

    def stop(self,*_):
        self.interrupted=True
        self._request_kill()

    def _request_kill(self):
        if self._closure is None or self._closure['signal_attempted'] or not self._owned(): return
        # HUPのreentryより前に確定し、同generationへSIGKILLを二度送らない。
        self._closure['signal_attempted']=True
        call=self._record('group_kill',SIGKILL,lambda:self._ops.killpg(self._owned_pid,SIGKILL))
        self._closure['signal_sent']=call['ok']

    def _close(self):
        if self._owned_process is None: return
        errors=[]
        if not self._owned():
            self._closure['closure_error']='owned process binding changed'; self._blocked=True; return
        self._request_kill()
        wait=self._record('child_wait',None,lambda:self._owned_process.wait(timeout=10))
        p=self._closure
        p['wait_start_ns']=wait['start_ns']; p['wait_end_ns']=wait['end_ns']
        p['wait_deadline_ns']=wait['start_ns']+WAIT_NS
        p['actual_returncode']=self._owned_process.returncode
        p['child_reaped']=wait['ok'] and type(wait['value']) is int and wait['value']==p['actual_returncode']
        if not p['child_reaped']: errors.append('direct child reap failed')
        if not wait['start_ns']<=wait['end_ns']<=p['wait_deadline_ns']: errors.append('direct child reap deadline')
        p['group_deadline_ns']=wait['end_ns']+GROUP_NS
        # bounded operationsも設け、注入clockが止まっても無限ループにしない。
        for _ in range(128):
            if self._ops.monotonic_ns()>p['group_deadline_ns']: break
            probe=self._record('group_probe',0,lambda:self._ops.killpg(self._owned_pid,0))
            if not probe['ok'] and probe['errno']==errno.ESRCH and probe['end_ns']<=p['group_deadline_ns']:
                p['group_absent']=True; p['group_absent_ns']=probe['end_ns']; break
            if self._ops.monotonic_ns()>=p['group_deadline_ns']: break
            self._ops.sleep(min(POLL_SECONDS,(p['group_deadline_ns']-self._ops.monotonic_ns())/1e9))
        if not p['group_absent']: errors.append('owned process group absence unconfirmed')
        if p['raw_calls_dropped']: errors.append('closure evidence bound')
        p['closure_error']='; '.join(errors) if errors else None
        p['complete']=not errors
        if not validate_closure(p,self._owned_pid,self.sequence):
            p['complete']=False
            if p['closure_error'] is None: p['closure_error']='closure evidence invalid'
            self._blocked=True

    def run(self,args,timeout=120,cwd=None,simulate_hup=False,simulate_parent_loss=False):
        if self._blocked: raise ClosureError('previous owned process group closure uncertain')
        if self._active: raise SupervisorError('supervisor already running')
        self._reset(); self._active=True
        output=bytearray(); selector=None; old={}; primary=None; kind='guard'; admitted=False
        log_path=self.root/'journal'/('finite-process-%d-%d.log'%(self.sequence,self._ops.time_ns()))
        try:
            if type(timeout) not in (int,float) or not math.isfinite(timeout) or timeout<0:
                raise SupervisorError('finite nonnegative timeout required')
            if not self.root.is_absolute(): raise SupervisorError('absolute root required')
            if not args or not Path(args[0]).is_absolute(): raise SupervisorError('absolute executable required')
            self.support.checked_path(args[0])
            directory=Path(cwd) if cwd is not None else self.root
            if not directory.is_absolute() or '..' in directory.parts or (directory!=self.root and self.root not in directory.parents):
                raise SupervisorError('cwd must be root or child')
            self.support.checked_path(directory)
            self.support.admit(self.root,self.support.LOG_LIMIT+65536); admitted=True
            for sig in (getattr(signal,'SIGHUP',None),signal.SIGTERM,signal.SIGINT):
                if sig is not None: old[sig]=self._ops.signal(sig,self.stop)
            selector=self._ops.selector(); start=self._ops.monotonic_ns(); kind='spawn'
            self.process=self._ops.popen(args,cwd=str(directory),env=self.support.child_environment(self.root),
                                         stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,close_fds=True)
            self._owned_process=self.process; self._owned_pid=self.process.pid
            self._closure.update(pid=self._owned_pid,pgid=self._owned_pid,owned_new_session=True)
            if type(self._owned_pid) is not int or self._owned_pid<=1: raise SupervisorError('invalid owned PID')
            selector.register(self.process.stdout,selectors.EVENT_READ)
            while True:
                kind='hup'
                if self.interrupted: raise SupervisorError('interrupted')
                kind='parent_loss'
                if simulate_parent_loss or self._ops.getppid()!=self.parent or self.parent==1: raise SupervisorError('parent lost')
                kind='timeout'
                if self._ops.monotonic_ns()-start>=timeout*1e9: raise SupervisorError('process timeout')
                kind='guard'; self.support.admit(self.root)
                if simulate_hup:
                    simulate_hup=False; self.stop(); continue
                kind='internal'
                for key,_ in selector.select(0.1):
                    chunk=self._ops.read(key.fileobj.fileno(),65536)
                    if chunk:
                        room=max(0,self.support.LOG_LIMIT-len(output))
                        output.extend(chunk[:room])
                        if len(chunk)>room:
                            kind='log_bound'; raise SupervisorError('process output bound')
                    else: selector.unregister(key.fileobj)
                if self.interrupted:
                    kind='hup'; raise SupervisorError('interrupted')
                if self.process.poll() is not None and not selector.get_map():
                    kind='exit'
                    self._closure['primary']=dict(kind='exit',returncode=self.process.returncode,error=None)
                    if self.process.returncode!=0: raise SupervisorError('process failed: '+str(self.process.returncode))
                    break
        except BaseException as exc:
            primary=exc
            self._closure['primary']=dict(kind=kind,returncode=self.process.returncode if kind=='exit' and self.process else None,
                                          error=(type(exc).__name__+': '+str(exc))[:2048])
        finally:
            try: self._close()
            except BaseException as exc:
                self._closure['closure_error']=('cleanup exception: '+str(exc))[:2048]
                self._closure['complete']=False; self._blocked=self._owned_process is not None
            for action in ([lambda:selector.close()] if selector else [])+[
                    lambda sig=sig,handler=handler:self._ops.signal(sig,handler) for sig,handler in old.items()]:
                try: action()
                except BaseException as exc:
                    self._closure['secondary_errors'].append(('resource restore: '+str(exc))[:2048])
                    if primary is None: primary=SupervisorError('resource restore failed')
            if self._owned_process is not None:
                try: self._owned_process.stdout.close()
                except BaseException as exc:
                    self._closure['secondary_errors'].append(('stdout close: '+str(exc))[:2048])
                    if primary is None: primary=SupervisorError('stdout close failed')
            self.last_output=bytes(output)
            if admitted:
                try: self._ops.write_log(log_path,self.last_output)
                except BaseException as exc:
                    self._closure['secondary_errors'].append(('log persistence: '+str(exc))[:2048])
                    if primary is None:
                        primary=SupervisorError('process log persistence failed')
                        self._closure['primary']=dict(kind='log_write',returncode=None,error=str(primary))
            if self.interrupted and primary is None:
                primary=SupervisorError('interrupted')
                self._closure['primary']=dict(kind='hup',returncode=None,error=str(primary))
            if self._closure['secondary_errors']:
                self._closure['complete']=False
                if self._closure['closure_error'] is None:
                    self._closure['closure_error']='closure evidence/resource persistence failed'
            self._active=False
        if self._closure['closure_error'] is not None:
            raise ClosureError(self._closure['closure_error'],primary=primary) from primary
        if primary is not None: raise primary
        return self.last_output.decode('utf-8','replace')
