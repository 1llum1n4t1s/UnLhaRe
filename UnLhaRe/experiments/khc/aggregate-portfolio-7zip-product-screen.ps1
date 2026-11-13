#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateCount(20,20)][ValidatePattern('^[0-9a-f]{32}$')][string[]]$RunIds,
    [Parameter(Mandatory)][DateTimeOffset]$CampaignStartedUtc,
    [Parameter(Mandatory)][DateTimeOffset]$CampaignFinishedUtc,
    [Parameter(Mandatory)][DateTimeOffset]$StartGateStartedUtc,
    [Parameter(Mandatory)][DateTimeOffset]$StartGateFinishedUtc,
    [Parameter(Mandatory)][ValidateCount(5,5)][double[]]$StartGateCpuPercent,
    [ValidateSet('eGovLawXml20261016','AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020','UciTabularDevelopment20261020')][string]$CorpusProfile='eGovLawXml20261016',
    [string]$CampaignManifestSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# 旧UCI開発用profileはmetadata登録のみ。専用Dry Bean holdoutとは分離する。
if ($CorpusProfile -ieq 'UciTabularDevelopment20261020') { throw 'UCI development-only metadata is excluded from this screen/aggregate, blind holdout completeness and superiority thresholds; no runnable wrapper is admitted.' }

$taskId='goal-restore-20261019'
$workRoot=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019')
$artifactRoot=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019')
$runRoot=Join-Path $artifactRoot 'storage-lifecycle\runs'
$campaignDirectory=Join-Path $artifactRoot 'egov-screen-20261020'
$campaignManifestPath=Join-Path $campaignDirectory 'campaign-start.json'
$outputPath=Join-Path $campaignDirectory 'campaign-report.json'
$workerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'portfolio-7zip-product-screen.ps1'))
$runnerPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'run-storage-experiment.ps1'))
$lifecyclePath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'))
$diskBudgetPath=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disk-budget.ps1'))
$expectedWorkerSha='8789bad160e3dbdb1931267b80e4cd4da679cdc22d00f9b7e20f4417669e7a16'
$expectedRunnerSha='aa981ad2dd416c10f14d6b2cc0b7e0d8b001de4e2ccfed7dc981ecd3b74e619b'
$expectedLifecycleSha='e3953d42595b66aba8a40da393e13bfd32e269b75c7d443e207dbfc9a202ba0c'
$expectedDiskBudgetSha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd'
$expectedCliPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
$expectedCliSha='3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b'
$expectedSevenPath='C:\Program Files\7-Zip\7z.exe'
$expectedSevenSha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
$expectedInputPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\egov-screen-20261020\input.zip')
$expectedInputSha='861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099'
$expectedInputManifestSha='332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3'
$expectedSourceManifestSha='0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404'
$expectedCampaignManifestSha='1ec16512fc8b342407c391c80693598e506136f7b76dfff5e67d24df96e95afe'
$expectedBytes=9527638L
$expectedFiles=100
$capBytes=32MB
$capEntries=512
$memoryBytes=160MB
$scope='DEVELOPMENT ONLY: e-Gov judicial 100-file XML/CSV set'
$fixedProfile=$null
$isCanterbury=($CorpusProfile -ceq 'CanterburyDevelopmentKcs1CountLength20261020')
$isHoldout=($CorpusProfile -cin @('JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020'))
$scriptSha=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()

