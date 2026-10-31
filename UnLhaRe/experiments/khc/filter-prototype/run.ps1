#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$HelperSha256)
$ErrorActionPreference='Stop'; Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-filter-prototype-20261005'
$exe=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/examples/khc_filter_probe.exe'
$watch=[Diagnostics.Stopwatch]::StartNew()
$locks=[Collections.Generic.List[IO.FileStream]]::new();$pins=[Collections.Generic.List[object]]::new();$results=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='khc_filter_prototype';timing='single-pass in-process; not comparable to process benchmark';variants=@('identity','plane8','delta1','delta8','delta8_plane8');wrapper_bytes=20;results=$results;pins=$pins;self_check=$null;failure=$null;raw_frame_disk_files=0;seven_zip_superiority_verified=$false;live_pins_unchanged=$false}
function Chain([string]$path){$p=[IO.Path]::GetFullPath($path);while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$path,[string]$sha=''){Chain $path;$lock=[IO.File]::Open($path,'Open','Read','Read');$locks.Add($lock);$f=Get-Item -LiteralPath $path;$hash=(Get-FileHash -LiteralPath $path).Hash;if($sha -and $hash -ne $sha){throw 'pin SHA mismatch'};$pins.Add(@{path=$path;SHA256=$hash;bytes=$f.Length;mtime=$f.LastWriteTimeUtc.ToString('o')})}
function Guard {if($watch.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'}}
function Child([string]$arg){
    Guard
    $p=[Diagnostics.Process]::new();$si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$exe;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.ArgumentList.Add($arg);$p.StartInfo=$si
    $started=$false;$child=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{
        if(-not $p.Start()){throw 'child start'};$started=$true;$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        while(-not $p.WaitForExit(10)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt 67108864 -or $private -gt 67108864){throw 'child RAM bound'};if($child.Elapsed.TotalSeconds -ge 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt 67108864 -or $private -gt 67108864){throw 'final RAM bound'}
        $o=$stdout.GetAwaiter().GetResult();$e=$stderr.GetAwaiter().GetResult();if($o.Length -gt 32768 -or $e.Length -gt 16384){throw 'text bound'};if($p.ExitCode -ne 0){throw "child error: $e"}
        return @{data=($o|ConvertFrom-Json);max_WS=$ws;max_private=$private;wall_ms=$child.Elapsed.TotalMilliseconds}
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);$null=$p.WaitForExit(1000)};$p.Dispose()}
}
$created=$false
try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $exe $HelperSha256
    foreach($relative in @('examples/khc_filter_probe.rs','experiments/khc/filter-prototype/PLAN.md','experiments/khc/filter-prototype/run.ps1','experiments/khc/CORPUS_MANIFEST.json','Cargo.toml','Cargo.lock','src/lib.rs')){Pin (Join-Path $root $relative)}
    foreach($f in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $f.FullName}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $report.self_check=Child '--self-check';if(-not $report.self_check.data.self_check){throw 'self-check contract'}
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$development=@($manifest|Where-Object name -eq 'canterbury-development');if($development.Count -ne 1 -or $development[0].files.Count -ne 11){throw 'manifest shape'}
    foreach($entry in $development[0].files){
        Guard;$path=Join-Path $root ('build/khc-corpus/canterbury-development/'+$entry.name);Pin $path $entry.sha256;if((Get-Item $path).Length -ne $entry.bytes -or $entry.bytes -gt 1048576){throw 'input size'}
        $r=Child $path;if($r.data.raw_bytes -ne $entry.bytes -or $r.data.rows.Count -ne 5 -or @($r.data.rows | Where-Object {-not $_.byte_exact}).Count){throw 'result contract'}
        $results.Add(@{name=$entry.name;input_SHA=$entry.sha256;result=$r});Write-Output ("completed "+$entry.name)
    }
    if($results.Count -ne 11){throw 'all input coverage'};$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($bytes.Length -gt 262144){throw 'report bound'};$path=Join-Path $work 'report.json';$s=[IO.File]::Open($path,'CreateNew','Write','None');try{$s.Write($bytes,0,$bytes.Length)}finally{$s.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;SHA256=(Get-FileHash $path).Hash;bytes=$bytes.Length;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
