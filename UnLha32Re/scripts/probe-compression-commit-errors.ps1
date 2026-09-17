[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('a','u','f','m')][string[]]$Commands = @('a','u','f','m')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
if (!$Commands -or @($Commands | Select-Object -Unique).Count -ne $Commands.Count) {
    throw 'Commands must be nonempty and unique'
}
if ($Workspace -match '[^\x20-\x7e]') { throw 'This initial move-path probe requires an ASCII workspace' }

$helperPath = Join-Path $PSScriptRoot 'test-enum-state.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$null,[ref]$parseErrors)
$helper = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'
},$true)
if ($parseErrors.Count -or !$helper) { throw 'Cannot load bounded probe helper' }
. ([scriptblock]::Create($helper.Extent.Text))

function Set-MoveProbeInput([string]$Path,[string]$Payload,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Payload,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}

function Invoke-MoveProbe([string]$Root,[string]$Name,[string[]]$Arguments) {
    $previousTemp = [Environment]::GetEnvironmentVariable('TEMP','Process')
    $previousTmp = [Environment]::GetEnvironmentVariable('TMP','Process')
    try {
        [Environment]::SetEnvironmentVariable('TEMP',(Join-Path $Root 'temp'),'Process')
        [Environment]::SetEnvironmentVariable('TMP',(Join-Path $Root 'temp'),'Process')
        @(Invoke-EnumProbe (Join-Path $Root $Name) $Arguments $Root)
    } finally {
        [Environment]::SetEnvironmentVariable('TEMP',$previousTemp,'Process')
        [Environment]::SetEnvironmentVariable('TMP',$previousTmp,'Process')
    }
}

function Get-MovePublicRows([string[]]$Rows,[string]$Root) {
    foreach ($key in 'result','output','win32-error','compat-error','compat-system-error') {
        $selected = @($Rows | Where-Object { $_.StartsWith($key + '=') })
        if ($selected.Count -ne 1) { throw "Missing or duplicate public field: $key" }
        $selected[0].Replace($Root.Replace('\','/'),'<ROOT>').Replace($Root.Replace('\','\\'),'<ROOT>').Replace($Root,'<ROOT>')
    }
}

function Get-MoveFileState([string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    [pscustomobject]@{
        Exists=$exists
        SHA256=$(if ($exists) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } else { $null })
        Length=$(if ($exists) { (Get-Item -LiteralPath $Path).Length } else { $null })
    }
}

function Test-MoveArchive([string]$Root,[string]$Archive,[string]$ChangedPayload) {
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -ceq 'oracle') { $Oracle } else { $Candidate }
        $crcRows = @(Invoke-MoveProbe $Root "read-$side-crc" @(
            '--base-command-probe',$dll,"t -n1 -gm1 `"$Archive`"",'1041','0','W','none','0'))
        if ($crcRows -notcontains 'result=0') { throw "CRC validation failed: $Root/$side" }
        foreach ($entry in @(
            @{ Name='change.txt'; Payload=$ChangedPayload },
            @{ Name='keep.txt'; Payload='old-keep' }
        )) {
            $rows = @(Invoke-MoveProbe $Root "read-$side-$($entry.Name)" @(
                '--base-command-probe',$dll,"p -n1 -gm1 `"$Archive`" `"$($entry.Name)`"",'1041','0','W','none','0'))
            if ($rows -notcontains 'result=0' -or $rows -cnotcontains ('output="' + $entry.Payload + '"')) {
                throw "Payload validation failed: $Root/$side/$($entry.Name)"
            }
        }
    }
}

