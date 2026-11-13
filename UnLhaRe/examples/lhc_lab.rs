//! 実験 codec 専用。既存の LHA 作成・展開 API には接続しない。
#[path = "../experiments/khc/bench_clock.rs"]
mod bench_clock;
#[path = "../experiments/khc/mod.rs"]
mod lhc;
#[path = "../experiments/khc/solid.rs"]
mod solid;

use clap::{Parser, ValueEnum};
use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

#[derive(Clone, Copy, ValueEnum)]
enum Mode {
    Encode,
    Decode,
    /// 固定frameを繰り返し復号し、照合・解放を含むbatch時間を測る。
    DecodeBench,
    Bench,
    /// 研究用groupの名前・境界を検証して、単一frameで履歴を共有する。
    GroupBench,
    /// 圧縮サイズのみを評価し、decode・solid entry照合・決定性を確認する。時間は計測しない。
    GroupSizeScreen,
    /// 検証済みの研究用group全体を圧縮する。
    GroupEncode,
    /// groupを検証後、各fileの本文を表順にstdoutへ連結出力する。
    GroupDecode,
    /// 圧縮groupを検証し、名前と元サイズをJSON配列で返す。
    GroupList,
    /// 単発の区間計測。通常encodeとの出力一致を照合し、計測値をJSONへ返す。
    Profile,
    /// 診断用parse workを無効にしてphase時間とnested Rep sampleだけを採取する。
    ProfileTiming,
    /// BT5 beamの選択MatchをJSONへ記録する開発用診断。
    MatchTrace,
    /// Rep解決済み距離で編集付きcopy segmentの機会を上限評価するscreen。
    RepPatchScreen,
    /// SA近傍K候補が選択Matchを保持できる割合を測る開発用screen。
    MatchCoverage,
    /// 選択済みcopy tokenの長さ別内部位置を数える、出力不変の診断screen。
    TokenCoverageScreen,
    /// Standard／lazy LZ／BT5 Beamの実token列を同一入力位置で比較する診断。
    ParserCensus,
    /// 通常Beam Range bitstreamと一致することを確認し、実plan境界の累積Range状態を採取する。
    BeamPlanRangeCensus,
    /// 同じtoken列で適応更新を窓ごとに遅延し、frameサイズだけを測る。
    AdaptFreezeScreen,
    /// greedy BT5 parseの固定field grammarに対する理想静的entropy下限を測る。
    GreedyStaticEntropyScreen,
    /// RepなしLiteral／絶対距離CopyをBT5 frontier上で一度だけDPする理想長screen。
    FrontierLiteralCopyDpScreen,
    /// 同じBT5 frontierの各matchで合法な全prefix長を区間DPする理想長screen。
    FrontierLiteralCopyAllLengthsDpScreen,
    /// Rep履歴を運ぶBT5 frontier DPの理想長screen。実frameは作らない。
    RepFrontierDpScreen,
    /// 選択済みBT5 token列で直近Rep距離差分文法の実range payloadサイズを測る。
    DistanceDeltaScreen,
    /// 現行Range復号が1 bitあたり何byte正規化するかを数える。速度比較には使わない。
    RenormCensus,
    /// solid groupのファイル境界ごとに、parser別の終端payload増分を測る。
    BoundaryCensus,
    /// exact token spliceと共有stateのsingle-pass hybridを実サイズ・時間・復号で確認する。
    HybridSpliceScreen,
    /// content-order groupの隣接2 file全域をLazy parseへ置き換える固定screen。
    HybridContentOrderRegionScreen,
    /// Standardの固定token parseをmethod-2 Rep4 grammarへ再符号化するsize screen。
    StandardRepReplayScreen,
    /// 固定Canterburyの実BT5候補とBlended価格でFSGの単調コスト前提を検査する。
    FsgPriceMonotonicityScreen,
    /// 固定Canterburyの正解token列を再生し、coder後に残る楽観的時間予算を測る。
    TokenReplayBudgetScreen,
    /// ptt5の216-byte fax走査線転置を含む固定Canterbury E2E/paired speed screen。
    Ptt5TransposeScreen,
    /// ptt5転置と1 MiB辞書窓の相互作用を固定Canterburyで検証するscreen。
    Ptt5TransposeWindowScreen,
    /// 固定groupの頻出byte pairを可逆辞書置換するresearch screen。
    BytePairDictionaryScreen,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Algorithm {
    Standard,
    Lz,
    Beam,
    Context,
    Auto,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum BeamModel {
    Current,
    Warm,
    Blended,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum BeamMatches {
    Nearest,
    PricedTie,
    Bt4,
    Bt5,
    Exact4,
    Hybrid,
    R4,
    R5,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum EntropyBackend {
    Range,
    Rans,
}

#[derive(Parser)]
#[command(
    about = "Unstable LHC research codec; binary output goes to stdout, never an archive path"
)]
struct Args {
    #[arg(value_enum)]
    mode: Mode,
    input: PathBuf,
    #[arg(long, default_value_t = 8)]
    dictionary_mib: usize,
    #[arg(long, value_enum, default_value_t = Algorithm::Lz)]
    algorithm: Algorithm,
    /// 研究用。rANSは適応binary decisionを約512KiBごとのplan境界でまとめて符号化する。
    #[arg(long, value_enum, default_value_t = EntropyBackend::Range)]
    entropy_backend: EntropyBackend,
    #[arg(long, default_value_t = 4, value_parser = parse_beam_width)]
    beam_width: usize,
    #[arg(long, default_value_t = 512, value_parser = parse_beam_block)]
    beam_block: usize,
    #[arg(long, value_enum, default_value_t = BeamModel::Current)]
    beam_model: BeamModel,
    #[arg(long, value_enum, default_value_t = BeamMatches::Nearest)]
    beam_matches: BeamMatches,
    #[arg(long)]
    beam_fixed_boundaries: bool,
    #[arg(long, default_value_t = 1, value_parser = parse_beam_batch_blocks)]
    beam_batch_blocks: usize,
    #[arg(long)]
    beam_greedy_seeds: bool,
    #[arg(long)]
    beam_rep_diverse_third_parent: bool,
    /// 研究用。greedy先行parseのRep履歴で単一状態DPを価格付けする。
    #[arg(long)]
    beam_fixed_rep_history: bool,
    /// 研究用。直前履歴をliteral再学習し、独立Range chunkでBeam圧縮する。
    #[arg(long)]
    beam_history_seeded: bool,
    /// 研究用。0は従来のBT、64はnice lengthで木の残り探索を打ち切る。
    #[arg(long, default_value_t = 0, value_parser = parse_bt_nice_len)]
    bt_nice_len: usize,
    #[arg(long, default_value_t = 5, value_parser = clap::value_parser!(u32).range(1..=100))]
    repeats: u32,
    #[arg(long, default_value_t = 32, value_parser = clap::value_parser!(u32).range(1..=1000))]
    decode_iterations: u32,
    /// profile-timingでRep長計測sampleに含める位置の16-byte residue。
    #[arg(long, value_parser = parse_rep_sample_offset)]
    rep_sample_offset: Option<usize>,
    /// profile-timingのRep長計測位置sample stride。
    #[arg(long, value_parser = parse_rep_sample_stride)]
    rep_sample_stride: Option<usize>,
}

fn parse_beam_width(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|n| matches!(n, 1 | 2 | 3 | 4 | 8 | 16))
        .ok_or("beam width must be 1, 2, 3, 4, 8, or 16")
}

fn parse_beam_block(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|n| (64..=8192).contains(n) && n.is_power_of_two())
        .ok_or("beam block must be a power of two from 64 through 8192")
}

fn parse_bt_nice_len(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|n| matches!(n, 0 | 64))
        .ok_or("BT nice length must be 0 or 64")
}

fn parse_beam_batch_blocks(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|n| (1..=4).contains(n))
        .ok_or("beam batch blocks must be from 1 through 4")
}

fn verify_history_seeded_failure_cases(
    frame: &[u8],
    options: lhc::Options,
) -> Result<(), Box<dyn std::error::Error>> {
    if frame.get(9) != Some(&4) || frame.len() < lhc::HEADER + 4 {
        return Err("history-seeded checks require a complete mode-4 chunk count".into());
    }
    let payload = &frame[lhc::HEADER..];
    let chunk_count = u32::from_le_bytes(payload[..4].try_into()?);
    let output_size = u64::from_le_bytes(frame[16..24].try_into()?);
    let mut malformed = Vec::new();

    let mut bad_header_crc = frame.to_vec();
    bad_header_crc[36] ^= 1;
    malformed.push(("header CRC", bad_header_crc));

    malformed.push(("truncated frame", frame[..frame.len() - 1].to_vec()));
    let mut trailing = frame.to_vec();
    trailing.push(0);
    malformed.push(("trailing frame byte", trailing));

    let mut wrong_count = frame.to_vec();
    wrong_count[lhc::HEADER] ^= 1;
    malformed.push(("wrong chunk count", wrong_count));

    if chunk_count > 0 {
        if payload.len() < 12 {
            return Err("history-seeded chunk header is truncated".into());
        }
        let mut empty_chunk = frame.to_vec();
        empty_chunk[lhc::HEADER + 4..lhc::HEADER + 8].fill(0);
        malformed.push(("zero-length chunk", empty_chunk));

        let mut oversized_chunk = frame.to_vec();
        oversized_chunk[lhc::HEADER + 8..lhc::HEADER + 12].copy_from_slice(&u32::MAX.to_le_bytes());
        malformed.push(("overflowing chunk length", oversized_chunk));
    }

    let truncated_payload = lhc::frame_with_payload(frame, &payload[..payload.len() - 1])?;
    malformed.push(("truncated chunk stream", truncated_payload));

    for (label, candidate) in malformed {
        if lhc::decode(&candidate, options, &mut || false).is_ok() {
            return Err(format!("malformed history-seeded frame accepted: {label}").into());
        }
    }

    let limited = lhc::Options {
        max_output: 0,
        ..options
    };
    let limited_result = lhc::decode(frame, limited, &mut || false);
    if output_size == 0 {
        if !limited_result.is_ok_and(|output| output.is_empty()) {
            return Err("history-seeded decode rejected empty output at a zero limit".into());
        }
    } else if limited_result.is_ok() {
        return Err("history-seeded decode ignored the output limit".into());
    }
    let memory_limited = lhc::Options {
        memory_budget: 1,
        ..options
    };
    if lhc::decode(frame, memory_limited, &mut || false).is_ok() {
        return Err("history-seeded decode ignored the memory limit".into());
    }
    if lhc::decode(frame, options, &mut || true).is_ok() {
        return Err("history-seeded decode ignored cancellation".into());
    }
    Ok(())
}

fn parse_rep_sample_offset(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|offset| *offset < 16)
        .ok_or("Rep sample offset must be from 0 through 15")
}

fn parse_rep_sample_stride(value: &str) -> Result<usize, &'static str> {
    value
        .parse::<usize>()
        .ok()
        .filter(|stride| matches!(stride, 1 | 16))
        .ok_or("Rep sample stride must be 1 or 16")
}

fn group_listing(entries: &[solid::Entry<'_>]) -> serde_json::Value {
    serde_json::json!(
        entries
            .iter()
            .map(|entry| { serde_json::json!({"name": entry.name, "bytes": entry.data.len()}) })
            .collect::<Vec<_>>()
    )
}

fn selected_token_interior_counts(
    input_len: usize,
    selected: &[lhc::SelectedToken],
) -> Result<[(usize, usize); 4], &'static str> {
    const THRESHOLDS: [usize; 4] = [32, 64, 128, 256];

    let mut counts = [0usize; 4];
    let mut expected_offset = 0usize;
    for token in selected {
        let offset = usize::try_from(token.offset).map_err(|_| "token offset overflow")?;
        let length = usize::try_from(token.length).map_err(|_| "token length overflow")?;
        let end = offset.checked_add(length).ok_or("token end overflow")?;
        if offset != expected_offset || length == 0 || end > input_len || token.kind > 3 {
            return Err("selected token trace is invalid or non-contiguous");
        }
        if token.kind != 0 {
            for (index, threshold) in THRESHOLDS.iter().copied().enumerate() {
                if length >= threshold {
                    counts[index] = counts[index]
                        .checked_add(length - 1)
                        .ok_or("token coverage overflow")?;
                }
            }
        }
        expected_offset = end;
    }
    if expected_offset != input_len {
        return Err("selected token trace does not cover the input");
    }

    Ok(std::array::from_fn(|index| {
        (THRESHOLDS[index], counts[index])
    }))
}

fn static_entropy_bits(histogram: &BTreeMap<u64, u64>) -> f64 {
    let total = histogram.values().copied().sum::<u64>();
    if total == 0 {
        return 0.0;
    }
    histogram
        .values()
        .copied()
        .map(|count| count as f64 * (total as f64 / count as f64).log2())
        .sum()
}

fn greedy_static_field_entropy(
    input: &[u8],
    selected: &[lhc::SelectedToken],
) -> Result<serde_json::Value, &'static str> {
    greedy_static_field_entropy_with_rep_capacity(input, selected, 4)
}

fn greedy_static_field_entropy_with_rep_capacity(
    input: &[u8],
    selected: &[lhc::SelectedToken],
    rep_capacity: usize,
) -> Result<serde_json::Value, &'static str> {
    if !(1..=256).contains(&rep_capacity) {
        return Err("Rep index capacity is out of range");
    }
    // field/context/symbolごとの出現数。context別頻度表を無料にして、実現frameではなく
    // 楽観的な下限を測る。
    let mut counts = BTreeMap::<(u8, u8, u64), u64>::new();
    let mut expected_offset = 0usize;
    let mut previous_match = false;
    for token in selected {
        let offset = usize::try_from(token.offset).map_err(|_| "token offset overflow")?;
        let length = usize::try_from(token.length).map_err(|_| "token length overflow")?;
        let distance = usize::try_from(token.distance).map_err(|_| "token distance overflow")?;
        let rep_index = usize::from(token.rep_index);
        let end = offset.checked_add(length).ok_or("token end overflow")?;
        if offset != expected_offset || length == 0 || end > input.len() || token.kind > 3 {
            return Err("greedy token trace is invalid or non-contiguous");
        }
        match token.kind {
            0 if length == 1 && distance == 0 && rep_index == 0 => {}
            1 if length == 1 && distance > 0 && distance <= offset && rep_index == 0 => {}
            2 if length >= 2 && distance > 0 && distance <= offset && rep_index < rep_capacity => {}
            3 if length >= 3 && distance > 0 && distance <= offset && rep_index == 0 => {}
            _ => return Err("greedy token fields are out of range"),
        }
        if token.kind >= 1 {
            for index in 0..length {
                if input[offset + index] != input[offset + index - distance] {
                    return Err("greedy copy token does not reconstruct the input");
                }
            }
        }

        let token_context = (usize::from(previous_match) * 4 + (offset & 3)) as u8;
        *counts
            .entry((0, token_context, u64::from(token.kind)))
            .or_default() += 1;
        if token.kind == 2 {
            *counts
                .entry((1, token_context, rep_index as u64))
                .or_default() += 1;
        }
        if matches!(token.kind, 2 | 3) {
            // Token kind and token context are both known before this field is read.
            let context = token_context * 2 + u8::from(token.kind == 3);
            *counts.entry((2, context, length as u64)).or_default() += 1;
        }
        if token.kind == 3 {
            let length_context = match length {
                0..=4 => 0,
                5..=8 => 1,
                9..=16 => 2,
                _ => 3,
            };
            let context = token_context * 4 + length_context;
            *counts.entry((3, context, distance as u64)).or_default() += 1;
        }
        if token.kind == 0 {
            let literal_context = if offset == 0 {
                32
            } else {
                usize::from(previous_match) * 16 + usize::from(input[offset - 1] >> 4)
            } as u8;
            *counts
                .entry((4, literal_context, u64::from(input[offset])))
                .or_default() += 1;
        }
        previous_match = token.kind != 0;
        expected_offset = end;
    }
    if expected_offset != input.len() {
        return Err("greedy token trace does not cover the input");
    }

    let mut field_bits = [0.0f64; 5];
    let mut field_contexts = [
        BTreeMap::<u8, BTreeMap<u64, u64>>::new(),
        BTreeMap::new(),
        BTreeMap::new(),
        BTreeMap::new(),
        BTreeMap::new(),
    ];
    for (&(field, context, symbol), &count) in &counts {
        let Some(field_context) = field_contexts.get_mut(usize::from(field)) else {
            return Err("unknown static field id");
        };
        *field_context
            .entry(context)
            .or_default()
            .entry(symbol)
            .or_default() += count;
    }
    let mut fields = Vec::with_capacity(field_contexts.len());
    for (field, contexts) in field_contexts.iter().enumerate() {
        let field_name = match field {
            0 => "token_kind",
            1 => "rep_index",
            2 => "copy_length",
            3 => "match_distance",
            4 => "literal_byte",
            _ => return Err("unknown static field id"),
        };
        let mut event_count = 0u64;
        let mut alphabet_symbols = 0usize;
        for histogram in contexts.values() {
            event_count += histogram.values().copied().sum::<u64>();
            alphabet_symbols += histogram.len();
            field_bits[field] += static_entropy_bits(histogram);
        }
        fields.push(serde_json::json!({
            "field": field_name,
            "contexts_used": contexts.len(),
            "event_count": event_count,
            "observed_symbols": alphabet_symbols,
            "ideal_bits": field_bits[field],
            "ideal_bytes": field_bits[field] / 8.0,
        }));
    }
    let ideal_bits = field_bits.iter().sum::<f64>();
    let ideal_payload_bytes = (ideal_bits / 8.0).ceil() as usize;
    let ideal_frame_bytes = ideal_payload_bytes
        .checked_add(lhc::HEADER)
        .ok_or("ideal frame size overflow")?;
    Ok(serde_json::json!({
        "token_count": selected.len(),
        "rep_index_capacity": rep_capacity,
        "round_trip_verified_from_copy_distances": true,
        "ideal_entropy_bits": ideal_bits,
        "ideal_payload_bytes": ideal_payload_bytes,
        "existing_header_bytes": lhc::HEADER,
        "ideal_frame_bytes_with_existing_header": ideal_frame_bytes,
        "field_tables_costed": false,
        "coder_termination_costed": false,
        "contexts": "token kind/rep index use previous-match and output position mod 4; copy length adds token kind; match distance adds length bucket; literal uses previous-match and previous decoded byte high nibble, with a distinct first-byte context",
        "fields": fields,
        "gate_7zip_bytes": 483_599,
        "delta_from_7zip_gate_bytes": ideal_frame_bytes as i64 - 483_599,
        "gate_current_lhc_bytes": 483_130,
        "delta_from_current_lhc_bytes": ideal_frame_bytes as i64 - 483_130,
        "passes_optimistic_7zip_size_lower_bound": ideal_frame_bytes < 483_599,
    }))
}

fn reclassify_with_recent_reps(
    input: &[u8],
    selected: &[lhc::SelectedToken],
    rep_capacity: usize,
) -> Result<Vec<lhc::SelectedToken>, &'static str> {
    if !(1..=256).contains(&rep_capacity) {
        return Err("Rep history capacity is out of range");
    }
    let mut widened_trace = Vec::<lhc::SelectedToken>::new();
    widened_trace
        .try_reserve_exact(selected.len())
        .map_err(|_| "wide-Rep trace allocation failed")?;
    let mut reps = vec![1usize; rep_capacity];
    let mut expected_offset = 0usize;
    for original in selected {
        let offset = usize::try_from(original.offset).map_err(|_| "token offset overflow")?;
        let length = usize::try_from(original.length).map_err(|_| "token length overflow")?;
        let distance = usize::try_from(original.distance).map_err(|_| "token distance overflow")?;
        let end = offset.checked_add(length).ok_or("token end overflow")?;
        if offset != expected_offset || length == 0 || end > input.len() {
            return Err("wide-Rep input trace is invalid or non-contiguous");
        }
        let mut token = *original;
        match original.kind {
            0 if length == 1 && distance == 0 && original.rep_index == 0 => {}
            2 | 3 if length >= 3 && distance > 0 && distance <= offset => {
                if let Some(rep_index) = reps.iter().position(|&rep| rep == distance) {
                    token.kind = 2;
                    token.rep_index = u8::try_from(rep_index).map_err(|_| "Rep index overflow")?;
                    for at in (1..=rep_index).rev() {
                        reps[at] = reps[at - 1];
                    }
                    reps[0] = distance;
                } else {
                    token.kind = 3;
                    token.rep_index = 0;
                    for at in (1..rep_capacity).rev() {
                        reps[at] = reps[at - 1];
                    }
                    reps[0] = distance;
                }
            }
            _ => return Err("wide-Rep input trace contains an invalid token"),
        }
        widened_trace.push(token);
        expected_offset = end;
    }
    if expected_offset != input.len() {
        return Err("wide-Rep input trace coverage is invalid");
    }
    Ok(widened_trace)
}

fn write_group_data(
    input: &[u8],
    output: &mut impl Write,
) -> Result<(), Box<dyn std::error::Error>> {
    // metadata全体を検証してから最初のbyteを出す。実パスへの展開はしない。
    let entries = solid::parse(input)?;
    for entry in entries {
        output.write_all(entry.data)?;
    }
    Ok(())
}

fn decode_benchmark(
    input: &[u8],
    options: lhc::Options,
    repeats: u32,
    iterations: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    if !(1..=100).contains(&repeats) || !(1..=1000).contains(&iterations) {
        return Err("decode benchmark count out of range".into());
    }
    // warm-upは測定外。正解原文との独立照合ではなく同一frameの決定性検査。
    let expected = lhc::decode(input, options, &mut || false)?;
    let mut samples = Vec::new();
    for _ in 0..repeats {
        let (result, time) = bench_clock::measure(|| {
            for _ in 0..iterations {
                let output = lhc::decode(std::hint::black_box(input), options, &mut || false)?;
                if output != expected {
                    return Err(lhc::Error::Format("decode benchmark determinism failure"));
                }
                // 解放もbatch計測内に含め、復号結果を反復数分保持しない。
                drop(output);
            }
            Ok::<(), lhc::Error>(())
        });
        result?;
        samples.push(serde_json::json!({
            "batch_ms": time.wall_ms,
            "mean_decode_verify_drop_ms": time.wall_ms / f64::from(iterations),
            "batch_cpu_ms": time.cpu_ms,
            "batch_cpu_status": time.cpu_status,
        }));
    }
    Ok(serde_json::json!({
        "experimental": true,
        "frame_bytes": input.len(),
        "decoded_bytes": expected.len(),
        "selected_mode": input[9],
        "dictionary": options.dictionary,
        "iterations_per_batch": iterations,
        "repeats": repeats,
        "warmup_decodes": 1,
        "note": "Warm-process batch: decode including frame CRC, full-byte comparison against warm-up, and output drop. Excludes input I/O and warm-up; not CLI latency or independent correctness proof. Holds one reference output outside codec memory budget. CPU clock may be quantized or unavailable.",
        "samples": samples,
    }))
}

const REP_PATCH_MIN_SPAN: usize = 256;
const REP_PATCH_MAX_SPAN: usize = 65_536;
const REP_PATCH_MAX_GAP_COMPARE_BYTES: usize = 64 * 1024 * 1024;

