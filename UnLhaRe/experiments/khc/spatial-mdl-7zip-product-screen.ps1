#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$KhcExecutableSha256,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$SevenZipSha256,
    [Parameter(Mandatory)][string]$InputRecoveryZip
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if ([long]$record.max_bytes -ne 16MB -or [int]$record.max_entries -ne 96) {
    throw 'This screen requires exactly 16 MiB / 96 entries.'
}

function Plain([string]$Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Absolute path required: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
        if ((Test-Path -LiteralPath $part) -and
            ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point: $part"
        }
    }
    return $full
}
function Hash([string]$Path) { return (Get-FileHash -LiteralPath (Plain $Path) -Algorithm SHA256).Hash.ToLowerInvariant() }
function New-Directory([string]$Path) {
    $full = Plain $Path
    if (-not $full.StartsWith($work + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $full -cne $work) {
        throw 'Output escaped registered work directory.'
    }
    if (Test-Path -LiteralPath $full) { throw "Output already exists: $full" }
    $null = New-Item -ItemType Directory -Path $full
}
function Assert-QuietCpu([string]$Label) {
    $sample = [ordered]@{ label=$Label; utc=[DateTime]::UtcNow.ToString('o'); percent=$null; limit_percent=15; error=$null }
    $quiet.Add($sample)
    try {
        $cpu = @(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
        if ($cpu.Count -ne 1 -or $null -eq $cpu[0].PercentProcessorTime) { throw 'CPU metric unavailable.' }
        $percent = [double]$cpu[0].PercentProcessorTime
        $sample.percent = $percent
        if ([double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or $percent -lt 0 -or $percent -gt 15) {
            throw "CPU gate exceeded before $Label : $percent percent. No retry."
        }
    } catch { $sample.error=$_.Exception.Message; throw }
}

# パイプはメモリ内で上限付き回収し、timeout後も子プロセスを残さない。
function Tool([string]$Executable, [string[]]$Arguments, [string]$Label, [switch]$Timed) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory=$source; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.Environment['TEMP']=$work; $info.Environment['TMP']=$work
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info
    $timer=[Diagnostics.Stopwatch]::new(); $captures=@(); $started=$false
    $command=[ordered]@{ label=$Label; executable=$Executable; argv=$Arguments; working_directory=$source; timed=[bool]$Timed
        exit_code=$null; wall_ms=$null; cpu_ms=$null; peak_working_set_bytes=0L; peak_paged_memory_bytes=0L; stdout=''; stderr=''; error=$null }
    $commands.Add($command)
    try {
        if ($Timed) { Assert-QuietCpu $Label }
        $timer.Start()
        if (-not $p.Start()) { throw "Unable to start: $Label" }; $started=$true
        foreach ($pipe in @($p.StandardOutput.BaseStream, $p.StandardError.BaseStream)) {
            $buffer=[byte[]]::new(1024)
            $captures+=@{ pipe=$pipe; buffer=$buffer; data=[IO.MemoryStream]::new(); done=$false; pending=$pipe.ReadAsync($buffer,0,$buffer.Length) }
        }
        while ($true) {
            $p.Refresh()
            $command.peak_working_set_bytes=[Math]::Max($command.peak_working_set_bytes,$p.PeakWorkingSet64)
            $command.peak_paged_memory_bytes=[Math]::Max($command.peak_paged_memory_bytes,$p.PeakPagedMemorySize64)
            foreach ($capture in $captures) {
                if ($capture.done -or -not $capture.pending.IsCompleted) { continue }
                $count=$capture.pending.GetAwaiter().GetResult()
                if ($count -eq 0) { $capture.done=$true; continue }
                $limit=if ($Label -ceq '7zip-version') { 32KB } else { 4KB }
                if ($capture.data.Length+$count -gt $limit) { throw "Stream limit exceeded: $Label" }
                $capture.data.Write($capture.buffer,0,$count)
                $capture.pending=$capture.pipe.ReadAsync($capture.buffer,0,$capture.buffer.Length)
            }
            if ($timer.Elapsed.TotalSeconds -gt 30) { throw "30-second command timeout: $Label" }
            if ($p.HasExited -and @($captures | Where-Object { -not $_.done }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 1
        }
        $timer.Stop()
        $command.exit_code=$p.ExitCode; $command.cpu_ms=$p.TotalProcessorTime.TotalMilliseconds
        if ($command.exit_code -ne 0) { throw "Command failed ($($command.exit_code)): $Label" }
        if ($Timed -and ($command.peak_working_set_bytes -le 0 -or $command.peak_paged_memory_bytes -le 0)) {
            throw "Missing memory measurements: $Label"
        }
        if ($Timed -and $command.peak_working_set_bytes -gt 160MB) {
            throw "Peak working set exceeds 160 MiB: $Label ($($command.peak_working_set_bytes) bytes)"
        }
    } catch { $command.error=$_.Exception.Message; throw }
    finally {
        $timer.Stop(); $command.wall_ms=$timer.Elapsed.TotalMilliseconds
        try {
            if ($started -and -not $p.HasExited) { $p.Kill($true); if (-not $p.WaitForExit(5000)) { throw "Process did not stop: $Label" } }
            if ($started -and $p.HasExited) { $command.exit_code=$p.ExitCode; $command.cpu_ms=$p.TotalProcessorTime.TotalMilliseconds }
            if ($captures.Count -eq 2) {
                $command.stdout=[Text.Encoding]::UTF8.GetString($captures[0].data.ToArray())
                $command.stderr=[Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())
            }
        } finally { foreach ($capture in $captures) { $capture.data.Dispose() }; $p.Dispose() }
    }
    return [pscustomobject]$command
}
function Verify-SevenFormat([string]$Archive, [string]$Label) {
    $listing=Tool $seven @('l','-slt','-sccUTF-8',$Archive) "$Label-list"
    $methods=@([regex]::Matches($listing.stdout,'(?m)^Method = (.+)\r?$') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if ($methods.Count -lt 2) { throw 'Missing 7z archive/file method listing.' }
    $dictionaries=@(foreach ($method in $methods) {
        if ($method -cnotmatch '^LZMA2:(\d+)([bkm]?)$') { throw "Unexpected actual method: $method" }
        $n=[long]$Matches[1]
        $bytes=switch ($Matches[2]) { 'b' {$n} 'k' {$n*1KB} 'm' {$n*1MB} default { if ($n -gt 26) { throw 'Dictionary exponent too large.' }; [long][Math]::Pow(2,$n) } }
        if ($bytes -le 0 -or $bytes -gt 64MB) { throw 'Actual dictionary exceeds requested 64 MiB.' }
        $bytes
    })
    # 7-Zipは小さい入力に合わせて実効dictionaryを縮小するため、実値も保存する。
    if ($listing.stdout -cnotmatch '(?m)^Path = ptt5\r?$' -or
        $listing.stdout -notmatch '(?m)^Size = 513216\r?$' -or
        $listing.stdout -notmatch '(?m)^Modified = \S[^\r\n]*') { throw '7z member, length, or mtime listing mismatch.' }
    return [pscustomobject]@{ actual_methods=$methods; effective_dictionary_bytes=$dictionaries; listing_command=$listing.label }
}
function Stats([double[]]$Values) {
    $sorted=@($Values | Sort-Object)
    if ($sorted.Count -ne 9) { throw 'Expected nine measured samples.' }
    return [pscustomobject]@{ median=$sorted[4]; min=$sorted[0]; max=$sorted[-1] }
}
function Inventory {
    return @(Get-ChildItem -LiteralPath $work -Recurse -Force | ForEach-Object {
        $null=Plain $_.FullName
        if ($_.PSIsContainer) { [pscustomobject]@{ path=[IO.Path]::GetRelativePath($work,$_.FullName); kind='directory' } }
        else { [pscustomobject]@{ path=[IO.Path]::GetRelativePath($work,$_.FullName); kind='file'; bytes=$_.Length; sha256=(Hash $_.FullName) } }
    })
}
function Write-Report {
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $report -Depth 30))
    if ($bytes.Length -gt 512KB) { throw 'Report exceeds 512 KiB.' }
    # 自身のファイル1件とwork rootを含め、書込前に最終サイズを受付枠へ照合する。
    $fileBytes=0L
    foreach ($entry in $report.artifacts) { if ($entry.kind -ceq 'file') { $fileBytes += $entry.bytes } }
    if ($fileBytes+$bytes.Length -gt 16MB -or $report.artifacts.Count+2 -gt 96) {
        throw 'Final inventory including report exceeds registered storage limits.'
    }
    $null=Plain $reportPath
    $stream=[IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

$work=Plain $WorkDirectory
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory must be unused.' }
$khc=Plain $KhcExecutable; $seven=Plain $SevenZipPath; $recovery=Plain $InputRecoveryZip
$expectedZip=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip')
if ($recovery -cne $expectedZip) { throw 'Use the preregistered recovery ZIP.' }
$source=Join-Path $work 'source'; $archives=Join-Path $work 'archives'
$reportPath=Join-Path $work 'spatial-mdl-7zip-product-screen.json'
$commands=[Collections.Generic.List[object]]::new(); $quiet=[Collections.Generic.List[object]]::new()
$samples=[Collections.Generic.List[object]]::new()
$report=[ordered]@{
    schema=1; status='running'; error=$null
    scope='Descriptive development screen on pinned Canterbury ptt5 only; not heldout; no general performance or product superiority claim.'
    design=[ordered]@{ warmup_per_strategy=1; measured_rounds=9; order='KHC first for even rounds (including warmup 0); 7zip first for odd rounds'
        strategy='spatial-mdl-trial'; archive_revision=9; selection='Strictly shorter complete KCS1 frame vs default MDL frame; ties select MDL'
        seven_zip_argv_template=@('a','-t7z','-m0=LZMA2','-mx=9','-md=64m','-mmt=1','-mtm=on','<archive>','--','.\ptt5')
        seven_zip_container='7z'; seven_zip_method='LZMA2'; seven_zip_level=9; seven_zip_dictionary_bytes=64MB; seven_zip_threads=1; mtime=$true
        quiet_cpu_source='Win32_PerfFormattedData_PerfOS_Processor/_Total'; quiet_cpu_max_percent=15; quiet_cpu_queries_per_timed_command=1; retry=$false
        command_timeout_seconds=30; outer_timeout_seconds=300; max_run_bytes=16MB; max_entries=96; archive_limit_exclusive_bytes=64KB
        report_limit_bytes=512KB; timed_command_peak_working_set_limit_bytes=160MB; candidate_max_archive_ratio=0.95
        wall='Individual create/extract process launch, I/O, pipe drain; CPU gate and output SHA checks excluded'; extraction='Full extraction to fresh tree for every archive' }
    host=[ordered]@{ machine=[Environment]::MachineName; os=[Environment]::OSVersion.VersionString; architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); powershell=$PSVersionTable.PSVersion.ToString(); logical_processors=[Environment]::ProcessorCount }
    input=[ordered]@{ zip=$recovery; zip_sha256='882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'; member='input/ptt5'; bytes=513216; sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'; mtime_utc=$null }
    tools=@(); seven_zip_version_output=$null; cpu_samples=$quiet; commands=$commands; samples=$samples; paired_rounds=@(); summary=@(); artifacts=@()
    artifact_inventory_scope='All work entries except this report; report is CreateNew, bounded to 512 KiB, and included in final byte/entry budget.'
    report_path=$reportPath; determinism_verified=$false; candidate_screen_passed=$null; candidate_decision=$null; candidate_comparison=$null
}
$failure=$null; $oldTemp=$env:TEMP; $oldTmp=$env:TMP
New-Directory $work
try {
    $env:TEMP=$work; $env:TMP=$work
    foreach ($pin in @(@($khc,$KhcExecutableSha256),@($seven,$SevenZipSha256),@($recovery,$report.input.zip_sha256))) {
        if (-not (Test-Path -LiteralPath $pin[0] -PathType Leaf) -or (Hash $pin[0]) -cne $pin[1]) { throw "Pinned file SHA mismatch: $($pin[0])" }
    }
    $report.tools=@(foreach ($tool in @($khc,$seven)) { [pscustomobject]@{ path=$tool; sha256=(Hash $tool); file_version=(Get-Item -LiteralPath $tool).VersionInfo.FileVersion } })
    New-Directory $source; New-Directory $archives
    $zip=[IO.Compression.ZipFile]::OpenRead($recovery)
    $inputPath=Join-Path $source 'ptt5'
    try {
        $members=@($zip.Entries | Where-Object FullName -CEQ $report.input.member)
        if ($members.Count -ne 1 -or $members[0].Length -ne $report.input.bytes) { throw 'Pinned member/length mismatch.' }
        $inputStream=$members[0].Open(); $output=$null
        try {
            $output=[IO.File]::Open($inputPath,[IO.FileMode]::CreateNew)
            $inputStream.CopyTo($output); $output.Flush($true)
        } finally { if ($null -ne $output) { $output.Dispose() }; $inputStream.Dispose() }
        [IO.File]::SetLastWriteTimeUtc($inputPath,$members[0].LastWriteTime.UtcDateTime)
    } finally { $zip.Dispose() }
    if ((Get-Item -LiteralPath $inputPath).Length -ne $report.input.bytes -or (Hash $inputPath) -cne $report.input.sha256) { throw 'Pinned ptt5 mismatch.' }
    $report.input.mtime_utc=(Get-Item -LiteralPath $inputPath).LastWriteTimeUtc.ToString('o')
    $version=Tool $seven @('i','-sccUTF-8') '7zip-version'
    $report.seven_zip_version_output=$version.stdout
    if ($version.stdout -cnotmatch '(?m)^7-Zip 26\.04 \(x64\)(?:\s|:)') { throw 'Expected exactly 7-Zip 26.04 x64 runtime.' }
    foreach ($round in 0..9) {
        $order=if ($round % 2 -eq 0) { @('spatial-mdl-trial','7zip') } else { @('7zip','spatial-mdl-trial') }
        foreach ($strategy in $order) {
            $label="$round-$strategy"; $extension=if ($strategy -ceq '7zip') { '7z' } else { 'khc' }
            $archive=Join-Path $archives "$label.$extension"; $extract=Join-Path $work "restored-$label"
            New-Directory $extract
            $create=if ($strategy -ceq '7zip') {
                Tool $seven @('a','-t7z','-m0=LZMA2','-mx=9','-md=64m','-mmt=1','-mtm=on',$archive,'--','.\ptt5') "$label-create" -Timed
            } else { Tool $khc @('khc-create',$archive,'--source',$source,'--strategy','spatial-mdl-trial') "$label-create" -Timed }
            $bytes=(Get-Item -LiteralPath (Plain $archive)).Length
            if ($bytes -le 0 -or $bytes -ge 64KB) { throw 'Archive must be nonempty and strictly below 64 KiB.' }
            $archiveHash=Hash $archive
            $format=if ($strategy -ceq '7zip') { Verify-SevenFormat $archive $label } else {
                $header=[IO.File]::ReadAllBytes($archive)
                if ($header.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($header,0,8) -cne "KHC1ARC`0" -or $header[8] -ne 9) { throw 'Expected KHC archive revision 9.' }
                [pscustomobject]@{ archive_revision=9 }
            }
            $decode=if ($strategy -ceq '7zip') { Tool $seven @('x',$archive,"-o$extract",'-y') "$label-extract" -Timed }
                else { Tool $khc @('khc-extract',$archive,'--output',$extract) "$label-extract" -Timed }
            $restored=@(Get-ChildItem -LiteralPath $extract -Recurse -Force)
            if ($restored.Count -ne 1 -or $restored[0].PSIsContainer -or $restored[0].Name -cne 'ptt5' -or $restored[0].Length -ne $report.input.bytes) { throw "Extract layout/length mismatch: $label" }
            $restoredHash=Hash $restored[0].FullName
            if ($restoredHash -cne $report.input.sha256) { throw "Extract SHA mismatch: $label" }
            $samples.Add([pscustomobject]@{ strategy=$strategy; round=$round; warmup=($round -eq 0); position=[Array]::IndexOf($order,$strategy)
                archive=$archive; archive_bytes=$bytes; archive_sha256=$archiveHash; format=$format; create=$create; extract=$decode
                restored_path=$restored[0].FullName; restored_bytes=$restored[0].Length; restored_sha256=$restoredHash; restored_verified=$true })
            Assert-KhcStorageContext -WorkDirectory $work
        }
    }
    foreach ($strategy in @('spatial-mdl-trial','7zip')) {
        $all=@($samples | Where-Object strategy -CEQ $strategy)
        if ($all.Count -ne 10 -or @($all.archive_sha256 | Select-Object -Unique).Count -ne 1 -or @($all.archive_bytes | Select-Object -Unique).Count -ne 1) { throw "Nondeterministic archives: $strategy" }
        $measured=@($all | Where-Object { -not $_.warmup })
        $summary=[ordered]@{ strategy=$strategy; measured_samples=9; archive_bytes=$all[0].archive_bytes; archive_sha256=$all[0].archive_sha256 }
        foreach ($phase in @('create','extract')) {
            foreach ($metric in @('wall_ms','cpu_ms','peak_working_set_bytes','peak_paged_memory_bytes')) {
                $summary["${phase}_${metric}"]=Stats @($measured | ForEach-Object { $_.$phase.$metric })
            }
        }
        $report.summary+=@([pscustomobject]$summary)
    }
    foreach ($round in 1..9) {
        $a=@($samples | Where-Object { $_.round -eq $round -and $_.strategy -ceq 'spatial-mdl-trial' })[0]
        $b=@($samples | Where-Object { $_.round -eq $round -and $_.strategy -ceq '7zip' })[0]
        $report.paired_rounds+=@([pscustomobject]@{ round=$round; first_strategy=if ($round%2 -eq 0) {'spatial-mdl-trial'} else {'7zip'}
            archive_byte_delta_khc_minus_7zip=$a.archive_bytes-$b.archive_bytes; create_wall_delta_ms_khc_minus_7zip=$a.create.wall_ms-$b.create.wall_ms
            extract_wall_delta_ms_khc_minus_7zip=$a.extract.wall_ms-$b.extract.wall_ms })
    }
    foreach ($tool in $report.tools) { if ((Hash $tool.path) -cne $tool.sha256) { throw 'Tool changed during screen.' } }
    if ((Hash $inputPath) -cne $report.input.sha256 -or (Hash $recovery) -cne $report.input.zip_sha256) { throw 'Input changed during screen.' }
    $report.determinism_verified=$true
    $candidateBytes=[long](@($samples | Where-Object strategy -CEQ 'spatial-mdl-trial')[0].archive_bytes)
    $baselineBytes=[long](@($samples | Where-Object strategy -CEQ '7zip')[0].archive_bytes)
    # 整数比較で5%境界を判定し、表示用の比率丸めから独立させる。
    $report.candidate_screen_passed=($candidateBytes*100L -le $baselineBytes*95L)
    $report.candidate_decision=if ($report.candidate_screen_passed) { 'pass' } else { 'no-go' }
    $report.candidate_comparison=[ordered]@{
        khc_archive_bytes=$candidateBytes; seven_zip_archive_bytes=$baselineBytes
        byte_savings=$baselineBytes-$candidateBytes; archive_ratio_khc_to_7zip=[double]$candidateBytes/$baselineBytes
        savings_fraction=1.0-([double]$candidateBytes/$baselineBytes); required_savings_fraction=0.05
        exact_gate='khc_archive_bytes * 100 <= seven_zip_archive_bytes * 95'
    }
    Assert-KhcStorageContext -WorkDirectory $work
    $report.artifacts=Inventory
    $report.status='completed'
} catch {
    $failure=$_; $report.status='failed'; $report.error=$_.Exception.Message
    $report.candidate_screen_passed=$null; $report.candidate_decision=$null
}
finally {
    try {
        if ($report.status -ne 'completed') { $report.artifacts=Inventory }
        Write-Report
        Write-Output (ConvertTo-Json -InputObject ([ordered]@{ status=$report.status; candidate_decision=$report.candidate_decision; candidate_screen_passed=$report.candidate_screen_passed; report_path=$reportPath; samples=$samples.Count; error=$report.error }) -Compress)
    } finally { $env:TEMP=$oldTemp; $env:TMP=$oldTmp }
}
if ($null -ne $failure) { throw $failure }
