use crate::{model,bundle,grammar};
type Result<T>=std::result::Result<T,String>;
const UNIFORM:[u8;12]=[64,0,42,171,85,86,64,0,128,1,0,0];
fn uniform(k:usize)->[u16;4]{match k{2=>[16384,16384,0,0],3=>[10923,10923,10922,0],_=>[8192;4]}}
pub fn run()->Result<String>{
    let density=crate::density_happy::run()?;let mut checks=0usize;
    for mixed in [false,true]{
        let mut h=model::Hist::new()?;
        if mixed{bundle::ingest(&mut h,2,0,[100,0,0,0])?;bundle::ingest(&mut h,2,1,[0,100,0,0])?;}
        let fit=model::Fit::build(&h)?;let(bytes,bits)=fit.serialize()?;
        if (!mixed && (bits!=93 || bytes!=UNIFORM || fit.selected_leaf_count()!=3 || fit.selected_split_count()!=0)) || (mixed && (bits!=142 || fit.selected_leaf_count()!=6 || fit.selected_split_count()!=1)){return Err("parent MDL field fixture".into());}
        let parsed=model::parse(&bytes,bits)?;
        for k in 2..=4{for history in 0..1024u16{let want=if mixed && k==2{match history&3{0=>[32766,2,0,0],1=>[2,32766,0,0],_=>uniform(k)}}else{uniform(k)};
            if fit.lookup(0,k,history)?!=want || parsed.lookup(0,k,history)?!=want{return Err("parent all block CDF".into());}checks+=1;
        }}
    }
    let mut bytes=Vec::new();for _ in 0..278{bundle::append(&mut bytes,&UNIFORM,93)?;}
    if bytes.len()!=4448 || &bytes[..4]!=93u32.to_le_bytes().as_slice(){return Err("parent bundle LE fields".into());}
    let mut reader=bundle::Reader::new(&bytes)?;for _ in 0..278{let(b,bits)=reader.next()?;if bits!=93 || b!=UNIFORM{return Err("parent packet boundary".into());}}reader.finish()?;
    let forest=bundle::Forest::parse(&bytes)?;let mut forest_checks=0usize;let mut nodes=0usize;
    for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});for node in 0..142{if tree.class(node)?==2{nodes+=1;for k in 2..=4{for history in 0..1024u16{if forest.lookup(c,node,k,history)?!=uniform(k){return Err("parent global forest CDF".into());}forest_checks+=1;}}}}}
    if nodes!=278 || forest_checks!=854016{return Err("parent forest extents".into());}
    Ok(format!("{{\"Density\":{density},\"block_fixtures\":2,\"block_CDF_comparisons\":{checks},\"bundle_bytes\":4448,\"models\":{nodes},\"Forest_CDF_comparisons\":{forest_checks}}}"))
}
