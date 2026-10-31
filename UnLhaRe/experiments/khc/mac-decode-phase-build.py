#!/usr/bin/env python3
"""凍結CLIを置換せず、別識別子と固定資源枠で診断exampleだけをビルドする。"""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import stat
import subprocess
import sys
import time
import zipfile

HERE=Path(__file__).absolute().parent
ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
SOURCE_PARENT=ROOT/'decode-phase-20261027'
SOURCE=SOURCE_PARENT/'source'
TARGET=ROOT/'cargo-target/decode-phase-20261027'
CARGO=ROOT/'tools/rust/bin/cargo'
BINARY=TARGET/'aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic'
BASE_SHA='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f'
CLI_SHA='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629'
ARCHIVE_SHA='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee'
REFERENCE_SHA='88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e'
FS_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
SETUP_SHA='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
BUILD_SHA='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb'
PROTOCOL='khc-mac-decode-phase-build-v1'
PURPOSE='decode-phase-diagnostic'
MAX_JSON=65536
PREFIX='mac-decode-phase-build'
SOURCE_ZIP=ROOT/'downloads/mac-decode-phase-source.zip'
PROTOCOL_PATH=ROOT/'journal/mac-decode-phase-build-protocol.json'
FORMATTED_SHA='1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55'
FORMATTED_MANIFEST_SHA='5bfea92de150219d371906813cba9db9471e9de21e7155951b950fd15857ebc5'
GENERATOR_SHA='42eccedf41fef3846797b64a19a2009684138aa281316ab4e519073ed269ac31'
ENVIRONMENT_SHA='4febd21b0ab814a62efb12c006c91ab5c9d4776cdd5c3d8a03e7f8c3213769e3'
CHANGED_FILES=('src/khc/mod.rs','src/khc/block/mod.rs','src/khc/spatial.rs')
ADDED_FILES=('src/khc/phase_diagnostic.rs','examples/khc_archive_phase_diagnostic.rs')
JOURNAL_MARGIN=8*65536
SDK_PATH='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
XCODE_LINKER_PATH='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'

def require(ok,message):
    if not ok:raise ValueError(message)

def digest(data):return hashlib.sha256(data).hexdigest()

def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode('utf-8')

def parse(data):
    def pairs(items):
        value={}
        for key,item in items:
            require(key not in value,'duplicate JSON key');value[key]=item
        return value
    return json.loads(data,object_pairs_hook=pairs,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite JSON')))

def sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None

def self_sha():return digest(Path(__file__).read_bytes())

def load(path,name,expected):
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink==1 and
        path.stat().st_size<=131072 and digest(path.read_bytes())==expected,'frozen dependency SHA/type')
    spec=importlib.util.spec_from_file_location(name,str(path));value=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value);return value

FS=load(HERE/'mac-finite-supervisor.py','phase_build_finite_supervisor',FS_SHA)

def expected_protocol(source_sha,manifest_sha,generator_sha,controller_sha):
    require(all(sha(x) for x in (source_sha,manifest_sha,generator_sha,controller_sha)),'protocol hashes')
    return dict(schema=1,protocol=PROTOCOL,purpose=PURPOSE,task='goal-restore-20261019',host='m3mb14',
        root=ROOT.as_posix(),base_source_sha256=BASE_SHA,source_sha256=source_sha,
        source_manifest_sha256=manifest_sha,controller_sha256=controller_sha,generator_sha256=generator_sha,
        source_directory=SOURCE.as_posix(),target=TARGET.as_posix(),toolchain='1.99.1-aarch64-apple-darwin',
        cargo_command=[CARGO.as_posix(),'build','--locked','--offline','--release','--example',
            'khc_archive_phase_diagnostic','--target','aarch64-apple-darwin','-j','1','--target-dir',TARGET.as_posix()],
        cargo_timeout_seconds=300,native_final_seconds=350,ssh_timeout_seconds=380,
        additional_target_max_bytes=536870912,ordinary_max_bytes=1610612736,cargo_max_bytes=1073741824,
        total_max_bytes=2684354560,baseline_cli_sha256=CLI_SHA,archive_sha256=ARCHIVE_SHA,
        reference_terminal_sha256=REFERENCE_SHA,supervisor_sha256=FS_SHA,setup_sha256=SETUP_SHA,
        build_verifier_sha256=BUILD_SHA,superiority_decision_allowed=False)

