#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-kt-reciprocal-numeric-20261001'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$oldRoot=Join-Path $root 'build/khc-q32-balanced-kt-numeric-20261001-junction-validated'
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
function Same-KT-Bytes([string]$Left,[string]$Right){
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Left)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Right))){throw "Full raw mismatch: $Left"}
}

No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned work root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null;$junction=Join-Path $work 'owned-junction'
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;protocol=@{input_record_bytes=8;output_record_bytes=32;record_cap=524288;errors=@{total_overflow=1;observation_cap=2};methods=@('error','equal','table','fallback');table_bytes=524296};datasets=@();inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Finite numeric coverage is not an exhaustive enumeration of all KT states.','Frozen independent KT oracle is reused; no new independent-author audit.','Forced portable x64 is not ARM64/macOS native verification.','No Model/full codec/product integration or speed adoption is claimed.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"KT-exact-reciprocal-numeric","retain":"reproducible CLI numeric E2E evidence"}'))
try{
    $pins=@{
        'experiments/khc/Q32_KT_RECIPROCAL_EXACT_PROOF_20261001.md'='F2E6122F37C6DF1A273161A3DFB5CDC3BF977B404C49D55D527D0B2583F7983C'
        'experiments/khc/Q32_KT_RECIPROCAL_NUMERIC_CONTRACT_20261001.md'='6FCF94B9FD52247F4324962D61E301C660DCC637F122E2A3B49529C320C4494A'
        'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
        'build/khc-q32-kt-denominator-counts-20261001/report.json'='5EA832E691142C9B1853DEC25BD3A6948A0F9E588344F934DCD587D84E861EFC'
        'build/khc-q32-balanced-kt-numeric-20261001-junction-validated/report.json'='63ACB1BBF1A2EFE811B76E761C6AA4CFDF2F4C443F75E24AD18FD97D312F5DAF'
    }
    foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'contract-or-parent-reference' $pin.Value}
    foreach($file in @('exact_kt.rs','audit_cli.rs','verify.ps1')){$null=Hold (Join-Path $PSScriptRoot $file) 'new-source-freeze'}
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $parent=Get-Content -LiteralPath (Join-Path $oldRoot 'report.json') -Raw|ConvertFrom-Json
    if($parent.status -cne 'verified' -or $parent.kt_dataset.records -ne 65536){throw 'Frozen KT prerequisite mismatch'}
    $legacyFiles=@('kt-finite.input','kt-finite.expected','kt-opt2-0.output','kt-opt2-1.output','kt-opt3-0.output','kt-opt3-1.output')
    foreach($name in $legacyFiles){
        $path=Join-Path $oldRoot $name;$oldId=@($parent.identities|Where-Object {$_.path -ceq $path})
        if($oldId.Count -ne 1 -or $oldId[0].before_bytes -ne $oldId[0].after_bytes -or $oldId[0].before_sha256 -cne $oldId[0].after_sha256){throw 'Frozen KT identity mismatch'}
        $current=Hold $path 'frozen-KT-fixture' $oldId[0].before_sha256;if($current.bytes -ne $oldId[0].before_bytes){throw 'Frozen KT length mismatch'}
    }
    foreach($name in $legacyFiles[2..5]){Same-KT-Bytes (Join-Path $oldRoot $name) (Join-Path $oldRoot 'kt-finite.expected')}
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'PowerShell Parser failure'}
    $null=Invoke-Child $compiler @('--version','--verbose')
    $formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe';$null=Hold $formatter 'formatter'
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot 'exact_kt.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'))
    $executables=@()
    foreach($portable in @($false,$true)){foreach($opt in @('2','3')){
        $mode=if($portable){'portable'}else{'native'};$exe=Join-Path $work "KT-$mode-opt$opt.exe"
        $argv=@('--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'--cfg','khc_kt_reciprocal_audit')
        if($portable){$argv+=@('--cfg','khc_force_portable')};$argv+=@((Join-Path $PSScriptRoot 'audit_cli.rs'),'-o',$exe)
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-KT-CLI';$executables+=@{path=$exe;mode=$mode;opt=$opt}
    }}
    Add-Type -ReferencedAssemblies System.Runtime,System.Numerics,System.Runtime.Numerics -TypeDefinition @'
using System;
using System.IO;
using System.Numerics;
public static class KtReciprocalOracle {
    const ulong Q=1UL<<32,CAP=562036803;
    public static byte[] Domain(){
        using(var m=new MemoryStream())using(var w=new BinaryWriter(m)){
            for(uint d=2;d<=65536;d++){
                uint t=d-1;
                foreach(uint z in new[]{0U,t,t/2,t/3,2*t/3}){w.Write(z);w.Write(t-z);}
            }return m.ToArray();
        }
    }
    public static byte[] Boundary(){
        uint[,] pairs={{0,0},{1,1},{281018401,281018401},{281018402,281018402},{0,562036803},{562036803,0},{0,562036804},{562036804,0},{uint.MaxValue,1},{uint.MaxValue,uint.MaxValue},{uint.MaxValue,0},{65535,0},{65536,0},{0,65535},{0,65536},{32768,32768}};
        using(var m=new MemoryStream())using(var w=new BinaryWriter(m)){for(int i=0;i<pairs.GetLength(0);i++){w.Write(pairs[i,0]);w.Write(pairs[i,1]);}return m.ToArray();}
    }
    public static byte[] Expected(byte[] data){
        using(var m=new MemoryStream())using(var w=new BinaryWriter(m)){
            for(int i=0;i<data.Length;i+=8){
                uint z=BitConverter.ToUInt32(data,i),o=BitConverter.ToUInt32(data,i+4);
                ulong t=(ulong)z+o,d=t+1,error=t>uint.MaxValue?1UL:t>CAP?2UL:0UL;
                ulong p=error==0?(ulong)(((BigInteger)Q*(2*(BigInteger)z+1))/(2*(BigInteger)d)):0;
                ulong method=error!=0?0:z==o?1UL:d<=65536?2UL:3UL;
                ulong reciprocal=method==2?(ulong)(((BigInteger.One<<64)+d-1)/d):0;
                w.Write(p);w.Write(error);w.Write(method);w.Write(reciprocal);
            }return m.ToArray();
        }
    }
    public static long[] Check(byte[] expected,byte[] actual,byte[] legacy=null){
        if(actual.Length!=expected.Length||actual.Length%32!=0)throw new Exception("Record size mismatch");
        long[] methods=new long[4];
        for(int i=0;i<actual.Length;i++)if(actual[i]!=expected[i])throw new Exception("Independent oracle mismatch byte "+i);
        for(int i=0;i<actual.Length/32;i++){
            ulong method=BitConverter.ToUInt64(actual,i*32+16);if(method>3)throw new Exception("Method mismatch");methods[method]++;
            if(legacy!=null)for(int k=0;k<16;k++)if(actual[i*32+k]!=legacy[i*16+k])throw new Exception("Legacy probability/error mismatch");
        }
        if(legacy!=null&&legacy.Length!=actual.Length/2)throw new Exception("Legacy length mismatch");
        return methods;
    }
}
'@
    $datasets=@()
    foreach($case in @('domain','boundary','legacy')){
        $bytes=if($case -eq 'domain'){[KtReciprocalOracle]::Domain()}elseif($case -eq 'boundary'){[KtReciprocalOracle]::Boundary()}else{[IO.File]::ReadAllBytes((Join-Path $oldRoot 'kt-finite.input'))}
        $count=$bytes.Length/8
        if(($case -eq 'domain' -and $count -ne 327675) -or ($case -eq 'legacy' -and $count -ne 65536)){throw 'Dataset count mismatch'}
        $fixture=Join-Path $work "$case.input";$oracle=Join-Path $work "$case.expected"
        Write-New $fixture $bytes;Write-New $oracle ([KtReciprocalOracle]::Expected($bytes));$null=Hold $fixture 'numeric-input';$null=Hold $oracle 'independent-oracle'
        $datasets+=@{name=$case;input=$fixture;expected=$oracle;records=$count}
    }
    foreach($executable in $executables){foreach($dataset in $datasets){
        $output=Join-Path $work "$($dataset.name)-$($executable.mode)-opt$($executable.opt).output"
        $row=Invoke-Child $executable.path @($dataset.input,$output);$owned.Add($output);$null=Hold $output 'numeric-raw-output'
        $stats=$row.stdout.Trim()|ConvertFrom-Json
        if($stats.operation -cne 'kt-reciprocal-audit' -or $stats.records -ne $dataset.records -or $stats.table_bytes -ne 524296){throw 'Stats/table layout mismatch'}
        $legacy=if($dataset.name -eq 'legacy'){[IO.File]::ReadAllBytes((Join-Path $oldRoot 'kt-finite.expected'))}else{$null}
        $methods=[KtReciprocalOracle]::Check([IO.File]::ReadAllBytes($dataset.expected),[IO.File]::ReadAllBytes($output),$legacy)
        Check "oracle-$($dataset.name)-$($executable.mode)-opt$($executable.opt)"
        if($executable.mode -eq 'native' -and $executable.opt -eq '3'){$report.datasets+=@{name=$dataset.name;records=$dataset.records;methods=$methods}}
    }}
    foreach($executable in @($executables|Where-Object {$_.opt -eq '3'})){
        $output=Join-Path $work "domain-$($executable.mode)-opt3-repeat.output"
        $null=Invoke-Child $executable.path @($datasets[0].input,$output);$owned.Add($output);$null=Hold $output 'repeat-raw-output'
        Same-KT-Bytes $output (Join-Path $work "domain-$($executable.mode)-opt3.output");Check "repeat-$($executable.mode)"
    }
    $empty=Join-Path $work 'empty.input';$odd=Join-Path $work 'odd.input';$over=Join-Path $work 'cap-plus-one.input';$maximum=Join-Path $work 'maximum.input'
    Write-New $empty ([byte[]]::new(0));Write-New $odd ([byte[]]@(1));Write-New $over ([byte[]]::new(524288*8+8));Write-New $maximum ([byte[]]::new(524288*8))
    foreach($path in @($empty,$odd,$over,$maximum)){$null=Hold $path 'boundary-format-input'}
    $maxExpected=Join-Path $work 'maximum.expected';Write-New $maxExpected ([KtReciprocalOracle]::Expected([IO.File]::ReadAllBytes($maximum)));$null=Hold $maxExpected 'maximum-oracle'
    foreach($executable in $executables){
        $prefix="$($executable.mode)-opt$($executable.opt)";$output=Join-Path $work "empty-$prefix.output"
        $row=Invoke-Child $executable.path @($empty,$output);$owned.Add($output);$null=Hold $output 'empty-output'
        if((Get-Item -LiteralPath $output).Length -ne 0 -or ($row.stdout.Trim()|ConvertFrom-Json).records -ne 0){throw 'Empty mismatch'};Check "empty-$prefix"
        Refuse $executable.path $odd (Join-Path $work "odd-$prefix.output") 'incomplete record'
        Refuse $executable.path $over (Join-Path $work "cap-$prefix.output") 'within cap'
        $sentinel=Join-Path $work "existing-$prefix.output";Write-New $sentinel ([byte[]]@(31,41,59));$before=Identity $sentinel
        $row=Invoke-Child $executable.path @($datasets[1].input,$sentinel) 1
        if($row.stderr -notmatch 'output create_new publication:' -or (Identity $sentinel).sha256 -cne $before.sha256){throw 'No-clobber mismatch'}
        $null=Hold $sentinel 'no-clobber-sentinel';Check "no-clobber-$prefix"
    }
    $maxOutput=Join-Path $work 'maximum.output';$row=Invoke-Child $executables[0].path @($maximum,$maxOutput);$owned.Add($maxOutput);$null=Hold $maxOutput 'maximum-raw-output'
    $null=[KtReciprocalOracle]::Check([IO.File]::ReadAllBytes($maxExpected),[IO.File]::ReadAllBytes($maxOutput))
    if(($row.stdout.Trim()|ConvertFrom-Json).records -ne 524288){throw 'Maximum Stats mismatch'};Check 'maximum-524288-records'
    Refuse $executables[0].path (Join-Path $work 'missing.input') (Join-Path $work 'missing.output') 'input open'
    Refuse $executables[0].path $work (Join-Path $work 'directory.output') 'input open|regular input'
    $null=New-Item -ItemType Junction -Path $junction -Target $work
    $j=Get-Item -LiteralPath $junction -Force
    if($j.LinkType -cne 'Junction' -or @($j.Target).Count -ne 1 -or -not ([IO.Path]::GetFullPath(@($j.Target)[0])).Equals($work,[StringComparison]::OrdinalIgnoreCase)){throw 'Created junction Target mismatch'}
    Refuse $executables[0].path (Join-Path $junction 'domain.input') (Join-Path $work 'reparse-input.output') 'reparse rejected'
    $row=Invoke-Child $executables[0].path @($datasets[1].input,(Join-Path $junction 'reparse-output.output')) 1
    if($row.stderr -notmatch 'reparse rejected' -or (Test-Path -LiteralPath (Join-Path $work 'reparse-output.output'))){throw 'Output reparse mismatch'};Check 'output-ancestor-reparse-refusal'
    $row=Invoke-Child $executables[0].path @($datasets[1].input,$junction) 1;if($row.stderr -notmatch 'reparse rejected'){throw 'Final reparse mismatch'};Check 'final-reparse-refusal'
    Remove-Junction $junction
    $report.status='verified_KT_reciprocal_numeric_not_timed'
}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    try{Remove-Junction $junction}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}
    foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw 'Source/raw after identity changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}}
    foreach($held in $locks){$held.Dispose()}
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{path=$_.FullName;name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null};reparse=(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}})
    $report.owned_tmp_count=@($report.inventory|Where-Object {$_.name -like '.kt-reciprocal-*.tmp'}).Count;$report.owned_reparse_count=@($report.inventory|Where-Object {$_.reparse}).Count
    if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Owned tmp/reparse remains'}}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)))
}
if($null -ne $failure){throw $failure}
"KT numeric E2E passed: $($checks.Count) checks; $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
