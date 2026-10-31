[CmdletBinding()]
param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$buildRoot = Join-Path $projectRoot 'build'

function Assert-PlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "リンク・reparse point は清掃しません: $($item.FullName)"
        }
        $item = $item.Parent
    }
}

function Assert-Idle {
    $busy = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -in @('cargo.exe', 'rustc.exe') -or
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase))
    })
    if ($busy.Count) { throw "ビルド・検証プロセスが稼働中です: $($busy.ProcessId -join ',')" }
}

Assert-PlainPath $buildRoot
Assert-Idle
$tracked = @(& git -C $projectRoot ls-files -- 'build')
if ($LASTEXITCODE -ne 0 -or $tracked.Count) { throw 'build の追跡ファイル確認に失敗しました。' }
$targets = @(foreach ($target in (Get-ChildItem -LiteralPath $buildRoot -Directory -Force)) {
    if ($target.Name -ne 'cargo' -and !$target.Name.StartsWith('cargo-', [StringComparison]::Ordinal)) { continue }
    Assert-PlainPath $target.FullName
    if (!(Test-Path -LiteralPath (Join-Path $target.FullName '.rustc_info.json') -PathType Leaf)) { continue }
    $profiles = @(Get-ChildItem -LiteralPath $target.FullName -Directory -Force | Where-Object Name -in @('debug', 'release'))
    foreach ($triple in (Get-ChildItem -LiteralPath $target.FullName -Directory -Force | Where-Object Name -notin @('debug', 'release', 'tmp'))) {
        Assert-PlainPath $triple.FullName
        $profiles += @(Get-ChildItem -LiteralPath $triple.FullName -Directory -Force | Where-Object Name -in @('debug', 'release'))
    }
    foreach ($profile in $profiles) {
        $path = Join-Path $profile.FullName 'incremental'
        if (!(Test-Path -LiteralPath $path -PathType Container)) { continue }
        Assert-PlainPath $path
        $resolved = (Resolve-Path -LiteralPath $path).Path
        if (!$resolved.StartsWith($buildRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -ne 'incremental') { throw "範囲外です: $resolved" }
        $entries = @(Get-ChildItem -LiteralPath $resolved -Recurse -Force)
        if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw "配下にリンクがあります: $resolved"
        }
        if (@($entries | Where-Object { $_.Name -eq '.git' -or (!$_.PSIsContainer -and $_.Extension -in @('.rs', '.ps1', '.md', '.json', '.exe', '.dll', '.rlib', '.pdb')) }).Count) {
            throw "増分キャッシュ以外の内容があります: $resolved"
        }
        $files = @($entries | Where-Object { !$_.PSIsContainer })
        [pscustomobject]@{ path = $resolved; files = $files.Count; bytes = [long](($files | Measure-Object Length -Sum).Sum) }
    }
})
$freeBefore = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($buildRoot)).AvailableFreeSpace
$deleted = 0L
foreach ($target in $targets) {
    if ($Apply) {
        # 列挙後も使用中・リンク変更を再確認し、同じPowerShellで限定削除する。
        Assert-Idle
        Assert-PlainPath $target.path
        if (@(Get-ChildItem -LiteralPath $target.path -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw "削除直前にリンクを検出しました: $($target.path)"
        }
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
} -Paths $target.path -Root $buildRoot | Out-Null
        if (Test-Path -LiteralPath $target.path) { throw "削除後に残存しています: $($target.path)" }
        $deleted += $target.bytes
    }
}
$receipt = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    applied = [bool]$Apply
    project = $projectRoot
    target_count = $targets.Count
    target_bytes = [long](($targets | Measure-Object bytes -Sum).Sum)
    deleted_bytes = $deleted
    free_before_bytes = $freeBefore
    free_after_bytes = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($buildRoot)).AvailableFreeSpace
    preserved = @('deps', 'examples', 'build-script outputs', 'fingerprints', 'executables', 'reports', 'corpus', 'artifacts')
    recovery = '削除済み増分キャッシュは必要時に cargo build が再生成します。'
    targets = $targets
}
if ($Apply) {
    $receiptPath = Join-Path $buildRoot ('incremental-cleanup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '.json')
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
    Write-Output "receipt=$receiptPath"
}
$receipt | ConvertTo-Json -Depth 5
