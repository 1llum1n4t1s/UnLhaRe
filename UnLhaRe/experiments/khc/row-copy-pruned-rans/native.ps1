#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='native-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-row-copy-pruned-rans-$Attempt-20261007"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='native_revision3_record_trial_E2E';timing_is_speed_evidence=$false;pins=$pins;build=$null;failure=$null;live_pins_unchanged=$false;limits=@{work=16777216;report=131072;child_seconds=60;suite_seconds=300;codec_child_RAM=67108864;compiler_parent_RAM=536870912;CPU_percent=15;quiet_seconds=60}}
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
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 16777216){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5389680640){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$file,[string[]]$arguments,[long]$ram){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 60){throw 'child deadline'}}
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

try {
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 16 | Out-Null
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Pin $PSCommandPath
    foreach($path in @('native-dependencies.json','native-probe.rs','native-archive.rs','codec.rs','baseline_block.rs','bound.rs','full_codec.rs','NATIVE_INTEGRATION_20261007.md')){Pin (Join-Path $PSScriptRoot $path)}
    foreach($path in @('src/lib.rs','src/main.rs','Cargo.toml','Cargo.lock','build.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $path)}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.rs'){if(@($pins|Where-Object path -eq $file.FullName).Count -eq 0){Pin $file.FullName}}
    Pin (Join-Path $PSScriptRoot '../mdl-rans/entropy.rs')
    Pin (Join-Path $PSScriptRoot '../causal-record-vote/voter.rs') '081FB1EF8D42E90710E0E37A01F9F1744EA52133D707D954A4AC4619D322203E'
    $deps=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'native-dependencies.json') -Raw|ConvertFrom-Json
    if($deps.dependencies.Count -ne 12){throw 'dependency count'}
    Pin $deps.manifest $deps.manifest_SHA256
    foreach($dep in $deps.dependencies){Pin $dep.path $dep.SHA256}
    foreach($file in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $file.FullName}
    $w52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
    $w53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
    Pin (Join-Path $w52 'windows.0.52.0.lib');Pin (Join-Path $w53 'windows.0.53.0.lib')
    $archive=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc'
    Pin $archive 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifest=Get-Content -LiteralPath (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json
    $entries=@($manifest|Where-Object name -eq 'canterbury-development')
    if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'corpus manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'shared Cargo cap'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $library=Join-Path $work 'libunlhare.rlib'
    $common=@('--edition=2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$w52",'-L',"native=$w53")
    $arguments=@('--crate-name','unlhare','--crate-type','rlib',(Join-Path $root 'src/lib.rs'))+$common+@('-o',$library)
    foreach($dep in $deps.dependencies){$arguments+=@('--extern',($dep.crate+'='+$dep.path))}
    Write-Output 'standalone native library; existing exact Cargo dependencies'
    $report.build=Child $rustc $arguments 536870912
    $report.library=@{path=$library;bytes=(Get-Item -LiteralPath $library).Length;SHA256=(Get-FileHash -LiteralPath $library).Hash}
    Pin $library $report.library.SHA256
    $exe=Join-Path $work 'probe.exe'
    $crc=@($deps.dependencies|Where-Object crate -eq 'crc_fast');$json=@($deps.dependencies|Where-Object crate -eq 'serde_json')
    if($crc.Count -ne 1 -or $json.Count -ne 1){throw 'probe externs'}
    $arguments=@('--crate-name','native_record_e2e',(Join-Path $PSScriptRoot 'native-probe.rs'))+$common+@('--extern',"unlhare=$library",'--extern',("crc_fast="+$crc[0].path),'--extern',("serde_json="+$json[0].path),'-o',$exe)
    Write-Output 'native/private frame equivalence and real archive E2E'
    $report.probe_build=Child $rustc $arguments 536870912
    Pin $exe
    $fixture=Join-Path $work 'fixture'
    $run=Child $exe @($archive,$corpus,$fixture) 67108864
    $report.data=$run.stdout|ConvertFrom-Json
    if(-not $report.data.native_trial_frame_exact -or -not $report.data.byte_exact -or -not $report.data.strict_rejection -or -not $report.data.native_archive.all_bytes_exact -or $report.data.native_archive.native_archive_bytes -ne 457017){throw 'native E2E result contract'}
    $run.Remove('stdout');$run.Remove('stderr');$report.run=$run
    $fixtureBytes=[long]((Get-ChildItem -LiteralPath $fixture -Recurse -File|Measure-Object Length -Sum).Sum)
    if($fixtureBytes -gt 4194304){throw 'fixture budget'}
    $report.fixture_bytes=$fixtureBytes
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){
        $data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($data.Length -gt 131072){throw 'report bound'}
        $path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
        & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 16 | Out-Null
        [ordered]@{status=$report.status;failure=$report.failure;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash}|ConvertTo-Json -Compress
    }else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}