New-Item -ItemType Directory -Path $Workspace | Out-Null
$protected = @($TestProgram,$Oracle,$Candidate,$runner,$helperPath,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{ Path=$_; SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$protected | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'inputs.json') -Encoding utf8
$seedRoot = Join-Path $Workspace 'seed'
$seedSource = Join-Path $seedRoot 'source'
New-Item -ItemType Directory -Path $seedSource,(Join-Path $seedRoot 'temp') | Out-Null
Set-MoveProbeInput (Join-Path $seedSource 'change.txt') 'old-change' 2020
Set-MoveProbeInput (Join-Path $seedSource 'keep.txt') 'old-keep' 2020
$seedArchive = Join-Path $seedRoot 'seed.lzh'
$seedCommand = "a -h2 -jm0 -n1 -gm1 -y1 -c1 -x1 `"$seedArchive`" `"$($seedSource.Replace('\','/'))/`" change.txt keep.txt"
$seedRows = @(Invoke-MoveProbe $seedRoot 'create' @(
    '--base-command-probe',$Oracle,$seedCommand,'1041','0','W','none','0'))
if ($seedRows -notcontains 'result=0') { throw 'Cannot create original seed archive' }
Test-MoveArchive $seedRoot $seedArchive 'old-change'
$seedHash = (Get-FileHash -LiteralPath $seedArchive -Algorithm SHA256).Hash
$observations = [Collections.Generic.List[object]]::new()

foreach ($operation in $Commands) {
    foreach ($mode in 'observe','deny') {
        $public = @{}
        foreach ($side in 'oracle','reimpl') {
            # 文字数をそろえ、失敗時も試行領域を再利用しない。観測段階では自動再試行しない。
            $root = Join-Path $Workspace "$operation-$mode-$side"
            $sourceRoot = Join-Path $root 'source'
            New-Item -ItemType Directory -Path $sourceRoot,(Join-Path $root 'temp') | Out-Null
            $archive = Join-Path $root 'archive.lzh'
            Copy-Item -LiteralPath $seedArchive -Destination $archive
            $source = Join-Path $sourceRoot 'change.txt'
            Set-MoveProbeInput $source 'new-change' 2024
            $sourceBefore = Get-MoveFileState $source
            $command = "$operation -h2 -jm0 -n1 -gm1 -y1 -c1 -x1 `"$archive`" `"$($sourceRoot.Replace('\','/'))/`" change.txt"
            $dll = if ($side -ceq 'oracle') { $Oracle } else { $Candidate }
            try {
                $rows = @(Invoke-MoveProbe $root 'command' @('--compression-move-probe',$dll,$command,$archive,$mode))
            } finally {
                # 未到達・監査失敗・タイムアウトでも、破壊的な再試行前に現物の状態を残す。
                $archiveAfter = Get-MoveFileState $archive
                $sourceAfter = Get-MoveFileState $source
                $temporaryFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force |
                    Where-Object { $_.Name -match '^(?i:LHT|LHC).*\.tmp$' } | ForEach-Object {
                        [IO.Path]::GetRelativePath($root,$_.FullName)
                    })
                [pscustomobject]@{ Archive=$archiveAfter; Source=$sourceAfter; TemporaryFiles=$temporaryFiles } |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'file-state.json') -Encoding utf8
            }
            $public[$side] = @(Get-MovePublicRows $rows $root)
            $resultRow = @($rows | Where-Object { $_ -match '^result=-?\d+$' })
            if ($resultRow.Count -ne 1) { throw "Invalid command result: $root" }
            $result = [int]$resultRow[0].Substring(7)
            $observation = [pscustomobject]@{
                Command=$operation; Mode=$mode; Side=$side; Result=$result
                Public=$public[$side]; Archive=$archiveAfter; Source=$sourceAfter; TemporaryFiles=$temporaryFiles
            }
            $observations.Add($observation)
            $observation | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'observation.json') -Encoding utf8
            if ($mode -ceq 'observe' -and $result -ne 0) {
                throw "Control move did not succeed; inspect recorded stage: $root"
            }
            if ($result -eq 0) {
                Test-MoveArchive $root $archive 'new-change'
                if ($operation -ceq 'm') {
                    if ($sourceAfter.Exists) { throw "Successful move retained its input: $root" }
                } elseif ($sourceAfter.SHA256 -cne $sourceBefore.SHA256) {
                    throw "Successful update changed its input: $root"
                }
            } elseif ($side -ceq 'reimpl') {
                if ($archiveAfter.SHA256 -cne $seedHash -or $sourceAfter.SHA256 -cne $sourceBefore.SHA256 -or $temporaryFiles.Count) {
                    throw "Candidate failed-save preservation contract was violated: $root"
                }
            }
            Write-Host "Compression move observation: $operation/$mode/$side result=$result"
        }
        $differences = @(Compare-Object $public.oracle $public.reimpl -CaseSensitive -SyncWindow 0)
        ConvertTo-Json -InputObject $differences | Set-Content -LiteralPath (Join-Path $Workspace "$operation-$mode-public-difference.json") -Encoding utf8
        if ($mode -ceq 'observe' -and $differences.Count) { throw "Successful public result mismatch: $operation" }
        # 故障群の差は診断結果。失敗値を推測して期待値にせず、互換成功とも扱わない。
        Write-Host "Compression move public comparison: $operation/$mode differing-rows=$($differences.Count)"
    }
}
foreach ($entry in $protected) {
    if ((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -cne $entry.SHA256) {
        throw "Probe input changed: $($entry.Path)"
    }
}
if ((Get-FileHash -LiteralPath $seedArchive -Algorithm SHA256).Hash -cne $seedHash) { throw 'Seed changed' }
$observations | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Workspace 'observations.json') -Encoding utf8
Write-Host "Compression move: $($observations.Count) observations recorded; fault-result compatibility requires assessment"
