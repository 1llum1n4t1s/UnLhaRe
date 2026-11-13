//! 全合法token/limitの経路照合。入力データやframeを生成しない。
#![allow(dead_code)]
const MAX_INPUT: usize = 1 << 20;
#[path = "../../../src/lhc/block/bwt.rs"]
mod bwt;
#[path = "../../../src/lhc/block/frontend.rs"]
mod frontend;
#[path = "../../../src/lhc/block/grammar.rs"]
mod grammar;
#[path = "../../../src/lhc/block/histogram.rs"]
mod histogram;
fn main() -> Result<(), String> {
    let mut pairs = 0usize;
    let mut branches = 0usize;
    for alphabet in [256, 257] {
        let tree = grammar::Tree::new(alphabet);
        let routes = grammar::Routes::new(&tree)?;
        for limit in 1..=alphabet {
            for token in 0..limit {
                let path = routes.path(token, limit, alphabet)?;
                let mut node = 0;
                for (depth, step) in path.iter().enumerate() {
                    let k = tree.prefix(node, limit)?;
                    let child = tree.known_child(node, token, limit)?;
                    let edge = tree.edge(node, child, k)?;
                    if step.node as usize != node
                        || step.child as usize != child
                        || step.class as usize != tree.class(node)?
                        || step.terminal != edge.node.is_none()
                        || (edge.node.is_none() && (edge.lo != token || depth + 1 != path.len()))
                    {
                        return Err(format!(
                            "route mismatch: {alphabet}/{limit}/{token}/{depth}"
                        ));
                    }
                    branches += 1;
                    if let Some(next) = edge.node {
                        node = next;
                    }
                }
                pairs += 1;
            }
        }
        for (token, limit) in [(0, 0), (alphabet, alphabet), (0, alphabet + 1)] {
            if routes.path(token, limit, alphabet).is_ok() {
                return Err("invalid token/limit accepted".into());
            }
        }
    }
    println!(
        "pairs={pairs}; branches={branches}; exact=true; invalid_rejected=6; route_bytes={}",
        std::mem::size_of::<grammar::Routes>()
    );
    Ok(())
}
