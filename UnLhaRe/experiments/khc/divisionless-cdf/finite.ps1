#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,24}$')][string]$Attempt='a')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-divisionless-cdf-$Attempt-20261006"
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
$report=[ordered]@{guard_enumeration_retries=0;guard_events=[Collections.Generic.List[object]]::new();status='starting';kind='divisionless_CDF_finite_screen';timing_evidence=$false;not_native_archive=$true;pins=$pins;failure=$null;build=$null;run=$null;live_pins_unchanged=$false}
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
    Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md');Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'probe.rs');Pin (Join-Path $PSScriptRoot 'candidate_block.rs');Pin (Join-Path $PSScriptRoot 'choice_range.rs');Pin (Join-Path $PSScriptRoot '../mdl-rans/baseline_block.rs');Pin (Join-Path $PSScriptRoot 'PLAN_20261006.md')
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
    $candidate=[regex]::Replace($candidate,'(?ms)^// CHOICE WRAPPER BEGIN\r?\n.*?^// CHOICE WRAPPER END\r?\n','')
    if([regex]::Matches($candidate,'(?m)^#\[path = "[^"]+"\]').Count -ne 13){throw 'block child count'}
    $candidate=[regex]::Replace($candidate,'(?m)^#\[path = "[^"\r\n]+"\]\r?\n','')
    $product=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/mod.rs') -Raw
    $start=$product.IndexOf('fn decode_interval(');$end=$product.IndexOf('fn token(',$start)
    $oldFunction=$product.Substring($start,$end-$start)
    $candidate=[regex]::Replace($candidate,'(?ms)^// CHOICE CALL BEGIN\r?\n.*?^// CHOICE CALL END\r?\n',[Text.RegularExpressions.MatchEvaluator]{param($match) $oldFunction})
    if([regex]::Replace($candidate,'\s','') -cne [regex]::Replace($product,'\s','')){throw 'block scope mismatch'}
    $choice=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'choice_range.rs') -Raw
    foreach($marker in @('METHOD','CONTRACT')){
        if([regex]::Matches($choice,"CHOICE $marker BEGIN").Count -ne 1){throw 'choice marker count'}
        $choice=[regex]::Replace($choice,"(?ms)^[ \t]*// CHOICE $marker BEGIN\r?\n.*?^[ \t]*// CHOICE $marker END\r?\n",'')
    }
    $range=Get-Content -LiteralPath (Join-Path $root 'src/khc/block/multi_range.rs') -Raw
    if([regex]::Replace($choice,'\s','') -cne [regex]::Replace($range,'\s','')){throw 'range source scope mismatch'}
    $report.normalized_current_product=$true
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.build=Child $rustc @('--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','codegen-units=1','-C','lto=thin','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L',"native=$windows52",'-L',"native=$windows53",'--extern',"unlhare=$library",'--extern',"crc_fast=$crc",(Join-Path $PSScriptRoot 'probe.rs'),'-o',$exe) 536870912
    Pin $exe
    $run=Child $exe $inputs 67108864;$data=$run.stdout|ConvertFrom-Json
    if(-not $data.byte_exact -or $data.numeric_contracts -lt 3145728 -or $data.finite_raw_cases -ne 49 -or $data.files -ne 11 -or $data.rows.Count -ne 11 -or $data.malformed_decoder_checks -ne 672 -or $data.rejected_decoder_checks -lt 600 -or $data.timing_evidence){throw 'finite cost/codec coverage'}
    if($data.old_frames -ne 465951 -or ($data.rows.old_bytes|Measure-Object -Sum).Sum -ne $data.old_frames -or ($data.rows.new_bytes|Measure-Object -Sum).Sum -ne $data.new_frames){throw 'current frame baseline/sum'}
    $rows=@();$index=0;foreach($entry in $corpus[0].files){
        $row=$data.rows[$index];if($row.index -ne $index -or $row.raw -ne $entry.bytes -or $row.comparisons -gt $row.raw*64 -or $row.first_budget_position -gt $row.raw -or $row.changed -gt $row.choices -or $row.shorter -gt $row.changed){throw 'row extent/budget'}
        $rows+=@{name=$entry.name;data=$row};$index++
    }
    $report.run=@{data=$data;named_rows=$rows;max_WS=$run.max_WS;max_private=$run.max_private;diagnostic_wall_ms=$run.diagnostic_wall_ms}
    $regressions=@($data.rows|Where-Object {$_.new_bytes*100 -gt $_.old_bytes*101})
    $report.screen=@{rate_reduction_percent=100.0*(1.0-$data.new_frames/$data.old_frames);required_identical=$true;per_file_regressions=$regressions.Count;passed=($data.new_frames -eq $data.old_frames -and $regressions.Count -eq 0);not_GOAL_completion=$true}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -cne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;foreach($lock in $locks){$lock.Dispose()};if(-not $same){$report.status='pin_mismatch'}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($bytes.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null;@{status=$report.status;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}
}
if($report.status -ne 'completed'){exit 1}














