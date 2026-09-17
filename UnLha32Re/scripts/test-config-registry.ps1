[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [Parameter(Mandatory)][string]$Archive,
    [ValidateSet('All', 'Configuration', 'Commands', 'Paths')][string]$Section = 'All'
)

$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Invoke-RegistryProbe([string]$Dll, [string]$Seed, [string[]]$ProbeArguments,
                              [switch]$Dump) {
    $registryOption = if ($Dump) { '--registry-dump' } else { '--registry' }
    $lines = @(& $TestProgram $registryOption $Seed $ProbeArguments[0] $Dll $ProbeArguments[1..($ProbeArguments.Count - 1)] 2>&1)
    $registryErrors = @($lines | Where-Object { $_ -match '^registry (enumeration|restore|sandbox cleanup|sandbox deletion) failed:' })
    if ($LASTEXITCODE -ne 0 -or $registryErrors.Count -ne 0) {
        throw "設定比較プローブが失敗しました: $Dll / $($ProbeArguments -join ' ') / $($registryErrors -join ' ')"
    }
    return $lines
}

function Assert-RegistryEqual([string[]]$Expected, [string[]]$Actual, [string]$Label) {
    if ([string]::Join("`n", $Expected) -cne [string]::Join("`n", $Actual)) {
        $difference = (Compare-Object $Expected $Actual -SyncWindow 0 | ForEach-Object {
            "$($_.SideIndicator) $($_.InputObject)"
        }) -join "`n"
        throw "保存設定の挙動が一致しません: $Label`n$difference"
    }
}

if ($Section -in @('All', 'Configuration')) {
$configSeeds = @(
    '',
    'C:DirectoryMode=0;C:OverWriteMode=0;C:ExtractAttribute=1;C:JunkDirectory=1;C:BadPathLevel=3',
    'C:DirectoryMode=404;C:OverWriteMode=406;C:ExtractAttribute=2;C:JunkDirectory=2;C:BadPathLevel=2',
    'L:TotalBar=4294967295;L:FVMode=4294967295;L:ForceUseAllPath=1',
    'C:DirectoryMode=1;C:OverWriteMode=1;C:ExtractAttribute=0;C:JunkDirectory=0;C:BadPathLevel=1;L:UseOldLog=0;L:DiskSpaceCheck=1;L:UseMFile=1',
    'L:JunkDirectory=1;L:BadPathLevel=3;L:ForceUseAllPath=2;L:MakeDirectoryMode=2;L:TotalBar=2;L:FVMode=2;L:FlushBuffer=2;L:UseOldLog=2;L:CauseOldGfSwitch=2',
    'C:DefaultDir@=.\MiXeD\Folder\'
)
$configCount = 0
foreach ($seed in $configSeeds) {
    foreach ($action in @('ok', 'main:412', 'local-save:502,503,504,505,506,507,508,509')) {
        foreach ($variant in @('A', 'W')) {
            $arguments = @('--config-dialog-probe', '1', $action, $variant)
            $expected = @(Invoke-RegistryProbe $Oracle $seed $arguments -Dump)
            $actual = @(Invoke-RegistryProbe $Candidate $seed $arguments -Dump)
            Assert-RegistryEqual $expected $actual "ConfigDialog $variant / $action / $seed"
            $configCount++
        }
    }
}
Write-Host "Registry configuration: $configCount A/W load/save/default-value cases compatible"

$expected = @(Invoke-RegistryProbe $Oracle '' @('--registry-lifecycle-probe', $Archive))
$actual = @(Invoke-RegistryProbe $Candidate '' @('--registry-lifecycle-probe', $Archive))
Assert-RegistryEqual $expected $actual 'same-process configuration lifetime'
Write-Host 'Registry configuration: external changes, dialog acceptance, and command lifetime compatible'
}

