#!/usr/bin/env python3
"""CDF ablation: fixed trial plan, checked I/O and decision rules.

Native invocation is intentionally unavailable until the registered supervisor,
continuous observer, immutable witness and an approved finite campaign budget are
bound. Injected drivers are for pure validation; they do not authorize execution.
"""
import hashlib
import base64
import copy
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import statistics

ROOT=PurePosixPath('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019')
CLI={'A':ROOT/'cargo-target/aarch64-apple-darwin/release/unlhare-cli',
     'B':ROOT/'cargo-target/cdf-chooser-candidate-20261027/aarch64-apple-darwin/release/unlhare-cli'}
CLI_SHA={'A':'5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629',
         'B':'cc36350705aff86fb4c8bf36e9d6f3d409c1fd4bf6b3d4fd6f1853e5add22632'}
SOURCE_SHA={'A':'030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f',
            'B':'36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05'}
MANIFEST_RAW_SHA='458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af'
MANIFEST_CONTENT_SHA='bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
INPUT_ZIP_SHA='29d1f681371d50819a904a9fc4639c276268fa631b709f9b4afe9398857d7b71'
# Proposed only: no remote registration or execution authorization is implied.
RUN=ROOT/'tmp/cdf-chooser-evaluation-20261027'
NAMES=('alice29.txt','asyoulik.txt','cp.html','fields.c','grammar.lsp','kennedy.xls','lcet10.txt',
       'plrabn12.txt','ptt5','sum','xargs.1')
ORDERS=('AB','BA','BA','AB','AB','BA','BA','AB','AB','BA')
RSS_LIMIT=134217728
ENCODE_TIMEOUT=60
DECODE_TIMEOUT=20

class InvalidRun(ValueError):
    def __init__(self,message,*,failure_record=None):
        super().__init__(message);self.failure_record=failure_record
class Rejected(ValueError):pass
class IntegrationUnavailable(RuntimeError):pass
def require(ok,message):
    if not ok:raise ValueError(message)
def sha(data):return hashlib.sha256(data).hexdigest()
def valid_sha(value):return type(value) is str and re.fullmatch('[0-9a-f]{64}',value) is not None

def validate_resource_budget(ordinary,cargo,reserved_ordinary,reserved_cargo,other,free_bytes):
    values=(ordinary,cargo,reserved_ordinary,reserved_cargo,other,free_bytes)
    require(all(type(n) is int and n>=0 for n in values),'resource counters')
    ordinary_total=ordinary+reserved_ordinary;cargo_total=cargo+reserved_cargo
    require(ordinary_total<=1610612736 and cargo_total<=1073741824 and
        ordinary_total+cargo_total<=2684354560 and ordinary_total+cargo_total+other<=3221225472,
        'ordinary/Cargo/total/overall cap')
    require(free_bytes>=5*1024**3+reserved_ordinary+reserved_cargo,'free space reservation')

def validate_manifest(data):
    require(type(data) is bytes and len(data)<=65536 and sha(data)==MANIFEST_RAW_SHA,'raw input manifest SHA/bound')
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'duplicate manifest key');result[key]=value
        return result
    value=json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
    require(type(value) is dict and set(value)=={'schema','corpus','purpose','files','bytes','manifest_sha256',
        'source_container_sha256','entries'} and type(value['schema']) is int and value['schema']==1 and
        value['corpus']=='Canterbury11' and value['purpose']=='training-reference-only' and value['files']==11 and
        value['bytes']==2810784 and value['manifest_sha256']==MANIFEST_CONTENT_SHA and
        value['source_container_sha256']=='b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb',
        'manifest identity')
    entries=value['entries'];require(type(entries) is list and len(entries)==11,'manifest entries')
    lines=[]
    for name,row in zip(NAMES,entries):
        require(type(row) is dict and set(row)=={'name','bytes','sha256'} and row['name']==name and
            type(row['bytes']) is int and 0<=row['bytes']<=2810784 and valid_sha(row['sha256']),'manifest record')
        lines.append('%s\t%d\t%s\n'%(name,row['bytes'],row['sha256']))
    require(sum(row['bytes'] for row in entries)==2810784 and sha(''.join(lines).encode())==MANIFEST_CONTENT_SHA,
        'manifest complete records')
    return value

