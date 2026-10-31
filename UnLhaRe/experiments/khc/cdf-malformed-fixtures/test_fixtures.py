import struct
import hashlib
import io
import unittest
import zlib
from unittest.mock import patch

import fixtures


def archive():
    name = b"a"
    manifest = struct.pack("<HBBQq", len(name), 0, 0, 1, 0) + name
    header = bytearray(b"KHC1ARC\0" + bytes([10, 0, 0, 0]))
    header += struct.pack("<III", 1 << 20, 1, len(manifest))
    header += struct.pack("<I", zlib.crc32(manifest))
    header += struct.pack("<I", zlib.crc32(header))
    frame = b"KHC1BLK\0" + bytes(32)
    return bytes(header) + manifest + struct.pack("<I", len(frame)) + frame + bytes(4) + b"KHC1END\0"


class FixtureTests(unittest.TestCase):
    def test_export_rejects_invalid_input_before_hash(self):
        for data in (bytearray(archive()), b"x" * (fixtures.MAX_INPUT + 1)):
            with patch.object(fixtures.hashlib, "sha256", side_effect=AssertionError("hashed invalid input")):
                with self.assertRaises(ValueError):
                    fixtures.export_verified(data, "0" * 64, {})

    def test_export_rejects_infinite_readback(self):
        class Endless(io.BytesIO):
            def read(self, size=-1):
                self.calls = getattr(self, "calls", 0) + 1
                if self.calls > 100:
                    raise AssertionError("unbounded readback")
                value = super().read(size)
                return value if value else b"x"
        base = archive()
        outputs = {name: io.BytesIO() for name in fixtures.mutations(base)}
        outputs["extent"] = Endless()
        with self.assertRaises(OSError):
            fixtures.export_verified(base, hashlib.sha256(base).hexdigest(), outputs)

    def test_export_rejects_invalid_readback_type(self):
        class WrongType(io.BytesIO):
            def read(self, size=-1):
                return "x"
        base = archive()
        outputs = {name: io.BytesIO() for name in fixtures.mutations(base)}
        outputs["extent"] = WrongType()
        with self.assertRaises(OSError):
            fixtures.export_verified(base, hashlib.sha256(base).hexdigest(), outputs)

    def test_verified_stream_export(self):
        base = archive()
        outputs = {name: io.BytesIO() for name in fixtures.mutations(base)}
        record = fixtures.export_verified(base, hashlib.sha256(base).hexdigest(), outputs)
        for name, stream in outputs.items():
            self.assertEqual(hashlib.sha256(stream.getvalue()).hexdigest(), record["fixtures"][name + ".khc"]["sha256"])

    def test_export_rejects_mismatch_and_nonempty_without_writing(self):
        base = archive()
        outputs = {name: io.BytesIO() for name in fixtures.mutations(base)}
        with self.assertRaises(ValueError):
            fixtures.export_verified(base, "0" * 64, outputs)
        self.assertTrue(all(not stream.getvalue() for stream in outputs.values()))
        outputs["extent"].write(b"x")
        with self.assertRaises(ValueError):
            fixtures.export_verified(base, hashlib.sha256(base).hexdigest(), outputs)
        self.assertTrue(all(not stream.getvalue() for name, stream in outputs.items() if name != "extent"))

    def test_export_rejects_alias_and_missing_streams(self):
        base = archive()
        digest = hashlib.sha256(base).hexdigest()
        stream = io.BytesIO()
        with self.assertRaises(ValueError):
            fixtures.export_verified(base, digest, {name: stream for name in fixtures.mutations(base)})
        with self.assertRaises(ValueError):
            fixtures.export_verified(base, digest, {})

    def test_no_filesystem_write_entry_point(self):
        self.assertFalse(hasattr(fixtures, "main"))
        self.assertFalse(hasattr(fixtures, "safe_path"))

    def test_fixed_mutations_and_checksums(self):
        base = archive()
        results = fixtures.mutations(base)
        self.assertEqual(results, fixtures.mutations(base))
        self.assertEqual(set(results), {"extent", "truncation", "crc-corruption", "unknown-revision"})
        prefix = 32 + 21
        self.assertEqual(struct.unpack_from("<I", results["extent"], prefix)[0], 0xffffffff)
        self.assertEqual(results["truncation"], base[:-1])
        self.assertEqual(results["crc-corruption"][28], base[28] ^ 1)
        unknown = results["unknown-revision"]
        self.assertEqual(unknown[8], 255)
        self.assertEqual(struct.unpack_from("<I", unknown, 28)[0], zlib.crc32(unknown[:28]))
        cases, record = fixtures.bundle(base)
        self.assertEqual(cases, results)
        self.assertEqual(record["input_sha256"], hashlib.sha256(base).hexdigest())
        for name, value in cases.items():
            self.assertEqual(record["fixtures"][name + ".khc"]["sha256"], hashlib.sha256(value).hexdigest())

    def test_reject_bad_input(self):
        base = archive()
        for bad in (base[:-1], b"", base[:24] + bytes(4) + base[28:], base + b"x"):
            with self.assertRaises(ValueError):
                fixtures.mutations(bad)

    def test_requires_frame(self):
        base = bytearray(archive())
        base[16:20] = struct.pack("<I", 0)
        base[20:24] = struct.pack("<I", 0)
        base[24:28] = struct.pack("<I", 0)
        base[28:32] = struct.pack("<I", zlib.crc32(base[:28]))
        with self.assertRaises(ValueError):
            fixtures.mutations(bytes(base[:32]) + b"KHC1END\0")


if __name__ == "__main__":
    unittest.main()
