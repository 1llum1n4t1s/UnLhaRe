"""先行失敗条件: hash/集合/型/結合/重複JSON/XML外部参照/読取中変更/新出力。

メモリfixtureのみ。実登録・本番state書込み・SSH・削除は実施しない。
"""
import base64
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

spec=importlib.util.spec_from_file_location('recovery_reader',Path(__file__).with_name('reader.py'))
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)


def sha(b):return hashlib.sha256(b).hexdigest()
def encode(v):return json.dumps(v,separators=(',',':')).encode()


def fixture():
    protocol=encode(dict(schema=1,protocol='khc-mac-cdf-candidate-e2e-v1',purpose='candidate-example-correctness-only'))
    psha=sha(protocol);rid='8fd4b003ba9e406da5a21b9be5a37c56'
    run=dict(run_id=rid,work_directory=M.WORK,max_bytes=8388608,max_entries=96,owner_pid=44468,
        owner_start_ticks=639286471405330489,owner_start_utc='2026-10-26T21:32:20.5330489Z',created_utc='2026-10-26T21:35:33.1577342Z')
    invocation=('''<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><Obj RefId="0"><TN RefId="0"><T>System.Management.Automation.PSCustomObject</T><T>System.Object</T></TN><MS><S N="script">'''+M.WORKER+'''</S><Obj N="parameters" RefId="1"><TN RefId="1"><T>System.Collections.Hashtable</T><T>System.Object</T></TN><DCT>'''+''.join('<En><S N="Key">'+k+'</S><S N="Value">'+v+'</S></En>' for k,v in [('ProtocolPath',M.PROTOCOL_PATH),('ProtocolSha256',psha),('WorkDirectory',M.WORK)])+'''</DCT></Obj></MS></Obj></Objs>''').encode()
    result=dict(schema=1,run_id=rid,status='failed',runner_sha256='37aa32ce53577830f2f06f0c02a8a769a0d01b7fda5f8743bbf7878db603927f',runner_sha256_at_finish='37aa32ce53577830f2f06f0c02a8a769a0d01b7fda5f8743bbf7878db603927f',started_utc='2026-10-26T21:32:22.856696Z',finished_utc='2026-10-26T21:38:34.097656Z',child_started=True,child_pid=0,child_exit_code=None,stdout_eof=False,stderr_eof=False,job_active_after_exit=None,cleanup_request_created=False,failure_message='deadline; original failure unavailable')
    raw=dict(run=encode(run),invocation=invocation,result=encode(result))
    raw['reserve']=encode(dict(schema=1,protocol='prunlet-recycle-v6',run_id=rid,registration_sha256=sha(raw['run']),max_bytes=8388608,max_entries=96,payload_bytes=8388608,metadata_bytes=7340032,remote_candidate_e2e_required=True,remote_candidate_e2e_protocol_sha256=psha))
    raw['recycle']=encode(dict(schema=1,protocol='prunlet-recycle-v6',reservation_sha256=sha(raw['reserve'])))
    raw['registration']=encode(dict(schema=1,protocol='khc-mac-cdf-candidate-e2e-registration-v1',run_id=rid,record_sha256=sha(raw['run']),worker_path=M.WORKER,worker_sha256='8868e4224d63376bbab2dda50e6f2fae3f6caf3fa8c22dec1bb7021234baa778',invocation_sha256=sha(invocation),protocol_sha256=psha,protocol_base64=base64.b64encode(protocol).decode()))
    raw['claim']=encode(dict(schema=1,protocol='khc-mac-cdf-candidate-e2e-claim-v1',run_id=rid,record_sha256=sha(raw['run']),protocol_sha256=psha,registered_utc='2026-10-26T21:36:10.0373542Z'))
    raw['veto']=encode(dict(schema=1,protocol='khc-candidate-runner-deadline-failure-v1',run_id=rid,record_sha256=sha(raw['run']),protocol_sha256=psha,original_result_sha256=sha(raw['result']),elapsed_seconds=373.0308542,recorded_utc='2026-10-26T21:38:34.2569798Z'))
    return raw,{k:sha(v) for k,v in raw.items()},psha


