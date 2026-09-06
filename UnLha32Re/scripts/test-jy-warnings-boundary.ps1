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
    # @adversarial @category boundary @severity high
    # @description 値を受け取るフラグなしの数字 @expected 最初の数字を警告する
    @{Name='immediate-digit';Switches=@('-jy1');Warnings=@('-jy1')}
    # @description 最初の不正文字の後に数字が続く @expected 最初の文字だけを警告する
    @{Name='digit-tail';Switches=@('-jy10');Warnings=@('-jy1')}
    # @description 有効フラグの後に数字が2文字続く @expected 1文字だけ消費する
    @{Name='digit-one-consumed';Switches=@('-jyc10');Warnings=@('-jy0')}
    # @description 有効フラグの後に符号と数字が続く @expected 符号だけ消費する
    @{Name='sign-one-consumed';Switches=@('-jyd-1');Warnings=@('-jy1')}
    # @description 不正文字が連続する @expected 最初の不正文字で警告走査を終える
    @{Name='invalid-first-stop';Switches=@('-jyxy');Warnings=@('-jyx')}
    # @description 有効フラグと不正文字が大文字 @expected 不正文字の大小文字を保持する
    @{Name='case-preserved';Switches=@('-jyD0X');Warnings=@('-jyX')}
    # @description 資料記載の b が現物で不正 @expected 原版現物の警告を保持する
    @{Name='legacy-b-invalid';Switches=@('-jybcdkno');Warnings=@('-jyb')}
)
Invoke-JyWarningCases @PSBoundParameters -Cases $cases -Category boundary
