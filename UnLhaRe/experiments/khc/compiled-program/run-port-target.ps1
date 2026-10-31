#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('khc_block_normal','khc_block_adversarial','khc_adversarial','khc_hybrid','khc_model_boundary','khc_state_safety')][string]$Target,
    [ValidatePattern('^[a-z][a-z0-9-]{0,20}$')][string]$BuildAttempt='a',
    [ValidatePattern('^[a-z][a-z0-9-]{0,20}$')][string]$Attempt='a'
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$shared=Join-Path $root 'build/cargo';$cap=6175228536L
$work=Join-Path $root ("build/khc-program-runtime-"+$Target+"-"+$Attempt+"-20261006")
$buildPath=Join-Path $root ("build/khc-program-port-"+$Target+"-"+$BuildAttempt+"-20261006/report.json")
$build=Get-Content -LiteralPath $buildPath -Raw|ConvertFrom-Json
if($build.status -cne 'completed' -or $build.target -cne $Target -or $build.check.exit -ne 0){throw 'successful target build proof required'}
$cli=Join-Path $shared 'x86_64-pc-windows-msvc/release/unlhare-cli.exe'
$fixed=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
if((Get-FileHash -LiteralPath $fixed).Hash -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'fixed input identity'}
$pins=@($build.source_before)+@($build.exe,$build.rlib)+@(@{path=$cli;SHA256=(Get-FileHash -LiteralPath $cli).Hash},@{path=$fixed;SHA256=(Get-FileHash -LiteralPath $fixed).Hash})
foreach($pin in $pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){throw 'build/source pin mismatch'}}
if(Test-Path -LiteralPath $work){throw 'unused work required'}
$clock=[Diagnostics.Stopwatch]::StartNew()
$report=[ordered]@{status='starting';failure=$null;target=$Target;build=@{path=$buildPath;SHA256=(Get-FileHash -LiteralPath $buildPath).Hash};pins=$pins;check=$null;outputs=@();fixture_roots=@();cargo_before=0L;cargo_peak=0L;cargo_after=0L;fixture_peak=0L;cap=$cap;runtime_tests=$true;not_bundle=$true;peak_is_sampled=$true;memory_sample_count=0;sampling_ms=50;child_deadline_s=60;expected_tests=if($Target -eq 'khc_adversarial'){2}else{1}}
function Size([string]$Path){
    if(-not (Test-Path -LiteralPath $Path)){return 0L}
    $nodes=@(Get-Item -LiteralPath $Path)+@(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop)
    if(@($nodes|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'output reparse'}
    $files=@($nodes|Where-Object {-not $_.PSIsContainer})
    if($files.Count -eq 0){return 0L}
    return [long](($files|Measure-Object Length -Sum).Sum)
}
function Guard{
    if($clock.Elapsed.TotalSeconds -ge 180){throw 'suite deadline'}
    $used=Size $shared;$report.cargo_peak=[math]::Max($report.cargo_peak,$used)
    if($used -gt $cap){throw 'shared Cargo cap'}
    $generated=Size $work
    foreach($path in $report.fixture_roots){$generated+=Size $path}
    $report.fixture_peak=[math]::Max($report.fixture_peak,$generated)
    if($generated -gt 8388608){throw 'new fixture/report cap'}
    if([IO.DriveInfo]::new('C:').AvailableFreeSpace -lt 5368709120+8388608+5806362){throw 'free space'}
    return $used
}
$report.cargo_before=Guard
$null=New-Item -ItemType Directory -Path $work
$saved=@{}
foreach($key in @('UNLHARE_KHC_FIXED_INPUT','UNLHARE_KHC_E2E_ROOT')){$saved[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
$p=$null;$started=$false;$ws=0L;$private=0L;$out=$null;$err=$null
try{
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_FIXED_INPUT',$fixed,'Process')
    [Environment]::SetEnvironmentVariable('UNLHARE_KHC_E2E_ROOT',$work,'Process')
    $i=[Diagnostics.ProcessStartInfo]::new();$i.FileName=$build.exe.path;$i.WorkingDirectory=$root
    $i.UseShellExecute=$false;$i.CreateNoWindow=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
    $i.ArgumentList.Add('--test-threads=1')
    $p=[Diagnostics.Process]::new();$p.StartInfo=$i;$t=[Diagnostics.Stopwatch]::StartNew()
    if(-not $p.Start()){throw 'runtime start'};$started=$true
    $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
    $base=Join-Path $root 'build/khc-product-e2e-20261005'
    $tags=switch($Target){
        'khc_block_normal'{@('block-normal')}
        'khc_block_adversarial'{@('block-adverse')}
        'khc_adversarial'{@('corrupt','policy')}
        'khc_model_boundary'{@('model-boundary')}
        'khc_state_safety'{@('source-state')}
        'khc_hybrid'{$base=Join-Path $root 'build/khc-hybrid-20261005';@('e2e')}
    }
    $report.fixture_roots=@(foreach($tag in $tags){Join-Path $base ($tag+'-'+$p.Id)})
    $nextGuard=0.0
    while(-not $p.WaitForExit(50)){
        $p.Refresh();$ws=[math]::Max($ws,$p.PeakWorkingSet64);$private=[math]::Max($private,$p.PrivateMemorySize64);$report.memory_sample_count++
        if($ws -gt 67108864 -or $private -gt 67108864){throw 'E2E RAM'}
        if($t.Elapsed.TotalSeconds -ge 60){throw 'runtime child deadline'}
        if($t.Elapsed.TotalMilliseconds -ge $nextGuard){
            $null=Guard
            $all=@(Get-CimInstance Win32_Process);$owned=[Collections.Generic.HashSet[int]]::new();$null=$owned.Add($p.Id)
            for($depth=0;$depth -lt 6;$depth++){
                $added=0;foreach($child in $all){if($owned.Contains([int]$child.ParentProcessId) -and $owned.Add([int]$child.ProcessId)){$added++}}
                if($added -eq 0){break}
            }
            foreach($child in $all|Where-Object {$owned.Contains([int]$_.ProcessId) -and $_.Name -eq 'unlhare-cli.exe'}){
                try{$cp=[Diagnostics.Process]::GetProcessById($child.ProcessId)}catch [ArgumentException]{continue}
                try{$cp.Refresh();$ws=[math]::Max($ws,$cp.PeakWorkingSet64);$private=[math]::Max($private,$cp.PrivateMemorySize64);$report.memory_sample_count++}finally{$cp.Dispose()}
            }
            if($ws -gt 67108864 -or $private -gt 67108864){throw 'CLI RAM'}
            $nextGuard=$t.Elapsed.TotalMilliseconds+500
        }
    }
    $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
    if($o.Length -gt 16384 -or $e.Length -gt 16384){throw 'text bound'}
    $report.check=@{exit=$p.ExitCode;stdout=$o;stderr=$e;diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private;short_process_peak_unobserved=($report.memory_sample_count -eq 0)}
    if($p.ExitCode -ne 0 -or $o -notmatch ('test result: ok\. '+$report.expected_tests+' passed; 0 failed')){throw 'runtime E2E failure or test count'}
    foreach($pin in $pins){if((Get-FileHash -LiteralPath $pin.path).Hash -cne $pin.SHA256){throw 'source/EXE/input changed'}}
    foreach($path in $report.fixture_roots){
        $artifact=if($Target -eq 'khc_adversarial' -and (Split-Path -Leaf $path).StartsWith('policy-')){'race.khc'}else{'result.json'}
        if(-not (Test-Path -LiteralPath (Join-Path $path $artifact))){throw 'expected E2E artifact missing'}
    }
    $report.status='completed'
}catch{$report.status='failed';$report.failure=$_.Exception.Message}
finally{
    if($started -and -not $p.HasExited){$p.Kill($true);if(-not $p.WaitForExit(1000)){throw 'owned process termination'}}
    if($started -and $report.check -eq $null -and $p.HasExited){
        $o=$out.GetAwaiter().GetResult();$e=$err.GetAwaiter().GetResult()
        $report.check=@{exit=$p.ExitCode;stdout=$o.Substring(0,[math]::Min($o.Length,16384));stderr=$e.Substring(0,[math]::Min($e.Length,16384));text_truncated=($o.Length -gt 16384 -or $e.Length -gt 16384);diagnostic_wall_ms=$t.Elapsed.TotalMilliseconds;max_WS=$ws;max_private=$private}
    }
    if($p){$p.Dispose()}
    foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key],'Process')}
    foreach($path in $report.fixture_roots){
        if(Test-Path -LiteralPath $path){
            $report.outputs+=@(Get-ChildItem -LiteralPath $path -File -Recurse|ForEach-Object {[ordered]@{path=$_.FullName;bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName).Hash}})
        }
    }
    try{$report.cargo_after=Guard}catch{$report.status='failed';$report.failure=($_.Exception.Message)}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 9 -Compress));if($bytes.Length -gt 131072){throw 'report bound'}
    $reportPath=Join-Path $work 'report.json';$stream=[IO.File]::Open($reportPath,'CreateNew','Write','None')
    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
    $null=Guard
    @{status=$report.status;failure=$report.failure;report=$reportPath;SHA256=(Get-FileHash -LiteralPath $reportPath).Hash}|ConvertTo-Json -Compress
}
if($report.status -ne 'completed'){exit 1}
