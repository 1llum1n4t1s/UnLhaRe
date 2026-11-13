#requires -Version 7.0
# リリース候補（DLL・EXE）へ Authenticode 署名する。
#
# 署名は Sigilune (https://github.com/1llum1n4t1s/Sigilune) で、Certum SimplySign のクラウド鍵を
# signtool の /dlib として使う。SimplySign Desktop・証明書ストア・手入力のワンタイムコードは不要。
# - ローカル: `sigilune setup` で資格情報マネージャーへ登録済みであること。
# - GitHub Actions: Environment "release" の Secrets を SIGILUNE_EMAIL / SIGILUNE_TOTP_URI で
#   署名 step だけへ渡す（.github/workflows/release-unlhare.yml）。
# UnLha32Re の release.ps1 と、近代化版 UnLhaRe の Windows bundle の両方から使う。
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Candidate,
    # 互換のため残す。指定時は署名者の証明書がこの SHA-1 サムプリントであることも必須にする
    # （Sigilune はアカウントの証明書で署名するため、証明書の選択には使わない）。
    [string]$CertificateThumbprint = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Candidate = [IO.Path]::GetFullPath($Candidate)
if (!(Test-Path -LiteralPath $Candidate -PathType Leaf)) {
    throw "署名対象ファイルが見つかりません: $Candidate"
}

# 署名者の CN。証明書の年次更新で thumbprint が変わっても同じ値で照合できる。
$signerCommonName = 'Open Source Developer Yuichiro Shinozaki'
. (Join-Path $PSScriptRoot 'Sigilune.Common.ps1')

function Get-NormalizedThumbprint {
    param([string]$Thumbprint)
    return ($Thumbprint -replace '[^0-9a-fA-F]', '').ToUpperInvariant()
}

$requestedThumbprint = Get-NormalizedThumbprint $CertificateThumbprint
if ($CertificateThumbprint -and $requestedThumbprint -notmatch '^[0-9A-F]{40}$') {
    throw 'CertificateThumbprint は SHA-1 証明書サムプリントではありません。'
}

# 本人の署名（有効・署名者 CN 一致・タイムスタンプあり、指定時は thumbprint も一致）かを判定する。
function Test-ReleaseSignature {
    param([Management.Automation.Signature]$Signature)
    return $Signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and
        $Signature.SignerCertificate.Subject -like "CN=$signerCommonName*" -and
        $null -ne $Signature.TimeStamperCertificate -and
        (!$requestedThumbprint -or
            (Get-NormalizedThumbprint $Signature.SignerCertificate.Thumbprint) -ceq $requestedThumbprint)
}

# 再実行時は、既に本人の有効な署名があればそのまま使う（タイムスタンプ通信と TOTP を節約する）。
if (Test-ReleaseSignature (Get-AuthenticodeSignature -LiteralPath $Candidate)) {
    Write-Host '既存の有効な Authenticode 署名を再利用しました。'
    return
}

$sigilune = Resolve-SigiluneExe
Connect-Sigilune -SigiluneExe $sigilune
# 本人以外・無効な署名が付いている場合は置き換える（旧 signtool と同じ挙動）。
# Sigilune は署名後に有効性・署名者・タイムスタンプを検証し、失敗なら非0で終わる。
& $sigilune sign --replace $Candidate
if ($LASTEXITCODE -ne 0) {
    throw "Sigilune の署名に失敗しました (exit $LASTEXITCODE)。自動再試行はしません。"
}
$signed = Get-AuthenticodeSignature -LiteralPath $Candidate
if (!(Test-ReleaseSignature $signed)) {
    throw "署名後の Authenticode 検証に失敗しました: $($signed.Status)"
}
Write-Host 'Authenticode 署名と署名後検証が完了しました。'
