#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# 先行契約の失敗条件を検査する実CLI診断。時間は速度採用に使わない。
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-bayes-equality-eligibility-20261001'
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$pins=[Collections.Generic.List[object]]::new()
$calls=[Collections.Generic.List[object]]::new()
$report=[ordered]@{status='failed';error=$null;timing_used=$false;provenance=$pins;invocations=$calls;counts=$null;created_utc=[DateTime]::UtcNow.ToString('o')}
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$f=Get-Item -LiteralPath $Path -Force;if($f -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$f.FullName;bytes=$f.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Pin([string]$Path,[string]$Role,[string]$Expected=''){
    No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path
    if($Expected -and $id.sha256 -cne $Expected){throw "Pin mismatch: $Role"}
    $pins.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});return $id
}
function Child([string]$Program,[string[]]$Argv,[string]$Kind){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    $row=[ordered]@{kind=$Kind;program=$Program;argv=$Argv;exit=$null;stdout='';stderr='';timeout=$false};$calls.Add($row)
    try{$started=$p.Start();if(-not $started){throw 'Start failed.'};$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw 'Child timeout.'};$row.exit=$p.ExitCode;$row.stdout=$o.GetAwaiter().GetResult();$row.stderr=$e.GetAwaiter().GetResult();if($row.exit -ne 0 -or $row.stderr){throw "Child failed: $Kind"};return [pscustomobject]$row}
    finally{if($started -and -not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
}
No-Reparse $work;if(Test-Path -LiteralPath $work){throw 'Existing root refused.'};$null=New-Item -ItemType Directory -Path $work
try{
    $source=Pin (Join-Path $PSScriptRoot 'codec.rs') 'diagnostic-source'
    $null=Pin $PSCommandPath 'harness'
    $null=Pin (Join-Path $PSScriptRoot '../BAYES_EQUALITY_ELIGIBILITY_20261001.md') 'contract'
    $null=Pin (Join-Path $PSScriptRoot '../causal-bayes-q32/codec.rs') 'frozen-q32-source' 'A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    $null=Pin (Join-Path $PSScriptRoot '../causal-bayes-q32/cts_model.rs') 'cts' '52CD54524DD89565DBEEEA2B1F3B5E89668DD8429453692663D3EDAA6D488D88'
    $null=Pin (Join-Path $PSScriptRoot '../causal-bayes-packed/bayes_model.rs') 'bayes' '65658333E8D3EB5EBD71B05AEBCD653B8E3506580203439C2E8912DFE3DB0EB9'
    $null=Pin (Join-Path $PSScriptRoot '../causal-bayes-sais/bwt.rs') 'bwt' '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
    $null=Pin (Join-Path $PSScriptRoot '../range.rs') 'range' '1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
    $null=Pin (Join-Path $PSScriptRoot '../rejected-binary-mix/packed_alphabet.rs') 'packed' '4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
    $proof=Pin (Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/report.json') 'full-proof' '2F7F612F63570CD58976F16F42D4DD3255DAE0DD242B6891B5CB3946463C006C'
    $group=Pin (Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group') 'fixed-group' '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    if($group.bytes -ne 2811006){throw 'Group size mismatch.'}
    $compiler=Pin 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' 'rustc' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $report['environment']=[ordered]@{os=[Runtime.InteropServices.RuntimeInformation]::OSDescription;ps=$PSVersionTable.PSVersion.ToString();cwd=$PWD.Path;source=$source.path;source_mtime=(Get-Item -LiteralPath $source.path).LastWriteTimeUtc.ToString('o');cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors)}
    $exe=Join-Path $work 'diagnostic.exe'
    $null=Child $compiler.path @($source.path,'--edition=2024','-C','opt-level=3','-C','panic=abort','-o',$exe) 'compile'
    $null=Pin $exe 'diagnostic-exe';$null=Pin (Join-Path $work 'diagnostic.pdb') 'diagnostic-pdb'
    $frame=Join-Path $work 'fixed.frame';$restore=Join-Path $work 'fixed.restored.group'
    $encoded=Child $exe @('encode',$group.path,$frame) 'encode'
    $frameId=Pin $frame 'generated-frame'
    if($frameId.bytes -ne 483469 -or $frameId.sha256 -cne '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'){throw 'Diagnostic changed the frozen full frame.'}
    $decoded=Child $exe @('decode',$frame,$restore) 'decode'
    $restored=Pin $restore 'generated-restore'
    if($restored.bytes -ne $group.bytes -or $restored.sha256 -cne $group.sha256 -or -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($group.path),[IO.File]::ReadAllBytes($restore))){throw 'Raw restore differs.'}
    $ec=@($encoded.stdout.Trim().Split("`n")|ForEach-Object {$_|ConvertFrom-Json});$dc=@($decoded.stdout.Trim().Split("`n")|ForEach-Object {$_|ConvertFrom-Json})
    if($ec.Count -ne 2 -or $dc.Count -ne 2 -or $ec[0].operation -cne 'encode' -or $dc[0].operation -cne 'decode' -or $ec[1].operation -cne 'bayes-equality-eligibility' -or $dc[1].operation -cne 'bayes-equality-eligibility'){throw 'JSON schema mismatch.'}
    $classes=[Collections.Generic.List[object]]::new();$sumTotal=0L;$sumEqual=0L
    if($ec[1].total.Count -ne 7 -or $ec[1].equal.Count -ne 7 -or $dc[1].total.Count -ne 7 -or $dc[1].equal.Count -ne 7){throw 'Class count mismatch.'}
    for($i=0;$i -lt 7;$i++){
        $total=[long]$ec[1].total[$i];$equal=[long]$ec[1].equal[$i]
        if($total -lt 0 -or $equal -lt 0 -or $equal -gt $total -or $total -gt 562036803 -or $total -ne $dc[1].total[$i] -or $equal -ne $dc[1].equal[$i]){throw 'Counter mismatch.'}
        $sumTotal+=$total;$sumEqual+=$equal;$classes.Add([pscustomobject]@{class=$i;total=$total;equal=$equal})
    }
    if($sumTotal -le 0 -or $sumTotal -gt 562036803){throw 'Observation total outside grammar bound.'}
    $report.counts=[ordered]@{classes=$classes;total=$sumTotal;equal=$sumEqual;fraction=[double]$sumEqual/$sumTotal;encode_decode_equal=$true}
    $report['frame']=$frameId;$report['restore']=$restored;$report.status='verified'
}catch{$report.error=$_.Exception.ToString()}
finally{
    foreach($pin in $pins){try{$after=Identity $pin.path;$pin.after_bytes=$after.bytes;$pin.after_sha256=$after.sha256;if($pin.before_bytes -ne $after.bytes -or $pin.before_sha256 -cne $after.sha256){throw 'Identity changed.'}}catch{$report.status='failed';$report.error=[string]$_}}
    foreach($held in $locks){$held.Dispose()}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o');No-Reparse $work
    $f=[IO.File]::Open((Join-Path $work 'report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$data=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12));$f.Write($data);$f.Flush($true)}finally{$f.Dispose()}
}
if($report.status -cne 'verified'){throw $report.error}
$report.counts|ConvertTo-Json -Depth 4
