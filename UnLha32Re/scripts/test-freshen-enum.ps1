[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [switch]$AttributeAudit
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
# 既存の EOF 待機・タイムアウト・個別ログ保存を同じ定義から利用する。
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw '列挙プローブのヘルパーを解析できません。' }
$helper = $helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'}, $true)
if (!$helper) { throw '列挙プローブのヘルパーがありません。' }
. ([scriptblock]::Create($helper.Extent.Text))
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Freshen enum workspace: $Workspace"
function Set-FreshenFixture([string]$Path, [string]$Value, [int]$Year) {
    $when = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
    [IO.File]::SetCreationTimeUtc($Path,$when)
    [IO.File]::SetLastWriteTimeUtc($Path,$when)
    [IO.File]::SetLastAccessTimeUtc($Path,$when)
}
$count = 0
function Test-OriginalMoveAccessDenied([string[]]$Rows) {
    return $Rows -contains 'result=32792' -and $Rows -contains 'compat-system-error=5' -and
        @($Rows -like '*on execute_cmd (MoveFile)*').Count -ne 0
}
foreach ($locale in 1033,1041) { foreach ($utf8 in 0,1) {
 foreach ($api in 'legacy','A','W') { foreach ($layout in 'a32','w32','a64','w64') {
    $label = "$locale-$utf8-$api-$layout"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
      for ($commandAttempt = 0; $commandAttempt -lt 6; $commandAttempt++) {
        $root = Join-Path $Workspace "$label-$side-attempt$commandAttempt"
        $caller = Join-Path $root 'caller'
        $search = Join-Path $caller '..source'
        $seed = Join-Path $root 'seed'
        New-Item -ItemType Directory -Path $search, $seed, (Join-Path $root 'source') | Out-Null
        Set-FreshenFixture (Join-Path $seed 'literal.txt') 'old-value' 2020
        Set-FreshenFixture (Join-Path $search 'literal.txt') 'search-value' 2024
        $replacement = Join-Path $root 'replacement.txt'
        Set-FreshenFixture $replacement 'callback-redirected-value' 2024
        $archive = Join-Path $root 'result.lzh'
        $rows = @(Invoke-EnumProbe (Join-Path $root 'seed') @('--command-probe',$Oracle,"a -h0 -n1 -gm1 -y1 `"$archive`" `"$seed\`" literal.txt"))
        if ($rows -notcontains 'result=0') { throw "f 列挙試験の元書庫を作れません: $label/$side" }
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        Push-Location $caller
        try {
            # 検索名 caller/..source/literal.txt は存在するが、通常の読込名 source/literal.txt は存在しない。
            $command = "f -h2 -n1 -gm1 -y1 -c1 `"$archive`" `"../source/`" literal.txt"
            $rows = @(Invoke-EnumProbe (Join-Path $root 'command') @('--command-enum-probe',$dll,$command,$layout,'1',$replacement,"$locale","$utf8",$api) $caller)
            # 原版の MoveFile エラー5は発生原因未確定。初期書庫・入力・パス長を
            # そろえた別領域で限定再試行し、失敗した試行の入力とログを保持する。
            if ($side -eq 'oracle' -and (Test-OriginalMoveAccessDenied $rows) -and $commandAttempt -lt 5) {
                Write-Host "Freshen enum: original MoveFile access denied; retrying in a fresh directory ($label/$commandAttempt)"
                Start-Sleep -Milliseconds 100
                continue
            }
            if ($rows -notcontains 'result=0' -or $rows -notcontains 'enum.count=1') {
                throw "f の列挙による欠落入力の差し替えが失敗しました: $label/$side`n$($rows -join "`n")"
            }
        } finally { Pop-Location }
        $attributeProbe = if ($AttributeAudit) { '--attribute-probe-audit' } else { '--attribute-probe' }
        $metadata = @(Invoke-EnumProbe (Join-Path $root 'attributes') @($attributeProbe,$Oracle,$archive))
        if ($metadata.Count -ne 6) { throw "差し替え後の属性出力が不足または過剰です: $label/$side" }
        $rows += $metadata
        $data = @(Invoke-EnumProbe (Join-Path $root 'data') @('--command-probe-a',$Oracle,"p -+ `"$archive`"",'A'))
        if ($data -notcontains 'result=0' -or
            @($data | Where-Object { $_ -like 'output="callback-redirected-value*' }).Count -ne 1) {
            throw "差し替え先の内容が格納されていません: $label/$side"
        }
        $rows += @($data | ForEach-Object { "data.$_" })
        $results += ,@($rows | ForEach-Object {
            $_.Replace($root.Replace('\','/'),'<ROOT>').Replace($root.Replace('\','\\'),'<ROOT>')
        })
        break
      }
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) {
        throw "f の欠落入力の列挙・差し替え結果が不一致です: $label`n$($difference | Select-Object -First 10 | Out-String -Width 2000)"
    }
    $count++
 } }
} }
Write-Host "Freshen enum: $count A/W/legacy 32/64 missing-source callback redirection, metadata, errors, and extracted-data comparisons passed"
