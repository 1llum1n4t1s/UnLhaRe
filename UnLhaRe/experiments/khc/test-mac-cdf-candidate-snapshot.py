"""先行条件: 一時消失の全破棄、外部消失・属性違反拒否、hardlink、期限と容量。

実fixtureの列挙・サイズ・inode・hardlink・rename消失を使う。Windowsでは
uid/Unix modeだけをMac相当へ注入し、その拒否条件を別々に検証する。
削除・Cargo・SSH・本番ROOT操作は行わず、fixtureは親のPrunlet清掃まで保持する。
"""
import errno
import importlib.util
import json
import os
import re
from pathlib import Path
import stat
import sys
import types
import unittest
import uuid

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('diagnostic_snapshot',HERE/'mac-cdf-candidate-snapshot.py')
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)
ARENA=None


def fixture_path(parent,identifier):
    if type(identifier) is not str or re.fullmatch('[0-9a-f]{32}',identifier) is None:
        raise ValueError('KHC_CDF_SNAPSHOT_FIXTURE_ID must be a fresh lowercase 32-hex identifier')
    return parent/('cdf-candidate-snapshot-tests-'+identifier)


def checked(path):
    require=unittest.TestCase().assertTrue
    require(path.is_absolute())
    for item in [path]+list(path.parents):
        if not item.exists():continue
        info=item.lstat()
        require(not stat.S_ISLNK(info.st_mode))
        require(not getattr(info,'st_file_attributes',0)&getattr(stat,'FILE_ATTRIBUTE_REPARSE_POINT',1024))
    if ARENA is not None:require(path==ARENA or ARENA in path.parents)
    return path


class MacOps:
    def __init__(self):self.hook=None;self.overrides={};self.walks=0;self.calls={}
    def getuid(self):return 501
    def walk(self,root,onerror):
        self.walks+=1
        yield from os.walk(root,followlinks=False,onerror=onerror)
    def lstat(self,path):
        path=Path(path);self.calls[path]=self.calls.get(path,0)+1
        if self.hook:self.hook(path,self.calls[path])
        real=path.lstat()
        row=dict(st_dev=real.st_dev,st_ino=real.st_ino,st_nlink=real.st_nlink,st_size=real.st_size,
            st_uid=501,st_mode=stat.S_IFMT(real.st_mode)|(0o700 if path.is_dir() else 0o600),
            st_file_attributes=getattr(real,'st_file_attributes',0))
        row.update(self.overrides.get(path,{}))
        return types.SimpleNamespace(**row)


class SetupLocation(unittest.TestCase):
    def test_fixed_native_install_uses_bootstrap_and_checkout_uses_adjacent(self):
        native=M.ROOT/'tools/mac-cdf-candidate-snapshot.py'
        self.assertEqual(M.setup_dependency_path(native),Path(str(M.ROOT)+'-bootstrap')/'mac-native-setup.py')
        self.assertEqual(M.setup_dependency_path(HERE/'mac-cdf-candidate-snapshot.py'),HERE/'mac-native-setup.py')

    def test_fixture_identifier_is_explicit_and_cannot_escape(self):
        parent=Path('D:/Claude/UnLhaRe/goal-restore-20261019')
        self.assertEqual(fixture_path(parent,'a'*32),parent/('cdf-candidate-snapshot-tests-'+'a'*32))
        for name in ('','a'*31,'A'*32,'../outside'):
            with self.assertRaises(ValueError):fixture_path(parent,name)