function Plain([string]$Path) {
    if(-not [IO.Path]::IsPathFullyQualified($Path)){throw "Absolute path required: $Path"}
    $full=[IO.Path]::GetFullPath($Path)
    for($part=$full;$part;$part=[IO.Path]::GetDirectoryName($part)){
        if(Test-Path -LiteralPath $part){
            $item=Get-Item -LiteralPath $part -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Reparse point rejected: $part"}
        }
    }
    return $full
}
function Hash([string]$Path){(Get-FileHash -LiteralPath (Plain $Path) -Algorithm SHA256).Hash.ToLowerInvariant()}
function Read-Json([string]$Path){Get-Content -LiteralPath (Plain $Path) -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 32}
function Assert-Hash([string]$Path,[string]$Expected){if((Hash $Path) -cne $Expected){throw "Pinned file SHA-256 mismatch: $Path"}}
function To-UtcDateTimeOffset([object]$Value,[string]$Name){
    if($null -eq $Value){throw "Missing timestamp: $Name"}
    if($Value -is [DateTimeOffset]){$parsed=$Value}
    elseif($Value -is [DateTime]){
        if($Value.Kind -eq [DateTimeKind]::Unspecified){throw "Timestamp has no timezone: $Name"}
        $parsed=[DateTimeOffset]::new($Value)
    }
    elseif($Value -is [string]){
        if($Value -notmatch '(?:Z|[+-][0-9]{2}:[0-9]{2})$'){throw "Timestamp lacks an explicit UTC offset: $Name"}
        $parsed=[DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    }
    else{throw "Unsupported timestamp type for ${Name}: $($Value.GetType().FullName)"}
    return $parsed.ToUniversalTime()
}
function Source-Manifest([string]$Root){
    $rootPath=Plain $Root
    $pathsByName=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($item in Get-ChildItem -LiteralPath $rootPath -Recurse -Force -ErrorAction Stop){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Source manifest rejects reparse point: $($item.FullName)"}
        if(-not $item.PSIsContainer -and $item.Extension -ceq '.rs'){
            $relative=[IO.Path]::GetRelativePath($rootPath,$item.FullName).Replace('\','/')
            $pathsByName.Add($relative,$item.FullName)
        }
    }
    $names=[string[]]$pathsByName.Keys;[Array]::Sort($names,[StringComparer]::Ordinal)
    $builder=[Text.StringBuilder]::new()
    foreach($name in $names){$path=$pathsByName[$name];$item=Get-Item -LiteralPath $path -Force;$null=$builder.Append($name).Append([char]9).Append($item.Length).Append([char]9).Append((Hash $path)).Append([char]10)}
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
}
function Get-StreamSha256([IO.Stream]$Stream){
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [Convert]::ToHexString($sha.ComputeHash($Stream)).ToLowerInvariant()}finally{$sha.Dispose()}
}
function Median([double[]]$Values){
    if($Values.Count -ne 9 -or @($Values|Where-Object{[double]::IsNaN($_)-or[double]::IsInfinity($_)-or$_-lt0}).Count){throw 'Expected nine finite nonnegative measured values.'}
    $ordered=@($Values|Sort-Object)
    return [pscustomobject]@{median=$ordered[4];min=$ordered[0];max=$ordered[8]}
}
function Assert-ReportPin([System.Collections.IDictionary]$Report,[string]$Path,[string]$ExpectedPath,[string]$Sha){
    $matches=@($Report.pins|Where-Object{[string]$_.expected_path -ceq $ExpectedPath -and [string]$_.sha -ceq $Sha})
    if($matches.Count -ne 1 -or [IO.Path]::GetFullPath([string]$matches[0].path) -cne $ExpectedPath){throw "Report pin mismatch: $ExpectedPath"}
}
function Read-RunReport([string]$RunId){
    $directory=Plain (Join-Path $runRoot $RunId)
    $runJson=Read-Json (Join-Path $directory 'run.json')
    $request=Read-Json (Join-Path $directory 'cleanup-request.json')
    $recovery=Read-Json (Join-Path $directory 'recovery.json')
    $complete=Read-Json (Join-Path $directory 'complete.json')
    $archivePath=Plain (Join-Path $directory 'recovery.zip')
    $manifestPath=Plain (Join-Path $directory 'recovery.json')
    if($runJson.run_id -cne $RunId -or $runJson.max_bytes -ne $capBytes -or $runJson.max_entries -ne $capEntries){throw "Registered cap/run identity mismatch: $RunId"}
    $work=[IO.Path]::GetFullPath([string]$runJson.work_directory)
    if([IO.Path]::GetDirectoryName($work) -ine $workRoot -or $work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or (Test-Path -LiteralPath $work)){throw "Run work root is outside its expected completed/clean state: $RunId"}
    if($request.run_id -cne $RunId -or $request.requires_prunlet -ne $true -or [IO.Path]::GetFullPath([string]$request.work_directory) -cne $work){throw "Cleanup request mismatch: $RunId"}
    if($complete.State -cne 'complete' -or $complete.RunId -cne $RunId -or $complete.AfterBytes -ne 0 -or
       [IO.Path]::GetFullPath([string]$complete.BackupPath) -cne $archivePath -or
       [IO.Path]::GetFullPath([string]$complete.ManifestPath) -cne $manifestPath -or
       [IO.Path]::GetFullPath([string]$complete.RequestPath) -cne (Join-Path $directory 'cleanup-request.json') -or
       [long]$complete.BeforeBytes -ne [long]$recovery.measured_work_bytes){throw "Lifecycle completion mismatch: $RunId"}
    if($recovery.schema -ne 1 -or $recovery.run_id -cne $RunId -or [IO.Path]::GetFullPath([string]$recovery.work_directory) -cne $work -or
       [long]$recovery.registered_max_bytes -ne $capBytes -or [long]$recovery.measured_work_bytes -gt $capBytes -or
       [long]$recovery.recovery_overrun_bytes -ne 0 -or [int]$recovery.entries.Count -gt $capEntries){throw "Recovery manifest cap/schema mismatch: $RunId"}
    if([long]$request.expected_bytes -ne [long]$recovery.measured_work_bytes -or
       [IO.Path]::GetFullPath([string]$request.recovery_archive_path) -cne $archivePath -or
       [IO.Path]::GetFullPath([string]$request.recovery_manifest_path) -cne $manifestPath -or
       [string]$request.recovery_archive_sha256 -cne [string]$recovery.backup_sha256 -or
       (Hash $archivePath) -cne [string]$recovery.backup_sha256 -or
       (Hash $manifestPath) -cne [string]$request.recovery_manifest_sha256){throw "Recovery archive/manifest integrity mismatch: $RunId"}
    if($request.expected_files.Count -ne $recovery.files.Count){throw "Cleanup file inventory mismatch: $RunId"}
    $env:KHC_STORAGE_TASK_ID=$taskId
    $receiptCheck=Test-KhcStorageCompletedReceipts -RunId $RunId
    if($receiptCheck.State -cne 'completed-receipts-verified'){throw "Lifecycle receipts are incomplete: $RunId"}
    $zip=[IO.Compression.ZipFile]::OpenRead($archivePath)
    try{
        $zipFiles=@($zip.Entries|Where-Object{-not $_.FullName.EndsWith('/')})
        if($zipFiles.Count -ne $recovery.files.Count){throw "Recovery ZIP file count mismatch: $RunId"}
        $expectedNames=[string[]]@($recovery.files|ForEach-Object{([string]$_.path).Replace('\','/')})
        [Array]::Sort($expectedNames,[StringComparer]::Ordinal)
        $actualNames=[string[]]@($zipFiles|ForEach-Object{[string]$_.FullName})
        [Array]::Sort($actualNames,[StringComparer]::Ordinal)
        if(($expectedNames -join "`n") -cne ($actualNames -join "`n")){throw "Recovery ZIP path set mismatch: $RunId"}
        foreach($file in $recovery.files){
            $entry=$zip.GetEntry(([string]$file.path).Replace('\','/'))
            if($null -eq $entry -or [long]$entry.Length -ne [long]$file.bytes){if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){throw "NICT recovery ZIP member length mismatch: $RunId"};throw "Recovery ZIP entry length mismatch: $RunId/$($file.path)"}
            $stream=$entry.Open()
            try{$sha=Get-StreamSha256 $stream}finally{$stream.Dispose()}
            if($sha -cne [string]$file.sha256){if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){throw "NICT recovery ZIP member hash mismatch: $RunId"};throw "Recovery ZIP entry hash mismatch: $RunId/$($file.path)"}
        }
        $reportEntry=$zip.GetEntry('portfolio-product-report.json')
        if($null -eq $reportEntry -or $reportEntry.Length -gt 512KB){throw "Bounded sample report missing: $RunId"}
        $reportFile=@($recovery.files|Where-Object{[string]$_.path -ceq 'portfolio-product-report.json'})
        if($reportFile.Count -ne 1 -or [long]$reportFile[0].bytes -ne [long]$reportEntry.Length){throw "Report recovery metadata mismatch: $RunId"}
        $stream=$reportEntry.Open()
        try{$reader=[IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true));try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
    }finally{$zip.Dispose()}
    $report=ConvertFrom-Json -InputObject $json -AsHashtable -Depth 32
    $reportSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($json))).ToLowerInvariant()
    if($reportSha -cne [string]$reportFile[0].sha256){throw "Sample report SHA mismatch: $RunId"}
    $sample=@($report.samples)
    if($sample.Count -ne 1 -or $report.status -cne 'completed' -or [string]$report.run_id -cne $RunId -or
       [string]$report.corpus_profile -cne $CorpusProfile -or
       [string]$report.worker_sha256 -cne $expectedWorkerSha -or [string]$report.source_manifest_sha256 -cne $expectedSourceManifestSha -or
       [string]$report.khc_version -cne 'unlhare-cli 1.0.4' -or [string]$report.expected_khc_version -cne '1.0.4' -or
       [string]$report.input.manifest_sha256 -cne $expectedInputManifestSha -or [long]$report.input.bytes -ne $expectedBytes -or [int]$report.input.files -ne $expectedFiles -or
       [long]$report.caps.storage_bytes -ne $capBytes -or [int]$report.caps.entries -ne $capEntries -or
       [long]$report.caps.process_memory_bytes -ne $memoryBytes -or [int]$report.caps.command_seconds -ne 60 -or
       [int]$report.caps.khc_create_threads -ne 1 -or [int]$report.caps.khc_extract_workers -ne 4 -or
       [int]$report.caps.seven_zip_create_threads -ne 1 -or [int]$report.caps.seven_zip_extract_threads -ne 4 -or
       [int]$report.caps.per_run_timeout_seconds -ne 300 -or [int]$report.caps.campaign_wall_seconds -ne 1800 -or
       $null -ne $report.candidate_size_passed -or $null -ne $report.candidate_time_passed -or $null -ne $report.candidate_screen_passed -or
       $null -ne $report.candidate_decision -or $report.final_goal_achieved -ne $false -or $report.holdout_evaluated -ne $isHoldout){
        throw "Sample report identity/profile/caps mismatch: $RunId"
    }
    if([string]$report.seven_zip_file_version -notmatch '^26\.04(?:\.|$)'){throw "7-Zip version mismatch in report: $RunId"}
    Assert-ReportPin $report $expectedCliPath $expectedCliPath $expectedCliSha
    Assert-ReportPin $report $expectedSevenPath $expectedSevenPath $expectedSevenSha
    Assert-ReportPin $report $expectedInputPath $expectedInputPath $expectedInputSha
    Assert-ReportPin $report $lifecyclePath $lifecyclePath $expectedLifecycleSha
    Assert-ReportPin $report $diskBudgetPath $diskBudgetPath $expectedDiskBudgetSha
    $one=$sample[0]
    $round=[int]$one.round
    $strategy=[string]$one.strategy
    if($null -ne $fixedProfile){
        if([string]$report.campaign_manifest_sha256 -cne $expectedCampaignManifestSha -or
           [string]$report.source_family -cne $fixedProfile.SourceFamily -or [int]$report.source_family_count -ne 1 -or
           $report.general_superiority_claimed -cne $false -or
           [IO.Path]::GetFullPath([string]$one.restore) -cne (Join-Path $work "restored-$round-$strategy")){throw "Fixed campaign/report identity mismatch: $RunId"}
        if($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){
            if([string]$report.source_condition -cne $fixedProfile.Name -or
               [string]$report.khc_source_manifest_sha256 -cne $fixedProfile.KhcSourceManifestSha256 -or
               [string]$report.input_entry_prefix -cne $fixedProfile.EntryPrefix){throw "NICT KCS1 holdout report source/input mismatch: $RunId"}
        }
        if($CorpusProfile -ceq 'UciDryBeanHoldout20261020'){
            Assert-KhcDryBeanMetadata -Actual $report.source_provenance -Expected $fixedProfile.Provenance
            if([string]$report.source_condition -cne $fixedProfile.Name -or
               [string]$report.khc_source_manifest_sha256 -cne $fixedProfile.KhcSourceManifestSha256 -or
               [string]$report.input_entry_prefix -cne $fixedProfile.EntryPrefix -or
               [string]$report.input_zip_path -cne (Get-KhcPortfolioInputZipPath $fixedProfile) -or
               [long]$report.input_zip_bytes -ne $fixedProfile.ZipBytes -or [string]$report.input_zip_sha256 -cne $fixedProfile.ZipSha256 -or
               $report.single_family_screen_only -isnot [bool] -or $report.single_family_screen_only -cne $true -or
               -not $report.Contains('aggregate_category_count') -or [int]$report.aggregate_category_count -ne 0){
                throw "Dry Bean one-family report source/input/scope mismatch: $RunId"
            }
        }
        if($isHoldout){
            if([string]$report.input_role -cne 'holdout-only' -or $report.holdout_only -isnot [bool] -or $report.holdout_only -cne $true -or
               $report.development_only -isnot [bool] -or $report.development_only -cne $false -or
               $report.training_allowed -isnot [bool] -or $report.training_allowed -cne $false -or
               $report.tuning_allowed -isnot [bool] -or $report.tuning_allowed -cne $false -or
               $report.holdout_evaluated -isnot [bool] -or $report.holdout_evaluated -cne $true -or [string]$report.start_date -cne $fixedProfile.StartDate -or
               [string]$report.end_date -cne $fixedProfile.EndDate -or (@($report.fields) -join ',') -cne ($fixedProfile.Fields -join ',')){
                throw "Independent holdout report role/coverage mismatch: $RunId"
            }
            if($CorpusProfile -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){
                if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020') -and
                    ([string]$report.input_zip_path -cne (Get-KhcPortfolioInputZipPath $fixedProfile) -or [long]$report.input_zip_bytes -ne $fixedProfile.ZipBytes -or [string]$report.input_zip_sha256 -cne $fixedProfile.ZipSha256)){
                    throw "NICT report wrapper identity mismatch: $RunId"
                }
                if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){Assert-KhcNictMetadata -Actual $report.source_provenance -Expected $fixedProfile.Provenance}
                else{Assert-KhcLivedoorMetadata -Actual $report.source_provenance -Expected $fixedProfile.Provenance}
                if([long]$report.caps.listing_stdout_bytes -ne $fixedProfile.ListingOutputBytes -or [long]$report.caps.listing_stderr_bytes -ne 2KB){throw "Livedoor listing cap mismatch: $RunId"}
            }
            if($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020'){
                $licenseVersionPresent = $report -is [System.Collections.IDictionary] -and $report.Contains('source_license_version')
                $licenseVersionMatches = if ($null -eq $fixedProfile.SourceLicenseVersion) { $licenseVersionPresent -and $null -eq $report.source_license_version } else { $licenseVersionPresent -and [string]$report.source_license_version -ceq $fixedProfile.SourceLicenseVersion }
                if([string]$report.source_page -cne $fixedProfile.SourcePage -or
                   [string]$report.source_catalog_page -cne $fixedProfile.SourceCatalogPage -or
                   [string]$report.source_direct_csv_url -cne $fixedProfile.SourceDirectCsvUrl -or
                   [string]$report.source_attribution -cne $fixedProfile.SourceAttribution -or
                   [string]$report.source_license_label -cne $fixedProfile.SourceLicenseLabel -or
                   -not $licenseVersionMatches -or
                   [string]$report.source_license_note -cne $fixedProfile.SourceLicenseNote -or
                   [string]$report.source_content_handling -cne $fixedProfile.SourceContentHandling){
                    throw "Tokyo resident-register sample source/attribution/license mismatch: $RunId"
                }
            }
        }elseif($isCanterbury){
            if([string]$report.input_role -cne 'development-only' -or
                $report.development_only -isnot [bool] -or $report.development_only -cne $true -or
                $report.holdout_only -isnot [bool] -or $report.holdout_only -cne $false -or
                $report.training_allowed -isnot [bool] -or $report.training_allowed -cne $true -or
                $report.tuning_allowed -isnot [bool] -or $report.tuning_allowed -cne $true -or
                [string]$report.source_condition -cne $fixedProfile.Name -or
                [string]$report.khc_source_manifest_sha256 -cne $fixedProfile.KhcSourceManifestSha256 -or
                [string]$report.input_zip_path -cne $expectedInputPath -or [long]$report.input_zip_bytes -ne $fixedProfile.ZipBytes -or
                [string]$report.input_zip_sha256 -cne $expectedInputSha -or [string]$report.input_entry_prefix -cne $fixedProfile.EntryPrefix){
                throw "Canterbury KCS1 development-only report role/source/input mismatch: $RunId"
            }
        }elseif([string]$report.candidate_manifest_sha256 -cne $fixedProfile.CandidateManifestSha256 -or
                (@($report.development_work_ids) -join ',') -cne '424,752' -or $report.development_only -cne $true){throw "Aozora development-only campaign/report identity mismatch: $RunId"}
        foreach($manifest in @($report.input,$one.restored)){
            if(@($manifest.entries).Count -ne $fixedProfile.Entries.Count){throw "Fixed report member count mismatch: $RunId"}
            for($i=0;$i -lt $fixedProfile.Entries.Count;$i++){
                $actual=$manifest.entries[$i];$expected=$fixedProfile.Entries[$i]
                if([string]$actual.name -cne $expected.name -or [long]$actual.bytes -ne $expected.bytes -or [string]$actual.sha256 -cne $expected.sha256){throw "Fixed report member name/length/SHA mismatch: $RunId"}
            }
        }
        foreach($prefix in @('source/',"restored-$round-$strategy/")){
            $members=@($recovery.files|Where-Object{([string]$_.path).Replace('\','/').StartsWith($prefix,[StringComparison]::Ordinal)})
            if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){
                if($members.Count -ne $fixedProfile.Files){throw "NICT recovered source/restore count mismatch: $RunId"}
                $rows=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
                foreach($member in $members){$name=([string]$member.path).Replace('\','/').Substring($prefix.Length);$rows.Add($name,$member)}
                $names=[string[]]$rows.Keys;[Array]::Sort($names,[StringComparer]::Ordinal)
                $lines=[Collections.Generic.List[string]]::new();$bytes=0L
                foreach($name in $names){$row=$rows[$name];$bytes+=[long]$row.bytes;$lines.Add("$name`t$(([long]$row.bytes).ToString([Globalization.CultureInfo]::InvariantCulture))`t$($row.sha256)")}
                $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n",$lines)))).ToLowerInvariant()
                if($bytes -ne $fixedProfile.Bytes -or $digest -cne $fixedProfile.ManifestSha256){throw "NICT recovered file-set length/SHA mismatch: $RunId"}
            }elseif($members.Count -ne $fixedProfile.Entries.Count){throw "Fixed recovered source/restore count mismatch: $RunId"}
            foreach($expected in $fixedProfile.Entries){
                $member=@($members|Where-Object{([string]$_.path).Replace('\','/') -ceq ($prefix+$expected.name)})
                if($member.Count -ne 1 -or [long]$member[0].bytes -ne $expected.bytes -or [string]$member[0].sha256 -cne $expected.sha256){throw "Fixed recovered source/restore name/length/SHA mismatch: $RunId"}
            }
        }
    }
    $registeredUtc=To-UtcDateTimeOffset $runJson.created_utc "$RunId.run.created_utc"
    $startedUtc=To-UtcDateTimeOffset $report.started_utc "$RunId.report.started_utc"
    $finishedUtc=To-UtcDateTimeOffset $report.updated_utc "$RunId.report.updated_utc"
    $runnerResultPath=Plain (Join-Path $directory 'runner-result.json')
    if(-not (Test-Path -LiteralPath $runnerResultPath -PathType Leaf) -or (Get-Item -LiteralPath $runnerResultPath -Force).Length -gt 8192){throw "Runner result receipt is missing or oversized: $RunId"}
    $runnerResult=Read-Json $runnerResultPath
    $runnerResultSha=Hash $runnerResultPath
    $runnerStartedUtc=To-UtcDateTimeOffset $runnerResult.started_utc "$RunId.runner.started_utc"
    $runnerFinishedUtc=To-UtcDateTimeOffset $runnerResult.finished_utc "$RunId.runner.finished_utc"
    if($runnerResult.schema -ne 1 -or [string]$runnerResult.run_id -cne $RunId -or
       [string]$runnerResult.status -cne 'succeeded' -or [string]$runnerResult.runner_sha256 -cne $expectedRunnerSha -or
       [string]$runnerResult.runner_sha256_at_finish -cne $expectedRunnerSha -or $runnerResult.child_started -ne $true -or
       (($runnerResult.child_exit_code -isnot [int]) -and ($runnerResult.child_exit_code -isnot [long])) -or [long]$runnerResult.child_exit_code -ne 0 -or
       (($runnerResult.child_pid -isnot [int]) -and ($runnerResult.child_pid -isnot [long])) -or [long]$runnerResult.child_pid -le 0 -or
       $runnerResult.stdout_eof -ne $true -or $runnerResult.stderr_eof -ne $true -or
       (($runnerResult.job_active_after_exit -isnot [int]) -and ($runnerResult.job_active_after_exit -isnot [long])) -or [long]$runnerResult.job_active_after_exit -ne 0 -or
       $runnerResult.cleanup_request_created -ne $true -or $null -ne $runnerResult.failure_message -or
       $runnerStartedUtc -gt $registeredUtc -or $runnerFinishedUtc -lt $registeredUtc -or
       $runnerFinishedUtc -lt $runnerStartedUtc -or $runnerFinishedUtc -lt $finishedUtc){
        throw "Runner success receipt is missing, failed, or inconsistent: $RunId"
    }
    $expectedPosition=if($round%2 -eq 0){if($strategy -ceq 'portfolio-trial'){0}else{1}}else{if($strategy -ceq '7zip'){0}else{1}}
    if($round -lt 0 -or $round -gt 9 -or $strategy -cnotin @('portfolio-trial','7zip') -or
       [int]$report.round -ne $round -or [string]$report.strategy -cne $strategy -or
       [bool]$one.warmup -ne ($round -eq 0) -or [int]$one.position -ne $expectedPosition -or [string]$one.result -cne 'passed' -or
       $startedUtc -lt $registeredUtc -or $finishedUtc -lt $startedUtc -or
       [IO.Path]::GetFullPath([string]$one.archive) -notlike "$work\*" -or [IO.Path]::GetFullPath([string]$one.restore) -notlike "$work\*"){
        throw "Sample round/strategy/order/restore mismatch: $RunId"
    }
    if([long]$one.archive_bytes -le 0 -or [long]$one.archive_bytes -gt ($expectedBytes+64KB) -or
       [string]$one.archive_sha256 -notmatch '^[0-9a-f]{64}$' -or
       [long]$one.restored.bytes -ne $expectedBytes -or [int]$one.restored.files -ne $expectedFiles -or
       [string]$one.restored.manifest_sha256 -cne $expectedInputManifestSha){throw "Archive size/hash/restore mismatch: $RunId"}
    if($strategy -ceq 'portfolio-trial'){
        if([int]$one.format.revision -ne 10 -or [string]$one.archive -notmatch '\.khc$'){throw "KHC revision-10 format evidence mismatch: $RunId"}
    }else{
        $dicts=@($one.format.effective_dictionary_bytes|Select-Object -Unique)
        if($CorpusProfile -cin @('AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){
            # コマンドはd=64m固定。小入力時の実効値はworkerと同じ0超64MiB以下で照合する。
            if($dicts.Count -ne 1 -or [long]$dicts[0] -le 0 -or [long]$dicts[0] -gt 64MB -or [string]$one.archive -notmatch '\.7z$'){throw "$CorpusProfile 7-Zip LZMA2 dictionary evidence mismatch: $RunId"}
        }else{
            if($dicts.Count -ne 1 -or [long]$dicts[0] -ne 64MB -or [string]$one.archive -notmatch '\.7z$'){throw "7-Zip LZMA2 dictionary evidence mismatch: $RunId"}
        }
    }
    $timed=@($report.commands|Where-Object{[bool]$_.timed})
    $gates=@($report.cpu_gates)
    if($timed.Count -ne 2 -or $gates.Count -ne 2){throw "Expected exactly timed create/extract and two CPU gates: $RunId"}
    foreach($phase in @('create','extract')){
        $command=$one[$phase]
        $label="$round-$strategy-$phase"
        $matching=@($timed|Where-Object{[string]$_.label -ceq $label})
        $gate=@($gates|Where-Object{[string]$_.label -ceq $label})
        $expectedExecutable=if($strategy -ceq '7zip'){$expectedSevenPath}else{$expectedCliPath}
        $expectedArgs=if($phase -ceq 'create' -and $strategy -ceq 'portfolio-trial'){@('khc-create',[string]$one.archive,'--source',(Join-Path $work 'source'),'--strategy','portfolio-trial')}
            elseif($phase -ceq 'extract' -and $strategy -ceq 'portfolio-trial'){@('khc-extract',[string]$one.archive,'--output',[string]$one.restore)}
            elseif($phase -ceq 'extract'){@('x',[string]$one.archive,"-o$($one.restore)",'-mmt=4','-y','-sccUTF-8','-bd','-bb0')}
            else{@('a','-t7z','-mx=9','-m0=lzma2:d=64m','-mmt=1','-ms=on','-mqs=off','-mtm=off','-mtc=off','-mta=off','-sccUTF-8','-scsUTF-8','-bd','-bb0',[string]$one.archive,'--') + @($report.input.entries|ForEach-Object{[string]$_.name.Replace('/',[IO.Path]::DirectorySeparatorChar)})}
        $argumentMismatch=(@($command.argv) -join "`n") -cne (@($expectedArgs) -join "`n")
        if($CorpusProfile -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){
            if($phase -ceq 'create' -and $strategy -ceq '7zip'){
                $memberNames=[string[]]@($recovery.files|Where-Object{([string]$_.path).Replace('\','/').StartsWith('source/',[StringComparison]::Ordinal)}|ForEach-Object{([string]$_.path).Replace('\','/').Substring(7)})
                [Array]::Sort($memberNames,[StringComparer]::Ordinal)
                $expectedArgs+=@($memberNames|ForEach-Object{$_.Replace('/',[IO.Path]::DirectorySeparatorChar)})
            }
            $argumentSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes([string]::Join("`n",[string[]]$expectedArgs)))).ToLowerInvariant()
            $argumentMismatch=([string]$command.argv_sha256 -cne $argumentSha -or (@($command.argv) -join ',') -cne '[omitted: NICT member identifiers]')
        }
        if($matching.Count -ne 1 -or [string]$command.label -cne $label -or [string]$command.result -cne 'passed' -or
           [IO.Path]::GetFullPath([string]$command.executable) -cne $expectedExecutable -or
           $argumentMismatch -or
           [int]$command.exit_code -ne 0 -or [double]$command.wall_ms -le 0 -or [double]$command.wall_ms -gt 60000 -or
           [double]$command.cpu_ms -lt 0 -or [long]$command.os_peak_working_set_bytes -le 0 -or [long]$command.os_peak_working_set_bytes -gt $memoryBytes -or
           [long]$command.os_peak_paged_memory_bytes -le 0 -or [long]$command.os_peak_paged_memory_bytes -gt $memoryBytes -or
           [long]$command.sampled_private_bytes_max -le 0 -or [long]$command.sampled_private_bytes_max -gt $memoryBytes -or
           [int]$command.live_memory_samples -le 0 -or $command.memory_sampling_complete -ne $true -or
           $gate.Count -ne 1 -or [int]$gate.limit_percent -ne 15 -or [int]$gate.required_samples -ne 5 -or [int]$gate.interval_ms -ne 1000 -or $null -ne $gate.error -or
           @($gate.samples).Count -ne 5 -or @($gate.samples|Where-Object{[double]$_.percent -lt 0 -or [double]$_.percent -gt 15 -or [double]::IsNaN([double]$_.percent) -or [double]::IsInfinity([double]$_.percent)}).Count -ne 0){
            throw "Timed command or CPU/memory gate evidence mismatch: $RunId/$label"
        }
    }
    return [pscustomobject]@{run_id=$RunId;work_directory=$work;registered_utc=$registeredUtc;started_utc=$startedUtc;finished_utc=$finishedUtc;runner_started_utc=$runnerStartedUtc;runner_finished_utc=$runnerFinishedUtc;runner_result_sha256=$runnerResultSha;report_sha256=$reportSha;recovery_sha256=(Hash $archivePath);round=$round;strategy=$strategy;sample=$one;report=$report;complete=$complete}
}

# 旧e-Gov markerの固定SHAと記録は維持する。新profileには別のimmutable markerが必須。
if($CorpusProfile -cin @('AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){
    Import-Module $lifecyclePath -Force
    $fixedProfile=Get-KhcPortfolioInputProfile $CorpusProfile
    $campaignValidator=if($CorpusProfile -ceq 'UciDryBeanHoldout20261020'){'Assert-KhcDryBeanHoldoutCampaign'}elseif($isCanterbury){'Assert-KhcCanterburyKcs1Campaign'}elseif($CorpusProfile -ceq 'JmaTokyoDaily2010_2025Holdout20261020'){'Assert-KhcJmaHoldoutCampaign'}elseif($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020'){'Assert-KhcTokyoPopulationHoldoutCampaign'}elseif($CorpusProfile -ceq 'LivedoorNews2012Holdout20261020'){'Assert-KhcLivedoorHoldoutCampaign'}elseif($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){'Assert-KhcNictKcs1HoldoutCampaign'}elseif($CorpusProfile -ceq 'NictWikiCorpusHoldout20261020'){'Assert-KhcNictHoldoutCampaign'}else{'Assert-KhcAozoraCampaign'}
    $profileMarker=& $campaignValidator -CampaignManifestSha256 $CampaignManifestSha256 -ExpectedTaskId $taskId
    $campaignDirectory=$fixedProfile.Directory
    $campaignManifestPath=Join-Path $campaignDirectory 'campaign-start.json'; $outputPath=Join-Path $campaignDirectory 'campaign-report.json'
    $expectedCampaignManifestSha=$CampaignManifestSha256
    $expectedWorkerSha=[string]$profileMarker.worker_sha256; $expectedRunnerSha=[string]$profileMarker.runner_sha256
    $expectedLifecycleSha=[string]$profileMarker.lifecycle_sha256
    $expectedInputPath=Get-KhcPortfolioInputZipPath $fixedProfile; $expectedInputSha=$fixedProfile.ZipSha256
    $expectedInputManifestSha=$fixedProfile.ManifestSha256; $expectedBytes=$fixedProfile.Bytes; $expectedFiles=$fixedProfile.Files
    $scope=$fixedProfile.Scope
    if($isCanterbury -or $CorpusProfile -cin @('NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){$expectedCliSha=$fixedProfile.CliSha256; $expectedSourceManifestSha=$fixedProfile.SourceManifestSha256}
}elseif($PSBoundParameters.ContainsKey('CampaignManifestSha256')){throw 'The existing e-Gov campaign marker SHA cannot be overridden.'}

if($RunIds.Count -ne 20 -or @($RunIds|Select-Object -Unique).Count -ne 20){throw 'Supply exactly 20 unique lifecycle run IDs in execution order.'}
if($CampaignStartedUtc.Offset.Ticks -ne 0 -or $CampaignFinishedUtc.Offset.Ticks -ne 0 -or $StartGateStartedUtc.Offset.Ticks -ne 0 -or $StartGateFinishedUtc.Offset.Ticks -ne 0 -or
   $CampaignFinishedUtc -lt $CampaignStartedUtc -or ($CampaignFinishedUtc-$CampaignStartedUtc).TotalSeconds -gt 1800){throw 'Campaign timestamps must be UTC and elapsed time must remain within the fixed 1,800-second wall cap.'}
if($StartGateFinishedUtc -lt $StartGateStartedUtc -or ($StartGateFinishedUtc-$StartGateStartedUtc).TotalSeconds -lt 4 -or ($StartGateFinishedUtc-$StartGateStartedUtc).TotalSeconds -gt 20){throw 'External CPU start-gate interval must cover five one-second samples.'}
if(@($StartGateCpuPercent|Where-Object{[double]::IsNaN($_)-or[double]::IsInfinity($_)-or$_-lt0-or$_-gt15}).Count -ne 0){throw 'External CPU start gate did not remain at or below 15 percent.'}
if($StartGateStartedUtc -lt $CampaignStartedUtc){throw 'CPU start gate precedes campaign timer start.'}
Assert-Hash $workerPath $expectedWorkerSha
Assert-Hash $runnerPath $expectedRunnerSha
Assert-Hash $lifecyclePath $expectedLifecycleSha
Assert-Hash $diskBudgetPath $expectedDiskBudgetSha
Assert-Hash $expectedCliPath $expectedCliSha
Assert-Hash $expectedSevenPath $expectedSevenSha
Assert-Hash $expectedInputPath $expectedInputSha
Assert-Hash $campaignManifestPath $expectedCampaignManifestSha
$campaignManifest=Read-Json $campaignManifestPath
$fixedCampaignStartedUtc=To-UtcDateTimeOffset $campaignManifest.started_utc 'campaign.started_utc'
$fixedCampaignDeadlineUtc=To-UtcDateTimeOffset $campaignManifest.deadline_utc 'campaign.deadline_utc'
if($campaignManifest.schema -ne 1 -or [string]$campaignManifest.campaign_id -cnotmatch '^[0-9a-f]{32}$' -or [string]$campaignManifest.task_id -cne $taskId -or
   $fixedCampaignStartedUtc.Offset.Ticks -ne 0 -or $fixedCampaignDeadlineUtc.Offset.Ticks -ne 0 -or $CampaignStartedUtc -ne $fixedCampaignStartedUtc -or
   $fixedCampaignDeadlineUtc -ne $fixedCampaignStartedUtc.AddSeconds(1800) -or $CampaignFinishedUtc -lt $fixedCampaignStartedUtc -or
   $CampaignFinishedUtc -gt $fixedCampaignDeadlineUtc -or [string]$campaignManifest.worker_sha256 -cne $expectedWorkerSha -or
   [string]$campaignManifest.runner_sha256 -cne $expectedRunnerSha -or [string]$campaignManifest.lifecycle_sha256 -cne $expectedLifecycleSha -or
   [string]$campaignManifest.disk_budget_sha256 -cne $expectedDiskBudgetSha -or [string]$campaignManifest.source_manifest_sha256 -cne $expectedSourceManifestSha -or
   [string]$campaignManifest.cli_sha256 -cne $expectedCliSha -or [string]$campaignManifest.seven_zip_sha256 -cne $expectedSevenSha -or
   [string]$campaignManifest.input_zip_sha256 -cne $expectedInputSha -or [string]$campaignManifest.input_manifest_sha256 -cne $expectedInputManifestSha -or
   [int]$campaignManifest.run_count -ne 20 -or [long]$campaignManifest.run_bytes -ne $capBytes -or [int]$campaignManifest.run_entries -ne $capEntries -or
   [int]$campaignManifest.per_run_timeout_seconds -ne 300 -or [int]$campaignManifest.campaign_wall_seconds -ne 1800 -or
   [int]$campaignManifest.command_timeout_seconds -ne 60 -or [long]$campaignManifest.process_memory_bytes -ne $memoryBytes -or
   [int]$campaignManifest.cpu_gate_max_percent -ne 15 -or [string]$campaignManifest.schedule -cne 'round 0 warmup; rounds 1-9 measured; alternate starting strategy by round parity'){
    throw 'Pre-registered campaign manifest identity, pins, schedule, or resource limits do not match.'
}
$aggregationStartedUtc=[DateTimeOffset]::UtcNow
if($aggregationStartedUtc -lt $fixedCampaignDeadlineUtc){throw 'Aggregation is allowed only after the complete fixed campaign window closes.'}
$currentSourceManifestSha=Source-Manifest ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src')))
if($currentSourceManifestSha -cne $expectedSourceManifestSha){throw 'Current Rust source manifest differs from registered screen source.'}
if((Hash $PSCommandPath) -cne $scriptSha){throw 'Aggregator source changed during its run.'}
if(Test-Path -LiteralPath $outputPath){throw 'Campaign report already exists; refusing to overwrite.'}

$previousTaskId=$env:KHC_STORAGE_TASK_ID
try{
    $env:KHC_STORAGE_TASK_ID=$taskId
    Import-Module $lifecyclePath -Force
    $registrationById=@{}
    $campaignRegistrations=[Collections.Generic.List[object]]::new()
    foreach($directory in Get-ChildItem -LiteralPath (Plain $runRoot) -Directory -Force){
        $runDirectory=Plain $directory.FullName
        if(-not (Test-Path -LiteralPath (Join-Path $runDirectory 'complete.json') -PathType Leaf)){throw "Pending lifecycle run blocks campaign aggregation: $runDirectory"}
        if($directory.Name -cnotmatch '^[0-9a-f]{32}$'){throw "Malformed lifecycle run directory: $runDirectory"}
        $recordPath=Plain (Join-Path $runDirectory 'run.json')
        if(-not (Test-Path -LiteralPath $recordPath -PathType Leaf)){throw "Lifecycle registration record is missing: $runDirectory"}
        $record=Read-Json $recordPath
        if([string]$record.run_id -cne $directory.Name){throw "Lifecycle registration identity mismatch: $runDirectory"}
        $registeredUtc=To-UtcDateTimeOffset $record.created_utc "$($directory.Name).run.created_utc"
        if($registeredUtc -lt $fixedCampaignStartedUtc -or $registeredUtc -gt $fixedCampaignDeadlineUtc){continue}
        if(-not [IO.Path]::IsPathFullyQualified([string]$record.work_directory) -or [long]$record.max_bytes -ne $capBytes -or [int]$record.max_entries -ne $capEntries){throw "Campaign lifecycle registration cap/path mismatch: $runDirectory"}
        $invocationPath=Plain (Join-Path $runDirectory 'invocation.clixml')
        if(-not (Test-Path -LiteralPath $invocationPath -PathType Leaf) -or (Get-Item -LiteralPath $invocationPath -Force).Length -gt 32768){throw "Campaign invocation receipt is missing or oversized: $($directory.Name)"}
        $invocationXml=Get-Content -LiteralPath $invocationPath -Raw -Encoding UTF8
        $invocation=[Management.Automation.PSSerializer]::Deserialize($invocationXml)
        $parameters=$invocation.parameters
        if($parameters -isnot [System.Collections.IDictionary]){throw "Campaign invocation parameters are not a dictionary: $($directory.Name)"}
        $expectedParameterNames=[string[]]@('WorkDirectory','CorpusProfile','Round','Strategy','KhcExecutable','SevenZipPath','InputRecoveryZip')
        if($null -ne $fixedProfile){$expectedParameterNames+=@('CampaignManifestSha256')}
        $actualParameterNames=[string[]]@($parameters.Keys|ForEach-Object{[string]$_})
        [Array]::Sort($expectedParameterNames,[StringComparer]::Ordinal)
        [Array]::Sort($actualParameterNames,[StringComparer]::Ordinal)
        if(($actualParameterNames -join "`n") -cne ($expectedParameterNames -join "`n")){throw "Campaign invocation parameter set mismatch: $($directory.Name)"}
        $work=[IO.Path]::GetFullPath([string]$record.work_directory)
        $invocationWork=if([IO.Path]::IsPathFullyQualified([string]$parameters['WorkDirectory'])){Plain ([string]$parameters['WorkDirectory'])}else{''}
        $roundValue=$parameters['Round']
        $roundIsInt=$roundValue -is [int]
        if([IO.Path]::GetFullPath([string]$invocation.script) -ine $workerPath -or
           $invocationWork -cne $work -or [IO.Path]::GetDirectoryName($work) -ine $workRoot -or $work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or
           [string]$parameters['CorpusProfile'] -cne $CorpusProfile -or -not $roundIsInt -or [int]$roundValue -lt 0 -or [int]$roundValue -gt 9 -or
           [string]$parameters['Strategy'] -cnotin @('portfolio-trial','7zip') -or
           [IO.Path]::GetFullPath([string]$parameters['KhcExecutable']) -cne $expectedCliPath -or
           [IO.Path]::GetFullPath([string]$parameters['SevenZipPath']) -cne $expectedSevenPath -or
           [IO.Path]::GetFullPath([string]$parameters['InputRecoveryZip']) -cne $expectedInputPath){throw "Campaign invocation does not match the fixed worker profile: $($directory.Name)"}
        if($null -ne $fixedProfile -and [string]$parameters['CampaignManifestSha256'] -cne $expectedCampaignManifestSha){throw "Fixed invocation start-marker SHA mismatch: $($directory.Name)"}
        $registration=[pscustomobject]@{run_id=$directory.Name;registered_utc=$registeredUtc;round=[int]$roundValue;strategy=[string]$parameters['Strategy'];work_directory=$work}
        $registrationById.Add($directory.Name,$registration)
        $campaignRegistrations.Add($registration)
    }
    if($campaignRegistrations.Count -ne 20){throw "Expected exactly 20 lifecycle registrations during the campaign, found $($campaignRegistrations.Count)."}
    $registrationOrder=[string[]]@($campaignRegistrations|Sort-Object registered_utc|ForEach-Object{[string]$_.run_id})
    $providedIds=[string[]]@($RunIds)
    if(($registrationOrder -join "`n") -cne ($providedIds -join "`n")){throw 'RunIds must equal every lifecycle registration in the campaign window, in execution order; failed or retried samples are not accepted.'}
    $items=[Collections.Generic.List[object]]::new()
    foreach($runId in $RunIds){
        $item=Read-RunReport $runId
        $registration=$registrationById[$runId]
        if([int]$item.round -ne [int]$registration.round -or [string]$item.strategy -cne [string]$registration.strategy -or [string]$item.work_directory -cne [string]$registration.work_directory){throw "Invocation and completed report disagree: $runId"}
        $items.Add($item)
    }
    $ordered=@($items|Sort-Object registered_utc)
    if($ordered.Count -ne 20){throw 'Campaign sample count mismatch.'}
    for($i=0;$i -lt 20;$i++){
        $round=[int][Math]::Floor($i/2)
        $strategy=if($round%2 -eq 0){if($i%2 -eq 0){'portfolio-trial'}else{'7zip'}}else{if($i%2 -eq 0){'7zip'}else{'portfolio-trial'}}
        if([int]$ordered[$i].round -ne $round -or [string]$ordered[$i].strategy -cne $strategy){throw "Alternating round order mismatch at sample $i."}
        if($i -gt 0 -and $ordered[$i].registered_utc -le $ordered[$i-1].registered_utc){throw 'Lifecycle registration timestamps must be strictly increasing.'}
        $completedUtc=To-UtcDateTimeOffset $ordered[$i].complete.CompletedUtc "$($ordered[$i].run_id).complete.CompletedUtc"
        if($ordered[$i].registered_utc -lt $CampaignStartedUtc -or $ordered[$i].started_utc -lt $ordered[$i].registered_utc -or
           $completedUtc -lt $ordered[$i].finished_utc -or $completedUtc -gt $CampaignFinishedUtc){throw "Sample lifecycle order/window mismatch: $($ordered[$i].run_id)"}
        if($i -eq 0 -and $ordered[$i].runner_started_utc -lt $StartGateFinishedUtc){throw 'First runner began before the external CPU start gate completed.'}
        if($i -gt 0 -and $ordered[$i].runner_started_utc -lt (To-UtcDateTimeOffset $ordered[$i-1].complete.CompletedUtc "$($ordered[$i-1].run_id).complete.CompletedUtc")){throw 'The next runner began before prior lifecycle cleanup completed.'}
        if($ordered[$i].runner_started_utc -lt $CampaignStartedUtc){throw "Runner began before the campaign timer: $($ordered[$i].run_id)"}
        if($completedUtc -lt $ordered[$i].runner_finished_utc){throw "Lifecycle cleanup predates runner completion: $($ordered[$i].run_id)"}
        if($i -gt 0 -and (To-UtcDateTimeOffset $ordered[$i-1].complete.CompletedUtc "$($ordered[$i-1].run_id).complete.CompletedUtc") -ge $ordered[$i].registered_utc){throw 'Each prior lifecycle cleanup must complete before the next registration.'}
        $registration=$registrationById[$ordered[$i].run_id]
        if([string]$registration.work_directory -cne [string]$ordered[$i].work_directory){throw "Invocation and completed run work directories disagree: $($ordered[$i].run_id)"}
    }
    if($StartGateFinishedUtc -gt $ordered[0].registered_utc){throw 'External CPU start gate did not finish before first registration.'}
    $summaries=@()
    foreach($strategy in @('portfolio-trial','7zip')){
        $all=@($ordered|Where-Object{$_.strategy -ceq $strategy})
        if($all.Count -ne 10 -or @($all|ForEach-Object{$_.sample.archive_sha256}|Select-Object -Unique).Count -ne 1 -or @($all|ForEach-Object{$_.sample.archive_bytes}|Select-Object -Unique).Count -ne 1){throw "Nondeterministic archive output: $strategy"}
        $measured=@($all|Where-Object{$_.round -gt 0})
        $summary=[ordered]@{strategy=$strategy;measured_samples=9;archive_bytes=[long]$all[0].sample.archive_bytes;archive_sha256=[string]$all[0].sample.archive_sha256}
        foreach($phase in @('create','extract')){
            foreach($metric in @('wall_ms','cpu_ms','os_peak_working_set_bytes','os_peak_paged_memory_bytes','sampled_private_bytes_max')){
                $summary["${phase}_${metric}"]=Median ([double[]]@($measured|ForEach-Object{[double]$_.sample.$phase.$metric}))
            }
        }
        $summaries+=@([pscustomobject]$summary)
    }
    $candidate=@($summaries|Where-Object{$_.strategy -ceq 'portfolio-trial'})[0]
    $seven=@($summaries|Where-Object{$_.strategy -ceq '7zip'})[0]
    $paired=@()
    foreach($round in 1..9){
        $a=@($ordered|Where-Object{$_.round -eq $round -and $_.strategy -ceq 'portfolio-trial'})[0]
        $b=@($ordered|Where-Object{$_.round -eq $round -and $_.strategy -ceq '7zip'})[0]
        $paired+=@([pscustomobject]@{round=$round;first_strategy=if($round%2 -eq 0){'portfolio-trial'}else{'7zip'};archive_byte_delta_candidate_minus_7zip=[long]$a.sample.archive_bytes-[long]$b.sample.archive_bytes;create_wall_delta_ms_candidate_minus_7zip=[double]$a.sample.create.wall_ms-[double]$b.sample.create.wall_ms;extract_wall_delta_ms_candidate_minus_7zip=[double]$a.sample.extract.wall_ms-[double]$b.sample.extract.wall_ms})
    }
    $sizePass=([long]$candidate.archive_bytes*100L -le [long]$seven.archive_bytes*95L)
    $timePass=([double]$candidate.create_wall_ms.median -le [double]$seven.create_wall_ms.median -and [double]$candidate.extract_wall_ms.median -le [double]$seven.extract_wall_ms.median)
    $campaign=[ordered]@{
        status='completed';campaign_id=[string]$campaignManifest.campaign_id;campaign_manifest_sha256=$expectedCampaignManifestSha;scope=$scope;protocol='PortfolioTrial revision 10 versus pinned 7-Zip 26.04; ten registered alternating rounds, one strategy sample per run.'
        campaign_deadline_utc=$fixedCampaignDeadlineUtc.ToString('o');aggregation_started_utc=$aggregationStartedUtc.ToString('o')
        campaign_started_utc=$CampaignStartedUtc.ToUniversalTime().ToString('o');campaign_finished_utc=$CampaignFinishedUtc.ToUniversalTime().ToString('o');campaign_elapsed_seconds=[Math]::Round(($CampaignFinishedUtc-$CampaignStartedUtc).TotalSeconds,3)
        external_cpu_start_gate=[ordered]@{started_utc=$StartGateStartedUtc.ToUniversalTime().ToString('o');finished_utc=$StartGateFinishedUtc.ToUniversalTime().ToString('o');limit_percent=15;required_samples=5;readings_percent=$StartGateCpuPercent}
        fixed=[ordered]@{input_zip_sha256=$expectedInputSha;input_manifest_sha256=$expectedInputManifestSha;raw_files=$expectedFiles;raw_bytes=$expectedBytes;source_manifest_sha256=$expectedSourceManifestSha;khc_cli_sha256=$expectedCliSha;khc_version='unlhare-cli 1.0.4';khc_encode_threads=1;khc_decode_workers=4;seven_zip_sha256=$expectedSevenSha;seven_zip_version='26.04';seven_zip_create_options='-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off';seven_zip_extract_options='x -mmt=4';run_cap_bytes=$capBytes;entry_cap=$capEntries;child_memory_cap_bytes=$memoryBytes;command_timeout_seconds=60;aggregate_wall_cap_seconds=1800}
        evidence=[ordered]@{worker_sha256=$expectedWorkerSha;runner_sha256=$expectedRunnerSha;lifecycle_sha256=$expectedLifecycleSha;aggregator_sha256=$scriptSha;run_ids=@($ordered|ForEach-Object{$_.run_id});samples=@($ordered|ForEach-Object{[pscustomobject]@{run_id=$_.run_id;runner_started_utc=$_.runner_started_utc.ToUniversalTime().ToString('o');registered_utc=$_.registered_utc.ToUniversalTime().ToString('o');started_utc=$_.started_utc.ToUniversalTime().ToString('o');finished_utc=$_.finished_utc.ToUniversalTime().ToString('o');runner_finished_utc=$_.runner_finished_utc.ToUniversalTime().ToString('o');runner_result_sha256=$_.runner_result_sha256;recovery_sha256=$_.recovery_sha256;report_sha256=$_.report_sha256;round=$_.round;strategy=$_.strategy;archive_bytes=$_.sample.archive_bytes;archive_sha256=$_.sample.archive_sha256;create_wall_ms=$_.sample.create.wall_ms;extract_wall_ms=$_.sample.extract.wall_ms}})}
        summary=$summaries;paired_rounds=$paired;candidate_size_passed=$sizePass;candidate_time_passed=$timePass;candidate_screen_passed=($sizePass-and$timePass);candidate_decision=if($isHoldout){if($sizePass-and$timePass){'holdout-screen-pass'}else{'holdout-screen-no-go'}}else{if($sizePass-and$timePass){'development-screen-pass'}else{'development-screen-no-go'}}
        holdout_evaluated=$isHoldout;general_superiority_claimed=$false;final_goal_achieved=$false
    }
    if($null -ne $fixedProfile){
        $campaign.development_only=(-not $isHoldout)
        $campaign.corpus_profile=$CorpusProfile
        $campaign.fixed.input_zip_path=$expectedInputPath; $campaign.fixed.input_zip_bytes=$fixedProfile.ZipBytes
        $campaign.fixed.input_entries=$fixedProfile.Entries
        $campaign.fixed.source_family=$fixedProfile.SourceFamily; $campaign.fixed.source_family_count=1
        if($CorpusProfile -ceq 'UciDryBeanHoldout20261020'){
            $campaign.source_condition=$fixedProfile.Name
            $campaign.single_family_screen_only=$true; $campaign.aggregate_category_count=0
            $campaign.candidate_decision=if($sizePass-and$timePass){'one-family-holdout-screen-pass'}else{'one-family-holdout-screen-no-go'}
            $campaign.fixed.khc_source_manifest_sha256=$fixedProfile.KhcSourceManifestSha256
            $campaign.fixed.input_entry_prefix=$fixedProfile.EntryPrefix; $campaign.fixed.source_provenance=$fixedProfile.Provenance
        }
        if($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){
            $campaign.source_condition=$fixedProfile.Name
            $campaign.fixed.khc_source_manifest_sha256=$fixedProfile.KhcSourceManifestSha256
            $campaign.fixed.input_entry_prefix=$fixedProfile.EntryPrefix
        }
        if($isHoldout){
            $campaign.input_role='holdout-only'; $campaign.holdout_only=$true; $campaign.training_allowed=$false; $campaign.tuning_allowed=$false
            $campaign.fixed.start_date=$fixedProfile.StartDate; $campaign.fixed.end_date=$fixedProfile.EndDate; $campaign.fixed.fields=$fixedProfile.Fields
            if($CorpusProfile -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')){
                $campaign.fixed.source_provenance=$fixedProfile.Provenance
                $campaign.fixed.listing_stdout_bytes=$fixedProfile.ListingOutputBytes; $campaign.fixed.listing_stderr_bytes=2KB
            }
            if($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020'){
                $campaign.fixed.source_page=$fixedProfile.SourcePage
                $campaign.fixed.source_catalog_page=$fixedProfile.SourceCatalogPage
                $campaign.fixed.source_direct_csv_url=$fixedProfile.SourceDirectCsvUrl
                $campaign.fixed.source_attribution=$fixedProfile.SourceAttribution
                $campaign.fixed.source_license_label=$fixedProfile.SourceLicenseLabel
                $campaign.fixed.source_license_version=$fixedProfile.SourceLicenseVersion
                $campaign.fixed.source_license_note=$fixedProfile.SourceLicenseNote
                $campaign.fixed.source_content_handling=$fixedProfile.SourceContentHandling
            }
        }elseif($isCanterbury){
            $campaign.input_role='development-only'; $campaign.holdout_only=$false; $campaign.training_allowed=$true; $campaign.tuning_allowed=$true
            $campaign.source_condition=$fixedProfile.Name
            $campaign.fixed.khc_source_manifest_sha256=$fixedProfile.KhcSourceManifestSha256
            $campaign.fixed.input_entry_prefix=$fixedProfile.EntryPrefix
        }else{
            $campaign.fixed.candidate_manifest_sha256=$fixedProfile.CandidateManifestSha256; $campaign.fixed.development_work_ids=@(424,752)
        }
        $null=& $campaignValidator -CampaignManifestSha256 $CampaignManifestSha256 -ExpectedTaskId $taskId
    }
    $parent=Plain ([IO.Path]::GetDirectoryName($outputPath))
    if($parent -cne [IO.Path]::GetFullPath($campaignDirectory) -or -not (Test-Path -LiteralPath $parent -PathType Container)){throw 'Fixed report parent path is missing or mismatched.'}
    $json=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $campaign -Depth 32))
    if($json.Length -gt 1MB){throw 'Aggregate campaign report exceeded its fixed 1 MiB bound.'}
    $stream=[IO.File]::Open($outputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($json,0,$json.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    Write-Output (ConvertTo-Json -InputObject ([ordered]@{status=$campaign.status;candidate_decision=$campaign.candidate_decision;candidate_screen_passed=$campaign.candidate_screen_passed;output_path=$outputPath;output_sha256=(Hash $outputPath)}) -Compress)
}finally{$env:KHC_STORAGE_TASK_ID=$previousTaskId}
