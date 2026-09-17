[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw "試験領域が既にあります: $Workspace" }
$full = Join-Path $Workspace 'full'
$empty = Join-Path $Workspace 'empty'
$partial = Join-Path $Workspace 'partial'
$directories = Join-Path $Workspace 'directories'
New-Item -ItemType Directory -Path $full, $empty, $partial,
    (Join-Path $directories 'a.txt'), (Join-Path $directories 'z.bin') | Out-Null
$setup = @(& $TestProgram --registry '' --command-probe $Oracle "x -gm1 -n1 -y1 `"$Archive`" `"$full\`"")
if ($LASTEXITCODE -ne 0 -or $setup -notcontains 'result=0' -or
    -not (Test-Path -LiteralPath (Join-Path $full 'z.bin'))) {
    throw '一覧試験には memory-selection fixture が必要です。'
}
Copy-Item -LiteralPath (Join-Path $full 'z.bin') -Destination $partial

function Get-InputSnapshot {
    @(Get-ChildItem -LiteralPath $Workspace -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.PSIsContainer) { "$($_.FullName)|directory|$([int]$_.Attributes)" }
        else { "$($_.FullName)|$($_.Length)|$([int]$_.Attributes)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    })
}
$before = Get-InputSnapshot
$checks = 0
function Assert-ProbePair([string]$Command, [string[]]$Options) {
    $rows = @()
    foreach ($dll in @($Oracle, $Candidate)) {
        $output = @(& $TestProgram --registry '' $Options[0] $dll $Command @($Options | Select-Object -Skip 1))
        if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { throw "一覧プローブ失敗: $dll / $Command" }
        $rows += ,$output
    }
    if ([string]::Join("`n", $rows[0]) -cne [string]::Join("`n", $rows[1])) {
        $difference = Compare-Object $rows[0] $rows[1] -SyncWindow 0 | Out-String -Width 4000
        throw "一覧の新規限定が不一致: $Command / $($Options -join ' ')`n$difference"
    }
    $script:checks++
}
foreach ($current in @($full, $empty, $partial)) {
    Push-Location -LiteralPath $current
    try {
        foreach ($base in @('', $full, $empty, $partial)) {
            foreach ($command in @('l', 'v')) {
                foreach ($display in 0, 1) {
                    foreach ($newOnly in 0, 1) {
                        $line = "$command -gm1 -n$display -jn$newOnly `"$Archive`""
                        if ($base) { $line += " `"$base\`"" }
                        foreach ($probe in @('--command-probe', '--command-probe-a')) {
                            Assert-ProbePair $line @($probe)
                        }
                    }
                }
            }
        }
        foreach ($layout in @('a32', 'w32', 'a64', 'w64')) {
            foreach ($selected in 0, 1) {
                foreach ($command in @('l', 'v')) {
                    Assert-ProbePair "$command -gm1 -jn1 `"$Archive`"" @('--command-enum-probe', $layout, "$selected")
                }
            }
        }
        foreach ($command in @('l', 'v')) {
            foreach ($firstMode in 0, 1) {
                $first = "$command -gm1 -n1 -jn$firstMode `"$Archive`""
                $second = "$command -gm1 -n1 -jn$(1 - $firstMode) `"$Archive`""
                Assert-ProbePair $first @('--command-sequence-probe', $second)
            }
        }
    } finally { Pop-Location }
}
Push-Location -LiteralPath $directories
try {
    foreach ($command in @('l', 'v')) {
        foreach ($probe in @('--command-probe', '--command-probe-a')) {
            Assert-ProbePair "$command -gm1 -n1 -jn1 `"$Archive`"" @($probe)
        }
    }
} finally { Pop-Location }
if ([string]::Join("`n", $before) -cne [string]::Join("`n", (Get-InputSnapshot))) {
    throw '一覧命令が比較用ファイルを変更しました。'
}
Write-Host "List new-only: $checks A/W, base-directory, partial-existence, and callback cases compatible; files unchanged"