def validate_protocol(value,controller_sha):
    require(type(value) is dict,'protocol object')
    expected=expected_protocol(value.get('source_sha256'),value.get('source_manifest_sha256'),
        value.get('generator_sha256'),controller_sha)
    require(canonical(value)==canonical(expected),'fixed diagnostic protocol mismatch')

def validate_receipt(value,protocol):
    validate_protocol(protocol,protocol['controller_sha256'])
    keys={'schema','protocol','purpose','source_sha256','controller_sha256','protocol_sha256','root','target',
        'cargo_command','status','exit','runtime_seconds','cargo_runtime_seconds','binary_sha256','wait_confirmed',
        'group_absent','postchecks_ok','closure_proof','closure_sha256','error','binary_path'}
    require(type(value) is dict and set(value)==keys,'receipt exact schema')
    for key in ('schema','protocol','purpose','source_sha256','controller_sha256','root','target','cargo_command'):
        require(canonical(value[key])==canonical(protocol[key]),'receipt identity: '+key)
    require(value['protocol_sha256']==digest(canonical(protocol)) and value['binary_path']==BINARY.as_posix(),
        'receipt protocol/binary binding')
    require(value['status'] in ('done','failed') and type(value['status']) is str and type(value['exit']) is int,
        'receipt status/exit type')
    require(all(type(value[k]) is bool for k in ('wait_confirmed','group_absent','postchecks_ok')),'receipt flags')
    for key in ('runtime_seconds','cargo_runtime_seconds'):
        require(type(value[key]) in (int,float) and math.isfinite(value[key]) and value[key]>=0,'receipt elapsed')
    proof=value['closure_proof'];closed=False
    if proof is not None:
        require(type(proof) is dict and sha(value['closure_sha256']) and
            digest(canonical(proof))==value['closure_sha256'],'closure raw SHA')
        closed=FS.validate_closure(proof,proof.get('pid'),proof.get('sequence'))
    else:require(value['closure_sha256'] is None,'missing closure has SHA')
    require(value['wait_confirmed'] is bool(closed) and value['group_absent'] is bool(closed),
        'closure flags disagree with original evidence')
    if value['binary_sha256'] is not None:require(sha(value['binary_sha256']),'binary SHA type')
    if value['status']=='done':
        require(value['exit']==0 and value['error'] is None and closed and value['postchecks_ok'] and
            sha(value['binary_sha256']) and proof['primary']['kind']=='exit' and
            proof['primary']['returncode']==0 and proof['actual_returncode']==0 and
            value['runtime_seconds']<=350 and value['cargo_runtime_seconds']<=300,'done eligibility')
    else:
        require(value['exit']==1 and type(value['error']) is str and 0<len(value['error'])<=4096,'failed receipt')
    return dict(schema=1,protocol=PROTOCOL,protocol_sha256=digest(canonical(protocol)),
        source_sha256=protocol['source_sha256'],controller_sha256=protocol['controller_sha256'],
        purpose=PURPOSE,verified=True,receipt_sha256=digest(canonical(value)),binary_sha256=value['binary_sha256'],
        closure_sha256=value['closure_sha256'],status=value['status'],exit=value['exit'],cleanup_allowed=bool(closed))

def verify_protocol_bytes(data,expected_sha,allow_noncanonical=False):
    require(type(data) is bytes and 0<len(data)<=MAX_JSON and sha(expected_sha) and digest(data)==expected_sha,
        'protocol bytes/SHA')
    value=parse(data);require(allow_noncanonical or canonical(value)==data,'canonical protocol required')
    validate_protocol(value,self_sha())
    return dict(schema=1,protocol=PROTOCOL,protocol_sha256=expected_sha,source_sha256=value['source_sha256'],
        controller_sha256=value['controller_sha256'],purpose=PURPOSE,verified=True)

def verify_receipt_bytes(data,protocol_data):
    require(type(data) is bytes and 0<len(data)<=MAX_JSON,'receipt bytes bound')
    verify_protocol_bytes(protocol_data,digest(protocol_data))
    value=parse(data);require(canonical(value)==data,'canonical receipt required')
    return validate_receipt(value,parse(protocol_data))

