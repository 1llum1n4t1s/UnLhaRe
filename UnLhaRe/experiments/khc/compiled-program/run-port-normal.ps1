#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-program-e2e-a-20261006'
$shared=Join-Path $root 'build/cargo';$cap=6175228536L
$clock=[Diagnostics.Stopwatch]::StartNew()
$report=[ordered]@{status='starting';failure=$null;cap=$cap;cargo_before=0L;cargo_peak=0L;cargo_after=0L;check=$null;profile='existing khc_normal real API/CLI runtime E2E';not_release_build=$true;runtime_tests=$true;source=@()}
function Guard{
    if($clock.Elapsed.TotalSeconds -ge 180){throw 'suite deadline'}
    $nodes=@(Get-ChildItem -LiteralPath $shared -Recurse -Force -ErrorAction Stop)
    if(@($nodes|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'shared target reparse'}
    $used=[long](($nodes|Where-Object {-not $_.PSIsContainer}|Measure-Object Length -Sum).Sum)
    $report.cargo_peak=[math]::Max($report.cargo_peak,$used)
    if($used -gt $cap){throw 'shared Cargo cap'}
    if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 671088640+11672607){throw 'free space'}
    return $used
}
if(Test-Path -LiteralPath $work){throw 'unused work required'}
& (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
$report.cargo_before=Guard
$null=New-Item -ItemType Directory -Path $work
$savedEnv=@{}
foreach($key in @('CARGO_TARGET_DIR','CARGO_BUILD_JOBS','CARGO_INCREMENTAL','RUSTC','RUSTUP_TOOLCHAIN','UNLHARE_KHC_E2E_ROOT','UNLHARE_KHC_FIXED_INPUT')){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
$p=$null;$started=$false
try{
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR',$shared,'Process')
    [Environment]::SetEnvironmentVariable('CARGO_BUILD_JOBS','1','Process')
    [Environment]::SetEnvironmentVariable('CARGO_INCREMENTAL','0','Process')
    [Environment]::SetEnvironmentVariable('RUSTC','C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe','Process')
    [Environment]::SetEnvironmentVariable('RUSTUP_TOOLCHAIN','1.98.1','Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_E2E_ROOT',$work,'Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_FIXED_INPUT',(Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'),'Process')
    $i=[Diagnostics.ProcessStartInfo]::new();$i.FileName=Join-Path $shared 'x86_64-pc-windows-msvc/release/deps/khc_normal-ab1cfcf221076e55.exe'
    $i.WorkingDirectory=$root;$i.UseShellExecute=$false;$i.CreateNoWindow=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
    foreach($arg in @('--test-threads=1')){$i.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$i;$t=[Diagnostics.Stopwatch]::StartNew()
    if(-not $p.Start()){throw 'cargo start'};$started=$true
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    $ws=0L;$private=0L
    while(-not $p.WaitForExit(500)){
        $null=Guard;$p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,$p.PrivateMemorySize64)
        # Cargo自身とそのrustc子を各512MiBまで観測。全体RAMの上限とは別。
        $all=@(Get-CimInstance Win32_Process)
        $owned=[Collections.Generic.HashSet[int]]::new();$null=$owned.Add($p.Id)
        for($depth=0;$depth -lt 6;$depth++){
            $added=0
            foreach($process in $all){
                if($owned.Contains([int]$process.ParentProcessId) -and $owned.Add([int]$process.ProcessId)){$added++}
            }
            if($added -eq 0){break}
        }
        foreach($child in $all|Where-Object {$owned.Contains([int]$_.ProcessId) -and $_.Name -in @('unlhare-cli.exe','khc_normal-ab1cfcf221076e55.exe')}){
            try{$cp=[Diagnostics.Process]::GetProcessById($child.ProcessId)}catch [ArgumentException]{continue}
            try{$cp.Refresh();$ws=[math]::Max($ws,$cp.PeakWorkingSet64);$private=[math]::Max($private,$cp.PrivateMemorySize64)}finally{$cp.Dispose()}
        }
        if($ws -gt 67108864 -or $private -gt 67108864){throw 'E2E RAM'}
        if($t.Elapsed.TotalSeconds -ge 60){throw 'cargo child deadline'}
    }
    $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
    if($o.Length -gt 16384 -or $e.Length -gt 16384){throw 'text bound'}
    $report.check=@{exit=$p.ExitCode;stdout=$o;stderr=$e;diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private}
    if($p.ExitCode -ne 0){throw 'runtime E2E failed'}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'owned process termination'}}
    if($p){$p.Dispose()}
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
    $report.cargo_after=Guard
    $report.source=@(foreach($name in @('mod.rs','packet.rs','grammar.rs','program.rs')){$path=Join-Path $root ('src/khc/block/'+$name);@{path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}})
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 7 -Compress));if($bytes.Length -gt 131072){throw 'report bound'}
    $reportPath=Join-Path $work 'report.json';$stream=[IO.File]::Open($reportPath,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
    @{status=$report.status;failure=$report.failure;report=$reportPath;SHA256=(Get-FileHash -LiteralPath $reportPath).Hash}|ConvertTo-Json -Compress
}
if($report.status -ne 'completed'){exit 1}
