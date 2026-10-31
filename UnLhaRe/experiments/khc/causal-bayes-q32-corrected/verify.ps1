#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$ReferenceBinary,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# Bayes/packed full research frame専用。通常build/出荷から呼び出さない。
# failure-first: correctness/決定性/上限/破損/公開なし/既存output保持を先に検証する。
# 固定sizeを超えた場合も失敗経路のE2Eは完了するが、時間測定・調整は行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$buildPrefix = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$fixedSize = 2811006L
$invocations = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
$identities = [Collections.Generic.List[object]]::new()
$owned = [Collections.Generic.List[string]]::new()
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$crcTable = [uint32[]]::new(256)
for ($i = 0; $i -lt 256; $i++) {
    $v = [uint32]$i
    for ($b = 0; $b -lt 8; $b++) { $v = if ($v -band 1) { ($v -shr 1) -bxor [uint32]3988292384 } else { $v -shr 1 } }
    $crcTable[$i] = $v
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Reparse point rejected: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Get-Identity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw "Expected regular file: $Path" }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path).Hash }
}
function Lock-Identity([string]$Path, [string]$Role) {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $id = Get-Identity $Path
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null }
    $identities.Add($row)
    return $row
}
function Write-New([string]$Path, [byte[]]$Data) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Data, 0, $Data.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $owned.Add($Path)
}
function Get-Crc([byte[]]$Data) {
    $crc = [uint32]::MaxValue
    foreach ($v in $Data) { $crc = ($crc -shr 8) -bxor $crcTable[($crc -bxor [uint32]$v) -band 255] }
    return ($crc -bxor [uint32]::MaxValue)
}
function Set-U32([byte[]]$Data, [int]$Offset, [uint32]$Value) {
    [BitConverter]::GetBytes($Value).CopyTo($Data, $Offset)
}
function Repair-Header([byte[]]$Data, [int]$MetadataBytes = -1) {
    $count = [BitConverter]::ToUInt32($Data, 16)
    if ($MetadataBytes -lt 0) { $MetadataBytes = Get-MetadataBytes $count }
    if ($Data.Length -lt 36 + $metadataBytes) { throw 'Invalid mutation header bounds.' }
    $covered = [byte[]]::new(32 + $metadataBytes)
    [Array]::Copy($Data, 0, $covered, 0, 32)
    [Array]::Copy($Data, 36, $covered, 32, $metadataBytes)
    Set-U32 $Data 32 (Get-Crc $covered)
}
function Get-MetadataBytes([uint32]$Count) {
    if ($Count -lt 1 -or $Count -gt 257) { throw 'Invalid metadata count for mutation.' }
    $factorial = [Numerics.BigInteger]::One
    for ($i=2; $i -le $Count; $i++) { $factorial *= $i }
    $maxRank = $factorial - [Numerics.BigInteger]::One
    $rankWidth = if ($maxRank.IsZero) { 0 } else { $maxRank.ToByteArray($true,$false).Length }
    return 33 + $rankWidth
}
function Add-Check([string]$Name, [object]$Evidence) { $checks.Add([pscustomobject]@{ name = $Name; passed = $true; evidence = $Evidence }) }
function Invoke-Cli([string]$Name, [string[]]$Argv, [int]$ExpectedExit, [string]$Program = $binary.path) {
    # 生成fixtureも使用前から、既存outputも拒否前から書換え・削除を禁止する。
    foreach ($path in @($Argv[1], $Argv[2])) {
        if (Test-Path -LiteralPath $path) { $null = Lock-Identity $path 'cli-retained-input-or-existing-output' }
    }
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $work
    foreach ($arg in $Argv) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $row = [ordered]@{ name = $Name; program = $Program; argv = $Argv; expected_exit = $ExpectedExit; exit = $null; stdout = ''; stderr = ''; timeout = $false; output = $null }
    $invocations.Add($row)
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process start failed.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $row.timeout = $true; throw "CLI timeout: $Name" }
        $row.stdout = $stdout.GetAwaiter().GetResult()
        $row.stderr = $stderr.GetAwaiter().GetResult()
        $row.exit = $process.ExitCode
        if ($row.exit -ne $ExpectedExit) { throw "CLI $Name exit $($row.exit), expected $ExpectedExit : $($row.stderr)" }
        if ($ExpectedExit -eq 0) {
            if ($row.stderr.Length -ne 0) { throw 'Successful CLI wrote stderr.' }
            $json = $row.stdout | ConvertFrom-Json
            if ($json.operation -cne $Argv[0]) { throw 'CLI JSON operation mismatch.' }
            $row.output = Get-Identity $Argv[2]
            $null = Lock-Identity $Argv[2] 'cli-retained-success-output'
            if ($json.input_bytes -ne (Get-Item -LiteralPath $Argv[1]).Length -or $json.output_bytes -ne $row.output.bytes) { throw 'CLI JSON byte counts mismatch.' }
            $owned.Add($Argv[2])
        }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
    return [pscustomobject]$row
}
function Assert-Rejected([string]$Name, [string]$Operation, [string]$InputPath, [string]$ExpectedReason) {
    # PowerShell自動変数$inputはparameter名にしない。拒否理由も照合し別経路の失敗を排除。
    $identity = if ($Name.StartsWith('missing-input-', [StringComparison]::Ordinal)) {
        if (Test-Path -LiteralPath $InputPath) { throw 'Missing-input fixture unexpectedly exists.' }
        $null
    } else { Get-Identity $InputPath }
    $out = Join-Path $work "$Name.rejected-output"
    $row = Invoke-Cli $Name @($Operation, $InputPath, $out) 1
    if (Test-Path -LiteralPath $out) { throw "Rejected input published output: $Name" }
    if ($row.stdout.Length -ne 0) { throw 'Rejected CLI wrote stdout.' }
    if (-not $row.stderr.Trim().StartsWith("rejected: $ExpectedReason", [StringComparison]::Ordinal)) { throw "Unexpected rejection reason: $Name : $($row.stderr)" }
    Add-Check $Name ([pscustomobject]@{ exit = $row.exit; output_absent = $true; input = $InputPath; input_identity = $identity; expected_reason = $ExpectedReason; observed_reason = $row.stderr.Trim() })
}
function Assert-Group([byte[]]$Data) {
    if ($Data.LongLength -ne $fixedSize -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Data)) -cne $fixedHash) { throw 'Fixed group identity mismatch.' }
    $collections = @(Get-Content -LiteralPath $manifest.path -Raw | ConvertFrom-Json | Where-Object { $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development' })
    if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) { throw 'Manifest boundary mismatch.' }
    $expected = @($collections[0].files)
    $names = [string[]]@($expected | ForEach-Object { $_.name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $stream = [IO.MemoryStream]::new($Data, $false)
    $reader = [IO.BinaryReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false)
    $entries = [Collections.Generic.List[object]]::new()
    try {
        if ([Convert]::ToHexString($reader.ReadBytes(8)) -cne '4B48534752503000' -or $reader.ReadUInt32() -ne 11 -or $reader.ReadUInt32() -ne 0) { throw 'Invalid group magic/count/flags.' }
        for ($i = 0; $i -lt 11; $i++) {
            $len = $reader.ReadUInt16(); $size = $reader.ReadUInt64()
            if ($len -lt 1 -or $len -gt 255 -or $size -gt $fixedSize) { throw 'Invalid group metadata lengths.' }
            $nameBytes = $reader.ReadBytes($len)
            if ($nameBytes.Length -ne $len) { throw 'Truncated group name.' }
            $name = [Text.UTF8Encoding]::new($false, $true).GetString($nameBytes)
            $match = @($expected | Where-Object { $_.name -ceq $names[$i] })
            if ($match.Count -ne 1 -or $name -cne $names[$i] -or $size -ne $match[0].bytes) { throw 'Group metadata/order mismatch.' }
            $entries.Add([pscustomobject]@{ name = $name; bytes = [long]$size; expected_sha256 = [string]$match[0].sha256; observed_sha256 = $null })
        }
        foreach ($entry in $entries) {
            $body = $reader.ReadBytes([int]$entry.bytes)
            $entry.observed_sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body))
            if ($body.LongLength -ne $entry.bytes -or $entry.observed_sha256 -cne $entry.expected_sha256) { throw "Group body mismatch: $($entry.name)" }
        }
        if ($stream.Position -ne $stream.Length) { throw 'Trailing group bytes.' }
    } finally { $reader.Dispose() }
    return $entries.ToArray()
}

