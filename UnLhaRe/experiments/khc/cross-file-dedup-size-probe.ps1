#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkDirectory,[Parameter(Mandatory)][string]$ProbeExecutable)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw | ConvertFrom-Json
if([long]$record.max_bytes -ne 8MB -or [int]$record.max_entries -ne 64){throw 'CDC pilot requires 8 MiB / 64 entries; outer run-storage entry fixes 300 seconds'}
function Plain([string]$Path){
    $full=[IO.Path]::GetFullPath($Path)
    for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse point'}
    }
    return $full
}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
$paths=Get-KhcStorageTaskPaths
$work=Plain $WorkDirectory
$probe=Plain $ProbeExecutable
$probeRoot=[IO.Path]::GetFullPath($paths.CargoTargetRoot)+[IO.Path]::DirectorySeparatorChar
if(-not $probe.StartsWith($probeRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($probe) -cne 'khc_cross_file_dedup_probe.exe' -or -not(Test-Path -LiteralPath $probe -PathType Leaf)){throw 'Only the registered Cargo probe executable is allowed'}
if(Test-Path -LiteralPath $work){throw 'WorkDirectory must be new'}
$sourceZip=Plain (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\1547e376c0654f75baa4628242d672eb\recovery.zip')
$zipSha=Sha $sourceZip
if((Get-Item -LiteralPath $sourceZip).Length -ne 8265238 -or $zipSha -cne 'defd57199689ea58e6c74afc1b1879eab35bc66ac9d15abb64ebca5f9a4b49a3'){throw 'Pinned recovery ZIP mismatch'}
$names=@('plink-0.82.exe','plink-0.83.exe')
$sizes=@(856688,868976)
$hashes=@('a86180e9a7ac473ad52fbab2842a1554581c536dd6e112fae9c824dd1041af20','7308e9d356f14aa1f08cab1af363f71a077bf35dcb49e50b363418044758cd1e')
# 二入力と小さなJSON二つだけをrun workへ保存する。
if(($sizes[0]+$sizes[1]+2*32768) -gt 8MB){throw 'Output upper bound exceeds reservation'}
$null=New-Item -ItemType Directory -Path $work
$inputs=@($names | ForEach-Object {Plain (Join-Path $work $_)})
$reportPath=Plain (Join-Path $work 'probe.json')
$resultPath=Plain (Join-Path $work 'result.json')
$zip=[IO.Compression.ZipFile]::OpenRead($sourceZip)
try {
    for($i=0;$i -lt 2;$i++){
        $entryName='source/'+$names[$i]
        $matches=@($zip.Entries | Where-Object {$_.FullName -ceq $entryName})
        if($matches.Count -ne 1 -or $matches[0].Length -ne $sizes[$i]){throw 'Pinned ZIP member mismatch'}
        $source=$matches[0].Open()
        $target=[IO.File]::Open($inputs[$i],[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {
            $buffer=[byte[]]::new(65536); $written=0
            while(($read=$source.Read($buffer,0,$buffer.Length)) -gt 0){
                $written+=$read
                if($written -gt $sizes[$i]){throw 'ZIP member exceeds pinned length'}
                $target.Write($buffer,0,$read)
            }
        } finally {$target.Dispose();$source.Dispose()}
        if((Get-Item -LiteralPath $inputs[$i]).Length -ne $sizes[$i] -or (Sha $inputs[$i]) -cne $hashes[$i]){throw 'Pinned input hash mismatch'}
    }
} finally {$zip.Dispose()}
$sourceCode=Plain (Join-Path $PSScriptRoot '../../examples/khc_cross_file_dedup_probe.rs')
$scriptSource=Plain $PSCommandPath
$storageRunner=Plain (Join-Path $PSScriptRoot 'run-storage-experiment.ps1')
$storageModule=Plain (Join-Path $PSScriptRoot 'storage-lifecycle.psm1')
$sourceSha=Sha $sourceCode; $scriptSha=Sha $scriptSource; $storageRunnerSha=Sha $storageRunner; $moduleSha=Sha $storageModule; $probeSha=Sha $probe
$start=[Diagnostics.ProcessStartInfo]::new($probe)
$start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WorkingDirectory=$work
$start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
$start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
$start.Environment['TEMP']=$work; $start.Environment['TMP']=$work; $start.Environment['TMPDIR']=$work
foreach($argument in @($inputs[0],$inputs[1],$reportPath)){$start.ArgumentList.Add($argument)}
$process=[Diagnostics.Process]::new(); $process.StartInfo=$start
try {
    if(-not $process.Start()){throw 'Could not start CDC probe'}
    $stdoutTask=$process.StandardOutput.ReadToEndAsync(); $stderrTask=$process.StandardError.ReadToEndAsync()
    if(-not $process.WaitForExit(240000)){$process.Kill($true);if(-not $process.WaitForExit(5000)){throw 'Probe did not stop after timeout'};throw 'CDC probe exceeded 240 seconds'}
    $stdout=$stdoutTask.GetAwaiter().GetResult(); $stderr=$stderrTask.GetAwaiter().GetResult()
    if($process.ExitCode -ne 0){throw "CDC probe failed (exit $($process.ExitCode)): $stderr"}
    if($stdout.Length -ne 0 -or $stderr.Length -ne 0){throw 'Unexpected probe console output'}
} finally {$process.Dispose()}
$reportPath=Plain $reportPath
if(-not(Test-Path -LiteralPath $reportPath -PathType Leaf) -or (Get-Item -LiteralPath $reportPath).Length -gt 32768){throw 'Missing or oversized probe JSON'}
$r=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$fields=@('schema','input_bytes','input_sha256','e2e_checks_passed','roundtrip','deterministic','full_input_match','serialized_bytes','serialized_sha256','size_gate','decision')
if(@($r.PSObject.Properties.Name).Count -ne $fields.Count -or @($r.PSObject.Properties.Name | Where-Object {$_ -cnotin $fields}).Count -ne 0){throw 'Unexpected probe schema'}
if($r.schema -cne 1 -or $r.input_bytes.Count -ne 2 -or $r.input_sha256.Count -ne 2 -or $r.serialized_bytes.Count -ne 3 -or $r.serialized_sha256.Count -ne 3 -or $r.e2e_checks_passed -lt 40){throw 'Invalid probe fields'}
for($i=0;$i -lt 2;$i++){
    if($r.input_bytes[$i] -cne $sizes[$i] -or $r.input_sha256[$i] -cne $hashes[$i] -or (Sha $inputs[$i]) -cne $hashes[$i]){throw 'Input evidence mismatch'}
}
foreach($n in $r.serialized_bytes){if($n -isnot [long] -and $n -isnot [int]){throw 'Size is not an integer'};if($n -le 0 -or $n -gt 8MB){throw 'Serialized size cap'}}
foreach($h in $r.serialized_sha256){if($h -isnot [string] -or $h -cnotmatch '^[0-9a-f]{64}$'){throw 'Invalid archive digest'}}
if($r.roundtrip -isnot [bool] -or -not $r.roundtrip -or $r.deterministic -isnot [bool] -or -not $r.deterministic -or $r.full_input_match -isnot [bool] -or -not $r.full_input_match){throw 'Mandatory correctness gate failed'}
$gate=(20*[long]$r.serialized_bytes[2] -le 19*[long]$r.serialized_bytes[0]) -and ($r.serialized_bytes[2] -lt $r.serialized_bytes[1])
$decision=if($gate){'go'}else{'no-go'}
if($r.size_gate -isnot [bool] -or $r.size_gate -ne $gate -or $r.decision -cne $decision){throw 'Size gate evidence mismatch'}
if((Sha $sourceCode) -cne $sourceSha -or (Sha $scriptSource) -cne $scriptSha -or (Sha $storageRunner) -cne $storageRunnerSha -or (Sha $storageModule) -cne $moduleSha -or (Sha $probe) -cne $probeSha){throw 'Probe provenance changed during execution'}
Assert-KhcStorageContext -WorkDirectory $work
$result=[ordered]@{
    schema=1; scope='PuTTY Plink 0.82 to 0.83 development pair only; experimental KCD1 size-first pilot'
    source_names=$names; source_bytes=$sizes; source_sha256=$hashes; source_recovery_zip_sha256=$zipSha
    probe_source_sha256=$sourceSha; probe_executable_sha256=$probeSha; runner_source_sha256=$scriptSha
    storage_runner_sha256=$storageRunnerSha; storage_module_sha256=$moduleSha
    measurement='Complete serialized KCD1 bytes; no time, memory, 7-Zip, product, or holdout claim'; probe=$r
}
$json=$result | ConvertTo-Json -Depth 8
$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json)
if($bytes.Length -gt 32768){throw 'Result report exceeds 32 KiB'}
$stream=[IO.File]::Open($resultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$stream.Write($bytes)}finally{$stream.Dispose()}
Write-Output $json
