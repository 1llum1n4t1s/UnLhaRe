#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# 先に失敗条件: 65536件での長さ/結果不一致、最大長±1、0/15byte header、
# 最大countだけの短い入力、不正入力の公開、既存出力上書き、実exit/JSONの不一致。
# 元BigInteger照合済みtriplesを循環反復し、input/oracleのheaderだけ最大countへ設定する。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$sourceRoot=Join-Path $repo 'build/khc-bwt-causal-bayes-exact-div-20260930'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $repo 'build'))+[IO.Path]::DirectorySeparatorChar
function No-Reparse([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path){
    No-Reparse $Path
    $item=Get-Item -LiteralPath $Path
    if($item -isnot [IO.FileInfo]){throw 'Regular file required.'}
    [pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}
}
function Write-New([string]$Path,[byte[]]$Bytes){
    No-Reparse $Path
    $sink=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$sink.Write($Bytes);$sink.Flush($true)}finally{$sink.Dispose()}
}
if(-not $work.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work
$null=New-Item -ItemType Directory -Path $work
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$ids=[Collections.Generic.List[object]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$failure=$null
function Invoke-Check([string]$Program,[string]$InputPath,[string]$OutputPath,[int]$ExpectedExit){
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.WorkingDirectory=$work;$info.ArgumentList.Add($InputPath);$info.ArgumentList.Add($OutputPath)
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        $started=$process.Start();if(-not $started){throw 'Start failed.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)){throw 'Child timeout.'}
        $row=[pscustomobject]@{program=$Program;argv=@($InputPath,$OutputPath);exit=$process.ExitCode;expected_exit=$ExpectedExit;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($row)
        if($row.exit -ne $ExpectedExit -or ($ExpectedExit -eq 0 -and $row.stderr) -or ($ExpectedExit -ne 0 -and $row.stdout)){throw 'Unexpected process result.'}
        $row
    }finally{if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
try{
    $proofPath=Join-Path $sourceRoot 'numeric-e2e/report.json'
    $proof=Get-Content -LiteralPath $proofPath -Raw|ConvertFrom-Json
    if($proof.status -cne 'verified' -or (Get-FileHash -LiteralPath $proofPath).Hash -cne '7F30002807B10D7D0A6423A751FCE47AECFCDA022D581C234294991F87C9BDF0'){throw 'Original numerical proof mismatch.'}
    $inputPath=Join-Path $sourceRoot 'numeric-e2e/triples.input'
    $oraclePath=Join-Path $sourceRoot 'numeric-e2e/bigint.expected'
    $oracleId=$proof.checks[0].oracle
    if((Identity $oraclePath).sha256 -cne $oracleId.sha256){throw 'Verified oracle mismatch.'}
    foreach($path in @($PSCommandPath,$proofPath,$inputPath,$oraclePath,(Join-Path $sourceRoot 'audit.exe'),(Join-Path $sourceRoot 'audit-portable.exe'),(Join-Path $PSScriptRoot 'exact_div.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'))){
        $id=Identity $path;$locks.Add([IO.File]::Open($id.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$ids.Add($id)
    }
    $original=[IO.File]::ReadAllBytes($inputPath);$oracle=[IO.File]::ReadAllBytes($oraclePath)
    $count=[BitConverter]::ToUInt32($original,8)
    if($count -ne 23608 -or $original.Length -ne 16+24*$count -or $oracle.Length -ne 16+16*$count){throw 'Original batch bounds mismatch.'}
    $max=[byte[]]::new(16+24*65536);$expected=[byte[]]::new(16+16*65536)
    [Array]::Copy($original,0,$max,0,16);[Array]::Copy($oracle,0,$expected,0,16)
    [BitConverter]::GetBytes([uint32]65536).CopyTo($max,8);[BitConverter]::GetBytes([uint32]65536).CopyTo($expected,8)
    $counts=@{success=0;zero=0;overflow=0}
    for($i=0;$i -lt 65536;$i++){
        $j=$i%$count;[Array]::Copy($original,16+24*$j,$max,16+24*$i,24);[Array]::Copy($oracle,16+16*$j,$expected,16+16*$i,16)
        switch([BitConverter]::ToUInt64($expected,16+16*$i)){0{$counts.success++}1{$counts.zero++}2{$counts.overflow++}default{throw 'Unknown oracle tag.'}}
    }
    $maxPath=Join-Path $work 'max.input';Write-New $maxPath $max
    $expectedPath=Join-Path $work 'max.expected';Write-New $expectedPath $expected;$expectedId=Identity $expectedPath
    foreach($pair in @(@('audit.exe','native',$false),@('audit-portable.exe','portable',$true))){
        $output=Join-Path $work "$($pair[1]).output";$run=Invoke-Check (Join-Path $sourceRoot $pair[0]) $maxPath $output 0
        $json=$run.stdout|ConvertFrom-Json;$actual=Identity $output
        if($actual.sha256 -cne $expectedId.sha256 -or $actual.bytes -ne $expectedId.bytes -or $json.operation -cne 'ratio-audit' -or $json.cases -ne 65536 -or $json.success -ne $counts.success -or $json.zero -ne $counts.zero -or $json.overflow -ne $counts.overflow -or $json.portable -ne $pair[2]){throw 'Maximum batch differs from oracle.'}
        $checks.Add([pscustomobject]@{name="maximum-$($pair[1])";passed=$true;output=$actual;json=$json})
    }
    foreach($pair in @(@('max-minus-one',[byte[]]$max[0..($max.Length-2)]),@('max-plus-one',[byte[]]($max+[byte[]]@(0))),@('empty',[byte[]]::new(0)),@('short-header',[byte[]]$max[0..14]),@('count-only',[byte[]]$max[0..15]))){
        $path=Join-Path $work "$($pair[0]).input";Write-New $path $pair[1];$absent=Join-Path $work "$($pair[0]).rejected"
        $run=Invoke-Check (Join-Path $sourceRoot 'audit.exe') $path $absent 1
        if(Test-Path -LiteralPath $absent){throw 'Rejected input published output.'}
        $checks.Add([pscustomobject]@{name=$pair[0];passed=$true;reason=$run.stderr})
    }
    $existing=Join-Path $work 'existing.output';Write-New $existing ([byte[]]@(31,41,59));$existingId=Identity $existing
    $run=Invoke-Check (Join-Path $sourceRoot 'audit.exe') $maxPath $existing 1
    if((Identity $existing).sha256 -cne $existingId.sha256 -or $run.stderr -notmatch 'create_new'){throw 'Maximum batch no-clobber failed.'}
    $checks.Add([pscustomobject]@{name='no-clobber';passed=$true;output=$existingId})
}catch{$failure=$_}
finally{
    foreach($id in $ids){if((Get-FileHash -LiteralPath $id.path).Hash -cne $id.sha256){$failure='Current identity changed.'}}
    foreach($held in $locks){$held.Dispose()}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});cases=65536;checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();timing_used=$false;oracle_origin='Repeated rows from retained independent BigInteger proof; not additional distinct arithmetic cases.';completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Maximum batch E2E PASS: $($checks.Count) checks / $($calls.Count) CLI."
