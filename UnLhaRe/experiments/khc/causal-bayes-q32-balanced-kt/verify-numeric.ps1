#requires -Version 7.2
# 失敗計画の正本: ../Q32_BALANCED_KT_CONTRACT_20261001.md（実装前に作成）。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-q32-balanced-kt-numeric-20261001-junction-validated'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$contractSha='11EC999DC04D3E2A828DA1A5B4611A07934C309F4BE520319CEE2B418A3A35EA'
$ids=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[object]]::new();$owned=[Collections.Generic.List[string]]::new()
$ktEvidence=$null;$failure=$null;$counts=$null;$datasetEvidence=$null;$historyEvidence=$null;$layoutEvidence=$null
function No-Reparse([string]$Path){$p=[IO.Path]::GetFullPath($Path);while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected'};$p=[IO.Path]::GetDirectoryName($p)}}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Lock-Identity([string]$Path,[string]$Role){No-Reparse $Path;$locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read));$id=Identity $Path;$ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected){
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try{$started=$p.Start();if(-not $started){throw 'Start failed'};$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();if(-not $p.WaitForExit(120000)){throw '120s timeout'};$r=[pscustomobject]@{program=$Program;argv=$Argv;exit=$p.ExitCode;expected_exit=$Expected;stdout=$out.GetAwaiter().GetResult();stderr=$err.GetAwaiter().GetResult()};$calls.Add($r);if($r.exit -ne $Expected -or ($Expected -eq 0 -and $r.stderr) -or ($Expected -ne 0 -and $r.stdout)){throw 'Unexpected child result'};$r}
    finally{if($started -and -not $p.HasExited){$p.Kill($true);$null=$p.WaitForExit(10000)};$p.Dispose()}
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'Fresh build root required'}
$null=New-Item -ItemType Directory -Path $work -ErrorAction Stop
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"q32-balanced-kt-numeric","retain":"reproducible numeric CLI E2E artifacts"}'))
try {
    foreach($name in @('cts_model.rs','audit_cli.rs','verify-numeric.ps1')){$null=Lock-Identity (Join-Path $PSScriptRoot $name) 'source'}
    $fixed=@(
        @{path=(Join-Path $PSScriptRoot '../Q32_BALANCED_KT_CONTRACT_20261001.md');role='contract';sha=$contractSha},
        @{path=(Join-Path $PSScriptRoot '../Q32_MIXTURE_REUSE_FEASIBILITY_20261001.md');role='feasibility';sha='4470BCF1A69EF403C6DCBB5BFBFF2538A38EAE5CC6821C4379D914F6305B9603'},
        @{path=(Join-Path $PSScriptRoot '../causal-bayes-q32-split-lut/cts_model.rs');role='old-cts-source';sha='87AD15A78B390FA3F34A2ED6C36DD19CEAC05E4B3D29979207BA9A11B52393EA'},
        @{path=(Join-Path $PSScriptRoot '../split-estimate-quotient/exact_div.rs');role='exact-helper';sha='D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'},
        @{path=(Join-Path $root 'build/khc-split-estimate-quotient-20261001/report.json');role='old-helper-proof';sha='03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29'},
        @{path=(Join-Path $PSScriptRoot '../causal-bayes-q32/verify-numeric.ps1');role='old-sparse-oracle-source';sha='B02BC0CA6DEBF59DE92C7A47F4F822E0639B0C3CA78A65A02AEEE3989450AA08'},
        @{path=$compiler;role='compiler';sha=$compilerSha}
    )
    $fixed += @(
        @{path=(Join-Path $PSScriptRoot '../causal-bayes-q32-mixture-reuse/cts_model.rs');role='frozen-parent-cts';sha='BBD229E9B8E787618472E66421EF5E38E0BCBBB63B761575032892C3EDBE98E2'},
        @{path=(Join-Path $PSScriptRoot '../causal-bayes-q32-mixture-reuse/verify-numeric.ps1');role='inherited-oracle-source';sha='F106178317D9DAD39B714AA32F870B4FFB7BBF6C5B44453EA219183DA3C7D87B'},
        @{path=(Join-Path $root 'build/khc-q32-mixture-reuse-numeric-20261001-model-layout/report.json');role='current-parent-proof';sha='BFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72'}
    )
    foreach($pin in $fixed){$id=Lock-Identity $pin.path $pin.role;if($id.sha256 -cne $pin.sha){throw 'Fixed artifact pin mismatch'}}
    $null=Invoke-Child $compiler @('--version','--verbose') 0
    foreach($opt in @('3','2')){
        $exe=Join-Path $work "audit-opt$opt.exe"
        $null=Invoke-Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'-o',$exe) 0
        $owned.Add($exe);$null=Lock-Identity $exe "opt$opt-executable"
        $modelExe=Join-Path $work "model-opt$opt.exe"
        $null=Invoke-Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','--cfg','khc_mixture_reuse_audit','-C','panic=abort','-C',"opt-level=$opt",'-o',$modelExe) 0
        $owned.Add($modelExe);$null=Lock-Identity $modelExe "model-opt$opt-executable"
    }
    foreach($opt in @('3','2')){
        $exe=Join-Path $work "kt-opt$opt.exe"
        $null=Invoke-Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','--cfg','khc_balanced_kt_audit','-C','panic=abort','-C',"opt-level=$opt",'-o',$exe) 0
        $owned.Add($exe);$null=Lock-Identity $exe "kt-opt$opt-executable"
    }
    # fixtureだけを生成し、候補の分母・posterior・weight計算は転用しない。
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
public static class MixtureReuseFixtures {
    const ulong Q=1UL<<32;
    public static byte[] Record(params ulong[] fields) {
        using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){foreach(ulong v in fields)bw.Write(v);return ms.ToArray();}
    }
    public static byte[] Dataset() {
        var rows=new List<ulong[]>();
        void Put(ulong snap,ulong live,ulong k,ulong c,ulong bit,ulong after){rows.Add(new[]{snap,live,k,c,bit,after,ulong.MaxValue});}
        // stale反例を冒頭へ固定。same/fallbackそれぞれの両bit。
        foreach(ulong live in new[]{Q/2,Q/4})foreach(ulong bit in new ulong[]{0,1})Put(Q/2,live,3,7,bit,1);
        ulong[] weights={0,1,Q/2,Q-1,Q};
        ulong[] probs={1,2,3,7,Q/2,Q-2,Q-1};
        foreach(ulong snap in weights)foreach(ulong live in weights)
            foreach(ulong k in probs)foreach(ulong c in probs)
                foreach(ulong bit in new ulong[]{0,1})foreach(ulong after in new ulong[]{1,2,562036803})Put(snap,live,k,c,bit,after);
        for(int e=1;e<32;e++){
            ulong p=1UL<<e;
            foreach(ulong w in new[]{p-1,p,p+1})foreach(ulong bit in new ulong[]{0,1}){
                Put(w,w,1,Q-1,bit,562036802);Put(w,Q-w,Q-1,1,bit,562036803);
                Put(Q/2,Q/4,p,Q-p,bit,2);
            }
        }
        var rng=new Random(20261001);var raw=new byte[8];
        ulong Next(){rng.NextBytes(raw);return BitConverter.ToUInt64(raw,0);}
        while(rows.Count<65536){
            ulong snap=Next()%(Q+1);ulong live=rows.Count%2==0?snap:Next()%(Q+1);
            ulong k=1+Next()%(Q-1);ulong c=1+Next()%(Q-1);
            Put(snap,live,k,c,Next()%2,1+Next()%562036803);
        }
        using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){foreach(var row in rows)foreach(ulong v in row)bw.Write(v);return ms.ToArray();}
    }
}
'@
    $inputBytes=[MixtureReuseFixtures]::Dataset();$input=Join-Path $work 'finite.input'
    Write-New $input $inputBytes;$null=Lock-Identity $input 'raw-input'
    $records=$inputBytes.Length/56;$expected=[byte[]]::new($records*40)
    $q=[Numerics.BigInteger]4294967296;$counts=[long[]]::new(7)
    for($row=0;$row -lt $records;$row++){
        $at=$row*56
        $snapshot=[Numerics.BigInteger][BitConverter]::ToUInt64($inputBytes,$at)
        $live=[Numerics.BigInteger][BitConverter]::ToUInt64($inputBytes,$at+8)
        $kt=[Numerics.BigInteger][BitConverter]::ToUInt64($inputBytes,$at+16)
        $child=[Numerics.BigInteger][BitConverter]::ToUInt64($inputBytes,$at+24)
        $bit=[BitConverter]::ToUInt64($inputBytes,$at+32)
        $after=[Numerics.BigInteger][BitConverter]::ToUInt64($inputBytes,$at+40)
        $s0=$snapshot*$kt+($q-$snapshot)*$child
        $zero=[Numerics.BigInteger]::Divide($s0,$q)
        $remainder=[uint64]([Numerics.BigInteger]::Remainder($s0,$q) -ne 0)
        # oracleは常にlive weightの正の整数和から旧ceilingを独立計算する。
        $pk=if($bit -eq 0){$kt}else{$q-$kt}
        $pc=if($bit -eq 0){$child}else{$q-$child}
        $sbit=$live*$pk+($q-$live)*$pc
        $denominator=[Numerics.BigInteger]::Divide($sbit+$q-1,$q)
        $posterior=[Numerics.BigInteger]::Divide($live*$pk,$denominator)
        $alpha=[Numerics.BigInteger]::Divide($q,$after+1)
        $next=$alpha+[Numerics.BigInteger]::Divide(($q-2*$alpha)*$posterior,$q)
        if($denominator -lt 1 -or $denominator -ge $q -or $posterior -lt 0 -or $posterior -gt $q -or $next -lt 0 -or $next -gt $q){throw 'Independent oracle bounds failed'}
        $values=@([uint64]$zero,$remainder,[uint64]$denominator,[uint64]$posterior,[uint64]$next)
        for($i=0;$i -lt 5;$i++){[BitConverter]::GetBytes([uint64]$values[$i]).CopyTo($expected,$row*40+$i*8)}
        $counts[0]++;if($snapshot -eq $live){$counts[1]++}else{$counts[2]++}
        if($remainder -eq 0){$counts[3]++}else{$counts[4]++}
        if($bit -eq 0){$counts[5]++}else{$counts[6]++}
    }
    if([BitConverter]::ToUInt64($expected,2*40+16) -ne 6 -or [BitConverter]::ToUInt64($expected,16) -ne 5){throw 'Stale denominator counterexample absent'}
    if(@($counts|Where-Object {$_ -eq 0}).Count -ne 0){throw 'Required numeric category absent'}
    $datasetEvidence=[pscustomobject]@{records=$records;input_fields=@('snapshot','live','kt-zero','child-zero','bit','after-count','ceiling-override-MAX-auto');output_fields=@('zero-floor','remainder-present','raw-denominator','posterior-floor','next-weight');stale_counterexample='snapshot Q/2 live Q/4 k3 child7: cached5 versus live6';seed=20261001}
    $oracle=Join-Path $work 'bigint.expected';Write-New $oracle $expected;$null=Lock-Identity $oracle 'raw-oracle'
    $baseline=$null
    foreach($opt in @('3','2')){foreach($round in 0..1){
        $output=Join-Path $work "finite-opt$opt-$round.output"
        $run=Invoke-Child (Join-Path $work "audit-opt$opt.exe") @($input,$output) 0
        $owned.Add($output);$id=Lock-Identity $output 'raw-output';$json=$run.stdout|ConvertFrom-Json
        $actual=[IO.File]::ReadAllBytes($output)
        if($json.operation -cne 'q32-mixture-reuse-audit' -or $json.records -ne $records -or -not [Linq.Enumerable]::SequenceEqual[byte]($expected,$actual)){throw 'Full raw BigInteger oracle mismatch'}
        if($null -eq $baseline){$baseline=$actual}else{if(-not [Linq.Enumerable]::SequenceEqual[byte]($baseline,$actual)){throw 'Full opt/repeat byte mismatch'}}
        $checks.Add([pscustomobject]@{name="oracle-opt$opt-$round";passed=$true;records=$records;output=$id})
    }}
    $q64=4294967296UL;$max=[ulong]::MaxValue
    $valid=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,7,0,1,$max)
    $badRecords=[ordered]@{
        'snapshot-weight'=[MixtureReuseFixtures]::Record($q64+1,$q64/2,3,7,0,1,$max)
        'live-weight'=[MixtureReuseFixtures]::Record($q64/2,$q64+1,3,7,0,1,$max)
        'kt-zero'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,0,7,0,1,$max)
        'kt-Q'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,$q64,7,1,1,$max)
        'child-zero'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,0,0,1,$max)
        'child-Q'=[MixtureReuseFixtures]::Record($q64/2,$q64/4,3,$q64,1,1,$max)
        'denominator-zero'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,7,0,1,0)
        'posterior-bound'=[MixtureReuseFixtures]::Record($q64,$q64,$q64-1,7,0,1,1)
        'bad-bit'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,7,2,1,$max)
        'zero-after'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,7,0,0,$max)
        'cap-after'=[MixtureReuseFixtures]::Record($q64/2,$q64/2,3,7,0,562036804,$max)
    }
    $fixtures=[ordered]@{odd=[byte[]]@(1);cap=[byte[]]::new(65537*56);capbyte=[byte[]]::new(65536*56+1)}
    foreach($name in $badRecords.Keys){$fixtures[$name]=[byte[]]($valid+$badRecords[$name])}
    foreach($name in $fixtures.Keys){
        $path=Join-Path $work "$name.input";Write-New $path $fixtures[$name];$null=Lock-Identity $path 'invalid-raw-input'
        foreach($opt in @('3','2')){
            $absent=Join-Path $work "$name-opt$opt.rejected"
            $run=Invoke-Child (Join-Path $work "audit-opt$opt.exe") @($path,$absent) 1
            if(Test-Path -LiteralPath $absent){throw 'Malformed or invalid input published output'}
            $checks.Add([pscustomobject]@{name="reject-$name-opt$opt";passed=$true;reason=$run.stderr})
        }
    }
    $empty=Join-Path $work 'empty.input';Write-New $empty ([byte[]]::new(0));$null=Lock-Identity $empty 'empty-raw-input'
    foreach($opt in @('3','2')){
        $exe=Join-Path $work "audit-opt$opt.exe";$out=Join-Path $work "empty-opt$opt.output";$null=Invoke-Child $exe @($empty,$out) 0;$owned.Add($out);$emptyId=Lock-Identity $out 'empty-output';if($emptyId.bytes -ne 0){throw 'Empty output'}
        $checks.Add([pscustomobject]@{name="empty-opt$opt";passed=$true})
        $existing=Join-Path $work "existing-opt$opt.output";Write-New $existing ([byte[]]@(31,41,59));$before=Identity $existing
        $run=Invoke-Child $exe @($input,$existing) 1;if((Identity $existing).sha256 -cne $before.sha256 -or $run.stderr -notmatch 'create_new'){throw 'No-clobber failed'};$null=Lock-Identity $existing 'no-clobber-output';$checks.Add([pscustomobject]@{name="no-clobber-opt$opt";passed=$true})
        foreach($argv in @([string[]]@(),[string[]]@($input),[string[]]@($input,(Join-Path $work 'extra.output'),'extra'),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')),[string[]]@($work,(Join-Path $work 'directory.output')),[string[]]@($input,(Join-Path $work 'absent-parent/output')))){
            $run=Invoke-Child $exe $argv 1;foreach($absent in @('extra.output','missing.output','directory.output','absent-parent/output')){if(Test-Path -LiteralPath (Join-Path $work $absent)){throw 'Bad invocation publication'}}
            $checks.Add([pscustomobject]@{name="invocation-opt$opt";passed=$true;argv=$argv;reason=$run.stderr})
        }
    }
    # 旧Q32の独立疎木・再帰BigInteger oracleを再利用。rawを各段Q32と更新後stateへ拡張。
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Numerics;
public static class Q32MixtureReuseModelOracle {
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
    static void Write(BinaryWriter output,Prediction p) {
        output.Write((ulong)p.Kt);output.Write((ulong)p.Zero);
        output.Write((ulong)p.Node.Zero);output.Write((ulong)p.Node.One);output.Write((ulong)p.Node.Weight);
        if(p.Child!=null)Write(output,p.Child);
    }
    public static byte[] Run(byte[] records) {
        if(records.Length%2!=0 || records.Length>8192)throw new Exception("Invalid batch length.");
        for(int i=0;i<records.Length;i+=2)if(records[i]>=7 || records[i+1]>1)throw new Exception("Invalid record.");
        var trees=new Tree[7];for(int c=0;c<7;c++)trees[c]=new Tree();
        using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){
            for(int at=0;at<records.Length;at+=2) {
                var tree=trees[records[at]];bool bit=records[at+1]!=0;
                BigInteger after=tree.Observations+1;if(after>Cap)throw new Exception("Oracle observation cap before mutation.");
                var p=Predict(tree,0,0);BigInteger alpha=Q/(after+1);
                Update(p,bit,alpha);Write(bw,p);
                tree.Observations=after;tree.History=(ushort)((tree.History<<1)|(bit?1:0));
            }
            return ms.ToArray();
        }
    }
}
'@
    $histories=[ordered]@{empty=[byte[]]::new(0);known=[byte[]]@(0,1,0,1,0,1)}
    foreach($mode in @('zeros','ones','alternating','biased')){
        $data=[byte[]]::new(1792*2)
        for($i=0;$i -lt 1792;$i++){
            $class=$i%7;$step=[int][Math]::Floor($i/7)
            $data[2*$i]=[byte]$class
            $data[2*$i+1]=switch($mode){zeros{[byte]0}ones{[byte]1}alternating{[byte]($step%2)}biased{[byte]([int](($step%23) -lt 3))}}
        }
        $histories[$mode]=$data
    }
    $data=[byte[]]::new(4096*2);$random=[Random]::new(20261001)
    for($i=0;$i -lt 4096;$i++){$data[2*$i]=[byte]$random.Next(7);$data[2*$i+1]=[byte]$random.Next(2)}
    $histories['maximum']=$data
    $historyRecords=0
    foreach($name in $histories.Keys){
        $data=$histories[$name];$historyRecords+=$data.Length/2
        $modelInput=Join-Path $work "model-$name.input";Write-New $modelInput $data;$inputId=Lock-Identity $modelInput 'model-raw-input'
        $modelExpected=[Q32MixtureReuseModelOracle]::Run($data)
        $modelOracle=Join-Path $work "model-$name.expected";Write-New $modelOracle $modelExpected;$oracleId=Lock-Identity $modelOracle 'model-raw-oracle'
        $first=$null
        foreach($opt in @('3','2')){foreach($round in 0..1){
            $output=Join-Path $work "model-$name-opt$opt-$round.output"
            $run=Invoke-Child (Join-Path $work "model-opt$opt.exe") @($modelInput,$output) 0
            $owned.Add($output);$id=Lock-Identity $output 'model-raw-output';$json=$run.stdout|ConvertFrom-Json
            if($null -eq $layoutEvidence){$layoutEvidence=[pscustomobject]@{prediction_bytes=$json.prediction_bytes;node_bytes=$json.node_bytes}}
            elseif($layoutEvidence.prediction_bytes -ne $json.prediction_bytes -or $layoutEvidence.node_bytes -ne $json.node_bytes){throw 'Model layout opt/repeat mismatch'}
            $actual=[IO.File]::ReadAllBytes($output)
            if($json.operation -cne 'q32-mixture-reuse-model-audit' -or $json.records -ne $data.Length/2 -or $actual.Length -ne $data.Length/2*680 -or -not [Linq.Enumerable]::SequenceEqual[byte]($modelExpected,$actual)){throw 'Model Q32 prediction/update state differs from sparse BigInteger oracle'}
            if($null -eq $first){$first=$actual}else{if(-not [Linq.Enumerable]::SequenceEqual[byte]($first,$actual)){throw 'Model opt/repeat full byte mismatch'}}
            $checks.Add([pscustomobject]@{name="model-$name-opt$opt-$round";passed=$true;records=$json.records;input=$inputId;oracle=$oracleId;output=$id})
        }}
    }
    $historyEvidence=[pscustomobject]@{records=$historyRecords;histories=$histories.Count;classes=7;maximum_batch=4096;raw_bytes_per_record=680;levels=17;level_fields=@('KT-Q32','zero-Q32','updated-zero-count','updated-one-count','updated-weight');layout=$layoutEvidence;dense_node_bytes=7*131071*$layoutEvidence.node_bytes;seed=20261001;fixtures=@($histories.Keys);audit_cfg='khc_mixture_reuse_audit'}
    foreach($fixture in @(@('odd',[byte[]]@(0)),@('cap',[byte[]]::new(8193)),@('class',[byte[]]@(0,1,7,0)),@('bit',[byte[]]@(0,1,0,2)))){
        $path=Join-Path $work "model-invalid-$($fixture[0]).input";Write-New $path $fixture[1];$null=Lock-Identity $path 'model-invalid-input'
        foreach($opt in @('3','2')){
            $absent=Join-Path $work "model-$($fixture[0])-opt$opt.rejected"
            $run=Invoke-Child (Join-Path $work "model-opt$opt.exe") @($path,$absent) 1
            if(Test-Path -LiteralPath $absent){throw 'Invalid Model input published output'}
            $checks.Add([pscustomobject]@{name="model-reject-$($fixture[0])-opt$opt";passed=$true;reason=$run.stderr})
        }
    }
    foreach($opt in @('3','2')){
        $modelExe=Join-Path $work "model-opt$opt.exe";$modelInput=Join-Path $work 'model-known.input'
        $existing=Join-Path $work "model-existing-opt$opt.output";Write-New $existing ([byte[]]@(31,41,59));$before=Identity $existing
        $run=Invoke-Child $modelExe @($modelInput,$existing) 1
        if((Identity $existing).sha256 -cne $before.sha256 -or $run.stderr -notmatch 'create_new'){throw 'Model no-clobber failed'}
        $null=Lock-Identity $existing 'model-no-clobber';$checks.Add([pscustomobject]@{name="model-no-clobber-opt$opt";passed=$true})
        foreach($argv in @([string[]]@(),[string[]]@($modelInput),[string[]]@($modelInput,(Join-Path $work 'model-extra.output'),'extra'),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'model-missing.output')),[string[]]@($work,(Join-Path $work 'model-directory.output')),[string[]]@($modelInput,(Join-Path $work 'model-absent-parent/output')))){
            $run=Invoke-Child $modelExe $argv 1
            foreach($absent in @('model-extra.output','model-missing.output','model-directory.output','model-absent-parent/output')){if(Test-Path -LiteralPath (Join-Path $work $absent)){throw 'Invalid Model invocation published output'}}
            $checks.Add([pscustomobject]@{name="model-invocation-opt$opt";passed=$true;argv=$argv;reason=$run.stderr})
        }
    }

    # direct KT入力は任意u32と有効cap内の偏り・等カウントを固定seedで混在させる。
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
public static class BalancedKtFixtures {
    public static byte[] Dataset() {
        var rows=new List<uint[]>();
        void Put(uint z,uint o){rows.Add(new[]{z,o});}
        uint[] edge={0,1,2,281018400,281018401,281018402,562036802,562036803,562036804,2147483647,2147483648,uint.MaxValue-1,uint.MaxValue};
        foreach(uint z in edge)foreach(uint o in edge)Put(z,o);
        for(int e=0;e<32;e++){uint p=1U<<e;foreach(uint z in new[]{p-1,p,p+1}){Put(z,z);Put(z,0);Put(0,z);Put(z,uint.MaxValue-z);}}
        for(uint t=562036800;t<=562036806;t++){foreach(uint z in new[]{0U,1U,t/2,t/2+1,t-1,t})Put(z,t-z);}
        var rng=new Random(20261001);var raw=new byte[4];
        uint Next(){rng.NextBytes(raw);return BitConverter.ToUInt32(raw,0);}
        while(rows.Count<65536){
            switch(rows.Count%4){
                case 0:Put(Next(),Next());break;
                case 1:uint c=Next()%281018402;Put(c,c);break;
                case 2:uint total=Next()%562036804;uint z=Next()%(total+1);Put(z,total-z);break;
                default:uint b=Next();Put(b,b);break;
            }
        }
        using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){foreach(var r in rows){bw.Write(r[0]);bw.Write(r[1]);}return ms.ToArray();}
    }
}
'@
    $ktInput=Join-Path $work 'kt-finite.input';$ktBytes=[BalancedKtFixtures]::Dataset()
    Write-New $ktInput $ktBytes;$ktInputId=Lock-Identity $ktInput 'kt-raw-input'
    $ktExpected=[byte[]]::new(65536*16);$ktCounts=[long[]]::new(4);$ktQ=[Numerics.BigInteger]4294967296
    for($r=0;$r -lt 65536;$r++){
        $z=[Numerics.BigInteger][BitConverter]::ToUInt32($ktBytes,$r*8);$o=[Numerics.BigInteger][BitConverter]::ToUInt32($ktBytes,$r*8+4)
        $total=$z+$o;$p=0UL;$code=0UL
        if($total -gt [uint32]::MaxValue){$code=1UL}elseif($total -gt 562036803){$code=2UL}else{$p=[uint64][Numerics.BigInteger]::Divide($ktQ*(2*$z+1),2*($total+1));if($p -lt 1 -or $p -ge 4294967296){throw 'KT oracle probability bound'}}
        $ktCounts[$code]++;if($code -eq 0 -and $z -eq $o){$ktCounts[3]++;if($p -ne 2147483648){throw 'Balanced oracle is not Q/2'}}
        [BitConverter]::GetBytes($p).CopyTo($ktExpected,$r*16);[BitConverter]::GetBytes($code).CopyTo($ktExpected,$r*16+8)
    }
    $ktOracle=Join-Path $work 'kt-finite.expected';Write-New $ktOracle $ktExpected;$ktOracleId=Lock-Identity $ktOracle 'kt-independent-oracle'
    foreach($opt in @('3','2')){foreach($round in 0..1){
        $output=Join-Path $work "kt-opt$opt-$round.output";$run=Invoke-Child (Join-Path $work "kt-opt$opt.exe") @($ktInput,$output) 0
        $owned.Add($output);$outputId=Lock-Identity $output 'kt-raw-output';$json=$run.stdout|ConvertFrom-Json
        if($json.operation -cne 'q32-balanced-kt-audit' -or $json.records -ne 65536 -or $json.error_messages.'1' -cne 'CTS node total overflow' -or $json.error_messages.'2' -cne 'CTS node observation cap exceeded' -or -not [Linq.Enumerable]::SequenceEqual[byte]($ktExpected,[IO.File]::ReadAllBytes($output))){throw 'Direct Node::kt value/status/message differs from independent BigInteger oracle'}
        $checks.Add([pscustomobject]@{name="kt-opt$opt-$round";passed=$true;records=65536;input=$ktInputId;oracle=$ktOracleId;output=$outputId})
    }}
    $ktEvidence=[pscustomobject]@{records=65536;input_record_bytes=8;output_record_bytes=16;input_fields=@('u32-zero','u32-one');output_fields=@('u64-probability-or-zero','u64-status');counts=$ktCounts;count_order=@('valid','total-overflow','cap-exceeded','valid-balanced');error_priority=@('u32-total-overflow','observation-cap');error_messages=@('CTS node total overflow','CTS node observation cap exceeded');seed=20261001;cfg='khc_balanced_kt_audit';oracle='PowerShell BigInteger Q*(2z+1)/(2*(z+o+1)); independent total and bounds'}
    foreach($name in @('odd','cap','capbyte')){
        $bytes=switch($name){odd{[byte[]]@(0)}cap{[byte[]]::new(65537*8)}capbyte{[byte[]]::new(65536*8+1)}}
        $bad=Join-Path $work "kt-$name.input";Write-New $bad $bytes;$null=Lock-Identity $bad 'kt-malformed-input'
        foreach($opt in @('3','2')){$output=Join-Path $work "kt-$name-opt$opt.rejected";$run=Invoke-Child (Join-Path $work "kt-opt$opt.exe") @($bad,$output) 1;if(Test-Path -LiteralPath $output){throw 'KT malformed publication'};$checks.Add([pscustomobject]@{name="kt-reject-$name-opt$opt";passed=$true;reason=$run.stderr})}
    }
    foreach($opt in @('3','2')){
        $exe=Join-Path $work "kt-opt$opt.exe"
        $existing=Join-Path $work "kt-existing-opt$opt.output";Write-New $existing ([byte[]]@(31,41,59));$before=Identity $existing
        $run=Invoke-Child $exe @($ktInput,$existing) 1;if((Identity $existing).sha256 -cne $before.sha256 -or $run.stderr -notmatch 'create_new'){throw 'KT no-clobber failed'};$null=Lock-Identity $existing 'kt-no-clobber';$checks.Add([pscustomobject]@{name="kt-no-clobber-opt$opt";passed=$true})
        foreach($argv in @([string[]]@(),[string[]]@($ktInput),[string[]]@($ktInput,(Join-Path $work 'kt-extra.output'),'extra'),[string[]]@((Join-Path $work 'kt-missing'),(Join-Path $work 'kt-missing.output')),[string[]]@($work,(Join-Path $work 'kt-directory.output')),[string[]]@($ktInput,(Join-Path $work 'kt-absent-parent/output')))){
            $run=Invoke-Child $exe $argv 1;$checks.Add([pscustomobject]@{name="kt-invocation-opt$opt";passed=$true;argv=$argv;reason=$run.stderr})
        }
        $out=Join-Path $work "kt-empty-opt$opt.output";$null=Invoke-Child $exe @((Join-Path $work 'empty.input'),$out) 0;$owned.Add($out);if((Lock-Identity $out 'kt-empty-output').bytes -ne 0){throw 'KT empty output'};$checks.Add([pscustomobject]@{name="kt-empty-opt$opt";passed=$true})
    }
    # 明示的に所有したリンクだけを拒否試験後に削除する。
    $inputLink=Join-Path $work 'kt-input-link';$outputLink=Join-Path $work 'kt-output-parent-link';$finalLink=Join-Path $work 'kt-output-link'
    $null=New-Item -ItemType Junction -Path $inputLink -Target $work
    $null=New-Item -ItemType Junction -Path $outputLink -Target $work
    $null=New-Item -ItemType Junction -Path $finalLink -Target $work
    try{
        foreach($link in @($inputLink,$outputLink,$finalLink)){
            $item=Get-Item -LiteralPath $link -Force
            if([IO.Path]::GetDirectoryName($item.FullName) -cne $work -or [IO.Path]::GetFullPath([string]$item.Target) -cne $work -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Owned junction identity/target mismatch'}
        }
        foreach($opt in @('3','2')){
            foreach($mode in @('input','parent','final')){
                $out=Join-Path $work "kt-reparse-$mode-opt$opt.rejected"
                $argv=switch($mode){input{@((Join-Path $inputLink 'kt-finite.input'),$out)}parent{@($ktInput,(Join-Path $outputLink "kt-reparse-parent-opt$opt.rejected"))}final{@($ktInput,$finalLink)}}
                $run=Invoke-Child (Join-Path $work "kt-opt$opt.exe") $argv 1
                if($run.stderr -notmatch 'reparse rejected' -or (Test-Path -LiteralPath $out)){throw 'KT reparse rejection failed'}
                $checks.Add([pscustomobject]@{name="kt-reparse-$mode-opt$opt";passed=$true;reason=$run.stderr})
            }
        }
    }finally{
        foreach($link in @($inputLink,$outputLink,$finalLink)){
            $absolute=[IO.Path]::GetFullPath($link)
            $item=Get-Item -LiteralPath $absolute -Force
            if([IO.Path]::GetDirectoryName($absolute) -cne $work -or [IO.Path]::GetFullPath([string]$item.Target) -cne $work -or -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Owned link cleanup scope/target mismatch'}
            & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $absolute -Root (Join-Path $root 'build') -AllowLeafLink | Out-Null
            if(Test-Path -LiteralPath $absolute){throw 'Owned link remained'}
        }
        if(-not (Test-Path -LiteralPath $work -PathType Container) -or (Identity $ktInput).sha256 -cne $ktInputId.sha256){throw 'Junction target/input damaged'}
        $checks.Add([pscustomobject]@{name='owned-reparse-cleanup';passed=$true;removed_paths=@($inputLink,$outputLink,$finalLink);target=$work;target_retained=$true;input_retained=$true;remaining_links=0})
    }

    if(@(Get-ChildItem -LiteralPath $work -Force -Filter '.quotient-*.tmp').Count -ne 0){throw 'Owned CLI temporary remained'}
    $checks.Add([pscustomobject]@{name='temporary-cleanup';passed=$true})
    if($checks.Count -lt 30 -or $calls.Count -lt 31){throw 'Inherited check/invocation floor not met'}
}catch{$failure=$_}
finally{
    try{foreach($id in $ids){$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){$failure='Pinned file identity changed'}}}catch{$failure=$_}
    finally{foreach($held in $locks){$held.Dispose()}}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});compiler_pin=$compilerSha;contract_pin=$contractSha;kt_dataset=$ktEvidence;dataset=$datasetEvidence;model_history=$historyEvidence;record_cap=65536;counts=$counts;count_order=@('records','same-weight','fallback-weight','remainder-zero','remainder-nonzero','bit-zero','bit-one');checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();owned_paths=$owned.ToArray();timing_used=$false;cpu_quiet_acceptance_measurement=$false;oracle='Independent PowerShell BigInteger positive snapshot sum; live-weight old ceiling; posterior floor; next-weight floor. No candidate implementation arithmetic shared. Real Model per-level Q32 KT/zero and updated counts/weights checked by independent sparse recursive C# BigInteger oracle.';limitations=@('Finite dataset, not exhaustive u64 enumeration','Windows x64 only','No codec/frame integration or performance claim','OOM and I/O fault injection untested');completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Q32 balanced KT numeric CLI E2E PASS: $($checks.Count) checks / $($calls.Count) calls; counts=$($counts -join ',')"
