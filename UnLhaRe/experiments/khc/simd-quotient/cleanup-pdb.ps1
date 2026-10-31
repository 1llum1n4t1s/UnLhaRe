[CmdletBinding()]
param([switch]$Apply)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$ownedRoots=@('C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-simd-quotient-20261002')
$exactPaths=@('C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-simd-quotient-20261002\audit-opt3.pdb','C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-simd-quotient-20261002\audit-opt2.pdb')
$plan=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'pdb-cleanup-plan.json') -Raw|ConvertFrom-Json
if($plan.planned_files.Count -ne 2 -or @($plan.planned_files.path|Where-Object {$_ -cnotin $exactPaths}).Count){throw 'exact two-file manifest required'}
$active=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(rustc|cargo|audit-opt[23]|codec-native|codec-checked|codec-scalar|codec-scalar-checked|candidate|7za)\.exe$'})
if($active.Count){throw 'related process active; no deletion'}
$ids=@(foreach($directory in $ownedRoots){(Get-Content -LiteralPath (Join-Path $directory 'report.json') -Raw|ConvertFrom-Json).identities})
$reports=@(foreach($directory in $ownedRoots){$path=Join-Path $directory 'report.json';[pscustomobject]@{path=$path;sha=(Get-FileHash -LiteralPath $path).Hash}})
foreach($file in $plan.planned_files){
    $absolute=[IO.Path]::GetFullPath($file.path)
    if($absolute -cne $file.path -or $absolute -cnotin $exactPaths -or [IO.Path]::GetDirectoryName($absolute) -cnotin $ownedRoots){throw 'outside exact owned targets'}
    $ancestor=$absolute
    while($ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse refused'};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    if((Get-Item -LiteralPath $absolute).Length -ne $file.bytes -or (Get-FileHash -LiteralPath $absolute).Hash -cne $file.sha256){throw 'PDB identity changed'}
    if(@($ids|Where-Object {$_.path -ceq $absolute}).Count){throw 'referenced evidence refused'}
    $relative=[IO.Path]::GetRelativePath('C:\Users\IMT\dev\UnLhaRe',$absolute).Replace('\','/')
    $tracked=@(git -C 'C:\Users\IMT\dev\UnLhaRe' ls-files -- $relative)
    if($LASTEXITCODE -ne 0 -or $tracked.Count){throw 'tracked data refused'}
    $probe=[IO.File]::Open($absolute,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $probe.Dispose()
}
foreach($id in $ids){if((Get-FileHash -LiteralPath $id.path).Hash -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed before cleanup'}}
if($Apply){
    # 検証済み絶対パス2件だけを単一PowerShellで削除。再帰・変数展開なし。
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
} -Paths 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-simd-quotient-20261002\audit-opt3.pdb' -Root 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build' | Out-Null
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
} -Paths 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-simd-quotient-20261002\audit-opt2.pdb' -Root 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build' | Out-Null
    foreach($path in $exactPaths){if(Test-Path -LiteralPath $path){throw 'PDB remains'}}
}
foreach($id in $ids){if((Get-FileHash -LiteralPath $id.path).Hash -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed after cleanup'}}
foreach($report in $reports){if((Get-FileHash -LiteralPath $report.path).Hash -cne $report.sha){throw 'report changed'}}
$budgets=@(foreach($directory in $ownedRoots){& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $directory -MaxRunMiB 8})
[pscustomobject]@{status=$(if($Apply){'two_owned_unreferenced_pdbs_removed'}else{'dry_run_verified_no_deletion'});ended_utc=[DateTime]::UtcNow.ToString('o');removed_files=$(if($Apply){$plan.planned_files}else{@()});removed_bytes=$(if($Apply){[long](($plan.planned_files|Measure-Object bytes -Sum).Sum)}else{0});recovery='not in trash; reproducible from retained sources/compiler; no backup created';checked_retained_identity_records=$ids.Count;unchanged_reports=$reports;budgets=$budgets;related_processes=0;remaining_planned_files=$(if($Apply){0}else{2})}|ConvertTo-Json -Depth 6
