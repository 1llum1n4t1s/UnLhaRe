#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$AuditBinary,
    [Parameter(Mandatory)][string]$ControlBinary,
    [Parameter(Mandatory)][string]$WorkDirectory
)
# 独立suffix比較oracle対実CLI、新旧全frame同値、入力境界/no-clobber。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build')) + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath($WorkDirectory)
$calls = [Collections.Generic.List[object]]::new()
$checks = [Collections.Generic.List[object]]::new()
$ids = [Collections.Generic.List[object]]::new()
$locks = [Collections.Generic.List[IO.FileStream]]::new()
$owned = [Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path) {
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse rejected.' }
        $item = [IO.Path]::GetDirectoryName($item)
    }
}
function Identity([string]$Path) {
    No-Reparse $Path
    $item = Get-Item -LiteralPath $Path
    if ($item -isnot [IO.FileInfo]) { throw 'Regular file required.' }
    [pscustomobject]@{ path=$item.FullName; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $item.FullName).Hash }
}
function Lock([string]$Path) {
    $id = Identity $Path
    $locks.Add([IO.File]::Open($id.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $ids.Add([pscustomobject]@{ path=$id.path; before_sha256=$id.sha256; after_sha256=$null })
    $id.path
}
function New-Bytes([string]$Path,[byte[]]$Bytes) {
    No-Reparse $Path
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
    $owned.Add($Path)
}
function Call([string]$Program,[string[]]$Argv,[int]$ExpectedExit) {
    $info = [Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.WorkingDirectory=$work
    foreach ($a in $Argv) { $info.ArgumentList.Add($a) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info; $started=$false
    try {
        $started=$process.Start(); if (-not $started) { throw 'Child start failed.' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { throw 'Child timeout.' }
        $row=[pscustomobject]@{ program=$Program; argv=$Argv; exit_code=$process.ExitCode; expected_exit=$ExpectedExit; stdout=$stdout.GetAwaiter().GetResult(); stderr=$stderr.GetAwaiter().GetResult() }
        $calls.Add($row)
        if ($row.exit_code -ne $ExpectedExit -or ($ExpectedExit -eq 0 -and $row.stderr)) { throw 'Unexpected child result.' }
        if ($ExpectedExit -ne 0 -and $row.stdout) { throw 'Failure stdout must be empty.' }
        $row
    } finally { if ($started -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }; $process.Dispose() }
}
if (-not $work.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)) { throw 'Fresh work below build required.' }
No-Reparse $work
$null=New-Item -ItemType Directory -Path $work
$failure=$null
try {
    $binary=Lock $BinaryPath; $audit=Lock $AuditBinary; $control=Lock $ControlBinary
    foreach ($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'codec.rs'),(Join-Path $PSScriptRoot 'bwt.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_FAST_BWT_CONTRACT_20260930.md'))) { $null=Lock $path }
    # audit CLIと構造を共有しない比較sort。非循環suffixを直接byte比較する。
    Add-Type -TypeDefinition @'
using System;
public static class IndependentSuffixBwt {
    public static byte[] Compute(byte[] input) {
        int n = input.Length + 1;
        ushort[] symbols = new ushort[n];
        for (int i=0;i<input.Length;i++) symbols[i]=(ushort)(input[i]+1);
        int[] sa = new int[n]; for (int i=0;i<n;i++) sa[i]=i;
        Array.Sort(sa, (a,b) => {
            while (a<n && b<n) { int c=symbols[a].CompareTo(symbols[b]); if(c!=0) return c; a++; b++; }
            return (n-a).CompareTo(n-b);
        });
        byte[] result = new byte[8+2*n]; int primary=Array.IndexOf(sa,0);
        BitConverter.GetBytes((uint)primary).CopyTo(result,0);
        BitConverter.GetBytes((uint)n).CopyTo(result,4);
        for(int i=0;i<n;i++) BitConverter.GetBytes(symbols[sa[i]==0?n-1:sa[i]-1]).CopyTo(result,8+2*i);
        return result;
    }
}
'@
    $fixtures = [Collections.Generic.List[object]]::new()
    $fixtures.Add(@('empty',[byte[]]::new(0))); $fixtures.Add(@('zero',[byte[]]@(0))); $fixtures.Add(@('high',[byte[]]@(255)))
    $fixtures.Add(@('initial-sort-counterexample',[byte[]]@(0,1,0))); $fixtures.Add(@('banana',[Text.Encoding]::ASCII.GetBytes('banana')))
    $fixtures.Add(@('all-byte',[byte[]](0..255)))
    foreach ($length in @(2,3,4,7,8,9,15,16,17,31,32,33,63,64,65,127,128,129,255,256,257,511,512,513,1023,1024,1025)) {
        $period=[byte[]]::new($length); for($i=0;$i -lt $length;$i++) { $period[$i]=[byte]((0,255,0,7,1)[$i%5]) }
        $fixtures.Add(@("period-$length",$period))
    }
    $random=[Random]::new(20260930)
    foreach ($length in @(2,3,7,16,31,64,127,257,513,1025)) { $data=[byte[]]::new($length); $random.NextBytes($data); $fixtures.Add(@("mixed-$length",$data)) }
    $same=[byte[]]::new(1025); [Array]::Fill[byte]($same,42); $fixtures.Add(@('equal-1025',$same))
    foreach ($fixture in $fixtures) {
        $name=$fixture[0]; [byte[]]$bytes=$fixture[1]; $input=Join-Path $work "$name.input"; New-Bytes $input $bytes
        $output=Join-Path $work "$name.bwt"; $run=Call $audit @($input,$output) 0; $owned.Add($output)
        $json=$run.stdout | ConvertFrom-Json; $expected=[IndependentSuffixBwt]::Compute($bytes); $actual=[IO.File]::ReadAllBytes($output)
        if ($json.input_bytes -ne $bytes.Length -or $json.symbols -ne $bytes.Length+1 -or $json.primary -ne [BitConverter]::ToUInt32($expected,0) -or $actual.Length -ne $expected.Length -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected))) { throw "Naive suffix oracle mismatch: $name" }
        $checks.Add([pscustomobject]@{ name="naive-$name"; passed=$true; input=(Identity $input); bwt=(Identity $output); primary=$json.primary })
    }
    # 境界は旧候補との全frame一致。naive比較を巨大入力へ拡張しない。
    $maxPath=Join-Path $work 'max-repeat.input'; $maxBytes=[byte[]]::new(8388608); [Array]::Fill[byte]($maxBytes,42); New-Bytes $maxPath $maxBytes
    foreach ($name in @('empty','initial-sort-counterexample','banana','all-byte','period-1025','mixed-1025','max-repeat')) {
        $input=Join-Path $work "$name.input"; $frame=Join-Path $work "$name.new.frame"; $oldFrame=Join-Path $work "$name.old.frame"
        $null=Call $binary @('encode',$input,$frame) 0; $owned.Add($frame)
        $null=Call $control @('encode',$input,$oldFrame) 0; $owned.Add($oldFrame)
        if ((Get-FileHash -LiteralPath $frame).Hash -cne (Get-FileHash -LiteralPath $oldFrame).Hash) { throw "Full frame identity mismatch: $name" }
        foreach ($pair in @(@($binary,'new'),@($control,'old'))) {
            $restore=Join-Path $work "$name.$($pair[1]).restored"; $null=Call $pair[0] @('decode',$frame,$restore) 0; $owned.Add($restore)
            if ((Get-FileHash -LiteralPath $restore).Hash -cne (Get-FileHash -LiteralPath $input).Hash) { throw 'Full restore mismatch.' }
        }
        $checks.Add([pscustomobject]@{ name="full-frame-$name"; passed=$true; frame=(Identity $frame); control_frame=(Identity $oldFrame) })
    }
    $tooLarge=Join-Path $work 'oversize.input'; $tooLargeData=[byte[]]::new(8388609); New-Bytes $tooLarge $tooLargeData
    foreach ($pair in @(@($audit,'audit'),@($binary,'new'),@($control,'old'))) {
        $absent=Join-Path $work "$($pair[1]).rejected-output"; $argv=if($pair[1] -ceq 'audit'){ @($tooLarge,$absent) }else{ @('encode',$tooLarge,$absent) }
        $run=Call $pair[0] $argv 1; if(Test-Path -LiteralPath $absent){ throw 'Rejected input was published.' }
        if ($run.stderr -notmatch 'limit|bounds|oversize') { throw 'Wrong oversize rejection reason.' }
        $checks.Add([pscustomobject]@{ name="oversize-$($pair[1])"; passed=$true; reason=$run.stderr })
    }
    $existing=Join-Path $work 'audit-existing-output'; New-Bytes $existing ([byte[]]@(31,41,59)); $before=Identity $existing
    $null=Call $audit @((Join-Path $work 'banana.input'),$existing) 1
    if ((Identity $existing).sha256 -cne $before.sha256) { throw 'Audit clobbered existing output.' }
    $checks.Add([pscustomobject]@{ name='audit-no-clobber'; passed=$true; existing=$before })
    foreach($argv in @([string[]]@(),[string[]]@((Join-Path $work 'empty.input')),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')))) {
        $run=Call $audit $argv 1
        if (Test-Path -LiteralPath (Join-Path $work 'missing.output')) { throw 'Missing input published output.' }
        $checks.Add([pscustomobject]@{ name='audit-invalid-invocation'; passed=$true; argv=$argv; reason=$run.stderr })
    }
} catch { $failure=$_ }
finally {
    foreach($id in $ids) { $id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash; if($id.after_sha256 -cne $id.before_sha256){ $failure='Input/source changed.' } }
    foreach($held in $locks){ $held.Dispose() }
    $record=[ordered]@{ status=$(if($null -eq $failure){'verified'}else{'failed'}); error=$(if($null -eq $failure){$null}else{[string]$failure}); checks=$checks.ToArray(); invocations=$calls.ToArray(); identities=$ids.ToArray(); owned_paths=$owned.ToArray(); timing_used_for_adoption=$false; completed_utc=[DateTime]::UtcNow.ToString('o') }
    New-Bytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 15)))
}
if($null -ne $failure){ throw $failure }
"BWT CLI E2E PASS: $($checks.Count) checks / $($calls.Count) invocations."
