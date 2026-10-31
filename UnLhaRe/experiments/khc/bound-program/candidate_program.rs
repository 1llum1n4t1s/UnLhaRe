//! 固定geometryのprivate復号命令表。入力依存CDFはpacket内の検査済み型で保持する。
use super::Result;
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
static COMPILED: Program = Program::compile();
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
            let root = program.build(c, 0, alphabet, 1, &mut used, &mut terminals);
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
        lo: usize,
        hi: usize,
        depth: usize,
        used: &mut usize,
        terminals: &mut usize,
    ) -> usize {
        let alphabet = if c == 0 { 257 } else { 256 };
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
                    let next = self.build(c, a, b, depth + 1, used, terminals);
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
    pub(crate) fn new() -> &'static Self {
        &COMPILED
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

// BIND_PROGRAM_BEGIN
use super::packet::{BoundCdf, DecodeForest};
pub(crate) const BINDING_BOUND: usize = 65536;
#[derive(Clone, Copy)]
pub(crate) struct BoundNode<'a> {
    pub(crate) instruction: &'a Instruction,
    pub(crate) cdf: Option<BoundCdf<'a>>,
    pub(crate) k: usize,
    pub(crate) class: usize,
}
pub(crate) struct BoundProgram<'a> {
    program: &'a Program,
    forest: &'a DecodeForest,
    c: usize,
    limit: usize,
    nodes: [Option<BoundNode<'a>>; 142],
}
const _: () = assert!(std::mem::size_of::<BoundProgram<'static>>() * 4 <= BINDING_BOUND);
impl<'a> BoundProgram<'a> {
    pub(crate) fn new(
        program: &'a Program,
        forest: &'a DecodeForest,
        c: usize,
        limit: usize,
    ) -> Result<Self> {
        let mut b = Self {
            program,
            forest,
            c,
            limit: 0,
            nodes: [None; 142],
        };
        b.update(limit)?;
        Ok(b)
    }
    pub(crate) fn update(&mut self, limit: usize) -> Result<()> {
        let alphabet = if self.c == 0 { 257 } else { 256 };
        if self.c >= 2 || limit == 0 || limit > alphabet {
            return Err("token/limit".into());
        }
        if limit == self.limit {
            return Ok(());
        }
        for n in 0..142 {
            self.nodes[n] = match self.program.node(self.c, n, limit) {
                Ok((instruction, k)) => Some(BoundNode {
                    instruction,
                    k,
                    class: self.c * 3 + instruction.class as usize,
                    cdf: if k == 1 {
                        None
                    } else {
                        Some(self.forest.bind(self.c, n, k)?)
                    },
                }),
                Err(e) if e == "tree empty prefix" => None,
                Err(e) => return Err(e),
            };
        }
        self.limit = limit;
        Ok(())
    }
    pub(crate) fn node(&self, n: usize) -> Result<&BoundNode<'a>> {
        self.nodes
            .get(n)
            .ok_or("tree node")?
            .as_ref()
            .ok_or("tree empty prefix".into())
    }
    pub(crate) fn limit(&self) -> usize {
        self.limit
    }
}
pub(crate) fn binding_contract(program: &Program, forest: &DecodeForest) -> Result<usize> {
    let mut count = 0;
    for c in 0..2 {
        let mut bound = BoundProgram::new(program, forest, c, 1)?;
        for limit in 1..=if c == 0 { 257 } else { 256 } {
            bound.update(limit)?;
            // 同limit更新は状態を変えない。
            bound.update(limit)?;
            for n in 0..142 {
                match (program.node(c, n, limit), bound.node(n)) {
                    (Err(a), Err(b)) if a == b => (),
                    (Ok((a, k)), Ok(b)) => {
                        if k != b.k || c * 3 + a.class as usize != b.class {
                            return Err("bound geometry".into());
                        }
                        for child in 0..=4 {
                            if a.step(child) != b.instruction.step(child) {
                                return Err("bound step".into());
                            }
                        }
                        if k > 1 {
                            for h in [0, 1, 1023] {
                                let a = forest.cdf(c, n, k, h)?;
                                let b = b.cdf.ok_or("bound test CDF")?.cdf(h)?;
                                for slot in [0, 1, 32767, 32768] {
                                    if a.choose(slot) != b.choose(slot) {
                                        return Err("bound geometry CDF".into());
                                    }
                                }
                            }
                        }
                    }
                    _ => return Err("bound acceptance".into()),
                }
                count += 1;
            }
        }
        if bound.node(142).err().as_deref() != Some("tree node")
            || bound.update(0).err().as_deref() != Some("token/limit")
            || bound
                .update(if c == 0 { 258 } else { 257 })
                .err()
                .as_deref()
                != Some("token/limit")
        {
            return Err("bound invalid arguments".into());
        }
    }
    if BoundProgram::new(program, forest, 2, 1).err().as_deref() != Some("token/limit") {
        return Err("bound component".into());
    }
    if count != 72846 {
        return Err("bound coverage".into());
    }
    Ok(count)
}
// BIND_PROGRAM_END
