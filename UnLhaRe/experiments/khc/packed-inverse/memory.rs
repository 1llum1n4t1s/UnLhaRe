use crate::contract::Result;
use std::ffi::c_void;
#[repr(C)]
#[derive(Default)]
struct CountersEx {
    cb:u32,page_fault_count:u32,peak_working_set:usize,working_set:usize,
    quota_peak_paged:usize,quota_paged:usize,quota_peak_nonpaged:usize,quota_nonpaged:usize,
    pagefile_usage:usize,peak_pagefile_usage:usize,private_usage:usize,
}
#[link(name="kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess()->*mut c_void;
    fn K32GetProcessMemoryInfo(process:*mut c_void,counters:*mut c_void,cb:u32)->i32;
}
pub fn validate_layout()->Result<()>{
    use std::mem::{size_of,align_of,offset_of};
    let offsets=[offset_of!(CountersEx,cb),offset_of!(CountersEx,page_fault_count),offset_of!(CountersEx,peak_working_set),offset_of!(CountersEx,working_set),offset_of!(CountersEx,quota_peak_paged),offset_of!(CountersEx,quota_paged),offset_of!(CountersEx,quota_peak_nonpaged),offset_of!(CountersEx,quota_nonpaged),offset_of!(CountersEx,pagefile_usage),offset_of!(CountersEx,peak_pagefile_usage),offset_of!(CountersEx,private_usage)];
    if size_of::<usize>()!=8 || size_of::<u32>()!=4 || size_of::<CountersEx>()!=80 || align_of::<CountersEx>()!=8 || offsets!=[0,4,8,16,24,32,40,48,56,64,72]{return Err("Windows x64 memory API ABI layout".into());}
    Ok(())
}
pub fn read_once()->Result<(String,Option<bool>)>{
    validate_layout()?;
    let mut counters=CountersEx{cb:80,..Default::default()};
    // 公式EX ABIの実buffer80Bとcb80Bを一致させる。pseudo handleを閉じない。
    let ok=unsafe{K32GetProcessMemoryInfo(GetCurrentProcess(),(&mut counters as *mut CountersEx).cast(),80)};
    if ok==0{
        let error=std::io::Error::last_os_error().raw_os_error();
        let error_json=error.map_or_else(||"null".into(),|e|e.to_string());
        return Ok((format!("{{\"API_calls\":1,\"ABI_size\":80,\"ABI_cb\":80,\"ABI_checked\":true,\"measured\":false,\"last_OS_error\":{error_json},\"peak_working_set_bytes\":null,\"peak_private_commit_bytes\":null,\"peak_gate_passed\":null}}"),None));
    }
    let passed=counters.peak_working_set<=160<<20;
    Ok((format!("{{\"API_calls\":1,\"ABI_size\":80,\"ABI_cb\":80,\"ABI_checked\":true,\"measured\":true,\"last_OS_error\":null,\"peak_working_set_bytes\":{},\"working_set_bytes\":{},\"peak_private_commit_bytes\":{},\"private_usage_bytes\":{},\"peak_gate_passed\":{passed}}}",counters.peak_working_set,counters.working_set,counters.peak_pagefile_usage,counters.private_usage),Some(passed)))
}
