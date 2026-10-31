//! 独立wire生成で全可変・high/low・最後の履歴と破損を確認するE2E診断。
#[allow(dead_code)]
#[path = "compact_codec.rs"]
mod new;
#[allow(dead_code)]
#[path = "codec.rs"]
mod old;

struct Bits {
    data: Vec<u8>,
    position: usize,
}
impl Bits {
    fn bit(&mut self, value: usize) {
        if self.position.is_multiple_of(8) {
            self.data.push(0);
        }
        self.data[self.position / 8] |= (value as u8) << (7 - self.position % 8);
        self.position += 1;
    }
    fn width(&mut self, value: usize, width: usize) {
        for shift in (0..width).rev() {
            self.bit((value >> shift) & 1);
        }
    }
}
fn reverse(history: usize) -> usize {
    let mut result = 0;
    for digit in 0..5 {
        result |= ((history >> (2 * digit)) & 3) << (2 * (4 - digit));
    }
    result
}
fn uniform(k: usize) -> [u16; 4] {
    let mut f = [0; 4];
    for (i, v) in f.iter_mut().enumerate().take(k) {
        *v = (32768 / k + usize::from(i < 32768 % k)) as u16;
    }
    f
}
fn pure(k: usize, dominant: usize) -> [u16; 4] {
    let mut f = [0; 4];
    f[..k].fill(2);
    f[dominant] = 32768 - 2 * (k as u16 - 1);
    f
}
fn node(bits: &mut Bits, depth: usize, path: usize, k: usize, kind: usize) {
    if depth < 5 {
        bits.bit(1);
        if depth == 0 {
            bits.bit(usize::from(kind == 3 || kind == 5));
        }
        for digit in 0..4 {
            node(bits, depth + 1, path | (digit << (2 * depth)), k, kind);
        }
    } else if kind == 7 && path == 1023 {
        bits.bit(1);
    } else if kind == 1 || ((kind == 4 || kind == 5) && path != if kind == 4 { 1023 } else { 1 }) {
        bits.bit(0);
        bits.bit(1);
        bits.bit(1);
    } else {
        bits.bit(0);
        bits.bit(1);
        bits.bit(0);
        let dominant = if kind == 6 && k == 3 && path == 1023 {
            3
        } else if kind == 4 || kind == 5 {
            0
        } else {
            path % k
        };
        bits.width(dominant, if k == 2 { 1 } else { 2 });
    }
}
fn model(header: &[u8], kind: usize) -> Result<Vec<u8>, String> {
    let mut bits = Bits {
        data: Vec::new(),
        position: 0,
    };
    bits.data
        .try_reserve_exact(1 << 20)
        .map_err(|_| "wire allocation")?;
    for root in 0..852 {
        let included = kind != 0 && (!(kind == 4 || kind == 5) || root == 851);
        bits.bit(usize::from(included));
        if included {
            node(&mut bits, 0, 0, root % 3 + 2, kind);
        }
    }
    if bits.data.len() > 1 << 20 {
        return Err("fixture model bound".into());
    }
    let mut result = header.to_vec();
    result[1..5].copy_from_slice(&(bits.position as u32).to_le_bytes());
    result.extend_from_slice(&bits.data);
    Ok(result)
}
fn rejected(bytes: &[u8]) -> Result<(), String> {
    let a = old::packet::Forest::parse(bytes).err();
    let b = new::packet::Forest::parse(bytes).err();
    if a.is_none() || a != b {
        return Err("model rejection mismatch".into());
    }
    Ok(())
}
fn execute() -> Result<(), String> {
    let raw = vec![65; old::MAX_INPUT];
    let (frame, stats) = old::encode(&raw)?;
    if stats.method != 1 {
        return Err("fixture header method".into());
    }
    let start = old::HEADER + stats.alphabet;
    let header = &frame[start..start + 134];
    let mut comparisons = 0usize;
    let mut rejected_cases = 0usize;
    let mut maximum_capacity = 0usize;
    let mut maximum_parse_transient = 0usize;
    for kind in 0..6 {
        let bytes = model(header, kind)?;
        let before = old::packet::Forest::parse(&bytes)?;
        let after = new::packet::Forest::parse(&bytes)?;
        maximum_capacity = maximum_capacity.max(after.capacity_bytes());
        maximum_parse_transient =
            maximum_parse_transient.max(after.parse_dispatch_peak + after.parse_reader_capacity);
        let mut varying = 0;
        for root in 0..852 {
            let c = root / (142 * 3);
            let node = (root / 3) % 142;
            let k = root % 3 + 2;
            let mut differs = false;
            let first = after.lookup(c, node, k, 0)?;
            for history in 0..1024 {
                let path = if kind == 3 || kind == 5 {
                    reverse(history)
                } else {
                    history
                };
                let expected = match kind {
                    0 | 1 => uniform(k),
                    2 | 3 => pure(k, path % k),
                    4 if root == 851 && path == 1023 => pure(k, 0),
                    5 if root == 851 && path == 1 => pure(k, 0),
                    _ => uniform(k),
                };
                if before.lookup(c, node, k, history as u16)? != expected
                    || after.lookup(c, node, k, history as u16)? != expected
                {
                    return Err(format!("CDF geometry {kind}/{root}/{history}"));
                }
                differs |= expected != first;
                comparisons += 1;
            }
            varying += usize::from(differs);
        }
        let expected = match kind {
            2 | 3 => 852,
            4 | 5 => 1,
            _ => 0,
        };
        if varying != expected {
            return Err("varying coverage".into());
        }
        if varying == 852
            && after.capacity_bytes() != 872448 * 8 + std::mem::size_of::<new::packet::Forest>()
        {
            return Err("maximum capacity mismatch".into());
        }
        for end in [0, 1, 4, 5, 127, 133, bytes.len() - 1] {
            rejected(&bytes[..end])?;
            rejected_cases += 1;
        }
        let mut trailing = bytes.clone();
        trailing.push(0);
        rejected(&trailing)?;
        rejected_cases += 1;
        // 直前の失敗後も同じ正常モデルが独立して解析できる。
        if new::packet::Forest::parse(&bytes)?.lookup(0, 0, 2, 0)? != before.lookup(0, 0, 2, 0)? {
            return Err("model recovery".into());
        }
    }
    for kind in [6, 7] {
        rejected(&model(header, kind)?)?;
        rejected_cases += 1;
    }
    if comparisons != 6 * 872448 || rejected_cases != 50 {
        return Err("coverage extent".into());
    }
    println!(
        "{{\"valid_models\":6,\"CDF_comparisons\":{comparisons},\"rejected_cases\":{rejected_cases},\"all_varying_roots\":852,\"high_low_verified\":true,\"last_group_last_history_verified\":true,\"maximum_capacity\":{maximum_capacity},\"maximum_parse_transient\":{maximum_parse_transient},\"exact\":true}}"
    );
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("forest_boundary: {error}");
        std::process::exit(1);
    }
}
