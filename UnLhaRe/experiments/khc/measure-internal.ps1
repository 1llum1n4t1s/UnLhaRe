param(
    [Parameter(Mandatory)][string]$LabPath,
    [string]$BaselineReport,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$ReferenceLabPath,
    [ValidateRange(1, 100)][int]$Repeats = 5,
    [ValidateSet(1, 2, 3, 4, 8, 16)][int]$BeamWidth = 4,
    [ValidateSet(64, 128, 256, 512, 1024, 2048, 4096, 8192)][int]$BeamBlock = 512,
    [ValidateSet('nearest', 'priced-tie', 'bt4', 'bt5')][string[]]$MatchPolicies = @('nearest', 'priced-tie')
)
# 固定した開発集合のcodec内部時間専用。7-Zip/CLI時間やholdoutとは比較しない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory -ErrorAction Stop
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$baselinePath = $null
$baselineHash = $null
$baseline = $null
if ($BaselineReport) {
    $baselinePath = (Resolve-Path -LiteralPath $BaselineReport).Path
    $baselineHash = (Get-FileHash -LiteralPath $baselinePath).Hash
    $baseline = Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
}
$manifestPath = Join-Path $PSScriptRoot 'CORPUS_MANIFEST.json'
$manifest = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json | Where-Object name -eq 'canterbury-development').files)
$files = @(Get-ChildItem -LiteralPath (Join-Path $root 'build/khc-corpus/canterbury-development') -File | Sort-Object Name)
if ($files.Count -ne 11 -or $manifest.Count -ne 11) {
    throw 'Expected the complete fixed development corpus.'
}
if ($baseline -and ($baseline.cases.Count -ne ($files.Count * $MatchPolicies.Count) -or $baseline.output_hash_checks.Count -ne ($files.Count * ($MatchPolicies.Count + 1)))) {
    throw 'Baseline case/hash counts do not match the requested matcher policies.'
}
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$sourceFiles = @((Get-ChildItem -LiteralPath $PSScriptRoot -File -Filter '*.rs').FullName) + @(
    (Join-Path $root 'examples/khc_lab.rs'), (Join-Path $root 'Cargo.toml'), (Join-Path $root 'Cargo.lock'), $PSCommandPath, $manifestPath
)
$sourceHashes = @($sourceFiles | Sort-Object -Unique | ForEach-Object { [pscustomobject]@{path = $_; hash = (Get-FileHash -LiteralPath $_).Hash} })
$labHash = (Get-FileHash -LiteralPath $lab).Hash
$reference = $null
$referenceHash = $null
if ($ReferenceLabPath) {
    $reference = (Resolve-Path -LiteralPath $ReferenceLabPath).Path
    $referenceHash = (Get-FileHash -LiteralPath $reference).Hash
    if ($baseline -and $referenceHash -ne $baseline.binary_sha256) { throw 'Reference executable must match the baseline report binary hash.' }
}
$cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
$compiler = @(& (Join-Path $env:USERPROFILE '.cargo/bin/rustc.exe') --version)
if ($LASTEXITCODE -ne 0) { throw 'Cannot read Rust compiler identity.' }
Write-Host "KHC internal timing: $($cpu[0].Name.Trim()); repeats=$Repeats; Blended/$BeamWidth/$BeamBlock/64 MiB; policies=$($MatchPolicies -join ',')"
Write-Host "Lab SHA-256: $labHash"
if ($reference) { Write-Host "Paired reference SHA-256: $referenceHash; alternating order; each process warms up before one sample" }