class Snapshot(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ARENA
        if ARENA is not None:return
        parent=Path('D:/Claude/UnLhaRe/goal-restore-20261019')
        checked(parent);cls.assertTrue(cls,parent.is_dir() and os.access(parent,os.W_OK))
        ARENA=fixture_path(parent,os.environ.get('KHC_CDF_SNAPSHOT_FIXTURE_ID',uuid.uuid4().hex))
        checked(ARENA);ARENA.mkdir(mode=0o700)

    def setUp(self):
        self.root=checked(ARENA/self._testMethodName);self.root.mkdir(mode=0o700)
        self.target=self.root/'cargo-target/cdf-chooser-candidate-20261027'
        for directory in (self.target,self.root/'source',self.root/'cargo-home'):
            checked(directory);directory.mkdir(parents=True,mode=0o700,exist_ok=True)
        for path,body in ((self.root/'source/input.rs',b'plain'),(self.root/'cargo-home/cache',b'abc'),(self.target/'leaf.o',b'x'*11)):
            checked(path)
            with path.open('xb') as stream:stream.write(body)
        self.ops=MacOps()

    def scan(self,**kwargs):return M.snapshot(self.root,deadline_ns=10**30,ops=self.ops,**kwargs)
    def move(self,old,new):checked(old);checked(new);old.rename(new)

    def test_single_walk_counts_ordinary_cargo_target_residue(self):
        value=self.scan()
        self.assertEqual((value['ordinary_bytes'],value['cargo_bytes'],value['target_bytes']),(5,14,11))
        self.assertEqual(self.ops.walks,1);self.assertEqual(value['attempts'],1)

    def test_real_target_disappearance_discards_entire_pass(self):
        old=self.target/'leaf.o';new=self.target/'renamed.o';done=[]
        def hook(path,count):
            if path==old and not done:done.append(True);self.move(old,new)
        self.ops.hook=hook
        value=self.scan()
        self.assertEqual(value['attempts'],2);self.assertEqual(self.ops.walks,2)
        self.assertEqual((value['ordinary_bytes'],value['cargo_bytes'],value['target_bytes']),(5,14,11))
        self.assertEqual(len(value['invalidated_snapshots']),1)
        self.assertFalse(old.exists());self.assertTrue(new.exists())

    def test_repeated_real_disappearance_is_finite(self):
        old=self.target/'leaf.o';self.move(old,self.target/'vanishing-0.o')
        def hook(path,count):
            if path.name.startswith('vanishing-'):
                index=int(path.stem.split('-')[1]);self.move(path,path.with_name('vanishing-%d.o'%(index+1)))
        self.ops.hook=hook
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,M.MAX_ATTEMPTS)

    def test_real_disappearance_outside_target_is_not_retried(self):
        old=self.root/'source/input.rs';new=self.root/'source/held.rs'
        self.ops.hook=lambda path,count:self.move(old,new) if path==old else None
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_root_owner_privacy_and_object_attributes_are_strict(self):
        leaf=self.target/'leaf.o'
        for path,change in ((self.root,dict(st_uid=0)),(self.root,dict(st_mode=stat.S_IFDIR|0o755)),
            (leaf,dict(st_uid=0)),(leaf,dict(st_mode=stat.S_IFREG|0o622)),
            (leaf,dict(st_mode=stat.S_IFLNK|0o600)),(leaf,dict(st_mode=stat.S_IFIFO|0o600)),
            (leaf,dict(st_file_attributes=1024))):
            self.ops=MacOps();self.ops.overrides[path]=change
            with self.subTest(change=change),self.assertRaises(M.SnapshotError):self.scan()

    def test_real_cargo_hardlinks_all_aliases_are_charged(self):
        alias=checked(self.target/'alias.o');os.link(self.target/'leaf.o',alias)
        value=self.scan()
        self.assertEqual((value['cargo_bytes'],value['target_bytes']),(25,22))

    def test_cross_category_and_external_hardlinks_are_rejected(self):
        alias=checked(self.root/'cargo-home/alias.o');os.link(self.target/'leaf.o',alias)
        with self.assertRaises(M.SnapshotError):self.scan()

    def test_external_alias_is_rejected(self):
        alias=checked(ARENA/'external-alias.o');os.link(self.target/'leaf.o',alias)
        with self.assertRaises(M.SnapshotError):self.scan()

    def test_ordinary_hardlink_is_rejected(self):
        alias=checked(self.root/'source/alias.rs');os.link(self.root/'source/input.rs',alias)
        with self.assertRaises(M.SnapshotError):self.scan()

    def test_real_hardlink_publication_invalidates_then_recaptures(self):
        leaf=self.target/'leaf.o';alias=checked(self.target/'published.o');done=[]
        def hook(path,count):
            if path==leaf and count==2 and not done:done.append(True);os.link(leaf,alias)
        self.ops.hook=hook
        value=self.scan()
        self.assertEqual(value['attempts'],2)
        self.assertEqual((value['cargo_bytes'],value['target_bytes']),(25,22))

    def test_changed_target_size_is_retried_but_source_change_is_rejected(self):
        leaf=self.target/'leaf.o';done=[]
        def hook(path,count):
            if path==leaf and count==2 and not done:
                done.append(True)
                with checked(leaf).open('ab') as stream:stream.write(b'changed')
        self.ops.hook=hook
        value=self.scan();self.assertEqual(value['attempts'],2);self.assertEqual(value['target_bytes'],18)
        source=self.root/'source/input.rs';self.ops=MacOps()
        def source_hook(path,count):
            if path==source and count==2:
                with checked(source).open('ab') as stream:stream.write(b'changed')
        self.ops.hook=source_hook
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_observed_target_excess_never_becomes_a_retry(self):
        self.ops.overrides[self.target/'leaf.o']=dict(st_size=536870913)
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_recheck_target_excess_is_rejected_before_retry(self):
        leaf=self.target/'leaf.o'
        def hook(path,count):
            if path==leaf and count==2:self.ops.overrides[leaf]=dict(st_size=536870913)
        self.ops.hook=hook
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_deadline_is_checked_during_scan(self):
        with self.assertRaises(M.SnapshotError):M.snapshot(self.root,deadline_ns=3,ops=self.ops,clock=iter(range(100)).__next__)
        self.assertLessEqual(self.ops.walks,1)

    def test_admission_uses_same_snapshot_and_counts_failed_target_residue(self):
        value=dict(self.scan(),ordinary_bytes=710149592-1048576,cargo_bytes=271009833,target_bytes=15664326)
        admitted=M.validate_admission(value,extra_ordinary=65536,free_bytes=8*1024**3)
        self.assertEqual(admitted['ordinary_bytes'],710149592)
        self.assertEqual(admitted['remaining_target_reserve_bytes'],536870912-15664326)
        for key,number in (('cargo_bytes',1073741824),('target_bytes',536870913),('ordinary_bytes',1610612736)):
            with self.subTest(key=key),self.assertRaises(M.SnapshotError):
                M.validate_admission(dict(value,**{key:number}),extra_ordinary=65536,free_bytes=8*1024**3)


class CandidateBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if ARENA is None:Snapshot.setUpClass()
    setUp = Snapshot.setUp
    scan = Snapshot.scan
    move = Snapshot.move
    # 継承された同じ安全条件を、新旧target共存fixtureでも必要な境界で再検証する。
    def add_old_target(self):
        old=checked(self.root/'cargo-target/decode-phase-20261027')
        old.mkdir(mode=0o700)
        leaf=checked(old/'retained.o')
        with leaf.open('xb') as stream:stream.write(b'r'*17)
        return leaf

    def test_old_and_candidate_actual_one_walk_and_only_candidate_reserve(self):
        self.add_old_target()
        value=self.scan()
        self.assertEqual((value['ordinary_bytes'],value['cargo_bytes'],value['target_bytes']),(5,31,11))
        self.assertEqual(value['target'],(self.root/M.TARGET_RELATIVE).as_posix())
        self.assertEqual(self.ops.walks,1)
        admitted=M.validate_admission(value,extra_ordinary=19,free_bytes=8*1024**3)
        self.assertEqual(admitted['remaining_target_reserve_bytes'],536870901)
        self.assertEqual(admitted['cargo_bytes']+admitted['remaining_target_reserve_bytes'],536870932)

    def test_old_target_disappearance_does_not_retry(self):
        leaf=self.add_old_target();held=leaf.with_name('held.o');done=[]
        def hook(path,count):
            if path==leaf and not done:done.append(True);self.move(leaf,held)
        self.ops.hook=hook
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_old_target_metadata_change_does_not_retry(self):
        leaf=self.add_old_target()
        def hook(path,count):
            if path==leaf and count==2:
                with checked(leaf).open('ab') as stream:stream.write(b'changed')
        self.ops.hook=hook
        with self.assertRaises(M.SnapshotError):self.scan()
        self.assertEqual(self.ops.walks,1)

    def test_hardlink_aliases_across_targets_are_all_charged(self):
        leaf=self.add_old_target();alias=checked(self.target/'old-alias.o')
        os.link(leaf,alias)
        value=self.scan()
        self.assertEqual((value['cargo_bytes'],value['target_bytes']),(48,28))
        admitted=M.validate_admission(value,extra_ordinary=0,free_bytes=8*1024**3)
        self.assertEqual(admitted['remaining_target_reserve_bytes'],536870884)

    def test_candidate_reservation_free_floor_and_cargo_cap_are_strict(self):
        self.add_old_target();value=self.scan();remaining=M.TARGET_MAX-value['target_bytes']
        with self.assertRaises(M.SnapshotError):
            M.validate_admission(value,extra_ordinary=7,free_bytes=5*1024**3+7+remaining-1)
        with self.assertRaises(M.SnapshotError):
            M.validate_admission(dict(value,cargo_bytes=M.CARGO_MAX-remaining+1),extra_ordinary=0,free_bytes=8*1024**3)

    def test_only_fixed_target_differs_from_frozen_source(self):
        frozen=(HERE/'mac-diagnostic-storage-snapshot.py').read_bytes()
        import hashlib
        self.assertEqual(hashlib.sha256(frozen).hexdigest(),'b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806')
        self.assertEqual(frozen.count(b"TARGET_RELATIVE=Path('cargo-target/decode-phase-20261027')"),1)
        expected=frozen.replace(b"TARGET_RELATIVE=Path('cargo-target/decode-phase-20261027')",b"TARGET_RELATIVE=Path('cargo-target/cdf-chooser-candidate-20261027')",1)
        self.assertEqual((HERE/'mac-cdf-candidate-snapshot.py').read_bytes(),expected)


if __name__=='__main__':
    result=unittest.main(exit=False).result
    if ARENA is not None:
        items=list(ARENA.rglob('*'));size=sum(p.stat().st_size for p in items if p.is_file())
        print(json.dumps(dict(fixture_root=str(ARENA),entries=len(items)+1,bytes=size,retained=True,unix_owner_mode='injected on Windows; file I/O and links real')))
        if size>262144 or len(items)+1>192:raise RuntimeError('fixture retention bound exceeded')
    sys.exit(0 if result.wasSuccessful() else 1)
