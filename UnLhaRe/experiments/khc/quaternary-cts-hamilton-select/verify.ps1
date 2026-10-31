[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$output = Join-Path $project 'build/khc-quaternary-cts-hamilton-select-20261004'
$exe = Join-Path $output 'hamilton-select-o2.exe'
$basisPath = Join-Path $project 'build/khc-quaternary-cts-inner-split-20261004/report.json'
$inputPath = Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$rustc = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$pwsh = 'C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$report = [ordered]@{ schema_version=1; status='planned'; diagnostic_only=$true; formal_speed_CPU_verified=$false; records=@(); identities=@(); phases=@(); timing=$null; error=$null }
function NoLinks([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "reparse path: $p" }
        }
        $p = [IO.Path]::GetDirectoryName($p)
    }
}
function Identity([string]$Path) {
    NoLinks $Path
    $f = Get-Item -LiteralPath $Path -Force
    if ($f.PSIsContainer) { throw 'identity is directory' }
    [ordered]@{path=$f.FullName;sha256=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash;bytes=$f.Length;mtime_utc=$f.LastWriteTimeUtc.ToString('o')}
}
function CheckIdentity($Expected) {
    $actual = Identity $Expected.path
    $expectedTicks = [DateTimeOffset]::Parse($Expected.mtime_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).UtcTicks
    $actualTicks = [DateTimeOffset]::Parse($actual.mtime_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).UtcTicks
    if ($actual.sha256 -cne $Expected.sha256 -or $actual.bytes -ne $Expected.bytes -or $actualTicks -ne $expectedTicks) { throw "identity mismatch: $($Expected.path)" }
}
function CheckAll([string]$Phase) {
    foreach ($id in $report.identities) { CheckIdentity $id }
    $report.phases += [ordered]@{name=$Phase;count=$report.identities.Count;mismatches=0}
}
function OwnedProcesses {
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and [string]::Equals($_.ExecutablePath,$exe,[StringComparison]::OrdinalIgnoreCase) } | Select-Object ProcessId,Name,ExecutablePath)
}
function Native([string]$Program,[string[]]$Arguments,[int]$Seconds) {
    $si = [Diagnostics.ProcessStartInfo]::new($Program)
    $si.UseShellExecute=$false; $si.CreateNoWindow=$true
    $si.RedirectStandardOutput=$true; $si.RedirectStandardError=$true; $si.WorkingDirectory=$project
    foreach ($arg in $Arguments) { $si.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::new(); $p.StartInfo=$si
    $out = [IO.MemoryStream]::new(); $err = [IO.MemoryStream]::new()
    $watch=[Diagnostics.Stopwatch]::StartNew(); $timedOut=$false; $over=$false; $started=$false
    try {
        $started=$p.Start(); if (!$started) { throw 'child start failed' }
        $ob=[byte[]]::new(4096); $eb=[byte[]]::new(4096)
        $ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length)
        $et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length)
        while ($null -ne $ot -or $null -ne $et -or !$p.HasExited) {
            if ($null -ne $ot -and $ot.IsCompleted) {
                $n=$ot.GetAwaiter().GetResult()
                if ($n -eq 0) { $ot=$null } else {
                    if ($out.Length+$n -gt 65536) { $over=$true; break }
                    $out.Write($ob,0,$n); $ot=$p.StandardOutput.BaseStream.ReadAsync($ob,0,$ob.Length)
                }
            }
            if ($null -ne $et -and $et.IsCompleted) {
                $n=$et.GetAwaiter().GetResult()
                if ($n -eq 0) { $et=$null } else {
                    if ($err.Length+$n -gt 16384) { $over=$true; break }
                    $err.Write($eb,0,$n); $et=$p.StandardError.BaseStream.ReadAsync($eb,0,$eb.Length)
                }
            }
            if ($watch.Elapsed.TotalSeconds -gt $Seconds) { $timedOut=$true; break }
            Start-Sleep -Milliseconds 20
        }
        if ($timedOut -or $over) { if (!$p.HasExited) { $p.Kill($true) }; if (!$p.WaitForExit(10000)) { throw 'owned child did not exit' } }
        else { $p.WaitForExit() }
        $record=[ordered]@{path=$Program;arguments=$Arguments;exit_code=$p.ExitCode;elapsed_ms=$watch.Elapsed.TotalMilliseconds;timeout=$timedOut;output_overflow=$over;stdout_bytes=$out.Length;stderr_bytes=$err.Length;stdout=[Text.Encoding]::UTF8.GetString($out.ToArray());stderr=[Text.Encoding]::UTF8.GetString($err.ToArray())}
        $report.records += $record
        if ($timedOut -or $over -or $p.ExitCode -ne 0) { throw "child failure: $Program, exit=$($p.ExitCode), timeout=$timedOut, overflow=$over" }
        $record
    } finally {
        if ($started -and !$p.HasExited) { $p.Kill($true); [void]$p.WaitForExit(10000) }
        $p.Dispose(); $out.Dispose(); $err.Dispose()
    }
}
function SameBody([string]$Left,[string]$Right,[string]$From,[string]$To) {
    $a=[IO.File]::ReadAllText($Left).Replace("`r`n","`n").TrimEnd("`n")
    $b=[IO.File]::ReadAllText($Right).Replace("`r`n","`n").TrimEnd("`n")
    $expected=if ($From.Length) {$a.Replace($From,$To)} else {$a}
    if ($expected -cne $b) { throw "non-allowlist source difference: $Right" }
}
NoLinks $output
if (Test-Path -LiteralPath $output) { throw 'fresh output already exists; inspect it read-only, do not rerun' }
$basisId=Identity $basisPath
if ($basisId.sha256 -cne '59C4C8B73DF3275303D52629C3862CD1F83D260AF60EC9E4D8A024AA95571562') { throw 'basis hash mismatch' }
$basis=Get-Content -LiteralPath $basisPath -Raw | ConvertFrom-Json -DateKind String
if ($basis.status -cne 'passed' -or $basis.identities.Count -ne 215) { throw 'basis status/count' }
$report.identities=@($basis.identities) + @($basisId,$basis.executable_after)
$compiler=Identity $rustc; $runtime=Identity $pwsh; $inputId=Identity $inputPath
if ($compiler.sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC' -or
    $runtime.sha256 -cne '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139' -or
    $inputId.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76' -or $inputId.bytes -ne 2811006) { throw 'tool/input pin mismatch' }
$newFiles=@(Get-ChildItem -LiteralPath $PSScriptRoot -File -Force)
if ($newFiles.Count -ne 7 -or ($newFiles | Measure-Object Length -Sum).Sum -gt 307200) { throw 'source count/budget' }
foreach ($file in $newFiles) { $report.identities += ,(Identity $file.FullName) }
$template=Join-Path $PSScriptRoot '../quaternary-cts-kt-equal'
foreach ($name in @('codec.rs','optimized_codec.rs','probe.rs')) {
    $id=Identity (Join-Path $template $name)
    if (!@($report.identities | Where-Object {$_.path -eq $id.path}).Count) { throw 'template absent in inherited frozen evidence' }
}
SameBody (Join-Path $template 'codec.rs') (Join-Path $PSScriptRoot 'codec.rs') '' ''
$a=[IO.File]::ReadAllText((Join-Path $template 'optimized_codec.rs')).Replace("`r`n","`n").TrimEnd("`n")
$b=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'optimized_codec.rs')).Replace("`r`n","`n").TrimEnd("`n")
if ($a -cne $b) { throw 'candidate codec non-allowlist difference' }
$oldKt=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../quaternary-cts-depth/integer_cts.rs')).Replace("`r`n","`n").TrimEnd("`n")
$newKt=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'integer_cts.rs')).Replace("`r`n","`n").TrimEnd("`n")
$oldStep='    let mut order=[0usize,1,2,3];order[..k].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));'
$newStep=@'
    let mut order=[0usize,1,2,3];
    if left==1 {
        let mut best=0;for j in 1..k {if remainder[j]>remainder[best]{best=j;}}order[0]=best;
    }else if left>=2 {
        order[..k].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));
    }
