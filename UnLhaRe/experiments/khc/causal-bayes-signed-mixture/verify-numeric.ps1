#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# 元の非負積和式をPowerShell BigIntegerで計算し、実signed-mixture auditを照合する。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=Join-Path $root 'build/khc-bwt-causal-bayes-signed-mixture-20260930'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$ids=[Collections.Generic.List[object]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$failure=$null
$q=281474976710656UL
$qBig=[Numerics.BigInteger]$q
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash}}
function Track([string]$Path){No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path;$ids.Add($id);return $id}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()}}
function Check([string]$Name,[object]$Evidence){$checks.Add([pscustomobject]@{name=$Name;passed=$true;evidence=$Evidence})}
function Run([string]$Program,[string[]]$Argv,[int]$Expected){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    $row=[ordered]@{program=$Program;argv=$Argv;expected_exit=$Expected;exit=$null;stdout='';stderr='';timeout=$false};$calls.Add($row)
    try{$started=$p.Start();if(-not $started){throw 'Start failed.'};$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(60000)){$row.timeout=$true;throw 'Timeout.'};$row.exit=$p.ExitCode;$row.stdout=$out.GetAwaiter().GetResult();$row.stderr=$err.GetAwaiter().GetResult();if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and ($row.stdout -or -not $row.stderr))){throw 'Unexpected CLI result.'};return [pscustomobject]$row}
    finally{if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
if(-not $work.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work;$null=New-Item -ItemType Directory -Path $work
try{
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'cts_model.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../causal-bayes-exact-div/exact_div.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_SIGNED_MIXTURE_CONTRACT_20260930.md'),(Join-Path $build 'audit.exe'),(Join-Path $build 'audit-reference.exe'),'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe')){$null=Track $path}
    # raw fixture生成だけ。候補の符号付き式・shift・error処理は共有しない。
    Add-Type -TypeDefinition @'
