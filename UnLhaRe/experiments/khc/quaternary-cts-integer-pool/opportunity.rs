#![allow(dead_code)]
#[path = "../causal-bayes-sais/bwt.rs"] mod bwt;
#[path = "../direct-token/cdf_model.rs"] mod original;
#[path = "fixed_math.rs"] mod fixed_math;
#[path = "integer_pool.rs"] mod integer_pool;
#[path = "../quaternary-cts-q32/integer_cts.rs"] mod integer_cts;
use fixed_math::{Math,Q,EXP_CUTOFF};
use integer_cts::{Cts,Snapshot,CLASSES,LEVELS,NODES,CAP};
use std::io::Read;

#[derive(Clone, Copy, Default)]
struct Sum { value: f64, correction: f64 }
impl Sum {
    fn add(&mut self, x: f64) {
        assert!(x.is_finite());
        let y = x - self.correction;
        let t = self.value + y;
        self.correction = (t - self.value) - y;
        self.value = t;
    }
}
fn close(a: f64, b: f64) { assert!(a.is_finite() && b.is_finite() && (a-b).abs() <= 2e-10 * (1.0+a.abs()+b.abs()), "numeric mismatch {a} {b}"); }
fn digest(h: &mut u64, value: usize) { *h = (*h ^ value as u64).wrapping_mul(0x100000001b3); }
fn exponent(v: usize) -> usize { if v == 0 { 0 } else { (usize::BITS-1-v.leading_zeros()) as usize } }
fn hash(mut x: u32) -> usize {
    x ^= x >> 16; x = x.wrapping_mul(0x7feb352d);
    x ^= x >> 15; x = x.wrapping_mul(0x846ca68b);
    (x ^ (x >> 16)) as usize
}
#[derive(Clone)]
struct Edge { lo: usize, hi: usize, node: Option<usize> }
struct Node { edges: Vec<Edge> }
struct Tree { alphabet: usize, nodes: Vec<Node>, classes:Vec<usize> }
impl Tree {
    fn new(alphabet: usize) -> Self {
        assert!([256,257].contains(&alphabet));
        let mut tree = Self { alphabet, nodes: Vec::new(),classes:Vec::new() };
        assert_eq!(tree.build(0,alphabet),0); assert!(tree.nodes.len()<256); tree.classes=oracle_classes(alphabet); assert_eq!(tree.classes.len(),tree.nodes.len()); tree
    }
    fn build(&mut self, lo: usize, hi: usize) -> usize {
        let id = self.nodes.len(); self.nodes.push(Node { edges: Vec::new() });
        let cuts = if lo==0 { vec![0,1,2,4,hi] }
            else if lo==4 && hi==self.alphabet { vec![4,8,16,32,hi] }
            else if lo==32 && hi==self.alphabet { vec![32,64,128,256,hi] }
            else { let n=(hi-lo).min(4); (0..=n).map(|i| lo+(hi-lo)*i/n).collect() };
        let mut edges=Vec::new();
        for pair in cuts.windows(2) {
            let (a,b)=(pair[0],pair[1]);
            if a<b { edges.push(Edge {lo:a,hi:b,node:if b-a>1 {Some(self.build(a,b))} else {None}}); }
        }
        assert!((2..=4).contains(&edges.len())); self.nodes[id].edges=edges; id
    }
    fn path(&self, token: usize, limit: usize) -> Result<Vec<(usize,usize,usize)>, &'static str> {
        if limit==0 || limit>self.alphabet || token>=limit { return Err("token/limit"); }
        let mut out=Vec::new(); let mut node=0;
        loop {
            let edges=&self.nodes[node].edges;
            let prefix=edges.iter().take_while(|e| e.lo<limit).count();
            let child=edges.iter().position(|e| e.lo<=token && token<e.hi).ok_or("child")?;
            assert!((1..=4).contains(&prefix) && child<prefix);
            out.push((node,child,prefix));
            if let Some(next)=edges[child].node {node=next;} else {assert_eq!(edges[child].lo,token); break;}
        }
        Ok(out)
    }
    fn inverse(&self, path: &[(usize,usize,usize)], limit: usize) -> Result<usize,&'static str> {
        if limit==0 || limit>self.alphabet {return Err("limit");}
        let mut expected=0;
        for (position,&(node,child,prefix)) in path.iter().enumerate() {
            if node!=expected {return Err("node");}
            let edges=&self.nodes[node].edges;
            if prefix==0 || prefix>4 || prefix!=edges.iter().filter(|e|e.lo<limit).count() || child>=prefix {return Err("prefix/child");}
            match edges[child].node {
                Some(next)=>expected=next,
                None=>return if position+1==path.len() {Ok(edges[child].lo)} else {Err("trailing")},
            }
        }
        Err("incomplete")
    }
}
// 木配列を参照せず、契約の区間規則からoracleを生成する。
fn oracle_path(a: usize, token: usize, limit: usize) -> Vec<(usize,usize,usize)> {
    fn visit(a:usize,lo:usize,hi:usize,t:usize,l:usize,id:&mut usize,out:&mut Vec<(usize,usize,usize)>) {
        let here=*id; *id+=1;
        let bounds:Vec<usize>=match (lo,hi) {
            (0,_)=>vec![0,1,2,4,a], (4,h) if h==a=>vec![4,8,16,32,a],
            (32,h) if h==a=>vec![32,64,128,256,a],
            _=>{let width=hi-lo; let count=std::cmp::min(width,4); (0..=count).map(|i|lo+i*width/count).collect()},
        };
        let ranges:Vec<_>=bounds.windows(2).filter(|p|p[1]>p[0]).map(|p|(p[0],p[1])).collect();
        let selected=ranges.iter().position(|&(x,y)| x<=t && t<y);
        if let Some(child)=selected {out.push((here,child,ranges.iter().filter(|&&(x,_)|x<l).count()));}
        // 全subtreeをpreorderで数え、選択された枝だけを出力する。
        for (x,y) in ranges { if y-x>1 {visit(a,x,y,t,l,id,out);} }
    }
    let mut result=Vec::new(); visit(a,0,a,token,limit,&mut 0,&mut result); result
}
fn tree_validation(trees:&[Tree;2]) -> (u64,usize) {
    let mut checked=0;let mut depth=0;
    for tree in trees {
        for node in 0..tree.nodes.len() {assert_eq!(causal_class(0,tree,node),tree.classes[node]);}
        assert!(tree.path(0,0).is_err()); assert!(tree.path(0,tree.alphabet+1).is_err());
        for limit in 1..=tree.alphabet {
            assert!(tree.path(limit,limit).is_err());
            for token in 0..limit {
                let path=tree.path(token,limit).unwrap();
                assert_eq!(path,oracle_path(tree.alphabet,token,limit));
                assert_eq!(tree.inverse(&path,limit).unwrap(),token);
                let mut invalid=path.clone();invalid[0].2=0;assert!(tree.inverse(&invalid,limit).is_err());
                invalid[0].2=5;assert!(tree.inverse(&invalid,limit).is_err());
                depth=depth.max(path.len()); checked+=1;
            }
        }
    }
    (checked,depth)
}

// full区間のみに依存し、合法prefixと観測childはclassに含めない。
fn causal_class(component:usize,tree:&Tree,node:usize)->usize {
    let edges=&tree.nodes[node].edges;let lo=edges.first().unwrap().lo;let hi=edges.last().unwrap().hi;
    component*3+if node==0 {0}else if (lo==4 || lo==32) && hi==tree.alphabet {1}else {2}
}
fn oracle_classes(alphabet:usize)->Vec<usize> {
    fn walk(a:usize,left:usize,right:usize,out:&mut Vec<usize>) {
        out.push(if left==0 {0}else if right==a && [4,32].contains(&left) {1}else {2});
        let boundaries=if left==0 {vec![0,1,2,4,a]}else if left==4 && right==a {vec![4,8,16,32,a]}else if left==32 && right==a {vec![32,64,128,256,a]}else {
            let n=(right-left).min(4);(0..=n).map(|j|left+(right-left)*j/n).collect()
        };
        for pair in boundaries.windows(2) {if pair[1]>pair[0]+1 {walk(a,pair[0],pair[1],out);}}
    }
    let mut result=Vec::new();walk(alphabet,0,alphabet,&mut result);result
}

