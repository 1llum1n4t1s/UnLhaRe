#!/usr/bin/env python3
"""純粋検証。実登録・SSH・Cargo・候補binaryは実行しない。

開始前に拒否する条件: 未登録/不一致のWindows識別子、既存RUN/api、旧証拠・binary・source
改変、期限不足、8MiB/96 entries超過、安全でないpath、欠落/余分な出力。
実行後の失敗条件: timeout、正常exit以外、不完全closure、stdout/oracle不一致、
archive suffix/復元bytes不一致、postcheck失敗、保存失敗。unknownは成功にも解放にも使わない。
"""
import importlib.util
import json
import base64
import subprocess
import sys
from unittest import mock
import unittest
from pathlib import Path

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('endpoint',HERE/'mac-cdf-candidate-e2e-endpoint.py')
endpoint=importlib.util.module_from_spec(spec);spec.loader.exec_module(endpoint)

class EndpointTests(unittest.TestCase):
    def test_api_disappearance_discards_whole_scan_with_deadline(self):
        run=Path('D:/fixed-run')
        path=run/'api'/'work'/'temp'
        miss=FileNotFoundError(2,'gone',str(path))
        patcher=mock.patch.object(endpoint,'RUN',run);patcher.start();self.addCleanup(patcher.stop)
        calls=mock.Mock(side_effect=[miss,{'bytes':7,'entries':4}])
        self.assertEqual(endpoint.scan_with_retry(calls,100,clock=lambda:1),{'bytes':7,'entries':4})
        self.assertEqual(calls.call_count,2)
        calls=mock.Mock(side_effect=[miss,miss,miss])
        with self.assertRaises(FileNotFoundError):endpoint.scan_with_retry(calls,100,clock=lambda:1)
        self.assertEqual(calls.call_count,3)
        for failure in (FileNotFoundError(2,'gone',str(endpoint.RUN/'registration.json')),
                        PermissionError('denied'),ValueError('capacity')):
            calls=mock.Mock(side_effect=failure)
            with self.assertRaises(type(failure)):endpoint.scan_with_retry(calls,100,clock=lambda:1)
            self.assertEqual(calls.call_count,1)
        calls=mock.Mock(side_effect=miss)
        with self.assertRaises(ValueError):endpoint.scan_with_retry(calls,1,clock=lambda:1)
        self.assertEqual(calls.call_count,0)
        calls=mock.Mock(side_effect=miss)
        with self.assertRaises(FileNotFoundError):endpoint.scan_with_retry(calls,100,clock=lambda:1,retry=False)
        self.assertEqual(calls.call_count,1)

    def test_stdin_verifier_strict_shape_and_protocol_sha(self):
        p=endpoint.canonical(endpoint.expected_protocol(endpoint.self_sha()))
        envelope={'mode':'protocol','protocol_base64':base64.b64encode(p).decode(),
                  'protocol_sha256':endpoint.digest(p),'receipt_base64':None}
        wire=endpoint.canonical(envelope)
        self.assertTrue(endpoint.verify_wire(wire)['verified'])
        result=subprocess.run([sys.executable,'-B',str(HERE/'mac-cdf-candidate-e2e-endpoint.py'),
            '--verify-wire-stdin'],input=wire,capture_output=True,check=True)
        self.assertTrue(json.loads(result.stdout)['verified'])
        for args,data in [(['--verify-wire-stdin'],b''),(['--verify-wire-stdin'],b' '*262145),
                          (['--verify-wire-stdin','--protocol-sha','0'*64],wire)]:
            result=subprocess.run([sys.executable,'-B',str(HERE/'mac-cdf-candidate-e2e-endpoint.py')]+args,
                                  input=data,capture_output=True)
            self.assertNotEqual(result.returncode,0)
        malformed=[b'',b' '*262145,b'{"mode":"protocol","mode":"protocol"}',
            endpoint.canonical(dict(envelope,extra=1)),endpoint.canonical(dict(envelope,protocol_sha256='0'*64)),
            endpoint.canonical(dict(envelope,receipt_base64='YQ==')),endpoint.canonical(dict(envelope,mode='unknown')),
            endpoint.canonical(dict(envelope,mode='receipt',receipt_base64=None))]
        for data in malformed:
            with self.subTest(data=data[:30]),self.assertRaises((ValueError,KeyError)):
                endpoint.verify_wire(data)
    def test_fixed_protocol_and_exact_timeout(self):
        protocol=endpoint.expected_protocol('a'*64)
        endpoint.validate_protocol(protocol,'a'*64)
        for key,value in [('native_timeout_seconds',301),('child_timeout_seconds',241),
                          ('example_sha256','b'*64),('run_directory','/tmp/other')]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                endpoint.validate_protocol(dict(protocol,**{key:value}),'a'*64)
        wire_protocol=endpoint.expected_protocol(endpoint.self_sha())
        wire_data=endpoint.canonical(wire_protocol)
        result=subprocess.run([sys.executable,'-B',str(HERE/'mac-cdf-candidate-e2e-endpoint.py'),
            '--verify-protocol-base64',base64.b64encode(wire_data).decode(),
            '--protocol-sha',endpoint.digest(wire_data)],capture_output=True,check=True)
        self.assertEqual(json.loads(result.stdout)['protocol_sha256'],endpoint.digest(wire_data))

    def test_budget_includes_reserves_and_entries(self):
        endpoint.validate_budget(8388608-65536,95,65536,1)
        for args in [(8388608-65535,95,65536,1),(1,96,0,1),(-1,1,0,0)]:
            with self.assertRaises(ValueError):endpoint.validate_budget(*args)

    def test_time_reserves_never_shortened(self):
        self.assertEqual(endpoint.child_start_deadline(100),127)
        endpoint.validate_child_start(127,100)
        with self.assertRaises(ValueError):endpoint.validate_child_start(127.01,100)

    def test_paths_reject_escape(self):
        self.assertEqual(str(endpoint.relative_path('api/legacy-1.khc')),'api/legacy-1.khc')
        for path in ('../x','/tmp/x','api//x','api/../x','api\\x','.'):
            with self.subTest(path=path),self.assertRaises(ValueError):endpoint.relative_path(path)

    def test_exact_api_inventory_and_conditional_partial(self):
        path=Path('D:/Codex/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-native-e2e-oracle.json')
        oracle=json.loads(path.read_bytes());required,optional,rows=endpoint.expected_api_files(oracle)
        records=[dict(path=p,bytes=1,sha256='a'*64) for p in sorted(required)]
        for row in records:
            if row['path'].endswith('/sentinel'):row.update(bytes=4,sha256=endpoint.digest(b'keep'))
        report=dict(schema=1,scope='candidate-example-correctness-only',api=oracle['api'],files=records,
            directories=['api','api/source','api/api-output','api/accepted-all-output','api/legacy-compat-output',
                         'api/rejected-frames','api/rejected-trailing','api/rejected-truncated'],
            archive_suffixes=rows,registration_sha256='a'*64,windows_run_id='b'*32,
            windows_registration_sha256='c'*64,protocol_sha256='d'*64)
        self.assertTrue(endpoint.validate_api_report(report,oracle))
        extra=dict(report,files=records+[dict(path='api/unexpected',bytes=1,sha256='a'*64)])
        with self.assertRaises(ValueError):endpoint.validate_api_report(extra,oracle)
        allowed=dict(report,files=records+[dict(path=sorted(optional)[0],bytes=1,sha256='a'*64)])
        self.assertTrue(endpoint.validate_api_report(allowed,oracle))
        allowed['files'][-1]['sha256']='b'*64
        with self.assertRaises(ValueError):endpoint.validate_api_report(allowed,oracle)
        fixture_spec=importlib.util.spec_from_file_location('old_fixture',HERE/'test-mac-decode-phase-build.py')
        fixture=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(fixture)
        _,old_receipt=fixture.fixture();proof=old_receipt['closure_proof']
        protocol=endpoint.expected_protocol('f'*64)
        report.update(protocol_sha256=endpoint.digest(endpoint.canonical(protocol)))
        report_data=endpoint.canonical(report)
        receipt={key:protocol[key] for key in ('schema','protocol','purpose','endpoint_sha256','source_sha256',
            'example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256')}
        receipt.update(windows_run_id=report['windows_run_id'],windows_registration_sha256=report['windows_registration_sha256'],
            protocol_sha256=report['protocol_sha256'],remote_registration_sha256=report['registration_sha256'],
            report_sha256=endpoint.digest(report_data),report_base64=base64.b64encode(report_data).decode(),
            closure_proof=proof,closure_sha256=endpoint.digest(endpoint.canonical(proof)),children_absent=True,
            postchecks_ok=True,runtime_seconds=42.,status='done',exit=0,error=None)
        self.assertEqual(endpoint.validate_receipt(receipt,protocol,oracle)['status'],'done')
        for key,value in [('runtime_seconds',301.),('postchecks_ok',False),('exit',1),('report_sha256','0'*64)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                endpoint.validate_receipt(dict(receipt,**{key:value}),protocol,oracle)

    def test_failed_receipt_requires_real_closure_and_identity(self):
        fixture_spec=importlib.util.spec_from_file_location('old_fixture',HERE/'test-mac-decode-phase-build.py')
        fixture=importlib.util.module_from_spec(fixture_spec);fixture_spec.loader.exec_module(fixture)
        _,old_receipt=fixture.fixture();proof=old_receipt['closure_proof']
        protocol=endpoint.expected_protocol(endpoint.self_sha())
        receipt={key:protocol[key] for key in ('schema','protocol','purpose','endpoint_sha256','source_sha256',
            'example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256')}
        receipt.update(windows_run_id='a'*32,windows_registration_sha256='b'*64,
            protocol_sha256=endpoint.digest(endpoint.canonical(protocol)),remote_registration_sha256=None,
            report_sha256=None,report_base64=None,closure_proof=proof,
            closure_sha256=endpoint.digest(endpoint.canonical(proof)),children_absent=True,postchecks_ok=False,
            runtime_seconds=42.,status='failed',exit=1,error='primary failure')
        result=endpoint.validate_receipt(receipt,protocol,{})
        self.assertTrue(result['cleanup_allowed']);self.assertEqual(result['status'],'failed')
        for key,value in [('children_absent',False),('windows_registration_sha256','invalid'),('example_sha256','0'*64)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                endpoint.validate_receipt(dict(receipt,**{key:value}),protocol,{})
        unknown=dict(receipt,closure_proof=None,closure_sha256=None,children_absent=False)
        self.assertFalse(endpoint.validate_receipt(unknown,protocol,{})['cleanup_allowed'])
        protocol_data=endpoint.canonical(protocol)
        envelope=dict(mode='receipt',protocol_base64=base64.b64encode(protocol_data).decode(),
            protocol_sha256=endpoint.digest(protocol_data),
            receipt_base64=base64.b64encode(endpoint.canonical(receipt)).decode())
        with mock.patch.object(endpoint,'load_oracle',return_value={}):
            self.assertEqual(endpoint.verify_wire(endpoint.canonical(envelope))['status'],'failed')

if __name__=='__main__':unittest.main()