if ($Section -in @('All', 'Commands')) {
$overwriteCount = 0
$caseIndex = 0
foreach ($seed in @('', 'C:OverWriteMode=0', 'C:OverWriteMode=1', 'C:OverWriteMode=2', 'C:OverWriteMode=406')) {
    $expected = @(Invoke-RegistryProbe $Oracle $seed @('--registry-overwrite-probe', (Join-Path $Workspace "overwrite-$caseIndex-original")))
    $actual = @(Invoke-RegistryProbe $Candidate $seed @('--registry-overwrite-probe', (Join-Path $Workspace "overwrite-$caseIndex-candidate")))
    Assert-RegistryEqual $expected $actual "overwrite switches / $seed"
    $overwriteCount += $expected.Count
    $caseIndex++
}
Write-Host "Registry overwrite: $overwriteCount command, explicit-switch, and -+ cases compatible"

$findCount = 0
foreach ($seed in @('C:JunkDirectory=1', 'L:ForceUseAllPath=1')) {
    $expected = @(Invoke-RegistryProbe $Oracle $seed @('--registry-find-probe', $Archive))
    $actual = @(Invoke-RegistryProbe $Candidate $seed @('--registry-find-probe', $Archive))
    Assert-RegistryEqual $expected $actual "archive search flags / $seed"
    $findCount += $expected.Count
}
Write-Host "Registry archive search: $findCount A/W/OpenArchive2/explicit-mode cases compatible"

$expected = @(Invoke-RegistryProbe $Oracle 'L:ForceUseAllPath=1' @('--find-pattern-probe', $Archive, 'ansi', 'defined'))
$actual = @(Invoke-RegistryProbe $Candidate 'L:ForceUseAllPath=1' @('--find-pattern-probe', $Archive, 'ansi', 'defined'))
Assert-RegistryEqual $expected $actual 'M_REGARDLESS_INIT_FILE with saved search settings'
Write-Host "Registry archive search: $($expected.Count) ignore-saved-settings cases compatible"

$seed = 'C:OverWriteMode=2;C:JunkDirectory=1;C:ExtractAttribute=1;L:ForceUseAllPath=1'
$expected = @(Invoke-RegistryProbe $Oracle $seed @('--memory-selection-probe', $Archive, 'none'))
$actual = @(Invoke-RegistryProbe $Candidate $seed @('--memory-selection-probe', $Archive, 'none'))
Assert-RegistryEqual $expected $actual 'memory extraction with saved command settings'
Write-Host "Registry memory extraction: $($expected.Count) selection cases compatible"
$expected = @(Invoke-RegistryProbe $Oracle $seed @('--unicode-memory-probe', (Join-Path $Workspace 'unicode-reference')))
$actual = @(Invoke-RegistryProbe $Candidate $seed @('--unicode-memory-probe', (Join-Path $Workspace 'unicode-candidate')))
Assert-RegistryEqual $expected $actual 'Unicode memory roundtrip with saved command settings'
Write-Host "Registry Unicode memory: $($expected.Count) roundtrip cases compatible"
}

function Get-RegistryFileSnapshot([string]$Root) {
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse | Sort-Object FullName)
    foreach ($file in $files) {
        $name = [IO.Path]::GetRelativePath($Root, $file.FullName)
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        "$name|$($file.Length)|$([int]$file.Attributes)|$hash"
    }
}

