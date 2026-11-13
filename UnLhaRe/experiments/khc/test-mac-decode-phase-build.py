"""診断ビルドの先行契約。protocol、source、資源枠、失敗時の回収と保存を純粋検証する。"""
import copy
import io
import importlib.util
from pathlib import Path, PurePosixPath
import stat
import unittest
import types
import zipfile

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('phase_build',str(HERE/'mac-decode-phase-build.py'))
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)

def fixture():
    p=M.expected_protocol('a'*64,'b'*64,'c'*64,M.self_sha())
    calls=[]
    for op,sig,start,end,ok,err,value in [('group_kill',9,1,2,True,None,None),
        ('child_wait',None,3,4,True,None,0),('group_probe',0,5,6,False,3,None)]:
        calls.append(dict(operation=op,target=100,generation=1,signal=sig,start_ns=start,end_ns=end,
            ok=ok,errno=err,value=value,error=None if ok else 'ESRCH'))
    c=dict(schema=1,sequence=1,generation=1,pid=100,pgid=100,owned_new_session=True,
        primary=dict(kind='exit',returncode=0,error=None),signal_attempted=True,signal_sent=True,
        child_reaped=True,actual_returncode=0,wait_start_ns=3,wait_end_ns=4,wait_deadline_ns=3+M.FS.WAIT_NS,
        group_deadline_ns=4+M.FS.GROUP_NS,group_absent=True,group_absent_ns=6,raw_calls=calls,raw_calls_dropped=0,
        closure_error=None,complete=True,secondary_errors=[])
    r=dict(schema=1,protocol=p['protocol'],purpose=p['purpose'],source_sha256=p['source_sha256'],
        controller_sha256=p['controller_sha256'],protocol_sha256=M.digest(M.canonical(p)),root=p['root'],
        target=p['target'],cargo_command=p['cargo_command'],status='done',exit=0,runtime_seconds=10.,
        cargo_runtime_seconds=8.,binary_sha256='d'*64,wait_confirmed=True,group_absent=True,
        postchecks_ok=True,closure_proof=c,closure_sha256=M.digest(M.canonical(c)),error=None,binary_path=M.BINARY.as_posix())
    return p,r

def snapshot_fixture(extra_change=None):
    base=Path('D:/Claude/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-native-source.zip').read_bytes()
    with zipfile.ZipFile(io.BytesIO(base)) as z:
        files={n:z.read(n) for n in z.namelist() if n!='snapshot-manifest.json'}
    for name in M.CHANGED_FILES:files[name]+=b'\n// diagnostic fixture\n'
    for name in M.ADDED_FILES:files[name]=b'// diagnostic fixture\n'
    if extra_change:files[extra_change]+=b'\n// unexpected\n'
    records=[dict(path=n,bytes=len(b),sha256=M.digest(b)) for n,b in sorted(files.items())]
    manifest=M.canonical(records);out=io.BytesIO()
    with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
        for n,b in files.items():z.writestr(n,b)
        z.writestr('snapshot-manifest.json',manifest)
    data=out.getvalue();p=M.expected_protocol(M.digest(data),M.digest(manifest),'c'*64,M.self_sha())
    return base,data,p

