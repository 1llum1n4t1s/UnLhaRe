[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[A-F0-9]{64}$')][string]$ExpectedReportSha)
$ErrorActionPreference='Stop'
$output=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build/khc-class-selective-static-mdl-20261004'))
$reportPath=Join-Path $output 'report.json';$headerPath=Join-Path $output 'model-bundle.bin'
foreach($path in @($reportPath,$headerPath)){$f=Get-Item -LiteralPath $path;if($f.PSIsContainer -or ($f.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Regular file required'}}
if((Get-FileHash -LiteralPath $reportPath).Hash -cne $ExpectedReportSha -or (Get-Item -LiteralPath $reportPath).Length -gt 262144){throw 'Report identity or extent'}
$r=Get-Content -Raw -LiteralPath $reportPath|ConvertFrom-Json -Depth 64 -DateKind String;$n=$r.screen
if($r.status -cne 'diagnostic-passed' -or $r.compile_calls -ne 1 -or $r.total_native_calls -ne 1){throw 'Diagnostic execution scope'}
if((Get-Item -LiteralPath $headerPath).Length -gt 5242880 -or (Get-FileHash -LiteralPath $headerPath).Hash -cne $r.header_identity.sha256){throw 'Bundle identity or bound'}
$bytes=[IO.File]::ReadAllBytes($headerPath);$offset=0L;$models=0;$roots=0;$sumBits=0L;$sumPadding=0L
$script:leaves=0L;$script:splits=0L;$script:fields=0L;$script:minimum=32768L
function Read-Field([int]$width){
 if($width -lt 1 -or $width -gt 15 -or $script:position+$width -gt $script:limit){throw 'Truncated model field'}
 [long]$value=0
 for($i=0;$i -lt $width;$i++){$index=$script:payloadOffset+[long][math]::Floor($script:position/8);$value=($value -shl 1) -bor (($bytes[$index] -shr (7-($script:position%8))) -band 1);$script:position++}
 return $value
}
function Read-Node([int]$prefix,[int]$depth){
 $tag=Read-Field 1
 if($tag -eq 1){if($depth -ge 5){throw 'Split beyond depth five'};$script:splits++;for($j=0;$j -lt 4;$j++){Read-Node $prefix ($depth+1)}}
 else{$script:leaves++;$sum=0L;for($j=0;$j -lt $prefix-1;$j++){$frequency=Read-Field 15;if($frequency -lt 2){throw 'Explicit frequency minimum'};$sum+=$frequency;$script:fields++;$script:minimum=[math]::Min($script:minimum,$frequency)};$last=32768-$sum;if($last -lt 2){throw 'Implicit frequency minimum or sum'};$script:minimum=[math]::Min($script:minimum,$last)}
}
for($model=0;$model -lt 278;$model++){
 if($offset+4 -gt $bytes.Length){throw 'Truncated LE bit length'}
 $bits=[uint64]$bytes[$offset] -bor ([uint64]$bytes[$offset+1] -shl 8) -bor ([uint64]$bytes[$offset+2] -shl 16) -bor ([uint64]$bytes[$offset+3] -shl 24);$offset+=4
 if($bits -eq 0 -or $bits -gt 142335){throw 'Model bit extent'};$extent=[long][math]::Ceiling($bits/8.0)
 if($offset+$extent -gt $bytes.Length){throw 'Truncated model byte extent'}
 $script:payloadOffset=$offset;$script:position=0L;$script:limit=[long]$bits
 for($prefix=2;$prefix -le 4;$prefix++){Read-Node $prefix 0;$roots++}
 if($script:position -ne $script:limit){throw 'Trailing model bits'}
 for($bit=[long]$bits;$bit -lt $extent*8;$bit++){if(($bytes[$offset+[long][math]::Floor($bit/8)] -band (1 -shl (7-($bit%8)))) -ne 0){throw 'Nonzero individual padding'}}
 $sumBits+=$bits;$sumPadding+=$extent*8-$bits;$offset+=$extent;$models++
}
if($offset -ne $bytes.Length -or $models -ne 278 -or $roots -ne 834 -or $script:leaves -ne $roots+3*$script:splits -or $sumBits -ne $script:leaves+$script:splits+15*$script:fields){throw 'Bundle terminal or structural accounting'}
if($bytes.Length -ne $n.bundle_bytes -or $sumBits -ne $n.sum_model_bits -or $script:leaves -ne $n.selected_leaves -or $script:splits -ne $n.selected_splits -or $n.model_count -ne 278 -or $bytes.Length*8 -ne $sumBits+$sumPadding+278*32){throw 'Native bundle accounting differs'}
[pscustomobject]@{status='independent-bundle-verified';models=$models;roots=$roots;bytes=$bytes.Length;sum_model_bits=$sumBits;individual_padding_bits=$sumPadding;length_field_bits=8896;leaves=$script:leaves;splits=$script:splits;explicit_frequency_fields=$script:fields;minimum_frequency=$script:minimum;native_calls=0;compile_calls=0;writes=0}|ConvertTo-Json
