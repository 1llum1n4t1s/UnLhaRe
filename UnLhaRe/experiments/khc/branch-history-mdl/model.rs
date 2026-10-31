type Result<T>=std::result::Result<T,String>;
pub const NODES:usize=1365;
pub const GROUPS:usize=18;
pub const HISTORIES:usize=1024;
pub const CAP:u32=3825340;
pub const MAX_BITS:usize=854010;
pub const MAX_BYTES:usize=106752;
fn allocated<T:Clone>(len:usize,value:T)->Result<Vec<T>>{let mut v=Vec::new();v.try_reserve_exact(len).map_err(|_|"model allocation")?;v.resize(len,value);Ok(v)}
fn group(class:usize,k:usize)->Result<usize>{if class>=6 || !(2..=4).contains(&k){return Err("model class/prefix".into());}Ok(class*3+k-2)}
fn valid_frequency(f:[u16;4],k:usize)->Result<()>{if !(2..=4).contains(&k) || f[..k].iter().any(|&v|v<2) || f[k..].iter().any(|&v|v!=0) || f[..k].iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("CDF support/total/tail".into());}Ok(())}
pub struct Hist {pub counts:Vec<[u32;4]>}
impl Hist {
    pub fn new()->Result<Self>{Ok(Self{counts:allocated(GROUPS*NODES,[0;4])?})}
    pub fn record(&mut self,class:usize,k:usize,history:u16,child:usize)->Result<()>{
        let g=group(class,k)?;if child>=k || self.counts.len()!=GROUPS*NODES{return Err("hist child/shape".into());}
        let mut ids=[0usize;6];let mut id=0;for depth in 0..=5{ids[depth]=g*NODES+id;if depth<5{id=4*id+1+((history>>(2*depth))&3) as usize;}}
        let mut values=[0u32;6];for(depth,&index)in ids.iter().enumerate(){let row=self.counts[index];if row[k..].iter().any(|&v|v!=0) || row.iter().map(|&v|u64::from(v)).sum::<u64>()>=u64::from(CAP){return Err("hist tail/CAP".into());}values[depth]=row[child].checked_add(1).ok_or("hist count overflow")?;}
        for(depth,&index)in ids.iter().enumerate(){self.counts[index][child]=values[depth];}Ok(())
    }
    pub fn capacity_bytes(&self)->usize{self.counts.capacity()*std::mem::size_of::<[u32;4]>()+std::mem::size_of::<Self>()}
}
pub fn quantize(counts:[u32;4],k:usize)->Result<[u16;4]>{
    if !(2..=4).contains(&k) || counts[k..].iter().any(|&v|v!=0){return Err("quantization prefix/tail".into());}
    let raw=counts.iter().map(|&v|u64::from(v)).sum::<u64>();if raw>u64::from(CAP){return Err("quantization raw CAP".into());}
    let weights=if raw==0{[1u32;4]}else{counts};let total=if raw==0{k as u64}else{raw};let budget=32768-2*k as u64;
    let mut result=[0u16;4];let mut remainders=[0u64;4];let mut used=0u64;
    for i in 0..k{let product=budget.checked_mul(u64::from(weights[i])).ok_or("Hamilton product overflow")?;let floor=product/total;remainders[i]=product%total;result[i]=u16::try_from(floor+2).map_err(|_|"Hamilton frequency range")?;used+=floor;}
    let left=usize::try_from(budget-used).map_err(|_|"Hamilton leftover")?;if left>=k{return Err("Hamilton leftover bound".into());}
    let mut order=[0usize,1,2,3];order[..k].sort_by(|&a,&b|remainders[b].cmp(&remainders[a]).then(a.cmp(&b)));
    for &i in &order[..left]{result[i]=result[i].checked_add(1).ok_or("Hamilton add overflow")?;}valid_frequency(result,k)?;Ok(result)
}
#[derive(Clone,Copy,Default)]
struct Node {frequency:[u16;4],split:bool,loss:f64,bits:usize}
pub struct Fit {nodes:Vec<Node>}
impl Fit {
    pub fn build(hist:&Hist)->Result<Self>{
        if hist.counts.len()!=GROUPS*NODES || std::mem::size_of::<Node>()>32{return Err("fit shape/node extent".into());}
        let mut fit=Self{nodes:allocated(GROUPS*NODES,Node::default())?};
        for g in 0..GROUPS{fit.build_node(hist,g,0,0,g%3+2)?;}Ok(fit)
    }
    fn build_node(&mut self,hist:&Hist,g:usize,id:usize,depth:usize,k:usize)->Result<()>{
        if id>=NODES || depth>5{return Err("fit node/depth".into());}let counts=hist.counts[g*NODES+id];let frequency=quantize(counts,k)?;let mut loss=0.0;
        for i in 0..k{if counts[i]!=0{loss+=f64::from(counts[i])*(32768.0/f64::from(frequency[i])).log2();}}
        if !loss.is_finite() || loss<0.0{return Err("fit leaf loss".into());}let mut best=Node{frequency,split:false,loss,bits:1+15*(k-1)};
        if depth<5{let mut sums=[0u64;4];let mut split_loss=0.0;let mut split_bits=1usize;
            for digit in 0..4{let child=4*id+1+digit;for i in 0..4{sums[i]=sums[i].checked_add(u64::from(hist.counts[g*NODES+child][i])).ok_or("hist child sum overflow")?;}self.build_node(hist,g,child,depth+1,k)?;let n=self.nodes[g*NODES+child];split_loss+=n.loss;split_bits=split_bits.checked_add(n.bits).ok_or("fit bit count overflow")?;}
            if sums!=counts.map(u64::from){return Err("hist parent/children mismatch".into());}
            if split_loss+(split_bits as f64) < loss+(best.bits as f64){best.split=true;best.loss=split_loss;best.bits=split_bits;}
        }
        self.nodes[g*NODES+id]=best;Ok(())
    }
    pub fn lookup(&self,class:usize,k:usize,history:u16)->Result<[u16;4]>{let g=group(class,k)?;let mut id=0;for depth in 0..=5{let node=self.nodes.get(g*NODES+id).ok_or("fit lookup node")?;if !node.split{return Ok(node.frequency);}if depth==5{return Err("fit split beyond depth".into());}id=4*id+1+((history>>(2*depth))&3) as usize;}Err("fit lookup terminal".into())}
    pub fn loss_bits(&self)->f64{self.nodes.chunks_exact(NODES).map(|v|v[0].loss).sum()}
    pub fn selected_header_bits(&self)->usize{self.nodes.chunks_exact(NODES).map(|v|v[0].bits).sum()}
    fn selected_counts(&self,g:usize,id:usize)->(usize,usize){let node=self.nodes[g*NODES+id];if !node.split{(1,0)}else{let mut leaves=0;let mut splits=1;for d in 0..4{let(a,b)=self.selected_counts(g,4*id+1+d);leaves+=a;splits+=b;}(leaves,splits)}}
    pub fn selected_leaf_count(&self)->usize{(0..GROUPS).map(|g|self.selected_counts(g,0).0).sum()}
    pub fn selected_split_count(&self)->usize{(0..GROUPS).map(|g|self.selected_counts(g,0).1).sum()}
    pub fn capacity_bytes(&self)->usize{self.nodes.capacity()*std::mem::size_of::<Node>()+std::mem::size_of::<Self>()}
    pub fn node_size()->usize{std::mem::size_of::<Node>()}
    pub fn serialize(&self)->Result<(Vec<u8>,usize)>{let bits=self.selected_header_bits();if bits==0 || bits>MAX_BITS{return Err("serialized model bit bound".into());}let mut writer=Writer{bytes:allocated(bits.div_ceil(8),0u8)?,position:0};for g in 0..GROUPS{self.write_node(g,0,0,g%3+2,&mut writer)?;}if writer.position!=bits || writer.bytes.len()>MAX_BYTES{return Err("serialized exact bit count".into());}Ok((writer.bytes,bits))}
    fn write_node(&self,g:usize,id:usize,depth:usize,k:usize,w:&mut Writer)->Result<()>{let n=self.nodes[g*NODES+id];w.write(u32::from(n.split),1)?;if n.split{if depth>=5{return Err("serialize split depth".into());}for d in 0..4{self.write_node(g,4*id+1+d,depth+1,k,w)?;}}else{valid_frequency(n.frequency,k)?;for &f in &n.frequency[..k-1]{w.write(u32::from(f),15)?;}}Ok(())}
}
struct Writer {bytes:Vec<u8>,position:usize}
impl Writer {fn write(&mut self,value:u32,width:usize)->Result<()>{if width>31 || value>=1u32<<width || self.position.checked_add(width).ok_or("writer offset overflow")?>self.bytes.len()*8{return Err("writer range".into());}for shift in (0..width).rev(){if value&(1<<shift)!=0{self.bytes[self.position/8]|=1<<(7-self.position%8);}self.position+=1;}Ok(())}}
pub struct Dispatch {frequencies:Vec<[u16;4]>}
impl Dispatch {pub fn lookup(&self,class:usize,k:usize,history:u16)->Result<[u16;4]>{let g=group(class,k)?;self.frequencies.get(g*HISTORIES+(history as usize&1023)).copied().ok_or("dispatch range".into())}pub fn capacity_bytes(&self)->usize{self.frequencies.capacity()*std::mem::size_of::<[u16;4]>()+std::mem::size_of::<Self>()}}
struct Reader<'a>{bytes:&'a[u8],bits:usize,position:usize}
impl Reader<'_>{fn read(&mut self,width:usize)->Result<u32>{if width>31 || self.position.checked_add(width).ok_or("reader offset overflow")?>self.bits{return Err("truncated model field".into());}let mut value=0u32;for _ in 0..width{value=(value<<1)|u32::from((self.bytes[self.position/8]>>(7-self.position%8))&1);self.position+=1;}Ok(value)}}
pub fn parse(bytes:&[u8],bits:usize)->Result<Dispatch>{
    if bits==0 || bits>MAX_BITS || bytes.len()!=bits.div_ceil(8) || bytes.len()>MAX_BYTES{return Err("model exact bytes/bits".into());}
    if bits%8!=0 && bytes.last().copied().ok_or("empty model")?&((1u8<<(8-bits%8))-1)!=0{return Err("model padding".into());}
    let mut reader=Reader{bytes,bits,position:0};let mut dispatch=Dispatch{frequencies:allocated(GROUPS*HISTORIES,[0;4])?};
    for g in 0..GROUPS{parse_node(&mut reader,&mut dispatch,g,0,0,g%3+2)?;}
    if reader.position!=bits{return Err("model trailing bits".into());}for(g,rows)in dispatch.frequencies.chunks_exact(HISTORIES).enumerate(){for &f in rows{valid_frequency(f,g%3+2)?;}}Ok(dispatch)
}
fn parse_node(reader:&mut Reader<'_>,dispatch:&mut Dispatch,g:usize,depth:usize,path:usize,k:usize)->Result<()>{
    if reader.read(1)?==1{if depth>=5{return Err("model split beyond depth5".into());}for digit in 0..4{parse_node(reader,dispatch,g,depth+1,path|(digit<<(2*depth)),k)?;}}
    else{let mut f=[0u16;4];let mut used=0u32;for value in &mut f[..k-1]{let raw=reader.read(15)?;if raw<2{return Err("parsed frequency minimum".into());}used=used.checked_add(raw).ok_or("parsed sum overflow")?;*value=u16::try_from(raw).map_err(|_|"parsed frequency range")?;}f[k-1]=u16::try_from(32768u32.checked_sub(used).ok_or("parsed last underflow")?).map_err(|_|"parsed last range")?;valid_frequency(f,k)?;
        let mask=(1usize<<(2*depth))-1;for history in 0..HISTORIES{if history&mask==path{let slot=&mut dispatch.frequencies[g*HISTORIES+history];if *slot!=[0;4]{return Err("parsed duplicate dispatch".into());}*slot=f;}}}
    Ok(())
}
