[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$Workspace
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw 'Use a fresh command-body error directory' }
New-Item -ItemType Directory -Path $Workspace | Out-Null

$environmentHashes = @{}
foreach ($path in $TestProgram,$Oracle,$Candidate,$runner,$Seed) {
    $environmentHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Command body environment: $path SHA256=$($environmentHashes[$path])"
}

function Update-Level0Checksum([byte[]]$Bytes) {
    $sum = 0
    for ($offset = 2; $offset -lt $Bytes[0]+2; $offset++) {
        $sum = ($sum + $Bytes[$offset]) -band 255
    }
    $Bytes[1] = [byte]$sum
}

$literal = Join-Path $Workspace 'literal'
& (Join-Path $PSScriptRoot 'new-legacy-fixtures.ps1') -SeedArchive $Seed `
    -OutputDirectory $literal -Methods lh0,lz4,lz5,lzs
$boundary = Join-Path $Workspace 'boundary'
& (Join-Path $PSScriptRoot 'new-legacy-boundaries.ps1') -Fixtures $literal `
    -OutputDirectory $boundary -Methods lh0,lz4,lz5,lzs -Sizes 1,9,100

$severe = Join-Path $Workspace 'severe'
$focused = Join-Path $Workspace 'focused'
New-Item -ItemType Directory -Path $severe,$focused | Out-Null
$severePaths = @{}
foreach ($method in 'lh0','lz4','lz5','lzs') {
    foreach ($size in 1,9,100) {
        $source = [IO.File]::ReadAllBytes((Join-Path $boundary "$method-$size-plain.lzh"))
        $headerSize = [int]$source[0] + 2
        $packed = [int][BitConverter]::ToUInt32($source,7)
        $keptLengths = @(0,1,2,3,[Math]::Floor($packed/2),($packed-1)) |
            Where-Object { $_ -ge 0 -and $_ -lt $packed } | Sort-Object -Unique
        foreach ($kept in $keptLengths) {
            $bytes = [byte[]]::new($headerSize+$kept)
            [Array]::Copy($source,$bytes,$bytes.Length)
            $archive = Join-Path $severe "$method-$size-keep$kept.lzh"
            [IO.File]::WriteAllBytes($archive,$bytes)
            $severePaths["$method-$size-keep$kept"] = $archive
        }
    }
}

$focusedPaths = @{}
foreach ($method in 'lh0','lz4','lz5','lzs') {
    $good = [IO.File]::ReadAllBytes((Join-Path $literal "$method-9.lzh"))
    if ($method -eq 'lh0') {
        $path = Join-Path $focused 'lh0-good.lzh'
        [IO.File]::WriteAllBytes($path,$good)
        $focusedPaths['lh0-good'] = $path
    }
    $badCrc = [byte[]]$good.Clone()
    $badCrc[22+$badCrc[21]] = $badCrc[22+$badCrc[21]] -bxor 1
    Update-Level0Checksum $badCrc
    $path = Join-Path $focused "$method-bad-crc.lzh"
    [IO.File]::WriteAllBytes($path,$badCrc)
    $focusedPaths["$method-bad-crc"] = $path
    if ($method -in 'lh0','lz4') {
        $badPayload = [byte[]]$good.Clone()
        $badPayload[[int]$good[0]+2] = $badPayload[[int]$good[0]+2] -bxor 1
        $path = Join-Path $focused "$method-bad-payload.lzh"
        [IO.File]::WriteAllBytes($path,$badPayload)
        $focusedPaths["$method-bad-payload"] = $path
    }
}

$results = [Collections.Generic.List[object]]::new()
$archiveHashes = @{}
function Compare-CommandCase([string]$Name,[string]$Archive,[string]$Command) {
    if (!$archiveHashes.ContainsKey($Archive)) {
        $archiveHashes[$Archive] = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash
    }
    $commandLine = "$Command -gm1 -n1 `"$Archive`" `"*`""
    $snapshots = @()
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(& $runner --timeout-seconds 30 $TestProgram --registry '' --command-enum-probe `
            $dll $commandLine w64 1 '' 1041 1 W 1 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        [IO.File]::WriteAllLines((Join-Path $Workspace "$Name.$side.txt"),[string[]]$rows,
            [Text.UTF8Encoding]::new($false))
        if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) {
            throw "Command body observation failed: $Name/$side/exit=$code"
        }
        $snapshots += ,$rows
    }
    $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
    if ($difference.Count) {
        $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$Name.diff.tsv") `
            -Delimiter "`t" -NoTypeInformation
    }
    $results.Add([pscustomobject]@{
        name = $Name
        command = $Command
        differences = $difference.Count
        oracle = $snapshots[0] -match '^result=' | Select-Object -First 1
        candidate = $snapshots[1] -match '^result=' | Select-Object -First 1
    })
    $results | Export-Csv -LiteralPath (Join-Path $Workspace 'observations.tsv') `
        -Delimiter "`t" -NoTypeInformation
}

