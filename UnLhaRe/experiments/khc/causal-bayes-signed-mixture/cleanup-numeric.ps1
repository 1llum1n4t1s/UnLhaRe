#requires -Version 7.2
# 独立照合済み数値CLIの同一backend別process反復だけを清掃。入力/初回/proofは保持。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ownedRoot='C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-bwt-causal-bayes-signed-mixture-20260930'
$work=Join-Path $ownedRoot 'numeric-e2e'
$reportPath=Join-Path $work 'report.json'
$receiptPath=Join-Path $work 'cleanup.json'
$expectedHash='CA2F50006E5E6D801E3FF90BC7DD55A02522C7A22B794911A24D7FA7A1628C74'
function Identity([string]$Path){
    $absolute=[IO.Path]::GetFullPath($Path)
    if(-not $absolute.StartsWith($ownedRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Target escaped owned root.'}
    $ancestor=$absolute
    while($ancestor){if((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    $item=Get-Item -LiteralPath $absolute -Force
    if($item -isnot [IO.FileInfo]){throw 'Regular file required.'}
    [pscustomobject]@{path=$absolute;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $absolute).Hash}
}
if(Test-Path -LiteralPath $receiptPath){throw 'Cleanup receipt exists; no retry.'}
$reportId=Identity $reportPath
if($reportId.sha256 -cne $expectedHash){throw 'Pinned proof changed.'}
$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
if($report.status -cne 'verified' -or @($report.checks).Count -ne 20 -or @($report.invocations).Count -ne 20){throw 'Proof incomplete.'}
$active=@(Get-CimInstance Win32_Process|Where-Object {($_.ExecutablePath -and $_.ExecutablePath.StartsWith($ownedRoot,[StringComparison]::OrdinalIgnoreCase)) -or ($_.Name -ceq 'rustc.exe' -and $_.CommandLine -and $_.CommandLine.Contains($ownedRoot,[StringComparison]::OrdinalIgnoreCase))})
if($active.Count){throw 'Owned process still active.'}
$retained=[Collections.Generic.List[object]]::new()
$targets=[Collections.Generic.List[object]]::new()
foreach($name in @('empty','known','maximum')){
    $retained.Add((Identity (Join-Path $work "$name.input")))
    foreach($backend in @('opt3','opt2')){
        $saved=Identity (Join-Path $work "$name-$backend-0.output")
        $target=Identity (Join-Path $work "$name-$backend-1.output")
        $row=@($report.checks|Where-Object {$_.name -ceq "$name-$backend-1"})
        if($row.Count -ne 1 -or $row[0].evidence.output.path -cne $target.path -or $row[0].evidence.output.bytes -ne $target.bytes -or $row[0].evidence.output.sha256 -cne $target.sha256 -or $target.sha256 -cne $saved.sha256 -or $target.bytes -ne $saved.bytes){throw 'Duplicate not proven identical.'}
        $retained.Add($saved);$targets.Add($target)
    }
}
if($targets.Count -ne 6){throw 'Unexpected cleanup scope.'}
$removed=[Collections.Generic.List[object]]::new()
foreach($target in $targets){
    $current=Identity $target.path
    if($current.sha256 -cne $target.sha256 -or $current.bytes -ne $target.bytes){throw 'Target changed before deletion.'}
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
} -Paths $target.path -Root $ownedRoot | Out-Null
    if(Test-Path -LiteralPath $target.path){throw 'Target still exists.'}
    $removed.Add($target)
}
foreach($saved in $retained){$current=Identity $saved.path;if($current.sha256 -cne $saved.sha256 -or $current.bytes -ne $saved.bytes){throw 'Retained artifact changed.'}}
if((Identity $reportPath).sha256 -cne $expectedHash){throw 'Proof changed during cleanup.'}
$receipt=[ordered]@{removed_files=$removed.Count;removed_bytes=($removed|Measure-Object bytes -Sum).Sum;targets=$removed.ToArray();target_residual_count=@($removed|Where-Object {Test-Path -LiteralPath $_.path}).Count;retained_files=$retained.ToArray();retained_report_sha256=$expectedHash;retained_report_unchanged=$true;recoverable_from_deleted_bytes=$false;identical_bytes_retained_at_round_zero=$true;reproducible_from_source_and_input=$true;recorded_utc=[DateTime]::UtcNow.ToString('o')}
$stream=[IO.File]::Open($receiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 8)));$stream.Flush($true)}finally{$stream.Dispose()}
"Numeric cleanup: $($receipt.removed_files) files / $($receipt.removed_bytes) bytes; proof unchanged."
