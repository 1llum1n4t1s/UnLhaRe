"""コーデック・プロセス・ファイル生成を伴わない契約検証。"""
import ast
import contextlib
import copy
import importlib.util
import io
from pathlib import Path
import time
import types
import unittest
from unittest.mock import MagicMock

# SHA458a...の正本から得た11件。payloadは生成しない。
ENTRIES = [dict(name=n,bytes=b,sha256=s) for n,b,s in [
    ('alice29.txt',152089,'7467306ee0feed4971260f3c87421154a05be571d944e9cb021a5713700c38f0'),
    ('asyoulik.txt',125179,'eaa3526fe53859f34ecdf255712f9ecf0b2c903451d4755b2edaa2e2599cb0fc'),
    ('cp.html',24603,'e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61'),
    ('fields.c',11150,'85d73e354cc50cec76cb5a50537cf8dc035f8cbb8480f9e1cbe2f7d6c23393c7'),
    ('grammar.lsp',3721,'1b0805dfc0ae706b35aac2bb4e15f02485efd24dda5dbd29de7b2f84d1a88c15'),
    ('kennedy.xls',1029744,'9af47239ca29dfe20e633f80bbbb9a4cc9783d0803d7b2b5626f42e4c3790420'),
    ('lcet10.txt',426754,'5314ba1dbb03f471df88bec6cd120a938ef60d0fd3511c5c1dce61bf7463245f'),
    ('plrabn12.txt',481861,'07e2e0b461af78c7c647cb53dab39de560198e16f799b4516eccf0fbd69f764c'),
    ('ptt5',513216,'0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'),
    ('sum',38240,'ee5733cd76ecc2f9d8ff156adc3c02a7a851051dcf43a2d56ff4ee4ff606bdb3'),
    ('xargs.1',4227,'c58aeb5d2d1e12751d47e7412b45784405fc30a5671b03d480fa05776e183619')]]

PATH = Path(__file__).with_name('mac-canterbury-continuous-reference.py')
spec = importlib.util.spec_from_file_location('continuous_reference', PATH)
M = importlib.util.module_from_spec(spec)
spec.loader.exec_module(M)


