#!/usr/bin/env python3
"""固定CDF候補の非比較correctness endpoint。未検証の開始は拒否する。"""
import base64
import argparse
import hashlib
import importlib.util
import json
import math
import os
import platform
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import time

HERE=Path(__file__).absolute().parent
ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
RUN=ROOT/'tmp/mac-cdf-candidate-example-e2e-20261027'
PROTOCOL='khc-mac-cdf-candidate-e2e-v1'
PURPOSE='candidate-example-correctness-only'
SOURCE_SHA='36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05'
MANIFEST_SHA='d711acf1989b34f5043d5a7bae68ea95c2d51a72f602ca6ca27124e5ebffc7e2'
EXAMPLE_SHA='0af3b9cc1823566c129c1bf989f4e53720bc8db843bb152c504d744bf556e59c'
CLI_SHA='cc36350705aff86fb4c8bf36e9d6f3d409c1fd4bf6b3d4fd6f1853e5add22632'
BUILD_SHA='34047b6793caa999e6dddc95a51b0b8c35e12218f1c9bf59e3834d89885cb23c'
CLOSURE_SHA='d180b552023a06f47672116be0a71f60950183fcc328415522c9c323523baeeb'
FIXTURE_SHA='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
ORACLE_SHA='343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75'
CANDIDATE_CONTROLLER_SHA='2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5'
SNAPSHOT_SHA='80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f'
FS_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
SETUP_SHA='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
BUILD_VERIFIER_SHA='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb'
MAX_JSON=65536

def require(ok,message):
    if not ok:raise ValueError(message)
def digest(data):return hashlib.sha256(data).hexdigest()
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None
def self_sha():return digest(Path(__file__).read_bytes())
def expected_protocol(endpoint_sha):
    require(sha(endpoint_sha),'endpoint SHA')
    return dict(schema=1,protocol=PROTOCOL,purpose=PURPOSE,task='goal-restore-20261019',host='m3mb14',
        root=ROOT.as_posix(),run_directory=RUN.as_posix(),endpoint_sha256=endpoint_sha,
        source_sha256=SOURCE_SHA,source_manifest_sha256=MANIFEST_SHA,example_sha256=EXAMPLE_SHA,
        candidate_cli_sha256=CLI_SHA,candidate_build_receipt_sha256=BUILD_SHA,candidate_build_closure_sha256=CLOSURE_SHA,
        fixture_sha256=FIXTURE_SHA,fixture_bytes=513216,oracle_sha256=ORACLE_SHA,
        windows_max_bytes=8388608,windows_max_entries=96,windows_timeout_seconds=360,
        worker_timeout_seconds=350,native_timeout_seconds=300,child_timeout_seconds=240,
        closure_reserve_seconds=13,preflight_seconds=27,postcheck_reserve_seconds=20,
        supervisor_sha256=FS_SHA,setup_sha256=SETUP_SHA,build_verifier_sha256=BUILD_VERIFIER_SHA,
        candidate_controller_sha256=CANDIDATE_CONTROLLER_SHA,candidate_snapshot_sha256=SNAPSHOT_SHA,
        superiority_decision_allowed=False)
def validate_protocol(value,endpoint_sha):
    require(type(value) is dict and canonical(value)==canonical(expected_protocol(endpoint_sha)),'fixed protocol')
def relative_path(value):
    require(type(value) is str,'path type');path=PurePosixPath(value)
    require(value and str(path)==value and not path.is_absolute() and '..' not in path.parts and
        '\\' not in value and value!='.','unsafe relative path');return path
def validate_budget(size,entries,reserved_bytes,reserved_entries):
    require(all(type(n) is int and n>=0 for n in (size,entries,reserved_bytes,reserved_entries)) and
        size+reserved_bytes<=8388608 and entries+reserved_entries<=96,'run budget')
def child_start_deadline(begin):return begin+27
def validate_child_start(now,begin):require(now<=child_start_deadline(begin),'insufficient child/closure/postcheck reserve')

