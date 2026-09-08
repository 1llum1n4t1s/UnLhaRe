[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Commands = @('a','u','f','m'),
    [string[]]$Layouts = @('none','a32','w32','a64','w64'),
    [int[]]$Locales = @(1033,1041),
    [int[]]$UnicodeModes = @(0,1),
    [string[]]$Apis = @('legacy','A','W'),
    [string[]]$Variants = @(),
    [switch]$NewArchive
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression sharing workspace: $Workspace"
function Set-SharingFixture([string]$Path, [string]$Value, [int]$Year) {
    [IO.File]::WriteAllBytes($Path,[Text.Encoding]::ASCII.GetBytes($Value))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}
function Normalize-SharingRows($Rows, [string]$Root) {
    @($Rows | ForEach-Object {
        $_.Replace($Root.Replace('\','/'),'<ROOT>').Replace($Root.Replace('\','\\'),'<ROOT>')
    })
}
$seedDirectory = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedDirectory | Out-Null
foreach ($name in 'a.txt','z.txt') { Set-SharingFixture (Join-Path $seedDirectory $name) "old-$name-value" 2020 }
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedCommand = "a -h0 -n1 -gm1 -y1 -c1 `"$seedArchive`" `"$seedDirectory\`" a.txt z.txt"
$seedRows = @(& $TestProgram --registry '' --command-probe $Oracle $seedCommand)
if ($LASTEXITCODE -ne 0 -or $seedRows -notcontains 'result=0') { throw '共有試験の元書庫を作成できません。' }
$seedHash = (Get-FileHash -LiteralPath $seedArchive -Algorithm SHA256).Hash
$cases = @(
    @{ Name='exclusive-first'; Share=[IO.FileShare]::None; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options=''; Failure=$true },
    @{ Name='exclusive-last'; Share=[IO.FileShare]::None; Access=[IO.FileAccess]::ReadWrite; Locked='z.txt'; Options=''; Failure=$true },
    @{ Name='reader-shared'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::Read; Locked='a.txt'; Options='-jso1' },
    @{ Name='writer-shared'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='' },
    @{ Name='writer-strict'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso1'; Failure=$true },
    @{ Name='writer-reenabled'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso1 -jso0' },
    @{ Name='writer-toggle'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso'; Failure=$true },
    @{ Name='writer-toggle-twice'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso -jso' },
    @{ Name='writer-two-twice'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso2 -jso2' },
    @{ Name='writer-multi-digit'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso10'; Failure=$true },
    @{ Name='redirect-exclusive'; Share=[IO.FileShare]::None; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options=''; Redirect=$true },
    @{ Name='redirect-strict'; Share=[IO.FileShare]::Read; Access=[IO.FileAccess]::ReadWrite; Locked='a.txt'; Options='-jso1'; Redirect=$true }
)
if ($Variants.Count) { $cases = @($cases | Where-Object Name -in $Variants) }
if (-not $cases.Count) { throw '共有試験の条件がありません。' }
$count = 0
foreach ($case in $cases) { foreach ($commandName in $Commands) { foreach ($layout in $Layouts) {
    # 新規作成時の未初期化列挙情報は一致対象外。ここでは通知なしで原子性を検証する。
    if ($NewArchive -and ($commandName -eq 'f' -or $layout -ne 'none')) { continue }
    # 失敗停止は全レイアウト、共有フラグの組み合わせは無登録と W64 で検証する。
    if ($case.Name -ne 'exclusive-first' -and $layout -notin 'none','w64') { continue }
    if ($case.Redirect -and ($layout -eq 'none' -or $commandName -eq 'm')) { continue }
    foreach ($locale in $Locales) { foreach ($unicode in $UnicodeModes) { foreach ($api in $Apis) {
        $label = "$($case.Name)/$commandName/$layout/$locale/$unicode/$api"
        $results = @()
        foreach ($side in 'oracle','reimpl') {
            $root = Join-Path $Workspace ("case-{0:D4}-$side" -f $count)
            $inputDirectory = Join-Path $root 'input'
            New-Item -ItemType Directory -Path $inputDirectory | Out-Null
            foreach ($name in 'a.txt','z.txt') { Set-SharingFixture (Join-Path $inputDirectory $name) "new-$name-updated-value" 2024 }
            $archive = Join-Path $root 'result.lzh'
            if (-not $NewArchive) { Copy-Item -LiteralPath $seedArchive -Destination $archive }
            $replacement = ''
            if ($case.Redirect) {
                $replacement = Join-Path $root 'replacement.txt'
                Set-SharingFixture $replacement 'redirected-value' 2024
            }
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $command = "$commandName -h2 -n1 -gm1 -y1 -c1 $($case.Options) `"$archive`" `"$($inputDirectory.Replace('\','/'))/`" a.txt z.txt"
            $share = $case.Share
            # m の圧縮成功後の削除失敗は別契約。この試験では成功時の削除を許可する。
            if ($commandName -eq 'm' -and -not $case.Failure) { $share = $share -bor [IO.FileShare]::Delete }
            $holder = [IO.File]::Open((Join-Path $inputDirectory $case.Locked),[IO.FileMode]::Open,$case.Access,$share)
            try {
                $rows = @(& $TestProgram --registry '' --command-enum-probe $dll $command $layout 1 $replacement $locale $unicode $api 0)
                if ($LASTEXITCODE -ne 0) { throw "共有試験のプロセスが異常終了しました: $label/$side" }
            } finally { $holder.Dispose() }
            $expectedResult = if ($case.Failure) { 32816 } else { 0 }
            $expectedSystem = if ($case.Failure) { 32 } elseif ($commandName -eq 'm') { 18 } else { 38 }
            if ($rows -notcontains "result=$expectedResult" -or
                $rows -notcontains "compat-error=$expectedResult" -or
                $rows -notcontains "compat-system-error=$expectedSystem") {
                throw "共有制御の戻り値が違います: $label/$side`n$($rows -join "`n")"
            }
            if ($case.Failure) {
                if ($NewArchive) {
                    if (Test-Path -LiteralPath $archive) { throw "共有エラーで未完成書庫が残りました: $label/$side" }
                } elseif ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $seedHash) {
                    throw "共有エラーで書庫が部分更新されました: $label/$side"
                }
            }
            foreach ($name in 'a.txt','z.txt') {
                if (-not $case.Failure) {
                    $data = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`" $name" A)
                    $expected = if ($case.Redirect) { 'redirected-value' } else { "new-$name-updated-value" }
                    if ($LASTEXITCODE -ne 0 -or $data -notcontains 'result=0' -or $data -notcontains "output=`"$expected`"") {
                        throw "共有入力の圧縮内容が違います: $label/$side/$name`n$($data -join "`n")"
                    }
                    if ($side -eq 'reimpl') {
                        # 候補が生成した書庫を、候補自身のメモリ展開 API でも読み返す。
                        $readCommand = 'p -+ "' + $archive + '" ' + $name
                        $candidateData = @(& $TestProgram --registry '' --command-probe-a $Candidate $readCommand A)
                        $candidateDataExit = $LASTEXITCODE
                        if ($candidateDataExit -ne 0 -or $candidateData -notcontains 'result=0') {
                            throw "共有入力の圧縮内容を候補自身で読み取れません: $label/$side/$name"
                        }
                        $payloadDifference = @(Compare-Object $data $candidateData -CaseSensitive -SyncWindow 0)
                        if ($payloadDifference.Count) {
                            $details = $payloadDifference | Select-Object -First 8 | Out-String -Width 1500
                            throw ("候補が生成した共有書庫の自己読み出しが原版読み出しと一致しません: " +
                                $label + "/" + $name + [Environment]::NewLine + $details)
                        }
                    }
                }
                $source = Join-Path $inputDirectory $name
                $exists = Test-Path -LiteralPath $source
                $expectedExists = $case.Failure -or $commandName -ne 'm'
                if ($exists -ne $expectedExists -or ($exists -and [IO.File]::ReadAllText($source) -cne "new-$name-updated-value")) {
                    throw "共有入力の保持・削除が違います: $label/$side/$name"
                }
            }
            $results += ,@(Normalize-SharingRows $rows $root)
        }
        $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
        if ($difference.Count) {
            throw "共有入力の列挙・ログ・エラーが一致しません: $label`n$($difference | Select-Object -First 10 | Out-String -Width 2000)"
        }
        $count++
    } } }
} } }
if ($count -eq 0) { throw '有効な共有試験の条件がありません。' }
$operation = if ($NewArchive) { 'new' } else { 'existing' }
Write-Host "Compression sharing: $count $operation input-open, rollback, jso switches, callback redirection, data, and source-retention comparisons passed (jss deletion excluded)"
