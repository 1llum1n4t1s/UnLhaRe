# 段階診断JSONの正確な整数・連続時系列・範囲を検査する共有入口。
function Get-ValidatedStage([object]$Json,[string]$Operation,[double]$WallMs=0){
    if($Json.operation -cne $Operation){throw 'Stage operation mismatch.'}
    $result=[ordered]@{}
    foreach($name in @('stage_bwt_ns','stage_payload_ns','stage_seal_ns','stage_total_ns')){
        $property=$Json.PSObject.Properties[$name]
        if($null -eq $property -or $null -eq $property.Value){throw 'Missing stage field.'}
        $value=$property.Value
        if($value -isnot [long] -and $value -isnot [int] -and $value -isnot [uint64]){throw 'Stage field must be an exact JSON integer.'}
        if($value -lt 0 -or [Numerics.BigInteger]$value -gt 120000000000){throw 'Stage field outside process timeout bound.'}
        $result[$name]=[uint64]$value
    }
    $sum=$result.stage_bwt_ns+$result.stage_payload_ns+$result.stage_seal_ns
    if($sum -ne $result.stage_total_ns){throw 'Stage sum differs from total.'}
    if($Operation -ceq 'decode'){
        if($sum -ne 0){throw 'Decode unexpectedly reports encode stages.'}
    }elseif($Operation -cne 'encode'){throw 'Unknown stage operation.'}
    if($WallMs -gt 0 -and $result.stage_total_ns/1000000.0 -gt $WallMs){throw 'Internal stage exceeds full CLI wall time.'}
    [pscustomobject]$result
}
