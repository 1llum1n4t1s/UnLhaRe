[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet('ascii','japanese')][string[]]$Families = @('ascii','japanese'),
    [ValidateSet(0,2)][int[]]$Methods = @(0,2),
    [ValidateSet(2,3)][int[]]$HeaderLevels = @(2,3),
    [ValidateSet('good','first','middle','last','all')][string[]]$Variants = @('good','first','middle','last','all'),
    [ValidateSet('l','v','t','p')][string[]]$Commands = @('l','v','t','p'),
    [ValidateSet(0,1,2)][int[]]$NameModes = @(0,1,2),
    [string[]]$ConfigurationNames = @('plain','a32','w32','a64','w64')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'level3-header-fixture.ps1')
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Header CRC commands workspace: $Workspace"
$configs = @(
    @{ Name='plain'; Api='legacy'; Enum='none'; Locale=1041; Utf8=0 },
    @{ Name='a32'; Api='A'; Enum='a32'; Locale=1041; Utf8=1 },
    @{ Name='w32'; Api='W'; Enum='w32'; Locale=1041; Utf8=0 },
    @{ Name='a64'; Api='legacy'; Enum='a64'; Locale=1033; Utf8=1 },
    @{ Name='w64'; Api='W'; Enum='w64'; Locale=1041; Utf8=1 }
)
foreach ($name in $ConfigurationNames) {
    if ($name -notin $configs.Name) { throw "未知の通知構成です: $name" }
}
$damagedIndexes = @{ good=@(); first=@(0); middle=@(1); last=@(2); all=@(0,1,2) }
$expectedResults = @{ good=0; first=0; middle=32790; last=32790; all=32795 }
$expectedMembers = @{ good=3; first=2; middle=1; last=2; all=0 }
$count = 0
$totalRows = 0
foreach ($family in $Families) { foreach ($method in $Methods) {
    $root = Join-Path $Workspace "$family-jm$method"
    New-Item -ItemType Directory -Path $root | Out-Null
    $names = if ($family -eq 'ascii') { @('a.txt','m.txt','z.txt') } else { @('a-資料.txt','m-日本語.txt','z-空.txt') }
    $payloads = @('first payload',('middle payload' * 20),'')
    $stamp = [datetime]::new(2020,1,2,3,4,6,[DateTimeKind]::Utc)
    for ($index = 0; $index -lt 3; $index++) {
        $path = Join-Path $root $names[$index]
        [IO.File]::WriteAllText($path,$payloads[$index],[Text.UTF8Encoding]::new($false))
        [IO.File]::SetCreationTimeUtc($path,$stamp)
        [IO.File]::SetLastWriteTimeUtc($path,$stamp)
        [IO.File]::SetLastAccessTimeUtc($path,$stamp)
    }
    $seed = Join-Path $root 'seed.lzh'
    $selection = ($names | ForEach-Object { "`"$_`"" }) -join ' '
    $created = @(& $TestProgram --registry '' --base-command-probe $Oracle "a -+ -h2 -jm$method -gm1 -y1 `"$seed`" `"$root\`" $selection" 1041 1 W none 0)
    if ($LASTEXITCODE -ne 0 -or $created -notcontains 'result=0') { throw "元書庫を作成できません: $family/jm$method" }
    $bytes = [IO.File]::ReadAllBytes($seed)
    $crcPositions = @()
    $position = 0
    for ($index = 0; $index -lt 3; $index++) {
        if ($position + 26 -gt $bytes.Length -or $bytes[$position + 20] -ne 2) { throw '予期しない元ヘッダーです' }
        $headerSize = [BitConverter]::ToUInt16($bytes,$position)
        $packed = [BitConverter]::ToUInt32($bytes,$position + 7)
        if ($method -eq 2 -and $index -eq 1 -and [Text.Encoding]::ASCII.GetString($bytes,$position + 2,5) -cne '-lh5-') {
            throw '圧縮済み本文の対照が作成されていません'
        }
        $extension = $position + 26
        $extensionSize = [BitConverter]::ToUInt16($bytes,$position + 24)
        $found = $false
        while ($extensionSize -gt 0) {
            if ($extensionSize -lt 3 -or $extension + $extensionSize -gt $position + $headerSize) { throw '不正な拡張ヘッダー位置です' }
            if ($bytes[$extension] -eq 0) {
                if ($extensionSize -lt 5) { throw 'CRC 領域が不足しています' }
                $crcPositions += $extension + 1
                $found = $true
                break
            }
            $next = $extension + $extensionSize - 2
            $extensionSize = [BitConverter]::ToUInt16($bytes,$next)
            $extension = $next + 2
        }
        if (-not $found) { throw 'CRC 拡張ヘッダーがありません' }
        $position += $headerSize + $packed
    }
    foreach ($level in $HeaderLevels) {
      $caseRoot = $root
      $levelBytes = $bytes
      $levelCrcPositions = $crcPositions
      if ($level -eq 3) {
        $converted = ConvertTo-Level3HeaderFixture $bytes
        $levelBytes = $converted.Bytes
        $levelCrcPositions = $converted.CrcPositions
        if ($levelCrcPositions.Count -ne 3) { throw 'Level-3 の対照項目が不足しています' }
        $caseRoot = Join-Path $root 'level3'
        New-Item -ItemType Directory -Path $caseRoot | Out-Null
      }
      foreach ($variant in $Variants) {
        $damaged = [byte[]]$levelBytes.Clone()
        foreach ($index in $damagedIndexes[$variant]) { $damaged[$levelCrcPositions[$index]] = $damaged[$levelCrcPositions[$index]] -bxor 1 }
        $archive = Join-Path $caseRoot "$variant.lzh"
        [IO.File]::WriteAllBytes($archive,$damaged)
        [IO.File]::SetLastWriteTimeUtc($archive,$stamp)
        $beforeHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        foreach ($commandName in $Commands) { foreach ($nameMode in $NameModes) {
            foreach ($config in $configs | Where-Object { $_.Name -in $ConfigurationNames }) {
                $label = "$family/jm$method/h$level/$variant/$commandName/n$nameMode/$($config.Name)"
                $snapshots = @()
                foreach ($side in 'oracle','reimpl') {
                    $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
                    $rows = @(& $TestProgram --registry '' --base-command-probe $dll "$commandName -+ -n$nameMode -gm1 `"$archive`"" $config.Locale $config.Utf8 $config.Api $config.Enum 1)
                    if ($LASTEXITCODE -ne 0) { throw "読取プローブが異常終了しました: $label/$side" }
                    [IO.File]::WriteAllLines((Join-Path $caseRoot ('case-{0:D4}-{1}.txt' -f $count,$side)),$rows)
                    $expected = $expectedResults[$variant]
                    if ($rows -notcontains "result=$expected" -or $rows -notcontains "compat-error=$expected") { throw "戻り値・DLL エラーが不正です: $label/$side`n$($rows -join "`n")" }
                    $expectedCount = if ($config.Enum -eq 'none') { 0 } else { $expectedMembers[$variant] }
                    if ($rows -notcontains "enum.count=$expectedCount") { throw "不良ヘッダーを列挙したか、成功項目が不足しています: $label/$side" }
                    if ($expected -ne 0 -and @($rows -match '^progress.entry=.*?,state=2,').Count) { throw "読取失敗後に終了通知を送りました: $label/$side" }
                    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $beforeHash -or
                        (Get-Item -LiteralPath $archive).LastWriteTimeUtc -ne $stamp) { throw "読み取りによって書庫が変更されました: $label/$side" }
                    $snapshots += ,$rows
                }
                $difference = @(Compare-Object $snapshots[0] $snapshots[1] -SyncWindow 0)
                if ($difference.Count) { throw "CRC 読み取りのログ・通知・状態が一致しません: $label`n$($difference | Select-Object -First 8 | Out-String -Width 2400)" }
                $totalRows += $snapshots[0].Count
                $count++
            }
        } }
        Write-Host "Header CRC commands: $family/jm$method/h$level/$variant, $count comparisons passed"
      }
    }
} }
Write-Host "Header CRC commands: $count comparisons, $totalRows exact output/enum/progress/state snapshots compatible; archive content and write time unchanged"
