[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime = (Get-Process -Id $PID).Path
$expectedRuntime = 'C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha = '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $project 'build/khc-quaternary-logpool-opportunity-20261002'
$guard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins = @(
    @('../QUATERNARY_LOGPOOL_CONTRACT_20261002.md', 'FA0E5F3AA5C659D7DD48D2EBF19F39BC3CB9C5C4EF5051B5CD7861810EEC56E5'),
    @('../quaternary-context/opportunity.rs', '653BD8743F71ED0CEF5D9C6F146C794A0A098ACAC20112774C43CCE3FCB0434D'),
    @('../quaternary-context/verify-opportunity.ps1', 'ECA619D08C36627125F28FBF874E0D1E466A14980D6DE3006CB504F0B9EF88A0'),
    @('../../../build/khc-quaternary-context-opportunity-20261002/report.json', 'D5F126BCD9F86D0A355AE7A8F5CB1550E23DA5F58A8F045E5C5281E055357D99'),
    @('opportunity.rs', '09A858DA1FD1C712D548D53AA580747CF68B74266419A4E1419369961E3B5C6D'),
    @('FAILURE_PLAN.md', '492431F92B9F9FDCC2206E182425ED4156484D053B4FA2A8119808614B7269E7'),
    @('../causal-bayes-sais/bwt.rs', '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'),
    @('../causal-bayes-sais/codec.rs', '5F9CF36402E0F9125B3773AF9CB8236EFEA9062ACDB5875BBED7A5D2E17B7EA6'),
    @('../direct-token/cdf_model.rs', '2F8308785D64BD65004A09529F76CC69E98E9DDA781BFCFB86BC76ADB8139E53'),
    @('../direct-token-loss/verify-loss.ps1', '22DAFE881A194AA85442BE0378EC054DAC662D80C7C12038C82783C0C5CCB881'),
    @('../DIRECT_TOKEN_LOSS_RESULT_20261002.md', '54BB89B95CD11FC0AA7F0B59690B62D7DF59ABFA418772E1F6EE417AC956A166'),
    @('../QUATERNARY_CONTEXT_CONTRACT_20261002.md', 'C480B08D4D3A5934B6D461BAB17BCC7252F2D0698FD5CE005FCE6B6CA8E06F26'),
    @('../QUATERNARY_CONTEXT_RANK_SIDEINFO_20261002.md', '0A9B025CE283F39691C0EB660DDCBBC18CEE6226FE66EEB549A2CAF5678CB201'),
    @('../disk-budget.ps1', 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'),
    @('../../../build/khc-current-source-native-solid-20260923-group/all.group', '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'),
    @('../../../build/khc-direct-token-full-20261002-bwt-pin-fix/report.json', 'B2CBF04F6CAFA79DA72EB082A0C957DE468C9AC4945186D8DDABC1EB8AA91C4F'),
    @('../../../build/khc-direct-token-loss-20261002/report.json', 'B9C917798B1B335DC12F684AEBE32BC45D58C80E856F500859038702B0F56D5B')
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
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@();bits_order=@('mixed','global','symbol','recent','joint');numeric_plan=@{tolerance=2e-10;finite_difference_step=1e-5;finite_difference_tolerance=2e-6;aggregate_bits_tolerance=1e-4};capacity_plan=@{max_bytes=8MB;estimated_final_bytes=300KB;executable_reserve_bytes=1MB;report_reserve_bytes=512KB;note='pre/post guard, not a process write quota'};unverified=@('integer wire','range rounding','full frame size','encode/decode performance','holdout/categories','four native','product/API integration')}
$created=$false
try {
    if (Test-Path -LiteralPath $work) { throw 'Fresh root already exists; no overwrite or retry' }
    foreach ($pin in $pins) {
        $path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]))
        $locks.Add([IO.File]::Open($path,'Open','Read','Read'))
        $id=Identity $path
        if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"}
        $sources.Add($id)
    }
    if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
    foreach ($path in @($PSCommandPath,$compiler,$runtime)) {
        $locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))
    }
    $report.compiler=Identity $compiler;$report.runtime=Identity $runtime
    $report.runtime_version=$PSVersionTable.PSVersion.ToString()
    if ($report.runtime_version -ne '7.6.5') {throw 'Runtime version mismatch'}
    if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha) {throw 'Compiler/runtime SHA mismatch'}
    # codec.rsはhash仕様の参照資料でありcompile対象ではない。実import graphのみを検査する。
    $compiledSources=@('opportunity.rs','../causal-bayes-sais/bwt.rs','../direct-token/cdf_model.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
    foreach ($source in @($sources | Where-Object {$_.path -in $compiledSources})) {
        $content=[IO.File]::ReadAllText($source.path)
        if ($content -match 'include!\s*\(') {throw 'Unexpected include'}
        foreach ($match in [regex]::Matches($content,'(?m)^\s*(?:#\[path = "([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')) {
            $relative=if ($match.Groups[1].Success) {$match.Groups[1].Value} else {$match.Groups[2].Value+'.rs'}
            $resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($source.path)) $relative))
            if (!(Test-Path -LiteralPath $resolved -PathType Leaf) -or $resolved -notin @($sources.path)) {throw "Unpinned import: $resolved"}
            $report.imports += @{source=$source.path;resolved=$resolved}
        }
    }
    if ($report.imports.Count -ne 2) {throw 'Unexpected import count'}
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    if ($report.disk_before.used_bytes + 1MB + 512KB -gt $report.disk_before.max_bytes) {throw 'Capacity reserve'}
    if ($Execute) {
        $version=Child $compiler @('--version');Success $version
        if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)') {throw 'Compiler version mismatch'}
        $report.compiler_version=$version.stdout
        $null=New-Item -ItemType Directory -Path $work;$created=$true
        $exe=Join-Path $work 'opportunity-o2-yes.exe'
        $build=Child $compiler @((Join-Path $PSScriptRoot 'opportunity.rs'),'--edition=2024','--cfg','model_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
        Success $build
        if ((Get-Item -LiteralPath $exe).Length -gt 1MB) {throw 'Executable reserve exceeded'}
        $exeBefore=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
        $audit=Child $exe @((Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'));Success $audit
        $result=$audit.stdout | ConvertFrom-Json
        if ($result.status -ne 'passed' -or !$result.diagnostic_only -or $result.wire_size_speed_verified -or $result.full_benchmark_allowed) {throw 'Diagnostic scope mismatch'}
        foreach ($name in @('runs','rank_tokens','length_tokens','rank_oracle_checked')) {if ($result.$name -ne 889227) {throw "Count mismatch: $name"}}
        if ($result.primary -ne 1762795 -or $result.escape_bytes -ne 742 -or $result.escape_bits -ne 5936 -or $result.alphabet -ne 257 -or $result.tree_cases -ne 66049 -or $result.grammar_digests[0] -ne $result.grammar_digests[1]) {throw 'Grammar/tree mismatch'}
        if ($result.tree_nodes[0] -ne 142 -or $result.tree_nodes[1] -ne 142 -or $result.tree_max_depth -ne 7 -or $result.max_depth[0] -gt 7 -or $result.max_depth[1] -gt 7) {throw 'Static topology mismatch'}
        if ($result.old_intervals_checked -ne 1778454 -or $result.branches_oracle_checked -ne ($result.branches[0]+$result.branches[1])) {throw 'Oracle count mismatch'}
        $proof=Get-Content -LiteralPath (Join-Path $project 'build/khc-direct-token-full-20261002-bwt-pin-fix/report.json') -Raw | ConvertFrom-Json
        $frame=$proof.frames[6]
        if ($proof.status -ne 'passed' -or $frame.name -ne 'all_group' -or $frame.stats.runs -ne $result.runs -or $frame.stats.primary -ne $result.primary -or $frame.stats.escape_bytes -ne $result.escape_bytes) {throw 'Full proof mismatch'}
        $loss=Get-Content -LiteralPath (Join-Path $project 'build/khc-direct-token-loss-20261002/report.json') -Raw | ConvertFrom-Json
        if ($loss.status -ne 'passed') {throw 'Loss proof mismatch'}
        $oldAudit=$loss.conditions[0].audit
        $report.old_component_comparison=@()
        for ($c=0;$c -lt 2;$c++) {
            $component=if ($c -eq 0) {'rank'} else {'length'}
            $oldBits=($oldAudit.cells | Where-Object {$_.component -eq $component} | Measure-Object old_bits -Sum).Sum
            if ([Math]::Abs($oldBits-$result.old_bits[$c]) -gt 0.0001) {throw 'Old component bits mismatch'}
            $branchSum=($result.prefix_counts[$c] | Measure-Object -Sum).Sum
            if ($branchSum -ne $result.branches[$c]) {throw 'Prefix count mismatch'}
            $report.old_component_comparison += @{component=$component;old_bits=$oldBits;mixed_bits=$result.bits[$c][0];difference_bits=$result.bits[$c][0]-$oldBits}
        }
        if ($result.gradients_checked -ne 4*$result.branches_oracle_checked -or $result.synthetic_predictions -ne 10 -or $result.finite_differences -ne 40) {throw 'Gradient validation count mismatch'}
        if ($result.numeric_tolerance -ne 2e-10 -or $result.finite_difference_step -ne 1e-5 -or $result.finite_difference_tolerance -ne 2e-6) {throw 'Fixed numeric tolerance mismatch'}
        $previous=Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-context-opportunity-20261002/report.json') -Raw | ConvertFrom-Json
        if ($previous.status -ne 'passed' -or ($previous.bits_order -join ',') -ne 'mixed,global,symbol,recent,joint') {throw 'Previous arithmetic proof mismatch'}
        $prior=$previous.audit
        $report.arithmetic_component_comparison=@();$report.expert_crosscheck=@()
        for ($c=0;$c -lt 2;$c++) {
            if ($result.grammar_digests[$c] -ne $prior.grammar_digests[$c] -or $result.branches[$c] -ne $prior.branches[$c] -or $result.max_depth[$c] -ne $prior.max_depth[$c] -or [Math]::Abs($result.old_bits[$c]-$prior.old_bits[$c]) -gt 1e-4) {throw 'Inherited grammar/count/oldflat mismatch'}
            for ($k=0;$k -lt 4;$k++) {if ($result.prefix_counts[$c][$k] -ne $prior.prefix_counts[$c][$k]) {throw 'Inherited prefix mismatch'}}
            $report.arithmetic_component_comparison+=@{component=$c;arithmetic_bits=$prior.bits[$c][0];logpool_bits=$result.bits[$c][0];difference_bits=$result.bits[$c][0]-$prior.bits[$c][0]}
            for ($i=1;$i -lt 5;$i++) {
                if ([Math]::Abs($result.bits[$c][$i]-$prior.bits[$c][$i]) -gt 1e-4) {throw 'Inherited expert bits mismatch'}
                $report.expert_crosscheck+=@{component=$c;expert=$report.bits_order[$i];previous_bits=$prior.bits[$c][$i];current_bits=$result.bits[$c][$i]}
            }
        }
        for ($i=0;$i -lt 4;$i++) {
            if ($result.rescales[$i] -ne $prior.rescales[$i] -or $result.cold_expert_branches[$i] -ne $prior.cold_expert_branches[$i]) {throw 'Inherited count/rescale mismatch'}
        }
        $report.arithmetic_mixture_difference_bits=$result.mixed_bits-$prior.mixed_bits
        $projected=$result.mixed_bits+$result.escape_bits;$budget=(483599-281-5)*8
        if ([Math]::Abs($projected-$result.projected_entropy_escape_bits) -gt 0.0001 -or $result.payload_budget_bits -ne $budget -or $result.opportunity_gate -ne ($projected -lt $budget)) {throw 'Opportunity gate mismatch'}
        $report.audit=$result;$report.executable=Identity $exe
        if ($report.executable.sha256 -ne $exeBefore.sha256) {throw 'Executable changed'}
        if (@(Get-ChildItem -LiteralPath $work -Force | Where-Object {$_.FullName -ne $exe}).Count) {throw 'Unexpected artifact'}
        $report.status='passed'
    }
    $report.sources_after=@($sources | ForEach-Object {
        $now=Identity $_.path
        if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes) {throw 'Source identity changed'}
        $now
    })
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
    try {
        if ($created) {
            $report.ended_utc=[DateTime]::UtcNow.ToString('o')
            $report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
            $json=$report | ConvertTo-Json -Depth 12
            if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 512KB) {throw 'Report cap'}
            [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
            $null=& $guard -WorkDirectory $work -MaxRunMiB 8
        }
    } finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;audit=$report.audit;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8)} | ConvertTo-Json -Depth 6}
else {[pscustomobject]@{status=$report.status;sources=$sources;imports=$report.imports;capacity=$report.disk_before;compiler=$report.compiler;runtime=$report.runtime} | ConvertTo-Json -Depth 5}

