//! canonical Q48 grid ln/exp -> Q32。encoder側にf64を使わない。
pub const Q:u64=1<<32;
pub const S:u64=1<<48;
pub const GRID:usize=4096;
pub const LN2:u64=195103586505154;
pub const EXP_CUTOFF:i64=95265423099;
pub type Result<T>=std::result::Result<T,&'static str>;
pub fn mul(a:u128,b:u128)->Result<u128> {a.checked_mul(b).ok_or("unsigned product overflow")}
pub fn add(a:u128,b:u128)->Result<u128> {a.checked_add(b).ok_or("unsigned sum overflow")}
pub fn div(n:u128,d:u128)->Result<u128> {if d==0 {Err("zero divisor")}else {Ok(n/d)}}
pub fn smul(a:i128,b:i128)->Result<i128> {a.checked_mul(b).ok_or("signed product overflow")}
pub fn sadd(a:i128,b:i128)->Result<i128> {a.checked_add(b).ok_or("signed sum overflow")}
pub fn sdiv(n:i128,d:i128)->Result<i128> {n.checked_div(d).ok_or("signed division domain")}
pub fn u64_value(n:u128)->Result<u64> {u64::try_from(n).map_err(|_|"unsigned conversion")}
pub fn i64_value(n:i128)->Result<i64> {i64::try_from(n).map_err(|_|"signed conversion")}
fn allocate<T:Clone>(n:usize,value:T)->Result<Vec<T>> {
    let mut result=Vec::new();result.try_reserve_exact(n).map_err(|_|"math allocation")?;result.resize(n,value);Ok(result)
}
pub struct Math {l:Vec<u64>,e:Vec<u64>,counts:Vec<i64>}
impl Math {
    pub fn new()->Result<Self> {
        let mut l=allocate(GRID+1,0u64)?;let mut e=allocate(GRID+1,0u64)?;
        for i in 0..=GRID {
            let x=add(u128::from(S),div(mul(i as u128,u128::from(S))?,GRID as u128)?)?;
            let t=div(mul(x-u128::from(S),u128::from(S))?,add(x,u128::from(S))?)?;
            let t2=div(mul(t,t)?,u128::from(S))?;let mut power=t;let mut sum=0;
            for k in 0..18u128 {sum=add(sum,div(power,2*k+1)?)?;power=div(mul(power,t2)?,u128::from(S))?;}
            l[i]=u64_value(mul(2,sum)?)?;
        }
        if l[GRID]!=LN2 {return Err("LN2 fixture");}
        for i in 0..=GRID {
            let x=div(mul(i as u128,u128::from(LN2))?,GRID as u128)?;
            let mut term=u128::from(S);let mut sum=term;
            for k in 1..=24u128 {term=div(mul(term,x)?,mul(u128::from(S),k)?)?;sum=add(sum,term)?;}
            e[i]=u64_value(div(mul(u128::from(S),u128::from(S))?,sum)?)?;
        }
        if e[GRID/2]!=199032864766437 || e[0]!=S || l[0]!=0 {return Err("math LUT fixture");}
        if l.windows(2).any(|p|p[0]>=p[1]) || e.windows(2).any(|p|p[0]<=p[1]) {return Err("math LUT monotonic");}
        let mut result=Self{l,e,counts:allocate(32769,0i64)?};
        for n in 1..=32768u64 {result.counts[n as usize]=result.ln_scaled(n,0)?;}
        Ok(result)
    }
    pub fn ln_scaled(&self,n:u64,scale_bits:u32)->Result<i64> {
        if n==0 || n>Q || ![0,32].contains(&scale_bits) {return Err("ln domain");}
        let exponent=63-n.leading_zeros();let base=1u64<<exponent;
        let pos=mul(u128::from(n-base),GRID as u128)?;let idx=(pos/u128::from(base)) as usize;let rem=pos%u128::from(base);
        if idx>=GRID {return Err("ln grid index");}
        let difference=self.l[idx+1].checked_sub(self.l[idx]).ok_or("ln interpolation order")?;
        let mant=add(u128::from(self.l[idx]),div(mul(u128::from(difference),rem)?,u128::from(base))?)?;
        let exponent_term=smul(i128::from(exponent)-i128::from(scale_bits),i128::from(LN2))?;
        i64_value(sdiv(sadd(i128::try_from(mant).map_err(|_|"ln mantissa conversion")?,exponent_term)?,1i128<<16)?)
    }
    pub fn ln_count(&self,n:u64)->Result<i64> {
        if !(1..=32768).contains(&n) {return Err("count ln domain");}Ok(self.counts[n as usize])
    }
    pub fn ln_cts(&self,n:u64)->Result<i64> {self.ln_scaled(n,32)}
    pub fn exp_neg(&self,d:i64)->Result<u64> {
        if d<0 || d>128*Q as i64 {return Err("exp domain");}
        if d==0 {return Ok(Q);}
        let mag=mul(d as u128,1u128<<16)?;let exponent=mag/u128::from(LN2);let rem=mag%u128::from(LN2);
        if exponent>=32 {return Ok(0);}
        let position=mul(rem,GRID as u128)?;let idx=(position/u128::from(LN2)) as usize;let rem2=position%u128::from(LN2);
        if idx>=GRID {return Err("exp grid index");}
        let difference=self.e[idx].checked_sub(self.e[idx+1]).ok_or("exp interpolation order")?;
        let correction=u64_value(div(mul(u128::from(difference),rem2)?,u128::from(LN2))?)?;
        let interp=self.e[idx].checked_sub(correction).ok_or("exp interpolation underflow")?;
        Ok(interp>>(16+exponent as u32))
    }
    pub fn l(&self)->&[u64] {&self.l}
    pub fn e(&self)->&[u64] {&self.e}
    pub fn counts(&self)->&[i64] {&self.counts}
}

