# Level-2 の本文と拡張データを保ち、サイズ鎖とヘッダー CRC だけを Level-3 形式へ組み直す。
# DLL の読み取り結果ではなく元バイト列から試験入力を作成する。
function ConvertTo-Level3HeaderFixture([byte[]]$Source) {
    $archive = [IO.MemoryStream]::new()
    $crcPositions = @()
    try {
        $position = 0
        while ($position -lt $Source.Length -and $Source[$position] -ne 0) {
            if ($position + 26 -gt $Source.Length -or $Source[$position + 20] -ne 2) {
                throw '変換元は Level-2 ヘッダーでなければなりません'
            }
            $oldSize = [BitConverter]::ToUInt16($Source,$position)
            $packed = [BitConverter]::ToUInt32($Source,$position + 7)
            if ($oldSize -lt 26 -or [long]$position + $oldSize + $packed -ge $Source.Length) {
                throw '変換元のヘッダーまたは本文が不足しています'
            }
            $size = [BitConverter]::ToUInt16($Source,$position + 24)
            $offset = $position + 26
            $extensions = [Collections.Generic.List[byte[]]]::new()
            while ($size) {
                if ($size -lt 3 -or $offset + $size -gt $position + $oldSize) { throw '拡張鎖が不正です' }
                $extensions.Add([byte[]]$Source[$offset..($offset + $size - 3)])
                $next = $offset + $size - 2
                $size = [BitConverter]::ToUInt16($Source,$next)
                $offset = $next + 2
            }
            if ($offset -ne $position + $oldSize -or !$extensions.Count) { throw '未処理の拡張領域があります' }
            $headerSize = 32
            foreach ($record in $extensions) { $headerSize += $record.Length + 4 }
            $header = [byte[]]::new($headerSize)
            [BitConverter]::GetBytes([uint16]4).CopyTo($header,0)
            [Array]::Copy($Source,$position + 2,$header,2,22)
            $header[20] = 3
            [BitConverter]::GetBytes([uint32]$headerSize).CopyTo($header,24)
            [BitConverter]::GetBytes([uint32]($extensions[0].Length + 4)).CopyTo($header,28)
            $newOffset = 32
            $crcAt = -1
            for ($index = 0; $index -lt $extensions.Count; $index++) {
                $record = $extensions[$index]
                $record.CopyTo($header,$newOffset)
                if ($record[0] -eq 0) {
                    if ($crcAt -ne -1 -or $record.Length -lt 3) { throw '共通 CRC 拡張が不正です' }
                    $crcAt = $newOffset + 1
                    $header[$crcAt] = 0
                    $header[$crcAt + 1] = 0
                }
                $nextSize = if ($index + 1 -lt $extensions.Count) { $extensions[$index + 1].Length + 4 } else { 0 }
                [BitConverter]::GetBytes([uint32]$nextSize).CopyTo($header,$newOffset + $record.Length)
                $newOffset += $record.Length + 4
            }
            if ($crcAt -lt 0 -or $newOffset -ne $headerSize) { throw 'ヘッダー組み立て失敗' }
            [int]$crc = 0
            foreach ($value in $header) {
                $crc = $crc -bxor [int]$value
                for ($bit = 0; $bit -lt 8; $bit++) {
                    $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 }
                }
            }
            [BitConverter]::GetBytes([uint16]$crc).CopyTo($header,$crcAt)
            $crcPositions += [int]($archive.Position + $crcAt)
            $archive.Write($header,0,$header.Length)
            $archive.Write($Source,$position + $oldSize,[int]$packed)
            $position += $oldSize + $packed
        }
        if ($position + 1 -ne $Source.Length -or $Source[$position] -ne 0 -or !$crcPositions.Count) {
            throw '変換元には末尾の終端が必要です'
        }
        $archive.WriteByte(0)
        [pscustomobject]@{ Bytes=$archive.ToArray(); CrcPositions=$crcPositions }
    } finally { $archive.Dispose() }
}
