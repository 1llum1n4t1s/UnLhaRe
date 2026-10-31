//! 固定geometryのprivate復号命令表。入力依存CDFはpacket内の検査済み型で保持する。
use super::{Result, grammar};
pub(crate) const RETAINED_BOUND: usize = 78000;
pub(crate) const TRANSIENT_BOUND: usize = 65536;
const PREFIX_BYTES: usize = 2 * 142 * 258;
#[derive(Clone, Copy)]
pub(crate) struct Instruction {
    lo: [u16; 4],
    next: [u8; 4],
    pub(crate) class: u8,
    count: u8,
}
const _: () = assert!(std::mem::size_of::<Instruction>() <= 16);
impl Instruction {
    pub(crate) fn step(&self, child: usize) -> Result<(usize, Option<usize>)> {
        if child >= self.count as usize {
            return Err("tree edge".into());
        }
        Ok((
            self.lo[child] as usize,
            (self.next[child] != 255).then_some(self.next[child] as usize),
        ))
    }
}
pub(crate) struct Program {
    nodes: Vec<Instruction>,
    prefixes: Vec<u8>,
}
impl Program {
    pub(crate) fn new() -> Result<Self> {
        let mut nodes = Vec::new();
        nodes
            .try_reserve_exact(284)
            .map_err(|_| "program nodes allocation")?;
        let mut prefixes = Vec::new();
        prefixes
            .try_reserve_exact(PREFIX_BYTES)
            .map_err(|_| "program prefix allocation")?;
        prefixes.resize(PREFIX_BYTES, 0);
        if nodes.capacity() * std::mem::size_of::<Instruction>()
            + prefixes.capacity()
            + std::mem::size_of::<Self>()
            > RETAINED_BOUND
        {
            return Err("program retained bound".into());
        }
        for c in 0..2 {
            let alphabet = if c == 0 { 257 } else { 256 };
            let tree = grammar::Tree::new(alphabet);
            if tree.node_count() != 142 {
                return Err("program node count".into());
            }
            let mut depths = [0u8; 142];
            depths[0] = 1;
            let mut terminals = 0;
            for n in 0..142 {
                if depths[n] == 0 || depths[n] > 8 {
                    return Err("program depth/reachability".into());
                }
                let k = tree.prefix(n, alphabet)?;
                let class = tree.class(n)?;
                if !(1..=4).contains(&k) || class > 2 {
                    return Err("program shape".into());
                }
                let mut instruction = Instruction {
                    lo: [0; 4],
                    next: [255; 4],
                    class: class as u8,
                    count: k as u8,
                };
                let mut previous_hi = None;
                for child in 0..k {
                    let edge = tree.edge(n, child, k)?;
                    if edge.lo >= edge.hi
                        || edge.hi > alphabet
                        || previous_hi.is_some_and(|hi| hi != edge.lo)
                    {
                        return Err("program edge bounds".into());
                    }
                    previous_hi = Some(edge.hi);
                    instruction.lo[child] = u16::try_from(edge.lo).map_err(|_| "program lo")?;
                    if let Some(next) = edge.node {
                        if next <= n || next >= 142 || depths[next] != 0 {
                            return Err("program forward parent".into());
                        }
                        let nk = tree.prefix(next, alphabet)?;
                        if tree.edge(next, 0, nk)?.lo != edge.lo
                            || tree.edge(next, nk - 1, nk)?.hi != edge.hi
                        {
                            return Err("program subtree extent".into());
                        }
                        depths[next] = depths[n] + 1;
                        instruction.next[child] = next as u8;
                    } else {
                        if edge.hi - edge.lo != 1 {
                            return Err("program terminal extent".into());
                        }
                        terminals += 1;
                    }
                }
                for limit in 1..=alphabet {
                    let count = match tree.prefix(n, limit) {
                        Ok(count) => count,
                        Err(error) if error == "tree empty prefix" => 0,
                        Err(error) => return Err(error),
                    };
                    prefixes[(c * 142 + n) * 258 + limit] = count as u8;
                }
                nodes.push(instruction);
            }
            if terminals != alphabet || depths.iter().any(|&d| d == 0 || d > 8) {
                return Err("program terminal/depth".into());
            }
        }
        Ok(Self { nodes, prefixes })
    }
    pub(crate) fn node(&self, c: usize, n: usize, limit: usize) -> Result<(&Instruction, usize)> {
        let alphabet = if c == 0 { 257 } else { 256 };
        if c >= 2 || limit == 0 || limit > alphabet {
            return Err("token/limit".into());
        }
        if n >= 142 {
            return Err("tree node".into());
        }
        let index = c * 142 + n;
        let k = self.prefixes[index * 258 + limit] as usize;
        if k == 0 {
            return Err("tree empty prefix".into());
        }
        Ok((&self.nodes[index], k))
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        self.nodes.capacity() * std::mem::size_of::<Instruction>()
            + self.prefixes.capacity()
            + std::mem::size_of::<Self>()
    }
}
pub(crate) fn geometry_contract() -> Result<(usize, usize)> {
    let program = Program::new()?;
    let mut routes = 0;
    let mut shapes = 0;
    for c in 0..2 {
        let alphabet = if c == 0 { 257 } else { 256 };
        let tree = grammar::Tree::new(alphabet);
        let old = grammar::CompactTree::new(alphabet)?;
        for n in 0..142 {
            for limit in 1..=alphabet {
                match (old.node(n, limit), program.node(c, n, limit)) {
                    (Ok((on, ok)), Ok((pn, pk))) => {
                        if ok != pk || on.class != pn.class {
                            return Err("program shape mismatch".into());
                        }
                        for child in 0..ok {
                            if on.edge(child, ok)? != pn.step(child)? {
                                return Err("program edge mismatch".into());
                            }
                        }
                    }
                    (Err(a), Err(b)) => {
                        if a != b {
                            return Err("program error mismatch".into());
                        }
                    }
                    _ => return Err("program acceptance mismatch".into()),
                }
                shapes += 1;
            }
        }
        for limit in 1..=alphabet {
            for token in 0..limit {
                let mut n = 0;
                let mut depth = 0;
                loop {
                    depth += 1;
                    if depth > 8 {
                        return Err("program contract depth".into());
                    }
                    let (instruction, k) = program.node(c, n, limit)?;
                    let child = tree.known_child(n, token, limit)?;
                    let (lo, next) = instruction.step(child)?;
                    if let Some(next) = next {
                        n = next;
                    } else {
                        if lo != token {
                            return Err("program contract token".into());
                        }
                        break;
                    }
                }
                routes += 1;
            }
        }
        for (bad_c, bad_node, bad_limit) in
            [(c, 0, 0), (c, 0, alphabet + 1), (c, 142, 1), (2, 0, 1)]
        {
            if program.node(bad_c, bad_node, bad_limit).is_ok() {
                return Err("program invalid accepted".into());
            }
        }
    }
    Ok((routes, shapes))
}
