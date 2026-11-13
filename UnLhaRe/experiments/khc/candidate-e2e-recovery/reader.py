"""旧失敗attemptの固定8原証拠を読む専用reader。回復・登録・sealは行わない。"""
import argparse
import base64
import ctypes
from ctypes import wintypes
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import PureWindowsPath
import re
import sys
import tempfile
import xml.etree.ElementTree as ET


def _khc_user_temp():
    """作業・保全の基点となるユーザー既定の一時フォルダーを返す（旧Dドライブ固定の作業フォルダー運用は廃止）。

    storage-lifecycle.psm1 と同じ規則にそろえる。親プロセスが子向けに TEMP/TMP を
    task専用tempへ差し替えるため、tempfile.gettempdir() だけに頼ると基点がずれる。
    そこでレジストリ上のユーザー環境変数TEMPを優先し、読めない環境だけ gettempdir() へ退避する。
    """
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            value, _kind = winreg.QueryValueEx(key, 'TEMP')
        if value:
            return os.path.expandvars(value)
    except OSError:
        pass
    except ImportError:
        pass
    return tempfile.gettempdir()


# 旧Dドライブ運用時の作業先・保全先に相当する兄弟フォルダー（work / TaskArtifacts）の親。
KHC_STORAGE_ROOT=os.path.join(_khc_user_temp(), 'UnLhaRe')
RUN_ID='8fd4b003ba9e406da5a21b9be5a37c56'
STATE=os.path.join(KHC_STORAGE_ROOT, r'TaskArtifacts\goal-restore-20261019\storage-lifecycle')
WORK=os.path.join(KHC_STORAGE_ROOT, r'work\goal-restore-20261019\run-3c4643267fbe4cf0952bb3e2c2545e2e')
WORKER=r'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-cdf-candidate-e2e.ps1'
PROTOCOL_PATH=os.path.join(KHC_STORAGE_ROOT, r'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-e2e-protocol.json')
PROTOCOL_SHA='95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c'
RUN_DIRECTORY=STATE+'\\runs\\'+RUN_ID
ANCHOR=STATE+'\\recycle-v6'
RUN_ENTRIES=('run.json','recycle-v6.json','invocation.clixml','runner-result.json','runner-deadline-failure.json')
PATHS=dict(zip(('run','recycle','invocation','result','veto'),(RUN_DIRECTORY+'\\'+x for x in RUN_ENTRIES)))
PATHS.update(reserve=ANCHOR+'\\'+RUN_ID+'.reserve.json',registration=ANCHOR+'\\mac-cdf-candidate-e2e-'+RUN_ID+'-registration.json',claim=ANCHOR+'\\mac-cdf-candidate-e2e.claim.json')
PINS=dict(zip(PATHS,(
    '799ef6ddb3f4c60b592ef1c6874fafe9f80c7574aab58ea87aaa59d5ee490f4e',
    '177e250ab68a4eaf935d7777130b56ef433bb4601c1264fbc5f1f243ace39d2f',
    '93b1b7140547e0adcfda3952a7da3c87809d02a8cce5260efd3b6e7a12e14b00',
    '3038dca1472fce3e808c97de5ed7a65f52dd65a8b3b745160933bfb3509e4be6',
    'b719fcdc557756bba4c45efd556265c26b306da3697c20cc12a93c917530664a',
    'b9ad6ab689b0d3546e133325db59878510085db496ad4d5670ad21d70e460904',
    '04d6ba78537416ae3bcddd51ed0d69bf5abb7b418109d8011da9e989b2d0df35',
    '12ff3b89c0ac6631e90daa10de6c0cf2a1bf62a426ec2609ac969e9a810b2436')))
FORBIDDEN=(RUN_DIRECTORY+'\\complete.json',RUN_DIRECTORY+'\\cleanup-request.json',ANCHOR+'\\mac-cdf-candidate-e2e-'+RUN_ID+'.json',WORK)
BOUND=65536


class Refusal(ValueError):pass


def require(ok,message):
    if not ok:raise Refusal(message)


def sha(data):return hashlib.sha256(data).hexdigest()


def object_pairs(pairs):
    value={}
    for key,item in pairs:
        require(key not in value,'duplicate JSON field');value[key]=item
    return value


def parse(data):
    try:
        return json.loads(data.decode('utf-8',errors='strict'),object_pairs_hook=object_pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(Refusal('nonfinite JSON')))
    except (UnicodeError,json.JSONDecodeError) as error:raise Refusal('invalid UTF-8 JSON') from error


def fields(obj,names):
    require(type(obj) is dict and set(obj)==set(names.split()),'unknown/missing JSON field')


