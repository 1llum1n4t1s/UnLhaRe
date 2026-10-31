[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Runner,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference='Stop'
$TestProgram=(Resolve-Path -LiteralPath $TestProgram).Path
$Runner=(Resolve-Path -LiteralPath $Runner).Path
$Oracle=(Resolve-Path -LiteralPath $Oracle).Path
$Candidate=(Resolve-Path -LiteralPath $Candidate).Path
$Workspace=[IO.Path]::GetFullPath($Workspace)
if(Test-Path -LiteralPath $Workspace){throw 'Fresh workspace required'}
New-Item -ItemType Directory -Path $Workspace | Out-Null
function Q([string]$Value){'"'+$Value.Replace('"','\"')+'"'}
function Run-Wide([string]$Dll,[string]$Command){
    $rows=@(& $Runner --timeout-seconds 30 $TestProgram --registry '' --base-command-probe $Dll $Command 1041 0 W none 0 2>&1 | ForEach-Object {"$_"})
    if($LASTEXITCODE -ne 0){throw "Probe failed: $Dll / $Command`n$($rows -join "`n")"}
    return ,$rows
}
$seedSource=Join-Path $Workspace 'seed-source.txt'
[IO.File]::WriteAllText($seedSource,'seed payload',[Text.UTF8Encoding]::new($false))
$seedArchive=Join-Path $Workspace 'seed.lzh'
$seedRows=Run-Wide $Oracle ('a -n1 -gm1 -y1 -h2 '+(Q $seedArchive)+' '+(Q $seedSource))
if('result=0' -cnotin $seedRows){throw "Seed failed`n$($seedRows -join "`n")"}
$cases=@('comment','explicit')
foreach($caseName in $cases){
    $records=@{}
    foreach($side in 'oracle','candidate'){
        $root=Join-Path $Workspace "$caseName-$side"
        New-Item -ItemType Directory -Path $root | Out-Null
        $archive=Join-Path $root 'archive.lzh'
        Copy-Item -LiteralPath $seedArchive -Destination $archive
        if($caseName -eq 'comment'){
            $comment=Join-Path $root (([string][char]0x0100)+'-comment.txt')
            [IO.File]::WriteAllText($comment,'comment text',[Text.UTF8Encoding]::new($false))
            $command='c -n1 -gm1 -y1 -jz'+(Q $comment)+' '+(Q $archive)+' a.txt'
        } else {
            $sourceDir=Join-Path $root (([string][char]0x0100)+'-source')
            New-Item -ItemType Directory -Path $sourceDir | Out-Null
            $source=Join-Path $sourceDir (([string][char]0x0100)+'.txt')
            [IO.File]::WriteAllText($source,('A'*64),[Text.UTF8Encoding]::new($false))
            $fixed=[datetime]'2030-01-02T03:04:06Z'
            [IO.File]::SetCreationTimeUtc($source,$fixed)
            [IO.File]::SetLastAccessTimeUtc($source,$fixed)
            [IO.File]::SetLastWriteTimeUtc($source,$fixed)
            $command='a -gm1 -y1 -jm0 -h2 '+(Q $archive)+' '+(Q $source)
        }
        $dll=if($side -eq 'oracle'){$Oracle}else{$Candidate}
        $rows=Run-Wide $dll $command
        $hash=(Get-FileHash -LiteralPath $archive).Hash
        $records[$side]=[pscustomobject]@{Rows=$rows;Hash=$hash;Archive=$archive}
        Write-Host "=== $caseName/$side hash=$hash ==="
        $rows | Write-Host
    }
    if($records.oracle.Hash -cne $records.candidate.Hash){Write-Host "HASH DIFFERENCE $caseName" -ForegroundColor Yellow}
}
