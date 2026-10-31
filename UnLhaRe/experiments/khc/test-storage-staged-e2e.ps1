# 実装前の失敗条件（実Windows E2E。製品stateを書き換えない）:
# 1. 実験子が失敗/timeout/background子を残したままでも、停止確認前に保全準備へ進まない。
# 2. ZIP内の内容/サイズ/SHAが作業ツリーと一致しないとPrunlet対象を出さない。
# 3. delete preview/receiptのpath・kind・status・operationId不一致でpurge/finalizeを拒否する。
# 4. purge preview/applyのoperationId・status・bytes不一致ではcomplete.jsonを作らない。
# 5. Prunletのいずれかの段階が失敗したとき、別削除経路を使わずpendingを保持する。
# 6. 未完了runが残る間は次のrun/Cargoを拒否し、finalize後だけ解除する。
# 7. inventory-boundが登録時上限より多い場合は、child起動前に拒否しworkを作らない。
# このE2Eは小さな実験用fixtureを作り、外部tool callでのPrunlet処理後にfinalizeする。
#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('success','inventory-bound','nonzero','timeout','background')][string]$FixtureMode='success',
    [Parameter(Mandatory)][string]$WorkDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
if ($FixtureMode -eq 'inventory-bound') {
    $runRecord = Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
    if ($runRecord.max_entries -lt 96) { throw 'inventory-bound fixture requires a 96-entry registration before creating output.' }
}

$null = New-Item -ItemType Directory -Path $WorkDirectory
$null = New-Item -ItemType Directory -Path (Join-Path $WorkDirectory 'nested/empty') -Force
[IO.File]::WriteAllBytes((Join-Path $WorkDirectory 'sample.bin'),[byte[]](0,1,2,127,128,254,255))
[IO.File]::WriteAllBytes((Join-Path $WorkDirectory 'nested/fixture.bin'),[byte[]](255,254,128,127,2,1,0))

switch ($FixtureMode) {
    'success' { 'KHC staged-storage E2E fixture ready.' }
    'inventory-bound' {
        for ($index = 0; $index -lt 72; $index++) {
            $name = 'inventory-{0:D2}.bin' -f $index
            [IO.File]::WriteAllBytes((Join-Path $WorkDirectory $name),[byte[]]@($index -band 255))
        }
        'KHC registered inventory E2E PASS: 72 generated files plus directory entries.'
    }
    'nonzero' { throw 'E2E expected child failure after writing its fixture.' }
    'timeout' { [Threading.Thread]::Sleep(60000) }
    'background' {
        $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        $info.ArgumentList.Add('-NoProfile'); $info.ArgumentList.Add('-Command'); $info.ArgumentList.Add('[Threading.Thread]::Sleep(60000)')
        $child = [Diagnostics.Process]::Start($info)
        [IO.File]::WriteAllText((Join-Path $WorkDirectory 'background-pid.txt'),[string]$child.Id)
        $child.Dispose()
    }
}
