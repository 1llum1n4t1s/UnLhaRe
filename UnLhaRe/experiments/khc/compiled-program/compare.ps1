#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,24}$')][string]$Attempt='a',[switch]$Reordered)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-compiled-program-$Attempt-20261006"
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
$report=[ordered]@{guard_enumeration_retries=0;guard_events=[Collections.Generic.List[object]]::new();measurements=[Collections.Generic.List[object]]::new();quiet_samples=[Collections.Generic.List[object]]::new();reordered=[bool]$Reordered;status='starting';kind='compiled_program_finite_performance';timing_evidence=$false;not_native_archive=$true;pins=$pins;failure=$null;build=$null;run=$null;live_pins_unchanged=$false}
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
    if(Test-Path -LiteralPath $work){throw 'unused work required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
    Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md');Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'probe.rs');Pin (Join-Path $PSScriptRoot 'candidate_block.rs');Pin (Join-Path $PSScriptRoot 'scope.json');Pin (Join-Path $PSScriptRoot 'compiled_packet.rs');Pin (Join-Path $PSScriptRoot 'program.rs');Pin (Join-Path $PSScriptRoot '../mdl-rans/baseline_block.rs');Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md')
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
    $candidate=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'candidate_block.rs') -Raw
    $candidate=[regex]::Replace($candidate,'(?ms)^// PROGRAM CONTRACT BEGIN\r?\n.*?^// PROGRAM CONTRACT END\r?\n','')
    $scope=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scope.json') -Raw|ConvertFrom-Json
    foreach($item in $scope){
        $pattern="(?ms)^[ \t]*// PROGRAM $($item.id) BEGIN\r?\n.*?^[ \t]*// PROGRAM $($item.id) END"
        if([regex]::Matches($candidate,$pattern).Count -ne 1){throw 'program scope marker'}
        $replacement=$item.old
        $candidate=[regex]::Replace($candidate,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match) $replacement})
    }
    if([regex]::Matches($candidate,'(?m)^#\[path = "[^"]+"\]').Count -ne 13){throw 'block child count'}
    $candidate=[regex]::Replace($candidate,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
    $product=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    if([regex]::Replace($candidate,'\s','') -cne [regex]::Replace($product,'\s','')){throw 'block scope mismatch'}
    $packet=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'compiled_packet.rs') -Raw
    foreach($marker in @('FOREST','NUMERIC')){
        $packet=[regex]::Replace($packet,"(?ms)^// PROGRAM $marker BEGIN\r?\n.*?^// PROGRAM $marker END\r?\n",'')
    }
    $productPacket=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/packet.rs') -Raw
    if([regex]::Replace($packet,'\s','') -cne [regex]::Replace($productPacket,'\s','')){throw 'packet scope mismatch'}
    $report.normalized_current_product=$true
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    if($Reordered){
        $previous=Join-Path $root 'build/khc-compiled-program-a-20261006/report.json'
        Pin $previous
        $oldReport=Get-Content -LiteralPath $previous -Raw|ConvertFrom-Json
        if($oldReport.status -ne 'completed' -or -not $oldReport.live_pins_unchanged -or -not $oldReport.performance_gate.passed -or $oldReport.reordered){throw 'reverse requires successful normal screen'}
        $compiled=@($oldReport.pins|Where-Object path -like '*probe.exe')
        if($compiled.Count -ne 1){throw 'compiled identity'}
        foreach($pin in $oldReport.pins){Pin $pin.path $pin.SHA256}
        $exe=$compiled[0].path
        $report.build=@{reused=$compiled[0];normal_report_SHA256=(Get-FileHash -LiteralPath $previous).Hash}
    } else {
    $report.build=Child $rustc @('--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$windows52",'-L',"native=$windows53",'--extern',"unlhare=$library",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'probe.rs'),'-o',$exe) 536870912
    }
    Pin $exe
    $run=Child $exe $inputs 67108864;$data=$run.stdout|ConvertFrom-Json
    if(-not $data.byte_exact -or $data.numeric_contracts -ne 532152 -or $data.cdf_rows -ne 6979584 -or $data.geometry_routes -ne 66049 -or $data.geometry_shapes -ne 72846 -or $data.gap_checks -ne 2 -or $data.normalize_checks -ne 2 -or $data.finite_raw_cases -ne 49 -or $data.files -ne 11 -or $data.rows.Count -ne 11 -or $data.malformed_decoder_checks -ne 684 -or $data.rejected_decoder_checks -lt 600 -or $data.timing_evidence){throw 'finite cost/codec coverage'}
    if($data.old_frames -ne 465951 -or ($data.rows.old_bytes|Measure-Object -Sum).Sum -ne $data.old_frames -or ($data.rows.new_bytes|Measure-Object -Sum).Sum -ne $data.new_frames){throw 'current frame baseline/sum'}
    $rows=@();$index=0;foreach($entry in $corpus[0].files){
        $row=$data.rows[$index];if($row.index -ne $index -or $row.raw -ne $entry.bytes -or $row.comparisons -gt $row.raw*64 -or $row.first_budget_position -gt $row.raw -or $row.changed -gt $row.choices -or $row.shorter -gt $row.changed){throw 'row extent/budget'}
        $rows+=@{name=$entry.name;data=$row};$index++
    }
    $report.run=@{data=$data;named_rows=$rows;max_WS=$run.max_WS;max_private=$run.max_private;diagnostic_wall_ms=$run.diagnostic_wall_ms}
    $regressions=@($data.rows|Where-Object {$_.new_bytes*100 -gt $_.old_bytes*101})
    $report.screen=@{rate_reduction_percent=100.0*(1.0-$data.new_frames/$data.old_frames);required_identical=$true;per_file_regressions=$regressions.Count;passed=($data.new_frames -eq $data.old_frames -and $regressions.Count -eq 0);not_GOAL_completion=$true}
    $indices=0..10;if($Reordered){[array]::Reverse($indices)}
    $report.execution_indices=@($indices)
    foreach($index in $indices){
        Quiet
        $measurement=Child $exe @('--measure',$inputs[$index],$(if($Reordered){'reverse'}else{'normal'})) 67108864
        $data=$measurement.stdout|ConvertFrom-Json
        if(-not $data.byte_exact -or $data.raw -ne $corpus[0].files[$index].bytes -or $data.reversed -ne [bool]$Reordered -or $data.bytes -ne $report.run.data.rows[$index].old_bytes -or $data.method -ne $report.run.data.rows[$index].old_method){throw 'timing identity'}
        foreach($field in @('old_encode_ns','new_encode_ns','old_decode_ns','new_decode_ns')){
            if($data.$field.Count -ne 9 -or @($data.$field|Where-Object {$_ -le 0}).Count){throw 'positive timing samples'}
        }
        $report.measurements.Add(@{index=$index;name=$corpus[0].files[$index].name;data=$data;WS=$measurement.max_WS;private=$measurement.max_private;diagnostic_wall_ms=$measurement.diagnostic_wall_ms})
        Write-Output ('measured '+$corpus[0].files[$index].name)
    }
    $mdl=@($report.measurements|Where-Object {$_.data.method -eq 1})
    if($mdl.Count -ne 8 -or $report.measurements.Count -ne 11){throw 'timing classification'}
    $oe=0.0;$ne=0.0;$od=0.0;$nd=0.0;$regressions=0
    foreach($row in $mdl){
        $oe+=Median $row.data.old_encode_ns;$ne+=Median $row.data.new_encode_ns
        $oldDecode=Median $row.data.old_decode_ns;$newDecode=Median $row.data.new_decode_ns
        $od+=$oldDecode;$nd+=$newDecode;if($newDecode -ge $oldDecode*1.10){$regressions++}
    }
    $oldPairEncode=@();$newPairEncode=@();$oldPairDecode=@();$newPairDecode=@()
    for($pair=0;$pair -lt 9;$pair++){
        $peo=0.0;$pen=0.0;$pdo=0.0;$pdn=0.0
        foreach($row in $mdl){
            $peo+=$row.data.old_encode_ns[$pair];$pen+=$row.data.new_encode_ns[$pair]
            $pdo+=$row.data.old_decode_ns[$pair];$pdn+=$row.data.new_decode_ns[$pair]
        }
        $oldPairEncode+=$peo;$newPairEncode+=$pen;$oldPairDecode+=$pdo;$newPairDecode+=$pdn
    }
    $oe2=Median $oldPairEncode;$ne2=Median $newPairEncode;$od2=Median $oldPairDecode;$nd2=Median $newPairDecode
    $report.performance_gate=@{MDL_files=8;old_encode_ms=$oe/1e6;new_encode_ms=$ne/1e6;old_decode_ms=$od/1e6;new_decode_ms=$nd/1e6;decode_reduction_percent=100.0*(1-$nd/$od);required_decode_reduction_percent=15;encode_ratio=$ne/$oe;per_MDL_regressions=$regressions;pair_median_old_encode_ms=$oe2/1e6;pair_median_new_encode_ms=$ne2/1e6;pair_median_old_decode_ms=$od2/1e6;pair_median_new_decode_ms=$nd2/1e6;pair_median_decode_reduction_percent=100.0*(1-$nd2/$od2);pair_median_encode_ratio=$ne2/$oe2;passed=($nd -le $od*0.85 -and $ne -le $oe*1.05 -and $nd2 -le $od2*0.85 -and $ne2 -le $oe2*1.05 -and $regressions -eq 0);not_native_seven_zip_completion=$true}
    $report.timing_evidence=$true
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -cne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;foreach($lock in $locks){$lock.Dispose()};if(-not $same){$report.status='pin_mismatch'}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($bytes.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null;@{status=$report.status;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}
}
if($report.status -ne 'completed'){exit 1}
