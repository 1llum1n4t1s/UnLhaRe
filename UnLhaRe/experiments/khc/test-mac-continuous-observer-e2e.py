"""native E2Eの合否条件をOS実行より前に固定する。"""
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('driver', Path(__file__).with_name('mac-continuous-observer-e2e.py'))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def raw(count=10, completed=True, fault=False):
    captures = [dict(id=i,target_ns=i*m.OBS.CADENCE_NS,start_ns=i*m.OBS.CADENCE_NS,
                    end_ns=i*m.OBS.CADENCE_NS+1000000,
                    environment=dict(schema=1,cpu_ticks=[i*10,i*5,i*135,0],logical_cpus=14,
                                     thermal_state=0,ac_power=True)) for i in range(count)]
    events = [dict(id=i,start_ns=p,end_ns=p+3000000) for i,p in enumerate(m.EVENT_NS)]
    if fault:
        events = [dict(id=0,start_ns=4000000000,end_ns=None)]
    value = dict(schema=1,cadence_ns=m.OBS.CADENCE_NS,max_captures=10,completed=completed,
                 failure='RuntimeError: injected-capture-fault' if fault else None,
                 captures=captures,events=events,epoch_ns=100)
    value['validation'] = m.OBS.validate_report(value)
    return value


class DriverTests(unittest.TestCase):
    def normal(self):
        r = raw()
        metrics = [dict(event_id=i,planned_start_ns=p,spawn_start_ns=p+1000000,
                        wait_end_ns=p+2000000,elapsed_ns=1000000,user_seconds=.0005,
                        system_seconds=.0001,peak_rss_bytes=1000000,normal_exit=True,
                        exit_code=0,signal=None,command=[str(m.CLI),'--version'])
                   for i,p in enumerate(m.EVENT_NS)]
        return dict(schema=1,purpose=m.PURPOSE,phase='normal',observer=r,metrics=metrics)

    def test_normal_and_command_rejection(self):
        value = self.normal()
        m.validate_normal(value)
        value['metrics'][0]['command'][-1] = 'khc-extract'
        with self.assertRaises(ValueError):
            m.validate_normal(value)

    def test_derived_validation_and_time_are_recomputed(self):
        for alter in ('validation','elapsed'):
            value = self.normal()
            if alter == 'validation':
                value['observer']['validation']['events'][0]['window_ids'] = []
            else:
                value['metrics'][0]['elapsed_ns'] += 1
            with self.assertRaises(ValueError):
                m.validate_normal(value)

    def fault(self):
        failure = dict(schema=1,phase='fault',error_type='RuntimeError',error='injected-capture-fault',
                       failure_ns=5000000000,observer=raw(4,False,True))
        pending = dict(schema=1,phase='fault',token=0,pid=222,parent_pid=111,
                       command=['/bin/sleep','45'],spawn_start_ns=4001000000)
        entered = dict(schema=1,token=0,pid=222,entered_ns=4002000000)
        return failure,pending,entered

    def test_fault_needs_actual70_and_pending_wait4(self):
        f,p,e = self.fault()
        m.validate_fault(70,f,p,e,False,111,True)
        for rc,finished,absent in ((-9,False,True),(1,False,True),(70,True,True),(70,False,False)):
            with self.assertRaises(ValueError):
                m.validate_fault(rc,f,p,e,finished,111,absent)

    def test_unrelated_failure_is_not_injection_success(self):
        f,p,e = self.fault()
        f['error'] = 'CPU limit'
        with self.assertRaises(ValueError):
            m.validate_fault(70,f,p,e,False,111,True)

    def test_journal_and_both_phases_charged(self):
        value = m.quota_counts(1048576,32)
        self.assertEqual(value['charged_bytes'],1048576+163840)
        self.assertLessEqual(value['charged_entries'],64)
        with self.assertRaises(ValueError):
            m.quota_counts(1048577,32)


if __name__ == '__main__':
    unittest.main()
