[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SeedArchive,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [int[]]$Sizes = @(0,1,13,100,2048)
)
$ErrorActionPreference = 'Stop'
$SeedArchive = (Resolve-Path -LiteralPath $SeedArchive).Path
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw '新しい出力ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$seed = [IO.File]::ReadAllBytes($SeedArchive)
if ($seed.Length -lt 25 -or $seed[20] -ne 0) { throw 'level-0 ヘッダーが必要です' }
$headerSize = [int]$seed[0] + 2
$crcOffset = 22 + [int]$seed[21]
if ($crcOffset + 2 -gt $headerSize -or $headerSize -gt $seed.Length) { throw 'データ CRC 欄が不正です' }
function Bits([int]$Value,[int]$Width) {
    if ($Width -eq 0) { if ($Value -ne 0) { throw '0 bit に非ゼロ値は格納できません' }; return '' }
    if ($Value -lt 0 -or $Value -ge (1 -shl $Width)) { throw '符号値が指定幅を超えています' }
    [Convert]::ToString($Value,2).PadLeft($Width,'0')
}
$records = [Collections.Generic.List[string]]::new()
$records.Add("method`tsize`tvariant`tpacked`tfile`tpayload")
function Write-PtLengths([int[]]$Lengths,[int]$Width,[int]$Special = -1) {
    $bits = Bits $Lengths.Count $Width
    for ($index=0; $index -lt $Lengths.Count; $index++) {
        $length = $Lengths[$index]
        if ($length -lt 0 -or $length -gt 16) { throw '符号長が範囲外です' }
        $bits += if ($length -lt 7) { Bits $length 3 } else { ('1' * ($length-4)) + '0' }
        if ($index+1 -eq $Special) { $bits += Bits 0 2 }
    }
    $bits
}
function Get-CanonicalCodes([int[]]$Lengths) {
    $result = @{}
    $code = 0
    $previous = 0
    foreach ($length in 1..16) {
        for ($index=0; $index -lt $Lengths.Count; $index++) {
            if ($Lengths[$index] -ne $length) { continue }
            $code = $code -shl ($length-$previous)
            $result[$index] = Bits $code $length
            $code++
            $previous = $length
        }
    }
    if ($previous -eq 0 -or $code -ne (1 -shl $previous)) { throw '完全なハフマン木ではありません' }
    $result
}
function New-PositionTable([int]$Mode,[int]$Symbol,[string]$Tree = 'singleton') {
    $bits = Bits $Mode 2
    if ($Tree -eq 'singleton') {
        if ($Mode -eq 2) { $bits += (Bits 1 4) + (Bits 1 4) + (Bits 1 4) + (Bits $Symbol 7) }
        if ($Mode -eq 3) { $bits += (Bits 0 5) + (Bits $Symbol 5) }
    } elseif ($Mode -eq 2 -and $Tree -eq 'balanced') {
        $bits += (Bits 7 4) * 128
    } elseif ($Mode -eq 2 -and $Tree -eq 'long') {
        $lengths = [int[]]::new(128)
        for ($index=0; $index -lt 9; $index++) { $lengths[$index] = $index+1 }
        $lengths[127] = 9
        foreach ($length in $lengths) { $bits += Bits $length 4 }
    } elseif ($Mode -eq 3 -and $Tree -eq 'long') {
        $bits += Write-PtLengths (@(1..14) + @(15,15)) 5
    } else { throw '位置表の指定が不正です' }
    $bits
}
function New-CBlock([int]$Count,[int]$Symbol,[int]$Mode,[int]$PositionSymbol = 0,[string]$Tree = 'singleton') {
    # 10016255 の読取順序。文字表を単一符号に固定する。
    $bits = (Bits $Count 16) + (Bits 0 5) + (Bits 0 5) + (Bits 0 9) + (Bits $Symbol 9)
    $bits += New-PositionTable $Mode $PositionSymbol $Tree
    $bits
}
function New-CodedBlock([byte[]]$Payload,[int[]]$Lengths,[int]$Mode) {
    # 文字 A からの連続した符号を使用。長さ表自体は 16 符号の均等木で符号化する。
    $bits = (Bits $Payload.Length 16) + (Write-PtLengths (@(4) * 16) 5 3)
    $bits += (Bits (65+$Lengths.Count) 9) + (Bits 2 4) + (Bits (65-20) 9)
    foreach ($length in $Lengths) { $bits += Bits ($length+2) 4 }
    $bits += New-PositionTable $Mode 0
    $codes = Get-CanonicalCodes $Lengths
    foreach ($value in $Payload) {
        $index = [int]$value - 65
        if (!$codes.ContainsKey($index)) { throw '本文の文字に対応する符号がありません' }
        $bits += $codes[$index]
    }
    $bits
}
function Get-FixedPosition([int]$High) {
    # 原版 RVA 2C430 の表を照合済み。分類は 128 個、位置の下位は別途 8 bit。
    $limits = @(1,1,3,6,13,31,78,0)
    $length = 2
    $weight = 1 -shl 14
    $code = 0
    $marker = 0
    for ($index=0; $index -lt 128; $index++) {
        while ($limits[$marker] -eq $index) { $length++; $weight = $weight -shr 1; $marker++ }
        if ($index -eq $High) { return (Bits ($code -shr (16-$length)) $length) }
        $code += $weight
    }
    throw '位置分類が範囲外です'
}
function Write-Lx1Archive([string]$Label,[string]$Variant,[byte[]]$Payload,[string]$Bits) {
    [uint32]$crc = 0
    foreach ($value in $Payload) {
        $crc = $crc -bxor $value
        for ($bit=0; $bit -lt 8; $bit++) { $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 } }
    }
    # ブロック間は詰めたまま連結し、ファイルの末尾だけを byte 境界へそろえる。
    $Bits += '0' * ((8 - ($Bits.Length % 8)) % 8)
    $body = [byte[]]::new($Bits.Length / 8)
    for ($offset=0; $offset -lt $body.Length; $offset++) { $body[$offset] = [Convert]::ToByte($Bits.Substring($offset*8,8),2) }
    $bytes = [byte[]]::new($headerSize + $body.Length + 1)
    [Array]::Copy($seed,$bytes,$headerSize)
    [Text.Encoding]::ASCII.GetBytes('-lx1-').CopyTo($bytes,2)
    [BitConverter]::GetBytes([uint32]$body.Length).CopyTo($bytes,7)
    [BitConverter]::GetBytes([uint32]$Payload.Length).CopyTo($bytes,11)
    [BitConverter]::GetBytes([uint16]$crc).CopyTo($bytes,$crcOffset)
    $checksum = 0
    for ($offset=2; $offset -lt $headerSize; $offset++) { $checksum = ($checksum + $bytes[$offset]) -band 255 }
    $bytes[1] = [byte]$checksum
    $body.CopyTo($bytes,$headerSize)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$Label.lzh"),$bytes)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$Label.bin"),$Payload)
    $records.Add("lx1`t$($Payload.Length)`t$Variant`t$($body.Length)`t$Label.lzh`t$Label.bin")
}
foreach ($size in $Sizes) {
    if ($size -lt 0 -or $size -gt 65535) { throw '単一ブロックの上限は 65535 です' }
    $payload = [Text.Encoding]::ASCII.GetBytes('A' * $size)
    foreach ($mode in 0,1,2,3) {
        Write-Lx1Archive "lx1-$size-mode$mode" "mode$mode" $payload (New-CBlock $size 65 $mode)
    }
}
foreach ($mode in 0,1,2,3) {
    foreach ($case in @(
        @{ Name='overlap-min'; Prefix=1; Length=3; Distance=1; Fill='A' },
        @{ Name='overlap-max'; Prefix=1; Length=256; Distance=1; Fill='A' },
        @{ Name='initial-distance-max'; Prefix=1; Length=256; Distance=32768; Fill=' ' },
        @{ Name='window-distance-max'; Prefix=32768; Length=256; Distance=32768; Fill='A' }
    )) {
        $position = $case.Distance - 1
        $positionSymbol = $position -shr 8
        if ($mode -eq 3) {
            $positionSymbol = 0
            for ($remaining=$position; $remaining -gt 0; $remaining = $remaining -shr 1) { $positionSymbol++ }
        }
        $bits = (New-CBlock $case.Prefix 65 $mode) + (New-CBlock 1 (253+$case.Length) $mode $positionSymbol)
        switch ($mode) {
            0 { $bits += Bits $position 15 }
            1 { $bits += (Get-FixedPosition ($position -shr 8)) + (Bits ($position -band 255) 8) }
            2 { $bits += Bits ($position -band 255) 8 }
            3 { if ($positionSymbol -gt 1) { $bits += Bits ($position - (1 -shl ($positionSymbol-1))) ($positionSymbol-1) } }
        }
        $payload = [Text.Encoding]::ASCII.GetBytes(('A' * $case.Prefix) + ($case.Fill * $case.Length))
        Write-Lx1Archive "lx1-$($case.Name)-mode$mode" "$($case.Name)-mode$mode" $payload $bits
    }
}
foreach ($mode in 0,1,2,3) {
    $payload = [Text.Encoding]::ASCII.GetBytes('AB' * 32)
    Write-Lx1Archive "lx1-two-character-mode$mode" "two-character-mode$mode" $payload (New-CodedBlock $payload @(1,1) $mode)
    $payload = [Text.Encoding]::ASCII.GetBytes('ABCDEFGHIJKLMN')
    Write-Lx1Archive "lx1-long-character-mode$mode" "long-character-mode$mode" $payload (New-CodedBlock $payload (@(1..12) + @(13,13)) $mode)
}
foreach ($case in @(
    @{ Mode=2; Tree='balanced'; Code=(Bits 127 7) + (Bits 255 8) },
    @{ Mode=2; Tree='long'; Code=(Bits 511 9) + (Bits 255 8) },
    @{ Mode=3; Tree='long'; Code=(Bits 32767 15) + (Bits 16383 14) }
)) {
    $bits = (New-CBlock 32768 65 $case.Mode) + (New-CBlock 1 509 $case.Mode 0 $case.Tree) + $case.Code
    $payload = [Text.Encoding]::ASCII.GetBytes('A' * (32768+256))
    $label = "lx1-position-$($case.Tree)-mode$($case.Mode)"
    Write-Lx1Archive $label "position-$($case.Tree)-mode$($case.Mode)" $payload $bits
}
# 同一ストリームで 3 → 0 → 1 → 2 → 3 と切り替え、表の持越しを確認する。
$bits = New-CodedBlock ([Text.Encoding]::ASCII.GetBytes('AB')) @(1,1) 3
foreach ($mode in 0,1,2,3) {
    $bits += New-CBlock 1 509 $mode $(if ($mode -eq 3) { 1 } else { 0 })
    switch ($mode) {
        0 { $bits += Bits 1 15 }
        1 { $bits += (Get-FixedPosition 0) + (Bits 1 8) }
        2 { $bits += Bits 1 8 }
    }
}
Write-Lx1Archive 'lx1-mode-transition' 'mode-transition' ([Text.Encoding]::ASCII.GetBytes('AB' * 513)) $bits
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'fixtures.tsv'),$records,[Text.UTF8Encoding]::new($false))
Write-Output "LX1: $($records.Count - 1) constant/dictionary/Huffman/block-switch archives prepared"
