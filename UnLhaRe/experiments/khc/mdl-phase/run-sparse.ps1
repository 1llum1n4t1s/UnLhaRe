#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$HelperSha256,
    [ValidatePattern('^[a-z0-9-]{1,32}$')][string]$Attempt='screen-b')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root "build/khc-mdl-phase-$Attempt-20261005"
$exe=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/examples/khc_sparse_probe.exe'
$clock=[Diagnostics.Stopwatch]::StartNew();$created=$false
$pins=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new();$rows=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='starting';kind='product_mdl_phase_screen';rounds=4;warmup=1;timing='warmup1+3 instrumented in-process; NOT comparable with process benchmark';frame_header_bytes=40;phase_names=@('BWT_Front','train','hist','fit','root_wire_packet','forest','encode_walk');results=$rows;pins=$pins;limits=@{raw=1048576;child_seconds=60;suite_seconds=300;WS_private=67108864;report=262144;work=8388608};raw_frame_disk_files=0;seven_zip_superiority_verified=$false;live_pins_unchanged=$false;failure=$null}
function Chain([string]$path){$p=[IO.Path]::GetFullPath($path);while($p){if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse path'}};$p=[IO.Path]::GetDirectoryName($p)}}
function Pin([string]$path,[string]$sha=''){Chain $path;$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$f=Get-Item -LiteralPath $path;$hash=(Get-FileHash -LiteralPath $path).Hash;if($sha -and $hash -ne $sha){throw 'SHA pin mismatch'};$pins.Add(@{path=$path;SHA256=$hash;bytes=$f.Length;mtime=$f.LastWriteTimeUtc.ToString('o')})}
function Guard{if($clock.Elapsed.TotalSeconds -ge 300){throw 'suite deadline'}}
function Child([string]$arg){
    Guard;$p=[Diagnostics.Process]::new();$si=[Diagnostics.ProcessStartInfo]::new();$si.FileName=$exe;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$si.ArgumentList.Add($arg);$p.StartInfo=$si
    $started=$false;$timer=[Diagnostics.Stopwatch]::StartNew();$ws=0L;$private=0L
    try{
        if(-not $p.Start()){throw 'child start'};$started=$true;$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync()
        while(-not $p.WaitForExit(10)){Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt 67108864 -or $private -gt 67108864){throw 'RAM bound'};if($timer.Elapsed.TotalSeconds -ge 60){throw 'child deadline'}}
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,[math]::Max($p.PrivateMemorySize64,$p.PeakPagedMemorySize64));if($ws -gt 67108864 -or $private -gt 67108864){throw 'final RAM bound'}
        $stdout=$o.GetAwaiter().GetResult();$stderr=$e.GetAwaiter().GetResult();if($stdout.Length -gt 32768 -or $stderr.Length -gt 16384){throw 'known helper text bound'};if($p.ExitCode -ne 0){throw "child exit $($p.ExitCode): $stderr"}
        return @{data=($stdout|ConvertFrom-Json);max_WS=$ws;max_private=$private;wall_ms=$timer.Elapsed.TotalMilliseconds}
    }finally{if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'termination timeout'}};$p.Dispose()}
}
try{
    Chain $work;if(Test-Path -LiteralPath $work){throw 'unused output required'}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null
    Pin $exe $HelperSha256
    Pin 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Pin 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/cargo.exe' 'C37545EC61D48D31BDEFCE53280ECAB61C4EA54EAACE372FAC6A0316C6E165D9'
    foreach($relative in @('examples/khc_sparse_probe.rs','experiments/khc/mdl-phase/PLAN.md','experiments/khc/mdl-phase/sparse_block.rs','experiments/khc/mdl-phase/run-sparse.ps1','experiments/khc/CORPUS_MANIFEST.json','Cargo.toml','Cargo.lock','src/lib.rs')){Pin (Join-Path $root $relative)}
    foreach($file in Get-ChildItem (Join-Path $root 'src/khc') -Recurse -File -Filter '*.rs'){Pin $file.FullName}
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    $manifest=Get-Content (Join-Path $root 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json;$development=@($manifest|Where-Object name -eq 'canterbury-development');if($development.Count -ne 1 -or $development[0].files.Count -ne 11){throw 'manifest shape'}
    foreach($entry in $development[0].files){
        Guard;$path=Join-Path $root ('build/khc-corpus/canterbury-development/'+$entry.name);Pin $path $entry.sha256;if((Get-Item -LiteralPath $path).Length -ne $entry.bytes -or $entry.bytes -gt 1048576){throw 'input extent'}
        $r=Child $path;if($r.data.raw_bytes -ne $entry.bytes -or $r.data.rows.Count -ne 4 -or @($r.data.rows | Where-Object {-not $_.byte_exact -or -not $_.frame_equal -or $_.bytes -gt $entry.bytes+40}).Count){throw 'result contract'}
        $rows.Add(@{name=$entry.name;input_SHA=$entry.sha256;result=$r});Write-Output ('completed '+$entry.name)
    }
    if($rows.Count -ne 11){throw 'full corpus coverage'};$report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    $same=$true;foreach($pin in $pins){try{$f=Get-Item -LiteralPath $pin.path;if($f.Length -ne $pin.bytes -or $f.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $pin.path).Hash -ne $pin.SHA256){$same=$false}}catch{$same=$false}};$report.live_pins_unchanged=$same;if(-not $same){$report.status='pin_mismatch'};foreach($lock in $locks){$lock.Dispose()}
    if($created){$data=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12 -Compress));if($data.Length -gt 262144){throw 'report bound'};$path=Join-Path $work 'report.json';$stream=[IO.File]::Open($path,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}; & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8 | Out-Null;[ordered]@{status=$report.status;report=$path;bytes=$data.Length;SHA256=(Get-FileHash -LiteralPath $path).Hash;failure=$report.failure}|ConvertTo-Json -Compress}else{$report|ConvertTo-Json -Depth 4 -Compress}
}
if($report.status -ne 'completed'){exit 1}
