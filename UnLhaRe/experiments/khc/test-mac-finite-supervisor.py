#!/usr/bin/env python3
"""先行した失敗条件。全process/signal/select/clock/log操作はmemory fakeのみ。"""
import copy
import errno
import importlib.util
from pathlib import Path
import sys
import unittest

s=importlib.util.spec_from_file_location('finite',Path(__file__).with_name('mac-finite-supervisor.py'))
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)


class Stream:
    def fileno(self): return 42
    def close(self): pass


class Process:
    pid=100
    def __init__(self,ops): self.ops=ops; self.stdout=Stream(); self.returncode=None
    def poll(self):
        if not self.ops.running: self.returncode=self.ops.rc
        return self.returncode
    def wait(self,timeout):
        self.ops.now+=self.ops.wait_ns
        if self.ops.wait_fail: raise TimeoutError('wait timeout')
        self.returncode=self.ops.rc
        return self.returncode


class Selector:
    def __init__(self,ops): self.ops=ops; self.mapping={}
    def register(self,stream,event): self.mapping[42]=stream
    def unregister(self,stream): self.mapping.clear()
    def get_map(self): return self.mapping
    def select(self,timeout):
        self.ops.now+=self.ops.select_ns
        if self.mapping: return [(type('Key',(),{'fileobj':self.mapping[42]})(),1)]
        return []
    def close(self): pass


class Ops:
    def __init__(self):
        self.now=1000000000; self.rc=70; self.calls=[]; self.probes=[errno.EPERM,errno.ESRCH]
        self.kill_errno=None; self.wait_fail=False; self.wait_ns=1; self.select_ns=1
        self.running=False; self.chunks=[b'']; self.logs=[]; self.log_fail=False; self.ppid=7; self.probe_delay_ns=0
    def getppid(self): return self.ppid
    def monotonic_ns(self): return self.now
    def time_ns(self): return self.now
    def sleep(self,seconds): self.now+=round(seconds*1e9)
    def popen(self,*args,**kwargs):
        self.calls.append(('spawn',args,kwargs)); self.process=Process(self); return self.process
    def selector(self): return Selector(self)
    def read(self,fd,size): return self.chunks.pop(0) if self.chunks else b''
    def signal(self,*args): return None
    def killpg(self,pid,sig):
        self.calls.append(('killpg',pid,sig))
        if not sig: self.now+=self.probe_delay_ns
        code=self.kill_errno if sig else (self.probes.pop(0) if len(self.probes)>1 else self.probes[0])
        if code: raise OSError(code,'injected')
    def write_log(self,path,data):
        if self.log_fail: raise OSError('log failure')
        self.logs.append((path,data))


class Support:
    LOG_LIMIT=32
    def __init__(self): self.calls=0; self.fail_at=None
    def admit(self,*args):
        self.calls+=1
        if self.calls==self.fail_at: raise RuntimeError('guard failed')
    def child_environment(self,root): return {'TMP':str(root)}
    def checked_path(self,path): pass


