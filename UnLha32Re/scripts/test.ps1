[CmdletBinding()]
param(
    [switch]$CompareUpdatePolicyOracle,
    [ValidateSet('Full','Focused')][string]$CrcDialogCoverage = 'Full',
    [ValidateSet('Normal','Focused')][string]$CodecPayloadDisplay = 'Focused',
    [string]$WorkspaceRoot = '',
    [switch]$IsolatedChild
)

$ErrorActionPreference = 'Stop'
# 非表示デスクトップの子 PowerShell でも、日本語の診断ログを UTF-8 に統一する。
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$desktopRunner = Join-Path $repositoryRoot 'artifacts\Release\DesktopRunner.exe'
if (-not $IsolatedChild) {
    & (Join-Path $PSScriptRoot 'build.ps1') -Configuration Release
    $shell = (Get-Process -Id $PID).Path
    $childArguments = @('-NoProfile', '-File', $PSCommandPath, '-IsolatedChild')
    if ($CompareUpdatePolicyOracle) { $childArguments += '-CompareUpdatePolicyOracle' }
    if ($WorkspaceRoot) { $childArguments += @('-WorkspaceRoot', $WorkspaceRoot) }
    $childArguments += @('-CrcDialogCoverage', $CrcDialogCoverage)
    $childArguments += @('-CodecPayloadDisplay', $CodecPayloadDisplay)
    Write-Host 'Tests run on a separate, non-visible desktop.'
    & $desktopRunner $shell @childArguments
    if ($LASTEXITCODE -ne 0) { throw "隔離した検証に失敗しました (exit $LASTEXITCODE)。" }
    return
}
& $desktopRunner --require-isolated
if ($LASTEXITCODE -ne 0) { throw '検証用デスクトップの分離を確認できません。' }
& (Join-Path $PSScriptRoot 'test-progress-directory-normalization.ps1')

$candidate = Join-Path $repositoryRoot 'artifacts\Release\UNLHA32RE.dll'
$testProgram = Join-Path $repositoryRoot 'artifacts\Release\CompatibilityTests.exe'
$oracle = Join-Path $repositoryRoot 'sample\ulh3300_extracted\UNLHA32.DLL'
$fixtureRoot = Join-Path $repositoryRoot 'sample\lha-master\tests'
$fixtures = @(
    'lha-test16-l1.lzh',
    'lha-test16-l2.lzh',
    'lha-test16-lg.lzh',
    'lha-test20-cap.lzh',
    'lha-test20-euc.lzh',
    'lha-test20-sjis.lzh',
    'lha-test20-utf8.lzh'
)

if (-not (Test-Path -LiteralPath $testProgram)) {
    throw "互換性テストが見つかりません: $testProgram"
}

if (Test-Path -LiteralPath $oracle) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $installationPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $dumpbin = Get-ChildItem -LiteralPath (Join-Path $installationPath 'VC\Tools\MSVC') -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx86\x86\dumpbin.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if (-not $dumpbin) {
        throw 'x86 dumpbin.exe が見つかりません。'
    }

    function Get-Exports([string]$Path) {
        $exports = @()
        foreach ($line in (& $dumpbin /nologo /exports $Path)) {
            if ($line -match '^\s+(\d+)\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') {
                $exports += [pscustomobject]@{ Ordinal = [int]$Matches[1]; Name = $Matches[2] }
            }
        }
        return $exports
    }

    $expected = @(Get-Exports $oracle)
    $actual = @(Get-Exports $candidate)
    $missing = @($expected | Where-Object {
        $entry = $_
        -not ($actual | Where-Object { $_.Ordinal -eq $entry.Ordinal -and $_.Name -eq $entry.Name })
    })
    if ($missing.Count -ne 0) {
        $description = $missing | ForEach-Object { "$($_.Ordinal):$($_.Name)" }
        throw "元 DLL のエクスポートが不足しています: $($description -join ', ')"
    }
    Write-Host "Exports: all $($expected.Count) original name/ordinal pairs are present."

    $headers = & $dumpbin /nologo /headers $candidate
    if (-not ($headers -match '14C machine \(x86\)')) {
        throw '出力 DLL が x86 PE ではありません。'
    }
}

$version = (Get-Item -LiteralPath $candidate).VersionInfo
if ($version.FileMajorPart -ne 3 -or $version.FileMinorPart -ne 0 -or
    $version.FileBuildPart -ne 0 -or $version.FilePrivatePart -ne 5) {
    throw "互換バージョンリソースが不正です: $($version.FileVersion)"
}
Write-Host "PE/version: x86, $($version.FileVersion)"

foreach ($fixtureName in $fixtures) {
    $fixture = Join-Path $fixtureRoot $fixtureName
    if (-not (Test-Path -LiteralPath $fixture)) {
        throw "fixture が見つかりません: $fixture"
    }
    if (Test-Path -LiteralPath $oracle) {
        & $testProgram $candidate $fixture $oracle
    } else {
        & $testProgram $candidate $fixture | Out-Null
    }
    if ($LASTEXITCODE -ne 0) {
        throw "互換性スナップショットが不一致です: $fixtureName"
    }
    Write-Host "Snapshot: $fixtureName"
}

$enumFixture = Join-Path $fixtureRoot 'lha-test16-l1.lzh'
$candidateEnum = @(& $testProgram --enum-probe $candidate $enumFixture)
if ($LASTEXITCODE -ne 0 -or
    $candidateEnum -notcontains 'a32.count=1' -or
    $candidateEnum -notcontains 'w32.count=1' -or
    $candidateEnum -notcontains 'a64.count=1' -or
    $candidateEnum -notcontains 'w64.count=1') {
    throw '列挙コールバックの A/W・32/64 構造体テストに失敗しました。'
}
if (Test-Path -LiteralPath $oracle) {
    $oracleEnum = @(& $testProgram --enum-probe $oracle $enumFixture)
    if ($LASTEXITCODE -ne 0) {
        throw '元 DLL の列挙コールバックスナップショット取得に失敗しました。'
    }
    $enumDifference = @(Compare-Object -ReferenceObject $oracleEnum -DifferenceObject $candidateEnum -SyncWindow 0)
    if ($enumDifference.Count -ne 0) {
        $description = $enumDifference | Out-String
        throw "列挙コールバックのメタデータが元 DLL と一致しません。`n$description"
    }
}
Write-Host 'Enum callback metadata: A/W 32/64 compatible'

$candidateRegistration = @(& $testProgram --registry '' --enum-registration-probe $candidate $enumFixture)
if ($LASTEXITCODE -ne 0 -or $candidateRegistration.Count -ne 186 -or
    @($candidateRegistration -match '\.null-initial=0,error=0,system=0$').Count -ne 7 -or
    @($candidateRegistration -match '\.null-retained=0,error=0,system=0$').Count -ne 7 -or
    @($candidateRegistration -match '\.invalid-address=0,error=32844,system=87$').Count -ne 7) {
    throw '列挙コールバックの登録・保持・解除状態が不正です。'
}
if (Test-Path -LiteralPath $oracle) {
    $oracleRegistration = @(& $testProgram --registry '' --enum-registration-probe $oracle $enumFixture)
    if ($LASTEXITCODE -ne 0) { throw '原版の列挙登録状態を取得できません。' }
    $difference = @(Compare-Object $oracleRegistration $candidateRegistration -SyncWindow 0)
    if ($difference.Count) { throw "列挙登録の状態が原版と一致しません。`n$($difference | Out-String)" }
}
Write-Host 'Enum registration: 186 A/W/legacy/64, NULL, invalid-size/address, retained/replaced/cleared state rows compatible'

# 元 DLL は lha-test16-l0.lzh の OpenArchive で停止するため、候補 DLL だけを確認する。
$levelZeroFixture = Join-Path $fixtureRoot 'lha-test16-l0.lzh'
& $testProgram $candidate $levelZeroFixture | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'level-0 fixture の読み取りに失敗しました。'
}
Write-Host 'Snapshot: lha-test16-l0.lzh (candidate-only)'

