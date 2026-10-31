#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$InputFile,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$InputSha256,
    [string]$Rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe',
    [string]$VsDevCmd='C:/Program Files/Microsoft Visual Studio/18/Community/Common7/Tools/VsDevCmd.bat'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
function Plain([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path); $q=$p
    while($q){if(Test-Path -LiteralPath $q){if((Get-Item -LiteralPath $q -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point'}};$q=[IO.Path]::GetDirectoryName($q)}
    $p
}
$work=Plain $WorkDirectory
$inputPath=Plain $InputFile
$compiler=Plain $Rustc
$vsDevCmd=Plain $VsDevCmd
$inputBytes=(Get-Item -LiteralPath $inputPath).Length
if((Test-Path -LiteralPath $work) -or $inputBytes -lt 1 -or $inputBytes -gt 1048576 -or -not (Test-Path -LiteralPath $vsDevCmd -PathType Leaf)){throw 'Unused work directory, 1..1MiB source, and VS environment required'}
if((Get-FileHash -LiteralPath $inputPath).Hash -ine $InputSha256){throw 'Fixed input SHA'}
$sources=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
function Source([string]$Path){
    $p=Plain $Path; if($sources.ContainsKey($p)){return}
    $sources[$p]=(Get-FileHash -LiteralPath $p).Hash
    $text=[IO.File]::ReadAllText($p)
    if($text -match '#\[global_allocator\]'){throw 'Custom allocator'}
    foreach($m in [regex]::Matches($text,'#\[path\s*=\s*"([^"]+)"\]\s*mod\s+\w+;|(?m)^mod\s+(\w+);')){
        $relative=if($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value+'.rs'}
        Source (Join-Path (Split-Path $p) $relative)
    }
}
$source=Join-Path $PSScriptRoot 'frame_e2e.rs'; Source $source
$closure=0L; foreach($p in $sources.Keys){$closure+=(Get-Item -LiteralPath $p).Length}
$candidateBytes=0L
foreach($name in @('FAILURE_PLAN.md','probe.rs','packet.rs','finite.rs','adversarial.rs','frame_e2e.rs')){$candidateBytes+=(Get-Item -LiteralPath (Join-Path $PSScriptRoot $name)).Length}
if($closure -gt 358400 -or $candidateBytes -gt 65536 -or (Get-Item -LiteralPath $source).Length -gt 26624){throw 'Source capacity'}
foreach($pin in (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'source-pins.json')|ConvertFrom-Json)){
    $p=Join-Path $PSScriptRoot $pin.name
    if((Get-Item -LiteralPath $p).Length -ne $pin.bytes -or (Get-FileHash -LiteralPath $p).Hash -cne $pin.sha256){throw 'Stage A source pin'}
}
$null=New-Item -ItemType Directory -Path $work
$exe=Join-Path $work 'frame-e2e.exe'
$script:processMetrics=[Collections.Generic.List[object]]::new()
function Child([string]$File,[string[]]$Arguments,[int]$Seconds,[string]$Name,[string]$RawArguments=$null){
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$File; $info.WorkingDirectory=$work
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.Environment['TMP']=$work; $info.Environment['TEMP']=$work
    if(-not [string]::IsNullOrEmpty($RawArguments)){$info.Arguments=$RawArguments}else{foreach($a in $Arguments){$info.ArgumentList.Add($a)}}
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info
    try{
        if(-not $p.Start()){throw 'Child start'}
        $stdout=$p.StandardOutput.ReadToEndAsync(); $stderr=$p.StandardError.ReadToEndAsync(); $timer=[Diagnostics.Stopwatch]::StartNew()
        $peak=0L; $peakPaged=0L; $peakPrivate=0L
        while($true){
            $p.Refresh(); $peak=[Math]::Max($peak,$p.PeakWorkingSet64); $peakPaged=[Math]::Max($peakPaged,$p.PeakPagedMemorySize64); $peakPrivate=[Math]::Max($peakPrivate,$p.PrivateMemorySize64)
            if($p.HasExited){break}
            if($timer.Elapsed.TotalSeconds -gt $Seconds){$p.Kill($true);$p.WaitForExit();throw "$Name timeout"}
            if($Name -eq 'native' -and ($peak -gt 160MB -or $peakPaged -gt 160MB -or $peakPrivate -gt 160MB)){$p.Kill($true);$p.WaitForExit();throw 'Native memory ceiling'}
            $null=$p.WaitForExit(50)
        }
        $out=$stdout.GetAwaiter().GetResult(); $err=$stderr.GetAwaiter().GetResult()
        if($out.Length+$err.Length -gt 32768){throw 'Output bound'}
        [IO.File]::WriteAllText((Join-Path $work "$Name.stdout"),$out)
        [IO.File]::WriteAllText((Join-Path $work "$Name.stderr"),$err)
        if($p.ExitCode -ne 0){throw "$Name exit $($p.ExitCode): $err"}
        $script:processMetrics.Add([pscustomobject][ordered]@{name=$Name;root_executable=$File;duration_ms=[Math]::Round($timer.Elapsed.TotalMilliseconds,3);sample_interval_ms=50;peak_working_set_sampled_bytes=$peak;peak_paged_memory_sampled_bytes=$peakPaged;max_private_bytes_sampled=$peakPrivate})
        $out
    }finally{if(-not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
$compileCommand='call "'+$vsDevCmd+'" -no_logo -arch=amd64 -host_arch=amd64 >nul && where link.exe >nul && set "TMP='+$work+'" && set "TEMP='+$work+'" && "'+$compiler+'" --edition=2024 -C opt-level=3 -C debuginfo=0 -o "'+$exe+'" "'+$source+'"'
$null=Child -File $env:ComSpec -Arguments @() -Seconds 60 -Name 'compile' -RawArguments ('/d /s /c '+$compileCommand)
$result=(Child $exe @($inputPath,$InputSha256.ToLowerInvariant()) 120 'native')|ConvertFrom-Json
foreach($p in $sources.Keys){if((Get-FileHash -LiteralPath $p).Hash -cne $sources[$p]){throw 'Source changed during run'}}
if((Get-FileHash -LiteralPath $inputPath).Hash -ine $InputSha256 -or -not $result.complete_frame -or $result.cases.Count -ne 9 -or $result.rejections -le 0 -or $result.rejections -ne $result.same_process_recoveries){throw 'E2E report/input identity'}
[ordered]@{source_bytes=$closure;candidate_bytes=$candidateBytes;source_sha256=$sources;compiler_path=$compiler;compiler_sha256=(Get-FileHash -LiteralPath $compiler).Hash;vsdevcmd_path=$vsDevCmd;vsdevcmd_sha256=(Get-FileHash -LiteralPath $vsDevCmd).Hash;fixed_input=$inputPath;fixed_input_sha256=$InputSha256.ToLowerInvariant();process_metrics=@($script:processMetrics);result=$result}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $work 'report.json') -Encoding utf8NoBOM
$result|ConvertTo-Json -Depth 8 -Compress
