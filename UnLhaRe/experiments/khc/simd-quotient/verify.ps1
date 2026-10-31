#requires -Version 7.2
# 実装前失敗計画: ../SIMD_QUOTIENT_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-simd-quotient-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$failure=$null
$summaries=[Collections.Generic.List[object]]::new()
$features=$null
$began=[DateTime]::UtcNow.ToString('o')
function Hold([string]$Path,[string]$Role,[string]$Expected='') {
    $full=[IO.Path]::GetFullPath($Path)
    $ancestor=$full
    while($ancestor) {
        if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "reparse: $ancestor"}
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $locks.Add([IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $item=Get-Item -LiteralPath $full
    $sha=(Get-FileHash -LiteralPath $full).Hash
    if($Expected -and $sha -cne $Expected){throw "pin mismatch: $Role"}
    $ids.Add([pscustomobject]@{path=$full;role=$Role;bytes=$item.Length;before_sha256=$sha;after_sha256=$null})
}
function Child([string]$Program,[string[]]$Argv,[int]$Expected=0) {
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.WorkingDirectory=$work;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($argument in $Argv){$info.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $started=$false
    try {
        $started=$process.Start();if(!$started){throw 'start failed'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(120000)){throw '120s timeout'}
        $call=[pscustomobject]@{program=$Program;argv=$Argv;exit=$process.ExitCode;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($call)
        if($call.exit -ne $Expected -or ($Expected -eq 0 -and $call.stderr) -or ($Expected -ne 0 -and $call.stdout)){throw 'unexpected child result'}
        return $call.stdout
    } finally {
        if($started -and !$process.HasExited){$process.Kill($true);$null=$process.WaitForExit(10000)}
        $process.Dispose()
    }
}

function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
if(Test-Path -LiteralPath $work){throw 'Fresh work directory required; no automatic retry/overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Hold (Join-Path $PSScriptRoot '../SIMD_QUOTIENT_CONTRACT_20261002.md') 'preimplementation-contract' '2587739B4CF5C4AB8FF3980782D9B16AEA57A47F45FE9012841BC41C3DAC6D4D'
    Hold (Join-Path $PSScriptRoot '../integer-refinement-narrow/audit_cli.rs') 'frozen-old-audit' '60495ACFC85E6DC32ECAA2AB28BD31DB37F8E5904331617F0F1BAEAB1A7E7A6D'
    foreach($name in @('exact_div.rs','audit_cli.rs','audit-correspondence.json','verify.ps1')){Hold (Join-Path $PSScriptRoot $name) 'new-source'}
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    $expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../integer-refinement-narrow/audit_cli.rs')).Replace("`r`n","`n")
    foreach($change in (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'audit-correspondence.json') -Raw|ConvertFrom-Json)){
        if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'audit source occurrence'}
        $expected=$expected.Replace([string]$change.old,[string]$change.new)
    }
    if([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'audit_cli.rs')).Replace("`r`n","`n") -cne $expected){throw 'full audit source correspondence'}
    $checks.Add('full-audit-correspondence-and-old-u128-oracle')
    $null=Child $compiler @('--version','--verbose')
    $golden=$null
    $vectors=@(
        @('0','0','0'),@('18446744073709551615','18446744073709551615','0'),
        @('18446744073709551615','2','3'),@('18446744073709551615','1','4294967295'),
        @('18446744073709551615','1','4294967296'),@('18446744073709551615','1','4294967297'),
        @('4294967295','4294967295','4294967295'),@('4294967295','4294967294','4294967295'),
        @('2147483648','4294967295','2147483649'),@('4294967296','4294967295','4294967295'),
        @('1','1','1'),@('9223372036854775807','1','2147483649'),@('9223372036854775808','1','2147483649'),
        @('18446743725817118960','1','4294967215')
    )

    foreach($level in @(2,3)){
        $exe=Join-Path $work "audit-opt$level.exe"
        $null=Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','-C','panic=abort','-C',"opt-level=$level",'-C','overflow-checks=yes','-o',$exe)
        Hold $exe "audit-opt$level"
        $featureText=Child $exe @('features')
        $currentFeatures=$featureText|ConvertFrom-Json
        if($null -eq $features){$features=$currentFeatures}elseif(($features|ConvertTo-Json -Compress) -cne ($currentFeatures|ConvertTo-Json -Compress)){throw 'feature detection differs'}
        $backends=if($features.avx2_available){@('scalar','avx2')}else{@('scalar')}
        if(!$features.avx2_available){$null=Child $exe @('audit','avx2') 2;$checks.Add("opt$level-unsupported-avx2-refused")}
        foreach($backend in $backends){
            $stdout=Child $exe @('audit',$backend)
            $summary=$stdout|ConvertFrom-Json
            if($summary.status -cne 'numeric_verified' -or $summary.records -ne 9293629 -or $summary.matched -ne $summary.records -or $summary.batches -ne 2323408 -or $summary.small_records -ne 1114112 -or $summary.bucket_records -ne 7077888 -or $summary.upper_records -ne 38400 -or $summary.special_records -ne 729 -or $summary.estimated -le 0 -or $summary.down -le 0 -or $summary.native -le 0 -or $summary.errors -le 0 -or $summary.certificate_fallback -ne 0){throw 'coverage/matched/certificate failure'}
            if($null -eq $golden){$golden=$stdout}elseif($stdout -cne $golden){throw 'backend/optimization summary differs'}
            $summaries.Add([pscustomobject]@{opt=$level;backend=$backend;summary=$summary})
            $checks.Add("opt$level-$backend-streamed-u128-oracle-9293629")
            foreach($count in @(1,2,3)){
                $tail=(Child $exe @('tail',$backend,[string]$count))|ConvertFrom-Json
                if($tail.records -ne $count -or $tail.matched -ne $count -or $tail.batches -ne 1 -or $tail.certificate_fallback -ne 0){throw 'tail coverage'}
                $checks.Add("opt$level-$backend-tail$count")
            }
            $mixed=(Child $exe @('mixed',$backend))|ConvertFrom-Json
            if($mixed.records -ne 32 -or $mixed.matched -ne 32 -or $mixed.batches -ne 8 -or $mixed.errors -ne 8 -or $mixed.certificate_fallback -ne 0){throw 'mixed lane rotation coverage'}
            $checks.Add("opt$level-$backend-mixed-error-and-normal-lanes")
            foreach($vector in $vectors){
                $a=[Numerics.BigInteger]::Parse($vector[0]);$bb=[Numerics.BigInteger]::Parse($vector[1]);$d=[Numerics.BigInteger]::Parse($vector[2]);$product=$a*$bb
                $actual=(Child $exe (@('query',$backend)+$vector))|ConvertFrom-Json
                if($d.IsZero){if($actual.error -cne 'zero denominator'){throw 'BigInteger zero priority'}}
                elseif($product -gt [Numerics.BigInteger][uint64]::MaxValue){if($actual.error -cne 'product overflow'){throw 'BigInteger product priority'}}
                else{if($actual.quotient -cne [Numerics.BigInteger]::Divide($product,$d).ToString()){throw 'BigInteger quotient'}}
            }
            $checks.Add("opt$level-$backend-independent-BigInteger-14")
            $null=Child $exe @('query',$backend,'-1','1','3') 2
            $checks.Add("opt$level-$backend-invalid-u64-refused")
        }
        $null=Child $exe @() 2
        $checks.Add("opt$level-argument-refusal")
    }
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed'}}
    $checks.Add('all-held-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    $temporary=@(Get-ChildItem -LiteralPath $work -Recurse -Force|Where-Object {$_.Name.EndsWith('.tmp') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($temporary.Count -and !$failure){$failure='owned temporary/reparse remains'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'batch_numeric_verified_not_codec_or_timing'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;verifier=$PSCommandPath;verifier_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');runtime_exe=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;checks=$checks;identities=$ids;invocations=$calls;owned_tmp_or_reparse=$temporary.Count;timing_used=$false;features=$features;summaries=$summaries}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;work=$work;retained_bytes=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}

