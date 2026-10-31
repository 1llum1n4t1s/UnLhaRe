"""Adapter failure tests: no real Mac, Cargo, candidate CLI or storage changes.

Reject unavailable resource usage, incomplete/invalid host observation, child
timeout, overflow, signal/nonzero exit, absent/unknown group closure and unsafe
command or cwd. Preserve raw closure and metrics only for a verified call.
"""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock
import json
import base64
import threading
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('process_adapter',Path(__file__).with_name('process_adapter.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)

class AdapterTests(unittest.TestCase):
    def test_bridge_owns_a_distinct_supervisor_and_excludes_concurrent_run(self):
        fs=mock.Mock();template=mock.Mock();owned=mock.Mock();fs.Supervisor.return_value=owned
        bridge=a.FrozenBackendBridge(fs,template,mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock())
        self.assertIs(bridge._supervisor,owned);self.assertIsNot(bridge._supervisor,template)
        fs.Supervisor.assert_called_once_with(template.root,template.support,ops=template._ops)
        entered=threading.Event();release=threading.Event();out=[]
        def blocking(**_kwargs):entered.set();release.wait(5);return 'done'
        bridge._run_owned=blocking
        thread=threading.Thread(target=lambda:out.append(bridge.run(command=[],timeout=20,cwd='/fixed')))
        thread.start()
        try:
            self.assertTrue(entered.wait(5))
            with self.assertRaises(a.InvalidObservation):bridge.run(command=[],timeout=20,cwd='/fixed')
        finally:release.set();thread.join(5)
        self.assertEqual(out,['done']);self.assertFalse(thread.is_alive())

    def test_child_timeout_is_bounded_by_absolute_observer_deadline(self):
        self.assertEqual(a.bounded_child_timeout(100,240_000_000_100,60),59.)
        self.assertEqual(a.bounded_child_timeout(100,100_000_000_100,20),20.)
        for begin,now,timeout in ((None,0,60),(100,99,60),(100,299_000_000_100,20),(100,100,61)):
            with self.subTest(now=now,timeout=timeout),self.assertRaises(a.InvalidObservation):
                a.bounded_child_timeout(begin,now,timeout)

    def test_expired_child_start_aborts_before_supervisor(self):
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
        supervisor=mock.Mock();helper=mock.Mock();helper.verify_identity.return_value=True
        fs=mock.Mock();fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),mock.Mock(),helper,lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',return_value=300_000_000_100),self.assertRaises(a.BackendFailure):
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        supervisor.run.assert_not_called()
        lifecycle.abort_observer.assert_called_once_with(deadline_ns=330_000_000_100)

    def test_spawn_guard_rechecks_deadline_after_slow_admission(self):
        ops=mock.Mock();lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        guard=a.DeadlineSpawnGuard(ops,lifecycle,100,59.)
        with mock.patch.object(a.time,'monotonic_ns',return_value=242_000_000_100),\
             self.assertRaises(a.InvalidObservation):guard.popen(['/fixed'])
        ops.popen.assert_not_called()
        with mock.patch.object(a.time,'monotonic_ns',return_value=240_500_000_100):guard.popen(['/fixed'])
        ops.popen.assert_called_once()

    def test_untrusted_native_clock_cannot_start_child(self):
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=False
        lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
        supervisor=mock.Mock();helper=mock.Mock();helper.verify_identity.return_value=True
        fs=mock.Mock();fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),mock.Mock(),helper,lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',return_value=200),self.assertRaises(a.BackendFailure):
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        supervisor.run.assert_not_called();helper.command.assert_not_called()

    def test_bridge_clamps_outer_timeout_and_keeps_fixed_helper_timeout(self):
        fs=mock.Mock();fs.validate_closure.return_value=True
        supervisor=mock.Mock();supervisor.sequence=0;supervisor.process=mock.Mock(pid=123)
        supervisor._owned_process=supervisor.process;supervisor._owned_pid=123
        supervisor.last_closure={'pid':123,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
        def run(*_args,**_kwargs):
            supervisor._ops.popen();supervisor.sequence=1
            return json.dumps(dict(schema=1,metric=self.metric,stdout_base64='',stderr_base64=''))
        supervisor.run.side_effect=run
        helper=mock.Mock();helper.verify_identity.return_value=True;helper.command.return_value=['/absolute/helper']
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        observer=mock.Mock();observer.begin_event.return_value=0
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),observer,helper,lifecycle,native_begin_ns=100)
        with mock.patch('os.path.isabs',return_value=True),\
             mock.patch.object(a.time,'monotonic_ns',return_value=240_000_000_100),\
             mock.patch.object(bridge,'_covered',return_value={'event_id':0,'report':{}}):
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        self.assertEqual(supervisor.run.call_args.kwargs['timeout'],59.)
        self.assertEqual(helper.command.call_args.kwargs['timeout'],60)

    def test_child_measured_beyond_clamped_timeout_is_invalid(self):
        fs=mock.Mock();fs.validate_closure.return_value=True
        supervisor=mock.Mock();supervisor.sequence=0;supervisor.process=mock.Mock(pid=123)
        supervisor._owned_process=supervisor.process;supervisor._owned_pid=123
        supervisor.last_closure={'pid':123,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
        metric=dict(self.metric,elapsed_ns=60_000_000_000,user_seconds=30.)
        def run(*_args,**_kwargs):
            supervisor._ops.popen();supervisor.sequence=1
            return json.dumps(dict(schema=1,metric=metric,stdout_base64='',stderr_base64=''))
        supervisor.run.side_effect=run
        helper=mock.Mock();helper.verify_identity.return_value=True;helper.command.return_value=['/absolute/helper']
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
        observer=mock.Mock();observer.begin_event.return_value=0
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),observer,helper,lifecycle,native_begin_ns=100)
        with mock.patch('os.path.isabs',return_value=True),\
             mock.patch.object(a.time,'monotonic_ns',return_value=240_000_000_100),self.assertRaises(a.BackendFailure):
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        lifecycle.abort_observer.assert_called_once()

    def setUp(self):
        self.metric=dict(elapsed_ns=1000000,user_seconds=.0005,system_seconds=0.,peak_rss_bytes=4096,
            normal_exit=True,exit_code=0,signal=None,cpu_per_wall=.5)
        self.proof={'closed':True};self.host={'eligible':True}
        self.backend=mock.Mock();self.backend.run.return_value=dict(metric=self.metric,closure_proof=self.proof,
            host_observation=self.host,stdout=b'ok',stderr=b'')
        self.backend.verify_closure.return_value=True;self.backend.verify_host.return_value=True
    def test_valid_call_preserves_raw_evidence(self):
        value=a.verify_observation(self.backend.run(),60,self.backend)
        self.assertEqual(value['metric']['peak_rss_bytes'],4096)
        self.assertEqual(value['closure_proof'],self.proof)

    def test_helper_result_wire_is_bounded_and_preserves_two_streams(self):
        value=dict(metric=self.metric,stdout=b'hello',stderr=b'error')
        raw=a.encode_helper_result(value);decoded=json.loads(raw)
        self.assertEqual(base64.b64decode(decoded['stdout_base64']),b'hello')
        self.assertEqual(base64.b64decode(decoded['stderr_base64']),b'error')
        with self.assertRaises(a.InvalidObservation):
            a.encode_helper_result(dict(value,stdout=b'x'*32769))
    def test_timeout_unknown_rss_closure_host_and_overflow_invalid(self):
        for name,change in [('timeout',dict(metric=dict(self.metric,elapsed_ns=60000000001))),
                            ('rss',dict(metric=dict(self.metric,peak_rss_bytes=0))),
                            ('signal',dict(metric=dict(self.metric,normal_exit=False,signal=9))),
                            ('output',dict(stdout=b'x'*65537))]:
            with self.subTest(name=name),self.assertRaises(a.InvalidObservation):
                a.verify_observation(dict(self.backend.run(),**change),60,self.backend)
        for verifier in ('verify_closure','verify_host'):
            getattr(self.backend,verifier).return_value=False
            with self.subTest(verifier=verifier),self.assertRaises(a.InvalidObservation):
                a.verify_observation(self.backend.run(),60,self.backend)
            getattr(self.backend,verifier).return_value=True
        self.backend.verify_host.side_effect=RuntimeError('unavailable')
        with self.assertRaises(a.InvalidObservation):a.verify_observation(self.backend.run(),60,self.backend)
    def test_real_entry_refuses_unbound_native_contract(self):
        with self.assertRaises(a.Unavailable):a.create_native_adapter()

    def test_driver_compatible_interface_delegates_and_revalidates(self):
        adapter=a.SupervisedAdapter(self.backend)
        result=adapter.invoke(['/absolute','khc-create'],timeout=60,cwd='/fixed')
        self.assertEqual(result['stdout'],b'ok')
        self.backend.run.assert_called_once_with(command=['/absolute','khc-create'],timeout=60,cwd='/fixed')
        self.backend.verify_closure.assert_called_once();self.backend.verify_host.assert_called_once()
        self.backend.verify_closure.return_value=False
        with self.assertRaises(a.InvalidObservation):adapter.invoke(['/absolute'],timeout=60,cwd='/fixed')

    def test_native_helper_refuses_non_darwin_and_unsupervised_calls(self):
        with mock.patch.object(a.sys,'platform','win32'),self.assertRaises(a.InvalidObservation):
            a.measure_child_in_owned_group(['/bin/example'],'/fixed',{},1,expected_supervisor_pid=2)

    def test_failure_cleanup_kills_and_reaps_the_owned_direct_child(self):
        process=mock.Mock();process.pid=123
        clock=iter((0,1,2))
        with mock.patch.object(a.signal,'SIGKILL',9,create=True),mock.patch.object(a.os,'kill') as kill,\
             mock.patch.object(a.os,'wait4',side_effect=[(0,0,None),(123,9,None)],create=True),\
             mock.patch.object(a.os,'WNOHANG',1,create=True),\
             mock.patch.object(a.os,'waitstatus_to_exitcode',return_value=-9,create=True),\
             mock.patch.object(a.time,'monotonic_ns',side_effect=lambda:next(clock)),mock.patch.object(a.time,'sleep'):
            a.stop_direct_child(process)
        kill.assert_called_once_with(123,9)
        self.assertEqual(process.returncode,-9)

    def test_timeout_preserves_failed_cleanup_as_unknown(self):
        process=mock.Mock();process.pid=123;process.stdout.fileno.return_value=11;process.stderr.fileno.return_value=12
        selector=mock.Mock();clock=iter((0,1000000000))
        with mock.patch.object(a.sys,'platform','darwin'),mock.patch.object(a.os,'getpid',return_value=123),\
             mock.patch.object(a.os,'getppid',return_value=456),mock.patch.object(a.os,'getpgrp',return_value=123,create=True),\
             mock.patch.object(a.os,'getsid',return_value=123,create=True),mock.patch.object(a.os,'wait4',create=True),\
             mock.patch.object(a.os.path,'isabs',return_value=True),mock.patch.object(a.os,'set_blocking'),\
             mock.patch.object(a.subprocess,'Popen',return_value=process),\
             mock.patch.object(a.selectors,'DefaultSelector',return_value=selector),\
             mock.patch.object(a.time,'monotonic_ns',side_effect=lambda:next(clock)),\
             mock.patch.object(a,'stop_direct_child',side_effect=OSError('reap unknown')):
            with self.assertRaises(a.PartialFailure) as caught:
                a.measure_child_in_owned_group(['/bin/example'],'/fixed',{},1,expected_supervisor_pid=456)
        self.assertIn('deadline',str(caught.exception))
        self.assertIn('reap unknown',caught.exception.cleanup_error['message'])

    def test_wait4_helper_calculates_metric_under_supervisor_fixture(self):
        process=mock.Mock();process.pid=123;process.stdout.fileno.return_value=11;process.stderr.fileno.return_value=12
        selector=mock.Mock();selector.select.return_value=[];selector.get_map.return_value={}
        usage=SimpleNamespace(ru_utime=.0005,ru_stime=0.,ru_maxrss=4096)
        clock=iter((0,100,1000000,1000000))
        with mock.patch.object(a.sys,'platform','darwin'),mock.patch.object(a.os,'getpid',return_value=123),\
             mock.patch.object(a.os,'getppid',return_value=456),mock.patch.object(a.os,'getpgrp',return_value=123,create=True),\
             mock.patch.object(a.os.path,'isabs',return_value=True),\
             mock.patch.object(a.os,'getsid',return_value=123,create=True),\
             mock.patch.object(a.os,'wait4',return_value=(123,0,usage),create=True),\
             mock.patch.object(a.os,'WNOHANG',1,create=True),mock.patch.object(a.os,'set_blocking'),\
             mock.patch.object(a.os,'waitstatus_to_exitcode',return_value=0,create=True),\
             mock.patch.object(a.os,'WIFEXITED',return_value=True,create=True),\
             mock.patch.object(a.os,'WEXITSTATUS',return_value=0,create=True),\
             mock.patch.object(a.os,'WIFSIGNALED',return_value=False,create=True),\
             mock.patch.object(a.subprocess,'Popen',return_value=process),\
             mock.patch.object(a.selectors,'DefaultSelector',return_value=selector),\
             mock.patch.object(a.time,'monotonic_ns',side_effect=lambda:next(clock)):
            value=a.measure_child_in_owned_group(['/bin/example'],'/fixed',{},1,expected_supervisor_pid=456)
        self.assertEqual(value['metric']['peak_rss_bytes'],4096)
        self.assertEqual(value['metric']['elapsed_ns'],1000000)
        self.assertEqual(value['metric']['cpu_per_wall'],.5)

    def test_injected_driver_uses_adapter_for_two_supervised_children(self):
        path=Path(__file__).with_name('evaluation.py')
        spec=importlib.util.spec_from_file_location('eval_for_adapter',path)
        evaluation=importlib.util.module_from_spec(spec);spec.loader.exec_module(evaluation)
        adapter=a.SupervisedAdapter(self.backend)
        with mock.patch.object(evaluation,'verify_tree',return_value=evaluation.MANIFEST_CONTENT_SHA),\
             mock.patch.object(evaluation,'archive_record',return_value={'archive_bytes':1,'archive_sha256':'b'*64}),\
             mock.patch.object(evaluation,'compare_archive_bytes'):
            row,raw=evaluation.execute_trial(0,{},adapter)
        self.assertEqual(self.backend.run.call_count,2)
        self.assertEqual(row['encode']['peak_rss_bytes'],4096)
        self.assertEqual(len(raw),2)

    def test_frozen_bridge_requires_complete_closure_and_event_coverage(self):
        fs=mock.Mock();fs.validate_closure.return_value=True
        supervisor=mock.Mock();supervisor.sequence=0;supervisor.process=mock.Mock(pid=123);supervisor._owned_pid=123
        supervisor._owned_process=supervisor.process
        supervisor.last_closure={'pid':123,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
        def run(*_args,**_kwargs):
            supervisor._ops.popen()
            supervisor.sequence+=1
            supervisor.last_closure=dict(supervisor.last_closure,sequence=supervisor.sequence)
            return json.dumps(dict(schema=1,metric=self.metric,
                stdout_base64=base64.b64encode(b'ok').decode(),stderr_base64=''))
        supervisor.run.side_effect=run
        observer=mock.Mock();observer.begin_event.return_value=0
        observer.report.return_value={'captures':[1,2,3,4],'events':[{'id':0}],'completed':False}
        validator=mock.Mock();validator.validate_report.return_value={
            'entry_ready':True,'errors':[],'events':[{'id':0,'state':'covered'}],'eligible':False}
        helper=mock.Mock();helper.verify_identity.return_value=True
        helper.command.return_value=['/absolute/helper']
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),validator,observer,helper,lifecycle,native_begin_ns=100)
        with mock.patch('os.path.isabs',return_value=True),mock.patch.object(a.time,'monotonic_ns',return_value=200):
            result=bridge.run(command=['/fixed/cli'],timeout=60,cwd='/fixed')
        self.assertEqual(result['stdout'],b'ok')
        self.assertEqual(result['closure_proof']['expected_pid'],123)
        self.assertEqual(result['closure_proof']['expected_sequence'],1)
        self.assertTrue(bridge.verify_closure(result['closure_proof']))
        self.assertTrue(bridge.verify_host(result['host_observation']))
        observer.finish_event.assert_called_once_with(0)
        fs.validate_closure.return_value=False
        with mock.patch('os.path.isabs',return_value=True),mock.patch.object(a.time,'monotonic_ns',return_value=200),\
             self.assertRaises(a.BackendFailure) as failure:
            bridge.run(command=['/fixed/cli'],timeout=60,cwd='/fixed')
        self.assertEqual(failure.exception.closure,supervisor.last_closure)

    def test_partial_observer_never_passes_final_campaign(self):
        fs=mock.Mock();supervisor=mock.Mock();validator=mock.Mock();observer=mock.Mock();helper=mock.Mock()
        observer.join.return_value=True;observer.report.return_value={'completed':False,'events':[{}]*48}
        validator.validate_report.return_value={'eligible':False,'errors':[],'events':[],'entry_ready':True}
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),validator,observer,helper,mock.Mock())
        with self.assertRaises(a.InvalidObservation):bridge.finalize_observation(48)

    def test_final_observer_wait_uses_bounded_chunks_under_total_deadline(self):
        observer=mock.Mock();observer.join.side_effect=[False,True]
        observer.report.return_value={'completed':True,'max_captures':240,'cadence_ns':1250000000,
            'events':[{'end_ns':10}]*48,'captures':[{'start_ns':11}]*240}
        validator=mock.Mock();validator.validate_report.return_value={'eligible':True}
        observer.report.return_value['epoch_ns']=100
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),validator,observer,mock.Mock(),mock.Mock(),native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',side_effect=[100,200,300,400]):
            self.assertTrue(bridge.finalize_observation(48)['completed'])
        self.assertTrue(all(call.args[0]<=10 for call in observer.join.call_args_list))

    def test_absolute_deadline_invalid_and_abort_failure_is_preserved(self):
        lifecycle=mock.Mock();lifecycle.abort_observer.side_effect=RuntimeError('abort failed')
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',return_value=317_000_000_100),\
             self.assertRaises(a.BackendFailure) as caught:
            bridge.finish_campaign()
        self.assertEqual([item['phase'] for item in caught.exception.failures],['observer_finalize','observer_abort'])
        self.assertIn('abort failed',caught.exception.failures[1]['message'])
        lifecycle.abort_observer.assert_called_once()

    def test_abort_verifier_must_finish_before_absolute_deadline(self):
        lifecycle=mock.Mock();lifecycle.abort_observer.return_value={'stopped':True}
        lifecycle.verify_observer_abort.return_value=True
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',side_effect=[329_000_000_100,331_000_000_100]):
            cleanup,error=bridge._abort_observer()
        self.assertEqual(cleanup['status'],'unknown');self.assertIsNotNone(error)

    def test_bad_closure_or_oversize_output_always_aborts_observer(self):
        for failure in ('closure','output','output_type'):
            fs=mock.Mock();fs.validate_closure.return_value=failure!='closure'
            supervisor=mock.Mock();supervisor.sequence=0;supervisor.process=mock.Mock(pid=123)
            supervisor._owned_pid=123;supervisor._owned_process=supervisor.process
            supervisor.last_closure={'pid':123,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
            def run(*_args,**_kwargs):
                supervisor._ops.popen()
                supervisor.sequence=1
                return 'x'*131073 if failure=='output' else None if failure=='output_type' else '{}'
            supervisor.run.side_effect=run
            observer=mock.Mock();observer.begin_event.return_value=0
            helper=mock.Mock();helper.verify_identity.return_value=True;helper.command.return_value=['/absolute/helper']
            lifecycle=mock.Mock();lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
            lifecycle.verify_native_clock.return_value=True
            fs.Supervisor.return_value=supervisor
            bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),observer,helper,lifecycle,native_begin_ns=100)
            with self.subTest(failure=failure),mock.patch('os.path.isabs',return_value=True),\
                 mock.patch.object(a.time,'monotonic_ns',return_value=200),self.assertRaises(a.BackendFailure):
                bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
            lifecycle.abort_observer.assert_called_once_with(deadline_ns=330_000_000_100)

    def test_late_join_still_attempts_cleanup_but_never_claims_timely_closure(self):
        lifecycle=mock.Mock();lifecycle.abort_observer.return_value={'stopped':True}
        lifecycle.verify_observer_abort.return_value=True
        observer=mock.Mock();observer.join.return_value=True
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),mock.Mock(),observer,mock.Mock(),lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',side_effect=[316_000_000_100,340_000_000_100,340_000_000_100]),\
             self.assertRaises(a.BackendFailure) as caught:
            bridge.finish_campaign()
        lifecycle.abort_observer.assert_called_once_with(deadline_ns=330_000_000_100)
        self.assertEqual(caught.exception.event['status'],'unknown')

    def test_unexpected_observer_report_error_and_cleanup_are_recorded(self):
        lifecycle=mock.Mock();lifecycle.abort_observer.return_value={'stopped':True}
        lifecycle.verify_observer_abort.return_value=True
        observer=mock.Mock();observer.join.return_value=True;observer.report.side_effect=RuntimeError('report broke')
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),mock.Mock(),observer,mock.Mock(),lifecycle,native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',return_value=200),self.assertRaises(a.BackendFailure) as caught:
            bridge.finish_campaign()
        self.assertIn('report broke',caught.exception.failures[0]['message'])
        self.assertEqual(caught.exception.event['status'],'verified')
        lifecycle.abort_observer.assert_called_once_with(deadline_ns=330_000_000_100)

    def test_event_coverage_does_not_outlive_native_observer_deadline(self):
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),native_begin_ns=100)
        with mock.patch.object(a.time,'monotonic_ns',return_value=317_000_000_100),\
             self.assertRaisesRegex(a.InvalidObservation,'deadline'):bridge._covered(0)
        bridge.observer.report.assert_not_called()

    def test_coverage_failure_requests_abort_with_absolute_closure_deadline(self):
        fs=mock.Mock();fs.validate_closure.return_value=True
        supervisor=mock.Mock();supervisor.sequence=0;supervisor.process=mock.Mock(pid=123)
        supervisor._owned_pid=123;supervisor._owned_process=supervisor.process
        supervisor.last_closure={'pid':123,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
        def run(*_args,**_kwargs):
            supervisor._ops.popen()
            supervisor.sequence=1
            return json.dumps(dict(schema=1,metric=self.metric,stdout_base64='',stderr_base64=''))
        supervisor.run.side_effect=run
        observer=mock.Mock();observer.begin_event.return_value=0
        helper=mock.Mock();helper.verify_identity.return_value=True;helper.command.return_value=['/absolute/helper']
        lifecycle=mock.Mock();lifecycle.abort_observer.return_value={'stopped':True}
        lifecycle.verify_observer_abort.return_value=True;lifecycle.verify_native_clock.return_value=True
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),observer,helper,lifecycle,native_begin_ns=100)
        with mock.patch('os.path.isabs',return_value=True),mock.patch.object(a.time,'monotonic_ns',return_value=200),\
             mock.patch.object(bridge,'_covered',side_effect=a.InvalidObservation('coverage deadline')),\
             self.assertRaises(a.BackendFailure):
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        lifecycle.abort_observer.assert_called_once_with(deadline_ns=330_000_000_100)

    def test_final_observer_rejects_wrong_fixed_capture_count(self):
        validator=mock.Mock();validator.validate_report.return_value={'eligible':True}
        bridge=a.FrozenBackendBridge(mock.Mock(),mock.Mock(),validator,mock.Mock(),mock.Mock(),mock.Mock())
        raw={'completed':True,'max_captures':64,'cadence_ns':1250000000,
             'events':[{'end_ns':10}]*48,'captures':[{'start_ns':11}]*64}
        self.assertFalse(bridge.verify_final_observation(raw))

    def test_independent_pid_sequence_and_normal_exit_are_required(self):
        fs=mock.Mock();fs.validate_closure.return_value=True
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock(),mock.Mock())
        proof=dict(pid=123,sequence=7,primary={'kind':'exit','returncode':0},actual_returncode=0)
        binding=bridge.remember_closure(proof,123,7)
        self.assertTrue(bridge.verify_closure(binding))
        for item in (dict(proof,pid=124),dict(proof,sequence=8),dict(proof,actual_returncode=1),
                     dict(proof,primary={'kind':'timeout','returncode':0})):
            self.assertFalse(bridge.verify_closure(dict(binding,raw=item)))
        self.assertFalse(bridge.verify_closure(dict(binding,expected_pid=124)))
        with self.assertRaises(a.InvalidObservation):bridge.remember_closure(proof,999,7)

    def test_supervisor_and_finish_failures_are_both_retained(self):
        fs=mock.Mock();supervisor=mock.Mock();supervisor.sequence=0;supervisor.run.side_effect=RuntimeError('supervisor failed')
        supervisor.last_closure={'pid':123,'sequence':1};supervisor.last_output=b'partial'
        observer=mock.Mock();observer.begin_event.return_value=0;observer.finish_event.side_effect=RuntimeError('finish failed')
        helper=mock.Mock();helper.verify_identity.return_value=True;helper.command.return_value=['/absolute/helper']
        lifecycle=mock.Mock();lifecycle.verify_native_clock.return_value=True
        lifecycle.abort_observer.return_value={'stopped':True};lifecycle.verify_observer_abort.return_value=True
        fs.Supervisor.return_value=supervisor
        bridge=a.FrozenBackendBridge(fs,mock.Mock(),mock.Mock(),observer,helper,lifecycle,native_begin_ns=100)
        with mock.patch('os.path.isabs',return_value=True),mock.patch.object(a.time,'monotonic_ns',return_value=200),\
             self.assertRaises(a.BackendFailure) as caught:
            bridge.run(command=['/fixed'],timeout=60,cwd='/fixed')
        self.assertEqual([x['phase'] for x in caught.exception.failures],['supervisor','finish_event'])
        self.assertIn('supervisor failed',caught.exception.failures[0]['message'])
        self.assertIn('finish failed',caught.exception.failures[1]['message'])

    def test_unexpected_backend_errors_keep_cause(self):
        adapter=a.SupervisedAdapter(self.backend)
        self.backend.run.side_effect=RuntimeError('unexpected run')
        with self.assertRaises(a.BackendFailure) as caught:adapter.invoke(['/x'],timeout=60,cwd='/fixed')
        self.assertIsInstance(caught.exception.__cause__,RuntimeError)
        self.backend.finish_campaign.side_effect=RuntimeError('unexpected finish')
        with self.assertRaises(a.BackendFailure) as caught:adapter.finish_campaign()
        self.assertIsInstance(caught.exception.__cause__,RuntimeError)
        self.backend.verify_final_observation.side_effect=RuntimeError('unexpected final verifier')
        with self.assertRaises(a.BackendFailure) as caught:adapter.validate_final_observation({})
        self.assertIsInstance(caught.exception.__cause__,RuntimeError)

    def test_bridge_recomputes_frozen_fs_and_observer_evidence(self):
        root=Path(__file__).parent.parent
        def module(name,file):
            spec=importlib.util.spec_from_file_location(name,root/file)
            value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
        fs=module('real_fs','mac-finite-supervisor.py')
        obs=module('real_obs','mac-continuous-cpu-observer.py')
        fixture=module('old_fixture','test-mac-decode-phase-build.py');_,receipt=fixture.fixture()
        captures=[dict(id=i,target_ns=i*obs.CADENCE_NS,start_ns=i*obs.CADENCE_NS,
            end_ns=i*obs.CADENCE_NS+1000000,environment=dict(schema=1,cpu_ticks=[0,0,i*100,0],
            logical_cpus=14,thermal_state=0,ac_power=True)) for i in range(5)]
        raw=dict(schema=1,cadence_ns=obs.CADENCE_NS,max_captures=10,completed=False,failure=None,
            captures=captures,events=[dict(id=0,start_ns=captures[3]['end_ns']+1,end_ns=captures[3]['end_ns']+2)])
        template=fs.Supervisor(Path('.'),mock.Mock())
        bridge=a.FrozenBackendBridge(fs,template,obs,mock.Mock(),mock.Mock(),mock.Mock())
        binding=bridge.remember_closure(receipt['closure_proof'],100,1)
        self.assertTrue(bridge.verify_closure(binding))
        self.assertTrue(bridge.verify_host(dict(event_id=0,report=raw)))
        raw['captures'][4]['environment']['ac_power']=False
        self.assertFalse(bridge.verify_host(dict(event_id=0,report=raw)))

if __name__=='__main__':unittest.main()