function Invoke-LabBytes([string[]]$Arguments, [string]$Executable = $lab) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $memory = [IO.MemoryStream]::new()
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Cannot start lab.' }
        $copy = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { throw 'Lab exceeded the 120 second per-process deadline.' }
        # PowerShellではVoidTaskResultも出力されるため、明示的に抑止する。
        $null = $copy.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Lab exit $($process.ExitCode): $stderr" }
        return ,$memory.ToArray()
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $memory.Dispose()
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
$referenceCases = @()
$pairs = @()
$pairIndex = 0
$hashChecks = @()
$inputIndex = 0
foreach ($file in $files) {
    $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
    $entry = @($manifest | Where-Object name -eq $file.Name)
    if ($entry.Count -ne 1 -or $entry[0].sha256 -ne $hash -or $entry[0].bytes -ne $file.Length) { throw 'Fixed corpus mismatch.' }
    foreach ($policy in $MatchPolicies) {
        $beamMatchName = switch ($policy) {
            'nearest' { 'Nearest' }
            'priced-tie' { 'PricedTie' }
            'bt4' { 'Bt4' }
            'bt5' { 'Bt5' }
        }
        $common = @($file.FullName, '--algorithm', 'beam', '--beam-model', 'blended', '--beam-matches', $policy, '--dictionary-mib', '64', '--beam-width', [string]$BeamWidth, '--beam-block', [string]$BeamBlock)
        if ($reference) {
            $candidateSamples = @()
            $referenceSamples = @()
            $result = $null
            $referenceResult = $null
            for ($repeat = 0; $repeat -lt $Repeats; $repeat++) {
                $order = if ($pairIndex % 2 -eq 0) { @('reference', 'candidate') } else { @('candidate', 'reference') }
                foreach ($side in $order) {
                    $executable = if ($side -eq 'reference') { $reference } else { $lab }
                    $bytes = Invoke-LabBytes (@('bench') + $common + @('--repeats', '1')) $executable
                    $one = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                    if ($one.samples.Count -ne 1) { throw 'Paired invocation must return exactly one sample.' }
                    if ($baseline) {
                        $expected = @($baseline.cases | Where-Object { $_.input -eq $file.Name -and $_.result.beam_matches -eq $one.beam_matches })
                        if ($expected.Count -ne 1) { throw 'Paired baseline case missing.' }
                        foreach ($field in @('algorithm', 'beam_model', 'beam_width', 'beam_block', 'dictionary', 'input_bytes', 'frame_bytes')) {
                            if ($one.$field -ne $expected[0].result.$field) { throw "Paired $field mismatch." }
                        }
                    } else {
                        foreach ($expected in @{
                                algorithm = 'Beam'; beam_model = 'Blended'; beam_width = $BeamWidth
                                beam_block = $BeamBlock; dictionary = 64MB; input_bytes = $file.Length
                                beam_matches = $beamMatchName
                            }.GetEnumerator()) {
                            if ($one.($expected.Key) -ne $expected.Value) { throw "Paired $($expected.Key) mismatch." }
                        }
                    }
                    if ($side -eq 'reference') { $referenceResult = $one; $referenceSamples += $one.samples[0] }
                    else { $result = $one; $candidateSamples += $one.samples[0] }
                }
                $pairs += [pscustomobject]@{
                    input = $file.Name; policy = $policy; repeat = $repeat; order = $order
                    reference = $referenceSamples[-1]; candidate = $candidateSamples[-1]
                }
                $pairIndex++
            }
            foreach ($field in @('algorithm', 'beam_model', 'beam_width', 'beam_block', 'beam_matches', 'dictionary', 'input_bytes', 'frame_bytes')) {
                if ($result.$field -ne $referenceResult.$field) { throw "Candidate/reference $field mismatch." }
            }
            $result.samples = $candidateSamples
            $referenceResult.samples = $referenceSamples
            $referenceCases += [pscustomobject]@{input = $file.Name; sha256 = $hash; result = $referenceResult}
        } else {
            $bytes = Invoke-LabBytes (@('bench') + $common + @('--repeats', [string]$Repeats))
            $result = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        }
        if ($result.samples.Count -ne $Repeats) { throw 'Sample count mismatch.' }
        if ($baseline) {
            $previous = @($baseline.cases | Where-Object { $_.input -eq $file.Name -and $_.result.beam_matches -eq $result.beam_matches })
            if ($previous.Count -ne 1 -or $previous[0].sha256 -ne $hash) { throw 'Baseline case mismatch.' }
            foreach ($field in @('algorithm', 'beam_model', 'beam_width', 'beam_block', 'dictionary', 'input_bytes', 'frame_bytes')) {
                if ($previous[0].result.$field -ne $result.$field) { throw "Baseline $field mismatch for $($file.Name)." }
            }
        }
        $cases += [pscustomobject]@{input = $file.Name; sha256 = $hash; result = $result}
    }
    $settings = @()
    foreach ($policy in $MatchPolicies) { $settings += ,@('beam', $policy) }
    $settings += ,@('lz', 'nearest')
    foreach ($setting in $settings) {
        $algorithm, $policy = $setting
        $encodeArguments = @('encode', $file.FullName, '--algorithm', $algorithm, '--beam-model', 'blended', '--beam-matches', $policy, '--dictionary-mib', '64', '--beam-width', [string]$BeamWidth, '--beam-block', [string]$BeamBlock)
        $bytes = Invoke-LabBytes $encodeArguments
        $packedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes))
        if ($baseline) {
            $previous = @($baseline.output_hash_checks | Where-Object { $_.input -eq $file.Name -and $_.algorithm -eq $algorithm -and $_.policy -eq $policy })
            if ($previous.Count -ne 1 -or $previous[0].frame_sha256 -ne $packedHash) { throw "Output changed: $($file.Name)/$algorithm/$policy." }
        }
        if ($reference) {
            $referenceBytes = Invoke-LabBytes $encodeArguments $reference
            if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$referenceBytes)) -ne $packedHash) { throw 'Paired output hash mismatch.' }
        }
        $hashChecks += [pscustomobject]@{input = $file.Name; algorithm = $algorithm; policy = $policy; frame_sha256 = $packedHash}
    }
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne $hash) { throw 'Input changed during measurement.' }
    $inputIndex++
    Write-Host "[$inputIndex/$($files.Count)] $($file.Name): timing and output hashes verified"
}
if ((Get-FileHash -LiteralPath $lab).Hash -ne $labHash -or ($baselinePath -and (Get-FileHash -LiteralPath $baselinePath).Hash -ne $baselineHash)) { throw 'Binary or baseline changed during measurement.' }
if ($reference -and (Get-FileHash -LiteralPath $reference).Hash -ne $referenceHash) { throw 'Reference executable changed during measurement.' }
foreach ($source in $sourceHashes) { if ((Get-FileHash -LiteralPath $source.path).Hash -ne $source.hash) { throw 'Source changed during measurement.' } }
$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); binary = $lab; binary_sha256 = $labHash; build_source_hashes = $sourceHashes
    baseline = $baselinePath; baseline_sha256 = $baselineHash; cpu = $cpu; compiler = $compiler
    os = [Environment]::OSVersion.VersionString; power_scheme = @(powercfg /getactivescheme)
    note = 'KHC-only internal timing; fixed development corpus; no CLI/7zip comparison; no new encoded/decoded copies'
    cases = $cases; output_hash_checks = $hashChecks
    reference_binary = $reference; reference_binary_sha256 = $referenceHash; reference_cases = $referenceCases; pairs = $pairs
    sampling = if ($reference) { 'Alternating reference/candidate order per pair; each process performs one warm-up and one measured sample.' } else { 'One warm-up per case, followed by all measured samples in the same process.' }
}
$null = New-Item -ItemType Directory -Path $work
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
foreach ($policy in $MatchPolicies) {
    $beamMatchName = switch ($policy) {
        'nearest' { 'Nearest' }
        'priced-tie' { 'PricedTie' }
        'bt4' { 'Bt4' }
        'bt5' { 'Bt5' }
    }
    $sum = 0.0
    foreach ($case in @($cases | Where-Object { $_.result.beam_matches -eq $beamMatchName })) {
        $sum += Get-MedianValue $case.result.samples.encode_ms
    }
    $referenceSum = $null
    if ($reference) {
        $referenceSum = 0.0
        foreach ($case in @($referenceCases | Where-Object { $_.result.beam_matches -eq $beamMatchName })) { $referenceSum += Get-MedianValue $case.result.samples.encode_ms }
    }
    [pscustomobject]@{policy = $beamMatchName; encode_median_sum_ms = $sum; reference_median_sum_ms = $referenceSum; output_hashes_verified = $hashChecks.Count; report = (Join-Path $work 'report.json')}
}
