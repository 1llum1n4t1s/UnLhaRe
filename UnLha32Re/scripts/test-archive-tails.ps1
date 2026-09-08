[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$EmptyArchive,
    [Parameter(Mandatory)][string]$DataArchive,
    [switch]$ReportDifferences,
    [switch]$FreshJoinOnly
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$EmptyArchive = (Resolve-Path -LiteralPath $EmptyArchive).Path
$DataArchive = (Resolve-Path -LiteralPath $DataArchive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$script:tailCases = 0
$script:tailSnapshots = 0
$script:tailFailures = 0

function Invoke-TailProbe([string]$Probe, [string]$Library, [string[]]$Values) {
    $arguments = @('--registry', '', $Probe, $Library) + $Values
    $rows = @(& $TestProgram @arguments)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $rows.Count -eq 0) {
        throw "末尾判定試験が実行できません: $Probe / $($Values -join ' ')"
    }
    return $rows
}

function Compare-TailProbe([string]$Probe, [string[]]$Values) {
    $expected = @(Invoke-TailProbe $Probe $Oracle $Values)
    $actual = @(Invoke-TailProbe $Probe $Candidate $Values)
    $difference = @(Compare-Object $expected $actual -SyncWindow 0)
    if ($difference.Count -ne 0) {
        $details = $difference | Select-Object -First 6 | ForEach-Object {
            $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
            "$side`: $($_.InputObject)"
        } | Out-String -Width 1000
        $message = "末尾判定が一致しません: $Probe / $($Values -join ' ')`n$details"
        if (!$ReportDifferences) { throw $message }
        Write-Host $message
        $script:tailFailures++
    }
    $script:tailCases++
    $script:tailSnapshots += $expected.Count
}

function Normalize-TailRows([string[]]$Rows, [string]$Root) {
    $slashRoot = $Root.Replace('\', '/')
    $escapedRoot = $Root.Replace('\', '\\')
    foreach ($row in $Rows) {
        $row.Replace($slashRoot, '<ROOT>').Replace($escapedRoot, '<ROOT>').Replace($Root, '<ROOT>')
    }
}

$fixtureDirectories = @()
foreach ($inputArchive in @($EmptyArchive, $DataArchive)) {
    $directory = Join-Path $Workspace ('fixtures-' + $fixtureDirectories.Count)
    & $TestProgram --create-open-size-fixtures $inputArchive $directory
    if ($LASTEXITCODE -ne 0) { throw '末尾判定 fixture の作成に失敗しました。' }
    $fixtureDirectories += $directory
    foreach ($fixture in Get-ChildItem -LiteralPath $directory -Filter '*.lzh' -File) {
        if (!$FreshJoinOnly) {
            Compare-TailProbe '--check-existing-archive-probe' @($fixture.FullName)
            # このプローブは多数のメモリ API を連続実行する。進捗ダイアログは専用試験で
            # 通常表示を比較済みなので、ここでは末尾判定そのものを確実に比較する。
            Compare-TailProbe '--archive-tail-probe' @($fixture.FullName, 'quiet')
            foreach ($api in 0..5) {
                Compare-TailProbe '--open-state-probe' @($fixture.FullName, '@valid', "$api", 'retry')
            }
            if ($fixture.BaseName -in @('size-55', 'size-64', 'size-79', 'size-511',
                    'tail-80-zip', 'tail-125', 'tail-129', 'empty-lh0', 'empty-lh5')) {
                foreach ($command in @('l', 'v', 't', 'p', 'l -n1', 'l -n2',
                        'l -jsg0', 't -jsg0', 'p -jsg0', 'l -jsg1 -jsg0', 'l -jsg0 -jsg1')) {
                    $line = $command + ' -gm1 "' + $fixture.FullName + '"'
                    Compare-TailProbe '--command-probe' @($line)
                    Compare-TailProbe '--command-probe-a' @($line)
                    Compare-TailProbe '--command-probe-a' @($line, 'A')
                }
            }
        }
    }
}

# 拒否される書庫への更新・展開は、すべて専用入力と専用出力だけで試す。
$foreignSource = Join-Path $fixtureDirectories[0] 'tail-80-zip.lzh'
$sourceHash = (Get-FileHash -LiteralPath $foreignSource).Hash
$foreignOnlySource = Join-Path $Workspace 'zip-directory-only.lzh'
[IO.File]::WriteAllBytes($foreignOnlySource, [byte[]](0x50, 0x4B, 0x01, 0x02, 0, 0, 0, 0, 0, 0))
$foreignOnlyHash = (Get-FileHash -LiteralPath $foreignOnlySource).Hash
$prefixedForeignSource = Join-Path $Workspace 'prefixed-lzh-with-zip-tail.lzh'
$foreignSourceBytes = [IO.File]::ReadAllBytes($foreignSource)
$prefixedForeignBytes = New-Object byte[] ($foreignSourceBytes.Length + 2)
$prefixedForeignBytes[0] = 0xAA
$prefixedForeignBytes[1] = 0xBB
[Array]::Copy($foreignSourceBytes, 0, $prefixedForeignBytes, 2, $foreignSourceBytes.Length)
# ZIP ディレクトリのオフセットは絶対位置なので、2 バイトのプレフィックスを加えた後も
# 合成した foreign-tail の参照先が有効になるよう補正する。
$foreignDirectoryOffset = [BitConverter]::ToUInt32($foreignSourceBytes, $foreignSourceBytes.Length - 6)
$prefixedDirectoryOffset = [BitConverter]::GetBytes([uint32]($foreignDirectoryOffset + 2))
[Array]::Copy($prefixedDirectoryOffset, 0, $prefixedForeignBytes, $prefixedForeignBytes.Length - 6,
              $prefixedDirectoryOffset.Length)
[IO.File]::WriteAllBytes($prefixedForeignSource, $prefixedForeignBytes)
$prefixedForeignHash = (Get-FileHash -LiteralPath $prefixedForeignSource).Hash
if (!$FreshJoinOnly) {
    $member = Join-Path $Workspace 'member.lzh'
    Copy-Item -LiteralPath $EmptyArchive -Destination $member
    foreach ($variant in @('legacy', 'A', 'W', 'unicode-W')) {
        $directory = Join-Path $Workspace $variant
        New-Item -ItemType Directory -Path $directory | Out-Null
        $archive = Join-Path $directory $(if ($variant -eq 'unicode-W') { '書庫_🧪.lzh' } else { 'input.lzh' })
        Copy-Item -LiteralPath $foreignSource -Destination $archive
        $output = Join-Path $directory 'output'
        New-Item -ItemType Directory -Path $output | Out-Null
        foreach ($command in @('a', 'u', 'f', 'm', 'd', 'e', 'x', 'j', 'y', 'n', 'c', 's')) {
            $line = $command + ' -gm1 -y1 "' + $archive + '"'
            if ($command -in @('a', 'u', 'f', 'm', 'j')) { $line += ' "' + $member + '"' }
            elseif ($command -in @('e', 'x', 's')) { $line += ' "' + $output + '\"' }
            else { $line += ' *' }
            if ($variant -eq 'legacy') { Compare-TailProbe '--command-probe-a' @($line) }
            elseif ($variant -eq 'A') { Compare-TailProbe '--command-probe-a' @($line, 'A') }
            else { Compare-TailProbe '--command-probe' @($line) }
            if (!(Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash -ne $sourceHash -or
                    !(Test-Path -LiteralPath $member) -or @(Get-ChildItem -LiteralPath $output -Force).Count -ne 0) {
                throw "拒否された書庫または入力・展開先が変更されています: $variant / $command"
            }
        }
    }
}

# 新規 j は、有効 LZH に付いた ZIP 末尾と ZIP ディレクトリだけの入力を別契約で判定する。
# Compare-TailProbe は同じ新規出力を順に使えないため、拒否時は原版の後始末を確認してから
# 候補を同じ入力で実行し、許可時は両 DLL 用の新規出力を分ける。
$joinSourceApis = @(
    [pscustomobject]@{ Name = 'W'; Probe = '--command-probe'; Extra = @() },
    [pscustomobject]@{ Name = 'legacy'; Probe = '--command-probe-a'; Extra = @() },
    [pscustomobject]@{ Name = 'A'; Probe = '--command-probe-a'; Extra = @('A') }
)
$joinForeignRejectCases = 0
$joinForeignAllowCases = 0
$joinForeignSequenceCases = 0
$joinForeignRejectSources = @(
    [pscustomobject]@{ Name = 'lzh-with-zip-tail'; Source = $foreignSource; Hash = $sourceHash;
        Switches = @(
            [pscustomobject]@{ Name = 'default'; Switch = '' },
            [pscustomobject]@{ Name = 'jsg1'; Switch = '-jsg1' }) },
    [pscustomobject]@{ Name = 'zip-directory-only'; Source = $foreignOnlySource; Hash = $foreignOnlyHash;
        Switches = @(
            [pscustomobject]@{ Name = 'default'; Switch = '' },
            [pscustomobject]@{ Name = 'jsg1'; Switch = '-jsg1' },
            [pscustomobject]@{ Name = 'jsg0'; Switch = '-jsg0' }) }
)
$joinForeignAllowSources = @(
    [pscustomobject]@{ Name = 'lzh-with-zip-tail'; Source = $foreignSource; Hash = $sourceHash },
    [pscustomobject]@{ Name = 'prefix2-lzh-with-zip-tail'; Source = $prefixedForeignSource; Hash = $prefixedForeignHash }
)

function Assert-FreshJoinForeignReject([string[]]$Rows, [string]$Source, [string]$Archive,
                                        [string]$ExpectedHash, [string]$Label) {
    if (@($Rows -ceq 'result=32795').Count -ne 1 -or
            @($Rows -ceq 'win32-error=0').Count -ne 1 -or
            @($Rows -ceq 'compat-error=32795').Count -ne 1 -or
            @($Rows -ceq 'compat-system-error=2').Count -ne 1) {
        throw "新規連結元の他形式拒否のエラー状態が不正です: $Label"
    }
    $output = @($Rows | Where-Object { $_ -like 'output=*' })
    $displaySource = $Source.Replace('\', '/')
    if ($output.Count -ne 1 -or $output[0] -notlike '*(on arccopy)*' -or
            $output[0].IndexOf($displaySource, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "新規連結元の他形式拒否の出力が不正です: $Label"
    }
    if (Test-Path -LiteralPath $Archive) {
        throw "拒否された新規連結先が残っています: $Label"
    }
    if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -cne $ExpectedHash) {
        throw "拒否された新規連結元が変更されています: $Label"
    }
    $folder = Split-Path -Parent $Archive
    if (@(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count -ne 0) {
        throw "拒否後に一時書庫が残っています: $Label"
    }
}

foreach ($api in $joinSourceApis) {
    foreach ($foreign in $joinForeignRejectSources) {
        foreach ($switchCase in $foreign.Switches) {
            $folder = Join-Path $Workspace ("join-source-reject-{0}-{1}-{2}" -f $api.Name,$foreign.Name,$switchCase.Name)
            New-Item -ItemType Directory -Path $folder | Out-Null
            $source = Join-Path $folder 'source.lzh'
            $archive = Join-Path $folder 'joined.lzh'
            Copy-Item -LiteralPath $foreign.Source -Destination $source
            $line = "j -gm1 -y1"
            if ($switchCase.Switch) { $line += " $($switchCase.Switch)" }
            $line += " `"$archive`" `"$source`""
            $values = @($line) + @($api.Extra)
            $expected = @(Invoke-TailProbe $api.Probe $Oracle $values)
            Assert-FreshJoinForeignReject $expected $source $archive $foreign.Hash "original/$($api.Name)/$($foreign.Name)/$($switchCase.Name)"
            $actual = @(Invoke-TailProbe $api.Probe $Candidate $values)
            Assert-FreshJoinForeignReject $actual $source $archive $foreign.Hash "candidate/$($api.Name)/$($foreign.Name)/$($switchCase.Name)"
            $difference = @(Compare-Object $expected $actual -SyncWindow 0)
            if ($difference.Count -ne 0) {
                $details = $difference | Select-Object -First 6 | ForEach-Object {
                    $side = if ($_.SideIndicator -eq '<=') { 'original' } else { 'candidate' }
                    "$side`: $($_.InputObject)"
                } | Out-String -Width 1000
                $message = "新規連結元の他形式拒否が一致しません: $($api.Name) / $($foreign.Name) / $($switchCase.Name)`n$details"
                if (!$ReportDifferences) { throw $message }
                Write-Host $message
                $script:tailFailures++
            }
            $script:tailCases++
            $script:tailSnapshots += $expected.Count
            $joinForeignRejectCases++
        }
    }

    foreach ($foreign in $joinForeignAllowSources) {
        $contractRows = @{}
        $contractHashes = @{}
        foreach ($side in @(
                [pscustomobject]@{ Name = 'oracle'; Directory = 'oracle'; Library = $Oracle },
                [pscustomobject]@{ Name = 'candidate'; Directory = 'reimpl'; Library = $Candidate })) {
            $folder = Join-Path $Workspace ("join-source-allow-{0}-{1}-{2}" -f $api.Name,$foreign.Name,$side.Directory)
            New-Item -ItemType Directory -Path $folder | Out-Null
            $source = Join-Path $folder 'source.lzh'
            $archive = Join-Path $folder 'joined.lzh'
            Copy-Item -LiteralPath $foreign.Source -Destination $source
            $line = "j -gm1 -y1 -jsg0 `"$archive`" `"$source`""
            $rows = @(Invoke-TailProbe $api.Probe $side.Library (@($line) + @($api.Extra)))
            $outputRows = @($rows | Where-Object { $_ -like 'output=*' })
            $archiveInfo = Get-Item -LiteralPath $archive -ErrorAction SilentlyContinue
            $outputLengthRows = @($rows | Where-Object { $_ -match '^output-length=\d+$' })
            if (@($rows -ceq 'result=0').Count -ne 1 -or @($rows -ceq 'win32-error=0').Count -ne 1 -or
                    @($rows -ceq 'compat-error=0').Count -ne 1 -or @($rows -ceq 'compat-system-error=2').Count -ne 1 -or
                    $outputRows.Count -ne 1 -or !$archiveInfo -or $archiveInfo.PSIsContainer -or
                    $archiveInfo.Length -le 0 -or
                    ($api.Probe -eq '--command-probe-a' -and
                        ($outputLengthRows.Count -ne 1 -or [int]$outputLengthRows[0].Substring(14) -le 0)) -or
                    ($api.Probe -ne '--command-probe-a' -and $outputLengthRows.Count -ne 0)) {
                throw "新規連結元の -jsg0 許可状態が不正です: $($side.Name)/$($api.Name)/$($foreign.Name)"
            }
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $foreign.Hash -or
                    @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count -ne 0) {
                throw "-jsg0 許可後の入力または一時書庫状態が不正です: $($side.Name)/$($api.Name)/$($foreign.Name)"
            }
            $contractRows[$side.Name] = @(Normalize-TailRows @($rows | Where-Object {
                    $_ -notmatch '^output-length='
                }) $folder)
            $contractHashes[$side.Name] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        }
        if (@(Compare-Object $contractRows.oracle $contractRows.candidate -SyncWindow 0).Count -ne 0) {
            throw "新規連結元の -jsg0 許可出力が一致しません: $($api.Name) / $($foreign.Name)"
        }
        if ($contractHashes.oracle -cne $contractHashes.candidate) {
            throw "新規連結元の -jsg0 許可書庫が一致しません: $($api.Name) / $($foreign.Name)"
        }
        $joinForeignAllowCases++
    }
}

$sequenceRows = @{}
$sequenceHashes = @{}
$normalJoinHash = (Get-FileHash -LiteralPath $EmptyArchive -Algorithm SHA256).Hash
foreach ($side in @(
        [pscustomobject]@{ Name = 'oracle'; Directory = 'oracle'; Library = $Oracle },
        [pscustomobject]@{ Name = 'candidate'; Directory = 'reimpl'; Library = $Candidate })) {
    $folder = Join-Path $Workspace ("join-source-sequence-{0}" -f $side.Directory)
    New-Item -ItemType Directory -Path $folder | Out-Null
    $tail = Join-Path $folder 'tail.lzh'
    $normal = Join-Path $folder 'normal.lzh'
    $firstArchive = Join-Path $folder 'foreignallowed.lzh'
    $secondArchive = Join-Path $folder 'normal.out'
    Copy-Item -LiteralPath $foreignSource -Destination $tail
    Copy-Item -LiteralPath $EmptyArchive -Destination $normal
    $first = "j -gm1 -y1 -jsg0 `"$firstArchive`" `"$tail`""
    # 原版の通常表示の連続生成で停止する経路を避け、再利用側の末尾判定を分離する。
    # 第1呼び出しの通常表示と、別の結合進捗試験の通知比較は維持する。
    $second = "j -gm1 -y1 -n1 `"$secondArchive`" `"$normal`""
    $rows = @(Invoke-TailProbe '--command-sequence-probe' $side.Library @($first, $second))
    if (@($rows -ceq 'phase=first').Count -ne 1 -or @($rows -ceq 'phase=second').Count -ne 1 -or
            @($rows -ceq 'result=0').Count -ne 2 -or @($rows -ceq 'compat-system-error=2').Count -ne 1 -or
            @($rows -ceq 'compat-system-error=38').Count -ne 1 -or
            !(Test-Path -LiteralPath $firstArchive) -or !(Test-Path -LiteralPath $secondArchive) -or
            (Get-Item -LiteralPath $firstArchive).Length -le 0 -or
            (Get-Item -LiteralPath $secondArchive).Length -le 0 -or
            (Get-FileHash -LiteralPath $tail -Algorithm SHA256).Hash -cne $sourceHash -or
            (Get-FileHash -LiteralPath $normal -Algorithm SHA256).Hash -cne $normalJoinHash -or
            @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count -ne 0) {
        throw "新規連結元の許可後再利用状態が不正です: $($side.Name)"
    }
    $sequenceRows[$side.Name] = @(Normalize-TailRows $rows $folder)
    $sequenceHashes[$side.Name] = @(
        (Get-FileHash -LiteralPath $firstArchive -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $secondArchive -Algorithm SHA256).Hash
    )
}
if (@(Compare-Object $sequenceRows.oracle $sequenceRows.candidate -SyncWindow 0).Count -ne 0 -or
        @(Compare-Object $sequenceHashes.oracle $sequenceHashes.candidate -SyncWindow 0).Count -ne 0) {
    throw '新規連結元の許可後再利用が一致しません。'
}
$joinForeignSequenceCases++

if ($joinForeignRejectCases -ne 15 -or $joinForeignAllowCases -ne 6 -or $joinForeignSequenceCases -ne 1) {
    throw "新規連結元の末尾判定マトリクス件数が不正です: reject=$joinForeignRejectCases, allow=$joinForeignAllowCases, sequence=$joinForeignSequenceCases"
}

if ($script:tailFailures -ne 0) {
    throw "末尾判定試験: $script:tailCases 組・$script:tailSnapshots 項目中、$script:tailFailures 組が不一致です。"
}
Write-Host "Archive tails: $script:tailCases API/command sequences, $script:tailSnapshots snapshots compatible; rejected writes unchanged; $joinForeignRejectCases fresh j rejections, $joinForeignAllowCases -jsg0 allows, and $joinForeignSequenceCases reuse sequence checked"
