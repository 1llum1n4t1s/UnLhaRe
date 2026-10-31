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
    'experiments/khc/causal-bayes-q32-mixture-reuse/cts_model.rs' = 'BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2'
    'experiments/khc/causal-bayes-q32-mixture-reuse/audit_cli.rs' = '9E12278CCA39B0163228DD785A59D56FD5BEAE5FC41F3F43AD73F68D353E225E'
    'experiments/khc/causal-bayes-q32-mixture-reuse/verify-numeric.ps1' = 'F106178317D9DAD39B714AA32F870B4FFB7BBF6C5B44453EA219183DA3C7D87B'
    'experiments/khc/causal-bayes-q32-split-lut/build.ps1' = '61252518210E7B575AC922F7735A62F839558D99F5FDDDE876604CFFF1A4F6F6'
    'experiments/khc/causal-bayes-q32-split-lut/verify.ps1' = '57A80259A9588EE87F170669086C1B2AB3C449D447E88C2F963E0C7F064F34E4'
    'experiments/khc/Q32_MIXTURE_REUSE_CONTRACT_20261001.md' = '21BE83C2C93096FE232BDC9127951B091C72D764AC52A31DDAA06422111002D8'
    'build/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json' = 'BFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72'
    'build/khc-bwt-causal-bayes-q32-split-lut-20261001/build-report.json' = '01033D6D34993471C6063F9FB565B0A63AA7023AC4906DC91499F057E60941EC'
    'build/khc-bwt-causal-bayes-q32-split-lut-20261001/full-e2e/report.json' = 'FCCB873D7A29EC8FAB332D4075DC94AD18CA960193BF9C7FBEE97FE723E5924C'
    'build/khc-bwt-causal-bayes-q32-split-lut-20261001/candidate.exe' = '471E62E5F804C74A498B266C458239C4B16A242172AF3B455CA0D5D8FB279D1C'
    'build/khc-bwt-causal-bayes-q32-split-lut-20261001/full-e2e/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'

    'experiments/khc/causal-bayes-q32-split-lut/codec.rs' = '9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    'experiments/khc/causal-bayes-q32-split-lut/cts_model.rs' = '87AD15A78B390FA3F34A2ED6C36DD19CEAC05E4B3D29979207BA9A11B52393EA'
    'experiments/khc/causal-bayes-q32-corrected-lut-inline/build.ps1' = 'A6D3C5DDA6C237367E3EA9C520851B5AF13256EABF08F3B83FB9DC0BD97194D3'
    'experiments/khc/causal-bayes-q32-corrected-lut-inline/verify.ps1' = '36BB185E92E994A0B4049B1DB255E1A0C422C329E3B857E71F5F2CF25B048D24'
    'experiments/khc/split-estimate-quotient/exact_div.rs' = 'D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'
    'experiments/khc/split-estimate-quotient/audit_cli.rs' = '9DEAE4E323413DEFA8F3FC4574C6ACF722B04A260DBF8CE8D649582A5E76C048'
    'experiments/khc/split-estimate-quotient/verify.ps1' = 'A8990B229AC8207E7741F4C85342AF81AC81E1D06B0D0DA5EE955B16AA609426'
    'build/khc-split-estimate-quotient-20261001/report.json' = '03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/candidate.exe' = '02C7D3D132DFD664CEA7BE643CDB0A5200583D5583AE101C715CC59FEF703083'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/build-report.json' = 'A5D6ADDCC64B09AFA820A80ABA85E90AEEA3CD1F9D02B112C0D949F69621B4D8'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/full-e2e/report.json' = '61B1AE66494F5AFE801B9DDDF55A583071E6E3C5C63683410A19970F290683E4'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/full-e2e/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
    'experiments/khc/causal-bayes-q32-corrected-lut-inline/codec.rs' = '9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    'experiments/khc/causal-bayes-q32-corrected-lut-inline/cts_model.rs' = '86FABD5061CA3187AB82F63A6D331CE1C91D21DB0F5E61A2D5A19B708E4810FE'
    'experiments/khc/causal-bayes-q32-corrected-lut-inline/exact_div.rs' = '1A82EDBCA1616C3F52F0855ADC449BA1468E4E5F3E1C2031EF254F43B4659BF1'
    'experiments/khc/Q32_INLINE_CONTRACT_20261001.md' = '1095D1B7548D73A411271B58A369C10259F0F0178EBE16C9010F5339897EDFA5'
    'experiments/khc/causal-bayes-q32-corrected-lut/codec.rs' = '54C3A877913FAF5E72486E21552DCA85D39803C88A56DEAA5655AC83397BA74C'
    'experiments/khc/causal-bayes-q32-corrected-lut/build.ps1' = '98E005EE1C62FF145CB758CA46FB3FAC90FE685FB5B2EFB2ABDF003319A4BC71'
    'experiments/khc/causal-bayes-q32-corrected-lut/verify.ps1' = '283195E75A2E8258F874F06D0B3D280C875F2289B6919D23DD202F44BBEEF0CF'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/build-report.json' = '6BBB273BD3D4907EF51B568A86A873403BC208D12B06F236FE8A415A1382FEAC'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/full-e2e/report.json' = '934C03B54DBCC1B82CC1ADF52820BC94425240D3E37F77A91DFBD389D1AFB93C'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/candidate.exe' = 'A3981BC785F0DC3F5882EED62F49DC12C4911FD045773AEC6646417E3BCD2010'
    'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/full-e2e/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'

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
    'experiments/khc/causal-bayes-q32-corrected/codec.rs' = 'A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    'experiments/khc/causal-bayes-q32-corrected/cts_model.rs' = 'DC876ED9B5B7FDB921A8522FA214FA80A76C317FD8F7BB6AC297DAF175ABF99B'
    'experiments/khc/causal-bayes-q32-corrected/build.ps1' = 'B051B71526232075D7475BD362A006CAEAE47B5014A933814F83D5B0115DD56D'
    'experiments/khc/causal-bayes-q32-corrected/verify.ps1' = 'BD55C3E29541B37E8673198D9BC5930B677724FE19F1F1D6B1CB1588D281C574'
    'experiments/khc/causal-bayes-log-table/bayes_model.rs' = 'E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
    'experiments/khc/Q32_CORRECTED_LUT_CONTRACT_20261001.md' = 'AA25BC09DC001113373256E104CDD22AC90E89182F3E5AD1BF04A24B9D639248'
    'build/khc-bwt-causal-bayes-q32-corrected-20261001/build-report.json' = '150B2D5171A1091976D5C19BBF634C3E0FFDEADD50B7BD7E9412B70147966C93'
    'build/khc-bwt-causal-bayes-q32-corrected-20261001/full-e2e/report.json' = 'EE6864D3DB72A5175AF89A90C36847441AA1BAEE462AD42A2C887FD614C14BAB'
    'build/khc-bwt-causal-bayes-q32-corrected-20261001/candidate.exe' = 'FC44562A23B61A6FD38FCE305B285185F82CB7D9CB0109E2E320CFDEEBF8027F'
    'build/khc-bwt-causal-bayes-q32-corrected-20261001/full-e2e/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/report.json' = 'F09A9C963A823D32FDA1A8943896FA6704CC5175F813623AF1433896806A327A'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/cleanup.json' = '3ACCEFD3485C8EE3ED402473744B803513D27875C3321B214ADB4286F622D31A'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/maximum.input' = 'AC02E3CC0EBA0A8B8FB403267313B10CF18581E5F2CE077C817B8DE39E2F9AD6'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/maximum-direct-0.output' = 'FE8006C00E791A6FD5996A5BD6715526FCD93A3C31CFA9056D5F8264A69B47E0'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/maximum-table-0.output' = 'FE8006C00E791A6FD5996A5BD6715526FCD93A3C31CFA9056D5F8264A69B47E0'
    'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/maximum-table-opt2-0.output' = 'FE8006C00E791A6FD5996A5BD6715526FCD93A3C31CFA9056D5F8264A69B47E0'
    'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
}

