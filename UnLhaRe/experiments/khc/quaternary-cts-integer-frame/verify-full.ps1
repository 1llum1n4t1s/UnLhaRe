[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-quaternary-cts-integer-frame-20261002'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins=@(
 @('../QUATERNARY_CTS_INTEGER_FRAME_CONTRACT_20261002.md','B813A1D3B41F40B615FA356411D0E1F923FA924231ADAC1FF9CB71BBD54122B1'),
 @('model.rs','BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9'),@('codec.rs','673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327'),@('e2e.rs','824DE9E08FA2EC069FE0D935EC7E2FE58EFD38FE813D5D49F545AD156AABE3E1'),@('FAILURE_PLAN.md','F06DFE8EF43DD10AE99DE118C7B40D5C18283C2469EE1191997336878C0DD4C3'),
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
$locks=[Collections.Generic.List[IO.FileStream]]::new();$sources=[Collections.Generic.List[object]]::new();$records=[Collections.Generic.List[object]]::new();$temporary=[Collections.Generic.List[object]]::new()
function Identity([string]$Path){[pscustomobject]@{path=[IO.Path]::GetFullPath($Path);sha256=(Get-FileHash -LiteralPath $Path).Hash;bytes=(Get-Item -LiteralPath $Path).Length}}
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
        $result=[pscustomobject]@{ file=$File; argv=$Arguments; cwd=$project; started=$started; status='completed'; exit=$process.ExitCode; stdout=$out.ToString().Trim(); stderr=$err.ToString().Trim(); elapsed_ms=$watch.Elapsed.TotalMilliseconds; error=$null }
        $records.Add($result)
        return $result
    } catch {
        $failure=$_.Exception.Message
        if ($started -and !$process.HasExited) {$process.Kill($true);$process.WaitForExit()}
        $exit=if ($started -and $process.HasExited) {$process.ExitCode}else {$null}
        $status=if ($started) {'interrupted'}else {'start-failed'}
        $records.Add([pscustomobject]@{file=$File;argv=$Arguments;cwd=$project;started=$started;status=$status;exit=$exit;stdout=(Bounded-Text $out.ToString());stderr=(Bounded-Text $err.ToString());elapsed_ms=$watch.Elapsed.TotalMilliseconds;error=$failure})
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
$exeReserve=1MB;$frameReserve=1MB+281;$reportReserve=512KB;$restoreReserve=2811006L;$tinyReserve=2KB
$peakReserve=$exeReserve+$frameReserve+$reportReserve+$restoreReserve+$tinyReserve
if ($peakReserve -ge 8MB -or $peakReserve -is [array]) {throw 'Peak scalar reserve mismatch'}
$created=$false;$exe=$null
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@();temporary=$temporary;parsed=@();comparison=$null;size_gate=$null;full_benchmark_allowed=$false;capacity_plan=@{max_bytes=8MB;retained_estimated_bytes=1280KB;exe_reserve_bytes=$exeReserve;frame_reserve_bytes=$frameReserve;report_reserve_bytes=$reportReserve;restore_reserve_bytes=$restoreReserve;tiny_reserve_bytes=$tinyReserve;peak_reserve_bytes=$peakReserve;scalar_preflight_evaluated=$true;note='pre/post guard, not OS write quota'};unverified=@('formal speed and CPU','holdout/categories','four native environments','product/API integration','general 8MiB input support','general extraction handle safety','heap/write/sync fault injection')}
function Save-Report {
 if (!$created) {return};$report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
 $json=$report | ConvertTo-Json -Depth 16;if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $reportReserve) {throw 'Report reserve exceeded'}
 [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json);$null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
