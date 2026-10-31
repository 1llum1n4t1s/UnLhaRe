#!/usr/bin/env python3
"""signal診断の許可条件をOS操作前に固定する純粋試験。"""
import importlib.util
from pathlib import Path
import unittest

s=importlib.util.spec_from_file_location('probe',Path(__file__).with_name('mac-signal-boundary-probe.py'))
m=importlib.util.module_from_spec(s); s.loader.exec_module(m)

def identity(pid=20,ppid=10,pgid=10,uid=501,command='/bin/sleep 2'):
    return dict(pid=pid,ppid=ppid,pgid=pgid,uid=uid,stat='S',
                started='Tue Oct 27 00:00:00 2026',command=command)

class PureTests(unittest.TestCase):
    def test_parse_full_command_starttime_and_duplicates(self):
        text=' 20 10 10 501 S Tue Oct 27 00:00:00 2026 /bin/sleep 2\n'
        self.assertEqual(m.parse_ps(text,[20])[20],identity())
        for bad in [text+text,text.replace('20 10','21 10'),text.replace('501','x'),'20 10 10 501 S']:
            with self.assertRaises(ValueError): m.parse_ps(bad,[20])
        self.assertEqual(m.parse_ps('',[20]),{})

    def test_group_permission_requires_owned_live_group(self):
        h=identity(10,1); f=identity()
        self.assertTrue(m.group_allowed(h,f,10,20,501))
        for key,value in [('pid',21),('ppid',1),('pgid',11),('uid',502),('command','sleep 2')]:
            bad=dict(f); bad[key]=value
            self.assertFalse(m.group_allowed(h,bad,10,20,501))
        self.assertFalse(m.group_allowed(None,f,10,20,501))
        self.assertFalse(m.group_allowed(dict(h,pgid=9),f,10,20,501))

    def test_pid_fallback_requires_complete_unchanged_identity(self):
        before=identity(ppid=1)
        self.assertTrue(m.pid_allowed(before,dict(before),20,10,501))
        for key in ['pid','ppid','pgid','uid','started','command']:
            bad=dict(before); bad[key]='changed'
            self.assertFalse(m.pid_allowed(before,bad,20,10,501))
        self.assertFalse(m.pid_allowed(before,None,20,10,501))
        self.assertFalse(m.pid_allowed(before,dict(before),20,10,502))

    def test_natural_exit_is_not_kill_success_and_timeout_is_not_absence(self):
        self.assertEqual(m.classify_outcome(False,True),'natural-exit-candidate')
        self.assertEqual(m.classify_outcome(True,True),'signal-sent-then-absent')
        self.assertEqual(m.classify_outcome(True,False),'unresolved')
        self.assertEqual(m.classify_outcome(False,False),'unresolved')

    def test_phase_order_and_quota_boundaries(self):
        self.assertTrue(m.phase_order(['sandbox','control']))
        for phases in [[],['control','sandbox'],['sandbox','sandbox','control']]:
            self.assertFalse(m.phase_order(phases))
        self.assertTrue(m.quota_ok(2*1024*1024,32))
        self.assertFalse(m.quota_ok(2*1024*1024+1,32))
        self.assertFalse(m.quota_ok(0,33))
        self.assertFalse(m.quota_ok(-1,1))

    def test_eperm_does_not_stop_independent_records(self):
        steps=[]
        def denied(): raise PermissionError(1,'denied')
        m.call_record(steps,'getpgid',20,denied)
        m.call_record(steps,'signal0',20,denied)
        m.call_record(steps,'group0',10,lambda:None)
        self.assertEqual([x['ok'] for x in steps],[False,False,True])
        self.assertEqual(steps[0]['errno'],1)

    def test_kill_requires_reaped70_and_fallback_requires_failed_group(self):
        names=['live-ps','live-getpgid','live-pid-signal0','live-getpgid','live-pid-signal0',
               'live-group-signal0','release','helper-wait','reaped-ps','reaped-getpgid',
               'reaped-pid-signal0','reaped-getpgid','reaped-pid-signal0','reaped-group-signal0',
               'prekill-ps','group-SIGKILL','fallback-ps','fixture-SIGKILL']
        steps=[dict(step=n,start_ns=2*i,end_ns=2*i+1,ok=True,value=None) for i,n in enumerate(names)]
        steps[7]['value']=70; steps[15]['ok']=False
        self.assertTrue(m.valid_step_order(steps))
        steps[15]['ok']=True; self.assertFalse(m.valid_step_order(steps)); steps[15]['ok']=False
        steps[7]['value']=71; self.assertFalse(m.valid_step_order(steps)); steps[7]['value']=70
        steps[15]['start_ns']=0; self.assertFalse(m.valid_step_order(steps))

    def test_unresolved_fixture_blocks_terminal_success_and_next_phase(self):
        for status in ['unresolved','inconclusive','signal-sent-then-absent']:
            self.assertFalse(m.phase_allows_next(dict(status=status,fixture_absent=False)))
        self.assertFalse(m.phase_allows_next(dict(status='natural-exit-candidate')))
        self.assertTrue(m.phase_allows_next(dict(status='natural-exit-candidate',fixture_absent=True)))
        self.assertTrue(m.phase_allows_next(dict(status='signal-sent-then-absent',fixture_absent=True)))
        self.assertFalse(m.phase_allows_next(dict(status='natural-exit-candidate',fixture_absent=True,error='failed')))

    def test_final_hash_failure_keeps_other_hashes_and_bounded_error(self):
        def digest(path):
            if path=='gone': raise OSError('gone'*1000)
            return 'a'*64
        hashes,errors=m.final_hash_snapshot(['first','gone','last'],digest)
        self.assertEqual(hashes,{'first':'a'*64,'gone':None,'last':'a'*64})
        self.assertEqual(len(errors),1)
        self.assertLessEqual(len(errors[0]),2048)

    def test_final_counts_failure_is_snapshot_once(self):
        calls=[]
        def count(): calls.append(1); raise ValueError('quota'*1000)
        result=m.final_count_snapshot(count)
        self.assertEqual(calls,[1])
        self.assertIsNone(result['counts'])
        self.assertLessEqual(len(result['counts_error']),2048)

if __name__=='__main__': unittest.main()
