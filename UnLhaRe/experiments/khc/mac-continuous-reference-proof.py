#!/usr/bin/env python3
"""Read-only, bounded proof collection and in-memory continuous-reference validation.

Collection never imports the codec or measurement dependencies. Verification uses
the independently pinned local endpoint; no archive entry is extracted or executed.
"""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys
import zipfile

HERE=Path(__file__).absolute().parent
ROOT=Path('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
PREFIX='mac-canterbury-continuous-reference'
RUN=ROOT/'tmp'/(PREFIX+'-20261027')
ENDPOINT_SHA='4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42'
RAW_LIMIT=65536
ZIP_LIMIT=1048576
TOTAL_LIMIT=2097152
NAMES=tuple(['protocol.json','terminal.json','started.json','report.json','closure.json','failure.json']+
    [f'capture-{i:02d}.json' for i in range(64)]+
    [f'cli-{i:02d}.json' for i in range(42)]+[f'pair-{i:02d}.json' for i in range(21)])

def require(ok,message):
    if not ok: raise ValueError(message)

def digest(data): return hashlib.sha256(data).hexdigest()

def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode('utf-8')

def parse(data):
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'duplicate JSON key');result[key]=value
        return result
    return json.loads(data,object_pairs_hook=pairs,
        parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite JSON')))

def sha(value): return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None

def checked_read(path,limit,owned=False):
    path=Path(path)
    require(path.is_absolute() and '..' not in path.parts,'absolute checked path required')
    for part in [*reversed(path.parents),path]:
        info=part.lstat()
        require(not stat.S_ISLNK(info.st_mode) and not getattr(info,'st_file_attributes',0)&1024,
                'linked proof path')
        if part != path: require(stat.S_ISDIR(info.st_mode),'proof ancestor type')
    require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=limit,'proof file type/size/link')
    if owned: require(info.st_uid==os.getuid(),'proof owner')
    with path.open('rb') as stream:data=stream.read(limit+1)
    require(len(data)<=limit and len(data)==info.st_size,'proof read bound')
    return data

def endpoint():
    path=HERE/(PREFIX+'.py')
    require(digest(checked_read(path,131072))==ENDPOINT_SHA,'local endpoint SHA')
    spec=importlib.util.spec_from_file_location('proof_pinned_endpoint',str(path))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value

def verify_protocol(data,expected_sha,allow_noncanonical=False):
    require(type(data) is bytes and len(data)<=RAW_LIMIT and sha(expected_sha) and digest(data)==expected_sha,
            'protocol bytes/SHA')
    value=parse(data)
    require(allow_noncanonical or canonical(value)==data,'protocol canonical encoding')
    module=endpoint();module.validate_protocol(value,ENDPOINT_SHA)
    return dict(schema=1,protocol=value['protocol'],protocol_sha256=expected_sha,endpoint_sha256=ENDPOINT_SHA,
        purpose=value['purpose'],superiority_decision_allowed=False,
        windows_max_entries=value['windows_max_entries'],windows_timeout_seconds=value['windows_timeout_seconds'])

def read_archive(data):
    require(type(data) is bytes and 0<len(data)<=ZIP_LIMIT,'proof ZIP bound')
    result={}
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        infos=z.infolist()
        require(3<=len(infos)<=len(NAMES),'proof ZIP entries')
        total=0
        for info in infos:
            require(info.filename in NAMES and info.filename not in result and not info.is_dir() and
                not info.flag_bits&1 and info.compress_type in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED) and
                stat.S_IFMT(info.external_attr>>16) in (0,stat.S_IFREG) and
                0<info.file_size<=RAW_LIMIT,'proof ZIP member type/name/size')
            total+=info.file_size;require(total<=TOTAL_LIMIT,'proof ZIP expanded total')
            with z.open(info) as stream:raw=stream.read(RAW_LIMIT+1)
            require(len(raw)==info.file_size and len(raw)<=RAW_LIMIT,'proof ZIP actual member size')
            result[info.filename]=raw
    require({'protocol.json','terminal.json','started.json'}<=set(result),'mandatory proof members')
    return result

