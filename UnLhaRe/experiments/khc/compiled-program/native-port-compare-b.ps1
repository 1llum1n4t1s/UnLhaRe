#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='paired-a',[switch]$Reordered)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-native-program-$Attempt-20261006"
$cli=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/unlhare-cli.exe'
$seven=Join-Path $root 'build/khc-baseline-20260918/x64/7za.exe'
$khc=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc'
$z=Join-Path $root 'build/khc-native-archive-native-a-20261006/native-solid.7z'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='native_full_archive_decode_verify';reordered=[bool]$Reordered;warmups=1;runs=9;input_known_development=$true;raw_bytes=2810784;khc_bytes=466395;seven_bytes=481490;decoder_workers=1;size_gate_pass=$false;archive_output_files=0;CPU_quantization_warning='OS CPU tick granularity, not pure codec';RAM_warning='sampled private and OS peak WS, zero means unavailable';results=$results;pins=$pins;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;RAM=67108864;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
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
function Child([string]$file,[string[]]$arguments){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::new();$ws=0L;$private=0L;$samples=0
    try{$timer.Start();if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        while(-not $p.WaitForExit(1)){$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));$samples++;if($ws -gt 67108864 -or $private -gt 67108864){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 60){throw 'child deadline'}}
        $timer.Stop();$p.Refresh();$cpu=$p.TotalProcessorTime.TotalMilliseconds;$processWall=($p.ExitTime.ToUniversalTime()-$p.StartTime.ToUniversalTime()).TotalMilliseconds
        $ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt 67108864 -or $private -gt 67108864){throw 'final RAM bound'}
        $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $stderr"};Guard
        return @{process_wall_ms=$processWall;cpu_ms=$cpu;harness_wall_ms=$timer.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private;memory_samples=$samples;memory_available=($ws -gt 0 -or $private -gt 0);stdout=$stdout;stderr=$stderr;exit_code=$p.ExitCode}
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'termination timeout'}};$p.Dispose()}
}
try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    $live=@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(cargo|rustc|clippy-driver|7za|unlhare-cli|archive_restore|cdf_compare)\.exe$'});if($live.Count){throw 'relevant process already live'}
    Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'NATIVE_PORT_PLAN_20261006.md');Pin (Join-Path $PSHOME 'pwsh.exe')
    Pin $cli '71EF1B98BC3CDF3477E39C6C4B823E10291A77DBA1590007F4667C687C266295';Pin $seven 'EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0'
    Pin $khc 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE';Pin $z 'F26CA2BA262964FC601D544D860280BCC07A984243828F02DC6DFDC5849F8A78'
    $prior=Join-Path $root 'build/khc-native-archive-native-c-20261006/report.json';Pin $prior '18E70562A567D520B57C4CD7FDC11F5B67C502C218933E6E5B2419DFBCB83D3A'
    $saved=Get-Content -LiteralPath $prior -Raw|ConvertFrom-Json;if($saved.status -ne 'completed' -or -not $saved.live_pins_unchanged){throw 'prior restore not verified'}
    $corpus=@($saved.pins|Where-Object {$_.path -like '*\khc-corpus\canterbury-development\*'}|Sort-Object path -Unique)
    if($corpus.Count -ne 11 -or ($corpus|Measure-Object bytes -Sum).Sum -ne 2810784){throw 'original corpus coverage'}
    foreach($pin in $corpus){Pin $pin.path $pin.SHA256}
    foreach($path in @('src/khc/mod.rs','src/main.rs','Cargo.toml','Cargo.lock')){Pin (Join-Path $root $path)}
    foreach($f in Get-ChildItem -LiteralPath (Join-Path $root 'src/khc/block') -File -Filter '*.rs'){Pin $f.FullName}
    Pin (Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps/libunlhare.rlib') '9D3BAEC4C907A80B043E7CE2DFDA2CC8AC0C483FE18DD82070E7DF7E085659BF'
    if((Get-Item -LiteralPath $khc).Length -ne 466395 -or (Get-Item -LiteralPath $z).Length -ne 481490){throw 'archive extent'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.environment=@{cwd=$root;runner=$PSCommandPath;start_UTC=[DateTime]::UtcNow.ToString('o');processor=(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);free_bytes=[IO.DriveInfo]::new('C:').AvailableFreeSpace;seven_actual=$saved.seven_actual}
    $restore=Join-Path $work 'restored'
    $report.restore_process=Child $cli @('khc-extract','--output',$restore,$khc)
    $files=@(Get-ChildItem -LiteralPath $restore -File -Recurse)
    if($files.Count -ne 11 -or ($files|Measure-Object Length -Sum).Sum -ne 2810784){throw 'restore extent'}
    $restored=[Collections.Generic.List[object]]::new()
    foreach($pin in $corpus){
        $name=[IO.Path]::GetFileName($pin.path);$output=Join-Path $restore $name
        $a=[IO.File]::OpenRead($pin.path);$b=[IO.File]::OpenRead($output)
        try{
            if($a.Length -ne $b.Length){throw 'byte extent'}
            $aa=[byte[]]::new(65536);$bb=[byte[]]::new(65536);$remaining=$a.Length
            while($remaining -gt 0){
                $count=[int][math]::Min($remaining,65536);$a.ReadExactly($aa,0,$count);$b.ReadExactly($bb,0,$count)
                for($j=0;$j -lt $count;$j++){if($aa[$j] -ne $bb[$j]){throw 'restore byte mismatch'}}
                $remaining-=$count
            }
        }finally{$a.Dispose();$b.Dispose()}
        $restored.Add(@{name=$name;bytes=$pin.bytes;byte_exact=$true;SHA256=(Get-FileHash -LiteralPath $output).Hash})
    }
    $report.restore=@{files=11;bytes=2810784;byte_exact=$true;rows=$restored;output_root=$restore}
    $sides=@('khc','seven');if($Reordered){[array]::Reverse($sides)}
    foreach($index in 0..9){
        foreach($side in $sides){
            $r=if($side -eq 'khc'){Child $cli @('khc-test',$khc)}else{Child $seven @('t','-mmt1','-bd','-bso0','-bsp0',$z)}
            if($r.process_wall_ms -le 0 -or $r.cpu_ms -le 0 -or $r.process_wall_ms -gt 60000){throw 'clock contract'}
            $results.Add(@{side=$side;iteration=$index;warmup=($index -eq 0);data=$r})
        };Write-Output ('completed pair '+$index)
    }
    if($results.Count -ne 20){throw 'pair coverage'}
    $summary=@{};foreach($side in @('khc','seven')){$rows=@($results|Where-Object {$_.side -eq $side -and -not $_.warmup});if($rows.Count -ne 9){throw 'side coverage'};$wall=@($rows.data.process_wall_ms|Sort-Object);$cpu=@($rows.data.cpu_ms|Sort-Object);$summary[$side]=@{wall_median_ms=$wall[4];wall_min_ms=$wall[0];wall_max_ms=$wall[8];cpu_median_ms=$cpu[4];cpu_min_ms=$cpu[0];cpu_max_ms=$cpu[8];max_WS=($rows.data.max_WS|Measure-Object -Maximum).Maximum;max_private=($rows.data.max_private|Measure-Object -Maximum).Maximum;memory_available=(@($rows|Where-Object {-not $_.data.memory_available}).Count -eq 0)}}
    $report.summary=$summary;$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
