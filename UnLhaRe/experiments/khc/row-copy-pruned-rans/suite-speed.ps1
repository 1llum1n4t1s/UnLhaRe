#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$LibrarySha256,
    [ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='suite-normal-a',
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ProofSha256,
    [ValidatePattern('^[a-z0-9-]{1,32}$')][string]$ProofAttempt='screen-a', [switch]$Reverse)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-row-copy-pruned-rans-$Attempt-20261007"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$windows52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
$windows53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$library=Join-Path $dependency 'libunlhare.rlib'
$exe=Join-Path $work 'probe.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='row_copy_pruned_single_child_paired_suite';timing_is_speed_evidence=$true;raw_frame_disk=0;results=$results;pins=$pins;build=$null;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;helper_RAM=67108864;compiler_RAM=536870912;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
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
try{
    $policyCases=@(
        @{error=[ComponentModel.Win32Exception]::new(2);expected=$true},
        @{error=[ComponentModel.Win32Exception]::new(3);expected=$true},
        @{error=[IO.FileNotFoundException]::new();expected=$true},
        @{error=[IO.DirectoryNotFoundException]::new();expected=$true},
        @{error=[Exception]::new('wrapped',[ComponentModel.Win32Exception]::new(2));expected=$true},
        @{error=[ComponentModel.Win32Exception]::new(5);expected=$false},
        @{error=[ComponentModel.Win32Exception]::new(32);expected=$false},
        @{error=[ComponentModel.Win32Exception]::new(112);expected=$false})
    foreach($case in $policyCases){if((MissingTransient $case.error) -ne $case.expected){throw 'work scan retry policy'}}
    $report.work_scan_policy=@{cases=$policyCases.Count;missing_only_retry=$true;bounded_scans=3}
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';Pin $crc '55457337A3D05ED2B2286381B39760C46AF4CEA9834EFE89B07AA1AB487444C9';Pin (Join-Path $PSHOME 'pwsh.exe')
    foreach($path in @('speed-suite.rs','suite-speed.ps1','codec.rs','bound.rs','baseline_block.rs','PLAN.md','SUITE_SPEED_PLAN.md')){Pin (Join-Path $PSScriptRoot $path)}
    Pin (Join-Path $PSScriptRoot '../causal-record-vote/voter.rs') '081FB1EF8D42E90710E0E37A01F9F1744EA52133D707D954A4AC4619D322203E'
    Pin (Join-Path $PSScriptRoot '../mdl-rans/entropy.rs')
    Pin (Join-Path $PSScriptRoot '../causal-row-copy/BYTE_ENTROPY_PLAN_20261006.md')
    foreach($path in @('Cargo.toml','Cargo.lock','src/lib.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $path)}
    Pin $library $LibrarySha256;Chain $hostDependency
    foreach($macro in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $macro.FullName}
    Pin (Join-Path $windows52 'windows.0.52.0.lib');Pin (Join-Path $windows53 'windows.0.53.0.lib')
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $path.FullName}
    $original=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    $block=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'baseline_block.rs') -Raw
    if([regex]::Matches($block,'(?m)^#\[path = "[^"]+"\]').Count -ne 14){throw 'baseline child paths'}
    $block=[regex]::Replace($block,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
    if([regex]::Replace($original,'\s','') -cne [regex]::Replace($block,'\s','')){throw 'baseline drift'}
    $report.normalized_current_product=$true
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'shared Cargo cap'}
    $archive=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc';Pin $archive 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$entries=@($manifest|Where-Object name -eq 'canterbury-development');if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'corpus manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    Pin (Join-Path $root "build/khc-row-copy-pruned-rans-$ProofAttempt-20261007/report.json") $ProofSha256
    $proof=Get-Content -LiteralPath (Join-Path $root "build/khc-row-copy-pruned-rans-$ProofAttempt-20261007/report.json") -Raw | ConvertFrom-Json -DateKind String
    if($proof.status -ne 'completed' -or -not $proof.data.size_gate -or -not $proof.data.coded_state_exact -or -not $proof.data.strict_rejection -or -not $proof.data.full_trial_frame_exact -or $proof.data.pruned_trials -le 0){throw 'size/E2E prerequisite'}
    $common=0
    foreach($pin in $pins){
        $matches=@($proof.pins|Where-Object {$_.path -eq $pin.path})
        if($matches.Count -gt 1){throw 'proof duplicate pin'}
        if($matches.Count -eq 1){
            if($matches[0].SHA256 -ne $pin.SHA256 -or $matches[0].bytes -ne $pin.bytes -or $matches[0].mtime -cne $pin.mtime){throw 'screen/speed identity mismatch'}
            $common++
        }
    }
    foreach($required in @((Join-Path $PSScriptRoot 'codec.rs'),(Join-Path $PSScriptRoot 'bound.rs'),(Join-Path $PSScriptRoot 'baseline_block.rs'),(Join-Path $PSScriptRoot '../causal-record-vote/voter.rs'),(Join-Path $PSScriptRoot '../mdl-rans/entropy.rs'),$library,$rustc,$crc)){
        $required=[IO.Path]::GetFullPath($required)
        if(@($proof.pins|Where-Object {[IO.Path]::GetFullPath($_.path) -eq $required}).Count -ne 1 -or @($pins|Where-Object {[IO.Path]::GetFullPath($_.path) -eq $required}).Count -ne 1){throw 'required common pin missing'}
    }
    if($common -lt 40){throw 'too few common identity pins'}
    $report.screen_identity=@{common_pins=$common;SHA256_bytes_mtime_exact=$true;proof_SHA256=$ProofSha256}

    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.build=Child $rustc @('--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$windows52",'-L',"native=$windows53",'--extern',"unlhare=$library",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'speed-suite.rs'),'-o',$exe) 536870912
    Pin $exe;Write-Output 'compiled diagnostic against current child modules'
    function Median($values){$o=@($values|Sort-Object);if($o.Count -ne 9 -or @($o|Where-Object {$_ -le 0}).Count){throw 'timing values'};return [double]$o[4]}
    $suiteArgs=@($(if($Reverse){'reverse'}else{'normal'}))
    foreach($entry in $entries[0].files){$suiteArgs+=(Join-Path $corpus $entry.name)}
    $run=Child $exe $suiteArgs 67108864
    $suite=$run.stdout|ConvertFrom-Json
    if($suite.complete_inputs -ne 11 -or $suite.rows.Count -ne 11){throw 'whole suite coverage'}
    foreach($entry in $entries[0].files){
        $suiteRows=@($suite.rows|Where-Object name -eq $entry.name)
        if($suiteRows.Count -ne 1){throw 'suite duplicate/missing entry'}
        $data=$suiteRows[0].measurement
        $proofRows=@($proof.data.rows|Where-Object name -eq $entry.name)
        if($proofRows.Count -ne 1 -or -not $data.byte_exact -or -not $data.public_baseline_exact -or $data.reversed -ne [bool]$Reverse -or $data.raw_bytes -ne $entry.bytes -or $data.old_bytes -ne $proofRows[0].old_frame -or $data.new_bytes -ne $proofRows[0].new_frame -or $data.new_method -ne $proofRows[0].method -or $data.logical_peak -gt 67108864){throw 'paired frame/coverage/cap contract'}
        $results.Add(@{name=$entry.name;measurement=$data;old_encode_ns=(Median $data.old_encode_ns);new_encode_ns=(Median $data.new_encode_ns);old_decode_ns=(Median $data.old_decode_ns);new_decode_ns=(Median $data.new_decode_ns)})
    }
    $run.Remove('stdout');$run.Remove('stderr');$report.run=$run;$report.single_child=$true

    $oldBytes=0L;$newBytes=0L;$oe=0.0;$ne=0.0;$od=0.0;$nd=0.0
    foreach($row in $results){$oldBytes+=$row.measurement.old_bytes;$newBytes+=$row.measurement.new_bytes;$oe+=$row.old_encode_ns;$ne+=$row.new_encode_ns;$od+=$row.old_decode_ns;$nd+=$row.new_decode_ns}
    if($oldBytes -ne 465951 -or $newBytes -ne $proof.data.new_frame_bytes){throw 'measured aggregate frame drift'}
    $report.summary=@{reversed=[bool]$Reverse;reserved_archive_estimate=$newBytes+700;old_bytes=$oldBytes;new_bytes=$newBytes;old_encode_ms=$oe/1000000;new_encode_ms=$ne/1000000;old_decode_ms=$od/1000000;new_decode_ms=$nd/1000000;passed=($ne -le 1.10*$oe -and $nd -le $od)}
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before -or $report.cargo_after -gt 6175228536){throw 'Cargo changed during standalone profile'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
















