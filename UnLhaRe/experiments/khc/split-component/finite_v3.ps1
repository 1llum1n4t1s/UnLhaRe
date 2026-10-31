#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,24}$')][string]$Attempt='a',[switch]$Reordered)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-split-component-v3-$Attempt-20261006"
$rustc='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$library=Join-Path $dependency 'libunlhare.rlib'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$windows52='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib'
$windows53='C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib'
$exe=Join-Path $work 'probe.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{guard_enumeration_retries=0;guard_events=[Collections.Generic.List[object]]::new();measurements=[Collections.Generic.List[object]]::new();quiet_samples=[Collections.Generic.List[object]]::new();reordered=[bool]$Reordered;status='starting';kind='split_component_finite_performance';timing_evidence=$false;not_native_archive=$true;pins=$pins;failure=$null;build=$null;run=$null;live_pins_unchanged=$false}
function Pin([string]$path,[string]$expected=''){
    $path=[IO.Path]::GetFullPath($path);$p=$path
    while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse pin'}};$p=[IO.Path]::GetDirectoryName($p)}
    $locks.Add([IO.File]::Open($path,'Open','Read','Read'));$file=Get-Item -LiteralPath $path;$sha=(Get-FileHash -LiteralPath $path).Hash
    if($expected -and $sha -cne $expected){throw 'pin identity'}
    $pins.Add(@{path=$path;SHA256=$sha;bytes=$file.Length;mtime=$file.LastWriteTimeUtc.ToString('o')})
}
function Guard{
    if($clock.Elapsed.TotalSeconds -ge 180){throw 'suite deadline'}
    if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120+8388608){throw 'free guard'}
    if($created){
        $nodes=$null
        for($attempt=0;$attempt -lt 3;$attempt++){
            try{$nodes=@(Get-ChildItem -LiteralPath $work -Recurse -Force -ErrorAction Stop);break}
            catch{
                $io=$false;$exception=$_.Exception
                for($depth=0;$exception -and $depth -lt 4;$depth++){
                    if($exception -is [IO.IOException] -or $exception -is [UnauthorizedAccessException]){$io=$true}
                    $exception=$exception.InnerException
                }
                if($report.guard_events.Count -lt 8){$report.guard_events.Add(@{type=$_.Exception.GetType().FullName;category=[string]$_.CategoryInfo.Category;id=$_.FullyQualifiedErrorId})}
                if(-not $io -or $attempt -eq 2){throw}
                $report.guard_enumeration_retries++;Start-Sleep -Milliseconds 10
            }
        }
        if($nodes|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'reparse output'}
        $f=@($nodes|Where-Object {-not $_.PSIsContainer})
        if($f.Count -and ($f|Measure-Object Length -Sum).Sum -gt 8388608){throw 'output bound'}
    }
}
function Quiet {
    $timer=[Diagnostics.Stopwatch]::StartNew();$last=$null;$samples=0
    while($true){
        Guard;$cpu=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
        if($null -eq $cpu -or $null -eq $cpu.PercentProcessorTime){throw 'CPU metric unavailable'}
        $last=[int]$cpu.PercentProcessorTime;$samples++
        if($last -le 15){$report.quiet_samples.Add(@{accepted_percent=$last;wait_ms=$timer.Elapsed.TotalMilliseconds;samples=$samples});return}
        if($timer.Elapsed.TotalSeconds -ge 60){$report.quiet_samples.Add(@{accepted_percent=$null;last_percent=$last;wait_ms=$timer.Elapsed.TotalMilliseconds;samples=$samples});throw 'CPU quiet timeout'}
        Start-Sleep -Milliseconds 500
    }
}
function Median($array) { $sorted=@($array|Sort-Object);if($sorted.Count -ne 9){throw '9 samples required'};return [double]$sorted[4] }

