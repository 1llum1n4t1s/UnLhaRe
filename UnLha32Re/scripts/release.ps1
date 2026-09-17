#requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [string]$CertificateThumbprint = '',
    [string]$WorkspaceRoot = '',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$budgetSeconds = 300
$monitorReserveSeconds = 150
$maximumTestTimeoutSeconds = 90
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
$candidate = [IO.Path]::GetFullPath((Join-Path $projectRoot 'artifacts\Release\UNLHA32RE.dll'))
$versionFile = Join-Path $repositoryRoot 'VERSION'
$buildScript = Join-Path $PSScriptRoot 'build.ps1'
$signScript = Join-Path $PSScriptRoot 'sign-release.ps1'
$testScript = Join-Path $PSScriptRoot 'test-release.ps1'
$packageScript = Join-Path $PSScriptRoot 'package-release.ps1'
$pwshPath = (Get-Process -Id $PID).Path
$clock = [Diagnostics.Stopwatch]::StartNew()
$startedAtUtc = [DateTime]::UtcNow
$stageRecords = [Collections.Generic.List[object]]::new()
$plannedStages = @('Build', 'Sign', 'SmokeTest', 'Package')
$failure = $null
$budgetExceeded = $false
$testTimeoutSeconds = $null
$dwmMonitorRoot = $null
$packagePath = $null
$initialGitHead = $null
$releaseLock = $null

if (!$WorkspaceRoot) {
    $WorkspaceRoot = Join-Path $projectRoot 'build\release-runs'
}
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
[IO.Directory]::CreateDirectory($WorkspaceRoot) | Out-Null
do {
    $runDirectory = Join-Path $WorkspaceRoot ("run-{0}" -f [Guid]::NewGuid().ToString('N'))
} while (Test-Path -LiteralPath $runDirectory)
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$smokeWorkspace = Join-Path $runDirectory 'smoke'
$testReport = Join-Path $runDirectory 'test-report.json'
$releaseReport = Join-Path $runDirectory 'release-report.json'

function Get-RemainingSeconds {
    return [Math]::Max(0.0, $budgetSeconds - $clock.Elapsed.TotalSeconds)
}

function Write-ProcessLog {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string]$StandardOutput = '',
        [string]$StandardError = '',
        [Nullable[int]]$ExitCode = $null,
        [bool]$TimedOut = $false
    )

    $exitText = if ($null -eq $ExitCode) { '<not available>' } else { [string]$ExitCode }
    $text = @"
TimedOut: $TimedOut
ExitCode: $exitText

