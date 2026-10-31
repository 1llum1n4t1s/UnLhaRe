//! 一入力四featureのtraining-only損失機会診断。frame/coderを生成しない。
#![allow(dead_code)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../static-direct-mdl/model.rs"] mod model;
#[path="features.rs"] mod features;
#[path="aggregate.rs"] mod aggregate;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
fn read_file(path:&str,expected:usize)->Result<Vec<u8>>{let file=File::open(path).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=expected as u64{return Err("file length pin".into());}let mut bytes=Vec::new();bytes.try_reserve_exact(expected).map_err(|_|"file RAM allocation")?;file.take(expected as u64+1).read_to_end(&mut bytes).map_err(|e|e.to_string())?;if bytes.len()!=expected{return Err("bounded read extent".into());}Ok(bytes)}
fn execute()->Result<()>{let args:Vec<_>=std::env::args().collect();if args.len()!=4 || args[1]!="diagnose"{return Err("usage: diagnose fixed-input frozen-model-header".into());}
    let history_checks=features::history_e2e()?;let aggregate_checks=aggregate::aggregate_e2e()?;
    let input=read_file(&args[2],2811006)?;let header=read_file(&args[3],14077)?;let static_model=model::Model::parse(&header,112616)?;if static_model.cdfs.len()!=62{return Err("frozen selected CDF count".into());}
    let front=frontend::Front::new(&input)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("fixed Front/count/capacity".into());}
    let hist=front.hist()?;let expected=features::Meta{tokens:hist.tokens,runs:hist.runs as usize,escapes:hist.escapes as usize,grammar:hist.grammar,history_checks:hist.tokens[0]+hist.tokens[1]};
    if expected.tokens!=[889227,889227] || expected.escapes!=742 || expected.grammar!=0x58735a2b7383d755{return Err("frozen frontend grammar/totals".into());}drop(hist);
    let mut component=[aggregate::Kahan::default();2];let mut all=aggregate::Kahan::default();let mut baseline_tokens=[0u64;2];
    let escapes=front.walk(|c,s,x,b,t,l,_|{let loss=static_model.score(c,s,x,b,t,l)?;component[c].add(loss)?;all.add(loss)?;baseline_tokens[c]=baseline_tokens[c].checked_add(1).ok_or("baseline tokens overflow")?;Ok(())})?;
    let attributed=component[0].sum+component[1].sum;let saved=5000107.114226128f64;let difference=(attributed-saved).abs();if escapes!=742 || baseline_tokens!=expected.tokens || difference>1e-6 || (all.sum-saved).abs()>1e-6 || (all.sum-attributed).abs()>1e-6{return Err("frozen loss component attribution mismatch".into());}
    let mut records=Vec::new();for family in [features::Family::Global,features::Family::Symbol,features::Family::Recent,features::Family::Joint]{records.push(aggregate::diagnose(&front,family,&expected)?);}
    println!("{{\"status\":\"passed\",\"kind\":\"training_only_feature_opportunity\",\"history_hand_checks\":{history_checks},\"aggregate_hand_checks\":{aggregate_checks},\"input_reads\":1,\"BWT_calls\":1,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"family_count\":4,\"runs\":{},\"primary\":{},\"rank_tokens\":889227,\"length_tokens\":889227,\"direct_tokens\":1778454,\"escape_bytes\":742,\"grammar\":{},\"baseline_component_loss_bits\":[{:.12},{:.12}],\"baseline_attributed_total_loss_bits\":{attributed:.12},\"baseline_single_accumulator_loss_bits\":{:.12},\"saved_static_loss_bits\":{saved:.12},\"baseline_absolute_difference_bits\":{difference:.12},\"baseline_component_token_bytes_ceil\":[{},{}],\"baseline_token_bytes_ceil\":{},\"fixed_run_capacity\":{},\"fixed_run_capacity_bytes\":{},\"score_phase_worst_estimate_with_margin_bytes\":85131891,\"BWT_phase_worst_estimate_bytes\":141598926,\"RAM_estimate_limit_bytes\":167772160,\"peak_RAM_measured\":false,\"old_expert_reproduced\":false,\"family_records\":[{}]}}",front.runs.len(),front.primary,expected.grammar,component[0].sum,component[1].sum,all.sum,(component[0].sum/8.0).ceil() as u64,(component[1].sum/8.0).ceil() as u64,(attributed/8.0).ceil() as u64,front.runs.capacity(),front.runs.capacity()*12,records.join(","));Ok(())}
fn main(){if let Err(e)=execute(){eprintln!("direct-feature-opportunity: {e}");std::process::exit(1);}}
