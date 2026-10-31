//! trained branch-history MDLの実header込み必要size診断。coder/frame/速度ではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
mod grammar;
mod model;
mod happy;
mod adversarial;
use std::{fs::{File,OpenOptions},io::{Read,Write}};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)]
struct Kahan {sum:f64,correction:f64}
impl Kahan {fn add(&mut self,value:f64)->Result<()>{if !value.is_finite() || value<0.0{return Err("loss finite/range".into());}let y=value-self.correction;let sum=self.sum+y;self.correction=(sum-self.sum)-y;self.sum=sum;if !sum.is_finite(){return Err("loss total finite".into());}Ok(())}}
fn fixed(meta:&grammar::Meta)->Result<()>{if meta.tokens!=[889227,889227] || meta.runs!=889227 || meta.escapes!=742 || meta.history_checks!=1778454 || meta.grammar!=0x58735a2b7383d755 || meta.branches!=[2725772,1099568] || meta.classes!=[889227,620240,1216305,889227,64372,145969]{return Err("frozen branch/class/history totals".into());}Ok(())}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=4 || args[1]!="screen"{return Err("usage: screen fixed-input model-header-output".into());}memory::validate_layout()?;
    let happy=happy::run()?;let adversarial=adversarial::run()?;
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed input length".into());}let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed input grew".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("fixed Front/capacity".into());}
    let mut hist=model::Hist::new()?;let trained=grammar::walk(&front,|class,k,history,child|if k==1{if child!=0{return Err("implicit child".into());}Ok(())}else{hist.record(class,k,history,child)})?;fixed(&trained)?;
    let fit=model::Fit::build(&hist)?;let dp_loss=fit.loss_bits();let leaves=fit.selected_leaf_count();let splits=fit.selected_split_count();let(data,bits)=fit.serialize()?;
    if data.len()!=bits.div_ceil(8) || data.len()>model::MAX_BYTES || bits!=fit.selected_header_bits(){return Err("actual metadata extent".into());}
    let parsed=model::parse(&data,bits)?;let mut cdf_comparisons=0;for class in 0..6{for k in 2..=4{for history in 0..1024u16{if fit.lookup(class,k,history)?!=parsed.lookup(class,k,history)?{return Err("parsed full dispatch CDF mismatch".into());}cdf_comparisons+=1;}}}
    let mut loss=Kahan::default();let mut component=[Kahan::default();2];let mut classes=[Kahan::default();6];let mut coded_branches=0usize;let mut implicit_branches=0usize;let mut min_frequency=u16::MAX;
    let replay=grammar::walk(&front,|class,k,history,child|{if k==1{implicit_branches+=1;return Ok(());}let f=parsed.lookup(class,k,history)?;if child>=k || f[child]<2 || f[..k].iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("parsed actual interval support/total".into());}let value=(32768.0/f64::from(f[child])).log2();loss.add(value)?;component[class/3].add(value)?;classes[class].add(value)?;coded_branches+=1;min_frequency=min_frequency.min(f[child]);Ok(())})?;fixed(&replay)?;
    if trained!=replay || cdf_comparisons!=18432 || coded_branches+implicit_branches!=3825340 || !dp_loss.is_finite() || (dp_loss-loss.sum).abs()>1e-6{return Err("whole grammar/DP/parsed replay loss".into());}
    let whole_bits=loss.sum+bits as f64;let dp_whole=dp_loss+fit.selected_header_bits() as f64;if (whole_bits-dp_whole).abs()>1e-6{return Err("DP whole model expense".into());}
    let hist_bytes=hist.capacity_bytes();let fit_bytes=fit.capacity_bytes();let dispatch_bytes=parsed.capacity_bytes();let packet_capacity=data.capacity();let node_size=model::Fit::node_size();let model_working=hist_bytes+fit_bytes+dispatch_bytes+packet_capacity+4096+4*1024*1024;
    let phase=front.runs.capacity()*12+plain.capacity()+model_working+1369112+4*1024*1024;
    if hist.counts.capacity()!=24570 || node_size>32 || model_working>8*1024*1024 || phase>32*1024*1024{return Err("MDL capacity RAM bound".into());}
    let token_bytes=(loss.sum/8.0).ceil() as u64;let screen=token_bytes.checked_add(data.len() as u64).and_then(|v|v.checked_add(3079)).ok_or("screen bytes overflow")?;
    // 新metadataだけをno-replace保存。入力/frame/plain/traceは保存しない。
    let mut output=OpenOptions::new().write(true).create_new(true).open(&args[3]).map_err(|e|e.to_string())?;output.write_all(&data).map_err(|e|e.to_string())?;output.flush().map_err(|e|e.to_string())?;drop(output);
    let component_loss=component.map(|v|v.sum);let class_loss=classes.map(|v|v.sum);let run_capacity=front.runs.capacity();let input_capacity=plain.capacity();let header_bytes=data.len();
    drop(parsed);drop(fit);drop(hist);drop(data);drop(front);drop(plain);
    let(memory,peak)=memory::read_once()?;let gate=peak.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"trained_branch_history_MDL_size_only\",\"E2E\":{{\"happy\":{happy},\"adversarial\":{adversarial}}},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":2,\"tokens\":{:?},\"runs\":{},\"primary\":1762795,\"escape_bytes\":{},\"grammar\":{},\"history_checks_per_walk\":{},\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"whole_two_walk_meta_equal\":true,\"coded_branches\":{coded_branches},\"implicit_prefix1_branches\":{implicit_branches},\"minimum_actual_frequency\":{min_frequency},\"quantized_component_loss_bits\":{component_loss:?},\"quantized_class_loss_bits\":{class_loss:?},\"quantized_branch_loss_bits\":{:.12},\"DP_selected_hist_loss_bits\":{dp_loss:.12},\"DP_vs_parsed_loss_abs_bits\":{:.12},\"whole_loss_plus_header_bits\":{whole_bits:.12},\"header_bits\":{bits},\"header_bytes\":{header_bytes},\"header_packet_capacity\":{packet_capacity},\"selected_leaves\":{leaves},\"selected_splits\":{splits},\"full_CDF_comparisons\":{cdf_comparisons},\"Q_token_bytes_ceil\":{token_bytes},\"side_bytes\":3079,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"hist_capacity_bytes\":{hist_bytes},\"fit_capacity_bytes\":{fit_bytes},\"fit_node_size\":{node_size},\"dispatch_capacity_bytes\":{dispatch_bytes},\"model_working_RAM_estimate_bytes\":{model_working},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":8388608,\"fixed_phase_RAM_limit_bytes\":33554432,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_resource_gate_passed\":{gate},\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"speed_claimed\":false,\"portable_wire_verified\":false,\"trained_in_sample_only\":true}}",trained.tokens,trained.runs,trained.escapes,trained.grammar,trained.history_checks,trained.branches,trained.classes,trained.prefixes,trained.final_history,loss.sum,(dp_loss-loss.sum).abs(),screen<=483599);Ok(())
}
fn main(){if let Err(error)=execute(){eprintln!("branch-history-mdl: {error}");std::process::exit(1);}}
