[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$DesktopRunner = '',
    [ValidateSet('legacy','A','W')][string[]]$Apis = @('legacy','A','W'),
    [int[]]$Priorities = @(-15,-2,-1,0,1,2,3),
    [ValidateSet(0,1)][int[]]$UnicodeModes = @(0,1)
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
if (!$DesktopRunner) { $DesktopRunner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe' }
$DesktopRunner = (Resolve-Path -LiteralPath $DesktopRunner).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '専用の新しい試験ディレクトリーを指定してください。' }
if (!$Apis.Count -or !$Priorities.Count -or !$UnicodeModes.Count) { throw '空の検証条件は指定できません。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
foreach ($path in $PSCommandPath,$TestProgram,$Oracle,$Candidate,$DesktopRunner) {
    Write-Host "$path SHA256=$((Get-FileHash -LiteralPath $path).Hash)"
}

function Invoke-PriorityProbe([string]$Label, [string[]]$ProbeArguments) {
    # 各プロセスを非表示デスクトップと空の HKCU に隔離し、標準出力を EOF まで回収する。
    $start = [Diagnostics.ProcessStartInfo]::new($DesktopRunner)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $Workspace
    foreach ($argument in @('--timeout-seconds','30',$TestProgram,'--registry','') + $ProbeArguments) {
        $start.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $timedOut = !$child.WaitForExit(40000)
        if ($timedOut) { $child.Kill($true); $child.WaitForExit() }
        $output = $stdout.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $Workspace "$Label.log"), $output)
        [IO.File]::WriteAllText((Join-Path $Workspace "$Label.stderr.log"), $stderr.GetAwaiter().GetResult())
        if ($timedOut -or $child.ExitCode -ne 0) { throw "優先度プローブが失敗しました: $Label, exit=$($child.ExitCode)" }
        return $output
    } finally { $child.Dispose() }
}

