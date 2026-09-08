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
Write-Host "Compression header initialization workspace: $Workspace"
$families = @(
    @{ Label='ascii'; Names=@('a.txt','empty.txt','guard.txt') },
    @{ Label='japanese'; Names=@('日本語.txt','空.txt','保持.txt') }
)
$configs = @(
    @{ Api='legacy'; Layout='none'; Locale=1033; Utf8=0 },
    @{ Api='A'; Layout='a32'; Locale=1041; Utf8=1 },
    @{ Api='W'; Layout='w32'; Locale=1041; Utf8=0 },
    @{ Api='legacy'; Layout='a64'; Locale=1033; Utf8=1 },
    @{ Api='W'; Layout='w64'; Locale=1041; Utf8=1 }
)
function New-HeaderSource([string]$Root,[string[]]$Names,[string]$Prefix,[int]$Year) {
    New-Item -ItemType Directory -Path $Root | Out-Null
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    for ($index = 0; $index -lt $Names.Count; $index++) {
        $path = Join-Path $Root $Names[$index]
        $payload = if ($Prefix -eq 'incoming' -and $index -eq 1) { '' } else { "$Prefix-$($Names[$index])-value" }
        [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
        [IO.File]::SetCreationTimeUtc($path,$time)
        [IO.File]::SetLastWriteTimeUtc($path,$time)
        [IO.File]::SetLastAccessTimeUtc($path,$time)
    }
}
$count = 0
foreach ($family in $families) {
    $names = $family.Names
    $seedRoot = Join-Path $Workspace "seed-$($family.Label)"
    New-HeaderSource $seedRoot $names 'seed' 2020
    $seed = Join-Path $Workspace "seed-$($family.Label).lzh"
    $selection = ($names | ForEach-Object { "`"$_`"" }) -join ' '
    $seedRows = @(& $TestProgram --registry '' --base-command-probe $Oracle "a -h2 -gm1 -y1 `"$seed`" `"$seedRoot\`" $selection" 1041 1 W none 0)
    if ($LASTEXITCODE -ne 0 -or $seedRows -notcontains 'result=0') { throw "level-2 元書庫を作成できません: $($family.Label)" }
    foreach ($selectionMode in 'first','all') { foreach ($commandName in 'a','u','f','m') { foreach ($config in $configs) {
        $selected = if ($selectionMode -eq 'first') { @($names[0]) } else { $names }
        $selection = ($selected | ForEach-Object { "`"$_`"" }) -join ' '
        # 従来 ANSI 入力の日本語は CP932 のロケールで渡す。表現不能名の動作は別の契約。
        $locale = if ($family.Label -eq 'japanese' -and $config.Utf8 -eq 0 -and $config.Api -ne 'W') { 1041 } else { $config.Locale }
        $label = "$($family.Label)/$selectionMode/$commandName/$($config.Api)/$($config.Layout)"
        $results = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
            $inputRoot = Join-Path $root 'input'
            New-HeaderSource $inputRoot $names 'incoming' 2024
            $archive = Join-Path $root 'result.lzh'
            Copy-Item -LiteralPath $seed -Destination $archive
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $command = "$commandName -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$inputRoot\`" $selection"
            # 先行する CheckArchive / GetFileCount 等は呼ばず、初回コマンドの事前走査を検証する。
            $rows = @(& $TestProgram --registry '' --base-command-probe $dll $command $locale $config.Utf8 $config.Api $config.Layout 0)
            [IO.File]::WriteAllLines((Join-Path $root 'command.txt'),$rows)
            if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains 'compat-error=0') { throw "level-2 初回更新に失敗しました: $label/$side`n$($rows -join "`n")" }
            $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
            $checked = @(& $TestProgram --registry '' --command-probe-a $Oracle "t -gm1 `"$archive`"" A)
            if ($LASTEXITCODE -ne 0 -or $checked -notcontains 'result=0') { throw "更新後の原版 CRC 検査に失敗しました: $label/$side" }
            $extractRoot = Join-Path $root 'extracted'
            New-Item -ItemType Directory -Path $extractRoot | Out-Null
            $extracted = @(& $TestProgram --registry '' --base-command-probe $Oracle "x -gm1 -y1 `"$archive`" `"$extractRoot\`"" 1041 1 W none 0)
            if ($LASTEXITCODE -ne 0 -or $extracted -notcontains 'result=0' -or @(Get-ChildItem -LiteralPath $extractRoot -File -Recurse).Count -ne $names.Count) { throw "更新後の原版展開に失敗しました: $label/$side" }
            # 原版での CRC 検査・展開だけでなく、候補が生成した書庫を候補自身のメモリ展開 API でも読み戻す。
            $contents = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`"" A)
            if ($LASTEXITCODE -ne 0 -or $contents -notcontains 'result=0') { throw "更新後の書庫内容を原版で読み戻せません: $label/$side" }
            if ($side -eq 'reimpl') {
                $candidateContents = @(& $TestProgram --registry '' --command-probe-a $Candidate "p -+ `"$archive`"" A)
                $candidateContentsExit = $LASTEXITCODE
                if ($candidateContentsExit -ne 0 -or $candidateContents -notcontains 'result=0') {
                    throw "更新後の書庫内容を候補自身で読み戻せません: $label/$side (exit $candidateContentsExit)`n$($candidateContents -join "`n")"
                }
                $contentsDifference = @(Compare-Object $contents $candidateContents -CaseSensitive -SyncWindow 0)
                if ($contentsDifference.Count) {
                    $details = $contentsDifference | Select-Object -First 12 | Out-String -Width 2000
                    throw "候補生成書庫の本文読み戻しが原版と不一致です: $label`n$details"
                }
            }
            foreach ($name in $names) {
                $prefix = if ($selected -contains $name) { 'incoming' } else { 'seed' }
                $expected = if ($prefix -eq 'incoming' -and $name -eq $names[1]) { '' } else { "$prefix-$name-value" }
                $actual = [IO.File]::ReadAllText((Join-Path $extractRoot $name),[Text.Encoding]::UTF8)
                if ($actual -cne $expected) { throw "更新・保持内容が一致しません: $label/$side/$name" }
                $expectedExists = $commandName -ne 'm' -or $selected -notcontains $name
                if ((Test-Path -LiteralPath (Join-Path $inputRoot $name)) -ne $expectedExists) { throw "元ファイルの保持・削除が一致しません: $label/$side/$name" }
            }
        }
        $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
        if ($difference.Count) { throw "level-2 初回更新の通知・ログ・状態が一致しません: $label`n$($difference | Select-Object -First 6 | Out-String -Width 2000)" }
        $count++
    } }
    Write-Host "Compression header initialization: $($family.Label)/$selectionMode, $count comparisons passed"
    }
}
Write-Host "Compression header initialization: $count cold a/u/f/m level-2 updates, ASCII/Japanese names, callbacks, CRC checks, full extracted-content, and source-retention comparisons passed"
