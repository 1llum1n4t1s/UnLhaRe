use crate::prior_math::PriorScale;
const MAX_CDF: u32 = 66045;
const MAX_ALPHABET: usize = 257;
const RESCALE: u32 = 16384;
const WEIGHT: u32 = 4;

struct Frequency {
    counts: [u16; MAX_ALPHABET],
    tree: [u32; MAX_ALPHABET + 1],
    total: u32,
}

impl Frequency {
    fn zero() -> Self {
        Self { counts: [0; MAX_ALPHABET], tree: [0; MAX_ALPHABET + 1], total: 0 }
    }

    fn prefix(&self, mut limit: usize) -> u32 {
        let mut sum = 0;
        while limit != 0 {
            sum += self.tree[limit];
            limit &= limit - 1;
        }
        sum
    }

    fn rebuild(&mut self, alphabet: usize) {
        self.tree.fill(0);
        self.total = 0;
        for token in 0..alphabet {
            let count = u32::from(self.counts[token]);
            self.total += count;
            let mut index = token + 1;
            while index <= alphabet {
                self.tree[index] += count;
                index += index & index.wrapping_neg();
            }
        }
    }

    fn prepare_increment(&self, token: usize, alphabet: usize) -> Result<(), &'static str> {
        if self.total >= RESCALE || u32::from(self.counts[token]) > self.total {
            return Err("count invariant");
        }
        self.counts[token].checked_add(1).ok_or("count overflow")?;
        self.total.checked_add(1).ok_or("total overflow")?;
        let mut index = token + 1;
        while index <= alphabet {
            if self.tree[index] > self.total { return Err("tree invariant"); }
            self.tree[index].checked_add(1).ok_or("tree overflow")?;
            index += index & index.wrapping_neg();
        }
        Ok(())
    }

    fn post_increment_total(&self, token: usize, alphabet: usize) -> Result<u32, &'static str> {
        let total = self.total.checked_add(1).ok_or("total overflow")?;
        if total != RESCALE { return Ok(total); }
        self.counts[..alphabet].iter().enumerate().try_fold(0u32, |sum, (index, &count)| {
            let increment = u32::from(index == token);
            let count = u32::from(count).checked_add(increment).ok_or("count overflow")?;
            sum.checked_add((count + 1) / 2).ok_or("rescale sum overflow")
        })
    }

    // root/localを両方検査した後だけ更新する。
    fn commit_increment(&mut self, token: usize, alphabet: usize) -> bool {
        self.counts[token] += 1;
        self.total += 1;
        let mut index = token + 1;
        while index <= alphabet {
            self.tree[index] += 1;
            index += index & index.wrapping_neg();
        }
        if self.total == RESCALE {
            for count in &mut self.counts[..alphabet] { *count = (*count + 1) / 2; }
            self.rebuild(alphabet);
            true
        } else { false }
    }
}

pub(crate) struct ContextModel {
    alphabet: usize,
    root: Frequency,
    scale: PriorScale,
    locals: Vec<Frequency>,
    #[cfg(model_audit)]
    rescales: (u64, u64),
}

impl ContextModel {
    pub(crate) fn new(alphabet: usize, keys: usize) -> Result<Self, &'static str> {
        if !(1..=MAX_ALPHABET).contains(&alphabet) { return Err("alphabet out of bounds"); }
        if !(1..=4096).contains(&keys) { return Err("key count out of bounds"); }
        let mut locals = Vec::new();
        locals.try_reserve_exact(keys).map_err(|_| "model allocation")?;
        locals.resize_with(keys, Frequency::zero);
        let mut root = Frequency::zero();
        root.counts[..alphabet].fill(1);
        root.rebuild(alphabet);
        let scale = PriorScale::new(root.total)?;
        Ok(Self { alphabet, root, scale, locals, #[cfg(model_audit)] rescales: (0, 0) })
    }

    fn local(&self, key: usize, limit: usize) -> Result<&Frequency, &'static str> {
        if limit == 0 || limit > self.alphabet { return Err("limit out of bounds"); }
        self.locals.get(key).ok_or("key out of bounds")
    }

