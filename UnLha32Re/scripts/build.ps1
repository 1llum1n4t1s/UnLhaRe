[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer の vswhere.exe が見つかりません。'
}

$installationPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
if (-not $installationPath) {
    throw 'MSBuild を含む Visual Studio が見つかりません。'
}

$msbuild = Join-Path $installationPath 'MSBuild\Current\Bin\MSBuild.exe'
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild が見つかりません: $msbuild"
}

& $msbuild (Join-Path $repositoryRoot 'UnLhaRe.sln') `
    /nologo /m /t:Build "/p:Configuration=$Configuration" /p:Platform=x86
if ($LASTEXITCODE -ne 0) {
    throw "ビルドに失敗しました (exit $LASTEXITCODE)。"
}

$dll = Join-Path $repositoryRoot "artifacts\$Configuration\UNLHA32RE.dll"
if (-not (Test-Path -LiteralPath $dll)) {
    throw "出力 DLL が見つかりません: $dll"
}
Write-Host "Built: $dll"
