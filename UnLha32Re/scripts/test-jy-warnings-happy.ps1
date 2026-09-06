[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TestProgram,
    [Parameter(Mandatory)][string]$RunnerPath,
    [Parameter(Mandatory)][string]$Oracle,
    [Parameter(Mandatory)][string]$Candidate,
    [Parameter(Mandatory)][string]$Archive,
    [Parameter(Mandatory)][string]$Workspace
)
. (Join-Path $PSScriptRoot 'jy-warning-test-helper.ps1')
$cases=@(
    # @happypath @category happy @severity high
    # @description 省略と有効な質問抑制指定 @expected 警告なしで検査が成功する
    @{Name='omitted';Switches=@();Warnings=@()}
    @{Name='bare';Switches=@('-jy');Warnings=@()}
    @{Name='combined-flags';Switches=@('-jycdkno');Warnings=@()}
    @{Name='single-digit-values';Switches=@('-jyc0d1');Warnings=@()}
    @{Name='repeated-sign-values';Switches=@('-jyd-','-jyd+');Warnings=@()}
    @{Name='uppercase-flags';Switches=@('-jyCDKNO');Warnings=@()}
)
Invoke-JyWarningCases @PSBoundParameters -Cases $cases -Category happy
