[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$Variants = @('list-all','list-first','list-none','mutate','reject-mutate',
        'count','check','open','find','find-none','memory-first','memory-last',
        'update','fresh','reject-update','register-read','reregister-read','mutate-add','skip-update'),
    [string[]]$Layouts = @('a32','w32','a64','w64'),
    [int[]]$Locales = @(1033,1041),
    [int[]]$UnicodeModes = @(0,1),
    [string[]]$Apis = @('legacy','A','W'),
    [ValidateRange(1,4)][int]$Parallelism = 4,
    [switch]$AttributeAudit
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
New-Item -ItemType Directory -Path $Workspace | Out-Null
Write-Host "Enum state workspace: $Workspace"
if ($Parallelism -gt 1 -and $Layouts.Count -gt 1) {
    # 書庫・レジストリの試験領域と DLL プロセスを分離し、4 ABI を独立に確認する。
    $parallelScript = $PSCommandPath
    $parallelArguments = @{
        TestProgram=$TestProgram; Oracle=$Oracle; Candidate=$Candidate; Variants=$Variants
        Locales=$Locales; UnicodeModes=$UnicodeModes; Apis=$Apis; Parallelism=1
        AttributeAudit=$AttributeAudit
    }
    $summaries = @($Layouts | ForEach-Object -ThrottleLimit $Parallelism -Parallel {
        try {
            $arguments = $using:parallelArguments
            & $using:parallelScript @arguments -Layouts $_ -Workspace (Join-Path $using:Workspace $_)
        } catch {
            [pscustomobject]@{ Failure=$_.Exception.Message }
        }
    })
    $failures = @($summaries | Where-Object { $_.PSObject.Properties['Failure'] })
    if ($failures.Count) { throw ($failures.Failure -join "`n") }
    if ($summaries.Count -ne $Layouts.Count) { throw '列挙状態試験の結果件数が不足しています。' }
    $count = ($summaries | Measure-Object -Property Comparisons -Sum).Sum
    $guards = ($summaries | Measure-Object -Property InitializationGuards -Sum).Sum
    Write-Host "Enum state: $count total comparisons and $guards candidate-only initialization guards passed"
    [pscustomobject]@{ Comparisons=$count; InitializationGuards=$guards }
    return
}
function Set-EnumFixture([string]$Path, [string]$Value, [datetime]$Time) {
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
    [IO.File]::SetCreationTimeUtc($Path, $Time)
    [IO.File]::SetLastAccessTimeUtc($Path, $Time)
    [IO.File]::SetLastWriteTimeUtc($Path, $Time)
}
function Normalize-EnumRows($Rows, [string]$Root) {
    @($Rows | ForEach-Object {
        $_.Replace($Root.Replace('\','/'),'<ROOT>').Replace($Root.Replace('\','\\'),'<ROOT>').Replace($Root,'<ROOT>')
    })
}
function Invoke-EnumProbe([string]$LogPrefix, [string[]]$Arguments, [string]$WorkingDirectory='') {
    # 並列 native pipeline では終了時の全出力欠落を観測したため、各子プロセスの EOF まで個別に読む。
    $start = [Diagnostics.ProcessStartInfo]::new($runner)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($WorkingDirectory) { $start.WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path }
    foreach ($argument in @('--timeout-seconds','30',$TestProgram,'--registry','') + $Arguments) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($start)
    $started = [datetime]::UtcNow
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $timedOut = !$child.WaitForExit(40000)
        if ($timedOut) { $child.Kill($true); $child.WaitForExit() }
        $output = $stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$LogPrefix.log", $output)
        [IO.File]::WriteAllText("$LogPrefix.stderr.log", $stderr.GetAwaiter().GetResult())
        [pscustomobject]@{ ProcessId=$child.Id; ExitCode=$child.ExitCode; TimedOut=$timedOut
            ElapsedSeconds=([datetime]::UtcNow-$started).TotalSeconds; Arguments=$Arguments } |
            ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$LogPrefix.invocation.json" -Encoding utf8
        if ($timedOut -or $child.ExitCode -ne 0) { throw "列挙状態プローブが失敗しました: $LogPrefix, exit=$($child.ExitCode)" }
        $reader = [IO.StringReader]::new($output)
        try { while ($null -ne ($line = $reader.ReadLine())) { $line } } finally { $reader.Dispose() }
    } finally { $child.Dispose() }
}
$count = 0
foreach ($variant in $Variants) {
 foreach ($locale in $Locales) { foreach ($utf8 in $UnicodeModes) {
  foreach ($api in $Apis) { foreach ($layout in $Layouts) {
    $label = "$variant-$locale-$utf8-$api-$layout"
    $results = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace "$label-$side"
        $inputPath = Join-Path $root 'input'
        $nextPath = Join-Path $root 'next'
        New-Item -ItemType Directory -Path $inputPath, $nextPath | Out-Null
        $archive = Join-Path $root 'old.lzh'
        $outputArchive = Join-Path $root 'new.lzh'
        $base = $inputPath.Replace('\','/') + '/'
        $nextBase = $nextPath.Replace('\','/') + '/'
        Set-EnumFixture (Join-Path $inputPath 'a.txt') 'old-first' ([datetime]'2020-01-02T03:04:06Z')
        Set-EnumFixture (Join-Path $inputPath 'z.txt') 'old-last-different' ([datetime]'2021-02-03T04:05:06Z')
        $seed = @(Invoke-EnumProbe (Join-Path $root 'seed') @('--command-probe',$Oracle,"a -n1 -gm1 -y1 -h0 `"$archive`" `"$base`" a.txt z.txt"))
        if ($seed -notcontains 'result=0' -or !(Test-Path -LiteralPath $archive)) {
            throw "列挙状態試験の元書庫を作成できません: $label/$side"
        }
        foreach ($path in $inputPath, $nextPath) {
            Set-EnumFixture (Join-Path $path 'a.txt') 'new-first-updated' ([datetime]'2024-01-02T03:04:06Z')
            Set-EnumFixture (Join-Path $path 'z.txt') 'new-last-different-value' ([datetime]'2025-02-03T04:05:06Z')
        }
        if ($variant -eq 'skip-update') {
            foreach ($name in 'a.txt','z.txt') { [IO.File]::SetLastWriteTimeUtc((Join-Path $inputPath $name), [datetime]'2000-01-02T03:04:06Z') }
        }
        $add = "a -n1 -gm1 -y1 -c1 -h2 `"$outputArchive`" `"$nextBase`" a.txt z.txt"
        $list = "l -n1 -gm1 -y1 `"$archive`""
        $update = "a -n1 -gm1 -y1 -c1 -h2 `"$archive`" `"$base`" a.txt z.txt"
        $fresh = "f -n1 -gm1 -y1 -c1 -h2 `"$archive`" `"$base`" a.txt z.txt"
        [string[]]$steps = @(switch ($variant) {
            'list-all' { $list; $add }
            'list-first' { "$list a.txt"; $add }
            'list-none' { "$list absent.txt"; $add }
            'mutate' { '@mutate'; $list; '@nomutate'; $add }
            'reject-mutate' { '@reject'; '@mutate'; $list; '@accept'; '@nomutate'; $add }
            'count' { "@count:$archive"; $add }
            'check' { "@check:$archive"; $add }
            'open' { "@open:$archive"; '@close'; $add }
            'find' { "@open:$archive"; '@first:z.txt'; '@close'; $add }
            'find-none' { "@open:$archive"; '@first:absent.txt'; '@close'; $add }
            'memory-first' { "@memory:`"$archive`" a.txt"; $add }
            'memory-last' { "@memory:`"$archive`" z.txt"; $add }
            'update' { $update; $add }
            'fresh' { $fresh; $add }
            'reject-update' { '@reject'; $update; '@accept'; $add }
            'register-read' { $list; '@register'; "$list a.txt"; $add }
            'reregister-read' { $list; '@reregister'; "$list a.txt"; $add }
            'mutate-add' { $list; '@mutate'; $add }
            'skip-update' { "u -n1 -gm1 -y1 -h2 `"$archive`" `"$base`" a.txt z.txt"; $add }
            default { throw "未知の列挙状態ケース: $variant" }
        })
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(Invoke-EnumProbe (Join-Path $root 'sequence') (@('--enum-sequence-probe',$dll,$layout,"$locale","$utf8",$api) + $steps))
        if (@($rows | Where-Object { $_ -match '^enum\.count=\d+$' }).Count -ne $steps.Count -or $rows[-1] -cne 'enum.clear=1') {
            throw "列挙状態の連続呼び出しログが不足しています: $label/$side"
        }
        foreach ($path in $archive, $outputArchive) {
            $exists = Test-Path -LiteralPath $path
            $rows += "archive=$([IO.Path]::GetFileName($path)),exists=$exists"
            if (!$exists) { continue }
            $archiveLabel = [IO.Path]::GetFileNameWithoutExtension($path)
            $attributeProbe = if ($AttributeAudit) { '--attribute-probe-audit' } else { '--attribute-probe' }
            $metadata = @(Invoke-EnumProbe (Join-Path $root "$archiveLabel-attributes") @($attributeProbe,$Oracle,$path))
            if ($metadata.Count -ne 12 -or @($metadata | Where-Object { $_ -match '^attribute\.[012]\.[01]=' }).Count -ne 6 -or
                @($metadata | Where-Object { $_ -match '^attribute\.memory\.[012]\.[01]=' }).Count -ne 6) {
                throw "結果書庫の属性・メモリ展開ログが不足しています: $label/$side/$archiveLabel"
            }
            $rows += $metadata
            $data = @(Invoke-EnumProbe (Join-Path $root "$archiveLabel-data") @('--command-probe-a',$Oracle,"p -+ `"$path`"",'A'))
            if ($data.Count -ne 6 -or $data -notcontains 'result=0') { throw "結果書庫を原版で展開できません: $label/$side" }
            $rows += @($data | ForEach-Object { "data.$_" })
        }
        $results += ,@(Normalize-EnumRows $rows $root | Tee-Object -FilePath (Join-Path $root 'comparable.log'))
    }
    $difference = @(Compare-Object $results[0] $results[1] -SyncWindow 0)
    if ($difference.Count) {
        $details = $difference | Select-Object -First 10 | Out-String -Width 2000
        throw "列挙情報の保持・読み取り境界・通知拒否が一致しません: $label`n$details"
    }
    $count++
  } }
 } }
 Write-Host "Enum state: $variant, $count comparisons passed"
}

# 原版の未初期化ヒープを返す再登録直後は、不定値を比較せず候補の初期化保証を検査する。
$guards = 0
foreach ($layout in $Layouts) {
 foreach ($operation in '@register','@reregister') {
    $root = Join-Path $Workspace "guard-$layout-$($operation.Substring(1))"
    New-Item -ItemType Directory -Path $root | Out-Null
    Set-EnumFixture (Join-Path $root 'a.txt') 'guard-data' ([datetime]'2024-01-02T03:04:06Z')
    $archive = Join-Path $root 'guard.lzh'
    $base = $root.Replace('\','/') + '/'
    $steps = @($operation, "a -n1 -gm1 -y1 -h2 `"$archive`" `"$base`" a.txt")
    $rows = @(Invoke-EnumProbe (Join-Path $root 'sequence') (@('--enum-sequence-probe',$Candidate,$layout,'1041','1','W') + $steps))
    $entries = @($rows | Where-Object { $_ -match '^enum\.entry=' })
    if ($entries.Count -ne 1 -or
        $entries[0] -notmatch ',command=2,original=0,packed=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write=0,') {
        throw "候補の再登録時初期化が失敗しました: $layout/$operation"
    }
    $guards++
 }
}
Write-Host "Enum state: $count A/W/legacy 32/64 retained-metadata, header-read, callback-edit, command/output/data comparisons and $guards candidate-only initialization guards passed"
[pscustomobject]@{ Comparisons=$count; InitializationGuards=$guards }
