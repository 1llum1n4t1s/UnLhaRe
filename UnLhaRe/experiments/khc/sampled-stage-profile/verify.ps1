#requires -Version 7.2
# 標本内訳の診断。正式速度評価・同候補の再試行ではない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-sampled-stage-profile-20261002'
$baseWork=Join-Path $root 'build/khc-light-compact-codec-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$seen=@{}
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$profiles=[Collections.Generic.List[object]]::new()
$failure=$null
$validatedBaseRecords=0
$began=[DateTime]::UtcNow.ToString('o')
function Hold([string]$Path,[string]$Role,[string]$Expected='') {
    $full=[IO.Path]::GetFullPath($Path)
    if(!$seen.ContainsKey($full)){
        $ancestor=$full
        while($ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse identity'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
        $locks.Add([IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        $entry=[pscustomobject]@{path=$full;role=$Role;bytes=(Get-Item -LiteralPath $full).Length;before_sha256=(Get-FileHash -LiteralPath $full).Hash;after_sha256=$null}
        $ids.Add($entry);$seen[$full]=$entry
    }
    $entry=$seen[$full]
    if($Expected -and $entry.before_sha256 -cne $Expected){throw "pin mismatch: $Role"}
    return $entry
}
function Child([string]$Program,[string[]]$Argv) {
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Argv){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try {
        $started=$process.Start();if(!$started){throw 'start failed'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(120000)){throw '120s timeout'}
        $call=[pscustomobject]@{program=$Program;argv=$Argv;exit=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($call)
        if($call.exit -ne 0 -or $call.stderr -or $call.stdout.Length -gt 65536){throw 'unexpected child result'}
        return $call.stdout
    } finally {
        if($started -and !$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(10000)}
        $process.Dispose()
    }
}
function Same([string]$First,[string]$Second) {
    if((Get-Item -LiteralPath $First).Length -ne (Get-Item -LiteralPath $Second).Length){throw 'length mismatch'}
    $a=[IO.File]::OpenRead($First);$b=[IO.File]::OpenRead($Second)
    try {
        $ab=[byte[]]::new(65536);$bb=[byte[]]::new(65536)
        while(($count=$a.Read($ab,0,$ab.Length)) -gt 0) {
            if($b.Read($bb,0,$count) -ne $count -or ![ProfileByteCompare]::Equal($ab,$bb,$count)){throw 'full bytes differ'}
        }
    } finally {$a.Dispose();$b.Dispose()}
}
function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
Add-Type -TypeDefinition @'
using System;
public static class ProfileByteCompare {
    public static bool Equal(byte[] a,byte[] b,int count) { return a.AsSpan(0,count).SequenceEqual(b.AsSpan(0,count)); }
}
'@
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
if(Test-Path -LiteralPath $work){throw 'Fresh diagnostic output required; no retry or overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $null=Hold (Join-Path $PSScriptRoot '../SAMPLED_STAGE_PROFILE_CONTRACT_20261002.md') 'preimplementation-contract' 'B9FEA87D801C2C3F05522862D84C7394347CDA38B72DB51960DF22DE76A8A25E'
    $baseProofPath=Join-Path $baseWork 'report.json'
    $null=Hold $baseProofPath 'base-full-proof' '9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BD'
    $base=Get-Content -LiteralPath $baseProofPath -Raw|ConvertFrom-Json
    if($base.status -cne 'correctness_and_size_passed_not_timed' -or $base.failure -or $base.timing_used -or $base.checks.Count -ne 51 -or $base.invocations.Count -ne 86 -or $base.identities.Count -ne 841 -or $base.frame_bytes -ne 483496 -or $base.owned_tmp_or_reparse -ne 0 -or $base.owned_pdb -ne 0){throw 'base correctness proof matrix'}
    foreach($id in $base.identities){
        if($id.before_sha256 -cne $id.after_sha256){throw 'base before/after identity'}
        $entry=Hold $id.path 'base-current-identity' $id.after_sha256
        if($entry.bytes -ne $id.bytes){throw 'base identity length'}
        $validatedBaseRecords++
    }
    $checks.Add('base-full-proof-and-all-current-identity-records')
    foreach($name in @('codec.rs','scheduler.rs','light.rs','heavy.rs','timing.rs','correspondence.json','verify.ps1')){$null=Hold (Join-Path $PSScriptRoot $name) 'profile-source'}
    $null=Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'disk-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    foreach($source in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json)){
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes){if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source replacement occurrence'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n") -cne $expected){throw 'full profile source correspondence'}
    }
    $checks.Add('four-source-full-correspondence')
    $null=Child $compiler @('--version','--verbose')
    foreach($variant in @('off','on')){
        $exe=Join-Path $work "codec-profile-$variant.exe"
        $argv=@((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C','opt-level=3','-C','panic=abort','-C','link-arg=/DEBUG:NONE','-o',$exe)
        if($variant -ceq 'on'){$argv+=@('--cfg','khc_stage_timing')}
        $null=Child $compiler $argv
        $null=Hold $exe "$variant-profile-codec"
    }
    $checks.Add('cfg-off-on-builds-no-pdb')
    $fixedInput=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    $null=Hold $fixedInput 'fixed-input' '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    if((Get-Item -LiteralPath $fixedInput).Length -ne 2811006){throw 'fixed input length'}
    $golden=Join-Path $baseWork 'fixed-native.frame'
    $null=Hold $golden 'base-frame' 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'
    $outputFrame=Join-Path $work 'profile.frame'
    $restore=Join-Path $work 'profile.restore'
    $baseNative=Join-Path $baseWork 'codec-native.exe'
    $null=Hold $baseNative 'base-native-not-reexecuted' '8BA849D4C3122D8F49DF8667D08A0DB497B575F2099EF37B73CD6A911FE04C3E'
    $encRef=@($base.invocations|Where-Object {$_.program -ceq $baseNative -and $_.argv.Count -eq 3 -and $_.argv[0] -ceq 'encode' -and $_.argv[2] -ceq $golden})
    $decRef=@($base.invocations|Where-Object {$_.program -ceq $baseNative -and $_.argv.Count -eq 3 -and $_.argv[0] -ceq 'decode' -and $_.argv[2] -ceq (Join-Path $baseWork 'fixed-native.restore')})
    if($encRef.Count -ne 1 -or $decRef.Count -ne 1){throw 'unique base fixed calls'}
    $primary=$encRef[0].stdout|ConvertFrom-Json
    $events=[long](($primary.scheduling.events|Measure-Object -Sum).Sum)
    $processed=[long](($primary.scheduling.processed|Measure-Object -Sum).Sum)
    if($events -ne 7622618 -or $processed -ne 3223156){throw 'frozen event counts'}
    $labels=@('bwt','inverse_bwt','entropy_encode','entropy_decode','light_init','heavy_init','light_predict','light_update','heavy_predict','heavy_update')
    foreach($operation in @('encode','decode')){
        $operationArgv=if($operation -ceq 'encode'){@('encode',$fixedInput,$outputFrame)}else{@('decode',$outputFrame,$restore)}
        $stdout=Child (Join-Path $work 'codec-profile-on.exe') $operationArgv
        $split=$stdout.IndexOf("`n")
        if($split -lt 0){throw 'profile summary absent'}
        $expectedStdout=if($operation -ceq 'encode'){$encRef[0].stdout}else{$decRef[0].stdout}
        if($stdout.Substring(0,$split+1) -cne $expectedStdout){throw 'profile primary summary changed'}
        $metric=$stdout.Substring($split+1).Trim()|ConvertFrom-Json
        if($metric.kind -cne 'sampled_stage_diagnostic_not_formal_performance' -or $metric.sampling_mask -ne 1023 -or $metric.salt_u64_hex -cne '9e3779b97f4a7c15' -or !$metric.nested_spans_overlap -or ($metric.spans.name -join ',') -cne ($labels -join ',')){throw 'sampling header/span order'}
        $estimates=[Collections.Generic.List[object]]::new()
        foreach($s in $metric.spans){
            $expectedCalls=switch($s.name){
                'bwt' {if($operation -ceq 'encode'){1}else{0}}
                'inverse_bwt' {if($operation -ceq 'decode'){1}else{0}}
                'entropy_encode' {if($operation -ceq 'encode'){1}else{0}}
                'entropy_decode' {if($operation -ceq 'decode'){1}else{0}}
                'light_init' {1}
                'heavy_init' {1}
                'light_predict' {$events}
                'light_update' {$events}
                'heavy_predict' {$processed}
                'heavy_update' {$processed}
            }
            if($s.calls -ne $expectedCalls -or $s.samples -gt $s.calls -or $s.log2_ns_buckets.Count -ne 65 -or ($s.log2_ns_buckets|Measure-Object -Sum).Sum -ne $s.samples){throw 'span call/sample/histogram coverage'}
            if($s.calls -eq 0){if($s.samples -ne 0 -or $s.sample_sum_ns -ne 0 -or $s.sample_min_ns -ne 0 -or $s.sample_max_ns -ne 0){throw 'inactive span nonzero'}}
            elseif($s.calls -eq 1){if($s.samples -ne 1 -or $s.sample_sum_ns -ne $s.sample_min_ns -or $s.sample_sum_ns -ne $s.sample_max_ns){throw 'coarse span accounting'}}
            elseif($s.samples -lt 1000){throw 'model sample coverage insufficient'}
            if($s.samples -gt 0){
                if($s.sample_min_ns -gt $s.sample_max_ns -or [decimal]$s.sample_sum_ns -lt [decimal]$s.sample_min_ns*[decimal]$s.samples -or [decimal]$s.sample_sum_ns -gt [decimal]$s.sample_max_ns*[decimal]$s.samples){throw 'sample duration bounds'}
                $target=[long][Math]::Ceiling($s.samples/2.0);$count=0L;$bucket=-1
                for($i=0;$i -lt 65;$i++){$count+=$s.log2_ns_buckets[$i];if($count -ge $target){$bucket=$i;break}}
                $low=if($bucket -eq 0){[bigint]0}else{[bigint]::Pow(2,$bucket-1)}
                $high=if($bucket -eq 0){[bigint]0}else{[bigint]::Pow(2,$bucket)-1}
                $mean=[decimal]$s.sample_sum_ns/[decimal]$s.samples
                $estimates.Add([pscustomobject]@{span=$s.name;sample_mean_ns=$mean;sample_p50_bucket_low_ns=$low.ToString();sample_p50_bucket_high_ns=$high.ToString();estimated_all_calls_ms_from_sample_mean=[decimal]$s.calls*$mean/1000000;not_observed_total_or_competitive_time=$true})
            }
        }
        $profiles.Add([pscustomobject]@{operation=$operation;metric=$metric;estimates_not_formal_performance=$estimates})
        $checks.Add("$operation-primary-summary-sampling-and-frozen-call-counts")
    }
    foreach($name in $labels){
        $e=@($profiles[0].metric.spans|Where-Object name -ceq $name)[0]
        $d=@($profiles[1].metric.spans|Where-Object name -ceq $name)[0]
        if($name -notin @('bwt','inverse_bwt','entropy_encode','entropy_decode') -and ($e.calls -ne $d.calls -or $e.samples -ne $d.samples)){throw 'encode/decode model count/sampling differs'}
    }
    Same $outputFrame $golden;Same $restore $fixedInput
    $null=Hold $outputFrame 'profile-frame' 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'
    $null=Hold $restore 'profile-restore' '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    $checks.Add('exact-profile-frame-restore-and-model-sample-counts')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'held identity changed'}}
    $checks.Add('all-current-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    $unwanted=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Name.EndsWith('.tmp') -or $_.Extension -ceq '.pdb' -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($unwanted.Count -and !$failure){$failure='owned tmp/PDB/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'sampled_stage_profile_completed_not_formal_performance'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;runtime_path=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();script_path=$PSCommandPath;script_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;validated_base_identity_records=$validatedBaseRecords;identities=$ids;checks=$checks;invocations=$calls;profiles=$profiles;owned_tmp_pdb_reparse=$unwanted.Count;diagnostic_timing_used=$true;ordinary_performance_retried=$false;observer_gate_changed=$false;off_variant_executed=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;validated_base_records=$validatedBaseRecords;work=$work;bytes_before_report=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}
