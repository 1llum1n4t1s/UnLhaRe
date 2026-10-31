#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$LibrarySha256,
    [ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='contract-c')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-program-rans-$Attempt-20261006"
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
$report=[ordered]@{status='starting';kind='current_program_scalar_rans_strict_fallback_contract';timing_is_speed_evidence=$false;raw_frame_disk=0;results=$results;pins=$pins;build=$null;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;helper_RAM=67108864;compiler_RAM=536870912;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
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
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';Pin $crc '55457337A3D05ED2B2286381B39760C46AF4CEA9834EFE89B07AA1AB487444C9';Pin (Join-Path $PSHOME 'pwsh.exe')
    foreach($path in @('probe_b.rs','compare_c.ps1','candidate_block.rs','baseline_block.rs','PLAN_20261006.md')){Pin (Join-Path $PSScriptRoot $path)}
    Pin (Join-Path $PSScriptRoot '../mdl-rans/entropy.rs') 'F08C18C547FDB7C505C2DFF24F36F049D016149F090007FE8340AD6F1ACF99EE'
    foreach($path in @('Cargo.toml','Cargo.lock','src/lib.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $path)}
    Pin $library $LibrarySha256;Chain $hostDependency
    foreach($macro in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $macro.FullName}
    Pin (Join-Path $windows52 'windows.0.52.0.lib');Pin (Join-Path $windows53 'windows.0.53.0.lib')
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $path.FullName}
    $original=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    foreach($name in @('baseline_block.rs','candidate_block.rs')){
        $block=Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw
        $expectedPaths=if($name -eq 'baseline_block.rs'){14}else{15}
        if([regex]::Matches($block,'(?m)^#\[path = "[^"]+"\]').Count -ne $expectedPaths){throw 'block child paths'}
        $block=[regex]::Replace($block,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
        if($name -eq 'candidate_block.rs'){
            $block=$block.Replace('b"KRS1BLK\0"','b"KHC1BLK\0"').Replace('mdl_entropy::Encoder','multi_range::Encoder').Replace('mdl_entropy::Decoder','multi_range::Decoder')
            $block=[regex]::Replace($block,'(?m)^pub\(crate\) mod mdl_entropy;\r?\n','')
            $block=[regex]::Replace($block,'(?m)^    pub journal_(capacity|events|transient): usize,\r?\n','')
            $block=[regex]::Replace($block,'(?ms)^ *// ANS (RESERVE|CAPACITY|FALLBACK) BEGIN\r?\n.*?^ *// ANS \1 END\r?\n','')
        }
        if([regex]::Replace($original,'\s','') -cne [regex]::Replace($block,'\s','')){throw 'block outside current Program/entropy scope'}
    }
    $report.normalized_current_product=$true
    $report.cargo_before=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'shared Cargo cap'}
    $archive=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc';Pin $archive 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$entries=@($manifest|Where-Object name -eq 'canterbury-development');if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'corpus manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $exe=Join-Path $root 'build/khc-program-rans-contract-b-20261006/probe.exe'
    Pin $exe '00309B01E00242EC5F4C95B9BE3467DE53A51F6883C4A6946702E0676B8D1C90'
    $report.build=@{reused=$true;source_report='build/khc-program-rans-contract-b-20261006/report.json';exe_SHA256='00309B01E00242EC5F4C95B9BE3467DE53A51F6883C4A6946702E0676B8D1C90'}

    $finiteRun=Child $exe @('--contract') 67108864
    $finite=$finiteRun.stdout|ConvertFrom-Json
    if(-not $finite.byte_exact -or $finite.coder_sequences -ne 66 -or $finite.coder_rejections -ne 25 -or $finite.finite_raw_cases -ne 29 -or $finite.finite_encodings -ne 58 -or $finite.oversize_rejects -ne 2 -or $finite.journal_fallbacks -ne 1 -or -not $finite.journal_fallback_state_valid){throw 'finite contract'}
    $finiteRun.Remove('stdout');$finiteRun.Remove('stderr');$report.finite_run=$finiteRun;$report.finite=$finite
    $report.cargo_after=[long]((Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo') -File -Recurse|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before -or $report.cargo_after -gt 6175228536){throw 'Cargo changed during standalone profile'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}