def decode_wire(value):
    require(type(value) is str and 0<len(value)<=((MAX_JSON+2)//3)*4,'base64 wire bound')
    data=base64.b64decode(value,validate=True);require(len(data)<=MAX_JSON,'base64 decoded bound');return data

def build_verifier():
    return load(HERE/'mac-native-build.py','phase_build_source_verifier',BUILD_SHA)

def snapshot(data,expected_sha,count,manifest_sha=None):
    require(type(data) is bytes and len(data)<=8*1024**2 and digest(data)==expected_sha,'source ZIP SHA/bound')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members=archive.infolist()
        require(len(members)==count+1 and len({m.filename for m in members})==len(members) and
            sum(m.file_size for m in members)<=8*1024**2+MAX_JSON,'source ZIP expanded count/bound')
        require(all(not m.is_dir() and not m.flag_bits&1 and m.compress_type in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED)
            and stat.S_IFMT(m.external_attr>>16) in (0,stat.S_IFREG) for m in members),'source ZIP member type')
        entry=archive.getinfo('snapshot-manifest.json');require(entry.file_size<=MAX_JSON,'source manifest bound')
        manifest=archive.read(entry)
        require(manifest_sha is None or digest(manifest)==manifest_sha,'source manifest SHA')
        records=parse(manifest);require(type(records) is list and len(records)==count,'source record count')
        names=build_verifier().validate_source_manifest(records)
        require(set(archive.namelist())==set(names)|{'snapshot-manifest.json'},'source exact ZIP file set')
        files={}
        for record in records:
            body=archive.read(record['path'])
            require(len(body)==record['bytes'] and digest(body)==record['sha256'],'source full bytes/SHA')
            files[record['path']]=body
    return records,files

def validate_source_snapshot(base,new,protocol):
    validate_protocol(protocol,protocol['controller_sha256'])
    old_records,old=snapshot(base,BASE_SHA,78)
    records,files=snapshot(new,protocol['source_sha256'],80,protocol['source_manifest_sha256'])
    require(set(files)-set(old)==set(ADDED_FILES) and set(old)<=set(files),'diagnostic added file set')
    require({n for n in old if old[n]!=files[n]}==set(CHANGED_FILES) and
        sum(old[n]==files[n] for n in old)==75,'diagnostic three changes/seventy-five unchanged')
    return old_records,records,files

def build_environment(profile,inherited):
    values={k:inherited[k] for k in ('HOME','USER','LOGNAME','LANG') if k in inherited}
    require(type(profile) is dict and type(profile.get('environment')) is dict and
        set(profile['environment'])=={'SDKROOT','DYLD_LIBRARY_PATH','PATH','CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER'} and
        all(type(v) is str for v in profile['environment'].values()),'corrective environment fields')
    values.update(profile['environment'])
    values.update(CARGO_HOME=(ROOT/'cargo-home').as_posix(),RUSTUP_HOME=(ROOT/'rustup-home').as_posix(),
        RUSTC=(ROOT/'tools/rust/bin/rustc').as_posix(),RUSTDOC=(ROOT/'tools/rust/bin/rustdoc').as_posix(),
        CC=(ROOT/'tools/native-bin/cc').as_posix(),CARGO_TARGET_DIR=TARGET.as_posix(),
        CARGO_BUILD_TARGET_DIR=TARGET.as_posix(),CARGO_BUILD_BUILD_DIR=TARGET.as_posix(),
        CARGO_INCREMENTAL='0',CARGO_BUILD_JOBS='1',CARGO_NET_OFFLINE='true',PYTHONDONTWRITEBYTECODE='1')
    for key in ('TEMP','TMP','TMPDIR'):values[key]=(TARGET/'tmp').as_posix()
    return values

def validate_admission(ordinary,cargo,target_bytes,extra_ordinary,free):
    require(all(type(n) is int and n>=0 for n in (ordinary,cargo,target_bytes,extra_ordinary,free)),'admission integer types')
    require(target_bytes<=512*1024**2 and target_bytes<=cargo,'additional TARGET cap/accounting')
    remaining=512*1024**2-target_bytes
    require(ordinary+extra_ordinary<=1610612736 and cargo+remaining<=1073741824 and
        ordinary+cargo+extra_ordinary+remaining<=2684354560,'global ordinary/Cargo/total reservation')
    require(free>=5*1024**3+extra_ordinary+remaining,'free space reservation')
    return dict(ordinary_bytes=ordinary,cargo_bytes=cargo,target_bytes=target_bytes,
        remaining_target_reserve_bytes=remaining,ordinary_extra_bytes=extra_ordinary)

def cargo_timeout(elapsed,limit=300):
    require(type(elapsed) in (int,float) and math.isfinite(elapsed) and elapsed>=0 and
        type(limit) in (int,float) and 0<limit<=300,'supervision deadline types')
    remaining=limit-13-elapsed
    require(remaining>0,'supervision admission/closure time reserve exhausted')
    return remaining

def cargo_transition(command,env,runner,execute,on_versions=lambda _:None):
    versions={}
    for name in ('cargo','rustc','rustdoc'):
        result=runner([(ROOT/'tools/rust/bin'/name).as_posix(),'--version'])
        require(type(result) is dict and type(result.get('returncode')) is int and result['returncode']==0 and
            type(result.get('stdout')) is bytes and 0<len(result['stdout'])<=4096 and result.get('stderr')==b'',
            'native tool --version return/output')
        text=result['stdout'].decode('utf-8').strip()
        require(re.fullmatch(re.escape(name)+r' 1\.99\.1(?: [^\r\n]+)?',text) is not None,'native 1.99.1 tool version')
        versions[name]=text
    on_versions(versions)
    return execute(CARGO.as_posix(),command,env)

def bounded_errors(primary,secondary):
    return (((primary+'; ') if primary else '')+str(secondary))[:4096]

def persist_terminal(result,protocol,began,persist,replace_late,*,clock=time.monotonic):
    """runtime_secondsはJSON準備時点。成功資格は初回fsync後の実elapsedでも検証。

    期限超過は一度だけfailedへ移す。保存/syscall停止へのhard watchdogではない。
    replace例外は呼出側へ伝播し、stdoutへdoneを公開しない。
    """
    validate_receipt(result,protocol)
    original_sha=digest(canonical(result))
    persist(result)
    elapsed=clock()-began
    if elapsed>350:
        result=dict(result,status='failed',exit=1,runtime_seconds=elapsed,postchecks_ok=False,
            error=bounded_errors(result['error'],'native terminal persistence exceeded 350 seconds'))
        validate_receipt(result,protocol)
        replace_late(result,original_sha)
    return result

def supervise_cargo(supervisor,command,cwd,limit,admit,*,clock=time.monotonic,persist=lambda _:None):
    began=clock();error=None
    try:
        admit()
        supervisor.run(command,timeout=cargo_timeout(clock()-began,limit),cwd=cwd)
    except BaseException as failure:error=(type(failure).__name__+': '+str(failure))[:2048]
    elapsed=clock()-began;proof=supervisor.last_closure
    if proof is not None:
        try:persist(proof)
        except BaseException as failure:error=bounded_errors(error,'closure persistence: '+type(failure).__name__+': '+str(failure))
    return elapsed,proof,error

def read_native(path,maximum,expected=None,*,artifact=False):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink>=(1 if artifact else 1) and
        (artifact or info.st_nlink==1) and info.st_uid==os.getuid() and info.st_size<=maximum,
        'native file owner/type/link/bound: '+str(path))
    with path.open('rb') as stream:data=stream.read(maximum+1)
    require(len(data)<=maximum and (expected is None or digest(data)==expected),'native bytes/SHA: '+str(path))
    return data

