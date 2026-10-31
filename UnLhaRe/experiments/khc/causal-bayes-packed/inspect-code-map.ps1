#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$OriginalBinary,
    [Parameter(Mandatory)][string]$MappingBinary,
    [Parameter(Mandatory)][string]$ReportPath
)
# 実行sectionが違えば旧ETWのRVA移植を許可しない。元pairの変更は行わない。
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$build = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build')) + [IO.Path]::DirectorySeparatorChar
$output = [IO.Path]::GetFullPath($ReportPath)
if (-not $output.StartsWith($build, [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $output)) { throw 'Fresh report below build required.' }
function No-Reparse([string]$Path) {
    $item = [IO.Path]::GetFullPath($Path)
    while ($item) {
        if ((Test-Path -LiteralPath $item) -and ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Reparse rejected.' }
        $item = [IO.Path]::GetDirectoryName($item)
    }
}
function Inspect([string]$Path) {
    No-Reparse $Path
    $full = [IO.Path]::GetFullPath($Path)
    $stream = [IO.File]::Open($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $hash = (Get-FileHash -LiteralPath $full).Hash
        $sections = @(foreach ($section in $pe.PEHeaders.SectionHeaders) {
            if ([long]$section.SectionCharacteristics -band 0x20000000) {
                [byte[]]$raw = $pe.GetEntireImage().GetContent($section.PointerToRawData, $section.SizeOfRawData)
                [pscustomobject]@{ name=$section.Name; rva=$section.VirtualAddress; virtual_size=$section.VirtualSize; raw_size=$section.SizeOfRawData; raw_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)) }
            }
        })
        if ($sections.Count -eq 0) { throw 'Executable section missing.' }
        $cv = @($pe.ReadDebugDirectory() | Where-Object Type -eq CodeView | ForEach-Object { $pe.ReadCodeViewDebugDirectoryData($_) })
        if ($cv.Count -ne 1) { throw 'One CodeView entry required.' }
        if ((Get-FileHash -LiteralPath $full).Hash -cne $hash) { throw 'Binary changed.' }
        [pscustomobject]@{ path=$full; bytes=$stream.Length; before_sha256=$hash; after_sha256=$hash; image_base=$pe.PEHeaders.PEHeader.ImageBase; codeview_guid=$cv[0].Guid.ToString(); codeview_age=$cv[0].Age; codeview_path=$cv[0].Path; executable_sections=$sections }
    } finally { $pe.Dispose(); $stream.Dispose() }
}
No-Reparse $output
$original = Inspect $OriginalBinary
$mapping = Inspect $MappingBinary
$same = ($original.executable_sections | ConvertTo-Json -Depth 5 -Compress) -ceq ($mapping.executable_sections | ConvertTo-Json -Depth 5 -Compress)
$record = [ordered]@{
    status='comparison_completed'; original=$original; mapping=$mapping; executable_sections_identical=$same
    original_trace_rva_remap_allowed=$same; decision=$(if ($same) { 'separate-pair identity validation still required' } else { 'NO-GO for remapping; fresh capture required' })
    source_code_changed=$false; recorded_utc=[DateTime]::UtcNow.ToString('o')
    parent_observed_build=@{ program='C:/Users/IMT/.cargo/bin/rustc.exe'; argv=@('+1.98.1','--edition=2024','-C','opt-level=3','-C','panic=abort','-C','debuginfo=2','UnLhaRe/experiments/khc/causal-bayes-packed/codec.rs','-o', $mapping.path); exit_code=0; receipt='parent tool execution, not re-executed by this inspection' }
    inspection_source_sha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
}
$sink = [IO.File]::Open($output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$writer = [IO.StreamWriter]::new($sink, [Text.UTF8Encoding]::new($false))
try { $writer.Write(($record | ConvertTo-Json -Depth 10)) } finally { $writer.Dispose() }
$record | ConvertTo-Json -Depth 10
