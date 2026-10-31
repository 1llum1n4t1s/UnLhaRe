[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-quaternary-cts-q32-primitive-20261002'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins=@(
    @('../QUATERNARY_CTS_Q32_PRIMITIVE_CONTRACT_20261002.md','3A5FD8AB1A03A834A4F497B8734A2F44468F38B7A1ACD11D02674758D075C14D'),
    @('integer_cts.rs','5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7'),
    @('primitive_audit.rs','2EC2AE50F33CC74597F9C45B7AC75B6F63774D4E301A5B4643D186FDA7B836EE'),
    @('FAILURE_PLAN.md','665F2B88F5B827A4A65ECE64A9A1AA1898D600F916A7B8830772874947F48778'),
    @('../QUATERNARY_CTS_CONTRACT_20261002.md','20417FCEEE4A908725729B9E6CA09A90D7D66E78197464279CDA10B70C51A051'),
    @('../quaternary-cts/cts_model.rs','4054EA03592A0D0548E20B1897EBE678BF0B5F901C5E23F3CDBC8B564BFD97A8'),
    @('../quaternary-cts/opportunity.rs','EA212C9326C62C6D420E2B1A738B0D8B3C63A39C75AB12B1682F388303FD98F3'),
    @('../QUATERNARY_CTS_RESULT_20261002.md','3AFF7A2E9274AA7A3753AC32C8CE9C73CCBF21E0726CED20634701E466DF514E'),
    @('../../../build/khc-quaternary-cts-opportunity-20261002/report.json','BA991A3240D62B5512504DFFDC80240D0F0306491CD00D12CFCC8A61C12F3DA2'),
    @('../disk-budget.ps1','F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7')
)
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$records=[Collections.Generic.List[object]]::new()
function Identity([string]$Path) {
    [pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash;bytes=(Get-Item -LiteralPath $Path).Length}
}
function Child([string]$File, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File; $info.WorkingDirectory=$project; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started=$false
    try {
        $null=$process.Start();$started=$true
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
                    $null=$out.Append($outBuffer,0,$n); if ([Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt 65536) {throw 'stdout byte cap'}; $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
                }
            }
            if (!$errDone -and $errTask.IsCompleted) {
                $n=$errTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $errDone=$true } else {
                    if ($err.Length+$n -gt 65536) { throw 'stderr cap' }
                    $null=$err.Append($errBuffer,0,$n); if ([Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 65536) {throw 'stderr byte cap'}; $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
                }
            }
            [Threading.Thread]::Sleep(5)
        }
        $result=[pscustomobject]@{ file=$File; argv=$Arguments; cwd=$project; exit=$process.ExitCode; stdout=$out.ToString().Trim(); stderr=$err.ToString().Trim(); elapsed_ms=$watch.Elapsed.TotalMilliseconds }
        $records.Add($result)
        return $result
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Success($Record) {
    if ($Record.exit -ne 0) { throw "Child failed: $($Record.file): $($Record.stderr)" }
}

