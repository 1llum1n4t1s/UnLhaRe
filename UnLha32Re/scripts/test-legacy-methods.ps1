[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('legacy','lx1')][string[]]$Groups = @('legacy','lx1'),
    [int[]]$CheckModes = @(0,1,2,6),
    [ValidateSet('legacy','A','W')][string[]]$CommandApis = @('legacy','A','W'),
    [string[]]$FixtureNames = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
foreach ($path in $TestProgram,$Oracle,$Candidate) {
    Write-Host "Legacy environment: $path, SHA256=$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
}
Write-Host "Legacy methods workspace: $Workspace"
# member.txt、本文 A、level 0 の固定ヘッダー。各生成器がサイズ・方式・CRC を再計算する。
$seed = Join-Path $Workspace 'seed.lzh'
[IO.File]::WriteAllBytes($seed,[Convert]::FromHexString('20DD2D6C68302D01000000010000008360225820000A6D656D6265722E747874C0304100'))
$sets = @()
if ('legacy' -in $Groups) {
    $legacy = Join-Path $Workspace 'literal'
    $boundaries = Join-Path $Workspace 'boundary'
    & (Join-Path $PSScriptRoot 'new-legacy-fixtures.ps1') -SeedArchive $seed -OutputDirectory $legacy
    & (Join-Path $PSScriptRoot 'new-legacy-boundaries.ps1') -Fixtures $legacy -OutputDirectory $boundaries
    $sets += @{ Root=$legacy; Payload=$true; Commands=$false }
    $sets += @{ Root=$boundaries; Payload=$false; Commands=$false }
}
if ('lx1' -in $Groups) {
    $lx1 = Join-Path $Workspace 'lx1'
    & (Join-Path $PSScriptRoot 'new-lx1-fixtures.ps1') -SeedArchive $seed -OutputDirectory $lx1
    $sets += @{ Root=$lx1; Payload=$true; Commands=$true }
}
$comparisonCount = 0
$memoryCount = 0
$commandCount = 0
function Assert-Same([object[]]$Expected,[object[]]$Actual,[string]$Label) {
    $difference = @(Compare-Object $Expected $Actual -SyncWindow 0)
    if ($difference.Count) { throw "旧方式の結果が元 DLL と一致しません: $Label`n$($difference | Select-Object -First 12 | Out-String -Width 2200)" }
}
foreach ($set in $sets) {
    $entries = @(Import-Csv -LiteralPath (Join-Path $set.Root 'fixtures.tsv') -Delimiter "`t" |
        Where-Object { $FixtureNames.Count -eq 0 -or $_.file -in $FixtureNames })
    foreach ($entry in $entries) {
        $archive = Join-Path $set.Root $entry.file
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        $traceRoot = Join-Path $set.Root ($entry.file + '.traces')
        New-Item -ItemType Directory -Path $traceRoot | Out-Null
        foreach ($mode in $CheckModes) {
            $snapshots = @()
            foreach ($side in 'oracle','candidate') {
                $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                $rows = @(& $TestProgram --registry '' --check-existing-archive-probe $dll $archive $mode)
                if ($LASTEXITCODE -ne 0 -or @($rows -match '^check\.existing\.').Count -ne 3) { throw "検査プローブが異常終了しました: $($entry.file)/$mode/$side" }
                [IO.File]::WriteAllLines((Join-Path $traceRoot "check-$mode-$side.txt"),$rows)
                if ($set.Payload -and @($rows -notmatch '^check\.existing\.\d+\.\d+=1,error=0,system=38$').Count) { throw "正常な試料が受理されません: $($entry.file)/$mode/$side" }
                $snapshots += ,$rows
            }
            Assert-Same $snapshots[0] $snapshots[1] "$($entry.file)/check/$mode"
            $comparisonCount += 3
        }
        if ($set.Payload) {
            $payloadName = if ($entry.PSObject.Properties['payload']) { $entry.payload } else { [IO.Path]::ChangeExtension($entry.file,'.bin') }
            $payload = Join-Path $set.Root $payloadName
            $expectedHash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash
            $snapshots = @()
            foreach ($side in 'oracle','candidate') {
                $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                $rows = @(& $TestProgram --registry '' --legacy-payload-probe $dll $archive $payload)
                [IO.File]::WriteAllLines((Join-Path $traceRoot "memory-$side.txt"),$rows)
                if ($LASTEXITCODE -ne 0 -or $rows.Count -ne 3 -or @($rows -notmatch ',payload=1,prefix=1,tail=1,guard=1$').Count) { throw "展開本文またはガードが一致しません: $($entry.file)/$side, exit=$LASTEXITCODE, rows=$($rows.Count)" }
                $snapshots += ,$rows
            }
            Assert-Same $snapshots[0] $snapshots[1] "$($entry.file)/memory"
            $memoryCount += 3
        }
        if ($set.Commands) {
            foreach ($api in $CommandApis) {
                $snapshots = @()
                foreach ($side in 'oracle','candidate') {
                    $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                    $outputRoot = Join-Path $traceRoot "$api-$side"
                    $flat = Join-Path $outputRoot 'flat'
                    $tree = Join-Path $outputRoot 'tree'
                    New-Item -ItemType Directory -Path $flat,$tree | Out-Null
                    $steps = @('l','v','t','p' | ForEach-Object { "$_ -+ -n1 -gm1 `"$archive`"" })
                    $steps += "e -+ -n1 -gm1 -y1 `"$archive`" `"$($flat.Replace('\','/'))/`""
                    $steps += "x -+ -n1 -gm1 -y1 `"$archive`" `"$($tree.Replace('\','/'))/`""
                    # 続けて別方式を読み、LX1 の表やブロック状態が漏れないことを確認する。
                    $followup = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\sample\lha-master\tests\lha-test16-l1.lzh'))
                    $steps += "t -+ -n1 -gm1 `"$followup`""
                    $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll w64 1041 1 $api @steps)
                    [IO.File]::WriteAllLines((Join-Path $traceRoot "commands-$api-$side.txt"),$rows)
                    if ($LASTEXITCODE -ne 0 -or @($rows -match '^result=').Count -ne 7 -or @($rows -match '^result=' | Where-Object { $_ -cne 'result=0' }).Count) { throw "LX1 のコマンドまたは別方式の継続処理に失敗しました: $($entry.file)/$api/$side" }
                    foreach ($directory in $flat,$tree) {
                        $extracted = Join-Path $directory 'member.txt'
                        if (!(Test-Path -LiteralPath $extracted) -or (Get-FileHash -LiteralPath $extracted -Algorithm SHA256).Hash -cne $expectedHash) { throw "ファイル展開本文が一致しません: $($entry.file)/$api/$side" }
                    }
                    $snapshots += ,@($rows | ForEach-Object { $_.Replace($outputRoot.Replace('\','\\'),'<OUT>').Replace($outputRoot.Replace('\','/'),'<OUT>') })
                }
                Assert-Same $snapshots[0] $snapshots[1] "$($entry.file)/commands/$api"
                $commandCount += 7
            }
        }
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hash) { throw '参照書庫が変更されました' }
    }
    Write-Host "Legacy methods: $comparisonCount check, $memoryCount full-payload, $commandCount command comparisons passed"
}
if ($comparisonCount + $memoryCount + $commandCount -eq 0) { throw '指定条件に一致する検証がありません' }
Write-Host "Legacy methods: $($comparisonCount + $memoryCount + $commandCount) comparisons passed"
