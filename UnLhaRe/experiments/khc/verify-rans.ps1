param(
    [Parameter(Mandatory)][string]$LabPath,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# 失敗条件: 往復/決定性不一致、境界長の失敗、不正入力の受理・panic・部分stdout、診断の誤ったbackend受理。
# 既存CLIを別プロセスとして実行し、成功時は再現用reportだけを保持する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $sourceRoot 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (-not $work.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and
            (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse point is not allowed: $current"
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
Assert-NoReparse $work
$lab = (Resolve-Path -LiteralPath $LabPath).Path
$group = (Resolve-Path -LiteralPath $GroupPath).Path
Assert-NoReparse $lab
Assert-NoReparse $group
$labHash = (Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash
$groupHash = (Get-FileHash -LiteralPath $group -Algorithm SHA256).Hash
if ($groupHash -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76') { throw 'Unexpected group.' }
$null = New-Item -ItemType Directory -Path $work
$plainPath = Join-Path $work 'input.bin'
$framePath = Join-Path $work 'frame.khc'
$badPath = Join-Path $work 'invalid.khc'
$rows = [Collections.Generic.List[object]]::new()
$success = $false
Add-Type -TypeDefinition @'
using System;
public static class KhcRansFixture {
    public static byte[] Pattern(int length) {
        var result = new byte[length];
        for (int i = 0; i < length; i++) result[i] = (byte)(i % 251);
        return result;
    }
    public static byte[] Alphabet16(int length) {
        var result = new byte[length];
        var random = new Random(7103);
        for (int i = 0; i < length; i++) result[i] = (byte)random.Next(16);
        return result;
    }
    public static uint HeaderCrc(byte[] frame) {
        uint crc = uint.MaxValue;
        for (int i = 0; i < 36; i++) {
            crc ^= frame[i];
            for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320u : 0u);
        }
        return ~crc;
    }
    public static byte[] Set32(byte[] source, int offset, uint value) {
        var result = (byte[])source.Clone();
        BitConverter.GetBytes(value).CopyTo(result, offset);
        return result;
    }
    public static byte[] Resize(byte[] source, int length) {
        var result = new byte[length];
        Array.Copy(source, result, Math.Min(source.Length, length));
        FixHeader(result);
        return result;
    }
    public static byte[] Insert(byte[] source, int offset) {
        var result = new byte[source.Length + 1];
        Array.Copy(source, result, offset);
        Array.Copy(source, offset, result, offset + 1, source.Length - offset);
        FixHeader(result);
        return result;
    }
    public static void FixHeader(byte[] frame) {
        if (frame.Length < 40) return;
        BitConverter.GetBytes((ulong)(frame.Length - 40)).CopyTo(frame, 24);
        BitConverter.GetBytes(HeaderCrc(frame)).CopyTo(frame, 36);
    }
}
'@

function Invoke-Lab([string]$Mode, [string]$Path, [string]$Backend = 'rans') {
    $info = [Diagnostics.ProcessStartInfo]::new($lab)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in @($Mode, $Path, '--algorithm', 'beam', '--beam-width', '2', '--beam-block', '8192',
        '--beam-model', 'blended', '--beam-matches', 'bt5', '--dictionary-mib', '64', '--entropy-backend', $Backend)) {
        $info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $sink = [IO.MemoryStream]::new()
    $started = $false
    $outputTask = $null
    $errorTask = $null
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Lab start failed.' }
        $outputTask = $process.StandardOutput.BaseStream.CopyToAsync($sink)
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { throw 'Lab exceeded 30 second deadline.' }
        $null = $outputTask.GetAwaiter().GetResult()
        $stderr = $errorTask.GetAwaiter().GetResult()
        return [pscustomobject]@{ exit_code = $process.ExitCode; bytes = $sink.ToArray(); stderr = $stderr }
    }
    finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        if ($null -ne $outputTask) { try { $null = $outputTask.GetAwaiter().GetResult() } catch { } }
        if ($null -ne $errorTask) { try { $null = $errorTask.GetAwaiter().GetResult() } catch { } }
        $sink.Dispose()
        $process.Dispose()
    }
}
function Get-BytesHash([byte[]]$Bytes) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)) }
function Test-Healthy([string]$Name, [byte[]]$Plain) {
    [IO.File]::WriteAllBytes($plainPath, $Plain)
    $encoded = Invoke-Lab 'encode' $plainPath
    if ($encoded.exit_code -ne 0) { throw "$Name encode: $($encoded.stderr)" }
    $again = Invoke-Lab 'encode' $plainPath
    if ($again.exit_code -ne 0 -or (Get-BytesHash $encoded.bytes) -cne (Get-BytesHash $again.bytes)) { throw "$Name nondeterministic" }
    [IO.File]::WriteAllBytes($framePath, $encoded.bytes)
    $decoded = Invoke-Lab 'decode' $framePath
    if ($decoded.exit_code -ne 0 -or $decoded.bytes.Length -ne $Plain.Length -or
        (Get-BytesHash $decoded.bytes) -cne (Get-BytesHash $Plain)) { throw "$Name round-trip: $($decoded.stderr)" }
    $rows.Add([pscustomobject]@{ case = $Name; accepted = $true; input_bytes = $Plain.Length; frame_bytes = $encoded.bytes.Length; frame_sha256 = Get-BytesHash $encoded.bytes; mode = $encoded.bytes[9] })
}
function Test-Invalid([string]$Name, [byte[]]$Frame, [string]$Backend = 'rans') {
    [IO.File]::WriteAllBytes($badPath, $Frame)
    $result = Invoke-Lab 'decode' $badPath $Backend
    if ($result.exit_code -ne 1 -or $result.bytes.Length -ne 0 -or $result.stderr -notmatch '^Error:') {
        throw "${Name}: expected an ordinary error and no stdout; exit=$($result.exit_code), stderr=$($result.stderr)"
    }
    $rows.Add([pscustomobject]@{ case = $Name; accepted = $false; frame_sha256 = Get-BytesHash $Frame; error = $result.stderr.Trim() })
}

