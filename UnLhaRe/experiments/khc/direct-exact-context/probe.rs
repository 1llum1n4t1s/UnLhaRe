//! 完全key辞書とu16 Fenwickの一設定loss-only診断。coder/frame/速度ではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../direct-feature-opportunity/features.rs"] mod features;
#[path="../causal-direct-mix/fenwick.rs"] mod old_fenwick;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
mod fenwick;
mod dictionary;
mod mixture;
mod happy;
mod adversarial;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)]
struct Kahan {sum:f64,correction:f64}
impl Kahan {fn add(&mut self,value:f64)->Result<()>{if !value.is_finite() || value< -2e-12{return Err("loss finite/range".into());}let y=value-self.correction;let sum=self.sum+y;self.correction=(sum-self.sum)-y;self.sum=sum;if !sum.is_finite(){return Err("loss sum finite".into());}Ok(())}}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen fixed-input".into());}
    memory::validate_layout()?;
    let checks=format!("{{\"happy\":{{\"fenwick\":{},\"dictionary\":{},\"mixture\":{}}},\"adversarial\":{{\"fenwick\":{},\"dictionary\":{},\"mixture\":{}}}}}",happy::fenwick()?,happy::dictionary()?,happy::mixture()?,adversarial::fenwick()?,adversarial::dictionary()?,adversarial::mixture()?);
    // 各小E2E内model/map/snapshotは復帰時に破棄済み。fixed入力は一回だけ読む。
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed length".into());}let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("bounded input read".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("frozen fixed Front counts/capacity".into());}
    let mut mix=mixture::Mix::new()?;let heap_bytes=mix.heap_bytes();let inline_bytes=std::mem::size_of::<mixture::Mix>();let model_bytes=mix.bytes();
    let mix_working=model_bytes+front.runs.capacity()*12+plain.capacity()+1369112+4*1024*1024;
    if heap_bytes!=120652224 || inline_bytes>4096 || mix_working>141613654 || mix_working>160*1024*1024{return Err("exact model allocation estimate bound".into());}
    let mut quantized=[Kahan::default();2];let mut unquantized=[Kahan::default();2];let mut expert=[[Kahan::default();2];4];let mut minimum_frequency=u32::MAX;
    let meta=features::walk(&front,features::Family::Joint,|component,joint,token,limit,recent|{let keys=mixture::four_keys(component,joint,recent)?;let prediction=mix.predict(keys,token,limit)?;let frequency=prediction.high-prediction.low;if frequency==0{return Err("actual zero Q interval".into());}minimum_frequency=minimum_frequency.min(frequency);quantized[component].add((32768.0/frequency as f64).log2())?;let p=prediction.mixture_probability;unquantized[component].add(-p.log2())?;for i in 0..4{expert[i][component].add(-prediction.probabilities[i].log2())?;}mix.observe(prediction)?;Ok(())})?;
    if meta.tokens!=[889227,889227] || meta.runs!=889227 || meta.escapes!=742 || meta.grammar!=0x58735a2b7383d755 || meta.history_checks!=1778454 || mix.observations!=1778454{return Err("exact frozen metadata totals".into());}
    let terminal_cells=mix.verify_terminal()?;if terminal_cells!=29483040{return Err("terminal all row leaf extent".into());}
    for bank in &mix.banks{if bank.table.ops.updates!=1778454 || bank.table.ops.queries!=3556908{return Err("expert update/query event counts".into());}}
    if mix.banks[2].map.as_ref().ok_or("recent exact map absent")?.used!=53860 || mix.banks[3].map.as_ref().ok_or("joint exact map absent")?.used!=21737{return Err("frozen distinct key totals".into());}
    let q=[quantized[0].sum,quantized[1].sum];let u=[unquantized[0].sum,unquantized[1].sum];let q_total=q[0]+q[1];let u_total=u[0]+u[1];let token_bytes=(q_total/8.0).ceil() as u64;let screen=token_bytes.checked_add(742+285+4+2048).ok_or("screen overflow")?;
    let experts=expert.map(|v|[v[0].sum,v[1].sum]);let banks=mix.banks.iter().map(|b|b.json()).collect::<Vec<_>>().join(",");let run_capacity=front.runs.capacity();let input_capacity=plain.capacity();
    drop(mix);drop(front);drop(plain);
    let(memory,peak_gate)=memory::read_once()?;let gate=peak_gate.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"direct_exact_context_loss_only\",\"E2E\":{checks},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":1,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"runs\":889227,\"primary\":1762795,\"tokens\":[889227,889227],\"grammar\":{},\"escape_bytes\":742,\"history_checks\":{},\"quantized_component_loss_bits\":{q:?},\"quantized_total_loss_bits\":{q_total:.12},\"unquantized_component_loss_bits\":{u:?},\"unquantized_total_loss_bits\":{u_total:.12},\"expert_component_loss_bits\":{experts:?},\"minimum_actual_Q_frequency\":{minimum_frequency},\"Q_token_bytes_ceil\":{token_bytes},\"model_table_saved_bytes\":0,\"policy_metadata_defined\":false,\"framing_bytes\":285,\"model_bitlength_bytes\":4,\"coder_reserve_bytes\":2048,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"model_heap_capacity_bytes\":{heap_bytes},\"model_inline_bytes\":{inline_bytes},\"model_total_capacity_and_inline_bytes\":{model_bytes},\"inline_Metadata_worst_bytes\":4096,\"mix_working_RAM_estimate_bytes\":{mix_working},\"mix_phase_precomputed_worst_bytes\":141613654,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_estimate_limit_bytes\":167772160,\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"terminal_rows_checked\":114720,\"terminal_leaf_and_Fenwick_node_checks\":{terminal_cells},\"terminal_all_exact_maps_checked\":true,\"all_updates_dense_oracle\":false,\"f64_floor_portable_wire_verified\":false,\"memory\":{memory},\"peak_resource_gate_passed\":{gate},\"banks\":[{banks}]}}",meta.grammar,meta.history_checks,screen<=483599);Ok(())
}
fn main(){if let Err(error)=execute(){eprintln!("direct-exact-context: {error}");std::process::exit(1);}}
