"""Fixed helper wire tests: no real candidate/SSH/Cargo/ledger operations.

Wrong command, binary, cwd, timeout, index, duplicate/noncanonical wire,
symlink/hash mismatch, partial request and unbound native execution must fail.
"""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('wait4_helper',HERE/'wait4_helper.py')
helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)

class HelperTests(unittest.TestCase):
    def test_receiver_rejects_changed_dependency_before_compilation(self):
        request=helper.expected_request(0,'encode',123)
        changed=dict(request['dependency_sha256'],**{'evaluation.py':'0'*64})
        with mock.patch.object(helper,'dependency_hashes',return_value=changed),\
             mock.patch.object(helper,'expected_trial',side_effect=AssertionError('compile reached')) as trial:
            with self.assertRaises(ValueError):helper.validate_request(request)
        trial.assert_not_called()
        for bad in ({},dict(request['dependency_sha256'],extra='a'*64),
                    dict(request['dependency_sha256'],**{'evaluation.py':'Z'*64})):
            with self.subTest(pins=bad),mock.patch.object(helper,'expected_request') as expected:
                with self.assertRaises(ValueError):helper.validate_request(dict(request,dependency_sha256=bad))
                expected.assert_not_called()
    def test_evaluation_executes_verified_bytes_without_reopen_or_pyc(self):
        original=helper.read_dependency
        captured=[]
        def read(path):
            captured.append(path.name)
            return original(path)
        with mock.patch.object(helper,'read_dependency',side_effect=read),\
             mock.patch.object(helper.importlib.util,'spec_from_file_location',side_effect=AssertionError('reopen')):
            value=helper.evaluation()
        self.assertEqual(value.MANIFEST_RAW_SHA,'458a2048459bbcae07a771c072d5e387af910c9916545919e42cbb3bcfbb87af')
        self.assertEqual(captured,['evaluation.py'])
        with mock.patch.object(helper,'read_dependency',return_value=b'raise AssertionError("must not execute")'),\
             self.assertRaises(ValueError):helper.evaluation('0'*64)

    def test_bridge_command_uses_fixed_request_and_rejects_wrong_argv(self):
        spec=importlib.util.spec_from_file_location('candidate_adapter',HERE/'process_adapter.py')
        adapter=importlib.util.module_from_spec(spec);spec.loader.exec_module(adapter)
        provider=adapter.FixedHelperCommand(helper,helper.dependency_hashes(),'/usr/bin/python3')
        command,cwd,timeout=helper.expected_trial(0,'encode')
        with mock.patch.object(adapter.os,'getpid',return_value=123):
            args=provider.command(command=command,cwd=cwd,timeout=timeout)
        self.assertEqual(args[0],'/usr/bin/python3');self.assertEqual(args[-2],'--run-request-base64')
        request=helper.parse_request(base64.b64decode(args[-1],validate=True))
        self.assertEqual(request['parent_pid'],123);self.assertEqual(request['command'],command)
        with self.assertRaises(adapter.InvalidObservation):provider.command(command=['/bin/false'],cwd=cwd,timeout=timeout)
        bad=adapter.FixedHelperCommand(helper,dict(helper.dependency_hashes(),**{'wait4_helper.py':'0'*64}),'/usr/bin/python3')
        self.assertFalse(bad.verify_identity())
        real_request=helper.expected_request(0,'encode',123)
        changed=dict(real_request,dependency_sha256=dict(real_request['dependency_sha256'],**{'evaluation.py':'0'*64}))
        with mock.patch.object(adapter.os,'getpid',return_value=123),\
             mock.patch.object(helper,'expected_request',return_value=changed),self.assertRaises(adapter.InvalidObservation):
            provider.command(command=command,cwd=cwd,timeout=timeout)
    def test_fixed_request_accepts_only_planned_command(self):
        command,cwd,timeout=helper.expected_trial(0,'encode')
        value=helper.expected_request(0,'encode',123)
        self.assertEqual(value['command'],command);self.assertEqual(value['cwd'],cwd);self.assertEqual(value['timeout'],timeout)
        helper.validate_request(value)
        for key,changed in [('command',['/bin/echo']),('cwd','/tmp'),('timeout',61),('index',22),('parent_pid',1)]:
            with self.subTest(key=key),self.assertRaises(ValueError):helper.validate_request(dict(value,**{key:changed}))

    def test_cli_wire_synthetic_process_and_closed_execution(self):
        request=helper.canonical(helper.expected_request(0,'decode',123))
        payload=base64.b64encode(request).decode()
        process=subprocess.run([sys.executable,'-B',str(HERE/'wait4_helper.py'),
            '--verify-request-base64',payload],capture_output=True,check=True)
        self.assertTrue(json.loads(process.stdout)['verified'])
        denied=subprocess.run([sys.executable,'-B',str(HERE/'wait4_helper.py'),
            '--run-request-base64',payload],capture_output=True)
        self.assertNotEqual(denied.returncode,0)
        self.assertIn(b'lifecycle',denied.stderr.lower())
        for invalid in (b'',b'{"x":1,"x":1}\n',request+b' '):
            with self.subTest(invalid=invalid[:20]),self.assertRaises(ValueError):helper.parse_request(invalid)

if __name__=='__main__':unittest.main()
