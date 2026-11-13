#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName='Generic')]
param(
    [Parameter(Mandatory,ParameterSetName='Generic')][string]$ScriptPath,
    [Parameter(Mandatory,ParameterSetName='Generic')][hashtable]$ScriptParameters,
    [Parameter(ParameterSetName='Generic')][ValidateRange(1,128)][int]$MaxRunMiB=32,
    [Parameter(ParameterSetName='Generic')][ValidateRange(0,4096)][int]$MaxEntries=0,
    [Parameter(ParameterSetName='Generic')][ValidateRange(1,1800)][int]$TimeoutSeconds=300,
    [Parameter(Mandatory,ParameterSetName='MacCdfCandidateE2e')][switch]$MacCdfCandidateE2e,
    [Parameter(Mandatory,ParameterSetName='MacCdfCandidateE2e')][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ProtocolSha256
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$candidateEnvelopeTimer=$null
if($PSCmdlet.ParameterSetName -ceq 'MacCdfCandidateE2e'){
    $candidateEnvelopeTimer=[Diagnostics.Stopwatch]::StartNew()
    if(-not $MacCdfCandidateE2e){throw 'MacCdfCandidateE2e must be explicitly true.'}
    $ScriptPath='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-cdf-candidate-e2e.ps1'
    $ScriptParameters=@{ProtocolPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-e2e-protocol.json');ProtocolSha256=$ProtocolSha256}
    $MaxRunMiB=8;$MaxEntries=96;$TimeoutSeconds=360
}
if ($ScriptParameters.ContainsKey('CorpusProfile') -and [string]$ScriptParameters['CorpusProfile'] -ieq 'UciTabularDevelopment20261020') { throw 'UCI development-only metadata has no admitted runnable wrapper and is excluded from holdout registration and evaluation.' }
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force
function Get-KhcSourceManifestSha256([string]$Root) {
    $rootPath=[IO.Path]::GetFullPath($Root)
    if(-not (Test-Path -LiteralPath $rootPath -PathType Container) -or
       ((Get-Item -LiteralPath $rootPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw "Invalid KHC source root: $rootPath"
    }
    $pathsByName=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($item in Get-ChildItem -LiteralPath $rootPath -Filter '*.rs' -File -Recurse -Force -ErrorAction Stop){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw "KHC source is a reparse point: $($item.FullName)"}
        $relative=[IO.Path]::GetRelativePath($rootPath,$item.FullName).Replace('\','/')
        $pathsByName.Add($relative,$item.FullName)
    }
    $names=[string[]]$pathsByName.Keys
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $builder=[Text.StringBuilder]::new()
    foreach($name in $names){
        $path=$pathsByName[$name]
        $item=Get-Item -LiteralPath $path -Force
        $sha=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $null=$builder.Append($name).Append([char]9).Append($item.Length).Append([char]9).Append($sha).Append([char]10)
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
}
$scriptFile=(Get-Item -LiteralPath $ScriptPath -ErrorAction Stop).FullName
$macNativeWorker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'mac-spatial-mdl-e2e.ps1'))
$macNativeAdmission=$scriptFile -ceq $macNativeWorker
$candidateE2eKind=& (Get-Module storage-lifecycle) {Get-KhcMacCandidateE2eKind}
$macCandidateAdmission=$scriptFile -ceq $candidateE2eKind.Worker
if($macCandidateAdmission){
    if($PSCmdlet.ParameterSetName -cne 'MacCdfCandidateE2e'){throw 'Candidate E2E requires its dedicated parameter set.'}
    & (Get-Module storage-lifecycle) {param($path,$sha) $null=Read-KhcMacCandidateE2eProtocol $path $sha} $ScriptParameters.ProtocolPath $ScriptParameters.ProtocolSha256
}
if($macNativeAdmission){
    if($scriptFile -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-spatial-mdl-e2e.ps1' -or $MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $TimeoutSeconds -ne 360 -or $ScriptParameters.Count -ne 2 -or -not $ScriptParameters.ContainsKey('ProtocolPath') -or -not $ScriptParameters.ContainsKey('ProtocolSha256')){throw 'Remote ps-free native E2E requires only fixed ProtocolPath/ProtocolSha256 and exact 8MiB/96 entries/360 seconds.'}
    & $macNativeWorker @ScriptParameters -ValidateProtocolOnly
}
$macReferenceType=if($scriptFile -ceq 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-canterbury-continuous-reference.ps1'){'khc-mac-canterbury-continuous-reference-v1'}else{'khc-mac-canterbury-reference-v1'}
$macReferenceKind=& (Get-Module storage-lifecycle) {param($name)Get-KhcMacReferenceKind $name} $macReferenceType
$macReferenceWorker=$macReferenceKind.Worker
$macReferenceAdmission=$scriptFile -ceq $macReferenceWorker
if($macReferenceAdmission){
    if($MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $ScriptParameters.Count -ne 2 -or -not $ScriptParameters.ContainsKey('ProtocolPath') -or -not $ScriptParameters.ContainsKey('ProtocolSha256')){throw 'Reference pilot requires only fixed ProtocolPath/ProtocolSha256 and exact 8MiB/96 entries.'}
    & (Get-Module storage-lifecycle) {param($name,$worker,$path,$seconds)Assert-KhcMacReferenceInvocationPair $name $worker $path $seconds} $macReferenceType $scriptFile $ScriptParameters.ProtocolPath $TimeoutSeconds
    & $macReferenceWorker @ScriptParameters -ValidateProtocolOnly
}
$remoteAdmission=$macNativeAdmission -or $macReferenceAdmission -or $macCandidateAdmission
$spatialReplayFrontier=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-replay-frontier.ps1'))
$compactSpatialReplayFrontier=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'compact-spatial-replay-frontier.ps1'))
$foldedSpatialReplayFrontier=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'folded-spatial-replay-frontier.ps1'))
$allowed=@('compare.ps1','compare-solid.ps1','measure-internal.ps1','causal-bayes-fast-bwt/compare.ps1','test-storage-staged-e2e.ps1','version-delta-screen.ps1','record-fast-screen.ps1','record-fast-7zip-screen.ps1','record-adaptive-screen.ps1','shared-history-screen.ps1','greedy-entropy-bound-screen.ps1','all-class-static/run-frame-e2e.ps1','product-pipeline-e2e.ps1','causal-row-copy-spatial-bits/run-e2e.ps1','product-spatial-e2e.ps1','spatial-mdl-e2e.ps1','historical-archive-compat-e2e.ps1','spatial-bits-product-screen.ps1','spatial-mdl-7zip-product-screen.ps1','spatial-mdl-canterbury-size-screen.ps1','digit-run-size-probe.ps1','cross-file-dedup-size-probe.ps1','html-span-size-probe.ps1','portfolio-size-pilot.ps1','portfolio-7zip-product-screen.ps1') | ForEach-Object {[IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_))}
if ($scriptFile -ieq $spatialReplayFrontier) {
    if ($scriptFile -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\spatial-replay-frontier.ps1' -or
        $MaxRunMiB -ne 28 -or $MaxEntries -ne 128 -or $TimeoutSeconds -ne 900 -or
        $ScriptParameters.Count -ne 2 -or -not $ScriptParameters.ContainsKey('ProtocolPath') -or
        -not $ScriptParameters.ContainsKey('ProtocolSha256')) {
        throw 'Spatial replay frontier requires its canonical worker, only ProtocolPath/ProtocolSha256, and exact 28MiB/128 entries/900 seconds.'
    }
    # 登録前の読取専用検証。workerは登録後CreateNewでrun IDへclaimを結び付ける。
    & $spatialReplayFrontier @ScriptParameters -ValidateProtocolOnly
    $allowed+= $spatialReplayFrontier
}
if($macNativeAdmission){$allowed+=$macNativeWorker}
if($macCandidateAdmission){$allowed+=$candidateE2eKind.Worker}
if($macReferenceAdmission){$allowed+=$macReferenceWorker}
if ($scriptFile -ieq $compactSpatialReplayFrontier) {
    if ($scriptFile -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\compact-spatial-replay-frontier.ps1' -or
        $MaxRunMiB -ne 28 -or $MaxEntries -ne 128 -or $TimeoutSeconds -ne 900 -or
        $ScriptParameters.Count -ne 2 -or -not $ScriptParameters.ContainsKey('ProtocolPath') -or
        -not $ScriptParameters.ContainsKey('ProtocolSha256')) {
        throw 'Compact spatial replay frontier requires its canonical worker, only ProtocolPath/ProtocolSha256, and exact 28MiB/128 entries/900 seconds.'
    }
    & $compactSpatialReplayFrontier @ScriptParameters -ValidateProtocolOnly
    $allowed+= $compactSpatialReplayFrontier
}
if ($scriptFile -ieq $foldedSpatialReplayFrontier) {
    if ($scriptFile -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\folded-spatial-replay-frontier.ps1' -or
        $MaxRunMiB -ne 28 -or $MaxEntries -ne 128 -or $TimeoutSeconds -ne 900 -or
        $ScriptParameters.Count -ne 2 -or -not $ScriptParameters.ContainsKey('ProtocolPath') -or
        -not $ScriptParameters.ContainsKey('ProtocolSha256')) {
        throw 'Folded spatial replay frontier requires its canonical worker, only ProtocolPath/ProtocolSha256, and exact 28MiB/128 entries/900 seconds.'
    }
    & $foldedSpatialReplayFrontier @ScriptParameters -ValidateProtocolOnly
    $allowed+= $foldedSpatialReplayFrontier
}
if ($scriptFile -notin $allowed) { throw '清掃契約を接続した登録済みの比較・候補screenまたは小容量E2Eだけを指定してください。旧実験/清掃scriptは履歴資料です。' }
$portfolioProductScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'portfolio-7zip-product-screen.ps1'))
if($scriptFile -ine $portfolioProductScreen -and $MaxRunMiB -gt 32){
    throw '32 MiB超のrunは事前登録済みe-Gov XML/CSV PortfolioTrial product screenに限ります。'
}
if ($ScriptParameters.ContainsKey('WorkDirectory')) { throw 'WorkDirectoryはこの入口が生成します。手動指定しないでください。' }
if($ScriptParameters.Count -gt 64){throw '実験の引数項目が64を超えています。'}
$productPipelineScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'product-pipeline-e2e.ps1'))
$storageFixtureScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'test-storage-staged-e2e.ps1'))
$productSpatialScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'product-spatial-e2e.ps1'))
$spatialMdlE2eScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-mdl-e2e.ps1'))
$spatialMdlProductScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-mdl-7zip-product-screen.ps1'))
$spatialMdlCanterburySizeScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-mdl-canterbury-size-screen.ps1'))
$spatialScreenScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-bits-product-screen.ps1'))
$adaptiveScreenScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'record-adaptive-screen.ps1'))
$recordFast7zipScript=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'record-fast-7zip-screen.ps1'))
$crossFileDedupScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'cross-file-dedup-size-probe.ps1'))
$htmlSpanScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'html-span-size-probe.ps1'))
$portfolioSizeScreen=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'portfolio-size-pilot.ps1'))
if($scriptFile -ieq $portfolioProductScreen -and ($MaxRunMiB -ne 32 -or $MaxEntries -ne 512 -or $TimeoutSeconds -ne 300)){
    throw 'Each fixed e-Gov revision-10/7-Zip sample requires MaxRunMiB 32 / MaxEntries 512 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $spatialScreenScript -and ($MaxRunMiB -ne 5 -or $MaxEntries -ne 64 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed spatial product screen requires MaxRunMiB 5 / MaxEntries 64 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $adaptiveScreenScript -and ($MaxRunMiB -ne 5 -or $MaxEntries -ne 64 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed KRS3 development screen requires MaxRunMiB 5 / MaxEntries 64 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $spatialMdlE2eScript -and ($MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $TimeoutSeconds -ne 300)){
throw 'The fixed SpatialMdl/revision-10 portfolio E2E requires MaxRunMiB 8 / MaxEntries 96 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $spatialMdlProductScreen -and ($MaxRunMiB -ne 16 -or $MaxEntries -ne 96 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed SpatialMdl/7-Zip ptt5 product screen requires MaxRunMiB 16 / MaxEntries 96 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $spatialMdlCanterburySizeScreen -and ($MaxRunMiB -ne 32 -or $MaxEntries -ne 96 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed SpatialMdl/Canterbury11 size-only screen requires MaxRunMiB 32 / MaxEntries 96 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $crossFileDedupScreen -and ($MaxRunMiB -ne 8 -or $MaxEntries -ne 64 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed CDC exact-reference pilot requires MaxRunMiB 8 / MaxEntries 64 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $htmlSpanScreen -and ($MaxRunMiB -ne 3 -or $MaxEntries -ne 64 -or $TimeoutSeconds -ne 120)){
    throw 'The fixed HTML span-separation pilot requires MaxRunMiB 3 / MaxEntries 64 / TimeoutSeconds 120 before registration.'
}
if($scriptFile -ieq $portfolioSizeScreen -and ($MaxRunMiB -ne 32 -or $MaxEntries -ne 96 -or $TimeoutSeconds -ne 300)){
    throw 'The fixed Canterbury11 block-portfolio size pilot requires MaxRunMiB 32 / MaxEntries 96 / TimeoutSeconds 300 before registration.'
}
if($scriptFile -ieq $portfolioSizeScreen){
    $pinnedPortfolioScreenSha='893d0fea9330d24d98a9abf21d13ce9540218093324b3151c5c88cb576c203cf'
    $expectedInput=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip')
    $expectedKhc=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
    $expectedProbe=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\examples\khc_portfolio_size_pilot.exe')
    $expectedSeven='C:\Program Files\7-Zip\7z.exe'
    $expectedProbeSha='fb595c1c8ab5b08135fa634c5d6b9e00ea6a2c7d3da8049f4d0aab06f52f6012'
    $expectedKhcSourceManifestSha='e24f0502e7ecccdd4933fcfc08217bfe11771eb6c229dc46877364a5754ec424'
    if(-not $ScriptParameters.ContainsKey('InputRecoveryZip') -or
       -not $ScriptParameters.ContainsKey('InputRecoveryZipSha256') -or
       -not $ScriptParameters.ContainsKey('ExpectedSourceManifestSha256') -or
       -not $ScriptParameters.ContainsKey('KhcExecutable') -or
       -not $ScriptParameters.ContainsKey('KhcExecutableSha256') -or
       -not $ScriptParameters.ContainsKey('ProbeExecutable') -or
       -not $ScriptParameters.ContainsKey('ProbeExecutableSha256') -or
       -not $ScriptParameters.ContainsKey('SevenZipPath') -or
       -not $ScriptParameters.ContainsKey('SevenZipSha256') -or
       -not $ScriptParameters.ContainsKey('ExpectedScreenSha256') -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['InputRecoveryZip']) -cne $expectedInput -or
       [string]$ScriptParameters['InputRecoveryZipSha256'] -cne 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb' -or
       [string]$ScriptParameters['ExpectedSourceManifestSha256'] -cne 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438' -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['KhcExecutable']) -cne $expectedKhc -or
       [string]$ScriptParameters['KhcExecutableSha256'] -cne '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3' -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['ProbeExecutable']) -cne $expectedProbe -or
       [string]$ScriptParameters['ProbeExecutableSha256'] -cne $expectedProbeSha -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['SevenZipPath']) -cne $expectedSeven -or
       [string]$ScriptParameters['SevenZipSha256'] -cne '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53' -or
       [string]$ScriptParameters['ExpectedScreenSha256'] -cne $pinnedPortfolioScreenSha){
        throw 'The Canterbury11 portfolio pilot requires exact preregistered input/tool parameters before registration.'
    }
    foreach($pin in @(
        [pscustomobject]@{path=$expectedInput;sha='b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'},
        [pscustomobject]@{path=$expectedKhc;sha='50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'},
        [pscustomobject]@{path=$expectedProbe;sha=$expectedProbeSha},
        [pscustomobject]@{path=$expectedSeven;sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'},
        [pscustomobject]@{path=$portfolioSizeScreen;sha=$pinnedPortfolioScreenSha},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\examples\khc_portfolio_size_pilot.rs'));sha='3f8bf9b6b8aaaca679f70822ec87e4c73d34f14a1542627d2c69b78141922707'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\main.rs'));sha='35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.toml'));sha='3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.lock'));sha='d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'));sha='511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disk-budget.ps1'));sha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd'}
    )){
        if(-not (Test-Path -LiteralPath $pin.path -PathType Leaf) -or
           (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha){
            throw "The Canterbury11 portfolio pilot pin does not match before registration: $($pin.path)"
        }
    }
    $khcSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\khc'))
    if((Get-KhcSourceManifestSha256 $khcSourceRoot) -cne $expectedKhcSourceManifestSha){
        throw 'The Canterbury11 portfolio pilot KHC source tree manifest changed before registration.'
    }
}
if($scriptFile -ieq $portfolioProductScreen){
    $pinnedPortfolioProductScreenSha='8789bad160e3dbdb1931267b80e4cd4da679cdc22d00f9b7e20f4417669e7a16'
    $expectedInput=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\egov-screen-20261020\input.zip')
    $expectedInputSha='861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099'
    $expectedLifecycleSha='e3953d42595b66aba8a40da393e13bfd32e269b75c7d443e207dbfc9a202ba0c'
    $expectedProfile='eGovLawXml20261016'; $expectedParameterCount=6
    $profileCampaign=$null
    $isCanterbury=$ScriptParameters.ContainsKey('CorpusProfile') -and [string]$ScriptParameters['CorpusProfile'] -ceq 'CanterburyDevelopmentKcs1CountLength20261020'
    $isNictKcs1=$ScriptParameters.ContainsKey('CorpusProfile') -and [string]$ScriptParameters['CorpusProfile'] -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'
    $expectedCliSha='3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b'
    $expectedSourceSha='0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404'
    if($ScriptParameters.ContainsKey('CorpusProfile') -and [string]$ScriptParameters['CorpusProfile'] -cin @('AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){
        if(-not $ScriptParameters.ContainsKey('CampaignManifestSha256')){throw 'This fixed profile requires a new immutable start-marker SHA before registration.'}
        $profile=Get-KhcPortfolioInputProfile ([string]$ScriptParameters['CorpusProfile'])
        $campaignValidator=if($profile.Name -ceq 'UciDryBeanHoldout20261020'){'Assert-KhcDryBeanHoldoutCampaign'}elseif($isCanterbury){'Assert-KhcCanterburyKcs1Campaign'}elseif($profile.Name -ceq 'JmaTokyoDaily2010_2025Holdout20261020'){'Assert-KhcJmaHoldoutCampaign'}elseif($profile.Name -ceq 'TokyoResidentRegister202101Holdout20261020'){'Assert-KhcTokyoPopulationHoldoutCampaign'}elseif($profile.Name -ceq 'LivedoorNews2012Holdout20261020'){'Assert-KhcLivedoorHoldoutCampaign'}elseif($profile.Name -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){'Assert-KhcNictKcs1HoldoutCampaign'}elseif($profile.Name -ceq 'NictWikiCorpusHoldout20261020'){'Assert-KhcNictHoldoutCampaign'}else{'Assert-KhcAozoraCampaign'}
        $profileCampaign=& $campaignValidator -CampaignManifestSha256 ([string]$ScriptParameters['CampaignManifestSha256']) -RequireOpenWindow
        $expectedProfile=$profile.Name; $expectedParameterCount=7
        $expectedInput=Get-KhcPortfolioInputZipPath $profile; $expectedInputSha=$profile.ZipSha256
        $pinnedPortfolioProductScreenSha=[string]$profileCampaign.worker_sha256
        $expectedLifecycleSha=[string]$profileCampaign.lifecycle_sha256
        if($isCanterbury -or $profile.Name -cin @('NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')){$expectedCliSha=$profile.CliSha256; $expectedSourceSha=$profile.SourceManifestSha256}
    }
    $expectedKhc=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
    $expectedSeven='C:\Program Files\7-Zip\7z.exe'
    $expectedParameterNames=@('CorpusProfile','Round','Strategy','InputRecoveryZip','KhcExecutable','SevenZipPath')
    if($null -ne $profileCampaign){$expectedParameterNames+=@('CampaignManifestSha256')}
    if($ScriptParameters.Count -ne $expectedParameterCount -or
       @($ScriptParameters.Keys | Where-Object { $_ -cnotin $expectedParameterNames }).Count -ne 0 -or
       -not $ScriptParameters.ContainsKey('CorpusProfile') -or
       -not $ScriptParameters.ContainsKey('Round') -or
       -not $ScriptParameters.ContainsKey('Strategy') -or
       -not $ScriptParameters.ContainsKey('InputRecoveryZip') -or
       -not $ScriptParameters.ContainsKey('KhcExecutable') -or
       -not $ScriptParameters.ContainsKey('SevenZipPath') -or
       [string]$ScriptParameters['CorpusProfile'] -cne $expectedProfile -or
       $ScriptParameters['Round'] -isnot [int] -or
       [int]$ScriptParameters['Round'] -lt 0 -or [int]$ScriptParameters['Round'] -gt 9 -or
       [string]$ScriptParameters['Strategy'] -cnotin @('portfolio-trial','7zip') -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['InputRecoveryZip']) -cne $expectedInput -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['KhcExecutable']) -cne $expectedKhc -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['SevenZipPath']) -cne $expectedSeven){
        throw 'The revision-10 e-Gov single-sample screen requires one fixed round/strategy, corpus profile and three pinned input/tool paths before registration.'
    }
    $portfolioProductPins=@(
        [pscustomobject]@{path=$expectedInput;sha=$expectedInputSha},
        [pscustomobject]@{path=$expectedKhc;sha=$expectedCliSha},
        [pscustomobject]@{path=$expectedSeven;sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'},
        [pscustomobject]@{path=$portfolioProductScreen;sha=$pinnedPortfolioProductScreenSha},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.toml'));sha='3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.lock'));sha='d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'));sha=$expectedLifecycleSha},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disk-budget.ps1'));sha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd'}
    )
    foreach($pin in $portfolioProductPins){
        if(-not (Test-Path -LiteralPath $pin.path -PathType Leaf) -or
           (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha){
            throw "The revision-10 e-Gov product-screen pin does not match before registration: $($pin.path)"
        }
    }
    $portfolioSourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src'))
    if((Get-KhcSourceManifestSha256 $portfolioSourceRoot) -cne $expectedSourceSha){
        throw 'The pinned Rust source manifest for the schedule-replay revision-10 portfolio CLI changed before registration.'
    }
    if(($isCanterbury -or $isNictKcs1 -or $expectedProfile -ceq 'UciDryBeanHoldout20261020') -and
       (Get-KhcSourceManifestSha256 (Join-Path $portfolioSourceRoot 'khc')) -cne $profile.KhcSourceManifestSha256){
        throw 'The KCS1 count-only KHC source manifest changed before registration.'
    }
    $sevenVersion=[Diagnostics.FileVersionInfo]::GetVersionInfo($expectedSeven)
    if($sevenVersion.FileMajorPart -ne 26 -or $sevenVersion.FileMinorPart -ne 4 -or $sevenVersion.FileBuildPart -ne 0 -or $sevenVersion.FilePrivatePart -ne 0){
        throw 'The revision-10 e-Gov product screen requires 7-Zip 26.04 before registration.'
    }
    $null=Assert-KhcPortfolioInput -CorpusProfile $expectedProfile -InputRecoveryZip $expectedInput -CampaignManifestSha256 ([string]$ScriptParameters['CampaignManifestSha256'])
}
$recordAdaptiveProductScreen=$scriptFile -ieq $recordFast7zipScript -and
    $ScriptParameters.ContainsKey('IncludeRecordAdaptiveCandidate') -and
    [bool]$ScriptParameters['IncludeRecordAdaptiveCandidate']
