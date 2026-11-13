"""先行条件: 全interval同値、無副作用、基準/marker/ZIP/変更範囲の拒否。"""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import random
import re
import unittest
import warnings
import zipfile

HERE=Path(__file__).absolute().parent
spec=importlib.util.spec_from_file_location('cdf_ablation',HERE/'generate.py')
M=importlib.util.module_from_spec(spec);spec.loader.exec_module(M)
BASE=Path('D:/Claude/TaskArtifacts/UnLhaRe/goal-restore-20261019/mac-native-source.zip')


def branch_program():
    """実置換Rustの制限文法を読む。別の候補モデルを手書きしない。"""
    body=M.NEW_CHOOSE.decode().split('{',1)[1].rsplit('}',1)[0]
    pattern=re.compile(r'if self\.k > (\d+) \{\s*let end = u32::from\(self.ends\[(\d+)\]\);\s*'
        r'if slot < end \{\s*(?:let cumulative = u32::from\(self.ends\[(\d+)\]\);\s*)?'
        r'return Ok\(\((\d+), (0|cumulative), (end(?: - cumulative)?)\)\);\s*\}\s*\}')
    program=[];cursor=0
    for match in pattern.finditer(body):
        if body[cursor:match.start()].strip():raise AssertionError('unsupported Rust statement')
        k,index,previous,child,second,third=match.groups()
        program.append((int(k),int(index),None if previous is None else int(previous),int(child),second,third))
        cursor=match.end()
    if body[cursor:].strip()!='Err("range CDF child".into())' or len(program)!=4:
        raise AssertionError('unexpected Rust fallthrough/branch count')
    return program


def reference(ends,k,slot):
    cumulative=0
    for child in range(min(k,4)):
        end=ends[child]
        if slot<end:return child,cumulative,end-cumulative
        cumulative=end
    return 'range CDF child'


def candidate(ends,k,slot,program):
    for minimum,index,previous,child,second,third in program:
        if k>minimum:
            end=ends[index]
            if slot<end:
                cumulative=0 if previous is None else ends[previous]
                result=(child,0 if second=='0' else cumulative,end-cumulative if third=='end - cumulative' else end)
                if not 0<=result[2]<2**32:raise AssertionError('Rust u32 subtraction overflow')
                return result
    return 'range CDF child'


