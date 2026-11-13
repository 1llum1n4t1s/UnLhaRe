"""先行失敗条件: base/hash/manifest改変、marker欠落/重複、変更範囲逸脱、非決定生成。"""
import hashlib
import importlib.util
import io
import json
import re
from pathlib import Path
import unittest
import zipfile

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('phase_generator',HERE/'generate.py')
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)
BASE=Path('D:/Claude/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-native-source.zip')


class Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=BASE.read_bytes()
        cls.generated,cls.manifest,cls.meta=M.generate(cls.base)

    def test_base_pin_and_eighty_records(self):
        self.assertEqual(hashlib.sha256(self.base).hexdigest(),M.BASE_SHA)
        self.assertEqual(len(self.manifest),80)
        with zipfile.ZipFile(io.BytesIO(self.generated)) as archive:
            self.assertEqual(len(archive.namelist()),81)
            self.assertEqual(json.loads(archive.read('snapshot-manifest.json')),self.manifest)
            for row in self.manifest:
                body=archive.read(row['path'])
                self.assertEqual(len(body),row['bytes'])
                self.assertEqual(hashlib.sha256(body).hexdigest(),row['sha256'])

    def test_only_three_changes_two_additions_and_seventy_five_identical(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as old,zipfile.ZipFile(io.BytesIO(self.generated)) as new:
            changed=[];identical=[]
            for name in old.namelist():
                if name=='snapshot-manifest.json':continue
                (identical if old.read(name)==new.read(name) else changed).append(name)
            self.assertEqual(set(changed),set(M.CHANGED))
            self.assertEqual(len(identical),75)
            self.assertEqual(set(new.namelist())-set(old.namelist()),set(M.ADDED))
            for name in ('Cargo.toml','Cargo.lock','build.rs'):
                self.assertEqual(old.read(name),new.read(name))

    def test_generation_is_deterministic_and_diff_hashes_bind_bytes(self):
        data,manifest,metadata=M.generate(self.base)
        self.assertEqual((data,manifest,metadata),(self.generated,self.manifest,self.meta))
        self.assertEqual(metadata['source_zip_sha256'],hashlib.sha256(data).hexdigest())
        self.assertFalse(metadata['superiority_decision_allowed'])
        self.assertEqual(metadata['purpose'],'non-comparative-decode-phase-diagnostic')

    def test_optional_formatter_only_sees_five_files_and_binds_identity(self):
        seen=[]
        def formatter(path,body):
            seen.append(path)
            return body+b'\n'
        data,records,metadata=M.generate(self.base,formatter=formatter,formatter_identity=M.FORMATTER_IDENTITY)
        self.assertEqual(seen,list(M.CHANGED+M.ADDED))
        self.assertTrue(metadata['raw_patch_reversal_verified'])
        self.assertEqual(metadata['formatting']['identity'],M.FORMATTER_IDENTITY)
        self.assertEqual([r['path'] for r in metadata['formatting']['files']],seen)
        with zipfile.ZipFile(io.BytesIO(self.base)) as old,zipfile.ZipFile(io.BytesIO(data)) as new:
            for name in old.namelist():
                if name not in set(M.CHANGED)|{'snapshot-manifest.json'}:
                    self.assertEqual(old.read(name),new.read(name))

    def test_formatter_rejects_unbound_identity_and_bad_output(self):
        for identity in (None,{},dict(M.FORMATTER_IDENTITY,sha256='0'*64)):
            with self.assertRaises(M.Refusal):
                M.generate(self.base,formatter=lambda p,b:b,formatter_identity=identity)
        for output in (None,b'',b'\xff'):
            with self.assertRaises(M.Refusal):
                M.generate(self.base,formatter=lambda p,b:output,formatter_identity=M.FORMATTER_IDENTITY)

    def test_base_mutation_is_rejected(self):
        for data in (b'',self.base[:-1],self.base+b'x'):
            with self.assertRaises(M.Refusal):M.generate(data)

    def test_exact_marker_missing_and_duplicate_are_rejected(self):
        with self.assertRaises(M.Refusal):M.replace_once(b'oldold',b'old',b'new')
        with self.assertRaises(M.Refusal):M.replace_once(b'body',b'old',b'new')
        self.assertEqual(M.replace_once(b'old',b'old',b'new'),b'new')

    def test_reverse_all_insertions_restores_exact_base_bytes(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as old,zipfile.ZipFile(io.BytesIO(self.generated)) as new:
            for name in M.CHANGED:
                body=new.read(name)
                for path,before,after in reversed(M.PATCHES):
                    if path==name:body=M.replace_once(body,after,before)
                self.assertEqual(body,old.read(name))

    def test_fixed_phase_abi_and_no_inner_loop_timer(self):
        names=M.PHASE_NAMES
        self.assertEqual(len(names),27)
        self.assertEqual(len(set(names)),27)
        for name in names:self.assertIn(('"'+name+'"').encode(),M.PHASE_SOURCE)
        array=M.PHASE_SOURCE.split(b'pub const PHASE_NAMES:',1)[1].split(b'];',1)[0]
        self.assertEqual(tuple(s.decode() for s in re.findall(rb'"([a-z_.]+)"',array)),names)
        self.assertIn(b'Instant',M.PHASE_SOURCE)
        self.assertIn(b'impl Drop for Guard',M.PHASE_SOURCE)
        self.assertIn(b'outer_total_ns',M.PHASE_SOURCE)
        self.assertIn(b'do not sum inclusive phases',M.PHASE_SOURCE)
        self.assertNotIn(b'#[test]',M.PHASE_SOURCE+M.EXAMPLE_SOURCE)
        self.assertNotIn(b'unsafe',M.PHASE_SOURCE+M.EXAMPLE_SOURCE)
        self.assertEqual(M.EXAMPLE_SOURCE.count(b'println!'),1)

    def test_manifest_rejects_duplicate_path_and_noninteger_length(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as archive:
            records=json.loads(archive.read('snapshot-manifest.json'))
        for rows in (records+[records[0]], [dict(records[0],bytes=True)]+records[1:],
                     [dict(records[0],path='../Cargo.toml')]+records[1:]):
            with self.assertRaises(M.Refusal):M.validate_records(rows,78)


if __name__=='__main__':unittest.main()
