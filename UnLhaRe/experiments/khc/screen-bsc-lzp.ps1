#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BscPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# 失敗条件を先に固定する。入力/binary/hash不一致、reparse、既存出力、
# 非zero終了、timeout、復元不一致、非決定性、実行中の入力変更では成功を記録しない。
# 同一binary/flagsに-pだけを加えるsize ablation。パラメータ探索や速度評価はしない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below UnLhaRe/build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
foreach ($path in @($BscPath, $GroupPath, $work)) { Assert-NoReparse $path }
$bsc = (Resolve-Path -LiteralPath $BscPath).Path
$group = (Resolve-Path -LiteralPath $GroupPath).Path
$inputHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$binaryHash = 'A8AE29E3F4CBE23466C6FFC383F7ADEF0A522BAEE3EDF264F41A6509769D0DA6'
if ((Get-Item -LiteralPath $group).Length -ne 2811006 -or (Get-FileHash -LiteralPath $group).Hash -cne $inputHash) { throw 'Fixed group mismatch.' }
if ((Get-FileHash -LiteralPath $bsc).Hash -cne $binaryHash) { throw 'Reference binary mismatch.' }
$null = New-Item -ItemType Directory -Path $work
$report = [ordered]@{
    kind = 'external_bsc_lzp_size_ablation'
    status = 'running'
    created_utc = [DateTime]::UtcNow.ToString('o')
    cwd = $PWD.Path
    script = $PSCommandPath
    script_sha256 = (Get-FileHash -LiteralPath $PSCommandPath).Hash
    binary = $bsc
    binary_sha256 = $binaryHash
    input = $group
    input_bytes = 2811006
    input_sha256 = $inputHash
    fixed_max_bytes = 483599
    runs = [Collections.Generic.List[object]]::new()
    timing_used = $false
    limitations = @('External reference codec; not an independent KHC implementation.', '-p also disables segmentation/reordering; both are already disabled by baseline defaults.', 'CLI displayed timing is retained only as raw output; this experiment does not evaluate speed.')
}

function Invoke-Bsc([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new($bsc)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process start failed.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw '30 second deadline exceeded.' }
        $run = [pscustomobject]@{
            argv = $Arguments
            exit = $process.ExitCode
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
        $report.runs.Add($run)
        if ($run.exit -ne 0) { throw "Reference codec exited $($run.exit): $($run.stderr)" }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

function Describe-File([string]$Path) {
    [pscustomobject]@{ path = $Path; bytes = (Get-Item -LiteralPath $Path).Length; sha256 = (Get-FileHash -LiteralPath $Path).Hash }
}

# 読み取り共有だけを許可して入力変更を防ぐ。
$inputLock = [IO.File]::Open($group, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $baselinePath = Join-Path $work 'baseline.bsc'
    $candidatePath = Join-Path $work 'without-lzp.bsc'
    $repeatPath = Join-Path $work 'without-lzp-repeat.bsc'
    $restoredPath = Join-Path $work 'restored.group'
    $flags = @('-b25', '-m0', '-e2', '-t', '-T1')
    Invoke-Bsc (@('e', $group, $baselinePath) + $flags)
    $report.baseline = Describe-File $baselinePath
    if ($report.baseline.bytes -ne 469606 -or $report.baseline.sha256 -cne '0D3B0D2874D7BAD463291BD2181D6C920B724A6B10DFE5DD7D51E229A6CF238F') { throw 'Baseline no longer reproduces the recorded reference.' }
    Invoke-Bsc (@('e', $group, $candidatePath) + $flags + @('-p'))
    Invoke-Bsc (@('e', $group, $repeatPath) + $flags + @('-p'))
    $report.without_lzp = Describe-File $candidatePath
    $report.repeat = Describe-File $repeatPath
    if ($report.repeat.sha256 -cne $report.without_lzp.sha256) { throw 'Non-deterministic reference frame.' }
    Invoke-Bsc @('d', $candidatePath, $restoredPath, '-t', '-T1')
    $report.restored = Describe-File $restoredPath
    if ($report.restored.bytes -ne 2811006 -or $report.restored.sha256 -cne $inputHash) { throw 'Round-trip mismatch.' }
    if ((Get-FileHash -LiteralPath $group).Hash -cne $inputHash -or (Get-FileHash -LiteralPath $bsc).Hash -cne $binaryHash -or (Get-FileHash -LiteralPath $PSCommandPath).Hash -cne $report.script_sha256) { throw 'Input, binary or script changed.' }
    $report.size_delta_without_lzp = $report.without_lzp.bytes - $report.baseline.bytes
    $report.without_lzp_size_gate_passed = $report.without_lzp.bytes -le $report.fixed_max_bytes
    $report.status = 'ablation_verified'
} catch {
    $report.status = 'failed'
    $report.error = $_.Exception.ToString()
    throw
} finally {
    $inputLock.Dispose()
    $reportPath = Join-Path $work 'report.json'
    $stream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write(($report | ConvertTo-Json -Depth 8)) } finally { $writer.Dispose() }
}
Write-Host "Verified LZP ablation: $($report.baseline.bytes) -> $($report.without_lzp.bytes) bytes; report: $reportPath"
