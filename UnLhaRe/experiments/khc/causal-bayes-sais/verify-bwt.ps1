#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$AuditBinary,
    [Parameter(Mandatory)][string]$ControlBinary,
    [Parameter(Mandatory)][string]$AuditOpt2,
    [Parameter(Mandatory)][string]$ControlAudit,
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
    $stdout=$null; $stderr=$null
    $row=[pscustomobject]@{program=$Program;argv=$Argv;exit_code=$null;expected_exit=$ExpectedExit;stdout='';stderr='';timed_out=$false;error=$null;started_utc=[DateTime]::UtcNow.ToString('o')}
    try {
        $started=$process.Start(); if (-not $started) { throw 'Child start failed.' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $row.timed_out=$true; throw 'Child timeout.' }
        $row.exit_code=$process.ExitCode; $row.stdout=$stdout.GetAwaiter().GetResult(); $row.stderr=$stderr.GetAwaiter().GetResult()
        if ($row.exit_code -ne $ExpectedExit -or ($ExpectedExit -eq 0 -and $row.stderr)) { throw 'Unexpected child result.' }
        if ($ExpectedExit -ne 0 -and $row.stdout) { throw 'Failure stdout must be empty.' }
        $row
    } catch { $row.error=$_.Exception.Message; throw }
    finally {
        if ($started) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            if($null -ne $stdout){try{$row.stdout=$stdout.GetAwaiter().GetResult()}catch{}}
            if($null -ne $stderr){try{$row.stderr=$stderr.GetAwaiter().GetResult()}catch{}}
            try{$row.exit_code=$process.ExitCode}catch{}
        }
        $calls.Add($row); $process.Dispose()
    }
}
if (-not $work.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)) { throw 'Fresh work below build required.' }
No-Reparse $work
$null=New-Item -ItemType Directory -Path $work
$failure=$null
try {
    $binary=Lock $BinaryPath; $audit=Lock $AuditBinary; $control=Lock $ControlBinary; $opt2=Lock $AuditOpt2; $controlAudit=Lock $ControlAudit
    if((Identity $controlAudit).sha256 -cne '907A2ED8DEB5854003B0D986A6C0182C0074F3E9168666FC2FFB34695996EF81'){throw 'Frozen prefix BWT audit identity changed.'}
    foreach ($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'codec.rs'),(Join-Path $PSScriptRoot 'bwt.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_SAIS_CONTRACT_20260930.md'))) { $null=Lock $path }
    foreach($path in @('../causal-bayes-exact-div/cts_model.rs','../causal-bayes-exact-div/exact_div.rs','../causal-bayes-packed/bayes_model.rs','../range.rs','../rejected-binary-mix/packed_alphabet.rs','../causal-bayes-fast-bwt/bwt.rs','C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe')){$absolute=if([IO.Path]::IsPathRooted($path)){$path}else{Join-Path $PSScriptRoot $path};$null=Lock $absolute}
    # audit CLIと構造を共有しない比較sort。非循環suffixを直接byte比較する。
    Add-Type -TypeDefinition @'
