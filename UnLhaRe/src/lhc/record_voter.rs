//! 既に完成したbyte pairの再出現距離だけを使う幅state。現在byteの予測後にobserve。
pub const MAX_RAW: usize = 1 << 20;
pub const BOUND: usize = 65536 * 4 + 1025 * 4 + 128;
pub struct Voter {
    last: Vec<u32>,
    votes: [u32; 1025],
    best: usize,
    maximum: u32,
    previous: Option<u8>,
    position: usize,
    pub events: usize,
    pub matched: usize,
    pub eligible: usize,
    pub changes: usize,
}
impl Voter {
    pub fn new() -> Result<Self, String> {
        let mut last = Vec::new();
        last.try_reserve_exact(65536)
            .map_err(|_| "vote allocation")?;
        if last.capacity() > 65536 {
            return Err("vote capacity".into());
        }
        last.resize(65536, u32::MAX);
        Ok(Self {
            last,
            votes: [0; 1025],
            best: 1,
            maximum: 0,
            previous: None,
            position: 0,
            events: 0,
            matched: 0,
            eligible: 0,
            changes: 0,
        })
    }
    pub fn best(&self) -> usize {
        self.best
    }
    pub fn votes(&self) -> &[u32; 1025] {
        &self.votes
    }
    pub fn positions(&self) -> &[u32] {
        &self.last
    }
    pub fn capacity(&self) -> usize {
        self.last.capacity() * 4 + std::mem::size_of::<Self>()
    }
    pub fn observe(&mut self, byte: u8) -> Result<(), String> {
        if self.position >= MAX_RAW {
            return Err("vote input bound".into());
        }
        if let Some(previous) = self.previous {
            let key = (usize::from(previous) << 8) | usize::from(byte);
            if key != 0 && key != 65535 {
                self.events += 1;
                let old = self.last[key];
                if old != u32::MAX {
                    let d = self
                        .position
                        .checked_sub(old as usize)
                        .ok_or("vote position")?;
                    if d == 0 {
                        return Err("vote nonprogress".into());
                    }
                    self.matched += 1;
                    if d <= 1024 {
                        let value = self.votes[d].checked_add(1).ok_or("vote overflow")?;
                        self.votes[d] = value;
                        self.eligible += 1;
                        if value > self.maximum || (value == self.maximum && d < self.best) {
                            if self.best != d {
                                self.changes += 1
                            }
                            self.best = d;
                            self.maximum = value;
                        }
                    }
                }
                self.last[key] = self.position as u32;
            }
        }
        self.previous = Some(byte);
        self.position += 1;
        Ok(())
    }
}
