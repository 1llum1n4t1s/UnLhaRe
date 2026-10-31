#requires -Version 7.2
# 実装前失敗計画: ../CPU_OBSERVER_DIAGNOSTIC_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-cpu-observer-diagnostic-20261002'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$samples=[Collections.Generic.List[object]]::new()
$failure=$null
$logical=0
$began=[DateTime]::UtcNow.ToString('o')
function Hold([string]$Path,[string]$Role,[string]$Expected='') {
    $full=[IO.Path]::GetFullPath($Path)
    $ancestor=$full
    while($ancestor) {
        if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "reparse: $ancestor"}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $locks.Add([IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $item=Get-Item -LiteralPath $full
    $sha=(Get-FileHash -LiteralPath $full).Hash
    if($Expected -and $sha -cne $Expected){throw "pin mismatch: $Role"}
    $ids.Add([pscustomobject]@{path=$full;role=$Role;bytes=$item.Length;before_sha256=$sha;after_sha256=$null})
}

function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}

function Snapshot {
    $map=@{}
    $skipped=[Collections.Generic.List[object]]::new()
    $count=0
    $start=[DateTime]::UtcNow.ToString('o')
    foreach($p in [Diagnostics.Process]::GetProcesses()){
        try {
            if($p.Id -eq 0){continue}
            $name=$p.ProcessName
            $creation=$p.StartTime.ToUniversalTime().Ticks
            $cpu=$p.TotalProcessorTime.TotalMilliseconds
            $map[$p.Id]=[pscustomobject]@{pid=$p.Id;name=$name;start_ticks=$creation;cpu_ms=$cpu;stamp=[Diagnostics.Stopwatch]::GetTimestamp()}
        } catch {
            $count++
            if($skipped.Count -lt 16){$skipped.Add([pscustomobject]@{pid=$p.Id;error=$_.Exception.GetType().Name})}
        } finally {$p.Dispose()}
    }
    return [pscustomobject]@{processes=$map;skipped_count=$count;skipped_first=$skipped;began_utc=$start;ended_utc=[DateTime]::UtcNow.ToString('o')}
}
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 1
if(Test-Path -LiteralPath $work){throw 'fresh diagnostic root required'}
$null=New-Item -ItemType Directory -Path $work
try {
    if(![OperatingSystem]::IsWindows()){throw 'Windows-only diagnostic'}
    Hold (Join-Path $PSScriptRoot '../CPU_OBSERVER_DIAGNOSTIC_CONTRACT_20261002.md') 'preimplementation-contract' '389920041B68DE18636B5C62851172796426A7A3689B9916593510C8A33B384D'
    Hold (Join-Path $PSScriptRoot '../causal-bayes-float-cts/quiet-host.ps1') 'frozen-observer' 'E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'
    Hold $PSCommandPath 'diagnostic-script'
    $logical=[int]((Get-CimInstance Win32_Processor|Measure-Object NumberOfLogicalProcessors -Sum).Sum)
    if($logical -lt 1 -or $logical -gt 64){throw 'requires 1..64 logical CPUs for system-wide native scope'}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpuTimeDiagnostic {
    [StructLayout(LayoutKind.Sequential)]
    public struct FT {
        public uint Low, High;
        public ulong Value { get { return ((ulong)High << 32) | Low; } }
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out FT idle, out FT kernel, out FT user);
    public static ulong[] Read() {
        FT idle, kernel, user;
        if(!GetSystemTimes(out idle, out kernel, out user))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return new ulong[] {idle.Value, kernel.Value, user.Value};
    }
}
'@
    foreach($mode in @('without-cim','with-cim','without-cim','with-cim')){
        $before=Snapshot
        $nativeBefore=[CpuTimeDiagnostic]::Read()
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $cim=$null
        if($mode -ceq 'with-cim'){
            $queryStart=[DateTime]::UtcNow.ToString('o')
            $queryWatch=[Diagnostics.Stopwatch]::StartNew()
            $values=@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
            $queryWatch.Stop()
            if($values.Count -ne 1){throw 'ambiguous WMI _Total'}
            $cpu=[double]$values[0].PercentProcessorTime
            if(![double]::IsFinite($cpu) -or $cpu -lt 0 -or $cpu -gt 100){throw 'invalid WMI CPU'}
            $meta=[ordered]@{}
            foreach($field in @('Timestamp_PerfTime','Timestamp_Sys100NS','Frequency_PerfTime','Frequency_Sys100NS')){
                $property=$values[0].PSObject.Properties[$field]
                $meta[$field]=if($null -eq $property){$null}else{$property.Value}
            }
            $cim=[ordered]@{query_began_utc=$queryStart;query_ended_utc=[DateTime]::UtcNow.ToString('o');query_ms=$queryWatch.Elapsed.TotalMilliseconds;percent_processor_time=$cpu;metadata=$meta}
        }
        $remaining=2000-$watch.Elapsed.TotalMilliseconds
        if($remaining -gt 0){[Threading.Thread]::Sleep([int][Math]::Ceiling($remaining))}
        $nativeAfter=[CpuTimeDiagnostic]::Read()
        $watch.Stop()
        $after=Snapshot
        for($i=0;$i -lt 3;$i++){if($nativeAfter[$i] -lt $nativeBefore[$i]){throw 'native counters nonmonotonic'}}
        $idle=[double]($nativeAfter[0]-$nativeBefore[0])
        $kernel=[double]($nativeAfter[1]-$nativeBefore[1])
        $user=[double]($nativeAfter[2]-$nativeBefore[2])
        $total=$kernel+$user
        if($total -le 0 -or $idle -lt 0 -or $idle -gt $total){throw 'invalid system CPU interval'}
        $busy=100*($total-$idle)/$total
        $rows=[Collections.Generic.List[object]]::new()
        $matched=0;$negative=0
        foreach($id in $before.processes.Keys){
            if(!$after.processes.ContainsKey($id)){continue}
            $first=$before.processes[$id];$last=$after.processes[$id]
            if($first.start_ticks -ne $last.start_ticks -or $first.name -cne $last.name){continue}
            $elapsedMs=1000*($last.stamp-$first.stamp)/[Diagnostics.Stopwatch]::Frequency
            $cpuMs=$last.cpu_ms-$first.cpu_ms
            if($elapsedMs -le 0 -or $cpuMs -lt 0){$negative++;continue}
            $matched++
            $rows.Add([pscustomobject]@{pid=$id;name=$last.name;cpu_ms=$cpuMs;interval_ms=$elapsedMs;percent_all_logical_cpus=100*$cpuMs/($elapsedMs*$logical);is_diagnostic_self=($id -eq $PID)})
        }
        $top=@($rows|Sort-Object percent_all_logical_cpus -Descending|Select-Object -First 10)
        $sample=[ordered]@{mode=$mode;ended_utc=[DateTime]::UtcNow.ToString('o');native_interval_ms=$watch.Elapsed.TotalMilliseconds;native_before=$nativeBefore;native_after=$nativeAfter;idle_delta_ticks=$idle;kernel_delta_ticks=$kernel;user_delta_ticks=$user;native_busy_percent=$busy;cim=$cim;top_processes=$top;matched_processes=$matched;before_processes=$before.processes.Count;after_processes=$after.processes.Count;before_skipped=$before.skipped_count;after_skipped=$after.skipped_count;before_skipped_first=$before.skipped_first;after_skipped_first=$after.skipped_first;nonmonotonic_process_cpu=$negative}
        $samples.Add([pscustomobject]$sample)
        Write-Output ([pscustomobject]@{mode=$mode;native_busy_percent=$busy;cim_percent=$(if($cim){$cim.percent_processor_time}else{$null});top=$top|Select-Object -First 3}|ConvertTo-Json -Depth 4 -Compress)
    }
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'frozen diagnostic identity changed'}}
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 1
    $report=[ordered]@{status=$(if($failure){'failed'}else{'read_only_cpu_diagnostic_completed_not_a_performance_gate'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');runtime_path=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();diagnostic_pid=$PID;logical_cpus=$logical;budget_before=$budgetBefore;budget_after=$budgetAfter;identities=$ids;samples=$samples;formal_performance_restarted=$false;observer_or_threshold_changed=$false;external_process_changed=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 1
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;samples=$samples.Count}|ConvertTo-Json -Compress)
}
if($failure){exit 1}