using System;
public static class IndependentSuffixBwt {
    public static byte[] Alternating(int length) {
        byte[] bytes=new byte[length];for(int i=0;i<length;i++)bytes[i]=(byte)(i&1);return bytes;
    }
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
    # 等しいLMS名・異なる長さ・再帰縮約を誘発する小alphabet。モデル設定は変えない。
    for($mask=0;$mask -lt 64;$mask++){
        $data=[byte[]]::new(6)
        for($i=0;$i -lt 6;$i++){$data[$i]=[byte](($mask -shr $i)-band 1)}
        $fixtures.Add(@("binary-six-$mask",$data))
    }
    foreach($length in @(17,33,65,129,257,513,1025)){
        foreach($alphabet in @(2,3,4)){
            $data=[byte[]]::new($length)
            for($i=0;$i -lt $length;$i++){$data[$i]=[byte]$random.Next($alphabet)}
            $fixtures.Add(@("small-alphabet-$alphabet-$length",$data))
        }
    }
    foreach ($fixture in $fixtures) {
        $name=$fixture[0]; [byte[]]$bytes=$fixture[1]; $input=Join-Path $work "$name.input"; New-Bytes $input $bytes
        $output=Join-Path $work "$name.bwt"; $run=Call $audit @($input,$output) 0; $owned.Add($output)
        $json=$run.stdout | ConvertFrom-Json; $expected=[IndependentSuffixBwt]::Compute($bytes); $actual=[IO.File]::ReadAllBytes($output)
        if ($json.input_bytes -ne $bytes.Length -or $json.symbols -ne $bytes.Length+1 -or $json.primary -ne [BitConverter]::ToUInt32($expected,0) -or $actual.Length -ne $expected.Length -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actual)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($expected))) { throw "Naive suffix oracle mismatch: $name" }
        $oracle=Join-Path $work "$name.oracle"; New-Bytes $oracle $expected
        $opt2Output=Join-Path $work "$name.opt2.bwt"; $opt2Run=Call $opt2 @($input,$opt2Output) 0; $owned.Add($opt2Output)
        $opt2Json=$opt2Run.stdout|ConvertFrom-Json
        if((Identity $opt2Output).sha256 -cne (Identity $oracle).sha256 -or $opt2Json.primary -ne $json.primary -or $opt2Json.symbols -ne $json.symbols -or $opt2Json.input_bytes -ne $json.input_bytes){throw 'Opt2 audit differs.'}
        $checks.Add([pscustomobject]@{ name="naive-$name"; passed=$true; input=(Identity $input); oracle=(Identity $oracle); bwt=(Identity $output); opt2_bwt=(Identity $opt2Output); primary=$json.primary })
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
    $periodMax=Join-Path $work 'max-period.input'; $periodBytes=[IndependentSuffixBwt]::Alternating(8388608)
    New-Bytes $periodMax $periodBytes
    foreach($name in @('max-repeat','max-period')){
        $input=Join-Path $work "$name.input"; $outputs=@()
        foreach($pair in @(@($audit,'new'),@($opt2,'opt2'),@($controlAudit,'prefix'))){
            $output=Join-Path $work "$name.$($pair[1]).bwt"
            $run=Call $pair[0] @($input,$output) 0; $owned.Add($output); $id=Identity $output; $outputs+=,$id
            $json=$run.stdout|ConvertFrom-Json
            if($json.input_bytes -ne 8388608 -or $json.symbols -ne 8388609 -or $id.bytes -ne 16777226){throw 'Maximum BWT syntax mismatch.'}
        }
        if($outputs[0].sha256 -cne $outputs[1].sha256 -or $outputs[0].sha256 -cne $outputs[2].sha256){throw 'Maximum BWT differs from prefix oracle.'}
        $checks.Add([pscustomobject]@{name="maximum-bwt-$name";passed=$true;input=(Identity $input);outputs=$outputs})
    }
    $tooLarge=Join-Path $work 'oversize.input'; $tooLargeData=[byte[]]::new(8388609); New-Bytes $tooLarge $tooLargeData
    foreach ($pair in @(@($audit,'audit'),@($opt2,'audit-opt2'),@($binary,'new'),@($control,'old'))) {
        $absent=Join-Path $work "$($pair[1]).rejected-output"; $argv=if($pair[1].StartsWith('audit',[StringComparison]::Ordinal)){ @($tooLarge,$absent) }else{ @('encode',$tooLarge,$absent) }
        $run=Call $pair[0] $argv 1; if(Test-Path -LiteralPath $absent){ throw 'Rejected input was published.' }
        if ($run.stderr -notmatch 'limit|bounds|oversize') { throw 'Wrong oversize rejection reason.' }
        $checks.Add([pscustomobject]@{ name="oversize-$($pair[1])"; passed=$true; reason=$run.stderr })
    }
    $existing=Join-Path $work 'audit-existing-output'; New-Bytes $existing ([byte[]]@(31,41,59)); $before=Identity $existing
    $null=Call $audit @((Join-Path $work 'banana.input'),$existing) 1
    if ((Identity $existing).sha256 -cne $before.sha256) { throw 'Audit clobbered existing output.' }
    $checks.Add([pscustomobject]@{ name='audit-no-clobber'; passed=$true; existing=$before })
    $directoryOutput=Join-Path $work 'directory.output'; $null=Call $audit @($work,$directoryOutput) 1
    if(Test-Path -LiteralPath $directoryOutput){throw 'Directory input published.'}
    $checks.Add([pscustomobject]@{name='audit-directory-input';passed=$true})
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
