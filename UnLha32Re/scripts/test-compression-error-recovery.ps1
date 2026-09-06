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
Write-Host "Compression error recovery workspace: $Workspace"
$seedSource = Join-Path $Workspace 'seed.txt'
[IO.File]::WriteAllText($seedSource,'defined header state',[Text.UTF8Encoding]::new($false))
[IO.File]::SetLastWriteTimeUtc($seedSource,[datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc))
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedRows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h0 -gm1 -y1 `"$seedArchive`" `"$Workspace\`" seed.txt" A)
if ($LASTEXITCODE -ne 0 -or $seedRows -notcontains 'result=0') { throw '既知の通知情報を持つ書庫の作成に失敗しました' }
$count = 0
foreach ($layout in 'a32','w32','a64','w64') { foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') {
    $label = "$layout/$locale/$utf8/$api"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ('case-{0:D3}-{1}' -f $count,$side)
        New-Item -ItemType Directory -Path $root | Out-Null
        foreach ($name in 'a.txt','empty.txt') {
            $path = Join-Path $root $name
            $payload = if ($name -eq 'a.txt') { 'abcdefghijklmnopqrstuvwxyz' * 200 } else { '' }
            [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
            $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($path,$time)
            [IO.File]::SetLastWriteTimeUtc($path,$time)
            [IO.File]::SetLastAccessTimeUtc($path,$time)
        }
        $steps = @(
            @{ Command='a'; Method='jm0'; Input='a.txt'; Name='stored' },
            @{ Command='a'; Method='jm2'; Input='empty.txt'; Name='empty' },
            @{ Command='f'; Method='jm0'; Input='a.txt'; Name='missing' },
            @{ Command='a'; Method='jm0'; Input='a.txt'; Name='after-failure' },
            @{ Command='a'; Method='jm2'; Input='a.txt'; Name='compressed' },
            @{ Command='a'; Method='jm0'; Input='a.txt'; Name='after-eof' },
            @{ Command='m'; Method='jm2'; Input='empty.txt'; Name='moved-empty' },
            @{ Command='a'; Method='jm0'; Input='a.txt'; Name='after-move' }
        )
        # 原版の新規登録直後の数値は未初期化。既知ヘッダーを読んでから連続動作を比較する。
        $operations = @("@count:$seedArchive")
        $base = "`"$($root.Replace('\','/'))/`""
        foreach ($step in $steps) {
            $archive = Join-Path $root "$($step.Name).lzh"
            $operations += "$($step.Command) -$($step.Method) -h0 -n1 -gm1 -y1 `"$archive`" $base $($step.Input)"
            if ($step.Command -ne 'f') { $operations += "@check:$archive" }
        }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll $layout $locale $utf8 $api @operations)
        if ($LASTEXITCODE -ne 0) { throw "圧縮最終状態の連続試験が異常終了しました: $label/$side" }
        [IO.File]::WriteAllLines((Join-Path $root 'commands.txt'),$rows)
        $returned = @($rows | Where-Object { $_ -match '^result=' }) -join ','
        $systems = @($rows | Where-Object { $_ -match '^compat-system-error=' }) -join ','
        if ($returned -cne 'result=0,result=0,result=32809,result=0,result=0,result=0,result=0,result=0' -or
            $systems -cne 'compat-system-error=18,compat-system-error=0,compat-system-error=2,compat-system-error=18,compat-system-error=38,compat-system-error=18,compat-system-error=18,compat-system-error=18' -or
            @($rows | Where-Object { $_ -eq 'check=1' }).Count -ne 7 -or
            (Test-Path -LiteralPath (Join-Path $root 'missing.lzh')) -or
            (Test-Path -LiteralPath (Join-Path $root 'empty.txt')) -or
            -not (Test-Path -LiteralPath (Join-Path $root 'a.txt'))) {
            throw "圧縮最終状態・失敗後の再利用・移動結果が想定と違います: $label/$side`n$($rows -join "`n")"
        }
        $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "圧縮最終状態の連続通知・ログが一致しません: $label`n$($difference | Select-Object -First 6 | Out-String -Width 2000)" }
    $count++
} }
Write-Host "Compression error recovery: $layout/$locale, $count sequences passed"
} }
Write-Host "Compression error recovery: $count retained-DLL stored/empty/failed/compressed/moved command sequences, CRC checks, and state resets passed"
