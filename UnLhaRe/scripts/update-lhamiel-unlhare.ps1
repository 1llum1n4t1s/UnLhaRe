[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^1\.0\.\d+$')]
    [string]$OldVersion,

    [Parameter(Mandatory)]
    [ValidatePattern('^1\.0\.\d+$')]
    [string]$Version
)

$resolvedProjectPath = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
$content = [System.IO.File]::ReadAllText($resolvedProjectPath)

$versionPattern = [regex]::new('(<UnLhaReVersion>)([^<]+)(</UnLhaReVersion>)')
$versionMatches = $versionPattern.Matches($content)
if ($versionMatches.Count -ne 1) {
    throw "UnLhaReVersion が1件に定まりません: $ProjectPath ($($versionMatches.Count)件)"
}

$referencePattern = [regex]::new(
    '<PackageReference\s+Include="Kagayoi\.UnLhaRe"\s+Version="\$\(UnLhaReVersion\)"\s*/>'
)
$referenceMatches = $referencePattern.Matches($content)
if ($referenceMatches.Count -ne 1) {
    throw "Kagayoi.UnLhaRe のプロパティ参照が1件に定まりません: $ProjectPath ($($referenceMatches.Count)件)"
}

$currentVersion = $versionMatches[0].Groups[2].Value
if ($currentVersion -ne $OldVersion -and $currentVersion -ne $Version) {
    throw "Kagayoi.UnLhaRe の現在版が想定外です: $ProjectPath ($currentVersion)"
}

if ($currentVersion -eq $Version) {
    return
}

$updatedContent = $versionPattern.Replace(
    $content,
    {
        param($match)
        $match.Groups[1].Value + $Version + $match.Groups[3].Value
    },
    1
)

[System.IO.File]::WriteAllText(
    $resolvedProjectPath,
    $updatedContent,
    [System.Text.UTF8Encoding]::new($false)
)