$testWorkspaceBase = [IO.Path]::GetFullPath($(if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    Join-Path $repositoryRoot 'build'
} else { $WorkspaceRoot }))
if (-not (Test-Path -LiteralPath $testWorkspaceBase)) {
    New-Item -ItemType Directory -Path $testWorkspaceBase | Out-Null
}
$integrationRoot = Join-Path $testWorkspaceBase ('integration-' + [Guid]::NewGuid().ToString('N'))
Write-Host "Integration workspace: $integrationRoot"
$integrationSucceeded = $false
try {
    & $testProgram --integration $candidate $integrationRoot
    if ($LASTEXITCODE -ne 0) {
        throw '圧縮・展開の統合テストに失敗しました。'
    }
    if (Test-Path -LiteralPath $oracle) {
        $roundtripArchive = Join-Path $integrationRoot 'roundtrip.lzh'
        $levelOneArchive = Join-Path $fixtureRoot 'lha-test16-l1.lzh'
        $levelTwoArchive = Join-Path $fixtureRoot 'lha-test16-l2.lzh'
        $sjisArchive = Join-Path $fixtureRoot 'lha-test20-sjis.lzh'
        $commandCases = @(
            @{ Probe = '--command-probe'; Command = "l `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "v `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "l -jpn1 `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "l -jpjn1 `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "l -jyc0n1 `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "l -gad0n1 `"$roundtripArchive`"" },
            @{ Probe = '--command-probe'; Command = "l -n1 `"$levelOneArchive`"" },
            @{ Probe = '--command-probe'; Command = "t `"$levelTwoArchive`"" },
            @{ Probe = '--command-probe-a-summary'; Command = "p `"$levelTwoArchive`" nullfile" },
            @{ Probe = '--command-probe-a-summary'; Command = "p `"$sjisArchive`"" }
        )
        foreach ($commandCase in $commandCases) {
            $oracleCommand = @(& $testProgram $commandCase.Probe $oracle $commandCase.Command)
            $oracleCommandExit = $LASTEXITCODE
            $candidateCommand = @(& $testProgram $commandCase.Probe $candidate $commandCase.Command)
            $candidateCommandExit = $LASTEXITCODE
            $commandDifference = @(Compare-Object -ReferenceObject $oracleCommand `
                -DifferenceObject $candidateCommand -SyncWindow 0)
            if ($oracleCommandExit -ne 0 -or $candidateCommandExit -ne 0 -or
                $commandDifference.Count -ne 0) {
                $description = $commandDifference | Out-String
                throw "読み取り系コマンド出力が元 DLL と一致しません: $($commandCase.Command)`n$description"
            }
        }
        Write-Host 'Command output: l/v/t/p formatting, payload capture, and header warnings compatible'

        # 既定 UI の比較なので -gm1 は付けず、非表示のエラー待ちは失敗として打ち切る。
        $oracleActions = @(& $desktopRunner --timeout-seconds 120 $testProgram --registry '' `
            --action-output-probe $oracle (Join-Path $integrationRoot 'actions-oracle') 2>&1 |
            ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $integrationRoot 'actions-oracle.log'))
        $oracleActionsExit = $LASTEXITCODE
        if ($oracleActionsExit -ne 0) {
            throw "原版の更新・展開系試験が終了できませんでした (exit $oracleActionsExit)。actions-oracle.log を確認してください。"
        }
        $candidateActions = @(& $desktopRunner --timeout-seconds 120 $testProgram --registry '' `
            --action-output-probe $candidate (Join-Path $integrationRoot 'actions-candidate') 2>&1 |
            ForEach-Object { "$_" } | Tee-Object -FilePath (Join-Path $integrationRoot 'actions-candidate.log'))
        $candidateActionsExit = $LASTEXITCODE
        if ($candidateActionsExit -ne 0) {
            throw "候補の更新・展開系試験が終了できませんでした (exit $candidateActionsExit)。actions-candidate.log を確認してください。"
        }
        $actionDifference = @(Compare-Object -ReferenceObject $oracleActions `
            -DifferenceObject $candidateActions -SyncWindow 0)
        if ($oracleActionsExit -ne 0 -or $candidateActionsExit -ne 0 -or
            $actionDifference.Count -ne 0) {
            $description = $actionDifference | Select-Object -First 8 | ForEach-Object {
                $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
                "$side`: $($_.InputObject)"
            } | Out-String -Width 1200
            throw "更新・展開系コマンド出力が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Command output: a/u/f/m/d/e/x results, formatting, and effects compatible'

        $oracleMatching = @(& $testProgram --match-options-probe $oracle `
            (Join-Path $integrationRoot 'matching-oracle'))
        $oracleMatchingExit = $LASTEXITCODE
        $candidateMatching = @(& $testProgram --match-options-probe $candidate `
            (Join-Path $integrationRoot 'matching-candidate'))
        $candidateMatchingExit = $LASTEXITCODE
        $matchingDifference = @(Compare-Object -ReferenceObject $oracleMatching `
            -DifferenceObject $candidateMatching -SyncWindow 0)
        if ($oracleMatchingExit -ne 0 -or $candidateMatchingExit -ne 0 -or
            $matchingDifference.Count -ne 0) {
            $description = $matchingDifference | Select-Object -First 8 | ForEach-Object {
                $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
                "$side`: $($_.InputObject)"
            } | Out-String -Width 1200
            throw "パス・ワイルドカード照合と処理対象が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Command matching: DOS wildcards, p/r/d/x/n options, exclusions, and l/t/p/x/d effects compatible'

        function ConvertTo-SafeUpdatePolicyExpected([string[]]$OriginalSnapshot) {
            # この fixture は元書庫が A、新入力が D。格納された D の入力だけを削除可能とする。
            # 原版実測値は維持し、利用者が選択した未格納入力の保持だけを厳密な期待値へ写す。
            $profiles = @{}
            foreach ($row in $OriginalSnapshot) {
                if ($row -cmatch '^archive="m(\d+)" profile=([AD-]{5})$') {
                    $key = [int]$Matches[1]
                    if ($profiles.ContainsKey($key)) { throw '更新判定の原版プロフィールが重複しています。' }
                    $profiles[$key] = $Matches[2]
                }
            }
            if ($profiles.Count -ne 22) { throw '更新判定の移動プロフィール 22 件がそろっていません。' }
            $moveIndex = 0
            foreach ($row in $OriginalSnapshot) {
                if ($row.StartsWith('case=m:', [StringComparison]::Ordinal)) {
                    if (!$profiles.ContainsKey($moveIndex) -or $row -cnotmatch ' result=0 .* files=-----$') {
                        throw '更新判定の原版の正常終了条件が不正です。'
                    }
                    $sourceMask = -join ($profiles[$moveIndex].ToCharArray() | ForEach-Object {
                        if ($_ -ceq 'D') { '-' } else { 'D' }
                    })
                    $row -creplace ' files=-----$', " files=$sourceMask"
                    $moveIndex++
                } else { $row }
            }
            if ($moveIndex -ne 22) { throw '更新判定の移動コマンド 22 件がそろっていません。' }
        }

        $candidatePolicy = @(& $testProgram --update-policy-probe $candidate `
            (Join-Path $integrationRoot 'update-policy-candidate'))
        $candidatePolicyExit = $LASTEXITCODE
        $originalPolicySnapshot = @(Get-Content -LiteralPath `
            (Join-Path $repositoryRoot 'tests\fixtures\update-policy-3.00.0.5.txt') |
            Where-Object { $_ -notlike '#*' -and $_.Length -gt 0 })
        $expectedPolicy = @(ConvertTo-SafeUpdatePolicyExpected $originalPolicySnapshot)
        $policyDifference = @(Compare-Object -ReferenceObject $expectedPolicy `
            -DifferenceObject $candidatePolicy -SyncWindow 0)
        if ($candidatePolicyExit -ne 0 -or $policyDifference.Count -ne 0) {
            $description = $policyDifference | Format-Table -Wrap | Out-String -Width 2000
            throw "日時・存在判定・通知順序と、未格納入力の保持仕様が期待値と一致しません。`n$description"
        }
        Write-Host 'Update policy: 132 strict original-based cases passed; 22 move cases enforce archived-input-only deletion, other logs/state/payloads unchanged'

        # 利用者が指定したデータ消失の例外は、原版比較でなく候補の保持保証を検証する。
        & (Join-Path $PSScriptRoot 'test-safety-exceptions.ps1') -TestProgram $testProgram `
            -Candidate $candidate -Workspace (Join-Path $integrationRoot 'safety-exceptions')
        & (Join-Path $PSScriptRoot 'test-compression-order.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-order')
        & (Join-Path $PSScriptRoot 'test-thread-priority.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'thread-priority') | Out-Null
        # FRESH 拒否時のデータ保持は上の安全性試験、通常の状態保持は原版との比較で確認する。
        & (Join-Path $PSScriptRoot 'test-enum-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'enum-state') | Out-Null
        & (Join-Path $PSScriptRoot 'test-freshen-enum.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'freshen-enum')
        $compressionSharingRoot = Join-Path $integrationRoot 'compression-sharing'
        & (Join-Path $PSScriptRoot 'test-compression-sharing.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace $compressionSharingRoot
        & (Join-Path $PSScriptRoot 'test-compression-sharing.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-sharing-new') -NewArchive
        & (Join-Path $PSScriptRoot 'test-compression-sharing-recovery.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Seed (Join-Path $compressionSharingRoot 'seed.lzh') `
            -Workspace (Join-Path $integrationRoot 'compression-sharing-recovery')
        & (Join-Path $PSScriptRoot 'test-compression-streams.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-streams')
        $moveDeleteRoot = Join-Path $integrationRoot 'move-delete'
        & (Join-Path $PSScriptRoot 'test-move-delete.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace $moveDeleteRoot
        & (Join-Path $PSScriptRoot 'test-move-delete.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'move-delete-new') -NewArchive
        & (Join-Path $PSScriptRoot 'test-move-delete-recovery.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Seed (Join-Path $moveDeleteRoot 'seed.lzh') `
            -Workspace (Join-Path $integrationRoot 'move-delete-recovery')
        & (Join-Path $PSScriptRoot 'test-compression-directories.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-directories')
        & (Join-Path $PSScriptRoot 'test-compression-directories.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-directories-new') -NewArchive
        & (Join-Path $PSScriptRoot 'test-compression-directory-members.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-directory-members')
        & (Join-Path $PSScriptRoot 'test-directory-members-recovery.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'directory-members-recovery')
        & (Join-Path $PSScriptRoot 'test-compression-parent-paths.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-parent-paths') `
            -Commands a,u,f -Variants recursive,dot-recursive,no-base-recursive,recursive-deep -EnumLayout w64
        & (Join-Path $PSScriptRoot 'test-compression-system-error.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-system-error')
        & (Join-Path $PSScriptRoot 'test-compression-error-recovery.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-error-recovery')
        & (Join-Path $PSScriptRoot 'test-compression-header-init.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-header-init')
        foreach ($inputBytes in 64,0) {
            & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "compression-code-pages-$inputBytes") `
                -InputBytes $inputBytes
        }
        & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-code-pages-english') `
            -UnicodeModes 1 -Locale 1033
        & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-code-pages-english-unicode-wildcard') `
            -UnicodeModes 1 -Locale 1033 -Apis W -Layouts w64 -CodePages 932 -HeaderLevels 2 `
            -ArchiveFileName 'archive.lzh' -UseSourceWildcard
        & (Join-Path $PSScriptRoot 'test-unicode-total-progress.ps1') -TestProgram $testProgram `
            -Runner $desktopRunner -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'unicode-total-progress')
        & (Join-Path $PSScriptRoot 'test-wide-noncp932-commands.ps1') -TestProgram $testProgram `
            -Runner $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'wide-noncp932-commands')
        & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-code-pages-english-ansi') `
            -UnicodeModes 0 -Locale 1033 -Layouts none -CodePages 932,65001,1252 -HeaderLevels 0,1,2 `
            -ArchiveFileName 'archive.lzh' -UseSourceWildcard
        & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-code-pages-wide-name') `
            -UnicodeModes 1 -MemberName 'Ā.txt'
        & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-code-pages-directory') `
            -Layouts none -MemberName '日本語/source.txt'
        foreach ($locale in 1041,1033) {
            & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "compression-unicode-parent-$locale") `
                -UnicodeModes 1 -Locale $locale -HeaderLevels 2 -MemberName '日本語/Ā.txt'
            & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "compression-unicode-directory-$locale") `
                -UnicodeModes 1 -Locale $locale -HeaderLevels 2 -MemberName 'Ā/日本語.txt'
            & (Join-Path $PSScriptRoot 'test-compression-code-pages.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "compression-unicode-parent-h1-$locale") `
                -UnicodeModes 1 -Locale $locale -HeaderLevels 1 -CodePages 932 -MemberName '日本語/Ā.txt'
        }
        & (Join-Path $PSScriptRoot 'test-compression-progress-methods.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-progress-methods')
        & (Join-Path $PSScriptRoot 'test-compression-update-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-update-progress')
        & (Join-Path $PSScriptRoot 'test-compression-update-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'compression-update-progress-h2') `
            -HeaderLevel 2 -PayloadRepeats 20 -ConfigurationNames plain,w64
        & (Join-Path $PSScriptRoot 'test-progress-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'progress-state')
        & (Join-Path $PSScriptRoot 'test-progress-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'progress-state-h2') `
            -SeedHeaderLevel 2 -Variants open,open-add,off-open-add,find,find-none,count,check,off-list,mutate,memory
        & (Join-Path $PSScriptRoot 'test-header-crc-search.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'header-crc-search')
        $headerCrcCommandsRoot = Join-Path $integrationRoot 'header-crc-commands'
        & (Join-Path $PSScriptRoot 'test-header-crc-commands.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace $headerCrcCommandsRoot
        foreach ($headerLevel in 2,3) { foreach ($warmup in $false,$true) {
            $levelDirectory = if ($headerLevel -eq 3) { 'level3' } else { '' }
            $levelSuffix = if ($headerLevel -eq 3) { '-h3' } else { '' }
            & (Join-Path $PSScriptRoot 'test-header-crc-command-state.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "header-crc-command-state$levelSuffix-$warmup") `
                -ArchiveDirectory (Join-Path $headerCrcCommandsRoot "ascii-jm2/$levelDirectory") -Warmup:$warmup
            foreach ($method in 0,2) {
                & (Join-Path $PSScriptRoot 'test-header-crc-api-state.ps1') -TestProgram $testProgram `
                    -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot "header-crc-api-state$levelSuffix-jm$method-$warmup") `
                    -ArchiveDirectory (Join-Path $headerCrcCommandsRoot "ascii-jm$method/$levelDirectory") -Warmup:$warmup
            }
        } }
        & (Join-Path $PSScriptRoot 'test-extraction-initial-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'extraction-initial-progress')
        & (Join-Path $PSScriptRoot 'test-extraction-initial-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'extraction-initial-progress-h0') `
            -HeaderLevel 0 -Sizes 0,99,100,101,2048 -ProgressLayouts w64
        & (Join-Path $PSScriptRoot 'test-extraction-initial-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'extraction-initial-progress-lz4') `
            -HeaderLevel 0 -Methods 0 -Sizes 0,99,100,101,2048 -StoredMethod lz4
        & (Join-Path $PSScriptRoot 'test-command-name-width.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'command-name-width')
        & (Join-Path $PSScriptRoot 'test-decode-progress-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'decode-progress-state')
        & (Join-Path $PSScriptRoot 'test-memory-progress-dialog.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'memory-progress-dialog')
        & (Join-Path $PSScriptRoot 'test-ratio-width.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'ratio-width')
        & (Join-Path $PSScriptRoot 'test-legacy-methods.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'legacy-methods')
        $pmarcCheckRoot = Join-Path $integrationRoot 'pmarc-check'
        & (Join-Path $PSScriptRoot 'test-pmarc-check.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace $pmarcCheckRoot
        & (Join-Path $PSScriptRoot 'test-memory-methods.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixtures $pmarcCheckRoot `
            -Workspace (Join-Path $integrationRoot 'memory-methods')
        & (Join-Path $PSScriptRoot 'test-command-methods.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixtures $pmarcCheckRoot `
            -Workspace (Join-Path $integrationRoot 'command-methods')
        & (Join-Path $PSScriptRoot 'test-pmarc-extraction.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixtures $pmarcCheckRoot `
            -Workspace (Join-Path $integrationRoot 'pmarc-extraction')
        & (Join-Path $PSScriptRoot 'test-command-initial-headers.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Seed (Join-Path $pmarcCheckRoot 'literal\lh0-9.lzh') `
            -Workspace (Join-Path $integrationRoot 'command-initial-headers')
        & (Join-Path $PSScriptRoot 'test-command-crc.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Seed (Join-Path $pmarcCheckRoot 'literal\lh0-9.lzh') `
            -Level2Fixtures $headerCrcCommandsRoot -Workspace (Join-Path $integrationRoot 'command-crc')
        & (Join-Path $PSScriptRoot 'test-command-body-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Seed (Join-Path $pmarcCheckRoot 'literal\lh0-9.lzh') `
            -Workspace (Join-Path $integrationRoot 'command-body-errors')
        $shortHeadersRoot = Join-Path $integrationRoot 'command-short-headers'
        & (Join-Path $PSScriptRoot 'test-command-short-headers.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace $shortHeadersRoot
        & (Join-Path $PSScriptRoot 'test-command-short-header-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -ArchiveDirectory $shortHeadersRoot `
            -Workspace (Join-Path $integrationRoot 'command-short-header-state')
        & (Join-Path $PSScriptRoot 'test-level3-body-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -Workspace (Join-Path $integrationRoot 'level3-body-errors')
        & (Join-Path $PSScriptRoot 'test-level3-body-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -Workspace (Join-Path $integrationRoot 'level3-body-raw') -Families ascii `
            -Groups control,tail,header-cut -CaseNames good,no-end,bad-end1,header-cut1,header-cut21,header-cut31,header-cut32 `
            -ProfileNames a32,legacy,reject,missing,rename,raw-W,raw-A-1,raw-A,raw-legacy
        & (Join-Path $PSScriptRoot 'test-level3-body-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -Workspace (Join-Path $integrationRoot 'level3-body-empty-raw') -Families ascii `
            -Groups control,tail,header-cut -CaseNames good,no-end,bad-end1,header-cut1,header-cut21,header-cut31,header-cut32 `
            -Commands p -ProfileNames raw-W-missing,raw-W-empty
        & (Join-Path $PSScriptRoot 'test-command-missing-crc.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -NoCrc (Join-Path $integrationRoot 'command-crc\lh0-no-crc.lzh') `
            -Good (Join-Path $integrationRoot 'command-crc\lh0-good.lzh') `
            -Pmarc (Join-Path $integrationRoot 'command-crc\literal\pm0-9.lzh') `
            -Workspace (Join-Path $integrationRoot 'command-missing-crc')
        & (Join-Path $PSScriptRoot 'test-extraction-header-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -ShortHeaderDirectory $shortHeadersRoot `
            -InitialHeaderDirectory (Join-Path $integrationRoot 'command-initial-headers') `
            -MissingCrcDirectory (Join-Path $integrationRoot 'command-missing-crc') `
            -Groups crc,short,initial,missing-crc -Workspace (Join-Path $integrationRoot 'extraction-header-errors')
        & (Join-Path $PSScriptRoot 'test-extraction-header-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -Groups crc -Families ascii -Methods 0 -NameModes 0,2 `
            -FixtureNames ascii-jm0-h2-good,ascii-jm0-h3-middle,ascii-jm0-h3-all,ascii-jm0-h3-no-end `
            -Workspace (Join-Path $integrationRoot 'extraction-header-modes')
        & (Join-Path $PSScriptRoot 'test-command-short-header-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -ArchiveDirectory $shortHeadersRoot -Commands e,x `
            -Workspace (Join-Path $integrationRoot 'extraction-short-header-state')
        & (Join-Path $PSScriptRoot 'test-extraction-header-release.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixture (Join-Path $headerCrcCommandsRoot 'ascii-jm0/good.lzh') `
            -Workspace (Join-Path $integrationRoot 'extraction-header-release')
        $extractionBodyRoot = Join-Path $integrationRoot 'level3-body-errors'
        $compressionCancelArguments = @{ TestProgram=$testProgram; RunnerPath=$desktopRunner; Oracle=$oracle
            Candidate=$candidate; SeedArchive=(Join-Path $extractionBodyRoot 'ascii-jm0/good.lzh') }
        & (Join-Path $PSScriptRoot 'test-compression-progress-cancel.ps1') @compressionCancelArguments `
            -Repeat 3 -Workspace (Join-Path $integrationRoot 'compression-cancel-matrix')
        & (Join-Path $PSScriptRoot 'test-compression-progress-cancel.ps1') @compressionCancelArguments `
            -Commands a,u,m -Cases open,begin1,process1,finish,search -Profiles w64 -NewArchive -Repeat 3 `
            -Workspace (Join-Path $integrationRoot 'compression-cancel-new')
        & (Join-Path $PSScriptRoot 'test-compression-progress-cancel.ps1') @compressionCancelArguments `
            -Cases begin2,finish -Methods 0 -SourceDirectoryName ソース `
            -Workspace (Join-Path $integrationRoot 'compression-cancel-japanese-paths')
        & (Join-Path $PSScriptRoot 'test-compression-progress-cancel.ps1') @compressionCancelArguments `
            -Cases begin2,process1,finish -Profiles a32,w64 -UseMappedFile 0 -Repeat 3 `
            -Workspace (Join-Path $integrationRoot 'compression-cancel-mapping-disabled')
        & (Join-Path $PSScriptRoot 'test-mapped-extraction.ps1') @compressionCancelArguments `
            -Workspace (Join-Path $integrationRoot 'extraction-mapping-settings')
        & (Join-Path $PSScriptRoot 'test-compression-progress-cancel.ps1') @compressionCancelArguments `
            -Cases process1,finish -Profiles a32,w64 -Methods 0 -InputSize 65537 -UseMappedFile 0 -Repeat 3 `
            -Workspace (Join-Path $integrationRoot 'compression-stored-mid-copy-cancel')
        $cancelArguments = @{ TestProgram=$testProgram; RunnerPath=$desktopRunner; Oracle=$oracle
            Candidate=$candidate; BodyDirectory=$extractionBodyRoot }
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Workspace (Join-Path $integrationRoot 'extraction-cancel-matrix')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Profiles legacy,none -Cases open,begin3,process1,end -NameModes 0,2 `
            -Workspace (Join-Path $integrationRoot 'extraction-cancel-modes')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Profiles missing,reject,rename -Cases begin1,begin3,process1,process3 `
            -Workspace (Join-Path $integrationRoot 'extraction-cancel-selection')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Methods 0 -Profiles w64 -Cases open,begin3,process1,process3 `
            -SuppressDialogs 0 -Languages 1033,1041 -Workspace (Join-Path $integrationRoot 'extraction-cancel-dialogs')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Commands p,t -Profiles w64 -Cases begin2,process1,process3 -Repeat 8 `
            -Workspace (Join-Path $integrationRoot 'extraction-cancel-resources')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Commands x,p,t -Profiles w64 -Variants crc-first,body0-cut3,body1-cut3 `
            -Cases begin1,begin3,process1,process3 -Workspace (Join-Path $integrationRoot 'extraction-cancel-damaged')
        & (Join-Path $PSScriptRoot 'test-extraction-progress-cancel.ps1') @cancelArguments `
            -Families ascii -Methods 0 -Profiles w64,a32 -ArchivePath (Join-Path $fixtureRoot 'lha-test16-l1.lzh') `
            -Cases open,begin1,begin2,process1 -Languages 1033,1041 `
            -Workspace (Join-Path $integrationRoot 'extraction-cancel-unix-header')
        & (Join-Path $PSScriptRoot 'test-extraction-body-read.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot -IncludeCrcErrors `
            -Workspace (Join-Path $integrationRoot 'extraction-body-read')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Workspace (Join-Path $integrationRoot 'extraction-directory-state')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -NestedFile -Variants good,body0-cut3,header-cut21,crc-first -Policies silent,keep-stop `
            -Workspace (Join-Path $integrationRoot 'extraction-directory-nested')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -NestedFile -DirectoryLast -Variants good -DirectoryAttributes 16,18 `
            -Workspace (Join-Path $integrationRoot 'extraction-directory-last')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Variants good,body0-cut3,crc-first -Policies silent,keep-stop -ExistingDirectories $true `
            -ExistingCreation ([datetime]::UtcNow.AddYears(4)) -Workspace (Join-Path $integrationRoot 'extraction-directory-future')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -DirectoryNames a-dir -Variants good,body0-cut3,crc-first -Policies silent,keep-stop `
            -DirectoryAttributes 17,18,22,48 -Profiles w64 -Workspace (Join-Path $integrationRoot 'extraction-directory-attributes')
        & (Join-Path $PSScriptRoot 'test-extraction-directory-state.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -DirectoryNames 資料 -Variants good,body0-cut3,crc-first -Policies silent,keep-stop `
            -Profiles w64,w32 -UnicodeMode 0 -DestinationName 'Ā-output' `
            -Workspace (Join-Path $integrationRoot 'extraction-directory-wide')
        foreach ($category in 'happy','boundary') {
            & (Join-Path $PSScriptRoot "test-jy-warnings-$category.ps1") -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
                -Archive (Join-Path $extractionBodyRoot 'ascii-jm0/good.lzh') `
                -Workspace (Join-Path $integrationRoot "jy-warnings-$category")
        }
        & (Join-Path $PSScriptRoot 'test-overwrite-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'overwrite-dialogs')
        & (Join-Path $PSScriptRoot 'test-directory-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'directory-dialogs')
        & (Join-Path $PSScriptRoot 'test-directory-member-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'directory-member-dialogs')
        & (Join-Path $PSScriptRoot 'test-disk-space-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'disk-space-dialogs')
        & (Join-Path $PSScriptRoot 'test-create-failure.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'create-failure')
        foreach ($unicodeMode in 0,1) {
            & (Join-Path $PSScriptRoot 'test-create-failure.ps1') -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Apis W `
                -EnumLayout w32 -UnicodeMode $unicodeMode -DestinationSuffix '-Ā' `
                -CaseNames skip,stop1,x-stop,injected-skip,injected-stop,injected-new `
                -Workspace (Join-Path $integrationRoot "create-failure-wide-$unicodeMode")
        }
        & (Join-Path $PSScriptRoot 'test-create-failure.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Apis W -EnumLayout none `
            -CaseNames skip,stop1 -Workspace (Join-Path $integrationRoot 'create-failure-noenum')
        & (Join-Path $PSScriptRoot 'test-preparation-failure.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'preparation-failure')
        foreach ($unicodeMode in 0,1) {
            & (Join-Path $PSScriptRoot 'test-preparation-failure.ps1') -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Apis W `
                -EnumLayout w32 -UnicodeMode $unicodeMode -DestinationSuffix '-Ā' `
                -CaseNames newer,missing,parent-no,parent-file,directory-file,metadata-open,newer-last `
                -Workspace (Join-Path $integrationRoot "preparation-failure-wide-$unicodeMode")
        }
        & (Join-Path $PSScriptRoot 'test-preparation-failure.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Apis W -EnumLayout none `
            -CaseNames newer,parent-file -Workspace (Join-Path $integrationRoot 'preparation-failure-noenum')
        & (Join-Path $PSScriptRoot 'test-filename-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'filename-dialogs')
        & (Join-Path $PSScriptRoot 'test-filename-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Apis W -NativeFileDialog `
            -CaseNames overwrite-new,overwrite-existing,overwrite-cancel-save,directory-new,member-new `
            -Workspace (Join-Path $integrationRoot 'filename-dialogs-native')
        & (Join-Path $PSScriptRoot 'test-overwrite-dialog-layout.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
            -SeedArchive (Join-Path $integrationRoot 'overwrite-dialogs/seed.lzh') `
            -Workspace (Join-Path $integrationRoot 'overwrite-dialog-layout')
        & (Join-Path $PSScriptRoot 'test-overwrite-dialog-layout.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -Directory `
            -SeedArchive (Join-Path $integrationRoot 'overwrite-dialogs/seed.lzh') `
            -Workspace (Join-Path $integrationRoot 'directory-dialog-layout')
        foreach ($mode in 0,1) {
            & (Join-Path $PSScriptRoot 'test-filename-dialogs.ps1') -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
                -Apis W -CaseNames overwrite-new,overwrite-existing,directory-new -EnumLayout w32 `
                -UnicodeMode $mode -SelectionSuffix '-Ā' `
                -Workspace (Join-Path $integrationRoot "filename-dialogs-wide-$mode")
            & (Join-Path $PSScriptRoot 'test-overwrite-dialogs.ps1') -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
                -Apis W -CaseNames yes,skip-all-new,ro-both-skip,cancel,ro-yes `
                -EnumLayout w32 -UnicodeMode $mode -DestinationSuffix '-Ā' `
                -Workspace (Join-Path $integrationRoot "overwrite-dialogs-wide-$mode")
            & (Join-Path $PSScriptRoot 'test-directory-dialogs.ps1') -TestProgram $testProgram `
                -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate `
                -Apis W -CaseNames yes,skip-all,cancel -EnumLayout w32 -UnicodeMode $mode `
                -DestinationSuffix '-Ā' -Workspace (Join-Path $integrationRoot "directory-dialogs-wide-$mode")
        }
        & (Join-Path $PSScriptRoot 'test-command-crc-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Coverage $CrcDialogCoverage -Workspace (Join-Path $integrationRoot 'command-crc-dialogs')
        & (Join-Path $PSScriptRoot 'test-command-crc-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Families ascii -Commands x,p -Variants good,crc-first,crc-all -Profiles w64 -Languages 1041 `
            -Policies delete-continue,keep-continue,delete-stop,keep-stop -AuditRelease `
            -Workspace (Join-Path $integrationRoot 'command-crc-release')
        & (Join-Path $PSScriptRoot 'test-command-crc-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Families japanese -Methods 0 -Commands x -Variants good,crc-first,crc-all -Languages 1041 `
            -Policies delete-stop,keep-stop,keep-continue -Profiles w64,W-A32 -UnicodeMode 0 -DestinationName 'Ā-output' `
            -Workspace (Join-Path $integrationRoot 'command-crc-wide-dialogs')
        & (Join-Path $PSScriptRoot 'test-command-crc-dialogs.ps1') -TestProgram $testProgram `
            -RunnerPath $desktopRunner -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Families ascii -Methods 2 -Commands x,p,t -Variants good,crc-first,crc-all -Languages 1033 `
            -Policies jy-continue -Profiles none,w32,a64,legacy -NameMode 0 -ExistingFiles `
            -Workspace (Join-Path $integrationRoot 'command-crc-jyd-dialogs')
        & (Join-Path $PSScriptRoot 'test-extraction-body-read.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -UnicodeMode 0 -DestinationName 'Ā-output' `
            -ProfileNames w64,w32,W-A32,W-A64,reject,missing,rename,raw-W,raw-W-1,abort-begin,abort-missing `
            -CaseNames good,body0-cut0,body0-cut12,body0-cut13,body1-cut0,body1-cut3 `
            -Workspace (Join-Path $integrationRoot 'extraction-body-wide')
        & (Join-Path $PSScriptRoot 'test-extraction-body-read.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Families ascii -Methods 0 -NameModes 0,2 -ExistingFiles `
            -CaseNames good,body0-cut0,body0-cut12,body0-cut13,body1-cut0,body1-cut3 `
            -Workspace (Join-Path $integrationRoot 'extraction-body-modes')
        & (Join-Path $PSScriptRoot 'test-extraction-body-read.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -BodyDirectory $extractionBodyRoot `
            -Families ascii -Methods 0 -UnicodeMode 0 -UnicodeArchivePath `
            -ProfileNames w64,w32,W-A32,W-A64,reject,missing,rename,raw-W,raw-W-1,abort-begin,abort-missing `
            -CaseNames good,body0-cut0,body0-cut12,body0-cut13,body1-cut0,body1-cut3 `
            -Workspace (Join-Path $integrationRoot 'extraction-body-wide-archive')
        & (Join-Path $PSScriptRoot 'test-extraction-header-errors.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Level2Fixtures $headerCrcCommandsRoot `
            -Groups crc -UnicodeMode 0 -DestinationName 'Ā-output' `
            -ProfileNames w64,w32,W-A32,W-A64,reject,missing,rename,raw-W,abort-begin,abort-missing `
            -FixtureNames ascii-jm0-h2-good,ascii-jm0-h3-middle,ascii-jm0-h3-all,ascii-jm0-h3-no-end,`
                          ascii-jm2-h2-good,ascii-jm2-h3-middle,ascii-jm2-h3-all,ascii-jm2-h3-no-end,`
                          japanese-jm0-h2-good,japanese-jm0-h3-middle,japanese-jm0-h3-all,japanese-jm0-h3-no-end,`
                          japanese-jm2-h2-good,japanese-jm2-h3-middle,japanese-jm2-h3-all,japanese-jm2-h3-no-end `
            -Workspace (Join-Path $integrationRoot 'extraction-header-wide')
        & (Join-Path $PSScriptRoot 'test-command-short-header-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -ArchiveDirectory $shortHeadersRoot -Commands e,x `
            -UnicodeMode 0 -DestinationName 'Ā-output' `
            -Workspace (Join-Path $integrationRoot 'extraction-header-wide-state')
        & (Join-Path $PSScriptRoot 'test-extraction-header-release.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixture (Join-Path $extractionBodyRoot 'ascii-jm0/body1-cut3.lzh') `
            -Commands e,x -UnicodeMode 0 -DestinationName 'Ā-output' `
            -ExpectedResult 32794 -ExpectedMissingResult 32824 -ExpectedMembers 1 -ExpectedListResult 32824 `
            -Workspace (Join-Path $integrationRoot 'extraction-body-release')
        & (Join-Path $PSScriptRoot 'test-command-filter-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Fixtures $pmarcCheckRoot `
            -Level2Fixtures $headerCrcCommandsRoot -Workspace (Join-Path $integrationRoot 'command-filter-progress')
        & (Join-Path $PSScriptRoot 'test-lz5-compression.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'lz5-compression') `
            -PayloadDisplay $CodecPayloadDisplay
        & (Join-Path $PSScriptRoot 'test-lh3-compression.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'lh3-compression') `
            -PayloadDisplay $CodecPayloadDisplay
        & (Join-Path $PSScriptRoot 'test-lh3-abort-recovery.ps1') -TestProgram $testProgram `
            -Candidate $candidate -Workspace (Join-Path $integrationRoot 'lh3-abort-recovery')

        $oracleOverwrite = @(& $testProgram --overwrite-policy-probe $oracle `
            (Join-Path $integrationRoot 'overwrite-oracle'))
        $oracleOverwriteExit = $LASTEXITCODE
        $candidateOverwrite = @(& $testProgram --overwrite-policy-probe $candidate `
            (Join-Path $integrationRoot 'overwrite-candidate'))
        $candidateOverwriteExit = $LASTEXITCODE
        $overwriteDifference = @(Compare-Object -ReferenceObject $oracleOverwrite `
            -DifferenceObject $candidateOverwrite -SyncWindow 0)
        if ($oracleOverwriteExit -ne 0 -or $candidateOverwriteExit -ne 0 -or
            $overwriteDifference.Count -ne 0) {
            $description = $overwriteDifference | Out-String
            throw "上書き・連番別名・特殊属性の動作が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Overwrite policy: x/e defaults with gm1, m1/m2, y ordering, ga0/1/2, protected files, and log names compatible'

        if ($CompareUpdatePolicyOracle) {
            $oraclePolicy = @(& $testProgram --update-policy-probe $oracle `
                (Join-Path $integrationRoot 'update-policy-oracle'))
            $oraclePolicyExit = $LASTEXITCODE
            if ($oraclePolicyExit -ne 0) { throw '日時・存在判定の原版ライブ試験が異常終了しました。' }
            $livePolicyExpected = @(ConvertTo-SafeUpdatePolicyExpected $oraclePolicy)
            $livePolicyDifference = @(Compare-Object -ReferenceObject $livePolicyExpected `
                -DifferenceObject $candidatePolicy -SyncWindow 0)
            if ($oraclePolicyExit -ne 0 -or $livePolicyDifference.Count -ne 0) {
                $description = $livePolicyDifference | Out-String
                throw "日時・存在判定のライブ比較が一致しません（原版の一時ファイル置換失敗も含めて判定）。`n$description"
            }
            Write-Host 'Update policy: live original-DLL comparison passed with explicit safe move-source retention'
        }

        $oracleComments = @(& $testProgram --comment-probe $oracle `
            (Join-Path $integrationRoot 'comments-oracle') $oracle)
        $oracleCommentsExit = $LASTEXITCODE
        $candidateComments = @(& $testProgram --comment-probe $candidate `
            (Join-Path $integrationRoot 'comments-candidate') $oracle)
        $candidateCommentsExit = $LASTEXITCODE
        $commentDifference = @(Compare-Object -ReferenceObject $oracleComments `
            -DifferenceObject $candidateComments -SyncWindow 0)
        if ($oracleCommentsExit -ne 0 -or $candidateCommentsExit -ne 0 -or
            $commentDifference.Count -ne 0) {
            $description = $commentDifference | Out-String
            throw "注釈命令の出力・保存形式・展開結果が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Comment command: A/W, BOM, clear, header levels, limits, and original-DLL extraction compatible'

        $oracleMethods = @(& $testProgram --method-switch-probe $oracle `
            (Join-Path $integrationRoot 'methods-oracle') $oracle)
        $oracleMethodsExit = $LASTEXITCODE
        $candidateMethods = @(& $testProgram --method-switch-probe $candidate `
            (Join-Path $integrationRoot 'methods-candidate') $oracle)
        $candidateMethodsExit = $LASTEXITCODE
        $methodDifference = @(Compare-Object -ReferenceObject $oracleMethods `
            -DifferenceObject $candidateMethods -SyncWindow 0)
        if ($oracleMethodsExit -ne 0 -or $candidateMethodsExit -ne 0 -or
            $methodDifference.Count -ne 0) {
            $description = $methodDifference | Out-String
            throw "連続呼出しでの圧縮方式切替・展開結果が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Compression state: lh0/lh1/lh5/lh6/lh7 switching, h0/h1/h2, and original-DLL extraction compatible'

        $oracleResponses = @(& $testProgram --response-probe $oracle `
            (Join-Path $integrationRoot 'response-oracle'))
        $oracleResponsesExit = $LASTEXITCODE
        $candidateResponses = @(& $testProgram --response-probe $candidate `
            (Join-Path $integrationRoot 'response-candidate'))
        $candidateResponsesExit = $LASTEXITCODE
        $responseDifference = @(Compare-Object -ReferenceObject $oracleResponses `
            -DifferenceObject $candidateResponses -SyncWindow 0)
        if ($oracleResponsesExit -ne 0 -or $candidateResponsesExit -ne 0 -or
            $responseDifference.Count -ne 0) {
            $description = $responseDifference | Out-String
            throw "レスポンスファイルと指定文字の状態遷移が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Response files: A/W/BOM, control state, literal names, non-nesting, and read failure compatible'
    }
    if (Test-Path -LiteralPath $oracle) {
        $oracleFreshRoot = Join-Path $integrationRoot 'fresh-oracle'
        & $testProgram --fresh-effects $oracle $oracleFreshRoot
        if ($LASTEXITCODE -ne 0) {
            throw '元 DLL の fresh 命令実処理テストに失敗しました。'
        }
    }
    $candidateFreshRoot = Join-Path $integrationRoot 'fresh-candidate'
    & $testProgram --fresh-effects $candidate $candidateFreshRoot
    if ($LASTEXITCODE -ne 0) {
        throw '候補 DLL の fresh 命令実処理テストに失敗しました。'
    }
    $candidateEnumRoot = Join-Path $integrationRoot 'enum-candidate'
    & $testProgram --enum-effects $candidate $candidateEnumRoot
    if ($LASTEXITCODE -ne 0) {
        throw '候補 DLL の列挙コールバック実処理テストに失敗しました。'
    }
    if (Test-Path -LiteralPath $oracle) {
        $oracleEnumRoot = Join-Path $integrationRoot 'enum-oracle'
        & $testProgram --enum-effects $oracle $oracleEnumRoot
        if ($LASTEXITCODE -ne 0) {
            throw '元 DLL の列挙コールバック実処理テストに失敗しました。'
        }

        $oracleSpecialRoot = Join-Path $integrationRoot 'special-oracle'
        $candidateSpecialRoot = Join-Path $integrationRoot 'special-candidate'
        $oracleSpecial = @(& $testProgram --special-command-probe $oracle $oracleSpecialRoot)
        $oracleSpecialExit = $LASTEXITCODE
        $candidateSpecial = @(& $testProgram --special-command-probe $candidate $candidateSpecialRoot)
        $candidateSpecialExit = $LASTEXITCODE
        $normalizeSpecial = {
            param([string[]]$Lines)
            @($Lines |
                Where-Object { $_ -notlike 'direct-h1.last-error=*' } |
                ForEach-Object { $_ -replace 'access=\d+', 'access=<dynamic>' })
        }
        $oracleSpecialNormalized = @(& $normalizeSpecial $oracleSpecial)
        $candidateSpecialNormalized = @(& $normalizeSpecial $candidateSpecial)
        if ($oracleSpecialExit -ne 0 -or $candidateSpecialExit -ne 0 -or
            [string]::Join("`n", $oracleSpecialNormalized) -cne
            [string]::Join("`n", $candidateSpecialNormalized)) {
            $specialDifference = Compare-Object -ReferenceObject $oracleSpecialNormalized `
                -DifferenceObject $candidateSpecialNormalized -SyncWindow 0 | Out-String
            throw "j/y/n 命令または列挙コールバック効果が元 DLL と一致しません。`n$specialDifference"
        }

        $oracleTransformRoot = Join-Path $integrationRoot 'special-transform-oracle'
        $candidateTransformRoot = Join-Path $integrationRoot 'special-transform-candidate'
        New-Item -ItemType Directory -Path $oracleTransformRoot,$candidateTransformRoot | Out-Null
        foreach ($archiveName in 'base.lzh','first.lzh','second.lzh') {
            Copy-Item -LiteralPath (Join-Path $oracleSpecialRoot $archiveName) `
                -Destination (Join-Path $oracleTransformRoot $archiveName)
            Copy-Item -LiteralPath (Join-Path $oracleSpecialRoot $archiveName) `
                -Destination (Join-Path $candidateTransformRoot $archiveName)
        }
        & $testProgram --special-transform-probe $oracle $oracleTransformRoot | Out-Null
        $oracleTransformExit = $LASTEXITCODE
        & $testProgram --special-transform-probe $candidate $candidateTransformRoot | Out-Null
        $candidateTransformExit = $LASTEXITCODE
        if ($oracleTransformExit -ne 0 -or $candidateTransformExit -ne 0) {
            throw 'j/y/n 同一入力変換プローブの実行に失敗しました。'
        }
        foreach ($archiveName in 'joined.lzh','converted.lzh','renamed.lzh') {
            $oracleHash = (Get-FileHash -LiteralPath (Join-Path $oracleTransformRoot $archiveName) `
                -Algorithm SHA256).Hash
            $candidateHash = (Get-FileHash -LiteralPath (Join-Path $candidateTransformRoot $archiveName) `
                -Algorithm SHA256).Hash
            if ($oracleHash -cne $candidateHash) {
                throw "j/y/n の生成バイト列が元 DLL と一致しません: $archiveName"
            }
        }
        Write-Host 'Special commands: j/y/n semantics, callbacks, and bytes compatible'
        & (Join-Path $PSScriptRoot 'test-rewrite-levels.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'rewrite-levels')
        & (Join-Path $PSScriptRoot 'test-rewrite-times.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'rewrite-times')
        & (Join-Path $PSScriptRoot 'test-rewrite-join-existing.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -FixturesRoot (Join-Path $integrationRoot 'rewrite-levels') `
            -Workspace (Join-Path $integrationRoot 'rewrite-join-existing')
        & (Join-Path $PSScriptRoot 'test-existing-join-cancel.ps1') -TestProgram $testProgram `
            -Candidate $candidate -FixturesRoot (Join-Path $integrationRoot 'rewrite-levels') `
            -Workspace (Join-Path $integrationRoot 'existing-join-cancel')
        & (Join-Path $PSScriptRoot 'test-rewrite-join-existing.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -FixturesRoot (Join-Path $integrationRoot 'rewrite-levels') `
            -SeedNames seed-l2.lzh -Modes @(1,2) -Apis @('legacy','A') -Layouts w64 `
            -Workspace (Join-Path $integrationRoot 'existing-join-ansi-progress')
        & (Join-Path $PSScriptRoot 'test-join-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -FixturesRoot (Join-Path $integrationRoot 'rewrite-levels') `
            -Workspace (Join-Path $integrationRoot 'join-progress')
        & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -InputBytes 0 `
            -Workspace (Join-Path $integrationRoot 'rewrite-progress-empty')
        foreach ($rewriteSize in 64,99,100,262143,262144,262145,1048577) {
            & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -InputBytes $rewriteSize `
                -Workspace (Join-Path $integrationRoot "rewrite-progress-$rewriteSize")
        }

        foreach ($rewriteMethod in 1,5) {
            & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -InputBytes 65536 -Method $rewriteMethod `
                -Workspace (Join-Path $integrationRoot "rewrite-progress-method-$rewriteMethod")
        }
        foreach ($rewritePattern in 'nested.txt','other.txt') {
            & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -InputBytes 65536 -SecondInputBytes 777 `
                -Method 1 -Pattern $rewritePattern `
                -Workspace (Join-Path $integrationRoot "rewrite-progress-partial-$rewritePattern")
        }
        & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -UnicodeArchive `
            -Workspace (Join-Path $integrationRoot 'rewrite-progress-unicode')
        foreach ($rewriteUnicode in $false,$true) {
            & (Join-Path $PSScriptRoot 'test-rewrite-progress.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate -UnicodeArchive:$rewriteUnicode `
                -RenameMember -Pattern 'nested.txt' `
                -Workspace (Join-Path $integrationRoot "rewrite-progress-member-rename-$rewriteUnicode")
        }
        & (Join-Path $PSScriptRoot 'test-rewrite-settings.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'rewrite-settings')
        & (Join-Path $PSScriptRoot 'test-rewrite-code-pages.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'rewrite-code-pages')
        $oracleUnicodeMemoryRoot = Join-Path $integrationRoot 'unicode-memory-oracle'
        $candidateUnicodeMemoryRoot = Join-Path $integrationRoot 'unicode-memory-candidate'
        $oracleUnicodeMemory = @(& $testProgram --unicode-memory-probe $oracle `
            $oracleUnicodeMemoryRoot)
        $oracleUnicodeMemoryExit = $LASTEXITCODE
        $candidateUnicodeMemory = @(& $testProgram --unicode-memory-probe $candidate `
            $candidateUnicodeMemoryRoot)
        $candidateUnicodeMemoryExit = $LASTEXITCODE
        if ($oracleUnicodeMemoryExit -ne 0 -or $candidateUnicodeMemoryExit -ne 0 -or
            [string]::Join("`n", $oracleUnicodeMemory) -cne
            [string]::Join("`n", $candidateUnicodeMemory)) {
            $unicodeMemoryDifference = Compare-Object -ReferenceObject $oracleUnicodeMemory `
                -DifferenceObject $candidateUnicodeMemory -SyncWindow 0 | Out-String
            throw "Unicode メモリ圧縮・展開 API が元 DLL と一致しません。`n$unicodeMemoryDifference"
        }
        Write-Host 'Unicode memory APIs: paths, names, metadata, and extraction compatible'

        $oracleUnicodeCommandRoot = Join-Path $integrationRoot 'unicode-command-oracle'
        $candidateUnicodeCommandRoot = Join-Path $integrationRoot 'unicode-command-candidate'
        $oracleUnicodeCommand = @(& $testProgram --unicode-command-probe $oracle `
            $oracleUnicodeCommandRoot)
        $oracleUnicodeCommandExit = $LASTEXITCODE
        $candidateUnicodeCommand = @(& $testProgram --unicode-command-probe $candidate `
            $candidateUnicodeCommandRoot)
        $candidateUnicodeCommandExit = $LASTEXITCODE
        if ($oracleUnicodeCommandExit -ne 0 -or $candidateUnicodeCommandExit -ne 0 -or
            [string]::Join("`n", $oracleUnicodeCommand) -cne
            [string]::Join("`n", $candidateUnicodeCommand)) {
            $unicodeCommandDifference = Compare-Object -ReferenceObject $oracleUnicodeCommand `
                -DifferenceObject $candidateUnicodeCommand -SyncWindow 0 | Out-String
            throw "Unicode 通常追加・展開コマンドが元 DLL と一致しません。`n$unicodeCommandDifference"
        }
        Write-Host 'Unicode command API: add, metadata, and extraction compatible'

        $oracleCheckRoot = Join-Path $integrationRoot 'check-archive-oracle'
        $candidateCheckRoot = Join-Path $integrationRoot 'check-archive-candidate'
        $oracleCheck = @(& $testProgram --check-archive-probe $oracle $oracleCheckRoot)
        $oracleCheckExit = $LASTEXITCODE
        $candidateCheck = @(& $testProgram --check-archive-probe $candidate $candidateCheckRoot)
        $candidateCheckExit = $LASTEXITCODE
        $checkDifference = @(Compare-Object -ReferenceObject $oracleCheck `
            -DifferenceObject $candidateCheck -SyncWindow 0)
        if ($oracleCheckExit -ne 0 -or $candidateCheckExit -ne 0 -or
            $checkDifference.Count -ne 0) {
            $description = $checkDifference | Out-String
            throw "CheckArchive の破損・CRC・回復モードが元 DLL と一致しません。`n$description"
        }
        Write-Host 'CheckArchive: rapid/basic/full CRC/recovery boundaries compatible'

        $configCases = @(
            @{ Mode = 0; Action = 'cancel'; Variant = 'a' },
            @{ Mode = 2147483647; Action = 'ok'; Variant = 'w' },
            @{ Mode = -1; Action = 'ok'; Variant = 'a' },
            @{ Mode = 1; Action = 'expand'; Variant = 'a' },
            @{ Mode = 2; Action = 'main:404'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:410'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:414'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:416'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:406'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:408'; Variant = 'a' },
            @{ Mode = 1; Action = 'main:409'; Variant = 'a' },
            @{ Mode = 1; Action = 'local:502'; Variant = 'a' },
            @{ Mode = 1; Action = 'local:503'; Variant = 'a' },
            @{ Mode = 1; Action = 'local:504,505,506,507,508,509'; Variant = 'a' },
            @{ Mode = 3; Action = 'cancel'; Variant = 'wnull' }
        )
        foreach ($configCase in $configCases) {
            $oracleConfig = @(& $testProgram --config-dialog-probe $oracle `
                $configCase.Mode $configCase.Action $configCase.Variant)
            $oracleConfigExit = $LASTEXITCODE
            $candidateConfig = @(& $testProgram --config-dialog-probe $candidate `
                $configCase.Mode $configCase.Action $configCase.Variant)
            $candidateConfigExit = $LASTEXITCODE
            $configDifference = @(Compare-Object -ReferenceObject $oracleConfig `
                -DifferenceObject $candidateConfig -SyncWindow 0)
            if ($oracleConfigExit -ne 0 -or $candidateConfigExit -ne 0 -or
                $configDifference.Count -ne 0) {
                $description = $configDifference | Out-String
                throw "ConfigDialog ($($configCase.Mode), $($configCase.Action), $($configCase.Variant)) が元 DLL と一致しません。`n$description"
            }
        }
        Write-Host 'ConfigDialog: A/W, ignored mode, controls, nested dialog, and cancel semantics compatible'

        $oracleSfxRoot = Join-Path $integrationRoot 'sfx-oracle'
        $candidateSfxRoot = Join-Path $integrationRoot 'sfx-candidate'
        New-Item -ItemType Directory -Path $oracleSfxRoot | Out-Null
        New-Item -ItemType Directory -Path $candidateSfxRoot | Out-Null
        foreach ($mode in @('win', 'winm')) {
            $oracleModeRoot = Join-Path $oracleSfxRoot $mode
            $candidateModeRoot = Join-Path $candidateSfxRoot $mode
            $oracleSfx = @(& $testProgram --sfx-probe $oracle $oracleModeRoot $mode)
            $oracleSfxExit = $LASTEXITCODE
            $candidateSfx = @(& $testProgram --sfx-probe $candidate $candidateModeRoot $mode)
            $candidateSfxExit = $LASTEXITCODE
            $oracleSemantics = @($oracleSfx | Where-Object { $_ -notmatch '\.size=' })
            $candidateSemantics = @($candidateSfx | Where-Object { $_ -notmatch '\.size=' })
            $sfxDifference = @(Compare-Object -ReferenceObject $oracleSemantics `
                -DifferenceObject $candidateSemantics -SyncWindow 0)
            if ($oracleSfxExit -ne 0 -or $candidateSfxExit -ne 0 -or
                $sfxDifference.Count -ne 0) {
                $description = $sfxDifference | Out-String
                throw "WinSFX $mode の生成契約が元 DLL と一致しません。`n$description"
            }

            $oracleExe = Get-ChildItem -LiteralPath (Join-Path $oracleModeRoot "$mode-out") `
                -Filter '*.EXE' -File | Select-Object -First 1
            if (-not $oracleExe) {
                throw "元 DLL が生成した WinSFX が見つかりません: $mode"
            }
            & $testProgram $candidate $oracleExe.FullName $oracle | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "元 DLL が生成した WinSFX を候補 DLL で互換に読めません: $mode"
            }
        }

        $candidateDosRoot = Join-Path $candidateSfxRoot 'dos'
        $candidateDosSfx = @(& $testProgram --sfx-probe $candidate $candidateDosRoot dos)
        if ($LASTEXITCODE -ne 0 -or
            $candidateDosSfx -notcontains 'sfx.dos.command.rc=0' -or
            $candidateDosSfx -notcontains 'sfx.dos.file0.check=1' -or
            $candidateDosSfx -notcontains 'sfx.dos.file0.check-sfx=32771' -or
            $candidateDosSfx -notcontains 'sfx.dos.file0.type=3') {
            throw 'gw0 自己解凍書庫の生成・識別テストに失敗しました。'
        }

        foreach ($mode in @('win', 'winm', 'dos')) {
            $modeRoot = Join-Path $candidateSfxRoot $mode
            $generatedDirectory = Join-Path $modeRoot "$mode-out"
            $generatedExe = Get-ChildItem -LiteralPath $generatedDirectory -Filter '*.EXE' -File |
                Select-Object -First 1
            if (-not $generatedExe) {
                throw "候補 DLL が生成した SFX が見つかりません: $mode"
            }
            $selfExtracted = Join-Path $modeRoot 'self-extracted'
            New-Item -ItemType Directory -Path $selfExtracted | Out-Null
            $process = Start-Process -FilePath $generatedExe.FullName `
                -ArgumentList ('"' + $selfExtracted + '"') -WindowStyle Hidden -PassThru
            if (-not $process.WaitForExit(15000)) {
                $process.Kill()
                throw "候補 SFX の自己展開がタイムアウトしました: $mode"
            }
            $sourcePayload = Join-Path (Join-Path $modeRoot 'input') 'payload.bin'
            $extractedPayload = Join-Path $selfExtracted 'payload.bin'
            if ($process.ExitCode -ne 0 -or
                -not (Test-Path -LiteralPath $extractedPayload) -or
                (Get-FileHash -LiteralPath $sourcePayload -Algorithm SHA256).Hash -cne
                (Get-FileHash -LiteralPath $extractedPayload -Algorithm SHA256).Hash) {
                throw "候補 SFX の自己展開結果が不正です: $mode"
            }
        }
        Write-Host 'SFX: WinSFX generation/read contracts and self-extraction compatible'

        $oracleDosTime = @(& $testProgram --dos-time-probe $oracle `
            (Join-Path $integrationRoot 'dos-time-oracle'))
        $oracleDosTimeExit = $LASTEXITCODE
        $candidateDosTime = @(& $testProgram --dos-time-probe $candidate `
            (Join-Path $integrationRoot 'dos-time-candidate'))
        $candidateDosTimeExit = $LASTEXITCODE
        $dosTimeDifference = @(Compare-Object -ReferenceObject $oracleDosTime `
            -DifferenceObject $candidateDosTime -SyncWindow 0)
        if ($oracleDosTimeExit -ne 0 -or $candidateDosTimeExit -ne 0 -or $dosTimeDifference.Count -ne 0) {
            $description = $dosTimeDifference | Out-String
            throw "DOS 日時の丸め・暦の繰り上がりが元 DLL と一致しません。`n$description"
        }
        Write-Host 'DOS timestamps: A/W metadata and progress, minute/day/month/year rollover compatible'

        $oracleFindRoot = Join-Path $integrationRoot 'find-state-oracle'
        $oracleFindState = @(& $testProgram --find-state-probe $oracle $oracleFindRoot)
        $oracleFindExit = $LASTEXITCODE
        $candidateFindState = @(& $testProgram --find-state-probe $candidate `
            (Join-Path $integrationRoot 'find-state-candidate') (Join-Path $oracleFindRoot 'state.lzh'))
        $candidateFindExit = $LASTEXITCODE
        $findStateDifference = @(Compare-Object -ReferenceObject $oracleFindState `
            -DifferenceObject $candidateFindState -SyncWindow 0)
        if ($oracleFindExit -ne 0 -or $candidateFindExit -ne 0 -or $findStateDifference.Count -ne 0) {
            $description = $findStateDifference | Out-String
            throw "FindFirst/Next の状態・累計値・メンバー情報 API が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Archive search: A/W cursor, repeated FindFirst, EOF, retained info, totals, and 31 getter states compatible'

        $findTreeRoot = Join-Path $integrationRoot 'find-pattern-tree'
        $findUnicodeRoot = Join-Path $integrationRoot 'find-pattern-unicode'
        & $testProgram --create-find-tree-fixture $oracle $findTreeRoot
        if ($LASTEXITCODE -ne 0) { throw '階層付き検索 fixture の作成に失敗しました。' }
        & $testProgram --create-find-unicode-fixture $oracle $findUnicodeRoot
        if ($LASTEXITCODE -ne 0) { throw 'Unicode 検索 fixture の作成に失敗しました。' }
        $findUnicodeArchive = Join-Path $findUnicodeRoot 'pattern.lzh'

        $memorySelectionRoot = Join-Path $integrationRoot 'memory-selection'
        $memoryCompressedRoot = Join-Path $integrationRoot 'memory-selection-compressed'
        & $testProgram --create-memory-selection-fixture $oracle $memorySelectionRoot
        if ($LASTEXITCODE -ne 0) { throw 'メモリ展開 fixture の作成に失敗しました。' }
        & $testProgram --create-memory-selection-fixture $oracle $memoryCompressedRoot compressed
        if ($LASTEXITCODE -ne 0) { throw '圧縮済みメモリ展開 fixture の作成に失敗しました。' }
        $memorySelectionArchive = Join-Path $memorySelectionRoot 'selection.lzh'
        & (Join-Path $PSScriptRoot 'test-dictionaries.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'dictionaries')
        & (Join-Path $PSScriptRoot 'test-print-output.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'print-output') `
            -ExtraArchive (Join-Path $integrationRoot 'dictionaries\case-7-original\compressed.lzh')
        & (Join-Path $PSScriptRoot 'test-attributes.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'attributes') `
            -Archive $memorySelectionArchive
        & (Join-Path $PSScriptRoot 'test-enum-paths.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'enum-paths') `
            -Archive (Join-Path $integrationRoot 'attributes\os-77-attr-33-level-2-mode--1.lzh') -Scope paths
        foreach ($locale in 1033, 1041) {
            foreach ($utf8 in $false, $true) {
                & (Join-Path $PSScriptRoot 'test-enum-paths.ps1') -TestProgram $testProgram `
                    -Oracle $oracle -Candidate $candidate `
                    -Workspace (Join-Path $integrationRoot "enum-encoding-$locale-$utf8") `
                    -Archive (Join-Path $integrationRoot 'attributes\os-77-attr-33-level-2-mode--1.lzh') `
                    -Scope codepages -Locale $locale -UnicodeMode:$utf8 -Progress
            }
        }
        foreach ($mode in 0, 2) {
            & (Join-Path $PSScriptRoot 'test-enum-paths.ps1') -TestProgram $testProgram `
                -Oracle $oracle -Candidate $candidate `
                -Workspace (Join-Path $integrationRoot "enum-progress-mode-$mode") `
                -Archive (Join-Path $integrationRoot 'attributes\os-77-attr-33-level-2-mode--1.lzh') `
                -Scope paths -Commands e, x, p, t -Progress -ProgressMode $mode
        }
        & (Join-Path $PSScriptRoot 'test-open-state.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'open-state') `
            -Archive $memorySelectionArchive
        & (Join-Path $PSScriptRoot 'test-archive-tails.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'archive-tails') `
            -EmptyArchive (Join-Path $fixtureRoot 'lha-test16-l1.lzh') -DataArchive $memorySelectionArchive
        & (Join-Path $PSScriptRoot 'test-existing-join-foreign.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'existing-join-foreign') `
            -Seed (Join-Path $integrationRoot 'rewrite-levels/seed-l2.lzh') `
            -ForeignFixtures (Join-Path $integrationRoot 'archive-tails')
        & (Join-Path $PSScriptRoot 'test-archive-paths.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'archive-paths') `
            -Archive $memorySelectionArchive
        & (Join-Path $PSScriptRoot 'test-config-registry.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Workspace (Join-Path $integrationRoot 'registry') `
            -Archive $memorySelectionArchive
        foreach ($memoryArchive in @($memorySelectionArchive,
                (Join-Path $memoryCompressedRoot 'selection.lzh'), $findUnicodeArchive)) {
            foreach ($callbackMode in @('none', 'a32', 'w32', 'a64', 'w64', 'reject', 'rename')) {
                $oracleMemory = @(& $testProgram --memory-selection-probe $oracle $memoryArchive $callbackMode)
                $oracleMemoryExit = $LASTEXITCODE
                $candidateMemory = @(& $testProgram --memory-selection-probe $candidate $memoryArchive $callbackMode)
                $candidateMemoryExit = $LASTEXITCODE
                $memoryDifference = @(Compare-Object $oracleMemory $candidateMemory -SyncWindow 0)
                if ($oracleMemoryExit -ne 0 -or $candidateMemoryExit -ne 0 -or $memoryDifference.Count -ne 0 -or
                    @($candidateMemory | Where-Object { $_ -match '^memory\.[01]\.[0-3]\.\d+=' }).Count -ne 96) {
                    $description = $memoryDifference | Select-Object -First 12 | Out-String
                    throw "メモリ展開 ($callbackMode, $memoryArchive) が元 DLL と一致しません。`n$description"
                }
            }
        }
        $oracleMemoryState = @(& $testProgram --memory-state-probe $oracle $memorySelectionArchive)
        $oracleMemoryStateExit = $LASTEXITCODE
        $candidateMemoryState = @(& $testProgram --memory-state-probe $candidate $memorySelectionArchive)
        $candidateMemoryStateExit = $LASTEXITCODE
        if ($oracleMemoryStateExit -ne 0 -or $candidateMemoryStateExit -ne 0 -or
            $candidateMemoryState.Count -ne 10 -or
            @(Compare-Object $oracleMemoryState $candidateMemoryState -SyncWindow 0).Count -ne 0) {
            throw 'メモリ展開の引数エラー・直前のメタデータ・書庫利用中の状態が元 DLL と一致しません。'
        }
        Write-Host 'Memory extraction: 2016 A/W selection/capacity/callback cases and 10 state transitions compatible'

        $memoryDamageRoot = Join-Path $integrationRoot 'memory-damage-compressed'
        & $testProgram --create-memory-damage-fixtures (Join-Path $memoryCompressedRoot 'selection.lzh') `
            $memoryDamageRoot
        if ($LASTEXITCODE -ne 0) { throw '破損した圧縮済みメモリ展開 fixture の作成に失敗しました。' }
        $memoryFailureArchives = @(
            foreach ($variant in @('valid', 'bad-header', 'bad-data', 'truncated', 'empty', 'prefixed',
                    'bad-fourth', 'between-garbage', 'no-terminator', 'level2-bad-name', 'trailing',
                    'multi', 'level2-valid')) {
                Join-Path $oracleCheckRoot ($variant + '.lzh')
            }
            foreach ($variant in @('body-zero', 'body-ff', 'body-flip', 'body-truncated',
                    'first-header-crc', 'second-header-crc')) {
                Join-Path $memoryDamageRoot ($variant + '.lzh')
            }
        )
        foreach ($memoryArchive in $memoryFailureArchives) {
            $oracleFailure = @(& $testProgram --memory-failure-probe $oracle $memoryArchive `
                (Join-Path $oracleCheckRoot 'valid.lzh'))
            $oracleFailureExit = $LASTEXITCODE
            $candidateFailure = @(& $testProgram --memory-failure-probe $candidate $memoryArchive `
                (Join-Path $oracleCheckRoot 'valid.lzh'))
            $candidateFailureExit = $LASTEXITCODE
            if ($oracleFailureExit -ne 0 -or $candidateFailureExit -ne 0) {
                throw "破損書庫のメモリ展開 ($memoryArchive) が異常終了しました。元=$oracleFailureExit 候補=$candidateFailureExit"
            }
            $failureDifference = @(Compare-Object $oracleFailure $candidateFailure -SyncWindow 0)
            if ($failureDifference.Count -ne 0 -or
                @($candidateFailure | Where-Object { $_ -match '^failure\.[01]\.[0-2]\.\d+=' }).Count -ne 24) {
                $description = $failureDifference | Select-Object -First 12 | Out-String
                throw "破損書庫のメモリ展開・エラー・状態保持 ($memoryArchive) が一致しません。`n$description"
            }
        }
        Write-Host 'Memory damage: 456 A/W CRC/header/truncation, selection, capacity, and retained-state cases compatible'

        $huffmanArchive = Join-Path $memoryDamageRoot 'body-ff.lzh'
        & $testProgram --memory-failure-stress $candidate $huffmanArchive
        if ($LASTEXITCODE -ne 0) { throw 'ハフマンコード異常を繰り返したときのメモリ・ハンドル検査に失敗しました。' }
        $oracleDecoder = @(& $testProgram --check-decoder-failure-probe $oracle $huffmanArchive `
            (Join-Path $memoryCompressedRoot 'selection.lzh'))
        $oracleDecoderExit = $LASTEXITCODE
        $candidateDecoder = @(& $testProgram --check-decoder-failure-probe $candidate $huffmanArchive `
            (Join-Path $memoryCompressedRoot 'selection.lzh'))
        $candidateDecoderExit = $LASTEXITCODE
        if ($oracleDecoderExit -ne 0 -or $candidateDecoderExit -ne 0 -or
            $candidateDecoder.Count -ne 12 -or
            [string]::Join("`n", $oracleDecoder) -cne [string]::Join("`n", $candidateDecoder)) {
            throw 'CheckArchive のハフマンコード異常・異常後の再利用が元 DLL と一致しません。'
        }
        Write-Host 'CheckArchive decoder guard: 12 legacy/A/W failure and subsequent valid-check cases compatible'

        $checkStateRoot = Join-Path $integrationRoot 'check-state-boundaries'
        $checkValidArchive = Join-Path $oracleCheckRoot 'valid.lzh'
        & $testProgram --create-check-boundary-fixtures $checkValidArchive $checkStateRoot
        if ($LASTEXITCODE -ne 0) { throw '書庫検査の境界 fixture の作成に失敗しました。' }
        $checkStateArchives = @($memoryFailureArchives) + @((Join-Path $memoryCompressedRoot 'selection.lzh')) +
            @(Get-ChildItem -LiteralPath $checkStateRoot -Filter '*.lzh' | Select-Object -ExpandProperty FullName)
        if ($checkStateArchives.Count -ne 157) { throw '書庫検査の境界 fixture 件数が一致しません。' }
        foreach ($checkArchive in $checkStateArchives) {
            $oracleState = @(& $testProgram --check-existing-archive-probe $oracle $checkArchive)
            $oracleStateExit = $LASTEXITCODE
            $candidateState = @(& $testProgram --check-existing-archive-probe $candidate $checkArchive)
            $candidateStateExit = $LASTEXITCODE
            if ($oracleStateExit -ne 0 -or $candidateStateExit -ne 0) {
                throw "書庫検査 ($checkArchive) が異常終了しました。元=$oracleStateExit 候補=$candidateStateExit"
            }
            $checkStateDifference = @(Compare-Object $oracleState $candidateState -SyncWindow 0)
            if ($candidateState.Count -ne 192 -or $checkStateDifference.Count -ne 0) {
                $description = $checkStateDifference | Select-Object -First 12 | Out-String
                throw "書庫検査のモード・探索・CRC・エラー状態 ($checkArchive) が一致しません。`n$description"
            }
        }
        Write-Host 'CheckArchive states: 30144 legacy/A/W mode, recovery, scan-limit, trailing-data, and error cases compatible'

        $checkUnicodeArchive = (Get-ChildItem -LiteralPath $checkStateRoot -Filter 'unicode-*.lzh').FullName
        foreach ($checkArchive in @($checkValidArchive, $checkUnicodeArchive)) {
            $oracleArguments = @(& $testProgram --check-argument-probe $oracle $checkArchive)
            $oracleArgumentsExit = $LASTEXITCODE
            $candidateArguments = @(& $testProgram --check-argument-probe $candidate $checkArchive)
            $candidateArgumentsExit = $LASTEXITCODE
            if ($oracleArgumentsExit -ne 0 -or $candidateArgumentsExit -ne 0 -or
                $candidateArguments.Count -ne 180 -or
                [string]::Join("`n", $oracleArguments) -cne [string]::Join("`n", $candidateArguments)) {
                throw '書庫検査の引用符・NULL・存在しないパス・ワイルドカードの扱いが一致しません。'
            }
        }
        foreach ($checkArchive in @($checkValidArchive, $huffmanArchive,
                (Join-Path $checkStateRoot 'prefix-131072.lzh'))) {
            foreach ($checkMode in @(-2147483648, -1, 64, 65, 66, 2147483647)) {
                $oracleFlags = @(& $testProgram --check-existing-archive-probe $oracle $checkArchive $checkMode)
                $oracleFlagsExit = $LASTEXITCODE
                $candidateFlags = @(& $testProgram --check-existing-archive-probe $candidate $checkArchive $checkMode)
                $candidateFlagsExit = $LASTEXITCODE
                if ($oracleFlagsExit -ne 0 -or $candidateFlagsExit -ne 0 -or $candidateFlags.Count -ne 3 -or
                    [string]::Join("`n", $oracleFlags) -cne [string]::Join("`n", $candidateFlags)) {
                    throw "書庫検査の予約モード ($checkMode) が一致しません。"
                }
            }
        }
        $oracleBusy = @(& $testProgram --check-busy-probe $oracle $checkValidArchive)
        $oracleBusyExit = $LASTEXITCODE
        $candidateBusy = @(& $testProgram --check-busy-probe $candidate $checkValidArchive)
        $candidateBusyExit = $LASTEXITCODE
        if ($oracleBusyExit -ne 0 -or $candidateBusyExit -ne 0 -or $candidateBusy.Count -ne 19 -or
            [string]::Join("`n", $oracleBusy) -cne [string]::Join("`n", $candidateBusy)) {
            throw '処理中の書庫検査の拒否・呼び出し元の継続が一致しません。'
        }
        Write-Host 'CheckArchive arguments: 360 path, 54 reserved-mode, and 18 busy cases compatible; outer extraction preserved'

        foreach ($variant in @('prefix-4060', 'prefix-4072', 'prefix-4073', 'prefix-8170',
                'prefix-8190', 'prefix-8192', 'unknown-method')) {
            $boundaryArchive = Join-Path $checkStateRoot ($variant + '.lzh')
            $oracleBoundary = @(& $testProgram --memory-failure-probe $oracle $boundaryArchive $checkValidArchive)
            $oracleBoundaryExit = $LASTEXITCODE
            $candidateBoundary = @(& $testProgram --memory-failure-probe $candidate $boundaryArchive $checkValidArchive)
            $candidateBoundaryExit = $LASTEXITCODE
            if ($oracleBoundaryExit -ne 0 -or $candidateBoundaryExit -ne 0 -or
                @($candidateBoundary | Where-Object { $_ -match '^failure\.[01]\.[0-2]\.\d+=' }).Count -ne 24 -or
                [string]::Join("`n", $oracleBoundary) -cne [string]::Join("`n", $candidateBoundary)) {
                throw "メモリ展開のヘッダー探索境界 ($variant) が一致しません。"
            }
        }
        Write-Host 'Shared header scanner: 168 memory extraction boundary and unknown-method cases compatible'

        $memoryWorkflowRoot = Join-Path $integrationRoot 'memory-workflow'
        foreach ($memoryArchive in @($memorySelectionArchive,
                (Join-Path $memoryCompressedRoot 'selection.lzh'), $findUnicodeArchive)) {
            foreach ($progressMode in @($false, $true)) {
                $workflowArguments = @('--memory-workflow-probe', $oracle, $memoryArchive, $memoryWorkflowRoot)
                if ($progressMode) { $workflowArguments += 'progress' }
                $oracleWorkflow = @(& $testProgram @workflowArguments)
                $oracleWorkflowExit = $LASTEXITCODE
                $workflowArguments[1] = $candidate
                $candidateWorkflow = @(& $testProgram @workflowArguments)
                $candidateWorkflowExit = $LASTEXITCODE
                $workflowDifference = @(Compare-Object $oracleWorkflow $candidateWorkflow -SyncWindow 0)
                if ($oracleWorkflowExit -ne 0 -or $candidateWorkflowExit -ne 0 -or
                    $workflowDifference.Count -ne 0 -or
                    @($candidateWorkflow | Where-Object { $_ -match '^workflow\.[01]\.' }).Count -ne 168) {
                    $description = $workflowDifference | Select-Object -First 12 | Out-String
                    throw "メモリ展開の引数・レスポンス・基準ディレクトリ・通知 ($memoryArchive, progress=$progressMode) が一致しません。`n$description"
                }
            }
        }
        Write-Host 'Memory workflow: 1008 A/W response, selection, base-directory, capacity, and progress-registration cases compatible'

        # この検索条件では比較元 DLL が 0xc0000005 で終了する。候補の境界検査を別枠で維持する。
        $boundedMemory = @(& $testProgram --memory-workflow-probe $candidate $memorySelectionArchive `
            $memoryWorkflowRoot progress response-wide-long)
        $boundedMemoryExit = $LASTEXITCODE
        $boundedMemoryRows = @($boundedMemory | Where-Object { $_ -match '^workflow\.[01]\.' })
        if ($boundedMemoryExit -ne 0 -or $boundedMemoryRows.Count -ne 4 -or
            @($boundedMemoryRows | Where-Object {
                $_ -notmatch '=0,error=0,system=38,.*guard=1,enum=1,progress=0$'
            }).Count -ne 0) {
            throw '長いレスポンス検索条件でのメモリ展開・バッファ境界検査に失敗しました。'
        }
        Write-Host 'Memory response bounds: 4 candidate-only cases pass; original access violation is not reproduced'

        foreach ($cpCase in @(@{ Name='ASCII'; Archive=$memorySelectionArchive },
                             @{ Name='Unicode'; Archive=$findUnicodeArchive })) {
            $oracleCp = @(& $testProgram --code-page-probe $oracle $cpCase.Archive `
                (Join-Path $integrationRoot ('code-page-oracle-' + $cpCase.Name)))
            $oracleCpExit = $LASTEXITCODE
            $candidateCp = @(& $testProgram --code-page-probe $candidate $cpCase.Archive `
                (Join-Path $integrationRoot ('code-page-candidate-' + $cpCase.Name)))
            $candidateCpExit = $LASTEXITCODE
            $cpDifference = @(Compare-Object $oracleCp $candidateCp -SyncWindow 0)
            if ($oracleCpExit -ne 0 -or $candidateCpExit -ne 0 -or $cpDifference.Count -ne 0) {
                $description = $cpDifference | Select-Object -First 12 | Out-String
                throw "文字コード API ($($cpCase.Name)) が元 DLL と一致しません。`n$description"
            }
        }
        Write-Host 'Code pages: setters, in-use guards, A/W names, UTF-8 archive paths, logs, callbacks, and memory input compatible'

        $oracleTimeRange = @(& $testProgram --timestamp-range-probe $oracle $memorySelectionArchive `
            (Join-Path $integrationRoot 'timestamp-range-oracle'))
        $oracleTimeRangeExit = $LASTEXITCODE
        $candidateTimeRange = @(& $testProgram --timestamp-range-probe $candidate $memorySelectionArchive `
            (Join-Path $integrationRoot 'timestamp-range-candidate'))
        $candidateTimeRangeExit = $LASTEXITCODE
        $timeRangeDifference = @(Compare-Object $oracleTimeRange $candidateTimeRange -SyncWindow 0)
        if ($oracleTimeRangeExit -ne 0 -or $candidateTimeRangeExit -ne 0 -or
            $candidateTimeRange.Count -ne 768 -or $timeRangeDifference.Count -ne 0) {
            $description = $timeRangeDifference | Select-Object -First 12 | Out-String
            throw "列挙時の日時範囲警告が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Timestamp range warnings: 768 creation/write/access and A/W/null-info/search cases compatible'

        $findPatternCases = @(
            @{ Name = 'ASCII'; Archive = (Join-Path $oracleFindRoot 'state.lzh'); Options = @('ansi', 'defined'); Count = 5720 },
            @{ Name = 'tree'; Archive = (Join-Path $findTreeRoot 'pattern.lzh'); Options = @('ansi', 'defined'); Count = 5720 },
            @{ Name = 'Unicode-ANSI'; Archive = $findUnicodeArchive; Options = @('ansi', 'components'); Count = 3168 },
            @{ Name = 'Unicode-UTF8'; Archive = $findUnicodeArchive; Options = @('utf8', 'components'); Count = 3168 },
            @{ Name = 'Unicode-path'; Archive = $findUnicodeArchive; Options = @('utf8', '28'); Count = 88 }
        )
        foreach ($case in $findPatternCases) {
            $patternOptions = $case.Options
            $oraclePatterns = @(& $testProgram --find-pattern-probe $oracle $case.Archive @patternOptions)
            $oraclePatternExit = $LASTEXITCODE
            $candidatePatterns = @(& $testProgram --find-pattern-probe $candidate $case.Archive @patternOptions)
            $candidatePatternExit = $LASTEXITCODE
            $patternDifference = @(Compare-Object -ReferenceObject $oraclePatterns `
                -DifferenceObject $candidatePatterns -SyncWindow 0)
            if ($oraclePatternExit -ne 0 -or $candidatePatternExit -ne 0 -or
                $oraclePatterns.Count -ne $case.Count -or $candidatePatterns.Count -ne $case.Count -or
                $patternDifference.Count -ne 0) {
                $description = $patternDifference | Out-String
                throw "列挙 API の検索条件が元 DLL と一致しません: $($case.Name)`n$description"
            }
            Write-Host "Archive patterns: $($case.Name), $($case.Count) A/W/OpenArchive2/mode cases compatible"
        }

        # 元 DLL は */?.txt・*/????.txt・*/ で終端の先を読み、以前の名前やスタックで結果が変わる。
        # ここは一致の保証対象にせず、候補が文字列内だけを照合して誤一致しないことを別途検証する。
        foreach ($patternIndex in @(13, 51, 55)) {
            $boundedPatterns = @(& $testProgram --find-pattern-probe $candidate $findUnicodeArchive utf8 $patternIndex)
            if ($LASTEXITCODE -ne 0 -or $boundedPatterns.Count -ne 88 -or
                @($boundedPatterns | Where-Object { $_ -notmatch '=end=-1,total=0,names=$' }).Count -ne 0) {
                throw "候補のパス付き検索が名前の終端を越えました: pattern $patternIndex"
            }
            foreach ($fixtureName in @('ASCII', 'tree')) {
                $fixturePath = if ($fixtureName -eq 'ASCII') {
                    Join-Path $oracleFindRoot 'state.lzh'
                } else { Join-Path $findTreeRoot 'pattern.lzh' }
                $boundedPatterns = @(& $testProgram --find-pattern-probe $candidate $fixturePath ansi $patternIndex)
                if ($LASTEXITCODE -ne 0 -or $boundedPatterns.Count -ne 88) {
                    throw "候補のパス境界試験に失敗しました: $fixtureName, pattern $patternIndex"
                }
                foreach ($row in $boundedPatterns) {
                    $expected = '=end=-1,total=0,names='
                    if ($patternIndex -eq 13) {
                        if ($fixtureName -eq 'ASCII') { $expected = '=end=-1,total=7,names="dir/c.txt";' }
                        elseif ($row -match '^pattern\.\d\.[02]\.') {
                            $expected = '=end=-1,total=17,names="dir/a.txt";"dir/sub/c.txt";"other/deep/a.txt";'
                        } else { $expected = '=end=-1,total=3,names="dir/a.txt";' }
                    }
                    if (-not $row.EndsWith($expected, [StringComparison]::Ordinal)) {
                        throw "候補のパス境界の結果が不正です: $row"
                    }
                }
            }
        }
        Write-Host 'Archive search bounds: 792 candidate-only cases pass; original end-of-string overreads are intentionally not reproduced'

        $unicodeFixture = Join-Path $integrationRoot 'unicode-original.lzh'
        & $testProgram --create-unicode-fixture $oracle $unicodeFixture
        if ($LASTEXITCODE -ne 0) {
            throw '元 DLL による Unicode 拡張ヘッダ fixture の作成に失敗しました。'
        }
        & $testProgram $candidate $unicodeFixture $oracle
        if ($LASTEXITCODE -ne 0) {
            throw 'Unicode／コードページ拡張ヘッダの互換性テストに失敗しました。'
        }
        $candidateUnicodeEnum = @(& $testProgram --enum-probe $candidate $unicodeFixture)
        $oracleUnicodeEnum = @(& $testProgram --enum-probe $oracle $unicodeFixture)
        $unicodeEnumDifference = @(Compare-Object -ReferenceObject $oracleUnicodeEnum -DifferenceObject $candidateUnicodeEnum -SyncWindow 0)
        if ($LASTEXITCODE -ne 0 -or $unicodeEnumDifference.Count -ne 0) {
            throw 'Unicode 名に対する列挙コールバック情報が元 DLL と一致しません。'
        }

        $unicodePathFixture = Join-Path $integrationRoot 'unicode-path-fixed.lzh'
        & $testProgram --create-unicode-fixture $oracle $unicodePathFixture fixed
        if ($LASTEXITCODE -ne 0) { throw '固定日時の Unicode パス fixture を作成できません。' }
        foreach ($locale in 1033, 1041) {
            foreach ($utf8 in $false, $true) {
                & (Join-Path $PSScriptRoot 'test-enum-paths.ps1') -TestProgram $testProgram `
                    -Oracle $oracle -Candidate $candidate -Archive $unicodePathFixture `
                    -Workspace (Join-Path $integrationRoot "unicode-header-$locale-$utf8") `
                    -Scope paths -Locale $locale -UnicodeMode:$utf8 -Progress -Pattern '*' `
                    -Commands e, x, p, t -Layouts none, a32, w32, a64, w64
            }
        }
        & (Join-Path $PSScriptRoot 'test-unicode-header-paths.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Archive $unicodePathFixture `
            -Workspace (Join-Path $integrationRoot 'unicode-header-paths')
        & (Join-Path $PSScriptRoot 'test-extraction-times.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate -Archive $unicodePathFixture `
            -Workspace (Join-Path $integrationRoot 'extraction-times')
        & (Join-Path $PSScriptRoot 'test-unicode-compression-logs.ps1') -TestProgram $testProgram `
            -Oracle $oracle -Candidate $candidate `
            -Workspace (Join-Path $integrationRoot 'unicode-compression-logs')

        $oracleProgressRoot = Join-Path $integrationRoot 'progress-oracle'
        $candidateProgressRoot = Join-Path $integrationRoot 'progress-candidate'
        $oracleProgress = @(& $testProgram --progress-probe $oracle $unicodeFixture $oracleProgressRoot)
        $oracleProgressExit = $LASTEXITCODE
        $candidateProgress = @(& $testProgram --progress-probe $candidate $unicodeFixture $candidateProgressRoot)
        $candidateProgressExit = $LASTEXITCODE
        $progressDifference = @(Compare-Object -ReferenceObject $oracleProgress -DifferenceObject $candidateProgress -SyncWindow 0)
        if ($oracleProgressExit -ne 0 -or $candidateProgressExit -ne 0 -or
            $progressDifference.Count -ne 0) {
            $description = $progressDifference | Out-String
            throw "進捗コールバックの Basic A/W・拡張 A/W・32/64 構造体が元 DLL と一致しません。`n$description"
        }
        Write-Host 'Owner progress callback: Basic A/W and extended A/W 32/64 compatible'

        # 元 DLL は callback が FALSE を返した後に同期復帰しないため、中断契約は候補 DLL だけを確認する。
        $candidateAbortRoot = Join-Path $integrationRoot 'progress-abort-candidate'
        $candidateAbort = @(& $testProgram --progress-abort-probe $candidate $unicodeFixture $candidateAbortRoot)
        if ($LASTEXITCODE -ne 0 -or
            $candidateAbort -notcontains 'abort.set=1' -or
            $candidateAbort -notcontains 'abort.command_result=-1' -or
            $candidateAbort -notcontains 'abort.kill=1' -or
            $candidateAbort -notcontains 'abort.count=4' -or
            -not ($candidateAbort | Where-Object { $_ -like 'abort.entry3=msg=1,state=1,*' })) {
            throw '進捗コールバックの FALSE 返却による中断テストに失敗しました。'
        }
        Write-Host 'Owner progress callback abort: stopped at INPROCESS and returned -1'

        foreach ($mode in 0, 1, 2) {
            $oracleAddProgressRoot = Join-Path $integrationRoot "progress-add-oracle-$mode"
            $candidateAddProgressRoot = Join-Path $integrationRoot "progress-add-candidate-$mode"
            $oracleAddProgress = @(& $testProgram --progress-add-probe $oracle $oracleAddProgressRoot $mode)
            $oracleAddProgressExit = $LASTEXITCODE
            $candidateAddProgress = @(& $testProgram --progress-add-probe $candidate $candidateAddProgressRoot $mode)
            $candidateAddProgressExit = $LASTEXITCODE
            $addProgressDifference = @(Compare-Object -ReferenceObject $oracleAddProgress -DifferenceObject $candidateAddProgress -SyncWindow 0)
            $expectedCount = if ($mode -eq 0) { 0 } else { 8 }
            if ($oracleAddProgressExit -ne 0 -or $candidateAddProgressExit -ne 0 -or
                $oracleAddProgress -notcontains "add.count=$expectedCount" -or
                $candidateAddProgress -notcontains "add.count=$expectedCount" -or
                $addProgressDifference.Count -ne 0) {
                $description = $addProgressDifference | Out-String
                throw "追加圧縮時の進捗コールバック情報が元 DLL と一致しません (n$mode)。`n$description"
            }
        }
        Write-Host 'Add progress callback: n0/n1/n2 selection, exact sequences and metadata compatible'
        Write-Host 'Snapshot: original Unicode extension headers'
    }
    $integrationSucceeded = $true
} finally {
    $resolvedTarget = [IO.Path]::GetFullPath($integrationRoot)
    $expectedPrefix = $testWorkspaceBase.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($resolvedTarget.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTarget)) {
        if ($integrationSucceeded) {
            Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
        } else {
            # 失敗した入力・一時書庫をその場に残し、原版側の I/O エラーも調査できるようにする。
            Write-Host "Failed integration workspace retained: $resolvedTarget"
        }
    }
}

if ($CodecPayloadDisplay -eq 'Focused') {
    Write-Host 'Codec payload coverage: all payload/guard checks passed; normal-display comparisons are representative, not all-input coverage.'
}
if ($CrcDialogCoverage -eq 'Full' -and $CodecPayloadDisplay -eq 'Normal') {
    Write-Host 'All compatibility and integration tests passed.'
} else {
    Write-Host "Selected compatibility and integration tests passed (CRC dialogs: $CrcDialogCoverage; codec payload display: $CodecPayloadDisplay). Focused coverage is not a full-matrix result."
}
