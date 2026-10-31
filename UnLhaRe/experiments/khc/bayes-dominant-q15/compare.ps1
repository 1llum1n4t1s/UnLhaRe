#requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$SevenZipPath,
    [Parameter(Mandatory)][string]$ControlBinary,
    [Parameter(Mandatory)][string]$GroupPath,
    [Parameter(Mandatory)][string]$WorkDirectory
)

# 実装前に列挙した失敗条件:
# 入力/exeの不存在・長さ/hash不一致、パス祖先のreparse、既存workへの上書き、
# groupの11件metadata/本文とmanifestの不一致、processの非zero終了/timeout、
# 復号hash/metadata不一致、入力/binary/script/manifestの変更、出力の非決定性。
# いずれも成功reportを禁止する。安全な新規workを確保できた後の失敗はreportを残す。
# compare-bsc-reference.ps1の計測/検証を再利用するが外部BSCは実行しない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build = [IO.Path]::GetFullPath((Join-Path $root 'build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$fixedHash = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
$fixedBytes = 2811006L
$candidateExpectedHash = 'A98326FBF88608DACE22D44DF934DF5EC3062AB684E934F644013024E69B0FBE'
$controlExpectedHash = '7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0'
$sevenExpectedHash = 'EDBEE35370E14030E4C785CF88200F42DC651C1EB4217C1E3963C38A12F099B0'
$runs = [Collections.Generic.List[object]]::new()
$samples = [Collections.Generic.List[object]]::new()
$tracked = [Collections.Generic.List[object]]::new()
$snapshots = [Collections.Generic.List[object]]::new()
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$report = [ordered]@{
    status = 'failed'
    started_utc = [DateTime]::UtcNow.ToString('o')
    error = $null
    environment = [ordered]@{
        os = [Runtime.InteropServices.RuntimeInformation]::OSDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
        stopwatch_frequency = [Diagnostics.Stopwatch]::Frequency
        stopwatch_high_resolution = [Diagnostics.Stopwatch]::IsHighResolution
        cpu = @()
    }
    fixed_gate = [ordered]@{ input_bytes = $fixedBytes; input_sha256 = $fixedHash; archive_bytes_max = 483599; encode_ms_exclusive_max = 574.5624 }
    paired_comparison = $null
    host_load_observations = $null
    settings = [ordered]@{ warmups = 1; measured_rounds = 9; process_timeout_seconds = 120; requested_poll_ms = 1; candidate_threads = 1; seven_zip_threads = 1 }
    provenance = $tracked
    input_entries = $snapshots
    invocations = $runs
    samples = $samples
    notes = @(
        'Light and heavy stream-owned loss tables, light learning, lazy heavy allocation and journal growth/replay are included in full process wall time and memory; no global cache is used.',
        'The 544-byte Prediction snapshot, copies and live-weight fallback are included in full process wall time and memory.',
        'The 524296-byte KT table and 262144-byte integer seed table, initialization and refinement are included in full process wall time and memory.'
        'The candidate is an independent research prototype, not a product acceptance or overall 7-Zip victory claim.',
        'Q15 dominant-shortcut integer scheduled candidate and frozen balanced KT Q32 control use identical KHSGRP0 input but different magic/predictions/frames. Their independently E2E-verified exact frames are mandatory. Native 11-file 7z solid archive has different container and output boundaries.',
        'Fixed historical gate and current-session paired ratios are separate; total container bytes are used, never inferred payload-only sizes.',
        'Encode wall time starts before process launch and ends after exit and stdout/stderr drain; CPU time belongs to the child process.',
        'Thread and memory polling requests 1 ms waits; enumeration overhead changes actual intervals. Thread exit/enumeration races are recorded. Unobserved threads do not prove single-thread execution.',
        'Single-thread command settings are recorded separately from sampled OS threads; auxiliary threads may exist.',
        'Direct decode/hash and native metadata verification run at rounds 0 and 9; intermediate archives must match the successfully decoded first archive SHA-256 exactly.',
        'Decode writes one group file for candidate/group-7z and 11 files for native-7z. Decode timings are diagnostic and excluded from adoption decisions because these output/size boundaries are unequal.',
        'Fixed Canterbury development corpus only; no holdout, general performance, product metadata or selective extraction claim.'
    )
}

function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse point is not allowed: $current"
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function Get-FileIdentity([string]$Path) {
    Assert-NoReparse $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item -isnot [IO.FileInfo]) { throw "Expected a regular file: $Path" }
    [pscustomobject]@{ path = $item.FullName; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
}

function Track-File([string]$Path, [string]$Role) {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $identity = Get-FileIdentity $Path
    $row = [pscustomobject]@{ role = $Role; path = $identity.path; before_bytes = $identity.bytes; before_sha256 = $identity.sha256; after_bytes = $null; after_sha256 = $null }
    $tracked.Add($row)
    return $row
}

function Write-NewBytes([string]$Path, [byte[]]$Bytes) {
    Assert-NoReparse $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}

function Invoke-Recorded([string]$Program, [string[]]$Argv, [string]$Kind, [string]$Codec, [int]$Round, [int]$Order, [string]$Cwd, [string]$Output = '') {
    if ($Output) {
        Assert-NoReparse $Output
        if (Test-Path -LiteralPath $Output) { throw "Refusing existing process output: $Output" }
    }
    $row = [ordered]@{
        kind = $Kind; codec = $Codec; round = $Round; warmup = ($Round -eq 0); order = $Order
        program = $Program; argv = $Argv; working_directory = $Cwd; output_path = $Output
        started_utc = [DateTime]::UtcNow.ToString('o'); exit_code = $null; timed_out = $false; error = $null
        stdout = ''; stderr = ''; wall_ms = $null; cpu_ms = $null; peak_working_bytes = $null; peak_private_sampled_bytes = 0L
        output_bytes = $null; output_sha256 = $null; max_thread_count_sampled = 0
        poll_count = 0; max_poll_interval_ms = 0.0; thread_observations = @(); sampling_races = @()
    }
    $runs.Add($row)
    Assert-QuietHost "$Codec/$Kind/$Round-before"
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $Cwd
    foreach ($argument in $Argv) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $stdoutTask = $null
    $stderrTask = $null
    $started = $false
    $threads = @{}
    $races = [Collections.Generic.List[object]]::new()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastPoll = 0.0
    try {
        $started = $process.Start()
        if (-not $started) { throw 'Process did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1)) {
            $elapsed = $watch.Elapsed.TotalMilliseconds
            if ($elapsed -gt 120000) { $row.timed_out = $true; throw 'Per-process 120 second deadline exceeded.' }
            $row.poll_count++
            $row.max_poll_interval_ms = [Math]::Max($row.max_poll_interval_ms, $elapsed - $lastPoll)
            $lastPoll = $elapsed
            try {
                $process.Refresh()
                $row.peak_working_bytes = [Math]::Max([long]$row.peak_working_bytes, $process.PeakWorkingSet64)
                $row.peak_private_sampled_bytes = [Math]::Max($row.peak_private_sampled_bytes, $process.PrivateMemorySize64)
                $collection = $process.Threads
                $row.max_thread_count_sampled = [Math]::Max($row.max_thread_count_sampled, $collection.Count)
                foreach ($thread in $collection) {
                    try {
                        $id = $thread.Id
                        $cpuMs = $thread.TotalProcessorTime.TotalMilliseconds
                        if (-not $threads.ContainsKey($id)) {
                            $threads[$id] = [ordered]@{ thread_id = $id; samples = 0; first_seen_ms = $elapsed; last_seen_ms = $elapsed; first_cpu_ms = $cpuMs; max_cpu_ms = $cpuMs }
                        }
                        $threads[$id].samples++
                        $threads[$id].last_seen_ms = $elapsed
                        $threads[$id].max_cpu_ms = [Math]::Max($threads[$id].max_cpu_ms, $cpuMs)
                    } catch { $races.Add([pscustomobject]@{ elapsed_ms = $elapsed; scope = 'thread'; error = $_.Exception.Message }) }
                    finally { $thread.Dispose() }
                }
            } catch { $races.Add([pscustomobject]@{ elapsed_ms = $elapsed; scope = 'process'; error = $_.Exception.Message }) }
        }
        $row.stdout = $stdoutTask.GetAwaiter().GetResult()
        $row.stderr = $stderrTask.GetAwaiter().GetResult()
        $watch.Stop()
        $row.exit_code = $process.ExitCode
        $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds
        $row.peak_working_bytes = [Math]::Max([long]$row.peak_working_bytes, $process.PeakWorkingSet64)
        if ($row.exit_code -ne 0) { throw "Process exited with code $($row.exit_code)." }
        if ($Output) {
            $identity = Get-FileIdentity $Output
            $row.output_bytes = $identity.bytes
            $row.output_sha256 = $identity.sha256
            if ($identity.bytes -le 0) { throw 'Process produced an empty output.' }
        }
    } catch {
        $row.error = $_.Exception.Message
        throw
    } finally {
        if ($started) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            if ($null -ne $stdoutTask) { try { $row.stdout = $stdoutTask.GetAwaiter().GetResult() } catch { } }
            if ($null -ne $stderrTask) { try { $row.stderr = $stderrTask.GetAwaiter().GetResult() } catch { } }
            try { $row.exit_code = $process.ExitCode; $row.cpu_ms = $process.TotalProcessorTime.TotalMilliseconds } catch { }
        }
        if ($watch.IsRunning) { $watch.Stop() }
        $row.wall_ms = $watch.Elapsed.TotalMilliseconds
        $row.thread_observations = @($threads.Values | Sort-Object { $_.thread_id })
        $row.sampling_races = @($races.ToArray())
        if ($Output -and (Test-Path -LiteralPath $Output)) {
            try { $identity = Get-FileIdentity $Output; $row.output_bytes = $identity.bytes; $row.output_sha256 = $identity.sha256 } catch { }
        }
        $process.Dispose()
    }
    Assert-QuietHost "$Codec/$Kind/$Round-after"
    return [pscustomobject]$row
}

function Assert-NativeListing([string]$Text) {
    $lines = @($Text -split '\r?\n')
    $separator = [Array]::IndexOf($lines, '----------')
    if ($separator -lt 0) { throw 'Missing 7-Zip technical listing separator.' }
    $header = @($lines[0..$separator])
    if (@($header | Where-Object { $_ -ceq 'Solid = +' }).Count -ne 1 -or
        @($header | Where-Object { $_ -ceq 'Blocks = 1' }).Count -ne 1) { throw 'Native archive must contain one solid block.' }
    $entries = [Collections.Generic.List[object]]::new()
    $name = $null
    $size = $null
    foreach ($line in $lines[($separator + 1)..($lines.Count - 1)]) {
        if ($line -cmatch '^Path = (.*)$') {
            if ($null -ne $name) {
                if ($null -eq $size) { throw 'Missing entry size.' }
                $entries.Add([pscustomobject]@{ name = $name; bytes = $size })
            }
            $name = $Matches[1]; $size = $null
        } elseif ($line -cmatch '^Size = ([0-9]+)$') {
            if ($null -eq $name -or $null -ne $size) { throw 'Unexpected listing size.' }
            $size = [long]$Matches[1]
        }
    }
    if ($null -ne $name) {
        if ($null -eq $size) { throw 'Missing final entry size.' }
        $entries.Add([pscustomobject]@{ name = $name; bytes = $size })
    }
    if ($entries.Count -ne 11) { throw 'Native archive entry count mismatch.' }
    for ($i = 0; $i -lt 11; $i++) {
        if ($entries[$i].name -cne $snapshots[$i].name -or $entries[$i].bytes -ne $snapshots[$i].bytes) { throw "Native archive metadata/order mismatch: $i" }
    }
}

