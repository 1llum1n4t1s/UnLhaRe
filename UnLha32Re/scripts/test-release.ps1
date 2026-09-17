#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Candidate = '',
    [string]$WorkspaceRoot = '',
    [string]$ReportPath = '',
    [ValidateRange(1,180)][int]$TimeoutSeconds = 90,
    [switch]$SkipBuild,
    [switch]$IsolatedChild
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gitRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
$runner = Join-Path $projectRoot 'artifacts\Release\DesktopRunner.exe'
$probe = Join-Path $projectRoot 'artifacts\Release\CompatibilityTests.exe'
if (!$Candidate) { $Candidate = Join-Path $projectRoot 'artifacts\Release\UNLHA32RE.dll' }
$Candidate = [IO.Path]::GetFullPath($Candidate)
if (!$WorkspaceRoot) { $WorkspaceRoot = Join-Path $projectRoot 'build\release-tests' }
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
if (!$ReportPath) { $ReportPath = Join-Path $projectRoot 'artifacts\Release\release-test.json' }
$ReportPath = [IO.Path]::GetFullPath($ReportPath)

if (!$IsolatedChild) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $runRoot = Join-Path $WorkspaceRoot ('run-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ReportPath)) | Out-Null
    $head = & git -C $gitRoot rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw '検証対象の Git HEAD を取得できません。' }
    $report = [ordered]@{
        SchemaVersion=1; Profile='Release'; Status='running'; GitHead=[string]$head
        CandidatePath=$Candidate; CandidateSha256=$null; ElapsedSeconds=0
        PowerShell=$PSVersionTable.PSVersion.ToString(); OS=[Environment]::OSVersion.VersionString
        ScriptPath=$PSCommandPath; ScriptSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
        Workspace=$runRoot; DwmMonitorRoot=(Join-Path $runRoot 'dwm-monitor'); Checks=@()
        Scope='candidate-only smoke; full oracle, UI matrix and stress tests are not run'
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
    try {
        if (!$SkipBuild) { & (Join-Path $PSScriptRoot 'build.ps1') -Configuration Release }
        foreach ($path in $Candidate,$runner,$probe) {
            if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "試験入力が見つかりません: $path" }
        }
        $report.CandidateSha256 = (Get-FileHash -LiteralPath $Candidate).Hash
        $report['ProbeSha256'] = (Get-FileHash -LiteralPath $probe).Hash
        $report['RunnerSha256'] = (Get-FileHash -LiteralPath $runner).Hash
        Write-Host "Release smoke: $Candidate SHA256=$($report.CandidateSha256)"
        Write-Host "Environment: PowerShell $($report.PowerShell), $($report.OS), $runRoot"
        $childReport = Join-Path $runRoot 'checks.json'
        $shell = (Get-Process -Id $PID).Path
        . (Join-Path $PSScriptRoot 'invoke-dwm-monitored-test.ps1')
        Invoke-DwmMonitoredTest -OutputRoot $report.DwmMonitorRoot -TestAction {
            # 上限は全プローブの合計。タイムアウトでも外側の DWM 監視は通常終了させる。
            & $runner --timeout-seconds $TimeoutSeconds $shell -NoProfile -File $PSCommandPath `
                -IsolatedChild -Candidate $Candidate -WorkspaceRoot $runRoot -ReportPath $childReport
            if ($LASTEXITCODE -ne 0) { throw "Release スモークが失敗しました (exit=$LASTEXITCODE): $runRoot" }
        }
        $child = Get-Content -LiteralPath $childReport -Raw | ConvertFrom-Json
        if ($child.Status -ne 'passed' -or @($child.Checks).Count -ne 12) {
            throw 'Release スモークの全チェック完了を確認できません。'
        }
        if ((Get-FileHash -LiteralPath $Candidate).Hash -ne $report.CandidateSha256) {
            throw '検証中に配布対象 DLL が変更されました。'
        }
        $report.Checks = @($child.Checks)
        $report.Status = 'passed'
        # 成功した正常系の入力・展開物だけを清掃し、計測と合否の記録は残す。
        $work = [IO.Path]::GetFullPath((Join-Path $runRoot 'work'))
        if (!$work.StartsWith($runRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw '試験用作業領域が実行ディレクトリーの外側です。'
        }
        $links = @(Get-Item -LiteralPath $work) + @(Get-ChildItem -LiteralPath $work -Recurse -Force)
        if (@($links | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw '試験用作業領域にリンクがあるため清掃を停止しました。'
        }
        Remove-Item -LiteralPath $work -Recurse -Force
        if (Test-Path -LiteralPath $work) { throw '試験用作業領域を清掃できませんでした。' }
    } catch {
        $report.Status = 'failed'
        $report['Error'] = $_.Exception.Message
        throw
    } finally {
        $report.ElapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
    }
    Write-Host "Release smoke passed: $($report.Checks.Count) checks, $($report.ElapsedSeconds)s; $ReportPath"
    return
}

& $runner --require-isolated
if ($LASTEXITCODE -ne 0) { throw 'Release スモークは分離デスクトップ内で実行してください。' }
$checks = [Collections.Generic.List[object]]::new()
$workRoot = Join-Path $WorkspaceRoot 'work'
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

function Test-ReleaseCheck([string]$Name, [scriptblock]$Action) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & $Action
    $elapsed = [math]::Round($timer.Elapsed.TotalSeconds, 3)
    $checks.Add([pscustomobject]@{ Name=$Name; Status='passed'; Seconds=$elapsed })
    Write-Host "Release smoke: $Name passed ($elapsed s)"
}
function Invoke-ReleaseProbe([string]$Label, [string[]]$Arguments, [string[]]$Expected = @()) {
    $rows = @(& $probe --registry '' @Arguments)
    $code = $LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $WorkspaceRoot "$Label.log"), [string[]]$rows, [Text.UTF8Encoding]::new($false))
    if ($code -ne 0) { throw "プローブ失敗: $Label (exit=$code)" }
    foreach ($line in $Expected) {
        if ($rows -cnotcontains $line) { throw "期待した結果がありません: $Label / $line" }
    }
    return $rows
}

Test-ReleaseCheck 'x86 ABI, exports and compatibility version' {
    $bytes = [IO.File]::ReadAllBytes($Candidate)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes,0) -ne 0x5a4d) { throw 'PE 形式ではありません。' }
    $pe = [BitConverter]::ToInt32($bytes,0x3c)
    if ($pe -lt 64 -or $pe -gt $bytes.Length-6 -or [BitConverter]::ToUInt32($bytes,$pe) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes,$pe+4) -ne 0x14c) { throw 'x86 PE DLL ではありません。' }
    $version = (Get-Item -LiteralPath $Candidate).VersionInfo
    if ($version.FileMajorPart -ne 3 -or $version.FileMinorPart -ne 0 -or
        $version.FileBuildPart -ne 0 -or $version.FilePrivatePart -ne 5) { throw '互換バージョンが 3.00.0.5 ではありません。' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = @(& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
    if (!$vs) { throw 'Visual Studio の C++ ツールが見つかりません。' }
    $dumpbin = Get-ChildItem -LiteralPath (Join-Path $vs[0] 'VC\Tools\MSVC') -Directory |
        Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x86\dumpbin.exe' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (!$dumpbin) { throw 'dumpbin.exe が見つかりません。' }
    $exports = @(& $dumpbin /nologo /exports $Candidate)
    if ($LASTEXITCODE -ne 0) { throw 'DLL のエクスポートを読み取れません。' }
    $actual = @($exports | ForEach-Object {
        if ($_ -match '^\s+(\d+)\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') { "$($Matches[1]):$($Matches[2])" }
    })
    $expected = @(Get-Content -LiteralPath (Join-Path $projectRoot 'src\unlhare.def') | ForEach-Object {
        if ($_ -match '^\s*(\w+)(?:=\w+)?\s+@(\d+)') { "$($Matches[2]):$($Matches[1])" }
    })
    # 原版の130公開名に、既存の全体進捗拡張1件を加えた公開面を維持する。
    if ($expected.Count -ne 131 -or $actual.Count -ne $expected.Count -or
        @(Compare-Object $expected $actual -CaseSensitive).Count) { throw '公開 ABI の名前・序数が定義と一致しません。' }
}

$roundtrip = Join-Path $workRoot 'roundtrip'
Test-ReleaseCheck 'file and memory roundtrip' {
    $null = Invoke-ReleaseProbe 'roundtrip' @('--integration',$Candidate,$roundtrip) @('integration round-trip passed')
}
$archive = Join-Path $roundtrip 'roundtrip.lzh'
Test-ReleaseCheck 'enumeration A/W 32/64 layouts' {
    $expected = @('a32','w32','a64','w64') | ForEach-Object { "$_.set=1"; "$_.clear=1"; "$_.command_result=0"; "$_.count=1" }
    $null = Invoke-ReleaseProbe 'enumeration' @('--enum-probe',$Candidate,$archive) $expected
}

# 固定された正常本文を圧縮し、DLL の復号結果を元バイト列と突き合わせる。
$methodsRoot = Join-Path $workRoot 'methods'
[IO.Directory]::CreateDirectory($methodsRoot) | Out-Null
$payloadPath = Join-Path $methodsRoot 'payload.bin'
[IO.File]::WriteAllBytes($payloadPath,[Text.Encoding]::ASCII.GetBytes(('release-payload-0123456789' * 300)))
foreach ($method in @(@{Switch='jm0';Header='-lh0-'},@{Switch='jm1';Header='-lh1-'},
        @{Switch='jm2';Header='-lh5-'},@{Switch='jm3';Header='-lh6-'},@{Switch='jm4';Header='-lh7-'})) {
    Test-ReleaseCheck "codec $($method.Header), CRC and 3 memory APIs" {
        $compressed = Join-Path $methodsRoot "$($method.Switch).lzh"
        $command = "a -+ -gm1 -n1 -y1 -h2 -$($method.Switch) `"$compressed`" `"$($methodsRoot.Replace('\','/'))/`" payload.bin"
        $null = Invoke-ReleaseProbe "create-$($method.Switch)" @('--command-probe-a',$Candidate,$command,'A') @('result=0')
        $bytes = [IO.File]::ReadAllBytes($compressed)
        if ($bytes.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($bytes,2,5) -cne $method.Header) {
            throw "指定した圧縮方式ではありません: $($method.Switch)"
        }
        $rows = @(Invoke-ReleaseProbe "payload-$($method.Switch)" @('--legacy-payload-probe',$Candidate,$compressed,$payloadPath,'quiet'))
        if ($rows.Count -ne 3 -or @($rows -notmatch ',payload=1,prefix=1,tail=1,guard=1$').Count) {
            throw "本文またはメモリガードが一致しません: $($method.Switch)"
        }
        $rows = @(Invoke-ReleaseProbe "crc-$($method.Switch)" @('--check-existing-archive-probe',$Candidate,$compressed,'2'))
        if ($rows.Count -ne 3 -or @($rows -notmatch '^check\.existing\.\d+\.\d+=1,error=0,system=38$').Count) {
            throw "正常書庫の CRC 検証に失敗しました: $($method.Switch)"
        }
    }
}
Test-ReleaseCheck 'Unicode paths, names and extracted bytes' {
    $expected = @('unicode-command.add.rc=0','unicode-command.archive.exists=1','unicode-command.check=1',
        'unicode-command.count=1','unicode-command.open=1','unicode-command.find=0','unicode-command.original=513',
        'unicode-command.extract.rc=0','unicode-command.extract.exists=1','unicode-command.extract.payload=1')
    $null = Invoke-ReleaseProbe 'unicode' @('--unicode-command-probe',$Candidate,(Join-Path $workRoot 'unicode')) $expected
}
Test-ReleaseCheck 'host signal handler preservation' {
    & (Join-Path $PSScriptRoot 'test-signal-handler.ps1') -TestProgram $probe -Candidate $Candidate `
        -DesktopRunner $runner -Workspace (Join-Path $workRoot 'signal') | Out-Host
}
Test-ReleaseCheck 'concurrent entry and subsequent reuse' {
    $null = Invoke-ReleaseProbe 'concurrent' @('--concurrent-entry-probe',$Candidate,$archive,'8','3') `
        @('iterations=3,workers=8,success=3,busy=21')
}
Test-ReleaseCheck 'data retention on rejected update and move' {
    & (Join-Path $PSScriptRoot 'test-safety-exceptions.ps1') -TestProgram $probe -Candidate $Candidate `
        -Workspace (Join-Path $workRoot 'retention') -Apis W -Layouts w64 | Out-Host
}

@{Status='passed';Checks=@($checks)} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
