#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# failure-first契約の実CLI。表を参照しない凍結Model/direct式をoracleとする。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=Join-Path $root 'build/khc-bwt-causal-bayes-log-table-20260930'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$failure=$null
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path;if($item -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Track([string]$Path){No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path;$ids.Add($id);return $id}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()}}
function Check([string]$Name,[object]$Evidence){$checks.Add([pscustomobject]@{name=$Name;passed=$true;evidence=$Evidence})}
function Run([string]$Program,[string[]]$Argv,[int]$Expected){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    $row=[ordered]@{program=$Program;argv=$Argv;expected_exit=$Expected;exit=$null;stdout='';stderr='';timeout=$false}
    $calls.Add($row)
    try{$started=$p.Start();if(-not $started){throw 'Start failed.'};$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(60000)){$row.timeout=$true;throw 'Timeout.'};$row.exit=$p.ExitCode;$row.stdout=$out.GetAwaiter().GetResult();$row.stderr=$err.GetAwaiter().GetResult();if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and -not $row.stderr) -or ($Expected -ne 0 -and $row.stdout)){throw 'Unexpected CLI result.'};return [pscustomobject]$row}
    finally{if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
if(-not $work.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work;$null=New-Item -ItemType Directory -Path $work
try{
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'bayes_model.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../causal-bayes-packed/bayes_model.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_LOG_TABLE_CONTRACT_20260930.md'),(Join-Path $build 'audit.exe'),(Join-Path $build 'audit-opt2.exe'),(Join-Path $build 'audit-reference.exe'),'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe')){$null=Track $path}
    # fixture生成のみ。candidateの木/表/対数計算を共有しない。
    Add-Type -TypeDefinition @'
