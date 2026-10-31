param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateSet('nearest','priced-tie','bt4','bt5','hybrid')][string[]]$MatchPolicies = @('nearest','priced-tie'),
    [ValidateSet(1,2,4,8,16)][int]$BeamWidth = 4,
    [ValidateSet(64,128,256,512,1024,2048,4096,8192)][int]$BeamBlock = 512
)
# 区間時間は計測負担を含むinclusive値。速度優位の判定には使わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$labHash = (Get-FileHash -LiteralPath $lab).Hash
$scriptHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
$work = [IO.Path]::GetFullPath($WorkDirectory)
$buildRoot = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
$manifestHash = (Get-FileHash -LiteralPath $manifestPath).Hash
$manifest = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object name -eq 'canterbury-development').files)
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'build/khc-corpus/canterbury-development') -File | Sort-Object Name)
if ($files.Count -ne 11 -or $manifest.Count -ne 11) { throw 'Expected fixed 11-input development corpus.' }
$cases = @()
foreach ($file in $files) {
    $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
    $entry = @($manifest | Where-Object name -eq $file.Name)
    if ($entry.Count -ne 1 -or $entry[0].sha256 -ne $hash -or $entry[0].bytes -ne $file.Length) { throw 'Corpus mismatch.' }
    foreach ($policy in $MatchPolicies) {
        $info = [Diagnostics.ProcessStartInfo]::new($lab)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($arg in @('profile', $file.FullName, '--algorithm', 'beam', '--beam-model', 'blended', '--beam-matches', $policy, '--beam-width', [string]$BeamWidth, '--beam-block', [string]$BeamBlock, '--dictionary-mib', '64')) {
            $info.ArgumentList.Add($arg)
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $started = $false
        try {
            $started = $process.Start()
            if (-not $started) { throw 'Cannot start profile.' }
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) { throw 'Profile exceeded 120 seconds.' }
            $json = $output.GetAwaiter().GetResult()
            $stderr = $errors.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) { throw "Profile exit $($process.ExitCode): $stderr" }
            $result = $json | ConvertFrom-Json
            $expectedPolicy = switch ($policy) { 'bt4' { 'Bt4' }; 'bt5' { 'Bt5' }; 'hybrid' { 'Hybrid' }; 'priced-tie' { 'PricedTie' }; 'nearest' { 'Nearest' } }
            if ($result.algorithm -ne 'Beam' -or $result.beam_model -ne 'Blended' -or $result.beam_matches -ne $expectedPolicy -or $result.beam_width -ne $BeamWidth -or $result.beam_block -ne $BeamBlock -or $result.dictionary -ne 67108864 -or $result.input_bytes -ne $file.Length) { throw 'Unexpected profile settings.' }
            $cases += [pscustomobject]@{input = $file.Name; sha256 = $hash; policy = $policy; result = $result}
        } finally {
            if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne $hash) { throw 'Input changed during profile.' }
    Write-Host "$($file.Name): uninstrumented/profile output and round-trip checks passed"
}
if ((Get-FileHash -LiteralPath $lab).Hash -ne $labHash -or (Get-FileHash -LiteralPath $manifestPath).Hash -ne $manifestHash) { throw 'Binary or manifest changed.' }
if ((Get-FileHash -LiteralPath $PSCommandPath).Hash -ne $scriptHash) { throw 'Script changed.' }
$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o')
    binary = $lab
    binary_sha256 = $labHash
    manifest_sha256 = $manifestHash
    script_sha256 = $scriptHash
    match_policies = $MatchPolicies
    beam_width = $BeamWidth
    beam_block = $BeamBlock
    coverage_note = 'BT4 tree preparation/frontier filtering are outside find_matches; beam_plan minus warm_model and expand_nodes is an unattributed residual, not matcher-only time.'
    cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    os = [Environment]::OSVersion.VersionString
    note = 'Fixed executable diagnostic only; instrumented inclusive times overlap; not a speed benchmark or holdout; binary provenance must be checked separately.'
    cases = $cases
}
$null = New-Item -ItemType Directory -Path $work
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
Write-Host "Saved $work/report.json"
