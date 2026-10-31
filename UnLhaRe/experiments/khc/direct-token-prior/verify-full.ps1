[CmdletBinding()]
param([Parameter(Mandatory)][string]$CodecSha,[Parameter(Mandatory)][string]$GroupPath)
$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $project 'build/khc-direct-token-prior-full-20261002'
$guard=Join-Path $PSScriptRoot '../disk-budget.ps1'
$compiler='C:/Users/IMT/.rustup/toolchains/1.98.1-x86_64-pc-windows-msvc/bin/rustc.exe'
$records=[Collections.Generic.List[object]]::new();$ledger=[Collections.Generic.List[object]]::new()
$locks=[Collections.Generic.List[IO.FileStream]]::new();$ids=[Collections.Generic.List[object]]::new()
$owned=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Identity([string]$p) { [pscustomobject]@{path=[IO.Path]::GetFullPath($p);bytes=(Get-Item -LiteralPath $p).Length;sha256=(Get-FileHash -LiteralPath $p).Hash} }
function TransientIdentity([string]$p) { $id=Identity $p;[pscustomobject]@{transient_path=$id.path;bytes=$id.bytes;sha256=$id.sha256;transient=$true} }
function LockIdentity([string]$p,[string]$hash='') {
    $p=[IO.Path]::GetFullPath($p);$locks.Add([IO.File]::Open($p,'Open','Read','Read'));$id=Identity $p
    if($hash -and $id.sha256 -ne $hash){throw "Identity mismatch: $p"};$ids.Add($id);return $id
}
function Child([string]$f,[string[]]$a) {
    $i=[Diagnostics.ProcessStartInfo]::new();$i.FileName=$f;$i.WorkingDirectory=$project;$i.UseShellExecute=$false;$i.CreateNoWindow=$true;$i.RedirectStandardOutput=$true;$i.RedirectStandardError=$true
    foreach($v in $a){$i.ArgumentList.Add($v)}
    $p=[Diagnostics.Process]::new();$p.StartInfo=$i;$w=[Diagnostics.Stopwatch]::StartNew()
    try {
        $null=$p.Start();$o=[Text.StringBuilder]::new();$e=[Text.StringBuilder]::new();$ob=[char[]]::new(4096);$eb=[char[]]::new(4096)
        $ot=$p.StandardOutput.ReadAsync($ob,0,4096);$et=$p.StandardError.ReadAsync($eb,0,4096);$od=$false;$ed=$false
        while(!$od -or !$ed -or !$p.HasExited){
            if($w.Elapsed.TotalSeconds -gt 120){throw 'Child timeout'}
            if(!$od -and $ot.IsCompleted){$n=$ot.GetAwaiter().GetResult();if(!$n){$od=$true}else{if($o.Length+$n -gt 65536){throw 'stdout cap'};$null=$o.Append($ob,0,$n);$ot=$p.StandardOutput.ReadAsync($ob,0,4096)}}
            if(!$ed -and $et.IsCompleted){$n=$et.GetAwaiter().GetResult();if(!$n){$ed=$true}else{if($e.Length+$n -gt 65536){throw 'stderr cap'};$null=$e.Append($eb,0,$n);$et=$p.StandardError.ReadAsync($eb,0,4096)}}
            [Threading.Thread]::Sleep(5)
        }
        $r=[pscustomobject]@{file=$f;argv=$a;cwd=$project;exit=$p.ExitCode;stdout=$o.ToString().Trim();stderr=$e.ToString().Trim();elapsed_ms_diagnostic=$w.Elapsed.TotalMilliseconds};$records.Add($r);return $r
    }finally{if($p.Id -and !$p.HasExited){$p.Kill($true);$p.WaitForExit()};$p.Dispose()}
}
function Success($r){if($r.exit -ne 0){throw "Child failed: $($r.stderr)"}}
function Own([string]$name){$p=Join-Path $work $name;$null=$owned.Add($p);return $p}
function CompareBytes([string]$a,[string]$b){
    if((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length){throw 'Length mismatch'}
    $x=[IO.File]::OpenRead($a);$y=[IO.File]::OpenRead($b);$ab=[byte[]]::new(65536);$bb=[byte[]]::new(65536);$total=0L
    try{while(($n=$x.Read($ab,0,$ab.Length)) -gt 0){$m=0;while($m -lt $n){$z=$y.Read($bb,$m,$n-$m);if(!$z){throw 'Short comparison'};$m+=$z};for($j=0;$j -lt $n;$j++){if($ab[$j] -ne $bb[$j]){throw "Byte mismatch at $($total+$j)"}};$total+=$n}}finally{$x.Dispose();$y.Dispose()}
    $ledger.Add([pscustomobject]@{comparison_a=$a;comparison_b=$b;compared_bytes=$total;equal=$true});return $total
}
function RemoveOwned([string]$p){
    $p=[IO.Path]::GetFullPath($p);if(!$owned.Contains($p) -or !$p.StartsWith($work+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup ownership mismatch'}
    $ancestor=$p;while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Cleanup reparse'}};$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
    if(Test-Path -LiteralPath $p){$id=Identity $p;& {
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
} -Paths $p -Root $work | Out-Null;if(Test-Path -LiteralPath $p){throw 'Cleanup failed'};$ledger.Add([pscustomobject]@{transient_path=$p;sha256=$id.sha256;bytes=$id.bytes;deleted=$true;children_stopped=$true;streams_closed=$true})}
}
function Refusal([string]$exe,[string[]]$a,[string]$pattern,[string]$out){
    $r=Child $exe $a;if($r.exit -eq 0 -or $r.stdout -or $r.stderr -notmatch $pattern){throw "Refusal mismatch ($pattern): $($r.stderr)"}
    if($out -and (Test-Path -LiteralPath $out)){throw 'Rejected operation published output'}
}
$report=[ordered]@{status='running';began_utc=[DateTime]::UtcNow.ToString('o');records=$records;identities_before=$ids;transient_ledger=$ledger;conditions=@();inputs=@();frames=@();grammar_cases=@();unverified=@('allocation failure injection','other native','formal performance','holdout/categories','product integration');capacity_estimate=@{normal_bytes=3MB;worst_bytes=50MB;cap_bytes=64MB;report_cap_bytes=512KB}}
$created=$false
try{
    $report.disk_before=& $guard -WorkDirectory $work -MaxRunMiB 64
    if(Test-Path -LiteralPath $work){throw 'Fresh full root already exists; no overwrite/retry'}
    $null=LockIdentity (Join-Path $PSScriptRoot 'codec.rs') $CodecSha
    $pins=@(
        @('../direct-token/multi_range.rs','CAEEA3C1CD6BCD26A45BFEDC4EAF1A825C4A6860E0958E2FEA1C9EAA403F8129'),
        @('cdf_model.rs','C046AF706803795762A6D2B3522A9D8747B08EDDA511DF0D576724F30BFD6E5C'),
        @('../DIRECT_TOKEN_FULL_CONTRACT_20261002.md','874EE1F8F60572BF8DC06EF07AE565017B59B005A7196ABFBFEA1571C5556571'),
        @('../causal-bayes-sais/bwt.rs','810662D4168EE8AC00C81A446D1F3B17056DBBEAFAD1724C43AB0C74A546132F'),
        @('prior_math.rs','138A83296052C562E35493D51943B744D450818D99FA2C09D5D769B08EB3B928'),
        @('../DIRECT_TOKEN_PRIOR_FULL_CONTRACT_20261002.md','9CD2534B8088DE669149C0F1EDEB4BCA58C4EB9C2E65DC7BC2BEB0975C54F225'),
        @('../DIRECT_TOKEN_PRIOR_CONTRACT_20261002.md','FB8373882F90882F8BAB50D3B9ECBC390181A2E769F3720DDDF001C0618752FB'),
        @('../rejected-binary-mix/packed_alphabet.rs','4934593F891296B72F91F8FB2CC27D26262514B3B153319A8EC1CDCA64B2734D'))
    foreach($pin in $pins){$null=LockIdentity (Join-Path $PSScriptRoot $pin[0]) $pin[1]}
    foreach($p in @($PSCommandPath,$guard,(Join-Path $PSScriptRoot 'frame_cases.rs'),(Join-Path $PSScriptRoot 'FULL_FAILURE_PLAN.md'),(Join-Path $PSScriptRoot '../DIRECT_TOKEN_CONTRACT_20261002.md'),(Join-Path $PSScriptRoot '../DIRECT_TOKEN_PRIMITIVE_RESULT_20261002.md'))){$null=LockIdentity $p}
    $null=LockIdentity (Join-Path $project 'build/khc-direct-token-range-20261002/report.json') '3C15411EEA53B6F9E401BC4A0C692629F9B53140E56963F362FE3DC0851B95AE'
    $null=LockIdentity (Join-Path $project 'build/khc-direct-token-prior-model-20261002/report.json') 'BD8090CE5C601F2BAC4C8E297E8C84FFD5D8FAE665B720ED1043580E676EFA2D'
    $report.compiler=LockIdentity $compiler 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC';$report.runtime=LockIdentity ((Get-Process -Id $PID).Path)
    $gid=LockIdentity $GroupPath '18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76';if($gid.bytes -ne 2811006){throw 'Fixed group length'}
    $oldExe=Join-Path $project 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/candidate.exe'
    $oldFrame=Join-Path $project 'build/khc-bwt-causal-bayes-q32-balanced-kt-20261001-schema-fix/full-e2e/empty.frame'
    $null=LockIdentity $oldExe '7E149D682025E4E03EDC32B6999A91C139991DBC834017EF9A15F88EA9290BF0';$null=LockIdentity $oldFrame '129D69D4A8D593AF7045D401116AC3AD69B9DF600C89AAAE282955A224B6AB56'
    $previousFrame=Join-Path $project 'build/khc-direct-token-full-20261002-bwt-pin-fix/empty.frame'
    $null=LockIdentity $previousFrame 'BA26EAB213CB1358E660A45BA78484DF0F008F3E14BEA73ED4B875A2906B64C2'
    $null=LockIdentity (Join-Path $project 'build/khc-direct-token-full-20261002-bwt-pin-fix/report.json') 'B2CBF04F6CAFA79DA72EB082A0C957DE468C9AC4945186D8DDABC1EB8AA91C4F'
    Success (Child $compiler @('--version'))
    $null=New-Item -ItemType Directory -Path $work;$created=$true
    foreach($opt in @(2,3)){foreach($overflow in @('yes','no')){
        $exe=Own "codec-o$opt-$overflow.exe";Success (Child $compiler @((Join-Path $PSScriptRoot 'codec.rs'),'--edition=2024','-C',"opt-level=$opt",'-C',"overflow-checks=$overflow",'-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$exe))
        $report.conditions += [pscustomobject]@{opt=$opt;overflow=$overflow;executable=(Identity $exe)}
    }}
    $forge=Own 'forge.exe';Success (Child $compiler @((Join-Path $PSScriptRoot 'frame_cases.rs'),'--edition=2024','-C','opt-level=2','-C','overflow-checks=yes','-C','panic=abort','-C','debuginfo=0','-C','link-arg=/DEBUG:NONE','-o',$forge))
    $report.forge=Identity $forge
    $inputNames=@('empty','single','all_bytes','zeros','alternating','random','all_group')
    $data=@([byte[]]@(),[byte[]]@(255),[byte[]](0..511|ForEach-Object{$_%256}),[byte[]]::new(131072),[byte[]](0..4095|ForEach-Object{$_%2}),[byte[]]::new(4096))
    $state=[uint32]0x13579bdf;for($j=0;$j -lt 4096;$j++){$state=$state -bxor ($state -shl 13);$state=$state -bxor ($state -shr 17);$state=$state -bxor ($state -shl 5);$data[5][$j]=[byte]($state -band 255)}
    for($k=0;$k -lt 7;$k++){
        $name=$inputNames[$k];$inp=$GroupPath;if($k -lt 6){$inp=Own "$name.input";[IO.File]::WriteAllBytes($inp,$data[$k])}
        $report.inputs += $(if($k -lt 6){TransientIdentity $inp}else{Identity $inp});$base=Own "$name.frame"
        for($c=0;$c -lt 4;$c++){
            $exe=$report.conditions[$c].executable.path;$frame=$base;if($c){$frame=Own "$name.condition.frame"}
            $r=Child $exe @('encode',$inp,$frame);Success $r;if($r.stderr){throw 'Encode stderr'};$s=$r.stdout|ConvertFrom-Json
            foreach($field in @('operation','input_bytes','output_bytes','runs','primary','alphabet_symbols','payload_bytes','plain_crc','payload_crc','rank_intervals','length_intervals','escape_bytes','run_storage_bytes')){if($null -eq $s.$field){throw "Missing stats $field"}}
            $actual=(Get-Item -LiteralPath $frame).Length;$n=(Get-Item -LiteralPath $inp).Length+1
            if($s.operation -ne 'encode' -or $s.input_bytes -ne $n-1 -or $s.output_bytes -ne $actual -or $s.payload_bytes -gt 8*$n+32 -or $actual -gt 8*$n+313 -or $s.run_storage_bytes -ne 12*$s.runs -or $s.rank_intervals -ne $s.runs -or $s.length_intervals -ne $s.runs){throw 'Declared bounds/stats mismatch'}
            $h=[byte[]]::new(36);$hs=[IO.File]::OpenRead($frame);try{if($hs.Read($h,0,36) -ne 36){throw 'Short actual header'}}finally{$hs.Dispose()}
            foreach($entry in @(@(8,($n-1)),@(12,$s.primary),@(16,$s.alphabet_symbols),@(20,$s.payload_bytes),@(24,$s.plain_crc),@(28,$s.payload_crc))){if([BitConverter]::ToUInt32($h,$entry[0]) -ne $entry[1]){throw 'Header/stats mismatch'}}
            $decoded=Own "$name.restore";$d=Child $exe @('decode',$frame,$decoded);Success $d;if($d.stderr){throw 'Decode stderr'};$ds=$d.stdout|ConvertFrom-Json
            if($ds.operation -ne 'decode' -or $ds.input_bytes -ne $actual -or $ds.output_bytes -ne $n-1){throw 'Decode actual stats mismatch'}
            foreach($field in @('runs','primary','alphabet_symbols','payload_bytes','plain_crc','payload_crc','rank_intervals','length_intervals','escape_bytes','run_storage_bytes')){if($ds.$field -ne $s.$field){throw 'Decode/encode stats mismatch'}}
            $null=CompareBytes $inp $decoded;RemoveOwned $decoded
            if($c){$null=CompareBytes $base $frame;RemoveOwned $frame}else{$report.frames += [pscustomobject]@{name=$name;identity=(Identity $base);stats=$s}}
            $null=& $guard -WorkDirectory $work -MaxRunMiB 64
        }
        if((Identity $inp).sha256 -ne $report.inputs[$k].sha256){throw 'Input changed'}
        if($k -lt 6){RemoveOwned $inp}
    }
    $exe=$report.conditions[0].executable.path
    $report.independent_length_boundaries=@()
    foreach($length in @(255,256,257)){
        $f=Own 'boundary.frame';$z=Own 'boundary.input';$out=Own 'boundary.restore'
        [IO.File]::WriteAllBytes($z,[byte[]]::new($length));Success (Child $forge @("zeros$length",$f));Success (Child $exe @('decode',$f,$out));$null=CompareBytes $z $out
        $report.independent_length_boundaries += [pscustomobject]@{length=$length;frame=(TransientIdentity $f);input=(TransientIdentity $z);compared_bytes=$length;transient=$true}
        RemoveOwned $out;RemoveOwned $z;RemoveOwned $f
    }
    $report.size_gate=($report.frames[6].identity.bytes -le 483599);$report.fixed_frame_bytes=$report.frames[6].identity.bytes
    $report.previous_frame_bytes=575791;$report.relative_change_bytes=$report.fixed_frame_bytes-575791;$report.size_gate_gap_bytes=$report.fixed_frame_bytes-483599
    $absent=Own 'refused.output'
    Refusal $exe @('decode',$previousFrame,$absent) 'bad frame magic/header' $absent
    Refusal $exe @('decode',$oldFrame,$absent) 'bad frame magic/header' $absent
    Refusal $oldExe @('decode',$report.frames[0].identity.path,$absent) 'bad frame magic/header' $absent
    foreach($op in @('encode','decode')){
        $source=if($op -eq 'encode'){$GroupPath}else{$report.frames[0].identity.path}
        $existing=Own 'existing.output';[IO.File]::WriteAllBytes($existing,[byte[]]@(17,29,43));$before=Identity $existing
        $r=Child $exe @($op,$source,$existing);if(!$r.exit -or $r.stdout -or $r.stderr -notmatch 'output create_new' -or (Identity $existing).sha256 -ne $before.sha256 -or [Convert]::ToHexString([IO.File]::ReadAllBytes($existing)) -ne '111D2B'){throw 'No clobber failure'};RemoveOwned $existing
        Refusal $exe @($op,(Join-Path $work 'missing.input'),$absent) '.' $absent
    }
    Refusal $exe @('invalid',$GroupPath,$absent) 'operation|usage|encode|decode' $absent
    Refusal $exe @() 'usage|arguments|encode|decode' $absent
    $patterns=@{early='active list exhausted before declared length';remaining='active list not empty at end';noncanonical='noncanonical length escape';unterminated='length escape exceeds four bytes';overflow='run length outside remaining bound';gap='range rounding gap';terminal='noncanonical range termination';trailing='trailing range bytes';sentinel='sentinel count';lf='LF cycle inconsistent';primary='invalid primary sentinel';magic='bad frame magic/header';header_crc='header CRC mismatch';payload_crc='payload CRC mismatch';plain_crc='plain length/CRC mismatch';field='frame fields outside bounds';payload_bound='payload exceeds transformed bound';padding='packed alphabet high bitmap padding nonzero';metadata_count='packed alphabet count mismatch';metadata_rank='packed alphabet rank outside factorial';short_header='bad frame magic/header';short_payload='packed header length outside bounds';prefix='invalid range prefix'}
    foreach($case in @('empty','early','remaining','noncanonical','unterminated','overflow','gap','terminal','trailing','sentinel','lf','primary','magic','header_crc','payload_crc','plain_crc','field','payload_bound','padding','metadata_count','metadata_rank','short_header','short_payload','prefix')){
        $f=Own 'forged.frame';Success (Child $forge @($case,$f))
        if($case -eq 'empty'){Success (Child $exe @('decode',$f,$absent));if((Get-Item -LiteralPath $absent).Length -ne 0){throw 'Forged empty nonempty'};RemoveOwned $absent}else{Refusal $exe @('decode',$f,$absent) $patterns[$case] $absent}
        $validCrc=$case -notin @('magic','header_crc','payload_crc','short_header','short_payload','payload_bound')
        $repaired=$case -in @('plain_crc','field','padding','metadata_count','metadata_rank','prefix')
        $report.grammar_cases += [pscustomobject]@{case=$case;identity=(TransientIdentity $f);expected=$patterns[$case];header_payload_crc_valid=$validCrc;crc_repaired=$repaired;transient=$true};RemoveOwned $f
    }
    $report.identities_after=@($ids|ForEach-Object{$now=Identity $_.path;if($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes){throw 'Identity changed'};$now})
    $stable=@($report.conditions|ForEach-Object{$_.executable})+@($report.forge)+@($report.frames|ForEach-Object{$_.identity})
    $report.artifacts_after=@($stable|ForEach-Object{$now=Identity $_.path;if($now.sha256 -ne $_.sha256 -or $now.bytes -ne $_.bytes){throw 'Artifact changed'};$now})
    $allowed=@($stable|ForEach-Object{$_.path})
    if(@(Get-ChildItem -LiteralPath $work -Force|Where-Object{$_.FullName -notin $allowed}).Count){throw 'Unexpected remaining artifact'}
    $report.nonmaximal_adjacent=@{executed=$false;static_invariant='unique active alphabet; head removed; rank0 removes symbol; rank>0 inserts behind another symbol, preventing adjacent equal runs'}
    $report.status='passed'
}catch{$report.status='failed';$report.error=$_.Exception.Message;throw}finally{
    if($created){$report.ended_utc=[DateTime]::UtcNow.ToString('o');$report.disk_before_report=& $guard -WorkDirectory $work -MaxRunMiB 64;$json=$report|ConvertTo-Json -Depth 12;if([Text.Encoding]::UTF8.GetByteCount($json) -gt 512KB){throw 'Report cap'};[IO.File]::WriteAllText((Join-Path $work 'report.json'),$json);$null=& $guard -WorkDirectory $work -MaxRunMiB 64}
    foreach($l in $locks){$l.Dispose()}
}
[pscustomobject]@{status=$report.status;conditions=$report.conditions.Count;frames=$report.frames.Count;grammar=$report.grammar_cases.Count;size_gate=$report.size_gate;report=(Identity (Join-Path $work 'report.json'))}|ConvertTo-Json -Depth 4
