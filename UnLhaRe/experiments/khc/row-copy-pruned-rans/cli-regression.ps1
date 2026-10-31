#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='cli-a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-row-copy-pruned-rans-$Attempt-20261007"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='native_CLI_and_existing9_E2E';timing_is_speed_evidence=$false;pins=$pins;build=$null;failure=$null;live_pins_unchanged=$false;limits=@{work=25165824;fixture=8388608;report=131072;child_seconds=60;suite_seconds=300;codec_child_RAM=67108864;compiler_parent_RAM=536870912;CPU_percent=15;quiet_seconds=60}}
$savedEnv=@{}
foreach($key in @('CARGO_MANIFEST_DIR','CARGO_PKG_VERSION','CARGO_PKG_NAME','CARGO_BIN_EXE_unlhare-cli','UNLHARE_KHC_E2E_ROOT','UNLHARE_KHC_FIXED_INPUT')){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
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
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'};if($created){$used=WorkUsage;if($used -gt 25165824){throw 'work bound'}};if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5393874944){throw 'free space guard'}}
function Quiet{$q=[Diagnostics.Stopwatch]::StartNew();while($true){Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'";if($null -eq $cpu){throw 'CPU metric unavailable'};if($cpu.PercentProcessorTime -le 15){return};if($q.Elapsed.TotalSeconds -ge 60){throw 'CPU quiet timeout'};Start-Sleep -Milliseconds 500}}
function Child([string]$file,[string[]]$arguments,[long]$ram,[int]$expectedExit=0){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$root;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -gt 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'final RAM bound'};Guard;$stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 32768){throw 'text bound'};if($p.ExitCode -ne $expectedExit){throw "child exit $($p.ExitCode): $stderr"};return @{stdout=$stdout;stderr=$stderr;max_WS=$ws;max_private=$private;wall_ms=$timer.Elapsed.TotalMilliseconds}
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
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 24 | Out-Null
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';Pin $PSCommandPath
    foreach($path in @('native-dependencies.json','existing-khc-tests.rs','CLI_REGRESSION_20261007.md')){Pin (Join-Path $PSScriptRoot $path)}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.rs'){Pin $file.FullName}
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $root 'tests') -File -Filter 'khc_*.rs'){Pin $file.FullName}
    foreach($path in @('Cargo.toml','Cargo.lock','build.rs')){Pin (Join-Path $root $path)}
    $nativeRoot=Join-Path $root 'build/khc-row-copy-pruned-rans-native-a-20261007'
    $nativeProof=Join-Path $nativeRoot 'report.json';Pin $nativeProof '58511CE39BA8238B33D28E3B711910204080C9C7CAC84F98A0AB17DE8FD99A5C'
    $prior=Get-Content -LiteralPath $nativeProof -Raw|ConvertFrom-Json -DateKind String
    if($prior.status -ne 'completed' -or -not $prior.data.native_trial_frame_exact -or -not $prior.data.native_archive.all_bytes_exact){throw 'native proof prerequisite'}
    foreach($pin in $pins|Where-Object {$_.path.StartsWith((Join-Path $root 'src')+[IO.Path]::DirectorySeparatorChar) -and $_.path -ne (Join-Path $root 'src/main.rs')}){
        $old=@($prior.pins|Where-Object path -eq $pin.path)
        if($old.Count -ne 1 -or $old[0].SHA256 -ne $pin.SHA256 -or $old[0].bytes -ne $pin.bytes -or $old[0].mtime -cne $pin.mtime){throw 'native library source drift'}
    }
    $report.library_source_exact=$true;$report.CLI_comment_update='revision-2 -> revision-2/3 help; library unchanged'
    $library=Join-Path $nativeRoot 'libunlhare.rlib';Pin $library 'BF50A95F66645A60156F89C8C8833D7D65DCA0448E3F15A1731BA4176303DC30'
    $deps=Get-Content (Join-Path $PSScriptRoot 'native-dependencies.json') -Raw|ConvertFrom-Json
    Pin $deps.manifest $deps.manifest_SHA256
    foreach($dep in $deps.dependencies){Pin $dep.path $dep.SHA256}
    foreach($file in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $file.FullName}
    $w52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
    $w53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
    Pin (Join-Path $w52 'windows.0.52.0.lib');Pin (Join-Path $w53 'windows.0.53.0.lib')
    $fixed=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    Pin $fixed '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    $source=Join-Path $nativeRoot 'fixture/source';Chain $source
    foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File){Pin $file.FullName}
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'Cargo cap'}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $manifestRoot=Join-Path $work 'fixture-manifest';$null=New-Item -ItemType Directory -Path $manifestRoot
    [Environment]::SetEnvironmentVariable('CARGO_MANIFEST_DIR',$manifestRoot,'Process')
    $version=[regex]::Match((Get-Content (Join-Path $root 'Cargo.toml') -Raw),'(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
    if($version -ne '1.0.4'){throw 'package version changed'}
    [Environment]::SetEnvironmentVariable('CARGO_PKG_VERSION',$version,'Process')
    [Environment]::SetEnvironmentVariable('CARGO_PKG_NAME','unlhare','Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_E2E_ROOT',$null,'Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_FIXED_INPUT',$fixed,'Process')
    $common=@('--edition=2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$w52",'-L',"native=$w53",'--extern',"unlhare=$library")
    foreach($dep in $deps.dependencies){$common+=@('--extern',($dep.crate+'='+$dep.path))}
    $cli=Join-Path $work 'unlhare-cli.exe'
    Write-Output 'standalone current CLI with verified native rlib'
    $report.build=Child $rustc (@('--crate-name','unlhare_cli',(Join-Path $root 'src/main.rs'))+$common+@('-o',$cli)) 536870912
    Pin $cli;$report.CLI=@{path=$cli;SHA256=(Get-FileHash $cli).Hash;bytes=(Get-Item $cli).Length}
    $help=Child $cli @('khc-create','--help') 67108864
    if($help.stdout -notmatch 'record-trial'){throw 'CLI strategy absent'}
    $invalid=Child $cli @('khc-create','bad.khc','--source',$source,'--strategy','unknown') 67108864 2
    $archive=Join-Path $work 'cli-record.khc';$output=Join-Path $work 'cli-output'
    $runs=[Collections.Generic.List[object]]::new()
    foreach($arguments in @(@('khc-create',$archive,'--source',$source,'--strategy','record-trial'),@('khc-list',$archive,'--json'),@('khc-test',$archive),@('khc-extract',$archive,'--output',$output))){
        $runs.Add((Child $cli $arguments 67108864))
    }
    if(@($runs[1].stdout|ConvertFrom-Json).Count -ne 6){throw 'CLI list coverage'}
    foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File){
        $relative=[IO.Path]::GetRelativePath($source,$file.FullName);$outFile=Join-Path $output $relative
        if((Get-FileHash -LiteralPath $outFile).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash -or (Get-Item -LiteralPath $outFile).Length -ne $file.Length){throw 'CLI byte hash/length'}
    }
    $report.CLI_runs=$runs;$report.CLI_help=$help.stdout;$report.invalid_strategy_rejected=$true;$report.CLI_bytes_exact=$true
    [Environment]::SetEnvironmentVariable('CARGO_BIN_EXE_unlhare-cli',$cli,'Process')
    $exe=Join-Path $work 'existing-khc-tests.exe'
    Write-Output 'existing 7 source files / Windows 9 E2E; no new unit tests'
    $report.test_build=Child $rustc (@('--crate-name','existing_khc_e2e','--test',(Join-Path $PSScriptRoot 'existing-khc-tests.rs'))+$common+@('-o',$exe)) 536870912
    Pin $exe
    $report.tests=Child $exe @('--test-threads=1') 67108864
    if($report.tests.stdout -notmatch 'test result: ok\. 9 passed; 0 failed; 0 ignored'){throw 'existing test coverage'}
    $evidence=@(Get-ChildItem -LiteralPath $manifestRoot -Recurse -File -Filter result.json)
    if($evidence.Count -ne 7){throw 'existing E2E evidence coverage'}
    $report.test_evidence=@(foreach($file in $evidence){@{path=$file.FullName;bytes=$file.Length;SHA256=(Get-FileHash $file.FullName).Hash;data=Get-Content $file.FullName -Raw|ConvertFrom-Json}})
    $block=@($report.test_evidence|Where-Object {$_.path -match 'block-normal-'})
    if($block.Count -ne 1 -or -not $block[0].data.fixed_not_larger_than_baseline -or $block[0].data.fixed_frame_bytes.Count -ne 3){throw 'fixed corpus not checked'}
    $report.fixture_bytes=[long]((Get-ChildItem -LiteralPath $manifestRoot -Recurse -File|Measure-Object Length -Sum).Sum)+[long]((Get-ChildItem -LiteralPath $output -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.fixture_bytes -gt 8388608){throw 'fixture budget'}
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 16 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
        & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 24 | Out-Null
        [ordered]@{status=$report.status;failure=$report.failure;report=$path;SHA256=(Get-FileHash $path).Hash}|ConvertTo-Json -Compress
    }else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}

