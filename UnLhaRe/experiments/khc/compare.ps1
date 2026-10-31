param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][string[]]$InputFiles,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateRange(1, 100)][int]$Repeats = 5,
    [ValidateSet('standard','lz','beam','context','auto')][string[]]$Algorithms = @('lz'),
    [ValidateRange(1,64)][int]$DictionaryMiB = 8,
    [ValidateSet(1,2,4,8,16)][int]$BeamWidth = 4,
    [ValidateSet(64,128,256,512,1024,2048,4096,8192)][int]$BeamBlock = 512,
    [ValidateSet('current','warm','blended')][string]$BeamModel = 'current',
    [ValidateSet('nearest','priced-tie','bt4','bt5','hybrid')][string]$BeamMatches = 'nearest'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory -ErrorAction Stop
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$sevenZip = (Resolve-Path -LiteralPath $SevenZipPath).Path
$inputs = @($InputFiles | ForEach-Object { (Get-Item -LiteralPath $_).FullName })
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$sourceFiles = @(
    (Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.rs').FullName
    (Join-Path $sourceRoot 'examples/khc_lab.rs')
    (Join-Path $sourceRoot 'Cargo.toml')
    (Join-Path $sourceRoot 'Cargo.lock')
    $PSCommandPath
)
$sourceHashes = @($sourceFiles | Sort-Object -Unique | ForEach-Object {
    [pscustomobject]@{ path = [IO.Path]::GetRelativePath($sourceRoot, $_); sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$labHash = (Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash
$sevenZipHash = (Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash
$sevenZipIdentity = @(& $sevenZip i | Select-String -Pattern '^7-Zip' | ForEach-Object { $_.Line })
if ($LASTEXITCODE -ne 0 -or $sevenZipIdentity.Count -eq 0) { throw 'Unable to verify the 7-Zip executable.' }
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
$compiler = @(& (Join-Path $env:USERPROFILE '.cargo/bin/rustc.exe') --version)
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the Rust compiler.' }
$revision = @(git -C $sourceRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0) { throw 'Unable to record the source revision.' }
Write-Host ("KHC comparison: {0}; {1}; dictionary={2} MiB; algorithms={3}; repeats={4}" -f $cpu[0].Name.Trim(), ($sevenZipIdentity -join ' '), $DictionaryMiB, ($Algorithms -join ','), $Repeats)
Write-Host "Lab SHA-256: $labHash"
Write-Host "Beam search: width=$BeamWidth; block=$BeamBlock bytes; model=$BeamModel; matches=$BeamMatches"
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new; existing data will not be overwritten.' }
$null = New-Item -ItemType Directory -Path $work

function Invoke-Measured([string]$Program, [string[]]$Arguments, [string]$StdoutFile, [string]$ExpectedDecodedHash = '') {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    # 復元出力は両codecとも同じSHA-256 sinkへ流し、検証用コピーを増やさない。
    # streaming hashのCPU時間はCLI wall timeに含む（codec単独時間ではない）。
    $hasher = if ($ExpectedDecodedHash) { [Security.Cryptography.SHA256]::Create() } else { $null }
    $sink = if ($hasher) {
        [Security.Cryptography.CryptoStream]::new([IO.Stream]::Null, $hasher, [Security.Cryptography.CryptoStreamMode]::Write, $true)
    } elseif ($StdoutFile) { [IO.File]::Open($StdoutFile, [IO.FileMode]::CreateNew) } else { [IO.Stream]::Null }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $peakWorking = 0L
    $peakPrivate = 0L
    $started = $false
    $outputTask = $null
    try {
        $started = $process.Start()
        $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1)) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Per-process 120 second deadline exceeded.' }
            if ($outputTask.IsFaulted) { $null = $outputTask.GetAwaiter().GetResult() }
            $process.Refresh()
            $peakWorking = [Math]::Max($peakWorking, $process.PeakWorkingSet64)
            $peakPrivate = [Math]::Max($peakPrivate, $process.PrivateMemorySize64)
        }
        $null = $outputTask.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        $decodedHash = $null
        if ($hasher) {
            $sink.FlushFinalBlock()
            $decodedHash = [Convert]::ToHexString($hasher.Hash)
        }
        $watch.Stop()
        if ($process.ExitCode -ne 0) { throw "$Program exit $($process.ExitCode): $stderr" }
        if ($hasher -and $decodedHash -ne $ExpectedDecodedHash) { throw 'Restored SHA-256 mismatch.' }
        [pscustomobject]@{
            wall_ms = $watch.Elapsed.TotalMilliseconds
            cpu_ms = $process.TotalProcessorTime.TotalMilliseconds
            peak_working_sampled = $(if ($peakWorking -gt 0) { $peakWorking } else { $null })
            peak_private_sampled = $(if ($peakPrivate -gt 0) { $peakPrivate } else { $null })
            decoded_sha256 = $decodedHash
        }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        # 失敗時もstdout pumpの終了後にsinkを解放し、並行書込み中にdisposeしない。
        if ($null -ne $outputTask) { try { $null = $outputTask.GetAwaiter().GetResult() } catch { } }
        if ($StdoutFile -or $hasher) { $sink.Dispose() }
        if ($hasher) { $hasher.Dispose() }
        $process.Dispose()
    }
}

function Get-MedianValue([double[]]$Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { throw 'Cannot take the median of no samples.' }
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 0) { return ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
    return $sorted[$middle]
}

$cases = @()
$index = 0
foreach ($inputPath in $inputs) {
    if ((Get-Item -LiteralPath $inputPath).Length -gt 64MB) { throw 'Lab input must not exceed 64 MiB.' }
    $caseDir = Join-Path $work ('case-{0:D2}' -f $index)
    $null = New-Item -ItemType Directory -Path $caseDir
    $snapshot = Join-Path $caseDir 'input.bin'
    Copy-Item -LiteralPath $inputPath -Destination $snapshot
    $inputHash = (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash
    $samples = @()
    $firstHashes = @{}
    for ($iteration = 0; $iteration -le $Repeats; $iteration++) {
        # 0 は warm-up。以後も実行順を交互化して双方を同条件で測る。
        $order = @($Algorithms | ForEach-Object { "khc-$_" }) + @('7zip')
        if ($iteration % 2 -ne 0) { [array]::Reverse($order) }
        foreach ($codec in $order) {
            $packed = Join-Path $caseDir "$iteration.$codec"
            if ($codec -ne '7zip') {
                $algorithm = $codec.Substring(4)
                $encoding = Invoke-Measured $lab @('encode', $snapshot, '--dictionary-mib', [string]$DictionaryMiB, '--algorithm', $algorithm, '--beam-width', [string]$BeamWidth, '--beam-block', [string]$BeamBlock, '--beam-model', $BeamModel, '--beam-matches', $BeamMatches) $packed
                $decoding = Invoke-Measured $lab @('decode', $packed) '' $inputHash
                $payloadBytes = (Get-Item -LiteralPath $packed).Length - 40
            } else {
                $encoding = Invoke-Measured $sevenZip @('a', '-t7z', '-mx=9', "-m0=LZMA2:d=$($DictionaryMiB)m", '-mmt=1', '-ms=off', '-mtm=off', '-mtc=off', '-mta=off', '-mhc=off', '-bso0', '-bsp0', $packed, $snapshot) ''
                $decoding = Invoke-Measured $sevenZip @('x', '-so', '-bsp0', $packed) '' $inputHash
                $listing = & $sevenZip l -slt $packed
                if ($LASTEXITCODE -ne 0) { throw '7-Zip listing failed.' }
                $sizeLines = @($listing | Where-Object { $_ -match '^Packed Size = (\d+)$' })
                if ($sizeLines.Count -ne 1) { throw 'Expected one independent 7-Zip payload.' }
                $payloadBytes = [long]($sizeLines[0] -replace '^Packed Size = ', '')
            }
            $packedHash = (Get-FileHash -LiteralPath $packed -Algorithm SHA256).Hash
            if ($iteration -eq 0) { $firstHashes[$codec] = $packedHash }
            elseif ($firstHashes[$codec] -ne $packedHash) { throw 'Output was not deterministic.' }
            $samples += [pscustomobject]@{
                codec = $codec
                iteration = $iteration
                warmup = ($iteration -eq 0)
                frame_bytes = (Get-Item -LiteralPath $packed).Length
                payload_bytes = $payloadBytes
                encode = $encoding
                decode = $decoding
            }
        }
    }
    $cases += [pscustomobject]@{ input = $inputPath; input_bytes = (Get-Item -LiteralPath $snapshot).Length; sha256 = $inputHash; samples = $samples }
    $index++
    Write-Host "[$index/$($inputs.Count)] $([IO.Path]::GetFileName($inputPath)): round-trips and determinism verified"
}
# 計測途中の再ビルドや編集を別候補の結果へ混ぜない。
if ((Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash -ne $labHash -or
    (Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash -ne $sevenZipHash) {
    throw 'An executable changed during the measurement; discard this run.'
}
foreach ($source in $sourceHashes) {
    if ((Get-FileHash -LiteralPath (Join-Path $sourceRoot $source.path) -Algorithm SHA256).Hash -ne $source.sha256) {
        throw 'A source file changed during the measurement; discard this run.'
    }
}
$report = [pscustomobject]@{
    status = 'development smoke comparison; not a holdout or overall performance claim'
    measured_utc = [DateTime]::UtcNow.ToString('o')
    os = [Environment]::OSVersion.VersionString
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    cpu = $cpu
    power_scheme = @(powercfg /getactivescheme)
    lab_sha256 = $labHash
    seven_zip_sha256 = $sevenZipHash
    seven_zip_identity = $sevenZipIdentity
    compiler = $compiler
    revision = $revision
    source_state = 'working tree; source files and executable hashes recorded separately'
    source_sha256 = $sourceHashes
    dictionary_bytes = $DictionaryMiB * 1MB
    algorithms = $Algorithms
    beam_width = $BeamWidth
    beam_block = $BeamBlock
    beam_model = $BeamModel
    beam_matches = $BeamMatches
    threads = 1
    memory_note = 'Sampled OS process memory is observational, not an equal hard memory ceiling.'
    decode_output = 'Both codecs stream to the same SHA-256 sink; hashing is included in CLI wall time; no decoded copies are created. Do not directly compare decode timings to earlier file-sink runs.'
    cases = $cases
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
$cases | ForEach-Object {
    $case = $_
    foreach ($codec in (@($Algorithms | ForEach-Object { "khc-$_" }) + @('7zip'))) {
        $rows = @($case.samples | Where-Object { $_.codec -eq $codec -and -not $_.warmup })
        $encodeTimes = @($rows.encode.wall_ms | Sort-Object)
        $decodeTimes = @($rows.decode.wall_ms | Sort-Object)
        [pscustomobject]@{
            input = [IO.Path]::GetFileName($case.input)
            codec = $codec
            input_bytes = $case.input_bytes
            frame_bytes = $rows[0].frame_bytes
            payload_bytes = $rows[0].payload_bytes
            encode_median_ms = Get-MedianValue $encodeTimes
            decode_median_ms = Get-MedianValue $decodeTimes
        }
    }
} | ConvertTo-Json
