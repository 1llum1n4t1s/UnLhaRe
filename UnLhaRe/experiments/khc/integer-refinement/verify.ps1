#requires -Version 7.2
# 実装前失敗計画: ../Q32_INTEGER_REFINEMENT_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-integer-refinement-20261002'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$failure=$null
$summary=$null
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
$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work
if(Test-Path -LiteralPath $work){throw 'Fresh work directory required; no automatic retry/overwrite'}
$null=New-Item -ItemType Directory -Path $work
try {
    Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Hold (Join-Path $PSScriptRoot '../Q32_INTEGER_REFINEMENT_CONTRACT_20261002.md') 'preimplementation-contract' 'E0105E72E5C8CB337046658DF434119436AFCF70BFC2CFBB99ADE678AD2941B6'
    foreach($name in @('exact_div.rs','audit_cli.rs','verify.ps1')){Hold (Join-Path $PSScriptRoot $name) 'source'}
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard'
    $null=Child $compiler @('--version','--verbose')
    $outputs=@()
    foreach($opt in @('3','2')) {
        $exe=Join-Path $work "audit-opt$opt.exe"
        $null=Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'-o',$exe)
        Hold $exe "opt$opt-executable"
        $outputs+=Child $exe @('audit')
        $null=Child $exe @() 2
        $null=Child $exe @('query','-1','1','3') 2
    }
    if($outputs[0] -cne $outputs[1]){throw 'opt2/opt3 full CLI summary mismatch'}
    $summary=$outputs[0]|ConvertFrom-Json
    if($summary.status -cne 'numeric_verified' -or $summary.records -lt 8000000 -or $summary.certificate_fallback -ne 0 -or $summary.table_bytes -ne 262144){throw 'numeric coverage/status mismatch'}
    $checks.Add('streamed-u128-oracle-all-records-opt2-opt3')
    $checks.Add('full-summary-and-rolling-fingerprint-equal')
    # 第二のoracle: .NET BigInteger。Rust側のoracleやseed更新を再利用しない。
    $q=[uint64]4294967296
    $vectors=@(
        @('0','0','0'),@('18446744073709551615','18446744073709551615','0'),
        @('18446744073709551615','2','3'),@('18446744073709551615','1','4294967295'),
        @('18446744073709551615','1','4294967296'),@('18446744073709551615','1','4294967297'),
        @('4294967295','4294967295','4294967295'),@('4294967295','4294967294','4294967295'),
        @('2147483648','4294967295','2147483649'),@('4294967296','4294967295','4294967295'),
        @('1','1','1'),@('9223372036854775807','1','2147483649'),@('9223372036854775808','1','2147483649'),
        @('18446743725817118960','1','4294967215')
    )
    foreach($vector in $vectors) {
        $a=[Numerics.BigInteger]::Parse($vector[0]);$b=[Numerics.BigInteger]::Parse($vector[1]);$d=[Numerics.BigInteger]::Parse($vector[2]);$product=$a*$b
        $actual=(Child (Join-Path $work 'audit-opt3.exe') (@('query')+$vector))|ConvertFrom-Json
        if($d.IsZero){if($actual.error -cne 'zero denominator'){throw 'BigInteger zero priority'}}
        elseif($product -gt [Numerics.BigInteger][uint64]::MaxValue){if($actual.error -cne 'product overflow'){throw 'BigInteger product priority'}}
        else {if($actual.quotient -cne [Numerics.BigInteger]::Divide($product,$d).ToString()){throw 'BigInteger quotient mismatch'}}
    }
    $checks.Add('independent-BigInteger-14-boundary-queries')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed'}}
    $checks.Add('all-held-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work
    $report=[ordered]@{status=$(if($failure){'failed'}else{'numeric_verified_not_codec_or_timing'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;verifier=$PSCommandPath;runtime=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;numeric=$summary;checks=$checks;identities=$ids;invocations=$calls}
    $json=$report|ConvertTo-Json -Depth 10
    $file=[IO.File]::Open((Join-Path $work 'report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.Encoding]::UTF8.GetBytes($json);$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;numeric=$summary;checks=$checks.Count;calls=$calls.Count;files=$ids.Count;work=$work}|ConvertTo-Json -Depth 5)
}
if($failure){exit 1}