function Assert-BytesEqual([string]$Left, [string]$Right) {
    $a = [IO.File]::ReadAllBytes($Left); $b = [IO.File]::ReadAllBytes($Right)
    if ($a.Length -ne $b.Length) { throw "Byte length mismatch: $Left / $Right" }
    if ((Get-FileHash -LiteralPath $Left).Hash -cne (Get-FileHash -LiteralPath $Right).Hash) { throw "SHA mismatch: $Left / $Right" }
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
    $frozenCorrected = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-20261001/candidate.exe') 'frozen-corrected-q32'
    $frozenCorrectedFixed = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-20261001/full-e2e/fixed.frame') 'frozen-corrected-fixed'
    $frozenLut = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/candidate.exe') 'frozen-lut-q32'
    $frozenLutFixed = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/full-e2e/fixed.frame') 'frozen-lut-fixed'
    $lutProof = Get-Content -LiteralPath (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/full-e2e/report.json') -Raw | ConvertFrom-Json
    if ($lutProof.checks.Count -ne 55 -or @($lutProof.checks | Where-Object { -not $_.passed }).Count -ne 0 -or $lutProof.status -cne 'correctness_and_size_passed_not_timed') { throw 'Invalid frozen LUT E2E proof.' }
    $frozenInline = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/candidate.exe') 'frozen-inline-q32'
    $frozenInlineFixed = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/full-e2e/fixed.frame') 'frozen-inline-fixed'
    $inlineProof = Get-Content -LiteralPath (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/full-e2e/report.json') -Raw | ConvertFrom-Json
    if ($inlineProof.checks.Count -ne 63 -or $inlineProof.invocations.Count -ne 106 -or @($inlineProof.checks | Where-Object { -not $_.passed }).Count -ne 0 -or $inlineProof.status -cne 'correctness_and_size_passed_not_timed') { throw 'Invalid frozen inline E2E proof.' }
    $splitProof = Get-Content -LiteralPath (Join-Path $root 'build/khc-split-estimate-quotient-20261001/report.json') -Raw | ConvertFrom-Json
    if ($splitProof.status -cne 'verified' -or $splitProof.checks.Count -ne 47 -or $splitProof.invocations.Count -ne 31 -or @($splitProof.checks | Where-Object { -not $_.passed }).Count -ne 0 -or @($splitProof.invocations | Where-Object { $_.exit -ne $_.expected_exit }).Count -ne 0) { throw 'Invalid frozen split numeric proof.' }

    $mixtureNumeric = Get-Content -LiteralPath (Join-Path $root 'build/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json') -Raw | ConvertFrom-Json
    if($mixtureNumeric.status -cne 'verified' -or $mixtureNumeric.timing_used -or $mixtureNumeric.checks.Count -ne 99 -or $mixtureNumeric.invocations.Count -ne 103 -or $mixtureNumeric.counts[0] -ne 65536 -or $mixtureNumeric.model_history.records -ne 11267 -or $mixtureNumeric.model_history.classes -ne 7 -or $mixtureNumeric.model_history.levels -ne 17 -or @($mixtureNumeric.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($mixtureNumeric.invocations|Where-Object {$_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Mixture numeric proof incomplete.'}
    foreach($id in $mixtureNumeric.identities){
        $current=Lock-Identity $id.path 'mixture-numeric-evidence'
        if($id.before_sha256 -cne $id.after_sha256 -or $id.before_bytes -ne $id.after_bytes -or $current.before_sha256 -cne $id.before_sha256 -or $current.before_bytes -ne $id.before_bytes){throw 'Mixture numeric evidence changed.'}
    }
    $frozenSplit = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-split-lut-20261001/candidate.exe') 'frozen-split-q32'
    $frozenSplitFixed = Lock-Identity (Join-Path $root 'build/khc-bwt-causal-bayes-q32-split-lut-20261001/full-e2e/fixed.frame') 'frozen-split-fixed'
    $splitFullProof = Get-Content -LiteralPath (Join-Path $root 'build/khc-bwt-causal-bayes-q32-split-lut-20261001/full-e2e/report.json') -Raw | ConvertFrom-Json
    if($splitFullProof.status -cne 'correctness_and_size_passed_not_timed' -or $splitFullProof.checks.Count -ne 71 -or $splitFullProof.invocations.Count -ne 130 -or @($splitFullProof.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($splitFullProof.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Frozen split full proof incomplete.'}
    $report['split_numeric_proof_reused'] = [pscustomobject]@{ checks=47; cli=31; timing_used=$false; sha256=$pins['build/khc-split-estimate-quotient-20261001/report.json'] }
    $numericRoot = Join-Path $root 'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e'
    $numericProof = Get-Content -LiteralPath (Join-Path $numericRoot 'report.json') -Raw | ConvertFrom-Json
    $cleanup = Get-Content -LiteralPath (Join-Path $numericRoot 'cleanup.json') -Raw | ConvertFrom-Json
    if ($numericProof.status -cne 'verified' -or $numericProof.checks.Count -ne 52 -or $numericProof.invocations.Count -ne 52 -or $numericProof.all_q15_values_both_bits -ne 65534 -or @($numericProof.checks | Where-Object { -not $_.passed }).Count -ne 0) { throw 'Invalid retained LUT numeric proof.' }
    if ($cleanup.removed_files -ne 12 -or $cleanup.target_residual_count -ne 0 -or -not $cleanup.retained_report_unchanged -or -not $cleanup.identical_bytes_retained_at_round_zero -or $cleanup.retained_report_sha256 -cne 'F09A9C963A823D32FDA1A8943896FA6704CC5175F813623AF1433896806A327A') { throw 'Invalid retained numeric cleanup receipt.' }
    foreach ($name in @('maximum.input','maximum-direct-0.output','maximum-table-0.output','maximum-table-opt2-0.output')) {
        $rawPath = Join-Path $numericRoot $name
        $raw = Get-Identity $rawPath
        $saved = @($cleanup.retained_files | Where-Object { $_.path -ceq $raw.path })
        if ($saved.Count -ne 1 -or $saved[0].bytes -ne $raw.bytes -or $saved[0].sha256 -cne $raw.sha256) { throw 'Retained maximum raw differs from cleanup receipt.' }
        $observations = @($numericProof.checks | Where-Object { $_.name -in @('maximum-direct-0','maximum-table-0','maximum-table-opt2-0') })
        if ($observations.Count -ne 3) { throw 'Missing retained maximum numeric checks.' }
        foreach ($observation in $observations) {
            $savedRaw = if ($name -ceq 'maximum.input') { $observation.evidence.input } else { $observation.evidence.output }
            if ($observation.evidence.observations -ne 65536 -or $savedRaw.bytes -ne $raw.bytes -or $savedRaw.sha256 -cne $raw.sha256) { throw 'Maximum raw differs from numeric report.' }
        }
    }
    Assert-BytesEqual (Join-Path $numericRoot 'maximum-direct-0.output') (Join-Path $numericRoot 'maximum-table-0.output')
    Assert-BytesEqual (Join-Path $numericRoot 'maximum-direct-0.output') (Join-Path $numericRoot 'maximum-table-opt2-0.output')
    foreach ($removed in $cleanup.targets) {
        $roundZero = $removed.path.Replace('-1.output','-0.output')
        $retained = @($cleanup.retained_files | Where-Object { $_.path -ceq $roundZero })
        if ($retained.Count -ne 1 -or $retained[0].bytes -ne $removed.bytes -or $retained[0].sha256 -cne $removed.sha256 -or (Test-Path -LiteralPath $removed.path)) { throw 'Numeric cleanup duplicate correspondence mismatch.' }
    }
    Add-Check 'bounded-retained-lut-numeric-proof-reuse' ([pscustomobject]@{ old_checks=52; old_cli=52; reused_cli_executed=0; all_q15_values_both_bits=65534; maximum_records=65536; maximum_input_bytes=393216; maximum_output_bytes=1179648; raw_full_byte_equality=$true; removed_round_one_duplicates=12; deleted_raw_readlocked=$false; scope='Existing Windows x64 Rust 1.98.1 proof only; other OS/libm unverified.' })
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
    foreach ($name in @('../causal-bayes-sais/bwt.rs','../causal-bayes-q32-corrected/cts_model.rs','cts_model.rs','../split-estimate-quotient/exact_div.rs','../Q32_INLINE_CONTRACT_20261001.md','../causal-bayes-log-table/bayes_model.rs','../rejected-binary-mix/packed_alphabet.rs','../CAUSAL_BAYES_Q32_CONTRACT_20260930.md')) { $null = Lock-Identity (Join-Path $PSScriptRoot $name) $name }
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
        $frozenFrame = Join-Path $work "$name.frozen-corrected.frame"
        $frozenEncoded = Invoke-Cli "$name-frozen-corrected-encode" @('encode', $input, $frozenFrame) 0 $frozenCorrected.path
        Assert-BytesEqual $frame $frozenFrame
        $frozenLutFrame = Join-Path $work "$name.frozen-lut.frame"
        $frozenLutEncoded = Invoke-Cli "$name-frozen-lut-encode" @('encode',$input,$frozenLutFrame) 0 $frozenLut.path
        $frozenLutDecoded = Invoke-Cli "$name-frozen-lut-decode-inline" @('decode',$frame,(Join-Path $work "$name.frozen-lut.restored")) 0 $frozenLut.path
        $inlineDecoded = Invoke-Cli "$name-inline-decode-frozen-lut" @('decode',$frozenLutFrame,(Join-Path $work "$name.inline-from-lut.restored")) 0
        Assert-BytesEqual $frame $frozenLutFrame
        Assert-BytesEqual $input $frozenLutDecoded.output.path
        Assert-BytesEqual $input $inlineDecoded.output.path
        Add-Check "$name-frozen-lut-full-byte-equality-and-cross-decode" ([pscustomobject]@{ frozen=$frozenLutEncoded.output; inline=$encoded.output; frozen_decode=$frozenLutDecoded.output; inline_decode=$inlineDecoded.output; raw_full_byte_equality=$true })
        $frozenInlineFrame = Join-Path $work "$name.frozen-inline.frame"
        $frozenInlineEncoded = Invoke-Cli "$name-frozen-inline-encode" @('encode',$input,$frozenInlineFrame) 0 $frozenInline.path
        $frozenInlineDecoded = Invoke-Cli "$name-frozen-inline-decode-split" @('decode',$frame,(Join-Path $work "$name.frozen-inline.restored")) 0 $frozenInline.path
        $splitDecoded = Invoke-Cli "$name-split-decode-frozen-inline" @('decode',$frozenInlineFrame,(Join-Path $work "$name.split-from-inline.restored")) 0
        Assert-BytesEqual $frame $frozenInlineFrame
        Assert-BytesEqual $input $frozenInlineDecoded.output.path
        Assert-BytesEqual $input $splitDecoded.output.path
        Add-Check "$name-frozen-inline-full-byte-equality-and-cross-decode" ([pscustomobject]@{ frozen=$frozenInlineEncoded.output; split=$encoded.output; frozen_decode=$frozenInlineDecoded.output; split_decode=$splitDecoded.output; raw_full_byte_equality=$true })

        $frozenSplitFrame = Join-Path $work "$name.frozen-split.frame"
        $frozenSplitEncoded = Invoke-Cli "$name-frozen-split-encode" @('encode',$input,$frozenSplitFrame) 0 $frozenSplit.path
        $frozenSplitDecoded = Invoke-Cli "$name-frozen-split-decode-mixture" @('decode',$frame,(Join-Path $work "$name.frozen-split.restored")) 0 $frozenSplit.path
        $mixtureDecoded = Invoke-Cli "$name-mixture-decode-frozen-split" @('decode',$frozenSplitFrame,(Join-Path $work "$name.mixture-from-split.restored")) 0
        Assert-BytesEqual $frame $frozenSplitFrame
        Assert-BytesEqual $input $frozenSplitDecoded.output.path
        Assert-BytesEqual $input $mixtureDecoded.output.path
        Add-Check "$name-frozen-split-full-byte-equality-and-cross-decode" ([pscustomobject]@{ frozen=$frozenSplitEncoded.output; mixture=$encoded.output; frozen_decode=$frozenSplitDecoded.output; mixture_decode=$mixtureDecoded.output; raw_full_byte_equality=$true })
        Add-Check "$name-frozen-corrected-full-byte-equality" ([pscustomobject]@{ corrected=$frozenEncoded.output; lut=$encoded.output })
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
    $frozenEncoded = Invoke-Cli 'fixed-frozen-corrected-encode' @('encode',$fixedInput,(Join-Path $work 'fixed.frozen-corrected.frame')) 0 $frozenCorrected.path
    Assert-BytesEqual $fixedFrame $frozenEncoded.output.path
    Assert-BytesEqual $fixedFrame $frozenCorrectedFixed.path
    $frozenDecode = Invoke-Cli 'frozen-corrected-decode-lut-fixed' @('decode',$fixedFrame,(Join-Path $work 'fixed.frozen-corrected.restored.group')) 0 $frozenCorrected.path
    $lutDecode = Invoke-Cli 'lut-decode-frozen-corrected-fixed' @('decode',$frozenCorrectedFixed.path,(Join-Path $work 'frozen-corrected.lut.restored.group')) 0
    Assert-BytesEqual $fixedInput $frozenDecode.output.path
    Assert-BytesEqual $fixedInput $lutDecode.output.path
    Add-Check 'frozen-corrected-fixed-full-byte-equality-and-cross-decode' ([pscustomobject]@{ frozen_frame=$frozenCorrectedFixed; fresh_frozen_frame=$frozenEncoded.output; lut_frame=$encoded.output; frozen_decode=$frozenDecode.output; lut_decode=$lutDecode.output })
    $frozenLutEncoded = Invoke-Cli 'fixed-frozen-lut-encode' @('encode',$fixedInput,(Join-Path $work 'fixed.frozen-lut.frame')) 0 $frozenLut.path
    $frozenLutDecoded = Invoke-Cli 'fixed-frozen-lut-decode-inline' @('decode',$fixedFrame,(Join-Path $work 'fixed.frozen-lut.restored.group')) 0 $frozenLut.path
    $inlineDecoded = Invoke-Cli 'fixed-inline-decode-frozen-lut' @('decode',$frozenLutFixed.path,(Join-Path $work 'fixed.inline-from-lut.restored.group')) 0
    Assert-BytesEqual $fixedFrame $frozenLutEncoded.output.path
    Assert-BytesEqual $fixedFrame $frozenLutFixed.path
    Assert-BytesEqual $fixedInput $frozenLutDecoded.output.path
    Assert-BytesEqual $fixedInput $inlineDecoded.output.path
    Add-Check 'fixed-frozen-lut-full-byte-equality-and-cross-decode' ([pscustomobject]@{ frozen_frame=$frozenLutFixed; fresh_frozen_frame=$frozenLutEncoded.output; inline_frame=$encoded.output; frozen_decode=$frozenLutDecoded.output; inline_decode=$inlineDecoded.output; raw_full_byte_equality=$true })
    foreach ($oldCheck in $lutProof.checks) {
        if (@($checks | Where-Object { $_.name -ceq $oldCheck.name }).Count -gt 1) { throw 'Duplicate inherited check name.' }
    }
    $frozenInlineEncoded = Invoke-Cli 'fixed-frozen-inline-encode' @('encode',$fixedInput,(Join-Path $work 'fixed.frozen-inline.frame')) 0 $frozenInline.path
    $frozenInlineDecoded = Invoke-Cli 'fixed-frozen-inline-decode-split' @('decode',$fixedFrame,(Join-Path $work 'fixed.frozen-inline.restored.group')) 0 $frozenInline.path
    $splitDecoded = Invoke-Cli 'fixed-split-decode-frozen-inline' @('decode',$frozenInlineFixed.path,(Join-Path $work 'fixed.split-from-inline.restored.group')) 0
    Assert-BytesEqual $fixedFrame $frozenInlineEncoded.output.path
    Assert-BytesEqual $fixedFrame $frozenInlineFixed.path
    Assert-BytesEqual $fixedInput $frozenInlineDecoded.output.path
    Assert-BytesEqual $fixedInput $splitDecoded.output.path
    Add-Check 'fixed-frozen-inline-full-byte-equality-and-cross-decode' ([pscustomobject]@{ frozen_frame=$frozenInlineFixed; fresh_frozen_frame=$frozenInlineEncoded.output; split_frame=$encoded.output; frozen_decode=$frozenInlineDecoded.output; split_decode=$splitDecoded.output; raw_full_byte_equality=$true })

    $frozenSplitEncoded = Invoke-Cli 'fixed-frozen-split-encode' @('encode',$fixedInput,(Join-Path $work 'fixed.frozen-split.frame')) 0 $frozenSplit.path
    $frozenSplitDecoded = Invoke-Cli 'fixed-frozen-split-decode-mixture' @('decode',$fixedFrame,(Join-Path $work 'fixed.frozen-split.restored.group')) 0 $frozenSplit.path
    $mixtureDecoded = Invoke-Cli 'fixed-mixture-decode-frozen-split' @('decode',$frozenSplitFixed.path,(Join-Path $work 'fixed.mixture-from-split.restored.group')) 0
    Assert-BytesEqual $fixedFrame $frozenSplitEncoded.output.path
    Assert-BytesEqual $fixedFrame $frozenSplitFixed.path
    Assert-BytesEqual $fixedInput $frozenSplitDecoded.output.path
    Assert-BytesEqual $fixedInput $mixtureDecoded.output.path
    Add-Check 'fixed-frozen-split-full-byte-equality-and-cross-decode' ([pscustomobject]@{ frozen_frame=$frozenSplitFixed; fresh_frozen_frame=$frozenSplitEncoded.output; mixture_frame=$encoded.output; frozen_decode=$frozenSplitDecoded.output; mixture_decode=$mixtureDecoded.output; raw_full_byte_equality=$true })
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
    foreach ($oldCheck in $lutProof.checks) {
        if (@($checks | Where-Object { $_.name -ceq $oldCheck.name -and $_.passed }).Count -ne 1) { throw "Missing inherited LUT check: $($oldCheck.name)" }
    }
    foreach ($oldCheck in $inlineProof.checks) {
        if (@($checks | Where-Object { $_.name -ceq $oldCheck.name -and $_.passed }).Count -ne 1) { throw "Missing inherited inline check: $($oldCheck.name)" }
    }

    foreach($oldCheck in $splitFullProof.checks){
        if(@($checks|Where-Object {$_.name -ceq $oldCheck.name -and $_.passed}).Count -ne 1){throw "Missing inherited split check: $($oldCheck.name)"}
    }
    $report['inherited_split_checks']=$splitFullProof.checks.Count
    $report['additional_split_cross_checks']=8
    $temporaryFiles = @(Get-ChildItem -LiteralPath $work -Force -File | Where-Object { $_.Name.EndsWith('.tmp', [StringComparison]::Ordinal) })
    if ($temporaryFiles.Count -ne 0) { throw 'Owned codec temporary files remain.' }
    if ($checks.Count -ne 79 -or $invocations.Count -ne 154) { throw 'Unexpected mixture E2E coverage counts.' }
    $report['inherited_inline_checks'] = $inlineProof.checks.Count
    $report['additional_inline_cross_checks'] = 8
    $report['owned_tmp_count'] = $temporaryFiles.Count
    $report['inherited_lut_checks'] = $lutProof.checks.Count
    $report['additional_lut_cross_checks'] = 8
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
