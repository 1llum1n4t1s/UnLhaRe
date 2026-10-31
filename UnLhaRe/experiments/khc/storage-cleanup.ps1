# Prunletの削除・purge自体はこのscriptから起動しない。必ずcmd.exe/login=falseの直接tool callで行う。
# この入口は各CLI結果の検証と、最後の非削除finalizeだけを担当する。
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
    [Parameter(Mandatory)][ValidateSet('RecoverUnstarted','RecoverAbandoned','DeletePreview','DeleteResult','PurgePreview','Finalize')][string]$Stage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'storage-lifecycle.psm1') -Force -ErrorAction Stop

switch ($Stage) {
    'RecoverUnstarted' {
        $result = Recover-KhcUnstartedStorageRun -RunId $RunId
        break
    }
    'RecoverAbandoned' {
        $result = Recover-KhcAbandonedStorageRun -RunId $RunId
        break
    }
    'DeletePreview' {
        $result = Test-KhcStorageDeletePreview -RunId $RunId
        break
    }
    'DeleteResult' {
        $result = Test-KhcStorageDeleteResult -RunId $RunId
        if ($result.PSObject.Properties.Name -contains 'Protocol' -and $result.Protocol -ceq 'prunlet-recycle-v6') {
            $result | Add-Member -NotePropertyName NextCommand -NotePropertyValue "pwsh -NoProfile -File experiments/khc/storage-cleanup.ps1 -RunId $RunId -Stage Finalize"
        } elseif ($result.OperationId) { $result | Add-Member -NotePropertyName NextCommand -NotePropertyValue "prunlet purge $($result.OperationId)" }
        break
    }
    'PurgePreview' {
        $result = Test-KhcStoragePurgePreview -RunId $RunId
        break
    }
    'Finalize' {
        $result = Finalize-KhcStorageRun -RunId $RunId
        break
    }
}

$result | ConvertTo-Json -Depth 8 -Compress
