param()
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work = Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/machine-code'
$tool = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe'
$inputs = @(
    @{ path=$tool; sha256='B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA' },
    @{ path=(Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/candidate.exe'); sha256='A3981BC785F0DC3F5882EED62F49DC12C4911FD045773AEC6646417E3BCD2010' },
    @{ path=(Join-Path $root 'build/khc-bwt-causal-bayes-q32-corrected-lut-inline-20261001/candidate.exe'); sha256='02C7D3D132DFD664CEA7BE643CDB0A5200583D5583AE101C715CC59FEF703083' }
)
$locks = @()
function Assert-NoReparse([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'reparse path' }
        $p = [IO.Path]::GetDirectoryName($p)
    }
}
try {
    foreach ($inputPin in $inputs) {
        Assert-NoReparse $inputPin.path
        $locks += [IO.File]::Open($inputPin.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        if ((Get-FileHash -LiteralPath $inputPin.path).Hash -ne $inputPin.sha256) { throw 'input mismatch' }
    }
    $evidence = @()
    foreach ($inputPin in $inputs[1..2]) {
        $lines = @(& $tool -d --no-show-raw-insn $inputPin.path)
        if ($LASTEXITCODE -ne 0) { throw 'objdump failed' }
        $sites = @()
        for ($i=0;$i -lt $lines.Count;$i++) {
            if ($lines[$i] -match '\sdivsd\s') {
                $sites += @{ instruction=$lines[$i]; context=@($lines[([Math]::Max(0,$i-26))..([Math]::Min($lines.Count-1,$i+30))]) }
            }
        }
        $evidence += @{ path=$inputPin.path; bytes=(Get-Item -LiteralPath $inputPin.path).Length; sha256=$inputPin.sha256; divsd_sites=$sites }
    }
    if ($evidence[0].divsd_sites.Count -ne 4 -or $evidence[1].divsd_sites.Count -ne 7) { throw 'unexpected frozen code shape' }
    $newSites = @($evidence[1].divsd_sites | ForEach-Object { $_.instruction })
    foreach ($address in @('140009642:','1400099b1:','14000a162:','14000a327:')) {
        if (@($newSites | Where-Object { $_.StartsWith($address) }).Count -ne 1) { throw 'inline site missing' }
    }
    foreach ($inputPin in $inputs) { if ((Get-FileHash -LiteralPath $inputPin.path).Hash -ne $inputPin.sha256) { throw 'input changed' } }
    Assert-NoReparse $work
    if (Test-Path -LiteralPath $work) { throw 'output already exists' }
    $null = New-Item -ItemType Directory -Path $work
    $report = @{ status='passed'; timing_used=$false; compression_children=0; pins=$inputs; evidence=$evidence; limitations=@('Addresses and divsd counts are static evidence only.', 'Function names are inferred from source and surrounding operands; no PDB attribution.', 'No dynamic fallback frequency or performance/adoption claim.') }
    $reportPath = Join-Path $work 'report.json'
    $stream = [IO.File]::Open($reportPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=[Text.Encoding]::UTF8.GetBytes(($report|ConvertTo-Json -Depth 12)); $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $loaded = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    if ($loaded.status -ne 'passed' -or $loaded.evidence[1].divsd_sites.Count -ne 7) { throw 'report readback failed' }
    Get-FileHash -LiteralPath $reportPath
} finally { foreach ($held in $locks) { $held.Dispose() } }
