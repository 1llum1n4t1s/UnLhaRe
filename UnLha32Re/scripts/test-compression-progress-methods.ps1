[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Methods = @('jm0','jm1','jm2','jm3','jm4','jm5','jm7','jm8','jmm12','jmm17','jmm19')
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Compression progress methods workspace: $Workspace"
$inputs = [ordered]@{ repeat=('abcdefghijklmnopqrstuvwxyz' * 200); small='unique small data'; empty='' }
$count = 0
foreach ($method in $Methods) { foreach ($inputName in $inputs.Keys) { foreach ($api in 'legacy','A','W') {
    $label = "$method/$inputName/$api"
    $results = @()
    $bodies = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        New-Item -ItemType Directory -Path $root | Out-Null
        $source = Join-Path $root 'a.txt'
        [IO.File]::WriteAllText($source,$inputs[$inputName],[Text.UTF8Encoding]::new($false))
        $time = [datetime]::new(2024,1,2,3,4,6,[DateTimeKind]::Utc)
        [IO.File]::SetCreationTimeUtc($source,$time)
        [IO.File]::SetLastWriteTimeUtc($source,$time)
        [IO.File]::SetLastAccessTimeUtc($source,$time)
        $archive = Join-Path $root 'result.lzh'
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $command = "a -+ -$method -h0 -n1 -gm1 -y1 `"$archive`" `"$($root.Replace('\','/'))/`" a.txt"
        $rows = @(& $TestProgram --registry '' --base-command-probe $dll $command 1041 1 $api none 1)
        if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0' -or $rows -notcontains 'compat-error=0') { throw "進捗方式の試験に失敗しました: $label/$side`n$($rows -join "`n")" }
        [IO.File]::WriteAllLines((Join-Path $root 'command.txt'),$rows)
        $bytes = [IO.File]::ReadAllBytes($archive)
        $storedMethod = [Text.Encoding]::ASCII.GetString($bytes,2,5)
        $headerSize = [int]$bytes[0] + 2
        $packedSize = [BitConverter]::ToUInt32($bytes,7)
        if ($bytes[20] -ne 0 -or $headerSize + $packedSize -ge $bytes.Length) { throw "予期しない書庫ヘッダーです: $label/$side" }
        $begins = @($rows | Where-Object { $_ -match '^progress.entry=.*?,state=0,' })
        $finishes = @($rows | Where-Object { $_ -match '^progress.entry=.*?,state=6,' })
        if ($begins.Count -ne 1 -or $finishes.Count -ne 1 -or $begins[0] -notmatch ',mode="-lh5-",' -or
            $finishes[0] -notmatch (',mode="' + [regex]::Escape($storedMethod) + '",')) {
            throw "BEGIN/FINISH の方式表示が違います: $label/$side`n$(($begins + $finishes) -join "`n")"
        }
        # アクセス日時は原版同士でも実行時刻により変動する。生値は command.txt に保持する。
        # DIRECTORY の不定値、通知回数、COPY の一時パス等もこの比較の対象外。
        $results += ,@(($begins + $finishes) | ForEach-Object {
            $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') -replace ',access=\d+',',access=volatile'
        })
        $bodies += "$storedMethod/$packedSize/" + [Convert]::ToBase64String($bytes,$headerSize,$packedSize)
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "単一入力の BEGIN/FINISH 数値・方式が一致しません: $label`n$($difference | Select-Object -First 4 | Out-String -Width 2000)" }
    if ($bodies[0] -cne $bodies[1]) { throw "通知方式の試験で圧縮本体が一致しません: $label" }
    $count++
} }
Write-Host "Compression progress methods: $method, $count comparisons passed"
}
Write-Host "Compression progress methods: $count single-input BEGIN/FINISH fields (volatile access time excluded) and actual compressed-body comparisons passed"
