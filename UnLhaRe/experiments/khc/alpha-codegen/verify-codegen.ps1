[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
$projectPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$experimentPath = Join-Path $projectPath 'experiments/khc'
$outputPath = Join-Path $projectPath 'build/khc-quaternary-cts-alpha-codegen-20261003'
$assemblyPath = Join-Path $outputPath 'baseline.s'
$reportPath = Join-Path $outputPath 'report.json'
$compilerPath = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$mathRoot = Join-Path $projectPath 'build/khc-quaternary-cts-pool-math-u64-20261003'
$mathReportPath = Join-Path $mathRoot 'report.json'
$sourceLocks = [Collections.Generic.List[IO.FileStream]]::new()
$codegenReport = [ordered]@{
    status = 'preflight'; began_utc = [DateTime]::UtcNow.ToString('o')
    kind = 'isolated-library-codegen-only'; benchmark_calls = 0; candidate_cli_calls = 0
    compile_calls = 0; owned_child_processes_at_end = 0
    full_binary_codegen_identity_claimed = $false; performance_improvement_claimed = $false
    sources_before = @(); sources_after = @(); record = $null
}
function File-Identity([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "識別対象が通常ファイルではありません: $Path"
    }
    [pscustomobject]@{
        path = $item.FullName; sha256 = (Get-FileHash -LiteralPath $item.FullName).Hash
        bytes = $item.Length; mtime_utc = $item.LastWriteTimeUtc.ToString('o')
    }
}
function Same-Identity($A, $B) {
    $A.path -eq $B.path -and $A.sha256 -eq $B.sha256 -and $A.bytes -eq $B.bytes -and
        [DateTimeOffset]::Parse([string]$A.mtime_utc).UtcTicks -eq [DateTimeOffset]::Parse([string]$B.mtime_utc).UtcTicks
}
function Lock-Source([string]$Path) {
    $sourceLocks.Add([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
}
function Bounded-Text([string]$Value) {
    if ([Text.Encoding]::UTF8.GetByteCount($Value) -le 65536) { return $Value }
    $low = 0; $high = [Math]::Min($Value.Length, 65536)
    while ($low -lt $high) {
        $middle = [int][Math]::Ceiling(($low + $high) / 2.0)
        if ([Text.Encoding]::UTF8.GetByteCount($Value.Substring(0, $middle)) -le 65536) { $low = $middle } else { $high = $middle - 1 }
    }
    if ($low -gt 0 -and [char]::IsHighSurrogate($Value[$low - 1])) { $low-- }
    $Value.Substring(0, $low)
}
function Compile-Assembly([string[]]$CompilerArguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $compilerPath; $startInfo.WorkingDirectory = $projectPath
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    foreach ($argument in $CompilerArguments) { $startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $startInfo
    $clock = [Diagnostics.Stopwatch]::StartNew(); $started = $false
    $out = [Text.StringBuilder]::new(); $err = [Text.StringBuilder]::new()
    $record = [ordered]@{ file = $compilerPath; arguments = $CompilerArguments; exit_code = $null; stdout = ''; stderr = ''; error = $null }
    try {
        $started = $process.Start()
        if (!$started) { throw 'compilerを起動できません' }
        $outBuffer = [char[]]::new(4096); $errBuffer = [char[]]::new(4096)
        $outTask = $process.StandardOutput.ReadAsync($outBuffer, 0, 4096)
        $errTask = $process.StandardError.ReadAsync($errBuffer, 0, 4096)
        $outDone = $false; $errDone = $false
        while (!$process.HasExited -or !$outDone -or !$errDone) {
            if ($clock.Elapsed.TotalSeconds -gt 60) { throw 'compiler timeout60秒' }
            if (!$outDone -and $outTask.IsCompleted) {
                $count = $outTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $outDone = $true } else {
                    [void]$out.Append($outBuffer, 0, $count)
                    if ($out.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt 65536) { throw 'compiler stdout64KiB超過' }
                    $outTask = $process.StandardOutput.ReadAsync($outBuffer, 0, 4096)
                }
            }
            if (!$errDone -and $errTask.IsCompleted) {
                $count = $errTask.GetAwaiter().GetResult()
                if ($count -eq 0) { $errDone = $true } else {
                    [void]$err.Append($errBuffer, 0, $count)
                    if ($err.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 65536) { throw 'compiler stderr64KiB超過' }
                    $errTask = $process.StandardError.ReadAsync($errBuffer, 0, 4096)
                }
            }
            Start-Sleep -Milliseconds 5
        }
        $record.exit_code = $process.ExitCode
    } catch {
        $record.error = $_.Exception.Message
        if ($started -and !$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(5000) }
        $record.stdout = Bounded-Text $out.ToString(); $record.stderr = Bounded-Text $err.ToString()
        $record.elapsed_ms = $clock.Elapsed.TotalMilliseconds
        $codegenReport.owned_child_processes_at_end = [int]($started -and !$process.HasExited)
        $process.Dispose()
    }
    [pscustomobject]$record
}
function Save-Report {
    $text = $codegenReport | ConvertTo-Json -Depth 12 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144) { throw 'report256KiB超過' }
    [IO.File]::WriteAllText($reportPath, $text, [Text.UTF8Encoding]::new($false))
}
try {
    $parserTokens = $null; $parserErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$parserTokens, [ref]$parserErrors)
    if ($parserErrors.Count) { throw 'PowerShell parser失敗' }
    $diskBefore = & (Join-Path $experimentPath 'disk-budget.ps1') -WorkDirectory $outputPath -MaxRunMiB 1 -MinFreeGiB 5
    if (Test-Path -LiteralPath $outputPath) { throw 'fresh出力rootが既に存在します' }
    $codegenReport.disk_before = $diskBefore
    if ((Get-FileHash -LiteralPath $mathReportPath).Hash -ne '0E252310BB8BE3415828258F190097D31CBD380A92A9CE9612C696E265E2D998') { throw '凍結Math report不一致' }
    $mathReport = Get-Content -LiteralPath $mathReportPath -Raw | ConvertFrom-Json -DateKind String
    if ($mathReport.status -ne 'passed' -or $mathReport.sources.Count -ne 130 -or $mathReport.sources_after.Count -ne 130) { throw '旧Math証拠の件数/完了状態不一致' }
    $sources = [Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 130; $index++) {
        $expected = $mathReport.sources[$index]; $after = $mathReport.sources_after[$index]
        if (!(Same-Identity $expected $after)) { throw "旧Math前後identity不一致: $($expected.path)" }
        Lock-Source $expected.path
        $live = File-Identity $expected.path
        if (!(Same-Identity $expected $live)) { throw "旧Math live identity不一致: $($expected.path)" }
        $sources.Add($live)
    }
    $additional = @(
        (Join-Path $experimentPath 'QUATERNARY_CTS_ALPHA_CODEGEN_PLAN_20261003.md'),
        (Join-Path $PSScriptRoot 'probe.rs'), $PSCommandPath,
        (Join-Path $experimentPath 'QUATERNARY_CTS_POOL_MATH_U64_RESULT_20261003.md'),
        $mathReportPath, (Join-Path $mathRoot 'math-o2-yes.exe')
    )
    foreach ($sourcePath in $additional) { Lock-Source $sourcePath; $sources.Add((File-Identity $sourcePath)) }
    if ($sources.Count -ne 136 -or @($sources.path | Sort-Object -Unique).Count -ne 136) { throw '136unique identities不一致' }
    $mathResult = $sources | Where-Object { $_.path -eq $additional[3] }
    $mathExe = $sources | Where-Object { $_.path -eq $additional[5] }
    if ($mathResult.sha256 -ne 'BD18E259719C3F33B8B0857D56B135195C53F14DC88C53D7E57A325A4EDC2EE6' -or
        $mathExe.sha256 -ne '60089C9B6241950CA9B29A1021AE85624C0BF1BD7C0F226F566CBD82033A960D') { throw '凍結Math result/EXE不一致' }
    $codegenReport.sources_before = $sources.ToArray()
    $codegenReport.old_basis_validated = $true
    $codegenReport.source_count = $sources.Count
    $codegenReport.compiler = $mathReport.compiler
    $codegenReport.compiler_version = $mathReport.compiler_version
    $codegenReport.environment = $mathReport.environment
    $compilerArguments = @((Join-Path $PSScriptRoot 'probe.rs'), '--crate-name', 'cts_alpha_codegen', '--crate-type', 'lib', '--edition=2024', '--cfg', 'frame_audit', '--cfg', 'primitive_audit', '-C', 'opt-level=2', '-C', 'overflow-checks=yes', '-C', 'panic=abort', '-C', 'debuginfo=0', '--emit=asm', '-o', $assemblyPath)
    if ($Execute) {
        [void](New-Item -ItemType Directory -Path $outputPath)
        $codegenReport.compile_calls = 1
        $codegenReport.record = Compile-Assembly $compilerArguments
        Save-Report
        if ($codegenReport.record.error -or $codegenReport.record.exit_code -ne 0) { throw 'assembly compile失敗（再試行なし）' }
        $assembly = File-Identity $assemblyPath
        if ($assembly.bytes -eq 0 -or $assembly.bytes -gt 524288) { throw 'assembly件数/容量不一致' }
        $codegenReport.assembly = $assembly
        $files = @(Get-ChildItem -LiteralPath $outputPath -Force)
        if ($files.Count -ne 2 -or @($files | Where-Object { $_.PSIsContainer -or $_.Name -notin @('baseline.s', 'report.json') }).Count) { throw '出力rootに予定外のファイルがあります' }
    }
    $current = @($sources | ForEach-Object { File-Identity $_.path })
    for ($index = 0; $index -lt $sources.Count; $index++) {
        if (!(Same-Identity $sources[$index] $current[$index])) { throw "source前後不一致: $($sources[$index].path)" }
    }
    $codegenReport.sources_after = $current
    $codegenReport.sources_unchanged = $true
    $codegenReport.status = if ($Execute) { 'passed-codegen-only' } else { 'passed-nonexecute' }
    $codegenReport.ended_utc = [DateTime]::UtcNow.ToString('o')
    if ($Execute) {
        $codegenReport.disk_after = & (Join-Path $experimentPath 'disk-budget.ps1') -WorkDirectory $outputPath -MaxRunMiB 1 -MinFreeGiB 5
        Save-Report
        $finalDisk = & (Join-Path $experimentPath 'disk-budget.ps1') -WorkDirectory $outputPath -MaxRunMiB 1 -MinFreeGiB 5
        $finalDisk | ConvertTo-Json -Compress
    }
    [pscustomobject]@{ status = $codegenReport.status; sources = $sources.Count; compile_calls = $codegenReport.compile_calls; output_created = [bool]$Execute; report_path = if ($Execute) { $reportPath } else { $null } } | ConvertTo-Json -Compress
} catch {
    $codegenReport.status = 'failed'; $codegenReport.error = $_.Exception.Message
    $codegenReport.ended_utc = [DateTime]::UtcNow.ToString('o')
    if ($Execute -and (Test-Path -LiteralPath $outputPath -PathType Container)) { Save-Report }
    throw
} finally {
    foreach ($sourceLock in $sourceLocks) { $sourceLock.Dispose() }
}
