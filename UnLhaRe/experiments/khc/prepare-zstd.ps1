[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$work=Join-Path $project 'build/khc-bench-tools-20261005'
$guard=Join-Path $PSScriptRoot 'disk-budget.ps1'
$uri='https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-v1.5.7-win64.zip'
$expectedZipBytes=1747181
$budget=& $guard -WorkDirectory $work -MaxRunMiB 8
if(Test-Path -LiteralPath $work){throw 'Unused tool output directory required'}
$client=[Net.Http.HttpClient]::new()
$client.Timeout=[TimeSpan]::FromSeconds(30)
$zipBytes=[IO.MemoryStream]::new()
try{
 $response=$client.GetAsync($uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
 try{
  $null=$response.EnsureSuccessStatusCode()
  if($response.Content.Headers.ContentLength -ne $expectedZipBytes){throw 'Release asset length changed'}
  $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
  try{
   $buffer=[byte[]]::new(65536)
   while(($read=$stream.Read($buffer,0,$buffer.Length)) -ne 0){if($zipBytes.Length+$read -gt $expectedZipBytes){throw 'ZIP download capacity'};$zipBytes.Write($buffer,0,$read)}
  }finally{$stream.Dispose()}
 }finally{$response.Dispose()}
 if($zipBytes.Length -ne $expectedZipBytes){throw 'Truncated asset'}
 $zipSHA=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($zipBytes.ToArray()))
 $zipBytes.Position=0
 $archive=[IO.Compression.ZipArchive]::new($zipBytes,[IO.Compression.ZipArchiveMode]::Read,$true)
 try{
  $inventory=@($archive.Entries|ForEach-Object {[pscustomobject]@{name=$_.FullName;bytes=$_.Length}})
  if($inventory.Count -gt 64 -or ($inventory|Measure-Object bytes -Sum).Sum -gt 8388608){throw 'Expanded ZIP inventory capacity'}
  $binaries=@($archive.Entries|Where-Object {$_.Name -ceq 'zstd.exe'})
  if($binaries.Count -ne 1 -or $binaries[0].Length -gt 2097152){throw 'Unique bounded zstd executable required'}
  $licenseEntries=@($archive.Entries|Where-Object {$_.Name -match '^(LICENSE|COPYING)([.].*)?$'})
  $licenseSource=Join-Path $PSScriptRoot 'bench-zstd-LICENSE'
  if(!$licenseEntries.Count){
   $licenseInfo=Get-Item -LiteralPath $licenseSource
   if($licenseInfo.PSIsContainer -or ($licenseInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $licenseInfo.Length -gt 131072){throw 'Bounded official release license required'}
  }
  if(($licenseEntries|Measure-Object Length -Sum).Sum -gt 131072){throw 'License capacity'}
  $null=New-Item -ItemType Directory -Path $work
  $created=[Collections.Generic.List[object]]::new()
  $wanted=@($binaries[0])+$licenseEntries
  foreach($entry in $wanted){
   $name=$entry.Name
   if($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $name -in @('.','..')){throw 'Flat output name'}
   $path=Join-Path $work $name
   $inputStream=$entry.Open();$outputStream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
   try{$inputStream.CopyTo($outputStream)}finally{$outputStream.Dispose();$inputStream.Dispose()}
   if((Get-Item -LiteralPath $path).Length -ne $entry.Length){throw 'Extracted length'}
   $created.Add([pscustomobject]@{path=$path;bytes=$entry.Length;sha256=(Get-FileHash -LiteralPath $path).Hash})
  }
  if(!$licenseEntries.Count){
   $licensePath=Join-Path $work 'LICENSE'
   Copy-Item -LiteralPath $licenseSource -Destination $licensePath
   $created.Add([pscustomobject]@{path=$licensePath;bytes=(Get-Item -LiteralPath $licensePath).Length;sha256=(Get-FileHash -LiteralPath $licensePath).Hash})
  }
  $report=[ordered]@{status='prepared-not-executed';source=$uri;release='v1.5.7';asset_updated_utc='2025-02-28T20:07:29Z';zip_bytes=$expectedZipBytes;zip_sha256=$zipSHA;publisher_digest_provided=$false;hash_is_local_identity_not_publisher_attestation=$true;zip_saved_to_disk=$false;download_calls_this_execution=1;previous_RAM_only_attempts=1;previous_attempt_reason='release ZIP contains no license; no output directory or file was created';license_source='https://github.com/facebook/zstd/blob/v1.5.7/LICENSE';license_git_blob_sha='75800288cc243f164b9d130f125e2ffae28f8e39';license_retrieved_via_GitHub_connector=$true;expanded_inventory=$inventory;files=@($created);disk_before=$budget;benchmark_calls=0;product_dependency_added=$false}
  $json=$report|ConvertTo-Json -Depth 6
  if([Text.Encoding]::UTF8.GetByteCount($json) -gt 32768){throw 'Preparation report capacity'}
  [IO.File]::WriteAllText((Join-Path $work 'preparation.json'),$json,[Text.UTF8Encoding]::new($false))
  $after=& $guard -WorkDirectory $work -MaxRunMiB 8
  [pscustomobject]@{status=$report.status;files=@($created);zip_saved_to_disk=$false;disk=$after}|ConvertTo-Json -Depth 5
 }finally{$archive.Dispose()}
}finally{$zipBytes.Dispose();$client.Dispose()}
