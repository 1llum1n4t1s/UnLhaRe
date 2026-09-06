[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('new','replace','append')][string[]]$ArchiveStates = @('new','replace','append'),
    [string[]]$Methods = @('jm0','jm2')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression system-error workspace: $Workspace"
$seedRoot = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedRoot | Out-Null
foreach ($name in 'a.txt','e.txt','guard.txt') {
    $path = Join-Path $seedRoot $name
    [IO.File]::WriteAllText($path,"seed-$name",[Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc))
}
$seeds = @{}
foreach ($state in 'replace','append') {
    $seed = Join-Path $Workspace "seed-$state.lzh"
    $selection = if ($state -eq 'replace') { 'a.txt e.txt guard.txt' } else { 'guard.txt' }
    $rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h0 -gm1 -y1 `"$seed`" `"$seedRoot\`" $selection" A)
    if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw "元書庫の作成に失敗しました: $state" }
    $seeds[$state] = $seed
}
$cases = [ordered]@{ repeat='a.txt'; empty='e.txt'; lastempty='a.txt e.txt'; firstempty='e.txt a.txt' }
$configs = @(
    @{ Api='legacy'; Layout='a32'; Locale=1033; Utf8=0 },
    @{ Api='A'; Layout='w32'; Locale=1041; Utf8=1 },
    @{ Api='W'; Layout='a64'; Locale=1041; Utf8=0 },
    @{ Api='legacy'; Layout='w64'; Locale=1033; Utf8=1 },
    @{ Api='W'; Layout='w64'; Locale=1041; Utf8=1 }
)
$count = 0
foreach ($state in $ArchiveStates) { foreach ($method in $Methods) { foreach ($commandName in 'a','u','f','m') { foreach ($caseName in $cases.Keys) { foreach ($config in $configs) {
    $label = "$state/$method/$commandName/$caseName/$($config.Api)/$($config.Layout)"
    $missing = $state -eq 'new' -and $commandName -eq 'f'
    $expectedResult = if ($missing) { 32809 } else { 0 }
    $expectedSystem = if ($missing) { 2 }
        elseif ($commandName -eq 'm') { 18 }
        elseif ($state -eq 'replace' -or $commandName -eq 'f') { 38 }
        elseif ($caseName -in 'empty','lastempty' -or ($caseName -eq 'firstempty' -and $method -eq 'jm0')) { 0 }
        elseif ($method -eq 'jm0' -and $state -eq 'new') { 18 }
        else { 38 }
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($name in 'a.txt','e.txt') {
            $path = Join-Path $root $name
            $payload = if ($name -eq 'a.txt') { 'abcdefghijklmnopqrstuvwxyz' * 200 } else { '' }
            [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
            $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($path,$time)
            [IO.File]::SetLastWriteTimeUtc($path,$time)
            [IO.File]::SetLastAccessTimeUtc($path,$time)
        }
        $archive = Join-Path $root 'result.lzh'
        if ($state -ne 'new') { Copy-Item -LiteralPath $seeds[$state] -Destination $archive }
        $command = "$commandName -$method -h0 -n1 -gm1 -y1 -c1 `"$archive`" `"$($root.Replace('\','/'))/`" $($cases[$caseName])"
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        # 新規登録直後の原版の通知数値は未初期化なので、既知ヘッダーを先に読む。
        $operations = @("@count:$($seeds['replace'])",$command)
        if (-not $missing) { $operations += "@check:$archive" }
        $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll $config.Layout $config.Locale $config.Utf8 $config.Api @operations)
        if ($LASTEXITCODE -ne 0) { throw "システムエラー試験が異常終了しました: $label/$side" }
        [IO.File]::WriteAllLines((Join-Path $root 'commands.txt'),$rows)
        if (@($rows | Where-Object { $_ -eq "result=$expectedResult" }).Count -ne 1 -or
            @($rows | Where-Object { $_ -eq "compat-system-error=$expectedSystem" }).Count -ne 1 -or
            $rows -notcontains 'compat-error=0' -or (-not $missing -and $rows -notcontains 'check=1')) {
            throw "圧縮後の結果・システムエラーが想定と違います: $label/$side (expected $expectedResult/$expectedSystem)`n$($rows -join "`n")"
        }
        if ($missing -and (Test-Path -LiteralPath $archive)) { throw "失敗した f が新規書庫を作成しました: $label/$side" }
        foreach ($name in 'a.txt','e.txt') {
            $expectedExists = $commandName -ne 'm' -or ($cases[$caseName].Split(' ') -notcontains $name)
            if ((Test-Path -LiteralPath (Join-Path $root $name)) -ne $expectedExists) { throw "移動元の保持・削除が想定と違います: $label/$side/$name" }
        }
        $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "圧縮のログ・列挙・最終エラーが一致しません: $label`n$($difference | Select-Object -First 6 | Out-String -Width 2000)" }
    $count++
} } }
Write-Host "Compression system error: $state/$method, $count comparisons passed"
} }
Write-Host "Compression system error: $count command, empty-input/order, header-EOF, final-error, CRC-check, and source-retention comparisons passed"
