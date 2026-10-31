#requires -Version 7.2
param([switch]$ProbeOnly)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$hostLoadObservations=[Collections.Generic.List[object]]::new()
function Assert-QuietHost([string]$Phase,[int]$Samples=1){
    if($Samples -lt 1 -or $Samples -gt 5){throw 'Host sampling count outside bounds.'}
    for($i=0;$i -lt $Samples;$i++){
        $values=@(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
        if($values.Count -ne 1){throw 'Host CPU total unavailable or ambiguous.'}
        $cpu=[double]$values[0].PercentProcessorTime
        if(-not [double]::IsFinite($cpu) -or $cpu -lt 0 -or $cpu -gt 100){throw 'Host CPU value invalid.'}
        $row=[pscustomobject]@{phase=$Phase;sample=$i;observed_utc=[DateTime]::UtcNow.ToString('o');total_processor_percent=$cpu;maximum_allowed_percent=15;passed=($cpu -le 15)}
        $hostLoadObservations.Add($row)
        Write-Host ($row|ConvertTo-Json -Compress)
        if(-not $row.passed){throw 'Host CPU busy; no ordinary performance adoption allowed.'}
        if($i+1 -lt $Samples){[Threading.Thread]::Sleep(1000)}
    }
}
if($ProbeOnly){Assert-QuietHost 'preflight' 5; 'Host quiet preflight PASS.'}
