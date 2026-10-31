#!/usr/bin/env python3
"""固定CDF候補を一度だけビルドする。旧記録と入力を保持する。"""
import argparse
import base64
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import time

HERE=Path(__file__).absolute().parent
ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
SOURCE_PARENT=ROOT/'cdf-chooser-candidate-20261027'
SOURCE=SOURCE_PARENT/'source'
TARGET=ROOT/'cargo-target/cdf-chooser-candidate-20261027'
BINARY=TARGET/'aarch64-apple-darwin/release/unlhare-cli'
SOURCE_ZIP=ROOT/'downloads/mac-cdf-chooser-ablation-source-36d904e0.zip'
PROTOCOL='khc-mac-cdf-candidate-build-v1'
PREFIX='mac-cdf-candidate-build'
PROTOCOL_PATH=ROOT/'journal/mac-cdf-candidate-build-protocol.json'
BASE_SHA='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f'
SOURCE_SHA='36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05'
MANIFEST_SHA='d711acf1989b34f5043d5a7bae68ea95c2d51a72f602ca6ca27124e5ebffc7e2'
OLD_SHA='da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'
RETRY_SHA='771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe'
SNAPSHOT_SHA='80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f'
MAX_JSON=65536
JOURNAL_MARGIN=8*65536
PRESERVED={
    'cargo-target/aarch64-apple-darwin/release/unlhare-cli':'5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629',
    'cargo-target/decode-phase-20261027/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic':'4e68a6a54d5b9fec55c4507c4b5c3588b8cf8e10c3425615541cd91a3103e742',
    'tmp/mac-canterbury-continuous-reference-20261027/00-archive.khc':'234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee',
    'journal/mac-canterbury-continuous-reference.terminal.json':'88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e',
    'journal/mac-decode-phase-retry.terminal.json':'b5e6efbefc39bafa9f2d21f7ce33074c6b26f3cff0af44b2a5159fc64fca3b0d',
    'journal/mac-decode-phase-retry.closure.json':'163ea2b3c4b9998d7f0519245c0447ba4df935b249326e4417f97264d0e53a36',
    'journal/mac-khc-decode-phase-run-20261027.terminal.json':'cc6a0f45af705522009bd727140f96e77af085a0aeb46f1a7b7e2247fc1bd78e'}

def require(ok,message):
    if not ok:raise ValueError(message)
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None
def self_sha():return digest(Path(__file__).read_bytes())
def load(path,name,expected):
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink==1 and
        path.stat().st_size<=131072 and digest(path.read_bytes())==expected,'frozen dependency SHA/type')
    spec=importlib.util.spec_from_file_location(name,str(path));module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module);return module
def old_controller():return load(HERE/'mac-decode-phase-build.py','cdf_frozen_phase',OLD_SHA)
def retry_controller():return load(HERE/'mac-decode-phase-retry.py','cdf_frozen_retry',RETRY_SHA)

def expected_protocol(controller_sha,snapshot_sha):
    require(sha(controller_sha) and snapshot_sha==SNAPSHOT_SHA,'dependency hashes')
    cargo=ROOT/'tools/rust/bin/cargo'
    return dict(schema=1,protocol=PROTOCOL,purpose='cdf-chooser-candidate',task='goal-restore-20261019',
        host='m3mb14',root=ROOT.as_posix(),source_directory=SOURCE.as_posix(),target=TARGET.as_posix(),
        binary_path=BINARY.as_posix(),source_sha256=SOURCE_SHA,source_manifest_sha256=MANIFEST_SHA,
        base_source_sha256=BASE_SHA,controller_sha256=controller_sha,snapshot_sha256=snapshot_sha,
        supervisor_sha256='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30',
        setup_sha256='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1',
        build_verifier_sha256='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb',
        phase_controller_sha256=OLD_SHA,retry_controller_sha256=RETRY_SHA,preserved_sha256=PRESERVED,
        toolchain='1.99.1-aarch64-apple-darwin',cargo_command=[cargo.as_posix(),'build','--release','--offline',
            '--locked','--target','aarch64-apple-darwin','--lib','--bin','unlhare-cli','--example',
            'khc_spatial_mdl_e2e','-j','1','--target-dir',TARGET.as_posix()],
        cargo_timeout_seconds=300,native_final_seconds=350,ssh_timeout_seconds=380,
        additional_target_max_bytes=536870912,ordinary_max_bytes=1610612736,cargo_max_bytes=1073741824,
        total_max_bytes=2684354560,additional_attempts=1,superiority_decision_allowed=False)

