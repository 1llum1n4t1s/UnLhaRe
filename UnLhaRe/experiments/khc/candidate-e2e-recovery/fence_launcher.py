"""固定 fence の有限監督と closure 記録。Windows 側の認可は別途必要。"""
import base64
import hashlib
import json
import os
import stat
import time
import types
import sys
import platform
from pathlib import Path

ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
SCRIPT=ROOT/'tools/mac-cdf-e2e-fence-launcher.py'
FENCE_SHA='d0e055cab949bd9d22c1a329698a9a27f5f58bc994fff33b67182c6b65974c46'
BRIDGE_SHA='d3e7b9e60167fc97549e36a5124e8054e68de46e0d87923c3f9d8883b89ba7c5'
FS_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
SETUP_SHA='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
LOCK=ROOT/'journal/mac-cdf-e2e-fence-supervisor.lock'

def require(value,message):
    if not value:raise ValueError(message)

def launch(ops,*,deadline_ns,clock=time.monotonic_ns):
    require(type(deadline_ns) is int and deadline_ns>0,'deadline')
    last=-1
    def check():
        nonlocal last
        now=clock();require(type(now) is int and last<=now<deadline_ns,'deadline/clock');last=now
    check();held=False;attempted=False
    try:
        require(ops.acquire() is True,'lock unavailable');held=True;check()
        require(ops.admit() is True,'capacity unavailable');check()
        attempted=True;child=ops.run(deadline_ns);check()
        closure=ops.closure()
        require(type(closure) is dict and type(closure.get('pid')) is int and
            type(closure.get('sequence')) is int and closure.get('primary',{}).get('kind')=='exit' and
            closure['primary'].get('returncode')==0 and closure.get('actual_returncode')==0,'child did not exit normally')
        require(ops.validate_closure(closure) is True,'closure not proven');check()
        require(ops.validate_result(child) is True,'marker/proof invalid');check()
        result=dict(schema=1,kind='fence-supervised-observation',eligible=False,marker_sha256=child['marker_sha256'],
            proof_base64=child['proof_base64'],closure=closure)
        ops.persist(result);check()
        return result
    except BaseException as error:
        if attempted:
            try:
                try:closure=ops.closure()
                except BaseException:closure=None
                ops.persist_failure(dict(schema=1,kind='fence-supervised-failure',eligible=False,
                    error_type=type(error).__name__,error=str(error)[:2048],closure=closure))
            except BaseException as persistence_error:
                raise RuntimeError('failure evidence persistence failed: '+str(persistence_error)[:2048]) from error
        raise
    finally:
        if held:ops.release()

def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def digest(value):return hashlib.sha256(value).hexdigest()

def parse_wire(data):
    require(type(data) is str and len(data)<=131072,'wire bound')
    def pairs(values):
        result={}
        for key,value in values:
            require(key not in result,'duplicate wire key');result[key]=value
        return result
    value=json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
    require(type(value) is dict and canonical(value)==data.encode('utf-8'),'canonical wire')
    return value

def load_pinned(path,expected,name):
    flags=os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK
    fd=os.open(str(path),flags)
    try:
        before=os.fstat(fd);named=os.lstat(str(path))
        identity=lambda s:(s.st_dev,s.st_ino,s.st_uid,s.st_mode,s.st_nlink,s.st_size,s.st_mtime_ns)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and before.st_uid in (0,os.getuid()) and
            not before.st_mode&0o022 and 0<before.st_size<=131072 and identity(before)==identity(named),'dependency type/path')
        chunks=[];size=0
        while True:
            chunk=os.read(fd,65536)
            if not chunk:break
            size+=len(chunk);require(size<=131072,'dependency bound');chunks.append(chunk)
        after=os.fstat(fd);named=os.lstat(str(path));data=b''.join(chunks)
        require(identity(before)==identity(after)==identity(named) and size==before.st_size and
            digest(data)==expected,'dependency changed/SHA')
    finally:os.close(fd)
    module=types.ModuleType(name);module.__file__=str(path)
    exec(compile(data,str(path),'exec'),module.__dict__)
    return module

