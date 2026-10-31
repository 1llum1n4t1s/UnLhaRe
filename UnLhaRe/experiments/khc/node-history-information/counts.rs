type Result<T>=std::result::Result<T,String>;
pub const NODE_COUNT:usize=142;
pub const HISTORIES:usize=1024;
pub const CAP:u32=3825340;
pub const ROWS:usize=2*NODE_COUNT*3*HISTORIES;
pub struct Dense {pub rows:Vec<[u32;4]>}
fn index(c:usize,node:usize,k:usize,history:u16)->Result<usize>{if c>=2 || node>=NODE_COUNT || !(2..=4).contains(&k){return Err("dense component/node/prefix".into());}Ok(((c*NODE_COUNT+node)*3+k-2)*HISTORIES+(history as usize&1023))}
impl Dense {
    pub fn new()->Result<Self>{let mut rows=Vec::new();rows.try_reserve_exact(ROWS).map_err(|_|"dense allocation")?;rows.resize(ROWS,[0;4]);Ok(Self{rows})}
    pub fn record(&mut self,c:usize,node:usize,k:usize,history:u16,child:usize)->Result<()>{let i=index(c,node,k,history)?;if child>=k || self.rows.len()!=ROWS{return Err("dense child/shape".into());}let row=self.rows[i];if row[k..].iter().any(|&v|v!=0) || row.iter().map(|&v|u64::from(v)).sum::<u64>()>=u64::from(CAP){return Err("dense tail/CAP".into());}let next=row[child].checked_add(1).ok_or("dense overflow")?;self.rows[i][child]=next;Ok(())}
    pub fn row(&self,c:usize,node:usize,k:usize,history:u16)->Result<[u32;4]>{let i=index(c,node,k,history)?;if self.rows.len()!=ROWS{return Err("dense shape".into());}let row=self.rows[i];if row[k..].iter().any(|&v|v!=0) || row.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(CAP){return Err("dense stored tail/CAP".into());}Ok(row)}
    pub fn capacity_bytes(&self)->usize{self.rows.capacity()*std::mem::size_of::<[u32;4]>()+std::mem::size_of::<Self>()}
}