$inputPath = Join-Path $Workspace 'input'
New-Item -ItemType Directory -Path $inputPath | Out-Null
foreach ($entry in @(@('a.txt','first-payload'),@('m.txt','middle-payload'),@('z.txt',''))) {
    $path = Join-Path $inputPath $entry[0]
    [IO.File]::WriteAllText($path,$entry[1],[Text.Encoding]::ASCII)
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]'2020-01-02T03:04:06Z')
}
$archive = Join-Path $Workspace 'seed.lzh'
$base = $inputPath.Replace('\','/') + '/'
$seed = Invoke-PriorityProbe 'seed' @('--command-probe',$Oracle,"a -n1 -gm1 -y1 -h0 `"$archive`" `"$base`" a.txt m.txt z.txt")
if ($seed -notmatch '(?m)^result=0\r?$' -or !(Test-Path -LiteralPath $archive)) { throw '優先度試験の元書庫を作成できません。' }
$comparisons = 0
foreach ($utf8 in $UnicodeModes) { foreach ($api in $Apis) { foreach ($priority in $Priorities) {
    foreach ($kind in 'enum','memory') {
        $label = "$kind-$api-u$utf8-p$priority"
        $steps = @("@priority:$priority",'@thread-baseline:1','@audit-priority-calls')
        if ($kind -eq 'enum') {
            $steps += @("@archive-api:$api",'@first:*','@next','@close','@thread-priority',
                "@open-quiet:$archive",'@thread-priority','@first:*','@thread-priority',
                '@next','@next','@next','@next','@thread-priority','@close','@thread-priority')
        } else {
            $command = "@memory:`"$archive`" a.txt"
            $steps += @("@memory-api:$api",$command,'@thread-priority','@memory:','@thread-priority',
                '@memory-null-buffer',$command,'@thread-priority','@memory-valid-buffer',
                '@memory-zero-size',$command,'@thread-priority')
        }
        $results = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $output = Invoke-PriorityProbe "$label-$side" (@('--enum-sequence-probe',$dll,'w64','1041',"$utf8",'W') + $steps)
            $rows = @($output -split '\r?\n')
            $restored = @($rows -match '^thread-priority=')
            $expectedReads = if ($kind -eq 'enum') { 5 } else { 4 }
            if ($restored.Count -ne $expectedReads -or @($restored -ne 'thread-priority=1').Count) {
                throw "呼び出し前の優先度へ復元されませんでした: $label-$side"
            }
            if (@($rows -match '^priority-call=').Count -eq 0) { throw "優先度呼び出しを観測できません: $label-$side" }
            if ($kind -eq 'memory') {
                $expected = 'memory=0,written=13','memory=32811,written=0','memory=32844,written=0','memory=32844,written=0'
                if ((@($rows -match '^memory=') -join "`n") -cne ($expected -join "`n")) { throw "メモリ展開結果が不正です: $label-$side" }
            } elseif ($rows -notcontains 'open=1' -or $rows -notcontains 'first=0' -or $rows -notcontains 'next=-1') {
                throw "列挙の成功・EOFを確認できません: $label-$side"
            }
            $results += $output
        }
        if ($results[0] -cne $results[1]) { throw "原版との優先度ログが一致しません: $label" }
        $comparisons++
    }
} } }
$failureComparisons = 0
foreach ($utf8 in $UnicodeModes) { foreach ($api in $Apis) { foreach ($kind in 'enum','memory') {
    $callCount = if ($kind -eq 'enum') { 8 } else { 4 }
    for ($failedCall = 1; $failedCall -le $callCount; $failedCall++) {
        $label = "failure-$kind-$api-u$utf8-call$failedCall"
        $steps = @('@priority:-2','@thread-baseline:1','@audit-priority-calls',"@priority-fail:$failedCall")
        if ($kind -eq 'enum') {
            $steps += @("@archive-api:$api","@open-quiet:$archive",'@thread-priority',
                '@first:*','@thread-priority','@next','@thread-priority','@close','@thread-priority')
        } else {
            $steps += @("@memory-api:$api","@memory:`"$archive`" a.txt",'@thread-priority')
        }
        $results = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $output = Invoke-PriorityProbe "$label-$side" (@('--enum-sequence-probe',$dll,'w64','1041',"$utf8",'W') + $steps)
            $rows = @($output -split '\r?\n')
            if (@($rows -match '^priority-call=').Count -ne $callCount -or
                @($rows -match '^priority-call=.*result=0,').Count -ne 1) {
                throw "指定した優先度呼び出しの失敗を確認できません: $label-$side"
            }
            if ($kind -eq 'memory' -and $rows -notcontains 'memory=0,written=13') {
                throw "設定失敗時のメモリ展開結果が不正です: $label-$side"
            }
            $results += $output
        }
        # 復元自体が失敗したときは原版も元値へ戻らないため、正常時の復元保証とは分けて比較する。
        if ($results[0] -cne $results[1]) { throw "設定失敗時の原版ログと一致しません: $label" }
        $failureComparisons++
    }
} } }
$getFailureComparisons = 0
foreach ($utf8 in $UnicodeModes) { foreach ($api in $Apis) { foreach ($kind in 'enum','memory') {
    $getCount = if ($kind -eq 'enum') { 4 } else { 2 }
    for ($failedCall = 1; $failedCall -le $getCount; $failedCall++) {
        $label = "get-failure-$kind-$api-u$utf8-call$failedCall"
        $steps = @('@priority:-2','@thread-baseline:1','@audit-priority-calls',"@priority-get-fail:$failedCall")
        if ($kind -eq 'enum') {
            $steps += @("@archive-api:$api","@open-quiet:$archive",'@thread-priority',
                '@first:*','@thread-priority','@next','@thread-priority','@close','@thread-priority')
        } else {
            $steps += @("@memory-api:$api","@memory:`"$archive`" a.txt",'@thread-priority')
        }
        $results = @()
        foreach ($side in 'oracle','candidate') {
            $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
            $output = Invoke-PriorityProbe "$label-$side" (@('--enum-sequence-probe',$dll,'w64','1041',"$utf8",'W') + $steps)
            $rows = @($output -split '\r?\n')
            if (@($rows -match '^priority-get=').Count -ne $getCount -or
                @($rows -eq 'priority-get=2147483647').Count -ne 1) {
                throw "指定した優先度取得の失敗を確認できません: $label-$side"
            }
            if ($kind -eq 'memory' -and $rows -notcontains 'memory=0,written=13') {
                throw "取得失敗時のメモリ展開結果が不正です: $label-$side"
            }
            $results += $output
        }
        if ($results[0] -cne $results[1]) { throw "取得失敗時の原版ログと一致しません: $label" }
        $getFailureComparisons++
    }
} } }
$reentryComparisons = 0
foreach ($utf8 in $UnicodeModes) { foreach ($api in $Apis) { foreach ($pattern in 'a.txt','*') {
    $selection = if ($pattern -eq '*') { 'all' } else { 'first' }
    $label = "reentry-$api-u$utf8-$selection"
    $steps = @('@priority:-2','@thread-baseline:1','@audit-priority-calls',"@memory-api:$api",
        "@memory-reenter:-gm1 `"$archive`" a.txt","@memory:-gm1 `"$archive`" $pattern",'@thread-priority')
    $results = @()
    foreach ($side in 'oracle','candidate') {
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        $output = Invoke-PriorityProbe "$label-$side" (@('--enum-sequence-probe',$dll,'w64','1041',"$utf8",'W') + $steps)
        $rows = @($output -split '\r?\n')
        $expectedReentries = if ($pattern -eq '*') { 36 } else { 12 }
        $expectedBytes = if ($pattern -eq '*') { 27 } else { 13 }
        if (@($rows -match '^memory-reentry=').Count -ne $expectedReentries -or
            @($rows -match '^memory-reentry=.*result=32799,.*before=-2,after=-2$').Count -ne $expectedReentries -or
            @($rows -match '^priority-call=').Count -ne 4 -or
            $rows -notcontains "memory=0,written=$expectedBytes" -or $rows -notcontains 'thread-priority=1') {
            throw "メモリ再入時の拒否・優先度・外側の展開結果が不正です: $label-$side"
        }
        $results += $output
    }
    if ($results[0] -cne $results[1]) { throw "再入時の原版ログと一致しません: $label" }
    $reentryComparisons++
} } }
Write-Host "Thread priority: $comparisons normal, $failureComparisons set-failure, $getFailureComparisons get-failure, $reentryComparisons reentry full-log comparisons passed"
[pscustomobject]@{ Comparisons=$comparisons; FailureComparisons=$failureComparisons; GetFailureComparisons=$getFailureComparisons; ReentryComparisons=$reentryComparisons }