fn row_ids(component:usize,context:usize,node:usize,symbol:usize,recent:u32,prev:(usize,usize)) -> Result<[usize;4],&'static str> {
    if component>1 || context>8 || (component==0 && context!=0) || node>=256 || symbol>=257 || recent>65535 || prev.0>8 || prev.1>31 {return Err("context");}
    let key=((component as u32)<<31)|((context as u32)<<20)|node as u32;
    let mask=(1<<18)-1;
    Ok([(component*9+context)*256+node,
        hash(key^(symbol as u32).wrapping_mul(0x9e3779b9))&mask,
        hash(key^recent.rotate_left(11))&mask,
        hash(key^(symbol as u32).wrapping_mul(0x85ebca6b)^((prev.0 as u32)<<24)^((prev.1 as u32)<<16))&mask])
}
fn oracle_ids(component:usize,context:usize,node:usize,symbol:usize,recent:u32,prev:(usize,usize))->[usize;4] {
    let scramble=|mut v:u32|{v=(v^(v/65536)).wrapping_mul(0x7feb352d);v=(v^(v/32768)).wrapping_mul(0x846ca68b);(v^(v/65536)) as usize%262144};
    let base=(component as u32)*2147483648+(context as u32)*1048576+node as u32;
    [component*2304+context*256+node,scramble(base^(symbol as u32).wrapping_mul(2654435769)),
        scramble(base^((recent<<11)|(recent>>21))),
        scramble(base^(symbol as u32).wrapping_mul(2246822507)^((prev.0 as u32)*16777216)^((prev.1 as u32)*65536))]
}
#[derive(Clone,Copy)]
struct Counts { values:[u16;4],total:u32 }
impl Counts {
    fn new()->Self {Self {values:[1;4],total:4}}
    fn probability(&self,child:usize,prefix:usize)->Result<f64,&'static str> {
        if prefix==0 || prefix>4 || child>=prefix {return Err("prefix");}
        Ok(f64::from(self.values[child])/self.values[..prefix].iter().map(|&c|f64::from(c)).sum::<f64>())
    }
    fn update(&mut self,child:usize)->bool {
        self.values[child]+=2;self.total+=2;
        if self.total>=32768 {self.total=0;for c in &mut self.values {*c=(*c+1)/2;self.total+=u32::from(*c);} true} else {false}
    }
}
const UNIFORM: f64 = 1.0/4096.0;
const RATE: f64 = 1.0/256.0;
const NUMERIC_TOLERANCE: f64 = 2e-10;
const FD_STEP: f64 = 1e-5;
const FD_TOLERANCE: f64 = 2e-6;
const SCALE:u64=4294967296;
type R<T>=std::result::Result<T,&'static str>;
fn divrem(n:u128,d:u128)->R<(u128,u128)> {if d==0 {Err("oracle zero divisor")}else {Ok((n/d,n%d))}}
fn long_divrem(n:u128,d:u128)->R<(u128,u128)> {
    if d==0 {return Err("oracle zero divisor");}
    let mut quotient=0u128;let mut remainder=0u128;
    for bit in (0..128).rev() {
        let carry=remainder>>(127)!=0;
        remainder=(remainder<<1)|((n>>bit)&1);
        if carry || remainder>=d {remainder=remainder.wrapping_sub(d);quotient|=1u128<<bit;}
    }
    assert!(remainder<d);assert_eq!(quotient.checked_mul(d).and_then(|v|v.checked_add(remainder)),Some(n));
    Ok((quotient,remainder))
}
fn normalize_reference(mass:[u128;4],prefix:usize)->R<[u64;4]> {
    if !(1..=4).contains(&prefix) {return Err("oracle prefix");}
    let denominator=mass[..prefix].iter().try_fold(0u128,|sum,&v|sum.checked_add(v).ok_or("oracle sum overflow"))?;
    if denominator==0 {return Err("oracle zero total");}
    let mut q=[0u64;4];let mut residue=[0u128;4];let mut allocated=0;
    for child in 0..prefix {
        let numerator=mass[child].checked_mul(u128::from(SCALE)).ok_or("oracle product overflow")?;
        let (value,rest)=divrem(numerator,denominator)?;q[child]=u64::try_from(value).map_err(|_|"oracle conversion")?;
        residue[child]=rest;allocated+=q[child];
    }
    let extra=(SCALE-allocated) as usize;if extra>=prefix {return Err("oracle remainder count");}
    // sortを呼ばず、余りが先行するchildの個数で各childの順位を決める。
    for child in 0..prefix {
        let rank=(0..prefix).filter(|&other|residue[other]>residue[child] || (residue[other]==residue[child] && other<child)).count();
        if rank<extra {q[child]+=1;}
    }assert_eq!(q.iter().sum::<u64>(),SCALE);Ok(q)
}
fn half_kt(half:[u64;4],prefix:usize)->[u64;4] {
    assert!((1..=4).contains(&prefix));
    normalize_reference(half.map(u128::from),prefix).unwrap()
}
fn independent_path(mut history:u64)->[usize;LEVELS] {
    let mut indexes=[0;LEVELS];let mut parent=0u64;
    for entry in indexes.iter_mut().skip(1) {parent=parent*4+history%4+1;*entry=parent as usize;history/=4;}
    indexes
}
fn mixture_reference(weight:u64,own:[u64;4],child:[u64;4],prefix:usize)->([u64;4],[u128;4]) {
    let mut own_mass=[0u128;4];
    for j in 0..prefix {own_mass[j]=u128::from(own[j])*u128::from(weight)+u128::from(child[j])*u128::from(SCALE-weight);}
    assert_eq!(own_mass.iter().sum::<u128>(),u128::from(SCALE)*u128::from(SCALE));
    (normalize_reference(own_mass,prefix).unwrap(),own_mass)
}
fn switch_reference(weight:u64,own:u64,child:u64,after:u32)->(u64,u64,u64) {
    let retained_own=u128::from(own)*u128::from(weight);let childmass=u128::from(child)*u128::from(SCALE-weight);
    let post=divrem(retained_own*u128::from(SCALE),retained_own+childmass).unwrap().0 as u64;
    let alpha=divrem(u128::from(SCALE),u128::from(after)+1).unwrap().0 as u64;
    // 一つの分子へalphaを持ち上げた別更新式。
    let numerator=u128::from(alpha)*u128::from(SCALE)+u128::from(SCALE-2*alpha)*u128::from(post);
    let next=divrem(numerator,u128::from(SCALE)).unwrap().0 as u64;
    assert!(post<=SCALE && next>=alpha && next<=SCALE-alpha);(post,alpha,next)
}
#[derive(Clone)]
struct ReferencePrediction {
    class:usize,prefix:usize,ids:[usize;LEVELS],history:u64,seen:u64,
    halves:[[u64;4];LEVELS],weights:[u64;LEVELS],kt:[[u64;4];LEVELS],mixed:[[u64;4];LEVELS],masses:[[u128;4];LEVELS],
}
fn recursive_reference(kt:&[[u64;4];LEVELS],weights:&[u64;LEVELS],prefix:usize,level:usize,depth:usize,mixed:&mut [[u64;4];LEVELS],masses:&mut [[u128;4];LEVELS])->[u64;4] {
    let value=if level==depth {kt[level]}else {
        let child=recursive_reference(kt,weights,prefix,level+1,depth,mixed,masses);
        let (value,raw)=mixture_reference(weights[level],kt[level],child,prefix);masses[level]=raw;value
    };mixed[level]=value;value
}
struct Reference {
    halves:Vec<[u64;4]>,weights:Vec<u64>,histories:[u64;CLASSES],seen:[u64;CLASSES],
}
impl Reference {
    fn new()->Self {Self{halves:vec![[1;4];CLASSES*NODES],weights:vec![SCALE/2;CLASSES*NODES],histories:[0;CLASSES],seen:[0;CLASSES]}}
    fn predict(&self,class:usize,prefix:usize)->ReferencePrediction {
        let ids=independent_path(self.histories[class]);
        let mut halves=[[0;4];LEVELS];let mut weights=[0;LEVELS];let mut kt=[[0;4];LEVELS];
        for level in 0..LEVELS {
            halves[level]=self.halves[class*NODES+ids[level]];weights[level]=self.weights[class*NODES+ids[level]];
            kt[level]=half_kt(halves[level],prefix);
        }
        let mut mixed=[[0;4];LEVELS];let mut masses=[[0;4];LEVELS];
        recursive_reference(&kt,&weights,prefix,0,LEVELS-1,&mut mixed,&mut masses);
        ReferencePrediction{class,prefix,ids,history:self.histories[class],seen:self.seen[class],halves,weights,kt,mixed,masses}
    }
    fn observe(&mut self,s:&ReferencePrediction,child:usize) {
        assert!(child<s.prefix && s.seen<u64::from(CAP));assert_eq!(self.histories[s.class],s.history);assert_eq!(self.seen[s.class],s.seen);
        let after=(s.seen+1) as u32;let mut next=[SCALE/2;LEVELS];
        for level in 0..LEVELS-1 {next[level]=switch_reference(s.weights[level],s.kt[level][child],s.mixed[level+1][child],after).2;}
        for level in 0..LEVELS {
            let id=s.class*NODES+s.ids[level];assert_eq!(self.halves[id],s.halves[level]);assert_eq!(self.weights[id],s.weights[level]);
            self.halves[id][child]+=2;self.weights[id]=next[level];
        }
        self.histories[s.class]=(s.history*4+child as u64)%65536;self.seen[s.class]=u64::from(after);
    }
}
fn compare_snapshot(a:&Snapshot,b:&ReferencePrediction) {
    assert_eq!(a.class,b.class);assert_eq!(a.prefix,b.prefix);assert_eq!(a.ids,b.ids);assert_eq!(u64::from(a.history),b.history);assert_eq!(u64::from(a.observations),b.seen);
    for level in 0..LEVELS {
        assert_eq!(a.raw[level].map(|v|u64::from(v)*2+1),b.halves[level]);assert_eq!(a.weights[level],b.weights[level]);
        assert_eq!(a.kernel.kt[level],b.kt[level]);assert_eq!(a.kernel.mixed[level],b.mixed[level]);assert_eq!(a.kernel.masses[level],b.masses[level]);
    }
}

