[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('ascii','japanese')][string[]]$TempNames = @('ascii','japanese'),
    [ValidateSet(0,1)][int[]]$UnicodeModes = @(0,1),
    [ValidateSet('A','W')][string[]]$Apis = @('A','W'),
    [ValidateSet('auto','a32','w32','a64','w64')][string[]]$ProgressLayouts = @('auto'),
    [string]$ArchiveFileName = 'archive.lzh'
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
if ([string]::IsNullOrWhiteSpace($ArchiveFileName) -or
    [IO.Path]::GetFileName($ArchiveFileName) -cne $ArchiveFileName) {
    throw 'ArchiveFileName must be a non-empty file name without a directory'
}
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$parseErrors)
$helper = $helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if ($parseErrors.Count -or !$helper) { throw 'Cannot load bounded probe helper' }
. ([scriptblock]::Create($helper.Extent.Text))
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @($TestProgram,$Oracle,$Candidate,$runner,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{ Path=$_; SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'binaries.json') -Encoding utf8
function Set-Input([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}
function ConvertTo-ProgressPathText([string]$Value,[string]$Api,[int]$UnicodeMode) {
    $builder = [Text.StringBuilder]::new()
    if ($Api -eq 'W') {
        foreach ($character in $Value.ToCharArray()) {
            $code = [int]$character
            if ($code -eq 0x5c -or $code -eq 0x22) {
                [void]$builder.Append('\').Append($character)
            } elseif ($code -ge 0x20 -and $code -lt 0x7f) {
                [void]$builder.Append($character)
            } else {
                [void]$builder.Append(('\u{0:X4}' -f $code))
            }
        }
    } else {
        $encoding = if ($UnicodeMode) { [Text.UTF8Encoding]::new($false) } else { [Text.Encoding]::GetEncoding(932) }
        foreach ($byte in $encoding.GetBytes($Value)) {
            if ($byte -eq 0x5c -or $byte -eq 0x22) {
                [void]$builder.Append('\').Append([char]$byte)
            } elseif ($byte -ge 0x20 -and $byte -lt 0x7f) {
                [void]$builder.Append([char]$byte)
            } else {
                [void]$builder.Append(('\x{0:X2}' -f $byte))
            }
        }
    }
    $builder.ToString()
}
function Test-Cp932Representable([string]$Value) {
    $encoding = [Text.Encoding]::GetEncoding(
        932,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
    try {
        [void]$encoding.GetBytes($Value)
        $true
    } catch [Text.EncoderFallbackException] {
        $false
    }
}
function Normalize-TemporaryPathRows([string[]]$Rows,[string]$Root) {
    # 実行領域だけを吸収する。一時ディレクトリ名の符号化は比較対象なので置換しない。
    $uniqueRootForms = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    @(
        $Root,
        $Root.Replace('\','/'),
        $Root.Replace('\','\\'),
        (ConvertTo-ProgressPathText $Root 'W' 0),
        (ConvertTo-ProgressPathText $Root 'A' 0),
        (ConvertTo-ProgressPathText $Root 'A' 1)
    ) | ForEach-Object { [void]$uniqueRootForms.Add($_) }
    $rootForms = @($uniqueRootForms) | Sort-Object Length -Descending
    @($Rows | ForEach-Object {
        $row = $_
        foreach ($rootForm in $rootForms) { $row = $row.Replace($rootForm,'<ROOT>') }
        # GetTempFileName が割り当てる番号だけを除き、LHT の場所・拡張子・文字表現は維持する。
        $row -creplace 'LHT[0-9A-Fa-f]+[.]tmp','LHT<ID>.tmp'
    })
}
function Normalize-ValidatedAccessRows(
    [string[]]$Rows,[string]$Side,[long]$SourceTime,[long]$Started,[long]$Ended,[string]$Label
) {
    $currentSourceAccess = $null
    $sourceBeginCount = 0
    $sourceMetadataCount = 0
    $normalized = @(foreach ($inputRow in $Rows) {
        $row = $inputRow
        if ($row -match '^progress[.]entry=.*?,state=5,') {
            # 原版の SEARCH 数値欄は未初期化。候補の初期化は比較から除く前に独立して要求する。
            $zeroFields = ',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source='
            if ($Side -eq 'reimpl' -and !$row.Contains($zeroFields)) {
                throw "Candidate SEARCH metadata is not initialized: $Label"
            }
            $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=',',metadata=undefined,source='
        }
        $sourceAudit = [regex]::Match($row,',source-access-audit=(\d+)')
        if ($sourceAudit.Success) {
            $audit = [long]$sourceAudit.Groups[1].Value
            if ($audit -ne $SourceTime -and ($audit -lt $Started -or $audit -gt $Ended)) {
                throw "Source access audit is outside the fixed/runtime range: $Label"
            }
            $row = $row -replace ',source-access-audit=\d+',(
                ',source-access-audit=' + $(if ($audit -eq $SourceTime) { 'fixed' } else { 'refreshed' })
            )
        }
        $findAudit = [regex]::Match($row,',source-find-access-audit=(\d+)')
        if ($findAudit.Success) {
            $audit = [long]$findAudit.Groups[1].Value
            if ($audit -ne $SourceTime -and ($audit -lt $Started -or $audit -gt $Ended)) {
                throw "Source find-access audit is outside the fixed/runtime range: $Label"
            }
            if ($row -match ",state=0,.*?,create=$SourceTime,") {
                $currentSourceAccess = $audit
                $sourceBeginCount++
            }
            $row = $row -replace ',source-find-access-audit=\d+',(
                ',source-find-access-audit=' + $(if ($audit -eq $SourceTime) { 'fixed' } else { 'refreshed' })
            )
        }
        if ($row -match "^progress[.]entry=.*?,create=$SourceTime,access=(\d+),write-time=(\d+),") {
            $sourceMetadataCount++
            if ($null -eq $currentSourceAccess -or [long]$Matches[1] -ne $currentSourceAccess -or
                [long]$Matches[2] -ne $SourceTime) {
                throw "Progress source times do not match the independently audited file: $Label`n$inputRow"
            }
            $row = $row -replace ',access=\d+,',',access=<audited-source>,'
        }
        $row
    })
    if ($sourceBeginCount -ne 1 -or $sourceMetadataCount -lt 1) {
        throw "Audited source progress metadata is missing: $Label, BEGIN=$sourceBeginCount, rows=$sourceMetadataCount"
    }
    $normalized
}
function Assert-TemporaryProgressSources([string[]]$Rows,[string]$ExpectedSource,[string]$Label) {
    $progressRows = @($Rows | Where-Object { $_ -match '^progress[.]entry=.*?,state=\d+,' })
    $copySeen = $false
    $copyCount = 0
    $temporaryInProcessCount = 0
    foreach ($row in $progressRows) {
        if ($row -match '^progress[.]entry=.*?,state=4,') {
            $copySeen = $true
            $copyCount++
            if (!$row.Contains($ExpectedSource)) { throw "COPY source is not the expected full TEMP path: $Label`n$row" }
        } elseif ($copySeen -and $row -match '^progress[.]entry=.*?,state=1,') {
            $temporaryInProcessCount++
            if (!$row.Contains($ExpectedSource)) { throw "Post-COPY INPROCESS source is not the expected full TEMP path: $Label`n$row" }
        }
    }
    if ($copyCount -ne 1 -or $temporaryInProcessCount -lt 1) {
        throw "Temporary COPY/INPROCESS progress is missing: $Label, COPY=$copyCount, INPROCESS=$temporaryInProcessCount"
    }
}
$seedRoot = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedRoot | Out-Null
foreach ($name in 'a.txt','z.txt') { Set-Input (Join-Path $seedRoot $name) "old-$name" 2020 }
$seed = Join-Path $Workspace 'seed.lzh'
$seedRows = @(Invoke-EnumProbe (Join-Path $Workspace 'seed-command') @('--command-probe',$Oracle,"a -h2 -jm0 -n1 -gm1 -y1 `"$seed`" `"$seedRoot\`" a.txt z.txt"))
if ($seedRows -notcontains 'result=0') { throw 'Cannot create seed archive' }
$seedHash = (Get-FileHash -LiteralPath $seed).Hash
$archiveNeedsWideReader = !(Test-Cp932Representable $ArchiveFileName)
$count = 0
foreach ($tempName in $TempNames) { foreach ($mode in $UnicodeModes) { foreach ($api in $Apis) { foreach ($requestedLayout in $ProgressLayouts) {
    $progressLayout = if ($requestedLayout -eq 'auto') {
        if ($api -eq 'W') { 'w64' } else { 'a64' }
    } else { $requestedLayout }
    $callbackApi = if ($progressLayout.StartsWith('w')) { 'W' } else { 'A' }
    $label = "$tempName-$mode-$api" + $(if ($requestedLayout -eq 'auto') { '' } else { "-$requestedLayout" })
    $pair = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace "$label-$side"
        $source = Join-Path $root 'source'
        $temporary = Join-Path $root $(if ($tempName -eq 'japanese') { '日本語-temp' } else { 'ascii-temp' })
        New-Item -ItemType Directory -Path $source,$temporary | Out-Null
        $inputPath = Join-Path $source 'a.txt'
        Set-Input $inputPath 'new-a.txt' 2024
        $sourceTime = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc).ToFileTimeUtc()
        $archive = Join-Path $root $ArchiveFileName
        Copy-Item -LiteralPath $seed -Destination $archive
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $previousTemp = [Environment]::GetEnvironmentVariable('TEMP','Process')
        $previousTmp = [Environment]::GetEnvironmentVariable('TMP','Process')
        try {
            # 子プローブだけに専用 TEMP を継承させ、他の作業や OS の設定には保存しない。
            [Environment]::SetEnvironmentVariable('TEMP',$temporary,'Process')
            [Environment]::SetEnvironmentVariable('TMP',$temporary,'Process')
            $command = "u -h2 -jm0 -n1 -gm1 -y1 -c1 `"$archive`" `"$source\`" a.txt"
            $started = [datetime]::UtcNow.ToFileTimeUtc()
            $rows = @(Invoke-EnumProbe (Join-Path $root 'command') @(
                '--progress-sequence-probe',$dll,'none','1041',"$mode",$api,$progressLayout,
                "@audit-access:$inputPath",'@audit-find-access','@full-progress-paths',$command
            ))
            $ended = [datetime]::UtcNow.ToFileTimeUtc()
        } finally {
            [Environment]::SetEnvironmentVariable('TEMP',$previousTemp,'Process')
            [Environment]::SetEnvironmentVariable('TMP',$previousTmp,'Process')
        }
        $archiveSize = if (Test-Path -LiteralPath $archive) { (Get-Item -LiteralPath $archive).Length } else { -1 }
        if ($rows -notcontains 'result=0') { throw "Temporary-path update failed: $label/$side, archive-size=$archiveSize`n$($rows -join "`n")" }
        if ($rows -notcontains 'progress.set=1' -or $rows -notcontains 'progress.kill=1') {
            throw "Temporary-path progress registration failed: $label/$side"
        }
        foreach ($member in 'a.txt','z.txt') {
            $expected = if ($member -eq 'a.txt') { 'new-a.txt' } else { 'old-z.txt' }
            foreach ($reader in 'oracle','reimpl') {
                $readerDll = if ($reader -eq 'oracle') { $Oracle } else { $Candidate }
                $readCommand = "p -n1 -gm1 `"$archive`" $member"
                $readArguments = if ($archiveNeedsWideReader) {
                    @('--base-command-probe',$readerDll,$readCommand,'1041','0','W','none','0')
                } else {
                    @('--command-probe',$readerDll,$readCommand)
                }
                $data = @(Invoke-EnumProbe (Join-Path $root "read-$reader-$member") $readArguments)
                if ($data -notcontains 'result=0' -or $data -notcontains ('output="' + $expected + '"')) { throw "Stored data lost: $label/$side/$reader/$member" }
            }
        }
        if ([IO.File]::ReadAllText((Join-Path $source 'a.txt')) -cne 'new-a.txt') { throw 'Source changed' }
        if (@(Get-ChildItem -LiteralPath $temporary -Force).Count) { throw "Temporary archive remains: $label/$side" }
        $normalized = @(Normalize-ValidatedAccessRows $rows $side $sourceTime $started $ended "$label/$side")
        $normalized = @(Normalize-TemporaryPathRows $normalized $root)
        $temporaryLeaf = Split-Path -Leaf $temporary
        $expectedSource = 'source=raw="<ROOT>' +
            (ConvertTo-ProgressPathText "/$temporaryLeaf/LHT<ID>.tmp" $callbackApi $mode) + '"'
        Assert-TemporaryProgressSources $normalized $expectedSource "$label/$side"
        $pair += ,$normalized
    }
    $difference = @(Compare-Object $pair[0] $pair[1] -CaseSensitive -SyncWindow 0)
    if ($difference.Count) { throw "Temporary-path state/output mismatch: $label`n$($difference | Out-String)" }
    $count++
    Write-Host "Compression temporary paths: passed $label ($count)"
} } } }
if ((Get-FileHash -LiteralPath $seed).Hash -cne $seedHash) { throw 'Seed changed' }
foreach ($entry in $hashes) { if ((Get-FileHash -LiteralPath $entry.Path).Hash -cne $entry.SHA256) { throw "Changed during test: $($entry.Path)" } }
Write-Host "Compression temporary paths: $count COPY/INPROCESS full-source-path, update/output/error/source-retention and cross-reader archive comparisons passed"
