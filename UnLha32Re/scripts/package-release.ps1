#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Configuration = 'Release',
    [string]$OutputDirectory = '',
    [string]$TestReport = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
$versionFile = Join-Path $repositoryRoot 'VERSION'

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

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
    try {
        if (!$process.Start()) {
            throw "プロセスを開始できませんでした: $FilePath"
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "$FilePath が失敗しました (exit $($process.ExitCode)): $($standardError.Trim())"
        }
        return [pscustomobject]@{
            StandardOutput = $standardOutput
            StandardError = $standardError
        }
    } finally {
        $process.Dispose()
    }
}

$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = $gitCommand.Source

function Assert-ReleaseTestReport {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$ExpectedGitHead
    )

    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "リリース試験レポートが見つかりません: $Path"
    }
    try {
        $report = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "リリース試験レポートを読み取れません: $Path ($($_.Exception.Message))"
    }
    if ($report.SchemaVersion -ne 1) {
        throw "リリース試験レポートの SchemaVersion が未対応です: $($report.SchemaVersion)"
    }
    if ($report.Profile -cne 'Release' -or $report.Status -cne 'passed') {
        throw "成功した Release 試験レポートではありません: Profile=$($report.Profile), Status=$($report.Status)"
    }
    $checks = @($report.Checks)
    if ($checks.Count -ne 12 -or @($checks | Where-Object Status -cne 'passed').Count -ne 0) {
        throw "リリース試験の12チェックがすべて成功していません: count=$($checks.Count)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$report.CandidatePath) -or
        ![IO.Path]::IsPathFullyQualified([string]$report.CandidatePath)) {
        throw 'リリース試験レポートの CandidatePath が絶対パスではありません。'
    }
    $reportedCandidate = [IO.Path]::GetFullPath([string]$report.CandidatePath)
    if (![string]::Equals($reportedCandidate, $Candidate, [StringComparison]::OrdinalIgnoreCase)) {
        throw "試験済み DLL が配布対象と一致しません: $reportedCandidate"
    }
    $dllHash = (Get-FileHash -LiteralPath $Candidate -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$report.CandidateSha256 -cnotmatch '^[0-9a-fA-F]{64}$' -or
        ![string]::Equals([string]$report.CandidateSha256, $dllHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw '配布対象 DLL はリリース試験後に変更されています。'
    }
    if ([string]$report.GitHead -cne $ExpectedGitHead) {
        throw "リリース試験レポートの Git HEAD が現在の HEAD と一致しません: $($report.GitHead)"
    }
    return [pscustomobject]@{ Report = $report; DllHash = $dllHash }
}

$trackedStatus = Invoke-CapturedProcess -FilePath $gitPath -ArgumentList @(
    '-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=no'
)
if (![string]::IsNullOrWhiteSpace($trackedStatus.StandardOutput)) {
    throw '追跡済みファイルに未コミットの差分があります。配布物はクリーンな Git HEAD から作成してください。'
}

if (!$Version) {
    $Version = [IO.File]::ReadAllText($versionFile).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "配布バージョンが SemVer ではありません: $Version"
}
if ([IO.File]::ReadAllText($versionFile).Trim() -cne $Version) {
    throw 'VERSION と指定された配布バージョンが一致しません。'
}

$dll = Join-Path $projectRoot "artifacts\$Configuration\UNLHA32RE.dll"
if (!(Test-Path -LiteralPath $dll)) {
    throw "配布対象 DLL が見つかりません: $dll"
}
$dll = [IO.Path]::GetFullPath($dll)
$dllVersion = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
if ($dllVersion -ne '3.00.0.5') {
    throw "互換バージョンが不正です: $dllVersion"
}

if (!$TestReport) {
    $TestReport = Join-Path $projectRoot "artifacts\$Configuration\release-test.json"
}
$TestReport = [IO.Path]::GetFullPath($TestReport)
$gitHeadResult = Invoke-CapturedProcess -FilePath $gitPath -ArgumentList @(
    '-C', $repositoryRoot, 'rev-parse', '--verify', 'HEAD'
)
$gitHead = $gitHeadResult.StandardOutput.Trim()
$validation = Assert-ReleaseTestReport -Path $TestReport -Candidate $dll -ExpectedGitHead $gitHead
$dllHash = $validation.DllHash

$signature = Get-AuthenticodeSignature -LiteralPath $dll
if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
    throw "DLL の Authenticode 署名が有効ではありません: $($signature.Status)"
}

