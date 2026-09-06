[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$RunnerPath='',
    [switch]$ReportDifferences
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = if($RunnerPath){(Resolve-Path -LiteralPath $RunnerPath).Path}else{
    (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../artifacts/Release/DesktopRunner.exe')).Path
}
$helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブが見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
$source = Join-Path $Workspace 'source'
New-Item -ItemType Directory -Path (Join-Path $source 'nested') | Out-Null
$names = @('a.txt','abcdefghijkl.txt','abcdefghijklm.txt','a-資料.txt','m-日本語.txt',
    '資料資料資料.txt','資料資料資料資料資料資料.txt','ｱｲｳｴｵｶｷｸ.txt','Ωé.txt','ＡＢＣ.txt','é.txt',
    'emoji-😀.txt','123456789😀.txt','nested/資料.txt')
$stamp = [datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc)
foreach ($name in $names) {
    $path = Join-Path $source $name
    [IO.File]::WriteAllText($path,'file payload',[Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path,$stamp)
}
$archive = Join-Path $Workspace 'names.lzh'
$selection = ($names | ForEach-Object { "`"$_`"" }) -join ' '
$created = @(Invoke-EnumProbe (Join-Path $Workspace 'seed') @('--base-command-probe',$Oracle,"a -+ -h2 -jm0 -gm1 -y1 `"$archive`" `"$source\`" $selection",'1041','1','W','none','0') $Workspace)
if ($created -notcontains 'result=0') { throw '文字幅対照の書庫を作成できません' }
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
Write-Host "Command name width workspace: $Workspace"
$count = 0
$rowsCompared = 0
$failures = 0
foreach ($commandName in 'l','v','l -x1','t','e','x') { foreach ($mode in 0,1,2) {
    foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') {
        $label = "$commandName/n$mode/locale$locale/utf8$utf8/$api"
        $snapshots = @()
        $extractedNames = @()
        foreach ($side in 'oracle','reimpl') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $command = "$commandName -+ -n$mode -gm1 -y1 `"$archive`""
            $destination = ''
            if ($commandName -in 'e','x') {
                $destination = Join-Path $Workspace ('extracted-{0:D3}-{1}' -f $count,$side)
                New-Item -ItemType Directory -Path $destination | Out-Null
                $command += " `"$destination\`""
            }
            $rows = @(Invoke-EnumProbe (Join-Path $Workspace ('probe-{0:D3}-{1}' -f $count,$side)) @('--base-command-probe',$dll,$command,[string]$locale,[string]$utf8,$api,'none','0') $Workspace)
            if ($rows -notcontains 'result=0') { throw "文字幅プローブの処理に失敗しました: $label/$side" }
            [IO.File]::WriteAllLines((Join-Path $Workspace ('case-{0:D3}-{1}.txt' -f $count,$side)),$rows)
            if ($destination) {
                $files = @(Get-ChildItem -LiteralPath $destination -File -Recurse | Sort-Object FullName)
                if ($files.Count -ne $names.Count) { throw "展開ファイル数が一致しません: $label/$side" }
                foreach ($file in $files) {
                    if ([IO.File]::ReadAllText($file.FullName) -cne 'file payload') { throw "展開した本文が一致しません: $label/$side" }
                }
                $extractedNames += ,@($files | ForEach-Object { [IO.Path]::GetRelativePath($destination,$_.FullName) })
                $rows = @($rows | ForEach-Object { $_.Replace($destination.Replace('\','/'),'<OUT>').Replace($destination.Replace('\','\\'),'<OUT>') })
            }
            $snapshots += ,$rows
        }
        if ($extractedNames.Count -and @(Compare-Object $extractedNames[0] $extractedNames[1] -SyncWindow 0).Count) { throw "展開名が一致しません: $label" }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) {
            $message = "名前の文字幅・一覧表示が一致しません: case=$count $label ($($difference.Count) rows)"
            if (!$ReportDifferences) { throw $message }
            Write-Host $message
            $failures++
        }
        $rowsCompared += $snapshots[0].Count
        $count++
    } } }
} }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hash) { throw '書庫が変更されました' }
if ($failures) { throw "Command name width: $count cases, $failures differences" }
Write-Host "Command name width: $count cases, $rowsCompared exact output/state rows compatible"
