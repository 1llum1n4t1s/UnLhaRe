[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet(0,1,2)][int[]]$Recursions = @(0,1,2),
    [ValidateSet('parent-first','parent-last')][string[]]$Orders = @('parent-first','parent-last'),
    [ValidateSet('none','exclude-txt')][string[]]$Exclusions = @('none','exclude-txt')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
foreach ($selection in @(
    @{ Name='Recursions'; Values=$Recursions },
    @{ Name='Orders'; Values=$Orders },
    @{ Name='Exclusions'; Values=$Exclusions }
)) {
    if (!$selection.Values -or @($selection.Values).Count -eq 0) { throw "$($selection.Name) must not be empty" }
    if (@($selection.Values | Select-Object -Unique).Count -ne @($selection.Values).Count) {
        throw "$($selection.Name) must not contain duplicates"
    }
}

# タイムアウト・非表示ウィンドウ・stdout/stderr の EOF 回収を既存の一箇所へ揃える。
$parseErrors = $null
$helperPath = Join-Path $PSScriptRoot 'test-enum-state.ps1'
$helperAst = [Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$null,[ref]$parseErrors)
$helper = $helperAst.Find({
    param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'
},$true)
if ($parseErrors.Count -or !$helper) { throw 'Cannot load bounded probe helper' }
. ([scriptblock]::Create($helper.Extent.Text))