def validate_protocol(value,controller_sha,snapshot_sha):
    require(type(value) is dict and canonical(value)==canonical(expected_protocol(controller_sha,snapshot_sha)),
            'candidate fixed protocol mismatch')

def validate_source_snapshot(base,new):
    old=old_controller()
    old_records,old_files=old.snapshot(base,BASE_SHA,78)
    records,files=old.snapshot(new,SOURCE_SHA,78,MANIFEST_SHA)
    require(set(files)==set(old_files),'candidate file set differs from baseline')
    changed={name for name in files if files[name]!=old_files[name]}
    require(changed=={'src/khc/block/packet.rs'} and sum(files[n]==old_files[n] for n in files)==77,
            'candidate must change only packet.rs')
    return old_records,records,files

def enforce_preparation_deadline(result,began,*,clock=time.monotonic):
    result=dict(result,runtime_seconds=max(result['runtime_seconds'],clock()-began))
    if result['status']=='done' and result['runtime_seconds']>350:
        result.update(status='failed',exit=1,error='native terminal preparation deadline exceeded')
    return result

def parse(data):
    require(type(data) is bytes and 0<len(data)<=MAX_JSON,'JSON bytes/bound')
    value=old_controller().parse(data)
    require(canonical(value)==data,'canonical JSON required')
    return value

def verify_protocol_bytes(data,expected_sha):
    require(sha(expected_sha) and digest(data)==expected_sha,'protocol raw SHA')
    load(HERE/'mac-cdf-candidate-snapshot.py','cdf_protocol_snapshot',SNAPSHOT_SHA)
    value=parse(data);validate_protocol(value,self_sha(),SNAPSHOT_SHA)
    return dict(schema=1,protocol=PROTOCOL,protocol_sha256=expected_sha,source_sha256=SOURCE_SHA,
        controller_sha256=value['controller_sha256'],purpose=value['purpose'],verified=True)

def validate_receipt(value,protocol):
    validate_protocol(protocol,protocol['controller_sha256'],SNAPSHOT_SHA)
    keys={'schema','protocol','purpose','source_sha256','controller_sha256','protocol_sha256','root','target',
        'cargo_command','status','exit','runtime_seconds','cargo_runtime_seconds','binary_sha256','wait_confirmed',
        'group_absent','postchecks_ok','closure_proof','closure_sha256','error','binary_path'}
    require(type(value) is dict and set(value)==keys,'receipt exact schema')
    for key in ('schema','protocol','purpose','source_sha256','controller_sha256','root','target','cargo_command'):
        require(canonical(value[key])==canonical(protocol[key]),'receipt identity: '+key)
    require(value['protocol_sha256']==digest(canonical(protocol)) and value['binary_path']==BINARY.as_posix(),
        'receipt protocol/binary binding')
    require(type(value['status']) is str and value['status'] in ('done','failed') and type(value['exit']) is int,
        'receipt status/exit')
    require(all(type(value[k]) is bool for k in ('wait_confirmed','group_absent','postchecks_ok')),'receipt flags')
    for key in ('runtime_seconds','cargo_runtime_seconds'):
        require(type(value[key]) in (int,float) and math.isfinite(value[key]) and value[key]>=0,'receipt elapsed')
    proof=value['closure_proof'];closed=False
    if proof is not None:
        require(type(proof) is dict and sha(value['closure_sha256']) and
            digest(canonical(proof))==value['closure_sha256'],'closure raw SHA')
        closed=old_controller().FS.validate_closure(proof,proof.get('pid'),proof.get('sequence'))
    else:require(value['closure_sha256'] is None,'missing closure SHA')
    require(value['wait_confirmed'] is bool(closed) and value['group_absent'] is bool(closed),'closure flags')
    if value['binary_sha256'] is not None:require(sha(value['binary_sha256']),'binary SHA')
    if value['status']=='done':
        require(value['exit']==0 and value['error'] is None and closed and value['postchecks_ok'] and
            sha(value['binary_sha256']) and proof['primary']['kind']=='exit' and
            proof['primary']['returncode']==0 and proof['actual_returncode']==0 and
            value['runtime_seconds']<=350 and value['cargo_runtime_seconds']<=300,'done eligibility')
    else:require(value['exit']==1 and type(value['error']) is str and 0<len(value['error'])<=4096,'failed receipt')
    return dict(schema=1,protocol=PROTOCOL,protocol_sha256=digest(canonical(protocol)),source_sha256=SOURCE_SHA,
        controller_sha256=protocol['controller_sha256'],purpose=protocol['purpose'],verified=True,
        receipt_sha256=digest(canonical(value)),binary_sha256=value['binary_sha256'],
        closure_sha256=value['closure_sha256'],status=value['status'],exit=value['exit'],cleanup_allowed=bool(closed))

