[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$FixturesRoot,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$RunnerPath
)
$ErrorActionPreference = 'Stop'

$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$FixturesRoot = (Resolve-Path -LiteralPath $FixturesRoot).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
$RunnerPath = if ($RunnerPath) {
    (Resolve-Path -LiteralPath $RunnerPath).Path
} else {
    (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
}
if (Test-Path -LiteralPath $Workspace) { throw '新しい連結進捗試験領域を指定してください。' }

$seed0 = Join-Path $FixturesRoot 'seed-l0.lzh'
$seed1 = Join-Path $FixturesRoot 'seed-l1.lzh'
foreach ($path in $seed0,$seed1) {
    if (!(Test-Path -LiteralPath $path)) { throw "連結進捗試験の種書庫がありません: $path" }
}

$hashes = @{}
foreach ($path in $TestProgram,$RunnerPath,$Oracle,$Candidate,$seed0,$seed1) {
    $hashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
New-Item -ItemType Directory -Path $Workspace | Out-Null

function Invoke-JoinProbe([string]$LogPrefix, [string]$Registry, [string[]]$Arguments,
                          [string]$WorkingDirectory) {
    $start = [Diagnostics.ProcessStartInfo]::new($RunnerPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
    foreach ($argument in @('--timeout-seconds','30',$TestProgram,'--registry',$Registry) + $Arguments) {
        [void]$start.ArgumentList.Add([string]$argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    $started = [datetime]::UtcNow
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $timedOut = !$child.WaitForExit(40000)
        if ($timedOut) {
            $child.Kill($true)
            $child.WaitForExit()
        }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText("$LogPrefix.log", $output, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$LogPrefix.stderr.log", $errorOutput, [Text.UTF8Encoding]::new($false))
        [pscustomobject]@{
            ProcessId = $child.Id
            ExitCode = $child.ExitCode
            TimedOut = $timedOut
            ElapsedSeconds = ([datetime]::UtcNow - $started).TotalSeconds
            Arguments = $Arguments
        } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath "$LogPrefix.invocation.json" -Encoding utf8
        if ($timedOut -or $child.ExitCode -ne 0) {
            throw "連結進捗プローブが失敗しました: $LogPrefix, exit=$($child.ExitCode), stderr=$errorOutput"
        }
        $reader = [IO.StringReader]::new($output)
        try {
            while ($null -ne ($line = $reader.ReadLine())) { $line }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $child.Dispose()
    }
}

function Normalize-JoinRows([string[]]$Rows, [string]$Root, [string]$Side) {
    foreach ($rowValue in $Rows) {
        $row = $rowValue
        if ($row -match '^progress\.entry=.*?,state=5,') {
            $zeroFields = ',file=0,compressed=0,write=0,attributes=0,crc=0,os=0,ratio=0,create=0,access=0,write-time=0,mode="",source='
            if ($Side -eq 'reimpl' -and !$row.Contains($zeroFields)) {
                throw "候補の SEARCH 通知に未初期化欄があります: $Root"
            }
            # 元 DLL の ANSI EX32 SEARCH は未使用の数値欄を初期化しない。名前・順序・宛先は比較する。
            $row = $row -replace ',file=.*?,mode="(?:\\.|[^"\\])*",source=', ',metadata=undefined,source='
        }
        if ($row -match '^handle-count=') { $row = 'handle-count=<stable>' }
        $row.Replace($Root.Replace('\','/'), '<ROOT>').Replace($Root.Replace('\','\\'), '<ROOT>').Replace($Root, '<ROOT>')
    }
}

function Get-ProgressEntries([string[]]$Rows) {
    @($Rows | Where-Object { $_ -like 'progress.entry=*' })
}

function Assert-NormalProgress([string[]]$Rows, [int]$Mode, [int]$SourceCount, [string]$Label) {
    if (@($Rows -ceq 'result=0').Count -ne 1) { throw "連結の戻り値が不正です: $Label" }
    $counts = @($Rows | Where-Object { $_ -match '^progress\.count=\d+$' })
    $expectedCount = if ($Mode -eq 0) { 0 } else { 4 * $SourceCount + 4 }
    if (!$counts.Count -or @($counts -ceq "progress.count=$expectedCount").Count -lt 1) {
        throw "連結進捗件数が不正です: $Label"
    }
    $states = [Collections.Generic.List[int]]::new()
    foreach ($entry in Get-ProgressEntries $Rows) {
        if ($entry -notmatch ',state=(\d+),') { throw "進捗状態を読めません: $Label" }
        $states.Add([int]$Matches[1])
    }
    [int[]]$expectedStates = @()
    if ($Mode -ne 0) {
        $values = [Collections.Generic.List[int]]::new()
        for ($index = 0; $index -lt $SourceCount; ++$index) { $values.Add(5) }
        $values.Add(3)
        for ($index = 0; $index -lt $SourceCount; ++$index) {
            $values.Add(0); $values.Add(1); $values.Add(1)
        }
        $values.Add(4); $values.Add(1); $values.Add(2)
        $expectedStates = $values.ToArray()
    }
    if (@(Compare-Object -ReferenceObject $expectedStates -DifferenceObject $states.ToArray() -SyncWindow 0).Count) {
        throw "連結進捗の状態順序が不正です: $Label"
    }
}

function Assert-Publication([string[]]$Rows, [int]$Mapped, [long]$FinalSize, [string]$Label) {
    $entries = @(Get-ProgressEntries $Rows)
    $copyIndex = -1
    for ($index = 0; $index -lt $entries.Count; ++$index) {
        if ($entries[$index] -match ',state=4,') { $copyIndex = $index; break }
    }
    if ($copyIndex -lt 1) { throw "COPY 通知がありません: $Label" }
    $preCopySize = if ($Mapped -eq 0) { 0 } else { 8388608 }
    for ($index = 0; $index -lt $copyIndex; ++$index) {
        if ($entries[$index] -notmatch "audit-archive-size=$preCopySize,audit-archive-prefix=error:32") {
            throw "COPY 前の書庫公開状態が不正です: $Label"
        }
    }
    $copy = $entries[$copyIndex]
    if ($copy -notmatch "audit-archive-size=$FinalSize," -or
        $copy -match 'audit-archive-prefix=error:' -or
        $copy -notmatch "audit-source-size=$FinalSize,audit-dest-size=$FinalSize") {
        throw "COPY 時点の書庫公開状態が不正です: $Label"
    }
}

function New-JoinInputs([string]$Folder, [int]$SourceCount) {
    $inputs = [Collections.Generic.List[string]]::new()
    $seeds = @($seed0,$seed1)
    for ($index = 0; $index -lt $SourceCount; ++$index) {
        $path = Join-Path $Folder ("source{0}.lzh" -f ($index + 1))
        Copy-Item -LiteralPath $seeds[$index] -Destination $path
        $inputs.Add($path)
    }
    return @($inputs)
}

function Assert-InputsUnchanged([string[]]$Inputs, [int]$SourceCount, [string]$Label) {
    $seeds = @($seed0,$seed1)
    for ($index = 0; $index -lt $SourceCount; ++$index) {
        if ((Get-FileHash -LiteralPath $Inputs[$index] -Algorithm SHA256).Hash -cne
            $hashes[$seeds[$index]]) {
            throw "連結元が変更されました: $Label"
        }
    }
}

$comparisons = 0
$publicationComparisons = 0
$cancellations = 0
$extendedPathComparisons = 0

$normalCases = [Collections.Generic.List[object]]::new()
foreach ($layout in 'a32','w32','a64','w64') {
    $api = if ($layout.StartsWith('a')) { 'A' } else { 'W' }
    foreach ($mode in 0,1,2) {
        foreach ($sourceCount in 1,2) {
            $normalCases.Add([pscustomobject]@{ Layout=$layout; Api=$api; Mode=$mode; SourceCount=$sourceCount })
        }
    }
}
# 旧 API でも W64 の進捗構造を受け取れる既存 ABI を、代表ケースで固定する。
$normalCases.Add([pscustomobject]@{ Layout='w64'; Api='legacy'; Mode=1; SourceCount=2 })

foreach ($case in $normalCases) {
    $logs = @{}
    $archives = @{}
    foreach ($side in 'oracle','reimpl') {
        $folder = Join-Path $Workspace ("normal-{0}-{1}-n{2}-s{3}-{4}" -f
            $case.Layout,$case.Api,$case.Mode,$case.SourceCount,$side)
        New-Item -ItemType Directory -Path $folder | Out-Null
        $inputs = @(New-JoinInputs $folder $case.SourceCount)
        $archive = Join-Path $folder 'joined.lzh'
        $line = "j -gm1 -y1 -n$($case.Mode) `"$archive`"" + (($inputs | ForEach-Object { " `"$_`"" }) -join '')
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(Invoke-JoinProbe (Join-Path $folder 'command') '' (
            @('--progress-sequence-probe',$dll,$case.Layout,'1041','0',$case.Api,$case.Layout,
              '@full-progress-paths',$line,"@audit-archive-release:$archive",'@handle-count')) $folder)
        Assert-NormalProgress $rows $case.Mode $case.SourceCount "$($case.Layout)/$($case.Api)/n$($case.Mode)/s$($case.SourceCount)/$side"
        if (!(Test-Path -LiteralPath $archive) -or
            @($rows -ceq 'archive-released=1,error=0').Count -ne 1) {
            throw "連結後の書庫またはハンドル解放が不正です: $folder"
        }
        if (@(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count) {
            throw "連結後に一時書庫が残っています: $folder"
        }
        Assert-InputsUnchanged $inputs $case.SourceCount $folder
        $archives[$side] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        $logs[$side] = @(Normalize-JoinRows $rows $folder $(if ($side -eq 'oracle') { 'oracle' } else { 'reimpl' }))
    }
    if ($archives.oracle -cne $archives.reimpl -or
        @(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count) {
        throw "新規連結の進捗・出力・書庫が一致しません: $($case.Layout)/$($case.Api)/n$($case.Mode)/s$($case.SourceCount)"
    }
    ++$comparisons
}

foreach ($mapped in 0,1) {
    $logs = @{}
    $archives = @{}
    foreach ($side in 'oracle','reimpl') {
        $folder = Join-Path $Workspace "publication-mapped-$mapped-$side"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $inputs = @(New-JoinInputs $folder 1)
        $archive = Join-Path $folder 'joined.lzh'
        $line = "j -gm1 -y1 -n1 `"$archive`" `"$($inputs[0])`""
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $rows = @(Invoke-JoinProbe (Join-Path $folder 'command') "L:UseMFile=$mapped" (
            @('--progress-sequence-probe',$dll,'w64','1041','0','W','w64',
              "@audit-progress-archive:$archive",'@audit-progress-archive-prefix',
              '@audit-progress-copy-files','@full-progress-paths',$line,
              "@audit-archive-release:$archive")) $folder)
        Assert-NormalProgress $rows 1 1 "publication/mapped-$mapped/$side"
        if (!(Test-Path -LiteralPath $archive)) { throw "COPY 後の書庫がありません: $folder" }
        $finalSize = (Get-Item -LiteralPath $archive).Length
        Assert-Publication $rows $mapped $finalSize "publication/mapped-$mapped/$side"
        if (@($rows -ceq 'archive-released=1,error=0').Count -ne 1) {
            throw "COPY 後に書庫ハンドルが残っています: $folder"
        }
        Assert-InputsUnchanged $inputs 1 $folder
        $archives[$side] = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        $logs[$side] = @(Normalize-JoinRows $rows $folder $(if ($side -eq 'oracle') { 'oracle' } else { 'reimpl' }))
    }
    if ($archives.oracle -cne $archives.reimpl -or
        @(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count) {
        throw "新規連結の公開タイミングが一致しません: UseMFile=$mapped"
    }
    ++$comparisons
    ++$publicationComparisons
}

# 原版は j の新規出力に拡張名前空間を受け付けない。直接作成経路が Win32 API を
# そのまま通して成功してしまわないことと、入力が残ることを固定する。
$logs = @{}
foreach ($side in 'oracle','reimpl') {
    $folder = Join-Path $Workspace "extended-target-$side"
    New-Item -ItemType Directory -Path $folder | Out-Null
    $inputs = @(New-JoinInputs $folder 1)
    $archive = Join-Path $folder 'joined.lzh'
    $extendedArchive = '\\?\' + $archive
    $line = "j -gm1 -y1 `"$extendedArchive`" `"$($inputs[0])`""
    $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
    $rows = @(Invoke-JoinProbe (Join-Path $folder 'command') '' (
        @('--command-probe',$dll,$line)) $folder)
    if (@($rows -ceq 'result=32809').Count -ne 1 -or
        @($rows -ceq 'win32-error=123').Count -ne 1 -or
        @($rows -ceq 'compat-system-error=2').Count -ne 1 -or
        (Test-Path -LiteralPath $archive) -or
        @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count) {
        throw "拡張名前空間の新規連結拒否が不正です: $folder"
    }
    Assert-InputsUnchanged $inputs 1 $folder
    $logs[$side] = @(Normalize-JoinRows $rows $folder $side)
}
if (@(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count) {
    throw '拡張名前空間の新規連結拒否が元 DLL と一致しません。'
}
$comparisons += 1
$extendedPathComparisons += 1

foreach ($mapped in 0,1) {
    foreach ($abortState in 5,3,0,1,4,2) {
        $logs = @{}
        $archives = @{}
        foreach ($side in 'oracle','reimpl') {
            $folder = Join-Path $Workspace "cancel-mapped-$mapped-state-$abortState-$side"
            New-Item -ItemType Directory -Path $folder | Out-Null
            $inputs = @(New-JoinInputs $folder 1)
            $archive = Join-Path $folder 'joined.lzh'
            $retry = Join-Path $folder 'retry.lzh'
            $line = "j -gm1 -y1 -n1 `"$archive`" `"$($inputs[0])`""
            $retryLine = "j -gm1 -y1 -n1 `"$retry`" `"$($inputs[0])`""
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $rows = @(Invoke-JoinProbe (Join-Path $folder 'command') "L:UseMFile=$mapped" (
                @('--progress-sequence-probe',$dll,'w64','1041','0','W','w64',
                  "@audit-progress-archive:$archive",'@audit-progress-archive-prefix',
                  '@audit-progress-copy-files','@full-progress-paths',"@abort-state:$abortState",
                  $line,"@audit-archive-release:$archive",'@handle-count','@abort-state:-1',
                  $retryLine,"@audit-archive-release:$retry",'@handle-count')) $folder)
            $expected = if ($abortState -in 5,3,0,1) { 32800 } else { 0 }
            $results = @($rows | Where-Object { $_ -match '^result=' })
            if ($results.Count -ne 2 -or $results[0] -cne "result=$expected" -or $results[1] -cne 'result=0') {
                throw "中断後の戻り値または再利用が不正です: $folder"
            }
            $expectedSystem = if ($abortState -in 5,3) { 1223 } elseif ($abortState -in 0,1) { 2 } else { 38 }
            if (@($rows -ceq "compat-system-error=$expectedSystem").Count -lt 1) {
                throw "中断時のシステムエラーが不正です: $folder"
            }
            $exists = Test-Path -LiteralPath $archive
            if ($exists -ne ($abortState -in 4,2) -or !(Test-Path -LiteralPath $retry)) {
                throw "中断後の書庫状態が不正です: $folder"
            }
            $releaseRows = @($rows | Where-Object { $_ -match '^archive-released=' })
            $expectedRelease = if ($exists) { 'archive-released=1,error=0' } else { 'archive-released=0,error=2' }
            if ($releaseRows.Count -ne 2 -or $releaseRows[0] -cne $expectedRelease -or
                $releaseRows[1] -cne 'archive-released=1,error=0') {
                throw "中断後のハンドル解放が不正です: $folder"
            }
            $handles = @($rows | Where-Object { $_ -match '^handle-count=' } |
                ForEach-Object { [int](($_ -split '=')[1]) })
            if ($handles.Count -ne 2 -or @($handles | Select-Object -Unique).Count -ne 1) {
                throw "中断後のハンドル数が安定しません: $folder"
            }
            if (@(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter '*.tmp').Count) {
                throw "中断後に一時書庫が残っています: $folder"
            }
            Assert-InputsUnchanged $inputs 1 $folder
            $archives[$side] = @{
                Main = if ($exists) { (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash } else { '<absent>' }
                Retry = (Get-FileHash -LiteralPath $retry -Algorithm SHA256).Hash
            }
            $logs[$side] = @(Normalize-JoinRows $rows $folder $(if ($side -eq 'oracle') { 'oracle' } else { 'reimpl' }))
        }
        if ($archives.oracle.Main -cne $archives.reimpl.Main -or
            $archives.oracle.Retry -cne $archives.reimpl.Retry -or
            @(Compare-Object $logs.oracle $logs.reimpl -SyncWindow 0).Count) {
            throw "新規連結の中断・再利用が一致しません: UseMFile=$mapped/state=$abortState"
        }
        ++$comparisons
        ++$cancellations
    }
}

foreach ($path in $hashes.Keys) {
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $hashes[$path]) {
        throw "検証資産が変更されました: $path"
    }
}
if ($comparisons -ne 40 -or $publicationComparisons -ne 2 -or $cancellations -ne 12 -or
    $extendedPathComparisons -ne 1) {
    throw '連結進捗試験の比較件数が不正です。'
}
Write-Host "Join progress: $comparisons oracle comparisons passed; $publicationComparisons publication, $cancellations cancellation/reuse, and $extendedPathComparisons extended-path rejection cases, with archive/source/temp/handle checks"
