"""Generate reproducible envelope-level mutations of an existing KHC archive."""
import hashlib
import hmac
import struct
import zlib

MAX_INPUT = 16 * 1024 * 1024
MAX_OUTPUT = 4 * MAX_INPUT + 65536
BLOCK = 1 << 20


def u32(data, offset):
    return struct.unpack_from("<I", data, offset)[0]


def parse(data):
    if not 32 <= len(data) <= MAX_INPUT or data[:8] != b"KHC1ARC\0":
        raise ValueError("invalid archive size or magic")
    if data[8] not in range(1, 11) or data[9:12] != bytes(3) or u32(data, 12) != BLOCK:
        raise ValueError("invalid archive header")
    if zlib.crc32(data[:28]) != u32(data, 28):
        raise ValueError("invalid header CRC")
    count, size = u32(data, 16), u32(data, 20)
    end = 32 + size
    if end > len(data) or count > size // 21 or zlib.crc32(data[32:end]) != u32(data, 24):
        raise ValueError("invalid manifest extent or CRC")
    at, entries = 32, []
    for _ in range(count):
        if at + 20 > end:
            raise ValueError("truncated manifest record")
        length, kind, flags, plain = struct.unpack_from("<HBBQ", data, at)
        name_end = at + 20 + length
        if not length or name_end > end or kind > 1 or flags or (kind and plain):
            raise ValueError("invalid manifest record")
        try:
            data[at + 20:name_end].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ValueError("invalid manifest name") from exc
        entries.append((kind, plain))
        at = name_end
    if at != end:
        raise ValueError("manifest trailing bytes")
    at, first = end, None
    for kind, plain in entries:
        if kind:
            continue
        while plain:
            if at + 4 > len(data):
                raise ValueError("missing frame length")
            length = u32(data, at)
            if length < 8 or length > BLOCK + 1024 or at + 4 + length > len(data):
                raise ValueError("invalid frame extent")
            if first is None:
                first = at
            at += 4 + length
            plain -= min(plain, BLOCK)
        if at + 4 > len(data):
            raise ValueError("missing file CRC")
        at += 4
    if first is None or data[at:] != b"KHC1END\0":
        raise ValueError("missing frame or invalid archive end")
    return first


def mutations(data):
    prefix = parse(data)
    extent = bytearray(data)
    struct.pack_into("<I", extent, prefix, 0xffffffff)
    crc_corruption = bytearray(data)
    crc_corruption[28] ^= 1
    unknown = bytearray(data)
    unknown[8] = 255
    struct.pack_into("<I", unknown, 28, zlib.crc32(unknown[:28]))
    return {"extent": bytes(extent), "truncation": data[:-1],
            "crc-corruption": bytes(crc_corruption), "unknown-revision": bytes(unknown)}


def bundle(data):
    """Return fixture bytes and their SHA-256 record without filesystem access."""
    cases = mutations(data)
    if sum(map(len, cases.values())) + 65536 > MAX_OUTPUT:
        raise ValueError("output limit exceeded")
    record = {"input_sha256": hashlib.sha256(data).hexdigest(), "input_bytes": len(data),
              "cdf_mutation": "unsupported: packet grammar preservation and wire CRC resealing not proven",
              "fixtures": {name + ".khc": {"sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}
                           for name, value in cases.items()}}
    return cases, record


def export_verified(data, expected_sha256, outputs):
    """Write to caller-owned, distinct empty binary streams; return the hash record.

    The caller must securely create and retain the streams and ensure that they
    refer to distinct files. A failure can leave partially written streams.
    """
    if type(data) is not bytes or len(data) > MAX_INPUT:
        raise ValueError("input must be bytes within the size limit")
    if not isinstance(expected_sha256, str) or len(expected_sha256) != 64 or not hmac.compare_digest(
        hashlib.sha256(data).hexdigest(), expected_sha256
    ):
        raise ValueError("input SHA-256 mismatch")
    cases, record = bundle(data)
    if set(outputs) != set(cases) or len({id(stream) for stream in outputs.values()}) != len(cases):
        raise ValueError("four distinct output streams are required")
    for stream in outputs.values():
        if not stream.seekable() or not stream.readable() or not stream.writable():
            raise ValueError("streams must be seekable, readable and writable")
        if stream.seek(0, 2) != 0:
            raise ValueError("output stream is not empty")
        stream.seek(0)
    for name, data_out in cases.items():
        stream = outputs[name]
        view = memoryview(data_out)
        while view:
            written = stream.write(view)
            if not isinstance(written, int) or written <= 0 or written > len(view):
                raise OSError("incomplete fixture write")
            view = view[written:]
        stream.flush()
        stream.seek(0)
        digest = hashlib.sha256()
        remaining = len(data_out)
        while remaining:
            requested = min(remaining, 65536)
            chunk = stream.read(requested)
            if type(chunk) is not bytes or not 0 < len(chunk) <= requested:
                raise OSError("invalid fixture readback length or type")
            digest.update(chunk)
            remaining -= len(chunk)
        extra = stream.read(1)
        if type(extra) is not bytes or extra != b"":
            raise OSError("fixture readback has trailing data or invalid type")
        if not hmac.compare_digest(digest.hexdigest(), record["fixtures"][name + ".khc"]["sha256"]):
            raise OSError("fixture readback SHA-256 mismatch")
    return record
