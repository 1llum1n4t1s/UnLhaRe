[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$compiledRoot = Join-Path $project 'build/khc-lookup-float-cts-20261004'
$work = Join-Path $compiledRoot 'native-validation'
$exe = Join-Path $compiledRoot 'lookup-float-o2-yes.exe'
$fixedInputPath = Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$originalRunner = Join-Path $PSScriptRoot 'verify.ps1'
$originalReport = Join-Path $compiledRoot 'report.json'
$guard = Join-Path $PSScriptRoot '../disk-budget.ps1'
$lookupSourceRoot = $PSScriptRoot
$created = $false
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$sources = [Collections.Generic.List[object]]::new()
$graph = [Collections.Generic.List[object]]::new()
$report = [ordered]@{
    status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@()
    reason='Original compilation passed; CLI resolved to Clear-Item alias before numeric launch. Reuse the compiled EXE; preserve the failed report.'
    adoption_scope='Private candidate retained only if size and both internal diagnostic directions pass. Not product or overall 7-Zip adoption.'
    compile_calls=0;disk_frames_created=$false;disk_restores_created=$false
}
# 失敗済みrunnerを実行せず、固定hashの関数ASTだけを再利用する。
# CLIはPowerShell標準aliasと衝突するため、AST中の定義名だけを一意名へ変更する。
if ((Get-FileHash -LiteralPath $originalRunner).Hash -cne '1E97EF3203470EF946D9AB575FE3D90FA9376B7B751D1D7858990CC721B4C4DA') {
    throw 'Frozen runner identity mismatch'
}
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($originalRunner,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Frozen runner syntax' }
$names=@('Identity','Safe-Path','Source','Save-Report','Child','CLI')
$report.function_bindings=@()
foreach ($name in $names) {
    $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
    if ($definitions.Count -ne 1) { throw "Function binding: $name" }
    $originalText=$definitions[0].Extent.Text
    $effectiveText=if ($name -ceq 'CLI') {$originalText.Replace('function CLI(','function Invoke-LookupNative(')} else {$originalText}
    if ($name -ceq 'CLI' -and $effectiveText -ceq $originalText) { throw 'CLI definition rename missing' }
    # CreateしたScriptBlockはPSScriptRootを持たない。源泉rootの明示変数へ束縛する。
    if ($name -ceq 'Source') {$effectiveText=$effectiveText.Replace('$PSScriptRoot','$lookupSourceRoot')}
    . ([ScriptBlock]::Create($effectiveText))
    $report.function_bindings+=@{original_name=$name;effective_name=$(if ($name -ceq 'CLI') {'Invoke-LookupNative'} else {$name});definition_only_rename=($name -ceq 'CLI');source_root_binding=($name -ceq 'Source')}
}
function Pin-LookupFile([string]$Path) {
    $null=Safe-Path $Path
    $locks.Add([IO.File]::Open($Path,'Open','Read','Read'))
    Identity $Path
}
function Assert-LookupIdentity($Expected,$Actual) {
    $beforeTicks=[DateTimeOffset]::Parse($Expected.mtime_utc).UtcTicks
    $afterTicks=[DateTimeOffset]::Parse($Actual.mtime_utc).UtcTicks
    if ($Expected.path -cne $Actual.path -or $Expected.sha256 -cne $Actual.sha256 -or $Expected.bytes -ne $Actual.bytes -or $beforeTicks -ne $afterTicks) {
        throw "Identity mismatch: $($Expected.path)"
    }
}
try {
    $null=Safe-Path $work
    if (Test-Path -LiteralPath $work) { throw 'Native validation root exists' }
    $report.runner=Pin-LookupFile $PSCommandPath
    $report.original_runner=Pin-LookupFile $originalRunner
    $report.compilation_report=Pin-LookupFile $originalReport
    $failed=Get-Content -Raw -LiteralPath $originalReport | ConvertFrom-Json -DateKind String
    if ($failed.status -cne 'failed' -or $failed.children.Count -ne 2 -or @($failed.children | Where-Object exit_code -ne 0).Count) {
        throw 'Expected frozen successful compilation and pre-native harness failure'
    }
    $report.executable=Pin-LookupFile $exe
    Assert-LookupIdentity $failed.executable_before $report.executable
    if ($report.executable.bytes -gt 1048576) { throw 'Executable budget' }
    Source (Join-Path $PSScriptRoot 'probe.rs')
    if ($sources.Count -ne 19 -or $graph.Count -ne 18 -or $failed.sources_before.Count -ne 19) { throw 'Source closure shape' }
    foreach ($source in $sources) {
        $previous=@($failed.sources_before | Where-Object path -CEQ $source.path)
        if ($previous.Count -ne 1) { throw 'Missing compiled source identity' }
        Assert-LookupIdentity $previous[0] $source
    }
    $report.sources_before=@($sources);$report.imports=@($graph)
    $report.input=Pin-LookupFile $fixedInputPath
    Assert-LookupIdentity $failed.input_before $report.input
    $report.guard=Pin-LookupFile $guard
    Assert-LookupIdentity $failed.guard_before $report.guard
    $report.plan=Pin-LookupFile (Join-Path $PSScriptRoot '../LOOKUP_FLOAT_CTS_PLAN_20261004.md')
    Assert-LookupIdentity $failed.plan $report.plan
    $report.failure_plan=Pin-LookupFile (Join-Path $PSScriptRoot 'FAILURE_PLAN.md')
    Assert-LookupIdentity $failed.failure_plan $report.failure_plan
    $report.disk_before=& $guard -WorkDirectory $compiledRoot -MaxRunMiB 8
    $null=New-Item -ItemType Directory -Path $work
    $created=$true;$report.status='running';Save-Report
    $report.numeric=Invoke-LookupNative 'numeric';Save-Report
    $report.selfcheck=Invoke-LookupNative 'selfcheck';Save-Report
    $report.screen=Invoke-LookupNative 'screen';Save-Report
    if ($report.screen.size_gate_passed) {
        $report.ABBA=Invoke-LookupNative 'abba'
        $report.status='diagnostic-passed';$report.adopted=$report.ABBA.both_directions_shorter
    } else {
        $report.status='size-rejected';$report.adopted=$false;$report.ABBA_skipped='Size gate failed; no parameter sweep.'
    }
} catch {
    $report.status='failed';$report.error=$_.Exception.Message
    throw
} finally {
    try {
        $report.sources_after=@($sources | ForEach-Object {$now=Identity $_.path;Assert-LookupIdentity $_ $now;$now})
        foreach ($key in @('runner','original_runner','compilation_report','executable','input','guard','plan','failure_plan')) {
            if ($report[$key]) {$now=Identity $report[$key].path;Assert-LookupIdentity $report[$key] $now;$report[$key+'_after']=$now}
        }
        $report.disk_after=& $guard -WorkDirectory $compiledRoot -MaxRunMiB 8
        $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
    } finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));adopted=$report.adopted;capacity=$report.disk_after} | ConvertTo-Json -Depth 5
