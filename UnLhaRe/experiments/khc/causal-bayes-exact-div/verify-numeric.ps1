#requires -Version 7.2
param(
    [Parameter(Mandatory)][string]$BinaryPath,
    [Parameter(Mandatory)][string]$PortableBinary,
    [Parameter(Mandatory)][string]$WorkDirectory
)
# 実audit CLIの全binary結果を独立BigInteger算術へ照合。ライブラリunit testではない。
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$build=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../build'))+[IO.Path]::DirectorySeparatorChar
$work=[IO.Path]::GetFullPath($WorkDirectory)
$calls=[Collections.Generic.List[object]]::new(); $checks=[Collections.Generic.List[object]]::new()
$ids=[Collections.Generic.List[object]]::new(); $locks=[Collections.Generic.List[IO.FileStream]]::new()
$owned=[Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path){
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Reparse rejected.'}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Identity([string]$Path){
    No-Reparse $Path
    $item=Get-Item -LiteralPath $Path; if($item -isnot [IO.FileInfo]){throw 'Regular file required.'}
    [pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName).Hash}
}
function Lock([string]$Path){
    $id=Identity $Path
    $locks.Add([IO.File]::Open($id.path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
    $ids.Add([pscustomobject]@{path=$id.path;before_sha256=$id.sha256;after_sha256=$null})
    $id.path
}
function New-Bytes([string]$Path,[byte[]]$Bytes){
    No-Reparse $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($Bytes);$stream.Flush($true)}finally{$stream.Dispose()}
    $owned.Add($Path)
}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$ExpectedExit){
    $info=[Diagnostics.ProcessStartInfo]::new($Program)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.WorkingDirectory=$work;foreach($a in $Argv){$info.ArgumentList.Add($a)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info;$started=$false
    try{
        $started=$process.Start();if(-not $started){throw 'Child start failed.'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(60000)){throw 'Child timeout.'}
        $row=[pscustomobject]@{program=$Program;argv=$Argv;exit=$process.ExitCode;expected_exit=$ExpectedExit;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
        $calls.Add($row)
        if($row.exit -ne $ExpectedExit -or ($ExpectedExit -eq 0 -and $row.stderr) -or ($ExpectedExit -ne 0 -and $row.stdout)){throw 'Unexpected child result.'}
        $row
    }finally{if($started -and -not $process.HasExited){$process.Kill($true);$process.WaitForExit()};$process.Dispose()}
}
if(-not $work.StartsWith($build,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $work)){throw 'Fresh work below build required.'}
No-Reparse $work;$null=New-Item -ItemType Directory -Path $work
$failure=$null;$counts=$null;$caseCount=0
try{
    $native=Lock $BinaryPath;$portable=Lock $PortableBinary
    foreach($path in @($PSCommandPath,(Join-Path $PSScriptRoot 'exact_div.rs'),(Join-Path $PSScriptRoot 'audit_cli.rs'),(Join-Path $PSScriptRoot '../CAUSAL_BAYES_EXACT_DIV_CONTRACT_20260930.md'))){$null=Lock $path}
    $triples=[Collections.Generic.List[object]]::new()
    $q=[uint64]281474976710656;$max=[uint64]::MaxValue
    [uint64[]]$values=@(0,1,2,3,65535,4294967295,4294967296,($q-1),$q,($q+1),9223372036854775807,9223372036854775808,($max-1),$max)
    foreach($a in $values){foreach($b in $values){foreach($d in $values){$triples.Add([uint64[]]@($a,$b,$d))}}}
    foreach($power in 0..63){
        $d=[uint64][Numerics.BigInteger]::Pow(2,$power)
        foreach($a in $values){foreach($b in [uint64[]]@(1,3,$q,($max-1),$max)){$triples.Add([uint64[]]@($a,$b,$d))}}
    }
    $random=[Random]::new(20260930);$buffer=[byte[]]::new(8)
    for($i=0;$i -lt 8192;$i++){
        $random.NextBytes($buffer);$a=[BitConverter]::ToUInt64($buffer,0)
        $random.NextBytes($buffer);$b=[BitConverter]::ToUInt64($buffer,0)
        $random.NextBytes($buffer);$d=[BitConverter]::ToUInt64($buffer,0)
        $triples.Add([uint64[]]@($a,$b,$d))
        if($i -lt 4096){
            $hi=[uint64][Numerics.BigInteger]::Divide(([Numerics.BigInteger]$a*[Numerics.BigInteger]$b),[Numerics.BigInteger]::Pow(2,64))
            $triples.Add([uint64[]]@($a,$b,$hi))
            $triples.Add([uint64[]]@($a,$b,($hi+1)))
        }
    }
    $caseCount=$triples.Count;if($caseCount -gt 65536){throw 'Numeric case budget exceeded.'}
    $inputStream=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($inputStream)
    $expectedStream=[IO.MemoryStream]::new();$expectedWriter=[IO.BinaryWriter]::new($expectedStream)
    $counts=@{success=0;zero=0;overflow=0}
    try{
        $writer.Write([Text.Encoding]::ASCII.GetBytes("KHCDIV0`0"));$writer.Write([uint32]$caseCount);$writer.Write([uint32]0)
        $expectedWriter.Write([Text.Encoding]::ASCII.GetBytes("KHCDVO0`0"));$expectedWriter.Write([uint32]$caseCount);$expectedWriter.Write([uint32]0)
        foreach($t in $triples){
            foreach($value in $t){$writer.Write([uint64]$value)}
            $tag=0;$quotient=[uint64]0
            if($t[2] -eq 0){$tag=1;$counts.zero++}
            else{
                $big=[Numerics.BigInteger]::Divide(([Numerics.BigInteger]$t[0]*[Numerics.BigInteger]$t[1]),[Numerics.BigInteger]$t[2])
                if($big -gt [Numerics.BigInteger]$max){$tag=2;$counts.overflow++}else{$quotient=[uint64]$big;$counts.success++}
            }
            $expectedWriter.Write([uint64]$tag);$expectedWriter.Write($quotient)
        }
        $writer.Flush();$expectedWriter.Flush();$inputBytes=$inputStream.ToArray();$expectedBytes=$expectedStream.ToArray()
    }finally{$writer.Dispose();$expectedWriter.Dispose()}
    $input=Join-Path $work 'triples.input';New-Bytes $input $inputBytes
    $oracle=Join-Path $work 'bigint.expected';New-Bytes $oracle $expectedBytes
    $oracleId=Identity $oracle
    foreach($program in @(@($native,'native',$false),@($portable,'portable',$true))){
        foreach($round in 0..1){
            $output=Join-Path $work "$($program[1])-$round.output";$run=Invoke-Child $program[0] @($input,$output) 0;$owned.Add($output)
            $json=$run.stdout|ConvertFrom-Json
            if($json.operation -cne 'ratio-audit' -or $json.cases -ne $caseCount -or $json.success -ne $counts.success -or $json.zero -ne $counts.zero -or $json.overflow -ne $counts.overflow -or $json.portable -ne $program[2]){throw 'Numeric JSON counts/backend mismatch.'}
            $actual=Identity $output
            if($actual.bytes -ne $oracleId.bytes -or $actual.sha256 -cne $oracleId.sha256){throw 'Hardware/portable quotient differs from BigInteger.'}
            $checks.Add([pscustomobject]@{name="bigint-$($program[1])-$round";passed=$true;cases=$caseCount;output=$actual;oracle=$oracleId;json=$json})
        }
    }
    # count0も正準batchとして成功。異常はcodec入力側の拒否でtrapと区別する。
    $empty=[byte[]]$inputBytes[0..15];[BitConverter]::GetBytes([uint32]0).CopyTo($empty,8)
    $emptyPath=Join-Path $work 'empty.input';New-Bytes $emptyPath $empty
    $emptyOut=Join-Path $work 'empty.output';$emptyRun=Invoke-Child $native @($emptyPath,$emptyOut) 0;$owned.Add($emptyOut)
    $emptyJson=$emptyRun.stdout|ConvertFrom-Json
    if($emptyJson.cases -ne 0 -or $emptyJson.success -ne 0 -or $emptyJson.zero -ne 0 -or $emptyJson.overflow -ne 0 -or (Get-Item -LiteralPath $emptyOut).Length -ne 16){throw 'Empty batch mismatch.'}
    $checks.Add([pscustomobject]@{name='empty-batch';passed=$true;output=(Identity $emptyOut)})
    $bad=[byte[]]$empty.Clone();$bad[0]=0
    $flags=[byte[]]$empty.Clone();$flags[12]=1
    $over=[byte[]]$empty.Clone();[BitConverter]::GetBytes([uint32]65537).CopyTo($over,8)
    $short=[byte[]]$inputBytes[0..($inputBytes.Length-2)]
    foreach($fixture in @(@('magic',$bad),@('flags',$flags),@('count',$over),@('short',$short),@('trailing',[byte[]]($empty+[byte[]]@(0))))){
        $path=Join-Path $work "$($fixture[0]).input";New-Bytes $path $fixture[1];$absent=Join-Path $work "$($fixture[0]).rejected"
        $run=Invoke-Child $native @($path,$absent) 1
        if(Test-Path -LiteralPath $absent){throw 'Invalid batch published output.'}
        $checks.Add([pscustomobject]@{name="bad-$($fixture[0])";passed=$true;reason=$run.stderr})
    }
    $existing=Join-Path $work 'existing.output';New-Bytes $existing ([byte[]]@(31,41,59));$id=Identity $existing
    $run=Invoke-Child $native @($emptyPath,$existing) 1
    if((Identity $existing).sha256 -cne $id.sha256 -or $run.stderr -notmatch 'create_new'){throw 'No-clobber contract failed.'}
    $checks.Add([pscustomobject]@{name='no-clobber';passed=$true;output=$id})
    foreach($argv in @([string[]]@(),[string[]]@($emptyPath),[string[]]@((Join-Path $work 'missing'),(Join-Path $work 'missing.output')))){
        $run=Invoke-Child $native $argv 1
        if(Test-Path -LiteralPath (Join-Path $work 'missing.output')){throw 'Missing input published output.'}
        $checks.Add([pscustomobject]@{name='invalid-invocation';passed=$true;argv=$argv;reason=$run.stderr})
    }
}catch{$failure=$_}
finally{
    foreach($id in $ids){$id.after_sha256=(Get-FileHash -LiteralPath $id.path).Hash;if($id.before_sha256 -cne $id.after_sha256){$failure='Numeric source/input changed.'}}
    foreach($held in $locks){$held.Dispose()}
    $report=[ordered]@{status=$(if($null -eq $failure){'verified'}else{'failed'});error=$(if($null -ne $failure){[string]$failure}else{$null});cases=$caseCount;expected_counts=$counts;checks=$checks.ToArray();invocations=$calls.ToArray();identities=$ids.ToArray();owned_paths=$owned.ToArray();timing_used=$false;completed_utc=[DateTime]::UtcNow.ToString('o')}
    New-Bytes (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 12)))
}
if($null -ne $failure){throw $failure}
"Numeric CLI E2E PASS: $caseCount triples / $($checks.Count) checks / $($calls.Count) child invocations."
