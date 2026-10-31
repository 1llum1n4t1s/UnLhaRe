use crate::{features::Family,fenwick::{Table,bump},dictionary::{ExactMap,Plan,EMPTY}};
pub use crate::dictionary::hash;
pub const FAMILIES:[Family;4]=[Family::Global,Family::Symbol,Family::Recent,Family::Joint];
pub const ROWS:[usize;4]=[32,16384,65536,32768];
fn fill<T:Clone>(len:usize,value:T)->Result<Vec<T>,String>{let mut v=Vec::new();v.try_reserve_exact(len).map_err(|_|"audit allocation")?;v.resize(len,value);Ok(v)}
pub fn four_keys(component:usize,joint:u32,recent:u32)->Result<[u32;4],String>{
    if Family::Joint.component(joint)?!=component{return Err("joint component mismatch".into());}let context=((joint>>18)&15) as usize;let symbol=((joint>>9)&511) as usize;let rank_exp=((joint>>5)&7) as usize;let length_exp=(joint&31) as usize;
    let mut keys=[0;4];for i in 0..4{keys[i]=FAMILIES[i].key(component,context,symbol,recent,rank_exp,length_exp)?;}if keys[3]!=joint{return Err("joint lossless reconstruction".into());}Ok(keys)
}
pub fn valid_weights(weights:&[f64;4])->Result<(),String>{let mut sum=0.0;for &w in weights{if !w.is_finite() || w<=0.0 || w>1.0{return Err("weight finite/positive/range".into());}sum+=w;}if !sum.is_finite() || (sum-1.0).abs()>1e-12{return Err("weight sum".into());}Ok(())}
pub fn cumulative(k:usize,limit:usize,s:f64)->Result<u32,String>{if limit==0 || limit>257 || k>limit || !s.is_finite() || s<0.0 || s>1.0+1e-12{return Err("mixture cumulative input".into());}if k==0{return Ok(0);}if k==limit{return Ok(32768);}let scaled=((32768-limit) as f64*s).floor();if !scaled.is_finite() || scaled<0.0 || scaled>(32768-limit) as f64{return Err("mixture cumulative floor range".into());}let value=(k as u32).checked_add(scaled as u32).ok_or("CDF add overflow")?;if value<k as u32 || value>32768-(limit-k) as u32{return Err("CDF reserved freq bound".into());}Ok(value)}
pub struct Bank {pub table:Table,pub family:Family,pub first_key:Vec<u32>,pub map:Option<ExactMap>,pub active_rows:u64}
impl Bank {
    fn new(i:usize,rows:usize)->Result<Self,String>{Ok(Self{table:Table::new(rows)?,family:FAMILIES[i],first_key:fill(rows,EMPTY)?,map:if i>=2{Some(ExactMap::new(rows)?)}else{None},active_rows:0})}
    pub fn bytes(&self)->usize{self.table.allocation_bytes()+self.first_key.capacity()*4+self.map.as_ref().map_or(0,ExactMap::allocation_bytes)}
    pub fn json(&self)->String{let o=self.table.ops;let map=self.map.as_ref().map_or_else(||"null".into(),|m|format!("{{\"capacity_rows\":{},\"used_rows\":{},\"key_slot_len\":{},\"key_slot_capacity\":{},\"row_slot_len\":{},\"row_slot_capacity\":{},\"allocation_bytes\":{}}}",m.capacity,m.used,m.keys.len(),m.keys.capacity(),m.rows.len(),m.rows.capacity(),m.allocation_bytes()));format!("{{\"family\":\"{}\",\"rows\":{},\"registered_rows\":{},\"model_row_aliases\":0,\"leaf_len\":{},\"leaf_capacity\":{},\"tree_len\":{},\"tree_capacity\":{},\"tree_element_bytes\":2,\"total_capacity\":{},\"first_key_capacity\":{},\"allocation_heap_bytes\":{},\"exact_map\":{map},\"prefix_queries\":{},\"prefix_visits\":{},\"token_updates\":{},\"update_visits\":{},\"rescales\":{},\"rebuild_leaves\":{},\"rebuild_visits\":{}}}",self.family.name(),self.table.rows,self.active_rows,self.table.leaf.len(),self.table.leaf.capacity(),self.table.tree.len(),self.table.tree.capacity(),self.table.total.capacity(),self.first_key.capacity(),self.bytes(),o.queries,o.query_visits,o.updates,o.update_visits,o.rescales,o.rebuild_leaves,o.rebuild_visits)}
}
#[derive(Clone)]
pub struct Prediction {pub keys:[u32;4],pub rows:[usize;4],pub global:usize,pub token:usize,pub limit:usize,pub probabilities:[f64;4],pub old_weights:[f64;4],pub mixture_probability:f64,pub low:u32,pub high:u32}
pub struct Mix {pub banks:[Bank;4],pub weights:[[f64;4];32],pub observations:u64}
impl Mix {
    pub fn new()->Result<Self,String>{Self::new_with_pool_rows(ROWS[2],ROWS[3])}
    pub fn new_with_pool_rows(recent:usize,joint:usize)->Result<Self,String>{if recent==0 || joint==0 || recent>ROWS[2] || joint>ROWS[3]{return Err("exact pool capacity".into());}Ok(Self{banks:[Bank::new(0,ROWS[0])?,Bank::new(1,ROWS[1])?,Bank::new(2,recent)?,Bank::new(3,joint)?],weights:[[0.25;4];32],observations:0})}
    pub fn predict(&mut self,keys:[u32;4],token:usize,limit:usize)->Result<Prediction,String>{
        if limit==0 || limit>257 || token>=limit{return Err("prediction token/limit".into());}let global=keys[0] as usize;if global>=32{return Err("prediction global key".into());}
        for i in 0..4{FAMILIES[i].component(keys[i])?;if keys[i]>>(FAMILIES[i].bits()-5)!=keys[0]{return Err("expert context mismatch".into());}}
        if keys[1]&511>=257 || four_keys(Family::Joint.component(keys[3])?,keys[3],keys[2]&65535)?!=keys{return Err("expert key fields".into());}
        let weights=self.weights[global];valid_weights(&weights)?;
        let mut rows=[0;4];let mut plans:[Option<Plan>;4]=[None;4];
        // 全mapのprepare/容量/予約/row metadataを確認してからだけ登録する。
        for i in 0..4{let bank=&self.banks[i];let row=if let Some(map)=&bank.map{let plan=map.prepare(keys[i])?;map.validate_plan(&plan)?;let row=plan.row();plans[i]=Some(plan);row}else{keys[i] as usize};
            if row>=bank.table.rows || bank.first_key.len()!=bank.table.rows{return Err("expert row range".into());}
            let first=bank.first_key[row];if first!=EMPTY && first!=keys[i]{return Err("exact row key mismatch".into());}if first==EMPTY{bank.active_rows.checked_add(1).ok_or("registered row count overflow")?;}rows[i]=row;
        }
        for i in 0..4{let bank=&mut self.banks[i];if let Some(plan)=plans[i]{let actual=bank.map.as_mut().ok_or("missing exact map")?.commit(plan)?;if actual!=rows[i]{return Err("exact committed row mismatch".into());}}if bank.first_key[rows[i]]==EMPTY{bank.first_key[rows[i]]=keys[i];bump(&mut bank.active_rows,1)?;}}
        let mut probabilities=[0.0;4];let mut slo=0.0;let mut shi=0.0;let mut mixture_probability=0.0;
        for i in 0..4{let bank=&mut self.banks[i];let row=rows[i];let total=bank.table.prefix(row,limit)?;let lower=bank.table.prefix(row,token)?;let count=bank.table.count(row,token)?;let upper=lower.checked_add(count).ok_or("expert upper overflow")?;if total==0 || upper>total || lower>=upper{return Err("expert prefix interval".into());}let p=count as f64/total as f64;if !p.is_finite() || p<=0.0 || p>1.0{return Err("expert probability".into());}probabilities[i]=p;slo+=weights[i]*(lower as f64/total as f64);shi+=weights[i]*(upper as f64/total as f64);mixture_probability+=weights[i]*p;}
        if !mixture_probability.is_finite() || mixture_probability<=0.0 || mixture_probability>1.0+1e-12{return Err("mixture probability".into());}let low=cumulative(token,limit,slo)?;let high=cumulative(token+1,limit,shi)?;if low>=high || high>32768{return Err("quantized actual interval".into());}
        Ok(Prediction{keys,rows,global,token,limit,probabilities,old_weights:weights,mixture_probability,low,high})
    }
    pub fn observe(&mut self,prediction:Prediction)->Result<(),String>{if prediction.global>=32{return Err("observation global key".into());}if self.weights[prediction.global].map(f64::to_bits)!=prediction.old_weights.map(f64::to_bits){return Err("diagnostic stale weights".into());}let mut next=[0.0;4];for i in 0..4{let posterior=prediction.old_weights[i]*prediction.probabilities[i]/prediction.mixture_probability;if !posterior.is_finite() || posterior<=0.0 || posterior>1.0+1e-12{return Err("posterior finite/range".into());}next[i]=(255.0/256.0)*posterior+1.0/1024.0;}valid_weights(&next)?;
        for i in 0..4{self.banks[i].table.observe(prediction.rows[i],prediction.token)?;}self.weights[prediction.global]=next;bump(&mut self.observations,1)?;Ok(())}
    pub fn heap_bytes(&self)->usize{self.banks.iter().map(Bank::bytes).sum()}
    pub fn bytes(&self)->usize{self.heap_bytes()+std::mem::size_of::<Self>()}
    pub fn verify_terminal(&self)->Result<usize,String>{let mut cells=0;for bank in &self.banks{cells+=bank.table.verify_all()?;let registered=bank.first_key.iter().filter(|&&k|k!=EMPTY).count() as u64;if registered!=bank.active_rows{return Err("terminal registered row count".into());}
            if let Some(map)=&bank.map{if map.verify_rows(&bank.first_key)? as u64!=registered{return Err("terminal exact map count".into());}}
            for(row,&key)in bank.first_key.iter().enumerate(){if key==EMPTY{if bank.table.total[row]!=257 || bank.table.leaf[row*257..(row+1)*257].iter().any(|&v|v!=1){return Err("terminal unused row prior".into());}}else{bank.family.component(key)?;if bank.map.is_none() && key as usize!=row{return Err("terminal direct key row".into());}}}
        }for w in &self.weights{valid_weights(w)?;}Ok(cells)}
}