fn rep_patch_screen(
    input: &[u8],
    selected: &[lhc::SelectedCopy],
    max_patch_bytes: usize,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    // まず実parseが選んだ全copy tokenを検証し、実距離ごとに並べる。
    let mut by_distance = BTreeMap::<usize, Vec<(usize, usize, u8)>>::new();
    let mut last_copy_end = 0usize;
    let mut kind_counts = [0usize; 4];
    let mut copied_bytes = 0usize;
    for item in selected {
        let start = usize::try_from(item.offset)?;
        let length = usize::try_from(item.length)?;
        let distance = usize::try_from(item.distance)?;
        let end = start.checked_add(length).ok_or("copy trace overflow")?;
        if length == 0
            || start < last_copy_end
            || distance == 0
            || distance > start
            || end > input.len()
            || !(1..=3).contains(&item.kind)
        {
            return Err("invalid selected copy token in trace".into());
        }
        for position in start..end {
            if input[position] != input[position - distance] {
                return Err("selected copy token does not match raw input".into());
            }
        }
        kind_counts[usize::from(item.kind)] += 1;
        copied_bytes = copied_bytes.saturating_add(length);
        by_distance
            .entry(distance)
            .or_default()
            .push((start, end, item.kind));
        last_copy_end = end;
    }

    // 連続する同距離copy event間だけを調べる。候補範囲の累積patch数は単調なので、
    // 直近65,536 byte内でpatch上限内となる最も古い開始eventを線形走査で求める。
    let mut candidate_intervals = Vec::<(usize, usize)>::new();
    let mut candidate_count = 0usize;
    let mut candidate_span_sum = 0usize;
    let mut maximum_span = 0usize;
    let mut maximum_patch_bytes = 0usize;
    let mut gap_compare_bytes = 0usize;
    let mut complete = true;
    'distances: for (&distance, events) in &by_distance {
        let mut mismatch_before = Vec::with_capacity(events.len());
        let mut mismatch_prefix = 0usize;
        let mut first_eligible = 0usize;
        for index in 0..events.len() {
            if index != 0 {
                let gap_start = events[index - 1].1;
                let gap_end = events[index].0;
                let gap_len = gap_end - gap_start;
                if gap_len > REP_PATCH_MAX_SPAN {
                    // このeventより前を含むspanはすべて上限外。gap自体も調べない。
                    first_eligible = index;
                } else {
                    let mut gap_mismatches = 0usize;
                    for position in gap_start..gap_end {
                        if gap_compare_bytes == REP_PATCH_MAX_GAP_COMPARE_BYTES {
                            complete = false;
                            break 'distances;
                        }
                        gap_compare_bytes += 1;
                        if input[position] != input[position - distance] {
                            gap_mismatches += 1;
                            if gap_mismatches > max_patch_bytes {
                                // これより古い同距離eventは全てpatch上限を超える。
                                first_eligible = index;
                                break;
                            }
                        }
                    }
                    mismatch_prefix += gap_mismatches;
                }
            }
            mismatch_before.push(mismatch_prefix);
            let end = events[index].1;
            while first_eligible < index
                && (end - events[first_eligible].0 > REP_PATCH_MAX_SPAN
                    || mismatch_prefix - mismatch_before[first_eligible] > max_patch_bytes)
            {
                first_eligible += 1;
            }
            if index != 0 && first_eligible == index {
                // 古い開始候補がすべて期限切れ、または差分過多になったので窓を再基準化。
                mismatch_prefix = 0;
                mismatch_before[index] = 0;
            }
            if first_eligible < index {
                let start = events[first_eligible].0;
                let span = end - start;
                if span >= REP_PATCH_MIN_SPAN {
                    let patches = mismatch_prefix - mismatch_before[first_eligible];
                    candidate_count += 1;
                    candidate_span_sum = candidate_span_sum.saturating_add(span);
                    maximum_span = maximum_span.max(span);
                    maximum_patch_bytes = maximum_patch_bytes.max(patches);
                    candidate_intervals.push((start, end));
                }
            }
        }
    }

    candidate_intervals.sort_unstable();
    let mut union_bytes = 0usize;
    let mut current: Option<(usize, usize)> = None;
    for (start, end) in candidate_intervals {
        match current {
            Some((current_start, current_end)) if start <= current_end => {
                current = Some((current_start, current_end.max(end)));
            }
            Some((current_start, current_end)) => {
                union_bytes = union_bytes.saturating_add(current_end - current_start);
                current = Some((start, end));
            }
            None => current = Some((start, end)),
        }
    }
    if let Some((start, end)) = current {
        union_bytes = union_bytes.saturating_add(end - start);
    }

    Ok(serde_json::json!({
        "experimental": true,
        "screen_complete": complete,
        "input_bytes": input.len(),
        "copy_events": selected.len(),
        "normal_match_events": kind_counts[1],
        "rep_events": kind_counts[2],
        "short_rep_events": kind_counts[3],
        "copied_bytes": copied_bytes,
        "distinct_copy_distances": by_distance.len(),
        "min_segment_span_bytes": REP_PATCH_MIN_SPAN,
        "max_segment_span_bytes": REP_PATCH_MAX_SPAN,
        "max_patch_bytes": max_patch_bytes,
        "eligible_segment_candidates": candidate_count,
        "eligible_span_union_bytes_upper_bound": union_bytes,
        "eligible_span_union_fraction_upper_bound": if input.is_empty() { 0.0 } else { union_bytes as f64 / input.len() as f64 },
        "candidate_span_bytes_sum_nonexclusive": candidate_span_sum,
        "maximum_candidate_span_bytes": maximum_span,
        "maximum_candidate_patch_bytes": maximum_patch_bytes,
        "gap_compare_bytes": gap_compare_bytes,
        "note": "This upper-bound screen only identifies same-distance spans from the baseline parse with at most max_patch_bytes raw-byte mismatches. It does not implement or price a segment token, and overlapping candidate spans are unioned only as a coverage upper bound."
    }))
}

fn validate_census_trace(
    parser: &str,
    input: &[u8],
    selected: &[lhc::SelectedToken],
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let mut expected_offset = 0usize;
    let mut kind_counts = [0u64; 4];
    let mut copied_bytes = 0u64;
    for token in selected {
        let offset = usize::try_from(token.offset)?;
        let length = usize::try_from(token.length)?;
        let distance = usize::try_from(token.distance)?;
        let end = offset.checked_add(length).ok_or("token end overflow")?;
        if offset != expected_offset || length == 0 || end > input.len() || token.kind > 3 {
            return Err(format!("{parser} trace is invalid or non-contiguous").into());
        }
        match token.kind {
            0 if length == 1 && distance == 0 && token.rep_index == 0 => {}
            1 if length == 1 && distance > 0 && distance <= offset && token.rep_index == 0 => {}
            2 if length >= 2 && distance > 0 && distance <= offset && token.rep_index < 4 => {}
            3 if length >= 3 && distance > 0 && distance <= offset && token.rep_index == 0 => {}
            _ => return Err(format!("{parser} trace token fields are out of range").into()),
        }
        if parser == "standard" && !matches!(token.kind, 0 | 3) {
            return Err("Standard parser emitted an LZ-only token kind".into());
        }
        if token.kind != 0 {
            for index in 0..length {
                if input[offset + index] != input[offset + index - distance] {
                    return Err(format!("{parser} copy trace does not reconstruct input").into());
                }
            }
            copied_bytes = copied_bytes.saturating_add(length as u64);
        }
        kind_counts[usize::from(token.kind)] += 1;
        expected_offset = end;
    }
    if expected_offset != input.len() {
        return Err(format!("{parser} trace does not cover the input").into());
    }

    Ok(serde_json::json!({
        "token_count": selected.len(),
        "copied_bytes": copied_bytes,
        "copy_byte_fraction": if input.is_empty() { 0.0 } else { copied_bytes as f64 / input.len() as f64 },
        "token_kind_counts": {
            "literal": kind_counts[0],
            "short_rep": kind_counts[1],
            "rep": kind_counts[2],
            "normal_match": kind_counts[3],
        },
        "contiguous_and_copy_reconstruction_verified": true,
    }))
}

fn census_token_at(
    selected: &[lhc::SelectedToken],
    cursor: &mut usize,
    offset: usize,
) -> Result<lhc::SelectedToken, Box<dyn std::error::Error>> {
    while let Some(token) = selected.get(*cursor) {
        let end = usize::try_from(token.offset)?
            .checked_add(usize::try_from(token.length)?)
            .ok_or("token end overflow")?;
        if end > offset {
            break;
        }
        *cursor += 1;
    }
    let token = *selected
        .get(*cursor)
        .ok_or("missing token at input offset")?;
    let start = usize::try_from(token.offset)?;
    if start > offset {
        return Err("gap in parser token trace".into());
    }
    Ok(token)
}

fn parser_census(
    input: &[u8],
    options: lhc::Options,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    if !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err("parser-census requires the current Beam baseline: Range/Blended/W2/BT5/B8192, no optional beam modes".into());
    }

    let parser_specs = [
        ("standard", lhc::Algorithm::Standard, 1u8),
        ("lazy_lz", lhc::Algorithm::Lz, 2u8),
        ("beam", lhc::Algorithm::Beam, 2u8),
    ];
    let mut traces = Vec::new();
    let mut parser_reports = Vec::new();
    let mut retained_trace_bytes = 0usize;
    for (name, algorithm, expected_method) in parser_specs {
        let mut parser_options = options;
        parser_options.algorithm = algorithm;
        parser_options.memory_budget = options
            .memory_budget
            .checked_sub(retained_trace_bytes)
            .ok_or("parser trace storage exceeds the configured memory budget")?;
        let frame = lhc::encode(input, parser_options, &mut || false)?;
        let decoded = lhc::decode(&frame, parser_options, &mut || false)?;
        if decoded != input {
            return Err(format!("{name} ordinary frame failed round-trip").into());
        }
        drop(decoded);

        let (payload, selected) = match name {
            "standard" => lhc::trace_standard_tokens(input, parser_options, &mut || false)?,
            "lazy_lz" => lhc::trace_lz_tokens(input, parser_options, &mut || false)?,
            "beam" => lhc::trace_beam_tokens(input, parser_options, &mut || false)?,
            _ => unreachable!(),
        };
        let trace_matches_ordinary_frame = frame.get(9) == Some(&expected_method)
            && frame.get(lhc::HEADER..) == Some(payload.as_slice());
        if frame.get(9) == Some(&expected_method) && !trace_matches_ordinary_frame {
            return Err(format!("{name} trace changed the encoded payload").into());
        }
        let token_report = validate_census_trace(name, input, &selected)?;
        let trace_storage = selected
            .capacity()
            .checked_mul(std::mem::size_of::<lhc::SelectedToken>())
            .ok_or("parser trace storage size overflow")?;
        retained_trace_bytes = retained_trace_bytes
            .checked_add(trace_storage)
            .ok_or("parser trace storage size overflow")?;
        parser_reports.push(serde_json::json!({
            "parser": name,
            "ordinary_encode_frame_bytes": frame.len(),
            "ordinary_encode_method": frame[9],
            "parser_candidate_frame_bytes": payload.len().saturating_add(lhc::HEADER),
            "trace_matches_ordinary_frame": trace_matches_ordinary_frame,
            "ordinary_frame_round_trip_verified": true,
            "trace": token_report,
        }));
        traces.push(selected);
    }

    let mut pair_counts = [0u64; 3];
    let mut all_three_agree = 0u64;
    let mut any_parser_disagrees = 0u64;
    let mut any_pair_agrees = 0u64;
    let mut cursors = [0usize; 3];
    for offset in 0..input.len() {
        let standard = census_token_at(&traces[0], &mut cursors[0], offset)?;
        let lazy_lz = census_token_at(&traces[1], &mut cursors[1], offset)?;
        let beam = census_token_at(&traces[2], &mut cursors[2], offset)?;
        let standard_lz = standard == lazy_lz;
        let standard_beam = standard == beam;
        let lz_beam = lazy_lz == beam;
        pair_counts[0] += u64::from(standard_lz);
        pair_counts[1] += u64::from(standard_beam);
        pair_counts[2] += u64::from(lz_beam);
        let all_equal = standard_lz && standard_beam;
        all_three_agree += u64::from(all_equal);
        any_pair_agrees += u64::from(standard_lz || standard_beam || lz_beam);
        any_parser_disagrees += u64::from(!all_equal);
    }
    let input_bytes = input.len() as u64;
    Ok(serde_json::json!({
        "experimental": true,
        "screen": "actual-parser-token-census",
        "input_bytes": input.len(),
        "current_beam_options": {
            "dictionary_bytes": options.dictionary,
            "beam_width": options.beam_width,
            "beam_block_bytes": options.beam_block,
            "beam_model": "blended",
            "beam_matches": "bt5",
        },
        "trace_limit_tokens_per_parser": 1usize << 22,
        "trace_limit_bytes_per_parser": (1usize << 22) * std::mem::size_of::<lhc::SelectedToken>(),
        "retained_trace_capacity_bytes": retained_trace_bytes,
        "parsers": parser_reports,
        "position_comparison": {
            "signature": "the containing token's exact (start, length, kind, resolved distance, rep index)",
            "denominator": "input byte positions",
            "standard_vs_lazy_lz_exact_bytes": pair_counts[0],
            "standard_vs_lazy_lz_agreement_fraction": if input_bytes == 0 { 1.0 } else { pair_counts[0] as f64 / input_bytes as f64 },
            "standard_vs_beam_exact_bytes": pair_counts[1],
            "standard_vs_beam_agreement_fraction": if input_bytes == 0 { 1.0 } else { pair_counts[1] as f64 / input_bytes as f64 },
            "lazy_lz_vs_beam_exact_bytes": pair_counts[2],
            "lazy_lz_vs_beam_agreement_fraction": if input_bytes == 0 { 1.0 } else { pair_counts[2] as f64 / input_bytes as f64 },
            "all_three_exact_agreement_bytes": all_three_agree,
            "any_pair_exact_agreement_bytes": any_pair_agrees,
            "any_parser_disagreement_bytes": any_parser_disagrees,
            "any_parser_disagreement_fraction": if input_bytes == 0 { 0.0 } else { any_parser_disagrees as f64 / input_bytes as f64 },
        },
        "grok_thresholds_applied": false,
        "interpretation": "Raw parser-decision census only. Disagreement is not the amount of compressible repair opportunity and does not establish a hybrid speedup. The proposed 40%/80% cutoffs are reported as hypotheses, not accepted gates, until calibrated against paired encode timing and per-file holdouts.",
    }))
}

fn span_start(input: &[u8], data: &[u8]) -> Result<usize, Box<dyn std::error::Error>> {
    let base = input.as_ptr() as usize;
    let start = data.as_ptr() as usize;
    let end = start.checked_add(data.len()).ok_or("span end overflow")?;
    if start < base || end > base + input.len() {
        return Err("group entry is not a subslice of the input".into());
    }
    Ok(start - base)
}

fn timed_encode(
    input: &[u8],
    options: lhc::Options,
) -> Result<(Vec<u8>, f64), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let frame = lhc::encode(input, options, &mut || false)?;
    Ok((frame, started.elapsed().as_secs_f64() * 1000.0))
}

fn sample_median_ms(samples: &[f64]) -> Option<f64> {
    if samples.is_empty()
        || samples
            .iter()
            .any(|sample| !sample.is_finite() || *sample <= 0.0)
    {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let middle = sorted.len() / 2;
    Some(if sorted.len().is_multiple_of(2) {
        (sorted[middle - 1] + sorted[middle]) / 2.0
    } else {
        sorted[middle]
    })
}

fn sha256_hex(input: &[u8]) -> String {
    const ROUND: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    const INITIAL: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    fn compress(state: &mut [u32; 8], block: &[u8], round: &[u32; 64]) {
        let mut schedule = [0u32; 64];
        for (index, word) in block.as_chunks::<4>().0.iter().enumerate() {
            schedule[index] = u32::from_be_bytes(*word);
        }
        for index in 16..64 {
            let x = schedule[index - 15];
            let sigma0 = x.rotate_right(7) ^ x.rotate_right(18) ^ (x >> 3);
            let y = schedule[index - 2];
            let sigma1 = y.rotate_right(17) ^ y.rotate_right(19) ^ (y >> 10);
            schedule[index] = schedule[index - 16]
                .wrapping_add(sigma0)
                .wrapping_add(schedule[index - 7])
                .wrapping_add(sigma1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;
        for index in 0..64 {
            let sum1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let choice = (e & f) ^ (!e & g);
            let first = h
                .wrapping_add(sum1)
                .wrapping_add(choice)
                .wrapping_add(round[index])
                .wrapping_add(schedule[index]);
            let sum0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let majority = (a & b) ^ (a & c) ^ (b & c);
            let second = sum0.wrapping_add(majority);
            [h, g, f, e, d, c, b, a] = [
                g,
                f,
                e,
                d.wrapping_add(first),
                c,
                b,
                a,
                first.wrapping_add(second),
            ];
        }

        for (target, value) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *target = target.wrapping_add(value);
        }
    }

    let bit_len = u64::try_from(input.len())
        .unwrap_or(u64::MAX)
        .wrapping_mul(8);
    let full_len = input.len() / 64 * 64;
    let mut state = INITIAL;
    for block in input[..full_len].as_chunks::<64>().0 {
        compress(&mut state, block, &ROUND);
    }

    let tail = &input[full_len..];
    let mut final_blocks = [0u8; 128];
    final_blocks[..tail.len()].copy_from_slice(tail);
    final_blocks[tail.len()] = 0x80;
    let final_len = if tail.len() < 56 { 64 } else { 128 };
    final_blocks[final_len - 8..final_len].copy_from_slice(&bit_len.to_be_bytes());
    for block in final_blocks[..final_len].as_chunks::<64>().0 {
        compress(&mut state, block, &ROUND);
    }

    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut result = String::with_capacity(64);
    for word in state {
        for byte in word.to_be_bytes() {
            result.push(char::from(HEX[usize::from(byte >> 4)]));
            result.push(char::from(HEX[usize::from(byte & 0x0f)]));
        }
    }
    result
}

const PTT5_TRANSFORM_TAG: &[u8; 8] = b"KHPTX001";
const BYTE_PAIR_DICTIONARY_MAGIC: &[u8; 8] = b"KHBG0001";
const BYTE_PAIR_DICTIONARY_PAIRS: usize = 32;
const BYTE_PAIR_DICTIONARY_HEADER_BYTES: usize = 8 + 1 + 1 + 8 + BYTE_PAIR_DICTIONARY_PAIRS * 3;

#[derive(Clone, Copy)]
struct BytePairRule {
    code: u8,
    first: u8,
    second: u8,
}

struct BytePairTransform {
    bytes: Vec<u8>,
    escape: u8,
    rules: Vec<BytePairRule>,
    replacements: usize,
    escaped_literals: usize,
}

fn encode_byte_pair_dictionary(
    input: &[u8],
) -> Result<BytePairTransform, Box<dyn std::error::Error>> {
    let mut byte_frequency = [0u64; 256];
    let mut pair_frequency = Vec::new();
    pair_frequency
        .try_reserve_exact(1 << 16)
        .map_err(|_| "byte-pair histogram allocation failed")?;
    pair_frequency.resize(1 << 16, 0u64);
    for (index, &byte) in input.iter().enumerate() {
        byte_frequency[usize::from(byte)] += 1;
        if let Some(&next) = input.get(index + 1) {
            pair_frequency[(usize::from(byte) << 8) | usize::from(next)] += 1;
        }
    }

    let mut pair_keys = Vec::new();
    pair_keys
        .try_reserve_exact(1 << 16)
        .map_err(|_| "byte-pair key allocation failed")?;
    pair_keys.extend(0..(1 << 16));
    pair_keys.sort_unstable_by(|left, right| {
        pair_frequency[*right]
            .cmp(&pair_frequency[*left])
            .then_with(|| left.cmp(right))
    });

    let mut symbol_bytes = std::array::from_fn::<_, 256, _>(|index| index as u8);
    symbol_bytes.sort_unstable_by_key(|&byte| (byte_frequency[usize::from(byte)], byte));
    let escape = symbol_bytes[0];
    let mut reserved = [false; 256];
    reserved[usize::from(escape)] = true;
    let mut pair_by_key = Vec::new();
    pair_by_key
        .try_reserve_exact(1 << 16)
        .map_err(|_| "byte-pair mapping allocation failed")?;
    pair_by_key.resize(1 << 16, -1i16);

    let mut rules = Vec::new();
    rules
        .try_reserve_exact(BYTE_PAIR_DICTIONARY_PAIRS)
        .map_err(|_| "byte-pair rule allocation failed")?;
    for (index, &key) in pair_keys
        .iter()
        .take(BYTE_PAIR_DICTIONARY_PAIRS)
        .enumerate()
    {
        let code = symbol_bytes[index + 1];
        reserved[usize::from(code)] = true;
        pair_by_key[key] = i16::from(code);
        rules.push(BytePairRule {
            code,
            first: (key >> 8) as u8,
            second: key as u8,
        });
    }

    let capacity = input
        .len()
        .checked_add(BYTE_PAIR_DICTIONARY_HEADER_BYTES)
        .ok_or("byte-pair transform capacity overflow")?;
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(capacity)
        .map_err(|_| "byte-pair transform allocation failed")?;
    bytes.extend_from_slice(BYTE_PAIR_DICTIONARY_MAGIC);
    bytes.push(escape);
    bytes.push(u8::try_from(rules.len())?);
    bytes.extend_from_slice(&u64::try_from(input.len())?.to_le_bytes());
    for rule in &rules {
        bytes.extend_from_slice(&[rule.code, rule.first, rule.second]);
    }
    if bytes.len() != BYTE_PAIR_DICTIONARY_HEADER_BYTES {
        return Err("byte-pair header length mismatch".into());
    }

    let mut replacements = 0usize;
    let mut escaped_literals = 0usize;
    let mut index = 0usize;
    while index < input.len() {
        if let Some(&next) = input.get(index + 1) {
            let key = (usize::from(input[index]) << 8) | usize::from(next);
            let code = pair_by_key[key];
            if code >= 0 {
                bytes.push(code as u8);
                replacements += 1;
                index += 2;
                continue;
            }
        }
        let byte = input[index];
        if reserved[usize::from(byte)] {
            bytes.extend_from_slice(&[escape, byte]);
            escaped_literals += 1;
        } else {
            bytes.push(byte);
        }
        index += 1;
    }

    Ok(BytePairTransform {
        bytes,
        escape,
        rules,
        replacements,
        escaped_literals,
    })
}

fn decode_byte_pair_dictionary(input: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    if input.len() < BYTE_PAIR_DICTIONARY_HEADER_BYTES
        || input.get(..BYTE_PAIR_DICTIONARY_MAGIC.len()) != Some(BYTE_PAIR_DICTIONARY_MAGIC)
    {
        return Err("byte-pair dictionary header/magic is invalid".into());
    }
    let escape = input[8];
    if usize::from(input[9]) != BYTE_PAIR_DICTIONARY_PAIRS {
        return Err("byte-pair dictionary count is invalid".into());
    }
    let original_len = usize::try_from(u64::from_le_bytes(input[10..18].try_into()?))?;
    if original_len > lhc::MAX_INPUT {
        return Err("byte-pair original length exceeds LHC limit".into());
    }
    let mut pair_by_code = [None; 256];
    let mut pair_keys = [false; 1 << 16];
    let mut cursor = 18usize;
    for _ in 0..BYTE_PAIR_DICTIONARY_PAIRS {
        let code = input[cursor];
        let first = input[cursor + 1];
        let second = input[cursor + 2];
        cursor += 3;
        let key = (usize::from(first) << 8) | usize::from(second);
        if code == escape || pair_by_code[usize::from(code)].is_some() || pair_keys[key] {
            return Err("byte-pair dictionary contains duplicate/reserved symbols".into());
        }
        pair_by_code[usize::from(code)] = Some([first, second]);
        pair_keys[key] = true;
    }
    if cursor != BYTE_PAIR_DICTIONARY_HEADER_BYTES {
        return Err("byte-pair dictionary header size is invalid".into());
    }

    let mut output = Vec::new();
    output
        .try_reserve_exact(original_len)
        .map_err(|_| "byte-pair decoded output allocation failed")?;
    let mut index = cursor;
    while index < input.len() {
        let symbol = input[index];
        index += 1;
        if symbol == escape {
            let literal = *input
                .get(index)
                .ok_or("byte-pair escape is missing its literal")?;
            output.push(literal);
            index += 1;
        } else if let Some(pair) = pair_by_code[usize::from(symbol)] {
            output.extend_from_slice(&pair);
        } else {
            output.push(symbol);
        }
        if output.len() > original_len {
            return Err("byte-pair output exceeds declared original length".into());
        }
    }
    if output.len() != original_len {
        return Err("byte-pair output differs from declared original length".into());
    }
    Ok(output)
}

fn timed_byte_pair_encode(
    input: &[u8],
    options: lhc::Options,
) -> Result<(Vec<u8>, f64), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let transformed = encode_byte_pair_dictionary(input)?;
    let frame = lhc::encode(&transformed.bytes, options, &mut || false)?;
    Ok((frame, started.elapsed().as_secs_f64() * 1000.0))
}

fn byte_pair_dictionary_screen(
    input: &[u8],
    options: lhc::Options,
    entries: &[solid::Entry<'_>],
    repeats: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_006;
    const INPUT_SHA256: &str = "18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76";
    const BASELINE_FRAME_BYTES: usize = 483_130;
    const BASELINE_FRAME_SHA256: &str =
        "CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D";
    const TRANSFORMED_BYTES: usize = 1_970_528;
    const TRANSFORM_REPLACEMENTS: usize = 854_731;
    const TRANSFORM_ESCAPES: usize = 14_139;
    const SEVEN_ZIP_SIZE_GATE: usize = 483_599;
    const SEVEN_ZIP_ENCODE_MS: f64 = 574.5624;
    const PAIRED_SAMPLES: usize = 9;
    const ENTRY_LAYOUT: [(&str, usize); 11] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];

    if !matches!(options.algorithm, lhc::Algorithm::Beam)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
        || options.dictionary != 64 * 1024 * 1024
    {
        return Err("byte-pair screen requires Range/Beam/Blended/BT5/W2/B8192/64MiB".into());
    }
    if input.len() != INPUT_BYTES
        || sha256_hex(input) != INPUT_SHA256
        || entries.len() != ENTRY_LAYOUT.len()
        || entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| entry.name != *name || entry.data.len() != *bytes)
        || repeats != PAIRED_SAMPLES as u32
    {
        return Err(
            "byte-pair screen requires the fixed 11-entry Canterbury group and exactly 9 paired samples"
                .into(),
        );
    }

    let baseline_frame = lhc::encode(input, options, &mut || false)?;
    if baseline_frame.len() != BASELINE_FRAME_BYTES
        || sha256_hex(&baseline_frame) != BASELINE_FRAME_SHA256
        || baseline_frame.get(9) != Some(&2)
        || lhc::decode(&baseline_frame, options, &mut || false)? != input
    {
        return Err(
            "fixed-group baseline frame/round-trip differs from the recorded contract".into(),
        );
    }

    let transform = encode_byte_pair_dictionary(input)?;
    if transform.bytes.len() != TRANSFORMED_BYTES
        || transform.replacements != TRANSFORM_REPLACEMENTS
        || transform.escaped_literals != TRANSFORM_ESCAPES
        || transform.rules.len() != BYTE_PAIR_DICTIONARY_PAIRS
        || transform.bytes.get(..8) != Some(BYTE_PAIR_DICTIONARY_MAGIC)
        || transform.bytes.get(8) != Some(&transform.escape)
    {
        return Err("byte-pair transform differs from its pre-registered census".into());
    }
    let candidate_frame = lhc::encode(&transform.bytes, options, &mut || false)?;
    if candidate_frame.get(9) != Some(&2)
        || lhc::encode(&transform.bytes, options, &mut || false)? != candidate_frame
    {
        return Err("byte-pair candidate is not deterministic method 2".into());
    }
    let decoded_candidate = lhc::decode(&candidate_frame, options, &mut || false)?;
    if decoded_candidate != transform.bytes {
        return Err("LHC frame did not restore the byte-pair transform stream".into());
    }
    let restored = decode_byte_pair_dictionary(&decoded_candidate)?;
    if restored != input
        || sha256_hex(&restored) != INPUT_SHA256
        || solid::parse(&restored)? != entries
    {
        return Err("inverse byte-pair transform did not restore the exact fixed group".into());
    }
    let repeated_transform = encode_byte_pair_dictionary(&restored)?;
    if repeated_transform.bytes != transform.bytes
        || repeated_transform.escape != transform.escape
        || repeated_transform.rules.len() != transform.rules.len()
        || repeated_transform
            .rules
            .iter()
            .zip(transform.rules.iter())
            .any(|(left, right)| {
                left.code != right.code || left.first != right.first || left.second != right.second
            })
    {
        return Err("byte-pair transform table is not canonical/deterministic".into());
    }

    let entry_hashes = entries
        .iter()
        .map(|entry| {
            serde_json::json!({
                "name": entry.name,
                "bytes": entry.data.len(),
                "sha256": sha256_hex(entry.data),
            })
        })
        .collect::<Vec<_>>();
    let pair_table = transform
        .rules
        .iter()
        .map(|rule| {
            serde_json::json!({
                "symbol": rule.code,
                "pair": [rule.first, rule.second],
            })
        })
        .collect::<Vec<_>>();

    if candidate_frame.len() > SEVEN_ZIP_SIZE_GATE {
        return Ok(serde_json::json!({
            "experimental": true,
            "screen": "fixed-canterbury-byte-pair-dictionary",
            "decision": "no_go_size",
            "input_bytes": input.len(),
            "input_sha256": INPUT_SHA256,
            "transform": {
                "algorithm": "top-32 overlapping bigrams; deterministic greedy non-overlapping substitution; least-frequency 33 byte values for 32 pair symbols and one escape",
                "header_bytes": BYTE_PAIR_DICTIONARY_HEADER_BYTES,
                "transformed_bytes": transform.bytes.len(),
                "transform_reduction_bytes": input.len() as i64 - transform.bytes.len() as i64,
                "pair_replacements": transform.replacements,
                "escaped_literals": transform.escaped_literals,
                "escape_symbol": transform.escape,
                "pair_table": pair_table,
            },
            "baseline_frame_bytes": baseline_frame.len(),
            "baseline_frame_sha256": BASELINE_FRAME_SHA256,
            "candidate_frame_bytes": candidate_frame.len(),
            "candidate_frame_sha256": sha256_hex(&candidate_frame),
            "size_gate_bytes": SEVEN_ZIP_SIZE_GATE,
            "round_trip_and_all_entry_hashes_verified": true,
            "entries": entry_hashes,
            "paired_timing_performed": false,
            "holdout_used": false,
        }));
    }

    let mut baseline_times_ms = Vec::new();
    let mut candidate_times_ms = Vec::new();
    baseline_times_ms.reserve(PAIRED_SAMPLES);
    candidate_times_ms.reserve(PAIRED_SAMPLES);
    for sample in 0..PAIRED_SAMPLES {
        if sample.is_multiple_of(2) {
            let started = Instant::now();
            let frame = lhc::encode(input, options, &mut || false)?;
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed byte-pair baseline differs from its verified frame".into());
            }
            baseline_times_ms.push(elapsed);
            let (frame, elapsed) = timed_byte_pair_encode(input, options)?;
            if frame != candidate_frame {
                return Err("timed byte-pair candidate differs from its verified frame".into());
            }
            candidate_times_ms.push(elapsed);
        } else {
            let (frame, elapsed) = timed_byte_pair_encode(input, options)?;
            if frame != candidate_frame {
                return Err("timed byte-pair candidate differs from its verified frame".into());
            }
            candidate_times_ms.push(elapsed);
            let started = Instant::now();
            let frame = lhc::encode(input, options, &mut || false)?;
            let elapsed = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed byte-pair baseline differs from its verified frame".into());
            }
            baseline_times_ms.push(elapsed);
        }
    }
    let baseline_median_ms = sample_median_ms(&baseline_times_ms)
        .ok_or("baseline timing was empty, non-finite, or non-positive")?;
    let candidate_median_ms = sample_median_ms(&candidate_times_ms)
        .ok_or("candidate timing was empty, non-finite, or non-positive")?;

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "fixed-canterbury-byte-pair-dictionary",
        "decision": if candidate_median_ms < SEVEN_ZIP_ENCODE_MS { "passes_fixed_speed_gate" } else { "no_go_speed" },
        "input_bytes": input.len(),
        "input_sha256": INPUT_SHA256,
        "transform": {
            "algorithm": "top-32 overlapping bigrams; deterministic greedy non-overlapping substitution; least-frequency 33 byte values for 32 pair symbols and one escape",
            "header_bytes": BYTE_PAIR_DICTIONARY_HEADER_BYTES,
            "transformed_bytes": transform.bytes.len(),
            "transform_reduction_bytes": input.len() as i64 - transform.bytes.len() as i64,
            "pair_replacements": transform.replacements,
            "escaped_literals": transform.escaped_literals,
            "escape_symbol": transform.escape,
            "pair_table": pair_table,
        },
        "baseline_frame_bytes": baseline_frame.len(),
        "baseline_frame_sha256": BASELINE_FRAME_SHA256,
        "candidate_frame_bytes": candidate_frame.len(),
        "candidate_frame_sha256": sha256_hex(&candidate_frame),
        "size_gate_bytes": SEVEN_ZIP_SIZE_GATE,
        "passes_size_gate": candidate_frame.len() <= SEVEN_ZIP_SIZE_GATE,
        "round_trip_and_all_entry_hashes_verified": true,
        "entries": entry_hashes,
        "timing": {
            "paired_samples_per_side": PAIRED_SAMPLES,
            "order": "alternating; even samples baseline-first, odd samples candidate-first",
            "candidate_timing_includes": "byte and bigram histograms, deterministic ranking, transformation/header generation, and LHC encode; excludes input I/O and decode",
            "baseline_encode_ms": baseline_times_ms,
            "candidate_transform_plus_encode_ms": candidate_times_ms,
            "baseline_median_ms": baseline_median_ms,
            "candidate_median_ms": candidate_median_ms,
            "fixed_seven_zip_encode_gate_ms": SEVEN_ZIP_ENCODE_MS,
            "saving_vs_paired_baseline_ms": baseline_median_ms - candidate_median_ms,
            "candidate_passes_strict_speed_gate": candidate_median_ms < SEVEN_ZIP_ENCODE_MS,
            "note": "Same-process fixed Canterbury screen. It does not establish a cross-corpus or overall 7-Zip win."
        },
        "holdout_used": false,
    }))
}