using System;
public static class MixtureAuditFixtures {
    const ulong Q=1UL<<48;
    static void Put(byte[] b,ref int i,ulong w,ulong k,ulong c){int at=i++*24;for(int s=0;s<8;s++){b[at+s]=(byte)(w>>(s*8));b[at+8+s]=(byte)(k>>(s*8));b[at+16+s]=(byte)(c>>(s*8));}}
    public static byte[] Known(){var b=new byte[96];int i=0;Put(b,ref i,1,1,2);Put(b,ref i,1,2,1);Put(b,ref i,Q-1,1,2);Put(b,ref i,Q-1,2,1);return b;}
    public static byte[] Maximum(){var b=new byte[65536*24];int i=0;ulong[] weights={0,1,2,Q/2-1,Q/2,Q/2+1,Q-2,Q-1,Q,Q+1,ulong.MaxValue};ulong[] probs={0,1,2,3,Q/2-1,Q/2,Q/2+1,Q-2,Q-1,Q,Q+1,ulong.MaxValue};foreach(ulong w in weights)foreach(ulong k in probs)foreach(ulong c in probs)Put(b,ref i,w,k,c);for(int e=0;e<64;e++){ulong p=1UL<<e;foreach(ulong w in new[]{p-1,p,p+1}){Put(b,ref i,w,1,Q-1);Put(b,ref i,w,Q-1,1);Put(b,ref i,Q/2,p,Q-1);Put(b,ref i,Q/2,Q-1,p);}}var r=new Random(20260930);var raw=new byte[8];while(i<65536){r.NextBytes(raw);ulong w=BitConverter.ToUInt64(raw);r.NextBytes(raw);ulong k=BitConverter.ToUInt64(raw);r.NextBytes(raw);ulong c=BitConverter.ToUInt64(raw);if(i%4!=0){w&=Q-1;k=1+k%(Q-1);c=1+c%(Q-1);}Put(b,ref i,w,k,c);}return b;}
}
'@
    $fixtures=[ordered]@{empty=[byte[]]@();known=[MixtureAuditFixtures]::Known();maximum=[MixtureAuditFixtures]::Maximum()}
    foreach($name in $fixtures.Keys){
        $data=$fixtures[$name];$count=[int]($data.Length/24);$inputPath=Join-Path $work "$name.input";Write-New $inputPath $data
        $expected=[byte[]]::new($count*16);$success=0;$invalidWeight=0;$invalidProbability=0;$negative=0
        for($i=0;$i -lt $count;$i++){
            $w=[BitConverter]::ToUInt64($data,$i*24);$k=[BitConverter]::ToUInt64($data,$i*24+8);$c=[BitConverter]::ToUInt64($data,$i*24+16);$status=0UL;$value=0UL
            if($w -gt $q){$status=1UL;$invalidWeight++}
            elseif($k -lt 1 -or $k -ge $q -or $c -lt 1 -or $c -ge $q){$status=2UL;$invalidProbability++}
            else{$wb=[Numerics.BigInteger]$w;$kb=[Numerics.BigInteger]$k;$cb=[Numerics.BigInteger]$c;$value=[uint64](($wb*$kb+($qBig-$wb)*$cb)/$qBig);$success++;if($k -lt $c){$negative++};if($value -lt 1 -or $value -ge $q){throw 'Positive BigInteger oracle probability outside bounds.'}}
            [BitConverter]::GetBytes($status).CopyTo($expected,$i*16);[BitConverter]::GetBytes($value).CopyTo($expected,$i*16+8)
        }
        if($name -ceq 'known'){for($i=0;$i -lt 4;$i++){if([BitConverter]::ToUInt64($expected,$i*16) -ne 0 -or [BitConverter]::ToUInt64($expected,$i*16+8) -ne 1){throw 'Negative fractional known oracle mismatch.'}}}
        $oraclePath=Join-Path $work "$name.expected";Write-New $oraclePath $expected;$oracle=Identity $oraclePath
        foreach($program in @(@('audit.exe','opt3'),@('audit-reference.exe','opt2'))){foreach($round in 0..1){
            $output=Join-Path $work "$name-$($program[1])-$round.output";$run=Run (Join-Path $build $program[0]) @($inputPath,$output) 0;$json=$run.stdout|ConvertFrom-Json;$actual=Identity $output
            if($json.operation -cne 'cts-mixture-audit' -or $json.cases -ne $count -or $actual.bytes -ne $oracle.bytes -or $actual.sha256 -cne $oracle.sha256){throw 'Signed mixture differs from positive BigInteger oracle.'}
            Check "$name-$($program[1])-$round" ([pscustomobject]@{cases=$count;success=$success;invalid_weight=$invalidWeight;invalid_probability=$invalidProbability;negative_delta_success=$negative;input=(Identity $inputPath);oracle=$oracle;output=$actual})
        }}
    }
    foreach($bad in @(@('unaligned',[byte[]]::new(23)),@('oversize-byte',[byte[]]::new(1572865)),@('oversize-record',[byte[]]::new(1572888)))){
        $inputPath=Join-Path $work "$($bad[0]).input";Write-New $inputPath $bad[1];$output=Join-Path $work "$($bad[0]).rejected";$run=Run (Join-Path $build 'audit.exe') @($inputPath,$output) 1
        if(Test-Path -LiteralPath $output){throw 'Invalid syntax published output.'};Check "reject-$($bad[0])" ([pscustomobject]@{input=(Identity $inputPath);output_absent=$true;reason=$run.stderr})
    }
    $existing=Join-Path $work 'existing.output';Write-New $existing ([byte[]]@(31,41,59));$before=Identity $existing;$run=Run (Join-Path $build 'audit.exe') @((Join-Path $work 'known.input'),$existing) 1;$after=Identity $existing
    if($after.sha256 -cne $before.sha256 -or $after.bytes -ne $before.bytes -or $run.stderr -notmatch 'create_new'){throw 'No-clobber mismatch.'};Check 'no-clobber' $before
    foreach($argv in @([string[]]@(),[string[]]@((Join-Path $work 'known.input')),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')))){$run=Run (Join-Path $build 'audit.exe') $argv 1;if(Test-Path -LiteralPath (Join-Path $work 'missing.output')){throw 'Missing input published output.'};Check 'bad-invocation' ([pscustomobject]@{argv=$argv;reason=$run.stderr})}
    $directoryOutput=Join-Path $work 'directory.output';$run=Run (Join-Path $build 'audit.exe') @($work,$directoryOutput) 1;if(Test-Path -LiteralPath $directoryOutput){throw 'Directory input published output.'};Check 'directory' ([pscustomobject]@{output_absent=$true;reason=$run.stderr})
}catch{$failure=$_}
finally{
    foreach($id in $ids){try{$after=Identity $id.path;if($after.sha256 -cne $id.sha256 -or $after.bytes -ne $id.bytes){throw 'Source/binary changed.'}}catch{$failure=$_}}
    foreach($held in $locks){$held.Dispose()}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();timing_used=$false;oracle='PowerShell BigInteger positive weighted sum divided by Q; no candidate signed multiplication/shift is reused.';maximum_cases=65536;completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Signed mixture numeric CLI E2E PASS: $($checks.Count) checks / $($calls.Count) CLI."