class Ablation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base=BASE.read_bytes();cls.program=branch_program()
        cls.generated,cls.records,cls.meta=M.generate(cls.base)

    def test_exact_one_changed_seventy_seven_unchanged(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as old,zipfile.ZipFile(io.BytesIO(self.generated)) as new:
            names=[r['path'] for r in json.loads(old.read('snapshot-manifest.json'))]
            changed=[n for n in names if old.read(n)!=new.read(n)]
            self.assertEqual(changed,[M.CHANGED_FILE]);self.assertEqual(len(names)-len(changed),77)
            self.assertEqual(set(old.namelist()),set(new.namelist()))
            body=new.read(M.CHANGED_FILE)
            self.assertEqual(M.replace_once(body,M.NEW_CHOOSE,M.OLD_CHOOSE),old.read(M.CHANGED_FILE))
            for name in ('Cargo.toml','Cargo.lock','build.rs'):
                self.assertEqual(old.read(name),new.read(name))

    def test_full_manifest_and_deterministic_source_id(self):
        self.assertEqual(M.generate(self.base),(self.generated,self.records,self.meta))
        self.assertEqual(len(self.records),78)
        self.assertEqual(self.meta['source_zip_sha256'],hashlib.sha256(self.generated).hexdigest())
        self.assertEqual(self.meta['unchanged_files'],77)
        self.assertFalse(self.meta['performance_verified']);self.assertFalse(self.meta['superiority_decision_allowed'])
        with zipfile.ZipFile(io.BytesIO(self.generated)) as z:
            self.assertEqual(json.loads(z.read('snapshot-manifest.json')),self.records)
            for row in self.records:
                b=z.read(row['path']);self.assertEqual(len(b),row['bytes'])
                self.assertEqual(hashlib.sha256(b).hexdigest(),row['sha256'])

    def test_all_valid_support_slots_and_unused_tail(self):
        rows={2:((2,32766),(16384,16384),(32766,2)),
              3:((2,2,32764),(10000,10000,12768),(32764,2,2)),
              4:((2,2,2,32762),(8192,8192,8192,8192),(32762,2,2,2))}
        for k,frequencies in rows.items():
            for frequencies in frequencies:
                cumulative=[];total=0
                for value in frequencies:total+=value;cumulative.append(total)
                ends=tuple(cumulative+[0]*(4-k))
                for slot in range(32769):
                    self.assertEqual(candidate(ends,k,slot,self.program),reference(ends,k,slot))
                for slot in (32769,65535,2**32-1):
                    self.assertEqual(candidate(ends,k,slot,self.program),reference(ends,k,slot))

    def test_malformed_cdfs_all_boundaries_and_k_zero_one_above_four(self):
        rng=random.Random(20261027)
        rows=[(0,0,0,0),(65535,0,65534,1),(1,1,1,1),(0,1,65535,2),(32768,2,32768,0)]
        rows += [tuple(rng.randrange(65536) for _ in range(4)) for _ in range(1000)]
        for ends in rows:
            slots={0,1,65535,65536,2**32-1}
            for end in ends:slots.update(v for v in (end-1,end,end+1) if 0<=v<2**32)
            for k in (0,1,2,3,4,5,17,2**64-1):
                for slot in slots:self.assertEqual(candidate(ends,k,slot,self.program),reference(ends,k,slot))

    def test_no_mutation_or_access_outside_active_array(self):
        class Ends:
            def __init__(self,values,k):self.values=values;self.k=min(k,4);self.reads=[]
            def __getitem__(self,index):
                self.reads.append(index)
                if not 0<=index<self.k:raise AssertionError('inactive/out-of-array read')
                return self.values[index]
        for k in (0,1,2,3,4,5,2**64-1):
            values=(2,3,4,65535)
            ends=Ends(values,k);candidate(ends,k,2**32-1,self.program)
            self.assertEqual(ends.values,values)
            if k==0:self.assertEqual(ends.reads,[])
            ends=Ends(values,k);candidate(ends,k,0,self.program)
            if k:self.assertEqual(ends.reads,[0])
        self.assertNotIn(b'unsafe',M.NEW_CHOOSE);self.assertNotIn(b'let mut',M.NEW_CHOOSE)

    def test_wrong_base_and_unique_rewrite_are_required(self):
        for data in (b'',self.base[:-1],self.base+b'x'):
            with self.assertRaises(M.Refusal):M.generate(data)
        with self.assertRaises(M.Refusal):M.replace_once(b'oldold',b'old',b'new')
        with self.assertRaises(M.Refusal):M.replace_once(b'none',b'old',b'new')

    def test_private_zip_validation_rejects_duplicate_symlink_and_bomb(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as z:files={n:z.read(n) for n in z.namelist()}
        for kind in ('duplicate','link','bomb','missing','traversal'):
            out=io.BytesIO()
            with warnings.catch_warnings():
                warnings.simplefilter('ignore',UserWarning)
                with zipfile.ZipFile(out,'w',compression=zipfile.ZIP_DEFLATED) as z:
                    for name,body in files.items():
                        if kind=='missing' and name==M.CHANGED_FILE:continue
                        if kind=='bomb' and name==M.CHANGED_FILE:body=b'\0'*(M.MAX_SOURCE+1)
                        if kind=='traversal' and name==M.CHANGED_FILE:name='../packet.rs'
                        info=zipfile.ZipInfo(name);info.compress_type=zipfile.ZIP_DEFLATED
                        info.external_attr=((0o120777 if kind=='link' and name==M.CHANGED_FILE else 0o100644)<<16)
                        z.writestr(info,body)
                    if kind=='duplicate':z.writestr(M.CHANGED_FILE,files[M.CHANGED_FILE])
            data=out.getvalue()
            with self.subTest(kind=kind),self.assertRaises(M.Refusal):M.read_snapshot(data,M.digest(data))

    def test_record_extent_types_duplicate_and_hash_are_strict(self):
        with zipfile.ZipFile(io.BytesIO(self.base)) as z:rows=json.loads(z.read('snapshot-manifest.json'))
        for bad in (rows+[rows[0]],[dict(rows[0],bytes=True)]+rows[1:],
                    [dict(rows[0],path='../Cargo.toml')]+rows[1:],[dict(rows[0],sha256='0'*63)]+rows[1:]):
            with self.assertRaises(M.Refusal):M.validate_records(bad)


if __name__=='__main__':unittest.main()
