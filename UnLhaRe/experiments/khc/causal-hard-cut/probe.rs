//! 新hard-cutを原poolへ接続するloss-only screen。診断TLS擾乱あり。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../float-static-node-gap/features.rs"] mod features;
#[path="../float-static-node-gap/grammar.rs"] mod grammar;
#[path="../lookup-float-cts/float_cts.rs"] mod old_cts;
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../prices.rs"] mod prices;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
mod engine;
use engine as float_cts;
mod scope;
mod happy;
mod adversarial;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)] struct Sum{value:f64,correction:f64}
impl Sum{fn add(&mut self,x:f64)->Result<()>{if !x.is_finite() || x<0.0{return Err("independent loss finite".into());}let y=x-self.correction;let t=self.value+y;self.correction=(t-self.value)-y;self.value=t;if !t.is_finite(){return Err("independent loss total".into());}Ok(())}}
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err("loss aggregation mismatch".into());}Ok(())}
fn fixed(m:&grammar::Meta)->Result<()>{if m.tokens!=[889227;2] || m.runs!=889227 || m.escapes!=742 || m.history_checks!=1778454 || m.grammar!=0x58735a2b7383d755 || m.branches!=[2725772,1099568] || m.classes!=[889227,620240,1216305,889227,64372,145969]{return Err("fixed grammar Meta".into());}Ok(())}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen fixed-input".into());}memory::validate_layout()?;
    // 各run内oracle/dump/mirrorをここでdrop。Model::newがTLSを再resetする。
    let happy=happy::run()?;let adversarial=adversarial::run()?;
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed input length".into());}let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed input grew".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("fixed Front capacity".into());}
    let mut model=scope::model::Model::new(5)?;let start=engine::audit_summary();if start.observations!=[0;6] || start.history!=[0;6] || start.root_best_Q8!=[0;6] || start.selected_price_Q8!=[0;6]{return Err("fixed sole Model TLS reset".into());}
    let mut loss=Sum::default();let mut alternate=Sum::default();let mut component=[Sum::default();2];let mut classes=[Sum::default();6];let mut coded=0u64;let mut implicit=0u64;let mut intervals=0u64;let mut selects=0u64;let mut minimum=u32::MAX;
    let meta=grammar::walk(&front,|c,node,class,k,_history,child,feature|{
        let s=model.predict(c,feature.context,node,feature.symbol,feature.recent,feature.previous,k)?;let mut sum=0u32;let mut observed=0;
        for j in 0..k{let(lo,f,total)=s.interval(j)?;if lo!=sum || f<2 || total!=32768 || s.select(lo)?!=j || s.select(lo+f-1)?!=j{return Err("all legal actual pool CDF".into());}sum=sum.checked_add(f).ok_or("CDF total overflow")?;if j==child{observed=f;}intervals+=1;selects+=2;}
        if sum!=32768 || observed<2 || child>=k{return Err("observed interval".into());}minimum=minimum.min(observed);
        let value=-(f64::from(observed)/32768.0).log2();loss.add(value)?;alternate.add((32768.0/f64::from(observed)).log2())?;component[c].add(value)?;classes[class].add(value)?;if k==1{implicit+=1;}else{coded+=1;}model.observe(&s,child)?;Ok(())
    })?;fixed(&meta)?;
    let primary=engine::audit_summary();if primary.observations.map(u64::from)!=meta.classes || model.class_observations().map(u64::from)!=meta.classes || model.audit.branches!=meta.branches || primary.history.map(|h|h&1023)!=meta.final_history || coded!=3825218 || implicit!=122 || intervals!=14305969 || selects!=28611938{return Err("terminal Model/primary/grammar counts".into());}
    if loss.value.to_bits()!=model.audit.entropy().to_bits(){return Err("independent actual entropy bits".into());}near(alternate.value,loss.value)?;near(component[0].value+component[1].value,loss.value)?;near(classes.iter().map(|s|s.value).sum(),loss.value)?;
    for c in 0..6{if primary.selected_depth_counts[c].iter().sum::<u64>()!=meta.classes[c]{return Err("selected depth count".into());}}
    if primary.node_capacity!=8190 || primary.node_size>40 || primary.capacity_bytes>1048576{return Err("actual primary capacity".into());}
    // 原Model.private Vecは新getterを足さないため、baseはsource構造boundを使う。
    let base_bound=16*1024*1024;let tree_bound=65536;let scratch_bound=65536;let primary_bytes=primary.capacity_bytes;let collector_bytes=std::mem::size_of::<engine::AuditSummary>();let price_bytes=prices::MEMORY_BYTES;
    let model_ram=base_bound+primary_bytes+tree_bound+scratch_bound+collector_bytes+price_bytes+4194304;let phase=front.runs.capacity()*12+plain.capacity()+model_ram+1369112+4194304;
    if model_ram>33554432 || phase>67108864{return Err("source bound/model/phase resource".into());}let token_bytes=(loss.value/8.0).ceil() as u64;let screen=token_bytes.checked_add(3079).ok_or("screen overflow")?;
    let class_loss=classes.map(|v|v.value);let component_loss=component.map(|v|v.value);let prefixes=model.audit.prefixes;let rescales=model.audit.rescales;let cold=model.audit.cold;let digest=model.state_digest();let entropy=model.audit.entropy();let run_capacity=front.runs.capacity();let input_capacity=plain.capacity();
    drop(model);drop(front);drop(plain);let(memory,peak)=memory::read_once()?;let gate=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"causal_hard_cut_loss_only\",\"E2E\":{{\"happy\":{happy},\"adversarial\":{adversarial}}},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":1,\"tokens\":{:?},\"runs\":889227,\"primary\":1762795,\"escape_bytes\":742,\"grammar\":{},\"history_checks\":1778454,\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"primary_full16bit_history\":{:?},\"coded_branches\":{coded},\"implicit_prefix1_branches\":{implicit},\"legal_intervals_checked\":{intervals},\"select_endpoint_checks\":{selects},\"minimum_actual_frequency\":{minimum},\"actual_pool_loss_bits\":{:.17},\"alternate_pool_loss_bits\":{:.17},\"Model_audit_entropy_bits\":{entropy:.17},\"actual_pool_entropy_u64\":{},\"Model_audit_entropy_u64\":{},\"component_pool_loss_bits\":{component_loss:?},\"class_pool_loss_bits\":{class_loss:?},\"primary_terminal_root_best_Q8\":{:?},\"primary_selected_sequential_price_Q8\":{:?},\"primary_selected_sequential_KT_loss_bits\":{:?},\"primary_selected_depth_counts\":{:?},\"primary_observations\":{:?},\"model_prefixes\":{prefixes:?},\"model_rescales\":{rescales:?},\"model_cold\":{cold:?},\"model_base_pool_digest\":\"{digest:016x}\",\"Q_token_bytes_ceil\":{token_bytes},\"side_bytes\":3079,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"primary_node_capacity\":{},\"primary_node_size\":{},\"primary_capacity_bytes\":{primary_bytes},\"price_static_bytes\":{price_bytes},\"TLS_collector_bytes\":{collector_bytes},\"base_Model_source_bound_bytes\":{base_bound},\"tree_source_bound_bytes\":{tree_bound},\"scratch_source_bound_bytes\":{scratch_bound},\"base_private_Vec_capacities_measured\":false,\"model_working_RAM_estimate_bytes\":{model_ram},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":33554432,\"fixed_phase_RAM_limit_bytes\":67108864,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_resource_gate_passed\":{gate},\"TLS_fixed_single_instance_only\":true,\"TLS_diagnostic_overhead\":true,\"model_header_bytes\":0,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"setting_sweeps\":0,\"old_teacher_state_equivalence_required\":false,\"speed_claimed\":false,\"regret_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",meta.tokens,meta.grammar,meta.branches,meta.classes,meta.prefixes,meta.final_history,primary.history,loss.value,alternate.value,loss.value.to_bits(),entropy.to_bits(),primary.root_best_Q8,primary.selected_price_Q8,primary.selected_KT_loss_bits,primary.selected_depth_counts,primary.observations,screen<=483599,primary.node_capacity,primary.node_size);Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("causal-hard-cut: {e}");std::process::exit(1);}}
