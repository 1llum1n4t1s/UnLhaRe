#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Direct')]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory,ParameterSetName='Direct')][ValidateCount(1,16)][string[]]$InputFiles,
    [Parameter(Mandatory,ParameterSetName='Recovery')][string]$InputRecoveryZip,
    [Parameter(Mandatory,ParameterSetName='Recovery')][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$InputRecoveryZipSha256,
    [Parameter(Mandatory,ParameterSetName='Recovery')][ValidateCount(1,16)][string[]]$InputRecoveryMembers,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [switch]$IncludeRecordAdaptiveCandidate,
    [switch]$SpeedFrontierStudy,
    [ValidateSet('Historical','SingleSeal20261020')][string]$SourceCondition = 'Historical',
    [ValidateSet(1,3,5,7,9)][int[]]$SevenZipLevels = @(9),
    [ValidateRange(1,1800)][int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop
$singleSeal=($SourceCondition -ieq 'SingleSeal20261020')
if ($singleSeal) { $SourceCondition='SingleSeal20261020' }
$singleSealCampaign=$null
if ($singleSeal -and -not $SpeedFrontierStudy) { throw 'SingleSeal requires SpeedFrontierStudy.' }
if ($SpeedFrontierStudy) {
    if ($IncludeRecordAdaptiveCandidate -or $PSCmdlet.ParameterSetName -ne 'Recovery' -or
        (@($SevenZipLevels) -join ',' -cne '1,3,5,7,9') -or $TimeoutSeconds -ne 900) {
        throw 'The fixed speed-frontier study requires the pinned recovery input, levels 1/3/5/7/9, no KRS3 candidate, and a 900-second timeout.'
    }
    if ($InputRecoveryZipSha256.ToLowerInvariant() -cne '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75' -or
        @($InputRecoveryMembers).Count -ne 1 -or $InputRecoveryMembers[0] -cne 'input/ptt5') {
        throw 'The speed-frontier study is pinned to the development recovery ZIP and input/ptt5 member.'
    }
} elseif ((@($SevenZipLevels) -join ',' -cne '9')) {
    throw 'Use the fixed speed-frontier study mode for any level set other than the legacy mx=9 comparison.'
}

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and
            (((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            throw "Reparse point is not permitted: $part"
        }
    }
    return $full
}
function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Write-NewText([string]$Path, [string]$Text) {
    $null = Assert-PlainPath $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}
function New-OutputDirectory([string]$Path) {
    $null = Assert-PlainPath $Path
    if (Test-Path -LiteralPath $Path) { throw "Output already exists: $Path" }
    $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop
}
function Get-Median([double[]]$Values) {
    if ($Values.Count -eq 0) { throw 'Cannot calculate a median from an empty sample.' }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}
function Get-StrategySummary([string]$Strategy, [int]$ExpectedCount) {
    $group = @($samples | Where-Object { $_.strategy -ceq $Strategy })
    if ($group.Count -ne $ExpectedCount) { throw "Expected $ExpectedCount samples for $Strategy, found $($group.Count)." }
    $encode = @($group | ForEach-Object { [double]$_.encode.wall_ms })
    $extract = @($group | ForEach-Object { [double]$_.extract.wall_ms })
    $combined = @($group | ForEach-Object { [double]$_.encode.wall_ms + [double]$_.extract.wall_ms })
    $working = @($group | ForEach-Object { [long]$_.encode.peak_working_set_bytes; [long]$_.extract.peak_working_set_bytes })
    $paged = @($group | ForEach-Object { [long]$_.encode.peak_pagefile_bytes; [long]$_.extract.peak_pagefile_bytes })
    $summary=[pscustomobject]@{
        strategy=$Strategy; archive_bytes=[long]$group[0].archive_bytes
        encode_median_ms=(Get-Median -Values $encode); extract_median_ms=(Get-Median -Values $extract)
        combined_median_ms=(Get-Median -Values $combined)
        peak_working_set_bytes=[long](($working | Measure-Object -Maximum).Maximum)
        peak_pagefile_bytes=[long](($paged | Measure-Object -Maximum).Maximum)
    }
    if ($singleSeal) {
        foreach ($direction in @('encode','extract')) {
            foreach ($counter in @('working_set','pagefile')) {
                $field="peak_${counter}_bytes"
                $peak=[long](($group | ForEach-Object { $_.$direction.$field } | Measure-Object -Maximum).Maximum)
                $summary | Add-Member -NotePropertyName "${direction}_$field" -NotePropertyValue $peak
            }
        }
    }
    return $summary
}
function Assert-QuietCpu([string]$Phase) {
    if ($singleSeal) {
        $values=[Collections.Generic.List[double]]::new()
        $sample=[pscustomobject]@{phase=$Phase; percent=$values; provider='fresh Win32_PerfFormattedData_PerfOS_Processor _Total per sample'}
        $cpuSamples.Add($sample)
        foreach ($index in 1..5) {
            Assert-SingleSealWindow
            Start-Sleep -Seconds 1
            Assert-SingleSealWindow
            $capture=@(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
            if ($capture.Count -ne 1 -or $null -eq $capture[0].PercentProcessorTime) { throw "Missing fresh CIM CPU sample at $Phase/$index; no retry." }
            $value=[double]$capture[0].PercentProcessorTime
            $values.Add($value)
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 15) { throw "SingleSeal CPU quiet-gate failed at $Phase/$index; no retry. value=$value" }
        }
        return
    }
    $capture = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5
    $values = @($capture.CounterSamples | ForEach-Object { [Math]::Round($_.CookedValue,1) })
    if ($values.Count -ne 5) { throw "CPU quiet-gate sample count mismatch at $Phase." }
    $null = $cpuSamples.Add([pscustomobject]@{phase=$Phase; percent=$values})
    if (@($values | Where-Object { $_ -gt 15 }).Count -ne 0) {
        throw "CPU quiet-gate failed at $Phase; no same-condition retry is allowed. samples=$($values -join ',')"
    }
}
function Assert-SingleSealWindow {
    if ($singleSeal -and ([DateTime]::UtcNow -lt ([DateTimeOffset]$singleSealCampaign.Marker.start_utc).UtcDateTime -or
        [DateTime]::UtcNow -ge ([DateTimeOffset]$singleSealCampaign.Marker.end_utc).UtcDateTime -or
        [DateTime]::UtcNow -ge $singleSealWorkerDeadline)) { throw 'SingleSeal fixed campaign/worker deadline is closed.' }
}

# 各コマンドの出力も上限付きで保持し、短命なプロセスで採れないメモリ値は成功扱いにしない。
function Invoke-ScreenTool([string]$Executable, [string[]]$Arguments, [string]$Label, [switch]$Measure) {
    if ($singleSeal -and $Measure) { Assert-QuietCpu "before-command-$Label" }
    Assert-SingleSealWindow
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory = $source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $peaks = [long[]]::new(2)
    $captures = @()
    try {
        Assert-SingleSealWindow
        if (-not $process.Start()) { throw "Unable to start: $Label" }
        $started = $true
        foreach ($pipe in @($process.StandardOutput.BaseStream, $process.StandardError.BaseStream)) {
            $buffer = [byte[]]::new(4096)
            $captures += @{ pipe=$pipe; buffer=$buffer; data=[IO.MemoryStream]::new(); done=$false; pending=$pipe.ReadAsync($buffer,0,$buffer.Length) }
        }
        while ($true) {
            Assert-SingleSealWindow
            try {
                $process.Refresh()
                $peaks[0] = [Math]::Max($peaks[0], $process.PeakWorkingSet64)
                $peaks[1] = [Math]::Max($peaks[1], $process.PeakPagedMemorySize64)
            } catch { } # 終了直後に取得できない場合も、それまでの実測値だけを使う。
            if ($singleSeal -and ($peaks[0] -gt 160MB -or $peaks[1] -gt 160MB)) { throw "SingleSeal child exceeded 160 MiB working-set/pagefile: $Label" }
            foreach ($capture in $captures) {
                if ($capture.done -or -not $capture.pending.IsCompleted) { continue }
                $count = $capture.pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $capture.done=$true; continue }
                if ($capture.data.Length + $count -gt 64KB) { throw "Output exceeded 64 KiB: $Label" }
                $capture.data.Write($capture.buffer,0,$count)
                $capture.pending=$capture.pipe.ReadAsync($capture.buffer,0,$capture.buffer.Length)
            }
            if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Timeout: $Label" }
            if ($singleSeal -and $timer.Elapsed.TotalSeconds -ge 60) { throw "SingleSeal child exceeded 60 seconds: $Label" }
            if ($process.HasExited -and @($captures | Where-Object { -not $_.done }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 1
        }
        $timer.Stop()
        $stdout = [Text.Encoding]::UTF8.GetString($captures[0].data.ToArray())
        $stderr = [Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())
        $result = [pscustomobject]@{
            label=$Label; executable=$Executable; arguments=$Arguments; exit_code=$process.ExitCode
            wall_ms=$timer.Elapsed.TotalMilliseconds; cpu_ms=$process.TotalProcessorTime.TotalMilliseconds
            peak_working_set_bytes=$peaks[0]; peak_pagefile_bytes=$peaks[1]
            measured=[bool]$Measure; stdout=$stdout; stderr=$stderr
        }
        $commands.Add($result)
        if ($process.ExitCode -ne 0) { throw "Nonzero exit ($($process.ExitCode)): $Label" }
        if ($Measure -and ($peaks[0] -le 0 -or $peaks[1] -le 0)) { throw "Zero OS memory counter: $Label" }
        return $result
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill($true)
            if (-not $process.WaitForExit(5000)) { throw "Process tree did not stop: $Label" }
        }
        foreach ($capture in $captures) { $capture.data.Dispose() }
        $timer.Stop()
        $process.Dispose()
    }
}
function Assert-Restored([string]$Directory) {
    $items = @(Get-ChildItem -LiteralPath $Directory -Force -Recurse)
    if ($items.Count -ne $entries.Count) { throw "Restored entry count mismatch: $Directory" }
    $verified = @()
    foreach ($item in $items) {
        $null = Assert-PlainPath $item.FullName
        $expected = @($entries | Where-Object { $_.name -ceq $item.Name })
        if ($item.PSIsContainer -or $item.DirectoryName -cne $Directory -or $expected.Count -ne 1) {
            throw "Unexpected restored path: $($item.FullName)"
        }
        $hash = Get-Sha256 $item.FullName
        if ($item.Length -ne $expected[0].bytes -or $hash -cne $expected[0].sha256) { throw "Restored SHA-256/size mismatch: $($item.Name)" }
        $verified += [pscustomobject]@{name=$item.Name; bytes=$item.Length; sha256=$hash}
    }
    return $verified
}

# 文字列検索でpayload中の偶然のmagicを拾わず、形式の境界だけを読む。
function Get-KhcFrameInfo([string]$Archive, [object[]]$Metadata) {
    $bytes = [IO.File]::ReadAllBytes($Archive)
    if ($bytes.Length -lt 40 -or [Text.Encoding]::ASCII.GetString($bytes,0,8) -cne "KHC1ARC`0") { throw 'Invalid KHC header.' }
    $revision = [int]$bytes[8]
    $at = 32 + [long][BitConverter]::ToUInt32($bytes,20)
    $frames = @()
    foreach ($entry in $Metadata) {
        if ($entry.is_directory) { throw 'Unexpected KHC directory entry.' }
        $remaining = [long]$entry.original_size
        while ($remaining -gt 0) {
            if ($at + 4 -gt $bytes.LongLength) { throw 'Truncated KHC frame prefix.' }
            $length = [long][BitConverter]::ToUInt32($bytes,[int]$at)
            $at += 4
            if ($length -lt 8 -or $at + $length -gt $bytes.LongLength) { throw 'Invalid KHC frame extent.' }
            $magic = [Text.Encoding]::ASCII.GetString($bytes,[int]$at,8)
            $frames += [pscustomobject]@{
                entry=$entry.name; offset=$at; bytes=$length; magic=$magic
                krs2=($magic -ceq "KRS2BLK`0"); krs3=($magic -ceq "KRS3BLK`0")
            }
            $at += $length
            $remaining -= [Math]::Min($remaining,1MB)
        }
        $at += 4 # ファイルCRC。
    }
    if ($at + 8 -ne $bytes.LongLength -or [Text.Encoding]::ASCII.GetString($bytes,[int]$at,8) -cne "KHC1END`0") { throw 'KHC trailer/extent mismatch.' }
    return [pscustomobject]@{
        archive_revision=$revision
        krs2_selected=(@($frames | Where-Object krs2).Count -gt 0)
        krs2_frames=@($frames | Where-Object krs2).Count
        krs3_selected=(@($frames | Where-Object krs3).Count -gt 0)
        krs3_frames=@($frames | Where-Object krs3).Count
        frames=$frames
    }
}

$work = Assert-PlainPath $WorkDirectory
Assert-KhcStorageContext -WorkDirectory $work
if ($singleSeal) {
    $registration=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw -Encoding UTF8 | ConvertFrom-Json
    $singleSealCampaign=Assert-KhcSingleSealSpeedFrontierCampaign -RunId $registration.run_id -RequireOpenWindow
    if ($singleSealCampaign.Claim.record_path -cne [IO.Path]::GetFullPath($env:KHC_STORAGE_RUN_RECORD) -or
        $singleSealCampaign.Claim.work_directory -cne $work -or
        $KhcExecutable -cne $singleSealCampaign.Marker.khc_executable -or
        $SevenZipPath -cne $singleSealCampaign.Marker.seven_zip_executable -or
        $InputRecoveryZip -cne $singleSealCampaign.Marker.input_recovery_zip) { throw 'SingleSeal worker invocation does not match its claim/marker.' }
    $singleSealWorkerDeadline=[DateTime]::UtcNow.AddSeconds(900)
}
$reportPath = Join-Path $work 'record-fast-7zip-screen.json'
if (Test-Path -LiteralPath $reportPath) { throw "Report already exists: $reportPath" }
$source = Join-Path $work 'record-fast-source'
$runs = Join-Path $work 'record-fast-runs'
$commands = [Collections.Generic.List[object]]::new()
$samples = [Collections.Generic.List[object]]::new()
$cpuSamples = [Collections.Generic.List[object]]::new()
$entries = @()
$inputPlans = [Collections.Generic.List[object]]::new()
$recoveryArchive = $null
$report = [ordered]@{
    schema=if($SpeedFrontierStudy){'khc-record-fast-speed-frontier-screen-v1'}elseif($IncludeRecordAdaptiveCandidate){'khc-record-adaptive-7zip-screen-v1'}else{'khc-record-fast-7zip-screen-v1'}
    status='running'; experimental=$true
    scope='candidate screen only; no general performance superiority claim'; utc=[DateTime]::UtcNow.ToString('o')
    rounds=if($SpeedFrontierStudy){5}else{3}; input_cap_bytes=1MB; timeout_seconds=$TimeoutSeconds
    memory='OS process peaks: PeakWorkingSet64 and PeakPagedMemorySize64; encode/extract must both be nonzero'
    speed_frontier_study=[bool]$SpeedFrontierStudy; seven_zip_levels=@($SevenZipLevels)
    source_condition=$SourceCondition
    single_seal_campaign=if($singleSeal){$singleSealCampaign}else{$null}
    interpretation_limits=if($singleSeal){'Development only; one known input; no holdout/general superiority/final-goal completion; five rotated rounds do not fully balance seven positions; no warmup.'}else{$null}
    child_timeout_seconds=if($singleSeal){60}else{$TimeoutSeconds}
    child_memory_cap_bytes=if($singleSeal){160MB}else{$null}
    cpu_threshold_percent=if($SpeedFrontierStudy){15}else{$null}; cpu_samples=$cpuSamples
    measurements_started=$false
    script_sha256=(Get-Sha256 $PSCommandPath); entries=@(); tools=@(); samples=$samples; commands=$commands
    determinism_verified=$false
}
$failure = $null
if ($singleSeal) {
    $report.frontier_decision=[pscustomobject]@{source_condition=$SourceCondition;screen_result='incomplete';rule='All five complete rounds and all preregistered gates are required; status=passed alone does not mean screen pass.'}
}
try {
    $khc = Assert-PlainPath $KhcExecutable
    $seven = Assert-PlainPath $SevenZipPath
    $report.tools = @($khc,$seven | ForEach-Object {
        $item=Get-Item -LiteralPath $_ -ErrorAction Stop
        if ($item.PSIsContainer) { throw "Executable is a directory: $_" }
        [pscustomobject]@{path=$item.FullName; bytes=$item.Length; sha256=(Get-Sha256 $_); file_version=$item.VersionInfo.FileVersion; product_version=$item.VersionInfo.ProductVersion}
    })
    if ($report.tools[1].file_version -notmatch '^26\.0?4(?:\D|$)') { throw '7-Zip file version must be 26.04.' }
    if ($SpeedFrontierStudy -and -not $singleSeal -and
        ($report.tools[0].sha256 -cne '81bb1f3d0e0aa592317be13e0cc6c4224f19579e51a1382077ace884bb87c732' -or
         $report.tools[1].sha256 -cne '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53')) {
        throw 'The speed-frontier study requires the pre-registered KHC Release CLI and 7-Zip 26.04 binaries.'
    }
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$total = 0
    if ($PSCmdlet.ParameterSetName -eq 'Direct') {
        foreach ($inputFile in $InputFiles) {
            $path=Assert-PlainPath $inputFile
            $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer -or -not $names.Add($item.Name)) { throw "Input must be a file with a unique basename: $path" }
            $total += $item.Length
            if ($total -gt 1MB) { throw 'Total input exceeds 1 MiB.' }
            $inputPlans.Add([pscustomobject]@{name=$item.Name; source=$path; bytes=[long]$item.Length; expected_sha256=(Get-Sha256 $path); archive_entry=$null})
        }
    } else {
        $recoveryPath=Assert-PlainPath $InputRecoveryZip
        $recoveryItem=Get-Item -LiteralPath $recoveryPath -Force -ErrorAction Stop
        if ($recoveryItem.PSIsContainer) { throw 'Input recovery ZIP is a directory.' }
        $recoveryHash=Get-Sha256 $recoveryPath
        if ($recoveryHash -cne $InputRecoveryZipSha256.ToLowerInvariant()) { throw 'Input recovery ZIP SHA-256 mismatch.' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $recoveryArchive=[IO.Compression.ZipFile]::OpenRead($recoveryPath)
        $report.input_recovery_archive=[pscustomobject]@{
            path=$recoveryPath; bytes=$recoveryItem.Length; sha256=$recoveryHash; members=@($InputRecoveryMembers)
        }
        foreach ($member in $InputRecoveryMembers) {
            $parts=$member.Split('/')
            if ([string]::IsNullOrWhiteSpace($member) -or $member.Contains('\') -or $member.StartsWith('/') -or
                $parts.Count -lt 2 -or @($parts | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
                throw "Invalid recovery ZIP member path: $member"
            }
            $matches=@($recoveryArchive.Entries | Where-Object { $_.FullName -ceq $member })
            if ($matches.Count -ne 1 -or $member.EndsWith('/')) { throw "Recovery ZIP member must exist exactly once as a file: $member" }
            $archiveEntry=$matches[0]
            $name=[IO.Path]::GetFileName($member)
            if ([string]::IsNullOrEmpty($name) -or -not $names.Add($name)) { throw "Recovery ZIP members need unique file basenames: $member" }
            $total += [long]$archiveEntry.Length
            if ($total -gt 1MB) { throw 'Total input exceeds 1 MiB.' }
            $inputPlans.Add([pscustomobject]@{name=$name; source="$recoveryPath!/$member"; bytes=[long]$archiveEntry.Length; expected_sha256=$null; archive_entry=$archiveEntry})
        }
    }
    if ($IncludeRecordAdaptiveCandidate) {
        if ($inputPlans.Count -ne 1 -or $inputPlans[0].name -cne 'ptt5' -or $inputPlans[0].bytes -ne 513216) {
            throw 'The RecordAdaptiveTrial product screen is pinned to the single development input ptt5 (513,216 bytes).'
        }
        if ($PSCmdlet.ParameterSetName -eq 'Recovery') {
            if ($InputRecoveryZipSha256.ToLowerInvariant() -cne '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75' -or
                $InputRecoveryMembers.Count -ne 1 -or $InputRecoveryMembers[0] -cne 'input/ptt5') {
                throw 'The RecordAdaptiveTrial recovery input must be the pinned development recovery ZIP and input/ptt5 member.'
            }
        } elseif ($inputPlans[0].expected_sha256 -cne '0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650') {
            throw 'The RecordAdaptiveTrial direct input must match the pinned development ptt5 SHA-256.'
        }
        $report.input_is_holdout=$false
        $report.cpu_threshold_percent=15
        $report.measurements_started=$false
    }
    if ($SpeedFrontierStudy) {
        if ($inputPlans.Count -ne 1 -or $inputPlans[0].name -cne 'ptt5' -or $inputPlans[0].bytes -ne 513216) {
            throw 'The speed-frontier study is pinned to the single development input ptt5 (513,216 bytes).'
        }
        $inputPlans[0].expected_sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
        $report.input_is_holdout=$false
    }
    if ($IncludeRecordAdaptiveCandidate) {
        $cpu=[Collections.Generic.List[double]]::new()
        $cpuCapture=Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 5
        foreach($sample in $cpuCapture.CounterSamples){$cpu.Add([math]::Round($sample.CookedValue,1))}
        if($cpu.Count -ne 5){throw 'CPU quiet-gate sample count mismatch.'}
        $report.cpu_samples_percent=@($cpu)
        if(@($cpu | Where-Object {$_ -gt 15}).Count -ne 0){
            $report.status='skipped-cpu-gate'
            return
        }
    }
    New-OutputDirectory $source
    New-OutputDirectory $runs
    foreach ($plan in @($inputPlans | Sort-Object -Property name -CaseSensitive)) {
        $destination=Join-Path $source $plan.name
        if ($null -eq $plan.archive_entry) {
            [IO.File]::Copy($plan.source,$destination,$false)
        } else {
            $entryStream=$plan.archive_entry.Open()
            $outputStream=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try { $entryStream.CopyTo($outputStream); $outputStream.Flush($true) }
            finally { $outputStream.Dispose(); $entryStream.Dispose() }
        }
        $copied=Get-Item -LiteralPath $destination -Force
        $copiedHash=Get-Sha256 $destination
        if ($copied.Length -ne $plan.bytes -or ($null -ne $plan.expected_sha256 -and $copiedHash -cne $plan.expected_sha256)) { throw 'Copied input changed.' }
        $entries += [pscustomobject]@{name=$plan.name; source=$plan.source; bytes=$copied.Length; sha256=$copiedHash}
    }
    $entries = @($entries | Sort-Object -Property name -CaseSensitive)
    $report.entries=$entries
    $report.input_bytes=$total
    if ($null -ne $recoveryArchive) { $recoveryArchive.Dispose(); $recoveryArchive=$null }
    $version=Invoke-ScreenTool $seven @('i','-sccUTF-8') '7zip-version'
    if ($version.stdout -notmatch '7-Zip[^\r\n]*26\.04') { throw '7-Zip runtime version must be 26.04.' }
    $report.seven_zip_version_output=($version.stdout -split '\r?\n',2)[0]
    if ($IncludeRecordAdaptiveCandidate) { $report.measurements_started=$true }
    if ($SpeedFrontierStudy) {
        Assert-QuietCpu 'before-measurements'
        $report.measurements_started=$true
    }
    $strategies=@('binary-adaptive','record-fast-trial')
    if ($IncludeRecordAdaptiveCandidate) { $strategies += 'record-adaptive-trial' }
    if ($SpeedFrontierStudy) { $strategies += @($SevenZipLevels | ForEach-Object { "7zip-mx$_" }) }
    else { $strategies += '7zip' }
    $roundCount=if($SpeedFrontierStudy){5}else{3}
    foreach ($round in 1..$roundCount) {
        if ($SpeedFrontierStudy) { Assert-QuietCpu "round-$round" }
        for ($position=0; $position -lt $strategies.Count; $position++) {
            $strategy=$strategies[($position+$round-1)%$strategies.Count]
            $label="$strategy-$round"
            $isSevenZip=$strategy -eq '7zip' -or $strategy -match '^7zip-mx(1|3|5|7|9)$'
            $level=if($strategy -eq '7zip'){9}elseif($isSevenZip){[int]$strategy.Substring(7)}else{$null}
            $extension=if ($isSevenZip) { '7z' } else { 'khc' }
            $archive=Join-Path $runs "$label.$extension"
            $extract=Join-Path $runs "$label-extracted"
            if ((Test-Path -LiteralPath $archive) -or (Test-Path -LiteralPath $extract)) { throw "Output already exists: $label" }
            if ($isSevenZip) {
                $arguments=@('a','-t7z',"-mx=$level",'-m0=lzma2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off','-spd','-sccUTF-8',$archive,'--') + @($entries | ForEach-Object { '.\' + $_.name })
                $encode=Invoke-ScreenTool $seven $arguments "$label-encode" -Measure
                $listing=Invoke-ScreenTool $seven @('l','-slt','-sccUTF-8',$archive) "$label-list"
                $methods=@([regex]::Matches($listing.stdout,'(?m)^Method = (.+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
                if ($methods.Count -eq 0) { throw '7-Zip did not report an actual method.' }
                $dictionaries=@([regex]::Matches(($methods -join "`n"),'LZMA2:(\d+)([bkm]?)') | ForEach-Object {
                    $n=[long]$_.Groups[1].Value
                    $effective=switch ($_.Groups[2].Value) { 'b' {$n} 'k' {$n*1KB} 'm' {$n*1MB} default { if ($n -gt 30) { throw 'Invalid LZMA2 dictionary exponent.' }; [long][Math]::Pow(2,$n) } }
                    [pscustomobject]@{token=$_.Value; bytes=$effective}
                })
                if ($total -gt 0 -and $dictionaries.Count -eq 0) { throw 'Missing effective LZMA2 dictionary.' }
                $format=[pscustomobject]@{methods=$methods; effective_dictionaries=$dictionaries; requested_dictionary_bytes=64MB}
                $null=Invoke-ScreenTool $seven @('t','-sccUTF-8',$archive) "$label-test"
                New-OutputDirectory $extract
                $decode=Invoke-ScreenTool $seven @('x','-sccUTF-8',$archive,"-o$extract",'-y') "$label-extract" -Measure
            } else {
                $encode=Invoke-ScreenTool $khc @('khc-create',$archive,'--source',$source,'--strategy',$strategy) "$label-encode" -Measure
                $listing=Invoke-ScreenTool $khc @('khc-list',$archive,'--json') "$label-list"
                $metadata=@(ConvertFrom-Json -InputObject $listing.stdout -ErrorAction Stop)
                if ($metadata.Count -ne $entries.Count) { throw 'KHC metadata entry count mismatch.' }
                foreach ($entry in $entries) {
                    $match=@($metadata | Where-Object { $_.name -ceq $entry.name })
                    if ($match.Count -ne 1 -or $match[0].is_directory -or $match[0].original_size -ne $entry.bytes) { throw 'KHC metadata mismatch.' }
                }
                $null=Invoke-ScreenTool $khc @('khc-test',$archive) "$label-test"
                $format=Get-KhcFrameInfo $archive $metadata
                if ($singleSeal -and $strategy -ceq 'record-fast-trial' -and
                    ($format.krs2_frames -ne 1 -or @($format.frames).Count -ne 1)) { throw 'SingleSeal requires one actual KRS2 frame in every record-fast sample; fallback is forbidden.' }
                $expectedRevision=switch ($strategy) {
                    'binary-adaptive' { 2 }
                    'record-fast-trial' { 6 }
                    'record-adaptive-trial' { 8 }
                    default { throw "Unexpected KHC strategy: $strategy" }
                }
                if ($format.archive_revision -ne $expectedRevision) { throw 'Unexpected KHC archive revision.' }
                New-OutputDirectory $extract
                $decode=Invoke-ScreenTool $khc @('khc-extract',$archive,'--output',$extract) "$label-extract" -Measure
            }
            $verified=@(Assert-Restored $extract)
            $samples.Add([pscustomobject]@{
                strategy=$strategy; round=$round; order_position=($position+1); archive=$archive; archive_bytes=(Get-Item -LiteralPath $archive).Length
                archive_sha256=(Get-Sha256 $archive); format=$format; encode=$encode; extract=$decode
                integrity_verified=$true; restored=$verified
            })
        }
    }
    foreach ($strategy in $strategies) {
        $group=@($samples | Where-Object strategy -CEQ $strategy)
        if (@($group.archive_sha256 | Select-Object -Unique).Count -ne 1 -or @($group.archive_bytes | Select-Object -Unique).Count -ne 1) { throw "Archive determinism mismatch: $strategy" }
    }
    if ($SpeedFrontierStudy) {
        $candidate=Get-StrategySummary -Strategy 'record-fast-trial' -ExpectedCount 5
        $profiles=@($SevenZipLevels | ForEach-Object { Get-StrategySummary -Strategy "7zip-mx$_" -ExpectedCount 5 })
        $eligible=@($profiles | Where-Object { $_.archive_bytes -ge $candidate.archive_bytes } | Sort-Object -Property combined_median_ms,strategy)
        $baseline=if($eligible.Count -gt 0){$eligible[0]}else{$null}
        $dominators=@($profiles | Where-Object {
            $_.archive_bytes -le $candidate.archive_bytes -and
            $_.encode_median_ms -le $candidate.encode_median_ms -and
            $_.extract_median_ms -le $candidate.extract_median_ms -and
            $_.peak_working_set_bytes -le $candidate.peak_working_set_bytes -and
            $_.peak_pagefile_bytes -le $candidate.peak_pagefile_bytes -and
            (-not $singleSeal -or
             ($_.encode_peak_working_set_bytes -le $candidate.encode_peak_working_set_bytes -and
              $_.extract_peak_working_set_bytes -le $candidate.extract_peak_working_set_bytes -and
              $_.encode_peak_pagefile_bytes -le $candidate.encode_peak_pagefile_bytes -and
              $_.extract_peak_pagefile_bytes -le $candidate.extract_peak_pagefile_bytes)) -and
            ($_.archive_bytes -lt $candidate.archive_bytes -or
             $_.encode_median_ms -lt $candidate.encode_median_ms -or
             $_.extract_median_ms -lt $candidate.extract_median_ms -or
             $_.peak_working_set_bytes -lt $candidate.peak_working_set_bytes -or
             $_.peak_pagefile_bytes -lt $candidate.peak_pagefile_bytes -or
             ($singleSeal -and
              ($_.encode_peak_working_set_bytes -lt $candidate.encode_peak_working_set_bytes -or
               $_.extract_peak_working_set_bytes -lt $candidate.extract_peak_working_set_bytes -or
               $_.encode_peak_pagefile_bytes -lt $candidate.encode_peak_pagefile_bytes -or
               $_.extract_peak_pagefile_bytes -lt $candidate.extract_peak_pagefile_bytes)))
        })
        $encodePass=$null -ne $baseline -and $candidate.encode_median_ms -le (0.95*$baseline.encode_median_ms)
        $extractPass=$null -ne $baseline -and $candidate.extract_median_ms -le (0.95*$baseline.extract_median_ms)
        $workingPass=$null -ne $baseline -and $candidate.peak_working_set_bytes -le $baseline.peak_working_set_bytes
        $pagedPass=$null -ne $baseline -and $candidate.peak_pagefile_bytes -le $baseline.peak_pagefile_bytes
        if ($singleSeal -and $null -ne $baseline) {
            $workingPass=$workingPass -and $candidate.encode_peak_working_set_bytes -le $baseline.encode_peak_working_set_bytes -and
                $candidate.extract_peak_working_set_bytes -le $baseline.extract_peak_working_set_bytes
            $pagedPass=$pagedPass -and $candidate.encode_peak_pagefile_bytes -le $baseline.encode_peak_pagefile_bytes -and
                $candidate.extract_peak_pagefile_bytes -le $baseline.extract_peak_pagefile_bytes
        }
        $screenPass=$null -ne $baseline -and $encodePass -and $extractPass -and $workingPass -and $pagedPass -and $dominators.Count -eq 0
        $report.frontier_profiles=$profiles
        $frontierDecision=[pscustomobject]@{
            source_condition=$SourceCondition
            screen_result=if($screenPass){'pass'}else{'no-go'}; candidate=$candidate; fastest_7zip_at_candidate_size_or_larger=$baseline
            encode_at_least_5_percent_faster=[bool]$encodePass; extract_at_least_5_percent_faster=[bool]$extractPass
            working_set_not_higher=[bool]$workingPass; paged_memory_not_higher=[bool]$pagedPass
            dominated_7zip_profiles=$dominators
            memory_comparison=if($singleSeal){'Both combined maxima and separate encode/extract working-set/pagefile maxima must be no higher; domination includes all four directional peaks.'}else{'Combined encode/extract maxima.'}
            rule='KRS2 must be <= the fastest combined-median 7-Zip profile with archive size >= KRS2, at least 5% faster on both encode and extract medians, no higher WS/paged peaks, and not be dominated by any of the five 7-Zip profiles.'
        }
    }
    foreach ($entry in $entries) {
        if ((Get-Sha256 (Join-Path $source $entry.name)) -cne $entry.sha256) { throw 'Input snapshot changed during screen.' }
    }
    foreach ($tool in $report.tools) { if ((Get-Sha256 $tool.path) -cne $tool.sha256) { throw 'Tool changed during screen.' } }
    Assert-SingleSealWindow
    # 最終hash・時刻gateの成功後だけ採否を公開し、失敗reportへpassを残さない。
    if ($SpeedFrontierStudy) { $report.frontier_decision=$frontierDecision }
    $report.determinism_verified=$true
    $report.status='passed'
} catch {
    $failure=$_
    $report.status='failed'
    $report.error=$_.Exception.Message
} finally {
    if ($null -ne $recoveryArchive) { $recoveryArchive.Dispose(); $recoveryArchive=$null }
    $json=ConvertTo-Json -InputObject $report -Depth 30
    Write-NewText $reportPath $json
    $errorText=if($null -ne $failure){$failure.Exception.Message}else{''}
    Write-Output (ConvertTo-Json -InputObject ([ordered]@{
        status=$report.status; report_path=$reportPath; sample_count=$report.samples.Count
        determinism_verified=[bool]$report.determinism_verified; error=$errorText
    }) -Compress)
}
if ($null -ne $failure) { throw $failure }
