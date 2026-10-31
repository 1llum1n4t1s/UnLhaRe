//! 一構成depth5 RAM screenと合格時だけのold/new/new/old一周。
#![allow(dead_code)]
#[path="float_math.rs"] mod float_math;
#[path="float_cts.rs"] mod float_cts;
#[path="float_pool.rs"] mod float_pool;
#[path="float_scope.rs"] mod float_scope;
#[path="numeric.rs"] mod numeric;
#[path="../quaternary-cts-depth/codec.rs"] mod old_codec;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod new_cts;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded {frame:Vec<u8>,stats:String,proof:old_codec::Proof,elapsed_ns:u64}
pub(crate) struct Decoded {plain:Vec<u8>,stats:String,proof:old_codec::Proof,elapsed_ns:u64}
fn equal(a:&[u8],b:&[u8],scope:&str)->Result<usize>{if a.len()!=b.len(){return Err(format!("{scope} length"));}for(i,(&a,&b))in a.iter().zip(b).enumerate(){if a!=b{return Err(format!("{scope} byte {i}"));}}Ok(a.len())}
fn read(path:&Path)->Result<Vec<u8>>{let f=File::open(path).map_err(|e|e.to_string())?;let m=f.metadata().map_err(|e|e.to_string())?;if !m.is_file()||m.len()!=2811006{return Err("fixed input shape".into());}let mut bytes=Vec::new();bytes.try_reserve_exact(m.len() as usize).map_err(|_|"input allocation")?;f.take(8*1024*1024+1).read_to_end(&mut bytes).map_err(|e|e.to_string())?;if bytes.len()!=2811006{return Err("fixed input grew".into());}Ok(bytes)}
fn new_round(input:&[u8])->Result<float_scope::Encoded>{let e=float_scope::codec::run_profile(input,5)?;e.proof.validate_fixed(5)?;let d=float_scope::codec::run_restore(&e.frame)?;equal(&d.plain,input,"new full plain")?;if e.proof!=d.proof||e.stats!=d.stats{return Err("new Proof14/stats".into());}d.proof.validate_fixed(5)?;Ok(e)}
fn screen(input:&[u8])->Result<()>{
    let e=new_round(input)?;let again=new_round(input)?;let repeated=equal(&e.frame,&again.frame,"screen repeat frame")?;
    if old_codec::run_restore(&e.frame).err().as_deref()!=Some("bad frame magic/header"){return Err("old decoder accepted new magic".into());}
    if e.proof!=again.proof||e.stats!=again.stats{return Err("screen repeat Proof14".into());}
    let gate=e.frame.len()<=483599;
    println!("{{\"status\":\"passed\",\"operation\":\"size-screen\",\"depth\":5,\"frame_bytes\":{},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":{gate},\"encode_calls\":2,\"decode_calls\":2,\"plain_comparisons\":2,\"matched_plain_bytes\":2811006,\"repeated_frame_bytes\":{repeated},\"all_Proof14_compared\":true,\"CDF_entropy_bits_compared\":true,\"stats\":{},\"disk_frames_created\":false,\"disk_restores_created\":false}}",e.frame.len(),e.stats);Ok(())
}
fn abba(input:&[u8])->Result<()>{
    let mut old_frame:Option<Vec<u8>>=None;let mut new_frame:Option<Vec<u8>>=None;let mut old_proof=None;let mut new_proof=None;
    let mut records=Vec::new();let mut enc=[0u64;2];let mut dec=[0u64;2];
    for (index,old) in [true,false,false,true].into_iter().enumerate(){
        let (frame,stats,elapsed_encode,elapsed_decode)=if old{
            let e=old_codec::run_profile(input,5)?;if e.frame.len()!=478750{return Err("old frozen depth5 shape".into());}e.proof.validate_fixed(5)?;
            let d=old_codec::run_restore(&e.frame)?;equal(&d.plain,input,"old full plain")?;d.proof.validate_fixed(5)?;
            if e.proof!=d.proof||e.stats!=d.stats{return Err("old Proof14/stats".into());}
            if let Some(ref previous)=old_frame{equal(&e.frame,previous,"old repeat frame")?;if old_proof.as_ref()!=Some(&e.proof){return Err("old repeat Proof14".into());}}else{old_frame=Some(e.frame.clone());old_proof=Some(e.proof.clone());}
            (e.frame,e.stats,e.elapsed_ns,d.elapsed_ns)
        }else{
            let e=float_scope::codec::run_profile(input,5)?;if e.frame.len()>483599{return Err("new size gate failed".into());}e.proof.validate_fixed(5)?;
            let d=float_scope::codec::run_restore(&e.frame)?;equal(&d.plain,input,"new full plain")?;d.proof.validate_fixed(5)?;
            if e.proof!=d.proof||e.stats!=d.stats{return Err("new Proof14/stats".into());}
            if let Some(ref previous)=new_frame{equal(&e.frame,previous,"new repeat frame")?;if new_proof.as_ref()!=Some(&e.proof){return Err("new repeat Proof14".into());}}else{new_frame=Some(e.frame.clone());new_proof=Some(e.proof.clone());}
            (e.frame,e.stats,e.elapsed_ns,d.elapsed_ns)
        };
        let method=if old{"old"}else{"new"};let j=usize::from(!old);enc[j]=enc[j].checked_add(elapsed_encode).ok_or("timer sum")?;dec[j]=dec[j].checked_add(elapsed_decode).ok_or("timer sum")?;
        records.push(format!("{{\"index\":{index},\"method\":\"{method}\",\"encode_elapsed_ns\":{elapsed_encode},\"decode_elapsed_ns\":{elapsed_decode},\"frame_bytes\":{},\"matched_plain_bytes\":2811006,\"all_Proof14_compared\":true,\"stats\":{stats}}}",frame.len()));
    }
    let faster=enc[1]<enc[0]&&dec[1]<dec[0];
    println!("{{\"status\":\"passed\",\"operation\":\"ABBA\",\"order\":[\"old\",\"new\",\"new\",\"old\"],\"records\":[{}],\"encode_calls\":4,\"decode_calls\":4,\"plain_comparisons\":4,\"repeat_frame_comparisons\":2,\"old_encode_sum_ns\":{},\"new_encode_sum_ns\":{},\"old_decode_sum_ns\":{},\"new_decode_sum_ns\":{},\"both_directions_shorter\":{faster},\"warmup_runs\":0,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"seven_zip_victory_claimed\":false,\"disk_frames_created\":false,\"disk_restores_created\":false}}",records.join(","),enc[0],enc[1],dec[0],dec[1]);Ok(())
}
fn execute()->Result<()>{let args:Vec<_>=std::env::args_os().collect();match args.get(1).and_then(|s|s.to_str()){
    Some("numeric")if args.len()==2=>numeric::run(),Some("selfcheck")if args.len()==2=>float_scope::codec::run_selfcheck(),
    Some("screen")if args.len()==3=>screen(&read(Path::new(&args[2]))?),Some("abba")if args.len()==3=>abba(&read(Path::new(&args[2]))?),
    _=>Err("usage: lookup_float numeric|selfcheck|screen INPUT|abba INPUT".into())}}
fn main(){if let Err(e)=execute(){eprintln!("rejected: {e}");std::process::exit(1);}if let Err(e)=std::io::stdout().flush(){eprintln!("flush: {e}");std::process::exit(1);}}
