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
$repairRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../quaternary-cts-depth-repair'))
$abbaRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../quaternary-cts-depth-abba'))
$midRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../quaternary-cts-mid-depth'))
$work=Join-Path $project 'build/khc-quaternary-cts-pool-qcancel-20261003'
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
 @('../quaternary-cts-depth-repair/probe.rs','59568EB04D772E65F20A52AB86184BF9E6DD2003744173223305EF61C4962E7D'),
 @('../quaternary-cts-depth-repair/FAILURE_PLAN.md','743845A1D0E5DDB8C343FAC49C49FC9293AEDBD01A2539C9C2E364F9055BAA96'),
 @('../quaternary-cts-depth-repair/verify-depth.ps1','BE06BD702468CC104E36B9840E0783AC20F1439278B6C1329A040FAFCF31F7F0'),
 @('../QUATERNARY_CTS_MID_DEPTH_CONTRACT_20261003.md','76AD586F37805153938D5ED196B1FBC4F360693DF780D64640005999B3AAEC9E'),
 @('../QUATERNARY_CTS_DEPTH_RESULT_20261003.md','EA766DEE84650FE530D51ABECCFCE2F2A9513DBE6407B13B411E91CA635CA1F8'),
 @('../../../build/khc-quaternary-cts-depth-repair-20261003/report.json','96FF61D2B125982BCA413CC63EA86FA2DDCAC61AD7B157C744974E29FFC63DE2'),
 @('../../../build/khc-quaternary-cts-depth-repair-20261003/depth-o2-yes.exe','E719F8B7237A200EEAE67CCBBAFC7B50EA5F489AA9F6AFAB31909772BA545A98'),
 @('../quaternary-cts-mid-depth/probe.rs','90C221D7D2D462BC46030DEA5C2CFF06E4120B9ECA44D8639B0AFC1EBB3DB2C5'),
 @('../quaternary-cts-mid-depth/codec.rs','AE1A578E5AAC949C5D4FA8CF94460AEF707A4A6A368ADD4FD649B8DF1E80A2BC'),
 @('../quaternary-cts-mid-depth/e2e.rs','4BAF506AD22E3E954399944B31A9D7C0C65C62C53A23E7698145759971D6C048'),
 @('../quaternary-cts-mid-depth/comparison.rs','7619D984934CF398465EBC65D219D1AF27AF96AC2191496D4A36259D595F9FAA'),
 @('../quaternary-cts-mid-depth/FAILURE_PLAN.md','0A9B27C0C59C334C818FB52AD2BFED7BA68A704C2949BD2FE2F3294B81A589C5'),
 @('../quaternary-cts-mid-depth/verify-depth.ps1','30D74EE571FF980CAE9AA7445920BA445D581B5503DF3B0D71E02F8F2480FA8F'),
 @('../QUATERNARY_CTS_DEPTH_ABBA_CONTRACT_20261003.md','5617F19FE3D9325E6D7737FB898A218F8350926AE521D751A1E370FAD7CAAABE'),
 @('../QUATERNARY_CTS_MID_DEPTH_RESULT_20261003.md','7DC6207567024CA7926A34DDC37893F4C4E146C21849D9DDDCC19CBDCE393792'),
 @('../../../build/khc-quaternary-cts-mid-depth-20261003/report.json','161FA2175DAFEE83507F321969D79F753363F8E6BDE073987EED861CF481E27A'),
 @('../../../build/khc-quaternary-cts-mid-depth-20261003/depth-o2-yes.exe','BBEC5C2D04F99F7B6AA70071C90059D1E94D35634EBC7CDE5E1DE2C7B8C82B56'),
 @('../quaternary-cts-depth-abba/probe.rs','6BD241C756EA52EDDBDBD41FC6AB9F522964F98BFE8921D5CA88123C74D74C27'),
 @('../quaternary-cts-depth-abba/FAILURE_PLAN.md','C7E1F5C099267C547511E70DFFD7AC309BACE533FA3857C234F8AB23EA70A061'),
 @('../quaternary-cts-depth-abba/verify-depth.ps1','30413849F2361E00D5388A8F006CA04B294B05A79FBF3E6CE7FEBE70F021A86F'),
 @('../QUATERNARY_CTS_POOL_QCANCEL_CONTRACT_20261003.md','06A85DD8249773BA8E1875122E4720DA8318B3C5FD1BB761F7D7DEE36289F8BA'),
 @('../QUATERNARY_CTS_DEPTH_ABBA_RESULT_20261003.md','21790F39833CE40B2035E0ACC15D196D722579B9FDF5550A81AD9D7CFA168107'),
 @('../../../build/khc-quaternary-cts-depth-abba-20261003/report.json','AE9A4E360507F7CE1A39E87AFE4194CBA8ADDB13ECE0582D0ABE76BF431B30EA'),
 @('../../../build/khc-quaternary-cts-depth-abba-20261003/depth-o2-yes.exe','0CA1ABB4F9B61E86B569C10B77CC80E1B268EC2A69F53464E1B3035F084DE689'),
 @('../QUATERNARY_CTS_POST_DEPTH_CANDIDATES_20261003.md','43EB3DF77B6F10B429CAEAE01F5E56D9D87B5643DB132539FF07CAB11018C602'),
 @('probe.rs','2904ECF30CC04E691692516CD5C4B7AF42973E0C2966C57E2AE8537CEBB114DE'),
 @('codec.rs','B321C808463BF1200EFA0C7C0338EDC1EA6E3CE3075EA47D2D759B069D8D419A'),
 @('optimized_codec.rs','684A1C00D8D031F0B2A3D3249397AF7F6CE12EFA210DA8290D501B8602ED1016'),
 @('integer_pool.rs','63CF52DA7B6E13C765025781BDF7D252F117FFFE4D2F53F028F42901E4E7ADCB'),
 @('comparison.rs','CD8E7F6FA17A4A070C8B31BA056EE26EA962D286443AA4235FDCBDD53AB736E7'),
 @('FAILURE_PLAN.md','5E0C5B08BBB115AB2853284F0C4F504009C7516319E9E693E04C07297F02AF4C')
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
$report=[ordered]@{status='preflight';began_utc=[DateTime]::UtcNow.ToString('o');sources=$sources;records=$records;imports=@();abba_lines=@();parsed_abba=$null;parsed_compare=$null;parsed_selfcheck=$null;parsed_selfcheck_new=$null;parsed_pool=$null;temporary_created=$false;full_benchmark_allowed=$false;capacity_plan=@{max_bytes=8MB;retained_estimated_bytes=1280KB;exe_reserve_bytes=$exeReserve;report_reserve_bytes=$reportReserve;peak_reserve_bytes=$peakReserve;scalar_preflight_evaluated=$true;note='pre/post guard, not OS write quota'};unverified=@('formal codec speed and CPU15%','holdout/categories','four native environments','product/API integration','formal machine CPU observer');timing_limitations=@('clock overhead','code placement','CPU scheduling');disk_frame_restore_input_copy_created=$false}
function Save-Report {
 if (!$created) {return};$report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 8
 $json=$report | ConvertTo-Json -Depth 20
 if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $reportReserve) {throw 'Report reserve exceeded'}
 [IO.File]::WriteAllText((Join-Path $work 'report.json'),$json);$null=& $guard -WorkDirectory $work -MaxRunMiB 8
}
function Capture-ABBALines {
 if (!$exe) {return}
 $child=@($records | Where-Object {$_.file -eq $exe -and $_.argv.Count -eq 2 -and $_.argv[0] -eq 'abba'} | Select-Object -Last 1)
 if (!$child.Count) {return}
 $report.abba_lines=@()
 foreach ($line in ($child[0].stdout -split '\r?\n')) {
  if (!$line) {continue}
  try {$parsed=$line | ConvertFrom-Json -DateKind String;$report.abba_lines+=@{raw=$line;parsed=$parsed;parse_error=$null}}
  catch {$report.abba_lines+=@{raw=$line;parsed=$null;parse_error=$_.Exception.Message}}
 }
 $final=@($report.abba_lines | Where-Object {$_.parsed -and $_.parsed.kind -eq 'final'} | Select-Object -Last 1)
 if ($final.Count) {$report.parsed_abba=$final[0].parsed}
 Save-Report
}
function Same-Time($A,$B) {return [DateTimeOffset]::Parse([string]$A).UtcTicks -eq [DateTimeOffset]::Parse([string]$B).UtcTicks}
function Immutable-Basis {
 $old=Get-Content -LiteralPath (Join-Path $project 'build/khc-quaternary-cts-phase-profile-20261002/report.json') -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 48 -or $old.sources_after.Count -ne 48) {throw 'Immutable prior basis shape/status'}
 $checked_count=0
 for ($j=0;$j -lt 48;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable prior source basis mismatch'}
  $checked_count++
 }
 $report.immutable_basis=@{status='passed';sources_checked=48;identity_checks_completed=$checked_count;prior_report_sha256='359A98D303CC898354AB346BD0A3EAB896B49D03C721EEAD46A3CA4A692B0B7F';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-KT64-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-kt64-20261002/report.json'
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 60 -or $old.sources_after.Count -ne 60 -or $old.profile_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.local_probe_validated -ne $true) {throw 'Immutable KT64 status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 60) {throw 'Duplicate prior KT64 source paths'}
 $checked_count=0
 for ($j=0;$j -lt 60;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable KT64 source mismatch: $($before.path)"}
  $checked_count++
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable KT64 EXE mismatch'}
 $report.immutable_kt64_basis=@{status='passed';sources_checked=60;identity_checks_completed=$checked_count;executable=$now;prior_report_sha256='C88FBE8B6FD30B68D013329C3A34D7BEA09A456129F5D06DBF9AF1A72959398B';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Sealed-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-sealed-20261003/report.json'
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 72 -or $old.sources_after.Count -ne 72 -or $old.profile_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.snapshot_comparison_validated -ne $true) {throw 'Immutable sealed status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 72) {throw 'Duplicate prior sealed source paths'}
 $checked_count=0
 for ($j=0;$j -lt 72;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable sealed source mismatch: $($before.path)"}
  $checked_count++
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw 'Immutable sealed EXE mismatch'}
 $report.immutable_sealed_basis=@{status='passed';sources_checked=72;identity_checks_completed=$checked_count;executable=$now;prior_report_sha256='B2EA272A74F5484993A2DA0A6396CC620A6BD6EA697868AB5DA99B24BE24237B';prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Depth-Failure {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-depth-20261003/report.json'
 $priorIdentity=Identity $priorPath
 if ($priorIdentity.sha256 -ne '9AD38A687C21CC3302B481E3B0E9B21D1FCCD846BF0473CA60CBEF7FD6AA6DF0' -or $priorIdentity.bytes -ne 124513) {throw 'Immutable depth failure report identity'}
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'failed' -or $old.execution_stage -ne 'build-once' -or $old.sources.Count -ne 84 -or $old.sources_after.Count -ne 84 -or $old.error -notmatch 'error\[E0432\]: unresolved import .crate::integer_cts.' -or $old.records.Count -ne 8) {throw 'Immutable depth failure status/shape/cause'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 84) {throw 'Duplicate failed depth source paths'}
 $checked_count=0
 for ($j=0;$j -lt 84;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable failed depth source mismatch: $($before.path)"}
  $checked_count++
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
 $report.immutable_depth_failure=@{status='passed';sources_checked=84;identity_checks_completed=$checked_count;report_identity=$priorIdentity;compile_calls=1;compile_exit=1;compile_error='E0432 unresolved crate::integer_cts';candidate_CLI_calls=0;executable_absent=$true;retained_files=1;prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Depth-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-depth-repair-20261003/report.json'
 $priorIdentity=Identity $priorPath
 if ($priorIdentity.sha256 -ne '96FF61D2B125982BCA413CC63EA86FA2DDCAC61AD7B157C744974E29FFC63DE2' -or $priorIdentity.bytes -ne 326925) {throw 'Immutable depth basis report identity'}
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 89 -or $old.sources_after.Count -ne 89 -or $old.sweep_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.snapshot_comparison_validated -ne $true) {throw 'Immutable depth basis status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 89) {throw 'Duplicate prior depth basis source paths'}
 $checked_count=0
 for ($j=0;$j -lt 89;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable depth basis source mismatch: $($before.path)"}
  $checked_count++
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1 -or $now.sha256 -ne 'E719F8B7237A200EEAE67CCBBAFC7B50EA5F489AA9F6AFAB31909772BA545A98' -or $now.bytes -ne 375296) {throw 'Immutable depth basis EXE mismatch'}
 $report.immutable_depth_basis=@{status='passed';sources_checked=89;identity_checks_completed=$checked_count;executable=$now;prior_report_identity=$priorIdentity;prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-Mid-Depth-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-mid-depth-20261003/report.json'
 $priorIdentity=Identity $priorPath
 if ($priorIdentity.sha256 -ne '161FA2175DAFEE83507F321969D79F753363F8E6BDE073987EED861CF481E27A' -or $priorIdentity.bytes -ne 360935) {throw 'Immutable mid-depth report identity'}
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 99 -or $old.sources_after.Count -ne 99 -or $old.sweep_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.snapshot_comparison_validated -ne $true) {throw 'Immutable mid-depth status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 99) {throw 'Duplicate prior mid-depth source paths'}
 $checked_count=0
 for ($j=0;$j -lt 99;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable mid-depth source mismatch: $($before.path)"}
  $checked_count++
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1 -or $now.sha256 -ne 'BBEC5C2D04F99F7B6AA70071C90059D1E94D35634EBC7CDE5E1DE2C7B8C82B56' -or $now.bytes -ne 375296) {throw 'Immutable mid-depth EXE mismatch'}
 $report.immutable_mid_depth_basis=@{status='passed';sources_checked=99;identity_checks_completed=$checked_count;executable=$now;prior_report_identity=$priorIdentity;prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
}
function Immutable-ABBA-Basis {
 $priorPath=Join-Path $project 'build/khc-quaternary-cts-depth-abba-20261003/report.json'
 $priorIdentity=Identity $priorPath
 if ($priorIdentity.sha256 -ne 'AE9A4E360507F7CE1A39E87AFE4194CBA8ADDB13ECE0582D0ABE76BF431B30EA' -or $priorIdentity.bytes -ne 390728) {throw 'Immutable ABBA report identity'}
 $old=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json -DateKind String
 if ($old.status -ne 'passed' -or $old.sources.Count -ne 106 -or $old.sources_after.Count -ne 106 -or $old.abba_validated -ne $true -or $old.selfcheck_validated -ne $true -or $old.snapshot_comparison_validated -ne $true) {throw 'Immutable ABBA status/shape/validation'}
 if (@($old.sources.path | Sort-Object -Unique).Count -ne 106) {throw 'Duplicate prior ABBA source paths'}
 $checked_count=0
 for ($j=0;$j -lt 106;$j++) {
  $before=$old.sources[$j];$after=$old.sources_after[$j];$now=Identity $before.path
  if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1) {throw "Immutable ABBA source mismatch: $($before.path)"}
  $checked_count++
 }
 $before=$old.executable_before;$after=$old.executable_after;$now=Identity $before.path
 if ($before.path -ne $after.path -or $before.sha256 -ne $after.sha256 -or $before.bytes -ne $after.bytes -or !(Same-Time $before.mtime_utc $after.mtime_utc) -or $now.sha256 -ne $before.sha256 -or $now.bytes -ne $before.bytes -or !(Same-Time $now.mtime_utc $before.mtime_utc) -or @($sources | Where-Object {$_.path -eq $now.path}).Count -ne 1 -or $now.sha256 -ne '0CA1ABB4F9B61E86B569C10B77CC80E1B268EC2A69F53464E1B3035F084DE689' -or $now.bytes -ne 378368) {throw 'Immutable ABBA EXE mismatch'}
 $report.immutable_abba_basis=@{status='passed';sources_checked=106;identity_checks_completed=$checked_count;executable=$now;prior_report_identity=$priorIdentity;prior_Execute_repeated=$false;mtime_comparison='UTC ticks with DateKind String'}
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
 foreach ($name in @('probe.rs','codec.rs','optimized_codec.rs','integer_pool.rs','comparison.rs','../quaternary-cts-depth/integer_cts.rs','../quaternary-cts-depth/model.rs','../quaternary-cts-mid-depth/e2e.rs','../quaternary-cts-mid-depth/comparison.rs')) {
  $source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $name))
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
 $report.rust_syntax=@{status='passed';checked_sources=9;formatter_before=$before;formatter_after=$after;checks=$checks;mode='rustfmt stdout, skip_children=true, no write';type_execution_verified=$false}
}
function Require-Array($Actual,$Expected,[string]$Scope) {
 if ($null -eq $Actual -or $Actual.Count -ne $Expected.Count) {throw "$Scope array shape"}
 for ($j=0;$j -lt $Expected.Count;$j++) {if ($null -eq $Actual[$j] -or $Actual[$j] -ne $Expected[$j]) {throw "$Scope array value at $j"}}
}
function Validate-Compare {
 $all=$report.parsed_compare.parsed
 if (!$all -or $report.parsed_compare.parse_error) {throw 'Depth comparison JSON'}
 Require-Fields $all @{status='passed';operation='depth-compare';constructor_rejections=2;compact_shape_cases=60;depth_success_cases=30;depth_rejection_cases=1070;depth_failed_prediction_cases=90;pure_prediction_cases=5;proof_method='full nodes/history/observations and RawSnapshot direct comparisons'} 'Depth comparison'
 Require-Array $all.depths @(4,5,6,7,8) 'Depth comparison order'
 $a=$all.sealed
 Require-Fields $a @{status='passed';operation='compare-snapshot';LCG_seed=1831565813;legal_sequence_steps=384;lifecycle_successes=3;valid_modified_successes=3;modified_preparation_successes=1;cap_exact_successes=1;success_cases=392;visible_tamper_rejections=167;stale_rejections=1;class_cap_rejections=1;node_cap_rejections=9;invalid_current_rejections=18;dual_invalid_rejections=18;early_guard_rejections=6;current_guard_priority_rejections=3;rejection_cases=223;failed_prediction_cases=22;success_all_state_comparisons=392;rejection_before_after_comparisons=446;failed_predict_before_after_comparisons=44;proof_method='full nodes/history/observations direct comparisons';diagnostic_only=$true;formal_speed_CPU_verified=$false;full_benchmark_allowed=$false;general_8MiB_input_supported=$false;local_timing_added=$false} 'Sealed comparison'
 if ($a.old_snapshot_bytes -le 0 -or $a.new_snapshot_bytes -ne $a.old_snapshot_bytes -or $a.node_storage_bytes_per_CTS -ne 12582864 -or $a.digest -notmatch '^[0-9a-f]{16}$' -or $a.reason_summary.Count -ne 8) {throw 'Sealed snapshot size/digest/reason shape'}
 $reasons=@('stale or modified snapshot','invalid prefix','invalid observation','class update cap','node update cap','invalid kernel depth/leaf','kernel weight','raw observation cap')
 $counts=@(166,2,3,4,9,3,17,19)
 for ($j=0;$j -lt 8;$j++) {if ($a.reason_summary[$j].reason -ne $reasons[$j] -or $a.reason_summary[$j].cases -ne $counts[$j]) {throw 'Sealed comparison reason exact counts'}}
 if ($all.records.Count -ne 5) {throw 'Depth comparison record shape'}
 $depths=@(4,5,6,7,8);$nodes=@(341,1365,5461,21845,87381);$storage=@(49104,196560,786384,3145680,12582864);$refusals=@(204,209,214,219,224);$failed=@(14,16,18,20,22)
 for ($i=0;$i -lt 5;$i++) {
  $depth=$depths[$i];$r=$all.records[$i];$priority=2+[int]($depth -ge 2)
  Require-Fields $r @{depth=$depth;success_cases=6;rejection_cases=$refusals[$i];failed_prediction_cases=$failed[$i];pure_prediction_cases=1;visible_tamper_rejections=167;foreign_depth_rejections=1;legal_rebased_foreign_successes=1;cap_exact_successes=1;node_cap_rejections=($depth+1);current_guard_priority_rejections=$priority;node_count=$nodes[$i];node_storage_bytes=$storage[$i];rejection_before_after_comparisons=$refusals[$i]} "Depth $depth comparison"
  if ($r.digest -notmatch '^[0-9a-f]{16}$' -or $r.reason_summary.Count -ne 8) {throw 'Depth digest/reasons'}
  $counts=@(167,2,3,4,($depth+1),$(if ($depth -eq 0) {4}else {3}),$(if ($depth -eq 0) {0}else {2*$depth+1}),(2*$depth+2+[int]($depth -ge 2)))
  for ($j=0;$j -lt 8;$j++) {if ($r.reason_summary[$j].reason -ne $reasons[$j] -or $r.reason_summary[$j].cases -ne $counts[$j]) {throw "Depth $depth exact reason at $j"}}
 }
 $report.snapshot_comparison_validated=$true
 $report.adoption='parent evaluates same-binary single-cycle A/B direction and provisional depth5 basis; no formal speed or statistical claim'
}
function Validate-Selfcheck([string]$Name='parsed_selfcheck') {
 $all=$report[$Name].parsed
 if (!$all -or $report[$Name].parse_error) {throw 'Depth selfcheck JSON'}
 Require-Fields $all @{status='passed';operation='depth-selfcheck';normal_cases=70;byte_roundtrips=70;canonical_cases=70;malformed_cases=165;short_depth_header_checks=20;model_rejection_named_cases=70;model_rejection_assertions=80;cap_exact_successes=5} 'Depth selfcheck totals'
 Require-Array $all.depths @(4,5,6,7,8) 'Selfcheck order'
 if ($all.records.Count -ne 5) {throw 'Selfcheck record shape'}
 $names=@('short_header','old_magic','bad_magic','input_length','primary_field','alphabet_zero','alphabet_over','payload_short','payload_quota','payload_derived_bound','header_crc','payload_crc','plain_crc','metadata_padding','metadata_sentinel','metadata_width','metadata_rank','range_prefix','range_gap','range_truncated','range_trailing','range_termination','sentinel_count','primary_sentinel','lf_cycle','active_early','active_remaining','escape_noncanonical','escape_fourbytes','escape_remaining','unsupported_depth9','unsupported_depth_max','depth_crc')
 $reasons=@('bad frame magic/header','bad frame magic/header','bad frame magic/header','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','frame fields outside bounds','payload exceeds transformed bound','header CRC mismatch','payload CRC mismatch','plain length/CRC mismatch','packed alphabet high bitmap padding nonzero','packed alphabet sentinel 0 missing','packed alphabet rank byte width not canonical','packed alphabet rank outside factorial','invalid range prefix','range rounding gap','truncated range stream','trailing range bytes','noncanonical range termination','sentinel count','invalid primary sentinel','LF cycle inconsistent','active list exhausted before declared length','active list not empty at end','noncanonical length escape','length escape exceeds four bytes','run length outside remaining bound','unsupported CTS depth','unsupported CTS depth','header CRC mismatch')
 $depths=@(4,5,6,7,8)
 for ($i=0;$i -lt 5;$i++) {
  $a=$all.records[$i]
  Require-Fields $a @{depth=$depths[$i];status='passed';operation='selfcheck';normal_cases=14;byte_roundtrips=14;canonical_cases=14;malformed_cases=33;short_depth_header_checks=4;model_rejection_named_cases=14;model_rejection_assertions=16;cap_exact_successes=1;CRC32_known_fixture=$true;LCG_seed=1831565813;general_8MiB_input_supported=$false;full_benchmark_allowed=$false;heap_write_sync_fault_injection=$false} 'Selfcheck'
  if ($a.malformed.Count -ne 33 -or $a.model_state_comparison -ne 'all base values and totals, pool weights, CTS raw and weights, histories, observations, serial and audit values directly') {throw 'Selfcheck rejection evidence'}
  for ($j=0;$j -lt 33;$j++) {if ($a.malformed[$j].name -ne $names[$j] -or $a.malformed[$j].reason -ne $reasons[$j] -or $null -eq $a.malformed[$j].frame_bytes -or $a.malformed[$j].frame_bytes -lt 0) {throw 'Malformed named exact rejection'}}
 }
 if ($Name -eq 'parsed_selfcheck') {$report.selfcheck_validated=$true}else {$report.selfcheck_new_validated=$true}
}
function Validate-Stats($Stats,[int]$Depth) {
 $nodes=@{4=341;5=1365;6=5461;7=21845;8=87381};$storage=@{4=49104;5=196560;6=786384;7=3145680;8=12582864}
 Require-Fields $Stats @{depth=$Depth;node_count=$nodes[$Depth];node_storage_bytes=$storage[$Depth];magic='KHQCID01';header_crc_covers_depth=$true;plain_crc=433441561;runs=889227;primary=1762795;alphabet_symbols=257;rank_intervals=889227;length_intervals=889227;escape_bytes=742;grammar_digest='58735a2b7383d755'} 'Causal stats'
 Require-Array $Stats.branches @(2725772,1099568) 'Causal branches'
 Require-Array $Stats.class_observations @(889227,620240,1216305,889227,64372,145969) 'Causal class observations'
 if ($null -eq $Stats.payload_bytes -or $Stats.payload_bytes -lt 5 -or $Stats.payload_bytes -gt 1MB -or $Stats.header_bytes -ne 285 -or $Stats.frame_bytes -ne $Stats.header_bytes+$Stats.payload_bytes -or $Stats.frame_bytes -gt 1MB+285 -or $null -eq $Stats.header_crc -or $Stats.header_crc -lt 0 -or $Stats.header_crc -gt [uint32]::MaxValue -or $null -eq $Stats.payload_crc -or $Stats.payload_crc -lt 0 -or $Stats.payload_crc -gt [uint32]::MaxValue -or $Stats.base_pool_digest -notmatch '^[0-9a-f]{16}$' -or $null -eq $Stats.cdf_entropy_bits -or ![double]::IsFinite([double]$Stats.cdf_entropy_bits) -or $Stats.cdf_entropy_bits -lt 0) {throw 'Depth frame/audit bounds'}
 if ($Depth -eq 4) {
  Require-Fields $Stats @{frame_bytes=484023;header_bytes=285;payload_bytes=483738;payload_crc=2516407690;header_crc=3696859040;base_pool_digest='5bd5c61ec8da4195'} 'Depth4 regression stats'
  if ([Math]::Abs($Stats.cdf_entropy_bits-3862945.676275690) -gt 1e-4) {throw 'Depth4 regression CDF entropy'}
 }
 if ($Depth -eq 5) {
  Require-Fields $Stats @{frame_bytes=478750;header_bytes=285;payload_bytes=478465;payload_crc=3616798779;header_crc=621578488;base_pool_digest='0caac94407124a37'} 'Depth5 ABBA fixed stats'
  if ([Math]::Abs($Stats.cdf_entropy_bits-3820763.985142052) -gt 1e-4) {throw 'Depth5 ABBA CDF entropy'}
 }
 if ($Depth -eq 8) {
  Require-Fields $Stats @{frame_bytes=474734;header_bytes=285;payload_bytes=474449;payload_crc=3589341169;header_crc=433030689;base_pool_digest='9128444225deabce'} 'Depth8 fixed stats'
  if ([Math]::Abs($Stats.cdf_entropy_bits-3788636.714502990) -gt 1e-4) {throw 'Depth8 CDF entropy'}
 }
}

function Normalized-Source([string]$Path) {return [IO.File]::ReadAllText($Path).Replace("`r`n","`n").TrimEnd()+"`n"}
function Assert-Frozen-Bodies {
 $old=Normalized-Source (Join-Path $midRoot 'codec.rs')
 $expected=$old.Replace('#[path="e2e.rs"] mod e2e;','#[path="../quaternary-cts-mid-depth/e2e.rs"] mod e2e;'+"`n"+'#[path="optimized_codec.rs"] pub(crate) mod optimized;')
 if ((Normalized-Source (Join-Path $PSScriptRoot 'codec.rs')) -cne $expected) {throw 'Old codec not exact allowed substitutions'}
 $start=$old.IndexOf('// JSONの丸め');$end=$old.IndexOf('pub(crate) fn run_profile',$start)
 if ($start -lt 0 -or $end -le $start) {throw 'Frozen Proof extraction'}
 $block=$old.Substring($start,$end-$start)
 $ctorStart=$block.IndexOf('    fn new');$ctorEnd=$block.IndexOf('    pub(crate) fn validate_fixed')
 $ctor=$block.Substring($ctorStart,$ctorEnd-$ctorStart).Replace('    fn new(s:&Stats)->Self {Self{','fn proof_new(s:&Stats)->Proof {Proof{')
 $expected=$old.Replace('#[path="e2e.rs"] mod e2e;','#[path="../quaternary-cts-mid-depth/e2e.rs"] mod e2e;').Replace('fixed_math,integer_pool,new_cts','fixed_math,new_pool as integer_pool,new_cts').Replace($block,'pub(crate) use super::Proof;'+"`n"+$ctor).Replace('let proof=Proof::new(&stats)','let proof=proof_new(&stats)')
 $optimized=Normalized-Source (Join-Path $PSScriptRoot 'optimized_codec.rs')
 if ($optimized -cne $expected -or [regex]::Matches($optimized,'proof_new\(&stats\)').Count -ne 2 -or $optimized -match 'struct Proof|impl Proof|Proof::new') {throw 'Optimized codec/Proof not exact allowed substitutions'}
 $oldPool=Normalized-Source (Join-Path $PSScriptRoot '../quaternary-cts-integer-pool/integer_pool.rs')
 $oldPool=$oldPool.Substring(0,$oldPool.IndexOf('pub fn observe'))
 $typesStart=$oldPool.IndexOf('#[derive');$predictStart=$oldPool.IndexOf('pub fn predict')
 $oldPool=$oldPool.Remove($typesStart,$predictStart-$typesStart).Insert($typesStart,'pub use crate::integer_pool::{Prediction,Update,observe};'+"`n")
 $oldPool=$oldPool.Replace('    for j in 0..prefix {mass[j]=f::add(f::mul(f::mul(4095,prefix as u128)?,u128::from(q[j]))?,u128::from(Q))?;}'+ "`n"+'    let p=integer_cts::normalize(mass,prefix)?;','    let p=normalize_p(q,prefix)?;')
 $pool=Normalized-Source (Join-Path $PSScriptRoot 'integer_pool.rs');$helperStart=$pool.IndexOf('// 正常normalize')
 if ($helperStart -lt 0 -or $pool.Substring(0,$helperStart).TrimEnd() -cne $oldPool.TrimEnd() -or $pool -match 'integer_cts::vector\(q|pub fn observe|struct Prediction|struct Update|unsafe|Instant') {throw 'Pool frozen predict/types/observe boundary'}
 if ($pool -notmatch 'pub\(crate\) fn normalize_p' -or $pool -notmatch 'checked_mul' -or $pool -notmatch 'checked_add' -or $pool -notmatch 'checked_sub' -or $pool -notmatch 'checked_div' -or $pool -notmatch 'checked_rem') {throw 'Pool checked u64 helper shape'}
 $report.static_body_validation=@{status='passed';old_codec_exact_substitutions=$true;optimized_codec_exact_substitutions=$true;Proof_constructor_all_fields_exact=$true;Proof_constructor_calls=2;pool_predict_except_second_normalize_exact=$true;Prediction_Update_observe_reexport=$true;q_vector_added=$false;timer_bodies_unchanged=$true}
}
function Assert-Validator-Calls {
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$errors)
 if ($errors.Count) {throw 'Validator AST parse'}
 $definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true) | ForEach-Object Name | Where-Object {$_ -like 'Validate-*'})
 $calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true) | ForEach-Object {$_.GetCommandName()} | Where-Object {$_ -like 'Validate-*'})
 foreach ($call in $calls) {if ($call -notin $definitions) {throw "Undefined validator call: $call"}}
 foreach ($name in @('Validate-Compare','Validate-Pool','Validate-Selfcheck','Validate-Stats','Validate-ABBA')) {if (@($definitions | Where-Object {$_ -eq $name}).Count -ne 1 -or $name -notin $calls) {throw "Missing/duplicate validator definition/call: $name"}}
 if (@($calls | Where-Object {$_ -eq 'Validate-Selfcheck'}).Count -ne 2 -or @($calls | Where-Object {$_ -eq 'Validate-Pool'}).Count -ne 1 -or @($calls | Where-Object {$_ -eq 'Validate-ABBA'}).Count -ne 1) {throw 'Validator fixed call counts'}
 $root=Normalized-Source (Join-Path $PSScriptRoot 'probe.rs')
 foreach ($pair in @(@('compare-snapshot','snapshot_comparison::run()'),@('compare-pool','comparison::run()'),@('selfcheck','codec::run_selfcheck()'),@('selfcheck-new','codec::optimized::run_selfcheck()'))) {if (!$root.Contains('Some("'+$pair[0]+'")=>Some('+$pair[1]+')')) {throw 'Rust CLI definition/call mismatch'}}
 $report.validator_call_guard=@{status='passed';definitions=$definitions;calls=$calls;undefined_validator_calls=0;selfcheck_calls=2;pool_calls=1;ABBA_calls=1;Rust_CLI_dispatch_checked=4}
}
function Validate-Pool {
 $a=$report.parsed_pool.parsed
 if (!$a -or $report.parsed_pool.parse_error) {throw 'Pool JSON shape'}
 Require-Fields $a @{status='passed';operation='compare-pool';q_fixture_cases=20;active_components=62;max_mass=70355859275776;max_mass_sum=70368744177664;prediction_all_field_comparisons=104;primary_prediction_all_field_comparisons=104;post_rejection_prediction_all_field_comparisons=12;total_prediction_all_field_comparisons=116;update_all_field_comparisons=257;rejection_cases=12;rejection_after_prediction_comparisons=12;rare_q_zero=$true;rare_factor_gradient_zero_next_unchanged=$true;proof_method='Prediction/Update all fields Eq and every p element direct comparison';diagnostic_only=$true;local_timing_added=$false} 'Pool comparison'
 Require-Array $a.residual_coverage_masks @(1,3,6,15) 'Pool residual coverage'
 $names=@('prefix0','prefix5','countzero','countsum','weight','CTSzero','CTSinactive','prefix-before-CTS','weight-before-CTS','CTS-before-count','CTSsum-before-count','child')
 $reasons=@('pool prefix/weight','pool prefix/weight','pool count row','pool count row','pool prefix/weight','invalid categorical vector','invalid categorical vector','pool prefix/weight','pool prefix/weight','invalid categorical vector','vector sum differs from Q','pool observed child/weights')
 if ($a.reasons.Count -ne 12) {throw 'Pool rejection reason count'}
 for ($j=0;$j -lt 12;$j++) {if ($a.reasons[$j].name -ne $names[$j] -or $a.reasons[$j].reason -ne $reasons[$j]) {throw "Pool rejection exact reason $j"}}
 $report.pool_comparison_validated=$true
}