if (-not $work.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below UnLhaRe/build.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'Refusing existing WorkDirectory.' }
$null = New-Item -ItemType Directory -Path $work
$owned.Add($work)
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); error = $null
    environment = [ordered]@{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); powershell = $PSVersionTable.PSVersion.ToString(); cwd = $PWD.Path }
    fixed_gate = [ordered]@{ input_bytes = $fixedSize; input_sha256 = $fixedHash; maximum_archive_bytes = 483599; maximum_encode_ms_exclusive = 574.5624 }
    provenance = $identities; invocations = $invocations; checks = $checks; owned_paths = $owned; timing_used = $false; fixed_candidate = $null; entries = @()
    limits = @('Research CLI only; no product integration or general 7-Zip superiority claim.', 'Single fixed configuration; no model/context/parameter sweep.', 'Full frame and decoder, not a performance measurement.', 'Malformed checks include repaired CRCs to exercise semantic validation beyond checksums.', 'Retained artifacts are evidence, not backups; cleanup must not bypass host policy.')
}
$pins = @{
    'experiments/khc/causal-bayes-q32/codec.rs' = 'A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    'experiments/khc/causal-bayes-q32/cts_model.rs' = '52CD54524DD89565DBEEEA2B1F3B5E89668DD8429453692663D3EDAA6D488D88'
    'experiments/khc/causal-bayes-q32/verify.ps1' = '1E71EFE27CB296F993E8CCD72E68C021132FD63E7392055E88D9F7EE19C79BE4'
    'experiments/khc/corrected-quotient/exact_div.rs' = '52595705A96F939B63D0DDB88871F3E7F78419973B0891E7A79E42579EA81D3A'
    'experiments/khc/causal-bayes-sais/bwt.rs' = '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
    'experiments/khc/causal-bayes-packed/bayes_model.rs' = '65658333E8D3EB5EBD71B05AEBCD653B8E3506580203439C2E8912DFE3DB0EB9'
    'experiments/khc/rejected-binary-mix/packed_alphabet.rs' = '4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
    'experiments/khc/range.rs' = '1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
    'experiments/khc/CAUSAL_BAYES_Q32_CONTRACT_20260930.md' = 'FF48085A6C534BDC1777E4BF6542E285800811753192086362405F3A04CD71DB'
    'experiments/khc/Q32_CORRECTED_QUOTIENT_CONTRACT_20261001.md' = 'EB992EDA250B115B4599BD7E13284616678BE9C7AB58BDD65447CEBACE193DA6'
    'experiments/khc/Q32_CORRECTED_CODEC_CONTRACT_20261001.md' = '856D9C58E5688A1468BF1DDF8D98B1A803EB6B5A7CBAE46380E43FF45E1B7FE4'
    'experiments/khc/CORPUS_MANIFEST.json' = '77F2A728B33AE54655B67DCC3BCAA85D0912B98BA0F44343C64F903707BD5036'
    'build/khc-corrected-quotient-20261001/report.json' = '803072EA44DB97BFFDDAC78913E975B827B9334870F82A0EB0E19051005626D6'
    'build/khc-bwt-causal-bayes-q32-20260930/candidate.exe' = 'FBF35FC6600FB62506658EC63A734F69857489AE2CE53257CD0907D00F6DAD5F'
    'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/report.json' = '2F7F612F63570CD58976F16F42D4DD3255DAE0DD242B6891B5CB3946463C006C'
    'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
    'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
}

