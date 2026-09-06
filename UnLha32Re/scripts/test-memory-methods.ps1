[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Fixtures,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
# test-pmarc-check.ps1 が作成した同じ入力を使い、生成処理を重複させない。
$Fixtures = (Resolve-Path -LiteralPath $Fixtures).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
$files = @('literal/lh0-0.lzh','literal/lh0-9.lzh')
foreach ($method in 'pm0','pm2') {
    $files += "literal/$method-0.lzh","literal/$method-9.lzh"
    foreach ($position in 'first','middle','last','embedded-large') { $files += "mixed/$method-$position.lzh" }
    foreach ($variant in 'missing-body-byte','under-declared','padding16') { $files += "boundary/$method-9-$variant.lzh" }
}
$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Memory methods environment: $path, SHA256=$($hashes[$path])"
}
foreach ($name in $files) {
    $path = Join-Path $Fixtures $name
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Memory methods workspace: $Workspace"
$observations = [Collections.Generic.List[object]]::new()

function Compare-MemoryCase([string]$Archive,[string]$Name,[string]$Profile) {
    $before = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    $label = [IO.Path]::GetFileNameWithoutExtension($Name.Replace('/','-'))
    $traceRoot = Join-Path $Workspace "$label-$Profile"
    New-Item -ItemType Directory -Path $traceRoot | Out-Null
    $expectedKeys = if ($Profile -eq 'progress') {
        @('workflow.0.implicit.1','workflow.0.implicit.8192','workflow.1.implicit.1','workflow.1.implicit.8192')
    } else {
        @('memory.0.0.8','memory.1.0.8','memory.2.0.8','memory.0.3.8','memory.1.3.8','memory.2.3.8')
    }
    $recordPattern = if ($Profile -eq 'progress') { '^workflow\.[01]\.implicit\.(1|8192)=' } else { '^memory\.[012]\.[03]\.8=' }
    $tracePattern = if ($Profile -eq 'progress') {
        '^workflow\.([01]\.implicit\.(1|8192)=|member=|progress=)'
    } else { '^memory\.([012]\.[03]\.8=|member=)' }
    $snapshots = @()
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @()
        $conditions = @(@('0','8'),@('3','8'))
        if ($Profile -eq 'progress') { $conditions = ,@() }
        foreach ($condition in $conditions) {
            # I によるメモリ出力だけを実行する。表示・実 HKCU・元書庫の更新を隔離する。
            # 一致／不一致選択ごとに DLL を開始する限定試験で、長時間の連続試験ではない。
            $arguments = if ($Profile -eq 'progress') {
                @('--registry','','--memory-workflow-probe',$dll,$Archive,$traceRoot,'progress','implicit')
            } else { @('--registry','','--memory-selection-case-probe',$dll,$Archive,$Profile)+$condition }
            $rows += @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            if ($code -ne 0) { break }
        }
        [IO.File]::WriteAllLines((Join-Path $traceRoot "$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
        $records = @($rows -match $recordPattern)
        if ($code -ne 0 -or $records.Count -ne $expectedKeys.Count -or
            @($records -notmatch ',guard=1(?:,|$)').Count -or @($rows -notmatch $tracePattern).Count) {
            throw "メモリ検証が異常終了しました: $Name/$Profile/$side/exit=$code/records=$($records.Count)"
        }
        for ($i=0; $i -lt $expectedKeys.Count; $i++) {
            if ($records[$i].Split('=')[0] -cne $expectedKeys[$i]) { throw 'API・選択・容量の記録順序が違います' }
        }
        if ((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash -cne $before) { throw '参照書庫が変更されました' }
        $snapshots += ,$rows
    }
    # DLL が返す時刻・残量・エラー・通知の内容と順序を除外せず比較する。
    $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if ($difference.Count) {
        throw "メモリの戻り値・メタデータ・通知が一致しません: $Name/$Profile`n$($difference | Select-Object -First 12 | Out-String -Width 2000)"
    }
    $observations.Add([pscustomobject]@{ file=$Name; profile=$Profile; sha256=$before; records=$expectedKeys.Count })
    $observations | Export-Csv -LiteralPath (Join-Path $Workspace 'comparisons.tsv') -Delimiter "`t" -NoTypeInformation -Encoding utf8
    return $expectedKeys.Count
}

try {
    $methodRecords = 0
    foreach ($name in $files) {
        foreach ($profile in 'none','w64','reject','rename','progress') {
            $methodRecords += Compare-MemoryCase (Join-Path $Fixtures $name) $name $profile
        }
        Write-Host "Memory methods: $name, $methodRecords return records and callbacks matched"
    }
    if ($observations.Count -ne 100 -or $methodRecords -ne 560) { throw '方式別メモリ検証の件数が違います' }

    $tails = [ordered]@{ empty=[byte[]]@() }
    foreach ($length in 1,2,20,21) { $tails["zero-$length"] = [byte[]]::new($length) }
    foreach ($length in 1,2,3,7,8,15,20) {
        $data = [byte[]]::new($length)
        [Array]::Fill($data,[byte]73)
        $tails["nonzero-$length"] = $data
    }
    foreach ($length in 21,22) {
        $data = [byte[]]::new($length)
        [Array]::Fill($data,[byte]73)
        $data[20] = 4
        $tails["unknown-level-$length"] = $data
    }
    $tails['valid-next'] = [IO.File]::ReadAllBytes((Join-Path $Fixtures 'literal/lh0-9.lzh'))
    $tailRoot = Join-Path $Workspace 'tail-fixtures'
    New-Item -ItemType Directory -Path $tailRoot | Out-Null
    $tailRecords = 0
    foreach ($method in 'lh0','pm0','pm2') {
        $source = [IO.File]::ReadAllBytes((Join-Path $Fixtures "literal/$method-9.lzh"))
        if ($source.Length -lt 26 -or $source[20] -ne 0 -or $source[-1] -ne 0) { throw 'level-0 の単一項目書庫が必要です' }
        $member = [byte[]]$source[0..($source.Length-2)]
        foreach ($name in $tails.Keys) {
            $archive = Join-Path $tailRoot "$method-$name.lzh"
            [IO.File]::WriteAllBytes($archive,[byte[]]($member+$tails[$name]))
            $hashes[$archive] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            $tailRecords += Compare-MemoryCase $archive "tail/$method-$name.lzh" 'w64'
        }
        Write-Host "Memory header tails: $method, $tailRecords return records and callbacks matched"
    }
    if ($observations.Count -ne 145 -or $tailRecords -ne 270) { throw '短いヘッダーの検証件数が違います' }
    Write-Host "Memory methods: 20 archives/100 profiles/560 returns and 45 header-tail archives/270 returns; all 830 records and callback traces match original"
} finally {
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
            throw "検証中に実行ファイルまたは入力書庫が変更されました: $path"
        }
    }
}
