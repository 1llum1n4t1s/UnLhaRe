#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$CaptureReportPath,
    [Parameter(Mandatory)][string]$AnalysisReportPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)
# 完了済みcaptureを入力とする、解析CLIの拒否契約E2E。新しい録画・圧縮は行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'capture-proof.ps1')
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build')) + [IO.Path]::DirectorySeparatorChar
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
$analyzer = Join-Path $PSScriptRoot 'analyze-cpu.ps1'
$pwsh = (Get-Process -Id $PID).Path
$capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
$analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
$binary = @($capture.provenance | Where-Object role -ceq 'current-release-binary')[0].path
$pdb = @($capture.provenance | Where-Object role -ceq 'matching-release-pdb')[0].path
$identities = @($capturePath, $analysisPath, $analyzer, $PSCommandPath, (Join-Path $PSScriptRoot 'capture-proof.ps1'), $binary, $pdb, $capture.trace.path) | ForEach-Object {
    [pscustomobject]@{ path = $_; before_sha256 = (Get-FileHash -LiteralPath $_).Hash; after_sha256 = $null }
}
$checks = [Collections.Generic.List[object]]::new()
$errorText = $null
try {
    if ($analysis.status -cne 'fresh_cpu_source_attribution_verified' -or $analysis.project_source_samples -le 0 -or $analysis.sample_total -le 0 -or $analysis.module_samples -le 0 -or $analysis.module_samples -gt $analysis.sample_total -or $analysis.events_lost -ne 0 -or $analysis.stack_statistics.matched_samples -ne $analysis.sample_total -or $analysis.stack_statistics.missing_samples -ne 0 -or $analysis.stack_statistics.duplicate_sample_keys -ne 0 -or @($analysis.per_pid).Count -ne 1) { throw 'Expected verified fixed capture analysis.' }
    $analyzerRecord = @($analysis.provenance | Where-Object role -ceq 'analyzer')
    if ($analyzerRecord.Count -ne 1 -or $analyzerRecord[0].before_sha256 -cne (Get-FileHash -LiteralPath $analyzer).Hash -or $analyzerRecord[0].after_sha256 -cne $analyzerRecord[0].before_sha256) { throw 'Positive analysis source mismatch.' }
    $checks.Add([ordered]@{ name = 'positive-real-etl-full-stack'; passed = $true; report = $analysisPath; report_sha256 = (Get-FileHash -LiteralPath $analysisPath).Hash })
    foreach ($run in @($capture.normal_e2e.warmup) + @($capture.encode_runs)) { Assert-CodecReceipt $run 'encode' }
    Assert-CodecReceipt $capture.decode.invocation 'decode'
    $checks.Add([ordered]@{ name='codec-stdout-json-receipts'; passed=$true; count=3; source_sha256=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'capture-proof.ps1')).Hash })
    $idle = @(& C:/Windows/System32/wpr.exe -status)
    if ($LASTEXITCODE -ne 0 -or ($idle -join "`n") -notmatch '(?im)^\s*WPR is not recording\.?\s*$') { throw 'Post-capture WPR idle not verified.' }
    $checks.Add([ordered]@{ name='post-capture-idle-receipt'; passed=$true; program='C:/Windows/System32/wpr.exe'; argv=@('-status'); exit_code=$LASTEXITCODE; stdout=$idle; observed_utc=[DateTime]::UtcNow.ToString('o'); at_capture_stop_observed_by_this_test=$false })
    $cases = @(
        @{ name = 'existing-work-no-clobber'; reason = 'Fresh directory below build required.' },
        @{ name = 'unverified-capture'; reason = 'Unverified capture report.' },
        @{ name = 'wrong-binary-identity'; reason = 'Analyzed pair differs from captured pair.' },
        @{ name = 'wrong-etl-identity'; reason = 'ETL identity mismatch.' },
        @{ name = 'invalid-target-pids'; reason = 'Invalid target PID set.' },
        @{ name = 'invalid-codec-stdout'; reason = 'Codec stdout JSON mismatch.' },
        @{ name = 'minimal-pdb-without-source'; reason = 'Source attribution unavailable.' },
        @{ name = 'invalid-time-window'; reason = 'Invalid captured process window.' }
    )
    foreach ($case in $cases) {
        $fixture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json
        if ($case.name -ceq 'minimal-pdb-without-source') {
            $minimalPath = Join-Path $build 'khc-bwt-causal-bayes-cpu-elevated-20260930/report.json'
            $fixture = Get-Content -LiteralPath $minimalPath -Raw | ConvertFrom-Json
            foreach ($path in @($minimalPath, $fixture.trace.path) + @($fixture.provenance | Where-Object { $_.role -in @('current-release-binary','matching-release-pdb') } | ForEach-Object path)) {
                $identities += [pscustomobject]@{ path=$path; before_sha256=(Get-FileHash -LiteralPath $path).Hash; after_sha256=$null }
            }
        }
        switch ($case.name) {
            'unverified-capture' { $fixture.status = 'failed' }
            'wrong-binary-identity' { @($fixture.provenance | Where-Object role -ceq 'current-release-binary')[0].before_sha256 = '0' * 64 }
            'wrong-etl-identity' { $fixture.trace.sha256 = '0' * 64 }
            'invalid-target-pids' { $fixture.recording.target_pids = @(0) }
            'invalid-codec-stdout' { $fixture.encode_runs[0].stdout = '{"operation":"encode"}' }
            'invalid-time-window' { $fixture.encode_runs[0].end_utc = $fixture.encode_runs[0].start_utc }
        }
        $fixturePath = Join-Path $work ($case.name + '.json')
        New-Json $fixturePath $fixture
        $caseWork = if ($case.name -ceq 'existing-work-no-clobber') { [IO.Path]::GetDirectoryName($analysisPath) } else { Join-Path $work $case.name }
        $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $caseBinary = @($fixture.provenance | Where-Object role -ceq 'current-release-binary')[0].path
        $casePdb = @($fixture.provenance | Where-Object role -ceq 'matching-release-pdb')[0].path
        foreach ($arg in @('-NoProfile', '-File', $analyzer, '-CaptureReportPath', $fixturePath, '-BinaryPath', $caseBinary, '-PdbPath', $casePdb, '-WorkDirectory', $caseWork)) { $info.ArgumentList.Add($arg) }
        if ($case.name -ceq 'minimal-pdb-without-source') { $info.ArgumentList.Add('-RequireSourceAttribution') }
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
