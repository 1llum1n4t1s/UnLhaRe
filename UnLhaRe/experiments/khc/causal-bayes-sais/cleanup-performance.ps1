#requires -Version 7.2
# 失敗条件: receipt既存、report変更、予定/実行件数不一致、稼働process、reparse、
# source/provenance変更、出力証拠不足、初回/最終回とのbytes/hash不一致は削除前に拒否する。
# 削除途中の変更・削除失敗・保持物変更・残存・receipt書込失敗も成功扱いにしない。
# 独立照合済みの同backend反復だけを削除する。直接復旧は不可、初回/最終回と再現材料を保持。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ownedRoot = 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\khc-bwt-causal-bayes-sais-20260930'
$specs = @(
    @{ name='performance-retry1'; hash='3EC710A481A62D3905A7B06F44B2BAA3A0C5B2A6BF4A8C9917E1FCB66A530095'; status='failed'; actual=23; planned=1; samples=18; last=5 },
    @{ name='performance-retry2'; hash='8650F4B5DAD2BA230DE40A3BD9FF5F9B91A482C755B213CCA103EF2241D74FED'; status='success'; actual=39; planned=0; samples=30; last=9 }
)
function Assert-PlainPath([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute path required.' }
    $absolute = [IO.Path]::GetFullPath($Path)
    $ancestor = $absolute
    while ($ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse rejected: $ancestor" }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $absolute
}
function Identity([string]$Path) {
    $absolute = Assert-PlainPath $Path
    $item = Get-Item -LiteralPath $absolute -Force
    if ($item -isnot [IO.FileInfo]) { throw "Regular file required: $absolute" }
    [pscustomobject]@{ path=$absolute; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash }
}
function Assert-EqualIdentity($Actual, $Expected) {
    if ($Actual.path -cne $Expected.path -or $Actual.bytes -ne $Expected.bytes -or $Actual.sha256 -cne $Expected.sha256) { throw "Identity changed: $($Expected.path)" }
}
function Assert-Idle {
    $active = @(Get-CimInstance Win32_Process | Where-Object {
        ($_.ExecutablePath -and $_.ExecutablePath.StartsWith($ownedRoot + '\', [StringComparison]::OrdinalIgnoreCase)) -or
        ($_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($ownedRoot, [StringComparison]::OrdinalIgnoreCase))
    })
    if ($active.Count) { throw 'Owned experiment process still active.' }
}
function Inventory([string]$Directory) {
    # 各階層を先に検査し、reparseディレクトリへ再帰しない。
    $null = Assert-PlainPath $Directory
    foreach ($item in Get-ChildItem -LiteralPath $Directory -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse rejected: $($item.FullName)" }
        if ($item -is [IO.DirectoryInfo]) { Inventory $item.FullName } else { Identity $item.FullName }
    }
}
function Write-Receipt($Stream, $Receipt) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Receipt | ConvertTo-Json -Depth 12))
    $Stream.Position = 0
    $Stream.SetLength(0)
    $Stream.Write($bytes)
    $Stream.Flush($true)
}
$null = Assert-PlainPath $ownedRoot
Assert-Idle
$plans = [Collections.Generic.List[object]]::new()
foreach ($spec in $specs) {
    $work = Join-Path $ownedRoot $spec.name
    $null = Assert-PlainPath $work
    $receiptPath = Join-Path $work 'cleanup.json'
    if (Test-Path -LiteralPath $receiptPath) { throw "Receipt exists; no retry: $receiptPath" }
    $reportPath = Join-Path $work 'report.json'
    $reportId = Identity $reportPath
    if ($reportId.sha256 -cne $spec.hash) { throw 'Pinned report changed.' }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $actual = @($report.invocations | Where-Object { $null -ne $_.exit_code })
    $planned = @($report.invocations | Where-Object { $null -eq $_.exit_code })
    if ($report.status -cne $spec.status -or $actual.Count -ne $spec.actual -or $planned.Count -ne $spec.planned -or @($report.samples).Count -ne $spec.samples) { throw 'Pinned report shape mismatch.' }
    foreach ($row in $actual) {
        if ($row.exit_code -ne 0 -or $row.timed_out -or $row.error) { throw 'Actual invocation not successful.' }
    }
    $support = [Collections.Generic.List[object]]::new()
    foreach ($row in $report.provenance) {
        $id = Identity $row.path
        if ($id.bytes -ne $row.before_bytes -or $id.bytes -ne $row.after_bytes -or $id.sha256 -cne $row.before_sha256 -or $id.sha256 -cne $row.after_sha256) { throw "Provenance changed: $($row.path)" }
        $support.Add($id)
    }
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($codec in @('sais-group', 'exact-div-control', '7zip-native')) {
        $extension = if ($codec -ceq '7zip-native') { '7z' } else { 'bayes' }
        $first = Identity (Join-Path $work "$codec-0.$extension")
        $last = Identity (Join-Path $work "$codec-$($spec.last).$extension")
        if ($first.bytes -ne $last.bytes -or $first.sha256 -cne $last.sha256) { throw 'First/last archives differ.' }
        foreach ($round in 0..$spec.last) {
            $id = Identity (Join-Path $work "$codec-$round.$extension")
            if (-not $id.path.StartsWith($work + '\', [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($id.path) -cne $work) { throw 'Target escaped fixed work root.' }
            $sample = @($report.samples | Where-Object { $_.codec -ceq $codec -and $_.round -eq $round })
            $invocation = @($actual | Where-Object { $_.kind -ceq 'encode' -and $_.codec -ceq $codec -and $_.round -eq $round })
            if ($sample.Count -ne 1 -or $invocation.Count -ne 1) { throw 'Unique archive evidence missing.' }
            $s = $sample[0]; $i = $invocation[0]
            if ($round -eq 0 -and $s.decode_verification -cne 'direct_decode_and_hash') { throw 'First archive direct decode evidence missing.' }
            if (-not $s.decode_verified -or $s.archive_bytes -ne $id.bytes -or $s.archive_sha256 -cne $id.sha256 -or $i.output_path -cne $id.path -or $i.output_bytes -ne $id.bytes -or $i.output_sha256 -cne $id.sha256 -or $id.bytes -ne $first.bytes -or $id.sha256 -cne $first.sha256) { throw 'Archive identity proof mismatch.' }
            if ($round -gt 0 -and $round -lt $spec.last) { $targets.Add($id) }
        }
    }
    $retained = @(Inventory $work | Where-Object { $_.path -cnotin $targets.path })
    $plans.Add([pscustomobject]@{ spec=$spec; work=$work; receipt_path=$receiptPath; report=$reportId; targets=$targets; retained=$retained; support=$support; removed=[Collections.Generic.List[object]]::new(); stream=$null })
}
$targetCount = 0
foreach ($plan in $plans) { $targetCount += $plan.targets.Count }
if ($targetCount -ne 36) { throw 'Expected exactly 36 fixed targets.' }
# 両rootの全件確認を完了してから、CreateNewで実行を予約。中断時も再実行を拒否する。
$status = 'failed'
$failure = 'Cleanup did not reach verified completion.'
try {
    $receiptError = $null
    foreach ($plan in $plans) {
        $null = Assert-PlainPath $plan.work
        $plan.stream = [IO.File]::Open($plan.receipt_path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        Write-Receipt $plan.stream ([ordered]@{ status='in_progress'; targets=$plan.targets.ToArray(); removed_files=0; recorded_utc=[DateTime]::UtcNow.ToString('o') })
    }
    Assert-Idle
    foreach ($plan in $plans) {
        foreach ($target in $plan.targets) {
            Assert-Idle
            Assert-EqualIdentity (Identity $target.path) $target
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
            if (Test-Path -LiteralPath $target.path) { throw 'Target still exists.' }
            $plan.removed.Add($target)
        }
    }
    foreach ($plan in $plans) {
        foreach ($saved in @($plan.retained) + @($plan.support.ToArray())) { Assert-EqualIdentity (Identity $saved.path) $saved }
        Assert-EqualIdentity (Identity $plan.report.path) $plan.report
        if (@($plan.targets | Where-Object { Test-Path -LiteralPath $_.path }).Count) { throw 'Target residual exists.' }
    }
    $status = 'success'
    $failure = $null
} catch {
    $failure = $_.Exception.Message
    throw
} finally {
    foreach ($plan in $plans) {
        if ($null -ne $plan.stream) {
            try {
                $receipt = [ordered]@{
                    status=$status; error=$failure; owned_root=$ownedRoot; work_root=$plan.work
                    removed_files=$plan.removed.Count; removed_bytes=($plan.removed | Measure-Object bytes -Sum).Sum
                    targets=$plan.targets.ToArray(); removed=$plan.removed.ToArray()
                    target_residual_count=@($plan.targets | Where-Object { Test-Path -LiteralPath $_.path }).Count
                    retained_files=$plan.retained; retained_provenance=$plan.support.ToArray(); retained_report=$plan.report
                    all_preflight_checks_completed=$true; all_postchecks_completed=($status -ceq 'success')
                    identical_bytes_retained_at_round_zero_and_last=$true
                    reproducible_from_retained_source_binary_and_input=($status -ceq 'success')
                    recoverable_from_deleted_bytes=$false
                    recovery_note='削除物そのものの直接回復は不可。同一backendの初回/最終回、入力、source、binary、reportを保持。'
                    recorded_utc=[DateTime]::UtcNow.ToString('o')
                }
                Write-Receipt $plan.stream $receipt
            } catch {
                $receiptError = $_
            } finally { $plan.stream.Dispose() }
        }
    }
    if ($null -ne $receiptError) {
        # 最終receiptの一部だけ成功に見える状態を避け、既に作成した全receiptを失敗に直す。
        foreach ($plan in $plans) {
            if ($null -ne $plan.stream) {
                $repair = $null
                try {
                    $repair = [IO.File]::Open($plan.receipt_path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    Write-Receipt $repair ([ordered]@{ status='failed'; error=$receiptError.Exception.Message; targets=$plan.targets.ToArray(); removed=$plan.removed.ToArray(); removed_files=$plan.removed.Count; removed_bytes=($plan.removed | Measure-Object bytes -Sum).Sum; target_residual_count=@($plan.targets | Where-Object { Test-Path -LiteralPath $_.path }).Count; retained_files=$plan.retained; retained_provenance=$plan.support.ToArray(); retained_report=$plan.report; recoverable_from_deleted_bytes=$false; recorded_utc=[DateTime]::UtcNow.ToString('o') })
                } catch { Write-Warning "Failed receipt could not be persisted: $($plan.receipt_path)" }
                finally { if ($null -ne $repair) { $repair.Dispose() } }
            }
        }
        throw $receiptError
    }
}
'Performance cleanup: 36 fixed duplicate archives removed; both reports and retained evidence unchanged.'