def load(path,name,expected):
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink==1 and path.stat().st_size<=131072 and
        digest(path.read_bytes())==expected,'dependency SHA/type')
    spec=importlib.util.spec_from_file_location(name,str(path));value=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value);return value
def candidate():return load(HERE/'mac-cdf-candidate-build.py','cdf_candidate_e2e_build',CANDIDATE_CONTROLLER_SHA)
def parse(data):
    require(type(data) is bytes and 0<len(data)<=MAX_JSON,'JSON bytes/bound')
    value=candidate().old_controller().parse(data)
    require(canonical(value)==data,'canonical JSON required');return value
def verify_protocol_bytes(data,expected):
    require(sha(expected) and digest(data)==expected,'protocol raw SHA')
    value=parse(data);validate_protocol(value,self_sha())
    return dict(schema=1,protocol=PROTOCOL,protocol_sha256=expected,endpoint_sha256=self_sha(),
                source_sha256=SOURCE_SHA,purpose=PURPOSE,verified=True)

def archive_suffix(data):
    require(len(data)>=32,'archive header');offset=32+struct.unpack_from('<I',data,20)[0]
    require(offset<=len(data),'archive metadata bound');return data[offset:]

def expected_api_files(oracle):
    require(type(oracle) is dict and oracle.get('schema')==1 and type(oracle.get('api')) is dict and
        type(oracle.get('archive_suffixes')) is list,'oracle shape')
    rows=[r for r in oracle['archive_suffixes'] if type(r) is dict and type(r.get('path')) is str and r['path'].startswith('api/')]
    require(len(rows)==23 and len({r['path'] for r in rows})==23 and
        all(set(r)=={'path','bytes','sha256'} and type(r['bytes']) is int and r['bytes']>=0 and sha(r['sha256'])
            and str(relative_path(r['path']))==r['path'] for r in rows),'oracle API archive rows')
    names=('a-main.bin','empty.bin','g32.bin','krs2.bin','krs3.bin','legacy.bin','random.bin','short.bin')
    files={r['path'] for r in rows}
    files.update('api/'+folder+'/'+name for folder in ('source','api-output','accepted-all-output') for name in names)
    files.update('api/legacy-compat-output/legacy-%d.bin'%i for i in range(1,10))
    files.update('api/'+folder+'/sentinel' for folder in ('rejected-frames','rejected-trailing','rejected-truncated'))
    files.add('api/legacy.bin')
    optional={'api/rejected-trailing/payload.bin','api/rejected-truncated/payload.bin'}
    return files,optional,rows

