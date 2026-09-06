[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Seed,
    [Parameter(Mandatory)][string]$Workspace
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Seed = (Resolve-Path -LiteralPath $Seed).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression sharing recovery workspace: $Workspace"
$count = 0
foreach ($layout in 'a32','w32','a64','w64') { foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') { foreach ($variant in 'strict-reset','exclusive-recovery') {
    $label = "$layout/$locale/$utf8/$api/$variant"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        # 出力長も比較するため、原版と候補のディレクトリ名は同じ文字数にする。
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        $inputDirectory = Join-Path $root 'input'
        New-Item -ItemType Directory -Path $inputDirectory | Out-Null
        foreach ($name in 'a.txt','z.txt') {
            $path = Join-Path $inputDirectory $name
            [IO.File]::WriteAllText($path,"new-$name-updated-value",[Text.UTF8Encoding]::new($false))
            $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
            [IO.File]::SetCreationTimeUtc($path,$time)
            [IO.File]::SetLastWriteTimeUtc($path,$time)
            [IO.File]::SetLastAccessTimeUtc($path,$time)
        }
        $archive = Join-Path $root 'result.lzh'
        Copy-Item -LiteralPath $Seed -Destination $archive
        $base = "f -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$($inputDirectory.Replace('\','/'))/`""
        $first = if ($variant -eq 'strict-reset') { "$base -jso1 a.txt z.txt" } else { "$base a.txt z.txt" }
        $second = if ($variant -eq 'strict-reset') { "$base a.txt z.txt" } else { "$base z.txt" }
        $share = if ($variant -eq 'strict-reset') { [IO.FileShare]::Read } else { [IO.FileShare]::None }
        $holder = [IO.File]::Open((Join-Path $inputDirectory 'a.txt'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,$share)
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        try {
            $rows = @(& $TestProgram --registry '' --enum-sequence-probe $dll $layout $locale $utf8 $api $first "@count:$archive" $second "@check:$archive")
            if ($LASTEXITCODE -ne 0) { throw "共有失敗後の連続呼び出しが異常終了しました: $label/$side" }
        } finally { $holder.Dispose() }
        $commandResults = @($rows | Where-Object { $_ -match '^result=' })
        if (($commandResults -join ',') -cne 'result=32816,result=0' -or $rows -notcontains 'count=2' -or $rows -notcontains 'check=1') {
            throw "共有失敗後の再利用に失敗しました: $label/$side`n$($rows -join "`n")"
        }
        $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "共有失敗後の状態・出力が一致しません: $label`n$($difference | Select-Object -First 12 | Out-String -Width 2000)" }
    $count++
} } } } }
Write-Host "Compression sharing recovery: $count strict-switch reset, failure/count/update/check, and retained-enum-state sequences passed"
