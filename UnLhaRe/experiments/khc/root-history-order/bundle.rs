//! global class2/5固定順の834root metadata。RAMだけで保持。
use crate::{model,grammar};
type Result<T>=std::result::Result<T,String>;
pub const MODELS:usize=278;
pub const ROOTS:usize=834;
pub const MAX_BUNDLE_BITS:usize=MODELS*model::MAX_BITS+ROOTS;
pub const MAX_BUNDLE_BYTES:usize=4+(MAX_BUNDLE_BITS+7)/8;
pub const MAX_SERIALIZED_BYTES:usize=MAX_BUNDLE_BYTES;
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

pub struct Packet{bytes:Vec<u8>,pub bits:usize,pub roots:usize,pub defaults:usize,pub checked_bits:usize,pub objective_bits:usize}
impl Packet{
    pub fn new()->Result<Self>{let mut bytes=Vec::new();bytes.try_reserve_exact(MAX_BUNDLE_BYTES).map_err(|_|"global packet allocation")?;
        if bytes.capacity()>MAX_BUNDLE_BYTES{return Err("global packet capacity".into());}bytes.resize(MAX_BUNDLE_BYTES,0);
        Ok(Self{bytes,bits:0,roots:0,defaults:0,checked_bits:0,objective_bits:0})}
    pub fn write(&mut self,value:u32,width:usize)->Result<()>{
        if width>31 || value>=1u32<<width || self.bits.checked_add(width).ok_or("global writer overflow")?>MAX_BUNDLE_BITS{return Err("global writer range".into());}
        for s in (0..width).rev(){if value&(1<<s)!=0{self.bytes[4+self.bits/8]|=1<<(7-self.bits%8);}self.bits+=1;}Ok(())
    }
    pub fn append_root(&mut self,fit:&model::Selected<'_>,k:usize)->Result<()>{
        if self.roots>=ROOTS{return Err("global extra root".into());}
        let default=fit.root_default(k)?;let objective=fit.root_objective_bits(k)?;
        if default!=(objective==0){return Err("global root default/objective".into());}
        self.write(u32::from(!default),1)?;self.roots+=1;self.defaults+=usize::from(default);self.objective_bits+=objective;
        if default{return Ok(());}
        let(local,bits)=fit.root_wire(k)?;if bits!=objective{return Err("global root wire/objective".into());}let start=self.bits;
        for i in 0..bits{self.write(u32::from((local[i/8]>>(7-i%8))&1),1)?;}
        for i in 0..bits{if (self.bytes[4+(start+i)/8]>>(7-(start+i)%8))&1!=(local[i/8]>>(7-i%8))&1{return Err("global root concatenation bit mismatch".into());}}
        self.checked_bits+=bits;Ok(())
    }
    pub fn finish(mut self)->Result<Vec<u8>>{
        if self.roots!=ROOTS || self.bits!=self.objective_bits+ROOTS{return Err("global actual DP bits plus root flags".into());}
        self.bytes[..4].copy_from_slice(&u32::try_from(self.bits).map_err(|_|"global field")?.to_le_bytes());
        self.bytes.truncate(4+self.bits.div_ceil(8));Ok(self.bytes)
    }
}
pub struct Reader<'a>{payload:&'a[u8],pub bits:usize,position:usize,models:usize,pub defaults:usize}
impl<'a> Reader<'a>{
    pub fn new(bytes:&'a[u8])->Result<Self>{
        if bytes.len()<4 || bytes.len()>MAX_BUNDLE_BYTES{return Err("global bytes bound".into());}
        let bits=u32::from_le_bytes(bytes[..4].try_into().map_err(|_|"global bit field")?) as usize;
        if !(ROOTS..=MAX_BUNDLE_BITS).contains(&bits) || bytes.len()!=4+bits.div_ceil(8){return Err("global exact bits/bytes".into());}
        let payload=&bytes[4..];if bits%8!=0 && payload.last().copied().ok_or("global empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("global zero padding".into());}
        Ok(Self{payload,bits,position:0,models:0,defaults:0})
    }
    pub fn next(&mut self)->Result<model::Dispatch>{
        if self.models>=MODELS{return Err("global extra model".into());}
        let(d,defaults)=model::parse_packet_node(self.payload,self.bits,&mut self.position)?;
        self.models+=1;self.defaults+=defaults;Ok(d)
    }
    pub fn finish(&self)->Result<()>{if self.models!=MODELS || self.position!=self.bits{return Err("global model count/trailing bits".into());}Ok(())}
}
pub struct Forest{frequencies:Vec<[u16;4]>,selected:[[bool;142];2]}
impl Forest{
    pub fn parse(bytes:&[u8])->Result<Self>{
        let mut reader=Reader::new(bytes)?;let mut frequencies=Vec::new();frequencies.try_reserve_exact(ROWS).map_err(|_|"Forest allocation")?;frequencies.resize(ROWS,[0;4]);
        let mut selected=[[false;142];2];let mut models=0;
        for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});if tree.node_count()!=142{return Err("Forest grammar nodes".into());}
            for node in 0..142{if tree.class(node)?==2{selected[c][node]=true;models+=1;let parsed=reader.next()?;
                for k in 2..=4{for h in 0..1024u16{frequencies[((c*142+node)*3+k-2)*1024+usize::from(h)]=parsed.lookup(0,k,h)?;}}
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