if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot "artifacts\releases\$Version"
}
$OutputDirectory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($OutputDirectory))
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "既存の出力ディレクトリを上書きしません。新しい出力先を指定してください: $OutputDirectory"
}
$outputParent = [IO.Path]::GetDirectoryName($OutputDirectory)
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "出力先の親ディレクトリを解決できません: $OutputDirectory"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
$zip = Join-Path $OutputDirectory 'UnLha32Re-win-x86.zip'
$checksum = "$zip.sha256"
$stagingDirectory = Join-Path $outputParent ('.partial-{0}' -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stagingDirectory) | Out-Null
$stagingZip = Join-Path $stagingDirectory 'UnLha32Re-win-x86.zip'
$stagingChecksum = Join-Path $stagingDirectory 'UnLha32Re-win-x86.zip.sha256'

$prefix = "UnLha32Re-$Version"
Invoke-CapturedProcess -FilePath $gitPath -ArgumentList @(
    '-C', $repositoryRoot, 'archive', '--format=zip', "--prefix=$prefix/source/", "--output=$stagingZip", $gitHead
) | Out-Null

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($stagingZip, [IO.Compression.ZipArchiveMode]::Update)
try {
    function Add-ReleaseFile([string]$Source, [string]$EntryName) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $Source, $EntryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }

    Add-ReleaseFile $dll "$prefix/bin/UNLHA32RE.DLL"
    Add-ReleaseFile (Join-Path $repositoryRoot 'LICENSE') "$prefix/LICENSE"
    Add-ReleaseFile (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') "$prefix/THIRD_PARTY_NOTICES.md"
    Add-ReleaseFile (Join-Path $repositoryRoot 'README.md') "$prefix/README.md"
    Add-ReleaseFile (Join-Path $projectRoot 'README.md') "$prefix/COMPATIBILITY.md"

    $readme = @"
UnLha32Re $Version

UNLHA32.DLL 3.00.0.5 互換を目指す 32 ビット (x86) Windows DLL です。

導入:
1. bin\UNLHA32RE.DLL を対象となる 32 ビットアプリの実行ファイルと同じフォルダーへ配置します。
2. アプリが従来名を固定して読み込む場合は、UNLHA32.DLL へ名前を変更します。
3. System32 や SysWOW64 には配置しないでください。

互換範囲と既知の差異は COMPATIBILITY.md、再配布条件は
THIRD_PARTY_NOTICES.md、対応ソースは source\ を確認してください。
"@
    $readmeEntry = $archive.CreateEntry("$prefix/README.txt")
    $writer = [IO.StreamWriter]::new($readmeEntry.Open(), [Text.UTF8Encoding]::new($true))
    try {
        $windowsReadme = $readme.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
        $writer.Write($windowsReadme)
    } finally { $writer.Dispose() }

    $hashEntry = $archive.CreateEntry("$prefix/SHA256SUMS.txt")
    $writer = [IO.StreamWriter]::new($hashEntry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write("$dllHash  bin/UNLHA32RE.DLL`r`n") } finally { $writer.Dispose() }
} finally {
    $archive.Dispose()
}

$verificationArchive = [IO.Compression.ZipFile]::OpenRead($stagingZip)
try {
    $dllEntry = $verificationArchive.GetEntry("$prefix/bin/UNLHA32RE.DLL")
    if ($null -eq $dllEntry) { throw 'staging ZIP に配布対象 DLL がありません。' }
    $entryStream = $dllEntry.Open()
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $archivedDllHash = [Convert]::ToHexString($sha256.ComputeHash($entryStream)).ToLowerInvariant()
    } finally {
        $sha256.Dispose()
        $entryStream.Dispose()
    }
    if ($archivedDllHash -cne $dllHash) {
        throw 'staging ZIP 内の DLL が試験済み DLL と一致しません。'
    }
} finally {
    $verificationArchive.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $stagingZip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(
    $stagingChecksum,
    "$zipHash  $([IO.Path]::GetFileName($zip))`r`n",
    [Text.UTF8Encoding]::new($false))

$finalStatus = Invoke-CapturedProcess -FilePath $gitPath -ArgumentList @(
    '-C', $repositoryRoot, 'status', '--porcelain=v1', '--untracked-files=no'
)
if (![string]::IsNullOrWhiteSpace($finalStatus.StandardOutput)) {
    throw 'ZIP作成中に追跡済みファイルが変更されました。'
}
$finalHead = (Invoke-CapturedProcess -FilePath $gitPath -ArgumentList @(
    '-C', $repositoryRoot, 'rev-parse', '--verify', 'HEAD'
)).StandardOutput.Trim()
if ($finalHead -cne $gitHead) {
    throw "ZIP作成中に Git HEAD が変更されました: $gitHead -> $finalHead"
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "既存の出力ディレクトリを上書きしません: $OutputDirectory"
}

# ZIPとチェックサムを同じディレクトリの1回のrenameで確定し、部分的な正式配布物を残さない。
[IO.Directory]::Move($stagingDirectory, $OutputDirectory)
Write-Host "Package: $zip"
Write-Host "SHA256: $zipHash"
