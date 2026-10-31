//! 固定有料minor長を目的へ入れた木選択。数値処理は凍結実装を参照する。
use crate::{model as original,codebook::{self,Encoder,Decoder,Writer,Reader}};
pub use original::{Hist,quantize,compact_frequency,leaf_mode,floor_code,MINOR_LUT,validate_lut,NODES,GROUPS,HISTORIES,CAP,MAX_BITS,MAX_BYTES};
type Result<T>=std::result::Result<T,String>;
fn allocated<T:Clone>(len:usize,value:T)->Result<Vec<T>>{let mut v=Vec::new();v.try_reserve_exact(len).map_err(|_|"paid model allocation")?;v.resize(len,value);Ok(v)}
fn group(class:usize,k:usize)->Result<usize>{if class!=0 || !(2..=4).contains(&k){return Err("model class/prefix".into());}Ok(k-2)}
fn valid_frequency(f:[u16;4],k:usize)->Result<()>{if !(2..=4).contains(&k) || f[..k].iter().any(|&v|v<2) || f[k..].iter().any(|&v|v!=0) || f[..k].iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("CDF support/total/tail".into());}Ok(())}
fn leaf_bits(f:[u16;4],k:usize)->Result<usize>{
    let(mode,dominant)=leaf_mode(f,k)?;
    let width=if k==2{1}else{2};
    match mode{0=>Ok(3),1=>Ok(3+width),2=>{
        let mut bits=2+width;
        for i in 0..k{if i!=dominant{bits+=codebook::fee(floor_code(f[i])?);}}
        Ok(bits)
    },_=>Err("leaf mode".into())}
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
    pub fn serialize(&self,book:&Encoder)->Result<(Vec<u8>,usize)>{let bits=self.selected_header_bits();if bits==0 || bits>MAX_BITS{return Err("serialized model bit bound".into());}let mut writer=Writer::new(bits)?;for g in 0..GROUPS{self.write_node(g,0,0,g%3+2,&mut writer,book)?;}if writer.position!=bits || writer.bytes.len()>MAX_BYTES{return Err("serialized exact bit count".into());}Ok((writer.bytes,bits))}
    fn write_node(&self,g:usize,id:usize,depth:usize,k:usize,w:&mut Writer,book:&Encoder)->Result<()>{let n=self.nodes[g*NODES+id];w.write(u32::from(n.split),1)?;if n.split{if depth==0{w.write(u32::from(self.high),1)?;}if depth>=5{return Err("serialize split depth".into());}for d in 0..4{self.write_node(g,4*id+1+d,depth+1,k,w,book)?;}}else{valid_frequency(n.frequency,k)?;let(mode,dominant)=leaf_mode(n.frequency,k)?;match mode{0=>w.write(3,2)?,1=>w.write(2,2)?,2=>w.write(0,1)?,_=>return Err("serialize mode".into())}match mode{0=>(),1=>w.write(dominant as u32,if k==2{1}else{2})?,2=>{w.write(dominant as u32,if k==2{1}else{2})?;for i in 0..k{if i!=dominant{let code=floor_code(n.frequency[i])?;if MINOR_LUT[usize::from(code)]!=n.frequency[i]{return Err("compact writer off-grid".into());}book.write(code,w)?;}}},_=>return Err("serialize reserved mode".into())}}Ok(())}
}
// 短いleaf root拡張：Hist/quantizeを保持し、DP費用0とoracle wire3bitを区別。
pub fn uniform(k:usize)->Result<[u16;4]>{quantize([0;4],k)}
impl Fit {
    pub fn root_loss(&self,k:usize)->Result<f64>{Ok(self.nodes[group(0,k)?*NODES].loss)}
    pub fn root_default(&self,k:usize)->Result<bool>{let n=self.nodes[group(0,k)?*NODES];Ok(!n.split && n.frequency==uniform(k)?)}
    pub fn root_wire(&self,k:usize,book:&Encoder)->Result<(Vec<u8>,usize)>{
        let g=group(0,k)?;let objective=self.nodes[g*NODES].bits;let bits=if objective==0{3}else{objective};
        if bits==0 || bits>MAX_BITS{return Err("root bit bound".into());}
        let mut w=Writer::new(bits)?;
        self.write_node(g,0,0,k,&mut w,book)?;
        if w.position!=bits || w.bytes.capacity()>MAX_BYTES{return Err("root writer extent".into());}
        Ok((w.bytes,bits))
    }
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
    pub fn root_wire(&self,k:usize,book:&Encoder)->Result<(Vec<u8>,usize)>{self.chosen(k)?.root_wire(k,book)}
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



pub struct Dispatch {frequencies:Vec<[u16;4]>}
impl Dispatch {
    pub fn lookup(&self,class:usize,k:usize,h:u16)->Result<[u16;4]>{let g=group(class,k)?;self.frequencies.get(g*HISTORIES+(h as usize&1023)).copied().ok_or("dispatch range".into())}
    pub fn capacity_bytes(&self)->usize{std::mem::size_of::<Self>()+self.frequencies.capacity()*std::mem::size_of::<[u16;4]>()}
}
fn parse_node(r:&mut Reader<'_>,d:&mut Dispatch,g:usize,depth:usize,path:usize,k:usize,book:&Decoder)->Result<()>{
    if r.read(1)?==1 {
        if depth>=5{return Err("paid split beyond depth5".into());}
        let high=depth==0 && r.read(1)?==1;
        for digit in 0..4{parse_node(r,d,g,depth+1,path|(digit<<(2*depth)),k,book)?;}
        if high{for h in 0..HISTORIES{let reversed=usize::from(reverse_history(h as u16));if h<reversed{d.frequencies.swap(g*HISTORIES+h,g*HISTORIES+reversed);}}}
    } else {
        let mode=if r.read(1)?==0{2}else if r.read(1)?==0{1}else{0};
        let mut f=[0u16;4];
        match mode{
            0=>f=uniform(k)?,
            1=>{let dominant=r.read(if k==2{1}else{2})? as usize;if dominant>=k{return Err("pure dominant index".into());}f[..k].fill(2);f[dominant]=32768-2*(k as u16-1);},
            _=>{let dominant=r.read(if k==2{1}else{2})? as usize;if dominant>=k{return Err("compact dominant index".into());}let mut used=0u32;
                for i in 0..k{if i!=dominant{f[i]=MINOR_LUT[usize::from(book.read(r)?)];used=used.checked_add(u32::from(f[i])).ok_or("compact minor sum")?;}}
                f[dominant]=u16::try_from(32768u32.checked_sub(used).ok_or("compact residual underflow")?).map_err(|_|"compact residual range")?;
                if f[dominant]<2 || f[..k].iter().any(|&v|v>f[dominant]){return Err("compact residual largest/minimum".into());}
            }
        }
        valid_frequency(f,k)?;let mask=(1usize<<(2*depth))-1;
        for h in 0..HISTORIES{if h&mask==path{let slot=&mut d.frequencies[g*HISTORIES+h];if *slot!=[0;4]{return Err("parsed duplicate dispatch".into());}*slot=f;}}
    } Ok(())
}
pub fn parse_root(bytes:&[u8],bits:usize,k:usize,book:&Decoder)->Result<Dispatch>{
    let g=group(0,k)?;if bits==0 || bits>MAX_BITS || bytes.len()!=bits.div_ceil(8) || bytes.len()>MAX_BYTES{return Err("root exact extent".into());}
    if bits%8!=0 && bytes.last().copied().ok_or("root empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("root padding".into());}
    let mut r=Reader{bytes,bits,position:0};let mut d=Dispatch{frequencies:allocated(GROUPS*HISTORIES,[0;4])?};
    parse_node(&mut r,&mut d,g,0,0,k,book)?;if r.position!=bits{return Err("root trailing bits".into());}Ok(d)
}
pub fn parse_packet_node(r:&mut Reader<'_>,book:&Decoder)->Result<(Dispatch,usize)>{
    let mut d=Dispatch{frequencies:allocated(GROUPS*HISTORIES,[0;4])?};let mut defaults=0;
    for k in 2..=4{let g=k-2;if r.read(1)?==0{for h in 0..HISTORIES{d.frequencies[g*HISTORIES+h]=uniform(k)?;}defaults+=1;}else{parse_node(r,&mut d,g,0,0,k,book)?;}}
    Ok((d,defaults))
}
#[derive(Clone,Copy,Default)]
pub struct Repriced {pub bits:usize,pub loss:f64,pub minor_count:usize,pub escapes:usize,pub node_comparisons:usize,pub cdfs:usize,pub packet_capacity:usize,pub dispatch_capacity:usize}
fn no_worse(new:f64,old:f64)->Result<()>{if !new.is_finite() || !old.is_finite() || new>old+1e-6{return Err(format!("paid objective worsened {new} > {old}"));}Ok(())}
fn reprice_node(r:&mut Reader<'_>,new:&Fit,hist:&Hist,g:usize,id:usize,depth:usize,k:usize)->Result<Repriced>{
    let n=new.nodes[g*NODES+id];let mut out=Repriced::default();
    if r.read(1)?==1{
        if depth>=5{return Err("baseline split depth".into());}out.bits=if depth==0{2}else{1};
        if depth==0 && (r.read(1)?==1)!=new.high{return Err("baseline order identity".into());}
        for digit in 0..4{let child=reprice_node(r,new,hist,g,4*id+1+digit,depth+1,k)?;out.bits+=child.bits;out.loss+=child.loss;out.minor_count+=child.minor_count;out.escapes+=child.escapes;out.node_comparisons+=child.node_comparisons;}
    }else{
        let mode=r.read(2)?;let mut f=[0u16;4];out.bits=3;
        match mode{
            0=>f=uniform(k)?,
            1=>{let width=if k==2{1}else{2};let dominant=r.read(width)? as usize;if dominant>=k{return Err("baseline pure dominant".into());}out.bits+=width;f[..k].fill(2);f[dominant]=32768-2*(k as u16-1);},
            2=>{let width=if k==2{1}else{2};let dominant=r.read(width)? as usize;if dominant>=k{return Err("baseline compact dominant".into());}out.bits=2+width;let mut used=0;
                for i in 0..k{if i!=dominant{let code=r.read(8)? as u8;out.bits+=codebook::fee(code);out.minor_count+=1;out.escapes+=usize::from(codebook::LENGTHS[usize::from(code)]==0);f[i]=MINOR_LUT[usize::from(code)];used+=u32::from(f[i]);}}
                f[dominant]=u16::try_from(32768u32.checked_sub(used).ok_or("baseline residual underflow")?).map_err(|_|"baseline residual range")?;
                if f[..k].iter().any(|&v|v>f[dominant]){return Err("baseline residual largest".into());}
            },
            _=>return Err("baseline mode".into())
        }
        valid_frequency(f,k)?;if f!=n.frequency{return Err("baseline leaf/new quantized frequency".into());}
        for i in 0..k{let count=hist.counts[g*NODES+id][i];if count!=0{out.loss+=f64::from(count)*(32768.0/f64::from(f[i])).log2();}}
        if depth==0 && f==uniform(k)?{out.bits=0;}
    }
    no_worse(n.loss+n.bits as f64,out.loss+out.bits as f64)?;out.node_comparisons+=1;Ok(out)
}
impl Fit{
    pub fn reprice_old(&self,old:&original::Fit,hist:&Hist,k:usize)->Result<Repriced>{
        let (bytes,bits)=old.root_wire(k)?;let dispatch=original::parse_root(&bytes,bits,k)?;
        let mut r=Reader{bytes:&bytes,bits,position:0};let mut out=reprice_node(&mut r,self,hist,k-2,0,0,k)?;
        out.packet_capacity=bytes.capacity()+std::mem::size_of::<Vec<u8>>();out.dispatch_capacity=dispatch.capacity_bytes();
        if r.position!=bits || (out.loss-old.root_loss(k)?).abs()>1e-6{return Err("baseline exact wire/loss".into());}
        if old.root_default(k)?!=(out.bits==0){return Err("baseline default fee".into());}
        let mut weighted_loss=0.0;
        for h in 0..1024u16{let f=dispatch.lookup(0,k,h)?;if f!=old.lookup(0,k,h)?{return Err("baseline wire/old Fit CDF".into());}
            let history=if self.high{reverse_history(h)}else{h};let mut id=0;
            for depth in 0..5{id=4*id+1+((history>>(2*depth))&3) as usize;}
            let row=hist.counts[(k-2)*NODES+id];for i in 0..k{if row[i]!=0{weighted_loss+=f64::from(row[i])*(32768.0/f64::from(f[i])).log2();}}
            out.cdfs+=1;
        }
        if (weighted_loss-out.loss).abs()>1e-6{return Err("baseline parsed CDF weighted loss".into());}
        Ok(out)
    }
}
impl Selected<'_>{
    pub fn assert_root_baseline(&self,k:usize,low:&Repriced,high:&Repriced)->Result<()>{no_worse(self.root_loss(k)?+self.root_objective_bits(k)? as f64,(low.loss+low.bits as f64).min(high.loss+high.bits as f64))}
    pub fn minor_counts(&self)->Result<(usize,usize)>{let mut known=0;let mut escaped=0;for k in 2..=4{self.chosen(k)?.minor_node(k-2,0,k,&mut known,&mut escaped)?;}Ok((known,escaped))}
}
impl Fit{
    fn minor_node(&self,g:usize,id:usize,k:usize,known:&mut usize,escaped:&mut usize)->Result<()>{
        let n=self.nodes[g*NODES+id];if n.split{for d in 0..4{self.minor_node(g,4*id+1+d,k,known,escaped)?;}}
        else{let(mode,dominant)=leaf_mode(n.frequency,k)?;if mode==2{for i in 0..k{if i!=dominant{if codebook::LENGTHS[usize::from(floor_code(n.frequency[i])?)]==0{*escaped+=1;}else{*known+=1;}}}}}Ok(())
    }
}

