[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string]$DesktopRunner = '',
    [ValidateRange(2,64)][int]$Workers = 16,
    [ValidateRange(1,100)][int]$Iterations = 20
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

$inputDirectory = Join-Path $Workspace 'input'
New-Item -ItemType Directory -Path $inputDirectory | Out-Null
[IO.File]::WriteAllText((Join-Path $inputDirectory 'a.txt'),'concurrent-entry-payload',[Text.Encoding]::ASCII)
$archive = Join-Path $Workspace 'concurrent.lzh'
$base = $inputDirectory.Replace('\','/') + '/'
$seedCommand = "a -n1 -gm1 -y1 -h0 `"$archive`" `"$base`" a.txt"
$seed = & $DesktopRunner --timeout-seconds 30 $TestProgram --registry '' --command-probe $Candidate $seedCommand 2>&1
if ($LASTEXITCODE -ne 0 -or $seed -notcontains 'result=0' -or !(Test-Path -LiteralPath $archive)) {
    throw '同時進入試験の元書庫を作成できません。'
}

$result = & $DesktopRunner --timeout-seconds 60 $TestProgram --registry '' --concurrent-entry-probe `
    $Candidate $archive $Workers $Iterations 2>&1
$result | Set-Content -LiteralPath (Join-Path $Workspace 'concurrent.log') -Encoding utf8
if ($LASTEXITCODE -ne 0 -or $result -notcontains "iterations=$Iterations,workers=$Workers,success=$Iterations,busy=$($Iterations * ($Workers - 1))") {
    throw '同一 DLL への同時進入が直列化されませんでした。'
}
Write-Host "Concurrent entry: $Iterations iterations x $Workers workers passed"
