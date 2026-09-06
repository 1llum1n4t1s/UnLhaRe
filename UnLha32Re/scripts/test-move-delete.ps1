[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$NewArchive
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Move deletion workspace: $Workspace"
function Set-DeleteFixture([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $when = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$when)
    [IO.File]::SetLastAccessTimeUtc($Path,$when)
    [IO.File]::SetLastWriteTimeUtc($Path,$when)
}
$seed = Join-Path $Workspace 'seed'
New-Item -ItemType Directory -Path $seed | Out-Null
foreach ($name in 'a.txt','m.txt','z.txt') { Set-DeleteFixture (Join-Path $seed $name) "seed-$name-value" 2020 }
$seedArchive = Join-Path $Workspace 'seed.lzh'
$rows = @(& $TestProgram --registry '' --command-probe-a $Oracle "a -h0 -n1 -gm1 -y1 `"$seedArchive`" `"$seed\`" a.txt m.txt z.txt" A)
if ($LASTEXITCODE -ne 0 -or $rows -notcontains 'result=0') { throw '削除失敗試験の元書庫を作成できません。' }
$cases = @(
    @{ Name='first-locked'; Failure='a.txt'; Order=@('a.txt','m.txt','z.txt'); Remain=@('a.txt','m.txt','z.txt') },
    @{ Name='middle-locked'; Failure='m.txt'; Order=@('a.txt','m.txt','z.txt'); Remain=@('m.txt','z.txt') },
    @{ Name='last-locked'; Failure='z.txt'; Order=@('a.txt','m.txt','z.txt'); Remain=@('z.txt') },
    @{ Name='reverse-middle'; Failure='m.txt'; Order=@('z.txt','m.txt','a.txt'); Remain=@('a.txt','m.txt') },
    @{ Name='middle-readonly'; Failure='m.txt'; Order=@('a.txt','m.txt','z.txt'); Remain=@('m.txt','z.txt'); ReadOnly=$true },
    @{ Name='success'; Failure=''; Order=@('z.txt','m.txt','a.txt'); Remain=@() }
)
$count = 0
$layouts = if ($NewArchive) { @('none') } else { @('none','a32','w32','a64','w64') }
foreach ($case in $cases) { foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) { foreach ($api in 'legacy','A','W') { foreach ($layout in $layouts) {
    $label = "$($case.Name)/$locale/$utf8/$api/$layout"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace ("case-{0:D3}-$side" -f $count)
        $inputDirectory = Join-Path $root 'input'
        New-Item -ItemType Directory -Path $inputDirectory | Out-Null
        foreach ($name in 'a.txt','m.txt','z.txt') { Set-DeleteFixture (Join-Path $inputDirectory $name) "input-$name-value" 2024 }
        $archive = Join-Path $root 'result.lzh'
        if (-not $NewArchive) { Copy-Item -LiteralPath $seedArchive -Destination $archive }
        $holder = $null
        if ($case.Failure) {
            $failure = Join-Path $inputDirectory $case.Failure
            if ($case.ReadOnly) { [IO.File]::SetAttributes($failure,[IO.FileAttributes]::ReadOnly -bor [IO.FileAttributes]::Archive) }
            else { $holder = [IO.File]::Open($failure,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Read) }
        }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $command = "m -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"$($inputDirectory.Replace('\','/'))/`" $($case.Order -join ' ')"
        try {
            $rows = @(& $TestProgram --registry '' --base-command-probe $dll $command $locale $utf8 $api $layout 0)
            if ($LASTEXITCODE -ne 0) { throw "削除失敗の試験が異常終了しました: $label/$side" }
        } finally { if ($holder) { $holder.Dispose() } }
        $expectedResult = if ($case.Failure) { 32828 } else { 0 }
        $expectedSystem = if ($case.ReadOnly) { 5 } elseif ($case.Failure) { 32 } else { 18 }
        if ($rows -notcontains "result=$expectedResult" -or $rows -notcontains "compat-error=$expectedResult" -or $rows -notcontains "compat-system-error=$expectedSystem") {
            throw "削除失敗の結果が違います: $label/$side`n$($rows -join "`n")"
        }
        $remaining = @(Get-ChildItem -LiteralPath $inputDirectory -File | Sort-Object Name | Select-Object -ExpandProperty Name)
        if (($remaining -join ',') -cne ($case.Remain -join ',')) { throw "削除停止後の入力が違います: $label/$side, remaining=$($remaining -join ',')" }
        foreach ($name in $remaining) {
            if ([IO.File]::ReadAllText((Join-Path $inputDirectory $name)) -cne "input-$name-value") { throw "残った入力が変わりました: $label/$side/$name" }
        }
        foreach ($name in 'a.txt','m.txt','z.txt') {
            $data = @(& $TestProgram --registry '' --command-probe-a $Oracle "p -+ `"$archive`" $name" A)
            if ($LASTEXITCODE -ne 0 -or $data -notcontains 'result=0' -or $data -notcontains "output=`"input-$name-value`"") {
                throw "削除失敗後の圧縮内容が違います: $label/$side/$name"
            }
        }
        $results += ,@($rows | ForEach-Object { $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>') })
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) { throw "削除失敗のログ・通知・エラーが一致しません: $label`n$($difference | Select-Object -First 10 | Out-String -Width 2000)" }
    $count++
} } } } }
$operation = if ($NewArchive) { 'new' } else { 'existing' }
Write-Host "Move deletion: $count $operation first/middle/last/reverse/readonly/success error, source-order, retained-content, and complete-archive comparisons passed"