def validate_api_report(report,oracle):
    keys={'schema','scope','api','files','directories','archive_suffixes','registration_sha256','windows_run_id',
        'windows_registration_sha256','protocol_sha256'}
    require(type(report) is dict and set(report)==keys and type(report['schema']) is int and report['schema']==1 and
        report['scope']=='candidate-example-correctness-only' and report['api']==oracle['api'],'API report shape/oracle')
    required,optional,rows=expected_api_files(oracle)
    records=report['files'];require(type(records) is list,'file records')
    by_path={}
    for row in records:
        require(type(row) is dict and set(row)=={'path','bytes','sha256'} and
            type(row['path']) is str and str(relative_path(row['path']))==row['path'] and
            type(row['bytes']) is int and row['bytes']>=0 and sha(row['sha256']) and row['path'] not in by_path,
            'file record shape/duplicate')
        by_path[row['path']]=row
    require(required<=set(by_path) and set(by_path)<=required|optional,'exact API file set')
    dirs={'api','api/source','api/api-output','api/accepted-all-output','api/legacy-compat-output',
          'api/rejected-frames','api/rejected-trailing','api/rejected-truncated'}
    require(type(report['directories']) is list and len(report['directories'])==len(dirs) and
        set(report['directories'])==dirs,'exact API directories')
    require(report['archive_suffixes']==rows,'API archive suffix oracle')
    for name in ('a-main.bin','empty.bin','g32.bin','krs2.bin','krs3.bin','legacy.bin','random.bin','short.bin'):
        source=by_path['api/source/'+name]
        for output in ('api-output','accepted-all-output'):
            other=by_path['api/'+output+'/'+name]
            require((source['bytes'],source['sha256'])==(other['bytes'],other['sha256']),'restored output differs')
    legacy=by_path['api/legacy.bin']
    require((legacy['bytes'],legacy['sha256'])==(by_path['api/source/legacy.bin']['bytes'],
        by_path['api/source/legacy.bin']['sha256']),'legacy source differs')
    for i in range(1,10):
        row=by_path['api/legacy-compat-output/legacy-%d.bin'%i]
        require((row['bytes'],row['sha256'])==(legacy['bytes'],legacy['sha256']),'legacy restore differs')
    for folder in ('rejected-frames','rejected-trailing','rejected-truncated'):
        row=by_path['api/'+folder+'/sentinel']
        require(row['bytes']==4 and row['sha256']==digest(b'keep'),'rejection sentinel')
    for name in optional & set(by_path):
        g32=by_path['api/source/g32.bin'];row=by_path[name]
        require((row['bytes'],row['sha256'])==(g32['bytes'],g32['sha256']),'optional partial output')
    return True

def load_oracle():
    path=(ROOT/'downloads/mac-native-e2e-oracle.json' if HERE==ROOT/'tools'
          else HERE/'mac-native-e2e-oracle.json')
    require(not path.is_symlink() and path.is_file() and path.stat().st_nlink==1 and
        path.stat().st_size<=MAX_JSON,'oracle type/bound')
    data=path.read_bytes();require(digest(data)==ORACLE_SHA,'oracle SHA')
    return candidate().old_controller().parse(data)

def validate_receipt(value,protocol,oracle):
    validate_protocol(protocol,protocol['endpoint_sha256'])
    keys={'schema','protocol','purpose','windows_run_id','windows_registration_sha256','protocol_sha256',
        'endpoint_sha256','source_sha256','example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256',
        'candidate_build_closure_sha256','remote_registration_sha256','report_sha256','report_base64',
        'closure_proof','closure_sha256','children_absent','postchecks_ok','runtime_seconds','status','exit','error'}
    require(type(value) is dict and set(value)==keys,'receipt exact schema')
    for key in ('schema','protocol','purpose','endpoint_sha256','source_sha256','example_sha256',
                'candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256'):
        require(value[key]==protocol[key] and type(value[key]) is type(protocol[key]),'receipt identity '+key)
    require(type(value['windows_run_id']) is str and re.fullmatch('[0-9a-f]{32}',value['windows_run_id']) and
        sha(value['windows_registration_sha256']) and value['protocol_sha256']==digest(canonical(protocol)),
        'Windows/protocol identity')
    require(type(value['runtime_seconds']) in (int,float) and math.isfinite(value['runtime_seconds']) and
        value['runtime_seconds']>=0 and type(value['status']) is str and value['status'] in ('done','failed') and
        type(value['exit']) is int and type(value['children_absent']) is bool and type(value['postchecks_ok']) is bool,
        'receipt status/timing')
    proof=value['closure_proof'];closed=False
    if proof is None:require(value['closure_sha256'] is None,'missing closure SHA')
    else:
        require(type(proof) is dict and sha(value['closure_sha256']) and
            digest(canonical(proof))==value['closure_sha256'],'closure SHA')
        closed=candidate().old_controller().FS.validate_closure(proof,proof.get('pid'),proof.get('sequence'))
    require(value['children_absent'] is bool(closed),'closure absence flag')
    if value['remote_registration_sha256'] is not None:require(sha(value['remote_registration_sha256']),'registration SHA')
    if value['report_base64'] is None:
        require(value['report_sha256'] is None,'missing report SHA')
    else:
        require(type(value['report_base64']) is str and len(value['report_base64'])<=43692 and
            sha(value['report_sha256']),'report wire')
        data=base64.b64decode(value['report_base64'],validate=True)
        require(len(data)<=32768 and digest(data)==value['report_sha256'],'report raw SHA/bound')
        report=parse(data);validate_api_report(report,oracle)
        require(report['registration_sha256']==value['remote_registration_sha256'] and
            report['windows_run_id']==value['windows_run_id'] and
            report['windows_registration_sha256']==value['windows_registration_sha256'] and
            report['protocol_sha256']==value['protocol_sha256'],'report binding')
    if value['status']=='done':
        require(value['exit']==0 and value['error'] is None and closed and value['postchecks_ok'] and
            sha(value['remote_registration_sha256']) and value['report_base64'] is not None and
            proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and
            proof['actual_returncode']==0 and value['runtime_seconds']<=300,'done eligibility')
    else:require(value['exit']==1 and type(value['error']) is str and 0<len(value['error'])<=4096,'failed receipt')
    return dict(schema=1,protocol=PROTOCOL,verified=True,protocol_sha256=value['protocol_sha256'],
        endpoint_sha256=value['endpoint_sha256'],source_sha256=SOURCE_SHA,purpose=PURPOSE,
        windows_run_id=value['windows_run_id'],windows_registration_sha256=value['windows_registration_sha256'],
        receipt_sha256=digest(canonical(value)),report_sha256=value['report_sha256'],
        closure_sha256=value['closure_sha256'],status=value['status'],exit=value['exit'],cleanup_allowed=bool(closed))

