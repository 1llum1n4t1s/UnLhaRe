"""Bounded, in-memory proof retrieval/validation contracts; no codec or disk fixtures."""
import base64
import copy
import importlib.util
import io
from pathlib import Path
import unittest
import warnings
import zipfile

HERE = Path(__file__).absolute().parent
def load(name, file):
    spec = importlib.util.spec_from_file_location(name,str(HERE/file))
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value)
    return value
M = load('proof_under_test','mac-continuous-reference-proof.py')
F = load('proof_fixture','test-mac-canterbury-continuous-reference.py')

def archive(files, extra=()):
    out=io.BytesIO()
    with warnings.catch_warnings():
        warnings.simplefilter('ignore',UserWarning)
        with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
            for name,data in list(files.items())+list(extra): z.writestr(name,data)
    return out.getvalue()

def fixture(success=True):
    p,t,raw=F.Contract().terminal_fixture(success)
    p['endpoint_sha256']=M.ENDPOINT_SHA
    ps=F.M.digest(F.M.canonical(p))
    report=F.M.REF.load_json(raw['report.json']); report['protocol_sha256']=ps
    raw['report.json']=F.M.canonical(report)
    identity=F.M.identity_for('b'*32,ps,M.ENDPOINT_SHA)
    t.update(identity)
    if success:
        t['report_sha256']=F.M.digest(raw['report.json'])
        t['report_base64']=base64.b64encode(raw['report.json']).decode()
    started=dict(identity,endpoint_pid=200,parent_pid=201,started_unix_ns=1,
        journal_reserved_bytes=F.M.JOURNAL_RESERVED_BYTES,
        journal_reserved_entries=F.M.JOURNAL_RESERVED_ENTRIES)
    raw.update({'protocol.json':F.M.canonical(p),'terminal.json':F.M.canonical(t),
                'started.json':F.M.canonical(started)})
    return p,t,raw,ps

class Proof(unittest.TestCase):
    def test_complete_archive_is_revalidated_without_extraction(self):
        _,_,files,ps=fixture()
        result=M.verify_archive(archive(files),ps,'b'*32)
        self.assertTrue(result['cleanup_allowed']); self.assertEqual(result['capture_count'],64)
        self.assertEqual(result['cli_count'],42); self.assertEqual(result['pair_count'],21)
        self.assertFalse(result['superiority_decision_allowed'])

    def test_failed_proof_retains_failure_and_checks_closure(self):
        _,_,files,ps=fixture(False)
        result=M.verify_archive(archive(files),ps,'b'*32)
        self.assertEqual(result['status'],'failed'); self.assertEqual(result['exit'],1)
        self.assertTrue(result['cleanup_allowed']); self.assertIsNone(result['report_sha256'])

    def test_unknown_closure_never_authorizes_cleanup(self):
        _,t,files,ps=fixture(False)
        closure=F.M.REF.load_json(files['closure.json']); closure['complete']=False
        files['closure.json']=F.M.canonical(closure)
        t.update(children_absent=False,closure_sha256=F.M.digest(files['closure.json']))
        files['terminal.json']=F.M.canonical(t)
        result=M.verify_archive(archive(files),ps,'b'*32)
        self.assertFalse(result['children_absent']); self.assertFalse(result['cleanup_allowed'])

    def test_duplicate_unknown_path_and_symlink_are_rejected(self):
        _,_,files,ps=fixture()
        for extra in [('terminal.json',files['terminal.json']),('../terminal.json',b'{}'),('unknown.json',b'{}')]:
            with self.subTest(extra=extra[0]),self.assertRaises(Exception):
                M.verify_archive(archive(files,[extra]),ps,'b'*32)
        out=io.BytesIO()
        with zipfile.ZipFile(out,'w') as z:
            info=zipfile.ZipInfo('terminal.json');info.external_attr=(0o120777<<16)
            z.writestr(info,b'protocol.json')
        with self.assertRaises(Exception):M.verify_archive(out.getvalue(),ps,'b'*32)

    def test_missing_and_rehashed_raw_are_rejected(self):
        _,_,files,ps=fixture()
        for name in ('protocol.json','terminal.json','started.json','capture-00.json','cli-00.json','pair-00.json'):
            changed=dict(files);del changed[name]
            with self.subTest(name=name),self.assertRaises(Exception):M.verify_archive(archive(changed),ps,'b'*32)
        changed=dict(files);changed['capture-00.json']=b'{}\n'
        with self.assertRaises(Exception):M.verify_archive(archive(changed),ps,'b'*32)

    def test_protocol_run_and_started_cross_binding(self):
        _,_,files,ps=fixture()
        for sha,run in [('f'*64,'b'*32),(ps,'c'*32)]:
            with self.assertRaises(Exception):M.verify_archive(archive(files),sha,run)
        started=F.M.REF.load_json(files['started.json']);started['endpoint_sha256']='f'*64
        files['started.json']=F.M.canonical(started)
        with self.assertRaises(Exception):M.verify_archive(archive(files),ps,'b'*32)

    def test_entry_and_expanded_total_bounds_precede_reads(self):
        _,_,files,ps=fixture()
        files['failure.json']=b'x'*(M.RAW_LIMIT+1)
        with self.assertRaises(Exception):M.verify_archive(archive(files),ps,'b'*32)
        with self.assertRaises(Exception):M.verify_archive(b'x'*(M.ZIP_LIMIT+1),ps,'b'*32)
        with self.assertRaises(Exception):M.verify_archive(b'not a zip',ps,'b'*32)

    def test_protocol_verification_is_exact_and_bounded(self):
        p,_,_,ps=fixture();data=F.M.canonical(p)
        result=M.verify_protocol(data,ps)
        self.assertEqual(result['windows_timeout_seconds'],180)
        self.assertEqual(result['endpoint_sha256'],M.ENDPOINT_SHA)
        with self.assertRaises(Exception):M.verify_protocol(data+b' ',ps)
        q=copy.deepcopy(p);q['observer_captures']=63
        data=F.M.canonical(q)
        with self.assertRaises(Exception):M.verify_protocol(data,F.M.digest(data))

if __name__=='__main__':unittest.main()
