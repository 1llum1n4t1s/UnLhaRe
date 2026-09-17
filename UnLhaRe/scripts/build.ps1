[CmdletBinding()]
param(
    [ValidateSet(
        'x86_64-pc-windows-msvc',
        'aarch64-pc-windows-msvc',
        'x86_64-apple-darwin',
        'aarch64-apple-darwin'
    )]
    [string]$Target,

    [switch]$Test
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$cargoCommand = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue
if ($null -ne $cargoCommand) {
    $cargo = $cargoCommand.Source
} else {
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
    if (-not (Test-Path -LiteralPath $cargo -PathType Leaf)) {
        throw 'cargo was not found on PATH or at %USERPROFILE%\.cargo\bin\cargo.exe.'
    }
}

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows
)
$isMacHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::OSX
)
$hostArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture

if ($isWindowsHost) {
    $hostTarget = switch ($hostArchitecture) {
        'X64' { 'x86_64-pc-windows-msvc' }
        'Arm64' { 'aarch64-pc-windows-msvc' }
        default { throw "Unsupported Windows host architecture: $hostArchitecture" }
    }
} elseif ($isMacHost) {
    $hostTarget = switch ($hostArchitecture) {
        'X64' { 'x86_64-apple-darwin' }
        'Arm64' { 'aarch64-apple-darwin' }
        default { throw "Unsupported macOS host architecture: $hostArchitecture" }
    }
} else {
    throw 'Only Windows and macOS hosts are supported.'
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = $hostTarget
}

$targetIsWindows = $Target.EndsWith('-pc-windows-msvc', [System.StringComparison]::Ordinal)
$targetIsMac = $Target.EndsWith('-apple-darwin', [System.StringComparison]::Ordinal)
$isCrossOperatingSystem = ($targetIsWindows -and -not $isWindowsHost) -or ($targetIsMac -and -not $isMacHost)
$isNativeTarget = $Target -eq $hostTarget
$cargoTargetDirectory = Join-Path $repositoryRoot 'build\cargo'
$previousCargoTargetDirectory = $env:CARGO_TARGET_DIR

