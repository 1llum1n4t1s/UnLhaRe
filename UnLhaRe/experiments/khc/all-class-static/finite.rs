//! @happypath @category happy/boundary @severity HIGH
//! 新規記述。全fixtureはRAMのみ、入力合計32768Bまで、逐次解放する。
use crate::{codebook,packet,paid_model as model};
type Result<T>=std::result::Result<T,String>;
fn order_fixtures()->Result<()> {
    let enc=codebook::Encoder::new(codebook::LENGTHS)?;let dec=codebook::Decoder::new(codebook::LENGTHS)?;
    for oldest in [false,true]{let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;
        for h in 0..1024u16{let mut row=[0;4];row[if oldest{(usize::from(h)>>8)%2}else{usize::from(h)%2}]=64;crate::bundle::ingest(&mut low,2,h,row)?;crate::bundle::ingest(&mut high,2,model::reverse_history(h),row)?;}
        let l=model::Fit::build(&low)?;let r=model::Fit::build_high(&high)?;let selected=model::Selected::new(&l,&r)?;
        if l.root_objective_bits(2)?!=if oldest{4438}else{18} || r.root_objective_bits(2)?!=if oldest{18}else{4438} || selected.root_high(2)?!=oldest{return Err("finite low/high actual root order fee".into());}
        for fit in [&l,&r]{let(bytes,bits)=fit.root_wire(2,&enc)?;let d=model::parse_root(&bytes,bits,2,&dec)?;
            for h in 0..1024u16{let mut expected=[2,2,0,0];expected[if oldest{(usize::from(h)>>8)%2}else{usize::from(h)%2}]=32766;
                if fit.lookup(0,2,h)?!=expected || d.lookup(0,2,h)?!=expected{return Err("finite low/high/depth5 CDF".into());}
            }
        }
        if oldest{let mut p=packet::Packet::new(&enc)?;for _ in 0..284{for k in 2..=4{p.append_root(&selected,k)?;}}let data=p.finish()?;
            if data.len()!=880{return Err("finite high allpacket actual880".into());}let forest=packet::Forest::parse(&data)?;
            for c in 0..2{for n in 0..142{for k in 2..=4{for h in 0..1024u16{if forest.lookup(c,n,k,h)?!=selected.lookup(0,k,h)?{return Err("finite high allpacket integer CDF".into());}}}}}
        }
    }Ok(())
}
pub fn run()->Result<String>{
    order_fixtures()?;let mut report=String::new();report.try_reserve_exact(4096).map_err(|_|"finite report allocation")?;
    let mut coded=[0u64;6];let mut prefixes=[0u64;4];let mut implicit=0u64;let mut bytes=0usize;let mut maximum_input=0usize;let mut cdfs=0usize;let mut fits=0usize;let mut max_model=0usize;let mut max_phase=0usize;
    report.push_str("{\"case_columns\":[\"input_bytes\",\"runs\",\"escape_bytes\",\"grammar\",\"ideal_token_bytes\",\"packet_bytes\",\"implicit_k1\",\"packet_bits\",\"pad_bits\",\"known_minor\",\"ESC_minor\"],\"cases\":[");
    for case in 0..8{let mut plain=match case{0=>Vec::new(),1=>vec![165],2=>(0..=255u8).collect(),3=>vec![7;1024],4=>vec![0;4096],5=>(0..4096).map(|i|(i%256) as u8).collect(),6=>vec![0;16384],_=> (0..192).map(|i|(i%3) as u8).collect()};
        if case==4{for i in (0..4096).step_by(127){plain[i]=255;}}
        if case==6{let mut state=0x6d2b79f5u32;for v in &mut plain{state^=state<<13;state^=state>>17;state^=state<<5;*v=state as u8;}}
        if plain.len()>32768 || plain.capacity()>32768{return Err("finite input32KiB".into());}
        let s=crate::evaluate(&plain,plain.capacity(),report.capacity()+std::mem::size_of::<String>(),false)?;
        for i in 0..6{coded[i]+=s.coded[i];for k in 0..4{prefixes[k]+=s.meta.prefixes[i][k];}}
        implicit+=s.implicit;bytes+=plain.len();maximum_input=maximum_input.max(plain.len());cdfs+=s.individual_cdfs+s.forest_cdfs;fits+=s.training_fits+s.verification_fits;max_model=max_model.max(s.model_ram);max_phase=max_phase.max(s.phase_ram);
        if case!=0{report.push(',');}let row=format!("[{}, {}, {}, {}, {}, {}, {}, {}, {}, {}, {}]",plain.len(),s.meta.runs,s.meta.escapes,s.meta.grammar,s.token_bytes,s.bytes,s.implicit,s.bits,s.pad,s.known,s.escapes);
        if report.len()+row.len()+1024>4096{return Err("finite report bound".into());}report.push_str(&row);
    }
    if bytes>32768 || maximum_input!=16384{return Err("finite aggregate input32KiB".into());}
    if coded.contains(&0) || prefixes.contains(&0) || implicit==0{return Err("finite allclass/prefix/k1 coverage".into());}
    report.push_str(&format!("],\"input_bytes_total\":{bytes},\"input_reads\":0,\"BWT_calls\":8,\"grammar_walks\":16,\"case_Fit_builds\":{fits},\"order_fixture_Fit_builds\":4,\"order_fixture_root_CDF_comparisons\":4096,\"order_fixture_Forest_CDF_comparisons\":872448,\"order_fixture_high_packet_bytes\":880,\"case_Forest_parse_calls\":8,\"order_fixture_Forest_parse_calls\":1,\"total_Forest_parse_calls\":9,\"maximum_synthetic_packet_bytes\":880,\"combined_individual_and_Forest_CDF_comparisons\":{cdfs},\"coded_class_counts\":{coded:?},\"prefix_counts\":{prefixes:?},\"implicit_k1_per_training_walks\":{implicit},\"all_class_coverage\":true,\"whole_Meta_equal\":true,\"model_count_per_case\":284,\"root_count_per_case\":852,\"maximum_input_bytes\":{maximum_input},\"aggregate_input_bound_bytes\":32768,\"max_model_RAM_estimate_bytes\":{max_model},\"max_phase_RAM_estimate_bytes\":{max_phase},\"RAM_only\":true}}"));
    if report.len()>4096 || report.capacity()>4096{return Err("finite final report bound".into());}Ok(report)
}
