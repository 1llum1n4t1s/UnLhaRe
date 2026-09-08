[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$Progress,
    [ValidateSet('none','a32','w32','a64','w64')][string]$EnumLayout = 'none',
    [ValidateSet('a','u','f','m')][string[]]$Commands = @('a','u','f','m'),
    [ValidateSet('missing','search-only','search-read','no-base','prefix','nested','recursive','dot','double','absolute-parent','fresh-read-missing','fresh-read-partial','recursive-deep','dot-recursive','no-base-recursive')]
    [string[]]$Variants = @('missing','search-only','search-read','no-base','prefix','nested','recursive','dot','double','absolute-parent','fresh-read-missing','recursive-deep','dot-recursive','no-base-recursive')
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression parent paths workspace: $Workspace"
$count = 0
$when = [DateTime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)

foreach ($variant in $Variants) {
 foreach ($locale in 1033,1041) {
  foreach ($utf8 in 0,1) {
   foreach ($api in 'legacy','A','W') {
    foreach ($command in $Commands) {
        $label = "$variant-$locale-$utf8-$api-$command"
        $results = @()
        foreach ($side in 'oracle','reimpl') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $root = Join-Path $Workspace "$label-$side"
            $caller = Join-Path $root 'caller'
            New-Item -ItemType Directory -Path $caller,(Join-Path $caller 'source') | Out-Null
            $files = [ordered]@{
                'source/literal.txt' = 'parent-value'
                'caller/wrong.txt' = 'wrong-caller-value'
                'seed/literal.txt' = 'old-value'
                'seed/sub/deep.txt' = 'old-deep-value'
                'seed/..prefix.txt' = 'old-prefix-value'
            }
            if ($variant -eq 'fresh-read-missing') { $files.Remove('source/literal.txt') }
            if ($variant -ne 'missing') {
                $searchDirectory = if ($variant -eq 'double') { '....source' } else { '..source' }
                $files["caller/$searchDirectory/literal.txt"] = 'search-value'
            }
            if ($variant -notin 'missing','search-only') { $files['caller/source/literal.txt'] = 'read-value' }
            if ($variant -in 'recursive','fresh-read-partial','recursive-deep','dot-recursive','no-base-recursive') {
                $files['caller/..source/sub/deep.txt'] = 'search-deep-value'
                $files['caller/source/sub/deep.txt'] = 'read-deep-value'
            }
            if ($variant -in 'recursive-deep','dot-recursive','no-base-recursive') {
                $files['caller/..source/sub/nest/deeper.txt'] = 'search-deeper-value'
                $files['caller/source/sub/nest/deeper.txt'] = 'read-deeper-value'
            }
            if ($variant -eq 'prefix') { $files['caller/..prefix.txt'] = 'prefix-value' }
            foreach ($file in $files.GetEnumerator()) {
                $path = Join-Path $root $file.Key
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($path)) -Force | Out-Null
                [IO.File]::WriteAllBytes($path,[Text.Encoding]::ASCII.GetBytes($file.Value))
                $stamp = if ($file.Key.StartsWith('seed/')) { $when.AddYears(-4) } else { $when }
                [IO.File]::SetCreationTimeUtc($path,$stamp)
                [IO.File]::SetLastWriteTimeUtc($path,$stamp)
                [IO.File]::SetLastAccessTimeUtc($path,$stamp)
            }
            $archive = Join-Path $root 'result.lzh'
            if ($command -ne 'a') {
                # h2 更新 CRC の別件を混ぜず、存在する書庫への入力選択を比較する。
                $seed = "a -h0 -gm1 -y1 -c1 -x1 -r1 `"$archive`" `"$root\seed\`" `"*.txt`""
                $rows = @(& $TestProgram --registry '' --base-command-probe $Oracle $seed $locale $utf8 $api)
                if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or -not (Test-Path -LiteralPath $archive)) {
                    throw "更新元の作成に失敗しました: $label / $side"
                }
            }
            $archiveBeforeHash = if (Test-Path -LiteralPath $archive) { (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash } else { $null }
            $base = '..\source\'
            $pattern = '*.txt'
            $flags = '-x0'
            if ($variant -eq 'prefix') { $base = '..\' }
            if ($variant -eq 'nested') { $base = '..\'; $pattern = 'source\*.txt'; $flags = '-x1' }
            if ($variant -in 'recursive','fresh-read-partial','recursive-deep','dot-recursive','no-base-recursive') { $flags = '-x1 -r1' }
            if ($variant -in 'dot','dot-recursive') { $base = '.\source\' }
            if ($variant -eq 'double') { $base = '..\..\source\' }
            if ($variant -eq 'absolute-parent') { $base = "$caller\..\source\" }
            $operands = "`"$base`" `"$pattern`""
            if ($variant -eq 'no-base') { $operands = '"..\source\*.txt"'; $flags = '-x1' }
            if ($variant -eq 'no-base-recursive') { $operands = '"..\source\*.txt"'; $flags = '-x1 -r1' }
            $line = "$command -h2 -n1 -gm1 -y1 -c1 $flags `"$archive`" $operands"
            Push-Location -LiteralPath $caller
            try {
                $rows = @(& $TestProgram --registry '' --base-command-probe $dll $line $locale $utf8 $api $EnumLayout ([int]$Progress.IsPresent))
                $probeExit = $LASTEXITCODE
            } finally { Pop-Location }
            if ($probeExit -ne 0 -or $rows -notcontains 'directory-preserved=1') {
                throw "親相対パスの呼び出しに失敗しました: $label / $side`n$($rows -join "`n")"
            }
            $exists = Test-Path -LiteralPath $archive
            $candidateProducedArchive = $side -eq 'reimpl' -and $exists -and
                ($null -eq $archiveBeforeHash -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $archiveBeforeHash)
            $rows += "archive-exists=$exists"
            if ($exists) {
                $metadata = @(& $TestProgram --registry '' --attribute-probe $Oracle $archive)
                if ($LASTEXITCODE -ne 0) { throw "原版で結果を列挙できません: $label / $side" }
                $rows += $metadata
                # 検索先と読み取り先の内容を区別し、格納された実データまで比較する。
                $contents = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`"" A)
                if ($LASTEXITCODE -ne 0 -or $contents -notcontains 'result=0') { throw "原版で結果を読めません: $label / $side" }
                if ($candidateProducedArchive) {
                    # 候補生成書庫を候補自身の全列挙・メモリ展開 API でも読み戻し、原版結果と厳密に比較する。
                    $candidateMetadata = @(& $TestProgram --registry '' --attribute-probe $Candidate $archive)
                    $candidateMetadataExit = $LASTEXITCODE
                    [IO.File]::WriteAllLines((Join-Path $root 'candidate-metadata.txt'),[string[]](@("probe-exit=$candidateMetadataExit") + $candidateMetadata))
                    if ($candidateMetadataExit -ne 0) {
                        throw "生成書庫のメタデータを候補自身で読み取れません: $label / $side"
                    }
                    $metadataDifference = @(Compare-Object $metadata $candidateMetadata -CaseSensitive -SyncWindow 0)
                    if ($metadataDifference.Count) {
                        $details = $metadataDifference | Select-Object -First 12 | Out-String -Width 2000
                        throw "候補生成書庫のメタデータ・メモリ展開が原版と不一致です: $label`n$details"
                    }
                    $candidateContents = @(& $TestProgram --registry '' --command-probe-a $Candidate "p -+ `"$archive`"" A)
                    $candidateContentsExit = $LASTEXITCODE
                    [IO.File]::WriteAllLines((Join-Path $root 'candidate-payload.txt'),[string[]](@("probe-exit=$candidateContentsExit") + $candidateContents))
                    if ($candidateContentsExit -ne 0 -or $candidateContents -notcontains 'result=0') {
                        throw "生成書庫の内容を候補自身で読み取れません: $label / $side (exit $candidateContentsExit)`n$($candidateContents -join "`n")"
                    }
                    $contentsDifference = @(Compare-Object $contents $candidateContents -CaseSensitive -SyncWindow 0)
                    if ($contentsDifference.Count) {
                        $details = $contentsDifference | Select-Object -First 12 | Out-String -Width 2000
                        throw "候補生成書庫の本文読み戻しが原版と不一致です: $label`n$details"
                    }
                }
                $rows += @($contents | ForEach-Object { "data.$_" })
            }
            foreach ($file in $files.Keys) { $rows += "file=$file,exists=$(Test-Path -LiteralPath (Join-Path $root $file))" }
            $rows = @($rows | ForEach-Object {
                $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
            $results += ,$rows
        }
        $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
        if ($difference.Count) {
            $details = $difference | Select-Object -First 12 | Out-String -Width 2000
            throw "親相対パスの検索・読み取り・副作用が不一致です: $label`n$details"
        }
        $count++
    }
   }
  }
 }
 Write-Host "Compression parent paths: $variant, $count comparisons passed"
}
Write-Host "Compression parent paths: $count A/W/legacy commands=$($Commands -join '/'), search/read, bytes, errors, working-directory comparisons passed; progress=$($Progress.IsPresent); enum=$EnumLayout"