def schedule():
    result=[dict(round=-1,position=i,letter=letter,order='AB',warmup=True) for i,letter in enumerate('AB')]
    for number,order in enumerate(ORDERS):
        result.extend(dict(round=number,position=i,letter=letter,order=order,warmup=False)
                      for i,letter in enumerate(order))
    return result

def commands(letter,source,archive,decoded):
    require(letter in CLI,'method')
    for path in (source,archive,decoded):
        require(type(path) is str and PurePosixPath(path).is_absolute() and '..' not in PurePosixPath(path).parts,
            'absolute normalized command path')
    binary=str(CLI[letter])
    return ([binary,'khc-create',archive,'--source',source,'--strategy','portfolio-trial'],
            [binary,'khc-extract',archive,'--output',decoded])

def trial_paths(index):
    require(type(index) is int and -2<=index<22,'trial index')
    base=('preflight-A' if index==-2 else 'preflight-B' if index==-1 else '%02d'%index)
    return tuple(str(p) for p in (RUN/'input',RUN/(base+'-archive.khc'),RUN/(base+'-restored')))

def read_checked_file(directory_fd,name,expected_size,expected_sha):
    """Read regular single-link file via its verified directory; no symlink/FIFO following."""
    fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK,dir_fd=directory_fd)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and before.st_uid==os.getuid() and
            before.st_size==expected_size,'file owner/type/link/size')
        h=hashlib.sha256();total=0
        while True:
            data=os.read(fd,65536)
            if not data:break
            total+=len(data);require(total<=expected_size,'file grew while reading');h.update(data)
        after=os.fstat(fd)
        require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) and total==expected_size and
            h.hexdigest()==expected_sha,'file bytes or identity changed')
    finally:os.close(fd)

def verify_tree(directory,manifest,check_path):
    """A bound setup adapter must inspect all path ancestors before and after this check."""
    check_path(directory)
    fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd)
        require(stat.S_ISDIR(before.st_mode) and before.st_uid==os.getuid(),'directory owner/type')
        require(sorted(os.listdir(fd))==sorted(NAMES),'exact 11-file tree, no extra names')
        for row in manifest['entries']:read_checked_file(fd,row['name'],row['bytes'],row['sha256'])
        after=os.fstat(fd)
        require((before.st_dev,before.st_ino)==(after.st_dev,after.st_ino),'directory changed')
        absolute=os.lstat(directory)
        require(not stat.S_ISLNK(absolute.st_mode) and (absolute.st_dev,absolute.st_ino)==
            (after.st_dev,after.st_ino),'directory path replaced')
    finally:os.close(fd)
    check_path(directory)
    return MANIFEST_CONTENT_SHA

def archive_record(path,check_path):
    check_path(str(PurePosixPath(path).parent))
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid==os.getuid() and before.st_nlink==1 and
            0<before.st_size<=3145728,'archive owner/type/link/bound')
        h=hashlib.sha256();total=0
        while True:
            data=os.read(fd,65536)
            if not data:break
            total+=len(data);require(total<=3145728,'archive grew');h.update(data)
        after=os.fstat(fd);named=os.lstat(path)
        require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) and
            (named.st_dev,named.st_ino)==(after.st_dev,after.st_ino) and total==before.st_size,
            'archive changed or replaced')
        return dict(archive_bytes=total,archive_sha256=h.hexdigest())
    finally:os.close(fd)