using System;
public static class BayesAuditFixtures {
    static void Put(byte[] b,int i,int c,int bit,int p,int t){int at=i*6;b[at]=(byte)c;b[at+1]=(byte)bit;b[at+2]=(byte)p;b[at+3]=(byte)(p>>8);b[at+4]=(byte)t;b[at+5]=(byte)(t>>8);}
    public static byte[] Known(){var b=new byte[24];Put(b,0,0,0,8192,24576);Put(b,1,1,1,1,32767);Put(b,2,1,0,8192,12288);Put(b,3,0,1,8192,24576);return b;}
    public static byte[] Maximum(){var b=new byte[65536*6];int i=0;for(int q=1;q<32768;q++)for(int bit=0;bit<2;bit++)Put(b,i++,(q+bit)%7,bit,q,32768-q);Put(b,i++,6,0,1,1);Put(b,i++,6,1,32767,32767);if(i!=65536)throw new Exception("Fixture count.");return b;}
    public static byte[] Mixed(){var b=new byte[512*6];var r=new Random(20260930);for(int i=0;i<512;i++)Put(b,i,r.Next(7),r.Next(2),r.Next(1,32768),r.Next(1,32768));return b;}
}
'@
    $fixtures=[ordered]@{empty=[byte[]]@();known=[BayesAuditFixtures]::Known();mixed=[BayesAuditFixtures]::Mixed();maximum=[BayesAuditFixtures]::Maximum()}
    foreach($name in $fixtures.Keys){
        $input=Join-Path $work "$name.input";Write-New $input $fixtures[$name];$inputId=Identity $input;$count=$inputId.bytes/6
        $oraclePath=Join-Path $work "$name-direct-0.output";$oracle=$null
        foreach($program in @(@('audit-reference.exe','direct'),@('audit.exe','table'),@('audit-opt2.exe','table-opt2'))){foreach($round in 0..1){
            $tag=$program[1];$output=Join-Path $work "$name-$tag-$round.output";$run=Run (Join-Path $build $program[0]) @($input,$output) 0;$json=$run.stdout|ConvertFrom-Json;$actual=Identity $output
            $backend=if($tag -ceq 'direct'){'direct'}else{'table'}
            if($json.operation -cne 'bayes-log-audit' -or $json.backend -cne $backend -or $json.observations -ne $count -or $actual.bytes -ne $count*18){throw 'Audit JSON/output count mismatch.'}
            if($null -eq $oracle){$oracle=$actual}
            if($actual.bytes -ne $oracle.bytes -or $actual.sha256 -cne $oracle.sha256){throw 'Loss bits or mixed Q15 differ from frozen direct oracle.'}
            if($name -ceq 'known'){$raw=[IO.File]::ReadAllBytes($output);$expected=@(16384,16384,8192,20480);for($i=0;$i -lt 4;$i++){if([BitConverter]::ToUInt16($raw,18*$i+16) -ne $expected[$i]){throw 'Known causal Bayes Q15 differs.'}}}
            Check "$name-$tag-$round" ([pscustomobject]@{input=$inputId;observations=$count;output=$actual;oracle=$oracle;known_q15=$(if($name -ceq 'known'){@(16384,16384,8192,20480)}else{$null})})
        }}
    }
    $bad=[ordered]@{unaligned=[byte[]]::new(5);oversize_byte=[byte[]]::new(393217);oversize_record=[byte[]]::new(393222);class=[byte[]]@(7,0,1,0,1,0);bit=[byte[]]@(0,2,1,0,1,0);primary_zero=[byte[]]@(0,0,0,0,1,0);primary_limit=[byte[]]@(0,0,0,128,1,0);cts_zero=[byte[]]@(0,0,1,0,0,0);cts_limit=[byte[]]@(0,0,1,0,0,128)}
    foreach($name in $bad.Keys){$input=Join-Path $work "$name.input";Write-New $input $bad[$name];foreach($program in @('audit.exe','audit-reference.exe')){$output=Join-Path $work "$name-$program.rejected";$run=Run (Join-Path $build $program) @($input,$output) 1;if(Test-Path -LiteralPath $output){throw 'Rejected input published output.'};Check "reject-$name-$program" ([pscustomobject]@{input=(Identity $input);output_absent=$true;reason=$run.stderr})}}
    foreach($program in @('audit.exe','audit-reference.exe')){
        $existing=Join-Path $work "$program-existing.output";Write-New $existing ([byte[]]@(31,41,59));$before=Identity $existing;$run=Run (Join-Path $build $program) @((Join-Path $work 'known.input'),$existing) 1;$after=Identity $existing
        if($after.sha256 -cne $before.sha256 -or $after.bytes -ne $before.bytes -or $run.stderr -notmatch 'create_new'){throw 'No-clobber mismatch.'};Check "no-clobber-$program" $before
        foreach($argv in @([string[]]@(),[string[]]@((Join-Path $work 'known.input')),[string[]]@((Join-Path $work 'missing'),(Join-Path $work "$program-missing.output")))){$run=Run (Join-Path $build $program) $argv 1;if(Test-Path -LiteralPath (Join-Path $work "$program-missing.output")){throw 'Missing input output exists.'};Check "argv-$program" ([pscustomobject]@{argv=$argv;reason=$run.stderr})}
        $directoryOutput=Join-Path $work "$program-directory.output";$run=Run (Join-Path $build $program) @($work,$directoryOutput) 1;if(Test-Path -LiteralPath $directoryOutput){throw 'Directory input published output.'};Check "directory-$program" ([pscustomobject]@{output_absent=$true;reason=$run.stderr})
    }
}catch{$failure=$_}
finally{
    foreach($id in $ids){try{$after=Identity $id.path;if($after.sha256 -cne $id.sha256 -or $after.bytes -ne $id.bytes){throw 'Source/binary changed.'}}catch{$failure=$_}}
    foreach($held in $locks){$held.Dispose()}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();timing_used=$false;oracle='Frozen original Bayes Model predict/update plus direct observed.log2 expression; Windows x64/toolchain-specific f64 bits, not an independent transcendental implementation.';maximum_records=65536;all_q15_values_both_bits=32767*2;completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Bayes loss-table CLI E2E PASS: $($checks.Count) checks / $($calls.Count) CLI."
