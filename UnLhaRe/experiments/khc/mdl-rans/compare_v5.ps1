#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='screen-c',[switch]$Reordered,[string]$ReuseReportSHA256='',[string]$ReusePartialReportSHA256='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-mdl-rans-$Attempt-20261006"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$windows52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
$windows53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$library=Join-Path $dependency 'libunlhare.rlib'
$exe=Join-Path $work 'compare.exe'
$partial=@()
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='static_MDL_multi_symbol_rANS_ablation';reordered=[bool]$Reordered;not_public_seven_zip_speed=$true;raw_frame_disk=0;results=$results;pins=$pins;build=$null;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;helper_RAM=67108864;compiler_RAM=536870912;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
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
    Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'NULL_FIX_20261006.md');Pin (Join-Path $PSScriptRoot 'TIMING_FIX_20261006.md');Pin (Join-Path $PSScriptRoot 'IDENTITY_FIX_20261006.md')
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';Pin $crc '55457337A3D05ED2B2286381B39760C46AF4CEA9834EFE89B07AA1AB487444C9';Pin (Join-Path $PSHOME 'pwsh.exe')
    foreach($name in @('PLAN_20261006.md','COMPILE_FIX_20261006.md','compare_v2.rs','entropy.rs','baseline_block.rs','candidate_block_v2.rs','compare_v2.ps1')){Pin (Join-Path $PSScriptRoot $name)}
    Pin (Join-Path $root 'experiments/khc/decode-phase/MDL_ENTROPY_PLAN_20261006.md')
    foreach($name in @('Cargo.toml','Cargo.lock','src/lib.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $name)}
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $path.FullName}
    Pin $library '94A19BFD6C0AFD23D7C0453760C51B596D9BFA2C7CBE983BBFA15F6111572AC4'
    Chain $hostDependency;foreach($macro in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $macro.FullName}
    Pin (Join-Path $windows52 'windows.0.52.0.lib');Pin (Join-Path $windows53 'windows.0.53.0.lib')
    $original=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    foreach($name in @('baseline_block.rs','candidate_block_v2.rs')){
        $copy=Get-Content -LiteralPath (Join-Path $PSScriptRoot $name) -Raw
        if($name -eq 'candidate_block_v2.rs'){
            foreach($marker in @('MODULE','STATS','RESERVE','FALLBACK','CAPACITY')){
                if([regex]::Matches($copy,"ANS $marker BEGIN").Count -ne 1 -or [regex]::Matches($copy,"ANS $marker END").Count -ne 1){throw 'candidate markers'}
                $copy=[regex]::Replace($copy,"(?ms)^[ \t]*// ANS $marker BEGIN\r?\n.*?^[ \t]*// ANS $marker END\r?\n",'')
            }
            $copy=$copy.Replace('mdl_entropy::','multi_range::').Replace('b"KHA1BLK\0"','b"KHC1BLK\0"')
            $copy=$copy.Replace('// 既存output上限と明示journal上限のみfallback。allocation/model/state errorは伝播する。','// 唯一許可するfallback error。allocation/model/state errorは伝播する。')
        }
        if([regex]::Matches($copy,'(?m)^#\[path = "[^"]+"\]').Count -ne 13){throw 'path scope'}
        $copy=[regex]::Replace($copy,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
        if([regex]::Replace($original,'\s','') -cne [regex]::Replace($copy,'\s','')){throw 'candidate scope mismatch'}
    }
    $report.normalized_current_product=$true
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    if($Reordered -or $ReusePartialReportSHA256){
        $previousPath=if($Reordered){Join-Path $root 'build/khc-mdl-rans-screen-c-20261006/report.json'}else{Join-Path $root 'build/khc-mdl-rans-screen-b-20261006/report.json'}
        $expectedSHA=if($Reordered){$ReuseReportSHA256}else{$ReusePartialReportSHA256}
        if($expectedSHA -notmatch '^[A-F0-9]{64}$'){throw 'previous report SHA required'}
        Pin $previousPath $expectedSHA
        $previous=Get-Content -LiteralPath $previousPath -Raw|ConvertFrom-Json
        if(-not $previous.live_pins_unchanged -or -not $previous.normalized_current_product){throw 'previous source/build not verified'}
        if($Reordered){if($previous.status -ne 'completed'){throw 'previous result not complete'}}
        else{
            if($previous.status -ne 'failed' -or $previous.failure -cne 'timing coverage' -or $previous.results.Count -ne 11 -or -not $previous.finite.data.byte_exact){throw 'specific partial recovery only'}
            $partial=$previous.results;$report.reused_partial_results=@{source=$previousPath;SHA256=$expectedSHA;count=11;no_sample_replacement=$true}
        }
        foreach($pin in $previous.pins){Pin $pin.path $pin.SHA256}
        $compiled=@($previous.pins|Where-Object path -like '*compare.exe')
        if(-not $compiled.Count){throw 'compiled identity'}
        $identity=$compiled[0]
        foreach($entry in $compiled){
            if($entry.path -cne $identity.path -or $entry.SHA256 -cne $identity.SHA256 -or $entry.bytes -ne $identity.bytes -or $entry.mtime -cne $identity.mtime){throw 'conflicting compiled identity'}
        }
        $exe=$identity.path
        $report.compiled_identity_records=$compiled.Count
        $report.build=@{reused_compilation=$previousPath;original_build=$previous.build}
    }else{throw 'explicit frozen compilation reuse required'}
    Pin $exe;Write-Output 'compiled or verified diagnostic'
    $finite=Child $exe @('--contract') 67108864;$contract=$finite.stdout|ConvertFrom-Json
    if(-not $contract.byte_exact -or $contract.coder_sequences -ne 66 -or $contract.coder_rejections -lt 20 -or $contract.finite_raw_cases -ne 27 -or $contract.finite_MDL -le 0 -or $contract.journal_limit_events -ne 2097152 -or $contract.malformed_cases -lt 2500 -or $contract.rejected -le 2000){throw 'finite E2E coverage'}
    $report.finite=@{data=$contract;max_WS=$finite.max_WS;max_private=$finite.max_private;wall_ms=$finite.wall_ms}
    Write-Output 'finite entropy/frame contract completed'
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$corpus=@($manifest|Where-Object name -eq 'canterbury-development');if($corpus.Count -ne 1 -or $corpus[0].files.Count -ne 11){throw 'manifest shape'}
    $cases=@(foreach($entry in $corpus[0].files){$path=Join-Path $root ('build/khc-corpus/canterbury-development/'+$entry.name);Pin $path $entry.sha256;if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or $entry.bytes -gt 1048576){throw 'input extent'};@{name=$entry.name;arg=$path;bytes=$entry.bytes;SHA256=$entry.sha256}})
    $cases+=@(@{name='empty';arg='--empty';bytes=0;SHA256='synthetic empty'},@{name='one';arg='--one';bytes=1;SHA256='synthetic [165]'})
    if($Reordered){[array]::Reverse($cases)}
    foreach($case in $cases){
        $arguments=@($case.arg);if($Reordered){$arguments+='--reverse'}
        $saved=@($partial|Where-Object name -eq $case.name)
        if($saved.Count){
            if($Reordered -or $saved.Count -ne 1 -or $saved[0].input_SHA256 -ne $case.SHA256){throw 'partial identity'}
            $data=$saved[0].data;$r=@{max_WS=$saved[0].max_WS;max_private=$saved[0].max_private;wall_ms=$saved[0].wall_ms}
        }else{$r=Child $exe $arguments 67108864;$data=$r.stdout|ConvertFrom-Json}
        if(-not $data.byte_exact -or $data.raw_bytes -ne $case.bytes -or $data.old_bytes -gt $case.bytes+40 -or $data.new_bytes -gt $case.bytes+40 -or $data.old_method -notin 0,1,2,3 -or $data.new_method -notin 0,1,2,3 -or $data.reversed -ne [bool]$Reordered){throw 'result contract'}
        $tiny=($case.bytes -le 1 -and $data.old_method -eq 0 -and $data.new_method -eq 0)
        foreach($field in @('old_encode_ns','new_encode_ns','old_decode_ns','new_decode_ns')){if($data.$field.Count -ne 9 -or @($data.$field|Where-Object {$_ -lt 0 -or (-not $tiny -and $_ -eq 0)}).Count){throw 'timing coverage'}}
        if($data.new_phase_capacity -gt 67108864 -or $data.journal_capacity -gt 12582912 -or $data.journal_events -gt 2097152 -or $data.journal_transient -gt 6291456){throw 'journal capacity'}
        $expected=if($case.bytes -eq 0){96}else{112};if($data.malformed_cases -ne $expected -or $data.rejected -lt 70){throw 'malformed coverage'}
        $results.Add(@{name=$case.name;input_SHA256=$case.SHA256;data=$data;max_WS=$r.max_WS;max_private=$r.max_private;wall_ms=$r.wall_ms});Write-Output ('completed '+$case.name)
    }
    if($results.Count -ne 13){throw 'full coverage'};$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
