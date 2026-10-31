//! canonical Q48 gridを一回生成し、固定順f64補間で使用する。
use crate::Result;
pub struct Math {l:Vec<f64>,e:Vec<f64>,counts:Vec<f64>,ln2:f64}
impl Math {
    pub fn new()->Result<Self>{
        let canonical=crate::fixed_math::Math::new()?;
        let mut l=Vec::new();let mut e=Vec::new();let mut counts=Vec::new();
        l.try_reserve_exact(canonical.l().len()).map_err(|_|"float math allocation")?;
        e.try_reserve_exact(canonical.e().len()).map_err(|_|"float math allocation")?;
        counts.try_reserve_exact(canonical.counts().len()).map_err(|_|"float math allocation")?;
        l.extend(canonical.l().iter().map(|&v|v as f64/crate::fixed_math::S as f64));
        e.extend(canonical.e().iter().map(|&v|v as f64/crate::fixed_math::S as f64));
        counts.extend(canonical.counts().iter().map(|&v|v as f64/crate::fixed_math::Q as f64));
        Ok(Self{l,e,counts,ln2:crate::fixed_math::LN2 as f64/crate::fixed_math::S as f64})
    }
    pub fn ln_count(&self,n:u64)->Result<f64>{if !(1..=32768).contains(&n){return Err("count ln domain".into());}Ok(self.counts[n as usize])}
    pub fn ln_cts(&self,n:f64)->Result<f64>{
        if !n.is_finite()||n<=0.0||n>1.0{return Err("ln domain".into());}
        // subnormalも正規化して指数と仮数へ分ける。
        let (value,adjust)=if n<f64::MIN_POSITIVE{(n*18014398509481984.0,-54)}else{(n,0)};
        let bits=value.to_bits();let exponent=((bits>>52)&2047) as i32-1023+adjust;
        let mantissa=f64::from_bits((bits&((1u64<<52)-1))|(1023u64<<52));
        let position=(mantissa-1.0)*4096.0;let index=position as usize;
        if index>=4096{return Err("ln grid index".into());}
        let fraction=position-index as f64;
        let interpolation=self.l[index]+(self.l[index+1]-self.l[index])*fraction;
        let result=interpolation+exponent as f64*self.ln2;
        if !result.is_finite(){return Err("ln interpolation".into());}Ok(result)
    }
    pub fn exp_neg(&self,d:f64)->Result<f64>{
        if !d.is_finite()||!(0.0..=128.0).contains(&d){return Err("exp domain".into());}
        let exponent=(d/self.ln2) as u32;
        // canonical Q32 exponent cutoffを維持する。
        if exponent>=32{return Ok(0.0);}
        let remainder=d-exponent as f64*self.ln2;
        let position=remainder*(4096.0/self.ln2);let index=position as usize;
        if index>=4096{return Err("exp grid index".into());}
        let fraction=position-index as f64;
        let interpolation=self.e[index]+(self.e[index+1]-self.e[index])*fraction;
        let result=interpolation*f64::from_bits((1023u64-u64::from(exponent))<<52);
        if !result.is_finite()||!(0.0..=1.0).contains(&result){return Err("exp interpolation".into());}Ok(result)
    }
}
