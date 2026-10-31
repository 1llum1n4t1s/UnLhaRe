type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct Feature {pub symbol:usize,pub context:usize,pub recent:u32,pub previous:(usize,usize)}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct FeatureState {recent:u32,previous:[(usize,usize);257]}
fn exponent(v:usize)->usize{if v==0{0}else{(usize::BITS-1-v.leading_zeros()) as usize}}
impl FeatureState {
    pub fn new()->Self{Self{recent:0,previous:[(0,0);257]}}
    pub fn peek(&self,context:usize,symbol:usize)->Result<Feature>{if context>8 || symbol>=257{return Err("feature context/symbol".into());}Ok(Feature{symbol,context,recent:self.recent,previous:self.previous[symbol]})}
    pub fn commit(&mut self,symbol:usize,rank:usize,length:usize)->Result<()>{if symbol>=257 || rank>256 || !(1..=8388609).contains(&length){return Err("feature commit range".into());}
        self.previous[symbol]=(exponent(rank.saturating_sub(1)),exponent(length-1));
        let class=match length{1=>0,2=>1,3..=4=>2,_=>3};self.recent=((self.recent<<4)|rank.min(3) as u32|class<<2)&0xffff;
        Ok(())
    }
}
