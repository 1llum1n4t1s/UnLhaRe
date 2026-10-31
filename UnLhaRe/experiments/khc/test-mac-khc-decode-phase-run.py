"""先行失敗条件: build未証明、二重起動、20s終了不明、出力超過、phase/復元/観測不整合。"""
import copy
import importlib.util
from pathlib import Path
import types
import unittest

spec=importlib.util.spec_from_file_location('phase_run',Path(__file__).with_name('mac-khc-decode-phase-run.py'))
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)


def phase_value():
    phases=[dict(name=name,calls=0,ns=0) for name in M.PHASE_NAMES]
    for row in phases:
        if row['name'] in ('archive.whole','archive.open','archive.manifest'):row.update(calls=1,ns=10)
    return dict(schema=1,purpose=M.PURPOSE,superiority_decision_allowed=False,status='completed',
        summary=dict(entries=11,files=11,bytes=2810784),error=None,
        phase_report=dict(schema=1,purpose=M.PURPOSE,superiority_decision_allowed=False,inclusive=True,
            aggregation=M.AGGREGATION,unmeasured_scope=M.UNMEASURED,outer_total_ns=100,
            lost_measurements=False,phases=phases))


class Run(unittest.TestCase):
    def test_exact_phase_report_and_single_top_level_calls(self):
        value=phase_value();M.validate_phase_stdout(M.canonical(value),1000)
        # inclusive/並列計上をouter以下へ制限しない。
        value['phase_report']['phases'][5].update(calls=2,ns=200)
        M.validate_phase_stdout(M.canonical(value),1000)

    def test_phase_shape_types_missing_duplicate_lost_and_outer_are_rejected(self):
        for kind in ('missing','duplicate','lost','inclusive','float','bool','negative','outer','whole','extra','summary'):
            value=phase_value();r=value['phase_report']
            if kind=='missing':r['phases'].pop()
            if kind=='duplicate':r['phases'][-1]['name']=r['phases'][0]['name']
            if kind=='lost':r['lost_measurements']=True
            if kind=='inclusive':r['inclusive']=False
            if kind=='float':r['phases'][0]['ns']=1.5
            if kind=='bool':r['phases'][0]['calls']=True
            if kind=='negative':r['phases'][0]['ns']=-1
            if kind=='outer':r['outer_total_ns']=1001
            if kind=='whole':r['phases'][0]['calls']=2
            if kind=='extra':value['extra']=1
            if kind=='summary':value['summary']['files']=10
            with self.subTest(kind=kind),self.assertRaises(Exception):M.validate_phase_stdout(M.canonical(value),1000)
        with self.assertRaises(Exception):M.validate_phase_stdout(b'{"schema":1,"schema":1}\n',1000)
        with self.assertRaises(Exception):M.validate_phase_stdout(b'x'*16385,1000)

    def test_build_gate_requires_success_raw_bound_summary(self):
        value=dict(status='done',exit=0,wait_confirmed=True,group_absent=True,postchecks_ok=True,
            source_sha256=M.SOURCE_SHA,binary_sha256=M.BINARY_SHA,closure_sha256=M.BUILD_CLOSURE_SHA)
        checked=dict(verified=True,cleanup_allowed=True,status='done',exit=0,receipt_sha256=M.BUILD_RECEIPT_SHA,
                     binary_sha256=M.BINARY_SHA,closure_sha256=M.BUILD_CLOSURE_SHA)
        M.gate_build(value,checked)
        for key,bad in [('status','failed'),('postchecks_ok',False),('wait_confirmed',False),('binary_sha256','0'*64)]:
            with self.assertRaises(Exception):M.gate_build(dict(value,**{key:bad}),checked)
        with self.assertRaises(Exception):M.gate_build(value,dict(checked,cleanup_allowed=False))

    def test_single_invocation_wait_and_output_supervision(self):
        calls=[];clock=iter((0,1,2,3)).__next__
        observer=types.SimpleNamespace(begin_event=lambda:0,finish_event=lambda token:dict(id=token,start_ns=0,end_ns=4))
        usage=types.SimpleNamespace(ru_utime=0.,ru_stime=0.,ru_maxrss=100)
        row=M.run_once(['binary','archive','decoded'],observer,
            spawn=lambda command:calls.append(command) or 123,
            wait=lambda pid,flags:(pid,0,usage),read_outputs=lambda:(b'{}\n',b''),
            check_outputs=lambda:None,clock=clock,sleep=lambda _:None)
        self.assertEqual(len(calls),1);self.assertEqual(row['pid'],123)
        self.assertEqual(row['wait_status'],0)
        self.assertEqual(row['metric']['elapsed_ns'],3)

    def test_terminal_storage_deadline_downgrades_once_and_keeps_failure(self):
        value=dict(status='done',exit=0,error=None,postchecks_ok=True,runtime_seconds=1.)
        saved=[];replaced=[]
        result=M.persist_terminal(value,0.,lambda r:saved.append(copy.deepcopy(r)),
            lambda r,sha:replaced.append((r,sha)),clock=lambda:61.)
        self.assertEqual(len(saved),1);self.assertEqual(len(replaced),1)
        self.assertEqual(replaced[0][1],M.digest(M.canonical(saved[0])))
        self.assertEqual(result['status'],'failed');self.assertEqual(result['exit'],1)
        self.assertEqual(result['runtime_seconds'],61.)
        with self.assertRaises(Exception):
            M.persist_terminal(value,0.,lambda r:None,lambda *a:(_ for _ in ()).throw(OSError('replace failed')),clock=lambda:61.)

    def test_deadline_or_output_failure_does_not_spawn_again(self):
        spawned=[];observer=types.SimpleNamespace(begin_event=lambda:0,finish_event=lambda _:self.fail('finish live child'))
        with self.assertRaises(Exception):
            M.run_once(['binary'],observer,spawn=lambda c:spawned.append(c) or 123,
                wait=lambda *a:(0,0,None),read_outputs=lambda:(b'',b''),check_outputs=lambda:None,
                clock=iter((0,1,21_000_000_000)).__next__,sleep=lambda _:None)
        self.assertEqual(len(spawned),1)
        with self.assertRaises(Exception):
            M.run_once(['binary'],observer,spawn=lambda c:123,wait=lambda *a:(0,0,None),
                read_outputs=lambda:(b'',b''),check_outputs=lambda:(_ for _ in ()).throw(ValueError('output cap')),
                clock=iter((0,1)).__next__,sleep=lambda _:None)

    def test_fixed_capture_count_and_deadline(self):
        raw=dict(schema=1,cadence_ns=1250000000,max_captures=24,completed=True,failure=None,captures=[],
                 events=[dict(id=0,start_ns=4000000000,end_ns=5000000000)])
        for i in range(24):raw['captures'].append(dict(id=i,target_ns=i*1250000000,start_ns=i*1250000000,
            end_ns=i*1250000000+1000000,environment=dict(schema=1,cpu_ticks=[10*i,5*i,85*i,0],
            logical_cpus=14,thermal_state=0,ac_power=True)))
        M.validate_observation(raw)
        raw['captures'].pop()
        with self.assertRaises(Exception):M.validate_observation(raw)

    def test_quota_reservation_includes_journal(self):
        self.assertEqual(M.quota_counts(1,1)['charged_bytes'],131073)
        for size,count in [(8*1024**2,1),(1,64),(-1,1)]:
            with self.assertRaises(Exception):M.quota_counts(size,count)


if __name__=='__main__':unittest.main()
