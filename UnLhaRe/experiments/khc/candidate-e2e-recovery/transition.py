"""旧attemptのWindows binding生成とfence証拠読取。実再開の許可入口は未接続。"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import stat
import sys
import time
import types

HERE=Path(__file__).absolute().parent
READER_SHA='e8cd9f7b1147bed9bb69210a913404f380b6875df6d911becd8e2cf7fa9bc105'
FENCE_SHA='d0e055cab949bd9d22c1a329698a9a27f5f58bc994fff33b67182c6b65974c46'
MIN_REMAINING_NS=330_000_000_000
MISSING_INTEGRATIONS=('authenticated-windows-mac-live-bridge','native-lifecycle-and-cargo-locks',
    'durable-one-attempt-amendment','registered-new-worker-binding','native-start-deadline-binding')


class Refusal(ValueError):pass
class MissingIntegration(Refusal):pass


def require(ok,message):
    if not ok:raise Refusal(message)


def sha(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()


def load_pinned(path,expected_sha,name):
    """hash照合した同handleのbytesを直接compileし、再openによるimportを避ける。"""
    before=path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and 0<before.st_size<=65536 and
        not getattr(before,'st_file_attributes',0)&1024,'pinned source type/bound')
    with path.open('rb') as stream:
        first=os.fstat(stream.fileno());data=stream.read(65537);last=os.fstat(stream.fileno())
    identity=lambda s:(s.st_dev,s.st_ino,s.st_size,s.st_mtime_ns,s.st_nlink,s.st_mode)
    verified_sha=sha(data)
    require(identity(before)==identity(first)==identity(last) and verified_sha==expected_sha,'pinned source identity/hash')
    module=types.ModuleType(name);module.__file__=str(path)
    exec(compile(data,str(path),'exec'),module.__dict__)
    if name=='old_candidate_recovery_fence':
        # このロード済copyだけを結合。凍結source自体は変更せず再openも行わない。
        require(callable(getattr(module,'self_sha',None)),'frozen fence self SHA API')
        module.self_sha=lambda:verified_sha
    return module


READER=load_pinned(HERE/'reader.py',READER_SHA,'old_candidate_recovery_reader')
FENCE=load_pinned(HERE.parent/'mac-cdf-e2e-not-started-fence.py',FENCE_SHA,'old_candidate_recovery_fence')
PROOF_PATH=str(PureWindowsPath(READER.STATE).parent/'mac-cdf-e2e-not-started-observed.json')


def expected_reader_summary():
    """固定原証拠の期待内容。これ自体は現在のstateを読んだ証明ではない。"""
    sizes=dict(zip(READER.PATHS,(374,149,1092,692,488,458,3156,352)))
    return dict(schema=1,run_id=READER.RUN_ID,classification='failed-pending-closure-unknown',can_start=False,
        cleanup_allowed=False,historical_closure_proven=False,never_invoked_proven=False,
        original_cause_known=False,pending_preserved=True,claim_preserved=True,
        evidence=[dict(name=k,path=READER.PATHS[k],bytes=sizes[k],sha256=READER.PINS[k]) for k in READER.PATHS],
        declared_child_started=True,declared_child_pid=0,declared_child_exit_code=None,
        deadline_elapsed_seconds=373.0308542)


def expected_binding():
    return dict(schema=1,kind='old-candidate-e2e-windows-binding-v1',old_run_id=READER.RUN_ID,
        reader_sha256=READER_SHA,fence_controller_sha256=FENCE_SHA,
        old_endpoint_sha256=FENCE.OLD_ENDPOINT,old_protocol_sha256=FENCE.OLD_PROTOCOL,
        old_worker_sha256=FENCE.OLD_WORKER,windows_evidence=expected_reader_summary(),
        can_start=False,cleanup_allowed=False,historical_closure_proven=False,
        past_start_status='unknown',windows_job_status='unknown',third_party_deletion_status='unknown')


def validate_binding(data):
    require(type(data) is bytes and 0<len(data)<=65536,'binding bytes bound')
    try:value=READER.parse(data)
    except READER.Refusal as error:raise Refusal('invalid Windows binding JSON') from error
    # canonical bytes全体を比較し、bool/intの等値や未知fieldも受け付けない。
    require(canonical(value)==data and data==canonical(expected_binding()),'fixed Windows binding mismatch')
    return value


def build_windows_binding():
    observed=READER.inspect_evidence()
    require(canonical(observed)==canonical(expected_reader_summary()),'fixed old evidence observation differs')
    return canonical(expected_binding())


def verify_fence_content(binding,proof,expected_proof_sha):
    validate_binding(binding)
    require(type(expected_proof_sha) is str and FENCE.sha(expected_proof_sha) and
        type(proof) is bytes and 0<len(proof)<=65536 and sha(proof)==expected_proof_sha,'fixed fence proof SHA/bound')
    value=FENCE.parse_evidence(proof)
    summary=FENCE.validate_evidence(value,sha(binding))
    require(summary['evidence_sha256']==expected_proof_sha,'canonical fence proof identity')
    return dict(summary,scope='fence-content-only',can_start=False,cleanup_allowed=False,
        historical_closure_proven=False,missing_integrations=list(MISSING_INTEGRATIONS))


class ProofFile(READER.WindowsEvidence):
    """将来回収される固定名proofのread-only呼出側。proof作成や転送はしない。"""
    def __enter__(self):
        try:
            for p in reversed(PureWindowsPath(PROOF_PATH).parents):self.open(str(p),True)
            self.leaves['proof']=self.open(PROOF_PATH,False)
            return self
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise


def read_fence_content(expected_proof_sha):
    # 現時点の旧Windows証拠も再読する。既存stateは一切変更しない。
    binding=build_windows_binding()
    with ProofFile() as source:
        identity=source.identity('proof');proof=source.read('proof')
        summary=verify_fence_content(binding,proof,expected_proof_sha)
        require(source.identity('proof')==identity and source.read('proof')==proof,'proof changed during read')
        require(build_windows_binding()==binding,'Windows evidence changed during proof verification')
        return summary


def assess_live_draft(binding,proof,proof_sha,*,live_ops=None,lock=None,deadline_ns,clock=time.monotonic_ns):
    """認証bridge/lockのadapter契約だけを検証する。返却物を実行許可には使えない。"""
    require(live_ops is not None and lock is not None,'live fence and lock integration required')
    require(type(deadline_ns) is int and deadline_ns>0,'same-process monotonic deadline required')
    previous=None
    def deadline():
        nonlocal previous
        now=clock()
        require(type(now) is int and now>=0 and (previous is None or now>=previous) and
            deadline_ns-now>=MIN_REMAINING_NS,'recovery deadline insufficient/clock reversed')
        previous=now
    deadline()
    with lock as held:
        require(held is not None and held.check() is True,'recovery lock not held')
        deadline()
        require(build_windows_binding()==binding,'old Windows evidence changed')
        content=verify_fence_content(binding,proof,proof_sha)
        first=FENCE.verify_live(live_ops,proof,sha(binding))
        require(first['fence_live_verified'] is True,'fence live verification failed')
        deadline()
        require(held.check() is True,'recovery lock lost')
        require(build_windows_binding()==binding,'old Windows evidence changed after live check')
        second=FENCE.verify_live(live_ops,proof,sha(binding))
        require(first==second,'live proof changed')
        require(held.check() is True,'recovery lock lost before return')
        deadline()
        return dict(content,scope='adapter-preconditions-only',adapter_fence_live_verified=True,
            fence_live_verified=False,windows_binding_sha256=sha(binding),can_start=False)


def authorize_new_execution():
    raise MissingIntegration('new execution disabled: '+', '.join(MISSING_INTEGRATIONS))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    action=parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--binding',action='store_true')
    action.add_argument('--verify-fence',action='store_true')
    parser.add_argument('--proof-sha')
    args=parser.parse_args()
    if args.binding:
        require(args.proof_sha is None,'proof SHA only applies to fixed proof reading')
        sys.stdout.buffer.write(build_windows_binding())
    else:
        require(args.proof_sha is not None,'explicit fixed proof SHA required')
        sys.stdout.buffer.write(canonical(read_fence_content(args.proof_sha)))


if __name__=='__main__':main()