def verify_inherited_lock(fd):
    """FD と path の一致・flock 取得だけを確認し、親の所有や登録認証は証明しない。"""
    import fcntl
    a=os.fstat(fd);b=os.lstat(str(LOCK))
    identity=lambda s:(s.st_dev,s.st_ino,s.st_uid,s.st_mode,s.st_nlink)
    require(stat.S_ISREG(a.st_mode) and stat.S_IMODE(a.st_mode)==0o600 and a.st_uid==os.getuid() and
        a.st_nlink==1 and identity(a)==identity(b) and os.getppid()>1,'inherited lock identity')
    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)

def child_credentials(env,*,clock=time.monotonic_ns):
    fd=env.get('KHC_FENCE_LOCK_FD','');deadline=env.get('KHC_FENCE_DEADLINE_NS','')
    require(type(fd) is str and fd.isascii() and fd.isdecimal() and len(fd)<=8 and
        type(deadline) is str and deadline.isascii() and deadline.isdecimal() and len(deadline)<=20,'child credentials')
    fd=int(fd);deadline=int(deadline)-13_000_000_000
    require(fd>=3 and clock()<deadline,'child deadline/lock')
    verify_inherited_lock(fd)
    return fd,deadline

def dependencies():
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load_pinned(setup_path,SETUP_SHA,'fence_setup');setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT,private=True);setup.checked_path(ROOT/'journal',private=True)
    fs=load_pinned(ROOT/'tools/mac-finite-supervisor.py',FS_SHA,'fence_fs')
    fence=load_pinned(ROOT/'tools/mac-cdf-e2e-not-started-fence.py',FENCE_SHA,'fence_native')
    fence.self_sha=lambda:FENCE_SHA
    bridge=load_pinned(ROOT/'tools/mac-cdf-e2e-fence-bridge.py',BRIDGE_SHA,'fence_bridge_native')
    return fs,setup,fence,bridge

def main(argv):
    # 外側のWindows binding・amendment・登録を認証するlifecycleは未接続。
    # flockの取得は親が保有していた証拠にならないため、両入口とも副作用前に拒否。
    raise ValueError('native lifecycle authorization is not connected')

