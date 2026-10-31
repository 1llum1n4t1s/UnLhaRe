//! 凍結hard-cut primaryへの型接続だけ。数値/更新/価格を変更しない。
#[path="../causal-hard-cut/engine.rs"] mod engine;
pub use engine::*;
pub type Node=NodeState;
