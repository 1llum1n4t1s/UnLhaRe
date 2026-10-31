#requires -Version 7.5
[CmdletBinding()]
param(
    [string]$WorkDirectory,
    [Parameter(Mandatory)][string]$ProtocolPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ProtocolSha256,
    [switch]$ValidateProtocolOnly,
    [switch]$StopBeforeRegistration,
    [string]$StopReason,
    [ValidateCount(0,5)][object[]]$CpuSamples=@()
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$campaign='D:\Codex\TaskArtifacts\UnLhaRe\goal-restore-20261019\kcs1-replay-20261020'
$claimPath=Join-Path $campaign 'performance-claim.json'
$stopPath=Join-Path $campaign 'performance-pre-registration-stop.json'
$admissionMutexName='Local\KHC-Spatial-Replay-Admission-goal-restore-20261019'
function Plain([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ($Path -cne $full) { throw "Canonical absolute path required: $Path" }
    for ($part=$full; $part; $part=[IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Reparse point: $part" }
    }
    return $full
}
function Sha([string]$Path) { return (Get-FileHash -LiteralPath (Plain $Path) -Algorithm SHA256).Hash.ToLowerInvariant() }
function SameBytes([byte[]]$Left,[byte[]]$Right) {
    return $Left.Length -eq $Right.Length -and [string]::Equals([Convert]::ToBase64String($Left),[Convert]::ToBase64String($Right),[StringComparison]::Ordinal)
}
function Tail([string]$Text,[int]$Limit) { if($Text.Length -le $Limit){return $Text}; return $Text.Substring($Text.Length-$Limit) }
function NewText([string]$Path,[string]$Text) {
    $null=Plain $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Text); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Manifest([string]$Root,[int]$Count) {
    $null=Plain $Root
    foreach ($directory in Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force) { $null=Plain $directory.FullName }
    $map=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in Get-ChildItem -LiteralPath $Root -Filter '*.rs' -File -Recurse -Force) {
        $null=Plain $item.FullName
        $map.Add([IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/'),$item.FullName)
    }
    if ($map.Count -ne $Count) { throw "Source manifest count changed: $Root" }
    $names=[string[]]$map.Keys; [Array]::Sort($names,[StringComparer]::Ordinal)
    $text=[Text.StringBuilder]::new()
    foreach ($name in $names) { $file=Get-Item -LiteralPath $map[$name]; $null=$text.Append($name).Append([char]9).Append($file.Length).Append([char]9).Append((Sha $file.FullName)).Append([char]10) }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text.ToString()))).ToLowerInvariant()
}
$fixed=[ordered]@{
    schema='kcs1-replay-performance-v1'; task_id='goal-restore-20261019'; runs=1; retries=0
    powershell_min_version='7.5'
    rounds=5; warmups=0; rotation_positions=5; strategies='baseline,replay,7zip-mx1,7zip-mx3,7zip-mx5,7zip-mx7,7zip-mx9'
    max_run_mib=28; max_entries=128; outer_seconds=900; child_seconds=60; child_memory_bytes=167772160
    version_capture_bytes_per_stream=32768; command_capture_bytes_per_stream=4096; report_max_utf8_bytes=2097152; report_tail_characters=256
    cleanup_timeout_milliseconds=5000; error_max_characters=1024; cleanup_error_max_characters=256
    admission_mutex='Local\KHC-Spatial-Replay-Admission-goal-restore-20261019'
    cpu_samples=5; cpu_interval_seconds=1; cpu_max_percent=15; source_timestamp_utc='2020-01-01T00:00:00Z'
    seven_zip_version='26.04'; seven_zip_options='-t7z,-m0=lzma2:d=64m,-mmt=1,-ms=on,-mqs=off,-mtm=off,-mtc=off,-mta=off'
    input_member='input/ptt5'; input_bytes=513216; input_sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
    rust_files=37; rust_manifest_sha256='ce9330c08bfd878fb5603f59c8a527c51307204d9c748bc98e88a3d2aa4335f6'
    khc_files=27; khc_manifest_sha256='d674bd9ec8a02e92f06e83f4b8e1a938292dbeda254afcc4b896cfdca0707572'
    archive_revision=7; frame_magic='KCS1BLK'; frame_count=1; khc_timestamp_fee='retain full archive bytes conservatively'
    seven_zip_time_ratio=0.95; source_encode_ratio=0.95; source_extract_ratio=1.05; source_memory_allowance_bytes=16777216
    selection_rule='fastest combined median among all five 7zip profiles with archive bytes >= replay; encode and extract <=95%; four directional and aggregate WS/page peaks <= baseline; no five-profile size/time/memory domination'
    archive_rule='every strategy deterministic across five rounds; all old/new archives byte-identical; replay bytes <= baseline'
    scope='ptt5 development only; no holdout/general superiority; five rotations incompletely balance seven positions; no warmup; OS filesystem extraction; MSVC source ablation only'
}
$expectedPins=[ordered]@{
    baseline=@((Join-Path $campaign 'baseline-unlhare-cli.exe'),'453b03419aa5d22a0702fba32ecb30187637044c196163039923ff5962d9b6dd',2583552)
    replay=@((Join-Path $campaign 'replay-msvc-unlhare-cli.exe'),'e13e110d491cac1a54ae340bca59f94f86ec55c951e65aab33a21daaea4b132e',2584576)
    seven_zip=@('C:\Program Files\7-Zip\7z.exe','95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53',$null)
    input_zip=@('D:\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip','882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75',$null)
    worker=@($PSCommandPath,$null,$null)
    runner=@((Join-Path $PSScriptRoot 'run-storage-experiment.ps1'),$null,$null)
    shared_module=@((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'),$null,$null)
}
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src'))
function CheckPins {
    if ((Sha $ProtocolPath) -cne $ProtocolSha256) { throw 'Protocol SHA changed.' }
    foreach ($key in $expectedPins.Keys) {
        $pin=$protocol.pins.$key; $expected=$expectedPins[$key]
        if ([string]$pin.path -cne $expected[0] -or [string]$pin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $null -eq $pin.bytes -or [long]$pin.bytes -le 0) { throw "Missing/invalid pin: $key" }
        if ($null -ne $expected[1] -and $pin.sha256 -cne $expected[1]) { throw "Wrong fixed SHA: $key" }
        if ($null -ne $expected[2] -and [long]$pin.bytes -ne $expected[2]) { throw "Wrong fixed size: $key" }
        if ((Get-Item -LiteralPath (Plain $pin.path)).Length -ne [long]$pin.bytes -or (Sha $pin.path) -cne $pin.sha256) { throw "Pin mismatch: $key" }
    }
    if ((Manifest $sourceRoot 37) -cne $fixed.rust_manifest_sha256 -or (Manifest (Join-Path $sourceRoot 'khc') 27) -cne $fixed.khc_manifest_sha256) { throw 'Source manifest changed.' }
}
if ((Plain $ProtocolPath) -cne (Join-Path $campaign 'performance-protocol.json')) { throw 'Wrong protocol path.' }
if ($StopBeforeRegistration) {
    # メタデータ専用の閉鎖入口。壊れた/未freeze protocolでも停止を記録でき、pinの正当性は主張しない。
    if ($ValidateProtocolOnly -or $WorkDirectory -or [string]::IsNullOrWhiteSpace($StopReason) -or $StopReason.Length -gt 1024 -or $env:KHC_STORAGE_TASK_ID -cne $fixed.task_id) { throw 'Invalid pre-registration stop metadata.' }
    $mutex=[Threading.Mutex]::new($false,$admissionMutexName); $held=$false
    try {
        try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true; throw 'Abandoned admission mutex; stop was not issued.' }
        if (-not $held) { throw 'Admission mutex busy; stop was not issued.' }
        foreach ($path in @($claimPath,$stopPath)) { $null=Plain $path; if (Test-Path -LiteralPath $path) { throw 'Already claimed/stopped; pre-registration stop refused.' } }
        $metadata=@($CpuSamples | ForEach-Object { $value=[string]$_; if($value.Length -gt 64){$value=$value.Substring(0,64)}; $value })
        NewText $stopPath (([ordered]@{schema=$fixed.schema;status='stopped-before-registration';utc=[DateTime]::UtcNow.ToString('o');reason=$StopReason;cpu_samples=$metadata;protocol_path=$ProtocolPath;supplied_protocol_sha256=$ProtocolSha256;protocol_pins_attested=$false} | ConvertTo-Json -Depth 5 -Compress))
    } finally { if($held){$mutex.ReleaseMutex()}; $mutex.Dispose() }
    return
}
if ($StopReason -or $CpuSamples.Count -ne 0) { throw 'Stop metadata is only accepted by StopBeforeRegistration.' }
if ((Sha $ProtocolPath) -cne $ProtocolSha256) { throw 'Protocol SHA mismatch.' }
$protocol=Get-Content -LiteralPath $ProtocolPath -Raw | ConvertFrom-Json -DateKind String
foreach ($key in $fixed.Keys) {
    if ($null -eq $protocol.settings.$key -or [string]$protocol.settings.$key -cne [string]$fixed[$key]) { throw "Protocol fixed setting mismatch: $key" }
}
if ($env:KHC_STORAGE_TASK_ID -cne $fixed.task_id) { throw 'Wrong storage task.' }
foreach ($path in @($claimPath,$stopPath)) { $null=Plain $path }
if ((Test-Path -LiteralPath $stopPath) -or ($ValidateProtocolOnly -and (Test-Path -LiteralPath $claimPath))) { throw 'Campaign already claimed/stopped.' }
CheckPins
if ($ValidateProtocolOnly) { return }
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$work=Plain $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json -DateKind String
if ($record.max_bytes -ne 28MB -or $record.max_entries -ne 128) { throw 'Requires exact registered 28MiB/128 entries.' }
$claim=Get-Content -LiteralPath $claimPath -Raw | ConvertFrom-Json -DateKind String
$claimSha256=Sha $claimPath
$claimed=([DateTimeOffset]$claim.claimed_utc).UtcDateTime; $deadline=([DateTimeOffset]$claim.deadline_utc).UtcDateTime
if ($claim.schema -cne $fixed.schema -or $claim.run_id -cne $record.run_id -or $claim.record_path -cne (Plain $env:KHC_STORAGE_RUN_RECORD) -or
    $claim.record_sha256 -cne (Sha $env:KHC_STORAGE_RUN_RECORD) -or $claim.work_directory -cne $work -or $claim.protocol_path -cne $ProtocolPath -or
    $claim.protocol_sha256 -cne $ProtocolSha256 -or $claim.retries -ne 0 -or $claimed -gt [DateTime]::UtcNow -or
    $deadline -ne $claimed.AddSeconds(900) -or [DateTime]::UtcNow -ge $deadline) { throw 'Worker invocation/registration/deadline does not match the admission claim.' }
$commands=[Collections.Generic.List[object]]::new(); $samples=[Collections.Generic.List[object]]::new(); $cpu=[Collections.Generic.List[object]]::new()
$source=Join-Path $work 'source'; $runs=Join-Path $work 'samples'
$report=[ordered]@{schema=$fixed.schema;status='running';settings=$fixed;protocol_sha256=$ProtocolSha256;run_id=$record.run_id;cpu_samples=$cpu;commands=$commands;samples=$samples;source_timestamp=$fixed.source_timestamp_utc}
$activeSample=$null
function Deadline {
    if ([DateTime]::UtcNow -ge $deadline -or (Test-Path -LiteralPath $stopPath)) { throw 'Campaign deadline/stop gate closed; no retry.' }
}
function Quiet([string]$Phase) {
    Deadline
    $values=[Collections.Generic.List[double]]::new(); $cpu.Add([pscustomobject]@{phase=$Phase;values=$values;provider='fresh CIM Win32_PerfFormattedData_PerfOS_Processor _Total'})
    foreach ($n in 1..5) {
        Deadline; Start-Sleep -Seconds 1; Deadline
        $capture=@(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
        if ($capture.Count -ne 1 -or $null -eq $capture[0].PercentProcessorTime) { throw "Missing CPU sample: $Phase/$n" }
        $value=[double]$capture[0].PercentProcessorTime; $values.Add($value)
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 15) { throw "CPU gate failed: $Phase/$n=$value; no retry" }
        Deadline
    }
    Deadline
}
function Tool([string]$Exe,[string[]]$Arguments,[string]$Label,[switch]$Measure) {
    $process=$null; $job=$null; $timer=[Diagnostics.Stopwatch]::new(); $captures=@(); $toolFailure=$null
    $limit=if($Label -ceq 'version'){$fixed.version_capture_bytes_per_stream}else{$fixed.command_capture_bytes_per_stream}
    $result=[pscustomobject]@{label=$Label;executable=$Exe;arguments=$Arguments;measured=[bool]$Measure;status='in-progress';started=$false;wall_ms=0.0;peak_working_set_bytes=0L;peak_pagefile_bytes=0L;exit_code=$null;exit_code_missing=$true;stdout='';stderr='';stdout_missing=$true;stderr_missing=$true;capture_limit_bytes_per_stream=$limit;capture_truncated=@($false,$false);capture_eof=@($false,$false);cleanup_status='not-started';cleanup_errors=[Collections.Generic.List[string]]::new();error=$null}
    try {
        if ($Measure) { Quiet "before-$Label" }; Deadline
        $info=[Diagnostics.ProcessStartInfo]::new($Exe); $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WorkingDirectory=$source
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $info.Environment['TEMP']=$work; $info.Environment['TMP']=$work
        foreach ($arg in $Arguments) { $info.ArgumentList.Add($arg) }
        $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
        $job=[Khc.Storage.ProcessJob]::new()
        Deadline; $timer.Start(); if (-not $process.Start()) { throw "Start failed: $Label" }; $result.started=$true; $job.Assign($process)
        foreach ($pipe in @($process.StandardOutput.BaseStream,$process.StandardError.BaseStream)) {
            $buffer=[byte[]]::new(4096); $captures+=@{pipe=$pipe;buffer=$buffer;data=[IO.MemoryStream]::new();done=$false;truncated=$false;pending=$pipe.ReadAsync($buffer,0,$buffer.Length)}
        }
        while ($true) {
            Deadline
            $process.Refresh(); $result.peak_working_set_bytes=[Math]::Max($result.peak_working_set_bytes,$process.PeakWorkingSet64); $result.peak_pagefile_bytes=[Math]::Max($result.peak_pagefile_bytes,$process.PeakPagedMemorySize64)
            if ($result.peak_working_set_bytes -gt $fixed.child_memory_bytes -or $result.peak_pagefile_bytes -gt $fixed.child_memory_bytes -or $timer.Elapsed.TotalSeconds -ge $fixed.child_seconds) { throw "Child time/memory cap: $Label" }
            foreach ($capture in $captures) {
                if ($capture.done -or -not $capture.pending.IsCompleted) { continue }
                $count=$capture.pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $capture.done=$true; continue }
                if ($capture.data.Length+$count -gt $limit) {
                    $capture.truncated=$true; $remaining=[int]($limit-$capture.data.Length)
                    if($remaining -gt 0){$capture.data.Write($capture.buffer,0,$remaining)}
                    throw "Output cap: $Label ($limit bytes per stream)"
                }
                $capture.data.Write($capture.buffer,0,$count); $capture.pending=$capture.pipe.ReadAsync($capture.buffer,0,$capture.buffer.Length)
            }
            if ($process.HasExited -and @($captures | Where-Object {-not $_.done}).Count -eq 0 -and $job.Active -eq 0) { break }
            Start-Sleep -Milliseconds 1
        }
        $timer.Stop(); Deadline
        if ($process.ExitCode -ne 0 -or $result.peak_working_set_bytes -le 0 -or $result.peak_pagefile_bytes -le 0) { throw "Exit/missing OS memory: $Label" }
        if ([double]::IsNaN($timer.Elapsed.TotalMilliseconds) -or [double]::IsInfinity($timer.Elapsed.TotalMilliseconds) -or $timer.Elapsed.TotalMilliseconds -le 0) { throw 'Invalid wall time.' }
    } catch { $toolFailure=$_
    } finally {
        $timer.Stop(); $result.wall_ms=$timer.Elapsed.TotalMilliseconds
        try {
            if ($null -ne $job) { try{$job.StopAndWait($fixed.cleanup_timeout_milliseconds)}catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))} }
        } finally {
            try {
                if ($result.started -and $null -ne $process) {
                    try {
                        if (-not $process.HasExited) { $process.Kill($true); if(-not $process.WaitForExit($fixed.cleanup_timeout_milliseconds)){throw 'Process tree termination not confirmed.'} }
                        $result.exit_code=$process.ExitCode; $result.exit_code_missing=$false
                    }catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}
                }
            } finally {
                try {
                    for($side=0;$side -lt $captures.Count;$side++) {
                        $capture=$captures[$side]
                        try {
                            # 終了後に既に完了した一回分だけ回収し、待機/上限なしのdrainをしない。
                            if(-not $capture.done -and $capture.pending.IsCompleted){
                                try{
                                    $count=$capture.pending.GetAwaiter().GetResult()
                                    if($count -eq 0){$capture.done=$true}else{
                                        $remaining=[int]($limit-$capture.data.Length); $take=[Math]::Min($remaining,$count)
                                        if($take -gt 0){$capture.data.Write($capture.buffer,0,$take)}
                                        if($count -gt $remaining){$capture.truncated=$true}
                                    }
                                }catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}
                            }
                            $field=if($side -eq 0){'stdout'}else{'stderr'}
                            $result.$field=[Text.Encoding]::UTF8.GetString($capture.data.ToArray()); $result."${field}_missing"=$false
                            $result.capture_truncated[$side]=$capture.truncated -or -not $capture.done; $result.capture_eof[$side]=$capture.done
                        }catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}
                        finally{try{$capture.data.Dispose()}catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}}
                    }
                }finally{
                    try{if($null -ne $process){try{$process.Dispose()}catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}}}
                    finally{if($null -ne $job){try{$job.Dispose()}catch{$result.cleanup_errors.Add((Tail $_.Exception.Message $fixed.cleanup_error_max_characters))}}}
                }
            }
        }
        $result.cleanup_status=if($result.cleanup_errors.Count){'failed'}else{'completed'}
        if($null -ne $toolFailure){$result.error=Tail $toolFailure.Exception.Message $fixed.error_max_characters}
        if($result.cleanup_errors.Count -and $null -eq $toolFailure){$toolFailure=[InvalidOperationException]::new('Child cleanup failed.');$result.error=$toolFailure.Message}
        $result.status=if($null -ne $toolFailure){'failed'}else{'passed'}
        $commands.Add($result)
        if($Measure -and $null -ne $activeSample){$direction=if($Label.EndsWith('-encode')){'encode'}else{'extract'};$activeSample.$direction=$result}
    }
    if($null -ne $toolFailure){throw $toolFailure}
    return $result
}
function Restored([string]$Directory) {
    $files=@(Get-ChildItem -LiteralPath $Directory -Force -Recurse)
    if ($files.Count -ne 1 -or $files[0].PSIsContainer -or $files[0].Name -cne 'ptt5' -or $files[0].DirectoryName -cne $Directory -or $files[0].Length -ne 513216 -or (Sha $files[0].FullName) -cne $fixed.input_sha256) { throw "Full restoration mismatch: $Directory" }
    if (-not (SameBytes ([IO.File]::ReadAllBytes($files[0].FullName)) ([IO.File]::ReadAllBytes((Join-Path $source 'ptt5'))))) { throw 'Restored bytes mismatch.' }
}
function Median([double[]]$Values) { if ($Values.Count -ne 5) { throw 'Five values required.' }; return [double](@($Values | Sort-Object)[2]) }
function Summary([string]$Strategy) {
    $group=@($samples | Where-Object strategy -CEQ $Strategy)
    if ($group.Count -ne 5 -or @($group.archive_sha256 | Select-Object -Unique).Count -ne 1 -or @($group.archive_bytes | Select-Object -Unique).Count -ne 1) { throw "Incomplete/nondeterministic strategy: $Strategy" }
    $s=[ordered]@{strategy=$Strategy;archive_bytes=$group[0].archive_bytes;encode_median_ms=(Median @($group | ForEach-Object {$_.encode.wall_ms}));extract_median_ms=(Median @($group | ForEach-Object {$_.extract.wall_ms}));combined_median_ms=(Median @($group | ForEach-Object {$_.encode.wall_ms+$_.extract.wall_ms}))}
    foreach ($counter in @('working_set','pagefile')) {
        $field="peak_${counter}_bytes"
        foreach ($direction in @('encode','extract')) { $s["${direction}_$field"]=[long](($group | ForEach-Object {$_.$direction.$field} | Measure-Object -Maximum).Maximum) }
        $s[$field]=[Math]::Max($s["encode_$field"],$s["extract_$field"])
    }
    $s.max_memory_bytes=[Math]::Max($s.peak_working_set_bytes,$s.peak_pagefile_bytes)
    return [pscustomobject]$s
}
$failure=$null
try {
    # 開始CPU gateの失敗も空の登録済みworkへ記録する。payloadはgate後だけ作る。
    $null=New-Item -ItemType Directory -Path $work
    Quiet 'start'
    $null=New-Item -ItemType Directory -Path $source,$runs
    $zip=[IO.Compression.ZipFile]::OpenRead($protocol.pins.input_zip.path)
    try {
        $members=@($zip.Entries | Where-Object FullName -CEQ 'input/ptt5')
        if ($members.Count -ne 1 -or $members[0].Length -ne 513216) { throw 'Pinned ZIP member mismatch.' }
        $inputStream=$members[0].Open(); $output=[IO.File]::Open((Join-Path $source 'ptt5'),[IO.FileMode]::CreateNew)
        try { $inputStream.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $inputStream.Dispose() }
    } finally { $zip.Dispose() }
    $inputPath=Join-Path $source 'ptt5'; if ((Sha $inputPath) -cne $fixed.input_sha256) { throw 'Input SHA mismatch.' }
    [IO.File]::SetLastWriteTimeUtc($inputPath,[DateTime]::Parse($fixed.source_timestamp_utc).ToUniversalTime())
    $seven=$protocol.pins.seven_zip.path
    $version=Tool $seven @('i','-sccUTF-8') 'version'
    if ($version.stdout -notmatch '7-Zip[^\r\n]*26\.04') { throw 'Requires 7-Zip 26.04.' }
    $strategies=$fixed.strategies.Split(',')
    foreach ($round in 1..5) {
        Quiet "round-$round"
        for ($position=0;$position -lt 7;$position++) {
            $strategy=$strategies[($position+$round-1)%7]; $label="$strategy-$round"
            $isSeven=$strategy.StartsWith('7zip-'); $archive=Join-Path $runs "$label.$(if($isSeven){'7z'}else{'khc'})"; $extract=Join-Path $runs "$label-out"
            $activeSample=[pscustomobject]@{strategy=$strategy;round=$round;order_position=$position+1;status='in-progress';failure=$null;archive=$archive;archive_bytes=$null;archive_sha256=$null;format=$null;encode=$null;extract=$null;full_byte_sha_restoration=$false;native_integrity=$false}
            $samples.Add($activeSample)
            if ($isSeven) {
                $encode=Tool $seven @('a','-t7z',"-mx=$($strategy.Substring(7))",'-m0=lzma2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off','-spd','-sccUTF-8',$archive,'--','.\ptt5') "$label-encode" -Measure
                $listing=Tool $seven @('l','-slt','-sccUTF-8',$archive) "$label-list"
                $methods=@([regex]::Matches($listing.stdout,'(?m)^Method = (.+)\r?$') | ForEach-Object {$_.Groups[1].Value.Trim()})
                $dictionaries=@([regex]::Matches(($methods -join "`n"),'LZMA2:(\d+)([bkm]?)') | ForEach-Object {
                    $n=[long]$_.Groups[1].Value; $effective=switch ($_.Groups[2].Value) {'b' {$n} 'k' {$n*1KB} 'm' {$n*1MB} default {if($n -gt 30){throw 'Invalid dictionary exponent'};[long][Math]::Pow(2,$n)}}
                    [pscustomobject]@{token=$_.Value;bytes=$effective}
                })
                if ($methods.Count -eq 0 -or $dictionaries.Count -eq 0) { throw 'Missing actual LZMA2 method/dictionary.' }
                $format=[pscustomobject]@{methods=$methods;effective_dictionaries=$dictionaries;requested_dictionary_bytes=64MB}
                $null=Tool $seven @('t','-sccUTF-8',$archive) "$label-test"
                $null=New-Item -ItemType Directory -Path $extract
                $decode=Tool $seven @('x','-sccUTF-8',$archive,"-o$extract",'-y') "$label-extract" -Measure
            } else {
                $exe=$protocol.pins.$strategy.path
                $encode=Tool $exe @('khc-create',$archive,'--source',$source,'--strategy','spatial-bits-trial') "$label-encode" -Measure
                $listing=Tool $exe @('khc-list',$archive,'--json') "$label-list"
                $metadata=@(ConvertFrom-Json -InputObject $listing.stdout -DateKind String)
                if ($metadata.Count -ne 1 -or $metadata[0].name -cne 'ptt5' -or $metadata[0].is_directory -or $metadata[0].original_size -ne 513216) { throw 'KHC metadata mismatch.' }
                $bytes=[IO.File]::ReadAllBytes($archive); $at=32+[long][BitConverter]::ToUInt32($bytes,20)
                if ($bytes.Length -lt 48 -or [Text.Encoding]::ASCII.GetString($bytes,0,8) -cne "KHC1ARC`0" -or $bytes[8] -ne 7 -or $at+12 -gt $bytes.Length) { throw 'KHC revision/header mismatch.' }
                $length=[long][BitConverter]::ToUInt32($bytes,[int]$at); $at+=4
                if ($length -lt 8 -or $at+$length+12 -ne $bytes.Length -or [Text.Encoding]::ASCII.GetString($bytes,[int]$at,8) -cne "KCS1BLK`0" -or [Text.Encoding]::ASCII.GetString($bytes,[int]($at+$length+4),8) -cne "KHC1END`0") { throw 'Requires exactly one actual KCS1 frame.' }
                $format=[pscustomobject]@{revision=7;frame_count=1;magic='KCS1BLK';frame_bytes=$length}
                $null=Tool $exe @('khc-test',$archive) "$label-test"
                $null=New-Item -ItemType Directory -Path $extract
                $decode=Tool $exe @('khc-extract',$archive,'--output',$extract) "$label-extract" -Measure
            }
            Restored $extract; Deadline
            $activeSample.archive_bytes=(Get-Item -LiteralPath $archive).Length; $activeSample.archive_sha256=Sha $archive
            $activeSample.format=$format; $activeSample.encode=$encode; $activeSample.extract=$decode
            $activeSample.full_byte_sha_restoration=$true; $activeSample.native_integrity=$true; $activeSample.status='passed'
        }
        Write-Output (([ordered]@{phase='round-complete';round=$round;sample_count=$samples.Count}) | ConvertTo-Json -Compress)
    }
    $summaries=@($strategies | ForEach-Object {Summary $_}); $old=$summaries[0]; $candidate=$summaries[1]; $profiles=@($summaries[2..6])
    $allKhc=@($samples | Where-Object {$_.strategy -cin @('baseline','replay')})
    if ($candidate.archive_bytes -gt $old.archive_bytes -or @($allKhc.archive_sha256 | Select-Object -Unique).Count -ne 1) { throw 'Old/new archive equality/size gate failed.' }
    $first=[IO.File]::ReadAllBytes($allKhc[0].archive)
    foreach ($sample in $allKhc) { if (-not (SameBytes $first ([IO.File]::ReadAllBytes($sample.archive)))) { throw 'Old/new archive bytes differ.' } }
    $report.summaries=$summaries; $report.determinism_verified=$true; $report.old_new_archive_bytes_equal=$true
    # 最後のhash/timegateが通る前は判定をreportへ追加しない。
    CheckPins
    if((Sha $claimPath) -cne $claimSha256 -or (Sha $env:KHC_STORAGE_RUN_RECORD) -cne $claim.record_sha256){throw 'Final claim/registration changed.'}
    if ((Sha $inputPath) -cne $fixed.input_sha256 -or [IO.File]::GetLastWriteTimeUtc($inputPath) -ne [DateTime]::Parse($fixed.source_timestamp_utc).ToUniversalTime()) { throw 'Final source changed.' }
    foreach ($sample in $samples) { if ((Sha $sample.archive) -cne $sample.archive_sha256) { throw 'Final archive changed.' }; Restored (Join-Path $runs "$($sample.strategy)-$($sample.round)-out") }
    Quiet 'final'; Deadline
    $eligible=@($profiles | Where-Object {$_.archive_bytes -ge $candidate.archive_bytes} | Sort-Object combined_median_ms,strategy)
    $baseline=if($eligible.Count){$eligible[0]}else{$null}; $metrics=@('encode_peak_working_set_bytes','extract_peak_working_set_bytes','encode_peak_pagefile_bytes','extract_peak_pagefile_bytes','peak_working_set_bytes','peak_pagefile_bytes')
    $memoryPass=$null -ne $baseline
    if ($null -ne $baseline) { foreach ($metric in $metrics) { if ($candidate.$metric -gt $baseline.$metric) { $memoryPass=$false } } }
    $dominators=@($profiles | Where-Object {
        $p=$_; $all=$p.archive_bytes -le $candidate.archive_bytes -and $p.encode_median_ms -le $candidate.encode_median_ms -and $p.extract_median_ms -le $candidate.extract_median_ms
        $strict=$p.archive_bytes -lt $candidate.archive_bytes -or $p.encode_median_ms -lt $candidate.encode_median_ms -or $p.extract_median_ms -lt $candidate.extract_median_ms
        foreach ($metric in $metrics) { $all=$all -and $p.$metric -le $candidate.$metric; $strict=$strict -or $p.$metric -lt $candidate.$metric }; $all -and $strict
    })
    $tradeoff=$candidate.encode_median_ms -le 0.95*$old.encode_median_ms -and $candidate.extract_median_ms -le 1.05*$old.extract_median_ms
    $tradeoff=$tradeoff -and $candidate.max_memory_bytes -le $old.max_memory_bytes+16MB
    $report.source_cost_tradeoff=[pscustomobject]@{passed=$tradeoff;baseline=$old;candidate=$candidate;interpretation='source-cost ablation only; distinct from 7zip frontier'}
    $report.frontier_decision=[pscustomobject]@{passed=($null -ne $baseline -and $candidate.encode_median_ms -le 0.95*$baseline.encode_median_ms -and $candidate.extract_median_ms -le 0.95*$baseline.extract_median_ms -and $memoryPass -and $dominators.Count -eq 0);selected_7zip_baseline=$baseline;all_five_profiles=$profiles;dominating_profiles=$dominators;memory_pass=$memoryPass}
    Deadline; $report.status='passed'
} catch {
    $failure=$_; $report.status='failed'; $report.failure=Tail $_.Exception.Message $fixed.error_max_characters
    if($null -ne $activeSample -and $activeSample.status -ceq 'in-progress'){$activeSample.status='failed';$activeSample.failure=$report.failure}
    $report.Remove('frontier_decision'); $report.Remove('source_cost_tradeoff')
} finally {
    # JSON escape後のUTF-8実byte数で制限し、同じcommandへのsample参照も一緒に縮小する。
    $report.logs_trimmed_for_budget=$false
    $json=$report | ConvertTo-Json -Depth 24 -Compress
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt $fixed.report_max_utf8_bytes){
        $report.logs_trimmed_for_budget=$true
        foreach($command in $commands){
            foreach($field in @('stdout','stderr')){
                $prior=$command.$field; $command.$field=Tail $prior $fixed.report_tail_characters
                if($prior.Length -ne $command.$field.Length){$side=if($field -ceq 'stdout'){0}else{1};$command.capture_truncated[$side]=$true}
            }
        }
        $json=$report | ConvertTo-Json -Depth 24 -Compress
    }
    $reportBytes=[Text.Encoding]::UTF8.GetByteCount($json)
    if($reportBytes -gt $fixed.report_max_utf8_bytes){throw 'Bounded report still exceeds 2MiB; report was not written.'}
    $workBytes=0L; $workEntries=0
    foreach($item in Get-ChildItem -LiteralPath $work -Recurse -Force){$null=Plain $item.FullName;$workEntries++;if(-not $item.PSIsContainer){$workBytes+=$item.Length}}
    if($workBytes+$reportBytes -gt 28MB -or $workEntries+1 -gt 128){throw 'Report would exceed actual 28MiB/128-entry work budget; report was not written.'}
    NewText (Join-Path $work 'spatial-replay-frontier.json') $json
}
if ($null -ne $failure) { throw $failure }
