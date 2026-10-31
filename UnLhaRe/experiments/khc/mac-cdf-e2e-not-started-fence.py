#!/usr/bin/env python3
"""旧start名の排他fence。Job閉鎖・過去の非実行・第三者削除不在は証明しない。

実行入口はまだ提供しない。親dir nofollow、状態前後確認とCreateNew/fsyncの
APIを別の認可済み連携へ渡す。生成済fenceは失敗しても削除しない。
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import time

ROOT=PurePosixPath('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
JOURNAL=ROOT/'journal'
TMP=ROOT/'tmp'
TOOLS=ROOT/'tools'
START=JOURNAL/'mac-cdf-candidate-e2e.started.json'
RUN=TMP/'mac-cdf-candidate-example-e2e-20261027'
TERMINAL=JOURNAL/'mac-cdf-candidate-e2e.terminal.json'
CLOSURE=JOURNAL/'mac-cdf-candidate-e2e.closure.json'
DEADLINE=JOURNAL/'mac-cdf-candidate-e2e.terminal-deadline.json'
OLD_RUN='8fd4b003ba9e406da5a21b9be5a37c56'
OLD_ENDPOINT='da6231a6f6fb61b04fd2c7833661a6a4467d3ee14db5d9fcf6e19ae2731b79ba'
OLD_PROTOCOL='95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c'
OLD_WORKER='8868e4224d63376bbab2dda50e6f2fae3f6caf3fa8c22dec1bb7021234baa778'
RAW={
    'run_record_sha256':'799ef6ddb3f4c60b592ef1c6874fafe9f80c7574aab58ea87aaa59d5ee490f4e',
    'invocation_sha256':'93b1b7140547e0adcfda3952a7da3c87809d02a8cce5260efd3b6e7a12e14b00',
    'runner_result_sha256':'3038dca1472fce3e808c97de5ed7a65f52dd65a8b3b745160933bfb3509e4be6',
    'deadline_veto_sha256':'b719fcdc557756bba4c45efd556265c26b306da3697c20cc12a93c917530664a',
    'claim_sha256':'12ff3b89c0ac6631e90daa10de6c0cf2a1bf62a426ec2609ac969e9a810b2436',
    'private_registration_sha256':'04d6ba78537416ae3bcddd51ed0d69bf5abb7b418109d8011da9e989b2d0df35'}
ANCHOR_PATHS=tuple(str(p) for p in reversed((JOURNAL,)+tuple(JOURNAL.parents)))+(str(TMP),str(TOOLS))
ABSENT_PATHS=tuple(str(p) for p in (START,RUN,TERMINAL,CLOSURE,DEADLINE))
PINNED={str(TOOLS/'mac-cdf-candidate-e2e-endpoint.py'):OLD_ENDPOINT,
        str(JOURNAL/'mac-cdf-candidate-e2e-protocol.json'):OLD_PROTOCOL}
MAX_JSON=65536

def require(ok,message):
    if not ok:raise ValueError(message)
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def digest(data):return hashlib.sha256(data).hexdigest()
def sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None
def self_sha():return digest(Path(__file__).read_bytes())
def expected_pins():return dict(PINNED,**{str(TOOLS/'mac-cdf-e2e-not-started-fence.py'):self_sha()})

def validate_observation(value,*,with_fence):
    require(type(value) is dict and set(value)==({'uid','anchors','pinned','absent','fence'} if with_fence else
        {'uid','anchors','pinned','absent'}),'observation shape')
    uid=value['uid'];require(type(uid) is int and uid>0,'owner uid')
    anchors=value['anchors'];require(type(anchors) is list and len(anchors)==len(ANCHOR_PATHS),'anchor coverage')
    for path,node in zip(ANCHOR_PATHS,anchors):
        require(type(node) is dict and set(node)=={'path','dev','ino','uid','mode'} and node['path']==path and
            all(type(node[k]) is int and node[k]>=0 for k in ('dev','ino','uid','mode')) and node['ino']>0 and
            node['uid'] in (0,uid) and not node['mode']&0o7022,'anchor identity/owner/mode')
        if path in (str(ROOT),str(JOURNAL),str(TMP)):
            require(node['uid']==uid and not node['mode']&0o077,'private anchor')
    absent_paths=set(ABSENT_PATHS)-({str(START)} if with_fence else set())
    require(type(value['absent']) is dict and set(value['absent'])==absent_paths and
        all(type(v) is bool and v for v in value['absent'].values()),'required absence')
    pins=expected_pins();pinned=value['pinned'];require(type(pinned) is list and len(pinned)==len(pins),'pinned dependency coverage')
    for path,node in zip(pins,pinned):
        require(type(node) is dict and set(node)=={'path','dev','ino','uid','mode','sha256'} and
            node['path']==path and node['sha256']==pins[path] and node['uid']==uid and
            all(type(node[k]) is int and node[k]>=0 for k in ('dev','ino','uid','mode')) and
            node['ino']>0 and not node['mode']&0o7022,'pinned file identity')
    if with_fence:
        item=value['fence'];journal=anchors[ANCHOR_PATHS.index(str(JOURNAL))]
        require(type(item) is dict and set(item)=={'dev','ino','uid','mode','empty'} and
            all(type(item[k]) is int and item[k]>=0 for k in ('dev','ino','uid','mode')) and
            item['dev']==journal['dev'] and item['ino']>0 and item['uid']==uid and item['mode']==0o700 and
            item['empty'] is True,'fence inode/owner/mode/device/empty')

def validate_evidence(value,windows_binding_sha):
    keys={'schema','kind','old_run_id','old_endpoint_sha256','old_protocol_sha256','old_worker_sha256',
        'fence_controller_sha256','created_unix_ns','windows_binding_sha256',
        'raw_sha256','observation','past_start_status','windows_job_status','third_party_deletion_status',
        'guarantee','fence_path'}
    require(type(value) is dict and set(value)==keys and type(value['schema']) is int and value['schema']==1 and
        value['kind']=='not-started-observed' and value['old_run_id']==OLD_RUN and
        value['old_endpoint_sha256']==OLD_ENDPOINT and value['old_protocol_sha256']==OLD_PROTOCOL and
        value['old_worker_sha256']==OLD_WORKER and value['fence_controller_sha256']==self_sha() and
        type(value['created_unix_ns']) is int and value['created_unix_ns']>0 and
        sha(windows_binding_sha) and value['windows_binding_sha256']==windows_binding_sha and
        value['raw_sha256']==RAW and value['past_start_status']=='unknown' and value['windows_job_status']=='unknown' and
        value['third_party_deletion_status']=='unknown' and value['fence_path']==str(START) and
        value['guarantee']=='fixed-old-endpoint-start-create-blocked-while-fence-intact','evidence binding')
    validate_observation(value['observation'],with_fence=True)
    return dict(content_verified=True,fence_live_verified=False,kind=value['kind'],
        fence_path=value['fence_path'],evidence_sha256=digest(canonical(value)),
        windows_job_status='unknown',past_start_status='unknown',third_party_deletion_status='unknown')

def create_fence(ops,windows_binding_sha):
    require(sha(windows_binding_sha),'Windows evidence binding SHA')
    before=ops.capture();validate_observation(before,with_fence=False)
    ops.create_exclusive()
    ops.sync()
    after=ops.verify(before)
    validate_observation(after,with_fence=True)
    require(after['anchors']==before['anchors'] and after['pinned']==before['pinned'] and
        after['uid']==before['uid'],'anchor/pin changed during fence')
    value=dict(schema=1,kind='not-started-observed',old_run_id=OLD_RUN,old_endpoint_sha256=OLD_ENDPOINT,
        old_protocol_sha256=OLD_PROTOCOL,old_worker_sha256=OLD_WORKER,fence_controller_sha256=self_sha(),
        created_unix_ns=time.time_ns(),windows_binding_sha256=windows_binding_sha,raw_sha256=RAW,
        observation=after,past_start_status='unknown',windows_job_status='unknown',third_party_deletion_status='unknown',
        guarantee='fixed-old-endpoint-start-create-blocked-while-fence-intact',fence_path=str(START))
    validate_evidence(value,windows_binding_sha)
    ops.persist(canonical(value))
    return value

def verify_live(ops,data,windows_binding_sha):
    value=parse_evidence(data);summary=validate_evidence(value,windows_binding_sha)
    current=ops.verify(value['observation'])
    validate_observation(current,with_fence=True)
    require(current==value['observation'],'live fence/anchors changed')
    require(ops.read_evidence()==data,'persisted evidence differs')
    require(ops.verify(value['observation'])==current,'fence changed during evidence read')
    summary['fence_live_verified']=True
    return summary

def parse_evidence(data):
    require(type(data) is bytes and 0<len(data)<=MAX_JSON,'evidence bytes bound')
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'duplicate JSON key');result[key]=value
        return result
    value=json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
    require(canonical(value)==data,'canonical evidence');return value

class NativeOps:
    """dir_fd基準の排他操作。呼出し前のWindows証拠とleaseの認可は呼出側が行う。"""
    def __init__(self):
        require(Path(__file__).absolute()==Path(str(TOOLS/'mac-cdf-e2e-not-started-fence.py')),
            'fixed native controller location')
        self.uid=os.getuid();self.handles={};self.fence_fd=None;self.before=None
    def __enter__(self):return self
    def __exit__(self,*_):
        if self.fence_fd is not None:os.close(self.fence_fd);self.fence_fd=None
        for fd in reversed(list(self.handles.values())):os.close(fd)
        self.handles.clear()
    @staticmethod
    def _identity(path,info):
        require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode),'anchor directory type')
        return dict(path=str(path),dev=info.st_dev,ino=info.st_ino,uid=info.st_uid,mode=stat.S_IMODE(info.st_mode))
    @staticmethod
    def _same(a,b):return (a.st_dev,a.st_ino,a.st_uid,a.st_mode)==(b.st_dev,b.st_ino,b.st_uid,b.st_mode)
    def _anchors(self,first=False):
        flags=os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW
        result=[]
        for path_string in ANCHOR_PATHS:
            path=PurePosixPath(path_string)
            if first:
                if path==PurePosixPath('/'):fd=os.open('/',flags)
                else:
                    parent=self.handles[str(path.parent)]
                    fd=os.open(path.name,flags,dir_fd=parent)
                self.handles[path_string]=fd
            fd=self.handles[path_string]
            anchored=os.fstat(fd);absolute=os.lstat(path_string)
            require(self._same(anchored,absolute),'absolute/dirfd anchor mismatch')
            if path!=PurePosixPath('/'):
                parent=self.handles[str(path.parent)]
                named=os.stat(path.name,dir_fd=parent,follow_symlinks=False)
                require(self._same(anchored,named),'parent/child anchor mismatch')
            result.append(self._identity(path,anchored))
        return result
    @staticmethod
    def _absent(fd,name):
        try:os.stat(name,dir_fd=fd,follow_symlinks=False)
        except FileNotFoundError:return True
        return False
    def _other_absent(self):
        journal=self.handles[str(JOURNAL)];tmp=self.handles[str(TMP)]
        values={str(RUN):self._absent(tmp,RUN.name)}
        for path in (TERMINAL,CLOSURE,DEADLINE):values[str(path)]=self._absent(journal,path.name)
        return values
    def _pinned(self):
        values=[]
        for path_string,expected in expected_pins().items():
            path=PurePosixPath(path_string);parent=self.handles[str(path.parent)]
            fd=os.open(path.name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=parent)
            try:
                before=os.fstat(fd);named=os.stat(path.name,dir_fd=parent,follow_symlinks=False)
                absolute=os.lstat(path_string)
                require(self._same(before,named) and self._same(before,absolute) and stat.S_ISREG(before.st_mode) and
                    before.st_uid==self.uid and before.st_nlink==1 and before.st_size<=131072,'pinned file type/path')
                chunks=[];size=0
                while True:
                    block=os.read(fd,65536)
                    if not block:break
                    size+=len(block);require(size<=131072,'pinned file size')
                    chunks.append(block)
                after=os.fstat(fd);raw=b''.join(chunks)
                require(self._same(before,after) and size==before.st_size==after.st_size and
                    before.st_mtime_ns==after.st_mtime_ns and digest(raw)==expected,'pinned file changed')
                values.append(dict(path=path_string,dev=before.st_dev,ino=before.st_ino,uid=before.st_uid,
                    mode=stat.S_IMODE(before.st_mode),sha256=expected))
            finally:os.close(fd)
        return values
    def capture(self):
        require(not self.handles,'capture only once')
        anchors=self._anchors(first=True);absent=self._other_absent()
        absent[str(START)]=self._absent(self.handles[str(JOURNAL)],START.name)
        evidence='mac-cdf-e2e-not-started-observed.json'
        require(self._absent(self.handles[str(JOURNAL)],evidence),'fence evidence path already occupied')
        try:os.lstat(str(JOURNAL/evidence))
        except FileNotFoundError:pass
        else:raise ValueError('absolute fence evidence path already occupied')
        # 独立した絶対path上の不在も同時に検査する。ENOENT以外は拒否。
        for path in (START,RUN,TERMINAL,CLOSURE,DEADLINE):
            try:os.lstat(str(path))
            except FileNotFoundError:continue
            absent[str(path)]=False
        self.before=dict(uid=self.uid,anchors=anchors,pinned=self._pinned(),absent=absent)
        validate_observation(self.before,with_fence=False)
        return self.before
    def create_exclusive(self):
        require(self.before is not None,'capture before mkdir')
        # EEXISTその他の失敗はそのまま返し、削除・上書き・retryは行わない。
        os.mkdir(START.name,0o700,dir_fd=self.handles[str(JOURNAL)])
        self.fence_fd=os.open(START.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,
            dir_fd=self.handles[str(JOURNAL)])
    def sync(self):
        require(self.fence_fd is not None,'fence handle required')
        os.fsync(self.fence_fd);os.fsync(self.handles[str(JOURNAL)])
    def verify(self,before):
        if not self.handles:
            self._anchors(first=True)
            self.fence_fd=os.open(START.name,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW,
                dir_fd=self.handles[str(JOURNAL)])
        require(self.fence_fd is not None,'live fence handle required')
        anchors=self._anchors();require(anchors==before['anchors'],'anchor path swap')
        journal=self.handles[str(JOURNAL)];a=os.fstat(self.fence_fd)
        b=os.stat(START.name,dir_fd=journal,follow_symlinks=False);c=os.lstat(str(START))
        require(self._same(a,b) and self._same(a,c) and stat.S_ISDIR(a.st_mode),'fence path swap/type')
        absent=self._other_absent()
        for path in (RUN,TERMINAL,CLOSURE,DEADLINE):
            try:os.lstat(str(path))
            except FileNotFoundError:continue
            absent[str(path)]=False
        result=dict(uid=self.uid,anchors=anchors,pinned=self._pinned(),absent=absent,
            fence=dict(dev=a.st_dev,ino=a.st_ino,uid=a.st_uid,mode=stat.S_IMODE(a.st_mode),
                       empty=not os.listdir(self.fence_fd)))
        validate_observation(result,with_fence=True)
        return result
    def persist(self,data):
        require(self.before is not None and self.fence_fd is not None,'fence before evidence')
        path='mac-cdf-e2e-not-started-observed.json'
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600,
                   dir_fd=self.handles[str(JOURNAL)])
        try:
            with os.fdopen(fd,'wb',closefd=False) as stream:
                stream.write(data);stream.flush();os.fsync(fd)
            info=os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid==self.uid and info.st_nlink==1 and
                stat.S_IMODE(info.st_mode)==0o600 and info.st_size==len(data),'evidence file identity')
        finally:os.close(fd)
        os.fsync(self.handles[str(JOURNAL)])
        checked=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=self.handles[str(JOURNAL)])
        try:
            after=os.fstat(checked);absolute=os.lstat(str(JOURNAL/path))
            require(self._same(info,after) and self._same(after,absolute) and after.st_nlink==1 and
                os.read(checked,len(data)+1)==data,'evidence persistence/path identity')
        finally:os.close(checked)
        final=self.verify(self.before)
        require(final['pinned']==self.before['pinned'],'pinned files changed during evidence persistence')
    def read_evidence(self):
        require(bool(self.handles),'open live anchors required')
        name='mac-cdf-e2e-not-started-observed.json';journal=self.handles[str(JOURNAL)]
        fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=journal)
        try:
            before=os.fstat(fd);named=os.stat(name,dir_fd=journal,follow_symlinks=False)
            absolute=os.lstat(str(JOURNAL/name))
            require(self._same(before,named) and self._same(before,absolute) and stat.S_ISREG(before.st_mode) and
                before.st_uid==self.uid and before.st_nlink==1 and stat.S_IMODE(before.st_mode)==0o600 and
                before.st_size<=MAX_JSON,'evidence type/path')
            data=os.read(fd,MAX_JSON+1);after=os.fstat(fd)
            require(self._same(before,after) and len(data)==before.st_size==after.st_size and
                before.st_mtime_ns==after.st_mtime_ns,'evidence changed while reading')
            return data
        finally:os.close(fd)
