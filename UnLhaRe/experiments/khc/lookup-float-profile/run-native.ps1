[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$budgetRoot=Join-Path $project 'build/khc-lookup-float-profile-20261004'
$work=Join-Path $budgetRoot 'corrected-native'
$exe=Join-Path $work 'lookup-float-profile-o2-yes.exe'
$fixedInputPath=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$created=$false
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$sources=[Collections.Generic.List[object]]::new()
$graph=[Collections.Generic.List[object]]::new()
$pins=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='preflight';started_utc=[DateTime]::UtcNow.ToString('o');children=@();diagnostic_only=$true;compile_calls=0;disk_frame_plain_input_copies=0;raw_traces=0;source_copy_method='apply_patch minimal instrumentation only';frozen_entrypoints_executed=$false}
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
function Pin-ProfileFile([string]$Path){$null=Safe-Path $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'));$pins.Add((Identity $Path))}
function Same-ProfileIdentity($A,$B){($A|ConvertTo-Json -Compress) -ceq ($B|ConvertTo-Json -Compress)}
try {
 $null=Safe-Path $work;if(Test-Path -LiteralPath $work){throw 'Unused output root required'}
 $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'Runner syntax'}
 Source (Join-Path $PSScriptRoot 'probe.rs');$report.imports=@($graph);$report.sources_before=@($sources)
 $sourceBytes=[long](($sources|Measure-Object bytes -Sum).Sum);if($sourceBytes -gt 307200){throw 'Source closure 300KiB bound'};$report.source_bytes=$sourceBytes;$report.source_count=$sources.Count
 foreach($path in @($PSCommandPath,$guard,$compiler,(Get-Process -Id $PID).Path,$fixedInputPath,(Join-Path $PSScriptRoot '../LOOKUP_FLOAT_PROFILE_PLAN_20261004.md'),(Join-Path $PSScriptRoot '../LOOKUP_FLOAT_CTS_RESULT_20261004.md'),(Join-Path $PSScriptRoot '../lookup-float-cts/verify.ps1'),(Join-Path $PSScriptRoot '../lookup-float-cts/run-native.ps1'),(Join-Path $project 'build/khc-lookup-float-cts-20261004/lookup-float-o2-yes.exe'),(Join-Path $project 'build/khc-lookup-float-cts-20261004/report.json'),(Join-Path $project 'build/khc-lookup-float-cts-20261004/native-validation/report.json'))){Pin-ProfileFile $path}
 Pin-ProfileFile (Join-Path $budgetRoot 'report.json')
 $report.identities_before=@($pins);$inputIdentity=Identity $fixedInputPath
 if($inputIdentity.bytes -ne 2811006 -or $inputIdentity.sha256 -cne '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'){throw 'Frozen input pin'}
 $compilerIdentity=Identity $compiler;if($compilerIdentity.sha256 -cne 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'){throw 'Compiler pin'}
 $report.environment=@{cwd=(Get-Location).Path;child_cwd=$project;CPU=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);OS=[Runtime.InteropServices.RuntimeInformation]::OSDescription;process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();PowerShell=$PSVersionTable.PSVersion.ToString()}
 if($report.environment.process_architecture -ne 'X64' -or ![OperatingSystem]::IsWindows()){throw 'Windows x64 required'}
 $report.disk_before=& $guard -WorkDirectory $budgetRoot -MaxRunMiB 8
 $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';Save-Report
 $version=Child $compiler @('--version') 60;if($version.stdout -cne 'rustc 1.98.1 (48a229cea 2026-09-01)'){throw 'Compiler version'}
 $report.compile_calls=1
 $report.compile_settings=@('--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE')
 $null=Child $compiler (@((Join-Path $PSScriptRoot 'probe.rs'))+$report.compile_settings+@('-o',$exe)) 60
 $report.executable_before=Identity $exe;if($report.executable_before.bytes -gt 1048576){throw 'EXE 1MiB bound'};$locks.Add([IO.File]::Open($exe,'Open','Read','Read'))
 $native=Child $exe @('profile',$fixedInputPath) 120
 if($native.stderr){throw 'Unexpected native stderr'}
 $parsed=$native.stdout|ConvertFrom-Json -Depth 32;if($parsed.status -cne 'passed' -or $parsed.cases -ne 5){throw 'Native contract status'}
 $report.native=$parsed;$report.status='diagnostic-passed'
 $report.executable_after=Identity $exe;if(!(Same-ProfileIdentity $report.executable_before $report.executable_after)){throw 'EXE changed'}
 $entries=@(Get-ChildItem -LiteralPath $work -Force);if($entries.Count -ne 2 -or @($entries|Where-Object {$_.PSIsContainer -or $_.FullName -notin @($exe,(Join-Path $work 'report.json')) -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output ownership/shape'}
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
 try {
  $report.sources_after=@($sources|ForEach-Object {$now=Identity $_.path;if(!(Same-ProfileIdentity $_ $now)){throw "Source identity changed: $($_.path)"};$now})
  $report.identities_after=@($pins|ForEach-Object {$now=Identity $_.path;if(!(Same-ProfileIdentity $_ $now)){throw "Tool/input/frozen identity changed: $($_.path)"};$now})
  $report.disk_after=& $guard -WorkDirectory $budgetRoot -MaxRunMiB 8
  $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  $finalGuard=& $guard -WorkDirectory $budgetRoot -MaxRunMiB 8
 }finally{foreach($stream in $locks){$stream.Dispose()}}
}
[pscustomobject]@{status=$report.status;report=Identity (Join-Path $work 'report.json');final_guard_after_report_save=$finalGuard;source_count=$report.source_count;source_bytes=$report.source_bytes;compile_calls=$report.compile_calls}|ConvertTo-Json -Depth 6

