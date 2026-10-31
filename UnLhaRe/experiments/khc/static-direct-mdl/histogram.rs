pub const RA: usize = 257;
pub const LA: usize = 256;
pub const RG: usize = 257;
pub const LG: usize = 9;
pub const RR: usize = 1 + RG * 5;
pub const LR: usize = 1 + LG * 5;
pub fn exponent(value: usize) -> usize { if value == 0 { 0 } else { usize::BITS as usize - 1 - value.leading_zeros() as usize } }
pub fn length_bucket(length: usize) -> usize { match length { 1 => 0, 2 => 1, 3..=4 => 2, _ => 3 } }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hist {
    pub rank: Vec<u32>, pub length: Vec<u32>, pub tokens: [u64; 2],
    pub runs: u64, pub escapes: u64, pub grammar: u64,
}
impl Hist {
    pub fn new() -> Self { Self { rank: vec![0; RR*RA], length: vec![0; LR*LA], tokens: [0;2], runs: 0, escapes: 0, grammar: 0xcbf29ce484222325 } }
    pub fn record(&mut self, component: usize, symbol: usize, context: usize, bucket: usize, token: usize, limit: usize, previous_rank: usize) -> Result<(), String> {
        if component > 1 || symbol >= RG || bucket >= 4 || token >= limit || limit == 0 { return Err("hist event range".into()); }
        let (data, alphabet, groups, group) = if component == 0 { (&mut self.rank, RA, RG, symbol) } else { (&mut self.length, LA, LG, context) };
        if group >= groups || limit > alphabet { return Err("hist group/limit".into()); }
        for row in [0, 1+group, 1+groups+group*4+bucket] { let cell = &mut data[row*alphabet+token]; *cell = cell.checked_add(1).ok_or("hist count overflow")?; }
        self.tokens[component] = self.tokens[component].checked_add(1).ok_or("token overflow")?;
        let key = if component == 0 { symbol*4+previous_rank.min(3) } else { symbol*9+context };
        for value in [component,key,token,limit] { self.grammar = (self.grammar ^ value as u64).wrapping_mul(0x100000001b3); }
        Ok(())
    }
    pub fn done(&mut self, escapes: usize) -> Result<(), String> { self.runs=self.runs.checked_add(1).ok_or("run overflow")?; self.escapes=self.escapes.checked_add(escapes as u64).ok_or("escape overflow")?; Ok(()) }
    pub fn validate(&self) -> Result<(), String> {
        for (data, alphabet, groups, component) in [(&self.rank, RA, RG,0), (&self.length, LA, LG,1)] {
            if data.len() != (1+groups*5)*alphabet { return Err("hist extent".into()); }
            let total: u64=data[..alphabet].iter().map(|&x|x as u64).sum();
            if total != self.tokens[component] || total != self.runs { return Err("hist total".into()); }
            for token in 0..alphabet {
                let groups_sum: u64=(0..groups).map(|g|data[(1+g)*alphabet+token] as u64).sum();
                if groups_sum != data[token] as u64 { return Err("hist global/group".into()); }
                for g in 0..groups {
                    let children: u64=(0..4).map(|b|data[(1+groups+g*4+b)*alphabet+token] as u64).sum();
                    if children != data[(1+g)*alphabet+token] as u64 { return Err("hist group/child".into()); }
                }
            }
        }
        Ok(())
    }
}
