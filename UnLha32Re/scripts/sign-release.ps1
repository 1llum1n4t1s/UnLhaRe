#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Candidate,
    [string]$CertificateThumbprint = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Candidate = [IO.Path]::GetFullPath($Candidate)
if (!(Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "署名対象 DLL が見つかりません: $Candidate"
}

function Get-NormalizedThumbprint {
    param([string]$Thumbprint)
    return ($Thumbprint -replace '[^0-9a-fA-F]', '').ToUpperInvariant()
}

function Test-CodeSigningCertificate {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)

    if (!$Certificate.HasPrivateKey -or $Certificate.NotBefore -gt [DateTime]::Now -or
        $Certificate.NotAfter -le [DateTime]::Now -or $Certificate.Subject -ceq $Certificate.Issuer) {
        return $false
    }
    foreach ($usage in $Certificate.EnhancedKeyUsageList) {
        if ($usage.ObjectId -eq '1.3.6.1.5.5.7.3.3') { return $true }
    }
    return $false
}

function Find-CodeSigningCertificate {
    param([string]$RequestedThumbprint)

    $normalized = Get-NormalizedThumbprint $RequestedThumbprint
    if ($RequestedThumbprint -and $normalized -notmatch '^[0-9A-F]{40}$') {
        throw 'CertificateThumbprint は SHA-1 証明書サムプリントではありません。'
    }
    $eligible = @(Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {
        (Test-CodeSigningCertificate $_) -and (!$normalized -or
            (Get-NormalizedThumbprint $_.Thumbprint) -ceq $normalized)
    })
    if ($eligible.Count -eq 0) {
        if ($normalized) {
            throw '指定された有効な非自己署名コード署名証明書が CurrentUser\My にありません。'
        }
        throw '有効な非自己署名コード署名証明書が CurrentUser\My にありません。'
    }
    if ($eligible.Count -ne 1) {
        throw '有効なコード署名証明書が複数あります。CertificateThumbprint で一意に指定してください。'
    }
    return $eligible[0]
}

function Find-SignTool {
    $sdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (!(Test-Path -LiteralPath $sdkBin -PathType Container)) {
        throw 'Windows SDK の bin ディレクトリが見つかりません。'
    }
    $directories = @(Get-ChildItem -LiteralPath $sdkBin -Directory | Sort-Object -Property @{
        Expression = { try { [Version]$_.Name } catch { [Version]'0.0' } }
        Descending = $true
    })
    foreach ($directory in $directories) {
        foreach ($architecture in @('x64', 'x86')) {
            $path = Join-Path $directory.FullName "$architecture\signtool.exe"
            if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
        }
    }
    throw 'Windows SDK の signtool.exe が見つかりません。'
}

function Invoke-SignTool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { $startInfo.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (!$process.Start()) { throw 'signtool.exe を開始できませんでした。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        if ($stdout) { [Console]::Out.Write($stdout) }
        if ($stderr) { [Console]::Error.Write($stderr) }
        if ($process.ExitCode -ne 0) {
            throw "signtool.exe が失敗しました (exit $($process.ExitCode))。"
        }
    } finally {
        $process.Dispose()
    }
}

$requestedThumbprint = Get-NormalizedThumbprint $CertificateThumbprint
$existingSignature = Get-AuthenticodeSignature -LiteralPath $Candidate
$canReuse = $existingSignature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
    (!$requestedThumbprint -or
        (Get-NormalizedThumbprint $existingSignature.SignerCertificate.Thumbprint) -ceq $requestedThumbprint)
if ($canReuse) {
    Write-Host '既存の有効な Authenticode 署名を再利用しました。'
    return
}

$certificate = Find-CodeSigningCertificate -RequestedThumbprint $CertificateThumbprint
$signTool = Find-SignTool
Invoke-SignTool -FilePath $signTool -ArgumentList @(
    'sign', '/fd', 'SHA256', '/tr', 'http://time.certum.pl/', '/td', 'SHA256',
    '/s', 'My', '/sha1', $certificate.Thumbprint, '/v', $Candidate
)
$signed = Get-AuthenticodeSignature -LiteralPath $Candidate
if ($signed.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    (Get-NormalizedThumbprint $signed.SignerCertificate.Thumbprint) -cne
        (Get-NormalizedThumbprint $certificate.Thumbprint)) {
    throw "署名後の Authenticode 検証に失敗しました: $($signed.Status)"
}
Write-Host 'Authenticode 署名と署名後検証が完了しました。'
