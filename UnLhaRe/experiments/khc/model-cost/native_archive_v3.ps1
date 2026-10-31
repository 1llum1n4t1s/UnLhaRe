#Requires -Version 7.0
[CmdletBinding()]
param([ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='native-c')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-native-archive-$Attempt-20261006"
$corpus=Join-Path $root 'build/khc-corpus/canterbury-development'
$cli=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/unlhare-cli.exe'
$seven=Join-Path $root 'build/khc-baseline-20260918/x64/7za.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$results=[Collections.Generic.List[object]]::new();$restored=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='native_archive_size_roundtrip_diagnostic';speed_evidence=$false;seven_zip_superiority_verified=$false;corpus_role='known development';source_copy_bytes=0;native_results=$results;restored=$restored;pins=$pins;limits=@{work=8388608;report=131072;child_seconds=60;suite_seconds=300;native_RAM=67108864;CPU_percent=15;quiet_seconds=60};failure=$null;live_pins_unchanged=$false}
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

function Record([string]$side,[string]$phase,[string]$file,[string[]]$arguments){
    $value=Child $file $arguments 67108864
    $results.Add(@{side=$side;phase=$phase;command=@($file)+$arguments;observation=$value})
    return $value
}
try{
    Chain $work;Chain $corpus;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $cli '9CAF52385AE3EDEC09D16D6D431F1146B8F1D2FB43A75E9AB0F58D97EAA38820'
    Pin $seven 'EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0'
    Pin (Join-Path $PSHOME 'pwsh.exe')
    foreach($path in @('NATIVE_ARCHIVE_PLAN_20261006.md','NATIVE_ARCHIVE_CHECK_FIX_20261006.md','native_archive.ps1','native_archive_v2.ps1','NATIVE_RESTORE_PLAN_20261006.md','native_archive_v3.ps1')){Pin (Join-Path $PSScriptRoot $path)}
    foreach($path in @('experiments/khc/CORPUS_MANIFEST.json','Cargo.toml','Cargo.lock','src/main.rs','src/lib.rs','src/khc/mod.rs')){Pin (Join-Path $root $path)}
    foreach($path in Get-ChildItem (Join-Path $root 'src/khc/block') -File -Filter '*.rs'){Pin $path.FullName}
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json
    $selected=@($manifest|Where-Object name -eq 'canterbury-development')
    if($selected.Count -ne 1 -or $selected[0].files.Count -ne 11){throw 'manifest extent'}
    $entries=@($selected[0].files|Sort-Object name)
    $physical=@(Get-ChildItem -LiteralPath $corpus -Force)
    if($physical.Count -ne 11 -or @($physical|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'exact source set'}
    $total=0L
    foreach($entry in $entries){$path=Join-Path $corpus $entry.name;Pin $path $entry.sha256;if((Get-Item -LiteralPath $path).Length -ne $entry.bytes){throw 'source extent'};$total+=$entry.bytes}
    if($total -ne 2810784){throw 'source total'}
    $report.input_bytes=$total
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    # 初回で成功したcreationを繰返さず、同じ実archiveを検証する。
    $initialPath=Join-Path $root 'build/khc-native-archive-native-a-20261006/report.json'
    Pin $initialPath 'C2C97D61C9B55BD3311DEB326C65AD44AEA4EB393212B680A99310B227555197'
    $initial=Get-Content -LiteralPath $initialPath -Raw|ConvertFrom-Json
    if($initial.status -ne 'failed' -or $initial.failure -cne '7z actual solid/method/dictionary' -or -not $initial.live_pins_unchanged){throw 'initial failure identity'}
    foreach($pin in $initial.pins){Pin $pin.path $pin.SHA256}
    $creates=@($initial.native_results|Where-Object phase -eq 'create')
    if($creates.Count -ne 2){throw 'completed creation coverage'}
    foreach($observation in $creates){$results.Add($observation)}
    $restore=Join-Path $root 'build/khc-native-restore-helper-restore-a-20261006/archive_restore.exe'
    $restoreReport=Join-Path $root 'build/khc-native-restore-helper-restore-a-20261006/report.json'
    Pin $restoreReport '601BDB694B94EEB78A321D5682652D993316CF18250B7B51F87E6DF0D92A5E0D'
    $builder=Get-Content -LiteralPath $restoreReport -Raw|ConvertFrom-Json
    if($builder.status -ne 'completed' -or -not $builder.live_pins_unchanged){throw 'restore helper provenance'}
    foreach($pin in $builder.pins){Pin $pin.path $pin.SHA256}
    Pin $restore '865B7652CF7C12B19D52D9B043A9E5A080AEAB25D5997C97826B1D8FA410AABB'
    $report.creation_provenance=$initialPath
    $khc=Join-Path $root 'build/khc-native-archive-native-a-20261006/current.khc'
    $z=Join-Path $root 'build/khc-native-archive-native-a-20261006/native-solid.7z'
    Pin $khc 'C29B63905569B44A6D4AF6F19D80AEF345D68B3572BBB0A0AA82AF08D882B7DE'
    Pin $z 'F26CA2BA262964FC601D544D860280BCC07A984243828F02DC6DFDC5849F8A78'
    foreach($path in @($khc,$z)){Chain $path;if((Get-Item -LiteralPath $path).Length -gt 1048576){throw 'archive size bound before restore'};Pin $path}
    $khcListing=Record 'khc' 'list' $cli @('khc-list',$khc,'--json')
    $khcEntries=@($khcListing.stdout|ConvertFrom-Json)
    if($khcEntries.Count -ne 11 -or @($khcEntries|Where-Object is_directory).Count){throw 'KHC entry set'}
    foreach($entry in $entries){$found=@($khcEntries|Where-Object name -ceq $entry.name);if($found.Count -ne 1 -or $found[0].original_size -ne $entry.bytes){throw 'KHC manifest match'}}
    $listing=Record 'seven' 'list' $seven @('l','-slt','-sccUTF-8',$z)
    if($listing.stdout -notmatch '(?m)^Solid = \+\r?$' -or $listing.stdout -notmatch '(?m)^Blocks = 1\r?$' -or $listing.stdout -notmatch '(?m)^Method = LZMA2:3m\r?$'){throw '7z actual solid/method/dictionary'}
    if(3145728 -lt $total -or 3145728 -gt 4194304){throw 'actual dictionary must cover full input within requested bound'}
    $report.seven_actual=@{solid=$true;blocks=1;method='LZMA2:3m';dictionary_property_bytes=3145728;dictionary_requested_bytes=4194304;worker=1;level=9;fast_bytes=273}
    $null=Record 'khc' 'test' $cli @('khc-test',$khc)
    $null=Record 'seven' 'test' $seven @('t','-mmt1','-bd','-bso0','-bsp0',$z)
    $khcOutput=Join-Path $work 'khc-restored';$sevenOutput=Join-Path $work 'seven-restored'
    $null=Record 'khc' 'extract_preserve_timestamps_API' $restore @($khc,$khcOutput)
    $null=Record 'seven' 'extract' $seven @('x','-mmt1','-bd','-bso0','-bsp0',('-o'+$sevenOutput),$z)
    foreach($side in @(@{name='khc';path=$khcOutput},@{name='seven';path=$sevenOutput})){
        Chain $side.path;$files=@(Get-ChildItem -LiteralPath $side.path -Recurse -Force)
        if($files.Count -ne 11 -or @($files|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'restored exact file set'}
        foreach($entry in $entries){
            $sourcePath=Join-Path $corpus $entry.name;$restoredPath=Join-Path $side.path $entry.name;Chain $restoredPath
            $source=Get-Item -LiteralPath $sourcePath;$destination=Get-Item -LiteralPath $restoredPath
            if($destination.Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $restoredPath).Hash -ne $entry.sha256){throw 'restored extent/SHA'}
            if([Convert]::ToBase64String([IO.File]::ReadAllBytes($sourcePath)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($restoredPath))){throw 'restored byte mismatch'}
            $mtimeOK=if($side.name -eq 'khc'){([DateTimeOffset]$source.LastWriteTimeUtc).ToUnixTimeSeconds() -eq ([DateTimeOffset]$destination.LastWriteTimeUtc).ToUnixTimeSeconds()}else{$source.LastWriteTimeUtc.Ticks -eq $destination.LastWriteTimeUtc.Ticks}
            if(-not $mtimeOK){throw 'restored mtime'}
            $restored.Add(@{side=$side.name;name=$entry.name;bytes=$entry.bytes;SHA256=$entry.sha256;byte_exact=$true;mtime_match=$true;mtime_precision=$(if($side.name -eq 'khc'){'seconds'}else{'100ns'})})
        }
    }
    $report.khc_bytes=(Get-Item -LiteralPath $khc).Length
    $report.seven_bytes=(Get-Item -LiteralPath $z).Length
    $report.khc_size_change_percent=100*($report.khc_bytes/$report.seven_bytes-1)
    $report.retained_before_cleanup_bytes=Usage
    $report.status='completed';Write-Output 'native archive size and exact restore completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10 -Compress));if($data.Length -gt 131072){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
