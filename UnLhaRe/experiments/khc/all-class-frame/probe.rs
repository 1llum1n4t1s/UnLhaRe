//! 新規記述。少量finite first、その後固定groupを1MiB×3blockでRAM逐次往復。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../node-history-information/grammar.rs"] mod grammar;
#[path="../node-history-information/counts.rs"] mod counts;
#[path="../root-history-order/model.rs"] mod model;
#[path="../root-history-order/bundle.rs"] mod bundle;
#[path="../paid-code-tree/model.rs"] mod paid_model;
#[path="../paid-code-tree/codebook.rs"] mod codebook;
#[path="../all-class-static/packet.rs"] mod packet;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/packed.rs"] mod packed;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../direct-token/multi_range.rs"] mod multi_range;
mod codec;
mod finite;
mod adversarial;
use std::{fs::File,io::Read,time::Instant};
use codec::Result;
fn execute()->Result<()>{let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen input".into());}memory::validate_layout()?;let(finite,finite_total)=finite::run()?;let adversarial=adversarial::run()?;
    let mut file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed group length".into());}let mut raw=Vec::new();raw.try_reserve_exact(codec::MAX_INPUT).map_err(|_|"chunk allocation")?;let mut blocks=String::new();blocks.try_reserve_exact(12288).map_err(|_|"block report allocation")?;
    let mut fixed=finite::Totals::default();let mut reads=0usize;let mut frame_bytes=0usize;let mut enc_ns=0u128;let mut dec_ns=0u128;
    for block in 0..3{let n=(2811006-fixed.inputs).min(codec::MAX_INPUT);raw.resize(n,0);let mut at=0;while at<n{let got=file.read(&mut raw[at..]).map_err(|e|e.to_string())?;reads+=1;if got==0{return Err("fixed input truncated".into());}at+=got;}
        let now=Instant::now();let(frame,e)=codec::encode(&raw)?;let encode_ns=now.elapsed().as_nanos();let now=Instant::now();let(decoded,d)=codec::decode(&frame)?;let decode_ns=now.elapsed().as_nanos();if decoded!=raw{return Err(format!("fixed block {block} byte mismatch"));}
        fixed.inputs+=n;fixed.add(&e,&d);frame_bytes+=frame.len();enc_ns+=encode_ns;dec_ns+=decode_ns;
        let report_capacity=finite.capacity()+adversarial.capacity()+blocks.capacity()+1024;let caller_encode=raw.capacity()-raw.len()+report_capacity;let caller_decode=raw.capacity()+report_capacity;
        fixed.max_capacity=fixed.max_capacity.max(e.phase_capacity_bound+caller_encode).max(d.phase_capacity_bound+caller_decode);fixed.max_scratch=fixed.max_scratch.max(codec::SCRATCH_BOUND+report_capacity);
        if fixed.max_capacity>64*codec::MAX_INPUT || fixed.max_scratch>65536{return Err("caller codec resource gate".into());}
        if block!=0{blocks.push(',');}blocks.push_str(&format!("{{\"index\":{block},\"raw_bytes\":{n},\"frame_bytes\":{},\"method\":{},\"alphabet_bytes\":{},\"metadata_bytes\":{},\"payload_bytes\":{},\"header_bytes\":40,\"encode_ns\":{encode_ns},\"decode_ns\":{decode_ns},\"BWT_calls\":{},\"grammar_walks\":{},\"Fit_builds\":{},\"root_writes\":{},\"root_CDF_comparisons\":{},\"encode_branches\":{},\"decode_branches\":{},\"implicit_k1\":{},\"escape_bytes\":{},\"run_count\":{},\"stored_reason\":\"{}\",\"front_capacity_bytes\":{},\"dense_capacity_bytes\":{},\"Hist_pair_capacity_bytes\":{},\"Fit_pair_capacity_bytes\":{},\"packet_capacity_bytes\":{},\"Forest_capacity_bytes\":{},\"parse_transient_capacity_bytes\":{},\"range_capacity_bound_bytes\":{},\"encoder_output_capacity_bytes\":{},\"decoder_output_capacity_bytes\":{},\"inverse_words_capacity_bytes\":{},\"encode_capacity_bound_bytes\":{},\"decode_capacity_bound_bytes\":{},\"scratch_bound_bytes\":{},\"byte_exact\":true}}",e.frame,e.method,e.alphabet,e.metadata,e.payload,e.bwt,e.walks,e.fits,e.roots,e.root_cdfs,e.branches,d.branches,d.implicit,d.escapes,d.runs,e.stored_reason,e.front_capacity,e.dense_capacity,e.hist_capacity,e.fit_capacity,e.packet_capacity,e.forest_capacity,e.parse_transient,e.range_capacity_bound,e.output_capacity,d.output_capacity,d.inverse_capacity,e.phase_capacity_bound,d.phase_capacity_bound,e.scratch_capacity_bound));
        if blocks.len()>12288{return Err("blocks report bound".into());}drop(decoded);drop(frame);
    }
    let mut extra=[0u8;1];let got=file.read(&mut extra).map_err(|e|e.to_string())?;reads+=1;if got!=0 || fixed.inputs!=2811006{return Err("fixed input grew".into());}drop(raw);drop(file);
    let(memory,peak)=memory::read_once()?;let private=memory.split("\"peak_private_commit_bytes\":").nth(1).ok_or("private peak missing")?.split([',','}']).next().ok_or("private peak extent")?.parse::<usize>().map_err(|_|"private peak unavailable")?;let resource=peak==Some(true)&&private<=160*1024*1024;if !resource{return Err("OS resource gate".into());}
    println!("{{\"status\":\"passed\",\"kind\":\"all_class_frame_roundtrip\",\"finite_E2E\":{finite},\"adversarial_E2E\":{adversarial},\"fixed_blocks\":[{blocks}],\"fixed_input_bytes\":{},\"fixed_input_read_calls\":{reads},\"fixed_encode_calls\":{},\"fixed_decode_calls\":{},\"fixed_BWT_calls\":{},\"fixed_grammar_walks\":{},\"fixed_Fit_builds\":{},\"fixed_root_CDF_comparisons\":{},\"fixed_stored_blocks\":{},\"fixed_compressed_blocks\":{},\"actual_frame_bytes_total\":{frame_bytes},\"actual_encode_ns_total\":{enc_ns},\"actual_decode_ns_total\":{dec_ns},\"fixed_byte_exact\":true,\"frames_retained_at_once\":1,\"max_codec_capacity_bound_bytes\":{},\"max_scratch_bound_bytes\":{},\"memory\":{memory},\"OS_resource_gate_passed\":{resource},\"teacher_models_executed\":0,\"raw_files_saved\":0,\"CRC_is_authentication\":false,\"seven_zip_superiority_verified\":false,\"speed_superiority_verified\":false,\"product_integration_verified\":false}}",fixed.inputs,fixed.encode_calls,fixed.decode_calls,fixed.bwt,fixed.walks,fixed.fits,fixed.cdfs,fixed.stored,fixed.compressed,fixed.max_capacity.max(finite_total.max_capacity),fixed.max_scratch.max(finite_total.max_scratch));Ok(())}
fn main(){if let Err(e)=execute(){eprintln!("all-class-frame: {e}");std::process::exit(1);}}
