#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$ProbeBinary,
    [Parameter(Mandatory)][string]$ReferenceBinary,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [switch]$RequireRankEntropy,
    [switch]$RequireClassMixerShadow,
    [switch]$RequireIdentityShadow,
    [switch]$RequireExponentShadow,
    [switch]$RequireSemanticShadow,
    [switch]$RequireCtsShadow,
    [switch]$RequireBayesShadow
)
# 不採用codecの観測専用。確率・係数・contextを調整せず、既知frameを要求する。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$frameHash = '05DC3B7C20A4779F271C7DC19BA1750CB4E1E57B2AE024D3A01687F35FA075F0'
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$provenance = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Reparse point rejected.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw 'Expected regular file.' }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path).Hash }
}
function Lock-File([string]$Path, [string]$Role) {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $id = Identity $Path
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null }
    $provenance.Add($row)
    return $row
}
function Call-Codec([string]$Program, [string[]]$Argv) {
    if (Test-Path -LiteralPath $Argv[2]) { throw 'Refusing existing output.' }
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.WorkingDirectory = $work
    foreach ($arg in $Argv) { $info.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::new(); $p.StartInfo = $info
    $row = [ordered]@{ program = $Program; argv = $Argv; exit = $null; stdout = ''; stderr = ''; output = $null }
    $calls.Add($row); $started = $false
    try {
        $started = $p.Start(); if (-not $started) { throw 'Start failed.' }
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { throw 'Diagnostic deadline exceeded.' }
        $row.exit = $p.ExitCode; $row.stdout = $stdout.GetAwaiter().GetResult(); $row.stderr = $stderr.GetAwaiter().GetResult()
        if ($row.exit -ne 0) { throw "Codec failed: $($row.stderr)" }
        $row.output = Identity $Argv[2]
    } finally {
        if ($started -and -not $p.HasExited) { $p.Kill($true); $p.WaitForExit() }
        $p.Dispose()
    }
    return [pscustomobject]$row
}
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be below build.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be new.' }
$null = New-Item -ItemType Directory -Path $work
$report = [ordered]@{
    status = 'failed'; started_utc = [DateTime]::UtcNow.ToString('o'); error = $null
    kind = 'unchanged_rejected_codec_site_loss'; provenance = $provenance; invocations = $calls; sites = @(); totals = $null
    timing_used = $false; require_rank_entropy = [bool]$RequireRankEntropy; rank_entropy = $null
    require_class_mixer_shadow = [bool]$RequireClassMixerShadow; class_mixer_shadow = $null
    require_identity_shadow = [bool]$RequireIdentityShadow; identity_shadow = $null
    require_exponent_shadow = [bool]$RequireExponentShadow; exponent_shadow = $null
require_semantic_shadow = [bool]$RequireSemanticShadow; semantic_shadow = $null
require_cts_shadow = [bool]$RequireCtsShadow; cts_shadow = $null
    environment = [ordered]@{ os = [Runtime.InteropServices.RuntimeInformation]::OSDescription; powershell = $PSVersionTable.PSVersion.ToString(); runtime = [Environment]::Version.ToString(); cwd = $PWD.Path }
    notes = @('No primary probability/context/coefficient/grammar changes; output must equal known rejected frame. Separate auxiliary models are diagnostic only.', 'Log2 losses are ideal probabilities; range interval truncation/flush and metadata are not charged to these losses.', 'Best fixed expert per kind is a hindsight oracle, not a working codec or guaranteed recoverable saving.', 'Development input only; no timing, sweeps, holdout, or adoption decision.')
}
$failure = $null
try {
    if ($RequireSemanticShadow -and (-not $RequireIdentityShadow -or $RequireExponentShadow)) { throw 'Semantic shadow requires identity control and excludes exponent combination.' }
    if ($RequireCtsShadow -and ($RequireIdentityShadow -or $RequireExponentShadow -or $RequireSemanticShadow -or $RequireClassMixerShadow)) { throw 'CTS model replacement must be diagnosed without other shadow combinations.' }
    if ($RequireBayesShadow -and -not $RequireCtsShadow) { throw 'Bayes requires frozen CTS provenance.' }
    $probe = Lock-File ([IO.Path]::GetFullPath($ProbeBinary)) 'diagnostic-binary'
    $reference = Lock-File ([IO.Path]::GetFullPath($ReferenceBinary)) 'verified-reference-binary'
    $group = Lock-File ([IO.Path]::GetFullPath($GroupPath)) 'fixed-input'
    $null = Lock-File (Join-Path $PSScriptRoot 'codec.rs') 'source'
    if ($RequireIdentityShadow) { $null = Lock-File (Join-Path $PSScriptRoot 'identity_probe.rs') 'identity-probe-source' }
    if ($RequireExponentShadow) { $null = Lock-File (Join-Path $PSScriptRoot 'exponent_probe.rs') 'exponent-probe-source' }
    if ($RequireSemanticShadow) { $null = Lock-File (Join-Path $PSScriptRoot 'semantic_probe.rs') 'semantic-probe-source' }
    if ($RequireCtsShadow) {
        $null = Lock-File (Join-Path $PSScriptRoot 'cts_probe.rs') 'cts-probe-source'
        $rustc = Lock-File 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'rustc'
        $report.environment['rustc_version'] = @(& $rustc.path --version --verbose)
        if ($LASTEXITCODE -ne 0 -or $report.environment.rustc_version[0] -cnotmatch '^rustc 1\.98\.1 ') { throw 'CTS Rust toolchain mismatch.' }
        $report.environment['compile_arguments'] = @('--edition=2024', '-C', 'opt-level=3', '-C', 'panic=abort', '--cfg', 'khc_site_probe', '--cfg', 'khc_cts_probe')
    }
    $null = Lock-File (Join-Path $PSScriptRoot '../range.rs') 'range-source'
    if ($RequireBayesShadow) {
        foreach ($sourceName in @('bayes_probe.rs', 'packed_alphabet.rs', 'validate-bayes-json.ps1', '../CAUSAL_BAYES_PACKED_CONTRACT_20260930.md')) { $null = Lock-File (Join-Path $PSScriptRoot $sourceName) $sourceName }
        . (Join-Path $PSScriptRoot 'validate-bayes-json.ps1')
        $report['require_bayes_shadow'] = $true
        $report.environment.compile_arguments += @('--cfg', 'khc_bayes_probe')
        $oldCts = Lock-File (Join-Path $root 'build/khc-bwt-cts-shadow-20260930/evidence/report.json') 'frozen-cts-evidence'
        if ($oldCts.before_sha256 -cne 'C70B6CFD2E4749F9B3D3747FEAF86E0CF2F6F5B06C78FF7AF1FDF6D377058804') { throw 'Frozen CTS evidence identity mismatch.' }
    }
    $null = Lock-File $PSCommandPath 'harness'
    if ($group.before_bytes -ne 2811006 -or $group.before_sha256 -cne $fixedHash) { throw 'Fixed group mismatch.' }
    if ($reference.before_sha256 -cne 'F8293F13A701B3CA7589A3A5561152F6AA7E50D00F64F8BE48033A223CD3E254') { throw 'Reference binary identity mismatch.' }
    $frame = Join-Path $work 'diagnostic.frame'
    $encoded = Call-Codec $probe.path @('encode', $group.path, $frame)
    if ($encoded.output.bytes -ne 505046 -or $encoded.output.sha256 -cne $frameHash) { throw 'Instrumentation changed the bitstream.' }
    $lines = @($encoded.stdout.Trim() -split '\r?\n')
    if ($lines.Count -ne 2) { throw 'Expected normal JSON plus exactly one diagnostic JSON line.' }
    $normal = $lines[0] | ConvertFrom-Json; $diagnostic = $lines[1] | ConvertFrom-Json
    if ($normal.operation -cne 'encode' -or $normal.input_bytes -ne 2811006 -or $normal.output_bytes -ne 505046 -or $diagnostic.kind -cne 'site_loss_diagnostic' -or @($diagnostic.sites).Count -ne 7) { throw 'Diagnostic boundary mismatch.' }
    $sumBits = 0L; $sumActual = 0.0; $sumActual12 = 0.0; $oracle = 0.0; $expertTotals = [double[]]::new(4)
    $fixedSiteCounts = @(889227L, 888970L, 2472373L, 1835474L, 889227L, 426165L, 221182L)
    for ($i = 0; $i -lt 7; $i++) {
        $site = $diagnostic.sites[$i]
        if ($site.class -ne $i -or $site.bits -ne $fixedSiteCounts[$i] -or @($site.expert_bits).Count -ne 4) { throw 'Site shape/count mismatch.' }
        foreach ($v in @($site.actual_q12_bits, $site.actual_q15_bits) + @($site.expert_bits)) { if (-not [double]::IsFinite([double]$v) -or $v -lt 0) { throw 'Invalid loss.' } }
        $sumBits += $site.bits; $sumActual += $site.actual_q15_bits; $sumActual12 += $site.actual_q12_bits
        $oracle += ($site.expert_bits | Measure-Object -Minimum).Minimum
        for ($j = 0; $j -lt 4; $j++) { $expertTotals[$j] += $site.expert_bits[$j] }
    }
    if ($sumBits -le 0 -or [Math]::Abs($sumActual - $sumActual12) -gt 0.01) { throw 'Q12/Q15 scale or total-count mismatch.' }
    # end flagは必ず全runで1回、他classはrun数やbit位置に従う。
    if ($diagnostic.sites[0].bits -ne $normal.runs -or $normal.runs -ne 889227) { throw 'Run/decision total mismatch.' }
    $payloadBits = [double]$normal.payload_bytes * 8
    if ($sumActual -gt $payloadBits + 1024 -or [Math]::Abs($sumActual - $payloadBits) -gt 8192) { throw 'Ideal loss is not plausibly consistent with payload bit count.' }
    $report.sites = $diagnostic.sites
    $report.totals = [ordered]@{ decisions = $sumBits; actual_q12_bits = $sumActual12; actual_q15_bits = $sumActual; payload_bits = $payloadBits; total_frame_bits = 505046 * 8; range_residual_bits = $payloadBits - $sumActual; expert_bits = $expertTotals; best_global_fixed_expert_bits = ($expertTotals | Measure-Object -Minimum).Minimum; hindsight_per_kind_best_expert_bits = $oracle; hindsight_gap_from_actual_bytes = ($sumActual - $oracle) / 8; rejected_frame_over_gate_bytes = 21447 }
    if ($diagnostic.PSObject.Properties.Name -contains 'rank_entropy') {
        $rank = $diagnostic.rank_entropy
        if ($rank.runs -ne 889227 -or $rank.alphabet -ne 257 -or $rank.histogram_runs_global -ne $rank.runs -or
            $rank.histogram_runs_symbol -ne $rank.runs -or $rank.histogram_runs_symbol_prev_exp -ne $rank.runs) { throw 'Rank histogram totals/boundaries mismatch.' }
        $entropyFields = @('global_shannon_bits', 'symbol_shannon_bits', 'symbol_prev_rank_exp_shannon_bits', 'symbol_kt_prequential_bits')
        foreach ($fieldName in $entropyFields) { if (-not [double]::IsFinite([double]$rank.$fieldName) -or $rank.$fieldName -lt 0) { throw 'Rank loss is not finite/nonnegative.' } }
        if ($rank.symbol_prev_rank_exp_shannon_bits -gt $rank.symbol_shannon_bits + 0.01 -or $rank.symbol_shannon_bits -gt $rank.global_shannon_bits + 0.01 -or $rank.symbol_shannon_bits -gt $rank.symbol_kt_prequential_bits + 0.01) { throw 'Entropy conditioning/prequential bounds violated.' }
        $rankActual = 0.0
        for ($i = 0; $i -lt 4; $i++) { $rankActual += $diagnostic.sites[$i].actual_q15_bits }
        $saving = ($rankActual - $rank.symbol_kt_prequential_bits) / 8
        $report.rank_entropy = [ordered]@{
            observations = $rank; existing_rank_ideal_bits = $rankActual; rank_symbol_kt_estimated_saving_bytes = $saving
            fixed_shortfall_bytes = 21447; rank_symbol_kt_alone_has_estimated_headroom = $saving -ge 21447
            interpretation = 'Diagnostic only; rank grammar changes can also alter shared predictor updates and run costs. No frame, model-table/header cost, speed, decoder synchronization, or generalization claim for this probability estimator.'
        }
    } elseif ($RequireRankEntropy) { throw 'Required rank entropy observation is missing.' }
    if ($diagnostic.PSObject.Properties.Name -contains 'class_mixer_shadow') {
        $shadow = $diagnostic.class_mixer_shadow
        if (@($shadow.classes).Count -ne 7 -or $shadow.total_bits_calls -ne $sumBits) { throw 'Shadow class shape/bitcount mismatch.' }
        $shadowCount = 0L; $shadowLoss = 0.0
        for ($i = 0; $i -lt 7; $i++) {
            $class = $shadow.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or -not [double]::IsFinite([double]$class.ideal_bits) -or $class.ideal_bits -lt 0) { throw 'Shadow class boundary/loss mismatch.' }
            $shadowCount += $class.bits; $shadowLoss += $class.ideal_bits
        }
        if ($shadowCount -ne $sumBits -or [Math]::Abs($shadowLoss - $shadow.ideal_bits_total) -gt 0.01 -or $shadow.payload_bytes -lt 5 -or $shadow.payload_bytes -gt 134218752 -or
            $shadow.estimated_frame_bytes -ne $shadow.payload_bytes + 36 + 2 * $normal.alphabet_symbols -or [Math]::Abs(8 * $shadow.payload_bytes - $shadowLoss) -gt 8192) { throw 'Shadow aggregate/flush/frame boundary mismatch.' }
        $report.class_mixer_shadow = [ordered]@{
            observations = $shadow; estimated_size_threshold_passed = $shadow.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $shadow.estimated_frame_bytes - 483599
            estimated_size_delta_from_control = $shadow.estimated_frame_bytes - 505046
            interpretation = 'Counterfactual auxiliary payload only; old frame is unchanged. A new frame/decoder needs independent correctness and real total-size verification before any fixed-gate claim. No time/holdout/general-performance evidence.'
        }
    } elseif ($RequireClassMixerShadow) { throw 'Required class mixer shadow is missing.' }
    if ($diagnostic.PSObject.Properties.Name -contains 'identity_shadow') {
        if (-not $RequireIdentityShadow) { throw 'Identity shadow requires explicit provenance verification.' }
        $identity = $diagnostic.identity_shadow
        if (@($identity.classes).Count -ne 7 -or @($identity.tables).Count -ne 4 -or $identity.total_bits_calls -ne $sumBits -or $identity.max_distinct_keys -ne 2000000) { throw 'Identity shadow shape/bitcount/cap mismatch.' }
        $identityCount = 0L; $identityLoss = 0.0; $distinctTotal = 0L
        for ($i = 0; $i -lt 7; $i++) {
            $class = $identity.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or -not [double]::IsFinite([double]$class.ideal_bits) -or $class.ideal_bits -lt 0) { throw 'Identity shadow class/loss mismatch.' }
            $identityCount += $class.bits; $identityLoss += $class.ideal_bits
        }
        $slotCaps = @(4096, 262144, 262144, 262144)
        for ($i = 0; $i -lt 4; $i++) {
            $table = $identity.tables[$i]
            foreach ($field in @('distinct_keys', 'occupied_slots', 'alias_keys')) {
                $value = [double]$table.$field
                if (-not [double]::IsFinite($value) -or $value -lt 0 -or $value -ne [Math]::Floor($value)) { throw 'Identity table count is not a nonnegative integer.' }
            }
            if ($table.table -ne $i -or $table.distinct_keys -lt 1 -or $table.distinct_keys -gt 2000000 -or $table.occupied_slots -lt 1 -or $table.occupied_slots -gt $slotCaps[$i] -or $table.occupied_slots -gt $table.distinct_keys -or $table.alias_keys -ne $table.distinct_keys - $table.occupied_slots) { throw 'Identity table slot/key accounting mismatch.' }
            $distinctTotal += $table.distinct_keys
        }
        if ($distinctTotal -ne $identity.total_distinct_keys -or $distinctTotal -gt 2000000 -or $identityCount -ne $sumBits -or
            -not [double]::IsFinite([double]$identity.ideal_bits_total) -or [Math]::Abs($identityLoss - $identity.ideal_bits_total) -gt 0.01 -or
            $identity.payload_bytes -lt 5 -or $identity.payload_bytes -gt 134218752 -or $identity.estimated_frame_bytes -ne $identity.payload_bytes + 36 + 2 * $normal.alphabet_symbols -or
            [Math]::Abs(8 * $identity.payload_bytes - $identityLoss) -gt 8192) { throw 'Identity aggregate/flush/frame accounting mismatch.' }
        $report.identity_shadow = [ordered]@{
            observations = $identity; estimated_size_threshold_passed = $identity.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $identity.estimated_frame_bytes - 483599
            estimated_size_delta_from_control = $identity.estimated_frame_bytes - 505046
            interpretation = 'Exact existing u32 keys only; auxiliary payload is not decoded. Primary frame is unchanged. Sparse-map allocation and instrumentation are diagnostic, not production memory/speed evidence. No class-mixer combination or new semantic context.'
        }
    } elseif ($RequireIdentityShadow) { throw 'Required identity shadow is missing.' }
    if ($diagnostic.PSObject.Properties.Name -contains 'semantic_shadow') {
        if (-not $RequireSemanticShadow -or -not $RequireIdentityShadow -or $null -eq $report.identity_shadow -or
            $diagnostic.PSObject.Properties.Name -contains 'exponent_shadow') { throw 'Semantic shadow requires explicit provenance and uncombined identity control.' }
        $semantic = $diagnostic.semantic_shadow
        if (@($semantic.classes).Count -ne 7 -or @($semantic.tables).Count -ne 4 -or $semantic.total_bits_calls -ne $sumBits -or
            $semantic.max_distinct_keys -ne 2000000 -or $report.identity_shadow.observations.estimated_frame_bytes -ne 504165) { throw 'Semantic shape/count/cap or identity control mismatch.' }
        $semanticCount = 0L; $semanticLoss = 0.0; $semanticKeys = 0L; $foldedKeys = 0L
        $classChanges = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt 7; $i++) {
            $class = $semantic.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or -not [double]::IsFinite([double]$class.ideal_bits) -or $class.ideal_bits -lt 0) { throw 'Semantic class/loss mismatch.' }
            $semanticCount += $class.bits; $semanticLoss += $class.ideal_bits
            $classChanges.Add([ordered]@{ class = $i; ideal_bit_delta_from_identity_control = $class.ideal_bits - $report.identity_shadow.observations.classes[$i].ideal_bits })
        }
        for ($i = 0; $i -lt 4; $i++) {
            $table = $semantic.tables[$i]
            foreach ($field in @('distinct_semantic_keys', 'distinct_folded_keys', 'additional_semantic_keys')) {
                $value = [double]$table.$field
                if (-not [double]::IsFinite($value) -or $value -lt 0 -or $value -gt 2000000 -or $value -ne [Math]::Floor($value)) { throw 'Semantic table count is not a bounded nonnegative integer.' }
            }
            if ($table.table -ne $i -or $table.distinct_semantic_keys -lt 1 -or $table.distinct_folded_keys -lt 1 -or
                $table.distinct_folded_keys -ne $report.identity_shadow.observations.tables[$i].distinct_keys -or
                $table.additional_semantic_keys -ne $table.distinct_semantic_keys - $table.distinct_folded_keys) { throw 'Semantic/folded key accounting mismatch.' }
            $semanticKeys += $table.distinct_semantic_keys; $foldedKeys += $table.distinct_folded_keys
        }
        if ($semanticKeys -ne $semantic.total_distinct_keys -or $semanticKeys -gt 2000000 -or $foldedKeys -ne $report.identity_shadow.observations.total_distinct_keys -or
            $semanticCount -ne $sumBits -or -not [double]::IsFinite([double]$semantic.ideal_bits_total) -or [Math]::Abs($semanticLoss - $semantic.ideal_bits_total) -gt 0.01 -or
            $semantic.payload_bytes -lt 5 -or $semantic.payload_bytes -gt 134218752 -or $semantic.estimated_frame_bytes -ne $semantic.payload_bytes + 36 + 2 * $normal.alphabet_symbols -or
            [Math]::Abs(8 * $semantic.payload_bytes - $semanticLoss) -gt 8192) { throw 'Semantic aggregate/flush/frame accounting mismatch.' }
        $report.semantic_shadow = [ordered]@{
            observations = $semantic; ideal_bit_changes_by_class = $classChanges
            additional_semantic_keys = $semanticKeys - $foldedKeys
            estimated_size_threshold_passed = $semantic.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $semantic.estimated_frame_bytes - 483599
            estimated_size_delta_from_primary = $semantic.estimated_frame_bytes - 505046
            estimated_size_delta_from_identity_control = $semantic.estimated_frame_bytes - 504165
            interpretation = 'Exact pre-XOR existing semantic tuples; auxiliary payload is not decoded. Same four Bernoulli/global mixer formulas, no added context or exponent/class-mixer combination. Distinct-key difference is not a harmful-bit count. No speed, resources, holdout, or overall-goal evidence.'
        }
    } elseif ($RequireSemanticShadow) { throw 'Required semantic shadow is missing.' }
    if ($diagnostic.PSObject.Properties.Name -contains 'exponent_shadow') {
        if (-not $RequireExponentShadow) { throw 'Exponent shadow requires explicit provenance verification.' }
        $exponent = $diagnostic.exponent_shadow
        if (@($exponent.classes).Count -ne 7 -or $exponent.total_bits_calls -ne $sumBits) { throw 'Exponent shadow shape/bitcount mismatch.' }
        $exponentCount = 0L; $exponentLoss = 0.0
        $classChanges = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt 7; $i++) {
            $class = $exponent.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or -not [double]::IsFinite([double]$class.ideal_bits) -or $class.ideal_bits -lt 0) { throw 'Exponent shadow class/loss mismatch.' }
            $exponentCount += $class.bits; $exponentLoss += $class.ideal_bits
            $classChanges.Add([ordered]@{ class = $i; ideal_bit_delta_from_control = $class.ideal_bits - $diagnostic.sites[$i].actual_q15_bits })
        }
        if ($exponentCount -ne $sumBits -or -not [double]::IsFinite([double]$exponent.ideal_bits_total) -or [Math]::Abs($exponentLoss - $exponent.ideal_bits_total) -gt 0.01 -or
            $exponent.payload_bytes -lt 5 -or $exponent.payload_bytes -gt 134218752 -or $exponent.estimated_frame_bytes -ne $exponent.payload_bytes + 36 + 2 * $normal.alphabet_symbols -or
            [Math]::Abs(8 * $exponent.payload_bytes - $exponentLoss) -gt 8192) { throw 'Exponent aggregate/flush/frame accounting mismatch.' }
        $report.exponent_shadow = [ordered]@{
            observations = $exponent; ideal_bit_changes_by_class = $classChanges
            estimated_size_threshold_passed = $exponent.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $exponent.estimated_frame_bytes - 483599
            estimated_size_delta_from_control = $exponent.estimated_frame_bytes - 505046
            interpretation = 'Known decoded exponent conditions mantissa only; auxiliary payload is not decoded. Primary frame unchanged. Same fixed tables/coefficient/global mixer, no identity/class-mixer combination. No speed, resource, holdout, or general-performance evidence.'
        }
    } elseif ($RequireExponentShadow) { throw 'Required exponent shadow is missing.' }
    if ($diagnostic.PSObject.Properties.Name -contains 'cts_shadow') {
        if (-not $RequireCtsShadow -or $diagnostic.PSObject.Properties.Name -contains 'identity_shadow' -or
            $diagnostic.PSObject.Properties.Name -contains 'exponent_shadow' -or $diagnostic.PSObject.Properties.Name -contains 'semantic_shadow') { throw 'CTS requires explicit provenance and no other model shadow combinations.' }
        $cts = $diagnostic.cts_shadow
        if ($cts.depth -ne 16 -or $cts.precision_bits -ne 48 -or $cts.nodes_per_class -ne 131071 -or
            $cts.total_node_capacity -ne 917497 -or $cts.node_state_bytes -ne 16 -or $cts.state_capacity_bytes -ne 14679952 -or
            @($cts.classes).Count -ne 7 -or $cts.total_bits_calls -ne $sumBits) { throw 'CTS model shape/state capacity/bitcount mismatch.' }
        function Assert-CtsInteger([object]$Value, [long]$Minimum, [long]$Maximum) {
            if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { throw 'CTS missing/non-numeric counter.' }
            $v = [double]$Value
            if (-not [double]::IsFinite($v) -or $v -lt $Minimum -or $v -gt $Maximum -or $v -ne [Math]::Floor($v)) { throw 'CTS counter outside integer bounds.' }
        }
        $ctsCount = 0L; $ctsVisits = 0L; $ctsActive = 0L; $ctsRaw = 0.0; $ctsQ15 = 0.0; $ctsKT = 0.0
        $changes = [Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt 7; $i++) {
            $class = $cts.classes[$i]
            if ($class.class -ne $i -or $class.bits -ne $diagnostic.sites[$i].bits -or $class.node_visits -ne 17L * $class.bits) { throw 'CTS class count/visits mismatch.' }
            Assert-CtsInteger $class.active_nodes 1 131071
            foreach ($loss in @($class.raw_ideal_bits, $class.q15_ideal_bits, $class.root_kt_ideal_bits)) {
                if ($null -eq $loss -or $loss -is [string] -or $loss -is [bool] -or -not [double]::IsFinite([double]$loss) -or $loss -lt 0) { throw 'CTS nonfinite/nonnegative loss mismatch.' }
            }
            $ctsCount += $class.bits; $ctsVisits += $class.node_visits; $ctsActive += $class.active_nodes
            $ctsRaw += $class.raw_ideal_bits; $ctsQ15 += $class.q15_ideal_bits; $ctsKT += $class.root_kt_ideal_bits
            $changes.Add([ordered]@{ class = $i; ideal_q15_bit_delta_from_primary = $class.q15_ideal_bits - $diagnostic.sites[$i].actual_q15_bits })
        }
        foreach ($loss in @($cts.raw_ideal_bits_total, $cts.q15_ideal_bits_total, $cts.root_kt_ideal_bits_total)) {
            if ($null -eq $loss -or $loss -is [string] -or $loss -is [bool] -or -not [double]::IsFinite([double]$loss) -or $loss -lt 0) { throw 'CTS invalid aggregate loss.' }
        }
        Assert-CtsInteger $cts.active_nodes 7 917497
        Assert-CtsInteger $cts.node_visits 0 ([long]::MaxValue)
        Assert-CtsInteger $cts.payload_bytes 5 134218752
        Assert-CtsInteger $cts.estimated_frame_bytes 5 134219302
        Assert-CtsInteger $cts.q15_clamp_low 0 $sumBits
        Assert-CtsInteger $cts.q15_clamp_high 0 $sumBits
        Assert-CtsInteger $cts.self_checks.cases 6 100
        foreach ($errorValue in @($cts.self_checks.max_abs_prediction_error, $cts.self_checks.max_abs_weight_error)) {
            if ($null -eq $errorValue -or -not [double]::IsFinite([double]$errorValue) -or $errorValue -lt 0 -or $errorValue -gt 1e-6) { throw 'CTS reference self-check numeric mismatch.' }
        }
        if ($cts.self_checks.passed -isnot [bool] -or -not $cts.self_checks.passed -or $ctsCount -ne $sumBits -or
            $ctsVisits -ne $cts.node_visits -or $ctsVisits -ne 129584506 -or $ctsActive -ne $cts.active_nodes -or
            [Math]::Abs($ctsRaw - $cts.raw_ideal_bits_total) -gt 0.01 -or [Math]::Abs($ctsQ15 - $cts.q15_ideal_bits_total) -gt 0.01 -or
            [Math]::Abs($ctsKT - $cts.root_kt_ideal_bits_total) -gt 0.01 -or
            $cts.estimated_frame_bytes -ne $cts.payload_bytes + 36 + 2 * $normal.alphabet_symbols -or
            [Math]::Abs(8 * $cts.payload_bytes - $ctsQ15) -gt 8192) { throw 'CTS aggregate/self-check/flush/header accounting mismatch.' }
        $report.cts_shadow = [ordered]@{
            observations = $cts; ideal_bit_changes_by_class = $changes
            estimated_size_threshold_passed = $cts.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $cts.estimated_frame_bytes - 483599
            estimated_size_delta_from_primary = $cts.estimated_frame_bytes - 505046
            interpretation = 'Fixed depth16 Q48 CTS on separate class past-bit histories, not symbol/node experts or an exact real-valued theorem implementation. Auxiliary range payload is not decoded. Primary grammar/frame unchanged. No coefficient/context/depth sweeps, speed, OS peak or holdout claims.'
        }
    } elseif ($RequireCtsShadow) { throw 'Required CTS shadow is missing.' }
    if ($RequireBayesShadow) {
        $bayes = Assert-BayesPackedDiagnostic $diagnostic $normal $frame
        $frozen = Get-Content -LiteralPath $oldCts.path -Raw | ConvertFrom-Json
        if (($diagnostic.cts_shadow | ConvertTo-Json -Depth 10 -Compress) -cne ($frozen.cts_shadow.observations | ConvertTo-Json -Depth 10 -Compress)) { throw 'Frozen CTS numerical results changed.' }
        for ($i = 0; $i -lt 7; $i++) {
            if (($diagnostic.sites[$i] | ConvertTo-Json -Compress) -cne ($frozen.sites[$i] | ConvertTo-Json -Compress)) { throw 'Frozen primary numerical results changed.' }
        }
        $report['bayes_shadow'] = [ordered]@{
            observations = $bayes; estimated_size_threshold_passed = $bayes.estimated_frame_bytes -le 483599
            estimated_size_delta_from_threshold = $bayes.estimated_frame_bytes - 483599
            interpretation = 'Preobservation class-wise two-component likelihood weighting with exact packed alphabet metadata. Actual auxiliary payload is NOT decoded and no complete new frame, speed, memory, holdout or overall victory is established.'
        }
    }
    $restored = Join-Path $work 'restored.group'
    $decoded = Call-Codec $reference.path @('decode', $frame, $restored)
    if ($decoded.output.bytes -ne 2811006 -or $decoded.output.sha256 -cne $fixedHash) { throw 'Diagnostic frame failed reference round-trip.' }
    $report['restored_group'] = $decoded.output
    foreach ($row in $provenance) {
        $after = Identity $row.path; $row.after_bytes = $after.bytes; $row.after_sha256 = $after.sha256
        if ($row.before_bytes -ne $after.bytes -or $row.before_sha256 -cne $after.sha256) { throw 'Provenance changed.' }
    }
    $report.status = 'unchanged_frame_diagnostic_verified'
} catch { $report.error = $_.Exception.ToString(); $failure = $_ }
finally {
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    $reportPath = Join-Path $work 'report.json'
    $stream = [IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
    try { $writer.Write(($report | ConvertTo-Json -Depth 10)) } finally { $writer.Dispose() }
}
if ($null -ne $failure) { throw $failure }
Write-Host "Unchanged frame diagnostic verified: $reportPath"
$report.totals | ConvertTo-Json
