//! 新規記述。teacher-free全classの実metadata/CDF費用screen、完成frameではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../node-history-information/grammar.rs"] mod grammar;
#[path="../node-history-information/counts.rs"] mod counts;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../root-history-order/model.rs"] mod model;
#[path="../root-history-order/bundle.rs"] mod bundle;
#[path="../paid-code-tree/model.rs"] mod paid_model;
#[path="../paid-code-tree/codebook.rs"] mod codebook;
mod packet;
mod finite;
mod adversarial;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Default)]
struct Sum{value:f64,correction:f64}
impl Sum{fn add(&mut self,x:f64)->Result<()>{if !x.is_finite() || x<0.0{return Err("loss finite/nonnegative".into());}let y=x-self.correction;let t=self.value+y;self.correction=(t-self.value)-y;self.value=t;if !t.is_finite(){return Err("loss overflow".into());}Ok(())}}
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err(format!("loss {a} != {b}"));}Ok(())}
#[derive(Default)]
pub(crate) struct Stats{
    pub meta:grammar::Meta,pub primary:usize,pub last_len:usize,pub input_bytes:usize,pub coded:[u64;6],pub implicit:u64,
    pub class_models:[usize;6],pub dp:[f64;6],pub parsed:[f64;6],pub replay:[f64;6],pub free:[f64;6],pub original:[f64;6],
    pub internal:[usize;6],pub defaults:usize,pub leaves:usize,pub splits:usize,pub modes:[usize;3],pub high_roots:usize,pub split_roots:usize,
    pub known:usize,pub escapes:usize,pub bits:usize,pub bytes:usize,pub pad:usize,pub checked:usize,pub token_bytes:u64,pub screen:u64,
    pub weighted_rows:usize,pub high_weighted_rows:usize,pub root_counts:usize,pub individual_cdfs:usize,pub forest_cdfs:usize,
    pub verify_rows:usize,pub verify_high_rows:usize,pub training_fits:usize,pub verification_fits:usize,
    pub dense_bytes:usize,pub forest_bytes:usize,pub packet_capacity:usize,pub hist_capacity:usize,pub fit_capacity:usize,pub dispatch_capacity:usize,pub local_capacity:usize,
    pub encoder_capacity:usize,pub decoder_capacity:usize,pub codec_peak:usize,pub scratch:usize,pub model_ram:usize,pub phase_ram:usize,pub input_capacity:usize,pub run_capacity:usize,
    pub forest_parse_dispatch:usize,pub forest_parse_reader:usize,pub forest_parse_transient:usize,
}
fn hist_pair(dense:&counts::Dense,c:usize,node:usize,s:&mut Stats,verify:bool)->Result<(model::Hist,model::Hist)>{
    let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;let mut roots=[[0u64;4];3];
    for k in 2..=4{for h in 0..1024u16{let row=dense.row(c,node,k,h)?;bundle::ingest(&mut low,k,h,row)?;bundle::ingest(&mut high,k,model::reverse_history(h),row)?;
        if verify{s.verify_rows+=1;s.verify_high_rows+=1;}else{s.weighted_rows+=1;s.high_weighted_rows+=1;}
        for i in 0..4{roots[k-2][i]+=u64::from(row[i]);}
    }}
    for k in 2..=4{if low.counts[(k-2)*model::NODES].map(u64::from)!=roots[k-2] || high.counts[(k-2)*model::NODES].map(u64::from)!=roots[k-2]{return Err("weighted all root counts".into());}s.root_counts+=2;}
    s.hist_capacity=s.hist_capacity.max(low.capacity_bytes()+high.capacity_bytes());Ok((low,high))
}
// k1も含む独立history検査。元grammarは全決定後に履歴を更新する。
fn history(histories:&mut[u16;6],class:usize,k:usize,h:u16,child:usize)->Result<()>{
    if class>=6 || !(1..=4).contains(&k) || child>=k || histories[class]!=h{return Err("all branch history/prefix/child".into());}
    histories[class]=((histories[class]<<2)|child as u16)&1023;Ok(())
}
pub(crate) fn evaluate(plain:&[u8],input_capacity:usize,retained:usize,fixed:bool)->Result<Stats>{
    let front=frontend::Front::new(plain)?;let mut s=Stats{primary:front.primary,last_len:front.last_len,input_bytes:plain.len(),input_capacity,run_capacity:front.runs.capacity(),..Stats::default()};
    let mut classes=[[0u8;142];2];for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});if tree.node_count()!=142{return Err("all grammar extent".into());}
        for n in 0..142{let class=tree.class(n)?;if class>2{return Err("all grammar class".into());}classes[c][n]=(c*3+class) as u8;s.class_models[c*3+class]+=1;}}
    if s.class_models!=[1,2,139,1,2,139]{return Err("all model class coverage".into());}
    let mut dense=counts::Dense::new()?;let mut histories=[0u16;6];
    let trained=grammar::walk(&front,|c,n,class,k,h,child|{if classes[c][n] as usize!=class{return Err("all training class identity".into());}history(&mut histories,class,k,h,child)?;
        if k==1{s.implicit+=1;}else{dense.record(c,n,k,h,child)?;s.coded[class]+=1;}Ok(())})?;
    if trained.final_history!=histories || trained.classes.iter().sum::<u64>()!=s.coded.iter().sum::<u64>()+s.implicit{return Err("training all history/count".into());}
    codebook::validate_fixed()?;let encoder=codebook::Encoder::new(codebook::LENGTHS)?;let decoder=codebook::Decoder::new(codebook::LENGTHS)?;
    s.encoder_capacity=encoder.capacity_bytes();s.decoder_capacity=decoder.capacity_bytes();s.codec_peak=s.encoder_capacity+2*s.decoder_capacity+257*std::mem::size_of::<usize>()+256;
    let mut data=packet::Packet::new(&encoder)?;let mut dp=[Sum::default();6];let mut parsed=[Sum::default();6];let mut free=[Sum::default();6];let mut original=[Sum::default();6];
    let mut oracle=0usize;let mut orders=[[[false;3];142];2];
    for c in 0..2{for n in 0..142{let class=classes[c][n] as usize;let(low,high)=hist_pair(&dense,c,n,&mut s,false)?;
        let l=paid_model::Fit::build(&low)?;let r=paid_model::Fit::build_high(&high)?;let fit=paid_model::Selected::new(&l,&r)?;s.training_fits+=2;s.fit_capacity=s.fit_capacity.max(l.capacity_bytes()+r.capacity_bytes());
        dp[class].add(fit.loss_bits()?)?;original[class].add(fit.original_selected_loss(&low,&high)?)?;
        let modes=fit.selected_mode_counts()?;for i in 0..3{s.modes[i]+=modes[i];}s.leaves+=fit.selected_leaf_count()?;s.splits+=fit.selected_split_count()?;
        let(known,escapes)=fit.minor_counts()?;s.known+=known;s.escapes+=escapes;
        for k in 2..=4{let(bytes,bits)=fit.root_wire(k,&encoder)?;let d=paid_model::parse_root(&bytes,bits,k,&decoder)?;
            s.internal[class]+=fit.root_objective_bits(k)?;oracle+=bits;s.high_roots+=usize::from(fit.root_high(k)?);s.split_roots+=usize::from(fit.root_split(k)?);orders[c][n][k-2]=fit.root_high(k)?;
            s.dispatch_capacity=s.dispatch_capacity.max(d.capacity_bytes());s.local_capacity=s.local_capacity.max(bytes.capacity()+std::mem::size_of::<Vec<u8>>());
            for h in 0..1024u16{let f=d.lookup(0,k,h)?;if f!=fit.lookup(0,k,h)?{return Err("all individual Fit/parse CDF".into());}s.individual_cdfs+=1;let row=dense.row(c,n,k,h)?;let q=model::quantize(row,k)?;
                for i in 0..k{if row[i]!=0{parsed[class].add(f64::from(row[i])*(32768.0/f64::from(f[i])).log2())?;free[class].add(f64::from(row[i])*(32768.0/f64::from(q[i])).log2())?;}}
            }
            drop(d);drop(bytes);data.append_root(&fit,k)?;
        }
    }}
    s.defaults=data.defaults;s.bits=data.bits;s.checked=data.checked_bits;
    if data.roots!=852 || data.objective_bits!=s.internal.iter().sum::<usize>() || s.bits!=852+data.objective_bits || oracle!=data.objective_bits+3*s.defaults{return Err("all flag/objective/oracle expenses".into());}
    let data=data.finish()?;s.bytes=data.len();s.pad=(8-s.bits%8)%8;s.packet_capacity=data.capacity()+std::mem::size_of::<Vec<u8>>();
    if s.bytes*8!=134*8+s.bits+s.pad{return Err("all paid bytes/padding".into());}
    let(table,bits,_)=codebook::read_header(&data,packet::MAX_BUNDLE_BITS)?;if table!=codebook::LENGTHS || bits!=s.bits{return Err("all wire table identity".into());}
    let forest=packet::Forest::parse(&data)?;s.forest_bytes=forest.capacity_bytes();s.forest_parse_dispatch=forest.parse_dispatch_peak;s.forest_parse_reader=forest.parse_reader_capacity;s.forest_parse_transient=s.forest_parse_dispatch+s.forest_parse_reader;
    for c in 0..2{for n in 0..142{let(low,high)=hist_pair(&dense,c,n,&mut s,true)?;let l=paid_model::Fit::build(&low)?;let r=paid_model::Fit::build_high(&high)?;let fit=paid_model::Selected::new(&l,&r)?;s.verification_fits+=2;
        s.fit_capacity=s.fit_capacity.max(l.capacity_bytes()+r.capacity_bytes());
        for k in 2..=4{if orders[c][n][k-2]!=fit.root_high(k)?{return Err("all reFit order".into());}for h in 0..1024u16{if forest.lookup(c,n,k,h)?!=fit.lookup(0,k,h)?{return Err("all completed Forest/reFit CDF".into());}s.forest_cdfs+=1;}}
    }}
    let mut replay=[Sum::default();6];let mut coded=[0u64;6];let mut implicit=0u64;let mut histories=[0u16;6];
    let replay_meta=grammar::walk(&front,|c,n,class,k,h,child|{if classes[c][n] as usize!=class{return Err("all replay class identity".into());}history(&mut histories,class,k,h,child)?;
        if k==1{implicit+=1;}else{let f=forest.lookup(c,n,k,h)?;if f[..k].iter().any(|&n|n<2) || f[k..].iter().any(|&n|n!=0) || f.iter().map(|&n|u32::from(n)).sum::<u32>()!=32768{return Err("replay integer CDF support/total/tail".into());}replay[class].add((32768.0/f64::from(f[child])).log2())?;coded[class]+=1;}Ok(())})?;
    if replay_meta!=trained || histories!=trained.final_history || coded!=s.coded || implicit!=s.implicit{return Err("all complete Meta/history/coded equality".into());}
    for class in 0..6{near(dp[class].value,parsed[class].value)?;near(dp[class].value,replay[class].value)?;}
    s.dp=dp.map(|v|v.value);s.parsed=parsed.map(|v|v.value);s.replay=replay.map(|v|v.value);s.free=free.map(|v|v.value);s.original=original.map(|v|v.value);
    if s.weighted_rows!=872448 || s.high_weighted_rows!=872448 || s.verify_rows!=872448 || s.verify_high_rows!=872448 || s.individual_cdfs!=872448 || s.forest_cdfs!=872448 || s.training_fits!=568 || s.verification_fits!=568 || s.root_counts!=3408{return Err("all training/verification census".into());}
    s.token_bytes=(s.replay.iter().sum::<f64>()/8.0).ceil() as u64;s.screen=s.token_bytes.checked_add(s.bytes as u64).and_then(|n|n.checked_add(3079)).ok_or("all screen overflow")?;
    s.dense_bytes=dense.capacity_bytes();s.scratch=std::mem::size_of::<Stats>()+std::mem::size_of_val(&classes)+std::mem::size_of_val(&orders)+retained+8192;
    // Forest parseのreader/table decoderと三root Dispatchを保守的に別加算。個別root Dispatchと同extentでも無料にしない。
    s.model_ram=s.dense_bytes+s.forest_bytes+s.packet_capacity+s.hist_capacity+s.fit_capacity+s.dispatch_capacity+s.local_capacity+s.codec_peak+s.forest_parse_transient+s.scratch+4194304+512;
    s.phase_ram=s.model_ram+s.run_capacity*12+s.input_capacity+1369112+4194304;
    if s.model_ram>33554432 || s.phase_ram>67108864 || s.scratch>65536 || paid_model::Fit::node_size()>32 || data.capacity()>packet::MAX_BUNDLE_BYTES{return Err("all model/phase/scratch capacity".into());}
    if fixed{near(s.dp[2]+s.dp[5],1540684.988783758)?;
        if s.internal[2]+s.internal[5]!=20422 || 834+s.internal[2]+s.internal[5]!=21256 || 134+(21256usize).div_ceil(8)!=2791
            || trained.tokens!=[889227;2] || trained.runs!=889227 || trained.escapes!=742 || trained.history_checks!=1778454 || trained.grammar!=0x58735a2b7383d755
            || trained.branches!=[2725772,1099568] || trained.classes!=[889227,620240,1216305,889227,64372,145969] || s.coded!=[889226,620143,1216282,889226,64372,145969] || s.implicit!=122
            || s.primary!=1762795 || s.last_len!=2811007{return Err("all fixed original Meta/2,5 control".into());}}
    s.meta=trained;
    drop(forest);drop(data);drop(dense);drop(encoder);drop(decoder);drop(front);Ok(s)
}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen input".into());}memory::validate_layout()?;
    let mut finite=finite::run()?;let(adversarial,rejections,recoveries)=adversarial::run()?;
    if finite.pop()!=Some('}'){return Err("finite report extent".into());}finite.push_str(&format!(",\"exact_reasons_verified\":true,\"packet_rejections\":{rejections},\"same_process_recoveries\":{recoveries},\"adversarial_summary_alias\":true}}"));
    if finite.len()>4096 || finite.capacity()>4096{return Err("finite summary capacity".into());}
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed input length".into());}
    let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed input grew".into());}
    let s=evaluate(&plain,plain.capacity(),finite.capacity()+adversarial.capacity()+2*std::mem::size_of::<String>(),true)?;drop(plain);
    let(memory,peak)=memory::read_once()?;let private=memory.split("\"peak_private_commit_bytes\":").nth(1).ok_or("private peak missing")?.split([',','}']).next().ok_or("private peak extent")?.parse::<usize>().map_err(|_|"private peak unavailable")?;
    println!("{{\"status\":\"passed\",\"kind\":\"all_class_static_cost_screen_only\",\"finite_E2E\":{finite},\"adversarial_E2E\":{adversarial},\"fixed_input_reads\":1,\"fixed_BWT_calls\":1,\"fixed_grammar_walks\":2,\"fixed_input_bytes\":{},\"tokens\":{:?},\"runs\":{},\"primary\":{},\"last_len\":{},\"escape_bytes\":{},\"grammar\":{},\"branches\":{:?},\"classes\":{:?},\"class_prefixes\":{:?},\"final_history\":{:?},\"history_checks_per_walk\":{},\"coded_class_counts\":{:?},\"implicit_k1_per_walk\":{},\"whole_Meta_equal\":true,\"k1_history_verified\":true,\"model_count\":284,\"root_count\":852,\"individual_root_parse_calls\":852,\"Forest_parse_calls\":1,\"replay_branch_probability_lookups\":3825218,\"class_model_counts\":{:?},\"training_Fit_builds\":{},\"verification_Fit_builds\":{},\"total_Fit_builds\":{},\"weighted_rows\":{},\"high_weighted_rows\":{},\"verification_weighted_rows\":{},\"verification_high_weighted_rows\":{},\"weighted_root_count_comparisons\":{},\"individual_root_CDF_comparisons\":{},\"completed_Forest_reFit_CDF_comparisons\":{},\"DP_class_loss_bits\":{:?},\"parsed_class_loss_bits\":{:?},\"replay_class_loss_bits\":{:?},\"free_Q_class_loss_bits\":{:?},\"same_selected_tree_Hamilton_class_loss_bits\":{:?},\"class_internal_bits\":{:?},\"root_flag_bits\":852,\"payload_bits\":{},\"metadata_prefix_bytes\":134,\"table_bytes\":129,\"zero_pad_bits\":{},\"packet_bytes\":{},\"concatenated_root_bits_checked\":{},\"default_roots\":{},\"selected_leaves\":{},\"selected_splits\":{},\"leaf_mode_counts\":{:?},\"selected_high_roots\":{},\"selected_split_roots\":{},\"known_minor_count\":{},\"ESC_count\":{},\"integer_wire_CDF_verified\":true,\"codec_dropped_before_report\":true,\"ideal_token_bytes_ceil\":{},\"borrowed_fixed_side_bytes\":3079,\"side_is_borrowed_estimate\":true,\"escape_side_subfield_bytes\":742,\"remaining_borrowed_side_bytes\":2337,\"remaining_side_components\":[\"alphabet\",\"primary\",\"header\",\"terminator\"],\"borrowed_component_sizes_unmeasured\":true,\"actual_complete_frame_bytes\":null,\"screen_bytes\":{},\"stored_payload_input_bytes\":2811006,\"screen_smaller_than_raw_input\":{},\"necessary_size_condition_passed\":{},\"control_class2_5_loss_bits\":{:.17},\"control_class2_5_internal_bits\":20422,\"control_class2_5_flags\":834,\"control_class2_5_packet_bytes\":2791,\"dense_capacity_bytes\":{},\"Forest_capacity_bytes\":{},\"packet_capacity_bytes\":{},\"max_Hist_pair_capacity_bytes\":{},\"max_Fit_pair_capacity_bytes\":{},\"max_Dispatch_capacity_bytes\":{},\"Forest_parse_Dispatch_capacity_bytes\":{},\"Forest_parse_reader_capacity_bytes\":{},\"Forest_parse_transient_capacity_bytes\":{},\"Forest_parse_transient_conservatively_added\":true,\"max_local_wire_capacity_bytes\":{},\"encoder_capacity_bytes\":{},\"decoder_capacity_bytes\":{},\"codec_peak_capacity_bytes\":{},\"scratch_capacity_bytes\":{},\"model_RAM_estimate_bytes\":{},\"phase_RAM_estimate_bytes\":{},\"run_capacity\":{},\"input_capacity\":{},\"memory\":{memory},\"OS_resource_gate_passed\":{},\"teacher_models_executed\":0,\"complete_frame_encodes\":0,\"complete_frame_decodes\":0,\"raw_packet_files_saved\":0,\"speed_claimed\":false,\"adoption\":false}}",
        s.input_bytes,s.meta.tokens,s.meta.runs,s.primary,s.last_len,s.meta.escapes,s.meta.grammar,s.meta.branches,s.meta.classes,s.meta.prefixes,s.meta.final_history,s.meta.history_checks,s.coded,s.implicit,s.class_models,
        s.training_fits,s.verification_fits,s.training_fits+s.verification_fits,s.weighted_rows,s.high_weighted_rows,s.verify_rows,s.verify_high_rows,s.root_counts,s.individual_cdfs,s.forest_cdfs,
        s.dp,s.parsed,s.replay,s.free,s.original,s.internal,s.bits,s.pad,s.bytes,s.checked,s.defaults,s.leaves,s.splits,s.modes,s.high_roots,s.split_roots,s.known,s.escapes,
        s.token_bytes,s.screen,s.screen<2811006,s.screen<=483599,s.dp[2]+s.dp[5],s.dense_bytes,s.forest_bytes,s.packet_capacity,s.hist_capacity,s.fit_capacity,s.dispatch_capacity,s.forest_parse_dispatch,s.forest_parse_reader,s.forest_parse_transient,s.local_capacity,s.encoder_capacity,s.decoder_capacity,s.codec_peak,s.scratch,s.model_ram,s.phase_ram,s.run_capacity,s.input_capacity,peak==Some(true)&&private<=167772160);Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("all-class-static: {e}");std::process::exit(1);}}
