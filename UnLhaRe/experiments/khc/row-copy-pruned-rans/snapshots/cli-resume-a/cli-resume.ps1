#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='cli-resume-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-row-copy-pruned-rans-$Attempt-20261007"
$priorWork=Join-Path $root 'build/khc-row-copy-pruned-rans-cli-a-20261007'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='same_EXE_existing9_scoped_E2E_resume';timing_is_speed_evidence=$false;pins=$pins;failure=$null;live_pins_unchanged=$false;compiled_again=$false}
$saved=@{}
foreach($key in @('UNLHARE_KHC_E2E_ROOT','UNLHARE_KHC_FIXED_INPUT')){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
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
function Guard{
    if([IO.Directory]::Exists($priorWork)){
        $priorUsage=[long]((Get-ChildItem -LiteralPath $priorWork -Recurse -File|Measure-Object Length -Sum).Sum);
        if($priorUsage -gt 25165824){throw 'prior fixture/build bound'}
    };if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 8388608){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$file,[string[]]$arguments,[long]$ram){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'final RAM bound'};Guard;$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $stderr"};return @{process_id=$p.Id;stdout=$stdout;stderr=$stderr;max_WS=$ws;max_private=$private;wall_ms=$timer.Elapsed.TotalMilliseconds}
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

try {
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused work required'}
    Pin $PSCommandPath
    $proofPath=Join-Path $priorWork 'report.json';Pin $proofPath 'D43C68A333549ADE40AFCF8336C5397FA31714DB9D5E97F8721A07DBDFE5CD99'
    $prior=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json -DateKind String
    if($prior.status -ne 'failed' -or $prior.failure -ne 'existing E2E evidence coverage' -or -not $prior.live_pins_unchanged -or -not $prior.CLI_bytes_exact -or -not $prior.invalid_strategy_rejected -or $prior.tests.stdout -notmatch 'test result: ok\. 9 passed; 0 failed'){throw 'wrong recovery prerequisite'}
    foreach($old in $prior.pins){
        Pin $old.path $old.SHA256
        $now=$pins[$pins.Count-1]
        if($old.bytes -ne $now.bytes -or $old.mtime -cne $now.mtime){throw 'historical identity drift'}
    }
    $report.inherited_CLI_phase=@{source_report=$proofPath;SHA256='D43C68A333549ADE40AFCF8336C5397FA31714DB9D5E97F8721A07DBDFE5CD99';CLI_bytes_exact=$prior.CLI_bytes_exact;invalid_strategy_rejected=$prior.invalid_strategy_rejected;CLI_SHA256=$prior.CLI.SHA256;prior_suite_status='failed collector; CLI/test executions had passed'}
    $exe=Join-Path $priorWork 'existing-khc-tests.exe'
    $fixed=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group';Pin $fixed '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    $fixture=Join-Path $priorWork 'fixture-manifest'
    $explicitRoot=Join-Path $fixture 'build/khc-product-e2e-20261005'
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_E2E_ROOT',$explicitRoot,'Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_FIXED_INPUT',$fixed,'Process')
    $report.explicit_normal_fixture_root=$explicitRoot
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'Cargo cap'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $run=Child $exe @('--test-threads=1') 67108864
    if($run.stdout -notmatch 'test result: ok\. 9 passed; 0 failed; 0 ignored'){throw 'existing tests failed/missing'}
    $report.tests=$run
    $childId=$run.process_id
    $evidence=@(Get-ChildItem -LiteralPath $fixture -Recurse -File -Filter result.json | Where-Object {$_.Directory.Name.EndsWith('-'+$childId)})
    if($evidence.Count -ne 7){throw 'scoped evidence coverage'}
    $report.evidence=@(foreach($file in $evidence){@{path=$file.FullName;bytes=$file.Length;SHA256=(Get-FileHash -LiteralPath $file.FullName).Hash;data=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json}})
    $block=@($report.evidence|Where-Object path -match 'block-normal-')
    $normal=@($report.evidence|Where-Object {$_.path -match '[\\/]normal-'})
    if($block.Count -ne 1 -or -not $block[0].data.fixed_not_larger_than_baseline -or $block[0].data.fixed_frame_bytes.Count -ne 3 -or $normal.Count -ne 1 -or -not $normal[0].data.api_and_real_cli -or -not $normal[0].data.byte_exact){throw 'required scoped E2E evidence'}
    $report.fixture_bytes=[long]((Get-ChildItem -LiteralPath $fixture -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.fixture_bytes -gt 8388608){throw 'fixture budget'}
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){
        $data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 16 -Compress));if($data.Length -gt 131072){throw 'report bound'}
        $path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
        [ordered]@{status=$report.status;failure=$report.failure;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}|ConvertTo-Json -Compress
    }else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}

