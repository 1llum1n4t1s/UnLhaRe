//! 凍結旧Q32の観測だけを行う単一入口。契約E2Eはcodecを呼ばない。
#![allow(dead_code)]
#[path = "codec.rs"] mod codec;
#[path = "../quaternary-cts-depth/integer_cts.rs"] mod baseline_cts;
#[path = "../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path = "../quaternary-cts-integer-pool/integer_pool.rs"] mod old_pool;
#[path = "../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path = "../causal-bayes-sais/bwt.rs"] mod bwt;
#[path = "../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path = "../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::time::Instant;
type Result<T> = std::result::Result<T, String>;
struct Encoded { frame: Vec<u8>, stats: String, proof: codec::Proof, elapsed_ns: u64 }
struct Decoded { plain: Vec<u8>, stats: String, proof: codec::Proof, elapsed_ns: u64 }

pub(crate) mod instrumentation {
    use super::Result;
    use std::{cell::RefCell, rc::Rc, time::Instant};
    pub const TRANSFORM: usize = 0;
    pub const PAYLOAD: usize = 1;
    pub const MODEL_NEW: usize = 2;
    pub const FINISH_AUDIT: usize = 3;
    pub const NAMES: [&str;4] = ["branch_after_prefix","predict","range_and_selection","observe"];
    pub const TOP_NAMES: [&str;4] = ["transform","payload","model_new","finish_audit"];
    #[derive(Clone,Copy,Debug,PartialEq,Eq)]
    pub enum Mode { Disabled, Profile }
    impl Mode {
        pub fn parse(value:&str)->Result<Self> { match value {
            "disabled"=>Ok(Self::Disabled), "profile"=>Ok(Self::Profile), _=>Err("profile mode".into())
        }}
    }
    fn add(a:u64,b:u64)->Result<u64>{a.checked_add(b).ok_or_else(||"profile counter overflow".into())}
    pub fn expected_samples(n:u64)->u64{if n<128 {0}else{1+(n-128)/256}}
    pub fn residual(parent:u64,children:[u64;3])->Result<u64>{
        let sum=children.into_iter().try_fold(0u64,|a,b|a.checked_add(b).ok_or("profile child sum overflow"))?;
        parent.checked_sub(sum).ok_or_else(||"profile negative residual".into())
    }
    #[derive(Clone,Copy,Debug,PartialEq,Eq)]
    pub struct Ticket { pub serial:u64,pub direction:u8,pub stratum:usize,pub ordinal:u64 }
    #[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]
    pub struct Bucket { pub started:u64,pub ended:u64,pub pairs:u64,pub elapsed_ns:u64,pub active:Option<Ticket> }
    #[derive(Clone,Copy,Debug,PartialEq,Eq)]
    struct Branch { ticket:Ticket,stage:u8,elapsed:[u64;4] }
    #[derive(Clone,Debug,PartialEq,Eq)]
    pub struct State {
        pub mode:Mode,pub direction:u8,pub branch_started:u64,pub branch_completed:u64,
        pub totals:[u64;8],pub samples:[u64;8],pub residuals:[u64;8],pub component:[u64;2],
        pub escape:u64,pub serial:u64,pub committed_endpoints:u64,pub clock_attempts:u64,
        pub buckets:[Bucket;36],branch:Option<Branch>,
    }
    impl State {
        pub fn new(mode:Mode,direction:u8)->Self{Self{mode,direction,branch_started:0,branch_completed:0,
            totals:[0;8],samples:[0;8],residuals:[0;8],component:[0;2],escape:0,serial:0,
            committed_endpoints:0,clock_attempts:0,buckets:[Bucket::default();36],branch:None}}
        pub fn admit(&mut self,component:usize,prefix:usize)->Result<Option<Ticket>>{
            if component>1{return Err("profile component".into());}
            if !(1..=4).contains(&prefix){return Err("profile prefix".into());}
            if self.mode==Mode::Disabled{return Ok(None);}
            if self.branch.is_some(){return Err("profile unfinished scope".into());}
            let s=component*4+prefix-1;
            let started=add(self.branch_started,1)?;let ordinal=add(self.totals[s],1)?;
            let component_count=add(self.component[component],1)?;
            let sampled=ordinal%256==128;
            let samples=if sampled{add(self.samples[s],1)?}else{self.samples[s]};
            let serial=if sampled{add(self.serial,1)?}else{self.serial};
            let ticket=sampled.then_some(Ticket{serial,direction:self.direction,stratum:s,ordinal});
            self.branch_started=started;self.totals[s]=ordinal;self.component[component]=component_count;
            self.samples[s]=samples;self.serial=serial;
            self.branch=ticket.map(|ticket|Branch{ticket,stage:0,elapsed:[0;4]});
            Ok(ticket)
        }
        fn token(&self,index:usize,ticket:Option<Ticket>)->Result<Ticket>{
            if index>=36{return Err("profile ticket".into());}
            if index<4{return Ok(Ticket{serial:0,direction:self.direction,stratum:index,ordinal:0});}
            let t=ticket.ok_or("profile ticket")?;
            if t.direction!=self.direction||t.stratum>=8||index!=4+t.stratum*4+index%4{
                return Err("profile ticket".into());
            }
            if self.branch.as_ref().map(|b|b.ticket)!=Some(t){return Err("profile ticket".into());}
            Ok(t)
        }
        pub fn begin(&mut self,index:usize,ticket:Option<Ticket>)->Result<()> {
            if self.mode==Mode::Disabled{return Ok(());}
            if index>=36{return Err("profile ticket".into());}
            if self.buckets[index].active.is_some(){return Err("profile scope active".into());}
            let token=self.token(index,ticket)?;
            let mut branch=self.branch;
            if index>=4 {
                let kind=index%4;let b=branch.as_mut().ok_or("profile ticket")?;
                let expected=[0,1,3,5][kind];
                if b.stage!=expected{return Err("profile scope order".into());}
                b.stage=[1,2,4,6][kind];
            }
            let started=add(self.buckets[index].started,1)?;let endpoints=add(self.committed_endpoints,1)?;
            self.buckets[index].started=started;self.buckets[index].active=Some(token);
            self.committed_endpoints=endpoints;self.branch=branch;Ok(())
        }
        pub fn end(&mut self,index:usize,ticket:Option<Ticket>,elapsed:u128)->Result<()> {
            if self.mode==Mode::Disabled{return Ok(());}
            if index>=36{return Err("profile ticket".into());}
            let active=self.buckets[index].active.ok_or("profile scope inactive")?;
            let token=self.token(index,ticket)?;if token!=active{return Err("profile ticket".into());}
            let elapsed=u64::try_from(elapsed).map_err(|_|"profile counter overflow")?;
            let mut branch=self.branch;let mut next_residual=None;
            if index>=4 {
                let kind=index%4;let b=branch.as_mut().ok_or("profile ticket")?;
                if b.stage!=[7,2,4,6][kind]{return Err("profile scope order".into());}
                b.elapsed[kind]=elapsed;b.stage=[8,3,5,7][kind];
                if kind==0 {next_residual=Some(add(self.residuals[token.stratum],residual(elapsed,[b.elapsed[1],b.elapsed[2],b.elapsed[3]])?)?);}
            }
            let mut bucket=self.buckets[index];bucket.ended=add(bucket.ended,1)?;bucket.pairs=add(bucket.pairs,1)?;
            bucket.elapsed_ns=add(bucket.elapsed_ns,elapsed)?;bucket.active=None;
            let endpoints=add(self.committed_endpoints,1)?;
            self.buckets[index]=bucket;self.committed_endpoints=endpoints;self.branch=branch;
            if let Some(n)=next_residual{self.residuals[token.stratum]=n;}Ok(())
        }
        pub fn complete(&mut self,ticket:Option<Ticket>)->Result<()> {
            if self.mode==Mode::Disabled{return Ok(());}
            match (self.branch,ticket) {
                (Some(b),Some(t)) if b.ticket==t&&b.stage==8=>{},
                (None,None)=>{},_=>return Err("profile unfinished scope".into())
            }
            let n=add(self.branch_completed,1)?;self.branch_completed=n;self.branch=None;Ok(())
        }
        pub fn escape_success(&mut self)->Result<()> {if self.mode==Mode::Profile{self.escape=add(self.escape,1)?;}Ok(())}
        pub fn finish(&self,total:u64)->Result<u64> {
            if self.buckets.iter().any(|b|b.active.is_some())||self.branch.is_some(){return Err("profile unfinished scope".into());}
            for b in self.buckets {if b.started!=b.ended||b.ended!=b.pairs{return Err("profile scope count".into());}}
            if self.branch_started!=self.branch_completed{return Err("profile branch count".into());}
            for s in 0..8 {
                if self.samples[s]!=expected_samples(self.totals[s]){return Err("profile sample count".into());}
                for kind in 0..4{if self.buckets[4+s*4+kind].pairs!=self.samples[s]{return Err("profile scope count".into());}}
            }
            residual(total,[self.buckets[TRANSFORM].elapsed_ns,self.buckets[PAYLOAD].elapsed_ns,0])
        }
        pub fn first_difference(&self,other:&Self)->Option<String>{
            macro_rules! cmp{($($f:ident),*)=>{$(if self.$f!=other.$f{return Some(stringify!($f).into());})*}}
            cmp!(mode,direction,branch_started,branch_completed,totals,samples,residuals,component,escape,serial,committed_endpoints,clock_attempts,branch);
            self.buckets.iter().zip(other.buckets.iter()).position(|(a,b)|a!=b).map(|i|format!("bucket[{i}]"))
        }
        pub fn context_json(&self)->String{
            let ticket=self.branch.map(|b|format!("{{\"ticket\":{},\"component\":{},\"prefix\":{},\"ordinal\":{},\"stage\":{}}}",b.ticket.serial,b.ticket.stratum/4,b.ticket.stratum%4+1,b.ticket.ordinal,b.stage)).unwrap_or("null".into());
            let active=self.buckets.iter().position(|b|b.active.is_some()).map(|i|i.to_string()).unwrap_or("null".into());
            format!("{{\"branch\":{ticket},\"active_scope_index\":{active}}}")
        }
    }
    #[derive(Clone)] pub struct Handle(Rc<RefCell<State>>);
    pub struct Clock {index:usize,ticket:Option<Ticket>,begin:Instant}
    impl Handle {
        pub fn new(mode:Mode,direction:u8)->Self{Self(Rc::new(RefCell::new(State::new(mode,direction))))}
        pub fn snapshot(&self)->State{self.0.borrow().clone()}
        pub fn admit(&self,c:usize,p:usize)->Result<Option<Ticket>>{self.0.borrow_mut().admit(c,p)}
        pub fn complete(&self,t:Option<Ticket>)->Result<()>{self.0.borrow_mut().complete(t)}
        pub fn escape_success(&self)->Result<()>{self.0.borrow_mut().escape_success()}
        fn start(&self,index:usize,ticket:Option<Ticket>)->Result<Option<Clock>> {
            let mut state=self.0.borrow_mut();if state.mode==Mode::Disabled{return Ok(None);}
            let mut next=state.clone();next.begin(index,ticket)?;
            // 固定入力の全branch上限。synthetic MAX seedはこの実時計wrapperを通らない。
            if next.buckets[index].started>3825340{return Err("profile scope count".into());}
            next.clock_attempts=add(next.clock_attempts,1)?;
            let begin=Instant::now();*state=next;Ok(Some(Clock{index,ticket,begin}))
        }
        pub fn begin_top(&self,index:usize)->Result<Option<Clock>> {self.start(index,None)}
        pub fn begin_branch(&self,ticket:Option<Ticket>,kind:usize)->Result<Option<Clock>> {
            if let Some(t)=ticket{if kind>=4{return Err("profile ticket".into());}self.start(4+t.stratum*4+kind,Some(t))}else{Ok(None)}
        }
        pub fn end(&self,clock:Option<Clock>)->Result<()> {
            if let Some(c)=clock {
                let mut state=self.0.borrow_mut();state.clock_attempts=add(state.clock_attempts,1)?;
                let elapsed=c.begin.elapsed().as_nanos();
                let mut next=state.clone();next.end(c.index,c.ticket,elapsed)?;*state=next;
            }Ok(())
        }
    }