    fn cumulative(&self, index: usize, root_prefix: u32, local_prefix: u32)
        -> Result<u32, &'static str>
    {
        let local = local_prefix.checked_mul(WEIGHT).ok_or("CDF local overflow")?;
        let prior = self.scale.floor(root_prefix)?;
        let total = (index as u32).checked_add(local)
            .and_then(|sum| sum.checked_add(prior))
            .ok_or("CDF cumulative outside bounds")?;
        if total > MAX_CDF { return Err("CDF cumulative outside bounds"); }
        Ok(total)
    }

    pub(crate) fn interval(&self, key: usize, token: usize, limit: usize)
        -> Result<(u32, u32, u32), &'static str>
    {
        let local = self.local(key, limit)?;
        if token >= limit { return Err("token out of bounds"); }
        let root_prefix = self.root.prefix(token);
        let local_prefix = local.prefix(token);
        let cumulative = self.cumulative(token, root_prefix, local_prefix)?;
        let end = self.cumulative(token + 1,
            root_prefix + u32::from(self.root.counts[token]),
            local_prefix + u32::from(local.counts[token]))?;
        let total = self.cumulative(limit, self.root.prefix(limit), local.prefix(limit))?;
        let frequency = end.checked_sub(cumulative).ok_or("CDF invariant")?;
        if frequency == 0 || end > total { return Err("CDF invariant"); }
        Ok((cumulative, frequency, total))
    }

    pub(crate) fn select(&self, key: usize, slot: u32, limit: usize)
        -> Result<(usize, u32, u32, u32), &'static str>
    {
        let local = self.local(key, limit)?;
        let total = self.cumulative(limit, self.root.prefix(limit), local.prefix(limit))?;
        if slot >= total { return Err("slot out of bounds"); }
        let (mut index, mut cumulative, mut root_prefix, mut local_prefix) = (0usize, 0u32, 0u32, 0u32);
        let mut bit = 1usize << (usize::BITS - 1 - limit.leading_zeros());
        while bit != 0 {
            let next = index + bit;
            if next <= limit {
                let candidate_root = root_prefix + self.root.tree[next];
                let candidate_local = local_prefix + local.tree[next];
                // 個別tree massではなく、候補indexまでの累積全体を丸める。
                let candidate = self.cumulative(next, candidate_root, candidate_local)?;
                if candidate <= slot {
                    index = next; cumulative = candidate;
                    root_prefix = candidate_root; local_prefix = candidate_local;
                }
            }
            bit >>= 1;
        }
        if index >= limit { return Err("selection invariant"); }
        let end = self.cumulative(index + 1,
            root_prefix + u32::from(self.root.counts[index]),
            local_prefix + u32::from(local.counts[index]))?;
        let frequency = end.checked_sub(cumulative).ok_or("selection invariant")?;
        if frequency == 0 || end > total || slot >= end { return Err("selection invariant"); }
        Ok((index, cumulative, frequency, total))
    }

    pub(crate) fn update(&mut self, key: usize, token: usize) -> Result<(), &'static str> {
        if token >= self.alphabet { return Err("token out of bounds"); }
        let local = self.locals.get_mut(key).ok_or("key out of bounds")?;
        self.root.prepare_increment(token, self.alphabet)?;
        local.prepare_increment(token, self.alphabet)?;
        let scale = PriorScale::new(self.root.post_increment_total(token, self.alphabet)?)?;
        let root_rescaled = self.root.commit_increment(token, self.alphabet);
        let local_rescaled = local.commit_increment(token, self.alphabet);
        self.scale = scale;
        #[cfg(model_audit)]
        { self.rescales.0 += u64::from(root_rescaled); self.rescales.1 += u64::from(local_rescaled); }
        #[cfg(not(model_audit))]
        let _ = (root_rescaled, local_rescaled);
        Ok(())
    }

    #[cfg(model_audit)]
    pub(crate) fn audit_counts(&self, key: Option<usize>) -> Result<&[u16], &'static str> {
        let counts = match key {
            Some(key) => &self.locals.get(key).ok_or("key out of bounds")?.counts,
            None => &self.root.counts,
        };
        Ok(&counts[..self.alphabet])
    }

    #[cfg(model_audit)]
    pub(crate) fn audit_rescales(&self) -> (u64, u64) { self.rescales }
}


