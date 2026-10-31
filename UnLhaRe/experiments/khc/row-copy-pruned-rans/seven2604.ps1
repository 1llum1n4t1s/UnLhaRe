#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-row-copy-pruned-rans-seven2604-20261007'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$true
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$report=[ordered]@{status='starting';kind='verified_7zip_2604_strong_native_baseline';pins=$pins;failure=$null;live_pins_unchanged=$false;timing_is_speed_evidence=$false;limits=@{work=8388608;RAM=67108864;child_seconds=60;suite_seconds=300;CPU_percent=15;quiet_seconds=60}}
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
function Child([string]$file,[string[]]$arguments,[long]$ram,[string]$cwd=$root){
    Quiet;$info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$cwd;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;foreach($arg in $arguments){$info.ArgumentList.Add($arg)}
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
    if(Test-Path -LiteralPath (Join-Path $work 'report.json')){throw 'new report required'}
    Pin $PSCommandPath;Pin (Join-Path $PSScriptRoot 'SEVEN2604_20261007.md');Pin (Join-Path $PSScriptRoot 'seven2604-release.json')
    $meta=Get-Content (Join-Path $PSScriptRoot 'seven2604-release.json') -Raw|ConvertFrom-Json
    if($meta.tag -ne '26.04' -or $meta.draft -or $meta.prerelease -or $meta.asset.size -ne 1764616){throw 'official stable release metadata'}
    $download=Join-Path $work $meta.asset.name;Pin $download $meta.asset.digest.Substring(7)
    if((Get-Item -LiteralPath $download).Length -ne $meta.asset.size){throw 'asset bytes'}
    $oldSeven=Join-Path $root 'build/khc-baseline-20260918/x64/7za.exe'
    Pin $oldSeven 'EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0'
    $report.release_metadata=$meta;$report.official_confirmed_UTC=[DateTime]::UtcNow.ToString('o')
    if(Test-Path -LiteralPath (Join-Path $work 'x64')){throw 'unused extract directory required'}
    $report.extraction=Child $oldSeven @('x',$download,('-o'+$work),'-bd','-bso0','-bsp0','x64\7za.exe','License.txt','history.txt','readme.txt') 67108864
    $seven=Join-Path $work 'x64/7za.exe';Pin $seven
    foreach($name in @('License.txt','history.txt','readme.txt')){Pin (Join-Path $work $name)}
    $info=Child $seven @('i') 67108864
    if($info.stdout -notmatch '26\.04 \(x64\)'){throw 'new executable version'}
    $report.seven=@{path=$seven;SHA256=(Get-FileHash -LiteralPath $seven).Hash;bytes=(Get-Item -LiteralPath $seven).Length;version='26.04';version_output=$info.stdout}
    $corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
    $manifestPath=Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json';Pin $manifestPath
    $manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json
    $entries=@($manifest|Where-Object name -eq 'canterbury-development')
    if($entries.Count -ne 1 -or $entries[0].files.Count -ne 11){throw 'manifest'}
    foreach($entry in $entries[0].files){Pin (Join-Path $corpus $entry.name) $entry.sha256}
    $report.cargo_before=[long]((Get-ChildItem (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_before -gt 6175228536){throw 'Cargo cap'}
    $archive=Join-Path $work 'native-solid.7z'
    $arguments=@('a','-t7z','-m0=LZMA2','-mx9','-mfb273','-md4m','-mmt1','-ms=on','-bd','-bso0','-bsp0',$archive)+@($entries[0].files.name)
    $report.compression_arguments=$arguments;$report.compression_cwd=$corpus
    $report.create=Child $seven $arguments 67108864 $corpus
    Pin $archive;$report.archive=@{path=$archive;bytes=(Get-Item -LiteralPath $archive).Length;SHA256=(Get-FileHash -LiteralPath $archive).Hash}
    $listing=Child $seven @('l','-slt',$archive) 67108864
    if($listing.stdout -notmatch 'Method = LZMA2:3m' -or $listing.stdout -notmatch 'Solid = \+' -or $listing.stdout -notmatch 'Blocks = 1'){throw 'strong archive properties'}
    $report.actual=@{method='LZMA2:3m';dictionary_property_bytes=3145728;dictionary_requested_bytes=4194304;fast_bytes=273;level=9;solid=$true;blocks=1;worker=1;listing=$listing.stdout}
    $restore=Join-Path $work 'restored'
    $report.restore_process=Child $seven @('x',$archive,('-o'+$restore),'-mmt1','-bd','-bso0','-bsp0') 67108864
    $files=@(Get-ChildItem -LiteralPath $restore -File -Recurse)
    if($files.Count -ne 11 -or ($files|Measure-Object Length -Sum).Sum -ne 2810784){throw 'restore coverage'}
    foreach($entry in $entries[0].files){
        $a=[IO.File]::OpenRead((Join-Path $corpus $entry.name));$b=[IO.File]::OpenRead((Join-Path $restore $entry.name))
        try{if($a.Length -ne $b.Length){throw 'restore length'};$aa=[byte[]]::new(65536);$bb=[byte[]]::new(65536);$remaining=$a.Length
            while($remaining -gt 0){$count=[int][math]::Min($remaining,65536);$a.ReadExactly($aa,0,$count);$b.ReadExactly($bb,0,$count);for($i=0;$i -lt $count;$i++){if($aa[$i] -ne $bb[$i]){throw 'restore byte mismatch'}};$remaining-=$count}
        }finally{$a.Dispose();$b.Dispose()}
    }
    $report.byte_exact=$true;$report.raw_bytes=2810784;$report.input_known_development=$true
    $report.size_threshold_95percent=$report.archive.bytes*0.95
    $report.current_native_archive_bytes=457017
    $report.size_gate_pass=(457017 -le $report.archive.bytes*0.95)
    $report.cargo_after=[long]((Get-ChildItem (Join-Path $root 'build/cargo') -Recurse -File|Measure-Object Length -Sum).Sum)
    if($report.cargo_after -ne $report.cargo_before){throw 'Cargo changed'}
    Guard;$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}}
    $report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($bytes.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    [ordered]@{status=$report.status;failure=$report.failure;report=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}|ConvertTo-Json -Compress
}
if($report.status -ne 'completed'){exit 1}

