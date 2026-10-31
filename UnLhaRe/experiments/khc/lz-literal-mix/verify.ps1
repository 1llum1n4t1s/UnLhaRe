#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-lz-literal-mix-20261001-dependency-repair'
$oldRoot=Join-Path $root 'build/khc-q32-balanced-kt-numeric-20261001-junction-validated'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$ids=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new()
$calls=[Collections.Generic.List[object]]::new()
$checks=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.List[string]]::new()
function No-Reparse([string]$Path){
    $p=[IO.Path]::GetFullPath($Path)
    while($p){if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw "Reparse rejected: $p"};$p=[IO.Path]::GetDirectoryName($p)}
}
function Identity([string]$Path){No-Reparse $Path;$item=Get-Item -LiteralPath $Path -Force;if($item -isnot [IO.FileInfo]){throw 'Regular file required'};[pscustomobject]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $Path).Hash}}
function Hold([string]$Path,[string]$Role,[string]$Expected=''){
    No-Reparse $Path;$locks.Add([IO.File]::Open($Path,'Open','Read','Read'))
    $id=Identity $Path;if($Expected -and $id.sha256 -cne $Expected){throw "Pin mismatch: $Path"}
    $ids.Add([pscustomobject]@{role=$Role;path=$id.path;before_bytes=$id.bytes;before_sha256=$id.sha256;after_bytes=$null;after_sha256=$null});$id
}
function Write-New([string]$Path,[byte[]]$Bytes){No-Reparse $Path;$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($Bytes);$f.Flush($true)}finally{$f.Dispose()};$owned.Add($Path)}
function Check([string]$Name){$checks.Add([pscustomobject]@{name=$Name;passed=$true})}
function Same-Bytes([string]$Left,[string]$Right){
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($Left)) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($Right))){throw "Full byte mismatch: $Left / $Right"}
}
function Invoke-Child([string]$Program,[string[]]$Argv,[int]$Expected=0){
    $row=[ordered]@{program=$Program;argv=$Argv;exit=$null;expected_exit=$Expected;timeout=$false;stdout='';stderr=''};$calls.Add($row)
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$started=$false;$outTask=$null;$errTask=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Child start failed'}
        $outTask=$p.StandardOutput.ReadToEndAsync();$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw '120s child timeout'}
        $row.stdout=$outTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$p.ExitCode
        if($row.exit -ne $Expected -or ($Expected -eq 0 -and $row.stderr) -or ($Expected -ne 0 -and $row.stdout)){throw 'Unexpected child exit/output'}
        [pscustomobject]$row
    }finally{
        if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
        if($null -ne $outTask){$row.stdout=$outTask.GetAwaiter().GetResult()};if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()};if($started){$row.exit=$p.ExitCode};$p.Dispose()
    }
}
function Refuse([string]$Exe,[string]$InputPath,[string]$OutputPath,[string]$Reason,[string]$Operation='decode'){
    $row=Invoke-Child $Exe @($Operation,$InputPath,$OutputPath) 1
    if($row.stderr -notmatch $Reason -or (Test-Path -LiteralPath $OutputPath)){throw "Refusal/publication mismatch: $Reason"}
    Check "refusal-$([IO.Path]::GetFileNameWithoutExtension($InputPath))-$([IO.Path]::GetFileName($Exe))"
}
function Invoke-Binary([string]$Program,[string[]]$Argv,[string]$OutputPath){
    $row=[ordered]@{program=$Program;argv=$Argv;exit=$null;expected_exit=0;timeout=$false;stdout='binary retained in output';stderr='';binary_stdout_bytes=$null};$calls.Add($row)
    $info=[Diagnostics.ProcessStartInfo]::new($Program);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.WorkingDirectory=$work
    foreach($arg in $Argv){$info.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;$stream=[IO.MemoryStream]::new();$started=$false;$copyTask=$null;$errTask=$null
    try{
        $started=$p.Start();if(-not $started){throw 'Binary child start failed'}
        $copyTask=$p.StandardOutput.BaseStream.CopyToAsync($stream);$errTask=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(120000)){$row.timeout=$true;throw '120s binary child timeout'}
        $copyTask.GetAwaiter().GetResult();$row.stderr=$errTask.GetAwaiter().GetResult();$row.exit=$p.ExitCode
        if($row.exit -ne 0 -or $row.stderr){throw 'Binary child failed'}
        $row.binary_stdout_bytes=$stream.Length;Write-New $OutputPath $stream.ToArray()
    }finally{
        if($started -and -not $p.HasExited){$p.Kill($true);$p.WaitForExit()}
        if($null -ne $copyTask){$copyTask.GetAwaiter().GetResult()};if($null -ne $errTask){$row.stderr=$errTask.GetAwaiter().GetResult()}
        if($started){$row.exit=$p.ExitCode};$p.Dispose();$stream.Dispose()
    }
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned work root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;model_history=$null;size_result=$null;inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Frozen independent BigInteger oracle is reused; this is not a new independent-author audit.','Model histories are finite correctness evidence, not performance evidence.','Forced portable on Windows x64 is not ARM64/macOS native verification.','Only isolated Lazy LZ + Range is supported; no product integration, speed adoption or general 7-Zip victory.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"literal-mix","retain":"reproducible CLI Model E2E evidence"}'))
try{
    $pins=@{
        'experiments/khc/bt.rs'='986FEE875B7E12A4B0CB83223E4787BD4AD57153306EB72FD008F64FA319EA18'
        'experiments/khc/context.rs'='8C46543A3EF4AB550A4D63B67FE179650C51F039D76E15E0EE6C9A10AE6B95D4'
        'experiments/khc/frontier_dp.rs'='A5F901E64C74D2ED5E06685AD853D9E14A20A43CDBD5BD51259C23777269F512'
        'experiments/khc/hybrid.rs'='4E9B539F5B8DF6C8DC373DD59A801055AB70F94FFD6216104846DE62E8B6506A'
        'experiments/khc/prices.rs'='8AA6FA66C13BF11A9D0792E35D67A16D541AB28FE646C2B187A5B968437F66C1'
        'experiments/khc/profile.rs'='3F701BE4C8068C995CC2277347CC5D8B4B8168768ED98A322CA120FE334DC680'
        'experiments/khc/range.rs'='1BD47734E6224C1D4819F57D94B4B546A2279793E1092F43B69F58CE3AD4667C'
        'experiments/khc/rans.rs'='514808347699DDAAFE8530435F3A262B465359BA4D8D1D76E01B8770516630B0'
        'experiments/khc/rep_frontier_dp.rs'='41BB1D87D4F6D1D3A9E98D131D83862C7FDE3B5741B3259F8E3BEB6D80A8E3A0'
        'experiments/khc/row.rs'='F0F422880F982FE7B2AFA6E4A4C9F06BC5E8F4B17260F46041C1883EBBCFD80C'
        'experiments/khc/suffix_probe.rs'='9D728B3A6CE3DD067442E8C0A0AFF1112FD7E4A2D94A4A8E510041DAEE46B382'
        'experiments/khc/reference_lz.rs'='6EDDBC7CEA31A3376BF17998D2D40233DBC082BAC73565407101A2C828EF399F'
        'experiments/khc/lz.rs'='43B334AEFD6E8585C2181E025F329CFDF3ED40F3B0DDBBC5789A94275E9EBC73'
        'experiments/khc/mod.rs'='3E37BD51E1CCD6CEC7BF5585F459BB3290803CB12E4F740763F30BB36777A8A3'
        'experiments/khc/lz-literal-mix/lz.rs'='EB99F33DC62F19171170537F6A2A4F279826E429B11240C3370167CD478FBF94'
        'experiments/khc/lz-literal-mix/mod.rs'='9F3D4272B7F7015D719870B46A46B41C1E01563F04FDDC7B0159CBF71AE8B6ED'
        'experiments/khc/lz-literal-mix/codec.rs'='C94E6DCC2F2E5948F0F07250B37DA5F156A0F13765827AAF023B46A9A19E0DA1'
        'experiments/khc/LZ_LITERAL_MIX_BUILD_REPAIR_20261001.md'='43DAB23C09AD240B6947F4BDF54EF7E9029D060DAB53FFFD06361A76B528883D'
        'build/cargo/release/deps/libserde_json-d86bf3242d3e6bfb.rlib'='DFB3602F335ACED106949EE273E848EC7BF000B472114837DB0CBDD8B5C48A2F'
        'build/khc-lz-literal-mix-20261001/report.json'='BA8F6B7B6C5D1C3E8D1329E47250D899ACD47F1ADA2C8E43E4F1E79108E18D13'
        'experiments/khc/lz-literal-mix/correspondence.json'='5355C187BD1E9391DAAEFB610CC3FC5BB2BAEE2C18CCBB211A28B61CFAAC6FC2'
        'experiments/khc/LZ_LITERAL_MIX_CONTRACT_20261001.md'='DEAF8DE0584C565920F24967617A15B515F2E34DE223767A8A4F7CB806494E2F'
        'examples/khc_lab.rs'='B2DABE852E10BDEC5A587C05AEE57E68EDD71717590F9D4BE505C8DC587D2176'
        'Cargo.toml'='D6493E185DAF2C3A3031D3D9F6F9533493A77A4EE8631B51DEA60BF1DB46BCF8'
        'Cargo.lock'='0E1E33CC2AE1BF9BB2ABFC870F0A6A6E0D20A99536BBFA7D398FA99BC9F64865'
        'build/cargo/release/examples/khc_lab.exe'='6B5EC833E94BBD9074B4C3C5665C2446B3CC384221CE8156DBE5EB1C43999BE4'
        'build/cargo/release/deps/libcrc_fast-7333d3e293afe8c1.rlib'='25AD13D5829A73A60C2B877A556AD8B2C50CC9FC9969535AD7B4329DE8112D91'
        'build/cargo/release/deps/libthiserror-6233482eeb4a593d.rlib'='F6E5EE9E01FE2392EF29A03CD46056416250F62A3394CC371B39C3C9A7093F9D'
        'build/khc-current-source-native-solid-20260923-group/all.group'='18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76'
        'build/cargo/release/deps/thiserror_impl-8d1862a9b2d7406e.dll'='82DD1B131AE53D0182E60CFB3FE17E3A72DB38A571230E4D9346D98406F0D65D'
        'build/cargo/release/deps/thiserror_impl-c1556e6406f11da0.dll'='83C723591E4EEB9C7F5F4BB57338CDD6808AA4EA9907A7E0322B5F731D4EBE19'
        'build/cargo/release/deps/thiserror_impl-cbbc8f4cc22203d4.dll'='3086E479869C48F3F4F75B7CC13596671EC8D6842E9BABC31A349EF5EF3684B9'
    }
    foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-dependency-contract-or-input' $pin.Value}
    $null=Hold $PSCommandPath 'verifier'
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'PowerShell Parser failure'}
    $changes=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'correspondence.json') -Raw|ConvertFrom-Json
    foreach($kind in @('lz','mod')){
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot "../$kind.rs")).Replace("`r`n","`n")
        $boundary="`n#[cfg(test)]`nmod tests {"
        if(($source.Split($boundary,[StringSplitOptions]::None)).Count -ne 2){throw 'Unique original test boundary required'}
        $expected=$source.Substring(0,$source.IndexOf($boundary))+"`n"
        foreach($change in $changes.$kind){
            if(([regex]::Matches($expected,[regex]::Escape($change.old))).Count -ne $change.count){throw "Source correspondence match count: $kind"}
            $expected=$expected.Replace([string]$change.old,[string]$change.new)
        }
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot "$kind.rs")) -cne $expected){throw "Full source correspondence failed: $kind"}
        Check "source-correspondence-$kind"
    }
    $null=Invoke-Child $compiler @('--version','--verbose')
    $formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe';$null=Hold $formatter 'formatter'
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot 'codec.rs'));Check 'CLI-fmt-clone-format-not-claimed'
    $deps=Join-Path $root 'build/cargo/release/deps'
    $crc=Join-Path $deps 'libcrc_fast-7333d3e293afe8c1.rlib';$thiserror=Join-Path $deps 'libthiserror-6233482eeb4a593d.rlib';$serdejson=Join-Path $deps 'libserde_json-d86bf3242d3e6bfb.rlib'
    $executables=@()
    foreach($mix in @($false,$true)){
        $variant=if($mix){'mixed'}else{'control'};$exe=Join-Path $work "$variant.exe"
        $argv=@('--edition=2024','-C','panic=abort','-C','opt-level=3','--extern',"crc_fast=$crc",'--extern',"thiserror=$thiserror",'--extern',"serde_json=$serdejson",'-L',"dependency=$deps")
        if($mix){$argv+=@('--cfg','khc_literal_mix')};$argv+=@((Join-Path $PSScriptRoot 'codec.rs'),'-o',$exe)
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-codec'
        $executables+=@{path=$exe;variant=$variant}
    }
    $fixtures=[ordered]@{empty=[byte[]]@();single=[byte[]]@(42);short=[byte[]]@(1,2,3);all_bytes=[byte[]](0..255);repeated=[byte[]]::new(8192);periodic=[byte[]]::new(16384);seeded_random=[byte[]]::new(8192)}
    [Array]::Fill($fixtures.repeated,[byte]65)
    for($i=0;$i -lt $fixtures.periodic.Length;$i++){$fixtures.periodic[$i]=[byte](@(0,1,2,255,3,3,7,8,0,13,27)[$i%11])}
    [Random]::new(20261001).NextBytes($fixtures.seeded_random)
    foreach($case in $fixtures.Keys){
        $fixture=Join-Path $work "$case.input";Write-New $fixture $fixtures[$case];$null=Hold $fixture 'codec-input'
        foreach($executable in $executables){
            $prefix="$case-$($executable.variant)";$frame=Join-Path $work "$prefix.frame";$restored=Join-Path $work "$prefix.restored"
            $row=Invoke-Child $executable.path @('encode',$fixture,$frame);$owned.Add($frame);$null=Hold $frame 'new-frame'
            $stats=$row.stdout.Trim()|ConvertFrom-Json
            if($stats.variant -cne $executable.variant -or $stats.input_bytes -ne $fixtures[$case].Length -or $stats.output_bytes -ne (Get-Item -LiteralPath $frame).Length -or $stats.additional_model_bytes -ne $(if($executable.variant -eq 'mixed'){524288}else{0})){throw 'Encode Stats mismatch'}
            $null=Invoke-Child $executable.path @('decode',$frame,$restored);$owned.Add($restored);$null=Hold $restored 'restored';Same-Bytes $restored $fixture
            Check "roundtrip-$prefix"
        }
    }
    $group=Join-Path $root 'build/khc-current-source-native-solid-20260923-group/all.group'
    if((Get-Item -LiteralPath $group).Length -ne 2811006){throw 'Fixed group length mismatch'}
    $reference=Join-Path $work 'fixed-original.frame'
    Invoke-Binary (Join-Path $root 'build/cargo/release/examples/khc_lab.exe') @('group-encode',$group,'--algorithm','lz','--dictionary-mib','64') $reference
    $null=Hold $reference 'original-CLI-frame'
    if((Get-Item -LiteralPath $reference).Length -ne 531353){throw 'Original Lazy LZ baseline not reproduced'}
    $frames=@{}
    foreach($executable in $executables){
        $variant=$executable.variant
        foreach($round in 0..1){
            $frame=Join-Path $work "fixed-$variant-$round.frame";$restored=Join-Path $work "fixed-$variant-$round.restored"
            $null=Invoke-Child $executable.path @('encode',$group,$frame);$owned.Add($frame);$null=Hold $frame 'fixed-frame'
            $null=Invoke-Child $executable.path @('decode',$frame,$restored);$owned.Add($restored);$null=Hold $restored 'fixed-restored';Same-Bytes $restored $group
            if($round -eq 0){$frames[$variant]=$frame}else{Same-Bytes $frame $frames[$variant]}
            if($variant -eq 'control'){Same-Bytes $frame $reference}
            Check "fixed-roundtrip-deterministic-$variant-$round"
        }
    }
    # formatを分離しており、異なるmodeによる復号は明示拒否する。
    Refuse $executables[0].path $frames.mixed (Join-Path $work 'mixed-by-control.output') 'rejected:'
    Refuse $executables[1].path $frames.control (Join-Path $work 'control-by-mixed.output') 'rejected:'
    $mut=[IO.File]::ReadAllBytes($frames.mixed);$mut[0]=$mut[0] -bxor 1;$bad=Join-Path $work 'bad-magic.frame';Write-New $bad $mut;$null=Hold $bad 'corrupt-input'
    Refuse $executables[1].path $bad (Join-Path $work 'bad-magic.output') 'rejected:'
    $mut=[IO.File]::ReadAllBytes($frames.mixed);$mut[$mut.Length-1]=$mut[$mut.Length-1] -bxor 1;$bad=Join-Path $work 'bad-payload.frame';Write-New $bad $mut;$null=Hold $bad 'corrupt-input'
    Refuse $executables[1].path $bad (Join-Path $work 'bad-payload.output') 'rejected:'
    foreach($executable in $executables){
        foreach($operation in @('encode','decode')){
            $fixture=if($operation -eq 'encode'){Join-Path $work 'single.input'}else{Join-Path $work "single-$($executable.variant).frame"}
            $sentinel=Join-Path $work "existing-$operation-$($executable.variant).output";Write-New $sentinel ([byte[]]@(31,41,59));$beforeId=Identity $sentinel
            $row=Invoke-Child $executable.path @($operation,$fixture,$sentinel) 1
            if($row.stderr -notmatch 'output create_new publication:' -or (Identity $sentinel).sha256 -cne $beforeId.sha256){throw 'No-clobber failure'}
            $null=Hold $sentinel 'sentinel';Check "no-clobber-$operation-$($executable.variant)"
            $out=Join-Path $work "cancel-$operation-$($executable.variant).output"
            $row=Invoke-Child $executable.path @("$operation-cancel",$fixture,$out) 1
            if($row.stderr -notmatch 'cancelled' -or (Test-Path -LiteralPath $out)){throw 'Cancellation published'}
            Check "cancel-$operation-$($executable.variant)"
        }
        $out=Join-Path $work "unknown-$($executable.variant).output"
        $row=Invoke-Child $executable.path @('unknown',(Join-Path $work 'single.input'),$out) 1
        if($row.stderr -notmatch 'unsupported operation' -or (Test-Path -LiteralPath $out)){throw 'Unknown operation accepted'}
        Check "unknown-$($executable.variant)"
        $out=Join-Path $work "missing-$($executable.variant).output"
        Refuse $executable.path (Join-Path $work 'missing.input') $out 'input open:'
        $out=Join-Path $work "directory-$($executable.variant).output"
        $row=Invoke-Child $executable.path @('encode',$work,$out) 1
        if($row.stderr -notmatch 'input open:|regular input' -or (Test-Path -LiteralPath $out)){throw 'Directory accepted'}
        Check "directory-$($executable.variant)"
    }
    $capInput=Join-Path $work 'over-cap.input'
    $capFile=[IO.File]::Open($capInput,'CreateNew','Write','None');try{$capFile.SetLength(64MB+41);$capFile.Flush($true)}finally{$capFile.Dispose()}
    $owned.Add($capInput);$null=Hold $capInput 'invalid-cap-input'
    foreach($executable in $executables){Refuse $executable.path $capInput (Join-Path $work "over-cap-$($executable.variant).output") 'regular input within cap' 'encode'}
    $target=Join-Path $work 'junction-target';$null=New-Item -ItemType Directory -Path $target;$owned.Add($target)
    $targetInput=Join-Path $target 'single.input';Write-New $targetInput ([byte[]]@(42));$null=Hold $targetInput 'junction-target-fixture'
    $junction=Join-Path $work 'junction'
    try{
        $null=New-Item -ItemType Junction -Path $junction -Target $target
        foreach($executable in $executables){
            Refuse $executable.path (Join-Path $junction 'single.input') (Join-Path $work "reparse-input-$($executable.variant).output") 'reparse rejected' 'encode'
            Refuse $executable.path (Join-Path $work 'single.input') (Join-Path $junction "reparse-output-$($executable.variant).output") 'reparse rejected' 'encode'
        }
    }finally{
        if(Test-Path -LiteralPath $junction){
            $link=Get-Item -LiteralPath $junction -Force
            if($link.LinkType -cne 'Junction' -or [IO.Path]::GetFullPath([string]$link.Target) -cne [IO.Path]::GetFullPath($target) -or -not $junction.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Owned junction target verification failed; not removed'}
            & {
    param([string[]]$Paths, [string]$Root, [string]$Ledger, [switch]$ReturnReceipt, [switch]$AllowLeafLink, [switch]$IgnoreMissing)
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Path]::IsPathFullyQualified($Root)) { throw 'Absolute cleanup root required' }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    if ($rootPath -eq [IO.Path]::GetPathRoot($Root).TrimEnd('\','/')) { throw 'Filesystem root cleanup prohibited' }
    if ($Paths.Count -eq 0) { throw 'Empty cleanup target set' }
    $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer) { throw 'Cleanup root must be a directory' }
    $validated = [Collections.Generic.List[string]]::new()
    $owned = @(foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathFullyQualified($path)) { throw 'Absolute cleanup target required' }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\','/')
        if (-not $full.StartsWith($rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Cleanup target outside root: $full" }
        foreach ($prior in $validated) {
            if ($full -eq $prior -or $full.StartsWith($prior + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $prior.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Duplicate or overlapping cleanup targets' }
        }
        $validated.Add($full)
        if (-not (Test-Path -LiteralPath $full) -and -not $IgnoreMissing) { throw "Cleanup target missing: $full" }
        for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
            if (Test-Path -LiteralPath $cursor) {
                $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not ($AllowLeafLink -and $cursor -eq $full)) { throw "Cleanup link refused: $cursor" }
            }
        }
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($full)
                while ($pending.Count) {
                    foreach ($child in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop) {
                        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cleanup child link refused: $($child.FullName)" }
                        if ($child.PSIsContainer) { $pending.Push($child.FullName) }
                    }
                }
            }
        }
        $full
    })
    if ($Ledger -and @( $owned | Where-Object { $Ledger -eq $_ -or $Ledger.StartsWith($_ + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Cleanup ledger is inside target' }
    $entries = @(foreach ($full in $owned) {
        if (Test-Path -LiteralPath $full) {
            $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $full -Force -ErrorAction Stop }
            else { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction Stop }
        }
        if (Test-Path -LiteralPath $full) { throw "Cleanup target remains: $full" }
        [pscustomobject]@{ original = @{Path=$full}; sourceAbsent=$true }
    })
    if ($Ledger) {
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($Ledger)) -Force | Out-Null
        [pscustomobject]@{state='complete'; items=$entries; protocol='direct-delete'} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Ledger -Encoding utf8
    }
    if ($ReturnReceipt) { foreach ($full in $owned) { [pscustomobject]@{Target=$full; State='complete'; LedgerPath=$Ledger} } }
} -Paths $junction -Root $work -AllowLeafLink | Out-Null
        }
    }
    $mixed=Identity $frames.mixed;$control=Identity $frames.control
    $report.size_result=[ordered]@{input=Identity $group;control=$control;mixed=$mixed;maximum_archive_bytes=483599;passed=($mixed.bytes -le 483599);delta_vs_control_bytes=($mixed.bytes-$control.bytes);timing_used=$false}
    $report.status=if($report.size_result.passed){'correctness_passed_size_gate_passed_not_timed'}else{'correctness_passed_size_no_go_not_timed'}

}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw 'Source/raw after identity changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}}
    foreach($held in $locks){$held.Dispose()}
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{path=$_.FullName;name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null};reparse=(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}})
    $report.owned_tmp_count=@($report.inventory|Where-Object {$_.name -like '*.tmp'}).Count;$report.owned_reparse_count=@($report.inventory|Where-Object {$_.reparse}).Count
    if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Owned tmp/reparse remains'}}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)))
}
if($null -ne $failure){throw $failure}
"Literal mixture E2E completed: $($checks.Count) checks; $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
