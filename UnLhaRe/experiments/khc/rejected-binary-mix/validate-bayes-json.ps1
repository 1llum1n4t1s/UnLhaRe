# 親harness共通: Rustとは独立したBigInteger metadata復号と損失会計。
function Assert-BayesInteger($Value, [long]$Low, [long]$High) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or
        -not [double]::IsFinite([double]$Value) -or $Value -ne [Math]::Truncate([double]$Value) -or $Value -lt $Low -or $Value -gt $High) { throw 'Bayes integer boundary mismatch.' }
}
function Assert-BayesLoss($Value) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or -not [double]::IsFinite([double]$Value) -or $Value -lt 0) { throw 'Bayes finite/nonnegative loss mismatch.' }
}
function Assert-BayesPackedDiagnostic($Diagnostic, $Primary, [string]$FramePath) {
    if ($Diagnostic.PSObject.Properties.Name -notcontains 'bayes_shadow') { throw 'Required causal Bayes observation missing.' }
    $b = $Diagnostic.bayes_shadow
    if (@($b.classes).Count -ne 7 -or $b.prior_primary -ne 0.5 -or $b.prior_cts -ne 0.5 -or $b.state_class_capacity -ne 7 -or
        $b.terminal -isnot [bool] -or -not $b.terminal -or $b.finite_losses -isnot [bool] -or -not $b.finite_losses -or $b.flush_count -ne 1 -or
        $b.self_checks.passed -isnot [bool] -or -not $b.self_checks.passed -or
        $b.self_checks.underflow_recovery -isnot [bool] -or -not $b.self_checks.underflow_recovery -or
        $b.self_checks.class_isolation -isnot [bool] -or -not $b.self_checks.class_isolation) { throw 'Bayes shape/prior/terminal/self-check mismatch.' }
    Assert-BayesInteger $b.self_checks.cases 3 10000
    Assert-BayesInteger $b.self_checks.checks 3 1000000
    Assert-BayesLoss $b.self_checks.max_abs_error
    if ($b.self_checks.max_abs_error -gt 1e-4) { throw 'Bayes self-check numeric error.' }
    $count = 0L; $totals = @{}; $maxError = 0.0
    foreach ($field in @('primary_q15_ideal_bits','cts_q15_ideal_bits','raw_ideal_bits','q15_ideal_bits','closed_form_ideal_bits')) { $totals[$field] = 0.0 }
    for ($i = 0; $i -lt 7; $i++) {
        $c = $b.classes[$i]
        Assert-BayesInteger $c.class $i $i
        Assert-BayesInteger $c.bits 0 ([long]::MaxValue)
        if ($c.bits -ne $Diagnostic.sites[$i].bits -or $c.bits -ne $Diagnostic.cts_shadow.classes[$i].bits) { throw 'Bayes class count mismatch.' }
        foreach ($field in @($totals.Keys)) { Assert-BayesLoss $c.$field; $totals[$field] += $c.$field }
        if ([Math]::Abs($c.primary_q15_ideal_bits - $Diagnostic.sites[$i].actual_q15_bits) -gt 1e-5 -or
            [Math]::Abs($c.cts_q15_ideal_bits - $Diagnostic.cts_shadow.classes[$i].q15_ideal_bits) -gt 1e-5) { throw 'Bayes changed component probabilities/loss.' }
        $difference = [Math]::Abs($c.primary_q15_ideal_bits - $c.cts_q15_ideal_bits)
        $closed = [Math]::Min($c.primary_q15_ideal_bits, $c.cts_q15_ideal_bits) + 1 - [Math]::Log2(1 + [Math]::Pow(2, -$difference))
        $error = [Math]::Abs($closed - $c.raw_ideal_bits)
        Assert-BayesLoss $c.closed_form_abs_error
        if ($error -gt 1e-4 -or [Math]::Abs($closed - $c.closed_form_ideal_bits) -gt 1e-5 -or [Math]::Abs($error - $c.closed_form_abs_error) -gt 1e-5) { throw 'Bayes prequential closed-form identity mismatch.' }
        foreach ($weight in @($c.posterior_primary,$c.posterior_cts)) { Assert-BayesLoss $weight; if ($weight -gt 1) { throw 'Bayes posterior outside range.' } }
        $t = [Math]::Pow(2, -$difference)
        $wp = if ($c.primary_q15_ideal_bits -le $c.cts_q15_ideal_bits) { 1 / (1 + $t) } else { $t / (1 + $t) }
        if ([Math]::Abs($wp - $c.posterior_primary) -gt 1e-12 -or [Math]::Abs($c.posterior_primary + $c.posterior_cts - 1) -gt 1e-12) { throw 'Bayes likelihood posterior mismatch.' }
        $count += $c.bits; $maxError = [Math]::Max($maxError, $error)
    }
    Assert-BayesInteger $b.total_bits_calls $count $count
    foreach ($field in $totals.Keys) {
        $totalField = $field + '_total'; Assert-BayesLoss $b.$totalField
        if ([Math]::Abs($totals[$field] - $b.$totalField) -gt 1e-5) { throw 'Bayes aggregate loss mismatch.' }
    }
    Assert-BayesLoss $b.closed_form_abs_error_total
    Assert-BayesLoss $b.max_class_closed_form_abs_error
    if ([Math]::Abs($b.closed_form_abs_error_total - [Math]::Abs($totals.raw_ideal_bits - $totals.closed_form_ideal_bits)) -gt 1e-5 -or
        [Math]::Abs($b.max_class_closed_form_abs_error - $maxError) -gt 1e-5) { throw 'Bayes reported identity error mismatch.' }
    Assert-BayesInteger $b.payload_bytes 5 134218752
    if ([Math]::Abs(8 * $b.payload_bytes - $b.q15_ideal_bits_total) -gt 8192) { throw 'Bayes real range payload accounting mismatch.' }
    $m = $b.packed_alphabet
    Assert-BayesInteger $m.k 1 257
    Assert-BayesInteger $m.bitmap_bytes 33 33
    Assert-BayesInteger $m.rank_bytes 0 212
    Assert-BayesInteger $m.metadata_bytes 33 245
    if ($m.k -ne $Primary.alphabet_symbols -or $m.metadata_bytes -ne 33 + $m.rank_bytes -or @($m.bytes).Count -ne $m.metadata_bytes -or
        $m.roundtrip -isnot [bool] -or -not $m.roundtrip -or $m.self_checks.passed -isnot [bool] -or -not $m.self_checks.passed) { throw 'Packed metadata shape/self-check mismatch.' }
    Assert-BayesInteger $m.self_checks.tiny_permutations 873 873
    Assert-BayesInteger $m.self_checks.full_alphabet_cases 2 10000
    Assert-BayesInteger $m.self_checks.adversarial_cases 6 10000
    foreach ($v in $m.bytes) { Assert-BayesInteger $v 0 255 }
    $bytes = [byte[]]$m.bytes
    if (($bytes[0] -band 1) -eq 0 -or ($bytes[32] -band 254) -ne 0) { throw 'Packed metadata sentinel/padding mismatch.' }
    $symbols = [Collections.Generic.List[int]]::new()
    for ($s = 0; $s -le 256; $s++) { if (($bytes[[int][Math]::Floor($s / 8)] -band (1 -shl ($s % 8))) -ne 0) { $symbols.Add($s) } }
    if ($symbols.Count -ne $m.k) { throw 'Packed bitmap cardinality mismatch.' }
    $factorials = [Collections.Generic.List[Numerics.BigInteger]]::new(); $factorials.Add([Numerics.BigInteger]::One)
    for ($i = 1; $i -le $m.k; $i++) { $factorials.Add($factorials[$i - 1] * $i) }
    $maxRank = $factorials[$m.k] - [Numerics.BigInteger]::One
    $expectedWidth = if ($maxRank.IsZero) { 0 } else { $maxRank.ToByteArray($true,$false).Length }
    if ($m.rank_bytes -ne $expectedWidth) { throw 'Packed rank fixed width is not canonical.' }
    # PowerShellはReadOnlySpan<byte> constructorへbindできない。正のsign byteを付ける。
    $rankBytes = [byte[]]::new($expectedWidth + 1)
    [Array]::Copy($bytes, 33, $rankBytes, 0, $expectedWidth)
    $rank = [Numerics.BigInteger]::new($rankBytes)
    if ($rank -ge $factorials[$m.k]) { throw 'Packed rank exceeds k!.' }
    $decoded = [Collections.Generic.List[int]]::new()
    for ($i = $m.k; $i -ge 1; $i--) {
        $divisor = $factorials[$i - 1]; $digit = [int]($rank / $divisor); $rank %= $divisor
        if ($digit -lt 0 -or $digit -ge $symbols.Count) { throw 'Packed permutation digit outside bounds.' }
        $decoded.Add($symbols[$digit]); $symbols.RemoveAt($digit)
    }
    if (-not $rank.IsZero -or $symbols.Count -ne 0) { throw 'Packed permutation remainder mismatch.' }
    $frame = [IO.File]::ReadAllBytes($FramePath)
    if ($frame.Length -lt 36 + 2 * $m.k -or [BitConverter]::ToUInt32($frame,16) -ne $m.k) { throw 'Primary frame alphabet boundary mismatch.' }
    for ($i = 0; $i -lt $m.k; $i++) { if ($decoded[$i] -ne [BitConverter]::ToUInt16($frame,36 + 2*$i)) { throw 'Independent packed metadata decode differs from primary alphabet.' } }
    Assert-BayesInteger $b.estimated_frame_bytes ($b.payload_bytes + 36 + $bytes.Length) ($b.payload_bytes + 36 + $bytes.Length)
    return $b
}

