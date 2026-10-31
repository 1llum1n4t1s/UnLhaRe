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
$candidateExpectedHash = 'FC44562A23B61A6FD38FCE305B285185F82CB7D9CB0109E2E320CFDEEBF8027F'
$controlExpectedHash = 'FBF35FC6600FB62506658EC63A734F69857489AE2CE53257CD0907D00F6DAD5F'
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
        'The candidate is an independent research prototype, not a product acceptance or overall 7-Zip victory claim.',
        'Corrected-quotient Q32 candidate and frozen original Q32 control use identical KHSGRP0 input, numeric model and frame; full frame equivalence is mandatory. Native 11-file 7z solid archive has different container and output boundaries.',
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

function Get-Median([double[]]$Values) { $sorted = @($Values | Sort-Object); return $sorted[4] }

# workを確保できない場合は既存データへ失敗reportすら書かない。
if (-not $work.StartsWith($build, [StringComparison]::OrdinalIgnoreCase)) { throw 'WorkDirectory must be a new directory below UnLhaRe/build.' }
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'WorkDirectory exists; no data will be overwritten.' }
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
    $sourcePins['codec.rs']='A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    $sourcePins['cts_model.rs']='DC876ED9B5B7FDB921A8522FA214FA80A76C317FD8F7BB6AC297DAF175ABF99B'
    $sourcePins['verify.ps1']='BD55C3E29541B37E8673198D9BC5930B677724FE19F1F1D6B1CB1588D281C574'
    $sourcePins['build.ps1']='B051B71526232075D7475BD362A006CAEAE47B5014A933814F83D5B0115DD56D'
    $sourcePins['../corrected-quotient/exact_div.rs']='52595705A96F939B63D0DDB88871F3E7F78419973B0891E7A79E42579EA81D3A'
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
    $proofFiles=@{}
    foreach($proofDocument in @($fullJson,$numericJson,$bwtJson,$candidateFullJson,$quotientJson,$buildJson)) {
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
                        if($current.before_sha256 -cne $proofNode.before_sha256 -or $proofNode.before_sha256 -cne $proofNode.after_sha256){throw "Proof provenance SHA mismatch: $proofPath"}
                        if($propertyNames -contains 'before_bytes' -and ($current.before_bytes -ne $proofNode.before_bytes -or $proofNode.before_bytes -ne $proofNode.after_bytes)){throw "Proof provenance length mismatch: $proofPath"}
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
    $codecs = @('q32-corrected-group', 'q32-control', '7zip-native')
    $sevenOptions = @('-t7z', '-mx=9', '-m0=LZMA2:d=64m', '-mmt=1', '-ms=on', '-mqs=off', '-mtm=off', '-mta=off', '-mtc=off')
    for ($round = 0; $round -le 9; $round++) {
        # warm-upと測定9回を同じセッションで回し、測定は各codecが先頭に3回ずつ来る。
        for ($order = 0; $order -lt 3; $order++) {
            $codec = $codecs[($round + $order) % 3]
            $extension = if ($codec -cne '7zip-native') { 'bayes' } else { '7z' }
            $archive = Join-Path $work "$codec-$round.$extension"
            if ($codec -ceq 'q32-corrected-group') {
                $encoding = Invoke-Recorded $candidate.path @('encode', $group, $archive) 'encode' $codec $round $order $work $archive
            } elseif ($codec -ceq 'q32-control') {
                $encoding = Invoke-Recorded $control.path @('encode', $group, $archive) 'encode' $codec $round $order $work $archive
            } else {
                $encoding = Invoke-Recorded $seven.path (@('a', $archive) + $sevenOptions + $names) 'encode' $codec $round $order $native $archive
            }
            if ($codec -ceq 'q32-corrected-group' -and ($encoding.output_bytes -ne $fullJson.fixed_candidate.bytes -or $encoding.output_sha256 -cne $fullJson.fixed_candidate.sha256)) { throw 'Candidate is not the E2E-verified complete Q32 frame.' }
            if ($codec -ceq 'q32-control' -and ($encoding.output_bytes -ne 483469 -or $encoding.output_sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C')) { throw 'Control is not the frozen complete Q32 frame.' }
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
                $decodeProgram = if ($codec -ceq 'q32-corrected-group') { $candidate.path } else { $control.path }
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
    $ratios = @($samples | Where-Object { $_.codec -ceq 'q32-corrected-group' -and -not $_.warmup } | ForEach-Object {
        $candidateRow = $_
        $sevenRow = @($samples | Where-Object { $_.round -eq $candidateRow.round -and $_.codec -ceq 'q32-control' })[0]
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
    foreach ($held in $locks) { $held.Dispose() }
    $json = $report | ConvertTo-Json -Depth 16
    Write-NewBytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes($json))
}
if ($null -ne $failure) { throw $failure }
Write-Host "Reference comparison complete: $(Join-Path $work 'report.json')"
$report.paired_comparison | ConvertTo-Json -Depth 8


