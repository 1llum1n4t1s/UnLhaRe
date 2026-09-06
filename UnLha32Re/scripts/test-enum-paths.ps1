[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Archive,
    [ValidateSet('all', 'paths', 'codepages')][string]$Scope = 'all',
    [uint32]$Locale = 0,
    [switch]$UnicodeMode,
    [ValidateSet('', 'legacy', 'A', 'W')][string]$Api = '',
    [switch]$Progress,
    [ValidateRange(0, 2)][int]$ProgressMode = 1,
    [ValidateSet('e', 'x', 'p', 't', 'l', 'v')][string[]]$Commands = @('e', 'x'),
    [ValidateSet('a32', 'w32', 'a64', 'w64', 'none')][string[]]$Layouts = @('a32', 'w32', 'a64', 'w64'),
    [string]$Pattern = 'a.txt'
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null

$count = 0
$replacementKinds = switch ($Scope) {
    'paths' { @('unchanged', 'leaf', 'nested', 'absolute') }
    'codepages' { @('japanese', 'nonbmp') }
    default { @('unchanged', 'leaf', 'nested', 'absolute', 'japanese', 'nonbmp') }
}
foreach ($layout in $Layouts) {
  foreach ($command in $Commands) {
    foreach ($destinationKind in 'absolute', 'relative', 'omitted') {
      foreach ($replacementKind in $replacementKinds) {
        if ($layout -eq 'none' -and $replacementKind -ne 'unchanged') { continue }
        # 従来の A 通知では非 BMP 文字を表せず '?' になるため、有効な書き換え名の試験対象外。
        if ($replacementKind -eq 'nonbmp' -and $layout.StartsWith('a') -and -not $UnicodeMode) { continue }
        foreach ($selected in 0, 1) {
            if ($layout -eq 'none' -and $selected -eq 0) { continue }
            $label = "$layout-$command-$destinationKind-$replacementKind-$selected"
            $results = @()
            foreach ($side in 'original', 'candidate') {
                $dll = if ($side -eq 'original') { $Oracle } else { $Candidate }
                # A API の出力長も比較できるよう、両側の作業パスを同じ長さにする。
                $sideDirectory = if ($side -eq 'original') { 'oracle' } else { 'reimpl' }
                $root = Join-Path $Workspace "$label-$sideDirectory"
                $working = Join-Path $root 'working'
                $destination = if ($destinationKind -eq 'omitted') { $working }
                    else { Join-Path $working 'destination' }
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                $line = "$command -gm1 -y1 -a1 `"$Archive`""
                if ($Progress) { $line = "$command -n$ProgressMode -gm1 -y1 -a1 `"$Archive`"" }
                if ($destinationKind -eq 'absolute') { $line += " `"$destination\`"" }
                elseif ($destinationKind -eq 'relative') { $line += ' "destination\"' }
                $line += " $Pattern"
                $arguments = @('--registry', '', '--command-enum-probe', $dll, $line, $layout, "$selected")
                $replacement = switch ($replacementKind) {
                    'leaf' { 'renamed.txt' }
                    'nested' { 'folder/renamed.txt' }
                    'absolute' { Join-Path $destination 'renamed.txt' }
                    'japanese' { '子フォルダ/変更.txt' }
                    'nonbmp' { '補助🙂/変更🗂.txt' }
                    default { '' }
                }
                $arguments += @($replacement, "$Locale", "$([int]$UnicodeMode.IsPresent)", $Api, "$([int]$Progress.IsPresent)")
                Push-Location -LiteralPath $working
                try { $rows = @(& $TestProgram @arguments); $probeExit = $LASTEXITCODE }
                finally { Pop-Location }
                if ($probeExit -ne 0 -or $rows -notcontains 'result=0') {
                    throw "列挙通知の展開先試験に失敗しました: $label / $side`n$($rows -join "`n")"
                }
                $rows = @($rows | ForEach-Object {
                    $_.Replace($root.Replace('\', '/'), '<ROOT>').Replace($root.Replace('\', '\\'), '<ROOT>')
                })
                foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)) {
                    $name = [IO.Path]::GetRelativePath($root, $file.FullName)
                    $rows += "file=$name,attributes=$([int]$file.Attributes),size=$($file.Length),time=$($file.LastWriteTimeUtc.Ticks),hash=$((Get-FileHash -LiteralPath $file.FullName).Hash)"
                }
                $results += ,$rows
            }
            $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
            if ($difference.Count -ne 0) {
                $details = $difference | Select-Object -First 8 | ForEach-Object {
                    $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
                    "$side`: $($_.InputObject)"
                } | Out-String -Width 1200
                throw "列挙通知の展開先が一致しません: $label`n$details"
            }
            $count++
        }
      }
    }
  }
}
Write-Host "Enum extraction paths: $count A/W 32/64 cases, callback decisions, logs, and file effects compatible"