def write_native(path,value):
    data=canonical(value);require(len(data)<=MAX_JSON,'auxiliary/terminal JSON bound')
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
    return digest(data)

def check_source_layout(parent,records):
    source=parent/'source';expected={r['path']:r for r in records};actual=set()
    require(source.is_dir() and not source.is_symlink() and source.stat().st_uid==os.getuid(),'source root identity')
    for directory,dirs,files in os.walk(source,followlinks=False,onerror=lambda e:(_ for _ in ()).throw(e)):
        for name in dirs+files:
            path=Path(directory)/name;info=path.lstat()
            require(info.st_uid==os.getuid() and not stat.S_ISLNK(info.st_mode) and
                (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)),'source path type/owner')
            if stat.S_ISREG(info.st_mode):
                relative=path.relative_to(source).as_posix();actual.add(relative)
                require(relative in expected and info.st_nlink==1 and info.st_size==expected[relative]['bytes'],'source file shape/size/link')
    require(actual==set(expected),'source exact file count/set')

def target_bytes():
    if not TARGET.exists():
        require(not TARGET.is_symlink(),'dangling TARGET link');return 0
    require(TARGET.is_dir() and not TARGET.is_symlink() and TARGET.stat().st_uid==os.getuid(),'TARGET root identity')
    total=0
    for directory,dirs,files in os.walk(TARGET,followlinks=False,onerror=lambda e:(_ for _ in ()).throw(e)):
        for name in dirs+files:
            info=(Path(directory)/name).lstat()
            require(info.st_uid==os.getuid() and not stat.S_ISLNK(info.st_mode) and
                (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)),'TARGET path owner/type')
            if stat.S_ISREG(info.st_mode):total+=info.st_size
            require(total<=536870912,'additional TARGET exceeds 512MiB')
    return total

