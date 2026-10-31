#![allow(dead_code)]
#[path = "../causal-bayes-sais/bwt.rs"] mod bwt;
#[path = "../direct-token/cdf_model.rs"] mod original;
use std::io::Read;
const CHILDREN: usize = 4;
const EXPERTS: usize = 5;
const LOSSES: usize = EXPERTS + 1;
const INITIAL_WEIGHTS: [f64;EXPERTS] = [0.25,0.25,0.25,0.25,0.0];

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
struct Tree { alphabet: usize, nodes: Vec<Node> }
impl Tree {
    fn new(alphabet: usize) -> Self {
        assert!([256,257].contains(&alphabet));
        let mut tree = Self { alphabet, nodes: Vec::new() };
        assert_eq!(tree.build(0,alphabet),0); assert!(tree.nodes.len()<256); tree
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
fn row_ids(component:usize,context:usize,node:usize,symbol:usize,recent:u32,prev:(usize,usize)) -> Result<[usize;EXPERTS],&'static str> {
    if component>1 || context>8 || (component==0 && context!=0) || node>=256 || symbol>=257 || recent>65535 || prev.0>8 || prev.1>31 {return Err("context");}
    let key=((component as u32)<<31)|((context as u32)<<20)|node as u32;
    let mask=(1<<18)-1;
    Ok([(component*9+context)*256+node,
        hash(key^(symbol as u32).wrapping_mul(0x9e3779b9))&mask,
        hash(key^recent.rotate_left(11))&mask,
        hash(key^(symbol as u32).wrapping_mul(0x85ebca6b)^((prev.0 as u32)<<24)^((prev.1 as u32)<<16))&mask,
        hash(key^(symbol as u32).wrapping_mul(0xc2b2ae35)^recent.rotate_left(7))&mask])
}
fn oracle_ids(component:usize,context:usize,node:usize,symbol:usize,recent:u32,prev:(usize,usize))->[usize;EXPERTS] {
    let scramble=|mut v:u32|{v=(v^(v/65536)).wrapping_mul(0x7feb352d);v=(v^(v/32768)).wrapping_mul(0x846ca68b);(v^(v/65536)) as usize%262144};
    let base=(component as u32)*2147483648+(context as u32)*1048576+node as u32;
    [component*2304+context*256+node,scramble(base^(symbol as u32).wrapping_mul(2654435769)),
        scramble(base^((recent<<11)|(recent>>21))),
        scramble(base^(symbol as u32).wrapping_mul(2246822507)^((prev.0 as u32)*16777216)^((prev.1 as u32)*65536)),
        scramble(base^(symbol as u32).wrapping_mul(3266489909)^((recent<<7)|(recent>>25)))]
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
struct Prediction { probability:f64, gradient:[f64;EXPERTS], q:[f64;4] }
fn pool(counts:[[u16;CHILDREN];EXPERTS], weights:[f64;EXPERTS],child:usize,prefix:usize)->Prediction {
    assert!((1..=4).contains(&prefix) && child<prefix);
    assert!(weights.iter().all(|&w|w.is_finite() && (0.0..=2.0).contains(&w)));
    let features=counts.map(|c|c.map(|v|{assert!(v>0);f64::from(v).ln()}));
    let mut scores=[0.0;CHILDREN];
    for j in 0..prefix {for i in 0..EXPERTS {scores[j]+=weights[i]*features[i][j];}}
    let max=scores[..prefix].iter().copied().fold(f64::NEG_INFINITY,f64::max);
    let mut q=[0.0;CHILDREN];let mut total=0.0;
    for j in 0..prefix {q[j]=(scores[j]-max).exp();total+=q[j];}
    for value in &mut q[..prefix] {*value/=total;}
    let probability=(1.0-UNIFORM)*q[child]+UNIFORM/prefix as f64;
    assert!(probability.is_finite() && probability>0.0 && probability<=1.0+1e-14);
    let factor=(1.0-UNIFORM)*q[child]/probability;
    let mut gradient=[0.0;EXPERTS];
    for i in 0..EXPERTS {
        let expected=(0..prefix).map(|j|q[j]*features[i][j]).sum::<f64>();
        gradient[i]=factor*(features[i][child]-expected);
        assert!(gradient[i].is_finite());
    }
    close(q[..prefix].iter().sum(),1.0);
    Prediction{probability,gradient,q}
}
// 別count/weight snapshotからnormalized ln(prob)・通常exp/sumで計算する。
fn oracle_pool(counts:[[u32;CHILDREN];EXPERTS],weights:[f64;EXPERTS],child:usize,prefix:usize)->Prediction {
    let mut ln_prob=[[0.0;CHILDREN];EXPERTS];
    for i in 0..EXPERTS {
        let total=counts[i][..prefix].iter().sum::<u32>();
        for j in 0..prefix {ln_prob[i][j]=(f64::from(counts[i][j])/f64::from(total)).ln();}
    }
    let mut unnormalized=[0.0;CHILDREN];
    for j in 0..prefix {
        let score=weights[0]*ln_prob[0][j]+weights[1]*ln_prob[1][j]+weights[2]*ln_prob[2][j]+weights[3]*ln_prob[3][j]+weights[4]*ln_prob[4][j];
        unnormalized[j]=score.exp();
    }
    let denominator=unnormalized[..prefix].iter().sum::<f64>();
    assert!(denominator.is_finite() && denominator>0.0);
    let q=unnormalized.map(|v|v/denominator);
    let probability=(4095.0*q[child]+1.0/prefix as f64)/4096.0;
    let gradient=std::array::from_fn(|i|{
        let mut expected=0.0;
        for j in 0..prefix {expected+=q[j]*ln_prob[i][j];}
        (q[child]*4095.0/(probability*4096.0))*(ln_prob[i][child]-expected)
    });
    Prediction{probability,gradient,q}
}
fn compare_predictions(a:&Prediction,b:&Prediction,prefix:usize) {
    close(a.probability,b.probability);
    close(-a.probability.log2(),-b.probability.log2());
    for i in 0..EXPERTS {close(a.gradient[i],b.gradient[i]);}
    for j in 0..prefix {close(a.q[j],b.q[j]);}
}
fn pool_validation()->(u64,u64) {
    let counts=[[1,23,7,5],[8,1,37,2],[31,13,1,9],[3,17,5,41],[19,2,47,11]];
    let weights=[0.13,0.7,1.4,0.3,0.6];
    let mut predictions=0;let mut differences=0;
    for prefix in 1..=4 {for child in 0..prefix {
        let prediction=pool(counts,weights,child,prefix);
        let oracle=oracle_pool(counts.map(|c|c.map(u32::from)),weights,child,prefix);
        compare_predictions(&prediction,&oracle,prefix);predictions+=1;
        for i in 0..EXPERTS {
            let mut plus=weights;let mut minus=weights;
            plus[i]+=FD_STEP;minus[i]-=FD_STEP;
            let fd=(pool(counts,plus,child,prefix).probability.ln()-pool(counts,minus,child,prefix).probability.ln())/(2.0*FD_STEP);
            assert!((fd-prediction.gradient[i]).abs()<=FD_TOLERANCE,"finite difference {fd} {}",prediction.gradient[i]);
            differences+=1;
        }
    }}
    for prefix in 1..=4 {for child in 0..prefix {
        let uniform=pool([[1;CHILDREN];EXPERTS],weights,child,prefix);
        close(uniform.probability,1.0/prefix as f64);
        for g in uniform.gradient {close(g,0.0);}
        let zero=pool(counts,[0.0;EXPERTS],child,prefix);close(zero.probability,1.0/prefix as f64);
    }}
    let forced=pool(counts,weights,0,1);
    close(forced.probability,1.0);
    for i in 0..EXPERTS {close(forced.gradient[i],0.0);close((weights[i]+RATE*forced.gradient[i]).clamp(0.0,2.0),weights[i]);}
    let asymmetric=[[1,10,1,1];EXPERTS];
    let low=pool(asymmetric,[0.0;EXPERTS],0,2);let low_oracle=oracle_pool(asymmetric.map(|c|c.map(u32::from)),[0.0;EXPERTS],0,2);
    compare_predictions(&low,&low_oracle,2);assert!(low.gradient[0]<0.0);assert_eq!((RATE*low.gradient[0]).clamp(0.0,2.0),0.0);
    let high=pool(asymmetric,[2.0;EXPERTS],1,2);let high_oracle=oracle_pool(asymmetric.map(|c|c.map(u32::from)),[2.0;EXPERTS],1,2);
    compare_predictions(&high,&high_oracle,2);assert!(high.gradient[0]>0.0);assert_eq!((2.0+RATE*high.gradient[0]).clamp(0.0,2.0),2.0);
    // 第五expertだけが非一様。初期0から正学習と負clampを独立照合する。
    let mut new_counts=[[1;CHILDREN];EXPERTS];new_counts[4]=[10,1,1,1];
    let positive=pool(new_counts,INITIAL_WEIGHTS,0,2);let negative=pool(new_counts,INITIAL_WEIGHTS,1,2);
    compare_predictions(&positive,&oracle_pool(new_counts.map(|c|c.map(u32::from)),INITIAL_WEIGHTS,0,2),2);
    compare_predictions(&negative,&oracle_pool(new_counts.map(|c|c.map(u32::from)),INITIAL_WEIGHTS,1,2),2);
    assert!(positive.gradient[4]>0.0 && RATE*positive.gradient[4]>0.0);
    assert!(negative.gradient[4]<0.0);assert_eq!((RATE*negative.gradient[4]).clamp(0.0,2.0),0.0);
    close(positive.probability,0.5);close(positive.gradient[4],(4095.0/4096.0)*10.0f64.ln()/2.0);
    (predictions,differences)
}
struct Model {
    tables:[Vec<Counts>;EXPERTS], weights:Vec<[f64;EXPERTS]>,
    reference:[Vec<[u32;CHILDREN]>;EXPERTS], reference_weights:Vec<[f64;EXPERTS]>,
    rescales:[u64;EXPERTS], checked:u64,cold:[u64;EXPERTS],state_digest:u64,
    gradients_checked:u64,clamp_counts:[u64;2],max_probability_error:f64,max_gradient_error:f64,max_weight_error:f64,
}
impl Model {
    fn new()->Self {Self { tables:std::array::from_fn(|i|vec![Counts::new();if i==0 {4608}else {1<<18}]),
        weights:vec![INITIAL_WEIGHTS;4608], reference:std::array::from_fn(|i|vec![[1;4];if i==0 {4608}else {1<<18}]),
        reference_weights:vec![INITIAL_WEIGHTS;4608],rescales:[0;EXPERTS],checked:0,cold:[0;EXPERTS],state_digest:0xcbf29ce484222325,
        gradients_checked:0,clamp_counts:[0;2],max_probability_error:0.0,max_gradient_error:0.0,max_weight_error:0.0}}
    fn branch(&mut self,ids:[usize;EXPERTS],child:usize,prefix:usize)->[f64;LOSSES] {
        let mut p=[0.0;EXPERTS];let mut counts=[[0u16;CHILDREN];EXPERTS];let mut reference_counts=[[0u32;CHILDREN];EXPERTS];
        for i in 0..EXPERTS {
            let c=self.tables[i][ids[i]];counts[i]=c.values;reference_counts[i]=self.reference[i][ids[i]];
            assert_eq!(c.values.map(u32::from),reference_counts[i]);
            assert_eq!(c.total,c.values.iter().map(|&x|u32::from(x)).sum::<u32>());
            if c.total==4 {self.cold[i]+=1;}
            p[i]=c.probability(child,prefix).unwrap();
            close(p[i],f64::from(reference_counts[i][child])/f64::from(reference_counts[i][..prefix].iter().sum::<u32>()));
        }
        let w=self.weights[ids[0]];let ow=self.reference_weights[ids[0]];
        let prediction=pool(counts,w,child,prefix);let oracle=oracle_pool(reference_counts,ow,child,prefix);
        compare_predictions(&prediction,&oracle,prefix);
        self.max_probability_error=self.max_probability_error.max((prediction.probability-oracle.probability).abs());
        // 全gradientを同じquery snapshotから計算してからcommitする。
        let updated=std::array::from_fn::<_,EXPERTS,_>(|i|(w[i]+RATE*prediction.gradient[i]).clamp(0.0,2.0));
        let reference_updated=std::array::from_fn::<_,EXPERTS,_>(|i|{
            let proposed=ow[i]+oracle.gradient[i]/256.0;
            if proposed<0.0 {0.0}else if proposed>2.0 {2.0}else {proposed}
        });
        for i in 0..EXPERTS {
            self.max_gradient_error=self.max_gradient_error.max((prediction.gradient[i]-oracle.gradient[i]).abs());
            self.max_weight_error=self.max_weight_error.max((updated[i]-reference_updated[i]).abs());
            close(updated[i],reference_updated[i]);
            let proposed=w[i]+RATE*prediction.gradient[i];
            self.clamp_counts[0]+=u64::from(proposed<0.0);self.clamp_counts[1]+=u64::from(proposed>2.0);
        }
        self.weights[ids[0]]=updated;self.reference_weights[ids[0]]=reference_updated;
        self.gradients_checked+=EXPERTS as u64;
        for i in 0..EXPERTS {
            let rescaled=self.tables[i][ids[i]].update(child);self.rescales[i]+=u64::from(rescaled);
            let r=&mut self.reference[i][ids[i]];r[child]+=2;
            let oracle_rescale=r.iter().sum::<u32>()>=32768;
            if oracle_rescale {for c in r.iter_mut(){*c=(*c>>1)+(*c&1);}}
            assert_eq!(rescaled,oracle_rescale);assert_eq!(self.tables[i][ids[i]].values.map(u32::from),*r);
        }
        self.checked+=1;
        let mut losses=[0.0;LOSSES];losses[0]=-prediction.probability.log2();for i in 0..EXPERTS {losses[i+1]=-p[i].log2();} losses
    }
    fn finish(&mut self)->u64 {
        let mut values=0;
        for i in 0..EXPERTS {for (c,r) in self.tables[i].iter().zip(&self.reference[i]) {
            assert_eq!(c.values.map(u32::from),*r);assert_eq!(c.total,r.iter().sum::<u32>());
            for &v in r {digest(&mut self.state_digest,v as usize);values+=1;}
        }}
        for (w,r) in self.weights.iter().zip(&self.reference_weights) {for i in 0..EXPERTS {
            assert!(w[i].is_finite() && (0.0..=2.0).contains(&w[i]));close(w[i],r[i]);
            digest(&mut self.state_digest,w[i].to_bits() as usize);values+=1;
        }}
        let shape_values=self.tables.iter().map(|t|t.len()*CHILDREN).sum::<usize>()+self.weights.len()*EXPERTS;
        assert_eq!(values,shape_values as u64);assert_eq!(values,4235776);
        values
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
    // 非対称count/重みとprefix1..4を別式で検証する。
    let mut model=Model::new();
    for prefix in 1..=4 {for child in 0..prefix {model.branch([0,0,0,0,0],child,prefix);}}
    for i in 0..EXPERTS {model.tables[i][0]=Counts{values:[32763,1,1,1],total:32766};model.reference[i][0]=[32763,1,1,1];}
    model.branch([0,0,0,0,0],3,4);assert_eq!(model.rescales,[1;EXPERTS]);
    model.finish();
}
fn hash_collision_validation() -> [usize;3] {
    let mut seen=vec![usize::MAX;1<<18];let mut collision=None;
    for recent in 0..=65535 {
        let ids=row_ids(0,0,0,17,recent,(0,0)).unwrap();
        assert_eq!(ids,oracle_ids(0,0,0,17,recent,(0,0)));
        if seen[ids[4]]!=usize::MAX {collision=Some((seen[ids[4]] as u32,recent));break;}
        seen[ids[4]]=recent as usize;
    }
    let (first,second)=collision.expect("bounded collision");assert_ne!(first,second);
    let first_ids=row_ids(0,0,0,17,first,(0,0)).unwrap();
    let second_ids=row_ids(0,0,0,17,second,(0,0)).unwrap();assert_eq!(first_ids[4],second_ids[4]);
    let mut model=Model::new();assert_eq!(model.weights[0],INITIAL_WEIGHTS);
    model.branch(first_ids,0,4);
    assert_eq!(model.tables[4][second_ids[4]].values,[3,1,1,1]);
    model.branch(second_ids,1,4);
    assert_eq!(model.tables[4][first_ids[4]].values,[3,3,1,1]);
    assert_eq!(model.reference[4][first_ids[4]],[3,3,1,1]);model.finish();
    for invalid in [(0,0,256,0,0),(1,9,0,0,0),(0,1,0,0,0),(0,0,0,257,0),(0,0,0,0,65536)] {
        assert!(row_ids(invalid.0,invalid.1,invalid.2,invalid.3,invalid.4,(0,0)).is_err());
    }
    [first as usize,second as usize,first_ids[4]]
}
#[derive(Clone,Copy)]
struct Run {symbol:usize,length:usize,next:usize}
struct Audit {bits:[[Sum;LOSSES];2],all_bits:[Sum;LOSSES],old:[Sum;2],tokens:[u64;2],branches:[u64;2],prefixes:[[u64;4];2],max_depth:[usize;2],grammar:[u64;2],old_checked:u64}
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
            let losses=model.branch(ids,child,prefix);
            for i in 0..LOSSES {self.bits[component][i].add(losses[i]);self.all_bits[i].add(losses[i]);}
            self.branches[component]+=1;self.prefixes[component][prefix-1]+=1;
        }
        self.tokens[component]+=1;
    }
}
fn run(path:&std::path::Path) {
    let trees=[Tree::new(257),Tree::new(256)];let (tree_cases,tree_depth)=tree_validation(&trees);primitive_validation();let hash_collision=hash_collision_validation();let (synthetic_predictions,finite_differences)=pool_validation();
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
    let mut model=Model::new();let mut old=[original::ContextModel::new(257,257*4).unwrap(),original::ContextModel::new(256,257*9).unwrap()];
    let mut audit=Audit{bits:[[Sum::default();LOSSES];2],all_bits:[Sum::default();LOSSES],old:[Sum::default();2],tokens:[0;2],branches:[0;2],prefixes:[[0;4];2],max_depth:[0;2],grammar:[0xcbf29ce484222325;2],old_checked:0};
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
    let state_values=model.finish();let mut total=Sum::default();for c in 0..2 {total.add(audit.bits[c][0].value);assert_eq!(audit.prefixes[c].iter().sum::<u64>(),audit.branches[c]);}
    for i in 0..LOSSES {assert!((audit.bits[0][i].value+audit.bits[1][i].value-audit.all_bits[i].value).abs()<0.0001);}
    let projected=total.value+escape as f64*8.0;let budget=(483599-281-5)*8;let gate=projected<(budget as f64);
    let old_total=audit.old[0].value+audit.old[1].value;assert!((old_total-4597717.435179456).abs()<0.0001);
    println!("{{\"status\":\"passed\",\"diagnostic_only\":true,\"wire_size_speed_verified\":false,\"runs\":{},\"alphabet\":257,\"primary\":{primary},\"rank_tokens\":{},\"length_tokens\":{},\"rank_oracle_checked\":{},\"tree_cases\":{tree_cases},\"tree_nodes\":[{},{}],\"tree_max_depth\":{tree_depth},\"grammar_digests\":[\"{:016x}\",\"{:016x}\"],\"branches\":[{},{}],\"max_depth\":[{},{}],\"prefix_counts\":{:?},\"branches_oracle_checked\":{},\"expert_count\":{EXPERTS},\"child_count\":{CHILDREN},\"initial_weights\":{INITIAL_WEIGHTS:?},\"hash_collision\":{hash_collision:?},\"synthetic_predictions\":{synthetic_predictions},\"finite_differences\":{finite_differences},\"gradients_checked\":{},\"clamp_counts\":{:?},\"max_probability_error\":{},\"max_gradient_error\":{},\"max_weight_error\":{},\"numeric_tolerance\":{NUMERIC_TOLERANCE},\"finite_difference_step\":{FD_STEP},\"finite_difference_tolerance\":{FD_TOLERANCE},\"state_values_checked\":{state_values},\"state_digest\":\"{:016x}\",\"rescales\":{:?},\"cold_expert_branches\":{:?},\"escape_bytes\":{escape},\"escape_bits\":{},\"bits\":[{:?},{:?}],\"old_bits\":[{:.9},{:.9}],\"old_intervals_checked\":{},\"mixed_bits\":{:.9},\"projected_entropy_escape_bits\":{projected:.9},\"payload_budget_bits\":{budget},\"opportunity_gate\":{gate},\"full_benchmark_allowed\":false}}",runs.len(),audit.tokens[0],audit.tokens[1],runs.len(),trees[0].nodes.len(),trees[1].nodes.len(),audit.grammar[0],audit.grammar[1],audit.branches[0],audit.branches[1],audit.max_depth[0],audit.max_depth[1],audit.prefixes,model.checked,model.gradients_checked,model.clamp_counts,model.max_probability_error,model.max_gradient_error,model.max_weight_error,model.state_digest,model.rescales,model.cold,escape*8,audit.bits[0].map(|s|s.value),audit.bits[1].map(|s|s.value),audit.old[0].value,audit.old[1].value,audit.old_checked,total.value);
}
fn main() {
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=2 {eprintln!("usage: opportunity fixed-input");std::process::exit(2);}
    run(std::path::Path::new(&args[1]));
}

