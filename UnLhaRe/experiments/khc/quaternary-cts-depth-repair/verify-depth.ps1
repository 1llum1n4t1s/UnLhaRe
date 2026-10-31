[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference='Stop'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$runtime=(Get-Process -Id $PID).Path
$expectedRuntime='C:/Users/IMT/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$expectedRuntimeSha='362A356CE7F0940EC74F73A8FC2C990A2CC24A38A11C90BBD8ECA947110AD139'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$originalRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../quaternary-cts-depth'))
$work=Join-Path $project 'build/khc-quaternary-cts-depth-repair-20261003'
$guard=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../disk-budget.ps1'))
$pins=@(
 @('../QUATERNARY_CTS_PHASE_PROFILE_CONTRACT_20261002.md','128DFCF78987C1F3F9F8960DF452B905A4AD4C26CE1CCA6FEE1630FEB81BA80A'),
 @('../quaternary-cts-phase-profile/profile.rs','7FA9557A7F5438FB18366E0D9554296919EAE929AE2508DDF0A4E6DB6F0E0092'),
 @('../quaternary-cts-phase-profile/timing.rs','7E0E44040DCFB0739EAEB8C3810C6E042644FBF10FE61D332C1322E5933C15DB'),
 @('../quaternary-cts-phase-profile/model.rs','F599961210F42C6B2DE9CF07146DE6CF9118858CA4119B3AA3D97B4EFB6D6F40'),
 @('../quaternary-cts-phase-profile/old_wire.rs','292417BF89C57CDEAD4D18E80015AB54AF17C51832F13D4D69BC70C4595F3117'),
 @('../quaternary-cts-phase-profile/pow2_wire.rs','22BB6FD2963E9E403321567767F6A5707B76327B59482DC2F289D99A03CB021A'),
 @('../quaternary-cts-phase-profile/FAILURE_PLAN.md','02BC42C61925B43695C6195B336C818504F718EABE331424FC542792B3511B0E'),
 @('../quaternary-cts-pow2/verify-full.ps1','F8B59FD01A776A1567A78AA16779B1BB9562C98C68ABD3A02A8CA1F21959C56F'),
 @('../QUATERNARY_CTS_POW2_RESULT_20261002.md','331E19239402C3B600F23E7F82531E4E3E52D0AB4EDC22E4E5311B5C7E933237'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/report.json','D5F40FA03A3987605432D3E430F5BAAEA7C47AB628E046CC27723085B7D8D777'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/codec-o2-yes.exe','92136CA3BE32D64768E5510ACB1AA2CD103B0B0608DFD7BD22EBE358F4F54F7B'),
 @('../../../build/khc-quaternary-cts-pow2-20261002/all.khqc','9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD'),
 @('../QUATERNARY_CTS_POW2_CONTRACT_20261002.md','3D942A6A32F267B469E55999E83E84DD9EFCA1B46B3442A589899B8FCA9C0ED0'),
 @('../QUATERNARY_CTS_INTEGER_FRAME_CONTRACT_20261002.md','B813A1D3B41F40B615FA356411D0E1F923FA924231ADAC1FF9CB71BBD54122B1'),
 @('../quaternary-cts-pow2/integer_cts.rs','DCFD5CF8F9D408174840194CA3D0AF38F90EB938172C5A51EA2B85BA90427B28'),
 @('../quaternary-cts-pow2/comparison.rs','248400D4F1954F4CB4A3F7D759A26F4AD51C12FBCB3EA0CBE8021CE4AF43D24C'),
 @('../quaternary-cts-integer-frame/codec.rs','673E3759DDCB2EC17C2FB6376AB8A95F06EFE4238242CB2DD1E677E1576C3327'),
 @('../quaternary-cts-integer-frame/verify-full.ps1','C1AB88073C433560F4F73D06A9EC10E051E1EF90809F10F6A8952255C6B92D0E'),
 @('../quaternary-cts-integer-frame/FAILURE_PLAN.md','F06DFE8EF43DD10AE99DE118C7B40D5C18283C2469EE1191997336878C0DD4C3'),
 @('../QUATERNARY_CTS_INTEGER_FRAME_RESULT_20261002.md','E042DD5807C35DC6654EEA431709081B204D3A1FCB177189AF94CA6607963C4F'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/report.json','18B106BDB873BB5B1C82EBF7F7B9B6EBB17209C8E137D9332320941D0CBECB98'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/all.khqc','9867AB88CD27AE48174C9C1E9FAC65BEEE6D95C95BDE8C53DB2F0E988653BFAD'),
 @('../../../build/khc-quaternary-cts-integer-frame-20261002/codec-o2-yes.exe','1E47B92B840F7211B981B367F15B216B8DAA03811C78C3261B55F37CA1765B95'),
 @('../quaternary-cts-integer-frame/model.rs','BB7DAFC75AF4763C553A15EC8619E9641FDBC6C53CC206B7DAB01B02D97547B9'),
 @('../quaternary-cts-pow2/codec.rs','4D4FF38557860B9DF99F20F2CBC11D9B99D9C1D9D2593D071C1D936CDC60C0CE'),
 @('../quaternary-cts-integer-frame/e2e.rs','824DE9E08FA2EC069FE0D935EC7E2FE58EFD38FE813D5D49F545AD156AABE3E1'),
 @('../quaternary-cts-pow2/FAILURE_PLAN.md','2831CFE2D4430A6D76C3740F1C9BF1A64E389EFB0997A25BFECEDAA8F8D0A101'),
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
 @('../disk-budget.ps1','F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'),
 @('../quaternary-cts-phase-profile/verify-profile.ps1','178C0D5B7F73A5C96D9EAF75B1AB624184CDCF30B946996E865D4D450E1B4260'),
 @('../QUATERNARY_CTS_PHASE_PROFILE_RESULT_20261002.md','697387D2FAD8388AAC7E3049922ABEDA810E8A7097FA4D1178F5DF45A88713A8'),
 @('../../../build/khc-quaternary-cts-phase-profile-20261002/report.json','359A98D303CC898354AB346BD0A3EAB896B49D03C721EEAD46A3CA4A692B0B7F'),
 @('../../../build/khc-quaternary-cts-phase-profile-20261002/profile-o2-yes.exe','FC938C42314383EC09EB35DA032AFDDD99A084F0E4A59B28C8805AF9193ECD2C'),
 @('../QUATERNARY_CTS_KT64_CONTRACT_20261002.md','12C7F578C902D58CEF8438022513DFA63F5A587410C1BB55AD8FDDEC83E87167'),
 @('../quaternary-cts-kt64/comparison.rs','C3A9CD3F95A9D4E64960C13740D0AB7B37304C6A390B440FB045F16F32DA6267'),
 @('../quaternary-cts-kt64/FAILURE_PLAN.md','3BB1D03CC372DCA8E92C00CCB3AA7AE36D922340363FD67DFBB83C59A305F22B'),
 @('../quaternary-cts-kt64/integer_cts.rs','90533959E33165C93752D67F0A6B7E8C925F10A9E6AFEE1E03D60F4F25E7D52B'),
 @('../quaternary-cts-kt64/model.rs','5A69F5A19035A18489D59DF82FD2DBFB423817CCF16414888F2C45BE35271889'),
 @('../quaternary-cts-kt64/new_wire.rs','C49EA2593C42A0899E9A50D7E8F59365163F014D4F6CBEE772559385DCC77838'),
 @('../quaternary-cts-kt64/old_wire.rs','5DD0E25F0FDE6179F209E8245A73C0817ABBFEFC1B490121BB94E76D2BAAC5A8'),
 @('../quaternary-cts-kt64/profile.rs','4A3ED806210CA5E617CE21FB131B8B81A4FF8208FE8FA0B161F10E5251C9C81B'),
 @('../quaternary-cts-kt64/verify-kt64.ps1','D8EF93A95585B1F7264830B3C4C62CEB9F14B8DAC26ED9EBCE47FBA0E52CA660'),
 @('../QUATERNARY_CTS_KT64_RESULT_20261002.md','F7201905871A5B87314E232D0407A4C74B1A349C16B18CE7547E383D4CCC5DFB'),
 @('../../../build/khc-quaternary-cts-kt64-20261002/report.json','C88FBE8B6FD30B68D013329C3A34D7BEA09A456129F5D06DBF9AF1A72959398B'),
 @('../../../build/khc-quaternary-cts-kt64-20261002/profile-o2-yes.exe','2B22BC6C5BFB39D9307D86D722A185632B61CD4F28D9098F9FFABBCAF6A57040'),
 @('../QUATERNARY_CTS_SEALED_CONTRACT_20261003.md','622867411E6A90CDD491D3EF96DA7640D20F47015B2AF29FCCF4521DFB6F0B9D'),
 @('../quaternary-cts-sealed/comparison.rs','72E4991A8DB612AFC5D11384665FC340ADDF6E55C133A6CFB38B657BC5A1ED60'),
 @('../quaternary-cts-sealed/FAILURE_PLAN.md','056FD496B2AD260A29300829C097C52D2408A930B743C61AF514A6FC62BDCC9E'),
 @('../quaternary-cts-sealed/integer_cts.rs','E953BBA82FE27C64C1588EE1E6D3A4C33E64E1DB28BB3E75A25ADF506601E496'),
 @('../quaternary-cts-sealed/model.rs','4A59EDF0545EC2D5E57CEC55396453A14E784D152A50BA0F38A7F4A7904D5FCA'),
 @('../quaternary-cts-sealed/new_wire.rs','E364C2F94AF4DE4C576635172A057C8D71FF0867F18B1A59EE2359BEDC4F7B60'),
 @('../quaternary-cts-sealed/old_wire.rs','ABF3B0622BDC3402ABF1BAA4A429904648553582662DA4D48FFA08909E8AA781'),
 @('../quaternary-cts-sealed/profile.rs','5B4466544B07A38D30F9D1959C69038CF2157C4619CB36FB9BED5E997623560F'),
 @('../quaternary-cts-sealed/verify-sealed.ps1','1C59D55BCE88D9EFD77A15A2DD6CC57E6649BE80011EA33A15E0254BE90AC816'),
 @('../QUATERNARY_CTS_DEPTH_CONTRACT_20261003.md','3B2A9E1CA7DF9FDE77DFECCD36CA93D7E513392ECA648B8EC9627180574450F3'),
 @('../QUATERNARY_CTS_SEALED_RESULT_20261003.md','E69CDB4BFE47A9BF69DA131798FCE5D3FC018E4427B75BB4941C30CD8BF5820C'),
 @('../../../build/khc-quaternary-cts-sealed-20261003/report.json','B2EA272A74F5484993A2DA0A6396CC620A6BD6EA697868AB5DA99B24BE24237B'),
 @('../../../build/khc-quaternary-cts-sealed-20261003/profile-o2-yes.exe','FF3EA779B4A28A4EBE06465430B6F8747F7CE5475C4B76623199FA1E89E016F2'),
 @('../quaternary-cts-depth/integer_cts.rs','E01F168CA9EEC738D9B0919BEF7574572219FDF180E2267A6F83267C8B26703D'),
 @('../quaternary-cts-depth/model.rs','AB4BBAC034472A6A83C1CCC39F29F37433A695FDA1FD5C89DBE6B63378575C12'),
 @('../quaternary-cts-depth/codec.rs','773493C397578A2E387FE0975F58CDDC03000CC71E9AC0AEE6453DA3ABCAFA4A'),
 @('../quaternary-cts-depth/e2e.rs','F3271691DE25F9B4C489B935A9772120018B33F22A8A29278860895017C24E31'),
 @('../quaternary-cts-depth/probe.rs','3616355EB0184BDCC9EDE99FB97DFAA8EDA1C14B188290E0B1E922695FB477DB'),
 @('../quaternary-cts-depth/comparison.rs','9294DEFD524F57185CAEB20D3BF4BEA8C654C6879DB76A3273496C46A581AE71'),
 @('../quaternary-cts-depth/FAILURE_PLAN.md','36F8694E673D91BBDF2978053C56B8D37ADC4A6B99709478F916D381B28A0203'),
 @('../quaternary-cts-depth/verify-depth.ps1','A4C50C09A0C7EA5DB9337704F35315E1402C67609ADEBFFDE3737DB32D73F343'),
 @('../QUATERNARY_CTS_DEPTH_REPAIR_CONTRACT_20261003.md','029D352BE256560D3DF641F7FC31D18390CD0E2A71F20C7FB877498A22025350'),
 @('../../../build/khc-quaternary-cts-depth-20261003/report.json','9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0'),
 @('probe.rs','59568EB04D772E65F20A52AB86184BF9E6DD2003744173223305EF61C4962E7D'),
 @('FAILURE_PLAN.md','743845A1D0E5DDB8C343FAC49C49FC9293AEDBD01A2539C9C2E364F9055BAA96')
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
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@();sweep_lines=@();parsed_sweep=$null;parsed_compare=$null;parsed_selfcheck=$null;temporary_created=$false;full_benchmark_allowed=$false;capacity_plan=@{max_bytes=8MB;retained_estimated_bytes=1280KB;exe_reserve_bytes=$exeReserve;report_reserve_bytes=$reportReserve;peak_reserve_bytes=$peakReserve;scalar_preflight_evaluated=$true;note='pre/post guard, not OS write quota'};unverified=@('formal codec speed and CPU15%','holdout/categories','four native environments','product/API integration','formal machine CPU observer');timing_limitations=@('clock overhead','code placement','CPU scheduling');disk_frame_restore_input_copy_created=$false}
function Save-Report {
 if (!$created) {return};$report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
 $json=$report | ConvertTo-Json -Depth 20
 if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $reportReserve) {throw 'Report reserve exceeded'}
 [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json);$null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
