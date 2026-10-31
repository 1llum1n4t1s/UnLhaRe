# Model 成功時 String 除去：先行失敗契約

## 範囲・所有

別 private root `hard-cut-model-lazy/`。元の通常候補と証拠は凍結する。worker の所有は `lazy_model.rs`, `codec.rs`, `float_scope.rs`, `adapter.rs`, `probe.rs`, `run-native.ps1` の6ファイルのみ。親は本 PLAN と RESULT、decision log、後段 readonly verifier を所有する。製品、Git、version、外部、削除は変更しない。

## 根拠と変更

`lookup-float-cts/model.rs` の tree edge / tree token / branch slot の3箇所だけ `ok_or("...".into())` を `ok_or_else(||"...".into())` に変更する。探索・clone・observe・浮動小数計算・状態更新・拒否メッセージは維持する。source意味上の成功時評価は方向ごと7650680回。LLVM除去や実 allocation 数・通常速度利益は未測定であり断言しない。

codecは凍結 `causal-hard-cut-wire/codec.rs` から model path だけ変更。scopeは新codecへ1path、adapter/probeは通常候補の exact bytes を維持。独自 allocator / 計測counterは導入しない。

## 先行失敗条件・E2E

既存凍結 finite E2E を使用、後書き unit test は追加しない。正常14の全plain/同型Proof14/再圧縮frame、破損34の厳密拒否理由、短header4が旧結果に完全一致しなければ失敗。

固定入力2811006 B/SHA18B8B47B24DA910DEF2835F01200208966009FF442C62A29F40C959EB9801E76を一度読み、圧縮1/展開1、全plain/Proof14直接一致、全stats/旧Debug/サイズ478856一致を検証。固定旧新全frameの直接比較は今回はしないと明記する。

compile1/native2だけを親レビュー後実行。rustc/toolchain/設定/source closure を識別し before/after/live照合、timeout/残存process/WinAPI両peak/実Vec容量/source boundを維持。rawframe/plain/イベント大コピーは保存しない。8MiB/空き5GiB guard事前事後、EXE<=1MiB、2出力のみ。単回内部診断時間のみ、正式CLI speed/holdout/native4/採用/GOAL成功とは区別する。

## 採否・観点

Performanceは成功時評価の除去と通常診断、Normalizerは3exact置換/接続allowlist、Hardening/Testerは凍結有限E2E/固定実行経路、Cleanerは生copyなし/証拠保持、Modernizerは依存変更なし。Asyncはphase寿命維持、Intel/Startupは外部仕様・製品起動変更なし。全総合ゲートは維持。小改善だけで46倍近い展開速度差が解消するとは主張しない。
