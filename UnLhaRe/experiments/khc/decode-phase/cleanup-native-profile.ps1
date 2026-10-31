#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$allowed=Join-Path $project 'build'
$target=[IO.Path]::GetFullPath((Join-Path $allowed 'khc-native-profile-profile-a-20261006/native_profile.pdb'))
$summaryPath=Join-Path $allowed 'khc-native-profile-cleanup-20261006.json'
if(Test-Path -LiteralPath $summaryPath){throw 'fresh cleanup summary required'}
if(-not $target.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'target outside build'}
if(@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(cargo|rustc|clippy-driver|link|native_profile|7za|unlhare-cli)\.exe$'}).Count){throw 'relevant process active'}
for($ancestor=$target;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse target/ancestor'}}
$item=Get-Item -LiteralPath $target -Force
if($item.PSIsContainer -or $item.Length -ne 1396736 -or $item.LastWriteTimeUtc.ToString('o') -cne '2026-10-05T18:59:31.9022550Z' -or (Get-FileHash -LiteralPath $target).Hash -ne 'BD30C05D4753979B6FEAD75A3745509E962C610DA3959C0789FEBC977F11A5E7'){throw 'owned PDB identity'}
foreach($pin in @(
    @{relative='khc-native-profile-profile-a-20261006/report.json';SHA256='D15CFC0E052B2B29603F8E674091C4E15CA4EAB0FF3678746B822B8342C130A8'},
    @{relative='khc-native-profile-profile-a-20261006/native_profile.exe';SHA256='6FDC294D80C05E608B7DCE217D44DCB3CAF55BC8873AC7E2153A1F5AA9127076'}
)){if((Get-FileHash -LiteralPath (Join-Path $allowed $pin.relative)).Hash -ne $pin.SHA256){throw 'retained evidence changed'}}
$lock=[IO.File]::Open($target,'Open','Read','None');$lock.Dispose()
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
} -Paths $target -Root $allowed -ReturnReceipt)
if($removed.Count -ne 1 -or $removed[0].State -ne 'complete' -or (Test-Path -LiteralPath $target)){throw 'cleanup incomplete'}
$data=[Text.Encoding]::UTF8.GetBytes((@{status='complete';removed_bytes=1396736;items=$removed;purpose='only this compilation PDB; EXE/report/archive/corpus preserved'}|ConvertTo-Json -Depth 5 -Compress))
if($data.Length -gt 65536){throw 'summary bound'}
$stream=[IO.File]::Open($summaryPath,'CreateNew','Write','None');try{$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
[ordered]@{status='complete';removed_bytes=1396736;summary=$summaryPath;SHA256=(Get-FileHash -LiteralPath $summaryPath).Hash}|ConvertTo-Json -Compress

