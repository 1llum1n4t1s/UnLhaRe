//! allocation計測付き単一binary。正式速度ではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
#[path="../lookup-float-cts/float_cts.rs"] mod old_cts;
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../prices.rs"] mod prices;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
use old_cts as float_cts;
mod control_scope;
mod candidate_scope;
mod compare;
type Result<T>=std::result::Result<T,String>;
fn main(){let result=(||->Result<()>{if std::mem::size_of::<control_scope::Node>()!=40 || std::mem::size_of::<candidate_scope::Node>()!=40{return Err("both NodeState ABI size40".into());}compare::run()})();if let Err(e)=result{eprintln!("hard-cut-lazy-errors: {e}");std::process::exit(1);}}