class Build(unittest.TestCase):
    def xcode_rows(self,path,file=False):
        names=[p.as_posix() for p in reversed(PurePosixPath(path).parents)]+[path]
        return [dict(path=name,uid=0,gid=80 if name=='/Applications' else 0,
            mode=(stat.S_IFREG if file and name==path else stat.S_IFDIR)|
                 (0o775 if name=='/Applications' else 0o755)) for name in names]

    def test_readonly_xcode_accepts_only_observed_admin_applications_exception(self):
        sdk='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        M.validate_xcode_components(sdk,self.xcode_rows(sdk))
        linker='/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
        M.validate_xcode_components(linker,self.xcode_rows(linker,file=True))

    def test_readonly_xcode_rejects_write_owner_group_and_link_changes(self):
        sdk='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        original=self.xcode_rows(sdk)
        for index,key,value in [(1,'uid',501),(1,'gid',20),(1,'mode',stat.S_IFDIR|0o777),
            (2,'uid',501),(2,'gid',80),(2,'mode',stat.S_IFDIR|0o775),
            (3,'mode',stat.S_IFLNK|0o755),(-1,'mode',stat.S_IFDIR|0o777)]:
            rows=copy.deepcopy(original);rows[index][key]=value
            with self.subTest(index=index,key=key),self.assertRaises(Exception):M.validate_xcode_components(sdk,rows)
        with self.assertRaises(Exception):M.validate_xcode_components(sdk,original[1:])
        with self.assertRaises(Exception):M.validate_xcode_components('/Applications/Other.app/SDK',original)

    def test_terminal_fsync_deadline_downgrades_once_before_publication(self):
        p,r=fixture();writes=[];replacements=[]
        final=M.persist_terminal(r,p,0.,lambda value:writes.append(copy.deepcopy(value)),
            lambda value,expected:replacements.append((copy.deepcopy(value),expected)),clock=lambda:351.)
        self.assertEqual(len(writes),1);self.assertEqual(len(replacements),1)
        self.assertEqual(replacements[0][1],M.digest(M.canonical(writes[0])))
        self.assertEqual(final['status'],'failed');self.assertEqual(final['exit'],1)
        self.assertEqual(final['runtime_seconds'],351.)
        self.assertIn('terminal persistence exceeded',final['error'])
        r.update(status='failed',exit=1,error='original error',postchecks_ok=False)
        final=M.persist_terminal(r,p,0.,lambda value:None,lambda value,expected:None,clock=lambda:360.)
        self.assertTrue(final['error'].startswith('original error'))

    def test_terminal_replace_failure_never_returns_done(self):
        p,r=fixture()
        def failed_replace(*args):raise OSError('atomic replace failed')
        with self.assertRaisesRegex(OSError,'atomic replace failed'):
            M.persist_terminal(r,p,0.,lambda value:None,failed_replace,clock=lambda:351.)

    def test_supervision_admission_failure_is_timed_without_invented_closure(self):
        clock=iter((0.,2.)).__next__
        supervisor=types.SimpleNamespace(last_closure=None,run=lambda *a,**k:self.fail('spawn after admission failure'))
        def admit():raise ValueError('admission failed')
        elapsed,proof,error=M.supervise_cargo(supervisor,['fixed'],M.SOURCE,300,admit,clock=clock)
        self.assertEqual(elapsed,2.);self.assertIsNone(proof);self.assertIn('admission failed',error)

    def test_supervision_keeps_primary_error_if_auxiliary_closure_save_fails(self):
        _,receipt=fixture();proof=receipt['closure_proof']
        def failed_run(*a,**k):raise TimeoutError('primary timeout')
        def failed_save(value):raise OSError('auxiliary save failed')
        supervisor=types.SimpleNamespace(last_closure=proof,run=failed_run)
        elapsed,observed,error=M.supervise_cargo(supervisor,['fixed'],M.SOURCE,300,lambda:None,
            clock=iter((0.,1.,2.)).__next__,persist=failed_save)
        self.assertEqual(elapsed,2.);self.assertEqual(observed,proof)
        self.assertTrue(error.startswith('TimeoutError: primary timeout'))
        self.assertIn('auxiliary save failed',error)
        combined=M.bounded_errors('P'*2048,'S'*4096)
        self.assertEqual(len(combined),4096);self.assertTrue(combined.startswith('P'*2048))

    def test_environment_forces_derived_target_and_keeps_corrective_cc_sdk(self):
        profile=__import__('json').loads((HERE/'mac-native-environment.json').read_bytes())
        env=M.build_environment(profile,{'HOME':'/owner','CARGO_HOME':'/bad','RUSTC_WRAPPER':'bad','RUSTFLAGS':'bad'})
        self.assertEqual(env['PATH'],profile['environment']['PATH'])
        self.assertEqual(env['SDKROOT'],profile['environment']['SDKROOT'])
        self.assertEqual(env['CARGO_HOME'],(M.ROOT/'cargo-home').as_posix())
        for name in ('CARGO_TARGET_DIR','CARGO_BUILD_TARGET_DIR','CARGO_BUILD_BUILD_DIR'):
            self.assertEqual(env[name],M.TARGET.as_posix())
        self.assertEqual(env['TMPDIR'],(M.TARGET/'tmp').as_posix())
        self.assertEqual(env['CARGO_INCREMENTAL'],'0');self.assertEqual(env['CARGO_BUILD_JOBS'],'1')
        self.assertNotIn('RUSTC_WRAPPER',env);self.assertNotIn('RUSTFLAGS',env)

    def test_additional_cargo_reservation_and_deadline_include_close(self):
        mib=1024**2
        value=M.validate_admission(200*mib,500*mib,0,65536,8*1024**3)
        self.assertEqual(value['remaining_target_reserve_bytes'],512*mib)
        for ordinary,cargo,target in [(200*mib,513*mib,0),(200*mib,600*mib,513*mib),(1536*mib,1,0)]:
            with self.assertRaises(Exception):M.validate_admission(ordinary,cargo,target,65536,8*1024**3)
        self.assertEqual(M.cargo_timeout(0),287)
        with self.assertRaises(Exception):M.cargo_timeout(287)

    def test_helper_checks_fixed_versions_before_exec_and_does_not_retry(self):
        order=[]
        def runner(command):
            order.append(command)
            name=Path(command[0]).name
            return dict(returncode=0,stdout=(name+' 1.99.1 (native)\n').encode(),stderr=b'')
        M.cargo_transition(['fixed'],{},runner,lambda *a:order.append('exec'))
        self.assertEqual(order[-1],'exec')
        self.assertEqual([Path(c[0]).name for c in order[:-1]],['cargo','rustc','rustdoc'])
        self.assertTrue(all(c[1:]==['--version'] for c in order[:-1]))
        with self.assertRaises(Exception):
            M.cargo_transition(['fixed'],{},lambda c:dict(returncode=0,stdout=b'cargo 1.98.0\n',stderr=b''),lambda *a:self.fail('exec after version failure'))

    def test_snapshot_preserves_exact_frozen_inputs_except_five_files(self):
        base,data,p=snapshot_fixture()
        original,records,files=M.validate_source_snapshot(base,data,p)
        self.assertEqual(len(original),78);self.assertEqual(len(records),80);self.assertEqual(len(files),80)

    def test_snapshot_rejects_cargo_change_and_source_sha_swap(self):
        base,data,p=snapshot_fixture('Cargo.toml')
        with self.assertRaises(Exception):M.validate_source_snapshot(base,data,p)
        base,data,p=snapshot_fixture();p['source_sha256']='0'*64
        with self.assertRaises(Exception):M.validate_source_snapshot(base,data,p)

    def test_exact_protocol_and_recipe(self):
        p,_=fixture();M.validate_protocol(p,M.self_sha())
        self.assertEqual(len(p),29);self.assertEqual(p['cargo_command'][0],M.CARGO.as_posix())
        self.assertNotIn('+1.99.1-aarch64-apple-darwin',p['cargo_command'])
        self.assertEqual(p['total_max_bytes'],2684354560)

    def test_protocol_fixed_fields_and_unknown_are_rejected(self):
        p,_=fixture()
        for key in p:
            if key in ('source_sha256','source_manifest_sha256','generator_sha256'):continue
            q=copy.deepcopy(p);q[key]=None
            with self.subTest(key=key),self.assertRaises(Exception):M.validate_protocol(q,M.self_sha())
        q=dict(p,extra=True)
        with self.assertRaises(Exception):M.validate_protocol(q,M.self_sha())

    def test_valid_receipt_has_recomputed_closure(self):
        p,r=fixture();s=M.validate_receipt(r,p)
        self.assertEqual(len(r),21);self.assertTrue(s['cleanup_allowed']);self.assertTrue(s['verified'])

    def test_changed_raw_closure_or_false_assertions_are_rejected(self):
        p,r=fixture()
        for key,value in [('closure_sha256','0'*64),('wait_confirmed',False),('group_absent',False),
            ('controller_sha256','0'*64),('source_sha256','0'*64),('binary_path','/tmp/binary')]:
            q=copy.deepcopy(r);q[key]=value
            with self.subTest(key=key),self.assertRaises(Exception):M.validate_receipt(q,p)
        q=copy.deepcopy(r);q['closure_proof']['complete']=False
        q['closure_sha256']=M.digest(M.canonical(q['closure_proof']))
        with self.assertRaises(Exception):M.validate_receipt(q,p)

    def test_failed_closed_and_unknown_are_distinct(self):
        p,r=fixture();r.update(status='failed',exit=1,error='postcheck failure',postchecks_ok=False,
            binary_sha256=None,runtime_seconds=360.,cargo_runtime_seconds=310.)
        self.assertTrue(M.validate_receipt(r,p)['cleanup_allowed'])
        r.update(closure_proof=None,closure_sha256=None,wait_confirmed=False,group_absent=False)
        self.assertFalse(M.validate_receipt(r,p)['cleanup_allowed'])

    def test_done_requires_limits_binary_and_postchecks(self):
        p,r=fixture()
        for key,value in [('runtime_seconds',351.),('cargo_runtime_seconds',301.),('binary_sha256',None),
            ('postchecks_ok',False),('error','hidden'),('exit',1),('status','unknown')]:
            q=dict(r);q[key]=value
            with self.subTest(key=key),self.assertRaises(Exception):M.validate_receipt(q,p)

    def test_raw_helpers_bind_exact_bytes_and_reject_duplicate_keys(self):
        p,r=fixture();pb=M.canonical(p);rb=M.canonical(r)
        self.assertTrue(M.verify_protocol_bytes(pb,M.digest(pb))['verified'])
        self.assertTrue(M.verify_receipt_bytes(rb,pb)['cleanup_allowed'])
        with self.assertRaises(Exception):M.verify_receipt_bytes(rb+b' ',pb)
        with self.assertRaises(Exception):M.verify_protocol_bytes(pb+b' ',M.digest(pb+b' '))
        with self.assertRaises(Exception):M.verify_protocol_bytes(b'{"schema":1,"schema":1}', '0'*64)

if __name__=='__main__':unittest.main()
