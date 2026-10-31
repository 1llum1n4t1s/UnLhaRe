//! 固定14tileのshort leaf実費DP情報費用診断。実frame/速度ではない。
#![allow(dead_code, unused_imports)]
#[path = "../causal-bayes-sais/bwt.rs"] mod bwt;
#[path = "../static-direct-mdl/frontend.rs"] mod frontend;
#[path = "../static-direct-mdl/histogram.rs"] mod histogram;
#[path = "../branch-history-mdl/model.rs"] mod model;
#[path = "../packed-inverse/reference.rs"] mod reference;
#[path = "../packed-inverse/contract.rs"] mod contract;
#[path = "../packed-inverse/memory.rs"] mod memory;
#[path = "../node-history-information/counts.rs"] mod counts;
#[path="../temporal-node-information/grammar.rs"] mod grammar;
#[path="tile_accumulator.rs"] mod tiles;
mod paid_model;
mod packet;
mod e2e;
use std::{fs::File, io::Read};
type Result<T> = std::result::Result<T, String>;
fn fixed(meta: &grammar::Meta) -> Result<()> {
    if meta.tokens != [889227,889227] || meta.runs != 889227 || meta.escapes != 742
        || meta.history_checks != 1778454 || meta.grammar != 0x58735a2b7383d755
        || meta.branches != [2725772,1099568]
        || meta.classes != [889227,620240,1216305,889227,64372,145969] {
        return Err("fixed branch/class/history totals".into());
    }
    // prefixes/final_historyを含む全Metaの原raw report照合は親runnerで行う。
    Ok(())
}
fn print_stat(s: tiles::Stat) {
    print!("{{\"count\":{},\"active_rows\":{},\"pure_rows\":{},\"nonzero_cells\":{},\"empirical_bits\":{:.12},\"Q_bits\":{:.12}}}",
        s.count,s.active,s.pure,s.cells,s.empirical.sum,s.quantized.sum);
}
fn private_peak(memory_json: &str) -> Result<usize> {
    let rest=memory_json.split("\"peak_private_commit_bytes\":").nth(1).ok_or("private peak missing")?;
    let number=rest.split([',','}']).next().ok_or("private peak extent")?;
    number.parse().map_err(|_|"private peak unavailable".into())
}
fn execute() -> Result<()> {
    let args: Vec<_>=std::env::args().collect();
    if args.len()!=3 || args[1]!="screen" { return Err("usage: screen fixed-input".into()); }
    memory::validate_layout()?;
    let e2e=e2e::run()?;
    let nodes=[grammar::Tree::new(257).node_count(),grammar::Tree::new(256).node_count()];
    if nodes!=[counts::NODE_COUNT;2] { return Err("native Tree node counts".into()); }
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;
    if file.metadata().map_err(|e|e.to_string())?.len()!=2811006 { return Err("fixed length".into()); }
    let mut plain=Vec::new();
    plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;
    file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;
    if plain.len()!=2811006 { return Err("fixed input grew".into()); }
    let front=frontend::Front::new(&plain)?;
    if front.runs.len()!=889227 || front.primary!=1762795 || front.last_len!=2811007
        || front.runs.capacity()>1048576 { return Err("fixed Front/capacity".into()); }
    let mut a=tiles::Accumulator::new(front.runs.len())?;
    let meta=grammar::walk(&front,|c,node,class,k,h,child,run| {
        a.record(c,node,class,k,h,child,run,&mut |_,_,_|Ok(()))
    })?;
    fixed(&meta)?;
    a.finish(&mut |_,_,_|Ok(()))?;
    if a.coded!=3825218 || a.implicit!=122 || a.coded+a.implicit!=3825340
        || a.flushes!=14 || a.scans!=12214272 || meta.final_history!=a.history {
        return Err("fixed tile/event/history census".into());
    }
    let mut reconstructed=tiles::Summary::default();
    for t in 0..tiles::TILES {
        let summary=&a.tiles[t]; summary.validate()?;
        for c in 0..2 {
            reconstructed.components[c].merge(summary.components[c])?;
            reconstructed.implicit[c]+=summary.implicit[c];
            for n in 0..counts::NODE_COUNT { reconstructed.nodes[c][n].merge(summary.nodes[c][n])?; }
        }
        reconstructed.whole.merge(summary.whole)?;
    }
    reconstructed.validate()?;
    if !tiles::same(reconstructed.whole,a.whole.whole) || reconstructed.implicit!=a.whole.implicit {
        return Err("tile/whole summary census".into());
    }
    for c in 0..2 {
        if !tiles::same(reconstructed.components[c],a.whole.components[c])
            || a.whole.components[c].count+a.whole.implicit[c]!=meta.branches[c] {
            return Err("tile/component/Meta census".into());
        }
        for n in 0..counts::NODE_COUNT {
            if !tiles::same(reconstructed.nodes[c][n],a.whole.nodes[c][n]) { return Err("tile/node census".into()); }
        }
    }
    let dense_capacity=a.dense.rows.capacity();
    let dense_bytes=a.dense.capacity_bytes();
    let scratch_peak=a.paid.iter().map(|s|s.working_bytes).max().ok_or("paid scratch peak")?;
    let model_working=scratch_peak+(a.capacity_bytes()-dense_bytes)+std::mem::size_of::<tiles::Summary>()+4*1024*1024;
    let run_capacity=front.runs.capacity(); let input_capacity=plain.capacity();
    let phase=run_capacity*12+input_capacity+model_working+1369112+4*1024*1024;
    if dense_capacity!=counts::ROWS || dense_bytes!=13959192 || model_working>24*1024*1024
        || phase>48*1024*1024 { return Err("dense/model/phase capacity RAM".into()); }
    let empirical_total=a.whole.whole.empirical.sum; let q_total=a.whole.whole.quantized.sum;
    if !empirical_total.is_finite() || !q_total.is_finite() { return Err("final loss finite".into()); }
    let ideal_bytes=(empirical_total/8.0).ceil() as u64;
    let q_bytes=(q_total/8.0).ceil() as u64;
    let ideal_screen=ideal_bytes.checked_add(3079).ok_or("empirical screen overflow")?;
    let q_screen=q_bytes.checked_add(3079).ok_or("Q screen overflow")?;
    // report用の固定配列を移し、Dense/Front/inputを解放してからprocess peakを読む。
    let bounded_summary_bytes=a.capacity_bytes()-dense_bytes;
    if a.tiles.len()!=tiles::TILES || a.tiles.capacity()!=tiles::TILES{return Err("fixed tile summary capacity".into());}
    let mut paid_loss=tiles::Loss::default();let mut paid_dp=tiles::Loss::default();
    let mut paid_components=[tiles::Loss::default();2];let mut paid_component_dp=[tiles::Loss::default();2];
    let mut paid_count=[0u64;2];let mut headers=0usize;let mut header_bits=0usize;let mut padding_bits=0usize;
    let mut defaults=0usize;let mut explicit=0usize;let mut cdf_checks=0usize;let mut root_bits_checked=0usize;
    let mut models=0usize;let mut roots=0usize;
    let mut internal_bits=0usize;let mut modes=[0usize;3];
    if a.paid.len()!=14 || a.paid.capacity()!=14{return Err("paid stats bounded 14".into());}
    for s in &a.paid{
        paid_loss.add(s.parsed_loss)?;paid_dp.add(s.dp_loss)?;
        headers+=s.header_bytes;header_bits+=s.header_bits;padding_bits+=s.padding_bits;
        defaults+=s.defaults;explicit+=s.explicit;cdf_checks+=s.cdf_checks;root_bits_checked+=s.concatenated_bits_checked;
        models+=s.models;roots+=s.roots;
        if s.dp_internal_bits+s.roots!=s.header_bits{return Err("tile actual DP bits/header".into());}
        internal_bits+=s.dp_internal_bits;modes[0]+=s.uniform_leaves;modes[1]+=s.pure_leaves;modes[2]+=s.raw_leaves;
        for c in 0..2{paid_count[c]+=s.components[c];paid_components[c].add(s.component_parsed[c])?;paid_component_dp[c].add(s.component_dp[c])?;}
    }
    for c in 0..2{if paid_count[c]!=a.whole.components[c].count || !tiles::close(paid_components[c].sum,paid_component_dp[c].sum){return Err("whole paid component/count/DP".into());}}
    if models!=3976 || roots!=11928 || cdf_checks!=12214272 || defaults+explicit!=roots || !tiles::close(paid_loss.sum,paid_dp.sum){return Err("whole paid census/DP loss".into());}
    if internal_bits+roots!=header_bits{return Err("whole DP internal bits plus flags/header".into());}
    let paid_token_bytes=(paid_loss.sum/8.0).ceil() as u64;
    let paid_delta=i64::try_from(paid_token_bytes).map_err(|_|"paid signed token range")?-449308i64;
    let delta_plus_header=paid_delta+i64::try_from(headers).map_err(|_|"paid signed header range")?;
    let paid_screen=paid_token_bytes.checked_add(headers as u64).and_then(|x|x.checked_add(3079)).ok_or("paid screen overflow")?;
    let paid_condition=delta_plus_header<=31212 && paid_screen<=483599;
    let paid_stats=std::mem::take(&mut a.paid);
    let tile_summaries=std::mem::take(&mut a.tiles); let whole=a.whole; let coded=a.coded; let implicit=a.implicit;
    drop(a); drop(front); drop(plain);
    let (memory_json,ws_gate)=memory::read_once()?;
    let private=private_peak(&memory_json)?;
    let private_gate=private<=160*1024*1024;
    let peak_gate=ws_gate==Some(true) && private_gate;
    print!("{{\"status\":\"passed\",\"kind\":\"temporal_short_leaf_information_only\",\"E2E\":{e2e},\"Tree_node_counts\":{nodes:?},\"input_reads\":1,\"BWT_calls\":1,\"fixed_Front_walks\":1,\"tile_width_runs\":65536,\"tile_count\":14,\"full_tiles\":13,\"tail_runs\":37259,\"width_sweeps\":0,\"tokens\":{:?},\"runs\":{},\"primary\":1762795,\"escape_bytes\":{},\"grammar\":{},\"history_checks_per_walk\":{},\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_last10bit_history\":{:?},\"original_raw_Meta_check_owner\":\"parent_runner\",\"second_walk_event_Q_replay_claimed\":false,\"coded_branches\":{coded},\"implicit_prefix1_branches\":{implicit},\"rows_checked_per_flush\":872448,\"rows_checked\":12214272,\"flushes\":14,\"tiles\":[",
        meta.tokens,meta.runs,meta.escapes,meta.grammar,meta.history_checks,meta.branches,meta.classes,meta.prefixes,meta.final_history);
    for (t,s) in tile_summaries.iter().enumerate() {
        if t!=0 { print!(","); }
        print!("{{\"tile\":{t},\"first_run\":{},\"run_count\":{},\"implicit_component_counts\":{:?},\"maximum_row_total\":{},\"components\":[",
            t*tiles::WIDTH,if t==13 {37259}else{65536},s.implicit,s.maximum_row_total);
        print_stat(s.components[0]); print!(","); print_stat(s.components[1]); print!("],\"whole\":"); print_stat(s.whole); print!("}}");
    }
    print!("],\"component_totals\":["); print_stat(whole.components[0]); print!(","); print_stat(whole.components[1]);
    print!("],\"node_column_schema\":[\"component\",\"node\",\"count\",\"active_rows\",\"pure_rows\",\"nonzero_cells\",\"empirical_bits\",\"Q_bits\"],\"node_totals\":[");
    for c in 0..2 { for n in 0..counts::NODE_COUNT {
        if c!=0 || n!=0 { print!(","); }
        let s=whole.nodes[c][n];
        print!("[{c},{n},{},{},{},{},{:.12},{:.12}]",s.count,s.active,s.pure,s.cells,s.empirical.sum,s.quantized.sum);
    } }
    print!("],\"whole\":"); print_stat(whole.whole);
    print!(",\"paid_tiles\":[");
    for (t,s) in paid_stats.iter().enumerate(){
        if t!=0{print!(",");}
        print!("{{\"tile\":{t},\"models\":{},\"roots\":{},\"default_roots\":{},\"explicit_roots\":{},\"header_bits\":{},\"DP_internal_bits\":{},\"selected_uniform_leaves\":{},\"selected_pure_leaves\":{},\"selected_raw_leaves\":{},\"header_bytes\":{},\"padding_bits\":{},\"count\":{},\"component_counts\":{:?},\"DP_loss_bits\":{:.12},\"parsed_row_loss_bits\":{:.12},\"component_DP_bits\":{:?},\"component_parsed_bits\":{:?},\"Fit_root_all_CDF_comparisons\":{},\"concatenated_root_bits_directly_compared\":{},\"completed_packet_row_checks\":{},\"scratch_capacity_bytes\":{}}}",
            s.models,s.roots,s.defaults,s.explicit,s.header_bits,s.dp_internal_bits,s.uniform_leaves,s.pure_leaves,s.raw_leaves,s.header_bytes,s.padding_bits,s.count,s.components,s.dp_loss,s.parsed_loss,s.component_dp,s.component_parsed,s.cdf_checks,s.concatenated_bits_checked,s.rows,s.working_bytes);
        // tile費用は有効bitsにouter flagを含み、u32長とpaddingを別計上。
    }
    print!("],\"paid_DP_internal_bits\":{internal_bits},\"paid_outer_flag_bits\":{roots},\"paid_DP_bits_plus_flags_verified\":true,\"paid_selected_uniform_leaves\":{},\"paid_selected_pure_leaves\":{},\"paid_selected_raw_leaves\":{}",modes[0],modes[1],modes[2]);
    print!(",\"paid_DP_loss_bits\":{:.12},\"paid_parsed_loss_bits\":{:.12},\"paid_token_bytes_ceil\":{paid_token_bytes},\"paid_token_delta_from_free_Q_bytes\":{paid_delta},\"paid_header_bytes\":{headers},\"paid_header_bits\":{header_bits},\"paid_padding_bits\":{padding_bits},\"paid_delta_plus_header_bytes\":{delta_plus_header},\"paid_delta_plus_header_limit_bytes\":31212,\"free_Q_token_baseline_bytes\":449308,\"free_Q_with_side_baseline_bytes\":452387,\"paid_screen_bytes\":{paid_screen},\"paid_size_condition_passed\":{paid_condition},\"paid_models\":{models},\"paid_roots\":{roots},\"paid_default_roots\":{defaults},\"paid_explicit_roots\":{explicit},\"Fit_root_all_CDF_comparisons\":{cdf_checks},\"concatenated_root_bits_directly_compared\":{root_bits_checked},\"packet_capacity_limit_bytes\":5053003,\"packet_instances_simultaneous\":1,\"node_oracle_array_bytes\":4544,\"packet_files_saved\":0,\"completed_packet_parse_verified\":true,\"paid_model_verified\":true",
        paid_dp.sum,paid_loss.sum);
    println!(",\"empirical_total_loss_bits\":{empirical_total:.12},\"Q_total_loss_bits\":{q_total:.12},\"empirical_token_bytes_ceil\":{ideal_bytes},\"Q_token_bytes_ceil\":{q_bytes},\"model_saved_bytes\":{headers},\"side_bytes\":3079,\"optimistic_empirical_screen_bytes\":{ideal_screen},\"optimistic_Q_screen_bytes\":{q_screen},\"empirical_size_condition_passed\":{},\"Q_size_condition_passed\":{},\"Q_token_condition_bytes\":480520,\"static_free_Q_baseline_bytes\":504637,\"dense_instances_simultaneous\":1,\"dense_row_capacity\":{dense_capacity},\"dense_capacity_bytes\":{dense_bytes},\"bounded_summary_bytes\":{},\"model_working_RAM_estimate_bytes\":{model_working},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":25165824,\"fixed_phase_RAM_limit_bytes\":50331648,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"run_capacity\":{run_capacity},\"input_capacity\":{input_capacity},\"memory\":{memory_json},\"peak_private_commit_gate_passed\":{private_gate},\"peak_resource_gate_passed\":{peak_gate},\"adoption\":false,\"frame_encodes\":0,\"frame_decodes\":0,\"raw_event_Vecs\":0,\"real_size_claimed\":false,\"speed_claimed\":false,\"portable_wire_verified\":false,\"holdout_claimed\":false,\"mathematical_frame_lower_bound_claimed\":false,\"Q_partition_monotonicity_claimed\":false,\"trained_in_sample_only\":true}}",
        ideal_screen<=483599,q_bytes<=480520 && q_screen<=483599,
        bounded_summary_bytes);
    Ok(())
}
fn main() {
    if let Err(error)=execute() { eprintln!("temporal-short-leaf: {error}"); std::process::exit(1); }
}
