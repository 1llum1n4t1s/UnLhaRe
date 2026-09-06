[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate,$Seed) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Initial command headers environment: $path, SHA256=$($hashes[$path])"
}
$seedData = [IO.File]::ReadAllBytes($Seed)
if ($seedData.Length -lt 35 -or $seedData[20] -ne 0 -or $seedData[0] -ne 32) {
    throw 'member.txt の level-0 対照書庫を指定してください'
}
$inputs = [ordered]@{ empty=[byte[]]@() }
foreach ($length in 1,2,20,21,22,256) { $inputs["zero-$length"] = [byte[]]::new($length) }
foreach ($length in 1,2,3,7,8,15,20,21,22) {
    $bytes = [byte[]]::new($length)
    [Array]::Fill($bytes,[byte]73)
    $inputs["nonzero-$length"] = $bytes
}
foreach ($length in 1,2,3,7,8,15,20,21,22,($seedData[0]+1)) {
    $inputs["prefix-$length"] = [byte[]]$seedData[0..($length-1)]
}
$inputs['valid'] = $seedData
$inputs['garbage-3-valid'] = [byte[]](@(1,1,1)+$seedData)
$inputs['garbage-21-valid'] = [byte[]]($inputs['nonzero-21']+$seedData)
$inputs['zero-16-valid'] = [byte[]]([byte[]]::new(16)+$seedData)
if ($inputs.Count -ne 30) { throw '先頭ヘッダーの入力数が違います' }
$stateNames = @('empty','zero-1','zero-22','nonzero-1','nonzero-21','prefix-3','prefix-21','prefix-33','valid','garbage-3-valid','garbage-21-valid','zero-16-valid')
$cases = [Collections.Generic.List[object]]::new()
foreach ($name in $inputs.Keys) {
    foreach ($operation in 'l','v','t','p') { foreach ($api in 'legacy','A','W') {
        foreach ($capacity in 1,256,4096) {
            $cases.Add([pscustomobject]@{name=$name;operation=$operation;api=$api;capacity=$capacity;selected=1;label="$name-$operation-$api-raw-$capacity"})
        }
        if ($name -in $stateNames) { foreach ($selected in 1,0) {
            $cases.Add([pscustomobject]@{name=$name;operation=$operation;api=$api;capacity=0;selected=$selected;label="$name-$operation-$api-state-$selected"})
        } }
    } }
}
if ($cases.Count -ne 1368) { throw '先頭ヘッダーの比較条件数が違います' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Initial command headers workspace: $Workspace"
$stamps = @{}
foreach ($name in $inputs.Keys) {
    $archive = Join-Path $Workspace "$name.lzh"
    [IO.File]::WriteAllBytes($archive,$inputs[$name])
    $hashes[$archive] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    $stamps[$archive] = [IO.File]::GetLastWriteTimeUtc($archive)
}
$observations = [Collections.Generic.List[object]]::new()
$keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
try {
    foreach ($case in $cases) {
        if (!$keys.Add($case.label)) { throw '先頭ヘッダーの条件名が重複しています' }
        $archive = Join-Path $Workspace "$($case.name).lzh"
        $line = $case.operation + ' -gm1 -n0 "' + $archive + '" "*"'
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $arguments = if ($case.capacity -gt 0) {
                @('--registry','','--command-raw-probe',$dll,$line,$case.api,$case.capacity,'utf8')
            } else {
                @('--registry','','--command-enum-probe',$dll,$line,'w64',$case.selected,'',1041,1,$case.api,1)
            }
            # 原版のダイアログとレジストリー変更は隔離し、入力書庫は両側で共用する。
            $rows = @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $Workspace "$($case.label).$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) { throw "コマンドが異常終了しました: $($case.label)/$side/exit=$code" }
            $valid = $case.name -eq 'valid' -or $case.name.EndsWith('-valid')
            $expected = if ($valid) { 0 } else { 32795 }
            if ($case.capacity -gt 0) {
                if ($rows.Count -ne 1 -or $rows[0] -notmatch "^result=$expected,error=$expected,system=38,raw=") {
                    throw "先頭ヘッダーの戻り値が違います: $($case.label)/$side"
                }
                $units = @((($rows[0] -split 'raw=',2)[1]).TrimEnd(',').Split(','))
                $guard = if ($case.api -eq 'W') { 'cccc' } else { 'cc' }
                if ($units.Count -ne $case.capacity+16 -or @($units[0..7] -cne $guard).Count -or
                    @($units[($case.capacity+8)..($case.capacity+15)] -cne $guard).Count) {
                    throw "出力バッファのガードが変化しました: $($case.label)/$side"
                }
            } elseif ($rows -notcontains "result=$expected" -or $rows -notcontains "compat-error=$expected") {
                throw "先頭ヘッダーの通知時戻り値が違います: $($case.label)/$side"
            }
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hashes[$archive] -or
                [IO.File]::GetLastWriteTimeUtc($archive) -ne $stamps[$archive]) { throw '入力書庫が変更されました' }
            $snapshots += ,$rows
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        $observations.Add([pscustomobject]@{name=$case.label;differences=$difference.Count})
        if ($difference.Count) {
            $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$($case.label).diff.tsv") -Delimiter "`t" -NoTypeInformation
            throw "先頭ヘッダーのログ・生バッファ・状態・通知が一致しません: $($case.label)"
        }
        if ($observations.Count % 48 -eq 0) { Write-Host "Initial command headers: $($observations.Count) comparisons passed" }
    }
} finally {
    $observations | Export-Csv -LiteralPath (Join-Path $Workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "検証資産が変化しました: $path" }
    }
}
Write-Host "Initial command headers: $($inputs.Count) fixtures, $($observations.Count) exact output/guard/state/enum/progress comparisons compatible"