struct SolidGroupLayout {
    metadata_end: usize,
    length_offsets: Vec<usize>,
    data_offsets: Vec<usize>,
}

fn solid_group_layout(
    input: &[u8],
    entries: &[solid::Entry<'_>],
) -> Result<SolidGroupLayout, Box<dyn std::error::Error>> {
    if input.len() < 16 || &input[..8] != b"KHSGRP0\0" {
        return Err("solid group header differs from KHSGRP0".into());
    }
    let count = u32::from_le_bytes(input[8..12].try_into()?);
    let reserved = u32::from_le_bytes(input[12..16].try_into()?);
    if usize::try_from(count)? != entries.len() || reserved != 0 {
        return Err("solid group count/reserved field mismatch".into());
    }

    let mut cursor = 16usize;
    let mut length_offsets = Vec::with_capacity(entries.len());
    for entry in entries {
        let name_len_end = cursor.checked_add(2).ok_or("group metadata overflow")?;
        if name_len_end > input.len() {
            return Err("truncated solid group name length".into());
        }
        let name_len = usize::from(u16::from_le_bytes(input[cursor..name_len_end].try_into()?));
        let length_offset = name_len_end;
        let length_end = length_offset
            .checked_add(8)
            .ok_or("group metadata overflow")?;
        if length_end > input.len() {
            return Err("truncated solid group entry length".into());
        }
        let data_len = u64::from_le_bytes(input[length_offset..length_end].try_into()?);
        let name_end = length_end
            .checked_add(name_len)
            .ok_or("group metadata overflow")?;
        if name_end > input.len()
            || input[length_end..name_end] != *entry.name.as_bytes()
            || data_len != u64::try_from(entry.data.len())?
        {
            return Err("solid group metadata differs from parsed entries".into());
        }
        length_offsets.push(length_offset);
        cursor = name_end;
    }

    let metadata_end = cursor;
    let mut data_cursor = metadata_end;
    let mut data_offsets = Vec::with_capacity(entries.len());
    for entry in entries {
        let offset = span_start(input, entry.data)?;
        if offset != data_cursor {
            return Err("solid group data spans are not contiguous in metadata order".into());
        }
        data_offsets.push(offset);
        data_cursor = data_cursor
            .checked_add(entry.data.len())
            .ok_or("solid group data span overflow")?;
    }
    if data_cursor != input.len() {
        return Err("solid group has trailing or missing data".into());
    }
    Ok(SolidGroupLayout {
        metadata_end,
        length_offsets,
        data_offsets,
    })
}

fn transpose_ptt5_216x2376(
    input: &[u8],
    inverse: bool,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    const WIDTH_BYTES: usize = 216;
    const ROWS: usize = 2376;
    const BYTES: usize = WIDTH_BYTES * ROWS;
    if input.len() != BYTES {
        return Err("ptt5 transpose requires exactly 513216 bytes".into());
    }
    let mut output = vec![0u8; BYTES];
    for column in 0..WIDTH_BYTES {
        let column_start = column * ROWS;
        for row in 0..ROWS {
            if inverse {
                output[row * WIDTH_BYTES + column] = input[column_start + row];
            } else {
                output[column_start + row] = input[row * WIDTH_BYTES + column];
            }
        }
    }
    Ok(output)
}

fn transpose_ptt5_group(
    input: &[u8],
    entries: &[solid::Entry<'_>],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let layout = solid_group_layout(input, entries)?;
    let ptt5 = entries
        .iter()
        .position(|entry| entry.name == "ptt5")
        .ok_or("fixed group has no ptt5 entry")?;
    if entries.iter().filter(|entry| entry.name == "ptt5").count() != 1
        || entries[ptt5].data.len() != 216 * 2376
    {
        return Err("ptt5 entry does not match the fixed 216x2376 dimensions".into());
    }
    let new_len = entries[ptt5]
        .data
        .len()
        .checked_add(PTT5_TRANSFORM_TAG.len())
        .ok_or("ptt5 tagged length overflow")?;
    let mut output = Vec::with_capacity(
        input
            .len()
            .checked_add(PTT5_TRANSFORM_TAG.len())
            .ok_or("transformed group size overflow")?,
    );
    output.extend_from_slice(&input[..layout.metadata_end]);
    output[layout.length_offsets[ptt5]..layout.length_offsets[ptt5] + 8]
        .copy_from_slice(&u64::try_from(new_len)?.to_le_bytes());
    for (index, entry) in entries.iter().enumerate() {
        let data_start = layout.data_offsets[index];
        let data_end = data_start
            .checked_add(entry.data.len())
            .ok_or("solid group data span overflow")?;
        let data = &input[data_start..data_end];
        if index == ptt5 {
            output.extend_from_slice(PTT5_TRANSFORM_TAG);
            output.extend_from_slice(&transpose_ptt5_216x2376(data, false)?);
        } else {
            output.extend_from_slice(data);
        }
    }
    Ok(output)
}

fn restore_ptt5_group(
    transformed: &[u8],
    entries: &[solid::Entry<'_>],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let layout = solid_group_layout(transformed, entries)?;
    let ptt5 = entries
        .iter()
        .position(|entry| entry.name == "ptt5")
        .ok_or("transformed group has no ptt5 entry")?;
    if entries.iter().filter(|entry| entry.name == "ptt5").count() != 1
        || entries[ptt5].data.len() != 216 * 2376 + PTT5_TRANSFORM_TAG.len()
        || !entries[ptt5].data.starts_with(PTT5_TRANSFORM_TAG)
    {
        return Err("transformed ptt5 tag/length mismatch".into());
    }
    let restored_len = entries[ptt5].data.len() - PTT5_TRANSFORM_TAG.len();
    let mut output = Vec::with_capacity(
        transformed
            .len()
            .checked_sub(PTT5_TRANSFORM_TAG.len())
            .ok_or("transformed group size underflow")?,
    );
    output.extend_from_slice(&transformed[..layout.metadata_end]);
    output[layout.length_offsets[ptt5]..layout.length_offsets[ptt5] + 8]
        .copy_from_slice(&u64::try_from(restored_len)?.to_le_bytes());
    for (index, entry) in entries.iter().enumerate() {
        let data_start = layout.data_offsets[index];
        let data_end = data_start
            .checked_add(entry.data.len())
            .ok_or("solid group data span overflow")?;
        let data = &transformed[data_start..data_end];
        if index == ptt5 {
            output.extend_from_slice(&transpose_ptt5_216x2376(
                &data[PTT5_TRANSFORM_TAG.len()..],
                true,
            )?);
        } else {
            output.extend_from_slice(data);
        }
    }
    Ok(output)
}

fn timed_ptt5_transpose_encode(
    input: &[u8],
    entries: &[solid::Entry<'_>],
    options: lhc::Options,
) -> Result<(Vec<u8>, f64), Box<dyn std::error::Error>> {
    let started = Instant::now();
    let transformed = transpose_ptt5_group(input, entries)?;
    let frame = lhc::encode(&transformed, options, &mut || false)?;
    drop(transformed);
    Ok((frame, started.elapsed().as_secs_f64() * 1000.0))
}

fn ptt5_transpose_screen(
    input: &[u8],
    options: lhc::Options,
    entries: &[solid::Entry<'_>],
    repeats: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_006;
    const INPUT_SHA256: &str = "18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76";
    const BASELINE_FRAME_BYTES: usize = 483_130;
    const BASELINE_FRAME_SHA256: &str =
        "CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D";
    const CANDIDATE_GROUP_BYTES: usize = 2_811_014;
    const CANDIDATE_GROUP_SHA256: &str =
        "A185CB3E92B0EBA0A1F6A330E72152625F6429B1CCBD815791F6026608D16788";
    const CANDIDATE_FRAME_BYTES: usize = 479_791;
    const CANDIDATE_FRAME_SHA256: &str =
        "6C8A4C9DDCB77ED0BDC1987F7FE7B6DE7EBC884CC90BC059CF5D3190F496519A";
    const SEVEN_ZIP_FRAME_GATE: usize = 483_599;
    const SEVEN_ZIP_ENCODE_MS: f64 = 574.5624;
    const PAIRED_SAMPLES: usize = 9;
    const ENTRY_LAYOUT: [(&str, usize); 11] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];

    if !matches!(options.algorithm, lhc::Algorithm::Beam)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
        || options.dictionary != 64 * 1024 * 1024
    {
        return Err("ptt5-transpose requires Range/Beam/Blended/BT5/W2/B8192/64MiB".into());
    }
    if input.len() != INPUT_BYTES
        || sha256_hex(input) != INPUT_SHA256
        || entries.len() != ENTRY_LAYOUT.len()
        || entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| entry.name != *name || entry.data.len() != *bytes)
        || repeats != PAIRED_SAMPLES as u32
    {
        return Err(
            "ptt5-transpose requires the fixed 11-entry group and exactly 9 paired samples".into(),
        );
    }

    let baseline_frame = lhc::encode(input, options, &mut || false)?;
    if baseline_frame.len() != BASELINE_FRAME_BYTES
        || sha256_hex(&baseline_frame) != BASELINE_FRAME_SHA256
        || baseline_frame.get(9) != Some(&2)
        || lhc::decode(&baseline_frame, options, &mut || false)? != input
    {
        return Err(
            "fixed-group baseline frame/round-trip differs from the recorded contract".into(),
        );
    }

    let candidate_group = transpose_ptt5_group(input, entries)?;
    let transformed_entries = solid::parse(&candidate_group)?;
    if candidate_group.len() != CANDIDATE_GROUP_BYTES
        || sha256_hex(&candidate_group) != CANDIDATE_GROUP_SHA256
        || transformed_entries.len() != ENTRY_LAYOUT.len()
        || transformed_entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| {
                entry.name != *name
                    || entry.data.len()
                        != if *name == "ptt5" {
                            bytes + PTT5_TRANSFORM_TAG.len()
                        } else {
                            *bytes
                        }
            })
    {
        return Err("transposed candidate group differs from the fixed transform contract".into());
    }

    let candidate_frame = lhc::encode(&candidate_group, options, &mut || false)?;
    if candidate_frame.len() != CANDIDATE_FRAME_BYTES
        || sha256_hex(&candidate_frame) != CANDIDATE_FRAME_SHA256
        || candidate_frame.get(9) != Some(&2)
        || lhc::encode(&candidate_group, options, &mut || false)? != candidate_frame
    {
        return Err(
            "candidate frame differs from the recorded deterministic method-2 screen".into(),
        );
    }
    let decoded_candidate = lhc::decode(&candidate_frame, options, &mut || false)?;
    if decoded_candidate != candidate_group {
        return Err("candidate frame did not restore its tagged transposed group".into());
    }
    let decoded_entries = solid::parse(&decoded_candidate)?;
    let restored_group = restore_ptt5_group(&decoded_candidate, &decoded_entries)?;
    let restored_entries = solid::parse(&restored_group)?;
    if restored_group != input || restored_entries != entries {
        return Err("inverse transpose failed exact group/entry round-trip".into());
    }
    let entry_hashes = restored_entries
        .iter()
        .map(|entry| {
            serde_json::json!({
                "name": entry.name,
                "bytes": entry.data.len(),
                "sha256": sha256_hex(entry.data),
            })
        })
        .collect::<Vec<_>>();

    let passes_size_gate = candidate_frame.len() <= SEVEN_ZIP_FRAME_GATE;
    if !passes_size_gate {
        return Ok(serde_json::json!({
            "experimental": true,
            "screen": "fixed-canterbury-ptt5-transpose",
            "decision": "no_go_size",
            "input_bytes": input.len(),
            "input_sha256": INPUT_SHA256,
            "candidate_group_bytes": candidate_group.len(),
            "candidate_group_sha256": CANDIDATE_GROUP_SHA256,
            "candidate_frame_bytes": candidate_frame.len(),
            "candidate_frame_sha256": CANDIDATE_FRAME_SHA256,
            "size_gate_bytes": SEVEN_ZIP_FRAME_GATE,
            "round_trip_and_all_entry_hashes_verified": true,
            "entries": entry_hashes,
            "speed_measured": false,
        }));
    }

    if lhc::encode(input, options, &mut || false)? != baseline_frame
        || timed_ptt5_transpose_encode(input, entries, options)?.0 != candidate_frame
    {
        return Err("baseline/candidate warm-up was nondeterministic".into());
    }

    let mut baseline_times_ms = Vec::with_capacity(PAIRED_SAMPLES);
    let mut candidate_times_ms = Vec::with_capacity(PAIRED_SAMPLES);
    for sample in 0..PAIRED_SAMPLES {
        if sample % 2 == 0 {
            let (frame, elapsed) = timed_encode(input, options)?;
            if frame != baseline_frame {
                return Err("timed baseline frame diverged".into());
            }
            baseline_times_ms.push(elapsed);

            let (frame, elapsed) = timed_ptt5_transpose_encode(input, entries, options)?;
            if frame != candidate_frame {
                return Err("timed transformed frame diverged".into());
            }
            candidate_times_ms.push(elapsed);
        } else {
            let (frame, elapsed) = timed_ptt5_transpose_encode(input, entries, options)?;
            if frame != candidate_frame {
                return Err("timed transformed frame diverged".into());
            }
            candidate_times_ms.push(elapsed);

            let (frame, elapsed) = timed_encode(input, options)?;
            if frame != baseline_frame {
                return Err("timed baseline frame diverged".into());
            }
            baseline_times_ms.push(elapsed);
        }
    }
    let baseline_median_ms = sample_median_ms(&baseline_times_ms)
        .ok_or("baseline timing was empty, non-finite, or non-positive")?;
    let candidate_median_ms = sample_median_ms(&candidate_times_ms)
        .ok_or("candidate timing was empty, non-finite, or non-positive")?;

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "fixed-canterbury-ptt5-transpose",
        "decision": if candidate_median_ms < SEVEN_ZIP_ENCODE_MS { "passes_fixed_speed_gate" } else { "no_go_speed" },
        "input_bytes": input.len(),
        "input_sha256": INPUT_SHA256,
        "settings": {
            "algorithm": "Beam",
            "entropy_backend": "Range",
            "beam_model": "Blended",
            "beam_matches": "BT5",
            "beam_width": options.beam_width,
            "beam_block": options.beam_block,
            "dictionary_bytes": options.dictionary,
        },
        "transform": "KHPTX001 + 216-byte x 2376-row row-major to column-major byte transpose",
        "candidate_group_bytes": candidate_group.len(),
        "candidate_group_sha256": CANDIDATE_GROUP_SHA256,
        "baseline_frame_bytes": baseline_frame.len(),
        "baseline_frame_sha256": BASELINE_FRAME_SHA256,
        "candidate_frame_bytes": candidate_frame.len(),
        "candidate_frame_sha256": CANDIDATE_FRAME_SHA256,
        "size_gate_bytes": SEVEN_ZIP_FRAME_GATE,
        "passes_size_gate": passes_size_gate,
        "round_trip_and_all_entry_hashes_verified": true,
        "restored_group_sha256": sha256_hex(&restored_group),
        "entries": entry_hashes,
        "timing": {
            "paired_samples_per_side": PAIRED_SAMPLES,
            "order": "alternating; even samples baseline-first, odd samples candidate-first",
            "candidate_timing_includes": "metadata scan, group copy/rebuild, tag, transpose, LHC encode, and temporary group release",
            "baseline_encode_ms": baseline_times_ms,
            "candidate_transform_plus_encode_ms": candidate_times_ms,
            "baseline_median_ms": baseline_median_ms,
            "candidate_median_ms": candidate_median_ms,
            "fixed_seven_zip_encode_gate_ms": SEVEN_ZIP_ENCODE_MS,
            "saving_vs_paired_baseline_ms": baseline_median_ms - candidate_median_ms,
            "candidate_passes_strict_speed_gate": candidate_median_ms < SEVEN_ZIP_ENCODE_MS,
            "note": "Same-process Instant timing. This fixed Canterbury result is not cross-corpus evidence and does not establish an overall 7-Zip win."
        },
        "holdout_used": false,
    }))
}

