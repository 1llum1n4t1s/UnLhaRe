#Requires -Version 7.0
# 読み取り専用：同じ採取区間のnative累積時間とWMIを照合する。閾値変更はしない。
$ErrorActionPreference='Stop'
if(-not [OperatingSystem]::IsWindows()){throw 'Windows CPU snapshot only'}
if([Environment]::ProcessorCount -gt 64){throw 'processor-group comparison needs separate handling'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KhcCpuSnapshotNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
}
'@
$prSamples=[Collections.Generic.List[object]]::new()
for($prSample=0;$prSample -lt 3;$prSample++){
    [ulong]$prIdleBefore=0;[ulong]$prKernelBefore=0;[ulong]$prUserBefore=0
    if(-not [KhcCpuSnapshotNative]::GetSystemTimes([ref]$prIdleBefore,[ref]$prKernelBefore,[ref]$prUserBefore)){throw 'GetSystemTimes before failed'}
    $prTimer=[Diagnostics.Stopwatch]::StartNew()
    $prWmi=Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
    $prWmiMs=$prTimer.Elapsed.TotalMilliseconds
    Start-Sleep -Milliseconds 1000
    [ulong]$prIdleAfter=0;[ulong]$prKernelAfter=0;[ulong]$prUserAfter=0
    if(-not [KhcCpuSnapshotNative]::GetSystemTimes([ref]$prIdleAfter,[ref]$prKernelAfter,[ref]$prUserAfter)){throw 'GetSystemTimes after failed'}
    if($prIdleAfter -lt $prIdleBefore -or $prKernelAfter -lt $prKernelBefore -or $prUserAfter -lt $prUserBefore){throw 'nonmonotonic CPU counters'}
    $prIdleDelta=$prIdleAfter-$prIdleBefore
    $prTotalDelta=($prKernelAfter-$prKernelBefore)+($prUserAfter-$prUserBefore)
    if($prTotalDelta -le 0 -or $prIdleDelta -gt $prTotalDelta){throw 'invalid CPU interval'}
    $prSamples.Add(@{native_cpu_percent=100.0*($prTotalDelta-$prIdleDelta)/$prTotalDelta;wmi_percent=$prWmi.PercentProcessorTime;wmi_query_ms=$prWmiMs;interval_ms=$prTimer.Elapsed.TotalMilliseconds;wmi_timestamp=$prWmi.Timestamp_Sys100NS})
}
[ordered]@{logical_processors=[Environment]::ProcessorCount;read_only=$true;threshold_changed=$false;samples=$prSamples}|ConvertTo-Json -Depth 4