fn quotient(n:u128,d:u128,slow:bool)->u128 {if slow {long_divrem(n,d).unwrap().0}else {assert!(d!=0);n/d}}
fn signed_quotient(n:i128,d:i128,slow:bool)->i128 {
    assert!(d>0);let value=quotient(n.unsigned_abs(),d as u128,slow) as i128;if n<0 {-value}else {value}
}
struct ReferenceMath {l:Vec<u64>,e:Vec<u64>,counts:Vec<i64>}
impl ReferenceMath {
    fn new()->Self {
        let scale=1u128<<48;let mut l=Vec::with_capacity(4097);let mut e=Vec::with_capacity(4097);
        for index in 0..=4096u128 {
            let x=scale+quotient(index*scale,4096,true);
            let t=quotient((x-scale)*scale,x+scale,true);let square=quotient(t*t,scale,true);
            let mut power=t;let mut sum=0;
            for odd in (1..=35u128).step_by(2) {sum+=quotient(power,odd,true);power=quotient(power*square,scale,true);}
            l.push((sum+sum) as u64);
        }
        let logarithm=u128::from(l[4096]);
        for index in 0..=4096u128 {
            let x=quotient(index*logarithm,4096,true);let mut term=scale;let mut sum=scale;
            for degree in 1..=24u128 {term=quotient(term*x,degree*scale,true);sum+=term;}
            e.push(quotient(scale*scale,sum,true) as u64);
        }
        let mut result=Self{l,e,counts:vec![0;32769]};
        for n in 1..=32768u64 {result.counts[n as usize]=result.ln(n,0,true);}
        result
    }
    fn ln(&self,n:u64,bits:i64,slow:bool)->i64 {
        assert!(n>=1 && n<=SCALE && [0,32].contains(&bits));
        let mut exponent=0i64;let mut base=1u64;while base<=n/2 {base*=2;exponent+=1;}
        let position=u128::from(n-base)*4096;let (index,rem)=if slow {long_divrem(position,u128::from(base)).unwrap()}else {(position/u128::from(base),position%u128::from(base))};
        let index=index as usize;let difference=u128::from(self.l[index+1]-self.l[index]);
        let mant=u128::from(self.l[index])+quotient(difference*rem,u128::from(base),slow);
        signed_quotient(mant as i128+i128::from(exponent-bits)*i128::from(self.l[4096]),65536,slow) as i64
    }
    fn exp(&self,d:i64,slow:bool)->u64 {
        assert!(d>=0 && d<=128*SCALE as i64);
        let mag=d as u128*65536;let ln2=u128::from(self.l[4096]);
        let (shift,rem)=if slow {long_divrem(mag,ln2).unwrap()}else {(mag/ln2,mag%ln2)};
        if shift>=32 {return 0;}
        let position=rem*4096;let (index,residue)=if slow {long_divrem(position,ln2).unwrap()}else {(position/ln2,position%ln2)};
        let i=index as usize;let correction=quotient(u128::from(self.e[i]-self.e[i+1])*residue,ln2,slow);
        ((u128::from(self.e[i])-correction)/(1u128<<(16+shift as u32))) as u64
    }
}
fn apportion_reference(mass:[u128;4],prefix:usize,target:u64,slow:bool)->[u64;4] {
    assert!((1..=4).contains(&prefix));let denominator=mass[..prefix].iter().sum::<u128>();assert!(denominator>0);
    let mut base=[0u64;4];let mut remainder=[0u128;4];
    for child in 0..prefix {
        let product=mass[child]*u128::from(target);
        let (q,r)=if slow {long_divrem(product,denominator).unwrap()}else {(product/denominator,product%denominator)};
        base[child]=q as u64;remainder[child]=r;
    }
    let missing=(target-base.iter().sum::<u64>()) as usize;assert!(missing<prefix);
    for child in 0..prefix {
        let preceding=(0..prefix).filter(|&other|remainder[other]>remainder[child] || (remainder[other]==remainder[child] && other<child)).count();
        if preceding<missing {base[child]+=1;}
    }base
}
struct ReferencePool {
    features:[[i64;4];5],scores:[i64;4],q:[u64;4],p:[u64;4],frequencies:[u32;4],cumulative:[u32;5],
    factor:u64,expected:[i64;5],gradient:[i64;5],delta:[i64;5],next:[u64;5],
}
fn reference_pool(math:&ReferenceMath,counts:[[u32;4];4],weights:[u64;5],cts:[u64;4],prefix:usize,child:usize,slow:bool)->ReferencePool {
    assert!(child<prefix && prefix<=4);
    let mut features=[[0i64;4];5];let mut accum=[0i128;4];
    for i in 0..5 {
        for j in 0..prefix {
            features[i][j]=if i<4 {math.counts[counts[i][j] as usize]}else {math.ln(cts[j],32,slow)};
            accum[j]+=i128::from(features[i][j])*i128::from(weights[i]);
        }
    }
    let mut scores=[0;4];for j in 0..prefix {scores[j]=signed_quotient(accum[j],i128::from(SCALE),slow) as i64;}
    let maximum=*scores[..prefix].iter().max().unwrap();let mut mass=[0u128;4];
    for j in 0..prefix {mass[j]=u128::from(math.exp(maximum-scores[j],slow));}
    let q=apportion_reference(mass,prefix,SCALE,slow);
    for j in 0..prefix {mass[j]=u128::from(SCALE)+u128::from(q[j])*(prefix as u128*4095);}
    let p=apportion_reference(mass,prefix,SCALE,slow);
    let frequency=apportion_reference(p.map(u128::from),prefix,32768,slow);
    let frequencies=frequency.map(|v|v as u32);let mut cumulative=[0u32;5];
    for end in 1..=4 {cumulative[end]=frequency[..end].iter().sum::<u64>() as u32;}
    let observed=u128::from(q[child])*4095*prefix as u128;
    let factor=quotient(observed*u128::from(SCALE),observed+u128::from(SCALE),slow) as u64;
    let mut expected=[0;5];let mut gradient=[0;5];let mut delta=[0;5];let mut next=[0;5];
    for i in 0..5 {
        let average=(0..prefix).map(|j|i128::from(features[i][j])*i128::from(q[j])).sum::<i128>();
        expected[i]=signed_quotient(average,i128::from(SCALE),slow) as i64;
        gradient[i]=signed_quotient(i128::from(features[i][child]-expected[i])*i128::from(factor),i128::from(SCALE),slow) as i64;
        delta[i]=signed_quotient(i128::from(gradient[i]),256,slow) as i64;
        let proposed=i128::from(weights[i])+i128::from(delta[i]);
        next[i]=if proposed<0 {0}else if proposed>2*i128::from(SCALE) {2*SCALE}else {proposed as u64};
    }
    ReferencePool{features,scores,q,p,frequencies,cumulative,factor,expected,gradient,delta,next}
}
fn compare_pool(a:&integer_pool::Prediction,u:&integer_pool::Update,b:&ReferencePool) {
    assert_eq!(a.features,b.features);assert_eq!(a.scores,b.scores);assert_eq!(a.q,b.q);assert_eq!(a.p,b.p);
    assert_eq!(a.frequencies,b.frequencies);assert_eq!(a.cumulative,b.cumulative);
    assert_eq!(u.factor,b.factor);assert_eq!(u.expected,b.expected);assert_eq!(u.gradient,b.gradient);assert_eq!(u.delta,b.delta);assert_eq!(u.next,b.next);
}
struct RealPrediction {q:[f64;4],p:[f64;4],gradient:[f64;5]}
fn ideal_pool(counts:[[u16;4];4],weights:[f64;5],cts:[u64;4],prefix:usize,child:usize)->RealPrediction {
    let mut features=[[0.0;4];5];
    for j in 0..prefix {for i in 0..4 {features[i][j]=f64::from(counts[i][j]).ln();}features[4][j]=(cts[j] as f64/Q as f64).ln();}
    let mut scores=[0.0;4];for j in 0..prefix {scores[j]=(0..5).map(|i|weights[i]*features[i][j]).sum();}
    let maximum=scores[..prefix].iter().copied().fold(f64::NEG_INFINITY,f64::max);
    let mut q=[0.0;4];for j in 0..prefix {q[j]=(scores[j]-maximum).exp();}
    let sum=q[..prefix].iter().sum::<f64>();for v in &mut q[..prefix] {*v/=sum;}
    let mut p=[0.0;4];for j in 0..prefix {p[j]=(4095.0*q[j]+1.0/prefix as f64)/4096.0;}
    let factor=4095.0*q[child]/(4096.0*p[child]);
    let gradient=std::array::from_fn(|i|factor*(features[i][child]-(0..prefix).map(|j|q[j]*features[i][j]).sum::<f64>()));
    RealPrediction{q,p,gradient}
}
#[derive(Default)]
struct LocalAudit {max_q:f64,max_q_bound_ratio:f64,max_p:f64,max_gradient:f64,max_next:f64,predictions:u64}
impl LocalAudit {
    fn compare(&mut self,counts:[[u16;4];4],cts:[u64;4],s:&integer_pool::Prediction,u:&integer_pool::Update,child:usize) {
        let weights=s.weights.map(|v|v as f64/Q as f64);let real=ideal_pool(counts,weights,cts,s.prefix,child);
        for j in 0..s.prefix {
            let error=(s.q[j] as f64/Q as f64-real.q[j]).abs();let bound=1e-6*real.q[j]+8.0/Q as f64;
            assert!(error<=bound,"q local error {error} {bound}");self.max_q=self.max_q.max(error);self.max_q_bound_ratio=self.max_q_bound_ratio.max(error/bound);
            let error=(s.p[j] as f64/Q as f64-real.p[j]).abs();assert!(error<=2e-6);self.max_p=self.max_p.max(error);
        }
        for i in 0..5 {
            let error=(u.gradient[i] as f64/Q as f64-real.gradient[i]).abs();assert!(error<=2e-3,"gradient local error {error}");self.max_gradient=self.max_gradient.max(error);
            let real_next=(weights[i]+real.gradient[i]/256.0).clamp(0.0,2.0);
            let error=(u.next[i] as f64/Q as f64-real_next).abs();assert!(error<=1e-5,"next local error {error}");self.max_next=self.max_next.max(error);
        }self.predictions+=1;
    }
}
fn math_validation(math:&Math,reference:&ReferenceMath)->(u64,u64,u64,u64,u64,f64,f64) {
    assert_eq!(math.l().len(),reference.l.len());assert_eq!(math.e().len(),reference.e.len());assert_eq!(math.counts().len(),reference.counts.len());
    for i in 0..4097 {assert_eq!(math.l()[i],reference.l[i],"L index {i}");assert_eq!(math.e()[i],reference.e[i],"E index {i}");}
    for i in 0..32769 {assert_eq!(math.counts()[i],reference.counts[i],"count ln index {i}");}
    assert_eq!(math.l()[4096],195103586505154);assert_eq!(math.e()[2048],199032864766437);
    let mut count=0;let mut boundary=0;let mut grid=0;let mut exp=0;let mut max_ln=0.0f64;let mut max_exp=0.0f64;
    for n in 1..=32768u64 {
        let actual=math.ln_count(n).unwrap();assert_eq!(actual,reference.ln(n,0,true));let error=(actual as f64/Q as f64-(n as f64).ln()).abs();assert!(error<=2e-8);max_ln=max_ln.max(error);count+=1;
    }
    for exponent in 0..=32 {
        for offset in [-1i64,0,1] {
            let value=(1i64<<exponent)+offset;if value<1 || value>Q as i64 {continue;}
            let n=value as u64;let actual=math.ln_cts(n).unwrap();assert_eq!(actual,reference.ln(n,32,true));
            let error=(actual as f64/Q as f64-(n as f64/Q as f64).ln()).abs();assert!(error<=2e-8);max_ln=max_ln.max(error);boundary+=1;
        }
    }
    for exponent in 12..=32u32 {for index in 0..=4096u64 {
        let base=1u64<<exponent;let n=base+base*index/4096;if n>Q {continue;}
        let actual=math.ln_cts(n).unwrap();assert_eq!(actual,reference.ln(n,32,true));
        let error=(actual as f64/Q as f64-(n as f64/Q as f64).ln()).abs();assert!(error<=2e-8);max_ln=max_ln.max(error);grid+=1;
    }}
    let mut previous=Q;
    for index in 0..=32768u64 {
        let d=(index*Q/256) as i64;let actual=math.exp_neg(d).unwrap();assert_eq!(actual,reference.exp(d,true));assert!(actual<=previous);previous=actual;
        let error=(actual as f64/Q as f64-(-(d as f64/Q as f64)).exp()).abs();assert!(error<=2e-8);max_exp=max_exp.max(error);exp+=1;
    }
    for d in [0,128*Q as i64,EXP_CUTOFF-1,EXP_CUTOFF,EXP_CUTOFF+1] {assert_eq!(math.exp_neg(d).unwrap(),reference.exp(d,true));}
    assert!(math.exp_neg(EXP_CUTOFF-1).unwrap()>0);assert_eq!(math.exp_neg(EXP_CUTOFF).unwrap(),0);assert_eq!(math.exp_neg(0).unwrap(),Q);
    let excess=(EXP_CUTOFF as i128*65536)-32*i128::from(fixed_math::LN2);assert_eq!(excess,51136);assert!(excess>32*145);
    let before=((EXP_CUTOFF-1) as i128*65536)-32*i128::from(fixed_math::LN2);assert_eq!(before,-14400);
    let mut invalid=0;
    for (n,bits) in [(0,0),(Q+1,0),(1,31)] {assert!(math.ln_scaled(n,bits).is_err());invalid+=1;}
    for n in [0,32769] {assert!(math.ln_count(n).is_err());invalid+=1;}
    for n in [0,Q+1] {assert!(math.ln_cts(n).is_err());invalid+=1;}
    for d in [-1,128*Q as i64+1] {assert!(math.exp_neg(d).is_err());invalid+=1;}
    for result in [fixed_math::mul(u128::MAX,2),fixed_math::add(u128::MAX,1),fixed_math::div(1,0)] {assert!(result.is_err());invalid+=1;}
    for result in [fixed_math::smul(i128::MAX,2),fixed_math::sadd(i128::MAX,1),fixed_math::sdiv(i128::MIN,-1)] {assert!(result.is_err());invalid+=1;}
    assert_eq!(fixed_math::sdiv(-5,2).unwrap(),-2);assert_eq!(count+boundary+grid,114806);assert_eq!(boundary,97);assert_eq!(grid,81941);assert_eq!(exp,32769);assert_eq!(invalid,15);
    (count,boundary,grid,exp,invalid,max_ln,max_exp)
}
fn pool_validation(math:&Math,reference:&ReferenceMath)->(u64,u64,u64,LocalAudit) {
    let counts=[[1,23,7,5],[8,1,37,2],[31,13,1,9],[3,17,5,41]];let raw=[7u128,31,2,11];let interior=[13*Q/100,7*Q/10,14*Q/10,3*Q/10,61*Q/100];
    let mut predictions=0;let mut fd=0;let mut edge=0;let mut local=LocalAudit::default();
    for prefix in 1..=4 {
        let cts=integer_cts::normalize(raw,prefix).unwrap();let octs=apportion_reference(raw,prefix,SCALE,true);assert_eq!(cts,octs);
        let s=integer_pool::predict(math,counts,interior,cts,prefix).unwrap();
        for child in 0..prefix {
            let u=integer_pool::observe(&s,child).unwrap();let b=reference_pool(reference,counts.map(|r|r.map(u32::from)),interior,octs,prefix,child,true);
            compare_pool(&s,&u,&b);local.compare(counts,cts,&s,&u,child);predictions+=1;
            let w=interior.map(|v|v as f64/Q as f64);let ideal=ideal_pool(counts,w,cts,prefix,child);
            for i in 0..5 {
                let mut plus=w;let mut minus=w;plus[i]+=1e-5;minus[i]-=1e-5;
                let difference=(ideal_pool(counts,plus,cts,prefix,child).p[child].ln()-ideal_pool(counts,minus,cts,prefix,child).p[child].ln())/2e-5;
                assert!((difference-ideal.gradient[i]).abs()<=2e-6);fd+=1;
            }
        }
        for weights in [[0;5],[2*Q;5],[Q/4,Q/4,Q/4,Q/4,0]] {
            for variant in 0..8 {
                let mut changed=counts;let mut c=cts;
                match variant {
                    0=>changed=[[1;4];4],
                    1..=4=>{changed[variant-1][0]=30000;},
                    5=>c=integer_cts::normalize([1,1,1,u128::from(Q)],prefix).unwrap(),
                    6=>c=integer_cts::normalize([u128::from(Q),1,1,1],prefix).unwrap(),
                    _=>{},
                }
                let s=integer_pool::predict(math,changed,weights,c,prefix).unwrap();
                for child in 0..prefix {
                    let u=integer_pool::observe(&s,child).unwrap();let b=reference_pool(reference,changed.map(|r|r.map(u32::from)),weights,c,prefix,child,true);
                    compare_pool(&s,&u,&b);local.compare(changed,c,&s,&u,child);edge+=1;
                    if prefix==1 {assert_eq!(s.q,[Q,0,0,0]);assert_eq!(s.p,s.q);assert_eq!(u.gradient,[0;5]);assert_eq!(u.next,weights);}
                }
            }
        }
    }
    // 親BigInt fixture。
    let cts=integer_cts::normalize(raw,4).unwrap();assert_eq!(cts,[589505315,2610666396,168430090,926365495]);
    let weights=[Q/4,Q/4,Q/4,Q/4,0];let s=integer_pool::predict(math,counts,weights,cts,4).unwrap();let u=integer_pool::observe(&s,1).unwrap();
    assert_eq!(s.scores,[7099625000,9162944343,7694719498,8819051486]);assert_eq!(s.q,[816896114,1320698313,938298535,1219074334]);
    assert_eq!(s.p,[816958821,1320638021,938331602,1219038852]);assert_eq!(s.frequencies,[6233,10076,7159,9300]);
    assert_eq!(u.gradient,[5536834830,-5930627186,2144632635,1491736668,5049401124]);assert_eq!(u.next,[1095370085,1050575312,1082119295,1079568920,19724223]);assert!(u.next[4]>0);
    compare_pool(&s,&u,&reference_pool(reference,counts.map(|r|r.map(u32::from)),weights,cts,4,1,true));local.compare(counts,cts,&s,&u,1);
    let negative=integer_pool::observe(&integer_pool::predict(math,counts,weights,cts,4).unwrap(),2).unwrap();assert!(negative.gradient[4]<0);assert_eq!(negative.next[4],0);
    compare_pool(&s,&negative,&reference_pool(reference,counts.map(|r|r.map(u32::from)),weights,cts,4,2,true));local.compare(counts,cts,&s,&negative,2);
    let uniform=integer_pool::predict(math,[[1;4];4],[0;5],integer_cts::normalize([1;4],4).unwrap(),4).unwrap();assert_eq!(uniform.p,[Q/4;4]);assert_eq!(uniform.frequencies,[8192;4]);
    let uniform_update=integer_pool::observe(&uniform,0).unwrap();compare_pool(&uniform,&uniform_update,&reference_pool(reference,[[1;4];4],[0;5],[Q/4;4],4,0,true));local.compare([[1;4];4],[Q/4;4],&uniform,&uniform_update,0);
    let rare=integer_pool::predict(math,[[1,32765,1,1];4],[2*Q;5],[1,Q-3,1,1],4).unwrap();assert_eq!(rare.q[0],0);assert!(rare.frequencies.iter().all(|&v|v>=2));
    for child in 0..4 {
        let update=integer_pool::observe(&rare,child).unwrap();
        let oracle=reference_pool(reference,[[1,32765,1,1];4],[2*Q;5],[1,Q-3,1,1],4,child,true);
        compare_pool(&rare,&update,&oracle);local.compare([[1,32765,1,1];4],[1,Q-3,1,1],&rare,&update,child);edge+=1;
        if rare.q[child]==0 {assert_eq!(update.factor,0);assert_eq!(update.gradient,[0;5]);assert_eq!(update.next,[2*Q;5]);}
    }
    let snapshot=s.clone();
    for prefix in [0,5] {assert!(integer_pool::predict(math,counts,weights,cts,prefix).is_err());}
    for changed in [[[0;4];4],[[32768;4];4]] {assert!(integer_pool::predict(math,changed,weights,cts,4).is_err());}
    assert!(integer_pool::predict(math,counts,[2*Q+1;5],cts,4).is_err());assert!(integer_pool::predict(math,counts,weights,[0;4],4).is_err());assert!(integer_pool::predict(math,counts,weights,[Q,1,0,0],1).is_err());
    assert!(integer_pool::observe(&s,4).is_err());assert_eq!(s,snapshot);
    assert_eq!(predictions,10);assert_eq!(fd,50);assert_eq!(edge,244);assert_eq!(local.predictions,257);
    (predictions,fd,edge,local)
}

