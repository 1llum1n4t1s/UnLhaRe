[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ModelSha,
    [Parameter(Mandatory)][ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$PriorSha)
$ErrorActionPreference = 'Stop'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime = (Get-Process -Id $PID).Path
$expectedRuntime = 'C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha = '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $project 'build/khc-direct-token-prior-model-20261002'
$guard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins = @(
    @('cdf_model.rs', $ModelSha),
    @('prior_math.rs', $PriorSha),
    @('model_audit.rs', '3E718BC4D2A5A9EFBD1DD76D7885407B16A5BB96E1522E3ACEBB44C58A5B40B6'),
    @('MODEL_FAILURE_PLAN.md', 'BAD7DBA80EA3AC5C83492A84EC8B1C409C4794862A4BA61EFBDD092523A1864A'),
    @('../DIRECT_TOKEN_PRIOR_CONTRACT_20261002.md', 'FB8373882F90882F8BAB50D3B9ECBC390181A2E769F3720DDDF001C0618752FB'),
    @('../disk-budget.ps1', 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'),
    @('../../../build/khc-direct-token-range-20261002/report.json', '3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AE'),
    @('../../../build/khc-direct-token-model-20261002/report.json', 'A3670F506550B6DA89878B840E7DCB63C770A5FD2F2BAFF3EC1CE19517FB3632'),
    @('../../../build/khc-direct-token-full-20261002-bwt-pin-fix/report.json', 'B2CBF04F6CAFA79DA72EB082A0C957DE468C9AC4945186D8DDABC1EB8AA91C4F')
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
$report=[ordered]@{ status='running'; began_utc=[DateTime]::UtcNow.ToString('o'); conditions=@(); records=$records; sources=$sources; capacity_plan=@{max_bytes=8MB; estimated_final_bytes=1MB; executable_reserve_bytes=1MB; report_reserve_bytes=512KB; note='4 small EXEs plus bounded JSON; reserve checked before each compile'}; unverified=@('allocation failure injection','other native','full grammar/container','compression ratio','competitive speed','product integration') }
$created=$false
try {
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
    if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) { throw 'PowerShell runtime path mismatch' }
    foreach ($path in @($compiler,$runtime)) {
        $locks.Add([IO.File]::Open($path,'Open','Read','Read')); $sources.Add((Identity $path))
    }
    $report.compiler=Identity $compiler; $report.runtime=Identity $runtime
    if ($report.compiler.sha256 -ne $compilerSha) { throw 'Compiler SHA mismatch' }
    if ($report.runtime.sha256 -ne $expectedRuntimeSha) { throw 'Runtime SHA mismatch' }
    # 全importを解決し、固定・lock済み集合に含まれることをchild開始前に確認する。
    $report.imports=@()
    foreach ($source in @($sources | Where-Object { $_.path.EndsWith('.rs') })) {
        $content=[IO.File]::ReadAllText($source.path)
        if ($content -match '#\s*\[\s*path\s*=|include!\s*\(') { throw 'Unexpected external Rust import syntax' }
        foreach ($match in [regex]::Matches($content,'(?m)^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')) {
            $import=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($source.path)) ($match.Groups[1].Value+'.rs')))
            if (!(Test-Path -LiteralPath $import -PathType Leaf) -or $import -notin @($sources.path)) { throw "Unpinned Rust import: $import" }
            $report.imports += [pscustomobject]@{source=$source.path; resolved=$import}
        }
    }
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    $version=Child $compiler @('--version'); Success $version; $report.compiler_version=$version.stdout
    $null=New-Item -ItemType Directory -Path $work; $created=$true
    $baseline=$null
    $executables=[Collections.Generic.List[object]]::new()
    foreach ($opt in @(2,3)) { foreach ($overflow in @('yes','no')) {
        $capacity=& $guard -WorkDirectory $work -MaxRunMiB 8
        if ($capacity.used_bytes + 1MB + 512KB -gt $capacity.max_bytes) { throw 'Bounded reserve unavailable' }
        $exe=Join-Path $work "model-o$opt-$overflow.exe"
        $arguments=@((Join-Path $PSScriptRoot 'model_audit.rs'),'--edition=2024','--cfg','model_audit','-C',"opt-level=$opt",'-C',"overflow-checks=$overflow",'-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        $build=Child $compiler $arguments; Success $build
        if ((Get-Item -LiteralPath $exe).Length -gt 1MB) { throw 'Executable reserve exceeded' }
        $exeBefore=Identity $exe; $executables.Add($exeBefore)
        $locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
        $audit=Child $exe @(); Success $audit
        if ($audit.stderr) { throw 'Unexpected audit stderr' }
        if ($null -eq $baseline) { $baseline=$audit.stdout } elseif ($audit.stdout -ne $baseline) { throw 'Conditions differ' }
        $result=$audit.stdout | ConvertFrom-Json
        if ($result.status -ne 'passed' -or $result.events -ne 393216 -or $result.refusals -ne 1014 -or $result.scale_refusals -ne 32769 -or
            $result.scale_comparisons -lt 8000000 -or $result.correction_witnesses -le 0 -or
            $result.selection_queries -lt $result.prefix_queries -or
            $result.prefix_queries -lt $result.events -or $result.state_values -lt 500000 -or
            $result.root_rescales -lt 3 -or $result.local_rescales -lt 3 -or $result.fingerprint -notmatch '^[0-9a-f]{16}$') { throw 'Incomplete model proof' }
        $refusal=Child $exe @('unexpected')
        if ($refusal.exit -ne 2 -or $refusal.stdout -or $refusal.stderr -ne 'arguments are not accepted') { throw 'Argument refusal mismatch' }
        if ((Identity $exe).sha256 -ne $exeBefore.sha256) { throw 'Executable changed after execution' }
        $report.conditions += [pscustomobject]@{ opt=$opt; overflow=$overflow; executable=(Identity $exe); audit=$result }
        $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    } }
    $report.sources_after=@($sources | ForEach-Object {
        $current=Identity $_.path
        if ($current.sha256 -ne $_.sha256 -or $current.bytes -ne $_.bytes) { throw 'Source changed' }
        $current
    })
    $report.executables_after=@($executables | ForEach-Object {
        $current=Identity $_.path
        if ($current.sha256 -ne $_.sha256 -or $current.bytes -ne $_.bytes) { throw 'Executable changed' }; $current
    })
    if (@(Get-ChildItem -LiteralPath $work -Force | Where-Object { $_.FullName -notin @($executables.path) }).Count) { throw 'Unexpected artifact' }
    $report.status='passed'
} catch { $report.status='failed'; $report.error=$_.Exception.Message; throw } finally {
    try {
    if ($created) {
        $report.ended_utc=[DateTime]::UtcNow.ToString('o')
        $report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
        $json=$report | ConvertTo-Json -Depth 10
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 512KB) { throw 'Report cap' }
        [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
        $null=& $guard -WorkDirectory $work -MaxRunMiB 8
    }
    } finally {
    foreach ($stream in $locks) { $stream.Dispose() }
    }
}
[pscustomobject]@{status=$report.status;conditions=$report.conditions.Count;audit=$report.conditions[0].audit;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8)} | ConvertTo-Json -Depth 5
