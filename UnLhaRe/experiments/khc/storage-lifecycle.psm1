#requires -Version 7.0
# 実験一時物・保全コピー・既存buildを同じ固定枠で数える。OSのquotaではない。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
# 作業先・保全先の基点は「ユーザー既定の一時フォルダー\UnLhaRe」とする（旧Dドライブ固定の作業フォルダー運用は廃止）。
# - $env:TEMP ではなくユーザー環境変数TEMP（レジストリ値）を読む。Initialize-KhcStorageTaskEnvironment が
#   子プロセス向けに $env:TEMP/TMP をtask専用tempへ差し替えるため、$env:TEMP や GetTempPath() を使うと
#   子プロセスで再importした際に基点がずれ、固定パスの完全一致検査がすべて食い違ってしまう。
# - ユーザー環境変数が無い環境だけ GetTempPath() へ退避する。
# - work と TaskArtifacts は同じ親の兄弟にする。入れ子にすると Get-KhcTaskWorkspaceRoots が保全側を
#   task rootと誤認し、容量計上（workspace + keep）も二重計上になるため。
# 他スクリプトも同じ式をインラインで使う（AST抽出で関数単位に読み込むテストがあり、共有変数に依存できないため）。
$script:KhcStorageRoot = (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe')
$script:WorkspaceBase = (Join-Path $script:KhcStorageRoot 'work')
$script:TaskArtifactsBase = (Join-Path $script:KhcStorageRoot 'TaskArtifacts')
$script:TaskId = [string]$env:KHC_STORAGE_TASK_ID
$script:TaskRoot = $null
$script:TempRoot = $null
$script:CargoTargetRoot = $null
$script:KeepRoot = $null
$script:StateRoot = $null
if ($script:TaskId) {
    if ($script:TaskId -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'KHC_STORAGE_TASK_ID must be a lowercase task slug.' }
    $script:TaskRoot = [IO.Path]::GetFullPath((Join-Path $script:WorkspaceBase $script:TaskId))
    $script:TempRoot = Join-Path $script:TaskRoot 'temp'
    $script:CargoTargetRoot = Join-Path $script:TaskRoot 'cargo'
    $script:KeepRoot = [IO.Path]::GetFullPath((Join-Path $script:TaskArtifactsBase $script:TaskId))
    $script:StateRoot = Join-Path $script:KeepRoot 'storage-lifecycle'
}
$script:LegacyTempRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp/Codex/UnLhaRe'))
$script:LegacyKeepRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Codex/TaskArtifacts/UnLhaRe'))
$script:LegacyStateRoot = Join-Path $script:LegacyKeepRoot 'storage-lifecycle'
$script:HistoricalDStateRoot = Join-Path $script:TaskArtifactsBase 'storage-lifecycle'
$script:LifecycleMutexName = 'Local\KHC-Storage-Lifecycle'
$script:CargoMutexName = 'Local\KHC-Storage-Cargo'
$script:LifecycleCapBytes = 1GB
if (-not ('Khc.Storage.TreeCounter' -as [type])) {
    # 大きい旧buildの走査で計測CPUを占有しない。assemblyはメモリ内だけに生成する。
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;
namespace Khc.Storage {
    public sealed class TreeStats { public long Bytes; public int Entries; }
    public static class TreeCounter {
        public static long Bytes(string path) { return Measure(path, int.MaxValue, int.MaxValue).Bytes; }
        public static TreeStats Measure(string path, int maxEntries, int maxRelativeChars) {
            var result = new TreeStats();
            var pending = new Stack<DirectoryInfo>();
            pending.Push(new DirectoryInfo(path));
            while (pending.Count != 0) {
                foreach (var entry in pending.Pop().EnumerateFileSystemInfos()) {
                    if (++result.Entries > maxEntries || entry.FullName.Length - path.Length - 1 > maxRelativeChars)
                        throw new IOException("Owned tree exceeds entry/path metadata bound.");
                    if ((entry.Attributes & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("Reparse point in accounting root: " + entry.FullName);
                    if (entry is DirectoryInfo directory) pending.Push(directory);
                    else result.Bytes = checked(result.Bytes + ((FileInfo)entry).Length);
                }
            }
            return result;
        }
    }
    // 子はstart eventで待機し、Assign完了後だけ実験を開始する。
    public sealed class ProcessJob : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct BasicLimit {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit {
            public BasicLimit Basic; public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential)] struct Accounting {
            public long UserTime, KernelTime, PeriodUserTime, PeriodKernelTime;
            public uint PageFaults, TotalProcesses, ActiveProcesses, TerminatedProcesses;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int kind, ref ExtendedLimit value, int size);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, out Accounting value, int size, IntPtr returned);
        [DllImport("kernel32.dll", EntryPoint="QueryInformationJobObject", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int kind, IntPtr value, int size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        IntPtr handle;
        public ProcessJob() {
            handle = CreateJobObject(IntPtr.Zero, null);
            if (handle == IntPtr.Zero) throw new Win32Exception();
            var limit = new ExtendedLimit(); limit.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE; BREAKAWAYを許可しない。
            if (!SetInformationJobObject(handle, 9, ref limit, Marshal.SizeOf<ExtendedLimit>())) { var error = new Win32Exception(); Dispose(); throw error; }
        }
        public void Assign(Process process) { if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception(); }
        public uint Active {
            get { Accounting value; if (!QueryInformationJobObject(handle, 1, out value, Marshal.SizeOf<Accounting>(), IntPtr.Zero)) throw new Win32Exception(); return value.ActiveProcesses; }
        }
        public string ProcessIdSnapshot() {
            const int capacity = 64; int size = 8 + capacity * IntPtr.Size; IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                Marshal.WriteInt32(buffer, 0, capacity); Marshal.WriteInt32(buffer, 4, 0);
                bool ok = QueryInformationJobObject(handle, 3, buffer, size, IntPtr.Zero); int error = ok ? 0 : Marshal.GetLastWin32Error();
                int assigned = Marshal.ReadInt32(buffer, 0), count = Marshal.ReadInt32(buffer, 4);
                if (count < 0 || count > capacity) return "ok=" + ok + ";assigned=" + assigned + ";listed=" + count + ";error=" + error;
                var ids = new string[count];
                for (int i = 0; i < count; i++) ids[i] = Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64().ToString(System.Globalization.CultureInfo.InvariantCulture);
                return "ok=" + ok + ";assigned=" + assigned + ";listed=" + count + ";pids=" + string.Join(",", ids) + ";error=" + error;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public void StopAndWait(int milliseconds) {
            if (Active != 0 && !TerminateJobObject(handle, 1)) throw new Win32Exception();
            var timer = Stopwatch.StartNew();
            while (Active != 0) { if (timer.ElapsedMilliseconds >= milliseconds) throw new IOException("Job processes did not finish; retain work directory."); Thread.Sleep(10); }
        }
        public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    }
}
'@
}

if (-not ('Khc.Storage.FileMutexLease' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace Khc.Storage {
    public sealed class FileMutexLease : IDisposable {
        private Mutex mutex;
        private FileStream stream;
        private bool ownsMutex;
        public FileMutexLease(string mutexName, string lockPath) {
            mutex = new Mutex(false, mutexName);
            try {
                try { ownsMutex = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex) throw new IOException("KHC storage resource is already leased.");
                stream = File.Open(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            } catch {
                if (ownsMutex) mutex.ReleaseMutex();
                mutex.Dispose(); mutex = null;
                throw;
            }
        }
        public void Dispose() {
            if (stream != null) { stream.Dispose(); stream = null; }
            if (mutex != null) {
                if (ownsMutex) mutex.ReleaseMutex();
                ownsMutex = false; mutex.Dispose(); mutex = null;
            }
        }
    }
}
'@
}

function Assert-KhcPlainPath {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not [IO.Path]::IsPathFullyQualified($LiteralPath) -or [WildcardPattern]::ContainsWildcardCharacters($LiteralPath)) { throw '絶対パスを指定してください（wildcard不可）。' }
    $path = [IO.Path]::GetFullPath($LiteralPath).TrimEnd([char[]]'\/')
    $ancestor = $path
    while ($ancestor) {
        if ([IO.File]::Exists($ancestor) -or [IO.Directory]::Exists($ancestor) -or (Test-Path -LiteralPath $ancestor)) {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "リンクを含むパスは使用できません: $ancestor" }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    return $path
}

# 旧campaignの固定値は変更しない。開発集合と独立holdoutは別のprofile/markerを使う。
function Assert-KhcSingleSealSpeedFrontierCampaign {
    param([string]$RunId, [switch]$RequireOpenWindow)
    $directory=Assert-KhcPlainPath (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\krs2-single-seal-frontier-20261020')
    $path=Assert-KhcPlainPath (Join-Path $directory 'campaign-start.json')
    $markerSha='9a3109f0b11f5f35b627982f494bd09888d3f070e47c17ee8329ea15d76aab77'
    if ((Get-Item -LiteralPath $path -Force).Length -ne 2390 -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $markerSha) { throw 'SingleSeal immutable campaign marker length/SHA mismatch.' }
    # 固定SHAは全JSON条件（順序・予算・判定基準を含む）の正本。値を再基準化しない。
    $marker=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 12
    if ($marker.schema -cne 'khc-krs2-single-seal-frontier-v1' -or $marker.source_condition -cne 'SingleSeal20261020' -or
        $marker.task_id -cne 'goal-restore-20261019' -or $script:TaskId -cne $marker.task_id -or
        ([DateTimeOffset]$marker.start_utc).UtcDateTime -ne [DateTimeOffset]::Parse('2026-10-20T04:45:00Z').UtcDateTime -or
        ([DateTimeOffset]$marker.end_utc).UtcDateTime -ne [DateTimeOffset]::Parse('2026-10-20T05:00:00Z').UtcDateTime -or
        $marker.one_run_only -ne $true -or $marker.retry_allowed -ne $false -or $marker.window_rebase_allowed -ne $false) { throw 'SingleSeal campaign context mismatch.' }
    $stop=Assert-KhcPlainPath (Join-Path $directory 'pre-registration-stop.json')
    if (Test-Path -LiteralPath $stop) { throw 'SingleSeal campaign was closed before registration; retry is forbidden.' }
    if ([IO.Path]::GetFullPath($PSScriptRoot) -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc') { throw 'SingleSeal requires the fixed source/script root.' }
    foreach ($pin in @(
        @{path=$marker.khc_executable;sha=$marker.khc_executable_sha256},
        @{path=$marker.seven_zip_executable;sha=$marker.seven_zip_executable_sha256},
        @{path=$marker.input_recovery_zip;sha=$marker.input_recovery_zip_sha256}
    )) {
        $plain=Assert-KhcPlainPath ([string]$pin.path)
        if (-not (Test-Path -LiteralPath $plain -PathType Leaf) -or
            (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha) { throw "SingleSeal tool/input ZIP pin mismatch: $plain" }
    }
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($marker.seven_zip_executable)
    if ($version.FileMajorPart -ne 26 -or $version.FileMinorPart -ne 4 -or $version.FileBuildPart -ne 0 -or $version.FilePrivatePart -ne 0) { throw 'SingleSeal requires 7-Zip 26.04.' }
    foreach ($sourcePin in @(
        @{path='D:\Dev\UnLhaRe\UnLhaRe\src';sha=$marker.rust_source_manifest_sha256},
        @{path='D:\Dev\UnLhaRe\UnLhaRe\src\khc';sha=$marker.khc_source_manifest_sha256}
    )) {
        $root=Assert-KhcPlainPath $sourcePin.path
        $paths=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($item in Get-ChildItem -LiteralPath $root -Filter '*.rs' -File -Recurse -Force -ErrorAction Stop) {
            $plain=Assert-KhcPlainPath $item.FullName
            $paths.Add([IO.Path]::GetRelativePath($root,$plain).Replace('\','/'),$plain)
        }
        $names=[string[]]$paths.Keys
        [Array]::Sort($names,[StringComparer]::Ordinal)
        $manifest=[Text.StringBuilder]::new()
        foreach ($name in $names) {
            $item=Get-Item -LiteralPath $paths[$name] -Force
            $sha=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $null=$manifest.Append($name).Append([char]9).Append($item.Length).Append([char]9).Append($sha).Append([char]10)
        }
        $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($manifest.ToString()))).ToLowerInvariant()
        if ($sha -cne $sourcePin.sha) { throw "SingleSeal source manifest mismatch: $root" }
    }
    $claimPath=Assert-KhcPlainPath (Join-Path $directory 'claim.json')
    $claim=$null
    if ([string]::IsNullOrEmpty($RunId)) {
        if (Test-Path -LiteralPath $claimPath) { throw 'SingleSeal one-run claim already exists; retry is forbidden.' }
    } else {
        if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'Invalid SingleSeal run ID.' }
        $claim=Get-Content -LiteralPath $claimPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $location=Get-KhcStorageRunLocation $RunId
        $recordPath=Assert-KhcPlainPath $location.RecordPath
        $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        $null=Assert-KhcPlainPath ([string]$record.work_directory)
        if ($claim.schema -cne 'khc-krs2-single-seal-claim-v1' -or
            ([DateTimeOffset]$claim.claimed_utc).UtcDateTime -lt ([DateTimeOffset]$marker.start_utc).UtcDateTime -or
            ([DateTimeOffset]$claim.claimed_utc).UtcDateTime -ge ([DateTimeOffset]$marker.end_utc).UtcDateTime -or
            $claim.run_id -cne $RunId -or $claim.marker_sha256 -cne $markerSha -or
            $claim.campaign_id -cne $marker.campaign_id -or $claim.record_path -cne $recordPath -or
            $record.run_id -cne $RunId -or $record.max_bytes -ne 28MB -or $record.max_entries -ne 128 -or
            $record.work_directory -cne $claim.work_directory -or
            $location.StateRoot -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\storage-lifecycle')) { throw 'SingleSeal claim/current registration mismatch.' }
    }
    if ($RequireOpenWindow -and ([DateTime]::UtcNow -lt ([DateTimeOffset]$marker.start_utc).UtcDateTime -or
        [DateTime]::UtcNow -ge ([DateTimeOffset]$marker.end_utc).UtcDateTime)) { throw 'SingleSeal fixed UTC window is closed.' }
    [pscustomobject]@{Marker=$marker;MarkerSha256=$markerSha;MarkerPath=$path;ClaimPath=$claimPath;Claim=$claim}
}

function New-KhcSingleSealSpeedFrontierClaim {
    param([Parameter(Mandatory)]$Context)
    $campaign=Assert-KhcSingleSealSpeedFrontierCampaign -RequireOpenWindow
    $recordPath=Assert-KhcPlainPath $Context.RecordPath
    $record=Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($record.run_id -cne $Context.RunId -or $record.work_directory -cne $Context.WorkDirectory -or
        $record.max_bytes -ne 28MB -or $record.max_entries -ne 128) { throw 'SingleSeal registration budget/context mismatch before claim.' }
    # CreateNewを使い、失敗後もclaimを保持する。再試行用に削除・置換しない。
    Write-KhcNewJson $campaign.ClaimPath ([ordered]@{
        schema='khc-krs2-single-seal-claim-v1';campaign_id=$campaign.Marker.campaign_id
        marker_sha256=$campaign.MarkerSha256;run_id=$Context.RunId;record_path=$recordPath
        work_directory=$Context.WorkDirectory;claimed_utc=[DateTime]::UtcNow.ToString('o')
    })
    $null=Assert-KhcSingleSealSpeedFrontierCampaign -RunId $Context.RunId -RequireOpenWindow
}

function Get-KhcPortfolioInputProfile {
    param([Parameter(Mandatory)][ValidateSet('eGovLawXml20261016','AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciTabularDevelopment20261020','UciDryBeanHoldout20261020')][string]$CorpusProfile)
    if ($CorpusProfile -ceq 'CanterburyDevelopmentKcs1CountLength20261020') {
        # 過去のCanterbury campaignとは別のsource条件。復旧ZIPは読み取り専用の入力container。
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\canterbury-development-kcs1-count-length-20261020')
            InputZipPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\storage-lifecycle\runs\5e93ed1e99ca4f5ab29d490db421e50b\recovery.zip')
            ZipBytes=8765120L; ZipSha256='b74644fac5f89251b15a68db6b2a3bce1bd508c12f0f685a61cd5c96ae1540bb'
            Files=11; Bytes=2810784L; ManifestSha256='bb63b0d70713c9aefa681347eaf99fb891d59f45923e009ad0deadc9ec9fc438'
            EntryPrefix='pipeline-e2e/canterbury/'; StoredMember=$false; InputRole='development-only'
            SourceFamily='Canterbury corpus'; Scope='DEVELOPMENT/TRAINING/TUNING ONLY: Canterbury11; KCS1 count-only code lengths; no holdout evaluation'
            SourceManifestSha256='2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21'
            KhcSourceManifestSha256='16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088'
            CliSha256='e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d'; CliBytes=2581504L
            Entries=@(
                [pscustomobject]@{name='alice29.txt';bytes=152089L;sha256='7467306ee0feed4971260f3c87421154a05be571d944e9cb021a5713700c38f0'},
                [pscustomobject]@{name='asyoulik.txt';bytes=125179L;sha256='eaa3526fe53859f34ecdf255712f9ecf0b2c903451d4755b2edaa2e2599cb0fc'},
                [pscustomobject]@{name='cp.html';bytes=24603L;sha256='e0cd21cef5b6c4069461e949be100080c3ce887de6f1dd8626c480528efaaf61'},
                [pscustomobject]@{name='fields.c';bytes=11150L;sha256='85d73e354cc50cec76cb5a50537cf8dc035f8cbb8480f9e1cbe2f7d6c23393c7'},
                [pscustomobject]@{name='grammar.lsp';bytes=3721L;sha256='1b0805dfc0ae706b35aac2bb4e15f02485efd24dda5dbd29de7b2f84d1a88c15'},
                [pscustomobject]@{name='kennedy.xls';bytes=1029744L;sha256='9af47239ca29dfe20e633f80bbbb9a4cc9783d0803d7b2b5626f42e4c3790420'},
                [pscustomobject]@{name='lcet10.txt';bytes=426754L;sha256='5314ba1dbb03f471df88bec6cd120a938ef60d0fd3511c5c1dce61bf7463245f'},
                [pscustomobject]@{name='plrabn12.txt';bytes=481861L;sha256='07e2e0b461af78c7c647cb53dab39de560198e16f799b4516eccf0fbd69f764c'},
                [pscustomobject]@{name='ptt5';bytes=513216L;sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650'},
                [pscustomobject]@{name='sum';bytes=38240L;sha256='ee5733cd76ecc2f9d8ff156adc3c02a7a851051dcf43a2d56ff4ee4ff606bdb3'},
                [pscustomobject]@{name='xargs.1';bytes=4227L;sha256='c58aeb5d2d1e12751d47e7412b45784405fc30a5671b03d480fa05776e183619'}
            )
        }
    }
    if ($CorpusProfile -ceq 'UciDryBeanHoldout20261020') {
        # 一系統screen専用。取得証拠とwrapperはcampaign/run清掃rootの外で固定する。
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\uci-dry-bean-holdout-20261020\campaign')
            MetadataDirectory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\uci-dry-bean-holdout-20261020')
            InputZipPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\uci-dry-bean-holdout-20261020\dry-bean-input.zip')
            ZipBytes=3813357L; ZipSha256='8052ba1666b0254c3b8911289d72d0cc205484cce37eb784cab3c14fdeff1221'
            Files=1; Bytes=3813205L; ManifestSha256='172896a2dfa74a8e8dad154c92bf5c12ab8ddf62e89d5d96c5e5f5c1769f7d83'
            EntryPrefix='input/'; StoredMember=$true; InputRole='holdout-only'
            DevelopmentOnly=$false; HoldoutOnly=$true; TrainingAllowed=$false; TuningAllowed=$false
            HoldoutCategoryCount=0; SuperiorityDecisionAllowed=$false; SingleFamilyScreenOnly=$true
            SourceFamily='UCI Dry Bean dataset'; Scope='HOLDOUT ONLY: UCI Dry Bean unchanged ARFF; one-family screen only; never development/training/tuning; excluded from 13-category/three-family aggregate'
            StartDate='not-applicable'; EndDate='not-applicable'; Fields=@('unchanged_arff')
            SourceManifestSha256='2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21'
            KhcSourceManifestSha256='16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088'
            CliSha256='e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d'; CliBytes=2581504L
            Entries=@([pscustomobject]@{name='Dry_Bean_Dataset.arff';bytes=3813205L;sha256='b2a4a76a2aedfb8ed415adfc1bfc70b5f202cb00cb72e500766e364c14834014'})
            Provenance=[ordered]@{
                schema=1; dataset_id=602; dataset_doi='10.24432/C50S4B'
                source_page='https://archive.ics.uci.edu/dataset/602/dry+bean+dataset'
                source_url='https://archive.ics.uci.edu/static/public/602/dry+bean+dataset.zip'
                authors=@('M. Koklu','Ilker Ali Özkan'); year=2020; article_doi='10.1016/j.compag.2020.105507'
                attribution='Dry Bean [Dataset]. (2020). UCI Machine Learning Repository. DOI 10.24432/C50S4B. M. Koklu and Ilker Ali Özkan.'
                license_label='CC BY 4.0'; license_url='https://creativecommons.org/licenses/by/4.0/'
                rights_basis='UCI dataset page explicitly grants CC BY 4.0 with appropriate credit; only the .txt rights/provenance sidecar was read; distribution has no LICENSE/NOTICE/COPYING.'
                source_archive_name='dry-bean-dataset.zip'; source_archive_bytes=4738776L
                source_archive_sha256='0a64eff5be87f48c3dbbfc0a12a56c5d5b5167ef8e61cd45d69b3e7c7130c06f'
                source_member='DryBeanDataset/Dry_Bean_Dataset.arff'; source_member_bytes=3813205L
                source_member_sha256='b2a4a76a2aedfb8ed415adfc1bfc70b5f202cb00cb72e500766e364c14834014'
                acquisition_lock_sha256='4d1b0d8cbcec51cd9feb7107566865cc37bce39dee605f67dfdc847d78cb7393'
                source_family_count=1; single_family_screen_only=$true; aggregate_category_count=0
                content_handling='Unchanged raw ARFF bytes only; no display, parsing, normalization, conversion, model training, tuning or feature selection.'
                wrapper_timestamp_local='1980-01-01 00:00:00'; input_entry_prefix='input/'; input_zip_compression='stored'
            }
        }
    }
    if ($CorpusProfile -ceq 'UciTabularDevelopment20261020') {
        # metadataのみ。固定wrapper未登録のため、実入力の読取り・run・集計へは進めない。
        return [pscustomobject]@{
            Name=$CorpusProfile; ScreenReady=$false; InputRole='development-only'
            DevelopmentOnly=$true; HoldoutOnly=$false; TrainingAllowed=$true; TuningAllowed=$true
            HoldoutEligible=$false; HoldoutCategoryCount=0; SuperiorityDecisionAllowed=$false
            ReadinessBlockers=@('Fixed wrapper path/length/SHA-256 and file-set manifest not admitted','Applicable member notices require completion before runnable admission')
            Files=3; Bytes=1648091L
            Scope='DEVELOPMENT/TRAINING/TUNING ONLY: UCI Bike Sharing hour.csv, Steel Plates Faults Faults.NNA, Abalone abalone.data; excluded from blind holdout, 13-category completeness and superiority decisions'
            Provenance=[ordered]@{
                schema=1; role='development-only'; holdout_eligible=$false; holdout_category_count=0; superiority_decision_allowed=$false
                distribution_platform='UCI Machine Learning Repository'
                independence_claimed=$false; unseen_claimed=$false
                prior_use_audit='Incomplete local exact-name/member-hash search only; does not establish absence of earlier use or independent families.'
                recipe='Use original member bytes without column extraction, normalization, sorting or reserialization; source ZIP wrappers are not compression inputs.'
                license_label='CC BY 4.0'; license_url='https://creativecommons.org/licenses/by/4.0/legalcode.en'
                attribution='Retain each dataset author credit, official dataset page, CC BY 4.0 link and applicable publication citation.'
                bike_notice_member='Readme.txt'; bike_notice_bytes=5607
                bike_publication_citation_required=$true
                bike_publication_citation='Fanaee-T, H., & Gama, J. (2014). Event labeling combining ensemble detectors and background knowledge. Progress in Artificial Intelligence, 2(2–3), 113–127. https://doi.org/10.1007/s13748-013-0040-3.'
                bike_publication_citation_metadata='UCI identifies this as the introductory paper and labels it 2013; Springer records online publication on 2013-11-26 and volume/pages as 2014.'
                bike_publication_citation_source='UCI Bike Sharing introductory-paper metadata and Springer publisher record; preserve the article citation required by Readme.txt.'
                datasets=@(
                    [ordered]@{
                        dataset='Bike Sharing';uci_id=275;source_page='https://archive.ics.uci.edu/dataset/275/bike+sharing+dataset'
                        source_zip_url='https://archive.ics.uci.edu/static/public/275/bike+sharing+dataset.zip';source_zip_bytes=279992L
                        source_zip_sha256='b70182d0d0508e9abbb79306ce5c0cec34869000f8220175ac83d11dbe845401'
                        member_path='hour.csv';member_bytes=1156736L;member_sha256='e03de4ee4ef4dc376ac6e04bf829673c6269e8eba5c60fa121640fa2f829504f'
                        authors='Fanaee-T';records=17379;fields=17;header_present=$true
                    }
                    [ordered]@{
                        dataset='Steel Plates Faults';uci_id=198;source_page='https://archive.ics.uci.edu/dataset/198/steel+plates+faults'
                        source_zip_url='https://archive.ics.uci.edu/static/public/198/steel+plates+faults.zip';source_zip_bytes=100890L
                        source_zip_sha256='cb8eb9859198b63f053e443513036b401746fa517ef58bd17c846c6741c93919'
                        member_path='Faults.NNA';member_bytes=299482L;member_sha256='08994f5b0185a8e6cc22afe9910fd36834990fb1ca30852ed79012a832fbff55'
                        authors='Buscema; Terzi; Tastle';records=1941;fields=34;header_present=$false
                    }
                    [ordered]@{
                        dataset='Abalone';uci_id=1;source_page='https://archive.ics.uci.edu/dataset/1/abalone'
                        source_zip_url='https://archive.ics.uci.edu/static/public/1/abalone.zip';source_zip_bytes=55357L
                        source_zip_sha256='755a6a67c5b266961a3f149ea13be2cfb6e6c727e48cee3c83bc0b4526210ee4'
                        member_path='abalone.data';member_bytes=191873L;member_sha256='de37cdcdcaaa50c309d514f248f7c2302a5f1f88c168905eba23fe2fbc78449f'
                        authors='Nash; Sellers; Talbot; Cawthorn; Ford';records=4177;fields=9;header_present=$false
                    }
                )
                member_notice_review='Only selected member metadata and noncandidate sidecars were reviewed previously; not a complete legal opinion.'
                preparation_status='Metadata only; no fixed input ZIP path/hash/manifest or campaign marker admitted.'
            }
            Entries=@(
                [pscustomobject]@{name='Faults.NNA';bytes=299482L;sha256='08994f5b0185a8e6cc22afe9910fd36834990fb1ca30852ed79012a832fbff55'}
                [pscustomobject]@{name='abalone.data';bytes=191873L;sha256='de37cdcdcaaa50c309d514f248f7c2302a5f1f88c168905eba23fe2fbc78449f'}
                [pscustomobject]@{name='hour.csv';bytes=1156736L;sha256='e03de4ee4ef4dc376ac6e04bf829673c6269e8eba5c60fa121640fa2f829504f'}
            )
        }
    }
    if ($CorpusProfile -ceq 'eGovLawXml20261016') {
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\egov-screen-20261020')
            ZipBytes=1022150L; ZipSha256='861ce8956f8347b34223466d5fff93360d1901b6aa42cca1238965d590e73099'
            Files=100; Bytes=9527638L; ManifestSha256='332cb1043efa84127312da055bb8c03104b991cb8e0820195cb2aafa4bfefee3'
            EntryPrefix='input/'; StoredMember=$false
            CandidateManifestSha256=$null; SourceFamily='e-Gov'; Scope='DEVELOPMENT ONLY: e-Gov judicial 100-file XML/CSV set'; Entries=@()
        }
    }
    if ($CorpusProfile -ceq 'JmaTokyoDaily2010_2025Holdout20261020') {
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\jma-holdout-20261020')
            ZipBytes=169228L; ZipSha256='bf89c170af85418f9911be0b2a547fae2029755ef06091b4209ca446841805f8'
            Files=1; Bytes=169060L; ManifestSha256='36d982b198c5557acb383b3fbe4df2aa74d08336705005916e25138973000dab'
            EntryPrefix='input/'; StoredMember=$true
            CandidateManifestSha256=$null; SourceFamily='JMA Tokyo daily weather series'
            Scope='HOLDOUT ONLY: independent Tokyo daily mean temperature and precipitation totals, 2010-01-01..2025-12-31; never training/tuning/development'
            StartDate='2010-01-01'; EndDate='2025-12-31'; Fields=@('daily_mean_temperature','daily_precipitation_total')
            Entries=@([pscustomobject]@{name='jma-tokyo-daily-2010-2025.csv';bytes=169060L;sha256='a17d1a8cca49f958ce417624a77416e04113da412bf42f68c559c96745d37885'})
        }
    }
    if ($CorpusProfile -ceq 'TokyoResidentRegister202101Holdout20261020') {
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\tokyo-population-holdout-campaign-20261020')
            ZipBytes=295202L; ZipSha256='7c5fa47e7c58cc2512024c6491af4589837e9395b8171ce84dd3d0193757c511'
            Files=1; Bytes=295022L; ManifestSha256='60964784dba36f8f7d3f63e71dda413aec4dbf501bf493dd19f9a1f85311159b'
            EntryPrefix='input/'; StoredMember=$true
            CandidateManifestSha256=$null; SourceFamily='Tokyo Metropolitan Government resident-register population table'
            Scope='HOLDOUT ONLY: Tokyo resident-register Table 5, January 2021; one small structured CSV; never development/training/tuning'
            StartDate='2021-01'; EndDate='2021-01'; Fields=@('municipality','town_area','households','male_population','female_population','total_population')
            SourcePage='https://www.toukei.metro.tokyo.lg.jp/juukiy/2021/jy21q10501.htm'
            SourceCatalogPage='https://spec.api.metro.tokyo.go.jp/spec/t000003d2000000818-f9ced66f9dcb572a175c81b9833cfd48-0?lang=ja'
            SourceDirectCsvUrl='https://www.toukei.metro.tokyo.lg.jp/juukiy/2021/jy21qv0500.csv'
            SourceAttribution='東京都「住民基本台帳による東京都の世帯と人口」（令和3年1月・第5表、2026-10-20取得）'
            SourceLicenseLabel='CC BY'; SourceLicenseVersion=$null
            SourceLicenseNote='公式APIカタログはCC BYと表示するが版番号は示さない。版を推測しない。'
            SourceContentHandling='CSV本文は無変更。input/ memberへの格納とstored ZIP wrapperの追加のみ。'
            Entries=@([pscustomobject]@{name='tokyo-population-2021-01-table5.csv';bytes=295022L;sha256='24f90c92c90500bef3e7e2170691a7bcc4fa0f22ecfe8f20cb9e1586e49af1a8'})
        }
    }
    if ($CorpusProfile -ceq 'LivedoorNews2012Holdout20261020') {
        # 記事本文は解釈せず、固定memberの名前・サイズ・SHAだけを保持する。
        $memberRows=@'
text/CHANGES.txt	223	340ad706bcde8af728cc1fa1748d856e88587256ab7da42800a2ab9221b4d26c
text/README.txt	2182	a98e4d868bf699d370af84e81fbe6383c69611d7eaecd3057f7d7d0651993b71
text/dokujo-tsushin/LICENSE.txt	521	721c4747be05813b0910e4e6db1ab355da12e36133bd8662608692ce607892f6
text/dokujo-tsushin/dokujo-tsushin-4961684.txt	5230	74b94273daecb6871dbd6af76fb8a1806b80d8bd5594c008094e7c481945a50f
text/dokujo-tsushin/dokujo-tsushin-5032732.txt	5300	6d930f9f77f797f3fc6d8ac55cbf8709ac395b34fdf4888859a70b00b305a7a1
text/dokujo-tsushin/dokujo-tsushin-5143945.txt	3125	51b28f3e54037a4e1fde4f872d223c700cc8acf53f222932656250af6c529b11
text/dokujo-tsushin/dokujo-tsushin-5200729.txt	3710	a2639d71e4ea3527a61587a768195c1702ec284eefb56b75ce7f057fdb16b38a
text/dokujo-tsushin/dokujo-tsushin-5235297.txt	4897	515c2a20faeb547149065a98bcd624ca9aa206fb19413806f40971c47e25f7ad
text/dokujo-tsushin/dokujo-tsushin-5376845.txt	4743	7ccd2068a199813834bd68fb70f842a045c2f30c606d75579bac8c7a69f0cd53
text/dokujo-tsushin/dokujo-tsushin-5382580.txt	5193	e8855c38b0bf5b5e02f58a8940fa41754c4364eaa6237802e4f3dc1c833cc612
text/dokujo-tsushin/dokujo-tsushin-5467479.txt	2823	5fdee27129e639525fd6b5714e641ff95e44b98ade572c7ed8f8a5f1e646ee25
text/dokujo-tsushin/dokujo-tsushin-5534793.txt	4905	8650706bf82ab8dc564fce31877fde0b45f33d8a6435a2195f72bc6917ec8c75
text/dokujo-tsushin/dokujo-tsushin-5598425.txt	4154	ecdc23777856c3f40cf12a4d0a11bbc8b1c23725d38cdb1af7573fb23086a075
text/dokujo-tsushin/dokujo-tsushin-5735834.txt	5739	3a83ef261664693a2331a507c30daf2c56c473710848dc60cc9b0ec9395d224b
text/dokujo-tsushin/dokujo-tsushin-5768808.txt	5498	4ddf9f36860c914afd1a105fcfd82ce2842b59632003a46609327f897b7bdd7c
text/dokujo-tsushin/dokujo-tsushin-5997396.txt	6524	16df4f62a22ebc71fea34b77d111f9d1e4ff7c47798d57896d187942a9b91dd0
text/dokujo-tsushin/dokujo-tsushin-6018194.txt	4080	020fc8dfa66ddd90d5f147048fc9942c4c950033c8ec34a0656aa72ea1bac39e
text/dokujo-tsushin/dokujo-tsushin-6255098.txt	4493	8b8e20602a5e254348a304821d8237acc752812ef3511300abd926966598e196
text/dokujo-tsushin/dokujo-tsushin-6455366.txt	3454	0b795e4709e5eb7d445f87cc51056bda7f8a45d849ea517d3c92dbd24dbdcba3
text/dokujo-tsushin/dokujo-tsushin-6534759.txt	3982	d0f6b993516d463906235426648628e6f21ae2094b98187263712f57b0f77598
text/dokujo-tsushin/dokujo-tsushin-6636095.txt	4092	d3dc8adf1bf15bb3285fa4636246c8f52ed5c044c3660eda4fe1aca584d49fbb
text/dokujo-tsushin/dokujo-tsushin-6702565.txt	5267	3e89ebc4d6cc648e731ed7b06e333820a9bf7315edc6482616eb3e2e06b8ee7e
text/dokujo-tsushin/dokujo-tsushin-6797502.txt	4438	b7a0911c7d23cd51e348ffcf0d3e77103e033d0005346741cb70f52b0bde2e46
text/dokujo-tsushin/dokujo-tsushin-6843813.txt	5253	238600e47314f39d0bee25bd330b7641167f091b58416f00e4f47e7db207c967
text/it-life-hack/LICENSE.txt	530	7cb66e134b1ff5041dd834d668d4e704da439fb91e48ab6b512f235f0a63b1fc
text/it-life-hack/it-life-hack-6303524.txt	2132	9c3be4ed953534878edde15a31209e03708a217d98bff86131d29a9d7f915f40
text/it-life-hack/it-life-hack-6351981.txt	4499	e67628117fc952091990a0aec515e9c1e6db573cfd3d2f65114aad267c9f1802
text/it-life-hack/it-life-hack-6353794.txt	5253	1008cb1d019643c8276fa8fe008bed165b6f4184a5a8cd1c327bd63f6982bc3b
text/it-life-hack/it-life-hack-6424692.txt	4424	1a1b9196165b962d9807ec20b203af52d4afd99b6810e0f2622d44cd6e663398
text/it-life-hack/it-life-hack-6532726.txt	4940	0d428d1110e65764cd399995a33b2ed9ab6e09da3027ca5c3a3743ec4982b504
text/it-life-hack/it-life-hack-6540729.txt	4789	ef429bce96548a7c82e7049f6fd274d1947e7bf9ad9bde4b47f83c4731589f36
text/it-life-hack/it-life-hack-6541754.txt	1374	e4e8af3242372f6ea5a0885bfc6e186d60cef68961a856946c6ab6fd9ae016af
text/it-life-hack/it-life-hack-6585066.txt	1114	75890d7fc46d22b717125be6887e0632c39b94da5fb047b93a8c64312c9b318b
text/it-life-hack/it-life-hack-6611530.txt	2945	e81bf731dd1e9083ee4e589b629e56110a2be2619b615a8b4465377982cdf5a0
text/it-life-hack/it-life-hack-6653680.txt	4919	4c9593e8aec9e45086dc3f6c75dff723669f5a3ce7ff56fbf690f3017b3b5b9d
text/it-life-hack/it-life-hack-6656368.txt	4441	1f36f8692aa0cf6ca58e9772fe63b3c0c5a065212171bd8dd6d7b5f3344d604e
text/it-life-hack/it-life-hack-6731701.txt	3014	16e1a243a0ed2ef86cb94f7b2194b847313b0d862e80b0782f25bf7cfe4c0a60
text/it-life-hack/it-life-hack-6732769.txt	2560	4e2acefdd1897856562850d6173d8ecd2cb4eff134bace3964e58f2ee7bcafe1
text/it-life-hack/it-life-hack-6763906.txt	6291	9884a2282a717f6114102a26a7b3bf2546723512df6124a6ed7c0bf9773114a2
text/it-life-hack/it-life-hack-6788402.txt	4358	4292ffca0eb861f6892fa989aa3b9558962afb9c9b57e17b063f42ccefa15a29
text/it-life-hack/it-life-hack-6800970.txt	3650	fe481019ea0d53e6210d858ace702f070aff51e72645b2cce7f14b0405a438e8
text/it-life-hack/it-life-hack-6813431.txt	2813	90407f8005495bd0c9e7425120be3fb973720b35f63a8132955885fb84704511
text/it-life-hack/it-life-hack-6846685.txt	3933	13882d2ce51515d22cd7a3f2ecf500b3ceefbfd000fc3479719c40de7c978530
text/it-life-hack/it-life-hack-6850409.txt	5532	47c4e8ce4ed9327167fd1cd6615d5eb0a84fc1a274ce30371a5bdd95d411e224
text/it-life-hack/it-life-hack-6857231.txt	4463	87a188fb9edd9e83ba7b148973bc210eca46ee7e2c9d6cfeb4e1fe3e1537b0bf
text/it-life-hack/it-life-hack-6891730.txt	5382	17faa76690f2b03497b0e3d832c43a75b199677d352e04b007cd330b35ed7178
text/kaden-channel/LICENSE.txt	535	f94eb19debc181e4f09b19d6a89ae18d8a1c94084cf52b28e991348778e39aed
text/kaden-channel/kaden-channel-5851374.txt	2680	2ef8bf28a273503aa79cdc09bef069ee8cd218f4b18d14f960441427658cb253
text/kaden-channel/kaden-channel-5855219.txt	1927	57830214a06b2a7906e1a76823273815818ddc24f08ad105ab0359229d52a053
text/kaden-channel/kaden-channel-5943211.txt	2049	6acb4098341823e4abd268b21a6abcda17a94edc2f487bd811399b890b85bc85
text/kaden-channel/kaden-channel-5988358.txt	2070	b29bbade1dbd35d69dafa148c0ce670bc8467ee4707e8c42fcbd37f80e0426c3
text/kaden-channel/kaden-channel-5993952.txt	1619	52c7b2a892764958139cf76d309675158ce7dd93b0b2eb216a9e3ae335251f83
text/kaden-channel/kaden-channel-6031869.txt	2556	4d448ed1966fa531418790b175710318cf7e565cabe433594c51fb9c130d3e54
text/kaden-channel/kaden-channel-6146341.txt	1638	d29e32313aa769e916c0e4caecfec98bc1a44cd044a77f981b34ff2079e79432
text/kaden-channel/kaden-channel-6185964.txt	2624	d71ca5169cfda7082299d51af79cb0ca136f4f581b10852a31934a63a8fee8f3
text/kaden-channel/kaden-channel-6252184.txt	1511	4a45e7d55905deb8ee51c54d0035ae1f796ed34fc05b996a61a7cf86fc3f4d64
text/kaden-channel/kaden-channel-6277507.txt	1615	0f5d27c652608a7acd4ec4a099cafc9a1035c38ea1a7f92836de3997bb6035e0
text/kaden-channel/kaden-channel-6292865.txt	1534	587d890fc48598be89dde631bc4180033f10faf9e2c194513af0dcfd1ea9051f
text/kaden-channel/kaden-channel-6293023.txt	1763	f08704d9f30a085168ab0ee3df44483c8380a047891e169ae23be87e58a736f2
text/kaden-channel/kaden-channel-6301913.txt	2828	aafbed06dca399d47cace27b2012ccbe0317ba8fefc9c195b061da3e90cbffdf
text/kaden-channel/kaden-channel-6335102.txt	1912	f10b2461a6030df3b3e4a14095fe0cb4a1eda92dbe305436ffb248c5a8ba9e13
text/kaden-channel/kaden-channel-6338063.txt	2963	c19c6d6c742e5b58ea785c3d7bbe52accb0e937b87fe158797d859371359745e
text/kaden-channel/kaden-channel-6484478.txt	1176	978051d555ee504c51c4b0e7a6c76fc022626c578228b92dccae2724166cb871
text/kaden-channel/kaden-channel-6497917.txt	4684	08f295dc4da441b1c9a12925f446972ca72f18b181cfeadf6db35d9c65818068
text/kaden-channel/kaden-channel-6530266.txt	1612	c62a7ef2f468f08e1b9fb71cc8f9afb960f4f0895c93386c8cafb6b640a5444b
text/kaden-channel/kaden-channel-6688340.txt	2287	3a929101a327078ba64e7b46a15a71fbf4532dc82bf6b4efeb120c120dda1caf
text/kaden-channel/kaden-channel-6745697.txt	1419	ed7d1171b3da03117270356cc0ad7e07fd83432c007fc92fabbb47733cf789f6
text/kaden-channel/kaden-channel-6763641.txt	1859	44662c42e8acbee0e65cf0ef55b87c4be92d363980770600024e30f91b8eb3d7
text/livedoor-homme/LICENSE.txt	526	f64bb0185089d40afcd01abab2b29f458540829564e31064f6d67eeaafeb55ea
text/livedoor-homme/livedoor-homme-4602124.txt	8188	293399ca89f1e53a02805b9dc4bd094f5ec6999da1bd30e48fb4c1c3f5601145
text/livedoor-homme/livedoor-homme-4692769.txt	6438	65fd15ebb91a00ab2afe2064767db60d350f99479ac25225f52b72f4e6568178
text/livedoor-homme/livedoor-homme-4730930.txt	3400	bd6a5eac9a6156559a8952d3dfdaaddf5733337dabc958f295e091012f1264d5
text/livedoor-homme/livedoor-homme-4874929.txt	1769	ccf9a2533b3c88bbbf08fff8e5e543e46cd0251db43706122ff375b8a9da3f65
text/livedoor-homme/livedoor-homme-4921525.txt	1933	f534a434cda98e9f2a81dfe136e62d735ca38f0fab84b55d8840db6d388cebae
text/livedoor-homme/livedoor-homme-5450050.txt	2373	b3bb9332a9cdb5d5a701b6b13ad01804a8a3a0384e357f46f8171aa7d36111ff
text/livedoor-homme/livedoor-homme-5450090.txt	1890	7682d2b23d99fd83c5027fc38f29cd4005c563590414139044b5c5d4b72af836
text/livedoor-homme/livedoor-homme-5667825.txt	1905	bbdc9216656fc34b03853db6e5d82f98289fedbba47eeaded2b3803754b48c96
text/livedoor-homme/livedoor-homme-5807555.txt	4518	b9f1823075688453f2b9259ffa67c89d61ea01f57fe99d81c1c12322f8c7e4a7
text/livedoor-homme/livedoor-homme-6052151.txt	4415	e6846c23fa10f4f1e5d68c32134602f703d903359eba399eba8365a20a3dcb20
text/livedoor-homme/livedoor-homme-6076425.txt	3072	2a31ed12c92cb5dde1201160575edc28d651695293091c10b10b16a316a8b297
text/livedoor-homme/livedoor-homme-6095213.txt	2577	c81f95024930a27797936a7f603f94455be865c0a3d2d327b49bc1be947c9f5a
text/livedoor-homme/livedoor-homme-6484559.txt	3581	7342c7a012174046c2e61dc4c54ace2ce3c41f34c01370dcfcfa6a354db78acc
text/movie-enter/LICENSE.txt	529	c75fbeda3d941fc16d18f7ed78cd71518b023f72d1527d18a2cd422ed583dcbf
text/movie-enter/movie-enter-5908336.txt	3287	0c32ae50ff61bb932cd564f5eff2e7234cd1f504bffa53cc1b9440a518e3d3b8
text/movie-enter/movie-enter-5950651.txt	5214	d3a192a659c70216d8e703bdbbb5097725825a43b07b6237b72c8ed01da17462
text/movie-enter/movie-enter-5972654.txt	8079	2d431e2d173d068f1f39d4cd5f633b62474acfc2dff5aa2c2fb725db51f5c042
text/movie-enter/movie-enter-5979444.txt	5338	ac124c2029ebfea84fd974f64cceaa43559f182ad2de1b2de4f77c1c9fc011c9
text/movie-enter/movie-enter-6075201.txt	3469	cca73f13f8b27d2af73409a13980f4b2eee3aa4276f751f85303e4a8aed8b3a4
text/movie-enter/movie-enter-6077002.txt	7562	3f350132b552fff1cdd2b255b54661bdcccb4c64c77611fd62a8e6db8dfb04b5
text/movie-enter/movie-enter-6178173.txt	5673	3b58a99dd97ebf9a5315ec10da70f33319590ea91f1b289d808eb630271335d3
text/movie-enter/movie-enter-6217461.txt	2581	0bd3b279bd76b122f1de7dc8526dc853823dee23b14e31bb43ee395275b96819
text/movie-enter/movie-enter-6278407.txt	7809	3bcfb133f93cccf1ffc08894e62baad54e5d808d6235d7f6bf81cd19a08cde54
text/movie-enter/movie-enter-6316908.txt	2074	dfa3411c9f01f8fe3977f7c4d8e44230d7987b30343a770bd023a32a072d207e
text/movie-enter/movie-enter-6350928.txt	5161	9e0b2b695a919f503f921d25855c5806015e4e28fc3908d66d7e09febc541e7b
text/movie-enter/movie-enter-6353886.txt	5267	793f4bcb2bae060519ec152c605f752a157a3ba9483a1b25473b842e20a487d7
text/movie-enter/movie-enter-6368046.txt	5821	d221c38cb3789b17824cead6b515646a8f03dd543422e5520318b726d3fa89dc
text/movie-enter/movie-enter-6467890.txt	5134	9152a2c7bb2a26b5f7ecd24e61708c83a689ff1fa4dbdd2a7960623cdd527879
text/movie-enter/movie-enter-6469135.txt	5736	6758c21595911df9ba9363bca9f3cd8fb015f19d91dce2ace62ca50d29746dd6
text/movie-enter/movie-enter-6542182.txt	7832	31d476d4deeb027f7b9b6ffab98470286184a77560e3f08d96ee8ad3a5e897e9
text/movie-enter/movie-enter-6561682.txt	3199	cad9cab78bec355bb6c7aab102c5328650eb3a8d26aecc18112cca402139792e
text/movie-enter/movie-enter-6568183.txt	3520	f4d000fe4373a512473379b237d9e315e6e65a189e85846df2d6be7dc69e4206
text/movie-enter/movie-enter-6590065.txt	1371	5ca0305241d6315ac87d2836548e5488d39d15d962404a7c313aafcf6a44925a
text/movie-enter/movie-enter-6685499.txt	1345	e2f15b8187f4d144e9f3dbe80065322163067e792ade1055859c904cdbcf0a14
text/movie-enter/movie-enter-6714654.txt	3588	1424ac41e44df90a20755e5d8d647161524c630fc730f2097718e2207e74ae3b
text/peachy/LICENSE.txt	520	3c375a5454198053de604a1ca9b3fee13287887e4f9b7b179e668e65f43fd4d2
text/peachy/peachy-4386543.txt	1689	42cab1b6db0895ce03ec6ee7cd50b308671cb466319b947746eadf73ad3aed57
text/peachy/peachy-4449009.txt	1485	5d6e925004093e24c428d31a015e908dedcd16f04c6f6f4fee8ed66b718bd4c5
text/peachy/peachy-4495213.txt	4077	9c6472b9b5612072c67cd717d79f5713c2060a30d2f7677957b6ecae83a853ce
text/peachy/peachy-4516010.txt	4681	a91a898260bafe2cee6883889edbdd59ef3fc1e7a6b24934b6d160164986f094
text/peachy/peachy-4645799.txt	1750	076d5b60f9891d91c8fbb223ff9e78abd18b1b468741fe9f8f9d076a612fb89e
text/peachy/peachy-4667108.txt	3049	7513dbb15bac8fbe36dd0167fb30c5338147efea309a6384965a6deda1b177b7
text/peachy/peachy-4707544.txt	1787	766cf091e4cc33b43366d07be7522adeaa989e118f2dbb11638e0a88746ffccc
text/peachy/peachy-4737880.txt	2673	91d4e8066dc5bdb2da1fd0b085ba4fdd24a0c8a85812e81880b24bdc585431b8
text/peachy/peachy-4743406.txt	2912	c6dd223f4092061851df1a518a95b7d094c129ec4686590556cd3db451d1c9ae
text/peachy/peachy-4844138.txt	3871	d4f2f447c1ea23273c9668dfb527d01b58ecfce4aff54021a6d6e68d655f4dbf
text/peachy/peachy-4881585.txt	2372	aa9b9379756317ca132fca4110e1ce81e7b603c5b8662a1068ed7b43cb9d17a2
text/peachy/peachy-4903439.txt	3909	8fe72bd0f05d1d6e0c43e3cc98959a5e497564e7288e6860a57ffbbced881c53
text/peachy/peachy-4986975.txt	4814	679a2d1ef9bcb2067606e34c0c9a87ab65cb4359df7d3e27d336b386e7c82bfa
text/peachy/peachy-5082009.txt	3506	90b8b96179bb0b3f73480ddf2d2f6e2a8d1d40526dd31fd3b9d5d333a431fd70
text/peachy/peachy-5130975.txt	2228	ff02b9429aba03276ed22b6096531b1b750c73cfa2985ea5929c28c75b34b9bc
text/peachy/peachy-5200667.txt	4163	7d40308fda74418dc6b9683d8ceb3a5ad580cdb4885eb34c88d010c20078d412
text/peachy/peachy-5332120.txt	1057	3cc1fadc6dba2ee62ae005fd36d3a3f41c56ec4328cce8a69cc5727631fb9595
text/peachy/peachy-6079986.txt	8990	2dd90f0c01bbdfc930fd18684eabea9ecc1871346253c8c8a74f1145ea4f3915
text/peachy/peachy-6148835.txt	7387	897607d5a09cb4d8c97db760a24491d48bfbc3616ad8b2d798f3437d791d007e
text/peachy/peachy-6853693.txt	4196	cdfb36848715658a38e3a5e8ad5f9acb03e1f5e786dbf5863f9ef3c783bf15af
text/peachy/peachy-6907988.txt	2918	0078b652b6cfd7249fa8d2ad41ef6bb93c5e2768fbced0f0b138ed00ded8f718
text/smax/LICENSE.txt	529	6f8d11def5d31978310128cb74e322dc6f674dff236a2b9dee8af9db045a136b
text/smax/smax-6514482.txt	3231	8e5782e47e7a4cb96de40d7c6e1d35a4d1591eb51db89dc3efd70b6bb4a92751
text/smax/smax-6528823.txt	7465	15ba1b94d31e3e90e60eb49fff5f29d3068943b4de48aeb4349df5349d27647a
text/smax/smax-6563634.txt	1997	37de542c3b22182728f4abf9ec92c17c7f47879bd201b290bba3e78a51d7608c
text/smax/smax-6563723.txt	1986	a0ccbae75ce036c36b10e0c49d1f27735f5c905d88560fec514d567c6379213b
text/smax/smax-6570626.txt	4685	3fbf8a6d8ba07281e98ab21e05551964ace4871c48fda5a74502695329417d8d
text/smax/smax-6582464.txt	8036	410673034d981d3698467acdd5c70bf743ad7f02ece3fd1f03e2ec215913c069
text/smax/smax-6673414.txt	8330	b7b230c04bf59167c1764256e41405df3527877662c6b7d8b84fe1f5dc7946f9
text/smax/smax-6682371.txt	2717	9dd71b7bbcfe54a8065ae4de42fedc257a00dfcb296f9c4132de04f8df8e70a5
text/smax/smax-6695392.txt	5736	c6e86257a5c123e0f1faff25a5ba27a69fd9189cfd0c6c4574d952ed64a78b5b
text/smax/smax-6695613.txt	2307	94991f80d723b86cf99d68cc9b69fad0834da38d6e52ca72ddd8d58898e6f429
text/smax/smax-6701937.txt	1902	1e95457e34d4384c0106ab2048cfe80d19f16a12017068ff1e7d9ab66eed4332
text/smax/smax-6741096.txt	2818	39dfab4542a97b8cf2f7acae2afd9e0bd679a462d553a73b7c49ab9badefb720
text/smax/smax-6760971.txt	5068	7621dd66c14d142181e8e9551a07c5d957ae5f0222e635a9bfc16451f4713223
text/smax/smax-6775177.txt	5253	6f8fb993107f800ccbac98a501f7bfe8c4ba5e892f7f35f17269f708d8f51634
text/smax/smax-6792496.txt	6617	6e1348d6d16cf371581accbb8b284c1e29aa84bc22dd21a4be43c064835bdfd1
text/smax/smax-6805310.txt	2060	4921666595f0d71d8b645c8ef8d9156cef7529a0f0408ec77009e4768cafcac8
text/smax/smax-6808604.txt	1917	8f95a760df75e106fccd058cf7b86122b70ec897b2ae4de5f72de32ecc9920b1
text/smax/smax-6815464.txt	2476	b329b350b2eca9174496b5e5f740d64bab15357c6673ec342a528a88c6789e85
text/smax/smax-6838453.txt	4755	1cbf4848f0b5f78cfafd027e0f35908817368d4f8d91be40bfe3dfd67207e2ac
text/smax/smax-6903745.txt	4140	94b66a99e33198ba619983985f1d339745ca7ec41769363b76c6affcee056bab
text/smax/smax-6913238.txt	6604	89779be51c708d56c6c3b59096f66ecb70fbda3aeffd6a40f6f69be71a2b54c6
text/sports-watch/LICENSE.txt	522	934b90a8125c9651905390b2aa5fa566d33102c311d95bdf2face89b82b1cda4
text/sports-watch/sports-watch-4604621.txt	1266	f8e886fe9160b63f4c437a4a9a33a0f44277ca1fc40ec306f706076158fafde5
text/sports-watch/sports-watch-4627799.txt	733	c5a48eeee76c98c801fec80ccb015d402615c2e4026f370ad08ff65ffed375a3
text/sports-watch/sports-watch-4727404.txt	2018	373c9290ae0c52ceb2afdda10593a866ad1e7c49719677951e9d8c27f322a4d3
text/sports-watch/sports-watch-4764440.txt	1327	b79cf83becb426e96559b3a159ed4c8e850113c9204999ae6bc58e4dfb98b80f
text/sports-watch/sports-watch-5059771.txt	1656	86bfafe5bd85d903c29c9687046c9f2ff96e896a0f9d806e71b933c9a28b1ba5
text/sports-watch/sports-watch-5129796.txt	1973	2a5f58168638954e0cb9e0df704d42307e5060f2b54f7913263beeab0f96bb28
text/sports-watch/sports-watch-5232886.txt	1961	d09cbd9da783cb9769b48f7919dfee1b7a63494be9cf3f0e3b68af885fcd8389
text/sports-watch/sports-watch-5240382.txt	1464	e0b6797dc7beea0c288e2370ee914ff8d15f659b80e89dccd354f69293ad777a
text/sports-watch/sports-watch-5258917.txt	2521	9e480c59c273091290da074e676bb264f2915b2372579a8f3256039b8b30c0bc
text/sports-watch/sports-watch-5295529.txt	2161	b647c09fd12f8b824c57b2295135c9468a83feb64cae110707d904bf0d23f3c9
text/sports-watch/sports-watch-5397323.txt	2617	738502d5409acb8e1d23a26a964609d1152114cba3e83416e3e5a0119d4495ed
text/sports-watch/sports-watch-5644902.txt	1921	6fff5c59719d1899e2ad9cd60ed407736721fcbb1bf66f543b18d80796f9cbeb
text/sports-watch/sports-watch-5784017.txt	2495	9927adee6b99d64ce05d57c87e75819da31162bb531584034b651327840d97fd
text/sports-watch/sports-watch-5795150.txt	1547	716efb5597400424fd77290941abdbd10cb5e21f4c1aaa5dca1a619b60d39147
text/sports-watch/sports-watch-5838039.txt	3297	afb27c64f52a51205fbbf80fbdf5cf61570bb16dbd27a1e0686a4382c82387c8
text/sports-watch/sports-watch-5970480.txt	2374	8df85aa67a9eae6de7fdba1f529f8b0ff7ff3eb262be4d031d56a4acd037441a
text/sports-watch/sports-watch-6117429.txt	1313	01e6d0e9805eebece4e61dadbd4c7631d9774e347720d08fd2e938cf1e8f9ace
text/sports-watch/sports-watch-6203815.txt	2179	7ec7b6fdd48975b0cbd4c4977727736edee759ec1d4f2c374293f0aff8bd5006
text/sports-watch/sports-watch-6366796.txt	2581	fa220781fe0384254f863f62b7c2ed61f310f91c395b119c78edb149ffcc975d
text/sports-watch/sports-watch-6494382.txt	3039	9b639641926fc1b2fdda9eaea663102c134c3738e0d0e1d3dee354c048e36d51
text/sports-watch/sports-watch-6522678.txt	2259	71045bd696aab20bdace6b38ae8358c9471a6953784a9f89d0ca4b27ac585700
text/sports-watch/sports-watch-6796211.txt	1670	aed4d18936a8fea267aef7025c00ea68b94bc82a869d19b6b8ca02d4cbbb9f47
text/topic-news/LICENSE.txt	535	d409183e22dc4d0ac2f0b1075ca1d7f500f8c935a057a9c9246ad3a5584a8af1
text/topic-news/topic-news-5961523.txt	2017	f7d1454b55ee3738655afa42882273871480f75b2fc492f4d2073e13b4bde6e6
text/topic-news/topic-news-5971067.txt	1569	cd02019e6fad68a40cb0732f6cdfc7225da60d16557ae62c10217b6e2b4d18dc
text/topic-news/topic-news-6005118.txt	2835	88f3951411e66f06ab6cf3ec8f17b431b14a6f9bfc72ce0469909fd4d3bd296b
text/topic-news/topic-news-6018683.txt	2140	f77fe947200b782080c9611272bd37bce10a73d2712dfddfbafd7c545318289c
text/topic-news/topic-news-6033135.txt	2893	d61920e29eb6df3b6a2a09ddc2e7fca69f4b61b86c566d502a084791d9d0729f
text/topic-news/topic-news-6110252.txt	2170	37ef4323dac8a1c489a1192ddd64c99d0e6437d132bce6405c4450b7f6b0c9ae
text/topic-news/topic-news-6184471.txt	1727	b048d722f1baf4aa29adc2d125dfc6d4b1ac69b0552cdffd41b9ebb0f33cc15f
text/topic-news/topic-news-6241641.txt	2846	b74b6fb4422e2e9ec06d9f9335e1d1a0eea0db80beb2ebd9bc4d8aa762bfd854
text/topic-news/topic-news-6279349.txt	2814	7677604a5aab47aa9aa9ead7639169cba3d7b0ab160c24b75c41d24de9274403
text/topic-news/topic-news-6302176.txt	2224	b1291f1231d09bcabb4b3f83d673d396e4468a37943419bb77b1c4409363c834
text/topic-news/topic-news-6309374.txt	1716	182e28719663e53524433a32f9808230276fdfda74f80d67e5a9cc992a9289e3
text/topic-news/topic-news-6397479.txt	2292	d5b5a969f10f92f1c95e0c7eb2d6c2be501e1e06b9c7ec090349d263c27f5531
text/topic-news/topic-news-6594397.txt	3064	4956d21e97f4768b9709a7b254b73fe5ffd53b03269195b1b2e08d9e52e391aa
text/topic-news/topic-news-6681547.txt	2297	59363a628998de187f2f3f2e3b2fe9e3888c4adfd36d8d9c8f76e6bcbd6707d3
text/topic-news/topic-news-6685969.txt	2351	712eb46541ac9d09a99a897fddf5eeb2c21bac78f46a698bbc3ad33a339dee0b
text/topic-news/topic-news-6713473.txt	2869	c7b651a02c73bd5df765f55957ba9d03ced2a2edfaa2c222e4d64d76cd135c6a
text/topic-news/topic-news-6730931.txt	2465	376a3dc55c92ca8b10ba81040ea802600614c5d43becb89da2b8baa6dc89e212
text/topic-news/topic-news-6765528.txt	1872	f0b459eb399cd17a68d5ff15ece2d966d72599be378d7bafa9a54feeec4d9205
text/topic-news/topic-news-6831564.txt	3118	ff81c19b3aaef7baf83e1fc507427d52d50e4a70689f6589c98cff83f7aa5dad
'@
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\livedoor-holdout-20261020')
            ZipBytes=661042L; ZipSha256='e9d770628225650dd1b28a355f908cdf3c54b0ae68bf397776d6757cfc4a3209'
            Files=191; Bytes=629588L; ManifestSha256='4c23d4dbdd312c4d7c9efa4199ccfff30c36a33671f53421e27a0578b57beec1'
            EntryPrefix='input/'; StoredMember=$true; CandidateManifestSha256=$null
            SourceFamily='Livedoor News 2012 corpus'; Scope='HOLDOUT ONLY: fixed 180-article proportional sample plus nine category licenses and two root metadata files; one source family; never development/training/tuning'
            StartDate='not-inferred'; EndDate='not-inferred'; Fields=@('unchanged_article_text','category_license','root_metadata')
            ListingOutputBytes=256KB
            Provenance=[ordered]@{
                schema=1; source_url='https://www.rondhuit.com/download/ldcc-20140209.tar.gz'
                source_archive_bytes=8855190L; source_archive_sha256='b17606ed8c670013a3809100a9e6104701baab62cc019abc262111bd2acf1063'
                source_tar_entries=7388; source_regular_files=7378; source_directories=10; source_special_entries=0; source_regular_bytes=25895663L
                source_article_count=7367; selected_article_count=180; source_family_count=1
                selection='largest-remainder proportional category quotas; equal remainders by category ordinal; within category smallest lowercase SHA-256 of UTF-8 tar-member path, ordinal order'
                categories=@(
                    [ordered]@{category='dokujo-tsushin';population=870;selected=21;content_provider='独女通信';license_member='text/dokujo-tsushin/LICENSE.txt'}
                    [ordered]@{category='it-life-hack';population=870;selected=21;content_provider='ITライフハック';license_member='text/it-life-hack/LICENSE.txt'}
                    [ordered]@{category='kaden-channel';population=864;selected=21;content_provider='家電チャンネル';license_member='text/kaden-channel/LICENSE.txt'}
                    [ordered]@{category='livedoor-homme';population=511;selected=13;content_provider='livedoor HOMME';license_member='text/livedoor-homme/LICENSE.txt'}
                    [ordered]@{category='movie-enter';population=870;selected=21;content_provider='MOVIE ENTER';license_member='text/movie-enter/LICENSE.txt'}
                    [ordered]@{category='peachy';population=842;selected=21;content_provider='Peachy';license_member='text/peachy/LICENSE.txt'}
                    [ordered]@{category='smax';population=870;selected=21;content_provider='エスマックス';license_member='text/smax/LICENSE.txt'}
                    [ordered]@{category='sports-watch';population=900;selected=22;content_provider='Sports Watch';license_member='text/sports-watch/LICENSE.txt'}
                    [ordered]@{category='topic-news';population=770;selected=19;content_provider='トピックニュース';license_member='text/topic-news/LICENSE.txt'}
                )
                root_metadata_members=@('text/CHANGES.txt','text/README.txt')
                license_label='CC BY-ND 2.1 JP'; license_url='https://creativecommons.org/licenses/by-nd/2.1/jp/'
                attribution='Credit the original author and category content provider as stated in each included category LICENSE.txt.'
                content_handling='Article bytes unchanged; all nine LICENSE files retained; stored ZIP entries with original nested paths.'
                article_content_displayed_or_parsed=$false; artifacts_local_only=$true; artifacts_publication_allowed=$false
                wrapper_timestamp_utc='1980-01-01 00:00:00 UTC'; input_entry_prefix='input/'
                listing_stdout_bytes=256KB; listing_stderr_bytes=2KB
                member_marker_policy='Wrapper SHA-256 and ordinal file-set SHA-256 pin all members; duplicate per-member marker rows omitted to keep marker <=32 KiB.'
            }
            Entries=@($memberRows.Split([char]10) | ForEach-Object {
                $parts=$_.TrimEnd([char]13).Split([char]9)
                [pscustomobject]@{name=$parts[0];bytes=[long]$parts[1];sha256=$parts[2]}
            })
        }
    }
    if ($CorpusProfile -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020') {
        # 新marker/reportを既存の固定入力・metadataから分離し、旧campaignの条件は変更しない。
        $profile=Get-KhcPortfolioInputProfile 'NictWikiCorpusHoldout20261020'
        $metadataDirectory=$profile.Directory
        $profile.Name=$CorpusProfile
        $profile.Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\nict-wiki-kcs1-count-length-holdout-20261020-v2')
        $profile.Scope='HOLDOUT ONLY: fixed 195 XML members, 13 per category; KCS1 count-only code lengths; one source family; never development/training/tuning'
        $profile | Add-Member -NotePropertyMembers @{
            InputZipPath=(Join-Path $metadataDirectory 'input.zip'); MetadataDirectory=$metadataDirectory
            InputRole='holdout-only'; DevelopmentOnly=$false; HoldoutOnly=$true; TrainingAllowed=$false; TuningAllowed=$false
            SourceManifestSha256='2c0335cea83661ff72c81875c01d67bd4737fa2273117e8a5ac7dc9dbb9f3a21'
            KhcSourceManifestSha256='16e8cd800b8696b92d2dc8e928cde73262779845157717d90a94075a650a1088'
            CliSha256='e1776bc7ca53109b77fa9f9f4215a2213f0fae28e7added9d6b9c1fdd9c77b7d'; CliBytes=2581504L
        }
        return $profile
    }
    if ($CorpusProfile -ceq 'NictWikiCorpusHoldout20261020') {
        return [pscustomobject]@{
            Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\nict-wiki-holdout-20261020-195-entry')
            ZipBytes=5257215L; ZipSha256='aee6335bc9f43f35e5c29c3944cb8067eefed618578c02c8faac4ff4112c5ecd'
            Files=195; Bytes=5236133L; ManifestSha256='cad92e76db4142c15c32b924f8906320a38fff42638d1cdc69e5a9ed157b66f5'
            EntryPrefix=''; StoredMember=$true; Entries=@(); CandidateManifestSha256=$null; ListingOutputBytes=256KB
            SourceFamily='NICT Japanese-English Wikipedia corpus'; Scope='HOLDOUT ONLY: fixed 195 XML members, 13 per category; one source family; never development/training/tuning'
            StartDate='not-inferred'; EndDate='not-inferred'; Fields=@('unchanged_xml')
            Provenance=[ordered]@{
                schema=1; source_url='https://alaginrc.nict.go.jp/WikiCorpus/src/wiki_corpus_2.01.tar.gz'
                source_page='https://alaginrc.nict.go.jp/WikiCorpus/'; source_readme_url='https://alaginrc.nict.go.jp/WikiCorpus/src/readme.pdf'
                source_archive_bytes=74096805L; source_archive_sha256='456172bdd1d7a32dbe68ae3e55e0a6de25a4f40582636fd7712a5404319a10e5'; source_version='2.01'
                license_label='CC BY-SA 3.0'; license_version='3.0'; license_url='https://creativecommons.org/licenses/by-sa/3.0/'
                attribution='本サービスで使用している[データ]はWikipediaの日本語文を国立研究開発法人情報通信研究機構が英訳したものを、Creative Comons Attribution-Share-Alike License 3.0による利用許諾のもと使用しております。詳細はhttp://creativecommons.org/licenses/by-sa/3.0/およびhttp://alaginrc.nict.go.jp/WikiCorpus/をご覧下さい。'
                selected_member_count=195; selected_payload_bytes=5236133L; source_family_count=1
                category_codes=@('BDS','BLD','CLT','EPR','FML','GNM','HST','LTT','PNM','RLW','ROD','SAT','SCL','SNT','TTL'); selected_per_category=13
                selection_manifest_sha256='c575b295d3afff9e057fc078688caf71b5d9edae849d1d9bc637fd2b4db73e09'
                member_manifest_sha256='21cab6251284f8b020c66756e9a96e711fa76abf4fea1f8342ef83d894504748'
                archive_inventory_sha256='f9cccf4b35220e8b95e33477778d5636dc71c58072ef319dee9b7b181d40217e'
                acquisition_record_sha256='4a2dcd95379f4af5aab54fcb04d97e9cd733ef23fa2e841ea0d7b0c2f4e3f8ae'
                preparer_sha256='2070319bd1847534213febb30051d8d2a102124b758f692e2c8d764b802e9dc0'
                content_handling='Unchanged XML bytes; local only; no article text, titles or member paths in logs or reports. Source Wikipedia content may contain defamatory, discriminatory or personal information.'
                article_content_displayed_or_parsed=$false; artifacts_local_only=$true; artifacts_publication_allowed=$false
                wrapper_timestamp_utc='1980-01-01 00:00:00 UTC'; input_entry_prefix=''; input_zip_compression='stored'
                listing_stdout_bytes=256KB; listing_stderr_bytes=2KB
                member_marker_policy='Wrapper SHA-256 and ordinal file-set SHA-256 pin all members; member paths omitted from marker and reports.'
            }
        }
    }
    if ($CorpusProfile -cne 'AozoraDevelopment20261020') { throw 'Corpus profile spelling/case must match the fixed identifier.' }
    return [pscustomobject]@{
        Name=$CorpusProfile; Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\aozora-dev-20261020')
        ZipBytes=222247L; ZipSha256='9772d6af224028a70c2d50af8f64faebf03de9a487a08fee566de4c1128cb0b6'
        Files=2; Bytes=222009L; ManifestSha256='4d9ded91fe0a2e7657cce870f7fd39a4c83c8b7fe5e26f7230ebd8e53c1d2ea6'
        EntryPrefix='input/'; StoredMember=$false
        CandidateManifestSha256='caa078a5053669dfd0fb90ebe9d3941b69a76a36600dec2579495f0de58c516d'
        SourceFamily='Aozora Bunko'; Scope='DEVELOPMENT/TRAINING/TUNING ONLY: Aozora Bunko No.424/752; one source family; no holdout evaluation'
        Entries=@(
            [pscustomobject]@{name='bocchan.txt';bytes=209990L;sha256='8b1087162da44dbf54705c15f5ba62c7c07db86bb6f38caacd4f5beb62e4618b'},
            [pscustomobject]@{name='lemon.txt';bytes=12019L;sha256='979e3e94b2537ef922851023bef4c32530ba4b7eef2e3c15bf66c80a495a5512'}
        )
    }
}

function Get-KhcPortfolioInputZipPath {
    param([Parameter(Mandatory)]$Profile)
    if ($Profile.Name -ceq 'UciDryBeanHoldout20261020') { return $Profile.InputZipPath }
    if ($Profile.Name -ceq 'CanterburyDevelopmentKcs1CountLength20261020') { return $Profile.InputZipPath }
    if ($Profile.Name -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020') { return $Profile.InputZipPath }
    return Join-Path $Profile.Directory 'input.zip'
}

function Assert-KhcPortfolioInput {
    param([Parameter(Mandatory)][string]$CorpusProfile, [Parameter(Mandatory)][string]$InputRecoveryZip, [string]$CampaignManifestSha256)
    $profile=Get-KhcPortfolioInputProfile $CorpusProfile
    if ($profile.Name -ceq 'NictWikiCorpusHoldout20261020') { Assert-KhcNictMetadataGate -CampaignManifestSha256 $CampaignManifestSha256 }
    if ($profile.Name -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020') { Assert-KhcNictKcs1MetadataGate -CampaignManifestSha256 $CampaignManifestSha256 }
    if ($profile.Name -ceq 'UciDryBeanHoldout20261020') { Assert-KhcDryBeanMetadataGate -CampaignManifestSha256 $CampaignManifestSha256 }
    if ($profile.Name -ceq 'UciTabularDevelopment20261020') { throw 'UCI development-only metadata has no admitted input wrapper; payload validation and holdout evaluation are forbidden.' }
    $path=Assert-KhcPlainPath $InputRecoveryZip
    if ($path -cne (Get-KhcPortfolioInputZipPath $profile) -or
        (Get-Item -LiteralPath $path -Force).Length -ne $profile.ZipBytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $profile.ZipSha256) {
        throw 'Fixed portfolio input ZIP path/length/SHA mismatch.'
    }
    if ($profile.StoredMember) {
        $reader=[IO.BinaryReader]::new([IO.File]::OpenRead($path))
        try { $header=$reader.ReadBytes(30) } finally { $reader.Dispose() }
        if ($header.Length -ne 30 -or [BitConverter]::ToUInt32($header,0) -ne 0x04034b50 -or [BitConverter]::ToUInt16($header,8) -ne 0) { throw 'Fixed holdout ZIP requires a stored (uncompressed) member.' }
    }
    $zip=[IO.Compression.ZipFile]::OpenRead($path)
    try {
        $members=@($zip.Entries)
        if ($profile.Name -ceq 'CanterburyDevelopmentKcs1CountLength20261020') {
            $members=@($zip.Entries | Where-Object { $_.FullName.StartsWith($profile.EntryPrefix,[StringComparison]::Ordinal) })
        }
        if ($members.Count -ne $profile.Files) { throw 'Fixed portfolio ZIP entry count mismatch (directory entries are forbidden).' }
        $rows=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $members) {
            if (-not $entry.FullName.StartsWith($profile.EntryPrefix,[StringComparison]::Ordinal) -or [string]::IsNullOrEmpty($entry.Name)) { throw 'Fixed portfolio ZIP entry prefix/type mismatch.' }
            $name=$entry.FullName.Substring($profile.EntryPrefix.Length)
            if ($name.StartsWith('/') -or $name.Contains('\') -or $name.Contains(':') -or $name.Contains('//') -or $name.EndsWith('/') -or $name -match '(^|/)\.{1,2}(/|$)' -or -not $seen.Add($name)) { throw 'Unsafe or duplicate fixed portfolio ZIP member.' }
            if ($entry.Length -le 0 -or $entry.Length -gt $profile.Bytes) { throw 'Fixed portfolio ZIP entry length is out of range.' }
            if ($profile.Name -cin @('UciDryBeanHoldout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020') -and $entry.LastWriteTime.DateTime -ne [DateTime]::new(1980,1,1)) { throw 'Fixed holdout member timestamp mismatch.' }
            if ($profile.StoredMember -and $entry.CompressedLength -ne $entry.Length) { throw 'Fixed holdout ZIP stored member length mismatch.' }
            $stream=$entry.Open()
            try {
                $sha=[Security.Cryptography.SHA256]::Create()
                try { $digest=[Convert]::ToHexString($sha.ComputeHash($stream)).ToLowerInvariant() } finally { $sha.Dispose() }
            } finally { $stream.Dispose() }
            $rows.Add($name,[pscustomobject]@{name=$name;bytes=[long]$entry.Length;sha256=$digest})
        }
        $names=[string[]]$rows.Keys; [Array]::Sort($names,[StringComparer]::Ordinal)
        $lines=[Collections.Generic.List[string]]::new(); $bytes=0L
        foreach ($name in $names) {
            $row=$rows[$name]; $bytes+=$row.bytes
            $lines.Add("$name`t$($row.bytes.ToString([Globalization.CultureInfo]::InvariantCulture))`t$($row.sha256)")
        }
        $manifestText=[string]::Join("`n",$lines)
        # Canterburyの既存11-file manifestは各行末LF込み。既存portfolio profileの方式は維持する。
        if ($profile.Name -ceq 'CanterburyDevelopmentKcs1CountLength20261020') { $manifestText+="`n" }
        $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($manifestText))).ToLowerInvariant()
        if ($bytes -ne $profile.Bytes -or $digest -cne $profile.ManifestSha256) { throw 'Fixed portfolio ZIP file-set digest/length mismatch.' }
        foreach ($expected in $profile.Entries) {
            if (-not $rows.ContainsKey($expected.name) -or $rows[$expected.name].bytes -ne $expected.bytes -or $rows[$expected.name].sha256 -cne $expected.sha256) { throw 'Fixed portfolio member name/length/SHA mismatch.' }
        }
        return $profile
    } finally { $zip.Dispose() }
}

function Assert-KhcAozoraCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'AozoraDevelopment20261020' @PSBoundParameters
}

function Assert-KhcCanterburyKcs1Campaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'CanterburyDevelopmentKcs1CountLength20261020' @PSBoundParameters
}

function Assert-KhcJmaHoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'JmaTokyoDaily2010_2025Holdout20261020' @PSBoundParameters
}

function Assert-KhcTokyoPopulationHoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'TokyoResidentRegister202101Holdout20261020' @PSBoundParameters
}

function Assert-KhcLivedoorMetadata {
    param([Parameter(Mandatory)][AllowNull()][object]$Actual, [Parameter(Mandatory)][object]$Expected)
    # 固定schemaを再帰比較し、欠落・追加・型の変化も拒否する。
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary] -or $Actual.Count -ne $Expected.Count) { throw 'Livedoor provenance schema mismatch.' }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key)) { throw "Missing Livedoor provenance field: $key" }
            Assert-KhcLivedoorMetadata -Actual $Actual[$key] -Expected $Expected[$key]
        }
    } elseif ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { throw 'Livedoor provenance array mismatch.' }
        for ($i=0; $i -lt $Expected.Count; $i++) { Assert-KhcLivedoorMetadata -Actual $Actual[$i] -Expected $Expected[$i] }
    } elseif ($Expected -is [bool]) {
        if ($Actual -isnot [bool] -or $Actual -cne $Expected) { throw 'Livedoor provenance boolean mismatch.' }
    } elseif ($Expected -is [string]) {
        if ($Actual -isnot [string] -or $Actual -cne $Expected) { throw 'Livedoor provenance string mismatch.' }
    } elseif ($null -eq $Actual -or $Actual -is [string] -or $Actual -is [bool] -or [decimal]$Actual -ne [decimal]$Expected) {
        throw 'Livedoor provenance numeric mismatch.'
    }
}

function Assert-KhcLivedoorHoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'LivedoorNews2012Holdout20261020' @PSBoundParameters
}

function Assert-KhcNictMetadata {
    param([Parameter(Mandatory)][AllowNull()][object]$Actual, [Parameter(Mandatory)][object]$Expected)
    try { Assert-KhcLivedoorMetadata -Actual $Actual -Expected $Expected }
    catch { throw 'NICT frozen provenance identity/schema mismatch.' }
}

function Assert-KhcNictMetadataGate {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256)
    if ($CampaignManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'NICT requires an immutable start-marker SHA before payload access.' }
    $profile=Get-KhcPortfolioInputProfile 'NictWikiCorpusHoldout20261020'
    $path=Assert-KhcPlainPath (Join-Path $profile.Directory 'campaign-start.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'NICT immutable start-marker is missing; payload access forbidden.' }
    if ((Get-Item -LiteralPath $path -Force).Length -gt 32KB -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CampaignManifestSha256) { throw 'NICT immutable start-marker length/SHA mismatch.' }
    $marker=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 12
    Assert-KhcNictMetadata -Actual $marker.source_provenance -Expected $profile.Provenance
    if ([string]$marker.corpus_profile -cne $profile.Name -or [string]$marker.input_zip_path -cne (Join-Path $profile.Directory 'input.zip') -or
        [long]$marker.input_zip_bytes -ne $profile.ZipBytes -or [string]$marker.input_zip_sha256 -cne $profile.ZipSha256 -or
        [int]$marker.input_files -ne $profile.Files -or [long]$marker.input_bytes -ne $profile.Bytes -or
        [string]$marker.input_manifest_sha256 -cne $profile.ManifestSha256 -or @($marker.input_entries).Count -ne 0) { throw 'NICT immutable input identity mismatch.' }
    foreach ($pin in @(
        @{name='selection-manifest.json';sha=$profile.Provenance.selection_manifest_sha256},
        @{name='member-manifest.json';sha=$profile.Provenance.member_manifest_sha256},
        @{name='archive-inventory.json';sha=$profile.Provenance.archive_inventory_sha256},
        @{name='acquisition-record.json';sha=$profile.Provenance.acquisition_record_sha256}
    )) {
        $metadataPath=Assert-KhcPlainPath (Join-Path $profile.Directory $pin.name)
        if ((Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha) { throw 'NICT frozen metadata file SHA mismatch.' }
    }
}

function Assert-KhcNictKcs1MetadataGate {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256)
    if ($CampaignManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'NICT requires an immutable start-marker SHA before payload access.' }
    $profile=Get-KhcPortfolioInputProfile 'NictWikiCorpusKcs1CountLengthHoldout20261020'
    $path=Assert-KhcPlainPath (Join-Path $profile.Directory 'campaign-start.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'NICT immutable start-marker is missing; payload access forbidden.' }
    if ((Get-Item -LiteralPath $path -Force).Length -gt 32KB -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CampaignManifestSha256) { throw 'NICT immutable start-marker length/SHA mismatch.' }
    $marker=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 12
    Assert-KhcNictMetadata -Actual $marker.source_provenance -Expected $profile.Provenance
    if ([string]$marker.corpus_profile -cne $profile.Name -or [string]$marker.input_zip_path -cne (Get-KhcPortfolioInputZipPath $profile) -or
        [long]$marker.input_zip_bytes -ne $profile.ZipBytes -or [string]$marker.input_zip_sha256 -cne $profile.ZipSha256 -or
        [int]$marker.input_files -ne $profile.Files -or [long]$marker.input_bytes -ne $profile.Bytes -or
        [string]$marker.input_manifest_sha256 -cne $profile.ManifestSha256 -or @($marker.input_entries).Count -ne 0) { throw 'NICT immutable input identity mismatch.' }
    foreach ($pin in @(
        @{name='selection-manifest.json';sha=$profile.Provenance.selection_manifest_sha256},
        @{name='member-manifest.json';sha=$profile.Provenance.member_manifest_sha256},
        @{name='archive-inventory.json';sha=$profile.Provenance.archive_inventory_sha256},
        @{name='acquisition-record.json';sha=$profile.Provenance.acquisition_record_sha256}
    )) {
        $metadataPath=Assert-KhcPlainPath (Join-Path $profile.MetadataDirectory $pin.name)
        if ((Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha) { throw 'NICT frozen metadata file SHA mismatch.' }
    }
}

function Assert-KhcNictKcs1HoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcNictKcs1MetadataGate -CampaignManifestSha256 $CampaignManifestSha256
    Assert-KhcPortfolioCampaign -CorpusProfile 'NictWikiCorpusKcs1CountLengthHoldout20261020' @PSBoundParameters
}

function Assert-KhcNictHoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcNictMetadataGate -CampaignManifestSha256 $CampaignManifestSha256
    Assert-KhcPortfolioCampaign -CorpusProfile 'NictWikiCorpusHoldout20261020' @PSBoundParameters
}

function Assert-KhcDryBeanMetadata {
    param([Parameter(Mandatory)][AllowNull()][object]$Actual, [Parameter(Mandatory)][object]$Expected)
    # 固定schemaを再帰比較し、欠落・追加・型の変化も拒否する。
    if ($Expected -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary] -or $Actual.Count -ne $Expected.Count) { throw 'DryBean provenance schema mismatch.' }
        foreach ($key in $Expected.Keys) {
            if (-not $Actual.Contains($key)) { throw "Missing DryBean provenance field: $key" }
            Assert-KhcDryBeanMetadata -Actual $Actual[$key] -Expected $Expected[$key]
        }
    } elseif ($Expected -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Expected.Count) { throw 'DryBean provenance array mismatch.' }
        for ($i=0; $i -lt $Expected.Count; $i++) { Assert-KhcDryBeanMetadata -Actual $Actual[$i] -Expected $Expected[$i] }
    } elseif ($Expected -is [bool]) {
        if ($Actual -isnot [bool] -or $Actual -cne $Expected) { throw 'DryBean provenance boolean mismatch.' }
    } elseif ($Expected -is [string]) {
        if ($Actual -isnot [string] -or $Actual -cne $Expected) { throw 'DryBean provenance string mismatch.' }
    } elseif ($null -eq $Actual -or $Actual -is [string] -or $Actual -is [bool] -or [decimal]$Actual -ne [decimal]$Expected) {
        throw 'DryBean provenance numeric mismatch.'
    }
}

function Assert-KhcDryBeanMetadataGate {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256)
    if ($CampaignManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Dry Bean requires immutable marker SHA before payload access.' }
    $profile=Get-KhcPortfolioInputProfile 'UciDryBeanHoldout20261020'
    $path=Assert-KhcPlainPath (Join-Path $profile.Directory 'campaign-start.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Dry Bean marker missing; payload access forbidden.' }
    if ((Get-Item -LiteralPath $path -Force).Length -gt 32KB -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CampaignManifestSha256) { throw 'Dry Bean marker length/SHA mismatch.' }
    $marker=Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 12
    $expected=[ordered]@{
        corpus_profile=$profile.Name; source_condition=$profile.Name; source_provenance=$profile.Provenance
        input_zip_path=$profile.InputZipPath; input_zip_bytes=$profile.ZipBytes; input_zip_sha256=$profile.ZipSha256
        input_files=$profile.Files; input_bytes=$profile.Bytes; input_manifest_sha256=$profile.ManifestSha256
        input_entry_prefix=$profile.EntryPrefix; input_entries=@([ordered]@{name=$profile.Entries[0].name;bytes=$profile.Entries[0].bytes;sha256=$profile.Entries[0].sha256})
        input_role='holdout-only'; holdout_only=$true; development_only=$false; training_allowed=$false; tuning_allowed=$false
        single_family_screen_only=$true; aggregate_category_count=0; general_superiority_claimed=$false; final_goal_achieved=$false
        khc_source_manifest_sha256=$profile.KhcSourceManifestSha256
    }
    foreach ($key in $expected.Keys) {
        if (-not $marker.Contains($key)) { throw "Missing Dry Bean admission field: $key" }
        Assert-KhcDryBeanMetadata -Actual $marker[$key] -Expected $expected[$key]
    }
    $lock=Assert-KhcPlainPath (Join-Path $profile.MetadataDirectory 'acquisition-lock.md')
    if ((Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash.ToLowerInvariant() -cne $profile.Provenance.acquisition_lock_sha256) { throw 'Dry Bean acquisition/rights lock SHA mismatch.' }
}

function Assert-KhcDryBeanHoldoutCampaign {
    param([Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    Assert-KhcPortfolioCampaign -CorpusProfile 'UciDryBeanHoldout20261020' @PSBoundParameters
}

function Assert-KhcPortfolioCampaign {
    param([Parameter(Mandatory)][ValidateSet('AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')][string]$CorpusProfile,
        [Parameter(Mandatory)][string]$CampaignManifestSha256, [switch]$RequireOpenWindow, [string]$ExpectedTaskId)
    if ([IO.Path]::GetFullPath($PSScriptRoot) -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc' -or
        [IO.Path]::GetFullPath($script:ProjectRoot) -cne 'D:\Dev\UnLhaRe\UnLhaRe') { throw 'Fixed portfolio profile requires the fixed working source/script roots.' }
    if ($CampaignManifestSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Fixed portfolio profile requires the SHA-256 of its separate immutable campaign-start.json.' }
    $profile=Get-KhcPortfolioInputProfile $CorpusProfile
    if ($profile.Name -ceq 'UciDryBeanHoldout20261020') { Assert-KhcDryBeanMetadataGate -CampaignManifestSha256 $CampaignManifestSha256 }
    if ($profile.Name -ceq 'LivedoorNews2012Holdout20261020') { $null=Assert-KhcPortfolioInput -CorpusProfile $CorpusProfile -InputRecoveryZip (Join-Path $profile.Directory 'input.zip') }
    $path=Assert-KhcPlainPath (Join-Path $profile.Directory 'campaign-start.json')
    if ((Get-Item -LiteralPath $path -Force).Length -gt 32KB -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CampaignManifestSha256) { throw 'Fixed portfolio immutable start-marker length/SHA mismatch.' }
    $markerJson=Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $marker=ConvertFrom-Json -InputObject $markerJson -AsHashtable -Depth 12
    $activeTaskId=$script:TaskId
    if ($PSBoundParameters.ContainsKey('ExpectedTaskId')) { $activeTaskId=$ExpectedTaskId }
    if ([string]::IsNullOrWhiteSpace($activeTaskId) -or [string]$marker.task_id -cne $activeTaskId) {
        throw 'Fixed portfolio start-marker task ID does not match the execution task context.'
    }
    $cli=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe')
    $cliSha='3dd0e0503ed6ec11c90ad1ff9ee69b2e34c564f8710871ab182dd684f27b7b4b'
    $seven='C:\Program Files\7-Zip\7z.exe'
    $sevenSha='95fff19b73eff77c87c0d7bd32822e43fb90dd2932459f962eb532d8dfb6ba53'
    $sourceSha='0f549ab7f8c675b8ef241279d8ab29f90e9c7b7e32a5bc08c7effd0dc861c404'
    $cliBytes=2575360L
    $isCanterbury=($profile.Name -ceq 'CanterburyDevelopmentKcs1CountLength20261020')
    if ($isCanterbury) {
        $cliSha=$profile.CliSha256; $cliBytes=$profile.CliBytes; $sourceSha=$profile.SourceManifestSha256
        if ([string]$marker.input_role -cne 'development-only' -or
            $marker.development_only -isnot [bool] -or $marker.development_only -cne $true -or
            $marker.holdout_only -isnot [bool] -or $marker.holdout_only -cne $false -or
            $marker.training_allowed -isnot [bool] -or $marker.training_allowed -cne $true -or
            $marker.tuning_allowed -isnot [bool] -or $marker.tuning_allowed -cne $true -or
            $marker.general_superiority_claimed -isnot [bool] -or $marker.general_superiority_claimed -cne $false -or
            $marker.final_goal_achieved -isnot [bool] -or $marker.final_goal_achieved -cne $false -or
            [string]$marker.source_condition -cne $profile.Name -or
            [string]$marker.khc_source_manifest_sha256 -cne $profile.KhcSourceManifestSha256 -or
            [string]$marker.input_entry_prefix -cne $profile.EntryPrefix -or
            [int]$marker.khc_create_threads -ne 1 -or [int]$marker.khc_extract_workers -ne 4 -or
            [int]$marker.seven_zip_create_threads -ne 1 -or [int]$marker.seven_zip_extract_threads -ne 4 -or
            [string]$marker.seven_zip_create_options -cne '-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off' -or
            [string]$marker.seven_zip_extract_options -cne 'x -mmt=4' -or [int]$marker.max_size_percent_of_7zip -ne 95 -or
            [long]$marker.maximum_effective_dictionary_bytes -ne 64MB -or
            $marker.create_median_no_slower -isnot [bool] -or $marker.create_median_no_slower -cne $true -or
            $marker.extract_median_no_slower -isnot [bool] -or $marker.extract_median_no_slower -cne $true) { throw 'Canterbury KCS1 development-only marker role/source/comparison settings mismatch.' }
    }
    if ($profile.Name -ceq 'UciDryBeanHoldout20261020') {
        $cliSha=$profile.CliSha256; $cliBytes=$profile.CliBytes; $sourceSha=$profile.SourceManifestSha256
        $sourceZip=Assert-KhcPlainPath (Join-Path $profile.MetadataDirectory $profile.Provenance.source_archive_name)
        if ((Get-Item -LiteralPath $sourceZip -Force).Length -ne $profile.Provenance.source_archive_bytes -or
            (Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash.ToLowerInvariant() -cne $profile.Provenance.source_archive_sha256) { throw 'Dry Bean official source ZIP pin mismatch.' }
    }
    if ($profile.Name -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020') {
        $cliSha=$profile.CliSha256; $cliBytes=$profile.CliBytes; $sourceSha=$profile.SourceManifestSha256
        if ([string]$marker.source_condition -cne $profile.Name -or
            [string]$marker.khc_source_manifest_sha256 -cne $profile.KhcSourceManifestSha256 -or
            [string]$marker.input_entry_prefix -cne $profile.EntryPrefix -or
            $marker.general_superiority_claimed -isnot [bool] -or $marker.general_superiority_claimed -cne $false -or
            $marker.final_goal_achieved -isnot [bool] -or $marker.final_goal_achieved -cne $false) { throw 'NICT KCS1 holdout marker source/comparison claims mismatch.' }
    }
    if ($profile.Name -ceq 'AozoraDevelopment20261020') {
        if ($marker.development_only -isnot [bool] -or $marker.development_only -cne $true -or
            (@($marker.development_work_ids) -join ',') -cne '424,752' -or
            [string]$marker.candidate_manifest_sha256 -cne $profile.CandidateManifestSha256) { throw 'Aozora development-only marker role/selection mismatch.' }
    } elseif (-not $isCanterbury) {
        if ([string]$marker.input_role -cne 'holdout-only' -or
            $marker.holdout_only -isnot [bool] -or $marker.holdout_only -cne $true -or
            $marker.development_only -isnot [bool] -or $marker.development_only -cne $false -or
            $marker.training_allowed -isnot [bool] -or $marker.training_allowed -cne $false -or
            $marker.tuning_allowed -isnot [bool] -or $marker.tuning_allowed -cne $false -or
            [string]$marker.start_date -cne $profile.StartDate -or [string]$marker.end_date -cne $profile.EndDate -or
            (@($marker.fields) -join ',') -cne ($profile.Fields -join ',') -or
            [string]$marker.input_zip_compression -cne 'stored' -or
            [int]$marker.khc_create_threads -ne 1 -or [int]$marker.khc_extract_workers -ne 4 -or
            [int]$marker.seven_zip_create_threads -ne 1 -or [int]$marker.seven_zip_extract_threads -ne 4 -or
            [string]$marker.seven_zip_create_options -cne '-t7z -mx=9 -m0=lzma2:d=64m -mmt=1 -ms=on -mqs=off -mtm=off -mtc=off -mta=off' -or
            [string]$marker.seven_zip_extract_options -cne 'x -mmt=4' -or [int]$marker.max_size_percent_of_7zip -ne 95 -or
            [long]$marker.maximum_effective_dictionary_bytes -ne 64MB -or
            $marker.create_median_no_slower -isnot [bool] -or $marker.create_median_no_slower -cne $true -or
            $marker.extract_median_no_slower -isnot [bool] -or $marker.extract_median_no_slower -cne $true) { throw 'Independent holdout marker role/coverage/comparison settings mismatch.' }
        if ($profile.Name -cin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) {
            if ($profile.Name -cin @('NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) { Assert-KhcNictMetadata -Actual $marker.source_provenance -Expected $profile.Provenance }
            else { Assert-KhcLivedoorMetadata -Actual $marker.source_provenance -Expected $profile.Provenance }
            if ([long]$marker.listing_stdout_bytes -ne $profile.ListingOutputBytes -or [long]$marker.listing_stderr_bytes -ne 2KB) { throw 'Livedoor listing capture preregistration mismatch.' }
        }
        if ($profile.Name -ceq 'TokyoResidentRegister202101Holdout20261020') {
            $licenseVersionPresent = $marker -is [System.Collections.IDictionary] -and $marker.Contains('source_license_version')
            $licenseVersionMatches = if ($null -eq $profile.SourceLicenseVersion) { $licenseVersionPresent -and $null -eq $marker.source_license_version } else { $licenseVersionPresent -and [string]$marker.source_license_version -ceq $profile.SourceLicenseVersion }
            if ([string]$marker.source_page -cne $profile.SourcePage -or
                [string]$marker.source_catalog_page -cne $profile.SourceCatalogPage -or
                [string]$marker.source_direct_csv_url -cne $profile.SourceDirectCsvUrl -or
                [string]$marker.source_attribution -cne $profile.SourceAttribution -or
                [string]$marker.source_license_label -cne $profile.SourceLicenseLabel -or
                -not $licenseVersionMatches -or
                [string]$marker.source_license_note -cne $profile.SourceLicenseNote -or
                [string]$marker.source_content_handling -cne $profile.SourceContentHandling) {
                throw 'Tokyo resident-register holdout source/attribution/license marker mismatch.'
            }
        }
    }
    if ($marker.schema -ne 1 -or [string]$marker.campaign_id -cnotmatch '^[0-9a-f]{32}$' -or
        [string]$marker.task_id -cne 'goal-restore-20261019' -or [string]$marker.corpus_profile -cne $profile.Name -or
        $marker.holdout_evaluated -isnot [bool] -or $marker.holdout_evaluated -cne $false -or
        [string]$marker.source_family -cne $profile.SourceFamily -or [int]$marker.source_family_count -ne 1 -or
        [string]$marker.input_zip_path -cne (Get-KhcPortfolioInputZipPath $profile) -or
        [long]$marker.input_zip_bytes -ne $profile.ZipBytes -or [string]$marker.input_zip_sha256 -cne $profile.ZipSha256 -or
        [int]$marker.input_files -ne $profile.Files -or [long]$marker.input_bytes -ne $profile.Bytes -or
        [string]$marker.input_manifest_sha256 -cne $profile.ManifestSha256 -or
        [string]$marker.cli_path -cne $cli -or [string]$marker.cli_sha256 -cne $cliSha -or
        [string]$marker.seven_zip_path -cne $seven -or [string]$marker.seven_zip_sha256 -cne $sevenSha -or
        [string]$marker.source_manifest_sha256 -cne $sourceSha -or
        [int]$marker.run_count -ne 20 -or [long]$marker.run_bytes -ne 32MB -or [int]$marker.run_entries -ne 512 -or
        [int]$marker.per_run_timeout_seconds -ne 300 -or [int]$marker.campaign_wall_seconds -ne 1800 -or
        [int]$marker.command_timeout_seconds -ne 60 -or [long]$marker.process_memory_bytes -ne 160MB -or
        [int]$marker.cpu_gate_max_percent -ne 15 -or
        [string]$marker.schedule -cne 'round 0 warmup; rounds 1-9 measured; alternate starting strategy by round parity') { throw 'Fixed portfolio start-marker profile/candidate/pins/schedule/caps mismatch.' }
    # ConvertFrom-JsonのDateTime自動変換でoffsetを失わないよう、元のJSON文字列を照合する。
    $timestamps=@(); $document=[Text.Json.JsonDocument]::Parse($markerJson)
    try {
        foreach ($field in @('started_utc','deadline_utc')) {
            $value=$document.RootElement.GetProperty($field).GetString()
            if ($value -notmatch '(?:Z|\+00:00)$') { throw 'Fixed portfolio campaign timestamps require explicit UTC.' }
            $date=[DateTimeOffset]::Parse($value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
            if ($date.Offset.Ticks -ne 0) { throw 'Fixed portfolio campaign timestamps must be UTC.' }
            $timestamps+=@($date)
        }
    } finally { $document.Dispose() }
    if ($timestamps[1] -ne $timestamps[0].AddSeconds(1800)) { throw 'Fixed portfolio campaign deadline must be exactly 1800 seconds after its start.' }
    $now=[DateTimeOffset]::UtcNow
    if ($RequireOpenWindow -and ($now -lt $timestamps[0] -or $now -ge $timestamps[1])) { throw 'Fixed portfolio campaign registration/sample is outside its immutable time window.' }
    $markerEntries=@(if ($profile.Name -cnotin @('LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020')) { $profile.Entries })
    if (@($marker.input_entries).Count -ne $markerEntries.Count) { throw 'Fixed portfolio start-marker member count mismatch.' }
    for ($i=0; $i -lt $markerEntries.Count; $i++) {
        $actual=$marker.input_entries[$i]; $expected=$markerEntries[$i]
        if ([string]$actual.name -cne $expected.name -or [long]$actual.bytes -ne $expected.bytes -or [string]$actual.sha256 -cne $expected.sha256) { throw 'Fixed portfolio start-marker member name/length/SHA mismatch.' }
    }
    foreach ($pin in @(
        @{path=$cli;sha=$cliSha}, @{path=$seven;sha=$sevenSha},
        @{path=(Join-Path $PSScriptRoot 'portfolio-7zip-product-screen.ps1');sha=[string]$marker.worker_sha256},
        @{path=(Join-Path $PSScriptRoot 'run-storage-experiment.ps1');sha=[string]$marker.runner_sha256},
        @{path=(Join-Path $PSScriptRoot 'storage-lifecycle.psm1');sha=[string]$marker.lifecycle_sha256},
        @{path=(Join-Path $PSScriptRoot 'disk-budget.ps1');sha='506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd'},
        @{path=(Join-Path $script:ProjectRoot 'Cargo.toml');sha='3b47e50b8e543a5af82617bee4d4bd48ec20fc795a333ba50cbc9e439e0c2fac'},
        @{path=(Join-Path $script:ProjectRoot 'Cargo.lock');sha='d8dab69b03805b559440c186ed04c2d0d0ee57eba922306cfa6827bf79985554'}
    )) {
        $pinPath=Assert-KhcPlainPath $pin.path
        if ($pin.sha -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $pinPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pin.sha) { throw "Fixed portfolio live source/tool/script pin mismatch: $pinPath" }
    }
    if ($isCanterbury -or $profile.Name -cin @('JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) {
        $aggregatorPath=Assert-KhcPlainPath (Join-Path $PSScriptRoot 'aggregate-portfolio-7zip-product-screen.ps1')
        if ([string]$marker.aggregator_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-FileHash -LiteralPath $aggregatorPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne [string]$marker.aggregator_sha256) { throw 'JMA holdout aggregator script pin mismatch.' }
    }
    if ([string]$marker.disk_budget_sha256 -cne '506e4c68dc05734bc1a0c02bac6f81d4677e0bcffd9b9fa2b7bd67d53319bdcd' -or (Get-Item -LiteralPath $cli).Length -ne $cliBytes) { throw 'Fixed portfolio candidate/tool size or disk-budget pin mismatch.' }
    $root=Assert-KhcPlainPath (Join-Path $script:ProjectRoot 'src')
    $paths=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Fixed portfolio source manifest rejects reparse points.' }
        if (-not $item.PSIsContainer -and $item.Extension -ceq '.rs') { $paths.Add([IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/'),$item.FullName) }
    }
    $names=[string[]]$paths.Keys; [Array]::Sort($names,[StringComparer]::Ordinal)
    $builder=[Text.StringBuilder]::new()
    foreach ($name in $names) {
        $file=$paths[$name]; $length=(Get-Item -LiteralPath $file -Force).Length
        $hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $null=$builder.Append($name).Append([char]9).Append($length).Append([char]9).Append($hash).Append([char]10)
    }
    $actualSourceSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($builder.ToString()))).ToLowerInvariant()
    if ($actualSourceSha -cne $sourceSha) { throw 'Fixed portfolio current Rust source manifest mismatch.' }
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($seven)
    if ($version.FileMajorPart -ne 26 -or $version.FileMinorPart -ne 4 -or $version.FileBuildPart -ne 0 -or $version.FilePrivatePart -ne 0) { throw 'Fixed portfolio profile requires pinned 7-Zip 26.04.' }
    $null=Assert-KhcPortfolioInput -CorpusProfile $profile.Name -InputRecoveryZip (Get-KhcPortfolioInputZipPath $profile) -CampaignManifestSha256 $CampaignManifestSha256
    return $marker
}

function Get-KhcTreeUsage {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $path = Assert-KhcPlainPath $LiteralPath
    if (-not (Test-Path -LiteralPath $path)) { return 0L }
    if (-not [IO.Directory]::Exists($path)) { throw "フォルダーではありません: $path" }
    return [Khc.Storage.TreeCounter]::Bytes($path)
}

# 関数名は旧Dドライブ固定運用時代のまま残す（test-storage-recycle-v6.ps1 などが同名でmockするため）。
# 現在は「ユーザー既定TEMP\UnLhaRe」配下の基点を検査する。基点のドライブが利用可能であること、
# ドライブrootと基点フォルダー群がreparse pointでないことを確認し、基点フォルダーが無ければ作成する
# （TEMP配下は初回に存在しないのが普通なので、旧運用の「事前に存在しなければ停止」はやめた）。
function Assert-KhcDStorageBase {
    $storageRoot = (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe')
    $driveRoot = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($storageRoot))
    $drive = [IO.DriveInfo]::new($driveRoot)
    if (-not $drive.IsReady) { throw "KHC storage requires an available drive for the TEMP base: $driveRoot" }
    $driveItem = Get-Item -LiteralPath $driveRoot -Force -ErrorAction Stop
    if ($driveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "KHC storage drive root cannot be a reparse point: $driveRoot" }
    foreach ($root in @($storageRoot,(Join-Path $storageRoot 'work'),(Join-Path $storageRoot 'TaskArtifacts'))) {
        # 作成前にも祖先のreparse pointを拒否してから作る。
        $path = Assert-KhcPlainPath $root
        if (-not [IO.Directory]::Exists($path)) { $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop }
        $path = Assert-KhcPlainPath $root
        if (-not [IO.Directory]::Exists($path)) { throw "KHC storage parent directory is unavailable: $path" }
    }
    return $drive
}

function Get-KhcStorageTaskPaths {
    param([switch]$Create)
    if (-not $script:TaskId -or $script:TaskId -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Set KHC_STORAGE_TASK_ID to a lowercase task slug before creating a new experiment or Cargo output.' }
    $null = Assert-KhcDStorageBase
    $expectedTaskRoot = [IO.Path]::GetFullPath((Join-Path $script:WorkspaceBase $script:TaskId))
    $expectedKeepRoot = [IO.Path]::GetFullPath((Join-Path $script:TaskArtifactsBase $script:TaskId))
    if ($expectedTaskRoot -ine $script:TaskRoot -or $expectedKeepRoot -ine $script:KeepRoot) { throw 'KHC task roots do not match the validated task slug.' }
    foreach ($path in @($script:TaskRoot,$script:TempRoot,$script:CargoTargetRoot,$script:KeepRoot,$script:StateRoot)) { $null = Assert-KhcPlainPath $path }
    if ($Create) {
        foreach ($path in @($script:TaskRoot,$script:TempRoot,$script:CargoTargetRoot,$script:KeepRoot)) {
            $null = New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop
            $checked = Assert-KhcPlainPath $path
            if (-not [IO.Directory]::Exists($checked)) { throw "KHC task directory could not be created: $checked" }
        }
    }
    [pscustomobject]@{
        TaskId = $script:TaskId
        TaskRoot = $script:TaskRoot
        WorkRoot = $script:TaskRoot
        TempRoot = $script:TempRoot
        CargoTargetRoot = $script:CargoTargetRoot
        KeepRoot = $script:KeepRoot
        StateRoot = $script:StateRoot
    }
}

function Initialize-KhcStorageTaskEnvironment {
    $null=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $null=Get-KhcRecycleV6Charges
    $paths = Get-KhcStorageTaskPaths -Create
    $env:KHC_STORAGE_TASK_ID = $paths.TaskId
    $env:TEMP = $paths.TempRoot
    $env:TMP = $paths.TempRoot
    $env:TMPDIR = $paths.TempRoot
    $env:CARGO_TARGET_DIR = $paths.CargoTargetRoot
    $env:CARGO_BUILD_TARGET_DIR = $paths.CargoTargetRoot
    $env:CARGO_BUILD_BUILD_DIR = $paths.CargoTargetRoot
    $env:CARGO_INCREMENTAL = '0'
    return $paths
}

function Get-KhcLegacyTempRoot {
    Assert-KhcPlainPath $script:LegacyTempRoot
}

function Assert-KhcStorageTaskWorkDirectory {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $paths = Get-KhcStorageTaskPaths
    $work = Assert-KhcPlainPath $LiteralPath
    if ([IO.Path]::GetDirectoryName($work) -ine $paths.WorkRoot -or $work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or $work.Length -gt 200) {
        throw 'WorkDirectory must be a new run-GUID directly under the validated TEMP-based task workspace.'
    }
    return $work
}

function Get-KhcTaskWorkspaceRoots {
    $null = Assert-KhcDStorageBase
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $script:WorkspaceBase -Directory -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "KHC workspace task root is a reparse point: $($item.FullName)" }
        $roots.Add((Assert-KhcPlainPath $item.FullName))
    }
    return @($roots.ToArray())
}

function Get-KhcTaskCargoBytes {
    $bytes = [long]0
    foreach ($root in Get-KhcTaskWorkspaceRoots) { $bytes += [long](Get-KhcTreeUsage (Join-Path $root 'cargo')) }
    return $bytes
}

function Get-KhcLifecycleStateRoots {
    $null = Assert-KhcDStorageBase
    $roots = [Collections.Generic.List[string]]::new()
    foreach ($base in @($script:LegacyKeepRoot,$script:TaskArtifactsBase)) {
        $checkedBase = Assert-KhcPlainPath $base
        if (-not [IO.Directory]::Exists($checkedBase)) { continue }
        $central = Join-Path $checkedBase 'storage-lifecycle'
        if ([IO.Directory]::Exists($central)) { $roots.Add((Assert-KhcPlainPath $central)) }
        foreach ($taskRoot in Get-ChildItem -LiteralPath $checkedBase -Directory -Force -ErrorAction Stop) {
            if ($taskRoot.Name -ieq 'storage-lifecycle') { continue }
            if ($taskRoot.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "KHC task artifact root is a reparse point: $($taskRoot.FullName)" }
            $state = Join-Path $taskRoot.FullName 'storage-lifecycle'
            if ([IO.Directory]::Exists($state)) { $roots.Add((Assert-KhcPlainPath $state)) }
        }
    }
    return @($roots.ToArray() | Sort-Object -Unique)
}

function Get-KhcLifecycleUsage {
    $bytes = [long]0
    foreach ($root in Get-KhcLifecycleStateRoots) { $bytes += [long](Get-KhcTreeUsage $root) }
    return $bytes
}

function Assert-KhcNoPendingStorageRuns {
    param([string]$AllowedRecordPath,[switch]$AllowInactiveOwner)
    $allowed = $null
    if ($AllowedRecordPath) { $allowed = Assert-KhcPlainPath $AllowedRecordPath }
    foreach ($state in Get-KhcLifecycleStateRoots) {
        $runs = Join-Path $state 'runs'
        if (-not [IO.Directory]::Exists($runs)) { continue }
        foreach ($run in Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop) {
            if ($run.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "KHC run record is a reparse point: $($run.FullName)" }
            $null=Get-KhcRecycleV6RunProtocol $state $run.Name
            if (Test-Path -LiteralPath (Join-Path $run.FullName 'complete.json') -PathType Leaf) { continue }
            $recordPath = Assert-KhcPlainPath (Join-Path $run.FullName 'run.json')
            if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw "Incomplete KHC run has no owner record: $($run.FullName)" }
            if ($allowed -and $recordPath -ieq $allowed) {
                if (-not $AllowInactiveOwner) {
                    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    Assert-KhcStorageContext -WorkDirectory ([string]$record.work_directory)
                }
                continue
            }
            throw "An unfinished KHC experiment or cleanup blocks new storage work: $($run.FullName)"
        }
    }
}

function Get-KhcRunUsage {
    param([Parameter(Mandatory)][string]$LiteralPath,[ValidateRange(1,4096)][int]$MaxEntries=4096)
    $path=Assert-KhcPlainPath $LiteralPath
    if(-not(Test-Path -LiteralPath $path)){return 0L}
    return [Khc.Storage.TreeCounter]::Measure($path,$MaxEntries,512).Bytes
}

function Get-KhcProductPipelineEntryBudget {
    # examples/khc_pipeline_e2e.rs と product-pipeline-e2e.ps1 の固定Canterbury11出力計画。
    # max_entriesはwork rootを除く子孫数。復元inventoryはさらに「.」を1件含む。
    $sourceFileCount = 11
    $malformedLabels = @('header','manifest','first-frame','end','trailing','truncated-header','truncated-last-crc','truncated-frame')
    $fileCrcIndices = @(0,5,10)
    $prefixFilesPerStream = 0
    foreach ($index in $fileCrcIndices) {
        if ($index -lt 0 -or $index -ge $sourceFileCount) { throw 'Canterbury11のfile-CRC出力計画が不正です。' }
        $prefixFilesPerStream += $index
    }
    $stable = [ordered]@{
        wrapperFiles = 2 + 2 * 2 # archive/report + 2 processのstdout/stderr
        e2eRoot = 1
        canterburyRestore = 1 + $sourceFileCount # 展開先directory + 固定Canterbury files
        malformedArchives = $malformedLabels.Count
        fileCrcArchives = $fileCrcIndices.Count
        fileCrcOutputDirectories = 2 * $fileCrcIndices.Count
        fileCrcPublishedPrefixFiles = 2 * $prefixFilesPerStream
        boundarySourceTree = 1 + 2 + 3 # root + directories + files
        boundaryArchive = 1
        boundaryRestoreTree = 1 + 2 + 3 # root + directories + files
    }
    $stableTreeEntries = 0
    foreach ($count in $stable.Values) { $stableTreeEntries += [int]$count }
    # KHCの一時公開は1つずつ進み、同時にTempDirとそのcontent fileが存在し得る。
    $transientStagingEntries = 2
    [pscustomobject]@{
        StableTreeEntries = $stableTreeEntries
        TransientStagingEntries = $transientStagingEntries
        RequiredTreeEntries = $stableTreeEntries + $transientStagingEntries
        StableInventoryEntries = $stableTreeEntries + 1
        RequiredInventoryEntries = $stableTreeEntries + $transientStagingEntries + 1
        Breakdown = $stable
    }
}

function Resolve-KhcRetirementRetention {
    param([Parameter(Mandatory)][object]$Record,[Parameter(Mandatory)][string]$AllowedKeepRoot)
    $fields = @('schema','archive_path','bytes','sha256','last_write_utc_ticks')
    if ($Record -isnot [pscustomobject] -or @($Record.PSObject.Properties).Count -ne $fields.Count) { throw '固定保管台帳はschema 1の単一オブジェクトに限定します。' }
    foreach ($field in $fields) { if ($null -eq $Record.PSObject.Properties[$field]) { throw "固定保管台帳の必須項目がありません: $field" } }
    if ($Record.schema -isnot [long] -and $Record.schema -isnot [int]) { throw '固定保管schemaは整数に限定します。' }
    if ($Record.schema -ne 1 -or $Record.archive_path -isnot [string] -or $Record.sha256 -isnot [string] -or $Record.sha256 -cnotmatch '^[0-9a-fA-F]{64}$') { throw '固定保管台帳のschema/path/SHA-256が不正です。' }
    foreach ($field in @('bytes','last_write_utc_ticks')) { if ($Record.$field -isnot [long] -and $Record.$field -isnot [int]) { throw "固定保管台帳の$field は整数に限定します。" } }
    if ($Record.bytes -le 0 -or $Record.bytes -gt 12GB -or $Record.last_write_utc_ticks -le 0 -or $Record.last_write_utc_ticks -gt [DateTime]::MaxValue.Ticks) { throw '固定保管台帳の容量/更新時刻が範囲外です。' }
    $path = Assert-KhcPlainPath $Record.archive_path
    $keep = Assert-KhcPlainPath $AllowedKeepRoot
    $pattern = '^' + [regex]::Escape($keep) + '\\build-retirement-[a-zA-Z0-9-]+\\build-snapshot\.zip$'
    if ($path -ine $Record.archive_path -or $path -notmatch $pattern) { throw '固定保管は登録root直下のbuild-retirement-*/build-snapshot.zipの正規絶対パスだけに限定します。' }
    if (-not (Test-Path -LiteralPath $path)) { return 0L }
    $item = Get-Item -LiteralPath $path -Force
    if ($item -isnot [IO.FileInfo] -or $item.Length -ne $Record.bytes -or $item.LastWriteTimeUtc.Ticks -ne $Record.last_write_utc_ticks) { throw '固定保管ZIPが登録時の容量/更新時刻と一致しません。' }
    return [long]$item.Length
}

function Get-KhcRetirementRetentionBytes {
    $keepRoots = [Collections.Generic.List[string]]::new()
    foreach ($base in @($script:LegacyKeepRoot,$script:TaskArtifactsBase)) {
        $root = Assert-KhcPlainPath $base
        if (-not [IO.Directory]::Exists($root)) { continue }
        $keepRoots.Add($root)
        foreach ($child in Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "固定保管rootにreparse pointがあります: $($child.FullName)" }
            $keepRoots.Add((Assert-KhcPlainPath $child.FullName))
        }
    }
    $registrations = [Collections.Generic.List[object]]::new()
    foreach ($keepRoot in @($keepRoots.ToArray() | Sort-Object -Unique)) {
        $path = Assert-KhcPlainPath (Join-Path $keepRoot 'build-retirement-retention.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $stream = [IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try {
            if ($stream.Length -gt 32KB) { throw '固定保管台帳は32KiB以下に限定します。' }
            $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$false,1024,$true)
            try { $record = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $registrations.Add([pscustomobject]@{Record=$record;KeepRoot=$keepRoot})
    }
    if ($registrations.Count -gt 1) { throw '固定保管登録が複数rootに存在します。既存登録を統合するまで容量判定を停止します。' }
    if ($registrations.Count -eq 0) { return 0L }
    $registration = $registrations[0]
    return Resolve-KhcRetirementRetention $registration.Record $registration.KeepRoot
}

function Get-KhcRecycleV6AnchorRoot {
    # この既存taskのbootstrapは利用者が一度だけ明示実行する。通常経路は再作成しない。
    (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\storage-lifecycle\recycle-v6')
}

function Assert-KhcRecycleV6ProtocolData {
    param([bool]$HasReserve,[bool]$HasRequestAnchor,[bool]$HasFinal,[bool]$HasMarker,[int]$RequestSchema,[bool]$HasPublicRequest,[bool]$HasComplete)
    if(-not $HasReserve){
        if($HasRequestAnchor -or $HasFinal -or $HasMarker -or ($HasPublicRequest -and $RequestSchema -ne 1)){throw 'Recycle-v6 evidence cannot be classified as legacy without its private reservation.'}
        return 1
    }
    if(-not $HasMarker){throw 'Private recycle-v6 registration lost its public marker; downgrade prohibited.'}
    if($HasRequestAnchor -ne $HasPublicRequest -or ($HasPublicRequest -and $RequestSchema -ne 2)){throw 'Private recycle-v6 request cannot be missing, partial, or downgraded.'}
    if($HasFinal -and -not $HasRequestAnchor){throw 'Private recycle-v6 final has no request binding.'}
    if($HasComplete -and -not $HasFinal){throw 'Public complete.json is not completion authority without a private final.'}
    return 6
}

function Get-KhcRecycleV6RunProtocol {
    param([string]$State,[string]$RunId)
    $state=Assert-KhcPlainPath $State
    $mandatory=Get-KhcRecycleV6AnchorRoot
    if($state -ieq [IO.Path]::GetDirectoryName($mandatory)){$null=Assert-KhcRecycleV6PrivatePath $mandatory -ProtectedRoot}
    $root=Assert-KhcPlainPath (Join-Path $state 'recycle-v6')
    $directory=Assert-KhcPlainPath (Join-Path (Join-Path $state 'runs') $RunId)
    $hasReserve=Test-Path -LiteralPath (Join-Path $root "$RunId.reserve.json")
    $hasRequestAnchor=Test-Path -LiteralPath (Join-Path $root "$RunId.request.json")
    $hasFinal=Test-Path -LiteralPath (Join-Path $root "$RunId.final.json")
    $hasMarker=Test-Path -LiteralPath (Join-Path $directory 'recycle-v6.json')
    $requestPath=Assert-KhcPlainPath (Join-Path $directory 'cleanup-request.json')
    $hasRequest=Test-Path -LiteralPath $requestPath
    $hasComplete=Test-Path -LiteralPath (Join-Path $directory 'complete.json')
    $schema=0
    if($hasRequest){$request=Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable;$schema=$request.schema}
    $protocol=Assert-KhcRecycleV6ProtocolData $hasReserve $hasRequestAnchor $hasFinal $hasMarker $schema $hasRequest $hasComplete
    if($protocol -eq 6){
        $null=Get-KhcRecycleV6RunAnchor $state $RunId
        if($hasRequest){$null=Get-KhcRecycleV6RunAnchor $state $RunId -Request}
        if($hasComplete){
            # Budgetには再入しない。private final→proof→public completeのhash拘束だけを検証する。
            $location=[pscustomobject]@{StateRoot=$state;Directory=$directory}
            $record=Get-Content -LiteralPath (Assert-KhcPlainPath (Join-Path $directory 'run.json')) -Raw | ConvertFrom-Json
            $request=Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json
            $complete=Get-Content -LiteralPath (Assert-KhcPlainPath (Join-Path $directory 'complete.json')) -Raw | ConvertFrom-Json
            $null=Test-KhcRecycleV6Completed $location $RunId $record $request $complete
        }
    }
    return $protocol
}

function Assert-KhcRecycleV6CapacityData {
    param([long]$PhysicalLifecycleBytes,[long]$ExistingChargeBytes,[long]$NewPersistentBytes,[long]$ZipMaximumBytes,[long]$PhysicalMetadataMarginBytes)
    $sum=[decimal]0
    foreach($n in @($PhysicalLifecycleBytes,$ExistingChargeBytes,$NewPersistentBytes,$ZipMaximumBytes,$PhysicalMetadataMarginBytes)){if($n -lt 0){throw 'Negative recycle-v6 lifecycle reservation.'};$sum+=[decimal]$n}
    if($sum -gt 1GB){throw 'Simultaneous lifecycle tree, persistent charges, recovery ZIP, and physical metadata margin exceed 1GiB.'}
}

function Get-KhcRecycleV6Hash {
    param([string]$Path)
    $path=Assert-KhcPlainPath $Path
    (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Assert-KhcRecycleV6PrivatePath {
    param([string]$Path,[switch]$ProtectedRoot)
    $path=Assert-KhcPlainPath $Path
    if(-not (Test-Path -LiteralPath $path)){throw "Required private recycle-v6 path is missing; no automatic bootstrap: $path"}
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted=@($sid,'S-1-5-18','S-1-5-32-544')
    $acl=Get-Acl -LiteralPath $path -ErrorAction Stop
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid){throw "Private recycle-v6 owner mismatch: $path"}
    if($ProtectedRoot -and -not $acl.AreAccessRulesProtected){throw 'Recycle-v6 trust root must have a protected DACL.'}
    $writeMask=[long]([Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership) -bor 0x50000000L
    foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($ace.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ([long]$ace.FileSystemRights -band $writeMask) -ne 0 -and $ace.IdentityReference.Value -cnotin $trusted){throw "Untrusted writer on private recycle-v6 path: $path"}
    }
    return $path
}

function Assert-KhcRecycleV6Installed {
    $exe='C:\Users\IMT\.local\Prunlet\bin\prunlet.exe'
    $config='C:\Users\IMT\.local\Prunlet\config.json'
    if((Get-Item -LiteralPath (Assert-KhcPlainPath $exe)).Length -ne 73983687L -or (Get-KhcRecycleV6Hash $exe) -cne 'af232d1e356faf027266d5569b651b01babdb624503a79bf4403384a3693ffc3' -or (Get-KhcRecycleV6Hash $config) -cne 'd0d38615274ab7a562a42df1544967d7d2aab7d3ad93965f02bac0b50b148765'){throw 'Installed Prunlet executable/config differs from the reviewed schema6 probe.'}
    $data=Get-Content -LiteralPath $config -Raw | ConvertFrom-Json -AsHashtable
    if($data.backupDirectory -cne 'C:\Users\IMT\.local\Prunlet\recovery'){throw 'Prunlet metadata root mismatch.'}
    [ordered]@{exe_sha256='af232d1e356faf027266d5569b651b01babdb624503a79bf4403384a3693ffc3';config_sha256='d0d38615274ab7a562a42df1544967d7d2aab7d3ad93965f02bac0b50b148765';metadata_root=$data.backupDirectory}
}

function Assert-KhcRecycleV6BootstrapCapacity {
    # root不在を許す唯一の経路。正常Budgetへのbypass引数は設けない。
    # 既存private台帳が一つでもある場合は再bootstrapとして拒否する。
    $null=Assert-KhcDStorageBase
    foreach($state in Get-KhcLifecycleStateRoots){if(Test-Path -LiteralPath (Join-Path $state 'recycle-v6')){throw 'Existing recycle-v6 accounting prevents bootstrap.'}}
    foreach($state in Get-KhcLifecycleStateRoots){
        $runs=Assert-KhcPlainPath (Join-Path $state 'runs')
        if(-not [IO.Directory]::Exists($runs)){continue}
        foreach($run in Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop){
            $directory=Assert-KhcPlainPath $run.FullName
            if(-not (Test-Path -LiteralPath (Join-Path $directory 'complete.json') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $directory 'recycle-v6.json'))){throw 'Pending or schema6 run prevents initial bootstrap.'}
            $request=Get-Content -LiteralPath (Assert-KhcPlainPath (Join-Path $directory 'cleanup-request.json')) -Raw | ConvertFrom-Json -AsHashtable
            if($request.schema -ne 1){throw 'Only historical schema1 completion is admissible before initial bootstrap.'}
        }
    }
    $own=Assert-KhcRecycleV6PrivatePath 'C:\Users\IMT\.local\Prunlet\recovery\59325e63acad49cdb791e61fd03ebaf1'
    $probeCharge=[Math]::Max(1MB,[long](Get-KhcTreeUsage $own))
    $recordsMargin=1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) 0 $probeCharge 0 $recordsMargin
    $build=Get-KhcTreeUsage (Join-Path $script:ProjectRoot 'build')
    $temp=(Get-KhcTreeUsage $script:LegacyTempRoot)+(Get-KhcTreeUsage $script:WorkspaceBase)
    $keep=(Get-KhcTreeUsage $script:LegacyKeepRoot)+(Get-KhcTreeUsage $script:TaskArtifactsBase)
    $taskCargo=Get-KhcTaskCargoBytes
    $cargo=(Get-KhcTreeUsage (Join-Path $script:ProjectRoot 'build/cargo'))+$taskCargo
    $archive=Get-KhcRetirementRetentionBytes
    if($archive -gt $keep){throw 'Bootstrap fixed archive accounting mismatch.'}
    $ordinary=$temp+$keep-$taskCargo-$archive
    if($ordinary -lt 0 -or $ordinary+$probeCharge+$recordsMargin -gt 2GB -or $build+$temp+$keep+$probeCharge+$recordsMargin -gt 30GB -or $cargo -gt 6GB){throw 'Bootstrap cannot reserve probe charge and records within fixed storage caps.'}
    # 空き容量は作業・保全の基点（ユーザー既定TEMP\UnLhaRe）があるドライブで測る。
    if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot((Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe')))).AvailableFreeSpace -lt 5GB+$recordsMargin){throw 'Bootstrap lacks fixed free space and record margin.'}
}

function Initialize-KhcRecycleV6TrustAnchor {
    # 明示的bootstrap専用。既存rootの修復・置換・予約の消去はしない。
    $root=Assert-KhcPlainPath (Get-KhcRecycleV6AnchorRoot)
    if(Test-Path -LiteralPath $root){throw 'Recycle-v6 anchor already exists; refuse to initialize or repair it.'}
    $state=Assert-KhcPlainPath ([IO.Path]::GetDirectoryName($root))
    if(-not [IO.Directory]::Exists($state)){throw 'Existing task StateRoot is required for explicit bootstrap.'}
    $null=Assert-KhcRecycleV6Installed
    $probe=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\schema6-cleanup-20261026\probe-contract.json')
    if((Get-KhcRecycleV6Hash $probe) -cne '78c8b3aa78e3baf6ea482bb6edc6119cd2aaf10dd2cbe783c4e37ac3296f3519'){throw 'Probe contract changed.'}
    $registrationLease=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        if(Test-Path -LiteralPath $root){throw 'Recycle-v6 bootstrap race.'}
        Assert-KhcRecycleV6BootstrapCapacity
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
        foreach($trusted in @($sid.Value,'S-1-5-18','S-1-5-32-544')){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($trusted),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
        }
        [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($root),$acl)
        $null=Assert-KhcRecycleV6PrivatePath $root -ProtectedRoot
        Write-KhcNewJson (Join-Path $root 'probe.json') ([ordered]@{schema=1;protocol='prunlet-recycle-v6-probe';operation_id='59325e63acad49cdb791e61fd03ebaf1';contract_path=$probe;contract_sha256=(Get-KhcRecycleV6Hash $probe);payload_bytes=0L;metadata_bytes=1MB})
        [pscustomobject]@{State='initialized';AnchorRoot=$root;ProbeMetadataChargeBytes=1MB}
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Assert-KhcRecycleV6ReservationData {
    param([Collections.IDictionary]$Anchor,[string]$RunId,[string]$RegistrationSha256)
    foreach($field in @('schema','max_bytes','max_entries','payload_bytes','metadata_bytes')){if($Anchor[$field] -isnot [int] -and $Anchor[$field] -isnot [long]){throw 'Recycle-v6 reservation requires integer bounds.'}}
    if($Anchor.schema -ne 1 -or $Anchor.protocol -cne 'prunlet-recycle-v6' -or $Anchor.run_id -cne $RunId -or $Anchor.registration_sha256 -cne $RegistrationSha256 -or $RegistrationSha256 -cnotmatch '^[0-9a-f]{64}$'){throw 'Recycle-v6 reservation schema/registration mismatch.'}
    $expected=Get-KhcRecycleV6Reservation $Anchor.max_bytes $Anchor.max_entries
    if($Anchor.payload_bytes -ne $expected.payload_bytes -or $Anchor.metadata_bytes -ne $expected.metadata_bytes){throw 'Recycle-v6 reservation was lowered or corrupted.'}
    if($Anchor.Contains('remote_native_e2e_required') -or $Anchor.Contains('remote_native_e2e_protocol_sha256')){if($Anchor.remote_native_e2e_required -isnot [bool] -or -not $Anchor.remote_native_e2e_required -or [string]$Anchor.remote_native_e2e_protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Remote native reservation binding is corrupted.'}}
    if($Anchor.Contains('remote_reference_required') -or $Anchor.Contains('remote_reference_protocol_sha256')){if($Anchor.remote_reference_required -isnot [bool] -or -not $Anchor.remote_reference_required -or [string]$Anchor.remote_reference_protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Remote reference reservation binding is corrupted.'}}
    if($Anchor.Contains('remote_candidate_e2e_required') -or $Anchor.Contains('remote_candidate_e2e_protocol_sha256')){if($Anchor.remote_candidate_e2e_required -isnot [bool] -or -not $Anchor.remote_candidate_e2e_required -or $Anchor.remote_candidate_e2e_protocol_sha256 -isnot [string] -or $Anchor.remote_candidate_e2e_protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Remote candidate E2E reserve binding is corrupted.'}}
    $null=Assert-KhcRemoteReferenceClassData ($Anchor.Contains('remote_native_e2e_required')) ($Anchor.Contains('remote_reference_required')) ($Anchor.Contains('remote_candidate_e2e_required'))
}

function Read-KhcRecycleV6PrivateJson {
    param([string]$Path)
    $path=Assert-KhcRecycleV6PrivatePath $Path
    if((Get-Item -LiteralPath $path).Length -gt 4MB){throw 'Private recycle-v6 record exceeds 4MiB.'}
    $value=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if($value -isnot [Collections.IDictionary]){throw 'Private recycle-v6 record must be an object.'}
    return $value
}

function Get-KhcRecycleV6RunAnchor {
    param([string]$State,[string]$RunId,[switch]$Request)
    $root=Assert-KhcRecycleV6PrivatePath (Join-Path $State 'recycle-v6') -ProtectedRoot
    $reservation=Read-KhcRecycleV6PrivateJson (Join-Path $root "$RunId.reserve.json")
    $recordPath=Assert-KhcPlainPath (Join-Path (Join-Path (Join-Path $State 'runs') $RunId) 'run.json')
    Assert-KhcRecycleV6ReservationData $reservation $RunId (Get-KhcRecycleV6Hash $recordPath)
    $record=Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
    if($record.max_bytes -ne $reservation.max_bytes -or $record.max_entries -ne $reservation.max_entries -or $record.run_id -cne $RunId){throw 'Recycle-v6 registration bounds mismatch.'}
    $marker=Get-Content -LiteralPath (Assert-KhcPlainPath (Join-Path ([IO.Path]::GetDirectoryName($recordPath)) 'recycle-v6.json')) -Raw | ConvertFrom-Json -AsHashtable
    if($marker.schema -ne 1 -or $marker.protocol -cne 'prunlet-recycle-v6' -or $marker.reservation_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path $root "$RunId.reserve.json"))){throw 'Recycle-v6 registration marker missing or mismatched.'}
    $null=Get-KhcMacNativeE2eRegistration $State $RunId $reservation
    $null=Get-KhcMacReferenceRegistration $State $RunId $reservation
    $null=Get-KhcMacCandidateE2eRegistration $State $RunId $reservation
    if($Request){
        $binding=Read-KhcRecycleV6PrivateJson (Join-Path $root "$RunId.request.json")
        if($binding.schema -ne 1 -or $binding.run_id -cne $RunId -or $binding.reservation_sha256 -cne $marker.reservation_sha256){throw 'Recycle-v6 request anchor mismatch.'}
        foreach($field in @('request','archive','manifest','paths')){
            if($field -ceq 'archive' -and $null -eq $binding.archive_path -and $null -eq $binding.archive_sha256){continue}
            if($binding["${field}_sha256"] -cne (Get-KhcRecycleV6Hash $binding["${field}_path"])){throw "Recycle-v6 bound $field changed."}
        }
        if($binding.exe_sha256 -cne 'af232d1e356faf027266d5569b651b01babdb624503a79bf4403384a3693ffc3' -or $binding.config_sha256 -cne 'd0d38615274ab7a562a42df1544967d7d2aab7d3ad93965f02bac0b50b148765' -or $binding.metadata_root -cne 'C:\Users\IMT\.local\Prunlet\recovery'){throw 'Recycle-v6 installed executable/config binding mismatch.'}
        return $binding
    }
    return $reservation
}

function Assert-KhcMacRemoteReservationData {
    param([Collections.IDictionary]$Profile)
    $fields=@('schema','protocol','host','root','ordinary_bytes','cargo_bytes','total_bytes','approval_max_bytes','approval_source','created_utc')
    if($Profile.Count -ne $fields.Count -or @($Profile.Keys | Where-Object {$_ -cnotin $fields}).Count){throw 'Unknown Mac reservation fields.'}
    foreach($field in @('schema','ordinary_bytes','cargo_bytes','total_bytes','approval_max_bytes')){if($Profile[$field] -isnot [int] -and $Profile[$field] -isnot [long]){throw 'Mac reservation requires integer bounds.'}}
    if($Profile.schema -ne 1 -or $Profile.protocol -cne 'khc-mac-remote-reservation-v1' -or $Profile.host -cne 'm3mb14' -or $Profile.root -cne '/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019' -or $Profile.ordinary_bytes -ne 1610612736L -or $Profile.cargo_bytes -ne 1073741824L -or $Profile.total_bytes -ne 2684354560L -or $Profile.approval_max_bytes -ne 3221225472L -or $Profile.approval_source -cne 'human20261026'){throw 'Mac reservation differs from the authorized fixed profile.'}
    $timestamp=[DateTime]::MinValue
    if($Profile.created_utc -is [DateTime]){
        # PS新版のConvertFrom-JsonはISO-ZをUTC DateTimeへ読む。PS7.0の文字列も維持する。
        if($Profile.created_utc.Kind -ne [DateTimeKind]::Utc){throw 'Mac reservation DateTime must retain UTC kind.'}
    }elseif($Profile.created_utc -isnot [string] -or -not [DateTime]::TryParseExact($Profile.created_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp) -or $timestamp.Kind -ne [DateTimeKind]::Utc){throw 'Mac reservation requires a round-trip UTC timestamp.'}
}

function Get-KhcMacRemoteReservation {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $path=Assert-KhcPlainPath (Join-Path $root 'mac-native-reservation.json')
    if(-not (Test-Path -LiteralPath $path)){return $null}
    $profile=Read-KhcRecycleV6PrivateJson $path
    Assert-KhcMacRemoteReservationData $profile
    return $profile
}

function Initialize-KhcMacRemoteReservation {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $state=[IO.Path]::GetDirectoryName($root)
    $path=Assert-KhcPlainPath (Join-Path $root 'mac-native-reservation.json')
    if(Test-Path -LiteralPath $path){throw 'Mac reservation already exists; no repair or replacement is permitted.'}
    $registrationLease=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        if(Test-Path -LiteralPath $path){throw 'Mac reservation initialization race.'}
        Assert-KhcNoPendingStorageRuns
        $null=Assert-KhcStorageBudget -ReserveBytes 1536MB -CargoReserveBytes 1024MB
        $profile=[ordered]@{schema=1;protocol='khc-mac-remote-reservation-v1';host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';ordinary_bytes=1610612736L;cargo_bytes=1073741824L;total_bytes=2684354560L;approval_max_bytes=3221225472L;approval_source='human20261026';created_utc=[DateTime]::UtcNow.ToString('o')}
        Assert-KhcMacRemoteReservationData $profile
        Write-KhcNewJson $path $profile
        return Get-KhcMacRemoteReservation
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Assert-KhcMacBuildStartData {
    param([Collections.IDictionary]$Record)
    $fields=@('schema','protocol','stage','source_sha256','script_sha256','host','root','started_utc')
    if($Record.Contains('amendment_sha256')){
        if($Record.stage -cne 'build' -or [string]$Record.amendment_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Amendment identity is permitted only on build.'}
        $fields+='amendment_sha256'
    }
    if($Record.Count -ne $fields.Count -or @($Record.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long])){throw 'Unknown Mac build start schema or fields.'}
    if($Record.schema -ne 1 -or $Record.protocol -cne 'khc-mac-native-build-v1' -or $Record.stage -cnotin @('prepare-source','fetch','check','build') -or [string]$Record.source_sha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$Record.script_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $Record.host -cne 'm3mb14' -or $Record.root -cne '/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'){throw 'Invalid immutable Mac build start identity.'}
    $timestamp=[DateTime]::MinValue
    if($Record.started_utc -is [DateTime]){if($Record.started_utc.Kind -ne [DateTimeKind]::Utc){throw 'Mac build start time must be UTC.'}}
    elseif($Record.started_utc -isnot [string] -or -not [DateTime]::TryParseExact($Record.started_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp) -or $timestamp.Kind -ne [DateTimeKind]::Utc){throw 'Mac build start timestamp is invalid.'}
}

function Assert-KhcMacBuildTerminalData {
    param([Collections.IDictionary]$Start,[Collections.IDictionary]$Receipt)
    Assert-KhcMacBuildStartData $Start
    foreach($field in @('stage','source_sha256','script_sha256')){if($Receipt[$field] -cne $Start[$field]){throw 'Mac build terminal identity mismatch.'}}
    if($Start.Contains('amendment_sha256')){if($Receipt.amendment_sha256 -cne $Start.amendment_sha256){throw 'Mac build terminal amendment SHA mismatch.'}}
    elseif($Receipt.Contains('amendment_sha256')){throw 'Old stage receipt cannot acquire an amendment identity.'}
    if($Receipt.children_absent -isnot [bool] -or -not $Receipt.children_absent -or ($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or $Receipt.exit -notin @(0,1)){throw 'Mac build has no confirmed terminal exit/children evidence.'}
    $status=if($Receipt.exit -eq 0){'done'}else{'failed'}
    if($Receipt.status -cne $status){throw 'Mac build status differs from its exit.'}
}

function Assert-KhcMacBuildActivationState {
    param([bool]$HasActivation,[bool]$HasDirectory,[int]$StartedCount)
    if(-not $HasActivation -and -not $HasDirectory -and $StartedCount -eq 0){return $false}
    if(-not $HasActivation -or -not $HasDirectory -or $StartedCount -lt 1){throw 'Mac build activation/directory/start evidence is missing; automatic repair is prohibited.'}
    return $true
}

function Assert-KhcMacBuildActivationData {
    param([Collections.IDictionary]$Record)
    $fields=@('schema','protocol','source_sha256','script_sha256','host','root','activated_utc')
    if($Record.Count -ne $fields.Count -or @($Record.Keys | Where-Object {$_ -cnotin $fields}).Count -or $Record.protocol -cne 'khc-mac-native-build-activation-v1'){throw 'Mac activation schema/fields mismatch.'}
    Assert-KhcMacBuildStartData ([ordered]@{schema=$Record.schema;protocol='khc-mac-native-build-v1';stage='prepare-source';source_sha256=$Record.source_sha256;script_sha256=$Record.script_sha256;host=$Record.host;root=$Record.root;started_utc=$Record.activated_utc})
}

function Assert-KhcMacBuildIntentState {
    param([bool]$HasIntent,[bool]$HasStarted,[bool]$HasTerminal)
    if($HasIntent -ne $HasStarted -or ($HasTerminal -and -not $HasStarted)){throw 'Mac stage intent/start/terminal evidence is orphaned; automatic repair is prohibited.'}
}

function Assert-KhcMacBuildIntentData {
    param([Collections.IDictionary]$Intent,[Collections.IDictionary]$Start,[string]$StartedSha256)
    Assert-KhcMacBuildStartData $Start
    $fields=@('schema','protocol','stage','source_sha256','script_sha256','host','root','started_sha256')
    if($Start.Contains('amendment_sha256')){$fields+='amendment_sha256';if($Intent.amendment_sha256 -cne $Start.amendment_sha256){throw 'Mac intent amendment SHA mismatch.'}}
    if($Intent.Count -ne $fields.Count -or @($Intent.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($Intent.schema -isnot [int] -and $Intent.schema -isnot [long]) -or $Intent.schema -ne 1 -or $Intent.protocol -cne 'khc-mac-native-build-intent-v1' -or $StartedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $Intent.started_sha256 -cne $StartedSha256){throw 'Mac intent schema/full start-record hash mismatch.'}
    foreach($field in @('stage','source_sha256','script_sha256','host','root')){if($Intent[$field] -cne $Start[$field]){throw 'Mac intent identity differs from its started record.'}}
}

function Assert-KhcMacBuildAmendmentSpec {
    param([Collections.IDictionary]$Spec)
    $fields=@('schema','protocol','task','host','root','stage','source_sha256','old_controller_sha256','new_controller_sha256','old_check_terminal_sha256','environment_sha256','cc_shim_sha256','reason')
    if($Spec.Count -ne 13 -or @($Spec.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($Spec.schema -isnot [int] -and $Spec.schema -isnot [long]) -or $Spec.schema -ne 1){throw 'Amendment spec schema/fields mismatch.'}
    $fixed=@{protocol='khc-mac-native-build-amendment-v1';task='goal-restore-20261019';host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';stage='build';source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';old_controller_sha256='51baf46cb26f441e1148123409a271421bd17944893e9bbd3e2fd68401c56a97';old_check_terminal_sha256='80e848d522773b5ec9a47b3eea677d87d38641b72bb12dd1036c19bed214c161';reason='sandboxed-xcrun-cache-and-rust-objcopy-rpath'}
    foreach($field in $fixed.Keys){if($Spec[$field] -isnot [string] -or $Spec[$field] -cne $fixed[$field]){throw "Amendment fixed value mismatch: $field"}}
    foreach($field in @('new_controller_sha256','environment_sha256','cc_shim_sha256')){if($Spec[$field] -isnot [string] -or $Spec[$field] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Amendment new pin format mismatch.'}}
    if($Spec.new_controller_sha256 -ceq $Spec.old_controller_sha256){throw 'Amendment must identify a distinct corrective build controller.'}
}

function Get-KhcMacBuildAmendment {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $path=Assert-KhcPlainPath (Join-Path $root 'mac-native-build-amendment.json')
    if(-not (Test-Path -LiteralPath $path)){return $null}
    $record=Read-KhcRecycleV6PrivateJson $path
    $fields=@('schema','protocol','spec_sha256','spec','registered_utc')
    if($record.Count -ne 5 -or @($record.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($record.schema -isnot [int] -and $record.schema -isnot [long]) -or $record.schema -ne 1 -or $record.protocol -cne 'khc-mac-native-build-amendment-registration-v1' -or $record.spec_sha256 -isnot [string] -or $record.spec_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Protected amendment registration is corrupted.'}
    Assert-KhcMacBuildAmendmentSpec $record.spec
    # UTCは既存startと同じPS7.0文字列/新版DateTime読込契約で検証する。
    Assert-KhcMacBuildStartData ([ordered]@{schema=1;protocol='khc-mac-native-build-v1';stage='build';source_sha256=$record.spec.source_sha256;script_sha256=$record.spec.old_controller_sha256;host=$record.spec.host;root=$record.spec.root;started_utc=$record.registered_utc})
    return $record
}

function Assert-KhcMacBuildBindingData {
    param([Collections.IDictionary]$Start,[Collections.IDictionary]$Activation,[AllowNull()][Collections.IDictionary]$Amendment)
    Assert-KhcMacBuildStartData $Start
    foreach($field in @('source_sha256','host','root')){if($Start[$field] -cne $Activation[$field]){throw 'Mac stage differs from its immutable activation identity.'}}
    if($Start.stage -ceq 'build' -and $null -ne $Amendment){
        Assert-KhcMacBuildAmendmentSpec $Amendment.spec
        $spec=$Amendment.spec
        if($Activation.source_sha256 -cne $spec.source_sha256 -or $Activation.script_sha256 -cne $spec.old_controller_sha256 -or $Start.script_sha256 -cne $spec.new_controller_sha256 -or -not $Start.Contains('amendment_sha256') -or $Start.amendment_sha256 -cne $Amendment.spec_sha256){throw 'Build does not match its one-shot protected amendment.'}
    }elseif($Start.Contains('amendment_sha256') -or $Start.script_sha256 -cne $Activation.script_sha256){throw 'Controller changes are prohibited outside the registered amended build.'}
}

function ConvertFrom-KhcMacBuildAmendmentSnapshot {
    param([byte[]]$Bytes,[string]$ExpectedSha256)
    if($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 65536 -or $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Amendment snapshot bound/SHA format mismatch.'}
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    if($actual -cne $ExpectedSha256){throw 'Amendment snapshot raw SHA mismatch.'}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $document=[Text.Json.JsonDocument]::Parse($text,[Text.Json.JsonDocumentOptions]::new())
    try{
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'Amendment snapshot must contain one JSON object.'}
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()){if(-not $names.Add($property.Name)){throw 'Duplicate amendment JSON key.'}}
    }finally{$document.Dispose()}
    $spec=ConvertFrom-Json -InputObject $text -AsHashtable
    Assert-KhcMacBuildAmendmentSpec $spec
    return $spec
}

function Read-KhcMacBuildAmendmentSnapshot {
    param([string]$Path,[string]$ExpectedSha256)
    $path=Assert-KhcPlainPath $Path
    # 同じhandleで最大64KiB+1を読み、そのbyte[]だけをhash/decode/parseに使う。
    # Windowsの共有Readのみを許し、取得中の書換え・削除共有は許可しない。
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length -gt 65536){throw 'Amendment spec exceeds 64KiB.'}
        $buffer=[byte[]]::new(65537);$length=0
        while($true){$n=$stream.Read($buffer,$length,$buffer.Length-$length);if($n -eq 0){break};$length+=$n;if($length -gt 65536){throw 'Amendment spec grew beyond 64KiB.'}}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($buffer,0,$bytes,0,$length)
    }finally{$stream.Dispose()}
    $null=Assert-KhcPlainPath $path
    return ConvertFrom-KhcMacBuildAmendmentSnapshot $bytes $ExpectedSha256
}

function Register-KhcMacBuildAmendment {
    param([Parameter(Mandatory)][string]$SpecPath,[Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$SpecSha256)
    $expected=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-build-amendment-spec.json')
    if($script:TaskId -cne 'goal-restore-20261019' -or $SpecPath -cne $expected -or (Assert-KhcPlainPath $SpecPath) -cne $expected){throw 'Amendment spec must use the current task fixed keep path.'}
    $spec=Read-KhcMacBuildAmendmentSnapshot $SpecPath $SpecSha256
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $path=Join-Path $root 'mac-native-build-amendment.json';$state=[IO.Path]::GetDirectoryName($root)
    $registrationLease=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        if(Test-Path -LiteralPath $path){throw 'Only one immutable Mac build amendment is permitted.'}
        Assert-KhcNoPendingStorageRuns;Assert-KhcNoPendingMacBuild
        $entries=@(Get-KhcMacBuildLedger)
        if($entries.Count -ne 3 -or @($entries | Where-Object {$_.Stage -cnotin @('prepare-source','fetch','check')}).Count){throw 'Amendment requires exactly the three preserved old stages and no build record.'}
        foreach($entry in $entries){if($null -eq $entry.Terminal -or $entry.Terminal.receipt.exit -ne 0 -or $entry.Terminal.receipt.status -cne 'done' -or $entry.Start.source_sha256 -cne $spec.source_sha256 -or $entry.Start.script_sha256 -cne $spec.old_controller_sha256){throw 'Old Mac stage evidence is not a successful terminal with the fixed old identity.'}}
        $null=Assert-KhcStorageBudget -ReserveBytes 1MB
        Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
        Write-KhcNewJson $path ([ordered]@{schema=1;protocol='khc-mac-native-build-amendment-registration-v1';spec_sha256=$SpecSha256;spec=$spec;registered_utc=[DateTime]::UtcNow.ToString('o')})
        return Get-KhcMacBuildAmendment
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Get-KhcMacBuildLedger {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $directory=Assert-KhcPlainPath (Join-Path $root 'mac-native-build')
    $activationPath=Assert-KhcPlainPath (Join-Path $root 'mac-native-build-activation.json')
    $hasActivation=Test-Path -LiteralPath $activationPath
    $hasDirectory=Test-Path -LiteralPath $directory
    $stages=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $intents=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($file in Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop){
        if($file.Name -cnotlike 'mac-native-build-*-intent.json'){continue}
        if($file.PSIsContainer -or $file.Name -cnotmatch '^mac-native-build-(prepare-source|fetch|check|build)-intent\.json$'){throw 'Unknown Mac stage intent name.'}
        $stage=$Matches[1];$null=Assert-KhcRecycleV6PrivatePath $file.FullName
        if(-not $intents.TryAdd($stage,$file.FullName)){throw 'Duplicate Mac stage intent.'}
        $null=$stages.Add($stage)
    }
    if(-not $hasDirectory){foreach($stage in $stages){Assert-KhcMacBuildIntentState $true $false $false};$null=Assert-KhcMacBuildActivationState $hasActivation $false 0;return @()}
    $null=Assert-KhcRecycleV6PrivatePath $directory
    if($null -eq (Get-KhcMacRemoteReservation)){throw 'Mac build ledger has no persistent remote reservation.'}
    $startedCount=0
    foreach($file in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop){
        $null=Assert-KhcRecycleV6PrivatePath $file.FullName
        if($file.PSIsContainer -or $file.Name -cnotmatch '^(prepare-source|fetch|check|build)\.(started|terminal)\.json$'){throw 'Unknown Mac build ledger record.'}
        if($Matches[2] -ceq 'started'){$startedCount++}
        $null=$stages.Add($Matches[1])
    }
    $null=Assert-KhcMacBuildActivationState $hasActivation $hasDirectory $startedCount
    $activation=Read-KhcRecycleV6PrivateJson $activationPath
    Assert-KhcMacBuildActivationData $activation
    $amendment=Get-KhcMacBuildAmendment
    $entries=[Collections.Generic.List[object]]::new()
    if(-not $stages.Contains('prepare-source')){throw 'Activated Mac build is missing its first prepare-source stage.'}
    foreach($stage in $stages){
        $startedPath=Join-Path $directory "$stage.started.json"
        $terminalPath=Join-Path $directory "$stage.terminal.json"
        Assert-KhcMacBuildIntentState ($intents.ContainsKey($stage)) (Test-Path -LiteralPath $startedPath) (Test-Path -LiteralPath $terminalPath)
        $start=Read-KhcRecycleV6PrivateJson $startedPath
        Assert-KhcMacBuildStartData $start
        $intent=Read-KhcRecycleV6PrivateJson $intents[$stage]
        Assert-KhcMacBuildIntentData $intent $start (Get-KhcRecycleV6Hash $startedPath)
        Assert-KhcMacBuildBindingData $start $activation $amendment
        if($start.stage -cne $stage){throw 'Mac build start filename identity mismatch.'}
        $terminal=$null
        if(Test-Path -LiteralPath $terminalPath){
            $terminal=Read-KhcRecycleV6PrivateJson $terminalPath
            $fields=@('schema','protocol','stage','receipt','completed_utc')
            if($start.Contains('amendment_sha256')){$fields+='amendment_sha256';if($terminal.amendment_sha256 -cne $start.amendment_sha256){throw 'Protected terminal amendment SHA mismatch.'}}
            if($terminal.Count -ne $fields.Count -or @($terminal.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($terminal.schema -isnot [int] -and $terminal.schema -isnot [long]) -or $terminal.schema -ne 1 -or $terminal.protocol -cne 'khc-mac-native-build-v1' -or $terminal.stage -cne $stage){throw 'Mac build terminal record schema mismatch.'}
            $timestamp=[DateTime]::MinValue
            if($terminal.completed_utc -is [DateTime]){if($terminal.completed_utc.Kind -ne [DateTimeKind]::Utc){throw 'Mac build terminal time must be UTC.'}}
            elseif($terminal.completed_utc -isnot [string] -or -not [DateTime]::TryParseExact($terminal.completed_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$timestamp) -or $timestamp.Kind -ne [DateTimeKind]::Utc){throw 'Mac build terminal timestamp is invalid.'}
            Assert-KhcMacBuildTerminalData $start $terminal.receipt
        }
        $entries.Add([pscustomobject]@{Stage=$stage;Start=$start;Terminal=$terminal})
    }
    if($null -ne $amendment){foreach($prior in @('prepare-source','fetch','check')){$old=@($entries | Where-Object {$_.Stage -ceq $prior});if($old.Count -ne 1 -or $null -eq $old[0].Terminal -or $old[0].Terminal.receipt.exit -ne 0 -or $old[0].Start.source_sha256 -cne $amendment.spec.source_sha256 -or $old[0].Start.script_sha256 -cne $amendment.spec.old_controller_sha256){throw 'Protected amendment lost its three successful old-stage prerequisites.'}}}
    return $entries.ToArray()
}

function Assert-KhcNoPendingMacBuild {
    Assert-KhcVerifierQuarantineClear
    $candidate=Get-KhcMacCdfCandidateLedger
    Assert-KhcMacCdfCandidateState ($null -ne $candidate.Start) ($null -ne $candidate.Terminal)
    $retry=Get-KhcMacDecodeRetryLedger
    Assert-KhcMacDecodeRetryState ($null -ne $retry.Amendment) ($null -ne $retry.Start) ($null -ne $retry.Terminal)
    $diagnostic=Get-KhcMacDecodeDiagnosticLedger
    Assert-KhcMacDecodeDiagnosticState ($null -ne $diagnostic.Start) ($null -ne $diagnostic.Terminal) $diagnostic.Terminal
    foreach($entry in @(Get-KhcMacBuildLedger)){if($null -eq $entry.Terminal){throw "Unresolved remote Mac stage blocks Cargo and registration: $($entry.Stage). Confirm its immutable remote terminal journal before explicit resolution."}}
}

function Get-KhcMacCdfCandidateTrustSpec {
    param([string]$ControllerSha256,[string]$SnapshotSha256,[string]$ProtocolSha256)
    if($ControllerSha256 -cne '2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5' -or $SnapshotSha256 -cne '80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f' -or $ProtocolSha256 -cne '8c6f4576d868e43158ade779ee176719bc6a7281d4420a4bfe3d371d25ab0082'){throw 'Unknown CDF candidate controller/snapshot/protocol; no fallback is permitted.'}
    $pins=(Get-KhcMacDecodeRetryTrustSpec '771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe' 'b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806').Pins
    $pins['mac-cdf-candidate-build.py']='2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5'
    $pins['mac-cdf-candidate-snapshot.py']='80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f'
    return [pscustomobject]@{Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-verifier-2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5');Pins=$pins}
}

function Get-KhcMacCdfCandidateProtocol {
    param([string]$ControllerSha256,[string]$SnapshotSha256)
    foreach($sha in @($ControllerSha256,$SnapshotSha256)){if($sha -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Candidate dependency SHA invalid.'}}
    $root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
    $target="$root/cargo-target/cdf-chooser-candidate-20261027"
    $preserved=@{
        'cargo-target/aarch64-apple-darwin/release/unlhare-cli'='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629'
        'cargo-target/decode-phase-20261027/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic'='4e68a6a54d5b9fec55c4507c4b5c3588b8cf8e10c3425615541cd91a3103e742'
        'tmp/mac-canterbury-continuous-reference-20261027/00-archive.khc'='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee'
        'journal/mac-canterbury-continuous-reference.terminal.json'='88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e'
        'journal/mac-decode-phase-retry.terminal.json'='b5e6efbefc39bafa9f2d21f7ce33074c6b26f3cff0af44b2a5159fc64fca3b0d'
        'journal/mac-decode-phase-retry.closure.json'='163ea2b3c4b9998d7f0519245c0447ba4df935b249326e4417f97264d0e53a36'
        'journal/mac-khc-decode-phase-run-20261027.terminal.json'='cc6a0f45af705522009bd727140f96e77af085a0aeb46f1a7b7e2247fc1bd78e'
    }
    return @{schema=1;protocol='khc-mac-cdf-candidate-build-v1';purpose='cdf-chooser-candidate';task='goal-restore-20261019';host='m3mb14';root=$root;source_directory="$root/cdf-chooser-candidate-20261027/source";target=$target;binary_path="$target/aarch64-apple-darwin/release/unlhare-cli";source_sha256='36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05';source_manifest_sha256='d711acf1989b34f5043d5a7bae68ea95c2d51a72f602ca6ca27124e5ebffc7e2';base_source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';controller_sha256=$ControllerSha256;snapshot_sha256=$SnapshotSha256;supervisor_sha256='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30';setup_sha256='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1';build_verifier_sha256='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb';phase_controller_sha256='da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc';retry_controller_sha256='771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe';preserved_sha256=$preserved;toolchain='1.99.1-aarch64-apple-darwin';cargo_command=@("$root/tools/rust/bin/cargo",'build','--release','--offline','--locked','--target','aarch64-apple-darwin','--lib','--bin','unlhare-cli','--example','khc_spatial_mdl_e2e','-j','1','--target-dir',$target);cargo_timeout_seconds=300;native_final_seconds=350;ssh_timeout_seconds=380;additional_target_max_bytes=536870912L;ordinary_max_bytes=1610612736L;cargo_max_bytes=1073741824L;total_max_bytes=2684354560L;additional_attempts=1;superiority_decision_allowed=$false}
}

function Assert-KhcMacCdfCandidateProtocol {
    param([Collections.IDictionary]$Protocol)
    if($Protocol.controller_sha256 -isnot [string] -or $Protocol.snapshot_sha256 -isnot [string]){throw 'Candidate dependency SHA types invalid.'}
    $expected=Get-KhcMacCdfCandidateProtocol $Protocol.controller_sha256 $Protocol.snapshot_sha256
    if(-not (Test-KhcMacNativeE2eJsonEqual $Protocol $expected)){throw 'Candidate fixed protocol differs.'}
}

function Assert-KhcMacCdfCandidateState {
    param([bool]$HasStart,[bool]$HasTerminal)
    if($HasTerminal -and -not $HasStart){throw 'Orphan candidate terminal.'}
    if($HasStart -and -not $HasTerminal){throw 'Unresolved candidate start blocks every Cargo invocation.'}
}

function Get-KhcMacCdfCandidateLedger {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $startPath=Assert-KhcPlainPath (Join-Path $root 'mac-cdf-candidate.started.json')
    $terminalPath=Assert-KhcPlainPath (Join-Path $root 'mac-cdf-candidate.terminal.json')
    $start=$null;$terminal=$null
    if(Test-Path -LiteralPath $startPath){
        $start=Read-KhcRecycleV6PrivateJson $startPath
        Assert-KhcMacDecodeDiagnosticFields $start @('schema','protocol','protocol_sha256','protocol_base64','started_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $start.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $start.protocol 'khc-mac-cdf-candidate-start-v1') -or $start.protocol_base64 -isnot [string] -or $start.protocol_base64.Length -gt 45000){throw 'Candidate start schema invalid.'}
        Assert-KhcMacDecodeDiagnosticUtc $start.started_utc
        $null=Invoke-KhcMacCdfCandidateVerifier $start
    }
    if(Test-Path -LiteralPath $terminalPath){
        if($null -eq $start){throw 'Orphan candidate terminal.'}
        $seal=Read-KhcRecycleV6PrivateJson $terminalPath
        Assert-KhcMacDecodeDiagnosticFields $seal @('schema','protocol','receipt_sha256','receipt_base64','saved_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $seal.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $seal.protocol 'khc-mac-cdf-candidate-terminal-seal-v1') -or $seal.receipt_base64 -isnot [string] -or $seal.receipt_base64.Length -gt 90000){throw 'Candidate terminal seal schema invalid.'}
        Assert-KhcMacDecodeDiagnosticUtc $seal.saved_utc
        $terminal=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($seal.receipt_base64)) $seal.receipt_sha256 65536
        $null=Invoke-KhcMacCdfCandidateVerifier $start $seal.receipt_base64
    }
    return [pscustomobject]@{Start=$start;Terminal=$terminal}
}

function Start-KhcMacCdfCandidate {
    param([byte[]]$ProtocolBytes,[string]$ProtocolSha256)
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot $ProtocolBytes $ProtocolSha256 32768
    Assert-KhcMacCdfCandidateProtocol $protocol
    $null=Get-KhcMacCdfCandidateTrustSpec $protocol.controller_sha256 $protocol.snapshot_sha256 $ProtocolSha256
    if($script:TaskId -cne 'goal-restore-20261019' -or $null -eq (Get-KhcMacRemoteReservation)){throw 'Candidate requires fixed task and existing remote reservation.'}
    Assert-KhcNoPendingStorageRuns;Assert-KhcNoPendingMacBuild
    if($null -ne (Get-KhcMacCdfCandidateLedger).Start){throw 'CDF candidate build is one-shot, including failed/partial attempts.'}
    $start=[ordered]@{schema=1;protocol='khc-mac-cdf-candidate-start-v1';protocol_sha256=$ProtocolSha256;protocol_base64=[Convert]::ToBase64String($ProtocolBytes);started_utc=[DateTime]::UtcNow.ToString('o')}
    $null=Invoke-KhcMacCdfCandidateVerifier $start
    # 既存remote reservationはAssertStorageBudgetが一度だけ課金する。新規はmetadataのみ。
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate.started.json') $start
}

function Save-KhcMacCdfCandidateTerminal {
    param([byte[]]$ReceiptBytes)
    $ledger=Get-KhcMacCdfCandidateLedger
    if($null -eq $ledger.Start -or $null -ne $ledger.Terminal){throw 'Candidate terminal requires an unresolved immutable start.'}
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    $null=ConvertFrom-KhcBoundedJsonSnapshot $ReceiptBytes $sha 65536
    $base64=[Convert]::ToBase64String($ReceiptBytes)
    $null=Invoke-KhcMacCdfCandidateVerifier $ledger.Start $base64
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate.terminal.json') ([ordered]@{schema=1;protocol='khc-mac-cdf-candidate-terminal-seal-v1';receipt_sha256=$sha;receipt_base64=$base64;saved_utc=[DateTime]::UtcNow.ToString('o')})
}

function Invoke-KhcMacCdfCandidateVerifier {
    param([Collections.IDictionary]$Start,[string]$ReceiptBase64='')
    Assert-KhcVerifierQuarantineClear
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($Start.protocol_base64)) $Start.protocol_sha256 32768
    Assert-KhcMacCdfCandidateProtocol $protocol
    $trust=Get-KhcMacCdfCandidateTrustSpec $protocol.controller_sha256 $protocol.snapshot_sha256 $Start.protocol_sha256
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-I','-B',(Join-Path $trust.Directory 'mac-cdf-candidate-build.py'))){$info.ArgumentList.Add($arg)}
    if($ReceiptBase64){if($ReceiptBase64.Length -gt 90000){throw 'Candidate receipt bound.'};foreach($arg in @('--verify-receipt-base64',$ReceiptBase64,'--protocol-base64',$Start.protocol_base64)){$info.ArgumentList.Add($arg)}}
    else{foreach($arg in @('--verify-protocol-base64',$Start.protocol_base64,'--protocol-sha',$Start.protocol_sha256)){$info.ArgumentList.Add($arg)}}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$spawned=$false;$readLease=$null
    try{
        $readLease=Enter-KhcMacDecodeVerifierReadLease $trust
        $scan=Get-KhcChargeScanContext
        $scanKey=Get-KhcChargeScanKey 'Invoke-KhcMacCdfCandidateVerifier' @($info.ArgumentList) ((@($trust.Pins.Keys | Sort-Object -CaseSensitive | ForEach-Object {$_+'='+$trust.Pins[$_]}) -join "`n"))
        if($null -ne $scan -and $scan.Results.ContainsKey($scanKey)){return (Copy-KhcChargeScanSummary $scan.Results[$scanKey])}
        if(-not $process.Start()){throw 'Candidate pure verifier did not start.'};$spawned=$true
        $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(2048),[char[]]::new(2048));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
        $tasks=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048));$done=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
        while($true){
            for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){$count=$tasks[$side].GetAwaiter().GetResult();if($count -eq 0){$done[$side]=$true}else{if($logs[$side].Length+$count -gt 16384){throw 'Candidate pure verifier output bound.'};$null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,2048)}}}
            if($timer.Elapsed.TotalSeconds -gt 15){throw 'Candidate pure verifier timeout.'}
            if($process.HasExited -and $done[0] -and $done[1]){break};Start-Sleep -Milliseconds 25
        }
        if($process.ExitCode -ne 0 -or $logs[1].Length -ne 0){throw 'Candidate native pure validation failed.'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($logs[0].ToString());$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $summary=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 16384
        Assert-KhcMacCdfCandidateSummary $summary $Start $ReceiptBase64
        if($null -ne $scan){
            $scan.Results[$scanKey]=Copy-KhcChargeScanSummary $summary
            $scan.Leases.Add($readLease);$readLease=$null
        }
        return $summary
    }finally{Complete-KhcVerifierReadLease $process $spawned $readLease}
}

function Assert-KhcMacCdfCandidateSummary {
    param([Collections.IDictionary]$Summary,[Collections.IDictionary]$Start,[string]$ReceiptBase64='')
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($Start.protocol_base64)) $Start.protocol_sha256 32768
    Assert-KhcMacCdfCandidateProtocol $protocol
    $fields=@('schema','protocol','protocol_sha256','source_sha256','controller_sha256','purpose','verified')
    if($ReceiptBase64){$fields+=@('receipt_sha256','binary_sha256','closure_sha256','status','exit','cleanup_allowed')}
    Assert-KhcMacDecodeDiagnosticFields $Summary $fields
    if(-not (Test-KhcMacNativeE2eJsonEqual $Summary.schema 1) -or $Summary.verified -isnot [bool] -or -not $Summary.verified -or $Summary.protocol_sha256 -isnot [string] -or $Summary.protocol_sha256 -cne $Start.protocol_sha256){throw 'Candidate pure summary identity mismatch.'}
    foreach($key in @('protocol','source_sha256','controller_sha256','purpose')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $protocol[$key])){throw 'Candidate pure summary binding mismatch.'}}
    if($ReceiptBase64){
        $raw=[Convert]::FromBase64String($ReceiptBase64);$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot $raw $sha 65536
        Assert-KhcMacDecodeDiagnosticFields $receipt @('schema','protocol','purpose','source_sha256','controller_sha256','protocol_sha256','root','target','cargo_command','status','exit','runtime_seconds','cargo_runtime_seconds','binary_sha256','binary_path','wait_confirmed','group_absent','postchecks_ok','closure_proof','closure_sha256','error')
        foreach($key in @('schema','protocol','purpose','source_sha256','controller_sha256','root','target','cargo_command','binary_path')){if(-not (Test-KhcMacNativeE2eJsonEqual $receipt[$key] $protocol[$key])){throw 'Candidate raw receipt identity/recipe differs.'}}
        if($receipt.protocol_sha256 -isnot [string] -or $receipt.protocol_sha256 -cne $Start.protocol_sha256 -or $Summary.receipt_sha256 -isnot [string] -or $Summary.receipt_sha256 -cne $sha -or $Summary.cleanup_allowed -isnot [bool] -or -not $Summary.cleanup_allowed){throw 'Candidate raw receipt or closure summary unconfirmed; pending remains.'}
        foreach($key in @('wait_confirmed','group_absent')){if($receipt[$key] -isnot [bool] -or -not $receipt[$key]){throw 'Candidate closure unknown; pending remains.'}}
        foreach($key in @('status','exit','binary_sha256','closure_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $receipt[$key])){throw 'Candidate receipt/summary differs.'}}
    }
}

function Assert-KhcVerifierQuarantineClear {
    if(('Khc.Storage.VerifierQuarantineState' -as [type]) -and [Khc.Storage.VerifierQuarantineState]::Count -gt 0){throw 'An unconfirmed verifier process/lease is quarantined in this host; further work is blocked.'}
    $marker=Assert-KhcPlainPath (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\storage-lifecycle\recycle-v6\mac-verifier-unresolved.json')
    if(Test-Path -LiteralPath $marker){throw 'Persistent unresolved verifier marker blocks further work; explicit evidence-based resolution is required.'}
}

function Protect-KhcUnclosedVerifier {
    param($Process,$ReadLease,[string]$Reason)
    if(-not ('Khc.Storage.VerifierQuarantineState' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace Khc.Storage {
 public static class VerifierQuarantineState {
  static readonly List<object[]> Held = new List<object[]>();
  public static int Count { get { lock(Held) { return Held.Count; } } }
  public static void Hold(object process,object lease) { lock(Held) { Held.Add(new object[] { process,lease }); } }
 }
}
'@
    }
    # 先にstrong referenceを保持する。marker保存失敗でも子/leaseは解放しない。
    [Khc.Storage.VerifierQuarantineState]::Hold($Process,$ReadLease)
    try{
        $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
        $marker=Assert-KhcPlainPath (Join-Path $root 'mac-verifier-unresolved.json')
        if(Test-Path -LiteralPath $marker){return}
        $childPid=$null
        try{$childPid=[int]$Process.Id}catch{}
        Write-KhcNewJson $marker ([ordered]@{schema=1;protocol='khc-verifier-unresolved-v1';pid=$childPid;reason=$Reason.Substring(0,[math]::Min(4096,$Reason.Length));recorded_utc=[DateTime]::UtcNow.ToString('o')})
    }catch{throw "Verifier process/lease retained in this host, but persistent marker could not be saved. After host exit, persistent blocking cannot be guaranteed. $($_.Exception.Message)"}
}

function Complete-KhcVerifierReadLease {
    param($Process,[bool]$Spawned,$ReadLease)
    $confirmed=-not $Spawned
    try{
        if($Spawned){
            if($Process.HasExited){$confirmed=$true}
            else{
                $Process.Kill($true)
                if(-not $Process.WaitForExit(5000)){throw 'Verifier child termination was not confirmed within the bounded wait.'}
                if(-not $Process.HasExited){throw 'Verifier child exit remains unconfirmed after wait.'}
                $confirmed=$true
            }
        }
    }catch{
        $reason=$_.Exception.Message
        Protect-KhcUnclosedVerifier $Process $ReadLease $reason
        throw "Verifier child and read lease remain quarantined; subsequent work is blocked. $reason"
    }finally{
        if($confirmed){
            try{if($null -ne $Process){$Process.Dispose()}}
            finally{if($null -ne $ReadLease){for($i=$ReadLease.Count-1;$i -ge 0;$i--){$ReadLease[$i].Dispose()}}}
        }
    }
}

function Get-KhcMacDecodeRetryTrustSpec {
    param([string]$ControllerSha256,[string]$SnapshotSha256)
    if($ControllerSha256 -cne '771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe' -or $SnapshotSha256 -cne 'b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806'){throw 'Unknown retry controller/snapshot; no fallback is permitted.'}
    $pins=(Get-KhcMacDecodeVerifierBundleSpec 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc').Pins
    $pins['mac-decode-phase-retry.py']='771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe'
    $pins['mac-diagnostic-storage-snapshot.py']='b99b4338cc3253181402b215fa826230d6284a9044ba9520efc04af1d0253806'
    $pins['mac-native-setup.py']='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1'
    return [pscustomobject]@{Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-decode-retry-verifier-771443623c9255e7cfd1ef2272dd265035aa38c3c5a903c245b63361db8eaafe');Pins=$pins;AmendmentSha256='f2a4979ed0f796b98876a324734998329eb40255b8593350ee439165873ae46e'}
}

function Assert-KhcMacDecodeRetryAmendment {
    param([Collections.IDictionary]$Amendment)
    $root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
    $fixed=@{schema=1;protocol='khc-mac-decode-phase-retry-v1';old_protocol_sha256='64f6aae8c18c83f5f966462c96e1d4ecc3bb34af0a2f114b9844c129539f0088';old_receipt_sha256='84c7e314b0a79c2ac9d55e34772c8f20339e29079dbd17868605c0e08f27f4ca';old_closure_sha256='d12c7079556b9f44e5e0e952847040f9a467a380a977badf9102669ecc7f91a6';old_controller_sha256='da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc';source_sha256='1ffe78d045d85e8919fddc166a4a97c997b88ee70fba5ca8a0df20be447c7f55';root=$root;source_directory="$root/decode-phase-20261027/source";target="$root/cargo-target/decode-phase-20261027";additional_attempts=1;cargo_timeout_seconds=300;native_final_seconds=350;ssh_timeout_seconds=380;additional_target_max_bytes=536870912L;ordinary_max_bytes=1610612736L;cargo_max_bytes=1073741824L;total_max_bytes=2684354560L}
    Assert-KhcMacDecodeDiagnosticFields $Amendment (@($fixed.Keys)+@('controller_sha256','snapshot_sha256'))
    foreach($key in $fixed.Keys){if(-not (Test-KhcMacNativeE2eJsonEqual $Amendment[$key] $fixed[$key])){throw "Retry amendment fixed field mismatch: $key"}}
    foreach($key in @('controller_sha256','snapshot_sha256')){if($Amendment[$key] -isnot [string] -or $Amendment[$key] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Retry SHA invalid.'}}
    if($Amendment.controller_sha256 -ceq $Amendment.old_controller_sha256){throw 'Retry must use the separately frozen repaired controller.'}
}

function Assert-KhcMacDecodeRetryOldEvidence {
    param([Collections.IDictionary]$Start,[Collections.IDictionary]$Receipt,[string]$ReceiptSha256)
    if($Start.protocol_sha256 -isnot [string] -or $Start.protocol_sha256 -cne '64f6aae8c18c83f5f966462c96e1d4ecc3bb34af0a2f114b9844c129539f0088' -or $Start.spec.controller_sha256 -isnot [string] -or $Start.spec.controller_sha256 -cne 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc' -or $ReceiptSha256 -cne '84c7e314b0a79c2ac9d55e34772c8f20339e29079dbd17868605c0e08f27f4ca' -or $Receipt.closure_sha256 -isnot [string] -or $Receipt.closure_sha256 -cne 'd12c7079556b9f44e5e0e952847040f9a467a380a977badf9102669ecc7f91a6' -or $Receipt.status -isnot [string] -or $Receipt.status -cne 'failed' -or ($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or $Receipt.exit -ne 1){throw 'Retry requires the exact historical failed attempt.'}
    foreach($key in @('postchecks_ok','wait_confirmed','group_absent')){if($Receipt[$key] -isnot [bool] -or -not $Receipt[$key]){throw 'Retry requires historical postchecks and known closure.'}}
}

function Get-KhcMacDecodeRetryOldEvidence {
    $old=Get-KhcMacDecodeDiagnosticLedger
    if($null -eq $old.Start -or $null -eq $old.Terminal){throw 'Retry requires the historical terminal.'}
    $seal=Read-KhcRecycleV6PrivateJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-decode-diagnostic.terminal.json')
    Assert-KhcMacDecodeRetryOldEvidence $old.Start $old.Terminal $seal.receipt_sha256
    # GetLedgerは旧bundleで原protocol/receipt/FS closureを独立再検証済み。
    return [pscustomobject]@{Start=$old.Start;Receipt=$old.Terminal;ReceiptBase64=$seal.receipt_base64}
}

function Assert-KhcMacDecodeRetryState {
    param([bool]$HasAmendment,[bool]$HasStart,[bool]$HasTerminal)
    if((($HasStart -or $HasTerminal) -and -not $HasAmendment) -or ($HasTerminal -and -not $HasStart)){throw 'Orphan retry ledger evidence.'}
    if($HasAmendment -and -not $HasTerminal){throw 'Unresolved retry amendment/start blocks every Cargo invocation.'}
}

function Get-KhcMacDecodeRetryLedger {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $registrationPath=Assert-KhcPlainPath (Join-Path $root 'mac-decode-retry.amendment.json')
    $startPath=Assert-KhcPlainPath (Join-Path $root 'mac-decode-retry.started.json')
    $terminalPath=Assert-KhcPlainPath (Join-Path $root 'mac-decode-retry.terminal.json')
    $amendment=$null;$start=$null;$terminal=$null
    if(Test-Path -LiteralPath $registrationPath){
        $amendment=Read-KhcRecycleV6PrivateJson $registrationPath
        Assert-KhcMacDecodeDiagnosticFields $amendment @('schema','protocol','amendment_sha256','amendment_base64','registered_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $amendment.schema 1) -or $amendment.protocol -isnot [string] -or $amendment.protocol -cne 'khc-mac-decode-retry-registration-v1' -or $amendment.amendment_base64 -isnot [string] -or $amendment.amendment_base64.Length -gt 45000){throw 'Retry registration schema mismatch.'}
        Assert-KhcMacDecodeDiagnosticUtc $amendment.registered_utc
        $spec=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($amendment.amendment_base64)) $amendment.amendment_sha256 32768
        Assert-KhcMacDecodeRetryAmendment $spec
        $null=Invoke-KhcMacDecodeRetryVerifier $amendment
    }
    if(Test-Path -LiteralPath $startPath){
        if($null -eq $amendment){throw 'Orphan retry start.'}
        $start=Read-KhcRecycleV6PrivateJson $startPath
        Assert-KhcMacDecodeDiagnosticFields $start @('schema','protocol','amendment_sha256','started_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $start.schema 1) -or $start.protocol -isnot [string] -or $start.protocol -cne 'khc-mac-decode-retry-start-v1' -or $start.amendment_sha256 -isnot [string] -or $start.amendment_sha256 -cne $amendment.amendment_sha256){throw 'Retry start binding mismatch.'}
        Assert-KhcMacDecodeDiagnosticUtc $start.started_utc
    }
    if(Test-Path -LiteralPath $terminalPath){
        if($null -eq $start){throw 'Orphan retry terminal.'}
        $seal=Read-KhcRecycleV6PrivateJson $terminalPath
        Assert-KhcMacDecodeDiagnosticFields $seal @('schema','protocol','receipt_sha256','receipt_base64','saved_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $seal.schema 1) -or $seal.protocol -isnot [string] -or $seal.protocol -cne 'khc-mac-decode-retry-terminal-seal-v1' -or $seal.receipt_base64 -isnot [string] -or $seal.receipt_base64.Length -gt 90000){throw 'Retry terminal seal schema mismatch.'}
        Assert-KhcMacDecodeDiagnosticUtc $seal.saved_utc
        $terminal=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($seal.receipt_base64)) $seal.receipt_sha256 65536
        $null=Invoke-KhcMacDecodeRetryVerifier $amendment $seal.receipt_base64
    }
    return [pscustomobject]@{Amendment=$amendment;Start=$start;Terminal=$terminal}
}

function Start-KhcMacDecodeRetry {
    param([byte[]]$AmendmentBytes,[string]$AmendmentSha256)
    # run-serial-cargo gatewayが既存共有Cargo leaseを保持して呼ぶ。
    $spec=ConvertFrom-KhcBoundedJsonSnapshot $AmendmentBytes $AmendmentSha256 32768
    Assert-KhcMacDecodeRetryAmendment $spec
    $null=Get-KhcMacDecodeRetryTrustSpec $spec.controller_sha256 $spec.snapshot_sha256
    if($script:TaskId -cne 'goal-restore-20261019' -or $null -eq (Get-KhcMacRemoteReservation)){throw 'Retry requires fixed task and existing remote reservation.'}
    Assert-KhcNoPendingStorageRuns;Assert-KhcNoPendingMacBuild
    $ledger=Get-KhcMacDecodeRetryLedger
    if($null -ne $ledger.Amendment){throw 'Additional retry is one-shot, including failed/partial attempts.'}
    $null=Get-KhcMacDecodeRetryOldEvidence
    $registration=[ordered]@{schema=1;protocol='khc-mac-decode-retry-registration-v1';amendment_sha256=$AmendmentSha256;amendment_base64=[Convert]::ToBase64String($AmendmentBytes);registered_utc=[DateTime]::UtcNow.ToString('o')}
    $null=Invoke-KhcMacDecodeRetryVerifier $registration
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    $root=Get-KhcRecycleV6AnchorRoot
    Write-KhcNewJson (Join-Path $root 'mac-decode-retry.amendment.json') $registration
    Write-KhcNewJson (Join-Path $root 'mac-decode-retry.started.json') ([ordered]@{schema=1;protocol='khc-mac-decode-retry-start-v1';amendment_sha256=$AmendmentSha256;started_utc=[DateTime]::UtcNow.ToString('o')})
}

function Save-KhcMacDecodeRetryTerminal {
    param([byte[]]$ReceiptBytes)
    $ledger=Get-KhcMacDecodeRetryLedger
    if($null -eq $ledger.Start -or $null -ne $ledger.Terminal){throw 'Retry terminal requires one unresolved immutable start.'}
    $receiptSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    $null=ConvertFrom-KhcBoundedJsonSnapshot $ReceiptBytes $receiptSha 65536
    $base64=[Convert]::ToBase64String($ReceiptBytes)
    $null=Invoke-KhcMacDecodeRetryVerifier $ledger.Amendment $base64
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-decode-retry.terminal.json') ([ordered]@{schema=1;protocol='khc-mac-decode-retry-terminal-seal-v1';receipt_sha256=$receiptSha;receipt_base64=$base64;saved_utc=[DateTime]::UtcNow.ToString('o')})
}

function Invoke-KhcMacDecodeRetryVerifier {
    param([Collections.IDictionary]$Registration,[string]$ReceiptBase64='')
    Assert-KhcVerifierQuarantineClear
    $spec=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($Registration.amendment_base64)) $Registration.amendment_sha256 32768
    Assert-KhcMacDecodeRetryAmendment $spec
    $trust=Get-KhcMacDecodeRetryTrustSpec $spec.controller_sha256 $spec.snapshot_sha256
    if($Registration.amendment_sha256 -cne $trust.AmendmentSha256){throw 'Retry amendment differs from the fixed reviewed raw identity.'}
    $old=Get-KhcMacDecodeRetryOldEvidence
    $directory=Assert-KhcPlainPath $trust.Directory
    $files=@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
    if($files.Count -ne $trust.Pins.Count){throw 'Retry verifier bundle file set mismatch.'}
    foreach($file in $files){$path=Assert-KhcPlainPath $file.FullName;if($file.PSIsContainer -or -not $trust.Pins.ContainsKey($file.Name) -or (Get-KhcRecycleV6Hash $path) -cne $trust.Pins[$file.Name]){throw 'Retry verifier bundle SHA/type mismatch.'}}
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-I','-B',(Join-Path $directory 'mac-decode-phase-retry.py'),'--old-protocol-base64',$old.Start.protocol_base64,'--old-receipt-base64',$old.ReceiptBase64)){$info.ArgumentList.Add($arg)}
    if($ReceiptBase64){if($ReceiptBase64.Length -gt 90000){throw 'Retry receipt bound.'};foreach($arg in @('--verify-receipt-base64',$ReceiptBase64,'--amendment-base64',$Registration.amendment_base64)){$info.ArgumentList.Add($arg)}}
    else{foreach($arg in @('--verify-amendment-base64',$Registration.amendment_base64,'--amendment-sha',$Registration.amendment_sha256)){$info.ArgumentList.Add($arg)}}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$spawned=$false;$readLease=$null
    try{
        $readLease=Enter-KhcMacDecodeVerifierReadLease $trust
        $scan=Get-KhcChargeScanContext
        $scanKey=Get-KhcChargeScanKey 'Invoke-KhcMacDecodeRetryVerifier' @($info.ArgumentList) ((@($trust.Pins.Keys | Sort-Object -CaseSensitive | ForEach-Object {$_+'='+$trust.Pins[$_]}) -join "`n"))
        if($null -ne $scan -and $scan.Results.ContainsKey($scanKey)){return (Copy-KhcChargeScanSummary $scan.Results[$scanKey])}
        if(-not $process.Start()){throw 'Retry pure verifier did not start.'};$spawned=$true
        $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(2048),[char[]]::new(2048));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
        $tasks=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048));$done=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
        while($true){
            for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){$count=$tasks[$side].GetAwaiter().GetResult();if($count -eq 0){$done[$side]=$true}else{if($logs[$side].Length+$count -gt 16384){throw 'Retry verifier output bound.'};$null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,2048)}}}
            if($timer.Elapsed.TotalSeconds -gt 15){throw 'Retry pure verifier timeout.'}
            if($process.HasExited -and $done[0] -and $done[1]){break};Start-Sleep -Milliseconds 25
        }
        if($process.ExitCode -ne 0 -or $logs[1].Length -ne 0){throw 'Retry native pure validation failed.'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($logs[0].ToString());$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $summary=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 16384
        Assert-KhcMacDecodeRetrySummary $summary $Registration $ReceiptBase64 $old.Start.spec
        if($null -ne $scan){
            $scan.Results[$scanKey]=Copy-KhcChargeScanSummary $summary
            $scan.Leases.Add($readLease);$readLease=$null
        }
        return $summary
    }finally{Complete-KhcVerifierReadLease $process $spawned $readLease}
}

function Assert-KhcMacDecodeRetrySummary {
    param([Collections.IDictionary]$Summary,[Collections.IDictionary]$Registration,[string]$ReceiptBase64='',[Collections.IDictionary]$OldProtocol)
    $spec=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($Registration.amendment_base64)) $Registration.amendment_sha256 32768
    Assert-KhcMacDecodeRetryAmendment $spec
    $fields=@('schema','protocol','verified','amendment_sha256','old_receipt_sha256','snapshot_sha256')
    if($ReceiptBase64){$fields+=@('receipt_sha256','status','exit','binary_sha256','closure_sha256','cleanup_allowed')}
    Assert-KhcMacDecodeDiagnosticFields $Summary $fields
    if(-not (Test-KhcMacNativeE2eJsonEqual $Summary.schema 1) -or $Summary.verified -isnot [bool] -or -not $Summary.verified -or $Summary.amendment_sha256 -isnot [string] -or $Summary.amendment_sha256 -cne $Registration.amendment_sha256){throw 'Retry pure summary identity mismatch.'}
    foreach($key in @('protocol','old_receipt_sha256','snapshot_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $spec[$key])){throw 'Retry pure summary binding mismatch.'}}
    if($ReceiptBase64){
        $raw=[Convert]::FromBase64String($ReceiptBase64);$rawSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot $raw $rawSha 65536
        Assert-KhcMacDecodeDiagnosticFields $receipt @('schema','protocol','purpose','source_sha256','controller_sha256','protocol_sha256','root','target','cargo_command','status','exit','runtime_seconds','cargo_runtime_seconds','binary_sha256','binary_path','wait_confirmed','group_absent','postchecks_ok','closure_proof','closure_sha256','error','amendment_sha256','snapshot_sha256','old_receipt_sha256')
        foreach($key in @('protocol','source_sha256','controller_sha256','root','target','snapshot_sha256','old_receipt_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $receipt[$key] $spec[$key])){throw 'Retry receipt identity mismatch.'}}
        if(-not (Test-KhcMacNativeE2eJsonEqual $receipt.schema 1) -or $receipt.protocol_sha256 -isnot [string] -or $receipt.protocol_sha256 -cne $Registration.amendment_sha256 -or $receipt.amendment_sha256 -isnot [string] -or $receipt.amendment_sha256 -cne $Registration.amendment_sha256 -or -not (Test-KhcMacNativeE2eJsonEqual $receipt.purpose 'decode-phase-diagnostic') -or -not (Test-KhcMacNativeE2eJsonEqual $receipt.cargo_command $OldProtocol.cargo_command) -or -not (Test-KhcMacNativeE2eJsonEqual $receipt.binary_path "$($spec.target)/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic")){throw 'Retry receipt recipe mismatch.'}
        foreach($key in @('wait_confirmed','group_absent')){if($receipt[$key] -isnot [bool] -or -not $receipt[$key]){throw 'Retry closure unknown; pending remains.'}}
        if($Summary.receipt_sha256 -isnot [string] -or $Summary.receipt_sha256 -cne $rawSha -or $Summary.cleanup_allowed -isnot [bool] -or -not $Summary.cleanup_allowed){throw 'Retry closure summary unknown; pending remains.'}
        foreach($key in @('status','exit','binary_sha256','closure_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $receipt[$key])){throw 'Retry raw receipt differs from pure summary.'}}
    }
}

function Get-KhcMacDecodeDiagnosticCommand {
    return @('/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019/tools/rust/bin/cargo','build','--locked','--offline','--release','--example','khc_archive_phase_diagnostic','--target','aarch64-apple-darwin','-j','1','--target-dir','/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019/cargo-target/decode-phase-20261027')
}

function Assert-KhcMacDecodeDiagnosticFields {
    param([Collections.IDictionary]$Record,[string[]]$Fields)
    if($null -eq $Record -or $Record.Count -ne $Fields.Count -or @($Record.Keys | Where-Object {$_ -cnotin $Fields}).Count){throw 'Unknown diagnostic fields.'}
}

function Assert-KhcMacDecodeDiagnosticUtc {
    param($Value)
    $parsed=[DateTime]::MinValue
    if($Value -is [DateTime]){if($Value.Kind -ne [DateTimeKind]::Utc){throw 'Diagnostic time must be UTC.'}}
    elseif($Value -isnot [string] -or -not [DateTime]::TryParseExact($Value,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed) -or $parsed.Kind -ne [DateTimeKind]::Utc){throw 'Invalid diagnostic timestamp.'}
}

function Assert-KhcMacDecodeDiagnosticProtocol {
    param([Collections.IDictionary]$Spec)
    $root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
    $fixed=@{schema=1;protocol='khc-mac-decode-phase-build-v1';purpose='decode-phase-diagnostic';task='goal-restore-20261019';host='m3mb14';root=$root;base_source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';baseline_cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';archive_sha256='234de239da6302ac69ca564729f7658a10c42889a96b1f8796136ea3af9192ee';reference_terminal_sha256='88bcfebefe228162fe12c4434d0a6cf493d7d0b8c8f01b6ed6a745c2774a370e';supervisor_sha256='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30';setup_sha256='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1';build_verifier_sha256='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb';source_directory="$root/decode-phase-20261027/source";target="$root/cargo-target/decode-phase-20261027";toolchain='1.99.1-aarch64-apple-darwin';cargo_timeout_seconds=300;native_final_seconds=350;ssh_timeout_seconds=380;additional_target_max_bytes=536870912L;cargo_max_bytes=1073741824L;ordinary_max_bytes=1610612736L;total_max_bytes=2684354560L;superiority_decision_allowed=$false}
    Assert-KhcMacDecodeDiagnosticFields $Spec (@($fixed.Keys)+@('source_sha256','source_manifest_sha256','controller_sha256','generator_sha256','cargo_command'))
    foreach($key in $fixed.Keys){
        if($fixed[$key] -is [int] -or $fixed[$key] -is [long]){if(($Spec[$key] -isnot [int] -and $Spec[$key] -isnot [long]) -or $Spec[$key] -ne $fixed[$key]){throw "Diagnostic integer mismatch: $key"}}
        elseif($fixed[$key] -is [bool]){if($Spec[$key] -isnot [bool] -or $Spec[$key] -ne $fixed[$key]){throw 'Diagnostic decision flag mismatch.'}}
        elseif($Spec[$key] -isnot [string] -or $Spec[$key] -cne $fixed[$key]){throw "Diagnostic fixed identity mismatch: $key"}
    }
    foreach($key in @('source_sha256','source_manifest_sha256','controller_sha256','generator_sha256')){if($Spec[$key] -isnot [string] -or $Spec[$key] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Diagnostic SHA must be lowercase hex.'}}
    $command=@(Get-KhcMacDecodeDiagnosticCommand)
    if($Spec.cargo_command -isnot [array] -or $Spec.cargo_command.Count -ne $command.Count){throw 'Diagnostic command shape mismatch.'}
    for($i=0;$i -lt $command.Count;$i++){if($Spec.cargo_command[$i] -isnot [string] -or $Spec.cargo_command[$i] -cne $command[$i]){throw 'Diagnostic command mismatch.'}}
}

function Assert-KhcMacDecodeDiagnosticStart {
    param([Collections.IDictionary]$Start)
    Assert-KhcMacDecodeDiagnosticFields $Start @('schema','protocol','purpose','protocol_sha256','protocol_base64','spec','started_utc')
    if(($Start.schema -isnot [int] -and $Start.schema -isnot [long]) -or $Start.schema -ne 1 -or $Start.protocol -isnot [string] -or $Start.protocol -cne 'khc-mac-decode-diagnostic-start-v1' -or $Start.purpose -isnot [string] -or $Start.purpose -cne 'decode-phase-diagnostic' -or $Start.protocol_sha256 -isnot [string] -or $Start.protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $Start.spec -isnot [Collections.IDictionary]){throw 'Invalid diagnostic immutable start.'}
    Assert-KhcMacDecodeDiagnosticProtocol $Start.spec
    if($Start.protocol_base64 -isnot [string] -or $Start.protocol_base64.Length -gt 45000){throw 'Diagnostic protocol raw bound.'}
    $raw=[Convert]::FromBase64String($Start.protocol_base64)
    $parsed=ConvertFrom-KhcBoundedJsonSnapshot $raw $Start.protocol_sha256 32768
    if(-not (Test-KhcMacNativeE2eJsonEqual $parsed $Start.spec)){throw 'Diagnostic protocol raw differs from immutable spec.'}
    Assert-KhcMacDecodeDiagnosticUtc $Start.started_utc
}

function Assert-KhcMacDecodeDiagnosticTerminal {
    param([Collections.IDictionary]$Start,[Collections.IDictionary]$Receipt)
    Assert-KhcMacDecodeDiagnosticStart $Start
    Assert-KhcMacDecodeDiagnosticFields $Receipt @('schema','protocol','purpose','source_sha256','controller_sha256','protocol_sha256','root','target','cargo_command','status','exit','runtime_seconds','cargo_runtime_seconds','binary_sha256','binary_path','wait_confirmed','group_absent','postchecks_ok','closure_proof','closure_sha256','error')
    if(($Receipt.schema -isnot [int] -and $Receipt.schema -isnot [long]) -or $Receipt.schema -ne 1){throw 'Invalid diagnostic terminal schema.'}
    foreach($key in @('protocol','purpose','source_sha256','controller_sha256','root','target')){if($Receipt[$key] -isnot [string] -or $Receipt[$key] -cne $Start.spec[$key]){throw "Diagnostic terminal identity mismatch: $key"}}
    if($Receipt.protocol_sha256 -isnot [string] -or $Receipt.protocol_sha256 -cne $Start.protocol_sha256){throw 'Diagnostic protocol SHA mismatch.'}
    $command=@(Get-KhcMacDecodeDiagnosticCommand)
    if($Receipt.cargo_command -isnot [array] -or $Receipt.cargo_command.Count -ne $command.Count){throw 'Diagnostic terminal command shape mismatch.'}
    for($i=0;$i -lt $command.Count;$i++){if($Receipt.cargo_command[$i] -isnot [string] -or $Receipt.cargo_command[$i] -cne $command[$i]){throw 'Diagnostic terminal command mismatch.'}}
    foreach($key in @('wait_confirmed','group_absent','postchecks_ok')){if($Receipt[$key] -isnot [bool] -or ($key -cne 'postchecks_ok' -and -not $Receipt[$key])){throw 'Diagnostic closure remains unconfirmed; Cargo stays blocked.'}}
    foreach($key in @('runtime_seconds','cargo_runtime_seconds')){
        $value=$Receipt[$key];$limit=if($key -ceq 'runtime_seconds'){350}else{300}
        if(($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double] -and $value -isnot [decimal]) -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -lt 0 -or ($Receipt.status -ceq 'done' -and $value -gt $limit)){throw 'Diagnostic runtime outside fixed deadline.'}
    }
    if($Receipt.cargo_runtime_seconds -gt $Receipt.runtime_seconds -or ($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or $Receipt.exit -lt 0 -or $Receipt.exit -gt 255 -or $Receipt.status -isnot [string] -or $Receipt.status -cnotin @('done','failed') -or (($Receipt.status -ceq 'done') -ne ($Receipt.exit -eq 0))){throw 'Diagnostic terminal status mismatch.'}
    if($Receipt.status -ceq 'done' -and -not $Receipt.postchecks_ok){throw 'Successful diagnostic requires postchecks.'}
    if($Receipt.status -ceq 'done' -or $null -ne $Receipt.binary_sha256){if($Receipt.binary_sha256 -isnot [string] -or $Receipt.binary_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Diagnostic binary SHA invalid.'}}
    if($Receipt.binary_path -isnot [string] -or $Receipt.binary_path -cne "$($Start.spec.target)/aarch64-apple-darwin/release/examples/khc_archive_phase_diagnostic" -or $Receipt.closure_proof -isnot [Collections.IDictionary] -or $Receipt.closure_sha256 -isnot [string] -or $Receipt.closure_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or ($null -ne $Receipt.error -and ($Receipt.error -isnot [string] -or $Receipt.error.Length -gt 4096))){throw 'Diagnostic binary/closure/error shape invalid.'}
}

function Assert-KhcMacDecodeDiagnosticState {
    param([bool]$HasStart,[bool]$HasTerminal,$Terminal)
    if($HasTerminal -and -not $HasStart){throw 'Orphan diagnostic terminal.'}
    if($HasStart -and -not $HasTerminal){throw 'Unresolved diagnostic start blocks every Cargo invocation.'}
    if($HasTerminal){foreach($key in @('wait_confirmed','group_absent')){if($Terminal[$key] -isnot [bool] -or -not $Terminal[$key]){throw 'Diagnostic closure remains unknown.'}}}
}

function Get-KhcMacDecodeDiagnosticLedger {
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $startPath=Assert-KhcPlainPath (Join-Path $root 'mac-decode-diagnostic.started.json')
    $terminalPath=Assert-KhcPlainPath (Join-Path $root 'mac-decode-diagnostic.terminal.json')
    $start=$null;$terminal=$null
    if(Test-Path -LiteralPath $startPath){
        $start=Read-KhcRecycleV6PrivateJson $startPath;Assert-KhcMacDecodeDiagnosticStart $start
        $null=Invoke-KhcMacDecodeDiagnosticVerifier $start
    }
    if(Test-Path -LiteralPath $terminalPath){
        if($null -eq $start){throw 'Orphan diagnostic terminal.'}
        $seal=Read-KhcRecycleV6PrivateJson $terminalPath
        Assert-KhcMacDecodeDiagnosticFields $seal @('schema','protocol','receipt_sha256','receipt_base64','saved_utc')
        if(($seal.schema -isnot [int] -and $seal.schema -isnot [long]) -or $seal.schema -ne 1 -or $seal.protocol -isnot [string] -or $seal.protocol -cne 'khc-mac-decode-diagnostic-terminal-seal-v1' -or $seal.receipt_sha256 -isnot [string] -or $seal.receipt_base64 -isnot [string] -or $seal.receipt_base64.Length -gt 90000){throw 'Invalid diagnostic terminal seal.'}
        Assert-KhcMacDecodeDiagnosticUtc $seal.saved_utc
        $raw=[Convert]::FromBase64String($seal.receipt_base64)
        $terminal=ConvertFrom-KhcBoundedJsonSnapshot $raw $seal.receipt_sha256 65536
        Assert-KhcMacDecodeDiagnosticTerminal $start $terminal
        $null=Invoke-KhcMacDecodeDiagnosticVerifier $start $seal.receipt_base64
    }
    return [pscustomobject]@{Start=$start;Terminal=$terminal}
}

function Start-KhcMacDecodeDiagnostic {
    param([Collections.IDictionary]$Spec,[string]$ProtocolSha256,[string]$ProtocolBase64)
    Assert-KhcMacDecodeDiagnosticProtocol $Spec
    if($script:TaskId -cne 'goal-restore-20261019' -or $null -eq (Get-KhcMacRemoteReservation)){throw 'Diagnostic requires the fixed task and persistent remote reservation.'}
    Assert-KhcNoPendingStorageRuns;Assert-KhcNoPendingMacBuild
    $ledger=Get-KhcMacDecodeDiagnosticLedger
    if($null -ne $ledger.Start){throw 'Diagnostic purpose is one-shot, including failed attempts; source or target changes cannot retry.'}
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    $start=[ordered]@{schema=1;protocol='khc-mac-decode-diagnostic-start-v1';purpose='decode-phase-diagnostic';protocol_sha256=$ProtocolSha256;protocol_base64=$ProtocolBase64;spec=$Spec;started_utc=[DateTime]::UtcNow.ToString('o')}
    Assert-KhcMacDecodeDiagnosticStart $start
    $null=Invoke-KhcMacDecodeDiagnosticVerifier $start
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-decode-diagnostic.started.json') $start
}

function Save-KhcMacDecodeDiagnosticTerminal {
    param([byte[]]$ReceiptBytes)
    $ledger=Get-KhcMacDecodeDiagnosticLedger
    if($null -eq $ledger.Start -or $null -ne $ledger.Terminal){throw 'Diagnostic terminal requires one unresolved immutable start.'}
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    $receipt=ConvertFrom-KhcBoundedJsonSnapshot $ReceiptBytes $sha 65536
    Assert-KhcMacDecodeDiagnosticTerminal $ledger.Start $receipt
    $receiptBase64=[Convert]::ToBase64String($ReceiptBytes)
    $null=Invoke-KhcMacDecodeDiagnosticVerifier $ledger.Start $receiptBase64
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-decode-diagnostic.terminal.json') ([ordered]@{schema=1;protocol='khc-mac-decode-diagnostic-terminal-seal-v1';receipt_sha256=$sha;receipt_base64=$receiptBase64;saved_utc=[DateTime]::UtcNow.ToString('o')})
}

function Get-KhcMacDecodeVerifierBundleSpec {
    param([string]$ControllerSha256)
    # 履歴で承認済みのSHAだけを選ぶ。receiptや公開pathを保存先として受け取らない。
    if($ControllerSha256 -cne 'da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc'){throw 'Unknown immutable diagnostic verifier SHA.'}
    return [pscustomobject]@{
        Directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-decode-verifier-da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc')
        Pins=@{'mac-decode-phase-build.py'='da3ba8ba569bd4335776b9276ce1eb42cea4412ba4aa65e77545d59ebfec2cbc';'mac-finite-supervisor.py'='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30';'mac-native-build.py'='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb';'mac-canterbury-reference.py'='a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4'}
    }
}

function Assert-KhcMacDecodeVerifierBundleInventory {
    param([string]$ControllerSha256,[object[]]$Entries)
    $spec=Get-KhcMacDecodeVerifierBundleSpec $ControllerSha256
    if($Entries.Count -ne $spec.Pins.Count){throw 'Immutable verifier bundle file set mismatch.'}
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($entry in $Entries){
        if($entry.Name -isnot [string] -or -not $spec.Pins.ContainsKey($entry.Name) -or -not $names.Add($entry.Name) -or $entry.IsDirectory -isnot [bool] -or $entry.IsDirectory -or $entry.IsReparsePoint -isnot [bool] -or $entry.IsReparsePoint -or $entry.Sha256 -isnot [string] -or $entry.Sha256 -cne $spec.Pins[$entry.Name]){throw 'Immutable verifier bundle entry type/hash mismatch.'}
    }
}

function Get-KhcMacDecodeVerifierBundle {
    param([string]$ControllerSha256)
    $spec=Get-KhcMacDecodeVerifierBundleSpec $ControllerSha256
    $directory=Assert-KhcPlainPath $spec.Directory
    if(-not [IO.Directory]::Exists($directory)){throw 'Required immutable diagnostic verifier bundle is missing; no current-source fallback.'}
    $entries=@(foreach($file in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop){
        $path=Assert-KhcPlainPath $file.FullName
        [pscustomobject]@{Name=$file.Name;IsDirectory=[bool]$file.PSIsContainer;IsReparsePoint=[bool]($file.Attributes -band [IO.FileAttributes]::ReparsePoint);Sha256=$(if($file.PSIsContainer){$null}else{Get-KhcRecycleV6Hash $path})}
    })
    Assert-KhcMacDecodeVerifierBundleInventory $ControllerSha256 $entries
    return $spec
}

function Initialize-KhcVerifierDirectoryHandle {
    if(-not ('Khc.Storage.VerifierDirectoryHandle' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Khc.Storage {
 public static class VerifierDirectoryHandle {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
   public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
  [DllImport("kernel32.dll", SetLastError=true)] static extern uint GetFileType(SafeFileHandle file);
  public static void ValidateLeafAttributes(uint attributes,uint links,uint fileType) {
   if(fileType!=1 || (attributes&0x410)!=0 || links!=1)
    throw new InvalidOperationException("Verifier leaf must be a regular, non-reparse, single-link disk file.");
  }
  public static System.IO.FileStream OpenLeaf(string path) {
   var handle=CreateFileW(path,0x80000000,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
   if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
   try {
    Info info;
    if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
    ValidateLeafAttributes(info.Attributes,info.Links,GetFileType(handle));
    return new System.IO.FileStream(handle,System.IO.FileAccess.Read);
   } catch {handle.Dispose();throw;}
  }
  public static SafeFileHandle Open(string path,uint access=1) {
   var handle=CreateFileW(path,access,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
   if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
   Info info;
   if(!GetFileInformationByHandle(handle,out info)){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}
   if((info.Attributes&0x400)!=0 || (info.Attributes&0x10)==0){handle.Dispose();throw new InvalidOperationException("Verifier directory is a reparse point or non-directory.");}
   return handle;
  }
 }
}
'@
    }
}

function Enter-KhcMacDecodeVerifierReadLease {
    param($Bundle)
    Initialize-KhcVerifierDirectoryHandle
    $taskRoot=Assert-KhcPlainPath (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019')
    $directory=Assert-KhcPlainPath $Bundle.Directory
    if([IO.Path]::GetDirectoryName($directory) -cne $taskRoot){throw 'Verifier bundle must be a direct child of the dedicated task root.'}
    $handles=[Collections.Generic.List[IDisposable]]::new()
    try{
        # 共有の上位フォルダー（ドライブrootやTEMP\UnLhaRe基点など）は保持しない。task専用root以下だけrename/writeを抑止する。
        foreach($path in @($taskRoot,$directory)){
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value -cne $sid){throw 'Verifier task/bundle owner mismatch.'}
            $handles.Add([Khc.Storage.VerifierDirectoryHandle]::Open($path))
        }
        $files=@(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop)
        if($files.Count -ne $Bundle.Pins.Count){throw 'Verifier lease file set mismatch.'}
        foreach($file in $files){
            if($file.PSIsContainer -or -not $Bundle.Pins.ContainsKey($file.Name)){throw 'Verifier lease unexpected entry.'}
            $path=Assert-KhcPlainPath $file.FullName
            # no-followで開いた同HANDLEの属性・link数・SHAを検証し、子終了まで保持する。
            $stream=[Khc.Storage.VerifierDirectoryHandle]::OpenLeaf($path)
            $handles.Add($stream)
            if($stream.Length -gt 131072){throw 'Verifier lease input bound.'}
            $hasher=[Security.Cryptography.SHA256]::Create()
            try{$sha=[Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant()}finally{$hasher.Dispose()}
            if($sha -cne $Bundle.Pins[$file.Name]){throw 'Verifier lease SHA mismatch on held handle.'}
            $stream.Position=0
        }
        return ,$handles
    }catch{for($i=$handles.Count-1;$i -ge 0;$i--){$handles[$i].Dispose()};throw}
}

function Invoke-KhcMacDecodeDiagnosticVerifier {
    param([Collections.IDictionary]$Start,[string]$ReceiptBase64='')
    Assert-KhcVerifierQuarantineClear
    Assert-KhcMacDecodeDiagnosticStart $Start
    $bundle=Get-KhcMacDecodeVerifierBundle $Start.spec.controller_sha256
    $directory=$bundle.Directory
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-I','-B',(Join-Path $directory 'mac-decode-phase-build.py'))){$info.ArgumentList.Add($arg)}
    if($ReceiptBase64){
        if($ReceiptBase64.Length -gt 90000){throw 'Diagnostic receipt base64 bound.'}
        foreach($arg in @('--verify-receipt-base64',$ReceiptBase64,'--protocol-base64',$Start.protocol_base64)){$info.ArgumentList.Add($arg)}
    }else{foreach($arg in @('--verify-protocol-base64',$Start.protocol_base64,'--protocol-sha',$Start.protocol_sha256)){$info.ArgumentList.Add($arg)}}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$spawned=$false;$readLease=$null
    try{
        $readLease=Enter-KhcMacDecodeVerifierReadLease $bundle
        $scan=Get-KhcChargeScanContext
        $scanKey=Get-KhcChargeScanKey 'Invoke-KhcMacDecodeDiagnosticVerifier' @($info.ArgumentList) ((@($bundle.Pins.Keys | Sort-Object -CaseSensitive | ForEach-Object {$_+'='+$bundle.Pins[$_]}) -join "`n"))
        if($null -ne $scan -and $scan.Results.ContainsKey($scanKey)){return (Copy-KhcChargeScanSummary $scan.Results[$scanKey])}
        if(-not $process.Start()){throw 'Diagnostic verifier did not start.'};$spawned=$true
        $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(2048),[char[]]::new(2048));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
        $tasks=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048));$done=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
        while($true){
            for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){$count=$tasks[$side].GetAwaiter().GetResult();if($count -eq 0){$done[$side]=$true}else{if($logs[$side].Length+$count -gt 16384){throw 'Diagnostic verifier output bound.'};$null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,2048)}}}
            if($timer.Elapsed.TotalSeconds -gt 15){throw 'Diagnostic pure verifier timeout.'}
            if($process.HasExited -and $done[0] -and $done[1]){break};Start-Sleep -Milliseconds 25
        }
        if($process.ExitCode -ne 0 -or $logs[1].Length -ne 0){throw 'Diagnostic native pure validation failed.'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($logs[0].ToString());$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $summary=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 16384
        Assert-KhcMacDecodeDiagnosticSummary $summary $Start $ReceiptBase64
        if($null -ne $scan){
            $scan.Results[$scanKey]=Copy-KhcChargeScanSummary $summary
            $scan.Leases.Add($readLease);$readLease=$null
        }
        return $summary
    }finally{Complete-KhcVerifierReadLease $process $spawned $readLease}
}

function Assert-KhcMacDecodeDiagnosticSummary {
    param([Collections.IDictionary]$Summary,[Collections.IDictionary]$Start,[string]$ReceiptBase64='')
    Assert-KhcMacDecodeDiagnosticStart $Start
    $fields=@('schema','protocol','protocol_sha256','source_sha256','controller_sha256','purpose','verified')
    if($ReceiptBase64){$fields+=@('receipt_sha256','binary_sha256','closure_sha256','status','exit','cleanup_allowed')}
    Assert-KhcMacDecodeDiagnosticFields $Summary $fields
    if(($Summary.schema -isnot [int] -and $Summary.schema -isnot [long]) -or $Summary.schema -ne 1 -or $Summary.verified -isnot [bool] -or -not $Summary.verified -or $Summary.protocol_sha256 -isnot [string] -or $Summary.protocol_sha256 -cne $Start.protocol_sha256){throw 'Diagnostic verifier summary identity.'}
    foreach($key in @('protocol','source_sha256','controller_sha256','purpose')){if($Summary[$key] -isnot [string] -or $Summary[$key] -cne $Start.spec[$key]){throw 'Diagnostic verifier summary binding.'}}
    if($ReceiptBase64){
        $raw=[Convert]::FromBase64String($ReceiptBase64);$rawSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot $raw $rawSha 65536
        Assert-KhcMacDecodeDiagnosticTerminal $Start $receipt
        foreach($key in @('binary_sha256','closure_sha256','status','exit')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $receipt[$key])){throw 'Diagnostic verifier receipt summary binding.'}}
        if($Summary.receipt_sha256 -isnot [string] -or $Summary.receipt_sha256 -cne $rawSha -or $Summary.cleanup_allowed -isnot [bool] -or -not $Summary.cleanup_allowed){throw 'Diagnostic verifier closure is not confirmed; pending remains.'}
    }
}

function Start-KhcMacNativeBuildStage {
    param([string]$Stage,[string]$SourceSha256,[string]$ScriptSha256,[string]$AmendmentSha256='')
    # 呼出元run-mac-native-build.ps1がCargo leaseを保持している間だけ使用する。
    if($script:TaskId -cne 'goal-restore-20261019' -or $null -eq (Get-KhcMacRemoteReservation)){throw 'Mac build requires the fixed task and initialized remote reservation.'}
    Assert-KhcNoPendingStorageRuns
    Assert-KhcNoPendingMacBuild
    $entries=@(Get-KhcMacBuildLedger)
    if($entries.Count -eq 0 -and $Stage -cne 'prepare-source'){throw 'First Mac stage must be prepare-source.'}
    foreach($entry in $entries){
        if($entry.Stage -ceq $Stage){throw 'Mac build stage is one-shot; an immutable start already exists.'}
        if($entry.Start.source_sha256 -cne $SourceSha256){throw 'Mac build source identity cannot change.'}
    }
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    $directory=Assert-KhcPlainPath (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-native-build')
    $record=[ordered]@{schema=1;protocol='khc-mac-native-build-v1';stage=$Stage;source_sha256=$SourceSha256;script_sha256=$ScriptSha256;host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';started_utc=[DateTime]::UtcNow.ToString('o')}
    if($AmendmentSha256){$record.amendment_sha256=$AmendmentSha256}
    Assert-KhcMacBuildStartData $record
    if($entries.Count){$activation=Read-KhcRecycleV6PrivateJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-native-build-activation.json');Assert-KhcMacBuildBindingData $record $activation (Get-KhcMacBuildAmendment)}
    if($entries.Count -eq 0){
        $activation=[ordered]@{schema=1;protocol='khc-mac-native-build-activation-v1';source_sha256=$SourceSha256;script_sha256=$ScriptSha256;host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';activated_utc=[DateTime]::UtcNow.ToString('o')}
        Assert-KhcMacBuildActivationData $activation
        Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-native-build-activation.json') $activation
    }
    $recordHash=Get-KhcRecycleV6TextHash (ConvertTo-Json -InputObject $record -Depth 12)
    $intent=[ordered]@{schema=1;protocol='khc-mac-native-build-intent-v1';stage=$Stage;source_sha256=$SourceSha256;script_sha256=$ScriptSha256;host=$record.host;root=$record.root;started_sha256=$recordHash}
    if($AmendmentSha256){$intent.amendment_sha256=$AmendmentSha256}
    Assert-KhcMacBuildIntentData $intent $record $recordHash
    Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) "mac-native-build-$Stage-intent.json") $intent
    $null=[IO.Directory]::CreateDirectory($directory)
    $null=Assert-KhcRecycleV6PrivatePath $directory
    Write-KhcNewJson (Join-Path $directory "$Stage.started.json") $record
}

function Save-KhcMacNativeBuildTerminal {
    param([string]$Stage,[Collections.IDictionary]$Receipt)
    $entry=@(Get-KhcMacBuildLedger | Where-Object {$_.Stage -ceq $Stage})
    if($entry.Count -ne 1 -or $null -ne $entry[0].Terminal){throw 'Mac build terminal requires one unresolved immutable stage.'}
    Assert-KhcMacBuildTerminalData $entry[0].Start $Receipt
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
    $directory=Assert-KhcRecycleV6PrivatePath (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-native-build')
    $terminal=[ordered]@{schema=1;protocol='khc-mac-native-build-v1';stage=$Stage;receipt=$Receipt;completed_utc=[DateTime]::UtcNow.ToString('o')}
    if($entry[0].Start.Contains('amendment_sha256')){$terminal.amendment_sha256=$entry[0].Start.amendment_sha256}
    Write-KhcNewJson (Join-Path $directory "$Stage.terminal.json") $terminal
}

function Resolve-KhcMacNativeBuildStage {
    param([Parameter(Mandatory)][ValidateSet('prepare-source','fetch','check','build')][string]$Stage,[Parameter(Mandatory)][string]$TerminalJson)
    # 通信断後、同じremote journalの終端と子孫不在を確認した親だけが明示実行する。
    $root=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $state=[IO.Path]::GetDirectoryName($root);$registrationLease=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        Assert-KhcNoPendingStorageRuns
        if($TerminalJson.Length -gt 1MB){throw 'Remote terminal JSON exceeds the bounded receipt size.'}
        Save-KhcMacNativeBuildTerminal $Stage (ConvertFrom-Json -InputObject $TerminalJson -AsHashtable)
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Read-KhcBoundedSnapshotBytes {
    param([string]$Path,[int]$Maximum=65536)
    $path=Assert-KhcPlainPath $Path
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length -gt $Maximum){throw 'Snapshot exceeds its byte bound.'}
        $buffer=[byte[]]::new($Maximum+1);$length=0
        while($true){$n=$stream.Read($buffer,$length,$buffer.Length-$length);if($n -eq 0){break};$length+=$n;if($length -gt $Maximum){throw 'Snapshot grew beyond its byte bound.'}}
        $bytes=[byte[]]::new($length);[Buffer]::BlockCopy($buffer,0,$bytes,0,$length)
    }finally{$stream.Dispose()}
    $null=Assert-KhcPlainPath $path
    return ,$bytes
}

function ConvertFrom-KhcBoundedJsonSnapshot {
    param([byte[]]$Bytes,[string]$ExpectedSha256,[int]$Maximum=65536)
    if($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt $Maximum -or $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() -cne $ExpectedSha256){throw 'JSON snapshot bound/SHA mismatch.'}
    $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $document=[Text.Json.JsonDocument]::Parse($text,[Text.Json.JsonDocumentOptions]::new())
    try{
        if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){throw 'JSON snapshot must be an object.'}
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $document.RootElement.EnumerateObject()){if(-not $names.Add($property.Name)){throw 'Duplicate JSON snapshot key.'}}
    }finally{$document.Dispose()}
    return ConvertFrom-Json -InputObject $text -AsHashtable
}

function ConvertFrom-KhcMacNativeInvocationSnapshot {
    param([byte[]]$Bytes,[string]$ExpectedSha256,[ValidateSet('native-e2e','reference','candidate-e2e')][string]$Class='native-e2e')
    if($null -eq $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -gt 32768 -or $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() -cne $ExpectedSha256){throw 'Child invocation snapshot bound/approved SHA mismatch.'}
    $xml=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $invocation=[Management.Automation.PSSerializer]::Deserialize($xml)
    $worker=if($Class -ceq 'reference'){'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-canterbury-reference.ps1'}else{'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-spatial-mdl-e2e.ps1'}
    $protocolPath=if($Class -ceq 'reference'){(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-reference-protocol.json')}else{(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-e2e-ps-free-protocol.json')}
    if($Class -ceq 'candidate-e2e'){$kind=Get-KhcMacCandidateE2eKind;$worker=$kind.Worker;$protocolPath=$kind.ProtocolPath}
    if($Class -ceq 'reference' -and $invocation.script -ceq 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-canterbury-continuous-reference.ps1'){$kind=Get-KhcMacReferenceKind 'khc-mac-canterbury-continuous-reference-v1';$worker=$kind.Worker;$protocolPath=$kind.ProtocolPath}
    # WorkDirectory はユーザー既定TEMP\UnLhaRe\work\goal-restore-20261019\run-<GUID> だけを許可する（旧Dドライブ固定の作業フォルダー運用は廃止）。
    $workPattern='\A'+[regex]::Escape((Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\run-'))+'[0-9a-f]{32}\z'
    if(@($invocation.PSObject.Properties).Count -ne 2 -or $invocation.script -cne $worker -or $invocation.parameters -isnot [Collections.IDictionary] -or $invocation.parameters.Count -ne 3 -or @($invocation.parameters.Keys | Where-Object {$_ -cnotin @('WorkDirectory','ProtocolPath','ProtocolSha256')}).Count -or [string]$invocation.parameters.WorkDirectory -cnotmatch $workPattern -or $invocation.parameters.ProtocolPath -cne $protocolPath -or [string]$invocation.parameters.ProtocolSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Approved typed remote invocation shape/worker mismatch.'}
    return $invocation
}

function Get-KhcMacNativeE2eChildCommand {
    param([string]$InvocationSha256,[ValidateSet('native-e2e','reference','candidate-e2e')][string]$Class='native-e2e')
    if($InvocationSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Native child expected SHA must be a trusted lowercase literal.'}
    # literalはprivate registration由来のhexだけ。公開invocationはchild側の単一snapshotで検証する。
    $command=@'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$ErrorActionPreference='Stop'
$gate=[Threading.EventWaitHandle]::OpenExisting($env:KHC_STORAGE_START_EVENT)
try {if(-not $gate.WaitOne(10000)){throw 'Job assignment timeout'}}finally{$gate.Dispose()}
Import-Module 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\storage-lifecycle.psm1' -Force
$inv=& (Get-Module storage-lifecycle) {
    $bytes=Read-KhcBoundedSnapshotBytes $env:KHC_STORAGE_INVOCATION 32768
    ConvertFrom-KhcMacNativeInvocationSnapshot $bytes '__INVOCATION_SHA__' '__CLASS__'
}
$params=$inv.parameters
if('__CLASS__' -ceq 'candidate-e2e'){
    $trust=& (Get-Module storage-lifecycle) {param($path,$sha)(Read-KhcMacCandidateE2eProtocol $path $sha).Trust} $params.ProtocolPath $params.ProtocolSha256
    $held=& (Get-Module storage-lifecycle) {param($trust) Enter-KhcMacDecodeVerifierReadLease $trust} $trust
    $workerExit=0
    try{& $trust.WorkerPath @params;$workerExit=$LASTEXITCODE}finally{for($i=$held.Count-1;$i -ge 0;$i--){$held[$i].Dispose()}}
    exit ([int]$workerExit)
}else{& $inv.script @params}
'@
    return $command.Replace('__INVOCATION_SHA__',$InvocationSha256).Replace('__CLASS__',$Class)
}

function Assert-KhcRemoteReferenceClassData {
    param([bool]$E2eRequired,[bool]$ReferenceRequired,[bool]$CandidateE2eRequired=$false)
    if(([int]$E2eRequired+[int]$ReferenceRequired+[int]$CandidateE2eRequired) -gt 1){throw 'A run can require exactly one remote terminal class.'}
    if($CandidateE2eRequired){return 'candidate-e2e'}
    if($ReferenceRequired){return 'reference'}
    if($E2eRequired){return 'native-e2e'}
    return 'none'
}

function Get-KhcMacCandidateE2eKind {
    return [pscustomobject]@{Worker='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-cdf-candidate-e2e.ps1';ProtocolPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-e2e-protocol.json');Protocol='khc-mac-cdf-candidate-e2e-v1'}
}

function Get-KhcMacCandidateRecoveryE2eKind {
    # schemaの識別子であり、この情報だけでは登録や実行を認可しない。
    return [pscustomobject]@{
        Worker='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\candidate-e2e-recovery\mac-cdf-candidate-e2e-recovery.ps1'
        ProtocolPath=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-e2e-recovery-protocol.json')
        ProtocolSha256='95cbd4db2f793720b4612a36bc50525fc5bd00cb6c1e44b0586e5f1e78f0c148'
        EndpointSha256='18471c7bad1c36f56220838dda491c5769cdb5a98e152644049f861e05e479e2'
        OldRunId='8fd4b003ba9e406da5a21b9be5a37c56'
        WindowsBindingSha256='af044113e2f841728f8da01095b3ae6bdeb7018b7f1730046f88129ba0596a9f'
        Protocol='khc-mac-cdf-candidate-e2e-recovery-v1'
    }
}

function Assert-KhcMacCandidateRecoveryRegistrationData {
    param([Collections.IDictionary]$Registration,[Collections.IDictionary]$Claim,[Collections.IDictionary]$Reserve,
        [string]$RunId,[string]$RecordSha256,[string]$InvocationSha256,[string]$WorkerSha256)
    $kind=Get-KhcMacCandidateRecoveryE2eKind
    $regKeys=@('schema','protocol','run_id','record_sha256','invocation_sha256','old_run_id','windows_binding_sha256','amendment_sha256','fence_proof_sha256','protocol_sha256','worker_sha256')
    $claimKeys=@('schema','protocol','run_id','record_sha256','old_run_id','amendment_sha256','fence_proof_sha256')
    if($null -eq $Registration -or $null -eq $Claim -or $null -eq $Reserve -or
       $Registration.Count -ne $regKeys.Count -or @($Registration.Keys | Where-Object {$_ -cnotin $regKeys}).Count -or
       $Claim.Count -ne $claimKeys.Count -or @($Claim.Keys | Where-Object {$_ -cnotin $claimKeys}).Count){throw 'Recovery registration/claim fields mismatch.'}
    foreach($key in $regKeys | Where-Object {$_ -cne 'schema'}){if($Registration[$key] -isnot [string]){throw 'Recovery registration string type mismatch.'}}
    foreach($key in $claimKeys | Where-Object {$_ -cne 'schema'}){if($Claim[$key] -isnot [string]){throw 'Recovery claim string type mismatch.'}}
    foreach($key in @('run_id','registration_sha256')){if($Reserve[$key] -isnot [string]){throw 'Recovery reservation string type mismatch.'}}
    if($RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $RunId -ceq $kind.OldRunId){throw 'Recovery requires a distinct typed run ID.'}
    foreach($sha in @($RecordSha256,$InvocationSha256,$WorkerSha256,$Registration.amendment_sha256,$Registration.fence_proof_sha256)){
        if($sha -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Recovery SHA format mismatch.'}
    }
    if(($Registration.schema -isnot [int] -and $Registration.schema -isnot [long]) -or $Registration.schema -ne 1 -or
       ($Claim.schema -isnot [int] -and $Claim.schema -isnot [long]) -or $Claim.schema -ne 1 -or
       $Registration.protocol -cne 'khc-mac-cdf-candidate-recovery-registration-v1' -or $Claim.protocol -cne 'khc-mac-cdf-candidate-recovery-claim-v1' -or
       $Registration.run_id -cne $RunId -or $Claim.run_id -cne $RunId -or $Reserve.run_id -cne $RunId -or
       $Registration.record_sha256 -cne $RecordSha256 -or $Claim.record_sha256 -cne $RecordSha256 -or $Reserve.registration_sha256 -cne $RecordSha256 -or
       $Registration.invocation_sha256 -cne $InvocationSha256 -or $Registration.worker_sha256 -cne $WorkerSha256 -or
       $Registration.old_run_id -cne $kind.OldRunId -or $Claim.old_run_id -cne $kind.OldRunId -or
       $Registration.windows_binding_sha256 -cne $kind.WindowsBindingSha256 -or $Registration.protocol_sha256 -cne $kind.ProtocolSha256 -or
       $Claim.amendment_sha256 -cne $Registration.amendment_sha256 -or $Claim.fence_proof_sha256 -cne $Registration.fence_proof_sha256 -or
       ($Reserve.max_bytes -isnot [int] -and $Reserve.max_bytes -isnot [long]) -or $Reserve.max_bytes -ne 8MB -or
       ($Reserve.max_entries -isnot [int] -and $Reserve.max_entries -isnot [long]) -or $Reserve.max_entries -ne 96 -or
       $Reserve.remote_candidate_recovery_required -isnot [bool] -or -not $Reserve.remote_candidate_recovery_required){throw 'Recovery registration, claim or reserve binding mismatch.'}
}

function Assert-KhcMacCandidateRecoveryReceiptData {
    param([Collections.IDictionary]$Receipt,[Collections.IDictionary]$Registration,[byte[]]$ReceiptBytes)
    # endpoint純粋verifierの実summaryを照合する。入力summary自体を認証・sealには使わない。
    $kind=Get-KhcMacCandidateRecoveryE2eKind
    $keys=@('schema','protocol','verified','content_verified','verification_scope','recovery_authorized','native_execution_enabled','protocol_sha256','endpoint_sha256','source_sha256','purpose','windows_run_id','windows_registration_sha256','receipt_sha256','report_sha256','closure_sha256','status','exit','cleanup_allowed')
    if($null -eq $Receipt -or $null -eq $Registration){throw 'Recovery summary and registration required.'}
    foreach($key in @('protocol','verification_scope','protocol_sha256','endpoint_sha256','source_sha256','purpose','windows_run_id','windows_registration_sha256','receipt_sha256','status')){
        if($Receipt[$key] -isnot [string]){throw 'Recovery receipt string type mismatch.'}
    }
    foreach($key in @('run_id','record_sha256')){if($Registration[$key] -isnot [string]){throw 'Recovery registration string type mismatch.'}}
    if($null -eq $Receipt -or $null -eq $Registration -or $null -eq $ReceiptBytes -or $ReceiptBytes.Length -lt 1 -or $ReceiptBytes.Length -gt 131072 -or
       $Receipt.Count -ne $keys.Count -or @($Receipt.Keys | Where-Object {$_ -cnotin $keys}).Count -or
       ($Receipt.schema -isnot [int] -and $Receipt.schema -isnot [long]) -or $Receipt.schema -ne 1 -or
       $Receipt.protocol -cne $kind.Protocol -or $Receipt.verified -isnot [bool] -or $Receipt.verified -or
       $Receipt.content_verified -isnot [bool] -or -not $Receipt.content_verified -or $Receipt.verification_scope -cne 'receipt-content-only' -or
       $Receipt.recovery_authorized -isnot [bool] -or $Receipt.recovery_authorized -or $Receipt.native_execution_enabled -isnot [bool] -or $Receipt.native_execution_enabled -or
       $Receipt.cleanup_allowed -isnot [bool] -or $Receipt.cleanup_allowed -or $Receipt.protocol_sha256 -cne $kind.ProtocolSha256 -or
       $Receipt.endpoint_sha256 -cne $kind.EndpointSha256 -or $Receipt.source_sha256 -cne '36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05' -or
       $Receipt.purpose -cne 'candidate-example-correctness-only' -or $Receipt.windows_run_id -cne $Registration.run_id -or
       $Receipt.windows_registration_sha256 -cne $Registration.record_sha256 -or
       ($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or
       !(($Receipt.status -ceq 'done' -and $Receipt.exit -eq 0) -or ($Receipt.status -ceq 'failed' -and $Receipt.exit -eq 1))){throw 'Recovery content summary invalid or exceeds its authority.'}
    foreach($key in @('report_sha256','closure_sha256')){if($null -ne $Receipt[$key] -and ($Receipt[$key] -isnot [string] -or $Receipt[$key] -cnotmatch '\A[0-9a-f]{64}\z')){throw 'Recovery summary optional SHA invalid.'}}
    if($Receipt.status -ceq 'done' -and ($null -eq $Receipt.report_sha256 -or $null -eq $Receipt.closure_sha256)){throw 'Successful recovery summary requires report and closure SHA.'}
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    if($Receipt.receipt_sha256 -isnot [string] -or $Receipt.receipt_sha256 -cne $sha){throw 'Recovery receipt raw SHA mismatch.'}
}

function Assert-KhcMacCandidateRecoveryPendingData {
    param([object[]]$PendingRunIds,[string]$CurrentRunId,[string]$WindowsBindingSha256)
    # 検出済みID集合の型と範囲のみ。旧証拠の読取やlive fenceの代用にはならない。
    $kind=Get-KhcMacCandidateRecoveryE2eKind
    if($CurrentRunId -cnotmatch '\A[0-9a-f]{32}\z' -or $CurrentRunId -ceq $kind.OldRunId -or
       $WindowsBindingSha256 -cne $kind.WindowsBindingSha256 -or $null -eq $PendingRunIds -or $PendingRunIds.Count -ne 2){throw 'Recovery pending set identity mismatch.'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($id in $PendingRunIds){
        if($id -isnot [string] -or $id -cnotmatch '\A[0-9a-f]{32}\z' -or -not $seen.Add($id) -or
           $id -cnotin @($kind.OldRunId,$CurrentRunId)){throw 'Unexpected or duplicate pending run.'}
    }
    if(-not $seen.Contains($kind.OldRunId) -or -not $seen.Contains($CurrentRunId)){throw 'Required pending run missing.'}
}

function Get-KhcCandidateRunnerDeadlineFailureBytes {
    param([byte[]]$OriginalBytes,[string]$RunId,[double]$ElapsedSeconds)
    if($RunId -cnotmatch '\A[0-9a-f]{32}\z' -or [double]::IsNaN($ElapsedSeconds) -or [double]::IsInfinity($ElapsedSeconds) -or $ElapsedSeconds -le 360 -or $OriginalBytes.Length -gt 8192){throw 'Candidate deadline failure input invalid.'}
    $document=[Text.Json.JsonDocument]::Parse([ReadOnlyMemory[byte]]::new($OriginalBytes))
    $memory=[IO.MemoryStream]::new();$writer=[Text.Json.Utf8JsonWriter]::new($memory)
    try{
        $root=$document.RootElement
        if($root.ValueKind -ne [Text.Json.JsonValueKind]::Object -or $root.GetProperty('schema').GetInt32() -ne 1 -or $root.GetProperty('run_id').GetString() -cne $RunId -or $root.GetProperty('status').GetString() -cnotin @('succeeded','failed')){throw 'Candidate result belongs to another attempt or state.'}
        $allowed=@('schema','run_id','status','runner_sha256','runner_sha256_at_finish','started_utc','finished_utc','child_started','child_pid','child_exit_code','stdout_eof','stderr_eof','job_active_after_exit','cleanup_request_created','failure_message')
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($property in $root.EnumerateObject()){if($property.Name -cnotin $allowed -or -not $seen.Add($property.Name)){throw 'Candidate runner result fields invalid.'}}
        if($seen.Count -ne $allowed.Count){throw 'Candidate runner result incomplete.'}
        $deadline='Candidate E2E Windows envelope exceeded 360 seconds during runner-result persistence.'
        $old=$root.GetProperty('failure_message');$message=if($old.ValueKind -eq [Text.Json.JsonValueKind]::Null){$deadline}else{$old.GetString()}
        if(-not $message.Contains($deadline)){$message+="; $deadline"}
        $message=$message.Substring(0,[math]::Min(4096,$message.Length))
        $writer.WriteStartObject()
        foreach($property in $root.EnumerateObject()){
            if($property.Name -ceq 'status'){$writer.WriteString('status','failed')}
            elseif($property.Name -ceq 'failure_message'){$writer.WriteString('failure_message',$message)}
            else{$property.WriteTo($writer)}
        }
        $writer.WriteEndObject();$writer.Flush();$bytes=$memory.ToArray()
        if($bytes.Length -gt 8192){throw 'Candidate failed result exceeds fixed bound.'}
        return ,$bytes
    }finally{$writer.Dispose();$memory.Dispose();$document.Dispose()}
}

function Merge-KhcCandidateRunnerDeadlineFailure {
    param($Failure,$Timer)
    $elapsed=[double]$Timer.Elapsed.TotalSeconds
    if([double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or $elapsed -lt 0){throw 'Candidate runner clock invalid.'}
    if($elapsed -le 360){return $Failure}
    $deadline=[TimeoutException]::new('Candidate E2E Windows envelope exceeded 360 seconds before runner-result construction.')
    if($null -eq $Failure){return $deadline}
    $original=if($Failure -is [Management.Automation.ErrorRecord]){$Failure.Exception}else{$Failure}
    return [AggregateException]::new('Candidate E2E original failure and deadline exceeded.',[Exception[]]@($original,$deadline))
}

function Assert-KhcCandidateSpawnBudget {
    param($Timer)
    $elapsed=[double]$Timer.Elapsed.TotalSeconds
    # native300 + SSH接続10 + Windows回収/seal/保存20を予約。既存350/360上限は維持する。
    if([double]::IsNaN($elapsed) -or [double]::IsInfinity($elapsed) -or $elapsed -lt 0 -or 360-$elapsed -lt 330){throw 'Candidate E2E requires 330 seconds remaining before child admission.'}
}

function Publish-KhcCandidateRunnerResult {
    param([Collections.IDictionary]$Result,$Timer,[scriptblock]$WriteInitial,[scriptblock]$WriteDeadlineFailure)
    $before=[double]$Timer.Elapsed.TotalSeconds
    if([double]::IsNaN($before) -or [double]::IsInfinity($before) -or $before -lt 0){throw 'Candidate runner clock invalid.'}
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -Compress -Depth 8 -InputObject $Result))
    if($bytes.Length -gt 8192){throw 'Candidate runner result bound exceeded.'}
    if($before -gt 360){$bytes=Get-KhcCandidateRunnerDeadlineFailureBytes $bytes $Result.run_id $before}
    $initialError=$null;$completionError=$null
    try{& $WriteInitial $bytes}catch{$initialError=$_.Exception}
    finally{
        # 全文write後のFlush/Dispose例外も、この同じ保存後検査を必ず通す。
        try{
            $after=[double]$Timer.Elapsed.TotalSeconds
            if([double]::IsNaN($after) -or [double]::IsInfinity($after) -or $after -lt $before){throw 'Candidate runner clock regressed after persistence.'}
            if($after -gt 360){
                $failed=Get-KhcCandidateRunnerDeadlineFailureBytes $bytes $Result.run_id $after
                & $WriteDeadlineFailure $bytes $failed $after
                $completionError=[TimeoutException]::new('Candidate E2E runner result persisted after 360 seconds; durable failed outcome recorded.')
            }
        }catch{$completionError=$_.Exception}
    }
    if($null -ne $initialError){
        if($null -ne $completionError){throw [AggregateException]::new('Candidate runner initial persistence and post-save completion both failed.',[Exception[]]@($initialError,$completionError))}
        throw $initialError
    }
    if($null -ne $completionError){throw $completionError}
}

function Set-KhcCandidateRunnerDeadlineFailure {
    param($Context,[byte[]]$OriginalBytes,[byte[]]$FailedBytes,[double]$ElapsedSeconds)
    $state=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\storage-lifecycle')
    if($Context.StateRoot -cne $state -or $Context.RunId -cnotmatch '\A[0-9a-f]{32}\z'){throw 'Candidate result update is restricted to the fixed task/run.'}
    $directory=Assert-KhcPlainPath (Join-Path (Join-Path $state 'runs') $Context.RunId)
    if($Context.RecordDirectory -cne $directory -or $Context.RecordPath -cne (Join-Path $directory 'run.json')){throw 'Candidate result update directory mismatch.'}
    $reserve=Get-KhcRecycleV6RunAnchor $state $Context.RunId
    if(-not $reserve.Contains('remote_candidate_e2e_required') -or $reserve.remote_candidate_e2e_required -isnot [bool] -or -not $reserve.remote_candidate_e2e_required){throw 'Only a real registered candidate E2E result may be downgraded.'}
    $record=ConvertFrom-Json -AsHashtable -InputObject ([Text.UTF8Encoding]::new($false,$true).GetString((Read-KhcBoundedSnapshotBytes $Context.RecordPath 8192)))
    if($record.owner_pid -ne $PID -or $record.owner_start_ticks -ne (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks){throw 'Candidate result update requires its live original owner.'}
    $expected=Get-KhcCandidateRunnerDeadlineFailureBytes $OriginalBytes $Context.RunId $ElapsedSeconds
    if(-not [Linq.Enumerable]::SequenceEqual[byte]($expected,$FailedBytes)){throw 'Candidate result update must be the exact one-direction deadline downgrade.'}
    $originalSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($OriginalBytes)).ToLowerInvariant()
    $vetoError=$null;$rewriteError=$null
    # 初回Flush/Disposeが失敗し元fileを開けなくても、正規runへのnegative vetoを先に試みる。
    try{Write-KhcNewJson (Join-Path $directory 'runner-deadline-failure.json') ([ordered]@{schema=1;protocol='khc-candidate-runner-deadline-failure-v1';run_id=$Context.RunId;record_sha256=$reserve.registration_sha256;protocol_sha256=$reserve.remote_candidate_e2e_protocol_sha256;original_result_sha256=$originalSha;elapsed_seconds=$ElapsedSeconds;recorded_utc=[DateTime]::UtcNow.ToString('o')})}catch{$vetoError=$_.Exception}
    try{
    if(-not ('Khc.Storage.CandidateResultHandle' -as [type])){
        Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
namespace Khc.Storage { public static class CandidateResultHandle {
 [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write; public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
 [DllImport("kernel32.dll",SetLastError=true)] static extern uint GetFileType(SafeFileHandle file);
 public static System.IO.FileStream Open(string path) {
  var h=CreateFileW(path,0xC0000000,0,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
  if(h.IsInvalid){int error=Marshal.GetLastWin32Error();h.Dispose();throw new Win32Exception(error);}
  try { Info i;if(!GetFileInformationByHandle(h,out i))throw new Win32Exception(Marshal.GetLastWin32Error());
   if(GetFileType(h)!=1 || (i.Attributes&0x410)!=0 || i.Links!=1)throw new InvalidOperationException("Candidate result must be a regular, non-reparse, single-link disk file.");
   return new System.IO.FileStream(h,System.IO.FileAccess.ReadWrite);
  }catch{h.Dispose();throw;}
 }
} }
'@
    }
    $path=Assert-KhcPlainPath (Join-Path $directory 'runner-result.json')
    $stream=[Khc.Storage.CandidateResultHandle]::Open($path)
    try{
        $owner=[IO.FileSystemAclExtensions]::GetAccessControl($stream).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if($owner -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or $stream.Length -ne $OriginalBytes.Length){throw 'Candidate result owner/length changed.'}
        $current=[byte[]]::new($OriginalBytes.Length);$offset=0
        while($offset -lt $current.Length){$read=$stream.Read($current,$offset,$current.Length-$offset);if($read -eq 0){throw 'Candidate result snapshot truncated.'};$offset+=$read}
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($current)).ToLowerInvariant() -cne $originalSha){throw 'Candidate result no longer matches this exact attempt snapshot.'}
        $stream.Position=0;$stream.Write($FailedBytes,0,$FailedBytes.Length);$stream.SetLength($FailedBytes.Length);$stream.Flush($true)
        $stream.Position=0;$written=[byte[]]::new($FailedBytes.Length);$offset=0
        while($offset -lt $written.Length){$read=$stream.Read($written,$offset,$written.Length-$offset);if($read -eq 0){throw 'Candidate failed result readback truncated; deadline veto remains authoritative.'};$offset+=$read}
        if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($written)) -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($FailedBytes))){throw 'Candidate failed result readback mismatch; deadline veto remains authoritative.'}
    }finally{$stream.Dispose()}
    }catch{$rewriteError=$_.Exception}
    if($null -ne $vetoError -and $null -ne $rewriteError){throw [AggregateException]::new('Candidate deadline veto and failed result could not be persisted; prior runner JSON must not be adopted as success.',[Exception[]]@($vetoError,$rewriteError))}
    if($null -ne $rewriteError){throw [IO.IOException]::new('Candidate deadline veto is durable, but failed result rewrite failed; veto remains authoritative.',$rewriteError)}
    if($null -ne $vetoError){throw [IO.IOException]::new('Candidate result is confirmed failed, but its separate deadline veto could not be persisted.',$vetoError)}
}

function Get-KhcCandidateRunnerDeadlineVetoStatus {
    param([Collections.IDictionary]$Veto,[string]$RunId,[string]$RecordSha256,[string]$ProtocolSha256)
    Assert-KhcMacDecodeDiagnosticFields $Veto @('schema','protocol','run_id','record_sha256','protocol_sha256','original_result_sha256','elapsed_seconds','recorded_utc')
    if(-not (Test-KhcMacNativeE2eJsonEqual $Veto.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $Veto.protocol 'khc-candidate-runner-deadline-failure-v1') -or -not (Test-KhcMacNativeE2eJsonEqual $Veto.run_id $RunId) -or -not (Test-KhcMacNativeE2eJsonEqual $Veto.record_sha256 $RecordSha256) -or -not (Test-KhcMacNativeE2eJsonEqual $Veto.protocol_sha256 $ProtocolSha256) -or $Veto.original_result_sha256 -isnot [string] -or $Veto.original_result_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or ($Veto.elapsed_seconds -isnot [int] -and $Veto.elapsed_seconds -isnot [long] -and $Veto.elapsed_seconds -isnot [double] -and $Veto.elapsed_seconds -isnot [decimal]) -or [double]::IsNaN([double]$Veto.elapsed_seconds) -or [double]::IsInfinity([double]$Veto.elapsed_seconds) -or $Veto.elapsed_seconds -le 360){throw 'Candidate runner deadline veto is invalid; success cannot be adopted.'}
    Assert-KhcMacDecodeDiagnosticUtc $Veto.recorded_utc
    return 'failed'
}

function Get-KhcMacCandidateE2eRegistration {
    param([string]$State,[string]$RunId,[Collections.IDictionary]$Reserve,[switch]$RequireInvocation,[switch]$RequireSeal)
    $root=Assert-KhcRecycleV6PrivatePath (Join-Path $State 'recycle-v6') -ProtectedRoot
    $path=Join-Path $root "mac-cdf-candidate-e2e-$RunId-registration.json";$sealPath=Join-Path $root "mac-cdf-candidate-e2e-$RunId.json"
    $required=$Reserve.Contains('remote_candidate_e2e_required')
    $null=Assert-KhcRemoteReferenceClassData ($Reserve.Contains('remote_native_e2e_required')) ($Reserve.Contains('remote_reference_required')) $required
    if(-not $required){if((Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath $sealPath)){throw 'Candidate E2E metadata has no required private reservation.'};return $null}
    if($State -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\storage-lifecycle') -or $RunId -cnotmatch '\A[0-9a-f]{32}\z'){throw 'Candidate E2E registration belongs only to the fixed task state and typed run ID.'}
    if($Reserve.remote_candidate_e2e_required -isnot [bool] -or -not $Reserve.remote_candidate_e2e_required -or $Reserve.max_bytes -ne 8MB -or $Reserve.max_entries -ne 96){throw 'Candidate E2E reserve type/resources mismatch.'}
    if(-not (Test-Path -LiteralPath $path)){throw 'Candidate E2E registration is missing or partial.'}
    $record=Read-KhcRecycleV6PrivateJson $path
    Assert-KhcMacDecodeDiagnosticFields $record @('schema','protocol','run_id','record_sha256','worker_path','worker_sha256','invocation_sha256','protocol_sha256','protocol_base64')
    $kind=Get-KhcMacCandidateE2eKind
    $directory=Join-Path (Join-Path $State 'runs') $RunId
    if(-not (Test-KhcMacNativeE2eJsonEqual $record.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $record.protocol 'khc-mac-cdf-candidate-e2e-registration-v1') -or -not (Test-KhcMacNativeE2eJsonEqual $record.run_id $RunId) -or -not (Test-KhcMacNativeE2eJsonEqual $record.record_sha256 $Reserve.registration_sha256) -or $record.record_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path $directory 'run.json')) -or -not (Test-KhcMacNativeE2eJsonEqual $record.protocol_sha256 $Reserve.remote_candidate_e2e_protocol_sha256) -or -not (Test-KhcMacNativeE2eJsonEqual $record.worker_path $kind.Worker) -or $record.protocol_base64 -isnot [string] -or $record.protocol_base64.Length -gt 45000 -or $record.invocation_sha256 -isnot [string] -or $record.invocation_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Candidate E2E private registration identity mismatch.'}
    $bytes=[Convert]::FromBase64String($record.protocol_base64)
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot $bytes $record.protocol_sha256 32768
    Assert-KhcMacCandidateE2eProtocol $protocol
    $trust=Get-KhcMacCandidateE2eTrustSpec $record.protocol_sha256 $protocol.endpoint_sha256
    if(-not (Test-KhcMacNativeE2eJsonEqual $record.worker_sha256 $trust.WorkerSha256)){throw 'Candidate E2E worker pin mismatch.'}
    $claim=Read-KhcRecycleV6PrivateJson (Join-Path $root 'mac-cdf-candidate-e2e.claim.json')
    Assert-KhcMacCandidateE2eClaimData $claim $RunId $record.record_sha256 $record.protocol_sha256
    $invocation=Join-Path $directory 'invocation.clixml'
    if($RequireInvocation -and -not (Test-Path -LiteralPath $invocation)){throw 'Candidate E2E invocation not published.'}
    if((Test-Path -LiteralPath $invocation) -and (Get-KhcRecycleV6Hash $invocation) -cne $record.invocation_sha256){throw 'Candidate E2E invocation differs from private registration.'}
    $sealed=Test-Path -LiteralPath $sealPath
    if($RequireSeal -and -not $sealed){throw 'Candidate E2E remains unsealed; cleanup/next execution refused.'}
    if($sealed){
        $seal=Read-KhcRecycleV6PrivateJson $sealPath
        Assert-KhcMacDecodeDiagnosticFields $seal @('schema','protocol','run_id','registration_sha256','protocol_sha256','receipt_sha256','receipt_base64','confirmed_utc')
        if(-not (Test-KhcMacNativeE2eJsonEqual $seal.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $seal.protocol 'khc-mac-cdf-candidate-e2e-seal-v1') -or -not (Test-KhcMacNativeE2eJsonEqual $seal.run_id $RunId) -or $seal.registration_sha256 -cne (Get-KhcRecycleV6Hash $path) -or -not (Test-KhcMacNativeE2eJsonEqual $seal.protocol_sha256 $record.protocol_sha256) -or $seal.receipt_base64 -isnot [string] -or $seal.receipt_base64.Length -gt 180000){throw 'Candidate E2E seal identity mismatch.'}
        Assert-KhcMacDecodeDiagnosticUtc $seal.confirmed_utc
        $raw=[Convert]::FromBase64String($seal.receipt_base64)
        $null=ConvertFrom-KhcBoundedJsonSnapshot $raw $seal.receipt_sha256 131072
        $null=Invoke-KhcMacCandidateE2eVerifier $bytes $record.protocol_sha256 $raw $RunId $record.record_sha256
    }
    $runnerDeadlineFailed=$false
    $vetoPath=Join-Path $directory 'runner-deadline-failure.json'
    if(Test-Path -LiteralPath $vetoPath){
        $vetoBytes=Read-KhcBoundedSnapshotBytes $vetoPath 8192
        $vetoSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($vetoBytes)).ToLowerInvariant()
        $veto=ConvertFrom-KhcBoundedJsonSnapshot $vetoBytes $vetoSha 8192
        $null=Get-KhcCandidateRunnerDeadlineVetoStatus $veto $RunId $record.record_sha256 $record.protocol_sha256
        $runnerDeadlineFailed=$true
    }
    return [pscustomobject]@{Record=$record;Protocol=$protocol;ProtocolBytes=$bytes;Trust=$trust;Path=$path;SealPath=$sealPath;RunnerDeadlineFailed=$runnerDeadlineFailed;RunnerStatus=$(if($runnerDeadlineFailed){'failed'}else{$null})}
}

function Assert-KhcMacCandidateE2eCleanupSeal {
    param($Run)
    $root=Join-Path $Run.StateRoot 'recycle-v6'
    $reservePath=Join-Path $root "$($Run.RunId).reserve.json"
    if(-not (Test-Path -LiteralPath $reservePath)){if((Test-Path -LiteralPath (Join-Path $root "mac-cdf-candidate-e2e-$($Run.RunId)-registration.json")) -or (Test-Path -LiteralPath (Join-Path $root "mac-cdf-candidate-e2e-$($Run.RunId).json"))){throw 'Candidate E2E metadata lost its private reserve.'};return}
    $reserve=Read-KhcRecycleV6PrivateJson $reservePath
    $null=Get-KhcMacCandidateE2eRegistration $Run.StateRoot $Run.RunId $reserve -RequireSeal
}

function Save-KhcMacCandidateE2eSeal {
    param([string]$State,[string]$RunId,[byte[]]$ReceiptBytes)
    $reserve=Get-KhcRecycleV6RunAnchor $State $RunId
    $registration=Get-KhcMacCandidateE2eRegistration $State $RunId $reserve -RequireInvocation
    if($null -eq $registration -or (Test-Path -LiteralPath $registration.SealPath)){throw 'Candidate E2E requires one unsealed registered run.'}
    $summary=Invoke-KhcMacCandidateE2eVerifier $registration.ProtocolBytes $registration.Record.protocol_sha256 $ReceiptBytes $RunId $registration.Record.record_sha256
    $sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    $null=Assert-KhcStorageBudget -ReserveBytes 1MB
    Write-KhcNewJson $registration.SealPath ([ordered]@{schema=1;protocol='khc-mac-cdf-candidate-e2e-seal-v1';run_id=$RunId;registration_sha256=(Get-KhcRecycleV6Hash $registration.Path);protocol_sha256=$registration.Record.protocol_sha256;receipt_sha256=$sha;receipt_base64=[Convert]::ToBase64String($ReceiptBytes);confirmed_utc=[DateTime]::UtcNow.ToString('o')})
    return $summary
}

function Get-KhcMacCandidateE2eTrustSpec {
    param([string]$ProtocolSha256,[string]$EndpointSha256)
    if($ProtocolSha256 -cne '95b2fd0228cca0f440d4a45998d6d2ad709b0e6cf20a5e42db6a439eccf67d5c' -or $EndpointSha256 -cne 'da6231a6f6fb61b04fd2c7833661a6a4467d3ee14db5d9fcf6e19ae2731b79ba'){throw 'Unknown candidate E2E protocol/endpoint; no fallback is permitted.'}
    $directory=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-cdf-candidate-e2e-verifier-da6231a6f6fb61b04fd2c7833661a6a4467d3ee14db5d9fcf6e19ae2731b79ba')
    $pins=(Get-KhcMacCdfCandidateTrustSpec '2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5' '80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f' '8c6f4576d868e43158ade779ee176719bc6a7281d4420a4bfe3d371d25ab0082').Pins
    $pins['mac-cdf-candidate-e2e-endpoint.py']='da6231a6f6fb61b04fd2c7833661a6a4467d3ee14db5d9fcf6e19ae2731b79ba'
    $pins['mac-native-e2e-oracle.json']='343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75'
    $pins['mac-cdf-candidate-e2e.ps1']='8868e4224d63376bbab2dda50e6f2fae3f6caf3fa8c22dec1bb7021234baa778'
    return [pscustomobject]@{Directory=$directory;Pins=$pins;WorkerSha256=$pins['mac-cdf-candidate-e2e.ps1'];WorkerPath=(Join-Path $directory 'mac-cdf-candidate-e2e.ps1')}
}

function Get-KhcMacCandidateE2eProtocol {
    param([string]$EndpointSha256)
    if($EndpointSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Candidate E2E endpoint SHA invalid.'}
    $root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
    return @{schema=1;protocol='khc-mac-cdf-candidate-e2e-v1';purpose='candidate-example-correctness-only';task='goal-restore-20261019';host='m3mb14';root=$root;run_directory="$root/tmp/mac-cdf-candidate-example-e2e-20261027";endpoint_sha256=$EndpointSha256;source_sha256='36d904e04917022328d7aa41f0f2aeea03d1827348f11f7b261b392013b5fc05';source_manifest_sha256='d711acf1989b34f5043d5a7bae68ea95c2d51a72f602ca6ca27124e5ebffc7e2';example_sha256='0af3b9cc1823566c129c1bf989f4e53720bc8db843bb152c504d744bf556e59c';candidate_cli_sha256='cc36350705aff86fb4c8bf36e9d6f3d409c1fd4bf6b3d4fd6f1853e5add22632';candidate_build_receipt_sha256='34047b6793caa999e6dddc95a51b0b8c35e12218f1c9bf59e3834d89885cb23c';candidate_build_closure_sha256='d180b552023a06f47672116be0a71f60950183fcc328415522c9c323523baeeb';fixture_sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650';fixture_bytes=513216;oracle_sha256='343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75';windows_max_bytes=8388608;windows_max_entries=96;windows_timeout_seconds=360;worker_timeout_seconds=350;native_timeout_seconds=300;child_timeout_seconds=240;closure_reserve_seconds=13;preflight_seconds=27;postcheck_reserve_seconds=20;supervisor_sha256='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30';setup_sha256='9790c77fb4e427247e9c1217c08b18243a31cdcd6e868ff1836ae392bfa59fd1';build_verifier_sha256='9bd8d719b7f94305070866a5c84a62ffdb805f2b0bf16599dfc568522b3fddfb';candidate_controller_sha256='2f11f23570c9553430cded38b3920ee878867a0a0f8ef5bb9486bcacdf9e1aa5';candidate_snapshot_sha256='80b14beefefbee2f4559f6c50a128794c7c5240ca8f08d606a4818ee4feb1f7f';superiority_decision_allowed=$false}
}

function Assert-KhcMacCandidateE2eProtocol {
    param([Collections.IDictionary]$Protocol)
    if($Protocol.endpoint_sha256 -isnot [string] -or -not (Test-KhcMacNativeE2eJsonEqual $Protocol (Get-KhcMacCandidateE2eProtocol $Protocol.endpoint_sha256))){throw 'Candidate E2E fixed protocol mismatch.'}
}

function Read-KhcMacCandidateE2eProtocol {
    param([string]$Path,[string]$Sha256)
    $kind=Get-KhcMacCandidateE2eKind
    if($Path -cne $kind.ProtocolPath -or (Assert-KhcPlainPath $Path) -cne $kind.ProtocolPath){throw 'Candidate E2E requires its fixed protocol path.'}
    $bytes=Read-KhcBoundedSnapshotBytes $Path 32768
    $data=ConvertFrom-KhcBoundedJsonSnapshot $bytes $Sha256 32768
    Assert-KhcMacCandidateE2eProtocol $data
    $trust=Get-KhcMacCandidateE2eTrustSpec $Sha256 $data.endpoint_sha256
    $null=Invoke-KhcMacCandidateE2eVerifier $bytes $Sha256
    return [pscustomobject]@{Data=$data;Bytes=$bytes;Trust=$trust}
}

function Assert-KhcMacCandidateE2eClaimData {
    param([Collections.IDictionary]$Claim,[string]$RunId,[string]$RecordSha256,[string]$ProtocolSha256)
    Assert-KhcMacDecodeDiagnosticFields $Claim @('schema','protocol','run_id','record_sha256','protocol_sha256','registered_utc')
    if($RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $RecordSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $ProtocolSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or -not (Test-KhcMacNativeE2eJsonEqual $Claim.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $Claim.protocol 'khc-mac-cdf-candidate-e2e-claim-v1') -or -not (Test-KhcMacNativeE2eJsonEqual $Claim.run_id $RunId) -or -not (Test-KhcMacNativeE2eJsonEqual $Claim.record_sha256 $RecordSha256) -or -not (Test-KhcMacNativeE2eJsonEqual $Claim.protocol_sha256 $ProtocolSha256)){throw 'Candidate E2E one-purpose claim identity mismatch.'}
    Assert-KhcMacDecodeDiagnosticUtc $Claim.registered_utc
}

function Assert-KhcMacCandidateE2eBuildEvidence {
    $ledger=Get-KhcMacCdfCandidateLedger
    if($null -eq $ledger.Start -or $null -eq $ledger.Terminal){throw 'Candidate E2E requires the sealed candidate build.'}
    $seal=Read-KhcRecycleV6PrivateJson (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate.terminal.json')
    if($seal.receipt_sha256 -cne '34047b6793caa999e6dddc95a51b0b8c35e12218f1c9bf59e3834d89885cb23c' -or $ledger.Terminal.status -cne 'done' -or $ledger.Terminal.closure_sha256 -cne 'd180b552023a06f47672116be0a71f60950183fcc328415522c9c323523baeeb' -or $ledger.Terminal.binary_sha256 -cne 'cc36350705aff86fb4c8bf36e9d6f3d409c1fd4bf6b3d4fd6f1853e5add22632'){throw 'Candidate E2E build raw/CLI/closure proof mismatch.'}
}

function Invoke-KhcMacCandidateE2eVerifier {
    param([byte[]]$ProtocolBytes,[string]$ProtocolSha256,[byte[]]$ReceiptBytes=$null,[string]$RunId='',[string]$RecordSha256='')
    Assert-KhcVerifierQuarantineClear
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot $ProtocolBytes $ProtocolSha256 32768
    Assert-KhcMacCandidateE2eProtocol $protocol
    $trust=Get-KhcMacCandidateE2eTrustSpec $ProtocolSha256 $protocol.endpoint_sha256
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $info.StandardInputEncoding=[Text.UTF8Encoding]::new($false,$true)
    $base64=[Convert]::ToBase64String($ProtocolBytes)
    if($null -ne $ReceiptBytes -and $ReceiptBytes.Length -gt 131072){throw 'Candidate E2E receipt bound.'}
    $wire=ConvertTo-Json -Compress -InputObject ([ordered]@{mode=$(if($null -eq $ReceiptBytes){'protocol'}else{'receipt'});protocol_base64=$base64;protocol_sha256=$ProtocolSha256;receipt_base64=$(if($null -eq $ReceiptBytes){$null}else{[Convert]::ToBase64String($ReceiptBytes)})})
    if([Text.Encoding]::UTF8.GetByteCount($wire) -gt 262144){throw 'Candidate E2E verifier stdin bound.'}
    $wireSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wire))).ToLowerInvariant()
    foreach($arg in @('-I','-B',(Join-Path $trust.Directory 'mac-cdf-candidate-e2e-endpoint.py'),'--verify-wire-stdin')){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$spawned=$false;$readLease=$null
    try{
        $readLease=Enter-KhcMacDecodeVerifierReadLease $trust
        $scan=Get-KhcChargeScanContext
        $scanKey=Get-KhcChargeScanKey 'Invoke-KhcMacCandidateE2eVerifier' (@($info.ArgumentList)+@($wireSha,$RunId,$RecordSha256)) ((@($trust.Pins.Keys | Sort-Object -CaseSensitive | ForEach-Object {$_+'='+$trust.Pins[$_]}) -join "`n"))
        if($null -ne $scan -and $scan.Results.ContainsKey($scanKey)){return (Copy-KhcChargeScanSummary $scan.Results[$scanKey])}
        if(-not $process.Start()){throw 'Candidate E2E pure verifier failed to start.'};$spawned=$true
        $inputTask=$process.StandardInput.WriteAsync($wire);$inputClosed=$false
        $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(2048),[char[]]::new(2048));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new())
        $tasks=@($readers[0].ReadAsync($buffers[0],0,2048),$readers[1].ReadAsync($buffers[1],0,2048));$done=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
        while($true){
            if(-not $inputClosed -and $inputTask.IsCompleted){$null=$inputTask.GetAwaiter().GetResult();$process.StandardInput.Close();$inputClosed=$true}
            for($side=0;$side -lt 2;$side++){if(-not $done[$side] -and $tasks[$side].IsCompleted){$count=$tasks[$side].GetAwaiter().GetResult();if($count -eq 0){$done[$side]=$true}else{if($logs[$side].Length+$count -gt 16384){throw 'Candidate E2E verifier output bound.'};$null=$logs[$side].Append($buffers[$side],0,$count);$tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,2048)}}}
            if($timer.Elapsed.TotalSeconds -gt 15){throw 'Candidate E2E pure verifier timeout.'}
            if($process.HasExited -and $done[0] -and $done[1] -and $inputClosed){break};Start-Sleep -Milliseconds 25
        }
        if($process.ExitCode -ne 0 -or $logs[1].Length -ne 0){throw 'Candidate E2E raw evidence verification failed.'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($logs[0].ToString());$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $summary=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 16384
        Assert-KhcMacCandidateE2eSummary $summary $protocol $ProtocolSha256 $ReceiptBytes $RunId $RecordSha256
        if($null -ne $scan){
            $scan.Results[$scanKey]=Copy-KhcChargeScanSummary $summary
            $scan.Leases.Add($readLease);$readLease=$null
        }
        return $summary
    }finally{Complete-KhcVerifierReadLease $process $spawned $readLease}
}

function Assert-KhcMacCandidateE2eSummary {
    param([Collections.IDictionary]$Summary,[Collections.IDictionary]$Protocol,[string]$ProtocolSha256,[byte[]]$ReceiptBytes=$null,[string]$RunId='',[string]$RecordSha256='')
    Assert-KhcMacCandidateE2eProtocol $Protocol
    $fields=@('schema','protocol','protocol_sha256','endpoint_sha256','source_sha256','purpose','verified')
    if($null -ne $ReceiptBytes){$fields+=@('windows_run_id','windows_registration_sha256','receipt_sha256','report_sha256','closure_sha256','status','exit','cleanup_allowed')}
    Assert-KhcMacDecodeDiagnosticFields $Summary $fields
    if(-not (Test-KhcMacNativeE2eJsonEqual $Summary.schema 1) -or $Summary.verified -isnot [bool] -or -not $Summary.verified -or -not (Test-KhcMacNativeE2eJsonEqual $Summary.protocol_sha256 $ProtocolSha256)){throw 'Candidate E2E verifier identity mismatch.'}
    foreach($key in @('protocol','endpoint_sha256','source_sha256','purpose')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $Protocol[$key])){throw 'Candidate E2E verifier pin mismatch.'}}
    if($null -eq $ReceiptBytes){return}
    $rawSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ReceiptBytes)).ToLowerInvariant()
    $receipt=ConvertFrom-KhcBoundedJsonSnapshot $ReceiptBytes $rawSha 131072
    Assert-KhcMacDecodeDiagnosticFields $receipt @('schema','protocol','purpose','windows_run_id','windows_registration_sha256','protocol_sha256','endpoint_sha256','source_sha256','example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256','remote_registration_sha256','report_sha256','report_base64','closure_proof','closure_sha256','children_absent','postchecks_ok','runtime_seconds','status','exit','error')
    foreach($key in @('schema','protocol','purpose','endpoint_sha256','source_sha256','example_sha256','candidate_cli_sha256','candidate_build_receipt_sha256','candidate_build_closure_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $receipt[$key] $Protocol[$key])){throw 'Candidate E2E raw pin identity differs.'}}
    if($RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $RecordSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or -not (Test-KhcMacNativeE2eJsonEqual $Summary.windows_run_id $RunId) -or -not (Test-KhcMacNativeE2eJsonEqual $Summary.windows_registration_sha256 $RecordSha256) -or -not (Test-KhcMacNativeE2eJsonEqual $Summary.receipt_sha256 $rawSha) -or -not (Test-KhcMacNativeE2eJsonEqual $receipt.protocol_sha256 $ProtocolSha256) -or $Summary.cleanup_allowed -isnot [bool] -or -not $Summary.cleanup_allowed -or $receipt.children_absent -isnot [bool] -or -not $receipt.children_absent){throw 'Candidate E2E registration/raw/closure remains unconfirmed.'}
    foreach($key in @('windows_run_id','windows_registration_sha256','report_sha256','closure_sha256','status','exit')){if(-not (Test-KhcMacNativeE2eJsonEqual $Summary[$key] $receipt[$key])){throw 'Candidate E2E raw receipt differs from verifier summary.'}}
    if($receipt.status -isnot [string] -or $receipt.status -cnotin @('done','failed') -or ($receipt.exit -isnot [int] -and $receipt.exit -isnot [long]) -or $receipt.exit -ne $(if($receipt.status -ceq 'done'){0}else{1}) -or $receipt.postchecks_ok -isnot [bool] -or $receipt.closure_proof -isnot [Collections.IDictionary] -or $receipt.closure_sha256 -isnot [string] -or $receipt.closure_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Candidate E2E receipt status/closure types invalid.'}
    $elapsed=$receipt.runtime_seconds
    if(($elapsed -isnot [int] -and $elapsed -isnot [long] -and $elapsed -isnot [double] -and $elapsed -isnot [decimal]) -or [double]::IsNaN([double]$elapsed) -or [double]::IsInfinity([double]$elapsed) -or $elapsed -lt 0 -or ($receipt.status -ceq 'done' -and ($elapsed -gt 300 -or -not $receipt.postchecks_ok))){throw 'Candidate E2E receipt runtime/eligibility invalid.'}
    if($null -ne $receipt.report_base64){
        if($receipt.report_base64 -isnot [string] -or $receipt.report_base64.Length -gt 180000 -or $receipt.report_sha256 -isnot [string]){throw 'Candidate E2E report bound/type invalid.'}
        $report=ConvertFrom-KhcBoundedJsonSnapshot ([Convert]::FromBase64String($receipt.report_base64)) $receipt.report_sha256 131072
        foreach($key in @('windows_run_id','windows_registration_sha256','protocol_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $report[$key] $receipt[$key])){throw 'Candidate E2E report registration differs.'}}
        if(-not (Test-KhcMacNativeE2eJsonEqual $report.registration_sha256 $receipt.remote_registration_sha256)){throw 'Candidate E2E derived registration report differs.'}
    }elseif($null -ne $receipt.report_sha256 -or $receipt.status -ceq 'done'){throw 'Candidate E2E successful report missing.'}
}

function Assert-KhcMacNativeE2eProtocolData {
    param([Collections.IDictionary]$Protocol)
    $fixed=@{schema=1;protocol='khc-mac-native-e2e-ps-free-v1';task='goal-restore-20261019';host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';run='mac-native-e2e-ps-free-20261026';windows_max_bytes=8388608;windows_max_entries=96;windows_timeout_seconds=360;remote_global_seconds=300;remote_supervisor_seconds=305;source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';old_failed_build_sha256='1b66fadf5833ad2874738b91b7107ccff9dd906f0b58ab4beb7f936d275ab9b7';previous_e2e_sha256='60311a84931e505b6b2de2810d31ed2d7c3e60c4ca6af66c1baf59c5a1eda12c';oracle_sha256='343e08f0e41295e736ffc94d2ab70340228e6e50bacd829a5e72c3b5a4b39d75';fixture_sha256='0ec3a75089bb52342813496b17e51377bc9eba3cb519a444d67025354841d650';cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';e2e_sha256='b4e8d7c5fe5fa87b74c466cacabe4c94baddf80a1717b66629e0012c59e12ff4';reason='sandbox-ps-exec-denied-use-outer-group-proof'}
    $fields=@($fixed.Keys)+@('endpoint_sha256','e2e_script_sha256','config_sha256')
    if($Protocol.Count -ne 22 -or @($Protocol.Keys | Where-Object {$_ -cnotin $fields}).Count){throw 'Native ps-free protocol fields mismatch.'}
    foreach($key in $fixed.Keys){if($fixed[$key] -is [int]){if(($Protocol[$key] -isnot [int] -and $Protocol[$key] -isnot [long]) -or $Protocol[$key] -ne $fixed[$key]){throw 'Native protocol integer/resource mismatch.'}}elseif($Protocol[$key] -isnot [string] -or $Protocol[$key] -cne $fixed[$key]){throw "Native protocol fixed pin mismatch: $key"}}
    foreach($key in @('endpoint_sha256','e2e_script_sha256','config_sha256')){if($Protocol[$key] -isnot [string] -or $Protocol[$key] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Native protocol artifact SHA format.'}}
}

function Read-KhcMacNativeE2eProtocol {
    param([string]$Path,[string]$Sha256)
    if($Path -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-e2e-ps-free-protocol.json')){throw 'Use the fixed current-task native protocol path.'}
    $bytes=Read-KhcBoundedSnapshotBytes $Path
    $data=ConvertFrom-KhcBoundedJsonSnapshot $bytes $Sha256
    Assert-KhcMacNativeE2eProtocolData $data
    [pscustomobject]@{Data=$data;Raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);Sha256=$Sha256}
}

function Test-KhcMacNativeE2eJsonEqual {
    param($Actual,$Expected)
    if($null -eq $Expected){return $null -eq $Actual}
    if($Expected -is [Collections.IDictionary]){if($Actual -isnot [Collections.IDictionary] -or $Actual.Count -ne $Expected.Count){return $false};foreach($key in $Expected.Keys){if($Actual.Keys -cnotcontains $key -or -not (Test-KhcMacNativeE2eJsonEqual $Actual[$key] $Expected[$key])){return $false}};return $true}
    if($Expected -is [Collections.IList]){if($Actual -isnot [Collections.IList] -or $Actual.Count -ne $Expected.Count){return $false};for($i=0;$i -lt $Expected.Count;$i++){if(-not (Test-KhcMacNativeE2eJsonEqual $Actual[$i] $Expected[$i])){return $false}};return $true}
    if($Expected -is [bool]){return ($Actual -is [bool] -and $Actual -eq $Expected)}
    if($Expected -is [int] -or $Expected -is [long]){return (($Actual -is [int] -or $Actual -is [long]) -and $Actual -eq $Expected)}
    if($Expected -is [double] -or $Expected -is [decimal]){return (($Actual -is [double] -or $Actual -is [decimal] -or $Actual -is [int] -or $Actual -is [long]) -and -not [double]::IsNaN([double]$Actual) -and -not [double]::IsInfinity([double]$Actual) -and $Actual -eq $Expected)}
    return ($Actual -is [string] -and $Actual -ceq $Expected)
}

function Assert-KhcMacNativeE2eReceiptData {
    param([Collections.IDictionary]$Receipt,[Collections.IDictionary]$Protocol,[string]$ProtocolSha256,[string]$RunId,[Collections.IDictionary]$Oracle)
    Assert-KhcMacNativeE2eProtocolData $Protocol
    $pins=@('endpoint_sha256','e2e_script_sha256','config_sha256','oracle_sha256','fixture_sha256','source_sha256','old_failed_build_sha256','previous_e2e_sha256','cli_sha256','e2e_sha256','reason')
    $fields=@('schema','protocol','windows_run_id','protocol_sha256','children_absent','tracked_direct_children_absent','exit','status','report_sha256','report_base64','error')+$pins
    if($Receipt.Count -ne 22 -or @($Receipt.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($Receipt.schema -isnot [int] -and $Receipt.schema -isnot [long]) -or $Receipt.schema -ne 1 -or $Receipt.protocol -cne 'khc-mac-native-e2e-ps-free-terminal-v1' -or $RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $Receipt.windows_run_id -cne $RunId -or $Receipt.protocol_sha256 -cne $ProtocolSha256 -or $Receipt.children_absent -isnot [bool] -or -not $Receipt.children_absent -or $Receipt.tracked_direct_children_absent -isnot [bool]){throw 'Native terminal schema/run/absence identity mismatch.'}
    foreach($key in $pins){if($Receipt[$key] -cne $Protocol[$key]){throw "Native terminal artifact pin mismatch: $key"}}
    if(($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or $Receipt.exit -notin @(0,1) -or $Receipt.status -cne $(if($Receipt.exit -eq 0){'passed'}else{'failed'}) -or ($null -ne $Receipt.error -and ($Receipt.error -isnot [string] -or $Receipt.error.Length -gt 4096))){throw 'Native terminal status/exit/error mismatch.'}
    $report=$null;$bytes=$null
    if($null -ne $Receipt.report_base64){
        if($Receipt.report_base64 -isnot [string] -or $Receipt.report_base64.Length -gt 45000 -or $Receipt.report_sha256 -isnot [string]){throw 'Native report transfer bound.'}
        $bytes=[Convert]::FromBase64String($Receipt.report_base64)
        $report=ConvertFrom-KhcBoundedJsonSnapshot $bytes $Receipt.report_sha256 32768
        if(($report.schema -isnot [int] -and $report.schema -isnot [long]) -or $report.schema -ne 1 -or $report.state -cne 'passed' -or $report.tracked_direct_children_absent -isnot [bool] -or -not $report.tracked_direct_children_absent -or $report.windows_run_id -cne $RunId -or $report.protocol_sha256 -cne $ProtocolSha256 -or [string]$report.registration_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Native report identity/track mismatch.'}
        foreach($key in @('config_sha256','oracle_sha256','fixture_sha256','cli_sha256','e2e_sha256','old_failed_build_sha256','previous_e2e_sha256','e2e_script_sha256','reason')){if($report[$key] -cne $Protocol[$key]){throw 'Native report pin mismatch.'}}
        foreach($pair in @(@('checks','checks'),@('api','api'),@('archive_suffixes','archive_suffixes'),@('restored','restored'))){if(-not (Test-KhcMacNativeE2eJsonEqual $report[$pair[0]] $Oracle[$pair[1]])){throw 'Native report differs from the fixed Windows oracle.'}}
        if(@($report.checks).Count -ne 34 -or @($report.archive_suffixes).Count -ne 24 -or @($report.full_goldens).Count -ne 3){throw 'Native report case/golden/suffix count mismatch.'}
        for($i=0;$i -lt 3;$i++){$hex=$Oracle.api.folded_zero_count_frames[$i];$frame=[Convert]::FromHexString($hex);$wanted=@{index=$i;hex=$hex;bytes=$frame.Length;sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($frame)).ToLowerInvariant()};if(-not (Test-KhcMacNativeE2eJsonEqual $report.full_goldens[$i] $wanted)){throw 'Full golden proof mismatch.'}}
    }elseif($null -ne $Receipt.report_sha256){throw 'Native report hash has no report bytes.'}
    if($Receipt.exit -eq 0 -and ($null -eq $report -or -not $Receipt.tracked_direct_children_absent -or $null -ne $Receipt.error)){throw 'Passed native endpoint requires full passed report and no error.'}
    [pscustomobject]@{Report=$report;ReportBytes=$bytes;Receipt=$Receipt}
}

function Assert-KhcMacNativeE2eSealState {
    param([bool]$Required,[bool]$Registered,[bool]$Sealed,[switch]$RequireSeal)
    if($Required -ne $Registered -or ($Sealed -and -not $Registered) -or ($RequireSeal -and $Required -and -not $Sealed)){throw 'Remote native run classification/terminal seal is missing; cleanup is prohibited.'}
}

function Get-KhcMacNativeE2eRegistration {
    param([string]$State,[string]$RunId,[Collections.IDictionary]$Reserve,[switch]$RequireInvocation,[switch]$RequireSeal)
    $root=Assert-KhcRecycleV6PrivatePath (Join-Path $State 'recycle-v6') -ProtectedRoot
    $path=Join-Path $root "mac-native-e2e-$RunId-registration.json";$sealPath=Join-Path $root "mac-native-e2e-$RunId.json"
    $required=$Reserve.Contains('remote_native_e2e_required')
    $registered=Test-Path -LiteralPath $path;$sealed=Test-Path -LiteralPath $sealPath
    Assert-KhcMacNativeE2eSealState $required $registered $sealed -RequireSeal:$RequireSeal
    if(-not $required){return $null}
    if($Reserve.remote_native_e2e_required -isnot [bool] -or -not $Reserve.remote_native_e2e_required -or [string]$Reserve.remote_native_e2e_protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Private remote reservation flag is invalid.'}
    $record=Read-KhcRecycleV6PrivateJson $path
    $directory=Join-Path (Join-Path $State 'runs') $RunId
    $fields=@('schema','protocol','run_id','record_sha256','worker_path','worker_sha256','invocation_sha256','protocol_sha256','protocol_utf8','oracle_utf8')
    if($record.Count -ne 10 -or @($record.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($record.schema -isnot [int] -and $record.schema -isnot [long]) -or $Reserve.max_bytes -ne 8MB -or $Reserve.max_entries -ne 96 -or $record.record_sha256 -cne $Reserve.registration_sha256){throw 'Private native registration fields/resources mismatch.'}
    foreach($field in $fields | Where-Object {$_ -cne 'schema'}){if($record[$field] -isnot [string]){throw 'Private native registration requires string identity fields.'}}
    if($record.schema -ne 1 -or $record.protocol -cne 'khc-mac-native-e2e-registration-v1' -or $record.run_id -cne $RunId -or $record.record_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path $directory 'run.json')) -or $record.protocol_sha256 -cne $Reserve.remote_native_e2e_protocol_sha256 -or $record.worker_path -cne 'D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-spatial-mdl-e2e.ps1' -or [string]$record.worker_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or [string]$record.invocation_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Private native registration identity is corrupted.'}
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($record.protocol_utf8)) $record.protocol_sha256
    Assert-KhcMacNativeE2eProtocolData $protocol
    $oracle=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($record.oracle_utf8)) $protocol.oracle_sha256
    $invocation=Join-Path $directory 'invocation.clixml'
    if($RequireInvocation -and -not (Test-Path -LiteralPath $invocation)){throw 'Native invocation has not been published.'}
    if((Test-Path -LiteralPath $invocation) -and (Get-KhcRecycleV6Hash $invocation) -cne $record.invocation_sha256){throw 'Published invocation differs from private native registration.'}
    $data=[pscustomobject]@{Record=$record;Protocol=$protocol;Oracle=$oracle;Path=$path;SealPath=$sealPath}
    if($sealed){
        $seal=Read-KhcRecycleV6PrivateJson $sealPath
        $fields=@('schema','protocol','run_id','registration_sha256','protocol_sha256','receipt_sha256','receipt_utf8','confirmed_utc')
        if($seal.Count -ne 8 -or @($seal.Keys | Where-Object {$_ -cnotin $fields}).Count -or ($seal.schema -isnot [int] -and $seal.schema -isnot [long]) -or $seal.receipt_utf8 -isnot [string] -or $seal.receipt_sha256 -isnot [string]){throw 'Private native seal fields/type mismatch.'}
        $stamp=[DateTime]::MinValue
        if($seal.confirmed_utc -is [DateTime]){if($seal.confirmed_utc.Kind -ne [DateTimeKind]::Utc){throw 'Native seal timestamp must be UTC.'}}
        elseif($seal.confirmed_utc -isnot [string] -or -not [DateTime]::TryParseExact($seal.confirmed_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp) -or $stamp.Kind -ne [DateTimeKind]::Utc){throw 'Native seal UTC timestamp mismatch.'}
        if($seal.schema -ne 1 -or $seal.protocol -cne 'khc-mac-native-e2e-terminal-seal-v1' -or $seal.run_id -cne $RunId -or $seal.registration_sha256 -cne (Get-KhcRecycleV6Hash $path) -or $seal.protocol_sha256 -cne $record.protocol_sha256){throw 'Private native terminal seal binding mismatch.'}
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($seal.receipt_utf8)) $seal.receipt_sha256
        $null=Assert-KhcMacNativeE2eReceiptData $receipt $protocol $record.protocol_sha256 $RunId $oracle
    }
    return $data
}

function Assert-KhcMacNativeE2eCleanupSeal {
    param([object]$Run)
    $root=Join-Path $Run.StateRoot 'recycle-v6'
    if(-not (Test-Path -LiteralPath (Join-Path $root "$($Run.RunId).reserve.json"))){if((Test-Path -LiteralPath (Join-Path $root "mac-native-e2e-$($Run.RunId)-registration.json")) -or (Test-Path -LiteralPath (Join-Path $root "mac-native-e2e-$($Run.RunId).json"))){throw 'Remote native metadata lost its private reserve.'};return}
    $reserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$($Run.RunId).reserve.json")
    $null=Get-KhcMacNativeE2eRegistration $Run.StateRoot $Run.RunId $reserve -RequireSeal
}

function Confirm-KhcMacNativeE2eTerminal {
    param([Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{32}\z')][string]$RunId,[Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedSha256)
    $location=Get-KhcStorageRunLocation $RunId;$state=$location.StateRoot
    $registrationLease=$null;$serialLock=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $serialLock=[IO.File]::Open((Join-Path $state 'serial.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        Assert-KhcNoPendingStorageRuns -AllowedRecordPath $location.RecordPath -AllowInactiveOwner
        $reserve=Get-KhcRecycleV6RunAnchor $state $RunId
        $registration=Get-KhcMacNativeE2eRegistration $state $RunId $reserve -RequireInvocation
        if($null -eq $registration){throw 'This run is not the registered remote native worker.'}
        $runRecord=Get-Content -LiteralPath $location.RecordPath -Raw | ConvertFrom-Json
        if($ReceiptPath -cne (Join-Path $runRecord.work_directory 'endpoint-receipt.json')){throw 'Use the exact registered work receipt path.'}
        $bytes=Read-KhcBoundedSnapshotBytes $ReceiptPath
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot $bytes $ExpectedSha256
        $verified=Assert-KhcMacNativeE2eReceiptData $receipt $registration.Protocol $registration.Record.protocol_sha256 $RunId $registration.Oracle
        if($null -ne $verified.ReportBytes -and (Get-KhcRecycleV6Hash (Join-Path $runRecord.work_directory 'native-e2e-report.json')) -cne $receipt.report_sha256){throw 'Windows retained native report does not match canonical endpoint bytes.'}
        $null=Assert-KhcStorageBudget -ReserveBytes 1MB
        Write-KhcNewJson $registration.SealPath ([ordered]@{schema=1;protocol='khc-mac-native-e2e-terminal-seal-v1';run_id=$RunId;registration_sha256=(Get-KhcRecycleV6Hash $registration.Path);protocol_sha256=$registration.Record.protocol_sha256;receipt_sha256=$ExpectedSha256;receipt_utf8=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);confirmed_utc=[DateTime]::UtcNow.ToString('o')})
        [pscustomobject]@{RunId=$RunId;State='remote-terminal-sealed';Status=$receipt.status;ChildrenAbsent=$true}
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $serialLock){$serialLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Get-KhcMacReferenceKind {
    param([string]$Protocol)
    $base='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\'
    $keep=(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\')
    switch -CaseSensitive ($Protocol){
        'khc-mac-canterbury-reference-v1' {$prefix='mac-canterbury-reference';$seconds=1800;$continuous=$false}
        'khc-mac-canterbury-continuous-reference-v1' {$prefix='mac-canterbury-continuous-reference';$seconds=180;$continuous=$true}
        default {throw 'Unknown reference protocol; no fallback is allowed.'}
    }
    [pscustomobject]@{Protocol=$Protocol;Worker=$base+$prefix+'.ps1';ProtocolPath=$keep+$prefix+'-protocol.json';TimeoutSeconds=$seconds;Prefix=$prefix;Continuous=$continuous}
}

function Assert-KhcMacReferenceInvocationPair {
    param([string]$Protocol,[string]$Worker,[string]$ProtocolPath,[int]$TimeoutSeconds)
    $kind=Get-KhcMacReferenceKind $Protocol
    if($Worker -cne $kind.Worker -or $ProtocolPath -cne $kind.ProtocolPath -or $TimeoutSeconds -ne $kind.TimeoutSeconds){throw 'Reference worker/protocol/path/timeout fixed pair mismatch.'}
}

function Assert-KhcMacContinuousProofSummary {
    param([Collections.IDictionary]$Summary,[string]$RunId,[string]$ProtocolSha256,[string]$ArchiveSha256,[long]$ArchiveBytes)
    $fields=@('schema','protocol','run_id','protocol_sha256','endpoint_sha256','archive_bytes','archive_sha256','receipt_sha256','status','exit','children_absent','cleanup_allowed','report_sha256','capture_count','cli_count','pair_count','purpose','superiority_decision_allowed')
    if($Summary.Count -ne 18 -or @($Summary.Keys|Where-Object {$_ -cnotin $fields}).Count -or $Summary.schema -isnot [long] -and $Summary.schema -isnot [int]){throw 'Continuous proof summary fields/schema type.'}
    foreach($key in @('protocol','run_id','protocol_sha256','endpoint_sha256','archive_sha256','receipt_sha256','status','purpose')){if($Summary[$key] -isnot [string]){throw 'Continuous proof identity must be typed strings.'}}
    if($Summary.schema -ne 1 -or $Summary.protocol -cne 'khc-mac-canterbury-continuous-reference-v1' -or $Summary.run_id -cne $RunId -or $Summary.protocol_sha256 -cne $ProtocolSha256 -or $Summary.archive_sha256 -cne $ArchiveSha256 -or $Summary.archive_bytes -ne $ArchiveBytes -or $ArchiveBytes -lt 1 -or $ArchiveBytes -gt 1MB -or $Summary.purpose -cne 'training-reference-only' -or $Summary.superiority_decision_allowed -isnot [bool] -or $Summary.superiority_decision_allowed){throw 'Continuous proof identity/scope mismatch.'}
    foreach($key in @('endpoint_sha256','archive_sha256','receipt_sha256','protocol_sha256')){if($Summary[$key] -isnot [string] -or $Summary[$key] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Continuous proof SHA type.'}}
    if($Summary.endpoint_sha256 -cne '4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42'){throw 'Continuous endpoint source pin mismatch.'}
    foreach($key in @('archive_bytes','exit','capture_count','cli_count','pair_count')){if($Summary[$key] -isnot [int] -and $Summary[$key] -isnot [long]){throw 'Continuous proof integer type.'}}
    if($Summary.children_absent -isnot [bool] -or $Summary.cleanup_allowed -isnot [bool] -or $Summary.children_absent -ne $Summary.cleanup_allowed -or $Summary.status -cnotin @('completed-reference','failed') -or $Summary.exit -ne $(if($Summary.status -ceq 'completed-reference'){0}else{1})){throw 'Continuous proof outcome/closure type.'}
    if($Summary.capture_count -lt 0 -or $Summary.capture_count -gt 64 -or $Summary.cli_count -lt 0 -or $Summary.cli_count -gt 42 -or $Summary.pair_count -lt 0 -or $Summary.pair_count -gt 21){throw 'Continuous proof counts.'}
    if($Summary.status -ceq 'completed-reference'){
        if(-not $Summary.cleanup_allowed -or $Summary.capture_count -ne 64 -or $Summary.cli_count -ne 42 -or $Summary.pair_count -ne 21 -or $Summary.report_sha256 -isnot [string] -or $Summary.report_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Incomplete successful continuous proof.'}
    }elseif($null -ne $Summary.report_sha256){throw 'Failed proof may not claim a successful report.'}
}

function Assert-KhcMacContinuousSealData {
    param([Collections.IDictionary]$Seal,[string]$RunId,[string]$RegistrationSha256,[string]$ProtocolSha256,[string]$ProofPath,[string]$ProofSha256,[long]$ProofBytes)
    $fields=@('schema','protocol','run_id','registration_sha256','protocol_sha256','receipt_sha256','receipt_utf8','confirmed_utc','proof_path','proof_sha256','proof_bytes','verifier_sha256')
    foreach($key in @('protocol','run_id','registration_sha256','protocol_sha256','receipt_sha256','receipt_utf8','proof_path','proof_sha256','verifier_sha256')){if($Seal[$key] -isnot [string]){throw 'Continuous seal identities must be typed strings.'}}
    if($Seal.Count -ne 12 -or @($Seal.Keys|Where-Object {$_ -cnotin $fields}).Count -or ($Seal.schema -isnot [int] -and $Seal.schema -isnot [long]) -or $Seal.schema -ne 1 -or $Seal.protocol -cne 'khc-mac-continuous-reference-terminal-seal-v1' -or $Seal.run_id -cne $RunId -or $Seal.registration_sha256 -cne $RegistrationSha256 -or $Seal.protocol_sha256 -cne $ProtocolSha256 -or $Seal.proof_path -cne $ProofPath -or $Seal.proof_sha256 -cne $ProofSha256 -or ($Seal.proof_bytes -isnot [int] -and $Seal.proof_bytes -isnot [long]) -or $Seal.proof_bytes -ne $ProofBytes -or $ProofBytes -lt 1 -or $ProofBytes -gt 1MB -or $Seal.receipt_utf8 -isnot [string] -or $Seal.receipt_sha256 -isnot [string] -or $Seal.receipt_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $Seal.verifier_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Continuous private seal/proof binding mismatch.'}
    $stamp=[DateTime]::MinValue
    if($Seal.confirmed_utc -is [DateTime]){if($Seal.confirmed_utc.Kind -ne [DateTimeKind]::Utc){throw 'Continuous seal time must be UTC.'}}
    elseif($Seal.confirmed_utc -isnot [string] -or -not [DateTime]::TryParseExact($Seal.confirmed_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp) -or $stamp.Kind -ne [DateTimeKind]::Utc){throw 'Continuous seal timestamp.'}
}

function Get-KhcMacContinuousVerifierPin {
    return '24a6b9d575820be99ba92fac913dc5a36ec712f7efe6dfa905e4cc66bc748cd5'
}

function Assert-KhcMacContinuousProofCopy {
    param([byte[]]$Bytes,[string]$ExpectedSha256,[long]$ExpectedBytes)
    if($null -eq $Bytes -or $Bytes.Length -lt 1 -or $Bytes.Length -gt 1MB -or $Bytes.Length -ne $ExpectedBytes -or $ExpectedSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() -cne $ExpectedSha256){throw 'Existing continuous private proof differs; retained unchanged.'}
}

function Invoke-KhcMacContinuousProofVerifier {
    param([string]$ArchivePath='',[string]$ProtocolBase64='',[string]$ProtocolSha256,[string]$RunId='', [switch]$ProtocolOnly,[switch]$AllowNoncanonical)
    $directory='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc'
    $helper=Join-Path $directory 'mac-continuous-reference-proof.py'
    $pins=@{
        'mac-continuous-reference-proof.py'=(Get-KhcMacContinuousVerifierPin)
        'mac-canterbury-continuous-reference.py'='4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42'
        'mac-canterbury-reference.py'='a73c73df659adac86160661c53e48098873c298c4e94489773b8169d8ac421a4'
        'mac-continuous-cpu-observer.py'='416687bc9460f0264e4f0620cce34a257c7647916fa1a71ccf66a86750fa3ffd'
        'mac-finite-supervisor.py'='51a0dcca109e302543b9a643f7d255813163cae64c4c0404dc74c7b9b5932b30'
    }
    foreach($name in $pins.Keys){$path=Assert-KhcPlainPath (Join-Path $directory $name);if((Get-KhcRecycleV6Hash $path) -cne $pins[$name]){throw 'Pinned continuous verifier/dependency changed.'}}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName='C:\Users\IMT\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    foreach($arg in @('-I','-B',$helper)){$info.ArgumentList.Add($arg)}
    if($ProtocolOnly){
        $protocolBytes=[Convert]::FromBase64String($ProtocolBase64)
        if($protocolBytes.Length -lt 1 -or $protocolBytes.Length -gt 65536){throw 'Continuous protocol input bound.'}
        $ProtocolSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($protocolBytes)).ToLowerInvariant()
        foreach($arg in @('--verify-protocol','--protocol-base64',$ProtocolBase64,'--protocol-sha',$ProtocolSha256)){$info.ArgumentList.Add($arg)}
        if($AllowNoncanonical){$info.ArgumentList.Add('--allow-noncanonical')}
    }else{
        $archive=Read-KhcBoundedSnapshotBytes $ArchivePath 1048576
        $archiveSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archive)).ToLowerInvariant()
        foreach($arg in @('--verify','--archive',$ArchivePath,'--protocol-sha',$ProtocolSha256,'--run-id',$RunId)){$info.ArgumentList.Add($arg)}
    }
    $scan=Get-KhcChargeScanContext;$scanLease=$null;$spawned=$false
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try{
        if($null -ne $scan){
            Assert-KhcVerifierQuarantineClear
            $scanPins=@{};foreach($name in $pins.Keys){$scanPins[(Join-Path $directory $name)]=$pins[$name]}
            if(-not $ProtocolOnly){$scanPins[$ArchivePath]=$archiveSha}
            $scanLease=Enter-KhcChargeScanLeafLease $scanPins
            $scanKey=Get-KhcChargeScanKey 'continuous' @($info.ArgumentList) $scanLease.Identity
            if($scan.Results.ContainsKey($scanKey)){return (Copy-KhcChargeScanSummary $scan.Results[$scanKey])}
        }
        if(-not $process.Start()){throw 'Continuous verifier start failed.'};$spawned=$true
        $output=$process.StandardOutput.ReadToEndAsync();$errorOutput=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(15000)){$process.Kill($true);throw 'Continuous verifier timeout.'}
        $text=$output.GetAwaiter().GetResult();$errors=$errorOutput.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0 -or $errors.Length -gt 0 -or [Text.Encoding]::UTF8.GetByteCount($text) -gt 16384){throw 'Continuous raw proof/protocol validation failed.'}
        $bytes=[Text.Encoding]::UTF8.GetBytes($text);$sha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $summary=ConvertFrom-KhcBoundedJsonSnapshot $bytes $sha 16384
        if($ProtocolOnly){
            $fields=@('schema','protocol','protocol_sha256','endpoint_sha256','purpose','superiority_decision_allowed','windows_max_entries','windows_timeout_seconds')
            if($summary.Count -ne 8 -or @($summary.Keys|Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $summary.schema 1) -or $summary.protocol -cne 'khc-mac-canterbury-continuous-reference-v1' -or $summary.protocol_sha256 -cne $ProtocolSha256 -or $summary.endpoint_sha256 -cne $pins['mac-canterbury-continuous-reference.py'] -or $summary.purpose -cne 'training-reference-only' -or $summary.superiority_decision_allowed -isnot [bool] -or $summary.superiority_decision_allowed -or -not (Test-KhcMacNativeE2eJsonEqual $summary.windows_max_entries 96) -or -not (Test-KhcMacNativeE2eJsonEqual $summary.windows_timeout_seconds 180)){throw 'Continuous protocol verifier summary mismatch.'}
        }else{
            Assert-KhcMacContinuousProofSummary $summary $RunId $ProtocolSha256 $archiveSha $archive.Length
            if((Get-KhcRecycleV6Hash $ArchivePath) -cne $archiveSha){throw 'Continuous proof changed during verification.'}
        }
        if($null -ne $scan){$scan.Results[$scanKey]=Copy-KhcChargeScanSummary $summary;$scan.Leases.Add($scanLease.Handles);$scanLease=$null}
        return $summary
    }finally{
        if($null -ne $scan){$held=if($null -ne $scanLease){$scanLease.Handles}else{$null};Complete-KhcVerifierReadLease $process $spawned $held}
        else{$process.Dispose()}
    }
}

function Invoke-KhcMacContinuousRemote {
    param([ValidateSet('run','inspect','bundle','read-terminal')][string]$Mode,[string]$RunId,[string]$ProtocolSha256)
    if($RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $ProtocolSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Continuous remote command identity.'}
    $root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019'
    if($Mode -cin @('bundle','read-terminal')){
        $script="$root/tools/mac-continuous-reference-proof.py";$sha=Get-KhcMacContinuousVerifierPin;$tail='--'+$Mode
    }else{
        $script="$root/tools/mac-canterbury-continuous-reference.py";$sha='4092605d8384666954dd00994a0145d4e81656096d617a957a1512fb9bc34a42'
        $tail="--windows-run-id $RunId --protocol-sha $ProtocolSha256";if($Mode -ceq 'inspect'){$tail+=' --inspect'}
    }
    $command='[ "$(/usr/bin/shasum -a 256 {0} | /usr/bin/cut -d '' '' -f 1)" = "{1}" ] && /usr/bin/python3 -I -B {0} {2}' -f $script,$sha,$tail
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName='C:\Program Files\Git\usr\bin\ssh.exe';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
    foreach($arg in @('-o','BatchMode=yes','-o','ConnectTimeout=10','-o','StrictHostKeyChecking=yes','m3mb14',$command)){$info.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        if(-not $process.Start()){throw 'Continuous SSH start failed.'};$started=$true
        $readers=@($process.StandardOutput,$process.StandardError);$buffers=@([char[]]::new(4096),[char[]]::new(4096));$logs=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new());$done=@($false,$false)
        $tasks=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096))
        $timer=[Diagnostics.Stopwatch]::StartNew();$nextBudget=0.0;$deadline=if($Mode -ceq 'run'){130}else{30};$cap=if($Mode -ceq 'bundle'){1500000}else{65536}
        while($true){
            for($side=0;$side -lt 2;$side++){
                if(-not $done[$side] -and $tasks[$side].IsCompleted){$n=$tasks[$side].GetAwaiter().GetResult();if($n -eq 0){$done[$side]=$true}else{
                    $null=$logs[$side].Append($buffers[$side],0,$n)
                    if([Text.Encoding]::UTF8.GetByteCount($logs[$side].ToString()) -gt $(if($side -eq 0){$cap}else{16384})){throw 'Continuous SSH stream bound.'}
                    $tasks[$side]=$readers[$side].ReadAsync($buffers[$side],0,4096)
                }}
            }
            if($timer.Elapsed.TotalSeconds -gt $deadline){throw 'Continuous SSH observation deadline; remote remains unsealed.'}
            if($timer.Elapsed.TotalSeconds -ge $nextBudget){$null=Assert-KhcStorageBudget;$nextBudget=$timer.Elapsed.TotalSeconds+5}
            if($process.HasExited -and $done[0] -and $done[1]){break}
            Start-Sleep -Milliseconds 100
        }
        [pscustomobject]@{Bytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($logs[0].ToString());ExitCode=$process.ExitCode;ErrorBytes=[Text.Encoding]::UTF8.GetByteCount($logs[1].ToString())}
    }finally{try{if($started -and -not $process.HasExited){$process.Kill($true);$null=$process.WaitForExit(5000)}}finally{$process.Dispose()}}
}

function Assert-KhcMacReferenceProtocolData {
    param([Collections.IDictionary]$Protocol)
    if($Protocol.protocol -ceq 'khc-mac-canterbury-continuous-reference-v1'){
        $null=Invoke-KhcMacContinuousProofVerifier -ProtocolBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Protocol|ConvertTo-Json -Depth 30 -Compress)))) -ProtocolSha256 '' -ProtocolOnly -AllowNoncanonical
        return
    }
    $profiles=@(@{id='khc';strategy='portfolio-trial';encode_workers=1;decode_workers=1},@{id='lzma2';level=9;dictionary_bytes=8388608;fast_bytes=273;solid=$true;sort_by_type=$true;store_mtime=$true;store_ctime=$false;store_atime=$false;encode_workers=1;decode_workers=1},@{id='ppmd';level=9;memory_bytes=67108864;order=16;solid=$true;sort_by_type=$true;store_mtime=$true;store_ctime=$false;store_atime=$false;encode_workers=1;decode_workers=1})
    $fixed=@{schema=1;protocol='khc-mac-canterbury-reference-v1';task='goal-restore-20261019';host='m3mb14';root='/Users/szk/Library/Caches/Kagayoi/UnLhaRe/goal-restore-20261019';run='mac-canterbury-reference-20261026';purpose='training-reference-only';superiority_decision_allowed=$false;windows_max_bytes=8388608;windows_max_entries=96;windows_timeout_seconds=1800;remote_max_bytes=167772160;remote_max_entries=512;campaign_seconds=1700;encode_seconds=60;decode_seconds=20;cpu_baseline_limit_percent=15;cpu_interval_limit_percent=30;thermal_state_required=0;ac_power_required=$true;rss_eligibility_bytes=134217728;cpu_per_wall_eligibility_max=1.2;warmups=1;orders=@('ABC','BCA','CAB','ACB','CBA','BAC');method_profiles=$profiles;source_sha256='030eaef48e23004e7902bfe81c0ba28eca15b505252ee59b5d0caa1e43926c3f';cli_sha256='5338389a94ecad6296fab1686398ef7d01efaf1783fb3fa90e54fa61d0fa9629';e2e_passed_receipt_sha256='0f9b1a1cb744775b64c7cdcbb485efebb2e5f4ba2cf0d58c99ee903255676299';reason='canterbury-training-reference-pilot-no-superiority-decision'}
    $pins=@('sevenzip_sha256','input_manifest_sha256','input_zip_sha256','endpoint_sha256','measurement_sha256','system_metrics_sha256')
    $fields=@($fixed.Keys)+$pins
    if($Protocol.Count -ne 35 -or @($Protocol.Keys | Where-Object {$_ -cnotin $fields}).Count){throw 'Reference protocol must have exactly the 35 preregistered fields.'}
    foreach($key in $fixed.Keys){if(-not (Test-KhcMacNativeE2eJsonEqual $Protocol[$key] $fixed[$key])){throw "Reference protocol fixed criterion mismatch: $key"}}
    foreach($key in $pins){if($Protocol[$key] -isnot [string] -or $Protocol[$key] -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Reference protocol artifact SHA format.'}}
}

function Assert-KhcMacReferenceManifestData {
    param([Collections.IDictionary]$Manifest)
    $fields=@('schema','corpus','purpose','files','bytes','manifest_sha256','source_container_sha256','entries')
    $profile=Get-KhcPortfolioInputProfile 'CanterburyDevelopmentKcs1CountLength20261020'
    if($Manifest.Count -ne 8 -or @($Manifest.Keys | Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $Manifest.schema 1) -or $Manifest.corpus -cne 'Canterbury11' -or $Manifest.purpose -cne 'training-reference-only' -or -not (Test-KhcMacNativeE2eJsonEqual $Manifest.files 11) -or -not (Test-KhcMacNativeE2eJsonEqual $Manifest.bytes 2810784) -or $Manifest.manifest_sha256 -cne $profile.ManifestSha256 -or $Manifest.source_container_sha256 -cne $profile.ZipSha256 -or @($Manifest.entries).Count -ne 11){throw 'Reference manifest training metadata/schema mismatch.'}
    $builder=[Text.StringBuilder]::new();$total=0L
    for($i=0;$i -lt 11;$i++){
        $row=$Manifest.entries[$i];$expected=$profile.Entries[$i]
        $wanted=@{name=$expected.name;bytes=$expected.bytes;sha256=$expected.sha256}
        if(-not (Test-KhcMacNativeE2eJsonEqual $row $wanted)){throw 'Reference input name/length/hash differs from fixed source metadata.'}
        $total+=[long]$row.bytes
        $null=$builder.Append($row.name).Append([char]9).Append(([long]$row.bytes).ToString([Globalization.CultureInfo]::InvariantCulture)).Append([char]9).Append($row.sha256).Append([char]10)
    }
    if($total -ne 2810784 -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($builder.ToString()))).ToLowerInvariant() -cne $profile.ManifestSha256){throw 'Reference ordinal input manifest digest/total mismatch.'}
}

function Assert-KhcMacReferenceMetricData {
    param([Collections.IDictionary]$Metric,[Collections.IDictionary]$Protocol,[bool]$Encode)
    $fields=@('elapsed_ns','user_seconds','system_seconds','peak_rss_bytes','cpu_per_wall','normal_exit','exit_code','signal','cpu_interval_percent','environment_before','environment_after')
    if($Metric.Count -ne 11 -or @($Metric.Keys | Where-Object {$_ -cnotin $fields}).Count){throw 'Reference metric fields mismatch.'}
    foreach($key in @('elapsed_ns','peak_rss_bytes')){if(($Metric[$key] -isnot [int] -and $Metric[$key] -isnot [long]) -or $Metric[$key] -le 0){throw 'Reference elapsed/RSS must be positive integers in ns/bytes.'}}
    foreach($key in @('user_seconds','system_seconds','cpu_per_wall','cpu_interval_percent')){if(($Metric[$key] -isnot [int] -and $Metric[$key] -isnot [long] -and $Metric[$key] -isnot [double] -and $Metric[$key] -isnot [decimal]) -or [double]::IsNaN([double]$Metric[$key]) -or [double]::IsInfinity([double]$Metric[$key]) -or $Metric[$key] -lt 0){throw 'Reference metric is not finite/nonnegative.'}}
    if($Metric.normal_exit -isnot [bool] -or -not $Metric.normal_exit -or -not (Test-KhcMacNativeE2eJsonEqual $Metric.exit_code 0) -or $null -ne $Metric.signal -or $Metric.cpu_interval_percent -gt 100){throw 'Only complete normal-exit pairs may enter the reference report.'}
    $ratio=([double]$Metric.user_seconds+[double]$Metric.system_seconds)/([double]$Metric.elapsed_ns/1e9)
    if([math]::Abs([double]$Metric.cpu_per_wall-$ratio) -gt [math]::Max(1e-9,[math]::Abs($ratio)*1e-6)){throw 'Reference CPU/wall representation differs from wait4 metrics.'}
    $eligible=$true
    foreach($env in @($Metric.environment_before,$Metric.environment_after)){
        $envFields=@('schema','cpu_ticks','logical_cpus','thermal_state','ac_power')
        if($env -isnot [Collections.IDictionary] -or $env.Count -ne 5 -or @($env.Keys | Where-Object {$_ -cnotin $envFields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $env.schema 1) -or -not (Test-KhcMacNativeE2eJsonEqual $env.logical_cpus 14) -or ($env.thermal_state -isnot [int] -and $env.thermal_state -isnot [long]) -or $env.thermal_state -notin @(0,1,2,3) -or $env.ac_power -isnot [bool] -or @($env.cpu_ticks).Count -ne 4){throw 'Reference native OS observation schema mismatch.'}
        foreach($tick in $env.cpu_ticks){if(($tick -isnot [int] -and $tick -isnot [long]) -or $tick -lt 0 -or $tick -gt 4294967295L){throw 'Reference host tick is not uint32.'}}
        if($env.thermal_state -ne 0 -or -not $env.ac_power){$eligible=$false}
    }
    $total=0L;$idle=0L
    for($i=0;$i -lt 4;$i++){$delta=[long]$Metric.environment_after.cpu_ticks[$i]-[long]$Metric.environment_before.cpu_ticks[$i];if($delta -lt 0){$delta+=4294967296L};$total+=$delta;if($i -eq 2){$idle=$delta}}
    if($total -eq 0){throw 'Host tick interval is unobservable; zero CPU cannot be fabricated.'}
    $cpu=100.0*($total-$idle)/$total
    if([math]::Abs([double]$Metric.cpu_interval_percent-$cpu) -gt 1e-6){throw 'Host interval CPU differs from the native before/after ticks.'}
    $seconds=if($Encode){$Protocol.encode_seconds}else{$Protocol.decode_seconds}
    # 許容誤差は表現の一致だけ。資格上限128MiB/1.2/30%自体は緩めない。
    if($Metric.elapsed_ns -gt $seconds*1000000000L -or $Metric.peak_rss_bytes -gt $Protocol.rss_eligibility_bytes -or $Metric.cpu_per_wall -gt $Protocol.cpu_per_wall_eligibility_max -or $Metric.cpu_interval_percent -gt $Protocol.cpu_interval_limit_percent){$eligible=$false}
    return $eligible
}

function Assert-KhcMacReferenceReportData {
    param([Collections.IDictionary]$Report,[Collections.IDictionary]$Protocol,[string]$ProtocolSha256,[string]$RunId,[Collections.IDictionary]$Manifest)
    Assert-KhcMacReferenceProtocolData $Protocol;Assert-KhcMacReferenceManifestData $Manifest
    $fields=@('schema','purpose','superiority_decision_allowed','reason','windows_run_id','protocol_sha256','source_sha256','cli_sha256','sevenzip_sha256','e2e_passed_receipt_sha256','input_manifest_sha256','input_zip_sha256','input_files','input_bytes','rss_unit','time_scope','cpu_observation','trials','status','error')
    if($Report.Count -ne 20 -or @($Report.Keys | Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $Report.schema 1) -or $Report.windows_run_id -cne $RunId -or $RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $Report.protocol_sha256 -cne $ProtocolSha256 -or $ProtocolSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or -not (Test-KhcMacNativeE2eJsonEqual $Report.input_files 11) -or -not (Test-KhcMacNativeE2eJsonEqual $Report.input_bytes 2810784) -or $Report.rss_unit -cne 'bytes' -or $Report.time_scope -cne 'CLI spawn-to-wait4 including launch and scheduling' -or $Report.cpu_observation -cne 'host-tick interval averages before/after each CLI' -or $Report.status -cnotin @('completed-reference','stopped','failed') -or ($null -ne $Report.error -and ($Report.error -isnot [string] -or $Report.error.Length -gt 4096))){throw 'Reference report identity/schema/unit mismatch.'}
    foreach($key in @('purpose','superiority_decision_allowed','reason','source_sha256','cli_sha256','sevenzip_sha256','e2e_passed_receipt_sha256','input_manifest_sha256','input_zip_sha256')){if(-not (Test-KhcMacNativeE2eJsonEqual $Report[$key] $Protocol[$key])){throw 'Reference report scope/pin mismatch.'}}
    if($Report.trials -isnot [Collections.IList] -or $Report.trials.Count -gt 21 -or ($Report.status -ceq 'completed-reference' -and ($Report.trials.Count -ne 21 -or $null -ne $Report.error))){throw 'Reference report is not the required complete/prefix set.'}
    $orders=@('ABC')+@($Protocol.orders);$methods=@{A='khc';B='lzma2';C='ppmd'};$sizes=@{}
    for($i=0;$i -lt $Report.trials.Count;$i++){
        $trial=$Report.trials[$i];$round=[int][math]::Floor($i/3);$position=$i%3;$method=$methods[[string]$orders[$round][$position]]
        $trialFields=@('method','warmup','round','position','archive_bytes','archive_sha256','restored_manifest_sha256','encode','decode')
        if($trial -isnot [Collections.IDictionary] -or $trial.Count -ne 9 -or @($trial.Keys | Where-Object {$_ -cnotin $trialFields}).Count -or $trial.method -cne $method -or $trial.warmup -isnot [bool] -or $trial.warmup -ne ($round -eq 0) -or -not (Test-KhcMacNativeE2eJsonEqual $trial.round ($round-1)) -or -not (Test-KhcMacNativeE2eJsonEqual $trial.position $position) -or ($trial.archive_bytes -isnot [int] -and $trial.archive_bytes -isnot [long]) -or $trial.archive_bytes -le 0 -or $trial.archive_sha256 -isnot [string] -or $trial.archive_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $trial.restored_manifest_sha256 -cne $Manifest.manifest_sha256){throw 'Reference complete-pair order/archive/restore mismatch.'}
        if($sizes.ContainsKey($method) -and $sizes[$method] -ne $trial.archive_bytes){throw 'Reference archive bytes changed within the same method.'};$sizes[$method]=$trial.archive_bytes
        $encode=Assert-KhcMacReferenceMetricData $trial.encode $Protocol $true
        $decode=Assert-KhcMacReferenceMetricData $trial.decode $Protocol $false
        if((-not $encode -or -not $decode) -and ($Report.status -ceq 'completed-reference' -or $i -ne $Report.trials.Count-1)){throw 'Reference report hides a nonfinal eligibility failure.'}
    }
}

function Assert-KhcMacReferenceReceiptData {
    param([Collections.IDictionary]$Receipt,[Collections.IDictionary]$Protocol,[string]$ProtocolSha256,[string]$RunId,[Collections.IDictionary]$Manifest)
    Assert-KhcMacReferenceProtocolData $Protocol;Assert-KhcMacReferenceManifestData $Manifest
    $pins=@('endpoint_sha256','measurement_sha256','system_metrics_sha256','input_manifest_sha256','input_zip_sha256','source_sha256','cli_sha256','sevenzip_sha256','e2e_passed_receipt_sha256','purpose','superiority_decision_allowed','reason')
    $fields=@('schema','protocol','windows_run_id','protocol_sha256','children_absent','exit','status','report_sha256','report_base64','error')+$pins
    if($Receipt.Count -ne 22 -or @($Receipt.Keys | Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $Receipt.schema 1) -or $Receipt.protocol -cne 'khc-mac-canterbury-reference-terminal-v1' -or $RunId -cnotmatch '\A[0-9a-f]{32}\z' -or $Receipt.windows_run_id -cne $RunId -or $ProtocolSha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $Receipt.protocol_sha256 -cne $ProtocolSha256 -or $Receipt.children_absent -isnot [bool] -or -not $Receipt.children_absent -or ($Receipt.exit -isnot [int] -and $Receipt.exit -isnot [long]) -or $Receipt.exit -notin @(0,1) -or $Receipt.status -cnotin @('completed-reference','stopped','failed') -or ($Receipt.exit -eq 0) -ne ($Receipt.status -ceq 'completed-reference') -or ($null -ne $Receipt.error -and ($Receipt.error -isnot [string] -or $Receipt.error.Length -gt 4096))){throw 'Reference terminal identity/status/absence mismatch.'}
    foreach($key in $pins){if(-not (Test-KhcMacNativeE2eJsonEqual $Receipt[$key] $Protocol[$key])){throw 'Reference terminal scope/artifact pin mismatch.'}}
    $bytes=$null;$report=$null
    if($null -ne $Receipt.report_base64){
        if($Receipt.report_base64 -isnot [string] -or $Receipt.report_base64.Length -gt 45000 -or $Receipt.report_sha256 -isnot [string]){throw 'Reference report byte bound/type mismatch.'}
        $bytes=[Convert]::FromBase64String($Receipt.report_base64);$report=ConvertFrom-KhcBoundedJsonSnapshot $bytes $Receipt.report_sha256 32768
        Assert-KhcMacReferenceReportData $report $Protocol $ProtocolSha256 $RunId $Manifest
        if($report.status -cne $Receipt.status -or $report.error -cne $Receipt.error){throw 'Reference report/terminal outcome mismatch.'}
    }elseif($null -ne $Receipt.report_sha256){throw 'Reference report hash without bytes.'}
    if($Receipt.exit -eq 0 -and ($null -eq $report -or $null -ne $Receipt.error)){throw 'Completed reference requires its complete report, not a superiority verdict.'}
    [pscustomobject]@{Report=$report;ReportBytes=$bytes;Receipt=$Receipt}
}

function Read-KhcMacReferenceProtocol {
    param([string]$Path,[string]$Sha256)
    if($Path -cnotin @((Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-reference-protocol.json'),(Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-continuous-reference-protocol.json'))){throw 'Use an exact current-task reference protocol path.'}
    $bytes=Read-KhcBoundedSnapshotBytes $Path
    $data=ConvertFrom-KhcBoundedJsonSnapshot $bytes $Sha256
    Assert-KhcMacReferenceProtocolData $data
    $kind=Get-KhcMacReferenceKind $data.protocol
    if($Path -cne $kind.ProtocolPath){throw 'Reference protocol type/path mismatch.'}
    if($kind.Continuous){$null=Invoke-KhcMacContinuousProofVerifier -ProtocolBase64 ([Convert]::ToBase64String($bytes)) -ProtocolSha256 $Sha256 -ProtocolOnly}
    [pscustomobject]@{Data=$data;Raw=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);Sha256=$Sha256}
}

function Assert-KhcMacReferenceSealState {
    param([bool]$Required,[bool]$Registered,[bool]$Sealed,[switch]$RequireSeal)
    if($Required -ne $Registered -or ($Sealed -and -not $Registered) -or ($RequireSeal -and $Required -and -not $Sealed)){throw 'Reference private classification/terminal seal is missing; cleanup prohibited.'}
}

function Get-KhcMacReferenceRegistration {
    param([string]$State,[string]$RunId,[Collections.IDictionary]$Reserve,[switch]$RequireInvocation,[switch]$RequireSeal)
    $root=Assert-KhcRecycleV6PrivatePath (Join-Path $State 'recycle-v6') -ProtectedRoot
    $path=Join-Path $root "mac-reference-$RunId-registration.json";$sealPath=Join-Path $root "mac-reference-$RunId.json"
    $required=$Reserve.Contains('remote_reference_required')
    $null=Assert-KhcRemoteReferenceClassData ($Reserve.Contains('remote_native_e2e_required')) $required
    Assert-KhcMacReferenceSealState $required (Test-Path -LiteralPath $path) (Test-Path -LiteralPath $sealPath) -RequireSeal:$RequireSeal
    if(-not $required){return $null}
    if($Reserve.remote_reference_required -isnot [bool] -or -not $Reserve.remote_reference_required -or $Reserve.remote_reference_protocol_sha256 -isnot [string] -or $Reserve.remote_reference_protocol_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $Reserve.max_bytes -ne 8MB -or $Reserve.max_entries -ne 96){throw 'Private reference reserve type/resources mismatch.'}
    $record=Read-KhcRecycleV6PrivateJson $path;$directory=Join-Path (Join-Path $State 'runs') $RunId
    $fields=@('schema','protocol','run_id','record_sha256','worker_path','worker_sha256','invocation_sha256','protocol_sha256','protocol_utf8','manifest_utf8')
    if($record.Count -ne 10 -or @($record.Keys | Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $record.schema 1)){throw 'Private reference registration fields/schema mismatch.'}
    foreach($field in $fields | Where-Object {$_ -cne 'schema'}){if($record[$field] -isnot [string]){throw 'Private reference identities must be strings.'}}
    if($record.protocol -cne 'khc-mac-reference-registration-v1' -or $record.run_id -cne $RunId -or $record.record_sha256 -cne $Reserve.registration_sha256 -or $record.record_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path $directory 'run.json')) -or $record.protocol_sha256 -cne $Reserve.remote_reference_protocol_sha256 -or $record.worker_sha256 -cnotmatch '\A[0-9a-f]{64}\z' -or $record.invocation_sha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Private reference registration identity/hash mismatch.'}
    $protocol=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($record.protocol_utf8)) $record.protocol_sha256;Assert-KhcMacReferenceProtocolData $protocol
    $kind=Get-KhcMacReferenceKind $protocol.protocol
    Assert-KhcMacReferenceInvocationPair $kind.Protocol $record.worker_path $kind.ProtocolPath $protocol.windows_timeout_seconds
    if($kind.Continuous){$null=Invoke-KhcMacContinuousProofVerifier -ProtocolBase64 ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($record.protocol_utf8))) -ProtocolSha256 $record.protocol_sha256 -ProtocolOnly}
    $manifest=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($record.manifest_utf8)) $protocol.input_manifest_sha256;Assert-KhcMacReferenceManifestData $manifest
    $invocation=Join-Path $directory 'invocation.clixml'
    if($RequireInvocation -and -not (Test-Path -LiteralPath $invocation)){throw 'Reference invocation is not published.'}
    if((Test-Path -LiteralPath $invocation) -and (Get-KhcRecycleV6Hash $invocation) -cne $record.invocation_sha256){throw 'Public reference invocation differs from private binding.'}
    $data=[pscustomobject]@{Record=$record;Protocol=$protocol;Manifest=$manifest;Path=$path;SealPath=$sealPath}
    if(Test-Path -LiteralPath $sealPath){
        if($kind.Continuous){
            $seal=Read-KhcRecycleV6PrivateJson $sealPath
            $proofPath=Assert-KhcRecycleV6PrivatePath (Join-Path $root "mac-reference-$RunId-continuous-proof.zip")
            $proofBytes=Read-KhcBoundedSnapshotBytes $proofPath 1048576
            $proofSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($proofBytes)).ToLowerInvariant()
            Assert-KhcMacContinuousSealData $seal $RunId (Get-KhcRecycleV6Hash $path) $record.protocol_sha256 $proofPath $proofSha $proofBytes.Length
            if($seal.verifier_sha256 -cne (Get-KhcMacContinuousVerifierPin)){throw 'Continuous seal verifier source changed.'}
            $proof=Invoke-KhcMacContinuousProofVerifier -ArchivePath $proofPath -ProtocolSha256 $record.protocol_sha256 -RunId $RunId
            $null=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($seal.receipt_utf8)) $seal.receipt_sha256
            if(-not $proof.cleanup_allowed -or $proof.receipt_sha256 -cne $seal.receipt_sha256){throw 'Continuous sealed proof/receipt closure mismatch.'}
            return $data
        }
        $seal=Read-KhcRecycleV6PrivateJson $sealPath;$fields=@('schema','protocol','run_id','registration_sha256','protocol_sha256','receipt_sha256','receipt_utf8','confirmed_utc')
        if($seal.Count -ne 8 -or @($seal.Keys | Where-Object {$_ -cnotin $fields}).Count -or -not (Test-KhcMacNativeE2eJsonEqual $seal.schema 1) -or $seal.protocol -cne 'khc-mac-reference-terminal-seal-v1' -or $seal.run_id -cne $RunId -or $seal.registration_sha256 -cne (Get-KhcRecycleV6Hash $path) -or $seal.protocol_sha256 -cne $record.protocol_sha256 -or $seal.receipt_utf8 -isnot [string] -or $seal.receipt_sha256 -isnot [string]){throw 'Private reference terminal seal binding mismatch.'}
        $stamp=[DateTime]::MinValue
        if($seal.confirmed_utc -is [DateTime]){if($seal.confirmed_utc.Kind -ne [DateTimeKind]::Utc){throw 'Reference seal time must be UTC.'}}
        elseif($seal.confirmed_utc -isnot [string] -or -not [DateTime]::TryParseExact($seal.confirmed_utc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp) -or $stamp.Kind -ne [DateTimeKind]::Utc){throw 'Reference seal timestamp mismatch.'}
        $receipt=ConvertFrom-KhcBoundedJsonSnapshot ([Text.Encoding]::UTF8.GetBytes($seal.receipt_utf8)) $seal.receipt_sha256
        $null=Assert-KhcMacReferenceReceiptData $receipt $protocol $record.protocol_sha256 $RunId $manifest
    }
    return $data
}

function Assert-KhcMacReferenceCleanupSeal {
    param([object]$Run)
    $root=Join-Path $Run.StateRoot 'recycle-v6';$reservePath=Join-Path $root "$($Run.RunId).reserve.json"
    if(-not (Test-Path -LiteralPath $reservePath)){if((Test-Path -LiteralPath (Join-Path $root "mac-reference-$($Run.RunId)-registration.json")) -or (Test-Path -LiteralPath (Join-Path $root "mac-reference-$($Run.RunId).json"))){throw 'Reference metadata lost its private reserve.'};return}
    $reserve=Read-KhcRecycleV6PrivateJson $reservePath
    $null=Get-KhcMacReferenceRegistration $Run.StateRoot $Run.RunId $reserve -RequireSeal
}

function Confirm-KhcMacReferenceTerminal {
    param([Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{32}\z')][string]$RunId,[Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedSha256)
    $location=Get-KhcStorageRunLocation $RunId;$state=$location.StateRoot;$registrationLease=$null;$serialLock=$null;$cargoLock=$null
    try{
        $registrationLease=[Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $serialLock=[IO.File]::Open((Join-Path $state 'serial.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cargoLock=[Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        Assert-KhcNoPendingStorageRuns -AllowedRecordPath $location.RecordPath -AllowInactiveOwner
        $reserve=Get-KhcRecycleV6RunAnchor $state $RunId;$registration=Get-KhcMacReferenceRegistration $state $RunId $reserve -RequireInvocation
        if($null -eq $registration){throw 'Run is not a private reference registration.'}
        $runRecord=Get-Content -LiteralPath $location.RecordPath -Raw | ConvertFrom-Json
        if($ReceiptPath -cne (Join-Path $runRecord.work_directory 'reference-receipt.json')){throw 'Use the exact reference work receipt path.'}
        $bytes=Read-KhcBoundedSnapshotBytes $ReceiptPath;$receipt=ConvertFrom-KhcBoundedJsonSnapshot $bytes $ExpectedSha256
        if($registration.Protocol.protocol -ceq 'khc-mac-canterbury-continuous-reference-v1'){
            $workProof=Join-Path $runRecord.work_directory 'reference-proof.zip'
            $proof=Invoke-KhcMacContinuousProofVerifier -ArchivePath $workProof -ProtocolSha256 $registration.Record.protocol_sha256 -RunId $RunId
            if(-not $proof.cleanup_allowed -or $proof.receipt_sha256 -cne $ExpectedSha256){throw 'Continuous terminal lacks verified group closure or matching proof bytes; seal prohibited.'}
            $canonical=Invoke-KhcMacContinuousRemote -Mode inspect -RunId $RunId -ProtocolSha256 $registration.Record.protocol_sha256
            if($canonical.ExitCode -ne 0){
                if($proof.status -cne 'failed'){throw 'Successful continuous terminal requires endpoint inspect success.'}
                $canonical=Invoke-KhcMacContinuousRemote -Mode read-terminal -RunId $RunId -ProtocolSha256 $registration.Record.protocol_sha256
                if($canonical.ExitCode -ne 0){throw 'Failed continuous terminal canonical reread failed.'}
            }
            $canonicalSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canonical.Bytes)).ToLowerInvariant()
            if($canonicalSha -cne $ExpectedSha256 -or $canonical.Bytes.Length -ne $bytes.Length){throw 'Parent canonical continuous receipt differs from worker/proof bytes.'}
            $archive=Read-KhcBoundedSnapshotBytes $workProof 1048576
            if([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archive)).ToLowerInvariant() -cne $proof.archive_sha256){throw 'Work proof changed before private copy.'}
            $null=Assert-KhcStorageBudget -ReserveBytes 2MB
            Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 2MB
            $root=Assert-KhcRecycleV6PrivatePath (Join-Path $state 'recycle-v6') -ProtectedRoot
            $privateProof=Join-Path $root "mac-reference-$RunId-continuous-proof.zip"
            if(Test-Path -LiteralPath $privateProof){
                $null=Assert-KhcRecycleV6PrivatePath $privateProof
                Assert-KhcMacContinuousProofCopy (Read-KhcBoundedSnapshotBytes $privateProof 1048576) $proof.archive_sha256 $archive.Length
            }else{
                $stream=[IO.File]::Open($privateProof,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
                try{$stream.Write($archive);$stream.Flush($true)}finally{$stream.Dispose()}
            }
            $null=Assert-KhcRecycleV6PrivatePath $privateProof
            $private=Invoke-KhcMacContinuousProofVerifier -ArchivePath $privateProof -ProtocolSha256 $registration.Record.protocol_sha256 -RunId $RunId
            if(-not $private.cleanup_allowed -or $private.archive_sha256 -cne $proof.archive_sha256 -or $private.receipt_sha256 -cne $ExpectedSha256){throw 'Private continuous proof differs from canonical evidence.'}
            Write-KhcNewJson $registration.SealPath ([ordered]@{schema=1;protocol='khc-mac-continuous-reference-terminal-seal-v1';run_id=$RunId;registration_sha256=(Get-KhcRecycleV6Hash $registration.Path);protocol_sha256=$registration.Record.protocol_sha256;receipt_sha256=$ExpectedSha256;receipt_utf8=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);confirmed_utc=[DateTime]::UtcNow.ToString('o');proof_path=$privateProof;proof_sha256=$private.archive_sha256;proof_bytes=$private.archive_bytes;verifier_sha256=(Get-KhcMacContinuousVerifierPin)})
            [pscustomobject]@{RunId=$RunId;State='continuous-reference-terminal-sealed';Status=$private.status;ChildrenAbsent=$true;Purpose='training-reference-only';SuperiorityDecisionAllowed=$false}
            return
        }
        $verified=Assert-KhcMacReferenceReceiptData $receipt $registration.Protocol $registration.Record.protocol_sha256 $RunId $registration.Manifest
        if($null -ne $verified.ReportBytes -and (Get-KhcRecycleV6Hash (Join-Path $runRecord.work_directory 'reference-report.json')) -cne $receipt.report_sha256){throw 'Retained reference report differs from canonical raw bytes.'}
        $null=Assert-KhcStorageBudget -ReserveBytes 1MB;Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 1MB
        Write-KhcNewJson $registration.SealPath ([ordered]@{schema=1;protocol='khc-mac-reference-terminal-seal-v1';run_id=$RunId;registration_sha256=(Get-KhcRecycleV6Hash $registration.Path);protocol_sha256=$registration.Record.protocol_sha256;receipt_sha256=$ExpectedSha256;receipt_utf8=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);confirmed_utc=[DateTime]::UtcNow.ToString('o')})
        [pscustomobject]@{RunId=$RunId;State='reference-terminal-sealed';Status=$receipt.status;ChildrenAbsent=$true;Purpose='training-reference-only';SuperiorityDecisionAllowed=$false}
    }finally{if($null -ne $cargoLock){$cargoLock.Dispose()};if($null -ne $serialLock){$serialLock.Dispose()};if($null -ne $registrationLease){$registrationLease.Dispose()}}
}

function Get-KhcChargeScanContext {
    if(-not @(Get-PSCallStack | Where-Object {$_.FunctionName -ceq 'Get-KhcRecycleV6Charges'}).Count){return $null}
    $variable=Get-Variable -Name khcChargeScanMemo -ErrorAction SilentlyContinue
    if($null -ne $variable){return $variable.Value}
    return $null
}

function Get-KhcCandidateRegistrationContext {
    # 登録関数のローカルscopeだけを参照。旧parameter setはnullで遮蔽する。
    if(-not @(Get-PSCallStack | Where-Object {$_.FunctionName -ceq 'New-KhcStorageRun'}).Count){return $null}
    $variable=Get-Variable -Name khcCandidateRegistrationMemo -ErrorAction SilentlyContinue
    if($null -ne $variable){return $variable.Value}
    return $null
}

function Enter-KhcChargeScanLeafLease {
    param([Collections.IDictionary]$Pins)
    Initialize-KhcVerifierDirectoryHandle
    $handles=[Collections.Generic.List[IDisposable]]::new();$identities=[Collections.Generic.List[string]]::new()
    try{
        foreach($path in @($Pins.Keys | Sort-Object -CaseSensitive)){
            $null=Assert-KhcPlainPath $path
            $stream=[Khc.Storage.VerifierDirectoryHandle]::OpenLeaf($path);$handles.Add($stream)
            if($stream.Length -lt 1 -or $stream.Length -gt 1048576){throw 'Charge scan verification input bound.'}
            $hasher=[Security.Cryptography.SHA256]::Create()
            try{$sha=[Convert]::ToHexString($hasher.ComputeHash($stream)).ToLowerInvariant()}finally{$hasher.Dispose()}
            if($sha -cne $Pins[$path]){throw 'Charge scan verification input changed on held handle.'}
            $stream.Position=0;$identities.Add($path+'='+$sha)
        }
        return [pscustomobject]@{Handles=$handles;Identity=($identities -join "`n")}
    }catch{for($i=$handles.Count-1;$i -ge 0;$i--){$handles[$i].Dispose()};throw}
}

function Get-KhcChargeScanKey {
    param([string]$Kind,[string[]]$Arguments,[string]$RawIdentity='')
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -Depth 8 -InputObject @($Kind,@($Arguments),$RawIdentity)))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Copy-KhcChargeScanSummary {
    param([Collections.IDictionary]$Summary)
    return ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Compress -Depth 30 -InputObject $Summary)
}

function Get-KhcRecycleV6Charges {
    # candidate登録内だけ純粋検証を共有。各entryのgetter・raw照合・課金は毎回実行する。
    $khcChargeScanMemo=Get-KhcCandidateRegistrationContext
    $ownsMemo=$null -eq $khcChargeScanMemo
    if($ownsMemo){$khcChargeScanMemo=@{Results=@{};Leases=[Collections.Generic.List[object]]::new()}}
    try {
    $mandatory=Get-KhcRecycleV6AnchorRoot
    $null=Assert-KhcRecycleV6PrivatePath $mandatory -ProtectedRoot
    $roots=@(Get-KhcLifecycleStateRoots)
    if([IO.Path]::GetDirectoryName($mandatory) -cnotin $roots){throw 'Mandatory recycle-v6 StateRoot is missing.'}
    $payload=0L;$metadata=0L
    foreach($state in $roots){
        $root=Join-Path $state 'recycle-v6'
        if(-not (Test-Path -LiteralPath $root)){
            $runs=Join-Path $state 'runs'
            if(-not [IO.Directory]::Exists($runs)){continue}
            foreach($r in @(Get-ChildItem -LiteralPath $runs -Directory -ErrorAction Stop)){
                if(Test-Path -LiteralPath (Join-Path $r.FullName 'recycle-v6.json')){throw 'Recycle-v6 marker has no private anchor root.'}
                $requestPath=Join-Path $r.FullName 'cleanup-request.json'
                if(Test-Path -LiteralPath $requestPath){$req=Get-Content -LiteralPath (Assert-KhcPlainPath $requestPath) -Raw | ConvertFrom-Json -AsHashtable;if($req.schema -ne 1){throw 'Nonlegacy request has no protected anchor root.'}}
            }
            continue
        }
        $null=Assert-KhcRecycleV6PrivatePath $root -ProtectedRoot
        foreach($file in Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop){
            $null=Assert-KhcRecycleV6PrivatePath $file.FullName
            if($file.Name -ceq 'mac-cdf-candidate-e2e.claim.json'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected candidate E2E claim location.'}
                $claim=Read-KhcRecycleV6PrivateJson $file.FullName
                Assert-KhcMacCandidateE2eClaimData $claim $claim.run_id $claim.record_sha256 $claim.protocol_sha256
                $reserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$($claim.run_id).reserve.json")
                $null=Get-KhcMacCandidateE2eRegistration $state $claim.run_id $reserve
                continue
            }
            if($file.Name -cmatch '^mac-cdf-candidate-e2e-([0-9a-f]{32})(-registration)?\.json$'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected candidate E2E private record location.'}
                $candidateId=$Matches[1];$reserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$candidateId.reserve.json")
                $null=Get-KhcMacCandidateE2eRegistration $state $candidateId $reserve
                continue
            }
            if($file.Name -cmatch '^mac-reference-([0-9a-f]{32})-continuous-proof\.zip$'){
                $referenceRunId=$Matches[1]
                if($file.PSIsContainer -or $root -ine $mandatory -or $file.Length -gt 1MB){throw 'Unexpected continuous private proof location/bound.'}
                $referenceReserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$referenceRunId.reserve.json")
                $registration=Get-KhcMacReferenceRegistration $state $referenceRunId $referenceReserve
                if($null -eq $registration -or $registration.Protocol.protocol -cne 'khc-mac-canterbury-continuous-reference-v1'){throw 'Continuous proof has no matching private registration.'}
                $null=Invoke-KhcMacContinuousProofVerifier -ArchivePath $file.FullName -ProtocolSha256 $registration.Record.protocol_sha256 -RunId $referenceRunId
                continue
            }
            if($file.Name -cmatch '^mac-reference-([0-9a-f]{32})(-registration)?\.json$'){
                $referenceRunId=$Matches[1]
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected reference private record location.'}
                $referenceReserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$referenceRunId.reserve.json")
                $null=Get-KhcMacReferenceRegistration $state $referenceRunId $referenceReserve
                continue
            }
            if($file.Name -cmatch '^mac-native-e2e-([0-9a-f]{32})(-registration)?\.json$'){
                $nativeRunId=$Matches[1]
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected native remote record location.'}
                $nativeReserve=Read-KhcRecycleV6PrivateJson (Join-Path $root "$nativeRunId.reserve.json")
                $null=Get-KhcMacNativeE2eRegistration $state $nativeRunId $nativeReserve
                continue
            }
            if($file.Name -cin @('mac-cdf-candidate.started.json','mac-cdf-candidate.terminal.json')){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected candidate ledger location.'}
                $null=Get-KhcMacCdfCandidateLedger
                continue
            }
            if($file.Name -ceq 'mac-verifier-unresolved.json'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected unresolved verifier marker location.'}
                # 課金走査は記録を保持して数える。実行入口は存在だけでfail closedする。
                $unresolved=Read-KhcRecycleV6PrivateJson $file.FullName
                Assert-KhcMacDecodeDiagnosticFields $unresolved @('schema','protocol','pid','reason','recorded_utc')
                if(-not (Test-KhcMacNativeE2eJsonEqual $unresolved.schema 1) -or $unresolved.protocol -isnot [string] -or $unresolved.protocol -cne 'khc-verifier-unresolved-v1'){throw 'Unresolved verifier marker schema mismatch.'}
                continue
            }
            if($file.Name -cin @('mac-decode-retry.amendment.json','mac-decode-retry.started.json','mac-decode-retry.terminal.json')){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected retry ledger location.'}
                $null=Get-KhcMacDecodeRetryLedger
                continue
            }
            if($file.Name -cin @('mac-decode-diagnostic.started.json','mac-decode-diagnostic.terminal.json')){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected decode diagnostic ledger location.'}
                # 容量走査は開始記録も課金する。実行許可のpending検査とは分ける。
                $null=Get-KhcMacDecodeDiagnosticLedger
                continue
            }
            if($file.Name -ceq 'mac-native-build-amendment.json'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected build amendment location.'}
                $null=Get-KhcMacBuildAmendment
                $null=@(Get-KhcMacBuildLedger)
                continue
            }
            if($file.Name -cmatch '^mac-native-build-(prepare-source|fetch|check|build)-intent\.json$'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected Mac stage intent location.'}
                $null=@(Get-KhcMacBuildLedger)
                continue
            }
            if($file.Name -ceq 'mac-native-build-activation.json'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected Mac build activation location.'}
                $null=@(Get-KhcMacBuildLedger)
                continue
            }
            if($file.Name -ceq 'mac-native-build'){
                if(-not $file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected Mac build ledger location.'}
                $null=@(Get-KhcMacBuildLedger)
                continue
            }
            if($file.Name -ceq 'mac-native-reservation.json'){
                if($file.PSIsContainer -or $root -ine $mandatory){throw 'Unexpected Mac reservation location.'}
                $null=Get-KhcMacRemoteReservation
                continue
            }
            if($file.PSIsContainer -or $file.Name -cnotmatch '^(probe|[0-9a-f]{32}\.(reserve|request|final))\.json$'){throw 'Unknown private recycle-v6 record.'}
            if($file.Name -ceq 'probe.json'){
                if($root -ine $mandatory){throw 'Unexpected probe anchor location.'}
                $probe=Read-KhcRecycleV6PrivateJson $file.FullName
                if($probe.schema -ne 1 -or $probe.protocol -cne 'prunlet-recycle-v6-probe' -or $probe.operation_id -cne '59325e63acad49cdb791e61fd03ebaf1' -or $probe.payload_bytes -ne 0 -or $probe.metadata_bytes -lt 1MB -or $probe.contract_sha256 -cne '78c8b3aa78e3baf6ea482bb6edc6119cd2aaf10dd2cbe783c4e37ac3296f3519' -or (Get-KhcRecycleV6Hash $probe.contract_path) -cne $probe.contract_sha256){throw 'Probe charge anchor is invalid.'}
                $own=Assert-KhcRecycleV6PrivatePath ('C:\Users\IMT\.local\Prunlet\recovery\'+$probe.operation_id)
                $metadata+=[Math]::Max([long]$probe.metadata_bytes,[long](Get-KhcTreeUsage $own))
                continue
            }
            $id=$file.Name.Substring(0,32)
            $reserve=Get-KhcRecycleV6RunAnchor $state $id
            if($file.Name -clike '*.request.json'){$null=Get-KhcRecycleV6RunAnchor $state $id -Request;continue}
            if($file.Name -cnotlike '*.reserve.json'){continue}
            $finalPath=Join-Path $root "$id.final.json"
            $payloadCharge=[long]$reserve.payload_bytes;$metadataCharge=[long]$reserve.metadata_bytes
            $requestPath=Join-Path (Join-Path (Join-Path $state 'runs') $id) 'cleanup-request.json'
            $binding=$null
            if(Test-Path -LiteralPath $requestPath){$binding=Get-KhcRecycleV6RunAnchor $state $id -Request}
            if(Test-Path -LiteralPath $finalPath){
                $final=Read-KhcRecycleV6PrivateJson $finalPath
                foreach($field in @('schema','payload_bytes','metadata_bytes')){if($final[$field] -isnot [int] -and $final[$field] -isnot [long]){throw 'Recycle-v6 final charge requires integer bounds.'}}
                if($final.schema -ne 1 -or $final.run_id -cne $id -or $final.reservation_sha256 -cne (Get-KhcRecycleV6Hash $file.FullName) -or $final.payload_bytes -lt 0 -or $final.payload_bytes -gt $reserve.payload_bytes -or $final.metadata_bytes -lt $reserve.metadata_bytes -or $final.proof_sha256 -cne (Get-KhcRecycleV6Hash $final.proof_path)){throw 'Recycle-v6 final charge/proof anchor is invalid.'}
                if($null -eq $binding){throw 'Recycle-v6 final anchor has no bound request.'}
                foreach($field in @('request_sha256','archive_sha256','exe_sha256','config_sha256')){if($final[$field] -cne $binding[$field]){throw 'Recycle-v6 final request binding mismatch.'}}
                $proof=Get-Content -LiteralPath (Assert-KhcPlainPath $final.proof_path) -Raw | ConvertFrom-Json -AsHashtable
                if($proof.schema -ne 1 -or $proof.protocol -cne 'prunlet-recycle-v6' -or $proof.run_id -cne $id -or $proof.operation_id -cne $final.operation_id -or $proof.payload_bytes -ne $final.payload_bytes -or $proof.metadata_bytes -ne $final.metadata_bytes){throw 'Recycle-v6 final proof charges/operation mismatch.'}
                $payloadCharge=[long]$final.payload_bytes;$metadataCharge=[long]$final.metadata_bytes
            }
            if($null -ne $binding){
                $req=Get-Content -LiteralPath $binding.request_path -Raw | ConvertFrom-Json -AsHashtable
                if($req.schema -ne 2 -or $req.protocol -cne 'prunlet-recycle-v6'){throw 'Protected recycle-v6 request was downgraded.'}
                if(Test-Path -LiteralPath $req.delete_result_path){
                    $receipt=Get-Content -LiteralPath (Assert-KhcPlainPath $req.delete_result_path) -Raw | ConvertFrom-Json -AsHashtable
                    $null=Assert-KhcRecycleV6ReceiptData $receipt $req.work_directory 'delete-result'
                    $own=Assert-KhcRecycleV6PrivatePath (Join-Path $binding.metadata_root $receipt.operationId)
                    $metadataCharge=[Math]::Max($metadataCharge,[long](Get-KhcTreeUsage $own))
                }
            }
            $payload+=$payloadCharge;$metadata+=$metadataCharge
        }
        foreach($run in @(Get-ChildItem -LiteralPath (Join-Path $state 'runs') -Directory -ErrorAction Stop)){
            $null=Get-KhcRecycleV6RunProtocol $state $run.Name
            $marker=Join-Path $run.FullName 'recycle-v6.json'
            if(Test-Path -LiteralPath $marker){$null=Get-KhcRecycleV6RunAnchor $state $run.Name}
            $requestPath=Join-Path $run.FullName 'cleanup-request.json'
            if(Test-Path -LiteralPath $requestPath){$req=Get-Content -LiteralPath (Assert-KhcPlainPath $requestPath) -Raw | ConvertFrom-Json -AsHashtable;if($req.schema -notin @(1,2)){throw 'Unknown cleanup request schema.'};if($req.schema -eq 2 -and -not (Test-Path -LiteralPath $marker)){throw 'Schema2 request lost its protected registration marker.'};if($req.schema -eq 1 -and (Test-Path -LiteralPath $marker)){throw 'Recycle-v6 marker cannot use a legacy request.'}}
        }
    }
    if(-not (Test-Path -LiteralPath (Join-Path $mandatory 'probe.json'))){throw 'Probe reservation anchor is missing.'}
    [pscustomobject]@{payload_bytes=$payload;metadata_bytes=$metadata;total_bytes=$payload+$metadata}
    } finally {
        if($ownsMemo){
            foreach($lease in $khcChargeScanMemo.Leases){for($i=$lease.Count-1;$i -ge 0;$i--){$lease[$i].Dispose()}}
            $khcChargeScanMemo.Results.Clear()
        }
    }
}

function Assert-KhcStorageBudget {
    param([ValidateRange(0, 4294967296)][long]$ReserveBytes = 0,[ValidateRange(0, 4294967296)][long]$CargoReserveBytes = 0)
    $null = Assert-KhcDStorageBase
    $build = Get-KhcTreeUsage (Join-Path $script:ProjectRoot 'build')
    $legacyTemp = Get-KhcTreeUsage $script:LegacyTempRoot
    $workspace = Get-KhcTreeUsage $script:WorkspaceBase
    $legacyKeep = Get-KhcTreeUsage $script:LegacyKeepRoot
    $taskArtifacts = Get-KhcTreeUsage $script:TaskArtifactsBase
    $oldCargo = Get-KhcTreeUsage (Join-Path $script:ProjectRoot 'build/cargo')
    $taskCargo = Get-KhcTaskCargoBytes
    $cargo = $oldCargo + $taskCargo
    $actualLocalCargo=$cargo
    $remote=Get-KhcMacRemoteReservation
    $remoteOrdinary=0L;$remoteCargo=0L;$remoteTotal=0L
    if($null -ne $remote){$remoteOrdinary=[long]$remote.ordinary_bytes;$remoteCargo=[long]$remote.cargo_bytes;$remoteTotal=[long]$remote.total_bytes}
    $cargo+=$remoteCargo
    $temp = $legacyTemp + $workspace
    $keep = $legacyKeep + $taskArtifacts
    $state = Get-KhcLifecycleUsage
    $archive = Get-KhcRetirementRetentionBytes
    $recycle=Get-KhcRecycleV6Charges
    $actualTotal=$build+$temp+$keep
    $total = $actualTotal + $recycle.total_bytes + $remoteTotal
    $actualState=$state;$state+=$recycle.total_bytes
    if ($total + $ReserveBytes + $CargoReserveBytes -gt 30GB) { throw "build・旧Temp・Dタスク作業先・保全の合算容量超過: $total + $ReserveBytes + $CargoReserveBytes > 30GiB。既存量を除外しません。" }
    if ($archive -gt $keep) { throw '固定保管ZIPの実測容量が保全の合算容量を超えています。' }
    $external = $temp + $keep + $recycle.total_bytes + $remoteTotal
    $externalRegular = $external - $taskCargo - $archive - $remoteCargo
    if ($externalRegular -lt 0) { throw '外部作業先/Cargo/固定保管の容量分類が一致しません。' }
    if ($externalRegular + $ReserveBytes -gt 2GB) { throw '旧C・全taskの通常外部作業と保全の合算2GiB枠を超えています（Cargoと登録済み固定保管ZIPは内数除外）。' }
    if ($cargo + $CargoReserveBytes -gt 6GB) { throw '旧build/cargoと全taskのCargoの固定6GiB枠を超えています。' }
    if ($state -gt $script:LifecycleCapBytes) { throw '復元バックアップと清掃台帳の固定1GiB枠を超えています。' }
    # 空き容量は作業・保全の基点（ユーザー既定TEMP\UnLhaRe）があるドライブで測る。旧D:固定は廃止。
    $free = ([IO.DriveInfo]::new([IO.Path]::GetPathRoot((Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe')))).AvailableFreeSpace
    if ($free -lt 5GB + $ReserveBytes + $CargoReserveBytes) { throw '作業基点ドライブの空き容量5GiBと今回の作業・Cargo予約を確保できません。' }
    [pscustomobject]@{
        build_bytes=$build; legacy_temp_bytes=$legacyTemp; workspace_bytes=$workspace; temp_bytes=$temp
        legacy_keep_bytes=$legacyKeep; task_artifact_bytes=$taskArtifacts; keep_bytes=$keep
        cargo_bytes=$cargo; task_cargo_bytes=$taskCargo; lifecycle_bytes=$state; total_bytes=$total; total_cap_bytes=30GB
        external_bytes=$external; external_cargo_bytes=$taskCargo+$remoteCargo; external_cap_bytes=2GB; external_regular_bytes=$externalRegular
        fixed_archive_bytes=$archive; fixed_archive_cap_bytes=$archive; cargo_cap_bytes=6GB; lifecycle_cap_bytes=$script:LifecycleCapBytes
        free_bytes=$free; reserved_bytes=$ReserveBytes; cargo_reserved_bytes=$CargoReserveBytes
        actual_tree_total_bytes=$actualTotal; actual_lifecycle_tree_bytes=$actualState
        actual_local_cargo_bytes=$actualLocalCargo; remote_ordinary_reserved_bytes=$remoteOrdinary; remote_cargo_reserved_bytes=$remoteCargo; remote_total_reserved_bytes=$remoteTotal
        recycle_retained_payload_charge_bytes=$recycle.payload_bytes; recycle_external_metadata_charge_bytes=$recycle.metadata_bytes
    }
}

function Write-KhcNewJson {
    param([string]$Path, [object]$Value)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Value -Depth 12))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}

function New-KhcStorageRun {
    param([Parameter(Mandatory)][string]$WorkDirectory, [ValidateRange(1,128)][int]$MaxRunMiB=32, [ValidateRange(0,4096)][int]$MaxEntries=0, [switch]$PortfolioProductScreen,[switch]$RemoteNativeE2e,[switch]$RemoteReference,[switch]$RemoteCandidateE2e,[string]$RemoteProtocolSha256='',[string]$RemoteInvocationSha256='',[string]$RemoteReferenceProtocol='khc-mac-canterbury-reference-v1')
    $khcCandidateRegistrationMemo=$null
    $registrationOperationFailure=$null
    if($RemoteCandidateE2e){$khcCandidateRegistrationMemo=@{Results=@{};Leases=[Collections.Generic.List[object]]::new()}}
    try {
    $null=Assert-KhcRemoteReferenceClassData $RemoteNativeE2e.IsPresent $RemoteReference.IsPresent $RemoteCandidateE2e.IsPresent
    if($RemoteCandidateE2e){
        if($script:TaskId -cne 'goal-restore-20261019' -or $MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $RemoteInvocationSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Candidate E2E requires the exact task/resources/invocation binding.'}
        $candidateE2eKind=Get-KhcMacCandidateE2eKind
        $candidateE2eProtocol=Read-KhcMacCandidateE2eProtocol $candidateE2eKind.ProtocolPath $RemoteProtocolSha256
        Assert-KhcMacCandidateE2eBuildEvidence
        if(Test-Path -LiteralPath (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate-e2e.claim.json')){throw 'Candidate example E2E purpose is one-shot, including failed or partial attempts.'}
    }elseif($RemoteNativeE2e){
        if($script:TaskId -cne 'goal-restore-20261019' -or $MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $RemoteInvocationSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Remote native registration requires the exact task/resources/invocation binding.'}
        $nativeProtocol=Read-KhcMacNativeE2eProtocol (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-e2e-ps-free-protocol.json') $RemoteProtocolSha256
        $nativeOracleBytes=Read-KhcBoundedSnapshotBytes (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-e2e-oracle.json')
        $null=ConvertFrom-KhcBoundedJsonSnapshot $nativeOracleBytes $nativeProtocol.Data.oracle_sha256
    }elseif($RemoteReference){
        if($script:TaskId -cne 'goal-restore-20261019' -or $MaxRunMiB -ne 8 -or $MaxEntries -ne 96 -or $RemoteInvocationSha256 -cnotmatch '\A[0-9a-f]{64}\z'){throw 'Reference registration requires the exact task/resources/invocation binding.'}
        $referenceKind=Get-KhcMacReferenceKind $RemoteReferenceProtocol
        $referenceProtocol=Read-KhcMacReferenceProtocol $referenceKind.ProtocolPath $RemoteProtocolSha256
        if($referenceProtocol.Data.protocol -cne $RemoteReferenceProtocol){throw 'Reference registration protocol type mismatch.'}
        $referenceManifestBytes=Read-KhcBoundedSnapshotBytes (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-input-manifest.json')
        $referenceManifest=ConvertFrom-KhcBoundedJsonSnapshot $referenceManifestBytes $referenceProtocol.Data.input_manifest_sha256
        Assert-KhcMacReferenceManifestData $referenceManifest
    }elseif($RemoteProtocolSha256 -or $RemoteInvocationSha256){throw 'Remote typed bindings cannot be added to an ordinary run.'}
    if($MaxRunMiB -gt 32 -and -not $PortfolioProductScreen){throw '32 MiBを超えるrun枠は固定e-Gov XML/CSV PortfolioTrial screenに限ります。'}
    if($PortfolioProductScreen -and ($MaxRunMiB -ne 128 -or $MaxEntries -ne 512)){throw 'PortfolioTrial product screen requires exactly 128 MiB / 512 entries.'}
    $paths = Get-KhcStorageTaskPaths
    $work = Assert-KhcStorageTaskWorkDirectory $WorkDirectory
    $state = Assert-KhcPlainPath $paths.StateRoot
    if((Join-Path $state 'recycle-v6') -ine (Get-KhcRecycleV6AnchorRoot)){throw 'New recycle-v6 registration is restricted to the explicitly bootstrapped current task.'}
    $null=Assert-KhcRecycleV6PrivatePath (Get-KhcRecycleV6AnchorRoot) -ProtectedRoot
    $null=Assert-KhcRecycleV6Installed
    $forbidden = @($script:ProjectRoot, (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'))
    if ($env:CODEX_HOME) { $forbidden += [IO.Path]::GetFullPath($env:CODEX_HOME) }
    foreach ($root in $forbidden) { if ($work.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $state.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'リポジトリ/Codexユーザーディレクトリは保存先にできません。' } }
    if (Test-Path -LiteralPath $work) { throw '既存の作業先は再利用・削除しません。' }
    $paths = Initialize-KhcStorageTaskEnvironment
    $state = Assert-KhcPlainPath $paths.StateRoot
    $null = Assert-KhcStorageBudget -ReserveBytes (2L*$MaxRunMiB*1MB+2MB)
    $null = New-Item -ItemType Directory -Path $state -Force
    $registrationLease = $null; $cargoProbe = $null; $lock = $null
    try {
        $registrationLease = [Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $null = Assert-KhcStorageBudget -ReserveBytes (2L*$MaxRunMiB*1MB+2MB)
        Assert-KhcNoPendingStorageRuns
        Assert-KhcNoPendingMacBuild
        if($RemoteCandidateE2e -and (Test-Path -LiteralPath (Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate-e2e.claim.json'))){throw 'Candidate E2E purpose was consumed before registration lock admission.'}
        $lock = [IO.File]::Open((Join-Path $state 'serial.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $records = Join-Path $state 'runs'
        if (Test-Path -LiteralPath $records) {
            foreach ($record in Get-ChildItem -LiteralPath $records -Directory -Force) {
                $null=Get-KhcRecycleV6RunProtocol $state $record.Name
                if (-not (Test-Path -LiteralPath (Join-Path $record.FullName 'complete.json') -PathType Leaf)) { throw "未完了の清掃があるため次の実験を停止します: $($record.FullName)" }
            }
        }
        # 永続payload+metadata課金と物理ZIP+proof/記録を同時に収める。
        # P=run上限、M=1MiB+entries*64KiB: 新規LC露出は(P+M)+P+(M+1MiB)。
        $metadataRoom = $script:LifecycleCapBytes - (Get-KhcLifecycleUsage) - (Get-KhcRecycleV6Charges).total_bytes - 2L*$MaxRunMiB*1MB - 3MB
        $availableEntries = [int][math]::Max(0,[math]::Min(4096,[math]::Floor($metadataRoom / 131072.0)))
        if ($MaxEntries -gt 0 -and $MaxEntries -lt 64) { throw '明示するentry上限は64～4096件です。' }
        if ($MaxEntries -gt 0 -and $MaxEntries -gt $availableEntries) { throw "明示するentry上限 $MaxEntries 件は、現行1GiB固定枠で予約可能な $availableEntries 件を超えます。MaxRunMiBを下げるか、固定枠に収まる上限を指定してください。証拠は自動削除しません。" }
        $maxEntries = if ($MaxEntries -gt 0) { $MaxEntries } else { $availableEntries }
        if ($maxEntries -lt 64) { throw '復元バックアップ/台帳1GiB枠に最低64 entry分を予約できません。MaxRunMiBを下げるか、不要と明示された証拠だけを整理してください。古い証拠は自動削除しません。' }
        # 受付と清掃で同じmetadata上限を用い、許可したentriesを清掃枠に収める。
        $newReservation=Get-KhcRecycleV6Reservation ($MaxRunMiB*1MB) $maxEntries
        $physicalMetadataMargin=[long]$newReservation.metadata_bytes+1MB
        $newPersistentBytes=[long]$newReservation.payload_bytes+[long]$newReservation.metadata_bytes
        Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes $newPersistentBytes ($MaxRunMiB*1MB) $physicalMetadataMargin
        $null = Assert-KhcStorageBudget -ReserveBytes ($newPersistentBytes+2L*$MaxRunMiB*1MB+$physicalMetadataMargin)
        # Cargo単独の実行と登録の競合も全task横断で禁止する。
        $cargoProbe = [Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        $id = [Guid]::NewGuid().ToString('N'); $directory = Join-Path $records $id
        $record=[ordered]@{run_id=$id;work_directory=$work;max_bytes=$MaxRunMiB*1MB;max_entries=$maxEntries;owner_pid=$PID;owner_start_ticks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;owner_start_utc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o');created_utc=[DateTime]::UtcNow.ToString('o')}
        $recordBytes=[Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $record -Depth 12))
        $recordHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($recordBytes)).ToLowerInvariant()
        $reservation=Get-KhcRecycleV6Reservation $record.max_bytes $record.max_entries
        Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes $newPersistentBytes $reservation.payload_bytes $physicalMetadataMargin
        $anchorPath=Join-Path (Get-KhcRecycleV6AnchorRoot) "$id.reserve.json"
        $reserveRecord=[ordered]@{schema=1;protocol='prunlet-recycle-v6';run_id=$id;registration_sha256=$recordHash;max_bytes=$record.max_bytes;max_entries=$record.max_entries;payload_bytes=$reservation.payload_bytes;metadata_bytes=$reservation.metadata_bytes}
        if($RemoteNativeE2e){$reserveRecord.remote_native_e2e_required=$true;$reserveRecord.remote_native_e2e_protocol_sha256=$RemoteProtocolSha256}
        if($RemoteReference){$reserveRecord.remote_reference_required=$true;$reserveRecord.remote_reference_protocol_sha256=$RemoteProtocolSha256}
        if($RemoteCandidateE2e){$reserveRecord.remote_candidate_e2e_required=$true;$reserveRecord.remote_candidate_e2e_protocol_sha256=$RemoteProtocolSha256}
        Write-KhcNewJson $anchorPath $reserveRecord
        $null = New-Item -ItemType Directory -Path $directory
        $recordPath = Join-Path $directory 'run.json'
        Write-KhcNewJson $recordPath $record
        Write-KhcNewJson (Join-Path $directory 'recycle-v6.json') ([ordered]@{schema=1;protocol='prunlet-recycle-v6';reservation_sha256=(Get-KhcRecycleV6Hash $anchorPath)})
        if($RemoteCandidateE2e){
            $claimPath=Join-Path (Get-KhcRecycleV6AnchorRoot) 'mac-cdf-candidate-e2e.claim.json'
            if(Test-Path -LiteralPath $claimPath){throw 'Candidate E2E purpose claim was already consumed.'}
            Write-KhcNewJson $claimPath ([ordered]@{schema=1;protocol='khc-mac-cdf-candidate-e2e-claim-v1';run_id=$id;record_sha256=$recordHash;protocol_sha256=$RemoteProtocolSha256;registered_utc=[DateTime]::UtcNow.ToString('o')})
            Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) "mac-cdf-candidate-e2e-$id-registration.json") ([ordered]@{schema=1;protocol='khc-mac-cdf-candidate-e2e-registration-v1';run_id=$id;record_sha256=$recordHash;worker_path=$candidateE2eKind.Worker;worker_sha256=$candidateE2eProtocol.Trust.WorkerSha256;invocation_sha256=$RemoteInvocationSha256;protocol_sha256=$RemoteProtocolSha256;protocol_base64=[Convert]::ToBase64String($candidateE2eProtocol.Bytes)})
        }
        if($RemoteNativeE2e){
            $nativeWorker='D:\Dev\UnLhaRe\UnLhaRe\experiments\khc\mac-spatial-mdl-e2e.ps1'
            Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) "mac-native-e2e-$id-registration.json") ([ordered]@{schema=1;protocol='khc-mac-native-e2e-registration-v1';run_id=$id;record_sha256=$recordHash;worker_path=$nativeWorker;worker_sha256=(Get-KhcRecycleV6Hash $nativeWorker);invocation_sha256=$RemoteInvocationSha256;protocol_sha256=$RemoteProtocolSha256;protocol_utf8=$nativeProtocol.Raw;oracle_utf8=[Text.UTF8Encoding]::new($false,$true).GetString($nativeOracleBytes)})
        }
        if($RemoteReference){
            $referenceWorker=$referenceKind.Worker
            Write-KhcNewJson (Join-Path (Get-KhcRecycleV6AnchorRoot) "mac-reference-$id-registration.json") ([ordered]@{schema=1;protocol='khc-mac-reference-registration-v1';run_id=$id;record_sha256=$recordHash;worker_path=$referenceWorker;worker_sha256=(Get-KhcRecycleV6Hash $referenceWorker);invocation_sha256=$RemoteInvocationSha256;protocol_sha256=$RemoteProtocolSha256;protocol_utf8=$referenceProtocol.Raw;manifest_utf8=[Text.UTF8Encoding]::new($false,$true).GetString($referenceManifestBytes)})
        }
        $null=Get-KhcRecycleV6RunAnchor $state $id
        Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 $reservation.payload_bytes $physicalMetadataMargin
        $null=Assert-KhcStorageBudget -ReserveBytes (2L*$MaxRunMiB*1MB+$physicalMetadataMargin)
        $result = [pscustomobject]@{RunId=$id;WorkDirectory=$work;RecordPath=$recordPath;RecordDirectory=$directory;StateRoot=$state;TempRoot=$paths.TempRoot;Lock=$lock;MaxBytes=$MaxRunMiB*1MB;MaxEntries=$maxEntries}
        $lock = $null
        return $result
    } catch { if ($null -ne $lock) { $lock.Dispose() }; throw }
    finally {
        if ($null -ne $cargoProbe) { $cargoProbe.Dispose() }
        if ($null -ne $registrationLease) { $registrationLease.Dispose() }
    }
    } catch {
        $registrationOperationFailure=$_
        throw
    } finally {
        if($null -ne $khcCandidateRegistrationMemo){
            $cleanupErrors=[Collections.Generic.List[Exception]]::new()
            try{
                foreach($lease in $khcCandidateRegistrationMemo.Leases){
                    for($i=$lease.Count-1;$i -ge 0;$i--){
                        try{$lease[$i].Dispose()}catch{$cleanupErrors.Add($_.Exception)}
                    }
                }
            }
            finally{$khcCandidateRegistrationMemo.Results.Clear();$khcCandidateRegistrationMemo.Leases.Clear()}
            if($cleanupErrors.Count){
                if($null -ne $registrationOperationFailure){$cleanupErrors.Insert(0,$registrationOperationFailure.Exception)}
                throw [AggregateException]::new('Candidate registration operation/lease cleanup failure.',[Exception[]]$cleanupErrors)
            }
        }
    }
}

function Assert-KhcStorageContext {
    param([Parameter(Mandatory)][string]$WorkDirectory)
    if (-not $env:KHC_STORAGE_RUN_RECORD) { throw 'run-storage-experiment.ps1を経由してください。直接実行は清掃保証がないため停止します。' }
    $paths = Get-KhcStorageTaskPaths
    $path = Assert-KhcPlainPath $env:KHC_STORAGE_RUN_RECORD
    if (-not $path.StartsWith($paths.StateRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '登録台帳の保存先が一致しません。' }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $work = Assert-KhcStorageTaskWorkDirectory $WorkDirectory
    if ($work -cne $record.work_directory -or (Test-Path -LiteralPath (Join-Path (Split-Path $path) 'complete.json'))) { throw '作業先と未完了の登録台帳が一致しません。' }
    $owner = Get-Process -Id $record.owner_pid -ErrorAction Stop
    # JSONのISO文字列がDateTimeへ自動変換されるPowerShellでもPID再利用を誤判定しない。
    if ($owner.StartTime.ToUniversalTime().Ticks -ne $record.owner_start_ticks) { throw '登録した実行主体が終了しています。' }
    if ((Get-KhcRunUsage $work -MaxEntries $record.max_entries) -gt $record.max_bytes) { throw '登録した今回の容量枠を超えています。' }
}

function Enter-KhcCargoLease {
    # Global mutex blocks cross-task Cargo and task registration probes.
    $paths = Initialize-KhcStorageTaskEnvironment
    $state = Assert-KhcPlainPath $paths.StateRoot
    $null = New-Item -ItemType Directory -Path $state -Force
    $lock = [Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
    try {
        Assert-KhcNoPendingMacBuild
        $null = Assert-KhcStorageBudget
        Assert-KhcNoPendingStorageRuns -AllowedRecordPath $env:KHC_STORAGE_RUN_RECORD
        return $lock
    } catch { $lock.Dispose(); throw }
}

function Get-KhcWorkInventory {
    param([Parameter(Mandatory)][string]$WorkDirectory,[Parameter(Mandatory)][int]$MaxEntries)
    $work = Assert-KhcPlainPath $WorkDirectory
    $metadata = [Khc.Storage.TreeCounter]::Measure($work,$MaxEntries,512)
    $entries = [Collections.Generic.List[object]]::new()
    $files = [Collections.Generic.List[object]]::new()
    $entries.Add([ordered]@{path='.';kind='directory'})
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($work)
    while ($pending.Count) {
        foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
            $relative = [IO.Path]::GetRelativePath($work,$child.FullName)
            if ($child.PSIsContainer) {
                $entries.Add([ordered]@{path=$relative;kind='directory'})
                $pending.Push($child.FullName)
            } else {
                $file = [ordered]@{path=$relative;bytes=[long]$child.Length;sha256=(Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
                $files.Add($file)
                $entries.Add([ordered]@{path=$relative;kind='file';bytes=[long]$child.Length})
            }
        }
    }
    [pscustomobject]@{Metadata=$metadata;Entries=@($entries.ToArray());Files=@($files.ToArray())}
}

function Get-KhcStorageRunLocation {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId)
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($state in Get-KhcLifecycleStateRoots) {
        $directory = Assert-KhcPlainPath (Join-Path (Join-Path $state 'runs') $RunId)
        $recordPath = Join-Path $directory 'run.json'
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) { $matches.Add([pscustomobject]@{StateRoot=$state;Directory=$directory;RecordPath=$recordPath}) }
    }
    if ($matches.Count -eq 0) { throw '指定されたrun IDの台帳がありません。' }
    if ($matches.Count -ne 1) { throw 'run IDが複数の旧/新StateRootに存在し、保存先を一意に決定できません。' }
    $found = $matches[0]
    $state = Assert-KhcPlainPath $found.StateRoot
    $taskRoot = $null
    $tempRoot = $null
    if ($state -ieq (Assert-KhcPlainPath $script:HistoricalDStateRoot) -or $state -ieq (Assert-KhcPlainPath $script:LegacyStateRoot)) {
        $tempRoot = Assert-KhcPlainPath $script:LegacyTempRoot
    } else {
        $relative = [IO.Path]::GetRelativePath($script:TaskArtifactsBase,$state)
        if ($relative -match '^([^\\]+)\\storage-lifecycle$' -and $Matches[1] -cnotmatch '^(?i:storage-lifecycle)$') {
            $taskId = $Matches[1]
            if ($taskId -cnotmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw '保全台帳のtask rootが安全なslugではありません。' }
            $taskRoot = Assert-KhcPlainPath (Join-Path $script:WorkspaceBase $taskId)
            $tempRoot = Assert-KhcPlainPath (Join-Path $taskRoot 'temp')
        } else {
            throw "run台帳のStateRootが既知の旧rootまたはD: task rootではありません: $state"
        }
    }
    [pscustomobject]@{StateRoot=$state;Directory=$found.Directory;RecordPath=$found.RecordPath;TaskRoot=$taskRoot;TempRoot=$tempRoot}
}

function Get-KhcStorageRun {
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'run IDは小文字32桁のGUIDに限定します。' }
    $location = Get-KhcStorageRunLocation $RunId
    if (-not $location.TaskRoot) { throw '旧C:または共有 StateRootは読取専用の履歴です。新規task run以外の清掃・更新は行いません。' }
    $directory = $location.Directory
    $recordPath = $location.RecordPath
    $runProtocol=Get-KhcRecycleV6RunProtocol $location.StateRoot $RunId
    $requestPath = Join-Path $directory 'cleanup-request.json'
    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf)) { throw 'pending清掃要求がありません。未開始runはRecoverUnstartedから処理してください。' }
    if (Test-Path -LiteralPath (Join-Path $directory 'complete.json') -PathType Leaf) { throw 'このrunはすでに完了しています。' }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($record.run_id -cne $RunId -or $request.schema -notin @(1,2) -or $request.run_id -cne $RunId -or $record.work_directory -cne $request.work_directory) { throw 'run記録と清掃要求が一致しません。' }
    if($runProtocol -eq 6 -and ($request.schema -ne 2 -or $request.protocol -cne 'prunlet-recycle-v6')){throw 'Private recycle-v6 registration cannot downgrade its public request.'}
    $work = Assert-KhcPlainPath ([string]$record.work_directory)
    if ([IO.Path]::GetDirectoryName($work) -ine $location.TaskRoot -and [IO.Path]::GetDirectoryName($work) -ine $location.TempRoot) { throw 'run作業先が登録されたD: task rootまたは歴史Tempの直接子ではありません。' }
    if ($work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or $work.Length -gt 200) { throw 'run作業先がrun-GUIDの正規形式ではありません。' }
    $expectedDirectory = [IO.Path]::GetFullPath($directory)
    $pathProperties = @('paths_file','delete_preview_path','delete_result_path','purge_preview_path','purge_result_path','recovery_manifest_path')
    if ($request.requires_prunlet) { $pathProperties += 'recovery_archive_path' }
    foreach ($property in $pathProperties) {
        $path = Assert-KhcPlainPath ([string]$request.$property)
        if (-not $path.StartsWith($expectedDirectory + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw "清掃記録の保存先がrun台帳外です: $property" }
    }
    [pscustomobject]@{RunId=$RunId;Directory=$directory;StateRoot=$location.StateRoot;TaskRoot=$location.TaskRoot;TempRoot=$location.TempRoot;Record=$record;Request=$request;RequestPath=$requestPath;WorkDirectory=$work}
}

function Assert-KhcRecoveryArchive {
    param([Parameter(Mandatory)][object]$Run)
    $request = $Run.Request
    $manifestPath = [string]$request.recovery_manifest_path
    $archivePath = [string]$request.recovery_archive_path
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) { throw '検証済み復元manifest/ZIPが欠けています。' }
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $request.recovery_manifest_sha256) { throw '復元manifestのSHA-256が一致しません。' }
    if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $request.recovery_archive_sha256) { throw '復元ZIPのSHA-256が一致しません。' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($manifest.run_id -cne $Run.RunId -or $manifest.work_directory -cne $Run.WorkDirectory) { throw '復元manifestがrun/作業先と一致しません。' }
    if ($manifest.backup_sha256 -cne $request.recovery_archive_sha256) { throw '復元manifestと清掃要求のZIP SHA-256が一致しません。' }
    $files = @($manifest.files)
    $entries = @($manifest.entries)
    if ($files.Count -ne @($request.expected_files).Count -or $entries.Count -ne @($request.expected_entries).Count) { throw '復元manifestと清掃要求の項目数が一致しません。' }
    $expected = @{}
    foreach ($file in $files) {
        if ([string]::IsNullOrWhiteSpace([string]$file.path) -or $file.bytes -lt 0 -or [string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw '復元manifestのfile記録が不正です。' }
        $expected[[string]$file.path.Replace('\','/')] = $file
    }
    $fileBytes = [long]0
    foreach ($index in 0..([Math]::Max(0,$files.Count-1))) {
        if ($files.Count -eq 0) { break }
        $left = $files[$index]
        $right = $request.expected_files[$index]
        if ($left.path -cne $right.path -or $left.bytes -ne $right.bytes -or $left.sha256 -cne $right.sha256) { throw '復元manifestと清掃要求のfile proofが一致しません。' }
        $fileBytes += [long]$left.bytes
    }
    if ($fileBytes -ne [long]$request.expected_bytes) { throw '復元manifestのfile合計が登録bytesと一致しません。' }
    $zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $zipFiles = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
        if ($zipFiles.Count -ne $files.Count) { throw '復元ZIPの項目数がmanifestと一致しません。' }
        foreach ($entry in $zipFiles) {
            if (-not $expected.ContainsKey($entry.FullName)) { throw "復元ZIPに未登録fileがあります: $($entry.FullName)" }
        }
        foreach ($file in $files) {
            $name = ([string]$file.path).Replace('\','/')
            $entry = $zip.GetEntry($name)
            if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw "復元ZIPのサイズが一致しません: $name" }
            $stream = $entry.Open()
            try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() } finally { $stream.Dispose() }
            if ($hash -cne $file.sha256) { throw "復元ZIPのSHA-256が一致しません: $name" }
        }
    } finally { $zip.Dispose() }
    foreach ($index in 0..([Math]::Max(0,$entries.Count-1))) {
        if ($entries.Count -eq 0) { break }
        $left = $entries[$index]
        $right = $request.expected_entries[$index]
        if ($left.path -cne $right.path -or $left.kind -cne $right.kind -or ($left.kind -eq 'file' -and $left.bytes -ne $right.bytes)) { throw '復元manifestと清掃要求のtree inventoryが一致しません。' }
    }
    [pscustomobject]@{Manifest=$manifest;Files=$files;Entries=$entries}
}

function Get-KhcRecycleV6Reservation {
    param([ValidateRange(1048576,134217728)][long]$MaxBytes,[ValidateRange(1,4096)][int]$MaxEntries)
    [ordered]@{payload_bytes=$MaxBytes;metadata_bytes=1MB+65536L*$MaxEntries}
}

function Assert-KhcRecycleV6ReceiptData {
    param([Collections.IDictionary]$Receipt,[string]$WorkDirectory,[string]$Stage)
    if($Stage -notin @('delete-preview','delete-result')){throw 'Recycle-v6 never permits purge.'}
    foreach($key in @('operationId','dryRun','items','warnings')){if(-not $Receipt.Contains($key)){throw "Missing recycle receipt field: $key"}}
    $preview=$Stage -ceq 'delete-preview'
    if($Receipt.dryRun -isnot [bool] -or $Receipt.dryRun -ne $preview -or @($Receipt.warnings).Count -ne 0){throw 'Recycle receipt dryRun/warnings mismatch.'}
    if($preview){if($null -ne $Receipt.operationId){throw 'Preview cannot carry an operation ID.'}}
    elseif([string]$Receipt.operationId -cnotmatch '^[0-9a-f]{32}$'){throw 'Invalid recycle operation ID.'}
    $items=@($Receipt.items)
    if($items.Count -ne 1){throw 'Recycle-v6 requires exactly one root item.'}
    $item=$items[0]
    foreach($key in @('path','kind','status','error','backupPath','size','sha256')){if(-not $item.Contains($key)){throw "Missing recycle root field: $key"}}
    $status=if($preview){'would_delete'}else{'deleted'}
    if($item.path -cne $WorkDirectory -or $item.kind -cne 'directory' -or $item.status -cne $status -or $null -ne $item.error){throw 'Recycle root receipt does not match the registered directory.'}
    # schema 6のwire契約はrootのsize/SHAを返さない。旧schema 1には適用しない。
    if($null -ne $item.size -or $null -ne $item.sha256){throw 'Unexpected recycle-v6 root size/SHA wire format.'}
    if($preview){if($null -ne $item.backupPath){throw 'Preview cannot carry a Bin path.'}}
    elseif([string]::IsNullOrWhiteSpace([string]$item.backupPath)){throw 'Recycle result is missing its Bin path.'}
    return $Receipt
}

function Assert-KhcRecycleV6IdentityData {
    param([Collections.IDictionary]$Left,[Collections.IDictionary]$Right)
    foreach($id in @($Left,$Right)){
        if($null -eq $id -or [string]$id.fileId -cnotmatch '^[0-9A-F]{32}$' -or [decimal]$id.volumeSerialNumber -le 0 -or $id.isDirectory -isnot [bool] -or -not $id.isDirectory -or $id.reparseTag -ne 0){throw 'Invalid recycle directory identity.'}
    }
    foreach($key in @('volumeSerialNumber','fileId','isDirectory','reparseTag','attributes')){if($Left[$key] -cne $Right[$key]){throw "Recycle identity mismatch: $key"}}
}

function Assert-KhcRecycleV6MetadataData {
    param([Collections.IDictionary]$Manifest,[Collections.IDictionary]$Completion,[Collections.IDictionary]$Receipt,[string]$ManifestSha256,[string]$WorkDirectory,[string]$MetadataRoot,[string]$OwnerSid,[string]$MachineName)
    $null=Assert-KhcRecycleV6ReceiptData $Receipt $WorkDirectory 'delete-result'
    $id=$Receipt.operationId
    if($Manifest.schema -ne 6 -or $Completion.schema -ne 6 -or $Manifest.operationId -cne $id -or $Completion.operationId -cne $id){throw 'Recycle metadata schema/operation mismatch.'}
    if($Manifest.ownerSid -cne $OwnerSid -or $Manifest.machineName -cne $MachineName -or $Manifest.metadataRoot -cne $MetadataRoot){throw 'Recycle metadata owner/machine/root mismatch.'}
    if($ManifestSha256 -cnotmatch '^[0-9a-f]{64}$' -or $Completion.manifestSha256 -cne $ManifestSha256 -or $Completion.index -ne 0 -or $Completion.action -cne 'recycle' -or $Completion.phase -cne 'complete'){throw 'Recycle completion binding mismatch.'}
    if([string]::IsNullOrWhiteSpace([string]$Completion.pidl)){throw 'Recycle completion lacks PIDL.'}
    try{$pidl=[Convert]::FromBase64String($Completion.pidl)}catch{throw 'Invalid recycle PIDL encoding.'}
    if($pidl.Length -lt 4 -or $pidl[-1] -ne 0 -or $pidl[-2] -ne 0){throw 'Invalid recycle PIDL termination.'}
    $pidlOffset=0
    while($pidlOffset -lt $pidl.Length-2){
        $itemLength=[BitConverter]::ToUInt16($pidl,$pidlOffset)
        if($itemLength -lt 2 -or $pidlOffset+$itemLength -gt $pidl.Length-2){throw 'Invalid recycle PIDL item bounds.'}
        $pidlOffset+=$itemLength
    }
    if($pidlOffset -ne $pidl.Length-2){throw 'Invalid recycle PIDL list bounds.'}
    if($Completion.physicalPath -cne $Receipt.items[0].backupPath){throw 'Recycle physical path differs from CLI backupPath.'}
    $entries=@($Manifest.entries)
    if($entries.Count -ne 1 -or $entries[0].index -ne 0 -or $entries[0].path -cne $WorkDirectory -or $entries[0].kind -cne 'directory' -or $entries[0].state -cne 'recycle_intent'){throw 'Recycle manifest root mismatch.'}
    Assert-KhcRecycleV6IdentityData $entries[0].identity $Completion.identity
    foreach($security in @($entries[0].security,$Completion.security)){
        if($security -isnot [Collections.IDictionary] -or -not $security.Contains('')){throw 'Recycle metadata lacks root security identity.'}
        Assert-KhcRecycleV6IdentityData $entries[0].identity $security[''].identity
    }
    return $Completion
}

function Assert-KhcPrunletItems {
    param([Parameter(Mandatory)][object]$Run,[Parameter(Mandatory)][string]$ReceiptPath,[Parameter(Mandatory)][string]$Stage,[string]$OperationId)
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw "Prunletの$Stage receiptがありません: $ReceiptPath" }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $request = $Run.Request
    $isDelete = $Stage -like 'delete*'
    $isPreview = $Stage -like '*preview'
    if ([bool]$receipt.dryRun -ne $isPreview) { throw "Prunletの$Stage dryRun状態が一致しません。" }
    if ($isDelete) {
        if (-not $isPreview -and ([string]$receipt.operationId -cnotmatch '^[0-9a-f]{32}$')) { throw 'Prunlet deleteのoperationIdがありません。' }
    } elseif ([string]$receipt.operationId -cne $OperationId) { throw 'Prunlet purgeのoperationIdがdelete結果と異なります。' }
    if (@($receipt.warnings).Count -ne 0) { throw "Prunletの$Stageにwarningがあります。" }
    $expected = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($request.expected_entries)) {
        $path = if ($entry.path -eq '.') { $Run.WorkDirectory } else { [IO.Path]::GetFullPath((Join-Path $Run.WorkDirectory ([string]$entry.path))) }
        $bytes = if ($null -ne $entry.PSObject.Properties['bytes']) { [long]$entry.bytes } else { $null }
        $expected.Add($path,[pscustomobject]@{kind=[string]$entry.kind;bytes=$bytes;sha256=$null})
    }
    foreach ($file in @($request.expected_files)) {
        $path = [IO.Path]::GetFullPath((Join-Path $Run.WorkDirectory ([string]$file.path)))
        $hash = ([string]$file.sha256).ToLowerInvariant()
        if (-not $expected.ContainsKey($path) -or $expected[$path].kind -cne 'file' -or $hash -cnotmatch '^[0-9a-f]{64}$') { throw '清掃要求のfile SHA-256 proofが不正です。' }
        $expected[$path].sha256 = $hash
    }
    foreach ($path in @($expected.Keys)) {
        if ($expected[$path].kind -eq 'file' -and [string]::IsNullOrEmpty([string]$expected[$path].sha256)) { throw '清掃要求にfile SHA-256 proofが不足しています。' }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $items = @($receipt.items)
    if ($items.Count -ne $expected.Count) { throw "Prunletの$Stage item数がexpected treeと一致しません。" }
    foreach ($item in $items) {
        $path = [IO.Path]::GetFullPath([string]$item.path).TrimEnd([char[]]'\/')
        if (-not $expected.ContainsKey($path) -or -not $seen.Add($path)) { throw "Prunletの$Stageに未登録/重複pathがあります: $path" }
        $wanted = $expected[$path]
        if ([string]$item.kind -cne $wanted.kind) { throw "Prunletの$Stage kindが一致しません: $path" }
        if (-not [string]::IsNullOrEmpty([string]$item.error)) { throw "Prunletの$Stage itemにerrorがあります: $path" }
        if ($Stage -eq 'delete-preview' -and [string]$item.status -cne 'would_delete') { throw "Prunlet delete previewが対象を承認しません: $path ($($item.status))" }
        if ($Stage -eq 'delete-result' -and [string]$item.status -cne 'deleted') { throw "Prunlet deleteが全件成功していません: $path ($($item.status))" }
        if ($Stage -eq 'purge-preview') {
            $expectedStatus = if ($wanted.kind -eq 'file') { @('would_purge','already_purged') } else { @('not_backed_up') }
            if ([string]$item.status -notin $expectedStatus) { throw "Prunlet purge previewが対象を承認しません: $path ($($item.status))" }
        }
        if ($Stage -eq 'purge-result') {
            $expectedStatus = if ($wanted.kind -eq 'file') { @('purged','already_purged') } else { @('not_backed_up') }
            if ([string]$item.status -notin $expectedStatus) { throw "Prunlet purgeが全件成功していません: $path ($($item.status))" }
        }
        if ($wanted.kind -eq 'file') {
            if ($null -eq $item.size -or [long]$item.size -ne [long]$wanted.bytes) { throw "Prunletの$Stage file sizeが一致しません: $path" }
            if ($Stage -ne 'delete-preview') {
                $actualHash = ([string]$item.sha256).ToLowerInvariant()
                if ($actualHash -cnotmatch '^[0-9a-f]{64}$' -or $actualHash -cne $wanted.sha256) { throw "Prunletの$Stage file SHA-256が復元ZIPと一致しません: $path" }
            }
        }
    }
    if ($seen.Count -ne $expected.Count) { throw "Prunletの$Stageに対象pathが不足しています。" }
    if ($Stage -eq 'purge-result') {
        $purgedFiles = @($items | Where-Object { $_.status -eq 'purged' })
        $actualPurged = [long]0
        if ($purgedFiles.Count -gt 0) { $actualPurged = [long](($purgedFiles | Measure-Object -Property size -Sum).Sum) }
        if ([long]$receipt.purgedBytes -ne $actualPurged) { throw 'Prunlet purgeのpurgedBytesがitem合計と一致しません。' }
    }
    return $receipt
}

function Prepare-KhcStorageRun {
    param([Parameter(Mandatory)][object]$Context)
    try {
        $state = Assert-KhcPlainPath ([string]$Context.StateRoot)
        $recordDirectory = Assert-KhcPlainPath ([string]$Context.RecordDirectory)
        if (-not $recordDirectory.StartsWith($state + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'run台帳は同じD: taskのStateRoot配下に限定します。' }
        $record = Get-Content -LiteralPath $Context.RecordPath -Raw | ConvertFrom-Json
        $recycleV6=(Get-KhcRecycleV6RunProtocol $state $Context.RunId) -eq 6
        if($recycleV6){$privateReserve=Get-KhcRecycleV6RunAnchor $state $Context.RunId;$installed=Assert-KhcRecycleV6Installed}
        Assert-KhcMacCandidateE2eCleanupSeal ([pscustomobject]@{StateRoot=$state;RunId=$Context.RunId})
        $recoveredOwner = $Context.PSObject.Properties.Name -contains 'RecoveredOwner' -and [bool]$Context.RecoveredOwner
        if ($record.run_id -cne $Context.RunId -or $record.work_directory -cne $Context.WorkDirectory -or (-not $recoveredOwner -and $record.owner_pid -ne $PID)) { throw '清掃対象の所有台帳が一致しません。' }
        if ($recoveredOwner) {
            $recoveryEntries = [int]$Context.RecoveryEntries
            if ($recoveryEntries -lt 1 -or $recoveryEntries -gt 4096) { throw '回復時のentry上限が範囲外です。' }
            $record.max_entries = $recoveryEntries
        }
        $work = Assert-KhcPlainPath $Context.WorkDirectory
        $size = Get-KhcTreeUsage $work
        if($recycleV6 -and $size -gt [long]$record.max_bytes){throw 'Recycle-v6 recovery cannot exceed its protected payload reservation.'}
        $inventory = $null
        $backup = $null
        $requiresPrunlet = Test-Path -LiteralPath $work -PathType Container
        if ($requiresPrunlet) {
            $inventory = Get-KhcWorkInventory -WorkDirectory $work -MaxEntries $record.max_entries
            if ($inventory.Files.Count -gt 4096 -or @($inventory.Files | Where-Object { $_.path.Length -gt 512 }).Count -or @($inventory.Entries | Where-Object { $_.path.Length -gt 512 }).Count) { throw '台帳容量を保証できないfile数/相対パス長のため保持します（4096件/512文字まで）。' }
            # JSON escapingとZIP中央ディレクトリ、helperの各identityを含む予約。
            $reserve = $size + 1MB + $inventory.Metadata.Entries*65536L
            if($recycleV6){
                $physicalMetadataMargin=[long]$privateReserve.metadata_bytes+1MB
                Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 $privateReserve.max_bytes $physicalMetadataMargin
                $reserve=[long]$privateReserve.max_bytes+$physicalMetadataMargin
            }elseif ((Get-KhcLifecycleUsage) + $reserve -gt $script:LifecycleCapBytes) { throw '削除前の復元バックアップを1GiB枠へ収められません。一時物を保持して次の実行を停止します。' }
            $null = Assert-KhcStorageBudget -ReserveBytes $reserve
            $backup = Join-Path $Context.RecordDirectory 'recovery.zip'
            [IO.Compression.ZipFile]::CreateFromDirectory($work,$backup,[IO.Compression.CompressionLevel]::Fastest,$false)
            $zip = [IO.Compression.ZipFile]::OpenRead($backup)
            try {
                $entries = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
                if ($entries.Count -ne $inventory.Files.Count) { throw '復元バックアップの項目数不一致です。' }
                foreach ($file in $inventory.Files) {
                    $entry = $zip.GetEntry($file.path.Replace('\','/'))
                    if ($null -eq $entry -or $entry.Length -ne $file.bytes) { throw '復元バックアップの内容不一致です。' }
                    $stream = $entry.Open()
                    try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
                    if ($hash.ToLowerInvariant() -cne $file.sha256) { throw '復元バックアップのSHA-256不一致です。' }
                }
            } finally { $zip.Dispose() }
            $after = Get-KhcWorkInventory -WorkDirectory $work -MaxEntries $record.max_entries
            if ((ConvertTo-Json -InputObject $inventory.Entries -Depth 6 -Compress) -cne (ConvertTo-Json -InputObject $after.Entries -Depth 6 -Compress) -or (ConvertTo-Json -InputObject $inventory.Files -Depth 6 -Compress) -cne (ConvertTo-Json -InputObject $after.Files -Depth 6 -Compress)) { throw '復元ZIP作成中に作業ツリーが変化しました。' }
        }
        $manifest = Join-Path $Context.RecordDirectory 'recovery.json'
        $inventoryFiles = @()
        $inventoryEntries = @()
        if ($inventory) { $inventoryFiles = @($inventory.Files); $inventoryEntries = @($inventory.Entries) }
        $archiveHash = if ($backup) { (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        $recoveryOverrunBytes = [Math]::Max(0L, [long]$size - [long]$record.max_bytes)
        $recoveryOverrunLimitBytes = if ($recoveredOwner) { 1MB } else { 0L }
        Write-KhcNewJson $manifest ([ordered]@{schema=1;run_id=$Context.RunId;work_directory=$work;registered_max_bytes=[long]$record.max_bytes;measured_work_bytes=[long]$size;recovery_overrun_bytes=$recoveryOverrunBytes;recovery_overrun_limit_bytes=$recoveryOverrunLimitBytes;files=$inventoryFiles;entries=$inventoryEntries;backup_sha256=$archiveHash;restore='Expand-Archive recovery.zip into a fresh external Temp directory; compare every SHA-256 in files.';retention='復元に必要なため保持。1GiB固定枠到達時は停止し、明示された清掃だけを行う。'})
        $manifestHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
        $cleanupDirectory = Join-Path $Context.RecordDirectory 'cleanup'
        $null = New-Item -ItemType Directory -Path $cleanupDirectory -Force
        $pathsFile = Join-Path $cleanupDirectory 'paths.json'
        $cleanupPaths = [string[]]@()
        if ($requiresPrunlet) { $cleanupPaths = [string[]]@($work) }
        Write-KhcNewJson $pathsFile $cleanupPaths
        $request = [ordered]@{
            schema=1;run_id=$Context.RunId;work_directory=$work;requires_prunlet=$requiresPrunlet
            paths_file=$pathsFile;delete_preview_path=(Join-Path $cleanupDirectory 'delete-preview.json');delete_result_path=(Join-Path $cleanupDirectory 'delete-result.json')
            purge_preview_path=(Join-Path $cleanupDirectory 'purge-preview.json');purge_result_path=(Join-Path $cleanupDirectory 'purge-result.json')
            recovery_manifest_path=$manifest;recovery_manifest_sha256=$manifestHash;recovery_archive_path=$backup;recovery_archive_sha256=$archiveHash
            expected_files=$inventoryFiles;expected_entries=$inventoryEntries;expected_bytes=$size;created_utc=[DateTime]::UtcNow.ToString('o')
        }
        $requestPath = Join-Path $Context.RecordDirectory 'cleanup-request.json'
        if($recycleV6){$request.schema=2;$request.protocol='prunlet-recycle-v6'}
        Write-KhcNewJson $requestPath $request
        if($recycleV6){
            $root=Get-KhcRecycleV6AnchorRoot
            Write-KhcNewJson (Join-Path $root "$($Context.RunId).request.json") ([ordered]@{schema=1;run_id=$Context.RunId;reservation_sha256=(Get-KhcRecycleV6Hash (Join-Path $root "$($Context.RunId).reserve.json"));request_path=$requestPath;request_sha256=(Get-KhcRecycleV6Hash $requestPath);archive_path=$backup;archive_sha256=$archiveHash;manifest_path=$manifest;manifest_sha256=$manifestHash;paths_path=$pathsFile;paths_sha256=(Get-KhcRecycleV6Hash $pathsFile);exe_sha256=$installed.exe_sha256;config_sha256=$installed.config_sha256;metadata_root=$installed.metadata_root})
            $null=Get-KhcRecycleV6RunAnchor $state $Context.RunId -Request
        }
        # Prunletの一時復元copyも今回の上限・空き予約に含め、完了前に固定枠を超えない。
        $null = Assert-KhcStorageBudget -ReserveBytes ($(if ($requiresPrunlet) { $size + 1MB } else { 0L }))
        [pscustomobject]@{RunId=$Context.RunId;WorkDirectory=$work;RecordDirectory=$Context.RecordDirectory;RequestPath=$requestPath;BackupPath=$backup;ManifestPath=$manifest;State='awaiting-prunlet';BeforeBytes=$size;AfterBytes=$size;RequiresPrunlet=$requiresPrunlet}
    } finally { $Context.Lock.Dispose() }
}

function Recover-KhcUnstartedStorageRun {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId)
    $location = Get-KhcStorageRunLocation $RunId
    $null=Get-KhcRecycleV6RunProtocol $location.StateRoot $RunId
    if (-not $location.TaskRoot) { throw '旧C:または共有 StateRootは読取専用の履歴です。未開始runを更新しません。' }
    $state = Assert-KhcPlainPath $location.StateRoot
    $workParent = Assert-KhcPlainPath $location.TaskRoot
    $directory = Assert-KhcPlainPath $location.Directory
    $recordPath = Assert-KhcPlainPath $location.RecordPath
    $registrationLease = $null; $serialLock = $null; $cargoLock = $null
    try {
        $registrationLease = [Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $serialLock = [IO.File]::Open((Join-Path $state 'serial.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cargoLock = [Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        Assert-KhcNoPendingStorageRuns -AllowedRecordPath $recordPath -AllowInactiveOwner
        $runDirectories = @(Get-ChildItem -LiteralPath (Join-Path $state 'runs') -Directory -Force)
        foreach ($runDirectory in $runDirectories) {
            if ($runDirectory.FullName -ine $directory -and -not (Test-Path -LiteralPath (Join-Path $runDirectory.FullName 'complete.json') -PathType Leaf)) {
                throw "別の未完了runがあるため回復を停止します: $($runDirectory.FullName)"
            }
        }
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $directory 'complete.json')) -or (Test-Path -LiteralPath (Join-Path $directory 'cleanup-request.json'))) { throw '未開始runの記録状態が一致しません。' }
        $ledgerItems = @(Get-ChildItem -LiteralPath $directory -Force)
        $ledgerNames=@('run.json','invocation.clixml')
        if(Test-Path -LiteralPath (Join-Path $directory 'recycle-v6.json')){$null=Get-KhcRecycleV6RunAnchor $state $RunId;$ledgerNames+='recycle-v6.json'}
        if ($ledgerItems.Count -ne $ledgerNames.Count -or @($ledgerItems | Where-Object { $_.Name -notin $ledgerNames -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -ne 0) { throw '未開始run台帳に未登録の項目があります。' }
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $recordFields = @('run_id','work_directory','max_bytes','max_entries','owner_pid','owner_start_ticks','owner_start_utc','created_utc')
        if ($record -isnot [pscustomobject] -or @($record.PSObject.Properties).Count -ne $recordFields.Count) { throw '未開始run記録のschemaが一致しません。' }
        foreach ($field in $recordFields) { if ($null -eq $record.PSObject.Properties[$field]) { throw "未開始run記録に必須項目がありません: $field" } }
        if ($record.run_id -cne $RunId -or $record.owner_pid -le 0 -or $record.owner_start_ticks -le 0 -or $record.max_bytes -lt 1MB -or $record.max_bytes -gt 32MB -or $record.max_entries -lt 1 -or $record.max_entries -gt 4096) { throw '未開始run記録の値が範囲外です。' }
        $owner = $null
        try { $owner = [Diagnostics.Process]::GetProcessById([int]$record.owner_pid) } catch [ArgumentException] { }
        if ($null -ne $owner) {
            try {
                if ($owner.StartTime.ToUniversalTime().Ticks -eq [long]$record.owner_start_ticks) { throw 'run所有プロセスがまだ実行中です。' }
            } finally { $owner.Dispose() }
        }
        $work = Assert-KhcPlainPath ([string]$record.work_directory)
        if ([IO.Path]::GetDirectoryName($work) -ine $workParent -or $work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or $work.Length -gt 200) { throw '未開始runの作業先がD: task workspace直下のrun-GUIDではありません。' }
        if (-not (Test-Path -LiteralPath $work -PathType Container)) { throw '未開始runの作業先がありません。' }
        $invocationPath = Join-Path $directory 'invocation.clixml'
        if ((Get-Item -LiteralPath $invocationPath).Length -gt 32KB) { throw '未開始runのinvocation記録が32KiBを超えています。' }
        $invocation = [Management.Automation.PSSerializer]::Deserialize((Get-Content -LiteralPath $invocationPath -Raw))
        $expectedScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'version-delta-screen.ps1'))
        if ([IO.Path]::GetFullPath([string]$invocation.script) -ine $expectedScript -or $invocation.parameters.WorkDirectory -cne $work -or $invocation.parameters.Dataset -notin @('putty','7zr')) { throw '未開始runのinvocationが版間delta screenの記録と一致しません。' }
        $children = @(Get-ChildItem -LiteralPath $work -Force)
        $expectedNames = @('runs','source','tools')
        if ($children.Count -ne $expectedNames.Count -or @($children | Where-Object { $_.Name -notin $expectedNames -or -not $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -ne 0) { throw '回復対象は空のruns/source/toolsディレクトリだけに限定します。' }
        foreach ($child in $children) { if (@(Get-ChildItem -LiteralPath $child.FullName -Force).Count -ne 0) { throw "回復対象の作業directoryが空ではありません: $($child.FullName)" } }
        $tree = [Khc.Storage.TreeCounter]::Measure($work,4096,512)
        if ($tree.Bytes -gt [long]$record.max_bytes -or $tree.Entries -ne 3) { throw '回復対象の空directory inventoryが想定と一致しません。' }
        $context = [pscustomobject]@{
            RunId=$RunId;WorkDirectory=$work;RecordPath=$recordPath;RecordDirectory=$directory;StateRoot=$state;TempRoot=$location.TempRoot
            Lock=$serialLock;RecoveredOwner=$true;RecoveryEntries=[Math]::Max(1,$tree.Entries)
        }
        $serialLock = $null
        return Prepare-KhcStorageRun -Context $context
    } finally {
        if ($null -ne $cargoLock) { $cargoLock.Dispose() }
        if ($null -ne $serialLock) { $serialLock.Dispose() }
        if ($null -ne $registrationLease) { $registrationLease.Dispose() }
    }
}

function Recover-KhcAbandonedStorageRun {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId)
    $location = Get-KhcStorageRunLocation $RunId
    $null=Get-KhcRecycleV6RunProtocol $location.StateRoot $RunId
    if (-not $location.TaskRoot) { throw '旧C:または共有 StateRootは読取専用の履歴です。放棄runを更新しません。' }
    $state = Assert-KhcPlainPath $location.StateRoot
    $workParent = Assert-KhcPlainPath $location.TaskRoot
    $directory = Assert-KhcPlainPath $location.Directory
    $recordPath = Assert-KhcPlainPath $location.RecordPath
    $registrationLease = $null; $serialLock = $null; $cargoLock = $null
    try {
        $registrationLease = [Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $serialLock = [IO.File]::Open((Join-Path $state 'serial.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cargoLock = [Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        Assert-KhcNoPendingStorageRuns -AllowedRecordPath $recordPath -AllowInactiveOwner
        foreach ($runDirectory in Get-ChildItem -LiteralPath (Join-Path $state 'runs') -Directory -Force) {
            if ($runDirectory.FullName -ine $directory -and -not (Test-Path -LiteralPath (Join-Path $runDirectory.FullName 'complete.json') -PathType Leaf)) {
                throw "別の未完了runがあるため回復を停止します: $($runDirectory.FullName)"
            }
        }
        if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $directory 'complete.json')) -or
            (Test-Path -LiteralPath (Join-Path $directory 'cleanup-request.json'))) {
            throw '放棄runはrun.jsonのみで、未完了の清掃要求がない状態に限定します。'
        }
        $ledgerItems = @(Get-ChildItem -LiteralPath $directory -Force)
        $ledgerNames=@('run.json','invocation.clixml')
        if(Test-Path -LiteralPath (Join-Path $directory 'recycle-v6.json')){$null=Get-KhcRecycleV6RunAnchor $state $RunId;$ledgerNames+='recycle-v6.json'}
        if ($ledgerItems.Count -ne $ledgerNames.Count -or @($ledgerItems | Where-Object { $_.Name -notin $ledgerNames -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count -ne 0) {
            throw '放棄run台帳はrun.jsonとinvocation.clixmlだけに限定します。'
        }
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $recordFields = @('run_id','work_directory','max_bytes','max_entries','owner_pid','owner_start_ticks','owner_start_utc','created_utc')
        if ($record -isnot [pscustomobject] -or @($record.PSObject.Properties).Count -ne $recordFields.Count) { throw '放棄run記録のschemaが一致しません。' }
        foreach ($field in $recordFields) { if ($null -eq $record.PSObject.Properties[$field]) { throw "放棄run記録に必須項目がありません: $field" } }
        if ($record.run_id -cne $RunId -or $record.owner_pid -le 0 -or $record.owner_start_ticks -le 0 -or $record.max_bytes -lt 1MB -or $record.max_bytes -gt 32MB -or $record.max_entries -lt 1 -or $record.max_entries -gt 4096) {
            throw '放棄run記録の値が範囲外です。'
        }
        $owner = $null
        try { $owner = [Diagnostics.Process]::GetProcessById([int]$record.owner_pid) } catch [ArgumentException] { }
        if ($null -ne $owner) {
            try {
                if ($owner.StartTime.ToUniversalTime().Ticks -eq [long]$record.owner_start_ticks) { throw 'run所有プロセスがまだ実行中です。' }
            } finally { $owner.Dispose() }
        }
        $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)
        $lineage = [Collections.Generic.HashSet[long]]::new()
        $null = $lineage.Add([long]$record.owner_pid)
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($process in $processes) {
                if ($lineage.Contains([long]$process.ParentProcessId) -and $lineage.Add([long]$process.ProcessId)) { $changed = $true }
            }
        }
        if ($lineage.Count -gt 1) { throw 'run所有プロセスの子孫が残っているため回復を停止します。' }

        $work = Assert-KhcPlainPath ([string]$record.work_directory)
        if ([IO.Path]::GetDirectoryName($work) -ine $workParent -or $work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or $work.Length -gt 200) {
            throw '放棄runの作業先がD: task workspace直下のrun-GUIDではありません。'
        }
        if (-not (Test-Path -LiteralPath $work -PathType Container)) { throw '放棄runの作業先がありません。' }
        $invocationPath = Join-Path $directory 'invocation.clixml'
        if ((Get-Item -LiteralPath $invocationPath).Length -gt 32KB) { throw '放棄runのinvocation記録が32KiBを超えています。' }
        $invocation = [Management.Automation.PSSerializer]::Deserialize((Get-Content -LiteralPath $invocationPath -Raw))
        $allowed = @('compare.ps1','compare-solid.ps1','measure-internal.ps1','causal-bayes-fast-bwt/compare.ps1','test-storage-staged-e2e.ps1','version-delta-screen.ps1','record-fast-screen.ps1','record-fast-7zip-screen.ps1','record-adaptive-screen.ps1','shared-history-screen.ps1','greedy-entropy-bound-screen.ps1','all-class-static/run-frame-e2e.ps1','product-pipeline-e2e.ps1','portfolio-7zip-product-screen.ps1') | ForEach-Object { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $_)) }
        $allowed += [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'spatial-mdl-e2e.ps1'))
        $nativeWorker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'mac-spatial-mdl-e2e.ps1'))
        $allowed+=$nativeWorker
        $candidateWorker=(Get-KhcMacCandidateE2eKind).Worker
        $allowed+=$candidateWorker
        $referenceWorker=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'mac-canterbury-reference.ps1'))
        $allowed+=$referenceWorker
        $invocationScript = [IO.Path]::GetFullPath([string]$invocation.script)
        if ($invocationScript -notin $allowed -or $invocation.parameters.WorkDirectory -cne $work) {
            throw '放棄runのinvocationが登録済み入口または作業先と一致しません。'
        }
        if($invocationScript -ceq $nativeWorker){
            $reserve=Get-KhcRecycleV6RunAnchor $state $RunId
            $native=Get-KhcMacNativeE2eRegistration $state $RunId $reserve -RequireInvocation
            if($null -eq $native -or $record.max_bytes -ne 8MB -or $record.max_entries -ne 96 -or $invocation.parameters.Count -ne 3 -or @($invocation.parameters.Keys | Where-Object {$_ -cnotin @('WorkDirectory','ProtocolPath','ProtocolSha256')}).Count -or $invocation.parameters.ProtocolPath -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-native-e2e-ps-free-protocol.json') -or $invocation.parameters.ProtocolSha256 -cne $native.Record.protocol_sha256){throw 'Recovered native invocation differs from its private registration.'}
        }
        if($invocationScript -ceq $candidateWorker){
            $reserve=Get-KhcRecycleV6RunAnchor $state $RunId
            $candidate=Get-KhcMacCandidateE2eRegistration $state $RunId $reserve -RequireInvocation -RequireSeal
            if($null -eq $candidate -or $record.max_bytes -ne 8MB -or $record.max_entries -ne 96){throw 'Recovered candidate E2E must have a verified private terminal seal.'}
            $raw=Read-KhcBoundedSnapshotBytes $invocationPath 32768
            $null=ConvertFrom-KhcMacNativeInvocationSnapshot $raw $candidate.Record.invocation_sha256 'candidate-e2e'
        }
        if($invocationScript -ceq $referenceWorker){
            $reserve=Get-KhcRecycleV6RunAnchor $state $RunId;$reference=Get-KhcMacReferenceRegistration $state $RunId $reserve -RequireInvocation
            if($null -eq $reference -or $record.max_bytes -ne 8MB -or $record.max_entries -ne 96 -or $invocation.parameters.Count -ne 3 -or @($invocation.parameters.Keys | Where-Object {$_ -cnotin @('WorkDirectory','ProtocolPath','ProtocolSha256')}).Count -or $invocation.parameters.ProtocolPath -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'TaskArtifacts\goal-restore-20261019\mac-canterbury-reference-protocol.json') -or $invocation.parameters.ProtocolSha256 -cne $reference.Record.protocol_sha256){throw 'Recovered reference invocation differs from its private registration.'}
        }
        $portfolioProductScreen = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'portfolio-7zip-product-screen.ps1'))
        if ($invocationScript -ieq $portfolioProductScreen) {
            $parameters = $invocation.parameters
            $expectedParameterNames = @('WorkDirectory','CorpusProfile','Round','Strategy','KhcExecutable','SevenZipPath','InputRecoveryZip')
            if ($parameters -isnot [System.Collections.IDictionary]) { throw 'PortfolioTrial recovery parameters must be a dictionary.' }
            $profile=Get-KhcPortfolioInputProfile ([string]$parameters['CorpusProfile'])
            if ($profile.Name -ceq 'UciTabularDevelopment20261020') { throw 'UCI development-only metadata cannot enter portfolio run recovery or holdout evaluation.' }
            if ($profile.Name -cin @('AozoraDevelopment20261020','CanterburyDevelopmentKcs1CountLength20261020','JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) { $expectedParameterNames+=@('CampaignManifestSha256') }
            if ($parameters -isnot [System.Collections.IDictionary] -or
                @($parameters.Keys).Count -ne $expectedParameterNames.Count -or
                @($parameters.Keys | Where-Object { $_ -cnotin $expectedParameterNames }).Count -ne 0 -or
                $record.max_bytes -ne 32MB -or $record.max_entries -ne 512 -or
                [string]$parameters['CorpusProfile'] -cne $profile.Name -or
                $parameters['Round'] -isnot [int] -or [int]$parameters['Round'] -lt 0 -or [int]$parameters['Round'] -gt 9 -or
                [string]$parameters['Strategy'] -cnotin @('portfolio-trial','7zip') -or
                [IO.Path]::GetFullPath([string]$parameters['InputRecoveryZip']) -cne (Get-KhcPortfolioInputZipPath $profile) -or
                [IO.Path]::GetFullPath([string]$parameters['KhcExecutable']) -cne (Join-Path (Join-Path ([Environment]::GetEnvironmentVariable('TEMP','User') ?? [IO.Path]::GetTempPath()) 'UnLhaRe') 'work\goal-restore-20261019\cargo\x86_64-pc-windows-msvc\release\unlhare-cli.exe') -or
                [IO.Path]::GetFullPath([string]$parameters['SevenZipPath']) -cne 'C:\Program Files\7-Zip\7z.exe') {
                throw '放棄runのPortfolioTrial single-sample invocation schema/parameters do not match the fixed campaign.'
            }
            if ($profile.Name -cin @('JmaTokyoDaily2010_2025Holdout20261020','TokyoResidentRegister202101Holdout20261020','LivedoorNews2012Holdout20261020','NictWikiCorpusHoldout20261020','NictWikiCorpusKcs1CountLengthHoldout20261020','UciDryBeanHoldout20261020')) {
                # holdoutはmarkerの検証が完了する前にpayloadを読み取らない。
                $campaignValidator=if($profile.Name -ceq 'UciDryBeanHoldout20261020'){'Assert-KhcDryBeanHoldoutCampaign'}elseif($profile.Name -ceq 'JmaTokyoDaily2010_2025Holdout20261020'){'Assert-KhcJmaHoldoutCampaign'}elseif($profile.Name -ceq 'LivedoorNews2012Holdout20261020'){'Assert-KhcLivedoorHoldoutCampaign'}elseif($profile.Name -ceq 'NictWikiCorpusKcs1CountLengthHoldout20261020'){'Assert-KhcNictKcs1HoldoutCampaign'}elseif($profile.Name -ceq 'NictWikiCorpusHoldout20261020'){'Assert-KhcNictHoldoutCampaign'}else{'Assert-KhcTokyoPopulationHoldoutCampaign'}
                $null=& $campaignValidator -CampaignManifestSha256 ([string]$parameters['CampaignManifestSha256'])
            } else {
                $null=Assert-KhcPortfolioInput -CorpusProfile $profile.Name -InputRecoveryZip ([string]$parameters['InputRecoveryZip']) -CampaignManifestSha256 ([string]$parameters['CampaignManifestSha256'])
                if ($profile.Name -ceq 'AozoraDevelopment20261020') { $null=Assert-KhcAozoraCampaign -CampaignManifestSha256 ([string]$parameters['CampaignManifestSha256']) }
                if ($profile.Name -ceq 'CanterburyDevelopmentKcs1CountLength20261020') { $null=Assert-KhcCanterburyKcs1Campaign -CampaignManifestSha256 ([string]$parameters['CampaignManifestSha256']) }
            }
        }
        $tree = [Khc.Storage.TreeCounter]::Measure($work,4096,512)
        $recoveryOverrunBytes = [long]$tree.Bytes - [long]$record.max_bytes
        if ($recoveryOverrunBytes -gt 1MB) { throw '放棄runの作業量が登録容量枠を1MiB超えています。復旧専用上限を超えるため保持します。' }
        $inventory = Get-KhcWorkInventory -WorkDirectory $work -MaxEntries 4096
        if ($inventory.Metadata.Entries -ne $tree.Entries) { throw '放棄runのinventory件数が安定しません。' }
        $reserve = [long]$tree.Bytes + 1MB + [long]$inventory.Metadata.Entries * 65536L
        if ((Get-KhcLifecycleUsage) + $reserve -gt $script:LifecycleCapBytes) { throw '回復用の復元ZIPと台帳を固定1GiB枠へ収められません。' }
        $null = Assert-KhcStorageBudget -ReserveBytes $reserve
        $context = [pscustomobject]@{
            RunId=$RunId;WorkDirectory=$work;RecordPath=$recordPath;RecordDirectory=$directory;StateRoot=$state;TempRoot=$location.TempRoot
            Lock=$serialLock;RecoveredOwner=$true;RecoveryEntries=[Math]::Max(1,[int]$inventory.Metadata.Entries)
        }
        $serialLock = $null
        return Prepare-KhcStorageRun -Context $context
    } finally {
        if ($null -ne $cargoLock) { $cargoLock.Dispose() }
        if ($null -ne $serialLock) { $serialLock.Dispose() }
        if ($null -ne $registrationLease) { $registrationLease.Dispose() }
    }
}

function Assert-KhcRecycleV6Tree {
    param([object]$Run,[string]$Root)
    function Get-KhcInventoryValue {
        param([object]$Item,[string]$Name)
        if($Item -is [Collections.IDictionary]){
            if($Item.Keys -cnotcontains $Name){throw "Recycle inventory field is missing: $Name"}
            return $Item[$Name]
        }
        $property=$Item.PSObject.Properties[$Name]
        if($null -eq $property){throw "Recycle inventory field is missing: $Name"}
        return $property.Value
    }
    function ConvertTo-KhcInventoryMap {
        param([object[]]$Items,[switch]$FileProof)
        # Dictionary keyとPSCustomObject propertyを同じ明示的な読取経路へ正規化する。
        # Ordinal keyで名前そのものを比較し、列挙順・文化依存sort・大文字小文字の畳込みを避ける。
        $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($item in $Items){
            $path=Get-KhcInventoryValue $item 'path'
            if($path -isnot [string] -or [string]::IsNullOrEmpty($path)){throw 'Recycle inventory path is not an exact nonempty string.'}
            $kind=if($FileProof){'file'}else{Get-KhcInventoryValue $item 'kind'}
            if($kind -cnotin @('directory','file')){throw 'Recycle inventory kind is invalid.'}
            $bytes=0L;$hash=$null
            if($kind -ceq 'file'){
                $bytes=Get-KhcInventoryValue $item 'bytes'
                if(($bytes -isnot [int] -and $bytes -isnot [long]) -or $bytes -lt 0){throw 'Recycle inventory file bytes are invalid.'}
                if($FileProof){
                    $hash=Get-KhcInventoryValue $item 'sha256'
                    if($hash -isnot [string] -or $hash -cnotmatch '^[0-9a-f]{64}$'){throw 'Recycle inventory SHA-256 is invalid.'}
                }
            }
            if(-not $map.TryAdd($path,[pscustomobject]@{kind=$kind;bytes=[long]$bytes;sha256=$hash})){throw "Duplicate exact recycle inventory path: $path"}
        }
        return ,$map
    }
    $tree=Get-KhcWorkInventory -WorkDirectory $Root -MaxEntries $Run.Record.max_entries
    $actualEntries=ConvertTo-KhcInventoryMap -Items @($tree.Entries)
    $wantedEntries=ConvertTo-KhcInventoryMap -Items @($Run.Request.expected_entries)
    $actualFiles=ConvertTo-KhcInventoryMap -Items @($tree.Files) -FileProof
    $wantedFiles=ConvertTo-KhcInventoryMap -Items @($Run.Request.expected_files) -FileProof
    if($actualEntries.Count -ne $wantedEntries.Count -or $actualFiles.Count -ne $wantedFiles.Count -or $tree.Metadata.Bytes -ne $Run.Request.expected_bytes){throw 'Recycle-v6 full tree counts/bytes differ from recovery inventory.'}
    foreach($path in $actualEntries.Keys){
        if(-not $wantedEntries.ContainsKey($path)){throw 'Recycle-v6 exact entry path differs from recovery inventory.'}
        $left=$actualEntries[$path];$right=$wantedEntries[$path]
        if($left.kind -cne $right.kind -or $left.bytes -ne $right.bytes){throw 'Recycle-v6 root/empty-directory/file inventory differs from recovery archive.'}
    }
    foreach($path in $actualFiles.Keys){
        if(-not $wantedFiles.ContainsKey($path)){throw 'Recycle-v6 exact file path differs from recovery inventory.'}
        $left=$actualFiles[$path];$right=$wantedFiles[$path]
        if($left.bytes -ne $right.bytes -or $left.sha256 -cne $right.sha256){throw 'Recycle-v6 full file SHA-256 differs from recovery archive.'}
    }
}

function Get-KhcRecycleV6TextHash {
    param([string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($Text))).ToLowerInvariant()
}

function Get-KhcRecycleV6LiveProof {
    param([object]$Run)
    Assert-KhcMacNativeE2eCleanupSeal $Run
    Assert-KhcMacReferenceCleanupSeal $Run
    Assert-KhcMacCandidateE2eCleanupSeal $Run
    $installed=Assert-KhcRecycleV6Installed
    $binding=Get-KhcRecycleV6RunAnchor $Run.StateRoot $Run.RunId -Request
    $reserve=Get-KhcRecycleV6RunAnchor $Run.StateRoot $Run.RunId
    if(Test-Path -LiteralPath $Run.WorkDirectory){throw 'Recycle-v6 original work root is still present.'}
    $proof=[ordered]@{schema=1;protocol='prunlet-recycle-v6';run_id=$Run.RunId;request_sha256=$binding.request_sha256;archive_sha256=$binding.archive_sha256;exe_sha256=$binding.exe_sha256;config_sha256=$binding.config_sha256;operation_id=$null;disposition='recycle-retained';root_after_bytes=0L;root_after_scope='registered original work root only; Bin payload is retained';reclaimed_bytes=0L;payload_bytes=[long]$Run.Request.expected_bytes;metadata_bytes=[long]$reserve.metadata_bytes;observed_external_metadata_bytes=0L;delete_preview=$null;delete_result=$null;manifest_text=$null;completion_text=$null;manifest_sha256=$null;completion_sha256=$null;verified_utc=[DateTime]::UtcNow.ToString('o')}
    if(-not $Run.Request.requires_prunlet){if($Run.Request.expected_bytes -ne 0){throw 'Absent recycle-v6 work root has nonzero expected bytes.'};return $proof}
    $null=Assert-KhcRecoveryArchive $Run
    $preview=Get-Content -LiteralPath (Assert-KhcPlainPath $Run.Request.delete_preview_path) -Raw | ConvertFrom-Json -AsHashtable
    $deleted=Get-Content -LiteralPath (Assert-KhcPlainPath $Run.Request.delete_result_path) -Raw | ConvertFrom-Json -AsHashtable
    $null=Assert-KhcRecycleV6ReceiptData $preview $Run.WorkDirectory 'delete-preview'
    $null=Assert-KhcRecycleV6ReceiptData $deleted $Run.WorkDirectory 'delete-result'
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $drive=[IO.Path]::GetPathRoot($Run.WorkDirectory)
    $binParent=Join-Path (Join-Path $drive '$Recycle.Bin') $sid
    $bin=[IO.Path]::GetFullPath([string]$deleted.items[0].backupPath)
    if($bin -cne $deleted.items[0].backupPath -or [IO.Path]::GetDirectoryName($bin) -ine $binParent -or [IO.Path]::GetFileName($bin) -cnotmatch '^\$R[A-Z0-9]+$'){throw 'Recycle payload is not the canonical original-drive/current-SID $R root.'}
    $bin=Assert-KhcPlainPath $bin
    if(-not [IO.Directory]::Exists($bin)){throw 'Live recycle payload directory is missing.'}
    Assert-KhcRecycleV6Tree $Run $bin
    $metadataRoot=Assert-KhcRecycleV6PrivatePath $installed.metadata_root
    $operation=Assert-KhcRecycleV6PrivatePath (Join-Path $metadataRoot $deleted.operationId)
    $manifestPath=Assert-KhcRecycleV6PrivatePath (Join-Path $operation 'recycle-manifest.json')
    $completionPath=Assert-KhcRecycleV6PrivatePath (Join-Path $operation 'recycle-0000-complete.json')
    $manifestText=Get-Content -LiteralPath $manifestPath -Raw
    $completionText=Get-Content -LiteralPath $completionPath -Raw
    $manifestHash=Get-KhcRecycleV6Hash $manifestPath;$completionHash=Get-KhcRecycleV6Hash $completionPath
    if((Get-KhcRecycleV6TextHash $manifestText) -cne $manifestHash -or (Get-KhcRecycleV6TextHash $completionText) -cne $completionHash){throw 'Recycle metadata changed while reading.'}
    $manifest=ConvertFrom-Json -InputObject $manifestText -AsHashtable
    $completion=ConvertFrom-Json -InputObject $completionText -AsHashtable
    $null=Assert-KhcRecycleV6MetadataData $manifest $completion $deleted $manifestHash $Run.WorkDirectory $installed.metadata_root $sid ([Environment]::MachineName)
    # 永続identityはPrunletのmanifest/complete DTO間で照合する。MACや認証の主張はしない。
    $observed=Get-KhcTreeUsage $operation
    $proof.operation_id=$deleted.operationId;$proof.delete_preview=$preview;$proof.delete_result=$deleted
    $proof.manifest_text=$manifestText;$proof.completion_text=$completionText;$proof.manifest_sha256=$manifestHash;$proof.completion_sha256=$completionHash
    $proof.observed_external_metadata_bytes=$observed;$proof.metadata_bytes=[Math]::Max([long]$reserve.metadata_bytes,[long]$observed)
    Assert-KhcRecycleV6Tree $Run $bin
    return $proof
}

function Complete-KhcRecycleV6Run {
    param([object]$Run)
    $proof=Get-KhcRecycleV6LiveProof $Run
    $privateReserve=Get-KhcRecycleV6RunAnchor $Run.StateRoot $Run.RunId
    $physicalMetadataMargin=[long]$privateReserve.metadata_bytes+1MB
    Assert-KhcRecycleV6CapacityData (Get-KhcLifecycleUsage) (Get-KhcRecycleV6Charges).total_bytes 0 0 $physicalMetadataMargin
    $null=Assert-KhcStorageBudget -ReserveBytes $physicalMetadataMargin
    $root=Assert-KhcRecycleV6PrivatePath (Join-Path $Run.StateRoot 'recycle-v6') -ProtectedRoot
    $proofPath=Join-Path $Run.Directory 'recycle-v6-proof.json'
    Write-KhcNewJson $proofPath $proof
    $proofHash=Get-KhcRecycleV6Hash $proofPath
    $result=[ordered]@{RunId=$Run.RunId;WorkDirectory=$Run.WorkDirectory;BackupPath=$Run.Request.recovery_archive_path;ManifestPath=$Run.Request.recovery_manifest_path;RequestPath=$Run.RequestPath;Protocol='prunlet-recycle-v6';Disposition='recycle-retained';OperationId=$proof.operation_id;State='complete';BeforeBytes=[long]$Run.Request.expected_bytes;AfterBytes=0L;RootAfterScope=$proof.root_after_scope;ReclaimedBytes=0L;RetainedPayloadChargeBytes=$proof.payload_bytes;ExternalMetadataChargeBytes=$proof.metadata_bytes;ProofPath=$proofPath;ProofSha256=$proofHash;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
    $completeHash=Get-KhcRecycleV6TextHash (ConvertTo-Json -InputObject $result -Depth 12)
    Write-KhcNewJson (Join-Path $root "$($Run.RunId).final.json") ([ordered]@{schema=1;run_id=$Run.RunId;reservation_sha256=(Get-KhcRecycleV6Hash (Join-Path $root "$($Run.RunId).reserve.json"));request_sha256=$proof.request_sha256;archive_sha256=$proof.archive_sha256;exe_sha256=$proof.exe_sha256;config_sha256=$proof.config_sha256;operation_id=$proof.operation_id;payload_bytes=$proof.payload_bytes;metadata_bytes=$proof.metadata_bytes;proof_path=$proofPath;proof_sha256=$proofHash;complete_sha256=$completeHash})
    # final anchorの公開後もBinの消失から容量creditを作らず、保存した量を継続計上する。
    $null=Assert-KhcStorageBudget
    Write-KhcNewJson (Join-Path $Run.Directory 'complete.json') $result
    return [pscustomobject]$result
}

function Test-KhcRecycleV6Completed {
    param([object]$Location,[string]$RunId,[object]$Record,[object]$Request,[object]$Complete)
    Assert-KhcMacNativeE2eCleanupSeal ([pscustomobject]@{StateRoot=$Location.StateRoot;RunId=$RunId})
    Assert-KhcMacReferenceCleanupSeal ([pscustomobject]@{StateRoot=$Location.StateRoot;RunId=$RunId})
    Assert-KhcMacCandidateE2eCleanupSeal ([pscustomobject]@{StateRoot=$Location.StateRoot;RunId=$RunId})
    $binding=Get-KhcRecycleV6RunAnchor $Location.StateRoot $RunId -Request
    $reserve=Get-KhcRecycleV6RunAnchor $Location.StateRoot $RunId
    $final=Read-KhcRecycleV6PrivateJson (Join-Path (Join-Path $Location.StateRoot 'recycle-v6') "$RunId.final.json")
    if($final.reservation_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path (Join-Path $Location.StateRoot 'recycle-v6') "$RunId.reserve.json"))){throw 'Completed recycle-v6 final lost its reservation binding.'}
    $proofPath=Assert-KhcPlainPath (Join-Path $Location.Directory 'recycle-v6-proof.json')
    if($Request.protocol -cne 'prunlet-recycle-v6' -or $Request.run_id -cne $RunId -or $Record.run_id -cne $RunId -or $Record.work_directory -cne $Request.work_directory -or $final.schema -ne 1 -or $final.run_id -cne $RunId -or $final.proof_path -cne $proofPath -or $final.proof_sha256 -cne (Get-KhcRecycleV6Hash $proofPath) -or $final.complete_sha256 -cne (Get-KhcRecycleV6Hash (Join-Path $Location.Directory 'complete.json'))){throw 'Completed recycle-v6 anchor/proof/record mismatch.'}
    $proof=Get-Content -LiteralPath $proofPath -Raw | ConvertFrom-Json -AsHashtable
    foreach($field in @('request_sha256','archive_sha256','exe_sha256','config_sha256')){if($proof[$field] -cne $binding[$field] -or $final[$field] -cne $binding[$field]){throw 'Completed recycle-v6 request/ZIP/executable binding mismatch.'}}
    if($proof.schema -ne 1 -or $proof.protocol -cne 'prunlet-recycle-v6' -or $proof.run_id -cne $RunId -or $proof.operation_id -cne $final.operation_id -or $proof.payload_bytes -ne $Request.expected_bytes -or $proof.payload_bytes -lt 0 -or $proof.payload_bytes -gt $reserve.payload_bytes -or $proof.metadata_bytes -lt $reserve.metadata_bytes -or $proof.payload_bytes -ne $final.payload_bytes -or $proof.metadata_bytes -ne $final.metadata_bytes -or $proof.disposition -cne 'recycle-retained' -or $proof.reclaimed_bytes -ne 0 -or $proof.root_after_bytes -ne 0 -or $Complete.Disposition -cne 'recycle-retained' -or $Complete.ReclaimedBytes -ne 0){throw 'Completed recycle-v6 disposition/charge mismatch.'}
    if($Request.requires_prunlet){
        $run=[pscustomobject]@{RunId=$RunId;WorkDirectory=$Record.work_directory;Request=$Request}
        $null=Assert-KhcRecoveryArchive $run
        $null=Assert-KhcRecycleV6ReceiptData $proof.delete_preview $Record.work_directory 'delete-preview'
        $null=Assert-KhcRecycleV6ReceiptData $proof.delete_result $Record.work_directory 'delete-result'
        foreach($pair in @(@('delete_preview','delete_preview_path'),@('delete_result','delete_result_path'))){
            $saved=Get-Content -LiteralPath (Assert-KhcPlainPath $Request.($pair[1])) -Raw | ConvertFrom-Json -AsHashtable
            if((ConvertTo-Json $saved -Depth 12 -Compress) -cne (ConvertTo-Json $proof[$pair[0]] -Depth 12 -Compress)){throw 'Completed recycle-v6 CLI receipt changed.'}
        }
        if((Get-KhcRecycleV6TextHash $proof.manifest_text) -cne $proof.manifest_sha256 -or (Get-KhcRecycleV6TextHash $proof.completion_text) -cne $proof.completion_sha256){throw 'Saved recycle-v6 metadata snapshot hash mismatch.'}
        $manifest=ConvertFrom-Json -InputObject $proof.manifest_text -AsHashtable
        $completion=ConvertFrom-Json -InputObject $proof.completion_text -AsHashtable
        $null=Assert-KhcRecycleV6MetadataData $manifest $completion $proof.delete_result $proof.manifest_sha256 $Record.work_directory $binding.metadata_root ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) ([Environment]::MachineName)
    }
    [pscustomobject]@{RunId=$RunId;State='completed-receipts-verified';Protocol='prunlet-recycle-v6';ReceiptCount=2;OperationId=$final.operation_id;Disposition='recycle-retained';ReclaimedBytes=0L;RetainedPayloadChargeBytes=$final.payload_bytes;ExternalMetadataChargeBytes=$final.metadata_bytes}
}

function Test-KhcStorageDeletePreview {
    param([Parameter(Mandatory)][string]$RunId)
    $run = Get-KhcStorageRun $RunId
    Assert-KhcMacNativeE2eCleanupSeal $run
    Assert-KhcMacReferenceCleanupSeal $run
    Assert-KhcMacCandidateE2eCleanupSeal $run
    if($run.Request.schema -eq 2){
        $null=Assert-KhcRecycleV6Installed
        $null=Get-KhcRecycleV6RunAnchor $run.StateRoot $RunId -Request
        if(-not $run.Request.requires_prunlet){return [pscustomobject]@{RunId=$RunId;State='no-prunlet-required';Protocol='prunlet-recycle-v6'}}
        $null=Assert-KhcRecoveryArchive $run
        Assert-KhcRecycleV6Tree $run $run.WorkDirectory
        $paths=@(Get-Content -LiteralPath $run.Request.paths_file -Raw | ConvertFrom-Json)
        if($paths.Count -ne 1 -or $paths[0] -cne $run.WorkDirectory){throw 'Recycle-v6 paths-file differs from exact work root.'}
        $receipt=Get-Content -LiteralPath (Assert-KhcPlainPath $run.Request.delete_preview_path) -Raw | ConvertFrom-Json -AsHashtable
        $null=Assert-KhcRecycleV6ReceiptData $receipt $run.WorkDirectory 'delete-preview'
        $null=Assert-KhcStorageBudget
        return [pscustomobject]@{RunId=$RunId;State='delete-preview-verified';Protocol='prunlet-recycle-v6';Items=1;WorkDirectory=$run.WorkDirectory;PathsFile=$run.Request.paths_file;ResultPath=$run.Request.delete_result_path}
    }
    if (-not $run.Request.requires_prunlet) { return [pscustomobject]@{RunId=$RunId;State='no-prunlet-required'} }
    $null = Assert-KhcRecoveryArchive $run
    $paths = @(Get-Content -LiteralPath $run.Request.paths_file -Raw | ConvertFrom-Json -ErrorAction Stop)
    if ($paths.Count -ne 1 -or [IO.Path]::GetFullPath([string]$paths[0]).TrimEnd([char[]]'\/') -cne $run.WorkDirectory) { throw 'Prunlet paths-fileがこのrunの単一作業先と一致しません。' }
    $receipt = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_preview_path -Stage 'delete-preview'
    if (Test-Path -LiteralPath $run.WorkDirectory) { $null = Assert-KhcStorageBudget -ReserveBytes ([long]$run.Request.expected_bytes + 1MB) }
    [pscustomobject]@{RunId=$RunId;State='delete-preview-verified';Items=@($receipt.items).Count;WorkDirectory=$run.WorkDirectory;PathsFile=$run.Request.paths_file;PreviewPath=$run.Request.delete_preview_path;ResultPath=$run.Request.delete_result_path}
}

function Test-KhcStorageCompletedReceipts {
    param([Parameter(Mandatory)][string]$RunId)
    if ($RunId -cnotmatch '^[0-9a-f]{32}$') { throw 'run IDは小文字32桁のGUIDに限定します。' }
    $location = Get-KhcStorageRunLocation $RunId
    if (-not $location.TaskRoot) { throw '完了runの読み取り検証は現行D: task runに限定します。' }
    $null=Get-KhcRecycleV6RunProtocol $location.StateRoot $RunId
    $directory = Assert-KhcPlainPath $location.Directory
    $recordPath = Assert-KhcPlainPath $location.RecordPath
    $requestPath = Assert-KhcPlainPath (Join-Path $directory 'cleanup-request.json')
    $completePath = Assert-KhcPlainPath (Join-Path $directory 'complete.json')
    if (-not (Test-Path -LiteralPath $requestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $completePath -PathType Leaf)) {
        throw '完了runのcleanup-request.json/complete.jsonがありません。'
    }
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $complete = Get-Content -LiteralPath $completePath -Raw | ConvertFrom-Json -ErrorAction Stop
    if($request.schema -eq 2){return Test-KhcRecycleV6Completed $location $RunId $record $request $complete}
    if ($record.run_id -cne $RunId -or $request.schema -ne 1 -or $request.run_id -cne $RunId -or
        $record.work_directory -cne $request.work_directory -or -not $request.requires_prunlet) {
        throw '完了runの記録と清掃要求が一致しないか、Prunlet清掃が必要なrunではありません。'
    }
    $work = Assert-KhcPlainPath ([string]$record.work_directory)
    if ([IO.Path]::GetDirectoryName($work) -ine $location.TaskRoot -and [IO.Path]::GetDirectoryName($work) -ine $location.TempRoot) {
        throw '完了run作業先が登録されたD: task rootまたは歴史Tempの直接子ではありません。'
    }
    if ($work -notmatch '(?i)\\run-[0-9a-f]{32}$' -or $work.Length -gt 200) { throw '完了run作業先がrun-GUIDの正規形式ではありません。' }
    $pathProperties = @('paths_file','delete_preview_path','delete_result_path','purge_preview_path','purge_result_path','recovery_manifest_path','recovery_archive_path')
    foreach ($property in $pathProperties) {
        $path = Assert-KhcPlainPath ([string]$request.$property)
        if (-not $path.StartsWith($directory + [IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
            throw "完了runの清掃receipt保存先がrun台帳外です: $property"
        }
    }
    $run = [pscustomobject]@{RunId=$RunId;Directory=$directory;StateRoot=$location.StateRoot;TaskRoot=$location.TaskRoot;TempRoot=$location.TempRoot;Record=$record;Request=$request;RequestPath=$requestPath;WorkDirectory=$work}
    $null = Assert-KhcRecoveryArchive $run
    $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $request.delete_preview_path -Stage 'delete-preview'
    $deleted = Assert-KhcPrunletItems -Run $run -ReceiptPath $request.delete_result_path -Stage 'delete-result'
    $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $request.purge_preview_path -Stage 'purge-preview' -OperationId $deleted.operationId
    $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $request.purge_result_path -Stage 'purge-result' -OperationId $deleted.operationId
    if (Test-Path -LiteralPath $work) { throw '完了runのPrunlet削除後も元の作業先が残っています。' }
    $ledger = $complete.Ledger
    if ($complete.State -cne 'complete' -or $complete.RunId -cne $RunId -or $complete.AfterBytes -ne 0 -or
        [long]$complete.BeforeBytes -ne [long]$request.expected_bytes -or
        [IO.Path]::GetFullPath([string]$complete.BackupPath) -cne [IO.Path]::GetFullPath([string]$request.recovery_archive_path) -or
        [IO.Path]::GetFullPath([string]$complete.ManifestPath) -cne [IO.Path]::GetFullPath([string]$request.recovery_manifest_path) -or
        [IO.Path]::GetFullPath([string]$complete.RequestPath) -cne $requestPath -or
        [string]$complete.OperationId -cne [string]$deleted.operationId -or
        $ledger.protocol -cne 'prunlet-cli-direct-cmd' -or [string]$ledger.operation_id -cne [string]$deleted.operationId -or
        [IO.Path]::GetFullPath([string]$ledger.delete_preview) -cne [IO.Path]::GetFullPath([string]$request.delete_preview_path) -or
        [IO.Path]::GetFullPath([string]$ledger.delete_result) -cne [IO.Path]::GetFullPath([string]$request.delete_result_path) -or
        [IO.Path]::GetFullPath([string]$ledger.purge_preview) -cne [IO.Path]::GetFullPath([string]$request.purge_preview_path) -or
        [IO.Path]::GetFullPath([string]$ledger.purge_result) -cne [IO.Path]::GetFullPath([string]$request.purge_result_path)) {
        throw '完了run recordと検証済みPrunlet receiptが一致しません。'
    }
    [pscustomobject]@{RunId=$RunId;State='completed-receipts-verified';ReceiptCount=4;OperationId=$deleted.operationId;CompletedUtc=$complete.CompletedUtc;BeforeBytes=[long]$complete.BeforeBytes;AfterBytes=[long]$complete.AfterBytes}
}

function Test-KhcStorageDeleteResult {
    param([Parameter(Mandatory)][string]$RunId)
    $run = Get-KhcStorageRun $RunId
    Assert-KhcMacNativeE2eCleanupSeal $run
    Assert-KhcMacReferenceCleanupSeal $run
    Assert-KhcMacCandidateE2eCleanupSeal $run
    if($run.Request.schema -eq 2){
        $proof=Get-KhcRecycleV6LiveProof $run
        return [pscustomobject]@{RunId=$RunId;State='delete-result-verified';Protocol='prunlet-recycle-v6';OperationId=$proof.operation_id;NextStage='Finalize';Disposition='recycle-retained';ReclaimedBytes=0L}
    }
    if (-not $run.Request.requires_prunlet) { return [pscustomobject]@{RunId=$RunId;State='no-prunlet-required';OperationId=$null} }
    $null = Assert-KhcRecoveryArchive $run
    $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_preview_path -Stage 'delete-preview'
    $receipt = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_result_path -Stage 'delete-result'
    if (Test-Path -LiteralPath $run.WorkDirectory) { throw 'Prunlet delete後も元の作業先が残っています。' }
    [pscustomobject]@{RunId=$RunId;State='delete-verified';OperationId=$receipt.operationId;ReceiptPath=$run.Request.delete_result_path;PurgePreviewPath=$run.Request.purge_preview_path;PurgeResultPath=$run.Request.purge_result_path}
}

function Test-KhcStoragePurgePreview {
    param([Parameter(Mandatory)][string]$RunId)
    $run = Get-KhcStorageRun $RunId
    if($run.Request.schema -eq 2){throw 'Recycle-v6 retains Bin payload; purge is prohibited. Use Finalize.'}
    if (-not $run.Request.requires_prunlet) { return [pscustomobject]@{RunId=$RunId;State='no-prunlet-required';OperationId=$null} }
    $null = Assert-KhcRecoveryArchive $run
    $null = Test-KhcStorageDeletePreview -RunId $RunId
    $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_preview_path -Stage 'delete-preview'
    $deleted = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_result_path -Stage 'delete-result'
    if (Test-Path -LiteralPath $run.WorkDirectory) { throw 'Prunlet delete後も元の作業先が残っています。' }
    $preview = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.purge_preview_path -Stage 'purge-preview' -OperationId $deleted.operationId
    [pscustomobject]@{RunId=$RunId;State='purge-preview-verified';OperationId=$deleted.operationId;Items=@($preview.items).Count;PurgeResultPath=$run.Request.purge_result_path;ApplyCommand="prunlet purge $($deleted.operationId) --apply"}
}

function Finalize-KhcStorageRun {
    param([Parameter(Mandatory)][string]$RunId)
    $run = Get-KhcStorageRun $RunId
    $state = Assert-KhcPlainPath $run.StateRoot
    $registrationLease = $null; $serialLock = $null; $cargoLock = $null
    try {
        $registrationLease = [Khc.Storage.FileMutexLease]::new($script:LifecycleMutexName,(Join-Path $state 'registration.lock'))
        $serialLock = [IO.File]::Open((Join-Path $state 'serial.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $cargoLock = [Khc.Storage.FileMutexLease]::new($script:CargoMutexName,(Join-Path $state 'cargo.lock'))
        $run = Get-KhcStorageRun $RunId
        Assert-KhcMacNativeE2eCleanupSeal $run
        Assert-KhcMacReferenceCleanupSeal $run
        Assert-KhcMacCandidateE2eCleanupSeal $run
        if($run.Request.schema -eq 2){return Complete-KhcRecycleV6Run $run}
        $archive = $null
        if ($run.Request.requires_prunlet) { $archive = Assert-KhcRecoveryArchive $run }
        $operationId = $null; $ledger = $null
        if ($run.Request.requires_prunlet) {
            $null = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_preview_path -Stage 'delete-preview'
            $deleted = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.delete_result_path -Stage 'delete-result'
            $preview = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.purge_preview_path -Stage 'purge-preview' -OperationId $deleted.operationId
            $purged = Assert-KhcPrunletItems -Run $run -ReceiptPath $run.Request.purge_result_path -Stage 'purge-result' -OperationId $deleted.operationId
            if (Test-Path -LiteralPath $run.WorkDirectory) { throw 'Prunlet delete後も元の作業先が残っています。' }
            $operationId = $deleted.operationId
            $ledger = [pscustomobject]@{delete_preview=$run.Request.delete_preview_path;delete_result=$run.Request.delete_result_path;purge_preview=$run.Request.purge_preview_path;purge_result=$run.Request.purge_result_path;operation_id=$operationId;protocol='prunlet-cli-direct-cmd'}
        } elseif (Test-Path -LiteralPath $run.WorkDirectory) { throw '清掃対象なしの記録に作業先が残っています。' }
        $null = Assert-KhcStorageBudget
        $result = [pscustomobject]@{RunId=$RunId;WorkDirectory=$run.WorkDirectory;BackupPath=$run.Request.recovery_archive_path;ManifestPath=$run.Request.recovery_manifest_path;RequestPath=$run.RequestPath;Ledger=$ledger;OperationId=$operationId;State='complete';BeforeBytes=[long]$run.Request.expected_bytes;AfterBytes=0L;CompletedUtc=[DateTime]::UtcNow.ToString('o')}
        Write-KhcNewJson (Join-Path $run.Directory 'complete.json') $result
        return $result
    } finally {
        if ($null -ne $cargoLock) { $cargoLock.Dispose() }
        if ($null -ne $serialLock) { $serialLock.Dispose() }
        if ($null -ne $registrationLease) { $registrationLease.Dispose() }
    }
}

Export-ModuleMember -Function Initialize-KhcRecycleV6TrustAnchor,Initialize-KhcMacRemoteReservation,Resolve-KhcMacNativeBuildStage,Register-KhcMacBuildAmendment,Confirm-KhcMacNativeE2eTerminal,Confirm-KhcMacReferenceTerminal

Export-ModuleMember -Function Assert-KhcSingleSealSpeedFrontierCampaign,New-KhcSingleSealSpeedFrontierClaim,Assert-KhcDryBeanMetadata,Assert-KhcDryBeanMetadataGate,Assert-KhcDryBeanHoldoutCampaign,Assert-KhcNictKcs1HoldoutCampaign,Assert-KhcNictMetadata,Assert-KhcNictHoldoutCampaign,Assert-KhcLivedoorMetadata,Assert-KhcLivedoorHoldoutCampaign,Get-KhcPortfolioInputProfile,Get-KhcPortfolioInputZipPath,Assert-KhcPortfolioInput,Assert-KhcAozoraCampaign,Assert-KhcCanterburyKcs1Campaign,Assert-KhcJmaHoldoutCampaign,Assert-KhcTokyoPopulationHoldoutCampaign,Get-KhcStorageTaskPaths,Initialize-KhcStorageTaskEnvironment,Get-KhcLegacyTempRoot,Assert-KhcStorageTaskWorkDirectory,Get-KhcTreeUsage,Get-KhcRunUsage,Get-KhcProductPipelineEntryBudget,Assert-KhcStorageBudget,New-KhcStorageRun,Assert-KhcStorageContext,Prepare-KhcStorageRun,Recover-KhcUnstartedStorageRun,Recover-KhcAbandonedStorageRun,Test-KhcStorageDeletePreview,Test-KhcStorageCompletedReceipts,Test-KhcStorageDeleteResult,Test-KhcStoragePurgePreview,Finalize-KhcStorageRun,Enter-KhcCargoLease