struct Model {
    tables:[Vec<Counts>;4],weights:Vec<[u64;5]>,reference:[Vec<[u32;4]>;4],reference_weights:Vec<[u64;5]>,
    math:Math,reference_math:ReferenceMath,cts:Cts,oracle_cts:Reference,local:LocalAudit,
    rescales:[u64;4],checked:u64,cold:[u64;4],state_digest:u64,gradients_checked:u64,clamp_counts:[u64;2],
    cts_queries:[[u64;LEVELS];CLASSES],cts_cold:[[u64;LEVELS];CLASSES],cts_class_loss:[Sum;CLASSES],
}
impl Model {
    fn new()->Self {
        Self{
            tables:std::array::from_fn(|i|vec![Counts::new();if i==0 {4608}else {1<<18}]),
            weights:vec![[Q/4,Q/4,Q/4,Q/4,0];4608],
            reference:std::array::from_fn(|i|vec![[1;4];if i==0 {4608}else {1<<18}]),
            reference_weights:vec![[SCALE/4,SCALE/4,SCALE/4,SCALE/4,0];4608],
            math:Math::new().unwrap(),reference_math:ReferenceMath::new(),cts:Cts::new().unwrap(),oracle_cts:Reference::new(),local:LocalAudit::default(),
            rescales:[0;4],checked:0,cold:[0;4],state_digest:0xcbf29ce484222325,gradients_checked:0,clamp_counts:[0;2],
            cts_queries:[[0;LEVELS];CLASSES],cts_cold:[[0;LEVELS];CLASSES],cts_class_loss:[Sum::default();CLASSES],
        }
    }
    fn branch(&mut self,ids:[usize;4],class:usize,child:usize,prefix:usize)->R<[f64;7]> {
        if class>=CLASSES || !(1..=4).contains(&prefix) || child>=prefix || (0..4).any(|i|ids[i]>=self.tables[i].len()) {return Err("branch input");}
        let snapshot=self.cts.predict(class,prefix)?;
        if snapshot.observations>=CAP || snapshot.raw.iter().any(|r|r.iter().map(|&v|u64::from(v)).sum::<u64>()>=u64::from(CAP)) {return Err("branch CTS cap");}
        let os=self.oracle_cts.predict(class,prefix);compare_snapshot(&snapshot,&os);
        let cts=snapshot.kernel.mixed[0];let octs=os.mixed[0];
        let mut p=[0.0;4];let mut counts=[[0u16;4];4];let mut reference_counts=[[0u32;4];4];
        for i in 0..4 {
            let c=self.tables[i][ids[i]];counts[i]=c.values;reference_counts[i]=self.reference[i][ids[i]];
            assert_eq!(c.values.map(u32::from),reference_counts[i]);assert_eq!(c.total,c.values.iter().map(|&v|u32::from(v)).sum::<u32>());
            p[i]=c.probability(child,prefix)?;close(p[i],f64::from(reference_counts[i][child])/f64::from(reference_counts[i][..prefix].iter().sum::<u32>()));
        }
        let s=integer_pool::predict(&self.math,counts,self.weights[ids[0]],cts,prefix)?;
        let u=integer_pool::observe(&s,child)?;
        let o=reference_pool(&self.reference_math,reference_counts,self.reference_weights[ids[0]],octs,prefix,child,false);
        compare_pool(&s,&u,&o);self.local.compare(counts,cts,&s,&u,child);
        // 全次weightを同snapshotからprepareした後に同時commit、CTS/basetableへ続く。
        self.weights[ids[0]]=u.next;self.reference_weights[ids[0]]=o.next;
        self.cts.observe(&snapshot,child)?;self.oracle_cts.observe(&os,child);
        for level in 0..LEVELS {
            self.cts_queries[class][level]+=1;self.cts_cold[class][level]+=u64::from(snapshot.raw[level].iter().all(|&v|v==0));
            let node=self.cts.nodes()[class*NODES+snapshot.ids[level]];
            assert_eq!(node.raw.map(|v|u64::from(v)*2+1),self.oracle_cts.halves[class*NODES+os.ids[level]]);
            assert_eq!(node.weight,self.oracle_cts.weights[class*NODES+os.ids[level]]);
        }
        assert_eq!(u64::from(self.cts.histories()[class]),self.oracle_cts.histories[class]);assert_eq!(u64::from(self.cts.observations()[class]),self.oracle_cts.seen[class]);
        for i in 0..5 {
            let proposed=i128::from(s.weights[i])+i128::from(u.delta[i]);self.clamp_counts[0]+=u64::from(proposed<0);self.clamp_counts[1]+=u64::from(proposed>2*i128::from(Q));
        }self.gradients_checked+=5;
        for i in 0..4 {
            if self.tables[i][ids[i]].total==4 {self.cold[i]+=1;}
            let rescaled=self.tables[i][ids[i]].update(child);self.rescales[i]+=u64::from(rescaled);
            let r=&mut self.reference[i][ids[i]];r[child]+=2;let expected_rescale=r.iter().sum::<u32>()>=32768;
            if expected_rescale {for v in r.iter_mut(){*v=(*v>>1)+(*v&1);}}
            assert_eq!(rescaled,expected_rescale);assert_eq!(self.tables[i][ids[i]].values.map(u32::from),*r);
        }
        self.checked+=1;let mut losses=[0.0;7];
        losses[0]=-(f64::from(s.frequencies[child])/32768.0).log2();
        for i in 0..4 {losses[i+1]=-p[i].log2();}
        losses[5]=-(cts[child] as f64/Q as f64).log2();losses[6]=-(s.p[child] as f64/Q as f64).log2();
        self.cts_class_loss[class].add(losses[5]);Ok(losses)
    }
    fn finish(&mut self)->u64 {
        let mut base=0;
        for i in 0..4 {for (c,r) in self.tables[i].iter().zip(&self.reference[i]) {
            assert_eq!(c.values.map(u32::from),*r);assert_eq!(c.total,r.iter().sum::<u32>());
            for &v in r {digest(&mut self.state_digest,v as usize);base+=1;}
        }}
        for (w,r) in self.weights.iter().zip(&self.reference_weights) {for i in 0..5 {
            assert_eq!(w[i],r[i]);assert!(w[i]<=2*Q);digest(&mut self.state_digest,w[i] as usize);base+=1;
        }}
        assert_eq!(base,3187200);let mut cts_values=0;
        assert_eq!(self.cts.nodes().len(),self.oracle_cts.halves.len());assert_eq!(self.cts.nodes().len(),self.oracle_cts.weights.len());
        for (id,node) in self.cts.nodes().iter().enumerate() {
            for j in 0..4 {assert_eq!(u64::from(node.raw[j])*2+1,self.oracle_cts.halves[id][j]);cts_values+=1;}
            assert_eq!(node.weight,self.oracle_cts.weights[id]);cts_values+=1;
        }
        for c in 0..CLASSES {assert_eq!(u64::from(self.cts.histories()[c]),self.oracle_cts.histories[c]);assert_eq!(u64::from(self.cts.observations()[c]),self.oracle_cts.seen[c]);cts_values+=2;}
        assert_eq!(cts_values,(self.cts.nodes().len()*5+2*self.cts.histories().len()) as u64);assert_eq!(cts_values,2621442);
        assert_eq!(base+cts_values,5808642);base+cts_values
    }
    fn rejected_branch_validation(&mut self) {
        let before_cts=self.cts.clone();let before_weights=self.weights.clone();let before_reference=self.reference_weights.clone();
        let before_reference_counts=self.reference.clone();let before_oracle_half=self.oracle_cts.halves.clone();let before_oracle_weights=self.oracle_cts.weights.clone();
        let before_oracle_history=self.oracle_cts.histories;let before_oracle_seen=self.oracle_cts.seen;
        let before_stats=(self.rescales,self.cold,self.state_digest,self.clamp_counts,self.cts_queries,self.cts_cold,self.local.predictions);
        let before_local=(self.local.max_q.to_bits(),self.local.max_q_bound_ratio.to_bits(),self.local.max_p.to_bits(),self.local.max_gradient.to_bits(),self.local.max_next.to_bits());
        let before_class_loss=self.cts_class_loss.map(|s|(s.value.to_bits(),s.correction.to_bits()));
        let before_counts:Vec<_>=self.tables.iter().map(|t|t.iter().map(|c|(c.values,c.total)).collect::<Vec<_>>()).collect();
        let before_checked=self.checked;let before_gradients=self.gradients_checked;
        for (ids,class,child,prefix) in [([0;4],6,0,4),([0;4],0,0,0),([0;4],0,0,5),([0;4],0,4,4),([usize::MAX;4],0,0,4)] {
            assert!(self.branch(ids,class,child,prefix).is_err());
            assert_eq!(self.cts.histories(),before_cts.histories());assert_eq!(self.cts.observations(),before_cts.observations());
            for (a,b) in self.cts.nodes().iter().zip(before_cts.nodes()) {assert_eq!(a,b);}
            for (current,before) in self.weights.iter().zip(&before_weights) {assert_eq!(current,before);}
            for (current,before) in self.reference_weights.iter().zip(&before_reference) {assert_eq!(current,before);}
            for i in 0..4 {
                for (c,&expected) in self.tables[i].iter().zip(&before_counts[i]) {assert_eq!((c.values,c.total),expected);}
                for (current,before) in self.reference[i].iter().zip(&before_reference_counts[i]) {assert_eq!(current,before);}
            }
            for (current,before) in self.oracle_cts.halves.iter().zip(&before_oracle_half) {assert_eq!(current,before);}
            for (current,before) in self.oracle_cts.weights.iter().zip(&before_oracle_weights) {assert_eq!(current,before);}
            assert_eq!(self.oracle_cts.histories,before_oracle_history);assert_eq!(self.oracle_cts.seen,before_oracle_seen);
            assert_eq!((self.rescales,self.cold,self.state_digest,self.clamp_counts,self.cts_queries,self.cts_cold,self.local.predictions),before_stats);
            assert_eq!((self.local.max_q.to_bits(),self.local.max_q_bound_ratio.to_bits(),self.local.max_p.to_bits(),self.local.max_gradient.to_bits(),self.local.max_next.to_bits()),before_local);
            assert_eq!(self.cts_class_loss.map(|s|(s.value.to_bits(),s.correction.to_bits())),before_class_loss);
            assert_eq!(self.checked,before_checked);assert_eq!(self.gradients_checked,before_gradients);
        }
    }
}