def scan_with_retry(scan,deadline,*,clock=time.monotonic,retry=True):
    for attempt in range(3 if retry else 1):
        require(clock()<deadline,'run snapshot deadline')
        try:
            result=scan()
            require(clock()<deadline,'run snapshot completion deadline')
            return result
        except FileNotFoundError as error:
            path=Path(error.filename) if error.filename else None
            inside=path is not None and path.is_absolute() and '..' not in path.parts and RUN/'api' in path.parents
            if not retry or not inside or attempt==2:raise
    raise ValueError('run snapshot retry bound')

def _run_budget_once():
    info=RUN.lstat();require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode) and
        info.st_uid==os.getuid() and not info.st_mode&0o077,'run root owner/type/mode')
    entries=1;size=0;stack=[RUN]
    while stack:
        for item in stack.pop().iterdir():
            info=item.lstat();entries+=1
            require(info.st_uid==os.getuid() and not info.st_mode&0o077 and not stat.S_ISLNK(info.st_mode),
                'run entry owner/mode/link')
            if stat.S_ISDIR(info.st_mode):stack.append(item)
            else:
                require(stat.S_ISREG(info.st_mode) and info.st_nlink==1,'run file type/link')
                size+=info.st_size
            # start/closure/terminal/期限超過置換、bounded log/reportを常時計上する。
            validate_budget(size,entries,4*65536+2*32768,6)
    validate_budget(size,entries,4*65536+2*32768,6)
    return dict(actual_bytes=size,actual_entries=entries,reserved_bytes=4*65536+2*32768,reserved_entries=6)

def run_budget(deadline=float('inf'),*,retry=False):
    return scan_with_retry(_run_budget_once,deadline,retry=retry)

def write_new(path,data):
    require(type(data) is bytes and len(data)<=MAX_JSON or path==RUN/'ptt5.bin' and len(data)==513216,
        'new data bound')
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())

