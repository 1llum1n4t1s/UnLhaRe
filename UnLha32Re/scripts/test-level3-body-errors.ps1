[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Level2Fixtures,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('ascii','japanese')][string[]]$Families=@('ascii','japanese'),
    [ValidateSet(0,2)][int[]]$Methods=@(0,2),
    [ValidateSet('control','crc','tail','header-cut','body-cut')][string[]]$Groups=@('control','crc','tail','header-cut','body-cut'),
    [ValidateSet('l','v','t','p')][string[]]$Commands=@('l','v','t','p'),
    [string[]]$ProfileNames=@('w64'),
    [string[]]$CaseNames=@()
)
$ErrorActionPreference='Stop'
$workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $workspace){throw '既存の診断結果は上書きしません'}
New-Item -ItemType Directory -Path $workspace | Out-Null
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$runner=(Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$oracle=(Resolve-Path -LiteralPath $Oracle).Path
$candidate=(Resolve-Path -LiteralPath $Candidate).Path
$Level2Fixtures=(Resolve-Path -LiteralPath $Level2Fixtures).Path
. (Join-Path $PSScriptRoot 'level3-header-fixture.ps1')
# 並列時の出力欠落対策と個別 30 秒上限を持つ、既存の隔離プローブ関数を共有する。
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
$helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if(!$helper){throw '隔離プローブ関数が見つかりません'}
. ([scriptblock]::Create($helper.Extent.Text))
function Update-BodyFixtureCrc([byte[]]$Bytes,[int]$Start,[int]$Length,[int]$CrcAt){
    $Bytes[$CrcAt]=0
    $Bytes[$CrcAt+1]=0
    [int]$crc=0
    for($offset=$Start;$offset -lt $Start+$Length;$offset++){
        $crc=$crc -bxor [int]$Bytes[$offset]
        for($bit=0;$bit -lt 8;$bit++){$crc=if($crc -band 1){($crc -shr 1) -bxor 0xa001}else{$crc -shr 1}}
    }
    [BitConverter]::GetBytes([uint16]$crc).CopyTo($Bytes,$CrcAt)
}
$profiles=@{
    w64=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    a32=@{Api='A';Layout='a32';Selected='1';Replacement='';Pattern='*';Capacity=0}
    legacy=@{Api='legacy';Layout='a64';Selected='1';Replacement='';Pattern='*';Capacity=0}
    reject=@{Api='W';Layout='w32';Selected='0';Replacement='';Pattern='*';Capacity=0}
    missing=@{Api='W';Layout='w64';Selected='1';Replacement='';Pattern='missing';Capacity=0}
    rename=@{Api='W';Layout='w64';Selected='1';Replacement='renamed.txt';Pattern='*';Capacity=0}
    'raw-W'=@{Api='W';Pattern='*';Capacity=4096}
    'raw-A-1'=@{Api='A';Pattern='*';Capacity=1}
    'raw-A'=@{Api='A';Pattern='*';Capacity=4096}
    'raw-legacy'=@{Api='legacy';Pattern='*';Capacity=4096}
    'raw-W-missing'=@{Api='W';Pattern='missing';Capacity=4096}
    'raw-W-empty'=@{Api='W';Pattern='z.txt';Capacity=4096}
}
foreach($profileName in $ProfileNames){if(!$profiles.ContainsKey($profileName)){throw "未知のプローブ構成です: $profileName"}}
$environmentHashes=@{}
foreach($path in $TestProgram,$runner,$oracle,$candidate){
    $environmentHashes[$path]=(Get-FileHash -LiteralPath $path).Hash
    Write-Host "$path SHA256=$($environmentHashes[$path])"
}
$observations=[Collections.Generic.List[object]]::new()
$expectedTotal=0
foreach($family in $Families){foreach($method in $Methods){
    $root=Join-Path $workspace "$family-jm$method"
    New-Item -ItemType Directory -Path $root | Out-Null
    $seed=(Resolve-Path -LiteralPath (Join-Path $Level2Fixtures "$family-jm$method/seed.lzh")).Path
    $environmentHashes[$seed]=(Get-FileHash -LiteralPath $seed).Hash
    $converted=ConvertTo-Level3HeaderFixture ([IO.File]::ReadAllBytes($seed))
    $good=$converted.Bytes
    $records=@()
    $position=0
    for($member=0;$member -lt 3;$member++){
        if($good[$position+20] -ne 3){throw '正常対照のレベルが不正です'}
        $headerSize=[int][BitConverter]::ToUInt32($good,$position+24)
        $packed=[int][BitConverter]::ToUInt32($good,$position+7)
        $records+=@{Start=$position;HeaderSize=$headerSize;Packed=$packed;CrcAt=$converted.CrcPositions[$member]}
        $position+=$headerSize+$packed
    }
    if($position+1 -ne $good.Length -or $good[$position] -ne 0){throw '正常対照の終端が不正です'}
    $inputs=[ordered]@{}
    if('control' -in $Groups){$inputs['good']=$good}
    if('crc' -in $Groups){
        $badIndexes=[ordered]@{first=@(0);middle=@(1);last=@(2);all=@(0,1,2)}
        foreach($variant in $badIndexes.Keys){
            $bad=[byte[]]$good.Clone()
            foreach($member in $badIndexes[$variant]){
                $record=$records[$member]
                $bad[$record.Start+21]=$bad[$record.Start+21] -bxor 1
                Update-BodyFixtureCrc $bad $record.Start $record.HeaderSize $record.CrcAt
            }
            $inputs["crc-$variant"]=$bad
        }
        foreach($member in 0,1){
            $bad=[byte[]]$good.Clone()
            $record=$records[$member]
            $at=$record.Start+$record.HeaderSize
            $bad[$at]=$bad[$at] -bxor 1
            $inputs["payload-$member"]=$bad
        }
    }
    if('tail' -in $Groups){
        $withoutEnd=[byte[]]$good[0..($good.Length-2)]
        $inputs['no-end']=$withoutEnd
        $inputs['bad-end1']=[byte[]]($withoutEnd+1)
        $inputs['bad-end2']=[byte[]]($withoutEnd+1+1)
    }
    if('header-cut' -in $Groups){
        foreach($kept in 1,2,20,21,31,32){$inputs["header-cut$kept"]=[byte[]]$good[0..($records[2].Start+$kept-1)]}
    }
    if('body-cut' -in $Groups){
        foreach($member in 0,1){
            $record=$records[$member]
            $lengths=@(0,1,2,3,[int][Math]::Floor($record.Packed/2),($record.Packed-1),$record.Packed) | Sort-Object -Unique
            foreach($kept in $lengths){$inputs["body$member-cut$kept"]=[byte[]]$good[0..($record.Start+$record.HeaderSize+$kept-1)]}
        }
    }
    foreach($name in $inputs.Keys){
        if($CaseNames.Count -and $name -notin $CaseNames){continue}
        $expectedTotal+=$Commands.Count*$ProfileNames.Count
        $archive=Join-Path $root "$name.lzh"
        [IO.File]::WriteAllBytes($archive,$inputs[$name])
        $environmentHashes[$archive]=(Get-FileHash -LiteralPath $archive).Hash
        foreach($command in $Commands){foreach($profileName in $ProfileNames){
            $profile=$profiles[$profileName]
            $line="$command -gm1 -n1 `"$archive`" `"$($profile.Pattern)`""
            $label="$name-$command-$profileName"
            $snapshots=@()
            foreach($side in 'oracle','candidate'){
                $dll=if($side -eq 'oracle'){$oracle}else{$candidate}
                $arguments=if($profile.Capacity){@('--command-raw-probe',$dll,$line,$profile.Api,[string]$profile.Capacity,'utf8')}
                    else{@('--command-enum-probe',$dll,$line,$profile.Layout,$profile.Selected,$profile.Replacement,'1041','1',$profile.Api,'1')}
                $rows=@(Invoke-EnumProbe (Join-Path $root "$label-$side") $arguments)
                if(@($rows -match '^result=').Count -ne 1){throw '戻り値行が不足しています'}
                if($name -eq 'good' -and !@($rows -match '^result=0(?:,|$)').Count){throw "正常対照が失敗しました: $label/$side"}
                if($profile.Capacity){
                    $units=@((($rows[0] -split 'raw=',2)[1]).TrimEnd(',').Split(','))
                    $guard=if($profile.Api -eq 'W'){'cccc'}else{'cc'}
                    if($units.Count -ne $profile.Capacity+16 -or @($units[0..7] -cne $guard).Count -or @($units[($profile.Capacity+8)..($profile.Capacity+15)] -cne $guard).Count){throw '生バッファの境界が変更されました'}
                }
                $snapshots+=,$rows
            }
            $difference=@(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
            if($difference.Count){$difference | Export-Csv -LiteralPath (Join-Path $root "$label-diff.tsv") -Delimiter "`t" -NoTypeInformation}
            $observations.Add([pscustomobject]@{Family=$family;Method=$method;Case=$name;Command=$command;Profile=$profileName;Differences=$difference.Count;Oracle=($snapshots[0] -match '^result=')[0];Candidate=($snapshots[1] -match '^result=')[0]})
        }}
        $observations | Export-Csv -LiteralPath (Join-Path $workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
        Write-Host "$family/jm$method/$name comparisons=$($observations.Count)"
    }
}}
foreach($path in $environmentHashes.Keys){if((Get-FileHash -LiteralPath $path).Hash -cne $environmentHashes[$path]){throw "試験中に内容が変化しました: $path"}}
$failures=@($observations | Where-Object Differences -ne 0)
if(!$expectedTotal -or $observations.Count -ne $expectedTotal){throw '本文エラー比較の件数が不足しています'}
if($failures.Count){$failures | Select-Object Family,Method,Case,Command,Profile,Differences | Format-Table -AutoSize | Out-String -Width 200 | Write-Host; throw 'Level-3 本文・終端・短いヘッダーの比較が不一致です'}
Write-Host "Level-3 body errors: $($observations.Count) exact comparisons and immutable-input guards passed"