function ConvertFrom-Level2NameBytes([byte[]]$Bytes) {
    if ($Bytes -contains 0) { throw 'Level-2 member name contains NUL' }
    $encoding = [Text.Encoding]::GetEncoding(
        932,[Text.EncoderFallback]::ExceptionFallback,[Text.DecoderFallback]::ExceptionFallback)
    $builder = [Text.StringBuilder]::new()
    $segment = [Collections.Generic.List[byte]]::new()
    foreach ($value in $Bytes) {
        if ($value -eq 0xff) {
            if ($segment.Count) {
                [void]$builder.Append($encoding.GetString($segment.ToArray()))
                $segment.Clear()
            }
            [void]$builder.Append('/')
        } else {
            $segment.Add($value)
        }
    }
    if ($segment.Count) { [void]$builder.Append($encoding.GetString($segment.ToArray())) }
    return $builder.ToString().Replace('\','/')
}

function Read-Level2Archive([byte[]]$Bytes) {
    if ($Bytes.Length -lt 1 -or $Bytes[-1] -ne 0) { throw 'Level-2 archive has no one-byte terminator' }
    $records = [Collections.Generic.List[object]]::new()
    $cursor = 0
    while ($cursor -lt $Bytes.Length - 1) {
        if ($Bytes[$cursor] -eq 0 -or $cursor + 26 -gt $Bytes.Length - 1) {
            throw "Invalid Level-2 record boundary at $cursor"
        }
        $headerSize = [int][BitConverter]::ToUInt16($Bytes,$cursor)
        if ($headerSize -lt 26 -or $cursor + $headerSize -gt $Bytes.Length - 1 -or $Bytes[$cursor + 20] -ne 2) {
            throw "Invalid Level-2 header at $cursor"
        }
        $packedSize = [long][BitConverter]::ToUInt32($Bytes,$cursor + 7)
        $recordSize = [long]$headerSize + $packedSize
        if ($recordSize -gt [int]::MaxValue -or $cursor + $recordSize -gt $Bytes.Length - 1) {
            throw "Invalid Level-2 packed-data boundary at $cursor"
        }
        $method = [Text.Encoding]::ASCII.GetString($Bytes,$cursor + 2,5)
        if ($method -cnotmatch '^-[A-Za-z0-9]{3}-$') { throw "Invalid Level-2 method at $cursor" }

        $filename = $null
        $dirname = ''
        $hasDirectoryHeader = $false
        $extensionSize = [int][BitConverter]::ToUInt16($Bytes,$cursor + 24)
        $extensionCursor = $cursor + 26
        while ($extensionSize) {
            if ($extensionSize -lt 3 -or $extensionCursor + $extensionSize -gt $cursor + $headerSize) {
                throw "Invalid Level-2 extended-header boundary at $cursor"
            }
            $type = $Bytes[$extensionCursor]
            $dataLength = $extensionSize - 3
            $data = [byte[]]::new($dataLength)
            if ($dataLength) { [Array]::Copy($Bytes,$extensionCursor + 1,$data,0,$dataLength) }
            if ($type -eq 1) {
                if ($null -ne $filename) { throw "Duplicate Level-2 filename header at $cursor" }
                $filename = ConvertFrom-Level2NameBytes $data
            } elseif ($type -eq 2) {
                if ($hasDirectoryHeader) { throw "Duplicate Level-2 directory header at $cursor" }
                $dirname = ConvertFrom-Level2NameBytes $data
                $hasDirectoryHeader = $true
            }
            $nextOffset = $extensionCursor + $extensionSize - 2
            $extensionSize = [int][BitConverter]::ToUInt16($Bytes,$nextOffset)
            $extensionCursor = $nextOffset + 2
        }
        $padding = $cursor + $headerSize - $extensionCursor
        if ($padding -lt 0 -or $padding -gt 1 -or ($padding -eq 1 -and $Bytes[$extensionCursor] -ne 0)) {
            throw "Invalid Level-2 header padding at $cursor"
        }
        if ($null -eq $filename) { throw "Level-2 filename header is missing at $cursor" }
        $name = ($dirname + $filename).Replace('\','/')
        $directory = $method -ceq '-lhd-'
        if ([string]::IsNullOrEmpty($name) -or ($directory -and !$name.EndsWith('/')) -or
            (!$directory -and $name.EndsWith('/'))) {
            throw "Level-2 member name/method mismatch at $cursor"
        }
        $recordBytes = [byte[]]::new([int]$recordSize)
        [Array]::Copy($Bytes,$cursor,$recordBytes,0,$recordBytes.Length)
        $records.Add([pscustomobject]@{
            Name=$name; IsDirectory=$directory; HeaderSize=$headerSize
            PackedSize=$packedSize; OriginalSize=[long][BitConverter]::ToUInt32($Bytes,$cursor + 11)
            Method=$method; Bytes=$recordBytes
        })
        $cursor += [int]$recordSize
    }
    if ($cursor -ne $Bytes.Length - 1) { throw 'Level-2 archive has trailing bytes before its terminator' }
    [pscustomobject]@{ Bytes=$Bytes; Records=@($records | ForEach-Object { $_ }) }
}

function Assert-SeedLayout($Archive) {
    $directories = @($Archive.Records | Where-Object IsDirectory)
    $files = @($Archive.Records | Where-Object { !$_.IsDirectory })
    if ($directories.Count -ne 1 -or $files.Count -ne 2) {
        throw "Seed must contain exactly one directory and two files: directories=$($directories.Count), files=$($files.Count)"
    }
    if ($directories[0].PackedSize -ne 0 -or $directories[0].OriginalSize -ne 0) {
        throw 'Seed directory record must not contain packed data'
    }
    $actual = @($Archive.Records.Name | Sort-Object)
    $expected = @('tree/','tree/keep.bin','tree/skip.txt') | Sort-Object
    if (@(Compare-Object $expected $actual -CaseSensitive -SyncWindow 0).Count) {
        throw "Unexpected seed members: $($actual -join ',')"
    }
}

function Convert-Level2ArchiveOrder([byte[]]$Bytes,[string]$Order) {
    if ($Order -cnotin @('parent-first','parent-last')) { throw "Unknown Level-2 order: $Order" }
    $archive = Read-Level2Archive $Bytes
    Assert-SeedLayout $archive
    $directory = @($archive.Records | Where-Object IsDirectory)[0]
    $files = @($archive.Records | Where-Object { !$_.IsDirectory })
    $ordered = if ($Order -ceq 'parent-first') { @($directory) + $files } else { $files + @($directory) }
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($record in $ordered) { $stream.Write($record.Bytes,0,$record.Bytes.Length) }
        $stream.WriteByte(0)
        return ,$stream.ToArray()
    } finally { $stream.Dispose() }
}

function New-SyntheticLevel2Record([string]$Name,[bool]$Directory,[byte[]]$Payload) {
    $normalized = $Name.Replace('\','/')
    $slash = $normalized.LastIndexOf('/')
    $dirnameText = if ($slash -ge 0) { $normalized.Substring(0,$slash + 1) } else { '' }
    $filenameText = if ($slash -ge 0) { $normalized.Substring($slash + 1) } else { $normalized }
    $encoding = [Text.Encoding]::ASCII
    $filename = $encoding.GetBytes($filenameText)
    $dirname = $encoding.GetBytes($dirnameText)
    for ($index = 0; $index -lt $dirname.Length; $index++) {
        if ($dirname[$index] -eq 0x2f) { $dirname[$index] = 0xff }
    }
    $extensions = [Collections.Generic.List[object]]::new()
    $extensions.Add([pscustomobject]@{ Type=0; Data=[byte[]](0,0) })
    $extensions.Add([pscustomobject]@{ Type=1; Data=$filename })
    if ($dirname.Length) { $extensions.Add([pscustomobject]@{ Type=2; Data=$dirname }) }
    $headerSize = 26 + (($extensions | ForEach-Object { 3 + $_.Data.Length } | Measure-Object -Sum).Sum)
    $record = [byte[]]::new($headerSize + $Payload.Length)
    [BitConverter]::GetBytes([uint16]$headerSize).CopyTo($record,0)
    $encoding.GetBytes($(if ($Directory) { '-lhd-' } else { '-lh0-' })).CopyTo($record,2)
    [BitConverter]::GetBytes([uint32]$Payload.Length).CopyTo($record,7)
    [BitConverter]::GetBytes([uint32]$Payload.Length).CopyTo($record,11)
    $record[20] = 2
    $offset = 26
    for ($index = 0; $index -lt $extensions.Count; $index++) {
        $extension = $extensions[$index]
        $size = 3 + $extension.Data.Length
        if ($index -eq 0) { [BitConverter]::GetBytes([uint16]$size).CopyTo($record,24) }
        $record[$offset] = $extension.Type
        if ($extension.Data.Length) { $extension.Data.CopyTo($record,$offset + 1) }
        $next = if ($index + 1 -lt $extensions.Count) { 3 + $extensions[$index + 1].Data.Length } else { 0 }
        [BitConverter]::GetBytes([uint16]$next).CopyTo($record,$offset + $size - 2)
        $offset += $size
    }
    if ($Payload.Length) { $Payload.CopyTo($record,$headerSize) }
    return ,$record
}

function Test-Level2Helpers {
    $records = @(
        (New-SyntheticLevel2Record 'tree/keep.bin' $false ([byte[]](1,2,3))),
        (New-SyntheticLevel2Record 'tree/' $true ([byte[]]::new(0))),
        (New-SyntheticLevel2Record 'tree/skip.txt' $false ([byte[]](4,5)))
    )
    $stream = [IO.MemoryStream]::new()
    try {
        foreach ($record in $records) { $stream.Write($record,0,$record.Length) }
        $stream.WriteByte(0)
        $valid = $stream.ToArray()
    } finally { $stream.Dispose() }
    $parsed = Read-Level2Archive $valid
    Assert-SeedLayout $parsed
    $first = Read-Level2Archive (Convert-Level2ArchiveOrder $valid 'parent-first')
    $last = Read-Level2Archive (Convert-Level2ArchiveOrder $valid 'parent-last')
    if (!$first.Records[0].IsDirectory -or !$last.Records[-1].IsDirectory) {
        throw 'Level-2 reorder helper did not move the complete directory record'
    }
    $fingerprints = @($parsed.Records | ForEach-Object { [Convert]::ToBase64String($_.Bytes) } | Sort-Object)
    foreach ($ordered in $first,$last) {
        $actual = @($ordered.Records | ForEach-Object { [Convert]::ToBase64String($_.Bytes) } | Sort-Object)
        if (@(Compare-Object $fingerprints $actual -CaseSensitive -SyncWindow 0).Count) {
            throw 'Level-2 reorder helper changed record bytes'
        }
    }
    $invalid = [Collections.Generic.List[byte[]]]::new()
    $invalid.Add([byte[]]$valid[0..($valid.Length - 2)])
    $wrongLevel = [byte[]]$valid.Clone(); $wrongLevel[20] = 1; $invalid.Add($wrongLevel)
    $badExtension = [byte[]]$valid.Clone(); $badExtension[24] = 0xff; $badExtension[25] = 0x7f; $invalid.Add($badExtension)
    $truncated = [byte[]]$valid[0..($valid.Length - 3)]; $truncated += [byte]0; $invalid.Add($truncated)
    foreach ($bytes in $invalid) {
        $failed = $false
        try { [void](Read-Level2Archive $bytes) } catch { $failed = $true }
        if (!$failed) { throw 'Level-2 parser accepted malformed input' }
    }
    $twoRecord = [byte[]]::new($records[0].Length + $records[1].Length + 1)
    $records[0].CopyTo($twoRecord,0); $records[1].CopyTo($twoRecord,$records[0].Length)
    $failed = $false
    try { [void](Convert-Level2ArchiveOrder $twoRecord 'parent-first') } catch { $failed = $true }
    if (!$failed) { throw 'Level-2 reorder helper accepted an incomplete seed layout' }
    return 10
}

function Set-FixedInput([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}

function Set-FixedDirectoryTime([string]$Path,[int]$Year) {
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.Directory]::SetCreationTimeUtc($Path,$time)
    [IO.Directory]::SetLastWriteTimeUtc($Path,$time)
    [IO.Directory]::SetLastAccessTimeUtc($Path,$time)
}

function New-InputTree([string]$Root,[string]$Prefix,[int]$Year,[bool]$Extra) {
    $tree = Join-Path $Root 'tree'
    New-Item -ItemType Directory -Path $tree -Force | Out-Null
    Set-FixedInput (Join-Path $tree 'keep.bin') "$Prefix-keep.bin" $Year
    Set-FixedInput (Join-Path $tree 'skip.txt') "$Prefix-skip.txt" $Year
    if ($Extra) { Set-FixedInput (Join-Path $tree 'extra.txt') "$Prefix-extra.txt" $Year }
    Set-FixedDirectoryTime $tree $Year
    Set-FixedDirectoryTime $Root $Year
}

function Get-InputSnapshot([string]$Root) {
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($path in @($Root) + @(Get-ChildItem -LiteralPath $Root -Directory -Recurse | ForEach-Object FullName)) {
        $item = Get-Item -LiteralPath $path
        $name = if ($path -ceq $Root) { '.' } else { [IO.Path]::GetRelativePath($Root,$path).Replace('\','/') }
        $rows.Add("D|$name|$($item.CreationTimeUtc.Ticks)|$($item.LastWriteTimeUtc.Ticks)")
    }
    foreach ($item in Get-ChildItem -LiteralPath $Root -File -Recurse) {
        $name = [IO.Path]::GetRelativePath($Root,$item.FullName).Replace('\','/')
        $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($item.FullName))
        $rows.Add("F|$name|$($item.CreationTimeUtc.Ticks)|$($item.LastWriteTimeUtc.Ticks)|$payload")
    }
    return @($rows | Sort-Object)
}

function Assert-SameRows([string[]]$Expected,[string[]]$Actual,[string]$Message) {
    $difference = @(Compare-Object $Expected $Actual -CaseSensitive -SyncWindow 0)
    if ($difference.Count) { throw "$Message`n$($difference | Select-Object -First 12 | Out-String -Width 2000)" }
}

function Normalize-ProbeRows([string[]]$Rows,[string]$Root) {
    @($Rows | ForEach-Object {
        $_.Replace($Root.Replace('\','/'),'<ROOT>').Replace($Root.Replace('\','\\'),'<ROOT>').Replace($Root,'<ROOT>')
    })
}

function Assert-ProbeSuccess([string[]]$Rows,[string]$Label,[bool]$RequireDirectoryPreserved) {
    if (@($Rows -ceq 'result=0').Count -ne 1 -or
        ($RequireDirectoryPreserved -and @($Rows -ceq 'directory-preserved=1').Count -ne 1)) {
        throw "Probe result is not a classified success: $Label`n$($Rows -join "`n")"
    }
}

function Test-OriginalMoveAccessDenied([string[]]$Rows) {
    return $Rows -contains 'result=32792' -and $Rows -contains 'compat-system-error=5' -and
        @($Rows -like '*on execute_cmd (MoveFile)*').Count -ne 0
}

function Get-ArchiveSnapshot([string]$Archive,[string]$Root,[string]$Label) {
    $parsed = Read-Level2Archive ([IO.File]::ReadAllBytes($Archive))
    $names = @($parsed.Records.Name | Sort-Object)
    if (@($names | Select-Object -Unique).Count -ne $names.Count) { throw "Duplicate final member: $Label" }
    $logRoot = Join-Path $Root ('inspection-' + ($Label -replace '[^A-Za-z0-9_.-]','-'))
    New-Item -ItemType Directory -Path $logRoot | Out-Null
    $snapshot = [Collections.Generic.List[string]]::new()
    foreach ($record in $parsed.Records | Sort-Object Name) {
        $snapshot.Add("member=$($record.Name),directory=$($record.IsDirectory)")
    }
    $readerSnapshots = @{}
    foreach ($reader in 'oracle','candidate') {
        $dll = if ($reader -eq 'oracle') { $Oracle } else { $Candidate }
        $readerSnapshot = [Collections.Generic.List[string]]::new()
        foreach ($operation in 'list','test') {
            $verb = if ($operation -ceq 'list') { 'l' } else { 't' }
            $rows = @(Invoke-EnumProbe (Join-Path $logRoot "read-$reader-$operation") @(
                '--base-command-probe',$dll,"$verb -n1 -gm1 `"$Archive`"",'1041','0','W','none','0'
            ) $Root)
            Assert-ProbeSuccess $rows "$Label/$reader/$operation" $true
            $readerSnapshot.Add("operation=$operation")
            $readerSnapshot.AddRange([string[]](Normalize-ProbeRows $rows $Root))
        }
        foreach ($record in $parsed.Records | Where-Object { !$_.IsDirectory } | Sort-Object Name) {
            $member = $record.Name
            $payloadRows = @(Invoke-EnumProbe (Join-Path $logRoot "read-$reader-$($member.Replace('/','-'))") @(
                '--base-command-probe',$dll,"p -n1 -gm1 `"$Archive`" `"$member`"",'1041','0','W','none','0'
            ) $Root)
            Assert-ProbeSuccess $payloadRows "$Label/$reader/$member" $true
            $readerSnapshot.Add("payload-member=$member")
            $readerSnapshot.AddRange([string[]](Normalize-ProbeRows $payloadRows $Root))
        }
        $readerSnapshots[$reader] = @($readerSnapshot)
    }
    Assert-SameRows $readerSnapshots.oracle $readerSnapshots.candidate "Archive differs between readers: $Label"
    $snapshot.AddRange([string[]]$readerSnapshots.oracle)
    return @($snapshot)
}

$pureHelperChecks = Test-Level2Helpers
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Implicit update workspace: $Workspace"
$trackedInputs = @($TestProgram,$Oracle,$Candidate,$runner,$helperPath,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{ Path=$_; SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$trackedInputs | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'inputs.json') -Encoding utf8

$seedSource = Join-Path $Workspace 'seed-source'
New-InputTree $seedSource 'old' 2020 $false
$seedInputSnapshot = Get-InputSnapshot $seedSource
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedCommand = "a -h2 -jm0 -d1 -x1 -n1 -gm1 -y1 -c1 `"$seedArchive`" `"$($seedSource.Replace('\','/'))/`" tree"
$seedRows = @(Invoke-EnumProbe (Join-Path $Workspace 'seed-command') @(
    '--base-command-probe',$Oracle,$seedCommand,'1041','0','W','none','0'
) $Workspace)
Assert-ProbeSuccess $seedRows 'seed' $true
Assert-SameRows $seedInputSnapshot (Get-InputSnapshot $seedSource) 'Seed source changed during archive creation'
$seedBytes = [IO.File]::ReadAllBytes($seedArchive)
$seedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($seedBytes))
$seedParsed = Read-Level2Archive $seedBytes
Assert-SeedLayout $seedParsed
$seedFingerprints = @($seedParsed.Records | ForEach-Object { [Convert]::ToBase64String($_.Bytes) } | Sort-Object)

$orderedSeeds = @{}
foreach ($order in 'parent-first','parent-last') {
    $bytes = Convert-Level2ArchiveOrder $seedBytes $order
    $path = Join-Path $Workspace "$order.lzh"
    [IO.File]::WriteAllBytes($path,$bytes)
    $parsed = Read-Level2Archive $bytes
    Assert-SeedLayout $parsed
    if (($order -ceq 'parent-first' -and !$parsed.Records[0].IsDirectory) -or
        ($order -ceq 'parent-last' -and !$parsed.Records[-1].IsDirectory)) {
        throw "Seed order was not established: $order"
    }
    $fingerprints = @($parsed.Records | ForEach-Object { [Convert]::ToBase64String($_.Bytes) } | Sort-Object)
    Assert-SameRows $seedFingerprints $fingerprints "Seed record bytes changed during reorder: $order"
    $snapshot = @(Get-ArchiveSnapshot $path $Workspace "seed/$order")
    $expectedPayloads = @('output="old-keep.bin"','output="old-skip.txt"')
    foreach ($expected in $expectedPayloads) {
        if ($snapshot -notcontains $expected) { throw "Seed payload is incomplete: $order/$expected" }
    }
    $orderedSeeds[$order] = [pscustomobject]@{
        Path=$path; Bytes=$bytes; Snapshot=$snapshot
        SHA256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    }
}

$cases = foreach ($recursion in $Recursions) {
    foreach ($order in $Orders) {
        foreach ($exclusion in $Exclusions) {
            [pscustomobject]@{ Recursion=$recursion; Order=$order; Exclusion=$exclusion }
        }
    }
}
if (!$cases.Count) { throw 'At least one implicit-update case is required' }
$count = 0
$retryCount = 0
foreach ($case in $cases) {
    $label = "r$($case.Recursion)-$($case.Order)-$($case.Exclusion)"
    $sideResults = @()
    foreach ($side in 'oracle','reimpl') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $maximumAttempt = if ($side -eq 'oracle') { 5 } else { 0 }
        $completed = $false
        for ($attempt = 0; $attempt -le $maximumAttempt; $attempt++) {
            # oracle/reimpl は同じ六文字、attempt は一桁に固定し、再試行でもパス長を変えない。
            $root = Join-Path $Workspace ('case-{0:D3}-{1}-attempt{2}' -f $count,$side,$attempt)
            $source = Join-Path $root 'source'
            New-InputTree $source 'new' 2024 $true
            $inputSnapshot = Get-InputSnapshot $source
            $archive = Join-Path $root 'result.lzh'
            [IO.File]::WriteAllBytes($archive,[byte[]]$orderedSeeds[$case.Order].Bytes)
            $options = @('u','-h2','-jm0','-n1','-gm1','-y1','-c1','-x1',"-r$($case.Recursion)")
            if ($case.Exclusion -ceq 'exclude-txt') { $options += '-jx*.txt' }
            # archive と基準ディレクトリーだけを渡す。暗黙入力へ '*' を補わない。
            $command = (($options + @("`"$archive`"","`"$($source.Replace('\','/'))/`"")) -join ' ')
            $rows = @(Invoke-EnumProbe (Join-Path $root 'command') @(
                '--base-command-probe',$dll,$command,'1041','0','W','none','0'
            ) $root)
            if ($rows -notcontains 'result=0') {
                if ($side -eq 'oracle' -and $attempt -lt $maximumAttempt -and (Test-OriginalMoveAccessDenied $rows)) {
                    [IO.File]::WriteAllLines((Join-Path $root 'original-command-failure.txt'),[string[]]$rows)
                    $retryCount++
                    Write-Host "Implicit update: original MoveFile access denied; retrying fresh fixture ($label/$attempt)"
                    Start-Sleep -Milliseconds 100
                    continue
                }
                if ($side -eq 'oracle') {
                    throw "Original implicit-update result is unclassified: $label/attempt$attempt`n$($rows -join "`n")"
                }
                throw "Candidate implicit-update command failed: $label`n$($rows -join "`n")"
            }
            Assert-ProbeSuccess $rows "$label/$side" $true
            Assert-SameRows $inputSnapshot (Get-InputSnapshot $source) "Implicit-update source changed: $label/$side"
            $archiveSnapshot = @(Get-ArchiveSnapshot $archive $root "$label/$side")
            $sideResults += ,@(
                'command:'
                Normalize-ProbeRows $rows $root
                'archive:'
                $archiveSnapshot
            )
            $completed = $true
            break
        }
        if (!$completed) { throw "Original implicit-update retry limit reached: $label/$side" }
    }
    Assert-SameRows $sideResults[0] $sideResults[1] "Implicit-update oracle/candidate mismatch: $label"
    $count++
    Write-Host "Implicit update: passed $label ($count/$($cases.Count))"
}

foreach ($entry in $trackedInputs) {
    if ((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -cne $entry.SHA256) {
        throw "Test input changed during execution: $($entry.Path)"
    }
}
if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($seedArchive))) -cne $seedHash -or
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($seedArchive)) -cne [Convert]::ToBase64String($seedBytes)) {
    throw 'Original seed archive changed during execution'
}
foreach ($order in 'parent-first','parent-last') {
    $current = [IO.File]::ReadAllBytes($orderedSeeds[$order].Path)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($current)) -cne $orderedSeeds[$order].SHA256 -or
        [Convert]::ToBase64String($current) -cne [Convert]::ToBase64String([byte[]]$orderedSeeds[$order].Bytes)) {
        throw "Ordered seed archive changed during execution: $order"
    }
}
Assert-SameRows $seedInputSnapshot (Get-InputSnapshot $seedSource) 'Seed source changed after case execution'
Write-Host "Implicit update: $count r0/r1/r2 parent-first/last exclusion comparisons, $pureHelperChecks pure helper checks, and $retryCount original retries passed"
[pscustomobject]@{ Comparisons=$count; PureHelperChecks=$pureHelperChecks; OriginalRetries=$retryCount }
