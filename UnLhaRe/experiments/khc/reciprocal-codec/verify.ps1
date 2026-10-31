#requires -Version 7.2
# 実装前失敗計画: ../RECIPROCAL_CODEC_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-reciprocal-codec-20261002'
$baseWork=Join-Path $root 'build/khc-light-compact-codec-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new();$seen=@{}
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$transients=[Collections.Generic.List[object]]::new()
$failure=$null;$baseRecords=0;$numericRecords=0;$peakOwned=0L
$began=[DateTime]::UtcNow.ToString('o')
$fixedFrame=Join-Path $work 'fixed-native.frame'
$scratchFrame=Join-Path $work 'scratch.frame'
$scratchRestore=Join-Path $work 'scratch.restore'
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
function Child([string]$Program,[string[]]$Argv,[int]$Expected=0) {
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
        if($call.exit -ne $Expected -or $call.stdout.Length -gt 65536 -or $call.stderr.Length -gt 65536 -or ($Expected -eq 0 -and $call.stderr) -or ($Expected -ne 0 -and $call.stdout)){throw 'unexpected child result'}
        return $call
    } finally {
        if($started -and !$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(10000)}
        $process.Dispose()
    }
}
function Same([string]$First,[string]$Second) {
    if((Get-Item -LiteralPath $First).Length -ne (Get-Item -LiteralPath $Second).Length){throw 'full byte length mismatch'}
    $a=[IO.File]::OpenRead($First);$b=[IO.File]::OpenRead($Second)
    try {
        $ab=[byte[]]::new(65536);$bb=[byte[]]::new(65536)
        while(($count=$a.Read($ab,0,$ab.Length)) -gt 0){
            if($b.Read($bb,0,$count) -ne $count -or ![ReciprocalByteCompare]::Equal($ab,$bb,$count)){throw 'full bytes differ'}
        }
    } finally {$a.Dispose();$b.Dispose()}
}
function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase) -or $Bytes.Length -gt 512KB){throw 'bounded owned write refused'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Budget {
    $current=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    $script:peakOwned=[Math]::Max($script:peakOwned,[long]$current.used_bytes)
    return $current
}
function Snapshot([string]$Path,[string]$Role,[string]$Against,[bool]$Remove=$true) {
    Same $Path $Against
    $actual=(Get-FileHash -LiteralPath $Path).Hash
    $expected=(Get-FileHash -LiteralPath $Against).Hash
    if($actual -cne $expected){throw 'byte comparison/hash inconsistency'}
    $row=[pscustomobject]@{path=$Path;role=$Role;bytes=(Get-Item -LiteralPath $Path).Length;sha256=$actual;compared_against=$Against;reference_sha256=$expected;full_bytes_compared=$true;delete_requested=$Remove;deleted=$false}
    $transients.Add($row)
    $null=Budget
    if($Remove){
        $full=[IO.Path]::GetFullPath($Path)
        if($full -cne $scratchFrame -and $full -cne $scratchRestore){throw 'not an explicitly owned scratch output'}
        if($seen.ContainsKey($full)){throw 'cannot remove stable identity'}
        $ancestor=$full
        while($ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'scratch reparse'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
        # ChildはWaitForExitとDispose済み、比較streamも閉じている。外部writerがあればここで失敗。
        $exclusive=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
        try{if($exclusive.Length -ne $row.bytes){throw 'scratch changed before removal'}}finally{$exclusive.Dispose()}
        if((Get-FileHash -LiteralPath $full).Hash -cne $actual){throw 'scratch changed before removal'}
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
} -Paths $full -Root $work | Out-Null
        if(Test-Path -LiteralPath $full){throw 'scratch removal failed'}
        $row.deleted=$true
    }
    $null=Budget
}
function ReferenceCall([string]$Program,[string]$Operation,[string]$Output) {
    $referenceMatches=@($script:base.invocations|Where-Object {$_.program -ceq $Program -and $_.argv.Count -eq 3 -and $_.argv[0] -ceq $Operation -and $_.argv[2] -ceq $Output})
    if($referenceMatches.Count -ne 1){throw 'frozen reference call not unique'}
    return $referenceMatches[0]
}
function SameCall($Actual,$Expected) {
    if($Actual.exit -ne $Expected.exit -or $Actual.stdout -cne $Expected.stdout -or $Actual.stderr -cne $Expected.stderr){throw 'complete call result differs'}
}
Add-Type -TypeDefinition @'
using System;
public static class ReciprocalByteCompare {
    public static bool Equal(byte[] a,byte[] b,int count) { return a.AsSpan(0,count).SequenceEqual(b.AsSpan(0,count)); }
}
'@
$budgetBefore=Budget
if(Test-Path -LiteralPath $work){throw 'Fresh output required; no automatic retry/overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $null=Hold (Join-Path $PSScriptRoot '../RECIPROCAL_CODEC_CONTRACT_20261002.md') 'preimplementation-contract' '3018755158AD075547CFB8C1753E76A678714C83CE4646500F2C387876B80306'
    $basePath=Join-Path $baseWork 'report.json'
    $null=Hold $basePath 'frozen-full-proof' '9DB9E948B5D9F270FB5C58D003DC6BF6650C61121A7F499D361B407B8108D2BD'
    $script:base=Get-Content -LiteralPath $basePath -Raw|ConvertFrom-Json
    if($base.status -cne 'correctness_and_size_passed_not_timed' -or $base.failure -or $base.timing_used -or $base.checks.Count -ne 51 -or $base.invocations.Count -ne 86 -or $base.identities.Count -ne 841 -or $base.frame_bytes -ne 483496){throw 'frozen full matrix'}
    foreach($identity in $base.identities){
        if($identity.before_sha256 -cne $identity.after_sha256){throw 'frozen identity before/after'}
        $entry=Hold $identity.path 'frozen-full-current-identity' $identity.after_sha256
        if($entry.bytes -ne $identity.bytes){throw 'frozen identity length'}
        $baseRecords++
    }
    $checks.Add('frozen-full-and-all-current-841-records')
    $numericPath=Join-Path $root 'build/khc-reciprocal-batch-20261002/report.json'
    $null=Hold $numericPath 'new-numeric-proof' 'A58898BA7716CE836B921FA04E3152718BB5D96B53FA279EC5EB27FAD69D3DD4'
    $numeric=Get-Content -LiteralPath $numericPath -Raw|ConvertFrom-Json
    if($numeric.status -cne 'reciprocal_batch_numeric_verified_not_codec_or_timing' -or $numeric.failure -or $numeric.timing_used -or $numeric.checks.Count -ne 32 -or $numeric.invocations.Count -ne 87 -or $numeric.identities.Count -ne 28 -or $numeric.summaries.Count -ne 4 -or !$numeric.features.avx2_available){throw 'new numerical matrix'}
    foreach($identity in $numeric.identities){
        if($identity.before_sha256 -cne $identity.after_sha256){throw 'numeric identity before/after'}
        $entry=Hold $identity.path 'numeric-current-identity' $identity.after_sha256
        if($entry.bytes -ne $identity.bytes){throw 'numeric identity length'}
        $numericRecords++
    }
    foreach($summary in $numeric.summaries){
        if($summary.summary.records -ne 9293629 -or $summary.summary.matched -ne 9293629 -or $summary.summary.compact -ne 8398832 -or $summary.summary.certificate_fallback -ne 0 -or $summary.summary.fingerprint_u64 -cne 'f02dbdcb00adbe1d'){throw 'frozen numeric coverage'}
    }
    $checks.Add('four-condition-independent-numeric-proof-reused-not-rerun')
    foreach($name in @('codec.rs','scheduler.rs','heavy.rs','exact_kt.rs','correspondence.json','verify.ps1')){$null=Hold (Join-Path $PSScriptRoot $name) 'new-source'}
    $null=Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    foreach($source in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json)){
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes){if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source occurrence'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n") -cne $expected){throw 'four source correspondence'}
    }
    $checks.Add('complete-four-source-correspondence')
    $null=Child $compiler @('--version','--verbose')
    foreach($variant in @('native','checked','scalar','scalar-checked','counted')){
        $exe=Join-Path $work "codec-$variant.exe"
        $argv=@((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C','opt-level=3','-C','panic=abort','-C','link-arg=/DEBUG:NONE','-o',$exe)
        if($variant -in @('checked','scalar-checked','counted')){$argv+=@('-C','overflow-checks=yes')}
        if($variant -in @('scalar','scalar-checked')){$argv+=@('--cfg','khc_force_scalar_batch')}
        if($variant -ceq 'counted'){$argv+=@('--cfg','khc_compact_counts')}
        $null=Child $compiler $argv
        $entry=Hold $exe "$variant-codec"
        if($entry.bytes -gt 300000){throw 'codec exceeds disk forecast'}
    }
    $checks.Add('four-codec-conditions-and-counted-build')
    $baseNative=Join-Path $baseWork 'codec-native.exe'
    $candidate=Join-Path $work 'codec-native.exe'
    foreach($caseName in @('empty','single','all_bytes','repeated','periodic','seeded_random','fixed')){
        $goldenFrame=Join-Path $baseWork "$caseName-native.frame"
        $nativeReference=ReferenceCall $baseNative 'encode' $goldenFrame
        $caseInput=$nativeReference.argv[1]
        $entry=Hold $caseInput 'shared-case-input'
        if($entry.bytes -gt 2811006){throw 'case outside forecast'}
        Same $caseInput (Join-Path $baseWork "$caseName-native.restore")
        if($caseName -ceq 'fixed' -and ($entry.bytes -ne 2811006 -or $entry.before_sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76')){throw 'fixed input changed'}
        foreach($variant in @('native','checked','scalar','scalar-checked')){
            $exe=Join-Path $work "codec-$variant.exe"
            $frame=if($caseName -ceq 'fixed' -and $variant -ceq 'native'){$fixedFrame}else{$scratchFrame}
            $encRef=ReferenceCall (Join-Path $baseWork "codec-$variant.exe") 'encode' (Join-Path $baseWork "$caseName-$variant.frame")
            SameCall (Child $exe @('encode',$caseInput,$frame)) $encRef
            Same $frame $goldenFrame
            $decRef=ReferenceCall (Join-Path $baseWork "codec-$variant.exe") 'decode' (Join-Path $baseWork "$caseName-$variant.restore")
            SameCall (Child $exe @('decode',$frame,$scratchRestore)) $decRef
            Snapshot $scratchRestore "$caseName-$variant-restore" $caseInput
            $checks.Add("$caseName-$variant-full-frame-summary-restore")
            if($variant -ceq 'native'){
                $oldRef=@($base.invocations|Where-Object {$_.argv.Count -eq 3 -and $_.argv[0] -ceq 'decode' -and $_.argv[1] -ceq $goldenFrame -and !$_.program.StartsWith($baseWork+'\',[StringComparison]::OrdinalIgnoreCase)})
                if($oldRef.Count -ne 1){throw 'old decoder reference not unique'}
                SameCall (Child $oldRef[0].program @('decode',$frame,$scratchRestore)) $oldRef[0]
                Snapshot $scratchRestore "$caseName-old-decoder-new-frame" $caseInput
                $reverseRef=ReferenceCall $baseNative 'decode' (Join-Path $baseWork "$caseName-new-decoder-old-frame.restore")
                SameCall (Child $exe @('decode',$reverseRef.argv[1],$scratchRestore)) $reverseRef
                Snapshot $scratchRestore "$caseName-new-decoder-old-frame" $caseInput
                $checks.Add("$caseName-bidirectional-old-decoder-interoperability")
            }
            if($frame -ceq $fixedFrame){Snapshot $frame 'retained-fixed-native-frame' $goldenFrame $false;$null=Hold $fixedFrame 'fixed-native-frame' 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'}
            else{Snapshot $frame "$caseName-$variant-frame" $goldenFrame}
        }
    }
    if((Get-Item -LiteralPath $fixedFrame).Length -ne 483496 -or (Get-Item -LiteralPath $fixedFrame).Length -gt 483599){throw 'fixed size gate'}
    $checks.Add('fixed-frame-size-and-unchanged-wire-gate')
    $fixedInput=(ReferenceCall $baseNative 'encode' (Join-Path $baseWork 'fixed-native.frame')).argv[1]
    $baseCounted=Join-Path $baseWork 'codec-counted.exe'
    $counted=Join-Path $work 'codec-counted.exe'
    SameCall (Child $counted @('encode',$fixedInput,$scratchFrame)) (ReferenceCall $baseCounted 'encode' (Join-Path $baseWork 'fixed-counted.frame'))
    SameCall (Child $counted @('decode',$scratchFrame,$scratchRestore)) (ReferenceCall $baseCounted 'decode' (Join-Path $baseWork 'fixed-counted.restore'))
    Snapshot $scratchFrame 'counted-fixed-frame' $fixedFrame
    Snapshot $scratchRestore 'counted-fixed-restore' $fixedInput
    $checks.Add('actual-kernel-counts-layout-entire-stdout-and-restored-bytes')
    foreach($badName in @('magic','header_crc','payload_crc','truncated','trailing')){
        $ref=ReferenceCall $baseNative 'decode' (Join-Path $baseWork "rejected-$badName.restore")
        $null=Hold $ref.argv[1] 'shared-malformed-fixture'
        $rejected=Join-Path $work "rejected-$badName.restore"
        SameCall (Child $candidate @('decode',$ref.argv[1],$rejected) 1) $ref
        if(Test-Path -LiteralPath $rejected){throw 'rejected frame published output'}
        $checks.Add("$badName-rejected-no-output")
    }
    foreach($operation in @('encode','decode')){
        $sentinel=Join-Path $work "$operation.existing"
        Write-New $sentinel ([Text.Encoding]::UTF8.GetBytes('keep-existing-output'))
        $entry=Hold $sentinel "$operation-no-clobber-sentinel"
        $ref=ReferenceCall $baseNative $operation (Join-Path $baseWork "$operation.existing")
        SameCall (Child $candidate @($operation,$ref.argv[1],$sentinel) 1) $ref
        if((Get-FileHash -LiteralPath $sentinel).Hash -cne $entry.before_sha256){throw 'no-clobber sentinel changed'}
        $checks.Add("$operation-no-clobber")
    }
    $missing=Join-Path $work 'absent.input';$missingOutput=Join-Path $work 'missing.restore'
    $missingRef=ReferenceCall $baseNative 'encode' (Join-Path $baseWork 'missing.restore')
    SameCall (Child $candidate @('encode',$missing,$missingOutput) 1) $missingRef
    if((Test-Path -LiteralPath $missing) -or (Test-Path -LiteralPath $missingOutput)){throw 'missing input published output'}
    $checks.Add('missing-input-rejected-no-output')
    foreach($identity in $ids){$identity.after_sha256=(Get-FileHash -LiteralPath $identity.path).Hash;if($identity.after_sha256 -cne $identity.before_sha256 -or (Get-Item -LiteralPath $identity.path).Length -ne $identity.bytes){throw 'held identity changed'}}
    $checks.Add('all-stable-identities-unchanged')
    if((Test-Path -LiteralPath $scratchFrame) -or (Test-Path -LiteralPath $scratchRestore) -or @($transients|Where-Object {$_.delete_requested -and !$_.deleted}).Count){throw 'finished scratch remains'}
    $checks.Add('all-compared-scratch-outputs-removed-with-records')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=Budget
    $unwanted=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Extension -in @('.tmp','.pdb') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($unwanted.Count -and !$failure){$failure='owned tmp/PDB/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'reciprocal_codec_correctness_and_size_passed_not_timed'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;runtime_path=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();verifier=$PSCommandPath;verifier_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;peak_owned_bytes_checked=$peakOwned;validated_base_records=$baseRecords;validated_numeric_records=$numericRecords;identities=$ids;checks=$checks;invocations=$calls;compared_output_records=$transients;owned_tmp_pdb_reparse=$unwanted.Count;timing_used=$false;formal_performance_retried=$false;observer_gate_changed=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $budgetFinal=Budget
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;compared_outputs=$transients.Count;work=$work;retained_bytes=$budgetFinal.used_bytes;peak_checked_bytes=$peakOwned}|ConvertTo-Json)
}
if($failure){exit 1}
