[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
function Need($a,$b,[string]$why){if($a -cne $b){throw $why}}
function Same($a,$b){($a|ConvertTo-Json -Compress -Depth 64) -ceq ($b|ConvertTo-Json -Compress -Depth 64)}
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-temporal-paid-root-20261004'
$reportPath=Join-Path $work 'report.json'
Need (Get-FileHash -LiteralPath $reportPath).Hash '1D87164EF4869B24BB5267914DE80ACC44E358D4C3D5D39E3CE42D278269C4B1' 'Report SHA'
$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 64 -DateKind String
Need $r.status 'failed' 'Frozen wrapper status';Need $r.error 'Trace' 'Known wrapper error'
Need $r.compile_calls 1 'Compile';Need $r.total_native_calls 1 'Native';Need $r.source_count 15 'Sources';Need @($r.imports).Count 14 'Edges';Need $r.source_bytes 95415 'Source bytes'
$runner=Join-Path $PSScriptRoot 'run-native.ps1'
Need (Get-FileHash -LiteralPath $runner).Hash '7EC90BDF1F909B08C05CBCD6C57294A0C2739A48958DA124BB752D92A8B6926F' 'Corrected runner SHA'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors);Need $errors.Count 0 'Runner AST'
foreach($name in @('Near','Validate-Screen','Validate-Paid')){
 $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need $defs.Count 1 'Validator definition'
 . ([scriptblock]::Create($defs[0].Extent.Text))
}
function Identity([string]$path){$p=[IO.Path]::GetFullPath($path);$i=Get-Item -LiteralPath $p -Force;if($i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Identity link'};[pscustomobject]@{path=$p;sha256=(Get-FileHash -LiteralPath $p).Hash;bytes=$i.Length;mtime_utc=$i.LastWriteTimeUtc.ToString('o')}}
$pairs=0;$restored=0
foreach($kind in @('sources','identities')){
 $a=@($r.($kind+'_before'));$b=@($r.($kind+'_after'));Need $a.Count $b.Count 'Pair count'
 for($i=0;$i -lt $a.Count;$i++){
  Need (Same $a[$i] $b[$i]) $true 'Frozen before/after'
  if($a[$i].path -ieq $runner){
   $s=[IO.File]::ReadAllText($runner)
   $fixed=" Need `$n.E2E.frozen_temporal.same_process_recovery `$true 'Recovery';Need `$n.E2E.frozen_temporal.full_event_trace_saved `$false 'Trace'"
   $original=" Need `$n.E2E.same_process_recovery `$true 'Recovery';Need `$n.E2E.full_event_trace_saved `$false 'Trace'"
   Need ([regex]::Matches($s,[regex]::Escape($fixed))).Count 1 'Validator restoration site'
   $s=$s.Replace($fixed,$original)
   Need ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($s)))) $a[$i].sha256 'Original runner raw restoration'
   $restored++
  }else{Need (Same $a[$i] (Identity $a[$i].path)) $true 'Live identity'}
  $pairs++
 }
}
Need $restored 1 'Only intentional changed pin'
Need $r.executable_after $null 'Wrapper stopped before EXE after field';Need (Same $r.executable_before (Identity $r.executable_before.path)) $true 'EXE before/live';$pairs++
Need $r.executable_before.sha256 '1C8FE42F9DB14CBA6B5713BF122A170109B5C810C7732D1E3D0C68B9C3D053FD' 'EXE SHA'
Need @($r.children).Count 3 'Children';foreach($c in $r.children){Need $c.exit_code 0 'Child exit';Need $c.stderr '' 'Child stderr';Need $c.failure $null 'Child bound'}
$raw=$r.children[2].stdout|ConvertFrom-Json -Depth 64 -DateKind String;Need (Same $raw $r.screen) $true 'Native raw/screen equality'
$priorPath=Join-Path $project 'build/khc-temporal-node-information-heap-20261004/report.json'
$prior=Get-Content -Raw -LiteralPath $priorPath|ConvertFrom-Json -Depth 64 -DateKind String
$old=Get-Content -Raw -LiteralPath (Join-Path $project 'build/khc-node-history-information-20261004/report.json')|ConvertFrom-Json -Depth 64 -DateKind String
Validate-Screen $raw $old;Validate-Paid $raw $prior
$files=@(Get-ChildItem -LiteralPath $work -Force);Need $files.Count 2 'Output count';if(@($files|Where-Object {$_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'Output shape'}
Need @(Get-Process|Where-Object Path -eq $r.executable_before.path).Count 0 'Owned EXE processes'
$disk=& (Join-Path $PSScriptRoot '../disk-budget.ps1') -WorkDirectory $work -MaxRunMiB 8
[pscustomobject]@{status='readonly-passed';identity_pairs=$pairs;intentional_runner_restoration_sites=$restored;raw_native_records=1;paid_screen_bytes=$raw.paid_screen_bytes;paid_header_bytes=$raw.paid_header_bytes;paid_size_condition_passed=$raw.paid_size_condition_passed;additional_compile_calls=0;additional_native_calls=0;disk=$disk}|ConvertTo-Json -Depth 5
