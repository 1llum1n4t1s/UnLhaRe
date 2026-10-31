param([switch]$Execute)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sourceRoot = 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\experiments\khc'
$projectRoot = 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe'
$ownedRoot = Join-Path $sourceRoot 'quaternary-cts-stage-profile'
$outputRoot = Join-Path $projectRoot 'build\khc-quaternary-cts-stage-profile-20261003'
$basisPath = Join-Path $projectRoot 'build\khc-quaternary-cts-mixed-q21-20261003\report.json'
$inputPath = Join-Path $projectRoot 'build\khc-current-source-native-solid-20260923-group\all.group'
$runtimePath = 'C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'
$compilerPath = 'C:\Users\IMT\.rustup\toolchains\1.98.1-x86_64-pc-windows-msvc\bin\rustc.exe'
$formatterPath = Join-Path (Split-Path -Parent $compilerPath) 'rustfmt.exe'
$locks = [System.Collections.Generic.List[System.IO.FileStream]]::new()
$records = [System.Collections.Generic.List[object]]::new()
$identities = [System.Collections.Generic.List[object]]::new()
$mask = [System.Collections.Generic.List[string]]::new()
$watch = [System.Diagnostics.Stopwatch]::StartNew()
$phase = 'preflight'
$report = [ordered]@{
    schema_version = 1; status = 'planned'; execute = [bool]$Execute
    diagnostic_only = $true; formal_speed_CPU_verified = $false; full_benchmark_allowed = $false
    independent_reference_oracle = $false; source_count = 169; identities = @()
    identity_phase_order = @('before','after','live'); identity_masks = @(); identity_phases = @()
    basis = $null; graph = $null; body_diff = $null; capacity_plan = $null
    records = @(); candidate = $null; compile_calls = 0; candidate_cli_calls = 0
    planned = @{ compile = 1; candidate_cli = 1; contract_loops = 12; contract_groups = 13; contract_cases = 83; encode = 2; decode = 1 }
    failure_evidence = $null; owned_codec_processes_at_end = $null; owned_codec_process_census = $null; disk_before = $null; disk_after = $null
    unverified = @('compile_and_codec_until_parent_Execute','failure_JSON_panic_timeout_paths','heap_write_sync_fault_injection','general_inputs_holdout_4native_product_API')
}
function Assert-Condition([bool]$condition,[string]$message) { if (-not $condition) { throw $message } }
function Assert-SafePath([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-Condition (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "reparse rejected: $cursor"
        }
        $parent = [System.IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $full
}
function Get-Ticks([string]$text) {
    return [DateTime]::Parse($text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().Ticks
}
function Get-Identity([string]$path,[switch]$Lock) {
    $full = Assert-SafePath $path
    $item = Get-Item -LiteralPath $full
    Assert-Condition (-not $item.PSIsContainer) "identity not file: $full"
    $stream = [System.IO.File]::Open($full,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read)
    try {
        $sha = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream))
        $after = Get-Item -LiteralPath $full
        Assert-Condition ($item.Length -eq $after.Length -and $item.LastWriteTimeUtc.Ticks -eq $after.LastWriteTimeUtc.Ticks) "identity changed during read: $full"
        $id = [pscustomobject]@{ path=$full; sha256=$sha; bytes=[long]$after.Length; mtime_utc=$after.LastWriteTimeUtc.ToString('O') }
        if ($Lock) { $locks.Add($stream); $stream=$null }
        return $id
    } finally { if ($null -ne $stream) { $stream.Dispose() } }
}
function Assert-Identity($actual,$expected) {
    Assert-Condition ([string]::Equals($actual.path,$expected.path,[StringComparison]::OrdinalIgnoreCase)) "identity path: $($expected.path)"
    foreach ($field in @('sha256','bytes')) { Assert-Condition ($actual.$field -eq $expected.$field) "identity $field mismatch: $($expected.path)" }
    Assert-Condition ((Get-Ticks $actual.mtime_utc) -eq (Get-Ticks $expected.mtime_utc)) "identity UTC ticks mismatch: $($expected.path)"
}
function Test-Phase([string]$name,[int]$index) {
    $done=0
    try {
        foreach ($expected in $identities) {
            $actual=Get-Identity $expected.path
            Assert-Identity $actual $expected
            $mask[$done]=$mask[$done].Remove($index,1).Insert($index,'1'); $done++
        }
        $basisLive=Get-Identity $basisPath; Assert-Identity $basisLive $report.basis
    } finally {
        $report.identity_phases += [pscustomobject]@{name=$name;planned=169;completed=$done;all_SHA_bytes_UTCticks_compared=($done -eq 169)}
    }
}
function Get-Budget {
    [void](Assert-SafePath $outputRoot)
    $drive=[System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($outputRoot))
    $used=0L; $files=@()
    if (Test-Path -LiteralPath $outputRoot) {
        foreach ($f in @(Get-ChildItem -LiteralPath $outputRoot -File -Recurse -Force)) { [void](Assert-SafePath $f.FullName);$used+=$f.Length;$files+=$f.Name }
    }
    Assert-Condition ($used -le 8388608) 'fresh root exceeds 8MiB'
    Assert-Condition ($drive.AvailableFreeSpace -ge 5377097728L) 'free space below 5GiB+8MiB'
    return [pscustomobject]@{root=$outputRoot;used_bytes=$used;free_bytes=$drive.AvailableFreeSpace;files=$files;fresh_limit_bytes=8388608;free_minimum_bytes=5377097728L}
}
function Get-Graph {
    $seen=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $edges=[System.Collections.Generic.List[object]]::new()
    $queue=[System.Collections.Generic.Queue[string]]::new();$queue.Enqueue((Join-Path $ownedRoot 'probe.rs'))
    while ($queue.Count) {
        $file=$queue.Dequeue(); if (-not $seen.Add($file)) { continue }
        $body=Get-Content -Raw -LiteralPath $file
        foreach ($m in [regex]::Matches($body,'#\[path\s*=\s*"([^"]+)"\]\s*(?:pub\([^)]*\)\s+)?mod\s+(\w+)\s*;')) {
            $target=[System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $file) $m.Groups[1].Value))
            $edges.Add([pscustomobject]@{from=$file;to=$target;alias=$m.Groups[2].Value});$queue.Enqueue($target)
        }
    }
    Assert-Condition ($seen.Count -eq 10 -and $edges.Count -eq 9) 'compile graph is not 10source/9edge'
    $expected=@{
        codec='quaternary-cts-stage-profile\codec.rs'; model='quaternary-cts-depth\model.rs'
        baseline_cts='quaternary-cts-depth\integer_cts.rs'; reference_cts='quaternary-cts-q32\integer_cts.rs'
        old_pool='quaternary-cts-integer-pool\integer_pool.rs'; fixed_math='quaternary-cts-integer-pool\fixed_math.rs'
        bwt='causal-bayes-sais\bwt.rs'; packed_alphabet='rejected-binary-mix\packed_alphabet.rs'; multi_range='direct-token\multi_range.rs'
    }
    foreach ($e in $edges) {Assert-Condition ($expected.ContainsKey($e.alias) -and $e.to -eq (Join-Path $sourceRoot $expected[$e.alias])) "graph alias mismatch: $($e.alias)"}
    Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $ownedRoot 'probe.rs')) -match 'use\s+reference_cts\s+as\s+integer_cts\s*;') 'root integer_cts alias'
    Assert-Condition ((Get-Content -Raw -LiteralPath (Join-Path $ownedRoot 'codec.rs')) -match 'baseline_cts\s+as\s+integer_cts') 'codec integer_cts alias'
    return [pscustomobject]@{source_count=10;edge_count=9;sources=@($seen | Sort-Object);edges=@($edges)}
}
function Get-RustTokens([string]$text) {
    # コメントと空白だけを除去し、文字列の空白・escapeは保存する。
    $pattern='"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/|\s+|[^\s]'
    $tokens=[Text.StringBuilder]::new()
    foreach($m in [regex]::Matches($text,$pattern)) {
        if ($m.Value.StartsWith('//') -or $m.Value.StartsWith('/*') -or $m.Value -match '^\s+$') { continue }
        [void]$tokens.Append($m.Value)
    }
    return $tokens.ToString()
}
function Get-BodyDiff {
    $baselinePath=Join-Path $sourceRoot 'quaternary-cts-mixed-q21\baseline_codec.rs'
    $baseline=(Get-Content -Raw -LiteralPath $baselinePath).Replace("`r",'').TrimEnd()+"`n"
    $expected=$baseline
    # 固定観測allowlistは後段に文字列置換の全recipeを定義する。
    foreach ($edit in $script:CodecEdits) {
        Assert-Condition ($expected.Contains([string]$edit[0])) 'body-diff recipe source missing'
        $expected=$expected.Replace([string]$edit[0],[string]$edit[1])
    }
    $expected=$expected.Replace('Handle, Clock,','Handle,')
    $actual=Get-Content -Raw -LiteralPath (Join-Path $ownedRoot 'codec.rs')
    Assert-Condition ((Get-RustTokens $expected) -ceq (Get-RustTokens $actual)) 'codec numerical/wire/state/timer token diff outside observation allowlist'
    return [pscustomobject]@{template=$baselinePath;observation_replacements=$script:CodecEdits.Count;all_tokens_equal_after_allowlist=$true;numeric_copy_files=1;old_total_timer_boundary_preserved=$true}
}
function Get-CLIProjection {
    # codecを実行せず、所有probeの実際のformat literalから全u64桁幅の上限を算出する。
    $body=Get-Content -Raw -LiteralPath (Join-Path $ownedRoot 'probe.rs')
    $formats=@([regex]::Matches($body,'format!\("((?:\\.|[^"\\])*)"') | ForEach-Object {ConvertFrom-Json -InputObject ('"'+$_.Groups[1].Value+'"')})
    $max='18446744073709551615'
    function Expand-Format([string]$text,[hashtable]$named,[string[]]$values=@()) {
        $text=$text.Replace('{{',[string][char]1).Replace('}}',[string][char]2)
        foreach($key in $named.Keys){$text=$text.Replace('{'+$key+'}',[string]$named[$key])}
        $text=$text.Replace('{:?}','['+(@($max)*8 -join ', ')+']')
        foreach($value in $values){$index=$text.IndexOf('{}');Assert-Condition ($index -ge 0) 'projection placeholder count';$text=$text.Remove($index,2).Insert($index,$value)}
        $text=[regex]::Replace($text,'\{(?:\w+)?\}',$max)
        Assert-Condition ($text -notmatch '\{\w*\}|\{:\?\}') 'unresolved format projection'
        return $text.Replace([string][char]1,'{').Replace([string][char]2,'}')
    }
    $groupFormat=@($formats | Where-Object {$_ -like '{{"name":*,"planned":{n},"completed":*'})[0]
    $groupProjection=(1..13 | ForEach-Object {Expand-Format $groupFormat @{} }) -join ','
    $e2eFormat=@($formats | Where-Object {$_ -like '{{"loops":*'})[0]
    $e2eProjection=Expand-Format $e2eFormat @{groups=$groupProjection}
    $rowFormat=@($formats | Where-Object {$_ -eq '[{}, {stratum},{},{},{},{},{}]'})[0]
    $rows=(0..35 | ForEach-Object {Expand-Format $rowFormat @{stratum='null'} @([string]($_%4),'3825340','3825340','3825340',$max,'false')}) -join ','
    $profileFormat=@($formats | Where-Object {$_ -like '{{"direction":*'})[0]
    # contextの実formatより大きい320Bを確保。arrayのcomponent2件も8件として見積る。
    $profileProjection=Expand-Format $profileFormat @{residual=$max;buckets=$rows} @($max,$max,$max,$max,$max,$max,$max,('x'*320))
    $callFormat=@($formats | Where-Object {$_ -like '{{"name":*,"planned":1,"started":*'})[0]
    $calls=(1..3 | ForEach-Object {Expand-Format $callFormat @{} }) -join ','
    $failureFormat=@($formats | Where-Object {$_ -like '{{"phase":*,"error":*'})[0]
    $failureProjection=Expand-Format $failureFormat @{} @(('x'*32),('x'*512),('x'*32),('x'*256),('x'*64),('x'*64),('x'*128),$max,('x'*130))
    $rootFormat=@($formats | Where-Object {$_ -like '{{"schema_version":1,*'})[0]
    $rootValues=@($max,('x'*32),$e2eProjection,$max,$max,$max,$max,$max,$max,('x'*3072),$max,$max,$max,$max)
    $projection=Expand-Format $rootFormat @{calls=$calls;profiles=($profileProjection+','+$profileProjection);failure=$failureProjection} $rootValues
    $count=[Text.Encoding]::UTF8.GetByteCount($projection)+2 # println newline
    Assert-Condition ($count -le 16384) "native stdout projection $count exceeds 16384"
    return [pscustomobject]@{native_stdout_limit_bytes=16384;native_stdout_projection_bytes=$count;numeric_width='time/ordinal/attempt scalars u64MAX20digits; bucket counts<=3825340 by real Handle guard';profile_buckets=72;profile_arrays_upper_length=8;stats_reserved_bytes=3072;failure_quote_byte_caps=@{error=512;recipe=256;expected=64;actual=64;first_difference=128;fixture=32};synthetic_seed_reachability='deliberately modified internal state, not claimed API reachable';clock_semantics='synthetic no real clocks/full state transactional; real end attempts persist if commit rejected'}
}
function Invoke-OwnedChild([string]$name,[string]$file,[string[]]$arguments,[int]$maximumSeconds=120) {
    $remaining=300-$watch.Elapsed.TotalSeconds
    Assert-Condition ($remaining -ge $maximumSeconds) "insufficient global deadline for child $name"
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$file;$info.WorkingDirectory=$ownedRoot
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach($argument in $arguments){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $childWatch=[Diagnostics.Stopwatch]::StartNew();$began=[DateTime]::UtcNow.ToString('O')
    $capture=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
    $hashes=@([Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256),[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256))
    $bytes=@(0L,0L);$previewBytes=@(0,0);$buffers=@([char[]]::new(2048),[char[]]::new(2048));$eof=@($false,$false)
    $timeout=$false;$overLimit=$false;$started=$false;$exit=$null
    try {
        Assert-Condition ($process.Start()) "child failed to start: $name";$started=$true
        $readers=@($process.StandardOutput,$process.StandardError)
        $tasks=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048))
        while (-not ($eof[0] -and $eof[1])) {
            if ($childWatch.Elapsed.TotalSeconds -gt $maximumSeconds -or $watch.Elapsed.TotalSeconds -gt 300) {$timeout=$true;if(-not $process.HasExited){$process.Kill($true)}}
            for($i=0;$i -lt 2;$i++) {
                if($eof[$i] -or -not $tasks[$i].IsCompleted){continue}
                $count=$tasks[$i].GetAwaiter().GetResult()
                if($count -eq 0){$eof[$i]=$true;continue}
                $chunk=[string]::new($buffers[$i],0,$count);$data=[Text.Encoding]::UTF8.GetBytes($chunk)
                $bytes[$i]+=$data.Length;$hashes[$i].AppendData($data)
                foreach($ch in $chunk.ToCharArray()) {
                    $width=[Text.Encoding]::UTF8.GetByteCount([string]$ch)
                    if($previewBytes[$i]+$width -gt 16384){break}
                    [void]$capture[$i].Append($ch);$previewBytes[$i]+=$width
                }
                $limit=if($name -like 'rustfmt-*'){307200}else{16384}
                if($bytes[$i] -gt $limit){$overLimit=$true;if(-not $process.HasExited){$process.Kill($true)}}
                $tasks[$i]=$readers[$i].ReadAsync($buffers[$i],0,2048)
            }
            Start-Sleep -Milliseconds 10
        }
        $process.WaitForExit();$exit=$process.ExitCode
        $record=[pscustomobject]@{name=$name;path=$file;arguments=$arguments;pid=$process.Id;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('O');elapsed_ms=$childWatch.Elapsed.TotalMilliseconds;exit_code=$exit;timeout=$timeout;output_limit_exceeded=$overLimit;stdout=$capture[0].ToString();stderr=$capture[1].ToString();stdout_bytes=$bytes[0];stderr_bytes=$bytes[1];stdout_sha256=[Convert]::ToHexString($hashes[0].GetHashAndReset());stderr_sha256=[Convert]::ToHexString($hashes[1].GetHashAndReset());stdout_preview_truncated=($bytes[0] -gt $previewBytes[0]);stderr_preview_truncated=($bytes[1] -gt $previewBytes[1])}
        $records.Add($record);return $record
    } finally {
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
        $process.Dispose();foreach($hash in $hashes){$hash.Dispose()}
    }
}
function Assert-Child($record) {Assert-Condition (-not $record.timeout -and -not $record.output_limit_exceeded -and $record.exit_code -eq 0) "child failed: $($record.name)"}
function Get-OwnedCodecProcesses {
    $exePath=Join-Path $outputRoot 'stage-o2-yes.exe'
    $escaped=$exePath.Replace('\','\\').Replace("'","\'")
    $processes=@(Get-CimInstance Win32_Process -Filter "ExecutablePath='$escaped'" | Select-Object ProcessId,ParentProcessId,CreationDate,ExecutablePath)
    $report.owned_codec_process_census=@{observed=$true;at_utc=[DateTime]::UtcNow.ToString('O');exact_executable_path=$exePath;count=$processes.Count}
    $report.owned_codec_processes_at_end=$processes
    Assert-Condition ($processes.Count -eq 0) 'owned codec process remains'
}
function Assert-Candidate($candidate) {
    Assert-Condition ($candidate.schema_version -eq 1 -and $candidate.status -eq 'passed') 'candidate schema/status'
    Assert-Condition ($candidate.diagnostic_only -and -not $candidate.formal_speed_CPU_verified -and -not $candidate.full_benchmark_allowed -and -not $candidate.independent_reference_oracle) 'candidate diagnostic flags'
    Assert-Condition ($candidate.contract_e2e.loops.planned -eq 12 -and $candidate.contract_e2e.loops.completed -eq 12) 'contract loops'
    Assert-Condition ($candidate.contract_e2e.groups.Count -eq 13 -and $candidate.contract_e2e.cases.planned -eq 83 -and $candidate.contract_e2e.cases.completed -eq 83 -and $candidate.contract_e2e.cases.ok -eq 38 -and $candidate.contract_e2e.cases.expected_err -eq 45) 'contract cases'
    foreach($g in $candidate.contract_e2e.groups){Assert-Condition ($g.planned -eq $g.completed) "contract group $($g.name)"}
    $operations=$candidate.contract_e2e.operations
    Assert-Condition ($operations.stream_branches -eq 3080 -and $operations.samples -eq 16 -and $operations.scope_pairs -eq 64 -and $operations.top_pairs -eq 4 -and $operations.escape_successes -eq 7) 'contract operations'
    Assert-Condition ($candidate.codec_calls.Count -eq 3) 'codec call records'
    foreach($call in $candidate.codec_calls){Assert-Condition ($call.planned -eq 1 -and $call.started -eq 1 -and $call.completed -eq 1) 'codec call completion'}
    Assert-Condition ($candidate.input_reads.completed -eq 1 -and $candidate.overhead_pairs.completed -eq 10000) 'input/overhead completion'
    foreach($key in @('frame','plain','proof')){Assert-Condition ($candidate.comparisons.$key.planned -eq $candidate.comparisons.$key.completed) "comparison $key"}
    Assert-Condition ($candidate.comparisons.proof.fields_per_pair -eq 14 -and $candidate.comparisons.proof.cdf_to_bits) 'Proof14'
    Assert-Condition ($candidate.profiles.Count -eq 2 -and $candidate.stats.Count -eq 3) 'profile/stats count'
    foreach($p in $candidate.profiles) {
        Assert-Condition ($p.branch_started -eq 3825340 -and $p.branch_completed -eq 3825340 -and $p.component[0] -eq 2725772 -and $p.component[1] -eq 1099568 -and $p.escape_successes -eq 742) 'fixed profile counters'
        Assert-Condition ($p.buckets.Count -eq 36 -and $p.clock_attempts -eq $p.committed_endpoints -and $null -ne $p.top_residual_ns) 'profile scope counters'
        for($s=0;$s -lt 8;$s++) {
            $n=[ulong]$p.stratum_totals[$s];$expectedSamples=if($n -lt 128){0UL}else{1UL+[ulong][Math]::Floor(($n-128UL)/256UL)}
            Assert-Condition ($p.stratum_samples[$s] -eq $expectedSamples) "sample count stratum $s"
        }
        foreach($b in $p.buckets){Assert-Condition ($b[2] -eq $b[3] -and $b[3] -eq $b[4] -and -not $b[6]) 'bucket completion'}
    }
    for($s=0;$s -lt 8;$s++){Assert-Condition ($candidate.profiles[0].stratum_totals[$s] -eq $candidate.profiles[1].stratum_totals[$s] -and $candidate.profiles[0].stratum_samples[$s] -eq $candidate.profiles[1].stratum_samples[$s]) 'direction stratum equality'}
    Assert-Condition ($candidate.peak_live_candidate_frames -eq 2 -and $candidate.peak_live_candidate_frame_bytes -eq 957500 -and $candidate.reference_frames_remaining -eq 0 -and $candidate.frame_clones -eq 0 -and $candidate.disk_input_frame_plain_copies -eq 0 -and $candidate.warmup_runs -eq 0 -and $candidate.abba_cycles -eq 0 -and $null -eq $candidate.failure_evidence) 'candidate ownership/extra-call flags'
}
function Save-Report {
    $report.identities=@($identities);$report.identity_masks=@($mask);$report.records=@($records)
    # formatter stdout本文は重複保持せず、bytes/SHA/exitとbounded stderrを保持する。
    foreach($record in $report.records){if($record.name -like 'rustfmt-*'){$record.stdout='';$record | Add-Member -NotePropertyName stdout_body_omitted -NotePropertyValue $true -Force}}
    $report.disk_after=Get-Budget
    $json=ConvertTo-Json -InputObject $report -Depth 40 -Compress
    $data=[Text.Encoding]::UTF8.GetBytes($json)
    Assert-Condition ($data.Length -le 262144) 'serialized report exceeds 256KiB'
    Assert-Condition ($report.disk_after.used_bytes+$data.Length -le 1310720 -and $report.disk_after.used_bytes+$data.Length -le 8388608) 'write projection exceeds retained/fresh budget'
    $stream=[IO.File]::Open((Join-Path $outputRoot 'report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}

$script:CodecEdits = ConvertFrom-Json -InputObject @'
[["#[path=\"e2e.rs\"] mod e2e;\n",""],["#[path=\"codec.rs\"] pub(crate) mod candidate;\n",""],["use model::{Model,exponent,digest};","use model::{Model,exponent,digest};\nuse crate::instrumentation::{Handle, Clock, TRANSFORM, PAYLOAD, MODEL_NEW, FINISH_AUDIT};"],["struct Stream<'a> {coder:Coder<'a>,","struct Stream<'a> {profile:Handle,coder:Coder<'a>,"],["fn new(coder:Coder<'a>,depth:usize)->Result<Self>{Ok(Self{coder,model:Model::new(depth)?,","fn new(coder:Coder<'a>,depth:usize,profile:&Handle)->Result<Self>{\n        let clock=profile.begin_top(MODEL_NEW)?; // @profile\n        let model=Model::new(depth)?;\n        profile.end(clock)?; // @profile\n        Ok(Self{profile:profile.clone(),coder,model,"],["let prefix=self.model.trees[component].prefix(node,limit)?;","let prefix=self.model.trees[component].prefix(node,limit)?;\n            let ticket=self.profile.admit(component,prefix)?; // @profile\n            let parent=self.profile.begin_branch(ticket,0)?; // @profile\n            let clock=self.profile.begin_branch(ticket,1)?; // @profile"],["let prediction=self.model.predict(component,context,node,usize::from(symbol),self.recent,self.previous[usize::from(symbol)],prefix)?;","let prediction=self.model.predict(component,context,node,usize::from(symbol),self.recent,self.previous[usize::from(symbol)],prefix)?;\n            self.profile.end(clock)?; // @profile\n            let clock=self.profile.begin_branch(ticket,2)?; // @profile"],["let edge=self.model.trees[component].edge(node,child,prefix)?;","self.profile.end(clock)?; // @profile\n            let edge=self.model.trees[component].edge(node,child,prefix)?;\n            let clock=self.profile.begin_branch(ticket,3)?; // @profile"],["self.model.observe(&prediction,child)?;","self.model.observe(&prediction,child)?;\n            self.profile.end(clock)?; // @profile\n            self.profile.end(parent)?; // @profile\n            self.profile.complete(ticket)?; // @profile"],["self.audit.escape_bytes+=1;Ok(byte)","self.audit.escape_bytes+=1;\n        self.profile.escape_success()?; // @profile\n        Ok(byte)"],["fn finish_audit(&mut self)->TokenAudit{self.audit.state_digest=self.model.state_digest();self.audit.branches=self.model.audit.branches;self.audit.class_observations=self.model.class_observations();self.audit.cdf_entropy=self.model.audit.entropy();self.audit}","fn finish_audit(&mut self)->Result<TokenAudit>{\n        let clock=self.profile.begin_top(FINISH_AUDIT)?; // @profile\n        self.audit.state_digest=self.model.state_digest();self.audit.branches=self.model.audit.branches;self.audit.class_observations=self.model.class_observations();self.audit.cdf_entropy=self.model.audit.entropy();\n        self.profile.end(clock)?; // @profile\n        Ok(self.audit)\n    }"],["fn encode_payload(last: &[u16],depth:usize)","fn encode_payload(last: &[u16],depth:usize,profile:&Handle)"],["Stream::new(Coder::Encode(Encoder::with_limit(limit)?),depth)?","Stream::new(Coder::Encode(Encoder::with_limit(limit)?),depth,profile)?"],["let audit=stream.finish_audit();","let audit=stream.finish_audit()?;"],["fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize,depth:usize)","fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize,depth:usize,profile:&Handle)"],["Stream::new(Coder::Decode(Decoder::new(payload)?),depth)?","Stream::new(Coder::Decode(Decoder::new(payload)?),depth,profile)?"],["fn encode(input: &[u8],depth:usize)","fn encode(input: &[u8],depth:usize,profile:&Handle)"],["let (last, primary) = bwt(input)?;\n    let (payload, alphabet, runs, tokens) = encode_payload(&last,depth)?;","let clock=profile.begin_top(TRANSFORM)?; // @profile\n    let (last, primary) = bwt(input)?;\n    profile.end(clock)?; // @profile\n    let clock=profile.begin_top(PAYLOAD)?; // @profile\n    let (payload, alphabet, runs, tokens) = encode_payload(&last,depth,profile)?;\n    profile.end(clock)?; // @profile"],["fn decode(frame: &[u8])","fn decode(frame: &[u8],profile:&Handle)"],["let (last, runs, tokens) = decode_payload(","let clock=profile.begin_top(PAYLOAD)?; // @profile\n    let (last, runs, tokens) = decode_payload("],["        depth,\n    )?;\n    let plain = inverse_bwt(&last, primary, &alphabet)?;","        depth,\n        profile,\n    )?;\n    profile.end(clock)?; // @profile\n    let clock=profile.begin_top(TRANSFORM)?; // @profile\n    let plain = inverse_bwt(&last, primary, &alphabet)?;\n    profile.end(clock)?; // @profile"],["pub(crate) fn run_profile(input:&[u8],depth:usize)","pub(crate) fn run_profile(input:&[u8],depth:usize,profile:&Handle)"],["let result=encode(input,depth);","let result=encode(input,depth,profile);"],["pub(crate) fn run_selfcheck()->crate::Result<()>{e2e::run()}\n",""],["pub(crate) fn run_restore(frame:&[u8])","pub(crate) fn run_restore(frame:&[u8],profile:&Handle)"],["let result=decode(frame);","let result=decode(frame,profile);"]]
'@

try {
    Assert-Condition ([IO.Path]::GetFullPath($PSScriptRoot) -eq $ownedRoot) 'runner path differs from fixed owned root'
    Assert-Condition ($PSVersionTable.PSVersion.ToString() -eq '7.6.5') 'requires PowerShell7.6.5'
    Assert-Condition ((Get-Process -Id $PID).Path -eq $runtimePath) 'runner must use pinned pwsh executable'
    $runtime=Get-Identity $runtimePath -Lock;Assert-Condition ($runtime.sha256 -eq '362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139') 'runtime SHA'
    $compiler=Get-Identity $compilerPath -Lock;Assert-Condition ($compiler.sha256 -eq 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC') 'compiler SHA'
    $formatter=Get-Identity $formatterPath -Lock
    $report.runtime=$runtime;$report.compiler=$compiler;$report.formatter=$formatter
    $report.basis=Get-Identity $basisPath -Lock
    Assert-Condition ($report.basis.bytes -eq 258738 -and $report.basis.sha256 -eq '2866C1AD9CB11F008F3856ED2B36560B569A42734F186D3F0C6A49D469EBD853') 'basis SHA/bytes'
    $basis=Get-Content -Raw -LiteralPath $basisPath | ConvertFrom-Json -DateKind String
    Assert-Condition ($basis.sources.Count -eq 163 -and $basis.sources_after.Count -eq 163 -and $basis.sources_live.Count -eq 163) 'basis phase source counts'
    $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for($i=0;$i -lt 163;$i++) {
        $pin=$basis.sources[$i];Assert-Condition ($unique.Add($pin.path)) 'duplicate/case alias basis identity'
        foreach($phaseSource in @($basis.sources_after,$basis.sources_live)) {
            $matching=@($phaseSource | Where-Object {$_.path -eq $pin.path});Assert-Condition ($matching.Count -eq 1) 'basis after/live path multiplicity';Assert-Identity $matching[0] $pin
        }
        $actual=Get-Identity $pin.path -Lock;Assert-Identity $actual $pin;$identities.Add($actual);$mask.Add('100')
    }
    $additions=@('QUATERNARY_CTS_MIXED_Q21_ABBA_RESULT_20261003.md','QUATERNARY_CTS_STAGE_PROFILE_CONTRACT_20261003.md','quaternary-cts-stage-profile\FAILURE_PLAN.md','quaternary-cts-stage-profile\codec.rs','quaternary-cts-stage-profile\probe.rs','quaternary-cts-stage-profile\verify-stages.ps1')
    foreach($relative in $additions){$id=Get-Identity (Join-Path $sourceRoot $relative) -Lock;Assert-Condition ($unique.Add($id.path)) 'new identity alias';$identities.Add($id);$mask.Add('100')}
    Assert-Condition ($identities.Count -eq 169) 'identity count'
    Assert-Condition ($identities[163].bytes -eq 9202 -and $identities[163].sha256 -eq '94FB800147EF15B2D11C75B33706499AD6276637BEE10A28FDE7F0610AAF3B62') 'RESULT pin'
    Assert-Condition ($identities[164].bytes -eq 8368 -and $identities[164].sha256 -eq '067F5AF84A6EB4D3129C262242247B16AFC1B3C3861FA628B97143611C8E4871') 'contract pin'
    Assert-Condition ($identities[165].bytes -eq 21052 -and $identities[165].sha256 -eq '95E16CD00334D6297FEE7A764A267567C0AE27D8C81ED4C7F30E01781A0455EC') 'FAILURE_PLAN pin'
    $report.identity_phases+=@{name='before';planned=169;completed=169;all_SHA_bytes_UTCticks_compared=$true}
    $inputIdentity=@($identities | Where-Object {$_.path -eq $inputPath});Assert-Condition ($inputIdentity.Count -eq 1 -and $inputIdentity[0].bytes -eq 2811006 -and $inputIdentity[0].sha256 -eq '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76') 'fixed input identity'
    $sourceBytes=0L;foreach($i in 165..168){$sourceBytes+=$identities[$i].bytes}
    Assert-Condition ($sourceBytes -le 307200) 'owned four source budget'
    $ownedFiles=@(Get-ChildItem -LiteralPath $ownedRoot -File);Assert-Condition ($ownedFiles.Count -eq 4) 'owned scope file count'
    $identityProjection=169*1024;foreach($id in $identities){Assert-Condition ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $id -Compress)) -le 1024) 'identity row projection'}
    Assert-Condition ([Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json $report.basis -Compress)) -le 2048) 'basis row projection'
    $report.capacity_plan=@{owned_source_bytes=$sourceBytes;owned_source_limit=307200;identity_bytes=$identityProjection;basis_bytes=2048;other_JSON_bytes=87040;JSON_projection_bytes=($identityProjection+2048+87040);JSON_limit=262144;EXE_limit=1048576;retained_projection_bytes=1310720;fresh_limit=8388608;free_minimum=5377097728L;compile_estimate_seconds=60;CLI_estimate_seconds=60;total_estimate_seconds=180;global_deadline_seconds=300;child_timeout_seconds=120}
    Assert-Condition ($report.capacity_plan.JSON_projection_bytes -eq 262144) 'JSON projection arithmetic'
    $report.graph=Get-Graph;$report.body_diff=Get-BodyDiff;$report.native_output_plan=Get-CLIProjection
    $tokens=$null;$parserErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parserErrors)
    Assert-Condition ($parserErrors.Count -eq 0) 'runner parser errors'
    $report.disk_before=Get-Budget
    Assert-Condition (-not (Test-Path -LiteralPath $outputRoot)) 'fresh output root must be absent'
    $phase='formatter'
    foreach($name in @('codec','probe')){
        $formatted=Invoke-OwnedChild "rustfmt-$name" $formatterPath @('--edition','2024','--config','skip_children=true','--emit','stdout',(Join-Path $ownedRoot "$name.rs")) 20
        Assert-Child $formatted;Assert-Condition ($formatted.stderr_bytes -eq 0) 'formatter stderr must be empty'
    }
    $report.stderr_policy=@{formatter='empty';candidate='empty on success, bounded retained on failure';compiler='bounded warnings retained; nonzero rejected'}
    if(-not $Execute) {
        Test-Phase 'after' 1;Test-Phase 'live' 2
        $report.status='nonExecute_passed';$report.identities=@($identities);$report.identity_masks=@($mask)
        $report.records=@($records | Select-Object name,exit_code,stdout_bytes,stderr_bytes,stdout_sha256,stderr_sha256)
        $report.disk_after=Get-Budget
        Assert-Condition (-not (Test-Path -LiteralPath $outputRoot)) 'nonExecute created output root'
        $report | ConvertTo-Json -Depth 30 -Compress
    } else {
        $phase='compile';[void](Get-Budget);[void][IO.Directory]::CreateDirectory($outputRoot)
        $exePath=Join-Path $outputRoot 'stage-o2-yes.exe';$report.compile_calls=1
        $compile=Invoke-OwnedChild 'compile' $compilerPath @('--edition=2024','--cfg','frame_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE',(Join-Path $ownedRoot 'probe.rs'),'-o',$exePath)
        Assert-Child $compile
        $report.executable_before=Get-Identity $exePath -Lock
        Assert-Condition ($report.executable_before.bytes -le 1048576) 'EXE exceeds 1MiB'
        [void](Get-Budget);$phase='profile';$report.candidate_cli_calls=1
        $profile=Invoke-OwnedChild 'profile' $exePath @('profile',$inputPath)
        # 非zeroでもparseしてから拒否。panic等は回収不能の内部completedをnullにする。
        try{$report.candidate=$profile.stdout | ConvertFrom-Json -DateKind String}catch{$report.candidate=@{schema_version=1;status='failed';phase='unrecoverable_child';completed=$null;unknown_reason='no valid bounded candidate JSON';planned=$report.planned};throw}
        Assert-Child $profile;Assert-Condition ($profile.stderr_bytes -eq 0) 'successful candidate stderr must be empty';Assert-Candidate $report.candidate
        $phase='identity_after';Test-Phase 'after' 1;Test-Phase 'live' 2
        $report.executable_after=Get-Identity $exePath;Assert-Identity $report.executable_after $report.executable_before
        $phase='save';Get-OwnedCodecProcesses;$report.status='passed';$report.unverified=@('failure_JSON_panic_timeout_paths','heap_write_sync_fault_injection','general_inputs_holdout_4native_product_API')
        Save-Report
        $final=Get-Budget;Assert-Condition ($final.files.Count -eq 2 -and $final.used_bytes -le 1310720) 'final output count/bytes'
        [pscustomobject]@{status='passed';output=$outputRoot;files=$final.files;final_bytes=$final.used_bytes;report_identity=(Get-Identity (Join-Path $outputRoot 'report.json'))} | ConvertTo-Json -Depth 5 -Compress
    }
} catch {
    $report.status='failed';$report.failure_evidence=@{phase=$phase;error=$_.Exception.Message.Substring(0,[Math]::Min(2048,$_.Exception.Message.Length));planned=$report.planned;compile_started=$report.compile_calls;CLI_started=$report.candidate_cli_calls}
    if($Execute -and (Test-Path -LiteralPath $outputRoot) -and -not (Test-Path -LiteralPath (Join-Path $outputRoot 'report.json'))) {
        try {Get-OwnedCodecProcesses} catch {
            $report.owned_codec_process_check_error=$_.Exception.Message.Substring(0,[Math]::Min(2048,$_.Exception.Message.Length))
            if($null -eq $report.owned_codec_process_census){
                $report.owned_codec_process_census=@{observed=$false;at_utc=[DateTime]::UtcNow.ToString('O');exact_executable_path=(Join-Path $outputRoot 'stage-o2-yes.exe');count=$null;reason='census unavailable; see owned_codec_process_check_error'}
            }
        }
        try {Save-Report} catch {Write-Error "bounded report save failed: $($_.Exception.Message)" -ErrorAction Continue}
    }
    throw
} finally {foreach($stream in $locks){$stream.Dispose()}}