fn ptt5_transpose_window_screen(
    input: &[u8],
    options: lhc::Options,
    entries: &[solid::Entry<'_>],
    repeats: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_006;
    const INPUT_SHA256: &str = "18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76";
    const BASELINE_FRAME_BYTES: usize = 485_838;
    const BASELINE_FRAME_SHA256: &str =
        "40362BB6A88AC05BCDC79382A920D3203C02FF2BB9768EE2E9067C3FFEE4D0C0";
    const CANDIDATE_GROUP_BYTES: usize = 2_811_014;
    const CANDIDATE_GROUP_SHA256: &str =
        "A185CB3E92B0EBA0A1F6A330E72152625F6429B1CCBD815791F6026608D16788";
    const SEVEN_ZIP_FRAME_GATE: usize = 483_599;
    const SEVEN_ZIP_ENCODE_MS: f64 = 574.5624;
    const PAIRED_SAMPLES: usize = 9;
    const ENTRY_LAYOUT: [(&str, usize); 11] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];

    if !matches!(options.algorithm, lhc::Algorithm::Beam)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
        || options.dictionary != 1024 * 1024
    {
        return Err("ptt5-transpose-window requires Range/Beam/Blended/BT5/W2/B8192/1MiB".into());
    }
    if input.len() != INPUT_BYTES
        || sha256_hex(input) != INPUT_SHA256
        || entries.len() != ENTRY_LAYOUT.len()
        || entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| entry.name != *name || entry.data.len() != *bytes)
        || repeats != PAIRED_SAMPLES as u32
    {
        return Err(
            "ptt5-transpose-window requires the fixed 11-entry group and exactly 9 paired samples"
                .into(),
        );
    }

    let baseline_frame = lhc::encode(input, options, &mut || false)?;
    if baseline_frame.len() != BASELINE_FRAME_BYTES
        || sha256_hex(&baseline_frame) != BASELINE_FRAME_SHA256
        || baseline_frame.get(9) != Some(&2)
        || lhc::decode(&baseline_frame, options, &mut || false)? != input
    {
        return Err(
            "fixed 1-MiB baseline frame/round-trip differs from its recorded contract".into(),
        );
    }

    let candidate_group = transpose_ptt5_group(input, entries)?;
    let transformed_entries = solid::parse(&candidate_group)?;
    if candidate_group.len() != CANDIDATE_GROUP_BYTES
        || sha256_hex(&candidate_group) != CANDIDATE_GROUP_SHA256
        || transformed_entries.len() != ENTRY_LAYOUT.len()
        || transformed_entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| {
                entry.name != *name
                    || entry.data.len()
                        != if *name == "ptt5" {
                            bytes + PTT5_TRANSFORM_TAG.len()
                        } else {
                            *bytes
                        }
            })
    {
        return Err(
            "transposed 1-MiB candidate group differs from the fixed transform contract".into(),
        );
    }

    let candidate_frame = lhc::encode(&candidate_group, options, &mut || false)?;
    if candidate_frame.get(9) != Some(&2)
        || lhc::encode(&candidate_group, options, &mut || false)? != candidate_frame
    {
        return Err("transposed 1-MiB candidate frame is not deterministic method 2".into());
    }
    let decoded_candidate = lhc::decode(&candidate_frame, options, &mut || false)?;
    if decoded_candidate != candidate_group {
        return Err("1-MiB candidate frame did not restore its tagged transposed group".into());
    }
    let decoded_entries = solid::parse(&decoded_candidate)?;
    let restored_group = restore_ptt5_group(&decoded_candidate, &decoded_entries)?;
    let restored_entries = solid::parse(&restored_group)?;
    if restored_group != input || restored_entries != entries {
        return Err("1-MiB inverse transpose failed exact group/entry round-trip".into());
    }
    let entry_hashes = restored_entries
        .iter()
        .map(|entry| {
            serde_json::json!({
                "name": entry.name,
                "bytes": entry.data.len(),
                "sha256": sha256_hex(entry.data),
            })
        })
        .collect::<Vec<_>>();

    let passes_size_gate = candidate_frame.len() <= SEVEN_ZIP_FRAME_GATE;
    if !passes_size_gate {
        return Ok(serde_json::json!({
            "experimental": true,
            "screen": "fixed-canterbury-ptt5-transpose-plus-1mib-window",
            "decision": "no_go_size",
            "input_bytes": input.len(),
            "input_sha256": INPUT_SHA256,
            "candidate_group_bytes": candidate_group.len(),
            "candidate_group_sha256": CANDIDATE_GROUP_SHA256,
            "baseline_frame_bytes": baseline_frame.len(),
            "baseline_frame_sha256": BASELINE_FRAME_SHA256,
            "candidate_frame_bytes": candidate_frame.len(),
            "candidate_frame_sha256": sha256_hex(&candidate_frame),
            "size_gate_bytes": SEVEN_ZIP_FRAME_GATE,
            "round_trip_and_all_entry_hashes_verified": true,
            "entries": entry_hashes,
            "speed_measured": false,
        }));
    }

    if lhc::encode(input, options, &mut || false)? != baseline_frame
        || timed_ptt5_transpose_encode(input, entries, options)?.0 != candidate_frame
    {
        return Err("1-MiB baseline/candidate warm-up was nondeterministic".into());
    }

    let mut baseline_times_ms = Vec::with_capacity(PAIRED_SAMPLES);
    let mut candidate_times_ms = Vec::with_capacity(PAIRED_SAMPLES);
    for sample in 0..PAIRED_SAMPLES {
        if sample % 2 == 0 {
            let (frame, elapsed) = timed_encode(input, options)?;
            if frame != baseline_frame {
                return Err("timed 1-MiB baseline frame diverged".into());
            }
            baseline_times_ms.push(elapsed);

            let (frame, elapsed) = timed_ptt5_transpose_encode(input, entries, options)?;
            if frame != candidate_frame {
                return Err("timed transformed 1-MiB frame diverged".into());
            }
            candidate_times_ms.push(elapsed);
        } else {
            let (frame, elapsed) = timed_ptt5_transpose_encode(input, entries, options)?;
            if frame != candidate_frame {
                return Err("timed transformed 1-MiB frame diverged".into());
            }
            candidate_times_ms.push(elapsed);

            let (frame, elapsed) = timed_encode(input, options)?;
            if frame != baseline_frame {
                return Err("timed 1-MiB baseline frame diverged".into());
            }
            baseline_times_ms.push(elapsed);
        }
    }
    let baseline_median_ms = sample_median_ms(&baseline_times_ms)
        .ok_or("1-MiB baseline timing was empty, non-finite, or non-positive")?;
    let candidate_median_ms = sample_median_ms(&candidate_times_ms)
        .ok_or("1-MiB candidate timing was empty, non-finite, or non-positive")?;

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "fixed-canterbury-ptt5-transpose-plus-1mib-window",
        "decision": if candidate_median_ms < SEVEN_ZIP_ENCODE_MS { "passes_fixed_speed_gate" } else { "no_go_speed" },
        "input_bytes": input.len(),
        "input_sha256": INPUT_SHA256,
        "settings": {
            "algorithm": "Beam",
            "entropy_backend": "Range",
            "beam_model": "Blended",
            "beam_matches": "BT5",
            "beam_width": options.beam_width,
            "beam_block": options.beam_block,
            "dictionary_bytes": options.dictionary,
        },
        "transform": "KHPTX001 + 216-byte x 2376-row row-major to column-major byte transpose",
        "expected_naive_additive_frame_bytes": 482_499,
        "candidate_group_bytes": candidate_group.len(),
        "candidate_group_sha256": CANDIDATE_GROUP_SHA256,
        "baseline_frame_bytes": baseline_frame.len(),
        "baseline_frame_sha256": BASELINE_FRAME_SHA256,
        "candidate_frame_bytes": candidate_frame.len(),
        "candidate_frame_sha256": sha256_hex(&candidate_frame),
        "size_gate_bytes": SEVEN_ZIP_FRAME_GATE,
        "passes_size_gate": passes_size_gate,
        "round_trip_and_all_entry_hashes_verified": true,
        "restored_group_sha256": sha256_hex(&restored_group),
        "entries": entry_hashes,
        "timing": {
            "paired_samples_per_side": PAIRED_SAMPLES,
            "order": "alternating; even samples baseline-first, odd samples candidate-first",
            "candidate_timing_includes": "metadata scan, group copy/rebuild, tag, transpose, LHC encode, and temporary group release",
            "baseline_encode_ms": baseline_times_ms,
            "candidate_transform_plus_encode_ms": candidate_times_ms,
            "baseline_median_ms": baseline_median_ms,
            "candidate_median_ms": candidate_median_ms,
            "fixed_seven_zip_encode_gate_ms": SEVEN_ZIP_ENCODE_MS,
            "saving_vs_paired_baseline_ms": baseline_median_ms - candidate_median_ms,
            "candidate_passes_strict_speed_gate": candidate_median_ms < SEVEN_ZIP_ENCODE_MS,
            "note": "Same-process Instant timing. This fixed Canterbury result is not cross-corpus evidence and does not establish an overall 7-Zip win."
        },
        "holdout_used": false,
    }))
}

fn token_replay_budget_screen(
    input: &[u8],
    options: lhc::Options,
    entries: &[solid::Entry<'_>],
    repeats: u32,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_006;
    const ENTRY_COUNT: usize = 11;
    const BASELINE_FRAME_BYTES: usize = 483_130;
    const SEVEN_ZIP_ENCODE_MS: f64 = 574.5624;
    const INPUT_SHA256: &str = "18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76";
    const ENTRY_LAYOUT: [(&str, usize); ENTRY_COUNT] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];

    if !matches!(options.algorithm, lhc::Algorithm::Beam)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_width != 2
        || options.beam_block != 8192
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
        || options.dictionary != 64 * 1024 * 1024
    {
        return Err(
            "token-replay-budget requires Range/Beam/Blended/BT5/W2/B8192/64MiB defaults".into(),
        );
    }
    if input.len() != INPUT_BYTES
        || sha256_hex(input) != INPUT_SHA256
        || entries.len() != ENTRY_COUNT
        || entries
            .iter()
            .zip(ENTRY_LAYOUT.iter())
            .any(|(entry, (name, bytes))| entry.name != *name || entry.data.len() != *bytes)
        || repeats == 0
    {
        return Err(
            "token-replay-budget requires the fixed 11-entry Canterbury group and nonzero repeats"
                .into(),
        );
    }

    let baseline_frame = lhc::encode(input, options, &mut || false)?;
    if baseline_frame.len() != BASELINE_FRAME_BYTES || baseline_frame.get(9) != Some(&2) {
        return Err("fixed-group Beam baseline frame has an unexpected method or size".into());
    }
    let (trace_payload, selected) = lhc::trace_beam_tokens(input, options, &mut || false)?;
    if baseline_frame.get(lhc::HEADER..) != Some(trace_payload.as_slice()) {
        return Err("captured token-trace payload differs from normal Beam output".into());
    }
    let prepared = lhc::prepare_beam_token_replay(input, &selected)?;
    let replay_frame =
        lhc::replay_beam_token_frame(input, &baseline_frame, &prepared, &mut || false)?;
    if replay_frame != baseline_frame {
        return Err("prepared token replay differs from the baseline frame".into());
    }
    let restored = lhc::decode(&replay_frame, options, &mut || false)?;
    if restored != input || solid::parse(&restored)? != entries {
        return Err("token replay frame failed group round-trip or metadata validation".into());
    }

    // parser/captureや初回page faultを計時へ含めないよう、両経路を同数warm-upする。
    if lhc::encode(input, options, &mut || false)? != baseline_frame
        || lhc::replay_beam_token_frame(input, &baseline_frame, &prepared, &mut || false)?
            != baseline_frame
    {
        return Err("token replay warm-up was nondeterministic".into());
    }

    let repeat_count = usize::try_from(repeats)?;
    let mut baseline_times_ms = Vec::with_capacity(repeat_count);
    let mut replay_times_ms = Vec::with_capacity(repeat_count);
    for sample in 0..repeat_count {
        if sample % 2 == 0 {
            let started = Instant::now();
            let frame = lhc::encode(input, options, &mut || false)?;
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed baseline encode was nondeterministic".into());
            }
            baseline_times_ms.push(elapsed_ms);

            let started = Instant::now();
            let frame =
                lhc::replay_beam_token_frame(input, &baseline_frame, &prepared, &mut || false)?;
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed token replay diverged from the baseline frame".into());
            }
            replay_times_ms.push(elapsed_ms);
        } else {
            let started = Instant::now();
            let frame =
                lhc::replay_beam_token_frame(input, &baseline_frame, &prepared, &mut || false)?;
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed token replay diverged from the baseline frame".into());
            }
            replay_times_ms.push(elapsed_ms);

            let started = Instant::now();
            let frame = lhc::encode(input, options, &mut || false)?;
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if frame != baseline_frame {
                return Err("timed baseline encode was nondeterministic".into());
            }
            baseline_times_ms.push(elapsed_ms);
        }
    }

    let baseline_median_ms = sample_median_ms(&baseline_times_ms)
        .ok_or("baseline timing was empty, non-finite, or non-positive")?;
    let replay_median_ms = sample_median_ms(&replay_times_ms)
        .ok_or("replay timing was empty, non-finite, or non-positive")?;
    let optimistic_parser_budget_ms = SEVEN_ZIP_ENCODE_MS - replay_median_ms;
    Ok(serde_json::json!({
        "experimental": true,
        "screen": "fixed-canterbury-exact-token-replay-budget",
        "input_bytes": input.len(),
        "input_sha256": INPUT_SHA256,
        "logical_entries": group_listing(entries),
        "settings": {
            "algorithm": "Beam",
            "entropy_backend": "Range",
            "beam_model": "Blended",
            "beam_matches": "BT5",
            "beam_width": 2,
            "beam_block": 8192,
            "dictionary_bytes": options.dictionary,
        },
        "baseline_frame_bytes": baseline_frame.len(),
        "selected_token_count": selected.len(),
        "captured_payload_matches_normal_encode": true,
        "replay_frame_byte_identical": true,
        "round_trip_and_group_metadata_verified": true,
        "timing": {
            "paired_samples": repeat_count,
            "order": "alternating; even samples baseline-first, odd samples replay-first",
            "baseline_encode_ms": baseline_times_ms,
            "exact_token_replay_ms": replay_times_ms,
            "baseline_encode_median_ms": baseline_median_ms,
            "exact_token_replay_median_ms": replay_median_ms,
            "fixed_seven_zip_encode_ms": SEVEN_ZIP_ENCODE_MS,
            "optimistic_parser_budget_ms": optimistic_parser_budget_ms,
            "replay_alone_below_seven_zip_gate": replay_median_ms < SEVEN_ZIP_ENCODE_MS,
            "note": "Replay reuses a validated optimal baseline token trace. It includes fresh Range coder/model work and frame copy, but excludes parsing, trace capture/conversion, and recomputing the input CRC from the reusable baseline header. The remaining parser budget is therefore optimistic and is not a speedup or a 7-Zip win."
        },
        "interpretation": "Diagnostic only; an alternative parser must find an equally good parse within this remaining budget, and a separate fixed-group plus held-out E2E must establish an overall win."
    }))
}

fn boundary_census(
    input: &[u8],
    options: lhc::Options,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    // 前回のpaired比較で固定した7-Zip圧縮中央値。この実行の結果では更新しない。
    const SEVEN_ZIP_ENCODE_MS: f64 = 574.5624;
    const SPEED_GATE_RATIO: f64 = 1.3;
    const SIZE_GATE_BYTES: i64 = 483_599;
    let speed_gate_ms = SEVEN_ZIP_ENCODE_MS * SPEED_GATE_RATIO;

    if options.entropy_backend != lhc::EntropyBackend::Range
        || options.beam_width != 2
        || options.beam_block != 8192
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err(
            "boundary-census requires Range/Blended/W2/BT5/B8192 without optional beam modes"
                .into(),
        );
    }
    let entries = solid::parse(input)?;
    let mut spans = Vec::new();
    for entry in &entries {
        let start = span_start(input, entry.data)?;
        let end = start + entry.data.len();
        spans.push((entry.name.to_string(), start, end));
    }
    spans.sort_by_key(|span| span.1);
    if spans.is_empty() || spans[0].1 == 0 {
        return Err("group has no metadata span before the first file".into());
    }
    let mut boundary_ends = Vec::new();
    let mut names = Vec::new();
    names.push("manifest".to_string());
    boundary_ends.push(spans[0].1);
    let mut covered = spans[0].1;
    for (name, start, end) in &spans {
        if *start != covered || *end <= *start {
            return Err("group file spans are not contiguous".into());
        }
        names.push(name.clone());
        boundary_ends.push(*end);
        covered = *end;
    }
    if covered != input.len() {
        return Err("group spans do not cover the input".into());
    }

    let mut beam = options;
    beam.algorithm = lhc::Algorithm::Beam;
    let mut standard = options;
    standard.algorithm = lhc::Algorithm::Standard;
    let mut lazy = options;
    lazy.algorithm = lhc::Algorithm::Lz;

    let (warm_frame, _) = timed_encode(input, beam)?;
    let (beam_frame, beam_ms) = timed_encode(input, beam)?;
    if beam_frame != warm_frame {
        return Err("beam frame was not deterministic".into());
    }
    let decoded = lhc::decode(&beam_frame, beam, &mut || false)?;
    if decoded != input {
        return Err("beam frame failed round-trip".into());
    }
    let (standard_frame, standard_ms) = timed_encode(input, standard)?;
    let (lazy_frame, lazy_ms) = timed_encode(input, lazy)?;
    if lhc::decode(&standard_frame, standard, &mut || false)? != input
        || lhc::decode(&lazy_frame, lazy, &mut || false)? != input
    {
        return Err("fast parser frame failed round-trip".into());
    }

    let (beam_payload, beam_tokens) = lhc::trace_beam_tokens(input, beam, &mut || false)?;
    let (standard_payload, standard_tokens) =
        lhc::trace_standard_tokens(input, standard, &mut || false)?;
    let (lazy_payload, lazy_tokens) = lhc::trace_lz_tokens(input, lazy, &mut || false)?;
    if beam_frame.get(lhc::HEADER..) != Some(beam_payload.as_slice())
        || standard_frame.get(lhc::HEADER..) != Some(standard_payload.as_slice())
        || lazy_frame.get(lhc::HEADER..) != Some(lazy_payload.as_slice())
    {
        return Err("token trace payload differs from the timed frame".into());
    }
    let (beam_replay, beam_preview) =
        lhc::replay_boundary_previews(input, &beam_tokens, &boundary_ends)?;
    let (standard_replay, standard_preview) =
        lhc::replay_standard_boundary_previews(input, &standard_tokens, &boundary_ends)?;
    let (lazy_replay, lazy_preview) =
        lhc::replay_boundary_previews(input, &lazy_tokens, &boundary_ends)?;
    let mismatch = |name: &str, replay: &[u8], original: &[u8]| -> Option<String> {
        if replay == original {
            return None;
        }
        let at = replay
            .iter()
            .zip(original.iter())
            .position(|(left, right)| left != right)
            .unwrap_or(replay.len().min(original.len()));
        Some(format!(
            "{name} replay {} bytes vs original {} bytes, first difference at {at}",
            replay.len(),
            original.len()
        ))
    };
    if let Some(message) = mismatch("beam", &beam_replay, &beam_payload)
        .or_else(|| mismatch("standard", &standard_replay, &standard_payload))
        .or_else(|| mismatch("lazy", &lazy_replay, &lazy_payload))
    {
        return Err(message.into());
    }

    let mut rows = Vec::new();
    let mut previous_beam = 0usize;
    let mut previous_standard = 0usize;
    let mut previous_lazy = 0usize;
    let mut file_beam_ms = Vec::new();
    let mut file_standard_ms = Vec::new();
    for (index, name) in names.iter().enumerate() {
        let plain_end = boundary_ends[index];
        let plain_start = if index == 0 {
            0
        } else {
            boundary_ends[index - 1]
        };
        let beam_marginal = beam_preview[index]
            .checked_sub(previous_beam)
            .ok_or("beam boundary preview went backwards")?;
        let standard_marginal = standard_preview[index]
            .checked_sub(previous_standard)
            .ok_or("standard boundary preview went backwards")?;
        let lazy_marginal = lazy_preview[index]
            .checked_sub(previous_lazy)
            .ok_or("lazy boundary preview went backwards")?;
        previous_beam = beam_preview[index];
        previous_standard = standard_preview[index];
        previous_lazy = lazy_preview[index];
        let (beam_file_ms, standard_file_ms) = if name == "manifest" {
            (0.0, 0.0)
        } else {
            let body = &input[plain_start..plain_end];
            let (_, beam_file_ms) = timed_encode(body, beam)?;
            let (_, standard_file_ms) = timed_encode(body, standard)?;
            (beam_file_ms, standard_file_ms)
        };
        file_beam_ms.push(beam_file_ms);
        file_standard_ms.push(standard_file_ms);
        rows.push(serde_json::json!({
            "name": name,
            "plain_start": plain_start,
            "plain_bytes": plain_end - plain_start,
            "beam_payload_marginal": beam_marginal,
            "standard_payload_marginal": standard_marginal,
            "lazy_lz_payload_marginal": lazy_marginal,
            "standard_minus_beam_bytes": standard_marginal as i64 - beam_marginal as i64,
            "lazy_lz_minus_beam_bytes": lazy_marginal as i64 - beam_marginal as i64,
            "separate_file_beam_encode_ms": beam_file_ms,
            "separate_file_standard_encode_ms": standard_file_ms,
        }));
    }

    let budget = SIZE_GATE_BYTES - beam_frame.len() as i64;
    let file_beam_total: f64 = file_beam_ms.iter().sum();
    let span_count = names.len();
    if span_count > 16 {
        return Err("boundary census supports at most 16 spans".into());
    }
    let mut best_save = f64::MIN;
    let mut best_mask = 0u32;
    let mut best_penalty = 0i64;
    for mask in 0..(1u32 << span_count) {
        let mut penalty = 0i64;
        let mut save = 0.0;
        for index in 0..span_count {
            if mask & (1u32 << index) == 0 {
                continue;
            }
            let standard_marginal =
                rows[index]["standard_payload_marginal"].as_u64().unwrap() as i64;
            let beam_marginal = rows[index]["beam_payload_marginal"].as_u64().unwrap() as i64;
            penalty += standard_marginal - beam_marginal;
            save += file_beam_ms[index] - file_standard_ms[index];
        }
        if penalty <= budget && save > best_save {
            best_save = save;
            best_mask = mask;
            best_penalty = penalty;
        }
    }
    let scaled_ms = if file_beam_total > 0.0 && best_save != f64::MIN {
        beam_ms * (1.0 - best_save / file_beam_total)
    } else {
        f64::MAX
    };
    let passes_size =
        best_save != f64::MIN && beam_frame.len() as i64 + best_penalty <= SIZE_GATE_BYTES;
    let passes_speed = scaled_ms < speed_gate_ms;
    let mut fast_spans = Vec::new();
    for (index, name) in names.iter().enumerate().take(span_count) {
        if best_mask & (1u32 << index) != 0 {
            fast_spans.push(name.clone());
        }
    }

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "solid-file-boundary-payload-contribution",
        "not_a_hybrid_implementation": true,
        "input_bytes": input.len(),
        "frames": {
            "beam_bytes": beam_frame.len(),
            "standard_bytes": standard_frame.len(),
            "lazy_lz_bytes": lazy_frame.len(),
            "beam_round_trip_verified": true,
            "standard_round_trip_verified": true,
            "lazy_lz_round_trip_verified": true,
            "replay_payload_matches_trace": true,
        },
        "single_run_group_encode_ms": {
            "note": "one uninstrumented encode after one beam warmup; not a median and not a 7-Zip comparison",
            "beam": beam_ms,
            "standard": standard_ms,
            "lazy_lz": lazy_ms,
        },
        "spans": rows,
        "gate": {
            "size_gate_bytes": SIZE_GATE_BYTES,
            "size_budget_above_beam_bytes": budget,
            "seven_zip_encode_ms_fixed_before_this_run": SEVEN_ZIP_ENCODE_MS,
            "speed_gate_ratio": SPEED_GATE_RATIO,
            "speed_gate_ms": speed_gate_ms,
            "time_model": "Separate-file beam/standard times choose which spans may switch to Standard. Their time ratio scales this process's solid beam encode. Manifest has no separate-file time.",
            "best_standard_spans": fast_spans,
            "best_standard_payload_penalty_bytes": best_penalty,
            "estimated_hybrid_frame_bytes": beam_frame.len() as i64 + best_penalty,
            "separate_file_beam_time_saved_ms": if best_save == f64::MIN { 0.0 } else { best_save },
            "scaled_solid_encode_ms": scaled_ms,
            "passes_size_gate": passes_size,
            "passes_speed_gate": passes_speed,
            "passes_both_gates": passes_size && passes_speed,
        },
    }))
}

#[derive(Clone)]
struct SpliceCandidate {
    name: String,
    part: usize,
    start: usize,
    end: usize,
}

#[derive(Clone, Copy)]
struct SpliceRegion {
    start: usize,
    end: usize,
    candidate: Option<usize>,
}

