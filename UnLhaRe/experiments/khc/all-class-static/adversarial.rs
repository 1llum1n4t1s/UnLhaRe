//! @adversarial @category boundary/type/state/resource @severity HIGH
//! 新規記述。RAM packet変異の厳密拒否と同process正常復帰。OS chaosではない。
use crate::{codebook,packet,paid_model as model};
type Result<T>=std::result::Result<T,String>;
fn wire(fields:&[(u32,usize)])->Result<Vec<u8>>{let bits=fields.iter().map(|x|x.1).sum();let mut w=codebook::Writer::new(bits)?;for &(v,n)in fields{w.write(v,n)?;}codebook::header(&w.bytes,bits,&codebook::LENGTHS)}
fn malformed()->Result<(usize,usize)>{
    let good=wire(&vec![(0,1);852])?;if good.len()!=241{return Err("all default paid241".into());}
    let forest=packet::Forest::parse(&good)?;for c in 0..2{for n in 0..142{for k in 2..=4{for h in 0..1024u16{if forest.lookup(c,n,k,h)?!=model::uniform(k)?{return Err("finite all default integer CDF".into());}}}}}drop(forest);
    let enc=codebook::Encoder::new(codebook::LENGTHS)?;
    let mut rejected=0;let mut recovered=0;for case in 0..19{let mut bad=good.clone();let reason=match case{
        0=>{bad.truncate(133);"header bytes bound"},1=>{bad[0]=0;"header codec flag"},2=>{bad[133]|=1;"table nibble padding"},
        3=>{bad[5]=(bad[5]&240)|12;"table length exceeds11"},4=>{bad[133]=0;"table ESC absent"},5=>{bad[5]=(bad[5]&240)|1;"table Kraft oversubscribed"},6=>{bad[5]&=15;"table Kraft incomplete"},
        7=>{bad[1..5].copy_from_slice(&0u32.to_le_bytes());"header exact bits/bytes"},8=>{bad[1..5].copy_from_slice(&((packet::MAX_BUNDLE_BITS+1) as u32).to_le_bytes());"header exact bits/bytes"},
        9=>{bad.pop();"header exact bits/bytes"},10=>{bad.push(0);"header exact bits/bytes"},11=>{*bad.last_mut().ok_or("finite pad")?|=1;"header zero padding"},
        12=>{let mut f=vec![(0,1),(1,1),(0,1),(0,1),(3,2)];f.extend(vec![(0,1);850]);bad=wire(&f)?;"compact dominant index"},
        13=>{let mut f=vec![(1,1),(1,1),(0,1)];f.extend(vec![(1,1);6]);f.extend(vec![(0,1);851]);bad=wire(&f)?;"paid split beyond depth5"},
        14|15=>{
            let k=if case==14{4}else{3};let roots=k-2;let width=2;let mut fields=vec![(0,1);roots];fields.extend([(1,1),(0,1),(0,1),(0,width)]);
            let minorbits=codebook::fee(255)*(k-1);let mut w=codebook::Writer::new(minorbits)?;for _ in 0..k-1{enc.write(255,&mut w)?;}
            for bit in 0..minorbits{fields.push((u32::from((w.bytes[bit/8]>>(7-bit%8))&1),1));}fields.extend(vec![(0,1);852-roots-1]);bad=wire(&fields)?;
            if case==14{"compact residual underflow"}else{"compact residual largest/minimum"}
        },
        16=>{let mut f=vec![(0,1);851];f.extend([(1,1),(1,1)]);bad=wire(&f)?;"truncated paid field/code/raw"},
        17=>{bad=wire(&vec![(0,1);853])?;"global model count/trailing bits"},
        _=>{bad=wire(&vec![(0,1);851])?;"global root bit minimum"}
    };
        let actual=packet::Forest::parse(&bad).err().ok_or_else(||format!("malformed {case} accepted"))?;
        if actual!=reason{return Err(format!("malformed {case}: {actual}, expected {reason}"));}rejected+=1;let _=packet::Forest::parse(&good)?;recovered+=1;
    }Ok((rejected,recovered))
}
pub fn run()->Result<(String,usize,usize)>{
    let(rejects,recoveries)=malformed()?;
    Ok((format!("{{\"packet_rejections\":{rejects},\"same_process_recoveries\":{recoveries},\"malformed_Forest_parse_calls\":{rejects},\"recovery_Forest_parse_calls\":{recoveries},\"normal_witness_Forest_parse_calls\":1,\"total_Forest_parse_calls\":{},\"normal_witness_packet_bytes\":241,\"normal_witness_CDF_comparisons\":872448,\"exact_reasons_verified\":true,\"Fit_builds\":0,\"BWT_calls\":0,\"input_reads\":0,\"grammar_walks\":0,\"tail_total_direct_fields\":false,\"tail_total_reason\":\"integer leaf grammar derives zero tail and total32768; invalid residual rejected\",\"failure_model\":\"bounded RAM metadata mutations\",\"OS_chaos_executed\":false,\"native_classification\":\"parent execution owns classification\",\"RAM_only\":true}}",1+rejects+recoveries),rejects,recoveries))
}
