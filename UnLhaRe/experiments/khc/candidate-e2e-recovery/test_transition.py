"""先行失敗条件: 固定binding相違、proof差替え、古い/欠落live、lock喪失、期限不足。

純粋adapter fixtureであり、native fence・実登録・実state変更は行わない。
"""
import copy
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('recovery_transition',Path(__file__).with_name('transition.py'))
T=importlib.util.module_from_spec(spec);spec.loader.exec_module(T)


def fixture():
    binding=T.canonical(T.expected_binding())
    f=T.FENCE
    nodes=[dict(path=p,dev=7,ino=i+1,uid=501,mode=0o700) for i,p in enumerate(f.ANCHOR_PATHS)]
    observation=dict(uid=501,anchors=nodes,pinned=[dict(path=p,dev=7,ino=700+i,uid=501,mode=0o600,sha256=s) for i,(p,s) in enumerate(f.expected_pins().items())],
        absent={p:True for p in f.ABSENT_PATHS if p!=str(f.START)},fence=dict(dev=7,ino=500,uid=501,mode=0o700,empty=True))
    value=dict(schema=1,kind='not-started-observed',old_run_id=f.OLD_RUN,old_endpoint_sha256=f.OLD_ENDPOINT,
        old_protocol_sha256=f.OLD_PROTOCOL,old_worker_sha256=f.OLD_WORKER,fence_controller_sha256=T.FENCE_SHA,
        created_unix_ns=1,windows_binding_sha256=T.sha(binding),raw_sha256=f.RAW,observation=observation,
        past_start_status='unknown',windows_job_status='unknown',third_party_deletion_status='unknown',
        guarantee='fixed-old-endpoint-start-create-blocked-while-fence-intact',fence_path=str(f.START))
    proof=f.canonical(value);ops=mock.Mock();ops.verify.return_value=observation;ops.read_evidence.return_value=proof
    lock=mock.MagicMock();lock.__enter__.return_value=lock;lock.check.return_value=True
    return binding,proof,ops,lock


class Transition(unittest.TestCase):
    def test_binding_requires_real_reader_call_and_is_deterministic(self):
        with mock.patch.object(T.READER,'inspect_evidence',return_value=T.expected_reader_summary()) as read:
            binding=T.build_windows_binding();read.assert_called_once_with()
        self.assertEqual(T.validate_binding(binding),T.expected_binding())
        self.assertEqual(binding,T.canonical(T.expected_binding()))
        bad=T.expected_reader_summary();bad['can_start']=True
        with mock.patch.object(T.READER,'inspect_evidence',return_value=bad),self.assertRaises(T.Refusal):T.build_windows_binding()

    def test_binding_hash_schema_and_old_eight_pins_are_exact(self):
        value=T.expected_binding()
        for key,bad in [('old_run_id','a'*32),('reader_sha256','0'*64),('can_start',True),('unknown',True)]:
            changed=copy.deepcopy(value);changed[key]=bad
            with self.assertRaises(T.Refusal):T.validate_binding(T.canonical(changed))
        raw=T.canonical(value)
        for bad in (raw+b' ',b'{"schema":1,"schema":1}',b'{"value":NaN}'):
            with self.assertRaises(T.Refusal):T.validate_binding(bad)

    def test_fence_content_verification_does_not_grant_live_or_start(self):
        binding,proof,_,_=fixture()
        summary=T.verify_fence_content(binding,proof,T.sha(proof))
        self.assertTrue(summary['content_verified']);self.assertFalse(summary['fence_live_verified'])
        self.assertFalse(summary['can_start']);self.assertFalse(summary['cleanup_allowed'])
        with self.assertRaises(T.Refusal):T.verify_fence_content(binding,proof,'0'*64)
        changed=T.FENCE.parse_evidence(proof);changed['windows_binding_sha256']='0'*64
        bad=T.FENCE.canonical(changed)
        with self.assertRaises((T.Refusal,ValueError)):T.verify_fence_content(binding,bad,T.sha(bad))

    def test_loaded_fence_sha_cannot_reread_changed_source_during_validation(self):
        binding,proof,ops,lock=fixture()
        # ロード後にsourceの内容が変わった状況を注入。旧fence sourceは実際に編集しない。
        with mock.patch.object(T.FENCE.Path,'read_bytes',return_value=b'changed source after load') as disk:
            self.assertEqual(T.FENCE.self_sha(),T.FENCE_SHA)
            value=T.verify_fence_content(binding,proof,T.sha(proof))
            self.assertTrue(value['content_verified']);self.assertFalse(value['can_start'])
            with mock.patch.object(T,'build_windows_binding',return_value=binding):
                draft=T.assess_live_draft(binding,proof,T.sha(proof),live_ops=ops,lock=lock,deadline_ns=400_000_000_000,clock=lambda:0)
            self.assertFalse(draft['can_start']);disk.assert_not_called()
        with mock.patch.object(T.FENCE.Path,'read_bytes',side_effect=OSError('source removed after load')) as disk:
            self.assertEqual(T.FENCE.self_sha(),T.FENCE_SHA)
            T.verify_fence_content(binding,proof,T.sha(proof));disk.assert_not_called()

    def test_live_draft_checks_before_after_lock_deadline_and_windows_evidence(self):
        binding,proof,ops,lock=fixture()
        with mock.patch.object(T,'build_windows_binding',return_value=binding) as windows:
            value=T.assess_live_draft(binding,proof,T.sha(proof),live_ops=ops,lock=lock,deadline_ns=400_000_000_000,clock=lambda:0)
        self.assertEqual(windows.call_count,2);self.assertGreaterEqual(lock.check.call_count,2)
        self.assertEqual(ops.verify.call_count,4)
        self.assertFalse(value['can_start']);self.assertFalse(value['historical_closure_proven'])
        self.assertEqual(value['scope'],'adapter-preconditions-only')
        lock.__exit__.assert_called_once()

    def test_missing_live_lock_deadline_changed_state_and_exceptions_deny(self):
        for failure in ('missing-live','missing-lock','short-deadline','backward-clock','lock-lost','live-changed','windows-changed'):
            binding,proof,ops,lock=fixture();deadline=400_000_000_000;clock=lambda:0
            if failure=='missing-live':ops=None
            if failure=='missing-lock':lock=None
            if failure=='short-deadline':deadline=329_999_999_999
            if failure=='backward-clock':clock=iter([2,1,1,1,1]).__next__
            if failure=='lock-lost':lock.check.side_effect=[True,False]
            if failure=='live-changed':ops.verify.return_value={}
            with self.subTest(failure=failure),mock.patch.object(T,'build_windows_binding',return_value=binding+(b'x' if failure=='windows-changed' else b'')):
                with self.assertRaises((T.Refusal,ValueError)):T.assess_live_draft(binding,proof,T.sha(proof),live_ops=ops,lock=lock,deadline_ns=deadline,clock=clock)
        with self.assertRaises(T.MissingIntegration):T.authorize_new_execution()


if __name__=='__main__':unittest.main()
