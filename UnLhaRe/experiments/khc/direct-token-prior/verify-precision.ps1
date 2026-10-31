[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime = (Get-Process -Id $PID).Path
$expectedRuntime = 'C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha = '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $project 'build/khc-prior-precision-diagnostic-20261002'
$guard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins = @(
    @('../direct-token/cdf_model.rs', '2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53'),
    @('cdf_model.rs', 'C046AF706803795762A6D2B3522A9D8747B08EDDA511DF0D576724F30BFD6E5C'),
    @('prior_math.rs', '138A83296052C562E35493D51943B744D450818D99FA2C09D5D769B08EB3B928'),
    @('precision_probe.rs', '9070ECF1CD53C22457445038959952E39E66F213AE3AC29E4FECE98448775001'),
    @('../PRIOR_PRECISION_DIAGNOSTIC_CONTRACT_20261002.md', '1BDC2A718BB2E5546C329803E250DD6D40D6A58D2FCE87FED38A088CA7689AEB'),
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
$report=[ordered]@{ status='running'; began_utc=[DateTime]::UtcNow.ToString('o'); conditions=@(); records=$records; sources=$sources; capacity_plan=@{max_bytes=8MB; estimated_final_bytes=200KB; executable_reserve_bytes=1MB; report_reserve_bytes=512KB; note='1 small EXE plus bounded JSON; 8MiB pre/post guard, not a process write quota'}; unverified=@('archive-wide size attribution','four compiler configurations','allocation failure injection','other native','full grammar/container','compression ratio','competitive speed','product integration') }
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
    # このprobeのpath付きimportも実解決し、readlock済み集合へ照合する。
    $report.imports=@()
    foreach ($source in @($sources | Where-Object { $_.path.EndsWith('.rs') })) {
        $content=[IO.File]::ReadAllText($source.path)
        if ($content -match 'include!\s*\(') { throw 'Unexpected Rust include' }
        foreach ($match in [regex]::Matches($content,'(?m)^\s*(?:#\[path = "([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')) {
            $relative=if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value+'.rs' }
            $import=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($source.path)) $relative))
            if (!(Test-Path -LiteralPath $import -PathType Leaf) -or $import -notin @($sources.path)) { throw "Unpinned Rust import: $import" }
            $report.imports += [pscustomobject]@{source=$source.path; resolved=$import}
        }
    }
    if ($report.imports.Count -ne 3) { throw 'Unexpected probe import count' }
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    $version=Child $compiler @('--version'); Success $version; $report.compiler_version=$version.stdout
    $null=New-Item -ItemType Directory -Path $work; $created=$true
    $executables=[Collections.Generic.List[object]]::new()
    $capacity=& $guard -WorkDirectory $work -MaxRunMiB 8
    if ($capacity.used_bytes + 1MB + 512KB -gt $capacity.max_bytes) { throw 'Bounded reserve unavailable' }
    $exe=Join-Path $work 'precision-o2-yes.exe'
    $arguments=@((Join-Path $PSScriptRoot 'precision_probe.rs'),'--edition=2024','--cfg','model_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
    $build=Child $compiler $arguments; Success $build
    if ((Get-Item -LiteralPath $exe).Length -gt 1MB) { throw 'Executable reserve exceeded' }
    $exeBefore=Identity $exe; $executables.Add($exeBefore)
    $locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
    $audit=Child $exe @(); Success $audit
    if ($audit.stderr) { throw 'Unexpected probe stderr' }
    $result=$audit.stdout | ConvertFrom-Json
    if ($result.status -ne 'passed' -or $result.updates_per_model -ne 8192 -or $result.counts_checked -ne 1536 -or
        $result.intervals_checked -ne 1024 -or $result.cold_uniform_mass -ne 256 -or $result.cold_total_mass -ne 512 -or
        ($result.cold_old -join ',') -ne '0,8193,8448' -or ($result.cold_new -join ',') -ne '0,249,512' -or
        ($result.hot_old -join ',') -ne '0,40961,41216' -or ($result.hot_new -join ',') -ne '0,33017,33280') { throw 'Incomplete precision diagnostic' }
    $refusal=Child $exe @('unexpected')
    if ($refusal.exit -ne 2 -or $refusal.stdout -or $refusal.stderr -ne 'no arguments') { throw 'Argument refusal mismatch' }
    $report.conditions += [pscustomobject]@{ opt=2; overflow='yes'; executable=(Identity $exe); audit=$result }
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