class Tests(unittest.TestCase):
    def make(self):
        ops=Ops(); support=Support(); supervisor=m.Supervisor(Path.cwd(),support,ops=ops)
        return supervisor,ops,support
    def run70(self,s):
        with self.assertRaisesRegex(m.SupervisorError,'process failed: 70'): s.run([sys.executable],timeout=2)
        return s.last_closure

    def test_successful_kill_eperm_then_esrch_preserves_primary70(self):
        s,o,_=self.make(); p=self.run70(s)
        self.assertTrue(m.validate_closure(p,100,1)); self.assertTrue(p['signal_sent'])
        self.assertEqual(p['primary']['kind'],'exit'); self.assertEqual(p['primary']['returncode'],70)
        self.assertEqual([x['errno'] for x in p['raw_calls'] if x['operation']=='group_probe'],[errno.EPERM,errno.ESRCH])

    def test_kill_eperm_then_eperm_esrch_is_absence_without_delivery(self):
        s,o,_=self.make(); o.kill_errno=errno.EPERM; p=self.run70(s)
        self.assertTrue(m.validate_closure(p,100,1)); self.assertFalse(p['signal_sent'])
        self.assertTrue(p['signal_attempted'])

    def test_persistent_eperm_live_and_late_esrch_fail_closed_and_block_next_run(self):
        for probe in [errno.EPERM,None]:
            s,o,_=self.make(); o.probes=[probe]
            with self.assertRaises(m.ClosureError): s.run([sys.executable],timeout=2)
            self.assertFalse(m.validate_closure(s.last_closure,100,1))
            self.assertEqual(s.last_closure['primary']['returncode'],70)
            with self.assertRaises(m.ClosureError): s.run([sys.executable])
            self.assertEqual(len([c for c in o.calls if c[0]=='spawn']),1)

    def test_reap_timeout_or_late_reap_cannot_recover_with_esrch(self):
        for fail,delay in [(True,1),(False,10_000_000_001)]:
            s,o,_=self.make(); o.wait_fail=fail; o.wait_ns=delay; o.probes=[errno.ESRCH]
            with self.assertRaises(m.ClosureError): s.run([sys.executable])
            self.assertFalse(m.validate_closure(s.last_closure,100,1))

    def test_duplicate_hup_attempts_only_one_kill_and_preserves_hup(self):
        s,o,_=self.make(); original=o.killpg
        def reentrant(pid,sig):
            if sig: s.stop(); s.stop()
            return original(pid,sig)
        o.killpg=reentrant
        with self.assertRaises(m.SupervisorError): s.run([sys.executable],simulate_hup=True)
        self.assertEqual(s.last_closure['primary']['kind'],'hup')
        self.assertEqual(len([x for x in o.calls if x[0]=='killpg' and x[2]]),1)

    def test_timeout_parentloss_guard_and_logbound_remain_failures(self):
        for kind in ['timeout','parent_loss','guard','log_bound']:
            s,o,g=self.make(); kwargs={}
            if kind=='timeout': kwargs['timeout']=0
            if kind=='parent_loss': kwargs['simulate_parent_loss']=True
            if kind=='guard': g.fail_at=2
            if kind=='log_bound': o.chunks=[b'x'*33]
            with self.assertRaises(RuntimeError): s.run([sys.executable],**kwargs)
            self.assertEqual(s.last_closure['primary']['kind'],kind)
            self.assertTrue(m.validate_closure(s.last_closure,100,1))
            self.assertLessEqual(len(s.last_output),32)

    def test_log_write_failure_keeps_cleanup_and_is_not_success(self):
        s,o,_=self.make(); o.rc=0; o.log_fail=True
        with self.assertRaises(m.SupervisorError): s.run([sys.executable])
        self.assertFalse(m.validate_closure(s.last_closure,100,1))
        self.assertTrue(s.last_closure['child_reaped']); self.assertTrue(s.last_closure['group_absent'])
        self.assertEqual(s.last_closure['primary']['kind'],'log_write')

    def test_log_failure_after70_cannot_masquerade_as_expected70_gate(self):
        s,o,_=self.make(); o.log_fail=True
        with self.assertRaises(m.ClosureError) as caught: s.run([sys.executable])
        self.assertEqual(str(caught.exception.primary),'process failed: 70')
        self.assertEqual(s.last_closure['primary']['returncode'],70)
        self.assertFalse(m.validate_closure(s.last_closure,100,1))

    def test_proof_reset_and_strict_pid_sequence_binding(self):
        s,o,_=self.make(); p=self.run70(s)
        self.assertFalse(m.validate_closure(p,101,1)); self.assertFalse(m.validate_closure(p,100,2))
        bad=copy.deepcopy(p); bad['raw_calls']=[]
        self.assertFalse(m.validate_closure(bad,100,1))
        o.probes=[errno.ESRCH]; self.run70(s)
        self.assertEqual(s.sequence,2); self.assertTrue(m.validate_closure(s.last_closure,100,2))
        self.assertFalse(m.validate_closure(p,100,2))
        changed=s.last_closure; changed['group_absent']=False
        self.assertTrue(s.last_closure['group_absent'])

    def test_esrch_after_group_deadline_is_not_accepted(self):
        s,o,_=self.make(); o.probes=[errno.ESRCH]; o.probe_delay_ns=3_000_000_001
        with self.assertRaises(m.ClosureError): s.run([sys.executable])
        self.assertFalse(s.last_closure['group_absent'])
        self.assertFalse(m.validate_closure(s.last_closure,100,1))

    def test_esrch_at_deadline_is_accepted(self):
        s,o,_=self.make(); o.probes=[errno.ESRCH]; o.probe_delay_ns=3_000_000_000
        self.assertTrue(m.validate_closure(self.run70(s),100,1))

    def test_primary70_is_attached_to_cleanup_error(self):
        s,o,_=self.make(); o.probes=[errno.EPERM]
        with self.assertRaises(m.ClosureError) as caught: s.run([sys.executable])
        self.assertEqual(str(caught.exception.primary),'process failed: 70')

    def test_hup_during_cleanup_after_exit0_is_still_failure(self):
        s,o,_=self.make(); o.rc=0; original=o.killpg
        def hup(pid,sig):
            if not sig: s.stop()
            return original(pid,sig)
        o.killpg=hup
        with self.assertRaises(m.SupervisorError): s.run([sys.executable])
        self.assertEqual(s.last_closure['primary']['kind'],'hup')
        self.assertTrue(m.validate_closure(s.last_closure,100,1))

    def test_hup_during_read_is_not_reclassified_as_exit70(self):
        s,o,_=self.make(); original=o.read
        def interrupted(fd,size): s.stop(); return original(fd,size)
        o.read=interrupted
        with self.assertRaises(m.SupervisorError): s.run([sys.executable])
        self.assertEqual(s.last_closure['primary']['kind'],'hup')

    def test_missing_kill_target_is_not_successful_delivery(self):
        s,o,_=self.make(); o.kill_errno=errno.ESRCH; o.probes=[errno.ESRCH]
        p=self.run70(s)
        self.assertTrue(m.validate_closure(p,100,1)); self.assertFalse(p['signal_sent'])

    def test_invalid_new_run_clears_old_proof_without_spawning(self):
        s,o,_=self.make(); self.run70(s)
        with self.assertRaises(m.SupervisorError): s.run(['relative'])
        self.assertEqual(s.sequence,2); self.assertIsNone(s.last_closure['pid'])
        self.assertFalse(m.validate_closure(s.last_closure,100,1))
        self.assertEqual(len([c for c in o.calls if c[0]=='spawn']),1)

    def test_popen_is_always_new_session_and_proof_is_bounded(self):
        s,o,_=self.make(); self.run70(s)
        spawn=[c for c in o.calls if c[0]=='spawn'][0]
        self.assertTrue(spawn[2]['start_new_session']); self.assertTrue(spawn[2]['close_fds'])
        p=s.last_closure
        self.assertLessEqual(len(p['raw_calls']),256)
        for key,value in [('generation',True),('primary',{'kind':'garbage','returncode':70,'error':None})]:
            bad=copy.deepcopy(p); bad[key]=value
            self.assertFalse(m.validate_closure(bad,100,1))

if __name__=='__main__': unittest.main()
