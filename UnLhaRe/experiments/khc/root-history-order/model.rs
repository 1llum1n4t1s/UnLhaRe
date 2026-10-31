type Result<T>=std::result::Result<T,String>;
pub const NODES:usize=1365;
pub const GROUPS:usize=3;
pub const HISTORIES:usize=1024;
pub const CAP:u32=3825340;
pub const MAX_BITS:usize=142338;
pub const MAX_BYTES:usize=17793;
fn allocated<T:Clone>(len:usize,value:T)->Result<Vec<T>>{let mut v=Vec::new();v.try_reserve_exact(len).map_err(|_|"model allocation")?;v.resize(len,value);Ok(v)}
fn group(class:usize,k:usize)->Result<usize>{if class!=0 || !(2..=4).contains(&k){return Err("model class/prefix".into());}Ok(class*3+k-2)}
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


// 固定整数LUT。float生成・精度sweepは行わない。
const fn make_lut()->[u16;256]{
    let mut v=[0u16;256];let mut i=0;while i<64{v[i]=(i+2) as u16;i+=1;}
    let mut e=6;while e<=13{let base=1u32<<e;let mut j=1;while j<=24{
        let value=base+(j*base+23)/24;v[i]=if value>16383{16383}else{value as u16};i+=1;j+=1;
    }e+=1;}v
}
pub const MINOR_LUT:[u16;256]=make_lut();
pub fn validate_lut()->Result<()>{
    if MINOR_LUT[0]!=2 || MINOR_LUT[255]!=16383 || MINOR_LUT.windows(2).any(|x|x[0]>=x[1]){return Err("minor LUT monotone/endpoints".into());}Ok(())
}
pub fn floor_code(value:u16)->Result<u8>{
    if !(2..=16383).contains(&value){return Err("minor range".into());}
    let i=MINOR_LUT.partition_point(|&v|v<=value)-1;u8::try_from(i).map_err(|_|"minor code".into())
}
fn largest(f:[u16;4],k:usize)->usize{let mut d=0;for i in 1..k{if f[i]>f[d]{d=i;}}d}
pub fn compact_frequency(original:[u16;4],k:usize)->Result<[u16;4]>{
    valid_frequency(original,k)?;let(mode,_)=leaf_mode(original,k)?;if mode<2{return Ok(original);}
    let dominant=largest(original,k);let mut f=[0u16;4];let mut sum=0u32;
    for i in 0..k{if i!=dominant{f[i]=MINOR_LUT[usize::from(floor_code(original[i])?)];sum=sum.checked_add(u32::from(f[i])).ok_or("minor sum overflow")?;}}
    f[dominant]=u16::try_from(32768u32.checked_sub(sum).ok_or("minor residual underflow")?).map_err(|_|"minor residual range")?;
    valid_frequency(f,k)?;if f[dominant]<original[dominant] || f[..k].iter().any(|&v|v>f[dominant]){return Err("minor dominant invariant".into());}Ok(f)
}
// minor leafの厳密mode：uniform優先、pure完全一致、それ以外はcompact。
pub fn leaf_mode(f:[u16;4],k:usize)->Result<(u32,usize)>{
    valid_frequency(f,k)?;
    if f==quantize([0;4],k)?{return Ok((0,0));}
    for dominant in 0..k{let mut p=[0u16;4];p[..k].fill(2);p[dominant]=32768-2*(k as u16-1);if f==p{return Ok((1,dominant));}}
    Ok((2,largest(f,k)))
}
fn leaf_bits(f:[u16;4],k:usize)->Result<usize>{
    Ok(match leaf_mode(f,k)?.0{0=>3,1=>3+if k==2{1}else{2},2=>3+(if k==2{1}else{2})+8*(k-1),_=>return Err("leaf mode".into())})
}
#[derive(Clone,Copy,Default)]
struct Node {frequency:[u16;4],split:bool,loss:f64,bits:usize}
pub struct Fit {nodes:Vec<Node>,high:bool}
impl Fit {
    pub fn build(hist:&Hist)->Result<Self>{Self::build_order(hist,false)}
    pub fn build_high(hist:&Hist)->Result<Self>{Self::build_order(hist,true)}
    fn build_order(hist:&Hist,high:bool)->Result<Self>{
        if hist.counts.len()!=GROUPS*NODES || std::mem::size_of::<Node>()>32{return Err("fit shape/node extent".into());}
        let mut fit=Self{nodes:allocated(GROUPS*NODES,Node::default())?,high};
        for g in 0..GROUPS{fit.build_node(hist,g,0,0,g%3+2)?;}Ok(fit)
    }
    fn build_node(&mut self,hist:&Hist,g:usize,id:usize,depth:usize,k:usize)->Result<()>{
        if id>=NODES || depth>5{return Err("fit node/depth".into());}let counts=hist.counts[g*NODES+id];let frequency=compact_frequency(quantize(counts,k)?,k)?;let mut loss=0.0;
        for i in 0..k{if counts[i]!=0{loss+=f64::from(counts[i])*(32768.0/f64::from(frequency[i])).log2();}}
        if !loss.is_finite() || loss<0.0{return Err("fit leaf loss".into());}let mut best=Node{frequency,split:false,loss,bits:if depth==0 && frequency==quantize([0;4],k)?{0}else{leaf_bits(frequency,k)?}};
        if depth<5{let mut sums=[0u64;4];let mut split_loss=0.0;let mut split_bits=if depth==0{2usize}else{1usize};
            for digit in 0..4{let child=4*id+1+digit;for i in 0..4{sums[i]=sums[i].checked_add(u64::from(hist.counts[g*NODES+child][i])).ok_or("hist child sum overflow")?;}self.build_node(hist,g,child,depth+1,k)?;let n=self.nodes[g*NODES+child];split_loss+=n.loss;split_bits=split_bits.checked_add(n.bits).ok_or("fit bit count overflow")?;}
            if sums!=counts.map(u64::from){return Err("hist parent/children mismatch".into());}
            if split_loss+(split_bits as f64) < loss+(best.bits as f64){best.split=true;best.loss=split_loss;best.bits=split_bits;}
        }
        self.nodes[g*NODES+id]=best;Ok(())
    }
    pub fn lookup(&self,class:usize,k:usize,history:u16)->Result<[u16;4]>{let g=group(class,k)?;let history=if self.high{reverse_history(history)}else{history};let mut id=0;for depth in 0..=5{let node=self.nodes.get(g*NODES+id).ok_or("fit lookup node")?;if !node.split{return Ok(node.frequency);}if depth==5{return Err("fit split beyond depth".into());}id=4*id+1+((history>>(2*depth))&3) as usize;}Err("fit lookup terminal".into())}
    pub fn loss_bits(&self)->f64{self.nodes.chunks_exact(NODES).map(|v|v[0].loss).sum()}
    pub fn selected_header_bits(&self)->usize{self.nodes.chunks_exact(NODES).map(|v|if v[0].bits==0{3}else{v[0].bits}).sum()}
    fn selected_counts(&self,g:usize,id:usize)->(usize,usize){let node=self.nodes[g*NODES+id];if !node.split{(1,0)}else{let mut leaves=0;let mut splits=1;for d in 0..4{let(a,b)=self.selected_counts(g,4*id+1+d);leaves+=a;splits+=b;}(leaves,splits)}}
    pub fn selected_leaf_count(&self)->usize{(0..GROUPS).map(|g|self.selected_counts(g,0).0).sum()}
    pub fn selected_split_count(&self)->usize{(0..GROUPS).map(|g|self.selected_counts(g,0).1).sum()}
    pub fn capacity_bytes(&self)->usize{self.nodes.capacity()*std::mem::size_of::<Node>()+std::mem::size_of::<Self>()}
    pub fn node_size()->usize{std::mem::size_of::<Node>()}
    pub fn serialize(&self)->Result<(Vec<u8>,usize)>{let bits=self.selected_header_bits();if bits==0 || bits>MAX_BITS{return Err("serialized model bit bound".into());}let mut writer=Writer{bytes:allocated(bits.div_ceil(8),0u8)?,position:0};for g in 0..GROUPS{self.write_node(g,0,0,g%3+2,&mut writer)?;}if writer.position!=bits || writer.bytes.len()>MAX_BYTES{return Err("serialized exact bit count".into());}Ok((writer.bytes,bits))}
    fn write_node(&self,g:usize,id:usize,depth:usize,k:usize,w:&mut Writer)->Result<()>{let n=self.nodes[g*NODES+id];w.write(u32::from(n.split),1)?;if n.split{if depth==0{w.write(u32::from(self.high),1)?;}if depth>=5{return Err("serialize split depth".into());}for d in 0..4{self.write_node(g,4*id+1+d,depth+1,k,w)?;}}else{valid_frequency(n.frequency,k)?;let(mode,dominant)=leaf_mode(n.frequency,k)?;w.write(mode,2)?;match mode{0=>(),1=>w.write(dominant as u32,if k==2{1}else{2})?,2=>{w.write(dominant as u32,if k==2{1}else{2})?;for i in 0..k{if i!=dominant{let code=floor_code(n.frequency[i])?;if MINOR_LUT[usize::from(code)]!=n.frequency[i]{return Err("compact writer off-grid".into());}w.write(u32::from(code),8)?;}}},_=>return Err("serialize reserved mode".into())}}Ok(())}
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
    if reader.read(1)?==1{if depth>=5{return Err("model split beyond depth5".into());}
        let high=depth==0 && reader.read(1)?==1;
        for digit in 0..4{parse_node(reader,dispatch,g,depth+1,path|(digit<<(2*depth)),k)?;}
        // tree座標で完成させたrootだけを元history indexへ戻す。内部mask条件を流用しない。
        if high{for h in 0..HISTORIES{let reversed=usize::from(reverse_history(h as u16));if h<reversed{dispatch.frequencies.swap(g*HISTORIES+h,g*HISTORIES+reversed);}}}
    }
    else{let mode=reader.read(2)?;let mut f=[0u16;4];match mode{0=>f=quantize([0;4],k)?,1=>{let dominant=reader.read(if k==2{1}else{2})? as usize;if dominant>=k{return Err("pure dominant index".into());}f[..k].fill(2);f[dominant]=32768-2*(k as u16-1);},2=>{let dominant=reader.read(if k==2{1}else{2})? as usize;if dominant>=k{return Err("compact dominant index".into());}let mut used=0u32;
        for i in 0..k{if i!=dominant{let code=reader.read(8)? as usize;f[i]=MINOR_LUT[code];used=used.checked_add(u32::from(f[i])).ok_or("compact minor sum")?;}}
        f[dominant]=u16::try_from(32768u32.checked_sub(used).ok_or("compact residual underflow")?).map_err(|_|"compact residual range")?;
        if f[dominant]<2 || f[..k].iter().any(|&v|v>f[dominant]){return Err("compact residual largest/minimum".into());}},_=>return Err("reserved leaf mode".into())}valid_frequency(f,k)?;
        let mask=(1usize<<(2*depth))-1;for history in 0..HISTORIES{if history&mask==path{let slot=&mut dispatch.frequencies[g*HISTORIES+history];if *slot!=[0;4]{return Err("parsed duplicate dispatch".into());}*slot=f;}}}
    Ok(())
}

