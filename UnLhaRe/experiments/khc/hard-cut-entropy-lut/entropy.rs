//! 旧式と同じbit値の不変表。容量診断はconstructor成功時だけ、branch計器なし。
use std::cell::Cell;
use crate::Result;
const LENGTH:usize=32769;
thread_local!{static LAST_CAPACITY:Cell<Option<usize>>=const{Cell::new(None)};}
fn reserve(n:usize)->Result<Vec<f64>>{let mut values=Vec::new();values.try_reserve_exact(n).map_err(|_|"entropy allocation".to_string())?;Ok(values)}
fn scalar(f:u32)->f64{-(f64::from(f)/32768.0).log2()}
pub(crate) struct Table{values:Vec<f64>}
impl Table{
    pub(crate) fn empty()->Self{Self{values:Vec::new()}}
    pub(crate) fn new()->Result<Self>{
        let mut values=reserve(LENGTH)?;
        for f in 0..LENGTH{values.push(scalar(f as u32));}
        LAST_CAPACITY.set(Some(values.capacity()));
        Ok(Self{values})
    }
    pub(crate) fn value(&self,f:u32)->f64{if f<=32768{self.values[f as usize]}else{scalar(f)}}
    pub(crate) fn capacity(&self)->usize{self.values.capacity()}
}
pub(crate) fn last_capacity()->Option<usize>{LAST_CAPACITY.get()}
fn need(ok:bool,why:&str)->Result<()>{if ok{Ok(())}else{Err(why.into())}}
fn mix(d:&mut u64,b:u64){*d=(*d^b).wrapping_mul(0x100000001b3);}
pub(crate) fn finite()->Result<String>{
    let table=Table::new()?;let capacity=table.capacity();let mut digest=0xcbf29ce484222325u64;
    for f in 0..=32768{let a=table.value(f).to_bits();need(a==scalar(f).to_bits(),"table before bits")?;mix(&mut digest,a);}
    need(table.value(0).to_bits()==f64::INFINITY.to_bits()&&table.value(32768).to_bits()==(-0.0f64).to_bits(),"Inf/negative zero bits")?;
    for f in [32769,u32::MAX]{let a=table.value(f).to_bits();need(a==scalar(f).to_bits(),"fallback bits")?;mix(&mut digest,a);}
    let(mut av,mut ac,mut bv,mut bc)=(0.0f64,0.0f64,0.0f64,0.0f64);
    for _ in 0..64{for f in [1,32768,2,32767,3,16384,7,8192,31,1024,32768,1]{
        let x=scalar(f);let y=x-ac;let t=av+y;ac=(t-av)-y;av=t;
        let x=table.value(f);let y=x-bc;let t=bv+y;bc=(t-bv)-y;bv=t;
        need(av.to_bits()==bv.to_bits()&&ac.to_bits()==bc.to_bits(),"Kahan step bits")?;mix(&mut digest,av.to_bits());mix(&mut digest,ac.to_bits());
    }}
    need(usize::MAX.checked_mul(std::mem::size_of::<f64>()).is_none(),"capacity overflow precondition")?;
    match reserve(usize::MAX){Err(e)=>need(e=="entropy allocation","capacity overflow error")?,Ok(_)=>return Err("capacity overflow accepted".into())}
    for f in 0..=32768{let a=table.value(f).to_bits();need(a==scalar(f).to_bits(),"table after bits")?;mix(&mut digest,a);}
    need(last_capacity()==Some(capacity)&&capacity>=LENGTH,"finite capacity readback")?;
    Ok(format!("{{\"domain_cases\":32769,\"fallback_cases\":2,\"table_before_bit_comparisons\":32769,\"table_after_bit_comparisons\":32769,\"special_bit_comparisons\":2,\"Kahan_updates\":768,\"Kahan_bit_comparisons\":1536,\"capacity_overflow_rejections\":1,\"constructor_calls\":1,\"table_capacity_entries\":{capacity},\"table_capacity_bytes\":{},\"table_payload_bytes\":262152,\"mismatches\":0,\"results_digest\":\"{digest:016x}\",\"streamed_cases\":true,\"cases_Vec\":0,\"OS_OOM_injected\":false}}",capacity*8))
}
