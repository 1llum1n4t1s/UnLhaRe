#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='sufficient-traced-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-flat-token-cdf-$Attempt-20261007"
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='sufficient_history_MDL_leaf_memo_census';pins=$pins;failure=$null;live_pins_unchanged=$false;real_new_codec=$false;timing_is_speed_evidence=$false;raw_frame_disk=0}
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
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 8388608){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};
if(-not $report.Contains('CPU_observations')){$report.CPU_observations=[Collections.Generic.List[object]]::new()}
if($report.CPU_observations.Count -lt 64){$report.CPU_observations.Add(@{UTC=[DateTime]::UtcNow.ToString('o');percent=[long]$cpu.PercentProcessorTime;elapsed_ms=$q.Elapsed.TotalMilliseconds})}
if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
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

try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused work required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
    $rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe';Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Pin $PSCommandPath
    foreach($name in @('SUFFICIENT_KEY_20261007.md','leaf_memo_sufficient.rs','baseline_sufficient.rs','paid_model_dependency.rs','packet_dependency.rs','census_sufficient.rs')){Pin (Join-Path $PSScriptRoot $name)}
    $arith=Join-Path $root 'build/khc-flat-token-cdf-execution-a-20261007/report.json';Pin $arith '458CF97065781CD932B821370805A0B7914D8A1E9365A57AB6409F3FE0EEC62B'
    $witness=Get-Content $arith -Raw|ConvertFrom-Json
    if($witness.status -ne 'completed' -or -not $witness.data.exact_integer -or $witness.build_success_claimed){throw 'arithmetic witness provenance'}
    $report.compiler_witness_status='arith builds failed resource gate; runtime-only witness separately passed; not codec proof'
    Pin (Join-Path $root 'src/khc/block/mod.rs') 'B050BBF7EBF988A50514146C39501F3EB6DB758051DA601968ACD70A65793984'
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'src/khc/block') -File -Filter '*.rs'){if(@($pins|Where-Object path -eq $file.FullName).Count -eq 0){Pin $file.FullName}}
    Pin (Join-Path $root 'Cargo.toml');Pin (Join-Path $root 'Cargo.lock')
    $depsFile=Join-Path $PSScriptRoot '../row-copy-pruned-rans/native-dependencies.json';Pin $depsFile
    $deps=Get-Content $depsFile -Raw|ConvertFrom-Json
    $crc=@($deps.dependencies|Where-Object crate -eq 'crc_fast');$json=@($deps.dependencies|Where-Object crate -eq 'serde_json')
    if($crc.Count -ne 1 -or $json.Count -ne 1){throw 'unique externs'};Pin $crc[0].path $crc[0].SHA256;Pin $json[0].path $json[0].SHA256
    $dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps';$hostDependency=Join-Path $root 'build/cargo/release/deps'
    foreach($file in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $file.FullName}
    $library=Join-Path $root 'build/khc-row-copy-pruned-rans-native-a-20261007/libunlhare.rlib';Pin $library 'BF50A95F66645A60156F89C8C8833D7D65DCA0448E3F15A1731BA4176303DC30'
    $w52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
    $w53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
    Pin (Join-Path $w52 'windows.0.52.0.lib');Pin (Join-Path $w53 'windows.0.53.0.lib')
    $archive=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc';Pin $archive 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifestFile=Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json';Pin $manifestFile
    $manifest=Get-Content $manifestFile -Raw|ConvertFrom-Json;$entries=@($manifest|Where-Object name -eq 'canterbury-development')
    if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'Cargo cap'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true;$exe=Join-Path $work 'census.exe'
    $compileArguments=@('--edition=2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$w52",'-L',"native=$w53",'--extern',"unlhare=$library",'--extern',("crc_fast="+$crc[0].path),'--extern',("serde_json="+$json[0].path),(Join-Path $PSScriptRoot 'census_sufficient.rs'),'-o',$exe)
    $report.build=Child $rustc $compileArguments 536870912;Pin $exe
    $run=Child $exe @($archive,$corpus) 67108864
    $report.data=$run.stdout|ConvertFrom-Json
    if($report.data.complete_inputs -ne 11 -or $report.data.cache_bytes -ne 1572864 -or -not $report.data.observational_only -or $report.data.finite_memo_checks -ne 27657){throw 'census result coverage'}
    foreach($entry in $entries[0].files){$rows=@($report.data.rows|Where-Object name -eq $entry.name);if($rows.Count -ne 1 -or -not $rows[0].byte_exact -or $rows[0].raw -ne $entry.bytes -or $rows[0].logical_peak -gt 67108864){throw 'row coverage/bytes/RAM'}}
    $run.Remove('stdout');$run.Remove('stderr');$report.run=$run
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($bytes.Length -gt 65536){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
        & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
        [ordered]@{status=$report.status;failure=$report.failure;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}|ConvertTo-Json -Compress
    }else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
