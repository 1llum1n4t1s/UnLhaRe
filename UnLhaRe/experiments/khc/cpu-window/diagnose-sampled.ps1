#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-cpu-sampled-window-20260930'
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$pins=[Collections.Generic.List[object]]::new()
$runs=[Collections.Generic.List[object]]::new()
$hostLoadObservations=[Collections.Generic.List[object]]::new()
$raw=[Collections.Generic.List[object]]::new()
$parentProcess=[Diagnostics.Process]::GetCurrentProcess()
$during=[ordered]@{start=$null;end=$null;delta=$null;parent_cpu_start_ms=$null;parent_cpu_end_ms=$null;parent_cpu_delta_ms=$null;child_cpu_ms=$null;parent_fraction_percent=$null;child_fraction_percent=$null;unattributed_percent=$null}
$report=[ordered]@{status='failed';error=$null;old_guard_refused=$false;performance_adoption=$false;actual_children=0;provenance=$pins;invocations=$runs;host_observations=$hostLoadObservations;raw_windows=$raw;during=$during;source_function='frozen Invoke-Recorded AST, unchanged';cpu=@();frame=$null;started_utc=[DateTime]::UtcNow.ToString('o');completed_utc=$null}
function NoReparse([string]$Path){$current=[IO.Path]::GetFullPath($Path);while($current){if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse refused.'};$current=[IO.Path]::GetDirectoryName($current)}}
function Pin([string]$Path,[string]$Hash=''){
    NoReparse $Path
    $locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $item=Get-Item -LiteralPath $Path -Force
    if($item -isnot [IO.FileInfo]){throw 'Regular file required.'}
    $id=[pscustomobject]@{path=$item.FullName;before_bytes=$item.Length;before_sha256=(Get-FileHash -LiteralPath $Path).Hash;after_bytes=$null;after_sha256=$null}
    $pins.Add($id)
    if($Hash -and $id.before_sha256 -cne $Hash){throw 'Pinned identity mismatch.'}
    $id
}
function Window([string]$Phase){
    $row=[ordered]@{phase=$Phase;start=[KhcCpuWindow.NativeTimes]::Capture($logical);end=$null;delta=$null}
    $raw.Add($row)
    [Threading.Thread]::Sleep(1000)
    $row.end=[KhcCpuWindow.NativeTimes]::Capture($logical)
    $row.delta=[KhcCpuWindow.NativeTimes]::Calculate($row.start,$row.end)
}
function Assert-QuietHost([string]$Phase,[int]$Samples=1){
    if($Phase.EndsWith('-before',[StringComparison]::Ordinal)){
        Assert-OldQuietHost $Phase $Samples
        Window 'before'
        $parentProcess.Refresh();$during.parent_cpu_start_ms=$parentProcess.TotalProcessorTime.TotalMilliseconds
        $during.start=[KhcCpuWindow.NativeTimes]::Capture($logical)
    }else{
        $during.end=[KhcCpuWindow.NativeTimes]::Capture($logical)
        $parentProcess.Refresh();$during.parent_cpu_end_ms=$parentProcess.TotalProcessorTime.TotalMilliseconds
        try{Assert-OldQuietHost $Phase $Samples}finally{Window 'after'}
    }
}
NoReparse $work
if(Test-Path -LiteralPath $work){throw 'Existing diagnostic root; no overwrite/retry.'}
$null=New-Item -ItemType Directory -Path $work
try{
    $null=Pin $PSCommandPath
    $null=Pin (Join-Path $PSScriptRoot '../CPU_SAMPLED_WINDOW_CONTRACT_20260930.md')
    $native=Pin (Join-Path $PSScriptRoot 'native-times.cs') '4838B4D1A1ACFF075D85968DA9FDE1D521253BC2FA6EFD8B78CF03915762AC73'
    $source=Pin (Join-Path $PSScriptRoot '../causal-bayes-sais/compare.ps1') 'C37651CF01DB86CBC1306E371494AE8210812CE16DE6A4421BFA965309AD751B'
    $observer=Pin (Join-Path $PSScriptRoot '../causal-bayes-float-cts/quiet-host.ps1') 'E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'
    $candidate=Pin (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/candidate.exe') '9AC5CA8F200611454F2AC7E482737518FA90842353F26B750F3A0420E07E7FBA'
    $group=Pin (Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group') '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    if($candidate.before_bytes -ne 209920 -or $group.before_bytes -ne 2811006){throw 'Fixed length mismatch.'}
    $null=Pin (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/full-e2e-retry1/report.json') '0AD5477093E2984B2D3B2024531EB8DA3FD69F0DCC0F79F41ECD986DE6274ABF'
    $errors=$null;$tokens=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($source.path,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Frozen source parse failure.'}
    foreach($name in @('Assert-NoReparse','Get-FileIdentity','Invoke-Recorded')){
        $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
        if($nodes.Count -ne 1){throw 'Unexpected frozen function count.'}
        . ([ScriptBlock]::Create($nodes[0].Extent.Text))
    }
    $old=[Management.Automation.Language.Parser]::ParseFile($observer.path,[ref]$tokens,[ref]$errors)
    $nodes=@($old.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-QuietHost'},$true))
    if($errors.Count -or $nodes.Count -ne 1){throw 'Unexpected frozen observer AST.'}
    $definition=$nodes[0].Extent.Text.Replace('function Assert-QuietHost(','function Assert-OldQuietHost(')
    if($definition -ceq $nodes[0].Extent.Text){throw 'Observer alias failed.'}
    . ([ScriptBlock]::Create($definition))
    $report.cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfLogicalProcessors)
    $logical=[int]($report.cpu|Measure-Object NumberOfLogicalProcessors -Sum).Sum
    if($logical -lt 1 -or $logical -gt 64){throw 'Logical CPU count out of bounds.'}
    Add-Type -TypeDefinition (Get-Content -LiteralPath $native.path -Raw) -Language CSharp
    $output=Join-Path $work 'sampled.bayes'
    try{$null=Invoke-Recorded $candidate.path @('encode',$group.path,$output) 'encode' 'sais-sampled-diagnostic' 0 0 $work $output}
    catch{
        if($hostLoadObservations.Count -gt 0 -and -not $hostLoadObservations[-1].passed -and $_.Exception.Message -ceq 'Host CPU busy; no ordinary performance adoption allowed.'){$report.old_guard_refused=$true;$report.error=$_.Exception.Message}
        else{throw}
    }
    $report.actual_children=@($runs|Where-Object {$null -ne $_.exit_code}).Count
    if($report.actual_children -eq 1){
        if($runs[0].exit_code -ne 0 -or $runs[0].timed_out){throw 'Actual child failed.'}
        $report.frame=Get-FileIdentity $output
        if($report.frame.bytes -ne 483468 -or $report.frame.sha256 -cne 'B4F17DEFF3B39FF26E5DBD38454B51FB1196FFEB1B5252E93E65D5E4B9A3824A'){throw 'Fixed frame mismatch.'}
        $during.delta=[KhcCpuWindow.NativeTimes]::Calculate($during.start,$during.end)
        $during.parent_cpu_delta_ms=$during.parent_cpu_end_ms-$during.parent_cpu_start_ms
        $during.child_cpu_ms=$runs[0].cpu_ms
        $totalMs=[double]::Parse($during.delta.Total100ns,[Globalization.CultureInfo]::InvariantCulture)/10000.0
        $during.parent_fraction_percent=100.0*$during.parent_cpu_delta_ms/$totalMs
        $during.child_fraction_percent=100.0*$during.child_cpu_ms/$totalMs
        $during.unattributed_percent=$during.delta.BusyPercent-$during.parent_fraction_percent-$during.child_fraction_percent
        if($raw.Count -ne 2 -or $raw[0].end.ApiEndTicks -gt $during.start.ApiStartTicks -or $raw[1].start.ApiStartTicks -lt $during.end.ApiEndTicks){throw 'Raw windows overlap measured interval.'}
    }
    $report.status='diagnostic_completed_no_performance_adoption'
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}
finally{
    foreach($id in $pins){
        $item=Get-Item -LiteralPath $id.path -Force
        $id.after_bytes=$item.Length;$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash
        if($id.after_bytes -ne $id.before_bytes -or $id.after_sha256 -cne $id.before_sha256){$report.status='failed';$report.error='Pinned source changed.'}
    }
    $report.completed_utc=[DateTime]::UtcNow.ToString('o')
    NoReparse $work
    $stream=[IO.File]::Open((Join-Path $work 'report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 24)));$stream.Flush($true)}finally{$stream.Dispose();foreach($held in $locks){$held.Dispose()};$parentProcess.Dispose()}
}
if($report.status -ceq 'failed'){throw $report.error}
Write-Host 'Sampled diagnostic completed; no performance adoption.'
