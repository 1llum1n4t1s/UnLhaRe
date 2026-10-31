//! 先行固定したleaf候補の有限RAM E2E。独立loss/feeと実wireを直接照合する。
use crate::{paid_model as model,previous_paid_model as previous,codebook::{self,Encoder,Decoder}};
type Result<T>=std::result::Result<T,String>;
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err(format!("leaf finite loss {a} != {b}"));}Ok(())}
fn uniform(k:usize)->[u16;4]{match k{2=>[16384,16384,0,0],3=>[10923,10923,10922,0],_=>[8192;4]}}
fn pure(k:usize,d:usize)->[u16;4]{let mut f=[0;4];for v in &mut f[..k]{*v=2;}f[d]=(32768-2*(k-1)) as u16;f}
fn loss(row:[u32;4],f:[u16;4],k:usize)->Result<f64>{if f[..k].iter().any(|&n|n<2) || f[k..].iter().any(|&n|n!=0) || f[..k].iter().map(|&n|u32::from(n)).sum::<u32>()!=32768{return Err("independent candidate CDF".into());}
    let mut l=0.0;for i in 0..k{if row[i]!=0{l+=f64::from(row[i])*(15.0-f64::from(f[i]).log2());}}Ok(l)}
fn fee(f:[u16;4],k:usize,root:bool)->Result<usize>{
    if f==uniform(k){return Ok(if root{0}else{3});}
    for d in 0..k{if f==pure(k,d){return Ok(if k==2{4}else{5});}}
    let mut d=0;for i in 1..k{if f[i]>f[d]{d=i;}}
    let mut bits=2+if k==2{1}else{2};
    for i in 0..k{if i!=d{let mut code=None;for c in 0..256{if previous::MINOR_LUT[c]==f[i]{code=Some(c);break;}}
        let n=codebook::LENGTHS[code.ok_or("independent compact LUT code")?];bits+=if n==0{19}else{usize::from(n)};
    }}Ok(bits)
}
fn oracle(row:[u32;4],k:usize,root:bool)->Result<([u16;4],f64,usize,usize)> {
    let legacy=previous::compact_frequency(previous::quantize(row,k)?,k)?;
    let mut result=(legacy,loss(row,legacy,k)?,fee(legacy,k,root)?,0usize);
    for i in 0..=k{let f=if i==0{uniform(k)}else{pure(k,i-1)};let l=loss(row,f,k)?;let b=fee(f,k,root)?;
        if l+(b as f64)<result.1+result.2 as f64{result=(f,l,b,if i==0{1}else{2});}
    }Ok(result)
}
#[derive(Default)]
struct Counts{cases:usize,uniform:usize,pure:usize,legacy:usize,empty:usize,tie:usize,cdfs:usize,paid_builds:usize,baseline_builds:usize,baseline_cdfs:usize,baseline_nodes:usize,fit_evaluations:usize,direct_evaluations:usize}
fn one(row:[u32;4],k:usize,kind:usize,c:&mut Counts,enc:&Encoder,dec:&Decoder)->Result<()> {
    let expected=oracle(row,k,true)?;let actual=model::choose_leaf(row,k,true)?;
    if actual.0!=expected.0 || actual.2!=expected.2 || actual.3!=expected.3 || actual.3!=kind{return Err("independent root candidate order/fee/kind".into());}near(actual.1,expected.1)?;
    let inner=oracle(row,k,false)?;let actual_inner=model::choose_leaf(row,k,false)?;
    if actual_inner.0!=inner.0 || actual_inner.2!=inner.2 || actual_inner.3!=inner.3{return Err("independent inner candidate order/fee/kind".into());}near(actual_inner.1,inner.1)?;
    c.direct_evaluations+=2*(k+2);
    let mut hist=model::Hist::new()?;crate::paid_bundle::ingest(&mut hist,k,0,row)?;
    let(fit,evaluations)=model::Fit::build_counted(&hist,false)?;c.paid_builds+=1;c.fit_evaluations+=evaluations;
    if fit.root_split(k)? || fit.root_objective_bits(k)?!=expected.2 || fit.root_default(k)?!=(expected.0==uniform(k)){return Err("leaf actual DP/root default fee".into());}
    let(bytes,bits)=fit.root_wire(k,enc)?;if bits!=if expected.2==0{3}else{expected.2}{return Err("independent actual root wire fee".into());}
    let parsed=model::parse_root(&bytes,bits,k,dec)?;
    for h in 0..1024u16{if fit.lookup(0,k,h)?!=expected.0 || parsed.lookup(0,k,h)?!=expected.0{return Err("selected candidate allCDF wire/fit".into());}c.cdfs+=1;}
    near(fit.root_loss(k)?,loss(row,parsed.lookup(0,k,0)?,k)?)?;
    let old=previous::Fit::build(&hist)?;c.baseline_builds+=1;let repriced=fit.reprice_previous(&old,&hist,k,enc,dec)?;
    c.baseline_cdfs+=repriced.cdfs;c.baseline_nodes+=repriced.node_comparisons;
    if fit.root_loss(k)?+fit.root_objective_bits(k)? as f64>repriced.loss+repriced.bits as f64+1e-6{return Err("finite previous paid no-worse".into());}
    c.cases+=1;match kind{0=>c.legacy+=1,1=>c.uniform+=1,_=>c.pure+=1,}Ok(())
}
pub fn run()->Result<String>{
    let enc=Encoder::new(codebook::LENGTHS)?;let dec=Decoder::new(codebook::LENGTHS)?;let mut c=Counts::default();
    for k in 2..=4{
        one([0;4],k,0,&mut c,&enc,&dec)?;c.empty+=1;
        let mut nonuniform=[0;4];nonuniform[0]=1;one(nonuniform,k,1,&mut c,&enc,&dec)?;
        for d in 0..k{let mut nonpure=[0;4];nonpure[..k].fill(1);nonpure[d]=10000;
            if previous::compact_frequency(previous::quantize(nonpure,k)?,k)?==pure(k,d){return Err("nonpure finite fixture became pure".into());}
            one(nonpure,k,2,&mut c,&enc,&dec)?;
            let mut tied=[0;4];tied[d]=17;one(tied,k,0,&mut c,&enc,&dec)?;c.tie+=1;
        }
        let compact=match k{2=>[30000,2768,0,0],3=>[30000,1700,1068,0],_=>[30000,1000,1000,768]};
        one(compact,k,0,&mut c,&enc,&dec)?;
    }
    if c.cases!=27 || c.uniform!=3 || c.pure!=9 || c.legacy!=15 || c.cdfs!=27648 || c.baseline_cdfs!=27648 || c.paid_builds!=27 || c.baseline_builds!=27{return Err("leaf finite extent".into());}
    if model::Fit::node_size()!=32{return Err("leaf Node32 preserved".into());}
    Ok(format!("{{\"root_cases\":{},\"inner_candidate_cases\":{},\"nonuniform_to_uniform_cases\":{},\"nonpure_to_pure_all_dominant_cases\":{},\"legacy_selected_cases\":{},\"empty_legacy_tie_cases\":{},\"pure_legacy_tie_cases\":{},\"compact_retained_cases\":3,\"Fit_parse_CDF_comparisons\":{},\"baseline_CDF_comparisons\":{},\"baseline_node_objective_comparisons\":{},\"paid_Fit_builds\":{},\"baseline_Fit_builds\":{},\"paid_build_candidate_evaluations\":{},\"direct_candidate_evaluations\":{},\"maximum_candidates_per_node\":6,\"candidate_order_and_strict_tie_verified\":true,\"actual_observed_loss_charged\":true,\"actual_wire_fee_verified\":true,\"previous_paid_no_worse\":true,\"Node_bytes\":32,\"RAM_only\":true}}",c.cases,c.cases,c.uniform,c.pure,c.legacy,c.empty,c.tie,c.cdfs,c.baseline_cdfs,c.baseline_nodes,c.paid_builds,c.baseline_builds,c.fit_evaluations,c.direct_evaluations))
}
