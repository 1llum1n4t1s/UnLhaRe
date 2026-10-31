"""固定snapshotのCdf::chooseだけを置換する、未測定の局所仮説。"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

BASE_SHA = '030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f'
PACKET_SHA = '2ef1cc41154b25f491d268e1fc365829d6efe9eec71a78f69c4ac112a3502c79'
CHANGED_FILE = 'src/khc/block/packet.rs'
MAX_SOURCE = 8 * 1024 * 1024
MANIFEST = 'snapshot-manifest.json'
OLD_CHOOSE = b'''    pub(crate) fn choose(&self, slot: u32) -> Result<(usize, u32, u32)> {
        let mut cumulative = 0;
        for (child, &end) in self.ends.iter().enumerate().take(self.k) {
            let end = u32::from(end);
            if slot < end {
                return Ok((child, cumulative, end - cumulative));
            }
            cumulative = end;
        }
        Err("range CDF child".into())
    }'''
NEW_CHOOSE = b'''    pub(crate) fn choose(&self, slot: u32) -> Result<(usize, u32, u32)> {
        if self.k > 0 {
            let end = u32::from(self.ends[0]);
            if slot < end {
                return Ok((0, 0, end));
            }
        }
        if self.k > 1 {
            let end = u32::from(self.ends[1]);
            if slot < end {
                let cumulative = u32::from(self.ends[0]);
                return Ok((1, cumulative, end - cumulative));
            }
        }
        if self.k > 2 {
            let end = u32::from(self.ends[2]);
            if slot < end {
                let cumulative = u32::from(self.ends[1]);
                return Ok((2, cumulative, end - cumulative));
            }
        }
        if self.k > 3 {
            let end = u32::from(self.ends[3]);
            if slot < end {
                let cumulative = u32::from(self.ends[2]);
                return Ok((3, cumulative, end - cumulative));
            }
        }
        Err("range CDF child".into())
    }'''


class Refusal(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True) + '\n').encode()


def require(condition, message):
    if not condition:
        raise Refusal(message)


def replace_once(data, old, new):
    require(bool(old) and data.count(old) == 1, 'rewrite marker count')
    return data.replace(old, new, 1)


def valid_name(name):
    require(isinstance(name, str) and name and '\\' not in name and ':' not in name,
            'source path')
    p = PurePosixPath(name)
    require(not p.is_absolute() and str(p) == name and all(x not in ('', '.', '..') for x in name.split('/')),
            'source path normalization')


def validate_records(records):
    require(type(records) is list and len(records) == 78, 'record count')
    names = set()
    total = 0
    for row in records:
        require(type(row) is dict and set(row) == {'path', 'bytes', 'sha256'}, 'record fields')
        valid_name(row['path'])
        require(row['path'].casefold() not in names and row['path'] != MANIFEST, 'duplicate record')
        names.add(row['path'].casefold())
        require(type(row['bytes']) is int and 0 <= row['bytes'] <= MAX_SOURCE, 'record extent')
        require(type(row['sha256']) is str and re.fullmatch('[0-9a-f]{64}', row['sha256']), 'record hash')
        total += row['bytes']
    require(total <= MAX_SOURCE, 'source extent')
    require({'cargo.toml', 'cargo.lock', 'build.rs', CHANGED_FILE.casefold()} <= names, 'required source')
    return records


def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, 'duplicate JSON key')
        obj[key] = value
    return obj


def read_snapshot(data, expected_sha):
    """展開前の上限検査後、全recordの実bytesとSHAを検証する。"""
    require(type(data) is bytes and len(data) <= MAX_SOURCE and digest(data) == expected_sha, 'source ZIP identity')
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            infos = z.infolist()
            require(len(infos) == 79, 'ZIP entry count')
            names = set()
            total = 0
            for info in infos:
                valid_name(info.filename)
                require(info.filename.casefold() not in names, 'duplicate ZIP member')
                names.add(info.filename.casefold())
                mode = info.external_attr >> 16
                require(not info.is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG), 'ZIP special/link')
                require(not info.flag_bits & 1 and info.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), 'ZIP encoding')
                bound = 65536 if info.filename == MANIFEST else MAX_SOURCE
                require(0 <= info.file_size <= bound, 'ZIP member extent')
                total += info.file_size
            require(total <= MAX_SOURCE + 65536 and MANIFEST in z.namelist(), 'ZIP expanded extent')
            records = validate_records(json.loads(z.read(MANIFEST), object_pairs_hook=unique_object,
                parse_constant=lambda value: (_ for _ in ()).throw(Refusal('nonfinite JSON'))))
            require(set(z.namelist()) == {r['path'] for r in records} | {MANIFEST}, 'ZIP record set')
            files = {}
            for row in records:
                body = z.read(row['path'])
                require(len(body) == row['bytes'] and digest(body) == row['sha256'], 'source record bytes/hash')
                files[row['path']] = body
            return records, files
    except (zipfile.BadZipFile, UnicodeError, json.JSONDecodeError, RuntimeError, OSError) as exc:
        raise Refusal('invalid source ZIP/manifest') from exc


def generate(base):
    """返却はZIP bytes・78records・差分metadata。ファイル作成や実行はしない。"""
    old_records, old_files = read_snapshot(base, BASE_SHA)
    require(digest(old_files[CHANGED_FILE]) == PACKET_SHA, 'packet baseline')
    files = dict(old_files)
    files[CHANGED_FILE] = replace_once(files[CHANGED_FILE], OLD_CHOOSE, NEW_CHOOSE)
    require(replace_once(files[CHANGED_FILE], NEW_CHOOSE, OLD_CHOOSE) == old_files[CHANGED_FILE], 'reverse rewrite')
    require([name for name in sorted(files) if files[name] != old_files[name]] == [CHANGED_FILE], 'changed source set')
    records = [{'path': name, 'bytes': len(body), 'sha256': digest(body)} for name, body in sorted(files.items())]
    validate_records(records)
    manifest = canonical(records)
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name, body in sorted({**files, MANIFEST: manifest}.items()):
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, body, compresslevel=9)
    result = output.getvalue()
    require(len(result) <= MAX_SOURCE, 'output ZIP extent')
    read_snapshot(result, digest(result))
    metadata = {'schema': 1, 'purpose': 'source-only-cdf-chooser-ablation',
        'base_zip_sha256': BASE_SHA, 'source_zip_sha256': digest(result), 'source_zip_bytes': len(result),
        'manifest_sha256': digest(manifest), 'manifest_bytes': len(manifest),
        'records': len(old_records), 'changed_files': [{'path': CHANGED_FILE,
            'old_bytes': len(old_files[CHANGED_FILE]), 'old_sha256': digest(old_files[CHANGED_FILE]),
            'new_bytes': len(files[CHANGED_FILE]), 'new_sha256': digest(files[CHANGED_FILE])}],
        'unchanged_files': 77, 'performance_verified': False, 'superiority_decision_allowed': False,
        'hypothesis': 'explicit four guarded comparisons; codegen and performance unverified'}
    return result, records, metadata


def checked_path(raw, *, missing=False):
    """CLIは既存親を非追跡確認し、出力を排他的に新規作成する。"""
    path = Path(raw)
    require(path.is_absolute() and '..' not in path.parts, 'absolute path required')
    for component in reversed((path.parent if missing else path, *(path.parent if missing else path).parents)):
        s = component.lstat()
        require(not stat.S_ISLNK(s.st_mode) and not getattr(s, 'st_file_attributes', 0) & 0x400, 'link/reparse path')
        if component != path:
            require(stat.S_ISDIR(s.st_mode), 'ancestor directory')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-zip', required=True)
    parser.add_argument('--output-zip', required=True)
    args = parser.parse_args()
    source = checked_path(args.base_zip)
    s = source.lstat()
    require(stat.S_ISREG(s.st_mode) and s.st_nlink == 1 and s.st_size <= MAX_SOURCE, 'input file type/extent')
    output = checked_path(args.output_zip, missing=True)
    require(not output.exists() and not output.is_symlink() and os.access(output.parent, os.W_OK), 'output unavailable')
    data, _, metadata = generate(source.read_bytes())
    with output.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    require(output.read_bytes() == data, 'saved ZIP identity')
    print(canonical(metadata).decode(), end='')


if __name__ == '__main__':
    main()
