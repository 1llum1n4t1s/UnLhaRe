#requires -Version 7.6
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$frozenSourceRoot=$PSScriptRoot
$taskOriginal=Join-Path $frozenSourceRoot 'compare.ps1'
$taskExpectedSha='785727BDEA01C90788707E352B215048D9934DA1848FFC5982BFBD4402EC69C2'
$taskProject=[IO.Path]::GetFullPath((Join-Path $frozenSourceRoot '../../..'))
$taskWork=Join-Path $taskProject 'build/khc-causal-scheduler-current-host-20261004'
$taskGuard=Join-Path $frozenSourceRoot '../disk-budget.ps1'
if((Get-FileHash -LiteralPath $taskOriginal).Hash -cne $taskExpectedSha){throw 'Frozen comparator identity'}
$taskHeld=[IO.File]::Open($taskOriginal,'Open','Read','Read')
try {
 $taskBody=[IO.File]::ReadAllText($taskOriginal)
 $taskOldWork='build/khc-causal-expert-scheduling-20261001/performance'
 if([regex]::Matches($taskBody,[regex]::Escape($taskOldWork)).Count -ne 1){throw 'Unique work replacement'}
 $taskBodyNew=$taskBody.Replace($taskOldWork,'build/khc-causal-scheduler-current-host-20261004').Replace('$PSScriptRoot','$frozenSourceRoot')
 $taskTokens=$null;$taskErrors=$null
 $taskAst=[Management.Automation.Language.Parser]::ParseInput($taskBody,[ref]$taskTokens,[ref]$taskErrors)
 if($taskErrors.Count){throw 'Frozen AST'}
 $taskAstNew=[Management.Automation.Language.Parser]::ParseInput($taskBodyNew,[ref]$taskTokens,[ref]$taskErrors)
 if($taskErrors.Count){throw 'Rebased AST'}
 $taskFunctions=@($taskAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
 $taskFunctionsNew=@($taskAstNew.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
 if($taskFunctions.Count -ne 8 -or $taskFunctionsNew.Count -ne 8){throw 'Eight frozen functions'}
 for($taskIndex=0;$taskIndex -lt 8;$taskIndex++){if($taskFunctions[$taskIndex].Extent.Text -cne $taskFunctionsNew[$taskIndex].Extent.Text){throw 'Measurement or verification function changed'}}
 if(Test-Path -LiteralPath $taskWork){throw 'Unused output required'}
 & $taskGuard -WorkDirectory $taskWork -MaxRunMiB 128
 $taskParameters=@{
  BinaryPath=Join-Path $taskProject 'build/khc-causal-expert-scheduling-20261001/codec-native.exe'
  ControlBinary=Join-Path $taskProject 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'
  SevenZipPath=Join-Path $taskProject 'build/khc-baseline-20260918/x64/7za.exe'
  GroupPath=Join-Path $taskProject 'build/khc-current-source-native-solid-20260923-group/all.group'
  WorkDirectory=$taskWork
 }
 . ([scriptblock]::Create($taskBodyNew)) @taskParameters
} finally {
 if((Get-FileHash -LiteralPath $taskOriginal).Hash -cne $taskExpectedSha){throw 'Frozen comparator changed'}
 $taskHeld.Dispose()
 & $taskGuard -WorkDirectory $taskWork -MaxRunMiB 128
}
