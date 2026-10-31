$ErrorActionPreference='Stop'
$test='C:\Users\IMT\dev\UnLhaRe\UnLha32Re\artifacts\Release\CompatibilityTests.exe'
$oracle='C:\Users\IMT\dev\UnLhaRe\UnLha32Re\sample\ulh3300_extracted\UNLHA32.DLL'
$candidate='C:\Users\IMT\dev\UnLhaRe\UnLha32Re\artifacts\Release\UNLHA32RE.dll'
$base='C:\Users\IMT\dev\UnLhaRe\UnLha32Re\build\dictionary-array-debug-20260910e'
$log=Join-Path (Split-Path -Parent $base) 'dictionary-array-debug-20260910e.log'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$outLines=[Collections.Generic.List[string]]::new()
$methods=@()
foreach($producer in @(@{Name='original';Dll=$oracle},@{Name='candidate';Dll=$candidate})) {
  $root=Join-Path $base $producer.Name
  $output=@(& $test --registry '' --create-dictionary-fixture $producer.Dll $root '-jmm16 -e0' '49152' 'W' 'payload.bin')
  $outLines.Add("producer=$($producer.Name) count=$($output.Count)")
  foreach($row in $output){$outLines.Add("row=$row")}
  foreach($consumer in $oracle,$candidate){$null=@(& $test --verify-dictionary-fixture $consumer $root 'payload.bin')}
  $m=@($output | Where-Object { $_ -like 'create.method=*' })
  $outLines.Add("m-count=$($m.Count) m0=[$($m[0])] m1=[$($m[1])]")
  $methods += $m
}
$outLines.Add("methods-count=$($methods.Count) values=$($methods -join '|')")
[IO.File]::WriteAllLines($log,$outLines,[Text.UTF8Encoding]::new($false))
