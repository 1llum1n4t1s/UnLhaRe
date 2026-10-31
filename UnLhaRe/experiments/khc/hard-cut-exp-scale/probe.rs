//! 有限全Resultの逐次比較。通常codec/速度/4native同値の検証ではない。
#![allow(dead_code)]
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../lookup-float-cts/float_math.rs"] mod reference_math;
#[path="scaled_math.rs"] mod candidate_math;
type Result<T> = std::result::Result<T,String>;
const EXPECTED: [u64;3] = [393312,65536,30];
const TOTAL: u64 = 458878;
const LIMIT: u64 = 500000;
const RAW_BOUNDARIES: [u64;24] = [
    0x0000000000000000,0x8000000000000000,
    0x0000000000000001,0x000fffffffffffff,0x0010000000000000,
    0x8000000000000001,0x800fffffffffffff,0x8010000000000000,
    0x7ff0000000000000,0xfff0000000000000,
    0x7ff8000000000000,0xfff8000000000000,
    0x7ff8000000000001,0xfff8000000000001,
    0x7fffffffffffffff,0xffffffffffffffff,
    0x7ff0000000000001,0xfff0000000000001,
    0x3ff0000000000000,0xbff0000000000000,
    0x7fefffffffffffff,0xffefffffffffffff,
    0x4060000000000000,0xc060000000000000,
];
// Rust ABIの診断wrapper。asmはこのEXEだけの局所証拠。
#[unsafe(no_mangle)]
#[inline(never)]
pub fn reference_exp(math:&reference_math::Math,d:f64)->Result<f64>{math.exp_neg(d)}
#[unsafe(no_mangle)]
#[inline(never)]
pub fn candidate_exp(math:&candidate_math::Math,d:f64)->Result<f64>{math.exp_neg(d)}
#[derive(Default)]
struct Census {groups:[u64;3],total:u64,ok:u64,error:u64,digest:u64}
fn fold(bits:u64)->u16 {((bits^(bits>>16)^(bits>>32)^(bits>>48))&65535)as u16}
fn error_fold(message:&str)->u16 {message.bytes().fold(0u16,|word,b|word.rotate_left(5)^u16::from(b))}
fn checked_inc(n:u64)->Result<u64>{n.checked_add(1).ok_or("case counter overflow".into())}
impl Census {
    fn compare(&mut self,group:usize,d:f64,old:&reference_math::Math,new:&candidate_math::Math)->Result<()> {
        let group_count=checked_inc(self.groups[group])?;let ordinal=checked_inc(self.total)?;
        if group_count>EXPECTED[group]||ordinal>LIMIT{return Err("fixed case group limit".into());}
        let a=reference_exp(old,d);let b=candidate_exp(new,d);
        let(word,is_ok)=match(&a,&b){
            (Ok(a),Ok(b))if a.to_bits()==b.to_bits()=>(fold(a.to_bits())^0x4f4b,true),
            (Err(a),Err(b))if a==b=>(error_fold(a)^0xe770,false),
            _=>return Err(format!("finite mismatch group={group} ordinal={ordinal} input={:016x} reference={a:?} candidate={b:?}",d.to_bits())),
        };
        // 全Result直接比較が主証拠。checksumは弱い順序付き表示証拠のみ。
        let contribution=ordinal.checked_mul(u64::from(fold(d.to_bits())^word)).ok_or("digest multiply overflow")?;
        let digest=self.digest.checked_add(contribution).ok_or("digest add overflow")?;
        if is_ok{self.ok=checked_inc(self.ok)?;}else{self.error=checked_inc(self.error)?;}
        self.groups[group]=group_count;self.total=ordinal;self.digest=digest;Ok(())
    }
}
fn execute()->Result<()> {
    if std::env::args_os().nth(1).is_some(){return Err("usage: no arguments".into());}
    if 32*4097*3!=EXPECTED[0]||65536!=EXPECTED[1]||RAW_BOUNDARIES.len()as u64+6!=EXPECTED[2]
        ||EXPECTED.iter().try_fold(0u64,|n,v|n.checked_add(*v))!=Some(TOTAL)||TOTAL>LIMIT{return Err("case census arithmetic".into());}
    let checksum_bound=LIMIT.checked_mul(LIMIT).and_then(|n|n.checked_mul(65535)).ok_or("digest source bound overflow")?;
    let reference=reference_math::Math::new()?;
    let candidate=candidate_math::Math::new()?;
    let ln2=fixed_math::LN2 as f64/fixed_math::S as f64;
    let mut census=Census::default();
    for exponent in 0..32 {for index in 0..=4096 {
        let d=exponent as f64*ln2+index as f64*(ln2/4096.0);
        for value in [d.next_down(),d,d.next_up()] {census.compare(0,value,&reference,&candidate)?;}
    }}
    let mut seed=0x6d2b79f5u32;
    for _ in 0..65536 {
        seed=seed.wrapping_mul(1664525).wrapping_add(1013904223);
        let d=f64::from(seed)*(128.0/f64::from(u32::MAX));
        census.compare(1,d,&reference,&candidate)?;
    }
    for bits in RAW_BOUNDARIES {census.compare(2,f64::from_bits(bits),&reference,&candidate)?;}
    for d in [128.0,32.0*ln2] {for value in [d.next_down(),d,d.next_up()] {census.compare(2,value,&reference,&candidate)?;}}
    if census.groups!=EXPECTED||census.total!=TOTAL||census.ok.checked_add(census.error)!=Some(TOTAL)||census.digest>checksum_bound{return Err("terminal census/digest bound".into());}
    let digest=format!("{:016x}",census.digest);
    println!("{{\"status\":\"passed\",\"operation\":\"exp-scale-finite\",\"grid_cases\":{},\"random_cases\":{},\"boundary_cases\":{},\"total_cases\":{},\"exact_result_comparisons\":{},\"ok_cases\":{},\"error_cases\":{},\"mismatches\":0,\"reference_constructor_calls\":1,\"candidate_constructor_calls\":1,\"streamed_cases\":true,\"cases_Vec\":0,\"speed_claimed\":false,\"adoption\":false,\"results_digest\":\"{digest}\",\"digest_algorithm\":\"checked ordinal times XOR16 input-result-class sum; noncryptographic\",\"digest_bound\":{checksum_bound},\"LCG_seed\":1831565813,\"LCG_final_state\":{seed},\"grid_exponents\":32,\"grid_indices_per_exponent\":4097,\"grid_neighbors\":3,\"raw_boundary_bits\":24,\"explicit_boundary_neighbors\":6,\"Ok_bits_directly_compared\":true,\"Err_strings_and_class_directly_compared\":true,\"wrapper_ABI\":\"Rust\",\"wrapper_names\":[\"reference_exp\",\"candidate_exp\"],\"candidate_extra_allocation_claim_scope\":\"source only, constructor body unchanged\",\"allocator_calls_measured\":false,\"normal_codec_verified\":false,\"all_f64_inputs_proven\":false,\"native4_verified\":false}}",census.groups[0],census.groups[1],census.groups[2],census.total,census.total,census.ok,census.error);
    Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("hard-cut-exp-scale: {e}");std::process::exit(1);}}
