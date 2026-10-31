#requires -Version 7.2
# 同一componentの件数診断。正式速度評価・同候補の再試行ではない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-equal-component-opportunity-20261002'
$baseWork=Join-Path $root 'build/khc-reciprocal-codec-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$seen=@{}
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$profiles=[Collections.Generic.List[object]]::new()
$failure=$null
$restoreEvidence=$null
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
    $null=Hold (Join-Path $PSScriptRoot '../EQUAL_COMPONENT_OPPORTUNITY_CONTRACT_20261002.md') 'preimplementation-contract' '4226FE6A55B0B513C021F1978D2A0E6FCF87CFA5892CE5E6C2C0326B9E50CBBB'
    $baseProofPath=Join-Path $baseWork 'report.json'
    $null=Hold $baseProofPath 'base-full-proof' '22C7D3364743D2FD962A330BCA5EC9BBE2DF4EC6E1603F8BB4ED655FE0D645BE'
    $base=Get-Content -LiteralPath $baseProofPath -Raw|ConvertFrom-Json
    if($base.status -cne 'reciprocal_codec_correctness_and_size_passed_not_timed' -or $base.failure -or $base.timing_used -or $base.checks.Count -ne 51 -or $base.invocations.Count -ne 86 -or $base.identities.Count -ne 466 -or $base.owned_tmp_pdb_reparse -ne 0){throw 'base correctness proof matrix'}
    foreach($id in $base.identities){
        if($id.before_sha256 -cne $id.after_sha256){throw 'base before/after identity'}
        $entry=Hold $id.path 'base-current-identity' $id.after_sha256
        if($entry.bytes -ne $id.bytes){throw 'base identity length'}
        $validatedBaseRecords++
    }
    $checks.Add('base-full-proof-and-all-current-identity-records')
    foreach($name in @('codec.rs','scheduler.rs','heavy.rs','correspondence.json','verify.ps1','verifier-correspondence.json')){$null=Hold (Join-Path $PSScriptRoot $name) 'profile-source'}
    $null=Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'disk-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    foreach($source in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json)){
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes){if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source replacement occurrence'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n") -cne $expected){throw 'full profile source correspondence'}
    }
    $oldVerifierPath=Join-Path $PSScriptRoot '../sampled-stage-profile/verify.ps1'
    $null=Hold $oldVerifierPath 'frozen-verifier' 'EE06A07CA0E7AC21512C2DE6B9AA923A3C761F05BE8227723C86F214C682BCA6'
    $expectedVerifier=[IO.File]::ReadAllText($oldVerifierPath).Replace("`r`n","`n")
    foreach($change in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verifier-correspondence.json') -Raw|ConvertFrom-Json)){
        if(([regex]::Matches($expectedVerifier,[regex]::Escape($change.old))).Count -ne $change.count){throw 'verifier replacement occurrence'}
        $expectedVerifier=$expectedVerifier.Replace([string]$change.old,[string]$change.new)
    }
    if([IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n") -cne $expectedVerifier){throw 'full verifier correspondence'}
    $checks.Add('three-source-and-verifier-full-correspondence')
    $null=Child $compiler @('--version','--verbose')
    foreach($variant in @('off','on')){
        $exe=Join-Path $work "codec-profile-$variant.exe"
        $argv=@((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C','opt-level=3','-C','panic=abort','-C','link-arg=/DEBUG:NONE','-o',$exe)
        if($variant -ceq 'on'){$argv+=@('--cfg','khc_equal_component_counts')}
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
    $null=Hold $baseNative 'base-native-not-reexecuted' '7DCB3AC8CD16139D48483FEE8FB2078902EAB7DF3AE0912F33A843F40714944B'
    $encRef=@($base.invocations|Where-Object {$_.program -ceq $baseNative -and $_.argv.Count -eq 3 -and $_.argv[0] -ceq 'encode' -and $_.argv[2] -ceq $golden})
    $decRef=@($base.invocations|Where-Object {$_.program -ceq $baseNative -and $_.argv.Count -eq 3 -and $_.argv[0] -ceq 'decode' -and $_.argv[1] -ceq $golden})
    if($encRef.Count -ne 1 -or $decRef.Count -ne 1){throw 'unique base fixed calls'}
    $primary=$encRef[0].stdout|ConvertFrom-Json
    $events=[long](($primary.scheduling.events|Measure-Object -Sum).Sum)
    $processed=[long](($primary.scheduling.processed|Measure-Object -Sum).Sum)
    if($events -ne 7622618 -or $processed -ne 3223156){throw 'frozen event counts'}
    foreach($operation in @('encode','decode')){
        $operationArgv=if($operation -ceq 'encode'){@('encode',$fixedInput,$outputFrame)}else{@('decode',$outputFrame,$restore)}
        $stdout=Child (Join-Path $work 'codec-profile-on.exe') $operationArgv
        $split=$stdout.IndexOf("`n")
        if($split -lt 0){throw 'counter summary absent'}
        $expectedStdout=if($operation -ceq 'encode'){$encRef[0].stdout}else{$decRef[0].stdout}
        if($stdout.Substring(0,$split+1) -cne $expectedStdout){throw 'counter primary summary changed'}
        $metric=$stdout.Substring($split+1).Trim()|ConvertFrom-Json
        if($metric.kind -cne 'equal_component_opportunity_not_performance' -or ($metric.upper_levels -join ',') -cne '3,7,11,15' -or $metric.groups -ne $processed*4 -or $metric.equal_component_ceiling_mismatch -ne 0 -or $metric.masks_by_upper.Count -ne 4){throw 'counter header/group domain'}
        $groups=0L;$equal=0L;$complete=0L
        for($upperIndex=0;$upperIndex -lt 4;$upperIndex++){
            $row=@($metric.masks_by_upper[$upperIndex])
            if($row.Count -ne 16 -or ($row|Measure-Object -Sum).Sum -ne $processed -or @($row|Where-Object {$_ -lt 0}).Count){throw 'histogram upper coverage'}
            for($mask=0;$mask -lt 16;$mask++){
                $groups+=[long]$row[$mask]
                $equal+=[long]$row[$mask]*[long][Numerics.BitOperations]::PopCount([uint32]$mask)
            }
            $complete+=[long]$row[15]
        }
        if($groups -ne $metric.groups -or $equal -ne $metric.equal_lanes -or $complete -ne $metric.all_equal_groups -or $equal -gt $groups*4){throw 'independent mask reduction differs'}
        $profiles.Add([pscustomobject]@{operation=$operation;metric=$metric;independent_groups=$groups;independent_equal_lanes=$equal;independent_all_equal_groups=$complete})
        $checks.Add("$operation-primary-summary-and-counter-histogram")
    }
    if(($profiles[0].metric|ConvertTo-Json -Compress -Depth 6) -cne ($profiles[1].metric|ConvertTo-Json -Compress -Depth 6)){throw 'counter encode/decode histogram differs'}
    Same $outputFrame $golden;Same $restore $fixedInput
    $null=Hold $outputFrame 'profile-frame' 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'
    $restoreEvidence=[pscustomobject]@{transient_path=$restore;bytes=(Get-Item -LiteralPath $restore).Length;sha256=(Get-FileHash -LiteralPath $restore).Hash;reference_sha256='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76';full_bytes_compared=$true;deleted=$false}
    if($restoreEvidence.bytes -ne 2811006 -or $restoreEvidence.sha256 -cne $restoreEvidence.reference_sha256){throw 'counter restore identity'}
    $fullRestore=[IO.Path]::GetFullPath($restore)
    if($fullRestore -cne (Join-Path $work 'profile.restore') -or $seen.ContainsKey($fullRestore)){throw 'not explicitly owned transient restore'}
    $ancestor=$fullRestore
    while($ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'restore reparse'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    $exclusive=[IO.File]::Open($fullRestore,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{if($exclusive.Length -ne $restoreEvidence.bytes){throw 'restore changed'}}finally{$exclusive.Dispose()}
    if((Get-FileHash -LiteralPath $fullRestore).Hash -cne $restoreEvidence.sha256){throw 'restore changed before removal'}
    & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $fullRestore -Root $work | Out-Null
    if(Test-Path -LiteralPath $fullRestore){throw 'restore cleanup failed'}
    $restoreEvidence.deleted=$true
    $checks.Add('exact-frame-restore-and-independent-counts-transient-restore-removed')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'held identity changed'}}
    $checks.Add('all-current-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    $unwanted=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Name.EndsWith('.tmp') -or $_.Extension -ceq '.pdb' -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($unwanted.Count -and !$failure){$failure='owned tmp/PDB/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'equal_component_opportunity_verified_not_timed'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;runtime_path=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();script_path=$PSCommandPath;script_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;validated_base_identity_records=$validatedBaseRecords;identities=$ids;checks=$checks;invocations=$calls;profiles=$profiles;owned_tmp_pdb_reparse=$unwanted.Count;diagnostic_timing_used=$false;counter_only=$true;restore_cleanup=$restoreEvidence;ordinary_performance_retried=$false;observer_gate_changed=$false;off_variant_executed=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;validated_base_records=$validatedBaseRecords;work=$work;bytes_before_report=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}
