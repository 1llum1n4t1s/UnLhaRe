#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-bwt-causal-bayes-q32-kt-reciprocal-20261001'
$oldRoot=Join-Path $root 'build/khc-q32-balanced-kt-numeric-20261001-junction-validated'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse rejected: $p"};$p=[IO.Path]::GetDirectoryName($p)}
}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Hold([string]$Path,[string]$Role,[string]$Expected=''){
    No-Reparse $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'))
    $id=Identity $Path;if($Expected -and $id.sha256 -cne $Expected){throw "Pin mismatch: $Path"}
    $ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id
}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Check([string]$Name){$checks.Add([pscustomobject]@{name=$Name;passed=$true})}
function Same-Bytes([string]$Left,[string]$Right){
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Left)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Right))){throw "Full byte mismatch: $Left / $Right"}
}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected=0){
    $row=[ordered]@{program=$Program;argv=$Argv;exit=$null;expected_exit=$Expected;timeout=$false;stdout='';stderr=''};$calls.Add($row)
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$outTask=$null;$errTask=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Child start failed'}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw '120s child timeout'}
        $row.stdout=$outTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$p.ExitCode
        if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and $row.stdout)){throw 'Unexpected child exit/output'}
        [pscustomobject]$row
    }finally{
        if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
        if($null -ne $outTask){$row.stdout=$outTask.GetAwaiter().GetResult()};if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()};if($started){$row.exit=$p.ExitCode};$p.Dispose()
    }
}
function Refuse([string]$Exe,[string]$InputPath,[string]$OutputPath,[string]$Reason){
    $row=Invoke-Child $Exe @($InputPath,$OutputPath) 1
    if($row.stderr -notmatch $Reason -or (Test-Path -LiteralPath $OutputPath)){throw "Refusal/publication mismatch: $Reason"}
    Check "refusal-$([IO.Path]::GetFileNameWithoutExtension($InputPath))-$([IO.Path]::GetFileName($Exe))"
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned work root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;fixed_frames=@();inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;gate=@{maximum_archive_bytes=483599;maximum_encode_ms_exclusive=574.5624;timing_pass=$null};limitations=@('Focused codec E2E; not a fresh audit of all prior 87 checks.','No speed adoption/product integration/general 7-Zip superiority claim.','Forced portable x64 is not native ARM64/macOS verification.','Research CreateNew publication is not the product parent-handle safety contract.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"kt-reciprocal-codec","retain":"reproducible full codec CLI E2E evidence"}'))
try{
    $pins=@{
        'experiments/khc/Q32_KT_RECIPROCAL_CODEC_CONTRACT_20261001.md'='4A92D5C29D9DD1A08B55BB873FD29653C6783E91AF72FFED5F0CDB010BE9F783'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/cts_model.rs'='ACEAA15363123470FA09481BF6408FF2BDFF95A15D65489D64A9998B8E26F6C7'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/exact_kt.rs'='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/verify-model.ps1'='254F95D35A6B11D5F52AC3D0EFD1D85EB64E2A527FCAEDF9E6FA13E80654CF76'
        'build/khc-q32-kt-reciprocal-model-20261001/report.json'='4D06E360637DCB16F8422EA149295B3F5B23B7D067B70638885DA8172A679B84'
        'experiments/khc/Q32_NATIVE32_CODEC_CONTRACT_20261001.md'='9B711FFF704B1890AD7FFA8510DD5E14506615E4946DDF12C7056FB04CFF4544'
        'experiments/khc/causal-bayes-q32-native32/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
        'experiments/khc/causal-bayes-q32-balanced-kt/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
        'experiments/khc/causal-bayes-q32-native32/cts_model.rs'='27775D82F1A94E013C83A2D42C8A004D7EF507ED09302EB1BB0704DCC798B0A0'
        'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
        'experiments/khc/causal-bayes-q32-native32/verify-model.ps1'='A85145449FE86B22CE8AAABA5A3506A2DFBC2712CFCCFF6CA966845D257F52AD'
        'build/khc-q32-native32-model-20261001-inherited-format/report.json'='89C9D6773D95A281C01437BB4653DE50B4716638A2F597AD13467B2CFA347B58'
        'build/khc-native32-quotient-numeric-20261001/report.json'='DF1FCBAA5884D8DB2B7234F5DF7A0356C1C3A5D198204929DEDB1F9C836EE656'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/report.json'='AB486DC5C8CE3DAE36B1A91EACCE1BE77F7084F52122B26C3EC6A629C59A06F4'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'='7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0'
        'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
        'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
        'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
        'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
        'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
        'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
    }
    foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-contract-or-parent' $pin.Value}
    $null=Hold $PSCommandPath 'verifier';$null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Same-Bytes (Join-Path $PSScriptRoot 'codec.rs') (Join-Path $PSScriptRoot '../causal-bayes-q32-balanced-kt/codec.rs');Check 'codec-source-byteexact'
    $modelProof=Get-Content -LiteralPath (Join-Path $root 'build/khc-q32-kt-reciprocal-model-20261001/report.json') -Raw|ConvertFrom-Json
    if($modelProof.status -cne 'verified_model_not_timed' -or $modelProof.checks.Count -ne 62 -or $modelProof.invocations.Count -ne 59 -or $modelProof.identities.Count -ne 107 -or $modelProof.model_history.records -ne 11267 -or $modelProof.table_storage_bytes -ne 524296 -or $modelProof.owned_tmp_count -ne 0 -or $modelProof.owned_reparse_count -ne 0 -or @($modelProof.identities|Where-Object {$_.before_sha256 -cne $_.after_sha256 -or $_.before_bytes -ne $_.after_bytes}).Count -or $modelProof.timing_used -or @($modelProof.checks|Where-Object {-not $_.passed}).Count){throw 'Model prerequisite mismatch'}
    # 今回source/compiler/親proofは直接lockする。全履歴再DFSを性能の前提としない。
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'PowerShell Parser failure'}
    $null=Invoke-Child $compiler @('--version','--verbose')
    $executables=@()
    foreach($portable in @($false,$true)){
        $mode=if($portable){'portable'}else{'native'};$exe=Join-Path $work "codec-$mode.exe"
        $argv=@('--edition=2024','-C','panic=abort','-C','opt-level=3')
        if($portable){$argv+=@('--cfg','khc_force_portable')};$argv+=@((Join-Path $PSScriptRoot 'codec.rs'),'-o',$exe)
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-codec';$executables+=@{path=$exe;mode=$mode}
    }
    $frozen=Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'
    $frozenFrame=Join-Path $root 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/fixed.frame'
    $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    if((Get-Item -LiteralPath $group).Length -ne 2811006){throw 'Fixed group size mismatch'}
    $fixtures=[ordered]@{empty=[byte[]]@();single=[byte[]]@(42);all_bytes=[byte[]](0..255);repeated=[byte[]]::new(8192);periodic=[byte[]]::new(16384);seeded_random=[byte[]]::new(8192)}
    [Array]::Fill($fixtures.repeated,[byte]65)
    for($i=0;$i -lt $fixtures.periodic.Length;$i++){$fixtures.periodic[$i]=[byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i%11])}
    [Random]::new(20260930).NextBytes($fixtures.seeded_random)
    $allCases=@($fixtures.Keys)+@('fixed')
    foreach($case in $allCases){
        $fixture=if($case -eq 'fixed'){$group}else{Join-Path $work "$case.input"}
        if($case -ne 'fixed'){Write-New $fixture $fixtures[$case];$null=Hold $fixture 'codec-input'}
        $oldFrame=Join-Path $work "$case-old.frame"
        $oldStats=Invoke-Child $frozen @('encode',$fixture,$oldFrame);$owned.Add($oldFrame);$null=Hold $oldFrame 'old-codec-raw'
        if($case -eq 'fixed'){Same-Bytes $oldFrame $frozenFrame}
        foreach($executable in $executables){
            $prefix="$case-$($executable.mode)";$frame=Join-Path $work "$prefix.frame";$restored=Join-Path $work "$prefix.restored"
            $row=Invoke-Child $executable.path @('encode',$fixture,$frame);$owned.Add($frame);$null=Hold $frame 'new-codec-frame';Same-Bytes $frame $oldFrame
            if($row.stdout -cne $oldStats.stdout){throw 'Encode Stats differs from frozen codec'}
            $null=Invoke-Child $executable.path @('decode',$frame,$restored);$owned.Add($restored);$null=Hold $restored 'new-codec-restored';Same-Bytes $restored $fixture
            Check "frame-and-decode-$prefix"
            if($case -eq 'fixed'){
                if((Get-Item -LiteralPath $frame).Length -ne 483469){throw 'Fixed archive size mismatch'};$report.fixed_frames+=Identity $frame
                $cross=Join-Path $work "$prefix-cross-old.restored"
                $null=Invoke-Child $frozen @('decode',$frame,$cross);$owned.Add($cross);$null=Hold $cross 'old-decoder-cross';Same-Bytes $cross $group;Check "new-frame-old-decoder-$prefix"
                $cross=Join-Path $work "$prefix-cross-new.restored"
                $null=Invoke-Child $executable.path @('decode',$frozenFrame,$cross);$owned.Add($cross);$null=Hold $cross 'new-decoder-cross';Same-Bytes $cross $group;Check "old-frame-new-decoder-$prefix"
            }
        }
    }
    $repeat=Join-Path $work 'fixed-native-repeat.frame'
    $null=Invoke-Child $executables[0].path @('encode',$group,$repeat);$owned.Add($repeat);$null=Hold $repeat 'repeat-frame';Same-Bytes $repeat $frozenFrame;Check 'fixed-native-repeat-fullbytes'
    $base=[IO.File]::ReadAllBytes((Join-Path $work 'periodic-native.frame'))
    $corrupt=[ordered]@{}
    $mut=$base.Clone();$mut[0]=$mut[0] -bxor 1;$corrupt.magic=$mut
    $mut=$base.Clone();$mut[32]=$mut[32] -bxor 1;$corrupt.header_crc=$mut
    $mut=$base.Clone();$mut[$mut.Length-1]=$mut[$mut.Length-1] -bxor 1;$corrupt.payload_crc=$mut
    $mut=[byte[]]::new($base.Length+1);[Array]::Copy($base,$mut,$base.Length);$corrupt.trailing=$mut
    $corrupt.truncated=[byte[]]$base[0..($base.Length-2)]
    foreach($case in $corrupt.Keys){$path=Join-Path $work "$case.frame";Write-New $path $corrupt[$case];$null=Hold $path 'corrupt-frame'}
    foreach($executable in $executables){
        foreach($case in $corrupt.Keys){
            $output=Join-Path $work "$case-$($executable.mode).refused"
            $row=Invoke-Child $executable.path @('decode',(Join-Path $work "$case.frame"),$output) 1
            if($row.stderr -notmatch 'rejected:' -or (Test-Path -LiteralPath $output)){throw 'Malformed frame accepted/published'};Check "malformed-$case-$($executable.mode)"
        }
        foreach($operation in @('encode','decode')){
            $sentinel=Join-Path $work "existing-$operation-$($executable.mode).output";Write-New $sentinel ([byte[]]@(31,41,59));$before=Identity $sentinel
            $fixture=if($operation -eq 'encode'){Join-Path $work 'single.input'}else{Join-Path $work 'single-native.frame'}
            $row=Invoke-Child $executable.path @($operation,$fixture,$sentinel) 1
            if($row.stderr -notmatch 'output create_new:' -or (Identity $sentinel).sha256 -cne $before.sha256){throw 'No-clobber mismatch'}
            $null=Hold $sentinel 'no-clobber-sentinel';Check "no-clobber-$operation-$($executable.mode)"
        }
    }
    $report.status='correctness_and_size_passed_not_timed'
}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw 'Source/raw after identity changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}}
    foreach($held in $locks){$held.Dispose()}
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{path=$_.FullName;name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null};reparse=(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}})
    $report.owned_tmp_count=@($report.inventory|Where-Object {$_.name -like '*.tmp'}).Count;$report.owned_reparse_count=@($report.inventory|Where-Object {$_.reparse}).Count
    if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Owned tmp/reparse remains'}}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)))
}
if($null -ne $failure){throw $failure}
"Codec E2E passed: $($checks.Count) checks; $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
