[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$ForeignFixtures,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$CaseLabels = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$ForeignFixtures = (Resolve-Path -LiteralPath $ForeignFixtures).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '新しい既存連結の形式判定試験領域が必要です' }
$inputs = @{
    normal=$Seed
    tail=(Join-Path $ForeignFixtures 'fixtures-0/tail-80-zip.lzh')
    prefix=(Join-Path $ForeignFixtures 'prefixed-lzh-with-zip-tail.lzh')
    zip=(Join-Path $ForeignFixtures 'zip-directory-only.lzh')
    'empty-lh0'=(Join-Path $ForeignFixtures 'fixtures-0/empty-lh0.lzh')
    'empty-lh5'=(Join-Path $ForeignFixtures 'fixtures-0/empty-lh5.lzh')
}
$cases = [Collections.Generic.List[object]]::new()
foreach ($api in 'legacy','A','W') {
    foreach ($kind in 'empty-tail20','empty-tail21','empty-tail22','data-tail20','data-tail21','data-tail22') {
        foreach ($fresh in $false,$true) {
            $cases.Add([pscustomobject]@{label="$kind-fresh$fresh-$api"; kind=$kind; policy='default'; api=$api; mode=1; order='single'; rejectOld=$false; fresh=$fresh})
        }
    }
    foreach ($kind in 'empty-lh0','empty-lh5') { foreach ($fresh in $false,$true) {
        $cases.Add([pscustomobject]@{label="$kind-fresh$fresh-$api"; kind=$kind; policy='default'; api=$api; mode=1; order='single'; rejectOld=$false; fresh=$fresh})
    } }
    foreach ($kind in 'empty-lh0','empty-lh5') { foreach ($order in 'good-first','good-last') {
        $cases.Add([pscustomobject]@{label="$kind-$order-$api"; kind=$kind; policy='default'; api=$api; mode=1; order=$order; rejectOld=$false})
    } }
    foreach ($kind in 'tail','prefix','zip') { foreach ($policy in 'default','jsg1','jsg0') {
        $cases.Add([pscustomobject]@{label="$kind-$policy-$api"; kind=$kind; policy=$policy; api=$api; mode=1; order='single'; rejectOld=$false})
    } }
    foreach ($mode in 0,1,2) {
        $cases.Add([pscustomobject]@{label="normal-n$mode-$api"; kind='normal'; policy='default'; api=$api; mode=$mode; order='single'; rejectOld=$false})
        foreach ($order in 'good-first','good-last') {
            $cases.Add([pscustomobject]@{label="$order-n$mode-$api"; kind='tail'; policy='default'; api=$api; mode=$mode; order=$order; rejectOld=$false})
        }
    }
    $cases.Add([pscustomobject]@{label="reject-old-$api"; kind='tail'; policy='default'; api=$api; mode=1; order='single'; rejectOld=$true})
}
if ($cases.Count -ne 117) { throw '形式判定の計画件数が不正です' }
if ($CaseLabels.Count) {
    if (@($CaseLabels | Sort-Object -Unique).Count -ne $CaseLabels.Count) { throw '重複したラベルです' }
    foreach ($label in $CaseLabels) { if ($label -cnotin $cases.label) { throw "未知のラベルです: $label" } }
    $cases = @($cases | Where-Object { $_.label -cin $CaseLabels })
}
$oldBytes = [IO.File]::ReadAllBytes($Seed)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$emptyBytes = [IO.File]::ReadAllBytes($inputs['empty-lh5'])
if ($emptyBytes[20] -ne 1 -or [BitConverter]::ToUInt32($emptyBytes,11) -ne 0 -or $oldBytes[-1] -ne 0) {
    throw '終端対照の入力形式が不正です'
}
# level-1 の packed は拡張ヘッダーも含む。本文直後の終端位置から残り 20/21/22 バイトを作る。
$emptyEnd = [int]$emptyBytes[0]+2+[BitConverter]::ToUInt32($emptyBytes,7)
foreach ($kind in 'empty','data') { foreach ($remaining in 20,21,22) {
    $sourceBytes = if ($kind -eq 'empty') { $emptyBytes } else { $oldBytes }
    $end = if ($kind -eq 'empty') { $emptyEnd } else { $oldBytes.Length-1 }
    $bytes = [byte[]]::new($end+$remaining)
    [Array]::Copy($sourceBytes,$bytes,$end)
    $label = "$kind-tail$remaining"
    $inputs[$label] = Join-Path $Workspace "$label.lzh"
    [IO.File]::WriteAllBytes($inputs[$label],$bytes)
} }
$hashes = @{}
foreach ($path in @($TestProgram,$runner,$Oracle,$Candidate,$PSCommandPath)+@($inputs.Values)) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash
}
$cases | Export-Csv -LiteralPath (Join-Path $Workspace 'plan.tsv') -Delimiter "`t" -NoTypeInformation
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'environment.json')
$count = 0
try {
    foreach ($case in $cases) {
        $rejected = $case.kind -eq 'zip' -or ($case.kind -in @('tail','prefix') -and $case.policy -ne 'jsg0')
        $snapshots = @{}; $archives = @{}; $retries = @{}
        foreach ($side in 'oracle','candidate') {
            # ANSI の返却長も比較できるよう、左右の絶対パスを同じ文字数にする。
            $sideDirectory = if ($side -eq 'oracle') { 'oracle' } else { 'reimpl' }
            $folder = Join-Path $Workspace "$($case.label)/$sideDirectory"
            $tempDirectory = Join-Path $folder 'temp'
            New-Item -ItemType Directory -Path $tempDirectory | Out-Null
            $archive = Join-Path $folder 'joined.lzh'
            $source = Join-Path $folder 'source.lzh'
            $good = Join-Path $folder 'good.lzh'
            $retry = Join-Path $folder 'retry.lzh'
            if (!$case.fresh) { Copy-Item -LiteralPath $Seed -Destination $archive }
            Copy-Item -LiteralPath $Seed -Destination $good
            Copy-Item -LiteralPath $inputs[$case.kind] -Destination $source
            $operands = if ($case.order -eq 'good-first') { @($good,$source) }
                elseif ($case.order -eq 'good-last') { @($source,$good) } else { @($source) }
            $line = 'j -gm1 -y1 -n' + $case.mode + ' '
            if ($case.policy -ne 'default') { $line += '-' + $case.policy + ' ' }
            $line += '"' + $archive + '" ' + (($operands | ForEach-Object { '"' + $_ + '"' }) -join ' ')
            # 通常表示の反復で原版が停止するため、再利用側は通知付きの表示抑止に固定する。
            $retryLine = 'j -gm1 -y1 -n1 "' + $retry + '" "' + $good + '"'
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $selection = if ($case.rejectOld) { '@reject' } else { '@accept' }
            $savedTemp = $env:TEMP; $savedTmp = $env:TMP
            $env:TEMP = $tempDirectory; $env:TMP = $tempDirectory
            Push-Location $folder
            try {
                $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --progress-sequence-probe `
                    $dll w64 1041 0 $case.api w64 $selection $line '@accept' $retryLine 2>&1 | ForEach-Object { "$_" })
                $exitCode = $LASTEXITCODE
            } finally { Pop-Location; $env:TEMP = $savedTemp; $env:TMP = $savedTmp }
            [IO.File]::WriteAllLines((Join-Path $folder 'probe.txt'),[string[]]$rows)
            $results = @($rows | Where-Object { $_ -match '^result=' })
            $expected = if ($rejected) { 32795 } else { 0 }
            if ($exitCode -ne 0 -or $results.Count -ne 2 -or $results[0] -cne "result=$expected" -or $results[1] -cne 'result=0') {
                throw "拒否・許可または同じ DLL の再利用が不正です: $($case.label)/$side"
            }
            $temporaries = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp')
            if ($rejected -and $side -eq 'oracle') {
                # 原版の危険な副作用は専用コピーだけで観測し、候補の期待値へ持ち込まない。
                if ((Test-Path -LiteralPath $archive) -or $temporaries.Count -ne 1 -or
                    (Get-FileHash -LiteralPath $temporaries[0].FullName).Hash -cne $hashes[$Seed]) {
                    throw "原版の拒否時ファイル状態が既知の条件と違います: $($case.label)"
                }
            } else {
                if (!(Test-Path -LiteralPath $archive) -or $temporaries.Count) { throw '候補の旧書庫保持または一時書庫解放が不正です' }
                $archives[$side] = (Get-FileHash -LiteralPath $archive).Hash
                if ($rejected -and $archives[$side] -cne $hashes[$Seed]) { throw '拒否された既存書庫が変更されました' }
                if (!$rejected -and !$case.fresh) {
                    $bytes = [IO.File]::ReadAllBytes($archive)
                    if ($bytes.Length -lt $oldBytes.Length -or
                        [Convert]::ToHexString([byte[]]$bytes[0..($oldBytes.Length-2)]) -cne
                        [Convert]::ToHexString([byte[]]$oldBytes[0..($oldBytes.Length-2)])) { throw '許可時に旧項目が変化しました' }
                }
            }
            foreach ($path in @($source,$good,$retry) + @($archive | Where-Object { Test-Path -LiteralPath $_ })) {
                $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
                $stream.Dispose()
            }
            if ((Get-FileHash -LiteralPath $source).Hash -cne $hashes[$inputs[$case.kind]] -or
                (Get-FileHash -LiteralPath $good).Hash -cne $hashes[$Seed]) { throw '連結元が変更されました' }
            $retries[$side] = (Get-FileHash -LiteralPath $retry).Hash
            $snapshots[$side] = @($rows | ForEach-Object {
                $row = $_
                if ($row -match '^progress\.entry=.*?,state=5,') {
                    if ($side -eq 'candidate' -and !$row.Contains(',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source=')) {
                        throw '候補の SEARCH 通知が初期化されていません'
                    }
                    # 原版の未使用数値欄だけを除き、名前・宛先・通知順は比較する。
                    $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source='
                }
                $row.Replace($folder.Replace('\','/'),'<ROOT>').Replace($folder.Replace('\','\\'),'<ROOT>') `
                    -replace 'source=path="LHT[0-9A-Fa-f]+\.tmp"','source=path="LHT<TEMP>.tmp"'
            })
        }
        $difference = @(Compare-Object $snapshots.oracle $snapshots.candidate -SyncWindow 0)
        if ($difference.Count -or $retries.oracle -cne $retries.candidate -or (!$rejected -and $archives.oracle -cne $archives.candidate)) {
            $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$($case.label).diff.tsv") -Delimiter "`t" -NoTypeInformation
            throw "既存連結の通知・ログ・状態・許可書庫が一致しません: $($case.label)`n$($difference | Select-Object -First 5 | Out-String -Width 2000)"
        }
        ++$count
        if ($count % 12 -eq 0) { Write-Host "Existing foreign join: $count comparisons passed" }
    }
    Write-Host "Existing foreign join: $count comparisons/reuse sequences passed, with separate candidate archive-retention and input/release guards"
} finally {
    foreach ($path in $hashes.Keys) { if ((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]) { throw "検証資産が変化しました: $path" } }
}
