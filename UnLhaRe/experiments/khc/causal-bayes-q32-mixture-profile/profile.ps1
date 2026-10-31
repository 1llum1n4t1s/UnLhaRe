#requires -Version 7.2
param()
# 準備した診断だけを単一実行する。自動retry・正式速度採用は禁止。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-q32-mixture-phase-profile-20261001-quiet-interval'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe'
$normal=Join-Path $root 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/candidate.exe'
$group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
$fixed=Join-Path $root 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/full-e2e/fixed.frame'
$proof=Join-Path $root 'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/performance/report.json'
$observer=Join-Path $PSScriptRoot '../causal-bayes-float-cts/quiet-host.ps1'
$pins=[ordered]@{
    'experiments/khc/Q32_MIXTURE_PHASE_QUIET_INTERVAL_20261001.md'='EED4C142BDDDDABE7A4C56ED82AF2015FBA6F8555417D7F9FF10A6191E75122B'
    'experiments/khc/causal-bayes-q32-mixture-reuse/codec.rs'='9D757709834F501B83929C2882BCE6053FCA5CFC5AAEEC2B4A16EED7AE58680B'
    'experiments/khc/causal-bayes-q32-mixture-reuse/cts_model.rs'='BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2'
    'experiments/khc/causal-bayes-q32-mixture-profile/codec.rs'='A3B5E44469D173B49FA911F92DB9953E62D469728B35D100ABF0D671C66BB9C5'
    'experiments/khc/causal-bayes-log-table/bayes_model.rs'='E50A6DDFEB93044A7A7DBFAC6881F863DE94E194F3E5EF50A9E8E211D4181422'
    'experiments/khc/causal-bayes-sais/bwt.rs'='810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
    'experiments/khc/rejected-binary-mix/packed_alphabet.rs'='4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
    'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
    'experiments/khc/split-estimate-quotient/exact_div.rs'='D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'
    'experiments/khc/causal-bayes-float-cts/quiet-host.ps1'='E66D39AE8BCDAD63BC7D3FC467D4C85E950261749D457D33C4BFA9D3ED13FFBF'
    'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/candidate.exe'='4B39B65E931479E151322E92E69198F3ED6A6A6A5E3F1DBFB389BC02DEF19446'
    'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/full-e2e/fixed.frame'='7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
    'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    'build/khc-bwt-causal-bayes-q32-mixture-reuse-20261001/performance/report.json'='D8A30E13006FC1CDFDB27AB6688560AC3C1397D042F112245701DDF16D28EF11'
    'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
}
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$identities=[Collections.Generic.List[object]]::new()
$calls=[Collections.Generic.List[object]]::new()
$profiles=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$report=[ordered]@{
    status='failed'; error=$null; error_script_stack_trace=$null; error_position_message=$null; started_utc=[DateTime]::UtcNow.ToString('o')
    diagnostic_only=$true; formal_timing_used=$false; adoption_decision=$false
    settings=@{profile_encodes=3;normal_encodes=1;child_deadline_seconds=120;automatic_retry=$false;opt_level=3}
    provenance=$identities; invocations=$calls; phase_runs=$profiles; checks=$checks
    host_load_observations=$null; inventory=@(); unexpected_files=@()
    phase_formula='elapsed_ns = (end - start).as_nanos(); parent includes children and timer overhead; never sum nested spans'
    limitations=@('Instrumented overhead is included; neither CLI timing nor these three runs establish formal speed or adoption.',
        'Entropy loop groups primary/CTS/Bayes/range; their individual costs are not measured.',
        'Model allocation/LUT span includes Stream/range construction; phase totals omit boundaries and are not exact parent partitions.',
        'RAII drop order may place stream/last deallocation outside child spans but inside parent spans; child sums are not an exact parent partition.',
        'Fixed development corpus only; no generalization or holdout claim.')
}
function Assert-NoReparse([string]$Path) {
    $current=[IO.Path]::GetFullPath($Path)
    while($current) {
        if((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw "Reparse rejected: $current"}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path) {
    Assert-NoReparse $Path
    $file=Get-Item -LiteralPath $Path -Force
    if($file -isnot [IO.FileInfo]){throw "Not regular file: $Path"}
    [pscustomobject]@{path=$file.FullName;bytes=$file.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}
}
function Lock-File([string]$Path,[string]$Expected='') {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $id=Identity $Path
    $row=[pscustomobject]@{path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null}
    $identities.Add($row)
    if($Expected -and $id.sha256 -cne $Expected){throw "Hash pin mismatch: $Path"}
}
function Write-New([string]$Path,[byte[]]$Bytes) {
    Assert-NoReparse $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Invoke-Child([string]$Program,[string[]]$Argv,[string]$Label,[int]$Expected=0) {
    $row=[ordered]@{label=$Label;program=$Program;argv=$Argv;exit=$null;timeout=$false;stdout='';stderr=''}
    $calls.Add($row)
    $process=[Diagnostics.Process]::new()
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$root
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $process.StartInfo=$info
    $started=$false;$outTask=$null;$errTask=$null
    try {
        Assert-QuietHost "$Label-before"
        $started=$process.Start()
        if(-not $started){throw 'Child start failed.'}
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(120000)){$row.timeout=$true;throw "Child deadline exceeded: $Label"}
        $row.stdout=$outTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$process.ExitCode
        if($row.exit -ne $Expected){throw "Unexpected child exit: $Label/$($row.exit)"}
    } finally {
        if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
        if($null -ne $outTask){$row.stdout=$outTask.GetAwaiter().GetResult()}
        if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()}
        if($started){$row.exit=$process.ExitCode}
        $process.Dispose()
        Assert-QuietHost "$Label-after"
    }
    [pscustomobject]$row
}
function Assert-Bytes([string]$Actual,[string]$Reference,[string]$Label) {
    $left=Identity $Actual;$right=Identity $Reference
    if($left.bytes -ne $right.bytes -or $left.sha256 -cne $right.sha256 -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($Actual)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Reference))){throw "Full byte mismatch: $Label"}
    $checks.Add([pscustomobject]@{label=$Label;passed=$true;bytes=$left.bytes;sha256=$left.sha256;full_byte_comparison=$true})
}
function Assert-Stats($Stats,[string]$Operation,[string]$ArchiveInputPath,[string]$ArchiveOutputPath,$Reference=$null) {
    foreach($field in @('input_bytes','output_bytes','runs','primary','alphabet_symbols','payload_bytes','plain_crc','payload_crc')) {
        if($null -eq $Stats.PSObject.Properties[$field] -or $Stats.$field -isnot [long] -and $Stats.$field -isnot [int]){throw "Invalid integer Stats: $field"}
        if($null -ne $Reference -and $Stats.$field -ne $Reference.$field){throw "Stats mismatch: $field"}
    }
    if($Stats.operation -cne $Operation -or $Stats.input_bytes -ne (Identity $ArchiveInputPath).bytes -or $Stats.output_bytes -ne (Identity $ArchiveOutputPath).bytes){throw 'Stats operation/length mismatch.'}
}
function Parse-Profile($Row,[string]$Operation,[string]$ArchiveInputPath,[string]$ArchiveOutputPath,$Reference=$null) {
    $lines=@($Row.stdout -split '\r?\n' | Where-Object {$_})
    if($lines.Count -ne 2){throw 'Expected separate Stats and diagnostic JSON lines.'}
    $stats=$lines[0]|ConvertFrom-Json
    Assert-Stats $stats $Operation $ArchiveInputPath $ArchiveOutputPath $Reference
    $diag=$lines[1]|ConvertFrom-Json
    if($diag.role -cne 'diagnostic_phase_profile' -or $diag.operation -cne $Operation -or $diag.unit -cne 'elapsed_ns'){throw 'Diagnostic role/unit mismatch.'}
    $names=@('main_read_ns','main_encode_ns','main_publish_ns')
    if($Operation -ceq 'encode'){$names+=@('encode_bwt_ns','encode_payload_ns','encode_frame_crc_build_ns','payload_prepare_ns','payload_model_allocation_lut_ns','payload_entropy_loop_ns','payload_range_finish_ns')}
    if(@($diag.phases.PSObject.Properties).Count -ne $names.Count){throw 'Unexpected phase count.'}
    foreach($name in $names){
        $value=$diag.phases.$name
        if(($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0){throw "Invalid elapsed integer ns: $name"}
    }
    $diag
}
Assert-NoReparse $work
if(Test-Path -LiteralPath $work){throw 'Existing diagnostic root rejected; no overwrite.'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
try {
    foreach($entry in $pins.GetEnumerator()){
        $path=if([IO.Path]::IsPathRooted($entry.Key)){$entry.Key}else{Join-Path $root $entry.Key}
        Lock-File $path $entry.Value
    }
    Lock-File $PSCommandPath
    Lock-File (Join-Path $PSScriptRoot '../Q32_MIXTURE_PHASE_PROFILE_CONTRACT_20261001.md')
    Lock-File $formatter
    if((Identity $group).bytes -ne 2811006 -or (Identity $fixed).bytes -ne 483469){throw 'Fixed input/frame length mismatch.'}
    $normalProof=Get-Content -LiteralPath $proof -Raw|ConvertFrom-Json
    if($normalProof.status -cne 'success'){throw 'Normal performance proof failed.'}
    foreach($id in $normalProof.provenance){
        if($id.before_sha256 -cne $id.after_sha256 -or $id.before_bytes -ne $id.after_bytes){throw 'Normal performance source provenance changed.'}
        Lock-File $id.path $id.before_sha256
        if((Identity $id.path).bytes -ne $id.before_bytes){throw 'Normal performance provenance length mismatch.'}
    }
    . $observer
    $report.host_load_observations=$hostLoadObservations
    Assert-QuietHost 'preflight' 5
    $tokens=$null;$parseErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors.Count){throw 'PowerShell Parser rejected script.'}
    $null=Invoke-Child $compiler @('--version') 'compiler-version'
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot 'codec.rs')) 'fmt-check'
    $exe=Join-Path $work 'profile.exe'
    $null=Invoke-Child $compiler @((Join-Path $PSScriptRoot 'codec.rs'),'--edition','2024','-C','panic=abort','-C','opt-level=3','-o',$exe) 'compile-profile'
    Lock-File $exe
    $normalFrame=Join-Path $work 'normal.frame'
    $normalRow=Invoke-Child $normal @('encode',$group,$normalFrame) 'normal-encode'
    $normalLines=@($normalRow.stdout -split '\r?\n'|Where-Object {$_})
    if($normalLines.Count -ne 1){throw 'Normal Stats must occupy one JSON line.'}
    $normalStats=$normalLines[0]|ConvertFrom-Json
    Assert-Stats $normalStats 'encode' $group $normalFrame
    Assert-Bytes $normalFrame $fixed 'normal-fixed-frame'
    $framePaths=@()
    for($i=1;$i -le 3;$i++){
        $frame=Join-Path $work "profile-$i.frame";$framePaths+=$frame
        $row=Invoke-Child $exe @('encode',$group,$frame) "profile-encode-$i"
        $profiles.Add((Parse-Profile $row 'encode' $group $frame $normalStats))
        Assert-Bytes $frame $fixed "profile-$i-fixed-frame"
    }
    $restored=Join-Path $work 'profile-decode-normal.group'
    $row=Invoke-Child $exe @('decode',$normalFrame,$restored) 'profile-decode-normal'
    $null=Parse-Profile $row 'decode' $normalFrame $restored
    Assert-Bytes $restored $group 'profile-decode-normal-hash'
    for($i=1;$i -le 3;$i++){
        $restored=Join-Path $work "normal-decode-profile-$i.group"
        $row=Invoke-Child $normal @('decode',$framePaths[$i-1],$restored) "normal-decode-profile-$i"
        $stats=$row.stdout.Trim()|ConvertFrom-Json
        Assert-Stats $stats 'decode' $framePaths[$i-1] $restored
        Assert-Bytes $restored $group "normal-decode-profile-$i-hash"
    }
    $sentinel=Join-Path $work 'no-clobber.sentinel'
    Write-New $sentinel ([Text.Encoding]::UTF8.GetBytes('phase-profile-no-clobber'))
    $sentinelBefore=Identity $sentinel
    foreach($program in @($normal,$exe)){
        foreach($operation in @('encode','decode')){
            $inputPath=if($operation -ceq 'encode'){$group}else{$fixed}
            $row=Invoke-Child $program @($operation,$inputPath,$sentinel) "no-clobber-$([IO.Path]::GetFileName($program))-$operation" 1
            if($row.stderr -notmatch 'output create_new:'){throw 'No-clobber rejection reason mismatch.'}
            $after=Identity $sentinel
            if($after.bytes -ne $sentinelBefore.bytes -or $after.sha256 -cne $sentinelBefore.sha256){throw 'Sentinel modified.'}
            $checks.Add([pscustomobject]@{label=$row.label;passed=$true;sha256=$after.sha256})
        }
    }
    $report.status='diagnostic_verified_not_adoption'
} catch {
    $failure=$_
    $report.error=$_.Exception.ToString()
    $report.error_script_stack_trace=$_.ScriptStackTrace
    $report.error_position_message=$_.InvocationInfo.PositionMessage
}
finally {
    foreach($id in $identities){
        try{
            $after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256
            if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw "Source-after identity changed: $($id.path)"}
        }catch{
            $report.status='failed'
            $report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; '
            if($null -eq $failure){
                $failure=$_
                $report.error_script_stack_trace=$_.ScriptStackTrace
                $report.error_position_message=$_.InvocationInfo.PositionMessage
            }
        }
    }
    $allowed=@('profile.exe','profile.pdb','normal.frame','profile-1.frame','profile-2.frame','profile-3.frame','profile-decode-normal.group','normal-decode-profile-1.group','normal-decode-profile-2.group','normal-decode-profile-3.group','no-clobber.sentinel')
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null}}})
    $report.unexpected_files=@($report.inventory|Where-Object {$_.name -cnotin $allowed})
    if($report.unexpected_files.Count){$report.status='failed';$report.error=(@($report.error,'Unexpected temporary/root entry.')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Unexpected temporary/root entry.'}}
    foreach($held in $locks){$held.Dispose()}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 24)))
}
if($null -ne $failure){throw $failure}
$profiles|ConvertTo-Json -Depth 8

