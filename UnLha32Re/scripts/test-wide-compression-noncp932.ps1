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

function Quote-Argument([string]$Value) {
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-WideCommand([string]$Dll, [string]$Command) {
    $rows = @(& $Runner --timeout-seconds 30 $TestProgram --registry '' `
        --base-command-probe $Dll $Command 1041 0 W none 0 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "Wide compression probe failed ($LASTEXITCODE): $Command`n$($rows -join "`n")"
    }
    return ,$rows
}

function Normalize-Rows([string[]]$Rows, [string]$Root) {
    $forward = $Root.Replace('\', '/')
    return @($Rows | ForEach-Object {
        $_.Replace($forward, '<ROOT>').Replace($Root, '<ROOT>')
    })
}

$seedSource = Join-Path $Workspace 'seed-source'
[IO.File]::WriteAllText($seedSource, 'seed payload', [Text.UTF8Encoding]::new($false))
$seedArchive = Join-Path $Workspace 'seed.lzh'
$seedRun = Invoke-WideCommand $Oracle ('a -gm1 -y1 -h2 ' +
    (Quote-Argument $seedArchive) + ' ' + (Quote-Argument $seedSource))
if ('result=0' -cnotin $seedRun) { throw 'Cannot create seed archive' }
$seedHash = (Get-FileHash -LiteralPath $seedArchive).Hash

$commentName = ([string][char]0x0100) + '-comment.txt'
$records = @{}
foreach ($side in 'oracle', 'candidate') {
    $root = Join-Path $Workspace $side
    New-Item -ItemType Directory -Path $root | Out-Null
    $archive = Join-Path $root 'archive.lzh'
    Copy-Item -LiteralPath $seedArchive -Destination $archive
    $comment = Join-Path $root $commentName
    [IO.File]::WriteAllText($comment, 'non-CP932 comment', [Text.UTF8Encoding]::new($false))
    $command = 'c -n1 -gm1 -y1 -jz' + (Quote-Argument $comment) + ' ' +
        (Quote-Argument $archive) + ' seed-source'
    $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
    $rows = Invoke-WideCommand $dll $command
    if ('result=0' -cnotin $rows -or 'win32-error=0' -cnotin $rows) {
        throw "Non-CP932 W comment update failed: $side`n$($rows -join "`n")"
    }
    $hash = (Get-FileHash -LiteralPath $archive).Hash
    if ($hash -ceq $seedHash) { throw "Comment was not applied: $side" }
    $records[$side] = @(Normalize-Rows $rows $root)
    $records["$side-hash"] = $hash
}

$difference = @(Compare-Object -ReferenceObject $records.oracle -DifferenceObject $records.candidate -SyncWindow 0)
if ($difference.Count -ne 0 -or $records['oracle-hash'] -cne $records['candidate-hash']) {
    throw "Non-CP932 W comment update differs from the original:`n$($difference | Out-String)"
}
Write-Host 'Wide non-CP932 compression: W UnicodeMode=0 comment path, output, state, and archive comparison passed'
