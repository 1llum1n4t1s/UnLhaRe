"""Pure tests; no CLI, Cargo, remote connection, storage ledger or filesystem output.

Failures first: missing/changed manifest or files, unexpected entry/link/overwrite,
incomplete witness/source/build proof or observer, wrong order/count, exit/signal,
unknown group closure/timeout, incomplete observations, excessive resource use,
changed archive bytes and any fixed performance threshold violation.
"""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest import mock
import os
import stat
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('evaluation',Path(__file__).with_name('evaluation.py'))
e=importlib.util.module_from_spec(spec);spec.loader.exec_module(e)

class EvaluationTests(unittest.TestCase):
    def test_archive_growth_is_bounded_and_invalid(self):
        entry=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_nlink=1,st_size=4,
                              st_dev=7,st_ino=8,st_mtime_ns=1)
        def growing(_fd,count):
            if count>4:raise AssertionError('unbounded read request')
            return b'x'*count
        with mock.patch.object(os,'O_NOFOLLOW',0x400000,create=True),\
             mock.patch.object(os,'O_NONBLOCK',0x800000,create=True),\
             mock.patch.object(os,'getuid',return_value=501,create=True),\
             mock.patch('os.open',side_effect=[11,12]),mock.patch('os.fstat',return_value=entry),\
             mock.patch('os.lstat',return_value=entry),mock.patch('os.close'),mock.patch('os.read',side_effect=growing) as read:
            with self.assertRaises(e.InvalidRun):e.compare_archive_bytes('/a','/b',lambda _:None)
            self.assertLessEqual(read.call_count,4)

    def test_archive_fixed_size_comparison_and_short_reads(self):
        entry=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_nlink=1,st_size=4,
                              st_dev=7,st_ino=8,st_mtime_ns=1)
        def run(streams):
            def read(fd,count):
                data=streams[fd];chunk=data[:min(count,2)];streams[fd]=data[len(chunk):];return chunk
            with mock.patch.object(os,'O_NOFOLLOW',0x400000,create=True),\
                 mock.patch.object(os,'O_NONBLOCK',0x800000,create=True),\
                 mock.patch.object(os,'getuid',return_value=501,create=True),\
                 mock.patch('os.open',side_effect=[11,12]),mock.patch('os.fstat',return_value=entry),\
                 mock.patch('os.lstat',return_value=entry),mock.patch('os.close'),mock.patch('os.read',side_effect=read):
                return e.compare_archive_bytes('/a','/b',lambda _:None)
        self.assertIsNone(run({11:b'abcd',12:b'abcd'}))
        with self.assertRaises(e.Rejected):run({11:b'abcd',12:b'abce'})
        with self.assertRaises(e.InvalidRun):run({11:b'ab',12:b'abcd'})
        with self.assertRaises(e.InvalidRun):run({11:b'abcd',12:b'abcde'})
    def test_real_manifest_exact_hash_and_eleven_records(self):
        path=Path('D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-canterbury-input-manifest.json')
        data=path.read_bytes();self.assertEqual(len(e.validate_manifest(data)['entries']),11)
        with self.assertRaises(ValueError):e.validate_manifest(data+b' ')

    def test_exact_fixed_order_and_command(self):
        schedule=e.schedule();self.assertEqual(len(schedule),22)
        self.assertEqual([s['order'] for s in schedule[2::2]],['AB','BA','BA','AB','AB','BA','BA','AB','AB','BA'])
        self.assertEqual(e.commands('A','/source','/archive','/out')[0][1:],
            ['khc-create','/archive','--source','/source','--strategy','portfolio-trial'])

    def test_decision_thresholds_are_not_relaxed(self):
        rows=fixture();result=e.assess(rows)
        self.assertEqual(result['decision'],'eligible-for-integration')
        rows=fixture()
        for row in (rows[3],rows[4]):row['decode'].update(elapsed_ns=1000,user_seconds=.0000005)
        self.assertEqual(e.assess(rows)['decision'],'rejected')
        rows=fixture();rows[2]['decode']['peak_rss_bytes']=134217729
        self.assertEqual(e.assess(rows)['decision'],'rejected')
        rows=fixture()
        for row in rows[2:]:
            if row['order']=='BA' and row['letter']=='B':row['decode'].update(elapsed_ns=960,user_seconds=.00000048)
        self.assertEqual(e.assess(rows)['decision'],'rejected')
        rows=fixture()
        for row in rows[2:]:
            if row['letter']=='B':row['encode'].update(elapsed_ns=1060,user_seconds=.00000053)
        self.assertEqual(e.assess(rows)['decision'],'rejected')
        rows=fixture();rows[3]['decode']['peak_rss_bytes']=12097153
        self.assertEqual(e.assess(rows)['decision'],'rejected')
        rows=fixture();rows[2]['decode']['normal_exit']=False
        with self.assertRaises(e.InvalidRun):e.assess(rows)
        rows=fixture();rows[2]['closure_verified']=False
        with self.assertRaises(e.InvalidRun):e.assess(rows)
        rows=fixture();rows[2]['archive_sha256']='b'*64
        with self.assertRaises(e.Rejected):e.assess(rows)

    def test_native_execution_closed_without_integration(self):
        with self.assertRaises(e.IntegrationUnavailable):e.run_native()

    def test_resource_caps_include_old_targets_and_reservations(self):
        e.validate_resource_budget(100,423285284,20,536870912,0,6*1024**3)
        for args in ((1610612736,1,1,0,0,6*1024**3),(1,1073741824,0,1,0,6*1024**3),
                     (1,1,0,0,3221225471,6*1024**3),(1,1,1,1,0,5*1024**3)):
            with self.subTest(args=args),self.assertRaises(ValueError):e.validate_resource_budget(*args)

    def test_injected_driver_runs_create_then_extract_and_checks_outputs(self):
        adapter=mock.Mock()
        metric=dict(elapsed_ns=1000,peak_rss_bytes=10000,normal_exit=True,exit_code=0,signal=None,
                    user_seconds=.0000005,system_seconds=0.,cpu_per_wall=.5)
        observation=dict(metric=metric,closure_proof={'closed':True},host_observation={'eligible':True},
                         stdout=b'normal',stderr=b'')
        adapter.invoke.return_value=observation
        adapter.validate_closure.return_value=True;adapter.validate_host.return_value=True
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA) as tree,\
             mock.patch.object(e,'archive_record',return_value=dict(archive_bytes=123,archive_sha256='b'*64)),\
             mock.patch.object(e,'compare_archive_bytes') as compare:
            row,raw=e.execute_trial(0,{},adapter)
        self.assertEqual([x.args[0][1] for x in adapter.invoke.call_args_list],['khc-create','khc-extract'])
        self.assertEqual([x.kwargs['timeout'] for x in adapter.invoke.call_args_list],[60,20])
        self.assertEqual([x.kwargs['cwd'] for x in adapter.invoke.call_args_list],[e.trial_paths(0)[0]]*2)
        self.assertEqual(tree.call_count,3);self.assertEqual(adapter.require_unused.call_count,2)
        self.assertEqual(adapter.verify_binary.call_count,2)
        self.assertEqual(compare.call_count,11)
        self.assertEqual(row['archive_sha256'],'b'*64);self.assertEqual(len(raw),2)
        adapter.validate_closure.return_value=False
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),self.assertRaises(e.InvalidRun):
            e.execute_trial(0,{},adapter)

    def test_preflight_then_22_fixed_trials_no_retry(self):
        manifest=Path('D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-canterbury-input-manifest.json').read_bytes()
        adapter=mock.Mock();adapter.verify_preflight.return_value=True
        adapter.validate_closure.return_value=True;adapter.validate_host.return_value=True
        adapter.finish_campaign.return_value={'completed':True};adapter.validate_final_observation.return_value=True
        metric=dict(elapsed_ns=1000,peak_rss_bytes=10000,normal_exit=True,exit_code=0,signal=None,
                    user_seconds=.0000005,system_seconds=0.,cpu_per_wall=.5)
        adapter.invoke.return_value=dict(metric=metric,closure_proof={'closed':True},
            host_observation={'eligible':True},stdout=b'',stderr=b'')
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),\
             mock.patch.object(e,'archive_record',return_value=dict(archive_bytes=123,archive_sha256='b'*64)),\
             mock.patch.object(e,'compare_archive_bytes') as compare:
            result=e.evaluate_injected(manifest,{'proof':'fixture'},adapter)
        self.assertEqual(len(result['preflight']),2);self.assertEqual(len(result['trials']),22)
        self.assertEqual(adapter.invoke.call_count,48)
        self.assertEqual(compare.call_count,24*11+23)
        self.assertEqual(result['decision']['decision'],'rejected')
        adapter.finish_campaign.return_value={'completed':False}
        adapter.validate_final_observation.return_value=False
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),\
             mock.patch.object(e,'archive_record',return_value=dict(archive_bytes=123,archive_sha256='b'*64)),\
             mock.patch.object(e,'compare_archive_bytes'),self.assertRaises(e.InvalidRun):
            e.evaluate_injected(manifest,{'proof':'fixture'},adapter)
        adapter.reset_mock();adapter.verify_preflight.return_value=False
        with self.assertRaises(e.InvalidRun):e.evaluate_injected(manifest,{},adapter)
        adapter.invoke.assert_not_called()

    def test_unexpected_backend_failure_has_recordable_original_cause(self):
        manifest=Path('D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-canterbury-input-manifest.json').read_bytes()
        adapter=mock.Mock();adapter.verify_preflight.return_value=True
        adapter.invoke.side_effect=RuntimeError('backend vanished')
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),self.assertRaises(e.InvalidRun) as caught:
            e.evaluate_injected(manifest,{},adapter)
        self.assertIsInstance(caught.exception.__cause__,RuntimeError)
        self.assertIn('backend vanished',caught.exception.failure_record['message'])
        spec=importlib.util.spec_from_file_location('adapter_failure_fixture',Path(__file__).with_name('process_adapter.py'))
        process_adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(process_adapter)
        adapter.invoke.side_effect=process_adapter.BackendFailure('two failures',closure={'pid':3},output=b'partial',
            failures=[{'phase':'supervisor','type':'RuntimeError','message':'first'},
                      {'phase':'finish_event','type':'RuntimeError','message':'second'}])
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),self.assertRaises(e.InvalidRun) as caught:
            e.evaluate_injected(manifest,{},adapter)
        self.assertEqual(len(caught.exception.failure_record['failures']),2)
        self.assertEqual(caught.exception.failure_record['closure'],{'pid':3})
        self.assertEqual(caught.exception.failure_record['output_base64'],'cGFydGlhbA==')

    def test_adapter_reused_objects_cannot_change_saved_trial(self):
        adapter=mock.Mock();adapter.validate_closure.return_value=True;adapter.validate_host.return_value=True
        metric=dict(elapsed_ns=1000,peak_rss_bytes=10000,normal_exit=True,exit_code=0,signal=None,
                    user_seconds=.0000005,system_seconds=0.,cpu_per_wall=.5)
        proof={'nested':{'pid':1}};host={'nested':{'thermal':0}}
        observation=dict(metric=metric,closure_proof=proof,host_observation=host,stdout=b'',stderr=b'')
        adapter.invoke.return_value=observation
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),\
             mock.patch.object(e,'archive_record',return_value=dict(archive_bytes=123,archive_sha256='b'*64)),\
             mock.patch.object(e,'compare_archive_bytes'):
            row,raw=e.execute_trial(0,{},adapter)
        metric['elapsed_ns']=9;proof['nested']['pid']=2;host['nested']['thermal']=3
        self.assertEqual(row['encode']['elapsed_ns'],1000)
        self.assertEqual(raw[0]['metric']['elapsed_ns'],1000)
        self.assertEqual(raw[0]['closure_proof']['nested']['pid'],1)
        self.assertEqual(raw[0]['host_observation']['nested']['thermal'],0)
        metric.update(elapsed_ns=1000,user_seconds=.0000005);proof['nested']['pid']=1;host['nested']['thermal']=0
        counter=[0]
        def reused(*_args,**_kwargs):
            counter[0]+=1
            if counter[0]==2:
                metric.update(elapsed_ns=900,user_seconds=.00000045);proof['nested']['pid']=2;host['nested']['thermal']=1
            return observation
        adapter.invoke.side_effect=reused
        with mock.patch.object(e,'verify_tree',return_value=e.MANIFEST_CONTENT_SHA),\
             mock.patch.object(e,'archive_record',return_value=dict(archive_bytes=123,archive_sha256='b'*64)),\
             mock.patch.object(e,'compare_archive_bytes'):
            row,raw=e.execute_trial(0,{},adapter)
        self.assertEqual((row['encode']['elapsed_ns'],row['decode']['elapsed_ns']),(1000,900))
        self.assertEqual((raw[0]['closure_proof']['nested']['pid'],raw[1]['closure_proof']['nested']['pid']),(1,2))

    def test_input_unavailable_is_invalid_but_restore_mismatch_rejects(self):
        adapter=mock.Mock();adapter.validate_closure.return_value=True;adapter.validate_host.return_value=True
        metric=dict(elapsed_ns=1000,peak_rss_bytes=10000,normal_exit=True,exit_code=0,signal=None,
                    user_seconds=.0000005,system_seconds=0.,cpu_per_wall=.5)
        adapter.invoke.return_value=dict(metric=metric,closure_proof={},host_observation={},stdout=b'',stderr=b'')
        with mock.patch.object(e,'verify_tree',side_effect=ValueError('source missing')),self.assertRaises(e.InvalidRun):
            e.execute_trial(0,{},adapter)
        with mock.patch.object(e,'verify_tree',side_effect=[e.MANIFEST_CONTENT_SHA,e.MANIFEST_CONTENT_SHA,
                                                           ValueError('restored bytes differ')]),\
             self.assertRaises(e.Rejected):e.execute_trial(0,{},adapter)

def fixture():
    out=[]
    for s in e.schedule():
        elapsed=1000 if s['letter']=='A' else 900
        metric=dict(elapsed_ns=elapsed,peak_rss_bytes=10000000,normal_exit=True,exit_code=0,signal=None,
                    user_seconds=elapsed*.5/1e9,system_seconds=0.,cpu_per_wall=0.5)
        out.append(dict(**s,encode=dict(metric),decode=dict(metric),archive_bytes=100,
            archive_sha256='a'*64,restored_manifest_sha256=e.MANIFEST_CONTENT_SHA,
            closure_verified=True,host_eligible=True,host_evidence_sha256='c'*64))
    return out

if __name__=='__main__':unittest.main()