function Temp([string]$Name,[string]$Purpose) {
 $path=Safe-Path (Join-Path $work $Name)
 if (!$path.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $path)) {throw 'Temporary ownership/no-overwrite'}
 $entry=[ordered]@{path=$path;purpose=$Purpose;deletion_condition='own explicit leaf, operation ended, no process/stream/link/mixed ownership';created=$false;deleted=$false;retained_reason=$null}
 $temporary.Add($entry);Save-Report;return $path
}
function Record-Temp([string]$Path) {foreach ($entry in $temporary) {if ($entry.path -eq $Path -and (Test-Path -LiteralPath $Path)) {$entry.created=$true;$entry.identity=Identity $Path}};Save-Report}
function Remove-Temps {
 $running=@(Get-Process | Where-Object {try {$_.Path -and $exe -and [IO.Path]::GetFullPath($_.Path) -eq [IO.Path]::GetFullPath($exe)}catch {$false}})
 $report.owned_codec_processes_at_cleanup=$running.Count;Save-Report
 if ($running.Count) {throw 'Owned codec process remains at cleanup'}
 foreach ($entry in $temporary) {
  $path=Safe-Path $entry.path
  if (!$path.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Cleanup outside owned root'}
  if (Test-Path -LiteralPath $path) {
   if (!(Get-Item -LiteralPath $path -Force).PSIsContainer) {
    $entry.identity=Identity $path;Save-Report
    # exclusive openで利用中/共有streamを拒否し、ledgerで既知のleafだけ削除する。
    $probe=[IO.File]::Open($path,'Open','ReadWrite','None');$probe.Dispose()
    $entry.children_stopped=$true;$entry.exclusive_leaf_check=$true;$entry.link_check=$true;$entry.mixed_ownership_check=$true
    & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $path -Root $work | Out-Null;$entry.deleted=!(Test-Path -LiteralPath $path)
    if (!$entry.deleted) {throw 'Temporary deletion failed'}
   }else {throw 'Temporary became directory'}
  }else {$entry.absent=$true}
 }
}
function Invoke-Audit([string]$Stage,[string[]]$Arguments) {
 $report.execution_stage=$Stage;$r=Child $exe $Arguments;Save-Report;Success $r
 if ($r.stderr) {throw "Unexpected stderr at $Stage"}
 $a=$r.stdout | ConvertFrom-Json
 $report.parsed+=@{stage=$Stage;audit=$a};Save-Report
 if ($a.status -ne 'passed' -or $a.full_benchmark_allowed -or $a.general_8MiB_input_supported) {throw "Audit scope mismatch: $Stage"}
 return $a
}
function Fixed-Stats($a) {
 $expected=@{runs=889227;primary=1762795;alphabet_symbols=257;plain_crc=433441561;rank_intervals=889227;length_intervals=889227;escape_bytes=742;input_limit=8388608;payload_limit=1048576;CTS_CAP=3825340}
 foreach ($name in $expected.Keys) {if ($null -eq $a.PSObject.Properties[$name] -or $a.$name -ne $expected[$name]) {throw "Fixed field mismatch: $name"}}
 if ($a.private_format -ne 'KHQCIP01' -or $a.grammar_digest -ne '58735a2b7383d755' -or $a.base_pool_digest -ne '9128444225deabce' -or $a.branches.Count -ne 2 -or $a.branches[0] -ne 2725772 -or $a.branches[1] -ne 1099568) {throw 'Fixed causal/base-pool mismatch'}
 $classes=@(889227,620240,1216305,889227,64372,145969)
 if ($a.class_observations.Count -ne 6) {throw 'Fixed class shape'}
 for ($j=0;$j -lt 6;$j++) {if ($a.class_observations[$j] -ne $classes[$j]) {throw 'Fixed class count'}}
 if (![double]::IsFinite([double]$a.cdf_entropy_bits) -or [Math]::Abs($a.cdf_entropy_bits-3788636.714502990) -gt 1e-4) {throw 'Fixed CDF entropy mismatch'}
 $prior=(Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-cts-integer-pool-opportunity-20261002/report.json') -Raw | ConvertFrom-Json).audit
 if ([Math]::Abs($a.cdf_entropy_bits-$prior.cdf_entropy_bits) -gt 1e-4) {throw 'Predecessor CDF mismatch'}
}
function Frame-Header([string]$Path) {
 $bytes=[IO.File]::ReadAllBytes($Path)
 $header=[ordered]@{magic=[Text.Encoding]::ASCII.GetString($bytes,0,[Math]::Min(8,$bytes.Length));frame_bytes=$bytes.Length;length=$null;primary=$null;alphabet=$null;payload_bytes=$null;plain_crc=$null;payload_crc=$null;header_crc=$null;header_bytes=$null}
 if ($bytes.Length -ge 36) {
  $names=@('length','primary','alphabet','payload_bytes','plain_crc','payload_crc','header_crc')
  for ($j=0;$j -lt 7;$j++) {$header[$names[$j]]=[BitConverter]::ToUInt32($bytes,8+4*$j)}
  $header.header_bytes=[long]$bytes.Length-[long]$header.payload_bytes
 }
 $report.frame_header=$header;Save-Report
 if ($header.magic -ne 'KHQCIP01' -or $header.length -ne 2811006 -or $header.primary -ne 1762795 -or $header.alphabet -ne 257 -or $header.plain_crc -ne 433441561 -or $header.header_bytes -lt 69 -or $header.header_bytes -gt 281 -or $header.payload_bytes -lt 5 -or $header.payload_bytes -gt 1MB) {throw 'Fixed private header fields'}
 return $header
}
function Compare-Bytes([string]$First,[string]$Second) {
 $record=[ordered]@{first=Identity $First;second=Identity $Second;compared_bytes=0L;equal=$false;first_mismatch=$null}
 $report.comparison=$record;Save-Report
 $x=[IO.File]::OpenRead($First);$y=[IO.File]::OpenRead($Second);$ab=[byte[]]::new(65536);$bb=[byte[]]::new(65536)
 try {
  while (($n=$x.Read($ab,0,$ab.Length)) -gt 0) {
   $m=0;while ($m -lt $n) {$z=$y.Read($bb,$m,$n-$m);if (!$z) {$record.first_mismatch=$record.compared_bytes+$m;Save-Report;throw 'Restore short'};$m+=$z}
   for ($j=0;$j -lt $n;$j++) {if ($ab[$j] -ne $bb[$j]) {$record.first_mismatch=$record.compared_bytes+$j;Save-Report;throw 'Restore byte mismatch'}}
   $record.compared_bytes+=$n
  }
  if ($y.ReadByte() -ne -1) {$record.first_mismatch=$record.compared_bytes;Save-Report;throw 'Restore trailing bytes'}
  $record.equal=$true;Save-Report
 }finally {$x.Dispose();$y.Dispose()}
 # 全byteを観測したrecordを先に保存してから長さ/SHA validatorへ進む。
 if ($record.compared_bytes -ne 2811006 -or $record.first.sha256 -ne $record.second.sha256) {throw 'Restore comparison identity/length mismatch'}
}
function Refusal([string]$Stage,[string[]]$Arguments,[string]$Reason,[string]$Absent='',[string]$Preserved='') {
 $report.execution_stage=$Stage;$r=Child $exe $Arguments;Save-Report
 $observation=[ordered]@{stage=$Stage;reason=$Reason;absent_path=$Absent;absent=(!$Absent -or !(Test-Path -LiteralPath $Absent));preserved_path=$Preserved;preserved=$true}
 if ($Preserved) {$bytes=[IO.File]::ReadAllBytes($Preserved);$observation.preserved=($bytes.Length -eq 16 -and [Linq.Enumerable]::SequenceEqual[byte]($bytes,[byte[]](0..15)))}
 $report.filesystem_observations+=@($observation);Save-Report
 if ($r.exit -eq 0 -or $r.stdout -or $r.stderr -notmatch [regex]::Escape($Reason) -or !$observation.absent -or !$observation.preserved) {throw "CLI refusal mismatch: $Stage"}
}
try {
 $null=Safe-Path $work
 if (Test-Path -LiteralPath $work) {throw 'Fresh root exists; no overwrite/retry'}
 foreach ($pin in $pins) {$path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0]));$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$id=Identity $path;if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"};$sources.Add($id)}
 if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
 foreach ($path in @($PSCommandPath,$compiler,$runtime)) {$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))}
 $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
 if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime pin mismatch'}
 $compiledSources=@('codec.rs','model.rs','e2e.rs','../quaternary-cts-integer-pool/fixed_math.rs','../quaternary-cts-integer-pool/integer_pool.rs','../quaternary-cts-q32/integer_cts.rs','../causal-bayes-sais/bwt.rs','../rejected-binary-mix/packed_alphabet.rs','../direct-token/multi_range.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
 foreach ($entry in @($sources | Where-Object {$_.path -in $compiledSources})) {
  $content=[IO.File]::ReadAllText($entry.path)
  if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b') {throw 'Unexpected include or extern crate'}
  $matches=[regex]::Matches($content,'(?m)^\s*(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
  if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{') {throw 'Unsupported module declaration'}
  foreach ($match in $matches) {$relative=if ($match.Groups[1].Success) {$match.Groups[1].Value}else {$match.Groups[2].Value+'.rs'};$resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($entry.path)) $relative));if ($resolved -notin $compiledSources) {throw "Unpinned graph edge: $resolved"};$report.imports+=@{source=$entry.path;resolved=$resolved}}
 }
 if ($compiledSources.Count -ne 9 -or $report.imports.Count -ne 8 -or @($report.imports | Where-Object {$_.source -ne $compiledSources[0]}).Count -or @($report.imports.resolved | Sort-Object -Unique).Count -ne 8) {throw 'Unexpected nine-source/eight-edge graph'}
 $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 8
 if (![BitConverter]::IsLittleEndian) {throw 'Fixed Windows little-endian host required for header audit'}
 if ($report.disk_before.used_bytes+$peakReserve -gt $report.disk_before.max_bytes) {throw 'Peak capacity reserve'}
 if ($Execute) {
  $null=New-Item -ItemType Directory -Path $work;$created=$true;$report.status='running';$report.execution_stage='compiler-version';$report.filesystem_observations=@()
  $version=Child $compiler @('--version');Save-Report;Success $version
  if ($version.stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)') {throw 'Compiler version mismatch'}
  $report.compiler_version=$version.stdout;$exe=Join-Path $work 'codec-o2-yes.exe';$report.execution_stage='build-once'
  $build=Child $compiler @((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe);Save-Report;Success $build
  $report.executable_before=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$report.execution_stage='exe-identity-saved';Save-Report
  if ($report.executable_before.bytes -gt $exeReserve) {throw 'EXE reserve'}
  $self=Invoke-Audit 'selfcheck' @('selfcheck')
  $expectedSelf=@{normal_cases=14;byte_roundtrips=14;canonical_cases=14;malformed_cases=30;model_rejection_named_cases=14;model_rejection_assertions=16;cap_exact_successes=1;LCG_seed=1831565813}
  foreach ($name in $expectedSelf.Keys) {if ($self.$name -ne $expectedSelf[$name]) {throw "Selfcheck fixed count: $name"}}
  if (!$self.CRC32_known_fixture -or $self.malformed.Count -ne 30 -or $self.heap_write_sync_fault_injection) {throw 'Selfcheck scope'}
  $input=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group'
  $frame=Join-Path $work 'all.khqc';$restore=Temp 'restore.tmp' 'fixed input full-byte restore comparison; delete after saved comparison'
  $encoded=Invoke-Audit 'fixed-encode' @('encode',$input,$frame)
  $report.frame=Identity $frame;Save-Report
  $header=Frame-Header $frame
  Fixed-Stats $encoded
  if ($header.payload_bytes -ne $encoded.payload_bytes -or $header.payload_crc -ne $encoded.payload_crc -or $header.plain_crc -ne $encoded.plain_crc) {throw 'Header/encode JSON mismatch'}
  if ($encoded.input_bytes -ne 2811006 -or $encoded.output_bytes -ne $report.frame.bytes -or $report.frame.bytes -gt $frameReserve) {throw 'Fixed frame size/identity'}
  $report.size_gate=($report.frame.bytes -le 483599);$report.actual_frame_bytes=$report.frame.bytes;Save-Report
  if ($encoded.size_gate -ne $report.size_gate) {throw 'Fixed primary actual size gate'}
  $decoded=Invoke-Audit 'fixed-decode' @('decode',$frame,$restore);Record-Temp $restore
  Compare-Bytes $input $restore
  Fixed-Stats $decoded
  if ($decoded.input_bytes -ne $report.frame.bytes -or $decoded.output_bytes -ne 2811006 -or $decoded.payload_crc -ne $encoded.payload_crc) {throw 'Fixed decode fields'}
  $canonical=Invoke-Audit 'fixed-canonical' @('canonical',$frame);Fixed-Stats $canonical
  if ($canonical.input_bytes -ne $report.frame.bytes -or $canonical.output_bytes -ne $report.frame.bytes -or $canonical.payload_crc -ne $encoded.payload_crc) {throw 'Fixed canonical fields'}
  $empty=Temp 'empty.input.tmp' 'CLI zero-byte input';[IO.File]::WriteAllBytes($empty,[byte[]]::new(0));Record-Temp $empty
  $emptyFrame=Temp 'empty.frame.tmp' 'CLI empty encode result';$zero=Invoke-Audit 'CLI-zero-encode' @('encode',$empty,$emptyFrame);Record-Temp $emptyFrame
  $emptyRestore=Temp 'empty.restore.tmp' 'CLI empty restore';$zeroRestore=Invoke-Audit 'CLI-zero-decode' @('decode',$emptyFrame,$emptyRestore);Record-Temp $emptyRestore
  $report.empty_roundtrip=@{input=Identity $empty;frame=Identity $emptyFrame;restore=Identity $emptyRestore;compared_bytes=0;equal=((Get-Item -LiteralPath $emptyRestore).Length -eq 0)};Save-Report
  if ($zero.input_bytes -ne 0 -or $zeroRestore.output_bytes -ne 0 -or !$report.empty_roundtrip.equal) {throw 'CLI zero-byte roundtrip'}
  $sentinel=Temp 'sentinel.output.tmp' 'existing 16B output no-clobber';[IO.File]::WriteAllBytes($sentinel,[byte[]](0..15));Record-Temp $sentinel
  Refusal 'CLI-encode-existing' @('encode',$empty,$sentinel) 'output create_new' '' $sentinel
  Refusal 'CLI-decode-existing' @('decode',$emptyFrame,$sentinel) 'output create_new' '' $sentinel
  $missing=Join-Path $work 'missing.source';$absentEncode=Temp 'missing-encode.output.tmp' 'must remain absent on missing input';$absentDecode=Temp 'missing-decode.output.tmp' 'must remain absent on missing input'
  Refusal 'CLI-encode-missing-source' @('encode',$missing,$absentEncode) 'input open' $absentEncode
  Refusal 'CLI-decode-missing-source' @('decode',$missing,$absentDecode) 'input open' $absentDecode
  $parent=Join-Path $work 'missing-parent'
  Refusal 'CLI-encode-missing-parent' @('encode',$empty,(Join-Path $parent 'encoded')) 'output create_new' (Join-Path $parent 'encoded')
  Refusal 'CLI-decode-missing-parent' @('decode',$emptyFrame,(Join-Path $parent 'restored')) 'output create_new' (Join-Path $parent 'restored')
  Refusal 'CLI-unknown' @('unknown') 'unknown operation'
  Refusal 'CLI-arguments' @('encode') 'usage: codec'
  $report.cli_filesystem_cases=10;$report.cli_filesystem_successes=2;$report.cli_filesystem_refusals=8;Save-Report
  Remove-Temps;Save-Report
  $report.executable_after=Identity $exe
  if ($report.executable_before.sha256 -ne $report.executable_after.sha256 -or $report.executable_before.bytes -ne $report.executable_after.bytes) {throw 'EXE identity changed'}
  $allowed=@($exe,$frame,(Join-Path $work 'report.json'))
  if (@(Get-ChildItem -LiteralPath $work -Force | Where-Object {$_.FullName -notin $allowed}).Count) {throw 'Unexpected retained artifact'}
  $report.status='passed';$report.execution_stage='validated'
 }
} catch {$report.status='failed';$report.error=$_.Exception.Message;throw} finally {
 try {
  $report.sources_after=@($sources | ForEach-Object {$now=Identity $_.path;if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes) {throw 'Source identity changed'};$now})
  if ($created) {
   if ($exe -and (Test-Path -LiteralPath $exe)) {$report.executable_after=Identity $exe}
   if ($report.status -eq 'failed') {$report.failure_temporary_policy='bounded child/parsed/identity/comparison evidence retained in report; idle owned temporary leaves deleted';Save-Report;Remove-Temps}
   $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  }
 }finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;size_gate=$report.size_gate;actual_frame_bytes=$report.actual_frame_bytes;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8)} | ConvertTo-Json -Depth 5}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;runtime=$report.runtime;compiler=$report.compiler;runtime_version=$report.runtime_version;capacity=$report.disk_before;capacity_plan=$report.capacity_plan} | ConvertTo-Json -Depth 5}

