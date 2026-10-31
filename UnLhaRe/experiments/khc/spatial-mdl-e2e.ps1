#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$InputRecoveryZip,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$KhcExecutableSha256,
    [Parameter(Mandatory)][string]$E2eExecutable,
    [Parameter(Mandatory)][string]$E2eExecutableSha256,
    [ValidateRange(30,270)][int]$ChildTimeoutSeconds = 240
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory

$expectedZip = 'D:\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
$expectedZipSha256 = '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'
$expectedMember = 'input/ptt5'
$expectedMemberBytes = 513216
$expectedMemberSha256 = '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
$expectedRunBytes = 8MB
$expectedEntries = 96
$recordPath = [IO.Path]::GetFullPath($env:KHC_STORAGE_RUN_RECORD)
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if ([long]$record.max_bytes -ne $expectedRunBytes -or [int]$record.max_entries -ne $expectedEntries) {
    throw 'SpatialMdl/revision-10 portfolio E2E requires the fixed 8MiB / 96-entry storage registration.'
}

function Plain([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if ((Test-Path -LiteralPath $current) -and
            (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse point in E2E path: $current"
        }
    }
    return $full
}

$work = Plain $WorkDirectory
$zipPath = Plain $InputRecoveryZip
$cli = Plain $KhcExecutable
$e2e = Plain $E2eExecutable
$taskPaths = Get-KhcStorageTaskPaths
$expectedCli = [IO.Path]::GetFullPath((Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc\release\unlhare-cli.exe'))
$expectedE2e = [IO.Path]::GetFullPath((Join-Path $taskPaths.CargoTargetRoot 'x86_64-pc-windows-msvc\release\examples\khc_spatial_mdl_e2e.exe'))
if ($work -ne [IO.Path]::GetFullPath($WorkDirectory) -or (Test-Path -LiteralPath $work)) {
    throw 'Registered WorkDirectory must be a new plain path.'
}
if ($zipPath -cne [IO.Path]::GetFullPath($expectedZip) -or
    $KhcExecutable -cne $expectedCli -or $E2eExecutable -cne $expectedE2e) {
    throw 'Use the preregistered recovery fixture and D-drive Cargo binaries.'
}
foreach ($hash in @($KhcExecutableSha256, $E2eExecutableSha256)) {
    if ($hash -cnotmatch '^[0-9a-f]{64}$') { throw 'Executable SHA-256 pins must be lowercase 64-digit hex.' }
}
foreach ($file in @($zipPath, $cli, $e2e)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing pinned input: $file" }
}
if ((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedZipSha256) {
    throw 'Pinned recovery ZIP SHA-256 mismatch.'
}
if ((Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash.ToLowerInvariant() -cne $KhcExecutableSha256 -or
    (Get-FileHash -LiteralPath $e2e -Algorithm SHA256).Hash.ToLowerInvariant() -cne $E2eExecutableSha256) {
    throw 'Pre-registered Release executable SHA-256 mismatch.'
}

$null = New-Item -ItemType Directory -Path $work
$inputDirectory = Join-Path $work 'input'
$null = New-Item -ItemType Directory -Path $inputDirectory
$ptt5Path = Join-Path $inputDirectory 'ptt5'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $members = @($zip.Entries | Where-Object { $_.FullName -ceq $expectedMember })
    if ($members.Count -ne 1 -or $members[0].Length -ne $expectedMemberBytes) {
        throw 'Pinned ptt5 recovery member is missing, duplicated, or has an unexpected size.'
    }
    $source = $members[0].Open()
    try {
        $destination = [IO.FileStream]::new($ptt5Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $source.CopyTo($destination) }
        finally { $destination.Dispose() }
    }
    finally { $source.Dispose() }
}
finally { $zip.Dispose() }
if ((Get-FileHash -LiteralPath $ptt5Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expectedMemberSha256) {
    throw 'Pinned ptt5 member SHA-256 mismatch.'
}

$script:checks = [Collections.Generic.List[object]]::new()
function Child([string]$File, [string[]]$Arguments, [string]$Name, [bool]$Success = $true) {
    $info = [Diagnostics.ProcessStartInfo]::new($File)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $work
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['TMP'] = $work
    $info.Environment['TEMP'] = $work
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw "Child start failed: $Name" }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(100)) {
            if ($timer.Elapsed.TotalSeconds -gt $ChildTimeoutSeconds) {
                $process.Kill($true)
                $process.WaitForExit()
                throw "$Name exceeded its child timeout."
            }
        }
        $process.WaitForExit()
        $out = $stdout.GetAwaiter().GetResult()
        $err = $stderr.GetAwaiter().GetResult()
        if ($out.Length + $err.Length -gt 32768) { throw "$Name output exceeded 32KiB." }
        $script:checks.Add([ordered]@{ name = $Name; exit_code = $process.ExitCode; stdout = $out; stderr = $err })
        if (($process.ExitCode -eq 0) -ne $Success) { throw "$Name had unexpected exit $($process.ExitCode): $err" }
        return $out
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}

$api = Join-Path $work 'api'
$null = Child $e2e @($api, $ptt5Path) 'api-revision-10-e2e'
$apiSourceDirectory = Join-Path $api 'source'
$sourceDirectory = Join-Path $work 'cli-source'
$null = New-Item -ItemType Directory -Path $sourceDirectory
[IO.File]::Copy($ptt5Path, (Join-Path $sourceDirectory 'ptt5.bin'), $false)
[IO.File]::Copy((Join-Path $apiSourceDirectory 'short.bin'), (Join-Path $sourceDirectory 'short.bin'), $false)
$archive = Join-Path $work 'cli-revision-10.khc'
$output = Join-Path $work 'cli-output'
$null = Child $cli @('khc-create', $archive, '--source', $sourceDirectory, '--strategy', 'portfolio-trial') 'cli-create'
$archiveBytes = [IO.File]::ReadAllBytes($archive)
if ($archiveBytes.Length -lt 40 -or [Text.Encoding]::ASCII.GetString($archiveBytes, 0, 8) -cne "KHC1ARC`0" -or $archiveBytes[8] -ne 10) {
    throw 'CLI did not write a revision-10 KHC archive.'
}
$listed = Child $cli @('khc-list', $archive, '--json') 'cli-list'
if (@($listed | ConvertFrom-Json).Count -ne 2) { throw 'CLI manifest entry count mismatch.' }
$null = Child $cli @('khc-test', $archive) 'cli-test'
$null = Child $cli @('khc-extract', $archive, '--output', $output) 'cli-extract'

$restored = [ordered]@{}
foreach ($name in @('ptt5.bin', 'short.bin')) {
    $beforePath = Join-Path $sourceDirectory $name
    $afterPath = Join-Path $output $name
    $before = [IO.File]::ReadAllBytes($beforePath)
    $after = [IO.File]::ReadAllBytes($afterPath)
    if (-not [Linq.Enumerable]::SequenceEqual[byte]($before, $after)) { throw "CLI byte mismatch: $name" }
    $beforeHash = (Get-FileHash -LiteralPath $beforePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $afterHash = (Get-FileHash -LiteralPath $afterPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($beforeHash -cne $afterHash) { throw "CLI SHA-256 mismatch: $name" }
    $restored[$name] = $afterHash
}

$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$null = Child $cli @('khc-create', $archive, '--source', $sourceDirectory, '--strategy', 'portfolio-trial') 'cli-no-replace-create' $false
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $archiveHash) { throw 'CLI replaced an existing archive.' }
$null = Child $cli @('khc-extract', $archive, '--output', $output) 'cli-no-replace-extract' $false
foreach ($name in $restored.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $output $name) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $restored[$name]) {
        throw "CLI changed existing output: $name"
    }
}

$invalidArchives = @(Get-ChildItem -LiteralPath $api -Filter 'bad-*.khc' -File -Force | Sort-Object Name)
if ($invalidArchives.Count -ne 9) { throw 'Expected the nine preregistered invalid revision-10 fixtures.' }
foreach ($invalidArchive in $invalidArchives) {
    $label = $invalidArchive.BaseName
    $group = switch ($label) {
        'bad-2' { 'truncated' }
        'bad-3' { 'trailing' }
        default { 'frames' }
    }
    $rejectedOutput = Join-Path $api "cli-rejected-$group"
    if (-not (Test-Path -LiteralPath $rejectedOutput)) {
        $null = New-Item -ItemType Directory -Path $rejectedOutput
    }
    $sentinel = Join-Path $rejectedOutput 'sentinel'
    if (-not (Test-Path -LiteralPath $sentinel)) {
        [IO.File]::WriteAllText($sentinel, 'keep', [Text.UTF8Encoding]::new($false))
    }
    $payload = Join-Path $rejectedOutput 'payload.bin'
    if (([IO.File]::ReadAllText($sentinel) -cne 'keep') -or
        ($group -eq 'frames' -and (Test-Path -LiteralPath $payload))) {
        throw "CLI rejection output was contaminated before $label."
    }
    $null = Child $cli @('khc-test', $invalidArchive.FullName) "cli-rejects-$label-test" $false
    $null = Child $cli @('khc-extract', $invalidArchive.FullName, '--output', $rejectedOutput) "cli-rejects-$label-extract" $false
    if ([IO.File]::ReadAllText($sentinel) -cne 'keep') {
        throw "CLI changed the existing sentinel for $label."
    }
    if ($group -eq 'frames' -and (Test-Path -LiteralPath $payload)) {
        throw "CLI wrote an output file for invalid frame $label."
    }
    if ($group -ne 'frames' -and (Test-Path -LiteralPath $payload)) {
        $sourcePayload = Join-Path $apiSourceDirectory 'g32.bin'
        if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant() -cne
            (Get-FileHash -LiteralPath $sourcePayload -Algorithm SHA256).Hash.ToLowerInvariant()) {
            throw "CLI left unexpected partial output for $label."
        }
    }
}
for ($revision = 1; $revision -le 9; $revision++) {
    $legacy = Join-Path $api "legacy-$revision.khc"
    $null = Child $cli @('khc-test', $legacy) "cli-read-revision-$revision"
}

$report = [ordered]@{
    schema = 1
    scope = 'finite revision-10 correctness E2E; not a performance benchmark'
    input_member_sha256 = $expectedMemberSha256
    cli_sha256 = $KhcExecutableSha256
    e2e_sha256 = $E2eExecutableSha256
    cli_archive_sha256 = $archiveHash.ToLowerInvariant()
    cli_roundtrip_sha256 = $restored
    checks = @($script:checks.ToArray())
}
$json = $report | ConvertTo-Json -Depth 8
if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768) { throw 'E2E report exceeded 32KiB.' }
[IO.File]::WriteAllText((Join-Path $work 'spatial-mdl-e2e.json'), $json, [Text.UTF8Encoding]::new($false))
Write-Output $json