def equal(obj,key,value):
    require(key in obj and type(obj[key]) is type(value) and obj[key]==value,'typed binding: '+key)


def utc(value):
    require(type(value) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z',value),'UTC timestamp')
    try:return datetime.fromisoformat(value.replace('Z','+00:00'))
    except ValueError as error:raise Refusal('invalid UTC date') from error


def validate_invocation(data,protocol_sha):
    """CLIXMLをオブジェクト復元せず、固定XML木として照合する。"""
    require(b'<!DOCTYPE' not in data.upper() and b'<!ENTITY' not in data.upper(),'DTD/entity prohibited')
    try:root=ET.fromstring(data.decode('utf-8',errors='strict'))
    except (UnicodeError,ET.ParseError) as error:raise Refusal('invalid invocation XML') from error
    template=('<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj RefId="0"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN><MS><S N="script">'+WORKER+'</S><Obj N="parameters" RefId="1"><TN RefId="1"><T>System.Collections.Hashtable</T><T>System.Object</T></TN><DCT>'+''.join('<En><S N="Key">'+k+'</S><S N="Value">'+v+'</S></En>' for k,v in [('ProtocolPath',PROTOCOL_PATH),('ProtocolSha256',protocol_sha),('WorkDirectory',WORK)])+'</DCT></Obj></MS></Obj></Objs>')
    def shape(node):
        require(not (node.tail or '').strip(),'unexpected XML tail')
        return node.tag,tuple(sorted(node.attrib.items())),(node.text or '').strip(),tuple(shape(child) for child in node)
    require(shape(root)==shape(ET.fromstring(template)),'invocation script/three parameters/type tree')


def validate_bundle(raw,pins=PINS,protocol_sha=PROTOCOL_SHA):
    """pins引数は純粋fixture用。実CLIは固定8path・固定SHA以外を受け付けない。"""
    require(type(raw) is dict and set(raw)==set(PATHS) and set(pins)==set(PATHS),'exact eight evidence set')
    for key,data in raw.items():
        require(type(data) is bytes and 0<len(data)<=BOUND and sha(data)==pins[key],'evidence bytes/hash: '+key)
    d={key:parse(data) for key,data in raw.items() if key!='invocation'}
    r=d['run'];fields(r,'run_id work_directory max_bytes max_entries owner_pid owner_start_ticks owner_start_utc created_utc')
    for key,value in [('run_id',RUN_ID),('work_directory',WORK),('max_bytes',8388608),('max_entries',96)]:equal(r,key,value)
    require(all(type(r[k]) is int and r[k]>0 for k in ('owner_pid','owner_start_ticks')),'run owner identity types')
    require(utc(r['owner_start_utc'])<=utc(r['created_utc']),'run owner/start chronology')
    reserve=d['reserve'];fields(reserve,'schema protocol run_id registration_sha256 max_bytes max_entries payload_bytes metadata_bytes remote_candidate_e2e_required remote_candidate_e2e_protocol_sha256')
    for key,value in [('schema',1),('protocol','prunlet-recycle-v6'),('run_id',RUN_ID),('registration_sha256',sha(raw['run'])),('max_bytes',8388608),('max_entries',96),('payload_bytes',8388608),('metadata_bytes',7340032),('remote_candidate_e2e_required',True),('remote_candidate_e2e_protocol_sha256',protocol_sha)]:equal(reserve,key,value)
    recycle=d['recycle'];fields(recycle,'schema protocol reservation_sha256')
    for key,value in [('schema',1),('protocol','prunlet-recycle-v6'),('reservation_sha256',sha(raw['reserve']))]:equal(recycle,key,value)
    registration=d['registration'];fields(registration,'schema protocol run_id record_sha256 worker_path worker_sha256 invocation_sha256 protocol_sha256 protocol_base64')
    for key,value in [('schema',1),('protocol','khc-mac-cdf-candidate-e2e-registration-v1'),('run_id',RUN_ID),('record_sha256',sha(raw['run'])),('worker_path',WORKER),('worker_sha256','8868e4224d63376bbab2dda50e6f2fae3f6caf3fa8c22dec1bb7021234baa778'),('invocation_sha256',sha(raw['invocation'])),('protocol_sha256',protocol_sha)]:equal(registration,key,value)
    require(type(registration['protocol_base64']) is str,'protocol base64 type')
    try:protocol_bytes=base64.b64decode(registration['protocol_base64'],validate=True)
    except (ValueError,TypeError) as error:raise Refusal('invalid protocol base64') from error
    require(len(protocol_bytes)<=32768 and sha(protocol_bytes)==protocol_sha,'embedded fixed protocol hash')
    protocol=parse(protocol_bytes)
    equal(protocol,'schema',1);equal(protocol,'protocol','khc-mac-cdf-candidate-e2e-v1');equal(protocol,'purpose','candidate-example-correctness-only')
    validate_invocation(raw['invocation'],protocol_sha)
    claim=d['claim'];fields(claim,'schema protocol run_id record_sha256 protocol_sha256 registered_utc')
    for key,value in [('schema',1),('protocol','khc-mac-cdf-candidate-e2e-claim-v1'),('run_id',RUN_ID),('record_sha256',sha(raw['run'])),('protocol_sha256',protocol_sha)]:equal(claim,key,value)
    require(utc(claim['registered_utc'])>=utc(r['created_utc']),'claim chronology')
    result=d['result'];fields(result,'schema run_id status runner_sha256 runner_sha256_at_finish started_utc finished_utc child_started child_pid child_exit_code stdout_eof stderr_eof job_active_after_exit cleanup_request_created failure_message')
    for key,value in [('schema',1),('run_id',RUN_ID),('status','failed'),('runner_sha256','37aa32ce53577830f2f06f0c02a8a769a0d01b7fda5f8743bbf7878db603927f'),('runner_sha256_at_finish','37aa32ce53577830f2f06f0c02a8a769a0d01b7fda5f8743bbf7878db603927f'),('child_started',True),('child_pid',0),('child_exit_code',None),('stdout_eof',False),('stderr_eof',False),('job_active_after_exit',None),('cleanup_request_created',False)]:equal(result,key,value)
    require(utc(result['finished_utc'])>=utc(result['started_utc']),'runner chronology')
    require(type(result['failure_message']) is str and 0<len(result['failure_message'])<=4096,'failure message')
    veto=d['veto'];fields(veto,'schema protocol run_id record_sha256 protocol_sha256 original_result_sha256 elapsed_seconds recorded_utc')
    for key,value in [('schema',1),('protocol','khc-candidate-runner-deadline-failure-v1'),('run_id',RUN_ID),('record_sha256',sha(raw['run'])),('protocol_sha256',protocol_sha),('original_result_sha256',sha(raw['result']))]:equal(veto,key,value)
    require(type(veto['elapsed_seconds']) in (int,float) and math.isfinite(veto['elapsed_seconds']) and veto['elapsed_seconds']>360,'deadline veto elapsed')
    require(utc(veto['recorded_utc'])>=utc(result['finished_utc']),'veto chronology')
    return dict(schema=1,run_id=RUN_ID,classification='failed-pending-closure-unknown',can_start=False,
        cleanup_allowed=False,historical_closure_proven=False,never_invoked_proven=False,
        original_cause_known=False,pending_preserved=True,claim_preserved=True,
        evidence=[dict(name=key,path=PATHS[key],bytes=len(raw[key]),sha256=sha(raw[key])) for key in PATHS],
        declared_child_started=True,declared_child_pid=0,declared_child_exit_code=None,
        deadline_elapsed_seconds=veto['elapsed_seconds'])


def validate_native_info(attributes,links,filetype,*,directory):
    require(filetype==1 and not attributes&0x400 and bool(attributes&0x10)==directory,'non-disk/reparse/type')
    if not directory:require(links==1,'evidence must be single link')


class WindowsEvidence:
    """祖先とleafをread-only/share-readで保持し、同handleだけから読む。"""
    def __init__(self):
        require(os.name=='nt','native evidence reading requires Windows')
        self.k=ctypes.WinDLL('kernel32',use_last_error=True);self.handles=[];self.leaves={}
        class Info(ctypes.Structure):
            _fields_=[('Attributes',wintypes.DWORD),('Creation',wintypes.FILETIME),('Access',wintypes.FILETIME),('Write',wintypes.FILETIME),('Volume',wintypes.DWORD),('SizeHigh',wintypes.DWORD),('SizeLow',wintypes.DWORD),('Links',wintypes.DWORD),('IndexHigh',wintypes.DWORD),('IndexLow',wintypes.DWORD)]
        self.Info=Info
        self.k.CreateFileW.argtypes=[wintypes.LPCWSTR,wintypes.DWORD,wintypes.DWORD,ctypes.c_void_p,wintypes.DWORD,wintypes.DWORD,wintypes.HANDLE];self.k.CreateFileW.restype=wintypes.HANDLE
        self.k.GetFileInformationByHandle.argtypes=[wintypes.HANDLE,ctypes.POINTER(Info)];self.k.GetFileInformationByHandle.restype=wintypes.BOOL
        self.k.GetFileType.argtypes=[wintypes.HANDLE];self.k.GetFileType.restype=wintypes.DWORD
        self.k.ReadFile.argtypes=[wintypes.HANDLE,ctypes.c_void_p,wintypes.DWORD,ctypes.POINTER(wintypes.DWORD),ctypes.c_void_p];self.k.ReadFile.restype=wintypes.BOOL
        self.k.SetFilePointerEx.argtypes=[wintypes.HANDLE,ctypes.c_longlong,ctypes.c_void_p,wintypes.DWORD];self.k.SetFilePointerEx.restype=wintypes.BOOL
        self.k.CloseHandle.argtypes=[wintypes.HANDLE];self.k.CloseHandle.restype=wintypes.BOOL

    def open(self,path,directory):
        h=self.k.CreateFileW(path,0x80 if directory else 0x80000000,1,None,3,0x02200000,None)
        if h==ctypes.c_void_p(-1).value:raise ctypes.WinError(ctypes.get_last_error())
        self.handles.append(h);self.info(h,directory);return h

    def info(self,h,directory=False):
        i=self.Info()
        if not self.k.GetFileInformationByHandle(h,ctypes.byref(i)):raise ctypes.WinError(ctypes.get_last_error())
        validate_native_info(i.Attributes,i.Links,self.k.GetFileType(h),directory=directory)
        require(directory or (i.SizeHigh==0 and 0<i.SizeLow<=BOUND),'native evidence size')
        return i.Volume,i.IndexHigh,i.IndexLow,i.Links,i.Attributes,i.SizeHigh,i.SizeLow,i.Write.dwHighDateTime,i.Write.dwLowDateTime

    def __enter__(self):
        try:
            parents={str(p) for path in PATHS.values() for p in PureWindowsPath(path).parents}
            # 前方から祖先handleを保持。上位ancestor raceの絶対排除までは主張しない。
            for parent in sorted(parents,key=lambda p:(len(PureWindowsPath(p).parts),p)):self.open(parent,True)
            for name,path in PATHS.items():self.leaves[name]=self.open(path,False)
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self,exc_type,exc_value,traceback):
        # BOOL失敗も例外として扱う。後続の解放を止めず、元の検証失敗を保持する。
        errors=[];unclosed=[]
        for handle in reversed(self.handles):
            try:
                if not self.k.CloseHandle(handle):
                    raise OSError(ctypes.get_last_error(),'CloseHandle failed')
            except BaseException as error:
                errors.append(error);unclosed.append(handle)
        self.handles=list(reversed(unclosed))
        if errors:
            if exc_value is not None:errors.insert(0,exc_value)
            raise BaseExceptionGroup('evidence validation/handle release failed',errors)
        return False

    def identity(self,name):return self.info(self.leaves[name])

    def read(self,name):
        h=self.leaves[name]
        if not self.k.SetFilePointerEx(h,0,None,0):raise ctypes.WinError(ctypes.get_last_error())
        buffer=ctypes.create_string_buffer(BOUND+1);count=wintypes.DWORD()
        if not self.k.ReadFile(h,buffer,BOUND+1,ctypes.byref(count),None):raise ctypes.WinError(ctypes.get_last_error())
        require(0<count.value<=BOUND,'same-handle read bound')
        return buffer.raw[:count.value]

    def boundary(self):
        for path in FORBIDDEN:
            h=self.k.CreateFileW(path,0x80,1,None,3,0x02200000,None)
            if h!=ctypes.c_void_p(-1).value:
                self.handles.append(h)
                raise Refusal('forbidden output/state exists: '+path)
            error=ctypes.get_last_error()
            require(error in (2,3),'cannot establish forbidden path absence')
        return dict(entries=sorted(os.listdir(RUN_DIRECTORY)),forbidden_present=False)


def inspect_evidence(backend=None,*,pins=PINS,protocol_sha=PROTOCOL_SHA):
    with (backend if backend is not None else WindowsEvidence()) as source:
        first=source.boundary()
        require(first==dict(entries=sorted(RUN_ENTRIES),forbidden_present=False),'run directory/output boundary')
        identities={name:source.identity(name) for name in PATHS}
        raw={name:source.read(name) for name in PATHS}
        summary=validate_bundle(raw,pins,protocol_sha)
        for name in PATHS:
            require(source.identity(name)==identities[name] and source.read(name)==raw[name],'same-handle evidence changed')
        require(source.boundary()==first,'run/output boundary changed')
        return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--read-only',action='store_true',required=True)
    parser.parse_args()
    print(json.dumps(inspect_evidence(),sort_keys=True,separators=(',',':')))


if __name__=='__main__':main()
