#!/usr/bin/env python3
"""Pure checks for immutable retry authorization; never runs Cargo or SSH."""
import importlib.util
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location('retry', Path(__file__).with_name('mac-decode-phase-retry.py'))
retry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retry)


class AmendmentTests(unittest.TestCase):
    def test_cargo_guard_deadline_preserves_closure_budget(self):
        self.assertEqual(retry.cargo_guard_deadline(1_000_000_000, 300.0, 400_000_000_000),
                         288_000_000_000)
        self.assertEqual(retry.cargo_guard_deadline(1_000_000_000, 20.0, 6_000_000_000),
                         6_000_000_000)
        with self.assertRaises(ValueError):
            retry.cargo_guard_deadline(1_000_000_000, 13.0, 400_000_000_000)

    def test_source_check_cannot_consume_closure_budget(self):
        calls = []
        clock = iter((100, 200))
        with self.assertRaises(ValueError):
            retry.guarded_admission(200, lambda: calls.append('source'),
                                    lambda deadline: calls.append(('snapshot', deadline)),
                                    clock=lambda: next(clock))
        self.assertEqual(calls, ['source'])
        calls.clear()
        clock = iter((100, 150, 200))
        with self.assertRaises(ValueError):
            retry.guarded_admission(200, lambda: calls.append('source'),
                                    lambda deadline: calls.append(('snapshot', deadline)),
                                    clock=lambda: next(clock))
        self.assertEqual(calls, ['source', ('snapshot', 200)])

    def test_terminal_preparation_deadline_downgrades_before_validation(self):
        proof = {'complete': True}
        result = dict(status='done', exit=0, error=None, closure_proof=proof,
                      closure_sha256='a' * 64, runtime_seconds=350.01)
        converted = retry.enforce_preparation_deadline(result, 100.0, clock=lambda: 450.02)
        self.assertEqual((converted['status'], converted['exit']), ('failed', 1))
        self.assertAlmostEqual(converted['runtime_seconds'], 350.02)
        self.assertIs(converted['closure_proof'], proof)
        self.assertEqual(converted['closure_sha256'], 'a' * 64)
        self.assertIn('deadline', converted['error'])
        failed = dict(result, status='failed', exit=1, error='primary failure')
        self.assertEqual(retry.enforce_preparation_deadline(failed, 100.0, clock=lambda: 450.02)['error'],
                         'primary failure')

    def test_exact_amendment_and_changed_fields(self):
        value = retry.expected_amendment('a' * 64, 'b' * 64)
        data = retry.canonical(value)
        self.assertEqual(retry.validate_amendment(data, retry.digest(data), 'a' * 64, 'b' * 64), value)
        for key, replacement in [('target', '/tmp/new'), ('additional_attempts', 2),
                                 ('cargo_timeout_seconds', 301), ('snapshot_sha256', 'c' * 64)]:
            altered = dict(value, **{key: replacement})
            encoded = retry.canonical(altered)
            with self.subTest(key=key), self.assertRaises(ValueError):
                retry.validate_amendment(encoded, retry.digest(encoded), 'a' * 64, 'b' * 64)

    def test_bad_hash_duplicate_and_noncanonical(self):
        data = retry.canonical(retry.expected_amendment('a' * 64, 'b' * 64))
        with self.assertRaises(ValueError):
            retry.validate_amendment(data, '0' * 64, 'a' * 64, 'b' * 64)
        for malformed in (b'{"x":1,"x":1}\n', b'{ "x":1}\n', b'{"x":NaN}\n'):
            with self.assertRaises(ValueError):
                retry.parse(malformed)

    def test_first_attempt_must_be_closed_failed_and_bound(self):
        protocol = dict(controller_sha256=retry.OLD_CONTROLLER_SHA, source_sha256=retry.SOURCE_SHA,
                        root=retry.ROOT, source_directory=retry.SOURCE, target=retry.TARGET)
        closure = {'closed': True}
        closure_data = retry.canonical(closure)
        receipt = dict(status='failed', exit=1, binary_sha256=None, wait_confirmed=True,
                       group_absent=True, postchecks_ok=True,
                       closure_sha256=retry.digest(closure_data), closure_proof=closure)
        protocol_data, receipt_data = map(retry.canonical, (protocol, receipt))
        old = mock.Mock()
        old.verify_receipt_bytes.return_value = {'cleanup_allowed': True}
        with mock.patch.multiple(retry, OLD_PROTOCOL_SHA=retry.digest(protocol_data),
                                 OLD_RECEIPT_SHA=retry.digest(receipt_data),
                                 OLD_CLOSURE_SHA=retry.digest(closure_data)):
            retry.validate_old_evidence(protocol_data, receipt_data, closure_data, old)
            old.verify_receipt_bytes.return_value = {'cleanup_allowed': False}
            with self.assertRaises(ValueError):
                retry.validate_old_evidence(protocol_data, receipt_data, closure_data, old)
            with self.assertRaises(ValueError):
                retry.validate_old_evidence(protocol_data, receipt_data, closure_data + b' ', old)
        old.verify_receipt_bytes.return_value = {'cleanup_allowed': True}
        for key, replacement in [('status', 'done'), ('binary_sha256', 'a' * 64),
                                 ('postchecks_ok', False), ('group_absent', False)]:
            changed = retry.canonical(dict(receipt, **{key: replacement}))
            with self.subTest(key=key), mock.patch.multiple(retry,
                    OLD_PROTOCOL_SHA=retry.digest(protocol_data), OLD_RECEIPT_SHA=retry.digest(changed),
                    OLD_CLOSURE_SHA=retry.digest(closure_data)), self.assertRaises(ValueError):
                retry.validate_old_evidence(protocol_data, changed, closure_data, old)

    def test_storage_failure_propagates_and_deadline_is_forwarded(self):
        snapshot = mock.Mock()
        snapshot.snapshot.side_effect = TimeoutError('deadline')
        with self.assertRaises(TimeoutError):
            retry.native_admission(snapshot, Path('/fixed'), 123, 456)
        snapshot.snapshot.assert_called_once_with(Path('/fixed'), deadline_ns=123)
        snapshot.validate_admission.assert_not_called()

    def test_retry_receipt_binding_precedes_frozen_validator(self):
        amendment = retry.expected_amendment('a' * 64, 'b' * 64)
        value = dict(protocol=retry.PROTOCOL, controller_sha256='a' * 64,
            amendment_sha256='c' * 64, protocol_sha256='c' * 64, snapshot_sha256='b' * 64,
            old_receipt_sha256=retry.OLD_RECEIPT_SHA)
        old = mock.Mock()
        old.validate_receipt.return_value = dict(status='failed', exit=1, binary_sha256=None,
            closure_sha256=None, cleanup_allowed=False)
        original = {'protocol': 'old'}
        result = retry.validate_retry_receipt(retry.canonical(value), amendment, 'c' * 64, old, original)
        self.assertFalse(result['cleanup_allowed'])
        for key in ('protocol', 'controller_sha256', 'amendment_sha256', 'protocol_sha256',
                    'snapshot_sha256', 'old_receipt_sha256'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                retry.validate_retry_receipt(retry.canonical(dict(value, **{key: 'wrong'})),
                                             amendment, 'c' * 64, old, original)

    def test_real_old_validator_rejects_abnormal_cargo_and_extra_fields(self):
        path = Path(__file__).with_name('test-mac-decode-phase-build.py')
        old_spec = importlib.util.spec_from_file_location('old_fixture', path)
        fixture = importlib.util.module_from_spec(old_spec)
        old_spec.loader.exec_module(fixture)
        protocol, value = fixture.fixture()
        amendment = retry.expected_amendment('a' * 64, 'b' * 64)
        value.update(protocol=retry.PROTOCOL, controller_sha256='a' * 64, protocol_sha256='c' * 64,
                     amendment_sha256='c' * 64, snapshot_sha256='b' * 64,
                     old_receipt_sha256=retry.OLD_RECEIPT_SHA)
        with mock.patch.object(retry, 'OLD_PROTOCOL_SHA', fixture.M.digest(fixture.M.canonical(protocol))):
            self.assertEqual(retry.validate_retry_receipt(retry.canonical(value), amendment, 'c' * 64,
                                                          fixture.M, protocol)['status'], 'done')
            late = retry.enforce_preparation_deadline(value, 100.0, clock=lambda: 450.01)
            verified = retry.validate_retry_receipt(retry.canonical(late), amendment, 'c' * 64,
                                                    fixture.M, protocol)
            self.assertEqual((verified['status'], verified['cleanup_allowed']), ('failed', True))
            for changed in (dict(value, exit=1), dict(value, postchecks_ok=False), dict(value, extra=1)):
                with self.assertRaises(ValueError):
                    retry.validate_retry_receipt(retry.canonical(changed), amendment, 'c' * 64,
                                                 fixture.M, protocol)


if __name__ == '__main__':
    unittest.main()
