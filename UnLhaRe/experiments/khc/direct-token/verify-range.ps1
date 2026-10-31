[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$expectedCompiler='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-direct-token-range-20261002'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$before=& $guard -WorkDirectory $work -MaxRunMiB 8
if(Test-Path -LiteralPath $work){throw 'Fresh range verification root already exists; do not overwrite or retry.'}
if((Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash -ne $expectedCompiler){throw 'Compiler SHA mismatch'}
$null=New-Item -ItemType Directory -Path $work
$records=[Collections.Generic.List[object]]::new()
function Child([string]$File,[string[]]$Arguments){
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File; $info.WorkingDirectory=$project; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach($argument in $Arguments){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    $null=$process.Start()
    # bounded async character reads prevent pipe deadlocks and unbounded capture.
    $stdout=[Text.StringBuilder]::new(); $stderr=[Text.StringBuilder]::new()
    $outBuffer=[char[]]::new(4096); $errBuffer=[char[]]::new(4096)
    $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,$outBuffer.Length)
    $errTask=$process.StandardError.ReadAsync($errBuffer,0,$errBuffer.Length)
    $watch=[Diagnostics.Stopwatch]::StartNew(); $outDone=$false; $errDone=$false
    try {
        while(!$outDone -or !$errDone -or !$process.HasExited){
            if($watch.Elapsed.TotalSeconds -gt 120){throw 'Child timeout'}
            if(!$outDone -and $outTask.IsCompleted){
                $n=$outTask.GetAwaiter().GetResult()
                if($n -eq 0){$outDone=$true}else{if($stdout.Length+$n -gt 65536){throw 'stdout cap'};$null=$stdout.Append($outBuffer,0,$n);$outTask=$process.StandardOutput.ReadAsync($outBuffer,0,$outBuffer.Length)}
            }
            if(!$errDone -and $errTask.IsCompleted){
                $n=$errTask.GetAwaiter().GetResult()
                if($n -eq 0){$errDone=$true}else{if($stderr.Length+$n -gt 65536){throw 'stderr cap'};$null=$stderr.Append($errBuffer,0,$n);$errTask=$process.StandardError.ReadAsync($errBuffer,0,$errBuffer.Length)}
            }
            [Threading.Thread]::Sleep(5)
        }
        $result=[pscustomobject]@{file=$File;argv=$Arguments;cwd=$project;exit=$process.ExitCode;stdout=$stdout.ToString().Trim();stderr=$stderr.ToString().Trim();elapsed_ms=$watch.Elapsed.TotalMilliseconds}
        $records.Add($result)
        if($result.exit -ne 0){throw "Child failed: $File ($($result.exit)): $($result.stderr)"}
        return $result
    } finally {if(!$process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
$sources=@('multi_range.rs','range_audit.rs','verify-range.ps1','RANGE_FAILURE_PLAN.md' | ForEach-Object {
    $path=Join-Path $PSScriptRoot $_
    [pscustomobject]@{path=$path;sha256=(Get-FileHash -LiteralPath $path).Hash;length=(Get-Item -LiteralPath $path).Length}
})
$report=[ordered]@{status='running';compiler=$compiler;compiler_sha256=$expectedCompiler;runtime=$runtime;runtime_sha256=(Get-FileHash -LiteralPath $runtime).Hash;sources=$sources;disk_before=$before;records=$records;conditions=@()}
try {
    $report.compiler_version=(Child $compiler @('--version')).stdout
    $baseline=$null; $serializedBaseline=$null
    foreach($opt in @(2,3)){foreach($overflow in @('on','off')){
        $exe=Join-Path $work "range-o$opt-$overflow.exe"
        $args=@((Join-Path $PSScriptRoot 'range_audit.rs'),'--edition=2021','--cfg','range_audit','-C',"opt-level=$opt",'-C',"overflow-checks=$overflow",'-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        $null=Child $compiler $args
        $audit=Child $exe @('audit')
        if($null -eq $baseline){$baseline=$audit.stdout}elseif($audit.stdout -ne $baseline){throw 'Audit fingerprints/counters differ'}
        $wire=(Child $exe @('encode')).stdout
        if($null -eq $serializedBaseline){$serializedBaseline=$wire}elseif($wire -ne $serializedBaseline){throw 'Serialized wire differs'}
        $decoded=Child $exe @('decode',$wire)
        $report.conditions+= [pscustomobject]@{opt=$opt;overflow=$overflow;exe=$exe;sha256=(Get-FileHash -LiteralPath $exe).Hash;length=(Get-Item -LiteralPath $exe).Length;audit=($audit.stdout|ConvertFrom-Json);serialized=($decoded.stdout|ConvertFrom-Json)}
        $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    }}
    $report.status='passed'
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
    $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8
    $json=$report|ConvertTo-Json -Depth 12
    if($json.Length -gt 65536){throw 'Report cap exceeded'}
    [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
    $null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
$report.conditions|ConvertTo-Json -Depth 5