class Backend:
    def __init__(self,raw):self.raw=raw;self.closed=False;self.calls={};self.changed=None;self.boundary_calls=0;self.extra=False
    def __enter__(self):return self
    def __exit__(self,*args):self.closed=True
    def identity(self,name):return (1,2,1,len(self.raw[name]))
    def read(self,name):
        self.calls[name]=self.calls.get(name,0)+1
        return self.raw[name]+(b'x' if self.changed==name and self.calls[name]>1 else b'')
    def boundary(self):
        self.boundary_calls+=1
        return dict(entries=sorted(M.RUN_ENTRIES)+(['unexpected'] if self.extra else []),forbidden_present=False)


class Reader(unittest.TestCase):
    def test_conservative_classification_and_same_handle_second_read(self):
        raw,pins,psha=fixture();backend=Backend(raw)
        value=M.inspect_evidence(backend,pins=pins,protocol_sha=psha)
        self.assertFalse(value['can_start']);self.assertFalse(value['cleanup_allowed'])
        self.assertFalse(value['historical_closure_proven']);self.assertFalse(value['never_invoked_proven'])
        self.assertEqual(value['classification'],'failed-pending-closure-unknown')
        self.assertEqual(set(backend.calls.values()),{2});self.assertEqual(backend.boundary_calls,2)
        self.assertTrue(backend.closed)

    def test_hash_count_and_read_change_fail_closed(self):
        raw,pins,psha=fixture()
        for key in raw:
            wrong=dict(raw);wrong[key]+=b'x'
            with self.subTest(key=key),self.assertRaises(M.Refusal):M.validate_bundle(wrong,pins,psha)
        with self.assertRaises(M.Refusal):M.validate_bundle(dict(raw,unknown=b'{}'),pins,psha)
        backend=Backend(raw);backend.changed='claim'
        with self.assertRaises(M.Refusal):M.inspect_evidence(backend,pins=pins,protocol_sha=psha)
        self.assertTrue(backend.closed)
        backend=Backend(raw);backend.extra=True
        with self.assertRaises(M.Refusal):M.inspect_evidence(backend,pins=pins,protocol_sha=psha)
        self.assertTrue(backend.closed)

    def test_all_cross_bindings_unknown_fields_and_types_are_checked(self):
        raw,_,psha=fixture()
        mutations=[('reserve','registration_sha256','0'*64),('recycle','reservation_sha256','0'*64),
            ('registration','invocation_sha256','0'*64),('registration','protocol_base64','e30='),
            ('claim','run_id','0'*32),('veto','original_result_sha256','0'*64),
            ('run','max_entries',True),('reserve','remote_candidate_e2e_required',1),
            ('result','status','succeeded'),('result','child_pid',123),('result','child_exit_code',0),
            ('result','stdout_eof',True),('result','cleanup_request_created',True),('veto','elapsed_seconds',359),
            ('claim','unknown',True)]
        for name,key,value in mutations:
            changed=copy.deepcopy(raw);obj=json.loads(changed[name]);obj[key]=value;changed[name]=encode(obj)
            with self.subTest(name=name,key=key),self.assertRaises(M.Refusal):M.validate_bundle(changed,{k:sha(v) for k,v in changed.items()},psha)

    def test_json_and_xml_never_expand_or_accept_duplicate_parameters(self):
        raw,_,psha=fixture()
        for name,body in [('claim',b'{"schema":1,"schema":1}'),('veto',b'{"elapsed_seconds":NaN}'),
            ('invocation',b'<!DOCTYPE x [<!ENTITY ext SYSTEM "file:///secret">]><x>&ext;</x>'),
            ('invocation',raw['invocation'].replace(b'ProtocolPath',b'UnknownField')),
            ('invocation',raw['invocation'].replace(b'ProtocolSha256',b'ProtocolPath'))]:
            changed=dict(raw);changed[name]=body
            with self.subTest(name=name,body=body[:30]),self.assertRaises(M.Refusal):M.validate_bundle(changed,{k:sha(v) for k,v in changed.items()},psha)

    def test_native_attribute_policy_is_strict(self):
        M.validate_native_info(0x20,1,1,directory=False)
        M.validate_native_info(0x10,1,1,directory=True)
        for attrs,links,kind,isdir in [(0x420,1,1,False),(0x20,2,1,False),(0x20,1,3,False),(0x10,1,1,False),(0x20,1,1,True)]:
            with self.assertRaises(M.Refusal):M.validate_native_info(attrs,links,kind,directory=isdir)

    def test_native_close_bool_failure_attempts_every_handle_and_vetoes_summary(self):
        class Kernel:
            def __init__(self):self.calls=[]
            def CloseHandle(self,handle):self.calls.append(handle);return handle!=22
        native=object.__new__(M.WindowsEvidence);native.k=Kernel();native.handles=[11,22,33]
        with self.assertRaises(BaseExceptionGroup) as caught:native.__exit__(None,None,None)
        self.assertEqual(native.k.calls,[33,22,11])
        self.assertIn('CloseHandle',str(caught.exception.exceptions[0]))
        self.assertEqual(native.handles,[22])

    def test_native_validation_and_release_errors_both_survive(self):
        class Kernel:
            def __init__(self):self.calls=[]
            def CloseHandle(self,handle):
                self.calls.append(handle)
                if handle==22:raise OSError('injected release exception')
                return True
        original=M.Refusal('original validation failure')
        native=object.__new__(M.WindowsEvidence);native.k=Kernel();native.handles=[11,22,33]
        with self.assertRaises(BaseExceptionGroup) as caught:native.__exit__(type(original),original,None)
        self.assertIs(caught.exception.exceptions[0],original)
        self.assertEqual(native.k.calls,[33,22,11])
        self.assertIn('injected release exception',str(caught.exception.exceptions[1]))

    def test_partial_enter_failure_preserves_original_and_closes_prior_handles(self):
        class Partial(M.WindowsEvidence):
            def __init__(self,close_ok):
                self.handles=[];self.leaves={};self.calls=[];self.close_ok=close_ok;self.k=self
            def open(self,path,directory):
                if len(self.handles)==2:raise M.Refusal('partial enter original failure')
                handle=len(self.handles)+10;self.handles.append(handle);return handle
            def CloseHandle(self,handle):self.calls.append(handle);return self.close_ok or handle!=11
        for close_ok in (True,False):
            native=Partial(close_ok)
            with self.subTest(close_ok=close_ok),self.assertRaises(BaseException) as caught:native.__enter__()
            self.assertEqual(native.calls,[11,10])
            if close_ok:self.assertIsInstance(caught.exception,M.Refusal)
            else:
                self.assertIsInstance(caught.exception,BaseExceptionGroup)
                self.assertIn('partial enter original failure',str(caught.exception.exceptions[0]))

    def test_successful_validation_cannot_return_summary_after_close_failure(self):
        class Kernel:
            def CloseHandle(self,handle):return False
        class CloseFailureBackend(Backend):
            __exit__=M.WindowsEvidence.__exit__
        raw,pins,psha=fixture();backend=CloseFailureBackend(raw)
        backend.k=Kernel();backend.handles=[22]
        with self.assertRaises(BaseExceptionGroup):M.inspect_evidence(backend,pins=pins,protocol_sha=psha)

    def test_forbidden_path_probe_handle_is_released_with_all_other_handles(self):
        class Probe(M.WindowsEvidence):
            def __init__(self):self.k=self;self.handles=[11];self.calls=[]
            def __enter__(self):return self
            def CreateFileW(self,*args):return 44
            def CloseHandle(self,handle):self.calls.append(handle);return handle!=44
        backend=Probe()
        with self.assertRaises(BaseExceptionGroup) as caught:
            with backend:backend.boundary()
        self.assertEqual(backend.calls,[44,11])
        self.assertIsInstance(caught.exception.exceptions[0],M.Refusal)


if __name__=='__main__':unittest.main()