def admission(setup,extra=0):
    ordinary,cargo=setup.counts(ROOT)
    free=os.statvfs(str(ROOT));free_bytes=free.f_bavail*free.f_frsize
    value=validate_admission(ordinary+setup.BOOTSTRAP_RESERVE,cargo,target_bytes(),extra,free_bytes)
    setup.admit_values(ordinary+setup.BOOTSTRAP_RESERVE,cargo,extra,value['remaining_target_reserve_bytes'],free_bytes)
    return value

def validate_xcode_components(selected,components):
    """固定Xcode読取対象専用。/Applicationsの観測済みadmin権限だけを例外にする。"""
    require(type(selected) is str and selected in (SDK_PATH,XCODE_LINKER_PATH),'selected Xcode path is not fixed')
    expected=[p.as_posix() for p in reversed(PurePosixPath(selected).parents)]+[selected]
    require(type(components) is list and len(components)==len(expected),'Xcode ancestor coverage')
    for name,record in zip(expected,components):
        require(type(record) is dict and set(record)=={'path','uid','gid','mode'} and record['path']==name and
            all(type(record[k]) is int and record[k]>=0 for k in ('uid','gid','mode')),'Xcode component shape/order')
        mode=record['mode'];permissions=stat.S_IMODE(mode)
        is_file=name==XCODE_LINKER_PATH
        require((stat.S_ISREG(mode) if is_file else stat.S_ISDIR(mode)) and record['uid']==0,
            'Xcode component type/nonlink/root owner')
        if name=='/Applications':
            require(record['gid']==80 and permissions==0o775,'observed /Applications uid0/gid80/mode0775 required')
        else:
            require(record['gid']==0 and not permissions&0o022 and not permissions&0o7000,
                'Xcode component group/writable/special mode')
        if is_file:require(permissions&0o111,'Xcode linker executable mode')

def checked_readonly_xcode(path):
    selected=path.as_posix()
    require(selected in (SDK_PATH,XCODE_LINKER_PATH),'fixed selected Xcode object required')
    components=[]
    # resolveでリンクを隠さず、末端と全祖先のlstatをそのまま検証する。
    for name in [p.as_posix() for p in reversed(PurePosixPath(selected).parents)]+[selected]:
        info=Path(name).lstat()
        components.append(dict(path=name,uid=info.st_uid,gid=info.st_gid,mode=info.st_mode))
    validate_xcode_components(selected,components)

def environment_profile(setup):
    path=ROOT/'downloads/mac-native-environment.json';setup.checked_path(path)
    profile=parse(read_native(path,MAX_JSON,ENVIRONMENT_SHA))
    require(type(profile) is dict and profile['schema']==1 and profile['host']=='m3mb14' and
        profile['root']==ROOT.as_posix() and profile['source_sha256']==BASE_SHA and
        profile['old_controller_sha256']=='51baf46cb26f441e1148123409a271421bd17944893e9bbd3e2fd68401c56a97',
        'frozen corrective environment identity')
    build_environment(profile,{})
    cc=ROOT/'tools/native-bin/cc';setup.checked_path(cc)
    read_native(cc,65536,profile['cc_shim_sha256']);require(os.access(cc,os.X_OK),'corrective cc shim executable')
    probe_path=ROOT/'journal/native-environment-probe.json';setup.checked_path(probe_path)
    probe=parse(read_native(probe_path,MAX_JSON,profile['native_probe_sha256']))
    require(probe['environment']==profile['environment'] and probe['children_absent'] is True and
        probe['c_compile_output']=='' and probe['rust_compile_output']=='' and
        probe['cc_shim_sha256']==profile['cc_shim_sha256'],'original native environment probe')
    sdk=Path(profile['environment']['SDKROOT'])
    require(sdk.as_posix()==SDK_PATH
        and sdk.is_dir(),'selected SDK identity/existence')
    checked_readonly_xcode(sdk)
    linker=Path(profile['environment']['CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER'])
    require(linker.is_file() and os.access(linker,os.X_OK),'selected native linker')
    if linker.as_posix()==XCODE_LINKER_PATH:checked_readonly_xcode(linker)
    else:
        require(linker.parent==ROOT/'tools/native-bin','native linker is outside fixed Xcode/native-bin paths')
        setup.checked_path(linker)
    return profile

