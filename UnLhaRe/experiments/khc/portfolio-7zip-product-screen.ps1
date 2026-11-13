#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][ValidateSet('eGovLawXml20261016','AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020','UciTabularDevelopment20261020')][string]$CorpusProfile,
    [Parameter(Mandatory)][ValidateRange(0,9)][int]$Round,
    [Parameter(Mandatory)][ValidateSet('portfolio-trial','7zip')][string]$Strategy,
    [string]$KhcExecutable = (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'),
    [string]$SevenZipPath = 'C:\Program Files\7-Zip\7z.exe',
    [string]$InputRecoveryZip = (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\egov-screen-20261020\input.zip'),
    [string]$CampaignManifestSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 旧UCI開発用profileはmetadata登録のみ。専用Dry Bean holdoutとは分離する。
if ($CorpusProfile -ieq 'UciTabularDevelopment20261020') { throw 'UCI development-only metadata is excluded from this screen/aggregate, blind holdout completeness and superiority thresholds; no runnable wrapper is admitted.' }
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force

# 開発集合と独立holdoutを固定profileで区別し、一般的優越性・最終GOAL達成は主張しない。
function Plain([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Absolute path required: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point rejected: $part"
        }
    }
    return $full
}
function Hash([string]$Path) { (Get-FileHash -LiteralPath (Plain $Path) -Algorithm SHA256).Hash.ToLowerInvariant() }
function Source-Manifest([string]$Root) {
    $rootPath=Plain $Root
    $pathsByName=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($item in Get-ChildItem -LiteralPath $rootPath -Recurse -Force -ErrorAction Stop){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Source manifest rejects reparse point: $($item.FullName)"}
        if(-not $item.PSIsContainer -and $item.Extension -ceq '.rs'){
            $relative=[IO.Path]::GetRelativePath($rootPath,$item.FullName).Replace('\','/')
            $pathsByName.Add($relative,$item.FullName)
        }
    }
    $names=[string[]]$pathsByName.Keys; [Array]::Sort($names,[StringComparer]::Ordinal)
    $builder=[Text.StringBuilder]::new()
    foreach($name in $names){
        $path=$pathsByName[$name]; $item=Get-Item -LiteralPath $path -Force; $sha=Hash $path
        $null=$builder.Append($name).Append([char]9).Append($item.Length).Append([char]9).Append($sha).Append([char]10)
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
}
function Output-Path([string]$Path) {
    $full = Plain $Path
    if (-not $full.StartsWith($work + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output escaped registered work directory: $full"
    }
    return $full
}
function New-RunDirectory([string]$Path) {
    $full = Plain $Path
    $taskPaths = Get-KhcStorageTaskPaths
    $taskRoot = Plain ([string]$taskPaths.WorkRoot)
    if ([IO.Path]::GetDirectoryName($full) -ine $taskRoot) {
        throw 'Registered run root must be a direct child of the validated task root.'
    }
    if (Test-Path -LiteralPath $full) { throw "Output already exists: $full" }
    $null = New-Item -ItemType Directory -Path $full -ErrorAction Stop
    $created = Plain $full
    if (-not [IO.Directory]::Exists($created)) { throw "Registered run root could not be created: $created" }
}
function New-Directory([string]$Path) {
    $full = Output-Path $Path
    if (Test-Path -LiteralPath $full) { throw "Output already exists: $full" }
    $null = New-Item -ItemType Directory -Path $full
}
function Check-Storage {
    Assert-KhcStorageContext -WorkDirectory $work
    $record = Get-Content -LiteralPath (Plain $env:KHC_STORAGE_RUN_RECORD) -Raw | ConvertFrom-Json
    if ([long]$record.max_bytes -ne 32MB -or [int]$record.max_entries -ne 512) {
        throw 'This single-sample screen requires exactly 32 MiB / 512 entries.'
    }
    $entries = @(Get-ChildItem -LiteralPath $work -Recurse -Force -ErrorAction Stop)
    $bytes = 0L
    foreach ($entry in $entries) {
        $null = Output-Path $entry.FullName
        if (-not $entry.PSIsContainer) { $bytes += $entry.Length }
    }
    # rootと最大512KiBのreportを常に予約する。
    if ($entries.Count + 2 -gt 512 -or $bytes + 512KB -gt 32MB) { throw 'Inventory exceeded cap including report reservation.' }
}
function Save-Report {
    $report.commands = $commands.ToArray(); $report.samples = $samples.ToArray(); $report.cpu_gates = $quiet.ToArray()
    $report.updated_utc = [DateTime]::UtcNow.ToString('o')
    if ($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
        # 実行中の一覧検証用データと保存用データを分け、個別記事の識別子を保存しない。
        $savedReport=ConvertFrom-Json (ConvertTo-Json -InputObject $report -Depth 24) -AsHashtable -Depth 24
        foreach ($command in @($savedReport.commands)+@($savedReport.samples | ForEach-Object { $_.create; $_.extract })) {
            if ($null -eq $command) { continue }
            $command.stdout='[omitted: NICT local-only content]'; $command.stderr='[omitted: NICT local-only content]'
            $command.argv_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n",[string[]]$command.argv)))).ToLowerInvariant()
            $command.argv=@('[omitted: NICT member identifiers]'); if ($command.error) { $command.error='NICT command failed; content details omitted.' }
        }
        if ($null -ne $savedReport.input) { $savedReport.input.entries=@() }
        foreach ($sample in $savedReport.samples) {
            if ($null -ne $sample.restored) { $sample.restored.entries=@() }
            if ($null -ne $sample.format -and $sample.format.Contains('frames')) {
                $index=0; foreach ($frame in $sample.format.frames) { $frame.member=[string]$index; $index++ }
            }
        }
        if ($savedReport.error) { $savedReport.error='NICT screen failed; content details omitted.' }
        $savedReport.inventory=@()
        $json=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $savedReport -Depth 24))
    } else { $json = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $report -Depth 24)) }
    if ($json.Length -gt 512KB) {
        if ($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) { throw 'NICT report exceeds 512 KiB.' }
        # 最後の失敗記録を残すため、重複したconsole本文だけを捨てる。argvと計測は保持する。
        $report.status='failed'; $report.error='Report exceeded 512 KiB; console bodies omitted.'
        $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
        $report.candidate_screen_passed=$null; $report.candidate_decision=$null
        foreach ($command in $commands) { $command.stdout='[omitted: report bound]'; $command.stderr='[omitted: report bound]' }
        foreach ($sample in $samples) {
            foreach ($phase in @('create','extract')) {
                if ($null -ne $sample[$phase]) { $sample[$phase].stdout='[omitted: report bound]'; $sample[$phase].stderr='[omitted: report bound]' }
            }
        }
        $json=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $report -Depth 24))
        if ($json.Length -le 512KB) { [IO.File]::WriteAllBytes((Output-Path $reportPath),$json) }
        throw 'Report exceeds 512 KiB.'
    }
    [IO.File]::WriteAllBytes((Output-Path $reportPath), $json)
}
function New-FinalErrorDetails {
    param([Parameter(Mandatory)][string]$Phase, [Parameter(Mandatory)][Management.Automation.ErrorRecord]$Caught)
    if ($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
        $message="NICT $Phase failed; content details omitted."
        return [pscustomobject]@{
            Record=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message),'NictScreenFailed',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
            Message=$message
        }
    }
    return [pscustomobject]@{ Record=$Caught; Message="$Phase failed: $($Caught.Exception.Message)" }
}
function Assert-QuietCpu([string]$Label) {
    $gate = [ordered]@{ label=$Label; samples=@(); limit_percent=15; required_samples=5; interval_ms=1000; error=$null }
    $quiet.Add($gate)
    try {
        foreach ($index in 1..5) {
            Start-Sleep -Milliseconds 1000
            $cpu = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
            if ($cpu.Count -ne 1 -or $null -eq $cpu[0].PercentProcessorTime) { throw 'Missing _Total CPU counter.' }
            $value = [double]$cpu[0].PercentProcessorTime
            $gate.samples += @([pscustomobject]@{ index=$index; utc=[DateTime]::UtcNow.ToString('o'); percent=$value })
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 15) {
                throw "CPU gate failed before $Label : $value percent; no retry."
            }
        }
    } catch { $gate.error=$_.Exception.Message; throw }
}

