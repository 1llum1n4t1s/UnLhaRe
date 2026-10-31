"""48-event observer contract: failure cases are defined before code.

Reject cadence/count/CPU/thermal/AC relaxation, missing/late/overlap events,
incomplete captures, reused or reordered bindings, expired deadlines and oversized
raw evidence. No real Mac, measured CLI, storage registration or process spawn.
"""
import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('observer_protocol',HERE/'observer_protocol.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

def raw_fixture():
    captures=[dict(id=i,target_ns=i*p.CADENCE_NS,start_ns=i*p.CADENCE_NS,end_ns=i*p.CADENCE_NS+1000000,
        environment=dict(schema=1,cpu_ticks=[0,0,i*100,0],logical_cpus=14,thermal_state=0,ac_power=True))
        for i in range(p.CAPTURE_COUNT)]
    events=[dict(id=i,start_ns=5_000_000_000+i*1_000_000,end_ns=5_000_500_000+i*1_000_000)
        for i in range(p.EVENT_COUNT)]
    return dict(schema=1,cadence_ns=p.CADENCE_NS,max_captures=p.CAPTURE_COUNT,completed=True,
        captures=captures,events=events,failure=None,epoch_ns=100)

def shift_closure(proof,offset):
    for key in ('wait_start_ns','wait_end_ns','wait_deadline_ns','group_deadline_ns','group_absent_ns'):
        proof[key]+=offset
    for call in proof['raw_calls']:
        call['start_ns']+=offset;call['end_ns']+=offset

class ProtocolTests(unittest.TestCase):
    def test_complete_48_events_and_fixed_resource_budget(self):
        raw=raw_fixture();self.assertTrue(p.validate_observer(raw)['eligible'])
        self.assertEqual(p.last_capture_seconds(),299.0)
        protocol=p.expected_protocol('a'*64);p.validate_protocol(protocol,'a'*64)
        self.assertLessEqual(protocol['observer_start_max_seconds']+p.last_capture_seconds()+
            protocol['closure_reserve_seconds']+protocol['final_reserve_seconds'],protocol['native_timeout_seconds'])
        for field,value in [('cpu_interval_limit_percent',31),('thermal_state_required',1),
                            ('native_timeout_seconds',351),('capture_count',241)]:
            with self.subTest(field=field),self.assertRaises(ValueError):
                p.validate_protocol(dict(protocol,**{field:value}),'a'*64)
        for path,expected in ((HERE/'evaluation.py',p.EVALUATION_SHA),(HERE/'process_adapter.py',p.ADAPTER_SHA),
                              (HERE/'wait4_helper.py',p.HELPER_SHA),(HERE.parent/'mac-finite-supervisor.py',p.FS_SHA),
                              (HERE.parent/'mac-continuous-cpu-observer.py',p.OBSERVER_SHA)):
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),expected)

    def test_incomplete_reordered_late_thermal_or_power_are_invalid(self):
        for change in ('missing_event','incomplete','hot','battery','cpu','overlap','uncovered'):
            raw=raw_fixture()
            if change=='missing_event':raw['events'].pop()
            if change=='incomplete':raw['completed']=False
            if change=='hot':raw['captures'][4]['environment']['thermal_state']=1
            if change=='battery':raw['captures'][4]['environment']['ac_power']=False
            if change=='cpu':raw['captures'][1]['environment']['cpu_ticks']=[100,0,100,0]
            if change=='overlap':raw['events'][1]['start_ns']=raw['events'][0]['start_ns']
            if change=='uncovered':raw['events'][-1]['end_ns']=raw['captures'][-1]['start_ns']
            with self.subTest(change=change),self.assertRaises(ValueError):p.validate_observer(raw)

    def test_join_is_chunked_and_total_deadline_is_fixed(self):
        observer=mock.Mock();observer.join.side_effect=[False,True];observer.report.return_value=raw_fixture()
        result=p.await_complete(observer,deadline=30,clock=iter((1,2,3,4)).__next__)
        self.assertTrue(result['eligible'])
        self.assertTrue(all(call.args[0]<=10 for call in observer.join.call_args_list))
        observer=mock.Mock();observer.join.return_value=False
        with self.assertRaises(ValueError):p.await_complete(observer,deadline=1,clock=lambda:1)
        observer.join.return_value=True;observer.report.return_value=raw_fixture()
        with self.assertRaisesRegex(ValueError,'deadline'):p.await_complete(observer,deadline=30,clock=iter((1,31)).__next__)

    def test_each_event_is_bound_to_fixed_command_and_owned_closure(self):
        raw=raw_fixture();bindings=[]
        source=HERE.parent/'test-mac-decode-phase-build.py'
        spec=importlib.util.spec_from_file_location('reference_fixture',source)
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        _,receipt=fixture.fixture()
        for event in raw['events']:
            event_id=event['id'];index,direction,command,cwd=p.expected_event(event_id)
            proof=copy.deepcopy(receipt['closure_proof']);proof['sequence']=event_id+1;proof['generation']=event_id+1
            for call in proof['raw_calls']:call['generation']=event_id+1
            shift_closure(proof,raw['epoch_ns']+event['start_ns']+1)
            bindings.append(dict(event_id=event_id,trial_index=index,direction=direction,command=command,cwd=cwd,
                start_ns=event['start_ns'],end_ns=event['end_ns'],
                closure=dict(raw=proof,expected_pid=100,expected_sequence=event_id+1)))
        self.assertTrue(p.validate_bindings(raw,bindings))
        summary=p.validate_complete_evidence(raw,bindings,native_begin_ns=0,completed_ns=299_000_000_000)
        self.assertTrue(summary['eligible']);self.assertEqual(summary['event_count'],48)
        with self.assertRaises(ValueError):
            p.validate_complete_evidence(raw,bindings,native_begin_ns=0,completed_ns=318_000_000_000)
        for change in ('missing','command','sequence','overlap','other_time','before_event'):
            modified=copy.deepcopy(bindings)
            if change=='missing':modified.pop()
            if change=='command':modified[0]['command']=['/unexpected']
            if change=='sequence':modified[1]['closure']['expected_sequence']=1
            if change=='overlap':modified[1]['start_ns']=modified[0]['start_ns']
            if change=='other_time':shift_closure(modified[0]['closure']['raw'],1_000_000_000)
            if change=='before_event':shift_closure(modified[0]['closure']['raw'],-3)
            with self.subTest(change=change),self.assertRaises(ValueError):p.validate_bindings(raw,modified)

    def test_observer_start_and_final_event_deadlines(self):
        p.validate_start_timing(100,8_000_000_100)
        with self.assertRaises(ValueError):p.validate_start_timing(100,8_000_000_101)
        p.validate_event_deadline((p.CAPTURE_COUNT-1)*p.CADENCE_NS-1)
        with self.assertRaises(ValueError):p.validate_event_deadline((p.CAPTURE_COUNT-1)*p.CADENCE_NS)
        deadlines=p.runtime_deadlines(100)
        self.assertEqual(deadlines['observer_finish_ns'],317_000_000_100)
        self.assertEqual(deadlines['closure_finish_ns'],330_000_000_100)
        self.assertEqual(deadlines['native_finish_ns'],350_000_000_100)
        with self.assertRaises(ValueError):p.runtime_deadlines(True)

    def test_native_entry_is_unavailable(self):
        with self.assertRaises(p.IntegrationUnavailable):p.create_native_observer()

if __name__=='__main__':unittest.main()
