[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [ValidateSet(0,1,2)][int[]]$HeaderLevels = @(0,1,2),
    [ValidateSet('ascii','wide')][string[]]$SourceNames = @('ascii','wide'),
    [string[]]$CaseNames = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
$cases = @(
    @{ Name='add-exclude-wildcard'; Command='a'; Pattern='*'; Options='-jx*.txt'; Members=@('keep.bin') },
    @{ Name='add-exclude-explicit'; Command='a'; Pattern='skip.txt keep.bin'; Options='-jx*.txt'; Members=@('keep.bin') },
    # 原版の a/u/m は既存項目の更新に -jx を適用せず、新規項目だけを除外する。
    @{ Name='add-existing-exclude'; Command='a'; Pattern='*'; Options='-jx*.txt'; Members=@('keep.bin','skip.txt'); Existing=$true; MixedExcluded=$true },
    @{ Name='update-exclude'; Command='u'; Pattern='*'; Options='-jx*.txt'; Members=@('keep.bin','skip.txt'); Existing=$true; MixedExcluded=$true },
    @{ Name='move-existing-exclude'; Command='m'; Pattern='*'; Options='-jx*.txt'; Members=@('keep.bin','skip.txt'); Existing=$true; MixedExcluded=$true },
    @{ Name='freshen-all'; Command='f'; Pattern='*'; Options=''; Members=@('keep.bin','skip.txt'); Existing=$true },
    @{ Name='freshen-exclude'; Command='f'; Pattern='*'; Options='-jx*.txt'; Members=@('keep.bin','skip.txt'); Existing=$true; OldSkip=$true; MixedExcluded=$true },
    @{ Name='callback-rename'; Command='a'; Pattern='skip.txt'; Options=''; Members=@('renamed.txt'); Replacement='@file:renamed.txt' },
    @{ Name='callback-a32'; Command='m'; Pattern='skip.txt'; Options=''; Members=@('skip.txt'); Layout='a32' },
    @{ Name='callback-a64'; Command='m'; Pattern='skip.txt'; Options=''; Members=@('skip.txt'); Layout='a64' }
)
foreach ($name in $CaseNames) { if ($name -cnotin $cases.Name) { throw "Unknown case: $name" } }
if ($CaseNames.Count) { $cases = @($cases | Where-Object Name -cin $CaseNames) }
$parseErrors = $null
$helperAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'test-enum-state.ps1'),[ref]$null,[ref]$parseErrors)
$helper = $helperAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EnumProbe'},$true)
if ($parseErrors.Count -or !$helper) { throw 'Cannot load bounded probe helper' }
. ([scriptblock]::Create($helper.Extent.Text))
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @($TestProgram,$Oracle,$Candidate,$runner,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{ Path=$_; SHA256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }
})
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Workspace 'binaries.json') -Encoding utf8
function Set-Input([string]$Path,[string]$Value,[int]$Year) {
    [IO.File]::WriteAllText($Path,$Value,[Text.UTF8Encoding]::new($false))
    $time = [datetime]::new($Year,1,2,3,4,6,[DateTimeKind]::Utc)
    [IO.File]::SetCreationTimeUtc($Path,$time)
    [IO.File]::SetLastWriteTimeUtc($Path,$time)
    [IO.File]::SetLastAccessTimeUtc($Path,$time)
}
function Normalize-Result([string[]]$Rows,[string]$Root) {
    # 新規書庫の未初期化 enum 数値はこの試験の対象外。命令の全文・結果・エラーを比較する。
    @($Rows | Where-Object { $_ -match '^(result|output|win32-error|compat-error|compat-system-error)=' } | ForEach-Object {
        $_.Replace($Root.Replace('\','/'),'<ROOT>').Replace($Root.Replace('\','\\'),'<ROOT>').Replace($Root,'<ROOT>')
    })
}
function Test-OriginalMoveAccessDenied([string[]]$Rows) {
    return $Rows -contains 'result=32792' -and
        $Rows -contains 'compat-system-error=5' -and
        @($Rows -like '*on execute_cmd (MoveFile)*').Count -ne 0
}
$count = 0
foreach ($level in $HeaderLevels) { foreach ($sourceName in $SourceNames) { foreach ($case in $cases) {
    $label = "h$level-$sourceName-$($case.Name)"
    $pair = @()
    foreach ($side in 'oracle','reimpl') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $completed = $false
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            # 一桁の attempt 番号を常に付け、再試行前後と両実装でパス長を維持する。
            $root = Join-Path $Workspace "$label-$side-attempt$attempt"
            $source = Join-Path $root $(if ($case.Layout) { '日本語-source' } elseif ($sourceName -eq 'wide') { 'Ā-source' } else { 'A-source' })
            New-Item -ItemType Directory -Path $source | Out-Null
            $archive = Join-Path $root $(if ($case.Layout -and $sourceName -eq 'wide') { 'Ā.lzh' } else { 'archive.lzh' })
            $inputNames = @('skip.txt','keep.bin') + $(if ($case.MixedExcluded) { @('extra.txt') } else { @() })
            foreach ($name in $inputNames) { Set-Input (Join-Path $source $name) "new-$name" 2024 }
            if ($case.Existing) {
                $seed = Join-Path $root 'seed'
                New-Item -ItemType Directory -Path $seed | Out-Null
                foreach ($name in 'skip.txt','keep.bin') { Set-Input (Join-Path $seed $name) "old-$name" 2020 }
                $seedArchive = Join-Path $root 'seed.lzh'
                $seedRows = @(Invoke-EnumProbe (Join-Path $root 'seed-command') @('--command-probe',$Oracle,"a -h$level -jm0 -n1 -gm1 -y1 `"$seedArchive`" `"$seed\`" *"))
                if ($seedRows -notcontains 'result=0') { throw "Seed failed: $label/$side" }
                Copy-Item -LiteralPath $seedArchive -Destination $archive
            }
            $layout = if ($case.Layout) { $case.Layout } elseif ($case.Replacement) { 'w64' } else { 'none' }
            $command = "$($case.Command) -h$level -jm0 -n1 -gm1 -y1 $($case.Options) `"$archive`" `"$source\`" $($case.Pattern)"
            $rows = @(Invoke-EnumProbe (Join-Path $root 'command') @('--command-enum-probe',$dll,$command,$layout,'1',[string]$case.Replacement,'1041','0','W','0'))
            if ($rows -notcontains 'result=0') {
                if ($side -eq 'oracle' -and (Test-OriginalMoveAccessDenied $rows)) {
                    [IO.File]::WriteAllLines((Join-Path $root 'original-command-failure.txt'),[string[]]$rows)
                    if ($attempt -lt 5) {
                        Write-Host "Wide compression selection: original MoveFile access denied; retrying in a fresh directory ($label/$attempt)"
                        Start-Sleep -Milliseconds 100
                        continue
                    }
                }
                throw "Compression failed: $label/$side`n$($rows -join "`n")"
            }
            $contents = @(Invoke-EnumProbe (Join-Path $root 'list') @('--command-probe',$Oracle,"l -n1 -gm1 `"$archive`""))
            $expectedNames = (($case.Members | ForEach-Object { $_ + '\u000D\u000A' }) -join '') + '\u000D\u000A'
            if ($contents -notcontains ('output="' + $expectedNames + '"')) { throw "Member selection differs: $label/$side`n$($contents -join "`n")" }
            foreach ($member in $case.Members) {
                $payloadName = if ($case.Replacement) { 'skip.txt' } else { $member }
                $prefix = if ($case.OldSkip -and $member -eq 'skip.txt') { 'old-' } else { 'new-' }
                foreach ($reader in 'oracle','reimpl') {
                    $readerDll = if ($reader -eq 'oracle') { $Oracle } else { $Candidate }
                    $payload = @(Invoke-EnumProbe (Join-Path $root "read-$reader-$member") @('--command-probe',$readerDll,"p -n1 -gm1 `"$archive`" $member"))
                    if ($payload -notcontains 'result=0' -or $payload -notcontains ('output="' + $prefix + $payloadName + '"')) {
                        throw "Payload differs: $label/$side/$reader/$member`n$($payload -join "`n")"
                    }
                }
            }
            foreach ($name in $inputNames) {
                if ($case.Command -eq 'm' -and $name -cin $case.Members) {
                    if (Test-Path -LiteralPath (Join-Path $source $name)) { throw "Archived move source remains: $label/$side/$name" }
                    continue
                }
                if ($case.Command -eq 'm' -and $case.MixedExcluded -and $name -eq 'extra.txt' -and $side -eq 'oracle') {
                    # 原版の未格納入力削除は既知の安全性例外。候補側は下の本文保持を必須とする。
                    if (Test-Path -LiteralPath (Join-Path $source $name)) { throw "Original exclusion/deletion observation changed: $label/$name" }
                    continue
                }
                if ([IO.File]::ReadAllText((Join-Path $source $name)) -cne "new-$name") { throw "Source changed: $label/$side/$name" }
            }
            $pair += ,@(Normalize-Result $rows $root)
            $completed = $true
            break
        }
        if (!$completed) { throw "Original retry limit reached: $label/$side" }
    }
    $difference = @(Compare-Object $pair[0] $pair[1] -CaseSensitive -SyncWindow 0)
    if ($difference.Count) { throw "Command output/state differs: $label`n$($difference | Out-String)" }
    $count++
    Write-Host "Wide compression selection: passed $label ($count)"
} } }
foreach ($entry in $hashes) { if ((Get-FileHash -LiteralPath $entry.Path).Hash -cne $entry.SHA256) { throw "Changed during test: $($entry.Path)" } }
Write-Host "Wide compression selection: $count exclusions/freshen/rename comparisons and cross-reader payload checks passed"
