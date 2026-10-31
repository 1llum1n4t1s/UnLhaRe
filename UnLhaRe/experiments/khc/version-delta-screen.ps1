#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('putty','7zr')][string]$Dataset,
    [Parameter(Mandatory)][string]$WorkDirectory,
    [string]$ToolCacheZip
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$work=[IO.Path]::GetFullPath($WorkDirectory)
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop
Assert-KhcStorageContext -WorkDirectory $work
$taskPaths=Get-KhcStorageTaskPaths
$sourceDir=Join-Path $work 'source'
$toolsDir=Join-Path $work 'tools'
$runDir=Join-Path $work 'runs'
foreach($path in @($sourceDir,$toolsDir,$runDir)) { $null=New-Item -ItemType Directory -Path $path -ErrorAction Stop }

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Copy-VerifiedCacheFile([object]$Archive,[object]$CacheManifest,[string]$EntryPath,[string]$Destination,[string]$ExpectedSha256) {
    $normalized=$EntryPath.Replace('\','/')
    $records=@($CacheManifest.files | Where-Object { ([string]$_.path).Replace('\','/') -ceq $normalized })
    $entries=@($Archive.Entries | Where-Object { $_.FullName -ceq $normalized })
    if($records.Count -ne 1 -or $entries.Count -ne 1 -or [long]$records[0].bytes -ne [long]$entries[0].Length) {
        throw "Verified tool cache is missing an unambiguous manifested file: $EntryPath"
    }
    if($ExpectedSha256 -and ([string]$records[0].sha256).ToLowerInvariant() -cne $ExpectedSha256.ToLowerInvariant()) {
        throw "Verified tool cache report hash disagrees with its manifest: $EntryPath"
    }
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force
    $input=$entries[0].Open()
    $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $input.CopyTo($output);$output.Flush($true) } finally { $output.Dispose();$input.Dispose() }
    $actual=Get-Sha256 $Destination
    if($actual -cne ([string]$records[0].sha256).ToLowerInvariant()) { throw "Copied tool cache file failed SHA-256 verification: $EntryPath" }
    [pscustomobject]@{source_entry=$normalized;work_path=[IO.Path]::GetRelativePath($work,$Destination);bytes=[long]$records[0].bytes;sha256=$actual}
}
function Get-Sha256Range([byte[]]$Bytes,[int]$Offset,[int]$Count) {
    $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        if($Count -gt 0) { $hash.AppendData($Bytes,$Offset,$Count) }
        [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    } finally { $hash.Dispose() }
}

function Update-ProcessMemoryPeaks([Diagnostics.Process]$Process,[long[]]$Peaks) {
    try {
        $Process.Refresh()
        $workingSet=$Process.PeakWorkingSet64
        $pagefile=$Process.PeakPagedMemorySize64
        if($null -ne $workingSet) { $Peaks[0]=[Math]::Max($Peaks[0],[long]$workingSet) }
        if($null -ne $pagefile) { $Peaks[1]=[Math]::Max($Peaks[1],[long]$pagefile) }
    } catch { }
}

function Assert-ProcessMemoryPeaks($Result,[string]$Label) {
    if([long]$Result.peak_working_set_bytes -le 0 -or [long]$Result.peak_pagefile_bytes -le 0) {
        throw "$Label exited before both OS process memory peaks were captured."
    }
}

function Invoke-Download([string]$Uri,[string]$Path,[long]$MaximumBytes) {
    if(Test-Path -LiteralPath $Path) { throw "Download target already exists: $Path" }
    Invoke-WebRequest -Uri $Uri -OutFile $Path -TimeoutSec 120 -MaximumRedirection 8
    $item=Get-Item -LiteralPath $Path
    if(-not $item.Length -or $item.Length -gt $MaximumBytes) { throw "Downloaded size outside cap: $Uri ($($item.Length) bytes)" }
    [pscustomobject]@{uri=$Uri;path=[IO.Path]::GetRelativePath($work,$Path);bytes=[long]$item.Length;sha256=(Get-Sha256 $Path)}
}

function Get-GitHubAsset([string]$Repository,[string]$Tag,[string]$AssetName,[string]$Destination,[long]$MaximumBytes) {
    $api="https://api.github.com/repos/$Repository/releases/tags/$Tag"
    $headers=@{'User-Agent'='UnLhaRe-version-delta-screen';'Accept'='application/vnd.github+json'}
    $release=Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 60
    $matches=@($release.assets | Where-Object { $_.name -ceq $AssetName })
    if($matches.Count -ne 1) { throw "Expected one official release asset $Repository/$Tag/$AssetName; found $($matches.Count)." }
    $asset=$matches[0]
    if([long]$asset.size -le 0 -or [long]$asset.size -gt $MaximumBytes) { throw "Official asset size outside cap: $AssetName" }
    $download=Invoke-Download ([string]$asset.browser_download_url) $Destination $MaximumBytes
    if([long]$download.bytes -ne [long]$asset.size) { throw "Official API/file size mismatch: $AssetName" }
    $digest=[string]$asset.digest
    if(-not [string]::IsNullOrWhiteSpace($digest)) {
        if($digest -cnotmatch '^sha256:([0-9a-fA-F]{64})$') { throw "Unsupported upstream digest format: $digest" }
        $expected=$Matches[1].ToLowerInvariant()
        if($download.sha256 -cne $expected) { throw "Official release SHA-256 mismatch: $AssetName" }
    } else { $expected=$null }
    [pscustomobject]@{uri=$download.uri;path=$download.path;bytes=$download.bytes;sha256=$download.sha256;upstream_digest=$digest;upstream_sha256=$expected;release_api=$api}
}

function Invoke-Program([string]$Path,[string[]]$CommandArguments,[string]$WorkingDirectory,[int]$DeadlineSeconds=180) {
    $info=[Diagnostics.ProcessStartInfo]::new($Path)
    $info.WorkingDirectory=$WorkingDirectory
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    foreach($argument in $CommandArguments) { $info.ArgumentList.Add([string]$argument) }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $timer=[Diagnostics.Stopwatch]::StartNew();$started=$false
    $stdoutTask=$null;$stderrTask=$null;$peaks=[long[]]::new(2)
    try {
        if(-not $process.Start()) { throw "Unable to start $Path" }
        $started=$true
        $stdoutTask=$process.StandardOutput.ReadToEndAsync()
        $stderrTask=$process.StandardError.ReadToEndAsync()
        Update-ProcessMemoryPeaks $process $peaks
        while(-not $process.WaitForExit(5)) {
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds) { throw "Process deadline exceeded: $Path" }
            Update-ProcessMemoryPeaks $process $peaks
        }
        $stdout=$stdoutTask.GetAwaiter().GetResult();$stderr=$stderrTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0) {
            $stdoutTail=if($stdout.Length -gt 6000){$stdout.Substring($stdout.Length-6000)}else{$stdout}
            $stderrTail=if($stderr.Length -gt 6000){$stderr.Substring($stderr.Length-6000)}else{$stderr}
            throw "Process exit $($process.ExitCode): $Path $($CommandArguments -join ' ')`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
        }
        [pscustomobject]@{stdout=$stdout;stderr=$stderr;exit_code=$process.ExitCode;wall_ms=$timer.Elapsed.TotalMilliseconds;cpu_ms=$process.TotalProcessorTime.TotalMilliseconds;peak_working_set_bytes=$peaks[0];peak_pagefile_bytes=$peaks[1]}
    } catch {
        if($started -and -not $process.HasExited) { $process.Kill($true);if(-not $process.WaitForExit(5000)) { throw 'Timed-out process tree did not stop.' } }
        throw
    } finally { $timer.Stop();$process.Dispose() }
}

function Invoke-BinaryProgram([string]$Path,[string[]]$CommandArguments,[string]$WorkingDirectory,[int]$DeadlineSeconds=180,[long]$MaximumOutputBytes=4MB) {
    $info=[Diagnostics.ProcessStartInfo]::new($Path)
    $info.WorkingDirectory=$WorkingDirectory
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    foreach($argument in $CommandArguments) { $info.ArgumentList.Add([string]$argument) }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    $timer=[Diagnostics.Stopwatch]::StartNew();$started=$false
    $stderrTask=$null;$copyTask=$null;$peaks=[long[]]::new(2)
    $memory=[IO.MemoryStream]::new()
    try {
        if(-not $process.Start()) { throw "Unable to start $Path" }
        $started=$true
        $stderrTask=$process.StandardError.ReadToEndAsync()
        $copyTask=$process.StandardOutput.BaseStream.CopyToAsync($memory)
        Update-ProcessMemoryPeaks $process $peaks
        while(-not $process.WaitForExit(5)) {
            if($timer.Elapsed.TotalSeconds -gt $DeadlineSeconds) { throw "Process deadline exceeded: $Path" }
            Update-ProcessMemoryPeaks $process $peaks
            if($memory.Length -gt $MaximumOutputBytes) { throw "Binary stdout exceeded its cap: $Path" }
        }
        $null=$copyTask.GetAwaiter().GetResult()
        $stderr=$stderrTask.GetAwaiter().GetResult()
        if($memory.Length -gt $MaximumOutputBytes) { throw "Binary stdout exceeded its cap: $Path" }
        if($process.ExitCode -ne 0) {
            $stderrTail=if($stderr.Length -gt 6000){$stderr.Substring($stderr.Length-6000)}else{$stderr}
            throw "Process exit $($process.ExitCode): $Path $($CommandArguments -join ' ')`nSTDERR:`n$stderrTail"
        }
        $bytes=$memory.ToArray()
        [pscustomobject]@{bytes=$bytes;byte_count=[long]$bytes.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant();exit_code=$process.ExitCode;wall_ms=$timer.Elapsed.TotalMilliseconds;cpu_ms=$process.TotalProcessorTime.TotalMilliseconds;peak_working_set_bytes=$peaks[0];peak_pagefile_bytes=$peaks[1]}
    } catch {
        if($started -and -not $process.HasExited) { $process.Kill($true);if(-not $process.WaitForExit(5000)) { throw 'Timed-out process tree did not stop.' } }
        throw
    } finally { $timer.Stop();$memory.Dispose();$process.Dispose() }
}

function Read-JsonLine([string]$Text,[string]$What) {
    try { $Text.Trim() | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$What did not return valid JSON: $Text" }
}

function Assert-Hash([string]$Path,[string]$Expected,[string]$Label) {
    $actual=Get-Sha256 $Path
    if($actual -cne $Expected.ToLowerInvariant()) { throw "$Label SHA-256 mismatch: $actual" }
    $actual
}

function Get-Median([double[]]$Values) {
    $ordered=@($Values | Sort-Object)
    if($ordered.Count -eq 0) { throw 'Median requires samples.' }
    if($ordered.Count % 2) { return [double]$ordered[[int]($ordered.Count/2)] }
    return ([double]$ordered[$ordered.Count/2-1]+[double]$ordered[$ordered.Count/2])/2
}

$cargoScript=Join-Path $PSScriptRoot 'run-serial-cargo.ps1'
$pwsh=(Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$cargoCommand="& '$($cargoScript.Replace("'","''"))' -TransientMiB 512 -CargoArguments @('build','--locked','--offline','--release','--example','khc_version_delta')"
$cargoArguments=@('-NoProfile','-Command',$cargoCommand)
$cargo=Invoke-Program $pwsh $cargoArguments $repoRoot 180
$probePath=Join-Path $taskPaths.CargoTargetRoot 'release/examples/khc_version_delta.exe'
if(-not (Test-Path -LiteralPath $probePath -PathType Leaf)) { throw 'Cargo did not produce the registered probe executable.' }
$selfCheck=Invoke-Program $probePath @('self-check') $work 180
$selfCheckReport=Read-JsonLine $selfCheck.stdout 'KHC delta self-check'
if($selfCheckReport.self_check -cne 'passed' -or [int]$selfCheckReport.checks -lt 10) { throw 'KHC delta self-check was incomplete.' }

$sourceEvidence=[Collections.Generic.List[object]]::new()
$metadata=[ordered]@{}
if($Dataset -eq 'putty') {
    $spec=[ordered]@{
        base=[ordered]@{version='0.82';name='plink-0.82.exe';url='https://the.earth.li/~sgtatham/putty/0.82/w32/plink.exe';manifest='https://the.earth.li/~sgtatham/putty/0.82/sha256sums';bytes=856688;sha256='a86180e9a7ac473ad52fbab2842a1554581c536dd6e112fae9c824dd1041af20'}
        target=[ordered]@{version='0.83';name='plink-0.83.exe';url='https://the.earth.li/~sgtatham/putty/0.83/w32/plink.exe';manifest='https://the.earth.li/~sgtatham/putty/0.83/sha256sums';bytes=868976;sha256='7308e9d356f14aa1f08cab1af363f71a077bf35dcb49e50b363418044758cd1e'}
    }
    foreach($key in @('base','target')) {
        $item=$spec[$key]
        $manifestPath=Join-Path $sourceDir "putty-$($item.version)-sha256sums.txt"
        $manifestEvidence=Invoke-Download $item.manifest $manifestPath 1MB
        $null=$sourceEvidence.Add($manifestEvidence)
        $manifestText=Get-Content -LiteralPath $manifestPath -Raw
        if($manifestText -notmatch "(?m)^$($item.sha256)\s+w32/plink\.exe\s*$") { throw "PuTTY official checksum manifest does not contain the expected w32/plink.exe hash for $($item.version)." }
        $path=Join-Path $sourceDir $item.name
        $download=Invoke-Download $item.url $path 2MB
        if([long]$download.bytes -ne [long]$item.bytes) { throw "PuTTY published byte length mismatch: $($item.name)" }
        $null=Assert-Hash $path $item.sha256 "PuTTY $($item.version)"
        $null=$sourceEvidence.Add([pscustomobject]@{uri=$download.uri;path=$download.path;bytes=$download.bytes;sha256=$download.sha256;manifest=$manifestEvidence.path;official_sha256=$item.sha256})
    }
    $metadata.dataset='PuTTY Plink x86 0.82 → 0.83'
    $metadata.architecture='x86'
    $metadata.base_version='0.82';$metadata.target_version='0.83'
} else {
    $spec=[ordered]@{
        base=[ordered]@{version='24.09';name='7zr-24.09.exe';url='https://github.com/ip7z/7zip/releases/download/24.09/7zr.exe';bytes=593408;sha256=$null}
        target=[ordered]@{version='25.01';name='7zr-25.01.exe';url='https://github.com/ip7z/7zip/releases/download/25.01/7zr.exe';bytes=601088;sha256='27cbe3d5804ad09e90bbcaa916da0d5c3b0be9462d0e0fb6cb54be5ed9030875'}
    }
    foreach($key in @('base','target')) {
        $item=$spec[$key]
        $dest=Join-Path $sourceDir $item.name
        $api="https://api.github.com/repos/ip7z/7zip/releases/tags/$($item.version)"
        $headers=@{'User-Agent'='UnLhaRe-version-delta-screen';'Accept'='application/vnd.github+json'}
        $release=Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 60
        $assetMatches=@($release.assets | Where-Object { $_.name -ceq '7zr.exe' })
        if($assetMatches.Count -ne 1 -or [long]$assetMatches[0].size -ne [long]$item.bytes -or [string]$assetMatches[0].browser_download_url -cne $item.url) { throw "Official 7-Zip release metadata mismatch for 7zr $($item.version)." }
        $download=Invoke-Download $item.url $dest 2MB
        if([long]$download.bytes -ne [long]$item.bytes) { throw "7zr published byte length mismatch: $($item.version)" }
        if($item.sha256) { $null=Assert-Hash $dest $item.sha256 "7zr $($item.version)" }
        $null=$sourceEvidence.Add([pscustomobject]@{uri=$download.uri;path=$download.path;bytes=$download.bytes;sha256=$download.sha256;release_api=$api;official_digest=[string]$assetMatches[0].digest;official_sha256=$item.sha256})
    }
    $metadata.dataset='7-Zip 7zr x86 24.09 → 25.01'
    $metadata.architecture='x86'
    $metadata.base_version='24.09';$metadata.target_version='25.01'
    $metadata.base_sha256_upstream='unavailable; official API digest is null'
}
$basePath=Join-Path $sourceDir $spec.base.name
$targetPath=Join-Path $sourceDir $spec.target.name
$baseHash=Get-Sha256 $basePath
$targetHash=Get-Sha256 $targetPath

$toolCacheEvidence=$null
if(-not [string]::IsNullOrWhiteSpace($ToolCacheZip)) {
    $cachePath=[IO.Path]::GetFullPath($ToolCacheZip)
    if(-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) { throw "Tool cache recovery ZIP is missing: $cachePath" }
    $localData=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $cacheRoot=[IO.Path]::GetFullPath((Join-Path (Join-Path (Join-Path $localData 'Codex\TaskArtifacts') 'UnLhaRe') 'storage-lifecycle')).TrimEnd([char[]]@(92,47)) + [IO.Path]::DirectorySeparatorChar
    if(-not $cachePath.StartsWith($cacheRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Tool cache must be read from the retained UnLhaRe storage-lifecycle TaskArtifacts tree.' }
    if($cachePath.StartsWith($work.TrimEnd([char[]]@(92,47))+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'Tool cache cannot be inside the current registered work directory.' }
    $cacheManifestPath=Join-Path (Split-Path -Parent $cachePath) 'recovery.json'
    if(-not (Test-Path -LiteralPath $cacheManifestPath -PathType Leaf)) { throw 'Tool cache recovery.json manifest is missing.' }
    $cacheManifest=Get-Content -LiteralPath $cacheManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if([int]$cacheManifest.schema -ne 1 -or (Get-Sha256 $cachePath) -cne ([string]$cacheManifest.backup_sha256).ToLowerInvariant()) { throw 'Tool cache ZIP does not match its recovery manifest.' }
    $cacheArchive=[IO.Compression.ZipFile]::OpenRead($cachePath)
    try {
        $reportEntry=$cacheArchive.GetEntry('version-delta-screen.json')
        if($null -eq $reportEntry) { throw 'Tool cache screen report is missing.' }
        $reader=[IO.StreamReader]::new($reportEntry.Open())
        try { $cacheReport=$reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
        $cacheTools=$cacheReport.tools
        if([string]$cacheTools.seven_zip_version -cne '26.04' -or [string]$cacheTools.zstd_version -cne '1.5.7' -or [string]$cacheReport.dataset -notmatch '^PuTTY Plink') { throw 'Tool cache report is not the verified PuTTY screen with the required comparator versions.' }
        $sevenEntry=([string]$cacheTools.seven_zip_path).Replace('\','/')
        $zstdEntry=([string]$cacheTools.zstd_path).Replace('\','/')
        if($sevenEntry -cne 'tools/7zip-extra/x64/7za.exe' -or $zstdEntry -cne 'tools/zstd-1.5.7/zstd.exe') { throw 'Tool cache report uses unexpected binary paths.' }
        $sevenDir=Join-Path (Join-Path $toolsDir '7zip-extra') 'x64'
        $zstdDir=Join-Path $toolsDir 'zstd-1.5.7'
        $copied=[Collections.Generic.List[object]]::new()
        foreach($name in @('7za.exe','7za.dll','7zxa.dll')) {
            $source="tools/7zip-extra/x64/$name"; $destination=Join-Path $sevenDir $name
            $expected=if($name -ceq '7za.exe') { [string]$cacheTools.seven_zip_sha256 } else { $null }
            $null=$copied.Add((Copy-VerifiedCacheFile $cacheArchive $cacheManifest $source $destination $expected))
        }
        $null=$copied.Add((Copy-VerifiedCacheFile $cacheArchive $cacheManifest 'tools/7zip-extra/License.txt' (Join-Path (Join-Path $toolsDir '7zip-extra') 'License.txt') $null))
        $zstdPath=Join-Path $zstdDir 'zstd.exe'
        $null=$copied.Add((Copy-VerifiedCacheFile $cacheArchive $cacheManifest $zstdEntry $zstdPath $null))
        $sevenZip=Join-Path $sevenDir '7za.exe'
        $toolCacheEvidence=[ordered]@{mode='verified-reuse';source_run_id=[string]$cacheManifest.run_id;source_recovery_zip=$cachePath;source_recovery_zip_sha256=Get-Sha256 $cachePath;source_manifest_sha256=Get-Sha256 $cacheManifestPath;source_dataset=[string]$cacheReport.dataset;source_assets=[ordered]@{seven_zip_extra=$cacheTools.extra;zstd=$cacheTools.zstd_zip};copied_files=$copied.ToArray()}
        $bootstrap=[pscustomobject]@{uri=[string]$cacheTools.bootstrap.url;bytes=[long]$cacheTools.bootstrap.bytes;sha256=[string]$cacheTools.bootstrap.sha256;upstream_digest=[string]$cacheTools.bootstrap.upstream_digest}
        $extra=[pscustomobject]@{uri=[string]$cacheTools.extra.url;bytes=[long]$cacheTools.extra.bytes;sha256=[string]$cacheTools.extra.sha256;upstream_digest=[string]$cacheTools.extra.upstream_digest}
        $zstdEvidence=[pscustomobject]@{uri=[string]$cacheTools.zstd_zip.url;bytes=[long]$cacheTools.zstd_zip.bytes;sha256=[string]$cacheTools.zstd_zip.sha256;upstream_digest=[string]$cacheTools.zstd_zip.upstream_digest}
    } finally { $cacheArchive.Dispose() }
    $sevenProbe=Invoke-Program $sevenZip @('i') $work 30
    if($sevenProbe.stdout -notmatch '(?m)^7-Zip \(a\) 26\.04(?:\s|$)') { throw 'Cached x64 console binary did not identify itself as 7-Zip 26.04.' }
    $sevenVersion='26.04'
} else {
$bootstrap=Get-GitHubAsset 'ip7z/7zip' '26.04' '7zr.exe' (Join-Path $toolsDir '7zr-26.04.exe') 2MB
$extra=Get-GitHubAsset 'ip7z/7zip' '26.04' '7z2604-extra.7z' (Join-Path $toolsDir '7z2604-extra.7z') 8MB
$extraDir=Join-Path $toolsDir '7zip-extra'
$null=New-Item -ItemType Directory -Path $extraDir
$bootstrapPath=Join-Path $work $bootstrap.path
$extraPath=Join-Path $work $extra.path
$extractResult=Invoke-Program $bootstrapPath @('x',$extraPath,"-o$extraDir",'-y','x64\7za.exe','x64\7za.dll','x64\7zxa.dll','License.txt') $work 120
$sevenCandidates=@(Get-ChildItem -LiteralPath $extraDir -Recurse -File | Where-Object { $_.Name -ceq '7za.exe' -and $_.FullName -match '[\\/]x64[\\/]' })
if($sevenCandidates.Count -eq 0) { throw 'Official 7-Zip Extra archive did not contain an x64 console binary.' }
$sevenSupportFiles=@(Get-ChildItem -LiteralPath $extraDir -Recurse -File)
foreach($required in @('7za.exe','7za.dll','7zxa.dll','License.txt')) { if(@($sevenSupportFiles | Where-Object { $_.Name -ceq $required }).Count -ne 1) { throw "Selective 7-Zip extraction missed required x64 file/license: $required" } }
$sevenZip=$null;$sevenVersion=$null
foreach($candidate in $sevenCandidates) {
    $probe=Invoke-Program $candidate.FullName @('i') $work 30
    if($probe.stdout -match '(?m)^7-Zip (?:\(a\) )?26\.04(?:\s|$)') { $sevenZip=$candidate.FullName;$sevenVersion='26.04';break }
}
if(-not $sevenZip) { throw 'No extracted x64 console binary identified itself as 7-Zip 26.04.' }
$zstdEvidence=Get-GitHubAsset 'facebook/zstd' 'v1.5.7' 'zstd-v1.5.7-win64.zip' (Join-Path $toolsDir 'zstd-v1.5.7-win64.zip') 8MB
$zstdDir=Join-Path $toolsDir 'zstd-1.5.7'
$null=New-Item -ItemType Directory -Path $zstdDir
$zstdArchive=[IO.Compression.ZipFile]::OpenRead((Join-Path $work $zstdEvidence.path))
try {
    $zstdEntries=@($zstdArchive.Entries | Where-Object {
        if($_.FullName.EndsWith('/')) { return $false }
        $leaf=[IO.Path]::GetFileName($_.FullName)
        $leaf -ieq 'zstd.exe' -or $leaf -match '^(?i:LICENSE|COPYING)(\.[^.]*)?$'
    })
    $zstdBinaries=@($zstdEntries | Where-Object { [IO.Path]::GetFileName($_.FullName) -ieq 'zstd.exe' })
    if($zstdBinaries.Count -ne 1 -or [long](($zstdEntries | Measure-Object -Property Length -Sum).Sum) -gt 4MB) { throw 'Official zstd ZIP binary/license selection is missing or exceeds the extraction cap.' }
    foreach($entry in $zstdEntries) {
        $destination=Join-Path $zstdDir ([IO.Path]::GetFileName($entry.FullName))
        $input=$entry.Open();$output=[IO.File]::Open($destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try { $input.CopyTo($output);$output.Flush($true) } finally { $output.Dispose();$input.Dispose() }
    }
} finally { $zstdArchive.Dispose() }
}
$zstd=Join-Path $zstdDir 'zstd.exe'
$zstdVersionResult=Invoke-Program $zstd @('--version') $work 30
if($zstdVersionResult.stdout -notmatch '(?m)\bv1\.5\.7\b') { throw "Unexpected zstd version: $($zstdVersionResult.stdout)" }

$sourceBytes=[long](Get-Item -LiteralPath $basePath).Length+[long](Get-Item -LiteralPath $targetPath).Length
$pairName=$Dataset
$sampleRoot=Join-Path $runDir $pairName
$null=New-Item -ItemType Directory -Path $sampleRoot
$artifactDir=Join-Path $sampleRoot 'artifacts'
$null=New-Item -ItemType Directory -Path $artifactDir
$khcFrame=Join-Path $artifactDir 'candidate.khcd'
$sevenArchive=Join-Path $artifactDir '7zip-pair.7z'
$zstdBase=Join-Path $artifactDir 'zstd-base.zst'
$zstdPatch=Join-Path $artifactDir 'zstd-patch.zst'
$metadataFee=48+[Text.Encoding]::UTF8.GetByteCount($spec.base.name)+[Text.Encoding]::UTF8.GetByteCount($spec.target.name)
$sampleResults=[Collections.Generic.List[object]]::new()
for($repeat=1;$repeat -le 3;$repeat++) {
    $khcEncoded=Invoke-Program $probePath @('encode-overwrite',$basePath,$targetPath,$khcFrame) $work 600
    Assert-ProcessMemoryPeaks $khcEncoded "KHC encode repeat $repeat"
    $khcEncodeData=Read-JsonLine $khcEncoded.stdout 'KHC delta encode'
    if([long]$khcEncodeData.frame_bytes -ne [long](Get-Item -LiteralPath $khcFrame).Length) { throw 'KHC delta frame size report mismatch.' }

    if($repeat -gt 1) {
        $null=Invoke-Program $sevenZip @('d',$sevenArchive,'*','-y') $work 120
        if(Test-Path -LiteralPath $sevenArchive) {
            $emptyCheck=Invoke-Program $sevenZip @('l','-slt',$sevenArchive) $work 30
            $archivePathLines=[regex]::Matches($emptyCheck.stdout,'(?m)^Path = ').Count
            if($archivePathLines -gt 1) { throw "7-Zip repeat reset left $($archivePathLines-1) archive members." }
        }
    }
    $sevenEncoded=Invoke-Program $sevenZip @('a','-t7z','-mx=9','-mmt=1','-ms=on','-m0=LZMA2:d=64m',$sevenArchive,$spec.base.name,$spec.target.name) $sourceDir 600
    Assert-ProcessMemoryPeaks $sevenEncoded "7-Zip encode repeat $repeat"

    $zstdBaseEncode=Invoke-BinaryProgram $zstd @('-19','-T1','-c',$basePath) $work 600 2MB
    $zstdPatchEncode=Invoke-BinaryProgram $zstd @('-19','-T1','-c',"--patch-from=$basePath",$targetPath) $work 600 2MB
    Assert-ProcessMemoryPeaks $zstdBaseEncode "zstd base encode repeat $repeat"
    Assert-ProcessMemoryPeaks $zstdPatchEncode "zstd patch encode repeat $repeat"
    if($repeat -eq 3) {
        [IO.File]::WriteAllBytes($zstdBase,$zstdBaseEncode.bytes)
        [IO.File]::WriteAllBytes($zstdPatch,$zstdPatchEncode.bytes)
        $lastZstdBase=$zstdBase;$lastZstdPatch=$zstdPatch
    }

    $sevenSize=[long](Get-Item -LiteralPath $sevenArchive).Length
    $khcSize=[long](Get-Item -LiteralPath $khcFrame).Length
    $khcFrameHash=Get-Sha256 $khcFrame
    $sevenArchiveHash=Get-Sha256 $sevenArchive
    $zstdBytes=[long]$zstdBaseEncode.byte_count+[long]$zstdPatchEncode.byte_count+$metadataFee
    $sampleResults.Add([pscustomobject]@{
        repeat=$repeat
        source_bytes=$sourceBytes
        sizes=[ordered]@{khc_delta=$khcSize;seven_zip=$sevenSize;zstd_patch_pair=$zstdBytes;zstd_base_frame=$zstdBaseEncode.byte_count;zstd_patch_frame=$zstdPatchEncode.byte_count;zstd_shared_metadata_fee=$metadataFee}
        khc=[ordered]@{mode=[int]$khcEncodeData.mode;operations=[int]$khcEncodeData.operations;patch_stream_bytes=[long]$khcEncodeData.patch_stream_bytes;encode=$khcEncoded;frame=$khcFrame;frame_sha256=$khcFrameHash}
        seven_zip=[ordered]@{archive=$sevenEncoded;archive_path=$sevenArchive;archive_sha256=$sevenArchiveHash}
        zstd=[ordered]@{base_encode=[pscustomobject]@{byte_count=$zstdBaseEncode.byte_count;sha256=$zstdBaseEncode.sha256;wall_ms=$zstdBaseEncode.wall_ms;cpu_ms=$zstdBaseEncode.cpu_ms;peak_working_set_bytes=$zstdBaseEncode.peak_working_set_bytes;peak_pagefile_bytes=$zstdBaseEncode.peak_pagefile_bytes};patch_encode=[pscustomobject]@{byte_count=$zstdPatchEncode.byte_count;sha256=$zstdPatchEncode.sha256;wall_ms=$zstdPatchEncode.wall_ms;cpu_ms=$zstdPatchEncode.cpu_ms;peak_working_set_bytes=$zstdPatchEncode.peak_working_set_bytes;peak_pagefile_bytes=$zstdPatchEncode.peak_pagefile_bytes};base_path=$zstdBase;patch_path=$zstdPatch}
    })
    $zstdBaseEncode=$null;$zstdPatchEncode=$null
}

$sizeKeys=@('khc_delta','seven_zip','zstd_patch_pair')
foreach($key in $sizeKeys) {
    $values=@($sampleResults | ForEach-Object { [long]$_.sizes[$key] } | Select-Object -Unique)
    if($values.Count -ne 1) { throw "Nondeterministic archive size for ${key}: $($values -join ',')" }
}
$khcHashes=@($sampleResults | ForEach-Object { $_.khc.frame_sha256 } | Select-Object -Unique)
$sevenHashes=@($sampleResults | ForEach-Object { $_.seven_zip.archive_sha256 } | Select-Object -Unique)
$zstdHashes=@($sampleResults | ForEach-Object { "$($_.zstd.base_encode.sha256):$($_.zstd.patch_encode.sha256)" } | Select-Object -Unique)
if($khcHashes.Count -ne 1 -or $sevenHashes.Count -ne 1 -or $zstdHashes.Count -ne 1) { throw 'Repeated encodes produced nondeterministic output hashes.' }
$khcEncodeMs=@($sampleResults | ForEach-Object { [double]$_.khc.encode.wall_ms })
$sevenEncodeMs=@($sampleResults | ForEach-Object { [double]$_.seven_zip.archive.wall_ms })
$zstdEncodeMs=@($sampleResults | ForEach-Object { [double]$_.zstd.base_encode.wall_ms+[double]$_.zstd.patch_encode.wall_ms })
$lastKhcFrame=$sampleResults[2].khc.frame
$lastSevenArchive=$sampleResults[2].seven_zip.archive_path
$baseLength=[int](Get-Item -LiteralPath $basePath).Length
$targetLength=[int](Get-Item -LiteralPath $targetPath).Length
$khcDecodeSamples=[Collections.Generic.List[object]]::new()
for($repeat=1;$repeat -le 3;$repeat++) {
    $khcDecode=Invoke-BinaryProgram $probePath @('decode-stdout',$lastKhcFrame) $work 600 2MB
    Assert-ProcessMemoryPeaks $khcDecode "KHC decode repeat $repeat"
    if([long]$khcDecode.byte_count -ne ($baseLength+$targetLength)) { throw 'KHC stdout decode returned an unexpected pair length.' }
    $decodedBaseHash=Get-Sha256Range $khcDecode.bytes 0 $baseLength
    $decodedTargetHash=Get-Sha256Range $khcDecode.bytes $baseLength $targetLength
    if($decodedBaseHash -cne $baseHash -or $decodedTargetHash -cne $targetHash) { throw 'KHC stdout decode did not reproduce both original members.' }
    $khcDecodeSamples.Add([pscustomobject]@{wall_ms=$khcDecode.wall_ms;cpu_ms=$khcDecode.cpu_ms;peak_working_set_bytes=$khcDecode.peak_working_set_bytes;peak_pagefile_bytes=$khcDecode.peak_pagefile_bytes;output_bytes=$khcDecode.byte_count;base_sha256=$decodedBaseHash;target_sha256=$decodedTargetHash})
    $khcDecode=$null
}
$sevenTest=Invoke-Program $sevenZip @('t',$lastSevenArchive) $work 300
$sevenDecodeSamples=[Collections.Generic.List[object]]::new()
for($repeat=1;$repeat -le 3;$repeat++) {
    $sevenPairDecode=Invoke-BinaryProgram $sevenZip @('e','-so',$lastSevenArchive) $work 600 2MB
    Assert-ProcessMemoryPeaks $sevenPairDecode "7-Zip decode repeat $repeat"
    if([long]$sevenPairDecode.byte_count -ne ($baseLength+$targetLength)) { throw '7-Zip stdout extraction returned an unexpected pair length.' }
    $firstHash=Get-Sha256Range $sevenPairDecode.bytes 0 $baseLength
    $secondHash=Get-Sha256Range $sevenPairDecode.bytes $baseLength $targetLength
    if($firstHash -ceq $baseHash -and $secondHash -ceq $targetHash) { $memberOrder='base,target' }
    elseif($firstHash -ceq $targetHash -and $secondHash -ceq $baseHash) { $memberOrder='target,base' }
    else { throw '7-Zip stdout extraction did not reproduce both original members.' }
    $sevenDecodeSamples.Add([pscustomobject]@{wall_ms=$sevenPairDecode.wall_ms;cpu_ms=$sevenPairDecode.cpu_ms;peak_working_set_bytes=$sevenPairDecode.peak_working_set_bytes;peak_pagefile_bytes=$sevenPairDecode.peak_pagefile_bytes;output_bytes=$sevenPairDecode.byte_count;member_order=$memberOrder;first_sha256=$firstHash;second_sha256=$secondHash})
    $sevenPairDecode=$null
}
$zstdDecodeSamples=[Collections.Generic.List[object]]::new()
for($repeat=1;$repeat -le 3;$repeat++) {
    $zstdBaseDecode=Invoke-BinaryProgram $zstd @('-d','-c',$lastZstdBase) $work 300 2MB
    Assert-ProcessMemoryPeaks $zstdBaseDecode "zstd base decode repeat $repeat"
    if([long]$zstdBaseDecode.byte_count -ne $baseLength -or $zstdBaseDecode.sha256 -cne $baseHash) { throw 'zstd base stdout decode did not reproduce the original base.' }
    $zstdPatchDecode=Invoke-BinaryProgram $zstd @('-d','-c',"--patch-from=$basePath",$lastZstdPatch) $work 300 2MB
    Assert-ProcessMemoryPeaks $zstdPatchDecode "zstd patch decode repeat $repeat"
    if([long]$zstdPatchDecode.byte_count -ne $targetLength -or $zstdPatchDecode.sha256 -cne $targetHash) { throw 'zstd patch stdout decode did not reproduce the original target.' }
    $zstdDecodeSamples.Add([pscustomobject]@{
        base=[pscustomobject]@{wall_ms=$zstdBaseDecode.wall_ms;cpu_ms=$zstdBaseDecode.cpu_ms;peak_working_set_bytes=$zstdBaseDecode.peak_working_set_bytes;peak_pagefile_bytes=$zstdBaseDecode.peak_pagefile_bytes;output_bytes=$zstdBaseDecode.byte_count;sha256=$zstdBaseDecode.sha256}
        patch=[pscustomobject]@{wall_ms=$zstdPatchDecode.wall_ms;cpu_ms=$zstdPatchDecode.cpu_ms;peak_working_set_bytes=$zstdPatchDecode.peak_working_set_bytes;peak_pagefile_bytes=$zstdPatchDecode.peak_pagefile_bytes;output_bytes=$zstdPatchDecode.byte_count;sha256=$zstdPatchDecode.sha256}
    })
    $zstdBaseDecode=$null;$zstdPatchDecode=$null
}
$khcDecodeMs=@($khcDecodeSamples | ForEach-Object { [double]$_.wall_ms })
$sevenDecodeMs=@($sevenDecodeSamples | ForEach-Object { [double]$_.wall_ms })
$zstdDecodeMs=@($zstdDecodeSamples | ForEach-Object { [double]$_.base.wall_ms+[double]$_.patch.wall_ms })
$summary=[ordered]@{
    schema=1;recorded_utc=[DateTime]::UtcNow.ToString('O');dataset=$metadata.dataset;architecture=$metadata.architecture;base_version=$metadata.base_version;target_version=$metadata.target_version
    source=[ordered]@{base_name=$spec.base.name;base_url=$spec.base.url;base_bytes=(Get-Item -LiteralPath $basePath).Length;base_sha256=$baseHash;target_name=$spec.target.name;target_url=$spec.target.url;target_bytes=(Get-Item -LiteralPath $targetPath).Length;target_sha256=$targetHash;items=@($sourceEvidence.ToArray())}
    tools=[ordered]@{seven_zip_version=$sevenVersion;seven_zip_path=[IO.Path]::GetRelativePath($work,$sevenZip);seven_zip_sha256=(Get-Sha256 $sevenZip);bootstrap=@{url=$bootstrap.uri;bytes=$bootstrap.bytes;sha256=$bootstrap.sha256;upstream_digest=$bootstrap.upstream_digest};extra=@{url=$extra.uri;bytes=$extra.bytes;sha256=$extra.sha256;upstream_digest=$extra.upstream_digest};zstd_version='1.5.7';zstd_path=[IO.Path]::GetRelativePath($work,$zstd);zstd_zip=@{url=$zstdEvidence.uri;bytes=$zstdEvidence.bytes;sha256=$zstdEvidence.sha256;upstream_digest=$zstdEvidence.upstream_digest}}
    method=[ordered]@{khc='KHC base block + deterministic 8-byte rolling-hash copy/additive-difference/literal commands, KHC-compressed body; 1 MiB member limit';seven_zip='7-Zip 26.04 solid 7z, LZMA2, 64 MiB dictionary, one thread, both named members';zstd='zstd 1.5.7 patch-from at level 19, one thread, independently compressed base plus patch; charges KHC-equivalent header/name fee'}
    self_check=$selfCheckReport
    parameters=[ordered]@{repeats=3;putty_tuned=$false;held_out=($Dataset -eq '7zr');metadata_fee_bytes=$metadataFee;independent_patch_base_included=$true}
    sizes=$sampleResults[0].sizes
    timing_boundary=[ordered]@{wall_ms='CLI process start through exit and complete stdout capture into memory; includes encoded input read and pipe transport, excludes decoded output file writes';khc_delta_decode='one process outputs base then target as a bounded concatenated byte stream';seven_zip_decode='one e -so process outputs both archive members; member order is detected by source hashes';zstd_patch_pair_decode='sum of sequential base and patch-from processes captured to memory; patch uses the verified original base file'}
    memory_boundary=[ordered]@{working_set='OS PeakWorkingSet64 queried while each child is alive, with a 5 ms wait cadence';pagefile='OS PeakPagedMemorySize64 queried while each child is alive, with a 5 ms wait cadence';scope='per-process high-water counters; excludes the PowerShell host and its in-memory stdout capture';validity='every reported encode/decode sample must have nonzero values for both counters'}
    timing_median_ms=[ordered]@{khc_delta_encode=(Get-Median $khcEncodeMs);khc_delta_decode=(Get-Median $khcDecodeMs);seven_zip_encode=(Get-Median $sevenEncodeMs);seven_zip_decode=(Get-Median $sevenDecodeMs);zstd_patch_pair_encode=(Get-Median $zstdEncodeMs);zstd_patch_pair_decode=(Get-Median $zstdDecodeMs)}
    samples=$sampleResults.ToArray()
    decode_samples=[ordered]@{khc_delta=$khcDecodeSamples.ToArray();seven_zip=$sevenDecodeSamples.ToArray();zstd_patch_pair=$zstdDecodeSamples.ToArray();seven_zip_integrity=$sevenTest}
    interpretation='Screen only: two Windows x86 release pairs do not establish general-purpose or Silesia performance. Compare complete pair size including the base; 7zr 24.09 has no upstream SHA-256 digest in the official release API.'
}
if($null -ne $toolCacheEvidence) { $summary.tool_cache=$toolCacheEvidence }
$summary.repeat_storage=[ordered]@{repeats=3;retained_compressed_artifacts='Only the final repeat artifacts are retained; size and SHA-256 are recorded for every repeat.';seven_zip_reset='Between measured repeats, all prior archive members are removed and an empty archive is verified; reset time is excluded from encode timing.';determinism='All three repeats must produce identical sizes and SHA-256 values.'}
$reportPath=Join-Path $work 'version-delta-screen.json'
[IO.File]::WriteAllText($reportPath,(ConvertTo-Json -InputObject $summary -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
Write-Output (ConvertTo-Json -InputObject $summary -Depth 12 -Compress)
