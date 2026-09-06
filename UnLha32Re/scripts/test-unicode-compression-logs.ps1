[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
$timestamp = [datetime]::new(2024, 1, 2, 3, 4, 6, [DateTimeKind]::Utc)
$count = 0
foreach ($locale in 1033, 1041) {
  foreach ($utf8 in 0, 1) {
    foreach ($api in 'legacy', 'A', 'W') {
      foreach ($command in 'a', 'u', 'f', 'm') {
        $label = "$locale-$utf8-$api-$command"
        $results = @()
        foreach ($side in 'oracle', 'reimpl') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $root = Join-Path $Workspace "$label-$side"
            $source = Join-Path $root 'source'
            New-Item -ItemType Directory -Path $source -Force | Out-Null
            $member = Join-Path $source '日本語.txt'
            [IO.File]::WriteAllBytes($member, [byte[]](65, 66, 67))
            [IO.File]::SetCreationTimeUtc($member, $timestamp)
            [IO.File]::SetLastAccessTimeUtc($member, $timestamp)
            [IO.File]::SetLastWriteTimeUtc($member, $timestamp)
            $archive = Join-Path $root 'archive.lzh'
            # 基準ディレクトリと相対ワイルドカードの解決順の差は、このログ試験に混ぜない。
            Push-Location -LiteralPath $source
            try {
                if ($command -in 'u', 'f') {
                    # level-2 の日本語名を更新すると生じる既存のヘッダー CRC 差とは分けて調べる。
                    $seedLine = "a -h0 -n1 -gm1 -y1 `"$archive`" `"$source\`" *"
                    $seed = @(& $TestProgram --registry '' --command-enum-probe $Oracle $seedLine none 1 '' $locale $utf8 $api 0)
                    if ($LASTEXITCODE -ne 0 -or $seed -notcontains 'result=0') {
                        throw "更新用書庫を作成できません: $label / $side"
                    }
                }
                $line = "$command -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$source\`" *"
                $rows = @(& $TestProgram --registry '' --command-enum-probe $dll $line none 1 '' $locale $utf8 $api 0)
                $probeExit = $LASTEXITCODE
            } finally { Pop-Location }
            if ($probeExit -ne 0 -or $rows -notcontains 'result=0') {
                throw "Unicode 圧縮ログ試験に失敗しました: $label / $side`n$($rows -join "`n")"
            }
            $rows = @($rows | ForEach-Object {
                $_.Replace($root.Replace('\', '/'), '<ROOT>').Replace($root.Replace('\', '\\'), '<ROOT>')
            })
            $rows += "source-exists=$(Test-Path -LiteralPath $member)"
            # 両方の出力書庫を元 DLL で読み、格納名・属性の維持と読取可能性も確認する。
            $metadata = @(& $TestProgram --registry '' --attribute-probe $Oracle $archive)
            if ($LASTEXITCODE -ne 0) { throw "圧縮結果を読み取れません: $label / $side" }
            $rows += $metadata
            $results += ,$rows
        }
        $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
        if ($difference.Count -ne 0) {
            $details = $difference | Select-Object -First 8 | Out-String -Width 1500
            throw "Unicode 圧縮ログが一致しません: $label`n$details"
        }
        $count++
      }
    }
  }
}
Write-Host "Unicode compression logs: $count add/update/freshen/move comparisons and original-DLL metadata reads passed"
