#requires -Version 7.2
<#
.SYNOPSIS
署名済みの UnLhaRe 配布物を Cloudflare R2（unlhare-updates / https://unlhare.kagayoi.com）へ配信する。

.DESCRIPTION
release-unlhare.yml（タグ unlhare-v<版> の push）の publish ジョブから呼ぶ。
GitHub Release は使わず（タグは配信の起点にだけ使う）、R2 を唯一の配布元にする。

置き場（バケット直下）:
  <ver>/UnLhaRe-<ver>-win-x64.zip            版付き・不変（immutable）
  <ver>/UnLhaRe-<ver>-win-arm64.zip          版付き・不変
  <ver>/UnLhaRe-<ver>-macos-arm64.tar.gz     版付き・不変
  <ver>/SHA256SUMS.txt                       版付き・不変（上の3ファイルの `<hash>  <name>`、名前の ordinal 順）
  <ver>/release.json                         版付き・不変（version・commit・files[{name,sha256}]）
  latest.json                                固定名のフィード（release.json と同じ内容）。最後に置き、固定名だけ purge する

DistDirectory の中身（通常モード）は、上の3ファイルと SHA256SUMS.txt と release.json だけに厳密一致させる
（余分なファイル・足りないファイル・サブフォルダーは失敗）。sign ジョブが作った成果物をそのまま渡す。

配信の順序と安全策:
  1. 入力検査（ファイル集合、実ハッシュと SHA256SUMS.txt・release.json の照合）と、bucket・zone の権限確認を、何も書く前に行う。
  2. 版付きファイルを先に置く（3ファイル -> SHA256SUMS.txt -> release.json）。同じキーが既にあって内容が同一なら
     成功（unchanged、再実行を許す）。内容が違えば上書きせず失敗する
     （署名のタイムスタンプが変わる再ビルドで、同じ版の別内容を上げない）。
  3. 公開 URL（Cloudflare 経由）から全ファイルを取り直して照合する。公開ドメイン未設定・誤設定のまま
     フィードだけを進めないための確認。
  4. R2 の latest.json の版が今回より新しければ latest.json は更新しない（後退防止）。同じか古ければ更新する。
  5. 固定名（latest.json）だけを purge する。purge の失敗は警告（latest.json は no-cache で配るため）。

-Import: 旧方式（GitHub Release、タグ unlhare-v<ver>）で公開済みの版を R2 へ取り込む。DistDirectory には元の
  Release の添付ファイルをそのまま置く。元の SHA256SUMS.txt に配布ファイル以外の行（例: macos-x64）が残っていても、
  配布する3ファイルについて照合して通す（それ以外の行・ファイルは無視して配信しない）。release.json は存在しないため
  -Commit（元のタグが指していたコミット）から生成し、SHA256SUMS.txt は配布する3ファイルだけの正規形で作り直す。
  配布するファイルの中身は一切変えない。

失敗は例外（throw）で知らせる。呼び出し側で $LASTEXITCODE を確認しないこと（スクリプト内部の
ネイティブ呼び出しの終了コードが残り、成功後でも誤って失敗扱いになるため）。

認証: 環境変数 CLOUDFLARE_API_TOKEN（R2 書込み＋キャッシュ purge 権限。CI では Environment の Secret）。
転送実装は Sigilune・Edictora と同じ R2Transfer.Core.cs / R2Distribution.Common.ps1（同梱コピー、無改変）を使う。
これらは複数リポジトリに同じものがあるため、片方だけを直さない（UnLhaRe/AGENTS.md 参照）。
#>
[CmdletBinding()]
param(
    # 配信する版（例 1.0.4）。タグ名と Cargo.toml の照合は呼び出し側（workflow の resolve ジョブ）で保証する。
    [Parameter(Mandatory)][string]$Version,
    # 配布ファイルを置いたフォルダー（上の「DistDirectory の中身」を参照）。
    [Parameter(Mandatory)][string]$DistDirectory,
    [string]$Bucket = 'unlhare-updates',
    [string]$BaseUrl = 'https://unlhare.kagayoi.com',
    # Cloudflare アカウント ID（秘密ではない。Sigilune・Edictora と同じアカウント）。
    [string]$AccountId = '10901bfadbf1005164774a7350082985',
    # 配信元のコミット（40桁の小文字 hex）。-Import では必須（release.json を生成する）。
    # 通常モードでは省略可で、指定すれば release.json の commit と一致していること。
    [string]$Commit,
    # 旧方式の公開済み版を取り込む（上の .DESCRIPTION 参照）。
    [switch]$Import,
    # 入力検査と release.json / latest.json の生成だけを行い、ネットワークへは一切接続しない（ローカル検証用）。
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -cnotmatch '^\d+\.\d+\.\d+$') { throw "version must look like 1.2.3: $Version" }
$BaseUrl = $BaseUrl.TrimEnd('/')
if ($BaseUrl -notmatch '^https://') { throw "BaseUrl must be https: $BaseUrl" }
if ($PSBoundParameters.ContainsKey('Commit') -and $Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'Commit must be a 40-digit lowercase hex SHA.' }
if ($Import -and -not $PSBoundParameters.ContainsKey('Commit')) { throw '-Import requires -Commit (the commit the old tag pointed at).' }