    pub const GROUPS:[(&str,u64);13]=[("GOLDEN",9),("STREAM",8),("STREAM_SCOPE",16),("TOP",1),("ESCAPE",1),
        ("BAD_COMPONENT",8),("BAD_PREFIX",6),("MODE_OK",2),("MODE_BAD",3),("DISABLED",1),("OVERFLOW",14),("LIFECYCLE",10),("RESIDUAL",4)];
    #[derive(Default)] pub struct E2e {
        pub completed:[u64;13],pub ok:u64,pub err:u64,pub loops:u64,pub stream_operations:u64,
        pub samples:u64,pub scope_pairs:u64,pub top_pairs:u64,pub escape_operations:u64,
        pub fixture:String,pub recipe:String,pub expected:String,pub actual:String,pub first_difference:Option<String>,
    }
    impl E2e {
        fn prepare(&mut self,g:usize,recipe:String,expected:&str) {
            self.fixture=GROUPS[g].0.into();self.recipe=recipe;self.expected=expected.into();
            self.actual="pending".into();self.first_difference=None;
        }
        fn case(&mut self,g:usize,recipe:String,expected:&str,actual:Result<()>,before:Option<&State>,after:Option<&State>)->Result<()> {
            self.prepare(g,recipe,expected);
            self.actual=match &actual{Ok(())=>"Ok".into(),Err(e)=>format!("Err({e})")};
            if expected!=self.actual{self.first_difference=Some("Result".into());return Err(format!("contract Result mismatch: {}",self.fixture));}
            if let (Some(a),Some(b))=(before,after){if a!=b{self.first_difference=a.first_difference(b);return Err("contract rejection mutated state".into());}}
            self.completed[g]+=1;if actual.is_ok(){self.ok+=1;}else{self.err+=1;}Ok(())
        }
        fn reject<F>(&mut self,g:usize,recipe:String,mut state:State,expected:&str,f:F)->Result<()> where F:FnOnce(&mut State)->Result<()> {
            self.prepare(g,recipe.clone(),&format!("Err({expected})"));
            let before=state.clone();let actual=f(&mut state);
            self.case(g,recipe,&format!("Err({expected})"),actual,Some(&before),Some(&state))
        }
        pub fn json(&self)->String {
            let groups=GROUPS.iter().enumerate().map(|(i,(name,n))|format!("{{\"name\":{},\"planned\":{n},\"completed\":{}}}",super::quote(name),self.completed[i])).collect::<Vec<_>>().join(",");
            format!("{{\"loops\":{{\"planned\":12,\"completed\":{}}},\"cases\":{{\"planned\":83,\"completed\":{},\"ok\":{},\"expected_err\":{}}},\"groups\":[{groups}],\"operations\":{{\"stream_branches\":{},\"samples\":{},\"scope_pairs\":{},\"top_pairs\":{},\"escape_successes\":{}}}}}",self.loops,self.completed.iter().sum::<u64>(),self.ok,self.err,self.stream_operations,self.samples,self.scope_pairs,self.top_pairs,self.escape_operations)
        }
    }
    fn ok(condition:bool)->Result<()>{if condition{Ok(())}else{Err("contract value mismatch".into())}}
    fn sample_seed()->Result<(State,Ticket)> {
        let mut s=State::new(Mode::Profile,0);s.totals[0]=127;
        let t=s.admit(0,1)?.ok_or("missing sample")?;Ok((s,t))
    }
    fn stage_seed(stage:u8)->Result<(State,Ticket)> {
        let (mut s,t)=sample_seed()?;s.begin(4,Some(t))?;
        if stage>=2{s.begin(5,Some(t))?;}
        if stage>=3{s.end(5,Some(t),10)?;}
        if stage>=4{s.begin(6,Some(t))?;}
        if stage>=5{s.end(6,Some(t),20)?;}
        if stage>=6{s.begin(7,Some(t))?;}
        if stage>=7{s.end(7,Some(t),30)?;}
        Ok((s,t))
    }
    pub fn contract_e2e(e:&mut E2e)->Result<()> {
        let result=contract_e2e_body(e);
        if let Err(error)=&result {
            if e.actual=="pending" {e.actual=format!("Err({error})");}
        }
        result
    }
    fn contract_e2e_body(e:&mut E2e)->Result<()> {
        let ns=[0,1,127,128,129,383,384,385,u64::MAX];let golden=[0,0,0,1,1,1,2,2,72057594037927936];
        for (n,want) in ns.into_iter().zip(golden){e.case(0,format!("expected_samples({n})={want}"),"Ok",ok(expected_samples(n)==want),None,None)?;}e.loops+=1;
        let mut stream=State::new(Mode::Profile,0);
        for c in 0..2{for p in 1..5 {
            let s=c*4+p-1;
            for ordinal in 1..=385 {
                let group=if ordinal%256==128{2}else{1};
                e.prepare(group,format!("component={c},prefix={p},ordinal={ordinal},admit/scope100/10/20/30/complete"),"Ok");
                let ticket=stream.admit(c,p)?;e.stream_operations+=1;
                if let Some(t)=ticket {
                    stream.begin(4+s*4,Some(t))?;
                    for (kind,duration) in [(1,10),(2,20),(3,30)] {stream.begin(4+s*4+kind,Some(t))?;stream.end(4+s*4+kind,Some(t),duration)?;}
                    stream.end(4+s*4,Some(t),100)?;
                    e.case(2,format!("component={c},prefix={p},ordinal={ordinal},ns=100/10/20/30"),"Ok",ok((ordinal==128||ordinal==384)&&t.ordinal==ordinal&&stream.residuals[s]==stream.samples[s]*40&&stream.buckets[4+s*4].pairs==stream.samples[s]),None,None)?;
                    e.samples+=1;e.scope_pairs+=4;
                }else if ordinal==128||ordinal==384{return Err("missing selected ordinal".into());}
                e.prepare(group,format!("component={c},prefix={p},ordinal={ordinal},complete"),"Ok");
                stream.complete(ticket)?;
            }
            e.case(1,format!("component={c},prefix={p},385 branches"),"Ok",ok(stream.totals[s]==385&&stream.samples[s]==2&&stream.buckets[4+s*4..8+s*4].iter().zip([200,20,40,60]).all(|(b,n)|b.started==2&&b.ended==2&&b.pairs==2&&b.elapsed_ns==n)),None,None)?;
        }}
        e.prepare(1,"stream summary: branches3080/endpoints128/residual640/finish".into(),"Ok");
        ok(stream.branch_started==3080&&stream.branch_completed==3080&&stream.committed_endpoints==128&&stream.residuals.iter().sum::<u64>()==640)?;
        stream.finish(0)?;e.loops+=1;
        let mut top=State::new(Mode::Profile,0);
        for (i,n) in [(0,100),(1,200),(2,20),(3,30)]{e.prepare(3,format!("top index={i},ns={n},begin/end"),"Ok");top.begin(i,None)?;top.end(i,None,n)?;}
        e.prepare(3,"top ns=100/200/20/30,total350,finish".into(),"Ok");
        e.case(3,"top ns=100/200/20/30,total350".into(),"Ok",ok(top.finish(350)?==50&&top.buckets[..4].iter().all(|b|b.started==1&&b.ended==1&&b.pairs==1)),None,None)?;e.top_pairs=4;e.loops+=1;
        let mut escape=State::new(Mode::Profile,0);for ordinal in 1..=7{e.prepare(4,format!("escape ordinal={ordinal}/7"),"Ok");escape.escape_success()?;}
        let mut want=State::new(Mode::Profile,0);want.escape=7;
        e.case(4,"escape success7".into(),"Ok",ok(escape==want),None,None)?;e.escape_operations=7;e.loops+=1;
        for c in [2,usize::MAX]{for p in 1..5{e.reject(5,format!("component={c},prefix={p}"),State::new(Mode::Profile,0),"profile component",|s|s.admit(c,p).map(|_|()))?;}}e.loops+=1;
        for c in 0..2{for p in [0,5,usize::MAX]{e.reject(6,format!("component={c},prefix={p}"),State::new(Mode::Profile,0),"profile prefix",|s|s.admit(c,p).map(|_|()))?;}}e.loops+=1;
        for (text,mode) in [("disabled",Mode::Disabled),("profile",Mode::Profile)]{e.prepare(7,text.into(),"Ok");e.case(7,text.into(),"Ok",ok(Mode::parse(text)?==mode),None,None)?;}e.loops+=1;
        for text in ["","sample","PROFILE"]{let s=State::new(Mode::Profile,0);e.case(8,text.into(),"Err(profile mode)",Mode::parse(text).map(|_|()),Some(&s),Some(&s))?;}e.loops+=1;
        let mut disabled=State::new(Mode::Disabled,0);let before=disabled.clone();
        for ordinal in 1..=385{e.prepare(9,format!("disabled branch ordinal={ordinal}/385,admit/complete"),"Ok");let t=disabled.admit(0,1)?;ok(t.is_none())?;disabled.complete(t)?;}
        for ordinal in 1..=7{e.prepare(9,format!("disabled escape ordinal={ordinal}/7"),"Ok");disabled.escape_success()?;}for i in 0..4{e.prepare(9,format!("disabled top index={i},begin/end"),"Ok");disabled.begin(i,None)?;disabled.end(i,None,1)?;}
        e.case(9,"disabled branches385/escape7/top4".into(),"Ok",Ok(()),Some(&before),Some(&disabled))?;e.loops+=1;
        for recipe in 1..=14 {
            e.prepare(10,format!("overflow recipe{recipe},seed"),"Ok(seed)");
            let (mut s,t)=if (7..=10).contains(&recipe){stage_seed(2)?}else if recipe==13{stage_seed(7)?}else{sample_seed()?};
            // 非scope recipeはfresh状態に必要なseedだけを置く。
            if recipe<=3||recipe==5||recipe==6||recipe==12{s=State::new(Mode::Profile,0);}
            match recipe {
                1=>s.branch_started=u64::MAX,2=>s.totals[0]=u64::MAX,
                3=>{s.totals[0]=127;s.samples[0]=u64::MAX;},4=>s.buckets[4].started=u64::MAX,
                5=>s.branch_completed=u64::MAX,6=>s.escape=u64::MAX,
                7=>s.buckets[5].ended=u64::MAX,8=>s.buckets[5].pairs=u64::MAX,
                9=>s.buckets[5].elapsed_ns=u64::MAX,11=>s.committed_endpoints=u64::MAX,
                12=>{s.totals[0]=127;s.serial=u64::MAX;},13=>s.residuals[0]=u64::MAX,_=>{}
            }
            let expected=if recipe==14{"profile child sum overflow"}else{"profile counter overflow"};
            e.reject(10,format!("overflow recipe{recipe}"),s,expected,|s|match recipe {
                1..=3|12=>s.admit(0,1).map(|_|()),4|11=>s.begin(4,Some(t)),5=>s.complete(None),6=>s.escape_success(),
                7..=9=>s.end(5,Some(t),1),10=>s.end(5,Some(t),u128::from(u64::MAX)+1),
                13=>s.end(4,Some(t),61),14=>residual(u64::MAX,[u64::MAX,1,0]).map(|_|()),_=>unreachable!()
            })?;
        }e.loops+=1;
        for recipe in 1..=10 {
            e.prepare(11,format!("lifecycle recipe{recipe},seed"),"Ok(seed)");
            let (mut s,t)=match recipe {1|3|4|6|9=>stage_seed(1)?,5=>stage_seed(3)?,7=>stage_seed(3)?,8=>stage_seed(5)?,_=>sample_seed()?};
            if recipe==2{s=State::new(Mode::Profile,0);}
            if recipe==10{s=State::new(Mode::Profile,0);s.buckets[0].started=1;}
            let expected=match recipe{1=>"profile scope active",2|5=>"profile scope inactive",3|4=>"profile ticket",6..=8=>"profile scope order",9=>"profile unfinished scope",10=>"profile scope count",_=>unreachable!()};
            e.reject(11,format!("lifecycle recipe{recipe}"),s,expected,|s|match recipe {
                1=>s.begin(4,Some(t)),2=>s.end(0,None,1),
                3=>s.end(4,Some(Ticket{serial:t.serial+1,..t}),100),4=>s.end(4,Some(Ticket{direction:1,..t}),100),
                5=>s.end(5,Some(t),10),6=>s.begin(6,Some(t)),7=>s.begin(7,Some(t)),8=>s.end(4,Some(t),100),
                9|10=>s.finish(0).map(|_|()),_=>unreachable!()
            })?;
        }e.loops+=1;
        for recipe in 1..=4 {
            e.prepare(12,format!("residual recipe{recipe},seed"),"Ok(seed)");
            let mut s=State::new(Mode::Profile,0);
            if recipe==2{for (i,n) in [(0,100),(1,200)]{s.begin(i,None)?;s.end(i,None,n)?;}}
            if recipe==3{s.totals[0]=384;s.samples[0]=1;}
            if recipe==4{s.branch_started=1;}
            let expected=match recipe{1|2=>"profile negative residual",3=>"profile sample count",4=>"profile branch count",_=>unreachable!()};
            e.reject(12,format!("residual recipe{recipe}"),s,expected,|s|match recipe {
                1=>residual(59,[10,20,30]).map(|_|()),2=>s.finish(299).map(|_|()),3|4=>s.finish(0).map(|_|()),_=>unreachable!()
            })?;
        }e.loops+=1;
        e.fixture="TOTAL".into();e.recipe="12loop/13group/83case/38Ok/45Err".into();e.expected="Ok".into();e.actual="pending".into();e.first_difference=None;
        ok(e.loops==12&&e.completed.iter().sum::<u64>()==83&&e.ok==38&&e.err==45)?;
        e.fixture.clear();e.recipe.clear();e.expected.clear();e.actual.clear();Ok(())
    }
}