# OS peak countersとpollしたprivate bytes最大値は別の値として保持する。
# timedな採用には、3カウンターが正値で、取得前後ともプロセス稼働中と確認できた標本を最低1つ要求する。
function Tool([string]$Executable, [string[]]$Arguments, [string]$Label, [switch]$Timed, [int]$ListingStdoutBytes=16KB) {
    if ($ListingStdoutBytes -notin @(16KB,256KB) -or ($ListingStdoutBytes -ne 16KB -and ($CorpusProfile -cnotin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020') -or -not $Label.EndsWith('-list')))) { throw 'Unregistered listing capture bound.' }
    $command = [ordered]@{ label=$Label; executable=$Executable; argv=$Arguments; working_directory=$source; timed=[bool]$Timed
        exit_code=$null; wall_ms=$null; cpu_ms=$null; os_peak_working_set_bytes=0L; os_peak_paged_memory_bytes=0L
        sampled_private_bytes_max=0L; memory_samples=0; live_memory_samples=0; memory_sampling_required=[bool]$Timed
        memory_sampling_complete=$true; memory_sampling_status='pending'; memory_missing_counter_fields=@()
        memory_unavailable_after_exit_counter_fields=@()
        memory_poll_target_ms=10; timeout_seconds=60
        stdout=''; stderr=''; result='failed'; error=$null }
    $commands.Add($command)
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory=$source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8; $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    $info.Environment['TEMP']=$work; $info.Environment['TMP']=$work
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info
    $timer=[Diagnostics.Stopwatch]::new(); $captures=@(); $started=$false; $lastStorage=0L
    try {
        Check-Storage
        if ($Timed) { Assert-QuietCpu $Label }
        $timer.Start()
        if (-not $p.Start()) { throw "Cannot start: $Label" }; $started=$true
        foreach ($pipe in @($p.StandardOutput.BaseStream, $p.StandardError.BaseStream)) {
            $buffer=[byte[]]::new(1024)
            $captures+=@{ pipe=$pipe; buffer=$buffer; data=[IO.MemoryStream]::new(); done=$false; pending=$pipe.ReadAsync($buffer,0,$buffer.Length) }
        }
        while ($true) {
            $p.Refresh()
            $sampleStartedAlive = -not $p.HasExited
            $working=[long]$p.PeakWorkingSet64; $paged=[long]$p.PeakPagedMemorySize64; $private=[long]$p.PrivateMemorySize64
            $p.Refresh()
            $exited=$p.HasExited
            $sampleWasLive = $sampleStartedAlive -and -not $exited
            # timedなcreate/extractは実行中のカウンター欠測を拒否する。終了直後の再取得だけが欠測した場合は
            # 実行中に得た正値の最大を維持し、終了後の欠測として別記する。untimedも各取得値を独立確認する。
            $missingCounters=@()
            if ($working -le 0) {
                $missingCounters+=@('working_set')
            } else {
                $command.os_peak_working_set_bytes=[Math]::Max($command.os_peak_working_set_bytes,$working)
                if ($working -gt 160MB) { throw "160 MiB memory gate exceeded: $Label (working set)" }
            }
            if ($paged -le 0) {
                $missingCounters+=@('paged_memory')
            } else {
                $command.os_peak_paged_memory_bytes=[Math]::Max($command.os_peak_paged_memory_bytes,$paged)
                if ($paged -gt 160MB) { throw "160 MiB memory gate exceeded: $Label (paged memory)" }
            }
            if ($private -le 0) {
                $missingCounters+=@('private_bytes')
            } else {
                $command.sampled_private_bytes_max=[Math]::Max($command.sampled_private_bytes_max,$private)
                if ($private -gt 160MB) { throw "160 MiB memory gate exceeded: $Label (private bytes)" }
            }
            if ($missingCounters.Count -gt 0) {
                $afterExitMayBeIncomplete = $Timed -and $exited -and $command.live_memory_samples -gt 0
                if (-not $afterExitMayBeIncomplete) { $command.memory_sampling_complete=$false }
                foreach ($counter in $missingCounters) {
                    if ($afterExitMayBeIncomplete) {
                        if ($command.memory_unavailable_after_exit_counter_fields -cnotcontains $counter) {
                            $command.memory_unavailable_after_exit_counter_fields+=@($counter)
                        }
                    } elseif ($command.memory_missing_counter_fields -cnotcontains $counter) {
                        $command.memory_missing_counter_fields+=@($counter)
                    }
                }
            }
            if ($Timed -and $missingCounters.Count -gt 0 -and -not $exited) { throw "Missing live memory counter: $Label" }
            if ($working -gt 0 -and $paged -gt 0 -and $private -gt 0) {
                $command.memory_samples++
                if ($sampleWasLive) { $command.live_memory_samples++ }
            }
            foreach ($capture in $captures) {
                if ($capture.done -or -not $capture.pending.IsCompleted) { continue }
                $count=$capture.pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $capture.done=$true; continue }
                $limit=if ($Label.EndsWith('-list') -and $CorpusProfile -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
                    if ([object]::ReferenceEquals($capture.pipe,$p.StandardOutput.BaseStream)) { $ListingStdoutBytes } else { 2KB }
                } elseif ($Label.EndsWith('-list') -or $Label -ceq '7zip-version') { 16KB } else { 2KB }
                if ($capture.data.Length+$count -gt $limit) { throw "Bounded stream exceeded: $Label" }
                $capture.data.Write($capture.buffer,0,$count)
                $capture.pending=$capture.pipe.ReadAsync($capture.buffer,0,$capture.buffer.Length)
            }
            if ($timer.Elapsed.TotalSeconds -gt 60) { throw "60-second timeout: $Label" }
            if ($p.HasExited -and @($captures | Where-Object { -not $_.done }).Count -eq 0) { break }
            if ($timer.ElapsedMilliseconds-$lastStorage -ge 250) { Check-Storage; $lastStorage=$timer.ElapsedMilliseconds }
            Start-Sleep -Milliseconds 10
        }
        $timer.Stop()
        $command.exit_code=$p.ExitCode; $command.cpu_ms=$p.TotalProcessorTime.TotalMilliseconds
        if ($command.exit_code -ne 0) { throw "Command exited $($command.exit_code): $Label" }
        if ($Timed -and ($command.live_memory_samples -le 0 -or $command.os_peak_working_set_bytes -le 0 -or $command.os_peak_paged_memory_bytes -le 0 -or $command.sampled_private_bytes_max -le 0)) {
            $command.memory_sampling_complete=$false
            throw "No complete positive live memory sample before exit: $Label"
        }
        $command.result='passed'
    } catch { $command.error=$_.Exception.Message; throw }
    finally {
        $timer.Stop(); $command.wall_ms=$timer.Elapsed.TotalMilliseconds
        try {
            if ($started -and -not $p.HasExited) {
                $p.Kill($true)
                if (-not $p.WaitForExit(5000)) { throw "Child tree did not stop: $Label" }
            }
            if ($started -and $p.HasExited) { $command.exit_code=$p.ExitCode; $command.cpu_ms=$p.TotalProcessorTime.TotalMilliseconds }
            $hasMemoryCounter=($command.os_peak_working_set_bytes -gt 0 -or $command.os_peak_paged_memory_bytes -gt 0 -or $command.sampled_private_bytes_max -gt 0)
            $command.memory_sampling_status=if (-not $hasMemoryCounter) { 'unavailable' } elseif ($Timed -and $command.live_memory_samples -le 0) { 'partial' } elseif ($command.memory_sampling_complete) { 'complete' } else { 'partial' }
            if ($captures.Count -eq 2) {
                $command.stdout=[Text.Encoding]::UTF8.GetString($captures[0].data.ToArray())
                $command.stderr=[Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())
            }
        } finally { foreach ($capture in $captures) { $capture.data.Dispose() }; $p.Dispose() }
    }
    Check-Storage
    return [pscustomobject]$command
}
function Manifest([string]$Directory) {
    $root=Plain $Directory
    $rows=@(foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse) {
        $null=Output-Path $item.FullName
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unexpected reparse point in input or restored tree.' }
        if ($item.PSIsContainer) { continue }
        $relative=$item.FullName.Substring($root.Length+1).Replace([char]92,[char]47)
        [pscustomobject]@{ name=$relative; bytes=[long]$item.Length; sha256=Hash $item.FullName }
    })
    $names=[string[]]@($rows.name); [Array]::Sort($names,[StringComparer]::Ordinal)
    if ($names.Count -ne $expectedFileCount -or ($names -join "`n") -cne ($expectedNames -join "`n")) { throw 'Extra, omitted, or changed member path.' }
    $lines=[Collections.Generic.List[string]]::new(); $sorted=@()
    foreach ($name in $names) {
        $row=@($rows | Where-Object name -CEQ $name)[0]; $sorted+=@($row)
        $lines.Add("$name`t$($row.bytes.ToString([Globalization.CultureInfo]::InvariantCulture))`t$($row.sha256)")
    }
    $manifestText=[string]::Join("`n",$lines)
    if ($isCanterbury) { $manifestText+="`n" }
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($manifestText))).ToLowerInvariant()
    $total=[long](($rows | Measure-Object bytes -Sum).Sum)
    if ($total -ne $expectedTotalBytes -or $sha -cne $manifestPin) { throw 'Raw file length/SHA manifest mismatch.' }
    return [pscustomobject]@{ files=$expectedFileCount; bytes=$total; manifest_sha256=$sha; entries=$sorted }
}
function Khc-Format([string]$Archive) {
    $b=[IO.File]::ReadAllBytes((Plain $Archive))
    if ($b.Length -lt 40 -or [Text.Encoding]::ASCII.GetString($b,0,8) -cne "KHC1ARC`0" -or $b[8] -ne 10 -or
        $b[9] -ne 0 -or $b[10] -ne 0 -or $b[11] -ne 0 -or [BitConverter]::ToUInt32($b,12) -ne 1MB -or
        [BitConverter]::ToUInt32($b,16) -ne $expectedFileCount) { throw 'Expected KHC archive revision 10, known flags, 1 MiB blocks and the pinned member count.' }
    $at=32L+[BitConverter]::ToUInt32($b,20); $frames=@()
    foreach ($entry in $report.input.entries) {
        $remaining=[long]$entry.bytes
        while ($remaining -gt 0) {
            if ($at+4 -gt $b.LongLength) { throw 'Truncated KHC frame prefix.' }
            $length=[long][BitConverter]::ToUInt32($b,[int]$at); $at+=4
            if ($length -lt 8 -or $at+$length -gt $b.LongLength) { throw 'Invalid KHC frame extent.' }
            $magic=[Text.Encoding]::ASCII.GetString($b,[int]$at,8)
            if ($magic -cnotin @("KHC1BLK`0","KCS1BLK`0","KRS2BLK`0","KRS3BLK`0")) { throw 'Unknown PortfolioTrial frame.' }
            $frames+=@([pscustomobject]@{ member=$entry.name; offset=$at; bytes=$length; magic=$magic })
            $at+=$length; $remaining-=[Math]::Min($remaining,1MB)
        }
        $at+=4 # file CRC is checked by the complete product extraction.
    }
    if ($at+8 -ne $b.LongLength -or [Text.Encoding]::ASCII.GetString($b,[int]$at,8) -cne "KHC1END`0") { throw 'KHC trailer/extent mismatch.' }
    return [pscustomobject]@{ revision=10; frames=$frames }
}
function Seven-Format([string]$Archive,[string]$Label) {
    $listingCap=if ($CorpusProfile -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) { $profile.ListingOutputBytes } else { 16KB }
    $listing=Tool $seven @('l','-slt','-sccUTF-8',$Archive) "$Label-list" -ListingStdoutBytes $listingCap
    $methods=@([regex]::Matches($listing.stdout,'(?m)^Method = (.+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if ($methods.Count -ne ($expectedFileCount+1)) { throw 'Expected one 7-Zip method record per pinned member plus the archive record.' }
    $dictionaries=@(foreach ($method in $methods) {
        if ($method -cnotmatch '^LZMA2:(\d+)([bkm]?)$') { throw "Unexpected actual method: $method" }
        $n=[long]$Matches[1]
        $bytes=switch ($Matches[2]) { 'b' {$n} 'k' {$n*1KB} 'm' {$n*1MB} default { if ($n -gt 26) { throw 'Dictionary exponent exceeds 26.' }; [long][Math]::Pow(2,$n) } }
        if ($bytes -le 0 -or $bytes -gt 64MB) { throw 'Invalid effective dictionary.' }; $bytes
    })
    $solidRecords=[regex]::Matches($listing.stdout,'(?m)^Solid = ([+-])\r?$')
    if ($solidRecords.Count -ne 1) { throw 'Missing or ambiguous 7-Zip Solid property.' }
    $solid=($solidRecords[0].Groups[1].Value -ceq '+')
    if (@($dictionaries | Select-Object -Unique).Count -ne 1 -or
        ($expectedFileCount -gt 1 -and -not $solid) -or
        $listing.stdout -cnotmatch '(?m)^Blocks = 1\r?$') { throw 'Unexpected solid/dictionary layout.' }
    $memberText=($listing.stdout -split '(?m)^----------\r?\n',2)
    if ($memberText.Count -ne 2) { throw 'Missing 7z member boundary.' }
    $names=@([regex]::Matches($memberText[1],'(?m)^Path = (.+)\r?$') | ForEach-Object { $_.Groups[1].Value.TrimEnd([char]13).Replace([char]92,[char]47) })
    if (($names -join "`n") -cne ($expectedNames -join "`n")) { throw '7z member order/name mismatch.' }
    foreach ($field in @('Modified','Created','Accessed')) {
        if ($memberText[1] -match "(?m)^$field = \S") { throw "Unexpected stored timestamp: $field" }
    }
    return [pscustomobject]@{ solid=$solid; actual_methods=$methods; effective_dictionary_bytes=$dictionaries; listing_command=$listing.label }
}
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$work=(Plain $WorkDirectory).TrimEnd([char]92,[char]47)
$source=Join-Path $work 'source'; $archives=Join-Path $work 'archives'; $reportPath=Join-Path $work 'portfolio-product-report.json'
if (Test-Path -LiteralPath $reportPath) { throw 'Report already exists; refusing to overwrite another run.' }
$expectedNames=[string[]]@()
$sevenInputNames=[string[]]@()
$expectedFileCount=100
$expectedTotalBytes=9527638L
$manifestPin='332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3'
$profile=Get-KhcPortfolioInputProfile $CorpusProfile
$profileCampaign=$null
$isCanterbury=($CorpusProfile -ceq 'CanterburyDevelopmentKcs1CountLength20261020')
$isHoldout=($CorpusProfile -cin @('JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020'))
$campaignValidator=if ($CorpusProfile -ceq 'UciDryBeanHoldout20261020') { 'Assert-KhcDryBeanHoldoutCampaign' } elseif ($isCanterbury) { 'Assert-KhcCanterburyKcs1Campaign' } elseif ($CorpusProfile -ceq 'JmaTokyoDaily2010_2025Holdout20261020') { 'Assert-KhcJmaHoldoutCampaign' } elseif ($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020') { 'Assert-KhcTokyoPopulationHoldoutCampaign' } elseif ($CorpusProfile -ceq 'LivedoorNews2012Holdout20261020') { 'Assert-KhcLivedoorHoldoutCampaign' } elseif($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){'Assert-KhcNictKcs1HoldoutCampaign'}elseif($CorpusProfile -ceq 'NictWikiCorpusHoldout20261020'){'Assert-KhcNictHoldoutCampaign'}else{ 'Assert-KhcAozoraCampaign' }
if ($isCanterbury -or $CorpusProfile -cin @('AozoraDevelopment20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) {
    $profileCampaign=& $campaignValidator -CampaignManifestSha256 $CampaignManifestSha256 -RequireOpenWindow
    $null=Assert-KhcPortfolioInput -CorpusProfile $CorpusProfile -InputRecoveryZip $InputRecoveryZip -CampaignManifestSha256 $CampaignManifestSha256
    $expectedFileCount=$profile.Files; $expectedTotalBytes=$profile.Bytes; $manifestPin=$profile.ManifestSha256
} elseif ($PSBoundParameters.ContainsKey('CampaignManifestSha256')) { throw 'The immutable e-Gov campaign does not accept an Aozora start marker.' }
$sourceManifestPin='0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404'
if ($isCanterbury -or $CorpusProfile -cin @('NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) { $sourceManifestPin=$profile.SourceManifestSha256 }
$sourceRoot=Join-Path $PSScriptRoot '..\..\src'
$workerSha=Hash $PSCommandPath
$registration=Get-Content -LiteralPath (Plain $env:KHC_STORAGE_RUN_RECORD) -Raw | ConvertFrom-Json
$runId=[string]$registration.run_id
$pins=@(
    @{ path=$KhcExecutable; expected_path=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe'); sha='3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b' },
    @{ path=$SevenZipPath; expected_path='C:\Program Files\7-Zip\7z.exe'; sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53' },
    @{ path=$InputRecoveryZip; expected_path=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\egov-screen-20261020\input.zip'); sha='861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099' },
    @{ path=(Join-Path $PSScriptRoot 'storage-lifecycle.psm1'); expected_path='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\storage-lifecycle.psm1'; sha='e3953d42595b66aba8a40da393e13bfd32e269b75c7d443e207dbfc9a202ba0c' },
    @{ path=(Join-Path $PSScriptRoot 'disk-budget.ps1'); expected_path='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\disk-budget.ps1'; sha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd' }
)
if ($null -ne $profileCampaign) {
    $pins[2]=@{path=$InputRecoveryZip;expected_path=(Get-KhcPortfolioInputZipPath $profile);sha=$profile.ZipSha256}
    $pins[3].sha=[string]$profileCampaign.lifecycle_sha256
}
if ($isCanterbury -or $CorpusProfile -cin @('NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) { $pins[0].sha=$profile.CliSha256 }
$commands=[Collections.Generic.List[object]]::new(); $samples=[Collections.Generic.List[object]]::new(); $quiet=[Collections.Generic.List[object]]::new()
$report=[ordered]@{ status='running'; error=$null; run_id=$runId; round=$Round; strategy=$Strategy; started_utc=[DateTime]::UtcNow.ToString('o'); scope=$profile.Scope; corpus_profile=$CorpusProfile; protocol='One preregistered PortfolioTrial revision 10 or 7-Zip 26.04 sample; campaign aggregation is separate.'
    holdout_evaluated=$isHoldout; general_superiority_claimed=$false; final_goal_achieved=$false
    candidate_size_passed=$null; candidate_time_passed=$null; candidate_screen_passed=$null; candidate_decision=$null
    caps=[ordered]@{ storage_bytes=32MB; entries=512; process_memory_bytes=160MB; command_seconds=60; khc_create_threads=1; khc_extract_workers=4; seven_zip_create_threads=1; seven_zip_extract_threads=4; per_run_timeout_seconds=300; campaign_wall_seconds=1800; report_bytes=512KB }
    required_gate='This report records one successful sample only; aggregate exactly 10 rounds x 2 strategies, exclude round 0, then apply the preregistered 95% size and no-slower median create/extract criteria.'
    input=$null; source_manifest_sha256=$null; worker_sha256=$workerSha; pins=$pins; seven_zip_file_version=$null; khc_version=$null; expected_khc_version='1.0.4'; commands=@(); samples=@(); cpu_gates=@(); summary=@(); paired_rounds=@(); inventory=@(); updated_utc=$null }
if ($null -ne $profileCampaign) {
    $report.development_only=(-not $isHoldout)
    $report.campaign_manifest_sha256=$CampaignManifestSha256
    $report.source_family=$profile.SourceFamily; $report.source_family_count=1
    if ($CorpusProfile -ceq 'UciDryBeanHoldout20261020') {
        $report.source_condition=$profile.Name; $report.khc_source_manifest_sha256=$profile.KhcSourceManifestSha256
        $report.input_entry_prefix=$profile.EntryPrefix; $report.source_provenance=$profile.Provenance
        $report.input_zip_path=Get-KhcPortfolioInputZipPath $profile; $report.input_zip_bytes=$profile.ZipBytes; $report.input_zip_sha256=$profile.ZipSha256
        $report.single_family_screen_only=$true; $report.aggregate_category_count=0
    }
    if ($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020') {
        $report.source_condition=$profile.Name; $report.khc_source_manifest_sha256=$profile.KhcSourceManifestSha256
        $report.input_entry_prefix=$profile.EntryPrefix
    }
    if ($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
        $report.input_zip_path=Get-KhcPortfolioInputZipPath $profile; $report.input_zip_bytes=$profile.ZipBytes; $report.input_zip_sha256=$profile.ZipSha256
    }
    if ($isHoldout) {
        $report.input_role='holdout-only'; $report.holdout_only=$true; $report.training_allowed=$false; $report.tuning_allowed=$false
        $report.start_date=$profile.StartDate; $report.end_date=$profile.EndDate; $report.fields=$profile.Fields
        if ($CorpusProfile -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
            $report.source_provenance=$profile.Provenance
            $report.caps.listing_stdout_bytes=$profile.ListingOutputBytes; $report.caps.listing_stderr_bytes=2KB
        }
        if ($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020') {
            $report.source_page=$profile.SourcePage
            $report.source_catalog_page=$profile.SourceCatalogPage
            $report.source_direct_csv_url=$profile.SourceDirectCsvUrl
            $report.source_attribution=$profile.SourceAttribution
            $report.source_license_label=$profile.SourceLicenseLabel
            $report.source_license_version=$profile.SourceLicenseVersion
            $report.source_license_note=$profile.SourceLicenseNote
            $report.source_content_handling=$profile.SourceContentHandling
        }
    } elseif ($isCanterbury) {
        $report.input_role='development-only'; $report.holdout_only=$false; $report.training_allowed=$true; $report.tuning_allowed=$true
        $report.source_condition=$profile.Name; $report.khc_source_manifest_sha256=$profile.KhcSourceManifestSha256
        $report.input_zip_path=Get-KhcPortfolioInputZipPath $profile; $report.input_zip_bytes=$profile.ZipBytes; $report.input_zip_sha256=$profile.ZipSha256
        $report.input_entry_prefix=$profile.EntryPrefix
    } else {
        $report.candidate_manifest_sha256=$profile.CandidateManifestSha256; $report.development_work_ids=@(424,752)
    }
}
$oldTemp=$env:TEMP; $oldTmp=$env:TMP; $failure=$null; $workRootReady=$false
try {
    New-RunDirectory $work
    $workRootReady=$true
    Check-Storage
    foreach ($pin in $pins) {
        if ((Plain $pin.path) -cne $pin.expected_path -or (Hash $pin.path) -cne $pin.sha) { throw 'Preregistered path/SHA mismatch.' }
    }
    $report.source_manifest_sha256=Source-Manifest $sourceRoot
    if($report.source_manifest_sha256 -cne $sourceManifestPin){throw 'Pinned full Rust source manifest mismatch.'}
    if($CorpusProfile -cin @('NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){
        $report.khc_source_manifest_sha256=Source-Manifest (Join-Path $sourceRoot 'khc')
        if($report.khc_source_manifest_sha256 -cne $profile.KhcSourceManifestSha256){throw 'Pinned holdout KHC source manifest mismatch.'}
    }
    if($isCanterbury){
        $report.khc_source_manifest_sha256=Source-Manifest (Join-Path $sourceRoot 'khc')
        if($report.khc_source_manifest_sha256 -cne $profile.KhcSourceManifestSha256){throw 'Pinned Canterbury KCS1 KHC source manifest mismatch.'}
    }
    $khc=Plain $KhcExecutable; $seven=Plain $SevenZipPath; $recovery=Plain $InputRecoveryZip
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($seven)
    if ($version.FileMajorPart -ne 26 -or $version.FileMinorPart -ne 4 -or $version.FileBuildPart -ne 0 -or $version.FilePrivatePart -ne 0) { throw 'Expected 7-Zip file version 26.04.' }
    $report.seven_zip_file_version=$version.FileVersion
    New-Directory $source; New-Directory $archives
    $env:TEMP=$work; $env:TMP=$work
    $zip=[IO.Compression.ZipFile]::OpenRead($recovery)
    try {
        $prefix=$profile.EntryPrefix
        $members=@($zip.Entries)
        if ($isCanterbury) { $members=@($zip.Entries | Where-Object { $_.FullName.StartsWith($prefix,[StringComparison]::Ordinal) }) }
        if ($members.Count -ne $expectedFileCount) { throw 'The pinned recovery ZIP must contain the fixed file count and no directory or extra entries in the selected input.' }
        $memberNames=[Collections.Generic.List[string]]::new()
        $seenNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $memberBytes=0L
        foreach ($member in $members) {
            if (-not $member.FullName.StartsWith($prefix,[StringComparison]::Ordinal) -or [string]::IsNullOrEmpty($member.Name)) { throw 'Unexpected e-Gov ZIP entry path.' }
            $name=$member.FullName.Substring($prefix.Length)
            if ($name.StartsWith('/') -or $name.Contains('\') -or $name.Contains(':') -or $name.Contains('//') -or $name.EndsWith('/') -or $name -match '(^|/)\.{1,2}(/|$)') { throw "Unsafe e-Gov member path: $name" }
            if (-not $seenNames.Add($name)) { throw "Duplicate e-Gov member path: $name" }
            if ($member.Length -le 0 -or $member.Length -gt $expectedTotalBytes) { throw "Invalid e-Gov member length: $name" }
            $memberBytes += [long]$member.Length
            $memberNames.Add($name)
        }
        if ($memberBytes -ne $expectedTotalBytes) { throw 'e-Gov recovery ZIP expanded length mismatch.' }
        $expectedNames=[string[]]$memberNames.ToArray(); [Array]::Sort($expectedNames,[StringComparer]::Ordinal)
        $sevenInputNames=[string[]]@($expectedNames | ForEach-Object { $_.Replace([char]47,[IO.Path]::DirectorySeparatorChar) })
        foreach ($name in $expectedNames) {
            $matches=@($members | Where-Object FullName -CEQ ($prefix+$name))
            if ($matches.Count -ne 1 -or $matches[0].Length -le 0 -or $matches[0].Length -gt $expectedTotalBytes) { throw "Missing/duplicate/oversized ZIP member: $name" }
            $member=$matches[0]; $inputStream=$member.Open()
            try {
                $outputPath=Output-Path (Join-Path $source ($name.Replace([char]47,[IO.Path]::DirectorySeparatorChar)))
                $parentPath=[IO.Path]::GetDirectoryName($outputPath)
                $null=[IO.Directory]::CreateDirectory($parentPath)
                for($checkPath=$parentPath; $checkPath; $checkPath=[IO.Path]::GetDirectoryName($checkPath)) {
                    if(-not $checkPath.StartsWith($source+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -and $checkPath -ine $source){throw 'e-Gov output parent escaped the source root.'}
                    $checkItem=Get-Item -LiteralPath $checkPath -Force
                    if($checkItem.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'e-Gov extraction parent is a reparse point.'}
                    if($checkPath -ieq $source){break}
                }
                $output=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew)
                try {
                    $buffer=[byte[]]::new(8192); $written=0L
                    while (($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $written+=$count
                        if ($written -gt $member.Length) { throw 'ZIP inflated beyond member size.' }
                        $output.Write($buffer,0,$count)
                    }
                    if ($written -ne $member.Length) { throw 'ZIP length mismatch.' }
                } finally { $output.Dispose() }
                # KHC manifestは入力mtimeを保存するため、固定ZIPの時刻を戻してrun間のarchive SHAを安定させる。
                [IO.File]::SetLastWriteTimeUtc($outputPath, $member.LastWriteTime.UtcDateTime)
            } finally { $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $report.input=Manifest $source
    $sevenVersion=Tool $seven @('i','-sccUTF-8') '7zip-version'
    if ($sevenVersion.stdout -notmatch '(?m)^7-Zip 26\.04(?:\s|\s*\()') { throw '7-Zip version output mismatch.' }
    $report.khc_version=(Tool $khc @('--version') 'khc-version').stdout.Trim()
    if ($report.khc_version -cnotmatch '^(?:unlhare|unlhare-cli) 1\.0\.4$') { throw 'Expected pinned KHC CLI version 1.0.4.' }
    Save-Report
    $order=if ($Round%2 -eq 0) { @('portfolio-trial','7zip') } else { @('7zip','portfolio-trial') }
    $label="$Round-$Strategy"; $extension=if ($Strategy -ceq '7zip') { '7z' } else { 'khc' }
    $archive=Output-Path (Join-Path $archives "$label.$extension"); $restore=Join-Path $work "restored-$label"
    New-Directory $restore
    if (Test-Path -LiteralPath $archive) { throw 'Archive already exists.' }
    $sample=[ordered]@{ strategy=$Strategy; round=$Round; warmup=($Round -eq 0); position=[Array]::IndexOf($order,$Strategy)
        archive=$archive; archive_bytes=$null; archive_sha256=$null; format=$null; create=$null; extract=$null; restore=$restore; restored=$null; result='failed' }
    $samples.Add($sample)
    $sample.create=if ($Strategy -ceq '7zip') {
        Tool $seven (@('a','-t7z','-mx=9','-m0=lzma2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off','-sccUTF-8','-scsUTF-8','-bd','-bb0',$archive,'--')+$sevenInputNames) "$label-create" -Timed
    } else { Tool $khc @('khc-create',$archive,'--source',$source,'--strategy','portfolio-trial') "$label-create" -Timed }
    $sample.archive_bytes=[long](Get-Item -LiteralPath (Plain $archive)).Length
    if ($sample.archive_bytes -le 0 -or $sample.archive_bytes -gt ($expectedTotalBytes+64KB)) { throw 'Archive outside fixed input + 64 KiB ceiling.' }
    $sample.extract=if ($Strategy -ceq '7zip') { Tool $seven @('x',$archive,"-o$restore",'-mmt=4','-y','-sccUTF-8','-bd','-bb0') "$label-extract" -Timed }
        else { Tool $khc @('khc-extract',$archive,'--output',$restore) "$label-extract" -Timed }
    # Hash/format checks follow timed extraction so validation reads cannot warm the archive first.
    $sample.archive_sha256=Hash $archive
    $sample.format=if ($Strategy -ceq '7zip') { Seven-Format $archive $label } else { Khc-Format $archive }
    $sample.restored=Manifest $restore; $sample.result='passed'
    Check-Storage; Save-Report
    foreach ($pin in $pins) { if ((Hash $pin.path) -cne $pin.sha) { throw 'Pinned source/tool changed during screen.' } }
    if((Source-Manifest $sourceRoot) -cne $sourceManifestPin -or (Hash $PSCommandPath) -cne $workerSha){throw 'Pinned source or screen script changed during screen.'}
    if ($null -ne $profileCampaign) { $null=& $campaignValidator -CampaignManifestSha256 $CampaignManifestSha256 }
    $null=Manifest $source
    if ($samples.Count -ne 1 -or $samples[0].round -ne $Round -or $samples[0].strategy -cne $Strategy -or $samples[0].result -cne 'passed') { throw 'Exactly the selected round/strategy sample must pass.' }
    $report.status='completed'
} catch {
    $failure=if ($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) { [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('NICT screen failed; content details omitted.'),'NictScreenFailed',[Management.Automation.ErrorCategory]::InvalidOperation,$null) } else { $_ }
    $report.status='failed'; $report.error=$failure.Exception.Message
    $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
    $report.candidate_screen_passed=$null; $report.candidate_decision=$null
} finally {
    try {
        if ($workRootReady -and [IO.Directory]::Exists($work)) {
            try {
                Check-Storage
                $report.inventory=@(Get-ChildItem -LiteralPath $work -Recurse -Force | ForEach-Object {
                    $null=Output-Path $_.FullName
                    [pscustomobject]@{ path=[IO.Path]::GetRelativePath($work,$_.FullName); directory=$_.PSIsContainer; bytes=if ($_.PSIsContainer) {0L} else {$_.Length} }
                })
            } catch {
                $finalError=New-FinalErrorDetails -Phase 'Final inventory' -Caught $_
                if ($null -eq $failure) { $failure=$finalError.Record; $report.error=$finalError.Message }
                else { $report.error="$($report.error); $($finalError.Message)" }
                $report.status='failed'
                $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
                $report.candidate_screen_passed=$null; $report.candidate_decision=$null
            }
            $reportSaved=$false
            try { Save-Report; $reportSaved=$true }
            catch {
                $finalError=New-FinalErrorDetails -Phase 'Final report save' -Caught $_
                if ($null -eq $failure) { $failure=$finalError.Record; $report.error=$finalError.Message }
                else { $report.error="$($report.error); $($finalError.Message)" }
                $report.status='failed'
                $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
                $report.candidate_screen_passed=$null; $report.candidate_decision=$null
            }
            if ($reportSaved) {
                try { Check-Storage }
                catch {
                    $finalError=New-FinalErrorDetails -Phase 'Final storage validation' -Caught $_
                    if ($null -eq $failure) { $failure=$finalError.Record; $report.error=$finalError.Message }
                    else { $report.error="$($report.error); $($finalError.Message)" }
                    $report.status='failed'
                    $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
                    $report.candidate_screen_passed=$null; $report.candidate_decision=$null
                    try { Save-Report }
                    catch {
                        $finalError=New-FinalErrorDetails -Phase 'Final failure report save' -Caught $_
                        $report.error += "; $($finalError.Message)"
                        if ($null -eq $failure) { $failure=$finalError.Record }
                    }
                }
            }
            Write-Output (ConvertTo-Json -InputObject ([ordered]@{ status=$report.status; candidate_decision=$report.candidate_decision; report_path=if(Test-Path -LiteralPath $reportPath){$reportPath}else{$null}; error=$report.error }) -Compress)
        } else {
            if ($null -eq $failure) {
                $failure='Registered work root was unavailable; no report was saved.'
                $report.status='failed'; $report.error=$failure
                $report.candidate_size_passed=$null; $report.candidate_time_passed=$null
                $report.candidate_screen_passed=$null; $report.candidate_decision=$null
            }
            Write-Output (ConvertTo-Json -InputObject ([ordered]@{ status='failed'; candidate_decision=$null; report_path=$null; error=$report.error }) -Compress)
        }
    } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
}
if ($null -ne $failure) { throw $failure }