def verify_native_inputs(setup,old,build):
    setup.checked_path(Path(__file__));old.read_native(Path(__file__),131072,self_sha())
    for path,expected in ((HERE/'mac-cdf-candidate-build.py',CANDIDATE_CONTROLLER_SHA),
                          (HERE/'mac-cdf-candidate-snapshot.py',SNAPSHOT_SHA)):
        setup.checked_path(path);old.read_native(path,131072,expected)
    build_protocol=old.read_native(build.PROTOCOL_PATH,MAX_JSON)
    build_receipt=old.read_native(ROOT/'journal/mac-cdf-candidate-build.terminal.json',MAX_JSON,BUILD_SHA)
    build_closure=old.read_native(ROOT/'journal/mac-cdf-candidate-build.closure.json',MAX_JSON,CLOSURE_SHA)
    verified=build.verify_receipt_bytes(build_receipt,build_protocol)
    require(verified['status']=='done' and verified['cleanup_allowed'] is True and verified['binary_sha256']==CLI_SHA and
        canonical(build.parse(build_receipt)['closure_proof'])==build_closure,'candidate build evidence')
    protocol=build.parse(build_protocol)
    _,records,_,_,tools=build.native_inputs(setup,old,protocol)
    old.check_source_layout(build.SOURCE_PARENT,records);old.build_verifier().verify_source(build.SOURCE_PARENT,records)
    cli=build.BINARY;example=build.TARGET/'aarch64-apple-darwin/release/examples/khc_spatial_mdl_e2e'
    for path,expected in ((cli,CLI_SHA),(example,EXAMPLE_SHA)):
        setup.checked_path(path);old.read_native(path,64*1024**2,expected,artifact=True)
        require(os.access(path,os.X_OK),'candidate binary executable')
    fixture=ROOT/'downloads/ptt5.bin';setup.checked_path(fixture)
    data=old.read_native(fixture,513216,FIXTURE_SHA);require(len(data)==513216,'fixture size')
    return records,tools,data,example

def collect_report(old,oracle,registration_sha,windows_run_id,windows_registration_sha,protocol_sha,api):
    required,optional,rows=expected_api_files(oracle)
    actual=set();dirs=set();records=[]
    for directory,subdirs,files in os.walk(RUN/'api',followlinks=False,onerror=lambda e:(_ for _ in ()).throw(e)):
        base=Path(directory);dirs.add(base.relative_to(RUN).as_posix())
        for name in subdirs:
            path=base/name;info=path.lstat()
            require(stat.S_ISDIR(info.st_mode) and not stat.S_ISLNK(info.st_mode),'API directory type')
        for name in files:
            path=base/name;relative=path.relative_to(RUN).as_posix();data=old.read_native(path,8388608)
            actual.add(relative);records.append(dict(path=relative,bytes=len(data),sha256=digest(data)))
    require(required<=actual and actual<=required|optional,'exact API output files')
    for row in rows:
        suffix=archive_suffix(old.read_native(RUN/relative_path(row['path']),8388608))
        require(len(suffix)==row['bytes'] and digest(suffix)==row['sha256'],'archive suffix mismatch')
    report=dict(schema=1,scope=PURPOSE,api=api,files=sorted(records,key=lambda x:x['path']),
        directories=sorted(dirs),archive_suffixes=rows,registration_sha256=registration_sha,
        windows_run_id=windows_run_id,windows_registration_sha256=windows_registration_sha,
        protocol_sha256=protocol_sha)
    validate_api_report(report,oracle);return report

