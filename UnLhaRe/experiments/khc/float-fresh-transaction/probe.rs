//! FT1一候補。fresh拒否→standalone E2E→同process全同値→固定ABBA一周。
#![allow(dead_code)]
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_cts.rs"] mod float_cts;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../lookup-float-cts/float_scope.rs"] mod reference;
#[path="float_cts.rs"] mod fresh_cts;
#[path="float_pool.rs"] mod fresh_pool;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
#[path="../lookup-float-profile/proof.rs"] mod proof;
mod fresh_scope;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
fn equal(a:&[u8],b:&[u8],label:&str)->Result<usize>{
    if a.len()!=b.len(){return Err(format!("{label} length {} != {}",a.len(),b.len()));}
    for(i,(&x,&y)) in a.iter().zip(b).enumerate(){if x!=y{return Err(format!("{label} first different byte {i}: {x} != {y}"));}}Ok(a.len())
}
fn typed_equal(a:&proof::Proof14,b:&proof::Proof14)->Result<()>{if a!=b{return Err(format!("typed Proof14 differs {a:?} != {b:?}"));}Ok(())}
fn read_fixed(path:&Path)->Result<Vec<u8>>{
    let f=File::open(path).map_err(|e|format!("fixed open {e}"))?;let meta=f.metadata().map_err(|e|e.to_string())?;
    if !meta.is_file()||meta.len()!=2811006{return Err("fixed input shape".into());}
    let mut bytes=Vec::new();bytes.try_reserve_exact(2811006).map_err(|_|"input allocation")?;
    f.take(2811007).read_to_end(&mut bytes).map_err(|e|e.to_string())?;
    if bytes.len()!=2811006{return Err("fixed input length changed".into());}Ok(bytes)
}
fn selfcheck()->Result<String>{
    let fresh=fresh_scope::codec::fresh_rejection_checks()?;
    let standalone=fresh_scope::codec::run_selfcheck_report()?;
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"selfcheck\",\"fresh_rejections\":{fresh},\"standalone\":{standalone},\"new_normal_path\":\"exclusive Model::transaction\",\"checked_split_scope\":\"26 auxiliary standalone rejection comparisons only\"}}"))
}
fn compare_case(case:&str,bytes:&[u8],fixed:bool)->Result<String>{
    let re=reference::codec::run_profile(bytes,5)?;
    let rd=reference::codec::run_restore(&re.frame)?;
    let ne=fresh_scope::codec::run_profile(bytes,5)?;
    let nd=fresh_scope::codec::run_restore(&re.frame)?;
    let rp=proof::Proof14::frozen_debug(&format!("{:?}",re.proof))?;
    typed_equal(&rp,&proof::Proof14::frozen_debug(&format!("{:?}",rd.proof))?)?;
    typed_equal(&rp,&ne.proof.projection())?;typed_equal(&rp,&nd.proof.projection())?;
    equal(&re.frame,&ne.frame,"whole reference/fresh frame")?;
    equal(bytes,&rd.plain,"reference direct plain")?;equal(bytes,&nd.plain,"fresh direct plain")?;equal(&rd.plain,&nd.plain,"both decoders plain")?;
    if re.stats!=rd.stats||re.stats!=ne.stats||re.stats!=nd.stats{return Err("all stats mismatch".into());}
    if fixed{
        re.proof.validate_fixed(5)?;rd.proof.validate_fixed(5)?;ne.proof.validate_fixed(5)?;nd.proof.validate_fixed(5)?;
        if re.frame.len()!=478750||ne.frame.len()>483599{return Err("fixed size gate".into());}
    }
    Ok(format!("{{\"case\":\"{case}\",\"input_bytes\":{},\"frame_bytes\":{},\"complete_frame_compared\":true,\"direct_plain_comparisons\":3,\"typed_Proof14_comparisons\":3,\"full_stats_comparisons\":3,\"cdf_bits_compared\":true,\"proof\":{},\"stats\":{},\"reference_encode_ns\":{},\"reference_decode_ns\":{},\"fresh_encode_ns\":{},\"fresh_decode_ns\":{}}}",bytes.len(),re.frame.len(),rp.json(),re.stats,re.elapsed_ns,rd.elapsed_ns,ne.elapsed_ns,nd.elapsed_ns))
}
fn screen(bytes:&[u8])->Result<String>{
    let mut cases=Vec::new();
    for(name,small)in[("empty",Vec::new()),("small-1",vec![255]),("small-all256",(0..1024).map(|i|(i%256)as u8).collect()),("small-text",b"lookup f64 fresh E2E\n".repeat(32))]{cases.push(compare_case(name,&small,false)?);}
    cases.push(compare_case("fixed-all-group",bytes,true)?);
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"size-and-equivalence-screen\",\"cases\":5,\"size_gate_limit_bytes\":483599,\"size_gate_passed\":true,\"fixed_frame_bytes\":478750,\"typed_proof_projection\":\"strict frozen Debug all 14 typed fields, fresh direct accessor\",\"records\":[{}],\"disk_frames_plain_inputs\":0}}",cases.join(",")))
}
fn abba(bytes:&[u8])->Result<String>{
    let mut saved:[Option<(Vec<u8>,proof::Proof14,String)>;2]=[None,None];
    let mut encode=[0u64;2];let mut decode=[0u64;2];let mut records=Vec::new();
    for(index,is_fresh)in[false,true,true,false].into_iter().enumerate(){
        let (frame,stats,project,encode_ns,decode_ns)=if is_fresh{
            let e=fresh_scope::codec::run_profile(bytes,5)?;let d=fresh_scope::codec::run_restore(&e.frame)?;
            equal(bytes,&d.plain,"ABBA fresh full plain")?;typed_equal(&e.proof.projection(),&d.proof.projection())?;
            if e.stats!=d.stats{return Err("ABBA fresh all stats".into());}e.proof.validate_fixed(5)?;d.proof.validate_fixed(5)?;
            (e.frame,e.stats,e.proof.projection(),e.elapsed_ns,d.elapsed_ns)
        }else{
            let e=reference::codec::run_profile(bytes,5)?;let d=reference::codec::run_restore(&e.frame)?;
            equal(bytes,&d.plain,"ABBA reference full plain")?;
            let p=proof::Proof14::frozen_debug(&format!("{:?}",e.proof))?;typed_equal(&p,&proof::Proof14::frozen_debug(&format!("{:?}",d.proof))?)?;
            if e.stats!=d.stats{return Err("ABBA reference all stats".into());}e.proof.validate_fixed(5)?;d.proof.validate_fixed(5)?;
            (e.frame,e.stats,p,e.elapsed_ns,d.elapsed_ns)
        };
        if frame.len()!=478750||frame.len()>483599{return Err("ABBA frame size".into());}
        let direction=usize::from(is_fresh);
        if let Some((previous,p,s))=&saved[direction]{equal(previous,&frame,"ABBA repeat all frame")?;typed_equal(p,&project)?;if s!=&stats{return Err("ABBA repeat stats".into());}}
        let opposite=1-direction;if let Some((previous,p,s))=&saved[opposite]{equal(previous,&frame,"ABBA cross-method all frame")?;typed_equal(p,&project)?;if s!=&stats{return Err("ABBA cross-method stats".into());}}
        encode[direction]=encode[direction].checked_add(encode_ns).ok_or("encode timer sum")?;
        decode[direction]=decode[direction].checked_add(decode_ns).ok_or("decode timer sum")?;
        let method=if is_fresh{"fresh"}else{"reference"};
        records.push(format!("{{\"index\":{index},\"method\":\"{method}\",\"frame_bytes\":{},\"encode_ns\":{encode_ns},\"decode_ns\":{decode_ns},\"direct_plain_bytes\":{},\"typed_proof\":{},\"stats\":{stats}}}",frame.len(),bytes.len(),project.json()));
        if saved[direction].is_none(){saved[direction]=Some((frame,project,stats));}
    }
    let shorter=encode[1]<encode[0]&&decode[1]<decode[0];
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"ABBA\",\"order\":[\"reference\",\"fresh\",\"fresh\",\"reference\"],\"records\":[{}],\"reference_encode_sum_ns\":{},\"fresh_encode_sum_ns\":{},\"reference_decode_sum_ns\":{},\"fresh_decode_sum_ns\":{},\"both_directions_shorter\":{shorter},\"private_candidate_retained\":{shorter},\"warmup_runs\":0,\"ABBA_cycles\":1,\"diagnostic_only\":true,\"formal_performance\":false,\"profile_clocks_used\":false,\"disk_frames_plain_inputs\":0}}",records.join(","),encode[0],encode[1],decode[0],decode[1]))
}
fn run()->Result<String>{
    let args=std::env::args_os().collect::<Vec<_>>();match args.get(1).and_then(|a|a.to_str()){
        Some("selfcheck")if args.len()==2=>selfcheck(),
        Some("screen")if args.len()==3=>screen(&read_fixed(Path::new(&args[2]))?),
        Some("abba")if args.len()==3=>abba(&read_fixed(Path::new(&args[2]))?),
        _=>Err("usage: float-fresh selfcheck|screen INPUT|abba INPUT".into()),
    }
}
fn main(){match run(){Ok(json)=>{if json.len()>65535{eprintln!("CLI stdout bound");std::process::exit(2);}println!("{json}");if let Err(e)=std::io::stdout().flush(){eprintln!("flush: {e}");std::process::exit(1);}},Err(e)=>{eprintln!("rejected: {e}");std::process::exit(1);}}}
