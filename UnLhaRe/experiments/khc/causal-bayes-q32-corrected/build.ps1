#requires -Version 7.2
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-20261001'
$compiler = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$pins = @{
    'build/khc-current-source-native-solid-20260923-group/all.group' = '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
    'experiments/khc/causal-bayes-q32/codec.rs' = 'A14F882A4B012A3628FC7B4C9AC1656668797469E81DFA76345BED1903B5C91E'
    'experiments/khc/causal-bayes-q32/cts_model.rs' = '52CD54524DD89565DBEEEA2B1F3B5E89668DD8429453692663D3EDAA6D488D88'
    'experiments/khc/causal-bayes-q32/verify.ps1' = '1E71EFE27CB296F993E8CCD72E68C021132FD63E7392055E88D9F7EE19C79BE4'
    'experiments/khc/corrected-quotient/exact_div.rs' = '52595705A96F939B63D0DDB88871F3E7F78419973B0891E7A79E42579EA81D3A'
    'experiments/khc/causal-bayes-sais/bwt.rs' = '810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'
    'experiments/khc/causal-bayes-packed/bayes_model.rs' = '65658333E8D3EB5EBD71B05AEBCD653B8E3506580203439C2E8912DFE3DB0EB9'
    'experiments/khc/rejected-binary-mix/packed_alphabet.rs' = '4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'
    'experiments/khc/range.rs' = '1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
    'experiments/khc/CAUSAL_BAYES_Q32_CONTRACT_20260930.md' = 'FF48085A6C534BDC1777E4BF6542E285800811753192086362405F3A04CD71DB'
    'experiments/khc/Q32_CORRECTED_QUOTIENT_CONTRACT_20261001.md' = 'EB992EDA250B115B4599BD7E13284616678BE9C7AB58BDD65447CEBACE193DA6'
    'experiments/khc/Q32_CORRECTED_CODEC_CONTRACT_20261001.md' = '856D9C58E5688A1468BF1DDF8D98B1A803EB6B5A7CBAE46380E43FF45E1B7FE4'
    'experiments/khc/CORPUS_MANIFEST.json' = '77F2A728B33AE54655B67DCC3BCAA85D0912B98BA0F44343C64F903707BD5036'
    'build/khc-corrected-quotient-20261001/report.json' = '803072EA44DB97BFFDDAC78913E975B827B9334870F82A0EB0E19051005626D6'
    'build/khc-bwt-causal-bayes-q32-20260930/candidate.exe' = 'FBF35FC6600FB62506658EC63A734F69857489AE2CE53257CD0907D00F6DAD5F'
    'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/report.json' = '2F7F612F63570CD58976F16F42D4DD3255DAE0DD242B6891B5CB3946463C006C'
    'build/khc-bwt-causal-bayes-q32-20260930/full-e2e-locked/fixed.frame' = '7584AF15ED4A70F6AD16E278F29DBB1C4D63EACD1DD58D5164198D03D3B5D95C'
    'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe' = 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
}

$locks = [Collections.Generic.List[IO.FileStream]]::new()
$ids = [Collections.Generic.List[object]]::new()
$calls = [Collections.Generic.List[object]]::new()
function Assert-NoReparse([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if ((Test-Path -LiteralPath $current) -and (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw "Reparse point rejected: $current" }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}
function Lock-Source([string]$Path, [string]$Expected = '') {
    Assert-NoReparse $Path
    $locks.Add([IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $id = [pscustomobject]@{path=[IO.Path]::GetFullPath($Path); before_bytes=(Get-Item -LiteralPath $Path).Length; before_sha256=(Get-FileHash -LiteralPath $Path).Hash; after_bytes=$null; after_sha256=$null}
    $ids.Add($id)
    if ($Expected -and $id.before_sha256 -cne $Expected) { throw "Pinned source mismatch: $Path" }
}
function Write-New([string]$Path, [string]$Value) {
    Assert-NoReparse $Path
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Value)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
Assert-NoReparse $work
if (Test-Path -LiteralPath $work) { throw 'Refusing existing build root.' }
$null = New-Item -ItemType Directory -Path $work
$report = [ordered]@{status='failed'; error=$null; started_utc=[DateTime]::UtcNow.ToString('o'); compiler=$compiler; compiler_version=$null; provenance=$ids; compile_calls=$calls; timing_used=$false; outputs=@()}
$failure = $null
try {
    foreach ($p in $pins.Keys) {
        $path = if ([IO.Path]::IsPathRooted($p)) {$p} else {Join-Path $root $p}
        Lock-Source $path $pins[$p]
    }
    foreach ($name in @('codec.rs','cts_model.rs','verify.ps1','build.ps1')) { Lock-Source (Join-Path $PSScriptRoot $name) }
    $report.compiler_version = @(& $compiler --version)
    foreach ($configuration in @(@('candidate',3),@('reference',2))) {
        $out = Join-Path $work "$($configuration[0]).exe"
        $argv = @((Join-Path $PSScriptRoot 'codec.rs'),'--edition','2024','-C','panic=abort','-C',"opt-level=$($configuration[1])",'-o',$out)
        $row = [ordered]@{program=$compiler;argv=$argv;exit=$null;stdout='';stderr='';timeout=$false}
        $calls.Add($row)
        $info = [Diagnostics.ProcessStartInfo]::new($compiler)
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true; $info.WorkingDirectory=$root
        foreach($arg in $argv){$info.ArgumentList.Add($arg)}
        $process=[Diagnostics.Process]::new(); $process.StartInfo=$info; $started=$false
        try {
            $started=$process.Start(); if(-not $started){throw 'Compiler start failed.'}
            $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(120000)){$row.timeout=$true;throw 'Compiler timeout.'}
            $row.stdout=$stdout.GetAwaiter().GetResult();$row.stderr=$stderr.GetAwaiter().GetResult();$row.exit=$process.ExitCode
            if($row.exit -ne 0){throw "Compile failed: $($row.stderr)"}
        } finally {
            if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()}
            $process.Dispose()
        }
        Lock-Source $out
        $report.outputs += [pscustomobject]@{path=$out;bytes=(Get-Item -LiteralPath $out).Length;sha256=(Get-FileHash -LiteralPath $out).Hash}
    }
    foreach($id in $ids){
        $id.after_bytes=(Get-Item -LiteralPath $id.path).Length;$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash
        if($id.after_bytes -ne $id.before_bytes -or $id.after_sha256 -cne $id.before_sha256){throw "Build provenance changed: $($id.path)"}
    }
    $report.status='built_not_timed'
} catch {$failure=$_;$report.error=$_.Exception.ToString()}
finally {
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'build-report.json') ($report | ConvertTo-Json -Depth 12)
    foreach($held in $locks){$held.Dispose()}
}
if($null -ne $failure){throw $failure}
& (Join-Path $PSScriptRoot 'verify.ps1') -BinaryPath (Join-Path $work 'candidate.exe') -ReferenceBinary (Join-Path $work 'reference.exe') -GroupPath (Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group') -WorkDirectory (Join-Path $work 'full-e2e')