def compare_archive_bytes(reference,path,check_path):
    """Byte-for-byte comparison, including metadata, without trusting equal hashes alone."""
    check_path(str(PurePosixPath(reference).parent));check_path(str(PurePosixPath(path).parent))
    fds=[];before=[]
    try:
        for name in (reference,path):
            fd=os.open(name,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK);fds.append(fd);info=os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid==os.getuid() and info.st_nlink==1 and
                0<info.st_size<=3145728,'archive comparison file')
            before.append(info)
        def ensure_stable():
            for fd,name,original in zip(fds,(reference,path),before):
                after=os.fstat(fd);named=os.lstat(name)
                if ((original.st_dev,original.st_ino,original.st_size,original.st_mtime_ns)!=
                    (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) or
                    (named.st_dev,named.st_ino)!=(after.st_dev,after.st_ino)):
                    raise InvalidRun('archive changed during comparison')
        if before[0].st_size!=before[1].st_size:
            ensure_stable();raise Rejected('archive sizes differ')
        def read_exact(fd,count):
            chunks=[];remaining=count
            while remaining:
                part=os.read(fd,remaining)
                if not part:raise InvalidRun('archive truncated during comparison')
                if len(part)>remaining:raise InvalidRun('invalid read length')
                chunks.append(part);remaining-=len(part)
            return b''.join(chunks)
        remaining=before[0].st_size;different=False
        while remaining:
            count=min(65536,remaining)
            if read_exact(fds[0],count)!=read_exact(fds[1],count):different=True
            remaining-=count
        if os.read(fds[0],1) or os.read(fds[1],1):raise InvalidRun('archive grew during comparison')
        ensure_stable()
        if different:raise Rejected('archive bytes differ')
    finally:
        for fd in fds:os.close(fd)

def execute_trial(index,manifest,adapter):
    """Injected boundary: adapter must supply finite supervisor, CPU observer and storage gate.

    No implementation of that adapter is supplied here; this is not a live entry point.
    `invoke` returns exact metrics, raw closure and host evidence already verified by
    the bound adapters, plus bounded captured stdout/stderr. Any exception aborts.
    """
    source,archive,decoded=trial_paths(index)
    item=(dict(round=-2,position=index+2,letter='A' if index==-2 else 'B',order='AB',warmup=False)
          if index<0 else schedule()[index])
    adapter.admit();adapter.verify_binary(str(CLI[item['letter']]),CLI_SHA[item['letter']])
    adapter.require_unused(archive);adapter.require_unused(decoded)
    def checked_input():
        try:return verify_tree(source,manifest,adapter.check_path)
        except (ValueError,OSError) as error:raise InvalidRun('input tree unavailable or changed') from error
    checked_input()
    adapter.create_private_directory(decoded)
    create,extract=commands(item['letter'],source,archive,decoded)
    observations=[]
    for command,timeout in ((create,ENCODE_TIMEOUT),(extract,DECODE_TIMEOUT)):
        adapter.admit()
        # Continuous reference sets cwd to the input directory for both commands.
        observed=adapter.invoke(command,timeout=timeout,cwd=source)
        require(type(observed) is dict and set(observed)=={'metric','closure_proof','host_observation',
            'stdout','stderr'},'adapter observation shape')
        observed=copy.deepcopy(observed)
        _metric(observed['metric'])
        if (adapter.validate_closure(copy.deepcopy(observed['closure_proof'])) is not True or
            adapter.validate_host(copy.deepcopy(observed['host_observation'])) is not True or
            observed['metric']['elapsed_ns']>timeout*10**9 or observed['metric']['cpu_per_wall']>1.2):
            raise InvalidRun('unknown closure, host observation or deadline')
        require(all(type(observed[k]) is bytes for k in ('stdout','stderr')) and
            sum(len(observed[k]) for k in ('stdout','stderr'))<=65536,'child output bound')
        observations.append(observed)
    checked_input()
    try:restored=verify_tree(decoded,manifest,adapter.check_path)
    except FileNotFoundError as error:raise Rejected('restored tree missing') from error
    except ValueError as error:raise Rejected('restored tree differs or is unsafe') from error
    except OSError as error:raise InvalidRun('restored tree could not be observed') from error
    for name in NAMES:
        try:compare_archive_bytes(str(PurePosixPath(source)/name),str(PurePosixPath(decoded)/name),adapter.check_path)
        except Rejected:raise
        except (ValueError,OSError) as error:raise InvalidRun('source or restored bytes became unobservable') from error
    archived=archive_record(archive,adapter.check_path)
    adapter.verify_binary(str(CLI[item['letter']]),CLI_SHA[item['letter']])
    adapter.admit()
    raw=[dict(command=cmd,cwd=source,metric=copy.deepcopy(obs['metric']),
        stdout_base64=base64.b64encode(obs['stdout']).decode(),
        stderr_base64=base64.b64encode(obs['stderr']).decode(),stdout_sha256=sha(obs['stdout']),
        stderr_sha256=sha(obs['stderr']),closure_proof=copy.deepcopy(obs['closure_proof']),
        host_observation=copy.deepcopy(obs['host_observation']))
        for cmd,obs in zip((create,extract),observations)]
    evidence_sha=sha(json.dumps([o['host_observation'] for o in observations],sort_keys=True,
        separators=(',',':'),allow_nan=False).encode())
    return dict(**item,encode=copy.deepcopy(observations[0]['metric']),decode=copy.deepcopy(observations[1]['metric']),**archived,
        restored_manifest_sha256=restored,closure_verified=True,host_eligible=True,host_evidence_sha256=evidence_sha),raw

