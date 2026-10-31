#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('khc_block_normal','khc_block_adversarial','khc_adversarial','khc_hybrid','khc_model_boundary','khc_state_safety')]
    [string]$Target,
    [ValidatePattern('^[a-z][a-z0-9-]{0,20}$')][string]$Attempt='a'
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root ("build/khc-program-port-"+$Target+"-"+$Attempt+"-20261006")
$dependency=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps'
$hostDependency=Join-Path $root 'build/cargo/release/deps'
$library=Join-Path $dependency 'libunlhare.rlib'
$crc=Join-Path $dependency 'libcrc_fast-a207a6446f4a1f16.rlib'
$json=Join-Path $dependency 'libserde_json-93ede885705299dd.rlib'
$cli=Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/unlhare-cli.exe'
$proof=Get-Content -LiteralPath (Join-Path $root 'build/khc-program-port-khc_block_normal-b-20261006/report.json') -Raw|ConvertFrom-Json
if($proof.status -cne 'completed' -or (Get-FileHash -LiteralPath $library).Hash -cne $proof.rlib.SHA256){throw 'current Cargo Release library proof'}
foreach($pin in $proof.source){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){throw 'core differs from Release proof'}}
$sourcePaths=@('src/khc/block/mod.rs','src/khc/block/packet.rs','src/khc/block/grammar.rs','src/khc/block/program.rs',("tests/"+$Target+".rs"),'Cargo.toml','Cargo.lock')
$before=@(foreach($relative in $sourcePaths){$path=Join-Path $root $relative;[ordered]@{path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}})
$before+=@(foreach($path in @($library,$crc,$json,$cli)){[ordered]@{path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}})
$exeBefore=@(Get-ChildItem -LiteralPath (Join-Path $root 'build/cargo/x86_64-pc-windows-msvc/release/deps') -File -Filter ($Target+'-*.exe')|ForEach-Object {[ordered]@{path=$_.FullName;bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
$shared=Join-Path $root 'build/cargo';$cap=6175228536L
$clock=[Diagnostics.Stopwatch]::StartNew()
$report=[ordered]@{status='starting';failure=$null;cap=$cap;cargo_before=0L;cargo_peak=0L;cargo_after=0L;check=$null;profile=('optimized standalone existing '+$Target+' E2E binary; public Cargo Release rlib; harness LTO off');not_cargo_build=$true;harness_lto='off';target=$Target;source_before=$before;exe_before=$exeBefore;exe=$null;rlib=$null;not_release_build=$false;not_bundle=$true;not_runtime_tests=$true;source=@()}
function Guard{
    if($clock.Elapsed.TotalSeconds -ge 180){throw 'suite deadline'}
    $nodes=$null
    for($attempt=0;$attempt -lt 3;$attempt++){
        try{$nodes=@(Get-ChildItem -LiteralPath $shared -Recurse -Force -ErrorAction Stop);break}
        catch{
            $io=$false;$exception=$_.Exception
            for($depth=0;$exception -and $depth -lt 4;$depth++){
                if($exception -is [IO.IOException] -or $exception -is [UnauthorizedAccessException]){$io=$true}
                $exception=$exception.InnerException
            }
            if(-not $io -or $attempt -eq 2){throw}
            Start-Sleep -Milliseconds 10
        }
    }
    if(@($nodes|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'shared target reparse'}
    $used=[long](($nodes|Where-Object {-not $_.PSIsContainer}|Measure-Object Length -Sum).Sum)
    $report.cargo_peak=[math]::Max($report.cargo_peak,$used)
    if($used -gt $cap){throw 'shared Cargo cap'}
    if(Test-Path -LiteralPath $work){
        $files=@(Get-ChildItem -LiteralPath $work -Recurse -File -Force)
        $workBytes=if($files.Count){[long](($files|Measure-Object Length -Sum).Sum)}else{0L}
        if($workBytes -gt 8388608){throw 'new standalone output cap'}
    }
    if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120+11672607){throw 'free space'}
    return $used
}
if(Test-Path -LiteralPath $work){throw 'unused work required'}
& (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
$report.cargo_before=Guard
$null=New-Item -ItemType Directory -Path $work
$savedEnv=@{}
foreach($key in @('CARGO_TARGET_DIR','CARGO_BUILD_JOBS','CARGO_INCREMENTAL','RUSTC','RUSTUP_TOOLCHAIN','CARGO_MANIFEST_DIR','CARGO_BIN_EXE_unlhare-cli')){$savedEnv[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
$p=$null;$started=$false
try{
    [Environment]::SetEnvironmentVariable('CARGO_TARGET_DIR',$shared,'Process')
    [Environment]::SetEnvironmentVariable('CARGO_BUILD_JOBS','1','Process')
    [Environment]::SetEnvironmentVariable('CARGO_INCREMENTAL','0','Process')
    [Environment]::SetEnvironmentVariable('RUSTC','C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe','Process')
    [Environment]::SetEnvironmentVariable('RUSTUP_TOOLCHAIN','1.98.1','Process')
    [Environment]::SetEnvironmentVariable('CARGO_MANIFEST_DIR',$root,'Process')
    [Environment]::SetEnvironmentVariable('CARGO_BIN_EXE_unlhare-cli',$cli,'Process')
    $i=[Diagnostics.ProcessStartInfo]::new();$i.FileName='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
    $i.WorkingDirectory=$root;$i.UseShellExecute=$false;$i.CreateNoWindow=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
    foreach($arg in @('--test','--edition','2024','--target','x86_64-pc-windows-msvc','-C','opt-level=3','-C','lto=off','-C','codegen-units=1','-C','panic=unwind','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-L',"dependency=$dependency",'-L',"dependency=$hostDependency",'-L','native=C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.52.6/lib','-L','native=C:/Users/IMT/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/windows_x86_64_msvc-0.53.1/lib','--extern',"unlhare=$library",'--extern',"crc_fast=$crc",'--extern',"serde_json=$json",(Join-Path $root ('tests/'+$Target+'.rs')),'-o',(Join-Path $work ($Target+'.exe')))){$i.ArgumentList.Add($arg)}
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
        foreach($child in $all|Where-Object {$owned.Contains([int]$_.ProcessId) -and $_.Name -in @('rustc.exe','clippy-driver.exe','link.exe','lld-link.exe')}){
            try{$cp=[Diagnostics.Process]::GetProcessById($child.ProcessId)}catch [ArgumentException]{continue}
            try{$cp.Refresh();$ws=[math]::Max($ws,$cp.PeakWorkingSet64);$private=[math]::Max($private,$cp.PrivateMemorySize64)}finally{$cp.Dispose()}
        }
        if($ws -gt 536870912 -or $private -gt 536870912){throw 'compiler RAM'}
        if($t.Elapsed.TotalSeconds -ge 60){throw 'cargo child deadline'}
    }
    $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
    if($o.Length -gt 16384 -or $e.Length -gt 16384){throw 'text bound'}
    $report.check=@{exit=$p.ExitCode;stdout=$o;stderr=$e;diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private}
    if($p.ExitCode -ne 0){throw 'cargo release E2E build failed'}
    foreach($pin in $before){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){throw 'source changed during build'}}
    $files=@(Get-Item -LiteralPath (Join-Path $work ($Target+'.exe')))
    if($files.Count -ne 1){throw 'unique E2E EXE required'}
    $report.exe=@{path=$files[0].FullName;bytes=$files[0].Length;SHA256=(Get-FileHash -LiteralPath $files[0].FullName).Hash}
    $files=@(Get-ChildItem -LiteralPath (Join-Path $shared 'x86_64-pc-windows-msvc/release/deps') -File -Filter 'libunlhare.rlib')
    if($files.Count -ne 1){throw 'unique public rlib required'}
    $report.rlib=@{path=$files[0].FullName;bytes=$files[0].Length;SHA256=(Get-FileHash -LiteralPath $files[0].FullName).Hash}
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'owned process termination'}}
    if($started -and $report.check -eq $null -and $p.HasExited){
        $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
        $report.check=@{exit=$p.ExitCode;stdout=$o.Substring(0,[math]::Min($o.Length,16384));stderr=$e.Substring(0,[math]::Min($e.Length,16384));text_truncated=($o.Length -gt 16384 -or $e.Length -gt 16384);diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private}
    }
    if($p){$p.Dispose()}
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key],'Process')}
    try{$report.cargo_after=Guard}catch{$report.status='failed';$report.failure=$_.Exception.Message}
    $report.source=@(foreach($name in @('mod.rs','packet.rs','grammar.rs','program.rs')){$path=Join-Path $root ('src/khc/block/'+$name);@{path=$path;SHA256=(Get-FileHash -LiteralPath $path).Hash}})
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 7 -Compress));if($bytes.Length -gt 131072){throw 'report bound'}
    $reportPath=Join-Path $work 'report.json';$stream=[IO.File]::Open($reportPath,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    & (Join-Path $root 'experiments/khc/disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8|Out-Null
    @{status=$report.status;failure=$report.failure;report=$reportPath;SHA256=(Get-FileHash -LiteralPath $reportPath).Hash}|ConvertTo-Json -Compress
}
if($report.status -ne 'completed'){exit 1}
