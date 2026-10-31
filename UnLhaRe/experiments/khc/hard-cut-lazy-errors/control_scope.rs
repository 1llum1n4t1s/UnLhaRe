//! 原hard-cut engineへ独立scope接続。Node名だけ型aliasする。
use crate::{float_math as fixed_math,float_pool as integer_pool,bwt,packed_alphabet,multi_range};
#[path="../causal-hard-cut/engine.rs"] mod engine;
pub use engine::*;
pub type Node=NodeState;
use crate::control_scope as integer_cts;
#[path="control_codec.rs"] pub(crate) mod codec;
pub(crate) struct Encoded {pub frame:Vec<u8>,pub stats:String,pub proof:codec::Proof,pub elapsed_ns:u64}
pub(crate) struct Decoded {pub plain:Vec<u8>,pub stats:String,pub proof:codec::Proof,pub elapsed_ns:u64}