def _evaluate_injected(manifest_data,preflight_evidence,adapter):
    """Exercise the fixed plan through an injected adapter; never itself creates processes.

    The adapter's correctness proof, registration, quota and observer checks are
    intentionally not implemented here and must be independently bound before use.
    """
    manifest=validate_manifest(manifest_data)
    if adapter.verify_preflight(preflight_evidence,SOURCE_SHA,CLI_SHA) is not True:
        raise InvalidRun('independent witness/source/safety/build proof not verified')
    preflight=[];raw=[]
    for index in (-2,-1):
        row,evidence=execute_trial(index,manifest,adapter);preflight.append(row);raw.extend(evidence)
    baseline=(preflight[0]['archive_bytes'],preflight[0]['archive_sha256'])
    if (preflight[1]['archive_bytes'],preflight[1]['archive_sha256'])!=baseline:
        raise Rejected('preflight archive bytes differ')
    baseline_path=trial_paths(-2)[1]
    compare_archive_bytes(baseline_path,trial_paths(-1)[1],adapter.check_path)
    rows=[]
    for index in range(22):
        row,evidence=execute_trial(index,manifest,adapter)
        if (row['archive_bytes'],row['archive_sha256'])!=baseline:raise Rejected('trial archive bytes differ')
        compare_archive_bytes(baseline_path,trial_paths(index)[1],adapter.check_path)
        rows.append(row);raw.extend(evidence)
    final_observation=copy.deepcopy(adapter.finish_campaign())
    if adapter.validate_final_observation(copy.deepcopy(final_observation)) is not True:
        raise InvalidRun('final continuous observation incomplete or ineligible')
    return dict(preflight=preflight,trials=rows,raw=raw,final_observation=final_observation,decision=assess(rows))

def evaluate_injected(manifest_data,preflight_evidence,adapter):
    try:return _evaluate_injected(manifest_data,preflight_evidence,adapter)
    except (InvalidRun,Rejected):raise
    except Exception as error:
        record=dict(type=type(error).__name__,message=str(error)[:2048])
        for key in ('failures','closure','event'):
            if hasattr(error,key):record[key]=copy.deepcopy(getattr(error,key))
        output=getattr(error,'output',None)
        if type(output) is bytes:record['output_base64']=base64.b64encode(output[:131072]).decode()
        raise InvalidRun('unexpected backend or observer failure',failure_record=record) from error

