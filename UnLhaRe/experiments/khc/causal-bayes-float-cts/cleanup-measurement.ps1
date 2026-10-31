#requires -Version 7.2
# 完了した今回の2測定だけ。過去にpolicy拒否された別rootへは触らない。
param([ValidateSet('performance')][string]$Measurement='performance')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$roots=@{ 'performance'='77193821F97BE3A855EC9315E08F402FB288D42BCBC230E541740D518C53DFFE' }
$work=[IO.Path]::GetFullPath((Join-Path $repo "build/khc-bwt-causal-bayes-float-cts-20260930/$Measurement"))
$prefix=$work+[IO.Path]::DirectorySeparatorChar
function No-Reparse([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){ throw 'Reparse rejected.' }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
No-Reparse $work
$reportPath=Join-Path $work 'report.json'
$reportHash=(Get-FileHash -LiteralPath $reportPath).Hash
if($reportHash -cne $roots[$Measurement]){ throw 'Measured report identity mismatch.' }
$proof=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
if($proof.status -cne 'success'){ throw 'Only completed measurement may be cleaned.' }
$receipt=Join-Path $work 'cleanup.json'
if(Test-Path -LiteralPath $receipt){ throw 'Cleanup receipt exists; no retry.' }
$ownedBuild=[IO.Path]::GetDirectoryName($work)+[IO.Path]::DirectorySeparatorChar
$active=@(Get-CimInstance Win32_Process|Where-Object{
    ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($ownedBuild,[StringComparison]::OrdinalIgnoreCase)) -or
    ($_.Name -in @('7za.exe','rustc.exe') -and $_.CommandLine -and $_.CommandLine.IndexOf($ownedBuild,[StringComparison]::OrdinalIgnoreCase) -ge 0)
})
if($active.Count){ throw 'Codec/build process still active.' }
$retained=[Collections.Generic.List[object]]::new()
foreach($run in @($proof.invocations|Where-Object{ $_.output_path -and ($_.kind -cne 'encode' -or $_.round -in @(0,9)) })){
    No-Reparse $run.output_path
    $item=Get-Item -LiteralPath $run.output_path -Force
    $hash=(Get-FileHash -LiteralPath $run.output_path).Hash
    if($item -isnot [IO.FileInfo] -or $item.Length -ne $run.output_bytes -or $hash -cne $run.output_sha256){throw 'Retained decode/archive identity mismatch.'}
    $retained.Add([pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=$hash})
}
$targets=[Collections.Generic.List[object]]::new()
foreach($series in @('float-cts-group','exact-div-control','7zip-native')){
    foreach($round in 1..8){
        $extension=if($series -ceq '7zip-native'){'7z'}else{'bayes'}
        $path=[IO.Path]::GetFullPath((Join-Path $work "$series-$round.$extension"))
        if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){ throw 'Cleanup path outside exact root.' }
        No-Reparse $path
        $item=Get-Item -LiteralPath $path -Force
        if($item -isnot [IO.FileInfo]){ throw 'Only a regular archive may be cleaned.' }
        $run=@($proof.invocations|Where-Object{ $_.kind -ceq 'encode' -and $_.codec -ceq $series -and $_.round -eq $round })
        $hash=(Get-FileHash -LiteralPath $path).Hash
        if($run.Count -ne 1 -or $run[0].output_bytes -ne $item.Length -or $run[0].output_sha256 -cne $hash){ throw 'Cleanup archive differs from verified invocation.' }
        $targets.Add([pscustomobject]@{ path=$path; bytes=$item.Length; sha256=$hash; removed=$false })
    }
}
if($targets.Count -ne 24){ throw 'Expected exactly 24 intermediate archives.' }
$failure=$null
try{
    foreach($target in $targets){ & {
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
} -Paths $target.path -Root $work | Out-Null; $target.removed=-not(Test-Path -LiteralPath $target.path); if(-not $target.removed){ throw 'Removal not confirmed.' } }
}catch{ $failure=$_ }
finally{
    $unchanged=(Get-FileHash -LiteralPath $reportPath).Hash -ceq $reportHash
    foreach($file in $retained){if(-not(Test-Path -LiteralPath $file.path) -or (Get-FileHash -LiteralPath $file.path).Hash -cne $file.sha256){$failure='Retained evidence changed.'}}
    $record=[ordered]@{ retained_files=$retained.ToArray(); status=$(if($null -eq $failure -and $unchanged){'cleaned'}else{'failed'}); error=$(if($null -ne $failure){[string]$failure}else{$null}); targets=$targets.ToArray(); removed_files=@($targets|Where-Object removed).Count; removed_bytes=($targets|Where-Object removed|Measure-Object bytes -Sum).Sum; retained_report_sha256=$reportHash; retained_report_unchanged=$unchanged; initial_final_archives_and_direct_decodes_retained=$true; recoverable_from_saved_bytes=$false; reproducible_from_retained_source_and_input=$true; recorded_utc=[DateTime]::UtcNow.ToString('o') }
    $sink=[IO.File]::Open($receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer=[IO.StreamWriter]::new($sink,[Text.UTF8Encoding]::new($false))
    try{ $writer.Write(($record|ConvertTo-Json -Depth 8)) }finally{ $writer.Dispose() }
}
if($null -ne $failure){ throw $failure }
"Cleanup completed: $($record.removed_files) files / $($record.removed_bytes) bytes; report unchanged=$unchanged."