fn quote(value:&str)->String {
    let mut out=String::from("\"");for c in value.chars(){match c {'"'=>out.push_str("\\\""),'\\'=>out.push_str("\\\\"),'\n'=>out.push_str("\\n"),'\r'=>out.push_str("\\r"),'\t'=>out.push_str("\\t"),c if c.is_control()=>out.push_str(&format!("\\u{:04x}",c as u32)),c=>out.push(c)}}out.push('"');out
}
fn bounded_quote(value:&str,max_chars:usize,max_bytes:usize)->String {
    let mut plain=String::new();for c in value.chars().take(max_chars){plain.push(c);if quote(&plain).len()>max_bytes{plain.pop();break;}}quote(&plain)
}

fn fixed_stats(frame_bytes:usize,stats:&str)->Result<()> {
    let expected="{\"depth\":5,\"node_count\":1365,\"node_storage_bytes\":196560,\"magic\":\"KHQCID01\",\"header_crc_covers_depth\":true,\"frame_bytes\":478750,\"header_bytes\":285,\"payload_bytes\":478465,\"plain_crc\":433441561,\"payload_crc\":3616798779,\"header_crc\":621578488,\"runs\":889227,\"primary\":1762795,\"alphabet_symbols\":257,\"rank_intervals\":889227,\"length_intervals\":889227,\"escape_bytes\":742,\"branches\":[2725772, 1099568],\"grammar_digest\":\"58735a2b7383d755\",\"base_pool_digest\":\"0caac94407124a37\",\"class_observations\":[889227, 620240, 1216305, 889227, 64372, 145969],\"cdf_entropy_bits\":3820763.985142052}";
    // f64 auditだけは計画のfixed許容差、実結果間は全bit・全stats exact比較。
    let marker="\"cdf_entropy_bits\":";
    let (actual_head,actual_tail)=stats.split_once(marker).ok_or("fixed stats schema")?;
    let (expected_head,_)=expected.split_once(marker).ok_or("fixed stats recipe")?;
    let cdf=actual_tail.strip_suffix('}').ok_or("fixed stats schema")?.parse::<f64>().map_err(|_|"fixed CDF schema")?;
    if frame_bytes!=478750||actual_head!=expected_head||!cdf.is_finite()||(cdf-3820763.985142052).abs()>1e-4{return Err("fixed depth5 stats mismatch".into());}Ok(())
}
fn profile_json(state:&instrumentation::State,total:Option<u64>)->String {
    let buckets=state.buckets.iter().enumerate().map(|(i,b)|{
        let stratum=if i<4{"null".into()}else{(i/4-1).to_string()};
        format!("[{}, {stratum},{},{},{},{},{}]",i%4,b.started,b.ended,b.pairs,b.elapsed_ns,b.active.is_some())
    }).collect::<Vec<_>>().join(",");
    let residual=total.and_then(|n|state.finish(n).ok()).map(|n|n.to_string()).unwrap_or("null".into());
    format!("{{\"direction\":{},\"branch_started\":{},\"branch_completed\":{},\"component\":{:?},\"stratum_totals\":{:?},\"stratum_samples\":{:?},\"sample_residual_ns\":{:?},\"escape_successes\":{},\"clock_attempts\":{},\"committed_endpoints\":{},\"total_ns\":{},\"top_residual_ns\":{residual},\"bucket_columns\":[\"kind\",\"stratum\",\"started\",\"ended\",\"pairs\",\"inclusive_ns\",\"active\"],\"top_kind_names\":[\"transform\",\"payload\",\"model_new\",\"finish_audit\"],\"branch_kind_names\":[\"branch_after_prefix\",\"predict\",\"range_and_selection\",\"observe\"],\"buckets\":[{buckets}],\"context\":{},\"sample_estimate_emitted\":false,\"payload_exact_exclusive_emitted\":false}}",
        state.direction,state.branch_started,state.branch_completed,state.component,state.totals,state.samples,state.residuals,state.escape,state.clock_attempts,state.committed_endpoints,total.map(|n|n.to_string()).unwrap_or("null".into()),state.context_json())
}
struct Run {
    phase:&'static str,e2e:instrumentation::E2e,input_reads:u64,overhead_completed:u64,overhead_ns:u64,overhead_pair_sum_ns:u64,
    started:[u64;3],completed:[u64;3],frame_comparisons:u64,plain_comparisons:u64,proof_comparisons:u64,
    matched_prefix_bytes:usize,first_difference:Option<String>,header64:String,stats:Vec<String>,totals:[Option<u64>;3],
    reference_frames:u64,peak_frames:u64,peak_frame_bytes:usize,
    disabled:instrumentation::Handle,encode:instrumentation::Handle,decode:instrumentation::Handle,
}
impl Run {
    fn new()->Self{use instrumentation::{Handle,Mode};Self{phase:"arguments",e2e:Default::default(),input_reads:0,overhead_completed:0,overhead_ns:0,
        overhead_pair_sum_ns:0,started:[0;3],completed:[0;3],frame_comparisons:0,plain_comparisons:0,proof_comparisons:0,matched_prefix_bytes:0,first_difference:None,
        header64:String::new(),stats:Vec::new(),totals:[None;3],reference_frames:0,peak_frames:0,peak_frame_bytes:0,
        disabled:Handle::new(Mode::Disabled,0),encode:Handle::new(Mode::Profile,0),decode:Handle::new(Mode::Profile,1)}}
    fn compare_bytes(&mut self,name:&str,a:&[u8],b:&[u8])->Result<()> {
        self.matched_prefix_bytes=0;
        for (index,(&x,&y)) in a.iter().zip(b).enumerate(){if x!=y{self.first_difference=Some(format!("{name}[{index}]:{x}!={y}"));return Err(format!("{name} byte mismatch"));}self.matched_prefix_bytes+=1;}
        if a.len()!=b.len(){self.first_difference=Some(format!("{name}.length:{}!={}",a.len(),b.len()));return Err(format!("{name} length mismatch"));}Ok(())
    }
    fn profile(&mut self,input_path:&str)->Result<()> {
        self.phase="contract_e2e";instrumentation::contract_e2e(&mut self.e2e)?;
        self.phase="empty_instant_pairs";
        let overhead_begin=Instant::now();
        for _ in 0..10000{let begin=Instant::now();let elapsed=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"overhead timer overflow")?;
            self.overhead_pair_sum_ns=self.overhead_pair_sum_ns.checked_add(elapsed).ok_or("overhead sum overflow")?;self.overhead_completed+=1;}
        self.overhead_ns=u64::try_from(overhead_begin.elapsed().as_nanos()).map_err(|_|"overhead timer overflow")?;
        self.phase="input_read";
        let input={use std::io::Read;let file=std::fs::File::open(input_path).map_err(|e|format!("input open: {e}"))?;
            let meta=file.metadata().map_err(|e|format!("input metadata: {e}"))?;
            if !meta.is_file()||meta.len()!=2811006{return Err("fixed input bytes/type mismatch".into());}
            let mut bytes=Vec::new();bytes.try_reserve_exact(2811006).map_err(|_|"input allocation")?;
            file.take(2811007).read_to_end(&mut bytes).map_err(|e|format!("input read: {e}"))?;
            if bytes.len()!=2811006{return Err("fixed input read length mismatch".into());}self.input_reads=1;bytes};
        self.phase="reference_encode";self.started[0]=1;
        let reference=codec::run_profile(&input,5,&self.disabled)?;self.completed[0]=1;self.totals[0]=Some(reference.elapsed_ns);
        self.reference_frames=1;self.peak_frames=1;self.peak_frame_bytes=reference.frame.len();
        reference.proof.validate_fixed(5)?;fixed_stats(reference.frame.len(),&reference.stats)?;self.stats.push(reference.stats.clone());
        if self.disabled.snapshot()!=instrumentation::State::new(instrumentation::Mode::Disabled,0){return Err("disabled profile changed".into());}
        self.phase="profile_encode";self.started[1]=1;
        let encoded=codec::run_profile(&input,5,&self.encode)?;self.completed[1]=1;self.totals[1]=Some(encoded.elapsed_ns);
        self.peak_frames=2;self.peak_frame_bytes=reference.frame.len().checked_add(encoded.frame.len()).ok_or("frame ownership bytes overflow")?;
        self.header64=encoded.frame.iter().take(64).map(|v|format!("{v:02x}")).collect();
        encoded.proof.validate_fixed(5)?;fixed_stats(encoded.frame.len(),&encoded.stats)?;self.stats.push(encoded.stats.clone());
        self.phase="profile_decode";self.started[2]=1;
        let decoded=codec::run_restore(&encoded.frame,&self.decode)?;self.completed[2]=1;self.totals[2]=Some(decoded.elapsed_ns);
        decoded.proof.validate_fixed(5)?;fixed_stats(encoded.frame.len(),&decoded.stats)?;self.stats.push(decoded.stats.clone());
        self.phase="frame_comparison";self.compare_bytes("frame",&reference.frame,&encoded.frame)?;self.frame_comparisons=1;
        self.phase="plain_comparison";self.compare_bytes("plain",&input,&decoded.plain)?;self.plain_comparisons=1;
        self.phase="proof_comparison";
        for (label,other) in [("profile_encode",&encoded.proof),("profile_decode",&decoded.proof)]{
            if let Some(field)=reference.proof.first_difference(other){self.first_difference=Some(format!("{label}.proof.{field}"));return Err("Proof14 mismatch".into());}self.proof_comparisons+=1;
        }
        self.phase="stats_comparison";
        for (i,stats) in self.stats.iter().enumerate().skip(1){if stats!=&self.stats[0]{self.first_difference=Some(format!("stats[{i}]"));return Err("all stats mismatch".into());}}
        drop(reference);self.reference_frames=0;
        self.phase="profile_finish";let en=self.encode.snapshot();let de=self.decode.snapshot();
        for (state,total) in [(&en,encoded.elapsed_ns),(&de,decoded.elapsed_ns)]{
            state.finish(total)?;
            if state.branch_started!=3825340||state.branch_completed!=3825340||state.component!=[2725772,1099568]||state.escape!=742{return Err("fixed branch/escape counters".into());}
            if state.buckets[..4].iter().any(|b|b.started!=1||b.ended!=1||b.pairs!=1){return Err("top stage count".into());}
            let samples=state.samples.iter().try_fold(0u64,|a,&b|a.checked_add(b).ok_or("sample total overflow"))?;
            if state.committed_endpoints!=8+samples*8||state.clock_attempts!=state.committed_endpoints{return Err("clock endpoint count".into());}
        }
        if en.totals!=de.totals||en.samples!=de.samples{return Err("direction stratum count mismatch".into());}
        if self.peak_frames!=2||self.peak_frame_bytes!=957500||self.reference_frames!=0{return Err("frame ownership counters".into());}
        self.phase="completed";Ok(())
    }
    fn json(&self,error:Option<&str>)->String {
        let calls=["reference_encode","profile_encode","profile_decode"].iter().enumerate().map(|(i,name)|format!("{{\"name\":{},\"planned\":1,\"started\":{},\"completed\":{}}}",quote(name),self.started[i],self.completed[i])).collect::<Vec<_>>().join(",");
        let profiles=[profile_json(&self.encode.snapshot(),self.totals[1]),profile_json(&self.decode.snapshot(),self.totals[2])].join(",");
        let failure=if let Some(error)=error{format!("{{\"phase\":{},\"error\":{},\"fixture\":{},\"recipe\":{},\"expected\":{},\"actual\":{},\"first_difference\":{},\"matched_prefix_bytes\":{},\"header64_hex\":{}}}",quote(self.phase),bounded_quote(error,2048,512),bounded_quote(&self.e2e.fixture,64,32),bounded_quote(&self.e2e.recipe,512,256),bounded_quote(&self.e2e.expected,1024,64),bounded_quote(&self.e2e.actual,1024,64),self.first_difference.as_ref().or(self.e2e.first_difference.as_ref()).map(|s|bounded_quote(s,256,128)).unwrap_or("null".into()),self.matched_prefix_bytes,quote(&self.header64))}else{"null".into()};
        format!("{{\"schema_version\":1,\"status\":{},\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"independent_reference_oracle\":false,\"phase\":{},\"contract_e2e\":{},\"codec_calls\":[{calls}],\"input_reads\":{{\"planned\":1,\"completed\":{}}},\"overhead_pairs\":{{\"planned\":10000,\"completed\":{},\"elapsed_ns\":{},\"includes_counter_loop\":true,\"subtracted\":false}},\"comparisons\":{{\"frame\":{{\"planned\":1,\"completed\":{},\"bytes\":478750}},\"plain\":{{\"planned\":1,\"completed\":{},\"bytes\":2811006}},\"proof\":{{\"planned\":2,\"completed\":{},\"fields_per_pair\":14,\"cdf_to_bits\":true}}}},\"profiles\":[{profiles}],\"stats\":[{}],\"reference_encode_total_ns\":{},\"peak_live_candidate_frames\":{},\"peak_live_candidate_frame_bytes\":{},\"reference_frames_remaining\":{},\"frame_clones\":0,\"disk_input_frame_plain_copies\":0,\"warmup_runs\":0,\"abba_cycles\":0,\"failure_evidence\":{failure},\"limitations\":[\"same_body_disabled_reference\",\"periodic_sampling_bias\",\"cold_rescale_bias\",\"clock_resolution_and_observation_overhead\",\"not_holdout_or_formal_benchmark\"]}}",
            quote(if error.is_some(){"failed"}else{"passed"}),quote(self.phase),self.e2e.json(),self.input_reads,self.overhead_completed,self.overhead_ns,self.frame_comparisons,self.plain_comparisons,self.proof_comparisons,self.stats.join(","),self.totals[0].map(|n|n.to_string()).unwrap_or("null".into()),self.peak_frames,self.peak_frame_bytes,self.reference_frames)
    }
}
fn main() {
    let mut run=Run::new();let args=std::env::args().collect::<Vec<_>>();
    let result=if args.len()!=3||args[1]!="profile"{Err("usage: stage-profile profile INPUT".into())}else{run.profile(&args[2])};
    let json=run.json(result.as_ref().err().map(String::as_str));
    if json.len()>16384{eprintln!("bounded CLI JSON exceeded 16384 bytes");std::process::exit(2);}
    println!("{json}");if result.is_err(){std::process::exit(1);}
}
