[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-anchored-wire-20261004'
$exe=Join-Path $work 'anchored-wire-o3.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$helper=Join-Path $PSScriptRoot '../float-fresh-transaction/run-native.ps1'
$frozenSourceRoot=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($helper))
$pricePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../prices.rs'))
$created=$false;$locks=[Collections.Generic.List[IO.FileStream]]::new();$sources=[Collections.Generic.List[object]]::new();$graph=[Collections.Generic.List[object]]::new();$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();compile_calls=0;total_native_calls=0;diagnostic_only=$true;frozen_entrypoints_executed=$false;disk_frame_plain_input_copies=0;raw_traces=0}
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 24) -ceq ($b|ConvertTo-Json -Compress -Depth 24)}
function Near([double]$a,[double]$b){if(![double]::IsFinite($a) -or ![double]::IsFinite($b) -or [math]::Abs($a-$b) -gt 0.000001){throw 'Loss sum tolerance'}}
function Hash-Text([string]$s){[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s)))}
# 凍結bounded helperの定義だけを抽出。旧entrypointは実行しない。
Need (Get-FileHash -LiteralPath $helper).Hash 'A3DCE4B3A5A48897173E1BB34F0025F0A6BB933F6A59F798AAAF24A9559E0D85' 'Frozen helper SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Helper AST'}
$sourceSuffix=@'
;if($p -ceq $pricePath){Need $entry.sha256 '8AA6FA66C13BF11A9D0792E35D67A16D541AB28FE646C2B187A5B968437F66C1' 'Frozen prices SHA';$normalized=$content.Replace("`r`n","`n");$marker="#[cfg(test)]`nmod tests {";if(([regex]::Matches($normalized,[regex]::Escape($marker))).Count -ne 1){throw 'Prices cfg(test) suffix count'};$cut=$normalized.IndexOf($marker,[StringComparison]::Ordinal);$suffix=$normalized.Substring($cut);if($suffix -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $suffix -match '#\[path\s*=' -or $suffix -match '\bmod\s+\w+\s*;'){throw 'Prices test external dependency'};$report.source_parser_prices=@{sha256=$entry.sha256;cfg_test_suffix_count=1;excluded_suffix_sha256=(Hash-Text $suffix);excluded_suffix_UTF8_bytes=[Text.Encoding]::UTF8.GetByteCount($suffix);compiled_prices_bytes_unchanged=$true;graph_only_cfg_test_off=$true};$content=$normalized.Substring(0,$cut)}
'@
foreach($name in @('Identity','Safe-Path','Source','Save-Report','Child')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Helper definition count';$original=$defs[0].Extent.Text;$text=$original
 if($name -ceq 'Source'){$text=$text.Replace('$PSScriptRoot','$frozenSourceRoot');$needle='$content=[IO.File]::ReadAllText($p)';Need ([regex]::Matches($text,[regex]::Escape($needle))).Count 1 'Source read insertion count';$text=$text.Replace($needle,$needle+$sourceSuffix);$restored=$text.Replace($needle+$sourceSuffix,$needle).Replace('$frozenSourceRoot','$PSScriptRoot');Need $restored $original 'Source helper full allowlist';$report.source_helper_ledger=@{original_definition_sha256=(Hash-Text $original);adapted_definition_sha256=(Hash-Text $text);root_binding_replacements=1;prices_graph_insertion=1;extra_residual=0}}
 . ([scriptblock]::Create($text))
}
function Pin([string]$p){$p=Safe-Path $p;if(@($pins|Where-Object path -eq $p).Count){return};$pins.Add((Identity $p));$locks.Add([IO.File]::Open($p,'Open','Read','Read'))}
function Replace-One([string]$s,[string]$a,[string]$b){Need ([regex]::Matches($s,[regex]::Escape($a))).Count 1 'Fulltext allowlist count';$s.Replace($a,$b)}
function LF([string]$p){[IO.File]::ReadAllText($p).Replace("`r`n","`n").TrimEnd()+"`n"}
function Memory-Gate($n){Need $n.API_calls 1 'Memory API calls';Need $n.ABI_size 80 'Memory ABI size';Need $n.ABI_cb 80 'Memory cb';Need $n.ABI_checked $true 'Memory layout';if(!$n.measured){return $null};if($null -ne $n.last_OS_error -or $null -eq $n.peak_working_set_bytes -or $null -eq $n.peak_private_commit_bytes -or $n.peak_working_set_bytes -le 0 -or $n.peak_private_commit_bytes -le 0){throw 'Measured memory values/error'};$n.peak_working_set_bytes -le 167772160 -and $n.peak_private_commit_bytes -le 167772160}
try{
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output required'};$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Runner AST'}
 $baselineRunner=Join-Path $PSScriptRoot '../hard-cut-exp-scale-wire/run-native.ps1';Need (Identity $baselineRunner).sha256 'ED2E0EAF214E265C2A6A0F6003780B099EC68109C95DE485083198F07EBE415F' 'Frozen runner';
 $runnerText=[IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n");$oldRunnerText=[IO.File]::ReadAllText($baselineRunner).Replace("`r`n","`n");$newPrefix=$runnerText.Substring(0,$runnerText.IndexOf("try{`n",[StringComparison]::Ordinal));$priorPrefix=$oldRunnerText.Substring(0,$oldRunnerText.IndexOf("try{`n",[StringComparison]::Ordinal));$newPrefix=Replace-One $newPrefix 'khc-anchored-wire-20261004' 'khc-hard-cut-exp-scale-wire-20261004';$newPrefix=Replace-One $newPrefix 'anchored-wire-o3.exe' 'exp-scale-wire-o3.exe';Need $newPrefix $priorPrefix 'Runner prefix exact two restoration';$report.runner_prefix_ledger=@{allowed_replacements=2;extra_residual=0}
 Source (Join-Path $PSScriptRoot 'probe.rs');Need $sources.Count 24 'Source count';Need $graph.Count 24 'Source edges';$report.sources_before=@($sources);$report.imports=@($graph);$report.source_count=$sources.Count;$report.source_bytes=[long](($sources|Measure-Object bytes -Sum).Sum)
 foreach($s in $sources){$text=LF $s.path;if($text -match '#\[global_allocator\]' -or [IO.Path]::GetFileName($s.path) -in @('profile.rs','compare.rs','scaled_math.rs','scaled_pool.rs','entropy.rs')){throw 'Unexpected instrumented/combined graph'}};$report.custom_allocator_linked=$false;$report.profile_linked=$false
 $oldRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../hard-cut-model-lazy'));$oldCodec=Join-Path $oldRoot 'codec.rs';$oldE2E=Join-Path $PSScriptRoot '../causal-hard-cut-wire/e2e.rs';Need (Identity $oldCodec).sha256 'F082B13176D924EAF086F56A915A947DDD951751DDC634D78F58FFFC98D1E996' 'Frozen codec'
 $restored=(LF (Join-Path $PSScriptRoot 'codec.rs')).TrimEnd();
 $from=@'
stats_json(frame.len(),field(frame,32),field(frame,36),if field(frame,8)+1>=8{32}else{0},&stats)
'@
 $to=@'
stats_json(frame.len(),field(frame,32),field(frame,36),&stats)
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
stats_json(frame.len(),field(&frame,32),depth,if input.len()+1>=8{32}else{0},&stats)
'@
 $to=@'
stats_json(frame.len(),field(&frame,32),depth,&stats)
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
\"header_crc_covers_depth\":true,\"anchor_bytes\":{anchor_len},\"header_crc_covers_anchors\":true,
'@
 $to=@'
\"header_crc_covers_depth\":true,
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
fn stats_json(frame_len:usize,header_crc:usize,depth:usize,anchor_len:usize,stats:&Stats)->String{
'@
 $to=@'
fn stats_json(frame_len:usize,header_crc:usize,depth:usize,stats:&Stats)->String{
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let plain = inverse_bwt(&last, primary, &alphabet, anchors)?;
'@
 $to=@'
    let plain = inverse_bwt(&last, primary, &alphabet)?;
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let anchors=&frame[alphabet_end..header_len];
    if anchor_len!=0{crate::anchored::parse(anchors,length+1,primary)?;}
    let payload = &frame[header_len..];
'@
 $to=@'
    let payload = &frame[header_len..];
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let alphabet_end=header_len.checked_sub(anchor_len).ok_or("anchor metadata bounds")?;
    let alphabet = packed_alphabet::decode(&frame[40..alphabet_end])?;
'@
 $to=@'
    let alphabet = packed_alphabet::decode(&frame[40..header_len])?;
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    if !(73+anchor_len..=285+anchor_len).contains(&header_len) {
'@
 $to=@'
    if !(73..=285).contains(&header_len) {
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let anchor_len=if length+1>=8{32}else{0};
    // payload長とdeclared nからalphabet/anchor境界を求める。CRCは両方を覆う。
'@
 $to=@'
    // payload長からmetadata境界を求め、凍結decoderで正準幅と順位を検査する。
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    frame.extend_from_slice(&metadata);
    frame.extend_from_slice(&anchors);
    let header_crc
'@
 $to=@'
    frame.extend_from_slice(&metadata);
    let header_crc
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
        .checked_add(metadata.len())
        .and_then(|n|n.checked_add(anchors.len()))
        .ok_or("header overflow")?;
'@
 $to=@'
        .checked_add(metadata.len())
        .ok_or("header overflow")?;
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
let (last, primary, anchors) = bwt(input)?;
'@
 $to=@'
let (last, primary) = bwt(input)?;
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
fn inverse_bwt(last:&[u16],primary:usize,alphabet:&[u16],metadata:&[u8])->Result<Vec<u8>>{
    Ok(crate::anchored::inverse(last,primary,alphabet,metadata)?.plain)
}

'@
 $to=@'
fn inverse_bwt(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Vec<u8>> {
    let n = last.len();
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0_usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] += 1;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &c) in counts.iter().enumerate() {
        if (c != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0_usize; 257];
    let mut total = 0;
    for (i, &c) in counts.iter().enumerate() {
        starts[i] = total;
        total += c;
    }
    let mut occurrence = [0_usize; 257];
    let mut lf = filled(n, 0_usize)?;
    for (i, &s) in last.iter().enumerate() {
        let s = s as usize;
        lf[i] = starts[s] + occurrence[s];
        occurrence[s] += 1;
    }
    let mut visited = filled(n, false)?;
    let mut text = filled(n, 0_u16)?;
    let mut row = primary;
    for out in text.iter_mut().rev() {
        if row >= n || visited[row] {
            return Err("LF cycle inconsistent".into());
        }
        visited[row] = true;
        *out = last[row];
        row = lf[row];
    }
    if row != primary
        || !visited.iter().all(|&v| v)
        || text[n - 1] != 0
        || text[..n - 1].contains(&0)
    {
        return Err("LF cycle/sentinel inconsistent".into());
    }
    let mut result = filled(n - 1, 0_u8)?;
    for (out, &s) in result.iter_mut().zip(&text) {
        *out = (s - 1) as u8;
    }
    Ok(result)
}

'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
const MAX_FRAME: usize = MAX_PAYLOAD + 317;
'@
 $to=@'
const MAX_FRAME: usize = MAX_PAYLOAD + 285;
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
\"magic\":\"KHQCHA01\"
'@
 $to=@'
\"magic\":\"KHQCHC01\"
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
const MAGIC: &[u8; 8] = b"KHQCHA01";
'@
 $to=@'
const MAGIC: &[u8; 8] = b"KHQCHC01";
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
//! KHQCHA01 /
'@
 $to=@'
//! KHQCHC01 /
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
integer_cts,anchor_bwt as bwt,packed_alphabet
'@
 $to=@'
integer_cts,bwt,packed_alphabet
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
#[path="e2e.rs"]
'@
 $to=@'
#[path="../causal-hard-cut-wire/e2e.rs"]
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
#[path="../hard-cut-model-lazy/lazy_model.rs"]
'@
 $to=@'
#[path="lazy_model.rs"]
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 Need ($restored+"`n") (LF $oldCodec) 'codec fulltext restoration';$report.codec_ledger=@{allowed_replacements=20;extra_residual=0;normalized_line_endings_only=$true}
 $restored=(LF (Join-Path $PSScriptRoot 'e2e.rs')).TrimEnd();
 $from=@'
#[cfg(wire_audit)]
fn anchor_layout(f:&[u8])->Result<()>{
    let n=field(f,8)+1;let h=f.len().checked_sub(field(f,20)).ok_or("normal header layout")?;let a=if n>=8{32}else{0};
    if h<73+a||h>285+a{return Err("normal anchor header bounds".into());}
    let symbols=packed_alphabet::decode(&f[40..h-a])?;if symbols.len()!=field(f,16){return Err("normal alphabet layout".into());}
    if a!=0{crate::anchored::parse(&f[h-a..h],n,field(f,12))?;}
    if crc_parts(&[&f[..32],&f[36..h]])!=field(f,32)as u32{return Err("normal anchor header CRC".into());}Ok(())
}
#[cfg(wire_audit)]
fn named_anchor(name:&str,depth:usize)->Result<(Vec<u8>,&'static str)>{
    let mut f=encode(&vec![0u8;15],depth)?.0;let h=f.len()-field(&f,20);let at=h-32;
    let reason=match name{
        "old_hardcut_magic"=>{f=crate::control_scope::codec::run_profile(&[],depth)?.frame;"bad frame magic/header"},
        "anchor_crc_bitflip"=>{f[at]^=1;"header CRC mismatch"},
        "anchor_row_range"=>{let n=field(&f,8)+1;set(&mut f,at+4,n)?;repair_header(&mut f)?;"anchor row range"},
        "anchor0_mismatch"=>{let other=field(&f,at+4);set(&mut f,at,other)?;repair_header(&mut f)?;"anchor0 primary"},
        "anchor_duplicate"=>{let primary=field(&f,at);set(&mut f,at+4,primary)?;repair_header(&mut f)?;"duplicate anchor"},
        "anchor_endpoint"=>{let x=field(&f,at+4);let y=field(&f,at+8);set(&mut f,at+4,y)?;set(&mut f,at+8,x)?;repair_header(&mut f)?;"anchor segment endpoint"},
        "anchor_cycle72"=>{let mut last=vec![1u16;72];last[7]=0;let(p,a,_,_)=encode_payload(&last,depth)?;f=frame(72,7,&a,&p,depth)?;let h=f.len()-field(&f,20);let anchors=crate::anchored::serialize([7,0,1,2,3,4,5,6])?;f[h-32..h].copy_from_slice(&anchors);repair_header(&mut f)?;"LF early primary cycle"},
        "anchor_metadata_missing"=>{f.drain(at..h);repair_header(&mut f)?;"packed header length outside bounds"},
        "anchor_metadata_extra"=>{let plain:Vec<u8>=(0..=255).collect();f=encode(&plain,depth)?.0;let h=f.len()-field(&f,20);if h!=317{return Err("maximum anchor header fixture".into());}f.insert(h,0);repair_header(&mut f)?;"packed header length outside bounds"},
        "fallback_metadata_extra"=>{f=encode(&[],depth)?.0;let h=f.len()-field(&f,20);f.splice(h..h,[0u8;32]);repair_header(&mut f)?;"packed alphabet rank byte width not canonical"},
        _=>return Err("unknown named anchor fixture".into())
    };Ok((f,reason))
}
#[cfg(wire_audit)]
fn anchor_cases(depth:usize)->Result<(usize,usize,usize,usize,String)>{
    let mut boundaries=0;
    for length in [6usize,7]{let input:Vec<u8>=(0..length).map(|i|(i*37)as u8).collect();let(f,es)=encode(&input,depth)?;anchor_layout(&f)?;let(plain,ds)=decode(&f)?;let(again,_)=encode(&plain,depth)?;if plain!=input||f!=again||Proof::new(&es)!=Proof::new(&ds){return Err("n7/n8 normal boundary full plain/frame/Proof14".into());}boundaries+=1;}
    let names=["old_hardcut_magic","anchor_crc_bitflip","anchor_row_range","anchor0_mismatch","anchor_duplicate","anchor_endpoint","anchor_cycle72","anchor_metadata_missing","anchor_metadata_extra","fallback_metadata_extra"];
    let(mut rejected,mut recovered)=(0usize,0usize);let mut evidence=Vec::new();
    for name in names{let(f,reason)=named_anchor(name,depth)?;match decode(&f){Err(e)if e==reason=>{},Err(e)=>return Err(format!("anchor {name} expected {reason}, actual {e}")),Ok(_)=>return Err(format!("anchor {name} accepted"))}
        evidence.push(format!("{{\"name\":\"{name}\",\"reason\":\"{reason}\"}}"));rejected+=1;
        let input=[0u8,255,7,4,9,1,255];let(g,es)=encode(&input,depth)?;let(plain,ds)=decode(&g)?;if plain!=input||Proof::new(&es)!=Proof::new(&ds){return Err(format!("anchor recovery {name}"));}recovered+=1;
    }
    let(f,_)=encode(&[],depth)?;match crate::control_scope::codec::run_restore(&f){Err(e)if e=="bad frame magic/header"=>{},_=>return Err("new magic accepted by old decoder".into())}
    if boundaries!=2||rejected!=10||recovered!=10{return Err("anchor finite census".into());}
    Ok((boundaries,rejected,recovered,1,evidence.join(",")))
}
#[cfg(wire_audit)]
pub(crate) fn run()->Result<()>
'@
 $to=@'
#[cfg(wire_audit)]
pub(crate) fn run()->Result<()>
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let(anchor_boundary_cases,anchor_named_rejections,anchor_recovery_cases,reverse_magic_rejections,anchor_evidence)=anchor_cases(depth)?;
    Ok(format!("{{\"anchor_boundary_cases\":{anchor_boundary_cases},\"anchor_named_rejections\":{anchor_named_rejections},\"anchor_recovery_cases\":{anchor_recovery_cases},\"reverse_magic_rejections\":{reverse_magic_rejections},\"anchor_named\":[{anchor_evidence}],\"depth\":{depth},
'@
 $to=@'
    Ok(format!("{{\"depth\":{depth},
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
        anchor_layout(&f)?;
        let(again,_)=encode(&plain,depth)?;if f!=again
'@
 $to=@'
        let(again,_)=encode(&plain,depth)?;if f!=again
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
"lf_cycle"=>{let(p,a,_,_)=encode_payload(&[0,1],depth)?;f=frame(2,0,&a,&p,depth)?;"LF early primary cycle"},
'@
 $to=@'
"lf_cycle"=>{let(p,a,_,_)=encode_payload(&[0,1],depth)?;f=frame(2,0,&a,&p,depth)?;"LF cycle inconsistent"},
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 $from=@'
    let anchors=if n>=8{let mut rows=[primary;8];let mut next=0;for row in rows.iter_mut().skip(1){while next==primary{next+=1;}if next>=n{return Err("forge unique anchor rows".into());}*row=next;next+=1;}crate::anchored::serialize(rows)?}else{Vec::new()};
    f.extend_from_slice(&metadata);f.extend_from_slice(&anchors);f.extend_from_slice(payload);
    let h=40+metadata.len()+anchors.len();
'@
 $to=@'
    f.extend_from_slice(&metadata);f.extend_from_slice(payload);
    let h=40+metadata.len();
'@
 $restored=Replace-One $restored ($from.Replace("`r`n","`n")) ($to.Replace("`r`n","`n"))
 Need ($restored+"`n") (LF $oldE2E) 'e2e fulltext restoration';$report.e2e_ledger=@{allowed_replacements=5;extra_residual=0;normalized_line_endings_only=$true}
 Need (LF (Join-Path $PSScriptRoot 'anchor_scope.rs')) (LF (Join-Path $oldRoot 'float_scope.rs')) 'Scope exact old bytes normalized';$report.scope_ledger=@{allowed_replacements=0;extra_residual=0}
 $packedRunner=Join-Path $PSScriptRoot '../packed-inverse/run-native.ps1';$frozenPackedRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../packed-inverse'));$frozenCodec=Join-Path $PSScriptRoot '../lookup-float-profile/codec.rs';Need (Identity $packedRunner).sha256 '4872305FF29E8E3CF4C82FBFEEF83D1923EECA995A532AA67B66DF4115A7E692' 'Reference helper SHA';$pa=[Management.Automation.Language.Parser]::ParseFile($packedRunner,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Reference helper AST'};$def=@($pa.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Check-ReferenceExtraction'},$true));Need $def.Count 1 'Reference helper definition';. ([scriptblock]::Create($def[0].Extent.Text.Replace('$PSScriptRoot','$frozenPackedRoot')));$report.reference_extraction=Check-ReferenceExtraction
 $oldPath=Join-Path $project 'build/khc-hard-cut-model-lazy-20261004/report.json';Need (Identity $oldPath).sha256 '62B93E3FF942CEB13ECD6572DAD6CDBBE4DD45F88B72512E9348BBA4812BBEF3' 'Normal report';$old=Get-Content -Raw -LiteralPath $oldPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $old.status 'diagnostic-passed' 'Normal status';Need (@($old.sources_before).Count+@($old.identities_before).Count) 149 'Normal identity census';Need $old.executable_before.sha256 '93A68018BC95F2731F3B42BAB8E943F299FE091616D6E0CF6D10001E7EF20D51' 'Normal EXE'
 $saPath=Join-Path $project 'build/khc-anchored-sa-generation-20261004/report.json';Need (Identity $saPath).sha256 'A4C1128B0092FC89D20D419AF87059ADCF607F76E989262396E41B5F0AD8DAAE' 'SA report';$sa=Get-Content -Raw -LiteralPath $saPath|ConvertFrom-Json -Depth 64 -DateKind String;Need $sa.status 'diagnostic-passed' 'SA status';Need (@($sa.sources_before).Count+@($sa.identities_before).Count+1) 59 'SA identity census';Need $sa.executable_before.sha256 '27050B585AD48BE4CB53B4AB7B6504172091EE8A28FE9D973AD5D6B201D88657' 'SA EXE'
 foreach($prior in @($old,$sa)){foreach($kind in @('sources','identities')){$a=@($prior.($kind+'_before'));$b=@($prior.($kind+'_after'));Need $a.Count $b.Count 'Prior pairs';for($i=0;$i -lt $a.Count;$i++){if(!(Same $a[$i] $b[$i]) -or !(Same $a[$i] (Identity $a[$i].path))){throw 'Prior before-after-live'};Pin $a[$i].path}};foreach($generated in @('executable','assembly')){if($prior.($generated+'_before')){$a=$prior.($generated+'_before');$b=$prior.($generated+'_after');if(!(Same $a $b) -or !(Same $a (Identity $a.path))){throw 'Prior generated identity'};Pin $a.path}}}
 $plan=Join-Path $PSScriptRoot '../ANCHORED_WIRE_PLAN_20261004.md';Need (Identity $plan).sha256 '175E11A041EB85B415A02194F32AD695E8174663A647706D4CB8D68203F0AE81' 'PLAN'
 foreach($p in @($PSCommandPath,$helper,$baselineRunner,$packedRunner,$frozenCodec,(Join-Path $frozenPackedRoot 'reference-ledger.json'),$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,$oldPath,$saPath,$plan,(Join-Path $PSScriptRoot 'FAILURE_PLAN.md'),(Join-Path $oldRoot 'verify-readonly.ps1'),(Join-Path $PSScriptRoot '../anchored-sa-generation/verify-artifacts.ps1'))){Pin $p};$report.identities_before=@($pins)
 Need (Identity $fixedInputPath).sha256 '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' 'Input SHA';Need (Identity $fixedInputPath).bytes 2811006 'Input size';Need (Identity $compiler).sha256 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'Compiler SHA';Need (Identity (Get-Process -Id $PID).Path).sha256 '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' 'PowerShell SHA'
 if($report.source_bytes+(Identity $plan).bytes+(Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')).bytes -gt 307200){throw 'Source and plans budget'}
 $report.environment=@{child_cwd=$project;OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()};if(![OperatingSystem]::IsWindows() -or $report.environment.architecture -cne 'X64'){throw 'Windows x64'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8;$null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $v=Child $compiler @('--version') 60;Need $v.stdout 'rustc 1.98.1 (48a229cea 2026-09-01)' 'Compiler version'
 $report.compile_settings=@('--edition=2024','--cfg','wire_audit','-C','opt-level=3','-C','lto=thin','-C','codegen-units=1','-C','panic=unwind','-C','overflow-checks=yes','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE');$report.compile_calls=1;$null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60;$report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE size'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $selfResources=@();foreach($command in @('selfcontrol','selfcandidate')){$report.total_native_calls++;$c=Child $exe @($command) 120;if($c.stderr){throw 'Self stderr'};Need @($c.stdout -split "`n"|Where-Object {$_}).Count 1 'Self JSON record count';$s=$c.stdout|ConvertFrom-Json -Depth 64 -DateKind String;Need $s.status 'passed' 'Self status'
  if($command -ceq 'selfcontrol'){if(!(Same $s.E2E $old.selfcheck.E2E)){throw 'Whole old finite JSON'}}else{
   foreach($p in $old.selfcheck.E2E.PSObject.Properties){if($p.Name -ceq 'malformed'){continue};if(!(Same $p.Value $s.E2E.($p.Name))){throw ('Original finite field '+$p.Name)}}
   $a=@($old.selfcheck.E2E.malformed);$b=@($s.E2E.malformed);Need $a.Count 34 'Original malformed census';Need $b.Count 34 'New original malformed census'
   for($i=0;$i -lt 34;$i++){Need $b[$i].name $a[$i].name 'Original named order';$reason=$a[$i].reason;if($a[$i].name -ceq 'lf_cycle'){$reason='LF early primary cycle'};Need $b[$i].reason $reason 'Original strict reason';$bytes=$a[$i].frame_bytes;if($a[$i].name -in @('range_truncated','escape_noncanonical','escape_fourbytes','escape_remaining')){$bytes+=32};Need $b[$i].frame_bytes $bytes 'Forge layout delta'}
   foreach($pair in @(@('anchor_boundary_cases',2),@('anchor_named_rejections',10),@('anchor_recovery_cases',10),@('reverse_magic_rejections',1))){Need $s.E2E.($pair[0]) $pair[1] 'New finite census'}
   $names=@('old_hardcut_magic','anchor_crc_bitflip','anchor_row_range','anchor0_mismatch','anchor_duplicate','anchor_endpoint','anchor_cycle72','anchor_metadata_missing','anchor_metadata_extra','fallback_metadata_extra');$reasons=@('bad frame magic/header','header CRC mismatch','anchor row range','anchor0 primary','duplicate anchor','anchor segment endpoint','LF early primary cycle','packed header length outside bounds','packed header length outside bounds','packed alphabet rank byte width not canonical');$evidence=@($s.E2E.anchor_named);Need $evidence.Count 10 'Anchor named evidence';for($i=0;$i -lt 10;$i++){Need $evidence[$i].name $names[$i] 'Anchor named order';Need $evidence[$i].reason $reasons[$i] 'Anchor strict reason'}
  };Need $s.E2E.normal_cases 14 'Normal';Need $s.E2E.malformed_cases 34 'Malformed';Need $s.E2E.short_depth_header_checks 4 'Short depth';$report[$command]=$s;$selfResources+=@(Memory-Gate $s.memory);Save-Report
 }
 $report.total_native_calls++;$c=Child $exe @('pair',$fixedInputPath) 120;if($c.stderr){throw 'Pair stderr'};Need @($c.stdout -split "`n"|Where-Object {$_}).Count 1 'Pair JSON record count';$n=$c.stdout|ConvertFrom-Json -Depth 64 -DateKind String;$report.pair=$n;Save-Report
 foreach($p in @(@('status','passed'),@('operation','anchored-wire-pair'),@('input_reads',1),@('control_encode_calls',1),@('candidate_encode_calls',1),@('control_decode_calls',1),@('candidate_decode_calls',1),@('fixed_reencode_calls',0),@('validate_fixed_calls',4),@('matched_plain_bytes',2811006),@('frame_bytes',478888),@('control_frame_bytes',478856),@('candidate_frame_bytes',478888),@('old_header_bytes',285),@('header_bytes',317),@('payload_bytes',478571),@('anchor_metadata_bytes',32),@('disk_frames',0),@('disk_restores',0),@('raw_event_Vecs',0))){Need $n.($p[0]) $p[1] 'Pair exact census'}
 foreach($field in @('all_common_header_alphabet_payload_bytes_directly_compared','all_plain_bytes_compared','typed_Proof14_each_direction_Eq','cross_Proof14_Debug_equal','all_common_stats_equal','each_side_encode_decode_fullstats_equal','header_layout_and_CRC_checked','old_plain_dropped_before_candidate_restore','anchor_header_CRC_protected')){Need $n.$field $true 'Direct and lifecycle checks'}
 foreach($field in @('all_frame_bytes_directly_compared','all_stats_equal','cross_typed_Proof_Eq_claimed','speed_claimed','formal_speed_verified','native4_verified','adoption','custom_allocator_linked','stage_profile_linked')){Need $n.$field $false 'Difference/nonclaim'}
 foreach($field in @('control_encode_stats','control_decode_stats')){if(!(Same $n.$field $old.fixed.encode_stats)){throw 'Old full stats'}};if(!(Same $n.candidate_encode_stats $n.candidate_decode_stats)){throw 'New full stats'}
 $os=$n.control_encode_stats;$ns=$n.candidate_encode_stats;$oldNames=@($os.PSObject.Properties.Name);$newNames=@($ns.PSObject.Properties.Name);Need $newNames.Count ($oldNames.Count+2) 'Candidate stats schema'
 foreach($p in $os.PSObject.Properties){if($p.Name -in @('magic','frame_bytes','header_bytes','header_crc')){continue};if(!(Same $p.Value $ns.($p.Name))){throw ('Common stats '+$p.Name)}};foreach($name in $newNames){if($name -notin $oldNames -and $name -notin @('anchor_bytes','header_crc_covers_anchors')){throw 'Unexpected stats field'}}
 Need $ns.magic 'KHQCHA01' 'New stats magic';Need $ns.frame_bytes 478888 'New stats frame';Need $ns.header_bytes 317 'New stats header';Need $ns.anchor_bytes 32 'New stats anchor';Need $ns.header_crc_covers_anchors $true 'Stats CRC protection';if($null -eq $ns.header_crc -or $ns.header_crc -lt 0 -or $ns.header_crc -gt [uint32]::MaxValue){throw 'New CRC range'}
 Need $n.Proof14_debug $old.fixed.Proof14_debug 'All14 exact Debug';Need $n.frame_bytes ($n.header_bytes+$n.payload_bytes) 'Frame layout';$report.size_gate_passed=$n.frame_bytes -le 483599
 foreach($field in @('control_encode_ns','candidate_encode_ns','control_decode_ns','candidate_decode_ns')){if($n.$field -le 0){throw 'Positive diagnostic timer'}}
 Need $n.input_capacity 2811006 'Input capacity';if($n.control_frame_capacity -lt 478856 -or $n.control_frame_capacity -gt 1048861 -or $n.candidate_frame_capacity -lt 478888 -or $n.candidate_frame_capacity -gt 1048893){throw 'Frame capacities'};foreach($field in @('control_plain_capacity','candidate_plain_capacity')){if($n.$field -lt 2811006 -or $n.$field -gt 2811007){throw 'Plain capacity'}}
 Need $n.primary_node_size 40 'Node size';Need $n.model_working_RAM_estimate_bytes 21561264 'Model estimate';Need $n.encoder_phase_RAM_estimate_bytes 45723526 'Encoder estimate';Need $n.inverse_phase_RAM_estimate_bytes ($n.input_capacity+$n.control_frame_capacity+$n.candidate_frame_capacity+14*2811007+65536+4194304) 'Old inverse estimate';Need $n.candidate_inverse_phase_RAM_estimate_bytes ($n.input_capacity+$n.control_frame_capacity+$n.candidate_frame_capacity+7*2811007-1+65536+4194304) 'New inverse estimate';Need $n.BWT_phase_RAM_estimate_bytes 142651883 'BWT estimate';Need $n.fixed_phase_RAM_estimate_bytes ([math]::Max($n.encoder_phase_RAM_estimate_bytes,[math]::Max($n.inverse_phase_RAM_estimate_bytes,$n.actual_main_data_Vec_capacity_peak_bytes+4194304))) 'Phase arithmetic';if($n.model_working_RAM_estimate_bytes -gt 33554432 -or $n.fixed_phase_RAM_estimate_bytes -gt 67108864){throw 'Model/phase budget'}
 $resource=Memory-Gate $n.memory;$report.pair_resource_gate=$resource;$report.self_resource_gates=$selfResources;if($null -eq $resource -or @($selfResources|Where-Object {$null -eq $_}).Count){$report.status='diagnostic-resource-unmeasured'}elseif(!$resource -or @($selfResources|Where-Object {!$_}).Count){$report.status='diagnostic-resource-unmet'}else{$report.status='diagnostic-passed'}
 $report.single_internal_ms=@{control_encode=$n.control_encode_ns/1000000.0;candidate_encode=$n.candidate_encode_ns/1000000.0;control_decode=$n.control_decode_ns/1000000.0;candidate_decode=$n.candidate_decode_ns/1000000.0};$report.screening_only=$true;$report.interpretation='CRC-protected private 32-byte anchor wire; old/new full frames intentionally differ. All common header/alphabet/payload bytes and each full plain directly compared; each typedProof14 Eq and cross exact Debug14, full common stats. One control-first warm0 internal pair; no formal speed/fullCLI/quiet/warm9/holdout/native4/product/7-Zip achievement.'
 $report.executable_after=Identity $exe;if(!(Same $report.executable_before $report.executable_after)){throw 'EXE identity'};$report.owned_exe_processes=@(Get-Process|Where-Object {$_.Path -eq $exe}).Count;Need $report.owned_exe_processes 0 'Owned processes';$files=@(Get-ChildItem -LiteralPath $work -Force);if($files.Count -ne 2 -or @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('anchored-wire-o3.exe','report.json') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{$report.sources_after=@($sources|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Source changed'};$v});$report.identities_after=@($pins|ForEach-Object {$v=Identity $_.path;if(!(Same $_ $v)){throw 'Pin changed'};$v});$report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report;$finalGuard=& $guard -WorkDirectory $work -MaxRunMiB 8}finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));compile_calls=$report.compile_calls;native_calls=$report.total_native_calls;diagnostic_ms=$report.single_internal_ms;disk=$finalGuard}|ConvertTo-Json -Depth 6
