#![allow(dead_code)]
use std::io::Write;
#[path = "cts_model.rs"]
mod heavy;
type Result<T> = std::result::Result<T, String>;
const Q: u64 = 65536;
const CAP: u32 = 562_036_803;
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values.try_reserve_exact(length).map_err(|e| e.to_string())?;
    values.resize(length, value);
    Ok(values)
}
fn oracle(a: u64, b: u64, d: u64) -> Result<u64> {
    if d == 0 { return Err("zero denominator".into()); }
    let n = u128::from(a) * u128::from(b);
    if n > u128::from(u64::MAX) { return Err("product overflow".into()); }
    Ok((n / u128::from(d)) as u64)
}
fn kt_oracle(zero: u32, one: u32) -> Result<u64> {
    let sum = u64::from(zero) + u64::from(one);
    if sum > u64::from(u32::MAX) { return Err("CTS node total overflow".into()); }
    if sum > u64::from(CAP) { return Err("CTS node observation cap exceeded".into()); }
    let numerator = u128::from(Q) * (2 * u128::from(zero) + 1);
    let d = 2 * (u128::from(sum) + 1);
    Ok(((numerator / d) as u64).clamp(1, Q - 1))
}
fn error_code(error: &str) -> Result<u8> {
    match error {
        "zero denominator" => Ok(1),
        "product overflow" => Ok(2),
        "CTS node total overflow" => Ok(3),
        "CTS node observation cap exceeded" => Ok(4),
        _ => Err(format!("unexpected numeric error: {error}")),
    }
}
fn record(output: &mut impl Write, count: &mut usize, actual: Result<u64>, expected: Result<u64>) -> Result<()> {
    if actual != expected {
        return Err(format!("numeric mismatch at record {count}: {actual:?} != {expected:?}"));
    }
    let (a, ae) = match actual { Ok(v) => (v, 0), Err(e) => (0, error_code(&e)?) };
    let (e, ee) = match expected { Ok(v) => (v, 0), Err(e) => (0, error_code(&e)?) };
    output.write_all(&a.to_le_bytes()).map_err(|e| e.to_string())?;
    output.write_all(&e.to_le_bytes()).map_err(|e| e.to_string())?;
    output.write_all(&[ae, ee]).map_err(|e| e.to_string())?;
    *count += 1;
    Ok(())
}
fn rng(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}
fn run() -> Result<()> {
    let argv: Vec<_> = std::env::args_os().collect();
    if argv.len() != 2 { return Err("usage: numeric-audit <new-records-output>".into()); }
    let file = std::fs::OpenOptions::new().create_new(true).write(true).open(&argv[1]).map_err(|e| e.to_string())?;
    let mut output = std::io::BufWriter::new(file);
    let table = heavy::audit_kt_table()?;
    let mut records = 0usize;
    let mut ratio_cases = 0usize;
    for d in 1..=Q {
        let bound = Q * d;
        for n in [0, d - 1, d, bound / 2 - 1, bound / 2, bound / 2 + 1, bound - 1, bound, bound + 1, u64::MAX] {
            record(&mut output, &mut records, table.ratio(n, 1, d).map_err(str::to_string), oracle(n, 1, d))?;
            ratio_cases += 1;
        }
    }
    let mut state = 0x9e3779b97f4a7c15u64;
    for i in 0..65536 {
        let x = rng(&mut state);
        let y = rng(&mut state);
        let z = rng(&mut state);
        let (a, b, d) = match i % 4 {
            0 => (x, 1, z | 1),
            1 => (x, y, z | 1),
            2 => (x & 0xffffffff, y & 0xffffffff, (z & 0xffff) + 1),
            _ => (x, 0, if i % 8 == 3 { 0 } else { z | 1 }),
        };
        record(&mut output, &mut records, table.ratio(a, b, d).map_err(str::to_string), oracle(a, b, d))?;
        ratio_cases += 1;
    }
    for (a,b,d) in [(u64::MAX,2,0),(u64::MAX,2,1),(u64::MAX,2,Q),(0,0,0),(0,0,1),(Q,1,1),(Q*Q,1,Q),(Q*Q+1,1,Q)] {
        record(&mut output, &mut records, table.ratio(a,b,d).map_err(str::to_string), oracle(a,b,d))?;
        ratio_cases += 1;
    }
    let mut kt_cases = 0usize;
    for total in 0..=65535u32 {
        for zero in [0, total/2, total] {
            let one = total-zero;
            record(&mut output, &mut records, table.kt(zero,one).map(|p| p.0).map_err(str::to_string), kt_oracle(zero,one))?;
            kt_cases += 1;
        }
    }
    for total in [65536u32,65537,1_000_000,CAP-1,CAP,CAP+1,u32::MAX] {
        for zero in [0,total/2,total] {
            record(&mut output, &mut records, table.kt(zero,total-zero).map(|p| p.0).map_err(str::to_string), kt_oracle(zero,total-zero))?;
            kt_cases += 1;
        }
    }
    for (zero,one) in [(u32::MAX,1),(u32::MAX,u32::MAX),(CAP,CAP),(CAP/2,CAP/2)] {
        record(&mut output, &mut records, table.kt(zero,one).map(|p| p.0).map_err(str::to_string), kt_oracle(zero,one))?;
        kt_cases += 1;
    }
    let mut model_cases = 0usize;
    for weight in [0,1,Q/2,Q-1,Q] {
        for kt in [1,Q/2,Q-1] {
            for child in [1,Q/2,Q-1] {
                let sum = u128::from(weight)*u128::from(kt)+u128::from(Q-weight)*u128::from(child);
                let (zero,remainder)=heavy::mixture_snapshot(weight,kt,child)?;
                record(&mut output,&mut records,Ok(zero),Ok((sum/u128::from(Q)) as u64))?;
                record(&mut output,&mut records,Ok(u64::from(remainder)),Ok(u64::from(sum%u128::from(Q)!=0)))?;
                model_cases += 2;
                for bit in [false,true] {
                    let pk=if bit {Q-kt}else{kt};
                    let pc=if bit {Q-child}else{child};
                    let observed=u128::from(weight)*u128::from(pk)+u128::from(Q-weight)*u128::from(pc);
                    let expected=(observed+u128::from(Q)-1)/u128::from(Q);
                    let ceiling=heavy::cached_ceiling(weight,weight,pk,pc,zero,remainder,bit)?;
                    record(&mut output,&mut records,Ok(ceiling),Ok(expected as u64))?;
                    let posterior=heavy::posterior_ratio(&table,weight,pk,ceiling)?;
                    record(&mut output,&mut records,Ok(posterior),Ok((u128::from(weight)*u128::from(pk)/expected) as u64))?;
                    model_cases += 2;
                    for after in [1u64,2,65535,65536,u64::from(CAP)] {
                        let alpha=table.ratio(Q,1,after+1).map_err(str::to_string)?.max(1);
                        let retained=Q-2*alpha;
                        let next=heavy::next_weight(&table,alpha,retained,posterior)?;
                        let expected_alpha=(u128::from(Q)/u128::from(after+1)).max(1);
                        record(&mut output,&mut records,Ok(alpha),Ok(expected_alpha as u64))?;
                        record(&mut output,&mut records,Ok(next),Ok((expected_alpha+u128::from(retained)*u128::from(posterior)/u128::from(Q)) as u64))?;
                        if !(1..=Q/2).contains(&alpha) || !(alpha..=Q-alpha).contains(&next) {
                            return Err("Q16 switch weight bounds differ".into());
                        }
                        model_cases += 2;
                    }
                }
            }
        }
    }
    output.flush().map_err(|e| e.to_string())?;
    let (prediction_bytes,node_bytes)=heavy::Model::audit_layout();
    if prediction_bytes != 544 || node_bytes != 16 || table.audit_bytes()!=524296 {
        return Err("Q16 Model layout/storage changed".into());
    }
    println!("{{\"records\":{records},\"record_bytes\":18,\"ratio_cases\":{ratio_cases},\"kt_cases\":{kt_cases},\"model_cases\":{model_cases},\"table_bytes\":524296,\"prediction_bytes\":{prediction_bytes},\"node_bytes\":{node_bytes}}}");
    Ok(())
}
fn main() {
    if let Err(error)=run() { eprintln!("{error}");std::process::exit(1); }
}