fn hybrid_splice_layout(
    input: &[u8],
) -> Result<(Vec<SpliceCandidate>, Vec<SpliceRegion>), Box<dyn std::error::Error>> {
    const PARTS_PER_FILE: usize = 16;
    const TARGETS: [(&str, usize); 4] = [
        ("kennedy.xls", 1_029_744),
        ("plrabn12.txt", 481_861),
        ("lcet10.txt", 426_754),
        ("ptt5", 513_216),
    ];
    if input.len() != 2_811_006 {
        return Err(
            "hybrid-splice-screen requires the fixed 2,811,006-byte Canterbury group".into(),
        );
    }

    let entries = solid::parse(input)?;
    let mut spans = Vec::new();
    for entry in &entries {
        let start = span_start(input, entry.data)?;
        let end = start
            .checked_add(entry.data.len())
            .ok_or("solid span overflow")?;
        spans.push((entry.name.to_string(), start, end));
    }
    spans.sort_by_key(|span| span.1);
    if spans.is_empty() || spans[0].1 == 0 {
        return Err("group has no metadata span before the first file".into());
    }

    let mut candidates = Vec::with_capacity(TARGETS.len() * PARTS_PER_FILE);
    let mut regions = Vec::with_capacity(entries.len() + candidates.capacity());
    let mut seen = [false; TARGETS.len()];
    regions.push(SpliceRegion {
        start: 0,
        end: spans[0].1,
        candidate: None,
    });
    let mut covered = spans[0].1;
    for (name, start, end) in spans {
        if start != covered || end <= start {
            return Err("group file spans are not contiguous".into());
        }
        if let Some((target_index, (_, expected_len))) = TARGETS
            .iter()
            .enumerate()
            .find(|(_, (target_name, _))| *target_name == name)
        {
            if end - start != *expected_len || seen[target_index] {
                return Err(format!("unexpected span for target file {name}").into());
            }
            seen[target_index] = true;
            for part in 0..PARTS_PER_FILE {
                let part_start = start + ((end - start) * part / PARTS_PER_FILE);
                let part_end = start + ((end - start) * (part + 1) / PARTS_PER_FILE);
                if part_end <= part_start {
                    return Err(format!("empty partition in {name}").into());
                }
                let candidate = candidates.len();
                candidates.push(SpliceCandidate {
                    name: name.clone(),
                    part,
                    start: part_start,
                    end: part_end,
                });
                regions.push(SpliceRegion {
                    start: part_start,
                    end: part_end,
                    candidate: Some(candidate),
                });
            }
        } else {
            regions.push(SpliceRegion {
                start,
                end,
                candidate: None,
            });
        }
        covered = end;
    }
    if covered != input.len() || seen.iter().any(|found| !found) {
        return Err("group spans or target files do not match the fixed census".into());
    }
    if candidates.len() != TARGETS.len() * PARTS_PER_FILE {
        return Err("unexpected internal partition count".into());
    }
    Ok((candidates, regions))
}

fn append_splice_source_range(
    source: &[lhc::SelectedToken],
    start: usize,
    end: usize,
    output: &mut Vec<lhc::SelectedToken>,
) -> Result<(), Box<dyn std::error::Error>> {
    if start >= end {
        return Err("empty splice source range".into());
    }
    let start_u64 = u64::try_from(start)?;
    let first = source
        .partition_point(|token| u64::from(token.offset) + u64::from(token.length) <= start_u64);
    let mut covered = start;
    for token in &source[first..] {
        let token_start = usize::try_from(token.offset)?;
        if token_start >= end {
            break;
        }
        let token_end = token_start
            .checked_add(usize::try_from(token.length)?)
            .ok_or("token span overflow")?;
        let clipped_start = token_start.max(start);
        let clipped_end = token_end.min(end);
        if clipped_start != covered || clipped_end <= clipped_start {
            return Err("parser trace does not cover a splice range contiguously".into());
        }
        output.try_reserve(1)?;
        output.push(lhc::SelectedToken {
            offset: u32::try_from(clipped_start)?,
            length: u32::try_from(clipped_end - clipped_start)?,
            distance: token.distance,
            kind: token.kind,
            rep_index: token.rep_index,
        });
        covered = clipped_end;
    }
    if covered != end {
        return Err("parser trace ended before a splice range".into());
    }
    Ok(())
}

fn move_splice_rep(reps: &mut [usize; 4], index: usize) {
    let distance = reps[index];
    for at in (1..=index).rev() {
        reps[at] = reps[at - 1];
    }
    reps[0] = distance;
}

fn add_splice_distance(reps: &mut [usize; 4], distance: usize) {
    reps[3] = reps[2];
    reps[2] = reps[1];
    reps[1] = reps[0];
    reps[0] = distance;
}

fn push_splice_literal(
    output: &mut Vec<lhc::SelectedToken>,
    offset: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    output.try_reserve(1)?;
    output.push(lhc::SelectedToken {
        offset: u32::try_from(offset)?,
        length: 1,
        distance: 0,
        kind: 0,
        rep_index: 0,
    });
    Ok(())
}

fn normalize_spliced_tokens(
    input: &[u8],
    raw: &[lhc::SelectedToken],
    dictionary: usize,
) -> Result<Vec<lhc::SelectedToken>, Box<dyn std::error::Error>> {
    let mut output = Vec::new();
    output.try_reserve(raw.len())?;
    let mut reps = [1usize; 4];
    let mut covered = 0usize;
    for token in raw {
        let start = usize::try_from(token.offset)?;
        let length = usize::try_from(token.length)?;
        let end = start.checked_add(length).ok_or("token span overflow")?;
        if start != covered || length == 0 || end > input.len() {
            return Err("spliced token trace is not contiguous".into());
        }
        if token.kind == 0 {
            if length != 1 || token.distance != 0 {
                return Err("invalid literal in spliced token trace".into());
            }
            push_splice_literal(&mut output, start)?;
            covered = end;
            continue;
        }

        let distance = usize::try_from(token.distance)?;
        if distance == 0 || distance > start || distance > dictionary {
            return Err("invalid copy distance in spliced token trace".into());
        }
        if input[start..end] != input[start - distance..end - distance] {
            return Err("spliced copy does not reproduce the input".into());
        }

        let preferred_rep = if token.kind == 2 {
            let index = usize::from(token.rep_index);
            (index < reps.len() && reps[index] == distance)
                .then_some(index)
                .or_else(|| reps.iter().position(|&value| value == distance))
        } else {
            reps.iter().position(|&value| value == distance)
        };
        let encoded = match token.kind {
            1 if length == 1 && reps[0] == distance => Some((1u8, 0u8)),
            1 if length == 1 => None,
            1 => return Err("short-rep trace has an invalid length".into()),
            2 if length == 1 && reps[0] == distance => Some((1, 0)),
            2 if length == 1 => None,
            2 if let Some(index) = preferred_rep => Some((2, u8::try_from(index)?)),
            2 if length >= 3 => Some((3, 0)),
            2 => None,
            3 if length >= 3 => Some((3, 0)),
            3 if length == 1 && reps[0] == distance => Some((1, 0)),
            3 if length == 2
                && let Some(index) = preferred_rep =>
            {
                Some((2, u8::try_from(index)?))
            }
            3 => None,
            _ => return Err("unknown token kind in spliced trace".into()),
        };

        let Some((kind, rep_index)) = encoded else {
            for offset in start..end {
                push_splice_literal(&mut output, offset)?;
            }
            covered = end;
            continue;
        };
        output.try_reserve(1)?;
        output.push(lhc::SelectedToken {
            offset: u32::try_from(start)?,
            length: u32::try_from(length)?,
            distance: u32::try_from(distance)?,
            kind,
            rep_index,
        });
        match kind {
            1 => {}
            2 => move_splice_rep(&mut reps, usize::from(rep_index)),
            3 => add_splice_distance(&mut reps, distance),
            _ => return Err("invalid normalized token kind".into()),
        }
        covered = end;
    }
    if covered != input.len() {
        return Err("spliced token trace does not cover the input".into());
    }
    Ok(output)
}

fn build_spliced_tokens(
    input: &[u8],
    beam_tokens: &[lhc::SelectedToken],
    lazy_tokens: &[lhc::SelectedToken],
    candidates: &[SpliceCandidate],
    regions: &[SpliceRegion],
    selected: &[bool],
    dictionary: usize,
) -> Result<Vec<lhc::SelectedToken>, Box<dyn std::error::Error>> {
    if selected.len() != candidates.len() {
        return Err("splice selection length does not match candidate count".into());
    }
    let mut raw = Vec::new();
    let mut merged: Vec<(usize, usize, bool)> = Vec::new();
    for region in regions {
        let use_lazy = region.candidate.is_some_and(|index| selected[index]);
        if region.start >= region.end {
            return Err("empty splice region".into());
        }
        if let Some(last) = merged.last_mut()
            && last.1 == region.start
            && last.2 == use_lazy
        {
            last.1 = region.end;
            continue;
        }
        merged.push((region.start, region.end, use_lazy));
    }
    let mut covered = 0usize;
    for (start, end, use_lazy) in merged {
        if start != covered {
            return Err("splice regions are not contiguous".into());
        }
        let source = if use_lazy { lazy_tokens } else { beam_tokens };
        append_splice_source_range(source, start, end, &mut raw)?;
        covered = end;
    }
    if covered != input.len() {
        return Err("splice regions do not cover the input".into());
    }
    normalize_spliced_tokens(input, &raw, dictionary)
}

#[expect(
    clippy::too_many_arguments,
    reason = "研究用比較の入力と状態を独立した引数として保持する"
)]
fn encode_spliced_frame(
    input: &[u8],
    header: &[u8],
    options: lhc::Options,
    beam_tokens: &[lhc::SelectedToken],
    lazy_tokens: &[lhc::SelectedToken],
    candidates: &[SpliceCandidate],
    regions: &[SpliceRegion],
    selected: &[bool],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    if header.len() < lhc::HEADER {
        return Err("baseline frame is shorter than its header".into());
    }
    let tokens = build_spliced_tokens(
        input,
        beam_tokens,
        lazy_tokens,
        candidates,
        regions,
        selected,
        options.dictionary,
    )?;
    let (payload, previews) = lhc::replay_boundary_previews(input, &tokens, &[input.len()])?;
    if previews.as_slice() != [payload.len()] {
        return Err("spliced replay final preview differs from payload length".into());
    }
    let frame = lhc::frame_with_payload(header, &payload)?;
    let decoded = lhc::decode(&frame, options, &mut || false)
        .map_err(|error| format!("spliced frame decoder rejected payload: {error}"))?;
    if decoded != input {
        return Err("spliced frame failed full-input round-trip".into());
    }
    Ok(frame)
}

fn merge_splice_regions(
    candidates: &[SpliceCandidate],
    selected: &[bool],
) -> Result<Vec<(usize, usize)>, Box<dyn std::error::Error>> {
    if selected.len() != candidates.len() {
        return Err("splice region selection has the wrong length".into());
    }
    let mut regions = Vec::<(usize, usize)>::new();
    for (candidate, &chosen) in candidates.iter().zip(selected) {
        if !chosen {
            continue;
        }
        if candidate.start >= candidate.end {
            return Err("splice candidate has an invalid range".into());
        }
        if let Some(last) = regions.last_mut() {
            if candidate.start < last.1 {
                return Err("splice candidates overlap or are not sorted".into());
            }
            if last.1 == candidate.start {
                last.1 = candidate.end;
                continue;
            }
        }
        regions.push((candidate.start, candidate.end));
    }
    Ok(regions)
}

fn encode_single_pass_hybrid_frame(
    input: &[u8],
    header: &[u8],
    options: lhc::Options,
    regions: &[(usize, usize)],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let payload = lhc::encode_beam_lz_regions(input, options, regions, &mut || false)?;
    Ok(lhc::frame_with_payload(header, &payload)?)
}

fn hybrid_splice_screen(
    input: &[u8],
    options: lhc::Options,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const SIZE_GATE_BYTES: usize = 483_599;
    const PARTS_PER_FILE: usize = 16;
    if options.entropy_backend != lhc::EntropyBackend::Range
        || options.dictionary != 64 * 1024 * 1024
        || options.beam_width != 2
        || options.beam_block != 8192
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.bt_nice_len != 0
    {
        return Err("hybrid-splice-screen requires Range/Blended/W2/BT5/B8192/64MiB without optional beam modes".into());
    }
    let (candidates, regions) = hybrid_splice_layout(input)?;
    let mut beam_options = options;
    beam_options.algorithm = lhc::Algorithm::Beam;
    let mut lazy_options = options;
    lazy_options.algorithm = lhc::Algorithm::Lz;
    let beam_frame = lhc::encode(input, beam_options, &mut || false)?;
    let beam_repeat = lhc::encode(input, beam_options, &mut || false)?;
    let lazy_frame = lhc::encode(input, lazy_options, &mut || false)?;
    let lazy_repeat = lhc::encode(input, lazy_options, &mut || false)?;
    if beam_frame != beam_repeat || lazy_frame != lazy_repeat {
        return Err("source parser frame is not deterministic".into());
    }
    if beam_frame.len() != 483_130 || beam_frame.get(9) != Some(&2) {
        return Err("fixed Beam method-2 baseline frame changed".into());
    }
    if lazy_frame.get(9) != Some(&2) {
        return Err("lazy LZ source frame is not method 2".into());
    }
    if lhc::decode(&beam_frame, beam_options, &mut || false)? != input
        || lhc::decode(&lazy_frame, lazy_options, &mut || false)? != input
    {
        return Err("source parser frame failed full-input round-trip".into());
    }
    let (beam_payload, beam_tokens) = lhc::trace_beam_tokens(input, beam_options, &mut || false)?;
    let (lazy_payload, lazy_tokens) = lhc::trace_lz_tokens(input, lazy_options, &mut || false)?;
    if beam_frame.get(lhc::HEADER..) != Some(beam_payload.as_slice())
        || lazy_frame.get(lhc::HEADER..) != Some(lazy_payload.as_slice())
    {
        return Err("parser token-trace payload differs from its ordinary frame".into());
    }

    let empty = vec![false; candidates.len()];
    let replayed_beam = encode_spliced_frame(
        input,
        &beam_frame,
        beam_options,
        &beam_tokens,
        &lazy_tokens,
        &candidates,
        &regions,
        &empty,
    )
    .map_err(|error| format!("baseline no-op splice failed: {error}"))?;
    if replayed_beam != beam_frame {
        return Err("no-op splice changed the Beam frame".into());
    }

    let mut single_deltas = Vec::with_capacity(candidates.len());
    let mut candidate_rows = Vec::with_capacity(candidates.len());
    for (index, candidate) in candidates.iter().enumerate() {
        let mut selected = vec![false; candidates.len()];
        selected[index] = true;
        let frame = encode_spliced_frame(
            input,
            &beam_frame,
            beam_options,
            &beam_tokens,
            &lazy_tokens,
            &candidates,
            &regions,
            &selected,
        )
        .map_err(|error| format!("single splice interval {index} failed: {error}"))?;
        let delta = i64::try_from(frame.len())? - i64::try_from(beam_frame.len())?;
        single_deltas.push(delta);
        candidate_rows.push(serde_json::json!({
            "index": index,
            "file": candidate.name,
            "part": candidate.part,
            "start": candidate.start,
            "end": candidate.end,
            "input_bytes": candidate.end - candidate.start,
            "exact_single_splice_frame_bytes": frame.len(),
            "exact_delta_from_beam_bytes": delta,
            "round_trip_verified": true,
        }));
    }

    let mut order: Vec<usize> = (0..candidates.len()).collect();
    order.sort_by(|&left, &right| {
        let left_len = (candidates[left].end - candidates[left].start) as f64;
        let right_len = (candidates[right].end - candidates[right].start) as f64;
        (single_deltas[left] as f64 / left_len)
            .total_cmp(&(single_deltas[right] as f64 / right_len))
            .then_with(|| left.cmp(&right))
    });
    let mut selected = vec![false; candidates.len()];
    let mut accepted = Vec::new();
    let mut current_bytes = beam_frame.len();
    for index in order {
        selected[index] = true;
        let frame = encode_spliced_frame(
            input,
            &beam_frame,
            beam_options,
            &beam_tokens,
            &lazy_tokens,
            &candidates,
            &regions,
            &selected,
        )
        .map_err(|error| format!("greedy splice interval {index} failed: {error}"))?;
        if frame.len() <= SIZE_GATE_BYTES {
            let candidate = &candidates[index];
            accepted.push(serde_json::json!({
                "index": index,
                "file": candidate.name,
                "part": candidate.part,
                "start": candidate.start,
                "end": candidate.end,
                "input_bytes": candidate.end - candidate.start,
                "exact_marginal_bytes": i64::try_from(frame.len())? - i64::try_from(current_bytes)?,
                "combined_frame_bytes": frame.len(),
            }));
            current_bytes = frame.len();
        } else {
            selected[index] = false;
        }
    }
    let selected_bytes: usize = candidates
        .iter()
        .zip(&selected)
        .filter_map(|(candidate, chosen)| chosen.then_some(candidate.end - candidate.start))
        .sum();
    let selected_count = selected.iter().filter(|&&chosen| chosen).count();
    let oracle_hybrid_regions = merge_splice_regions(&candidates, &selected)?;
    let no_op_hybrid_payload =
        lhc::encode_beam_lz_regions(input, beam_options, &[], &mut || false)?;
    if lhc::frame_with_payload(&beam_frame, &no_op_hybrid_payload)? != beam_frame {
        return Err("single-pass no-op hybrid changed the Beam baseline".into());
    }

    const ACTUAL_SUBSET_CANDIDATES: [usize; 6] = [7, 8, 9, 10, 48, 63];
    if ACTUAL_SUBSET_CANDIDATES
        .iter()
        .any(|&index| index >= candidates.len())
    {
        return Err("single-pass subset candidate index is out of range".into());
    }
    let mut actual_subset_results = Vec::with_capacity(1 << ACTUAL_SUBSET_CANDIDATES.len());
    let mut actual_passing_subset_count = 0usize;
    let mut actual_size_passing_schedules = Vec::new();
    type ActualSubsetCandidate = (u64, Vec<(usize, usize)>, Vec<u8>);
    let mut best_actual_any: Option<ActualSubsetCandidate> = None;
    let mut best_actual_passing: Option<ActualSubsetCandidate> = None;
    for mask in 0u64..(1u64 << ACTUAL_SUBSET_CANDIDATES.len()) {
        let mut subset = vec![false; candidates.len()];
        for (bit, &candidate_index) in ACTUAL_SUBSET_CANDIDATES.iter().enumerate() {
            subset[candidate_index] = mask & (1u64 << bit) != 0;
        }
        let subset_regions = merge_splice_regions(&candidates, &subset)?;
        let frame =
            encode_single_pass_hybrid_frame(input, &beam_frame, beam_options, &subset_regions)?;
        if mask == 0 && frame != beam_frame {
            return Err("single-pass subset mask zero changed the Beam baseline".into());
        }
        if lhc::decode(&frame, beam_options, &mut || false)? != input {
            return Err(format!("single-pass subset mask {mask} failed round-trip").into());
        }
        let passes_size_gate = frame.len() <= SIZE_GATE_BYTES;
        let nonempty_passes_gate = mask != 0 && passes_size_gate;
        if nonempty_passes_gate {
            actual_passing_subset_count += 1;
            actual_size_passing_schedules.push((mask, subset_regions.clone(), frame.clone()));
            let replace = best_actual_passing
                .as_ref()
                .is_none_or(|(best_mask, _, best_frame)| {
                    frame.len() < best_frame.len()
                        || (frame.len() == best_frame.len()
                            && mask.count_ones() < best_mask.count_ones())
                });
            if replace {
                best_actual_passing = Some((mask, subset_regions.clone(), frame.clone()));
            }
        }
        if mask != 0 {
            let replace = best_actual_any
                .as_ref()
                .is_none_or(|(best_mask, _, best_frame)| {
                    frame.len() < best_frame.len()
                        || (frame.len() == best_frame.len()
                            && mask.count_ones() < best_mask.count_ones())
                });
            if replace {
                best_actual_any = Some((mask, subset_regions.clone(), frame.clone()));
            }
        }
        actual_subset_results.push(serde_json::json!({
            "mask": mask,
            "selected_candidates": ACTUAL_SUBSET_CANDIDATES
                .iter()
                .enumerate()
                .filter_map(|(bit, &index)| (mask & (1u64 << bit) != 0).then_some(index))
                .collect::<Vec<_>>(),
            "regions": subset_regions,
            "frame_bytes": frame.len(),
            "passes_7zip_size_gate": passes_size_gate,
            "nonempty_candidate": mask != 0,
            "round_trip_verified": true,
        }));
    }
    let (execution_mask, execution_regions, initial_hybrid_frame) = best_actual_passing
        .or(best_actual_any)
        .ok_or("single-pass subset search produced no nonempty candidate")?;
    const TIMED_REPEATS: usize = 9;
    let timing_schedules = if actual_size_passing_schedules.is_empty() {
        vec![(
            execution_mask,
            execution_regions.clone(),
            initial_hybrid_frame.clone(),
        )]
    } else {
        actual_size_passing_schedules
    };
    let mut beam_times_by_schedule_ms = (0..timing_schedules.len())
        .map(|_| Vec::with_capacity(TIMED_REPEATS))
        .collect::<Vec<_>>();
    let mut hybrid_times_by_schedule_ms = (0..timing_schedules.len())
        .map(|_| Vec::with_capacity(TIMED_REPEATS))
        .collect::<Vec<_>>();
    let encode_beam_sample = || -> Result<(Vec<u8>, f64), Box<dyn std::error::Error>> {
        let started = Instant::now();
        let frame = lhc::encode(input, beam_options, &mut || false)?;
        Ok((frame, started.elapsed().as_secs_f64() * 1000.0))
    };
    for repeat in 0..TIMED_REPEATS {
        for offset in 0..timing_schedules.len() {
            let schedule_index = (offset + repeat) % timing_schedules.len();
            let (schedule_mask, schedule_regions, expected_frame) =
                &timing_schedules[schedule_index];
            let (repeated_beam, beam_elapsed, repeated_hybrid, hybrid_elapsed) = if repeat % 2 == 0
            {
                let (beam, beam_elapsed) = encode_beam_sample()?;
                let started = Instant::now();
                let hybrid = encode_single_pass_hybrid_frame(
                    input,
                    &beam_frame,
                    beam_options,
                    schedule_regions,
                )?;
                (
                    beam,
                    beam_elapsed,
                    hybrid,
                    started.elapsed().as_secs_f64() * 1000.0,
                )
            } else {
                let started = Instant::now();
                let hybrid = encode_single_pass_hybrid_frame(
                    input,
                    &beam_frame,
                    beam_options,
                    schedule_regions,
                )?;
                let hybrid_elapsed = started.elapsed().as_secs_f64() * 1000.0;
                let (beam, beam_elapsed) = encode_beam_sample()?;
                (beam, beam_elapsed, hybrid, hybrid_elapsed)
            };
            beam_times_by_schedule_ms[schedule_index].push(beam_elapsed);
            hybrid_times_by_schedule_ms[schedule_index].push(hybrid_elapsed);
            if repeated_beam != beam_frame {
                return Err("timed Beam encoding changed its deterministic baseline".into());
            }
            if &repeated_hybrid != expected_frame {
                return Err(format!(
                    "single-pass hybrid schedule {schedule_mask} was not deterministic"
                )
                .into());
            }
            if lhc::decode(&repeated_hybrid, beam_options, &mut || false)? != input {
                return Err(format!(
                    "single-pass hybrid schedule {schedule_mask} failed its full-input round-trip"
                )
                .into());
            }
        }
    }
    let mut timed_size_passing_candidates = Vec::with_capacity(timing_schedules.len());
    let mut selected_times_ms = None;
    for (index, (mask, regions, frame)) in timing_schedules.iter().enumerate() {
        let beam_times_ms = &mut beam_times_by_schedule_ms[index];
        let hybrid_times_ms = &mut hybrid_times_by_schedule_ms[index];
        beam_times_ms.sort_by(f64::total_cmp);
        hybrid_times_ms.sort_by(f64::total_cmp);
        let beam_median_ms = beam_times_ms[beam_times_ms.len() / 2];
        let hybrid_median_ms = hybrid_times_ms[hybrid_times_ms.len() / 2];
        timed_size_passing_candidates.push(serde_json::json!({
            "mask": mask,
            "selected_candidate_indices": ACTUAL_SUBSET_CANDIDATES
                .iter()
                .enumerate()
                .filter_map(|(bit, &candidate)| (mask & (1u64 << bit) != 0).then_some(candidate))
                .collect::<Vec<_>>(),
            "regions": regions.iter().map(|&(start, end)| serde_json::json!({
                "start": start,
                "end": end,
                "input_bytes": end - start,
            })).collect::<Vec<_>>(),
            "frame_bytes": frame.len(),
            "size_gate_passed": frame.len() <= SIZE_GATE_BYTES,
            "repeats": TIMED_REPEATS,
            "beam_encode_ms": beam_times_ms,
            "single_pass_hybrid_encode_ms": hybrid_times_ms,
            "beam_median_ms": beam_median_ms,
            "single_pass_hybrid_median_ms": hybrid_median_ms,
            "median_saving_ms": beam_median_ms - hybrid_median_ms,
            "median_speedup": beam_median_ms / hybrid_median_ms,
        }));
        if *mask == execution_mask {
            selected_times_ms = Some((beam_times_ms.clone(), hybrid_times_ms.clone()));
        }
    }
    let (beam_times_ms, hybrid_times_ms) =
        selected_times_ms.ok_or("selected schedule was not measured")?;
    let beam_median_ms = beam_times_ms[beam_times_ms.len() / 2];
    let hybrid_median_ms = hybrid_times_ms[hybrid_times_ms.len() / 2];
    let hybrid_frame = initial_hybrid_frame;
    let all_targets = vec![true; candidates.len()];
    let all_target_frame = encode_spliced_frame(
        input,
        &beam_frame,
        beam_options,
        &beam_tokens,
        &lazy_tokens,
        &candidates,
        &regions,
        &all_targets,
    )
    .map_err(|error| format!("all-target splice failed: {error}"))?;
    Ok(serde_json::json!({
        "experimental": true,
        "screen": "exact-method2-splice-and-single-pass-hybrid",
        "input_bytes": input.len(),
        "method": "An exact mixed-token splice is used only as a size oracle; a separate single-pass hybrid switches Beam and BT-candidate lazy parsing over fixed ranges while sharing Range models and Rep history.",
        "candidate_parser": "lazy LZ; Standard is excluded because it uses a different method-1 grammar",
        "partitions_per_file": PARTS_PER_FILE,
        "target_files": ["kennedy.xls", "plrabn12.txt", "lcet10.txt", "ptt5"],
        "frames": {
            "beam_bytes": beam_frame.len(),
            "beam_round_trip_verified": true,
            "lazy_lz_bytes": lazy_frame.len(),
            "lazy_lz_round_trip_verified": true,
            "single_pass_hybrid_bytes": hybrid_frame.len(),
            "single_pass_hybrid_round_trip_verified": true,
            "single_pass_no_op_matches_beam": true,
            "no_op_splice_matches_beam": true,
            "all_target_files_lazy_exact_frame_bytes": all_target_frame.len(),
            "all_target_files_lazy_round_trip_verified": true,
        },
        "single_interval_exact_results": candidate_rows,
        "size_budget_greedy": {
            "policy": "sort by exact single-interval byte delta per input byte, then fully replay and decode every proposed cumulative combination; accept only if the exact combined frame remains within the fixed 7-Zip size gate",
            "size_gate_bytes": SIZE_GATE_BYTES,
            "selected_count": selected_count,
            "selected_input_bytes": selected_bytes,
            "selected_input_fraction": selected_bytes as f64 / input.len() as f64,
            "exact_combined_frame_bytes": current_bytes,
            "passes_size_gate": current_bytes <= SIZE_GATE_BYTES,
            "accepted_intervals": accepted,
        },
        "single_pass_schedule": {
            "selected_interval_count": selected_count,
            "merged_region_count": oracle_hybrid_regions.len(),
            "regions": oracle_hybrid_regions.iter().map(|&(start, end)| serde_json::json!({
                "start": start,
                "end": end,
                "input_bytes": end - start,
            })).collect::<Vec<_>>(),
            "selection_cost_included_in_timing": false,
            "note": "The fixed regions come from the preceding two-full-trace size oracle and are corpus-specific; this is a capability experiment, not a production selection policy.",
        },
        "single_pass_actual_subset_search": {
            "candidate_indices": ACTUAL_SUBSET_CANDIDATES,
            "combinations": actual_subset_results.len(),
            "nonempty_combinations_passing_7zip_size_gate": actual_passing_subset_count,
            "selected_mask": execution_mask,
            "selected_candidate_indices": ACTUAL_SUBSET_CANDIDATES
                .iter()
                .enumerate()
                .filter_map(|(bit, &index)| (execution_mask & (1u64 << bit) != 0).then_some(index))
                .collect::<Vec<_>>(),
            "selected_regions": execution_regions.iter().map(|&(start, end)| serde_json::json!({
                "start": start,
                "end": end,
                "input_bytes": end - start,
            })).collect::<Vec<_>>(),
            "selected_frame_bytes": hybrid_frame.len(),
            "selected_passes_7zip_size_gate": hybrid_frame.len() <= SIZE_GATE_BYTES,
            "results": actual_subset_results,
        },
        "speed": {
            "measured": true,
            "measurement": "nine paired Release encodes on the same input; Beam/hybrid order alternates; frame assembly is included and decoding is excluded",
            "offline_trace_selection_cost_included": false,
            "subset_search_cost_included": false,
            "measured_schedule_mask": execution_mask,
            "repeats": TIMED_REPEATS,
            "beam_encode_ms": beam_times_ms,
            "single_pass_hybrid_encode_ms": hybrid_times_ms,
            "beam_median_ms": beam_median_ms,
            "single_pass_hybrid_median_ms": hybrid_median_ms,
            "median_saving_ms": beam_median_ms - hybrid_median_ms,
            "median_speedup": beam_median_ms / hybrid_median_ms,
            "timed_size_passing_candidate_count": actual_passing_subset_count,
            "size_passing_candidate_results": timed_size_passing_candidates,
        },
    }))
}