function Assert-BayesDiagnosticRejectsCorruption($Diagnostic, $Primary, [string]$FramePath) {
    # 成功したCLI結果の1項目だけ壊し、harnessが受理してしまわないことを検査する。
    $mutations = [ordered]@{
        class_count = { param($d) $d.bayes_shadow.classes[3].bits++ }
        component_loss = { param($d) $d.bayes_shadow.classes[3].primary_q15_ideal_bits += 1 }
        prequential_loss = { param($d) $d.bayes_shadow.classes[3].raw_ideal_bits += 1 }
        frame_accounting = { param($d) $d.bayes_shadow.estimated_frame_bytes++ }
        sentinel = { param($d) $d.bayes_shadow.packed_alphabet.bytes[0] = $d.bayes_shadow.packed_alphabet.bytes[0] -band 254 }
        padding = { param($d) $d.bayes_shadow.packed_alphabet.bytes[32] = $d.bayes_shadow.packed_alphabet.bytes[32] -bor 128 }
        rank_overflow = { param($d) for($i=33;$i -lt $d.bayes_shadow.packed_alphabet.bytes.Count;$i++) { $d.bayes_shadow.packed_alphabet.bytes[$i] = 255 } }
        permutation = { param($d) $d.bayes_shadow.packed_alphabet.bytes[33] = $d.bayes_shadow.packed_alphabet.bytes[33] -bxor 1 }
        rank_width = { param($d) $d.bayes_shadow.packed_alphabet.rank_bytes-- }
        self_check = { param($d) $d.bayes_shadow.self_checks.passed = $false }
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($name in $mutations.Keys) {
        $copy = $Diagnostic | ConvertTo-Json -Depth 15 | ConvertFrom-Json
        & $mutations[$name] $copy
        $reason = $null
        try { $null = Assert-BayesPackedDiagnostic $copy $Primary $FramePath } catch { $reason = $_.Exception.Message }
        if ($null -eq $reason) { throw "Corrupted Bayes JSON was accepted: $name" }
        $results.Add([pscustomobject]@{ name=$name; passed=$true; rejection=$reason })
    }
    return ,$results.ToArray()
}
