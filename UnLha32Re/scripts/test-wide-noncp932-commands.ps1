[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Runner = (Resolve-Path -LiteralPath $Runner).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

$fixedTime = [datetime]'2024-01-02T03:04:06Z'
$binaryHashes = @{}
foreach ($path in $TestProgram, $Runner, $Oracle, $Candidate) {
    $binaryHashes[$path] = (Get-FileHash -LiteralPath $path).Hash
}

function Set-TestFile([string]$Path, [string]$Contents) {
    [IO.File]::WriteAllText($Path, $Contents, [Text.UTF8Encoding]::new($false))
    [IO.File]::SetCreationTimeUtc($Path, $fixedTime)
    [IO.File]::SetLastAccessTimeUtc($Path, $fixedTime)
    [IO.File]::SetLastWriteTimeUtc($Path, $fixedTime)
}

function Quote-Argument([string]$Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-WideCommand([string]$Dll, [string]$Command, [int]$Locale) {
    $rows = @(& $Runner --timeout-seconds 30 $TestProgram --registry '' `
        --base-command-probe $Dll $Command $Locale 0 W none 0 2>&1 |
        ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Wide command probe failed (exit $exitCode):`n$($rows -join "`n")"
    }
    return [pscustomobject]@{ Rows = $rows; ExitCode = $exitCode }
}

function Invoke-CancelSequence([string]$Dll, [string]$Command, [string]$Archive, [int]$Locale) {
    $steps = @(
        '@abort-state:0',
        $Command,
        ('@audit-archive-release:' + $Archive),
        '@abort-state:-1',
        $Command,
        ('@audit-archive-release:' + $Archive)
    )
    $rows = @(& $Runner --timeout-seconds 30 $TestProgram --registry '' `
        --progress-sequence-probe $Dll w64 $Locale 0 W w64 @steps 2>&1 |
        ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Wide move cancellation probe failed (exit $exitCode):`n$($rows -join "`n")"
    }
    return [pscustomobject]@{ Rows = $rows; ExitCode = $exitCode }
}

function Assert-Result([object]$Run, [int]$Expected, [string]$Label) {
    if ($Run.Rows -notcontains "result=$Expected") {
        throw "Unexpected command result: $Label`n$($Run.Rows -join "`n")"
    }
}

function Normalize-Rows([string[]]$Rows, [string]$Root) {
    $forwardRoot = $Root.Replace('\', '/')
    return @($Rows | ForEach-Object {
        $_.Replace($forwardRoot, '<ROOT>').Replace($Root, '<ROOT>')
    })
}

function Get-FileSnapshot([string]$Root, [switch]$WithHash) {
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
            $entry = "file=$relative,size=$($_.Length)"
            if ($WithHash) { $entry += ',hash=' + (Get-FileHash -LiteralPath $_.FullName).Hash }
            $entry
        })
}

function Assert-EqualRecords([string[]]$OracleRecords, [string[]]$CandidateRecords, [string]$Label) {
    $difference = @(Compare-Object -ReferenceObject $OracleRecords -DifferenceObject $CandidateRecords -SyncWindow 0)
    if ($difference.Count -ne 0) {
        $details = $difference | Select-Object -First 16 | Out-String -Width 2000
        throw "Wide non-CP932 command mismatch: $Label`n$details"
    }
}

function New-Case([string]$Label, [string]$Side, [string]$InputName = '', [string]$InputContents = '') {
    $root = Join-Path $Workspace "$Label-$Side"
    $parent = Join-Path $root (([string][char]0x014c) + '-parent')
    $source = Join-Path $root (([string][char]0x014c) + '-source')
    New-Item -ItemType Directory -Path $parent, $source -Force | Out-Null
    $archive = Join-Path $parent (([string][char]0x0100) + '.lzh')
    Copy-Item -LiteralPath $script:seedArchive -Destination $archive
    $input = ''
    if ($InputName) {
        $input = Join-Path $source $InputName
        Set-TestFile $input $InputContents
    }
    return [pscustomobject]@{
        Root = $root
        Parent = $parent
        Source = $source
        Archive = $archive
        Input = $input
    }
}

function Assert-ReadableMember([string]$Dll, [string]$Archive, [int]$Locale, [string]$Member, [string]$Contents, [string]$Label) {
    $run = Invoke-WideCommand $Dll ('p -+ ' + (Quote-Argument $Archive) + ' ' + $Member) $Locale
    Assert-Result $run 0 $Label
    if ($run.Rows -notcontains ('output="' + $Contents + '"')) {
        throw "Archive member content is wrong: $Label`n$($run.Rows -join "`n")"
    }
    return $run
}

$seedDirectory = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seedDirectory | Out-Null
Set-TestFile (Join-Path $seedDirectory 'one.txt') 'one payload'
Set-TestFile (Join-Path $seedDirectory 'two.txt') 'two payload'
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedCommand = 'a -gm1 -y1 -jm0 -h2 ' + (Quote-Argument $seedArchive) + ' ' +
    (Quote-Argument ($seedDirectory + '\')) + ' one.txt two.txt'
$seedRun = Invoke-WideCommand $Oracle $seedCommand 1041
Assert-Result $seedRun 0 'seed archive creation'
$script:seedArchive = $seedArchive
$seedHash = (Get-FileHash -LiteralPath $seedArchive).Hash

$comparisonCount = 0
foreach ($locale in 1033, 1041) {
    foreach ($command in 'l', 'v', 't', 'p', 'd') {
        $records = @{}
        foreach ($side in 'oracle', 'candidate') {
            $case = New-Case "$command-$locale" $side
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $line = if ($command -eq 'd') {
                'd -gm1 -y1 -n1 ' + (Quote-Argument $case.Archive) + ' one.txt'
            } else {
                "$command -gm1 -y1 -n1 " + (Quote-Argument $case.Archive) + ' *'
            }
            $run = Invoke-WideCommand $dll $line $locale
            Assert-Result $run 0 "$command/$locale/$side"
            $memberRun = $null
            if ($command -eq 'd') {
                $memberRun = Assert-ReadableMember $dll $case.Archive $locale 'two.txt' 'two payload' "$command/$locale/$side"
            }
            $records[$side] = @(
                Normalize-Rows $run.Rows $case.Root
                if ($memberRun) { Normalize-Rows $memberRun.Rows $case.Root }
                Get-FileSnapshot $case.Root -WithHash
            )
        }
        Assert-EqualRecords $records.oracle $records.candidate "$command/$locale"
        $comparisonCount++
    }
}

foreach ($locale in 1033, 1041) {
    foreach ($shape in 'switch-first', 'default') {
        $records = @{}
        foreach ($side in 'oracle', 'candidate') {
            $case = New-Case "position-$shape-$locale" $side
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $line = if ($shape -eq 'switch-first') {
                '-gm1 -y1 -n1 l ' + (Quote-Argument $case.Archive) + ' *'
            } else {
                (Quote-Argument $case.Archive) + ' *'
            }
            $run = Invoke-WideCommand $dll $line $locale
            Assert-Result $run 0 "position/$shape/$locale/$side"
            $records[$side] = @(Normalize-Rows $run.Rows $case.Root; Get-FileSnapshot $case.Root -WithHash)
        }
        Assert-EqualRecords $records.oracle $records.candidate "position/$shape/$locale"
        $comparisonCount++
    }
}

foreach ($locale in 1033, 1041) {
    foreach ($inputKind in 'explicit', 'wildcard') {
        $records = @{}
        foreach ($side in 'oracle', 'candidate') {
            $case = New-Case "move-$inputKind-$locale" $side 'move.txt' 'move payload'
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $inputSpec = if ($inputKind -eq 'explicit') {
                Quote-Argument $case.Input
            } else {
                (Quote-Argument ($case.Source + '\')) + ' *.txt'
            }
            $line = 'm -gm1 -y1 -n1 -jm0 -h2 ' + (Quote-Argument $case.Archive) + ' ' + $inputSpec
            $run = Invoke-WideCommand $dll $line $locale
            Assert-Result $run 0 "move/$inputKind/$locale/$side"
            if (Test-Path -LiteralPath $case.Input) { throw "Moved input remains: $inputKind/$locale/$side" }
            if (@(Get-ChildItem -LiteralPath $case.Root -File -Recurse -Force -Filter '*.tmp').Count -ne 0) {
                throw "Temporary archive remains: $inputKind/$locale/$side"
            }
            $memberRun = Assert-ReadableMember $dll $case.Archive $locale 'move.txt' 'move payload' "move/$inputKind/$locale/$side"
            if ($side -eq 'candidate') {
                # 書庫のアクセス日時は DLL ごとの読み取り時刻で異なるため、原版で本文を読む。
                Assert-ReadableMember $Oracle $case.Archive $locale 'move.txt' 'move payload' "move/$inputKind/$locale/oracle-read" | Out-Null
            }
            $files = @(Get-FileSnapshot $case.Root)
            if ($files.Count -ne 1 -or $files[0] -notlike ('file=' + ([string][char]0x014c) + '-parent/' + ([string][char]0x0100) + '.lzh,*')) {
                throw "Move created an unexpected file: $inputKind/$locale/$side`n$($files -join "`n")"
            }
            $records[$side] = @(Normalize-Rows $run.Rows $case.Root; Normalize-Rows $memberRun.Rows $case.Root; $files)
        }
        Assert-EqualRecords $records.oracle $records.candidate "move/$inputKind/$locale"
        $comparisonCount++
    }
}