$boundaryRecords = Import-Csv -LiteralPath (Join-Path $boundary 'fixtures.tsv') -Delimiter "`t" |
    Where-Object { $_.variant -in 'plain','padding1','under-declared','missing-body-byte','short-body' }
foreach ($record in $boundaryRecords) {
    Compare-CommandCase "t-$($record.method)-$($record.size)-$($record.variant)" `
        (Join-Path $boundary $record.file) 't'
}
foreach ($key in @($severePaths.Keys | Sort-Object)) {
    Compare-CommandCase "t-$key" $severePaths[$key] 't'
}

$focusedCases = @(
    @{ Name='p-lh0-good'; Archive=$focusedPaths['lh0-good']; Command='p' },
    @{ Name='p-lh0-bad-crc'; Archive=$focusedPaths['lh0-bad-crc']; Command='p' },
    @{ Name='p-lh0-bad-payload'; Archive=$focusedPaths['lh0-bad-payload']; Command='p' },
    @{ Name='p-lz4-bad-crc'; Archive=$focusedPaths['lz4-bad-crc']; Command='p' },
    @{ Name='p-lz4-bad-payload'; Archive=$focusedPaths['lz4-bad-payload']; Command='p' },
    @{ Name='p-lz5-bad-crc'; Archive=$focusedPaths['lz5-bad-crc']; Command='p' },
    @{ Name='p-lzs-bad-crc'; Archive=$focusedPaths['lzs-bad-crc']; Command='p' },
    @{ Name='p-lh0-no-end'; Archive=(Join-Path $boundary 'lh0-9-missing-body-byte.lzh'); Command='p' },
    @{ Name='p-lz5-no-end'; Archive=(Join-Path $boundary 'lz5-9-missing-body-byte.lzh'); Command='p' },
    @{ Name='p-lh0-under'; Archive=(Join-Path $boundary 'lh0-9-under-declared.lzh'); Command='p' },
    @{ Name='p-lz5-under'; Archive=(Join-Path $boundary 'lz5-9-under-declared.lzh'); Command='p' },
    @{ Name='p-lh0-severe'; Archive=$severePaths['lh0-9-keep3']; Command='p' },
    @{ Name='p-lz4-severe'; Archive=$severePaths['lz4-9-keep3']; Command='p' },
    @{ Name='p-lz5-severe'; Archive=$severePaths['lz5-9-keep3']; Command='p' },
    @{ Name='p-lzs-severe'; Archive=$severePaths['lzs-9-keep3']; Command='p' },
    @{ Name='l-no-end'; Archive=(Join-Path $boundary 'lh0-9-missing-body-byte.lzh'); Command='l' },
    @{ Name='v-no-end'; Archive=(Join-Path $boundary 'lh0-9-missing-body-byte.lzh'); Command='v' }
)
foreach ($case in $focusedCases) {
    Compare-CommandCase $case.Name $case.Archive $case.Command
}

foreach ($path in $archiveHashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $archiveHashes[$path]) {
        throw "Command body artifact changed: $path"
    }
}
foreach ($path in $environmentHashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $environmentHashes[$path]) {
        throw "Command body environment changed: $path"
    }
}
$differences = @($results | Where-Object { [int]$_.differences -ne 0 })
if ($results.Count -ne 131 -or $differences.Count -ne 0) {
    $sample = $differences | Select-Object -First 8 | Format-Table -AutoSize | Out-String -Width 2000
    throw "短い本文・末尾欠落・p CRC の互換性が一致しません。$([Environment]::NewLine)$sample"
}
Write-Host 'Command body errors: 60 boundary, 54 severe, and 17 focused comparisons exact'
