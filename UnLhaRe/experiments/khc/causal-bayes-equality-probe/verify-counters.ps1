#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# 保存済み実CLIの診断JSONを検証。速度比較・codec再実行はしない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$ownedRoot=Join-Path $root 'build/khc-bwt-causal-bayes-equality-probe-20260930'
$sourceProof=Join-Path $ownedRoot 'full-e2e/report.json'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$buildPrefix=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$identities=[Collections.Generic.List[object]]::new()
$rows=[Collections.Generic.List[object]]::new()
$failure=$null
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash}}
function Track([string]$Path){No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path;$identities.Add($id);return $id}
function Metrics([object]$Json){
    $v=[ordered]@{}
    foreach($name in @('predict_bits','update_bits','kt_calls','kt_fresh','mixture_calls','mixture_equal','posterior_calls','posterior_equal','retained_calls','retained_half')){
        $property=$Json.PSObject.Properties["cts_$name"]
        if($null -eq $property){throw "Missing CTS metric: $name"}
        $value=$property.Value
        if($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint64]){throw "Non-integer CTS metric: $name"}
        if($value -lt 0){throw 'Negative CTS metric.'}
        $v[$name]=[long]$value
    }
    $bits=$v.predict_bits
    if($bits -gt 128L*8388609L -or $bits -ne $v.update_bits -or $v.kt_calls -ne $bits*17L -or $v.mixture_calls -ne $bits*16L -or $v.posterior_calls -ne $bits*16L -or $v.retained_calls -ne $bits*16L){throw 'CTS per-bit counter invariant failed.'}
    foreach($pair in @(@('kt_fresh','kt_calls'),@('mixture_equal','mixture_calls'),@('posterior_equal','posterior_calls'),@('retained_half','retained_calls'))){if($v[$pair[0]] -gt $v[$pair[1]]){throw 'CTS hit exceeds attempts.'}}
    return [pscustomobject]$v
}
if(-not $work.StartsWith($buildPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work;$null=New-Item -ItemType Directory -Path $work
$report=[ordered]@{status='failed';error=$null;source_report=$null;identities=$identities;verified_success_json=$rows;fixture_comparisons=@();fixed_metrics=$null;timing_used=$false;notes=@('Conditions are exact integer identities; frequencies are not CPU shares or speed improvement rates.','Original arithmetic is still executed; no optimization or model change.','Eight fixed correctness inputs including Canterbury development group, not holdout or overall 7-Zip victory.')}
try{
    $proof=Track $sourceProof;$report.source_report=$proof
    $null=Track $PSCommandPath
    $json=Get-Content -LiteralPath $proof.path -Raw|ConvertFrom-Json
    if($json.status -cne 'correctness_and_size_passed_not_timed' -or @($json.checks).Count -ne 36 -or @($json.invocations).Count -ne 61 -or @($json.checks|Where-Object {-not $_.passed}).Count -ne 0){throw 'Full E2E proof incomplete.'}
    foreach($id in $json.provenance){$current=Track $id.path;if($current.sha256 -cne $id.before_sha256 -or $id.before_sha256 -cne $id.after_sha256 -or $current.bytes -ne $id.before_bytes -or $id.before_bytes -ne $id.after_bytes){throw 'Provenance identity changed.'}}
    $binary=@($json.provenance|Where-Object {$_.role -ceq 'binary'})
    if($binary.Count -ne 1){throw 'Ambiguous diagnostic binary.'}
    foreach($call in $json.invocations){
        if($call.exit -ne $call.expected_exit -or $call.timeout){throw 'CLI exit/timeout mismatch.'}
        if($call.expected_exit -ne 0 -or $call.program -cne $binary[0].path){continue}
        if($call.stderr){throw 'Successful diagnostic CLI stderr.'}
        $decoded=$call.stdout|ConvertFrom-Json
        if($decoded.operation -cne $call.argv[0]){throw 'Operation mismatch.'}
        $value=Metrics $decoded
        $actual=Track $call.output.path
        if($actual.sha256 -cne $call.output.sha256 -or $actual.bytes -ne $call.output.bytes){throw 'Success output identity mismatch.'}
        $fixture=[IO.Path]::GetFileNameWithoutExtension($call.argv[1])
        $rows.Add([pscustomobject]@{name=$call.name;operation=$decoded.operation;fixture=$fixture;metrics=$value;output=$actual})
    }
    if($rows.Count -ne 24){throw 'Expected 24 diagnostic successful CLI JSON records.'}
    $comparison=[Collections.Generic.List[object]]::new()
    foreach($name in @('empty','single','single_high','all_bytes','repeated','periodic','seeded_random','fixed')){
        $fixtureRows=@($rows|Where-Object {$_.fixture -ceq $name})
        if($fixtureRows.Count -ne 3 -or @($fixtureRows|Where-Object {$_.operation -ceq 'encode'}).Count -ne 2 -or @($fixtureRows|Where-Object {$_.operation -ceq 'decode'}).Count -ne 1){throw 'Fixture encode/repeat/decode boundary differs.'}
        $canonical=$fixtureRows[0].metrics|ConvertTo-Json -Compress
        foreach($row in $fixtureRows){if(($row.metrics|ConvertTo-Json -Compress) -cne $canonical){throw 'Encode/repeat/decode counters differ.'}}
        $comparison.Add([pscustomobject]@{fixture=$name;successful_cli=3;metrics=$fixtureRows[0].metrics;all_equal=$true})
        if($name -ceq 'fixed'){$m=$fixtureRows[0].metrics;$report.fixed_metrics=[pscustomobject]@{counters=$m;kt_fresh_fraction=$m.kt_fresh/$m.kt_calls;mixture_equal_fraction=$m.mixture_equal/$m.mixture_calls;posterior_equal_fraction=$m.posterior_equal/$m.posterior_calls;retained_half_fraction=$m.retained_half/$m.retained_calls}}
    }
    $report.fixture_comparisons=$comparison.ToArray();$report.status='verified'
}catch{$failure=$_;$report.error=$_.Exception.ToString()}
finally{
    foreach($id in $identities){try{$current=Identity $id.path;if($current.sha256 -cne $id.sha256 -or $current.bytes -ne $id.bytes){throw 'Identity changed during verification.'}}catch{$failure=$_;$report.status='failed';$report.error=$_.Exception.ToString()}}
    foreach($held in $locks){$held.Dispose()}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    $out=Join-Path $work 'report.json';$stream=[IO.File]::Open($out,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)));$stream.Flush($true)}finally{$stream.Dispose()}
}
if($null -ne $failure){throw $failure}
"CTS equality counters PASS: $($rows.Count) successful CLI / $($report.fixture_comparisons.Count) fixtures."
$report.fixed_metrics|ConvertTo-Json -Depth 4