if ($Section -in @('All', 'Commands', 'Paths')) {
$pathCases = @(
    @{ Options='x'; Pattern='*'; Explicit=$false },
    @{ Options='e'; Pattern='*'; Explicit=$false },
    @{ Options='x -x1'; Pattern='*'; Explicit=$false },
    @{ Options='e -x1'; Pattern='*'; Explicit=$false },
    @{ Options='x -x0'; Pattern='*'; Explicit=$false },
    @{ Options='x -+'; Pattern='*'; Explicit=$false },
    @{ Options='x -+0'; Pattern='*'; Explicit=$false },
    @{ Options='x -+1 -+0'; Pattern='*'; Explicit=$false },
    @{ Options='x'; Pattern='*'; Explicit=$true },
    @{ Options='e'; Pattern='*'; Explicit=$true },
    @{ Options='x'; Pattern='*.txt'; Explicit=$false },
    @{ Options='x -p0'; Pattern='*.txt'; Explicit=$false },
    @{ Options='x -p1'; Pattern='*.txt'; Explicit=$false },
    @{ Options='x -x1 -+'; Pattern='*'; Explicit=$false },
    @{ Options='x -a0'; Pattern='*'; Explicit=$false },
    @{ Options='x -a1'; Pattern='*'; Explicit=$false },
    @{ Options='x -a2'; Pattern='*'; Explicit=$false },
    @{ Options='x -a1 -a0'; Pattern='*'; Explicit=$false },
    @{ Options='x -a1 -+'; Pattern='*'; Explicit=$false }
)
$pathCount = 0
foreach ($settings in @('', 'C:JunkDirectory=1', 'L:ForceUseAllPath=1', 'C:ExtractAttribute=1', 'C:DirectoryMode=0')) {
    foreach ($case in $pathCases) {
        foreach ($variant in @('A', 'W')) {
            $snapshots = @()
            foreach ($dll in @($Oracle, $Candidate)) {
                $kind = if ($dll -ceq $Oracle) { 'reference' } else { 'candidate' }
                $root = Join-Path $Workspace "paths-$pathCount-$kind"
                $saved = Join-Path $root 'saved'
                $explicit = Join-Path $root 'explicit'
                New-Item -ItemType Directory -Path $root, $saved, $explicit | Out-Null
                $seed = "C:DefaultDir@=$saved\"
                if ($settings) { $seed += ";$settings" }
                $command = $case.Options + ' -gm1 "' + $Archive + '" '
                if ($case.Explicit) { $command += '"' + $explicit + '\" ' }
                $command += $case.Pattern
                $probe = if ($variant -eq 'A') { '--command-probe-a' } else { '--command-probe' }
                Push-Location -LiteralPath $root
                try {
                    $output = @(Invoke-RegistryProbe $dll $seed @($probe, $command))
                } finally { Pop-Location }
                $normalized = foreach ($line in $output) {
                    $line.Replace($root.Replace('\', '\\'), '<ROOT>').Replace($root.Replace('\', '/'), '<ROOT>')
                }
                $snapshots += ,@($normalized + @(Get-RegistryFileSnapshot $root))
            }
            Assert-RegistryEqual $snapshots[0] $snapshots[1] "default path $variant / $($case.Options) / $settings / explicit=$($case.Explicit)"
            $pathCount++
        }
    }
}
Write-Host "Registry paths: $pathCount A/W default directory, path selection, and attribute cases compatible"

$sequenceCases = @(
    foreach ($mode in @(0, 1)) {
        foreach ($initial in @('l', 'l -+', 'l -jf1', 'config:ok', 'config:main:404',
                'config:main:403', 'open', 'open-ignore', 'check', 'memory', 'memory -+',
                'l;open', 'l;open-ignore', 'l -+;check', 'l -+;memory')) {
            @{ Mode=$mode; Initial=$initial; Options='x'; Explicit=$false }
        }
    }
    foreach ($initial in @('l', 'l -+')) {
        foreach ($options in @('x -+', 'x -+0', 'e')) {
            @{ Mode=0; Initial=$initial; Options=$options; Explicit=$false }
        }
        @{ Mode=0; Initial=$initial; Options='x'; Explicit=$true }
    }
)
$sequenceCount = 0
foreach ($case in $sequenceCases) {
    foreach ($variant in @('A', 'W')) {
        $snapshots = @()
        foreach ($dll in @($Oracle, $Candidate)) {
            $kind = if ($dll -ceq $Oracle) { 'reference' } else { 'candidate' }
            $root = Join-Path $Workspace "sequence-$sequenceCount-$kind"
            $saved = Join-Path $root 'saved'
            $explicit = Join-Path $root 'explicit'
            New-Item -ItemType Directory -Path $saved, $explicit | Out-Null
            $seed = "C:DirectoryMode=$($case.Mode);C:DefaultDir@=$saved\"
            $command = $case.Options + ' -gm1 "' + $Archive + '" '
            if ($case.Explicit) { $command += '"' + $explicit + '\" ' }
            $command += '*'
            Push-Location -LiteralPath $root
            try {
                $output = @(Invoke-RegistryProbe $dll $seed @('--registry-path-sequence-probe',
                    $Archive, $case.Initial, $command, $variant))
            } finally { Pop-Location }
            if ($output -notcontains 'phase=initial' -or $output -notcontains 'phase=second') {
                throw "設定シーケンスの観測行が欠落しました: $kind / $($case.Initial) / $variant"
            }
            $normalized = foreach ($line in $output) {
                $line.Replace($root.Replace('\', '\\'), '<ROOT>').Replace($root.Replace('\', '/'), '<ROOT>').Replace(
                    $root.Replace('\', '/').ToUpperInvariant(), '<ROOT>')
            }
            $snapshots += ,@($normalized + @(Get-RegistryFileSnapshot $root))
        }
        Assert-RegistryEqual $snapshots[0] $snapshots[1] "path sequence $variant / mode=$($case.Mode) / $($case.Initial) -> $($case.Options)"
        $sequenceCount++
    }
}
Write-Host "Registry lifetime: $sequenceCount A/W command, dialog, archive, check, and memory sequences compatible"

# 非 CP932 経路はログの既知差異を別項目として残し、ここでは設定が支配する内容・属性を比較する。
$wideCount = 0
foreach ($seed in @('', 'C:ExtractAttribute=1')) {
    foreach ($options in @('x', 'x -a0', 'x -a1', 'x -a2')) {
        $snapshots = @()
        foreach ($dll in @($Oracle, $Candidate)) {
            $kind = if ($dll -ceq $Oracle) { 'reference' } else { 'candidate' }
            $root = Join-Path $Workspace "wide-$wideCount-$kind"
            $destination = Join-Path $root '展開𠮷'
            New-Item -ItemType Directory -Path $destination | Out-Null
            $command = $options + ' -gm1 "' + $Archive + '" "' + $destination + '\" *'
            $output = @(Invoke-RegistryProbe $dll $seed @('--command-probe', $command))
            if ($output[0] -cne 'result=0') { throw "Unicode 属性の展開が失敗しました: $dll / $options" }
            $snapshots += ,@(Get-RegistryFileSnapshot $root)
        }
        Assert-RegistryEqual $snapshots[0] $snapshots[1] "Unicode attributes / $options / $seed"
        $wideCount++
    }
}
Write-Host "Registry Unicode extraction: $wideCount content and read-only-attribute cases compatible (logs tracked separately)"
}
