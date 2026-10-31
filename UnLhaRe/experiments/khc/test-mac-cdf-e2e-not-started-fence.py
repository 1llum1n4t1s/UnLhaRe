#!/usr/bin/env python3
"""Fence failures first: no real mkdir, Mac access, SSH or ledger mutation.

Refuse old start/RUN/terminal/closure of any type, wrong identity/mode/device,
symlink/path swap, mkdir EEXIST, nonempty or replaced fence, failure to fsync,
ambiguous receipt or unknown dependency. Never erase a created fence. Past
deletion and Windows Job closure remain unknown, never inferred from absence.
"""
import importlib.util
import copy
import os
import stat
import unittest
from pathlib import Path
from unittest import mock

spec=importlib.util.spec_from_file_location('fence',Path(__file__).with_name('mac-cdf-e2e-not-started-fence.py'))
fence=importlib.util.module_from_spec(spec);spec.loader.exec_module(fence)

class FenceTests(unittest.TestCase):
    def setUp(self):
        nodes=[dict(path=path,dev=7,ino=i+1,uid=501,mode=448) for i,path in enumerate(fence.ANCHOR_PATHS)]
        pinned=[dict(path=path,dev=7,ino=700+i,uid=501,mode=0o600,sha256=sha)
                for i,(path,sha) in enumerate(fence.expected_pins().items())]
        self.before=dict(uid=501,anchors=nodes,pinned=pinned,absent={name:True for name in fence.ABSENT_PATHS})
        self.after=dict(self.before,absent={p:True for p in fence.ABSENT_PATHS if p!=str(fence.START)},
                        fence=dict(dev=7,ino=500,uid=501,mode=448,empty=True))
    def ops(self):
        value=mock.Mock();value.capture.return_value=self.before;value.verify.return_value=self.after
        return value
    def test_fixture_fence_is_durable_and_does_not_claim_history(self):
        ops=self.ops()
        value=fence.create_fence(ops,'a'*64)
        fence.validate_evidence(value,'a'*64)
        self.assertNotIn(str(fence.START),value['observation']['absent'])
        ambiguous=copy.deepcopy(value);ambiguous['observation']['absent'][str(fence.START)]=True
        with self.assertRaises(ValueError):fence.validate_evidence(ambiguous,'a'*64)
        self.assertEqual(value['past_start_status'],'unknown')
        self.assertEqual(value['windows_job_status'],'unknown')
        ops.create_exclusive.assert_called_once()
        ops.sync.assert_called_once()
        ops.verify.assert_called_once()

    def test_exclusive_collision_and_sync_failure_never_remove(self):
        for point,error in [('create_exclusive',FileExistsError('collision')),('sync',OSError('sync')),
                            ('persist',OSError('evidence fsync'))]:
            ops=self.ops()
            getattr(ops,point).side_effect=error
            with self.assertRaises(type(error)):fence.create_fence(ops,'a'*64)
            self.assertFalse(hasattr(ops,'remove') and ops.remove.called)

    def test_receipt_ambiguous_or_tampered_identity_rejected(self):
        ops=self.ops()
        value=fence.create_fence(ops,'a'*64)
        for key,change in [('past_start_status','never'),('windows_job_status','closed'),
                           ('old_run_id','0'*32),('old_endpoint_sha256','0'*64)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                fence.validate_evidence(dict(value,**{key:change}),'a'*64)

    def test_path_swap_or_nonempty_rejected(self):
        for key,bad in [('ino',0),('uid',0),('mode',0o777),('dev',99),('empty',False)]:
            ops=self.ops();changed=copy.deepcopy(self.after);changed['fence'][key]=bad;ops.verify.return_value=changed
            with self.subTest(key=key),self.assertRaises(ValueError):fence.create_fence(ops,'a'*64)
        for key,bad in [('ino',999),('uid',0),('mode',0o777),('path','/elsewhere')]:
            ops=self.ops();changed=copy.deepcopy(self.after);changed['anchors'][-2][key]=bad;ops.verify.return_value=changed
            with self.subTest(key=key),self.assertRaises(ValueError):fence.create_fence(ops,'a'*64)
        for path in fence.ABSENT_PATHS:
            ops=self.ops();changed=copy.deepcopy(self.before);changed['absent'][path]=False;ops.capture.return_value=changed
            with self.subTest(path=path),self.assertRaises(ValueError):fence.create_fence(ops,'a'*64)
            ops.create_exclusive.assert_not_called()

    def test_live_fence_recheck_and_ambiguity(self):
        ops=self.ops();value=fence.create_fence(ops,'a'*64);raw=fence.canonical(value)
        self.assertFalse(fence.validate_evidence(value,'a'*64)['fence_live_verified'])
        ops.read_evidence.return_value=raw
        self.assertTrue(fence.verify_live(ops,raw,'a'*64)['fence_live_verified'])
        altered=copy.deepcopy(self.after);altered['fence']['ino']+=1;ops.verify.return_value=altered
        with self.assertRaises(ValueError):fence.verify_live(ops,raw,'a'*64)
        with self.assertRaises(ValueError):fence.parse_evidence(b'{"a":1,"a":1}\n')

    def test_native_type_and_rename_are_rejected(self):
        def entry(mode,ino=500):return os.stat_result((mode,ino,7,2,501,20,0,0,0,0))
        good=entry(stat.S_IFDIR|0o700)
        with self.assertRaises(ValueError):fence.NativeOps._identity(fence.START,entry(stat.S_IFLNK|0o700))
        n=object.__new__(fence.NativeOps);n.uid=501;n.handles={str(fence.JOURNAL):5};n.fence_fd=6
        n._anchors=mock.Mock(return_value=self.before['anchors']);n._other_absent=mock.Mock(return_value=self.after['absent'])
        with mock.patch('os.fstat',return_value=good),mock.patch('os.stat',return_value=entry(stat.S_IFDIR|0o700,501)),\
                mock.patch('os.lstat',return_value=good):
            with self.assertRaises(ValueError):n.verify(self.before)
        with mock.patch('os.fsync',side_effect=OSError('directory sync unavailable')) as sync:
            with self.assertRaises(OSError):n.sync()
            sync.assert_called_once_with(6)

    def test_native_mkdir_eexist_has_no_fallback(self):
        n=object.__new__(fence.NativeOps);n.before=self.before;n.handles={str(fence.JOURNAL):5};n.fence_fd=None
        with mock.patch('os.mkdir',side_effect=FileExistsError('occupied')) as mkdir,mock.patch('os.open') as opened:
            with self.assertRaises(FileExistsError):n.create_exclusive()
        mkdir.assert_called_once_with(fence.START.name,0o700,dir_fd=5)
        opened.assert_not_called()

    def test_absence_rejects_any_type_and_other_errors(self):
        for mode in (stat.S_IFDIR,stat.S_IFREG,stat.S_IFLNK,stat.S_IFIFO):
            value=os.stat_result((mode|0o600,2,7,1,501,20,0,0,0,0))
            with self.subTest(mode=mode),mock.patch('os.stat',return_value=value):
                self.assertFalse(fence.NativeOps._absent(5,'old'))
        with mock.patch('os.stat',side_effect=PermissionError('denied')):
            with self.assertRaises(PermissionError):fence.NativeOps._absent(5,'old')

    def test_fifo_open_is_nonblocking_before_regular_file_check(self):
        n=object.__new__(fence.NativeOps);n.uid=501;n.handles={str(fence.JOURNAL):5,str(fence.TOOLS):7}
        fifo=os.stat_result((stat.S_IFIFO|0o600,2,7,1,501,20,0,0,0,0))
        with mock.patch.object(os,'O_NOFOLLOW',0x400000,create=True),mock.patch.object(os,'O_NONBLOCK',0x800000,create=True),\
                mock.patch('os.open',return_value=6) as opened,mock.patch('os.fstat',return_value=fifo),\
                mock.patch('os.stat',return_value=fifo),mock.patch('os.lstat',return_value=fifo),\
                mock.patch('os.close'),mock.patch('os.read') as read:
            with self.assertRaises(ValueError):n._pinned()
            self.assertTrue(opened.call_args.args[1]&os.O_NONBLOCK)
            read.assert_not_called()
        with mock.patch.object(os,'O_NOFOLLOW',0x400000,create=True),mock.patch.object(os,'O_NONBLOCK',0x800000,create=True),\
                mock.patch('os.open',return_value=6) as opened,mock.patch('os.fstat',return_value=fifo),\
                mock.patch('os.stat',return_value=fifo),mock.patch('os.lstat',return_value=fifo),\
                mock.patch('os.close'),mock.patch('os.read') as read:
            with self.assertRaises(ValueError):n.read_evidence()
            self.assertTrue(opened.call_args.args[1]&os.O_NONBLOCK)
            read.assert_not_called()

if __name__=='__main__':unittest.main()