fn hybrid_content_order_region_screen(
    input: &[u8],
    options: lhc::Options,
    entries: &[solid::Entry<'_>],
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_028;
    const BASELINE_FRAME_BYTES: usize = 480_777;
    const SEVEN_ZIP_SIZE_GATE: usize = 483_599;
    const SEVEN_ZIP_ONE_THREAD_MS: f64 = 574.5624;
    const TIMED_PAIRS: usize = 9;
    const EXPECTED_LOGICAL: [(&str, usize); 11] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];
    const EXPECTED_PHYSICAL: [&str; 11] = [
        "xargs.1",
        "asyoulik.txt",
        "plrabn12.txt",
        "lcet10.txt",
        "alice29.txt",
        "cp.html",
        "fields.c",
        "sum",
        "ptt5",
        "kennedy.xls",
        "grammar.lsp",
    ];

    if input.len() != INPUT_BYTES
        || entries.len() != EXPECTED_LOGICAL.len()
        || !matches!(options.algorithm, lhc::Algorithm::Beam)
        || options.entropy_backend != lhc::EntropyBackend::Range
        || options.dictionary != 64 * 1024 * 1024
        || options.beam_width != 2
        || options.beam_block != 8192
        || !matches!(options.beam_model, lhc::BeamModel::Blended)
        || !matches!(options.beam_matches, lhc::BeamMatches::Bt5)
        || options.beam_fixed_boundaries
        || options.beam_batch_blocks != 1
        || options.beam_greedy_seeds
        || options.beam_rep_diverse_third_parent
        || options.beam_fixed_rep_history
        || options.beam_history_seeded
        || options.bt_nice_len != 0
    {
        return Err("content-order region screen requires the fixed group and plain Range/Blended/W2/BT5/B8192/64MiB Beam baseline".into());
    }
    for (entry, &(expected_name, expected_len)) in entries.iter().zip(&EXPECTED_LOGICAL) {
        if entry.name != expected_name || entry.data.len() != expected_len {
            return Err(
                "content-order logical group entries differ from the fixed Canterbury census"
                    .into(),
            );
        }
    }

    let mut spans = entries
        .iter()
        .map(|entry| {
            let start = span_start(input, entry.data)?;
            let end = start
                .checked_add(entry.data.len())
                .ok_or("group span overflow")?;
            Ok((entry.name, start, end))
        })
        .collect::<Result<Vec<_>, Box<dyn std::error::Error>>>()?;
    spans.sort_by_key(|span| span.1);
    let physical_order = spans.iter().map(|span| span.0).collect::<Vec<_>>();
    if physical_order != EXPECTED_PHYSICAL {
        return Err("content-order physical entry order differs from the fixed hypothesis".into());
    }
    let mut covered = spans.first().ok_or("group has no data spans")?.1;
    for &(_, start, end) in &spans {
        if start != covered || end <= start {
            return Err("content-order group data spans are not contiguous".into());
        }
        covered = end;
    }
    if covered != input.len() {
        return Err("content-order group spans do not cover the input".into());
    }
    let (ptt_start, ptt_end) = spans
        .iter()
        .find_map(|&(name, start, end)| (name == "ptt5").then_some((start, end)))
        .ok_or("ptt5 span is missing")?;
    let (kennedy_start, kennedy_end) = spans
        .iter()
        .find_map(|&(name, start, end)| (name == "kennedy.xls").then_some((start, end)))
        .ok_or("kennedy.xls span is missing")?;
    if ptt_end != kennedy_start || kennedy_end - ptt_start != 1_542_960 {
        return Err(
            "ptt5 and kennedy.xls are not the expected adjacent 1,542,960-byte region".into(),
        );
    }
    let region = [(ptt_start, kennedy_end)];

    let beam_frame = lhc::encode(input, options, &mut || false)?;
    let beam_repeat = lhc::encode(input, options, &mut || false)?;
    if beam_frame != beam_repeat
        || beam_frame.len() != BASELINE_FRAME_BYTES
        || beam_frame.get(9) != Some(&2)
        || lhc::decode(&beam_frame, options, &mut || false)? != input
    {
        return Err(
            "content-order Beam baseline failed deterministic 480,777-byte method-2 E2E".into(),
        );
    }
    let beam_decoded = lhc::decode(&beam_frame, options, &mut || false)?;
    if solid::parse(&beam_decoded)? != entries {
        return Err("content-order Beam baseline logical entries differ after decode".into());
    }

    let no_op_payload = lhc::encode_beam_lz_regions(input, options, &[], &mut || false)?;
    if lhc::frame_with_payload(&beam_frame, &no_op_payload)? != beam_frame {
        return Err("no-op single-pass hybrid differs from the Beam baseline".into());
    }
    let candidate_payload = lhc::encode_beam_lz_regions(input, options, &region, &mut || false)?;
    let candidate = lhc::frame_with_payload(&beam_frame, &candidate_payload)?;
    let candidate_repeat_payload =
        lhc::encode_beam_lz_regions(input, options, &region, &mut || false)?;
    let candidate_repeat = lhc::frame_with_payload(&beam_frame, &candidate_repeat_payload)?;
    if candidate != candidate_repeat || candidate.get(9) != Some(&2) {
        return Err("content-order hybrid candidate is not deterministic method 2".into());
    }
    let candidate_decoded = lhc::decode(&candidate, options, &mut || false)?;
    if candidate_decoded != input || solid::parse(&candidate_decoded)? != entries {
        return Err(
            "content-order hybrid candidate failed byte or logical-entry round-trip".into(),
        );
    }

    let passes_size_gate = candidate.len() <= SEVEN_ZIP_SIZE_GATE;
    let mut beam_times_ms = Vec::new();
    let mut hybrid_times_ms = Vec::new();
    if passes_size_gate {
        beam_times_ms.reserve(TIMED_PAIRS);
        hybrid_times_ms.reserve(TIMED_PAIRS);
        for pair in 0..TIMED_PAIRS {
            if pair % 2 == 0 {
                let started = Instant::now();
                let frame = lhc::encode(input, options, &mut || false)?;
                beam_times_ms.push(started.elapsed().as_secs_f64() * 1000.0);
                if frame != beam_frame {
                    return Err(
                        "timed content-order Beam frame differs from its verified baseline".into(),
                    );
                }
                let started = Instant::now();
                let frame = encode_single_pass_hybrid_frame(input, &beam_frame, options, &region)?;
                hybrid_times_ms.push(started.elapsed().as_secs_f64() * 1000.0);
                if frame != candidate {
                    return Err(
                        "timed content-order hybrid frame differs from its verified candidate"
                            .into(),
                    );
                }
            } else {
                let started = Instant::now();
                let frame = encode_single_pass_hybrid_frame(input, &beam_frame, options, &region)?;
                hybrid_times_ms.push(started.elapsed().as_secs_f64() * 1000.0);
                if frame != candidate {
                    return Err(
                        "timed content-order hybrid frame differs from its verified candidate"
                            .into(),
                    );
                }
                let started = Instant::now();
                let frame = lhc::encode(input, options, &mut || false)?;
                beam_times_ms.push(started.elapsed().as_secs_f64() * 1000.0);
                if frame != beam_frame {
                    return Err(
                        "timed content-order Beam frame differs from its verified baseline".into(),
                    );
                }
            }
        }
    }
    let median_ms = |samples: &[f64]| {
        let mut sorted = samples.to_vec();
        sorted.sort_by(f64::total_cmp);
        if sorted.is_empty() {
            return None;
        }
        let middle = sorted.len() / 2;
        Some(if sorted.len().is_multiple_of(2) {
            (sorted[middle - 1] + sorted[middle]) / 2.0
        } else {
            sorted[middle]
        })
    };
    let beam_median_ms = median_ms(&beam_times_ms);
    let hybrid_median_ms = median_ms(&hybrid_times_ms);

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "content-order-adjacent-ptt5-kennedy-full-region-single-pass-hybrid",
        "input_bytes": input.len(),
        "logical_entries": group_listing(entries),
        "physical_order": physical_order,
        "region": {
            "start": ptt_start,
            "end": kennedy_end,
            "bytes": kennedy_end - ptt_start,
            "coverage_fraction": (kennedy_end - ptt_start) as f64 / input.len() as f64,
            "files": ["ptt5", "kennedy.xls"],
        },
        "beam_baseline_frame_bytes": beam_frame.len(),
        "hybrid_frame_bytes": candidate.len(),
        "hybrid_delta_from_beam_bytes": candidate.len() as i64 - beam_frame.len() as i64,
        "seven_zip_size_gate_bytes": SEVEN_ZIP_SIZE_GATE,
        "passes_size_gate": passes_size_gate,
        "round_trip_and_determinism_verified": true,
        "timing": {
            "timed_pairs": beam_times_ms.len(),
            "order": "alternating Beam-first and hybrid-first",
            "beam_encode_ms": beam_times_ms,
            "hybrid_encode_ms": hybrid_times_ms,
            "beam_median_ms": beam_median_ms,
            "hybrid_median_ms": hybrid_median_ms,
            "fixed_seven_zip_one_thread_ms": SEVEN_ZIP_ONE_THREAD_MS,
            "hybrid_below_fixed_seven_zip_gate": hybrid_median_ms.is_some_and(|ms| ms < SEVEN_ZIP_ONE_THREAD_MS),
            "note": if passes_size_gate { "paired same-process codec timings; rerun the usual CLI-vs-7-Zip E2E before claiming a win" } else { "not measured because the fixed size gate failed" },
        },
        "note": "The lazy region preserves BT matcher preparation; it removes Beam planning only. A pass is not a general or held-out result."
    }))
}

