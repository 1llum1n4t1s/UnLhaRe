param(
    [string]$WorkDirectory = 'C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-q32-machine-code-20261001'
)
$ErrorActionPreference = 'Stop'
# 凍結EXEの読取診断。再コンパイル・圧縮・速度測定を行わない。
$tool = 'C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/lib/rustlib/x86_64-pc-windows-msvc/bin/llvm-objdump.exe'
$binary = 'C:/Users/IMT/dev/UnLhaRe/UnLhaRe/build/khc-bwt-causal-bayes-q32-corrected-lut-20261001/candidate.exe'
$pins = @(
    @{ path = $tool; sha256 = 'B7BC838715378E58182AB04651835347BD83C23A9EB40904AE8BA88F095C74CA' },
    @{ path = $binary; sha256 = 'A3981BC785F0DC3F5882EED62F49DC12C4911FD045773AEC6646417E3BCD2010' }
)
$streams = @()
try {
    foreach ($pin in $pins) {
        $item = Get-Item -LiteralPath $pin.path
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse input' }
        $streams += [IO.File]::Open($pin.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ((Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash -ne $pin.sha256) { throw 'input identity mismatch' }
    }
    $lines = @(& $tool -d --no-show-raw-insn $binary)
    if ($LASTEXITCODE -ne 0) { throw 'objdump failed' }
    $start = @($lines | Select-String '^14000af30:')
    $end = @($lines | Select-String '^14000b120:')
    # 本EXE固有の番地。別候補へ無検査で適用しない。
    $body = @($lines | Where-Object { $_ -match '^([0-9a-f]+):' -and [Convert]::ToUInt64($Matches[1],16) -ge 0x14000af30 -and [Convert]::ToUInt64($Matches[1],16) -lt 0x14000b120 })
    if ($start.Count -ne 1 -or $end.Count -ne 1 -or $body.Count -lt 80) { throw 'expected body missing' }
    $calls = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'callq\s+0x14000af30\b') {
            $calls += @{ instruction = $lines[$i]; context = @($lines[([Math]::Max(0,$i-12))..([Math]::Min($lines.Count-1,$i+8))]) }
        }
    }
    if ($calls.Count -ne 4) { throw 'expected static call sites changed' }
    $counts = [ordered]@{}
    foreach ($op in @('divsd','cvttsd2si','mulq','divq','divl','callq')) {
        $counts[$op] = @($body | Where-Object { $_ -match "\s$op\s" }).Count
    }
    if ($counts.divsd -ne 1 -or $counts.cvttsd2si -ne 2 -or $counts.divq -ne 1 -or $counts.divl -ne 1) { throw 'instruction assertions failed' }
    foreach ($pin in $pins) {
        if ((Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash -ne $pin.sha256) { throw 'input changed' }
    }
    $root = [IO.Path]::GetFullPath($WorkDirectory)
    $allowed = 'C:\Users\IMT\dev\UnLhaRe\UnLhaRe\build\'
    if (-not $root.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'output outside build' }
    if (Test-Path -LiteralPath $root) { throw 'output already exists' }
    $parent = Get-Item -LiteralPath ([IO.Path]::GetDirectoryName($root))
    while ($null -ne $parent) {
        if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'reparse output parent' }
        $parent = $parent.Parent
    }
    $null = New-Item -ItemType Directory -Path $root
    $report = [ordered]@{
        status = 'passed'; diagnostic_only = $true; timing = $false; compression_children = 0
        symbol_resolution = 'none; address attribution is source/control-flow inference, not PDB confirmation'
        pins = $pins; static_call_sites = $calls; body = $body; static_instruction_counts = $counts
        limitations = @('Static instructions are not dynamic execution counts or a profile.', 'Fallback branches do not prove fallback frequency.', 'No speed/adoption or four-platform conclusion.')
    }
    $output = Join-Path $root 'report.json'
    $outStream = [IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($report | ConvertTo-Json -Depth 12))
        $outStream.Write($bytes,0,$bytes.Length)
        $outStream.Flush($true)
    } finally { $outStream.Dispose() }
    Get-FileHash -LiteralPath $output -Algorithm SHA256
    $counts
} finally { foreach ($stream in $streams) { $stream.Dispose() } }
