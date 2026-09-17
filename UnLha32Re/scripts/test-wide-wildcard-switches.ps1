[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Workspace,
    [string[]]$CaseNames = @()
)
$ErrorActionPreference = 'Stop'
$TestProgram = (Resolve-Path -LiteralPath $TestProgram).Path
$Oracle = (Resolve-Path -LiteralPath $Oracle).Path
$Candidate = (Resolve-Path -LiteralPath $Candidate).Path
$runner = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $TestProgram) 'DesktopRunner.exe')).Path
$Workspace = [IO.Path]::GetFullPath($Workspace)
if (Test-Path -LiteralPath $Workspace) { throw 'Fresh workspace required' }
foreach ($script in 'test-enum-state.ps1','test-wide-compression-selection.ps1') {
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $script),[ref]$null,[ref]$parseErrors)
    if ($parseErrors.Count) { throw "Cannot parse helper: $script" }
    foreach ($name in 'Invoke-EnumProbe','Set-Input','Normalize-Result') {
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name },$true)
        if ($function) { . ([scriptblock]::Create($function.Extent.Text)) }
    }
}
$cases = @(
    @{Name='r1'; Options='-r1'}, @{Name='r'; Options='-r'}, @{Name='r-plus'; Options='-r+'},
    @{Name='d1'; Options='-d1'; Pattern='*'}, @{Name='d'; Options='-d'; Pattern='*'}, @{Name='d-plus'; Options='-d+'; Pattern='*'},
    @{Name='r-reset'; Options='-r1 -r0 -r'}, @{Name='r-response'; Options='-r+'; Response=$true}
)
foreach ($name in $CaseNames) { if ($name -cnotin $cases.Name) { throw "Unknown case: $name" } }
if ($CaseNames.Count) { $cases = @($cases | Where-Object Name -cin $CaseNames) }
New-Item -ItemType Directory -Path $Workspace | Out-Null
$hashes = @($TestProgram,$Oracle,$Candidate,$runner,$PSCommandPath | ForEach-Object {
    [pscustomobject]@{Path=$_; SHA256=(Get-FileHash -LiteralPath $_).Hash}
})
$hashes | ConvertTo-Json | Set-Content (Join-Path $Workspace 'binaries.json') -Encoding utf8
$count = 0
foreach ($case in $cases) {
    $pair = @()
    foreach ($side in 'oracle','reimpl') {
        $root = Join-Path $Workspace "$($case.Name)-$side"
        $source = Join-Path $root 'source'
        $nested = Join-Path $source 'nested'
        New-Item -ItemType Directory -Path $nested | Out-Null
        $inputPath = Join-Path $nested 'Ā.txt'
        Set-Input $inputPath 'wide-wildcard-payload' 2024
        $archive = Join-Path $root 'archive.lzh'
        $dll = if ($side -eq 'oracle') { $Oracle } else { $Candidate }
        # -d は -r2 と同じく、まずパターンに一致したディレクトリーをたどる。
        $pattern = if ($case.Pattern) { $case.Pattern } else { '*.txt' }
        $arguments = "-h2 -jm0 -n1 -gm1 -y1 -x1 $($case.Options) `"$archive`" `"$source\`" $pattern"
        if ($case.Response) {
            $response = Join-Path $root 'files.txt'
            # W 命令の BOM なし応答は UTF-16 として読む。明示 BOM と終端を付ける。
            [IO.File]::WriteAllText($response,($arguments + "`r`n"),[Text.UnicodeEncoding]::new($false,$true))
            $command = "a @`"$response`""
        } else { $command = "a $arguments" }
        $rows = @(Invoke-EnumProbe (Join-Path $root 'command') @('--base-command-probe',$dll,$command,'1041','0','W','none','0'))
        if ($rows -notcontains 'result=0') { throw "Wide recursive selection failed: $($case.Name)/$side`n$($rows -join "`n")" }
        foreach ($reader in 'oracle','reimpl') {
            $readerDll = if ($reader -eq 'oracle') { $Oracle } else { $Candidate }
            $payload = @(Invoke-EnumProbe (Join-Path $root "read-$reader") @('--base-command-probe',$readerDll,"p -n1 -gm1 `"$archive`" *",'1041','0','W','none','0'))
            if ($payload -notcontains 'result=0' -or $payload -notcontains 'output="wide-wildcard-payload"') { throw "Wide recursive payload differs: $($case.Name)/$side/$reader`n$($payload -join "`n")" }
        }
        if ([IO.File]::ReadAllText($inputPath) -cne 'wide-wildcard-payload') { throw 'Source changed' }
        $pair += ,@(Normalize-Result $rows $root)
    }
    $difference = @(Compare-Object $pair[0] $pair[1] -CaseSensitive -SyncWindow 0)
    if ($difference.Count) { throw "Wide recursive output/state differs: $($case.Name)`n$($difference | Out-String)" }
    $count++
    Write-Host "Wide recursive switches: passed $($case.Name) ($count)"
}
foreach ($entry in $hashes) { if ((Get-FileHash -LiteralPath $entry.Path).Hash -cne $entry.SHA256) { throw "Changed during test: $($entry.Path)" } }
Write-Host "Wide recursive switches: $count non-CP932 nested-leaf comparisons passed"
