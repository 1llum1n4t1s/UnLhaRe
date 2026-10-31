[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-lookup-float-cts-20261004'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$created=$false;$exe=$null;$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new();$graph=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');sources_before=@();sources_after=@();imports=@();children=@();capacity_plan=@{source_bytes=307200;exe_bytes=1048576;report_bytes=262144;fresh_bytes=8388608;compile_seconds=60;CLI_seconds=120;stdout_bytes=65536;stderr_bytes=16384};disk_frames_created=$false;disk_restores_created=$false}
function Identity([string]$Path){$p=[IO.Path]::GetFullPath($Path);$i=Get-Item -LiteralPath $p -Force;if ($i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Identity file/link: $p"};[pscustomobject]@{path=$p;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=$i.Length;mtime_utc=$i.LastWriteTimeUtc.ToString('o')}}
function Safe-Path([string]$Path){$p=[IO.Path]::GetFullPath($Path);$ancestor=$p;while ($ancestor){if (Test-Path -LiteralPath $ancestor){if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse ancestor: $ancestor"}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)};$p}
function Source([string]$Path){
 $p=Safe-Path $Path;if (@($sources | Where-Object path -eq $p).Count){return}
 if (!$p.StartsWith([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw "Source outside khc: $p"}
 $entry=Identity $p;$sources.Add($entry);$locks.Add([IO.File]::Open($p,'Open','Read','Read'));$content=[IO.File]::ReadAllText($p)
 if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b'){throw 'Unsupported source dependency'}
 $matches=[regex]::Matches($content,'(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
 if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{'){throw 'Unsupported module graph'}
 foreach ($m in $matches){$relative=if ($m.Groups[1].Success){$m.Groups[1].Value}else{$m.Groups[2].Value+'.rs'};$resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($p)) $relative));$graph.Add(@{source=$p;resolved=$resolved});Source $resolved}
}
function Save-Report{if (!$created){return};$json=$report | ConvertTo-Json -Depth 16;if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 262144){throw 'Report capacity'};[IO.File]::WriteAllText((Join-Path $work 'report.json'),$json,[Text.UTF8Encoding]::new($false))}
function Child([string]$File,[string[]]$Arguments,[int]$Seconds,[bool]$RecordChild=$true){
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$File;$info.WorkingDirectory=$project;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach ($argument in $Arguments){$info.ArgumentList.Add($argument)}
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$watch=[Diagnostics.Stopwatch]::StartNew();$out=[Text.StringBuilder]::new();$err=[Text.StringBuilder]::new();$failure=$null
 $ob=[char[]]::new(1024);$eb=[char[]]::new(1024);$ot=$null;$et=$null;$od=$false;$ed=$false
 try {
  if (!$p.Start()){throw 'Child start'};$ot=$p.StandardOutput.ReadAsync($ob,0,$ob.Length);$et=$p.StandardError.ReadAsync($eb,0,$eb.Length)
  while (!$p.HasExited -or !$od -or !$ed){
   if ($watch.Elapsed.TotalSeconds -gt $Seconds){$failure='Child timeout';break}
   if (!$od -and $ot.IsCompleted){$n=$ot.GetAwaiter().GetResult();if ($n -eq 0){$od=$true}else{$null=$out.Append($ob,0,$n);if ([Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt 65536){$failure='Child stdout bound';break};$ot=$p.StandardOutput.ReadAsync($ob,0,$ob.Length)}}
   if (!$ed -and $et.IsCompleted){$n=$et.GetAwaiter().GetResult();if ($n -eq 0){$ed=$true}else{$null=$err.Append($eb,0,$n);if ([Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 16384){$failure='Child stderr bound';break};$et=$p.StandardError.ReadAsync($eb,0,$eb.Length)}}
   Start-Sleep -Milliseconds 5
  }
  if ($failure -and !$p.HasExited){$p.Kill($true)};$p.WaitForExit();$watch.Stop()
  $record=[ordered]@{file=$File;arguments=$Arguments;exit_code=$p.ExitCode;elapsed_ms=$watch.Elapsed.TotalMilliseconds;stdout=$out.ToString().Trim();stderr=$err.ToString().Trim();failure=$failure}
  if ($RecordChild){$report.children+=@($record);Save-Report}
  if ($failure){throw $failure};if ($record.exit_code -ne 0){throw "Child exit $($record.exit_code): $($record.stderr)"};return $record
 }finally{if (!$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
function CLI([string]$Operation){$arguments=if ($Operation -in @('screen','abba')){@($Operation,$fixedInputPath)}else{@($Operation)};$child=Child $exe $arguments 120
 if ($child.stderr){throw 'Unexpected CLI stderr'};$parsed=$child.stdout | ConvertFrom-Json;if ($parsed.status -ne 'passed'){throw 'CLI status'};return $parsed}
try {
 $null=Safe-Path $work;if (Test-Path -LiteralPath $work){throw 'Existing output root rejected'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if ($parseErrors.Count){throw 'PowerShell syntax'}
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 if ($sources.Count -ne 19 -or $graph.Count -ne 18){throw 'Expected nineteen-source eighteen-edge closure'}
 $sourceBytes=[long](($sources | Measure-Object bytes -Sum).Sum);if ($sourceBytes -gt 307200){throw 'Source capacity'};$report.source_bytes=$sourceBytes;$report.source_count=$sources.Count
 $report.runner_before=Identity $PSCommandPath;$locks.Add([IO.File]::Open($PSCommandPath,'Open','Read','Read'))
 $report.failure_plan=Identity (Join-Path $PSScriptRoot 'FAILURE_PLAN.md');$report.plan=Identity (Join-Path $PSScriptRoot '../LOOKUP_FLOAT_CTS_PLAN_20261004.md');$locks.Add([IO.File]::Open($report.plan.path,'Open','Read','Read'))
 $locks.Add([IO.File]::Open($report.failure_plan.path,'Open','Read','Read'));$report.guard_before=Identity $guard;$locks.Add([IO.File]::Open($guard,'Open','Read','Read'))
 $report.compiler=Identity $compiler;if ($report.compiler.sha256 -ne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.formatter=Identity $formatter;$report.runtime=Identity (Get-Process -Id $PID).Path;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
 $report.input_before=Identity $fixedInputPath;if ($report.input_before.bytes -ne 2811006 -or $report.input_before.sha256 -ne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Input pin'};$locks.Add([IO.File]::Open($fixedInputPath,'Open','Read','Read'))
 $report.environment=@{cwd=(Get-Location).Path;source_cwd=$project;CPU=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);OS=([Runtime.InteropServices.RuntimeInformation]::OSDescription);process_architecture=([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString())}
 if ($report.environment.process_architecture -ne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 $report.formatter_checks=@();foreach ($entry in $sources | Where-Object {$_.path.StartsWith($PSScriptRoot,[StringComparison]::OrdinalIgnoreCase)}){$formatted=Child $formatter @('--edition','2024','--emit','stdout','--config','skip_children=true',$entry.path) 60 $false;$report.formatter_checks+=@{path=$entry.path;exit_code=$formatted.exit_code;stdout_bytes=[Text.Encoding]::UTF8.GetByteCount($formatted.stdout)}}
 if ($Execute){
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
  $version=Child $compiler @('--version') 60;if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
  $exe=Join-Path $work 'lookup-float-o2-yes.exe'
  $null=Child $compiler @((Join-Path $PSScriptRoot 'probe.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe) 60
  $report.executable_before=Identity $exe;if ($report.executable_before.bytes -gt 1048576){throw 'EXE capacity'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
  $report.numeric=CLI 'numeric';Save-Report;$report.selfcheck=CLI 'selfcheck';Save-Report;$report.screen=CLI 'screen';Save-Report
  $report.adoption_scope='private experimental screen only; no production or general adoption'
  if ($report.screen.size_gate_passed){$report.ABBA=CLI 'abba';$report.status='diagnostic-passed';$report.adopted=$report.ABBA.both_directions_shorter}else{$report.status='size-rejected';$report.adopted=$false;$report.ABBA_skipped='size gate failed; no sweep or retry'}
  $report.executable_after=Identity $exe;if (($report.executable_before | ConvertTo-Json -Compress) -ne ($report.executable_after | ConvertTo-Json -Compress)){throw 'EXE changed'}
  $files=@(Get-ChildItem -LiteralPath $work -Force);if ($files.Count -ne 2 -or @($files | Where-Object {$_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output ownership/shape'}
 }
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try{
  $report.sources_after=@($sources | ForEach-Object {$now=Identity $_.path;if (($now | ConvertTo-Json -Compress) -ne ($_ | ConvertTo-Json -Compress)){throw "Source changed: $($_.path)"};$now})
  if ($report.runner_before){$report.runner_after=Identity $PSCommandPath;if (($report.runner_before | ConvertTo-Json -Compress) -ne ($report.runner_after | ConvertTo-Json -Compress)){throw 'Runner changed'}}
  if ($report.input_before){$report.input_after=Identity $fixedInputPath;if (($report.input_before | ConvertTo-Json -Compress) -ne ($report.input_after | ConvertTo-Json -Compress)){throw 'Input changed'}}
  foreach ($key in @('failure_plan','plan','guard_before')){if ($report[$key]){$now=Identity $report[$key].path;if (($report[$key] | ConvertTo-Json -Compress) -ne ($now | ConvertTo-Json -Compress)){throw "Identity changed: $key"};$report[$key+'_after']=$now}}
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8;$report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
 }finally{foreach ($stream in $locks){$stream.Dispose()}}
}
if ($Execute){[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));adopted=$report.adopted;capacity=$report.disk_after} | ConvertTo-Json -Depth 5}else{$report | ConvertTo-Json -Depth 12}
