#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-native32-quotient-numeric-20261001'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$oldRoot=Join-Path $root 'build/khc-split-estimate-quotient-20261001'
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
    if($row.stderr -notmatch $Reason){throw "Refusal reason mismatch: $Reason"}
    if(Test-Path -LiteralPath $OutputPath){throw 'Refusal published output'}
    Check "refusal-$Reason-$([IO.Path]::GetFileName($Exe))"
}
function Remove-Junction([string]$Path){
    $resolved=[IO.Path]::GetFullPath($Path);$expected=[IO.Path]::GetFullPath((Join-Path $work 'owned-junction'))
    if(-not $resolved.Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'Unexpected junction removal path'}
    if(Test-Path -LiteralPath $resolved){
        No-Reparse ([IO.Path]::GetDirectoryName($resolved));$item=Get-Item -LiteralPath $resolved -Force
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or $item.LinkType -cne 'Junction' -or @($item.Target).Count -ne 1 -or -not ([IO.Path]::GetFullPath(@($item.Target)[0])).Equals($work,[StringComparison]::OrdinalIgnoreCase)){throw 'Junction Target mismatch'}
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
} -Paths $resolved -Root (Join-Path $root 'build') -AllowLeafLink | Out-Null
    }
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned work root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null;$junction=Join-Path $work 'owned-junction'
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;protocol=@{input_record_bytes=24;output_record_bytes=32;record_cap=65536;errors=@{zero_denominator=1;product_overflow=2};native32_flag=32};dataset=$null;legacy=$null;inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Finite numeric boundary coverage is not exhaustive all-u64 verification.','Forced portable on Windows x64 is not a native ARM64 or macOS test.','Audit flags differ from the old helper on the guarded native path; ordinary quotient/error are preserved.','Audit may execute the guarded primitive again to observe real EDX remainder; it is not a timing benchmark.','No CTS/codec/product integration or speed adoption is claimed.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"native32-quotient-numeric","retain":"reproducible numeric CLI E2E evidence"}'))
try{
    $pins=@{
        'experiments/khc/Q32_NATIVE32_NUMERIC_CONTRACT_20261001.md'='298E94B29F0174BE9567D7153E2A49E9DC529D69100F862276714B3E96724F0D'
        'experiments/khc/Q32_NATIVE32_QUOTIENT_FEASIBILITY_20261001.md'='268AF44903743E447B4A0D9569436DADFDF88C8A1D7DD5253B96FA54D88F7BC2'
        'experiments/khc/split-estimate-quotient/exact_div.rs'='D969F4CDD89A41BA70BD1BD4C3EC4F4D99004455C9B6C66B53DE4DCC470C0966'
        'build/khc-split-estimate-quotient-20261001/report.json'='03C8C60C2DC435AD57BD96F5E19DC2E3EB2B275E775BB246E1292F55274C5C29'
    }
    foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'contract-or-parent-reference' $pin.Value}
    foreach($name in @('exact_div.rs','audit_cli.rs','verify.ps1')){$null=Hold (Join-Path $PSScriptRoot $name) 'current-source'}
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $oldReport=Get-Content -Raw -LiteralPath (Join-Path $oldRoot 'report.json')|ConvertFrom-Json
    if($oldReport.status -cne 'verified' -or $oldReport.counts[0] -ne 56191){throw 'Parent numeric proof incomplete'}
    foreach($name in @('finite.input','bigint.expected','finite-opt2-0.output','finite-opt2-1.output','finite-opt3-0.output','finite-opt3-1.output')){
        $path=Join-Path $oldRoot $name;$parentId=@($oldReport.identities|Where-Object {$_.path -ceq $path})
        if($parentId.Count -ne 1 -or $parentId[0].before_sha256 -cne $parentId[0].after_sha256 -or $parentId[0].before_bytes -ne $parentId[0].after_bytes){throw "Parent raw identity missing: $name"}
        $held=Hold $path 'parent-direct-raw' $parentId[0].before_sha256;if($held.bytes -ne $parentId[0].before_bytes){throw 'Parent raw length mismatch'}
    }
    $old=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../split-estimate-quotient/exact_div.rs')).Replace("`r`n","`n")
    $new=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'exact_div.rs')).Replace("`r`n","`n")
    $clean=$new.Replace('//! 独立数値実験。guarded64/32経路、診断flagsは製品へ導入しない。','//! 独立数値実験。診断flagsは製品モデルに導入しない。').Replace("pub const NATIVE32: u8 = 32;`n",'')
    $clean=[regex]::Replace($clean,'(?s)\n#\[inline\(always\)\]\nfn native32.*?(?=\n#\[inline\(always\)\]\npub fn ratio)','')
    $clean=$clean.Replace("    if let Some((quotient, _remainder)) = native32(n, d) {`n        return Ok((quotient, NATIVE32));`n    }`n",'')
    $clean=[regex]::Replace($clean,'(?s)\n#\[cfg\(khc_native32_audit\)\].*\z','')
    if($old.Trim() -cne $clean.Trim()){throw 'Portable original source correspondence failed'};Check 'old-portable-source-verbatim'
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'PowerShell Parser failure'}
    $null=Invoke-Child $compiler @('--version','--verbose')
    $formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe';$null=Hold $formatter 'formatter'
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot 'exact_div.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'))
    $executables=@()
    foreach($portable in @($false,$true)){foreach($opt in @('2','3')){
        $mode=if($portable){'portable'}else{'native'};$exe=Join-Path $work "$mode-opt$opt.exe"
        $argv=@((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','--cfg','khc_native32_audit','-C','panic=abort','-C',"opt-level=$opt",'-o',$exe)
        if($portable){$argv+=@('--cfg','khc_force_portable')}
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-audit'
        $executables+=@{mode=$mode;opt=$opt;portable=$portable;path=$exe}
    }}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Numerics;
using System.Collections.Generic;
public static class Native32Oracle {
    const ulong Q=1UL<<32;
    static ulong rng=0x5A23F08170CD19B5UL;
    static ulong Next(){rng^=rng<<13;rng^=rng>>7;rng^=rng<<17;return rng;}
    public static byte[] Dataset(){
        var rows=new List<ulong[]>();void Put(ulong a,ulong b,ulong d){rows.Add(new[]{a,b,d});}
        ulong[] ds={0,1,2,3,7,255,65535,(1UL<<31)-1,1UL<<31,(1UL<<31)+1,Q-1,Q,Q+1,ulong.MaxValue};
        ulong[] vals={0,1,2,Q-1,Q,Q+1,(1UL<<63)-1,1UL<<63,(1UL<<63)+1,ulong.MaxValue};
        foreach(ulong d in ds)foreach(ulong a in vals)foreach(ulong b in vals)Put(a,b,d);
        foreach(ulong d in ds)if(d>0&&d<Q){
            foreach(ulong h in new[]{d-1,d,d+1})if(h<Q)foreach(ulong low in new[]{0UL,1UL,Q/2,Q-1})Put((h<<32)|low,1,d);
            foreach(ulong quotient in new[]{Q-1,Q,Q+1})foreach(ulong r in new[]{0UL,d-1}){
                BigInteger n=(BigInteger)quotient*d+r;if(n<=ulong.MaxValue)Put((ulong)n,1,d);
            }
        }
        for(int shift=1;shift<64;shift++)foreach(ulong n in new[]{(1UL<<shift)-1,1UL<<shift,(1UL<<shift)+1})foreach(ulong d in ds)Put(n,1,d);
        while(rows.Count<65536){int k=rows.Count%7;ulong d=Next()%(Q-1)+1;
            if(k==0)Put(ulong.MaxValue,2,0);
            else if(k==1)Put(Next(),Next(),d);
            else if(k==2)Put(Next(),1,d);
            else if(k==3)Put(((Next()%d)<<32)|(Next()&(Q-1)),1,d);
            else if(k==4)Put(Next(),1,Q);
            else if(k==5)Put(Next(),1,Q+1+Next()%(ulong.MaxValue-Q));
            else Put(Next()&(Q-1),Next()&(Q-1),d);
        }
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){foreach(var row in rows)foreach(ulong v in row)w.Write(v);return ms.ToArray();}
    }
    public static byte[] Expected(byte[] input){
        using(var ms=new MemoryStream())using(var w=new BinaryWriter(ms)){
            for(int i=0;i<input.Length;i+=24){ulong a=BitConverter.ToUInt64(input,i),b=BitConverter.ToUInt64(input,i+8),d=BitConverter.ToUInt64(input,i+16);
                BigInteger n=(BigInteger)a*b;ulong error=d==0?1UL:n>ulong.MaxValue?2UL:0UL;
                ulong q=error==0?(ulong)(n/d):0,r=error==0?(ulong)(n%d):0;
                ulong method=error!=0?0:d==Q?1:d>Q?8:((ulong)n>>32)<d?32:ulong.MaxValue;
                w.Write(q);w.Write(r);w.Write(error);w.Write(method);
            }return ms.ToArray();
        }
    }
    public static long[] Check(byte[] input,byte[] expected,byte[] actual,bool portable,byte[] legacy=null){
        if(actual.Length!=input.Length/24*32||expected.Length!=actual.Length)throw new Exception("Record length mismatch");
        long[] methods=new long[5];
        for(int i=0;i<input.Length/24;i++){
            int o=i*32;ulong q=BitConverter.ToUInt64(actual,o),r=BitConverter.ToUInt64(actual,o+8),e=BitConverter.ToUInt64(actual,o+16),f=BitConverter.ToUInt64(actual,o+24);
            for(int k=0;k<3;k++)if(BitConverter.ToUInt64(actual,o+k*8)!=BitConverter.ToUInt64(expected,o+k*8))throw new Exception("BigInteger mismatch record "+i);
            ulong m=BitConverter.ToUInt64(expected,o+24),d=BitConverter.ToUInt64(input,i*24+16);
            if(e!=0){if(f!=0)throw new Exception("Error flags");methods[4]++;}
            else if(d==Q){if(f!=1)throw new Exception("Shift flags");methods[1]++;}
            else if(d>Q){if(f!=8)throw new Exception("Wide flags");methods[2]++;}
            else if(!portable&&m==32){if(f!=32)throw new Exception("Native guard/flags mismatch");methods[0]++;}
            else{if((f&~30UL)!=0)throw new Exception("Portable flags");methods[3]++;}
            if(legacy!=null){if(e!=0||q!=BitConverter.ToUInt64(legacy,i*9)||(portable&&f!=legacy[i*9+8]))throw new Exception("Legacy value/flags mismatch");}
        }return methods;
    }
}
'@
    $dataset=[Native32Oracle]::Dataset();if($dataset.Length -ne 65536*24){throw 'Dataset cap mismatch'}
    $expected=[Native32Oracle]::Expected($dataset)
    $input=Join-Path $work 'finite.input';$oracle=Join-Path $work 'bigint.expected';Write-New $input $dataset;Write-New $oracle $expected
    $null=Hold $input 'numeric-input';$null=Hold $oracle 'independent-oracle'
    $legacyInput=[IO.File]::ReadAllBytes((Join-Path $oldRoot 'finite.input'));$legacyExpected=[Native32Oracle]::Expected($legacyInput)
    if($legacyInput.Length -ne 56191*24){throw 'Legacy count mismatch'}
    $legacyOracle=Join-Path $work 'legacy-bigint.expected';Write-New $legacyOracle $legacyExpected;$null=Hold $legacyOracle 'independent-legacy-oracle'
    $nativeMethods=$null;$portableMethods=$null
    foreach($executable in $executables){foreach($round in 0..1){
        $output=Join-Path $work "finite-$($executable.mode)-opt$($executable.opt)-$round.output"
        $row=Invoke-Child $executable.path @($input,$output);$owned.Add($output);$null=Hold $output 'finite-raw-output'
        $stats=$row.stdout.Trim()|ConvertFrom-Json;if($stats.operation -cne 'native32-quotient-audit' -or $stats.records -ne 65536){throw 'CLI Stats mismatch'}
        $methods=[Native32Oracle]::Check($dataset,$expected,[IO.File]::ReadAllBytes($output),$executable.portable)
        if($executable.portable){$portableMethods=$methods}else{$nativeMethods=$methods};Check "finite-$($executable.mode)-opt$($executable.opt)-$round"
        $legacyOutput=Join-Path $work "legacy-$($executable.mode)-opt$($executable.opt)-$round.output"
        $row=Invoke-Child $executable.path @((Join-Path $oldRoot 'finite.input'),$legacyOutput);$owned.Add($legacyOutput);$null=Hold $legacyOutput 'legacy-raw-output'
        if(($row.stdout.Trim()|ConvertFrom-Json).records -ne 56191){throw 'Legacy Stats mismatch'}
        $oldRaw=[IO.File]::ReadAllBytes((Join-Path $oldRoot "finite-opt$($executable.opt)-$round.output"))
        $null=[Native32Oracle]::Check($legacyInput,$legacyExpected,[IO.File]::ReadAllBytes($legacyOutput),$executable.portable,$oldRaw);Check "legacy-$($executable.mode)-opt$($executable.opt)-$round"
    }}
    # 通常/portableそれぞれ全opt・反復を全byte比較する。
    foreach($mode in @('native','portable')){
        $reference=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $work "finite-$mode-opt2-0.output")))
        foreach($opt in @('2','3')){foreach($round in 0..1){if([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $work "finite-$mode-opt$opt-$round.output"))) -cne $reference){throw 'Repeat/opt raw mismatch'}}};Check "repeat-opt-fullbytes-$mode"
    }
    $report.dataset=@{records=65536;native_methods=$nativeMethods;portable_methods=$portableMethods;method_order=@('native32','shift','wide_native','portable_estimate','error')};$report.legacy=@{records=56191;portable_flags_preserved=$true;quotients_preserved=$true}
    $empty=Join-Path $work 'empty.input';$odd=Join-Path $work 'odd.input';$cap=Join-Path $work 'cap-plus-one.input'
    Write-New $empty ([byte[]]::new(0));Write-New $odd ([byte[]]@(1));Write-New $cap ([byte[]]::new(65536*24+24))
    foreach($path in @($empty,$odd,$cap)){$null=Hold $path 'refusal-input'}
    foreach($executable in $executables){
        $prefix="$($executable.mode)-opt$($executable.opt)";$output=Join-Path $work "empty-$prefix.output"
        $row=Invoke-Child $executable.path @($empty,$output);$owned.Add($output);$null=Hold $output 'empty-raw-output'
        if((Get-Item -LiteralPath $output).Length -ne 0 -or ($row.stdout.Trim()|ConvertFrom-Json).records -ne 0){throw 'Empty audit mismatch'};Check "empty-$prefix"
        Refuse $executable.path $odd (Join-Path $work "odd-$prefix.output") 'incomplete record'
        Refuse $executable.path $cap (Join-Path $work "cap-$prefix.output") 'within cap'
        Refuse $executable.path (Join-Path $work 'missing.input') (Join-Path $work "missing-$prefix.output") 'input open'
        Refuse $executable.path $work (Join-Path $work "directory-$prefix.output") 'input open|regular input'
        $sentinel=Join-Path $work "existing-$prefix.output";Write-New $sentinel ([byte[]]@(31,41,59));$before=Identity $sentinel
        $row=Invoke-Child $executable.path @($input,$sentinel) 1;if($row.stderr -notmatch 'output create_new publication:' -or (Identity $sentinel).sha256 -cne $before.sha256){throw 'No-clobber mismatch'};$null=Hold $sentinel 'no-clobber-sentinel';Check "no-clobber-$prefix"
    }
    $null=New-Item -ItemType Junction -Path $junction -Target $work
    $j=Get-Item -LiteralPath $junction -Force
    if($j.LinkType -cne 'Junction' -or @($j.Target).Count -ne 1 -or -not ([IO.Path]::GetFullPath(@($j.Target)[0])).Equals($work,[StringComparison]::OrdinalIgnoreCase)){throw 'Created junction Target mismatch'}
    $exe=$executables[0].path
    Refuse $exe (Join-Path $junction 'finite.input') (Join-Path $work 'reparse-input.output') 'reparse rejected'
    $row=Invoke-Child $exe @($input,(Join-Path $junction 'reparse-output.output')) 1
    if($row.stderr -notmatch 'reparse rejected' -or (Test-Path -LiteralPath (Join-Path $work 'reparse-output.output'))){throw 'Reparse output refusal failed'};Check 'ancestor-reparse-output-refused'
    $row=Invoke-Child $exe @($input,$junction) 1;if($row.stderr -notmatch 'reparse rejected'){throw 'Final reparse output refusal failed'};Check 'final-reparse-output-refused'
    Remove-Junction $junction
    $report.status='verified_numeric_not_timed'
}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    try{Remove-Junction $junction}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}
    foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw 'Source/raw after identity changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}}
    foreach($held in $locks){$held.Dispose()}
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{path=$_.FullName;name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null};reparse=(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}})
    $report.owned_tmp_count=@($report.inventory|Where-Object {$_.name -like '.native32-*.tmp'}).Count;$report.owned_reparse_count=@($report.inventory|Where-Object {$_.reparse}).Count
    if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Owned tmp/reparse remains'}}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)))
}
if($null -ne $failure){throw $failure}
"Numeric E2E passed: $($checks.Count) checks; $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
