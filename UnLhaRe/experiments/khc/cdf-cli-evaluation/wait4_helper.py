#!/usr/bin/env python3
"""Fixed wait4-helper wire. Native execution stays closed pending lifecycle binding."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import types

HERE=Path(__file__).absolute().parent
MAX_WIRE=16384

def require(ok,message):
    if not ok:raise ValueError(message)
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def digest(data):return hashlib.sha256(data).hexdigest()

def read_dependency(path):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_nlink==1 and
        info.st_size<=131072,'dependency type/bound')
    if sys.platform=='darwin':require(hasattr(os,'O_NOFOLLOW'),'Darwin nofollow required')
    flags=os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0)
    fd=os.open(str(path),flags)
    try:
        before=os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and
            (info.st_dev,info.st_ino)==(before.st_dev,before.st_ino),'dependency identity')
        blocks=[];total=0
        while True:
            data=os.read(fd,65536)
            if not data:break
            total+=len(data);require(total<=131072,'dependency read bound');blocks.append(data)
        after=os.fstat(fd);named=path.lstat()
        require((before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) and
            (named.st_dev,named.st_ino)==(after.st_dev,after.st_ino) and total==before.st_size,
            'dependency changed')
        return b''.join(blocks)
    finally:os.close(fd)

def dependency_hashes():
    return {name:digest(read_dependency(HERE/name)) for name in ('wait4_helper.py','evaluation.py','process_adapter.py')}

def evaluation(expected_sha=None):
    path=HERE/'evaluation.py';data=read_dependency(path)
    if expected_sha is not None:require(digest(data)==expected_sha,'evaluation SHA changed')
    value=types.ModuleType('cdf_fixed_helper_evaluation');value.__file__=str(path)
    # 実際に検査したbytesだけをcompileし、二度目のpath openやpycを使わない。
    exec(compile(data,str(path),'exec'),value.__dict__)
    return value

def expected_trial(index,direction,expected_pins=None):
    e=evaluation(None if expected_pins is None else expected_pins['evaluation.py'])
    require(type(index) is int and -2<=index<22 and direction in ('encode','decode'),'trial identity')
    letter=('A' if index==-2 else 'B' if index==-1 else e.schedule()[index]['letter'])
    source,archive,decoded=e.trial_paths(index)
    create,extract=e.commands(letter,source,archive,decoded)
    return (create if direction=='encode' else extract,source,60 if direction=='encode' else 20)

def expected_request(index,direction,parent_pid,expected_pins=None):
    require(type(parent_pid) is int and parent_pid>1,'supervisor parent PID')
    pins=dependency_hashes()
    if expected_pins is not None:require(pins==expected_pins,'dependency pins changed')
    command,cwd,timeout=expected_trial(index,direction,pins)
    require(dependency_hashes()==pins,'dependencies changed while building request')
    return dict(schema=1,index=index,direction=direction,parent_pid=parent_pid,command=command,cwd=cwd,
        timeout=timeout,dependency_sha256=pins)

def validate_request(value):
    require(type(value) is dict and set(value)=={'schema','index','direction','parent_pid','command','cwd','timeout',
        'dependency_sha256'} and type(value['schema']) is int and value['schema']==1,'request schema')
    pins=value['dependency_sha256']
    require(type(pins) is dict and set(pins)=={'wait4_helper.py','evaluation.py','process_adapter.py'} and
        all(type(digest_value) is str and len(digest_value)==64 and
            all(c in '0123456789abcdef' for c in digest_value) for digest_value in pins.values()),'dependency pin schema')
    require(canonical(value)==canonical(expected_request(value['index'],value['direction'],value['parent_pid'],
        expected_pins=pins)),
        'fixed request differs')
    return value

def parse_request(data):
    require(type(data) is bytes and 0<len(data)<=MAX_WIRE,'request bytes bound')
    def pairs(items):
        result={}
        for key,value in items:
            require(key not in result,'duplicate request key');result[key]=value
        return result
    result=json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError('nonfinite')))
    require(canonical(result)==data,'canonical request required')
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--verify-request-base64');group.add_argument('--run-request-base64')
    args=parser.parse_args();wire=args.verify_request_base64 or args.run_request_base64
    require(type(wire) is str and 0<len(wire)<=((MAX_WIRE+2)//3)*4,'request wire bound')
    data=base64.b64decode(wire,validate=True);value=validate_request(parse_request(data))
    if args.run_request_base64:
        raise RuntimeError('Native helper execution is closed until authenticated lifecycle and pending-run binding exist.')
    sys.stdout.buffer.write(canonical(dict(schema=1,verified=True,request_sha256=digest(data),
        helper_sha256=value['dependency_sha256']['wait4_helper.py'])))
    return 0

if __name__=='__main__':sys.exit(main())
