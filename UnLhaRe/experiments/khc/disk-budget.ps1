[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [ValidateRange(1, 4096)][int]$MaxRunMiB = 256,
    [ValidateRange(1, 1024)][int]$MinFreeGiB = 5
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workPath = [IO.Path]::GetFullPath($WorkDirectory, $projectRoot)
Assert-KhcStorageContext -WorkDirectory $workPath
$storage = Assert-KhcStorageBudget -ReserveBytes ([long]$MaxRunMiB * 1MB)
$ancestor = $workPath
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "リンク先を実験生成先にできません: $ancestor"
        }
    }
    $ancestor = [IO.Path]::GetDirectoryName($ancestor)
}
$used = 0L
if (Test-Path -LiteralPath $workPath) {
    if (!(Test-Path -LiteralPath $workPath -PathType Container)) { throw '生成先がディレクトリではありません。' }
    $entries = @(Get-ChildItem -LiteralPath $workPath -Recurse -Force)
    if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw '生成先配下にリンクがあります。' }
    $files = @($entries | Where-Object { !$_.PSIsContainer })
    if ($files.Count) {
        $used = [long](($files | Measure-Object Length -Sum).Sum)
    }
}
$free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($workPath)).AvailableFreeSpace
$budget = [long]$MaxRunMiB * 1MB
if ($used -gt $budget) { throw "生成先が容量予算超過です: $used > $budget bytes" }
if ($free -lt ([long]$MinFreeGiB * 1GB + $budget)) { throw "空き容量不足です: $free bytes（空き下限と実験予算を確保できません）" }
[pscustomobject]@{ work_directory = $workPath; used_bytes = $used; max_bytes = $budget; free_bytes = $free; minimum_free_bytes = [long]$MinFreeGiB * 1GB; storage = $storage }
