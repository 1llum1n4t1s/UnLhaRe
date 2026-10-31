"""失敗条件: marker衝突・保存失敗・fence失敗・live不一致・期限切れは再試行不可。"""
import importlib.util
from pathlib import Path
import unittest
from unittest import mock

spec=importlib.util.spec_from_file_location('fence_bridge',Path(__file__).with_name('fence_bridge.py'))
B=importlib.util.module_from_spec(spec);spec.loader.exec_module(B)

class BridgeTests(unittest.TestCase):
    def test_marker_precedes_fence_and_live_verification(self):
        ops=mock.Mock();ops.create.return_value=b'proof';ops.verify.return_value={'fence_live_verified':True}
        result=B.perform(ops,clock=iter([1,2,3,4]).__next__,deadline_ns=10)
        self.assertEqual(result,b'proof')
        self.assertEqual([x[0] for x in ops.method_calls],['marker','create','verify'])

    def test_marker_failure_and_fence_failure_never_retry(self):
        for name in ('marker','create','verify'):
            ops=mock.Mock();ops.create.return_value=b'proof';ops.verify.return_value={'fence_live_verified':True}
            getattr(ops,name).side_effect=OSError(name)
            with self.subTest(name=name),self.assertRaises(OSError):B.perform(ops,clock=lambda:1,deadline_ns=10)
            getattr(ops,name).assert_called_once()
            if name=='marker':ops.create.assert_not_called()

    def test_bad_live_and_deadline_fail_closed(self):
        ops=mock.Mock();ops.create.return_value=b'proof';ops.verify.return_value={'fence_live_verified':False}
        with self.assertRaises(ValueError):B.perform(ops,clock=lambda:1,deadline_ns=10)
        ops=mock.Mock()
        with self.assertRaises(ValueError):B.perform(ops,clock=lambda:10,deadline_ns=10)
        ops.marker.assert_not_called()

    def test_marker_requires_validated_pre_fence_anchors_before_open(self):
        fence=mock.Mock();native=mock.MagicMock();fence.NativeOps.return_value=mock.MagicMock()
        fence.NativeOps.return_value.__enter__.return_value=native
        native.capture.side_effect=ValueError('unsafe journal')
        with mock.patch.object(B.os,'open') as opened, self.assertRaises(ValueError):
            B.NativeFenceOps(fence).marker()
        opened.assert_not_called()

if __name__=='__main__':unittest.main()
