//! 静的direct-token一候補のmetadata/loss予算screen。実coderではない。
#![allow(dead_code)]
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_cts.rs"] mod float_cts;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../lookup-float-cts/float_scope.rs"] mod reference;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
#[path="../lookup-float-profile/proof.rs"] mod proof;
#[path="histogram.rs"] mod histogram;
#[path="frontend.rs"] mod frontend;
#[path="observer.rs"] mod observer;
#[path="model.rs"] mod model;
#[path="observed_scope.rs"] mod observed;
use std::{fs::{File,OpenOptions},io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
fn same_bytes(a:&[u8],b:&[u8],label:&str)->Result<()>{if a.len()!=b.len(){return Err(format!("{label} length"));}for(i,(&x,&y))in a.iter().zip(b).enumerate(){if x!=y{return Err(format!("{label} different at {i}"));}}Ok(())}
fn same_hist(a:&histogram::Hist,b:&histogram::Hist)->Result<usize>{if a.rank.len()!=b.rank.len() || a.length.len()!=b.length.len(){return Err("hist extent comparison".into());}for(component,(x,y))in [(&a.rank,&b.rank),(&a.length,&b.length)].into_iter().enumerate(){for(i,(&p,&q))in x.iter().zip(y).enumerate(){if p!=q{return Err(format!("hist component {component} cell {i}: {p}!={q}"));}}}if a.tokens!=b.tokens || a.runs!=b.runs || a.escapes!=b.escapes || a.grammar!=b.grammar{return Err("hist meta mismatch".into());}Ok(a.rank.len()+a.length.len())}
fn case(name:&str,plain:&[u8],header_path:Option<&Path>)->Result<String>{
    let reference=reference::codec::run_profile(plain,5)?;let restore=reference::codec::run_restore(&reference.frame)?;
    observer::start()?;let instrumented=observed::codec::run_profile(plain,5)?;let enc_hist=observer::finish()?;
    observer::start()?;let inst_restore=observed::codec::run_restore(&instrumented.frame)?;let dec_hist=observer::finish()?;
    same_bytes(&reference.frame,&instrumented.frame,"whole reference/observer frame")?;
    same_bytes(plain,&restore.plain,"reference fullplain")?;same_bytes(plain,&inst_restore.plain,"observer fullplain")?;
    let p=proof::Proof14::frozen_debug(&format!("{:?}",reference.proof))?;
    for debug in [format!("{:?}",restore.proof),format!("{:?}",instrumented.proof),format!("{:?}",inst_restore.proof)]{if proof::Proof14::frozen_debug(&debug)?!=p{return Err("typed all14 Proof mismatch".into());}}
    if reference.stats!=restore.stats || reference.stats!=instrumented.stats || reference.stats!=inst_restore.stats{return Err("all stats mismatch".into());}
    let front=frontend::Front::new(plain)?;if front.primary!=p.primary || front.runs.len()!=p.runs{return Err("frontend primary/runs".into());}let hist=front.hist()?;
    let cells=same_hist(&hist,&enc_hist)?;same_hist(&hist,&dec_hist)?;
    if hist.grammar!=p.grammar || hist.tokens!=[p.rank as u64,p.length as u64] || hist.escapes!=p.escape as u64{return Err("frontend/reference grammar totals".into());}
    let trained=model::Model::train(&hist)?;let(header,bits)=trained.header()?;let parsed=model::Model::parse(&header,bits)?;
    if trained!=parsed{return Err("whole CDF/group/dispatch roundtrip".into());}
    let mut loss=0.0;let mut compensation=0.0;let mut score_tokens=0u64;
    let escape_replay=front.walk(|c,s,x,b,t,l,_|{let value=parsed.score(c,s,x,b,t,l)?;let y=value-compensation;let sum=loss+y;compensation=(sum-loss)-y;loss=sum;score_tokens=score_tokens.checked_add(1).ok_or("score count overflow")?;Ok(())})?;
    if !loss.is_finite() || loss<0.0 || score_tokens!=hist.runs.checked_mul(2).ok_or("direct token overflow")? || escape_replay as u64!=hist.escapes{return Err("loss replay totals".into());}
    let token_bytes=(loss/8.0).ceil() as u64;let budget=(header.len() as u64).checked_add(token_bytes).and_then(|x|x.checked_add(hist.escapes)).and_then(|x|x.checked_add(285+4+2048)).ok_or("budget overflow")?;
    if let Some(path)=header_path{if plain.len()!=2811006 || reference.frame.len()!=478750 || hist.runs!=889227 || hist.escapes!=742 || p.branches!=[2725772,1099568]{return Err("fixed reference totals".into());}if header.len()>1048576 || header.len()!=bits.div_ceil(8){return Err("metadata save bound".into());}let mut file=OpenOptions::new().write(true).create_new(true).open(path).map_err(|e|format!("header create_new {e}"))?;file.write_all(&header).map_err(|e|e.to_string())?;file.sync_all().map_err(|e|e.to_string())?;drop(file);let mut saved=Vec::new();File::open(path).map_err(|e|e.to_string())?.take(1048577).read_to_end(&mut saved).map_err(|e|e.to_string())?;same_bytes(&header,&saved,"saved model header")?;if model::Model::parse(&saved,bits)?!=trained{return Err("saved model parser mismatch".into());}}
    let lookup=trained.cdfs.len().checked_mul(32768*2).ok_or("lookup bytes overflow")?;
    let cdf_bytes=trained.cdfs.iter().map(|c|(c.freq.len()+c.prefix.len())*4).sum::<usize>();
    let dispatch=(257+9)*4*std::mem::size_of::<usize>();
    Ok(format!("{{\"name\":\"{name}\",\"plain_bytes\":{},\"reference_frame_bytes\":{},\"whole_frame_equal\":true,\"fullplain_equal\":true,\"typed_Proof14_equal\":true,\"stats_equal\":true,\"hist_cells_per_comparison\":{cells},\"hist_comparisons\":2,\"proof\":{},\"stats\":{},\"direct_tokens\":{score_tokens},\"old_branches\":{},\"model_bits\":{bits},\"model_bytes\":{},\"selected_CDFs\":{},\"tags\":{:?},\"truncated_loss_bits\":{loss:.12},\"token_bytes_ceil\":{token_bytes},\"escape_bytes\":{},\"framing_bytes\":285,\"model_bit_length_bytes\":4,\"coder_reserve_bytes\":2048,\"budget_bytes\":{budget},\"budget_gate_passed\":{},\"lookup_bytes_estimate\":{lookup},\"hist_bytes_each\":1369112,\"three_hist_bytes\":4107336,\"selected_dense_CDF_bytes_each\":{cdf_bytes},\"two_selected_dense_CDF_bytes\":{},\"dispatch_bytes_each\":{dispatch},\"run_bytes\":{},\"run_capacity_bytes\":{},\"BWT_last_bytes\":{},\"input_bytes\":{},\"header_RAM_bytes\":{}}}",plain.len(),reference.frame.len(),p.json(),reference.stats,p.branches.iter().sum::<u64>(),header.len(),trained.cdfs.len(),trained.tag_counts(),hist.escapes,budget<=483599,cdf_bytes*2,front.runs.len()*12,front.runs.capacity()*12,front.last_len*2,plain.len(),header.len()))
}
fn execute()->Result<()>{let arguments:Vec<_>=std::env::args().collect();if arguments.len()!=4 || arguments[1]!="screen"{return Err("usage: screen fixed-input model-header-output".into());}
    let(header_normal,header_rejected)=model::header_e2e()?;
    let fixtures=[("empty",Vec::new()),("one",vec![7]),("repeat",vec![3;2048]),("all256",(0..=255).collect()),("text",b"static direct model history and metadata\n".repeat(7))];let mut records=Vec::new();for(name,plain)in fixtures{records.push(case(name,&plain,None)?);}
    let fixed_file=File::open(&arguments[2]).map_err(|e|e.to_string())?;if fixed_file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed input length".into());}let mut fixed=Vec::new();fixed_file.take(2811007).read_to_end(&mut fixed).map_err(|e|e.to_string())?;if fixed.len()!=2811006{return Err("bounded fixed input".into());}records.push(case("fixed",&fixed,Some(Path::new(&arguments[3])))?);
    println!("{{\"status\":\"passed\",\"kind\":\"metadata_loss_budget_only\",\"cases\":{},\"header_normal_checks\":{header_normal},\"header_rejections\":{header_rejected},\"maximum_header_bits\":8208276,\"maximum_header_bytes\":1026035,\"maximum_selected_CDFs\":1332,\"maximum_lookup_bytes\":87293952,\"records\":[{}]}}",records.len(),records.join(","));Ok(())}
fn main(){if let Err(e)=execute(){eprintln!("static-direct-mdl: {e}");std::process::exit(1);}}
