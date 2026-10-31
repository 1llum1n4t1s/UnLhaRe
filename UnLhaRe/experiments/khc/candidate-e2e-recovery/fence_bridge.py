"""固定 fence の one-shot 操作部。呼出元は実 lock と有限 supervisor を保持する。"""
import os
import stat
import time

BINDING_SHA='af044113e2f841728f8da01095b3ae6bdeb7018b7f1730046f88129ba0596a9f'
MARKER='mac-cdf-e2e-fence-attempt.started.json'
MARKER_BYTES=b'{"binding_sha256":"af044113e2f841728f8da01095b3ae6bdeb7018b7f1730046f88129ba0596a9f","schema":1}\n'

def require(condition,message):
    if not condition:raise ValueError(message)

def perform(ops,*,deadline_ns,clock=time.monotonic_ns):
    require(type(deadline_ns) is int and deadline_ns>0,'deadline')
    previous=-1
    def check():
        nonlocal previous
        now=clock();require(type(now) is int and previous<=now<deadline_ns,'deadline/clock')
        previous=now
    check();ops.marker();check()
    proof=ops.create();check()
    require(type(proof) is bytes and 0<len(proof)<=65536,'proof bounds')
    value=ops.verify(proof);check()
    require(type(value) is dict and value.get('fence_live_verified') is True,'live fence')
    return proof

class NativeFenceOps:
    """NativeOps の固定 dirfd と CreateNew/fsync を用いる。失敗後の marker は保持。"""
    def __init__(self,fence):self.fence=fence
    def marker(self):
        f=self.fence
        with f.NativeOps() as ops:
            anchors=ops.capture()['anchors']
            journal=ops.handles[str(f.JOURNAL)]
            fd=os.open(MARKER,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,dir_fd=journal)
            try:
                info=os.fstat(fd)
                require(stat.S_ISREG(info.st_mode) and info.st_uid==ops.uid and info.st_nlink==1 and
                    stat.S_IMODE(info.st_mode)==0o600,'marker ownership/type')
                written=0
                while written<len(MARKER_BYTES):
                    count=os.write(fd,MARKER_BYTES[written:]);require(count>0,'marker write');written+=count
                os.fsync(fd);os.fsync(journal)
                named=os.stat(MARKER,dir_fd=journal,follow_symlinks=False)
                absolute=os.lstat(str(f.JOURNAL/MARKER))
                require(ops._same(info,named) and ops._same(named,absolute) and named.st_nlink==1 and
                    named.st_size==len(MARKER_BYTES) and ops._anchors()==anchors,'marker identity')
            finally:os.close(fd)
    def create(self):
        with self.fence.NativeOps() as ops:
            return self.fence.canonical(self.fence.create_fence(ops,BINDING_SHA))
    def verify(self,proof):
        with self.fence.NativeOps() as ops:return self.fence.verify_live(ops,proof,BINDING_SHA)
