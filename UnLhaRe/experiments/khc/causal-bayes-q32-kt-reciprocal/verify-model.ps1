#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$work=Join-Path $root 'build/khc-q32-kt-reciprocal-model-20261001'
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
function Refuse([string]$Exe,[string]$InputPath,[string]$OutputPath,[string]$Reason){
    $row=Invoke-Child $Exe @($InputPath,$OutputPath) 1
    if($row.stderr -notmatch $Reason -or (Test-Path -LiteralPath $OutputPath)){throw "Refusal/publication mismatch: $Reason"}
    Check "refusal-$([IO.Path]::GetFileNameWithoutExtension($InputPath))-$([IO.Path]::GetFileName($Exe))"
}
No-Reparse $work
if(Test-Path -LiteralPath $work){throw 'New owned work root required; no automatic retry'}
$null=New-Item -ItemType Directory -Path $work
$failure=$null
$report=[ordered]@{status='failed';error=$null;started_utc=[DateTime]::UtcNow.ToString('o');timing_used=$false;compiler=$compiler;identities=$ids;invocations=$calls;checks=$checks;owned_paths=$owned;model_history=$null;inventory=@();owned_tmp_count=$null;owned_reparse_count=$null;limitations=@('Frozen independent BigInteger oracle is reused; this is not a new independent-author audit.','Model histories are finite correctness evidence, not performance evidence.','Forced portable on Windows x64 is not ARM64/macOS native verification.','No full codec/product integration or speed adoption is claimed.')}
Write-New (Join-Path $work 'ownership.json') ([Text.Encoding]::UTF8.GetBytes('{"owner":"kt-reciprocal-model","retain":"reproducible CLI Model E2E evidence"}'))
try{
    $pins=@{
        'experiments/khc/Q32_KT_RECIPROCAL_MODEL_CONTRACT_20261001.md'='FB2C4DAC2FF1CECD205F55C3900855D05665CC1CE30AF030A7D09AFEB08C46BC'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/cts_model.rs'='ACEAA15363123470FA09481BF6408FF2BDFF95A15D65489D64A9998B8E26F6C7'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/audit_cli.rs'='8CECE549BD88A0CD30367C3A54C540276A129BCAA5944C06965EB6F7923CD6D6'
        'experiments/khc/causal-bayes-q32-kt-reciprocal/exact_kt.rs'='4DC85F126E3813531337036A6A3C4B048B1B256645A3E58A60469170383A0B61'
        'experiments/khc/kt-reciprocal-table/exact_kt.rs'='D102D534397EA91055DCF0716B05EB48F1CFB0642F1B45FA27A388C894CCFE25'
        'build/khc-kt-reciprocal-numeric-20261001/report.json'='9E6CE54D564C602CBAD6ACADFDF67D9AB0D2444B7C4791AC5383CDEAB63BBF93'
        'experiments/khc/Q32_NATIVE32_MODEL_CONTRACT_20261001.md'='13E0B3B9640CF0168DDDAD19777FBCAAC6B1B5DE284E9D5503831028F68E3336'
        'experiments/khc/Q32_NATIVE32_MODEL_REPAIR_20261001.md'='D0189164F863BC290370D7947FDBE9DA35C2747BBCF5099085657F585535D1EF'
        'experiments/khc/Q32_NATIVE32_MODEL_FORMAT_SCOPE_20261001.md'='9FD4C427E0B7BE4FBF81EB5C9E567E494B361ED57327687D5F35E68F3B001985'
        'experiments/khc/causal-bayes-q32-balanced-kt/cts_model.rs'='9CFC6DF121A3711D704ED9F36F8D068F03A788DBC9F1A67118BB0CA89BD2F647'
        'experiments/khc/causal-bayes-q32-balanced-kt/audit_cli.rs'='CD3F0D1FA5671AAC10A72222AA35F7DD84623D90CAE1DA9EAEE3104CC68859EC'
        'experiments/khc/causal-bayes-q32-native32/cts_model.rs'='27775D82F1A94E013C83A2D42C8A004D7EF507ED09302EB1BB0704DCC798B0A0'
        'experiments/khc/causal-bayes-q32-native32/audit_cli.rs'='CD3F0D1FA5671AAC10A72222AA35F7DD84623D90CAE1DA9EAEE3104CC68859EC'
        'experiments/khc/native32-quotient/exact_div.rs'='338B2EB4F8A7C70994BD96CE28038C107F65F1106DD57A575CA6C524797310CD'
        'build/khc-native32-quotient-numeric-20261001/report.json'='DF1FCBAA5884D8DB2B7234F5DF7A0356C1C3A5D198204929DEDB1F9C836EE656'
        'build/khc-q32-balanced-kt-numeric-20261001-junction-validated/report.json'='63ACB1BBF1A2EFE811B76E761C6AA4CFDF2F4C443F75E24AD18FD97D312F5DAF'
    }
    foreach($pin in $pins.GetEnumerator()){$null=Hold (Join-Path $root $pin.Key) 'source-contract-or-parent' $pin.Value}
    $null=Hold $PSCommandPath 'verifier'
    $null=Hold $compiler 'compiler' 'CA9988AF88B1463F6857FDFE909299FEE50A63260B3E5F7DBCB5B4D3318B27BC'
    # 許可された変更だけを順に適用し、空白と末尾LFも含め全sourceを照合。
    $changes = @'
{
  "cts": [
    [
      "    fn kt(&self) -> Result<u64> {\n        let total = self\n            .zero\n            .checked_add(self.one)\n            .ok_or(\"CTS node total overflow\")?;\n        if total > MAX_OBSERVATIONS {\n            return Err(\"CTS node observation cap exceeded\".into());\n        }\n        // 合計のoverflowとcap検査を通過した等カウントだけを短絡する。\n        if self.zero == self.one {\n            return Ok(Q / 2);\n        }\n        let numerator_factor = u64::from(self.zero)\n            .checked_mul(2)\n            .and_then(|n| n.checked_add(1))\n            .ok_or(\"CTS KT numerator overflow\")?;\n        let denominator = u64::from(total)\n            .checked_add(1)\n            .ok_or(\"CTS KT denominator overflow\")?;\n        probability(ratio(Q / 2, numerator_factor, denominator)?)\n    }",
      "    fn kt(&self, table: &exact_kt::KtTable) -> Result<u64> {\n        table\n            .kt(self.zero, self.one)\n            .map(|(probability, _, _)| probability)\n            .map_err(|e| e.into())\n    }"
    ],
    [
      "mod exact_div;",
      "mod exact_div;\n#[path = \"exact_kt.rs\"]\nmod exact_kt;"
    ],
    [
      "    fn predict(&self) -> Result<Prediction> {",
      "    fn predict(&self, table: &exact_kt::KtTable) -> Result<Prediction> {"
    ],
    [
      "                .kt()?;",
      "                .kt(table)?;"
    ],
    [
      "    trees: [Tree; CLASSES],",
      "    trees: [Tree; CLASSES],\n    kt_table: exact_kt::KtTable,"
    ],
    [
      "impl Model {",
      "impl Model {\n    #[cfg(khc_mixture_reuse_audit)]\n    pub(super) fn audit_table_bytes(&self) -> usize {\n        self.kt_table.audit_bytes()\n    }\n"
    ],
    [
      "            ],\n        })\n    }\n    pub(super) fn predict",
      "            ],\n            kt_table: exact_kt::KtTable::new().map_err(|e| e.to_string())?,\n        })\n    }\n    pub(super) fn predict"
    ],
    [
      "            .predict()",
      "            .predict(&self.kt_table)"
    ],
    [
      "#[cfg(khc_balanced_kt_audit)]\npub(super) fn audit_kt(zero: u32, one: u32) -> Result<(u64, u64)> {\n    match (Node { zero, one, weight: Q / 2 }).kt() {",
      "#[cfg(khc_balanced_kt_audit)]\npub(super) fn audit_kt_table() -> Result<exact_kt::KtTable> {\n    exact_kt::KtTable::new().map_err(|e| e.to_string())\n}\n#[cfg(khc_balanced_kt_audit)]\npub(super) fn audit_kt(table: &exact_kt::KtTable, zero: u32, one: u32) -> Result<(u64, u64)> {\n    match (Node { zero, one, weight: Q / 2 }).kt(table) {"
    ]
  ],
  "cli": [
    [
      "    #[cfg(khc_mixture_reuse_audit)]\n    {\n        for r",
      "    #[cfg(khc_mixture_reuse_audit)]\n    let table_bytes = {\n        for r"
    ],
    [
      "        }\n    }\n    #[cfg(khc_balanced_kt_audit)]\n    for r",
      "        }\n        model.audit_table_bytes()\n    };\n    #[cfg(khc_balanced_kt_audit)]\n    let table = cts_model::audit_kt_table()?;\n    #[cfg(khc_balanced_kt_audit)]\n    for r"
    ],
    [
      "cts_model::audit_kt(zero, one)?",
      "cts_model::audit_kt(&table, zero, one)?"
    ],
    [
      "format!(\",\\\"prediction_bytes\\\":{prediction_bytes},\\\"node_bytes\\\":{node_bytes}\")",
      "format!(\",\\\"prediction_bytes\\\":{prediction_bytes},\\\"node_bytes\\\":{node_bytes},\\\"table_bytes\\\":{table_bytes}\")"
    ]
  ]
}
'@ | ConvertFrom-Json
    foreach($kind in @('cts','cli')){
        $file=if($kind -eq 'cts'){'cts_model.rs'}else{'audit_cli.rs'}
        $expected=[IO.File]::ReadAllText((Join-Path $PSScriptRoot "../causal-bayes-q32-native32/$file"))
        foreach($change in $changes.$kind){
            $needle=[string]$change[0];$replacement=[string]$change[1]
            if(([regex]::Matches($expected,[regex]::Escape($needle))).Count -ne 1){throw "Non-unique correspondence edit: $kind"}
            $expected=$expected.Replace($needle,$replacement)
        }
        if([IO.File]::ReadAllText((Join-Path $PSScriptRoot $file)) -cne $expected){throw "Source correspondence failure: $kind"}
        Check "localized-source-correspondence-$kind"
    }
    $oldHelper=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../kt-reciprocal-table/exact_kt.rs'))
    $needle="    #[cfg(khc_kt_reciprocal_audit)]\n    pub fn audit_bytes"
    $replacement="    #[cfg(any(khc_kt_reciprocal_audit, khc_mixture_reuse_audit))]\n    pub fn audit_bytes"
    $needle=$needle.Replace('\n',"`n");$replacement=$replacement.Replace('\n',"`n")
    if(([regex]::Matches($oldHelper,[regex]::Escape($needle))).Count -ne 1 -or [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'exact_kt.rs')) -cne $oldHelper.Replace($needle,$replacement)){throw 'Helper cfg-only correspondence failure'}
    Check 'helper-cfg-only-correspondence'
    $numeric=Get-Content -LiteralPath (Join-Path $root 'build/khc-kt-reciprocal-numeric-20261001/report.json') -Raw|ConvertFrom-Json
    if($numeric.status -cne 'verified_KT_reciprocal_numeric_not_timed' -or $numeric.checks.Count -ne 36 -or $numeric.invocations.Count -ne 42 -or $numeric.owned_tmp_count -ne 0 -or $numeric.owned_reparse_count -ne 0){throw 'Reciprocal numeric prerequisite mismatch'}
    Check 'frozen-reciprocal-numeric-prerequisite'
    $parent=Get-Content -LiteralPath (Join-Path $oldRoot 'report.json') -Raw|ConvertFrom-Json
    if($parent.status -cne 'verified'){throw 'Parent status mismatch'}
    $history=$parent.model_history
    if($history.records -ne 11267 -or $history.histories -ne 7 -or $history.classes -ne 7 -or $history.maximum_batch -ne 4096 -or $history.raw_bytes_per_record -ne 680 -or $history.levels -ne 17 -or $history.layout.prediction_bytes -ne 544 -or $history.layout.node_bytes -ne 16 -or ($history.fixtures -join ',') -cne 'empty,known,zeros,ones,alternating,biased,maximum' -or ($history.level_fields -join ',') -cne 'KT-Q32,zero-Q32,updated-zero-count,updated-one-count,updated-weight' -or $history.audit_cfg -cne 'khc_mixture_reuse_audit'){throw 'Parent Model schema mismatch'}
    $report.model_history=$history
    $recordTotal=0
    foreach($case in $history.fixtures){
        $paths=@((Join-Path $oldRoot "model-$case.input"),(Join-Path $oldRoot "model-$case.expected"))
        foreach($opt in @('2','3')){foreach($round in 0..1){$paths+=Join-Path $oldRoot "model-$case-opt$opt-$round.output"}}
        foreach($path in $paths){
            $parentId=@($parent.identities|Where-Object {$_.path -ceq $path});if($parentId.Count -ne 1 -or $parentId[0].before_sha256 -cne $parentId[0].after_sha256 -or $parentId[0].before_bytes -ne $parentId[0].after_bytes){throw 'Parent fixture identity mismatch'}
            $held=Hold $path 'frozen-Model-fixture' $parentId[0].before_sha256;if($held.bytes -ne $parentId[0].before_bytes){throw 'Parent fixture length mismatch'}
        }
        $count=(Get-Item -LiteralPath $paths[0]).Length/2;$recordTotal+=$count
        if($count -gt 4096 -or (Get-Item -LiteralPath $paths[1]).Length -ne $count*680){throw 'Frozen fixture size mismatch'}
        foreach($raw in $paths[2..5]){Same-Bytes $raw $paths[1]};Check "frozen-opt-repeat-oracle-$case"
    }
    if($recordTotal -ne 11267){throw 'Frozen records mismatch'}
    $tokens=$null;$parseErrors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$tokens,[ref]$parseErrors);if($parseErrors.Count){throw 'PowerShell Parser failure'}
    $null=Invoke-Child $compiler @('--version','--verbose')
    $formatter=Join-Path ([IO.Path]::GetDirectoryName($compiler)) 'rustfmt.exe';$null=Hold $formatter 'formatter'
    # 凍結cloneの非標準書式を保持するため、新helperだけをfmt検査する。
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot '../native32-quotient/exact_div.rs'))
    $null=Invoke-Child $formatter @('--edition','2024','--config','skip_children=true','--check',(Join-Path $PSScriptRoot 'exact_kt.rs'))
    Check 'helper-fmt-clone-verbatim-not-fmt-clean'
    $executables=@()
    foreach($portable in @($false,$true)){foreach($opt in @('2','3')){
        $mode=if($portable){'portable'}else{'native'};$exe=Join-Path $work "model-$mode-opt$opt.exe"
        $argv=@('--edition=2024','-C','panic=abort','-C',"opt-level=$opt",'--cfg','khc_mixture_reuse_audit')
        if($portable){$argv+=@('--cfg','khc_force_portable')};$argv+=@((Join-Path $PSScriptRoot 'audit_cli.rs'),'-o',$exe)
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-Model-CLI'
        $executables+=@{path=$exe;mode=$mode;opt=$opt}
    }}
    foreach($executable in $executables){foreach($case in $history.fixtures){
        $fixture=Join-Path $oldRoot "model-$case.input";$oracle=Join-Path $oldRoot "model-$case.expected";$output=Join-Path $work "model-$case-$($executable.mode)-opt$($executable.opt).output"
        $row=Invoke-Child $executable.path @($fixture,$output);$owned.Add($output);$null=Hold $output 'Model-raw-output';Same-Bytes $output $oracle
        $stats=$row.stdout.Trim()|ConvertFrom-Json
        if($stats.operation -cne 'q32-mixture-reuse-model-audit' -or $stats.records -ne (Get-Item -LiteralPath $fixture).Length/2 -or $stats.prediction_bytes -ne 544 -or $stats.node_bytes -ne 16 -or $stats.table_bytes -ne 524296){throw 'Model Stats/layout mismatch'}
        Check "Model-fullbytes-$case-$($executable.mode)-opt$($executable.opt)"
    }}
    $invalid=@{class=[byte[]]@(7,0);bit=[byte[]]@(0,2);odd=[byte[]]@(0);cap=[byte[]]::new(4096*2+2)}
    foreach($entry in $invalid.GetEnumerator()){$path=Join-Path $work "$($entry.Key).input";Write-New $path $entry.Value;$null=Hold $path 'invalid-input'}
    foreach($executable in $executables){
        $prefix="$($executable.mode)-opt$($executable.opt)"
        foreach($case in @('class','bit','odd','cap')){$reason=if($case -in @('class','bit')){'class/bit outside bounds'}elseif($case -eq 'odd'){'incomplete record'}else{'within cap'};Refuse $executable.path (Join-Path $work "$case.input") (Join-Path $work "$case-$prefix.output") $reason}
        $sentinel=Join-Path $work "existing-$prefix.output";Write-New $sentinel ([byte[]]@(31,41,59));$before=Identity $sentinel
        $row=Invoke-Child $executable.path @((Join-Path $oldRoot 'model-known.input'),$sentinel) 1
        if($row.stderr -notmatch 'output create_new publication:' -or (Identity $sentinel).sha256 -cne $before.sha256){throw 'No-clobber mismatch'};$null=Hold $sentinel 'no-clobber-sentinel';Check "no-clobber-$prefix"
    }
    # 互換監査入口もbatch共有tableで評価し、overflow/capを含む旧KT全件を照合。
    $ktInput=Join-Path $oldRoot 'kt-finite.input';$ktExpected=Join-Path $oldRoot 'kt-finite.expected'
    foreach($path in @($ktInput,$ktExpected)){
        $parentId=@($parent.identities|Where-Object {$_.path -ceq $path})
        if($parentId.Count -ne 1 -or $parentId[0].before_sha256 -cne $parentId[0].after_sha256 -or $parentId[0].before_bytes -ne $parentId[0].after_bytes){throw 'Frozen KT identity mismatch'}
        $held=Hold $path 'frozen-KT-fixture' $parentId[0].before_sha256
        if($held.bytes -ne $parentId[0].before_bytes){throw 'Frozen KT length mismatch'}
    }
    if((Get-Item -LiteralPath $ktInput).Length -ne 65536*8 -or (Get-Item -LiteralPath $ktExpected).Length -ne 65536*16){throw 'KT record size mismatch'}
    foreach($portable in @($false,$true)){
        $mode=if($portable){'portable'}else{'native'};$exe=Join-Path $work "kt-$mode-opt3.exe"
        $argv=@('--edition=2024','-C','panic=abort','-C','opt-level=3','--cfg','khc_balanced_kt_audit')
        if($portable){$argv+=@('--cfg','khc_force_portable')}
        $argv+=@((Join-Path $PSScriptRoot 'audit_cli.rs'),'-o',$exe)
        $null=Invoke-Child $compiler $argv;$owned.Add($exe);$null=Hold $exe 'compiled-KT-CLI'
        $output=Join-Path $work "kt-$mode.output"
        $row=Invoke-Child $exe @($ktInput,$output);$owned.Add($output);$null=Hold $output 'KT-raw-output';Same-Bytes $output $ktExpected
        $stats=$row.stdout.Trim()|ConvertFrom-Json
        if($stats.operation -cne 'q32-balanced-kt-audit' -or $stats.records -ne 65536){throw 'KT Stats mismatch'}
        Check "KT-fullbytes-and-error-order-$mode"
    }
    $report['table_storage_bytes']=524296
    $report.status='verified_model_not_timed'
}catch{$failure=$_;$report.error=$_.Exception.ToString();$report['error_stack']=$_.ScriptStackTrace}
finally{
    foreach($id in $ids){try{$after=Identity $id.path;$id.after_bytes=$after.bytes;$id.after_sha256=$after.sha256;if($id.before_bytes -ne $id.after_bytes -or $id.before_sha256 -cne $id.after_sha256){throw 'Source/raw after identity changed'}}catch{$report.status='failed';$report.error=(@($report.error,$_.Exception.Message)|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure=$_}}}
    foreach($held in $locks){$held.Dispose()}
    $report.inventory=@(Get-ChildItem -LiteralPath $work -Force|ForEach-Object {[pscustomobject]@{path=$_.FullName;name=$_.Name;bytes=if($_ -is [IO.FileInfo]){$_.Length}else{$null};reparse=(($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)}})
    $report.owned_tmp_count=@($report.inventory|Where-Object {$_.name -like '.quotient-*.tmp'}).Count;$report.owned_reparse_count=@($report.inventory|Where-Object {$_.reparse}).Count
    if($report.owned_tmp_count -ne 0 -or $report.owned_reparse_count -ne 0){$report.status='failed';$report.error=(@($report.error,'Owned tmp/reparse remains')|Where-Object {$_}) -join '; ';if($null -eq $failure){$failure='Owned tmp/reparse remains'}}
    $report['completed_utc']=[DateTime]::UtcNow.ToString('o')
    Write-New (Join-Path $work 'report.json') ([Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 20)))
}
if($null -ne $failure){throw $failure}
"Model E2E passed: $($checks.Count) checks; $($calls.Count) CLI; report=$(Join-Path $work 'report.json')"