===== standard output =====
$StandardOutput
===== standard error =====
$StandardError
"@
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Invoke-BudgetedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter(Mandatory)]
        [double]$TimeoutSeconds
    )

    if ($TimeoutSeconds -le 0) {
        throw "プロセスを開始する残り時間がありません: $FilePath"
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $standardOutput = ''
    $standardError = ''
    $timedOut = $false
    $exitCode = $null
    $streamsCollected = $false
    try {
        if (!$process.Start()) {
            throw "プロセスを開始できませんでした: $FilePath"
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [Math]::Max(
            1,
            [Math]::Min([int]::MaxValue, [Math]::Floor($TimeoutSeconds * 1000.0)))
        if (!$process.WaitForExit([int]$timeoutMilliseconds)) {
            $timedOut = $true
            try {
                $process.Kill($true)
            } catch {
                throw "タイムアウトしたプロセスツリーを終了できませんでした: $FilePath ($($_.Exception.Message))"
            }
            if (!$process.WaitForExit(10000)) {
                throw "終了したプロセスを10秒以内に回収できませんでした: $FilePath"
            }
        }
        $streamDeadline = [DateTime]::UtcNow.AddSeconds(5)
        while ((!$standardOutputTask.IsCompleted -or !$standardErrorTask.IsCompleted) -and
            [DateTime]::UtcNow -lt $streamDeadline) {
            [Threading.Thread]::Sleep(25)
        }
        if (!$standardOutputTask.IsCompleted -or !$standardErrorTask.IsCompleted) {
            throw "子プロセスの出力を5秒以内に回収できませんでした: $FilePath"
        }
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $streamsCollected = $true
        $exitCode = $process.ExitCode
    } catch {
        if (!$streamsCollected) {
            if ($null -ne $standardOutputTask -and $standardOutputTask.IsCompletedSuccessfully) {
                $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
            }
            if ($null -ne $standardErrorTask -and $standardErrorTask.IsCompletedSuccessfully) {
                $standardError = $standardErrorTask.GetAwaiter().GetResult()
            }
        }
        Write-ProcessLog -Path $LogPath -StandardOutput $standardOutput `
            -StandardError ($standardError + $_.Exception.Message) -ExitCode $exitCode -TimedOut $timedOut
        throw
    } finally {
        $process.Dispose()
    }

    Write-ProcessLog -Path $LogPath -StandardOutput $standardOutput -StandardError $standardError `
        -ExitCode $exitCode -TimedOut $timedOut
    if ($timedOut) {
        throw "制限時間を超えたためプロセスツリーを終了しました: $FilePath"
    }
    if ($exitCode -ne 0) {
        throw "$FilePath が失敗しました (exit $exitCode)。ログ: $LogPath"
    }
    return [pscustomobject]@{
        StandardOutput = $standardOutput
        StandardError = $standardError
        ExitCode = $exitCode
    }
}

function Invoke-ReleaseStage {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $stageClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $stageClock.Stop()
        $stageRecords.Add([pscustomobject]@{
            Name = $Name
            Status = 'passed'
            ElapsedSeconds = [Math]::Round($stageClock.Elapsed.TotalSeconds, 3)
            Reason = $null
        })
    } catch {
        $stageClock.Stop()
        $stageRecords.Add([pscustomobject]@{
            Name = $Name
            Status = 'failed'
            ElapsedSeconds = [Math]::Round($stageClock.Elapsed.TotalSeconds, 3)
            Reason = $_.Exception.Message
        })
        throw
    }
}

function Assert-VersionUnchanged {
    param([string]$ExpectedHash)

    $actualHash = (Get-FileHash -LiteralPath $versionFile -Algorithm SHA256).Hash
    if ($actualHash -cne $ExpectedHash) {
        throw 'リリース準備中に VERSION が変更されました。'
    }
}

function Get-RepositoryHead {
    param([Parameter(Mandatory)][string]$LogName)

    $result = Invoke-BudgetedProcess -FilePath $gitPath -ArgumentList @(
        '-C', $repositoryRoot, 'rev-parse', '--verify', 'HEAD'
    ) -LogPath (Join-Path $runDirectory $LogName) `
      -TimeoutSeconds ([Math]::Min(10.0, (Get-RemainingSeconds)))
    $head = $result.StandardOutput.Trim()
    if ($head -notmatch '^[0-9a-fA-F]{40,64}$') {
        throw "Git HEAD を取得できませんでした: $head"
    }
    return $head
}

function Assert-RepositoryState {
    param(
        [Parameter(Mandatory)][string]$Label,
        [switch]$RequireClean
    )

    $head = Get-RepositoryHead -LogName "git-head-$Label.log"
    if ($head -cne $initialGitHead) {
        throw "リリース準備中に Git HEAD が変更されました: $initialGitHead -> $head"
    }
    if ($RequireClean) {
        $status = Invoke-BudgetedProcess -FilePath $gitPath -ArgumentList @(
            '-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=no'
        ) -LogPath (Join-Path $runDirectory "git-status-$Label.log") `
          -TimeoutSeconds ([Math]::Min(10.0, (Get-RemainingSeconds)))
        if (![string]::IsNullOrWhiteSpace($status.StandardOutput)) {
            throw "リリース準備中に追跡済みファイルが変更されました ($Label)。"
        }
    }
}

