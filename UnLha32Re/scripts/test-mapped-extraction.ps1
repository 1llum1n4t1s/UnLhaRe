[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$SeedArchive,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '新しい試験領域を指定してください'}
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath $RunnerPath).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$seed=(Resolve-Path -LiteralPath $SeedArchive).Path
$hashes=@{}
foreach($path in $TestProgram,$runner,$oracle,$candidate,$seed){$hashes[$path]=(Get-FileHash -LiteralPath $path).Hash}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブがありません'}
. ([scriptblock]::Create($helper.Extent.Text.Replace("'--registry',''", "'--registry',`$registrySeed")))
New-Item -ItemType Directory -Path $workspace | Out-Null
$stamp=([datetime]'2024-01-02T03:04:06Z').ToUniversalTime()
$fixed=$stamp.ToFileTimeUtc()
$count=0
Write-Host "Mapped extraction: candidate=$($hashes[$candidate]), probe=$($hashes[$TestProgram]), oracle=$($hashes[$oracle])"
foreach($mapped in 0,1){foreach($command in 'e','x'){foreach($api in 'legacy','A','W'){
    $registrySeed="L:UseMFile=$mapped"
    $snapshots=@()
    foreach($side in 'oracle','reimpl'){
        $root=Join-Path $workspace "$mapped-$command-$api-$side"
        New-Item -ItemType Directory -Path $root | Out-Null
        $path=Join-Path $root 'a.txt'
        [IO.File]::WriteAllText($path,'existing-content',[Text.UTF8Encoding]::new($false))
        [IO.File]::SetCreationTimeUtc($path,$stamp)
        [IO.File]::SetLastWriteTimeUtc($path,$stamp)
        [IO.File]::SetLastAccessTimeUtc($path,$stamp)
        $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
        # 新規のみの展開指定で既存内容を保持し、判定時の参照日時だけを観測する。
        $line="$command -+ -jn1 -gm1 -y1 -n1 `"$seed`" `"$($root.Replace('\','/'))/`" a.txt"
        $started=[datetime]::UtcNow.ToFileTimeUtc()
        $rows=@(Invoke-EnumProbe (Join-Path $root 'sequence') @('--sequence-dialog-probe',$dll,'2','w64','1041','1',$api,'w64',$line) $root)
        $ended=[datetime]::UtcNow.ToFileTimeUtc()
        $access=[IO.File]::GetLastAccessTimeUtc($path).ToFileTimeUtc()
        if($rows -notcontains 'result=0'){throw "展開拒否の戻り値: $mapped/$command/$api/$side"}
        if($mapped -eq 0 -and $access -ne $fixed){throw "無効設定で参照日時が変化: $command/$api/$side"}
        if($mapped -eq 1 -and ($access -lt $started -or $access -gt $ended)){throw "有効設定の参照日時が範囲外: $command/$api/$side"}
        if([IO.File]::GetCreationTimeUtc($path) -ne $stamp -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamp -or
            [IO.File]::ReadAllText($path) -cne 'existing-content'){throw '既存内容または日時が変更されました'}
        $snapshots+=,@($rows | ForEach-Object {$_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')})
    }
    if(@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0).Count){throw "通知・ログ不一致: $mapped/$command/$api"}
    $count++
}}}
foreach($path in $hashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]){throw "検証資産が変更されました: $path"}}
Write-Host "Mapped extraction: $count comparisons; source content/create/write/access and logs passed"
