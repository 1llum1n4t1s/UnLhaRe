use crate::histogram::{Hist,RA,LA,RG,LG};
const TOTAL:u32=32768;
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Cdf {pub freq:Vec<u32>,pub prefix:Vec<u32>}
impl Cdf {
    fn from_freq(freq:Vec<u32>)->Result<Self,String>{let mut prefix=vec![0u32];for &f in &freq{prefix.push(prefix.last().unwrap().checked_add(f).ok_or("CDF overflow")?);}if prefix.last()!=Some(&TOTAL){return Err("CDF total".into());}Ok(Self{freq,prefix})}
    pub fn quantize(counts:&[u32])->Result<Self,String>{
        let sum=counts.iter().try_fold(0u64,|s,&c|s.checked_add(c as u64).ok_or("count sum overflow"))?;
        let used=counts.iter().filter(|&&c|c!=0).count();if used==0 || used>TOTAL as usize{return Err("empty/too many CDF".into());}
        let left=TOTAL as u64-used as u64;let mut freq=vec![0u32;counts.len()];let mut remainders=Vec::new();let mut assigned=used as u64;
        for (s,&c) in counts.iter().enumerate(){if c!=0{let product=(c as u64).checked_mul(left).ok_or("quantize product overflow")?;let q=product/sum;freq[s]=u32::try_from(1+q).map_err(|_|"quantize range")?;assigned=assigned.checked_add(q).ok_or("assigned overflow")?;remainders.push((product%sum,s));}}
        remainders.sort_by(|a,b|b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
        let residual=TOTAL as u64-assigned;if residual>remainders.len() as u64{return Err("Hamilton residual".into());}for &(_,s) in remainders.iter().take(residual as usize){freq[s]=freq[s].checked_add(1).ok_or("freq increment")?;}
        Self::from_freq(freq)
    }
    pub fn bits(&self)->usize{let n=self.freq.iter().filter(|&&f|f!=0).count();24*n-6}
    fn loss(&self,counts:&[u32])->Result<f64,String>{if counts.len()!=self.freq.len(){return Err("loss extent".into());}let mut sum=0.0;for (&c,&f) in counts.iter().zip(&self.freq){if c!=0{if f==0{return Ok(f64::INFINITY);}sum+=c as f64*(TOTAL as f64/f as f64).log2();}}if sum.is_nan() || sum<0.0{return Err("loss nonfinite".into());}Ok(sum)}
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Group {pub tag:u8,pub own:Option<usize>,pub children:[Option<usize>;4]}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Model {pub cdfs:Vec<Cdf>,pub rank:Vec<Group>,pub length:Vec<Group>,pub rank_dispatch:Vec<[usize;4]>,pub length_dispatch:Vec<[usize;4]>}
impl Model {
    fn dispatch(groups:&[Group],global:usize)->Vec<[usize;4]>{groups.iter().map(|g|{let base=g.own.unwrap_or(global);std::array::from_fn(|b|g.children[b].unwrap_or(base))}).collect()}
    fn from_parts(cdfs:Vec<Cdf>,rank:Vec<Group>,length:Vec<Group>)->Self{let rank_dispatch=Self::dispatch(&rank,0);let length_dispatch=Self::dispatch(&length,1);Self{cdfs,rank,length,rank_dispatch,length_dispatch}}
    pub fn train(hist:&Hist)->Result<Self,String>{hist.validate()?;let mut cdfs=vec![Cdf::quantize(&hist.rank[..RA])?,Cdf::quantize(&hist.length[..LA])?];let rank=Self::groups(&hist.rank,RA,RG,0,&mut cdfs)?;let length=Self::groups(&hist.length,LA,LG,1,&mut cdfs)?;Ok(Self::from_parts(cdfs,rank,length))}
    fn groups(data:&[u32],a:usize,n:usize,global:usize,cdfs:&mut Vec<Cdf>)->Result<Vec<Group>,String>{
        let mut result=Vec::new();for g in 0..n {
            let row=&data[(1+g)*a..(2+g)*a];if row.iter().all(|&x|x==0){result.push(Group{tag:0,own:None,children:[None;4]});continue;}
            let own=Cdf::quantize(row)?;let children_rows:[&[u32];4]=std::array::from_fn(|b|&data[(1+n+g*4+b)*a..(2+n+g*4+b)*a]);
            let children:Vec<Option<Cdf>>=children_rows.iter().map(|row|if row.iter().all(|&x|x==0){Ok(None)}else{Cdf::quantize(row).map(Some)}).collect::<Result<_,String>>()?;
            let mut best=f64::INFINITY;let mut tag=0;let mut selected=[false;4];
            for candidate in 0..4u8 {
                let base=if candidate&1!=0{&own}else{&cdfs[global]};let mut cost=2.0+if candidate&1!=0{own.bits() as f64}else{0.0};let mut flags=[false;4];
                if candidate<2 {cost+=base.loss(row)?;}else{cost+=4.0;for b in 0..4{let inherit=base.loss(children_rows[b])?;let child=if let Some(c)=&children[b]{c.loss(children_rows[b])?+c.bits() as f64}else{f64::INFINITY};if child<inherit{cost+=child;flags[b]=true;}else{cost+=inherit;}}if !flags.iter().any(|&v|v){continue;}}
                if !cost.is_finite(){return Err("MDL cost nonfinite".into());}if cost<best{best=cost;tag=candidate;selected=flags;}
            }
            let own_index=if tag&1!=0{let i=cdfs.len();cdfs.push(own);Some(i)}else{None};let mut child_indices=[None;4];for b in 0..4{if selected[b]{let i=cdfs.len();cdfs.push(children[b].clone().ok_or("selected empty child")?);child_indices[b]=Some(i);}}
            result.push(Group{tag,own:own_index,children:child_indices});
        }Ok(result)
    }
    pub fn score(&self,c:usize,s:usize,x:usize,b:usize,t:usize,limit:usize)->Result<f64,String>{let index=if c==0{*self.rank_dispatch.get(s).and_then(|r|r.get(b)).ok_or("rank dispatch")?}else if c==1{*self.length_dispatch.get(x).and_then(|r|r.get(b)).ok_or("length dispatch")?}else{return Err("score component".into());};let cdf=self.cdfs.get(index).ok_or("CDF dispatch range")?;if limit==0 || limit>cdf.freq.len() || t>=limit{return Err("score token/limit".into());}let f=cdf.freq[t];let total=cdf.prefix[limit];if f==0 || total==0 || f>total{return Err("score zero/range".into());}let loss=(total as f64/f as f64).log2();if !loss.is_finite() || loss<0.0{return Err("score finite".into());}Ok(loss)}
    pub fn tag_counts(&self)->[usize;4]{let mut counts=[0;4];for g in self.rank.iter().chain(&self.length){counts[g.tag as usize]+=1;}counts}
    pub fn header(&self)->Result<(Vec<u8>,usize),String>{
        let mut writer=Writer::new();writer.cdf(&self.cdfs[0])?;writer.cdf(&self.cdfs[1])?;
        for groups in [&self.rank,&self.length]{for g in groups{writer.put(g.tag as u32,2)?;if let Some(i)=g.own{writer.cdf(&self.cdfs[i])?;}if g.tag>=2{if g.children.iter().all(Option::is_none){return Err("redundant split tag".into());}for &i in &g.children{writer.put(u32::from(i.is_some()),1)?;if let Some(i)=i{writer.cdf(&self.cdfs[i])?;}}}}}
        if writer.bits>8208276 || writer.bytes.len()>1048576{return Err("header bound".into());}Ok((writer.bytes,writer.bits))
    }
    pub fn parse(bytes:&[u8],bits:usize)->Result<Self,String>{
        let mut reader=Reader::new(bytes,bits)?;let mut cdfs=vec![reader.cdf(RA)?,reader.cdf(LA)?];let rank=reader.groups(RG,RA,&mut cdfs)?;let length=reader.groups(LG,LA,&mut cdfs)?;if reader.pos!=bits{return Err("extra declared model bits".into());}Ok(Self::from_parts(cdfs,rank,length))
    }
}
struct Writer {bytes:Vec<u8>,bits:usize}
impl Writer {
    fn new()->Self{Self{bytes:Vec::new(),bits:0}}
    fn put(&mut self,value:u32,width:usize)->Result<(),String>{if width>31 || value >=1u32<<width{return Err("writer value range".into());}let end=self.bits.checked_add(width).ok_or("writer bits overflow")?;if end>8208276{return Err("writer maximum".into());}for b in 0..width{if self.bits%8==0{self.bytes.push(0);}self.bytes[self.bits/8]|=(((value>>b)&1) as u8)<<(self.bits%8);self.bits+=1;}Ok(())}
    fn cdf(&mut self,cdf:&Cdf)->Result<(),String>{let used:Vec<_>=cdf.freq.iter().enumerate().filter(|&(_, &f)|f!=0).collect();if used.is_empty() || used.len()>257{return Err("writer CDF extent".into());}self.put(used.len() as u32,9)?;for &(s,_) in &used{self.put(s as u32,9)?;}for &(_, &f) in used.iter().take(used.len()-1){if f==0 || f>=TOTAL{return Err("writer freq".into());}self.put(f,15)?;}Ok(())}
}
struct Reader<'a>{bytes:&'a[u8],bits:usize,pos:usize}
impl<'a> Reader<'a>{
    fn new(bytes:&'a[u8],bits:usize)->Result<Self,String>{if bits>8208276 || bytes.len()>1048576 || bits>bytes.len().checked_mul(8).ok_or("reader extent overflow")? || bytes.len()!=bits.div_ceil(8){return Err("reader declared extent".into());}if bits%8!=0 && bytes.last().copied().unwrap_or(0)>>(bits%8)!=0{return Err("nonzero padding".into());}Ok(Self{bytes,bits,pos:0})}
    fn get(&mut self,width:usize)->Result<u32,String>{if self.pos.checked_add(width).ok_or("reader overflow")?>self.bits{return Err("truncated field".into());}let mut value=0;for b in 0..width{value|=u32::from((self.bytes[self.pos/8]>>(self.pos%8))&1)<<b;self.pos+=1;}Ok(value)}
    fn cdf(&mut self,a:usize)->Result<Cdf,String>{let used=self.get(9)? as usize;if used==0 || used>a{return Err("used count range".into());}let mut ids=Vec::new();for _ in 0..used{let s=self.get(9)? as usize;if s>=a || ids.last().is_some_and(|&p|p>=s){return Err("CDF symbol range/order".into());}ids.push(s);}let mut freq=vec![0;a];let mut sum=0u32;for &s in ids.iter().take(used-1){let f=self.get(15)?;if f==0{return Err("zero explicit freq".into());}sum=sum.checked_add(f).ok_or("parsed sum overflow")?;if sum>=TOTAL{return Err("CDF frequency sum".into());}freq[s]=f;}freq[*ids.last().unwrap()]=TOTAL-sum;Cdf::from_freq(freq)}
    fn groups(&mut self,n:usize,a:usize,cdfs:&mut Vec<Cdf>)->Result<Vec<Group>,String>{let mut groups=Vec::new();for _ in 0..n{let tag=self.get(2)? as u8;let own=if tag&1!=0{let i=cdfs.len();cdfs.push(self.cdf(a)?);Some(i)}else{None};let mut children=[None;4];if tag>=2{for index in &mut children{if self.get(1)?!=0{let i=cdfs.len();cdfs.push(self.cdf(a)?);*index=Some(i);}}if children.iter().all(Option::is_none){return Err("redundant split tag".into());}}groups.push(Group{tag,own,children});}Ok(groups)}
}

pub fn header_e2e()->Result<(usize,usize),String>{
    fn set(bytes:&mut[u8],pos:usize,width:usize,value:u32){for b in 0..width{let mask=1u8<<((pos+b)%8);let byte=&mut bytes[(pos+b)/8];*byte=(*byte&!mask)|((((value>>b)&1) as u8)<<((pos+b)%8));}}
    let mut rank_counts=vec![0;RA];rank_counts[0]=1;rank_counts[256]=1;let r=Cdf::quantize(&rank_counts)?;let mut len_counts=vec![0;LA];len_counts[0]=1;len_counts[255]=1;let l=Cdf::quantize(&len_counts)?;
    let singleton=Cdf::quantize(&[7])?;let thirds=Cdf::quantize(&[1,1,1])?;let all=Cdf::quantize(&vec![1;RA])?;if singleton.freq!=[32768] || thirds.freq!=[10923,10923,10922] || all.freq.iter().any(|&f|f==0){return Err("quantization boundary E2E".into());}
    let empty=Group{tag:0,own:None,children:[None;4]};let mut rank=vec![empty.clone();RG];let mut cdfs=vec![r.clone(),l];rank[0]=Group{tag:1,own:Some(2),children:[None;4]};cdfs.push(r.clone());rank[1]=Group{tag:2,own:None,children:[Some(3),None,None,None]};cdfs.push(r.clone());rank[2]=Group{tag:3,own:Some(4),children:[None,Some(5),None,None]};cdfs.push(r.clone());cdfs.push(r);
    rank[3]=Group{tag:1,own:Some(6),children:[None;4]};cdfs.push(cdfs[0].clone());
    let model=Model::from_parts(cdfs,rank,vec![empty;LG]);let (bytes,bits)=model.header()?;if Model::parse(&bytes,bits)?!=model{return Err("all tag model roundtrip".into());}let mut normal=1;let mut rejected=0;
    let mut reject=|data:Vec<u8>,n:usize|->Result<(),String>{if Model::parse(&data,n).is_ok(){return Err(format!("header rejection accepted {rejected}"));}rejected+=1;Ok(())};
    reject(vec![],0)?;reject(bytes.clone(),bytes.len()*8+1)?;
    let n=bits-1;reject(bytes[..n.div_ceil(8)].to_vec(),n)?;let mut extra=bytes.clone();extra.push(0);reject(extra,bits)?;
    let mut extra_bits=bytes.clone();extra_bits.resize((bits+1).div_ceil(8),0);reject(extra_bits,bits+1)?;
    if bits%8!=0{let mut bad=bytes.clone();let last=bad.len()-1;bad[last]|=1<<(bits%8);reject(bad,bits)?;}else{return Err("padding fixture alignment".into());}
    for (pos,width,value) in [(0,9,0),(0,9,258),(9,9,257),(18,9,0),(9,9,256),(27,15,0)]{let mut bad=bytes.clone();set(&mut bad,pos,width,value);reject(bad,bits)?;}
    let mut decreasing=bytes.clone();set(&mut decreasing,9,9,256);set(&mut decreasing,18,9,1);reject(decreasing,bits)?;
    let mut three_rank=vec![0;RA];three_rank[0]=1;three_rank[1]=1;three_rank[2]=1;let fixture=Model::from_parts(vec![Cdf::quantize(&three_rank)?,model.cdfs[1].clone()],vec![Group{tag:0,own:None,children:[None;4]};RG],model.length.clone());let (mut sum_bytes,sum_bits)=fixture.header()?;set(&mut sum_bytes,36,15,32767);set(&mut sum_bytes,51,15,1);reject(sum_bytes,sum_bits)?;
    // 2bit tagは全合法。split-all-inheritは冗長な表現としてのみ拒否する。
    let mut redundant=Writer::new();redundant.cdf(&model.cdfs[0])?;redundant.cdf(&model.cdfs[1])?;redundant.put(2,2)?;for _ in 0..4{redundant.put(0,1)?;}for _ in 1..RG+LG{redundant.put(0,2)?;}reject(redundant.bytes,redundant.bits)?;
    let mut trunc=Writer::new();trunc.cdf(&model.cdfs[0])?;trunc.cdf(&model.cdfs[1])?;trunc.put(1,2)?;reject(trunc.bytes,trunc.bits)?;
    for input in [vec![0u32;RA],vec![0u32;LA]]{if Cdf::quantize(&input).is_ok(){return Err("empty CDF accepted".into());}normal+=1;}
    Ok((normal,rejected))
}
