//! 凍結hard-cut primaryへの型接続だけ。数値/更新/価格を変更しない。
#[path="../hard-cut-lazy-errors/lazy_engine.rs"] mod engine;
pub use engine::*;
pub type Node=NodeState;
