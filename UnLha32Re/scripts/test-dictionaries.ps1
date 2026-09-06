[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$ReportDifferences
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Invoke-DictionaryTest([string[]]$Values) {
    $output = @(& $TestProgram --registry '' @Values)
    if ($LASTEXITCODE -ne 0) {
        throw "辞書試験失敗: $($Values -join ' ')`n$($output -join "`n")"
    }
    return $output
}

$cases = @()
foreach ($bits in 12..19) {
    $cases += @{ Options = "-jmm$bits"; Block = 3 * [math]::Pow(2, $bits - 2); Api = 'W' }
}
foreach ($bits in 17..19) {
    foreach ($api in 'A', 'memoryA', 'memoryW') {
        $cases += @{ Options = "-jmm$bits"; Block = 3 * [math]::Pow(2, $bits - 2); Api = $api }
    }
    $cases += @{ Options = "-jmm$bits"; Block = 0; Api = 'W' }
}
foreach ($options in '-jmm19 -jm2', '-jm2 -jmm19', '-jmm17 -jmm16',
        '-jmm19 -jmm11', '-jmm20', '-jmm17m18', '-jmm19 -jmm12') {
    $cases += @{ Options = $options; Block = 1024; Api = 'W' }
}
foreach ($bits in 12..19) {
    $cases += @{ Options = "-jmm$bits -e0"; Block = 3 * [math]::Pow(2, $bits - 2); Api = 'W' }
}
$cases += @{ Options = '-jmm19'; Block = 393216; Api = 'W'; Unicode = $true }
$cases += @{ Options = '-jmm19'; Block = 393216; Api = 'memoryW'; Unicode = $true }
foreach ($api in 'W', 'A', 'memoryA', 'memoryW') {
    foreach ($options in '-jm2', '-jmm19') {
        $cases += @{ Options = $options; Block = 1024; Api = $api; Unicode = $true; Member = '資料😀.bin' }
    }
}
foreach ($api in 'A', 'memoryA') {
    $cases += @{ Options = '-jmm19'; Block = 393216; Api = $api; Unicode = $true }
}
foreach ($api in 'memoryA', 'memoryW') {
    foreach ($options in '-jm2', '-jmm19') {
        $cases += @{ Options = $options; Block = 1024; Api = $api; Unicode = $true;
                     Member = '資料😀.bin'; UnicodeTemp = $true }
    }
}

$crossChecks = 0
$failures = 0
for ($index = 0; $index -lt $cases.Count; $index++) {
    $savedTemp = $env:TEMP
    $savedTmp = $env:TMP
    try {
        $case = $cases[$index]
        $member = if ($case.Member) { $case.Member } else { 'payload.bin' }
        if ($case.UnicodeTemp) {
            $tempRoot = Join-Path $Workspace "temp-$index-一時😀"
            New-Item -ItemType Directory -Path $tempRoot | Out-Null
            $env:TEMP = $tempRoot
            $env:TMP = $tempRoot
        }
        $methods = @()
        foreach ($producer in @(@{ Name = 'original'; Dll = $Oracle }, @{ Name = 'candidate'; Dll = $Candidate })) {
            $name = "case-$index-$($producer.Name)"
            if ($case.Unicode) { $name += '-資料-😀' }
            $root = Join-Path $Workspace $name
            $output = @(Invoke-DictionaryTest @('--create-dictionary-fixture', $producer.Dll, $root,
                $case.Options, [string]$case.Block, $case.Api, $member))
            $methods += @($output | Where-Object { $_ -like 'create.method=*' })
            foreach ($consumer in $Oracle, $Candidate) {
                $null = Invoke-DictionaryTest @('--verify-dictionary-fixture', $consumer, $root, $member)
                $crossChecks++
            }
        }
        if ($methods.Count -ne 2 -or $methods[0] -ne $methods[1]) {
            throw "圧縮方式が一致しません: $($case.Options) / $($case.Api) / $($methods -join ', ')"
        }
        # 圧縮器の生成バイト列・圧縮サイズの一致ではなく、方式選択と相互展開を保証する。
        if ($case.Block -gt 0 -and $case.Options -match '^-jmm(17|18|19)$' -and $methods[0] -ne 'create.method=-lhx-') {
            throw '大辞書試験が無圧縮へ退避しており、広い参照位置を検証できません。'
        }
        if ($case.UnicodeTemp -and @(Get-ChildItem -LiteralPath $tempRoot -Force).Count -ne 0) {
            throw 'Unicode 一時ディレクトリに作業ファイルが残っています。'
        }
    } catch {
        if (!$ReportDifferences) { throw }
        Write-Host "Dictionary case $index failed: $_"
        $failures++
    } finally {
        $env:TEMP = $savedTemp
        $env:TMP = $savedTmp
    }
}

foreach ($producer in @(@{ Name = 'original'; Dll = $Oracle }, @{ Name = 'candidate'; Dll = $Candidate })) {
    $root = Join-Path $Workspace ('state-' + $producer.Name)
    $null = Invoke-DictionaryTest @('--dictionary-state', $producer.Dll, $root)
    foreach ($step in 0..7) {
        foreach ($consumer in $Oracle, $Candidate) {
            $null = Invoke-DictionaryTest @('--verify-dictionary-fixture', $consumer, (Join-Path $root "step-$step"))
            $crossChecks++
        }
    }
}
Write-Host "Dictionaries: $($cases.Count) method/API/Unicode cases, $crossChecks successful cross-extractions, 2 retained-DLL state sequences, $failures failed cases"
if ($failures -ne 0) { throw "辞書比較試験の $failures 件が不一致です。" }