class NativeSupervisor:
    """既存 FS と検証済 dependency を持つ native 呼出元からのみ構築する。"""
    def __init__(self,fs,setup,fence,bridge,root,child_argv):
        require(root==ROOT and child_argv==['/usr/bin/python3',str(SCRIPT),'--child'],'fixed root/child command')
        self.fs=fs;self.setup=setup;self.fence=fence;self.bridge=bridge;self.root=root
        self.child_argv=child_argv;self.lock_fd=None;self.supervisor=fs.Supervisor(root,setup)
    def acquire(self):
        import fcntl,stat
        self.setup.admit(self.root,2*1024*1024)
        fd=None
        try:
          with self.fence.NativeOps() as anchors:
            anchors.capture();journal=anchors.handles[str(self.fence.JOURNAL)]
            fd=os.open('mac-cdf-e2e-fence-supervisor.lock',os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600,dir_fd=journal)
            try:
                info=os.fstat(fd);named=os.stat('mac-cdf-e2e-fence-supervisor.lock',dir_fd=journal,follow_symlinks=False)
                absolute=os.lstat(str(self.fence.JOURNAL/'mac-cdf-e2e-fence-supervisor.lock'))
                require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and info.st_nlink==1 and
                    stat.S_IMODE(info.st_mode)==0o600 and anchors._same(info,named) and
                    anchors._same(named,absolute),'lock identity')
                fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);os.fsync(journal)
            except BaseException:raise
          self.lock_fd=fd;fd=None
        finally:
            if fd is not None:os.close(fd)
        return True
    def admit(self):self.setup.admit(self.root,2*1024*1024);return True
    def run(self,deadline_ns):
        remaining=(deadline_ns-time.monotonic_ns())/1e9
        require(remaining>14,'closure reserve')
        child_timeout=min(30,remaining-14)
        original=self.supervisor._ops
        class Guard:
            def __getattr__(self,name):return getattr(original,name)
            def popen(self,*args,**kwargs):
                require(time.monotonic_ns()+int(child_timeout*1e9)+13_000_000_000<=deadline_ns,
                    'spawn deadline/child timeout/closure reserve')
                require(type(self_owner.lock_fd) is int and self_owner.lock_fd>=0,'held lock required')
                kwargs['pass_fds']=(self_owner.lock_fd,)
                env=dict(kwargs.get('env') or {});env['KHC_FENCE_LOCK_FD']=str(self_owner.lock_fd)
                env['KHC_FENCE_DEADLINE_NS']=str(deadline_ns);kwargs['env']=env
                return original.popen(*args,**kwargs)
        self_owner=self
        self.supervisor._ops=Guard()
        try:output=self.supervisor.run(self.child_argv,timeout=child_timeout,cwd=self.root)
        finally:self.supervisor._ops=original
        return parse_wire(output)
    def closure(self):return self.supervisor.last_closure
    def validate_closure(self,value):
        return (self.supervisor._owned_pid==value['pid'] and self.supervisor.sequence==value['sequence'] and
            self.fs.validate_closure(value,self.supervisor._owned_pid,self.supervisor.sequence))
    def validate_result(self,value):
        if type(value) is not dict or set(value)!={'marker_sha256','proof_base64'}:return False
        if value['marker_sha256']!=digest(self.bridge.MARKER_BYTES):return False
        try:
            proof=base64.b64decode(value['proof_base64'],validate=True)
            with self.fence.NativeOps() as ops:
                if self.fence.verify_live(ops,proof,self.bridge.BINDING_SHA)['fence_live_verified'] is not True:return False
                journal=ops.handles[str(self.fence.JOURNAL)]
                fd=os.open(self.bridge.MARKER,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=journal)
                try:
                    a=os.fstat(fd);b=os.stat(self.bridge.MARKER,dir_fd=journal,follow_symlinks=False)
                    c=os.lstat(str(self.fence.JOURNAL/self.bridge.MARKER))
                    raw=os.read(fd,len(self.bridge.MARKER_BYTES)+1);d=os.fstat(fd)
                    return (stat.S_ISREG(a.st_mode) and stat.S_IMODE(a.st_mode)==0o600 and
                        ops._same(a,b) and ops._same(b,c) and ops._same(c,d) and a.st_nlink==1 and
                        a.st_uid==ops.uid and a.st_size==len(raw) and a.st_mtime_ns==d.st_mtime_ns and
                        raw==self.bridge.MARKER_BYTES)
                finally:os.close(fd)
        except (OSError,ValueError,KeyError,TypeError):return False
    def persist(self,value):self._persist('mac-cdf-e2e-fence-supervised.json',value)
    def persist_failure(self,value):self._persist('mac-cdf-e2e-fence-supervised-failure.json',value)
    def _persist(self,name,value):
        data=canonical(value);require(len(data)<=131072,'receipt bound')
        with self.fence.NativeOps() as ops:
            ops._anchors(first=True);journal=ops.handles[str(self.fence.JOURNAL)]
            fd=os.open(name,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=journal)
            try:
                view=memoryview(data)
                while view:
                    n=os.write(fd,view);require(n>0,'receipt write');view=view[n:]
                os.fsync(fd);os.fsync(journal)
                a=os.fstat(fd);b=os.stat(name,dir_fd=journal,follow_symlinks=False)
                c=os.lstat(str(self.fence.JOURNAL/name))
                require(ops._same(a,b) and ops._same(b,c) and a.st_nlink==1 and a.st_size==len(data),'receipt identity')
            finally:os.close(fd)
    def release(self):
        if self.lock_fd is not None:os.close(self.lock_fd);self.lock_fd=None

if __name__=='__main__':main(sys.argv[1:])