function Capture-SweepLines {
 if (!$exe) {return}
 $child=@($records | Where-Object {$_.file -eq $exe -and $_.argv.Count -eq 3 -and $_.argv[0] -eq 'sweep'} | Select-Object -Last 1)
 if (!$child.Count) {return}
 $report.sweep_lines=@()
 foreach ($line in ($child[0].stdout -split '\r?\n')) {
  if (!$line) {continue}
  try {$parsed=$line | ConvertFrom-Json -DateKind String;$report.sweep_lines+=@{raw=$line;parsed=$parsed;parse_error=$null}}
  catch {$report.sweep_lines+=@{raw=$line;parsed=$null;parse_error=$_.Exception.Message}}
 }
 $final=@($report.sweep_lines | Where-Object {$_.parsed -and $_.parsed.kind -eq 'final'} | Select-Object -Last 1)
 if ($final.Count) {$report.parsed_sweep=$final[0].parsed}
 Save-Report
}
function Same-Time($A,$B) {return [DateTimeOffset]::Parse([string]$A).UtcTicks -eq [DateTimeOffset]::Parse([string]$B).UtcTicks}
function Immutable-Basis {
 $old=Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-cts-phase-profile-20261002/report.json') -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 48 -or $old.sources_after.Count -ne 48) {throw 'Immutable prior basis shape/status'}
 $identities=@()
 for ($j=0;$j -lt 48;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable prior source basis mismatch'}
  $identities+=@($now)
 }
 $report.immutable_basis=@{status='passed';sources_checked=48;identities=$identities;prior_report_sha256='359A98D303CC898354AB346BD0A3EAB896B49D03C721EEAD46A3CA4A692B0B7F';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-KT64-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-kt64-20261002/report.json'
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 60 -or $old.sources_after.Count -ne 60 -or $old.profile_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.local_probe_validated -ne $true) {throw 'Immutable KT64 status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 60) {throw 'Duplicate prior KT64 source paths'}
 $identities=@()
 for ($j=0;$j -lt 60;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable KT64 source mismatch: $($before.path)"}
  $identities+=@($now)
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable KT64 EXE mismatch'}
 $report.immutable_kt64_basis=@{status='passed';sources_checked=60;identities=$identities;executable=$now;prior_report_sha256='C88FBE8B6FD30B68D013329C3A34D7BEA09A456129F5D06DBF9AF1A72959398B';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Sealed-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-sealed-20261003/report.json'
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 72 -or $old.sources_after.Count -ne 72 -or $old.profile_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.snapshot_comparison_validated -ne $true) {throw 'Immutable sealed status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 72) {throw 'Duplicate prior sealed source paths'}
 $identities=@()
 for ($j=0;$j -lt 72;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable sealed source mismatch: $($before.path)"}
  $identities+=@($now)
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable sealed EXE mismatch'}
 $report.immutable_sealed_basis=@{status='passed';sources_checked=72;identities=$identities;executable=$now;prior_report_sha256='B2EA272A74F5484993A2DA0A6396CC620A6BD6EA697868AB5DA99B24BE24237B';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Depth-Failure {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-depth-20261003/report.json'
 $priorIdentity=Identity $priorPath
 if ($priorIdentity.sha256 -ne '9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0' -or $priorIdentity.bytes -ne 124513) {throw 'Immutable depth failure report identity'}
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'failed' -or $old.execution_stage -ne 'build-once' -or $old.sources.Count -ne 84 -or $old.sources_after.Count -ne 84 -or $old.error -notmatch 'error\[E0432\]: unresolved import .crate::integer_cts.' -or $old.records.Count -ne 8) {throw 'Immutable depth failure status/shape/cause'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 84) {throw 'Duplicate failed depth source paths'}
 $identities=@()
 for ($j=0;$j -lt 84;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable failed depth source mismatch: $($before.path)"}
  $identities+=@($now)
 }
 $compile=@($old.records | Where-Object {[IO.Path]::GetFullPath($_.file) -eq [IO.Path]::GetFullPath($compiler) -and $_.argv.Count -gt 1})
 $version=@($old.records | Where-Object {[IO.Path]::GetFullPath($_.file) -eq [IO.Path]::GetFullPath($compiler) -and $_.argv.Count -eq 1 -and $_.argv[0] -eq '--version'})
 $cli=@($old.records | Where-Object {$_.argv.Count -and $_.argv[0] -in @('compare-snapshot','selfcheck','sweep')})
 $unexpected=@($old.records | Where-Object {[IO.Path]::GetFileName($_.file) -notin @('rustfmt.exe','rustc.exe')})
 $oldWork=Safe-Path (Join-Path $project 'build/khc-quaternary-cts-depth-20261003')
 $oldExe=Join-Path $oldWork 'depth-o2-yes.exe'
 if ($compile.Count -ne 1 -or $compile[0].exit -ne 1 -or $compile[0].status -ne 'completed' -or $compile[0].stderr -notmatch 'error\[E0432\]: unresolved import .crate::integer_cts.' -or $compile[0].argv[0] -ne (Join-Path $originalRoot 'probe.rs') -or $compile[0].argv[-2] -ne '-o' -or $compile[0].argv[-1] -ne $oldExe -or $version.Count -ne 1 -or $version[0].exit -ne 0 -or $version[0].stdout -ne 'rustc 1.98.1 (48a229cea 2026-09-01)' -or $cli.Count -ne 0 -or $unexpected.Count -ne 0 -or $old.executable_before -or $old.executable_after -or (Test-Path -LiteralPath $oldExe)) {throw 'Immutable failed compile/CLI0/EXE absent proof'}
 $files=@(Get-ChildItem -LiteralPath $oldWork -Force)
 if ($files.Count -ne 1 -or $files[0].FullName -ne $priorPath -or $files[0].PSIsContainer -or ($files[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {throw 'Immutable failed root mixed ownership'}
 $report.immutable_depth_failure=@{status='passed';sources_checked=84;identities=$identities;report_identity=$priorIdentity;compile_calls=1;compile_exit=1;compile_error='E0432 unresolved crate::integer_cts';candidate_CLI_calls=0;executable_absent=$true;retained_files=1;prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Parse-PowerShell([string]$Path) {
 $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 if ($errors.Count) {throw "PowerShell parse failure: $Path : $($errors[0].Message)"}
}
function Capture-Single($Child,[string]$Name) {
 $report[$Name]=@{raw=$Child.stdout;parsed=$null;parse_error=$null}
 try {$report[$Name].parsed=$Child.stdout | ConvertFrom-Json -DateKind String}catch {$report[$Name].parse_error=$_.Exception.Message}
 Save-Report
}
function Require-Fields($Object,$Expected,[string]$Scope) {
 foreach ($name in $Expected.Keys) {if ($null -eq $Object.$name -or $Object.$name -ne $Expected[$name]) {throw "$Scope fixed field: $name"}}
}
function Rust-Syntax {
 $formatter=Safe-Path (Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe')
 $locks.Add([IO.File]::Open($formatter,'Open','Read','Read'))
 $before=Identity $formatter;$checks=@()
 foreach ($name in @('integer_cts.rs','model.rs','codec.rs','e2e.rs','comparison.rs','probe.rs')) {
  $source=if ($name -eq 'probe.rs') {Join-Path $PSScriptRoot $name}else {Join-Path $originalRoot $name}
  $syntax=Child $formatter @('--edition','2024','--config','skip_children=true','--emit','stdout',$source)
  $bytes=[Text.Encoding]::UTF8.GetByteCount($syntax.stdout)
  Success $syntax
  if ($syntax.stderr -or $bytes -eq 0) {throw "Rust syntax failure or empty formatter output: $name"}
  # 書き戻さず構文だけ検証。整形済みsourceは証拠へ重複保存しない。
  $syntax.stdout='';$syntax | Add-Member -NotePropertyName syntax_stdout_discarded_bytes -NotePropertyValue $bytes
  $checks+=@{source=$source;status='passed';formatted_stdout_bytes=$bytes;source_rewritten=$false;type_checked=$false}
 }
 $after=Identity $formatter
 if ($before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or $before.mtime_utc -ne $after.mtime_utc) {throw 'Rustfmt identity changed'}
 $report.rust_syntax=@{status='passed';checked_sources=6;formatter_before=$before;formatter_after=$after;checks=$checks;mode='rustfmt stdout, skip_children=true, no write';type_execution_verified=$false}
}
function Require-Array($Actual,$Expected,[string]$Scope) {
 if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) {throw "$Scope array shape"}
 for ($j=0;$j -lt $Expected.Count;$j++) {if ($null -eq $Actual[$j] -or $Actual[$j] -ne $Expected[$j]) {throw "$Scope array value at $j"}}
}
function Validate-Compare {
 $all=$report.parsed_compare.parsed
 if (!$all -or $report.parsed_compare.parse_error) {throw 'Depth comparison JSON'}
 Require-Fields $all @{status='passed';operation='depth-compare';constructor_rejections=2;compact_shape_cases=60;depth_success_cases=30;depth_rejection_cases=993;depth_failed_prediction_cases=60;pure_prediction_cases=5;proof_method='full nodes/history/observations and RawSnapshot direct comparisons'} 'Depth comparison'
 Require-Array $all.depths @(0,1,2,4,8) 'Depth comparison order'
 $a=$all.sealed
 Require-Fields $a @{status='passed';operation='compare-snapshot';LCG_seed=1831565813;legal_sequence_steps=384;lifecycle_successes=3;valid_modified_successes=3;modified_preparation_successes=1;cap_exact_successes=1;success_cases=392;visible_tamper_rejections=167;stale_rejections=1;class_cap_rejections=1;node_cap_rejections=9;invalid_current_rejections=18;dual_invalid_rejections=18;early_guard_rejections=6;current_guard_priority_rejections=3;rejection_cases=223;failed_prediction_cases=22;success_all_state_comparisons=392;rejection_before_after_comparisons=446;failed_predict_before_after_comparisons=44;proof_method='full nodes/history/observations direct comparisons';diagnostic_only=$true;formal_speed_CPU_verified=$false;full_benchmark_allowed=$false;general_8MiB_input_supported=$false;local_timing_added=$false} 'Sealed comparison'
 if ($a.old_snapshot_bytes -le 0 -or $a.new_snapshot_bytes -ne $a.old_snapshot_bytes -or $a.node_storage_bytes_per_CTS -ne 12582864 -or $a.digest -notmatch '^[0-9a-f]{16}$' -or $a.reason_summary.Count -ne 8) {throw 'Sealed snapshot size/digest/reason shape'}
 $reasons=@('stale or modified snapshot','invalid prefix','invalid observation','class update cap','node update cap','invalid kernel depth/leaf','kernel weight','raw observation cap')
 $counts=@(166,2,3,4,9,3,17,19)
 for ($j=0;$j -lt 8;$j++) {if ($a.reason_summary[$j].reason -ne $reasons[$j] -or $a.reason_summary[$j].cases -ne $counts[$j]) {throw 'Sealed comparison reason exact counts'}}
 if ($all.records.Count -ne 5) {throw 'Depth comparison record shape'}
 $depths=@(0,1,2,4,8);$nodes=@(1,5,21,341,87381);$storage=@(144,720,3024,49104,12582864);$refusals=@(183,188,194,204,224);$failed=@(6,8,10,14,22)
 for ($i=0;$i -lt 5;$i++) {
  $depth=$depths[$i];$r=$all.records[$i];$priority=2+[int]($depth -ge 2)
  Require-Fields $r @{depth=$depth;success_cases=6;rejection_cases=$refusals[$i];failed_prediction_cases=$failed[$i];pure_prediction_cases=1;visible_tamper_rejections=167;foreign_depth_rejections=1;legal_rebased_foreign_successes=1;cap_exact_successes=1;node_cap_rejections=($depth+1);current_guard_priority_rejections=$priority;node_count=$nodes[$i];node_storage_bytes=$storage[$i];rejection_before_after_comparisons=$refusals[$i]} "Depth $depth comparison"
  if ($r.digest -notmatch '^[0-9a-f]{16}$' -or $r.reason_summary.Count -ne 8) {throw 'Depth digest/reasons'}
  $counts=@(167,2,3,4,($depth+1),$(if ($depth -eq 0) {4}else {3}),$(if ($depth -eq 0) {0}else {2*$depth+1}),(2*$depth+2+[int]($depth -ge 2)))
  for ($j=0;$j -lt 8;$j++) {if ($r.reason_summary[$j].reason -ne $reasons[$j] -or $r.reason_summary[$j].cases -ne $counts[$j]) {throw "Depth $depth exact reason at $j"}}
 }
 $report.snapshot_comparison_validated=$true
 $report.adoption='parent chooses correct size-passing candidates for same-condition ABBA; no formal speed or improvement-rate claim'
}
function Validate-Selfcheck {
 $all=$report.parsed_selfcheck.parsed
 if (!$all -or $report.parsed_selfcheck.parse_error) {throw 'Depth selfcheck JSON'}
 Require-Fields $all @{status='passed';operation='depth-selfcheck';normal_cases=70;byte_roundtrips=70;canonical_cases=70;malformed_cases=165;short_depth_header_checks=20;model_rejection_named_cases=70;model_rejection_assertions=80;cap_exact_successes=5} 'Depth selfcheck totals'
 Require-Array $all.depths @(0,1,2,4,8) 'Selfcheck order'
 if ($all.records.Count -ne 5) {throw 'Selfcheck record shape'}
 $names=@('short_header','old_magic','bad_magic','input_length','primary_field','alphabet_zero','alphabet_over','payload_short','payload_quota','payload_derived_bound','header_crc','payload_crc','plain_crc','metadata_padding','metadata_sentinel','metadata_width','metadata_rank','range_prefix','range_gap','range_truncated','range_trailing','range_termination','sentinel_count','primary_sentinel','lf_cycle','active_early','active_remaining','escape_noncanonical','escape_fourbytes','escape_remaining','unsupported_depth9','unsupported_depth_max','depth_crc')
 $reasons=@('bad frame magic/header','bad frame magic/header','bad frame magic/header','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','payload exceeds transformed bound','header CRC mismatch','payload CRC mismatch','plain length/CRC mismatch','packed alphabet high bitmap padding nonzero','packed alphabet sentinel 0 missing','packed alphabet rank byte width not canonical','packed alphabet rank outside factorial','invalid range prefix','range rounding gap','truncated range stream','trailing range bytes','noncanonical range termination','sentinel count','invalid primary sentinel','LF cycle inconsistent','active list exhausted before declared length','active list not empty at end','noncanonical length escape','length escape exceeds four bytes','run length outside remaining bound','unsupported CTS depth','unsupported CTS depth','header CRC mismatch')
 $depths=@(0,1,2,4,8)
 for ($i=0;$i -lt 5;$i++) {
  $a=$all.records[$i]
  Require-Fields $a @{depth=$depths[$i];status='passed';operation='selfcheck';normal_cases=14;byte_roundtrips=14;canonical_cases=14;malformed_cases=33;short_depth_header_checks=4;model_rejection_named_cases=14;model_rejection_assertions=16;cap_exact_successes=1;CRC32_known_fixture=$true;LCG_seed=1831565813;general_8MiB_input_supported=$false;full_benchmark_allowed=$false;heap_write_sync_fault_injection=$false} 'Selfcheck'
  if ($a.malformed.Count -ne 33 -or $a.model_state_comparison -ne 'all base values and totals, pool weights, CTS raw and weights, histories, observations, serial and audit values directly') {throw 'Selfcheck rejection evidence'}
  for ($j=0;$j -lt 33;$j++) {if ($a.malformed[$j].name -ne $names[$j] -or $a.malformed[$j].reason -ne $reasons[$j] -or $null -eq $a.malformed[$j].frame_bytes -or $a.malformed[$j].frame_bytes -lt 0) {throw 'Malformed named exact rejection'}}
 }
 $report.selfcheck_validated=$true
}
function Validate-Stats($Stats,[int]$Depth) {
 $nodes=@{0=1;1=5;2=21;4=341;8=87381};$storage=@{0=144;1=720;2=3024;4=49104;8=12582864}
 Require-Fields $Stats @{depth=$Depth;node_count=$nodes[$Depth];node_storage_bytes=$storage[$Depth];magic='KHQCID01';header_crc_covers_depth=$true;plain_crc=433441561;runs=889227;primary=1762795;alphabet_symbols=257;rank_intervals=889227;length_intervals=889227;escape_bytes=742;grammar_digest='58735a2b7383d755'} 'Causal stats'
 Require-Array $Stats.branches @(2725772,1099568) 'Causal branches'
 Require-Array $Stats.class_observations @(889227,620240,1216305,889227,64372,145969) 'Causal class observations'
 if ($null -eq $Stats.payload_bytes -or $Stats.payload_bytes -lt 5 -or $Stats.payload_bytes -gt 1MB -or $Stats.header_bytes -ne 285 -or $Stats.frame_bytes -ne $Stats.header_bytes+$Stats.payload_bytes -or $Stats.frame_bytes -gt 1MB+285 -or $null -eq $Stats.header_crc -or $Stats.header_crc -lt 0 -or $Stats.header_crc -gt [uint32]::MaxValue -or $null -eq $Stats.payload_crc -or $Stats.payload_crc -lt 0 -or $Stats.payload_crc -gt [uint32]::MaxValue -or $Stats.base_pool_digest -notmatch '^[0-9a-f]{16}$' -or $null -eq $Stats.cdf_entropy_bits -or ![double]::IsFinite([double]$Stats.cdf_entropy_bits) -or $Stats.cdf_entropy_bits -lt 0) {throw 'Depth frame/audit bounds'}
 if ($Depth -eq 8) {
  Require-Fields $Stats @{frame_bytes=474734;header_bytes=285;payload_bytes=474449;payload_crc=3589341169;base_pool_digest='9128444225deabce'} 'Depth8 fixed stats'
  if ([Math]::Abs($Stats.cdf_entropy_bits-3788636.714502990) -gt 1e-4) {throw 'Depth8 CDF entropy'}
 }
}
function Validate-Sweep {
 $a=$report.parsed_sweep
 if (!$a -or $report.sweep_lines.Count -ne 6 -or @($report.sweep_lines | Where-Object {$_.parse_error}).Count) {throw 'Sweep JSON shape'}
 Require-Fields $a @{kind='final';status='passed';operation='depth-sweep';runs_completed=5;encode_calls=5;decode_calls=5;plain_comparisons=5;stats_comparisons=5;expected_restored_bytes=2811006;input_read_attempts=1;input_reads=1;baseline_read_attempts=1;baseline_reads=1;warmup_runs=0;additional_repeats=0;inner_timers=$false;full_input_canonical_reencoded=$false;disk_frames_created=$false;disk_restores_created=$false;diagnostic_only=$true;formal_speed_CPU_verified=$false;full_benchmark_allowed=$false;general_8MiB_input_supported=$false;timing_scope='encode/decode calls only; excludes JSON/stats formatting/comparison/drop';next_step='correct size-passing candidates only for same-condition ABBA; parent chooses'} 'Sweep'
 Require-Array $a.depth_order @(8,4,2,1,0) 'Sweep order'
 Require-Array $a.timing_limitations @('fixed depth order','single sample','code placement','CPU scheduling') 'Sweep limitations'
 if ($a.error -or $a.records.Count -ne 5 -or $report.sweep_lines[5].parsed.kind -ne 'final') {throw 'Sweep final/error shape'}
 $report.byte_comparisons=@()
 foreach ($r in $a.records) {$report.byte_comparisons+=@{kind='plain';depth=$r.depth;expected_bytes=2811006;matched_bytes=$r.matched_plain_bytes;equal=$r.plain_equal;bridge_field_matched_bytes=$r.bridge_field_matched_bytes;bridge_metadata_payload_matched_bytes=$r.bridge_metadata_payload_matched_bytes;error=$r.error}}
 Save-Report
 $order=@(8,4,2,1,0);$gateCount=0;$passing=@()
 for ($j=0;$j -lt 5;$j++) {
  $r=$a.records[$j];$progress=$report.sweep_lines[$j].parsed;$depth=$order[$j]
  Require-Fields $r @{index=$j;depth=$depth;status='passed';encode_calls=1;decode_calls=1;stats_equal=$true;cdf_compared_as_bits=$true;matched_plain_bytes=2811006;plain_equal=$true;size_gate_limit_bytes=483599;bridge_field_matched_bytes=$(if ($depth -eq 8) {24}else {0});bridge_metadata_payload_matched_bytes=$(if ($depth -eq 8) {474694}else {0})} "Depth $depth sweep"
  if ($r.error -or $null -eq $r.encode_elapsed_ns -or $r.encode_elapsed_ns -lt 0 -or $null -eq $r.decode_elapsed_ns -or $r.decode_elapsed_ns -lt 0 -or $progress.kind -ne 'depth' -or ($progress.record | ConvertTo-Json -Depth 12 -Compress) -ne ($r | ConvertTo-Json -Depth 12 -Compress)) {throw 'Sweep record/progress/timing mismatch'}
  Validate-Stats $r.encode_stats $depth;Validate-Stats $r.decode_stats $depth
  if (($r.encode_stats | ConvertTo-Json -Depth 12 -Compress) -ne ($r.decode_stats | ConvertTo-Json -Depth 12 -Compress)) {throw 'Sweep encode/decode stats differ'}
  if ($r.size_gate_passed -isnot [bool] -or $r.size_gate_passed -ne ($r.encode_stats.frame_bytes -le 483599)) {throw 'Actual frame size gate mismatch'}
  if ($r.size_gate_passed) {$gateCount++;$passing+=@($depth)}
 }
 if ($a.size_gate_passed_count -ne $gateCount) {throw 'Sweep size gate count'}
 $report.size_passing_candidates=$passing
 $report.sweep_validated=$true
}

try {
 Parse-PowerShell $PSCommandPath
 $null=Safe-Path $work
 if (Test-Path -LiteralPath $work) {throw 'Fresh root exists; no overwrite/retry'}
 foreach ($pin in $pins) {
  $path=Safe-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot $pin[0])))
  if (@($sources | Where-Object {$_.path -eq $path}).Count) {throw "Duplicate pinned source: $path"}
  $locks.Add([IO.File]::Open($path,'Open','Read','Read'));$id=Identity $path;if ($id.sha256 -ne $pin[1]) {throw "Pin mismatch: $path"};$sources.Add($id)
  if ([IO.Path]::GetExtension($path) -eq '.ps1') {Parse-PowerShell $path}
 }
 if ([IO.Path]::GetFullPath($runtime) -ne [IO.Path]::GetFullPath($expectedRuntime)) {throw 'Runtime path mismatch'}
 foreach ($path in @($PSCommandPath,$compiler,$runtime)) {
  $path=Safe-Path $path
  if (@($sources | Where-Object {$_.path -eq $path}).Count -eq 0) {$locks.Add([IO.File]::Open($path,'Open','Read','Read'));$sources.Add((Identity $path))}
 }
 if ($sources.Count -ne 89 -or @($sources.path | Sort-Object -Unique).Count -ne 89) {throw 'Expected 89 unique source identities'}
 $report.source_count=$sources.Count;$report.runner_before=Identity $PSCommandPath
 $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
 if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime pin mismatch'}
 $compiledSources=@('probe.rs','../quaternary-cts-depth/integer_cts.rs','../quaternary-cts-depth/model.rs','../quaternary-cts-depth/codec.rs','../quaternary-cts-depth/e2e.rs','../quaternary-cts-depth/comparison.rs','../quaternary-cts-sealed/integer_cts.rs','../quaternary-cts-integer-pool/fixed_math.rs','../quaternary-cts-integer-pool/integer_pool.rs','../quaternary-cts-q32/integer_cts.rs','../causal-bayes-sais/bwt.rs','../rejected-binary-mix/packed_alphabet.rs','../direct-token/multi_range.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
 $compiledEntries=@($sources | Where-Object {$_.path -in $compiledSources})
 if ($compiledEntries.Count -ne 13) {throw 'Compiled source missing from pins'}
 foreach ($entry in $compiledEntries) {
  $content=[IO.File]::ReadAllText($entry.path)
  if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b') {throw 'Unexpected include or extern crate'}
  $matches=[regex]::Matches($content,'(?m)^\s*(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
  if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{') {throw 'Unsupported module declaration'}
  foreach ($match in $matches) {$relative=if ($match.Groups[1].Success) {$match.Groups[1].Value}else {$match.Groups[2].Value+'.rs'};$resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($entry.path)) $relative));if ($resolved -notin $compiledSources) {throw "Unpinned graph edge: $resolved"};$report.imports+=@{source=$entry.path;resolved=$resolved}}
 }
 $root=$compiledSources[0];$modelSource=$compiledSources[2];$codecSource=$compiledSources[3];$e2eSource=$compiledSources[4]
 if ($compiledSources.Count -ne 13 -or $report.imports.Count -ne 12 -or @($report.imports | Where-Object {$_.source -eq $root}).Count -ne 10 -or @($report.imports | Where-Object {$_.source -eq $codecSource -and $_.resolved -eq $modelSource}).Count -ne 1 -or @($report.imports | Where-Object {$_.source -eq $codecSource -and $_.resolved -eq $e2eSource}).Count -ne 1 -or @($report.imports.resolved | Sort-Object -Unique).Count -ne 12) {throw 'Unexpected thirteen-source/twelve-edge graph'}
 $rootText=[IO.File]::ReadAllText($root);$codecText=[IO.File]::ReadAllText($codecSource);$modelText=[IO.File]::ReadAllText($modelSource)
 if ($rootText -notmatch '(?m)^use reference_cts as integer_cts;' -or $rootText -match '\benum\s|\bdyn\s' -or $codecText -notmatch 'new_cts as integer_cts' -or $modelText -notmatch 'use super::\{' -or $modelText -match 'crate::integer_cts|Instant|timing::|std::time' -or $codecText -notmatch 'Model::new\(depth\)' -or $codecText -notmatch 'b"KHQCID01"') {throw 'Static CTS depth alias boundary mismatch'}
 $priorProbe=[IO.File]::ReadAllText((Join-Path $originalRoot 'probe.rs'))
 $expectedProbe=$priorProbe.Replace('#[path="codec.rs"]','#[path="../quaternary-cts-depth/codec.rs"]').Replace('#[path="integer_cts.rs"]','#[path="../quaternary-cts-depth/integer_cts.rs"]').Replace('#[path="comparison.rs"]','#[path="../quaternary-cts-depth/comparison.rs"]').Replace('use std::{fs::File',("use reference_cts as integer_cts;"+[char]10+'use std::{fs::File'))
 if ($rootText.TrimEnd() -cne $expectedProbe.TrimEnd()) {throw 'Repair probe changed beyond three module paths and one root alias'}
 $report.root_alias_repair=@{status='passed';original_source=(Join-Path $originalRoot 'probe.rs');repaired_source=$root;module_path_changes=3;root_alias_additions=1;body_unchanged=$true;reference_alias='use reference_cts as integer_cts;';comparison='direct full source after four exact substitutions, trailing EOF whitespace excluded'}
 $report.compiled_graph=@{sources=$compiledSources;source_count=13;edge_count=12;root_edge_count=10;unique_destinations=12;automatic_relaxation=$false}

 Immutable-Basis
 Immutable-KT64-Basis
 Immutable-Sealed-Basis
 Immutable-Depth-Failure
 Rust-Syntax
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
  $report.compiler_version=$version.stdout;$exe=Join-Path $work 'depth-o2-yes.exe';$report.execution_stage='build-once'
  $build=Child $compiler @((Join-Path $PSScriptRoot 'probe.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe);Save-Report;Success $build
  $report.executable_before=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$report.execution_stage='exe-identity-saved';Save-Report
  if ($report.executable_before.bytes -gt $exeReserve) {throw 'EXE reserve'}
  $input=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group';$frame=Join-Path $project 'build/khc-quaternary-cts-integer-frame-20261002/all.khqc'
  $report.execution_stage='one-compare-snapshot-cli';$compare=Child $exe @('compare-snapshot');Save-Report;Capture-Single $compare 'parsed_compare';Success $compare
  if ($compare.stderr) {throw 'Unexpected compare stderr'};Validate-Compare
  $report.execution_stage='one-selfcheck-cli';$selfcheck=Child $exe @('selfcheck');Save-Report;Capture-Single $selfcheck 'parsed_selfcheck';Success $selfcheck
  if ($selfcheck.stderr) {throw 'Unexpected selfcheck stderr'};Validate-Selfcheck
  $report.execution_stage='one-depth-sweep-cli';$profile=Child $exe @('sweep',$input,$frame);Save-Report
  Capture-SweepLines
  Success $profile
  if ($profile.stderr) {throw 'Unexpected sweep stderr'}
  Validate-Sweep
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
} catch {$report.status='failed';$report.error=$_.Exception.Message;Capture-SweepLines;throw} finally {
 try {
  if ($report.immutable_basis) {Immutable-Basis}
  if ($report.immutable_kt64_basis) {Immutable-KT64-Basis}
  if ($report.immutable_sealed_basis) {Immutable-Sealed-Basis}
  if ($report.immutable_depth_failure) {Immutable-Depth-Failure}
  $report.runner_after=Identity $PSCommandPath
  if ($report.runner_before -and ($report.runner_before.sha256 -ne $report.runner_after.sha256 -or $report.runner_before.bytes -ne $report.runner_after.bytes -or $report.runner_before.mtime_utc -ne $report.runner_after.mtime_utc)) {throw 'Runner selfidentity changed'}
  $report.sources_after=@($sources | ForEach-Object {$now=Identity $_.path;if ($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes -or $now.mtime_utc -ne $_.mtime_utc) {throw 'Source identity changed'};$now})
  $report.disk_after=& $guard -WorkDirectory $work -MaxRunMiB 8
  if ($created) {
   if ($exe -and (Test-Path -LiteralPath $exe)) {$report.executable_after=Identity $exe}
   if ($report.status -eq 'failed') {$report.failure_policy='no retry; keep bounded completed/partial JSON and child records; no temporary files created'}
   $report.ended_utc=[DateTime]::UtcNow.ToString('o');Save-Report
  }
 }finally {foreach ($stream in $locks) {$stream.Dispose()}}
}
if ($Execute) {[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8);completed_runs=$report.parsed_sweep.runs_completed} | ConvertTo-Json -Depth 5}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;runtime=$report.runtime;compiler=$report.compiler;runtime_version=$report.runtime_version;rust_syntax=$report.rust_syntax;capacity=$report.disk_before;capacity_after=$report.disk_after;capacity_plan=$report.capacity_plan;immutable_basis=$report.immutable_basis;immutable_kt64_basis=$report.immutable_kt64_basis;immutable_sealed_basis=$report.immutable_sealed_basis;immutable_depth_failure=$report.immutable_depth_failure;root_alias_repair=$report.root_alias_repair;compiled_graph=$report.compiled_graph;source_count=$report.source_count;runner_before=$report.runner_before;runner_after=$report.runner_after;environment=$report.environment} | ConvertTo-Json -Depth 8}

