//! 同一binaryの新旧E2Eと条件付きABBA。正式benchmarkではない。
#![allow(dead_code)]
#[path="baseline_codec.rs"] mod codec;
#[path="integer_cts.rs"] mod new_cts;
#[path="integer_pool.rs"] mod integer_pool;
#[path="oracle.rs"] mod oracle;
#[path="comparison.rs"] mod comparison;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod baseline_cts;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod old_pool;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::{fs::File,io::Read,path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded{frame:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
pub(crate) struct Decoded{plain:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
struct Reference{frame:Vec<u8>,proof:codec::Proof,stats:String}
const FIXED_STATS:&str=r#"{"depth":5,"node_count":1365,"node_storage_bytes":196560,"magic":"KHQCID01","header_crc_covers_depth":true,"frame_bytes":478750,"header_bytes":285,"payload_bytes":478465,"plain_crc":433441561,"payload_crc":3616798779,"header_crc":621578488,"runs":889227,"primary":1762795,"alphabet_symbols":257,"rank_intervals":889227,"length_intervals":889227,"escape_bytes":742,"branches":[2725772, 1099568],"grammar_digest":"58735a2b7383d755","base_pool_digest":"0caac94407124a37","class_observations":[889227, 620240, 1216305, 889227, 64372, 145969],"cdf_entropy_bits":3820763.985142052}"#;
#[derive(Default)] struct Accounting{encode:usize,decode:usize,plain:usize,proof:usize,repeats:usize,repeat_bytes:usize,reads:usize,peak_frames:usize,peak_bytes:usize,enc:[u64;2],dec:[u64;2],sizes:[usize;2]}
fn quote(s:&str)->String{let mut out=String::from("\"");for c in s.chars(){match c{'"'=>out.push_str("\\\""),'\\'=>out.push_str("\\\\"),'\n'=>out.push_str("\\n"),'\r'=>out.push_str("\\r"),'\t'=>out.push_str("\\t"),c if c<' '=>out.push_str(&format!("\\u{:04x}",c as u32)),c=>out.push(c)}}out.push('"');out}
fn error_json(e:&str)->String{let mut end=e.len().min(3500);while !e.is_char_boundary(end){end-=1;}loop{let q=quote(&e[..end]);let text=format!("{{\"reason\":{q},\"original_bytes\":{},\"truncated\":{}}}",e.len(),end<e.len());if text.len()<=4096{return text;}end/=2;while !e.is_char_boundary(end){end-=1;}}}
fn read_input(path:&Path)->Result<Vec<u8>>{let file=File::open(path).map_err(|e|format!("input open: {e}"))?;let meta=file.metadata().map_err(|e|format!("input metadata: {e}"))?;if !meta.is_file()||meta.len()!=2811006{return Err("fixed input shape/type".into());}let mut data=Vec::new();data.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut data).map_err(|e|format!("input read: {e}"))?;if data.len()!=2811006{return Err("fixed input changed length".into());}Ok(data)}
fn equal(a:&[u8],b:&[u8],scope:&str)->Result<usize>{if a.len()!=b.len(){return Err(format!("{scope} byte length differs {} != {}",a.len(),b.len()));}for (i,(&x,&y)) in a.iter().zip(b).enumerate(){if x!=y{return Err(format!("{scope} byte index={i} actual={x} expected={y}"));}}Ok(a.len())}
fn run_one(index:usize,new:bool,input:&[u8],a:&mut Accounting,refs:&mut [Option<Reference>;2])->Result<(String,bool)>{
    let slot=usize::from(new);let name=if new{"new"}else{"old"};a.encode+=1;
    let encoded=if new{codec::candidate::run_profile(input,5)?}else{codec::run_profile(input,5)?};
    let held=refs.iter().flatten().count();let held_bytes=refs.iter().flatten().map(|r|r.frame.len()).sum::<usize>();let live=held+1;let live_bytes=held_bytes+encoded.frame.len();a.peak_frames=a.peak_frames.max(live);a.peak_bytes=a.peak_bytes.max(live_bytes);
    // size拒否のB1も全plain/Proof確認まで進める。合格frameのRAM上限だけをここで主張する。
    if live>3{return Err("ABBA more than three frames".into());}if encoded.frame.len()<=483599&&live_bytes>1445948{return Err("ABBA admitted frame bytes bound".into());}
    encoded.proof.validate_fixed(5)?;if !new&&(encoded.frame.len()!=478750||encoded.stats!=FIXED_STATS){return Err("old A fixed frame/CRC/stats mismatch".into());}
    a.decode+=1;let decoded=if new{codec::candidate::run_restore(&encoded.frame)?}else{codec::run_restore(&encoded.frame)?};let matched=equal(&decoded.plain,input,"all plain")?;a.plain+=1;
    if encoded.proof!=decoded.proof||encoded.stats!=decoded.stats{return Err(format!("run={index} new={new} encode/decode Proof14 first_field={:?} stats_equal={}",encoded.proof.first_difference(&decoded.proof),encoded.stats==decoded.stats));}a.proof+=1;decoded.proof.validate_fixed(5)?;if !new&&decoded.stats!=FIXED_STATS{return Err("old A decoded fixed stats".into());}drop(decoded.plain);
    let admitted=encoded.frame.len()<=483599;a.enc[slot]=a.enc[slot].checked_add(encoded.elapsed_ns).ok_or("encode timer sum")?;a.dec[slot]=a.dec[slot].checked_add(decoded.elapsed_ns).ok_or("decode timer sum")?;a.sizes[slot]=encoded.frame.len();
    let stats=format!("\"encode_stats\":{},\"decode_stats\":{}",encoded.stats,decoded.stats);let frame_bytes=encoded.frame.len();let mut repeated=false;
    if !admitted{if !new||index!=1{return Err("unexpected size refusal position".into());}drop(encoded.frame);for r in refs.iter_mut(){drop(r.take());}}
    else if let Some(prior)=refs[slot].take(){if prior.proof!=encoded.proof||prior.stats!=encoded.stats{return Err(format!("run={index} new={new} repeat Proof14 first_field={:?} stats_equal={}",prior.proof.first_difference(&encoded.proof),prior.stats==encoded.stats));}a.repeat_bytes+=equal(&prior.frame,&encoded.frame,"all repeat frame")?;a.repeats+=1;repeated=true;drop(prior);drop(encoded.frame);}
    else{refs[slot]=Some(Reference{frame:encoded.frame,proof:encoded.proof,stats:encoded.stats});}
    let reference_count=refs.iter().flatten().count();let reference_bytes=refs.iter().flatten().map(|r|r.frame.len()).sum::<usize>();if reference_count>2||reference_bytes>962349{return Err("reference frame bound".into());}
    Ok((format!("{{\"index\":{index},\"depth\":5,\"implementation\":\"{name}\",\"status\":\"{}\",\"frame_bytes\":{frame_bytes},\"encode_elapsed_ns\":{},\"decode_elapsed_ns\":{},\"matched_plain_bytes\":{matched},\"all_plain_equal\":true,\"all_proof_equal\":true,\"proof_fields\":14,\"CDF_as_bits\":true,\"repeat_frame_compared\":{repeated},\"candidate_frames_before_comparison\":{live},\"candidate_frame_bytes_before_comparison\":{live_bytes},\"reference_frames_after\":{reference_count},\"reference_frame_bytes_after\":{reference_bytes},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":{admitted},{stats}}}",if admitted{"passed"}else{"size-rejected"},encoded.elapsed_ns,decoded.elapsed_ns),admitted))
}
fn abba(path:&Path)->Result<()>{
    let mut a=Accounting::default();let mut refs:[Option<Reference>;2]=[None,None];let mut records=Vec::new();let mut status="failed";let mut error=None;
    let outcome=(||->Result<()>{a.reads+=1;let input=read_input(path)?;for (index,new) in [false,true,true,false].into_iter().enumerate(){let(record,ok)=run_one(index,new,&input,&mut a,&mut refs)?;records.push(record);if !ok{status="size-rejected";return Ok(());}}
        if a.encode!=4||a.decode!=4||a.plain!=4||a.proof!=4||a.repeats!=2||a.repeat_bytes!=478750+a.sizes[1]||refs.iter().any(Option::is_some){return Err("ABBA fixed complete counters".into());}status="passed";Ok(())})();
    if let Err(e)=outcome{error=Some(e);}for r in &mut refs{drop(r.take());}let adoption=status=="passed"&&a.sizes[1]<=483599&&a.enc[1]<a.enc[0]&&a.dec[1]<a.dec[0];let evidence=error.as_deref().map_or("null".into(),error_json);
    println!("{{\"status\":\"{status}\",\"operation\":\"abba\",\"implementation_order\":[\"old\",\"new\",\"new\",\"old\"],\"depth_order\":[5,5,5,5],\"records\":[{}],\"runs_completed\":{},\"encode_calls\":{},\"decode_calls\":{},\"plain_comparisons\":{},\"proof_comparisons\":{},\"repeat_frame_comparisons\":{},\"repeat_frame_matched_bytes\":{},\"input_reads\":{},\"warmup_runs\":0,\"abba_cycles\":{},\"peak_live_candidate_frames\":{},\"peak_live_candidate_frame_bytes\":{},\"references_remaining\":0,\"frame_clones_created\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"old_encode_total_ns\":{},\"new_encode_total_ns\":{},\"old_decode_total_ns\":{},\"new_decode_total_ns\":{},\"candidate_adoption_gates_passed\":{adoption},\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"failure_evidence\":{evidence}}}",records.join(","),records.len(),a.encode,a.decode,a.plain,a.proof,a.repeats,a.repeat_bytes,a.reads,usize::from(status=="passed"),a.peak_frames,a.peak_bytes,a.enc[0],a.enc[1],a.dec[0],a.dec[1]);
    if let Some(e)=error{return Err(e);}if status=="size-rejected"{std::process::exit(2);}Ok(())
}
fn main(){let args:Vec<_>=std::env::args_os().collect();let result=match args.get(1).and_then(|s|s.to_str()){
    Some("compare") if args.len()==2=>comparison::run(),Some("selfcheck-old") if args.len()==2=>codec::run_selfcheck(),Some("selfcheck-new") if args.len()==2=>codec::candidate::run_selfcheck(),Some("abba") if args.len()==3=>abba(Path::new(&args[2])),_=>Err("usage: probe compare|selfcheck-old|selfcheck-new|abba INPUT".into())};
    if let Err(e)=result{let evidence=error_json(&e);eprintln!("{evidence}");std::process::exit(1);}}