def verify_receipt_bytes(data,protocol_data):
    verify_protocol_bytes(protocol_data,digest(protocol_data))
    return validate_receipt(parse(data),parse(protocol_data))

def decode_wire(value):
    require(type(value) is str and 0<len(value)<=((MAX_JSON+2)//3)*4,'wire bound')
    data=base64.b64decode(value,validate=True);require(len(data)<=MAX_JSON,'wire decoded bound');return data

def preserved_inputs(setup,old):
    for relative,expected in PRESERVED.items():
        path=ROOT/relative;setup.checked_path(path)
        maximum=64*1024**2 if relative.startswith(('cargo-target/','tmp/')) else MAX_JSON
        old.read_native(path,maximum,expected,artifact='decode-phase-20261027/' in relative)
    # The old verifier remains immutable and validates the whole original chain.
    retry=retry_controller()
    amendment_path=ROOT/'journal/mac-decode-phase-retry-amendment.json'
    setup.checked_path(amendment_path)
    amendment_data=old.read_native(amendment_path,MAX_JSON)
    amendment_sha=digest(amendment_data)
    _,_,_,_,amendment,protocol=retry.native_context(amendment_sha)
    receipt=old.read_native(ROOT/'journal/mac-decode-phase-retry.terminal.json',MAX_JSON,
        PRESERVED['journal/mac-decode-phase-retry.terminal.json'])
    summary=retry.validate_retry_receipt(receipt,amendment,amendment_sha,old,protocol)
    closure=old.read_native(ROOT/'journal/mac-decode-phase-retry.closure.json',MAX_JSON,
        PRESERVED['journal/mac-decode-phase-retry.closure.json'])
    require(summary['status']=='done' and summary['cleanup_allowed'] is True and
        summary['binary_sha256']==PRESERVED['cargo-target/decode-phase-20261027/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic'] and
        canonical(parse(receipt)['closure_proof'])==closure,'original retry evidence not closed/successful')

def native_inputs(setup,old,protocol):
    setup.checked_path(Path(__file__));old.read_native(Path(__file__),131072,protocol['controller_sha256'])
    for path,expected in ((HERE/'mac-decode-phase-build.py',OLD_SHA),
                          (HERE/'mac-decode-phase-retry.py',RETRY_SHA),
                          (HERE/'mac-cdf-candidate-snapshot.py',SNAPSHOT_SHA)):
        setup.checked_path(path);old.read_native(path,131072,expected)
    preserved_inputs(setup,old)
    base_path=ROOT/'downloads/source.zip';setup.checked_path(base_path);setup.checked_path(SOURCE_ZIP)
    base=old.read_native(base_path,8*1024**2,BASE_SHA)
    derived=old.read_native(SOURCE_ZIP,8*1024**2,SOURCE_SHA)
    old_records,records,files=validate_source_snapshot(base,derived)
    verifier=old.build_verifier();old.check_source_layout(ROOT,old_records);verifier.verify_source(ROOT,old_records)
    verifier.reject_cargo_config(SOURCE,ROOT/'cargo-home')
    verifier.reject_cargo_config(ROOT/'source',ROOT/'cargo-home')
    return old_records,records,files,old.environment_profile(setup),old.tool_hashes(setup)

def candidate_environment(profile,base):
    require(type(base) is dict and type(profile) is dict and type(profile.get('environment')) is dict,
        'baseline environment')
    values=dict(base);values.update(profile['environment'])
    values.update(RUSTC=(ROOT/'tools/rust/bin/rustc').as_posix(),
        RUSTDOC=(ROOT/'tools/rust/bin/rustdoc').as_posix(),RUSTUP_AUTO_INSTALL='0',
        CARGO_INCREMENTAL='0',CARGO_BUILD_JOBS='1')
    # 比較元との差は書込み先の隔離のみ。Cargo設定と元sourceは変更しない。
    values['CARGO_TARGET_DIR']=TARGET.as_posix()
    for key in ('TEMP','TMP','TMPDIR'):values[key]=(TARGET/'tmp').as_posix()
    return values

def native_context(protocol_sha):
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(Path(__file__).absolute()==ROOT/'tools/mac-cdf-candidate-build.py','native controller location')
    old=old_controller();setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=old.load(setup_path,'cdf_candidate_setup',old.SETUP_SHA);setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT,private=True);setup.checked_path(ROOT/'journal',private=True);setup.checked_path(PROTOCOL_PATH)
    protocol_data=old.read_native(PROTOCOL_PATH,MAX_JSON,protocol_sha);verify_protocol_bytes(protocol_data,protocol_sha)
    protocol=parse(protocol_data);snapshot=load(HERE/'mac-cdf-candidate-snapshot.py','cdf_candidate_snapshot',SNAPSHOT_SHA)
    return old,setup,protocol,snapshot

def admission(snapshot,deadline_ns,extra):
    value=snapshot.snapshot(ROOT,deadline_ns=deadline_ns)
    fs=os.statvfs(str(ROOT))
    return snapshot.validate_admission(value,extra_ordinary=extra,free_bytes=fs.f_bavail*fs.f_frsize)

def extract_source(old,records,files):
    SOURCE_PARENT.mkdir(mode=0o700);SOURCE.mkdir(mode=0o700)
    for record in records:
        path=SOURCE/record['path'];path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        with path.open('xb') as stream:stream.write(files[record['path']]);stream.flush();os.fsync(stream.fileno())
    old.check_source_layout(SOURCE_PARENT,records);old.build_verifier().verify_source(SOURCE_PARENT,records)

def save_started(old,path,value):
    return old.write_native(path,value)

def create_candidate_target():
    TARGET.mkdir(mode=0o700)
    (TARGET/'tmp').mkdir(mode=0o700)

def validate_candidate_target(setup):
    setup.checked_path(TARGET,private=True)
    setup.checked_path(TARGET/'tmp',private=True)

def helper_main(parent_pid,protocol_sha):
    require(type(parent_pid) is int and parent_pid>1 and os.getppid()==parent_pid,'Cargo helper parent')
    old,setup,protocol,_=native_context(protocol_sha)
    started=parse(old.read_native(ROOT/'journal'/(PREFIX+'.started.json'),MAX_JSON))
    require(started['endpoint_pid']==parent_pid and started['protocol_sha256']==protocol_sha and
        started['controller_sha256']==self_sha(),'Cargo helper started binding')
    _,records,_,profile,tools=native_inputs(setup,old,protocol)
    require(tools==started['tool_sha256'] and Path.cwd()==SOURCE and not BINARY.exists() and not BINARY.is_symlink(),
        'Cargo helper source/tools/binary context')
    validate_candidate_target(setup)
    old.check_source_layout(SOURCE_PARENT,records);old.build_verifier().verify_source(SOURCE_PARENT,records)
    env=candidate_environment(profile,setup.child_environment(ROOT))
    def runner(command):
        proc=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True)
        stdout,stderr=proc.communicate(timeout=3)
        return dict(returncode=proc.returncode,stdout=stdout,stderr=stderr)
    def save_versions(versions):
        require(old.tool_hashes(setup)==tools,'tools changed during versions')
        old.write_native(ROOT/'journal'/(PREFIX+'.versions.json'),dict(schema=1,versions=versions,tool_sha256=tools,
            protocol_sha256=protocol_sha,controller_sha256=self_sha()))
    old.cargo_transition(protocol['cargo_command'],env,runner,os.execvpe,save_versions)
    raise RuntimeError('Cargo exec unexpectedly returned')

