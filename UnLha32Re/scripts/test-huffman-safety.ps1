[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$GenerateOnly
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = Join-Path (Split-Path $TestProgram) 'DesktopRunner.exe'
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい試験領域が必要です。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Write-Fixture([string]$Name, [string]$Method, [byte[]]$Body, [uint32]$Original, [uint16]$Crc = 0) {
    $leaf = [Text.Encoding]::ASCII.GetBytes('a.txt')
    [byte[]]$header = @(0,0) + [Text.Encoding]::ASCII.GetBytes($Method) +
        [BitConverter]::GetBytes([uint32]$Body.Length) + [BitConverter]::GetBytes($Original) +
        [byte[]]@(0,0,0,0,32,0,$leaf.Length) + $leaf + [BitConverter]::GetBytes($Crc)
    $header[0] = $header.Length - 2
    $sum = 0
    foreach ($b in $header[2..($header.Length-1)]) { $sum = ($sum + $b) -band 255 }
    $header[1] = $sum
    $path = Join-Path $Workspace ($Name + '.lzh')
    [IO.File]::WriteAllBytes($path, [byte[]]($header + $Body + [byte[]]@(0)))
    return $path
}
function Convert-Bits([string]$Bits) {
    $Bits = $Bits.Replace(' ', '')
    $Bits = $Bits.PadRight(($Bits.Length + 7) -band -8, '0')
    [byte[]]$bytes = for ($i=0; $i -lt $Bits.Length; $i+=8) { [Convert]::ToByte($Bits.Substring($i,8),2) }
    return [byte[]]($bytes + [byte[]]@(0,0,0,0))
}
# 不正な符号長連続数と、合計が16ビットで折り返す過剰な符号木。
$cases = [ordered]@{
    'zero-run-overflow' = '0000000000000001 00000 00010 000000001 111111111'
    'oversubscribed-tree' = '0000000000000001 00100 001 001 001 00 001'
    'invalid-pt-singleton' = '0000000000000001 00000 11111 000000001'
    'invalid-c-singleton' = '0000000000000001 00000 00000 000000000 111111111'
}
$valid = Write-Fixture 'valid' '-lh0-' ([byte[]]@(0)) 1
$archives = foreach ($entry in $cases.GetEnumerator()) {
    Write-Fixture $entry.Key '-lh5-' (Convert-Bits $entry.Value) 1
}
if ($GenerateOnly) { $archives; return }
Write-Host "Candidate SHA256: $((Get-FileHash -LiteralPath $Candidate).Hash)"
foreach ($archive in $archives) {
    foreach ($wide in 0,1) {
        $rows = @(& $runner --timeout-seconds 20 $TestProgram --memory-failure-case-probe $Candidate $archive $valid $wide 0 32)
        if ($LASTEXITCODE -ne 0 -or @($rows -match '^failure\.[01]\.0\.32=32788,error=0,system=13,.*guard=1,').Count -ne 1) {
            throw "破損符号表の拒否・回復に失敗: $archive / $wide / $($rows -join ';')"
        }
    }
    $rows = @(& $runner --timeout-seconds 20 $TestProgram --check-decoder-failure-probe $Candidate $archive $valid)
    if ($LASTEXITCODE -ne 0 -or @($rows -match '^check.decoder.').Count -ne 12) {
        throw "CRC検査の拒否・回復に失敗: $archive"
    }
}
Write-Host "Huffman safety: $($archives.Count) malformed inputs, A/W memory guards and 3-API repeated CRC recovery passed"