function Validate-ABBA {
 $a=$report.parsed_abba
 if (!$a -or $report.abba_lines.Count -ne 5 -or @($report.abba_lines | Where-Object {$_.parse_error}).Count) {throw 'ABBA JSON shape'}
 Require-Fields $a @{kind='final';status='passed';operation='pool-qcancel-abba';runs_completed=4;encode_calls=4;decode_calls=4;plain_comparisons=4;stats_comparisons=4;reference_stats_comparisons=3;expected_restored_bytes=2811006;size_gate_passed_count=4;input_read_attempts=1;input_reads=1;warmup_runs=0;abba_cycles=1;protocol_external_repeats=0;repeat_frame_comparison_attempts=3;repeat_frame_comparisons=3;repeat_frame_matched_bytes=1436250;peak_reference_frames=1;peak_reference_frame_bytes=478750;peak_live_candidate_frames=2;peak_live_candidate_frame_bytes=957500;references_remaining=0;all_process_peak_verified=$false;frame_clones_created=$false;additional_repeats=0;inner_timers=$false;full_input_canonical_reencoded=$false;disk_frames_created=$false;disk_restores_created=$false;diagnostic_only=$true;formal_speed_CPU_verified=$false;full_benchmark_allowed=$false;general_8MiB_input_supported=$false;timing_scope='encode/decode calls only; excludes JSON/stats formatting/comparison/drop';next_step='single-cycle diagnostic only; parent evaluates pool Q-cancel direction'} 'Pool ABBA'
 Require-Array $a.depth_order @(5,5,5,5) 'ABBA depth'
 Require-Array $a.implementation_order @('old','new','new','old') 'ABBA implementation'
 Require-Array $a.timing_limitations @('single ABBA cycle','no warmup','code placement','CPU scheduling') 'ABBA limitations'
 if ($a.error -or $a.records.Count -ne 4 -or $report.abba_lines[4].parsed.kind -ne 'final') {throw 'ABBA final/error shape'}
 $report.byte_comparisons=@()
 foreach ($r in $a.records) {$report.byte_comparisons+=@{kind='plain-and-reference-frame';index=$r.index;depth=5;implementation=$r.implementation;expected_plain_bytes=2811006;matched_plain_bytes=$r.matched_plain_bytes;plain_equal=$r.plain_equal;repeat_frame_compared=$r.repeat_frame_compared;repeat_frame_matched_bytes=$r.repeat_frame_matched_bytes;all_proof_equal=$r.all_proof_equal;reference_all_proof_stats_compared=$r.reference_all_proof_stats_compared;error=$r.error}}
 Save-Report
 $order=@('old','new','new','old');$repeatBytes=@(0,478750,478750,478750);$liveCounts=@(1,2,2,2);$liveBytes=@(478750,957500,957500,957500);$heldCounts=@(1,1,1,0);$heldBytes=@(478750,478750,478750,0)
 for ($j=0;$j -lt 4;$j++) {
  $r=$a.records[$j];$progress=$report.abba_lines[$j].parsed
  Require-Fields $r @{index=$j;depth=5;implementation=$order[$j];status='passed';encode_calls=1;decode_calls=1;stats_equal=$true;all_proof_equal=$true;reference_all_proof_stats_compared=($j -gt 0);cdf_compared_as_bits=$true;matched_plain_bytes=2811006;plain_equal=$true;size_gate_limit_bytes=483599;size_gate_passed=$true;repeat_frame_compared=($j -gt 0);repeat_frame_matched_bytes=$repeatBytes[$j];candidate_frames_before_comparison=$liveCounts[$j];candidate_frame_bytes_before_comparison=$liveBytes[$j];reference_frames_after=$heldCounts[$j];reference_frame_bytes_after=$heldBytes[$j]} "Pool ABBA run $j"
  if ($r.error -or $null -eq $r.encode_elapsed_ns -or $r.encode_elapsed_ns -lt 0 -or $null -eq $r.decode_elapsed_ns -or $r.decode_elapsed_ns -lt 0 -or $progress.kind -ne 'run' -or ($progress.record | ConvertTo-Json -Depth 12 -Compress) -ne ($r | ConvertTo-Json -Depth 12 -Compress)) {throw 'ABBA record/progress/timing mismatch'}
  Validate-Stats $r.encode_stats 5;Validate-Stats $r.decode_stats 5
  if (($r.encode_stats | ConvertTo-Json -Depth 12 -Compress) -ne ($r.decode_stats | ConvertTo-Json -Depth 12 -Compress) -or ($r.encode_stats | ConvertTo-Json -Depth 12 -Compress) -ne ($a.records[0].encode_stats | ConvertTo-Json -Depth 12 -Compress)) {throw 'ABBA encode/decode/reference stats differ'}
  if ($r.size_gate_passed -isnot [bool] -or $r.encode_stats.frame_bytes -gt 483599) {throw 'ABBA actual frame size gate'}
 }
 $aEncode=([double]$a.records[0].encode_elapsed_ns+[double]$a.records[3].encode_elapsed_ns)/2000000.0
 $bEncode=([double]$a.records[1].encode_elapsed_ns+[double]$a.records[2].encode_elapsed_ns)/2000000.0
 $aDecode=([double]$a.records[0].decode_elapsed_ns+[double]$a.records[3].decode_elapsed_ns)/2000000.0
 $bDecode=([double]$a.records[1].decode_elapsed_ns+[double]$a.records[2].decode_elapsed_ns)/2000000.0
 $report.diagnostic_summary=@{ABBA=@('old','new','new','old');depth=5;cycles=1;A=@{implementation='old';samples=2;frame_bytes=478750;node_storage_bytes=196560;encode_mean_ms=$aEncode;decode_mean_ms=$aDecode};B=@{implementation='new';samples=2;frame_bytes=478750;node_storage_bytes=196560;encode_mean_ms=$bEncode;decode_mean_ms=$bDecode};B_encode_mean_lower=($bEncode -lt $aEncode);B_decode_mean_lower=($bDecode -lt $aDecode);both_mean_directions_lower=($bEncode -lt $aEncode -and $bDecode -lt $aDecode);diagnostic_only=$true;formal_speed_CPU_verified=$false;statistical_significance_claimed=$false;next_decision='parent evaluates this one cycle; no retry to select favorable numbers'}
 $report.abba_validated=$true
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
 if ($sources.Count -ne 118 -or @($sources.path | Sort-Object -Unique).Count -ne 118) {throw 'Expected 118 unique source identities'}
 $report.source_count=$sources.Count;$report.runner_before=Identity $PSCommandPath
 $report.compiler=Identity $compiler;$report.runtime=Identity $runtime;$report.runtime_version=$PSVersionTable.PSVersion.ToString()
 if ($report.compiler.sha256 -ne $compilerSha -or $report.runtime.sha256 -ne $expectedRuntimeSha -or $report.runtime_version -ne '7.6.5') {throw 'Compiler/runtime pin mismatch'}
 $compiledSources=@('probe.rs','../quaternary-cts-depth/integer_cts.rs','../quaternary-cts-depth/model.rs','codec.rs','../quaternary-cts-mid-depth/e2e.rs','../quaternary-cts-mid-depth/comparison.rs','../quaternary-cts-sealed/integer_cts.rs','../quaternary-cts-integer-pool/fixed_math.rs','../quaternary-cts-integer-pool/integer_pool.rs','../quaternary-cts-q32/integer_cts.rs','../causal-bayes-sais/bwt.rs','../rejected-binary-mix/packed_alphabet.rs','../direct-token/multi_range.rs','optimized_codec.rs','integer_pool.rs','comparison.rs') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
 $compiledEntries=@($sources | Where-Object {$_.path -in $compiledSources})
 if ($compiledEntries.Count -ne 16) {throw 'Compiled source missing from pins'}
 foreach ($entry in $compiledEntries) {
  $content=[IO.File]::ReadAllText($entry.path)
  if ($content -match 'include(?:_str|_bytes)?\s*!\s*\(' -or $content -match '\bextern\s+crate\b') {throw 'Unexpected include or extern crate'}
  $matches=[regex]::Matches($content,'(?m)^\s*(?:#\[path\s*=\s*"([^"]+)"\]\s*)?(?:pub(?:\([^)]*\))?\s+)?mod\s+(\w+)\s*;')
  if ([regex]::Matches($content,'\bmod\s+\w+\s*;').Count -ne $matches.Count -or $content -match '\bmod\s+\w+\s*\{') {throw 'Unsupported module declaration'}
  foreach ($match in $matches) {$relative=if ($match.Groups[1].Success) {$match.Groups[1].Value}else {$match.Groups[2].Value+'.rs'};$resolved=[IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($entry.path)) $relative));if ($resolved -notin $compiledSources) {throw "Unpinned graph edge: $resolved"};$report.imports+=@{source=$entry.path;resolved=$resolved}}
 }
 $root=$compiledSources[0];$modelSource=$compiledSources[2];$codecSource=$compiledSources[3];$e2eSource=$compiledSources[4]

 if ($compiledSources.Count -ne 16 -or $report.imports.Count -ne 17 -or @($report.imports | Where-Object {$_.source -eq $root}).Count -ne 12 -or @($report.imports.resolved | Sort-Object -Unique).Count -ne 15) {throw 'Unexpected sixteen-source/seventeen-edge graph'}
 $rootText=[IO.File]::ReadAllText($root);$modelText=[IO.File]::ReadAllText($modelSource)
 if ($rootText -notmatch '(?m)^use reference_cts as integer_cts;' -or $rootText -match '\benum\s|\bdyn\s' -or $modelText -notmatch 'use super::\{' -or $modelText -match 'crate::integer_cts|Instant|timing::|std::time') {throw 'Static CTS/pool alias boundary mismatch'}
 if ($rootText -match '\.clone\s*\(|\bInstant\b|std::time|timing::|\bunsafe\b|OpenOptions|File::create|std::fs::write' -or $rootText -notmatch 'for \(index,optimized\) in \[false,true,true,false\]\.into_iter\(\)\.enumerate\(\)' -or $e2eSource -ne (Join-Path $midRoot 'e2e.rs') -or $compiledSources[5] -ne (Join-Path $midRoot 'comparison.rs')) {throw 'Pool ABBA frozen source/timer/clone/sequence guard'}
 Assert-Frozen-Bodies
 Assert-Validator-Calls
 $report.frozen_source_boundary=@{status='passed';new_root=$root;codec=$codecSource;optimized_codec=$compiledSources[13];e2e=$e2eSource;comparison=$compiledSources[5];CTS=$compiledSources[1];model=$compiledSources[2];codec_numerical_timer_bodies_unchanged=$true;Proof_all_fields_shared=$true;pool_observe_types_reexported=$true;timers_in_new_root=$false;frame_clone_calls_in_new_root=0;root_alias_maintained=$true}
 $report.compiled_graph=@{sources=$compiledSources;source_count=16;edge_count=17;root_edge_count=12;unique_destinations=15;automatic_relaxation=$false}

 Immutable-Basis
 Immutable-KT64-Basis
 Immutable-Sealed-Basis
 Immutable-Depth-Failure
 Immutable-Depth-Basis
 Immutable-Mid-Depth-Basis
 Immutable-ABBA-Basis
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
  $report.compiler_version=$version.stdout;$exe=Join-Path $work 'pool-o2-yes.exe';$report.execution_stage='build-once'
  $build=Child $compiler @((Join-Path $PSScriptRoot 'probe.rs'),'--edition=2024','--cfg','frame_audit','--cfg','primitive_audit','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe);Save-Report;Success $build
  $report.executable_before=Identity $exe;$locks.Add([IO.File]::Open($exe,'Open','Read','Read'));$report.execution_stage='exe-identity-saved';Save-Report
  if ($report.executable_before.bytes -gt $exeReserve) {throw 'EXE reserve'}
  $input=Join-Path $project 'build/khc-current-source-native-solid-20260923-group/all.group';$frame=Join-Path $project 'build/khc-quaternary-cts-integer-frame-20261002/all.khqc'
  $report.execution_stage='one-compare-snapshot-cli';$compare=Child $exe @('compare-snapshot');Save-Report;Capture-Single $compare 'parsed_compare';Success $compare
  if ($compare.stderr) {throw 'Unexpected compare stderr'};Validate-Compare
  $report.execution_stage='one-selfcheck-cli';$selfcheck=Child $exe @('selfcheck');Save-Report;Capture-Single $selfcheck 'parsed_selfcheck';Success $selfcheck
  if ($selfcheck.stderr) {throw 'Unexpected selfcheck stderr'};Validate-Selfcheck
  $report.execution_stage='one-selfcheck-new-cli';$selfcheckNew=Child $exe @('selfcheck-new');Save-Report;Capture-Single $selfcheckNew 'parsed_selfcheck_new';Success $selfcheckNew
  if ($selfcheckNew.stderr) {throw 'Unexpected selfcheck-new stderr'};Validate-Selfcheck 'parsed_selfcheck_new'
  $report.execution_stage='one-compare-pool-cli';$pool=Child $exe @('compare-pool');Save-Report;Capture-Single $pool 'parsed_pool';Success $pool
  if ($pool.stderr) {throw 'Unexpected compare-pool stderr'};Validate-Pool
  $report.execution_stage='one-pool-ABBA-cli';$profile=Child $exe @('abba',$input);Save-Report
  Capture-ABBALines
  Success $profile
  if ($profile.stderr) {throw 'Unexpected ABBA stderr'}
  Validate-ABBA
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
} catch {$report.status='failed';$report.error=$_.Exception.Message;Capture-ABBALines;throw} finally {
 try {
  if ($report.immutable_basis) {Immutable-Basis}
  if ($report.immutable_kt64_basis) {Immutable-KT64-Basis}
  if ($report.immutable_sealed_basis) {Immutable-Sealed-Basis}
  if ($report.immutable_depth_failure) {Immutable-Depth-Failure}
  if ($report.immutable_depth_basis) {Immutable-Depth-Basis}
  if ($report.immutable_mid_depth_basis) {Immutable-Mid-Depth-Basis}
  if ($report.immutable_abba_basis) {Immutable-ABBA-Basis}
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
if ($Execute) {[pscustomobject]@{status=$report.status;report=(Identity (Join-Path $work 'report.json'));capacity=(& $guard -WorkDirectory $work -MaxRunMiB 8);completed_runs=$report.parsed_abba.runs_completed} | ConvertTo-Json -Depth 5}
else {[pscustomobject]@{status=$report.status;sources=$sources;sources_after=$report.sources_after;imports=$report.imports;runtime=$report.runtime;compiler=$report.compiler;runtime_version=$report.runtime_version;rust_syntax=$report.rust_syntax;capacity=$report.disk_before;capacity_after=$report.disk_after;capacity_plan=$report.capacity_plan;immutable_basis=$report.immutable_basis;immutable_kt64_basis=$report.immutable_kt64_basis;immutable_sealed_basis=$report.immutable_sealed_basis;immutable_depth_failure=$report.immutable_depth_failure;immutable_depth_basis=$report.immutable_depth_basis;immutable_mid_depth_basis=$report.immutable_mid_depth_basis;immutable_abba_basis=$report.immutable_abba_basis;static_body_validation=$report.static_body_validation;validator_call_guard=$report.validator_call_guard;frozen_source_boundary=$report.frozen_source_boundary;compiled_graph=$report.compiled_graph;source_count=$report.source_count;runner_before=$report.runner_before;runner_after=$report.runner_after;environment=$report.environment} | ConvertTo-Json -Depth 8}

