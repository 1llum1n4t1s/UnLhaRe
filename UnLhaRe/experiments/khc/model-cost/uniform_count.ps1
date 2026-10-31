#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='uniform-count-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-model-cost-$Attempt-20261006"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$exe=Join-Path $work 'uniform_count.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='uniform_quantization_call_diagnostic';timing_is_speed_evidence=$false;raw_frame_disk=0;results=$results;pins=$pins;build=$null;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;helper_RAM=67108864;compiler_RAM=536870912;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
function Chain([string]$path){$p=[IO.Path]::GetFullPath($path);while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$path,[string]$expected=''){Chain $path;$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$file=Get-Item -LiteralPath $path;$sha=(Get-FileHash -LiteralPath $path).Hash;if($expected -and $sha -ne $expected){throw 'SHA mismatch'};$pins.Add(@{path=$path;SHA256=$sha;bytes=$file.Length;mtime=$file.LastWriteTimeUtc.ToString('o')})}
function Usage{
    for($attemptIndex=0;$attemptIndex -lt 4;$attemptIndex++){
        try{$files=@(Get-ChildItem -LiteralPath $work -File -Recurse -ErrorAction Stop);if($files|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'reparse output'};if(-not $files.Count){return 0L};return [long](($files|Measure-Object Length -Sum).Sum)}
        catch{if($_.Exception -isnot [IO.IOException] -or ($_.Exception.HResult -band 65535) -notin 2,3 -or $attemptIndex -eq 3 -or -not (Test-Path -LiteralPath $work -PathType Container)){throw};Start-Sleep -Milliseconds 25}
    }
    throw 'unreachable usage'
}
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created -and (Usage) -gt 8388608){throw 'work bound'};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$file,[string[]]$arguments,[long]$ram){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'final RAM bound'};Guard;$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $stderr"};return @{stdout=$stdout;stderr=$stderr;max_WS=$ws;max_private=$private;wall_ms=$timer.Elapsed.TotalMilliseconds}
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'termination timeout'}};$p.Dispose()}
}
try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';Pin $crc '55457337A3D05ED2B2286381B39760C46AF4CEA9834EFE89B07AA1AB487444C9';Pin (Join-Path $PSHOME 'pwsh.exe')
    foreach($path in @('UNIFORM_DIAGNOSTIC_PLAN_20261006.md','uniform_count.rs','uniform_count_codec.rs','uniform_count_model.rs','uniform_count.ps1')){Pin (Join-Path $PSScriptRoot $path)}
    Pin (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json')
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc/block') -File -Filter '*.rs'){Pin $path.FullName}
    foreach($pair in @(@('mod.rs','uniform_count_codec.rs'),@('model.rs','uniform_count_model.rs'))){
        $original=Get-Content (Join-Path $root ('src/khc/block/'+$pair[0])) -Raw
        $copy=Get-Content (Join-Path $PSScriptRoot $pair[1]) -Raw
        $copy=[regex]::Replace($copy,'(?ms)^\s*// PROFILE BEGIN\r?\n.*?^\s*// PROFILE END\r?\n','')
        if($pair[0] -eq 'mod.rs'){
            if([regex]::Matches($copy,'(?m)^#\[path = "[^"]+"\]').Count -ne 13){throw 'derived path coverage'}
            $copy=[regex]::Replace($copy,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
        }
        if([regex]::Replace($original,'\s','') -cne [regex]::Replace($copy,'\s','')){throw ('derived product mismatch '+$pair[0])}
    }
    $report.normalized_current_product=$true
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.build=Child $rustc @('--edition','2024','-C','opt-level=3','-C','codegen-units=1','-C','debuginfo=0','-L',"dependency=$dependency",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'uniform_count.rs'),'-o',$exe) 536870912
    Pin $exe;Write-Output 'compiled diagnostic'
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$corpus=@($manifest|Where-Object name -eq 'canterbury-development');if($corpus.Count -ne 1 -or $corpus[0].files.Count -ne 11){throw 'manifest shape'}
    $cases=@(foreach($entry in $corpus[0].files){$path=Join-Path $root ('build/khc-corpus/canterbury-development/'+$entry.name);Pin $path $entry.sha256;if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or $entry.bytes -gt 1048576){throw 'input extent'};@{name=$entry.name;arg=$path;bytes=$entry.bytes;SHA256=$entry.sha256}})
    $cases+=@(@{name='empty';arg='--empty';bytes=0;SHA256='synthetic empty'},@{name='one';arg='--one';bytes=1;SHA256='synthetic [165]'})
    foreach($case in $cases){
        $r=Child $exe @($case.arg) 67108864;$data=$r.stdout|ConvertFrom-Json
        if(-not $data.byte_exact -or $data.raw_bytes -ne $case.bytes -or $data.frame_bytes -gt $case.bytes+40 -or $data.method -notin 0,1,2,3){throw 'result contract'}
        if($data.encode_ns.Count -ne 9 -or $data.zero_quantize_calls -gt $data.quantize_calls -or $data.phase_capacity_bound -gt 67108864){throw 'coverage/capacity'}
        $results.Add(@{name=$case.name;input_SHA256=$case.SHA256;data=$data;max_WS=$r.max_WS;max_private=$r.max_private});Write-Output ('completed '+$case.name)
    }
    if($results.Count -ne 13){throw 'full coverage'};$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}