'@
$newStep=$newStep.Replace("`r`n","`n")
if (($oldKt.Split($oldStep).Count-1) -ne 2 -or ($newKt.Split($newStep).Count-1) -ne 2) { throw 'Hamilton allowlist block count' }
if ($newKt.Replace($newStep,$oldStep) -cne $oldKt) { throw 'Hamilton inverse non-allowlist difference' }
$report.body_allowlist=[ordered]@{codec='exact kt-equal baseline';candidate_codec='exact kt-equal candidate codec (original CTS selected)';cts='two Hamilton selection blocks inverse-restored exactly';other_numeric_changes=0}
# path付きRustグラフの全参照を証拠表と接続する。
$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue((Join-Path $PSScriptRoot 'probe.rs'))
while ($queue.Count) {
    $path=[IO.Path]::GetFullPath($queue.Dequeue()); if (!$seen.Add($path)) { continue }
    if ($seen.Count -gt 32) { throw 'graph node limit' }
    if (!@($report.identities | Where-Object { $_.path -eq $path }).Count) { throw "unidentified graph source: $path" }
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($path),'#\[path\s*=\s*"([^"]+)"\]')) { $queue.Enqueue([IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) $m.Groups[1].Value))) }
}
$report.graph=@($seen | Sort-Object)
if ($report.identities.Count -ne 224) { throw 'new identity exact count' }
foreach ($id in $report.identities) {
    if ([Text.Encoding]::UTF8.GetByteCount(($id | ConvertTo-Json -Compress)) -gt 768) { throw 'identity record bound' }
}
$report.capacity_plan=[ordered]@{identity_records=$report.identities.Count;identity_record_bytes=768;other_bytes=65536;report_bytes=262144;source_bytes=307200;executable_bytes=1048576;native_stdout_bytes=65536;native_stderr_bytes=16384;retained_stream_preview_chars=1024}
if ($report.identities.Count*768+65536 -gt 262144) { throw 'report capacity estimate' }
CheckAll 'before'
$report.disk_before=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $output -MaxRunMiB 8
if (@(OwnedProcesses).Count) { throw 'owned executable process already active' }
if (!$Execute) { [ordered]@{status='preflight_passed';identity_count=$report.identities.Count;graph_count=$seen.Count;disk_before=$report.disk_before} | ConvertTo-Json -Depth 5; return }
[void](New-Item -ItemType Directory -Path $output)
try {
    $report.status='running'
    $args=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE',(Join-Path $PSScriptRoot 'probe.rs'),'-o',$exe)
    $compile=Native $rustc $args 60
    $report.executable_before=Identity $exe
    if ($report.executable_before.bytes -gt 1048576) { throw 'executable size bound' }
    $math=Native $exe @('compare-kt') 60
    $report.math=$math.stdout.Trim() | ConvertFrom-Json -DateKind String
    if ($report.math.status -cne 'passed' -or $report.math.comparisons -ne 17320 -or $report.math.accepted -ne 17262 -or $report.math.rejected -ne 58 -or
        $report.math.old_rejection_calls -ne 1 -or $report.math.new_rejection_calls -ne 1 -or $report.math.rejection_assertions -ne 32 -or $report.math.mixture_comparisons -ne 4137 -or $report.math.mixture_accepted -ne 4126 -or $report.math.mixture_rejected -ne 11 -or $report.math.cts_accepted -ne 4 -or $report.math.cts_rejected -ne 6 -or $report.math.mixture_left1_max_ties -lt 1 -or @($report.math.mixture_left_counts | Where-Object {$_ -lt 1}).Count) { throw 'KT comparison did not pass' }
    $abba=Native $exe @('abba',$inputPath) 120
    $lines=@($abba.stdout.Trim() -split '\r?\n')
    if ($lines.Count -ne 5) { throw 'ABBA record count' }
    $report.candidate=$lines[-1] | ConvertFrom-Json -DateKind String
    if ($report.candidate.status -cne 'passed' -or $report.candidate.runs_completed -ne 4 -or $report.candidate.repeat_frame_matched_bytes -ne 1436250 -or $report.candidate.plain_comparisons -ne 4 -or $report.candidate.reference_stats_comparisons -ne 3) { throw 'ABBA completeness gate' }
    $runs=$report.candidate.records
    $oldEnc=($runs[0].encode_elapsed_ns+$runs[3].encode_elapsed_ns)/2.0
    $newEnc=($runs[1].encode_elapsed_ns+$runs[2].encode_elapsed_ns)/2.0
    $oldDec=($runs[0].decode_elapsed_ns+$runs[3].decode_elapsed_ns)/2.0
    $newDec=($runs[1].decode_elapsed_ns+$runs[2].decode_elapsed_ns)/2.0
    $report.timing=[ordered]@{median_sample_count_per_direction=2;old_encode_median_ms=$oldEnc/1e6;new_encode_median_ms=$newEnc/1e6;old_decode_median_ms=$oldDec/1e6;new_decode_median_ms=$newDec/1e6;old_encode_ms=$oldEnc/1e6;new_encode_ms=$newEnc/1e6;old_decode_ms=$oldDec/1e6;new_decode_ms=$newDec/1e6;encode_change_percent=100*($newEnc/$oldEnc-1);decode_change_percent=100*($newDec/$oldDec-1);both_directions_shorter=($newEnc -lt $oldEnc -and $newDec -lt $oldDec);formal_adoption=$false}
    CheckIdentity $report.executable_before
    $report.executable_after=Identity $exe
    CheckAll 'after'
    CheckAll 'live'
    $report.status='passed'
} catch { $report.status='failed'; $report.error=$_.Exception.Message }
finally {
    try { $report.owned_processes_at_end=@(OwnedProcesses); if ($report.owned_processes_at_end.Count) { $report.status='failed'; $report.error='owned process remains' } }
    catch { $report.status='failed'; $report.error="process census failed: $($_.Exception.Message)" }
    try { $report.disk_after=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $output -MaxRunMiB 8 }
    catch { $report.status='failed'; $report.error="disk check failed: $($_.Exception.Message)" }
    foreach ($record in $report.records) {
        foreach ($field in @('stdout','stderr')) {
            $raw=$record[$field]
            $record[$field+'_sha256']=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($raw)))
            $record[$field]=$raw.Substring(0,[Math]::Min(1024,$raw.Length))
            $record[$field+'_preview_truncated']=($raw.Length -gt 1024)
        }
    }
    $other=[ordered]@{}; foreach ($key in $report.Keys) { if ($key -ne 'identities') { $other[$key]=$report[$key] } }
    if ([Text.Encoding]::UTF8.GetByteCount(($other | ConvertTo-Json -Depth 30)) -gt 65536) { throw 'non-identity report section bound' }
    $json=$report | ConvertTo-Json -Depth 30
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 262144) { throw 'report exceeds 256KiB; preserve evidence in memory, no oversized write' }
    $reportPath=Join-Path $output 'report.json'
    if (Test-Path -LiteralPath $reportPath) { throw 'report already exists' }
    # 生成JSONは機械出力。source編集にはapply_patchを使用する。
    [IO.File]::WriteAllText($reportPath,$json,[Text.UTF8Encoding]::new($false))
    & (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $output -MaxRunMiB 8 | Out-Null
}
[ordered]@{status=$report.status;report=(Identity (Join-Path $output 'report.json'));timing=$report.timing;error=$report.error} | ConvertTo-Json -Depth 6
if ($report.status -cne 'passed') { throw $report.error }