try {
    foreach ($length in @(0, 1, 2, 3, 31, 8191, 8192, 8193, 65535, 65536, 65537, 524287, 524288, 524289, 598017)) {
        Test-Healthy "pattern-$length" ([KhcRansFixture]::Pattern($length))
    }
    Test-Healthy 'zero-524289' ([byte[]]::new(524289))
    $random = [byte[]]::new(65536)
    [Random]::new(7103).NextBytes($random)
    Test-Healthy 'random-65536-seed7103' $random
    # 不圧縮fallbackに逃げず、多数のjournalページと複数segmentの再利用を通す。
    foreach ($length in @(16383, 16384, 16385, 1048577)) {
        Test-Healthy "alphabet16-$length-seed7103" ([KhcRansFixture]::Alphabet16($length))
        if ($rows[$rows.Count - 1].mode -ne 2) { throw 'Alphabet fixture must exercise the entropy codec.' }
    }
    $encoded = Invoke-Lab 'group-encode' $group
    if ($encoded.exit_code -ne 0 -or $encoded.bytes.Length -ne 483197) { throw "Fixed group encode failed: $($encoded.stderr)" }
    $original = $encoded.bytes
    if ([KhcRansFixture]::HeaderCrc($original) -ne [BitConverter]::ToUInt32($original, 36)) { throw 'Fixture header CRC helper disagrees.' }
    [IO.File]::WriteAllBytes($framePath, $original)
    $decoded = Invoke-Lab 'decode' $framePath
    if ($decoded.exit_code -ne 0 -or (Get-BytesHash $decoded.bytes) -cne $groupHash) { throw 'Fixed group round-trip failed.' }
    $rows.Add([pscustomobject]@{ case = 'fixed-group'; accepted = $true; frame_bytes = $original.Length; frame_sha256 = Get-BytesHash $original })
    Test-Invalid 'wrong-backend' $original 'range'
    Test-Invalid 'bad-marker' ([KhcRansFixture]::Set32($original, 40, 0))
    $oversize = [byte[]]$original.Clone()
    [BitConverter]::GetBytes([uint64]67108865).CopyTo($oversize, 16)
    [KhcRansFixture]::FixHeader($oversize)
    Test-Invalid 'output-over-64mib-limit' $oversize
    $oversizeDictionary = [KhcRansFixture]::Set32($original, 12, 67108865)
    [KhcRansFixture]::FixHeader($oversizeDictionary)
    Test-Invalid 'dictionary-over-64mib-limit' $oversizeDictionary
    $segment = 0
    $offset = 44
    while ($offset -lt $original.Length) {
        $plain = [BitConverter]::ToUInt32($original, $offset)
        $packed = [BitConverter]::ToUInt32($original, $offset + 4)
        Test-Invalid "segment-$segment-plain-zero" ([KhcRansFixture]::Set32($original, $offset, 0))
        Test-Invalid "segment-$segment-plain-short" ([KhcRansFixture]::Set32($original, $offset, $plain - 1))
        Test-Invalid "segment-$segment-plain-long" ([KhcRansFixture]::Set32($original, $offset, $plain + 1))
        Test-Invalid "segment-$segment-state-zero" ([KhcRansFixture]::Set32($original, $offset + 8, 0))
        Test-Invalid "segment-$segment-packed-max" ([KhcRansFixture]::Set32($original, $offset + 4, [uint32]::MaxValue))
        $inserted = [KhcRansFixture]::Insert($original, $offset + 8 + $packed)
        $inserted = [KhcRansFixture]::Set32($inserted, $offset + 4, $packed + 1)
        Test-Invalid "segment-$segment-trailing-byte" $inserted
        $offset += 8 + $packed
        $segment++
    }
    if ($offset -ne $original.Length -or $segment -lt 2) { throw 'Invalid or nonsegmented fixture.' }
    foreach ($length in @(0, 8, 39, 40, 43, 44, 47, 51, 52, ($original.Length - 1))) {
        Test-Invalid "truncate-$length" ([KhcRansFixture]::Resize($original, $length))
    }
    Test-Invalid 'trailing-payload' ([KhcRansFixture]::Resize($original, $original.Length + 1))
    for ($index = 0; $index -lt 64; $index++) {
        $mutated = [byte[]]$original.Clone()
        $at = 52 + [int][Math]::Floor($index * ($original.Length - 52) / 64)
        $mutated[$at] = $mutated[$at] -bxor (1 -shl ($index % 8))
        Test-Invalid "payload-bit-$index-at-$at" $mutated
    }
    foreach ($mode in @('distance-delta-screen', 'adapt-freeze-screen')) {
        $result = Invoke-Lab $mode $group
        if ($result.exit_code -ne 1 -or $result.bytes.Length -ne 0 -or $result.stderr -notlike '*requires range entropy backend*') { throw "$mode did not reject unsupported rANS early." }
        $rows.Add([pscustomobject]@{ case = "$mode-rans"; accepted = $false; error = $result.stderr.Trim() })
    }
    if ((Get-FileHash -LiteralPath $lab -Algorithm SHA256).Hash -cne $labHash) { throw 'Lab changed during validation.' }
    $success = $true
}
finally {
    [pscustomobject]@{ success = $success; lab_sha256 = $labHash; group_sha256 = $groupHash; cases = $rows.ToArray() } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8
    if ($success) {
        foreach ($path in @($plainPath, $framePath, $badPath)) {
            if (Test-Path -LiteralPath $path) {
                $resolved = (Resolve-Path -LiteralPath $path).Path
                if (-not $resolved.StartsWith($work + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Scratch file escaped work directory.' }
                Assert-NoReparse $resolved
                & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $resolved -Root $work | Out-Null
                if (Test-Path -LiteralPath $resolved) { throw "Scratch cleanup failed: $resolved" }
            }
        }
    }
}
Write-Host "rANS E2E passed: $($rows.Count) cases; report: $work/report.json"
