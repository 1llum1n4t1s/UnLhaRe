[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$DesktopRunner = ''
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
if (!$DesktopRunner) { $DesktopRunner = Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe' }
$DesktopRunner = (Resolve-Path -LiteralPath $DesktopRunner).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw '専用の新しい試験ディレクトリーを指定してください。' }
New-Item -ItemType Directory -Path $Workspace | Out-Null
foreach ($path in $PSCommandPath,$TestProgram,$Candidate,$DesktopRunner) {
    Write-Host "$path SHA256=$((Get-FileHash -LiteralPath $path).Hash)"
}

function Invoke-SignalProbe([string]$Label, [string]$Command) {
    $start = [Diagnostics.ProcessStartInfo]::new($DesktopRunner)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $Workspace
    foreach ($argument in '--timeout-seconds','30',$TestProgram,'--registry','','--signal-handler-probe',$Candidate,$Command) {
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
        if ($timedOut -or $child.ExitCode -ne 0) {
            throw "SIGINT ハンドラープローブが失敗しました: $Label, exit=$($child.ExitCode)"
        }
        $rows = @($output -split '\r?\n')
        if ($rows -notcontains 'result=0' -or $rows -notcontains 'handler-preserved=1') {
            throw "DLL 呼び出し後にホストの SIGINT ハンドラーが保持されませんでした: $Label"
        }
    } finally { $child.Dispose() }
}

$inputDirectory = Join-Path $Workspace 'input'
$extractDirectory = Join-Path $Workspace 'extract'
New-Item -ItemType Directory -Path $inputDirectory,$extractDirectory | Out-Null
$payloadA = 'signal-handler-seed'
$payloadB = 'signal-handler-update'
[IO.File]::WriteAllText((Join-Path $inputDirectory 'a.txt'),$payloadA,[Text.Encoding]::ASCII)
[IO.File]::WriteAllText((Join-Path $inputDirectory 'b.txt'),$payloadB,[Text.Encoding]::ASCII)
$archive = Join-Path $Workspace 'signal.lzh'
$base = $inputDirectory.Replace('\','/') + '/'
$destination = $extractDirectory.Replace('\','/') + '/'
$seedCommand = "a -n1 -gm1 -y1 -h0 `"$archive`" `"$base`" a.txt"
$seed = & $DesktopRunner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Candidate $seedCommand 2>&1
if ($LASTEXITCODE -ne 0 -or $seed -notcontains 'result=0' -or !(Test-Path -LiteralPath $archive)) {
    throw 'SIGINT ハンドラー試験の元書庫を作成できません。'
}
Invoke-SignalProbe 'compress' "a -n1 -gm1 -y1 -h0 `"$archive`" `"$base`" b.txt"
Invoke-SignalProbe 'extract' "x -n1 -gm1 -y1 `"$archive`" `"$destination`""
$extractedA = Join-Path $extractDirectory 'a.txt'
$extractedB = Join-Path $extractDirectory 'b.txt'
if (!(Test-Path -LiteralPath $extractedA) -or !(Test-Path -LiteralPath $extractedB) -or
    [IO.File]::ReadAllText($extractedA) -cne $payloadA -or
    [IO.File]::ReadAllText($extractedB) -cne $payloadB) {
    throw '展開プローブの内容が一致しません。'
}
Write-Host 'SIGINT handler preservation: compression and extraction passed'