foreach ($locale in 1033, 1041) {
    $records = @{}
    foreach ($side in 'oracle', 'candidate') {
        $case = New-Case "move-no-match-$locale" $side 'keep.txt' 'keep payload'
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $before = (Get-FileHash -LiteralPath $case.Archive).Hash
        $line = 'm -gm1 -y1 -n1 -jm0 -h2 ' + (Quote-Argument $case.Archive) + ' ' +
            (Quote-Argument ($case.Source + '\')) + ' missing*.txt'
        $run = Invoke-WideCommand $dll $line $locale
        Assert-Result $run 0 "move/no-match/$locale/$side"
        if (-not (Test-Path -LiteralPath $case.Input) -or
            [IO.File]::ReadAllText($case.Input) -cne 'keep payload' -or
            (Get-FileHash -LiteralPath $case.Archive).Hash -cne $before) {
            throw "Move no-match changed an input or archive: $locale/$side"
        }
        $records[$side] = @(Normalize-Rows $run.Rows $case.Root; Get-FileSnapshot $case.Root -WithHash)
    }
    Assert-EqualRecords $records.oracle $records.candidate "move/no-match/$locale"
    $comparisonCount++
}

foreach ($locale in 1033, 1041) {
    $records = @{}
    foreach ($side in 'oracle', 'candidate') {
        $case = New-Case "move-cancel-$locale" $side 'move.txt' ('M' * 4096)
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $line = 'm -gm1 -y1 -n1 -jm0 -h2 ' + (Quote-Argument $case.Archive) + ' ' +
            (Quote-Argument ($case.Source + '\')) + ' *.txt'
        $run = Invoke-CancelSequence $dll $line $case.Archive $locale
        $results = @($run.Rows | Where-Object { $_ -match '^result=' })
        $released = @($run.Rows | Where-Object { $_ -match '^archive-released=' })
        if (($results -join ',') -cne 'result=32800,result=0' -or
            ($released -join ',') -cne 'archive-released=1,error=0,archive-released=1,error=0') {
            throw "Move cancellation/reuse differs: $locale/$side`n$($run.Rows -join "`n")"
        }
        if ((Test-Path -LiteralPath $case.Input) -or
            (@(Get-ChildItem -LiteralPath $case.Root -File -Recurse -Force -Filter '*.tmp').Count -ne 0)) {
            throw "Move cancellation cleanup differs: $locale/$side"
        }
        $memberRun = Assert-ReadableMember $dll $case.Archive $locale 'move.txt' ('M' * 4096) "move/cancel/$locale/$side"
        if ($side -eq 'candidate') {
            Assert-ReadableMember $Oracle $case.Archive $locale 'move.txt' ('M' * 4096) "move/cancel/$locale/oracle-read" | Out-Null
        }
        $summary = @($run.Rows | Where-Object {
            $_ -match '^(result=|win32-error=|compat-error=|compat-system-error=|archive-released=|progress\.kill=)'
        })
        $records[$side] = @(Normalize-Rows $summary $case.Root; Normalize-Rows $memberRun.Rows $case.Root; Get-FileSnapshot $case.Root)
    }
    Assert-EqualRecords $records.oracle $records.candidate "move/cancel/$locale"
    $comparisonCount++
}

if ($comparisonCount -ne 22) { throw "Incomplete wide non-CP932 command test: $comparisonCount" }
if ((Get-FileHash -LiteralPath $seedArchive).Hash -cne $seedHash) { throw 'Seed archive changed during test' }
foreach ($path in $binaryHashes.Keys) {
    if ((Get-FileHash -LiteralPath $path).Hash -cne $binaryHashes[$path]) {
        throw "Binary changed during test: $path"
    }
}
Write-Host 'Wide non-CP932 W commands: 22 original/candidate command, path, mutation, cancellation, release, and interoperability comparisons passed'
