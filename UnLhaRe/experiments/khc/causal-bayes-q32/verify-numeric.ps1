#requires -Version 7.2
param([Parameter(Mandatory)][string]$WorkDirectory)
# 先に失敗条件: 全Q15列/既知列/opt3・opt2・反復の不一致、無効入力の公開、
# argc/regular/奇数長/上限+1/class/bitの拒否漏れ、上書き、source/input/proof変化。
# 独立BigInteger疎木・再帰oracleの実CLI E2E。速度測定/旧f64との同値検証ではない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=Join-Path $root 'build/khc-bwt-causal-bayes-q32-20260930'
$work=[IO.Path]::GetFullPath($WorkDirectory)
$prefix=[IO.Path]::GetFullPath((Join-Path $root 'build'))+[IO.Path]::DirectorySeparatorChar
$ids=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[string]]::new();$failure=$null
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required.'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Lock-Identity([string]$Path,[string]$Role){No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path;$ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try{$started=$p.Start();if(-not $started){throw 'Start failed.'};$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(120000)){throw 'Timeout.'};$r=[pscustomobject]@{program=$Program;argv=$Argv;exit=$p.ExitCode;expected_exit=$Expected;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()};$calls.Add($r);if($r.exit -ne $Expected -or ($Expected -eq 0 -and $r.stderr) -or ($Expected -ne 0 -and $r.stdout)){throw 'Unexpected CLI result.'};$r}
    finally{if($started -and -not $p.HasExited){$p.Kill();$p.WaitForExit()};$p.Dispose()}
}
if(-not $work.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work
# Directory.CreateDirectoryは既存rootを受け入れるため、CreateNew sentinelで所有も固定する。
$null=New-Item -ItemType Directory -Path $work -ErrorAction Stop
Write-New (Join-Path $work 'ownership.json') ([Text.UTF8Encoding]::new($false).GetBytes('{"backend":"causal-bayes-q32-numeric","retain":"input,oracle,source-identities,binary-identities,outputs,report"}'))
try{
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'codec.rs'),(Join-Path $PSScriptRoot 'cts_model.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_Q32_CONTRACT_20260930.md'))){$null=Lock-Identity $path 'scope-owned-source-proof'}
    foreach($name in @('audit.exe','audit-opt2.exe')){$null=Lock-Identity (Join-Path $build $name) 'candidate-audit-binary'}
    # dense配列/反復pathを使わず、状態と予測snapshotを別構造に保つ。
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Numerics;
public static class Q32CtsOracle {
    static readonly BigInteger Q=BigInteger.One<<32;
    static readonly BigInteger Cap=new BigInteger(562036803);
    sealed class Node { public BigInteger Zero, One; public BigInteger Weight=Q/2; }
    sealed class Tree { public Dictionary<int,Node> Nodes=new Dictionary<int,Node>(); public ushort History; public BigInteger Observations; }
    sealed class Prediction { public Node Node; public BigInteger Kt, Zero, Weight; public Prediction Child; }
    static void Probability(BigInteger value) { if(value<=0 || value>=Q)throw new Exception("Oracle probability out of bounds."); }
    static Prediction Predict(Tree tree,int index,int depth) {
        Node node;if(!tree.Nodes.TryGetValue(index,out node)){node=new Node();tree.Nodes.Add(index,node);}
        BigInteger total=node.Zero+node.One;if(total>Cap)throw new Exception("Oracle count cap.");
        BigInteger kt=(Q/2)*(2*node.Zero+1)/(total+1);
        var p=new Prediction { Node=node,Kt=kt,Weight=node.Weight };
        if(depth==16)p.Zero=kt;
        else { p.Child=Predict(tree,checked(index*2+1+((tree.History>>depth)&1)),depth+1);p.Zero=(p.Weight*kt+(Q-p.Weight)*p.Child.Zero)/Q; }
        Probability(kt);Probability(p.Zero);return p;
    }
    static void Update(Prediction p,bool bit,BigInteger alpha) {
        if(p.Child!=null) {
            Update(p.Child,bit,alpha);
            // 観測bit1はKTとchildZero各々の補数。Q-floor(rootZero)は使用しない。
            BigInteger pk=bit?Q-p.Kt:p.Kt;
            BigInteger child=bit?Q-p.Child.Zero:p.Child.Zero;
            BigInteger sum=p.Weight*pk+(Q-p.Weight)*child;
            BigInteger denominator=(sum+Q-1)/Q;
            if(denominator<=0)throw new Exception("Oracle zero denominator.");
            BigInteger posterior=p.Weight*pk/denominator;
            if(posterior<0 || posterior>Q)throw new Exception("Oracle posterior out of bounds.");
            BigInteger retained=Q-2*alpha;
            BigInteger next=alpha+retained*posterior/Q;
            if(alpha<7 || retained<0 || next<=0 || next>=Q)throw new Exception("Oracle weight out of bounds.");
            p.Node.Weight=next;
        }
        if(bit)p.Node.One+=BigInteger.One;else p.Node.Zero+=BigInteger.One;
        if(p.Node.Zero+p.Node.One>Cap)throw new Exception("Oracle node count cap.");
    }
    public static byte[] Run(byte[] records) {
        if(records.Length%2!=0 || records.Length>8192)throw new Exception("Invalid batch length.");
        // 全recordを変更前に検証する。
        for(int i=0;i<records.Length;i+=2)if(records[i]>=7 || records[i+1]>1)throw new Exception("Invalid record.");
        var trees=new Tree[7];for(int c=0;c<7;c++)trees[c]=new Tree();
        var output=new byte[records.Length];
        for(int at=0;at<records.Length;at+=2) {
            var tree=trees[records[at]];bool bit=records[at+1]!=0;
            BigInteger after=tree.Observations+1;if(after>Cap)throw new Exception("Oracle observation cap before mutation.");
            var p=Predict(tree,0,0);BigInteger rounded=(p.Zero+(BigInteger.One<<16))>>17;
            ushort q=(ushort)BigInteger.Max(1,BigInteger.Min(32767,rounded));
            output[at]=(byte)q;output[at+1]=(byte)(q>>8);
            BigInteger alpha=Q/(after+1);Update(p,bit,alpha);
            tree.Observations=after;tree.History=(ushort)((tree.History<<1)|(bit?1:0));
        }
        return output;
    }
}
'@
    $fixtures=[ordered]@{empty=[byte[]]::new(0);known=[byte[]]@(0,1,0,1,0,1)}
    foreach($mode in @('zeros','ones','alternating','interleaved','random')){
        $data=[byte[]]::new(512);$random=[Random]::new(20260930)
        for($i=0;$i -lt 256;$i++){$data[2*$i]=if($mode -ceq 'interleaved'){[byte]($i%7)}else{[byte]0};$data[2*$i+1]=switch($mode){zeros{[byte]0}ones{[byte]1}alternating{[byte]($i%2)}interleaved{[byte]([int](($i%23) -lt 9))}random{[byte]$random.Next(2)}}}
        $fixtures[$mode]=$data
    }
    $maximum=[byte[]]::new(8192);$random=[Random]::new(20260930)
    for($i=0;$i -lt 4096;$i++){$maximum[2*$i]=[byte]$random.Next(7);$maximum[2*$i+1]=[byte]$random.Next(2)}
    $fixtures['maximum']=$maximum
    foreach($name in $fixtures.Keys){
        $input=Join-Path $work "$name.input";Write-New $input $fixtures[$name];$inputId=Lock-Identity $input 'retained-input'
        $expected=[Q32CtsOracle]::Run($fixtures[$name]);$oracle=Join-Path $work "$name.expected";Write-New $oracle $expected;$oracleId=Lock-Identity $oracle 'raw-bigint-oracle'
        if($name -ceq 'known' -and [Convert]::ToHexString($expected) -cne '00400030C721'){throw 'Known Q32 sequence 16384,12288,8647 mismatch.'}
        foreach($program in @(@('audit.exe','opt3'),@('audit-opt2.exe','opt2'))){foreach($round in 0..1){
            $output=Join-Path $work "$name-$($program[1])-$round.output";$run=Invoke-Child (Join-Path $build $program[0]) @($input,$output) 0;$owned.Add($output);$json=$run.stdout|ConvertFrom-Json;$actual=Lock-Identity $output 'retained-actual-q15'
            if($json.operation -cne 'cts-q32-audit' -or $json.observations -ne $fixtures[$name].Length/2 -or $actual.bytes -ne $oracleId.bytes -or $actual.sha256 -cne $oracleId.sha256 -or -not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($output),$expected)){throw 'CLI predictions differ from independent BigInteger oracle.'}
            $checks.Add([pscustomobject]@{name="$name-$($program[1])-$round";passed=$true;observations=$json.observations;input=$inputId;output=$actual;oracle=$oracleId})
        }}
    }
    foreach($fixture in @(@('odd',[byte[]]@(0)),@('oversize',[byte[]]::new(8193)),@('class',[byte[]]@(7,0)),@('bit',[byte[]]@(0,2)))){
        $input=Join-Path $work "$($fixture[0]).input";Write-New $input $fixture[1];$null=Lock-Identity $input 'invalid-input';$absent=Join-Path $work "$($fixture[0]).rejected";$run=Invoke-Child (Join-Path $build 'audit.exe') @($input,$absent) 1
        if(Test-Path -LiteralPath $absent){throw 'Invalid input published output.'};$checks.Add([pscustomobject]@{name="reject-$($fixture[0])";passed=$true;reason=$run.stderr})
    }
    $existing=Join-Path $work 'existing.output';Write-New $existing ([byte[]]@(31,41,59));$existingId=Identity $existing
    $run=Invoke-Child (Join-Path $build 'audit.exe') @((Join-Path $work 'known.input'),$existing) 1
    if((Identity $existing).sha256 -cne $existingId.sha256 -or $run.stderr -notmatch 'create_new'){throw 'Existing output overwritten.'}
    $null=Lock-Identity $existing 'no-clobber-after';$checks.Add([pscustomobject]@{name='no-clobber';passed=$true;output=$existingId})
    foreach($argv in @([string[]]@(),[string[]]@((Join-Path $work 'known.input')),[string[]]@((Join-Path $work 'known.input'),(Join-Path $work 'extra.output'),'extra'),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')),[string[]]@($work,(Join-Path $work 'directory.output')),[string[]]@((Join-Path $work 'known.input'),(Join-Path $work 'absent-parent/output')))){
        $run=Invoke-Child (Join-Path $build 'audit.exe') $argv 1
        foreach($absent in @('extra.output','missing.output','directory.output','absent-parent/output')){if(Test-Path -LiteralPath (Join-Path $work $absent)){throw 'Invalid invocation published output.'}}
        $checks.Add([pscustomobject]@{name='bad-invocation';passed=$true;argv=$argv;reason=$run.stderr})
    }
}catch{$failure=$_}
finally{
    try{foreach($id in $ids){$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){$failure='Source/input/oracle/proof/binary changed.'}}}catch{$failure=$_}
    finally{foreach($held in $locks){$held.Dispose()}}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();owned_paths=$owned.ToArray();timing_used=$false;oracle='Independent BigInteger Q32 sparse recursive CTS; floor prediction, observed-side ceil posterior, half-up Q15; no f64/Q48 equivalence claim.';limits=@('OOM injection untested','I/O fault injection untested','Other OS untested','Observation cap exercised only through bounded batches, not 562036803 observations');completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"BigInteger Q32 CTS CLI E2E PASS: $($checks.Count) checks / $($calls.Count) CLI."
