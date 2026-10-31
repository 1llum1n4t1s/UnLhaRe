#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$allowed=Join-Path $project 'build'
$summaryPath=Join-Path $allowed 'khc-cdf-native-cleanup-20261006.json'
if(Test-Path -LiteralPath $summaryPath){throw 'new cleanup summary required; no blind rerun'}
if(@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(cargo|rustc|clippy-driver|link|cdf_compare|archive_restore|public_io|7za|khc_.*|unlhare-cli)\.exe$'}).Count){throw 'relevant process active'}
$owned=@(
    @{relative='khc-model-cost-cdf-a-20261006/cdf_compare.pdb';bytes=1413120L;utc='2026-10-05T18:27:41.4542594Z';directory=$false},
    @{relative='khc-native-restore-helper-restore-a-20261006/archive_restore.pdb';bytes=1372160L;utc='2026-10-05T18:38:51.3863341Z';directory=$false},
    @{relative='khc-native-archive-native-b-20261006/khc-restored';bytes=2810784L;utc='2026-10-05T18:37:04.0706432Z';directory=$true},
    @{relative='khc-native-archive-native-b-20261006/seven-restored';bytes=2810784L;utc='2026-10-05T18:37:07.5932844Z';directory=$true},
    @{relative='khc-native-archive-native-c-20261006/khc-restored';bytes=2810784L;utc='2026-10-05T18:39:25.0542835Z';directory=$true},
    @{relative='khc-native-archive-native-c-20261006/seven-restored';bytes=2810784L;utc='2026-10-05T18:39:26.1863724Z';directory=$true}
)
foreach($pin in @(
    @{relative='khc-model-cost-cdf-a-20261006/report.json';SHA256='2EF809566FFDE238A7C29C545DED670CFCF90E3B9D22DEFF1A953AAF52B7084C'},
    @{relative='khc-model-cost-cdf-reverse-a-20261006/report.json';SHA256='29DA0A833B30D7C40024B734FFBF538D3B200DE341DF795F1C3E5C5053269441'},
    @{relative='khc-native-archive-native-b-20261006/report.json';SHA256='D0E3201E9AD388FB6B3E78A266AD8D3F587FDFC0A8AAD8DECB5E5EF66B42240F'},
    @{relative='khc-native-archive-native-c-20261006/report.json';SHA256='18E70562A567D520B57C4CD7FDC11F5B67C502C218933E6E5B2419DFBCB83D3A'}
)){if((Get-FileHash -LiteralPath (Join-Path $allowed $pin.relative)).Hash -ne $pin.SHA256){throw 'evidence changed'}}
$manifest=Get-Content (Join-Path $project 'experiments/khc/CORPUS_MANIFEST.json') -Raw|ConvertFrom-Json
$entries=@(($manifest|Where-Object name -eq 'canterbury-development').files)
if($entries.Count -ne 11){throw 'fixed fixture coverage'}
$targets=@(foreach($item in $owned){
    $path=[IO.Path]::GetFullPath((Join-Path $allowed $item.relative))
    if(-not $path.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'scope escape'}
    for($ancestor=$path;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse'}}
    $actual=Get-Item -LiteralPath $path -Force
    if($actual.PSIsContainer -ne $item.directory -or $actual.LastWriteTimeUtc.ToString('o') -cne $item.utc){throw 'owned identity'}
    $files=if($item.directory){@(Get-ChildItem -LiteralPath $path -Recurse -Force)}else{@($actual)}
    if(@($files|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'mixed/reparse output'}
    if([long](($files|Measure-Object Length -Sum).Sum) -ne $item.bytes){throw 'owned extent'}
    if($item.directory){
        if($files.Count -ne 11){throw 'mixed restore directory'}
        foreach($entry in $entries){$file=Join-Path $path $entry.name;if((Get-Item -LiteralPath $file).Length -ne $entry.bytes -or (Get-FileHash -LiteralPath $file).Hash -ne $entry.sha256){throw 'restore no longer matches generated fixture'}}
    }
    foreach($file in $files){$lock=[IO.File]::Open($file.FullName,'Open','Read','None');$lock.Dispose()}
    $path
})
if($targets.Count -ne 6){throw 'exact cleanup set'}
$removed=@(& {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $targets -Root $allowed -ReturnReceipt)
if($removed.Count -ne 6 -or @($removed|Where-Object State -ne 'complete').Count -or @($targets|Where-Object {Test-Path -LiteralPath $_}).Count){throw 'cleanup incomplete'}
$data=[Text.Encoding]::UTF8.GetBytes((@{status='complete';removed_bytes=14028416;items=$removed;purpose='generated symbols and restored fixture copies only; archives/EXE/report/source retained'}|ConvertTo-Json -Depth 5 -Compress))
if($data.Length -gt 65536){throw 'summary bound'}
$stream=[IO.File]::Open($summaryPath,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
[ordered]@{status='complete';Count=$removed.Count;removed_bytes=14028416;summary=$summaryPath;SHA256=(Get-FileHash -LiteralPath $summaryPath).Hash}|ConvertTo-Json -Compress
