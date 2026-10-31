//! 有料table。encoderのsort方式とdecoderのcount方式を別々に構築する。
type Result<T> = std::result::Result<T, String>;
pub const ESC: usize = 256;
pub const PREFIX: usize = 134;
pub const MAX_TRIE: usize = 513;
pub const LENGTHS: [u8; 257] = [
7,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,11,0,0,11,0,0,0,0,10,0,11,0,0,0,0,0,11,0,11,0,0,0,0,0,0,11,0,0,0,11,0,0,0,11,11,0,0,11,0,0,0,0,11,11,0,0,0,10,0,11,0,11,0,0,0,11,0,0,0,0,10,0,11,11,0,0,0,11,0,0,0,9,11,10,9,10,10,11,11,11,10,9,10,11,10,0,9,0,10,11,0,0,10,9,9,9,11,10,10,10,11,9,9,9,10,9,10,11,10,10,9,10,10,9,9,8,10,8,7,8,9,9,9,8,8,9,10,8,8,9,9,8,9,9,9,9,10,8,8,9,8,8,8,7,8,8,8,8,8,7,9,8,8,8,8,9,10,8,7,9,7,9,8,9,7,9,7,8,7,8,7,8,7,7,7,8,8,8,8,7,8,7,8,8,8,8,7,8,7,7,7,7,6,6,6,7,6,7,6,6,6,6,6,6,6,6,6,6,6,6,6,6,4,5,5,6,7,7,7,8,7,8,8,8,8,8,7,7,7,7,7,6,6,7,6,6,0,11
];
pub fn fee(code: u8) -> usize { let n=LENGTHS[usize::from(code)]; if n==0 {19} else {usize::from(n)} }
pub fn validate(lengths: &[u8;257]) -> Result<()> {
    if lengths.iter().any(|&n|n>11) {return Err("table length exceeds11".into());}
    if lengths[ESC]==0 {return Err("table ESC absent".into());}
    let mut kraft=0u32;
    for &n in lengths { if n!=0 {kraft=kraft.checked_add(1u32<<(11-n)).ok_or("table Kraft overflow")?;} }
    if kraft>2048 {return Err("table Kraft oversubscribed".into());}
    if kraft!=2048 {return Err("table Kraft incomplete".into());} Ok(())
}
pub fn validate_fixed() -> Result<()> {
    validate(&LENGTHS)?;
    if LENGTHS[ESC]!=11 || LENGTHS.iter().copied().max()!=Some(11) {return Err("fixed max/ESC11".into());}
    // k2/3/4: 1024 leaf * (split1+compact1+dominant+19*(k-1)), 内部341/root-order1。
    let full=(2..=4).map(|k|1024*(2+(if k==2{1}else{2})+19*(k-1))+342).sum::<usize>();
    if full!=129026 || full>crate::model::MAX_BITS {return Err("fixed full expansion bound".into());} Ok(())
}
pub struct Encoder { pub lengths:[u8;257], pub codes:[u16;257] }
impl Encoder {
    pub fn new(lengths:[u8;257]) -> Result<Self> {
        validate(&lengths)?;
        let mut symbols=[0usize;257];for(i,v)in symbols.iter_mut().enumerate(){*v=i;}
        symbols.sort_unstable_by_key(|&i|(lengths[i],i));
        let mut codes=[0u16;257];let mut next=0u32;let mut previous=0;
        for s in symbols {let n=lengths[s];if n==0{continue;}next=next.checked_shl(u32::from(n-previous)).ok_or("encoder shift")?;
            if next>=1u32<<n{return Err("encoder canonical range".into());}codes[s]=next as u16;next+=1;previous=n;
        } Ok(Self{lengths,codes})
    }
    pub fn write(&self, code:u8,w:&mut Writer) -> Result<()> {
        let s=usize::from(code);let escaped=self.lengths[s]==0;let symbol=if escaped{ESC}else{s};
        w.write(u32::from(self.codes[symbol]),usize::from(self.lengths[symbol]))?;
        if escaped{w.write(u32::from(code),8)?;} Ok(())
    }
    pub fn capacity_bytes(&self)->usize {std::mem::size_of::<Self>()}
}
#[derive(Clone,Copy)]
struct Trie {next:[i16;2],symbol:i16}
pub struct Decoder { pub lengths:[u8;257], trie:Vec<Trie> }
impl Decoder {
    pub fn new(lengths:[u8;257]) -> Result<Self> {
        validate(&lengths)?;
        let blank=Trie{next:[-1;2],symbol:-1};let mut trie=Vec::new();trie.try_reserve_exact(MAX_TRIE).map_err(|_|"trie allocation")?;
        if trie.capacity()>MAX_TRIE{return Err("trie capacity".into());}trie.push(blank);
        let mut counts=[0u32;12];for &n in &lengths{if n>0{counts[usize::from(n)]+=1;}}
        let mut next=[0u32;12];let mut value=0;
        for n in 1..=11 {value=(value+counts[n-1])*2;next[n]=value;}
        for s in 0..257 {let n=usize::from(lengths[s]);if n==0{continue;}let code=next[n];next[n]+=1;let mut at=0;
            for shift in (0..n).rev(){if trie[at].symbol>=0{return Err("trie prefix collision".into());}let bit=((code>>shift)&1) as usize;
                if trie[at].next[bit]<0{if trie.len()>=MAX_TRIE{return Err("trie node overflow".into());}let id=trie.len();trie.push(blank);trie[at].next[bit]=id as i16;}
                at=trie[at].next[bit] as usize;
            }
            if trie[at].symbol>=0 || trie[at].next!=[-1;2]{return Err("trie duplicate/prefix".into());}trie[at].symbol=s as i16;
        }
        Ok(Self{lengths,trie})
    }
    pub fn read(&self,r:&mut Reader<'_>) -> Result<u8> {
        let mut at=0;
        for _ in 0..=11 {let symbol=self.trie.get(at).ok_or("trie index")?.symbol;
            if symbol>=0 {if symbol as usize==ESC {let raw=r.read(8)? as u8;if self.lengths[usize::from(raw)]!=0{return Err("redundant ESC known symbol".into());}return Ok(raw);}return Ok(symbol as u8);}
            let bit=r.read(1)? as usize;let next=self.trie[at].next[bit];if next<0{return Err("trie missing code".into());}at=next as usize;
        } Err("canonical code exceeds11".into())
    }
    pub fn capacity_bytes(&self)->usize {std::mem::size_of::<Self>()+self.trie.capacity()*std::mem::size_of::<Trie>()}
    pub fn nodes(&self)->usize{self.trie.len()}
}
pub struct Writer {pub bytes:Vec<u8>,pub position:usize,pub limit:usize}
impl Writer {
    pub fn new(bits:usize)->Result<Self>{let mut bytes=Vec::new();bytes.try_reserve_exact(bits.div_ceil(8)).map_err(|_|"writer allocation")?;bytes.resize(bits.div_ceil(8),0);Ok(Self{bytes,position:0,limit:bits})}
    pub fn write(&mut self,value:u32,width:usize)->Result<()>{if width>31 || value>=1u32<<width || self.position.checked_add(width).ok_or("writer overflow")?>self.limit{return Err("writer range".into());}
        for s in (0..width).rev(){if value&(1<<s)!=0{self.bytes[self.position/8]|=1<<(7-self.position%8);}self.position+=1;}Ok(())}
}
pub struct Reader<'a>{pub bytes:&'a[u8],pub bits:usize,pub position:usize}
impl Reader<'_>{
    pub fn read(&mut self,width:usize)->Result<u32>{if width>31 || self.bits>self.bytes.len()*8 || self.position.checked_add(width).ok_or("reader overflow")?>self.bits{return Err("truncated paid field/code/raw".into());}
        let mut v=0;for _ in 0..width{v=(v<<1)|u32::from((self.bytes[self.position/8]>>(7-self.position%8))&1);self.position+=1;}Ok(v)}
}
pub fn header(payload:&[u8],bits:usize,lengths:&[u8;257])->Result<Vec<u8>>{
    validate(lengths)?;if payload.len()!=bits.div_ceil(8) || bits>u32::MAX as usize{return Err("header exact payload".into());}
    let mut b=Vec::new();b.try_reserve_exact(PREFIX+payload.len()).map_err(|_|"header allocation")?;b.resize(PREFIX,0);b[0]=1;b[1..5].copy_from_slice(&(bits as u32).to_le_bytes());
    for(i,&n)in lengths.iter().enumerate(){b[5+i/2]|=n<<if i%2==0{4}else{0};}b.extend_from_slice(payload);Ok(b)
}
pub fn read_header(bytes:&[u8],max:usize)->Result<([u8;257],usize,&[u8])>{
    if bytes.len()<PREFIX || bytes.len()>PREFIX+max.div_ceil(8){return Err("header bytes bound".into());}
    if bytes[0]!=1{return Err("header codec flag".into());}
    if bytes[PREFIX-1]&15!=0{return Err("table nibble padding".into());}
    let bits=u32::from_le_bytes(bytes[1..5].try_into().map_err(|_|"header length")?) as usize;
    if bits>max || bytes.len()!=PREFIX+bits.div_ceil(8){return Err("header exact bits/bytes".into());}
    if bits%8!=0 && bytes.last().copied().ok_or("header empty")?&((1u8<<(8-bits%8))-1)!=0{return Err("header zero padding".into());}
    let mut lengths=[0u8;257];for(i,n)in lengths.iter_mut().enumerate(){*n=(bytes[5+i/2]>>if i%2==0{4}else{0})&15;}validate(&lengths)?;Ok((lengths,bits,&bytes[PREFIX..]))
}
