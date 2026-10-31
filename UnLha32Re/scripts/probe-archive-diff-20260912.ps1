$o = Resolve-Path -LiteralPath $args[0]
$c = Resolve-Path -LiteralPath $args[1]
$ob = [IO.File]::ReadAllBytes($o)
$cb = [IO.File]::ReadAllBytes($c)
Write-Output ("lengths {0} {1}" -f $ob.Length, $cb.Length)
$diff = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt [Math]::Min($ob.Length, $cb.Length); $i++) {
    if ($ob[$i] -ne $cb[$i]) {
        $diff.Add([pscustomobject]@{ Offset = $i; Oracle = ('{0:X2}' -f $ob[$i]); Candidate = ('{0:X2}' -f $cb[$i]) })
        if ($diff.Count -ge 100) { break }
    }
}
$diff | Format-Table -AutoSize
$start = 140
for ($i = $start; $i -lt [Math]::Min($start + 120, $ob.Length); $i += 16) {
    $row = for ($j = $i; $j -lt [Math]::Min($i + 16, $ob.Length); $j++) { '{0:X2}/{1:X2}' -f $ob[$j], $cb[$j] }
    Write-Output (('{0:X4}: ' -f $i) + ($row -join ' '))
}
foreach ($offset in 150, 158, 160, 166, 174, 182) {
    if ($offset + 8 -le $ob.Length) {
        Write-Output ("time {0}: {1} / {2}" -f $offset, [BitConverter]::ToInt64($ob, $offset), [BitConverter]::ToInt64($cb, $offset))
    }
}
$headerLength = [BitConverter]::ToUInt16($ob, 0)
Write-Output ("header={0}" -f $headerLength)
for ($position = 24; $position -lt $headerLength - 2;) {
    $length = [BitConverter]::ToUInt16($ob, $position)
    $type = $ob[$position + 2]
    Write-Output ("extension p={0} len={1} type=0x{2:X2}" -f $position, $length, $type)
    if ($type -eq 0x41) {
        Write-Output ("times={0}/{1}/{2}" -f [BitConverter]::ToInt64($ob, $position + 3), [BitConverter]::ToInt64($ob, $position + 11), [BitConverter]::ToInt64($ob, $position + 19))
        Write-Output ("times-candidate={0}/{1}/{2}" -f [BitConverter]::ToInt64($cb, $position + 3), [BitConverter]::ToInt64($cb, $position + 11), [BitConverter]::ToInt64($cb, $position + 19))
    }
    $position += $length
}
