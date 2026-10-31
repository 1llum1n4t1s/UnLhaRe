#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$CaptureReportPath,
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$PdbPath,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$TraceEventDllPath = 'C:/Users/IMT/.nuget/packages/microsoft.diagnostics.tracing.traceevent/3.2.6/lib/netstandard2.0/Microsoft.Diagnostics.Tracing.TraceEvent.dll',
    [string]$SymbolizerPath = 'C:/Program Files/Microsoft Visual Studio/18/Community/VC/Tools/MSVC/14.51.36231/bin/Hostx64/x64/llvm-symbolizer.exe'
)
# 生ETLのみを読む。旧ETLX・DIA・NGENPDB・外部symbol downloadは使わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$provenance = [Collections.Generic.List[object]]::new()
function Identity([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse point rejected.' }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    $item = Get-Item -LiteralPath $full -Force
    if ($item -isnot [IO.FileInfo]) { throw 'Expected regular file.' }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $full).Hash }
}
function Lock-File([string]$Path, [string]$Role) {
    $id = Identity $Path
    $locks.Add([IO.File]::Open($id.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
    $row = [pscustomobject]@{ role = $Role; path = $id.path; before_bytes = $id.bytes; before_sha256 = $id.sha256; after_bytes = $null; after_sha256 = $null }
    $provenance.Add($row)
    $row
}
function Check-Span([long]$Start, [long]$Length, [long]$Total) {
    if ($Start -lt 0 -or $Length -lt 0 -or $Start -gt $Total -or $Length -gt $Total - $Start) { throw 'PDB span outside file.' }
}
function Native-PdbIdentity([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 56 -or $item.Length -gt 67108864) { throw 'PDB inspection limit exceeded.' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([Text.Encoding]::ASCII.GetString($bytes, 0, 26) -cne "Microsoft C/C++ MSF 7.00`r`n") { throw 'Expected native MSF7 PDB.' }
    $bs = [BitConverter]::ToUInt32($bytes, 32)
    $pages = [BitConverter]::ToUInt32($bytes, 40)
    $dirSize = [BitConverter]::ToUInt32($bytes, 44)
    $blockMap = [BitConverter]::ToUInt32($bytes, 52)
    if ($bs -notin @(512, 1024, 2048, 4096) -or [long]$pages * $bs -ne $bytes.Length -or $dirSize -lt 12 -or $dirSize -gt $bytes.Length) { throw 'Invalid PDB superblock.' }
    $dir = [byte[]]::new($dirSize)
    $dirPages = [int][Math]::Ceiling($dirSize / [double]$bs)
    Check-Span ([long]$blockMap * $bs) ([long]$dirPages * 4) $bytes.Length
    for ($i = 0; $i -lt $dirPages; $i++) {
        $block = [BitConverter]::ToUInt32($bytes, [int]([long]$blockMap * $bs + $i * 4))
        $length = [int][Math]::Min($bs, $dirSize - [long]$i * $bs)
        Check-Span ([long]$block * $bs) $length $bytes.Length
        [Array]::Copy($bytes, [long]$block * $bs, $dir, [long]$i * $bs, $length)
    }
    $streams = [BitConverter]::ToUInt32($dir, 0)
    if ($streams -lt 2) { throw 'Missing PDB info stream.' }
    Check-Span 4 ([long]$streams * 4) $dir.Length
    $cursor = 4L + 4L * $streams
    $size0 = [BitConverter]::ToUInt32($dir, 4)
    if ($size0 -ne [uint32]::MaxValue) { $cursor += 4L * [long][Math]::Ceiling($size0 / [double]$bs) }
    $size1 = [BitConverter]::ToUInt32($dir, 8)
    if ($size1 -lt 28 -or $size1 -eq [uint32]::MaxValue) { throw 'Invalid PDB info stream.' }
    Check-Span $cursor 4 $dir.Length
    $firstPage = [BitConverter]::ToUInt32($dir, [int]$cursor)
    Check-Span ([long]$firstPage * $bs) 28 $bytes.Length
    $offset = [int]([long]$firstPage * $bs)
    $guidBytes = [byte[]]::new(16)
    [Array]::Copy($bytes, $offset + 12, $guidBytes, 0, 16)
    [pscustomobject]@{ guid = [guid]::new($guidBytes).ToString(); age = [BitConverter]::ToUInt32($bytes, $offset + 8) }
}
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)) { throw 'Fresh directory below build required.' }
$ancestor = [IO.Path]::GetDirectoryName($work)
while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse ancestor rejected.' }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$null = New-Item -ItemType Directory -Path $work
$report = [ordered]@{ status = 'failed'; error = $null; started_utc = [DateTime]::UtcNow.ToString('o'); provenance = $provenance; pdb_identity = $null; modules = @(); per_pid = @(); sample_total = 0; module_samples = 0; unresolved_module_samples = 0; events_lost = $null; exclusive_inline_leaf = @(); inclusive_inline_functions = @(); addresses = @(); symbolizer = $null; timing_used_for_performance_decision = $false; notes = @('CPU sampled IPs only, not wall-time phases.', 'Symbol[0] is exclusive inline leaf; inclusive chain counts overlap and must not be added.', 'All target process samples remain in denominator, including OS and unresolved samples.', 'Fresh matching binary/PDB only; no ETLX/DIA/NGENPDB or online symbol lookup.') }
$failure = $null
$report['stack_statistics'] = $null
$report['sample_stacks'] = @()
$report['runtime_function_inclusive'] = @()
$report['unresolved_runtime_module_frames'] = 0L
$report.notes += 'Runtime inclusive functions include physical callers and inline frames, deduplicated per CPU sample; never add overlapping functions.'
$report.notes += 'Each physical chain starts with a captured IP; subsequent return addresses use RVA minus one for call-site resolution.'
try {
    $captureId = Lock-File $CaptureReportPath 'capture-report'
    $binary = Lock-File $BinaryPath 'binary'
    $pdb = Lock-File $PdbPath 'pdb'
    $traceDll = Lock-File $TraceEventDllPath 'traceevent-assembly'
    $symbolizer = Lock-File $SymbolizerPath 'llvm-symbolizer'
    $null = Lock-File $PSCommandPath 'analyzer'
    $capture = Get-Content -LiteralPath $captureId.path -Raw | ConvertFrom-Json
    if ($capture.status -cne 'capture_verified' -or @($capture.encode_runs).Count -ne 3) { throw 'Unverified capture report.' }
    if (-not [IO.Path]::GetDirectoryName($binary.path).Equals([IO.Path]::GetDirectoryName($pdb.path), [StringComparison]::OrdinalIgnoreCase)) { throw 'Binary/PDB must be adjacent for native symbol resolution.' }
    foreach ($pair in @(@('current-release-binary', $binary), @('matching-release-pdb', $pdb))) {
        $recorded = @($capture.provenance | Where-Object role -ceq $pair[0])
        $actual = $pair[1]
        if ($recorded.Count -ne 1 -or -not $recorded[0].path.Equals($actual.path, [StringComparison]::OrdinalIgnoreCase) -or
            $recorded[0].before_sha256 -cne $actual.before_sha256 -or $recorded[0].after_sha256 -cne $actual.before_sha256) { throw 'Analyzed pair differs from captured pair.' }
    }
    foreach ($run in $capture.encode_runs) {
        if (-not $run.program.Equals($binary.path, [StringComparison]::OrdinalIgnoreCase) -or $run.exit_code -ne 0 -or
            $run.output.bytes -ne 483130 -or $run.output.sha256 -cne 'CF4F107BE32E35B603FCA9CE05AC8A5C5C3F4211A4BC0B68236A383F8029447D') { throw 'Target run identity mismatch.' }
    }
    $trace = Lock-File $capture.trace.path 'raw-etl'
    if ($trace.before_sha256 -cne $capture.trace.sha256 -or $trace.before_bytes -ne $capture.trace.bytes) { throw 'ETL identity mismatch.' }
    $pdbIdentity = Native-PdbIdentity $pdb.path
    $peStream = [IO.File]::OpenRead($binary.path)
    $pe = [System.Reflection.PortableExecutable.PEReader]::new($peStream)
    try {
        $cv = @($pe.ReadDebugDirectory() | Where-Object Type -eq CodeView | ForEach-Object { $pe.ReadCodeViewDebugDirectoryData($_) })
        $imageSize = [uint64]$pe.PEHeaders.PEHeader.SizeOfImage
        if ($cv.Count -ne 1 -or $cv[0].Guid.ToString() -cne $pdbIdentity.guid -or $cv[0].Age -ne $pdbIdentity.age -or [IO.Path]::GetFileName($cv[0].Path) -cne [IO.Path]::GetFileName($pdb.path)) { throw 'EXE/PDB identity mismatch.' }
        $report.pdb_identity = $pdbIdentity
    } finally { $pe.Dispose(); $peStream.Dispose() }
    Add-Type -Path $traceDll.path
    $targetIds = @($capture.encode_runs | ForEach-Object { [int]$_.pid })
    if (@($targetIds | Select-Object -Unique).Count -ne 3) { throw 'Duplicate target PIDs rejected.' }
    $modules = @{}; $counts = @{}; $moduleCounts = @{}; $rvas = @{}
    $samples = @{}; $stacks = @{}; $compressedRefs = [Collections.Generic.List[object]]::new()
    $lifetimes = @{}; $windows = @{}
    foreach ($run in $capture.encode_runs) {
        $lifetimes[[int]$run.pid] = [Collections.Generic.List[object]]::new()
        # ConvertFrom-JsonがDateTimeへ変換した値を文字列化すると小数秒を失うため直接castする。
        $windows[[int]$run.pid] = [pscustomobject]@{ start = ([DateTime]$run.start_utc).ToUniversalTime(); end = ([DateTime]$run.end_utc).ToUniversalTime() }
        if ($windows[[int]$run.pid].start -ge $windows[[int]$run.pid].end) { throw 'Invalid captured process window.' }
    }
    foreach ($targetId in $targetIds) { $counts[$targetId] = 0L; $moduleCounts[$targetId] = 0L }
    $source = [Microsoft.Diagnostics.Tracing.ETWTraceEventSource]::new($trace.path)
    $source.Kernel.add_ImageLoadGroup([Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.ImageLoadTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds -and [IO.Path]::GetFileName($ev.FileName) -ieq [IO.Path]::GetFileName($binary.path)) {
            $item = [pscustomobject]@{ pid = $ev.ProcessID; base = [uint64]$ev.ImageBase; size = [uint64]$ev.ImageSize; path = $ev.FileName; time_ms = $ev.TimeStampRelativeMSec }
            if ($item.size -ne $imageSize -or -not $item.path.Equals($binary.path, [StringComparison]::OrdinalIgnoreCase)) { throw 'Loaded module path/image size mismatch.' }
            if ($modules.ContainsKey($ev.ProcessID) -and $modules[$ev.ProcessID].base -ne $item.base) { throw 'Ambiguous module/PID lifetime.' }
            $modules[$ev.ProcessID] = $item
        }
    })
    $source.Kernel.add_ProcessStart([Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.ProcessTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds) { $lifetimes[$ev.ProcessID].Add([pscustomobject]@{ kind = 'start'; qpc = $ev.TimeStampQPC; utc = $ev.TimeStamp.ToUniversalTime().ToString('o') }) }
    })
    $source.Kernel.add_ProcessStop([Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.ProcessTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds) { $lifetimes[$ev.ProcessID].Add([pscustomobject]@{ kind = 'stop'; qpc = $ev.TimeStampQPC; utc = $ev.TimeStamp.ToUniversalTime().ToString('o') }) }
    })
    $source.Kernel.add_PerfInfoSample([Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.SampledProfileTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds) {
            $counts[$ev.ProcessID]++
            $ip = [uint64]$ev.InstructionPointer
            $key = '{0}:{1}:{2}' -f $ev.ProcessID, $ev.ThreadID, $ev.TimeStampQPC
            if ($samples.ContainsKey($key)) { throw 'Duplicate CPU sample key.' }
            $utc = $ev.TimeStamp.ToUniversalTime()
            $window = $windows[$ev.ProcessID]
            if ($utc -lt $window.start -or $utc -gt $window.end) { throw 'CPU sample outside captured invocation window.' }
            $samples[$key] = [pscustomobject]@{ pid = $ev.ProcessID; tid = $ev.ThreadID; qpc = $ev.TimeStampQPC; ip = $ip; utc = $utc.ToString('o') }
        }
    })
    $source.Kernel.add_StackWalkStack([Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.StackWalkStackTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds) {
            $key = '{0}:{1}:{2}' -f $ev.ProcessID, $ev.ThreadID, $ev.EventTimeStampQPC
            if (-not $stacks.ContainsKey($key)) { $stacks[$key] = [Collections.Generic.List[object]]::new() }
            $ips = [uint64[]]::new($ev.FrameCount)
            for ($i = 0; $i -lt $ips.Length; $i++) { $ips[$i] = $ev.InstructionPointer($i) }
            $stacks[$key].Add([pscustomobject]@{ ips = $ips; event_qpc = $ev.EventTimeStampQPC; stack_qpc = $ev.TimeStampQPC })
        }
    })
    $referenceHandler = [Action[Microsoft.Diagnostics.Tracing.Parsers.Kernel.StackWalkRefTraceData]]{
        param($ev)
        if ($ev.ProcessID -in $targetIds) { $compressedRefs.Add([pscustomobject]@{ pid = $ev.ProcessID; tid = $ev.ThreadID; qpc = $ev.EventTimeStampQPC }) }
    }
    $source.Kernel.add_StackWalkStackKeyKernel($referenceHandler)
    $source.Kernel.add_StackWalkStackKeyUser($referenceHandler)
    try {
        $processed = $source.GetType().GetMethod('Process').Invoke($source, @())
        $report.events_lost = $source.EventsLost
        if (-not $processed -or $source.EventsLost -ne 0) { throw 'Incomplete ETL or lost events.' }
    } finally { $source.Dispose() }
    foreach ($targetId in $targetIds) {
        $starts = @($lifetimes[$targetId] | Where-Object kind -ceq 'start')
        $stops = @($lifetimes[$targetId] | Where-Object kind -ceq 'stop')
        if ($starts.Count -ne 1 -or $stops.Count -ne 1 -or $starts[0].qpc -ge $stops[0].qpc) { throw 'Ambiguous or incomplete captured PID lifetime.' }
    }
    if ($compressedRefs.Count -ne 0) { throw 'Compressed stack references require explicit restoration; unsupported capture rejected.' }
    $queries = @{}; $stackRows = [Collections.Generic.List[object]]::new()
    $kernelBoundary = [Convert]::ToUInt64('8000000000000000', 16)
    $splitSamples = 0L; $stackEvents = 0L; $nonCpuKeys = 0L; $maxFrames = 0
    foreach ($key in $stacks.Keys) { $stackEvents += $stacks[$key].Count; if (-not $samples.ContainsKey($key)) { $nonCpuKeys++ } }
    foreach ($key in @($samples.Keys | Sort-Object)) {
        $sample = $samples[$key]; $m = $modules[$sample.pid]
        if ($null -eq $m) { throw 'Missing sampled process module.' }
        if ($sample.ip -ge $m.base -and $sample.ip -lt $m.base + $m.size) {
            $moduleCounts[$sample.pid]++
            $rva = '0x{0:X}' -f ($sample.ip - $m.base)
            if (-not $rvas.ContainsKey($rva)) { $rvas[$rva] = 0L }; $rvas[$rva]++
        }
        if (-not $stacks.ContainsKey($key)) { throw 'Missing CPU sample stack.' }
        $chains = @($stacks[$key].ToArray())
        if ($chains.Count -lt 1 -or $chains.Count -gt 2 -or @($chains | Where-Object { $_.ips.Length -eq 0 }).Count) { throw 'Unsupported or empty CPU stack chain.' }
        $matching = @($chains | Where-Object { $_.ips[0] -eq $sample.ip })
        if ($matching.Count -ne 1) { throw 'Sample IP must match exactly one stack head.' }
        $orderedChains = @($matching[0])
        if ($chains.Count -eq 2) {
            $other = @($chains | Where-Object { $_.ips[0] -ne $sample.ip })
            if ($sample.ip -lt $kernelBoundary -or $other.Count -ne 1 -or $other[0].ips[0] -ge $kernelBoundary -or
                @($matching[0].ips | Where-Object { $_ -lt $kernelBoundary }).Count -or
                @($other[0].ips | Where-Object { $_ -ge $kernelBoundary }).Count) { throw 'Unknown split kernel/user stack layout.' }
            $orderedChains += $other[0]; $splitSamples++
        }
        $frames = [Collections.Generic.List[object]]::new()
        for ($chainIndex = 0; $chainIndex -lt $orderedChains.Count; $chainIndex++) {
            $chain = $orderedChains[$chainIndex]
            for ($i = 0; $i -lt $chain.ips.Length; $i++) {
                $ip = $chain.ips[$i]; $lookup = $null
                if ($ip -ge $m.base -and $ip -lt $m.base + $m.size) {
                    $offset = $ip - $m.base
                    if ($i -gt 0) { if ($offset -eq 0) { throw 'Return address underflows module.' }; $offset-- }
                    $lookup = '0x{0:X}' -f [uint64]$offset; $queries[$lookup] = $true
                }
                $frames.Add([ordered]@{ chain = $chainIndex; index = $i; ip = ('0x{0:X}' -f $ip); lookup_rva = $lookup; return_address_adjusted = ($i -gt 0 -and $null -ne $lookup) })
            }
        }
        $maxFrames = [Math]::Max($maxFrames, $frames.Count)
        $stackRows.Add([ordered]@{ key = $key; pid = $sample.pid; tid = $sample.tid; event_qpc = $sample.qpc; sample_utc = $sample.utc; sampled_ip = ('0x{0:X}' -f $sample.ip); chain_count = $chains.Count; physical_frames = $frames.ToArray() })
    }
    if ($samples.Count -ne ($counts.Values | Measure-Object -Sum).Sum -or $stackRows.Count -ne $samples.Count) { throw 'CPU stack accounting mismatch.' }
    $report.stack_statistics = [ordered]@{ matched_samples = $samples.Count; missing_samples = 0; duplicate_sample_keys = 0; split_kernel_user_samples = $splitSamples; compressed_references = $compressedRefs.Count; target_stack_events = $stackEvents; target_stack_keys = $stacks.Count; non_cpu_stack_keys = $nonCpuKeys; maximum_combined_frames = $maxFrames }
    $report.sample_stacks = $stackRows.ToArray()
    foreach ($targetId in $targetIds) {
        if ($counts[$targetId] -le 0 -or $moduleCounts[$targetId] -le 0 -or -not $modules.ContainsKey($targetId)) { throw 'Missing target process samples/module.' }
        $report.per_pid += [ordered]@{ pid = $targetId; samples = $counts[$targetId]; module_samples = $moduleCounts[$targetId]; captured_window = $windows[$targetId]; process_lifetime_events = $lifetimes[$targetId].ToArray() }
        $report.sample_total += $counts[$targetId]; $report.module_samples += $moduleCounts[$targetId]
        $report.modules += $modules[$targetId]
    }
    foreach ($key in $rvas.Keys) { $queries[$key] = $true }
    $keys = @($queries.Keys | Sort-Object)
    $args = @("--obj=$($binary.path)", '--relative-address', '--inlines', '--output-style=JSON', '--no-debuginfod')
    $info = [Diagnostics.ProcessStartInfo]::new($symbolizer.path)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in $args) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $started = $false
    try {
        $started = $process.Start(); if (-not $started) { throw 'Symbolizer start failed.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        foreach ($key in $keys) { $process.StandardInput.WriteLine($key) }; $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) { throw 'Symbolizer deadline exceeded.' }
        $raw = $stdout.GetAwaiter().GetResult(); $err = $stderr.GetAwaiter().GetResult()
        $report.symbolizer = [ordered]@{ program = $symbolizer.path; argv = $args; exit = $process.ExitCode; stderr = $err; query_count = $keys.Count }
        if ($process.ExitCode -ne 0 -or $err) { throw 'Symbolizer failed.' }
    } finally { if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
    $rows = @($raw.Trim() -split '\r?\n' | ForEach-Object { $_ | ConvertFrom-Json })
    if ($rows.Count -ne $keys.Count) { throw 'Symbol row count mismatch.' }
    $exclusive = @{}; $inclusive = @{}; $symbolsByRva = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $row = $rows[$i]
        if ([Convert]::ToUInt64($row.Address.Substring(2), 16) -ne [Convert]::ToUInt64($keys[$i].Substring(2), 16)) { throw 'Symbol address mismatch.' }
        $symbols = @($row.Symbol); $symbolsByRva[$keys[$i]] = $symbols
        $count = if ($rvas.ContainsKey($keys[$i])) { $rvas[$keys[$i]] } else { 0L }
        $report.addresses += [ordered]@{ rva = $keys[$i]; samples = $count; inline_frames = $symbols }
        if ($count -eq 0) { continue }
        if ($symbols.Count -eq 0 -or -not $symbols[0].FunctionName -or $symbols[0].FunctionName -eq '??') { $report.unresolved_module_samples += $count; continue }
        $leaf = $symbols[0].FunctionName
        if (-not $exclusive.ContainsKey($leaf)) { $exclusive[$leaf] = 0L }; $exclusive[$leaf] += $count
        foreach ($fn in @($symbols | ForEach-Object FunctionName | Where-Object { $_ -and $_ -ne '??' } | Select-Object -Unique)) {
            if (-not $inclusive.ContainsKey($fn)) { $inclusive[$fn] = 0L }; $inclusive[$fn] += $count
        }
    }
    $report.exclusive_inline_leaf = @($exclusive.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ function = $_.Key; samples = $_.Value; fraction_of_all_samples = $_.Value / [double]$report.sample_total } })
    $report.inclusive_inline_functions = @($inclusive.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ function = $_.Key; samples = $_.Value; fraction_of_all_samples = $_.Value / [double]$report.sample_total } })
    $runtime = @{}
    foreach ($stackRow in $stackRows) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($frame in $stackRow.physical_frames) {
            if ($null -eq $frame.lookup_rva) { continue }
            $symbols = $symbolsByRva[$frame.lookup_rva]
            $valid = @($symbols | Where-Object { $_.FunctionName -and $_.FunctionName -cne '??' })
            if ($valid.Count -eq 0) { $report.unresolved_runtime_module_frames++; continue }
            foreach ($symbol in $valid) { $null = $seen.Add($symbol.FunctionName) }
        }
        foreach ($fn in $seen) { if (-not $runtime.ContainsKey($fn)) { $runtime[$fn] = 0L }; $runtime[$fn]++ }
    }
    $report.runtime_function_inclusive = @($runtime.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ function = $_.Key; samples = $_.Value; fraction_of_all_samples = $_.Value / [double]$report.sample_total } })
    $accounted = ($exclusive.Values | Measure-Object -Sum).Sum + $report.unresolved_module_samples
    if ($accounted -ne $report.module_samples) { throw 'Exclusive sample accounting mismatch.' }
    foreach ($row in $provenance) {
        $after = Identity $row.path; $row.after_bytes = $after.bytes; $row.after_sha256 = $after.sha256
        if ($row.before_bytes -ne $after.bytes -or $row.before_sha256 -cne $after.sha256) { throw 'Provenance changed.' }
    }
    $report.status = 'fresh_cpu_attribution_verified'
} catch { $report.error = $_.Exception.ToString(); $failure = $_ }
finally {
    foreach ($held in $locks) { $held.Dispose() }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    $stream = [IO.File]::Open((Join-Path $work 'report.json'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write(($report | ConvertTo-Json -Depth 15)) } finally { $writer.Dispose() }
}
if ($null -ne $failure) { throw $failure }
Write-Host "Fresh CPU attribution verified: $(Join-Path $work 'report.json')"
$report.exclusive_inline_leaf | Select-Object -First 15 | ConvertTo-Json
