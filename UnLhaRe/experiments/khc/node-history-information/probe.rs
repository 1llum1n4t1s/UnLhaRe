//! 保存分布を無料にするnode/history in-sample情報診断。実frame/速度ではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../branch-history-mdl/model.rs"] mod model;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
mod grammar;
mod counts;
mod happy;
mod adversarial;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)]
struct Kahan {sum:f64,correction:f64}
impl Kahan {fn add(&mut self,value:f64)->Result<()>{if !value.is_finite() || value<0.0{return Err("information loss finite/range".into());}let y=value-self.correction;let sum=self.sum+y;self.correction=(sum-self.sum)-y;self.sum=sum;if !sum.is_finite(){return Err("information total finite".into());}Ok(())}}
fn fixed(meta:&grammar::Meta)->Result<()>{if meta.tokens!=[889227,889227] || meta.runs!=889227 || meta.escapes!=742 || meta.history_checks!=1778454 || meta.grammar!=0x58735a2b7383d755 || meta.branches!=[2725772,1099568] || meta.classes!=[889227,620240,1216305,889227,64372,145969]{return Err("frozen branch/class/history totals".into());}Ok(())}
fn frequency(row:[u32;4],k:usize)->Result<[u16;4]>{let q=model::quantize(row,k)?;if q[..k].iter().any(|&v|v<2) || q[k..].iter().any(|&v|v!=0) || q[..k].iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("frozen Q CDF support/total".into());}Ok(q)}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen fixed-input".into());}memory::validate_layout()?;
    let happy=happy::run()?;let adversarial=adversarial::run()?;
    let nodes=[grammar::Tree::new(257).node_count(),grammar::Tree::new(256).node_count()];if nodes!=[counts::NODE_COUNT;2]{return Err("both native Tree node counts".into());}
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed length".into());}let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed input grew".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("fixed Front/capacity".into());}
    let mut dense=counts::Dense::new()?;let mut coded=0u64;let mut implicit=0u64;
    let trained=grammar::walk(&front,|c,node,class,k,history,child|{if c>=2 || class/3!=c || node>=counts::NODE_COUNT{return Err("callback component/node/class".into());}if k==1{if child!=0{return Err("implicit child".into());}implicit+=1;}else{dense.record(c,node,k,history,child)?;coded+=1;}Ok(())})?;fixed(&trained)?;
    if coded!=3825218 || implicit!=122 || coded+implicit!=3825340 || dense.rows.len()!=counts::ROWS{return Err("trained coded/implicit totals".into());}
    let mut empirical=[Kahan::default();2];let mut quantized=[Kahan::default();2];let mut component_counts=[0u64;2];let mut active=[0usize;2];let mut pure=[0usize;2];let mut cells=[0usize;2];let mut maximum_row_total=0u64;
    for(index,&row)in dense.rows.iter().enumerate(){let c=index/(counts::NODE_COUNT*3*counts::HISTORIES);let k=(index/counts::HISTORIES)%3+2;let total=row.iter().map(|&v|u64::from(v)).sum::<u64>();if total>u64::from(counts::CAP) || row[k..].iter().any(|&v|v!=0){return Err("aggregate row tail/CAP".into());}let q=frequency(row,k)?;maximum_row_total=maximum_row_total.max(total);component_counts[c]=component_counts[c].checked_add(total).ok_or("whole row count overflow")?;
        if total==0{continue;}active[c]+=1;let support=row[..k].iter().filter(|&&v|v!=0).count();pure[c]+=usize::from(support==1);cells[c]+=support;
        for i in 0..k{if row[i]!=0{empirical[c].add(f64::from(row[i])*(total as f64/f64::from(row[i])).log2())?;quantized[c].add(f64::from(row[i])*(32768.0/f64::from(q[i])).log2())?;}}
    }
    if component_counts.iter().sum::<u64>()!=coded{return Err("whole histogram/branch count".into());}
    let mut replay_loss=[Kahan::default();2];let mut replay_coded=0u64;let mut replay_implicit=0u64;let mut minimum_actual_frequency=u16::MAX;
    let replay=grammar::walk(&front,|c,node,class,k,history,child|{if c>=2 || class/3!=c{return Err("replay component/class".into());}if k==1{if child!=0{return Err("replay implicit child".into());}replay_implicit+=1;return Ok(());}let row=dense.row(c,node,k,history)?;if child>=k || row[child]==0{return Err("actual trained row support".into());}let q=frequency(row,k)?;minimum_actual_frequency=minimum_actual_frequency.min(q[child]);replay_loss[c].add((32768.0/f64::from(q[child])).log2())?;replay_coded+=1;Ok(())})?;fixed(&replay)?;
    let ideal=empirical.map(|v|v.sum);let q=quantized.map(|v|v.sum);let replay_q=replay_loss.map(|v|v.sum);let ideal_total=ideal.iter().sum::<f64>();let q_total=q.iter().sum::<f64>();let replay_total=replay_q.iter().sum::<f64>();
    if trained!=replay || replay_coded!=coded || replay_implicit!=implicit || (q_total-replay_total).abs()>1e-6 || (0..2).any(|c|(q[c]-replay_q[c]).abs()>1e-6){return Err("two walks whole Meta/Q loss".into());}
    let dense_capacity=dense.rows.capacity();let dense_bytes=dense.capacity_bytes();let model_working=dense_bytes+4*1024*1024;let phase=front.runs.capacity()*12+plain.capacity()+model_working+1369112+4*1024*1024;
    if dense_capacity!=counts::ROWS || dense_bytes!=13959192 || model_working>24*1024*1024 || phase>48*1024*1024{return Err("dense/phase capacity RAM".into());}
    let ideal_bytes=(ideal_total/8.0).ceil() as u64;let q_bytes=(q_total/8.0).ceil() as u64;let ideal_screen=ideal_bytes.checked_add(3079).ok_or("ideal screen overflow")?;let q_screen=q_bytes.checked_add(3079).ok_or("Q screen overflow")?;let near_boundary=(ideal_screen as f64-483599.0).abs()<=1.0;
    let run_capacity=front.runs.capacity();let input_capacity=plain.capacity();drop(dense);drop(front);drop(plain);let(memory,peak)=memory::read_once()?;let gate=peak.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"node_history_information_optimistic_only\",\"E2E\":{{\"happy\":{happy},\"adversarial\":{adversarial}}},\"Tree_node_counts\":{nodes:?},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":2,\"tokens\":{:?},\"runs\":{},\"primary\":1762795,\"escape_bytes\":{},\"grammar\":{},\"history_checks_per_walk\":{},\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"whole_two_walk_Meta_equal\":true,\"coded_branches\":{coded},\"implicit_prefix1_branches\":{implicit},\"component_row_counts\":{component_counts:?},\"component_active_rows\":{active:?},\"component_pure_rows\":{pure:?},\"component_nonzero_cells\":{cells:?},\"maximum_row_total\":{maximum_row_total},\"rows_checked\":{},\"empirical_component_loss_bits\":{ideal:?},\"empirical_total_loss_bits\":{ideal_total:.12},\"Q_component_loss_bits\":{q:?},\"Q_total_loss_bits\":{q_total:.12},\"second_walk_Q_component_loss_bits\":{replay_q:?},\"second_walk_Q_total_loss_bits\":{replay_total:.12},\"whole_Q_loss_abs_difference_bits\":{:.12},\"minimum_actual_Q_frequency\":{minimum_actual_frequency},\"empirical_token_bytes_ceil\":{ideal_bytes},\"Q_token_bytes_ceil\":{q_bytes},\"model_saved_bytes\":0,\"side_bytes\":3079,\"optimistic_empirical_screen_bytes\":{ideal_screen},\"optimistic_Q_screen_bytes\":{q_screen},\"empirical_size_condition_passed\":{},\"Q_size_condition_passed\":{},\"empirical_gate_within_one_byte\":{near_boundary},\"mathematical_frame_lower_bound_claimed\":false,\"dense_row_capacity\":{dense_capacity},\"dense_capacity_bytes\":{dense_bytes},\"model_working_RAM_estimate_bytes\":{model_working},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":25165824,\"fixed_phase_RAM_limit_bytes\":50331648,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_resource_gate_passed\":{gate},\"adoption\":false,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"real_size_claimed\":false,\"speed_claimed\":false,\"portable_wire_verified\":false,\"holdout_claimed\":false,\"trained_in_sample_only\":true}}",trained.tokens,trained.runs,trained.escapes,trained.grammar,trained.history_checks,trained.branches,trained.classes,trained.prefixes,trained.final_history,counts::ROWS,(q_total-replay_total).abs(),ideal_screen<=483599,q_screen<=483599);Ok(())
}
fn main(){if let Err(error)=execute(){eprintln!("node-history-information: {error}");std::process::exit(1);}}
