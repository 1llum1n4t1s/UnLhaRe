#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# 実CLIの更新前Q15列を独立decimal疎木/再帰predict/updateへ照合する。
# 先に失敗条件: oracle不一致、既知列不一致、opt2/opt3/反復不一致、
# 空/最大batch、奇数長/上限+1/class/bitの拒否漏れ、既存出力上書き、source変化。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=Join-Path $root 'build/khc-bwt-causal-bayes-float-cts-20260930'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path;if($item -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()}}
if(-not $work.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work;$null=New-Item -ItemType Directory -Path $work
$ids=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[object]]::new();$failure=$null
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try{$started=$p.Start();if(-not $started){throw 'Start failed.'};$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(60000)){throw 'Timeout.'};$r=[pscustomobject]@{program=$Program;argv=$Argv;exit=$p.ExitCode;expected_exit=$Expected;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()};$calls.Add($r);if($r.exit -ne $Expected -or ($Expected -eq 0 -and $r.stderr) -or ($Expected -ne 0 -and $r.stdout)){throw 'Unexpected CLI result.'};$r}
    finally{if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
try{
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'cts_model.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_FLOAT_CTS_CONTRACT_20260930.md'),(Join-Path $build 'audit.exe'),(Join-Path $build 'audit-reference.exe'))){$id=Identity $path;$locks.Add([IO.File]::Open($id.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$ids.Add($id)}
    # 候補のdense iterative treeと共有しない、decimalの疎dictionary/再帰構造。
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
public static class DecimalCtsOracle {
    sealed class Node { public uint Zero, One; public decimal Weight=.5m; }
    sealed class Tree { public Dictionary<int,Node> Nodes=new Dictionary<int,Node>(); public ushort History; public uint Observations; }
    sealed class Prediction { public Node Node; public decimal Kt, Zero, One; public Prediction Child; }
    static Prediction Predict(Tree tree,int index,int depth) {
        Node node;if(!tree.Nodes.TryGetValue(index,out node)){node=new Node();tree.Nodes.Add(index,node);}
        decimal kt=(node.Zero+.5m)/(checked(node.Zero+node.One)+1m);
        var p=new Prediction { Node=node,Kt=kt };
        if(depth==16){p.Zero=kt;p.One=1m-kt;}
        else{p.Child=Predict(tree,checked(index*2+1+((tree.History>>depth)&1)),depth+1);p.Zero=node.Weight*kt+(1m-node.Weight)*p.Child.Zero;p.One=node.Weight*(1m-kt)+(1m-node.Weight)*p.Child.One;}
        if(p.Zero<=0m||p.Zero>=1m||p.One<=0m||p.One>=1m)throw new Exception("Oracle probability out of bounds.");
        return p;
    }
    static void Update(Prediction p,bool bit,decimal alpha) {
        if(p.Child!=null){Update(p.Child,bit,alpha);decimal posterior=p.Node.Weight*(bit?1m-p.Kt:p.Kt)/(bit?p.One:p.Zero);p.Node.Weight=alpha+(1m-2m*alpha)*posterior;if(p.Node.Weight<0m||p.Node.Weight>1m)throw new Exception("Oracle weight out of bounds.");}
        if(bit)p.Node.One=checked(p.Node.One+1);else p.Node.Zero=checked(p.Node.Zero+1);
        uint total=checked(p.Node.Zero+p.Node.One);
    }
    public static byte[] Run(byte[] records) {
        if(records.Length%2!=0)throw new Exception("Odd records.");
        var trees=new Tree[7];for(int c=0;c<7;c++)trees[c]=new Tree();
        var output=new byte[records.Length];
        for(int at=0;at<records.Length;at+=2){int c=records[at];bool bit=records[at+1]!=0;if(c>=7||records[at+1]>1)throw new Exception("Invalid record.");var tree=trees[c];var p=Predict(tree,0,0);decimal rounded=decimal.Floor(p.Zero*32768m+.5m);ushort q=(ushort)Math.Max(1m,Math.Min(32767m,rounded));output[at]=(byte)q;output[at+1]=(byte)(q>>8);uint after=checked(tree.Observations+1);Update(p,bit,1m/(after+1m));tree.Observations=after;tree.History=(ushort)((tree.History<<1)|(bit?1:0));}
        return output;
    }
}
'@
    $fixtures=[ordered]@{empty=[byte[]]::new(0);ones=[byte[]]@(0,1,0,1,0,1)}
    foreach($mode in @('zeros','alternating','periodic','interleaved','random')){
        $data=[byte[]]::new(512);$random=[Random]::new(20260930)
        for($i=0;$i -lt 256;$i++){$data[2*$i]=if($mode -ceq 'interleaved'){[byte]($i%7)}else{[byte]0};$data[2*$i+1]=switch($mode){zeros{[byte]0}alternating{[byte]($i%2)}periodic{[byte]([int](($i%19) -lt 11))}interleaved{[byte]([int](($i%23) -lt 9))}random{[byte]$random.Next(2)}}}
        $fixtures[$mode]=$data
    }
    $maximum=[byte[]]::new(8192);$random=[Random]::new(20260930)
    for($i=0;$i -lt 4096;$i++){$maximum[2*$i]=[byte]$random.Next(7);$maximum[2*$i+1]=[byte]$random.Next(2)}
    $fixtures['maximum']=$maximum
    foreach($name in $fixtures.Keys){
        $input=Join-Path $work "$name.input";Write-New $input $fixtures[$name]
        $expected=[DecimalCtsOracle]::Run($fixtures[$name]);$oracle=Join-Path $work "$name.expected";Write-New $oracle $expected;$oracleId=Identity $oracle
        if($name -ceq 'ones' -and [Convert]::ToHexString($expected) -cne '00400030C721'){throw 'Known 1/2,3/8,19/72 Q15 sequence mismatch.'}
        foreach($program in @(@('audit.exe','opt3'),@('audit-reference.exe','opt2'))){foreach($round in 0..1){
            $output=Join-Path $work "$name-$($program[1])-$round.output";$run=Invoke-Child (Join-Path $build $program[0]) @($input,$output) 0;$json=$run.stdout|ConvertFrom-Json;$actual=Identity $output
            if($json.operation -cne 'cts-f64-audit' -or $json.observations -ne $fixtures[$name].Length/2 -or $actual.bytes -ne $oracleId.bytes -or $actual.sha256 -cne $oracleId.sha256){throw 'CLI predictions differ from independent decimal oracle.'}
            $checks.Add([pscustomobject]@{name="$name-$($program[1])-$round";passed=$true;observations=$json.observations;input=(Identity $input);output=$actual;oracle=$oracleId})
        }}
    }
    foreach($fixture in @(@('odd',[byte[]]@(0)),@('oversize',[byte[]]::new(8193)),@('class',[byte[]]@(7,0)),@('bit',[byte[]]@(0,2)))){
        $input=Join-Path $work "$($fixture[0]).input";Write-New $input $fixture[1];$absent=Join-Path $work "$($fixture[0]).rejected";$run=Invoke-Child (Join-Path $build 'audit.exe') @($input,$absent) 1
        if(Test-Path -LiteralPath $absent){throw 'Invalid input published output.'};$checks.Add([pscustomobject]@{name="reject-$($fixture[0])";passed=$true;reason=$run.stderr})
    }
    $existing=Join-Path $work 'existing.output';Write-New $existing ([byte[]]@(31,41,59));$existingId=Identity $existing
    $run=Invoke-Child (Join-Path $build 'audit.exe') @((Join-Path $work 'ones.input'),$existing) 1
    if((Identity $existing).sha256 -cne $existingId.sha256 -or $run.stderr -notmatch 'create_new'){throw 'Existing output overwritten.'}
    $checks.Add([pscustomobject]@{name='no-clobber';passed=$true;output=$existingId})
    foreach($argv in @([string[]]@(),[string[]]@((Join-Path $work 'ones.input')),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')))){$run=Invoke-Child (Join-Path $build 'audit.exe') $argv 1;if(Test-Path -LiteralPath (Join-Path $work 'missing.output')){throw 'Missing input published output.'};$checks.Add([pscustomobject]@{name='bad-invocation';passed=$true;argv=$argv;reason=$run.stderr})}
}catch{$failure=$_}
finally{
    foreach($id in $ids){if((Get-FileHash -LiteralPath $id.path).Hash -cne $id.sha256){$failure='Source/binary changed.'}}
    foreach($held in $locks){$held.Dispose()}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();timing_used=$false;oracle='Independent decimal sparse recursive CTS, root Q15 only; not exact real arithmetic or raw f64 equivalence.';completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Decimal CTS CLI E2E PASS: $($checks.Count) checks / $($calls.Count) CLI."
