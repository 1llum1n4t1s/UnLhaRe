#requires -Version 7.2
# 実装前失敗計画: ../LIGHT_COMPACT_CODEC_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-light-compact-codec-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$oldRoot=Join-Path $root 'build/khc-causal-integer-refinement-20261002-comparison-repair'
$inputRoot=Join-Path $root 'build/khc-causal-expert-scheduling-20261001'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$failure=$null
$fixedFrame=$null
$diagnostic=$null
$began=[DateTime]::UtcNow.ToString('o')
function Hold([string]$Path,[string]$Role,[string]$Expected='') {
    $full=[IO.Path]::GetFullPath($Path)
    $ancestor=$full
    while($ancestor) {
        if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "reparse: $ancestor"}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $locks.Add([IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $item=Get-Item -LiteralPath $full
    $sha=(Get-FileHash -LiteralPath $full).Hash
    if($Expected -and $sha -cne $Expected){throw "pin mismatch: $Role"}
    $ids.Add([pscustomobject]@{path=$full;role=$Role;bytes=$item.Length;before_sha256=$sha;after_sha256=$null})
}
function Child([string]$Program,[string[]]$Argv,[int]$Expected=0) {
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Argv){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $started=$false
    try {
        $started=$process.Start();if(!$started){throw 'start failed'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(120000)){throw '120s timeout'}
        $call=[pscustomobject]@{program=$Program;argv=$Argv;exit=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($call)
        if($call.exit -ne $Expected -or ($Expected -eq 0 -and $call.stderr) -or ($Expected -ne 0 -and $call.stdout)){throw 'unexpected child result'}
        return $call.stdout
    } finally {
        if($started -and !$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(10000)}
        $process.Dispose()
    }
}
function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Same([string]$First,[string]$Second) {
    if((Get-Item -LiteralPath $First).Length -ne (Get-Item -LiteralPath $Second).Length){throw 'length mismatch'}
    $a=[IO.File]::OpenRead($First);$b=[IO.File]::OpenRead($Second)
    try {
        $ab=[byte[]]::new(65536);$bb=[byte[]]::new(65536)
        while(($count=$a.Read($ab,0,$ab.Length)) -gt 0) {
            $other=$b.Read($bb,0,$count);if($other -ne $count){throw 'read length mismatch'}
            if(![FrameCompare]::Equal($ab,$bb,$count)){throw 'full frame bytes differ'}
        }
    } finally {$a.Dispose();$b.Dispose()}
}
Add-Type -TypeDefinition @'
using System;
public static class FrameCompare {
    public static bool Equal(byte[] first, byte[] second, int count) {
        return first.AsSpan(0,count).SequenceEqual(second.AsSpan(0,count));
    }
}
'@
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 32
if(Test-Path -LiteralPath $work){throw 'Fresh work directory required; no automatic retry/overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Hold (Join-Path $PSScriptRoot '../LIGHT_COMPACT_CODEC_CONTRACT_20261002.md') 'preimplementation-contract' '9FEEE81B2EA1CC8F6E48F49FB8BA68D3F5AC6A77DD4319C827E82B782D5E23D2'
    Hold (Join-Path $PSScriptRoot '../compact-simd-quotient/exact_div.rs') 'batch-helper' '978B932A7D0CFAA7C8090DB75C6928E7746798F91213CA7AE89231810A9C222D'
    Hold (Join-Path $root 'build/khc-compact-simd-20261002-coverage-repair/report.json') 'batch-numeric-proof' 'C8B6DAA9DEFA6C97D6DD062682AA87139B0CC6C5F6782B642EA977783FCE4935'
    Hold (Join-Path $root 'build/khc-bayes-dominant-q15-20261002-numeric/report.json') 'numeric-proof' 'CD285519F0EB1A74A5DBA01CDD26AFD484471586A6555537E3A7051FB69A5C51'
    Hold (Join-Path $PSScriptRoot '../integer-refinement-narrow/exact_div.rs') 'numeric-helper' '01EA52E84D8725AB3F4A0B85999DC21598C18A330FA4101E0ACE7720D06674A3'
    Hold (Join-Path $oldRoot 'report.json') 'old-codec-proof' 'B7BE539DB0DA5786EAAA1BC7F4E43DC983A4495F21E6B2E80BADD999407D459D'
    $oldReport=Get-Content -LiteralPath (Join-Path $oldRoot 'report.json') -Raw|ConvertFrom-Json
    if($oldReport.status -cne 'correctness_and_size_passed_not_timed'){throw 'Old correctness proof status'}
    foreach($id in $oldReport.identities){Hold $id.path 'old-current-identity' $id.before_sha256}
    $nodeProofPath=Join-Path $root 'build/khc-cts-node-u32-20261002/report.json'
    Hold $nodeProofPath 'node-u32-full-proof' '9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04'
    $nodeProof=Get-Content -LiteralPath $nodeProofPath -Raw|ConvertFrom-Json
    if($nodeProof.status -cne 'correctness_and_size_passed_not_timed' -or $nodeProof.failure -or $nodeProof.timing_used -or $nodeProof.checks.Count -ne 55 -or $nodeProof.invocations.Count -ne 94 -or $nodeProof.identities.Count -ne 550 -or $nodeProof.frame_bytes -ne 483496 -or $nodeProof.owned_tmp_or_reparse -ne 0 -or $nodeProof.owned_pdb -ne 0){throw 'node-u32 source proof matrix'}
    foreach($id in $nodeProof.identities){Hold $id.path 'node-u32-current-identity' $id.after_sha256}
    $checks.Add('node-u32-source-proof-and-current-identities')
    $lightProofPath=Join-Path $root 'build/khc-light-compact-path-20261002/report.json'
    Hold $lightProofPath 'light-state-proof' '99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109F'
    $lightProof=Get-Content -LiteralPath $lightProofPath -Raw|ConvertFrom-Json
    if($lightProof.status -cne 'light_compact_path_state_verified_not_codec_or_timing' -or $lightProof.failure -or $lightProof.timing_used -or $lightProof.full_codec_verified -or $lightProof.checks.Count -ne 7 -or $lightProof.invocations.Count -ne 9 -or $lightProof.identities.Count -ne 15 -or $lightProof.owned_tmp_pdb_reparse -ne 0){throw 'light numeric/state proof matrix'}
    if(($lightProof.summaries.variant -join ',') -cne 'opt2-checkedFalse,opt2-checkedTrue,opt3-checkedFalse,opt3-checkedTrue'){throw 'light numeric/state variant matrix'}
    foreach($item in $lightProof.summaries){
        $s=$item.summary
        if($s.status -cne 'light_compact_path_state_verified_not_codec_or_timing' -or $s.mapping_records -ne 1114112 -or $s.invalid_depth_cases -ne 2 -or $s.state_events -ne 131072 -or $s.values_per_event -ne 72 -or $s.invalid_class_cases -ne 2 -or $s.stale_cases -ne 1 -or $s.class_mismatch_cases -ne 1 -or $s.injected_cap_cases -ne 1 -or $s.rollback_checks -ne 3 -or $s.continuation_events -ne 2 -or $s.fingerprint_u64 -cne 'd47b3bd91aab06f7'){throw 'light mapping/state/refusal coverage'}
        if($s.old_prediction_bytes -ne 160 -or $s.new_prediction_bytes -ne 24 -or $s.old_node_bytes -ne 8 -or $s.new_node_bytes -ne 8 -or $s.classes.Count -ne 7 -or $s.selected_depths.Count -ne 17 -or ($s.classes|Measure-Object -Sum).Sum -ne 131072 -or ($s.selected_depths|Measure-Object -Sum).Sum -ne 131072){throw 'light layout/class coverage'}
        if($item.stdout -cne $lightProof.summaries[0].stdout){throw 'light state summary differs'}
    }
    foreach($call in $lightProof.invocations){if($call.exit -ne 0 -or $call.stderr){throw 'light state proof child failure'}}
    foreach($id in $lightProof.identities){Hold $id.path 'light-state-current-identity' $id.after_sha256}
    $checks.Add('light-streamed-numeric-state-proof-reused-not-rerun')
    foreach($name in @('scheduler.rs','codec.rs','correspondence.json','verify.ps1','verifier-correspondence.json')){Hold (Join-Path $PSScriptRoot $name) 'new-source'}
    Hold (Join-Path $PSScriptRoot '../cts-node-u32/codec.rs') 'frozen-node-u32-codec.rs' '1E32F2AEAD5ACC93D10F04A2FA04E3380CB9BEC6F4D98E1A842E7A24663EF5EE'
    Hold (Join-Path $PSScriptRoot '../cts-node-u32/cts_model.rs') 'frozen-node-u32-cts_model.rs' '310DDC66487310D13C7D358D9233DB6C601268A40A03833550807E805E9B304A'
    Hold (Join-Path $PSScriptRoot '../cts-node-u32/exact_kt.rs') 'frozen-node-u32-exact_kt.rs' 'A208D7BE5E9519FA636ABD94B0BDD9306F5CFDE3AAC03E24C2144A391EAB06E5'
    Hold (Join-Path $PSScriptRoot '../cts-node-u32/scheduler.rs') 'frozen-node-u32-scheduler.rs' 'DA48F8E69E72D3C455BF86718D38B39FF6C6BD1E24FC9D834A343CF1A36DA5B2'
    Hold (Join-Path $PSScriptRoot '../causal-compact-simd/verify.ps1') 'original-full-verifier' '27BCE6AF9C53E8103CF2F54763952C6493E840547655F6982352B12BF69E37BB'
    Hold (Join-Path $PSScriptRoot '../light-compact-path/light.rs') 'new-light-model' '42DAD8135AF86DF5AF0FDD6DCA6616C35346B5B127EF0B58751305B6B76BFDC4'
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard'
    Hold (Join-Path $PSScriptRoot '../bayes-dominant-q15/bayes_model.rs') 'unchanged-bayes' 'DC0852C55C5CDA8B97D445C231B92ACF446FCBC17959B6ABC58244E7D0E6797B'
    Hold (Join-Path $PSScriptRoot '../bayes-dominant-q15/scheduler.rs') 'old-scheduler' 'C286EC6D84894A889B5BD2153E0817BDA4FD22A2A684B8E2554F47BB21475656'
    Hold (Join-Path $PSScriptRoot '../bayes-dominant-q15/codec.rs') 'old-codec' '0AD79D2C15CFFA96CDBED33421C20418C146BA223C872CFDCF5FD3F263ED0B64'
    $batchNumeric=Get-Content -LiteralPath (Join-Path $root 'build/khc-compact-simd-20261002-coverage-repair/report.json') -Raw|ConvertFrom-Json
    if($batchNumeric.status -cne 'compact_batch_numeric_verified_not_codec_or_timing' -or $batchNumeric.checks.Count -ne 32 -or $batchNumeric.invocations.Count -ne 87 -or $batchNumeric.identities.Count -ne 13){throw 'batch numeric proof counts/status'}
    if(!$batchNumeric.features.avx2_available){throw 'Four-variant verifier requires observed AVX2 availability'}
    foreach($summary in $batchNumeric.summaries){if($summary.summary.records -ne 9293629 -or $summary.summary.matched -ne 9293629 -or $summary.summary.batches -ne 2323408 -or $summary.summary.fingerprint_u64 -cne 'f02dbdcb00adbe1d' -or $summary.summary.compact -ne 8398832 -or $summary.summary.certificate_fallback -ne 0){throw 'batch numeric summary'}}
    foreach($id in $batchNumeric.identities){Hold $id.path 'batch-numeric-current-identity' $id.before_sha256}
    $checks.Add('four-condition-streamed-independent-batch-numeric-proof')
    $correspondence=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json
    foreach($source in $correspondence) {
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes){if($change.PSObject.Properties.Name -contains 'append'){$expected+=$change.append}else{if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source replacement occurrence'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}}
        $current=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n")
        if($current -cne $expected){throw "full source correspondence: $($source.name)"}
    }
    $numeric=Get-Content -LiteralPath (Join-Path $root 'build/khc-bayes-dominant-q15-20261002-numeric/report.json') -Raw|ConvertFrom-Json
    if($numeric.status -cne 'numeric_native_equivalence_passed_not_timed' -or $numeric.checks.Count -ne 6 -or $numeric.invocations.Count -ne 7){throw 'numeric proof status/counts'}
    foreach($id in $numeric.identities){Hold $id.path 'numeric-current-identity' $id.before_sha256}
    $verifierCorrespondence=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verifier-correspondence.json') -Raw|ConvertFrom-Json
    $expectedVerifier=[IO.File]::ReadAllText((Join-Path $root $verifierCorrespondence.original)).Replace("`r`n","`n")
    foreach($change in $verifierCorrespondence.changes){if(([regex]::Matches($expectedVerifier,[regex]::Escape($change.old))).Count -ne $change.count){throw 'verifier replacement occurrence'};$expectedVerifier=$expectedVerifier.Replace([string]$change.old,[string]$change.new)}
    if([IO.File]::ReadAllText($PSCommandPath).Replace("`r`n","`n") -cne $expectedVerifier){throw 'complete verifier correspondence'}
    $checks.Add('full-source-correspondence-codec-and-scheduler')
    $null=Child $compiler @('--version','--verbose')
    foreach($variant in @('native','checked','scalar','scalar-checked')) {
        $exe=Join-Path $work "codec-$variant.exe"
        $argv=@((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C','panic=abort','-C','opt-level=3','-C','link-arg=/DEBUG:NONE','-o',$exe)
        if($variant.EndsWith('checked')){$argv+=@('-C','overflow-checks=yes')}
        if($variant.StartsWith('scalar')){$argv+=@('--cfg','khc_force_scalar_batch')}
        $null=Child $compiler $argv
        Hold $exe "$variant-codec"
    }
    $countedExe=Join-Path $work 'codec-counted.exe'
    $null=Child $compiler @((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C','panic=abort','-C','opt-level=3','-C','overflow-checks=yes','-C','link-arg=/DEBUG:NONE','--cfg','khc_compact_counts','-o',$countedExe)
    Hold $countedExe 'counted-codec'
    foreach($case in @('empty','single','all_bytes','repeated','periodic','seeded_random','fixed')) {
        $input=if($case -ceq 'fixed'){Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'}else{Join-Path $inputRoot "$case.input"}
        $golden=Join-Path $oldRoot "$case-native.frame"
        $oldCalls=@($oldReport.invocations|Where-Object {$_.argv.Count -eq 3 -and $_.argv[0] -ceq 'encode' -and $_.argv[2] -ceq $golden})
        if($oldCalls.Count -ne 1){throw 'unique old encode call required'}
        foreach($variant in @('native','checked','scalar','scalar-checked')) {
            $exe=Join-Path $work "codec-$variant.exe"
            $frame=Join-Path $work "$case-$variant.frame"
            $restore=Join-Path $work "$case-$variant.restore"
            $stdout=Child $exe @('encode',$input,$frame)
            Same $frame $golden
            if($stdout -cne $oldCalls[0].stdout){throw 'exact scheduling/full encode summary changed'}
            $null=Child $exe @('decode',$frame,$restore)
            Same $restore $input
            Hold $frame "$case-$variant-frame";Hold $restore "$case-$variant-restore"
            $checks.Add("$case-$variant-frame-bytes-summary-and-restore")
        }
        $cross=Join-Path $work "$case-old-decoder.restore"
        $null=Child (Join-Path $oldRoot 'codec-native.exe') @('decode',(Join-Path $work "$case-native.frame"),$cross)
        Same $cross $input;Hold $cross "$case-old-decoder-restore"
        $cross=Join-Path $work "$case-new-decoder-old-frame.restore"
        $null=Child (Join-Path $work 'codec-native.exe') @('decode',$golden,$cross)
        Same $cross $input;Hold $cross "$case-new-decoder-old-frame-restore"
        $checks.Add("$case-bidirectional-decoder-interoperability")
    }
    $fixedFrame=Get-Item -LiteralPath (Join-Path $work 'fixed-native.frame')
    if($fixedFrame.Length -ne 483496 -or (Get-FileHash -LiteralPath $fixedFrame.FullName).Hash -cne 'CF62CD2324B4CF889CDDDB25C9508C28E4BD4D24217B93BB7D4FF9318C3EAD12'){throw 'frozen complete frame changed'}
    if($fixedFrame.Length -gt 483599){throw 'size NO-GO'}
    $checks.Add('frozen-complete-frame-and-fixed-size-gate')

    $fixedInput=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    $countedFrame=Join-Path $work 'fixed-counted.frame'
    $countedRestore=Join-Path $work 'fixed-counted.restore'
    $countedEncode=Child $countedExe @('encode',$fixedInput,$countedFrame)
    $split=$countedEncode.IndexOf("`n")
    if($split -lt 0 -or $countedEncode.Substring(0,$split+1) -cne $oldCalls[0].stdout){throw 'counted encode primary stdout'}
    $encodeCounts=$countedEncode.Substring($split+1).Trim()|ConvertFrom-Json
    $countedDecode=Child $countedExe @('decode',$countedFrame,$countedRestore)
    $split=$countedDecode.IndexOf("`n")
    if($split -lt 0){throw 'counted decode diagnostic missing'}
    $decodePrimary=$countedDecode.Substring(0,$split+1)|ConvertFrom-Json
    $decodeCounts=$countedDecode.Substring($split+1).Trim()|ConvertFrom-Json
    if(($encodeCounts|ConvertTo-Json -Compress) -cne ($decodeCounts|ConvertTo-Json -Compress)){throw 'encode/decode compact counters differ'}
    $fixedPrimary=$oldCalls[0].stdout|ConvertFrom-Json
    $heavyEvents=[long](($fixedPrimary.scheduling.processed|Measure-Object -Sum).Sum)
    if($heavyEvents -ne 3223156 -or $encodeCounts.compact_groups -le 0 -or $encodeCounts.compact_groups+$encodeCounts.fallback_groups -ne $heavyEvents*4){throw 'bounded actual compact kernel coverage'}
    if($encodeCounts.plain_array_bytes -ne 32 -or $encodeCounts.legacy_array_bytes -ne 96 -or $encodeCounts.compact_option_bytes -ge 96){throw 'compact diagnostic type layout'}
    if($encodeCounts.node_bytes -ne 12 -or $encodeCounts.node_count -ne 917497 -or $encodeCounts.logical_node_storage_bytes -ne 11009964 -or $encodeCounts.light_prediction_bytes -ne 24 -or $encodeCounts.scheduler_prediction_bytes -le 24){throw 'full actual node/light Prediction layout'}
    $checks.Add('actual-full-node-and-light-prediction-layout')
    if(($decodePrimary.scheduling|ConvertTo-Json -Compress) -cne ($fixedPrimary.scheduling|ConvertTo-Json -Compress)){throw 'counted decode schedule differs'}
    Same $countedFrame (Join-Path $work 'fixed-native.frame')
    Same $countedRestore $fixedInput
    Hold $countedFrame 'counted-fixed-frame';Hold $countedRestore 'counted-fixed-restore'
    $diagnostic=[ordered]@{scope='one native diagnostic encode/decode, no reference cfg, no timing';heavy_events=$heavyEvents;encode=$encodeCounts;decode=$decodeCounts}
    $checks.Add('bounded-actual-kernel-counts-frame-summary-and-restore')

    foreach($case in @('magic','header_crc','payload_crc','truncated','trailing')) {
        $output=Join-Path $work "rejected-$case.restore"
        $null=Child (Join-Path $work 'codec-native.exe') @('decode',(Join-Path $inputRoot "$case.bad"),$output) 1
        if(Test-Path -LiteralPath $output){throw 'corrupt frame output exposed'}
        $checks.Add("$case-refused-no-output")
    }
    foreach($operation in @('encode','decode')) {
        $existing=Join-Path $work "$operation.existing"
        Write-New $existing ([byte[]]@(2,4,6));Hold $existing 'sentinel'
        $input=if($operation -ceq 'encode'){Join-Path $inputRoot 'seeded_random.input'}else{Join-Path $work 'seeded_random-native.frame'}
        $null=Child (Join-Path $work 'codec-native.exe') @($operation,$input,$existing) 1
        if([Convert]::ToHexString([IO.File]::ReadAllBytes($existing)) -cne '020406'){throw 'existing output overwritten'}
        $checks.Add("$operation-no-clobber")
    }
    $missingOutput=Join-Path $work 'missing.restore'
    $null=Child (Join-Path $work 'codec-native.exe') @('encode',(Join-Path $work 'absent.input'),$missingOutput) 1
    if(Test-Path -LiteralPath $missingOutput){throw 'missing input output exposed'}
    $checks.Add('missing-input-refused')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed'}}
    $checks.Add('all-held-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 32
    $pdbs=@(Get-ChildItem -LiteralPath $work -File|Where-Object {$_.Extension -ceq '.pdb'})
    if($pdbs.Count -and !$failure){$failure='unneeded PDB unexpectedly generated'}
    $temporary=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Name.EndsWith('.tmp') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($temporary.Count -and !$failure){$failure='owned temporary/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'correctness_and_size_passed_not_timed'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;verifier=$PSCommandPath;verifier_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');runtime_exe=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;frame_bytes=$(if($fixedFrame){$fixedFrame.Length}else{$null});checks=$checks;identities=$ids;invocations=$calls;owned_tmp_or_reparse=$temporary.Count;owned_pdb=$pdbs.Count;variants=@('native','checked','scalar','scalar-checked');timing_used=$false;compact_diagnostic=$diagnostic;reused_light_state_proof_sha256='99330ECA76275BE5B4B55F1E663612764B4CB88E60A02A8E3FE843B32928109F';reused_node_u32_proof_sha256='9627A3391CDC5995ADF757D2432235F9078899F026B02239AAA829D88EA8DF04'}
    $json=$report|ConvertTo-Json -Depth 10
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes($json))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 32
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;frame_bytes=$report.frame_bytes;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;work=$work;retained_bytes=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}