def native_main(windows_run_id,windows_registration_sha,protocol_sha):
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 only')
    require(type(windows_run_id) is str and re.fullmatch('[0-9a-f]{32}',windows_run_id) and
        sha(windows_registration_sha) and sha(protocol_sha),'Windows run identity')
    require(Path(__file__).absolute()==ROOT/'tools/mac-cdf-candidate-e2e-endpoint.py','endpoint location')
    os.umask(0o077);began=time.monotonic()
    build=candidate();old=build.old_controller();setup_path=Path(str(ROOT)+'-bootstrap')/'mac-native-setup.py'
    setup=old.load(setup_path,'cdf_e2e_setup',SETUP_SHA);setup.validate_bootstrap(setup_path)
    setup.checked_path(ROOT,private=True);setup.checked_path(ROOT/'journal',private=True)
    setup.checked_path(ROOT/'tmp',private=True)
    protocol_path=ROOT/'journal/mac-cdf-candidate-e2e-protocol.json';setup.checked_path(protocol_path)
    protocol_data=old.read_native(protocol_path,MAX_JSON,protocol_sha);verify_protocol_bytes(protocol_data,protocol_sha)
    protocol=parse(protocol_data)
    oracle_path=ROOT/'downloads/mac-native-e2e-oracle.json';setup.checked_path(oracle_path)
    old.read_native(oracle_path,MAX_JSON,ORACLE_SHA);oracle=load_oracle()
    prefix=ROOT/'journal/mac-cdf-candidate-e2e';started=Path(str(prefix)+'.started.json')
    terminal=Path(str(prefix)+'.terminal.json')
    require(not RUN.exists() and not RUN.is_symlink(),'candidate E2E RUN already exists')
    for suffix in ('.started.json','.terminal.json','.terminal-deadline.json','.closure.json'):
        path=Path(str(prefix)+suffix);require(not path.exists() and not path.is_symlink(),'E2E already attempted')
    setup.admit(ROOT,8388608)
    records,tools,fixture,example=verify_native_inputs(setup,old,build)
    validate_child_start(time.monotonic(),began)
    started_data=dict(schema=1,protocol=PROTOCOL,windows_run_id=windows_run_id,
        windows_registration_sha256=windows_registration_sha,protocol_sha256=protocol_sha,
        endpoint_sha256=self_sha(),endpoint_pid=os.getpid(),started_unix_ns=time.time_ns())
    old.write_native(started,started_data)
    registration_sha=None;report_data=None;proof=None;error=None;status='failed';postchecks=False
    original_admit,original_environment=setup.admit,setup.child_environment
    try:
        RUN.mkdir(mode=0o700);setup.checked_path(RUN,private=True)
        registration=dict(schema=1,protocol=PROTOCOL,purpose=PURPOSE,run_directory=RUN.as_posix(),
            windows_run_id=windows_run_id,windows_registration_sha256=windows_registration_sha,
            protocol_sha256=protocol_sha,source_sha256=SOURCE_SHA,example_sha256=EXAMPLE_SHA,
            candidate_cli_sha256=CLI_SHA,candidate_build_receipt_sha256=BUILD_SHA,
            candidate_build_closure_sha256=CLOSURE_SHA)
        registration_data=canonical(registration);write_new(RUN/'registration.json',registration_data)
        registration_sha=digest(registration_data)
        write_new(RUN/'ptt5.bin',fixture);run_budget()
        require(not (RUN/'api').exists() and not (RUN/'api').is_symlink(),'API output exists')
        validate_child_start(time.monotonic(),began)
        child_deadline=time.monotonic()+240
        def guard(root,extra=0):
            require(time.monotonic()<child_deadline,'child guard deadline')
            run_budget(child_deadline,retry=True);original_admit(root,extra+4*65536+2*32768)
            require(time.monotonic()<child_deadline,'child guard completion deadline')
        def child_environment(root):
            env=original_environment(root)
            for key in ('TMP','TEMP','TMPDIR'):env[key]=RUN.as_posix()
            env['KHC_STORAGE_RUN_RECORD']=(RUN/'registration.json').as_posix()
            return env
        class RunOps(old.FS.SystemOps):
            @staticmethod
            def popen(*args,**kwargs):
                # guard内での時間消費も準備枠に含め、遅れたspawnを拒否する。
                validate_child_start(time.monotonic(),began)
                return subprocess.Popen(*args,**kwargs)
            @staticmethod
            def write_log(_path,data):
                require(len(data)<=32768,'child log bound')
                write_new(RUN/'child.log',data);run_budget()
        setup.admit=guard;setup.child_environment=child_environment;setup.LOG_LIMIT=32768
        supervisor=old.FS.Supervisor(ROOT,support=setup,ops=RunOps())
        try:
            output=supervisor.run(setup.sandbox_command(ROOT)+[str(example),str(RUN/'api'),str(RUN/'ptt5.bin')],
                                  timeout=240,cwd=RUN)
        finally:proof=supervisor.last_closure
        require(proof is not None and old.FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')) and
            proof['primary']['kind']=='exit' and proof['primary']['returncode']==0 and
            proof['actual_returncode']==0,'example normal exit/group closure')
        old.write_native(Path(str(prefix)+'.closure.json'),proof)
        require(len(output.encode())<=32768,'example output bound')
        require(old.read_native(RUN/'child.log',32768)==output.encode(),'child log/output changed')
        api=old.parse(output.encode());require(api==oracle['api'],'example API oracle')
        require({p.name for p in RUN.iterdir()}=={'api','registration.json','ptt5.bin','child.log'},
            'unexpected RUN top-level output')
        report=collect_report(old,oracle,registration_sha,windows_run_id,windows_registration_sha,protocol_sha,api)
        report_data=canonical(report);require(len(report_data)<=32768,'report bound')
        write_new(RUN/'report.json',report_data);run_budget()
        status='done'
    except BaseException as failure:error=(type(failure).__name__+': '+str(failure))[:2048]
    finally:setup.admit,setup.child_environment=original_admit,original_environment
    try:
        # エラー後もgroupが既知ならraw closureを保全する。
        closure_path=Path(str(prefix)+'.closure.json')
        if proof is not None and not closure_path.exists() and not closure_path.is_symlink():old.write_native(closure_path,proof)
        records_after,tools_after,_,_=verify_native_inputs(setup,old,build)
        require(records_after==records and tools_after==tools,'postcheck source/tool identity')
        if registration_sha is not None:
            require(digest(old.read_native(RUN/'registration.json',MAX_JSON))==registration_sha,'registration changed')
            require(digest(old.read_native(RUN/'ptt5.bin',513216))==FIXTURE_SHA,'run fixture changed')
            if status=='done':
                require(old.read_native(RUN/'report.json',32768)==report_data,'report changed')
                report_after=collect_report(old,oracle,registration_sha,windows_run_id,
                    windows_registration_sha,protocol_sha,old.parse(output.encode()))
                require(canonical(report_after)==report_data,'API outputs changed after report')
            run_budget()
        require(time.monotonic()-began<=300,'native deadline');postchecks=True
    except BaseException as failure:
        status='failed';error=old.bounded_errors(error,type(failure).__name__+': '+str(failure))
    if proof is not None:
        # 記録が欠落・部分保存なら端末結果を公開せずWindows側をpendingにする。
        old.read_native(Path(str(prefix)+'.closure.json'),MAX_JSON,digest(canonical(proof)))
    closed=bool(proof is not None and old.FS.validate_closure(proof,proof.get('pid'),proof.get('sequence')))
    result=dict(schema=1,protocol=PROTOCOL,purpose=PURPOSE,windows_run_id=windows_run_id,
        windows_registration_sha256=windows_registration_sha,protocol_sha256=protocol_sha,endpoint_sha256=self_sha(),
        source_sha256=SOURCE_SHA,example_sha256=EXAMPLE_SHA,candidate_cli_sha256=CLI_SHA,
        candidate_build_receipt_sha256=BUILD_SHA,candidate_build_closure_sha256=CLOSURE_SHA,
        remote_registration_sha256=registration_sha,report_sha256=digest(report_data) if report_data else None,
        report_base64=base64.b64encode(report_data).decode() if report_data else None,closure_proof=proof,
        closure_sha256=digest(canonical(proof)) if proof is not None else None,children_absent=closed,
        postchecks_ok=postchecks,runtime_seconds=time.monotonic()-began,status=status,exit=0 if status=='done' else 1,error=error)
    result['runtime_seconds']=max(result['runtime_seconds'],time.monotonic()-began)
    if result['status']=='done' and result['runtime_seconds']>300:
        result.update(status='failed',exit=1,error='native terminal preparation deadline exceeded')
    validate_receipt(result,protocol,oracle);terminal_sha=old.write_native(terminal,result)
    if time.monotonic()-began>300:
        result.update(status='failed',exit=1,postchecks_ok=False,runtime_seconds=time.monotonic()-began,
            error=old.bounded_errors(result['error'],'native terminal persistence exceeded 300 seconds'))
        validate_receipt(result,protocol,oracle);temporary=Path(str(prefix)+'.terminal-deadline.json')
        old.read_native(terminal,MAX_JSON,terminal_sha);old.write_native(temporary,result)
        old.read_native(terminal,MAX_JSON,terminal_sha);os.replace(temporary,terminal)
        old.read_native(terminal,MAX_JSON,digest(canonical(result)))
    sys.stdout.buffer.write(canonical(result));return result['exit']

