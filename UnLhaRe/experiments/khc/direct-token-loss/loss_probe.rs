#![allow(dead_code)]
#[path = "../causal-bayes-sais/bwt.rs"] mod bwt;
#[path = "../direct-token/cdf_model.rs"] mod original;
#[path = "../direct-token-prior/cdf_model.rs"] mod p256;
#[path = "../direct-token-prior/prior_math.rs"] mod prior_math;
#[path = "../direct-token-dirichlet/cdf_model.rs"] mod dirichlet;
#[path = "../direct-token-dirichlet/mixture_math.rs"] mod mixture_math;
use std::io::Read;

#[derive(Clone, Copy, Default)]
struct Sum { value: f64, compensation: f64 }
impl Sum {
    fn add(&mut self, value: f64) {
        assert!(value.is_finite());
        let corrected = value - self.compensation;
        let updated = self.value + corrected;
        self.compensation = (updated - self.value) - corrected;
        self.value = updated;
    }
}
#[derive(Clone, Copy, Default)]
struct Cell { count: u64, bits: [Sum; 4] }
struct Models {
    old: original::ContextModel,
    p256: p256::ContextModel,
    new: dirichlet::ContextModel,
    keys: usize,
}
impl Models {
    fn new(alphabet: usize, keys: usize) -> Self {
        Self { old: original::ContextModel::new(alphabet, keys).unwrap(),
            p256: p256::ContextModel::new(alphabet, keys).unwrap(),
            new: dirichlet::ContextModel::new(alphabet, keys).unwrap(), keys }
    }
    fn compare_state(&self) -> u64 {
        let mut checked = 0;
        for key in std::iter::once(None).chain((0..self.keys).map(Some)) {
            let root = self.old.audit_counts(key).unwrap();
            assert_eq!(root, self.p256.audit_counts(key).unwrap());
            assert_eq!(root, self.new.audit_counts(key).unwrap());
            checked += 2 * root.len() as u64;
        }
        assert_eq!(self.old.audit_rescales(), self.p256.audit_rescales());
        assert_eq!(self.old.audit_rescales(), self.new.audit_rescales());
        checked
    }
    fn query(&mut self, key: usize, token: usize, limit: usize) -> (u32, [f64; 4], [(u32,u32,u32);3]) {
        let old = self.old.interval(key, token, limit).unwrap();
        let p256 = self.p256.interval(key, token, limit).unwrap();
        let new = self.new.prepare(key, limit).unwrap().interval(token).unwrap();
        let root = self.old.audit_counts(None).unwrap();
        let local = self.old.audit_counts(Some(key)).unwrap();
        let prefix = |values: &[u16], count: usize| values[..count].iter().map(|&v| u64::from(v)).sum::<u64>();
        let d = prefix(root, root.len());
        let t = prefix(local, local.len());
        let r = prefix(root, token);
        let l = prefix(local, token);
        let r_end = r + u64::from(root[token]);
        let l_end = l + u64::from(local[token]);
        let r_limit = prefix(root, limit);
        let l_limit = prefix(local, limit);
        assert_eq!(old, ((r + 4*l) as u32, (r_end-r+4*(l_end-l)) as u32, (r_limit+4*l_limit) as u32));
        let pc = |k: usize, r: u64, l: u64| k as u32 + 4*l as u32 + (256*u128::from(r)/u128::from(d)) as u32;
        assert_eq!(p256, (pc(token,r,l), pc(token+1,r_end,l_end)-pc(token,r,l), pc(limit,r_limit,l_limit)));
        let nc = |k: usize, r: u64, l: u64| k as u32 +
            (32768*(64*u128::from(r)+u128::from(d)*u128::from(l))/(u128::from(d)*(64+u128::from(t)))) as u32;
        assert_eq!(new, (nc(token,r,l),nc(token+1,r_end,l_end)-nc(token,r,l),nc(limit,r_limit,l_limit)));
        let ideal_numerator = 64 * (r_end-r) + d * (l_end-l);
        let ideal_denominator = 64 * r_limit + d * l_limit;
        assert!(ideal_numerator > 0 && ideal_numerator <= ideal_denominator);
        let loss = |numerator: u64, denominator: u64| {
            assert!(numerator > 0 && numerator <= denominator);
            (denominator as f64 / numerator as f64).log2()
        };
        let bits = [loss(u64::from(old.1), u64::from(old.2)), loss(ideal_numerator,ideal_denominator),
            loss(u64::from(p256.1),u64::from(p256.2)), loss(u64::from(new.1),u64::from(new.2))];
        self.old.update(key,token).unwrap();
        self.p256.update(key,token).unwrap();
        self.new.update(key,token).unwrap();
        (t as u32,bits,[old,p256,new])
    }
}
fn mix(hash: &mut u64, value: u64) { *hash = (*hash ^ value).wrapping_mul(0x100000001b3); }
fn bin(total: u32) -> usize {
    match total { 0=>0,1..=7=>1,8..=31=>2,32..=127=>3,128..=511=>4,512..=2047=>5,2048..=8191=>6,8192..=16383=>7,_=>panic!("local total") }
}
struct Audit {
    cells: [[Cell;8];2],
    totals: [Sum;4],
    tokens: [u64;2],
    integer_intervals: u64,
    fingerprint: u64,
}
impl Audit {
    fn token(&mut self, model: &mut Models, component: usize, key: usize, token: usize, limit: usize) {
        let (local_total,bits,intervals) = model.query(key,token,limit);
        let cell = &mut self.cells[component][bin(local_total)];
        cell.count += 1; self.tokens[component] += 1;
        for (i,value) in bits.into_iter().enumerate() { cell.bits[i].add(value); self.totals[i].add(value); }
        self.integer_intervals += 3;
        for value in [component as u64,key as u64,token as u64,limit as u64,u64::from(local_total)] { mix(&mut self.fingerprint,value); }
        for (c,f,t) in intervals { for value in [c,f,t] { mix(&mut self.fingerprint,u64::from(value)); } }
    }
}
#[derive(Clone,Copy)]
struct Run { symbol: u16, length: u32, next: u32 }
fn run(path: &std::path::Path) {
    let input_file = std::fs::File::open(path).unwrap();
    assert_eq!(input_file.metadata().unwrap().len(),2811006);
    let mut input = Vec::new(); input.try_reserve_exact(2811006).unwrap();
    input_file.take(2811007).read_to_end(&mut input).unwrap();
    assert_eq!(input.len(),2811006);
    let (last,primary) = bwt::bwt(&input).unwrap();
    assert_eq!(primary,1762795); assert_eq!(last.len(),2811007);
    let count = last.iter().enumerate().filter(|&(i,s)| i==0 || last[i-1]!=*s).count();
    assert_eq!(count,889227);
    let mut runs: Vec<Run> = Vec::new(); runs.try_reserve_exact(count).unwrap();
    for &symbol in &last {
        if let Some(run) = runs.last_mut().filter(|run|run.symbol==symbol) { run.length+=1; }
        else { runs.push(Run { symbol,length:1,next:u32::MAX }); }
    }
    let mut next = [u32::MAX;257];
    for (index,run) in runs.iter_mut().enumerate().rev() { run.next=next[usize::from(run.symbol)];next[usize::from(run.symbol)]=index as u32; }
    let mut alphabet=Vec::new();alphabet.try_reserve_exact(257).unwrap();
    for run in &runs { if !alphabet.contains(&run.symbol) { alphabet.push(run.symbol); } }
    assert_eq!(alphabet.len(),257);
    let mut active=alphabet.clone();
    let mut ranks=Models::new(257,257*4);
    let mut lengths=Models::new(256,257*9);
    let mut previous=[0u16;257];
    let mut audit=Audit { cells:[[Cell::default();8];2],totals:[Sum::default();4],tokens:[0;2],integer_intervals:0,fingerprint:0xcbf29ce484222325 };
    let mut state_values = ranks.compare_state()+lengths.compare_state();
    let mut consumed=0;
    let mut escape_bytes=0;
    for (index,run) in runs.iter().enumerate() {
        assert_eq!(active.first(),Some(&run.symbol));assert_eq!(next[usize::from(run.symbol)] as usize,index);
        let symbol=active.remove(0);next[usize::from(symbol)]=run.next;
        let rank=if run.next==u32::MAX {0} else {
            let rank=active.iter().position(|&s|next[usize::from(s)]>run.next).unwrap_or(active.len());
            assert!(rank>0);rank
        };
        let rank_key=usize::from(symbol)*4+usize::from(previous[usize::from(symbol)].min(3));
        audit.token(&mut ranks,0,rank_key,rank,active.len()+1);
        let rank_context=(usize::BITS-1-(rank+1).leading_zeros()) as usize;
        let length_key=usize::from(symbol)*9+rank_context;
        let length=run.length as usize;
        audit.token(&mut lengths,1,length_key,length.saturating_sub(1).min(255),(last.len()-consumed).min(256));
        if length>=256 {
            let mut value=(length-256) as u32;
            loop { escape_bytes+=1;value>>=7;if value==0 {break;} }
        }
        consumed+=length;previous[usize::from(symbol)]=rank as u16;
        if rank!=0 { active.insert(rank,symbol); }
        if index%65536==0 { state_values+=ranks.compare_state()+lengths.compare_state(); }
    }
    state_values+=ranks.compare_state()+lengths.compare_state();
    assert!(active.is_empty());assert_eq!(consumed,last.len());
    assert_eq!(audit.tokens,[889227,889227]);assert_eq!(escape_bytes,742);
    let mut binned=[Sum::default();4];
    for component in 0..2 {
        assert_eq!(audit.cells[component].iter().map(|cell|cell.count).sum::<u64>(),audit.tokens[component]);
        for cell in &audit.cells[component] { for (i,bits) in cell.bits.iter().enumerate() { binned[i].add(bits.value); } }
    }
    for i in 0..4 { assert!((binned[i].value-audit.totals[i].value).abs()<0.0001); }
    let [old,prior,p256,new]=audit.totals.map(|sum|sum.value);
    let precision_delta=new-prior;
    let prior_delta=prior-old;
    assert!(((new-old)-(precision_delta+prior_delta)).abs()<0.0001);
    let escape_bits=escape_bytes*8;
    let payload_bits=[575510u64*8,609941u64*8,590456u64*8];
    let gaps=[payload_bits[0] as f64-old-escape_bits as f64,payload_bits[1] as f64-p256-escape_bits as f64,payload_bits[2] as f64-new-escape_bits as f64];
    println!("{{\"status\":\"passed\",\"runs\":{},\"primary\":{primary},\"rank_intervals\":{},\"length_intervals\":{},\"escape_bytes\":{escape_bytes},\"integer_intervals_checked\":{},\"state_values\":{state_values},\"fingerprint\":\"{:016x}\",\"escape_bits\":{escape_bits},\"old_bits\":{old:.9},\"prior64_bits\":{prior:.9},\"p256_bits\":{p256:.9},\"dirichlet_bits\":{new:.9},\"prior_strength_delta_bits\":{prior_delta:.9},\"dirichlet_precision_support_delta_bits\":{precision_delta:.9},\"p256_precision_support_delta_bits\":{:.9},\"payload_gap_bits\":[{:.9},{:.9},{:.9}],\"cells\":[",runs.len(),audit.tokens[0],audit.tokens[1],audit.integer_intervals,audit.fingerprint,p256-prior,gaps[0],gaps[1],gaps[2]);
    let mut first=true;
    for component in 0..2 { for bin in 0..8 {
        let cell=audit.cells[component][bin];
        let [old,prior,p256,new]=cell.bits.map(|sum|sum.value);
        if !first {print!(",");} first=false;
        print!("{{\"component\":\"{}\",\"bin\":{bin},\"count\":{},\"old_bits\":{old:.9},\"prior64_bits\":{prior:.9},\"p256_bits\":{p256:.9},\"dirichlet_bits\":{new:.9},\"prior_strength_delta_bits\":{:.9},\"dirichlet_precision_support_delta_bits\":{:.9},\"p256_precision_support_delta_bits\":{:.9}}}",if component==0 {"rank"} else {"length"},cell.count,prior-old,new-prior,p256-prior);
    }}
    println!("]}}");
}
fn main() {
    let arguments: Vec<_>=std::env::args_os().collect();
    if arguments.len()!=2 { eprintln!("usage: loss_probe fixed-input");std::process::exit(2); }
    run(std::path::Path::new(&arguments[1]));
}

