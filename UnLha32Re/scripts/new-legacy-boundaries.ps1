[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Fixtures,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string[]]$Methods = @('lh0','lz4','lz5','lzs','lhd'),
    [int[]]$Sizes = @(0,1,8,9,100,2048)
)
$ErrorActionPreference = 'Stop'
$Fixtures = (Resolve-Path -LiteralPath $Fixtures).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw '新しい出力ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$records = [Collections.Generic.List[string]]::new()
$records.Add("method`tsize`tvariant`tpacked`tfile")
foreach ($method in @($Methods | Where-Object { $_ -ne 'lhd' })) { foreach ($size in $Sizes) {
    $source = [IO.File]::ReadAllBytes((Join-Path $Fixtures "$method-$size.lzh"))
    if ($source.Length -lt 25 -or $source[20] -ne 0) { throw 'level-0 の対照が必要です' }
    $headerSize = [int]$source[0] + 2
    $packed = [BitConverter]::ToUInt32($source,7)
    if ($headerSize + $packed + 1 -ne $source.Length -or $source[-1] -ne 0) { throw '単一項目の格納境界が不正です' }
    $variants = @(
        @{ Name='plain'; Extra=0; Declared=[int]$packed; Remove=0 },
        @{ Name='padding1'; Extra=1; Declared=[int]$packed+1; Remove=0 },
        @{ Name='padding16'; Extra=16; Declared=[int]$packed+16; Remove=0 }
    )
    if ($packed -gt 0) {
        $variants += @{ Name='under-declared'; Extra=0; Declared=[int]$packed-1; Remove=0 }
        $variants += @{ Name='missing-body-byte'; Extra=0; Declared=[int]$packed; Remove=1 }
        $variants += @{ Name='short-body'; Extra=0; Declared=[int]$packed-1; Remove=1 }
    }
    foreach ($variant in $variants) {
        $bytes = [byte[]]::new($source.Length + $variant.Extra - $variant.Remove)
        [Array]::Copy($source,0,$bytes,0,$headerSize + $packed - $variant.Remove)
        [BitConverter]::GetBytes([uint32]$variant.Declared).CopyTo($bytes,7)
        $checksum = 0
        for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
        $bytes[1] = [byte]$checksum
        $file = "$method-$size-$($variant.Name).lzh"
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory $file),$bytes)
        $records.Add("$method`t$size`t$($variant.Name)`t$($variant.Declared)`t$file")
    }
} }
if ('lhd' -in $Methods) {
    $source = [IO.File]::ReadAllBytes((Join-Path $Fixtures 'lh0-0.lzh'))
    $headerSize = [int]$source[0] + 2
    $crcOffset = 22 + [int]$source[21]
    foreach ($packed in 0,1,16) { foreach ($crc in 0,21930) {
        $bytes = [byte[]]::new($headerSize + $packed + 1)
        [Array]::Copy($source,$bytes,$headerSize)
        [Text.Encoding]::ASCII.GetBytes('-lhd-').CopyTo($bytes,2)
        $bytes[19] = 16
        [BitConverter]::GetBytes([uint32]$packed).CopyTo($bytes,7)
        [BitConverter]::GetBytes([uint16]$crc).CopyTo($bytes,$crcOffset)
        # 非ゼロ余白でも読み飛ばし位置を守り、ディレクトリーの CRC は判定しない。
        for ($offset=0; $offset -lt $packed; $offset++) { $bytes[$headerSize+$offset] = [byte](65+$offset) }
        $checksum = 0
        for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
        $bytes[1] = [byte]$checksum
        $file = "lhd-padding$packed-crc$crc.lzh"
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory $file),$bytes)
        $records.Add("lhd`t0`tpadding$packed-crc$crc`t$packed`t$file")
    } }
}
# 同じ 8 bit 本文に偶数・奇数の CRC を与え、境界の残余 bit とゼロ補完を区別する。
if ('lzs' -in $Methods -and 1 -in $Sizes) {
    $source = [IO.File]::ReadAllBytes((Join-Path $Fixtures 'lzs-1.lzh'))
    $headerSize = [int]$source[0] + 2
    $crcOffset = 22 + [int]$source[21]
    foreach ($value in 0,1,2,3,64,65,126,127,128,129,192,193,254,255) {
        $bytes = [byte[]]::new($headerSize + 2)
        [Array]::Copy($source,$bytes,$headerSize)
        [BitConverter]::GetBytes([uint32]1).CopyTo($bytes,7)
        $bytes[$headerSize] = [byte](128 -bor ($value -shr 1))
        [uint32]$crc = $value
        for ($bit=0; $bit -lt 8; $bit++) { $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 } }
        [BitConverter]::GetBytes([uint16]$crc).CopyTo($bytes,$crcOffset)
        $checksum = 0
        for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
        $bytes[1] = [byte]$checksum
        $file = "lzs-1-residual-$value.lzh"
        [IO.File]::WriteAllBytes((Join-Path $OutputDirectory $file),$bytes)
        $records.Add("lzs`t1`tresidual-$value`t1`t$file")
    }
}
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'fixtures.tsv'),$records,[Text.UTF8Encoding]::new($false))
Write-Output "Legacy boundaries: $($records.Count - 1) archives created"