def verify_archive(data,protocol_sha,run_id):
    require(type(run_id) is str and re.fullmatch('[0-9a-f]{32}',run_id),'run identity')
    files=read_archive(data)
    verify_protocol(files['protocol.json'],protocol_sha)
    module=endpoint();protocol=parse(files['protocol.json']);terminal=parse(files['terminal.json'])
    require(canonical(terminal)==files['terminal.json'],'canonical terminal bytes')
    module.validate_terminal(terminal,protocol,run_id,files.__getitem__)
    started=parse(files['started.json']);identity=module.identity_for(run_id,protocol_sha,ENDPOINT_SHA)
    extra={'endpoint_pid','parent_pid','started_unix_ns','journal_reserved_bytes','journal_reserved_entries'}
    require(type(started) is dict and set(started)==set(identity)|extra,'started proof shape')
    require(all(canonical(started[k])==canonical(v) for k,v in identity.items()),'started identity binding')
    require(all(type(started[k]) is int and started[k]>0 for k in ('endpoint_pid','parent_pid','started_unix_ns')) and
        started['endpoint_pid']>1 and started['journal_reserved_bytes']==module.JOURNAL_RESERVED_BYTES and
        started['journal_reserved_entries']==module.JOURNAL_RESERVED_ENTRIES,'started process/quota fields')
    return dict(schema=1,protocol=protocol['protocol'],run_id=run_id,protocol_sha256=protocol_sha,
        endpoint_sha256=ENDPOINT_SHA,archive_bytes=len(data),archive_sha256=digest(data),
        receipt_sha256=digest(files['terminal.json']),status=terminal['status'],exit=terminal['exit'],
        children_absent=terminal['children_absent'],cleanup_allowed=terminal['children_absent'],
        report_sha256=terminal['report_sha256'],capture_count=sum(n.startswith('capture-') for n in files),
        cli_count=sum(n.startswith('cli-') for n in files),pair_count=sum(n.startswith('pair-') for n in files),
        purpose='training-reference-only',superiority_decision_allowed=False)

def remote_path(name):
    if name=='protocol.json':return ROOT/'downloads'/(PREFIX+'-protocol.json')
    if name in ('terminal.json','started.json'):return ROOT/'journal'/(PREFIX+'.'+name)
    return RUN/name

def collect():
    require(platform.system()=='Darwin' and platform.machine()=='arm64','native Mac ARM64 collection only')
    files={};total=0
    for name in NAMES:
        path=remote_path(name)
        try:data=checked_read(path,RAW_LIMIT,owned=True)
        except FileNotFoundError:
            require(name not in ('protocol.json','terminal.json','started.json'),'mandatory remote proof missing')
            continue
        total+=len(data);require(total<=TOTAL_LIMIT,'remote proof expanded bound');files[name]=data
    out=io.BytesIO()
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for name,data in files.items():
            info=zipfile.ZipInfo(name,(1980,1,1,0,0,0));info.external_attr=(stat.S_IFREG|0o600)<<16
            info.compress_type=zipfile.ZIP_DEFLATED;z.writestr(info,data)
    data=out.getvalue();require(len(data)<=ZIP_LIMIT,'collected ZIP bound')
    return dict(archive_bytes=len(data),archive_sha256=digest(data),archive_base64=base64.b64encode(data).decode())

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--bundle',action='store_true');modes.add_argument('--read-terminal',action='store_true')
    modes.add_argument('--verify',action='store_true');modes.add_argument('--verify-protocol',action='store_true')
    parser.add_argument('--archive');parser.add_argument('--protocol');parser.add_argument('--protocol-base64')
    parser.add_argument('--protocol-sha');parser.add_argument('--run-id');parser.add_argument('--allow-noncanonical',action='store_true')
    args=parser.parse_args()
    if args.bundle or args.read_terminal:
        require(not any((args.archive,args.protocol,args.protocol_base64,args.protocol_sha,args.run_id,args.allow_noncanonical)),
            'collection takes no paths or identity overrides')
        require(platform.system()=='Darwin' and platform.machine()=='arm64','native collection only')
        if args.read_terminal:
            data=checked_read(remote_path('terminal.json'),RAW_LIMIT,owned=True)
            require(canonical(parse(data))==data,'canonical terminal encoding')
            sys.stdout.buffer.write(data);return 0
        result=collect()
    elif args.verify:
        require(args.archive and args.protocol_sha and args.run_id and not any((args.protocol,args.protocol_base64,args.allow_noncanonical)),
            'verify argument shape')
        result=verify_archive(checked_read(Path(args.archive),ZIP_LIMIT),args.protocol_sha,args.run_id)
    else:
        require(bool(args.protocol)!=bool(args.protocol_base64) and args.protocol_sha and not args.archive and not args.run_id,
            'protocol verification argument shape')
        if args.protocol:data=checked_read(Path(args.protocol),RAW_LIMIT)
        else:
            require(len(args.protocol_base64)<=((RAW_LIMIT+2)//3)*4,'protocol wire bound')
            data=base64.b64decode(args.protocol_base64,validate=True)
        result=verify_protocol(data,args.protocol_sha,args.allow_noncanonical)
    sys.stdout.buffer.write(canonical(result));return 0

if __name__=='__main__':sys.exit(main())
