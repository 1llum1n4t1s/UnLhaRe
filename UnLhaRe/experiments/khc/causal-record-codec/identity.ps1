# 既存reportと現在共有sourceの読み取り専用照合。速度は再実行しない。
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$screenPath=Join-Path $root 'build/khc-causal-record-codec-screen-a-20261006/report.json'
$speedPath=Join-Path $root 'build/khc-causal-record-codec-speed-normal-a-20261006/report.json'
$screenSha='FB582327FD4E6B4A237A9976C21982F276E167D7A25854B57EEDD72315481235'
$speedSha='1A6D89B3BB94952FB9B017966CA784609E666F9B12793B7F62D87FF4F2975DD8'
if((Get-FileHash -LiteralPath $screenPath).Hash -ne $screenSha -or (Get-FileHash -LiteralPath $speedPath).Hash -ne $speedSha){throw 'proof report SHA'}
# DateKind Stringでround-trip timestampを保持。DateTime自動変換と文字列の比較はしない。
$screen=Get-Content -LiteralPath $screenPath -Raw|ConvertFrom-Json -DateKind String
$speed=Get-Content -LiteralPath $speedPath -Raw|ConvertFrom-Json -DateKind String
$past=@{};foreach($pin in $screen.pins){$past[[IO.Path]::GetFullPath($pin.path)]=$pin}
$common=[Collections.Generic.List[object]]::new();$locks=[Collections.Generic.List[IO.FileStream]]::new()
try {
    foreach($pin in $speed.pins){
        $path=[IO.Path]::GetFullPath($pin.path)
        if($past.ContainsKey($path)){
            $previous=$past[$path]
            if($previous.SHA256 -ne $pin.SHA256 -or $previous.bytes -ne $pin.bytes -or $previous.mtime -ne $pin.mtime){throw ('shared source/pin changed: '+$path)}
            $locks.Add([IO.File]::Open($path,'Open','Read','Read'))
            $current=Get-Item -LiteralPath $path
            if($current.Length -ne $pin.bytes -or $current.LastWriteTimeUtc.ToString('o') -ne $pin.mtime -or (Get-FileHash -LiteralPath $path).Hash -ne $pin.SHA256){throw ('current pin changed: '+$path)}
            $common.Add([ordered]@{path=$path;SHA256=$pin.SHA256;bytes=$pin.bytes;mtime=$pin.mtime})
        }
    }
    foreach($required in @('experiments/khc/causal-record-codec/codec.rs','experiments/khc/causal-record-codec/baseline_block.rs','experiments/khc/causal-record-vote/voter.rs','src/khc/block/multi_range.rs','build/cargo/x86_64-pc-windows-msvc/release/deps/libunlhare.rlib','Cargo.toml','Cargo.lock')){
        $path=[IO.Path]::GetFullPath((Join-Path $root $required))
        if(-not @($common|Where-Object path -eq $path).Count){throw ('required shared pin missing: '+$path)}
    }
    [ordered]@{checked_utc=[DateTime]::UtcNow.ToString('o');status='identical';screen_SHA256=$screenSha;speed_SHA256=$speedSha;same_source_compiler_dependencies_corpus=$true;common_count=$common.Count;common_pins=$common;interpretation='post-run identity audit, not a new benchmark'}|ConvertTo-Json -Depth 5
} finally {foreach($lock in $locks){$lock.Dispose()}}
