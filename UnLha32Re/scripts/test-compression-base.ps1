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
Write-Host "Compression base workspace: $Workspace"
$count = 0
$names = @('a.txt','日本語.txt','sub/c.txt','sub/deep/d.txt')

function Set-SourceTimes([string]$Path, [int]$Year) {
    $value = [DateTime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$value)
    [IO.File]::SetLastWriteTimeUtc($Path,$value)
    [IO.File]::SetLastAccessTimeUtc($Path,$value)
}

foreach ($variant in 'top','nested','recursive','relative','absolute','control','response','unicode-base') {
 foreach ($locale in 1033,1041) {
  foreach ($utf8 in 0,1) {
   foreach ($api in 'legacy','A','W') {
    foreach ($command in 'a','u','f','m') {
        $label = "$variant-$locale-$utf8-$api-$command"
        $results = @()
        foreach ($side in 'original','candidate') {
            $dll = if ($side -eq 'original') { $Oracle } else { $Candidate }
            $suffix = if ($side -eq 'original') { 'oracle' } else { 'reimpl' }
            $root = Join-Path $Workspace "$label-$suffix"
            $source = Join-Path $root $(if ($variant -eq 'unicode-base') { '入力日本語' } else { 'source' })
            $caller = Join-Path $root 'caller'
            New-Item -ItemType Directory -Path $source,$caller | Out-Null
            for ($index=0; $index -lt $names.Count; $index++) {
                $file = Join-Path $source $names[$index]
                New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file)) -Force | Out-Null
                [IO.File]::WriteAllBytes($file,[byte[]](65,66,(67+$index)))
                Set-SourceTimes $file 2020
            }
            New-Item -ItemType Directory -Path (Join-Path $caller 'sub') | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $caller 'wrong.txt'),[byte[]](1,2,3,4))
            [IO.File]::WriteAllBytes((Join-Path $caller 'sub/wrong.txt'),[byte[]](5,6,7))
            $archive = Join-Path $root 'result.lzh'
            $pattern = if ($variant -eq 'nested') { 'sub\*.txt' } elseif ($variant -eq 'absolute') { "$source\*.txt" } else { '*.txt' }
            $flags = if ($variant -in 'nested','recursive') { '-x1' } else { '-x0' }
            if ($variant -eq 'recursive') { $flags += ' -r1' }
            if ($command -ne 'a') {
                # 更新元は原版の h0 で作り、既知の一部 h2 更新 CRC 差異をこの検索試験と分離する。
                $seed = "a -h0 -gm1 -y1 -c1 $flags `"$archive`" `"$source\`" `"$pattern`""
                Push-Location -LiteralPath $source
                try { $rows = @(& $TestProgram --registry '' --base-command-probe $Oracle $seed $locale $utf8 $api) }
                finally { Pop-Location }
                if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw "更新元の作成に失敗しました: $label / $side" }
            }
            foreach ($name in $names) { Set-SourceTimes (Join-Path $source $name) 2024 }
            $base = if ($variant -eq 'relative') { '..\source\' } else { "$source\" }
            $operands = "`"$base`" `"$pattern`""
            $working = $caller
            if ($variant -eq 'control') { $operands = "`"$pattern`""; $working = $source }
            if ($variant -eq 'response') {
                $response = Join-Path $root 'files.txt'
                [IO.File]::WriteAllBytes($response,[Text.Encoding]::ASCII.GetBytes($operands))
                $operands = "@`"$response`""
            }
            $line = "$command -h2 -n1 -gm1 -y1 -c1 $flags `"$archive`" $operands"
            Push-Location -LiteralPath $working
            try {
                $rows = @(& $TestProgram --registry '' --base-command-probe $dll $line $locale $utf8 $api)
                $probeExit = $LASTEXITCODE
            } finally { Pop-Location }
            if ($probeExit -ne 0 -or $rows -notcontains 'result=0' -or
                $rows -notcontains 'directory-preserved=1' -or -not (Test-Path -LiteralPath $archive)) {
                throw "圧縮基準ディレクトリ試験に失敗しました: $label / $side`n$($rows -join "`n")"
            }
            $rows = @($rows | ForEach-Object {
                $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
            })
            $metadata = @(& $TestProgram --registry '' --attribute-probe $Oracle $archive)
            if ($LASTEXITCODE -ne 0) { throw "圧縮結果を原版で読み取れません: $label / $side" }
            if ($metadata -match 'name="[^"]*wrong\.txt') { throw "呼び出し元のファイルが混入しました: $label / $side" }
            $rows += $metadata
            foreach ($name in $names) { $rows += "source=$name,exists=$(Test-Path -LiteralPath (Join-Path $source $name))" }
            $results += ,$rows
        }
        $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
        if ($difference.Count -ne 0) {
            $details = $difference | Select-Object -First 8 | Out-String -Width 1500
            throw "圧縮の選択結果が不一致です: $label`n$details"
        }
        $count++
    }
   }
  }
 }
 Write-Host "Compression base: $variant, $count comparisons passed"
}
Write-Host "Compression base: $count A/W/legacy add/update/freshen/move, relative/absolute/recursive/response cases and working-directory restoration passed"
