#requires -Version 7.2
# 実装前失敗計画: ../SIMD_LAYOUT_CONTRACT_20261002.md
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-simd-layout-20261002'
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

function Write-New([string]$Path,[byte[]]$Bytes) {
    if(!$Path.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'write outside owned root'}
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}

$budgetBefore=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 2
if(Test-Path -LiteralPath $work){throw 'Fresh root required; no overwrite or automatic retry'}
$null=New-Item -ItemType Directory -Path $work
try {
    Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    Hold (Join-Path $PSScriptRoot '../SIMD_LAYOUT_CONTRACT_20261002.md') 'preimplementation-contract' '05A2A23F250F3601B18C7F2FE1CFA5D8D764395AABC23B83325ED7366EDCC34A'
    Hold (Join-Path $PSScriptRoot '../simd-quotient/exact_div.rs') 'frozen-helper' '9A135D48AD9C80B02B5BF916301EBBA0F95ED3EA578B6E0B0563A4E6E38645C7'
    Hold (Join-Path $PSScriptRoot '../disk-budget.ps1') 'budget-guard' 'F0B0260F4F7F21C851F5A2D62E4232996BBF259D6782A3F9A49689D4B03FFCC7'
    Hold (Join-Path $PSScriptRoot 'probe.rs') 'probe'
    Hold $PSCommandPath 'verifier'
    $null=Child $compiler @('--version','--verbose')
    $assembly=Join-Path $work 'probe.s'
    $null=Child $compiler @((Join-Path $PSScriptRoot 'probe.rs'),'--edition=2024','--crate-type=lib','--emit=asm','-C','opt-level=3','-C','overflow-checks=yes','-C','panic=abort','-o',$assembly)
    Hold $assembly 'generated-assembly'
    $checks.Add('frozen-helper-compiled-to-assembly-without-warning')
    $asm=[IO.File]::ReadAllText($assembly)
    if($asm -notmatch '(?m)^batch_probe:' -or $asm -notmatch '\bvdivpd\b'){throw 'exported kernel or vector divide absent'}
    $summary=[ordered]@{
        evidence_kind='standalone_probe_static_not_full_codec_or_timing'
        assembly_bytes=(Get-Item -LiteralPath $assembly).Length
        vector_divide_static_occurrences=([regex]::Matches($asm,'\bvdivpd\b')).Count
        scalar_divide_static_occurrences=([regex]::Matches($asm,'\bdivsd\b')).Count
        call_static_occurrences=([regex]::Matches($asm,'(?m)^\s*callq\s')).Count
        stack_allocations=@([regex]::Matches($asm,'(?m)^\s*(?:subq\s+\$[0-9]+,\s*%rsp|\.seh_stackalloc\s+[0-9]+).*')|ForEach-Object {$_.Value.Trim()})
        exported_size_getters=@('ratio_bytes','four_ratio_bytes','four_cts_result_bytes','four_cts_input_bytes','four_plain_posterior_bytes')
    }
    $checks.Add('exported-wrapper-and-AVX-vector-divide-present')
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.after_sha256 -cne $id.before_sha256 -or (Get-Item -LiteralPath $id.path).Length -ne $id.bytes){throw 'retained identity changed'}}
    $checks.Add('all-held-identities-unchanged')
} catch {$failure=$_.Exception.Message}
finally {
    foreach($stream in $locks){$stream.Dispose()}
    $budgetAfter=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 2
    $temporary=@(Get-ChildItem -LiteralPath $work -Force -Recurse|Where-Object {$_.Name.EndsWith('.tmp') -or $_.Extension -in @('.exe','.pdb','.rlib','.rmeta') -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)})
    if($temporary.Count -and !$failure){$failure='unexpected executable/library/temp/reparse artifact'}
    $report=[ordered]@{status=$(if($failure){'failed'}else{'static_layout_probe_compiled_not_timed'});failure=$failure;began_utc=$began;ended_utc=[DateTime]::UtcNow.ToString('o');cwd=$root;verifier=$PSCommandPath;runtime_exe=(Get-Process -Id $PID).Path;runtime=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString;budget_before=$budgetBefore;budget_after=$budgetAfter;checks=$checks;identities=$ids;invocations=$calls;summary=$summary;unexpected_artifacts=$temporary.Count;timing_used=$false}
    Write-New (Join-Path $work 'report.json') ([Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 10)))
    $null=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 2
    [pscustomobject]@{status=$report.status;failure=$failure;checks=$checks.Count;calls=$calls.Count;identities=$ids.Count;summary=$summary}|ConvertTo-Json -Depth 5
}
if($failure){exit 1}