fn primitive_validation() {
    let c=Counts::new(); close(c.probability(0,1).unwrap(),1.0);close(c.probability(3,4).unwrap(),0.25);
    assert!(c.probability(0,0).is_err());assert!(c.probability(0,5).is_err());assert!(c.probability(1,1).is_err());
    let mut c=Counts{values:[32763,1,1,1],total:32766};assert!(c.update(3));assert_eq!(c.values,[16382,1,1,2]);assert_eq!(c.total,16386);
    assert_eq!(row_ids(0,0,255,256,65535,(8,31)).unwrap()[0],255);
    assert_eq!(row_ids(1,8,255,256,65535,(8,31)).unwrap()[0],4607);
    assert!(row_ids(1,9,0,0,0,(0,0)).is_err());assert!(row_ids(0,8,0,0,0,(0,0)).is_err());assert!(row_ids(0,0,256,0,0,(0,0)).is_err());
    for (component,context) in [(0,0),(1,0),(1,8)] {for node in [0,255] {
        assert_eq!(row_ids(component,context,node,256,65535,(8,31)).unwrap(),oracle_ids(component,context,node,256,65535,(8,31)));
    }}
}
#[derive(Clone,Copy)]
struct Run {symbol:usize,length:usize,next:usize}
struct Audit {bits:[[Sum;7];2],all_bits:[Sum;7],old:[Sum;2],tokens:[u64;2],branches:[u64;2],prefixes:[[u64;4];2],max_depth:[usize;2],grammar:[u64;2],old_checked:u64}
impl Audit {
    fn token(&mut self,component:usize,key:usize,token:usize,limit:usize,context:usize,symbol:usize,recent:u32,prev:(usize,usize),tree:&Tree,model:&mut Model,old:&mut original::ContextModel) {
        for value in [component,key,token,limit] {digest(&mut self.grammar[0],value);}
        let interval=old.interval(key,token,limit).unwrap();
        let root=old.audit_counts(None).unwrap(); let local=old.audit_counts(Some(key)).unwrap();
        let sum=|values:&[u16],n:usize|values[..n].iter().map(|&v|u32::from(v)).sum::<u32>();
        assert_eq!(interval,(sum(root,token)+4*sum(local,token),u32::from(root[token])+4*u32::from(local[token]),sum(root,limit)+4*sum(local,limit)));
        self.old[component].add((f64::from(interval.2)/f64::from(interval.1)).log2());old.update(key,token).unwrap();self.old_checked+=1;
        let path=tree.path(token,limit).unwrap();self.max_depth[component]=self.max_depth[component].max(path.len());
        for &(node,child,prefix) in &path {
            let ids=row_ids(component,context,node,symbol,recent,prev).unwrap();
            assert_eq!(ids,oracle_ids(component,context,node,symbol,recent,prev));
            let class=causal_class(component,tree,node);assert_eq!(class,component*3+tree.classes[node]);
            let losses=model.branch(ids,class,child,prefix).unwrap();
            for i in 0..7 {self.bits[component][i].add(losses[i]);self.all_bits[i].add(losses[i]);}
            self.branches[component]+=1;self.prefixes[component][prefix-1]+=1;
        }
        self.tokens[component]+=1;
    }
}
fn run(path:&std::path::Path) {
    let trees=[Tree::new(257),Tree::new(256)];let (tree_cases,tree_depth)=tree_validation(&trees);primitive_validation();
    let mut model=Model::new();
    let (count_ln_cases,cts_ln_boundary_cases,cts_ln_grid_cases,exp_cases,math_invalid_cases,max_ln_error,max_exp_error)=math_validation(&model.math,&model.reference_math);
    let (synthetic_predictions,finite_differences,pool_edge_predictions,synthetic_local)=pool_validation(&model.math,&model.reference_math);
    model.rejected_branch_validation();
    let file=std::fs::File::open(path).unwrap();assert_eq!(file.metadata().unwrap().len(),2811006);
    let mut input=Vec::new();file.take(2811007).read_to_end(&mut input).unwrap();assert_eq!(input.len(),2811006);
    let (last,primary)=bwt::bwt(&input).unwrap();assert_eq!(primary,1762795);assert_eq!(last.len(),2811007);
    let mut runs:Vec<Run>=Vec::new();
    for &symbol in &last {if let Some(r)=runs.last_mut().filter(|r|r.symbol==symbol as usize){r.length+=1;}else {runs.push(Run{symbol:symbol as usize,length:1,next:usize::MAX});}}
    assert_eq!(runs.len(),889227);
    let mut next=[usize::MAX;257];for (index,r) in runs.iter_mut().enumerate().rev(){r.next=next[r.symbol];next[r.symbol]=index;}
    let mut active=Vec::new();let mut positions:Vec<Vec<usize>>=(0..257).map(|_|Vec::new()).collect();
    for (index,r) in runs.iter().enumerate(){if !active.contains(&r.symbol){active.push(r.symbol);}positions[r.symbol].push(index);}
    assert_eq!(active.len(),257);let mut cursor=[0usize;257];
    let mut previous_rank=[0usize;257];let mut previous=[(0usize,0usize);257];let mut recent=0u32;
    let mut oracle_rank=[0usize;257];let mut oracle_previous=[(0usize,0usize);257];let mut oracle_recent=0u32;
    let mut old=[original::ContextModel::new(257,257*4).unwrap(),original::ContextModel::new(256,257*9).unwrap()];
    let mut audit=Audit{bits:[[Sum::default();7];2],all_bits:[Sum::default();7],old:[Sum::default();2],tokens:[0;2],branches:[0;2],prefixes:[[0;4];2],max_depth:[0;2],grammar:[0xcbf29ce484222325;2],old_checked:0};
    let mut consumed=0usize;let mut escape=0usize;
    for (index,r) in runs.iter().enumerate() {
        assert_eq!(previous_rank,oracle_rank);assert_eq!(previous,oracle_previous);assert_eq!(recent,oracle_recent);
        assert_eq!(active.first(),Some(&r.symbol));assert_eq!(next[r.symbol],index);let symbol=active.remove(0);next[symbol]=r.next;
        let rank=if r.next==usize::MAX {0}else{active.iter().position(|&s|next[s]>r.next).unwrap_or(active.len())};
        let before_next=|s:usize|positions[s].get(cursor[s]).copied().unwrap_or(usize::MAX);
        assert_eq!(before_next(symbol),index);
        let oracle_limit=(0..257).filter(|&s|before_next(s)!=usize::MAX).count();
        let oracle_next=positions[symbol].get(cursor[symbol]+1).copied().unwrap_or(usize::MAX);
        let oracle_rank_value=if oracle_next==usize::MAX {0}else{(0..257).filter(|&s|s!=symbol && before_next(s)<oracle_next).count()};
        assert_eq!(r.next,oracle_next);assert_eq!(rank,oracle_rank_value);assert_eq!(active.len()+1,oracle_limit);
        if rank!=0 {assert!(rank>0 && rank<=active.len());}
        let rank_key=symbol*4+previous_rank[symbol].min(3);let oracle_key=symbol*4+oracle_rank[symbol].min(3);
        for value in [0,oracle_key,oracle_rank_value,oracle_limit] {digest(&mut audit.grammar[1],value);}
        audit.token(0,rank_key,rank,active.len()+1,0,symbol,recent,previous[symbol],&trees[0],&mut model,&mut old[0]);
        // rankは既知だが、recent/previousはrunが完了するまで更新しない。
        assert_eq!(previous,oracle_previous);assert_eq!(recent,oracle_recent);
        let context=exponent(rank+1);let length_token=(r.length-1).min(255);let length_limit=(last.len()-consumed).min(256);
        let oracle_context=if oracle_rank_value+1==0 {0}else{((oracle_rank_value+1) as f64).log2().floor() as usize};
        assert_eq!(context,oracle_context);
        for value in [1,symbol*9+oracle_context,length_token,length_limit] {digest(&mut audit.grammar[1],value);}
        audit.token(1,symbol*9+context,length_token,length_limit,context,symbol,recent,previous[symbol],&trees[1],&mut model,&mut old[1]);
        if r.length>=256 {let mut v=r.length-256;loop{escape+=1;v>>=7;if v==0{break;}}}
        consumed+=r.length;
        previous_rank[symbol]=rank;previous[symbol]=(exponent(rank.saturating_sub(1)),exponent(r.length-1));
        let class=match r.length{1=>0,2=>1,3..=4=>2,_=>3};recent=((recent<<4)|(rank.min(3) as u32)|class<<2)&0xffff;
        oracle_rank[symbol]=oracle_rank_value;
        let exp_oracle=|mut v:usize|{let mut e=0;while v>1{v/=2;e+=1;}e};
        oracle_previous[symbol]=(exp_oracle(oracle_rank_value.saturating_sub(1)),exp_oracle(r.length-1));
        oracle_recent=((oracle_recent*16)+oracle_rank_value.min(3) as u32+4*class)%65536;
        cursor[symbol]+=1;if rank!=0 {active.insert(rank,symbol);}
    }
    assert_eq!(previous_rank,oracle_rank);assert_eq!(previous,oracle_previous);assert_eq!(recent,oracle_recent);
    assert!(active.is_empty());assert_eq!(consumed,last.len());assert_eq!(escape,742);assert_eq!(audit.tokens,[889227;2]);assert_eq!(audit.grammar[0],audit.grammar[1]);
    assert_eq!(model.checked,3825340);assert_eq!(audit.branches,[2725772,1099568]);
    assert_eq!(model.cts.observations(),[889227,620240,1216305,889227,64372,145969]);
    assert_eq!(model.gradients_checked,19126700);assert_eq!(model.local.predictions,model.checked);
    let state_values=model.finish();let mut total=Sum::default();
    for c in 0..2 {total.add(audit.bits[c][0].value);assert_eq!(audit.prefixes[c].iter().sum::<u64>(),audit.branches[c]);}
    for i in 0..7 {assert!((audit.bits[0][i].value+audit.bits[1][i].value-audit.all_bits[i].value).abs()<0.0001);}
    let projected=total.value+escape as f64*8.0;let budget=3866504;let gate=projected<budget as f64;
    let projected_p=audit.all_bits[6].value+escape as f64*8.0;
    let old_total=audit.old[0].value+audit.old[1].value;assert!((old_total-4597717.435179456).abs()<0.0001);
    assert_eq!(audit.grammar,[0x58735a2b7383d755;2]);
    let cts_total=model.cts_class_loss.iter().map(|s|s.value).sum::<f64>();assert!((cts_total-audit.all_bits[5].value).abs()<0.0001);
    print!("{{\"status\":\"passed\",\"diagnostic_only\":true,\"integer_pool_verified\":true,\"wire_size_speed_verified\":false,\"full_benchmark_allowed\":false,\"f64_continuous_trajectory_verified\":false,\"gate_basis\":\"CDF entropy plus common escape\",\"Q\":{Q},\"ln_cases\":{},\"count_ln_cases\":{count_ln_cases},\"cts_ln_boundary_cases\":{cts_ln_boundary_cases},\"cts_ln_grid_cases\":{cts_ln_grid_cases},\"exp_cases\":{exp_cases},\"ln_lut_values\":4097,\"exp_lut_values\":4097,\"exp_additional_cases\":5,\"math_invalid_cases\":{math_invalid_cases},\"synthetic_predictions\":{synthetic_predictions},\"finite_differences\":{finite_differences},\"pool_edge_predictions\":{pool_edge_predictions},\"bigint_pool_fixtures\":1,\"pool_dedicated_fixture_predictions\":3,\"pool_invalid_cases\":8,\"branch_rejection_cases\":5,\"small_oracle_division\":\"128-step binary long division for math and pool primitives only\",\"full_oracle_division\":\"native u128 with independent formulas and ranking\",\"cts_oracle_division\":\"native u128; prior primitive has separate long-division proof\",\"max_local_ln_error\":{max_ln_error},\"max_local_exp_error\":{max_exp_error},",count_ln_cases+cts_ln_boundary_cases+cts_ln_grid_cases);
    print!("\"synthetic_local_predictions\":{},\"synthetic_max_q_error\":{},\"synthetic_max_P_error\":{},\"synthetic_max_gradient_error\":{},\"synthetic_max_next_weight_error\":{},",synthetic_local.predictions,synthetic_local.max_q,synthetic_local.max_p,synthetic_local.max_gradient,synthetic_local.max_next);
    print!("\"local_predictions\":{},\"max_q_error\":{},\"max_q_error_bound_ratio\":{},\"max_P_error\":{},\"max_gradient_error\":{},\"max_next_weight_error\":{},\"local_ln_exp_bound\":2e-8,\"local_q_relative_bound\":1e-6,\"local_q_absolute_bound\":{},\"local_P_bound\":2e-6,\"local_gradient_bound\":2e-3,\"local_next_weight_bound\":1e-5,\"legacy_f64_tolerance\":2e-10,\"finite_difference_step\":1e-5,\"finite_difference_tolerance\":2e-6,",model.local.predictions,model.local.max_q,model.local.max_q_bound_ratio,model.local.max_p,model.local.max_gradient,model.local.max_next,8.0/Q as f64);
    print!("\"runs\":{},\"alphabet\":257,\"primary\":{primary},\"rank_tokens\":{},\"length_tokens\":{},\"rank_oracle_checked\":{},\"tree_cases\":{tree_cases},\"tree_nodes\":[{},{}],\"tree_max_depth\":{tree_depth},\"grammar_digests\":[\"{:016x}\",\"{:016x}\"],\"branches\":{:?},\"max_depth\":{:?},\"prefix_counts\":{:?},\"branches_oracle_checked\":{},\"gradients_checked\":{},\"clamp_counts\":{:?},\"state_values_checked\":{state_values},\"base_state_values_checked\":3187200,\"cts_state_values_checked\":2621442,\"state_digest\":\"{:016x}\",\"rescales\":{:?},\"cold_expert_branches\":{:?},",runs.len(),audit.tokens[0],audit.tokens[1],runs.len(),trees[0].nodes.len(),trees[1].nodes.len(),audit.grammar[0],audit.grammar[1],audit.branches,audit.max_depth,audit.prefixes,model.checked,model.gradients_checked,model.clamp_counts,model.state_digest,model.rescales,model.cold);
    println!("\"cts_class_observations\":{:?},\"cts_class_loss_bits\":{:?},\"cts_node_queries\":{:?},\"cts_cold_node_queries\":{:?},\"escape_bytes\":{escape},\"escape_bits\":{},\"bits\":[{:?},{:?}],\"old_bits\":[{:.9},{:.9}],\"old_intervals_checked\":{},\"cdf_entropy_bits\":{:.9},\"P_entropy_bits\":{:.9},\"projected_CDF_entropy_escape_bits\":{projected:.9},\"projected_P_entropy_escape_bits\":{projected_p:.9},\"payload_budget_bits\":{budget},\"opportunity_gate\":{gate},\"unverified_integer_range_frame_performance\":true}}",model.cts.observations(),model.cts_class_loss.map(|s|s.value),model.cts_queries,model.cts_cold,escape*8,audit.bits[0].map(|s|s.value),audit.bits[1].map(|s|s.value),audit.old[0].value,audit.old[1].value,audit.old_checked,total.value,audit.all_bits[6].value);
}
fn main() {
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=2 {eprintln!("usage: opportunity fixed-input");std::process::exit(2);}
    run(std::path::Path::new(&args[1]));
}

