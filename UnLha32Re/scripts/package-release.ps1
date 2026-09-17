[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Configuration = 'Release',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '..'))
$versionFile = Join-Path $repositoryRoot 'VERSION'

if (!$Version) {
    $Version = [IO.File]::ReadAllText($versionFile).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "配布バージョンが SemVer ではありません: $Version"
}
if ([IO.File]::ReadAllText($versionFile).Trim() -cne $Version) {
    throw 'VERSION と指定された配布バージョンが一致しません。'
}

$dll = Join-Path $projectRoot "artifacts\$Configuration\UNLHA32RE.dll"
if (!(Test-Path -LiteralPath $dll)) {
    throw "配布対象 DLL が見つかりません: $dll"
}
$dllVersion = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion
if ($dllVersion -ne '3.00.0.5') {
    throw "互換バージョンが不正です: $dllVersion"
}
$signature = Get-AuthenticodeSignature -LiteralPath $dll
if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
    throw "DLL の Authenticode 署名が有効ではありません: $($signature.Status)"
}

if (!$OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot "artifacts\releases\$Version"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$zip = Join-Path $OutputDirectory 'UnLha32Re-win-x86.zip'
$checksum = "$zip.sha256"
if ((Test-Path -LiteralPath $zip) -or (Test-Path -LiteralPath $checksum)) {
    throw "既存の配布物を上書きしません。新しい出力先を指定してください: $OutputDirectory"
}

$prefix = "UnLha32Re-$Version"
& git -C $repositoryRoot archive --format=zip --prefix="$prefix/source/" --output=$zip HEAD
if ($LASTEXITCODE -ne 0) { throw '対応ソースのアーカイブ作成に失敗しました。' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Update)
try {
    function Add-ReleaseFile([string]$Source, [string]$EntryName) {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $Source, $EntryName, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }

    Add-ReleaseFile $dll "$prefix/bin/UNLHA32RE.DLL"
    Add-ReleaseFile (Join-Path $repositoryRoot 'LICENSE') "$prefix/LICENSE"
    Add-ReleaseFile (Join-Path $projectRoot 'THIRD_PARTY_NOTICES.md') "$prefix/THIRD_PARTY_NOTICES.md"
    Add-ReleaseFile (Join-Path $repositoryRoot 'README.md') "$prefix/README.md"
    Add-ReleaseFile (Join-Path $projectRoot 'README.md') "$prefix/COMPATIBILITY.md"

    $dllHash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash.ToLowerInvariant()
    $readme = @"
UnLha32Re $Version

UNLHA32.DLL 3.00.0.5 互換を目指す 32 ビット (x86) Windows DLL です。

導入:
1. bin\UNLHA32RE.DLL を対象となる 32 ビットアプリの実行ファイルと同じフォルダーへ配置します。
2. アプリが従来名を固定して読み込む場合は、UNLHA32.DLL へ名前を変更します。
3. System32 や SysWOW64 には配置しないでください。

互換範囲と既知の差異は COMPATIBILITY.md、再配布条件は
THIRD_PARTY_NOTICES.md、対応ソースは source\ を確認してください。
"@
    $readmeEntry = $archive.CreateEntry("$prefix/README.txt")
    $writer = [IO.StreamWriter]::new($readmeEntry.Open(), [Text.UTF8Encoding]::new($true))
    try { $writer.Write($readme.Replace("`n", "`r`n")) } finally { $writer.Dispose() }

    $hashEntry = $archive.CreateEntry("$prefix/SHA256SUMS.txt")
    $writer = [IO.StreamWriter]::new($hashEntry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write("$dllHash  bin/UNLHA32RE.DLL`r`n") } finally { $writer.Dispose() }
} finally {
    $archive.Dispose()
}

$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($checksum, "$zipHash  $([IO.Path]::GetFileName($zip))`r`n", [Text.UTF8Encoding]::new($false))
Write-Host "Package: $zip"
Write-Host "SHA256: $zipHash"
