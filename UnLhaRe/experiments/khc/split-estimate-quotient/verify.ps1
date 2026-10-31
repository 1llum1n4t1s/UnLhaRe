#requires -Version 7.2
# 失敗計画の正本: ../Q32_SPLIT_ESTIMATE_CONTRACT_20261001.md（実装前に作成）。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-split-estimate-quotient-20261001'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$compilerSha='CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
$contractSha='5A9693B2BEE9FBF72A2958460B80BA59F7B756B22C0F1BEDA9CFBD41372AD50F'
$ids=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new();$checks=[Collections.Generic.List[object]]::new();$owned=[Collections.Generic.List[string]]::new()
$failure=$null;$counts=$null;$datasetEvidence=$null
$oldRoot=Join-Path $root 'build/khc-signed-estimate-quotient-20261001'
$baseSha='4DB94AD93B403BCB41F85973A16CAA60A9A504DCD05B2FF9DA7F6224B2144106'
$oldProofSha='C3A57EA84F68E93F766AAC7C8BED6F8804FDF7324662BB77F7479FA0E211249C'
$oldInputSha='56FF5C408B4FDEF283E647EE497EE727C495C35D56EA5BB9EAA509CBA95EBCBD'
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
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"split-estimate-quotient-numeric","retain":"reproducible numeric CLI E2E artifacts"}'))
try {
    foreach($name in @('exact_div.rs','audit_cli.rs','verify.ps1')){$null=Lock-Identity (Join-Path $PSScriptRoot $name) 'source'}
    $contract=Lock-Identity (Join-Path $PSScriptRoot '../Q32_SPLIT_ESTIMATE_CONTRACT_20261001.md') 'failure-plan-contract'
    if($contract.sha256 -cne $contractSha){throw 'Contract pin mismatch'}
    $base=Lock-Identity (Join-Path $PSScriptRoot '../signed-estimate-quotient/exact_div.rs') 'old-signed-source'
    if($base.sha256 -cne $baseSha){throw 'Old inline source pin mismatch'}
    $proof=Lock-Identity (Join-Path $oldRoot 'report.json') 'old-proof'
    if($proof.sha256 -cne $oldProofSha){throw 'Old proof pin mismatch'}
    $oldInput=Lock-Identity (Join-Path $oldRoot 'finite.input') 'old-raw-input'
    if($oldInput.sha256 -cne $oldInputSha){throw 'Old input pin mismatch'}
    $oldPins=@(
        @{path=(Join-Path $PSScriptRoot '../signed-estimate-quotient/audit_cli.rs');role='old-cli-source';sha='C8E2CEE0C0CD1DA1D5FFF34A19388E04F1EB3C39EC88EBCD49D4E14E98988E0C'},
        @{path=(Join-Path $PSScriptRoot '../signed-estimate-quotient/verify.ps1');role='old-verifier-source';sha='301DCCA885917F0EDB2C3FF1DFCDB70BFB284B5F4A92FB668CC0F0BCB9A5BB45'},
        @{path=(Join-Path $oldRoot 'audit-opt3.exe');role='old-opt3-executable';sha='4286CE1614F610BD900413C01663D7E8AF0B2B0BB4B0A6338343CE5D2800F867'},
        @{path=(Join-Path $oldRoot 'audit-opt2.exe');role='old-opt2-executable';sha='47EA55866E5F783F931275D9AD0AE1A55C8C97DEA495E85F73A8D674C8FE6951'},
        @{path=(Join-Path $oldRoot 'bigint.expected');role='old-raw-oracle';sha='84D166A06DF470584BED8D8D96CE973685B1A5B3FA7B2BD467AD16E631BDDCE3'}
    )
    foreach($opt in @('3','2')){foreach($round in 0..1){$oldPins+=@{path=(Join-Path $oldRoot "finite-opt$opt-$round.output");role='old-raw-output';sha='238979E4F4A380D335B5104AF61A76249DCC3E9F2D57ACAF5ADFDDED0898C9A3'}}}
    foreach($oldPin in $oldPins){$identity=Lock-Identity $oldPin.path $oldPin.role;if($identity.sha256 -cne $oldPin.sha){throw 'Old artifact pin mismatch'}}
    $oldReport=[IO.File]::ReadAllText($proof.path)|ConvertFrom-Json
    if($oldReport.status -cne 'verified' -or $oldReport.counts[0] -ne 56191 -or $oldReport.checks.Count -lt 30 -or $oldReport.invocations.Count -lt 31){throw 'Old proof not verified'}
    $pin=Lock-Identity $compiler 'compiler';if($pin.sha256 -cne $compilerSha){throw 'Compiler pin mismatch'}
    $null=Invoke-Child $compiler @('--version','--verbose') 0
    foreach($opt in @('3','2')){
        $exe=Join-Path $work "audit-opt$opt.exe"
        $null=Invoke-Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'-o',$exe) 0
        $owned.Add($exe);$null=Lock-Identity $exe "opt$opt-executable"
    }
    # oracleはBigIntegerの積・除算・残余のみを使う。helperのf64補正は再実装しない。
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Numerics;
public static class QuotientOracle {
    const ulong Q=1UL<<32;
    static List<ulong[]> rows=new List<ulong[]>();
    static void Add(ulong a,ulong b,ulong d){if(d==0 || (BigInteger)a*b>ulong.MaxValue)return;rows.Add(new[]{a,b,d});}
    public static byte[] Dataset(){
        rows.Clear();ulong m=ulong.MaxValue;ulong p=1UL<<53;
        ulong[] ns={0,1,2,3,Q-1,Q,Q+1,p-2,p-1,p,p+1,p+2,m-2,m-1,m};
        ulong[] ds={1,2,3,7,31,Q/2-1,Q/2,Q/2+1,Q-2,Q-1,Q,Q+1,p-1,p,p+1,m-1,m};
        foreach(ulong n in ns)foreach(ulong d in ds)Add(n,1,d);
        foreach(ulong d in ds)foreach(ulong q in new ulong[]{1,2,3,7,Q-1,Q,Q+1,p-1,p}){
            BigInteger center=(BigInteger)d*q;for(int delta=-2;delta<=2;delta++){BigInteger n=center+delta;if(n>=0 && n<=m)Add((ulong)n,1,d);}
        }
        // KT count cap / alpha / posterior boundaries, each as original checked product.
        foreach(ulong count in new ulong[]{0,1,2,562036802,562036803}){
            foreach(ulong zero in new ulong[]{0,count/2,count})Add(Q/2,2*zero+1,count+1);
            Add(Q,1,count+2);
        }
        foreach(ulong w in new ulong[]{0,1,7,Q/2,Q-1,Q})foreach(ulong prob in new ulong[]{1,7,Q/2,Q-1,Q})foreach(ulong d in new ulong[]{1,7,Q/2,Q-1,Q})Add(w,prob,d);
        var rng=new Random(20261001);byte[] buf=new byte[8];
        for(int i=0;i<24000;i++){
            rng.NextBytes(buf);ulong n=BitConverter.ToUInt64(buf,0);
            rng.NextBytes(buf);ulong d=BitConverter.ToUInt64(buf,0);
            if(i%3==0)d=(d%Q)+1;else if(i%3==1)d=(d%4096)+1;else if(d==0)d=1;
            Add(n,1,d);
            // 可用範囲の二因子積も検査。
            if(i<6000){ulong a=n&0xffffffff;ulong b=(n>>32);Add(a,b,d);}
        }
        Add(m-1,1,Q-1);Add(m,1,3);Add(m,1,Q+1);
        if(rows.Count!=30937)throw new Exception("Old dataset record count");
        // signed境界の全8193分子とd=1/2/3: 24579件を追加。
        ulong signedMax=(ulong)long.MaxValue;
        for(int delta=-4096;delta<=4096;delta++){
            ulong n=(ulong)((BigInteger)signedMax+delta);
            foreach(ulong d in new ulong[]{1,2,3})Add(n,1,d);
        }
        if(rows.Count!=55516)throw new Exception("Signed neighborhood record count");
        // 選択境界も両枝・shift/native・dQ±1・二因子積で検査。
        foreach(ulong center in new ulong[]{p,signedMax,signedMax+1,m-4096,m}){
            for(int delta=-8;delta<=8;delta++){
                BigInteger n=(BigInteger)center+delta;
                if(n>=0 && n<=m)foreach(ulong d in new ulong[]{1,2,3,Q-1,Q,Q+1})Add((ulong)n,1,d);
            }
        }
        foreach(ulong a in new ulong[]{Q/2-1,Q/2,Q/2+1,Q-1,Q,Q+1}){
            foreach(ulong b in new ulong[]{Q-2,Q-1,Q,Q+1,Q+2})
                foreach(ulong d in new ulong[]{1,2,3,Q-1,Q,Q+1})Add(a,b,d);
        }
        for(ulong count=562036801;count<=562036803;count++){
            foreach(ulong zero in new ulong[]{0,1,count/2,count-1,count})Add(Q/2,2*zero+1,count+1);
            Add(Q,1,count+2);
        }
        foreach(ulong d in new ulong[]{1,2,3,Q-1,Q,Q+1}){
            foreach(ulong q in new ulong[]{p-1,p,p+1,signedMax/3,signedMax/2,signedMax,signedMax+1,m}){
                for(int delta=-1;delta<=1;delta++){
                    BigInteger n=(BigInteger)d*q+delta;
                    if(n>=0 && n<=m)Add((ulong)n,1,d);
                }
            }
        }
        if(rows.Count>65536)throw new Exception("Dataset cap");
        using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){foreach(var r in rows)foreach(var v in r)bw.Write(v);return ms.ToArray();}
    }
    public static byte[] Expected(byte[] input){using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){for(int at=0;at<input.Length;at+=24){BigInteger n=(BigInteger)BitConverter.ToUInt64(input,at)*BitConverter.ToUInt64(input,at+8);BigInteger d=BitConverter.ToUInt64(input,at+16);bw.Write((ulong)(n/d));}return ms.ToArray();}}
    public static long[] Check(byte[] input,byte[] actual,byte[] expected){
        if(actual.Length!=input.Length/24*9 || expected.Length!=input.Length/24*8)throw new Exception("Output length");
        long[] counts=new long[7];
        for(int row=0;row<input.Length/24;row++){
            ulong q=BitConverter.ToUInt64(actual,row*9);byte flags=actual[row*9+8];
            BigInteger n=(BigInteger)BitConverter.ToUInt64(input,row*24)*BitConverter.ToUInt64(input,row*24+8);
            ulong d=BitConverter.ToUInt64(input,row*24+16);BigInteger prod=(BigInteger)q*d;
            if(q!=BitConverter.ToUInt64(expected,row*8) || prod>n || n-prod>=d || (flags&~31)!=0)throw new Exception("Oracle/certificate mismatch row "+row);
            if(d==Q && flags!=1 || d!=Q && (flags&1)!=0 || d>Q && (flags&8)==0)throw new Exception("Classification mismatch");
            counts[0]++;if(flags==0)counts[1]++;if((flags&1)!=0)counts[2]++;if((flags&2)!=0)counts[3]++;if((flags&4)!=0)counts[4]++;if((flags&8)!=0)counts[5]++;if((flags&16)!=0)counts[6]++;
        }return counts;
    }
    public static byte[] Invalid(ulong a,ulong b,ulong d){using(var ms=new MemoryStream())using(var bw=new BinaryWriter(ms)){bw.Write(1UL);bw.Write(1UL);bw.Write(1UL);bw.Write(a);bw.Write(b);bw.Write(d);return ms.ToArray();}}
}
'@
    $inputBytes=[QuotientOracle]::Dataset();$input=Join-Path $work 'finite.input';Write-New $input $inputBytes;$null=Lock-Identity $input 'raw-input'
    $oldBytes=[IO.File]::ReadAllBytes($oldInput.path)
    if($inputBytes.Length -ne 56191*24 -or -not [Linq.Enumerable]::SequenceEqual[byte]($oldBytes,$inputBytes)){throw 'Old full input bytes mismatch'}
    $datasetEvidence=[pscustomobject]@{old_records=56191;old_rows='Exact full input bytes';signed_neighborhood_records=24579;signed_neighborhood='i64::MAX-4096 through i64::MAX+4096 inclusive, each d=1/2/3';additional_boundary_records=$inputBytes.Length/24-55516;records=$inputBytes.Length/24;old_flags_comparison_required=$true;old_raw_outputs=4}
    $checks.Add([pscustomobject]@{name='old-full-input-identical';passed=$true;records=56191;input_pin=$oldInputSha})
    $expected=[QuotientOracle]::Expected($inputBytes);$oracle=Join-Path $work 'bigint.expected';Write-New $oracle $expected;$null=Lock-Identity $oracle 'raw-oracle'
    if(-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes((Join-Path $oldRoot 'bigint.expected')),$expected)){throw 'Old full oracle bytes mismatch'}
    $checks.Add([pscustomobject]@{name='old-full-oracle-identical';passed=$true;records=56191})
    $baseline=$null
    foreach($opt in @('3','2')){foreach($round in 0..1){
        $output=Join-Path $work "finite-opt$opt-$round.output";$run=Invoke-Child (Join-Path $work "audit-opt$opt.exe") @($input,$output) 0
        $owned.Add($output);$id=Lock-Identity $output 'raw-output';$json=$run.stdout|ConvertFrom-Json
        if($json.operation -cne 'split-estimate-quotient' -or $json.records -ne $inputBytes.Length/24){throw 'CLI metadata mismatch'}
        $bytes=[IO.File]::ReadAllBytes($output);$counts=[QuotientOracle]::Check($inputBytes,$bytes,$expected)
        if($null -eq $baseline){$baseline=$bytes}else{if(-not [Linq.Enumerable]::SequenceEqual[byte]($baseline,$bytes)){throw 'Full byte opt/repeat mismatch'}}
        foreach($oldOpt in @('3','2')){foreach($oldRound in 0..1){
            $oldOutput=Join-Path $oldRoot "finite-opt$oldOpt-$oldRound.output"
            if(-not [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($oldOutput),$bytes)){throw 'Old full quotient/flags bytes mismatch'}
            $checks.Add([pscustomobject]@{name="old-full-bytes-opt$opt-$round-vs-opt$oldOpt-$oldRound";passed=$true;bytes=$bytes.Length;old_output=$oldOutput})
        }}
        $checks.Add([pscustomobject]@{name="oracle-opt$opt-$round";passed=$true;records=$json.records;output=$id})
    }}
    if($counts[3] -eq 0 -or $counts[4] -eq 0 -or $counts[5] -eq 0 -or $counts[6] -eq 0){throw 'Required correction/fallback/overflow coverage absent'}
    foreach($fixture in @(@('odd',[byte[]]@(1)),@('cap',[byte[]]::new(65537*24)),@('zero',[QuotientOracle]::Invalid(1,1,0)),@('overflow',[QuotientOracle]::Invalid([ulong]::MaxValue,2,1)))){
        $path=Join-Path $work "$($fixture[0]).input";Write-New $path $fixture[1];$null=Lock-Identity $path 'invalid-raw-input'
        foreach($opt in @('3','2')){$absent=Join-Path $work "$($fixture[0])-opt$opt.rejected";$run=Invoke-Child (Join-Path $work "audit-opt$opt.exe") @($path,$absent) 1;if(Test-Path -LiteralPath $absent){throw 'Malformed input published output'};$checks.Add([pscustomobject]@{name="reject-$($fixture[0])-opt$opt";passed=$true;reason=$run.stderr})}
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
    if(@(Get-ChildItem -LiteralPath $work -Force -Filter '.quotient-*.tmp').Count -ne 0){throw 'Owned CLI temporary remained'}
    $checks.Add([pscustomobject]@{name='temporary-cleanup';passed=$true})
    if($checks.Count -lt 30 -or $calls.Count -lt 31){throw 'Inherited check/invocation floor not met'}
}catch{$failure=$_}
finally{
    try{foreach($id in $ids){$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){$failure='Pinned file identity changed'}}}catch{$failure=$_}
    finally{foreach($held in $locks){$held.Dispose()}}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});compiler_pin=$compilerSha;contract_pin=$contractSha;old_signed_source_pin=$baseSha;old_proof_pin=$oldProofSha;old_input_pin=$oldInputSha;dataset=$datasetEvidence;record_cap=65536;counts=$counts;count_order=@('records','uncorrected','shift','down','up','fallback','guess_product_overflow');checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();owned_paths=$owned.ToArray();timing_used=$false;oracle='Independent C# BigInteger checked product and exact quotient + remainder certificate; deterministic seed 20261001';domain='d>Q directly falls back; d<=Q with quotient>Q may need fallback and is not within assumed one-correction support';limitations=@('Finite dataset, not exhaustive u64 enumeration','Windows x64 only','No codec/CTS/frame integration','No performance claim','OOM and I/O fault injection untested');completed_utc=[DateTime]::UtcNow.ToString('o')}
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Split estimate quotient CLI E2E PASS: $($checks.Count) checks / $($calls.Count) calls; counts=$($counts -join ',')"
