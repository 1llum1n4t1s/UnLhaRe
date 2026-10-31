[CmdletBinding()]
param([switch]$Verify)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$basisRoot=Join-Path $project 'build/khc-quaternary-cts-q32-primitive-20261002'
$work=Join-Path $project 'build/khc-quaternary-cts-q32-primitive-20261002-proof-closure'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$pins=@(
    @((Join-Path $basisRoot 'report.json'),'C9DA0D03345C1D1913910F3A65FC17BCA128EAE75CE1569C51E8F3E009DC2AEA'),
    @((Join-Path $basisRoot 'primitive-o2-yes.exe'),'51315E1F6C8110AF9D5D2BB2C79A55981B5EC1A5992FB0166E77EC71CCDD3652'),
    @((Join-Path $PSScriptRoot '../QUATERNARY_CTS_Q32_PROOF_CLOSURE_20261002.md'),'5B9A66B06BA8120C47392D130DACA8E2F89F620249DFC7F7FD89C6372135DE91'),
    @($runtime,'362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139')
)
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$identities=[Collections.Generic.List[object]]::new()
function Identity([string]$Path) {
    [pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash;bytes=(Get-Item -LiteralPath $Path).Length}
}
function Hold([string]$Path,[string]$Hash) {
    $full=[IO.Path]::GetFullPath($Path)
    if (!@($identities|Where-Object {$_.path -eq $full}).Count) {
        $locks.Add([IO.File]::Open($full,'Open','Read','Read'))
        $id=Identity $full
        if ($Hash -and $id.sha256 -ne $Hash) {throw "Pin mismatch: $full"}
        $identities.Add($id)
    } elseif ($Hash -and @($identities|Where-Object {$_.path -eq $full})[0].sha256 -ne $Hash) {throw 'Conflicting pin'}
}
function Require([bool]$Condition,[string]$Message) {if (!$Condition) {throw $Message}}
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');original_wrapper_passed=$false;candidate_reexecuted=$false;recorded_executable_before_identity_available=$false;full_benchmark_allowed=$false;identities=$identities;unverified=@('recorded original executable pre/post identity','integer five-feature pool and whole-input gate','CDF/range/frame','formal speed and CPU','holdout/categories','four native','product/API')}
$created=$false
try {
    Require (!(Test-Path -LiteralPath $work)) 'Fresh closure root exists; no overwrite or retry'
    Require ([IO.Path]::GetFullPath($runtime) -eq [IO.Path]::GetFullPath($expectedRuntime)) 'Runtime path mismatch'
    Require ($PSVersionTable.PSVersion.ToString() -eq '7.6.5') 'Runtime version mismatch'
    foreach ($pin in $pins) {Hold $pin[0] $pin[1]}
    Hold $PSCommandPath ''
    $basis=Get-Content -LiteralPath (Join-Path $basisRoot 'report.json') -Raw | ConvertFrom-Json
    Require ($basis.status -eq 'failed' -and $basis.error -eq "Method invocation failed because [System.Object[]] does not contain a method named 'op_Division'.") 'Unexpected original failure'
    Require ($basis.sources.Count -eq 13 -and $basis.sources_after.Count -eq 13) 'Source shape mismatch'
    Require (@($basis.sources.path|Sort-Object -Unique).Count -eq 13) 'Duplicate basis identity'
    foreach ($id in $basis.sources) {
        Hold $id.path $id.sha256
        Require ((Get-Item -LiteralPath $id.path).Length -eq $id.bytes) 'Source size mismatch'
        $after=@($basis.sources_after|Where-Object {$_.path -eq $id.path})
        Require ($after.Count -eq 1 -and $after[0].sha256 -eq $id.sha256 -and $after[0].bytes -eq $id.bytes) 'Original before/after mismatch'
    }
    $auditSource=Join-Path $PSScriptRoot 'primitive_audit.rs'
    $modelSource=Join-Path $PSScriptRoot 'integer_cts.rs'
    Require ($basis.imports.Count -eq 1 -and $basis.imports[0].source -eq $auditSource -and $basis.imports[0].resolved -eq $modelSource) 'Original import mismatch'
    Require ($basis.runtime_version -eq '7.6.5' -and $basis.compiler_version -eq 'rustc 1.98.1 (48a229cea 2026-09-01)' -and !$basis.full_benchmark_allowed) 'Original scope/environment mismatch'
    Require ($basis.records.Count -eq 3) 'Original child count mismatch'
    foreach ($record in $basis.records) {Require ($record.exit -eq 0 -and $record.stderr -eq '' -and $record.cwd -eq $project) 'Original child failure/cwd mismatch'}
    $compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
    Require ($basis.records[0].file -eq $compiler -and ($basis.records[0].argv -join ',') -eq '--version' -and $basis.records[0].stdout -eq $basis.compiler_version) 'Version record mismatch'
    $exe=Join-Path $basisRoot 'primitive-o2-yes.exe'
    $expectedArgs=@($auditSource,'--edition=2024','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe)
    Require ($basis.records[1].file -eq $compiler -and ($basis.records[1].argv -join "`n") -ceq ($expectedArgs -join "`n") -and $basis.records[1].stdout -eq '') 'Compile argv mismatch'
    Require ($basis.records[2].file -eq $exe -and @($basis.records[2].argv).Count -eq 0) 'Diagnostic record mismatch'
    $result=$basis.records[2].stdout | ConvertFrom-Json
    Require ($result.status -eq 'passed' -and $result.diagnostic_only -and $result.integer_primitive_only -and !$result.wire_size_speed_verified -and !$result.integer_pool_verified -and !$result.opportunity_gate_evaluated -and !$result.full_benchmark_allowed -and !$result.f64_continuous_trajectory_verified -and $result.rejection_state_direct_comparison) 'Saved diagnostic scope mismatch'
    Require (!('opportunity_gate' -in $result.PSObject.Properties.Name)) 'Primitive cannot claim gate'
    $expected=@{Q=4294967296;classes=6;levels=9;nodes_per_class=87381;observation_cap=3825340;path_cases=65536;path_levels_checked=589824;maximum_heap_index=87380;kt_cases=5184;kt_cap_cases=8;bigint_fixtures=2;mixture_predictions=60;mixture_updates=450;small_depth_predictions=84;small_depth_updates=210;scalar_rejections=18;state_rejections=22;series_branches=384;series_node_updates=3456;state_values_checked=2621442;kt_error_comparisons=25062;recursive_mix_error_comparisons=12102;q32_rawmass_update_error_comparisons=3882}
    foreach ($field in $expected.Keys) {Require ($result.$field -eq $expected[$field]) "Fixed count mismatch: $field"}
    Require ($result.class_observations.Count -eq 6 -and @($result.class_observations|Where-Object {$_ -ne 64}).Count -eq 0) 'Class count mismatch'
    $scale=4294967296.0
    Require ($result.local_kt_bound -eq (2.0/$scale) -and $result.local_max_depth_mix_bound -eq (18.0/$scale) -and $result.local_q32_rawmass_update_bound -eq (4.0/$scale) -and $result.legacy_f64_tolerance -eq 2e-10) 'Fixed bounds mismatch'
    # 名前付きscalar値を使い、配列全体へのdivisionを避ける。
    $bounds=@{max_local_kt_error=(2.0/$scale);max_local_recursive_mix_error=(18.0/$scale);max_local_q32_rawmass_posterior_error=(4.0/$scale);max_local_q32_rawmass_switch_error=(4.0/$scale)}
    foreach ($field in $bounds.Keys) {
        $value=[double]$result.$field
        Require ([double]::IsFinite($value) -and $value -ge 0 -and $value -le $bounds[$field]) "Local bound exceeded: $field"
    }
    Require ($result.local_error_scope -eq 'KT and recursive mix use same raw counts and Q32 weights; posterior and switch use already quantized KT and child mixed for one update only') 'Local error scope mismatch'
    $report.basis_report=Identity (Join-Path $basisRoot 'report.json');$report.current_executable=Identity $exe
    $report.original_sources_checked=13;$report.audit=$result;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
    Require ($report.disk_before.used_bytes+512KB -le $report.disk_before.max_bytes) 'Report reserve'
    if ($Verify) {
        $null=New-Item -ItemType Directory -Path $work;$created=$true
        $report.status='saved_output_verified'
    }
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
    try {
        $report.identities_after=@($identities|ForEach-Object {
            $now=Identity $_.path
            Require ($now.sha256 -eq $_.sha256 -and $now.bytes -eq $_.bytes) 'Closure identity changed'
            $now
        })
        if ($created) {
            $report.ended_utc=[DateTime]::UtcNow.ToString('o')
            $json=$report|ConvertTo-Json -Depth 12
            Require ([Text.Encoding]::UTF8.GetByteCount($json) -le 512KB) 'Closure report cap'
            [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json)
            $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8
        }
    } finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;identity_count=$identities.Count;original_sources_checked=$report.original_sources_checked;candidate_reexecuted=$false;original_wrapper_passed=$false;recorded_executable_before_identity_available=$false;audit=$report.audit;report=if($created){Identity (Join-Path $work 'report.json')}else{$null};capacity=if($created){$report.disk_after}else{$report.disk_before}}|ConvertTo-Json -Depth 5
