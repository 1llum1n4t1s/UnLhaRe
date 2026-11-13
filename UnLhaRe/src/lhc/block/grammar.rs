use super::frontend::Front;
type Result<T> = std::result::Result<T, String>;
// 全class履歴をk1含め更新する固定grammar。
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Edge {
    pub lo: usize,
    pub hi: usize,
    pub node: Option<usize>,
}
#[derive(Clone)]
struct Node {
    edges: Vec<Edge>,
    class: usize,
}
pub(crate) struct Tree {
    alphabet: usize,
    nodes: Vec<Node>,
}
#[derive(Clone, Copy, Default)]
pub(crate) struct RouteStep {
    pub node: u16,
    pub class: u8,
    pub child: u8,
    pub terminal: bool,
}
pub(crate) struct Routes {
    steps: [[RouteStep; 8]; 257],
    lengths: [u8; 257],
}
impl Routes {
    pub fn new(tree: &Tree) -> Result<Self> {
        let mut routes = Self {
            steps: [[RouteStep::default(); 8]; 257],
            lengths: [0; 257],
        };
        for token in 0..tree.alphabet {
            let mut node = 0;
            loop {
                let depth = routes.lengths[token] as usize;
                let child = tree.known_child(node, token, tree.alphabet)?;
                let edge = tree.edge(node, child, tree.prefix(node, tree.alphabet)?)?;
                *routes.steps[token].get_mut(depth).ok_or("route depth")? = RouteStep {
                    node: u16::try_from(node).map_err(|_| "route node")?,
                    class: u8::try_from(tree.class(node)?).map_err(|_| "route class")?,
                    child: u8::try_from(child).map_err(|_| "route child")?,
                    terminal: edge.node.is_none(),
                };
                routes.lengths[token] += 1;
                match edge.node {
                    Some(next) => node = next,
                    None => break,
                }
            }
        }
        Ok(routes)
    }
    pub fn path(&self, token: usize, limit: usize, alphabet: usize) -> Result<&[RouteStep]> {
        if limit == 0 || limit > alphabet || token >= limit {
            return Err("token/limit".into());
        }
        Ok(&self.steps[token][..self.lengths[token] as usize])
    }
}
impl Tree {
    pub fn new(alphabet: usize) -> Self {
        let mut t = Self {
            alphabet,
            nodes: Vec::new(),
        };
        t.build(0, alphabet);
        t
    }
    fn build(&mut self, lo: usize, hi: usize) -> usize {
        let id = self.nodes.len();
        let class = if lo == 0 {
            0
        } else if (lo == 4 || lo == 32) && hi == self.alphabet {
            1
        } else {
            2
        };
        self.nodes.push(Node {
            edges: Vec::new(),
            class,
        });
        let cuts = if lo == 0 {
            vec![0, 1, 2, 4, hi]
        } else if lo == 4 && hi == self.alphabet {
            vec![4, 8, 16, 32, hi]
        } else if lo == 32 && hi == self.alphabet {
            vec![32, 64, 128, 256, hi]
        } else {
            let n = (hi - lo).min(4);
            (0..=n).map(|i| lo + (hi - lo) * i / n).collect()
        };
        let mut edges = Vec::new();
        for p in cuts.windows(2) {
            if p[0] < p[1] {
                let node = if p[1] - p[0] > 1 {
                    Some(self.build(p[0], p[1]))
                } else {
                    None
                };
                edges.push(Edge {
                    lo: p[0],
                    hi: p[1],
                    node,
                });
            }
        }
        self.nodes[id].edges = edges;
        id
    }
    pub fn prefix(&self, node: usize, limit: usize) -> Result<usize> {
        if limit == 0 || limit > self.alphabet {
            return Err("token/limit".into());
        }
        let n = self.nodes.get(node).ok_or("tree node")?;
        let k = n.edges.iter().take_while(|e| e.lo < limit).count();
        if k == 0 {
            return Err("tree empty prefix".into());
        }
        Ok(k)
    }
    pub fn edge(&self, node: usize, child: usize, prefix: usize) -> Result<Edge> {
        if child >= prefix {
            return Err("tree child".into());
        }
        self.nodes
            .get(node)
            .and_then(|n| n.edges.get(child))
            .cloned()
            .ok_or("tree edge".into())
    }
    pub fn known_child(&self, node: usize, token: usize, limit: usize) -> Result<usize> {
        let k = self.prefix(node, limit)?;
        if token >= limit {
            return Err("token/limit".into());
        }
        self.nodes[node].edges[..k]
            .iter()
            .position(|e| e.lo <= token && token < e.hi)
            .ok_or("tree token".into())
    }
    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }
    pub fn class(&self, node: usize) -> Result<usize> {
        self.nodes
            .get(node)
            .map(|n| n.class)
            .ok_or("tree class".into())
    }
}
#[derive(Default, Debug, PartialEq, Eq)]
pub struct Meta {
    pub tokens: [u64; 2],
    pub runs: usize,
    pub escapes: usize,
    pub history_checks: u64,
    pub grammar: u64,
    pub branches: [u64; 2],
    pub classes: [u64; 6],
    pub prefixes: [[u64; 4]; 6],
    pub final_history: [u16; 6],
}
pub fn walk(
    front: &Front,
    mut branch: impl FnMut(usize, usize, usize, usize, u16, usize) -> Result<()>,
) -> Result<Meta> {
    walk_with_terminal(front, |c, n, cl, k, h, ch, _terminal| {
        branch(c, n, cl, k, h, ch)
    })
}
pub fn walk_with_terminal(
    front: &Front,
    mut branch: impl FnMut(usize, usize, usize, usize, u16, usize, bool) -> Result<()>,
) -> Result<Meta> {
    let trees = [Tree::new(257), Tree::new(256)];
    let routes = [Routes::new(&trees[0])?, Routes::new(&trees[1])?];
    let mut histories = [0u16; 6];
    let mut rank = [0usize; 257];
    let mut bucket = [0usize; 257];
    let mut pending = None;
    let mut meta = Meta {
        grammar: 0xcbf29ce484222325,
        ..Meta::default()
    };
    meta.escapes = front.walk(|c, s, x, b, token, limit, old_rank| {
        if c > 1
            || s >= 257
            || rank[s] != old_rank
            || (c == 0 && b != rank[s].min(3))
            || (c == 1 && b != bucket[s])
        {
            return Err("branch frozen history".into());
        }
        let run = front.runs.get(meta.runs).ok_or("branch run")?;
        if run.symbol as usize != s {
            return Err("branch symbol order".into());
        }
        if c == 0 {
            if pending.is_some() {
                return Err("branch pending rank".into());
            }
            pending = Some((s, token));
        } else {
            let Some((ps, r)) = pending else {
                return Err("branch pending length".into());
            };
            if ps != s
                || x != super::histogram::exponent(r + 1)
                || token != (run.length as usize - 1).min(255)
            {
                return Err("branch length/context".into());
            }
        }
        let tree = &trees[c];
        for step in routes[c].path(token, limit, tree.alphabet)? {
            let node = step.node as usize;
            let k = tree.prefix(node, limit)?;
            let child = step.child as usize;
            if child >= k {
                return Err("tree child".into());
            }
            let class = c * 3 + step.class as usize;
            branch(c, node, class, k, histories[class], child, step.terminal)?;
            meta.branches[c] = meta.branches[c].checked_add(1).ok_or("branch overflow")?;
            meta.classes[class] = meta.classes[class].checked_add(1).ok_or("class overflow")?;
            meta.prefixes[class][k - 1] = meta.prefixes[class][k - 1]
                .checked_add(1)
                .ok_or("prefix overflow")?;
            histories[class] = ((histories[class] << 2) | child as u16) & 1023;
        }
        let key = if c == 0 {
            s * 4 + old_rank.min(3)
        } else {
            s * 9 + x
        };
        for value in [c, key, token, limit] {
            meta.grammar = (meta.grammar ^ value as u64).wrapping_mul(0x100000001b3);
        }
        meta.tokens[c] = meta.tokens[c]
            .checked_add(1)
            .ok_or("token count overflow")?;
        meta.history_checks = meta
            .history_checks
            .checked_add(1)
            .ok_or("history count overflow")?;
        if c == 1 {
            let (_, r) = pending.take().ok_or("run rank missing")?;
            rank[s] = r;
            bucket[s] = super::histogram::length_bucket(run.length as usize);
            meta.runs += 1;
        }
        Ok(())
    })?;
    if pending.is_some()
        || meta.tokens != [front.runs.len() as u64; 2]
        || meta.runs != front.runs.len()
    {
        return Err("branch terminal counts".into());
    }
    meta.final_history = histories;
    Ok(meta)
}
