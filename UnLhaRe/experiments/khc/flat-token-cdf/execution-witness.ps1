#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-flat-token-cdf-execution-a-20261007'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='arith_runtime_witness_only';pins=$pins;failure=$null;live_pins_unchanged=$false;build_success_claimed=$false;compiled_again=$false;real_codec=$false;timing_is_speed_evidence=$false}
function Chain([string]$path){$p=[IO.Path]::GetFullPath($path);while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$path,[string]$expected=''){Chain $path;$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$file=Get-Item -LiteralPath $path;$sha=(Get-FileHash -LiteralPath $path).Hash;if($expected -and $sha -ne $expected){throw 'SHA mismatch'};$pins.Add(@{path=$path;SHA256=$sha;bytes=$file.Length;mtime=$file.LastWriteTimeUtc.ToString('o')})}
function MissingTransient([Exception]$failure){
    for($cause=$failure;$null -ne $cause;$cause=$cause.InnerException){
        if($cause -is [ComponentModel.Win32Exception] -and $cause.NativeErrorCode -in @(2,3)){return $true}
        if($cause -is [IO.IOException] -and (($cause.HResult -band 65535) -in @(2,3))){return $true}
    }
    return $false
}
function WorkUsage{
    for($scan=0;$scan -lt 3;$scan++){
        try{
            $files=@(Get-ChildItem -LiteralPath $work -Recurse -Force -ErrorAction Stop)
            if(@($files|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'work reparse'}
            $regular=@($files|Where-Object {-not $_.PSIsContainer})
            return $(if($regular.Count){($regular|Measure-Object Length -Sum).Sum}else{0L})
        }catch{
            $missing=MissingTransient $_.Exception
            if(-not $missing -or $scan -eq 2 -or -not [IO.Directory]::Exists($work)){throw}
            Start-Sleep -Milliseconds 25
        }
    }
}
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 1048576){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$file,[string[]]$arguments,[long]$ram){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 10){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'final RAM bound'};Guard;$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $stderr"};return @{stdout=$stdout;stderr=$stderr;max_WS=$ws;max_private=$private;wall_ms=$timer.Elapsed.TotalMilliseconds}
    }catch{
        $report.child_failure=@{file=$file;arguments=$arguments;exception=$_.Exception.GetType().FullName;message=$_.Exception.Message;stack=$_.ScriptStackTrace;started=$started}
        throw
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'termination timeout'}};
        if($started -and $p.HasExited -and $report.Contains('child_failure')){
            $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
            $report.child_failure.stdout=$o.Substring(0,[math]::Min(32768,$o.Length))
            $report.child_failure.stderr=$e.Substring(0,[math]::Min(32768,$e.Length))
            $report.child_failure.exit=$p.ExitCode
        }
        $p.Dispose()}
}

try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused work required'}
    Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'EXECUTION_WITNESS.md')
    $failure=Join-Path $root 'build/khc-flat-token-cdf-arith-no-lto-a-20261007/report.json';Pin $failure '24074D67AFD7640EFDA6F70AAF43FC0D6975F8479D4276AC8A193FB4329A5D52'
    $prior=Get-Content -LiteralPath $failure -Raw|ConvertFrom-Json -DateKind String
    if($prior.status -ne 'failed' -or $prior.failure -ne 'work bound' -or -not $prior.live_pins_unchanged){throw 'wrong compiler provenance'}
    foreach($old in $prior.pins){Pin $old.path $old.SHA256;$now=$pins[$pins.Count-1];if($old.bytes -ne $now.bytes -or $old.mtime -cne $now.mtime){throw 'compiler source drift'}}
    $exe=Join-Path $root 'build/khc-flat-token-cdf-arith-no-lto-a-20261007/arith.exe';Pin $exe '038A5087504340CB669FDAEDBAB57C0B7E143CD2F733032609B44D9DD339B289'
    $report.compiler_status='failed_work_bound; not reversed';$report.compiler_failure_report=$failure
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'Cargo cap'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $run=Child $exe @() 16777216
    $report.data=$run.stdout|ConvertFrom-Json
    if(-not $report.data.exact_integer -or -not $report.data.all_supports_1_to_257 -or $report.data.invalid_rejects -ne 6){throw 'witness coverage'}
    $run.Remove('stdout');$run.Remove('stderr');$report.run=$run
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($bytes.Length -gt 16384){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()};[ordered]@{status=$report.status;failure=$report.failure;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}

