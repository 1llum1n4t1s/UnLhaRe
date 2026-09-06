[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SeedArchive,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$Methods = @('lh0','lz4','lz5','lzs')
)
$ErrorActionPreference = 'Stop'
$SeedArchive = (Resolve-Path -LiteralPath $SeedArchive).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw '新しい出力ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$seed = [IO.File]::ReadAllBytes($SeedArchive)
if ($seed.Length -lt 25 -or $seed[20] -ne 0) { throw '正常な level-0 ヘッダーが必要です' }
$headerSize = [int]$seed[0] + 2
$crcOffset = 22 + [int]$seed[21]
if ($crcOffset + 2 -gt $headerSize -or $headerSize -gt $seed.Length) { throw 'データ CRC 欄の位置が不正です' }
$manifest = [Collections.Generic.List[string]]::new()
$manifest.Add("method`tsize`tpacked`tcrc`tfile")
foreach ($method in $Methods) { foreach ($size in 0,1,7,8,9,99,100,280,2048) {
    $payload = [byte[]]::new($size)
    for ($offset=0; $offset -lt $size; $offset++) { $payload[$offset] = [byte](65 + ($offset % 26)) }
    [uint32]$crc = 0
    foreach ($value in $payload) {
        $crc = $crc -bxor $value
        for ($bit=0; $bit -lt 8; $bit++) { $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 } }
    }
    $body = [Collections.Generic.List[byte]]::new()
    if ($method -eq 'lz5') {
        # 各フラグをリテラルに固定し、辞書参照なしで有効な旧方式本文を作る。
        for ($offset=0; $offset -lt $size; $offset += 8) {
            $body.Add(255)
            for ($item=$offset; $item -lt [Math]::Min($offset + 8,$size); $item++) { $body.Add($payload[$item]) }
        }
    } elseif ($method -eq 'lzs') {
        $bits = (@($payload | ForEach-Object { '1' + [Convert]::ToString($_,2).PadLeft(8,'0') }) -join '')
        $bits += '0' * ((8 - ($bits.Length % 8)) % 8)
        for ($offset=0; $offset -lt $bits.Length; $offset += 8) { $body.Add([Convert]::ToByte($bits.Substring($offset,8),2)) }
    } else { $body.AddRange($payload) }
    $bytes = [byte[]]::new($headerSize + $body.Count + 1)
    [Array]::Copy($seed,$bytes,$headerSize)
    [Text.Encoding]::ASCII.GetBytes("-$method-").CopyTo($bytes,2)
    [BitConverter]::GetBytes([uint32]$body.Count).CopyTo($bytes,7)
    [BitConverter]::GetBytes([uint32]$size).CopyTo($bytes,11)
    [BitConverter]::GetBytes([uint16]$crc).CopyTo($bytes,$crcOffset)
    $checksum = 0
    for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
    $bytes[1] = [byte]$checksum
    $body.CopyTo($bytes,$headerSize)
    $file = "$method-$size.lzh"
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory $file),$bytes)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$method-$size.bin"),$payload)
    $manifest.Add("$method`t$size`t$($body.Count)`t$crc`t$file")
} }
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'fixtures.tsv'),$manifest,[Text.UTF8Encoding]::new($false))
Write-Host "Legacy fixtures: $($manifest.Count - 1) literal/stored archives created at $OutputDirectory; no DLL was executed"
