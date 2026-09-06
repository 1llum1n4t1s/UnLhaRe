[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestProgram,[Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Fixture,[string]$RunnerPath='',
    [ValidateSet(0,1)][int]$UnicodeMode=1,[string]$DestinationName='output',
    [int]$ExpectedResult=0,[int]$ExpectedMissingResult=0,[int]$ExpectedMembers=3,[int]$ExpectedListResult=0,
    [ValidateSet('t','p','e','x')][string[]]$Commands=@('t','p','e','x'))
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '新しい検証領域が必要です'}
if([IO.Path]::GetFileName($DestinationName) -cne $DestinationName -or $DestinationName -in '','.','..'){throw '出力先名は領域内の単一ディレクトリ名に限定します'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
if(!$RunnerPath){$RunnerPath=Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'}
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$candidate=(Resolve-Path $Candidate).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$fixture=(Resolve-Path -LiteralPath $Fixture).Path
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
. ([scriptblock]::Create($helper.Extent.Text))
$bytes=[IO.File]::ReadAllBytes($fixture)
$hashes=@{}
foreach($path in $TestProgram,$runner,$oracle,$candidate,$fixture){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$count=0
foreach($command in $Commands){foreach($pattern in '*','missing'){foreach($abort in -1,0){
$snapshots=@()
foreach($side in 'oracle','reimpl'){
    $label="$command-$(if($pattern -eq '*'){'all'}else{$pattern})-$abort-$side"
    $root=Join-Path $workspace $label
    $outputDirectory=Join-Path $root $DestinationName
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
    $archive=Join-Path $root 'seed.lzh'
    [IO.File]::WriteAllBytes($archive,$bytes)
    $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
    $line="$command -+ -gm1 -y1 -n1 `"$archive`""
    if($command -in 'e','x'){$line+=" `"$($outputDirectory.Replace('\','/'))/`""}
    $line+=" $pattern"
    $rows=@(Invoke-EnumProbe (Join-Path $root 'trace') @('--progress-sequence-probe',$dll,'none','1041',[string]$UnicodeMode,'W','w64',"@abort-state:$abort",$line,"@audit-archive-release:$archive",'@abort-state:-1',"l -gm1 -n1 `"$archive`" *","@audit-archive-release:$archive"))
    $results=@($rows -match '^result=')
    $expected=if($abort -eq 0){32800}elseif($pattern -eq 'missing'){$ExpectedMissingResult}else{$ExpectedResult}
    if($results.Count -ne 2 -or $results[0] -cne "result=$expected" -or $results[1] -cne "result=$ExpectedListResult"){throw "継続処理の戻り値が不正です: $label"}
    if(@($rows -ceq 'archive-released=1,error=0').Count -ne 2){throw "同一 DLL の呼び出し後に書庫が解放されていません: $label"}
    $files=@(Get-ChildItem -LiteralPath $outputDirectory -Recurse -File | Sort-Object FullName | ForEach-Object {
        "file=$([IO.Path]::GetRelativePath($outputDirectory,$_.FullName)),size=$($_.Length),sha256=$((Get-FileHash -LiteralPath $_.FullName).Hash)"
    })
    $expectedFiles=if($command -in 'e','x' -and $pattern -eq '*' -and $abort -eq -1){$ExpectedMembers}else{0}
    if($files.Count -ne $expectedFiles){throw "解放試験の展開数が違います: $label"}
    [IO.File]::WriteAllLines((Join-Path $root 'effects.txt'),[string[]]$files)
    if((Get-FileHash -LiteralPath $archive).Hash -cne $hashes[$fixture]){throw '専用の入力書庫が変更されました'}
    $snapshots+=,@((@($rows)+@($files)) | ForEach-Object {$_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')})
}
$difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $workspace "$command-$abort-$count-diff.tsv") -Delimiter "`t" -NoTypeInformation;throw '解放前後の通知・ログ・状態が不一致です'}
$count++
Write-Host "$command/$pattern/$abort release and continuation passed"
}}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw "試験中に入力が変化しました: $path"}}
if(!$count -or $count -ne $Commands.Count*4){throw '解放試験の条件数が不足しています'}
Write-Host "Extraction header release: $count exact command sequences and $($count*4) exclusive-open guards passed"
