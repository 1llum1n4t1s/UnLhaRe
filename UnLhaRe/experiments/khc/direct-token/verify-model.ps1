[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime = (Get-Process -Id $PID).Path
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $project 'build/khc-direct-token-model-20261002'
$guard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins = @(
    @('cdf_model.rs', '2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53'),
    @('model_audit.rs', '73A737710A4D91ED58AB81270583E9A62F2E00471A8EE60E81F2D68CB4633743'),
    @('MODEL_FAILURE_PLAN.md', '22C4372BF1D66F6B67CE9518A3E7F4875C3466DECD28755E8BA66EBB0C243AAB'),
    @('../DIRECT_TOKEN_CONTRACT_20261002.md', '9E05B35E6A109036B30452260A908CB5610AD52501A28519FEB7CDD53B9D82E3'),
    @('../disk-budget.ps1', 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7')
)
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$sources = [Collections.Generic.List[object]]::new()
$records = [Collections.Generic.List[object]]::new()
function Identity([string]$Path) {
    [pscustomobject]@{ path=[IO.Path]::GetFullPath($Path); sha256=(Get-FileHash -LiteralPath $Path).Hash; bytes=(Get-Item -LiteralPath $Path).Length }
}
function Child([string]$File, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File; $info.WorkingDirectory=$project; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $null=$process.Start()
        $out=[Text.StringBuilder]::new(); $err=[Text.StringBuilder]::new()
        $outBuffer=[char[]]::new(4096); $errBuffer=[char[]]::new(4096)
        $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
        $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
        $outDone=$false; $errDone=$false
        while (!$outDone -or !$errDone -or !$process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Child timeout' }
            if (!$outDone -and $outTask.IsCompleted) {
                $n=$outTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $outDone=$true } else {
                    if ($out.Length+$n -gt 65536) { throw 'stdout cap' }
                    $null=$out.Append($outBuffer,0,$n); $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
                }
            }
            if (!$errDone -and $errTask.IsCompleted) {
                $n=$errTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $errDone=$true } else {
                    if ($err.Length+$n -gt 65536) { throw 'stderr cap' }
                    $null=$err.Append($errBuffer,0,$n); $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
                }
            }
            [Threading.Thread]::Sleep(5)
        }
        $result=[pscustomobject]@{ file=$File; argv=$Arguments; cwd=$project; exit=$process.ExitCode; stdout=$out.ToString().Trim(); stderr=$err.ToString().Trim(); elapsed_ms=$watch.Elapsed.TotalMilliseconds }
        $records.Add($result)
        return $result
    } finally {
        if ($process.Id -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Success($Record) {
    if ($Record.exit -ne 0) { throw "Child failed: $($Record.file): $($Record.stderr)" }
}
$report=[ordered]@{ status='running'; began_utc=[DateTime]::UtcNow.ToString('o'); conditions=@(); records=$records; sources=$sources; contract_exe_count_note='contract says 2; four compiler conditions retained as four EXEs, within unchanged 8MiB budget'; unverified=@('allocation failure injection','other native','full grammar/container','compression ratio','competitive speed','product integration') }
$created=$false
try {
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    if (Test-Path -LiteralPath $work) { throw 'Fresh model root already exists; no overwrite or retry' }
    foreach ($pin in $pins) {
        $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]))
        $locks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        $identity=Identity $path
        if ($identity.sha256 -ne $pin[1]) { throw "Source pin mismatch: $path" }
        $sources.Add($identity)
    }
    $locks.Add([IO.File]::Open($PSCommandPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $sources.Add((Identity $PSCommandPath))
    $report.compiler=Identity $compiler; $report.runtime=Identity $runtime
    if ($report.compiler.sha256 -ne $compilerSha) { throw 'Compiler SHA mismatch' }
    $version=Child $compiler @('--version'); Success $version; $report.compiler_version=$version.stdout
    $null=New-Item -ItemType Directory -Path $work; $created=$true
    $baseline=$null
    foreach ($opt in @(2,3)) { foreach ($overflow in @('yes','no')) {
        $exe=Join-Path $work "model-o$opt-$overflow.exe"
        $arguments=@((Join-Path $PSScriptRoot 'model_audit.rs'),'--edition=2024','--cfg','model_audit','-C',"opt-level=$opt",'-C',"overflow-checks=$overflow",'-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        $build=Child $compiler $arguments; Success $build
        $audit=Child $exe @(); Success $audit
        if ($audit.stderr) { throw 'Unexpected audit stderr' }
        if ($null -eq $baseline) { $baseline=$audit.stdout } elseif ($audit.stdout -ne $baseline) { throw 'Conditions differ' }
        $result=$audit.stdout | ConvertFrom-Json
        if ($result.status -ne 'passed' -or $result.events -ne 393216 -or $result.refusals -ne 918 -or
            $result.prefix_queries -lt $result.events -or $result.state_values -lt 500000 -or
            $result.root_rescales -lt 3 -or $result.local_rescales -lt 3 -or $result.fingerprint -notmatch '^[0-9a-f]{16}$') { throw 'Incomplete model proof' }
        $refusal=Child $exe @('unexpected')
        if ($refusal.exit -ne 2 -or $refusal.stdout -or $refusal.stderr -ne 'arguments are not accepted') { throw 'Argument refusal mismatch' }
        $report.conditions += [pscustomobject]@{ opt=$opt; overflow=$overflow; executable=(Identity $exe); audit=$result }
        $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    } }
    $report.sources_after=@($sources | ForEach-Object {
        $current=Identity $_.path
        if ($current.sha256 -ne $_.sha256 -or $current.bytes -ne $_.bytes) { throw 'Source changed' }
        $current
    })
    $report.status='passed'
} catch { $report.status='failed'; $report.error=$_.Exception.Message; throw } finally {
    if ($created) {
        $report.ended_utc=[DateTime]::UtcNow.ToString('o')
        $report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
        $json=$report | ConvertTo-Json -Depth 10
        if ($json.Length -gt 65536) { throw 'Report cap' }
        [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
        $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    }
    foreach ($stream in $locks) { $stream.Dispose() }
}
$report.conditions | ConvertTo-Json -Depth 5