class Contract(unittest.TestCase):
    def test_outer_report_validation_failure_keeps_failed_receipt_inspectable(self):
        # 実mainのcampaign tryからterminal構築までをmemory I/Oで通す。
        # platform/preflightだけを省き、問題のexcept/finally分岐は原コードを実行する。
        tree = ast.parse(PATH.read_text(encoding='utf-8'))
        main = next(node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name == 'main')
        start = next(i for i,node in enumerate(main.body) if isinstance(node,ast.Try) and
                     isinstance(node.body[0],ast.Expr) and 'RUN.mkdir' in ast.unparse(node.body[0]))
        campaign = ast.Module(body=[node for node in main.body[start:] if not isinstance(node,ast.Return)],type_ignores=[])
        p,_,raw = self.terminal_fixture()
        proof = M.REF.load_json(raw['closure.json'])
        run = MagicMock()
        setup = MagicMock()
        setup.sandbox_command.return_value = []
        ns = dict(M.__dict__)
        ns.update(RUN=run,setup=setup,original_admit=setup.admit,original_environment=setup.child_environment,
            source=MagicMock(),inputs={'files':[]},supervisor=types.SimpleNamespace(
                run=lambda *a,**kw:'',last_closure=proof),begin=time.monotonic(),
            status='failed',error=None,closure_sha=None,report_data=None,absent=False,
            identity=M.identity_for('b'*32,M.digest(M.canonical(p)),'a'*64),protocol=p,
            args=types.SimpleNamespace(windows_run_id='b'*32,protocol_sha=M.digest(M.canonical(p))),
            terminal_path=Path('/memory-terminal.json'),guard=lambda *a,**kw:None,environment=lambda *a:{},
            extract_inputs=MagicMock(),read_json=MagicMock(return_value={}),
            dependency_pins=lambda:[],local_counts=lambda:M.quota_counts(100,10),
            write=MagicMock(side_effect=lambda path,value,*a:M.canonical(value)),
            validate_report=MagicMock(side_effect=M.Refusal('injected invalid report')),
            REF=types.SimpleNamespace(**dict(M.REF.__dict__,read_bounded=MagicMock(return_value=b'{}\n'))))
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(campaign,str(PATH),'exec'),ns)
        terminal = ns['terminal']
        self.assertEqual(terminal['status'],'failed')
        self.assertEqual(terminal['error'],'injected invalid report')
        self.assertIsNone(terminal['report_sha256'])
        self.assertIsNone(terminal['report_base64'])
        self.assertFalse(M.validate_terminal(terminal,p,'b'*32,raw.__getitem__))

    def fixture(self):
        protocol = M.expected_protocol('a'*64)
        report = M.summary_skeleton()
        report.update(windows_run_id='b'*32,protocol_sha256=M.digest(M.canonical(protocol)),
                      cpu_summary=dict(entry_max_percent=15.,runtime_max_percent=15.))
        raw = {}
        for kind,i,path in M.evidence_plan():
            if kind == 'capture':
                row = dict(id=i,target_ns=i*1250000000,start_ns=i*1250000000,end_ns=i*1250000000+1000000,
                    environment=dict(schema=1,cpu_ticks=[i*10,i*5,i*85,0],logical_cpus=14,thermal_state=0,ac_power=True))
            elif kind == 'cli':
                pair,direction = divmod(i,2)
                archive,decoded = M.pair_paths(pair,M.schedule()[pair][3])
                row = dict(schema=1,id=i,pair=pair,direction=('encode','decode')[direction],
                    command=M.codec_commands(M.schedule()[pair][3],M.RUN/'input',archive,decoded)[direction],
                    event=dict(id=i,start_ns=4000000000+i*10000000,end_ns=4002000000+i*10000000),
                    metric=dict(elapsed_ns=1000000,user_seconds=.0003,system_seconds=.0002,peak_rss_bytes=1000,
                                normal_exit=True,exit_code=0,signal=None,cpu_per_wall=.5))
            else:
                archive,decoded = M.pair_paths(i,M.schedule()[i][3])
                row = dict(schema=1,id=i,schedule=list(M.schedule()[i]),archive=archive.name,archive_bytes=1,
                           archive_sha256='a'*64,decoded=decoded.name,restored=copy.deepcopy(ENTRIES))
            raw[path] = M.canonical(row)
        report['evidence'] = [dict(kind=k,id=i,path=p,bytes=len(raw[p]),sha256=M.digest(raw[p]))
                              for k,i,p in M.evidence_plan()]
        return protocol,report,raw

    def terminal_fixture(self, success=True):
        protocol,report,raw = self.fixture()
        code = 0 if success else 70
        calls = []
        for op,sig,start,end,ok,err,value in [('group_kill',9,1,2,True,None,None),
                ('child_wait',None,3,4,True,None,code),('group_probe',0,5,6,False,3,None)]:
            calls.append(dict(operation=op,target=100,generation=1,signal=sig,start_ns=start,end_ns=end,
                ok=ok,errno=err,value=value,error=None if ok else 'ESRCH'))
        closure = dict(schema=1,sequence=1,generation=1,pid=100,pgid=100,owned_new_session=True,
            primary=dict(kind='exit',returncode=code,error=None),signal_attempted=True,signal_sent=True,
            child_reaped=True,actual_returncode=code,wait_start_ns=3,wait_end_ns=4,wait_deadline_ns=3+M.FS.WAIT_NS,
            group_deadline_ns=4+M.FS.GROUP_NS,group_absent=True,group_absent_ns=6,raw_calls=calls,raw_calls_dropped=0,
            closure_error=None,complete=True,secondary_errors=[])
        raw['closure.json'] = M.canonical(closure)
        raw['report.json'] = M.canonical(report)
        terminal = dict(M.identity_for('b'*32,M.digest(M.canonical(protocol)),'a'*64),
            status='completed-reference' if success else 'failed',error=None if success else 'helper exit 70',
            exit=0 if success else 1,children_absent=True,closure_sha256=M.digest(raw['closure.json']),
            counts=M.quota_counts(100,10),elapsed_seconds=80.,
            report_sha256=M.digest(raw['report.json']) if success else None,
            report_base64=M.base64.b64encode(raw['report.json']).decode() if success else None)
        return protocol,terminal,raw

    def test_complete_report_revalidation(self):
        p,r,raw = self.fixture()
        result = M.validate_report(r,p,'b'*32,raw.__getitem__)
        self.assertEqual(len(result['captures']),64)
        self.assertEqual(len(result['events']),42)
        self.assertNotIn('\\',M.canonical(r).decode())

    def test_report_rejects_plan_hash_and_summary_mutation(self):
        p,r,raw = self.fixture()
        for change in ('plan','hash','summary','missing','identity','extra'):
            q = copy.deepcopy(r)
            if change == 'plan': q['evidence'][0]['path'] = '../capture-00.json'
            if change == 'hash': q['evidence'][0]['sha256'] = '0'*64
            if change == 'summary': q['cpu_summary']['entry_max_percent'] = 0
            if change == 'missing': q['evidence'].pop()
            if change == 'identity': q['windows_run_id'] = 'c'*32
            if change == 'extra': q['extra'] = True
            with self.subTest(change=change),self.assertRaises(M.Refusal):
                M.validate_report(q,p,'b'*32,raw.__getitem__)

    def test_rehashing_tampered_raw_does_not_bypass_validation(self):
        for change in ('command','metric','restored','order','capture'):
            p,r,raw = self.fixture()
            path = 'pair-00.json' if change in ('restored','order') else 'capture-04.json' if change == 'capture' else 'cli-00.json'
            row = M.REF.load_json(raw[path])
            if change == 'command': row['command'].append('--changed')
            if change == 'metric': row['metric']['peak_rss_bytes'] = 129*1024**2
            if change == 'restored': row['restored'][0]['sha256'] = 'a'*64
            if change == 'order': row['schedule'][3] = 'C'
            if change == 'capture': row['environment']['ac_power'] = False
            raw[path] = M.canonical(row)
            evidence = next(e for e in r['evidence'] if e['path'] == path)
            evidence.update(bytes=len(raw[path]),sha256=M.digest(raw[path]))
            with self.subTest(change=change),self.assertRaises(M.Refusal):
                M.validate_report(r,p,'b'*32,raw.__getitem__)

    def test_success_and_failed_terminal_closure_validation(self):
        for success in (True,False):
            p,t,raw = self.terminal_fixture(success)
            self.assertIs(M.validate_terminal(t,p,'b'*32,raw.__getitem__),success)
            t['closure_sha256'] = '0'*64
            with self.assertRaises(M.Refusal): M.validate_terminal(t,p,'b'*32,raw.__getitem__)

    def test_terminal_rejects_unknown_status_extra_type_and_false_absence(self):
        p,t,raw = self.terminal_fixture()
        for key,value in [('status','unknown'),('exit',True),('children_absent',False),('counts',None),
                          ('elapsed_seconds',121),('schema',True),('extra',1)]:
            with self.subTest(key=key),self.assertRaises(M.Refusal):
                M.validate_terminal(dict(t,**{key:value}),p,'b'*32,raw.__getitem__)

    def test_protocol_roundtrip(self):
        p = M.expected_protocol('a'*64)
        M.validate_protocol(p, 'a'*64)
        self.assertFalse(p['superiority_decision_allowed'])
        self.assertEqual(p['purpose'], 'training-reference-only')
        self.assertEqual(p['observer_captures'], 64)
        self.assertEqual(p['codec_invocations'], 42)

    def test_protocol_rejects_any_mutation(self):
        p = M.expected_protocol('a'*64)
        for key in p:
            q = copy.deepcopy(p)
            q[key] = None
            with self.subTest(key=key), self.assertRaises(M.Refusal):
                M.validate_protocol(q, 'a'*64)

    def test_protocol_rejects_extra_missing_and_old(self):
        p = M.expected_protocol('a'*64)
        for q in (dict(p, extra=1), {k:v for k,v in p.items() if k != 'purpose'},
                  M.REF.expected_protocol('a'*64, 'b'*64)):
            with self.assertRaises(M.Refusal):
                M.validate_protocol(q, 'a'*64)

    def test_invalid_endpoint_hash(self):
        for sha in ('a'*63, 'G'*64, True, None):
            with self.assertRaises(M.Refusal):
                M.expected_protocol(sha)

    def test_schedule(self):
        plan = M.schedule()
        self.assertEqual(len(plan), 21)
        self.assertEqual(''.join(p[3] for p in plan), 'ABCABCB CACABACBCBABAC'.replace(' ', ''))
        self.assertEqual(sum(p[2] for p in plan), 3)

    def test_command_settings(self):
        for letter, method in [('B', '-m0=LZMA2:d=8m:fb=273'), ('C', '-m0=PPMd:mem=64m:o=16')]:
            enc, dec = M.REF.codec_commands(letter, Path('/input'), Path('/archive'), Path('/decoded'))
            self.assertIn(method, enc)
            self.assertIn('-mmt=1', enc)
            self.assertIn('-mmt=1', dec)

    def test_metric_limits(self):
        row = dict(elapsed_ns=1000000000, user_seconds=.5, system_seconds=.1,
                   peak_rss_bytes=128*1024**2, normal_exit=True, exit_code=0, signal=None,
                   cpu_per_wall=.6)
        M.validate_metric(row, 60)
        for key, value in [('elapsed_ns', 60000000001), ('peak_rss_bytes', 128*1024**2+1),
                           ('cpu_per_wall', 1.21), ('user_seconds', float('nan')),
                           ('normal_exit', 1), ('exit_code', 70), ('elapsed_ns', True)]:
            with self.subTest(key=key), self.assertRaises(M.Refusal):
                M.validate_metric(dict(row, **{key:value}), 60)

    def test_metric_recomputes_cpu_wall(self):
        row = dict(elapsed_ns=1000000000, user_seconds=1.3, system_seconds=0,
                   peak_rss_bytes=1, normal_exit=True, exit_code=0, signal=None, cpu_per_wall=.1)
        with self.assertRaises(M.Refusal):
            M.validate_metric(row, 60)

    def test_quota_includes_journal(self):
        result = M.quota_counts(1, 1)
        self.assertEqual(result['charged_bytes'], 1+M.JOURNAL_RESERVED_BYTES)
        for size, count in [(M.MAX_BYTES, 1), (1, M.MAX_ENTRIES), (-1, 1), (True, 1)]:
            with self.assertRaises(M.Refusal):
                M.quota_counts(size, count)

    def test_json_budget_preflight(self):
        M.validate_output_budget()
        self.assertLessEqual(len(M.canonical(M.summary_skeleton())), M.REPORT_LIMIT)

    def test_observation_complete_and_missing_late(self):
        raw = dict(schema=1, cadence_ns=1250000000, max_captures=64,
                   completed=True, failure=None, captures=[], events=[])
        for i in range(64):
            raw['captures'].append(dict(id=i, target_ns=i*1250000000,
                start_ns=i*1250000000, end_ns=i*1250000000+1000000,
                environment=dict(schema=1, cpu_ticks=[i*10,i*5,i*85,0], logical_cpus=14,
                                 thermal_state=0, ac_power=True)))
        for i in range(42):
            raw['events'].append(dict(id=i, start_ns=4000000000+i*10000000,
                                     end_ns=4000000001+i*10000000))
        M.validate_observation(raw)
        for change in ('missing', 'unfinished', 'late', 'count'):
            q = copy.deepcopy(raw)
            if change == 'missing': q['captures'].pop()
            if change == 'unfinished': q['events'][-1]['end_ns'] = None
            if change == 'late': q['events'][-1]['end_ns'] = q['captures'][-1]['start_ns']
            if change == 'count': q['events'].pop()
            with self.subTest(change=change), self.assertRaises(M.Refusal):
                M.validate_observation(q)


if __name__ == '__main__':
    unittest.main()
