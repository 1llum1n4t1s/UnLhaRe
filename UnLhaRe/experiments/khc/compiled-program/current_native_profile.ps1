#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$LibrarySha256,
    [ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='profile-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-program-profile-$Attempt-20261006"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$windows52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
$windows53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$library=Join-Path $dependency 'libunlhare.rlib'
$exe=Join-Path $work 'current_native_profile.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='compiled_Program_current_source_native_frame_profile';timing_is_speed_evidence=$false;raw_frame_disk=0;results=$results;pins=$pins;build=$null;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;helper_RAM=67108864;compiler_RAM=536870912;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
function Chain([string]$path){$p=[IO.Path]::GetFullPath($path);while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$path,[string]$expected=''){Chain $path;$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$file=Get-Item -LiteralPath $path;$sha=(Get-FileHash -LiteralPath $path).Hash;if($expected -and $sha -ne $expected){throw 'SHA mismatch'};$pins.Add(@{path=$path;SHA256=$sha;bytes=$file.Length;mtime=$file.LastWriteTimeUtc.ToString('o')})}
function WorkUsage{
    for($scan=0;$scan -lt 3;$scan++){
        try{
            $files=@(Get-ChildItem -LiteralPath $work -Recurse -Force -ErrorAction Stop)
            if(@($files|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'work reparse'}
            $regular=@($files|Where-Object {-not $_.PSIsContainer})
            return $(if($regular.Count){($regular|Measure-Object Length -Sum).Sum}else{0L})
        }catch{
            $missing=$false
            for($errorValue=$_.Exception;$null -ne $errorValue;$errorValue=$errorValue.InnerException){if($errorValue -is [IO.IOException] -and (($errorValue.HResult -band 65535) -in @(2,3))){$missing=$true}}
            if(-not $missing -or $scan -eq 2 -or -not [IO.Directory]::Exists($work)){throw}
            Start-Sleep -Milliseconds 25
        }
    }
}
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 8388608){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120){throw 'free space guard'}}
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
    foreach($path in @('current_native_profile.rs','CURRENT_PHASE_PLAN_20261006.md','current_native_profile.ps1','current_profile_block.rs')){Pin (Join-Path $PSScriptRoot $path)}
    foreach($path in @('Cargo.toml','Cargo.lock','src/lib.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $path)}
    Pin $library $LibrarySha256;Chain $hostDependency
    foreach($macro in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $macro.FullName}
    Pin (Join-Path $windows52 'windows.0.52.0.lib');Pin (Join-Path $windows53 'windows.0.53.0.lib')
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $path.FullName}
    $original=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    $profile=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'current_profile_block.rs') -Raw
    if([regex]::Matches($profile,'(?m)^#\[path = "[^"]+"\]').Count -ne 14){throw 'profile child paths'}
    $profile=[regex]::Replace($profile,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
    $profile=[regex]::Replace($profile,'(?ms)^std::thread_local! \{\r?\n.*?^pub\(crate\) fn decode_phases\(\) -> \[u128; 6\] \{\r?\n.*?^\}\r?\n','')
    $profile=[regex]::Replace($profile,'(?m)^    (?:let mut phase_started = .*|let mut phases = .*|DECODE_PHASES\.with.*|phases\[\d\] = .*|phase_started = .*);\r?\n','')
    if([regex]::Replace($original,'\s','') -cne [regex]::Replace($profile,'\s','')){throw 'profile outside timer/path scope'}
    $report.normalized_current_product=$true
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'shared Cargo cap'}
    $archive=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc';Pin $archive 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$entries=@($manifest|Where-Object name -eq 'canterbury-development');if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'corpus manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.build=Child $rustc @('--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$windows52",'-L',"native=$windows53",'--extern',"unlhare=$library",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'current_native_profile.rs'),'-o',$exe) 536870912
    Pin $exe;Write-Output 'compiled diagnostic against current child modules'
    $run=Child $exe @($archive,$corpus) 67108864
    $decoded=$run.stdout|ConvertFrom-Json
    if($decoded.decoder -cne 'current compiled Program' -or -not $decoded.byte_exact -or -not $decoded.public_archive_verified -or $decoded.rows.Count -ne 99 -or ($decoded.phase_names -join ',') -cne 'wire,alphabet_forest,grammar_setup,token_runs,inverse,CRC_capacity'){throw 'profile result contract'}
    foreach($entry in $entries[0].files){
        $rows=@($decoded.rows|Where-Object name -eq $entry.name);if($rows.Count -ne 9 -or @($rows.iteration|Select-Object -Unique).Count -ne 9){throw 'profile coverage'}
        foreach($row in $rows){
            if($row.raw_bytes -ne $entry.bytes -or $row.frame_bytes -gt $entry.bytes+40 -or $row.method -notin 0,1,2,3 -or $row.public_ns -le 0 -or $row.total_ns -le 0 -or $row.phase_ns.Count -ne 6 -or @($row.phase_ns|Where-Object {$_ -lt 0}).Count -or ($row.phase_ns|Measure-Object -Sum).Sum -gt $row.total_ns){throw 'profile row contract'}
            if($row.method -ne 1 -and @($row.phase_ns|Where-Object {$_ -ne 0}).Count){throw 'nonMDL phase'}
            if($row.phase_capacity_bound -gt 67108864){throw 'profile allocation bound'}
        }
    }
    $run.Remove('stdout');$run.Remove('stderr');$report.run=$run;$report.data=$decoded
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before -or $report.cargo_after -gt 6175228536){throw 'Cargo changed during standalone profile'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
