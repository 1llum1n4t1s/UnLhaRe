[CmdletBinding()]
param([Parameter(Mandatory)][string]$TestProgram,[Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,[Parameter(Mandatory)][string]$Workspace)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の試験領域です'}
New-Item -ItemType Directory -Path $workspace | Out-Null
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$source=Join-Path $workspace 'input'
New-Item -ItemType Directory -Path $source | Out-Null
$payloads=[ordered]@{'a.txt'='first payload';'m.txt'=('middle payload'*20);'z.txt'=''}
foreach($name in $payloads.Keys){
    $path=Join-Path $source $name
    [IO.File]::WriteAllText($path,$payloads[$name],[Text.UTF8Encoding]::new($false))
    foreach($setter in 'SetCreationTimeUtc','SetLastWriteTimeUtc','SetLastAccessTimeUtc'){[IO.File]::$setter($path,[datetime]'2020-01-02T03:04:06Z')}
}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブ関数が見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
. (Join-Path $PSScriptRoot 'level3-header-fixture.ps1')
$results=@()
foreach($level in 0,1,2,3){
    $root=Join-Path $workspace "h$level"
    New-Item -ItemType Directory -Path $root | Out-Null
    $seed=Join-Path $root 'seed.lzh'
    if($level -ne 3){
        $created=@(Invoke-EnumProbe (Join-Path $root 'seed') @('--base-command-probe',$oracle,"a -+ -h$level -jm0 -gm1 -y1 `"$seed`" `"$source\`" a.txt m.txt z.txt",'1041','0','W','none','0'))
        if($created -notcontains 'result=0'){throw '元書庫を作成できません'}
    }else{
        $converted=ConvertTo-Level3HeaderFixture ([IO.File]::ReadAllBytes((Join-Path $workspace 'h2/seed.lzh')))
        [IO.File]::WriteAllBytes($seed,$converted.Bytes)
    }
    $bytes=[IO.File]::ReadAllBytes($seed)
    $start=0
    for($index=0;$index -lt 2;$index++){
        if($bytes[$start+20] -ne $level){throw '対照のレベルが不正です'}
        $headerSize=if($level -lt 2){[int]$bytes[$start]+2}elseif($level -eq 2){[int][BitConverter]::ToUInt16($bytes,$start)}else{[int][BitConverter]::ToUInt32($bytes,$start+24)}
        $start+=$headerSize+[int][BitConverter]::ToUInt32($bytes,$start+7)
    }
    $lastHeaderLength=$bytes.Length-$start-1
    $inputs=[ordered]@{good=$bytes;badEnd=[byte[]]($bytes[0..($bytes.Length-2)]+1)}
    $lengths=@(1,2,20,21,22,31,32,($lastHeaderLength-1)) | Where-Object {$_ -gt 0 -and $_ -lt $lastHeaderLength} | Sort-Object -Unique
    foreach($kept in $lengths){$inputs["cut$kept"]=[byte[]]$bytes[0..($start+$kept-1)]}
    foreach($name in $inputs.Keys){
        $archive=Join-Path $root "$name.lzh"
        [IO.File]::WriteAllBytes($archive,$inputs[$name])
        $hash=(Get-FileHash -LiteralPath $archive).Hash
        $stamp=[IO.File]::GetLastWriteTimeUtc($archive)
        foreach($command in 'l','t'){
            $snapshots=@()
            foreach($side in 'oracle','candidate'){
                $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
                $rows=@(Invoke-EnumProbe (Join-Path $root "$name-$command-$side") @('--command-enum-probe',$dll,"$command -gm1 -n1 `"$archive`" *",'w64','1','','1041','1','W','1'))
                $expected=if($name -in 'good','badEnd','cut1'){0}else{32834}
                if($rows -notcontains "result=$expected"){throw "読取結果が不正です: h$level/$name/$command/$side"}
                if((Get-FileHash -LiteralPath $archive).Hash -cne $hash -or [IO.File]::GetLastWriteTimeUtc($archive) -ne $stamp){throw '読取書庫が変更されました'}
                $snapshots+=,$rows
            }
            $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
            if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $root "$name-$command-diff.tsv") -Delimiter "`t" -NoTypeInformation}
            $results+=[pscustomobject]@{Level=$level;Case=$name;Command=$command;Differences=$difference.Count;Oracle=($snapshots[0] -match '^result=')[0];Candidate=($snapshots[1] -match '^result=')[0]}
        }
    }
}
$results | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
if($results.Count -ne 76 -or @($results | Where-Object Differences -ne 0).Count){
    $results | Where-Object Differences -ne 0 | Format-Table -AutoSize | Out-String | Write-Host
    throw 'Level-0/1/2/3 の短いヘッダー比較が不一致です'
}
Write-Host 'Short command headers: 76 exact comparisons and immutable-input guards passed'
