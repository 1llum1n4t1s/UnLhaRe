#!/usr/bin/env python3
"""Mac診断用の容量snapshot。一回のROOT走査でordinary/Cargo/固定TARGETを集計。

TARGET内の消失や安全属性を保ったmetadata変化はpass全体を破棄する。
最大3passと同processのmonotonic deadlineで制限し、部分値を返さない。
走査による入場制御であり、OSのatomic snapshotや書込hard quotaではない。
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import time

ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
TARGET_RELATIVE=Path('cargo-target/decode-phase-20261027')
MAX_ATTEMPTS=3
ORDINARY_MAX=1610612736
CARGO_MAX=1073741824
TOTAL_MAX=2684354560
TARGET_MAX=536870912
BOOTSTRAP_RESERVE=1048576
SETUP_SHA='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'


class SnapshotError(RuntimeError):
    pass


class _TargetRace(Exception):
    def __init__(self,path,reason):
        self.path=path;self.reason=reason
        super().__init__(reason+': '+str(path))


def require(ok,message):
    if not ok:raise SnapshotError(message)


def setup_dependency_path(module_file=None):
    location=Path(module_file) if module_file is not None else Path(__file__).absolute()
    if location.parent==ROOT/'tools':
        return Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    return location.with_name('mac-native-setup.py')


def _load_setup():
    path=setup_dependency_path()
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=131072,'frozen setup type/bound')
    require(hashlib.sha256(path.read_bytes()).hexdigest()==SETUP_SHA,'frozen setup SHA')
    spec=importlib.util.spec_from_file_location('diagnostic_snapshot_frozen_setup',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module


SETUP=_load_setup()


class NativeOps:
    def getuid(self):return os.getuid()
    def lstat(self,path):return Path(path).lstat()
    def walk(self,root,onerror):return os.walk(root,followlinks=False,onerror=onerror)


def _deadline(deadline_ns,clock):
    now=clock()
    require(type(now) is int and now<deadline_ns,'snapshot monotonic deadline exceeded')
    return now


def _inside_target(path,target):
    try:
        value=Path(path)
        return value.is_absolute() and '..' not in value.parts and target in value.parents
    except (TypeError,ValueError):return False


def _object(info,uid,*,root=False):
    require(not stat.S_ISLNK(info.st_mode) and
        not getattr(info,'st_file_attributes',0)&getattr(stat,'FILE_ATTRIBUTE_REPARSE_POINT',1024),
        'snapshot symlink/reparse point')
    require(info.st_uid==uid and not info.st_mode&0o022,'snapshot owner or writable object')
    require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode),'snapshot special object')
    if root:
        require(stat.S_ISDIR(info.st_mode) and not info.st_mode&0o077,'snapshot root must be private owned directory')
    if stat.S_ISREG(info.st_mode):
        require(type(info.st_nlink) is int and info.st_nlink>=1 and type(info.st_size) is int and info.st_size>=0,
            'snapshot file size/link metadata')


def _fingerprint(info):
    return info.st_dev,info.st_ino,info.st_nlink,info.st_size,info.st_uid,info.st_mode


def _once(root,target,ops,uid,deadline_ns,clock):
    def observe(path):
        _deadline(deadline_ns,clock)
        try:info=ops.lstat(path)
        except FileNotFoundError as error:
            if _inside_target(path,target):raise _TargetRace(path,'target-entry-disappeared') from error
            raise SnapshotError('object disappeared outside fixed TARGET: '+str(path)) from error
        _deadline(deadline_ns,clock)
        _object(info,uid)
        return info
    _deadline(deadline_ns,clock)
    try:root_info=ops.lstat(root)
    except OSError as error:raise SnapshotError('snapshot root unavailable') from error
    _object(root_info,uid,root=True)
    ordinary=cargo=target_total=0
    entries=1;rows=[];observed={}
    def walk_error(error):
        name=getattr(error,'filename',None)
        if isinstance(error,FileNotFoundError) and _inside_target(name,target):
            raise _TargetRace(Path(name),'target-directory-disappeared') from error
        raise SnapshotError('snapshot walk failed outside transient policy: '+str(error)) from error
    for directory,dirs,files in ops.walk(root,onerror=walk_error):
        _deadline(deadline_ns,clock)
        for name in dirs+files:
            path=Path(directory)/name
            require(root in path.parents and '..' not in path.parts,'walk escaped snapshot ROOT')
            info=observe(path);entries+=1
            if stat.S_ISREG(info.st_mode):
                require(path not in observed,'duplicate snapshot path')
                category=path.relative_to(root).parts[0]
                rows.append((str(path),(info.st_dev,info.st_ino),info.st_nlink,info.st_size,category))
                observed[path]=info
                if category in ('cargo-home','cargo-target'):cargo+=info.st_size
                else:ordinary+=info.st_size
                if target in path.parents:target_total+=info.st_size
                require(ordinary<=ORDINARY_MAX and cargo<=CARGO_MAX and ordinary+cargo<=TOTAL_MAX and
                    target_total<=TARGET_MAX,'observed snapshot capacity exceeded')
    # 全regular fileを再確認。TARGETのinode/size/nlink変化もpass全体を無効にする。
    # owner/type/permissionの異常はobserveが先に拒否し、retryで隠さない。
    for path,previous in observed.items():
        current=observe(path)
        if _fingerprint(current)!=_fingerprint(previous):
            if _inside_target(path,target):
                revised_target=target_total-previous.st_size+current.st_size
                revised_cargo=cargo-previous.st_size+current.st_size
                require(revised_target<=TARGET_MAX and revised_cargo<=CARGO_MAX and
                    ordinary+revised_cargo<=TOTAL_MAX,'observed recheck capacity exceeded')
                raise _TargetRace(path,'target-metadata-changed')
            raise SnapshotError('immutable object changed outside fixed TARGET: '+str(path))
    try:SETUP.validate_link_groups(rows)
    except SETUP.Refusal as error:raise SnapshotError('hardlink consistency: '+str(error)) from error
    final_root=observe(root);_object(final_root,uid,root=True)
    require((final_root.st_dev,final_root.st_ino,final_root.st_uid,final_root.st_mode)==
        (root_info.st_dev,root_info.st_ino,root_info.st_uid,root_info.st_mode),'snapshot root identity changed')
    finished=_deadline(deadline_ns,clock)
    return dict(schema=1,root=root.as_posix(),target=target.as_posix(),ordinary_bytes=ordinary,
        cargo_bytes=cargo,target_bytes=target_total,entries=entries,finished_ns=finished)


def snapshot(root=ROOT,*,deadline_ns,ops=None,clock=time.monotonic_ns):
    require(type(deadline_ns) is int and deadline_ns>0,'absolute monotonic deadline required')
    root=Path(root)
    require(root.is_absolute() and '..' not in root.parts,'absolute normalized snapshot ROOT required')
    target=root/TARGET_RELATIVE;ops=ops or NativeOps();uid=ops.getuid()
    require(type(uid) is int and uid>=0,'snapshot expected UID')
    started=_deadline(deadline_ns,clock);invalidated=[]
    for attempt in range(1,MAX_ATTEMPTS+1):
        try:
            value=_once(root,target,ops,uid,deadline_ns,clock)
            value.update(attempts=attempt,invalidated_snapshots=invalidated,started_ns=started)
            _deadline(deadline_ns,clock)
            return value
        except _TargetRace as error:
            invalidated.append(dict(attempt=attempt,reason=error.reason,path=str(error.path)[:512]))
            if attempt==MAX_ATTEMPTS:
                raise SnapshotError('fixed TARGET snapshot unavailable after %d complete attempts: %s'%(attempt,error)) from error
            _deadline(deadline_ns,clock)
        except SnapshotError:raise
        except OSError as error:raise SnapshotError('snapshot I/O failure: '+str(error)) from error
    raise SnapshotError('snapshot retry bound')


def validate_admission(value,*,extra_ordinary,free_bytes):
    require(type(value) is dict and value.get('schema')==1,'snapshot admission object')
    values=[value.get(k) for k in ('ordinary_bytes','cargo_bytes','target_bytes')]+[extra_ordinary,free_bytes]
    require(all(type(n) is int and n>=0 for n in values),'snapshot admission integer values')
    ordinary,cargo,target,extra,free=values
    ordinary+=BOOTSTRAP_RESERVE
    require(target<=TARGET_MAX and target<=cargo,'fixed TARGET cap/accounting')
    remaining=TARGET_MAX-target
    # cargoとtargetは同じ走査の同じstat列。TARGET残骸の寄与を二重予約しない。
    require(ordinary+extra<=ORDINARY_MAX and cargo+remaining<=CARGO_MAX and
        ordinary+cargo+extra+remaining<=TOTAL_MAX,'global ordinary/Cargo/total reservation')
    require(free>=5*1024**3+extra+remaining,'snapshot free space reserve')
    return dict(ordinary_bytes=ordinary,cargo_bytes=cargo,target_bytes=target,
        remaining_target_reserve_bytes=remaining,ordinary_extra_bytes=extra)