function Assert-BytesEqual([string]$Left, [string]$Right) {
    $a = [IO.File]::ReadAllBytes($Left); $b = [IO.File]::ReadAllBytes($Right)
    if ($a.Length -ne $b.Length) { throw "Byte length mismatch: $Left / $Right" }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { throw "Byte mismatch at $i : $Left / $Right" } }
}
$failure = $null
try {
    foreach ($p in $pins.Keys) {
        $path = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $root $p }
        $pinned = Lock-Identity $path "pinned:$p"
        if ($pinned.before_sha256 -cne $pins[$p]) { throw "Pinned identity mismatch: $p" }
    }
    $null = Lock-Identity (Join-Path $PSScriptRoot 'build.ps1') 'build-harness'
    $null = Lock-Identity (Join-Path ([IO.Path]::GetDirectoryName($work)) 'build-report.json') 'build-proof'
    $originalQ32 = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/candidate.exe') 'original-q32'
    $originalFixed = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/fixed.frame') 'original-q32-fixed'
    $binary = Lock-Identity ([IO.Path]::GetFullPath($BinaryPath)) 'binary'
    $reference = Lock-Identity ([IO.Path]::GetFullPath($ReferenceBinary)) 'opt2-reference-binary'
    $buildProof = Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($work)) 'build-report.json') -Raw | ConvertFrom-Json
    if ($buildProof.status -cne 'built_not_timed' -or $buildProof.compile_calls.Count -ne 2) { throw 'Invalid corrected build proof.' }
    foreach ($exe in @($binary,$reference)) {
        $saved = @($buildProof.outputs | Where-Object { $_.path -ceq $exe.path })
        if ($saved.Count -ne 1 -or $saved[0].sha256 -cne $exe.before_sha256 -or $saved[0].bytes -ne $exe.before_bytes) { throw 'Compiled executable differs from build proof.' }
    }
    $source = Lock-Identity (Join-Path $PSScriptRoot 'codec.rs') 'source'
    $oldBinary=Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/candidate.exe') 'old-format-decoder'
    $oldFrame=Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-exact-div-20260930/full-e2e/fixed.frame') 'old-format-frame'
    if($oldBinary.before_sha256 -cne '9AC5CA8F200611454F2AC7E482737518FA90842353F26B750F3A0420E07E7FBA' -or $oldFrame.before_sha256 -cne 'B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A'){throw 'Old format reference mismatch.'}
    foreach ($name in @('../causal-bayes-sais/bwt.rs','cts_model.rs','../causal-bayes-packed/bayes_model.rs','../rejected-binary-mix/packed_alphabet.rs','../CAUSAL_BAYES_Q32_CONTRACT_20260930.md')) { $null = Lock-Identity (Join-Path $PSScriptRoot $name) $name }
    $range = Lock-Identity (Join-Path $PSScriptRoot '../range.rs') 'range-source'
    $group = Lock-Identity ([IO.Path]::GetFullPath($GroupPath)) 'fixed-input'
    $manifest = Lock-Identity (Join-Path $PSScriptRoot '../CORPUS_MANIFEST.json') 'manifest'
    $null = Lock-Identity $PSCommandPath 'harness'
    $null = Lock-Identity 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'rustc'
    $report.environment['cpu'] = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    $report.environment['rustc'] = @(& 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' --version)
    $report.environment['source_last_write_utc'] = (Get-Item -LiteralPath $source.path).LastWriteTimeUtc.ToString('o')
    if ($group.before_bytes -ne $fixedSize -or $group.before_sha256 -cne $fixedHash) { throw 'Fixed input provenance mismatch.' }
    $fixedBytes = [IO.File]::ReadAllBytes($group.path)
    $report.entries = @(Assert-Group $fixedBytes)
    Write-Host "Size-only E2E source=$($source.before_sha256) binary=$($binary.before_sha256) input=$fixedHash"
    $fixtures = [ordered]@{ empty = [byte[]]@(); single = [byte[]]@(42); single_high=[byte[]]@(255); all_bytes = [byte[]](0..255); repeated = [byte[]]::new(8192); periodic = [byte[]]::new(16384); seeded_random = [byte[]]::new(8192) }
    [Array]::Fill($fixtures.repeated, [byte]65)
    for ($i = 0; $i -lt $fixtures.periodic.Length; $i++) { $fixtures.periodic[$i] = [byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i % 11]) }
    $random = [Random]::new(20260930); $random.NextBytes($fixtures.seeded_random)
    foreach ($name in $fixtures.Keys) {
        $input = Join-Path $work "$name.input"; $frame = Join-Path $work "$name.frame"; $repeat = Join-Path $work "$name.repeat.frame"; $restored = Join-Path $work "$name.restored"
        Write-New $input $fixtures[$name]
        $encoded = Invoke-Cli "$name-encode" @('encode', $input, $frame) 0
        $second = Invoke-Cli "$name-repeat" @('encode', $input, $repeat) 0
        if ($encoded.output.sha256 -cne $second.output.sha256) { throw "Non-deterministic fixture: $name" }
        $decoded = Invoke-Cli "$name-decode" @('decode', $frame, $restored) 0
        $cross = Invoke-Cli "$name-opt2-decode" @('decode', $frame, (Join-Path $work "$name.opt2.restored")) 0 $reference.path
        $original = Get-Identity $input
        if ($original.sha256 -cne $decoded.output.sha256 -or $original.bytes -ne $decoded.output.bytes -or $original.sha256 -cne $cross.output.sha256) { throw "Fixture round-trip mismatch: $name" }
        $originalFrame = Join-Path $work "$name.original-q32.frame"
        $originalEncoded = Invoke-Cli "$name-original-q32-encode" @('encode', $input, $originalFrame) 0 $originalQ32.path
        Assert-BytesEqual $frame $originalFrame
        Assert-BytesEqual $input $restored
        Assert-BytesEqual $input (Join-Path $work "$name.opt2.restored")
        Assert-BytesEqual $frame $repeat
        Add-Check "$name-original-q32-full-byte-equality" ([pscustomobject]@{ original = $originalEncoded.output; corrected = $encoded.output })
        Add-Check "$name-roundtrip-and-determinism" ([pscustomobject]@{ input = $original; frame = $encoded.output; restored = $decoded.output })
    }
    $fixedInput = Join-Path $work 'fixed.group'; Write-New $fixedInput $fixedBytes
    $fixedFrame = Join-Path $work 'fixed.frame'; $fixedRepeat = Join-Path $work 'fixed.repeat.frame'; $fixedRestore = Join-Path $work 'fixed.restored.group'
    $encoded = Invoke-Cli 'fixed-encode' @('encode', $fixedInput, $fixedFrame) 0
    $second = Invoke-Cli 'fixed-repeat' @('encode', $fixedInput, $fixedRepeat) 0
    if ($encoded.output.sha256 -cne $second.output.sha256) { throw 'Fixed frame non-determinism.' }
    $decoded = Invoke-Cli 'fixed-decode' @('decode', $fixedFrame, $fixedRestore) 0
    $cross = Invoke-Cli 'fixed-opt2-decode' @('decode', $fixedFrame, (Join-Path $work 'fixed.opt2.restored.group')) 0 $reference.path
    $crossEncode = Invoke-Cli 'fixed-opt2-encode' @('encode', $fixedInput, (Join-Path $work 'fixed.opt2.frame')) 0 $reference.path
    if ($cross.output.sha256 -cne $fixedHash -or $crossEncode.output.sha256 -cne $encoded.output.sha256) { throw 'Cross-build full codec mismatch.' }
    if ($encoded.output.bytes -ne 483469 -or $encoded.output.sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C') { throw 'Corrected fixed frame pin mismatch.' }
    Assert-BytesEqual $fixedFrame $originalFixed.path
    Assert-BytesEqual $fixedFrame $fixedRepeat
    Assert-BytesEqual $fixedFrame (Join-Path $work 'fixed.opt2.frame')
    Assert-BytesEqual $fixedInput $fixedRestore
    Assert-BytesEqual $fixedInput (Join-Path $work 'fixed.opt2.restored.group')
    $originalCross = Invoke-Cli 'original-q32-decode-corrected-fixed' @('decode', $fixedFrame, (Join-Path $work 'fixed.original-q32.restored.group')) 0 $originalQ32.path
    $correctedCross = Invoke-Cli 'corrected-decode-original-q32-fixed' @('decode', $originalFixed.path, (Join-Path $work 'original-fixed.corrected.restored.group')) 0
    Assert-BytesEqual $fixedInput $originalCross.output.path
    Assert-BytesEqual $fixedInput $correctedCross.output.path
    Add-Check 'original-q32-fixed-full-byte-equality-and-cross-decode' ([pscustomobject]@{ original_frame = $originalFixed; corrected_frame = $encoded.output; original_decode = $originalCross.output; corrected_decode = $correctedCross.output })
    $fixedData = [IO.File]::ReadAllBytes($fixedFrame)
    if ($encoded.output.bytes -ne (36 + 245 + [BitConverter]::ToUInt32($fixedData,20)) -or (Get-MetadataBytes ([BitConverter]::ToUInt32($fixedData,16))) -ne 245) { throw 'Full frame / payload / metadata accounting mismatch.' }
    $restoredEntries = @(Assert-Group ([IO.File]::ReadAllBytes($fixedRestore)))
    Add-Check 'fixed-roundtrip-determinism-11entries' ([pscustomobject]@{ frame = $encoded.output; restored = $decoded.output; entries = $restoredEntries })
    Assert-Rejected 'reject-old-format' 'decode' $oldFrame.path 'bad frame magic/header'
    $oldOutput=Join-Path $work 'old-decoder-rejected'
    $oldRun=Invoke-Cli 'old-decoder-rejects-new-format' @('decode',$fixedFrame,$oldOutput) 1 $oldBinary.path
    if((Test-Path -LiteralPath $oldOutput) -or $oldRun.stdout -or $oldRun.stderr -notmatch 'bad frame magic/header'){throw 'Old decoder accepted new CTS format.'}
    Add-Check 'old-decoder-rejects-new-format' ([pscustomobject]@{reason=$oldRun.stderr;output_absent=$true})
    $report.fixed_candidate = $encoded.output
    $report['fixed_size_gate_passed'] = $encoded.output.bytes -le 483599
    $report['fixed_size_delta'] = $encoded.output.bytes - 483599

    # 小fixtureの攻撃でもalphabetは257 symbolsある。CRCを修復して意味検査に届かせる。
    $valid = [IO.File]::ReadAllBytes((Join-Path $work 'all_bytes.frame'))
    if ([Text.Encoding]::ASCII.GetString($valid, 0, 8) -cne 'KHBAYQ32') { throw 'Unexpected candidate format magic.' }
    $alphabetCount = [BitConverter]::ToUInt32($valid, 16)
    if ($alphabetCount -ne 257) { throw 'All-byte alphabet contract mismatch.' }
    $mutations = [Collections.Generic.List[object]]::new()
    $bad = [byte[]]$valid.Clone(); $bad[0] = $bad[0] -bxor 1; $mutations.Add(@('bad-magic', $bad))
    $bad = [byte[]]$valid.Clone(); $bad[32] = $bad[32] -bxor 1; $mutations.Add(@('bad-header-crc', $bad))
    $bad = [byte[]]$valid.Clone(); $bad[-1] = $bad[-1] -bxor 128; $mutations.Add(@('bad-payload-crc', $bad))
    $mutations.Add(@('truncated-header', [byte[]]$valid[0..30]))
    $mutations.Add(@('truncated-payload', [byte[]]$valid[0..($valid.Length - 2)]))
    $mutations.Add(@('trailing-byte', [byte[]]($valid + [byte[]]@(0))))
    $bad = [byte[]]$valid.Clone(); Set-U32 $bad 12 ([uint32]::MaxValue); Repair-Header $bad; $mutations.Add(@('bad-primary-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); Set-U32 $bad 8 8388609; Repair-Header $bad; $mutations.Add(@('oversize-plain-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); Set-U32 $bad 8 ([uint32]::MaxValue); Repair-Header $bad; $mutations.Add(@('overflow-plain-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); Set-U32 $bad 20 ([uint32]::MaxValue); Repair-Header $bad; $mutations.Add(@('overflow-payload-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); Set-U32 $bad 24 ([BitConverter]::ToUInt32($bad,24) -bxor [uint32]1); Repair-Header $bad; $mutations.Add(@('bad-plain-crc-valid-header', $bad))
    $bad = [byte[]]$valid.Clone(); $bad[68] = $bad[68] -bor 128; Repair-Header $bad; $mutations.Add(@('bitmap-padding-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); for($i=69;$i -lt 281;$i++) { $bad[$i] = 255 }; Repair-Header $bad; $mutations.Add(@('rank-overflow-valid-crc', $bad))
    $bad = [byte[]]($valid[0..279] + $valid[281..($valid.Length-1)]); Repair-Header $bad 244; $mutations.Add(@('rank-width-valid-crc', $bad))
    foreach($invalidCount in @([uint32]0,[uint32]258,[uint32]::MaxValue)) {
        $bad = [byte[]]$valid.Clone(); Set-U32 $bad 16 $invalidCount; Repair-Header $bad 245
        $mutations.Add(@("alphabet-count-$invalidCount-valid-crc", $bad))
    }
    $bad = [byte[]]$valid.Clone(); $bad[36] = $bad[36] -band 254; Repair-Header $bad; $mutations.Add(@('missing-sentinel-valid-crc', $bad))
    # k2とk3は順位幅1 byteが同じ。正準tableを通った後のcount不一致も検査する。
    $bad = [IO.File]::ReadAllBytes((Join-Path $work 'single.frame'))
    $smallCount = [BitConverter]::ToUInt32($bad,16)
    if ($smallCount -ne 2) { throw 'Single-byte alphabet contract mismatch.' }
    Set-U32 $bad 16 3; Repair-Header $bad; $mutations.Add(@('bitmap-count-mismatch-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); $start = 36 + (Get-MetadataBytes $alphabetCount)
    $bad[$start] = 1; Set-U32 $bad 28 (Get-Crc ([byte[]]$bad[$start..($bad.Length - 1)])); Repair-Header $bad; $mutations.Add(@('bad-range-prefix-valid-crc', $bad))
    $bad = [byte[]]$valid.Clone(); $bad[-1] = $bad[-1] -bxor 1
    Set-U32 $bad 28 (Get-Crc ([byte[]]$bad[$start..($bad.Length - 1)])); Repair-Header $bad; $mutations.Add(@('altered-range-bit-valid-crc', $bad))
    $bad = [IO.File]::ReadAllBytes((Join-Path $work 'empty.frame'))
    if ($bad[-1] -eq 255) { throw 'Empty range lower-bound fixture unexpectedly ends at 255.' }
    $bad[-1]++; $emptyStart = 36 + (Get-MetadataBytes ([BitConverter]::ToUInt32($bad,16)))
    Set-U32 $bad 28 (Get-Crc ([byte[]]$bad[$emptyStart..($bad.Length-1)])); Repair-Header $bad; $mutations.Add(@('bad-range-termination-valid-crc', $bad))
    $bad = [byte[]]($valid + [byte[]]@(0)); Set-U32 $bad 20 ([BitConverter]::ToUInt32($valid,20)+1)
    Set-U32 $bad 28 (Get-Crc ([byte[]]$bad[$start..($bad.Length-1)])); Repair-Header $bad; $mutations.Add(@('range-trailing-valid-crc', $bad))
    $reasons = @{
        'bad-magic' = 'bad frame magic/header'; 'bad-header-crc' = 'header CRC mismatch'; 'bad-payload-crc' = 'payload CRC mismatch'
        'truncated-header' = 'bad frame magic/header'; 'truncated-payload' = 'header CRC mismatch'; 'trailing-byte' = 'packed header length outside bounds'
        'bad-primary-valid-crc' = 'frame fields outside bounds'; 'oversize-plain-valid-crc' = 'frame fields outside bounds'
        'overflow-plain-valid-crc' = 'frame fields outside bounds'; 'overflow-payload-valid-crc' = 'frame fields outside bounds'
        'bad-plain-crc-valid-header' = 'plain length/CRC mismatch'; 'bitmap-padding-valid-crc' = 'packed alphabet high bitmap padding nonzero'
        'rank-overflow-valid-crc' = 'packed alphabet rank outside factorial'; 'missing-sentinel-valid-crc' = 'packed alphabet sentinel 0 missing'
        'rank-width-valid-crc' = 'packed alphabet rank byte width not canonical'
        'alphabet-count-0-valid-crc' = 'frame fields outside bounds'; 'alphabet-count-258-valid-crc' = 'frame fields outside bounds'
        'alphabet-count-4294967295-valid-crc' = 'frame fields outside bounds'; 'bitmap-count-mismatch-valid-crc' = 'packed alphabet count mismatch'
        'bad-range-prefix-valid-crc' = 'invalid range stream prefix'; 'bad-range-termination-valid-crc' = 'non-canonical range termination'
        'altered-range-bit-valid-crc' = 'truncated range stream'; 'range-trailing-valid-crc' = 'trailing bytes in range stream'
    }
    foreach ($mutation in $mutations) { $path = Join-Path $work "$($mutation[0]).frame"; Write-New $path $mutation[1]; Assert-Rejected $mutation[0] 'decode' $path $reasons[$mutation[0]] }
    $oversize = Join-Path $work 'oversize.input'
    $stream = [IO.File]::Open($oversize, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.SetLength(8388609) } finally { $stream.Dispose() }; $owned.Add($oversize)
    Assert-Rejected 'oversize-input' 'encode' $oversize 'input is not a regular file within limit'
    Assert-Rejected 'missing-input-encode' 'encode' (Join-Path $work 'does-not-exist') 'input open:'
    Assert-Rejected 'missing-input-decode' 'decode' (Join-Path $work 'does-not-exist') 'input open:'
    foreach ($operation in @('encode', 'decode')) {
        $existing = Join-Path $work "$operation-existing-output"; Write-New $existing ([byte[]]@(31,41,59,26))
        $before = Get-Identity $existing
        $input = if ($operation -ceq 'encode') { Join-Path $work 'single.input' } else { Join-Path $work 'single.frame' }
        $null = Invoke-Cli "$operation-overwrite" @($operation, $input, $existing) 1
        $after = Get-Identity $existing
        if ($before.sha256 -cne $after.sha256 -or $before.bytes -ne $after.bytes) { throw 'Existing output changed.' }
        Add-Check "$operation-no-clobber" ([pscustomobject]@{ before = $before; after = $after })
    }
    foreach ($row in $identities) {
        $after = Get-Identity $row.path; $row.after_bytes = $after.bytes; $row.after_sha256 = $after.sha256
        if ($row.before_bytes -ne $row.after_bytes -or $row.before_sha256 -cne $row.after_sha256) { throw "Provenance changed: $($row.role)" }
    }
    $report.status = if ($report.fixed_size_gate_passed) { 'correctness_and_size_passed_not_timed' } else { 'correctness_passed_size_no_go' }
} catch { $report.error = $_.Exception.ToString(); $failure = $_ }
finally {
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    $reportPath = Join-Path $work 'report.json'
    Write-New $reportPath ([Text.UTF8Encoding]::new($false).GetBytes(($report | ConvertTo-Json -Depth 12)))
}
if ($null -ne $failure) { throw $failure }
Write-Host "E2E $($report.status): $($checks.Count) checks; $($invocations.Count) CLI invocations; $($report.fixed_candidate.bytes) bytes; report=$reportPath"
