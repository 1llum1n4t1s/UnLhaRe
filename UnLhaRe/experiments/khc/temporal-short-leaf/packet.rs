//! 固定852root packet。RAMだけに保持し、逐次検証後に解放する。
use crate::{counts, paid_model, tiles};
type Result<T>=std::result::Result<T,String>;
pub const ROOTS:usize=2*counts::NODE_COUNT*3;
pub const MAX_PACKET_BYTES:usize=5053003;
pub const MAX_PACKET_BITS:usize=284*paid_model::MAX_BITS+ROOTS;
#[derive(Clone,Copy,Default)]
pub struct PaidStats{
    pub header_bits:usize,pub header_bytes:usize,pub padding_bits:usize,
    pub dp_internal_bits:usize,pub uniform_leaves:usize,pub pure_leaves:usize,pub raw_leaves:usize,
    pub defaults:usize,pub explicit:usize,pub models:usize,pub roots:usize,
    pub cdf_checks:usize,pub concatenated_bits_checked:usize,pub rows:usize,
    pub count:u64,pub components:[u64;2],pub dp_loss:f64,pub parsed_loss:f64,
    pub component_dp:[f64;2],pub component_parsed:[f64;2],pub working_bytes:usize,
}
pub struct Packet{bytes:Vec<u8>,bits:usize}
impl Packet{
    pub fn new()->Result<Self>{
        let mut bytes=Vec::new();bytes.try_reserve_exact(MAX_PACKET_BYTES).map_err(|_|"packet allocation")?;
        if bytes.capacity()>MAX_PACKET_BYTES{return Err("packet allocation cap".into());}
        bytes.resize(MAX_PACKET_BYTES,0);Ok(Self{bytes,bits:0})
    }
    pub fn write(&mut self,value:u32,width:usize)->Result<()>{
        if width>31 || value>=1u32<<width || self.bits.checked_add(width).ok_or("packet bit overflow")?>MAX_PACKET_BITS{return Err("packet writer range".into());}
        for s in (0..width).rev(){if value&(1<<s)!=0{self.bytes[4+self.bits/8]|=1<<(7-self.bits%8);}self.bits+=1;}Ok(())
    }
    pub fn root(&mut self,fit:&paid_model::Fit,k:usize)->Result<(bool,usize)>{
        let default=fit.root_default(k)?;let objective=fit.root_objective_bits(k)?;
        if default!=(objective==0){return Err("root default/objective fee".into());}self.write(u32::from(!default),1)?;
        if default{return Ok((true,0));}
        let (bytes,bits)=fit.root_wire(k)?;if bits!=objective{return Err("nondefault wire/objective bits".into());}let start=self.bits;
        for i in 0..bits{self.write(u32::from((bytes[i/8]>>(7-i%8))&1),1)?;}
        // 完成packetの当該範囲を局所root bitと直接比較。後続appendはこの範囲を書き換えない。
        for i in 0..bits{if (self.bytes[4+(start+i)/8]>>(7-(start+i)%8))&1 != (bytes[i/8]>>(7-i%8))&1{return Err("root concatenation direct bit mismatch".into());}}
        Ok((false,bits))
    }
    pub fn finish(mut self)->Result<Vec<u8>>{
        if self.bits<ROOTS || self.bits>MAX_PACKET_BITS{return Err("packet root/bit bound".into());}
        self.bytes[..4].copy_from_slice(&u32::try_from(self.bits).map_err(|_|"packet u32")?.to_le_bytes());
        self.bytes.truncate(4+self.bits.div_ceil(8));Ok(self.bytes)
    }
}
pub struct Reader<'a>{payload:&'a[u8],bits:usize,position:usize,nodes:usize,pub defaults:usize}
impl<'a> Reader<'a>{
    pub fn new(bytes:&'a[u8])->Result<Self>{
        if bytes.len()<4 || bytes.len()>MAX_PACKET_BYTES{return Err("packet bytes bound".into());}
        let bits=u32::from_le_bytes(bytes[..4].try_into().map_err(|_|"packet field")?) as usize;
        if !(ROOTS..=MAX_PACKET_BITS).contains(&bits) || bytes.len()!=4+bits.div_ceil(8){return Err("packet exact bits/bytes".into());}
        let payload=&bytes[4..];
        if bits%8!=0 && payload.last().copied().ok_or("packet empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("packet zero padding".into());}
        Ok(Self{payload,bits,position:0,nodes:0,defaults:0})
    }
    pub fn next(&mut self)->Result<paid_model::Dispatch>{
        if self.nodes>=2*counts::NODE_COUNT{return Err("packet extra node".into());}
        let (d,n)=paid_model::parse_packet_node(self.payload,self.bits,&mut self.position)?;
        self.nodes+=1;self.defaults+=n;Ok(d)
    }
    pub fn finish(&self)->Result<()>{
        if self.nodes!=2*counts::NODE_COUNT || self.position!=self.bits{return Err("packet roots/trailing bits".into());}Ok(())
    }
}
pub fn ingest(hist:&mut paid_model::Hist,k:usize,history:u16,row:[u32;4])->Result<()>{
    if !(2..=4).contains(&k) || hist.counts.len()!=paid_model::GROUPS*paid_model::NODES{return Err("weighted shape/prefix".into());}
    let added=row.iter().map(|&v|u64::from(v)).sum::<u64>();
    if row[k..].iter().any(|&v|v!=0) || added>u64::from(paid_model::CAP){return Err("weighted tail/CAP".into());}
    let mut ids=[0usize;6];let mut next=[[0u32;4];6];let mut id=0;
    for depth in 0..=5{let index=(k-2)*paid_model::NODES+id;ids[depth]=index;let current=hist.counts[index];
        if current[k..].iter().any(|&v|v!=0) || current.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(paid_model::CAP){return Err("weighted existing tail/CAP".into());}
        for j in 0..4{next[depth][j]=current[j].checked_add(row[j]).ok_or("weighted count overflow")?;}
        if next[depth].iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(paid_model::CAP){return Err("weighted updated CAP".into());}
        if depth<5{id=4*id+1+((history>>(2*depth))&3) as usize;}
    }
    for depth in 0..6{hist.counts[ids[depth]]=next[depth];}Ok(())
}

fn row_loss(row:[u32;4],f:[u16;4],k:usize)->Result<f64>{
    if row[k..].iter().any(|&n|n!=0) || f[k..].iter().any(|&n|n!=0)
        || f[..k].iter().any(|&n|n<2) || f[..k].iter().map(|&n|u32::from(n)).sum::<u32>()!=32768{return Err("paid row/CDF shape".into());}
    let mut loss=0.0;for i in 0..k{if row[i]!=0{loss+=f64::from(row[i])*(32768.0/f64::from(f[i])).log2();}}
    if !loss.is_finite() || loss<0.0{return Err("paid row loss".into());}Ok(loss)
}
pub fn evaluate_tile(dense:&counts::Dense)->Result<PaidStats>{
    if dense.rows.len()!=counts::ROWS{return Err("paid Dense shape".into());}
    let mut packet=Packet::new()?;let mut stat=PaidStats::default();
    let mut node_dp=[0.0;284];let mut node_count=[0u64;284];
    let mut comp_dp=[tiles::Loss::default();2];
    for c in 0..2{for node in 0..counts::NODE_COUNT{
        let mut hist=paid_model::Hist::new()?;
        for k in 2..=4{for h in 0..1024u16{ingest(&mut hist,k,h,dense.row(c,node,k,h)?)?;}}
        let fit=paid_model::Fit::build(&hist)?;let mut local_loss=tiles::Loss::default();let mut local_dp=tiles::Loss::default();
        for k in 2..=4{
            let (wire,bits)=fit.root_wire(k)?;let parsed=paid_model::parse_root(&wire,bits,k)?;
            for h in 0..1024u16{
                if fit.lookup(0,k,h)?!=parsed.lookup(0,k,h)?{return Err("Fit/root parse CDF direct mismatch".into());}
                stat.cdf_checks+=1;let row=dense.row(c,node,k,h)?;
                node_count[c*142+node]+=row.iter().map(|&n|u64::from(n)).sum::<u64>();
                local_loss.add(row_loss(row,parsed.lookup(0,k,h)?,k)?)?;
            }
            local_dp.add(fit.root_loss(k)?)?;
            stat.dp_internal_bits+=fit.root_objective_bits(k)?;
            let dispatch_bytes=parsed.capacity_bytes();drop(wire);drop(parsed);
            let (default,checked)=packet.root(&fit,k)?;
            stat.defaults+=usize::from(default);stat.explicit+=usize::from(!default);stat.roots+=1;stat.concatenated_bits_checked+=checked;
            let working=dense.capacity_bytes()+hist.capacity_bytes()+fit.capacity_bytes()+dispatch_bytes
                +paid_model::MAX_BYTES+std::mem::size_of::<Vec<u8>>()+MAX_PACKET_BYTES+std::mem::size_of::<Packet>();
            stat.working_bytes=stat.working_bytes.max(working);
        }
        if !tiles::close(local_dp.sum,local_loss.sum){return Err("node DP/individual root row loss".into());}
        let modes=fit.selected_mode_counts()?;stat.uniform_leaves+=modes[0];stat.pure_leaves+=modes[1];stat.raw_leaves+=modes[2];
        node_dp[c*142+node]=local_dp.sum;comp_dp[c].add(local_dp.sum)?;stat.models+=1;
    }}
    let bytes=packet.finish()?;stat.header_bits=u32::from_le_bytes(bytes[..4].try_into().map_err(|_|"completed packet field")?) as usize;
    stat.header_bytes=bytes.len();stat.padding_bits=(8-stat.header_bits%8)%8;
    if stat.dp_internal_bits+ROOTS!=stat.header_bits{return Err("DP internal bits plus outer flags/header bits".into());}
    let mut reader=Reader::new(&bytes)?;let mut component_parsed=[tiles::Loss::default();2];
    for c in 0..2{for node in 0..counts::NODE_COUNT{
        let dispatch=reader.next()?;let mut loss=tiles::Loss::default();let mut count=0u64;
        for k in 2..=4{for h in 0..1024u16{
            let row=dense.row(c,node,k,h)?;count+=row.iter().map(|&n|u64::from(n)).sum::<u64>();
            loss.add(row_loss(row,dispatch.lookup(0,k,h)?,k)?)?;stat.rows+=1;
        }}
        if count!=node_count[c*142+node] || !tiles::close(loss.sum,node_dp[c*142+node]){return Err("node completed packet count/DP loss".into());}
        stat.components[c]+=count;component_parsed[c].add(loss.sum)?;
    }}
    reader.finish()?;if reader.defaults!=stat.defaults || stat.roots!=ROOTS || stat.models!=284 || stat.rows!=counts::ROWS{return Err("paid packet census".into());}
    let mut dp=tiles::Loss::default();let mut parsed=tiles::Loss::default();
    for c in 0..2{
        if !tiles::close(comp_dp[c].sum,component_parsed[c].sum){return Err("component paid loss".into());}
        stat.component_dp[c]=comp_dp[c].sum;stat.component_parsed[c]=component_parsed[c].sum;
        dp.add(comp_dp[c].sum)?;parsed.add(component_parsed[c].sum)?;stat.count+=stat.components[c];
    }
    stat.dp_loss=dp.sum;stat.parsed_loss=parsed.sum;
    if !tiles::close(stat.dp_loss,stat.parsed_loss){return Err("tile paid loss".into());}
    Ok(stat)
}
