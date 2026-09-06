[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$NoCrc,
    [Parameter(Mandatory)][string]$Good,
    [Parameter(Mandatory)][string]$Pmarc,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$NoCrc = (Resolve-Path -LiteralPath $NoCrc).Path
$Good = (Resolve-Path -LiteralPath $Good).Path
$Pmarc = (Resolve-Path -LiteralPath $Pmarc).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$runner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe'
if (Test-Path -LiteralPath $Workspace) { throw 'Use a fresh missing-CRC sequence directory' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$goodBytes = [IO.File]::ReadAllBytes($Good)
$noCrcBytes = [IO.File]::ReadAllBytes($NoCrc)
$pmarcBytes = [IO.File]::ReadAllBytes($Pmarc)
$goodMember = [byte[]]$goodBytes[0..($goodBytes.Length-2)]
$noCrcMember = [byte[]]$noCrcBytes[0..($noCrcBytes.Length-2)]
$pmarcMember = [byte[]]$pmarcBytes[0..($pmarcBytes.Length-2)]
$inputs = [ordered]@{
    'missing-good'=[byte[]]($noCrcMember+$goodMember+0)
    'good-missing'=[byte[]]($goodMember+$noCrcMember+0)
    'good-missing-good'=[byte[]]($goodMember+$noCrcMember+$goodMember+0)
    'missing-pmarc-good'=[byte[]]($noCrcMember+$pmarcMember+$goodMember+0)
}
$hashes = @{}
foreach ($path in $TestProgram,$Oracle,$Candidate,$runner,$NoCrc,$Good,$Pmarc) { $hashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
$results = [Collections.Generic.List[object]]::new()
foreach ($name in $inputs.Keys) {
    $archive = Join-Path $Workspace "$name.lzh"
    [IO.File]::WriteAllBytes($archive,$inputs[$name])
    $hashes[$archive] = (Get-FileHash -LiteralPath $archive).Hash
    foreach ($operation in 'l','v','t','p') { foreach ($api in 'legacy','A','W') { foreach ($profile in 'raw','all','missing') {
        $pattern = if ($profile -eq 'missing') { 'missing' } else { '*' }
        $line = $operation + ' -gm1 -n1 "' + $archive + '" "' + $pattern + '"'
        $label = "$name-$operation-$api-$profile"
        $snapshots = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $arguments = if ($profile -eq 'raw') { @('--registry','','--command-raw-probe',$dll,$line,$api,256,'utf8') }
                else { @('--registry','','--command-enum-probe',$dll,$line,'w64',1,'',1041,1,$api,1) }
            $rows = @(& $runner --timeout-seconds 30 $TestProgram @arguments 2>&1 | ForEach-Object { "$_" })
            if ($LASTEXITCODE -ne 0 -or @($rows -match '^result=').Count -ne 1) { throw "Sequence probe failed: $label/$side" }
            [IO.File]::WriteAllLines((Join-Path $Workspace "$label.$side.txt"),[string[]]$rows,[Text.UTF8Encoding]::new($false))
            $snapshots += ,$rows
        }
        $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
        if ($difference.Count) { $difference | Export-Csv -LiteralPath (Join-Path $Workspace "$label.diff.tsv") -Delimiter "`t" -NoTypeInformation }
        $results.Add([pscustomobject]@{name=$name;operation=$operation;api=$api;profile=$profile;differences=$difference.Count})
    } } }
    Write-Host "Missing CRC sequence: $name, $($results.Count) observed"
}
$results | Export-Csv -LiteralPath (Join-Path $Workspace 'observations.tsv') -Delimiter "`t" -NoTypeInformation
foreach ($path in $hashes.Keys) { if ((Get-FileHash -LiteralPath $path).Hash -cne $hashes[$path]) { throw "Sequence artifact changed: $path" } }
$failed = @($results | Where-Object { [int]$_.differences -ne 0 })
if ($results.Count -ne 144 -or $failed.Count -ne 0) {
    $sample = $failed | Select-Object -First 8 | Format-Table -AutoSize | Out-String -Width 2000
    throw "CRC 欠落項目の順序別結果が一致しません。$([Environment]::NewLine)$sample"
}
Write-Host "Missing CRC sequence: 144 exact initial/middle/mixed comparisons compatible"


