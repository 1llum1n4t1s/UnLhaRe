#!/usr/bin/env python3
"""Candidate failures defined before implementation; no Cargo, SSH or ledger writes.

Reject changed pins/command/path/limits, noncanonical or duplicate JSON, altered ZIP
or any difference beyond packet.rs, unsafe source, preexisting start/source/target,
unclosed/abnormal Cargo, failed postchecks, timeout, failed persistence, changed old
evidence and unavailable/over-budget snapshot. Preserve failure and raw closure.
"""
import importlib.util
import copy
import base64
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).absolute().parent
spec = importlib.util.spec_from_file_location('candidate', HERE/'mac-cdf-candidate-build.py')
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)


class CandidateTests(unittest.TestCase):
    def test_start_writer_produces_canonical_helper_input(self):
        writer=candidate.old_controller()
        value={'schema':1,'endpoint_pid':123,'controller_sha256':'a'*64,'protocol_sha256':'b'*64}
        mocked_open=mock.mock_open()
        with mock.patch.object(Path,'open',mocked_open),mock.patch('os.fsync'):
            candidate.save_started(writer,Path('/journal/start'),value)
        mocked_open.assert_called_once_with('xb')
        self.assertEqual(candidate.parse(mocked_open().write.call_args.args[0]),value)

    def test_protocol_is_exact_and_cargo_selection_fixed(self):
        protocol = candidate.expected_protocol('a'*64, candidate.SNAPSHOT_SHA)
        command = protocol['cargo_command']
        self.assertIn('--lib', command)
        self.assertEqual(command[command.index('--bin')+1], 'unlhare-cli')
        self.assertEqual(command[command.index('--example')+1], 'khc_spatial_mdl_e2e')
        candidate.validate_protocol(protocol, 'a'*64, candidate.SNAPSHOT_SHA)
        for key, value in [('target', '/tmp/other'), ('cargo_timeout_seconds', 301),
                           ('snapshot_sha256', 'c'*64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                candidate.validate_protocol(dict(protocol, **{key: value}), 'a'*64, candidate.SNAPSHOT_SHA)

    def test_candidate_real_archive_matches_base_except_packet(self):
        root = Path('D:/Claude/TaskArtifacts/UnLhaRe/goal-restore-20261019')
        base=(root/'mac-native-source.zip').read_bytes()
        derived=(root/'mac-cdf-chooser-ablation-source-36d904e0.zip').read_bytes()
        candidate.validate_source_snapshot(base,derived)
        with self.assertRaises(ValueError):candidate.validate_source_snapshot(base,derived+b' ')

    def test_deadline_preparation_preserves_closure(self):
        proof = {'complete': True}
        result = dict(status='done', exit=0, error=None, runtime_seconds=349., closure_proof=proof)
        result = candidate.enforce_preparation_deadline(result, 100., clock=lambda: 450.1)
        self.assertEqual((result['status'], result['exit']), ('failed', 1))
        self.assertIs(result['closure_proof'], proof)

    def test_receipt_requires_closed_normal_exit_and_postchecks(self):
        oldspec=importlib.util.spec_from_file_location('old_fixture',HERE/'test-mac-decode-phase-build.py')
        fixture=importlib.util.module_from_spec(oldspec);oldspec.loader.exec_module(fixture)
        _,receipt=fixture.fixture()
        protocol=candidate.expected_protocol('a'*64,candidate.SNAPSHOT_SHA)
        for key in ('schema','protocol','purpose','source_sha256','controller_sha256','root','target','cargo_command'):
            receipt[key]=protocol[key]
        receipt.update(protocol_sha256=candidate.digest(candidate.canonical(protocol)),binary_path=candidate.BINARY.as_posix())
        self.assertEqual(candidate.validate_receipt(receipt,protocol)['status'],'done')
        for key,value in [('exit',1),('postchecks_ok',False),('group_absent',False),('binary_sha256',None)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                candidate.validate_receipt(dict(receipt,**{key:value}),protocol)
        broken=copy.deepcopy(receipt);broken['closure_proof']['actual_returncode']=1
        broken['closure_sha256']=candidate.digest(candidate.canonical(broken['closure_proof']))
        with self.assertRaises(ValueError):candidate.validate_receipt(broken,protocol)
        late=candidate.enforce_preparation_deadline(receipt,100.,clock=lambda:450.1)
        self.assertEqual(candidate.validate_receipt(late,protocol)['status'],'failed')
        self.assertTrue(candidate.validate_receipt(late,protocol)['cleanup_allowed'])

    def test_protocol_json_canonical_and_byte_binding(self):
        protocol=candidate.expected_protocol(candidate.self_sha(),candidate.SNAPSHOT_SHA)
        data=candidate.canonical(protocol)
        self.assertTrue(candidate.verify_protocol_bytes(data,candidate.digest(data))['verified'])
        for broken in (data+b' ',b'{"a":1,"a":1}\n'):
            with self.assertRaises(ValueError):candidate.verify_protocol_bytes(broken,candidate.digest(broken))

    def test_gateway_protocol_wire_and_allowlisted_environment(self):
        protocol=candidate.expected_protocol(candidate.self_sha(),candidate.SNAPSHOT_SHA)
        data=candidate.canonical(protocol)
        run=subprocess.run([sys.executable,'-B',str(HERE/'mac-cdf-candidate-build.py'),
            '--verify-protocol-base64',base64.b64encode(data).decode(),
            '--protocol-sha',candidate.digest(data)],capture_output=True,check=True)
        self.assertTrue(json.loads(run.stdout)['verified'])
        old=candidate.old_controller()
        setup=old.load(HERE/'mac-native-setup.py','candidate_test_setup',old.SETUP_SHA)
        base=setup.child_environment(candidate.ROOT,{'HOME':'/home/user','RUSTFLAGS':'-C target-cpu=native',
            'CARGO_ENCODED_RUSTFLAGS':'unwanted'})
        profile={'environment':{'SDKROOT':'sdk','DYLD_LIBRARY_PATH':'dyld','PATH':'path',
                                'CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER':'linker'}}
        env=candidate.candidate_environment(profile,base)
        self.assertNotIn('RUSTFLAGS',env);self.assertNotIn('CARGO_ENCODED_RUSTFLAGS',env)
        self.assertEqual(env['RUSTUP_AUTO_INSTALL'],'0')
        self.assertEqual(env['CARGO_TARGET_DIR'],candidate.TARGET.as_posix())
        for key in ('TMP','TEMP','TMPDIR'):
            self.assertEqual(env[key],(candidate.TARGET/'tmp').as_posix())
        self.assertEqual(base['CARGO_TARGET_DIR'],str(candidate.ROOT/'cargo-target'))
        self.assertEqual(base['TMP'],str(candidate.ROOT/'tmp'))

    def test_target_creation_requires_new_target_and_private_tmp(self):
        with mock.patch.object(Path,'mkdir',autospec=True) as mkdir:
            candidate.create_candidate_target()
        self.assertEqual(mkdir.call_args_list,[mock.call(candidate.TARGET,mode=0o700),
                                              mock.call(candidate.TARGET/'tmp',mode=0o700)])
        with mock.patch.object(Path,'mkdir',side_effect=FileExistsError('already exists')) as mkdir:
            with self.assertRaises(FileExistsError):candidate.create_candidate_target()
            self.assertEqual(mkdir.call_count,1)
        with mock.patch.object(Path,'mkdir',side_effect=[None,FileExistsError('tmp exists')]) as mkdir:
            with self.assertRaises(FileExistsError):candidate.create_candidate_target()
            self.assertEqual(mkdir.call_count,2)
        setup=mock.Mock();candidate.validate_candidate_target(setup)
        self.assertEqual(setup.checked_path.call_args_list,
            [mock.call(candidate.TARGET,private=True),mock.call(candidate.TARGET/'tmp',private=True)])

    def test_snapshot_failure_propagates_before_capacity_acceptance(self):
        snapshot=mock.Mock();snapshot.snapshot.side_effect=TimeoutError('snapshot deadline')
        with self.assertRaises(TimeoutError):candidate.admission(snapshot,123,456)
        snapshot.snapshot.assert_called_once_with(candidate.ROOT,deadline_ns=123)
        snapshot.validate_admission.assert_not_called()


if __name__ == '__main__':
    unittest.main()
