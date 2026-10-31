#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkDirectory,
    [Parameter(Mandatory)][string]$KhcExecutable,
    [Parameter(Mandatory)][string]$E2eExecutable,
    [ValidateRange(10,300)][int]$TimeoutSeconds=120
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if($record.max_bytes -lt 5MB -or $record.max_entries -lt 64){throw 'Product KCS1/KRS3 E2E requires a registered 5MiB / 64 entry reservation'}
function Plain([string]$Path) {
    $p=[IO.Path]::GetFullPath($Path)
    for($q=$p;$q;$q=[IO.Path]::GetDirectoryName($q)) {
        if((Test-Path -LiteralPath $q) -and ((Get-Item -LiteralPath $q -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse point'}
    }
    return $p
}
$work=Plain $WorkDirectory
$cli=Plain $KhcExecutable
$e2e=Plain $E2eExecutable
if(Test-Path -LiteralPath $work){throw 'WorkDirectory must be unused'}
foreach($exe in @($cli,$e2e)){if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw "Missing prebuilt executable: $exe"}}
$null=New-Item -ItemType Directory -Path $work
$script:checks=[Collections.Generic.List[object]]::new()
function Child([string]$File,[string[]]$Arguments,[string]$Name,[bool]$Success=$true) {
    $info=[Diagnostics.ProcessStartInfo]::new($File)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$work
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.Environment['TMP']=$work;$info.Environment['TEMP']=$work
    foreach($a in $Arguments){$info.ArgumentList.Add($a)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false
    try {
        $started=$p.Start();if(-not $started){throw "Child start: $Name"}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while(-not $p.WaitForExit(100)){
            if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){$p.Kill($true);$p.WaitForExit();throw "$Name timeout"}
        }
        $p.WaitForExit();$out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        if($out.Length+$err.Length -gt 32768){throw "$Name output bound"}
        $script:checks.Add([ordered]@{name=$Name;exit_code=$p.ExitCode;stdout=$out;stderr=$err})
        if(($p.ExitCode -eq 0) -ne $Success){throw "$Name unexpected exit $($p.ExitCode): $err"}
        return $out
    } finally {if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
$api=Join-Path $work 'api'
$null=Child $e2e @($api) 'api-e2e'
$restored=[ordered]@{}
foreach($trial in @(
    @{revision=7;strategy='spatial-bits-trial';prefix=''},
    @{revision=8;strategy='record-adaptive-trial';prefix='adaptive-'}
)){
$source=Join-Path $api "$($trial.prefix)source"
$archive=Join-Path $work "cli-$($trial.revision).khc"
$output=Join-Path $work "cli-out-$($trial.revision)"
$null=Child $cli @('khc-create',$archive,'--source',$source,'--strategy',$trial.strategy) "cli-create-$($trial.revision)"
$archiveBytes=[IO.File]::ReadAllBytes($archive)
if($archiveBytes[8] -ne $trial.revision){throw 'CLI selected the wrong revision'}
if($trial.revision -eq 8){
    $frame=32+[BitConverter]::ToUInt32($archiveBytes,20)+4
    $frameLength=[BitConverter]::ToUInt32($archiveBytes,$frame-4)
    if([Text.Encoding]::ASCII.GetString($archiveBytes,$frame,8) -ne "KRS3BLK`0"){throw 'CLI did not select KRS3'}
    if([Text.Encoding]::ASCII.GetString($archiveBytes,$frame+$frameLength+12,8) -ne "KHC1BLK`0"){throw 'CLI did not preserve KHC1 fallback'}
}
$manifest=Child $cli @('khc-list',$archive,'--json') 'cli-list'
if(@($manifest | ConvertFrom-Json).Count -ne 3){throw 'CLI manifest count'}
$null=Child $cli @('khc-test',$archive) 'cli-test'
$null=Child $cli @('khc-extract',$archive,'--output',$output) 'cli-extract'
$hashes=[ordered]@{}
foreach($file in @('a-main.bin','empty.bin','short.bin')){
    $a=[IO.File]::ReadAllBytes((Join-Path $source $file));$b=[IO.File]::ReadAllBytes((Join-Path $output $file))
    if(-not [Linq.Enumerable]::SequenceEqual[byte]($a,$b)){throw "Byte mismatch: $file"}
    $before=(Get-FileHash -LiteralPath (Join-Path $source $file) -Algorithm SHA256).Hash
    $after=(Get-FileHash -LiteralPath (Join-Path $output $file) -Algorithm SHA256).Hash
    if($before -ne $after){throw "SHA mismatch: $file"};$hashes[$file]=$after.ToLowerInvariant()
}
$archiveHash=(Get-FileHash -LiteralPath $archive).Hash
$null=Child $cli @('khc-create',$archive,'--source',$source,'--strategy',$trial.strategy) 'cli-no-replace-create' $false
if((Get-FileHash -LiteralPath $archive).Hash -ne $archiveHash){throw 'Existing archive changed'}
$null=Child $cli @('khc-extract',$archive,'--output',$output) 'cli-no-replace-extract' $false
foreach($file in $hashes.Keys){if((Get-FileHash -LiteralPath (Join-Path $output $file)).Hash.ToLowerInvariant() -ne $hashes[$file]){throw 'Existing output changed'}}
$bad=Join-Path $api "$($trial.prefix)bad.khc"
$rejected=Join-Path $api "$($trial.prefix)rejected"
$null=Child $cli @('khc-test',$bad) 'cli-corrupt-test' $false
$null=Child $cli @('khc-extract',$bad,'--output',$rejected) 'cli-corrupt-extract' $false
if(@(Get-ChildItem -LiteralPath $rejected -Force).Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $rejected 'sentinel')) -ne 'keep'){throw 'Corrupt archive published output'}
$null=Child $cli @('khc-test',$archive) 'cli-reuse-after-corrupt'
$restored["revision-$($trial.revision)"]=$hashes
}
foreach($revision in @(1,2,3,4,5,6,7)){$null=Child $cli @('khc-test',(Join-Path $api "legacy-$revision.khc")) "cli-legacy-$revision"}
$report=[ordered]@{schema=1;scope='finite product KCS1/KRS3 correctness E2E; not a benchmark';cli_sha256=(Get-FileHash -LiteralPath $cli).Hash.ToLowerInvariant();e2e_sha256=(Get-FileHash -LiteralPath $e2e).Hash.ToLowerInvariant();restored_sha256=$restored;checks=@($script:checks.ToArray())}
$json=$report | ConvertTo-Json -Depth 8
if([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768){throw 'Report size bound'}
[IO.File]::WriteAllText((Join-Path $work 'result.json'),$json,[Text.UTF8Encoding]::new($false))
Write-Output $json
