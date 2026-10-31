"""失敗条件: lock/容量拒否、marker未保存、closure不明、異常終了、期限超過。"""
import importlib.util
from pathlib import Path
import unittest
import stat
from types import SimpleNamespace
from unittest import mock

spec=importlib.util.spec_from_file_location('fence_launcher',Path(__file__).with_name('fence_launcher.py'))
L=importlib.util.module_from_spec(spec);spec.loader.exec_module(L)

class LauncherTests(unittest.TestCase):
    def fixture(self):
        ops=mock.Mock();ops.acquire.return_value=True;ops.admit.return_value=True
        ops.run.return_value={'marker_sha256':'a'*64,'proof_base64':'cHJvb2Y='}
        ops.closure.return_value={'pid':321,'sequence':1,'primary':{'kind':'exit','returncode':0},'actual_returncode':0}
        ops.validate_closure.return_value=True;ops.validate_result.return_value=True
        return ops

    def test_success_persists_real_closure_and_marker(self):
        ops=self.fixture();result=L.launch(ops,clock=lambda:1,deadline_ns=100)
        self.assertEqual(result['marker_sha256'],'a'*64)
        self.assertEqual(result['closure'],ops.closure.return_value)
        ops.persist.assert_called_once_with(result)
        self.assertEqual([x[0] for x in ops.method_calls],['acquire','admit','run','closure','validate_closure','validate_result','persist','release'])

    def test_rejects_lock_admission_bad_closure_and_bad_result(self):
        for key in ('acquire','admit','validate_closure','validate_result'):
            ops=self.fixture();getattr(ops,key).return_value=False
            with self.subTest(key=key),self.assertRaises(ValueError):L.launch(ops,clock=lambda:1,deadline_ns=100)
            ops.persist.assert_not_called()
            if key in ('acquire','admit'):ops.run.assert_not_called()

    def test_deadline_and_bad_exit_never_persist_success(self):
        ops=self.fixture();ops.closure.return_value['actual_returncode']=1
        with self.assertRaises(ValueError):L.launch(ops,clock=lambda:1,deadline_ns=100)
        ops.persist.assert_not_called()
        ops=self.fixture()
        with self.assertRaises(ValueError):L.launch(ops,clock=lambda:100,deadline_ns=100)
        ops.acquire.assert_not_called()

    def test_native_supervisor_rejects_other_root_or_child_command(self):
        fs=mock.Mock()
        for root,argv in [(Path('/tmp'),['/usr/bin/python3']),
                          (L.ROOT,['/usr/bin/python3','/tmp/script.py','--child'])]:
            with self.subTest(root=root),self.assertRaises(ValueError):
                L.NativeSupervisor(fs,mock.Mock(),mock.Mock(),mock.Mock(),root,argv)
        fs.Supervisor.assert_not_called()

    def test_native_rechecks_marker_bytes_in_live_anchored_directory(self):
        fs=mock.Mock();fence=mock.MagicMock();native=fence.NativeOps.return_value.__enter__.return_value
        native.uid=501;native.handles={str(fence.JOURNAL):7};native._same.return_value=True
        fence.verify_live.return_value={'fence_live_verified':True}
        bridge=mock.Mock();bridge.MARKER='marker';bridge.MARKER_BYTES=b'marker';bridge.BINDING_SHA='b'*64
        supervisor=L.NativeSupervisor(fs,mock.Mock(),fence,bridge,L.ROOT,
            ['/usr/bin/python3',str(L.SCRIPT),'--child'])
        value={'marker_sha256':L.digest(b'marker'),'proof_base64':'cHJvb2Y='}
        info=SimpleNamespace(st_nlink=1,st_uid=501,st_size=6,st_mtime_ns=5,st_mode=stat.S_IFREG|0o600)
        with mock.patch.object(L.os,'O_NOFOLLOW',0,create=True),mock.patch.object(L.os,'O_NONBLOCK',0,create=True),\
             mock.patch.object(L.os,'open',return_value=42),mock.patch.object(L.os,'close'),\
             mock.patch.object(L.os,'fstat',return_value=info),mock.patch.object(L.os,'stat',return_value=info),\
             mock.patch.object(L.os,'lstat',return_value=info),mock.patch.object(L.os,'read',return_value=b'marker'):
            self.assertTrue(supervisor.validate_result(value))
            info.st_mode=stat.S_IFIFO|0o600
            self.assertFalse(supervisor.validate_result(value))

    def test_finite_supervisor_rechecks_deadline_after_admission_before_spawn(self):
        fs=mock.Mock();native=fs.Supervisor.return_value;original=mock.Mock();native._ops=original
        native.run.side_effect=lambda *_a,**_kw:native._ops.popen('child')
        bridge=L.NativeSupervisor(fs,mock.Mock(),mock.Mock(),mock.Mock(),L.ROOT,
            ['/usr/bin/python3',str(L.SCRIPT),'--child'])
        with mock.patch.object(L.time,'monotonic_ns',side_effect=[0,40_000_000_000]),self.assertRaises(ValueError):
            bridge.run(40_000_000_000)
        original.popen.assert_not_called()
        self.assertIs(native._ops,original)

    def test_spawn_rejects_when_full_child_timeout_no_longer_fits(self):
        fs=mock.Mock();native=fs.Supervisor.return_value;original=mock.Mock();native._ops=original
        native.run.side_effect=lambda *_a,**_kw:native._ops.popen('child')
        bridge=L.NativeSupervisor(fs,mock.Mock(),mock.Mock(),mock.Mock(),L.ROOT,
            ['/usr/bin/python3',str(L.SCRIPT),'--child'])
        with mock.patch.object(L.time,'monotonic_ns',side_effect=[0,2_000_000_000]),self.assertRaises(ValueError):
            bridge.run(40_000_000_000)
        original.popen.assert_not_called()

    def test_failure_and_post_persistence_timeout_are_durable(self):
        ops=self.fixture();ops.run.side_effect=ValueError('child failed')
        with self.assertRaises(ValueError):L.launch(ops,clock=lambda:1,deadline_ns=100)
        ops.persist_failure.assert_called_once()
        ops=self.fixture();times=iter([1,2,3,4,5,6,100])
        with self.assertRaises(ValueError):L.launch(ops,clock=lambda:next(times),deadline_ns=100)
        ops.persist_failure.assert_called_once()
        self.assertFalse(ops.persist.call_args.args[0]['eligible'])

    def test_failure_record_persistence_error_preserves_original_cause(self):
        ops=self.fixture();ops.run.side_effect=ValueError('child failed')
        ops.persist_failure.side_effect=OSError('disk failed')
        with self.assertRaises(RuntimeError) as caught:L.launch(ops,clock=lambda:1,deadline_ns=100)
        self.assertIn('disk failed',str(caught.exception))
        self.assertIsInstance(caught.exception.__cause__,ValueError)
        self.assertIn('child failed',str(caught.exception.__cause__))

    def test_loader_executes_only_the_verified_open_handle_bytes(self):
        data=b'value=17\n';info=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_nlink=1,st_uid=501,
            st_dev=7,st_ino=22,st_size=len(data),st_mtime_ns=5)
        for expected,accepted in [(L.digest(data),True),('0'*64,False)]:
            with self.subTest(accepted=accepted),mock.patch.object(L.os,'O_NOFOLLOW',0,create=True),\
                 mock.patch.object(L.os,'O_NONBLOCK',0,create=True),mock.patch.object(L.os,'getuid',return_value=501,create=True),\
                 mock.patch.object(L.os,'open',return_value=42),mock.patch.object(L.os,'close'),\
                 mock.patch.object(L.os,'fstat',return_value=info),mock.patch.object(L.os,'lstat',return_value=info),\
                 mock.patch.object(L.os,'read',side_effect=[data,b'']):
                if accepted:self.assertEqual(L.load_pinned(Path('/fixed'),expected,'fixture').value,17)
                else:
                    with self.assertRaises(ValueError):L.load_pinned(Path('/fixed'),expected,'fixture')

    def test_child_spawn_receives_held_lock_and_absolute_deadline(self):
        fs=mock.Mock();native=fs.Supervisor.return_value;original=mock.Mock();native._ops=original
        native.run.side_effect=lambda *_a,**_kw:native._ops.popen('child',env={}) or '{}'
        original.popen.return_value='{}\n'
        bridge=L.NativeSupervisor(fs,mock.Mock(),mock.Mock(),mock.Mock(),L.ROOT,
            ['/usr/bin/python3',str(L.SCRIPT),'--child']);bridge.lock_fd=44
        with mock.patch.object(L.time,'monotonic_ns',side_effect=[0,1]):bridge.run(50_000_000_000)
        args=original.popen.call_args.kwargs
        self.assertEqual(args['pass_fds'],(44,));self.assertEqual(args['env']['KHC_FENCE_LOCK_FD'],'44')
        self.assertEqual(args['env']['KHC_FENCE_DEADLINE_NS'],'50000000000')

    def test_child_rejects_missing_or_invalid_inherited_lock(self):
        for env in ({},{'KHC_FENCE_LOCK_FD':'-1','KHC_FENCE_DEADLINE_NS':'100'},
                    {'KHC_FENCE_LOCK_FD':'5','KHC_FENCE_DEADLINE_NS':'invalid'}):
            with self.subTest(env=env),self.assertRaises(ValueError):L.child_credentials(env,clock=lambda:0)

    def test_child_deadline_leaves_thirteen_seconds_for_closure(self):
        with mock.patch.object(L,'verify_inherited_lock') as verify:
            fd,deadline=L.child_credentials({'KHC_FENCE_LOCK_FD':'5','KHC_FENCE_DEADLINE_NS':'30000000000'},clock=lambda:1)
        self.assertEqual((fd,deadline),(5,17_000_000_000));verify.assert_called_once_with(5)

    def test_child_wire_rejects_duplicate_fields_and_noncanonical_json(self):
        for data in ('{"x":1,"x":1}\n','{"x": 1}\n','{"x":1}'):
            with self.subTest(data=data),self.assertRaises(ValueError):L.parse_wire(data)
        self.assertEqual(L.parse_wire('{"x":1}\n'),{'x':1})

    def test_native_entries_refuse_before_any_side_effect_without_lifecycle(self):
        for argv in ([],['--child']):
            with self.subTest(argv=argv),mock.patch.object(L.platform,'system',return_value='Darwin'),\
                 mock.patch.object(L.platform,'machine',return_value='arm64'),\
                 mock.patch.object(L,'SCRIPT',Path(L.__file__).absolute()),\
                 mock.patch.object(L.os,'umask') as umask,mock.patch.object(L,'dependencies') as deps,\
                 mock.patch.object(L,'child_credentials') as creds, self.assertRaisesRegex(ValueError,'lifecycle'):
                L.main(argv)
            umask.assert_not_called();deps.assert_not_called();creds.assert_not_called()

    def test_flock_on_arbitrary_new_descriptor_is_not_parent_authentication(self):
        import sys,types
        info=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_nlink=1,st_dev=7,st_ino=8)
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,flock=mock.Mock())
        with mock.patch.dict(sys.modules,{'fcntl':fake}),mock.patch.object(L.os,'fstat',return_value=info),\
             mock.patch.object(L.os,'lstat',return_value=info),mock.patch.object(L.os,'getuid',return_value=501,create=True),\
             mock.patch.object(L.os,'getppid',return_value=300):
            self.assertIsNone(L.verify_inherited_lock(5))
        fake.flock.assert_called_once()

    def test_acquire_releases_fd_when_anchor_context_exit_fails(self):
        import sys,types
        fs=mock.Mock();fence=mock.MagicMock();anchor=fence.NativeOps.return_value.__enter__.return_value
        anchor.capture.return_value={'anchors':[]};anchor.handles={str(fence.JOURNAL):7};anchor._same.return_value=True
        fence.NativeOps.return_value.__exit__.side_effect=OSError('close failed')
        obj=L.NativeSupervisor(fs,mock.Mock(),fence,mock.Mock(),L.ROOT,['/usr/bin/python3',str(L.SCRIPT),'--child'])
        info=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_uid=501,st_nlink=1)
        fake=types.SimpleNamespace(LOCK_EX=1,LOCK_NB=2,flock=lambda *_:None)
        with mock.patch.dict(sys.modules,{'fcntl':fake}),mock.patch.object(L.os,'O_NOFOLLOW',0,create=True),\
             mock.patch.object(L.os,'open',return_value=42),mock.patch.object(L.os,'close') as close,\
             mock.patch.object(L.os,'getuid',return_value=501,create=True),mock.patch.object(L.os,'fsync'),\
             mock.patch.object(L.os,'fstat',return_value=info),mock.patch.object(L.os,'stat',return_value=info),\
             mock.patch.object(L.os,'lstat',return_value=info),self.assertRaises(OSError):obj.acquire()
        close.assert_called_once_with(42);self.assertIsNone(obj.lock_fd)

if __name__=='__main__':unittest.main()