function Assert-ReleaseTestReport {
    if (!(Test-Path -LiteralPath $testReport -PathType Leaf)) {
        throw "リリース試験レポートが作成されませんでした: $testReport"
    }
    try {
        $smokeReport = [IO.File]::ReadAllText($testReport) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "リリース試験レポートを読み取れません: $($_.Exception.Message)"
    }
    if ($smokeReport.SchemaVersion -ne 1 -or $smokeReport.Profile -cne 'Release' -or
        $smokeReport.Status -cne 'passed') {
        throw "成功した Release 試験レポートではありません: Status=$($smokeReport.Status)"
    }
    if ($null -eq $smokeReport.Checks -or @($smokeReport.Checks).Count -eq 0) {
        throw 'リリース試験レポートにチェックがありません。'
    }
    $checks = @($smokeReport.Checks)
    if ($checks.Count -ne 12 -or @($checks | Where-Object Status -cne 'passed').Count -ne 0) {
        throw "リリース試験の12チェックがすべて成功していません: count=$($checks.Count)"
    }
    $script:dwmMonitorRoot = [string]$smokeReport.DwmMonitorRoot
    if ([string]::IsNullOrWhiteSpace([string]$smokeReport.CandidatePath) -or
        ![IO.Path]::IsPathFullyQualified([string]$smokeReport.CandidatePath)) {
        throw 'リリース試験レポートの CandidatePath が絶対パスではありません。'
    }
    $reportedCandidate = [IO.Path]::GetFullPath([string]$smokeReport.CandidatePath)
    if (![string]::Equals($reportedCandidate, $candidate, [StringComparison]::OrdinalIgnoreCase)) {
        throw "リリース試験レポートの候補 DLL が一致しません: $reportedCandidate"
    }
    $candidateHash = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
    if (![string]::Equals([string]$smokeReport.CandidateSha256, $candidateHash,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'リリース試験後に候補 DLL が変更されています。'
    }
    if ([string]$smokeReport.GitHead -cne $initialGitHead) {
        throw "リリース試験レポートの Git HEAD が一致しません: $($smokeReport.GitHead)"
    }
}

try {
    $lockDirectory = Join-Path $projectRoot 'artifacts'
    [IO.Directory]::CreateDirectory($lockDirectory) | Out-Null
    try {
        $releaseLock = [IO.File]::Open(
            (Join-Path $lockDirectory 'release.lock'),
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
    } catch {
        throw '別のリリース準備が同じ成果物を使用中です。'
    }

    foreach ($requiredScript in @($buildScript, $signScript, $testScript, $packageScript)) {
        if (!(Test-Path -LiteralPath $requiredScript -PathType Leaf)) {
            throw "必要なスクリプトが見つかりません: $requiredScript"
        }
    }

    $version = [IO.File]::ReadAllText($versionFile).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') {
        throw "VERSION が SemVer ではありません: $version"
    }
    $initialVersionHash = (Get-FileHash -LiteralPath $versionFile -Algorithm SHA256).Hash

    $gitPath = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $initialGitHead = Get-RepositoryHead -LogName 'git-head-initial.log'
    if (!$CheckOnly) {
        $gitCheck = Invoke-BudgetedProcess -FilePath $gitPath -ArgumentList @(
            '-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=no'
        ) -LogPath (Join-Path $runDirectory 'preflight-git.log') `
          -TimeoutSeconds ([Math]::Min(10.0, (Get-RemainingSeconds)))
        if (![string]::IsNullOrWhiteSpace($gitCheck.StandardOutput)) {
            throw '追跡済みファイルに未コミットの差分があります。通常リリースはクリーンな Git HEAD から実行してください。'
        }
    }

    Invoke-ReleaseStage -Name 'Build' -Action {
        Invoke-BudgetedProcess -FilePath $pwshPath -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $buildScript, '-Configuration', 'Release'
        ) -LogPath (Join-Path $runDirectory 'build.log') -TimeoutSeconds (Get-RemainingSeconds)
    }
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Release DLL が見つかりません: $candidate"
    }
    Assert-RepositoryState -Label 'after-build' -RequireClean:(!$CheckOnly)

    if (!$CheckOnly) {
        Invoke-ReleaseStage -Name 'Sign' -Action {
            Assert-VersionUnchanged -ExpectedHash $initialVersionHash
            $signArguments = @(
                '-NoProfile', '-NonInteractive', '-File', $signScript, '-Candidate', $candidate
            )
            if ($CertificateThumbprint) {
                $signArguments += @('-CertificateThumbprint', $CertificateThumbprint)
            }
            Invoke-BudgetedProcess -FilePath $pwshPath -ArgumentList $signArguments `
                -LogPath (Join-Path $runDirectory 'sign.log') -TimeoutSeconds (Get-RemainingSeconds) | Out-Null
        }
        Assert-RepositoryState -Label 'after-sign' -RequireClean
    }

    Invoke-ReleaseStage -Name 'SmokeTest' -Action {
        $remaining = Get-RemainingSeconds
        $script:testTimeoutSeconds = [Math]::Min(
            $maximumTestTimeoutSeconds,
            [Math]::Floor($remaining - $monitorReserveSeconds))
        if ($script:testTimeoutSeconds -lt 1) {
            throw "DWM 監視の開始・清掃用に $monitorReserveSeconds 秒を予約できません。"
        }
        $testLog = Join-Path $runDirectory 'test-release.log'
        & $testScript -SkipBuild -Candidate $candidate -WorkspaceRoot $smokeWorkspace `
            -ReportPath $testReport -TimeoutSeconds $script:testTimeoutSeconds 2>&1 |
            Tee-Object -LiteralPath $testLog | Out-Host
        Assert-ReleaseTestReport
        if ($clock.Elapsed.TotalSeconds -gt $budgetSeconds) {
            throw "リリース準備の300秒予算を超過しました: $([Math]::Round($clock.Elapsed.TotalSeconds, 3)) 秒"
        }
    }
    Assert-RepositoryState -Label 'after-test' -RequireClean:(!$CheckOnly)

    if (!$CheckOnly) {
        Assert-VersionUnchanged -ExpectedHash $initialVersionHash
        Assert-RepositoryState -Label 'before-package' -RequireClean
        Invoke-ReleaseStage -Name 'Package' -Action {
            $packageArguments = @(
                '-NoProfile', '-NonInteractive', '-File', $packageScript,
                '-Version', $version, '-Configuration', 'Release', '-TestReport', $testReport
            )
            if ($OutputDirectory) {
                $packageArguments += @('-OutputDirectory', [IO.Path]::GetFullPath($OutputDirectory))
            }
            $packageResult = Invoke-BudgetedProcess -FilePath $pwshPath -ArgumentList $packageArguments `
                -LogPath (Join-Path $runDirectory 'package.log') -TimeoutSeconds (Get-RemainingSeconds)
            $packageLine = @($packageResult.StandardOutput -split '\r?\n' | Where-Object {
                $_ -like 'Package: *'
            }) | Select-Object -Last 1
            if ($packageLine) {
                $script:packagePath = $packageLine.Substring('Package: '.Length).Trim()
            }
        }
        Assert-VersionUnchanged -ExpectedHash $initialVersionHash
        Assert-RepositoryState -Label 'after-package' -RequireClean
    }
} catch {
    $failure = $_
} finally {
    $clock.Stop()
    $budgetExceeded = $clock.Elapsed.TotalSeconds -gt $budgetSeconds
    foreach ($stageName in $plannedStages) {
        if ($stageRecords.Name -notcontains $stageName) {
            $reason = if ($CheckOnly -and $stageName -in @('Sign', 'Package')) {
                'CheckOnly では実行しません。'
            } elseif ($failure) {
                '先行工程が失敗したため実行していません。'
            } else {
                '実行対象外です。'
            }
            $stageRecords.Add([pscustomobject]@{
                Name = $stageName
                Status = 'skipped'
                ElapsedSeconds = 0.0
                Reason = $reason
            })
        }
    }
    $orderedStages = foreach ($stageName in $plannedStages) {
        $stageRecords | Where-Object Name -eq $stageName | Select-Object -First 1
    }
    $candidateHash = if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    } else { $null }
    $unrunStages = @($orderedStages | Where-Object Status -eq 'skipped' | ForEach-Object Name)
    $report = [ordered]@{
        SchemaVersion = 1
        Status = if ($failure -or $budgetExceeded) { 'failed' } else { 'passed' }
        CheckOnly = [bool]$CheckOnly
        StartedAtUtc = $startedAtUtc.ToString('o')
        FinishedAtUtc = [DateTime]::UtcNow.ToString('o')
        ElapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
        BudgetSeconds = $budgetSeconds
        RemainingBudgetSeconds = [Math]::Round((Get-RemainingSeconds), 3)
        Version = $version
        GitHead = $initialGitHead
        RunDirectory = $runDirectory
        CandidatePath = $candidate
        CandidateSha256 = $candidateHash
        TestTimeoutSeconds = $testTimeoutSeconds
        TestReportPath = $testReport
        DwmMonitorRoot = $dwmMonitorRoot
        PackagePath = $packagePath
        Stages = @($orderedStages)
        UnrunStages = $unrunStages
        Error = if ($failure) {
            $failure.Exception.Message
        } elseif ($budgetExceeded) {
            "300秒予算を超過しました: $([Math]::Round($clock.Elapsed.TotalSeconds, 3)) 秒"
        } else { $null }
    }
    try {
        [IO.File]::WriteAllText(
            $releaseReport,
            ($report | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))
    } finally {
        if ($null -ne $releaseLock) { $releaseLock.Dispose() }
    }
}

Write-Host "Release report: $releaseReport"
if ($failure) {
    throw $failure
}
if ($budgetExceeded) {
    throw "リリース準備が300秒予算を超過しました。レポート: $releaseReport"
}
Write-Host "Release preparation completed in $([Math]::Round($clock.Elapsed.TotalSeconds, 3)) seconds."
