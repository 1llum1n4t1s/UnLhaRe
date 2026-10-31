#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [string]$InputRecoveryZip='C:\Users\IMT\AppData\Local\Codex\TaskArtifacts\UnLhaRe\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if($record.max_bytes -ne 5MB -or $record.max_entries -ne 64){throw 'This fixed screen requires exactly MaxRunMiB 5 / MaxEntries 64.'}

function Plain([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    for($part=$full;$part;$part=[IO.Path]::GetDirectoryName($part)) {
        if((Test-Path -LiteralPath $part) -and ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse point: $part"}
    }
    return $full
}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function New-Directory([string]$Path) {
    $null=Plain $Path
    if(Test-Path -LiteralPath $Path){throw "Output already exists: $Path"}
    $null=New-Item -ItemType Directory -Path $Path
}
function Write-Report {
    $json=ConvertTo-Json -InputObject $report -Depth 24
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
    if($bytes.Length -gt 512KB){throw 'Report exceeded its fixed 512 KiB reservation.'}
    $stream=[IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

# CPU取得の失敗や閾値超過では待機再試行せず、次のtrial前に停止する。
function Assert-QuietCpu([string]$Label) {
    $cpu=@(Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
    if($cpu.Count -ne 1 -or $null -eq $cpu[0].PercentProcessorTime){throw 'Unable to verify total CPU usage.'}
    $percent=[double]$cpu[0].PercentProcessorTime
    $quiet.Add([pscustomobject]@{label=$Label;utc=[DateTime]::UtcNow.ToString('o');percent=$percent;limit_percent=15;source='Win32_PerfFormattedData_PerfOS_Processor/_Total'})
    if([double]::IsNaN($percent) -or $percent -lt 0 -or $percent -gt 15){throw "Quiet CPU requirement failed before $Label : $percent percent"}
}

# wallは起動・I/O・pipe回収を含む。OS高水位が採れなければ測定成功にしない。
function Tool([string]$Executable,[string[]]$Arguments,[string]$Label,[switch]$Timed) {
    $info=[Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory=$source;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['TEMP']=$work;$info.Environment['TMP']=$work
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info
    $captures=@();$started=$false;$logged=$false;$timer=[Diagnostics.Stopwatch]::StartNew()
    $captureLimit=if($Label -ceq '7zip-runtime-version'){32KB}else{4KB}
    $peaks=[long[]]::new(2)
    try {
        if(-not $p.Start()){throw "Process start failed: $Label"};$started=$true
        foreach($pipe in @($p.StandardOutput.BaseStream,$p.StandardError.BaseStream)) {
            $buffer=[byte[]]::new(1024)
            $captures+=@{pipe=$pipe;buffer=$buffer;data=[IO.MemoryStream]::new();done=$false;pending=$pipe.ReadAsync($buffer,0,$buffer.Length)}
        }
        while($true) {
            try{$p.Refresh();$peaks[0]=[Math]::Max($peaks[0],$p.PeakWorkingSet64);$peaks[1]=[Math]::Max($peaks[1],$p.PeakPagedMemorySize64)}catch{} # 取得済みの実測だけを保持する。
            foreach($c in $captures) {
                if($c.done -or -not $c.pending.IsCompleted){continue}
                $count=$c.pending.GetAwaiter().GetResult()
                if($count -eq 0){$c.done=$true;continue}
                if($c.data.Length+$count -gt $captureLimit){throw "Process output exceeded its $captureLimit byte limit: $Label"}
                $c.data.Write($c.buffer,0,$count);$c.pending=$c.pipe.ReadAsync($c.buffer,0,$c.buffer.Length)
            }
            if($timer.Elapsed.TotalSeconds -gt 30){throw "Process timeout: $Label"}
            if($p.HasExited -and @($captures|Where-Object {-not $_.done}).Count -eq 0){break}
            Start-Sleep -Milliseconds 1
        }
        $timer.Stop()
        $result=[pscustomobject]@{
            label=$Label;executable=$Executable;argv=$Arguments;exit_code=$p.ExitCode;timed=[bool]$Timed
            wall_ms=$timer.Elapsed.TotalMilliseconds;cpu_ms=$p.TotalProcessorTime.TotalMilliseconds
            peak_working_set_bytes=$peaks[0];peak_paged_memory_bytes=$peaks[1]
            stdout=[Text.Encoding]::UTF8.GetString($captures[0].data.ToArray());stderr=[Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())
        }
        $commands.Add($result);$logged=$true
        if($result.exit_code -ne 0){throw "Nonzero exit $($result.exit_code): $Label"}
        if($Timed -and ($peaks[0] -le 0 -or $peaks[1] -le 0)){throw "Missing nonzero OS memory counters: $Label"}
        return $result
    } catch {
        if(-not $logged) {
            $stdout=if($captures.Count -gt 0){[Text.Encoding]::UTF8.GetString($captures[0].data.ToArray())}else{''}
            $stderr=if($captures.Count -gt 1){[Text.Encoding]::UTF8.GetString($captures[1].data.ToArray())}else{''}
            $exitCode=if($started -and $p.HasExited){$p.ExitCode}else{$null}
            $commands.Add([pscustomobject]@{label=$Label;executable=$Executable;argv=$Arguments;exit_code=$exitCode;timed=[bool]$Timed;wall_ms=$timer.Elapsed.TotalMilliseconds;peak_working_set_bytes=$peaks[0];peak_paged_memory_bytes=$peaks[1];stdout=$stdout;stderr=$stderr;error=$_.Exception.Message})
        }
        throw
    } finally {
        if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(5000)){throw "Process did not stop: $Label"}}
        foreach($c in $captures){$c.data.Dispose()}
        $timer.Stop();$p.Dispose()
    }
}

# 固定1entryのmanifest境界からframeを読み、payload中のmagic検索はしない。
function Khc-Format([string]$Archive,[string]$Strategy) {
    $bytes=[IO.File]::ReadAllBytes($Archive)
    if($bytes.Length -lt 40 -or [Text.Encoding]::ASCII.GetString($bytes,0,8) -cne "KHC1ARC`0"){throw 'KHC header mismatch.'}
    $expectedRevision=if($Strategy -ceq 'spatial-bits-trial'){7}else{6}
    $expectedMagic=if($expectedRevision -eq 7){"KCS1BLK`0"}else{"KRS2BLK`0"}
    $at=32+[long][BitConverter]::ToUInt32($bytes,20)
    if($at+4 -gt $bytes.Length){throw 'Truncated frame prefix.'}
    $length=[long][BitConverter]::ToUInt32($bytes,[int]$at);$at+=4
    if($length -lt 8 -or $at+$length+12 -ne $bytes.Length){throw 'Expected exactly one complete KHC frame and CRC/trailer.'}
    $magic=[Text.Encoding]::ASCII.GetString($bytes,[int]$at,8)
    if($bytes[8] -ne $expectedRevision -or $magic -cne $expectedMagic -or [Text.Encoding]::ASCII.GetString($bytes,[int]($at+$length+4),8) -cne "KHC1END`0"){throw 'Unexpected KHC revision/frame family/trailer.'}
    return [pscustomobject]@{archive_revision=[int]$bytes[8];frame_magic=$magic;frame_bytes=$length}
}
function Seven-Format([string]$Archive,[string]$Label) {
    $listing=Tool $seven @('l','-slt','-sccUTF-8',$Archive) "$Label-list"
    $methods=@([regex]::Matches($listing.stdout,'(?m)^Method = (.+)\r?$')|ForEach-Object {$_.Groups[1].Value.Trim()})
    if($methods.Count -eq 0){throw '7-Zip omitted actual method.'}
    $dictionaries=@(foreach($method in $methods) {
        if($method -cnotmatch '^LZMA2:(\d+)([bkm]?)$'){throw "Unexpected 7-Zip actual method: $method"}
        $n=[long]$Matches[1]
        $size=switch($Matches[2]){'b'{$n}'k'{$n*1KB}'m'{$n*1MB}default{if($n -gt 30){throw 'Invalid dictionary exponent.'};[long][Math]::Pow(2,$n)}}
        if($size -le 0 -or $size -gt 64MB){throw 'Invalid effective dictionary size.'}
        [pscustomobject]@{token=$method;bytes=$size}
    })
    return [pscustomobject]@{actual_methods=$methods;effective_dictionaries=$dictionaries;requested_dictionary_bytes=64MB;container='7z';threads=1;solid=$true;level=9;metadata_times=$false}
}

$work=Plain $WorkDirectory
if(Test-Path -LiteralPath $work){throw 'WorkDirectory must be unused.'}
$khc=Plain $KhcExecutable;$seven=Plain $SevenZipPath;$recovery=Plain $InputRecoveryZip
foreach($path in @($khc,$seven,$recovery)){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing input/tool: $path"}}
$source=Join-Path $work 'source';$archives=Join-Path $work 'archives';$reportPath=Join-Path $work 'spatial-bits-product-screen.json'
$commands=[Collections.Generic.List[object]]::new();$samples=[Collections.Generic.List[object]]::new();$quiet=[Collections.Generic.List[object]]::new()
$strategies=@('spatial-bits-trial','record-fast-trial','7zip')
$report=[ordered]@{
    schema=1;status='running';error=$null;scope='fixed development ptt5 screen; not holdout; no general superiority claim'
    design=[ordered]@{warmup_per_method=1;measured_rounds=9;order='rotating by round; reversed on alternate rounds';quiet_cpu_max_percent=15;decode='full verify/decode+CRC; not filesystem extract throughput';wall='process launch + I/O + pipe drain';outer_timeout_seconds=300;max_run_bytes=5MB;max_entries=64;archive_limit_bytes=64KB;report_limit_bytes=512KB}
    input=[ordered]@{zip=$recovery;zip_sha256='882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75';member='input/ptt5';basename='ptt5';bytes=513216;sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650';holdout=$false}
    tools=@();cpu_samples=$quiet;commands=$commands;samples=$samples;roundtrips=@();summary=@();determinism_verified=$false
}
$failure=$null
New-Directory $work
try {
    $report.tools=@(foreach($tool in @($khc,$seven)){[pscustomobject]@{path=$tool;sha256=(Hash $tool);file_version=(Get-Item -LiteralPath $tool).VersionInfo.FileVersion}})
    if((Hash $recovery) -cne $report.input.zip_sha256){throw 'Pinned recovery ZIP hash mismatch.'}
    New-Directory $source;New-Directory $archives
    $zip=[IO.Compression.ZipFile]::OpenRead($recovery)
    try {
        $members=@($zip.Entries|Where-Object FullName -CEQ 'input/ptt5')
        if($members.Count -ne 1 -or $members[0].Length -ne 513216){throw 'Pinned ZIP member/size mismatch.'}
        $inputStream=$members[0].Open();$output=[IO.File]::Open((Join-Path $source 'ptt5'),[IO.FileMode]::CreateNew)
        try{$inputStream.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$inputStream.Dispose()}
    } finally {$zip.Dispose()}
    $inputPath=Join-Path $source 'ptt5'
    if((Hash $inputPath) -cne $report.input.sha256){throw 'Pinned ptt5 hash mismatch.'}
    $version=Tool $seven @('i','-sccUTF-8') '7zip-runtime-version'
    if($version.stdout -notmatch '(?m)^7-Zip[^\r\n]*26\.04(?:\s|\()'){throw '7-Zip runtime must be 26.04.'}
    $report['seven_zip_version_output']=$version.stdout
    foreach($round in 0..9) {
        $order=@(0..2|ForEach-Object {$strategies[($_+$round)%3]})
        if($round%2 -eq 0 -and $round -gt 0){[Array]::Reverse($order)}
        foreach($position in 0..2) {
            $strategy=$order[$position];$label="$round-$strategy"
            # warmupも同じCPU条件で起動し、反復のencode前とdecode前を記録する。
            Assert-QuietCpu "$label-create"
            $extension=if($strategy -ceq '7zip'){'7z'}else{'khc'}
            $archive=Join-Path $archives "$label.$extension"
            if($strategy -ceq '7zip') {
                $createArgs=@('a','-t7z','-mx=9','-m0=lzma2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off','-spd','-sccUTF-8',$archive,'--','.\ptt5')
                $encode=Tool $seven $createArgs "$label-create" -Timed
            } else {$encode=Tool $khc @('khc-create',$archive,'--source',$source,'--strategy',$strategy) "$label-create" -Timed}
            $size=(Get-Item -LiteralPath $archive).Length
            if($size -gt 64KB){throw 'Archive exceeded its fixed 64 KiB reservation.'}
            $format=if($strategy -ceq '7zip'){Seven-Format $archive $label}else{Khc-Format $archive $strategy}
            Assert-QuietCpu "$label-verify-decode"
            $decode=if($strategy -ceq '7zip'){Tool $seven @('t','-sccUTF-8',$archive) "$label-verify-decode" -Timed}else{Tool $khc @('khc-test',$archive) "$label-verify-decode" -Timed}
            $samples.Add([pscustomobject]@{strategy=$strategy;round=$round;warmup=($round -eq 0);order_position=($position+1);archive=$archive;archive_bytes=$size;archive_sha256=(Hash $archive);format=$format;create=$encode;verify_decode=$decode})
            Assert-KhcStorageContext -WorkDirectory $work
        }
    }
    foreach($strategy in $strategies) {
        $all=@($samples|Where-Object strategy -CEQ $strategy)
        if(@($all.archive_sha256|Select-Object -Unique).Count -ne 1 -or @($all.archive_bytes|Select-Object -Unique).Count -ne 1){throw "Nondeterministic archives: $strategy"}
        $extract=Join-Path $work "restored-$strategy";New-Directory $extract
        $last=$all[-1]
        if($strategy -ceq '7zip'){$null=Tool $seven @('x','-sccUTF-8',$last.archive,"-o$extract",'-y') "$strategy-final-extract"}
        else{$null=Tool $khc @('khc-extract',$last.archive,'--output',$extract) "$strategy-final-extract"}
        $restored=@(Get-ChildItem -LiteralPath $extract -Force -Recurse)
        if($restored.Count -ne 1 -or $restored[0].PSIsContainer -or $restored[0].Name -cne 'ptt5' -or $restored[0].Length -ne 513216){throw 'Final extract path/size mismatch.'}
        $null=Plain $restored[0].FullName
        $hash=Hash $restored[0].FullName
        if($hash -cne $report.input.sha256){throw 'Final extract SHA-256 mismatch.'}
        $report.roundtrips+=@([pscustomobject]@{strategy=$strategy;bytes=$restored[0].Length;sha256=$hash;verified=$true})
        $measured=@($all|Where-Object {-not $_.warmup})
        $enc=@($measured.create.wall_ms|Sort-Object);$dec=@($measured.verify_decode.wall_ms|Sort-Object)
        $report.summary+=@([pscustomobject]@{strategy=$strategy;measured_samples=$measured.Count;archive_bytes=$last.archive_bytes;archive_sha256=$last.archive_sha256;create_median_ms=$enc[4];verify_decode_median_ms=$dec[4];create_max_peak_working_set_bytes=($measured.create.peak_working_set_bytes|Measure-Object -Maximum).Maximum;create_max_peak_paged_memory_bytes=($measured.create.peak_paged_memory_bytes|Measure-Object -Maximum).Maximum;verify_decode_max_peak_working_set_bytes=($measured.verify_decode.peak_working_set_bytes|Measure-Object -Maximum).Maximum;verify_decode_max_peak_paged_memory_bytes=($measured.verify_decode.peak_paged_memory_bytes|Measure-Object -Maximum).Maximum})
    }
    if((Hash $inputPath) -cne $report.input.sha256 -or (Hash $recovery) -cne $report.input.zip_sha256){throw 'Input changed during screen.'}
    foreach($tool in $report.tools){if((Hash $tool.path) -cne $tool.sha256){throw 'Tool changed during screen.'}}
    $report.determinism_verified=$true;$report.status='passed'
} catch {$failure=$_;$report.status='failed';$report.error=$_.Exception.Message}
finally {
    Write-Report
    Assert-KhcStorageContext -WorkDirectory $work
    Write-Output (ConvertTo-Json -InputObject ([ordered]@{status=$report.status;report_path=$reportPath;scope=$report.scope;summary=$report.summary;sample_count=$samples.Count;error=$report.error}) -Depth 6 -Compress)
}
if($null -ne $failure){throw $failure}
