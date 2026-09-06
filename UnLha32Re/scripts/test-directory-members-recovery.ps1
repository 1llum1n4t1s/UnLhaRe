[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Directory member recovery workspace: $Workspace"
# 登録直後の初回通知だけを、既存のゼロ初期化契約で検査する。
$helperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-compression-directories.ps1'),[ref]$null,[ref]$null)
$helper = $helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Normalize-NewDirectoryRows'},$true)
if (!$helper) { throw '初回通知の検査処理がありません。' }
. ([scriptblock]::Create($helper.Extent.Text))
function Normalize-DirectoryRecoveryRows([string[]]$Rows, [string]$Side) {
    $boundary = [Array]::IndexOf($Rows, 'phase=1')
    if ($Rows[0] -cne 'phase=0' -or $boundary -lt 1) { throw '初回操作の境界が不正です。' }
    Normalize-NewDirectoryRows $Rows[0..($boundary - 1)] $Side 1
    # 件数取得で確定した後の通知値は、そのまま全項目を比較する。
    $Rows[$boundary..($Rows.Count - 1)]
}
$count = 0
foreach ($layout in 'a32','w32','a64','w64') { foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') {
    $label = "$layout/$locale/$utf8/$api"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        $inputDirectory = Join-Path $root 'input'
        New-Item -ItemType Directory -Path (Join-Path $inputDirectory 'empty'),(Join-Path $inputDirectory 'tree/sub') | Out-Null
        $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
        foreach ($name in 'a.txt','tree/b.txt','tree/sub/c.txt') {
            $path = Join-Path $inputDirectory $name
            [IO.File]::WriteAllText($path,"input-$name-value",[Text.UTF8Encoding]::new($false))
            [IO.File]::SetCreationTimeUtc($path,$time)
            [IO.File]::SetLastWriteTimeUtc($path,$time)
            [IO.File]::SetLastAccessTimeUtc($path,$time)
        }
        foreach ($name in 'empty','tree/sub','tree') {
            $path = Join-Path $inputDirectory $name
            [IO.Directory]::SetCreationTimeUtc($path,$time)
            [IO.Directory]::SetLastWriteTimeUtc($path,$time)
            [IO.Directory]::SetLastAccessTimeUtc($path,$time)
        }
        $firstArchive = Join-Path $root 'first.lzh'
        $directoryArchive = Join-Path $root 'directory.lzh'
        $ignoredArchive = Join-Path $root 'ignored.lzh'
        $lastArchive = Join-Path $root 'last.lzh'
        $base = "`"$($inputDirectory.Replace('\','/'))/`""
        $first = "m -h0 -n1 -gm1 -y1 `"$firstArchive`" $base a.txt"
        $directory = "m -d1 -h0 -n1 -gm1 -y1 `"$directoryArchive`" $base empty"
        $ignored = "m -h0 -n1 -gm1 -y1 `"$ignoredArchive`" $base tree"
        $last = "m -d1 -h0 -n1 -gm1 -y1 `"$lastArchive`" $base tree"
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll $layout $locale $utf8 $api $first "@count:$firstArchive" $directory "@check:$directoryArchive" $ignored $last "@check:$lastArchive")
        if ($LASTEXITCODE -ne 0) { throw "ディレクトリー設定の連続試験が異常終了しました: $label/$side" }
        [IO.File]::WriteAllLines((Join-Path $root 'commands.txt'),$rows)
        $commandResults = @($rows | Where-Object { $_ -match '^result=' })
        $systemErrors = @($rows | Where-Object { $_ -match '^compat-system-error=' })
        if (($commandResults -join ',') -cne 'result=0,result=0,result=0,result=0' -or
            ($systemErrors -join ',') -cne 'compat-system-error=18,compat-system-error=18,compat-system-error=18,compat-system-error=18' -or
            $rows -notcontains 'count=1' -or @($rows | Where-Object { $_ -eq 'check=1' }).Count -ne 2 -or
            (Test-Path -LiteralPath $ignoredArchive)) { throw "ディレクトリー設定・削除結果が想定と違います: $label/$side`n$($rows -join "`n")" }
        if (@(Get-ChildItem -LiteralPath $inputDirectory -File -Recurse).Count) { throw "正常な移動後に入力ファイルが残っています: $label/$side" }
        foreach ($name in 'empty','tree/sub','tree') { if (-not (Test-Path -LiteralPath (Join-Path $inputDirectory $name) -PathType Container)) { throw "元ディレクトリーが消えました: $label/$side/$name" } }
        $results += ,@(Normalize-DirectoryRecoveryRows $rows $side | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "ディレクトリー設定の連続通知・ログ・エラーが一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2000)" }
    $count++
} }
Write-Host "Directory member recovery: $layout/$locale, $count sequences passed"
} }
Write-Host "Directory member recovery: $count retained-DLL file move, directory-only move, default-switch reset, metadata, and deletion-state sequences passed"
