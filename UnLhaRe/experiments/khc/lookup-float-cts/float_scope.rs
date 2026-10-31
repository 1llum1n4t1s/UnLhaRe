//! 新旧codecの返却型を独立した静的スコープへ接続する。
#[path="codec.rs"] pub(crate) mod codec;
pub(crate) struct Encoded {pub frame:Vec<u8>,pub stats:String,pub proof:codec::Proof,pub elapsed_ns:u64}
pub(crate) struct Decoded {pub plain:Vec<u8>,pub stats:String,pub proof:codec::Proof,pub elapsed_ns:u64}