function Invoke-Cargo {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & $cargo @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "cargo $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

function New-LocalBundle {
    $releaseDirectory = Join-Path $cargoTargetDirectory "$Target\release"
    if ($targetIsWindows) {
        $binaryFiles = @('unlhare-cli.exe', 'unlhare.dll', 'unlhare.dll.lib')
    } else {
        $binaryFiles = @('unlhare-cli', 'libunlhare.dylib')
    }

    $artifactsDirectory = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'artifacts'))
    New-Item -ItemType Directory -Path $artifactsDirectory -Force | Out-Null
    $artifactsItem = Get-Item -LiteralPath $artifactsDirectory -Force
    if (($artifactsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to modify a reparse-point artifacts directory: $artifactsDirectory"
    }
    $artifactsDirectory = (Resolve-Path -LiteralPath $artifactsDirectory).Path
    $artifactsPrefix = $artifactsDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    function Resolve-ArtifactsChild {
        param([Parameter(Mandatory)][string]$Path)

        $absolutePath = [System.IO.Path]::GetFullPath($Path)
        if (-not $absolutePath.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to modify a path outside artifacts: $absolutePath"
        }
        if (Test-Path -LiteralPath $absolutePath) {
            $item = Get-Item -LiteralPath $absolutePath -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to modify a reparse point: $absolutePath"
            }
            $absolutePath = (Resolve-Path -LiteralPath $absolutePath).Path
            if (-not $absolutePath.StartsWith($artifactsPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Resolved path is outside artifacts: $absolutePath"
            }
        }
        return $absolutePath
    }

    $bundleDirectory = Resolve-ArtifactsChild (Join-Path $artifactsDirectory $Target)
    $temporaryBundle = Resolve-ArtifactsChild (Join-Path $artifactsDirectory ".$Target-$PID-$([guid]::NewGuid().ToString('N'))")
    $bundleFiles = @(
        @{ Source = (Join-Path $repositoryRoot 'include\unlhare.h'); Destination = 'include\unlhare.h' },
        @{ Source = (Join-Path $repositoryRoot 'README.md'); Destination = 'README.md' },
        @{ Source = (Join-Path $repositoryRoot 'VALIDATION.md'); Destination = 'VALIDATION.md' },
        @{ Source = ([System.IO.Path]::GetFullPath((Join-Path $repositoryRoot '..\LICENSE'))); Destination = 'LICENSE' },
        @{ Source = (Join-Path $repositoryRoot 'THIRD_PARTY_NOTICES.md'); Destination = 'THIRD_PARTY_NOTICES.md' },
        @{ Source = (Join-Path $repositoryRoot 'THIRD_PARTY_LICENSES.txt'); Destination = 'THIRD_PARTY_LICENSES.txt' },
        @{ Source = (Join-Path $repositoryRoot 'Cargo.lock'); Destination = 'Cargo.lock' }
    )
    foreach ($binaryFile in $binaryFiles) {
        $bundleFiles += @{ Source = (Join-Path $releaseDirectory $binaryFile); Destination = $binaryFile }
    }
    if ($targetIsWindows -and (Test-Path -LiteralPath $releaseDirectory -PathType Container)) {
        foreach ($debugFile in Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.pdb' -File) {
            $bundleFiles += @{ Source = $debugFile.FullName; Destination = $debugFile.Name }
        }
    }

    foreach ($file in $bundleFiles) {
        if (-not (Test-Path -LiteralPath $file.Source -PathType Leaf)) {
            throw "Cannot create bundle because a required file is missing: $($file.Source)"
        }
    }
    $licensingDirectory = Join-Path $repositoryRoot 'licensing'
    if (-not (Test-Path -LiteralPath $licensingDirectory -PathType Container)) {
        throw "Cannot create bundle because the licensing directory is missing: $licensingDirectory"
    }

    try {
        New-Item -ItemType Directory -Path (Join-Path $temporaryBundle 'include') -Force | Out-Null
        foreach ($file in $bundleFiles) {
            $destination = Join-Path $temporaryBundle $file.Destination
            Copy-Item -LiteralPath $file.Source -Destination $destination
        }
        Copy-Item -LiteralPath $licensingDirectory -Destination $temporaryBundle -Recurse

        if (Test-Path -LiteralPath $bundleDirectory) {
            Remove-Item -LiteralPath $bundleDirectory -Recurse -Force
        }
        Move-Item -LiteralPath $temporaryBundle -Destination $bundleDirectory
    } finally {
        if (Test-Path -LiteralPath $temporaryBundle) {
            Remove-Item -LiteralPath $temporaryBundle -Recurse -Force
        }
    }

    Write-Host "Bundle: $bundleDirectory"
}

try {
    $env:CARGO_TARGET_DIR = $cargoTargetDirectory
    Push-Location -LiteralPath $repositoryRoot
    try {
        if ($Test -and $isNativeTarget) {
            Invoke-Cargo -Arguments @('fmt', '--all', '--', '--check')
            Invoke-Cargo -Arguments @('clippy', '--locked', '--workspace', '--all-targets', '--target', $Target, '--', '-D', 'warnings')
            Invoke-Cargo -Arguments @('test', '--locked', '--workspace', '--target', $Target)
        } elseif ($Test) {
            Write-Warning "Tests run only on the native host target ($hostTarget); building $Target without running tests."
        }

        if ($isCrossOperatingSystem) {
            Write-Warning "No native SDK is available for $Target on this host; running cargo check only. Build and test this target in CI."
            Invoke-Cargo -Arguments @('check', '--locked', '--workspace', '--release', '--target', $Target)
        } else {
            Invoke-Cargo -Arguments @('build', '--locked', '--workspace', '--release', '--target', $Target)
            New-LocalBundle
        }
    } finally {
        Pop-Location
    }
} finally {
    if ($null -eq $previousCargoTargetDirectory) {
        Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    } else {
        $env:CARGO_TARGET_DIR = $previousCargoTargetDirectory
    }
}