function Child([string]$file,[string[]]$arguments,[long]$ram){
    Guard;$i=[Diagnostics.ProcessStartInfo]::new();$i.FileName=$file;$i.WorkingDirectory=$root;$i.UseShellExecute=$false;$i.CreateNoWindow=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
    foreach($arg in $arguments){$i.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$i;$started=$false;$t=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{
        if(-not $p.Start()){throw 'child start'};$started=$true;$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        while(-not $p.WaitForExit(20)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'RAM bound'};if($t.Elapsed.TotalSeconds -ge 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt $ram -or $private -gt $ram){throw 'final RAM bound'};Guard
        $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult();if($o.Length -gt 16384 -or $e.Length -gt 16384){throw 'text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $e"}
        return @{stdout=$o;stderr=$e;max_WS=$ws;max_private=$private;diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds}
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'termination timeout'}};$p.Dispose()}
}
try{
    if($Reordered){throw 'finite safety only'}
    if(Test-Path -LiteralPath $work){throw 'unused work required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
    Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md');Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'probe_v3.rs');Pin (Join-Path $PSScriptRoot 'candidate_block_v2.rs');Pin (Join-Path $PSScriptRoot 'scope.json');Pin (Join-Path $PSScriptRoot '../mdl-rans/baseline_block.rs');Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md')
    Pin $rustc 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Pin $library '94A19BFD6C0AFD23D7C0453760C51B596D9BFA2C7CBE983BBFA15F6111572AC4'
    Pin $crc '55457337A3D05ED2B2286381B39760C46AF4CEA9834EFE89B07AA1AB487444C9'
    foreach($name in @('Cargo.toml','Cargo.lock','src/lib.rs','experiments/khc/CORPUS_MANIFEST.json')){Pin (Join-Path $root $name)}
    foreach($s in Get-ChildItem -LiteralPath (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $s.FullName}
    foreach($macro in Get-ChildItem -LiteralPath $hostDependency -File -Filter '*.dll'){Pin $macro.FullName}
    Pin (Join-Path $windows52 'windows.0.52.0.lib');Pin (Join-Path $windows53 'windows.0.53.0.lib');Pin (Join-Path $PSHOME 'pwsh.exe')
    $manifest=Get-Content -LiteralPath (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json
    $corpus=@($manifest|Where-Object name -eq 'canterbury-development');if($corpus.Count -ne 1 -or $corpus[0].files.Count -ne 11){throw 'corpus shape'}
    $inputs=@(foreach($entry in $corpus[0].files){$path=Join-Path $root ('build/khc-corpus/canterbury-development/'+$entry.name);Pin $path $entry.sha256;if((Get-Item -LiteralPath $path).Length -ne $entry.bytes){throw 'corpus bytes'};$path})
    $candidate=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate_block_v2.rs') -Raw
    foreach($marker in @('HELPERS','CONTRACT')){
        $candidate=[regex]::Replace($candidate,"(?ms)^[ \t]*// SPLIT $marker BEGIN\r?\n.*?^[ \t]*// SPLIT $marker END\r?\n",'')
    }
    $scope=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scope.json') -Raw|ConvertFrom-Json
    foreach($item in $scope){
        $pattern="(?ms)^[ \t]*// SPLIT $($item.id) BEGIN\r?\n.*?^[ \t]*// SPLIT $($item.id) END"
        if([regex]::Matches($candidate,$pattern).Count -ne 1){throw 'split scope marker'}
        $replacement=$item.old
        $candidate=[regex]::Replace($candidate,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match) $replacement})
    }
    if([regex]::Matches($candidate,'(?m)^#\[path = "[^"]+"\]').Count -ne 13){throw 'block child count'}
    $candidate=[regex]::Replace($candidate,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
    $product=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    if([regex]::Replace($candidate,'\s','') -cne [regex]::Replace($product,'\s','')){throw 'block scope mismatch'}
    $report.normalized_current_product=$true
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    if($Reordered){
        $previous=Join-Path $root 'build/khc-split-component-v3-a-20261006/report.json'
        Pin $previous
        $oldReport=Get-Content -LiteralPath $previous -Raw|ConvertFrom-Json
        if($oldReport.status -ne 'completed' -or -not $oldReport.live_pins_unchanged -or -not $oldReport.performance_gate.passed -or $oldReport.reordered){throw 'reverse requires successful normal screen'}
        $compiled=@($oldReport.pins|Where-Object path -like '*probe.exe')
        if($compiled.Count -ne 1){throw 'compiled identity'}
        foreach($pin in $oldReport.pins){Pin $pin.path $pin.SHA256}
        $exe=$compiled[0].path
        $report.build=@{reused=$compiled[0];normal_report_SHA256=(Get-FileHash -LiteralPath $previous).Hash}
    } else {
    $report.build=Child $rustc @('--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$windows52",'-L',"native=$windows53",'--extern',"unlhare=$library",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'probe_v3.rs'),'-o',$exe) 536870912
    }
    Pin $exe
    $run=Child $exe $inputs 67108864;$data=$run.stdout|ConvertFrom-Json
    if(-not $data.byte_exact -or $data.numeric_contracts -ne 28 -or $data.finite_raw_cases -ne 49 -or $data.files -ne 11 -or $data.rows.Count -ne 11 -or $data.malformed_decoder_checks -lt 246 -or $data.normalize_truncations -lt 1 -or $data.component_gap_checks -ne 4 -or $data.rejected_decoder_checks -lt 238 -or $data.timing_evidence){throw 'finite cost/codec coverage'}
    if($data.old_frames -ne 465951 -or ($data.rows.old_bytes|Measure-Object -Sum).Sum -ne $data.old_frames -or ($data.rows.new_bytes|Measure-Object -Sum).Sum -ne $data.new_frames){throw 'current frame baseline/sum'}
    $rows=@();$index=0;foreach($entry in $corpus[0].files){
        $row=$data.rows[$index];if($row.index -ne $index -or $row.raw -ne $entry.bytes -or $row.stream_events -gt 16*($row.raw+1)){throw 'row extent/stream count'}
        $rows+=@{name=$entry.name;data=$row};$index++
    }
    $report.run=@{data=$data;named_rows=$rows;max_WS=$run.max_WS;max_private=$run.max_private;diagnostic_wall_ms=$run.diagnostic_wall_ms}
    $regressions=@($data.rows|Where-Object {
        ($_.old_method -eq 1 -and ($_.new_method -ne 1 -or $_.new_bytes-$_.old_bytes -gt 16)) -or
        ($_.old_method -ne 1 -and $_.new_bytes -ne $_.old_bytes)})
    $report.screen=@{old_frames=$data.old_frames;new_frames=$data.new_frames;extra_bytes=$data.new_frames-$data.old_frames;per_file_regressions=$regressions.Count;passed=($data.new_frames-$data.old_frames -le 128 -and $regressions.Count -eq 0);not_GOAL_completion=$true}
    $report.skipped_timing='independent safety supplement only; normal performance rejected'
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -cne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;foreach($lock in $locks){$lock.Dispose()};if(-not $same){$report.status='pin_mismatch'}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($bytes.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null;@{status=$report.status;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}
}
if($report.status -ne 'completed'){exit 1}