# 配布する3ファイル（名前の ordinal 順。SHA256SUMS.txt と release.json の files はこの順に並べる）。
$distNames = @(
    "UnLhaRe-$Version-macos-arm64.tar.gz",
    "UnLhaRe-$Version-win-arm64.zip",
    "UnLhaRe-$Version-win-x64.zip"
)
$sumsName = 'SHA256SUMS.txt'
$releaseName = 'release.json'

# --- 入力検査 ------------------------------------------------------------------------------------
$dist = Get-Item -LiteralPath $DistDirectory -ErrorAction Stop
if (-not $dist.PSIsContainer) { throw "DistDirectory is not a directory: $DistDirectory" }
$present = @(Get-ChildItem -LiteralPath $dist.FullName -Force)
if ($present | Where-Object { $_.PSIsContainer }) { throw 'DistDirectory must not contain sub-directories.' }
$presentNames = @($present | ForEach-Object Name)
if ($Import) {
    # 取り込みでは元の Release に付いていた他のファイル（macos-x64 など）が混ざってよい。配布する3ファイルと
    # 元の SHA256SUMS.txt は必須で、それ以外は無視する（配信しない）。
    $required = $distNames + @($sumsName)
} else {
    $required = $distNames + @($sumsName, $releaseName)
}
foreach ($name in $required) {
    if ($presentNames -cnotcontains $name) { throw "required file is missing: $name" }
}
if (-not $Import) {
    $unexpected = @($presentNames | Where-Object { $required -cnotcontains $_ })
    if ($unexpected.Count -gt 0) { throw "unexpected file(s) in DistDirectory: $($unexpected -join ', ')" }
}

