//! @happypath @category happy/boundary/resource @severity HIGH
//! 新規記述。入力累計4MiB以内、各frame/decodedは直接比較後に逐次解放する。
use crate::codec::{self,Result,Stats,MAX_INPUT};
#[derive(Default,Clone)]
pub struct Totals{pub inputs:usize,pub encode_calls:usize,pub decode_calls:usize,pub bwt:usize,pub walks:usize,pub fits:usize,pub roots:usize,pub cdfs:usize,pub stored:usize,pub compressed:usize,pub max_capacity:usize,pub max_scratch:usize}
impl Totals{pub fn add(&mut self,e:&Stats,d:&Stats){self.encode_calls+=1;self.decode_calls+=1;self.bwt+=e.bwt;self.walks+=e.walks;self.fits+=e.fits;self.roots+=e.roots;self.cdfs+=e.root_cdfs;self.stored+=usize::from(e.method==0);self.compressed+=usize::from(e.method==1);self.max_capacity=self.max_capacity.max(e.phase_capacity_bound).max(d.phase_capacity_bound);self.max_scratch=self.max_scratch.max(e.scratch_capacity_bound).max(d.scratch_capacity_bound);}}
pub fn seeded(n:usize)->Vec<u8>{let mut p=vec![0;n];let mut x=0x6d2b79f5u32;for b in &mut p{x^=x<<13;x^=x>>17;x^=x<<5;*b=x as u8;}p}
pub fn run()->Result<(String,Totals)>{let mut report=String::new();report.try_reserve_exact(8192).map_err(|_|"finite report allocation")?;let mut total=Totals::default();
    report.push_str("{\"case_columns\":[\"input_bytes\",\"method\",\"frame_bytes\",\"alphabet_bytes\",\"metadata_bytes\",\"payload_bytes\",\"BWT_calls\",\"Fit_builds\",\"encode_branches\",\"decode_branches\",\"escape_bytes\"],\"cases\":[");
    for case in 0..9{let plain=match case{0=>Vec::new(),1=>vec![165],2=>(0..=255u8).collect(),3=>vec![7;4096],4=>(0..8192).map(|i|if i%127==0{255}else{0}).collect(),5=>seeded(8192),6=>(0..4096).map(|i|(i%3)as u8).collect(),7=>vec![23;MAX_INPUT-1],_=>seeded(MAX_INPUT)};
        total.inputs=total.inputs.checked_add(plain.len()).ok_or("finite input sum")?;let(frame,e)=codec::encode(&plain)?;let(decoded,d)=codec::decode(&frame)?;
        if decoded!=plain || frame.len()>plain.len()+40 || e.method!=d.method || e.alphabet+e.metadata+e.payload+40!=frame.len() || (e.method==1 && (e.branches!=d.branches || e.implicit!=d.implicit || e.escapes!=d.escapes || e.runs!=d.runs)){return Err(format!("happy frame byte/census equality case{case}"));}
        if e.method==1 && (e.fits!=568 || e.roots!=852 || e.root_cdfs!=872448 || e.walks!=2 || e.bwt!=1){return Err("happy compressed model census".into());}total.add(&e,&d);total.max_capacity=total.max_capacity.max(d.phase_capacity_bound+plain.capacity()+report.capacity());total.max_scratch=total.max_scratch.max(codec::SCRATCH_BOUND+report.capacity());
        if case!=0{report.push(',');}report.push_str(&format!("[{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}]",plain.len(),e.method,e.frame,e.alphabet,e.metadata,e.payload,e.bwt,e.fits,e.branches,d.branches,e.escapes));
        if report.len()>4096{return Err("finite report body bound".into());}
    }
    let over=vec![0;MAX_INPUT+1];total.inputs+=over.len();total.encode_calls+=1;let reason=codec::encode(&over).err().ok_or("oversize encode accepted")?;if reason!="input exceeds block limit"{return Err("oversize encode reason".into());}drop(over);
    if total.inputs>4*MAX_INPUT || total.stored==0 || total.compressed==0 || total.max_capacity>64*MAX_INPUT || total.max_scratch>65536{return Err("finite coverage/resource".into());}
    report.push_str(&format!("],\"input_bytes_total\":{},\"input_budget_bytes\":4194304,\"maximum_input_including_rejected\":1048577,\"encode_calls\":{},\"decode_calls\":{},\"BWT_calls\":{},\"grammar_walks\":{},\"Fit_builds\":{},\"root_writes\":{},\"root_CDF_comparisons\":{},\"stored_cases\":{},\"compressed_cases\":{},\"oversize_encode_rejections\":1,\"byte_exact\":true,\"RAM_only\":true,\"max_codec_capacity_bound_bytes\":{},\"max_scratch_bound_bytes\":{}}}",total.inputs,total.encode_calls,total.decode_calls,total.bwt,total.walks,total.fits,total.roots,total.cdfs,total.stored,total.compressed,total.max_capacity,total.max_scratch));
    if report.len()>8192 || report.capacity()>8192{return Err("finite report capacity".into());}Ok((report,total))
}
