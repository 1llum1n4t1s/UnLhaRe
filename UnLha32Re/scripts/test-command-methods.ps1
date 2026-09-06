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
# test-pmarc-check.ps1 の入力を共用する。PM2 は非対応判定用の任意本文である。
$Fixtures = (Resolve-Path -LiteralPath $Fixtures).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw '新しい検証用ディレクトリーを指定してください' }
if (!(Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'DesktopRunner が必要です' }
$cases = [Collections.Generic.List[object]]::new()
$literal = @('literal/lh0-0.lzh','literal/lh0-9.lzh','literal/pm0-0.lzh','literal/pm0-9.lzh','literal/pm2-0.lzh','literal/pm2-9.lzh')
$files = @($literal)
foreach ($method in 'pm0','pm2') {
    foreach ($position in 'first','middle','last') { $files += "mixed/$method-$position.lzh" }
}
foreach ($operation in 'p','t') {
    foreach ($file in $literal) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($file.Replace('/','-'))
        foreach ($profile in 'none','w64','reject') {
            foreach ($selection in 'match','missing') {
                $cases.Add([pscustomobject]@{
                    name="selection-$operation-$stem-$profile-$selection"; file=$file
                    operation=$operation; api='W'; profile=$profile; mode=$null
                    pattern=$(if ($selection -eq 'match') { '*' } else { 'missing' }); capacity=0
                })
            }
        }
    }
    foreach ($file in $files) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($file.Replace('/','-'))
        foreach ($api in 'legacy','A','W') {
            foreach ($profile in 'plain','progress','raw-1','raw-64','raw-256') {
                if ($file.StartsWith('mixed/') -and $profile.StartsWith('raw-')) { continue }
                $cases.Add([pscustomobject]@{
                    name="boundary-$operation-$stem-$api-$profile"; file=$file
                    operation=$operation; api=$api; profile=$profile
                    mode=$(if ($profile -eq 'progress') { 1 } else { 0 }); pattern='*'
                    capacity=$(if ($profile.StartsWith('raw-')) { [int]$profile.Substring(4) } else { 0 })
                })
            }
        }
    }
}
# 整形前のログが最終 NUL の後に残らないことを、呼び出し元の未使用領域も含めて確認する。
foreach ($operation in 'l','v','t') {
    foreach ($mode in 0,1) {
        foreach ($api in 'legacy','A','W') {
            foreach ($capacity in 1,256,512,4096) {
                $cases.Add([pscustomobject]@{
                    name="tail-$operation-n$mode-$api-$capacity"; file='literal/lh0-9.lzh'
                    operation=$operation; api=$api; profile='raw'; mode=$mode; pattern='*'; capacity=$capacity
                })
            }
        }
    }
}
if ($cases.Count -ne 396) { throw 'コマンドの比較条件数が違います' }
$keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$hashes = @{}
foreach ($path in $TestProgram,$runner,$Oracle,$Candidate) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Command methods environment: $path, SHA256=$($hashes[$path])"
}
foreach ($file in $files) {
    $path = Join-Path $Fixtures $file
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Command methods workspace: $Workspace"
$observations = [Collections.Generic.List[object]]::new()
try {
    foreach ($case in $cases) {
        if (!$keys.Add($case.name)) { throw 'コマンド条件名が重複しています' }
        $archive = Join-Path $Fixtures $case.file
        $line = $case.operation + ' -gm1 '
        if ($null -ne $case.mode) { $line += '-n' + $case.mode + ' ' }
        $line += '"' + $archive + '" "' + $case.pattern + '"'
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $arguments = if ($case.capacity -gt 0) {
                @('--registry','','--command-raw-probe',$dll,$line,$case.api,$case.capacity,'utf8')
            } else {
                $layout = if ($case.profile -eq 'none') { 'none' } else { 'w64' }
                $selected = if ($case.profile -eq 'reject') { '0' } else { '1' }
                $progress = if ($case.profile -eq 'progress') { '1' } else { '0' }
                @('--registry','','--command-enum-probe',$dll,$line,$layout,$selected,'',1041,1,$case.api,$progress)
            }
            # 読み取りと出力バッファだけを扱い、実 HKCU・ユーザーデスクトップを使わない。
            $rows = @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $Workspace "$($case.name).$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) {
                throw "コマンドが異常終了しました: $($case.name)/$side/exit=$code"
            }
            if ($case.capacity -gt 0) {
                if ($rows.Count -ne 1 -or $rows[0] -notmatch ',raw=') { throw '生バッファの記録がありません' }
                $units = @((($rows[0] -split 'raw=',2)[1]).TrimEnd(',').Split(','))
                $guard = if ($case.api -eq 'W') { 'cccc' } else { 'cc' }
                if ($units.Count -ne $case.capacity+16 -or @($units[0..7] -cne $guard).Count -or
                    @($units[($case.capacity+8)..($case.capacity+15)] -cne $guard).Count) {
                    throw "出力バッファのガードが変化しました: $($case.name)/$side"
                }
            }
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $hashes[$archive]) { throw '参照書庫が変更されました' }
            $snapshots += ,$rows
        }
        # 通知順・エラー・終端後を含む出力を省略せず、同じ原版入力と比較する。
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) {
            throw "コマンドの表示・通知・バッファが一致しません: $($case.name)`n$($difference | Select-Object -First 8 | Out-String -Width 2000)"
        }
        $observations.Add([pscustomobject]@{ name=$case.name; file=$case.file; sha256=$hashes[$archive] })
        $observations | Export-Csv -LiteralPath (Join-Path $Workspace 'comparisons.tsv') -Delimiter "`t" -NoTypeInformation -Encoding utf8
        if ($observations.Count % 24 -eq 0) { Write-Host "Command methods: $($observations.Count) exact original comparisons passed" }
    }
    Write-Host 'Command methods: 324 PMarc/LH0 print/test and 72 list/test raw-tail comparisons passed; all 396 returns, buffers, and callback traces match original'
} finally {
    foreach ($path in $hashes.Keys) {
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
            throw "検証中に実行ファイルまたは入力書庫が変更されました: $path"
        }
    }
}
