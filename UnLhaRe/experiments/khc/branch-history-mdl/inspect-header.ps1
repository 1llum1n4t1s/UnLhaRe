[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$output=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build/khc-branch-history-mdl-20261004'))
$reportPath=Join-Path $output 'report.json'
$headerPath=Join-Path $output 'model-header.bin'
if((Get-FileHash -LiteralPath $reportPath).Hash -cne 'BC40F13C20D14A35EB2996A44BCD781A900AC886A76E665BE8399E157AC201BE'){throw 'Report identity'}
$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json -Depth 32
$n=$report.screen
if($report.status -cne 'diagnostic-passed' -or $report.compile_calls -ne 1 -or $report.total_native_calls -ne 1){throw 'Report scope'}
$bytes=[IO.File]::ReadAllBytes($headerPath)
if((Get-FileHash -LiteralPath $headerPath).Hash -cne '94B4DB639FD61ECD1741FFCCF7140FB4CF835CEDEC24D6C4F2CF850CEB1FC96F' -or $bytes.Length -ne 7400 -or $bytes.Length -ne $n.header_bytes){throw 'Header identity'}
$script:position=0;$script:leaves=0;$script:splits=0;$script:frequencies=0;$script:minimum=32768
$script:limit=[long]$n.header_bits
function Read-Field([int]$width){
 if($width -lt 1 -or $width -gt 15 -or $script:position+$width -gt $script:limit){throw 'Truncated field'}
 [long]$value=0
 for($i=0;$i -lt $width;$i++){
  $byteIndex=[int][math]::Floor($script:position/8)
  $shift=7-($script:position%8)
  $value=($value -shl 1) -bor (($bytes[$byteIndex] -shr $shift) -band 1)
  $script:position++
 }
 return $value
}
function Read-Node([int]$prefix,[int]$depth){
 $tag=Read-Field 1
 if($tag -eq 1){
  if($depth -ge 5){throw 'Split beyond depth five'}
  $script:splits++
  for($child=0;$child -lt 4;$child++){Read-Node $prefix ($depth+1)}
 }else{
  $script:leaves++;[long]$sum=0
  for($child=0;$child -lt $prefix-1;$child++){
   $frequency=Read-Field 15
   if($frequency -lt 2){throw 'Illegal explicit support'}
   $sum+=$frequency;$script:frequencies++
   $script:minimum=[math]::Min($script:minimum,$frequency)
  }
  $last=32768-$sum
  if($last -lt 2){throw 'Illegal implicit support'}
  $script:minimum=[math]::Min($script:minimum,$last)
 }
}
$roots=0
for($class=0;$class -lt 6;$class++){
 for($prefix=2;$prefix -le 4;$prefix++){Read-Node $prefix 0;$roots++}
}
if($script:position -ne $script:limit -or $bytes.Length -ne [math]::Ceiling($script:limit/8)){throw 'Trailing bits or bytes'}
for($bit=$script:limit;$bit -lt $bytes.Length*8;$bit++){
 if(($bytes[[int][math]::Floor($bit/8)] -band (1 -shl (7-($bit%8)))) -ne 0){throw 'Nonzero padding'}
}
if($script:leaves -ne $n.selected_leaves -or $script:splits -ne $n.selected_splits -or $script:leaves -ne 18+3*$script:splits -or $script:position -ne $script:leaves+$script:splits+15*$script:frequencies){throw 'Structural counts differ'}
[pscustomobject]@{status='independent-header-verified';roots=$roots;bits=$script:position;bytes=$bytes.Length;leaves=$script:leaves;splits=$script:splits;explicit_frequency_fields=$script:frequencies;minimum_model_frequency=$script:minimum;native_calls=0;compile_calls=0;writes=0}|ConvertTo-Json