function Assert-NumericInvocations([object[]]$Records) {
    # 数値CLIはtimeoutでthrowするため、成功記録に存在しないtimeout欄へアクセスしない。
    foreach ($record in $Records) {
        foreach ($name in @('program','argv','exit','expected_exit','stdout','stderr')) {
            if ($null -eq $record -or $null -eq $record.PSObject.Properties[$name]) { throw "Numeric invocation missing required field: $name" }
            if ($null -eq $record.PSObject.Properties[$name].Value) { throw "Numeric invocation null required field: $name" }
        }
        if ($record.exit -ne $record.expected_exit -or ($record.expected_exit -eq 0 -and $record.stderr) -or ($record.expected_exit -ne 0 -and $record.stdout)) { throw 'Numeric invocation exit/output mismatch.' }
    }
}

function Get-Median([double[]]$Values) { $sorted = @($Values | Sort-Object); return $sorted[4] }

# workを確保できない場合は既存データへ失敗reportすら書かない。
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be a new directory below UnLhaRe/build.' }
Assert-NoReparse $work
$expectedWork=[IO.Path]::GetFullPath((Join-Path $root 'build/khc-bayes-dominant-q15-20261002-codec/performance'))
if(-not $work.Equals($expectedWork,[StringComparison]::OrdinalIgnoreCase)){throw 'WorkDirectory must be the frozen integer refinement codec performance directory.'}
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory exists; no data will be overwritten.' }
$report['disk_budget_before'] = & (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 128
try {
    $observer=Join-Path $PSScriptRoot '../causal-bayes-float-cts/quiet-host.ps1'
    $observerIdentity=Track-File $observer 'quiet-host.ps1'
    if($observerIdentity.before_sha256 -cne 'E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'){throw 'Quiet observer identity mismatch.'}
    . $observer
    $report.host_load_observations=$hostLoadObservations
    Assert-QuietHost 'preflight' 5
    $null=New-Item -ItemType Directory -Path $work
    Assert-NoReparse $work
} catch {
    foreach($held in $locks){$held.Dispose()}
    throw
}
$failure = $null
try {
    $report.environment.cpu = @(Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors)
    $report.environment['resolved_cwd'] = [IO.Path]::GetFullPath((Get-Location).Path)
    $report.environment['powershell_executable'] = (Get-Process -Id $PID).Path
    $report.environment['script_path'] = $PSCommandPath
    $report.environment['script_last_write_utc'] = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o')
    $report.environment['power_scheme'] = @(powercfg /getactivescheme)
    $candidate = Track-File ([IO.Path]::GetFullPath($BinaryPath)) 'bayes-binary'
    $control = Track-File ([IO.Path]::GetFullPath($ControlBinary)) 'frozen-control-binary'
    if ($control.before_sha256 -cne $controlExpectedHash) { throw 'Frozen control identity mismatch.' }
    $seven = Track-File ([IO.Path]::GetFullPath($SevenZipPath)) 'sevenzip-binary'
    $groupSource = Track-File ([IO.Path]::GetFullPath($GroupPath)) 'fixed-group-source'
    $manifest = Track-File (Join-Path $PSScriptRoot '../CORPUS_MANIFEST.json') 'manifest'
    $null = Track-File $PSCommandPath 'harness'
    # Q32とcontrol/BWT検証のsupport sourceも、読込み前に固定する。
    $sourcePins = [ordered]@{
        '../causal-bayes-float-cts/quiet-host.ps1' = 'E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'
        '../causal-bayes-q32/verify.ps1' = '1E71EFE27CB296F993E8CCD72E68C021132FD63E7392055E88D9F7EE19C79BE4'
        '../causal-bayes-q32/verify-numeric.ps1' = 'B02BC0CA6DEBF59DE92C7A47F4F822E0639B0C3CA78A65A02AEEE3989450AA08'
        '../causal-bayes-sais/audit_cli.rs' = '6763DFAB6F350C41D977A84753001112A14BA1CD1556483218C077851A9D0EA4'
        '../causal-bayes-sais/compare.ps1' = 'C37651CF01DB86CBC1306E371494AE8210812CE16DE6A4421BFA965309AD751B'
        '../causal-bayes-q32/codec.rs' = 'A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
        '../causal-bayes-exact-div/cts_model.rs' = 'DC6741D14EC89E0E3CE721F5209C1FF807F5146ECAFBBD1266608025DFAF121D'
        '../causal-bayes-sais/codec.rs' = '5F9CF36402E0F9125B3773AF9CB8236EFEA9062ACDB5875BBED7A5D2E17B7EA6'
        '../causal-bayes-exact-div/exact_div.rs' = 'AA6490E9F20094E6149480713475634C756C5969733FD8725C565A9839F59229'
        '../causal-bayes-q32/cts_model.rs' = '52CD54524DD89565DBEEEA2B1F3B5E89668DD8429453692663D3EDAA6D488D88'
        '../range.rs' = '1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
        '../CAUSAL_BAYES_Q32_CONTRACT_20260930.md' = 'FF48085A6C534BDC1777E4BF6542E285800811753192086362405F3A04CD71DB'
        '../causal-bayes-packed/bayes_model.rs' = '65658333E8D3EB5EBD71B05AEBCD653B8E3506580203439C2E8912DFE3DB0EB9'
        '../CORPUS_MANIFEST.json' = '77F2A728B33AE54655B67DCC3BCAA85D0912B98BA0F44343C64F903707BD5036'
        '../causal-bayes-fast-bwt/audit_cli.rs' = '1EF417E8A97C308E4432C677B48040E4DDB68BE6E375254D5C0AE13E33646691'
        '../causal-bayes-fast-bwt/bwt.rs' = 'CE0B1E09C63D651A4AE0A35F8B406F9CBEAB02D54A1CD594037C20F3B665F14C'
        '../causal-bayes-sais/bwt.rs' = '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
        '../CAUSAL_BAYES_SAIS_CONTRACT_20260930.md' = '6A4AD011C31A0C6CAB2DE68EC6900D59B2A736EC9C123805A5BB4ECA5AD6FD4C'
        '../causal-bayes-float-cts/QUIET_HOST_CONTRACT_20260930.md' = 'E19663EDB1A0345EF3347EA398772A9A4364E61C162C385D31EA8B14F8C97D62'
        '../rejected-binary-mix/packed_alphabet.rs' = '4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
        '../causal-bayes-sais/verify-bwt.ps1' = '29B243D5AB6A2E47F424B1EB648BEDBEAE3BA8044547CD99C9C6767E5CB4FAD6'
        '../causal-bayes-q32/audit_cli.rs' = '70DF2E96C508555694B0BA785781EAF767B7DE90FAA96E3CAA1FBDC2B139F1C9'
    }
    $sourcePins['../causal-bayes-q32-corrected/codec.rs']='A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    $sourcePins['../causal-bayes-q32-corrected/cts_model.rs']='DC876ED9B5B7FDB921A8522FA214FA80A76C317FD8F7BB6AC297DAF175ABF99B'
    $sourcePins['../causal-bayes-q32-corrected/verify.ps1']='BD55C3E29541B37E8673198D9BC5930B677724FE19F1F1D6B1CB1588D281C574'
    $sourcePins['../causal-bayes-q32-corrected/build.ps1']='B051B71526232075D7475BD362A006CAEAE47B5014A933814F83D5B0115DD56D'
    $sourcePins['../corrected-quotient/exact_div.rs']='52595705A96F939B63D0DDB88871F3E7F78419973B0891E7A79E42579EA81D3A'
    $sourcePins['../causal-bayes-q32-corrected-lut/codec.rs']='54C3A877913FAF5E72486E21552DCA85D39803C88A56DEAA5655AC83397BA74C'
    $sourcePins['../causal-bayes-q32-corrected-lut/verify.ps1']='283195E75A2E8258F874F06D0B3D280C875F2289B6919D23DD202F44BBEEF0CF'
    $sourcePins['../causal-bayes-q32-corrected-lut/build.ps1']='98E005EE1C62FF145CB758CA46FB3FAC90FE685FB5B2EFB2ABDF003319A4BC71'
    $sourcePins['../causal-bayes-log-table/bayes_model.rs']='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'

    $sourcePins['../causal-bayes-q32-corrected-lut-inline/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-corrected-lut-inline/cts_model.rs']='86FABD5061CA3187AB82F63A6D331CE1C91D21DB0F5E61A2D5A19B708E4810FE'
    $sourcePins['../causal-bayes-q32-corrected-lut-inline/exact_div.rs']='1A82EDBCA1616C3F52F0855ADC449BA1468E4E5F3E1C2031EF254F43B4659BF1'
    $sourcePins['../causal-bayes-q32-corrected-lut-inline/verify.ps1']='36BB185E92E994A0B4049B1DB255E1A0C422C329E3B857E71F5F2CF25B048D24'
    $sourcePins['../causal-bayes-q32-corrected-lut-inline/build.ps1']='A6D3C5DDA6C237367E3EA9C520851B5AF13256EABF08F3B83FB9DC0BD97194D3'
    $sourcePins['../Q32_INLINE_CONTRACT_20261001.md']='1095D1B7548D73A411271B58A369C10259F0F0178EBE16C9010F5339897EDFA5'
    $sourcePins['../Q32_INLINE_PERFORMANCE_CONTRACT_20261001.md']='A71EAB1F7C1401A583FF4F01CCBC058434BE5824E58958118809AA00A8E7B26E'

    $sourcePins['../causal-bayes-q32-split-lut/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-split-lut/cts_model.rs']='87AD15A78B390FA3F34A2ED6C36DD19CEAC05E4B3D29979207BA9A11B52393EA'
    $sourcePins['../causal-bayes-q32-split-lut/verify.ps1']='57A80259A9588EE87F170669086C1B2AB3C449D447E88C2F963E0C7F064F34E4'
    $sourcePins['../causal-bayes-q32-split-lut/build.ps1']='61252518210E7B575AC922F7735A62F839558D99F5FDDDE876604CFFF1A4F6F6'
    $sourcePins['../split-estimate-quotient/exact_div.rs']='D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'
    $sourcePins['../split-estimate-quotient/audit_cli.rs']='9DEAE4E323413DEFA8F3FC4574C6ACF722B04A260DBF8CE8D649582A5E76C048'
    $sourcePins['../split-estimate-quotient/verify.ps1']='A8990B229AC8207E7741F4C85342AF81AC81E1D06B0D0DA5EE955B16AA609426'
    $sourcePins['../Q32_SPLIT_ESTIMATE_CONTRACT_20261001.md']='5A9693B2BEE9FBF72A2958460B80BA59F7B756B22C0F1BEDA9CFBD41372AD50F'
    $sourcePins['../Q32_SPLIT_CODEC_CONTRACT_20261001.md']='43190210B117B0FEDF3BAE082F6DAD17DB3B907C466FC7151C95E53FE06D843B'
    $sourcePins['../Q32_SPLIT_PERFORMANCE_CONTRACT_20261001.md']='4A794C379DEC24104ED429C0639BA97B62A18B18717300ED24FC4AF770C5C90F'
    $sourcePins['../Q32_SPLIT_ESTIMATE_CODEGEN_20261001.md']='9626DF39B4179D41C5BE158DD82BEA735B205304756C22605A2802182D2576AB'

    # 元splitの全source pinsを保持し、新候補の凍結source/契約を追加する。
    $sourcePins['../causal-bayes-q32-split-lut/compare.ps1']='052E6B088E35D49DDEC29E0D7174C2909BE2F6FA650978F066B99C50486237DD'
    $sourcePins['../causal-bayes-q32-mixture-reuse/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-mixture-reuse/cts_model.rs']='BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2'
    $sourcePins['../causal-bayes-q32-mixture-reuse/audit_cli.rs']='9E12278CCA39B0163228DD785A59D56FD5BEAE5FC41F3F43AD73F68D353E225E'
    $sourcePins['../causal-bayes-q32-mixture-reuse/verify-numeric.ps1']='F106178317D9DAD39B714AA32F870B4FFB7BBF6C5B44453EA219183DA3C7D87B'
    $sourcePins['../causal-bayes-q32-mixture-reuse/verify.ps1']='D1B2D8A9DD2F4FC5AE4FB1C9B6A1332E8218668A2F19DD6D24FC6E317436EE02'
    $sourcePins['../causal-bayes-q32-mixture-reuse/build.ps1']='FA832E0CE7824EC10F6530C0A4FA45507BD5764C07D5A8B5C51006F52E683996'
    $sourcePins['../Q32_MIXTURE_REUSE_CONTRACT_20261001.md']='21BE83C2C93096FE232BDC9127951B091C72D764AC52A31DDAA06422111002D8'
    $sourcePins['../Q32_MIXTURE_REUSE_CODEC_CONTRACT_20261001.md']='FD1B5FCA0FD9AB563BD84F99036D284295043444DF60436D248C820BCEA36C7E'
    $sourcePins['../Q32_MIXTURE_REUSE_CODEGEN_20261001.md']='B2FD007CB3F10D36223B649767521FB8FF22A81342CA45539F08BEC4DD4BF0D6'
    $sourcePins['../Q32_MIXTURE_REUSE_PERFORMANCE_CONTRACT_20261001.md']='92DD6F838B36C75CB1B61FF6D0A76A94486DAA15E34EB1C0490875221DEA6483'

    # 旧mixtureの全pinsを保持し、balanced KTの凍結source/契約を追加する。
    $sourcePins['../causal-bayes-q32-mixture-reuse/compare.ps1']='CF6333706D8D1A4A175F24A42B560460CB26CAF1EF85A0E1061223717A364223'
    $sourcePins['../causal-bayes-q32-balanced-kt/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-balanced-kt/cts_model.rs']='9CFC6DF121A3711D704ED9F36F8D068F03A788DBC9F1A67118BB0CA89BD2F647'
    $sourcePins['../causal-bayes-q32-balanced-kt/audit_cli.rs']='CD3F0D1FA5671AAC10A72222AA35F7DD84623D90CAE1DA9EAEE3104CC68859EC'
    $sourcePins['../causal-bayes-q32-balanced-kt/verify-numeric.ps1']='A798063ED6D6FFCDD4A1978DA375D753438AB54FA25AA71AC7866A734747C8A0'
    $sourcePins['../causal-bayes-q32-balanced-kt/verify.ps1']='B622468C23B355B0B1D21E3EDFA789170102E2CDA4EFA253EEC82B1388B70FB8'
    $sourcePins['../causal-bayes-q32-balanced-kt/build.ps1']='5C6567A3681CEA03B6245A980542B7F01CCFE4C89CB6BE09A732B9E075E8D3E6'
    $sourcePins['../Q32_BALANCED_KT_CONTRACT_20261001.md']='11EC999DC04D3E2A828DA1A5B4611A07934C309F4BE520319CEE2B418A3A35EA'
    $sourcePins['../Q32_BALANCED_KT_CODEC_CONTRACT_20261001.md']='2D96A1DB1F59A4D7902A36FAB753C8D3D61064D9BD0F3C4930A17EFA35F559DB'
    $sourcePins['../Q32_BALANCED_KT_SCHEMA_FIX_20261001.md']='2E05343F95249027943F16546BA370BB141C8ACB484E8F7D0308A3C7DA02DFAD'
    $sourcePins['../Q32_BALANCED_KT_PERFORMANCE_CONTRACT_20261001.md']='EA343FB0482B77C7BC3E7960C94FA0B6A29486BFFB636BBC82002529E2AE9D33'
    # 元比較の全pins/検査を保持し、新helper/Model/codecのCURRENTだけを追加する。
    $sourcePins['../causal-bayes-q32-balanced-kt/compare.ps1']='869873F5AC295B3ABF0392824CA737DD1420A3E01B93DFB39A459A589E6F41B8'
    $sourcePins['../causal-bayes-q32-native32/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-native32/cts_model.rs']='27775D82F1A94E013C83A2D42C8A004D7EF507ED09302EB1BB0704DCC798B0A0'
    $sourcePins['../causal-bayes-q32-native32/audit_cli.rs']='CD3F0D1FA5671AAC10A72222AA35F7DD84623D90CAE1DA9EAEE3104CC68859EC'
    $sourcePins['../causal-bayes-q32-native32/verify-model.ps1']='A85145449FE86B22CE8AAABA5A3506A2DFBC2712CFCCFF6CA966845D257F52AD'
    $sourcePins['../causal-bayes-q32-native32/verify-codec.ps1']='F4E4FDA8E56AAF2D134262AC42D76EB765A79F68E933800D6C9857FCC41A5609'
    $sourcePins['../native32-quotient/exact_div.rs']='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
    $sourcePins['../native32-quotient/audit_cli.rs']='267F08FF911C86A88E343DBB7810D6B4CBB832F4CF0CB3A2217305FD6BA51F16'
    $sourcePins['../native32-quotient/verify.ps1']='E41C6506569EB02C7F84572186FA7857741CD5F32797F5346CB1267CCDAD4277'
    $sourcePins['../Q32_NATIVE32_NUMERIC_CONTRACT_20261001.md']='298E94B29F0174BE9567D7153E2A49E9DC529D69100F862276714B3E96724F0D'
    $sourcePins['../Q32_NATIVE32_MODEL_CONTRACT_20261001.md']='13E0B3B9640CF0168DDDAD19777FBCAAC6B1B5DE284E9D5503831028F68E3336'
    $sourcePins['../Q32_NATIVE32_CODEC_CONTRACT_20261001.md']='9B711FFF704B1890AD7FFA8510DD5E14506615E4946DDF12C7056FB04CFF4544'
    $sourcePins['../Q32_NATIVE32_CODEGEN_20261001.md']='3F59664F6FB096E9FEC12BA73CC96A52D6A283C8624283B7DF81EDCCEE13C6C0'
    $sourcePins['../Q32_NATIVE32_PERFORMANCE_CONTRACT_20261001.md']='83B18F004C3FE12AB8428B569BDDBAD4D469224E69B661044821B94505104E22'
    $sourcePins['../causal-bayes-q32-native32/compare.ps1']='5F33B8638875865965E09ABAF535EE10E231D7E25EB283560E9377D28EF6A521'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/codec.rs']='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/cts_model.rs']='ACEAA15363123470FA09481BF6408FF2BDFF95A15D65489D64A9998B8E26F6C7'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/audit_cli.rs']='8CECE549BD88A0CD30367C3A54C540276A129BCAA5944C06965EB6F7923CD6D6'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/exact_kt.rs']='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/verify-model.ps1']='254F95D35A6B11D5F52AC3D0EFD1D85EB64E2A527FCAEDF9E6FA13E80654CF76'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/verify-codec.ps1']='57FE10670953211C194BEA06D224B025E26EEA57023A0577ADD9F0293DC6E38E'
    $sourcePins['../Q32_KT_RECIPROCAL_MODEL_CONTRACT_20261001.md']='FB2C4DAC2FF1CECD205F55C3900855D05665CC1CE30AF030A7D09AFEB08C46BC'
    $sourcePins['../Q32_KT_RECIPROCAL_CODEC_CONTRACT_20261001.md']='4A92D5C29D9DD1A08B55BB873FD29653C6783E91AF72FFED5F0CDB010BE9F783'
    $sourcePins['../Q32_KT_RECIPROCAL_PERFORMANCE_CONTRACT_20261001.md']='00366A30817A81E0D2B666850A455C0314266E92207FC256E6316C52A7DCA413'
    $sourcePins['../kt-reciprocal-table/exact_kt.rs']='D102D534397EA91055DCF0716B05EB48F1CFB0642F1B45FA27A388C894CCFE25'
    $sourcePins['../kt-reciprocal-table/verify.ps1']='D42AFBB187F7EF3CA2D2FF5077F1A5A89901176749742D54B22339E4BEA01DAE'
    $sourcePins['../causal-bayes-q32-kt-reciprocal/compare.ps1']='CE15DBEB417857C351A412ADF366C95511EEA00AFCCCA69FE228EDA2EF1C550C'
    $sourcePins['../causal-expert-scheduling/codec.rs']='0AD79D2C15CFFA96CDBED33421C20418C146BA223C872CFDCF5FD3F263ED0B64'
    $sourcePins['../causal-expert-scheduling/scheduler.rs']='7207E2467E7C0FCDA699D62DBB8D906770A4EB3AB6EED16EC6801DAB5918000D'
    $sourcePins['../causal-expert-scheduling/bayes_model.rs']='CABE510C4566B63C7AAB7F5EA0507BC3DA1EB2FA0E146E2FE568C134E3CFB9B8'
    $sourcePins['../causal-expert-scheduling/correspondence.json']='378DD52D48E9DF987062194F0BF1835680946FBA77ABDF6A01417AB4C12F4F1E'
    $sourcePins['../causal-expert-scheduling/verify.ps1']='99CB9966342207F8B4DFC8AE02B6D1F32459343C4216F02A4EA09BE179CAD4C0'
    $newPins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'performance-support-pins.json') -Raw|ConvertFrom-Json
    foreach($pin in $newPins){$sourcePins[[string]$pin.path]=[string]$pin.sha256}
    $null=Track-File (Join-Path $PSScriptRoot 'performance-support-pins.json') 'new-source-pins'
    $null=Track-File (Join-Path $PSScriptRoot 'performance-correspondence.json') 'performance-correspondence'
    $oldHarness=Track-File (Join-Path $PSScriptRoot '../causal-integer-refinement/compare.ps1') 'old-performance-harness'
    if($oldHarness.before_sha256 -cne '1BB00E71EB54CDDDAAC5146C5DC36F43B6F23F8FC37A9F0B5F1D3F546E800B51'){throw 'Old harness pin mismatch'}
    $expected=[IO.File]::ReadAllText($oldHarness.path).Replace("`r`n","`n")
    foreach($replacement in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'performance-correspondence.json') -Raw|ConvertFrom-Json)){
        if(([regex]::Matches($expected,[regex]::Escape($replacement.old))).Count -ne $replacement.count){throw 'Unique performance replacement mismatch'}
        $expected=$expected.Replace([string]$replacement.old,[string]$replacement.new)
    }
    if($expected -cne [IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n")){throw 'Complete performance source correspondence mismatch'}
    foreach($path in @($oldHarness.path,$PSCommandPath)){
        $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
        if($errors.Count){throw 'Performance PowerShell parser failure'}
        $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
        if($functions.Count -ne 8){throw 'Expected eight measurement helpers'}
        if($path -ceq $oldHarness.path){$oldFunctions=$functions}else{$newFunctions=$functions}
    }
    foreach($oldFunction in $oldFunctions){
        $matches=@($newFunctions|Where-Object Name -ceq $oldFunction.Name)
        if($matches.Count -ne 1 -or $matches[0].Body.Extent.Text -cne $oldFunction.Body.Extent.Text){throw 'Measurement helper AST changed'}
    }
    $report['measurement_helper_AST_equal']=8
    $sourcePins['../adaptive-suffix-kt/cts_model.rs']='F6E6BABE00ECB2063117D554135E8ED6F13B3B458E4FBCFA7D4B0596C6CCBB32'
    $sourcePins['../CAUSAL_EXPERT_SCHEDULING_CONTRACT_20261001.md']='3599F4C04C3EA6985A1A470B44C94980117B4DF3088C9A9AF79DCC674CD776E6'
    $sourcePins['../CAUSAL_EXPERT_SCHEDULING_PERFORMANCE_CONTRACT_20261001.md']='BCC266C6AC60AF1139A912C3790F8D4F95CA8AAED13A88C319951CAE0AA26549'
    foreach($name in $sourcePins.Keys) {
        $support=Track-File (Join-Path $PSScriptRoot $name) $name
        if($support.before_sha256 -cne $sourcePins[$name]){throw "Support source identity mismatch: $name"}
    }
    $null = Track-File 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'rustc'
    $correctness = Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/report.json') 'full-codec-e2e-proof'
    if ($correctness.before_sha256 -cne '2F7F612F63570CD58976F16F42D4DD3255DAE0DD242B6891B5CB3946463C006C') { throw 'Full codec E2E proof identity mismatch.' }
    $fullJson=Get-Content -LiteralPath $correctness.path -Raw|ConvertFrom-Json
    if($fullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($fullJson.checks).Count -ne 38 -or @($fullJson.invocations).Count -ne 63 -or @($fullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($fullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or -not $fullJson.fixed_size_gate_passed -or $fullJson.timing_used){throw 'Full codec proof incomplete.'}
    if($fullJson.fixed_candidate.bytes -ne 483469 -or $fullJson.fixed_candidate.sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'){throw 'Q32 complete frame proof mismatch.'}
    $numericProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/numeric-e2e/report.json') 'q32-numeric-e2e-proof'
    if($numericProof.before_sha256 -cne '71D5A9B2E5652D95B958ACA623CF322A1E1F833167C6E58E382F2023824A5748'){throw 'Numeric E2E proof identity mismatch.'}
    $numericJson=Get-Content -LiteralPath $numericProof.path -Raw|ConvertFrom-Json
    if($numericJson.status -cne 'verified' -or @($numericJson.checks).Count -ne 43 -or @($numericJson.invocations).Count -ne 43 -or @($numericJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($numericJson.invocations|Where-Object {$_.exit -ne $_.expected_exit -or ($_.expected_exit -eq 0 -and $_.stderr) -or ($_.expected_exit -ne 0 -and $_.stdout)}).Count -ne 0 -or $numericJson.timing_used){throw 'Numeric E2E proof incomplete.'}
    $bwtProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-sais-20260930/bwt-e2e/report.json') 'bwt-equivalence-proof'
    if($bwtProof.before_sha256 -cne '413B1CB2CA66D1C1AF0BAF12C755B7483AC076B9847FD99ED8619D31E8A6BB6F'){throw 'BWT E2E proof identity mismatch.'}
    $bwtJson=Get-Content -LiteralPath $bwtProof.path -Raw|ConvertFrom-Json
    if($bwtJson.status -cne 'verified' -or @($bwtJson.checks).Count -ne 147 -or @($bwtJson.invocations).Count -ne 301 -or @($bwtJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($bwtJson.invocations|Where-Object {$_.timed_out -or $_.exit_code -ne $_.expected_exit}).Count -ne 0){throw 'BWT E2E proof incomplete.'}
    # proof自体のpinに加え、全provenanceとネストしたinput/oracle/output evidenceを
    # 同じreadlockへ含める。重複pathでも各記録の期待値は照合する。
    $candidateCorrectness=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-20261001/full-e2e/report.json') 'corrected-full-proof'
    if($candidateCorrectness.before_sha256 -cne 'EE6864D3DB72A5175AF89A90C36847441AA1BAEE462AD42A2C887FD614C14BAB'){throw 'Corrected full proof identity mismatch.'}
    $candidateFullJson=Get-Content -LiteralPath $candidateCorrectness.path -Raw|ConvertFrom-Json
    if($candidateFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($candidateFullJson.checks).Count -ne 46 -or @($candidateFullJson.invocations).Count -ne 72 -or @($candidateFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($candidateFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $candidateFullJson.timing_used -or -not $candidateFullJson.fixed_size_gate_passed -or $candidateFullJson.fixed_candidate.bytes -ne 483469 -or $candidateFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256){throw 'Corrected full proof incomplete.'}
    $quotientProof=Track-File (Join-Path $root 'build/khc-corrected-quotient-20261001/report.json') 'exact-quotient-numeric-proof'
    if($quotientProof.before_sha256 -cne '803072EA44DB97BFFDDAC78913E975B827B9334870F82A0EB0E19051005626D6'){throw 'Exact quotient proof mismatch.'}
    $quotientJson=Get-Content -LiteralPath $quotientProof.path -Raw|ConvertFrom-Json
    if($quotientJson.status -cne 'verified' -or $quotientJson.timing_used -or @($quotientJson.checks).Count -ne 29 -or @($quotientJson.invocations).Count -ne 31 -or $quotientJson.counts[0] -ne 30937 -or @($quotientJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($quotientJson.invocations|Where-Object {$_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Exact quotient proof incomplete.'}
    $buildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-20261001/build-report.json') 'corrected-build-proof'
    if($buildProof.before_sha256 -cne '150B2D5171A1091976D5C19BBF634C3E0FFDEADD50B7BD7E9412B70147966C93'){throw 'Corrected build proof mismatch.'}
    $buildJson=Get-Content -LiteralPath $buildProof.path -Raw|ConvertFrom-Json
    if($buildJson.status -cne 'built_not_timed' -or @($buildJson.compile_calls).Count -ne 2 -or @($buildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'Corrected build proof incomplete.'}
    $report['corrected_proofs']=[ordered]@{full=$candidateCorrectness;numeric=$quotientProof;build=$buildProof}
    $null=Track-File (Join-Path $PSScriptRoot '../Q32_CORRECTED_PERFORMANCE_CONTRACT_20261001.md') 'prospective-performance-contract'
    $lutFullProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/full-e2e/report.json') 'lut-full-proof'
    if($lutFullProof.before_sha256 -cne '934C03B54DBCC1B82CC1ADF52820BC94425240D3E37F77A91DFBD389D1AFB93C'){throw 'LUT full proof identity mismatch.'}
    $lutFullJson=Get-Content -LiteralPath $lutFullProof.path -Raw|ConvertFrom-Json
    if($lutFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($lutFullJson.checks).Count -ne 55 -or @($lutFullJson.invocations).Count -ne 82 -or @($lutFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($lutFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $lutFullJson.timing_used -or -not $lutFullJson.fixed_size_gate_passed -or $lutFullJson.fixed_candidate.bytes -ne 483469 -or $lutFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256){throw 'LUT full proof incomplete.'}
    $lutBuildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/build-report.json') 'lut-build-proof'
    if($lutBuildProof.before_sha256 -cne '6BBB273BD3D4907EF51B568A86A873403BC208D12B06F236FE8A415A1382FEAC'){throw 'LUT build proof mismatch.'}
    $lutBuildJson=Get-Content -LiteralPath $lutBuildProof.path -Raw|ConvertFrom-Json
    if($lutBuildJson.status -cne 'built_not_timed' -or @($lutBuildJson.compile_calls).Count -ne 2 -or @($lutBuildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'LUT build proof incomplete.'}
    # 再利用する数値証拠と清掃receipt、保持された入力/初回/oracleも現在値を固定する。
    $lutNumericProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/report.json') 'numeric-equivalence-proof'
    if($lutNumericProof.before_sha256 -cne 'F09A9C963A823D32FDA1A8943896FA6704CC5175F813623AF1433896806A327A'){throw 'Numeric proof identity mismatch.'}
    $lutNumericJson=Get-Content -Raw -LiteralPath $lutNumericProof.path|ConvertFrom-Json
    if($lutNumericJson.status -cne 'verified' -or @($lutNumericJson.checks).Count -ne 52 -or @($lutNumericJson.invocations).Count -ne 52 -or $lutNumericJson.maximum_records -ne 65536 -or $lutNumericJson.all_q15_values_both_bits -ne 65534 -or @($lutNumericJson.checks|Where-Object {-not $_.passed}).Count){throw 'Numeric proof incomplete.'}
    $cleanupProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-log-table-20260930/numeric-e2e/cleanup.json') 'numeric-cleanup-proof'
    if($cleanupProof.before_sha256 -cne '3ACCEFD3485C8EE3ED402473744B803513D27875C3321B214ADB4286F622D31A'){throw 'Numeric cleanup identity mismatch.'}
    $cleanupJson=Get-Content -Raw -LiteralPath $cleanupProof.path|ConvertFrom-Json
    if(@($cleanupJson.targets).Count -ne 12 -or $cleanupJson.target_residual_count -ne 0){throw 'Numeric cleanup shape mismatch.'}
    $lutNumericIds=[Collections.Generic.List[object]]::new()
    foreach($id in $lutNumericJson.identities){$lutNumericIds.Add($id)}
    foreach($check in $lutNumericJson.checks){
        $evidence=$check.evidence
        if($null -ne $evidence -and $evidence.PSObject.Properties['path'] -and $evidence.PSObject.Properties['bytes'] -and $evidence.PSObject.Properties['sha256']){$lutNumericIds.Add($evidence)}
        foreach($property in $check.evidence.PSObject.Properties){
            $id=$property.Value
            if($null -ne $id -and $id.PSObject.Properties['path'] -and $id.PSObject.Properties['bytes'] -and $id.PSObject.Properties['sha256']){$lutNumericIds.Add($id)}
        }
    }
    foreach($id in @($lutNumericIds|Sort-Object path -Unique)){
        if(Test-Path -LiteralPath $id.path -PathType Leaf){$held=Track-File $id.path 'numeric-current-evidence'}
        else{
            $removed=@($cleanupJson.targets|Where-Object {$_.path -ceq $id.path -and $_.bytes -eq $id.bytes -and $_.sha256 -ceq $id.sha256})
            $savedPath=$id.path -replace '-1.output$','-0.output'
            if($removed.Count -ne 1 -or $savedPath -ceq $id.path){throw 'Unexplained numeric evidence missing.'}
            $held=Track-File $savedPath 'numeric-retained-identical-first-output'
        }
        if($held.before_bytes -ne $id.bytes -or $held.before_sha256 -cne $id.sha256){throw 'Numeric current evidence mismatch.'}
    }

    if(@($lutNumericJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit -or ($_.expected_exit -eq 0 -and $_.stderr)}).Count -ne 0 -or $lutNumericJson.timing_used){throw 'LUT numeric invocations incomplete.'}
    $report['lut_proofs']=[ordered]@{full=$lutFullProof;build=$lutBuildProof;numeric=$lutNumericProof;cleanup=$cleanupProof;numeric_distinct_records=@($lutNumericIds|Sort-Object path -Unique).Count}
    $null=Track-File (Join-Path $PSScriptRoot '../Q32_CORRECTED_LUT_PERFORMANCE_CONTRACT_20261001.md') 'prospective-lut-performance-contract'

    $inlineFullProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/full-e2e/report.json') 'inline-full-proof'
    if($inlineFullProof.before_sha256 -cne '61B1AE66494F5AFE801B9DDDF55A583071E6E3C5C63683410A19970F290683E4'){throw 'Inline full proof identity mismatch.'}
    $inlineFullJson=Get-Content -LiteralPath $inlineFullProof.path -Raw|ConvertFrom-Json
    if($inlineFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($inlineFullJson.checks).Count -ne 63 -or @($inlineFullJson.invocations).Count -ne 106 -or @($inlineFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($inlineFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $inlineFullJson.timing_used -or -not $inlineFullJson.fixed_size_gate_passed -or $inlineFullJson.fixed_candidate.bytes -ne 483469 -or $inlineFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256){throw 'Inline full proof incomplete.'}
    $inlineBuildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/build-report.json') 'inline-build-proof'
    if($inlineBuildProof.before_sha256 -cne 'A5D6ADDCC64B09AFA820A80ABA85E90AEEA3CD1F9D02B112C0D949F69621B4D8'){throw 'Inline build proof identity mismatch.'}
    $inlineBuildJson=Get-Content -LiteralPath $inlineBuildProof.path -Raw|ConvertFrom-Json
    if($inlineBuildJson.status -cne 'built_not_timed' -or @($inlineBuildJson.compile_calls).Count -ne 2 -or @($inlineBuildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'Inline build proof incomplete.'}
    $report['inline_proofs']=[ordered]@{full=$inlineFullProof;build=$inlineBuildProof}

    $splitNumericProof=Track-File (Join-Path $root 'build/khc-split-estimate-quotient-20261001/report.json') 'split-numeric-proof'
    if($splitNumericProof.before_sha256 -cne '03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29'){throw 'Split numeric proof identity mismatch.'}
    $splitNumericJson=Get-Content -LiteralPath $splitNumericProof.path -Raw|ConvertFrom-Json
    if($splitNumericJson.status -cne 'verified' -or $splitNumericJson.timing_used -or @($splitNumericJson.checks).Count -ne 47 -or @($splitNumericJson.invocations).Count -ne 31 -or $splitNumericJson.counts[0] -ne 56191 -or @($splitNumericJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($splitNumericJson.invocations|Where-Object {$_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Split numeric proof incomplete.'}
    $splitFullProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-split-lut-20261001/full-e2e/report.json') 'split-full-proof'
    if($splitFullProof.before_sha256 -cne 'FCCB873D7A29EC8FAB332D4075DC94AD18CA960193BF9C7FBEE97FE723E5924C'){throw 'Split full proof identity mismatch.'}
    $splitFullJson=Get-Content -LiteralPath $splitFullProof.path -Raw|ConvertFrom-Json
    if($splitFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($splitFullJson.checks).Count -ne 71 -or @($splitFullJson.invocations).Count -ne 130 -or @($splitFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($splitFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $splitFullJson.timing_used -or -not $splitFullJson.fixed_size_gate_passed -or $splitFullJson.fixed_candidate.bytes -ne 483469 -or $splitFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256){throw 'Split full proof incomplete.'}
    $splitBuildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-split-lut-20261001/build-report.json') 'split-build-proof'
    if($splitBuildProof.before_sha256 -cne '01033D6D34993471C6063F9FB565B0A63AA7023AC4906DC91499F057E60941EC'){throw 'Split build proof identity mismatch.'}
    $splitBuildJson=Get-Content -LiteralPath $splitBuildProof.path -Raw|ConvertFrom-Json
    if($splitBuildJson.status -cne 'built_not_timed' -or @($splitBuildJson.compile_calls).Count -ne 2 -or @($splitBuildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'Split build proof incomplete.'}
    $report['split_proofs']=[ordered]@{full=$splitFullProof;build=$splitBuildProof;numeric=$splitNumericProof}

    # CURRENTだけを正式証拠へ追加。清掃済み中間numeric rootsは参照しない。
    $mixtureNumericProof=Track-File (Join-Path $root 'build/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json') 'mixture-current-numeric-proof'
    if($mixtureNumericProof.before_sha256 -cne 'BFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72'){throw 'Mixture CURRENT numeric proof identity mismatch.'}
    $mixtureNumericJson=Get-Content -LiteralPath $mixtureNumericProof.path -Raw|ConvertFrom-Json
    if($mixtureNumericJson.status -cne 'verified' -or $mixtureNumericJson.timing_used -or @($mixtureNumericJson.checks).Count -ne 99 -or @($mixtureNumericJson.invocations).Count -ne 103 -or @($mixtureNumericJson.identities).Count -ne 87 -or $mixtureNumericJson.dataset.records -ne 65536 -or $mixtureNumericJson.counts[0] -ne 65536 -or $mixtureNumericJson.record_cap -ne 65536 -or $mixtureNumericJson.model_history.records -ne 11267 -or $mixtureNumericJson.model_history.histories -ne 7 -or $mixtureNumericJson.model_history.classes -ne 7 -or $mixtureNumericJson.model_history.levels -ne 17 -or $mixtureNumericJson.model_history.layout.prediction_bytes -ne 544 -or $mixtureNumericJson.model_history.layout.node_bytes -ne 16 -or @($mixtureNumericJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($mixtureNumericJson.invocations|Where-Object {$_.exit -ne $_.expected_exit -or ($_.expected_exit -eq 0 -and $_.stderr) -or ($_.expected_exit -ne 0 -and $_.stdout)}).Count -ne 0){throw 'Mixture CURRENT numeric proof incomplete.'}
    $mixtureFullProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/full-e2e/report.json') 'mixture-full-proof'
    if($mixtureFullProof.before_sha256 -cne 'B0AE7D16901B3755105914885C49FE44AF91BFCD8DC524FAD34F8428D49CFE56'){throw 'Mixture full proof identity mismatch.'}
    $mixtureFullJson=Get-Content -LiteralPath $mixtureFullProof.path -Raw|ConvertFrom-Json
    if($mixtureFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($mixtureFullJson.checks).Count -ne 79 -or @($mixtureFullJson.invocations).Count -ne 154 -or @($mixtureFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($mixtureFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $mixtureFullJson.timing_used -or -not $mixtureFullJson.fixed_size_gate_passed -or $mixtureFullJson.fixed_candidate.bytes -ne 483469 -or $mixtureFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256){throw 'Mixture full proof incomplete.'}
    $mixtureBuildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/build-report.json') 'mixture-build-proof'
    if($mixtureBuildProof.before_sha256 -cne '06113576C0D2DC714E6C26B0C3B342C3977749F4BA270D5035AE73E8609382E8'){throw 'Mixture build proof identity mismatch.'}
    $mixtureBuildJson=Get-Content -LiteralPath $mixtureBuildProof.path -Raw|ConvertFrom-Json
    if($mixtureBuildJson.status -cne 'built_not_timed' -or $mixtureBuildJson.timing_used -or @($mixtureBuildJson.compile_calls).Count -ne 2 -or @($mixtureBuildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'Mixture build proof incomplete.'}
    $report['mixture_proofs']=[ordered]@{full=$mixtureFullProof;build=$mixtureBuildProof;numeric_current=$mixtureNumericProof}

    $balancedNumericProof=Track-File (Join-Path $root 'build/khc-q32-balanced-kt-numeric-20261001-junction-validated/report.json') 'balanced-kt-current-numeric-proof'
    if($balancedNumericProof.before_sha256 -cne '63ACB1BBF1A2EFE811B76E761C6AA4CFDF2F4C443F75E24AD18FD97D312F5DAF'){throw 'Balanced KT CURRENT numeric proof identity mismatch.'}
    $balancedNumericJson=Get-Content -LiteralPath $balancedNumericProof.path -Raw|ConvertFrom-Json
    Assert-NumericInvocations $balancedNumericJson.invocations
    if($balancedNumericJson.status -cne 'verified' -or $balancedNumericJson.timing_used -or @($balancedNumericJson.checks).Count -ne 132 -or @($balancedNumericJson.invocations).Count -ne 137 -or @($balancedNumericJson.identities).Count -ne 105 -or $balancedNumericJson.counts[0] -ne 65536 -or $balancedNumericJson.record_cap -ne 65536 -or $balancedNumericJson.kt_dataset.records -ne 65536 -or $balancedNumericJson.kt_dataset.input_record_bytes -ne 8 -or $balancedNumericJson.kt_dataset.output_record_bytes -ne 16 -or $balancedNumericJson.model_history.records -ne 11267 -or $balancedNumericJson.model_history.histories -ne 7 -or $balancedNumericJson.model_history.classes -ne 7 -or $balancedNumericJson.model_history.levels -ne 17 -or $balancedNumericJson.model_history.layout.prediction_bytes -ne 544 -or $balancedNumericJson.model_history.layout.node_bytes -ne 16 -or @($balancedNumericJson.checks|Where-Object {-not $_.passed}).Count -ne 0){throw 'Balanced KT CURRENT numeric proof incomplete.'}
    $balancedFullProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/report.json') 'balanced-kt-full-proof'
    if($balancedFullProof.before_sha256 -cne 'AB486DC5C8CE3DAE36B1A91EACCE1BE77F7084F52122B26C3EC6A629C59A06F4'){throw 'Balanced KT full proof identity mismatch.'}
    $balancedFullJson=Get-Content -LiteralPath $balancedFullProof.path -Raw|ConvertFrom-Json
    if($balancedFullJson.status -cne 'correctness_and_size_passed_not_timed' -or @($balancedFullJson.checks).Count -ne 87 -or @($balancedFullJson.invocations).Count -ne 178 -or @($balancedFullJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($balancedFullJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0 -or $balancedFullJson.timing_used -or -not $balancedFullJson.fixed_size_gate_passed -or $balancedFullJson.fixed_candidate.bytes -ne 483469 -or $balancedFullJson.fixed_candidate.sha256 -cne $fullJson.fixed_candidate.sha256 -or $balancedFullJson.inherited_mixture_checks -ne 79 -or $balancedFullJson.additional_mixture_cross_checks -ne 8 -or $balancedFullJson.owned_tmp_count -ne 0){throw 'Balanced KT full proof incomplete.'}
    foreach($oldCheck in $mixtureFullJson.checks){
        if(@($balancedFullJson.checks|Where-Object {$_.name -ceq $oldCheck.name -and $_.passed}).Count -ne 1){throw "Missing inherited mixture check: $($oldCheck.name)"}
    }
    $balancedBuildProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/build-report.json') 'balanced-kt-build-proof'
    if($balancedBuildProof.before_sha256 -cne 'FA92C276E742BD1A48038A7C11FD56CF47016E6FF5F67235964633A13060A1A2'){throw 'Balanced KT build proof identity mismatch.'}
    $balancedBuildJson=Get-Content -LiteralPath $balancedBuildProof.path -Raw|ConvertFrom-Json
    if($balancedBuildJson.status -cne 'built_not_timed' -or $balancedBuildJson.timing_used -or @($balancedBuildJson.compile_calls).Count -ne 2 -or @($balancedBuildJson.compile_calls|Where-Object {$_.timeout -or $_.exit -ne 0 -or $_.stderr}).Count -ne 0){throw 'Balanced KT build proof incomplete.'}
    $report['balanced_kt_proofs']=[ordered]@{full=$balancedFullProof;build=$balancedBuildProof;numeric_current=$balancedNumericProof}

    $nativeNumericProof=Track-File (Join-Path $root 'build/khc-native32-quotient-numeric-20261001/report.json') 'native32-current-numeric-proof'
    if($nativeNumericProof.before_sha256 -cne 'DF1FCBAA5884D8DB2B7234F5DF7A0356C1C3A5D198204929DEDB1F9C836EE656'){throw 'Native32 numeric proof identity mismatch.'}
    $nativeNumericJson=Get-Content -LiteralPath $nativeNumericProof.path -Raw|ConvertFrom-Json
    if($nativeNumericJson.status -cne 'verified_numeric_not_timed' -or $nativeNumericJson.timing_used -or $nativeNumericJson.checks.Count -ne 46 -or $nativeNumericJson.invocations.Count -ne 49 -or $nativeNumericJson.identities.Count -ne 49 -or $nativeNumericJson.dataset.records -ne 65536 -or $nativeNumericJson.legacy.records -ne 56191 -or $nativeNumericJson.owned_tmp_count -ne 0 -or $nativeNumericJson.owned_reparse_count -ne 0 -or @($nativeNumericJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($nativeNumericJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Native32 numeric proof incomplete.'}
    $nativeModelProof=Track-File (Join-Path $root 'build/khc-q32-native32-model-20261001-inherited-format/report.json') 'native32-current-Model-proof'
    if($nativeModelProof.before_sha256 -cne '89C9D6773D95A281C01437BB4653DE50B4716638A2F597AD13467B2CFA347B58'){throw 'Native32 Model proof identity mismatch.'}
    $nativeModelJson=Get-Content -LiteralPath $nativeModelProof.path -Raw|ConvertFrom-Json
    if($nativeModelJson.status -cne 'verified_model_not_timed' -or $nativeModelJson.timing_used -or $nativeModelJson.checks.Count -ne 57 -or $nativeModelJson.invocations.Count -ne 54 -or $nativeModelJson.identities.Count -ne 95 -or $nativeModelJson.model_history.records -ne 11267 -or $nativeModelJson.model_history.layout.prediction_bytes -ne 544 -or $nativeModelJson.model_history.layout.node_bytes -ne 16 -or $nativeModelJson.owned_tmp_count -ne 0 -or $nativeModelJson.owned_reparse_count -ne 0 -or @($nativeModelJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($nativeModelJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Native32 Model proof incomplete.'}
    $nativeCodecProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-native32-20261001/report.json') 'native32-current-codec-proof'
    if($nativeCodecProof.before_sha256 -cne '78F3D20CCD1764A94AC237976D96BE4CA8095935E136C4D13738E3F4BD2708C0'){throw 'Native32 codec proof identity mismatch.'}
    $nativeCodecJson=Get-Content -LiteralPath $nativeCodecProof.path -Raw|ConvertFrom-Json
    if($nativeCodecJson.status -cne 'correctness_and_size_passed_not_timed' -or $nativeCodecJson.timing_used -or $nativeCodecJson.checks.Count -ne 34 -or $nativeCodecJson.invocations.Count -ne 57 -or $nativeCodecJson.identities.Count -ne 75 -or $nativeCodecJson.fixed_frames.Count -ne 2 -or $nativeCodecJson.owned_tmp_count -ne 0 -or $nativeCodecJson.owned_reparse_count -ne 0 -or @($nativeCodecJson.fixed_frames|Where-Object {$_.bytes -ne 483469 -or $_.sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'}).Count -ne 0 -or @($nativeCodecJson.checks|Where-Object {-not $_.passed}).Count -ne 0 -or @($nativeCodecJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count -ne 0){throw 'Native32 codec proof incomplete.'}
    if(@($nativeCodecJson.identities|Where-Object {$_.role -ceq 'compiled-codec' -and $_.path -ceq (Join-Path $root 'build/khc-bwt-causal-bayes-q32-native32-20261001/codec-native.exe') -and $_.before_sha256 -ceq '44CF635A18CF73E14E968A63C5A0EC4534FE47A4E277D7F818C32E1EEDE740C3' -and $_.before_bytes -eq 216576}).Count -ne 1){throw 'Frozen native32 binary not bound to codec E2E proof.'}
    $report['native32_proofs']=[ordered]@{numeric_current=$nativeNumericProof;model_current=$nativeModelProof;codec=$nativeCodecProof}
    $report['prior_gate_checks_scope']='Old complete correctness proofs are retained and traced unchanged; new codec proof is focused 34-check E2E, not a new independent 87-check audit.'

    $reciprocalNumericProof=Track-File (Join-Path $root 'build/khc-kt-reciprocal-numeric-20261001/report.json') 'reciprocal-numeric-proof'
    if($reciprocalNumericProof.before_sha256 -cne '9E6CE54D564C602CBAD6ACADFDF67D9AB0D2444B7C4791AC5383CDEAB63BBF93'){throw 'Reciprocal numeric proof identity mismatch.'}
    $reciprocalNumericJson=Get-Content -LiteralPath $reciprocalNumericProof.path -Raw|ConvertFrom-Json
    if($reciprocalNumericJson.status -cne 'verified_KT_reciprocal_numeric_not_timed' -or $reciprocalNumericJson.timing_used -or $reciprocalNumericJson.checks.Count -ne 36 -or $reciprocalNumericJson.invocations.Count -ne 42 -or $reciprocalNumericJson.identities.Count -ne 54){throw 'Reciprocal numeric proof incomplete.'}
    $reciprocalModelProof=Track-File (Join-Path $root 'build/khc-q32-kt-reciprocal-model-20261001/report.json') 'reciprocal-Model-proof'
    if($reciprocalModelProof.before_sha256 -cne '4D06E360637DCB16F8422EA149295B3F5B23B7D067B70638885DA8172A679B84'){throw 'Reciprocal Model proof identity mismatch.'}
    $reciprocalModelJson=Get-Content -LiteralPath $reciprocalModelProof.path -Raw|ConvertFrom-Json
    if($reciprocalModelJson.status -cne 'verified_model_not_timed' -or $reciprocalModelJson.timing_used -or $reciprocalModelJson.checks.Count -ne 62 -or $reciprocalModelJson.invocations.Count -ne 59 -or $reciprocalModelJson.identities.Count -ne 107 -or $reciprocalModelJson.model_history.records -ne 11267 -or $reciprocalModelJson.model_history.layout.prediction_bytes -ne 544 -or $reciprocalModelJson.model_history.layout.node_bytes -ne 16 -or $reciprocalModelJson.table_storage_bytes -ne 524296){throw 'Reciprocal Model proof incomplete.'}
    $reciprocalCodecProof=Track-File (Join-Path $root 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/report.json') 'reciprocal-codec-proof'
    if($reciprocalCodecProof.before_sha256 -cne '010C42392454709F7EE7FD69B25150579D880B1A773BC9CC32B6430CB45E419A'){throw 'Reciprocal codec proof identity mismatch.'}
    $reciprocalCodecJson=Get-Content -LiteralPath $reciprocalCodecProof.path -Raw|ConvertFrom-Json
    if($reciprocalCodecJson.status -cne 'correctness_and_size_passed_not_timed' -or $reciprocalCodecJson.timing_used -or $reciprocalCodecJson.checks.Count -ne 34 -or $reciprocalCodecJson.invocations.Count -ne 57 -or $reciprocalCodecJson.identities.Count -ne 81 -or $reciprocalCodecJson.fixed_frames.Count -ne 2 -or @($reciprocalCodecJson.fixed_frames|Where-Object {$_.bytes -ne 483469 -or $_.sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'}).Count){throw 'Reciprocal codec proof incomplete.'}
    foreach($proof in @($reciprocalNumericJson,$reciprocalModelJson,$reciprocalCodecJson)){
        if($proof.owned_tmp_count -ne 0 -or $proof.owned_reparse_count -ne 0 -or @($proof.checks|Where-Object {-not $_.passed}).Count -or @($proof.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count){throw 'Reciprocal proof cleanup/check/invocation failure.'}
    }
    if(@($reciprocalCodecJson.identities|Where-Object {$_.role -ceq 'compiled-codec' -and $_.path -ceq (Join-Path $root 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001/codec-native.exe') -and $_.before_sha256 -ceq '74704D097CC6D70E531086DE73A3311716E1C3F96CEB62F6A5794067331B99FE' -and $_.before_bytes -eq 218112}).Count -ne 1){throw 'Frozen reciprocal binary not bound to reciprocal codec E2E proof.'}
    $report['reciprocal_proofs']=[ordered]@{numeric=$reciprocalNumericProof;model=$reciprocalModelProof;codec=$reciprocalCodecProof}

    $schedulerProof=Track-File (Join-Path $root 'build/khc-causal-expert-scheduling-20261001/report.json') 'causal-scheduler-codec-proof'
    if($schedulerProof.before_sha256 -cne '370534F32A979FE2768CD60C29DFBD8342CD7B358C15C4D510945B8F8DD35E7A'){throw 'Scheduler proof identity mismatch.'}
    $schedulerJson=Get-Content -LiteralPath $schedulerProof.path -Raw|ConvertFrom-Json
    if($schedulerJson.status -cne 'correctness_and_size_passed_not_timed' -or $schedulerJson.timing_used -or $schedulerJson.checks.Count -ne 50 -or $schedulerJson.invocations.Count -ne 63 -or $schedulerJson.identities.Count -ne 83 -or $schedulerJson.owned_tmp_count -ne 0 -or $schedulerJson.owned_reparse_count -ne 0 -or @($schedulerJson.checks|Where-Object {-not $_.passed}).Count -or @($schedulerJson.invocations|Where-Object {$_.timeout -or $_.exit -ne $_.expected_exit}).Count){throw 'Scheduler codec proof incomplete.'}
    if(-not $schedulerJson.size_result.passed -or $schedulerJson.size_result.timing_used -or $schedulerJson.size_result.maximum_archive_bytes -ne 483599 -or $schedulerJson.size_result.candidate.bytes -ne 483496 -or $schedulerJson.size_result.candidate.sha256 -cne 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'){throw 'Scheduler complete frame proof mismatch.'}
    $oldSchedulerBinary=Join-Path $root 'build/khc-causal-expert-scheduling-20261001/codec-native.exe'
    if(@($schedulerJson.identities|Where-Object {$_.role -ceq 'compiled-codec' -and $_.path -ceq $oldSchedulerBinary -and $_.before_sha256 -ceq '0737E2FFD936ECD89EA2FD4F8907AC0CD6C0766072BCE56CBB65AABDA7C981EA' -and $_.before_bytes -eq 236544}).Count -ne 1){throw 'Old scheduler binary not bound to old E2E proof.'}
    $schedule=$schedulerJson.fixed_schedule
    if($schedule.maximum_records -ne 8388608 -or $schedule.peak_reserved_records -gt $schedule.maximum_records -or $schedule.reserved_records -gt $schedule.peak_reserved_records -or ($schedule.events|Measure-Object -Sum).Sum -ne 7622618 -or ($schedule.processed|Measure-Object -Sum).Sum -ne 3223156 -or ($schedule.replayed|Measure-Object -Sum).Sum -ne 434286){throw 'Scheduler normal history evidence mismatch.'}
    for($class=0;$class -lt 7;$class++){
        if($schedule.processed[$class]+$schedule.pending[$class] -ne $schedule.events[$class] -or $schedule.replayed[$class]+$schedule.active_events[$class] -ne $schedule.processed[$class] -or $schedule.reference_checks[$class] -ne 0){throw 'Scheduler normal event invariant mismatch.'}
        if($schedulerJson.small_journal_schedule.reference_checks[$class] -ne $schedulerJson.small_journal_schedule.active_events[$class]){throw 'Small journal reference evidence mismatch.'}
    }
    if($schedulerJson.small_journal_schedule.maximum_records -ne 64 -or ($schedulerJson.small_journal_schedule.forced|Measure-Object -Sum).Sum -le 0){throw 'Small journal forced catch-up evidence missing.'}
    $report['scheduler_proof']=$schedulerProof
    $report['scheduler_scope']='50 checks/63 CLI; native/portable/finite Q15 continuous reference; small-journal forced replay; representative malformed/no-clobber. Not a full internal-state oracle, new normal over-cap fixture, four-native or product proof.'
    $integerProof=Track-File (Join-Path $root 'build/khc-causal-integer-refinement-20261002-comparison-repair/report.json') 'integer-codec-proof'
    if($integerProof.before_sha256 -cne 'B7BE539DB0DA5786EAAA1BC7F4E43DC983A4495F21E6B2E80BADD999407D459D'){throw 'Integer codec proof SHA'}
    $integerJson=Get-Content -LiteralPath $integerProof.path -Raw|ConvertFrom-Json
    if($integerJson.status -cne 'correctness_and_size_passed_not_timed' -or $integerJson.failure -or $integerJson.timing_used -or $integerJson.checks.Count -ne 32 -or $integerJson.invocations.Count -ne 53 -or $integerJson.identities.Count -ne 141 -or $integerJson.owned_tmp_or_reparse -ne 0 -or $integerJson.frame_bytes -ne 483496){throw 'Integer codec proof incomplete'}
    $ordinary=@($integerJson.identities|Where-Object {$_.role -ceq 'native-codec' -and $_.path -ceq (Join-Path $root 'build/khc-causal-integer-refinement-20261002-comparison-repair/codec-native.exe') -and $_.before_sha256 -ceq 'AD2D1D930F27FA73B70F1E096BBEDC35301244B0A2FA3130F689680430184A26' -and $_.bytes -eq 238080})
    if($ordinary.Count -ne 1){throw 'Candidate not the integer ordinary codec'}
    $failedCalls=@($integerJson.invocations|Where-Object exit -ne 0)
    if($failedCalls.Count -ne 8 -or @($failedCalls|Where-Object {$_.exit -ne 1 -or !$_.stderr -or $_.stdout}).Count){throw 'Integer expected refusal records mismatch'}
    $integerNumericProof=Track-File (Join-Path $root 'build/khc-integer-refinement-narrow-20261002/report.json') 'integer-narrow-numeric-proof'
    $integerWideProof=Track-File (Join-Path $root 'build/khc-integer-refinement-20261002/report.json') 'integer-wide-numeric-proof'
    if($integerNumericProof.before_sha256 -cne 'AB03ECAD9DC5BD8109792C85B6D4F94433064AC375A38A0975E4FD567B6DB68C' -or $integerWideProof.before_sha256 -cne 'A956525D2234A000353B8E33E54BEB6B48C366A8CD64FF6F23E7B439B96EEFE2'){throw 'Integer numeric proof SHA'}
    $integerNumericJson=Get-Content -LiteralPath $integerNumericProof.path -Raw|ConvertFrom-Json
    $integerWideJson=Get-Content -LiteralPath $integerWideProof.path -Raw|ConvertFrom-Json
    foreach($numericDocument in @($integerNumericJson,$integerWideJson)){
        if($numericDocument.status -cne 'numeric_verified_not_codec_or_timing' -or $numericDocument.failure -or $numericDocument.numeric.records -ne 9293629 -or $numericDocument.numeric.certificate_fallback -ne 0 -or $numericDocument.numeric.table_bytes -ne 262144 -or $numericDocument.numeric.fingerprint_u64 -cne '51b49b146351fbd2' -or $numericDocument.invocations.Count -ne 23){throw 'Integer numeric coverage mismatch'}
        foreach($call in $numericDocument.invocations){
            $expectedExit=if($call.argv.Count -eq 0 -or ($call.argv.Count -gt 1 -and $call.argv[0] -ceq 'query' -and $call.argv[1] -ceq '-1')){2}else{0}
            if($call.exit -ne $expectedExit -or ($expectedExit -eq 0 -and $call.stderr) -or ($expectedExit -ne 0 -and $call.stdout)){throw 'Integer numeric invocation failure'}
        }
    }
    if(($integerNumericJson.numeric|ConvertTo-Json -Compress) -cne ($integerWideJson.numeric|ConvertTo-Json -Compress)){throw 'Wide/narrow summary mismatch'}
    $report['integer_proofs']=[ordered]@{codec=$integerProof;narrow=$integerNumericProof;wide=$integerWideProof}
    $dominantProof=Track-File (Join-Path $root 'build/khc-bayes-dominant-q15-20261002-codec/report.json') 'dominant-codec-proof'
    if($dominantProof.before_sha256 -cne '0776392ED95FEE12D1F47FF6CE06C409B7A6DEC6A086AAC131234335EC834360'){throw 'Dominant codec proof SHA'}
    $dominantJson=Get-Content -LiteralPath $dominantProof.path -Raw|ConvertFrom-Json
    if($dominantJson.status -cne 'correctness_and_size_passed_not_timed' -or $dominantJson.failure -or $dominantJson.timing_used -or $dominantJson.checks.Count -ne 32 -or $dominantJson.invocations.Count -ne 53 -or $dominantJson.identities.Count -ne 218 -or $dominantJson.owned_tmp_or_reparse -ne 0 -or $dominantJson.frame_bytes -ne 483496){throw 'Dominant codec proof incomplete'}
    $dominantOrdinary=@($dominantJson.identities|Where-Object {$_.role -ceq 'native-codec' -and $_.path -ceq $candidate.path -and $_.before_sha256 -ceq $candidate.before_sha256 -and $_.bytes -eq 238080})
    if($dominantOrdinary.Count -ne 1){throw 'Candidate not the dominant ordinary codec'}
    $dominantRefusals=@($dominantJson.invocations|Where-Object exit -ne 0)
    if($dominantRefusals.Count -ne 8 -or @($dominantRefusals|Where-Object {$_.exit -ne 1 -or !$_.stderr -or $_.stdout}).Count -or @($dominantJson.invocations|Where-Object {$_.exit -eq 0 -and $_.stderr}).Count){throw 'Dominant codec invocation mismatch'}
    $dominantNumericProof=Track-File (Join-Path $root 'build/khc-bayes-dominant-q15-20261002-numeric/report.json') 'dominant-numeric-proof'
    if($dominantNumericProof.before_sha256 -cne 'CD285519F0EB1A74A5DBA01CDD26AFD484471586A6555537E3A7051FB69A5C51'){throw 'Dominant numeric proof SHA'}
    $dominantNumericJson=Get-Content -LiteralPath $dominantNumericProof.path -Raw|ConvertFrom-Json
    if($dominantNumericJson.status -cne 'numeric_native_equivalence_passed_not_timed' -or $dominantNumericJson.failure -or $dominantNumericJson.timing_used -or $dominantNumericJson.checks.Count -ne 6 -or $dominantNumericJson.invocations.Count -ne 7 -or $dominantNumericJson.identities.Count -ne 19 -or $dominantNumericJson.owned_tmp_or_reparse -ne 0){throw 'Dominant numeric proof incomplete'}
    foreach($call in $dominantNumericJson.invocations){
        $expectedExit=if($call.argv.Count -eq 1 -and $call.argv[0] -ceq 'unexpected'){2}else{0}
        if($call.exit -ne $expectedExit -or ($expectedExit -eq 0 -and $call.stderr) -or ($expectedExit -ne 0 -and $call.stdout)){throw 'Dominant numeric invocation failure'}
    }
    $dominantSummaries=@($dominantNumericJson.invocations|Where-Object {$_.argv.Count -eq 0})
    if($dominantSummaries.Count -ne 2 -or $dominantSummaries[0].stdout -cne $dominantSummaries[1].stdout){throw 'Dominant optimization summary mismatch'}
    $dominantCounts=$dominantSummaries[0].stdout|ConvertFrom-Json
    if($dominantCounts.records -ne 5920979 -or $dominantCounts.equal_component -ne 491915 -or $dominantCounts.primary_dominant -ne 2151943 -or $dominantCounts.cts_dominant -ne 2152672 -or $dominantCounts.unchanged_path -ne 1124449 -or $dominantCounts.errors -ne 4361 -or $dominantCounts.fingerprint_fnv64 -cne '529ee7291004574b'){throw 'Dominant numeric coverage mismatch'}
    $report['dominant_proofs']=[ordered]@{codec=$dominantProof;numeric=$dominantNumericProof}

    $report['historical_budget_guard_repairs']=[Collections.Generic.List[object]]::new()
    $proofFiles=@{}
    foreach($proofDocument in @($fullJson,$numericJson,$bwtJson,$candidateFullJson,$quotientJson,$buildJson,$lutFullJson,$lutBuildJson,$inlineFullJson,$inlineBuildJson,$splitNumericJson,$splitFullJson,$splitBuildJson,$mixtureNumericJson,$mixtureFullJson,$mixtureBuildJson,$balancedNumericJson,$balancedFullJson,$balancedBuildJson,$nativeNumericJson,$nativeModelJson,$nativeCodecJson,$reciprocalNumericJson,$reciprocalModelJson,$reciprocalCodecJson,$schedulerJson,$integerJson,$integerNumericJson,$integerWideJson,$dominantJson,$dominantNumericJson)) {
        $proofStack=[Collections.Generic.Stack[object]]::new()
        $proofStack.Push($proofDocument)
        while($proofStack.Count -gt 0) {
            $proofNode=$proofStack.Pop()
            if($proofNode -is [pscustomobject]) {
                $propertyNames=@($proofNode.PSObject.Properties.Name)
                if($propertyNames -contains 'path' -and ($propertyNames -contains 'before_sha256' -or $propertyNames -contains 'sha256')) {
                    $proofPath=[IO.Path]::GetFullPath([string]$proofNode.path)
                    if(-not $proofFiles.ContainsKey($proofPath)){$proofFiles[$proofPath]=Track-File $proofPath 'proof-provenance-or-output'}
                    $current=$proofFiles[$proofPath]
                    if($propertyNames -contains 'before_sha256') {
                        $historicalGuard=([object]::ReferenceEquals($proofDocument,$integerNumericJson) -or [object]::ReferenceEquals($proofDocument,$integerWideJson)) -and $proofPath.Equals([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1')),[StringComparison]::OrdinalIgnoreCase)
                        if($historicalGuard){
                            if($proofNode.role -cne 'budget-guard' -or $proofNode.before_sha256 -cne '379BFC1CCE693FCADD75AD6D8C375FEA2F10151EBA4B63D8462ADA91C2051BBF' -or $proofNode.after_sha256 -cne $proofNode.before_sha256 -or $proofNode.bytes -ne 1997 -or $current.before_sha256 -cne 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7' -or $current.before_bytes -ne 2054){throw 'Historical guard repair identity mismatch'}
                            $report.historical_budget_guard_repairs.Add([pscustomobject]@{owner=$(if([object]::ReferenceEquals($proofDocument,$integerNumericJson)){'narrow'}else{'wide'});path=$proofPath;historical_sha256=$proofNode.before_sha256;current_sha256=$current.before_sha256;reason='StrictMode empty-directory fix; math and gates unchanged'})
                        } else {
                            if($current.before_sha256 -cne $proofNode.before_sha256 -or $proofNode.before_sha256 -cne $proofNode.after_sha256){throw "Proof provenance SHA mismatch: $proofPath"}
                            if($propertyNames -contains 'before_bytes' -and ($current.before_bytes -ne $proofNode.before_bytes -or $proofNode.before_bytes -ne $proofNode.after_bytes)){throw "Proof provenance length mismatch: $proofPath"}
                            if($propertyNames -contains 'bytes' -and $current.before_bytes -ne $proofNode.bytes){throw "Proof identity byte length mismatch: $proofPath"}
                        }
                    } else {
                        if($current.before_sha256 -cne $proofNode.sha256 -or $current.before_bytes -ne $proofNode.bytes){throw "Proof input/output evidence mismatch: $proofPath"}
                    }
                }
                foreach($property in $proofNode.PSObject.Properties){if($null -ne $property.Value){$proofStack.Push($property.Value)}}
            } elseif($proofNode -is [array]) {
                foreach($proofChild in $proofNode){if($null -ne $proofChild){$proofStack.Push($proofChild)}}
            }
        }
    }
    $report['proof_evidence_file_count']=$proofFiles.Count
    if($report.historical_budget_guard_repairs.Count -ne 2){throw 'Expected exactly two repaired historical guard references'}
    if ($candidate.before_sha256 -cne $candidateExpectedHash) { throw 'Candidate binary identity mismatch.' }
    if ($seven.before_bytes -ne 1335296 -or $seven.before_sha256 -cne $sevenExpectedHash) { throw 'Baseline 7za binary identity mismatch.' }
    if ($groupSource.before_bytes -ne $fixedBytes -or $groupSource.before_sha256 -cne $fixedHash) { throw 'Fixed group length or SHA-256 mismatch.' }
    $collections = @(Get-Content -LiteralPath $manifest.path -Raw | ConvertFrom-Json | Where-Object { $_.name -ceq 'canterbury-development' -and $_.role -ceq 'development' })
    if ($collections.Count -ne 1 -or @($collections[0].files).Count -ne 11) { throw 'Expected fixed 11-entry development manifest.' }
    $entries = @($collections[0].files)
    $names = [string[]]@($entries | ForEach-Object { $_.name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt 11; $i++) {
        if ($names[$i] -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or ($i -gt 0 -and $names[$i] -ceq $names[$i - 1])) { throw 'Invalid or duplicate manifest basename.' }
    }
    $bytes = [IO.File]::ReadAllBytes($groupSource.path)
    if ($bytes.Length -ne $fixedBytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) -cne $fixedHash) { throw 'Group changed while reading.' }
    $stream = [IO.MemoryStream]::new($bytes, $false)
    $reader = [IO.BinaryReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false)
    $metadata = [Collections.Generic.List[object]]::new()
    try {
        if ([Convert]::ToHexString($reader.ReadBytes(8)) -cne '4B48534752503000' -or $reader.ReadUInt32() -ne 11 -or $reader.ReadUInt32() -ne 0) { throw 'Invalid KHSGRP0 header.' }
        for ($i = 0; $i -lt 11; $i++) {
            $length = $reader.ReadUInt16()
            $size = $reader.ReadUInt64()
            if ($length -lt 1 -or $length -gt 255 -or $size -gt 64MB) { throw 'Invalid group metadata length.' }
            $nameBytes = $reader.ReadBytes($length)
            if ($nameBytes.Length -ne $length) { throw 'Truncated group name.' }
            $name = [Text.UTF8Encoding]::new($false, $true).GetString($nameBytes)
            $expected = @($entries | Where-Object { $_.name -ceq $names[$i] })
            if ($expected.Count -ne 1 -or $name -cne $names[$i] -or $size -ne [long]$expected[0].bytes -or [string]$expected[0].sha256 -cnotmatch '^[0-9A-F]{64}$') { throw "Group/manifest metadata mismatch: $i" }
            $metadata.Add([pscustomobject]@{ name = $name; bytes = [long]$size; sha256 = [string]$expected[0].sha256 })
        }
        $native = Join-Path $work 'native-input'
        $null = New-Item -ItemType Directory -Path $native
        foreach ($entry in $metadata) {
            $body = $reader.ReadBytes([int]$entry.bytes)
            if ($body.Length -ne $entry.bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($body)) -cne $entry.sha256) { throw "Group body mismatch: $($entry.name)" }
            $path = Join-Path $native $entry.name
            Write-NewBytes $path $body
            $snapshotIdentity = Track-File $path 'native-snapshot'
            if ($snapshotIdentity.before_bytes -ne $entry.bytes -or $snapshotIdentity.before_sha256 -cne $entry.sha256) { throw 'Native snapshot verification failed.' }
            $snapshots.Add([pscustomobject]@{ name = $entry.name; bytes = $entry.bytes; sha256 = $entry.sha256; path = $path })
        }
        if ($stream.Position -ne $stream.Length) { throw 'Trailing group bytes.' }
    } finally { $reader.Dispose() }
    $group = Join-Path $work 'all.group'
    Write-NewBytes $group $bytes
    $groupIdentity = Track-File $group 'group-snapshot'
    if ($groupIdentity.before_bytes -ne $fixedBytes -or $groupIdentity.before_sha256 -cne $fixedHash) { throw 'Group snapshot verification failed.' }
    $report.environment['rustc_version'] = @(& 'C:/Users/IMT/.cargo/bin/rustc.exe' +1.98.1 --version --verbose)
    $null = Invoke-Recorded $seven.path @('i') 'version' '7zip' -1 -1 $work
    $firstHashes = @{}
    $firstDecodeVerified = @{}
    $codecs = @('q15-dominant-shortcut-group', 'q32-balanced-kt-control', '7zip-native')
    $sevenOptions = @('-t7z', '-mx=9', '-m0=LZMA2:d=64m', '-mmt=1', '-ms=on', '-mqs=off', '-mtm=off', '-mta=off', '-mtc=off')
    for ($round = 0; $round -le 9; $round++) {
        # warm-upと測定9回を同じセッションで回し、測定は各codecが先頭に3回ずつ来る。
        for ($order = 0; $order -lt 3; $order++) {
            $codec = $codecs[($round + $order) % 3]
            $extension = if ($codec -cne '7zip-native') { 'bayes' } else { '7z' }
            $archive = Join-Path $work "$codec-$round.$extension"
            if ($codec -ceq 'q15-dominant-shortcut-group') {
                $encoding = Invoke-Recorded $candidate.path @('encode', $group, $archive) 'encode' $codec $round $order $work $archive
            } elseif ($codec -ceq 'q32-balanced-kt-control') {
                $encoding = Invoke-Recorded $control.path @('encode', $group, $archive) 'encode' $codec $round $order $work $archive
            } else {
                $encoding = Invoke-Recorded $seven.path (@('a', $archive) + $sevenOptions + $names) 'encode' $codec $round $order $native $archive
            }
            if ($codec -ceq 'q15-dominant-shortcut-group' -and ($encoding.output_bytes -ne $schedulerJson.size_result.candidate.bytes -or $encoding.output_sha256 -cne $schedulerJson.size_result.candidate.sha256)) { throw 'Candidate is not the E2E-verified complete scheduled frame.' }
            if ($codec -ceq 'q32-balanced-kt-control' -and ($encoding.output_bytes -ne 483469 -or $encoding.output_sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C')) { throw 'Control is not the frozen complete Q32 frame.' }
            if ($firstHashes.ContainsKey($codec)) {
                if ($firstHashes[$codec] -cne $encoding.output_sha256) { throw "Nondeterministic archive: $codec round $round" }
            } else { $firstHashes[$codec] = $encoding.output_sha256 }
            $sample = [ordered]@{ codec = $codec; round = $round; warmup = ($round -eq 0); order = $order; archive_bytes = $encoding.output_bytes; archive_sha256 = $encoding.output_sha256; encode_ms = $encoding.wall_ms; decode_verified = $false; decode_verification = $null; decode_ms = $null }
            $samples.Add($sample)
            # 中間runは直接復号済み初回書庫との完全同一SHAで検証する。
            if ($round -ne 0 -and $round -ne 9) {
                if (-not $firstDecodeVerified.ContainsKey($codec) -or -not $firstDecodeVerified[$codec]) { throw 'Cannot infer decode verification before the first direct decode succeeds.' }
                $sample.decode_verified = $true
                $sample.decode_verification = 'identical_archive_to_verified_first_run'
                continue
            }
            # 初回/最終だけ復号コピーを保持し、native SLTも同じ境界で照合する。
            $decoded = Join-Path $work "$codec-$round-decoded"
            $null = New-Item -ItemType Directory -Path $decoded
            if ($codec -cne '7zip-native') {
                $restore = Join-Path $decoded 'all.group'
                $decodeProgram = if ($codec -ceq 'q15-dominant-shortcut-group') { $candidate.path } else { $control.path }
                $decoding = Invoke-Recorded $decodeProgram @('decode', $archive, $restore) 'decode' $codec $round $order $work $restore
            } else {
                $decoding = Invoke-Recorded $seven.path @('x', $archive, "-o$decoded", '-y', '-mmt=1') 'decode' $codec $round $order $work
            }
            $files = @(Get-ChildItem -LiteralPath $decoded -Force -Recurse)
            $expectedEntries = if ($codec -ceq '7zip-native') { @($snapshots.ToArray()) } else { @([pscustomobject]@{ name = 'all.group'; bytes = $fixedBytes; sha256 = $fixedHash }) }
            if ($files.Count -ne $expectedEntries.Count) { throw "Decoded entry count mismatch: $codec" }
            foreach ($entry in $expectedEntries) {
                $identity = Get-FileIdentity (Join-Path $decoded $entry.name)
                if ($identity.bytes -ne $entry.bytes -or $identity.sha256 -cne $entry.sha256) { throw "Decoded file/hash mismatch: $codec/$($entry.name)" }
            }
            if ($codec -ceq '7zip-native') {
                $listing = Invoke-Recorded $seven.path @('l', '-slt', $archive) 'metadata' $codec $round $order $work
                Assert-NativeListing $listing.stdout
            }
            $sample.decode_verified = $true
            $sample.decode_verification = 'direct_decode_and_hash'
            $sample.decode_ms = $decoding.wall_ms
            if ($round -eq 0) { $firstDecodeVerified[$codec] = $true }
        }
    }
    $summaries = @{}
    foreach ($codec in $codecs) {
        $rows = @($samples | Where-Object { $_.codec -ceq $codec -and -not $_.warmup })
        if ($rows.Count -ne 9) { throw 'Expected nine measured runs per codec.' }
        $median = Get-Median ([double[]]@($rows | ForEach-Object { $_.encode_ms }))
        $measuredInvocations = @($runs | Where-Object { $_.codec -ceq $codec -and $_.kind -ceq 'encode' -and $_.round -gt 0 })
        if ($measuredInvocations.Count -ne 9) { throw 'Missing measured encode invocations.' }
        $summaries[$codec] = [ordered]@{
            archive_bytes = $rows[0].archive_bytes
            encode_median_ms = $median
            encode_cpu_median_ms = Get-Median ([double[]]@($measuredInvocations | ForEach-Object { $_.cpu_ms }))
            peak_working_median_bytes = Get-Median ([double[]]@($measuredInvocations | ForEach-Object { $_.peak_working_bytes }))
            peak_private_sampled_median_bytes = Get-Median ([double[]]@($measuredInvocations | ForEach-Object { $_.peak_private_sampled_bytes }))
            fixed_size_threshold_passed = ($rows[0].archive_bytes -le 483599)
            fixed_wall_threshold_passed = ($median -lt 574.5624)
            fixed_size_and_wall_thresholds_passed = ($rows[0].archive_bytes -le 483599 -and $median -lt 574.5624)
            single_thread_evidence = 'configured_and_sampled_not_lifetime_verified'
        }
    }
    $ratios = @($samples | Where-Object { $_.codec -ceq 'q15-dominant-shortcut-group' -and -not $_.warmup } | ForEach-Object {
        $candidateRow = $_
        $sevenRow = @($samples | Where-Object { $_.round -eq $candidateRow.round -and $_.codec -ceq 'q32-balanced-kt-control' })[0]
        $nativeRow = @($samples | Where-Object { $_.round -eq $candidateRow.round -and $_.codec -ceq '7zip-native' })[0]
        [pscustomobject]@{
            round = $candidateRow.round
            candidate_to_frozen_control_encode_ratio = $candidateRow.encode_ms / $sevenRow.encode_ms
            candidate_to_frozen_control_size_ratio = $candidateRow.archive_bytes / $sevenRow.archive_bytes
            candidate_group_to_7zip_native_encode_ratio = $candidateRow.encode_ms / $nativeRow.encode_ms
            candidate_group_to_7zip_native_size_ratio = $candidateRow.archive_bytes / $nativeRow.archive_bytes
        }
    })
    $report.paired_comparison = [ordered]@{
        summaries = $summaries
        per_round_ratios = $ratios
        control_paired_encode_ratio_median = Get-Median ([double[]]@($ratios | ForEach-Object { $_.candidate_to_frozen_control_encode_ratio }))
        native_paired_encode_ratio_median = Get-Median ([double[]]@($ratios | ForEach-Object { $_.candidate_group_to_7zip_native_encode_ratio }))
        decision_boundary = 'encode wall time and total archive bytes only; native representation differs; research prototype, not product adoption'
    }
    $report.status = 'success'
    $report['disk_budget_after'] = & (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 128
} catch {
    $failure = $_
    $report.error = $_.Exception.Message
} finally {
    foreach ($file in $tracked) {
        try {
            $after = Get-FileIdentity $file.path
            $file.after_bytes = $after.bytes; $file.after_sha256 = $after.sha256
            if ($file.before_bytes -ne $after.bytes -or $file.before_sha256 -cne $after.sha256) { throw "Tracked file changed: $($file.path)" }
        } catch {
            $report.status = 'failed'
            $report.error = (@($report.error, $_.Exception.Message) | Where-Object { $_ }) -join '; '
            if ($null -eq $failure) { $failure = $_ }
        }
    }
    $report['completed_utc'] = [DateTime]::UtcNow.ToString('o')
    try { $report['disk_budget_final'] = & (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 128 } catch { $report.status='failed'; $report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; '; if($null -eq $failure){$failure=$_} }
    foreach ($held in $locks) { $held.Dispose() }
    $json = $report | ConvertTo-Json -Depth 16
    Write-NewBytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes($json))
}
if ($null -ne $failure) { throw $failure }
Write-Host "Reference comparison complete: $(Join-Path $work 'report.json')"
$report.paired_comparison | ConvertTo-Json -Depth 8