fn standard_rep_replay_screen(
    input: &[u8],
    standard_options: lhc::Options,
    entries: &[solid::Entry<'_>],
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    const INPUT_BYTES: usize = 2_811_006;
    const STANDARD_FRAME_BYTES: usize = 579_558;
    const BEAM_FRAME_BYTES: usize = 483_130;
    const SEVEN_ZIP_SIZE_GATE: usize = 483_599;
    const EXPECTED_LOGICAL: [(&str, usize); 11] = [
        ("alice29.txt", 152_089),
        ("asyoulik.txt", 125_179),
        ("cp.html", 24_603),
        ("fields.c", 11_150),
        ("grammar.lsp", 3_721),
        ("kennedy.xls", 1_029_744),
        ("lcet10.txt", 426_754),
        ("plrabn12.txt", 481_861),
        ("ptt5", 513_216),
        ("sum", 38_240),
        ("xargs.1", 4_227),
    ];
    if input.len() != INPUT_BYTES
        || entries.len() != EXPECTED_LOGICAL.len()
        || !matches!(standard_options.algorithm, lhc::Algorithm::Standard)
        || standard_options.entropy_backend != lhc::EntropyBackend::Range
        || standard_options.dictionary != 64 * 1024 * 1024
        || standard_options.beam_width != 2
        || standard_options.beam_block != 8192
        || !matches!(standard_options.beam_model, lhc::BeamModel::Blended)
        || !matches!(standard_options.beam_matches, lhc::BeamMatches::Bt5)
        || standard_options.beam_fixed_boundaries
        || standard_options.beam_batch_blocks != 1
        || standard_options.beam_greedy_seeds
        || standard_options.beam_rep_diverse_third_parent
        || standard_options.beam_fixed_rep_history
        || standard_options.beam_history_seeded
        || standard_options.bt_nice_len != 0
    {
        return Err("standard-rep-replay-screen requires the fixed Canterbury group and plain Range/64MiB options".into());
    }
    for (entry, &(expected_name, expected_len)) in entries.iter().zip(&EXPECTED_LOGICAL) {
        if entry.name != expected_name || entry.data.len() != expected_len {
            return Err(
                "standard replay group entries differ from the fixed Canterbury census".into(),
            );
        }
    }

    let standard_frame = lhc::encode(input, standard_options, &mut || false)?;
    let standard_repeat = lhc::encode(input, standard_options, &mut || false)?;
    if standard_frame != standard_repeat
        || standard_frame.len() != STANDARD_FRAME_BYTES
        || standard_frame.get(9) != Some(&1)
        || lhc::decode(&standard_frame, standard_options, &mut || false)? != input
    {
        return Err(
            "ordinary Standard baseline failed deterministic 579,558-byte method-1 E2E".into(),
        );
    }
    let standard_decoded = lhc::decode(&standard_frame, standard_options, &mut || false)?;
    if solid::parse(&standard_decoded)? != entries {
        return Err("ordinary Standard baseline logical entries differ after decode".into());
    }

    let (standard_payload, standard_tokens) =
        lhc::trace_standard_tokens(input, standard_options, &mut || false)?;
    if standard_frame.get(lhc::HEADER..) != Some(standard_payload.as_slice()) {
        return Err("Standard token trace payload differs from ordinary method-1 frame".into());
    }
    let standard_trace_report = validate_census_trace("standard", input, &standard_tokens)?;
    drop(standard_frame);
    drop(standard_repeat);
    drop(standard_decoded);
    drop(standard_payload);

    let mut beam_options = standard_options;
    beam_options.algorithm = lhc::Algorithm::Beam;
    let beam_frame = lhc::encode(input, beam_options, &mut || false)?;
    if beam_frame.len() != BEAM_FRAME_BYTES
        || beam_frame.get(9) != Some(&2)
        || lhc::decode(&beam_frame, beam_options, &mut || false)? != input
    {
        return Err("method-2 header template failed the fixed 483,130-byte Beam E2E".into());
    }
    let beam_decoded = lhc::decode(&beam_frame, beam_options, &mut || false)?;
    if solid::parse(&beam_decoded)? != entries {
        return Err("method-2 baseline logical entries differ after decode".into());
    }
    drop(beam_decoded);

    let (candidate_payload, converted_tokens) = lhc::reencode_standard_trace_as_method2(
        input,
        standard_options,
        standard_tokens.clone(),
        &mut || false,
    )?;
    let candidate = lhc::frame_with_payload(&beam_frame, &candidate_payload)?;
    let mut converted_rep_tokens = 0u64;
    let mut converted_match_tokens = 0u64;
    let mut converted_rep_bytes = 0u64;
    if converted_tokens.len() != standard_tokens.len() {
        return Err("fixed-parse method-2 replay changed the token count".into());
    }
    for (original, converted) in standard_tokens.iter().zip(&converted_tokens) {
        if original.offset != converted.offset
            || original.length != converted.length
            || original.distance != converted.distance
            || (original.kind == 0 && converted.kind != 0)
            || (original.kind == 3 && !matches!(converted.kind, 2 | 3))
        {
            return Err(
                "fixed-parse method-2 replay changed a token span or absolute distance".into(),
            );
        }
        match converted.kind {
            0 => {}
            2 if converted.rep_index < 4 => {
                converted_rep_tokens += 1;
                converted_rep_bytes += u64::from(converted.length);
            }
            3 if converted.rep_index == 0 => converted_match_tokens += 1,
            _ => return Err("converted method-2 trace has an invalid token".into()),
        }
    }
    drop(candidate_payload);
    let fixed_parse_static_field_entropy = greedy_static_field_entropy(input, &converted_tokens)?;
    let rep4_reclassified = reclassify_with_recent_reps(input, &converted_tokens, 4)?;
    if rep4_reclassified != converted_tokens {
        return Err("Rep4 MTF reclassification differs from the established replay trace".into());
    }
    let mut wide_rep_entropy_screens = Vec::with_capacity(3);
    for rep_capacity in [5usize, 6, 8] {
        let widened_tokens = reclassify_with_recent_reps(input, &converted_tokens, rep_capacity)?;
        let field_entropy =
            greedy_static_field_entropy_with_rep_capacity(input, &widened_tokens, rep_capacity)?;
        let mut rep_index_counts = vec![0u64; rep_capacity];
        let mut rep_tokens = 0u64;
        let mut normal_match_tokens = 0u64;
        for token in &widened_tokens {
            match token.kind {
                2 => {
                    let index = usize::from(token.rep_index);
                    let count = rep_index_counts
                        .get_mut(index)
                        .ok_or("wide-Rep index exceeds its fixed capacity")?;
                    *count += 1;
                    rep_tokens += 1;
                }
                3 => normal_match_tokens += 1,
                0 => {}
                _ => return Err("wide-Rep trace contains an invalid token kind".into()),
            }
        }
        let ideal_frame_bytes = field_entropy["ideal_frame_bytes_with_existing_header"]
            .as_u64()
            .ok_or("wide-Rep entropy result omitted ideal frame size")?;
        wide_rep_entropy_screens.push(serde_json::json!({
            "rep_capacity": rep_capacity,
            "rep_tokens": rep_tokens,
            "additional_reps_vs_rep4": rep_tokens.saturating_sub(converted_rep_tokens),
            "normal_match_tokens": normal_match_tokens,
            "rep_index_counts": rep_index_counts,
            "ideal_frame_bytes_with_existing_header": ideal_frame_bytes,
            "delta_from_7zip_gate_bytes": ideal_frame_bytes as i64 - SEVEN_ZIP_SIZE_GATE as i64,
            "passes_7zip_size_gate_optimistically": ideal_frame_bytes <= SEVEN_ZIP_SIZE_GATE as u64,
            "field_entropy": field_entropy,
        }));
    }
    drop(converted_tokens);

    let (candidate_repeat_payload, repeated_tokens) = lhc::reencode_standard_trace_as_method2(
        input,
        standard_options,
        standard_tokens,
        &mut || false,
    )?;
    let candidate_repeat = lhc::frame_with_payload(&beam_frame, &candidate_repeat_payload)?;
    if candidate != candidate_repeat || candidate.get(9) != Some(&2) {
        return Err("fixed-parse method-2 frame is not deterministic method 2".into());
    }
    drop(candidate_repeat_payload);
    drop(repeated_tokens);
    let candidate_decoded = lhc::decode(&candidate, beam_options, &mut || false)?;
    if candidate_decoded != input || solid::parse(&candidate_decoded)? != entries {
        return Err(
            "fixed-parse method-2 candidate failed byte or logical-entry round-trip".into(),
        );
    }

    Ok(serde_json::json!({
        "experimental": true,
        "screen": "standard-fixed-parse-method2-rep4-reencode-size-only",
        "input_bytes": input.len(),
        "solid_group": group_listing(entries),
        "standard_frame_bytes": STANDARD_FRAME_BYTES,
        "beam_method2_frame_bytes": beam_frame.len(),
        "candidate_frame_bytes": candidate.len(),
        "candidate_delta_from_beam_bytes": candidate.len() as i64 - BEAM_FRAME_BYTES as i64,
        "candidate_saving_from_standard_bytes": STANDARD_FRAME_BYTES.saturating_sub(candidate.len()),
        "seven_zip_size_gate_bytes": SEVEN_ZIP_SIZE_GATE,
        "passes_size_gate": candidate.len() <= SEVEN_ZIP_SIZE_GATE,
        "standard_trace": standard_trace_report,
        "converted_method2_tokens": {
            "rep_tokens": converted_rep_tokens,
            "rep_bytes": converted_rep_bytes,
            "normal_match_tokens": converted_match_tokens,
            "token_parse_preserved": true,
        },
        "fixed_parse_static_field_entropy": fixed_parse_static_field_entropy,
        "wide_rep_entropy_screens": wide_rep_entropy_screens,
        "round_trip_and_determinism_verified": true,
        "timing": "not measured; a passing size screen must first receive a one-pass Standard-to-method-2 encoder",
    }))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    if (args.rep_sample_offset.is_some() || args.rep_sample_stride.is_some())
        && !matches!(args.mode, Mode::ProfileTiming)
    {
        return Err("--rep-sample-offset/--rep-sample-stride require profile-timing".into());
    }
    let rep_sample_stride = args.rep_sample_stride.unwrap_or(16);
    let rep_sample_offset = args.rep_sample_offset.unwrap_or_default();
    if rep_sample_offset >= rep_sample_stride {
        return Err("--rep-sample-offset must be less than --rep-sample-stride".into());
    }
    let limit = lhc::MAX_INPUT + lhc::HEADER;
    let mut input = Vec::new();
    std::fs::File::open(&args.input)?
        .take((limit + 1) as u64)
        .read_to_end(&mut input)?;
    if input.len() > limit {
        return Err("lab input limit exceeded".into());
    }
    let group = if matches!(
        args.mode,
        Mode::GroupBench
            | Mode::GroupSizeScreen
            | Mode::GroupEncode
            | Mode::GreedyStaticEntropyScreen
            | Mode::FrontierLiteralCopyDpScreen
            | Mode::FrontierLiteralCopyAllLengthsDpScreen
            | Mode::RepFrontierDpScreen
            | Mode::DistanceDeltaScreen
            | Mode::BeamPlanRangeCensus
            | Mode::HybridContentOrderRegionScreen
            | Mode::StandardRepReplayScreen
            | Mode::FsgPriceMonotonicityScreen
            | Mode::TokenReplayBudgetScreen
            | Mode::Ptt5TransposeScreen
            | Mode::Ptt5TransposeWindowScreen
            | Mode::BytePairDictionaryScreen
    ) {
        Some(solid::parse(&input)?)
    } else {
        None
    };
    let options = lhc::Options {
        algorithm: match args.algorithm {
            Algorithm::Standard => lhc::Algorithm::Standard,
            Algorithm::Lz => lhc::Algorithm::Lz,
            Algorithm::Beam => lhc::Algorithm::Beam,
            Algorithm::Context => lhc::Algorithm::Context,
            Algorithm::Auto => lhc::Algorithm::Auto,
        },
        entropy_backend: match args.entropy_backend {
            EntropyBackend::Range => lhc::EntropyBackend::Range,
            EntropyBackend::Rans => lhc::EntropyBackend::Rans,
        },
        beam_width: args.beam_width,
        beam_block: args.beam_block,
        beam_model: match args.beam_model {
            BeamModel::Current => lhc::BeamModel::Current,
            BeamModel::Warm => lhc::BeamModel::Warm,
            BeamModel::Blended => lhc::BeamModel::Blended,
        },
        beam_matches: match args.beam_matches {
            BeamMatches::Nearest => lhc::BeamMatches::Nearest,
            BeamMatches::PricedTie => lhc::BeamMatches::PricedTie,
            BeamMatches::Bt4 => lhc::BeamMatches::Bt4,
            BeamMatches::Bt5 => lhc::BeamMatches::Bt5,
            BeamMatches::Exact4 => lhc::BeamMatches::Exact4,
            BeamMatches::Hybrid => lhc::BeamMatches::Hybrid,
            BeamMatches::R4 => lhc::BeamMatches::R4,
            BeamMatches::R5 => lhc::BeamMatches::R5,
        },
        beam_fixed_boundaries: args.beam_fixed_boundaries,
        beam_batch_blocks: args.beam_batch_blocks,
        beam_greedy_seeds: args.beam_greedy_seeds,
        beam_rep_diverse_third_parent: args.beam_rep_diverse_third_parent,
        beam_fixed_rep_history: args.beam_fixed_rep_history,
        beam_history_seeded: args.beam_history_seeded,
        bt_nice_len: args.bt_nice_len,
        dictionary: args
            .dictionary_mib
            .checked_mul(1024 * 1024)
            .ok_or("dictionary overflow")?,
        ..lhc::Options::default()
    };
    match args.mode {
        Mode::DecodeBench => println!(
            "{}",
            decode_benchmark(&input, options, args.repeats, args.decode_iterations)?
        ),
        Mode::Encode | Mode::GroupEncode => {
            std::io::stdout()
                .lock()
                .write_all(&lhc::encode(&input, options, &mut || false)?)?
        }
        Mode::MatchTrace => {
            let frame = lhc::encode(&input, options, &mut || false)?;
            let (payload, selected) = lhc::trace_beam_matches(&input, options, &mut || false)?;
            if frame.get(9) != Some(&2) || frame.get(lhc::HEADER..) != Some(payload.as_slice()) {
                return Err("match trace payload differs from normal beam output".into());
            }
            if selected.iter().any(|item| {
                item.distance == 0
                    || item.distance > item.offset
                    || item.length < 3
                    || item.length > input.len() - item.offset
            }) {
                return Err("invalid selected match in trace".into());
            }
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "algorithm": "Beam",
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_fixed_boundaries": options.beam_fixed_boundaries,
                    "beam_batch_blocks": options.beam_batch_blocks,
                    "beam_greedy_seeds": options.beam_greedy_seeds,
                    "beam_rep_diverse_third_parent": options.beam_rep_diverse_third_parent,
                    "beam_fixed_rep_history": options.beam_fixed_rep_history,
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "frame_bytes": frame.len(),
                    "payload_matches_normal_encode": true,
                    "selected_matches": selected
                        .iter()
                        .map(|item| [item.offset, item.length, item.distance])
                        .collect::<Vec<_>>(),
                })
            );
        }
        Mode::RepPatchScreen => {
            let frame = lhc::encode(&input, options, &mut || false)?;
            let (payload, selected, selected_tokens) =
                lhc::trace_beam_copies(&input, options, &mut || false)?;
            if frame.get(9) != Some(&2) || frame.get(lhc::HEADER..) != Some(payload.as_slice()) {
                return Err("copy trace payload differs from normal beam output".into());
            }
            let rewrite_gate_by_patch_budget = [8usize, 16, 32, 64, 128]
                .into_iter()
                .map(|patch_budget| {
                    let (rewritten_payload, rewrite_stats) = lhc::rewrite_beam_copy_segments(
                        &input,
                        options,
                        &selected_tokens,
                        patch_budget,
                    )?;
                    let rewritten_frame_bytes = lhc::HEADER + rewritten_payload.len();
                    Ok(serde_json::json!({
                        "max_patch_bytes": patch_budget,
                        "baseline_frame_bytes": frame.len(),
                        "rewritten_frame_bytes": rewritten_frame_bytes,
                        "delta_bytes": rewritten_frame_bytes as i64 - frame.len() as i64,
                        "round_trip_verified": true,
                        "stats": {
                            "eligible_candidates": rewrite_stats.eligible_candidates,
                            "covered_bytes": rewrite_stats.covered_bytes,
                            "patch_bytes": rewrite_stats.patch_bytes,
                            "selected_segments": rewrite_stats.selected_segments,
                            "baseline_tokens": rewrite_stats.baseline_tokens,
                            "rewritten_tokens": rewrite_stats.rewritten_tokens,
                        },
                        "note": "Actual mode-2 range-coder output after non-overlapping segment selection and Rep-distance renormalization. This tests size feasibility only; matcher and baseline parse still ran, so it is not an encoding-speed result."
                    }))
                })
                .collect::<Result<Vec<_>, lhc::Error>>()?;
            let patched_token_budget = 8usize;
            let patched_token_started = Instant::now();
            let (patched_payload, patched_stats) = lhc::encode_patched_copy_segments(
                &input,
                options,
                &selected_tokens,
                patched_token_budget,
            )?;
            let patched_token_probe_ms = patched_token_started.elapsed().as_secs_f64() * 1000.0;
            let patched_frame_bytes = lhc::HEADER + patched_payload.len();
            if lhc::decode_patched_copy_payload(&patched_payload, input.len(), options.dictionary)?
                != input
            {
                return Err("patched-copy decoder did not restore the input".into());
            }
            let screen_by_patch_budget = [8usize, 16, 32, 64, 128]
                .into_iter()
                .map(|budget| rep_patch_screen(&input, &selected, budget))
                .collect::<Result<Vec<_>, _>>()?;
            println!(
                "{}",
                serde_json::json!({
                    "algorithm": "Beam",
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_fixed_boundaries": options.beam_fixed_boundaries,
                    "beam_batch_blocks": options.beam_batch_blocks,
                    "beam_greedy_seeds": options.beam_greedy_seeds,
                    "beam_rep_diverse_third_parent": options.beam_rep_diverse_third_parent,
                    "dictionary": options.dictionary,
                    "frame_bytes": frame.len(),
                    "payload_matches_normal_encode": true,
                    "selected_token_trace_items": selected_tokens.len(),
                    "rewrite_gate_by_patch_budget": rewrite_gate_by_patch_budget,
                    "patched_copy_token_gate": {
                        "max_patch_bytes": patched_token_budget,
                        "baseline_frame_bytes": frame.len(),
                        "patched_copy_frame_bytes": patched_frame_bytes,
                        "delta_bytes": patched_frame_bytes as i64 - frame.len() as i64,
                        "round_trip_verified": true,
                        "post_parse_encode_verify_ms": patched_token_probe_ms,
                        "stats": {
                            "eligible_candidates": patched_stats.eligible_candidates,
                            "covered_bytes": patched_stats.covered_bytes,
                            "patch_bytes": patched_stats.patch_bytes,
                            "selected_segments": patched_stats.selected_segments,
                            "baseline_tokens": patched_stats.baseline_tokens,
                            "patched_plan_tokens": patched_stats.rewritten_tokens,
                        },
                        "note": "Research-only extended token grammar; frame-byte comparison includes the common LHC header size. Timing includes candidate reselection, mode-2 control encode/decode, patched-token encode/decode verification, but excludes baseline matcher/beam parsing. It is not a full encoder speed result."
                    },
                    "screen_by_patch_budget": screen_by_patch_budget,
                })
            );
        }
        Mode::MatchCoverage => {
            let frame = lhc::encode(&input, options, &mut || false)?;
            let (payload, selected) = lhc::trace_beam_matches(&input, options, &mut || false)?;
            if frame.get(9) != Some(&2) || frame.get(lhc::HEADER..) != Some(payload.as_slice()) {
                return Err("match trace payload differs from normal beam output".into());
            }
            let coverage = lhc::suffix_probe::measure(&input, &selected, options.dictionary, 16)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_fixed_boundaries": options.beam_fixed_boundaries,
                    "beam_batch_blocks": options.beam_batch_blocks,
                    "beam_greedy_seeds": options.beam_greedy_seeds,
                    "beam_rep_diverse_third_parent": options.beam_rep_diverse_third_parent,
                    "dictionary": options.dictionary,
                    "frame_bytes": frame.len(),
                    "payload_matches_normal_encode": true,
                    "suffix_candidate_coverage": coverage,
                })
            );
        }
        Mode::DistanceDeltaScreen => {
            let result = lhc::screen_distance_delta(&input, options, &mut || false)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "algorithm": "Beam",
                    "beam_model": "Blended",
                    "beam_matches": "Bt5",
                    "beam_width": 2,
                    "beam_block": 8192,
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "solid_group": group.as_deref().map(group_listing),
                    "baseline_frame_bytes": result.baseline_frame_bytes,
                    "candidate_frame_bytes": result.candidate_frame_bytes,
                    "delta_bytes": result.candidate_frame_bytes as i64
                        - result.baseline_frame_bytes as i64,
                    "candidate_percent_smaller": if result.baseline_frame_bytes == 0 {
                        0.0
                    } else {
                        (1.0 - result.candidate_frame_bytes as f64
                            / result.baseline_frame_bytes as f64)
                            * 100.0
                    },
                    "token_count": result.token_count,
                    "normal_match_events": result.normal_match_events,
                    "delta_events": result.delta_events,
                    "absolute_escape_events": result.absolute_escape_events,
                    "delta_event_fraction": if result.normal_match_events == 0 {
                        0.0
                    } else {
                        result.delta_events as f64 / result.normal_match_events as f64
                    },
                    "round_trip_verified": result.round_trip_verified,
                    "deterministic": result.deterministic,
                    "note": "This screen preserves the current parse and measures only the research token grammar with the real adaptive range coder. It is not a full re-optimized encoder speed result or a production format change."
                })
            );
        }
        Mode::TokenCoverageScreen => {
            let frame = lhc::encode(&input, options, &mut || false)?;
            let (payload, _, selected_tokens) =
                lhc::trace_beam_copies(&input, options, &mut || false)?;
            if frame.get(9) != Some(&2) || frame.get(lhc::HEADER..) != Some(payload.as_slice()) {
                return Err("token trace payload differs from normal beam output".into());
            }
            let interior_counts = selected_token_interior_counts(input.len(), &selected_tokens)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "algorithm": "Beam",
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "frame_bytes": frame.len(),
                    "payload_matches_normal_encode": true,
                    "selected_token_count": selected_tokens.len(),
                    "selected_path_only": true,
                    "coverage": interior_counts.into_iter().map(|(threshold, count)| serde_json::json!({
                        "minimum_token_length": threshold,
                        "interior_input_positions": count,
                        "fraction_of_input": if input.is_empty() { 0.0 } else { count as f64 / input.len() as f64 }
                    })).collect::<Vec<_>>(),
                    "warning": "Selected-path coverage is only an upper bound. It does not prove that alternate live beam parents or all legal matches can be skipped, and it does not measure BT snapshot construction."
                })
            );
        }
        Mode::ParserCensus => {
            let report = parser_census(&input, options)?;
            println!(
                "{}",
                serde_json::json!({
                    "input_path": args.input,
                    "census": report,
                })
            );
        }
        Mode::BeamPlanRangeCensus => {
            let (frame, plans) = lhc::trace_beam_plan_ranges(&input, options, &mut || false)?;
            let decoded = lhc::decode(&frame, options, &mut || false)?;
            if decoded != input {
                return Err("Beam plan Range census frame failed round-trip".into());
            }

            let mut plain_end = 0usize;
            let mut emitted_bytes = 0usize;
            let mut plan_rows = Vec::new();
            plan_rows
                .try_reserve_exact(plans.len())
                .map_err(|_| lhc::Error::Limit)?;
            for (index, plan) in plans.iter().enumerate() {
                if plan.plain_start != plain_end || plan.plain_bytes == 0 {
                    return Err("Beam plan Range census has a gap or empty plan".into());
                }
                plain_end = plain_end
                    .checked_add(plan.plain_bytes)
                    .ok_or("Beam plan Range census input offset overflow")?;
                let emitted_delta = plan
                    .emitted_bytes_total
                    .checked_sub(emitted_bytes)
                    .ok_or("Beam plan Range census committed bytes decreased")?;
                if emitted_delta != plan.emitted_bytes_since_previous_plan
                    || plan.prefix_payload_bytes_if_terminated < plan.emitted_bytes_total
                {
                    return Err("Beam plan Range census Range-state accounting mismatch".into());
                }
                emitted_bytes = plan.emitted_bytes_total;
                plan_rows.push(serde_json::json!({
                    "plan_index": index,
                    "plain_start": plan.plain_start,
                    "plain_bytes": plan.plain_bytes,
                    "committed_payload_bytes_total": plan.emitted_bytes_total,
                    "committed_payload_bytes_since_previous_plan": plan.emitted_bytes_since_previous_plan,
                    "pending_range_bytes": plan.pending_bytes,
                    "payload_bytes_if_terminated_at_this_plan": plan.prefix_payload_bytes_if_terminated,
                }));
            }
            if plain_end != input.len() {
                return Err("Beam plan Range census does not cover all input bytes".into());
            }
            let payload_bytes = frame.len() - lhc::HEADER;
            if plans
                .last()
                .is_none_or(|plan| plan.prefix_payload_bytes_if_terminated != payload_bytes)
            {
                return Err("Beam plan Range census final prefix length mismatch".into());
            }
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "beam-plan-range-census",
                    "algorithm": "Beam/Blended/W2/BT5/B8192/Range",
                    "input_bytes": input.len(),
                    "frame_bytes": frame.len(),
                    "payload_bytes": payload_bytes,
                    "normal_frame_payload_match_verified": true,
                    "round_trip_verified": true,
                    "plan_ranges_contiguous_and_cover_input": true,
                    "committed_output_monotonic_and_deltas_verified": true,
                    "final_prefix_preview_matches_finished_payload": true,
                    "timing_recorded": false,
                    "prefix_interpretation": "Cumulative Range payload size if the whole stream terminated at this actual plan boundary; not an independent block size and not additive per-plan cost.",
                    "plans": plan_rows,
                })
            );
        }
        Mode::AdaptFreezeScreen => {
            let started = Instant::now();
            let baseline = lhc::encode(&input, options, &mut || false)?;
            let baseline_ms = started.elapsed().as_secs_f64() * 1000.0;
            let intervals = [256usize, 1024, 4096];
            let screened = lhc::screen_adapt_freeze(&input, options, &intervals, &mut || false)?;
            let rows = screened
                .into_iter()
                .map(|(interval, frame_bytes)| {
                    serde_json::json!({
                        "interval_bytes": interval,
                        "frame_bytes": frame_bytes,
                        "delta_from_baseline": frame_bytes as i64 - baseline.len() as i64,
                        "delta_from_lzma2_gate": frame_bytes as i64 - 483_599,
                        "passes_size_gate": frame_bytes <= 483_599,
                    })
                })
                .collect::<Vec<_>>();
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "adapt-freeze",
                    "algorithm": "Beam",
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "baseline_frame_bytes": baseline.len(),
                    "baseline_encode_ms": baseline_ms,
                    "size_gate_bytes": 483_599,
                    "intervals": rows,
                    "note": "Same BT5 token sequence with probability updates deferred until the input-position window changes. This is a size screen only. It does not change encode speed, product wire, or the default decoder."
                })
            );
        }
        Mode::FrontierLiteralCopyDpScreen => {
            let estimate = lhc::screen_frontier_literal_copy_dp(&input, options, &mut || false)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "bt5-frontier-literal-absolute-copy-dp",
                    "not_a_real_frame": true,
                    "not_a_7zip_or_lhc_codec_result": true,
                    "frontier_limited": true,
                    "grammar": "Literal or one exact BT5 frontier copy with an absolute distance. No Rep history, ShortRep, or intermediate match length.",
                    "price_source": "one longest-frontier greedy trace, then one DP parse under those frozen add-one prices",
                    "screen_input": "serialized solid-group bytes, the same bytes group-bench compresses",
                    "input_bytes": input.len(),
                    "solid_group": group.as_deref().map(group_listing),
                    "dictionary": options.dictionary,
                    "beam_block": options.beam_block,
                    "shannon_ideal_bits": estimate.shannon_ideal_bits,
                    "raw_extra_bits": estimate.raw_extra_bits,
                    "header_bytes": estimate.header_bytes,
                    "estimate_bytes": estimate.estimate_bytes,
                    "greedy_shannon_ideal_bits": estimate.greedy_shannon_ideal_bits,
                    "greedy_raw_extra_bits": estimate.greedy_raw_extra_bits,
                    "greedy_estimate_bytes": estimate.greedy_estimate_bytes,
                    "estimate_minus_greedy_parse_bytes": estimate.estimate_bytes as i64 - estimate.greedy_estimate_bytes as i64,
                    "estimate_definition": "ceil((shannon_ideal_bits + raw_extra_bits) / 8) + 40-byte header allowance. Shannon covers is-copy, literal byte, copy-length slot, and distance slot. Raw extra bits are the length-slot width and distance-slot width; neither is entropy-coded. Frequency tables and coder termination are free.",
                    "field_shannon_bits": {
                        "is_copy": estimate.field_bits[0],
                        "literal_byte": estimate.field_bits[1],
                        "copy_length_slot": estimate.field_bits[2],
                        "distance_slot": estimate.field_bits[3],
                    },
                    "greedy_token_count": estimate.greedy_token_count,
                    "dp_token_count": estimate.token_count,
                    "literal_count": estimate.literal_count,
                    "copy_count": estimate.copy_count,
                    "copy_replay_and_contiguity_verified": true,
                    "gate_7zip_26_03_bytes": 483_599,
                    "estimate_minus_7zip_gate_bytes": estimate.estimate_bytes as i64 - 483_599,
                    "gate_current_lhc_bytes": 483_130,
                    "estimate_minus_current_lhc_bytes": estimate.estimate_bytes as i64 - 483_130,
                    "note": "This estimates only the selected parse, not the optimum of all BT5 parses. It is not an encoded frame and is not evidence of beating 7-Zip or current LHC."
                })
            );
        }
        Mode::RepFrontierDpScreen => {
            let estimate = lhc::screen_rep_frontier_dp(&input, options, &mut || false)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "bt5-frontier-rep-carrying-dp",
                    "not_a_real_frame": true,
                    "not_a_7zip_or_lhc_codec_result": true,
                    "frontier_limited": true,
                    "single_state_per_position": true,
                    "grammar": "Literal, ShortRep, Rep0-3, or absolute Match from the BT5 frontier. Rep history is the history carried by the winning path. Match and Rep lengths stay inside the prepared block. Within a length-slot and length-bucket the longest length is the only edge.",
                    "price_source": "one longest-copy greedy trace that may use Rep, then one DP under those frozen add-one prices",
                    "input_bytes": input.len(),
                    "solid_group": group.as_deref().map(group_listing),
                    "dictionary": options.dictionary,
                    "beam_block": options.beam_block,
                    "shannon_ideal_bits": estimate.shannon_ideal_bits,
                    "raw_extra_bits": estimate.raw_extra_bits,
                    "header_bytes": 40,
                    "estimate_bytes": estimate.estimate_bytes,
                    "greedy_estimate_bytes": estimate.greedy_estimate_bytes,
                    "estimate_minus_greedy_bytes": estimate.estimate_bytes as i64 - estimate.greedy_estimate_bytes as i64,
                    "field_shannon_bits": {
                        "token_class": estimate.field_bits[0],
                        "rep_index": estimate.field_bits[1],
                        "literal_byte": estimate.field_bits[2],
                        "length_slot": estimate.field_bits[3],
                        "distance_slot": estimate.field_bits[4],
                    },
                    "token_count": estimate.token_count,
                    "literal_count": estimate.literal_count,
                    "short_rep_count": estimate.short_count,
                    "rep_count": estimate.rep_count,
                    "match_count": estimate.match_count,
                    "copy_replay_contiguity_and_block_bounds_verified": true,
                    "gate_7zip_26_03_bytes": 483_599,
                    "estimate_minus_7zip_gate_bytes": estimate.estimate_bytes as i64 - 483_599,
                    "gate_current_lhc_bytes": 483_130,
                    "estimate_minus_current_lhc_bytes": estimate.estimate_bytes as i64 - 483_130,
                    "note": "Optimistic ideal length of one single-state parse. Not an encoded frame and not evidence of beating 7-Zip or current LHC. A value above either gate rejects only this construction."
                })
            );
        }
        Mode::FrontierLiteralCopyAllLengthsDpScreen => {
            let result =
                lhc::screen_frontier_literal_copy_all_lengths_dp(&input, options, &mut || false)?;
            let estimate = &result.estimate;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "bt5-frontier-literal-absolute-copy-all-lengths-dp",
                    "not_a_real_frame": true,
                    "not_a_7zip_or_lhc_codec_result": true,
                    "frontier_limited": true,
                    "edge_model": "all_legal_prefix_lengths_implicit_in_constant_price_intervals",
                    "grammar": "Literal or one exact BT5 frontier copy with an absolute distance. No Rep history or ShortRep.",
                    "price_source": "one longest-frontier greedy trace, then one DP parse under those frozen add-one prices",
                    "screen_input": "serialized solid-group bytes, the same bytes group-bench compresses",
                    "input_bytes": input.len(),
                    "solid_group": group.as_deref().map(group_listing),
                    "dictionary": options.dictionary,
                    "beam_block": options.beam_block,
                    "retained_candidate_count": result.retained_candidate_count,
                    "range_interval_count": result.range_interval_count,
                    "implicit_copy_length_count": result.implicit_copy_length_count,
                    "fixed_price_dp_cost_bits": result.fixed_price_cost,
                    "shannon_ideal_bits": estimate.shannon_ideal_bits,
                    "raw_extra_bits": estimate.raw_extra_bits,
                    "header_bytes": estimate.header_bytes,
                    "estimate_bytes": estimate.estimate_bytes,
                    "greedy_shannon_ideal_bits": estimate.greedy_shannon_ideal_bits,
                    "greedy_raw_extra_bits": estimate.greedy_raw_extra_bits,
                    "greedy_estimate_bytes": estimate.greedy_estimate_bytes,
                    "estimate_minus_greedy_parse_bytes": estimate.estimate_bytes as i64 - estimate.greedy_estimate_bytes as i64,
                    "estimate_definition": "ceil((shannon_ideal_bits + raw_extra_bits) / 8) + 40-byte header allowance. Shannon covers is-copy, literal byte, copy-length slot, and distance slot. Raw extra bits are the length-slot width and distance-slot width; neither is entropy-coded. Frequency tables and coder termination are free.",
                    "field_shannon_bits": {
                        "is_copy": estimate.field_bits[0],
                        "literal_byte": estimate.field_bits[1],
                        "copy_length_slot": estimate.field_bits[2],
                        "distance_slot": estimate.field_bits[3],
                    },
                    "greedy_token_count": estimate.greedy_token_count,
                    "dp_token_count": estimate.token_count,
                    "literal_count": estimate.literal_count,
                    "copy_count": estimate.copy_count,
                    "copy_replay_and_contiguity_verified": true,
                    "gate_7zip_26_03_bytes": 483_599,
                    "estimate_minus_7zip_gate_bytes": estimate.estimate_bytes as i64 - 483_599,
                    "gate_current_lhc_bytes": 483_130,
                    "estimate_minus_current_lhc_bytes": estimate.estimate_bytes as i64 - 483_130,
                    "note": "This screen covers every legal prefix length of each retained BT5 frontier match, but not shorter matches discarded by the frontier, other parser grammar, adaptive-model feedback, actual coding tables, or coder termination. It is not an encoded frame or evidence of beating 7-Zip or current LHC."
                })
            );
        }
        Mode::GreedyStaticEntropyScreen => {
            let selected = lhc::trace_greedy_bt5_tokens(&input, options, &mut || false)?;
            let entropy = greedy_static_field_entropy(&input, &selected)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "greedy-static-field-entropy-lower-bound",
                    "parser": "one BT5 greedy parse with token-by-token adaptive model and Rep-state updates",
                    "screen_input": "serialized solid-group bytes, matching group-bench's codec input",
                    "input_bytes": input.len(),
                    "solid_group": group.as_deref().map(group_listing),
                    "beam_width_and_beam_model": "not used by this greedy parser",
                    "entropy": entropy,
                    "note": "Optimistic information lower bound only: each fixed field/context gets a free full-file frequency table; no field-table, framing, or coder-termination costs are charged. A bound at or above the 7-Zip size gate is an immediate no-go. A lower bound is not evidence that a realizable format reaches it."
                })
            );
        }
        Mode::BoundaryCensus => {
            println!("{}", boundary_census(&input, options)?);
        }
        Mode::HybridSpliceScreen => {
            println!("{}", hybrid_splice_screen(&input, options)?);
        }
        Mode::HybridContentOrderRegionScreen => {
            let entries = group
                .as_deref()
                .ok_or("content-order region screen requires a parsed solid group")?;
            println!(
                "{}",
                hybrid_content_order_region_screen(&input, options, entries)?
            );
        }
        Mode::StandardRepReplayScreen => {
            let entries = group
                .as_deref()
                .ok_or("standard replay screen requires a parsed solid group")?;
            println!("{}", standard_rep_replay_screen(&input, options, entries)?);
        }
        Mode::FsgPriceMonotonicityScreen => {
            const INPUT_BYTES: usize = 2_811_006;
            const BASELINE_FRAME_BYTES: usize = 483_130;
            const EXPECTED_GROUP: [(&str, usize); 11] = [
                ("alice29.txt", 152_089),
                ("asyoulik.txt", 125_179),
                ("cp.html", 24_603),
                ("fields.c", 11_150),
                ("grammar.lsp", 3_721),
                ("kennedy.xls", 1_029_744),
                ("lcet10.txt", 426_754),
                ("plrabn12.txt", 481_861),
                ("ptt5", 513_216),
                ("sum", 38_240),
                ("xargs.1", 4_227),
            ];
            let entries = group
                .as_deref()
                .ok_or("FSG price screen requires a parsed solid group")?;
            if input.len() != INPUT_BYTES
                || entries.len() != EXPECTED_GROUP.len()
                || entries
                    .iter()
                    .zip(EXPECTED_GROUP)
                    .any(|(entry, (name, bytes))| entry.name != name || entry.data.len() != bytes)
            {
                return Err("FSG price screen requires the fixed Canterbury group corpus".into());
            }

            let baseline = lhc::encode(&input, options, &mut || false)?;
            let baseline_repeat = lhc::encode(&input, options, &mut || false)?;
            if baseline != baseline_repeat
                || baseline.len() != BASELINE_FRAME_BYTES
                || baseline.get(9) != Some(&2)
                || lhc::decode(&baseline, options, &mut || false)? != input
            {
                return Err(
                    "FSG price screen baseline failed deterministic 483,130-byte E2E".into(),
                );
            }
            let decoded_group = lhc::decode(&baseline, options, &mut || false)?;
            if solid::parse(&decoded_group)? != entries {
                return Err("FSG price screen baseline logical entries differ after decode".into());
            }

            let report = lhc::screen_fsg_price_monotonicity(&input, options, &mut || false)?;
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "fsg-first-block-lhc-price-monotonicity",
                    "not_a_parser_implementation": true,
                    "not_a_speed_measurement": true,
                    "baseline": {
                        "input_bytes": input.len(),
                        "frame_bytes": baseline.len(),
                        "method": baseline[9],
                        "deterministic": true,
                        "round_trip_verified": true,
                        "logical_entries_verified": true,
                    },
                    "price_source": "exact BT5/Blended first-block frozen Models from the ordinary Beam warm-up path; initial Rep state [1,1,1,1] and width-2 boundary mask",
                    "candidate_domain": "distances and maximum lengths present in the first 8192-byte BT5 candidate snapshot; every shorter legal prefix of each retained candidate is considered",
                    "result": {
                        "input_bytes": report.input_bytes,
                        "first_block_bytes": report.first_block_bytes,
                        "candidate_positions": report.candidate_positions,
                        "candidate_edges": report.candidate_edges,
                        "reachable_distances": report.reachable_distances,
                        "maximum_match_length": report.maximum_match_length,
                        "match_length_checks": report.match_length_checks,
                        "match_length_decreases": report.match_length_decreases,
                        "distance_checks": report.distance_checks,
                        "distance_decreases": report.distance_decreases,
                        "length_distance_boundary_checks": report.length_distance_boundary_checks,
                        "length_distance_boundary_decreases": report.length_distance_boundary_decreases,
                        "first_decreases": report.first_decreases.iter().map(|drop| {
                            serde_json::json!({
                                "kind": drop.kind,
                                "token_context": drop.token_context,
                                "length_context": drop.length_context,
                                "distance": drop.distance,
                                "previous_symbol": drop.previous_symbol,
                                "symbol": drop.symbol,
                                "previous_price": drop.previous_price,
                                "price": drop.price,
                            })
                        }).collect::<Vec<_>>(),
                    },
                    "interpretation": "Any decrease falsifies the increasing-cost premise for at least one edge in this actual candidate domain. No decrease in this first block is only a necessary-condition screen; it does not prove the premise across later blocks, all parser states, Rep transitions, or all legal matches."
                })
            );
        }
        Mode::RenormCensus => {
            if options.entropy_backend != lhc::EntropyBackend::Range {
                return Err("renorm-census counts the Range decoder only".into());
            }
            let frame = lhc::encode(&input, options, &mut || false)?;
            let decoded = lhc::decode(&frame, options, &mut || false)?;
            if decoded != input {
                return Err("renorm census frame failed round-trip".into());
            }
            let (profiled, profile) = lhc::decode_profile(&frame, options, &mut || false)?;
            if profiled != decoded {
                return Err("renorm census profile decode diverged".into());
            }
            let events = profile.renorm_byte_events;
            let bits = events.iter().copied().sum::<u64>();
            let two_byte_fraction = if bits == 0 {
                0.0
            } else {
                events[2] as f64 / bits as f64
            };
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "range-renorm-byte-census",
                    "not_a_speed_measurement": true,
                    "algorithm": format!("{:?}", args.algorithm),
                    "entropy_backend": "Range",
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "frame_bytes": frame.len(),
                    "round_trip_verified": true,
                    "profile_decode_matches_output": true,
                    "range_bit_calls": profile.range_bit_calls,
                    "renorm_events_by_bytes": {
                        "0": events[0],
                        "1": events[1],
                        "2_or_more": events[2],
                    },
                    "renorm_event_sum": bits,
                    "bit_calls_match_renorm_events": bits == profile.range_bit_calls,
                    "two_byte_fraction": two_byte_fraction,
                    "shift_gate_two_byte_fraction": 0.20,
                    "passes_two_byte_shift_gate": two_byte_fraction >= 0.20,
                    "note": "Counts bytes read by the existing one-byte renormalizer. Below 20% two-byte events, a two-byte shift is not implemented. This is not a 7-Zip comparison.",
                })
            );
        }
        Mode::Decode => {
            std::io::stdout()
                .lock()
                .write_all(&lhc::decode(&input, options, &mut || false)?)?
        }
        Mode::GroupDecode | Mode::GroupList => {
            let decoded = lhc::decode(&input, options, &mut || false)?;
            if matches!(args.mode, Mode::GroupDecode) {
                write_group_data(&decoded, &mut std::io::stdout().lock())?;
            } else {
                println!("{}", group_listing(&solid::parse(&decoded)?));
            }
        }
        Mode::GroupSizeScreen => {
            let expected_group = group
                .as_deref()
                .ok_or("group-size-screen input group was not parsed")?;
            if input.len() != 2_811_006
                || sha256_hex(&input)
                    != "18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76"
                || expected_group.len() != 11
            {
                return Err(
                    "group-size-screen requires the fixed 11-entry Canterbury group".into(),
                );
            }
            if !matches!(args.algorithm, Algorithm::Beam)
                || !matches!(args.entropy_backend, EntropyBackend::Range)
                || !matches!(args.beam_model, BeamModel::Blended)
                || !matches!(args.beam_matches, BeamMatches::Bt5)
                || args.beam_width != 2
                || args.beam_block != 8192
                || args.dictionary_mib != 64
                || args.beam_fixed_boundaries
                || args.beam_batch_blocks != 1
                || args.beam_greedy_seeds
                || args.beam_rep_diverse_third_parent
                || args.beam_fixed_rep_history
                || args.beam_history_seeded
                || args.bt_nice_len != 0
            {
                return Err("group-size-screen requires the fixed Range/Beam/Blended/W2/B8192/64 MiB settings".into());
            }
            let frame = lhc::encode(&input, options, &mut || false)?;
            let decoded = lhc::decode(&frame, options, &mut || false)?;
            if decoded != input || solid::parse(&decoded)? != expected_group {
                return Err("group-size-screen round-trip or entry mismatch".into());
            }
            let repeated_frame = lhc::encode(&input, options, &mut || false)?;
            if repeated_frame != frame {
                return Err("group-size-screen output is not deterministic".into());
            }
            if matches!(args.beam_matches, BeamMatches::Bt5)
                && (frame.len() != 483_130
                    || sha256_hex(&frame)
                        != "CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D")
            {
                return Err("group-size-screen BT5 baseline differs from the fixed control".into());
            }
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "screen": "fixed Canterbury BT5 control size/correctness; no timing",
                    "algorithm": format!("{:?}", args.algorithm),
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "input_sha256": sha256_hex(&input),
                    "frame_bytes": frame.len(),
                    "frame_sha256": sha256_hex(&frame),
                    "baseline_frame_bytes": 483_130,
                    "delta_from_baseline": frame.len() as i64 - 483_130,
                    "size_gate_bytes": 483_599,
                    "passes_size_gate": frame.len() <= 483_599,
                    "deterministic": true,
                    "round_trip_and_all_solid_entries_match": true,
                    "timing": "not measured",
                })
            );
        }
        Mode::Profile | Mode::ProfileTiming => {
            let start = Instant::now();
            let plain = lhc::encode(&input, options, &mut || false)?;
            let uninstrumented_ms = start.elapsed().as_secs_f64() * 1000.0;
            let timing_only = matches!(args.mode, Mode::ProfileTiming);
            let (packed, report) = if timing_only {
                lhc::profile::capture_timing(
                    || lhc::encode(&input, options, &mut || false),
                    rep_sample_offset,
                    rep_sample_stride,
                )
            } else {
                lhc::profile::capture(|| lhc::encode(&input, options, &mut || false))
            };
            let packed = packed?;
            if packed != plain {
                return Err("profile changed encoded output".into());
            }
            let plain_decoded = lhc::decode(&packed, options, &mut || false)?;
            if plain_decoded != input {
                return Err("profile encode failed round-trip".into());
            }
            let (profiled_decoded, decode_profile) =
                lhc::decode_profile(&packed, options, &mut || false)?;
            if profiled_decoded != plain_decoded {
                return Err("profile changed decoded output".into());
            }
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "algorithm": format!("{:?}", args.algorithm),
                    "entropy_backend": format!("{:?}", args.entropy_backend),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_fixed_boundaries": options.beam_fixed_boundaries,
                    "beam_batch_blocks": options.beam_batch_blocks,
                    "beam_greedy_seeds": options.beam_greedy_seeds,
                    "beam_rep_diverse_third_parent": options.beam_rep_diverse_third_parent,
                    "beam_fixed_rep_history": options.beam_fixed_rep_history,
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "dictionary": options.dictionary,
                    "input_bytes": input.len(),
                    "frame_bytes": packed.len(),
                    "profile_mode": if timing_only { "timing-only" } else { "diagnostics" },
                    "uninstrumented_ms": uninstrumented_ms,
                    "decode_work_profile": {
                        "note": "counts are exact; this is not a speed comparison",
                        "range_bit_calls": decode_profile.range_bit_calls,
                        "renorm_byte_events": decode_profile.renorm_byte_events,
                        "match_copy_bytes": decode_profile.match_copy_bytes,
                        "decoded_tokens": decode_profile.decoded_tokens,
                    },
                    "profile": report.json(),
                })
            );
        }
        Mode::TokenReplayBudgetScreen => {
            let entries = group
                .as_deref()
                .ok_or("token-replay-budget input group was not parsed")?;
            println!(
                "{}",
                token_replay_budget_screen(&input, options, entries, args.repeats)?
            );
        }
        Mode::Ptt5TransposeScreen => {
            let entries = group
                .as_deref()
                .ok_or("ptt5-transpose input group was not parsed")?;
            println!(
                "{}",
                ptt5_transpose_screen(&input, options, entries, args.repeats)?
            );
        }
        Mode::Ptt5TransposeWindowScreen => {
            let entries = group
                .as_deref()
                .ok_or("ptt5-transpose-window input group was not parsed")?;
            println!(
                "{}",
                ptt5_transpose_window_screen(&input, options, entries, args.repeats)?
            );
        }
        Mode::BytePairDictionaryScreen => {
            let entries = group
                .as_deref()
                .ok_or("byte-pair screen input group was not parsed")?;
            println!(
                "{}",
                byte_pair_dictionary_screen(&input, options, entries, args.repeats)?
            );
        }
        Mode::Bench | Mode::GroupBench => {
            // warm-up は結果と別。測定は I/O を除く codec 内部時間であり CLI 比較と混同しない。
            let warm = lhc::encode(&input, options, &mut || false)?;
            assert_eq!(lhc::decode(&warm, options, &mut || false)?, input);
            if options.beam_history_seeded {
                verify_history_seeded_failure_cases(&warm, options)?;
            }
            let mut samples = Vec::new();
            for _ in 0..args.repeats {
                let (packed, encode_time) =
                    bench_clock::measure(|| lhc::encode(&input, options, &mut || false));
                let packed = packed?;
                let (output, decode_time) =
                    bench_clock::measure(|| lhc::decode(&packed, options, &mut || false));
                let output = output?;
                if output != input || packed != warm {
                    return Err("round-trip or determinism failure".into());
                }
                if let Some(expected) = &group
                    && solid::parse(&output)? != *expected
                {
                    return Err("solid group metadata or entry mismatch".into());
                }
                samples.push(serde_json::json!({
                    "encode_ms": encode_time.wall_ms,
                    "decode_ms": decode_time.wall_ms,
                    "encode_cpu_ms": encode_time.cpu_ms,
                    "encode_cpu_status": encode_time.cpu_status,
                    "decode_cpu_ms": decode_time.cpu_ms,
                    "decode_cpu_status": decode_time.cpu_status,
                }));
            }
            println!(
                "{}",
                serde_json::json!({
                    "experimental": true,
                    "algorithm": format!("{:?}", args.algorithm),
                    "entropy_backend": format!("{:?}", args.entropy_backend),
                    "beam_width": options.beam_width,
                    "beam_block": options.beam_block,
                    "beam_fixed_boundaries": options.beam_fixed_boundaries,
                    "beam_batch_blocks": options.beam_batch_blocks,
                    "beam_greedy_seeds": options.beam_greedy_seeds,
                    "beam_rep_diverse_third_parent": options.beam_rep_diverse_third_parent,
                    "beam_fixed_rep_history": options.beam_fixed_rep_history,
                    "beam_history_seeded": options.beam_history_seeded,
                    "beam_model": format!("{:?}", args.beam_model),
                    "beam_matches": format!("{:?}", args.beam_matches),
                    "bt_nice_len": options.bt_nice_len,
                    "selected_mode": warm[9],
                    "input_bytes": input.len(),
                    "frame_bytes": warm.len(),
                    "payload_bytes": warm.len() - lhc::HEADER,
                    "dictionary": options.dictionary,
                    "solid_group": group.as_deref().map(group_listing),
                    "cpu_clock_note": "Current-thread user+kernel CPU around each codec call, including small timing-boundary overhead; Windows GetThreadTimes, unsupported elsewhere. Null is unavailable, successful zero is retained. Resolution is not guaranteed by the 100ns unit. Not process CPU, not wall time, not a cause-of-delay diagnosis.",
                    "samples": samples,
                })
            );
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_bench_repeats_fixed_frames_and_rejects_invalid_input() {
        for input in [Vec::new(), b"decode-only repeated pattern;".repeat(500)] {
            let options = lhc::Options::default();
            let packed = lhc::encode(&input, options, &mut || false).unwrap();
            let report = decode_benchmark(&packed, options, 2, 3).unwrap();
            assert_eq!(report["decoded_bytes"], input.len());
            assert_eq!(report["iterations_per_batch"], 3);
            assert_eq!(report["samples"].as_array().unwrap().len(), 2);
            assert!(decode_benchmark(&packed, options, 0, 3).is_err());
            assert!(decode_benchmark(&packed, options, 1, 1001).is_err());
            assert!(decode_benchmark(&packed[..packed.len() - 1], options, 1, 1).is_err());
        }
        let args = Args::try_parse_from(["lhc_lab", "decode-bench", "unused"]).unwrap();
        assert_eq!(args.decode_iterations, 32);
        for value in ["0", "1001", "-1", "abc"] {
            assert!(
                Args::try_parse_from([
                    "lhc_lab",
                    "decode-bench",
                    "unused",
                    "--decode-iterations",
                    value
                ])
                .is_err()
            );
        }
    }

    #[test]
    fn rep_patch_screen_finds_same_distance_span_and_enforces_patch_limit() {
        fn input_with_patches(patch_count: usize) -> Vec<u8> {
            let mut input = vec![0u8; 300];
            input[..6].copy_from_slice(b"ABCDEF");
            for position in 6..input.len() {
                let source = input[position - 6];
                let is_patch = (80..80 + patch_count).contains(&position);
                input[position] = if is_patch { source ^ 0xff } else { source };
            }
            input
        }

        let selected = [
            lhc::SelectedCopy {
                offset: 6,
                length: 6,
                distance: 6,
                kind: 2,
            },
            lhc::SelectedCopy {
                offset: 250,
                length: 20,
                distance: 6,
                kind: 2,
            },
        ];
        let one_patch = rep_patch_screen(&input_with_patches(1), &selected, 8).unwrap();
        assert_eq!(one_patch["eligible_segment_candidates"], 1);
        assert_eq!(one_patch["eligible_span_union_bytes_upper_bound"], 264);
        assert_eq!(one_patch["maximum_candidate_patch_bytes"], 1);
        assert_eq!(one_patch["screen_complete"], true);

        let over_eight = rep_patch_screen(&input_with_patches(9), &selected, 8).unwrap();
        assert_eq!(over_eight["eligible_segment_candidates"], 0);
        assert_eq!(over_eight["eligible_span_union_bytes_upper_bound"], 0);
        let within_sixteen = rep_patch_screen(&input_with_patches(9), &selected, 16).unwrap();
        assert_eq!(within_sixteen["eligible_segment_candidates"], 1);
        assert_eq!(within_sixteen["maximum_candidate_patch_bytes"], 9);
        let over_thirty_two = rep_patch_screen(&input_with_patches(33), &selected, 32).unwrap();
        assert_eq!(over_thirty_two["eligible_segment_candidates"], 0);
        let within_sixty_four = rep_patch_screen(&input_with_patches(33), &selected, 64).unwrap();
        assert_eq!(within_sixty_four["eligible_segment_candidates"], 1);
        assert_eq!(within_sixty_four["maximum_candidate_patch_bytes"], 33);
    }

    #[test]
    fn selected_token_coverage_counts_only_long_copy_interiors_and_checks_trace() {
        let selected = [
            lhc::SelectedToken {
                offset: 0,
                length: 1,
                distance: 0,
                kind: 0,
                rep_index: 0,
            },
            lhc::SelectedToken {
                offset: 1,
                length: 64,
                distance: 1,
                kind: 3,
                rep_index: 0,
            },
            lhc::SelectedToken {
                offset: 65,
                length: 31,
                distance: 1,
                kind: 2,
                rep_index: 0,
            },
            lhc::SelectedToken {
                offset: 96,
                length: 128,
                distance: 1,
                kind: 3,
                rep_index: 0,
            },
        ];
        assert_eq!(
            selected_token_interior_counts(224, &selected),
            Ok([(32, 190), (64, 190), (128, 127), (256, 0)])
        );
        assert!(selected_token_interior_counts(225, &selected).is_err());
        let mut gap = selected;
        gap[2].offset += 1;
        assert!(selected_token_interior_counts(224, &gap).is_err());
        let mut invalid = selected;
        invalid[1].kind = 4;
        assert!(selected_token_interior_counts(224, &invalid).is_err());
    }

    #[test]
    fn group_output_preserves_metadata_and_validates_before_writing() {
        let mut group = b"KHSGRP0\0".to_vec();
        group.extend_from_slice(&3u32.to_le_bytes());
        group.extend_from_slice(&0u32.to_le_bytes());
        for (name, length) in [(b'a', 0u64), (b'b', 3), (b'c', 2)] {
            group.extend_from_slice(&1u16.to_le_bytes());
            group.extend_from_slice(&length.to_le_bytes());
            group.push(name);
        }
        group.extend_from_slice(b"abc\0\xff");
        let entries = solid::parse(&group).unwrap();
        assert_eq!(
            group_listing(&entries),
            serde_json::json!([
                {"name":"a", "bytes":0},
                {"name":"b", "bytes":3},
                {"name":"c", "bytes":2}
            ])
        );
        let mut output = Vec::new();
        write_group_data(&group, &mut output).unwrap();
        assert_eq!(output, b"abc\0\xff");
        group.push(0);
        let mut untouched = Vec::new();
        assert!(write_group_data(&group, &mut untouched).is_err());
        assert!(untouched.is_empty());
        for mode in [
            "group-encode",
            "group-decode",
            "group-list",
            "group-bench",
            "rep-patch-screen",
            "token-coverage-screen",
            "greedy-static-entropy-screen",
        ] {
            assert!(Args::try_parse_from(["lhc_lab", mode, "unused"]).is_ok());
        }
    }

    #[test]
    fn beam_cli_values_are_bounded_supported_widths() {
        let args = Args::try_parse_from(["lhc_lab", "bench", "unused"]).unwrap();
        assert_eq!((args.beam_width, args.beam_block), (4, 512));
        assert!(matches!(args.beam_model, BeamModel::Current));
        assert!(matches!(args.beam_matches, BeamMatches::Nearest));
        assert!(!args.beam_rep_diverse_third_parent);
        let args = Args::try_parse_from([
            "lhc_lab",
            "bench",
            "unused",
            "--beam-rep-diverse-third-parent",
        ])
        .unwrap();
        assert!(args.beam_rep_diverse_third_parent);
        for policy in ["nearest", "priced-tie", "bt4", "bt5", "exact4", "r4", "r5"] {
            assert!(
                Args::try_parse_from(["lhc_lab", "bench", "unused", "--beam-matches", policy])
                    .is_ok()
            );
        }
        assert!(
            Args::try_parse_from(["lhc_lab", "bench", "unused", "--beam-matches", "unknown"])
                .is_err()
        );
        for model in ["current", "warm", "blended"] {
            assert!(
                Args::try_parse_from(["lhc_lab", "bench", "unused", "--beam-model", model]).is_ok()
            );
        }
        assert!(
            Args::try_parse_from(["lhc_lab", "bench", "unused", "--beam-model", "unknown"])
                .is_err()
        );
        for width in [1, 2, 3, 4, 8, 16] {
            assert_eq!(parse_beam_width(&width.to_string()), Ok(width));
        }
        for block in [64, 128, 256, 512, 1024, 2048, 4096, 8192] {
            assert_eq!(parse_beam_block(&block.to_string()), Ok(block));
        }
        for value in ["0", "5", "17", "18446744073709551616", "abc"] {
            assert!(parse_beam_width(value).is_err());
        }
        for value in ["0", "32", "65", "16384", "18446744073709551616", "abc"] {
            assert!(parse_beam_block(value).is_err());
        }
    }

    #[test]
    fn static_entropy_bits_match_known_histograms() {
        let single = BTreeMap::from([(42u64, 7u64)]);
        assert_eq!(static_entropy_bits(&single), 0.0);
        let balanced = BTreeMap::from([(0u64, 2u64), (1u64, 2u64)]);
        assert_eq!(static_entropy_bits(&balanced), 4.0);
        let skewed = BTreeMap::from([(0u64, 3u64), (1u64, 1u64)]);
        assert!((static_entropy_bits(&skewed) - 3.245_112_497_836_531_3).abs() < 1e-12);
    }

    #[test]
    fn greedy_static_screen_trace_is_deterministic_and_reconstructs() {
        let input = b"the quick brown fox jumps over the lazy dog; ".repeat(160);
        let options = lhc::Options {
            algorithm: lhc::Algorithm::Beam,
            dictionary: 4096,
            beam_block: 64,
            beam_matches: lhc::BeamMatches::Bt5,
            ..lhc::Options::default()
        };
        let first = lhc::trace_greedy_bt5_tokens(&input, options, &mut || false).unwrap();
        let second = lhc::trace_greedy_bt5_tokens(&input, options, &mut || false).unwrap();
        assert_eq!(first, second);
        let report = greedy_static_field_entropy(&input, &first).unwrap();
        assert_eq!(report["round_trip_verified_from_copy_distances"], true);
        assert!(
            report["ideal_frame_bytes_with_existing_header"]
                .as_u64()
                .is_some()
        );

        let batched = lhc::Options {
            beam_batch_blocks: 2,
            ..options
        };
        assert!(lhc::trace_greedy_bt5_tokens(&input, batched, &mut || false).is_err());
    }
}