if($recordAdaptiveProductScreen -and ($MaxRunMiB -ne 12 -or $MaxEntries -ne 64 -or $TimeoutSeconds -ne 900)){
    throw 'The fixed KRS3 product comparison requires MaxRunMiB 12 / MaxEntries 64 / TimeoutSeconds 900 before registration.'
}
$recordFastSpeedFrontierScreen=$scriptFile -ieq $recordFast7zipScript -and
    $ScriptParameters.ContainsKey('SpeedFrontierStudy') -and [bool]$ScriptParameters['SpeedFrontierStudy']
$singleSealFrontier=$scriptFile -ieq $recordFast7zipScript -and $ScriptParameters.ContainsKey('SourceCondition') -and
    [string]$ScriptParameters['SourceCondition'] -ieq 'SingleSeal20261020'
if($singleSealFrontier -and -not $recordFastSpeedFrontierScreen){throw 'SingleSeal requires SpeedFrontierStudy.'}
if($recordFastSpeedFrontierScreen){
    if($recordAdaptiveProductScreen -or $MaxRunMiB -ne 28 -or $MaxEntries -ne 128 -or $TimeoutSeconds -ne 900 -or
       -not $ScriptParameters.ContainsKey('TimeoutSeconds') -or [int]$ScriptParameters['TimeoutSeconds'] -ne 900 -or
       -not $ScriptParameters.ContainsKey('SevenZipLevels') -or (@($ScriptParameters['SevenZipLevels']) -join ',' -cne '1,3,5,7,9')){
        throw 'The fixed KRS2 speed-frontier study requires 28MiB / 128 entries / 900 seconds, child timeout 900, and levels 1/3/5/7/9 before registration.'
    }
    if(-not $ScriptParameters.ContainsKey('InputRecoveryZip') -or
       -not $ScriptParameters.ContainsKey('InputRecoveryZipSha256') -or
       [string]$ScriptParameters['InputRecoveryZipSha256'] -cne '882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75' -or
       -not $ScriptParameters.ContainsKey('InputRecoveryMembers') -or @($ScriptParameters['InputRecoveryMembers']).Count -ne 1 -or
       [string]$ScriptParameters['InputRecoveryMembers'][0] -cne 'input/ptt5'){
        throw 'The fixed KRS2 speed-frontier study requires the pinned recovery ZIP and input/ptt5 before registration.'
    }
    if(-not $ScriptParameters.ContainsKey('KhcExecutable') -or -not $ScriptParameters.ContainsKey('SevenZipPath')){
        throw 'The fixed KRS2 speed-frontier study requires the pinned KHC CLI and 7-Zip paths before registration.'
    }
    if($singleSealFrontier){
        $singleSealCampaign=Assert-KhcSingleSealSpeedFrontierCampaign -RequireOpenWindow
        foreach($pair in @(@('InputRecoveryZip','input_recovery_zip'),@('KhcExecutable','khc_executable'),@('SevenZipPath','seven_zip_executable'))){
            if([string]$ScriptParameters[$pair[0]] -cne [string]$singleSealCampaign.Marker[$pair[1]]){throw 'SingleSeal requires the exact preregistered input/tool paths.'}
        }
    }else{
    foreach($pin in @(
        [pscustomobject]@{path=[string]$ScriptParameters['InputRecoveryZip'];sha='882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'},
        [pscustomobject]@{path=[string]$ScriptParameters['KhcExecutable'];sha='81bb1f3d0e0aa592317be13e0cc6c4224f19579e51a1382077ace884bb87c732'},
        [pscustomobject]@{path=[string]$ScriptParameters['SevenZipPath'];sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'}
    )){
        if(-not (Test-Path -LiteralPath $pin.path -PathType Leaf) -or
           (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha){
            throw "The fixed KRS2 speed-frontier study pin does not match before registration: $($pin.path)"
        }
    }
    }
}
if($scriptFile -ieq $spatialMdlProductScreen){
    $pinnedScreenSha='bcf3c51cc71ecd0861850baf99c2ef1f92e79b69650bae0dcf5b14761438c622'
    if((Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pinnedScreenSha){
        throw 'The preregistered revision-9 product screen source hash changed before registration.'
    }
    if(-not $ScriptParameters.ContainsKey('InputRecoveryZip') -or
       -not $ScriptParameters.ContainsKey('KhcExecutable') -or
       -not $ScriptParameters.ContainsKey('KhcExecutableSha256') -or
       -not $ScriptParameters.ContainsKey('SevenZipPath') -or
       -not $ScriptParameters.ContainsKey('SevenZipSha256') -or
       [string]$ScriptParameters['KhcExecutableSha256'] -cne '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3' -or
       [string]$ScriptParameters['SevenZipSha256'] -cne '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'){
        throw 'The revision-9 product screen requires exact pinned input/tool parameters before registration.'
    }
    if([IO.Path]::GetFullPath([string]$ScriptParameters['InputRecoveryZip']) -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\8a849a3267954242bcd8424b93526176\recovery.zip')){
        throw 'The revision-9 product screen requires the registered pinned ptt5 recovery path before registration.'
    }
    $revision9Pins=@(
        [pscustomobject]@{path=[string]$ScriptParameters['InputRecoveryZip'];sha='882e7108870c3de5d20de6e87ffc89f390c5d34630930aef73baed9171557f75'},
        [pscustomobject]@{path=[string]$ScriptParameters['KhcExecutable'];sha='50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'},
        [pscustomobject]@{path=[string]$ScriptParameters['SevenZipPath'];sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\khc\mod.rs'));sha='c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\main.rs'));sha='35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.toml'));sha='3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.lock'));sha='d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'));sha='511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3'}
    )
    foreach($pin in $revision9Pins){
        if(-not (Test-Path -LiteralPath $pin.path -PathType Leaf) -or
           (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha){
            throw "The preregistered revision-9 product screen pin does not match before registration: $($pin.path)"
        }
    }
}
if($scriptFile -ieq $spatialMdlCanterburySizeScreen){
    $pinnedSizeScreenSha='a297f0e278c9d8f7c3e06b23a12bdcb8ffe1546413f24193b93a330b1b80bcf8'
    if((Get-FileHash -LiteralPath $scriptFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pinnedSizeScreenSha){
        throw 'The preregistered revision-9 Canterbury11 size-screen source hash changed before registration.'
    }
    $expectedInput=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip')
    $expectedKhc=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
    $expectedSeven='C:\Program Files\7-Zip\7z.exe'
    if(-not $ScriptParameters.ContainsKey('InputRecoveryZip') -or
       -not $ScriptParameters.ContainsKey('InputRecoveryZipSha256') -or
       -not $ScriptParameters.ContainsKey('ExpectedSourceManifestSha256') -or
       -not $ScriptParameters.ContainsKey('KhcExecutable') -or
       -not $ScriptParameters.ContainsKey('KhcExecutableSha256') -or
       -not $ScriptParameters.ContainsKey('SevenZipPath') -or
       -not $ScriptParameters.ContainsKey('SevenZipSha256') -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['InputRecoveryZip']) -cne $expectedInput -or
       [string]$ScriptParameters['InputRecoveryZipSha256'] -cne 'b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb' -or
       [string]$ScriptParameters['ExpectedSourceManifestSha256'] -cne 'bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438' -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['KhcExecutable']) -cne $expectedKhc -or
       [string]$ScriptParameters['KhcExecutableSha256'] -cne '50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3' -or
       [IO.Path]::GetFullPath([string]$ScriptParameters['SevenZipPath']) -cne $expectedSeven -or
       [string]$ScriptParameters['SevenZipSha256'] -cne '95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'){
        throw 'The revision-9 Canterbury11 size screen requires exact preregistered input/tool parameters before registration.'
    }
    $sizeScreenPins=@(
        [pscustomobject]@{path=$expectedInput;sha='b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'},
        [pscustomobject]@{path=$expectedKhc;sha='50952a6e7781800b946f85a7493bea7ca0923b5a974f34db1ba2baf32d1de6e3'},
        [pscustomobject]@{path=$expectedSeven;sha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\khc\mod.rs'));sha='c3335017f8905364f66d797f992f10ba54a50707116cb224304acc4470ec41fa'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\main.rs'));sha='35ee6bd7a7d222db03f92a1647155c678d752b9a69e793b4749a665fa57c72aa'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\khc\block\mod.rs'));sha='861da675a6eee403e51a7d2130ad80414da765c72a5e37eca6966084067fd748'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\src\khc\spatial.rs'));sha='8b508ee1c876c0b581af1bba66cecb0e1b183db3eae31349033fa8a0ec374982'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.toml'));sha='3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\Cargo.lock'));sha='d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'storage-lifecycle.psm1'));sha='511ac35885416d0ee7deb6367f2f210d6bda3e71ced3001a590dd90426962ac3'},
        [pscustomobject]@{path=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'disk-budget.ps1'));sha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd'}
    )
    foreach($pin in $sizeScreenPins){
        if(-not (Test-Path -LiteralPath $pin.path -PathType Leaf) -or
           (Get-FileHash -LiteralPath $pin.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha){
            throw "The preregistered revision-9 Canterbury11 size-screen pin does not match before registration: $($pin.path)"
        }
    }
}
$requiredEntries=0
if($scriptFile -ieq $productPipelineScript){
    if($MaxRunMiB -lt 18){throw 'Canterbury product E2Eは実測inventoryとstaging余裕からMaxRunMiB 18以上が必要です。登録・子起動前に停止しました。'}
    $entryBudget=Get-KhcProductPipelineEntryBudget
    $requiredEntries=[int]$entryBudget.RequiredTreeEntries
}elseif($scriptFile -ieq $productSpatialScript){
    if($MaxRunMiB -lt 5){throw 'Product KCS1/KRS3 E2E requires MaxRunMiB 5 or larger before registration'}
    $requiredEntries=64
}elseif($scriptFile -ieq $spatialMdlE2eScript){
    $requiredEntries=64
}elseif($scriptFile -ieq $spatialMdlProductScreen){
    $requiredEntries=96
}elseif($scriptFile -ieq $spatialMdlCanterburySizeScreen){
    $requiredEntries=96
}elseif($scriptFile -ieq $portfolioProductScreen){
    $requiredEntries=512
}elseif($scriptFile -ieq $adaptiveScreenScript){
    $requiredEntries=64
}elseif($recordAdaptiveProductScreen){
    $requiredEntries=64
}elseif($recordFastSpeedFrontierScreen){
    $requiredEntries=128
}elseif($scriptFile -ieq $storageFixtureScript -and $ScriptParameters.ContainsKey('FixtureMode') -and [string]$ScriptParameters['FixtureMode'] -eq 'inventory-bound'){
    $requiredEntries=96
}
if($MaxEntries -eq 0 -and $requiredEntries -gt 0){$MaxEntries=$requiredEntries}
elseif($MaxEntries -lt $requiredEntries){throw "この登録済みE2Eのentry上限は少なくとも $requiredEntries 件です。MaxEntries=$MaxEntries ではrun登録・子起動・作業出力を行いません。"}
$taskPaths=Get-KhcStorageTaskPaths
$runnerStartedUtc=[DateTime]::UtcNow
$runnerShaAtStart=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
$work=Join-Path $taskPaths.WorkRoot ('run-'+[Guid]::NewGuid().ToString('N'))
if($remoteAdmission){
    $nativeParameters=@{};foreach($key in $ScriptParameters.Keys){$nativeParameters[$key]=$ScriptParameters[$key]};$nativeParameters.WorkDirectory=$work
    $nativeInvocationXml=[Management.Automation.PSSerializer]::Serialize([pscustomobject]@{script=$scriptFile;parameters=$nativeParameters},5)
    $nativeInvocationSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($nativeInvocationXml))).ToLowerInvariant()
}
if($singleSealFrontier){$null=Assert-KhcSingleSealSpeedFrontierCampaign -RequireOpenWindow}
$compactSpatialReplayAdmission=$scriptFile -ieq $compactSpatialReplayFrontier
$foldedSpatialReplayAdmission=$scriptFile -ieq $foldedSpatialReplayFrontier
$spatialReplayAdmission=$scriptFile -ieq $spatialReplayFrontier -or $compactSpatialReplayAdmission -or $foldedSpatialReplayAdmission
$replayAdmissionMutex=$null; $replayAdmissionHeld=$false
if($spatialReplayAdmission){
    $context=$null
    $replayAdmissionMutexName=if($foldedSpatialReplayAdmission){'Local\KHC-Folded-Spatial-Replay-Admission-goal-restore-20261019'}elseif($compactSpatialReplayAdmission){'Local\KHC-Compact-Spatial-Replay-Admission-goal-restore-20261019'}else{'Local\KHC-Spatial-Replay-Admission-goal-restore-20261019'}
    $replayAdmissionMutex=[Threading.Mutex]::new($false,$replayAdmissionMutexName)
    try{
        try{$replayAdmissionHeld=$replayAdmissionMutex.WaitOne(0)}
        catch [Threading.AbandonedMutexException]{$replayAdmissionHeld=$true;throw 'Abandoned spatial replay admission mutex; registration refused.'}
        if(-not $replayAdmissionHeld){throw 'Spatial replay admission mutex busy; registration refused.'}
        & $scriptFile @ScriptParameters -ValidateProtocolOnly
        $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB $MaxRunMiB -MaxEntries $MaxEntries
        $taskPaths=Get-KhcStorageTaskPaths
    }catch{
        if($null -ne $context){$context.Lock.Dispose()}
        if($replayAdmissionHeld){$replayAdmissionMutex.ReleaseMutex();$replayAdmissionHeld=$false}
        $replayAdmissionMutex.Dispose();throw
    }
}elseif($macCandidateAdmission){
    & (Get-Module storage-lifecycle) {param($clock) Assert-KhcCandidateSpawnBudget $clock} $candidateEnvelopeTimer
    $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB 8 -MaxEntries 96 -RemoteCandidateE2e -RemoteProtocolSha256 $ScriptParameters.ProtocolSha256 -RemoteInvocationSha256 $nativeInvocationSha
}elseif($macReferenceAdmission){
    $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB 8 -MaxEntries 96 -RemoteReference -RemoteReferenceProtocol $macReferenceType -RemoteProtocolSha256 $ScriptParameters.ProtocolSha256 -RemoteInvocationSha256 $nativeInvocationSha
}elseif($macNativeAdmission){
    $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB 8 -MaxEntries 96 -RemoteNativeE2e -RemoteProtocolSha256 $ScriptParameters.ProtocolSha256 -RemoteInvocationSha256 $nativeInvocationSha
}elseif($scriptFile -ieq $portfolioProductScreen){
    $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB $MaxRunMiB -MaxEntries $MaxEntries
}else{
    $context=New-KhcStorageRun -WorkDirectory $work -MaxRunMiB $MaxRunMiB -MaxEntries $MaxEntries
}
if(-not $spatialReplayAdmission){$taskPaths=Get-KhcStorageTaskPaths}
$process=$null; $started=$false; $failure=$null; $pending=$null; $job=$null; $gate=$null; $runRootPid=0
$exitCode=$null; $stdoutEof=$false; $stderrEof=$false; $active=$null
function Invoke-KhcRunDiskBudget {
    $previous = $env:KHC_STORAGE_RUN_RECORD
    $env:KHC_STORAGE_RUN_RECORD = $context.RecordPath
    try { $null = & (Join-Path $PSScriptRoot 'disk-budget.ps1') -WorkDirectory $work -MaxRunMiB $MaxRunMiB -MinFreeGiB 5 }
    finally { $env:KHC_STORAGE_RUN_RECORD = $previous }
}
try {
    if($spatialReplayAdmission){
        $claimPath=if($foldedSpatialReplayAdmission){(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\folded-zero-count-20261023\performance-claim.json')}elseif($compactSpatialReplayAdmission){(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\compact-replay-20261020\performance-claim.json')}else{(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\kcs1-replay-20261020\performance-claim.json')}
        $replayClaimSchema=if($foldedSpatialReplayAdmission){'kcs1-folded-replay-performance-v1'}elseif($compactSpatialReplayAdmission){'kcs1-compact-replay-performance-v1'}else{'kcs1-replay-performance-v1'}
        $claimed=[DateTime]::UtcNow
        $claimJson=[ordered]@{schema=$replayClaimSchema;run_id=$context.RunId;record_path=$context.RecordPath;record_sha256=(Get-FileHash -LiteralPath $context.RecordPath -Algorithm SHA256).Hash.ToLowerInvariant();work_directory=$work;protocol_path=$ScriptParameters.ProtocolPath;protocol_sha256=$ScriptParameters.ProtocolSha256;claimed_utc=$claimed.ToString('o');deadline_utc=$claimed.AddSeconds(900).ToString('o');retries=0} | ConvertTo-Json -Depth 5 -Compress
        $claimBytes=[Text.UTF8Encoding]::new($false).GetBytes($claimJson)
        $claimStream=[IO.File]::Open($claimPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        try{$claimStream.Write($claimBytes,0,$claimBytes.Length);$claimStream.Flush($true)}finally{$claimStream.Dispose()}
        $replayAdmissionMutex.ReleaseMutex();$replayAdmissionHeld=$false
        $replayAdmissionMutex.Dispose();$replayAdmissionMutex=$null
    }
    if($singleSealFrontier){New-KhcSingleSealSpeedFrontierClaim -Context $context}
    Invoke-KhcRunDiskBudget
    $gateName='Local\KHC-Storage-'+$context.RunId
    $gate=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,$gateName)
    $job=[Khc.Storage.ProcessJob]::new()
    $parameters=@{}; foreach($key in $ScriptParameters.Keys){$parameters[$key]=$ScriptParameters[$key]}; $parameters.WorkDirectory=$work
    $invocation=Join-Path $context.RecordDirectory 'invocation.clixml'
    $xml=[Management.Automation.PSSerializer]::Serialize([pscustomobject]@{script=$scriptFile;parameters=$parameters},5)
    if($remoteAdmission){$xml=$nativeInvocationXml}
    if([Text.Encoding]::UTF8.GetByteCount($xml) -gt 32768){throw '実験の引数保存は32KiBまでです。'}
    [IO.File]::WriteAllText($invocation,$xml,[Text.UTF8Encoding]::new($false))
    if($macCandidateAdmission){$nativeChildCommand=& (Get-Module storage-lifecycle) {param($state,$id) $reserve=Get-KhcRecycleV6RunAnchor $state $id;$registration=Get-KhcMacCandidateE2eRegistration $state $id $reserve -RequireInvocation;Get-KhcMacNativeE2eChildCommand $registration.Record.invocation_sha256 'candidate-e2e'} $context.StateRoot $context.RunId}
    elseif($macReferenceAdmission){$nativeChildCommand=& (Get-Module storage-lifecycle) {param($state,$id) $reserve=Get-KhcRecycleV6RunAnchor $state $id;$registration=Get-KhcMacReferenceRegistration $state $id $reserve -RequireInvocation;Get-KhcMacNativeE2eChildCommand $registration.Record.invocation_sha256 'reference'} $context.StateRoot $context.RunId}
    elseif($macNativeAdmission){$nativeChildCommand=& (Get-Module storage-lifecycle) {param($state,$id) $reserve=Get-KhcRecycleV6RunAnchor $state $id;$registration=Get-KhcMacNativeE2eRegistration $state $id $reserve -RequireInvocation;Get-KhcMacNativeE2eChildCommand $registration.Record.invocation_sha256} $context.StateRoot $context.RunId}
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $info.WorkingDirectory=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $info.Environment['KHC_STORAGE_RUN_RECORD']=$context.RecordPath
    $info.Environment['KHC_STORAGE_TASK_ID']=$taskPaths.TaskId
    $info.Environment['KHC_STORAGE_INVOCATION']=$invocation
    $info.Environment['KHC_STORAGE_START_EVENT']=$gateName
    $info.Environment['TEMP']=$taskPaths.TempRoot
    $info.Environment['TMP']=$taskPaths.TempRoot
    $info.Environment['TMPDIR']=$taskPaths.TempRoot
    $info.Environment['CARGO_TARGET_DIR']=$taskPaths.CargoTargetRoot
    $info.Environment['CARGO_BUILD_TARGET_DIR']=$taskPaths.CargoTargetRoot
    $info.Environment['CARGO_BUILD_BUILD_DIR']=$taskPaths.CargoTargetRoot
    $info.Environment['CARGO_INCREMENTAL']='0'
    $info.ArgumentList.Add('-NoProfile')
    if($remoteAdmission){
        $info.ArgumentList.Add('-EncodedCommand');$info.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nativeChildCommand)))
    }else{
        $info.ArgumentList.Add('-Command')
        $info.ArgumentList.Add('[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $OutputEncoding=[Console]::OutputEncoding; $ErrorActionPreference="Stop"; $gate=[Threading.EventWaitHandle]::OpenExisting($env:KHC_STORAGE_START_EVENT); try {if(-not $gate.WaitOne(10000)){throw "Job assignment timeout"}}finally{$gate.Dispose()}; $inv=Import-Clixml -LiteralPath $env:KHC_STORAGE_INVOCATION; $params=$inv.parameters; & $inv.script @params')
    }
    if($macCandidateAdmission){& (Get-Module storage-lifecycle) {param($clock) Assert-KhcCandidateSpawnBudget $clock} $candidateEnvelopeTimer}
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    $started=$process.Start(); if(-not $started){throw '実験子プロセスを開始できません。'}
    $job.Assign($process)
    if($macCandidateAdmission){& (Get-Module storage-lifecycle) {param($clock) Assert-KhcCandidateSpawnBudget $clock} $candidateEnvelopeTimer}
    $null=$gate.Set()
    $readers=@($process.StandardOutput,$process.StandardError); $buffers=@([char[]]::new(4096),[char[]]::new(4096))
    $logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new()); $done=@($false,$false); $reads=@($null,$null)
    for($side=0;$side -lt 2;$side++){$reads[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)}
    $timer=[Diagnostics.Stopwatch]::StartNew(); $globalCheck=0.0
    $postExitStreamGraceMs=1000; $rootExitDrain=$null; $streamDrainExpired=$false
    while($true){
        for($side=0;$side -lt 2;$side++){
            if(-not $done[$side] -and $reads[$side].IsCompleted){
                $n=$reads[$side].GetAwaiter().GetResult()
                if($n -eq 0){$done[$side]=$true}else{
                    if($logs[$side].Length+$n -gt 32768){throw '実験の標準出力/エラーが32K文字枠を超えました。'}
                    $null=$logs[$side].Append($buffers[$side],0,$n); $reads[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
                }
            }
        }
        $runBytes = $null
        for($scanAttempt=0;$scanAttempt -lt 3;$scanAttempt++){
            try{
                $runBytes=Get-KhcRunUsage $work -MaxEntries $context.MaxEntries
                break
            }catch{
                $cause=$_.Exception
                while($null -ne $cause -and $cause -isnot [IO.DirectoryNotFoundException]){$cause=$cause.InnerException}
                if($null -eq $cause -or $scanAttempt -eq 2){throw}
                # API展開中にstaging TempDirが公開・削除される瞬間だけ、容量走査を短く再試行する。
                Start-Sleep -Milliseconds 10
            }
        }
        if($null -eq $runBytes){throw '実験一時物の容量走査を完了できません。'}
        if($runBytes -gt $context.MaxBytes){throw '実験一時物が登録容量枠を超えました。'}
        if($timer.Elapsed.TotalSeconds -ge $globalCheck){$null=Assert-KhcStorageBudget; $globalCheck=$timer.Elapsed.TotalSeconds+10}
        if($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds){throw '実験の制限時間を超えました。'}
        if($macCandidateAdmission -and $candidateEnvelopeTimer.Elapsed.TotalSeconds -gt 360){throw 'Candidate E2E Windows registration/worker envelope exceeded 360 seconds.'}
        if($singleSealFrontier -and [DateTime]::UtcNow -ge ([DateTimeOffset]$singleSealCampaign.Marker.end_utc).UtcDateTime){throw 'SingleSeal fixed campaign deadline exceeded.'}
        if($process.HasExited){
            if($null -eq $rootExitDrain){$rootExitDrain=[Diagnostics.Stopwatch]::StartNew()}
            if($done[0] -and $done[1]){break}
            if($rootExitDrain.ElapsedMilliseconds -ge $postExitStreamGraceMs){$streamDrainExpired=$true;break}
        }
        Start-Sleep -Milliseconds 100
    }
    $stdoutEof=[bool]$done[0]; $stderrEof=[bool]$done[1]
    foreach($log in $logs){Write-Output $log.ToString()}
    $process.WaitForExit()
    $exitCode=$process.ExitCode
    if($exitCode -ne 0){throw "実験の終了コード: $exitCode"}
    $runRootPid=[int]$process.Id
    $process.Dispose()
    $process=$null
    $drain=[Diagnostics.Stopwatch]::StartNew()
    while($job.Active -ne 0 -and $drain.ElapsedMilliseconds -lt 1000){Start-Sleep -Milliseconds 10}
    $active=$job.Active
    if($active -ne 0){
        $snapshot=@()
        $jobPidSnapshot='unavailable'
        $jobPidError=$null;$jobMembers=@()
        try{
            $jobPidSnapshot=$job.ProcessIdSnapshot()
            if($jobPidSnapshot -match ';pids=([^;]*)'){
                foreach($rawPid in $Matches[1].Split(',',[StringSplitOptions]::RemoveEmptyEntries)){
                    $jobPid=[long]::Parse($rawPid,[Globalization.CultureInfo]::InvariantCulture)
                    $member=Get-CimInstance Win32_Process -Filter ("ProcessId = $jobPid") -ErrorAction Stop
                    if($null -eq $member){$jobMembers+=,[pscustomobject]@{ProcessId=$jobPid;details_unavailable='not returned by CIM'}}
                    else{$jobMembers+=,[pscustomobject]@{ProcessId=[long]$member.ProcessId;ParentProcessId=[long]$member.ParentProcessId;Name=[string]$member.Name;ExecutablePath=[string]$member.ExecutablePath}}
                }
            }
        }catch{$jobPidError=$_.Exception.Message}
        try{
            $all=@(Get-CimInstance Win32_Process|Where-Object{$_.ProcessId -ne $PID})
            $ids=[Collections.Generic.HashSet[int]]::new();$null=$ids.Add($runRootPid)
            $changed=$true
            while($changed){$changed=$false;foreach($item in $all){if($ids.Contains([int]$item.ParentProcessId)-and $ids.Add([int]$item.ProcessId)){$changed=$true}}}
            $snapshot=@($all|Where-Object{$ids.Contains([int]$_.ProcessId)}|Select-Object ProcessId,ParentProcessId,Name,ExecutablePath)
        }catch{$snapshot=@([pscustomobject]@{diagnostic_error=$_.Exception.Message})}
        $snapshotJson=ConvertTo-Json -InputObject $snapshot -Compress -Depth 3
        $jobMembersJson=ConvertTo-Json -InputObject $jobMembers -Compress -Depth 3
        throw "実験root終了後もJob内process=$active が残存しています。rootPid=$runRootPid; Job PID一覧=$jobPidSnapshot; PID詳細=$jobMembersJson; PID診断error=$jobPidError; 子孫snapshot=$snapshotJson"
    }
    if($streamDrainExpired){
        $undrained=@();if(-not $done[0]){$undrained+='stdout'};if(-not $done[1]){$undrained+='stderr'}
        throw "実験root終了後${postExitStreamGraceMs}ms以内に標準streamのEOFを確認できません。未完了=$($undrained -join ',');取得文字数=$($logs[0].Length)/$($logs[1].Length)。出力が不完全なため成功扱いしません。"
    }
} catch {$failure=$_}
finally {
    try {
        if($null -ne $job){$job.StopAndWait(5000)}
        if($started -and $null -ne $process -and -not $process.HasExited){$process.Kill($true); if(-not $process.WaitForExit(5000)){throw '実験子プロセスの終了を確認できません。一時物を保持します。'}}
        if($macCandidateAdmission){
            if($candidateEnvelopeTimer.Elapsed.TotalSeconds -gt 360){throw 'Candidate E2E final evidence deadline exceeded; run remains pending.'}
            # worker終了・Job閉鎖後だけprivate sealを書き、並行する容量走査との部分読取を避ける。
            & (Get-Module storage-lifecycle) {
                param($state,$id,$work)
                $raw=Read-KhcBoundedSnapshotBytes (Join-Path $work 'endpoint-receipt.json') 131072
                $null=Save-KhcMacCandidateE2eSeal $state $id $raw
            } $context.StateRoot $context.RunId $work
            if($candidateEnvelopeTimer.Elapsed.TotalSeconds -gt 360){throw 'Candidate E2E seal persistence exceeded the Windows deadline.'}
        }
        Invoke-KhcRunDiskBudget
        $pending=Prepare-KhcStorageRun -Context $context
        if($macCandidateAdmission -and $candidateEnvelopeTimer.Elapsed.TotalSeconds -gt 360){throw 'Candidate E2E final preparation exceeded the Windows deadline.'}
    } catch {
        if($macCandidateAdmission -and $null -ne $failure){
            $priorException=if($failure -is [Management.Automation.ErrorRecord]){$failure.Exception}else{$failure}
            $failure=[AggregateException]::new('Candidate runner initial failure and finalization failure.',[Exception[]]@($priorException,$_.Exception))
        }else{$failure=$_}
        $context.Lock.Dispose()
    }
    finally {
        if($null -ne $replayAdmissionMutex){try{if($replayAdmissionHeld){$replayAdmissionMutex.ReleaseMutex()}}finally{$replayAdmissionMutex.Dispose()}}
        if($null -ne $process){$process.Dispose()};if($null -ne $gate){$gate.Dispose()};if($null -ne $job){$job.Dispose()}
    }
}
if($null -ne $pending){$pending | ConvertTo-Json -Compress}
try{
    $runnerShaAtFinish=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $runnerSucceeded=($null -eq $failure -and $started -and $exitCode -eq 0 -and $stdoutEof -and $stderrEof -and $active -eq 0 -and $null -ne $pending -and $runnerShaAtFinish -ceq $runnerShaAtStart)
    if(-not $runnerSucceeded -and $null -eq $failure){$failure=[InvalidOperationException]::new('Runner completion gates did not all pass.')}
    $failureMessage=if($null -eq $failure){$null}elseif($failure -is [Management.Automation.ErrorRecord]){[string]$failure.Exception.Message}else{[string]$failure.Message}
    if($null -ne $failureMessage -and $failureMessage.Length -gt 4096){$failureMessage=$failureMessage.Substring(0,4096)}
    if($macCandidateAdmission -and $candidateEnvelopeTimer.Elapsed.TotalSeconds -gt 360){
        $runnerSucceeded=$false
        $failure=& (Get-Module storage-lifecycle) {param($original,$clock) Merge-KhcCandidateRunnerDeadlineFailure $original $clock} $failure $candidateEnvelopeTimer
        $failureMessage=$failure.Message
    }
    $runnerResult=[ordered]@{
        schema=1;run_id=$context.RunId;status=if($runnerSucceeded){'succeeded'}else{'failed'}
        runner_sha256=$runnerShaAtStart;runner_sha256_at_finish=$runnerShaAtFinish
        started_utc=$runnerStartedUtc.ToString('o');finished_utc=[DateTime]::UtcNow.ToString('o')
        child_started=[bool]$started;child_pid=$runRootPid;child_exit_code=$exitCode
        stdout_eof=$stdoutEof;stderr_eof=$stderrEof;job_active_after_exit=$active
        cleanup_request_created=($null -ne $pending);failure_message=$failureMessage
    }
    $runnerResultPath=Join-Path $context.RecordDirectory 'runner-result.json'
    if($macCandidateAdmission){
        & (Get-Module storage-lifecycle) {
            param($result,$clock,$context)
            Publish-KhcCandidateRunnerResult $result $clock {
                param($bytes)
                $path=Join-Path $context.RecordDirectory 'runner-result.json'
                $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
            } {
                param($original,$failed,$elapsed)
                Set-KhcCandidateRunnerDeadlineFailure $context $original $failed $elapsed
            }
        } $runnerResult $candidateEnvelopeTimer $context
    }else{
        $runnerJson=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $runnerResult -Compress -Depth 8))
        if($runnerJson.Length -gt 8192){throw 'Runner result receipt exceeded its 8 KiB bound.'}
        $runnerResultStream=[IO.File]::Open($runnerResultPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$runnerResultStream.Write($runnerJson,0,$runnerJson.Length);$runnerResultStream.Flush($true)}finally{$runnerResultStream.Dispose()}
    }
}catch{
    if($null -eq $failure){$failure=$_}
    else{
        $priorException=if($failure -is [Management.Automation.ErrorRecord]){$failure.Exception}else{$failure}
        if($macCandidateAdmission){$failure=[AggregateException]::new('Candidate runner result receipt failed after an earlier runner error.',[Exception[]]@($priorException,$_.Exception))}
        else{$failure=[InvalidOperationException]::new("Runner result receipt failed after an earlier runner error: $($_.Exception.Message)",$priorException)}
    }
}
if($null -ne $failure){throw $failure}
