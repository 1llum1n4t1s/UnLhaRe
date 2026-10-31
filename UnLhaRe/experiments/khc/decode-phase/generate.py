#!/usr/bin/env python3
"""Generate a separate diagnostic source ZIP from the pinned 78-file snapshot.

generate(bytes) performs no I/O and returns (ZIP bytes, 80 records, diff metadata).
An optional caller-supplied formatter receives only the five diagnostic files;
its fixed tool identity and each before/after hash are bound in diff metadata.
The import reads only the two adjacent Rust templates. No base source is edited.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import tomllib
import zipfile

BASE_SHA='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f'
MAX_BYTES=8*1024**2
CHANGED=('src/khc/mod.rs','src/khc/block/mod.rs','src/khc/spatial.rs')
ADDED=('src/khc/phase_diagnostic.rs','examples/khc_archive_phase_diagnostic.rs')
FORMATTER_IDENTITY=dict(
    tool='C:/Users/IMT/.rustup/toolchains/1.99.1-x86_64-pc-windows-msvc/bin/rustfmt.exe',
    toolchain='1.99.1-x86_64-pc-windows-msvc',
    version='rustfmt 1.10.0-stable (58cf8f9c35 2026-10-13)',
    sha256='231e4b294d5f6d9f025a9025514e3e6b0ee5defa524fd016498e1c77eb96980a',
    arguments=['--edition','2024','--emit','stdout','--config','skip_children=true'])
PHASE_NAMES=(
    'archive.whole','archive.open','archive.manifest','archive.parallel_eligibility',
    'archive.parallel_dispatch','archive.read_frame','archive.decompress','archive.file_crc',
    'archive.write','archive.sync_all','archive.publish','archive.close','archive.finish',
    'block.whole','block.header_wire','block.stored_copy','block.lz','block.model_setup',
    'block.entropy_loop','block.inverse','block.raw_crc','spatial.whole','spatial.header_wire',
    'spatial.stored_copy','spatial.model_setup','spatial.token_loop','spatial.raw_crc',
)


class Refusal(RuntimeError):
    pass


def require(ok,message):
    if not ok:raise Refusal(message)


def sha(data):return hashlib.sha256(data).hexdigest()


def canonical(value):
    return (json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False)+'\n').encode()


def strict_json(data):
    def pairs(rows):
        result={}
        for name,value in rows:
            require(name not in result,'duplicate JSON key');result[name]=value
        return result
    return json.loads(data,object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(Refusal('nonfinite JSON')))


def checked_path(path,*,must_exist):
    require(path.is_absolute() and '..' not in path.parts,'absolute normalized path required')
    for ancestor in [path]+list(path.parents):
        try:info=ancestor.lstat()
        except FileNotFoundError:
            require(ancestor==path and not must_exist,'missing parent/input');continue
        require(not stat.S_ISLNK(info.st_mode) and not getattr(info,'st_file_attributes',0)&getattr(stat,'FILE_ATTRIBUTE_REPARSE_POINT',1024),'link/reparse point rejected')
        if ancestor!=path:require(stat.S_ISDIR(info.st_mode),'ancestor is not a directory')
    return path


def read_file(path,maximum):
    checked_path(path,must_exist=True);info=path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink==1 and info.st_size<=maximum,'input type/link/size')
    with path.open('rb') as stream:data=stream.read(maximum+1)
    require(len(data)<=maximum,'input grew beyond bound')
    return data


HERE=Path(__file__).absolute().parent
PHASE_SOURCE=read_file(HERE/'phase.rs',65536)
EXAMPLE_SOURCE=read_file(HERE/'example.rs',65536)


def replace_once(body,before,after):
    require(type(body) is bytes and type(before) is bytes and type(after) is bytes and
        before and body.count(before)==1,'exact marker missing or duplicated')
    return body.replace(before,after,1)


def patch(path,before,after):return path,before.encode(),after.encode()


M,B,S=CHANGED
P='crate::khc::phase_diagnostic::enter'

# old markerは各々固定snapshotの一箇所だけ。I/Oと?の並びを維持する。
PATCHES=[
    patch(M,'pub(crate) mod block;','pub(crate) mod block;\n/// Derived diagnostic source only.\npub mod phase_diagnostic;'),
    patch(M,'pub fn decompress_block(frame: &[u8]) -> Result<Vec<u8>> {',
        'pub fn decompress_block(frame: &[u8]) -> Result<Vec<u8>> {\n    let _phase_decompress = '+P+'("archive.decompress");'),
    patch(M,'fn open_archive(path: &Path) -> Result<File> {',
        'fn open_archive(path: &Path) -> Result<File> {\n    let _phase_open = '+P+'("archive.open");'),
    patch(M,'fn read_manifest(file: &mut File, limits: &Limits) -> Result<(Vec<Entry>, Summary, u8)> {',
        'fn read_manifest(file: &mut File, limits: &Limits) -> Result<(Vec<Entry>, Summary, u8)> {\n    let _phase_manifest = '+P+'("archive.manifest");'),
    patch(M,'fn read_frame(file: &mut File, expected: usize, archive_revision: u8) -> Result<Vec<u8>> {',
        'fn read_frame(file: &mut File, expected: usize, archive_revision: u8) -> Result<Vec<u8>> {\n    let _phase_read_frame = '+P+'("archive.read_frame");'),
    patch(M,'fn finish(file: &mut File) -> Result<()> {',
        'fn finish(file: &mut File) -> Result<()> {\n    let _phase_finish = '+P+'("archive.finish");'),
    patch(M,'    parallel: bool,\n) -> Result<Summary> {\n    checkpoint(callback, 1, 0, 0)?;',
        '    parallel: bool,\n) -> Result<Summary> {\n    let _phase_whole = '+P+'("archive.whole");\n    checkpoint(callback, 1, 0, 0)?;'),
    patch(M,'    if parallel && pipeline::eligible(&mut input, &entries, revision)? {\n        pipeline::process(',
        '    if parallel && {\n        let _phase_eligibility = '+P+'("archive.parallel_eligibility");\n        pipeline::eligible(&mut input, &entries, revision)?\n    } {\n        let _phase_dispatch = '+P+'("archive.parallel_dispatch");\n        pipeline::process('),
    patch(M,'            if raw.len() != expected {\n                return Err(Error::Format("KHC decoded size".into()));\n            }\n            file_crc.update(&raw);',
        '            if raw.len() != expected {\n                return Err(Error::Format("KHC decoded size".into()));\n            }\n            {\n                let _phase_crc = '+P+'("archive.file_crc");\n                file_crc.update(&raw);\n            }'),
    patch(M,'                output.write_all(&raw)?;',
        '                let _phase_write = '+P+'("archive.write");\n                output.write_all(&raw)?;'),
    patch(M,'        let mut expected_crc = [0u8; 4];\n        exact(&mut input, &mut expected_crc)?;',
        '        let phase_final_crc = '+P+'("archive.file_crc");\n        let mut expected_crc = [0u8; 4];\n        exact(&mut input, &mut expected_crc)?;'),
    patch(M,'            return Err(Error::Format("KHC file CRC".into()));\n        }\n        if let (Some(output),',
        '            return Err(Error::Format("KHC file CRC".into()));\n        }\n        drop(phase_final_crc);\n        if let (Some(output),'),
    patch(M,'            output.sync_all()?;\n            crate::reader::publish_staged_no_replace(',
        '            let phase_sync = '+P+'("archive.sync_all");\n            output.sync_all()?;\n            drop(phase_sync);\n            let phase_publish = '+P+'("archive.publish");\n            crate::reader::publish_staged_no_replace('),
    patch(M,'                staging, output, parent, filename, &path, callback,\n            )?;\n        }\n        drop(output);\n        if let Some(staging) = staging {\n            staging.close()?;\n        }',
        '                staging, output, parent, filename, &path, callback,\n            )?;\n            drop(phase_publish);\n        }\n        {\n            let _phase_close = '+P+'("archive.close");\n            drop(output);\n            if let Some(staging) = staging {\n                staging.close()?;\n            }\n        }'),
    patch(B,'pub(crate) fn decode(bytes: &[u8]) -> Result<(Vec<u8>, Stats)> {',
        'pub(crate) fn decode(bytes: &[u8]) -> Result<(Vec<u8>, Stats)> {\n    let _phase_whole = '+P+'("block.whole");\n    let phase_header = '+P+'("block.header_wire");'),
    patch(B,'    if crc_parts(&[&bytes[..36], &bytes[40..]]) != get32(bytes, 36)? as u32 {\n        return Err("wire CRC".into());\n    }',
        '    if crc_parts(&[&bytes[..36], &bytes[40..]]) != get32(bytes, 36)? as u32 {\n        return Err("wire CRC".into());\n    }\n    drop(phase_header);'),
    patch(B,'        plain.copy_from_slice(&bytes[40..]);\n        if crc32(&plain) != get32(bytes, 32)? as u32 {\n            return Err("plain CRC".into());\n        }',
        '        {\n            let _phase_copy = '+P+'("block.stored_copy");\n            plain.copy_from_slice(&bytes[40..]);\n        }\n        {\n            let _phase_crc = '+P+'("block.raw_crc");\n            if crc32(&plain) != get32(bytes, 32)? as u32 {\n                return Err("plain CRC".into());\n            }\n        }'),
    patch(B,'        let plain = lz::decode(&bytes[40..], raw, if method == 2 { 3 } else { 8 })?;\n        if crc32(&plain) != get32(bytes, 32)? as u32 {\n            return Err("plain CRC".into());\n        }',
        '        let plain = {\n            let _phase_lz = '+P+'("block.lz");\n            lz::decode(&bytes[40..], raw, if method == 2 { 3 } else { 8 })?\n        };\n        {\n            let _phase_crc = '+P+'("block.raw_crc");\n            if crc32(&plain) != get32(bytes, 32)? as u32 {\n                return Err("plain CRC".into());\n            }\n        }'),
    patch(B,'    let mut alphabet = [0u16; 257];\n    let mut active = [0u16; 257];',
        '    let phase_model = '+P+'("block.model_setup");\n    let mut alphabet = [0u16; 257];\n    let mut active = [0u16; 257];'),
    patch(B,'        multi_range::Decoder::new(&bytes[model_start + model_len..]).map_err(str::to_owned)?;',
        '        multi_range::Decoder::new(&bytes[model_start + model_len..]).map_err(str::to_owned)?;\n    drop(phase_model);'),
    patch(B,'    let mut encounter_count = 0;\n    while remaining != 0 {',
        '    let mut encounter_count = 0;\n    let phase_entropy = '+P+'("block.entropy_loop");\n    while remaining != 0 {'),
    patch(B,'    dec.finish().map_err(str::to_owned)?;\n    drop(forest);',
        '    dec.finish().map_err(str::to_owned)?;\n    drop(phase_entropy);\n    drop(forest);'),
    patch(B,'    let inverse = packed::inverse(&last, primary, &alphabet[..alphabet_len])?;',
        '    let inverse = {\n        let _phase_inverse = '+P+'("block.inverse");\n        packed::inverse(&last, primary, &alphabet[..alphabet_len])?\n    };'),
    patch(B,'    let plain = inverse.plain;\n    if crc32(&plain) != get32(bytes, 32)? as u32 {\n        return Err("plain CRC".into());\n    }',
        '    let plain = inverse.plain;\n    {\n        let _phase_crc = '+P+'("block.raw_crc");\n        if crc32(&plain) != get32(bytes, 32)? as u32 {\n            return Err("plain CRC".into());\n        }\n    }'),
    patch(S,'pub(super) fn decode(frame: &[u8], expected: usize) -> Result<(Vec<u8>, Stats)> {\n    validate_frame(frame, expected)?;',
        'pub(super) fn decode(frame: &[u8], expected: usize) -> Result<(Vec<u8>, Stats)> {\n    let _phase_whole = '+P+'("spatial.whole");\n    let phase_header = '+P+'("spatial.header_wire");\n    validate_frame(frame, expected)?;'),
    patch(S,'    let payload_len = field(frame, 20)?;\n    let mut out = alloc(raw)?;',
        '    let payload_len = field(frame, 20)?;\n    drop(phase_header);\n    let mut out = alloc(raw)?;'),
    patch(S,'            out.extend_from_slice(&frame[HEADER..]);',
        '            let _phase_copy = '+P+'("spatial.stored_copy");\n            out.extend_from_slice(&frame[HEADER..]);'),
    patch(S,'            let model = CountModel::parse(&frame[HEADER..HEADER + model_len])?;',
        '            let phase_model = '+P+'("spatial.model_setup");\n            let model = CountModel::parse(&frame[HEADER..HEADER + model_len])?;'),
    patch(S,'            let mut table = [16384; 4096];\n            while out.len() < raw {',
        '            let mut table = [16384; 4096];\n            drop(phase_model);\n            let phase_tokens = '+P+'("spatial.token_loop");\n            while out.len() < raw {'),
    patch(S,'            stats.final_width = v.best();',
        '            drop(phase_tokens);\n            stats.final_width = v.best();'),
    patch(S,'    if crc(&[&out]) as usize != field(frame, 24)? {\n        return Err("raw CRC".into());\n    }',
        '    {\n        let _phase_crc = '+P+'("spatial.raw_crc");\n        if crc(&[&out]) as usize != field(frame, 24)? {\n            return Err("raw CRC".into());\n        }\n    }'),
]


def validate_records(records,count):
    require(type(records) is list and len(records)==count,'snapshot record count')
    seen=set();total=0
    root_names={'Cargo.toml','Cargo.lock','build.rs','THIRD_PARTY_NOTICES.md','THIRD_PARTY_LICENSES.txt'}
    for row in records:
        require(type(row) is dict and set(row)=={'path','bytes','sha256'},'snapshot record fields')
        name=row['path'];require(type(name) is str and 0<len(name)<=250,'snapshot name')
        path=PurePosixPath(name)
        require(path.as_posix()==name and not path.is_absolute() and '..' not in path.parts and '\\' not in name and
            name.casefold() not in seen and (name in root_names or (path.parts[0] in ('src','examples') and name.endswith('.rs'))),'snapshot path/duplicate')
        require(type(row['bytes']) is int and 0<=row['bytes']<=MAX_BYTES and type(row['sha256']) is str and
            re.fullmatch('[0-9a-f]{64}',row['sha256']) is not None,'snapshot bytes/SHA')
        seen.add(name.casefold());total+=row['bytes']
    require(total<=MAX_BYTES and root_names|{'src/lib.rs','src/main.rs'}<= {r['path'] for r in records},'snapshot total/required inputs')


def base_files(data):
    require(type(data) is bytes and len(data)<=MAX_BYTES and sha(data)==BASE_SHA,'fixed base ZIP SHA/bound')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members=archive.infolist()
        require(len(members)==79 and len({m.filename for m in members})==79 and
            sum(m.file_size for m in members)<=MAX_BYTES+65536,'base ZIP count/expanded bound')
        require(all(not m.is_dir() and not m.flag_bits&1 and m.compress_type in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED) and
            stat.S_IFMT(m.external_attr>>16) in (0,stat.S_IFREG) for m in members),'base ZIP member type')
        manifest=archive.getinfo('snapshot-manifest.json');require(manifest.file_size<=65536,'base manifest bound')
        records=strict_json(archive.read(manifest));validate_records(records,78)
        require(set(archive.namelist())=={r['path'] for r in records}|{'snapshot-manifest.json'},'base ZIP file set')
        result={}
        for row in records:
            body=archive.read(row['path'])
            require(len(body)==row['bytes'] and sha(body)==row['sha256'],'base full file bytes/SHA')
            result[row['path']]=body
    cargo=tomllib.loads(result['Cargo.toml'].decode('utf-8'))
    require(cargo.get('package',{}).get('autoexamples',True) is True and
        all(example.get('name')!='khc_archive_phase_diagnostic' for example in cargo.get('example',[])),
        'Cargo autoexample disabled or explicit name collision')
    return result


def generate(data,*,formatter=None,formatter_identity=None):
    require((formatter is None and formatter_identity is None) or
        (callable(formatter) and type(formatter_identity) is dict and
         canonical(formatter_identity)==canonical(FORMATTER_IDENTITY)),
        'formatter requires the fixed tool/version/SHA/arguments identity')
    original=base_files(data);files=dict(original)
    require(not (set(ADDED)&set(original)),'diagnostic source already present')
    for path,before,after in PATCHES:files[path]=replace_once(files[path],before,after)
    files[ADDED[0]]=PHASE_SOURCE;files[ADDED[1]]=EXAMPLE_SOURCE
    changed={name for name in original if original[name]!=files[name]}
    require(changed==set(CHANGED) and set(files)-set(original)==set(ADDED),'derived file change boundary')
    require(sum(original[name]==files[name] for name in original)==75,'unchanged 75 file boundary')
    # 整形が始まる前に、計測挿入の全逆置換がbaseへ完全に戻ることを検証。
    for name in CHANGED:
        restored=files[name]
        for path,before,after in reversed(PATCHES):
            if path==name:restored=replace_once(restored,after,before)
        require(restored==original[name],'raw instrumentation reversal differs from base')
    formatting=None
    if formatter is not None:
        formatted=[]
        for name in CHANGED+ADDED:
            before=files[name];after=formatter(name,before)
            require(type(after) is bytes and 0<len(after)<=MAX_BYTES,'formatter output type/bound')
            try:after.decode('utf-8')
            except UnicodeDecodeError as error:raise Refusal('formatter output is not UTF-8') from error
            files[name]=after
            formatted.append(dict(path=name,before_bytes=len(before),before_sha256=sha(before),
                                  after_bytes=len(after),after_sha256=sha(after)))
        formatting=dict(identity=strict_json(canonical(formatter_identity)),files=formatted)
    require({name for name in original if original[name]!=files[name]}==set(CHANGED) and
        sum(original[name]==files[name] for name in original)==75 and
        set(files)-set(original)==set(ADDED),'post-format three/two/seventy-five file boundary')
    records=[dict(path=name,bytes=len(body),sha256=sha(body)) for name,body in sorted(files.items())]
    validate_records(records,80)
    manifest=canonical(records);require(len(manifest)<=65536,'derived manifest bound')
    output=io.BytesIO()
    with zipfile.ZipFile(output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
        for name,body in list(sorted(files.items()))+[('snapshot-manifest.json',manifest)]:
            info=zipfile.ZipInfo(name,(1980,1,1,0,0,0));info.external_attr=(stat.S_IFREG|0o644)<<16
            info.compress_type=zipfile.ZIP_DEFLATED;archive.writestr(info,body,compresslevel=9)
    result=output.getvalue();require(len(result)<=MAX_BYTES,'derived ZIP bound')
    metadata=dict(schema=1,purpose='non-comparative-decode-phase-diagnostic',superiority_decision_allowed=False,
        base_source_sha256=BASE_SHA,base_records=78,records=80,unchanged_files=75,
        source_zip_sha256=sha(result),source_zip_bytes=len(result),manifest_sha256=sha(manifest),
        changed=[dict(path=name,before_bytes=len(original[name]),before_sha256=sha(original[name]),after_bytes=len(files[name]),after_sha256=sha(files[name])) for name in CHANGED],
        added=[dict(path=name,bytes=len(files[name]),sha256=sha(files[name])) for name in ADDED],
        phase_schema=1,phase_names=list(PHASE_NAMES),cargo_autoexample_verified=True,
        raw_patch_reversal_verified=True,formatting=formatting,
        source_namespace='derived diagnostic only; frozen source and CLI unchanged',
        inclusive=True,aggregation='do not sum inclusive phases; outer total includes unmeasured intervals')
    return result,records,metadata


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-zip',required=True);parser.add_argument('--output-zip',required=True)
    args=parser.parse_args()
    source=checked_path(Path(args.base_zip),must_exist=True)
    output=checked_path(Path(args.output_zip),must_exist=False)
    require(source!=output and not output.exists() and not output.is_symlink(),'new output path required')
    require(output.parent.is_dir() and os.access(output.parent,os.W_OK),'output parent is not writable')
    result,_,metadata=generate(read_file(source,MAX_BYTES))
    with output.open('xb') as stream:stream.write(result);stream.flush();os.fsync(stream.fileno())
    checked_path(output,must_exist=True)
    require(read_file(output,MAX_BYTES)==result,'saved derived ZIP bytes changed')
    sys.stdout.buffer.write(canonical(metadata));return 0


if __name__=='__main__':sys.exit(main())