# 実ハッシュ。
$actual = [ordered]@{}
foreach ($name in $distNames) {
    $actual[$name] = (Get-FileHash -LiteralPath (Join-Path $dist.FullName $name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
# 正規形の SHA256SUMS.txt（`<hash>  <name>\n`、ordinal 順）。
$canonicalSums = (($distNames | ForEach-Object { '{0}  {1}' -f $actual[$_], $_ }) -join "`n") + "`n"

$sumsPath = Join-Path $dist.FullName $sumsName
$sumsText = [IO.File]::ReadAllText($sumsPath, [Text.UTF8Encoding]::new($false, $true))
if ($Import) {
    # 元の SHA256SUMS.txt を行ごとに解釈し、配布する3ファイルの行が1つずつあって実ハッシュと一致することを確かめる。
    $listed = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($line in ($sumsText -split "`n")) {
        $line = $line.TrimEnd("`r")
        if ($line -eq '') { continue }
        if ($line -cnotmatch '^([0-9a-fA-F]{64})  (\S.*)$') { throw "$sumsName has an unparsable line: $line" }
        $lineName = $Matches[2]
        if ($listed.ContainsKey($lineName)) { throw "$sumsName lists $lineName more than once." }
        $listed[$lineName] = $Matches[1].ToLowerInvariant()
    }
    foreach ($name in $distNames) {
        if (-not $listed.ContainsKey($name)) { throw "$sumsName does not list $name" }
        if ($listed[$name] -cne $actual[$name]) { throw "$name does not match $sumsName (expected $($listed[$name]), actual $($actual[$name]))" }
    }
    $ignored = @($listed.Keys | Where-Object { $distNames -cnotcontains $_ })
    if ($ignored.Count -gt 0) { Write-Host "import: ignoring $sumsName line(s) for non-distributed file(s): $($ignored -join ', ')" }
    $sumsText = $canonicalSums   # 配信するのは正規形（配布ファイルだけ）
} else {
    # 通常モードは正規形と完全一致（余分な行・順序違い・大文字ハッシュも失敗）。
    if ($sumsText -cne $canonicalSums) { throw "$sumsName does not match the actual files (expected exactly the canonical 3 lines)" }
}

# release.json（version・commit・files）。
$files = @($distNames | ForEach-Object { [ordered]@{ name = $_; sha256 = $actual[$_] } })
if ($Import) {
    $release = [ordered]@{ version = $Version; commit = $Commit; files = $files }
    $releaseJson = ($release | ConvertTo-Json -Depth 4 -Compress) + "`n"
} else {
    $releasePath = Join-Path $dist.FullName $releaseName
    $releaseJson = [IO.File]::ReadAllText($releasePath, [Text.UTF8Encoding]::new($false, $true))
    $parsed = $releaseJson | ConvertFrom-Json
    $keys = @($parsed.PSObject.Properties.Name)
    if (Compare-Object -CaseSensitive $keys @('version', 'commit', 'files')) { throw "$releaseName must have exactly version, commit, files (got: $($keys -join ', '))" }
    if ("$($parsed.version)" -cne $Version) { throw "$releaseName version '$($parsed.version)' does not match $Version" }
    if ("$($parsed.commit)" -cnotmatch '^[0-9a-f]{40}$') { throw "$releaseName commit is not a 40-digit lowercase hex SHA" }
    if ($PSBoundParameters.ContainsKey('Commit') -and "$($parsed.commit)" -cne $Commit) { throw "$releaseName commit '$($parsed.commit)' does not match -Commit $Commit" }
    $listedFiles = @($parsed.files)
    if ($listedFiles.Count -ne $distNames.Count) { throw "$releaseName must list exactly $($distNames.Count) files" }
    for ($i = 0; $i -lt $distNames.Count; $i++) {
        $entry = $listedFiles[$i]
        $entryKeys = @($entry.PSObject.Properties.Name)
        if (Compare-Object -CaseSensitive $entryKeys @('name', 'sha256')) { throw "$releaseName files[$i] must have exactly name and sha256" }
        if ("$($entry.name)" -cne $distNames[$i]) { throw "$releaseName files[$i] must be $($distNames[$i]) (got $($entry.name))" }
        if ("$($entry.sha256)" -cne $actual[$distNames[$i]]) { throw "$releaseName sha256 for $($distNames[$i]) does not match the file" }
    }
}
Write-Host "package ok: version $Version, $($distNames.Count) files"
foreach ($name in $distNames) { Write-Host "  $($actual[$name])  $name" }

$work = Join-Path ([IO.Path]::GetTempPath()) ('unlhare-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # 配信するファイルを作業フォルダーへ集める（Import では正規形の SHA256SUMS.txt と生成した release.json を使う）。
    # ファイルの中身は常に上で検証した文字列と同じ。BOM なし UTF-8。
    $utf8 = [Text.UTF8Encoding]::new($false)
    $uploads = [Collections.Generic.List[hashtable]]::new()
    $contentTypes = @{ '.zip' = 'application/zip'; '.gz' = 'application/gzip' }
    foreach ($name in $distNames) {
        $type = $contentTypes[[IO.Path]::GetExtension($name)]
        $uploads.Add(@{ File = (Join-Path $dist.FullName $name); Key = "$Version/$name"; Type = $type; Name = $name })
    }
    $sumsFile = Join-Path $work $sumsName
    [IO.File]::WriteAllText($sumsFile, $sumsText, $utf8)
    $uploads.Add(@{ File = $sumsFile; Key = "$Version/$sumsName"; Type = 'text/plain; charset=utf-8'; Name = $sumsName })
    $releaseFile = Join-Path $work $releaseName
    [IO.File]::WriteAllText($releaseFile, $releaseJson, $utf8)
    $uploads.Add(@{ File = $releaseFile; Key = "$Version/$releaseName"; Type = 'application/json'; Name = $releaseName })
    # フィード latest.json は release.json と同じ内容（version / commit / files）。取り込み側が最小限の項目だけを信用する。
    $feedFile = Join-Path $work 'latest.json'
    [IO.File]::WriteAllText($feedFile, $releaseJson, $utf8)
    Write-Host "feed: $($releaseJson.Trim())"

    if ($ValidateOnly) {
        Write-Host 'ValidateOnly: no network access.'
        return
    }

    if (-not $env:CLOUDFLARE_API_TOKEN) { throw 'CLOUDFLARE_API_TOKEN is not set' }
    . (Join-Path $PSScriptRoot 'R2Distribution.Common.ps1')
    $api = 'https://api.cloudflare.com/client/v4'
    $headers = @{ Authorization = "Bearer $($env:CLOUDFLARE_API_TOKEN)" }

    # --- 書く前の権限確認（途中まで公開された状態を防ぐ） -----------------------------------------
    $bucketResponse = Invoke-RestMethod -Uri "$api/accounts/$AccountId/r2/buckets/$([uri]::EscapeDataString($Bucket))" `
        -Headers $headers -TimeoutSec 30 -MaximumRedirection 0
    if (-not $bucketResponse.success -or $bucketResponse.result.name -cne $Bucket) { throw "R2 bucket '$Bucket' was not found" }
    # <sub>.kagayoi.com -> kagayoi.com（apex）。キャッシュ purge に zone ID が要る。
    $zoneName = ([uri]$BaseUrl).Host -replace '^[^.]+\.', ''
    $zoneResponse = Invoke-RestMethod -Uri "$api/zones?name=$zoneName" -Headers $headers -TimeoutSec 30 -MaximumRedirection 0
    if (-not $zoneResponse.success -or @($zoneResponse.result).Count -eq 0) { throw "Cloudflare zone '$zoneName' was not found" }
    $zoneId = $zoneResponse.result[0].id

    # --- 後退防止の判定材料: いま公開されている latest.json の版 ----------------------------------
    # 固定名は no-cache で配っているため、公開 URL から読む。無い（404）なら初回配信。
    $remote = Invoke-WebRequest -Uri "$BaseUrl/latest.json" -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
    $remoteVersion = $null
    if ($remote.StatusCode -eq 200) {
        $remoteFeed = $remote.Content | ConvertFrom-Json
        # 壊れたフィードを黙って上書きしない（原因を確かめてから）。
        if (-not ($remoteFeed.PSObject.Properties.Name -contains 'version') -or "$($remoteFeed.version)" -notmatch '^\d+\.\d+\.\d+$') {
            throw "the published latest.json has no valid version; check $BaseUrl/latest.json"
        }
        $remoteVersion = [version]$remoteFeed.version
    } elseif ($remote.StatusCode -ne 404) {
        throw "could not read $BaseUrl/latest.json (HTTP $($remote.StatusCode))"
    }

    # --- 版付き（不変）ファイルを先に置く ----------------------------------------------------------
    # Immutable: 既存と同一なら成功（Changed=false）、既存と内容が違えば照合で失敗し上書きしない。
    # 順序は 3ファイル -> SHA256SUMS.txt -> release.json（$uploads の並び）。
    $immutableCache = 'public, max-age=31536000, immutable'
    foreach ($item in $uploads) {
        $result = Publish-R2Object -AccountId $AccountId -Bucket $Bucket -FilePath $item.File -Key $item.Key `
            -ApiToken $env:CLOUDFLARE_API_TOKEN -ContentType $item.Type -CacheControl $immutableCache -Immutable
        Write-Host ("  {0}  {1}" -f $(if ($result.Changed) { 'uploaded ' } else { 'unchanged' }), $item.Key)
    }

    # --- 公開 URL から取り直して照合（フィードを進める前の最終確認） --------------------------------
    foreach ($item in $uploads) {
        $publicFile = Join-Path $work ('public-' + $item.Name)
        Invoke-WebRequest -Uri "$BaseUrl/$($item.Key)" -OutFile $publicFile -MaximumRedirection 0 -TimeoutSec 600
        $expected = (Get-FileHash -LiteralPath $item.File -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $publicFile -Algorithm SHA256).Hash -cne $expected) {
            throw "$BaseUrl/$($item.Key) does not serve the uploaded file"
        }
        Remove-Item -LiteralPath $publicFile -Force
    }
    Write-Host "public URL verified: $BaseUrl/$Version/"

    # --- フィード（最後） ---------------------------------------------------------------------------
    if ($remoteVersion -and $remoteVersion -gt [version]$Version) {
        # 古い版の再実行・取り込みなどで latest を後退させない。版付きファイルは置いたので配信自体は成功。
        Write-Warning "published latest.json is already $remoteVersion (newer than $Version); latest.json was left unchanged."
        return
    }
    # 固定名は毎回再検証させる。Publish-R2Object は既存の ETag を If-Match に使い、同時更新を検出する。
    $null = Publish-R2Object -AccountId $AccountId -Bucket $Bucket -FilePath $feedFile -Key 'latest.json' `
        -ApiToken $env:CLOUDFLARE_API_TOKEN -ContentType 'application/json' -CacheControl 'no-cache, must-revalidate'
    Write-Host '  uploaded   latest.json'

    # --- 固定名だけ purge（版付きは URL が一意なので不要）。失敗は警告にとどめる -------------------
    try {
        $body = @{ files = @("$BaseUrl/latest.json") } | ConvertTo-Json -Compress
        $purge = Invoke-RestMethod -Method Post -Uri "$api/zones/$zoneId/purge_cache" -Headers $headers `
            -ContentType 'application/json' -Body $body -TimeoutSec 30 -MaximumRedirection 0
        if (-not $purge.success) { throw ($purge.errors | ConvertTo-Json -Compress) }
        Write-Host '  purged     latest.json'
    } catch {
        Write-Warning "uploaded, but the cache purge failed: $($_.Exception.Message)"
    }
    Write-Host "published UnLhaRe $Version to $BaseUrl"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
