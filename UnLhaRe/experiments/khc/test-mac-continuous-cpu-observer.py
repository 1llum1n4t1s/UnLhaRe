#!/usr/bin/env python3
"""失敗条件を先に固定する。外部プロセス・codec・ファイル出力は使わない。"""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('observer', Path(__file__).with_name('mac-continuous-cpu-observer.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def env(i, busy=10):
    return dict(schema=1, cpu_ticks=[busy*i, 0, (100-busy)*i, 0],
                logical_cpus=14, thermal_state=0, ac_power=True)


def report(count=6, duration=0, late=0, busy=10):
    return dict(schema=1, cadence_ns=1_250_000_000, max_captures=count,
                captures=[dict(id=i, target_ns=i*1_250_000_000,
                               start_ns=i*1_250_000_000+late,
                               end_ns=i*1_250_000_000+late+duration,
                               environment=env(i, busy)) for i in range(count)],
                events=[], failure=None, completed=True)


class ValidatorTests(unittest.TestCase):
    def test_boundaries_and_modulo(self):
        r = report(duration=200_000_000, late=50_000_000, busy=15)
        self.assertTrue(m.validate_report(r)['eligible'])
        r = report(count=4)
        r['captures'][0]['environment']['cpu_ticks'] = [2**32-10, 0, 2**32-90, 0]
        self.assertTrue(m.validate_report(r)['eligible'])

    def test_every_failure_is_rejected(self):
        cases = []
        for key, value in [('start_ns', 50_000_001), ('end_ns', 200_000_001), ('id', 1), ('target_ns', 1)]:
            r=report(); r['captures'][0][key]=value; cases.append(r)
        for key,value in [('schema', True), ('logical_cpus', 13), ('thermal_state', 4),
                          ('ac_power', 1), ('cpu_ticks', [0, 0, 0, -1])]:
            r=report(); r['captures'][2]['environment'][key]=value; cases.append(r)
        for busy in [16, 31]:
            cases.append(report(busy=busy))
        r=report(); r['captures'][4]['environment']=env(3); cases.append(r)
        r=report(); r['captures'].pop(4); cases.append(r)
        r=report(); r['captures'][4]['start_ns']=r['captures'][3]['end_ns']; cases.append(r)
        r=report(); r['captures'][4]['end_ns']=r['captures'][4]['start_ns']-1; cases.append(r)
        cases.extend([report(count=0), report(count=3)])
        for r in cases:
            with self.subTest(r=r): self.assertFalse(m.validate_report(r)['eligible'])

    def test_runtime_limit_entry_and_thermal_ac(self):
        r=report(); r['captures'][4]['environment']=env(4, 15)
        # 窓4は30%: busy delta=30 / total100。
        r['captures'][4]['environment']['cpu_ticks']=[60,0,340,0]
        r['captures'][5]['environment']['cpu_ticks']=[90,0,410,0]
        self.assertTrue(m.validate_report(r)['eligible'])
        for key,value in [('thermal_state',1),('ac_power',False)]:
            bad=report(); bad['captures'][5]['environment'][key]=value
            self.assertFalse(m.validate_report(bad)['eligible'])

    def test_inclusive_overlap_and_pending_coverage(self):
        r=report()
        r['events']=[dict(id=0,start_ns=3_750_000_000,end_ns=5_000_000_000)]
        v=m.validate_report(r)
        self.assertTrue(v['eligible'])
        self.assertEqual(v['events'][0]['window_ids'], [3,4,5])
        r['events'][0]['end_ns']=6_250_000_001
        self.assertFalse(m.validate_report(r)['eligible'])
        r['completed']=False
        self.assertEqual(m.validate_report(r)['events'][0]['state'],'pending')
        r['failure']='subsequent capture failed'
        self.assertEqual(m.validate_report(r)['events'][0]['state'],'failed')

    def test_endpoints_start_before_entry_and_spanning_gap(self):
        for start,end in [(0,1), (3_750_000_000,3_749_999_999), (3_750_000_000,None)]:
            r=report(); r['events']=[dict(id=0,start_ns=start,end_ns=end)]
            self.assertFalse(m.validate_report(r)['eligible'])
        r=report(); r['captures'].pop(4)
        r['events']=[dict(id=0,start_ns=3_750_000_000,end_ns=5_000_000_000)]
        self.assertFalse(m.validate_report(r)['eligible'])

    def test_exact_window_bounds_and_outside_by_one(self):
        r=report()
        r['captures'][0].update(start_ns=50_000_000,end_ns=250_000_000)
        self.assertEqual(m.validate_report(r)['windows'][0]['lower_ns'],1_000_000_000)
        self.assertTrue(m.validate_report(r)['eligible'])
        r['captures'][0]['end_ns']+=1
        self.assertFalse(m.validate_report(r)['eligible'])
        r=report()
        r['captures'][1].update(start_ns=1_300_000_000,end_ns=1_500_000_000)
        self.assertEqual(m.validate_report(r)['windows'][0]['upper_ns'],1_500_000_000)
        self.assertTrue(m.validate_report(r)['eligible'])
        r['captures'][1]['end_ns']+=1
        self.assertFalse(m.validate_report(r)['eligible'])

    def test_report_tampering_ignores_derived_claim(self):
        r=report(); r['captures'][3]['environment']=env(2)
        r['validation']={'eligible':True,'errors':[]}
        self.assertFalse(m.validate_report(r)['eligible'])

    def test_active_equality_waits_for_future_window_fixed_final_equality_passes(self):
        r=report()
        r['events']=[dict(id=0,start_ns=3_750_000_000,end_ns=6_250_000_000)]
        self.assertTrue(m.validate_report(r)['eligible'])
        self.assertEqual(m.validate_report(r)['events'][0]['window_ids'],[3,4,5])
        r['completed']=False
        self.assertEqual(m.validate_report(r)['events'][0]['state'],'pending')
        r['max_captures']=7
        r['captures'].append(dict(id=6,target_ns=7_500_000_000,start_ns=7_500_000_000,
                                  end_ns=7_500_000_000,environment=env(6)))
        result=m.validate_report(r)['events'][0]
        self.assertEqual(result['state'],'covered')
        self.assertEqual(result['window_ids'],[3,4,5,6])


class Clock:
    def __init__(self): self.now=100_000_000_000
    def __call__(self): return self.now
    def sleep(self, seconds): self.now+=round(seconds*1_000_000_000)


class ObserverTests(unittest.TestCase):
    def make(self, count=6, callback=None, fail_at=None):
        clock=Clock(); failures=[]; holder={}; calls=[]
        def capture():
            i=len(calls); calls.append(i)
            if i==fail_at: raise RuntimeError('native failure')
            return env(i)
        def on_capture(raw):
            if callback: callback(holder['o'], clock, raw)
        o=m.Observer(capture,on_failure=lambda e,r: failures.append((e,r)),on_capture=on_capture,
                     max_captures=count,clock=clock,sleep=clock.sleep)
        holder['o']=o
        return o,clock,failures

    def test_event_pending_then_covered_and_deepcopy(self):
        def callback(o,c,r):
            if r['id']==3:
                token=o.begin_event(); c.now+=1; event=o.finish_event(token)
                self.assertEqual(event['state'],'pending')
            r['environment']['cpu_ticks'][0]=999999
        o,c,f=self.make(callback=callback); o.start(); self.assertTrue(o.join(2))
        self.assertTrue(o.wait_entry_ready(0)); self.assertFalse(f)
        r=o.report(); self.assertTrue(m.validate_report(r)['eligible'])
        self.assertEqual(r['captures'][0]['environment']['cpu_ticks'][0],0)
        r['captures'].clear(); self.assertEqual(len(o.report()['captures']),6)

    def test_failure_is_terminal_callback_and_new_event_rejected(self):
        o,c,f=self.make(fail_at=4); o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertEqual(len(f),1); self.assertEqual(len(f[0][1]),4)
        with self.assertRaises(m.ObservationError): o.begin_event()

    def test_callback_delay_is_not_resynchronized(self):
        def callback(o,c,r):
            if r['id']==3: c.now+=1_300_000_001
        o,c,f=self.make(callback=callback); o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertEqual(len(f),1)

    def test_callback_exception_and_missing_failure_handler(self):
        with self.assertRaises(ValueError): m.Observer(lambda:env(0),on_failure=None)
        def callback(o,c,r): raise RuntimeError('save failure')
        o,c,f=self.make(callback=callback); o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertEqual(len(f),1)

    def test_no_permission_before_entry_and_callback_failure_is_shared(self):
        o,c,f=self.make()
        with self.assertRaises(m.ObservationError): o.begin_event()
        def broken(error,raw): raise RuntimeError('failure sink broken')
        o._on_failure=broken; o._capture=lambda: None
        o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertIn('failure sink broken',o.report()['failure'])

    def test_finished_event_without_coverage_fails_and_later_failure_invalidates(self):
        def callback(o,c,r):
            if r['id']==3:
                token=o.begin_event(); c.now+=1; o.finish_event(token)
        for count,fail_at in [(4,None),(6,4)]:
            o,c,f=self.make(count=count,callback=callback,fail_at=fail_at); o.start()
            with self.assertRaises(m.ObservationError): o.join(2)
            self.assertEqual(len(f),1)
            self.assertEqual(o.report()['validation']['events'][0]['state'],'failed')

    def test_zero_ticks_keeps_raw_without_retry(self):
        o,c,f=self.make()
        o._capture=lambda:env(0)
        o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertEqual(len(o.report()['captures']),2)
        self.assertEqual(len(f[0][1]),2)
        self.assertIn('Unobservable',o.report()['failure'])

    def test_reversed_event_endpoint_is_terminal(self):
        def callback(o,c,r):
            if r['id']==3:
                token=o.begin_event(); c.now-=1
                with self.assertRaises(m.ObservationError): o.finish_event(token)
        o,c,f=self.make(callback=callback); o.start()
        with self.assertRaises(m.ObservationError): o.join(2)
        self.assertEqual(len(f),1)
        with self.assertRaises(m.ObservationError): o.begin_event()


if __name__=='__main__': unittest.main()
