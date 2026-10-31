[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-hard-cut-exp-scale-20261004'
function Need([bool]$v,[string]$why){if(!$v){throw $why}}
function Json($v){ConvertTo-Json -InputObject $v -Depth 32 -Compress}
function Identity($v){$p=[IO.Path]::GetFullPath($v.path);$a=$p;while($a){Need (!((Get-Item -LiteralPath $a -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Reparse';$a=[IO.Path]::GetDirectoryName($a)};$i=Get-Item -LiteralPath $p;Need (!$i.PSIsContainer -and $i.Length -eq $v.bytes -and $i.LastWriteTimeUtc.ToString('o') -ceq $v.mtime_utc -and (Get-FileHash $p).Hash -ceq $v.sha256) 'Live identity'}
$rp=Join-Path $work 'recovery.json';Need ((Get-FileHash $rp).Hash -ceq '94EF514E399F3FDF5F918884EDE6E53A820084306707B823B84103A6A2DBEA68') 'Recovery SHA'
$r=Get-Content -Raw -LiteralPath $rp|ConvertFrom-Json -Depth 32 -DateKind String
Need ($r.status -ceq 'finite-passed' -and $r.compile_calls -eq 0 -and $r.total_native_calls -eq 1 -and $r.children.Count -eq 1 -and $r.children[0].exit_code -eq 0 -and !$r.children[0].failure -and !$r.children[0].stderr) 'Recovered execution census'
$pairs=0;foreach($kind in @('sources','identities')){$a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need ($a.Count -eq $b.Count) 'Pair count';for($i=0;$i -lt $a.Count;$i++){Need ((Json $a[$i]) -ceq (Json $b[$i])) 'Before-after';Identity $a[$i];$pairs++}}
Need ($pairs -eq 11 -and $r.sources_before.Count -eq 4) 'All identities'
foreach($v in @($r.original_report,$r.cleanup_ledger,$r.executable_before,$r.executable_after,$r.assembly_before,$r.assembly_after)){Identity $v}
Need ((Json $r.executable_before) -ceq (Json $r.executable_after) -and (Json $r.assembly_before) -ceq (Json $r.assembly_after)) 'Generated identities unchanged'
Need ((Json ($r.children[0].stdout|ConvertFrom-Json -Depth 32 -DateKind String)) -ceq (Json $r.finite)) 'Raw projection'
$n=$r.finite;Need ($n.total_cases -eq 458878 -and $n.grid_cases -eq 393312 -and $n.random_cases -eq 65536 -and $n.boundary_cases -eq 30 -and $n.exact_result_comparisons -eq 458878 -and $n.ok_cases -eq 458859 -and $n.error_cases -eq 19 -and $n.mismatches -eq 0 -and $n.results_digest -ceq '000c3ed9dea119fa' -and $n.LCG_final_state -eq 1348762101 -and $n.Ok_bits_directly_compared -and $n.Err_strings_and_class_directly_compared) 'Exact finite outcomes'
Need ($n.reference_constructor_calls -eq 1 -and $n.candidate_constructor_calls -eq 1 -and $n.cases_Vec -eq 0 -and $n.streamed_cases -and !$n.speed_claimed -and !$n.adoption -and !$n.normal_codec_verified -and !$n.native4_verified -and !$n.all_f64_inputs_proven) 'Nonclaims'
$oldText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../lookup-float-cts/float_math.rs')).Replace("`r`n","`n").TrimEnd()
$newText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'scaled_math.rs')).Replace("`r`n","`n").TrimEnd();$site='let result=interpolation*f64::from_bits((1023u64-u64::from(exponent))<<52);'
Need ([regex]::Matches($newText,[regex]::Escape($site)).Count -eq 1 -and $newText.Replace($site,'let result=interpolation/(1u64<<exponent) as f64;') -ceq $oldText) 'One-site fulltext restoration'
$asm=Get-Content -Raw -LiteralPath $r.assembly_before.path;$counts=@()
foreach($name in @('reference_exp','candidate_exp')){$m=[regex]::Matches($asm,'(?ms)^'+$name+':\r?\n(.*?^\s*\.seh_endproc)');Need ($m.Count -eq 1) 'Wrapper body';$body=$m[0].Groups[1].Value;$div=[regex]::Matches($body,'\bv?divsd\b').Count;$mul=[regex]::Matches($body,'\bv?mulsd\b').Count;Need ($div -eq $r.assembly_metrics.$name.scalar_divides -and $mul -eq $r.assembly_metrics.$name.scalar_multiplies) 'Asm projection';$counts+=@($div)}
Need ($counts[0] -eq 3 -and $counts[1] -eq 2 -and $r.generated_instruction_reduction_verified) 'Finite wrapper division reduction'
$ledger=Get-Content -Raw -LiteralPath $r.cleanup_ledger.path|ConvertFrom-Json -Depth 32 -DateKind String
Need ($ledger.state -ceq 'complete' -and $ledger.items.Count -eq 13) 'Cleanup ledger';foreach($item in $ledger.items){Need ($item.sourceAbsent -and $item.recycleAbsent -and $item.metadataAbsent -and !(Test-Path -LiteralPath $item.original.Path)) 'Cleanup absence'}
Need (@(Get-ChildItem -LiteralPath $project -Filter 'probe*.s' -File).Count -eq 0 -and @(Get-Process|Where-Object {$_.Path -eq $r.executable_before.path}).Count -eq 0) 'No stray asm or owned process'
$files=@(Get-ChildItem -LiteralPath $work -Force);$bytes=($files|Measure-Object Length -Sum).Sum
Need ($files.Count -eq 5 -and @($files|Where-Object {$_.PSIsContainer -or $_.Name -notin @('report.json','recovery.json','cleanup-unused-asm.json','exp-scale-o3.exe','exp-scale-o3.s')}).Count -eq 0 -and $bytes -eq 353401 -and $bytes -le 8MB) 'Retained output'
[pscustomobject]@{status='readonly-verified';identity_pairs=$pairs;raw_projections=1;finite_cases=$n.total_cases;finite_wrapper_divides=$counts;retained_bytes=$bytes;unused_asm_deleted=13;compile_calls=0;native_calls=0}|ConvertTo-Json
