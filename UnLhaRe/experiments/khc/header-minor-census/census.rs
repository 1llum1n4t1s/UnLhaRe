//! 旧RAM packetのminor censusと有界Huffman費用診断。実codecは未実装。
use crate::{bundle,model};
type Result<T>=std::result::Result<T,String>;
pub const MAX_MINOR:u32=1708032;
const NONE:u16=u16::MAX;
#[derive(Clone,Copy)]
struct Node{weight:u64,min_symbol:u16,left:u16,right:u16,parent:u16}
pub struct Estimate{
    pub lengths:[u8;256],pub total:u32,pub nonzero:usize,pub max_depth:usize,pub kraft_valid:bool,
    pub weighted_code_bits:u64,pub huffman_valid:bool,pub fallback_reason:&'static str,
    pub raw_bytes:usize,pub huffman_bytes:Option<usize>,pub lower_bound_bytes:Option<usize>,
    pub chosen_bytes:usize,pub chosen_payload_bits:usize,pub chosen_padding_bits:usize,
    pub chosen_table_bytes:usize,pub huffman_chosen:bool,pub temporary_bytes:usize,
}
pub struct Census{
    pub histogram:[u32;256],pub estimate:Estimate,pub payload_bits:usize,pub prefix_payload_bits:usize,
    pub roots:usize,pub defaults:usize,pub splits:usize,pub uniform:usize,pub pure:usize,pub compact:usize,
    pub low_orders:usize,pub high_orders:usize,pub split_field_bits:usize,pub mode_field_bits:usize,
    pub dominant_field_bits:usize,pub minor_field_bits:usize,pub packet_bytes:usize,
}
fn key(nodes:&[Node],id:usize)->(u64,u16,usize){let n=nodes[id];(n.weight,n.min_symbol,id)}
fn push(heap:&mut Vec<usize>,nodes:&[Node],id:usize)->Result<()>{
    if heap.len()>=256{return Err("Huffman heap cap".into());}heap.push(id);let mut at=heap.len()-1;
    while at>0{let parent=(at-1)/2;if key(nodes,heap[parent])<=key(nodes,heap[at]){break;}heap.swap(parent,at);at=parent;}Ok(())
}
fn pop(heap:&mut Vec<usize>,nodes:&[Node])->Result<usize>{
    let top=*heap.first().ok_or("Huffman empty heap")?;let last=heap.pop().ok_or("Huffman pop")?;
    if !heap.is_empty(){heap[0]=last;let mut at=0;loop{let left=2*at+1;if left>=heap.len(){break;}let right=left+1;
        let child=if right<heap.len() && key(nodes,heap[right])<key(nodes,heap[left]){right}else{left};
        if key(nodes,heap[at])<=key(nodes,heap[child]){break;}heap.swap(at,child);at=child;
    }}Ok(top)
}
pub fn estimate(hist:&[u32;256],payload_bits:usize,compact:usize)->Result<Estimate>{
    let total=hist.iter().try_fold(0u32,|n,&v|n.checked_add(v).ok_or("Huffman histogram sum overflow"))?;
    if hist.iter().any(|&v|v>MAX_MINOR){return Err("Huffman maximum weight".into());}
    if total>MAX_MINOR{return Err("Huffman maximum total".into());}
    let nonzero=hist.iter().filter(|&&v|v!=0).count();
    let minor_bits=usize::try_from(total).map_err(|_|"minor usize")?.checked_mul(8).ok_or("minor bits overflow")?;
    let prefix=payload_bits.checked_sub(compact).ok_or("prefix compact subtraction")?;
    let rest=prefix.checked_sub(minor_bits).ok_or("minor payload subtraction")?;
    let mut lengths=[0u8;256];let mut nodes=Vec::new();let mut heap=Vec::new();
    nodes.try_reserve_exact(511).map_err(|_|"Huffman nodes allocation")?;
    heap.try_reserve_exact(256).map_err(|_|"Huffman heap allocation")?;
    let temporary_bytes=nodes.capacity()*std::mem::size_of::<Node>()+std::mem::size_of_val(&nodes)
        +heap.capacity()*std::mem::size_of::<usize>()+std::mem::size_of_val(&heap)+512+std::mem::size_of::<Estimate>()+256;
    if nodes.capacity()>511 || heap.capacity()>256 || temporary_bytes>16384{return Err("Huffman temporary cap".into());}
    for (symbol,&weight) in hist.iter().enumerate(){if weight!=0{
        let id=nodes.len();nodes.push(Node{weight:u64::from(weight),min_symbol:symbol as u16,left:NONE,right:NONE,parent:NONE});push(&mut heap,&nodes,id)?;
    }}
    let leaves=nodes.len();
    while heap.len()>1{
        let a=pop(&mut heap,&nodes)?;let b=pop(&mut heap,&nodes)?;
        if nodes.len()>=511{return Err("Huffman node cap".into());}
        let id=nodes.len();let weight=nodes[a].weight.checked_add(nodes[b].weight).ok_or("Huffman merge weight overflow")?;
        let min_symbol=nodes[a].min_symbol.min(nodes[b].min_symbol);
        nodes.push(Node{weight,min_symbol,left:a as u16,right:b as u16,parent:NONE});
        nodes[a].parent=id as u16;nodes[b].parent=id as u16;push(&mut heap,&nodes,id)?;
    }
    let mut depth_counts=[0u16;256];let mut max_depth=0;let mut weighted_code_bits=0u64;
    for id in 0..leaves{
        let mut depth=0usize;let mut at=id;while nodes[at].parent!=NONE{
            let parent=usize::from(nodes[at].parent);
            if parent<=at || parent>=nodes.len() || (nodes[parent].left as usize!=at && nodes[parent].right as usize!=at){return Err("Huffman parent extent".into());}
            depth+=1;if depth>255{return Err("Huffman depth bound".into());}at=parent;
        }
        let depth=depth.max(1);let symbol=usize::from(nodes[id].min_symbol);
        lengths[symbol]=depth as u8;depth_counts[depth]=depth_counts[depth].checked_add(1).ok_or("Huffman depth count overflow")?;
        max_depth=max_depth.max(depth);weighted_code_bits=weighted_code_bits.checked_add(u64::from(hist[symbol]).checked_mul(depth as u64).ok_or("Huffman code product overflow")?).ok_or("Huffman code sum overflow")?;
    }
    let mut slots=1u32;for depth in 1..=max_depth{slots=slots.checked_mul(2).ok_or("Huffman Kraft slots overflow")?.checked_sub(u32::from(depth_counts[depth])).ok_or("Huffman Kraft oversubscribed")?;}
    let kraft_valid=if nonzero==0{max_depth==0}else if nonzero==1{slots==1 && max_depth==1}else{slots==0};
    if !kraft_valid || (total!=0 && weighted_code_bits==0){return Err("Huffman Kraft/code cost".into());}
    let raw_bytes=5usize.checked_add(prefix.div_ceil(8)).ok_or("raw metadata overflow")?;
    let huffman_payload=rest.checked_add(usize::try_from(weighted_code_bits).map_err(|_|"Huffman cost usize")?).ok_or("Huffman payload overflow")?;
    if prefix>u32::MAX as usize || huffman_payload>u32::MAX as usize{return Err("metadata bitlength u32".into());}
    let lower_bound_bytes=if nonzero==0{None}else{Some(133usize.checked_add(huffman_payload.div_ceil(8)).ok_or("Huffman metadata overflow")?)};
    let huffman_valid=nonzero!=0 && max_depth<=15;let huffman_bytes=if huffman_valid{lower_bound_bytes}else{None};
    let huffman_chosen=huffman_bytes.is_some_and(|n|n<raw_bytes);
    let chosen_payload_bits=if huffman_chosen{huffman_payload}else{prefix};
    let chosen_bytes=if huffman_chosen{huffman_bytes.ok_or("Huffman chosen missing")?}else{raw_bytes};
    let fallback_reason=if nonzero==0{"empty"}else if max_depth>15{"max_depth_exceeds_15"}else if !huffman_chosen{"raw_is_no_larger"}else{"none"};
    drop(heap);drop(nodes);
    Ok(Estimate{lengths,total,nonzero,max_depth,kraft_valid,weighted_code_bits,huffman_valid,fallback_reason,
        raw_bytes,huffman_bytes,lower_bound_bytes,chosen_bytes,chosen_payload_bits,chosen_padding_bits:(8-chosen_payload_bits%8)%8,
        chosen_table_bytes:if huffman_chosen{128}else{0},huffman_chosen,temporary_bytes})
}
struct Reader<'a>{payload:&'a[u8],bits:usize,position:usize}
fn add(counter:&mut usize,value:usize)->Result<()>{*counter=counter.checked_add(value).ok_or("census scalar sum overflow")?;Ok(())}
impl Reader<'_>{
    fn read(&mut self,width:usize)->Result<u32>{
        if width>31 || self.position.checked_add(width).ok_or("census bit offset overflow")?>self.bits{return Err("census truncated field".into());}
        let mut value=0;for _ in 0..width{value=(value<<1)|u32::from((self.payload[self.position/8]>>(7-self.position%8))&1);self.position+=1;}Ok(value)
    }
}
fn tree(reader:&mut Reader<'_>,c:&mut Census,k:usize,depth:usize)->Result<()>{
    add(&mut c.split_field_bits,1)?;
    if reader.read(1)?==1{
        if depth>=5{return Err("census depth exceeds 5".into());}add(&mut c.splits,1)?;
        if depth==0{if reader.read(1)?==0{add(&mut c.low_orders,1)?;}else{add(&mut c.high_orders,1)?;}}
        for _ in 0..4{tree(reader,c,k,depth+1)?;}
    }else{
        add(&mut c.mode_field_bits,2)?;let mode=reader.read(2)?;
        match mode{
            0=>{add(&mut c.uniform,1)?;let _=model::uniform(k)?;},
            1=>{add(&mut c.pure,1)?;let width=if k==2{1}else{2};add(&mut c.dominant_field_bits,width)?;if reader.read(width)? as usize>=k{return Err("census pure dominant index".into());}},
            2=>{
                add(&mut c.compact,1)?;let width=if k==2{1}else{2};add(&mut c.dominant_field_bits,width)?;let dominant=reader.read(width)? as usize;
                if dominant>=k{return Err("census compact dominant index".into());}
                let mut frequency=[0u16;4];let mut sum=0u32;
                for i in 0..k{if i!=dominant{
                    let code=reader.read(8)? as usize;c.histogram[code]=c.histogram[code].checked_add(1).ok_or("minor histogram overflow")?;add(&mut c.minor_field_bits,8)?;
                    frequency[i]=model::MINOR_LUT[code];sum=sum.checked_add(u32::from(frequency[i])).ok_or("census minor sum overflow")?;
                }}
                frequency[dominant]=u16::try_from(32768u32.checked_sub(sum).ok_or("census residual underflow")?).map_err(|_|"census residual range")?;
                if frequency[dominant]<2 || frequency[..k].iter().any(|&f|f>frequency[dominant]){return Err("census residual largest/minimum".into());}
            },
            _=>return Err("census reserved mode".into()),
        }
    }Ok(())
}
pub fn scan(bytes:&[u8])->Result<Census>{
    if bytes.len()<4 || bytes.len()>bundle::MAX_BUNDLE_BYTES{return Err("census bytes bound".into());}
    let bits=u32::from_le_bytes(bytes[..4].try_into().map_err(|_|"census length field")?) as usize;
    if !(bundle::ROOTS..=bundle::MAX_BUNDLE_BITS).contains(&bits) || bytes.len()!=4+bits.div_ceil(8){return Err("census exact bytes/bits".into());}
    let payload=&bytes[4..];if bits%8!=0 && payload.last().copied().ok_or("census empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("census zero padding".into());}
    let blank=Estimate{lengths:[0;256],total:0,nonzero:0,max_depth:0,kraft_valid:false,weighted_code_bits:0,huffman_valid:false,fallback_reason:"unmeasured",
        raw_bytes:0,huffman_bytes:None,lower_bound_bytes:None,chosen_bytes:0,chosen_payload_bits:0,chosen_padding_bits:0,chosen_table_bytes:0,huffman_chosen:false,temporary_bytes:0};
    let mut c=Census{histogram:[0;256],estimate:blank,payload_bits:bits,prefix_payload_bits:0,roots:0,defaults:0,splits:0,uniform:0,pure:0,compact:0,
        low_orders:0,high_orders:0,split_field_bits:0,mode_field_bits:0,dominant_field_bits:0,minor_field_bits:0,packet_bytes:bytes.len()};
    let mut reader=Reader{payload,bits,position:0};
    for _ in 0..bundle::MODELS{for k in 2..=4{add(&mut c.roots,1)?;if reader.read(1)?==0{add(&mut c.defaults,1)?;}else{tree(&mut reader,&mut c,k,0)?;}}}
    if reader.position!=bits || c.roots!=834{return Err("census exact root/trailing bits".into());}
    let typed_bits=[c.roots,c.split_field_bits,c.low_orders,c.high_orders,c.mode_field_bits,c.dominant_field_bits,c.minor_field_bits]
        .into_iter().try_fold(0usize,|sum,n|sum.checked_add(n).ok_or("census typed bits overflow"))?;
    if typed_bits!=bits{return Err("census typed field bit totals".into());}
    c.prefix_payload_bits=bits.checked_sub(c.compact).ok_or("census prefix bits")?;
    c.estimate=estimate(&c.histogram,bits,c.compact)?;
    if usize::try_from(c.estimate.total).map_err(|_|"census count usize")?.checked_mul(8).ok_or("census minor bit overflow")?!=c.minor_field_bits{return Err("census histogram/minor bit sum".into());}
    Ok(c)
}
impl Census{
    pub fn verify_existing(&self,bits:usize,defaults:usize,leaves:usize,splits:usize,low_orders:usize,high_orders:usize,modes:[usize;3])->Result<()>{
        if self.payload_bits!=bits || self.defaults!=defaults || self.uniform+self.pure+self.compact+self.defaults!=leaves
            || self.splits!=splits || self.low_orders!=low_orders || self.high_orders!=high_orders
            || [self.uniform+self.defaults,self.pure,self.compact]!=modes{return Err("census frozen structure mismatch".into());}Ok(())
    }
    pub fn print_json(&self){
        fn optional(n:Option<usize>)->String{n.map_or_else(||"null".into(),|v|v.to_string())}
        let e=&self.estimate;
        print!("{{\"histogram\":{:?},\"lengths\":{:?},\"minor_count\":{},\"nonzero_symbols\":{},\"max_depth\":{},\"kraft_valid\":{},\"huffman_valid\":{},\"fallback_reason\":\"{}\",\"weighted_code_bits\":{},\"raw_minor_metadata_bytes\":{},\"huffman_metadata_bytes\":{},\"unrestricted_huffman_metadata_lower_bound_bytes\":{},\"estimated_metadata_bytes\":{},\"estimated_payload_bits\":{},\"estimated_padding_bits\":{},\"codec_flag_bytes\":1,\"length_field_bytes\":4,\"length_table_bytes\":{},\"huffman_chosen\":{},\"encoder_implemented\":false,\"roots\":{},\"default_roots\":{},\"splits\":{},\"uniform_saved_leaves\":{},\"pure_saved_leaves\":{},\"compact_saved_leaves\":{},\"order_bits\":{},\"low_order_bits\":{},\"high_order_bits\":{},\"original_payload_bits\":{},\"prefix_payload_bits\":{},\"split_field_bits\":{},\"mode_field_bits\":{},\"dominant_field_bits\":{},\"minor_field_bits\":{},\"original_packet_bytes\":{},\"retained_census_bytes\":{},\"Huffman_peak_temporary_bytes\":{},\"packet_scans\":1,\"packet_copies\":0,\"length_limited_decoder_verified\":false}}",
            self.histogram,e.lengths,e.total,e.nonzero,e.max_depth,e.kraft_valid,e.huffman_valid,e.fallback_reason,e.weighted_code_bits,e.raw_bytes,optional(e.huffman_bytes),
            optional(e.lower_bound_bytes),e.chosen_bytes,e.chosen_payload_bits,e.chosen_padding_bits,e.chosen_table_bytes,e.huffman_chosen,
            self.roots,self.defaults,self.splits,self.uniform,self.pure,self.compact,self.low_orders+self.high_orders,self.low_orders,self.high_orders,
            self.payload_bits,self.prefix_payload_bits,self.split_field_bits,self.mode_field_bits,self.dominant_field_bits,self.minor_field_bits,self.packet_bytes,
            std::mem::size_of::<Self>(),e.temporary_bytes);
    }
}