def native_main(protocol_sha):
    old,setup,protocol,snapshot=native_context(protocol_sha)
    retry=retry_controller();os.umask(0o077)
    prefix=ROOT/'journal'/PREFIX;started=Path(str(prefix)+'.started.json');terminal=Path(str(prefix)+'.terminal.json')
    for suffix in ('.started.json','.terminal.json','.terminal-deadline.json','.closure.json','.versions.json'):
        path=Path(str(prefix)+suffix)
        require(not path.exists() and not path.is_symlink(),'candidate already attempted or journal occupied')
    began=time.monotonic();deadline_ns=time.monotonic_ns()+350_000_000_000
    runtime=0.;proof=None;error=None;binary_sha=None;postchecks=False;status='failed'
    old_records=records=tools=None;started_here=False
    original_admit,original_environment=setup.admit,setup.child_environment
    try:
        require(not SOURCE_PARENT.exists() and not SOURCE_PARENT.is_symlink() and
            not TARGET.exists() and not TARGET.is_symlink() and not BINARY.exists() and not BINARY.is_symlink(),
            'candidate source/target/binary must be unused')
        old_records,records,files,profile,tools=native_inputs(setup,old,protocol)
        admission(snapshot,deadline_ns,sum(r['bytes'] for r in records)+JOURNAL_MARGIN)
        save_started(old,started,dict(schema=1,protocol=PROTOCOL,protocol_sha256=protocol_sha,
            controller_sha256=self_sha(),source_sha256=SOURCE_SHA,endpoint_pid=os.getpid(),
            parent_pid=os.getppid(),tool_sha256=tools,started_unix_ns=time.time_ns()))
        started_here=True
        extract_source(old,records,files);create_candidate_target()
        cargo_deadline_ns=deadline_ns
        def guard(_root,extra=0):
            def source_check():
                old.check_source_layout(ROOT,old_records);old.check_source_layout(SOURCE_PARENT,records)
            return retry.guarded_admission(cargo_deadline_ns,source_check,
                lambda deadline:admission(snapshot,deadline,extra+JOURNAL_MARGIN))
        setup.admit=guard
        setup.child_environment=lambda root:candidate_environment(profile,original_environment(root))
        setup.LOG_LIMIT=16384
        supervisor=old.FS.Supervisor(ROOT,support=setup)
        cargo_begin_ns=time.monotonic_ns();cargo_begin=cargo_begin_ns/1_000_000_000
        limit=min(300.,350.-45.-(cargo_begin-began))
        cargo_deadline_ns=retry.cargo_guard_deadline(cargo_begin_ns,limit,deadline_ns)
        command=setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(Path(__file__)),
            '--cargo-helper-parent-pid',str(os.getpid()),'--protocol-sha',protocol_sha]
        runtime,proof,primary=old.supervise_cargo(supervisor,command,SOURCE,limit,lambda:guard(ROOT),
            persist=lambda value:old.write_native(Path(str(prefix)+'.closure.json'),value))
        runtime=max(runtime,time.monotonic()-cargo_begin)
        require(primary is None,primary)
        require(runtime<=300 and proof is not None and
            old.FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')) and
            proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and
            proof['actual_returncode']==0,'Cargo normal exit/group closure')
        setup.checked_path(BINARY);require(os.access(BINARY,os.X_OK),'candidate binary executable')
        binary_sha=digest(old.read_native(BINARY,64*1024**2,artifact=True));status='done'
    except BaseException as failure:error=(type(failure).__name__+': '+str(failure))[:2048]
    finally:setup.admit,setup.child_environment=original_admit,original_environment
    require(started_here,error or 'candidate start not recorded')
    try:
        old_after,new_after,_,_,tools_after=native_inputs(setup,old,protocol)
        require(old_records==old_after and records==new_after and tools==tools_after,'post-build source/tool identity')
        old.check_source_layout(SOURCE_PARENT,records);old.build_verifier().verify_source(SOURCE_PARENT,records)
        admission(snapshot,deadline_ns,JOURNAL_MARGIN)
        if status=='done':
            require(digest(old.read_native(BINARY,64*1024**2,artifact=True))==binary_sha,'candidate binary changed')
            versions=parse(old.read_native(Path(str(prefix)+'.versions.json'),MAX_JSON))
            require(versions['tool_sha256']==tools and versions['protocol_sha256']==protocol_sha and
                versions['controller_sha256']==self_sha(),'version binding')
        require(time.monotonic_ns()<=deadline_ns,'native finalization deadline');postchecks=True
    except BaseException as failure:
        status='failed';error=old.bounded_errors(error,type(failure).__name__+': '+str(failure))
    closed=bool(proof is not None and old.FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')))
    result=dict(schema=1,protocol=PROTOCOL,purpose=protocol['purpose'],source_sha256=SOURCE_SHA,
        controller_sha256=protocol['controller_sha256'],protocol_sha256=protocol_sha,root=protocol['root'],
        target=protocol['target'],cargo_command=protocol['cargo_command'],status=status,exit=0 if status=='done' else 1,
        runtime_seconds=time.monotonic()-began,cargo_runtime_seconds=runtime,binary_sha256=binary_sha,
        wait_confirmed=closed,group_absent=closed,postchecks_ok=postchecks,closure_proof=proof,
        closure_sha256=digest(canonical(proof)) if proof is not None else None,error=error,binary_path=BINARY.as_posix())
    result=enforce_preparation_deadline(result,began)
    validate_receipt(result,protocol);terminal_sha=old.write_native(terminal,result)
    if time.monotonic_ns()>deadline_ns:
        result.update(status='failed',exit=1,postchecks_ok=False,runtime_seconds=time.monotonic()-began,
            error=old.bounded_errors(result['error'],'native terminal persistence exceeded 350 seconds'))
        validate_receipt(result,protocol)
        temporary=Path(str(prefix)+'.terminal-deadline.json')
        old.read_native(terminal,MAX_JSON,terminal_sha);old.write_native(temporary,result)
        old.read_native(terminal,MAX_JSON,terminal_sha);os.replace(temporary,terminal)
        old.read_native(terminal,MAX_JSON,digest(canonical(result)))
    sys.stdout.buffer.write(canonical(result));return result['exit']

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protocol-sha');parser.add_argument('--protocol-base64')
    parser.add_argument('--verify-protocol-base64');parser.add_argument('--verify-receipt-base64')
    parser.add_argument('--cargo-helper-parent-pid',type=int)
    args=parser.parse_args()
    if args.verify_protocol_base64:
        require(args.protocol_sha and not args.protocol_base64 and not args.verify_receipt_base64 and
            args.cargo_helper_parent_pid is None,'protocol verifier arguments')
        result=verify_protocol_bytes(decode_wire(args.verify_protocol_base64),args.protocol_sha)
    elif args.verify_receipt_base64:
        require(args.protocol_base64 and not args.protocol_sha and args.cargo_helper_parent_pid is None,
            'receipt verifier arguments')
        result=verify_receipt_bytes(decode_wire(args.verify_receipt_base64),decode_wire(args.protocol_base64))
    else:
        require(args.protocol_sha and not args.protocol_base64,'native arguments')
        if args.cargo_helper_parent_pid is not None:return helper_main(args.cargo_helper_parent_pid,args.protocol_sha)
        return native_main(args.protocol_sha)
    sys.stdout.buffer.write(canonical(result));return 0

if __name__=='__main__':sys.exit(main())
