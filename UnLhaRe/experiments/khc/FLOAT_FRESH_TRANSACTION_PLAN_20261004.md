# Fresh branch transaction: 実装前契約

## 根拠と採否条件

lookup-float-profileの初回native診断は全frame478750B/全plain/typed Proof14/stats一致。予測親が主要なsample段で、CTS/pool両方が重い。observe stale再照合だけで総合達成できる証拠はない。sample weighted合計はwholeを越えており時計/TLS擾乱のため正式な改善可能率へ外挿しない。FT1は小容量の一候補として実際に反証する。速度改善がなければ不採用にする。

## 最初に起こり得る失敗

callbackがModelを変更できる、readonly予測を改変できる、child確定前の状態を学習へ混ぜる、coder/edge失敗前にModelを変更する、pool/count/auditをCTS拒否より先にcommitする、予測CAPちょうどを更新可能と誤解する、不正child/serial overflow/raw CAP/NaN拒否を失う、演算順やentropy bitsを変える、checked検証経路だけ通して新経路を未検証にする、保持情報の削減を実コピー削減と誤認する、有利な性能再試行で採用する、入力コピーや大きなtraceを作る。

## 実装範囲

新規 `float-fresh-transaction/` のみ。凍結lookup-float-cts/profileのsource/report/EXE/plan、製品、別版は変更しない。1 branchの排他的&mut Model transaction内で予測→狭いreadonly callback→child/edge確定→pending準備→末尾commitを行う。callbackへ&mut Modelや可変予測を渡さない。unsafeを使わない。

数値演算と演算順は維持。予測の入力/count/weight/vector/CDF検査、child/slot範囲、gradient/posterior有限性と範囲、serial/audit overflow、class/raw更新CAPは残す。fresh scopeで不変が保証できたstale比較/同path再生成/検証済みpの再vector/同state再検査だけを削減する。snapshot構造縮小（FT2）や新数値方式は今回は行わない。

checked split経路を残す場合はstandalone拒否検証専用と明示して通常codecから外す。通常経路をfresh一本へ切り替える。変更はapply_patchのみ、Git stage/commit/push/外部書込み/削除は行わない。

## 検証

先に新fresh経路のcallback Err/不正child/edge拒否、serial overflow、class/raw CAP境界を通し、Model全state直接比較（float to_bits）で非mutationを検証する。既存26拒否は補助であり代用にしない。既存standalone正常/異常E2Eと少量/空入力の新経路を通す。固定inputは既存all.groupをRAM読込、参照float codecと全frame・全plain・typed Proof14全14値・stats・entropy bits比較。

サイズと正当性を先に判定し、合格時のみreference/new/new/referenceの内部ABBAを一周、warmup0。両encode/decodeが短縮するときだけprivate候補として保持する。静穏正式full CLI/holdout/完成書庫/同resource/4native/製品API/7-Zip勝利はこの診断の保証外。係数/depth sweep、優先度変更、他process停止、有利再試行なし。

## 資源

未使用build/khc-float-fresh-transaction-20261004、生成物8MiB、EXE1MiB、report256KiB、source閉包300KiB、stdout64KiB/stderr16KiB、compile60秒/native各120秒。rustc単体opt2/overflowyes/panicabort/debug0/DEBUG:NONE。新Cargo target/PDB/rawtrace/frame/plain/input disk copyなし。disk-budget事前/事後/最終report後、source/tool/input beforeafter SHA/bytes/timeとprocess残存を確認。失敗証拠を残し構文修復は未使用別rootと全compile回数を明記する。

## 観点

Performance/Hardening/Testerは上記契約で親と実装担当、Cleanerはfresh通常経路とchecked検証専用の分離、Startupは初期化を変更しない。Modernizer/Normalizer/Async/Intelはruntime/API/並列/外部仕様を変えないため非該当。所有編集担当一名、独立照合は別文脈。元の固定ゲートとGOAL activeを維持する。
