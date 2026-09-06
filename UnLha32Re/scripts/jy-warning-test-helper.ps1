function Invoke-JyWarningCases {
    param(
        [Parameter(Mandatory)][string]$TestProgram,
        [Parameter(Mandatory)][string]$RunnerPath,
        [Parameter(Mandatory)][string]$Oracle,
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Workspace,
        [Parameter(Mandatory)][object[]]$Cases,
        [Parameter(Mandatory)][string]$Category
    )
    $ErrorActionPreference='Stop'
    $TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
    $runner=(Resolve-Path -LiteralPath $RunnerPath).Path
    $Oracle=(Resolve-Path -LiteralPath $Oracle).Path
    $Candidate=(Resolve-Path -LiteralPath $Candidate).Path
    $Archive=(Resolve-Path -LiteralPath $Archive).Path
    $Workspace=[IO.Path]::GetFullPath($Workspace)
    if(Test-Path -LiteralPath $Workspace){throw '新しい jy 警告試験領域が必要です。'}
    if(!$Cases.Count){throw 'jy 警告の試験条件が空です。'}
    $hashes=@{}; $stamps=@{}
    foreach($path in $TestProgram,$runner,$Oracle,$Candidate,$Archive){
        $hashes[$path]=(Get-FileHash -LiteralPath $path).Hash
        $stamps[$path]=[IO.File]::GetLastWriteTimeUtc($path)
    }
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$null)
    $helper=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
    if(!$helper){throw '隔離・時間制限付きプローブがありません。'}
    . ([scriptblock]::Create($helper.Extent.Text))
    New-Item -ItemType Directory -Path $Workspace | Out-Null
    $count=0
    foreach($case in $Cases){
        if($case.Name -notmatch '^[a-z0-9-]+$'){throw '試験名は安全なディレクトリー名に限定します。'}
        foreach($api in 'legacy','A','W'){
            $snapshots=@{}
            foreach($side in 'oracle','candidate'){
                $root=Join-Path $Workspace "$($case.Name)-$api-$side"
                New-Item -ItemType Directory -Path $root | Out-Null
                $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
                # 検査命令だけを使い、入力書庫の置換・展開・元入力の削除を行わない。
                $command='t -gm1 -y1 '+($case.Switches -join ' ')+' "'+$Archive+'"'
                $probe=if($api -eq 'W'){'--command-probe'}else{'--command-probe-a'}
                $arguments=@($probe,$dll,$command)
                if($api -eq 'A'){$arguments+='A'}
                $rows=@(Invoke-EnumProbe (Join-Path $root 'command') $arguments $root)
                if(@($rows -ceq 'result=0').Count -ne 1 -or @($rows -ceq 'compat-error=0').Count -ne 1){
                    throw "警告後の書庫検査が成功しません: $($case.Name)/$api/$side"
                }
                $outputs=@($rows -match '^output=')
                if($outputs.Count -ne 1){throw '出力の完了記録が不正です。'}
                $warnings=@([regex]::Matches($outputs[0],"invalid switch : '([^']*)'") | ForEach-Object {$_.Groups[1].Value})
                if(($warnings -join "`n") -cne (@($case.Warnings) -join "`n")){
                    throw "警告の文字・件数・順序が違います: $($case.Name)/$api/$side"
                }
                $snapshots[$side]=$rows
            }
            if(@(Compare-Object $snapshots.oracle $snapshots.candidate -SyncWindow 0).Count){
                throw "jy 警告・出力長・検査結果が一致しません: $($case.Name)/$api"
            }
            $count++
        }
    }
    foreach($path in $hashes.Keys){
        if((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path] -or [IO.File]::GetLastWriteTimeUtc($path) -ne $stamps[$path]){
            throw "検証入力・バイナリが変更されました: $path"
        }
    }
    if($count -ne $Cases.Count*3){throw 'jy 警告の比較件数が不足しています。'}
    Write-Host "Jy warnings $Category`: $count exact legacy/A/W comparisons and immutable-input guards passed"
}
