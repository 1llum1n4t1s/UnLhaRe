#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){throw 'STA required'}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$allowed=Join-Path $project 'build'
$ledger=Join-Path $allowed 'khc-forest-public-intermediates-cleanup-20261006.json'
if(Test-Path -LiteralPath $ledger){throw 'new ledger required; do not blindly rerun'}
if(@(Get-CimInstance Win32_Process|Where-Object {$_.Name -match '^(cargo|rustc|clippy-driver|link|public_io|khc_.*|unlhare-cli|compare)\.exe$'}).Count){throw 'relevant process active'}
$expected=@(
    @{attempt='b';files=3;bytes=94056;report='C0F7A9C9C84F436FA549084F07A019177EDD7A8996DCCEEFE6917A53BDBB3017'},
    @{attempt='c';files=2;bytes=2446336;report='F45CEDEE652AB9020ADFD29F041F8EF364C93EC1B0D70A9EB6EF81C54E1DA96B'},
    @{attempt='d';files=117;bytes=6301894;report='9BEA65EFB60933547F9770ADAF3E50ABA9D0B678A96FD404BD68DFF42E588438'}
)
$targets=[Collections.Generic.List[string]]::new()
foreach($item in $expected){
    $dir=[IO.Path]::GetFullPath((Join-Path $allowed ('khc-forest-public-io-public-'+$item.attempt+'-20261006')))
    if(-not $dir.StartsWith($allowed+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'scope escape'}
    for($ancestor=$dir;$ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)){if((Get-Item -LiteralPath $ancestor).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'reparse ancestor'}}
    if((Get-FileHash -LiteralPath (Join-Path $dir 'report.json')).Hash -ne $item.report){throw 'owned attempt report mismatch'}
    $entries=@(Get-ChildItem -LiteralPath $dir -Force -Recurse)
    if(@($entries|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'reparse descendant'}
    $files=@($entries|Where-Object {-not $_.PSIsContainer -and $_.Name -ne 'report.json'})
    if($files.Count -ne $item.files -or ($files|Measure-Object -Property Length -Sum).Sum -ne $item.bytes){throw 'owned generated extent changed'}
    foreach($file in $files){
        if($file.CreationTimeUtc -lt ([DateTimeOffset]'2026-10-05T16:44:00Z').UtcDateTime -or $file.LastWriteTimeUtc -gt ([DateTimeOffset]'2026-10-05T16:47:00Z').UtcDateTime){throw 'owned generation time mismatch'}
        $lock=[IO.File]::Open($file.FullName,'Open','Read','None');$lock.Dispose()
    }
    foreach($entry in @(Get-ChildItem -LiteralPath $dir -Force|Where-Object {$_.Name -ne 'report.json'})){
        if($entry.Name -notmatch '^public_io\.' -and $entry.Name -cne 'rustcIMMhlI'){throw 'unexpected mixed top-level item'}
        $targets.Add([IO.Path]::GetFullPath($entry.FullName))
    }
}
if($PSCmdlet.ShouldProcess(($targets -join ', '),'Delete only unused generated linker objects, symbols and unmeasured helpers; retain reports')){
    $result=& {
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
} -Paths $targets.ToArray() -Root $allowed -Ledger $ledger
    $record=Get-Content -LiteralPath $ledger -Raw|ConvertFrom-Json
    if($record.state -ne 'complete' -or $record.items.Count -ne $targets.Count -or @($record.items|Where-Object {-not $_.sourceAbsent}).Count){throw 'cleanup not complete'}
    foreach($item in $expected){if((Get-FileHash -LiteralPath (Join-Path $allowed ('khc-forest-public-io-public-'+$item.attempt+'-20261006/report.json'))).Hash -ne $item.report){throw 'retained report changed'}}
    $result|ConvertTo-Json -Depth 4
}
