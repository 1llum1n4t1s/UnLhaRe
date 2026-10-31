#requires -Version 7.2
# 実装前失敗計画: ../BAYES_DOMINANT_Q15_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-bayes-dominant-q15-20261002-numeric'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[string]]::new()
$failure=$null
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
    Hold (Join-Path $PSScriptRoot '../BAYES_DOMINANT_Q15_CONTRACT_20261002.md') 'preimplementation-contract' '9BC66305D8C01DEFD56CF33A643BA0963F49CB351EB3DCE84C4ED3F3E56EEFE5'
    Hold (Join-Path $PSScriptRoot '../causal-expert-scheduling/bayes_model.rs') 'frozen-old-bayes' 'CABE510C4566B63C7AAB7F5EA0507BC3DA1EB2FA0E146E2FE568C134E3CFB9B8'
    foreach($name in @('bayes_old.rs','bayes_model.rs','audit_cli.rs','correspondence.json','verify-numeric.ps1')){Hold (Join-Path $PSScriptRoot $name) 'audit-source'}
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    $correspondence=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json
    foreach($source in $correspondence) {
        Hold (Join-Path $root $source.original) 'original-source'
        Hold (Join-Path $PSScriptRoot $source.name) 'derived-source'
        $expected=[IO.File]::ReadAllText((Join-Path $root $source.original)).Replace("`r`n","`n")
        foreach($change in $source.changes){
            if($change.PSObject.Properties.Name -contains 'append'){$expected+=$change.append}
            else{if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw 'source replacement occurrence'};$expected=$expected.Replace([string]$change.old,[string]$change.new)}
        }
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $source.name)).Replace("`r`n","`n") -cne $expected){throw "full source correspondence: $($source.name)"}
    }
    $checks.Add('full-source-correspondence-four-files')
    $null=Child $compiler @('--version','--verbose')
    $golden=$null
    foreach($level in @(2,3)) {
        $exe=Join-Path $work "audit-opt$level.exe"
        $null=Child $compiler @((Join-Path $PSScriptRoot 'audit_cli.rs'),'--edition=2024','--cfg','khc_bayes_dominant_audit','-C','panic=abort','-C',"opt-level=$level",'-C','overflow-checks=yes','-o',$exe)
        Hold $exe "audit-opt$level"
        $stdout=Child $exe @()
        $summary=$stdout|ConvertFrom-Json
        if($summary.records -ne 5920979 -or $summary.errors -le 0 -or $summary.equal_component -le 0 -or $summary.primary_dominant -le 0 -or $summary.cts_dominant -le 0){throw 'summary coverage/count failure'}
        if($null -eq $golden){$golden=$stdout}elseif($stdout -cne $golden){throw 'optimization summary changed'}
        $checks.Add("opt$level-streamed-actual-old-predict-equality")
        $null=Child $exe @('unexpected') 2
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
    $report=[ordered]@{status=$(if($failure){'failed'}else{'numeric_native_equivalence_passed_not_timed'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;verifier=$PSCommandPath;verifier_last_write_utc=(Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc.ToString('o');runtime_exe=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;cpu=@(Get-CimInstance Win32_Processor|Select-Object Name,NumberOfCores,NumberOfLogicalProcessors);budget_before=$budgetBefore;budget_after=$budgetAfter;checks=$checks;identities=$ids;invocations=$calls;owned_tmp_or_reparse=$temporary.Count;timing_used=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
    Write-Output ([pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;work=$work;retained_bytes=$budgetAfter.used_bytes}|ConvertTo-Json)
}
if($failure){exit 1}

