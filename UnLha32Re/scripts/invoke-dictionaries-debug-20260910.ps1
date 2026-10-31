$ErrorActionPreference = 'Continue'
$script = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-dictionaries.ps1'))
$root = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'build\dictionaries-retry-20260910'))
$log = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'build\dictionaries-retry-20260910.log'))
$test = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'artifacts\Release\CompatibilityTests.exe'))
$oracle = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'sample\ulh3300_extracted\UNLHA32.DLL'))
$candidate = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'artifacts\Release\UNLHA32RE.dll'))
& $script -TestProgram $test -Oracle $oracle -Candidate $candidate -Workspace $root *>&1 |
    Tee-Object -FilePath $log
$code = $LASTEXITCODE
Add-Content -LiteralPath $log -Value "wrapper-exit=$code"
exit $code
