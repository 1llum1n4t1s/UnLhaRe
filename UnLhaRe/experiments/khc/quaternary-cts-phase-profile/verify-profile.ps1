[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-quaternary-cts-phase-profile-20261002'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins=@(
 @('../QUATERNARY_CTS_PHASE_PROFILE_CONTRACT_20261002.md','128DFCF78987C1F3F9F8960DF452B905A4AD4C26CE1CCA6FEE1630FEB81BA80A'),
 @('profile.rs','7FA9557A7F5438FB18366E0D9554296919EAE929AE2508DDF0A4E6DB6F0E0092'),
 @('timing.rs','7E0E44040DCFB0739EAEB8C3810C6E042644FBF10FE61D332C1322E5933C15DB'),
 @('model.rs','F599961210F42C6B2DE9CF07146DE6CF9118858CA4119B3AA3D97B4EFB6D6F40'),
 @('old_wire.rs','292417BF89C57CDEAD4D18E80015AB54AF17C51832F13D4D69BC70C4595F3117'),
 @('pow2_wire.rs','22BB6FD2963E9E403321567767F6A5707B76327B59482DC2F289D99A03CB021A'),
 @('FAILURE_PLAN.md','02BC42C61925B43695C6195B336C818504F718EABE331424FC542792B3511B0E'),
 @('../quaternary-cts-pow2/verify-full.ps1','F8B59FD01A776A1567A78AA16779B1BB9562C98C68ABD3A02A8CA1F21959C56F'),
 @('../QUATERNARY_CTS_POW2_RESULT_20261002.md','331E19239402C3B600F23E7F82531E4E3E52D0AB4EDC22E4E5311B5C7E933237'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/report.json','D5F40FA03A3987605432D3E430F5BAAEA7C47AB628E046CC27723085B7D8D777'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/codec-o2-yes.exe','92136CA3BE32D64768E5510ACB1AA2CD103B0B0608DFD7BD22EBE358F4F54F7B'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/all.khqc','9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD'),
 @('../QUATERNARY_CTS_POW2_CONTRACT_20261002.md','3D942A6A32F267B469E55999E83E84DD9EFCA1B46B3442A589899B8FCA9C0ED0'),
 @('../QUATERNARY_CTS_INTEGER_FRAME_CONTRACT_20261002.md','B813A1D3B41F40B615FA356411D0E1F923FA924231ADAC1FF9CB71BBD54122B1'),
 @('../quaternary-cts-pow2/integer_cts.rs','DCFD5CF8F9D408174840194CA3D0AF38F90EB938172C5A51EA2B85BA90427B28'),@('../quaternary-cts-pow2/comparison.rs','248400D4F1954F4CB4A3F7D759A26F4AD51C12FBCB3EA0CBE8021CE4AF43D24C'),
 @('../quaternary-cts-integer-frame/codec.rs','673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327'),
 @('../quaternary-cts-integer-frame/verify-full.ps1','C1AB88073C433560F4F73D06A9EC10E051E1EF90809F10F6A8952255C6B92D0E'),
 @('../quaternary-cts-integer-frame/FAILURE_PLAN.md','F06DFE8EF43DD10AE99DE118C7B40D5C18283C2469EE1191997336878C0DD4C3'),
 @('../QUATERNARY_CTS_INTEGER_FRAME_RESULT_20261002.md','E042DD5807C35DC6654EEA431709081B204D3A1FCB177189AF94CA6607963C4F'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/report.json','18B106BDB873BB5B1C82EBF7F7B9B6EBB17209C8E137D9332320941D0CBECB98'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/all.khqc','9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/codec-o2-yes.exe','1E47B92B840F7211B981B367F15B216B8DAA03811C78C3261B55F37CA1765B95'),
 @('../quaternary-cts-integer-frame/model.rs','BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9'),@('../quaternary-cts-pow2/codec.rs','4D4FF38557860B9DF99F20F2CBC11D9B99D9C1D9D2593D071C1D936CDC60C0CE'),@('../quaternary-cts-integer-frame/e2e.rs','824DE9E08FA2EC069FE0D935EC7E2FE58EFD38FE813D5D49F545AD156AABE3E1'),@('../quaternary-cts-pow2/FAILURE_PLAN.md','2831CFE2D4430A6D76C3740F1C9BF1A64E389EFB0997A25BFECEDAA8F8D0A101'),
 @('../quaternary-cts-integer-pool/fixed_math.rs','A599C6FA10DA8A1E7D72210CA559F02873F1EDAB5564FC84745CAAC9C0E4BACD'),
 @('../quaternary-cts-integer-pool/integer_pool.rs','7135CC9E6F5CF57191DC6EE409D8C32C8EF9FEB9C1B6B2D7B18C7B436F56C625'),
 @('../quaternary-cts-integer-pool/opportunity.rs','5DEC4BD1AAAC58BEFB8F933CD5A2EB48D82CC911DAA9C631B044C3F00631003F'),
 @('../quaternary-cts-q32/integer_cts.rs','5AE361CF9544AA75A86FECD852DBBCE6DA7EDF08AB169690B3C8A69973BEEED7'),
 @('../causal-bayes-sais/bwt.rs','810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'),
 @('../rejected-binary-mix/packed_alphabet.rs','4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'),
 @('../direct-token/multi_range.rs','CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129'),
 @('../QUATERNARY_CTS_INTEGER_POOL_CONTRACT_20261002.md','EE130558C966D6C96DE8887050A01D39FA3FDC59802AC70A867BC0DD53BE28FA'),
 @('../QUATERNARY_CTS_INTEGER_POOL_RESULT_20261002.md','CC5139C868DC26B20CF333E84EE4B4E35E18853FF8E91BC2561FF3E78C94E73B'),
 @('../../../build/khc-quaternary-cts-integer-pool-opportunity-20261002/report.json','A0A586A487E8761E075CD3B157866CD5C0183AEC94106D9E6556199688C11A01'),
 @('../QUATERNARY_CTS_Q32_PRIMITIVE_CONTRACT_20261002.md','3A5FD8AB1A03A834A4F497B8734A2F44468F38B7A1ACD11D02674758D075C14D'),
 @('../QUATERNARY_CTS_Q32_PRIMITIVE_RESULT_20261002.md','BD045390F92312C188E092F4C221726FF259201CB62BA63C13B4CEC5E4F8EC57'),
 @('../QUATERNARY_CTS_Q32_PROOF_CLOSURE_20261002.md','5B9A66B06BA8120C47392D130DACA8E2F89F620249DFC7F7FD89C6372135DE91'),
 @('../../../build/khc-quaternary-cts-q32-primitive-20261002-proof-closure/report.json','3E50A4A0B3A2C7FE3983BA09D3241C27481B63AE7D05085BAFDAA8CD56B30309'),
 @('../DIRECT_TOKEN_PRIMITIVE_RESULT_20261002.md','BB3121FE5EFA6B6391C99575ABEABD2C4ECF075C1334E63FD245B1DEE23AFC4A'),
 @('../../../build/khc-direct-token-range-20261002/report.json','3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AE'),
 @('../../../build/khc-current-source-native-solid-20260923-group/all.group','18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'),
 @('../disk-budget.ps1','F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7')
)
$locks=[Collections.Generic.List[IO.FileStream]]::new();$sources=[Collections.Generic.List[object]]::new();$records=[Collections.Generic.List[object]]::new()
function Identity([string]$Path) {$item=Get-Item -LiteralPath $Path;[pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash;bytes=$item.Length;mtime_utc=$item.LastWriteTimeUtc.ToString('o')}}
function Bounded-Text([string]$Text) {
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -le 65536) {return $Text}
    $low=0;$high=[Math]::Min($Text.Length,65536)
    while ($low -lt $high) {
        $middle=[int][Math]::Ceiling(($low+$high)/2.0)
        if ([Text.Encoding]::UTF8.GetByteCount($Text.Substring(0,$middle)) -le 65536) {$low=$middle}else {$high=$middle-1}
    }
    if ($low -gt 0 -and [char]::IsHighSurrogate($Text[$low-1])) {$low--}
    return $Text.Substring(0,$low)
}
function Child([string]$File, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$File; $info.WorkingDirectory=$project; $info.UseShellExecute=$false
    $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started=$false
    $out=[Text.StringBuilder]::new(); $err=[Text.StringBuilder]::new()
    try {
        $null=$process.Start();$started=$true
        $outBuffer=[char[]]::new(4096); $errBuffer=[char[]]::new(4096)
        $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
        $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
        $outDone=$false; $errDone=$false
        while (!$outDone -or !$errDone -or !$process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -gt 120) { throw 'Child timeout' }
            if (!$outDone -and $outTask.IsCompleted) {
                $n=$outTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $outDone=$true } else {
                    $null=$out.Append($outBuffer,0,$n)
                    if ($out.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($out.ToString()) -gt 65536) {throw 'stdout byte cap'}; $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,4096)
                }
            }
            if (!$errDone -and $errTask.IsCompleted) {
                $n=$errTask.GetAwaiter().GetResult()
                if ($n -eq 0) { $errDone=$true } else {
                    $null=$err.Append($errBuffer,0,$n)
                    if ($err.Length -gt 65536 -or [Text.Encoding]::UTF8.GetByteCount($err.ToString()) -gt 65536) {throw 'stderr byte cap'}; $errTask=$process.StandardError.ReadAsync($errBuffer,0,4096)
                }
            }
            [Threading.Thread]::Sleep(5)
        }
        $result=[pscustomobject]@{ file=$File; argv=$Arguments; cwd=$project; started=$started; status='completed'; exit=$process.ExitCode; stdout=$out.ToString().Trim(); stderr=$err.ToString().Trim(); elapsed_ms=$watch.Elapsed.TotalMilliseconds; child_total_processor_ms=$process.TotalProcessorTime.TotalMilliseconds; error=$null }
        $records.Add($result)
        return $result
    } catch {
        $failure=$_.Exception.Message
        if ($started -and !$process.HasExited) {$process.Kill($true);$process.WaitForExit()}
        $exit=if ($started -and $process.HasExited) {$process.ExitCode}else {$null}
        $status=if ($started) {'interrupted'}else {'start-failed'}
        $records.Add([pscustomobject]@{file=$File;argv=$Arguments;cwd=$project;started=$started;status=$status;exit=$exit;stdout=(Bounded-Text $out.ToString());stderr=(Bounded-Text $err.ToString());elapsed_ms=$watch.Elapsed.TotalMilliseconds;child_total_processor_ms=$(if ($started -and $process.HasExited) {$process.TotalProcessorTime.TotalMilliseconds}else {$null});error=$failure})
        throw
    } finally {
        if ($started -and !$process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Success($Record) {
    if ($Record.exit -ne 0) { throw "Child failed: $($Record.file): $($Record.stderr)" }
}

function Safe-Path([string]$Path) {
 $resolved=[IO.Path]::GetFullPath($Path);$ancestor=$resolved
 while ($ancestor) {if (Test-Path -LiteralPath $ancestor) {if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw "Reparse point: $ancestor"}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
 return $resolved
}
$exeReserve=1MB;$reportReserve=512KB;$peakReserve=$exeReserve+$reportReserve
if ($peakReserve -ne 1572864 -or $peakReserve -is [array]) {throw 'Peak scalar reserve mismatch'}
$created=$false;$exe=$null
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@();profile_lines=@();parsed_profile=$null;temporary_created=$false;full_benchmark_allowed=$false;capacity_plan=@{max_bytes=8MB;retained_estimated_bytes=1280KB;exe_reserve_bytes=$exeReserve;report_reserve_bytes=$reportReserve;peak_reserve_bytes=$peakReserve;scalar_preflight_evaluated=$true;note='pre/post guard, not OS write quota'};unverified=@('formal codec speed and CPU15%','holdout/categories','four native environments','product/API integration','exact full-input CPU time from samples');sampling_limitations=@('serial subset bias','clock and aggregation overhead','code placement','CPU scheduling');decode_repeated=$false;disk_frame_restore_input_copy_created=$false}
function Save-Report {
 if (!$created) {return};$report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
 $json=$report | ConvertTo-Json -Depth 20
 if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $reportReserve) {throw 'Report reserve exceeded'}
 [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json);$null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
function Capture-ProfileLines {
 if (!$exe) {return}
 $child=@($records | Where-Object {$_.file -eq $exe} | Select-Object -Last 1)
 if (!$child.Count) {return}
 $report.profile_lines=@()
 foreach ($line in ($child[0].stdout -split '\r?\n')) {
  if (!$line) {continue}
  try {$parsed=$line | ConvertFrom-Json;$report.profile_lines+=@{raw=$line;parsed=$parsed;parse_error=$null}}
  catch {$report.profile_lines+=@{raw=$line;parsed=$null;parse_error=$_.Exception.Message}}
 }
 $final=@($report.profile_lines | Where-Object {$_.parsed -and $_.parsed.kind -eq 'final'} | Select-Object -Last 1)
 if ($final.Count) {$report.parsed_profile=$final[0].parsed}
 Save-Report
}
function Immutable-Basis {
 $old=(Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-cts-pow2-20261002/report.json') -Raw | ConvertFrom-Json)
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 36 -or $old.sources_after.Count -ne 36) {throw 'Immutable prior basis shape/status'}
 $identities=@()
 for ($j=0;$j -lt 36;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable prior source basis mismatch'}
  $identities+=@($now)
 }
 $report.immutable_basis=@{status='passed';sources_checked=36;identities=$identities;prior_report_sha256='D5F40FA03A3987605432D3E430F5BAAEA7C47AB628E046CC27723085B7D8D777';prior_Execute_repeated=$false}
}
function Validate-Profile {
 $a=$report.parsed_profile
 if (!$a -or $report.profile_lines.Count -ne 5 -or @($report.profile_lines | Where-Object {$_.parse_error}).Count -or $a.kind -ne 'final' -or $a.status -ne 'passed' -or $a.operation -ne 'phase-profile' -or !$a.diagnostic_only -or $a.formal_speed_CPU_verified -or $a.full_benchmark_allowed -or $a.decode_repeated -or $a.disk_frames_created -or $a.disk_restores_created) {throw 'Profile scope/final JSON mismatch'}
 $fixed=@{runs_completed=4;frame_comparisons=4;expected_matched_bytes_per_run=474730;samples_per_run=3736;phases_per_sample=7;sample_stride=1024;warmup_runs=0;additional_repeats=0}
 foreach ($name in $fixed.Keys) {if ($a.$name -ne $fixed[$name]) {throw "Profile fixed field: $name"}}
 if ($a.ABBA.Count -ne 4 -or $a.run_records.Count -ne 4) {throw 'Profile ABBA shape'}
 $order=@('old','pow2','pow2','old')
 $allNames=@('full_encode','bwt','payload_setup','model_initialization','payload_loop','final_digest','metadata_crc_frame')
 $sampleNames=@('model_predict','cts_predict','pool_predict','range_interval','model_observe','pool_update','cts_observe')
 $fields=@{frame_bytes=474730;header_bytes=281;payload_bytes=474449;plain_crc=433441561;payload_crc=3589341169;header_crc=1741345118;runs=889227;primary=1762795;alphabet_symbols=257;rank_intervals=889227;length_intervals=889227;escape_bytes=742}
 $classes=@(889227,620240,1216305,889227,64372,145969)
 for ($j=0;$j -lt 4;$j++) {
  $r=$a.run_records[$j];$progress=$report.profile_lines[$j].parsed
  if ($a.ABBA[$j] -ne $order[$j] -or $r.index -ne $j -or $r.variant -ne $order[$j] -or !$r.frame_equal -or $r.matched_bytes -ne 474730 -or $r.error -or $progress.kind -ne 'run' -or ($progress.record | ConvertTo-Json -Depth 12 -Compress) -ne ($r | ConvertTo-Json -Depth 12 -Compress)) {throw 'Profile run/progress/frame mismatch'}
  foreach ($name in $fields.Keys) {if ($r.stats.$name -ne $fields[$name]) {throw "Profile run fixed stats: $name"}}
  if ($r.stats.grammar_digest -ne '58735a2b7383d755' -or $r.stats.base_pool_digest -ne '9128444225deabce' -or $r.stats.branches.Count -ne 2 -or $r.stats.branches[0] -ne 2725772 -or $r.stats.branches[1] -ne 1099568 -or $r.stats.class_observations.Count -ne 6) {throw 'Profile causal stats'}
  for ($k=0;$k -lt 6;$k++) {if ($r.stats.class_observations[$k] -ne $classes[$k]) {throw 'Profile class observation'}}
  if (![double]::IsFinite([double]$r.stats.cdf_entropy_bits) -or [Math]::Abs($r.stats.cdf_entropy_bits-3788636.714502990) -gt 1e-4) {throw 'Profile entropy'}
  $m=$r.metrics
  if ($m.sample_count -ne 3736 -or $m.first_sample_serial -ne 0 -or $m.last_sample_serial -ne 3824640 -or $m.sample_components.Count -ne 2 -or $m.sample_prefixes.Count -ne 4 -or $m.all_phases.Count -ne 7 -or $m.sampled_phases.Count -ne 7) {throw 'Profile sample shape/count/serial'}
  $componentSum=0L;foreach ($value in $m.sample_components) {if ($value -lt 0) {throw 'Negative component samples'};$componentSum+=$value}
  $prefixSum=0L;foreach ($value in $m.sample_prefixes) {if ($value -lt 0) {throw 'Negative prefix samples'};$prefixSum+=$value}
  if ($componentSum -ne 3736 -or $prefixSum -ne 3736) {throw 'Profile component/prefix coverage'}
  for ($k=0;$k -lt 7;$k++) {
   if ($m.all_phases[$k].name -ne $allNames[$k] -or $m.all_phases[$k].count -ne 1 -or $m.all_phases[$k].elapsed_ns -lt 0 -or $m.sampled_phases[$k].name -ne $sampleNames[$k] -or $m.sampled_phases[$k].count -ne 3736 -or $m.sampled_phases[$k].elapsed_ns -lt 0) {throw 'Profile phase name/count/time'}
  }
 }
 $report.profile_validated=$true
 $report.phase_interpretation='whole phases mutually non-containing except full_encode; inner sampled CTS/pool contained in outer model, no sum equality assertion; sample time not extrapolated to exact CPU'
}
try {
 $null=Safe-Path $work
 if (Test-Path -LiteralPath $work) {throw 'Fresh root exists; no overwrite/retry'}
 foreach ($pin in $pins) {$path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]));$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$id=Identity $path;if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"};$sources.Add($id)}
 if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
 foreach ($path in @($PSCommandPath,$compiler,$runtime)) {$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))}
 $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
 if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime pin mismatch'}
 $compiledSources=@('profile.rs','timing.rs','model.rs','old_wire.rs','pow2_wire.rs','../quaternary-cts-integer-pool/fixed_math.rs','../quaternary-cts-integer-pool/integer_pool.rs','../quaternary-cts-q32/integer_cts.rs','../quaternary-cts-pow2/integer_cts.rs','../causal-bayes-sais/bwt.rs','../rejected-binary-mix/packed_alphabet.rs','../direct-token/multi_range.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
 foreach ($entry in @($sources | Where-Object {$_.path -in $compiledSources})) {
  $content=[IO.File]::ReadAllText($entry.path)
  if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b') {throw 'Unexpected include or extern crate'}
  $matches=[regex]::Matches($content,'(?m)^\s*(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
  if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{') {throw 'Unsupported module declaration'}
  foreach ($match in $matches) {$relative=if ($match.Groups[1].Success) {$match.Groups[1].Value}else {$match.Groups[2].Value+'.rs'};$resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($entry.path)) $relative));if ($resolved -notin $compiledSources) {throw "Unpinned graph edge: $resolved"};$report.imports+=@{source=$entry.path;resolved=$resolved}}
 }
 $root=$compiledSources[0];$modelSource=$compiledSources[2];$wireSources=@($compiledSources[3],$compiledSources[4])
 if ($compiledSources.Count -ne 12 -or $report.imports.Count -ne 12 -or @($report.imports | Where-Object {$_.source -eq $root}).Count -ne 10 -or @($report.imports | Where-Object {$_.source -in $wireSources -and $_.resolved -eq $modelSource}).Count -ne 2 -or @($report.imports.resolved | Sort-Object -Unique).Count -ne 11) {throw 'Unexpected twelve-source/twelve-edge graph'}
 $rootText=[IO.File]::ReadAllText($root);$oldText=[IO.File]::ReadAllText($compiledSources[3]);$powText=[IO.File]::ReadAllText($compiledSources[4]);$modelText=[IO.File]::ReadAllText($modelSource)
 if ($rootText -notmatch 'use reference_cts as integer_cts;' -or $rootText -match '\benum\s|\bdyn\s' -or $oldText -notmatch 'reference_cts as integer_cts' -or $powText -notmatch 'pow2_cts as integer_cts' -or $modelText -notmatch 'use super::\{' -or $modelText -match 'crate::integer_cts') {throw 'Static CTS alias boundary mismatch'}
 Immutable-Basis
 $cpu=@(Get-CimInstance Win32_Processor | Select-Object Name,NumberOfCores,NumberOfLogicalProcessors,Architecture,Manufacturer)
 $os=Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,OSArchitecture
 $report.environment=@{source_cwd=$project;preflight_cwd=(Get-Location).Path;CPU=$cpu;OS=$os;process_architecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString();OS_description=[Runtime.InteropServices.RuntimeInformation]::OSDescription;logical_count=[Environment]::ProcessorCount;runtime=$report.runtime;runtime_version=$report.runtime_version;compiler=$report.compiler}
 if ($report.environment.process_architecture -ne 'X64' -or ![OperatingSystem]::IsWindows() -or $cpu.Count -eq 0 -or !$os.Version) {throw 'Windows x64 environment evidence missing'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if ($report.disk_before.used_bytes+$peakReserve -gt $report.disk_before.max_bytes) {throw 'Peak capacity reserve'}
 if ($Execute) {
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';$report.execution_stage='compiler-version';Save-Report
  $version=Child $compiler @('--version');Save-Report;Success $version
  if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)') {throw 'Compiler version mismatch'}
  $report.compiler_version=$version.stdout;$exe=Join-Path $work 'profile-o2-yes.exe';$report.execution_stage='build-once'
  $build=Child $compiler @((Join-Path $PSScriptRoot 'profile.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe);Save-Report;Success $build
  $report.executable_before=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$report.execution_stage='exe-identity-saved';Save-Report
  if ($report.executable_before.bytes -gt $exeReserve) {throw 'EXE reserve'}
  $input=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group';$frame=Join-Path $project 'build/khc-quaternary-cts-integer-frame-20261002/all.khqc'
  $report.execution_stage='one-ABBA-profile-cli';$profile=Child $exe @('profile',$input,$frame);Save-Report
  Capture-ProfileLines
  Success $profile
  if ($profile.stderr) {throw 'Unexpected profile stderr'}
  Validate-Profile
  $report.executable_after=Identity $exe;Save-Report
  if ($report.executable_before.sha256 -ne $report.executable_after.sha256 -or $report.executable_before.bytes -ne $report.executable_after.bytes -or $report.executable_before.mtime_utc -ne $report.executable_after.mtime_utc) {throw 'EXE identity changed'}
  $null=Safe-Path $work
  $files=@(Get-ChildItem -LiteralPath $work -Force)
  foreach ($entry in $files) {if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Output descendant reparse'}}
  $running=@(Get-Process | Where-Object {try {$_.Path -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($exe)}catch {$false}})
  $report.owned_codec_processes_at_end=$running.Count;Save-Report
  if ($running.Count -or $files.Count -ne 2 -or @($files | Where-Object {$_.FullName -notin @($exe,(Join-Path $work 'report.json'))}).Count) {throw 'Retained files/process/mixed ownership'}
  $report.status='passed';$report.execution_stage='validated'
 }
} catch {$report.status='failed';$report.error=$_.Exception.Message;Capture-ProfileLines;throw} finally {
 try {
  $report.sources_after=@($sources | ForEach-Object {$now=Identity $_.path;if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes -or $now.mtime_utc -ne $_.mtime_utc) {throw 'Source identity changed'};$now})
  if ($created) {
   if ($exe -and (Test-Path -LiteralPath $exe)) {$report.executable_after=Identity $exe}
   if ($report.status -eq 'failed') {$report.failure_policy='no retry; keep bounded completed/partial JSON and child records; no temporary files created'}
   $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  }
 }finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8);completed_runs=$report.parsed_profile.runs_completed} | ConvertTo-Json -Depth 5}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;runtime=$report.runtime;compiler=$report.compiler;runtime_version=$report.runtime_version;capacity=$report.disk_before;capacity_plan=$report.capacity_plan;immutable_basis=$report.immutable_basis;environment=$report.environment} | ConvertTo-Json -Depth 8}