// 短いleaf root拡張：Hist/quantizeを保持し、DP費用0とoracle wire3bitを区別。
pub fn uniform(k:usize)->Result<[u16;4]>{quantize([0;4],k)}
impl Fit {
    pub fn root_loss(&self,k:usize)->Result<f64>{Ok(self.nodes[group(0,k)?*NODES].loss)}
    pub fn root_default(&self,k:usize)->Result<bool>{let n=self.nodes[group(0,k)?*NODES];Ok(!n.split && n.frequency==uniform(k)?)}
    pub fn root_wire(&self,k:usize)->Result<(Vec<u8>,usize)>{
        let g=group(0,k)?;let objective=self.nodes[g*NODES].bits;let bits=if objective==0{3}else{objective};
        if bits==0 || bits>MAX_BITS{return Err("root bit bound".into());}
        let mut w=Writer{bytes:allocated(bits.div_ceil(8),0u8)?,position:0};
        self.write_node(g,0,0,k,&mut w)?;
        if w.position!=bits || w.bytes.capacity()>MAX_BYTES{return Err("root writer extent".into());}
        Ok((w.bytes,bits))
    }
}
pub fn parse_root(bytes:&[u8],bits:usize,k:usize)->Result<Dispatch>{
    let g=group(0,k)?;
    if bits==0 || bits>MAX_BITS || bytes.len()!=bits.div_ceil(8) || bytes.len()>MAX_BYTES{return Err("root exact extent".into());}
    if bits%8!=0 && bytes.last().copied().ok_or("root empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("root padding".into());}
    let mut r=Reader{bytes,bits,position:0};
    let mut d=Dispatch{frequencies:allocated(GROUPS*HISTORIES,[0;4])?};
    parse_node(&mut r,&mut d,g,0,0,k)?;
    if r.position!=bits{return Err("root trailing bits".into());}Ok(d)
}
pub fn parse_packet_node(bytes:&[u8],bits:usize,position:&mut usize)->Result<(Dispatch,usize)>{
    if bits>bytes.len()*8 || *position>bits{return Err("packet reader extent".into());}
    let mut r=Reader{bytes,bits,position:*position};
    let mut d=Dispatch{frequencies:allocated(GROUPS*HISTORIES,[0;4])?};let mut defaults=0;
    for k in 2..=4{let g=k-2;
        if r.read(1)?==0{let f=uniform(k)?;for h in 0..HISTORIES{d.frequencies[g*HISTORIES+h]=f;}defaults+=1;}
        else{parse_node(&mut r,&mut d,g,0,0,k)?;}
    }
    *position=r.position;Ok((d,defaults))
}
impl Fit {
    pub fn root_objective_bits(&self,k:usize)->Result<usize>{Ok(self.nodes[group(0,k)?*NODES].bits)}
    fn mode_counts(&self,g:usize,id:usize,k:usize,out:&mut[usize;3])->Result<()>{
        let n=self.nodes[g*NODES+id];if n.split{for d in 0..4{self.mode_counts(g,4*id+1+d,k,out)?;}}
        else{out[leaf_mode(n.frequency,k)?.0 as usize]+=1;}Ok(())
    }
    pub fn selected_mode_counts(&self)->Result<[usize;3]>{let mut out=[0;3];for k in 2..=4{self.mode_counts(k-2,0,k,&mut out)?;}Ok(out)}
}
// 新DPで選択した同じ木の原Qloss。旧選択木との比較ではない。
impl Fit{
    fn original_node_loss(&self,hist:&Hist,g:usize,id:usize,k:usize)->Result<f64>{
        if self.nodes[g*NODES+id].split{let mut sum=0.0;for d in 0..4{sum+=self.original_node_loss(hist,g,4*id+1+d,k)?;}Ok(sum)}
        else{let row=hist.counts[g*NODES+id];let f=quantize(row,k)?;let mut loss=0.0;for i in 0..k{if row[i]!=0{loss+=f64::from(row[i])*(32768.0/f64::from(f[i])).log2();}}Ok(loss)}
    }
    pub fn original_selected_loss(&self,hist:&Hist)->Result<f64>{
        if hist.counts.len()!=GROUPS*NODES{return Err("original selected Hist shape".into());}
        let mut loss=0.0;for k in 2..=4{loss+=self.original_node_loss(hist,k-2,0,k)?;}Ok(loss)
    }
}
// 固定5digit反転。grammar履歴やDense indexは変更しない。
pub fn reverse_history(history:u16)->u16{
    let mut result=0;for d in 0..5{result|=((history>>(2*d))&3)<<(2*(4-d));}result
}
impl Fit{
    pub fn root_split(&self,k:usize)->Result<bool>{Ok(self.nodes[group(0,k)?*NODES].split)}
}
pub struct Selected<'a>{low:&'a Fit,high:&'a Fit,high_roots:[bool;3]}
impl<'a> Selected<'a>{
    pub fn new(low:&'a Fit,high:&'a Fit)->Result<Self>{
        if low.high || !high.high{return Err("selection low/high identity".into());}
        let mut high_roots=[false;3];for k in 2..=4{
            let low_cost=low.root_loss(k)?+low.root_objective_bits(k)? as f64;
            let high_cost=high.root_loss(k)?+high.root_objective_bits(k)? as f64;
            high_roots[k-2]=high_cost<low_cost;
        }Ok(Self{low,high,high_roots})
    }
    fn chosen(&self,k:usize)->Result<&Fit>{let g=group(0,k)?;Ok(if self.high_roots[g]{self.high}else{self.low})}
    pub fn root_high(&self,k:usize)->Result<bool>{let g=group(0,k)?;Ok(self.high_roots[g])}
    pub fn root_split(&self,k:usize)->Result<bool>{self.chosen(k)?.root_split(k)}
    pub fn root_order_bits(&self,k:usize)->Result<usize>{Ok(usize::from(self.root_split(k)?))}
    pub fn root_default(&self,k:usize)->Result<bool>{self.chosen(k)?.root_default(k)}
    pub fn root_objective_bits(&self,k:usize)->Result<usize>{self.chosen(k)?.root_objective_bits(k)}
    pub fn root_loss(&self,k:usize)->Result<f64>{self.chosen(k)?.root_loss(k)}
    pub fn root_wire(&self,k:usize)->Result<(Vec<u8>,usize)>{self.chosen(k)?.root_wire(k)}
    pub fn lookup(&self,class:usize,k:usize,history:u16)->Result<[u16;4]>{self.chosen(k)?.lookup(class,k,history)}
    pub fn loss_bits(&self)->Result<f64>{let mut sum=0.0;for k in 2..=4{sum+=self.root_loss(k)?;}Ok(sum)}
    pub fn original_selected_loss(&self,low:&Hist,high:&Hist)->Result<f64>{
        if low.counts.len()!=GROUPS*NODES || high.counts.len()!=GROUPS*NODES{return Err("selected Hist shape".into());}
        let mut sum=0.0;for k in 2..=4{let hist=if self.root_high(k)?{high}else{low};sum+=self.chosen(k)?.original_node_loss(hist,k-2,0,k)?;}Ok(sum)
    }
    pub fn selected_leaf_count(&self)->Result<usize>{let mut sum=0;for k in 2..=4{sum+=self.chosen(k)?.selected_counts(k-2,0).0;}Ok(sum)}
    pub fn selected_split_count(&self)->Result<usize>{let mut sum=0;for k in 2..=4{sum+=self.chosen(k)?.selected_counts(k-2,0).1;}Ok(sum)}
    pub fn selected_mode_counts(&self)->Result<[usize;3]>{let mut out=[0;3];for k in 2..=4{self.chosen(k)?.mode_counts(k-2,0,k,&mut out)?;}Ok(out)}
}

