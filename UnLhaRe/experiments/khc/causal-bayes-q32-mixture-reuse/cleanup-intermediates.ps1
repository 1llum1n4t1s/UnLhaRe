#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$base=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$retained=[IO.Path]::GetFullPath((Join-Path $base 'build/khc-q32-mixture-reuse-numeric-20261001-model-layout'))
$roots=@('build/khc-q32-mixture-reuse-numeric-20261001','build/khc-q32-mixture-reuse-numeric-20261001-model')|ForEach-Object {[IO.Path]::GetFullPath((Join-Path $base $_))}
$receipt=Join-Path $retained 'intermediate-cleanup.json'
$targets=[Collections.Generic.List[object]]::new()
$holds=[Collections.Generic.List[IO.FileStream]]::new()
$proofs=[Collections.Generic.List[object]]::new()
$failure=$null
function No-Reparse([string]$path){
    $p=[IO.Path]::GetFullPath($path)
    while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse path rejected'};$p=[IO.Path]::GetDirectoryName($p)}
}
function Hold([string]$path){No-Reparse $path;$holds.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
Add-Type -TypeDefinition @'
using System.IO;
public static class MixtureDuplicateBytes {
    public static bool Equal(string a, string b) {
        using(var x=File.OpenRead(a)) using(var y=File.OpenRead(b)) {
            if(x.Length!=y.Length) return false;
            int p; while((p=x.ReadByte())>=0) if(p!=y.ReadByte()) return false;
            return y.ReadByte()<0;
        }
    }
}
'@
No-Reparse $retained
if(Test-Path -LiteralPath $receipt){throw 'Cleanup receipt already exists'}
try{
    $currentReport=Join-Path $retained 'report.json';Hold $currentReport
    if((Get-FileHash -LiteralPath $currentReport).Hash -cne 'BFF074A286B71CA770059B4CD87B1037A982EC7B28A1BD48378F5E9914E45C72'){throw 'Current proof mismatch'}
    $proofs.Add([pscustomobject]@{path=$currentReport;sha256=(Get-FileHash -LiteralPath $currentReport).Hash})
    $current=Get-Content -LiteralPath $currentReport -Raw|ConvertFrom-Json
    if($current.status -cne 'verified'){throw 'Current proof not successful'}
    foreach($root in $roots){
        No-Reparse $root
        $ownership=Join-Path $root 'ownership.json';Hold $ownership
        if((Get-Content -LiteralPath $ownership -Raw|ConvertFrom-Json).owner -cne 'q32-mixture-reuse-numeric'){throw 'Intermediate ownership mismatch'}
        $reportPath=Join-Path $root 'report.json';Hold $reportPath
        $proofs.Add([pscustomobject]@{path=$reportPath;sha256=(Get-FileHash -LiteralPath $reportPath).Hash})
        $old=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
        if($old.status -cne 'verified'){throw 'Intermediate proof not successful'}
        $known=@($old.owned_paths)+@($old.identities|ForEach-Object {$_.path})
        foreach($file in (Get-ChildItem -LiteralPath $root -File -Force)){
            if($file.Extension -notin @('.input','.output','.expected')){continue}
            $path=[IO.Path]::GetFullPath($file.FullName)
            if(-not $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or $path -notin $known){throw 'Target outside owned intermediate files'}
            No-Reparse $path
            $saved=Join-Path $retained $file.Name
            if(-not (Test-Path -LiteralPath $saved -PathType Leaf)){continue}
            Hold $saved
            if($file.Length -ne (Get-Item -LiteralPath $saved).Length){continue}
            $hash=(Get-FileHash -LiteralPath $path).Hash
            if($hash -cne (Get-FileHash -LiteralPath $saved).Hash){continue}
            if(-not [MixtureDuplicateBytes]::Equal($path,$saved)){throw 'Full-byte duplicate comparison failed'}
            $targets.Add([pscustomobject]@{path=$path;bytes=$file.Length;sha256=$hash;retained_path=$saved;removed=$false})
        }
    }
    $users=@(Get-CimInstance Win32_Process|Where-Object {$_.ProcessId -ne $PID -and ($_.ExecutablePath -or $_.CommandLine)}|Where-Object {
        $process=$_
        @($roots|Where-Object {($process.ExecutablePath -and $process.ExecutablePath.StartsWith($_,[StringComparison]::OrdinalIgnoreCase)) -or ($process.CommandLine -and $process.CommandLine.IndexOf($_,[StringComparison]::OrdinalIgnoreCase) -ge 0)}).Count -gt 0
    })
    if($users.Count){throw 'Intermediate files may be in use'}
    if($targets.Count -ne 98 -or ($targets|Measure-Object bytes -Sum).Sum -ne 86575630){throw 'Duplicate inventory changed'}
    foreach($target in $targets){
        No-Reparse $target.path
        if((Get-Item -LiteralPath $target.path).Length -ne $target.bytes -or (Get-FileHash -LiteralPath $target.path).Hash -cne $target.sha256){throw 'Target changed before removal'}
        & {
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
} -Paths $target.path -Root (Join-Path $base 'build') | Out-Null
        $target.removed=-not (Test-Path -LiteralPath $target.path)
        if(-not $target.removed){throw 'Removed target remains'}
    }
    foreach($proof in $proofs){if((Get-FileHash -LiteralPath $proof.path).Hash -cne $proof.sha256){throw 'Proof changed during cleanup'}}
}catch{$failure=$_}
finally{
    $result=[ordered]@{status=$(if($null -eq $failure){'passed'}else{'failed'});error=$(if($failure){[string]$failure}else{$null});targets=$targets.ToArray();proofs=$proofs.ToArray();removed_files=@($targets|Where-Object removed).Count;removed_bytes=($targets|Where-Object removed|Measure-Object bytes -Sum).Sum;target_residual_count=@($targets|Where-Object {Test-Path -LiteralPath $_.path}).Count;retained_root=$retained;limitations=@('Intermediate reports retained as superseded historical records; they are not current source acceptance proofs.','EXE/PDB, source, final raw/oracle and all reports are retained.');completed_utc=[DateTime]::UtcNow.ToString('o')}
    foreach($hold in $holds){$hold.Dispose()}
    $stream=[IO.File]::Open($receipt,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($result|ConvertTo-Json -Depth 6));$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
if($failure){throw $failure}
[pscustomobject]$result|Select-Object status,removed_files,removed_bytes,target_residual_count|ConvertTo-Json -Compress
