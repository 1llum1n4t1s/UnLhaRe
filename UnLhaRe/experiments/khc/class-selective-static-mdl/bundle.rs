//! 局所3groupモデルをglobal class2/5 node順へ束ねるprivate metadata。
use crate::{model,grammar};
type Result<T>=std::result::Result<T,String>;
pub const MAX_BUNDLE_BYTES:usize=5*1024*1024;
pub const MODELS:usize=278;
pub const MAX_SERIALIZED_BYTES:usize=MODELS*(4+model::MAX_BYTES);
const ROWS:usize=2*142*3*1024;
pub fn ingest(hist:&mut model::Hist,k:usize,history:u16,row:[u32;4])->Result<()>{
    if !(2..=4).contains(&k) || hist.counts.len()!=model::GROUPS*model::NODES{return Err("weighted shape/prefix".into());}
    let added=row.iter().map(|&v|u64::from(v)).sum::<u64>();
    if row[k..].iter().any(|&v|v!=0) || added>u64::from(model::CAP){return Err("weighted tail/CAP".into());}
    let mut ids=[0usize;6];let mut next=[[0u32;4];6];let mut id=0;
    for depth in 0..=5{let index=(k-2)*model::NODES+id;ids[depth]=index;let current=hist.counts[index];
        if current[k..].iter().any(|&v|v!=0) || current.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(model::CAP){return Err("weighted existing tail/CAP".into());}
        for j in 0..4{next[depth][j]=current[j].checked_add(row[j]).ok_or("weighted count overflow")?;}
        if next[depth].iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(model::CAP){return Err("weighted updated CAP".into());}
        if depth<5{id=4*id+1+((history>>(2*depth))&3) as usize;}
    }
    for depth in 0..6{hist.counts[ids[depth]]=next[depth];}Ok(())
}
pub fn append(out:&mut Vec<u8>,bytes:&[u8],bits:usize)->Result<()>{
    let _dispatch=model::parse(bytes,bits)?;let field=u32::try_from(bits).map_err(|_|"bundle bitlen u32")?;
    let length=out.len().checked_add(4).and_then(|n|n.checked_add(bytes.len())).ok_or("bundle length overflow")?;
    if length>MAX_BUNDLE_BYTES || out.capacity()>MAX_BUNDLE_BYTES{return Err("bundle capacity limit".into());}
    out.try_reserve_exact(length-out.len()).map_err(|_|"bundle allocation")?;
    if out.capacity()>MAX_BUNDLE_BYTES{return Err("bundle allocated capacity limit".into());}
    out.extend_from_slice(&field.to_le_bytes());out.extend_from_slice(bytes);Ok(())
}
pub struct Reader<'a>{bytes:&'a[u8],position:usize}
impl<'a> Reader<'a>{
    pub fn new(bytes:&'a[u8])->Result<Self>{if bytes.len()>MAX_BUNDLE_BYTES{return Err("bundle input limit".into());}Ok(Self{bytes,position:0})}
    pub fn next(&mut self)->Result<(&'a[u8],usize)>{
        let field_end=self.position.checked_add(4).ok_or("bundle field overflow")?;
        let field=self.bytes.get(self.position..field_end).ok_or("truncated bundle bitlen")?;
        let bits=u32::from_le_bytes(field.try_into().map_err(|_|"bundle field width")?) as usize;
        if bits==0 || bits>model::MAX_BITS{return Err("bundle bitlen bound".into());}
        let end=field_end.checked_add(bits.div_ceil(8)).ok_or("bundle model extent overflow")?;
        let bytes=self.bytes.get(field_end..end).ok_or("truncated bundle model")?;self.position=end;Ok((bytes,bits))
    }
    pub fn finish(&self)->Result<()>{if self.position!=self.bytes.len(){return Err("bundle trailing bytes".into());}Ok(())}
}
pub struct Forest{frequencies:Vec<[u16;4]>,selected:[[bool;142];2]}
impl Forest{
    pub fn parse(bytes:&[u8])->Result<Self>{
        let mut reader=Reader::new(bytes)?;let mut frequencies=Vec::new();frequencies.try_reserve_exact(ROWS).map_err(|_|"Forest allocation")?;frequencies.resize(ROWS,[0;4]);let mut selected=[[false;142];2];let mut models=0;
        for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});if tree.node_count()!=142{return Err("Forest grammar nodes".into());}
            for node in 0..142{if tree.class(node)?==2{selected[c][node]=true;models+=1;let(block,bits)=reader.next()?;let parsed=model::parse(block,bits)?;
                for k in 2..=4{for history in 0..1024u16{let index=((c*142+node)*3+k-2)*1024+history as usize;frequencies[index]=parsed.lookup(0,k,history)?;}}
            }}
        }
        if models!=MODELS{return Err("Forest selected node count".into());}reader.finish()?;Ok(Self{frequencies,selected})
    }
    pub fn lookup(&self,c:usize,node:usize,k:usize,history:u16)->Result<[u16;4]>{
        if c>=2 || node>=142 || !(2..=4).contains(&k) || !self.selected[c][node]{return Err("Forest component/node/prefix/mask".into());}
        self.frequencies.get(((c*142+node)*3+k-2)*1024+(history as usize&1023)).copied().ok_or("Forest index".into())
    }
    pub fn capacity_bytes(&self)->usize{self.frequencies.capacity()*std::mem::size_of::<[u16;4]>()+std::mem::size_of::<Self>()}
}
