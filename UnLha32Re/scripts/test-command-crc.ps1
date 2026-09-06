[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$Level2Fixtures,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$Level2Fixtures = (Resolve-Path -LiteralPath $Level2Fixtures).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw 'Use a fresh CRC observation directory' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @{}
foreach ($path in $TestProgram,$Oracle,$Candidate,$runner,$Seed) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Host "Command CRC environment: $path SHA256=$($hashes[$path])"
}
function Update-Sum([byte[]]$Bytes) {
    $sum = 0
    for ($offset=2; $offset -lt $Bytes[0]+2; $offset++) { $sum = ($sum+$Bytes[$offset]) -band 255 }
    $Bytes[1] = $sum
}
function Get-Crc16([byte[]]$Bytes,[int]$Start,[int]$Length) {
    [uint32]$crc = 0
    for ($offset=$Start; $offset -lt $Start+$Length; $offset++) {
        $crc = $crc -bxor $Bytes[$offset]
        for ($bit=0; $bit -lt 8; $bit++) { $crc = if ($crc -band 1) { ($crc -shr 1) -bxor 0xa001 } else { $crc -shr 1 } }
    }
    return [uint16]$crc
}
$literal = Join-Path $Workspace 'literal'
& (Join-Path $PSScriptRoot 'new-legacy-fixtures.ps1') -SeedArchive $Seed -OutputDirectory $literal -Methods lh0,lz4,lz5,lzs,pm0
$inputs = [ordered]@{}
foreach ($method in 'lh0','lz4','lz5','lzs') {
    $good = [IO.File]::ReadAllBytes((Join-Path $literal "$method-9.lzh"))
    $bad = [byte[]]$good.Clone()
    $bad[22+$bad[21]] = $bad[22+$bad[21]] -bxor 1
    Update-Sum $bad
    $inputs["$method-good"] = $good
    $inputs["$method-bad-crc"] = $bad
    $headerSize = [int]$good[0]+2
    $noCrc = [byte[]]($good[0..($headerSize-3)]+$good[$headerSize..($good.Length-1)])
    $noCrc[0] -= 2
    Update-Sum $noCrc
    $inputs["$method-no-crc"] = $noCrc
    if ($method -in 'lh0','lz4') {
        $payload = [byte[]]$good.Clone()
        $payload[$headerSize] = $payload[$headerSize] -bxor 1
        $inputs["$method-bad-payload"] = $payload
    }
    if ($method -ne 'lz4') { $inputs["$method-truncated"] = [byte[]]$good[0..($headerSize+2)] }
}
$goodMember = [byte[]]$inputs['lh0-good'][0..($inputs['lh0-good'].Length-2)]
$badMember = [byte[]]$inputs['lh0-bad-crc'][0..($inputs['lh0-bad-crc'].Length-2)]
$pmarc = [IO.File]::ReadAllBytes((Join-Path $literal 'pm0-9.lzh'))
$pmarcMember = [byte[]]$pmarc[0..($pmarc.Length-2)]
$inputs['duplicate-good-bad-good'] = [byte[]]($goodMember+$badMember+$goodMember+0)
$inputs['duplicate-bad-good-bad'] = [byte[]]($badMember+$goodMember+$badMember+0)
$inputs['duplicate-all-bad'] = [byte[]]($badMember+$badMember+0)
$inputs['pmarc-bad-good'] = [byte[]]($pmarcMember+$badMember+$goodMember+0)
$inputs['bad-pmarc-good'] = [byte[]]($badMember+$pmarcMember+$goodMember+0)
$badHeader = [byte[]]$inputs['lh0-good'].Clone()
$badHeader[1] = $badHeader[1] -bxor 1
$inputs['lh0-bad-header'] = $badHeader
$badIndexes = @{ good=@();first=@(0);middle=@(1);last=@(2);all=@(0,1,2) }
foreach ($family in 'ascii','japanese') { foreach ($method in 0,2) {
    $path = Join-Path $Level2Fixtures "$family-jm$method/seed.lzh"
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $seedData = [IO.File]::ReadAllBytes($path)
    foreach ($variant in 'good','first','middle','last','all') {
        $bytes = [byte[]]$seedData.Clone()
        $position = 0
        for ($member=0; $member -lt 3; $member++) {
            if ($bytes[$position+20] -ne 2) { throw 'Expected level-2 members' }
            $headerSize = [BitConverter]::ToUInt16($bytes,$position)
            $packed = [BitConverter]::ToUInt32($bytes,$position+7)
            if ($member -in $badIndexes[$variant]) {
                # 本文 CRC だけを変え、ヘッダー CRC は正しい値に再計算する。
                $bytes[$position+21] = $bytes[$position+21] -bxor 1
                $extension = $position+26
                $extensionSize = [BitConverter]::ToUInt16($bytes,$position+24)
                $headerCrcPosition = -1
                while ($extensionSize -gt 0) {
                    if ($extensionSize -lt 3 -or $extension+$extensionSize -gt $position+$headerSize) { throw 'Invalid extension boundary' }
                    if ($bytes[$extension] -eq 0) { $headerCrcPosition = $extension+1;break }
                    $next = $extension+$extensionSize-2
                    $extensionSize = [BitConverter]::ToUInt16($bytes,$next)
                    $extension = $next+2
                }
                if ($headerCrcPosition -lt 0) { throw 'Missing header CRC' }
                $bytes[$headerCrcPosition] = 0
                $bytes[$headerCrcPosition+1] = 0
                [BitConverter]::GetBytes((Get-Crc16 $bytes $position $headerSize)).CopyTo($bytes,$headerCrcPosition)
            }
            $position += $headerSize+$packed
        }
        $inputs["level2-$family-jm$method-$variant"] = $bytes
    }
} }
$profiles = @(
    @{name='raw-W';api='W';capacity=4096;mode=0},
    @{name='raw-legacy';api='legacy';capacity=4096;mode=0},
    @{name='raw-A-1';api='A';capacity=1;mode=0},
    @{name='plain';api='W';capacity=0;mode=0;selected=1;layout='none';pattern='*';replacement='';progress=0}
)
foreach ($api in 'legacy','A','W') { foreach ($selected in 1,0) {
    $profiles += @{name="state-$api-$selected";api=$api;capacity=0;mode=1;selected=$selected;layout='w64';pattern='*';replacement='';progress=1}
} }
$profiles += @{name='missing';api='W';capacity=0;mode=1;selected=1;layout='w64';pattern='missing';replacement='';progress=1}
$profiles += @{name='rename';api='W';capacity=0;mode=1;selected=1;layout='w64';pattern='*';replacement='renamed.txt';progress=1}
$results = [Collections.Generic.List[object]]::new()
foreach ($name in $inputs.Keys) {
    $archive = Join-Path $Workspace "$name.lzh"
    [IO.File]::WriteAllBytes($archive,$inputs[$name])
    $hashes[$archive] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    foreach ($profile in $profiles) {
        $pattern = if ($profile.capacity) { '*' } else { $profile.pattern }
        $line = 't -gm1 -n' + $profile.mode + ' "' + $archive + '" "' + $pattern + '"'
        $label = "$name-$($profile.name)"
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $arguments = if ($profile.capacity) {
                @('--registry','','--command-raw-probe',$dll,$line,$profile.api,$profile.capacity,'utf8')
            } else {
                @('--registry','','--command-enum-probe',$dll,$line,$profile.layout,$profile.selected,$profile.replacement,1041,1,$profile.api,$profile.progress)
            }
            $rows = @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            [IO.File]::WriteAllLines((Join-Path $Workspace "$label.$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            if ($code -ne 0 -or @($rows -match '^result=').Count -ne 1) { throw "CRC observation failed: $label/$side/exit=$code" }
            if ($profile.capacity) {
                $units = @((($rows[0] -split 'raw=',2)[1]).TrimEnd(',').Split(','))
                $guard = if ($profile.api -eq 'W') { 'cccc' } else { 'cc' }
                if ($units.Count -ne $profile.capacity+16 -or @($units[0..7] -cne $guard).Count -or @($units[($profile.capacity+8)..($profile.capacity+15)] -cne $guard).Count) { throw 'CRC output guard changed' }
            }
            $snapshots += ,$rows
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$label.diff.tsv") -Delimiter "`t" -NoTypeInformation }
        $results.Add([pscustomobject]@{name=$name;profile=$profile.name;api=$profile.api;capacity=$profile.capacity;mode=$profile.mode;pattern=$pattern;selected=$profile.selected;layout=$profile.layout;replacement=$profile.replacement;progress=$profile.progress;differences=$difference.Count;oracle=($snapshots[0] -match '^result=' | Select-Object -First 1);candidate=($snapshots[1] -match '^result=' | Select-Object -First 1)})
        $results | Export-Csv -LiteralPath (Join-Path $Workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
    }
    Write-Host "Command CRC: $name, $($results.Count) comparisons observed"
}
foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) { throw "CRC artifact changed: $path" }
}
$differences = @($results | Where-Object { [int]$_.differences -ne 0 })
if ($results.Count -ne 516 -or $differences.Count -ne 0) {
    $sample = $differences | Select-Object -First 8 | Format-Table -AutoSize | Out-String -Width 2000
    throw "本文 CRC・先頭 CRC 欠落・短い本文の互換性が一致しません。$([Environment]::NewLine)$sample"
}
Write-Host "Command CRC: 516 exact normal/CRC/short-body comparisons passed"
