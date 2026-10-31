#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkDirectory,[Parameter(Mandatory)][string]$InputFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$expected='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'
function Plain([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path);$q=$p
    while($q){if(Test-Path -LiteralPath $q){if((Get-Item -LiteralPath $q -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point'}};$q=[IO.Path]::GetDirectoryName($q)}
    if($p -match '["%&|<>\r\n]'){throw 'Unsupported shell path'}
    $p
}
$work=Plain $WorkDirectory
$inputPath=Plain $InputFile
$root=Plain (Join-Path $PSScriptRoot '../../..')
$rustc=Plain 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$vs=Plain 'C:/Program Files/Microsoft Visual Studio/18/Community/Common7/Tools/VsDevCmd.bat'
$taskPaths=Get-KhcStorageTaskPaths
$baseline=Plain (Join-Path $taskPaths.CargoTargetRoot 'debug/examples/khc_record_fast_bench.exe')
if((Test-Path -LiteralPath $work) -or (Get-Item -LiteralPath $inputPath).Length -ne 513216 -or (Get-FileHash -LiteralPath $inputPath).Hash -ine $expected){throw 'Unused work and exact ptt5 required'}
foreach($file in @($rustc,$vs,$baseline)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Required executable: $file"}}
$sources=[ordered]@{}
foreach($relative in @('PLAN_20261016.md','probe.rs','codec.rs','run-e2e.ps1','../causal-record-vote/voter.rs','../../../src/khc/block/multi_range.rs')) {
    $path=Plain (Join-Path $PSScriptRoot $relative)
    $sources[$path]=[ordered]@{bytes=(Get-Item -LiteralPath $path).Length;sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}
}
$sourceBytes=0L;foreach($p in $sources.Keys){$sourceBytes+=$sources[$p].bytes}
if($sourceBytes -gt 65536){throw 'Source closure exceeds fixed 64KiB'}
$null=New-Item -ItemType Directory -Path $work
$inputDir=Join-Path $work 'input';$null=New-Item -ItemType Directory -Path $inputDir
$localInput=Join-Path $inputDir 'ptt5';Copy-Item -LiteralPath $inputPath -Destination $localInput
$exe=Join-Path $work 'probe.exe'
$script:metrics=[Collections.Generic.List[object]]::new()
function Child([string]$File,[string[]]$Arguments,[string]$Name,[int]$Seconds,[string]$RawArguments=$null) {
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$File;$info.WorkingDirectory=$work
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['TMP']=$work;$info.Environment['TEMP']=$work
    if($RawArguments){$info.Arguments=$RawArguments}else{foreach($a in $Arguments){$info.ArgumentList.Add($a)}}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try {
        $started=$p.Start();if(-not $started){throw 'Child start'}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$timer=[Diagnostics.Stopwatch]::StartNew()
        $peak=0L
        while($true){
            $p.Refresh();$peak=[Math]::Max($peak,$p.PeakWorkingSet64)
            if($p.HasExited){break}
            if($timer.Elapsed.TotalSeconds -gt $Seconds){$p.Kill($true);$p.WaitForExit();throw "$Name timeout"}
            if($Name -eq 'native' -and $peak -gt 160MB){$p.Kill($true);$p.WaitForExit();throw 'Native process memory ceiling'}
            $null=$p.WaitForExit(50)
        }
        $p.WaitForExit();$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        if($out.Length+$err.Length -gt 32768){throw 'Child output bound'}
        [IO.File]::WriteAllText((Join-Path $work "$Name.stdout"),$out)
        [IO.File]::WriteAllText((Join-Path $work "$Name.stderr"),$err)
        $script:metrics.Add([ordered]@{name=$Name;exit_code=$p.ExitCode;duration_ms=$timer.Elapsed.TotalMilliseconds;peak_working_set_bytes=$peak})
        if($p.ExitCode -ne 0){throw "$Name exit $($p.ExitCode): $err"}
        $out
    } finally {if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
$source=Join-Path $PSScriptRoot 'probe.rs'
$command='call "'+$vs+'" -no_logo -arch=amd64 -host_arch=amd64 >nul && "'+$rustc+'" --edition=2024 -C opt-level=3 -C debuginfo=0 -C panic=abort -o "'+$exe+'" "'+$source+'"'
$null=Child $env:ComSpec @() 'compile' 60 ('/d /s /c '+$command)
if((Get-KhcRunUsage $work -MaxEntries 64) -gt 3MB){throw 'Compile left insufficient fixed 5MiB room for E2E and recovery'}
$result=(Child $exe @($localInput,$expected,$work) 'native' 120)|ConvertFrom-Json
$krs2=(Child $baseline @('record-fast-trial',$localInput,'3') 'krs2' 60)|ConvertFrom-Json
if($krs2.frame_format -ne 'KRS2' -or $krs2.frame_bytes -ne 46202 -or $krs2.input_bytes -ne 513216){throw 'Current KRS2 identity/size changed'}
if(-not $result.complete_frame -or $result.normal_cases.Count -ne 10 -or $result.rejections -ne $result.same_process_recoveries -or $result.rejections -lt 25){throw 'Incomplete finite E2E'}
if((Get-FileHash -LiteralPath (Join-Path $work 'restored-ptt5')).Hash -ine $expected -or (Get-FileHash -LiteralPath $inputPath).Hash -ine $expected){throw 'Roundtrip or source SHA changed'}
foreach($p in $sources.Keys){if((Get-FileHash -LiteralPath $p).Hash -ine $sources[$p].sha256){throw 'Source changed during experiment'}}
$report=[ordered]@{
    schema='khc-causal-copy-spatial-bits-v1';fixed_input=$inputPath;fixed_input_sha256=$expected
    source_bytes=$sourceBytes;source_pins=$sources
    compiler_path=$rustc;compiler_sha256=(Get-FileHash -LiteralPath $rustc).Hash.ToLowerInvariant()
    baseline_path=$baseline;baseline_sha256=(Get-FileHash -LiteralPath $baseline).Hash.ToLowerInvariant()
    process_metrics=@($script:metrics);candidate=$result;krs2=$krs2
    comparison=[ordered]@{candidate_frame_bytes=$result.frame_bytes;krs2_frame_bytes=$krs2.frame_bytes;stored_frame_bytes=513256;delta_to_krs2_bytes=($result.frame_bytes-$krs2.frame_bytes);historical_khc_archive_bytes=46274;historical_7zip_26_04_archive_bytes=42199;archive_reference_is_historical=$true;candidate_has_no_archive_container=$true;size_screen_go=($result.frame_bytes -lt $krs2.frame_bytes)}
}
$report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8NoBOM
$report.comparison|ConvertTo-Json -Compress