def _metric(row):
    require(type(row) is dict and set(row)=={'elapsed_ns','peak_rss_bytes','normal_exit','exit_code','signal',
        'user_seconds','system_seconds','cpu_per_wall'},
        'metric shape')
    if (type(row['elapsed_ns']) is not int or row['elapsed_ns']<=0 or type(row['peak_rss_bytes']) is not int or
        row['peak_rss_bytes']<=0 or type(row['cpu_per_wall']) not in (int,float) or not math.isfinite(row['cpu_per_wall']) or
        row['cpu_per_wall']<0 or row['normal_exit'] is not True or type(row['exit_code']) is not int or
        row['exit_code']!=0 or row['signal'] is not None):raise InvalidRun('child metric/exit invalid')
    if (any(type(row[k]) not in (int,float) or not math.isfinite(row[k]) or row[k]<0
            for k in ('user_seconds','system_seconds')) or
        not math.isclose((row['user_seconds']+row['system_seconds'])*1e9/row['elapsed_ns'],
                         row['cpu_per_wall'],rel_tol=1e-12,abs_tol=1e-12)):
        raise InvalidRun('CPU accounting mismatch')

def assess(rows):
    if type(rows) is not list or len(rows)!=22:raise InvalidRun('fixed warmup and ten pairs required')
    expected=schedule();pairs=[];reference=None
    for index,(row,item) in enumerate(zip(rows,expected)):
        require(type(row) is dict and set(row)==set(item)|{'encode','decode','archive_bytes','archive_sha256',
            'restored_manifest_sha256','closure_verified','host_eligible','host_evidence_sha256'},'trial schema')
        if any(type(row[k]) is not type(v) or row[k]!=v for k,v in item.items()):raise InvalidRun('trial order')
        if row['closure_verified'] is not True or row['host_eligible'] is not True or not valid_sha(row['host_evidence_sha256']):
            raise InvalidRun('closure or continuous host observation unavailable/ineligible')
        for direction,limit in (('encode',ENCODE_TIMEOUT),('decode',DECODE_TIMEOUT)):
            _metric(row[direction])
            if row[direction]['elapsed_ns']>limit*10**9 or row[direction]['cpu_per_wall']>1.2:
                raise InvalidRun('timeout or CPU/wall ineligible')
        if not valid_sha(row['archive_sha256']) or type(row['archive_bytes']) is not int or row['archive_bytes']<=0:
            raise InvalidRun('archive evidence')
        if row['restored_manifest_sha256']!=MANIFEST_CONTENT_SHA:raise Rejected('restored files mismatch')
        current=(row['archive_bytes'],row['archive_sha256'])
        if reference is None:reference=current
        elif current!=reference:raise Rejected('archive bytes differ')
        if index>=2 and index%2==1:
            left,right=rows[index-1:index+1];by={left['letter']:left,right['letter']:right}
            pairs.append((by['B']['decode']['elapsed_ns']/by['A']['decode']['elapsed_ns'],item['order']))
    measured=rows[2:];ratios=[v for v,_ in pairs]
    subgroup={order:statistics.median(v for v,o in pairs if o==order) for order in ('AB','BA')}
    a=[r for r in measured if r['letter']=='A'];b=[r for r in measured if r['letter']=='B']
    encode_ratio=statistics.median(r['encode']['elapsed_ns'] for r in b)/statistics.median(r['encode']['elapsed_ns'] for r in a)
    violations=[]
    if statistics.median(ratios)>0.95 or any(x>0.95 for x in subgroup.values()) or sorted(ratios)[-2]>=1:
        violations.append('decode thresholds')
    if encode_ratio>1.05:violations.append('encode threshold')
    for direction in ('encode','decode'):
        amax=max(r[direction]['peak_rss_bytes'] for r in a);bmax=max(r[direction]['peak_rss_bytes'] for r in b)
        if max(amax,bmax)>RSS_LIMIT or bmax>max(amax*1.05,amax+2097152):violations.append(direction+' RSS')
    return dict(decision='rejected' if violations else 'eligible-for-integration',violations=violations,
        decode_ratios=ratios,decode_median=statistics.median(ratios),subgroup_medians=subgroup,
        second_largest=sorted(ratios)[-2],encode_median_ratio=encode_ratio)

def run_native(*_args,**_kwargs):
    raise IntegrationUnavailable('No registered supervisor/observer, correctness evidence or approved campaign bounds are bound.')
