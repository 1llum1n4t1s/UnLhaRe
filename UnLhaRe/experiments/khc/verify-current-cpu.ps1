#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$CaptureReportPath,
    [Parameter(Mandatory)][string]$AnalysisReportPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)
# 完了済みcaptureを入力とする、解析CLIの拒否契約E2E。新しい録画・圧縮は行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)) { throw 'Fresh E2E directory below build required.' }
$ancestor = $work
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse path rejected.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$null = New-Item -ItemType Directory -Path $work
function New-Json([string]$Path, $Value) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write(($Value | ConvertTo-Json -Depth 30)) } finally { $writer.Dispose() }
}
$capturePath = [IO.Path]::GetFullPath($CaptureReportPath)
$analysisPath = [IO.Path]::GetFullPath($AnalysisReportPath)
$analyzer = Join-Path $PSScriptRoot 'analyze-current-cpu.ps1'
$pwsh = (Get-Process -Id $PID).Path
$capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
$binary = @($capture.provenance | Where-Object role -ceq 'current-release-binary')[0].path
$pdb = @($capture.provenance | Where-Object role -ceq 'matching-release-pdb')[0].path
$identities = @($capturePath, $analysisPath, $analyzer, $PSCommandPath, $binary, $pdb, $capture.trace.path) | ForEach-Object {
    [pscustomobject]@{ path = $_; before_sha256 = (Get-FileHash -LiteralPath $_).Hash; after_sha256 = $null }
}
$checks = [Collections.Generic.List[object]]::new()
$errorText = $null
try {
    if ($analysis.status -cne 'fresh_cpu_attribution_verified' -or $analysis.sample_total -ne 3199 -or $analysis.module_samples -ne 2915 -or $analysis.events_lost -ne 0 -or $analysis.stack_statistics.matched_samples -ne 3199 -or $analysis.stack_statistics.split_kernel_user_samples -ne 120 -or $analysis.unresolved_runtime_module_frames -ne 0) { throw 'Expected verified fixed capture analysis.' }
    $analyzerRecord = @($analysis.provenance | Where-Object role -ceq 'analyzer')
    if ($analyzerRecord.Count -ne 1 -or $analyzerRecord[0].before_sha256 -cne (Get-FileHash -LiteralPath $analyzer).Hash -or $analyzerRecord[0].after_sha256 -cne $analyzerRecord[0].before_sha256) { throw 'Positive analysis source mismatch.' }
    $checks.Add([ordered]@{ name = 'positive-real-etl-full-stack'; passed = $true; report = $analysisPath; report_sha256 = (Get-FileHash -LiteralPath $analysisPath).Hash })
    $cases = @(
        @{ name = 'existing-work-no-clobber'; reason = 'Fresh directory below build required.' },
        @{ name = 'unverified-capture'; reason = 'Unverified capture report.' },
        @{ name = 'wrong-binary-identity'; reason = 'Analyzed pair differs from captured pair.' },
        @{ name = 'wrong-etl-identity'; reason = 'ETL identity mismatch.' },
        @{ name = 'duplicate-pids'; reason = 'Duplicate target PIDs rejected.' },
        @{ name = 'invalid-time-window'; reason = 'Invalid captured process window.' }
    )
    foreach ($case in $cases) {
        $fixture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        switch ($case.name) {
            'unverified-capture' { $fixture.status = 'failed' }
            'wrong-binary-identity' { @($fixture.provenance | Where-Object role -ceq 'current-release-binary')[0].before_sha256 = '0' * 64 }
            'wrong-etl-identity' { $fixture.trace.sha256 = '0' * 64 }
            'duplicate-pids' { $fixture.encode_runs[1].pid = $fixture.encode_runs[0].pid }
            'invalid-time-window' { $fixture.encode_runs[0].end_utc = $fixture.encode_runs[0].start_utc }
        }
        $fixturePath = Join-Path $work ($case.name + '.json')
        New-Json $fixturePath $fixture
        $caseWork = if ($case.name -ceq 'existing-work-no-clobber') { [IO.Path]::GetDirectoryName($analysisPath) } else { Join-Path $work $case.name }
        $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($arg in @('-NoProfile', '-File', $analyzer, '-CaptureReportPath', $fixturePath, '-BinaryPath', $binary, '-PdbPath', $pdb, '-WorkDirectory', $caseWork)) { $info.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $started = $false
        try {
            $started = $process.Start(); if (-not $started) { throw 'E2E child start failed.' }
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) { throw 'E2E child deadline exceeded.' }
            $out = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -eq 0 -or ($out + $err) -notlike ('*' + $case.reason + '*')) { throw ('Wrong CLI rejection for ' + $case.name) }
            $failureReport = if ($case.name -ceq 'existing-work-no-clobber') { $null } else { Join-Path $caseWork 'report.json' }
            if ($null -ne $failureReport) {
                $failed = Get-Content -LiteralPath $failureReport -Raw | ConvertFrom-Json
                if ($failed.status -cne 'failed' -or $failed.error -notlike ('*' + $case.reason + '*')) { throw 'Failure report mismatch.' }
            }
            $checks.Add([ordered]@{ name = $case.name; passed = $true; program = $pwsh; argv = @($info.ArgumentList); exit_code = $process.ExitCode; expected_reason = $case.reason; stdout = $out; stderr = $err; failure_report = $failureReport })
        } finally { if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
    }
} catch { $errorText = $_.Exception.ToString() }
finally {
    foreach ($item in $identities) {
        $item.after_sha256 = (Get-FileHash -LiteralPath $item.path).Hash
        if ($item.before_sha256 -cne $item.after_sha256) { $errorText = 'E2E input/source was changed.' }
    }
    New-Json (Join-Path $work 'report.json') ([ordered]@{ status = $(if ($null -eq $errorText) { 'verified' } else { 'failed' }); error = $errorText; checks = $checks.ToArray(); identities = $identities; new_capture_or_codec_execution = $false; completed_utc = [DateTime]::UtcNow.ToString('o') })
}
if ($null -ne $errorText) { throw $errorText }
Write-Host "CPU analysis CLI E2E verified: $($checks.Count) checks."
