#requires -Version 7.0
# 連続観測Canterbury training reference。私sealは親の再読と全raw検証後のみ。
[CmdletBinding()]
param([string]$WorkDirectory='',[Parameter(Mandatory)][string]$ProtocolPath,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256,[switch]$ValidateProtocolOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
$module=Get-Module storage-lifecycle
$protocol=& $module {param($path,$sha)
    $kind=Get-KhcMacReferenceKind 'khc-mac-canterbury-continuous-reference-v1'
    Assert-KhcMacReferenceInvocationPair $kind.Protocol $kind.Worker $path 180
    $value=Read-KhcMacReferenceProtocol $path $sha
    if($value.Data.protocol -cne $kind.Protocol){throw 'Continuous worker requires its own protocol type.'}
    $value
} $ProtocolPath $ProtocolSha256
if($ValidateProtocolOnly){return}
Assert-KhcStorageContext -WorkDirectory $WorkDirectory
$paths=Get-KhcStorageTaskPaths
if($paths.TaskId -cne 'goal-restore-20261019'){throw 'Continuous worker requires the approved current task.'}
$record=Get-Content -LiteralPath $env:KHC_STORAGE_RUN_RECORD -Raw|ConvertFrom-Json
if([string]$record.run_id -cnotmatch '\A[0-9a-f]{32}\z' -or [IO.Path]::GetFullPath($env:KHC_STORAGE_RUN_RECORD) -cne (Join-Path (Join-Path (Join-Path $paths.StateRoot 'runs') $record.run_id) 'run.json') -or [IO.Path]::GetFullPath($env:KHC_STORAGE_INVOCATION) -cne (Join-Path (Join-Path (Join-Path $paths.StateRoot 'runs') $record.run_id) 'invocation.clixml') -or $record.max_bytes -ne 8MB -or $record.max_entries -ne 96 -or $record.work_directory -cne $WorkDirectory){throw 'Continuous worker registration resources/path mismatch.'}
$registration=& $module {param($state,$id)$reserve=Get-KhcRecycleV6RunAnchor $state $id;Get-KhcMacReferenceRegistration $state $id $reserve -RequireInvocation} $paths.StateRoot $record.run_id
if($null -eq $registration -or $registration.Protocol.protocol -cne 'khc-mac-canterbury-continuous-reference-v1' -or $registration.Record.protocol_sha256 -cne $ProtocolSha256 -or $registration.Record.worker_sha256 -cne (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'Continuous worker/protocol differs from private registration.'}
if(Test-Path -LiteralPath $WorkDirectory){throw 'Continuous work root must be unused.'}
$null=[IO.Directory]::CreateDirectory($WorkDirectory)
$null=Assert-KhcStorageBudget
$endpoint=& $module {param($id,$sha)Invoke-KhcMacContinuousRemote -Mode run -RunId $id -ProtocolSha256 $sha} $record.run_id $ProtocolSha256
$bundle=& $module {param($id,$sha)Invoke-KhcMacContinuousRemote -Mode bundle -RunId $id -ProtocolSha256 $sha} $record.run_id $ProtocolSha256
if($bundle.ExitCode -ne 0){throw 'Continuous evidence bundle unavailable; remote remains unsealed.'}
$bundleSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bundle.Bytes)).ToLowerInvariant()
$envelope=& $module {param($bytes,$sha)ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 1500000} $bundle.Bytes $bundleSha
if($envelope.Count -ne 3 -or @($envelope.Keys|Where-Object {$_ -cnotin @('archive_bytes','archive_sha256','archive_base64')}).Count -or ($envelope.archive_bytes -isnot [int] -and $envelope.archive_bytes -isnot [long]) -or $envelope.archive_bytes -lt 1 -or $envelope.archive_bytes -gt 1MB -or $envelope.archive_base64 -isnot [string] -or $envelope.archive_base64.Length -gt 1398104 -or $envelope.archive_sha256 -isnot [string] -or $envelope.archive_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Continuous bundle envelope type/bound.'}
$archive=[Convert]::FromBase64String($envelope.archive_base64)
if($archive.Length -ne $envelope.archive_bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archive)).ToLowerInvariant() -cne $envelope.archive_sha256){throw 'Continuous bundle bytes/SHA mismatch.'}
$proofPath=Join-Path $WorkDirectory 'reference-proof.zip'
$stream=[IO.File]::Open($proofPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$stream.Write($archive);$stream.Flush($true)}finally{$stream.Dispose()}
$proof=& $module {param($path,$sha,$id)Invoke-KhcMacContinuousProofVerifier -ArchivePath $path -ProtocolSha256 $sha -RunId $id} $proofPath $ProtocolSha256 $record.run_id
# 全集合はpinned Pythonで検証済み。raw127個は展開しない。
$memory=[IO.MemoryStream]::new($archive,$false)
$zip=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read,$false)
try{
    $entry=$zip.GetEntry('terminal.json');if($null -eq $entry -or $entry.Length -gt 65536){throw 'Missing bounded canonical terminal.'}
    $input=$entry.Open();$output=[IO.MemoryStream]::new()
    try{$input.CopyTo($output);$receiptBytes=$output.ToArray()}finally{$input.Dispose();$output.Dispose()}
}finally{$zip.Dispose();$memory.Dispose()}
$receiptSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($receiptBytes)).ToLowerInvariant()
if($receiptSha -cne $proof.receipt_sha256){throw 'Bundled terminal differs from fully validated proof.'}
if($endpoint.Bytes.Length -gt 0 -and [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($endpoint.Bytes)).ToLowerInvariant() -cne $receiptSha){throw 'Endpoint stdout differs from canonical bundled terminal.'}
$receipt=& $module {param($bytes,$sha)ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha} $receiptBytes $receiptSha
if($null -ne $receipt.report_base64){
    $report=[Convert]::FromBase64String($receipt.report_base64)
    $stream=[IO.File]::Open((Join-Path $WorkDirectory 'reference-report.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($report);$stream.Flush($true)}finally{$stream.Dispose()}
}
$stream=[IO.File]::Open((Join-Path $WorkDirectory 'reference-receipt.json'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$stream.Write($receiptBytes);$stream.Flush($true)}finally{$stream.Dispose()}
Write-Output (ConvertTo-Json -Compress -InputObject ([ordered]@{run_id=$record.run_id;status=$proof.status;receipt_sha256=$receiptSha;report_sha256=$proof.report_sha256;children_absent=$proof.children_absent;proof_sha256=$proof.archive_sha256;seal='parent canonical confirmation and private proof copy required'}))
exit ([int]$proof.exit)