def tool_hashes(setup):
    hashes={}
    for name in ('cargo','rustc','rustdoc'):
        path=ROOT/'tools/rust/bin'/name;setup.checked_path(path)
        require(os.access(path,os.X_OK),'native tool executable')
        hashes[name]=digest(read_native(path,128*1024**2))
    return hashes

def native_inputs(setup,protocol):
    require((protocol['source_sha256'],protocol['source_manifest_sha256'],protocol['generator_sha256'])==
        (FORMATTED_SHA,FORMATTED_MANIFEST_SHA,GENERATOR_SHA),'registered formatted source/generator pins')
    pins=[(HERE/'mac-finite-supervisor.py',FS_SHA,131072),(HERE/'mac-native-build.py',BUILD_SHA,131072),
        (Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py',SETUP_SHA,131072),
        (ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli',CLI_SHA,16*1024**2),
        (ROOT/'tmp/mac-canterbury-continuous-reference-20261027/00-archive.khc',ARCHIVE_SHA,450309),
        (ROOT/'journal/mac-canterbury-continuous-reference.terminal.json',REFERENCE_SHA,MAX_JSON),
        (Path(__file__),protocol['controller_sha256'],131072)]
    for path,expected,maximum in pins:setup.checked_path(path);read_native(path,maximum,expected)
    base_path=ROOT/'downloads/source.zip';setup.checked_path(base_path);setup.checked_path(SOURCE_ZIP)
    base=read_native(base_path,8*1024**2,BASE_SHA)
    derived=read_native(SOURCE_ZIP,304889,protocol['source_sha256'])
    old_records,records,files=validate_source_snapshot(base,derived,protocol)
    verifier=build_verifier();check_source_layout(ROOT,old_records);verifier.verify_source(ROOT,old_records)
    verifier.reject_cargo_config(SOURCE,ROOT/'cargo-home')
    verifier.reject_cargo_config(ROOT/'source',ROOT/'cargo-home')
    return old_records,records,files,environment_profile(setup),tool_hashes(setup)

def extract_source(records,files):
    SOURCE_PARENT.mkdir(mode=0o700);SOURCE.mkdir(mode=0o700)
    for record in records:
        path=SOURCE/record['path'];path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        with path.open('xb') as stream:stream.write(files[record['path']]);stream.flush();os.fsync(stream.fileno())
    check_source_layout(SOURCE_PARENT,records);build_verifier().verify_source(SOURCE_PARENT,records)

def helper_main(parent_pid,protocol_sha):
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 helper only')
    require(type(parent_pid) is int and parent_pid>1 and os.getppid()==parent_pid,'Cargo helper parent identity')
    require(Path(__file__).absolute()==ROOT/'tools/mac-decode-phase-build.py','Cargo helper controller location')
    protocol_data=read_native(PROTOCOL_PATH,MAX_JSON,protocol_sha);verify_protocol_bytes(protocol_data,protocol_sha)
    protocol=parse(protocol_data)
    started=parse(read_native(ROOT/'journal'/(PREFIX+'.started.json'),MAX_JSON))
    require(started['endpoint_pid']==parent_pid and started['controller_sha256']==self_sha() and
        started['protocol_sha256']==protocol_sha,'Cargo helper started binding')
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'phase_build_helper_setup',SETUP_SHA);setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT/'journal',private=True);setup.checked_path(PROTOCOL_PATH)
    _,records,_,profile,tools=native_inputs(setup,protocol)
    require(tools==started['tool_sha256'],'native tools changed before version/exec')
    require(Path.cwd()==SOURCE and TARGET.is_dir() and (TARGET/'tmp').is_dir(),'Cargo helper source/TARGET context')
    check_source_layout(SOURCE_PARENT,records);build_verifier().verify_source(SOURCE_PARENT,records)
    env=build_environment(profile,setup.child_environment(ROOT))
    def runner(command):
        process=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True)
        stdout,stderr=process.communicate(timeout=3)
        return dict(returncode=process.returncode,stdout=stdout,stderr=stderr)
    def save_versions(versions):
        require(tool_hashes(setup)==tools,'native tools changed during version checks')
        write_native(ROOT/'journal'/(PREFIX+'.versions.json'),dict(schema=1,versions=versions,tool_sha256=tools,
            protocol_sha256=protocol_sha,controller_sha256=self_sha()))
    cargo_transition(protocol['cargo_command'],env,runner,os.execvpe,save_versions)
    raise RuntimeError('Cargo exec unexpectedly returned')

