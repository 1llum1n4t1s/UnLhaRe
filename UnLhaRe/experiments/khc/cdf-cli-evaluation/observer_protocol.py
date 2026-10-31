#!/usr/bin/env python3
"""Proposed finite 48-event observer contract; live entry remains disabled.

The short fixed window is not guaranteed to contain all maximum-duration children.
Missing coverage or any deadline breach invalidates the run, with no retry.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import time
import types

HERE=Path(__file__).absolute().parent
OBSERVER_PATH=HERE.parent/'mac-continuous-cpu-observer.py'
OBSERVER_SHA='416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
FS_SHA='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
EVALUATION_SHA='62baa11eb38d06c7288cbebb4022ef2422804f06b3d31571065a0d5db25a1c74'
ADAPTER_SHA='76cd4763b2873f10a2beed4e50efdfffe51de7dc6263e9242e80a2441ae06a9f'
HELPER_SHA='08c0be03d8b3d119bbccbd7a5497a3adc90e5257d3b52f43f8a9e63594b05f4b'
METRICS_SHA='31955203a22b4128b956e86daa4bffb653e513bb31682d63a9b8b5941df8d5ba'
CADENCE_NS=1_250_000_000
CAPTURE_COUNT=240
EVENT_COUNT=48
MAX_RAW_BYTES=1048576
MAX_CAPTURE_BYTES=4096

class IntegrationUnavailable(RuntimeError):pass
def require(ok,message):
    if not ok:raise ValueError(message)
def canonical(value):return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()
def last_capture_seconds():return ((CAPTURE_COUNT-1)*CADENCE_NS+50_000_000+200_000_000)/1e9

def frozen_module(path,expected,name):
    info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and not stat.S_ISLNK(info.st_mode) and info.st_nlink==1 and
        info.st_size<=131072,'frozen observer type/bound')
    if os.name=='posix':require(hasattr(os,'O_NOFOLLOW') and hasattr(os,'O_NONBLOCK'),'nofollow/nonblock support')
    flags=os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0)
    fd=os.open(str(path),flags)
    try:
        before=os.fstat(fd);require(stat.S_ISREG(before.st_mode) and before.st_nlink==1 and
            (info.st_dev,info.st_ino)==(before.st_dev,before.st_ino),'observer same-handle identity')
        data=b''
        while len(data)<=131072:
            part=os.read(fd,min(65536,131073-len(data)))
            if not part:break
            data+=part
        after=os.fstat(fd);named=path.lstat()
        require(len(data)<=131072 and len(data)==before.st_size==after.st_size and
            (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)==
            (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) and
            (named.st_dev,named.st_ino)==(after.st_dev,after.st_ino) and
            hashlib.sha256(data).hexdigest()==expected,'frozen module SHA/identity')
    finally:os.close(fd)
    result=types.ModuleType(name);result.__file__=str(path)
    exec(compile(data,str(path),'exec'),result.__dict__)
    return result

def frozen_observer():return frozen_module(OBSERVER_PATH,OBSERVER_SHA,'cdf_frozen_continuous_observer')
def frozen_evaluation():return frozen_module(HERE/'evaluation.py',EVALUATION_SHA,'cdf_frozen_evaluation')
def frozen_supervisor():return frozen_module(HERE.parent/'mac-finite-supervisor.py',FS_SHA,'cdf_frozen_supervisor')

def expected_protocol(controller_sha):
    require(type(controller_sha) is str and len(controller_sha)==64 and
        all(c in '0123456789abcdef' for c in controller_sha),'controller SHA')
    return dict(schema=1,protocol='khc-cdf-chooser-observer-v1',controller_sha256=controller_sha,
        observer_sha256=OBSERVER_SHA,supervisor_sha256=FS_SHA,evaluation_sha256=EVALUATION_SHA,
        process_adapter_sha256=ADAPTER_SHA,wait4_helper_sha256=HELPER_SHA,
        system_metrics_sha256=METRICS_SHA,logical_cpus=14,capture_count=CAPTURE_COUNT,
        cadence_ns=CADENCE_NS,entry_windows=3,max_capture_ns=200000000,max_start_late_ns=50000000,
        cpu_baseline_limit_percent=15,cpu_interval_limit_percent=30,thermal_state_required=0,ac_power_required=True,
        cpu_per_wall_eligibility_max=1.2,rss_eligibility_bytes=134217728,event_count=EVENT_COUNT,
        native_timeout_seconds=350,windows_timeout_seconds=360,observer_start_max_seconds=8,
        event_coverage_wait_seconds=4,closure_reserve_seconds=13,final_reserve_seconds=20,join_chunk_seconds=10,
        capture_stream_max_bytes=MAX_RAW_BYTES,final_observer_max_bytes=MAX_RAW_BYTES,
        event_bindings_max_bytes=MAX_RAW_BYTES,capture_stream_max_entries=1,final_observer_max_entries=1,
        event_bindings_max_entries=1,max_capture_record_bytes=MAX_CAPTURE_BYTES,
        automatic_retry=False,superiority_decision_allowed=False)

def validate_protocol(value,controller_sha):
    require(type(value) is dict and canonical(value)==canonical(expected_protocol(controller_sha)),'fixed observer protocol')
    require(value['observer_start_max_seconds']+last_capture_seconds()+value['closure_reserve_seconds']+
        value['final_reserve_seconds']<=value['native_timeout_seconds']<value['windows_timeout_seconds'],
        'observer/closure/final deadline plan')

def validate_observer(raw):
    keys={'schema','cadence_ns','max_captures','completed','captures','events','failure','epoch_ns'}
    require(type(raw) is dict and set(raw) in (keys,keys|{'validation'}) and len(canonical(raw))<=MAX_RAW_BYTES and
        raw.get('max_captures')==CAPTURE_COUNT and
        type(raw.get('max_captures')) is int and raw.get('completed') is True and type(raw.get('captures')) is list and
        len(raw['captures'])==CAPTURE_COUNT and type(raw.get('events')) is list and len(raw['events'])==EVENT_COUNT,
        'observer full capture/event/bound')
    obs=frozen_observer();verdict=obs.validate_report(raw)
    if 'validation' in raw:require(raw['validation']==verdict,'stored observer validation differs')
    require(verdict['eligible'] is True and not verdict['errors'] and
        len(verdict['events'])==EVENT_COUNT and all(e['state']=='covered' for e in verdict['events']),
        'observer eligibility')
    events=raw['events'];captures=raw['captures']
    require(all(type(e['end_ns']) is int for e in events) and
        all(a['end_ns']<=b['start_ns'] for a,b in zip(events,events[1:])) and
        events[-1]['end_ns']<captures[-1]['start_ns'],'event ordering/final capture')
    validate_event_deadline(events[-1]['end_ns'])
    return verdict

def validate_start_timing(native_begin_ns,observer_epoch_ns):
    require(type(native_begin_ns) is int and type(observer_epoch_ns) is int and
        0<=observer_epoch_ns-native_begin_ns<=8_000_000_000,'observer start deadline')

def runtime_deadlines(native_begin_ns):
    require(type(native_begin_ns) is int and native_begin_ns>=0,'native start monotonic ns')
    return dict(observer_start_ns=native_begin_ns+8_000_000_000,
        observer_finish_ns=native_begin_ns+317_000_000_000,
        closure_finish_ns=native_begin_ns+330_000_000_000,
        native_finish_ns=native_begin_ns+350_000_000_000)

def validate_event_deadline(event_end_ns):
    require(type(event_end_ns) is int and 0<=event_end_ns<(CAPTURE_COUNT-1)*CADENCE_NS,
        'last event must finish before final scheduled capture')

def _expected_event(e,event_id):
    require(type(event_id) is int and 0<=event_id<EVENT_COUNT,'event ID')
    trial=(-2,-1,*range(22))[event_id//2]
    letter='A' if trial==-2 else 'B' if trial==-1 else e.schedule()[trial]['letter']
    source,archive,decoded=e.trial_paths(trial)
    commands=e.commands(letter,source,archive,decoded)
    direction='encode' if event_id%2==0 else 'decode'
    return trial,direction,commands[event_id%2],source

def expected_event(event_id):return _expected_event(frozen_evaluation(),event_id)

def validate_bindings(raw,bindings):
    validate_observer(raw)
    require(type(raw.get('epoch_ns')) is int and raw['epoch_ns']>=0,'observer epoch identity')
    require(type(bindings) is list and len(bindings)==EVENT_COUNT,'event binding count')
    e=frozen_evaluation();fs=frozen_supervisor();previous_sequence=None
    for index,(binding,event) in enumerate(zip(bindings,raw['events'])):
        require(type(binding) is dict and set(binding)=={'event_id','trial_index','direction','command','cwd',
            'start_ns','end_ns','closure'},'event binding shape')
        trial,direction,command,cwd=_expected_event(e,index)
        require(type(binding['event_id']) is int and binding['event_id']==index and
            type(binding['trial_index']) is int and binding['trial_index']==trial and
            binding['direction']==direction and binding['command']==command and binding['cwd']==cwd and
            type(binding['start_ns']) is int and type(binding['end_ns']) is int and
            binding['start_ns']==event['start_ns'] and binding['end_ns']==event['end_ns'],'event command/time binding')
        closure=binding['closure']
        require(type(closure) is dict and set(closure)=={'raw','expected_pid','expected_sequence'} and
            type(closure['expected_pid']) is int and closure['expected_pid']>1 and
            type(closure['expected_sequence']) is int and closure['expected_sequence']>0,'closure binding shape')
        sequence=closure['expected_sequence'];proof=closure['raw']
        require(previous_sequence is None or sequence==previous_sequence+1,'closure sequence continuity')
        require(type(proof) is dict and type(proof.get('primary')) is dict and
            proof['primary'].get('kind')=='exit' and type(proof['primary'].get('returncode')) is int and
            proof['primary']['returncode']==0 and type(proof.get('actual_returncode')) is int and
            proof['actual_returncode']==0 and
            fs.validate_closure(proof,closure['expected_pid'],sequence) is True,'closure not normal/owned')
        start=raw['epoch_ns']+event['start_ns'];end=raw['epoch_ns']+event['end_ns']
        calls=proof.get('raw_calls')
        require(type(calls) is list and bool(calls) and
            all(type(call) is dict and type(call.get('start_ns')) is int and type(call.get('end_ns')) is int and
                start<=call['start_ns']<=call['end_ns']<=end for call in calls) and
            type(proof.get('wait_start_ns')) is int and type(proof.get('wait_end_ns')) is int and
            type(proof.get('group_absent_ns')) is int and
            start<=proof['wait_start_ns']<=proof['wait_end_ns']<=proof['group_absent_ns']<=end,
            'closure timestamps outside observer event')
        previous_sequence=sequence
    return True

def validate_complete_evidence(raw,bindings,*,native_begin_ns,completed_ns):
    require(type(raw) is dict and type(raw.get('epoch_ns')) is int and type(completed_ns) is int,
        'observer timing identity')
    validate_start_timing(native_begin_ns,raw['epoch_ns'])
    deadlines=runtime_deadlines(native_begin_ns)
    require(type(raw.get('captures')) is list and raw['captures'] and type(raw['captures'][-1]) is dict and
        type(raw['captures'][-1].get('end_ns')) is int and
        raw['epoch_ns']+raw['captures'][-1]['end_ns']<=completed_ns<=deadlines['observer_finish_ns'],
        'observer completion deadline')
    validate_bindings(raw,bindings)
    raw_bytes=canonical(raw);binding_bytes=canonical(bindings)
    require(len(raw_bytes)<=MAX_RAW_BYTES and len(binding_bytes)<=MAX_RAW_BYTES,'observer evidence bound')
    return dict(eligible=True,event_count=EVENT_COUNT,capture_count=CAPTURE_COUNT,
        observer_sha256=hashlib.sha256(raw_bytes).hexdigest(),
        binding_sha256=hashlib.sha256(binding_bytes).hexdigest(),
        windows_job_status='not_asserted',lifecycle_binding='not_asserted',live_process_identity='not_asserted')

def new_observer(capture,*,on_failure,on_capture):
    """Create, but never start, the frozen observer with bounded capture records.

    Capture must already be provided by a separately authenticated, 200ms-bounded
    native system-metrics adapter. Callback persistence/accounting is external.
    """
    require(callable(capture) and callable(on_failure) and callable(on_capture),'observer callbacks')
    obs=frozen_observer();count=[0];size=[0]
    def capture_bounded():
        value=capture();obs.validate_environment(value)
        require(len(canonical(value))<=MAX_CAPTURE_BYTES,'native capture bound')
        return value
    def save_bounded(record):
        raw=canonical(record);count[0]+=1;size[0]+=len(raw)
        require(count[0]<=CAPTURE_COUNT and len(raw)<=MAX_CAPTURE_BYTES and size[0]<=MAX_RAW_BYTES,
            'capture stream bound')
        on_capture(record)
    return obs.Observer(capture_bounded,on_failure=on_failure,on_capture=save_bounded,max_captures=CAPTURE_COUNT)

def await_complete(observer,*,deadline,clock=time.monotonic):
    while True:
        remaining=deadline-clock();require(remaining>0,'observer join deadline')
        if observer.join(min(10.,remaining)):
            require(clock()<deadline,'observer join deadline')
            result=validate_observer(observer.report())
            require(clock()<deadline,'observer validation deadline')
            return result

def create_native_observer(*_args,**_kwargs):
    raise IntegrationUnavailable('Native metrics, lifecycle, authenticated bounds and failure persistence are not bound.')
