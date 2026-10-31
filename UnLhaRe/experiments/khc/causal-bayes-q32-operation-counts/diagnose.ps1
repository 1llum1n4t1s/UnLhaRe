#requires -Version 7.2
param([switch]$StaticOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $root 'build/khc-q32-operation-counts-20261001'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$identities = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
function No-Reparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse rejected: $current" }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path) {
    No-Reparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw "Not regular file: $Path" }
    [pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}
}
function Hold([string]$Path, [string]$Expected='', [string]$Role='source') {
    No-Reparse $Path
    $held = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
    $locks.Add($held)
    $before = Identity $Path
    if ($Expected -and $before.sha256 -cne $Expected) { throw "Pin mismatch: $Path" }
    $identities.Add([pscustomobject]@{role=$Role;before=$before;after=$null})
    return $before
}
function New-Bytes([string]$Path,[byte[]]$Data) {
    No-Reparse $Path
    $stream = [IO.File]::Open($Path,'CreateNew','Write','None')
    try { $stream.Write($Data); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Invoke-Recorded([string]$Name,[string]$Program,[string[]]$Argv,[int]$ExpectedExit=0) {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.WorkingDirectory=$work
    foreach ($arg in $Argv) { $info.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::new(); $p.StartInfo=$info
    $row = [ordered]@{name=$Name;program=$Program;argv=$Argv;expected_exit=$ExpectedExit;exit=$null;stdout='';stderr='';timeout=$false}
    $calls.Add($row)
    try {
        if (-not $p.Start()) { throw 'Process failed to start' }
        $outTask=$p.StandardOutput.ReadToEndAsync(); $errTask=$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(120000)) { $row.timeout=$true; $p.Kill($true); $p.WaitForExit() }
        $row.stdout=$outTask.GetAwaiter().GetResult(); $row.stderr=$errTask.GetAwaiter().GetResult(); $row.exit=$p.ExitCode
        if ($row.timeout) { throw "Timeout: $Name" }
        if ($row.exit -ne $ExpectedExit) { throw "Exit mismatch: $Name : $($row.stderr)" }
        return [pscustomobject]$row
    } finally { if (-not $p.HasExited) { $p.Kill($true); $p.WaitForExit() }; $p.Dispose() }
}
function Remove-Diagnostic([string]$Text) {
    # 診断cfgの直後のfield/item/block全体を消して通常経路を比較する。
    $lines=$Text.Replace("`r`n","`n").Split("`n")
    $kept=[Collections.Generic.List[string]]::new()
    for ($i=0;$i -lt $lines.Length;$i++) {
        if ($lines[$i].Trim() -ceq '#[cfg(khc_operation_counts)]') {
            $depth=0; $opened=$false
            do {
                $i++
                if ($i -ge $lines.Length) { throw 'Unclosed cfg item' }
                $line=$lines[$i]
                # JSON strings contain balanced braces; only brace balance is needed here.
                $opening=([regex]::Matches($line,'\{')).Count
                $closing=([regex]::Matches($line,'\}')).Count
                if ($opening) { $opened=$true }
                $depth += $opening-$closing
                if (-not $opened -and $line.Trim().EndsWith(',')) { break }
            } while (-not $opened -or $depth -ne 0)
        } else { $kept.Add($lines[$i]) }
    }
    return ($kept -join "`n").Trim()
}
function Static-Correspondence {
    foreach ($file in @('cts_model.rs','codec.rs')) {
        $old=[IO.File]::ReadAllText((Join-Path $PSScriptRoot "../causal-bayes-q32-balanced-kt/$file")).Replace("`r`n","`n").Trim()
        $clean=Remove-Diagnostic ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $file)))
        if ($file -ceq 'codec.rs') {
            $clean=$clean.Replace("    let payload = e.finish()?;`n    Ok((payload, alphabet, runs.len()))",'    Ok((e.finish()?, alphabet, runs.len()))')
        }
        # cfg削除が作る空行だけを正規化し、全演算と順序を比較する。
        if (($old -replace '\n\s*\n',"`n") -cne ($clean -replace '\n\s*\n',"`n")) { throw "Static correspondence failed: $file" }
    }
}
function Equal-Bytes([string]$Left,[string]$Right) {
    $a=[IO.File]::ReadAllBytes($Left); $b=[IO.File]::ReadAllBytes($Right)
    if ($a.Length -ne $b.Length) { throw 'Byte length differs' }
    for ($i=0;$i -lt $a.Length;$i++) { if ($a[$i] -ne $b[$i]) { throw "Byte differs at $i" } }
}
function Check-Counts($Counts) {
    foreach ($c in @($Counts.total)+@($Counts.classes | ForEach-Object {$_.counts})) {
        if ($c.predict_bits -ne $c.update_bits -or $c.kt_calls -ne 17*$c.update_bits -or $c.posterior_calls -ne 16*$c.update_bits -or $c.balanced_kt -gt $c.kt_calls -or $c.half_weight_identity -gt $c.ceiling_equals_pk -or $c.ceiling_equals_pk -gt $c.posterior_calls) { throw 'Counter bounds mismatch' }
    }
    if ($Counts.diagnostic -cne 'khc_operation_counts' -or @($Counts.classes).Count -ne 7) { throw 'Class schema mismatch' }
    for ($i=0;$i -lt 7;$i++) { if ($Counts.classes[$i].class -ne $i) { throw 'Class order mismatch' } }
    foreach ($field in @('predict_bits','update_bits','kt_calls','balanced_kt','posterior_calls','ceiling_equals_pk','half_weight_identity')) {
        [decimal]$sum=0
        foreach ($class in $Counts.classes) { $sum += $class.counts.$field }
        if ($sum -ne $Counts.total.$field) { throw "Class sum mismatch: $field" }
    }
}
if ($StaticOnly) {
    Static-Correspondence
    Write-Host 'Static correspondence passed: cfg diagnostic items removed; codec finish binding normalized.'
    foreach ($file in @('cts_model.rs','codec.rs','diagnose.ps1')) { Identity (Join-Path $PSScriptRoot $file) }
    return
}
No-Reparse $work
if (Test-Path -LiteralPath $work) { throw 'Work directory already exists; no automatic retry' }
New-Item -ItemType Directory -Path $work | Out-Null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');purpose='integer operation counts E2E; not speed measurement';ownership=@{root=$work;sources=@('cts_model.rs','codec.rs','diagnose.ps1');temporary_purpose='codec publication temporary files only'};identities=$identities;invocations=$calls;static_correspondence=$false;counts=$null;artifacts=$null;inventory=$null;owned_tmp_count=$null}
$failure=$null
try {
    New-Bytes (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes(($report.ownership|ConvertTo-Json)))
    $pins=@{
        'experiments/khc/Q32_CTS_OPERATION_COUNTS_CONTRACT_20261001.md'='67CBFA855066979E7AA61B5790D2B50C6B048986859F04DBFADC3AA6AF373348'
        'experiments/khc/causal-bayes-q32-balanced-kt/cts_model.rs'='9CFC6DF121A3711D704ED9F36F8D068F03A788DBC9F1A67118BB0CA89BD2F647'
        'experiments/khc/causal-bayes-q32-balanced-kt/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
        'experiments/khc/split-estimate-quotient/exact_div.rs'='D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'
        'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
        'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
        'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
        'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
        'build/khc-q32-balanced-kt-numeric-20261001-junction-validated/report.json'='63ACB1BBF1A2EFE811B76E761C6AA4CFDF2F4C443F75E24AD18FD97D312F5DAF'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/report.json'='AB486DC5C8CE3DAE36B1A91EACCE1BE77F7084F52122B26C3EC6A629C59A06F4'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'='7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
        'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    }
    foreach ($pin in $pins.GetEnumerator()) { $null=Hold (Join-Path $root $pin.Key) $pin.Value 'frozen-source-or-direct-parent-reference' }
    $null=Hold $compiler 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' 'native-compiler'
    foreach ($file in @('cts_model.rs','codec.rs','diagnose.ps1')) { $null=Hold (Join-Path $PSScriptRoot $file) '' 'diagnostic-source-freeze' }
    Static-Correspondence; $report.static_correspondence=$true
    $null=Invoke-Recorded 'compiler-version' $compiler @('--version')
    $normal=Join-Path $work 'normal.exe'; $diag=Join-Path $work 'diagnostic.exe'
    foreach ($build in @(@($normal,'normal'),@($diag,'diagnostic'))) {
        $argv=@((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2021','-C','opt-level=3','-o',$build[0])
        if ($build[1] -ceq 'diagnostic') { $argv += @('--cfg','khc_operation_counts') }
        $null=Invoke-Recorded "compile-$($build[1])" $compiler $argv
        $null=Hold $build[0] '' 'compiled-binary'
    }
    $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    $fixed=Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'
    if ((Identity $group).bytes -ne 2811006 -or (Identity $fixed).bytes -ne 483469) { throw 'Fixed length mismatch' }
    $encodes=[Collections.Generic.List[object]]::new()
    foreach ($run in @(@($normal,'normal'),@($diag,'diagnostic-1'),@($diag,'diagnostic-2'))) {
        $frame=Join-Path $work "$($run[1]).frame"
        $row=Invoke-Recorded "encode-$($run[1])" $run[0] @('encode',$group,$frame)
        Equal-Bytes $frame $fixed
        $stats=$row.stdout | ConvertFrom-Json
        if ($stats.operation -cne 'encode' -or $stats.input_bytes -ne 2811006 -or $stats.output_bytes -ne 483469) { throw 'Stats mismatch' }
        if ($run[1] -ceq 'normal') { if ($row.stderr.Length) { throw 'Normal stderr not empty' } } else {
            if (@($row.stderr.Trim().Split("`n")).Count -ne 1) { throw 'Diagnostic must be one JSON line' }
            Check-Counts ($row.stderr | ConvertFrom-Json)
        }
        $encodes.Add($row); $null=Hold $frame '' 'encoded-frame'
    }
    if ($encodes[1].stderr -cne $encodes[2].stderr -or $encodes[0].stdout -cne $encodes[1].stdout -or $encodes[1].stdout -cne $encodes[2].stdout) { throw 'Repeated counts or Stats differ' }
    $report.counts=$encodes[1].stderr | ConvertFrom-Json
    $restored=Join-Path $work 'restored.group'
    $row=Invoke-Recorded 'diagnostic-decode-normal' $diag @('decode',(Join-Path $work 'normal.frame'),$restored)
    if ($row.stderr.Length) { throw 'Decode stderr not empty' }
    $stats=$row.stdout | ConvertFrom-Json
    if ($stats.operation -cne 'decode' -or $stats.input_bytes -ne 483469 -or $stats.output_bytes -ne 2811006) { throw 'Decode Stats mismatch' }
    Equal-Bytes $restored $group; $null=Hold $restored '' 'restored-group'
    foreach ($run in @(@($normal,'normal'),@($diag,'diagnostic'))) {
        $sentinel=Join-Path $work "$($run[1]).sentinel"
        New-Bytes $sentinel ([byte[]]@(31,41,59,26)); $before=Hold $sentinel '' 'no-clobber-sentinel'
        $row=Invoke-Recorded "no-clobber-$($run[1])" $run[0] @('encode',$group,$sentinel) 1
        $reasonLines=@($row.stderr.Trim().Split("`n"))
        if ($row.stdout.Length -or -not $reasonLines[-1].Trim().StartsWith('rejected: output create_new:',[StringComparison]::Ordinal) -or -not $reasonLines[-1].Contains('(os error 80)')) { throw "Wrong no-clobber reason: $($row.stderr)" }
        if ($run[1] -ceq 'normal' -and $reasonLines.Count -ne 1) { throw 'Unexpected normal no-clobber stderr' }
        if ($run[1] -ceq 'diagnostic') {
            if ($reasonLines.Count -ne 2) { throw 'Unexpected diagnostic no-clobber stderr' }
            if ($reasonLines[0].Trim() -cne $encodes[1].stderr.Trim()) { throw 'No-clobber diagnostic counts differ' }
        }
        $after=Identity $sentinel
        if ($before.sha256 -cne $after.sha256 -or $after.bytes -ne 4) { throw 'Sentinel changed' }
    }
    foreach ($id in $identities) {
        $id.after=Identity $id.before.path
        if ($id.before.sha256 -cne $id.after.sha256 -or $id.before.bytes -ne $id.after.bytes) { throw "Identity changed: $($id.before.path)" }
    }
    $report.artifacts=@(Get-ChildItem -LiteralPath $work -File | ForEach-Object { Identity $_.FullName })
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force -Recurse | Select-Object FullName,Length,Attributes)
    $report.owned_tmp_count=@(Get-ChildItem -LiteralPath $work -Force -Recurse -File | Where-Object Name -Like '*.tmp').Count
    if ($report.owned_tmp_count -ne 0) { throw 'Temporary files remain' }
    $report.status='integer_counts_and_archive_e2e_passed_not_timed'
} catch { $failure=$_; $report.error=$_.Exception.ToString() }
finally {
    foreach ($id in $identities) {
        if ($null -eq $id.after) { try { $id.after=Identity $id.before.path } catch { $report.error += "`nSource-after failed: $($_.Exception.Message)" } }
    }
    if ($null -eq $report.inventory) { $report.inventory=@(Get-ChildItem -LiteralPath $work -Force -Recurse | Select-Object FullName,Length,Attributes) }
    if ($null -eq $report.artifacts) { $report.artifacts=@(Get-ChildItem -LiteralPath $work -File | ForEach-Object { Identity $_.FullName }) }
    if ($null -eq $report.owned_tmp_count) { $report.owned_tmp_count=@(Get-ChildItem -LiteralPath $work -Force -Recurse -File | Where-Object Name -Like '*.tmp').Count }
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    New-Bytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 18)))
}
if ($failure) { throw $failure }
Write-Host "E2E $($report.status): report=$work/report.json"
