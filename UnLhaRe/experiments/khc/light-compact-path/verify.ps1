#requires -Version 7.2
# standalone数値/状態E2E。時間は正式性能値に使用しない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-light-compact-path-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$summaries=[Collections.Generic.List[object]]::new()
$failure=$null
$began=[DateTime]::UtcNow.ToString('o')
function Hold([string]$Path,[string]$Role,[string]$Expected='') {
    $full=[IO.Path]::GetFullPath($Path)
    $ancestor=$full
    while($ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse identity'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    $locks.Add([IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $sha=(Get-FileHash -LiteralPath $full).Hash
    if($Expected -and $sha -cne $Expected){throw "pin mismatch: $Role"}
    $ids.Add([pscustomobject]@{path=$full;role=$Role;bytes=(Get-Item -LiteralPath $full).Length;before_sha256=$sha;after_sha256=$null})
}
function Child([string]$Program,[string[]]$Argv) {
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try {
        $started=$process.Start();if(!$started){throw 'child start failure'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(120000)){throw 'child timeout120s'}
        $call=[pscustomobject]@{program=$Program;argv=$Argv;exit=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($call)
        if($call.exit -ne 0 -or $call.stderr -or $call.stdout.Length -gt 65536){throw 'child failed or unexpected output'}
        return $call.stdout
    } finally {
        if($started -and !$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(10000)}
        $process.Dispose()
    }
}
function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 4
if(Test-Path -LiteralPath $work){throw 'Fresh output required; no automatic retry/overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Hold (Join-Path $PSScriptRoot '../LIGHT_COMPACT_PATH_CONTRACT_20261002.md') 'preimplementation-contract' 'A8E3740D6EF827B1CA68D73DA1863F1439F9940B8B92DB265E3DD03FE1E3899A'
    Hold (Join-Path $PSScriptRoot '../adaptive-suffix-kt/cts_model.rs') 'old-frozen-light' 'F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32'
    Hold (Join-Path $PSScriptRoot '../causal-bayes-q32-kt-reciprocal/exact_kt.rs') 'unchanged-kt' '4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
    Hold (Join-Path $PSScriptRoot '../native32-quotient/exact_div.rs') 'unchanged-kt-quotient' '338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'capacity-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    foreach($name in @('old_audit.rs','light.rs','audit.rs','correspondence.json','verify.ps1')){Hold (Join-Path $PSScriptRoot $name) 'new-source'}
    $correspondence=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json
    foreach($source in $correspondence) {
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes) {
            if($change.PSObject.Properties.Name -contains 'append'){$expected+=$change.append}
            else {if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source replacement count'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}
        }
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n") -cne $expected){throw 'complete source correspondence differs'}
    }
    $checks.Add('full-old-audit-and-new-source-correspondence')
    $null=Child $compiler @('--version','--verbose')
    foreach($opt in @(2,3)) {
        foreach($checked in @($false,$true)) {
            $variant="opt$opt-checked$checked"
            $exe=Join-Path $work "audit-$variant.exe"
            $argv=@((Join-Path $PSScriptRoot 'audit.rs'),'--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'-C','link-arg=/DEBUG:NONE','--cfg','khc_light_path_audit','-o',$exe)
            if($checked){$argv+=@('-C','overflow-checks=yes')}
            $null=Child $compiler $argv
            Hold $exe "$variant-audit"
            $stdout=Child $exe @()
            $summary=$stdout|ConvertFrom-Json
            if($summary.status -cne 'light_compact_path_state_verified_not_codec_or_timing' -or $summary.mapping_records -ne 1114112 -or $summary.invalid_depth_cases -ne 2 -or $summary.state_events -ne 131072 -or $summary.values_per_event -ne 72){throw 'mapping/state coverage incomplete'}
            if($summary.invalid_class_cases -ne 2 -or $summary.stale_cases -ne 1 -or $summary.class_mismatch_cases -ne 1 -or $summary.injected_cap_cases -ne 1 -or $summary.rollback_checks -ne 3 -or $summary.continuation_events -ne 2){throw 'refusal/continuation coverage incomplete'}
            if($summary.old_node_bytes -ne 8 -or $summary.new_node_bytes -ne 8 -or $summary.new_prediction_bytes -ge $summary.old_prediction_bytes){throw 'layout regression'}
            if($summary.classes.Count -ne 7 -or @($summary.classes|Where-Object {$_ -le 0}).Count -or ($summary.classes|Measure-Object -Sum).Sum -ne 131072 -or $summary.selected_depths.Count -ne 17 -or $summary.selected_depths[0] -le 0 -or $summary.selected_depths[16] -le 0 -or ($summary.selected_depths|Measure-Object -Sum).Sum -ne 131072){throw 'class/expert coverage incomplete'}
            $summaries.Add([pscustomobject]@{variant=$variant;summary=$summary;stdout=$stdout})
            $checks.Add("$variant-exhaustive-mapping-streamed-state-and-refusal-e2e")
        }
    }
    foreach($item in $summaries){if($item.stdout -cne $summaries[0].stdout){throw 'four-condition complete summary differs'}}
    $checks.Add('four-condition-full-summary-identical')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'held identity changed'}}
    $checks.Add('all-held-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 4
    $unwanted=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Extension -ceq '.pdb' -or $_.Name.EndsWith('.tmp') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($unwanted.Count -and !$failure){$failure='owned temporary/PDB/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'light_compact_path_state_verified_not_codec_or_timing'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;runtime_path=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();script_path=$PSCommandPath;script_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;identities=$ids;invocations=$calls;checks=$checks;summaries=$summaries;owned_tmp_pdb_reparse=$unwanted.Count;timing_used=$false;full_codec_verified=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 9)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 4
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;work=$work;bytes_before_report=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}
