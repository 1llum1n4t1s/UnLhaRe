//! class2/5 global minor codebookの実metadata費用screen。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../node-history-information/grammar.rs"] mod grammar;
#[path="../node-history-information/counts.rs"] mod counts;
#[path="../node-history-information/happy.rs"] mod density_happy;
#[path="../node-history-information/adversarial.rs"] mod density_adversarial;
#[path="../branch-history-mdl/model.rs"] mod density_model;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
mod model;
mod bundle;
mod e2e;
use std::{fs::File,io::Read,fmt::Write as _};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)]
struct Sum{value:f64,correction:f64}
impl Sum{fn add(&mut self,x:f64)->Result<()>{if !x.is_finite() || x<0.0{return Err("finite nonnegative loss".into());}let y=x-self.correction;let t=self.value+y;self.correction=(t-self.value)-y;self.value=t;if !t.is_finite(){return Err("finite loss sum".into());}Ok(())}}
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err(format!("loss mismatch {a} {b}"));}Ok(())}
fn fixed(m:&grammar::Meta)->Result<()>{if m.tokens!=[889227;2] || m.runs!=889227 || m.escapes!=742 || m.history_checks!=1778454 || m.grammar!=0x58735a2b7383d755 || m.branches!=[2725772,1099568] || m.classes!=[889227,620240,1216305,889227,64372,145969]{return Err("fixed whole Meta".into());}Ok(())}
#[derive(Clone,Copy,Default)]
struct Node{coded:u64,dp:f64,parsed:Sum,free:Sum,bits:usize,oracle_bits:usize,original:f64,delta:f64}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=6 || args[1]!="screen"{return Err("usage: screen input teacher-nonselected free-rank free-length".into());}memory::validate_layout()?;
    let teacher=args[3].parse::<f64>().map_err(|_|"teacher loss argument")?;let free_reference=[args[4].parse::<f64>().map_err(|_|"free rank")?,args[5].parse::<f64>().map_err(|_|"free length")?];
    if !teacher.is_finite() || teacher<0.0 || free_reference.iter().any(|v|!v.is_finite() || *v<0.0){return Err("reference loss range".into());}
    near(teacher,2286636.8077715)?;model::validate_lut()?;let e2e=e2e::run()?;
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed input length".into());}let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed input grew".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007 || front.runs.capacity()>1048576{return Err("fixed Front capacity".into());}
    let mut tree_classes=[[0usize;142];2];for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});if tree.node_count()!=142{return Err("grammar Tree extent".into());}for node in 0..142{tree_classes[c][node]=tree.class(node)?;}}
    let mut dense=counts::Dense::new()?;let mut train_coded=[0u64;6];let mut train_implicit=0u64;
    let trained=grammar::walk(&front,|c,node,class,k,h,child|{if tree_classes[c][node]+c*3!=class{return Err("training node/class".into());}if k==1{if child!=0{return Err("implicit child".into());}train_implicit+=1;}else{dense.record(c,node,k,h,child)?;train_coded[class]+=1;}Ok(())})?;fixed(&trained)?;
    if train_coded!=[889226,620143,1216282,889226,64372,145969] || train_implicit!=122{return Err("whole coded counts".into());}
    let mut nodes=[[Node::default();142];2];let mut data=bundle::Packet::new()?;
    let mut model_count=0usize;let mut selected_nodes=[0usize;2];let mut sum_model_bits=0usize;let mut oracle_bits=0usize;
    let mut selected_leaves=0usize;let mut selected_splits=0usize;let mut mode_counts=[0usize;3];let mut fit_parse_cdfs=0usize;
    let mut dp=[Sum::default();2];let mut free=[Sum::default();2];let mut original=[Sum::default();2];
    let mut weighted_rows=0usize;let mut weighted_root_comparisons=0usize;
    let mut max_hist=0usize;let mut max_fit=0usize;let mut max_dispatch=0usize;let mut max_packet=0usize;
    for c in 0..2{for node in 0..142{if tree_classes[c][node]!=2{continue;}selected_nodes[c]+=1;model_count+=1;
        let mut hist=model::Hist::new()?;let mut root=[[0u64;4];3];let mut count=0u64;let mut free_loss=Sum::default();
        for k in 2..=4{for h in 0..1024u16{let row=dense.row(c,node,k,h)?;bundle::ingest(&mut hist,k,h,row)?;weighted_rows+=1;let fq=model::quantize(row,k)?;
            for j in 0..4{root[k-2][j]+=u64::from(row[j]);count+=u64::from(row[j]);if row[j]!=0{free_loss.add(f64::from(row[j])*(32768.0/f64::from(fq[j])).log2())?;}}
        }}
        for k in 2..=4{if hist.counts[(k-2)*model::NODES].map(u64::from)!=root[k-2]{return Err("weighted root counts".into());}weighted_root_comparisons+=1;}
        let fit=model::Fit::build(&hist)?;let node_dp=fit.loss_bits();let old_q=fit.original_selected_loss(&hist)?;
        let mut node_bits=0usize;let mut node_oracle=0usize;let mut parsed_rows=Sum::default();
        for k in 2..=4{let(local,bits)=fit.root_wire(k)?;let parsed=model::parse_root(&local,bits,k)?;
            node_bits+=fit.root_objective_bits(k)?;node_oracle+=bits;
            for h in 0..1024u16{let f=parsed.lookup(0,k,h)?;
                if fit.lookup(0,k,h)?!=f{return Err("Fit individual root parse CDF".into());}fit_parse_cdfs+=1;
                let row=dense.row(c,node,k,h)?;for i in 0..k{if row[i]!=0{parsed_rows.add(f64::from(row[i])*(32768.0/f64::from(f[i])).log2())?;}}
            }
            max_dispatch=max_dispatch.max(parsed.capacity_bytes());max_packet=max_packet.max(local.capacity()+std::mem::size_of::<Vec<u8>>());
            drop(parsed);drop(local);data.append_root(&fit,k)?;
        }
        near(parsed_rows.value,node_dp)?;
        max_hist=max_hist.max(hist.capacity_bytes());max_fit=max_fit.max(fit.capacity_bytes());
        let modes=fit.selected_mode_counts()?;for i in 0..3{mode_counts[i]+=modes[i];}
        selected_leaves+=fit.selected_leaf_count();selected_splits+=fit.selected_split_count();
        sum_model_bits+=node_bits;oracle_bits+=node_oracle;
        nodes[c][node]=Node{coded:count,dp:node_dp,parsed:Sum::default(),free:free_loss,bits:node_bits,oracle_bits:node_oracle,original:old_q,delta:node_dp-old_q};
        dp[c].add(node_dp)?;free[c].add(free_loss.value)?;original[c].add(old_q)?;
    }}
    if model_count!=278 || selected_nodes!=[139,139] || fit_parse_cdfs!=854016 || weighted_rows!=854016 || weighted_root_comparisons!=834{return Err("global training extents".into());}
    near(free[0].value,free_reference[0])?;near(free[1].value,free_reference[1])?;
    let default_roots=data.defaults;let root_bits_checked=data.checked_bits;let header_bits=data.bits;
    if data.roots!=834 || data.objective_bits!=sum_model_bits || header_bits!=sum_model_bits+834
        || oracle_bits!=sum_model_bits+3*default_roots{return Err("global DP/oracle/outer flag expenses".into());}
    let data=data.finish()?;let padding_bits=(8-header_bits%8)%8;
    if data.len()*8!=32+header_bits+padding_bits{return Err("global actual bytes/padding/u32".into());}
    let forest=bundle::Forest::parse(&data)?;
    // 完成Forestと同Denseから再構築した選択Fitを直接比較。巨大Fit forestは保持しない。
    let mut forest_cdfs=0usize;let mut verification_weighted_rows=0usize;let mut verification_fit_builds=0usize;
    for c in 0..2{for node in 0..142{if tree_classes[c][node]!=2{continue;}
        let mut hist=model::Hist::new()?;
        for k in 2..=4{for h in 0..1024u16{bundle::ingest(&mut hist,k,h,dense.row(c,node,k,h)?)?;verification_weighted_rows+=1;}}
        let fit=model::Fit::build(&hist)?;verification_fit_builds+=1;let mut row_loss=Sum::default();let mut row_count=0u64;
        for k in 2..=4{for h in 0..1024u16{let f=forest.lookup(c,node,k,h)?;
            if fit.lookup(0,k,h)?!=f{return Err("completed Forest/selected Fit direct CDF".into());}forest_cdfs+=1;
            let row=dense.row(c,node,k,h)?;for i in 0..k{row_count+=u64::from(row[i]);if row[i]!=0{row_loss.add(f64::from(row[i])*(32768.0/f64::from(f[i])).log2())?;}}
        }}
        if row_count!=nodes[c][node].coded{return Err("completed Forest/Dense node count".into());}
        near(row_loss.value,nodes[c][node].dp)?;near(fit.loss_bits(),nodes[c][node].dp)?;
        near(fit.original_selected_loss(&hist)?,nodes[c][node].original)?;
        max_hist=max_hist.max(hist.capacity_bytes());max_fit=max_fit.max(fit.capacity_bytes());
    }}
    if forest_cdfs!=854016 || verification_weighted_rows!=854016 || verification_fit_builds!=278 || model_count+verification_fit_builds!=556{return Err("global verification work census".into());}
    let mut component=[Sum::default();2];let mut class_loss=[Sum::default();6];let mut selected_coded=[0u64;2];let mut whole_coded=0u64;let mut implicit=0u64;let mut minimum=u16::MAX;
    let replay=grammar::walk(&front,|c,node,class,k,h,child|{if k==1{implicit+=1;return Ok(());}whole_coded+=1;if class!=2 && class!=5{return Ok(());}let f=forest.lookup(c,node,k,h)?;if child>=k || f[..k].iter().any(|&v|v<2) || f[k..].iter().any(|&v|v!=0) || f[..k].iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("Forest actual CDF".into());}
        let loss=(32768.0/f64::from(f[child])).log2();nodes[c][node].parsed.add(loss)?;component[c].add(loss)?;class_loss[class].add(loss)?;selected_coded[c]+=1;minimum=minimum.min(f[child]);Ok(())})?;fixed(&replay)?;
    if trained!=replay || whole_coded!=3825218 || implicit!=122 || selected_coded!=[1216282,145969]{return Err("replay selected/whole count Meta".into());}
    let mut node_report=String::new();node_report.try_reserve_exact(36000).map_err(|_|"node report allocation")?;node_report.push('[');
    let mut component_delta=[0.0;2];
    for c in 0..2{near(component[c].value,dp[c].value)?;near(class_loss[c*3+2].value,component[c].value)?;
        let mut count=0u64;let mut sum_dp=Sum::default();let mut sum_replay=Sum::default();let mut sum_free=Sum::default();let mut sum_original=Sum::default();
        if c!=0{node_report.push(',');}node_report.push('[');
        for node in 0..142{let n=nodes[c][node];near(n.dp,n.parsed.value)?;near(n.dp-n.original,n.delta)?;
            count+=n.coded;sum_dp.add(n.dp)?;sum_replay.add(n.parsed.value)?;sum_free.add(n.free.value)?;sum_original.add(n.original)?;component_delta[c]+=n.delta;
            if node!=0{node_report.push(',');}
            let row=format!("[{}, {}, {}, {:.12}, {:.12}, {:.12}, {:.12}, {:.12}]",n.coded,n.bits,n.oracle_bits,n.dp,n.parsed.value,n.free.value,n.original,n.delta);
            if row.len()>160 || node_report.len()+row.len()+8>36000{return Err("node report preappend bound".into());}node_report.push_str(&row);
        }
        node_report.push(']');if count!=selected_coded[c]{return Err("node component counts".into());}
        near(sum_dp.value,dp[c].value)?;near(sum_replay.value,component[c].value)?;near(sum_free.value,free[c].value)?;
        near(sum_original.value,original[c].value)?;near(component_delta[c],dp[c].value-original[c].value)?;
    }
    node_report.push(']');if node_report.len()>36000 || node_report.capacity()>36000{return Err("node report bound".into());}
    let selected_loss=component[0].value+component[1].value;let selected_dp=dp[0].value+dp[1].value;near(selected_loss,selected_dp)?;
    let same_tree_original=original[0].value+original[1].value;let approximation_delta=selected_dp-same_tree_original;
    near(component_delta.iter().sum(),approximation_delta)?;
    let combined=teacher+selected_loss;let token_bytes=(combined/8.0).ceil() as u64;let bundle_bytes=data.len();
    let screen=token_bytes.checked_add(bundle_bytes as u64).and_then(|v|v.checked_add(3079)).ok_or("screen overflow")?;
    let scratch=std::mem::size_of_val(&nodes)+std::mem::size_of_val(&tree_classes)+node_report.capacity()+4096;
    let dense_bytes=dense.capacity_bytes();let forest_bytes=forest.capacity_bytes();let bundle_capacity=data.capacity()+std::mem::size_of::<Vec<u8>>();
    let model_ram=dense_bytes+forest_bytes+max_hist+max_fit+max_dispatch+max_packet+bundle_capacity+scratch+4194304+512;
    let phase=front.runs.capacity()*12+plain.capacity()+model_ram+1369112+4194304;
    if scratch>65536 || model_ram>33554432 || phase>67108864 || model::Fit::node_size()>32 || data.capacity()>bundle::MAX_BUNDLE_BYTES{return Err("global model/phase actual capacity".into());}
    let run_capacity=front.runs.capacity();let input_capacity=plain.capacity();
    drop(forest);drop(data);drop(dense);drop(front);drop(plain);
    let(memory,peak)=memory::read_once()?;let private=memory.split("\"peak_private_commit_bytes\":").nth(1).ok_or("private peak missing")?.split([',','}']).next().ok_or("private peak extent")?.parse::<usize>().map_err(|_|"private peak unavailable")?;
    let private_gate=private<=167772160;let peak_gate=peak==Some(true) && private_gate;
    let total_fit_builds=model_count+verification_fit_builds;
    println!("{{\"status\":\"passed\",\"kind\":\"global_minor_codebook_cost_screen_only\",\"E2E\":{e2e},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":2,\"tokens\":{:?},\"runs\":889227,\"primary\":1762795,\"escape_bytes\":742,\"grammar\":{},\"history_checks_per_walk\":1778454,\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"whole_two_walk_Meta_equal\":true,\"coded_branches\":{whole_coded},\"implicit_prefix1_branches\":{implicit},\"selected_mask\":[2,5],\"selected_node_counts\":{selected_nodes:?},\"selected_coded_counts\":{selected_coded:?},\"minimum_actual_frequency\":{minimum},\"weighted_rows\":{weighted_rows},\"verification_weighted_rows\":{verification_weighted_rows},\"weighted_root_comparisons\":{weighted_root_comparisons},\"Fit_individual_parse_CDF_comparisons\":{fit_parse_cdfs},\"completed_Forest_Fit_CDF_comparisons\":{forest_cdfs},\"model_count\":{model_count},\"distinct_models\":{model_count},\"verification_Fit_builds\":{verification_fit_builds},\"total_Fit_builds\":{total_fit_builds},\"global_root_count\":834,\"global_default_roots\":{default_roots},\"global_explicit_roots\":{},\"bundle_bytes\":{bundle_bytes},\"global_DP_internal_bits\":{sum_model_bits},\"root_outer_flag_bits\":834,\"header_effective_bits\":{header_bits},\"sum_oracle_wire_bits\":{oracle_bits},\"global_padding_bits\":{padding_bits},\"length_field_bytes\":4,\"concatenated_root_bits_directly_compared\":{root_bits_checked},\"selected_leaves\":{selected_leaves},\"selected_splits\":{selected_splits},\"selected_uniform_leaves\":{},\"selected_pure_leaves\":{},\"selected_compact_leaves\":{},\"node_columns\":[\"coded\",\"objective_bits\",\"oracle_wire_bits\",\"DP_bits\",\"parsed_bits\",\"free_bits\",\"original_Q_same_selected_tree_bits\",\"approx_delta_bits\"],\"nodes\":{node_report},\"node_report_utf8_bytes\":{},\"DP_component_loss_bits\":{:?},\"parsed_component_loss_bits\":{:?},\"parsed_class_loss_bits\":{:?},\"free_component_loss_bits\":{:?},\"same_selected_tree_original_Q_component_loss_bits\":{:?},\"approx_component_loss_delta_bits\":{component_delta:?},\"same_selected_tree_original_Q_loss_bits\":{same_tree_original:.17},\"approx_selected_loss_delta_bits\":{approximation_delta:.17},\"DP_selected_loss_bits\":{selected_dp:.17},\"parsed_selected_loss_bits\":{selected_loss:.17},\"teacher_nonselected_loss_bits\":{teacher:.17},\"combined_loss_bits\":{combined:.17},\"Q_token_bytes_ceil\":{token_bytes},\"side_bytes\":3079,\"screen_bytes\":{screen},\"necessary_size_condition_passed\":{},\"dense_capacity_bytes\":{dense_bytes},\"Forest_capacity_bytes\":{forest_bytes},\"max_Hist_capacity_bytes\":{max_hist},\"max_Fit_capacity_bytes\":{max_fit},\"max_Dispatch_capacity_bytes\":{max_dispatch},\"max_packet_capacity_bytes\":{max_packet},\"bundle_capacity_bytes\":{bundle_capacity},\"scratch_capacity_bytes\":{scratch},\"LUT_bytes\":512,\"model_working_RAM_estimate_bytes\":{model_ram},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":33554432,\"fixed_phase_RAM_limit_bytes\":67108864,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"fit_node_size\":{},\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory},\"peak_private_commit_gate_passed\":{private_gate},\"peak_resource_gate_passed\":{peak_gate},\"Dense_instances_simultaneous\":1,\"Forest_instances_simultaneous\":1,\"packet_instances_simultaneous\":1,\"node_scratch_instances_simultaneous\":1,\"packet_files_saved\":0,\"teacher_models_executed\":0,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"parameter_sweeps\":0,\"trained_in_sample_only\":true,\"teacher_state_preservation_verified\":false,\"speed_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",
        trained.tokens,trained.grammar,trained.branches,trained.classes,trained.prefixes,trained.final_history,834-default_roots,
        mode_counts[0],mode_counts[1],mode_counts[2],node_report.len(),dp.map(|v|v.value),component.map(|v|v.value),class_loss.map(|v|v.value),free.map(|v|v.value),original.map(|v|v.value),screen<=483599,model::Fit::node_size());Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("global-minor-codebook: {e}");std::process::exit(1);}}

