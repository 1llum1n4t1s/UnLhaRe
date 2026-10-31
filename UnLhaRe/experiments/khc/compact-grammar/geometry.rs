//! 固定node表の全limit照合。データとframeを生成しない。
#![allow(dead_code)]
const MAX_INPUT: usize = 1 << 20;
#[path = "../../../src/khc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/khc/block/frontend.rs"]
mod frontend;
#[path = "../../../src/khc/block/grammar.rs"]
mod grammar;
#[path = "../../../src/khc/block/histogram.rs"]
mod histogram;
fn main() -> Result<(), String> {
    let mut contexts = 0;
    let mut edges = 0;
    let mut rejected = 0;
    for alphabet in [256, 257] {
        let old = grammar::Tree::new(alphabet);
        let new = grammar::CompactTree::new(alphabet)?;
        for n in 0..144 {
            for limit in 0..=alphabet + 1 {
                let expected = old.prefix(n, limit);
                let actual = new.node(n, limit);
                if expected.as_ref().map(|&k| k) != actual.as_ref().map(|&(_, k)| k) {
                    return Err(format!("prefix mismatch {alphabet}/{n}/{limit}"));
                }
                if let Ok((node, k)) = actual {
                    if node.class as usize != old.class(n)? {
                        return Err("class mismatch".into());
                    }
                    for ch in 0..=4 {
                        let a = old.edge(n, ch, k).map(|e| (e.lo, e.node));
                        let b = node.edge(ch, k);
                        if a != b {
                            return Err(format!("edge mismatch {alphabet}/{n}/{limit}/{ch}"));
                        }
                        edges += 1;
                    }
                    contexts += 1;
                } else {
                    rejected += 1;
                }
            }
        }
    }
    println!(
        "contexts={contexts}; edges={edges}; rejected={rejected}; exact=true; tree_bytes={}",
        std::mem::size_of::<grammar::CompactTree>()
    );
    Ok(())
}
