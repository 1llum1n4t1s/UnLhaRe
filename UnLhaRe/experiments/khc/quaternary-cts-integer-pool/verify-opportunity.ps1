[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-quaternary-cts-integer-pool-opportunity-20261002'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins=@(
    @('../QUATERNARY_CTS_INTEGER_POOL_CONTRACT_20261002.md','EE130558C966D6C96DE8887050A01D39FA3FDC59802AC70A867BC0DD53BE28FA'),
    @('fixed_math.rs','A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD'),@('integer_pool.rs','7135CC9E6F5CF57191DC6EE409D8C32C8EF9FEB9C1B6B2D7B18C7B436F56C625'),@('opportunity.rs','5DEC4BD1AAAC58BEFB8F933CD5A2EB48D82CC911DAA9C631B044C3F00631003F'),@('FAILURE_PLAN.md','7B982332B80124B73599E594FA20FB9755AAA23BDBF427BD31F5A55DB94C5273'),
    @('../quaternary-cts-q32/integer_cts.rs','5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7'),
    @('../causal-bayes-sais/bwt.rs','810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'),
    @('../direct-token/cdf_model.rs','2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53'),
    @('../quaternary-cts/opportunity.rs','EA212C9326C62C6D420E2B1A738B0D8B3C63A39C75AB12B1682F388303FD98F3'),
    @('../quaternary-cts/cts_model.rs','4054EA03592A0D0548E20B1897EBE678BF0B5F901C5E23F3CDBC8B564BFD97A8'),
    @('../QUATERNARY_CTS_CONTRACT_20261002.md','20417FCEEE4A908725729B9E6CA09A90D7D66E78197464279CDA10B70C51A051'),
    @('../QUATERNARY_CTS_RESULT_20261002.md','3AFF7A2E9274AA7A3753AC32C8CE9C73CCBF21E0726CED20634701E466DF514E'),
    @('../../../build/khc-quaternary-cts-opportunity-20261002/report.json','BA991A3240D62B5512504DFFDC80240D0F0306491CD00D12CFCC8A61C12F3DA2'),
    @('../QUATERNARY_CTS_Q32_PRIMITIVE_CONTRACT_20261002.md','3A5FD8AB1A03A834A4F497B8734A2F44468F38B7A1ACD11D02674758D075C14D'),
    @('../QUATERNARY_CTS_Q32_PRIMITIVE_RESULT_20261002.md','BD045390F92312C188E092F4C221726FF259201CB62BA63C13B4CEC5E4F8EC57'),
    @('../QUATERNARY_CTS_Q32_PROOF_CLOSURE_20261002.md','5B9A66B06BA8120C47392D130DACA8E2F89F620249DFC7F7FD89C6372135DE91'),
    @('../../../build/khc-quaternary-cts-q32-primitive-20261002-proof-closure/report.json','3E50A4A0B3A2C7FE3983BA09D3241C27481B63AE7D05085BAFDAA8CD56B30309'),
    @('../../../build/khc-current-source-native-solid-20260923-group/all.group','18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'),
    @('../disk-budget.ps1','F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7')
)
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$records=[Collections.Generic.List[object]]::new()
function Identity([string]$Path) {
    [pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash;bytes=(Get-Item -LiteralPath $Path).Length}
}
function Bounded-Text([string]$Text) {
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -le 65536) {return $Text}
    $low=0;$high=[Math]::Min($Text.Length,65536)
    while ($low -lt $high) {
        $middle=[int][Math]::Ceiling(($low+$high)/2.0)
        if ([Text.Encoding]::UTF8.GetByteCount($Text.Substring(0,$middle)) -le 65536) {$low=$middle}else {$high=$middle-1}
    }
    if ($low -gt 0 -and [char]::IsHighSurrogate($Text[$low-1])) {$low--}
    return $Text.Substring(0,$low)
}
function Child([string]$File, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File; $info.WorkingDirectory=$project; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started=$false
    $out=[Text.StringBuilder]::new(); $err=[Text.StringBuilder]::new()
    try {
        $null=$process.Start();$started=$true
        $outBuffer=[char[]]::new(4096); $errBuffer=[char[]]::new(4096)
        $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
        $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
        $outDone=$false; $errDone=$false
        while (!$outDone -or !$errDone -or !$process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Child timeout' }
            if (!$outDone -and $outTask.IsCompleted) {
                $n=$outTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $outDone=$true } else {
                    $null=$out.Append($outBuffer,0,$n)
                    if ($out.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt 65536) {throw 'stdout byte cap'}; $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
                }
            }
            if (!$errDone -and $errTask.IsCompleted) {
                $n=$errTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $errDone=$true } else {
                    $null=$err.Append($errBuffer,0,$n)
                    if ($err.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 65536) {throw 'stderr byte cap'}; $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
                }
            }
            [Threading.Thread]::Sleep(5)
        }
        $result=[pscustomobject]@{ file=$File; argv=$Arguments; cwd=$project; started=$started; status='completed'; exit=$process.ExitCode; stdout=$out.ToString().Trim(); stderr=$err.ToString().Trim(); elapsed_ms=$watch.Elapsed.TotalMilliseconds; error=$null }
        $records.Add($result)
        return $result
    } catch {
        $failure=$_.Exception.Message
        if ($started -and !$process.HasExited) {$process.Kill($true);$process.WaitForExit()}
        $exit=if ($started -and $process.HasExited) {$process.ExitCode}else {$null}
        $status=if ($started) {'interrupted'}else {'start-failed'}
        $records.Add([pscustomobject]@{file=$File;argv=$Arguments;cwd=$project;started=$started;status=$status;exit=$exit;stdout=(Bounded-Text $out.ToString());stderr=(Bounded-Text $err.ToString());elapsed_ms=$watch.Elapsed.TotalMilliseconds;error=$failure})
        throw
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Success($Record) {
    if ($Record.exit -ne 0) { throw "Child failed: $($Record.file): $($Record.stderr)" }
}


$scale=4294967296.0
# 配列内divisionを使わず、これらのscalar式はpreflightでも実際に評価する。
$bounds=[ordered]@{
    max_local_ln_error=2e-8;max_local_exp_error=2e-8;max_q_error_bound_ratio=1.0
    max_P_error=2e-6;max_gradient_error=2e-3;max_next_weight_error=1e-5
    synthetic_max_P_error=2e-6;synthetic_max_gradient_error=2e-3;synthetic_max_next_weight_error=1e-5
}
$qAbsoluteBound=(8.0 / $scale)
foreach ($value in $bounds.Values) {if ($value -isnot [double] -or ![double]::IsFinite($value) -or $value -le 0) {throw 'Non-scalar bound expression'}}
if ($qAbsoluteBound -isnot [double] -or $qAbsoluteBound -ne 1.862645149230957e-9) {throw 'Q bound expression mismatch'}
$report=[ordered]@{
    status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@()
    bits_order=@('CDF','global','symbol','recent','joint','cts','P')
    numerical_spec='canonical Q48 grid ln/exp, Q32 categorical CTS and five-feature pool, Hamilton CDF32768'
    scalar_bounds=$bounds;q_absolute_bound=$qAbsoluteBound;scalar_bounds_preflight_evaluated=$true
    capacity_plan=@{max_bytes=8MB;estimated_final_bytes=512KB;executable_reserve_bytes=1MB;report_reserve_bytes=512KB;note='pre/post guard, not a process write quota'}
    unverified=@('independent f64 continuous trajectory','integer range and actual frame','formal performance and CPU','holdout/categories','four native environments','product/API integration')
    full_benchmark_allowed=$false
}
$created=$false;$exe=$null
function Save-Report {
    if (!$created) {return}
    $report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
    $json=$report | ConvertTo-Json -Depth 15
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 512KB) {throw 'Report cap'}
    [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
    $null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
function Validate-Audit($result) {
    foreach ($name in @('status','diagnostic_only','integer_pool_verified','wire_size_speed_verified','full_benchmark_allowed','f64_continuous_trajectory_verified','gate_basis','opportunity_gate','cdf_entropy_bits','P_entropy_bits','projected_CDF_entropy_escape_bits','projected_P_entropy_escape_bits')) {
        if ($null -eq $result.PSObject.Properties[$name]) {throw "Missing audit field: $name"}
    }
    if ($result.status -ne 'passed' -or !$result.diagnostic_only -or !$result.integer_pool_verified -or $result.wire_size_speed_verified -or $result.full_benchmark_allowed -or $result.f64_continuous_trajectory_verified -or !$result.unverified_integer_range_frame_performance -or $result.gate_basis -ne 'CDF entropy plus common escape') {throw 'Integer opportunity scope mismatch'}
    $expected=@{Q=4294967296;ln_cases=114806;count_ln_cases=32768;cts_ln_boundary_cases=97;cts_ln_grid_cases=81941;exp_cases=32769;ln_lut_values=4097;exp_lut_values=4097;exp_additional_cases=5;math_invalid_cases=15;synthetic_predictions=10;finite_differences=50;pool_edge_predictions=244;pool_dedicated_fixture_predictions=3;synthetic_local_predictions=257;bigint_pool_fixtures=1;pool_invalid_cases=8;branch_rejection_cases=5;runs=889227;alphabet=257;primary=1762795;rank_tokens=889227;length_tokens=889227;rank_oracle_checked=889227;tree_cases=66049;tree_max_depth=7;branches_oracle_checked=3825340;gradients_checked=19126700;state_values_checked=5808642;base_state_values_checked=3187200;cts_state_values_checked=2621442;old_intervals_checked=1778454;escape_bytes=742;escape_bits=5936;payload_budget_bits=3866504;local_predictions=3825340}
    foreach ($name in $expected.Keys) {if ($result.$name -ne $expected[$name]) {throw "Fixed count mismatch: $name"}}
    if ($result.small_oracle_division -ne '128-step binary long division for math and pool primitives only' -or $result.full_oracle_division -ne 'native u128 with independent formulas and ranking' -or $result.cts_oracle_division -ne 'native u128; prior primitive has separate long-division proof') {throw 'Oracle division scope mismatch'}
    if ($result.local_ln_exp_bound -ne 2e-8 -or $result.local_q_relative_bound -ne 1e-6 -or $result.local_q_absolute_bound -ne $qAbsoluteBound -or $result.local_P_bound -ne 2e-6 -or $result.local_gradient_bound -ne 2e-3 -or $result.local_next_weight_bound -ne 1e-5 -or $result.legacy_f64_tolerance -ne 2e-10 -or $result.finite_difference_step -ne 1e-5 -or $result.finite_difference_tolerance -ne 2e-6) {throw 'Fixed local bound mismatch'}
    foreach ($name in $bounds.Keys) {
        if ($null -eq $result.PSObject.Properties[$name]) {throw "Missing numeric field: $name"}
        $value=[double]$result.$name
        if (![double]::IsFinite($value) -or $value -lt 0 -or $value -gt $bounds[$name]) {throw "Local error exceeded: $name"}
    }
    foreach ($name in @('max_q_error','synthetic_max_q_error','cdf_entropy_bits','P_entropy_bits','projected_CDF_entropy_escape_bits','projected_P_entropy_escape_bits')) {
        $value=[double]$result.$name
        if (![double]::IsFinite($value) -or $value -lt 0) {throw "Invalid finite nonnegative value: $name"}
    }
    if ($result.tree_nodes.Count -ne 2 -or $result.tree_nodes[0] -ne 142 -or $result.tree_nodes[1] -ne 142 -or $result.branches[0] -ne 2725772 -or $result.branches[1] -ne 1099568) {throw 'Fixed topology/branch mismatch'}
    if ($result.grammar_digests.Count -ne 2 -or $result.grammar_digests[0] -ne '58735a2b7383d755' -or $result.grammar_digests[1] -ne '58735a2b7383d755') {throw 'Grammar digest mismatch'}
    $classCounts=@(889227,620240,1216305,889227,64372,145969)
    if ($result.cts_class_observations.Count -ne 6 -or $result.cts_class_loss_bits.Count -ne 6 -or $result.cts_node_queries.Count -ne 6 -or $result.cts_cold_node_queries.Count -ne 6) {throw 'CTS class shape mismatch'}
    for ($class=0;$class -lt 6;$class++) {
        if ($result.cts_class_observations[$class] -ne $classCounts[$class] -or $result.cts_node_queries[$class].Count -ne 9 -or $result.cts_cold_node_queries[$class].Count -ne 9) {throw 'CTS class count mismatch'}
        for ($level=0;$level -lt 9;$level++) {
            if ($result.cts_node_queries[$class][$level] -ne $classCounts[$class] -or $result.cts_cold_node_queries[$class][$level] -lt 0 -or $result.cts_cold_node_queries[$class][$level] -gt $classCounts[$class]) {throw 'CTS query/cold mismatch'}
        }
    }
    $prior=(Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-cts-opportunity-20261002/report.json') -Raw | ConvertFrom-Json).audit
    $report.expert_crosscheck=@();$report.component_comparison=@()
    for ($component=0;$component -lt 2;$component++) {
        if ($result.bits[$component].Count -ne 7 -or $result.prefix_counts[$component].Count -ne 4 -or $result.max_depth[$component] -ne $prior.max_depth[$component] -or $result.branches[$component] -ne $prior.branches[$component] -or [Math]::Abs($result.old_bits[$component]-$prior.old_bits[$component]) -gt 1e-4) {throw 'Inherited oldflat/depth/branch mismatch'}
        for ($i=0;$i -lt 4;$i++) {if ($result.prefix_counts[$component][$i] -ne $prior.prefix_counts[$component][$i]) {throw 'Inherited prefix mismatch'}}
        for ($expert=1;$expert -lt 5;$expert++) {
            if ([Math]::Abs($result.bits[$component][$expert]-$prior.bits[$component][$expert]) -gt 1e-4) {throw 'Inherited four-expert loss mismatch'}
            $report.expert_crosscheck+=@{component=$component;expert=$report.bits_order[$expert];previous_bits=$prior.bits[$component][$expert];current_bits=$result.bits[$component][$expert]}
        }
        foreach ($loss in $result.bits[$component]) {if (![double]::IsFinite([double]$loss) -or $loss -lt 0) {throw 'Invalid component loss'}}
        $classLoss=0.0;for ($i=0;$i -lt 3;$i++) {$classLoss+=$result.cts_class_loss_bits[3*$component+$i]}
        if ([Math]::Abs($classLoss-$result.bits[$component][5]) -gt 1e-4) {throw 'CTS component loss mismatch'}
        $report.component_comparison+=@{component=$component;previous_f64_P_bits=$prior.bits[$component][0];integer_CDF_bits=$result.bits[$component][0];integer_P_bits=$result.bits[$component][6]}
    }
    for ($expert=0;$expert -lt 4;$expert++) {
        if ($result.cold_expert_branches[$expert] -ne $prior.cold_expert_branches[$expert] -or $result.rescales[$expert] -ne $prior.rescales[$expert]) {throw 'Inherited cold/rescale mismatch'}
    }
    for ($class=0;$class -lt 6;$class++) {for ($level=0;$level -lt 9;$level++) {
        if ($result.cts_cold_node_queries[$class][$level] -ne $prior.cts_cold_node_queries[$class][$level] -or $result.cts_node_queries[$class][$level] -ne $prior.cts_node_queries[$class][$level]) {throw 'Inherited CTS causal path/cold mismatch'}
    }}
    $cdf=$result.bits[0][0]+$result.bits[1][0];$p=$result.bits[0][6]+$result.bits[1][6]
    $projected=$cdf+5936;$projectedP=$p+5936;$budget=3866504
    if ([Math]::Abs($cdf-$result.cdf_entropy_bits) -gt 1e-4 -or [Math]::Abs($p-$result.P_entropy_bits) -gt 1e-4 -or [Math]::Abs($projected-$result.projected_CDF_entropy_escape_bits) -gt 1e-4 -or [Math]::Abs($projectedP-$result.projected_P_entropy_escape_bits) -gt 1e-4 -or $result.opportunity_gate -ne ($projected -lt $budget)) {throw 'CDF primary opportunity gate mismatch'}
    $report.CDF_opportunity_margin_bits=$budget-$projected;$report.CDF_opportunity_margin_byte_equivalent=($budget-$projected)/8.0
    $report.P_CDF_difference_bits=$cdf-$p
}
try {
    if (Test-Path -LiteralPath $work) {throw 'Fresh root already exists; no overwrite or retry'}
    foreach ($pin in $pins) {
        $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]));$locks.Add([IO.File]::Open($path,'Open','Read','Read'))
        $id=Identity $path;if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"};$sources.Add($id)
    }
    if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
    foreach ($path in @($PSCommandPath,$compiler,$runtime)) {$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))}
    $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
    if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime identity mismatch'}
    $compiledSources=@('opportunity.rs','fixed_math.rs','integer_pool.rs','../quaternary-cts-q32/integer_cts.rs','../causal-bayes-sais/bwt.rs','../direct-token/cdf_model.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
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
    if ($report.imports.Count -ne 5 -or @($report.imports | Where-Object {$_.source -ne $compiledSources[0]}).Count -or @($report.imports.resolved | Sort-Object -Unique).Count -ne 5) {throw 'Unexpected six-source/five-edge graph'}
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    if ($report.disk_before.used_bytes+1MB+512KB -gt $report.disk_before.max_bytes) {throw 'Capacity reserve'}
    if ($Execute) {
        $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';$report.execution_stage='compiler-version'
        $version=Child $compiler @('--version');Success $version
        if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)') {throw 'Compiler version mismatch'};$report.compiler_version=$version.stdout
        $exe=Join-Path $work 'opportunity-o2-yes.exe'
        $build=Child $compiler @((Join-Path $PSScriptRoot 'opportunity.rs'),'--edition=2024','--cfg','model_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        Success $build
        $report.executable_before=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$report.execution_stage='executable-identity-saved';Save-Report
        if ($report.executable_before.bytes -gt 1MB) {throw 'Executable reserve exceeded'}
        $audit=Child $exe @((Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'))
        $report.execution_stage='child-record-saved';Save-Report;Success $audit
        $result=$audit.stdout | ConvertFrom-Json
        $report.audit=$result;$report.execution_stage='parsed-audit-saved';Save-Report
        Validate-Audit $result
        $report.executable_after=Identity $exe
        if ($report.executable_after.sha256 -ne $report.executable_before.sha256 -or $report.executable_after.bytes -ne $report.executable_before.bytes) {throw 'Executable identity changed'}
        $allowed=@($exe,(Join-Path $work 'report.json'))
        if (@(Get-ChildItem -LiteralPath $work -Force | Where-Object {$_.FullName -notin $allowed}).Count) {throw 'Unexpected artifact'}
        $report.status='passed';$report.execution_stage='validated'
    }
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
    try {
        $report.sources_after=@($sources | ForEach-Object {
            $now=Identity $_.path
            if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes) {throw 'Source identity changed'}
            $now
        })
        if ($created) {
            if ($exe -and (Test-Path -LiteralPath $exe)) {$report.executable_after=Identity $exe}
            $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
        }
    } finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;audit=$report.audit;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8)} | ConvertTo-Json -Depth 6}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;capacity=$report.disk_before;compiler=$report.compiler;runtime=$report.runtime;runtime_version=$report.runtime_version;scalar_bounds=$bounds;q_absolute_bound=$qAbsoluteBound;scalar_bounds_preflight_evaluated=$true} | ConvertTo-Json -Depth 5}