def wire(value):
    require(type(value) is str and 0<len(value)<=((MAX_JSON+2)//3)*4,'wire bound')
    data=base64.b64decode(value,validate=True);require(len(data)<=MAX_JSON,'wire decoded bound');return data

def verify_wire(data):
    require(type(data) is bytes and 0<len(data)<=262144,'stdin wire bound')
    envelope=candidate().old_controller().parse(data)
    require(type(envelope) is dict and set(envelope)=={'mode','protocol_base64','protocol_sha256','receipt_base64'} and
        type(envelope['mode']) is str and envelope['mode'] in ('protocol','receipt') and
        sha(envelope['protocol_sha256']),'stdin wire shape')
    protocol_data=wire(envelope['protocol_base64'])
    summary=verify_protocol_bytes(protocol_data,envelope['protocol_sha256'])
    if envelope['mode']=='protocol':
        require(envelope['receipt_base64'] is None,'protocol wire receipt must be null')
        return summary
    require(type(envelope['receipt_base64']) is str,'receipt wire value')
    return validate_receipt(parse(wire(envelope['receipt_base64'])),parse(protocol_data),load_oracle())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-run-id');parser.add_argument('--windows-registration-sha')
    parser.add_argument('--protocol-sha');parser.add_argument('--protocol-base64')
    parser.add_argument('--verify-protocol-base64');parser.add_argument('--verify-receipt-base64')
    parser.add_argument('--verify-wire-stdin',action='store_true')
    args=parser.parse_args()
    if args.verify_wire_stdin:
        require(not any((args.verify_protocol_base64,args.verify_receipt_base64,args.protocol_base64,
            args.protocol_sha,args.windows_run_id,args.windows_registration_sha)),'stdin verifier arguments')
        result=verify_wire(sys.stdin.buffer.read(262145))
    elif args.verify_protocol_base64:
        require(args.protocol_sha and not any((args.protocol_base64,args.verify_receipt_base64,
            args.windows_run_id,args.windows_registration_sha)),'protocol verifier arguments')
        result=verify_protocol_bytes(wire(args.verify_protocol_base64),args.protocol_sha)
    elif args.verify_receipt_base64:
        require(args.protocol_base64 and not any((args.protocol_sha,args.windows_run_id,args.windows_registration_sha)),
            'receipt verifier arguments')
        protocol_data=wire(args.protocol_base64);verify_protocol_bytes(protocol_data,digest(protocol_data))
        result=validate_receipt(parse(wire(args.verify_receipt_base64)),parse(protocol_data),load_oracle())
    else:
        require(args.windows_run_id and args.windows_registration_sha and args.protocol_sha and not args.protocol_base64,
            'native arguments')
        return native_main(args.windows_run_id,args.windows_registration_sha,args.protocol_sha)
    sys.stdout.buffer.write(canonical(result));return 0

if __name__=='__main__':sys.exit(main())