$report=[ordered]@{
    status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@()
    numerical_spec='new categorical Q32 CTS primitive; Hamilton remainder descending then child ascending; rawmass posterior'
    capacity_plan=@{max_bytes=8MB;estimated_final_bytes=400KB;executable_reserve_bytes=1MB;report_reserve_bytes=512KB;note='pre/post guard, not a process write quota'}
    fixed_plan=@{Q=4294967296;classes=6;levels=9;nodes_per_class=87381;observation_cap=3825340;legacy_f64_tolerance=2e-10}
    unverified=@('ln/exp and five-feature pool','integer whole-input entropy opportunity gate','CDF/range rounding','actual frame size','formal encode/decode performance and CPU','holdout/categories','four native environments','product/API integration','independent f64 continuous trajectory and aggregate entropy equality')
    full_benchmark_allowed=$false
}
$created=$false
try {
    if (Test-Path -LiteralPath $work) {throw 'Fresh root already exists; no overwrite or retry'}
    foreach ($pin in $pins) {
        $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]))
        $locks.Add([IO.File]::Open($path,'Open','Read','Read'))
        $id=Identity $path;if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"};$sources.Add($id)
    }
    if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
    foreach ($path in @($PSCommandPath,$compiler,$runtime)) {$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))}
    $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
    if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime identity mismatch'}
    $compiledSources=@('primitive_audit.rs','integer_cts.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
    foreach ($entry in @($sources | Where-Object {$_.path -in $compiledSources})) {
        $content=[IO.File]::ReadAllText($entry.path)
        if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b') {throw 'Unexpected include or extern crate'}
        $matches=[regex]::Matches($content,'(?m)^\s*(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
        if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{') {throw 'Unsupported module declaration'}
        foreach ($match in $matches) {
            $relative=if ($match.Groups[1].Success) {$match.Groups[1].Value}else {$match.Groups[2].Value+'.rs'}
            $resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($entry.path)) $relative))
            if (!(Test-Path -LiteralPath $resolved -PathType Leaf) -or $resolved -notin $compiledSources) {throw "Unpinned compile import: $resolved"}
            $report.imports+=@{source=$entry.path;resolved=$resolved}
        }
    }
    if ($report.imports.Count -ne 1 -or $report.imports[0].source -ne $compiledSources[0] -or $report.imports[0].resolved -ne $compiledSources[1]) {throw 'Unexpected two-source compile graph'}
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    if ($report.disk_before.used_bytes+1MB+512KB -gt $report.disk_before.max_bytes) {throw 'Capacity reserve'}
    if ($Execute) {
        $null=New-Item -ItemType Directory -Path $work;$created=$true
        $version=Child $compiler @('--version');Success $version
        if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)') {throw 'Compiler version mismatch'}
        $report.compiler_version=$version.stdout
        $exe=Join-Path $work 'primitive-o2-yes.exe'
        $build=Child $compiler @((Join-Path $PSScriptRoot 'primitive_audit.rs'),'--edition=2024','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        Success $build
        if ((Get-Item -LiteralPath $exe).Length -gt 1MB) {throw 'Executable reserve exceeded'}
        $exeBefore=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
        $audit=Child $exe @();Success $audit
        $result=$audit.stdout | ConvertFrom-Json
        if ($result.status -ne 'passed' -or !$result.diagnostic_only -or !$result.integer_primitive_only -or $result.wire_size_speed_verified -or $result.integer_pool_verified -or $result.opportunity_gate_evaluated -or $result.full_benchmark_allowed -or $result.f64_continuous_trajectory_verified -or !$result.rejection_state_direct_comparison) {throw 'Primitive scope mismatch'}
        if ('opportunity_gate' -in $result.PSObject.Properties.Name) {throw 'Primitive cannot claim opportunity gate'}
        $expected=@{Q=4294967296;classes=6;levels=9;nodes_per_class=87381;observation_cap=3825340;path_cases=65536;path_levels_checked=589824;maximum_heap_index=87380;kt_cases=5184;kt_cap_cases=8;bigint_fixtures=2;mixture_predictions=60;mixture_updates=450;small_depth_predictions=84;small_depth_updates=210;scalar_rejections=18;state_rejections=22;series_branches=384;series_node_updates=3456;state_values_checked=2621442;kt_error_comparisons=25062;recursive_mix_error_comparisons=12102;q32_rawmass_update_error_comparisons=3882}
        foreach ($field in $expected.Keys) {if ($result.$field -ne $expected[$field]) {throw "Fixed count mismatch: $field"}}
        if ($result.class_observations.Count -ne 6 -or @($result.class_observations | Where-Object {$_ -ne 64}).Count) {throw 'Class separation count mismatch'}
        $scale=4294967296.0
        if ($result.local_kt_bound -ne 2.0/$scale -or $result.local_max_depth_mix_bound -ne 18.0/$scale -or $result.local_q32_rawmass_update_bound -ne 4.0/$scale -or $result.legacy_f64_tolerance -ne 2e-10) {throw 'Fixed local bounds mismatch'}
        foreach ($pair in @(@('max_local_kt_error',2.0/$scale),@('max_local_recursive_mix_error',18.0/$scale),@('max_local_q32_rawmass_posterior_error',4.0/$scale),@('max_local_q32_rawmass_switch_error',4.0/$scale))) {
            $value=[double]$result.($pair[0])
            if (![double]::IsFinite($value) -or $value -lt 0 -or $value -gt $pair[1]) {throw "Local error bound exceeded: $($pair[0])"}
        }
        if ($result.local_error_scope -ne 'KT and recursive mix use same raw counts and Q32 weights; posterior and switch use already quantized KT and child mixed for one update only') {throw 'Local error scope mismatch'}
        $report.audit=$result;$report.executable=Identity $exe
        if ($report.executable.sha256 -ne $exeBefore.sha256 -or $report.executable.bytes -ne $exeBefore.bytes) {throw 'Executable identity changed'}
        if (@(Get-ChildItem -LiteralPath $work -Force | Where-Object {$_.FullName -ne $exe}).Count) {throw 'Unexpected artifact'}
        $report.status='passed'
    }
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
    try {
        $report.sources_after=@($sources | ForEach-Object {
            $now=Identity $_.path
            if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes) {throw 'Source identity changed'}
            $now
        })
        if ($created) {
            $report.ended_utc=[DateTime]::UtcNow.ToString('o')
            $report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
            $json=$report | ConvertTo-Json -Depth 12
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 512KB) {throw 'Report cap'}
            [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
            $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8
        }
    } finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;audit=$report.audit;report=(Identity (Join-Path $work 'report.json'));capacity=$report.disk_after} | ConvertTo-Json -Depth 6}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;capacity=$report.disk_before;compiler=$report.compiler;runtime=$report.runtime;runtime_version=$report.runtime_version} | ConvertTo-Json -Depth 5}

