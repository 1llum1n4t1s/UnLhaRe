# 録画済みreceiptのJSONを固定全frame統計へ照合する。新processや録画は開始しない。
function Assert-CodecReceipt($Run, [string]$Operation) {
    if ($Run.exit_code -ne 0 -or $Run.stderr -or $Run.timed_out) { throw 'Codec process receipt invalid.' }
    try { $json = $Run.stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Codec stdout JSON mismatch.' }
    $expected = [ordered]@{
        operation=$Operation; input_bytes=$(if ($Operation -ceq 'encode') { 2811006 } else { 483468 })
        output_bytes=$(if ($Operation -ceq 'encode') { 483468 } else { 2811006 })
        runs=889227; primary=1762795; alphabet_symbols=257; payload_bytes=483187; plain_crc=433441561; payload_crc=1505987445
    }
    if ($json -is [Array] -or @($json.PSObject.Properties).Count -ne $expected.Count) { throw 'Codec stdout JSON mismatch.' }
    foreach ($key in $expected.Keys) {
        $property = $json.PSObject.Properties[$key]
        if ($null -eq $property -or $property.Value -cne $expected[$key]) { throw 'Codec stdout JSON mismatch.' }
    }
    if ($null -eq $Run.output -or $Run.output.bytes -ne $expected.output_bytes) { throw 'Codec stdout/output length mismatch.' }
}