def native_main(protocol_sha):
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(Path(__file__).absolute()==ROOT/'tools/mac-decode-phase-build.py','native controller location')
    os.umask(0o077)
    protocol_data=read_native(PROTOCOL_PATH,MAX_JSON,protocol_sha);verify_protocol_bytes(protocol_data,protocol_sha)
    protocol=parse(protocol_data)
    setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=load(setup_path,'phase_build_native_setup',SETUP_SHA);setup.validate_bootstrap(setup_path);setup.checked_path(ROOT,private=True)
    setup.checked_path(ROOT/'journal',private=True);setup.checked_path(PROTOCOL_PATH)
    started=ROOT/'journal'/(PREFIX+'.started.json');terminal=ROOT/'journal'/(PREFIX+'.terminal.json')
    require(not started.exists() and not started.is_symlink() and not terminal.exists() and not terminal.is_symlink(),
        'diagnostic build already attempted')
    begin=time.monotonic();cargo_runtime=0.;proof=None;error=None;binary_sha=None;postchecks=False
    status='failed';old_records=None;records=None;tools=None;supervisor=None
    original_admit,original_environment=setup.admit,setup.child_environment
    try:
        require(not SOURCE_PARENT.exists() and not SOURCE_PARENT.is_symlink() and not TARGET.exists() and
            not TARGET.is_symlink() and not BINARY.exists(),'derived source/target/binary must be unused')
        old_records,records,files,profile,tools=native_inputs(setup,protocol)
        source_extra=sum(r['bytes'] for r in records)+JOURNAL_MARGIN
        admission(setup,source_extra)
        setup.new_json(started,dict(schema=1,protocol=PROTOCOL,protocol_sha256=protocol_sha,
            controller_sha256=self_sha(),source_sha256=protocol['source_sha256'],endpoint_pid=os.getpid(),
            parent_pid=os.getppid(),tool_sha256=tools,started_unix_ns=time.time_ns()))
        extract_source(records,files)
        TARGET.mkdir(mode=0o700);(TARGET/'tmp').mkdir(mode=0o700)
        write_native(ROOT/'journal'/(PREFIX+'.source-delta.json'),dict(schema=1,base_records=78,records=80,
            changed=list(CHANGED_FILES),added=list(ADDED_FILES),unchanged=75,source_sha256=protocol['source_sha256'],
            manifest_sha256=protocol['source_manifest_sha256'],generator_sha256=protocol['generator_sha256']))
        def guard(root,extra=0):
            require(time.monotonic()-begin<350,'native total runtime deadline')
            check_source_layout(ROOT,old_records);check_source_layout(SOURCE_PARENT,records)
            return admission(setup,extra+JOURNAL_MARGIN)
        setup.admit=guard
        setup.child_environment=lambda root:build_environment(profile,original_environment(root))
        setup.LOG_LIMIT=16384
        supervisor=FS.Supervisor(ROOT,support=setup)
        cargo_begin=time.monotonic()
        # 事前admitからgroup close完了まで300s以内。native後処理にも45sを残す。
        interval_limit=min(300.,350.-45.-(cargo_begin-begin))
        command=setup.sandbox_command(ROOT)+['/usr/bin/python3','-I','-B',str(Path(__file__)),
            '--cargo-helper-parent-pid',str(os.getpid()),'--protocol-sha',protocol_sha]
        cargo_runtime,proof,primary=supervise_cargo(supervisor,command,SOURCE,interval_limit,
            lambda:admission(setup,JOURNAL_MARGIN),
            persist=lambda value:write_native(ROOT/'journal'/(PREFIX+'.closure.json'),value))
        require(primary is None,primary)
        require(cargo_runtime<=300,'Cargo supervision including admission/close exceeded 300 seconds')
        require(FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')) and
            proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and proof['actual_returncode']==0,
            'Cargo primary outcome/group closure')
        setup.checked_path(BINARY);require(os.access(BINARY,os.X_OK),'diagnostic binary executable')
        binary_sha=digest(read_native(BINARY,64*1024**2,artifact=True))
        status='done'
    except BaseException as failure:error=(type(failure).__name__+': '+str(failure))[:2048]
    finally:setup.admit,setup.child_environment=original_admit,original_environment
    try:
        old_after,new_after,_,_,tools_after=native_inputs(setup,protocol)
        require(old_records==old_after and records==new_after and tools==tools_after,'post-build source/tool identity')
        check_source_layout(SOURCE_PARENT,records);build_verifier().verify_source(SOURCE_PARENT,records)
        admission(setup,JOURNAL_MARGIN)
        if status=='done':
            require(digest(read_native(BINARY,64*1024**2,artifact=True))==binary_sha,'post-build binary changed')
            versions=parse(read_native(ROOT/'journal'/(PREFIX+'.versions.json'),MAX_JSON))
            require(versions['tool_sha256']==tools and versions['protocol_sha256']==protocol_sha and
                versions['controller_sha256']==self_sha(),'saved tool version binding')
        require(time.monotonic()-begin<=350,'native finalization deadline')
        postchecks=True
    except BaseException as failure:
        status='failed';error=bounded_errors(error,type(failure).__name__+': '+str(failure))
    closed=bool(proof is not None and FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')))
    result=dict(schema=1,protocol=PROTOCOL,purpose=PURPOSE,source_sha256=protocol['source_sha256'],
        controller_sha256=protocol['controller_sha256'],protocol_sha256=protocol_sha,root=protocol['root'],target=protocol['target'],
        cargo_command=protocol['cargo_command'],status=status,exit=0 if status=='done' else 1,
        runtime_seconds=time.monotonic()-begin,cargo_runtime_seconds=cargo_runtime,binary_sha256=binary_sha,
        wait_confirmed=closed,group_absent=closed,postchecks_ok=postchecks,closure_proof=proof,
        closure_sha256=digest(canonical(proof)) if proof is not None else None,error=error,binary_path=BINARY.as_posix())
    # 保存直前の時間も成功条件へ反映。失敗は主errorを残して既知closureを独立に示す。
    if result['status']=='done' and result['runtime_seconds']>350:
        result.update(status='failed',exit=1,error='native final terminal preparation deadline')
    def replace_late(value,expected_sha):
        # 同attemptがCreateNewした未公開terminalだけを対象に一方向へ置換する。
        require(terminal==ROOT/'journal'/(PREFIX+'.terminal.json'),'terminal replacement path')
        setup.checked_path(terminal)
        read_native(terminal,MAX_JSON,expected_sha)
        temporary=ROOT/'journal'/(PREFIX+'.terminal-deadline.json')
        require(not temporary.exists() and not temporary.is_symlink(),'deadline temporary already exists')
        setup.checked_path(temporary.parent,private=True)
        temporary_sha=write_native(temporary,value)
        setup.checked_path(temporary);read_native(temporary,MAX_JSON,temporary_sha)
        setup.checked_path(terminal);read_native(terminal,MAX_JSON,expected_sha)
        os.replace(temporary,terminal)
        read_native(terminal,MAX_JSON,temporary_sha)
    result=persist_terminal(result,protocol,begin,lambda value:write_native(terminal,value),replace_late)
    sys.stdout.buffer.write(canonical(result));return result['exit']

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--protocol-sha');parser.add_argument('--protocol-base64')
    parser.add_argument('--verify-protocol-base64');parser.add_argument('--verify-receipt-base64')
    parser.add_argument('--allow-noncanonical',action='store_true')
    parser.add_argument('--cargo-helper-parent-pid',type=int)
    args=parser.parse_args()
    if args.verify_protocol_base64:
        require(args.protocol_sha and not args.protocol_base64 and not args.verify_receipt_base64 and args.cargo_helper_parent_pid is None,'protocol helper shape')
        result=verify_protocol_bytes(decode_wire(args.verify_protocol_base64),args.protocol_sha,args.allow_noncanonical)
    elif args.verify_receipt_base64:
        require(args.protocol_base64 and not args.protocol_sha and not args.allow_noncanonical and args.cargo_helper_parent_pid is None,'receipt helper shape')
        result=verify_receipt_bytes(decode_wire(args.verify_receipt_base64),decode_wire(args.protocol_base64))
    else:
        require(args.protocol_sha and not args.protocol_base64 and not args.allow_noncanonical,'native build argument shape')
        if args.cargo_helper_parent_pid is not None:return helper_main(args.cargo_helper_parent_pid,args.protocol_sha)
        return native_main(args.protocol_sha)
    sys.stdout.buffer.write(canonical(result));return 0

if __name__=='__main__':sys.exit(main())
