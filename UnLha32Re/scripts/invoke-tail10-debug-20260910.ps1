$ErrorActionPreference = 'Continue'
$script = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'tail10-continuation-20260910.ps1'))
$log = [IO.Path]::GetFullPath((Join-Path (Join-Path $PSScriptRoot '..') 'build\tail24-debug-20260911.log'))
try {
    & $script *>&1 | Tee-Object -FilePath $log
    $code = $LASTEXITCODE
    Add-Content -LiteralPath $log -Value "wrapper-exit=$code"
    exit $code
}
catch {
    $_ | Out-String -Width 4096 | Set-Content -LiteralPath $log
    Add-Content -LiteralPath $log -Value ("stack=" + $_.ScriptStackTrace)
    exit 1
}
