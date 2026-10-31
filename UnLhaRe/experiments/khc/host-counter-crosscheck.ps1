#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$work=Join-Path $root 'build/khc-host-counter-crosscheck-20261001'
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse rejected: $p"};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path;[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function New-Bytes([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()}}
function Raw-Cpu {
    $rows=@(Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'")
    if($rows.Count -ne 1){throw 'Raw CPU Total missing/ambiguous'}
    [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o');idle=[decimal]$rows[0].PercentProcessorTime;timestamp=[decimal]$rows[0].Timestamp_Sys100NS;frequency=[decimal]$rows[0].Frequency_Sys100NS}
}
function Formatted-Cpu {
    $rows=@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'")
    if($rows.Count -ne 1){throw 'Formatted CPU Total missing/ambiguous'}
    $value=[double]$rows[0].PercentProcessorTime
    if(-not [double]::IsFinite($value) -or $value -lt 0 -or $value -gt 100){throw 'Invalid formatted CPU'}
    [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o');percent=$value;timestamp=[decimal]$rows[0].Timestamp_Sys100NS}
}
No-Reparse $work;if(Test-Path -LiteralPath $work){throw 'New owned diagnostic work required; no retry'}
$null=New-Item -ItemType Directory -Path $work
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');performance_adoption_allowed=$false;rows=[Collections.Generic.List[object]]::new();identities=@();environment=$null;limitations=@('Intervals overlap but are not identical; formatted internal interval is unknown.','Process CPU excludes idle/system interrupt and exited/unobserved processes.','This later diagnostic cannot establish the cause of the earlier CPU41% or invalidate its failed benchmark.')}
$held=[Collections.Generic.List[IO.FileStream]]::new();$failure=$null
try{
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'HOST_COUNTER_CROSSCHECK_CONTRACT_20261001.md'))){No-Reparse $path;$held.Add([IO.File]::Open($path,'Open','Read','Read'));$report.identities+=Identity $path}
    $logical=[int](Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if(-not $IsWindows -or $logical -lt 1 -or $logical -gt 64){throw 'Windows and <=64 logical CPUs required'}
    $report.environment=@{os=[Runtime.InteropServices.RuntimeInformation]::OSDescription;architecture=[Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString();logical_processors=$logical;powershell=$PSVersionTable.PSVersion.ToString()}
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class KhcSystemCpu {
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint Low, High; public ulong Value { get { return ((ulong)High<<32)|Low; } } }
    [DllImport("kernel32.dll",SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)]
    static extern bool GetSystemTimes(out FT idle,out FT kernel,out FT user);
    public static ulong[] Read(){FT i,k,u;if(!GetSystemTimes(out i,out k,out u))throw new Win32Exception(Marshal.GetLastWin32Error());return new[]{i.Value,k.Value,u.Value};}
}
'@
    for($index=0;$index -lt 6;$index++){
        $processBefore=@{};Get-Process|ForEach-Object {if($null -ne $_.CPU){$processBefore[$_.Id]=[double]$_.CPU}}
        $nativeStartUtc=[DateTime]::UtcNow.ToString('o');$nativeBefore=[KhcSystemCpu]::Read();$clock=[Diagnostics.Stopwatch]::StartNew()
        $rawBefore=Raw-Cpu;$formattedBefore=Formatted-Cpu
        [Threading.Thread]::Sleep(1000)
        $formattedAfter=Formatted-Cpu;$rawAfter=Raw-Cpu
        $nativeAfter=[KhcSystemCpu]::Read();$nativeEndUtc=[DateTime]::UtcNow.ToString('o');$elapsed=$clock.Elapsed.TotalSeconds
        $nativeDelta=@();for($k=0;$k -lt 3;$k++){if($nativeAfter[$k] -lt $nativeBefore[$k]){throw 'Native counter decreased'};$nativeDelta+=[decimal]$nativeAfter[$k]-[decimal]$nativeBefore[$k]}
        $nativeTotal=$nativeDelta[1]+$nativeDelta[2]
        if($nativeTotal -le 0 -or $nativeDelta[0] -gt $nativeTotal -or $rawAfter.timestamp -le $rawBefore.timestamp -or $rawAfter.idle -lt $rawBefore.idle){throw 'Counter/timestamp invalid'}
        $nativePercent=[double](100*($nativeTotal-$nativeDelta[0])/$nativeTotal)
        $rawPercent=[double](100*(1-($rawAfter.idle-$rawBefore.idle)/($rawAfter.timestamp-$rawBefore.timestamp)))
        foreach($value in @($nativePercent,$rawPercent)){if(-not [double]::IsFinite($value) -or $value -lt 0 -or $value -gt 100){throw 'Raw/native CPU outside range'}}
        $top=@(Get-Process|ForEach-Object {if($null -ne $_.CPU -and $processBefore.ContainsKey($_.Id)){$delta=[double]$_.CPU-$processBefore[$_.Id];if($delta -gt 0){[pscustomobject]@{pid=$_.Id;name=$_.ProcessName;cpu_percent_of_machine=[math]::Round(100*$delta/$elapsed/$logical,3)}}}}|Sort-Object cpu_percent_of_machine -Descending|Select-Object -First 8)
        $row=[pscustomobject]@{index=$index;native_start_utc=$nativeStartUtc;native_end_utc=$nativeEndUtc;elapsed_seconds=$elapsed;native_before=$nativeBefore;native_after=$nativeAfter;native_percent=$nativePercent;raw_before=$rawBefore;raw_after=$rawAfter;raw_percent=$rawPercent;formatted_before=$formattedBefore;formatted_after=$formattedAfter;top_processes=$top}
        $report.rows.Add($row)
        [pscustomobject]@{index=$index;native_percent=[math]::Round($nativePercent,2);raw_percent=[math]::Round($rawPercent,2);formatted_before=$formattedBefore.percent;formatted_after=$formattedAfter.percent}|ConvertTo-Json -Compress
    }
    $report.status='diagnostic_collected_not_a_benchmark'
}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    foreach($id in $report.identities){$after=Identity $id.path;if($id.bytes -ne $after.bytes -or $id.sha256 -cne $after.sha256){$report.status='failed';$report.error='Source changed';if($null -eq $failure){$failure='Source changed'}}}
    foreach($lock in $held){$lock.Dispose()}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    New-Bytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 10)))
}
if($null -ne $failure){throw $failure}
