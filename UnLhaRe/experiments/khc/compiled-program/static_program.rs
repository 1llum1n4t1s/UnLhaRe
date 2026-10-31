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
    nodes: [Instruction; 284],
    prefixes: [u8; PREFIX_BYTES],
}
const COMPILED: Program = Program::compile();
impl Program {
    const fn compile() -> Self {
        let mut program = Self {
            nodes: [Instruction {
                lo: [0; 4],
                next: [255; 4],
                class: 0,
                count: 0,
            }; 284],
            prefixes: [0; PREFIX_BYTES],
        };
        let mut c = 0;
        while c < 2 {
            let alphabet = if c == 0 { 257 } else { 256 };
            let mut used = 0;
            let mut terminals = 0;
            let root = program.build(c, alphabet, 0, alphabet, 1, &mut used, &mut terminals);
            assert!(root == 0 && used == 142 && terminals == alphabet);
            let mut n = 0;
            while n < 142 {
                let instruction = program.nodes[c * 142 + n];
                assert!(instruction.class <= 2 && instruction.count >= 1 && instruction.count <= 4);
                let mut limit = 1;
                while limit <= alphabet {
                    let mut k = 0;
                    while k < instruction.count as usize && (instruction.lo[k] as usize) < limit {
                        k += 1;
                    }
                    program.prefixes[(c * 142 + n) * 258 + limit] = k as u8;
                    limit += 1;
                }
                n += 1;
            }
            c += 1;
        }
        assert!(std::mem::size_of::<Self>() <= RETAINED_BOUND);
        program
    }
    const fn build(
        &mut self,
        c: usize,
        alphabet: usize,
        lo: usize,
        hi: usize,
        depth: usize,
        used: &mut usize,
        terminals: &mut usize,
    ) -> usize {
        assert!(lo < hi && hi <= alphabet && depth >= 1 && depth <= 8 && *used < 142);
        let id = *used;
        *used += 1;
        let class = if lo == 0 {
            0
        } else if (lo == 4 || lo == 32) && hi == alphabet {
            1
        } else {
            2
        };
        let mut cuts = [0usize; 5];
        let n;
        if lo == 0 {
            cuts = [0, 1, 2, 4, hi];
            n = 4;
        } else if lo == 4 && hi == alphabet {
            cuts = [4, 8, 16, 32, hi];
            n = 4;
        } else if lo == 32 && hi == alphabet {
            cuts = [32, 64, 128, 256, hi];
            n = 4;
        } else {
            let difference = hi - lo;
            n = if difference < 4 { difference } else { 4 };
            let mut i = 0;
            while i <= n {
                cuts[i] = lo + (hi - lo) * i / n;
                i += 1;
            }
        }
        let mut instruction = Instruction {
            lo: [0; 4],
            next: [255; 4],
            class,
            count: 0,
        };
        let mut i = 0;
        while i < n {
            let a = cuts[i];
            let b = cuts[i + 1];
            assert!(a >= lo && b <= hi && a <= b);
            if a < b {
                let child = instruction.count as usize;
                assert!(child < 4 && a <= 256);
                instruction.lo[child] = a as u16;
                if b - a > 1 {
                    let next = self.build(c, alphabet, a, b, depth + 1, used, terminals);
                    assert!(next > id && next < 142);
                    instruction.next[child] = next as u8;
                } else {
                    *terminals += 1;
                }
                instruction.count += 1;
            }
            i += 1;
        }
        assert!(instruction.count >= 1);
        self.nodes[c * 142 + id] = instruction;
        id
    }
    pub(crate) fn new() -> Result<&'static Self> {
        Ok(&COMPILED)
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
        std::mem::size_of::<Self>()
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
                    if child >= k {
                        return Err("program contract prefix".into());
                    }
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
